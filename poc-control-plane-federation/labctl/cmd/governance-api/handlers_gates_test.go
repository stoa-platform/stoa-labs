package main

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/governance"
)

// ---- fixtures: configurable chain (environments.yaml) + groups + ITSM ----

// chainYAML is the bank-style 4-environment pipeline under test: self-approval
// into rec, group-gated int, fully gated prod (4-eyes + refs + ITSM).
const chainYAML = `environments: [dev, rec, int, prod]
gates:
  - {to: rec, selfApproval: true}
  - {to: int, approverGroup: integration-team}
  - {to: prod, fourEyes: true, requireChangeRef: true, requirePVRef: true, itsmCheck: true}
`

const chainSeedDeploy = "version: 1.0.0\nenabled: true\npromoted_by: seed\n"

// seedChainRepo builds a governance repo carrying environments.yaml and one
// published contract deployed in dev; extra adds more files to the seed commit
// (deploy.rec.yaml, deploy.int.yaml... depending on the hop under test).
func seedChainRepo(t *testing.T, extra map[string]string) *governance.Repo {
	t.Helper()
	dir := t.TempDir()
	gitT(t, dir, "init", "-b", "main")
	gitT(t, dir, "config", "user.name", "seed")
	gitT(t, dir, "config", "user.email", "seed@test.local")
	gitT(t, dir, "config", "commit.gpgsign", "false")

	files := map[string]string{
		"environments.yaml":                "id: banking-demo\n",
		"tenants/banking-demo/tenant.yaml": "id: banking-demo\nname: banking-demo\ndisplayName: Banking Demo\ntier: gold\nstatus: active\n",
		"tenants/banking-demo/apis/payments-initiation/api.yaml": `name: payments-initiation
version: 1.0.0
tenant_id: banking-demo
classification: VH
status: published
endpoints:
  - path: /payments
    methods: ["POST"]
    backend_url: http://backend:8080
`,
		"tenants/banking-demo/apis/payments-initiation/deploy.dev.yaml": chainSeedDeploy,
	}
	files["environments.yaml"] = chainYAML
	for p, c := range extra {
		files[p] = c
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
	gitT(t, dir, "commit", "-m", "seed: banking-demo with custom env chain")

	repo, err := governance.OpenRepo(dir)
	if err != nil {
		t.Fatalf("OpenRepo: %v", err)
	}
	return repo
}

// newChainServer wires a Server on a chain-configured repo; itsmURL "" leaves
// the ITSM unconfigured (the fail-closed path).
func newChainServer(t *testing.T, extra map[string]string, itsmURL string) (*Server, http.Handler, *authFixture) {
	t.Helper()
	fix, verifier := newAuthFixture(t)
	srv := &Server{
		Store:    &governance.Store{Repo: seedChainRepo(t, extra)},
		Verifier: verifier,
		KC:       governance.NewKCAdmin("http://127.0.0.1:1", "stoa-lab", "admin", "admin"),
		Schema:   uacSchema,
		ITSM:     governance.NewITSMClient(itsmURL),
	}
	t.Cleanup(srv.WaitDenials)
	return srv, srv.Handler(), fix
}

// signGroups mints a token carrying a `groups` claim on top of the fixture key
// (the standard sign() has no groups — the gate must read the claim, not roles).
func signGroups(t *testing.T, fix *authFixture, username, name, tenant string, roles, groups []string) string {
	t.Helper()
	header, _ := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT", "kid": "test-key"})
	payload, _ := json.Marshal(map[string]any{
		"iss":                fix.issuer,
		"exp":                time.Now().Add(time.Hour).Unix(),
		"preferred_username": username,
		"name":               name,
		"email":              username + "@bank.example",
		"tenant":             tenant,
		"groups":             groups,
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

// itsmStub serves GET /changes/{id} from a mutable map (mutex'd so tests can
// flip a change status mid-flight).
type itsmStub struct {
	mu       sync.Mutex
	statuses map[string]string
}

func (s *itsmStub) set(id, status string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.statuses[id] = status
}

func newITSMStub(t *testing.T, statuses map[string]string) (*itsmStub, *httptest.Server) {
	t.Helper()
	stub := &itsmStub{statuses: statuses}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.URL.Path, "/changes/")
		stub.mu.Lock()
		st, ok := stub.statuses[id]
		stub.mu.Unlock()
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{"id": id, "status": st})
	}))
	t.Cleanup(srv.Close)
	return stub, srv
}

// requestPromotion POSTs a promotion and returns its id.
func requestPromotion(t *testing.T, h http.Handler, token string, body map[string]any) string {
	t.Helper()
	code, resp := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions", token, body)
	if code != 200 {
		t.Fatalf("promotion request = %d %v", code, resp)
	}
	return resp["promotion"].(map[string]any)["id"].(string)
}

// ---- tests: configurable chain & per-hop gates ----

func TestChainInvalidHopListsTheChain(t *testing.T) {
	_, h, fix := newChainServer(t, nil, "")
	alice := fix.sign(t, "alice", "Alice Martin", "banking-demo", []string{"tenant-admin"})

	// dev→prod skips rec and int: refused, message lists the CONFIGURED chain.
	code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions", alice,
		map[string]any{"slug": "payments-initiation", "from": "dev", "to": "prod", "message": "saut interdit"})
	if code != 400 {
		t.Fatalf("dev->prod = %d %v", code, body)
	}
	msg := body["error"].(map[string]any)["message"].(string)
	if !strings.Contains(msg, "dev→rec, rec→int, int→prod") {
		t.Fatalf("error message must list the configured chain, got %q", msg)
	}
	// dev→staging is no longer a valid hop on this chain.
	if code, _ := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions", alice,
		map[string]any{"slug": "payments-initiation", "from": "dev", "to": "staging", "message": "ancienne chaîne"}); code != 400 {
		t.Fatalf("dev->staging on custom chain = %d, want 400", code)
	}
}

func TestChainSelfApprovalAllowedAndPinned(t *testing.T) {
	srv, h, fix := newChainServer(t, nil, "")
	carol := fix.sign(t, "carol", "Carol Admin", "", []string{"cpi-admin"})

	promoID := requestPromotion(t, h, carol,
		map[string]any{"slug": "payments-initiation", "from": "dev", "to": "rec", "message": "vers rec"})

	// selfApproval hop: carol requested AND approves — no fourEyes on rec.
	code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", carol,
		map[string]any{"message": "auto-approbation autorisée vers rec"})
	if code != 200 {
		t.Fatalf("self-approve dev->rec = %d %v", code, body)
	}
	if body["promotion"].(map[string]any)["status"] != "approved" {
		t.Fatalf("promotion not approved: %v", body)
	}

	// Real pinning: the merged deploy.rec.yaml pins the api.yaml main SHA.
	repoDir := srv.Store.Repo.Dir
	contractSHA := strings.TrimSpace(gitT(t, repoDir, "log", "-1", "--format=%H", "main", "--",
		"tenants/banking-demo/apis/payments-initiation/api.yaml"))
	deployRaw := gitT(t, repoDir, "show", "main:tenants/banking-demo/apis/payments-initiation/deploy.rec.yaml")
	if !strings.Contains(deployRaw, "commit: "+contractSHA) {
		t.Fatalf("deploy.rec.yaml must pin the contract SHA %s:\n%s", contractSHA, deployRaw)
	}
}

func TestChainGroupGate(t *testing.T) {
	srv, h, fix := newChainServer(t, map[string]string{
		"tenants/banking-demo/apis/payments-initiation/deploy.rec.yaml": chainSeedDeploy,
	}, "")
	alice := fix.sign(t, "alice", "Alice Martin", "banking-demo", []string{"tenant-admin"})
	bobNoGroup := fix.sign(t, "bob", "Bob Approver", "banking-demo", []string{"devops"})
	bobInGroup := signGroups(t, fix, "bob", "Bob Approver", "banking-demo", []string{"devops"}, []string{"integration-team"})

	promoID := requestPromotion(t, h, alice,
		map[string]any{"slug": "payments-initiation", "from": "rec", "to": "int", "message": "vers int"})

	// Outside the gate group: 403, audited.
	code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", bobNoGroup,
		map[string]any{"message": "je tente sans le groupe"})
	if code != 403 || errCode(body) != "GATE_GROUP_REQUIRED" {
		t.Fatalf("approve without group = %d %v", code, body)
	}
	srv.WaitDenials()
	raw, err := os.ReadFile(filepath.Join(srv.Store.Repo.Dir, filepath.FromSlash(governance.DenialsPath)))
	if err != nil || !strings.Contains(string(raw), "GATE_GROUP_REQUIRED") {
		t.Fatalf("group denial not audited: %v %q", err, raw)
	}

	// Same user WITH the groups claim: approved.
	code, body = do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", bobInGroup,
		map[string]any{"message": "revue intégration OK"})
	if code != 200 || body["promotion"].(map[string]any)["status"] != "approved" {
		t.Fatalf("approve with group = %d %v", code, body)
	}
}

func TestChainProdGateRefsRequiredAtRequest(t *testing.T) {
	_, h, fix := newChainServer(t, map[string]string{
		"tenants/banking-demo/apis/payments-initiation/deploy.int.yaml": chainSeedDeploy,
	}, "")
	alice := fix.sign(t, "alice", "Alice Martin", "banking-demo", []string{"tenant-admin"})

	// No change_ref: refused at REQUEST time (fail at the earliest).
	code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions", alice,
		map[string]any{"slug": "payments-initiation", "from": "int", "to": "prod", "message": "vers prod"})
	if code != 400 || errCode(body) != "GATE_REFS_REQUIRED" {
		t.Fatalf("int->prod without change_ref = %d %v", code, body)
	}
	// change_ref but no pv_ref: still refused.
	code, body = do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions", alice,
		map[string]any{"slug": "payments-initiation", "from": "int", "to": "prod", "message": "vers prod", "change_ref": "CHG-0001"})
	if code != 400 || errCode(body) != "GATE_REFS_REQUIRED" {
		t.Fatalf("int->prod without pv_ref = %d %v", code, body)
	}
}

func TestChainProdITSMGate(t *testing.T) {
	stub, itsm := newITSMStub(t, map[string]string{"CHG-0042": "draft"})
	srv, h, fix := newChainServer(t, map[string]string{
		"tenants/banking-demo/apis/payments-initiation/deploy.int.yaml": chainSeedDeploy,
	}, itsm.URL)
	alice := fix.sign(t, "alice", "Alice Martin", "banking-demo", []string{"tenant-admin"})
	bob := fix.sign(t, "bob", "Bob Approver", "banking-demo", []string{"devops"})

	promoID := requestPromotion(t, h, alice, map[string]any{
		"slug": "payments-initiation", "from": "int", "to": "prod",
		"message": "MEP T3", "change_ref": "CHG-0042", "pv_ref": "PV-2026-17",
	})

	// Refs are stored on the marker.
	code, body := do(t, h, "GET", "/api/v1/tenants/banking-demo/promotions?status=pending", alice, nil)
	if code != 200 || !strings.Contains(string(mustJSON(t, body["_list"])), "CHG-0042") {
		t.Fatalf("pending promotion must carry change_ref: %d %v", code, body)
	}

	// Change still draft in the ITSM: 409, audited, branch intact.
	code, body = do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", bob,
		map[string]any{"message": "fenêtre validée"})
	if code != 409 || errCode(body) != "ITSM_NOT_APPROVED" {
		t.Fatalf("approve with draft change = %d %v", code, body)
	}
	srv.WaitDenials()

	// The change gets approved in the ITSM: the same approval now passes.
	stub.set("CHG-0042", "approved")
	code, body = do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", bob,
		map[string]any{"message": "fenêtre validée, CHG approuvé"})
	if code != 200 {
		t.Fatalf("approve with approved change = %d %v", code, body)
	}
	// Evidence carries the gate evaluation (hop, ITSM verdict, pv_ref).
	evPath, _ := body["evidence"].(string)
	evRaw := gitT(t, srv.Store.Repo.Dir, "show", "main:"+evPath)
	for _, want := range []string{`"hop": "int→prod"`, `"change_ref": "CHG-0042"`, `"status": "approved"`, `"pv_ref": "PV-2026-17"`} {
		if !strings.Contains(evRaw, want) {
			t.Fatalf("evidence gate check missing %q:\n%s", want, evRaw)
		}
	}
}

func TestChainProdITSMFailClosed(t *testing.T) {
	// ITSM unreachable (dead port): 503, never approved.
	_, h, fix := newChainServer(t, map[string]string{
		"tenants/banking-demo/apis/payments-initiation/deploy.int.yaml": chainSeedDeploy,
	}, "http://127.0.0.1:1")
	alice := fix.sign(t, "alice", "Alice Martin", "banking-demo", []string{"tenant-admin"})
	bob := fix.sign(t, "bob", "Bob Approver", "banking-demo", []string{"devops"})

	promoID := requestPromotion(t, h, alice, map[string]any{
		"slug": "payments-initiation", "from": "int", "to": "prod",
		"message": "MEP", "change_ref": "CHG-0001", "pv_ref": "PV-1",
	})
	code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", bob, nil)
	if code != 503 || errCode(body) != "ITSM_UNAVAILABLE" {
		t.Fatalf("approve with ITSM down = %d %v", code, body)
	}

	// ITSM not configured at all (nil client): 503 as well — never a pass.
	_, h2, fix2 := newChainServer(t, map[string]string{
		"tenants/banking-demo/apis/payments-initiation/deploy.int.yaml": chainSeedDeploy,
	}, "")
	alice2 := fix2.sign(t, "alice", "Alice Martin", "banking-demo", []string{"tenant-admin"})
	bob2 := fix2.sign(t, "bob", "Bob Approver", "banking-demo", []string{"devops"})
	promoID2 := requestPromotion(t, h2, alice2, map[string]any{
		"slug": "payments-initiation", "from": "int", "to": "prod",
		"message": "MEP", "change_ref": "CHG-0001", "pv_ref": "PV-1",
	})
	code, body = do(t, h2, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID2+"/approve", bob2, nil)
	if code != 503 || errCode(body) != "ITSM_NOT_CONFIGURED" {
		t.Fatalf("approve without ITSM client = %d %v", code, body)
	}
}

// The DEFAULT chain (no environments.yaml) still blocks production
// self-approval — and the pin now guards request→approve drift everywhere.
func TestContractMovedBetweenRequestAndApprove(t *testing.T) {
	srv, h, fix := newTestServer(t)
	alice := fix.sign(t, "alice", "Alice Martin", "banking-demo", []string{"tenant-admin"})
	bob := fix.sign(t, "bob", "Bob Approver", "banking-demo", []string{"devops"})

	code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions", alice,
		map[string]any{"slug": "payments-initiation", "from": "dev", "to": "staging", "message": "vers staging"})
	if code != 200 {
		t.Fatalf("request = %d %v", code, body)
	}
	promoID := body["promotion"].(map[string]any)["id"].(string)

	// The contract moves on main between request and approval.
	moved := map[string]any{
		"name": "payments-initiation", "version": "1.2.0", "tenant_id": "banking-demo",
		"classification": "VH", "status": "draft",
		"endpoints": []any{map[string]any{
			"path": "/payments", "methods": []any{"POST"}, "backend_url": "http://backend:8080",
		}},
	}
	if code, body := do(t, h, "PUT", "/api/v1/tenants/banking-demo/contracts/payments-initiation", alice,
		map[string]any{"contract": moved, "message": "bump pendant la revue"}); code != 200 {
		t.Fatalf("PUT = %d %v", code, body)
	}

	code, body = do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", bob,
		map[string]any{"message": "j'approuve l'ancien texte"})
	if code != 409 || errCode(body) != "CONTRACT_MOVED" {
		t.Fatalf("approve after contract moved = %d %v", code, body)
	}
	srv.WaitDenials()
	raw, err := os.ReadFile(filepath.Join(srv.Store.Repo.Dir, filepath.FromSlash(governance.DenialsPath)))
	if err != nil || !strings.Contains(string(raw), "CONTRACT_MOVED") {
		t.Fatalf("CONTRACT_MOVED denial not audited: %v %q", err, raw)
	}
}

// mustJSON marshals for substring assertions on decoded fragments.
func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
