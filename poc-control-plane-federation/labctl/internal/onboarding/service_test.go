package onboarding

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"sigs.k8s.io/yaml"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/governance"
)

// gitT runs a git command in dir, failing the test on error. Global/system
// config is masked so a developer's commit.gpgsign cannot leak in.
func gitT(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(),
		"GIT_CONFIG_GLOBAL=/dev/null",
		"GIT_CONFIG_SYSTEM=/dev/null",
		"GIT_COMMITTER_NAME=seed",
		"GIT_COMMITTER_EMAIL=seed@test.local",
		"GIT_AUTHOR_NAME=seed",
		"GIT_AUTHOR_EMAIL=seed@test.local",
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return string(out)
}

// newGovernanceRepo seeds a throwaway governance repo on main (signature off).
func newGovernanceRepo(t *testing.T) *governance.Repo {
	t.Helper()
	dir := t.TempDir()
	gitT(t, dir, "init", "-b", "main")
	gitT(t, dir, "config", "user.name", "seed")
	gitT(t, dir, "config", "user.email", "seed@test.local")
	gitT(t, dir, "config", "commit.gpgsign", "false")
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("governance seed\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitT(t, dir, "add", "README.md")
	gitT(t, dir, "commit", "-m", "seed: init")

	repo, err := governance.OpenRepo(dir)
	if err != nil {
		t.Fatalf("OpenRepo: %v", err)
	}
	return repo
}

var idpDev = governance.Actor{
	Username: "idp-dev",
	Name:     "IdP Developer",
	Email:    "idp-dev@bank.example",
	Roles:    []string{"tenant-admin"},
}

// THE load-bearing proof: an Onboard call (what POST /applications invokes)
// writes a VALID partner manifest YAML into the governance Git repo — and only
// that. The gateway is never touched (the Service has no gateway client).
func TestOnboardWritesValidManifestToGit(t *testing.T) {
	repo := newGovernanceRepo(t)
	svc := &Service{Repo: repo}
	ctx := context.Background()

	res, verrs, err := svc.Onboard(ctx, validRequest(), idpDev)
	if err != nil {
		t.Fatalf("Onboard: %v", err)
	}
	if verrs != nil {
		t.Fatalf("unexpected validation errors: %v", verrs)
	}
	if !res.Created {
		t.Fatal("expected Created=true on first onboard")
	}
	if res.Commit.SHA == "" {
		t.Fatal("expected a commit SHA")
	}
	if res.Path != "tenants/banking-demo/partners/acme-payments.yaml" {
		t.Fatalf("unexpected manifest path %q", res.Path)
	}

	// Re-read FROM GIT (never from the request) and assert it is a valid manifest.
	raw, err := repo.ReadFile(ctx, "main", res.Path)
	if err != nil {
		t.Fatalf("manifest not committed to Git: %v", err)
	}
	var got Manifest
	if err := yaml.Unmarshal(raw, &got); err != nil {
		t.Fatalf("committed manifest is not valid YAML: %v\n%s", err, raw)
	}
	if got.Kind != Kind || got.APIVersion != APIVersion {
		t.Fatalf("committed manifest has wrong identity: %s/%s", got.APIVersion, got.Kind)
	}
	if got.Metadata.Tenant != "banking-demo" || got.Metadata.Name != "acme-payments" {
		t.Fatalf("metadata not committed: %+v", got.Metadata)
	}
	if got.Spec.ClientID != "acme-payments-client" || len(got.Spec.APIs) != 1 {
		t.Fatalf("spec not committed: %+v", got.Spec)
	}
	if len(got.Spec.Partner.IPAllowlist) != 3 || got.Spec.Partner.PublicCertRef == "" {
		t.Fatalf("partner block not committed: %+v", got.Spec.Partner)
	}

	// The commit is authored by the IdP actor, with the §3 audit trailers.
	log := gitT(t, repo.Dir, "log", "-1", "--format=%an <%ae>%n%B")
	if !strings.Contains(log, "IdP Developer <idp-dev@bank.example>") {
		t.Fatalf("commit not authored by the actor:\n%s", log)
	}
	if !strings.Contains(log, "Action: partner.onboard") {
		t.Fatalf("missing audit trailer:\n%s", log)
	}

	// And no private-key material ever reaches Git.
	if strings.Contains(strings.ToUpper(string(raw)), "PRIVATE KEY") {
		t.Fatal("private-key material leaked into the committed manifest")
	}
}

// Re-onboarding the SAME request is an idempotent no-op (byte-identical content
// -> the write-through layer returns the current head, no new commit).
func TestOnboardIdempotent(t *testing.T) {
	repo := newGovernanceRepo(t)
	svc := &Service{Repo: repo}
	ctx := context.Background()

	first, _, err := svc.Onboard(ctx, validRequest(), idpDev)
	if err != nil {
		t.Fatal(err)
	}
	second, _, err := svc.Onboard(ctx, validRequest(), idpDev)
	if err != nil {
		t.Fatal(err)
	}
	if first.Commit.SHA != second.Commit.SHA {
		t.Fatalf("expected idempotent re-onboard to reuse the head commit, got %s then %s",
			first.Commit.SHA7, second.Commit.SHA7)
	}
	if second.Created {
		t.Fatal("expected Created=false on the second onboard")
	}
}

// An invalid request never reaches Git: validation errors come back, the repo
// HEAD is unchanged (no gateway, no commit, no side effect).
func TestOnboardInvalidNeverCommits(t *testing.T) {
	repo := newGovernanceRepo(t)
	svc := &Service{Repo: repo}
	ctx := context.Background()

	headBefore := gitT(t, repo.Dir, "rev-parse", "HEAD")

	bad := validRequest()
	bad.PublicCert = "-----BEGIN PRIVATE KEY-----\nXX\n-----END PRIVATE KEY-----\n"
	res, verrs, err := svc.Onboard(ctx, bad, idpDev)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res != nil || verrs == nil {
		t.Fatalf("expected validation failure, got res=%v verrs=%v", res, verrs)
	}

	headAfter := gitT(t, repo.Dir, "rev-parse", "HEAD")
	if headBefore != headAfter {
		t.Fatal("an invalid onboard mutated Git HEAD — it must not commit")
	}
}
