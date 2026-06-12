package keycloak

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
)

// fakeKeycloak emulates the slice of the Keycloak Admin REST API EnsureClient
// touches: the master-realm token endpoint, the clients list/create endpoints,
// and the per-client client-secret read. It is stateful so the same server can
// back both the "create" and the "already exists" (idempotent) assertions.
type fakeKeycloak struct {
	t      *testing.T
	mu     sync.Mutex
	realm  string
	uuid   string // assigned on create
	secret string

	// recorders for adversarial assertions on the emitted calls.
	tokenForm     url.Values // parsed form of the token POST
	createBody    *clientRep // body sent to POST /clients (nil until created)
	createCalls   int
	listCalls     int
	secretCalls   int
	sawAuthBearer bool // every admin call carried Authorization: Bearer <token>
}

const (
	testToken  = "test-admin-token-123"
	testUUID   = "11111111-2222-3333-4444-555555555555"
	testSecret = "generated-secret-abcdef"
	testClient = "stoa-consumer"
	testRealm  = "stoa"
)

func (f *fakeKeycloak) handler() http.Handler {
	mux := http.NewServeMux()

	// (1) master-realm token endpoint — form-urlencoded password grant.
	mux.HandleFunc("/realms/master/protocol/openid-connect/token", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			f.t.Errorf("token: method = %s, want POST", r.Method)
		}
		if ct := r.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/x-www-form-urlencoded") {
			f.t.Errorf("token: Content-Type = %q, want form-urlencoded", ct)
		}
		raw, _ := io.ReadAll(r.Body)
		vals, err := url.ParseQuery(string(raw))
		if err != nil {
			f.t.Errorf("token: bad form: %v", err)
		}
		f.mu.Lock()
		f.tokenForm = vals
		f.mu.Unlock()
		writeJSON(w, http.StatusOK, tokenResponse{AccessToken: testToken})
	})

	// (2) clients list + create on the same path; method discriminates.
	clientsPath := "/admin/realms/" + f.realm + "/clients"
	mux.HandleFunc(clientsPath, func(w http.ResponseWriter, r *http.Request) {
		f.assertBearer(r)
		switch r.Method {
		case http.MethodGet:
			f.mu.Lock()
			f.listCalls++
			if got := r.URL.Query().Get("clientId"); got != testClient {
				f.t.Errorf("list: clientId query = %q, want %q", got, testClient)
			}
			created := f.uuid != ""
			f.mu.Unlock()
			if !created {
				writeJSON(w, http.StatusOK, []clientRep{}) // empty before create
				return
			}
			writeJSON(w, http.StatusOK, []clientRep{{ID: f.uuid, ClientID: testClient}})
		case http.MethodPost:
			var body clientRep
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				f.t.Errorf("create: decode body: %v", err)
			}
			f.mu.Lock()
			f.createCalls++
			f.createBody = &body
			f.uuid = testUUID
			f.mu.Unlock()
			// Keycloak answers 201 with a Location header and empty body.
			w.Header().Set("Location", clientsPath+"/"+testUUID)
			w.WriteHeader(http.StatusCreated)
		default:
			f.t.Errorf("clients: unexpected method %s", r.Method)
			w.WriteHeader(http.StatusMethodNotAllowed)
		}
	})

	// (3) per-client secret read.
	secretPath := clientsPath + "/" + testUUID + "/client-secret"
	mux.HandleFunc(secretPath, func(w http.ResponseWriter, r *http.Request) {
		f.assertBearer(r)
		if r.Method != http.MethodGet {
			f.t.Errorf("client-secret: method = %s, want GET", r.Method)
		}
		f.mu.Lock()
		f.secretCalls++
		f.mu.Unlock()
		writeJSON(w, http.StatusOK, secretRep{Value: f.secret})
	})

	return mux
}

func (f *fakeKeycloak) assertBearer(r *http.Request) {
	if got := r.Header.Get("Authorization"); got == "Bearer "+testToken {
		f.mu.Lock()
		f.sawAuthBearer = true
		f.mu.Unlock()
	} else {
		f.t.Errorf("%s %s: Authorization = %q, want %q", r.Method, r.URL.Path, got, "Bearer "+testToken)
	}
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

// TestEnsureClient_CreatesThenIdempotent drives EnsureClient against the fake
// twice: the first call must create the confidential client and return the
// secret; the second must converge onto the existing client without re-creating.
func TestEnsureClient_CreatesThenIdempotent(t *testing.T) {
	fk := &fakeKeycloak{t: t, realm: testRealm, secret: testSecret}
	srv := httptest.NewServer(fk.handler())
	defer srv.Close()

	cfg := Config{
		URL:           srv.URL,
		Realm:         testRealm,
		AdminUser:     "admin",
		AdminPassword: "admin-pw",
		ClientID:      testClient,
	}

	// --- first call: creates the client ---
	gotID, gotSecret, err := EnsureClient(context.Background(), cfg)
	if err != nil {
		t.Fatalf("EnsureClient (create): unexpected error: %v", err)
	}
	if gotID != testClient {
		t.Errorf("clientID = %q, want %q", gotID, testClient)
	}
	if gotSecret != testSecret {
		t.Errorf("clientSecret = %q, want %q", gotSecret, testSecret)
	}

	// token form must be the admin-cli password grant.
	wantForm := map[string]string{
		"client_id":  "admin-cli",
		"username":   "admin",
		"password":   "admin-pw",
		"grant_type": "password",
	}
	for k, want := range wantForm {
		if got := fk.tokenForm.Get(k); got != want {
			t.Errorf("token form[%q] = %q, want %q", k, got, want)
		}
	}

	// create body must declare a confidential service-account client.
	if fk.createBody == nil {
		t.Fatalf("create body was never recorded")
	}
	if fk.createBody.ClientID != testClient {
		t.Errorf("create body clientId = %q, want %q", fk.createBody.ClientID, testClient)
	}
	if !fk.createBody.ServiceAccountsEnabled {
		t.Errorf("create body serviceAccountsEnabled = false, want true")
	}
	if !fk.createBody.StandardFlowEnabled {
		t.Errorf("create body standardFlowEnabled = false, want true")
	}
	if fk.createBody.PublicClient {
		t.Errorf("create body publicClient = true, want false (confidential)")
	}
	if fk.createBody.Secret != "" {
		t.Errorf("create body secret = %q, want empty (none pinned)", fk.createBody.Secret)
	}
	if fk.createCalls != 1 {
		t.Errorf("createCalls = %d, want 1 after first EnsureClient", fk.createCalls)
	}
	if !fk.sawAuthBearer {
		t.Errorf("admin calls did not carry the bearer token")
	}

	// --- second call: idempotent, no new create ---
	gotID2, gotSecret2, err := EnsureClient(context.Background(), cfg)
	if err != nil {
		t.Fatalf("EnsureClient (idempotent): unexpected error: %v", err)
	}
	if gotID2 != testClient || gotSecret2 != testSecret {
		t.Errorf("idempotent call = (%q,%q), want (%q,%q)", gotID2, gotSecret2, testClient, testSecret)
	}
	if fk.createCalls != 1 {
		t.Errorf("createCalls = %d after second EnsureClient, want 1 (idempotent, no re-create)", fk.createCalls)
	}
	if fk.secretCalls != 2 {
		t.Errorf("secretCalls = %d, want 2 (one per EnsureClient)", fk.secretCalls)
	}
}

// TestEnsureClient_PinsSecret verifies a caller-supplied secret is sent on
// create (so a known secret can be seeded) rather than left to Keycloak.
func TestEnsureClient_PinsSecret(t *testing.T) {
	fk := &fakeKeycloak{t: t, realm: testRealm, secret: "pinned-secret-xyz"}
	srv := httptest.NewServer(fk.handler())
	defer srv.Close()

	cfg := Config{
		URL:           srv.URL,
		Realm:         testRealm,
		AdminUser:     "admin",
		AdminPassword: "admin-pw",
		ClientID:      testClient,
		ClientSecret:  "pinned-secret-xyz",
	}
	_, gotSecret, err := EnsureClient(context.Background(), cfg)
	if err != nil {
		t.Fatalf("EnsureClient: unexpected error: %v", err)
	}
	if fk.createBody == nil || fk.createBody.Secret != "pinned-secret-xyz" {
		t.Errorf("create body secret = %v, want pinned-secret-xyz", fk.createBody)
	}
	if gotSecret != "pinned-secret-xyz" {
		t.Errorf("returned secret = %q, want pinned-secret-xyz", gotSecret)
	}
}

// TestEnsureClient_TokenFailure ensures a non-2xx token response is wrapped with
// the admin-token stage so the diagnostic points at the right step.
func TestEnsureClient_TokenFailure(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `{"error":"invalid_grant"}`, http.StatusUnauthorized)
	}))
	defer srv.Close()

	_, _, err := EnsureClient(context.Background(), Config{
		URL: srv.URL, Realm: testRealm, ClientID: testClient,
		AdminUser: "admin", AdminPassword: "wrong",
	})
	if err == nil {
		t.Fatalf("expected error on 401 token response, got nil")
	}
	if !strings.Contains(err.Error(), "admin token") {
		t.Errorf("error %q does not mention the admin-token stage", err.Error())
	}
}

// TestEnsureClient_Validation rejects missing required config without any HTTP.
func TestEnsureClient_Validation(t *testing.T) {
	_, _, err := EnsureClient(context.Background(), Config{Realm: testRealm, ClientID: testClient})
	if err == nil {
		t.Fatalf("expected validation error for missing URL, got nil")
	}
}

// fakeConsumerAuthKC emulates the slice of the Keycloak Admin REST API
// EnsureConsumerAuth touches: token, clients list, the client's
// protocol-mappers/models (audience mapper), realm client-scopes, and the
// per-client default-client-scopes assignment. Stateful, so the same server
// backs both the "create" and the idempotent "already present" assertions.
type fakeConsumerAuthKC struct {
	t     *testing.T
	mu    sync.Mutex
	realm string

	mappers      []protocolMapper
	scopes       []clientScope
	defaultScope map[string]bool // scopeID -> assigned as default

	mapperPosts int
	scopePosts  int
	defaultPuts int
}

func (f *fakeConsumerAuthKC) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/realms/master/protocol/openid-connect/token", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, tokenResponse{AccessToken: testToken})
	})

	clientsPath := "/admin/realms/" + f.realm + "/clients"
	mux.HandleFunc(clientsPath, func(w http.ResponseWriter, r *http.Request) {
		// resolve consumer client by clientId.
		writeJSON(w, http.StatusOK, []clientRep{{ID: testUUID, ClientID: testClient}})
	})

	mux.HandleFunc(clientsPath+"/"+testUUID+"/protocol-mappers/models", func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			f.mu.Lock()
			defer f.mu.Unlock()
			writeJSON(w, http.StatusOK, f.mappers)
		case http.MethodPost:
			var m protocolMapper
			_ = json.NewDecoder(r.Body).Decode(&m)
			f.mu.Lock()
			f.mapperPosts++
			m.ID = "mapper-1"
			f.mappers = append(f.mappers, m)
			f.mu.Unlock()
			w.WriteHeader(http.StatusCreated)
		}
	})

	scopesPath := "/admin/realms/" + f.realm + "/client-scopes"
	mux.HandleFunc(scopesPath, func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			f.mu.Lock()
			defer f.mu.Unlock()
			writeJSON(w, http.StatusOK, f.scopes)
		case http.MethodPost:
			var s clientScope
			_ = json.NewDecoder(r.Body).Decode(&s)
			f.mu.Lock()
			f.scopePosts++
			s.ID = "scope-1"
			f.scopes = append(f.scopes, s)
			f.mu.Unlock()
			w.WriteHeader(http.StatusCreated)
		}
	})

	// default-client-scopes/{id} PUT — wildcard via a prefix handler.
	defPrefix := clientsPath + "/" + testUUID + "/default-client-scopes/"
	mux.HandleFunc(defPrefix, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPut {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		id := strings.TrimPrefix(r.URL.Path, defPrefix)
		f.mu.Lock()
		f.defaultPuts++
		if f.defaultScope == nil {
			f.defaultScope = map[string]bool{}
		}
		f.defaultScope[id] = true
		f.mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	})

	return mux
}

func consumerAuthCfg(srvURL string) ConsumerAuthConfig {
	return ConsumerAuthConfig{
		Config: Config{
			URL: srvURL, Realm: testRealm, AdminUser: "admin", AdminPassword: "pw",
			ClientID: testClient,
		},
		Audience: "accounts-read",
		Scope:    "accounts.read",
	}
}

// TestEnsureConsumerAuth_CreatesThenIdempotent drives EnsureConsumerAuth twice:
// the first run creates the audience mapper + client scope and assigns it
// default; the second converges with no new POSTs.
func TestEnsureConsumerAuth_CreatesThenIdempotent(t *testing.T) {
	fk := &fakeConsumerAuthKC{t: t, realm: testRealm}
	srv := httptest.NewServer(fk.handler())
	defer srv.Close()

	if err := EnsureConsumerAuth(context.Background(), consumerAuthCfg(srv.URL)); err != nil {
		t.Fatalf("EnsureConsumerAuth (create): %v", err)
	}
	if fk.mapperPosts != 1 {
		t.Errorf("audience mapper POSTs = %d, want 1", fk.mapperPosts)
	}
	if fk.scopePosts != 1 {
		t.Errorf("client scope POSTs = %d, want 1", fk.scopePosts)
	}
	if !fk.defaultScope["scope-1"] {
		t.Errorf("client scope not assigned as DEFAULT: %v", fk.defaultScope)
	}
	// The mapper carries aud=accounts-read into the access token.
	if len(fk.mappers) != 1 {
		t.Fatalf("mappers = %d, want 1", len(fk.mappers))
	}
	m := fk.mappers[0]
	if m.ProtocolMapper != "oidc-audience-mapper" {
		t.Errorf("protocolMapper = %q, want oidc-audience-mapper", m.ProtocolMapper)
	}
	if m.Config["included.custom.audience"] != "accounts-read" {
		t.Errorf("included.custom.audience = %q, want accounts-read", m.Config["included.custom.audience"])
	}
	if m.Config["access.token.claim"] != "true" {
		t.Errorf("access.token.claim = %q, want true", m.Config["access.token.claim"])
	}
	// The scope is token-scope-bearing.
	if len(fk.scopes) != 1 || fk.scopes[0].Attributes["include.in.token.scope"] != "true" {
		t.Errorf("client scope not include.in.token.scope=true: %+v", fk.scopes)
	}

	// --- second run: idempotent, no new POSTs ---
	if err := EnsureConsumerAuth(context.Background(), consumerAuthCfg(srv.URL)); err != nil {
		t.Fatalf("EnsureConsumerAuth (idempotent): %v", err)
	}
	if fk.mapperPosts != 1 {
		t.Errorf("audience mapper POSTs = %d after re-run, want 1 (idempotent)", fk.mapperPosts)
	}
	if fk.scopePosts != 1 {
		t.Errorf("client scope POSTs = %d after re-run, want 1 (idempotent)", fk.scopePosts)
	}
	// PUT default-client-scopes is safe to repeat (idempotent assignment).
	if fk.defaultPuts != 2 {
		t.Errorf("default-scope PUTs = %d, want 2 (one per run, idempotent assignment)", fk.defaultPuts)
	}
}

// TestEnsureConsumerAuth_NoopWhenEmpty proves the signature-only path needs no
// Keycloak writes (and makes no HTTP calls at all).
func TestEnsureConsumerAuth_NoopWhenEmpty(t *testing.T) {
	called := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		called = true
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	cfg := ConsumerAuthConfig{Config: Config{URL: srv.URL, Realm: testRealm, ClientID: testClient}}
	if err := EnsureConsumerAuth(context.Background(), cfg); err != nil {
		t.Fatalf("EnsureConsumerAuth (no-op): %v", err)
	}
	if called {
		t.Error("EnsureConsumerAuth made an HTTP call with empty audience+scope, want zero calls")
	}
}

// TestEnsureConsumerAuth_HalfConfigFailsClosed rejects audience without scope
// (and vice versa) — the gateway OAuth2 path enforces BOTH.
func TestEnsureConsumerAuth_HalfConfigFailsClosed(t *testing.T) {
	for name, cfg := range map[string]ConsumerAuthConfig{
		"audience only": {Config: Config{URL: "http://x", Realm: testRealm, ClientID: testClient}, Audience: "a"},
		"scope only":    {Config: Config{URL: "http://x", Realm: testRealm, ClientID: testClient}, Scope: "s"},
	} {
		t.Run(name, func(t *testing.T) {
			if err := EnsureConsumerAuth(context.Background(), cfg); err == nil {
				t.Fatal("half-filled consumer auth succeeded, want fail-closed")
			}
		})
	}
}
