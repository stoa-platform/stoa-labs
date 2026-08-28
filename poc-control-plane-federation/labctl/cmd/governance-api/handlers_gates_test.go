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

// ---- the SHIPPED 5-hop chain, hop by hop (G2, ADR-084) ----

// shippedChainTemplate is the chain template that ACTUALLY ships (couche CONFIG
// CLIENT). envchain_shipped_test.go proves that file PARSES; the tests below run
// its gates through the real approve handler, so a relaxed gate stops REFUSING
// here — which is what a client would actually feel.
const shippedChainTemplate = "../../../clients/_example/environments.yaml"

func shippedChainYAML(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile(shippedChainTemplate)
	if err != nil {
		t.Fatalf("read %s: %v", shippedChainTemplate, err)
	}
	return string(raw)
}

// newShippedChainServer wires a Server whose environments.yaml is the given
// chain (the shipped template, or a variant of it), with deploy.<from>.yaml
// seeded so the hop under test has something to promote. The seed already
// carries deploy.dev.yaml, the head of the chain.
func newShippedChainServer(t *testing.T, chain, from string) (*Server, http.Handler, *authFixture) {
	t.Helper()
	extra := map[string]string{"environments.yaml": chain}
	if from != "dev" {
		extra["tenants/banking-demo/apis/payments-initiation/deploy."+from+".yaml"] = chainSeedDeploy
	}
	return newChainServer(t, extra, "")
}

// TestShippedChainPerHopGateRefusals replays the two approval refusals on EVERY
// hop the shipped chain adds. A gate is per-hop DATA, not code: proving 4-eyes
// on production proves nothing about int or homol — each new palier gets its own
// row, or it ships unproven.
func TestShippedChainPerHopGateRefusals(t *testing.T) {
	chain := shippedChainYAML(t)
	for _, tc := range []struct {
		name           string
		from, to       string
		refs           bool     // this hop demands change_ref/pv_ref AT REQUEST
		selfApprove    bool     // the requester approves their own promotion
		approverGroups []string // `groups` claim (Keycloak) of whoever approves
		wantErr        string
	}{
		// 4-eyes bites even when the approver IS in the gate's group: being
		// entitled to approve this hop never means approving one's own.
		{"int/self-approval-though-in-int-team", "rec", "int", false, true, []string{"int-team"}, "SELF_APPROVAL_BLOCKED"},
		{"homol/self-approval-though-in-release-team", "int", "homol", true, true, []string{"release-team"}, "SELF_APPROVAL_BLOCKED"},
		// The group names WHO. A distinct third party outside it is refused —
		// and holding the NEIGHBOURING hop's group is not holding this one's.
		{"int/third-party-without-int-team", "rec", "int", false, false, []string{"release-team"}, "GATE_GROUP_REQUIRED"},
		{"homol/third-party-without-release-team", "int", "homol", true, false, []string{"int-team"}, "GATE_GROUP_REQUIRED"},
		{"prod/third-party-without-release-team", "homol", "prod", true, false, []string{"int-team"}, "GATE_GROUP_REQUIRED"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv, h, fix := newShippedChainServer(t, chain, tc.from)
			// cpi-admin is the only role holding request AND approve, so the
			// only principal who can even ATTEMPT a self-approval.
			carol := signGroups(t, fix, "carol", "Carol Admin", "", []string{"cpi-admin"}, tc.approverGroups)
			alice := fix.sign(t, "alice", "Alice Martin", "banking-demo", []string{"tenant-admin"})
			bob := signGroups(t, fix, "bob", "Bob Approver", "banking-demo", []string{"devops"}, tc.approverGroups)

			req := map[string]any{"slug": "payments-initiation", "from": tc.from, "to": tc.to, "message": "vers " + tc.to}
			if tc.refs {
				req["change_ref"], req["pv_ref"] = "CHG-0042", "PV-2026-17"
			}
			requester, approver := alice, bob
			if tc.selfApprove {
				requester, approver = carol, carol
			}
			promoID := requestPromotion(t, h, requester, req)

			code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", approver,
				map[string]any{"message": "j'approuve"})
			if code != 403 || errCode(body) != tc.wantErr {
				t.Fatalf("approve %s→%s = %d %v, want 403 %s", tc.from, tc.to, code, body, tc.wantErr)
			}
			// A gate that refuses silently is a gate nobody can prove refused.
			srv.WaitDenials()
			raw, err := os.ReadFile(filepath.Join(srv.Store.Repo.Dir, filepath.FromSlash(governance.DenialsPath)))
			if err != nil || !strings.Contains(string(raw), tc.wantErr) {
				t.Fatalf("%s not audited in denials.jsonl: %v %q", tc.wantErr, err, raw)
			}
		})
	}
}

// TestShippedChainRecFourEyesVariant exercises DÉCISION CLIENT n°1. The template
// ships `rec` autonomous (selfApproval, documentary only) and its comment claims
// that closing the DORA art. 17(1)(b) tension is "une ligne". This test adds
// exactly that line and checks it BITES — a promise about a config line is worth
// what its refusal is worth.
func TestShippedChainRecFourEyesVariant(t *testing.T) {
	const recGate = "  - to: rec\n    selfApproval: true\n"
	chain := shippedChainYAML(t)
	if !strings.Contains(chain, recGate) {
		t.Fatalf("the shipped rec gate no longer reads:\n%s— re-anchor this variant on the template", recGate)
	}
	variant := strings.Replace(chain, recGate, recGate+"    fourEyes: true\n", 1)

	srv, h, fix := newShippedChainServer(t, variant, "dev")
	carol := signGroups(t, fix, "carol", "Carol Admin", "", []string{"cpi-admin"}, nil)
	promoID := requestPromotion(t, h, carol,
		map[string]any{"slug": "payments-initiation", "from": "dev", "to": "rec", "message": "vers rec"})
	code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", carol,
		map[string]any{"message": "je m'auto-approuve comme avant"})
	if code != 403 || errCode(body) != "SELF_APPROVAL_BLOCKED" {
		t.Fatalf("rec self-approve WITH fourEyes = %d %v, want 403 SELF_APPROVAL_BLOCKED", code, body)
	}
	srv.WaitDenials()

	// Contre-épreuve on the UNMODIFIED template: the very same self-approval
	// passes. The refusal above comes from that one line and nothing else.
	_, h2, fix2 := newShippedChainServer(t, chain, "dev")
	carol2 := signGroups(t, fix2, "carol", "Carol Admin", "", []string{"cpi-admin"}, nil)
	promoID2 := requestPromotion(t, h2, carol2,
		map[string]any{"slug": "payments-initiation", "from": "dev", "to": "rec", "message": "vers rec"})
	code, body = do(t, h2, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID2+"/approve", carol2,
		map[string]any{"message": "auto-approbation autorisée vers rec"})
	if code != 200 || body["promotion"].(map[string]any)["status"] != "approved" {
		t.Fatalf("rec self-approve on the shipped chain = %d %v, want 200 approved", code, body)
	}
}

// TestShippedChainApproveEvidenceNamesTheDeployer proves the approval record
// carries the THIRD axis: WHO may carry the apply. bob holds int-team (the
// Keycloak claim the gate reads) and NOT apim-apply-int (the LDAP group behind
// the Vault policy) — and his approval passes: the deployer axis is MATERIALISED
// in the evidence, never EVALUATED here. The refusal lives at dispatch.
func TestShippedChainApproveEvidenceNamesTheDeployer(t *testing.T) {
	srv, h, fix := newShippedChainServer(t, shippedChainYAML(t), "rec")
	alice := fix.sign(t, "alice", "Alice Martin", "banking-demo", []string{"tenant-admin"})
	bob := signGroups(t, fix, "bob", "Bob Approver", "banking-demo", []string{"devops"}, []string{"int-team"})

	promoID := requestPromotion(t, h, alice,
		map[string]any{"slug": "payments-initiation", "from": "rec", "to": "int", "message": "vers int"})
	code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", bob,
		map[string]any{"message": "revue intégration OK"})
	if code != 200 {
		t.Fatalf("approve rec→int = %d %v", code, body)
	}
	evPath, _ := body["evidence"].(string)
	evRaw := gitT(t, srv.Store.Repo.Dir, "show", "main:"+evPath)
	for _, want := range []string{`"hop": "rec→int"`, `"approver_group": "int-team"`, `"deployer_group": "apim-apply-int"`} {
		if !strings.Contains(evRaw, want) {
			t.Fatalf("evidence gate check missing %q:\n%s", want, evRaw)
		}
	}
}
