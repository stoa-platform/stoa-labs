package main

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/governance"
)

// ---- git fixture ----

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

// seedRepo builds a governance repo equivalent to the demo seed: two tenants,
// one valid contract deployed in dev+staging, one pending subscription.
// Signing is OFF (the real seed turns it on).
func seedRepo(t *testing.T) *governance.Repo {
	t.Helper()
	dir := t.TempDir()
	gitT(t, dir, "init", "-b", "main")
	gitT(t, dir, "config", "user.name", "seed")
	gitT(t, dir, "config", "user.email", "seed@test.local")
	gitT(t, dir, "config", "commit.gpgsign", "false")

	files := map[string]string{
		"tenants/banking-demo/tenant.yaml": "id: banking-demo\nname: banking-demo\ndisplayName: Banking Demo\ntier: gold\nstatus: active\n",
		"tenants/other-corp/tenant.yaml":   "id: other-corp\nname: other-corp\ndisplayName: Other Corp\ntier: silver\nstatus: active\n",
		"tenants/banking-demo/apis/payments-initiation/api.yaml": `name: payments-initiation
version: 1.0.0
tenant_id: banking-demo
classification: VH
status: draft
endpoints:
  - path: /payments
    methods: ["POST"]
    backend_url: http://backend:8080
`,
		"tenants/banking-demo/apis/payments-initiation/deploy.dev.yaml":     "version: 1.0.0\nenabled: true\npromoted_by: seed\n",
		"tenants/banking-demo/apis/payments-initiation/deploy.staging.yaml": "version: 1.0.0\nenabled: true\npromoted_by: seed\n",
		"subscriptions/banking-demo/sub-001.yaml":                           "id: sub-001\napi: payments-initiation\nconsumer: treasury-app\nrequested_by: carol\nstatus: pending\n",
	}
	for p, c := range files {
		full := filepath.Join(dir, filepath.FromSlash(p))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(c), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	gitT(t, dir, "add", "-A")
	gitT(t, dir, "commit", "-m", "seed: banking-demo governance repo")

	repo, err := governance.OpenRepo(dir)
	if err != nil {
		t.Fatalf("OpenRepo: %v", err)
	}
	return repo
}

// ---- JWT fixture: RSA key + JWKS served by httptest ----

type authFixture struct {
	key    *rsa.PrivateKey
	issuer string
	sign   func(t *testing.T, username, name, tenant string, roles []string) string
}

// newAuthFixture generates an RSA key, serves its JWKS over httptest at the
// Keycloak certs path, and returns a token factory bound to the issuer.
func newAuthFixture(t *testing.T) (*authFixture, *governance.Verifier) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("rsa: %v", err)
	}
	jwks := map[string]any{
		"keys": []map[string]any{{
			"kid": "test-key",
			"kty": "RSA",
			"use": "sig",
			"alg": "RS256",
			"n":   base64.RawURLEncoding.EncodeToString(key.PublicKey.N.Bytes()),
			"e":   "AQAB",
		}},
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(jwks)
	}))
	t.Cleanup(srv.Close)

	verifier := governance.NewVerifier(srv.URL, "stoa-lab")
	fix := &authFixture{key: key, issuer: srv.URL + "/realms/stoa-lab"}
	fix.sign = func(t *testing.T, username, name, tenant string, roles []string) string {
		t.Helper()
		header, _ := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT", "kid": "test-key"})
		payload, _ := json.Marshal(map[string]any{
			"iss":                fix.issuer,
			"exp":                time.Now().Add(time.Hour).Unix(),
			"preferred_username": username,
			"name":               name,
			"email":              username + "@bank.example",
			"tenant":             tenant,
			"realm_access":       map[string]any{"roles": roles},
		})
		signing := base64.RawURLEncoding.EncodeToString(header) + "." + base64.RawURLEncoding.EncodeToString(payload)
		digest := sha256.Sum256([]byte(signing))
		sig, err := rsa.SignPKCS1v15(rand.Reader, fix.key, crypto.SHA256, digest[:])
		if err != nil {
			t.Fatalf("sign: %v", err)
		}
		return signing + "." + base64.RawURLEncoding.EncodeToString(sig)
	}
	return fix, verifier
}

// newTestServer wires a full Server on a seeded repo (Keycloak admin points
// at a dead port: the KC-backed endpoints are not under test here).
func newTestServer(t *testing.T) (*Server, http.Handler, *authFixture) {
	t.Helper()
	fix, verifier := newAuthFixture(t)
	srv := &Server{
		Store:    &governance.Store{Repo: seedRepo(t)},
		Verifier: verifier,
		KC:       governance.NewKCAdmin("http://127.0.0.1:1", "stoa-lab", "admin", "admin"),
		Schema:   uacSchema,
	}
	// The 403 audit is asynchronous: drain it before t.TempDir cleanup
	// deletes the repo under the goroutine's feet.
	t.Cleanup(srv.WaitDenials)
	return srv, srv.Handler(), fix
}

// do issues an authenticated JSON request and decodes the response body.
func do(t *testing.T, h http.Handler, method, path, token string, body any) (int, map[string]any) {
	t.Helper()
	var rdr *bytes.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		rdr = bytes.NewReader(raw)
	} else {
		rdr = bytes.NewReader(nil)
	}
	req := httptest.NewRequest(method, path, rdr)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	out := map[string]any{}
	raw := rec.Body.Bytes()
	if len(raw) > 0 && raw[0] == '[' {
		var list []any
		_ = json.Unmarshal(raw, &list)
		out["_list"] = list
	} else if len(raw) > 0 {
		_ = json.Unmarshal(raw, &out)
	}
	return rec.Code, out
}

func errCode(body map[string]any) string {
	if e, ok := body["error"].(map[string]any); ok {
		c, _ := e["code"].(string)
		return c
	}
	return ""
}

// ---- tests ----

func TestMeProjectsRolesAndPermissions(t *testing.T) {
	_, h, fix := newTestServer(t)
	alice := fix.sign(t, "alice", "Alice Martin", "banking-demo", []string{"tenant-admin", "offline_access"})

	code, body := do(t, h, "GET", "/api/v1/me", alice, nil)
	if code != 200 {
		t.Fatalf("GET /me = %d %v", code, body)
	}
	if body["username"] != "alice" || body["tenant"] != "banking-demo" {
		t.Fatalf("identity mismatch: %v", body)
	}
	perms := fmt.Sprintf("%v", body["permissions"])
	if !strings.Contains(perms, "apis:update") || strings.Contains(perms, "users:manage") {
		t.Fatalf("tenant-admin permissions wrong: %v", perms)
	}
	roles := fmt.Sprintf("%v", body["roles"])
	if strings.Contains(roles, "offline_access") {
		t.Fatalf("non-governance roles must be filtered from /me: %v", roles)
	}
}

func TestUnauthenticatedAndBadToken(t *testing.T) {
	_, h, _ := newTestServer(t)
	if code, body := do(t, h, "GET", "/api/v1/me", "", nil); code != 401 || errCode(body) != "UNAUTHORIZED" {
		t.Fatalf("no token: %d %v", code, body)
	}
	if code, _ := do(t, h, "GET", "/api/v1/me", "not.a.jwt", nil); code != 401 {
		t.Fatalf("garbage token must be 401, got %d", code)
	}
}

func TestTenantIsolation(t *testing.T) {
	_, h, fix := newTestServer(t)
	alice := fix.sign(t, "alice", "Alice Martin", "banking-demo", []string{"tenant-admin"})
	admin := fix.sign(t, "root", "Root Admin", "", []string{"cpi-admin"})

	// Alice only sees her tenant.
	code, body := do(t, h, "GET", "/api/v1/tenants", alice, nil)
	if code != 200 || len(body["_list"].([]any)) != 1 {
		t.Fatalf("alice tenants = %d %v", code, body)
	}
	// cpi-admin sees both.
	code, body = do(t, h, "GET", "/api/v1/tenants", admin, nil)
	if code != 200 || len(body["_list"].([]any)) != 2 {
		t.Fatalf("admin tenants = %d %v", code, body)
	}
	// Cross-tenant read is a 403.
	code, body = do(t, h, "GET", "/api/v1/tenants/other-corp/contracts", alice, nil)
	if code != 403 || errCode(body) != "FORBIDDEN" {
		t.Fatalf("cross-tenant read = %d %v", code, body)
	}
}

func TestViewerDenialIsAudited(t *testing.T) {
	srv, h, fix := newTestServer(t)
	viewer := fix.sign(t, "eve", "Eve Auditor", "banking-demo", []string{"viewer"})

	code, body := do(t, h, "PUT", "/api/v1/tenants/banking-demo/contracts/payments-initiation", viewer,
		map[string]any{"contract": map[string]any{"name": "payments-initiation"}})
	if code != 403 || errCode(body) != "FORBIDDEN" {
		t.Fatalf("viewer PUT = %d %v", code, body)
	}
	srv.WaitDenials()

	raw, err := os.ReadFile(filepath.Join(srv.Store.Repo.Dir, filepath.FromSlash(governance.DenialsPath)))
	if err != nil || !strings.Contains(string(raw), `"user":"eve"`) {
		t.Fatalf("denials.jsonl missing the refusal: %v %q", err, raw)
	}
	log := gitT(t, srv.Store.Repo.Dir, "log", "--format=%s", "main")
	if !strings.Contains(log, "deny(banking-demo): apis:update by eve") {
		t.Fatalf("deny commit missing:\n%s", log)
	}
}

func TestValidateDraftPutPublishFlow(t *testing.T) {
	srv, h, fix := newTestServer(t)
	alice := fix.sign(t, "alice", "Alice Martin", "banking-demo", []string{"tenant-admin"})

	// Validation surface: a destructive endpoint without approval is refused.
	badContract := map[string]any{
		"name": "payments-initiation", "version": "1.0.0", "tenant_id": "banking-demo",
		"classification": "VH", "status": "draft",
		"endpoints": []any{map[string]any{
			"path": "/payments/{id}", "methods": []any{"DELETE"}, "backend_url": "http://backend:8080",
			"llm": map[string]any{
				"summary": "annule", "intent": "annulation", "tool_name": "cancel_payment",
				"side_effects": "destructive", "safe_for_agents": false,
				"requires_human_approval": false,
				"examples":                []any{map[string]any{"input": map[string]any{}}},
			},
		}},
	}
	code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/contracts/payments-initiation/validate", alice,
		map[string]any{"contract": badContract})
	if code != 200 || body["valid"] != false {
		t.Fatalf("validate = %d %v", code, body)
	}
	if !strings.Contains(fmt.Sprintf("%v", body["errors"]), "DESTRUCTIVE_REQUIRES_APPROVAL") {
		t.Fatalf("destructive rule not reported: %v", body["errors"])
	}

	// PUT with an invalid contract -> 422, nothing committed.
	code, body = do(t, h, "PUT", "/api/v1/tenants/banking-demo/contracts/payments-initiation", alice,
		map[string]any{"contract": badContract})
	if code != 422 || errCode(body) != "VALIDATION_FAILED" {
		t.Fatalf("invalid PUT = %d %v", code, body)
	}

	// Valid PUT -> commit, response content re-read from Git.
	good := map[string]any{
		"name": "payments-initiation", "version": "1.1.0", "tenant_id": "banking-demo",
		"classification": "VH", "status": "draft",
		"endpoints": []any{map[string]any{
			"path": "/payments", "methods": []any{"POST"}, "backend_url": "http://backend:8080",
		}},
	}
	code, body = do(t, h, "PUT", "/api/v1/tenants/banking-demo/contracts/payments-initiation", alice,
		map[string]any{"contract": good, "message": "bump 1.1.0"})
	if code != 200 {
		t.Fatalf("PUT = %d %v", code, body)
	}
	commit := body["commit"].(map[string]any)
	if commit["sha7"] == "" || commit["signed"] != false {
		t.Fatalf("commit echo wrong: %v", commit)
	}
	if body["contract"].(map[string]any)["version"] != "1.1.0" {
		t.Fatalf("re-read contract wrong: %v", body["contract"])
	}

	// Publish -> status published + deploy.dev + evidence in ONE commit.
	code, body = do(t, h, "POST", "/api/v1/tenants/banking-demo/contracts/payments-initiation/publish", alice,
		map[string]any{"message": "mise en service dev"})
	if code != 200 {
		t.Fatalf("publish = %d %v", code, body)
	}
	evidence, _ := body["evidence"].(string)
	if !strings.HasPrefix(evidence, "evidence/banking-demo/payments-initiation/publish-") {
		t.Fatalf("evidence path = %q", evidence)
	}
	repoDir := srv.Store.Repo.Dir
	show := gitT(t, repoDir, "show", "--stat", "--format=%an|%s", "HEAD")
	for _, want := range []string{"Alice Martin|gov(banking-demo): publish payments-initiation",
		"deploy.dev.yaml", "publish-001.json", "publish-001.md", "api.yaml"} {
		if !strings.Contains(show, want) {
			t.Fatalf("publish commit missing %q:\n%s", want, show)
		}
	}
	detailCode, detail := do(t, h, "GET", "/api/v1/tenants/banking-demo/contracts/payments-initiation", alice, nil)
	if detailCode != 200 {
		t.Fatalf("detail = %d", detailCode)
	}
	if detail["contract"].(map[string]any)["status"] != "published" {
		t.Fatalf("status not published after publish: %v", detail["contract"])
	}
	if detail["deployments"].(map[string]any)["dev"] == nil {
		t.Fatalf("deploy.dev missing: %v", detail["deployments"])
	}
}

func TestPromotionFourEyes(t *testing.T) {
	srv, h, fix := newTestServer(t)
	admin := fix.sign(t, "carol", "Carol Admin", "", []string{"cpi-admin"})
	bob := fix.sign(t, "bob", "Bob Approver", "banking-demo", []string{"devops"})
	alice := fix.sign(t, "alice", "Alice Martin", "banking-demo", []string{"tenant-admin"})

	// Message is mandatory.
	code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions", admin,
		map[string]any{"slug": "payments-initiation", "from": "staging", "to": "production"})
	if code != 400 {
		t.Fatalf("missing message = %d %v", code, body)
	}
	// Chain must be valid.
	code, _ = do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions", admin,
		map[string]any{"slug": "payments-initiation", "from": "dev", "to": "production", "message": "saut interdit"})
	if code != 400 {
		t.Fatalf("dev->production must be rejected, got %d", code)
	}
	// Alice (tenant-admin) can request but NOT approve.
	code, body = do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions", admin,
		map[string]any{"slug": "payments-initiation", "from": "staging", "to": "production", "message": "passage en production T2"})
	if code != 200 {
		t.Fatalf("request = %d %v", code, body)
	}
	promo := body["promotion"].(map[string]any)
	promoID := promo["id"].(string)
	if promo["status"] != "pending" || !strings.Contains(promo["branch"].(string), "stoa/promote/banking-demo/payments-initiation/") {
		t.Fatalf("promotion shape: %v", promo)
	}

	// The review diff is a real git diff of the branch.
	code, body = do(t, h, "GET", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/diff", bob, nil)
	if code != 200 || !strings.Contains(body["diff"].(string), "deploy.production.yaml") {
		t.Fatalf("diff = %d %v", code, body)
	}

	// Alice cannot approve at all (no promotions:approve).
	code, body = do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", alice, nil)
	if code != 403 || errCode(body) != "FORBIDDEN" {
		t.Fatalf("alice approve = %d %v", code, body)
	}

	// 4-yeux: carol requested it, carol cannot approve her own production push.
	code, body = do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", admin,
		map[string]any{"message": "je tente"})
	if code != 403 || errCode(body) != "SELF_APPROVAL_BLOCKED" {
		t.Fatalf("self-approval = %d %v", code, body)
	}
	srv.WaitDenials()
	raw, err := os.ReadFile(filepath.Join(srv.Store.Repo.Dir, filepath.FromSlash(governance.DenialsPath)))
	if err != nil || !strings.Contains(string(raw), "SELF_APPROVAL_BLOCKED") {
		t.Fatalf("self-approval denial not in denials.jsonl: %v %q", err, raw)
	}

	// Bob (devops, distinct) approves: signed --no-ff merge + evidence.
	code, body = do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", bob,
		map[string]any{"message": "revue OK, fenêtre validée"})
	if code != 200 {
		t.Fatalf("bob approve = %d %v", code, body)
	}
	approved := body["promotion"].(map[string]any)
	if approved["status"] != "approved" || approved["approved_by"] != "bob" {
		t.Fatalf("approved promotion: %v", approved)
	}
	mc := body["merge_commit"].(map[string]any)
	parents := strings.Fields(strings.TrimSpace(gitT(t, srv.Store.Repo.Dir, "log", "-1", "--format=%P", mc["sha"].(string))))
	if len(parents) != 2 {
		t.Fatalf("approve must be a --no-ff merge, parents=%v", parents)
	}
	evPath, _ := body["evidence"].(string)
	if !strings.Contains(gitT(t, srv.Store.Repo.Dir, "show", "--stat", "--format=%s", "HEAD"), filepath.Base(evPath)) {
		t.Fatalf("evidence %s not inside the merge commit", evPath)
	}
	// The negative control of §6 references the blocked self-approval.
	evRaw := gitT(t, srv.Store.Repo.Dir, "show", "main:"+evPath)
	if !strings.Contains(evRaw, "SELF_APPROVAL") && !strings.Contains(evRaw, "auto-approbation") {
		t.Fatalf("evidence misses the negative control: %s", evRaw)
	}
	if !strings.Contains(evRaw, `"distinct": true`) {
		t.Fatalf("four_eyes check missing in evidence: %s", evRaw)
	}

	// Re-approving a settled promotion is a conflict.
	code, body = do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", bob, nil)
	if code != 409 {
		t.Fatalf("double approve = %d %v", code, body)
	}
}

func TestPromotionRejectIsMotivated(t *testing.T) {
	srv, h, fix := newTestServer(t)
	alice := fix.sign(t, "alice", "Alice Martin", "banking-demo", []string{"tenant-admin"})
	bob := fix.sign(t, "bob", "Bob Approver", "banking-demo", []string{"devops"})

	code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions", alice,
		map[string]any{"slug": "payments-initiation", "from": "dev", "to": "staging", "message": "vers staging"})
	if code != 200 {
		t.Fatalf("request = %d %v", code, body)
	}
	promoID := body["promotion"].(map[string]any)["id"].(string)

	// Reason mandatory.
	if code, _ := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/reject", bob, map[string]any{}); code != 400 {
		t.Fatalf("reject without reason = %d", code)
	}
	code, body = do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/reject", bob,
		map[string]any{"reason": "tests de charge incomplets"})
	if code != 200 {
		t.Fatalf("reject = %d %v", code, body)
	}
	rejected := body["promotion"].(map[string]any)
	if rejected["status"] != "rejected" || rejected["reason"] != "tests de charge incomplets" {
		t.Fatalf("rejected promotion: %v", rejected)
	}
	if br, _ := srv.Store.Repo.BranchesUnder(context.Background(), "stoa/promote"); len(br) != 0 {
		t.Fatalf("branch must be deleted after reject: %v", br)
	}
	// Pending list is empty, rejected shows with ?status=rejected.
	code, body = do(t, h, "GET", "/api/v1/tenants/banking-demo/promotions?status=rejected", alice, nil)
	if code != 200 || len(body["_list"].([]any)) != 1 {
		t.Fatalf("rejected listing = %d %v", code, body)
	}
}

func TestSubscriptionsScopedApproveReject(t *testing.T) {
	_, h, fix := newTestServer(t)
	alice := fix.sign(t, "alice", "Alice Martin", "banking-demo", []string{"tenant-admin"})
	stranger := fix.sign(t, "mallory", "Mallory Other", "other-corp", []string{"tenant-admin"})
	viewer := fix.sign(t, "eve", "Eve Auditor", "banking-demo", []string{"viewer"})

	// Scoping: the stranger sees nothing of banking-demo.
	code, body := do(t, h, "GET", "/api/v1/subscriptions", stranger, nil)
	if code != 200 || len(body["_list"].([]any)) != 0 {
		t.Fatalf("stranger subscriptions = %d %v", code, body)
	}
	// Viewer can read but not approve.
	if code, body := do(t, h, "POST", "/api/v1/subscriptions/sub-001/approve", viewer, nil); code != 403 || errCode(body) != "FORBIDDEN" {
		t.Fatalf("viewer approve = %d %v", code, body)
	}
	// Cross-tenant approve refused.
	if code, body := do(t, h, "POST", "/api/v1/subscriptions/sub-001/approve", stranger, nil); code != 403 {
		t.Fatalf("cross-tenant approve = %d %v", code, body)
	}
	// Reject requires a reason.
	if code, _ := do(t, h, "POST", "/api/v1/subscriptions/sub-001/reject", alice, map[string]any{}); code != 400 {
		t.Fatal("reject without reason must be 400")
	}
	// Approve commits + evidence.
	code, body = do(t, h, "POST", "/api/v1/subscriptions/sub-001/approve", alice, nil)
	if code != 200 {
		t.Fatalf("approve = %d %v", code, body)
	}
	sub := body["subscription"].(map[string]any)
	if sub["status"] != "approved" {
		t.Fatalf("subscription not approved: %v", sub)
	}
	if body["commit"].(map[string]any)["sha7"] == "" {
		t.Fatalf("commit echo missing: %v", body)
	}
}

func TestAuditTrailAndExport(t *testing.T) {
	_, h, fix := newTestServer(t)
	alice := fix.sign(t, "alice", "Alice Martin", "banking-demo", []string{"tenant-admin"})
	viewer := fix.sign(t, "eve", "Eve Auditor", "banking-demo", []string{"viewer"})

	// Generate one governed action.
	code, _ := do(t, h, "POST", "/api/v1/tenants/banking-demo/contracts/payments-initiation/publish", alice,
		map[string]any{"message": "publication initiale"})
	if code != 200 {
		t.Fatalf("publish = %d", code)
	}

	code, body := do(t, h, "GET", "/api/v1/audit?action=publish", viewer, nil)
	if code != 200 {
		t.Fatalf("audit = %d %v", code, body)
	}
	list := body["_list"].([]any)
	if len(list) != 1 {
		t.Fatalf("expected exactly the publish entry, got %v", list)
	}
	entry := list[0].(map[string]any)
	if entry["action"] != "publish" || entry["actor"] != "alice" || entry["resource"] != "banking-demo/payments-initiation" {
		t.Fatalf("audit entry: %v", entry)
	}
	if entry["evidence"] == "" || entry["sha7"] == "" {
		t.Fatalf("audit entry must link commit + evidence: %v", entry)
	}

	// Viewer has audit:read but NOT audit:export.
	if code, body := do(t, h, "GET", "/api/v1/audit/export?format=csv", viewer, nil); code != 403 || errCode(body) != "FORBIDDEN" {
		t.Fatalf("viewer export = %d %v", code, body)
	}
	req := httptest.NewRequest("GET", "/api/v1/audit/export?format=csv", nil)
	req.Header.Set("Authorization", "Bearer "+alice)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != 200 || !strings.Contains(rec.Header().Get("Content-Disposition"), "attachment") {
		t.Fatalf("export = %d %q", rec.Code, rec.Header().Get("Content-Disposition"))
	}
	if !strings.Contains(rec.Body.String(), "publish") {
		t.Fatalf("csv export misses the entry:\n%s", rec.Body.String())
	}
}

func TestSchemaCORSAndTargets(t *testing.T) {
	_, h, fix := newTestServer(t)
	viewer := fix.sign(t, "eve", "Eve Auditor", "banking-demo", []string{"viewer"})

	// Schema served raw to any authenticated user.
	code, body := do(t, h, "GET", "/api/v1/schema/uac", viewer, nil)
	if code != 200 || body["title"] != "UAC Contract v1.0" {
		t.Fatalf("schema = %d %v", code, body["title"])
	}

	// CORS preflight.
	req := httptest.NewRequest("OPTIONS", "/api/v1/me", nil)
	req.Header.Set("Origin", "http://localhost:5173")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != 204 || rec.Header().Get("Access-Control-Allow-Origin") != "http://localhost:5173" {
		t.Fatalf("preflight = %d %v", rec.Code, rec.Header())
	}

	// No TARGETS_FILE -> empty list, still 200 (never blocking).
	code, body = do(t, h, "GET", "/api/v1/targets", viewer, nil)
	if code != 200 || len(body["_list"].([]any)) != 0 {
		t.Fatalf("targets = %d %v", code, body)
	}
}
