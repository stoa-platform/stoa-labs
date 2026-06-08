package webmethods

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
)

// mockGateway is an in-memory stand-in for the webMethods API Gateway mock. It
// implements only the surface the adapter touches under /rest/apigateway/* and
// records the requests it received so tests can assert paths/methods/bodies.
type mockGateway struct {
	mu       sync.Mutex
	apis     map[string]apiRecord    // apiId -> record
	subs     map[string]subscription // subId -> record
	apiSeq   int
	subSeq   int
	requests []string // "METHOD path" log, in order
	isAlive  bool
}

func newMockGateway() *mockGateway {
	return &mockGateway{
		apis:    map[string]apiRecord{},
		subs:    map[string]subscription{},
		isAlive: true,
	}
}

// mux wires the Go 1.22+ method-pattern routes. A wrong method yields 405 from
// the mux (not a handler hit), matching the real mock's behaviour.
func (m *mockGateway) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /rest/apigateway/is/health", m.health)
	mux.HandleFunc("GET /rest/apigateway/apis", m.listAPIs)
	mux.HandleFunc("POST /rest/apigateway/apis", m.createAPI)
	mux.HandleFunc("GET /rest/apigateway/apis/{id}", m.getAPI)
	mux.HandleFunc("DELETE /rest/apigateway/apis/{id}", m.deleteAPI)
	mux.HandleFunc("GET /rest/apigateway/subscriptions", m.listSubs)
	mux.HandleFunc("POST /rest/apigateway/subscriptions", m.createSub)
	// Wrap so every response carries the X-Gateway header, like the real mock.
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		m.mu.Lock()
		m.requests = append(m.requests, r.Method+" "+r.URL.Path)
		m.mu.Unlock()
		w.Header().Set(gatewayHeaderKey, gatewayHeaderValue)
		mux.ServeHTTP(w, r)
	})
}

func (m *mockGateway) writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func (m *mockGateway) health(w http.ResponseWriter, _ *http.Request) {
	m.writeJSON(w, http.StatusOK, healthResponse{IsAlive: m.isAlive, Gateway: gatewayHeaderValue})
}

func (m *mockGateway) listAPIs(w http.ResponseWriter, _ *http.Request) {
	m.mu.Lock()
	defer m.mu.Unlock()
	list := make([]apiRecord, 0, len(m.apis))
	for _, a := range m.apis {
		list = append(list, a)
	}
	m.writeJSON(w, http.StatusOK, apiListEnvelope{APIs: list, Count: len(list)})
}

func (m *mockGateway) createAPI(w http.ResponseWriter, r *http.Request) {
	var in apiRecord
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	if in.APIName == "" || in.BasePath == "" {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "apiName and basePath are required"})
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.apiSeq++
	id := fmt.Sprintf("api-%04d", m.apiSeq)
	rec := apiRecord{
		APIID:      id,
		APIName:    in.APIName,
		APIVersion: orDefault(in.APIVersion, "1.0.0"),
		BasePath:   serverNormalize(in.BasePath),
		BackendURL: in.BackendURL,
		CreatedAt:  "2026-06-08T00:00:00Z",
	}
	m.apis[id] = rec
	m.writeJSON(w, http.StatusCreated, rec)
}

func (m *mockGateway) getAPI(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	m.mu.Lock()
	defer m.mu.Unlock()
	rec, ok := m.apis[id]
	if !ok {
		m.writeJSON(w, http.StatusNotFound, map[string]string{"error": "api not found"})
		return
	}
	m.writeJSON(w, http.StatusOK, rec)
}

func (m *mockGateway) deleteAPI(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.apis[id]; !ok {
		m.writeJSON(w, http.StatusNotFound, map[string]string{"error": "api not found"})
		return
	}
	delete(m.apis, id)
	w.WriteHeader(http.StatusNoContent)
}

func (m *mockGateway) listSubs(w http.ResponseWriter, _ *http.Request) {
	m.mu.Lock()
	defer m.mu.Unlock()
	list := make([]subscription, 0, len(m.subs))
	for _, s := range m.subs {
		list = append(list, s)
	}
	m.writeJSON(w, http.StatusOK, subListEnvelope{Subscriptions: list, Count: len(list)})
}

func (m *mockGateway) createSub(w http.ResponseWriter, r *http.Request) {
	var in subscription
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	if in.ApplicationName == "" || in.ClientID == "" {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "applicationName and clientId are required"})
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.subSeq++
	id := fmt.Sprintf("sub-%04d", m.subSeq)
	rec := subscription{
		SubscriptionID:  id,
		ApplicationName: in.ApplicationName,
		APIID:           in.APIID,
		ClientID:        in.ClientID,
		CreatedAt:       "2026-06-08T00:00:00Z",
	}
	m.subs[id] = rec
	m.writeJSON(w, http.StatusCreated, rec)
}

// serverNormalize mirrors the mock's basePath normalization ("/"+Trim(slashes)).
func serverNormalize(p string) string {
	p = strings.Trim(p, "/")
	if p == "" {
		return "/"
	}
	return "/" + p
}

func orDefault(v, def string) string {
	if strings.TrimSpace(v) == "" {
		return def
	}
	return v
}

func (m *mockGateway) countRequests(prefix string) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for _, r := range m.requests {
		if strings.HasPrefix(r, prefix) {
			n++
		}
	}
	return n
}

// newAdapter builds an adapter pointed at the test server, plus the sample API.
func newAdapter(t *testing.T, srv *httptest.Server) (*Adapter, *adapter.NormalizedAPI) {
	t.Helper()
	a, err := New(adapter.Config{
		Type:       gatewayName,
		Name:       gatewayName,
		AdminURL:   srv.URL,
		GatewayURL: "http://webmethods-mock:8080",
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	api := &adapter.NormalizedAPI{
		Name:       "accounts-read",
		Version:    "1.0.0",
		BasePath:   "/accounts-read/v1",
		BackendURL: "http://microcks:8080/rest/accounts",
	}
	return a.(*Adapter), api
}

func TestPublish_CreatesAndReadsBack(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newAdapter(t, srv)
	res, err := a.Publish(context.Background(), api)
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}

	if res.Gateway != gatewayName {
		t.Errorf("Gateway = %q, want %q", res.Gateway, gatewayName)
	}
	if res.APIID != "api-0001" {
		t.Errorf("APIID = %q, want api-0001", res.APIID)
	}
	if res.RevisionID != "" {
		t.Errorf("RevisionID = %q, want empty (no revision lifecycle)", res.RevisionID)
	}
	if !res.Published {
		t.Error("Published = false, want true")
	}
	if !res.Created {
		t.Error("Created = false, want true on first publish")
	}
	want := "http://webmethods-mock:8080/gateway/accounts-read/v1"
	if res.InvocationURL != want {
		t.Errorf("InvocationURL = %q, want %q", res.InvocationURL, want)
	}

	// The create must have been preceded by a health preflight and followed by a
	// read-back GET /apis/{id}.
	if got := mock.countRequests("GET /rest/apigateway/is/health"); got != 1 {
		t.Errorf("health preflight count = %d, want 1", got)
	}
	if got := mock.countRequests("POST /rest/apigateway/apis"); got != 1 {
		t.Errorf("create count = %d, want 1", got)
	}
	if got := mock.countRequests("GET /rest/apigateway/apis/api-0001"); got != 1 {
		t.Errorf("read-back count = %d, want 1", got)
	}

	// The API is actually persisted with normalized fields.
	if len(mock.apis) != 1 {
		t.Fatalf("server holds %d apis, want 1", len(mock.apis))
	}
	stored := mock.apis["api-0001"]
	if stored.BasePath != "/accounts-read/v1" {
		t.Errorf("stored basePath = %q, want /accounts-read/v1", stored.BasePath)
	}
	if stored.BackendURL != api.BackendURL {
		t.Errorf("stored backendUrl = %q, want %q", stored.BackendURL, api.BackendURL)
	}
}

func TestPublish_IdempotentNoDuplicate(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newAdapter(t, srv)
	first, err := a.Publish(context.Background(), api)
	if err != nil {
		t.Fatalf("first Publish: %v", err)
	}
	if !first.Created {
		t.Error("first publish Created = false, want true")
	}

	// Second publish with the SAME api must converge onto the existing record:
	// no duplicate, Created=false, and no second POST issued.
	second, err := a.Publish(context.Background(), api)
	if err != nil {
		t.Fatalf("second Publish: %v", err)
	}
	if second.Created {
		t.Error("second publish Created = true, want false (idempotent reuse)")
	}
	if second.APIID != first.APIID {
		t.Errorf("apiId drifted: %q -> %q", first.APIID, second.APIID)
	}
	if len(mock.apis) != 1 {
		t.Fatalf("server holds %d apis after re-publish, want 1 (no duplicate)", len(mock.apis))
	}
	// Exactly one create POST over both publishes.
	if got := mock.countRequests("POST /rest/apigateway/apis"); got != 1 {
		t.Errorf("create POST count = %d over two publishes, want 1", got)
	}
}

func TestPublish_DriftDeletesAndRecreates(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newAdapter(t, srv)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("first Publish: %v", err)
	}

	// Change the backendUrl: the mock has no update endpoint, so the adapter must
	// DELETE the stale api then POST a fresh one.
	api.BackendURL = "http://microcks:8080/rest/accounts-v2"
	res, err := a.Publish(context.Background(), api)
	if err != nil {
		t.Fatalf("drift Publish: %v", err)
	}
	if !res.Created {
		t.Error("drift publish Created = false, want true (delete+recreate)")
	}
	if got := mock.countRequests("DELETE /rest/apigateway/apis/"); got != 1 {
		t.Errorf("delete count = %d, want 1 on drift", got)
	}
	if len(mock.apis) != 1 {
		t.Fatalf("server holds %d apis after drift, want 1", len(mock.apis))
	}
	// New record carries the updated backend.
	if res.APIID == "" {
		t.Fatal("drift publish returned empty apiId")
	}
	if mock.apis[res.APIID].BackendURL != api.BackendURL {
		t.Errorf("recreated backendUrl = %q, want %q", mock.apis[res.APIID].BackendURL, api.BackendURL)
	}
}

func TestCreateConsumer_SetsClientID(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newAdapter(t, srv)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	spec := &adapter.ConsumerSpec{
		Name:     "partner-app",
		ClientID: "kc-client-abc123",
		AuthType: "oauth2",
	}
	res, err := a.CreateConsumer(context.Background(), api, spec)
	if err != nil {
		t.Fatalf("CreateConsumer: %v", err)
	}

	if res.SubscriptionID != "sub-0001" {
		t.Errorf("SubscriptionID = %q, want sub-0001", res.SubscriptionID)
	}
	if res.ConsumerID != "sub-0001" {
		t.Errorf("ConsumerID = %q, want sub-0001", res.ConsumerID)
	}
	// webMethods echoes the supplied clientId as the consumer key, no secret.
	if res.ConsumerKey != spec.ClientID {
		t.Errorf("ConsumerKey = %q, want %q", res.ConsumerKey, spec.ClientID)
	}
	if res.ConsumerSecret != "" {
		t.Errorf("ConsumerSecret = %q, want empty (mock has no secret)", res.ConsumerSecret)
	}
	if !strings.Contains(res.TokenHint, spec.ClientID) {
		t.Errorf("TokenHint %q does not mention clientId", res.TokenHint)
	}

	// The subscription stored on the server carries the clientId and the apiId.
	if len(mock.subs) != 1 {
		t.Fatalf("server holds %d subs, want 1", len(mock.subs))
	}
	stored := mock.subs["sub-0001"]
	if stored.ClientID != spec.ClientID {
		t.Errorf("stored clientId = %q, want %q", stored.ClientID, spec.ClientID)
	}
	if stored.APIID != "api-0001" {
		t.Errorf("stored apiId = %q, want api-0001", stored.APIID)
	}
	if stored.ApplicationName != spec.Name {
		t.Errorf("stored applicationName = %q, want %q", stored.ApplicationName, spec.Name)
	}
}

func TestCreateConsumer_Idempotent(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newAdapter(t, srv)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	spec := &adapter.ConsumerSpec{Name: "partner-app", ClientID: "kc-client-abc123"}

	first, err := a.CreateConsumer(context.Background(), api, spec)
	if err != nil {
		t.Fatalf("first CreateConsumer: %v", err)
	}
	second, err := a.CreateConsumer(context.Background(), api, spec)
	if err != nil {
		t.Fatalf("second CreateConsumer: %v", err)
	}
	if first.SubscriptionID != second.SubscriptionID {
		t.Errorf("subscriptionId drifted: %q -> %q", first.SubscriptionID, second.SubscriptionID)
	}
	if len(mock.subs) != 1 {
		t.Fatalf("server holds %d subs after re-subscribe, want 1 (no duplicate)", len(mock.subs))
	}
	if got := mock.countRequests("POST /rest/apigateway/subscriptions"); got != 1 {
		t.Errorf("subscribe POST count = %d, want 1", got)
	}
}

func TestCreateConsumer_RequiresClientID(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newAdapter(t, srv)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	// Missing clientId must fail before any POST (Keycloak client is mandatory).
	_, err := a.CreateConsumer(context.Background(), api, &adapter.ConsumerSpec{Name: "x"})
	if err == nil {
		t.Fatal("CreateConsumer with empty clientId succeeded, want error")
	}
	if !strings.Contains(err.Error(), "clientId") {
		t.Errorf("error %q does not mention clientId requirement", err.Error())
	}
}

func TestHealth_GatesOnIsAlive(t *testing.T) {
	mock := newMockGateway()
	mock.isAlive = false
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, _ := newAdapter(t, srv)
	if err := a.Health(context.Background()); err == nil {
		t.Fatal("Health succeeded with isAlive=false, want error")
	}
}

func TestName(t *testing.T) {
	srv := httptest.NewServer(newMockGateway().handler())
	defer srv.Close()
	a, _ := newAdapter(t, srv)
	if a.Name() != "webmethods" {
		t.Errorf("Name() = %q, want webmethods", a.Name())
	}
}
