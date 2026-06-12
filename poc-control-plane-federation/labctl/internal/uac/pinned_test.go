package uac

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// gitU runs one git command in dir with a hermetic identity (no global config,
// no signing) — the same pattern as the governance handler tests.
func gitU(t *testing.T, dir string, args ...string) string {
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

const pinnedV1 = `name: accounts-read
version: 1.0.0
tenant_id: banking-demo
status: published
endpoints:
  - path: /accounts
    methods: [GET]
    backend_url: http://backend-v1:8080/accounts
`

const pinnedV2 = `name: accounts-read
version: 2.0.0
tenant_id: banking-demo
status: published
endpoints:
  - path: /accounts
    methods: [GET]
    backend_url: http://backend-v2:8080/accounts
  - path: /accounts/{iban}
    methods: [GET]
    backend_url: http://backend-v2:8080/accounts
`

// pinnedRepo builds a REAL git governance repo where api.yaml has two commits
// and returns (root, sha of the first commit).
func pinnedRepo(t *testing.T) (string, string) {
	t.Helper()
	root := t.TempDir()
	gitU(t, root, "init", "-b", "main")
	gitU(t, root, "config", "user.name", "seed")
	gitU(t, root, "config", "user.email", "seed@test.local")
	gitU(t, root, "config", "commit.gpgsign", "false")

	apiPath := filepath.Join(root, "tenants", "banking-demo", "apis", "accounts-read", "api.yaml")
	if err := os.MkdirAll(filepath.Dir(apiPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(apiPath, []byte(pinnedV1), 0o644); err != nil {
		t.Fatal(err)
	}
	gitU(t, root, "add", "-A")
	gitU(t, root, "commit", "-m", "contract v1.0.0")
	sha1 := strings.TrimSpace(gitU(t, root, "rev-parse", "HEAD"))

	if err := os.WriteFile(apiPath, []byte(pinnedV2), 0o644); err != nil {
		t.Fatal(err)
	}
	gitU(t, root, "add", "-A")
	gitU(t, root, "commit", "-m", "contract v2.0.0")
	return root, sha1
}

func TestResolvePinned_ReplacesContractWithPinnedVersion(t *testing.T) {
	root, sha1 := pinnedRepo(t)
	// The dev deploy pins the FIRST commit while the worktree holds v2.0.0.
	deploy := "version: 1.0.0\nenabled: true\npromoted_by: alice\ncommit: " + sha1 + "\n"
	if err := os.WriteFile(filepath.Join(root, "tenants", "banking-demo", "apis", "accounts-read", "deploy.dev.yaml"),
		[]byte(deploy), 0o644); err != nil {
		t.Fatal(err)
	}

	apis, err := LoadRepo(root)
	if err != nil {
		t.Fatalf("LoadRepo: %v", err)
	}
	a := apis[0]
	if a.Contract.Version != "2.0.0" {
		t.Fatalf("HEAD contract = %s, want 2.0.0", a.Contract.Version)
	}
	if a.Deploys["dev"].Commit != sha1 {
		t.Fatalf("deploy.dev commit = %q, want %s", a.Deploys["dev"].Commit, sha1)
	}

	if err := ResolvePinned(root, &a, "dev"); err != nil {
		t.Fatalf("ResolvePinned: %v", err)
	}
	if a.Contract.Version != "1.0.0" || len(a.Contract.Endpoints) != 1 ||
		a.Contract.Endpoints[0].BackendURL != "http://backend-v1:8080/accounts" {
		t.Errorf("pinned contract not resolved: %+v", a.Contract)
	}
}

func TestResolvePinned_NoPinIsNoop(t *testing.T) {
	root, _ := pinnedRepo(t)
	apis, err := LoadRepo(root)
	if err != nil {
		t.Fatalf("LoadRepo: %v", err)
	}
	a := apis[0]
	// No deploy at all for the env, and no commit pin: both are no-ops.
	if err := ResolvePinned(root, &a, "staging"); err != nil {
		t.Fatalf("ResolvePinned(no deploy): %v", err)
	}
	a.Deploys = map[string]Deploy{"dev": {Enabled: true}}
	if err := ResolvePinned(root, &a, "dev"); err != nil {
		t.Fatalf("ResolvePinned(no pin): %v", err)
	}
	if a.Contract.Version != "2.0.0" {
		t.Errorf("contract must stay HEAD without a pin: %+v", a.Contract)
	}
}

func TestResolvePinned_GitFailureSurfaces(t *testing.T) {
	root, _ := pinnedRepo(t)
	apis, err := LoadRepo(root)
	if err != nil {
		t.Fatalf("LoadRepo: %v", err)
	}
	a := apis[0]
	a.Deploys = map[string]Deploy{"dev": {Enabled: true, Commit: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}}
	if err := ResolvePinned(root, &a, "dev"); err == nil ||
		!strings.Contains(err.Error(), "git show") {
		t.Errorf("err = %v, want a git show failure (fail-closed, never HEAD)", err)
	}
}
