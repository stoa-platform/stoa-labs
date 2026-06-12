package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"sigs.k8s.io/yaml"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/audit"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/governance"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/onboarding"
)

// fakeVerifier maps a raw token string to the Identity it "validates" to. An
// unknown token returns an error — modelling a forged/absent token without a
// live Keycloak/JWKS. This is the seam the local JWKS Verifier sits behind in
// production (cmd uses governance.NewVerifierWithAudience).
type fakeVerifier struct {
	valid map[string]*governance.Identity
}

func (f fakeVerifier) Verify(_ context.Context, token string) (*governance.Identity, error) {
	if id, ok := f.valid[token]; ok {
		return id, nil
	}
	return nil, errInvalidToken
}

var errInvalidToken = &verErr{}

type verErr struct{}

func (*verErr) Error() string { return "jwt: invalid token" }

// fakeAudit captures every recorded decision so a test can assert that a DENY
// (and an ACCEPT) was audited with the right reason/decision/tenant.
type fakeAudit struct {
	mu     sync.Mutex
	events []audit.Event
}

func (a *fakeAudit) Record(_ context.Context, ev audit.Event) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.events = append(a.events, ev)
}

func (a *fakeAudit) last() audit.Event {
	a.mu.Lock()
	defer a.mu.Unlock()
	if len(a.events) == 0 {
		return audit.Event{}
	}
	return a.events[len(a.events)-1]
}

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

// onboarderID is a validated identity carrying the partner-onboarder role and
// tenant=banking-demo (via the flat `tenant` claim).
func onboarderID(tenant string) *governance.Identity {
	return &governance.Identity{
		Username: "alice",
		Subject:  "sub-alice",
		Name:     "Alice Onboarder",
		Email:    "alice@bank.example",
		Roles:    []string{RequiredRole, "viewer"},
		Tenant:   tenant,
	}
}

func newServer(t *testing.T) (*Server, *governance.Repo, *fakeAudit) {
	t.Helper()
	dir := t.TempDir()
	gitT(t, dir, "init", "-b", "main")
	gitT(t, dir, "config", "user.name", "seed")
	gitT(t, dir, "config", "user.email", "seed@test.local")
	gitT(t, dir, "config", "commit.gpgsign", "false")
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("seed\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitT(t, dir, "add", "README.md")
	gitT(t, dir, "commit", "-m", "seed: init")

	repo, err := governance.OpenRepo(dir)
	if err != nil {
		t.Fatalf("OpenRepo: %v", err)
	}
	aud := &fakeAudit{}
	vf := fakeVerifier{valid: map[string]*governance.Identity{
		"good-banking":  onboarderID("banking-demo"),
		"good-payments": onboarderID("payments-team"),
		"norole":        {Username: "bob", Subject: "sub-bob", Roles: []string{"viewer"}, Tenant: "banking-demo"},
		"notenant":      {Username: "carol", Subject: "sub-carol", Roles: []string{RequiredRole}},
		"group-tenant": {
			Username: "dave", Subject: "sub-dave",
			Roles:  []string{RequiredRole},
			Groups: []string{"/tenants/banking-demo"},
		},
	}}
	srv := &Server{Svc: &onboarding.Service{Repo: repo}, Verifier: vf, Audit: aud}
	return srv, repo, aud
}

func validBody(tenant string) string {
	return `{
	  "name": "acme-payments",
	  "tenant": "` + tenant + `",
	  "clientId": "acme-payments-client",
	  "apis": ["accounts-read"],
	  "ipAllowlist": ["203.0.113.10", "10.60.30.1-10.60.30.30"],
	  "publicCert": "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n",
	  "tokenIdentifiers": ["partner-token-abc"]
	}`
}

func post(t *testing.T, url, token, body string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, url, bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	return resp
}

// THE happy path: a valid token (role partner-onboarder, tenant banking-demo)
// with a matching body tenant writes the manifest as the VALIDATED actor and
// audits an ACCEPT carrying the commit sha + trace id.
func TestOnboard_ValidTokenMatchingTenant_201(t *testing.T) {
	srv, repo, aud := newServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	resp := post(t, ts.URL+"/applications", "good-banking", validBody("banking-demo"))
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("expected 201, got %d", resp.StatusCode)
	}
	if resp.Header.Get("X-Trace-Id") == "" {
		t.Fatal("missing X-Trace-Id response header")
	}

	var out onboarding.Result
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if out.Path != "tenants/banking-demo/partners/acme-payments.yaml" {
		t.Fatalf("unexpected path %q", out.Path)
	}

	// The manifest is REALLY in Git and committed by the VALIDATED actor (alice),
	// not by an X-Actor-* header.
	raw, err := repo.ReadFile(context.Background(), "main", out.Path)
	if err != nil {
		t.Fatalf("manifest not in Git: %v", err)
	}
	var m onboarding.Manifest
	if err := yaml.Unmarshal(raw, &m); err != nil {
		t.Fatalf("committed manifest is not valid YAML: %v\n%s", err, raw)
	}
	if m.Kind != onboarding.Kind || m.Spec.ClientID != "acme-payments-client" {
		t.Fatalf("manifest content wrong: %+v", m)
	}
	logOut := gitT(t, repo.Dir, "log", "-1", "--format=%an <%ae>")
	if !strings.Contains(logOut, "alice@bank.example") {
		t.Fatalf("commit author is not the validated actor: %q", logOut)
	}

	ev := aud.last()
	if ev.Decision != audit.Accept || ev.Reason != "ok" {
		t.Fatalf("expected ACCEPT/ok audit, got %+v", ev)
	}
	if ev.Actor != "alice" || ev.Tenant != "banking-demo" || ev.CommitSHA == "" || ev.TraceID == "" {
		t.Fatalf("audit ACCEPT missing fields: %+v", ev)
	}
}

// A token scoped to banking-demo cannot onboard for payments-team: 403 +
// DENY(tenant_mismatch), and NOTHING is written to Git.
func TestOnboard_TenantMismatch_403(t *testing.T) {
	srv, repo, aud := newServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	headBefore := gitT(t, repo.Dir, "rev-parse", "HEAD")
	resp := post(t, ts.URL+"/applications", "good-banking", validBody("payments-team"))
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", resp.StatusCode)
	}
	if headAfter := gitT(t, repo.Dir, "rev-parse", "HEAD"); headAfter != headBefore {
		t.Fatal("tenant-mismatch POST mutated Git HEAD")
	}
	ev := aud.last()
	if ev.Decision != audit.Deny || ev.Reason != "tenant_mismatch" {
		t.Fatalf("expected DENY/tenant_mismatch, got %+v", ev)
	}
	if ev.Tenant != "banking-demo" {
		t.Fatalf("mismatch DENY should be recorded under the token tenant, got %q", ev.Tenant)
	}
}

// A valid token WITHOUT the partner-onboarder role is refused 403 +
// DENY(missing_role).
func TestOnboard_MissingRole_403(t *testing.T) {
	srv, _, aud := newServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	resp := post(t, ts.URL+"/applications", "norole", validBody("banking-demo"))
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", resp.StatusCode)
	}
	if ev := aud.last(); ev.Decision != audit.Deny || ev.Reason != "missing_role" {
		t.Fatalf("expected DENY/missing_role, got %+v", ev)
	}
}

// No Authorization header → 401 + DENY(no_token).
func TestOnboard_NoToken_401(t *testing.T) {
	srv, _, aud := newServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	resp := post(t, ts.URL+"/applications", "", validBody("banking-demo"))
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
	if ev := aud.last(); ev.Decision != audit.Deny || ev.Reason != "no_token" {
		t.Fatalf("expected DENY/no_token, got %+v", ev)
	}
}

// A forged/unknown token (signature would not verify) → 401 + DENY(invalid_token).
func TestOnboard_ForgedToken_401(t *testing.T) {
	srv, _, aud := newServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	resp := post(t, ts.URL+"/applications", "forged.signature.here", validBody("banking-demo"))
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
	if ev := aud.last(); ev.Decision != audit.Deny || ev.Reason != "invalid_token" {
		t.Fatalf("expected DENY/invalid_token, got %+v", ev)
	}
}

// The tenant may also come from a `/tenants/{tenant}` group claim (no flat
// tenant claim) — group-derived scope onboards successfully.
func TestOnboard_GroupTenant_201(t *testing.T) {
	srv, _, aud := newServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	resp := post(t, ts.URL+"/applications", "group-tenant", validBody("banking-demo"))
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("expected 201, got %d", resp.StatusCode)
	}
	if ev := aud.last(); ev.Decision != audit.Accept || ev.Tenant != "banking-demo" {
		t.Fatalf("expected ACCEPT for group tenant, got %+v", ev)
	}
}

// A token with the role but NO tenant (neither claim nor group) is unscoped and
// refused 403 + DENY(no_tenant).
func TestOnboard_NoTenant_403(t *testing.T) {
	srv, _, aud := newServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	resp := post(t, ts.URL+"/applications", "notenant", validBody("banking-demo"))
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", resp.StatusCode)
	}
	if ev := aud.last(); ev.Decision != audit.Deny || ev.Reason != "no_tenant" {
		t.Fatalf("expected DENY/no_tenant, got %+v", ev)
	}
}

// A POST carrying a PRIVATE KEY is rejected 400 (validation) AFTER auth, and
// writes nothing — the non-regression of the original safety check, now behind
// the auth gate.
func TestOnboard_RejectsPrivateKey_400(t *testing.T) {
	srv, repo, aud := newServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	headBefore := gitT(t, repo.Dir, "rev-parse", "HEAD")
	body := `{
	  "name": "acme-payments",
	  "tenant": "banking-demo",
	  "clientId": "acme-payments-client",
	  "apis": ["accounts-read"],
	  "publicCert": "-----BEGIN PRIVATE KEY-----\nXX\n-----END PRIVATE KEY-----\n"
	}`
	resp := post(t, ts.URL+"/applications", "good-banking", body)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", resp.StatusCode)
	}
	var out struct {
		Error  string   `json:"error"`
		Fields []string `json:"fields"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if out.Error != "VALIDATION_FAILED" || len(out.Fields) == 0 {
		t.Fatalf("expected validation failure body, got %+v", out)
	}
	if headAfter := gitT(t, repo.Dir, "rev-parse", "HEAD"); headAfter != headBefore {
		t.Fatal("rejected POST mutated Git HEAD")
	}
	if ev := aud.last(); ev.Decision != audit.Deny || ev.Reason != "validation_failed" {
		t.Fatalf("expected DENY/validation_failed, got %+v", ev)
	}
}
