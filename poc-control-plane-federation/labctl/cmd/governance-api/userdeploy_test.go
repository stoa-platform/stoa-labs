package main

// userdeploy_test.go — chaîne A (ADR-077) branchée sur promote-approve : le
// BFF échange le Bearer de l'APPROBATEUR (RFC 8693) et déclenche le webhook
// user-deploy avec le JWT échangé. Fakes httptest pour Keycloak et Jenkins —
// on vérifie le CONTRAT (grant_type, subject_token = jeton de l'approbateur,
// audience) et l'effet (payload vault_jwt), pas l'implémentation.

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeExchange serves a Keycloak token endpoint that validates the RFC 8693
// shape and returns exchangedJWT; it records the subject_token it saw.
type fakeExchange struct {
	mu           sync.Mutex
	subjectSeen  string
	audienceSeen string
	exchangedJWT string
	refuse       bool
}

func (f *fakeExchange) handler(t *testing.T) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Errorf("exchange: form invalide: %v", err)
		}
		if g := r.PostForm.Get("grant_type"); g != "urn:ietf:params:oauth:grant-type:token-exchange" {
			t.Errorf("grant_type = %q", g)
		}
		if st := r.PostForm.Get("subject_token_type"); st != "urn:ietf:params:oauth:token-type:access_token" {
			t.Errorf("subject_token_type = %q", st)
		}
		if cid := r.PostForm.Get("client_id"); cid != "vault-exchange" {
			t.Errorf("client_id = %q", cid)
		}
		f.mu.Lock()
		f.subjectSeen = r.PostForm.Get("subject_token")
		f.audienceSeen = r.PostForm.Get("audience")
		f.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		if f.refuse {
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "invalid_token", "error_description": "subject non adressé"})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"access_token": f.exchangedJWT})
	}
}

// seen returns the recorded subject_token/audience under the mutex (les
// écritures viennent des goroutines du serveur httptest — jamais de lecture
// nue, le test doit passer sous -race).
func (f *fakeExchange) seen() (subject, audience string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.subjectSeen, f.audienceSeen
}

// fakeWebhook records the generic-webhook-trigger payloads it receives.
type fakeWebhook struct {
	mu       sync.Mutex
	payloads []map[string]string
}

// list returns a copy of the recorded payloads under the mutex.
func (f *fakeWebhook) list() []map[string]string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]map[string]string(nil), f.payloads...)
}

func (f *fakeWebhook) handler(t *testing.T) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		var p map[string]string
		if err := json.Unmarshal(raw, &p); err != nil {
			t.Errorf("webhook: payload non-JSON: %v", err)
		}
		f.mu.Lock()
		f.payloads = append(f.payloads, p)
		f.mu.Unlock()
		w.WriteHeader(http.StatusOK)
	}
}

// newFakeUserDeploy wires a UserDeploy against the two fakes.
func newFakeUserDeploy(t *testing.T, fx *fakeExchange, fw *fakeWebhook) (*UserDeploy, func()) {
	kc := httptest.NewServer(fx.handler(t))
	hook := httptest.NewServer(fw.handler(t))
	u := &UserDeploy{
		TokenURL:     kc.URL, // le chemin exact du realm est déjà résolu par NewUserDeployFromEnv
		ClientID:     "vault-exchange",
		ClientSecret: "s3cret",
		Audience:     "vault",
		WebhookURL:   hook.URL + "/generic-webhook-trigger/invoke?token=stoa-user-deploy",
		HTTP:         &http.Client{Timeout: 5 * time.Second},
	}
	return u, func() { kc.Close(); hook.Close() }
}

func TestUserDeployDispatchContract(t *testing.T) {
	fx := &fakeExchange{exchangedJWT: "exchanged.jwt.aud-vault"}
	fw := &fakeWebhook{}
	u, done := newFakeUserDeploy(t, fx, fw)
	defer done()

	if err := u.Dispatch(t.Context(), "bearer-de-bob", "promote-approve banking-demo/pr-1 par bob"); err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	subject, audience := fx.seen()
	if subject != "bearer-de-bob" {
		t.Errorf("subject_token vu = %q (attendu le Bearer de l'approbateur)", subject)
	}
	if audience != "vault" {
		t.Errorf("audience = %q", audience)
	}
	payloads := fw.list()
	if len(payloads) != 1 || payloads[0]["vault_jwt"] != "exchanged.jwt.aud-vault" {
		t.Fatalf("webhook payloads = %v (attendu vault_jwt = JWT échangé)", payloads)
	}
	if !strings.Contains(payloads[0]["hint"], "par bob") {
		t.Errorf("hint = %q", payloads[0]["hint"])
	}
}

func TestUserDeployExchangeRefusedNoWebhook(t *testing.T) {
	fx := &fakeExchange{refuse: true}
	fw := &fakeWebhook{}
	u, done := newFakeUserDeploy(t, fx, fw)
	defer done()

	err := u.Dispatch(t.Context(), "token-de-service-non-adresse", "hint")
	if err == nil || !strings.Contains(err.Error(), "invalid_token") {
		t.Fatalf("err = %v (refus d'exchange attendu, avec le code KC mais JAMAIS le jeton)", err)
	}
	if strings.Contains(err.Error(), "token-de-service-non-adresse") {
		t.Errorf("le message d'erreur porte le jeton: %v", err)
	}
	if p := fw.list(); len(p) != 0 {
		t.Errorf("le webhook ne doit PAS être déclenché quand l'exchange est refusé (payloads=%v)", p)
	}
}

// TestApproveDispatchesUserDeploy exerce le hook complet : request (carol) →
// approve (bob) → le webhook reçoit le JWT échangé DEPUIS le Bearer de bob,
// et la réponse d'approve porte user_deploy=dispatched.
func TestApproveDispatchesUserDeploy(t *testing.T) {
	srv, h, fix := newTestServer(t)
	admin := fix.sign(t, "carol", "Carol Admin", "", []string{"cpi-admin"})
	bob := fix.sign(t, "bob", "Bob Approver", "banking-demo", []string{"devops"})

	fx := &fakeExchange{exchangedJWT: "exchanged.jwt.bob"}
	fw := &fakeWebhook{}
	u, done := newFakeUserDeploy(t, fx, fw)
	defer done()
	srv.UserDeploy = u

	code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions", admin,
		map[string]any{"slug": "payments-initiation", "from": "staging", "to": "production", "message": "T2"})
	if code != 200 {
		t.Fatalf("request = %d %v", code, body)
	}
	promoID := body["promotion"].(map[string]any)["id"].(string)

	code, body = do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", bob,
		map[string]any{"message": "revue OK"})
	if code != 200 {
		t.Fatalf("approve = %d %v", code, body)
	}
	if body["user_deploy"] != "dispatched" {
		t.Fatalf("user_deploy = %v (attendu dispatched)", body["user_deploy"])
	}
	srv.WaitDispatches()

	subject, _ := fx.seen()
	if subject != bob {
		t.Errorf("subject_token = le Bearer de bob attendu (vu %.20q…)", subject)
	}
	payloads := fw.list()
	if len(payloads) != 1 || payloads[0]["vault_jwt"] != "exchanged.jwt.bob" {
		t.Fatalf("webhook = %v", payloads)
	}
	if !strings.Contains(payloads[0]["hint"], "banking-demo/"+promoID) || !strings.Contains(payloads[0]["hint"], "par bob") {
		t.Errorf("hint = %q", payloads[0]["hint"])
	}
}

// TestApproveDeniedNoDispatch : un approve REFUSÉ (4-yeux) ne doit JAMAIS
// déclencher d'exchange ni de webhook — le dispatcher n'est atteint qu'après
// les gates.
func TestApproveDeniedNoDispatch(t *testing.T) {
	srv, h, fix := newTestServer(t)
	admin := fix.sign(t, "carol", "Carol Admin", "", []string{"cpi-admin"})

	fx := &fakeExchange{exchangedJWT: "never.issued"}
	fw := &fakeWebhook{}
	u, done := newFakeUserDeploy(t, fx, fw)
	defer done()
	srv.UserDeploy = u

	code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions", admin,
		map[string]any{"slug": "payments-initiation", "from": "staging", "to": "production", "message": "T2"})
	if code != 200 {
		t.Fatalf("request = %d %v", code, body)
	}
	promoID := body["promotion"].(map[string]any)["id"].(string)

	// carol tente d'approuver SA promotion → 403 SELF_APPROVAL_BLOCKED.
	code, body = do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", admin,
		map[string]any{"message": "je tente"})
	if code != 403 || errCode(body) != "SELF_APPROVAL_BLOCKED" {
		t.Fatalf("self-approval = %d %v", code, body)
	}
	srv.WaitDenials()
	srv.WaitDispatches()
	if subject, _ := fx.seen(); subject != "" {
		t.Errorf("un refus a déclenché un exchange (subject vu %.20q…)", subject)
	}
	if p := fw.list(); len(p) != 0 {
		t.Errorf("un refus a déclenché le webhook: %v", p)
	}
}

// TestApproveExchangeRefusedStillApproved : LE verrou de la propriété « le
// dispatch est un effet, pas un gate » — l'exchange refusé n'affecte ni le 200
// ni le merge ; le webhook n'est pas appelé.
func TestApproveExchangeRefusedStillApproved(t *testing.T) {
	srv, h, fix := newTestServer(t)
	admin := fix.sign(t, "carol", "Carol Admin", "", []string{"cpi-admin"})
	bob := fix.sign(t, "bob", "Bob Approver", "banking-demo", []string{"devops"})

	fx := &fakeExchange{refuse: true}
	fw := &fakeWebhook{}
	u, done := newFakeUserDeploy(t, fx, fw)
	defer done()
	srv.UserDeploy = u

	code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions", admin,
		map[string]any{"slug": "payments-initiation", "from": "staging", "to": "production", "message": "T2"})
	if code != 200 {
		t.Fatalf("request = %d %v", code, body)
	}
	promoID := body["promotion"].(map[string]any)["id"].(string)

	code, body = do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", bob,
		map[string]any{"message": "revue OK"})
	if code != 200 {
		t.Fatalf("approve doit rester 200 même si l'exchange échoue, got %d %v", code, body)
	}
	if body["user_deploy"] != "dispatched" {
		t.Fatalf("user_deploy = %v", body["user_deploy"])
	}
	if body["promotion"].(map[string]any)["status"] != "approved" {
		t.Fatalf("la promotion doit être approved: %v", body["promotion"])
	}
	srv.WaitDispatches()
	if p := fw.list(); len(p) != 0 {
		t.Errorf("exchange refusé → le webhook ne doit pas partir: %v", p)
	}
}

// TestApproveWithoutUserDeployUnchanged : wiring absent (nil) → réponse
// user_deploy=not_configured, aucun effet de bord.
func TestApproveWithoutUserDeployUnchanged(t *testing.T) {
	_, h, fix := newTestServer(t)
	admin := fix.sign(t, "carol", "Carol Admin", "", []string{"cpi-admin"})
	bob := fix.sign(t, "bob", "Bob Approver", "banking-demo", []string{"devops"})

	code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions", admin,
		map[string]any{"slug": "payments-initiation", "from": "staging", "to": "production", "message": "T2"})
	if code != 200 {
		t.Fatalf("request = %d %v", code, body)
	}
	promoID := body["promotion"].(map[string]any)["id"].(string)

	code, body = do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", bob,
		map[string]any{"message": "revue OK"})
	if code != 200 || body["user_deploy"] != "not_configured" {
		t.Fatalf("approve = %d user_deploy=%v", code, body["user_deploy"])
	}
}

func TestNewUserDeployFromEnvOptIn(t *testing.T) {
	t.Setenv("USER_DEPLOY_WEBHOOK_URL", "")
	t.Setenv("VAULT_EXCHANGE_SECRET", "")
	t.Setenv("VAULT_EXCHANGE_SECRET_FILE", "")
	if u := NewUserDeployFromEnv("http://kc:8480", "stoa-lab"); u != nil {
		t.Fatalf("sans env, UserDeploy doit être nil (flux A7 inchangé)")
	}
	t.Setenv("USER_DEPLOY_WEBHOOK_URL", "http://jenkins:8080/generic-webhook-trigger/invoke?token=x")
	t.Setenv("VAULT_EXCHANGE_SECRET", "s")
	u := NewUserDeployFromEnv("http://kc:8480/", "stoa-lab")
	if u == nil || u.TokenURL != "http://kc:8480/realms/stoa-lab/protocol/openid-connect/token" ||
		u.ClientID != "vault-exchange" || u.Audience != "vault" {
		t.Fatalf("config depuis env inattendue: %+v", u)
	}
}
