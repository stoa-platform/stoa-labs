package apisix

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
)

// capturedCall records one Admin API request so tests can assert on it.
type capturedCall struct {
	method  string
	path    string
	apiKey  string
	body    map[string]any
	rawBody []byte
}

// fakeAdmin is a minimal in-memory APISIX Admin API. It accepts every PUT
// (200/201), serves GET reads for the verify/probe steps, and records calls.
type fakeAdmin struct {
	t     *testing.T
	calls []capturedCall
	// routes that "exist" for GET reads, keyed by id.
	routes map[string]map[string]any
}

func newFakeAdmin(t *testing.T) *fakeAdmin {
	return &fakeAdmin{t: t, routes: map[string]map[string]any{}}
}

func (f *fakeAdmin) handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		call := capturedCall{
			method:  r.Method,
			path:    r.URL.Path,
			apiKey:  r.Header.Get("X-API-KEY"),
			rawBody: raw,
		}
		if len(raw) > 0 {
			_ = json.Unmarshal(raw, &call.body)
		}
		f.calls = append(f.calls, call)

		switch r.Method {
		case http.MethodPut:
			// Persist route bodies so a later GET can read them back. APISIX
			// returns the stored object under {"value":{...}}.
			if strings.Contains(r.URL.Path, "/apisix/admin/routes/") {
				id := strings.TrimPrefix(r.URL.Path, "/apisix/admin/routes/")
				f.routes[id] = call.body
			}
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{"value":{}}`))
		case http.MethodGet:
			if strings.Contains(r.URL.Path, "/apisix/admin/routes/") {
				id := strings.TrimPrefix(r.URL.Path, "/apisix/admin/routes/")
				stored, ok := f.routes[id]
				if !ok {
					http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
					return
				}
				resp := map[string]any{"value": stored}
				_ = json.NewEncoder(w).Encode(resp)
				return
			}
			// routes list endpoint (Health/List): render every stored route as
			// {"key":"/apisix/routes/<id>","value":{"id":<id>,...}} so List can
			// round-trip the stamped labels.
			list := make([]map[string]any, 0, len(f.routes))
			for id, stored := range f.routes {
				value := map[string]any{"id": id}
				for k, v := range stored {
					value[k] = v
				}
				list = append(list, map[string]any{
					"key":   "/apisix/routes/" + id,
					"value": value,
				})
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"list": list})
		default:
			w.WriteHeader(http.StatusOK)
		}
	})
}

// callFor returns the first recorded call matching method + path suffix.
func (f *fakeAdmin) callFor(method, pathSuffix string) (capturedCall, bool) {
	for _, c := range f.calls {
		if c.method == method && strings.HasSuffix(c.path, pathSuffix) {
			return c, true
		}
	}
	return capturedCall{}, false
}

func newTestAdapter(t *testing.T, srv *httptest.Server) *Adapter {
	t.Helper()
	a, err := New(adapter.Config{
		Type:        "apisix",
		Name:        "apisix",
		AdminURL:    srv.URL,
		GatewayURL:  "http://apisix:9080",
		Credentials: map[string]string{"adminKey": "test-admin-key"},
		Options:     map[string]string{"consumerAuth": "jwt-auth"},
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return a.(*Adapter)
}

func sampleAPI() *adapter.NormalizedAPI {
	return &adapter.NormalizedAPI{
		Name:       "accounts-read",
		Version:    "1.0.0",
		BasePath:   "/accounts-read/v1",
		BackendURL: "http://backend.svc:8080",
		Endpoints: []adapter.Endpoint{
			{Path: "/accounts", Methods: []string{"GET", "POST"}},
			{Path: "/accounts/{id}", Methods: []string{"GET"}},
		},
	}
}

func TestPublish_EmitsObjectPluginsAndEnabledRoute(t *testing.T) {
	fake := newFakeAdmin(t)
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()
	a := newTestAdapter(t, srv)

	res, err := a.Publish(context.Background(), sampleAPI())
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}

	// PublishResult assertions.
	if res.Gateway != "apisix" {
		t.Errorf("Gateway = %q, want apisix", res.Gateway)
	}
	if res.APIID != "accounts-read-0" {
		t.Errorf("APIID = %q, want accounts-read-0", res.APIID)
	}
	if res.RevisionID != "" {
		t.Errorf("RevisionID = %q, want empty (APISIX has no revisions)", res.RevisionID)
	}
	if res.InvocationURL != "http://apisix:9080/accounts-read/v1" {
		t.Errorf("InvocationURL = %q", res.InvocationURL)
	}
	if !res.Published {
		t.Error("Published = false, want true")
	}
	if !res.Created {
		t.Error("Created = false, want true (route did not pre-exist)")
	}

	// X-API-KEY must be present on EVERY admin call.
	for _, c := range fake.calls {
		if c.apiKey != "test-admin-key" {
			t.Errorf("%s %s: X-API-KEY = %q, want test-admin-key", c.method, c.path, c.apiKey)
		}
	}

	// UPSTREAM body: scheme derived from backend, node host:port, type roundrobin.
	up, ok := fake.callFor("PUT", "/apisix/admin/upstreams/accounts-read")
	if !ok {
		t.Fatal("no PUT upstream call recorded")
	}
	if up.body["type"] != "roundrobin" {
		t.Errorf("upstream type = %v, want roundrobin", up.body["type"])
	}
	if up.body["scheme"] != "http" {
		t.Errorf("upstream scheme = %v, want http", up.body["scheme"])
	}
	nodes, _ := up.body["nodes"].(map[string]any)
	if _, ok := nodes["backend.svc:8080"]; !ok {
		t.Errorf("upstream nodes = %v, want key backend.svc:8080", up.body["nodes"])
	}

	// ROUTE body: plugins is an OBJECT (not array), status==1, no auth plugin.
	rt, ok := fake.callFor("PUT", "/apisix/admin/routes/accounts-read-0")
	if !ok {
		t.Fatal("no PUT route accounts-read-0 call recorded")
	}
	if got, ok := rt.body["status"].(float64); !ok || got != 1 {
		t.Errorf("route status = %v, want 1", rt.body["status"])
	}
	plugins, ok := rt.body["plugins"].(map[string]any)
	if !ok {
		t.Fatalf("route plugins is %T, want JSON object (map)", rt.body["plugins"])
	}
	if _, isArr := rt.body["plugins"].([]any); isArr {
		t.Fatal("route plugins decoded as array, want object")
	}
	if _, has := plugins["proxy-rewrite"]; !has {
		t.Errorf("route plugins missing proxy-rewrite: %v", plugins)
	}
	if _, has := plugins["opentelemetry"]; !has {
		t.Errorf("route plugins missing opentelemetry: %v", plugins)
	}
	// No auth at publish time (avoid 401 window).
	if _, has := plugins["jwt-auth"]; has {
		t.Error("route has jwt-auth at publish time, must be added only in CreateConsumer")
	}
	if _, has := plugins["key-auth"]; has {
		t.Error("route has key-auth at publish time, must be added only in CreateConsumer")
	}

	// Route labels stamp managed-by/api/version so List() can round-trip them.
	labels, ok := rt.body["labels"].(map[string]any)
	if !ok {
		t.Fatalf("route labels is %T, want object: %v", rt.body["labels"], rt.body["labels"])
	}
	if labels["managed-by"] != "labctl" {
		t.Errorf("route label managed-by = %v, want labctl", labels["managed-by"])
	}
	if labels["api"] != "accounts-read" {
		t.Errorf("route label api = %v, want accounts-read", labels["api"])
	}
	if labels["version"] != "1.0.0" {
		t.Errorf("route label version = %v, want 1.0.0", labels["version"])
	}

	// proxy-rewrite regex_uri must QuoteMeta the basePath so path metachars are
	// matched literally (no over-match).
	pr, ok := plugins["proxy-rewrite"].(map[string]any)
	if !ok {
		t.Fatalf("proxy-rewrite is %T, want object", plugins["proxy-rewrite"])
	}
	rx, ok := pr["regex_uri"].([]any)
	if !ok || len(rx) < 1 {
		t.Fatalf("regex_uri = %v, want [pattern, replacement]", pr["regex_uri"])
	}
	// No metachars in this basePath, so QuoteMeta is a no-op here.
	if rx[0] != `^/accounts-read/v1/(.*)` {
		t.Errorf("regex_uri[0] = %v, want ^/accounts-read/v1/(.*)", rx[0])
	}

	// Templated path -> prefix wildcard uri.
	rt1, ok := fake.callFor("PUT", "/apisix/admin/routes/accounts-read-1")
	if !ok {
		t.Fatal("no PUT route accounts-read-1 call recorded")
	}
	if rt1.body["uri"] != "/accounts-read/v1/accounts/*" {
		t.Errorf("templated route uri = %v, want /accounts-read/v1/accounts/*", rt1.body["uri"])
	}

	// Verify step issued a GET on the representative route.
	if _, ok := fake.callFor("GET", "/apisix/admin/routes/accounts-read-0"); !ok {
		t.Error("expected a GET verify call on accounts-read-0")
	}
}

func TestPublish_RawPluginsAreObjectInWire(t *testing.T) {
	// Guard against accidental array encoding: inspect the raw wire bytes.
	fake := newFakeAdmin(t)
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()
	a := newTestAdapter(t, srv)

	if _, err := a.Publish(context.Background(), sampleAPI()); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	rt, ok := fake.callFor("PUT", "/apisix/admin/routes/accounts-read-0")
	if !ok {
		t.Fatal("no route call")
	}
	// The "plugins" value in raw JSON must start with '{' not '['.
	s := string(rt.rawBody)
	idx := strings.Index(s, `"plugins"`)
	if idx < 0 {
		t.Fatal("no plugins key in raw body")
	}
	rest := strings.TrimSpace(s[idx+len(`"plugins"`):])
	rest = strings.TrimPrefix(rest, ":")
	rest = strings.TrimSpace(rest)
	if !strings.HasPrefix(rest, "{") {
		t.Errorf("plugins encoded as %q..., want JSON object starting with '{'", rest[:1])
	}
}

func TestCreateConsumer_JWTNoBearerAndSignRoute(t *testing.T) {
	fake := newFakeAdmin(t)
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()
	a := newTestAdapter(t, srv)

	api := sampleAPI()
	spec := &adapter.ConsumerSpec{
		Name:     "accounts-read-app", // contains dashes -> must be sanitised
		AuthType: "jwt-auth",
		Key:      "app-key",
		Secret:   "hs256-secret",
	}
	res, err := a.CreateConsumer(context.Background(), api, spec)
	if err != nil {
		t.Fatalf("CreateConsumer: %v", err)
	}

	// Username sanitised: dashes -> underscores.
	if res.ConsumerID != "accounts_read_app" {
		t.Errorf("ConsumerID = %q, want accounts_read_app", res.ConsumerID)
	}

	// TokenHint for jwt-auth MUST instruct a RAW Authorization header with no
	// "Bearer " prefix before the token (the adversarial correction). We assert
	// on the actual header instruction, not the explanatory "(NO Bearer prefix)"
	// note that legitimately mentions the word.
	if strings.Contains(res.TokenHint, "Authorization: Bearer") {
		t.Errorf("jwt-auth TokenHint emits a Bearer prefix in the header: %q", res.TokenHint)
	}
	if !strings.Contains(res.TokenHint, "Authorization: $token") {
		t.Errorf("jwt-auth TokenHint missing raw Authorization hint: %q", res.TokenHint)
	}

	// Consumer PUT body: username in body, jwt-auth plugin object with key+secret.
	cons, ok := fake.callFor("PUT", "/apisix/admin/consumers")
	if !ok {
		t.Fatal("no PUT consumer call recorded")
	}
	if cons.body["username"] != "accounts_read_app" {
		t.Errorf("consumer username = %v, want accounts_read_app", cons.body["username"])
	}
	cplugins, ok := cons.body["plugins"].(map[string]any)
	if !ok {
		t.Fatalf("consumer plugins is %T, want object", cons.body["plugins"])
	}
	jwt, ok := cplugins["jwt-auth"].(map[string]any)
	if !ok {
		t.Fatalf("consumer plugins missing jwt-auth object: %v", cplugins)
	}
	if jwt["key"] != "app-key" || jwt["secret"] != "hs256-secret" {
		t.Errorf("jwt-auth = %v, want key=app-key secret=hs256-secret", jwt)
	}

	// Auth enabled on the route via an EMPTY jwt-auth object, merged with shared.
	rt, ok := fake.callFor("PUT", "/apisix/admin/routes/accounts-read-0")
	if !ok {
		t.Fatal("no route PUT during CreateConsumer")
	}
	rplugins, _ := rt.body["plugins"].(map[string]any)
	authObj, has := rplugins["jwt-auth"]
	if !has {
		t.Fatalf("route plugins missing jwt-auth after CreateConsumer: %v", rplugins)
	}
	if m, ok := authObj.(map[string]any); !ok || len(m) != 0 {
		t.Errorf("route jwt-auth = %v, want empty object {}", authObj)
	}
	if _, has := rplugins["proxy-rewrite"]; !has {
		t.Error("route lost proxy-rewrite when auth was enabled")
	}

	// jwt-auth public sign route provisioned with public-api plugin.
	sign, ok := fake.callFor("PUT", "/apisix/admin/routes/accounts-read-jwt-sign")
	if !ok {
		t.Fatal("no public-api jwt sign route provisioned")
	}
	if sign.body["uri"] != "/apisix/plugin/jwt/sign" {
		t.Errorf("sign route uri = %v, want /apisix/plugin/jwt/sign", sign.body["uri"])
	}
	sp, _ := sign.body["plugins"].(map[string]any)
	if _, has := sp["public-api"]; !has {
		t.Errorf("sign route missing public-api plugin: %v", sp)
	}

	// X-API-KEY present on every admin call.
	for _, c := range fake.calls {
		if c.apiKey != "test-admin-key" {
			t.Errorf("%s %s: missing X-API-KEY", c.method, c.path)
		}
	}
}

func TestCreateConsumer_KeyAuthHint(t *testing.T) {
	fake := newFakeAdmin(t)
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()
	a := newTestAdapter(t, srv)

	api := sampleAPI()
	spec := &adapter.ConsumerSpec{
		Name:     "reader",
		AuthType: "key-auth",
		Key:      "secret-apikey",
	}
	res, err := a.CreateConsumer(context.Background(), api, spec)
	if err != nil {
		t.Fatalf("CreateConsumer: %v", err)
	}
	if res.ConsumerKey != "secret-apikey" {
		t.Errorf("ConsumerKey = %q, want secret-apikey", res.ConsumerKey)
	}
	// SECURITY: the raw apikey must NEVER appear in TokenHint (it is printed
	// verbatim on stdout). The hint must be a TEMPLATE; the key stays available
	// (truncated) via res.ConsumerKey / the CREDENTIAL column.
	if strings.Contains(res.TokenHint, "secret-apikey") {
		t.Errorf("key-auth TokenHint leaks the raw apikey on stdout: %q", res.TokenHint)
	}
	// key-auth hint: apikey header template, NO Bearer, and no sign route needed.
	if !strings.Contains(res.TokenHint, "apikey: <key>") {
		t.Errorf("key-auth TokenHint = %q, want templated apikey header note", res.TokenHint)
	}
	// key-auth must never instruct a Bearer-prefixed header.
	if strings.Contains(res.TokenHint, "apikey: Bearer") || strings.Contains(res.TokenHint, "Authorization") {
		t.Errorf("key-auth TokenHint must use a plain apikey header, got: %q", res.TokenHint)
	}
	if _, ok := fake.callFor("PUT", "/apisix/admin/routes/reader-jwt-sign"); ok {
		t.Error("key-auth must not provision a jwt sign route")
	}
	// Route auth plugin is key-auth (empty object).
	rt, _ := fake.callFor("PUT", "/apisix/admin/routes/accounts-read-0")
	rplugins, _ := rt.body["plugins"].(map[string]any)
	if _, has := rplugins["key-auth"]; !has {
		t.Errorf("route missing key-auth after CreateConsumer: %v", rplugins)
	}
}

func TestPublish_HTTPSBackendScheme(t *testing.T) {
	fake := newFakeAdmin(t)
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()
	a := newTestAdapter(t, srv)

	api := sampleAPI()
	api.BackendURL = "https://secure.backend:8443"
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	up, _ := fake.callFor("PUT", "/apisix/admin/upstreams/accounts-read")
	if up.body["scheme"] != "https" {
		t.Errorf("upstream scheme = %v, want https (must match backend)", up.body["scheme"])
	}
	nodes, _ := up.body["nodes"].(map[string]any)
	if _, ok := nodes["secure.backend:8443"]; !ok {
		t.Errorf("nodes = %v, want secure.backend:8443", up.body["nodes"])
	}
}

func TestHealth(t *testing.T) {
	fake := newFakeAdmin(t)
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()
	a := newTestAdapter(t, srv)
	if err := a.Health(context.Background()); err != nil {
		t.Fatalf("Health: %v", err)
	}
	c, ok := fake.callFor("GET", "/apisix/admin/routes")
	if !ok {
		t.Fatal("Health did not call routes endpoint")
	}
	if c.apiKey != "test-admin-key" {
		t.Errorf("Health X-API-KEY = %q", c.apiKey)
	}
}

func TestPublish_BasePathRegexEscaped(t *testing.T) {
	// A legal OpenAPI server path can contain a regex metachar (e.g. "/v1.0").
	// Injected raw, '.' would match ANY char and over-strip the prefix. The
	// regex_uri must QuoteMeta the basePath so it is matched literally.
	fake := newFakeAdmin(t)
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()
	a := newTestAdapter(t, srv)

	api := sampleAPI()
	api.BasePath = "/accounts-read/v1.0"
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	rt, ok := fake.callFor("PUT", "/apisix/admin/routes/accounts-read-0")
	if !ok {
		t.Fatal("no route call")
	}
	plugins, _ := rt.body["plugins"].(map[string]any)
	pr, _ := plugins["proxy-rewrite"].(map[string]any)
	rx, ok := pr["regex_uri"].([]any)
	if !ok || len(rx) < 1 {
		t.Fatalf("regex_uri = %v, want [pattern, replacement]", pr["regex_uri"])
	}
	if rx[0] != `^/accounts-read/v1\.0/(.*)` {
		t.Errorf("regex_uri[0] = %v, want '.' escaped as '\\.'", rx[0])
	}
}

func TestList_RoundTripsNameAndVersionFromLabels(t *testing.T) {
	// List() must read back Name+Version from the route labels stamped at
	// publish, reaching parity with the WSO2/webMethods adapters.
	fake := newFakeAdmin(t)
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()
	a := newTestAdapter(t, srv)

	// Publish a single-endpoint API so exactly one route is stamped + listed.
	api := &adapter.NormalizedAPI{
		Name:       "accounts-read",
		Version:    "1.0.0",
		BasePath:   "/accounts-read/v1",
		BackendURL: "http://backend.svc:8080",
		Endpoints:  []adapter.Endpoint{{Path: "/", Methods: nil}},
	}
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	apis, err := a.List(context.Background())
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(apis) != 1 {
		t.Fatalf("List len = %d, want 1", len(apis))
	}
	got := apis[0]
	if got.Gateway != "apisix" {
		t.Errorf("Gateway = %q, want apisix", got.Gateway)
	}
	if got.APIID != "accounts-read-0" {
		t.Errorf("APIID = %q, want accounts-read-0", got.APIID)
	}
	if got.Name != "accounts-read" {
		t.Errorf("Name = %q, want accounts-read (from 'api' label)", got.Name)
	}
	if got.Version != "1.0.0" {
		t.Errorf("Version = %q, want 1.0.0 (from 'version' label)", got.Version)
	}
	if got.BasePath != "/accounts-read/v1/*" {
		t.Errorf("BasePath = %q, want route uri /accounts-read/v1/*", got.BasePath)
	}
}

func TestCreateConsumer_GeneratedKeyNotLeakedInHint(t *testing.T) {
	// When key-auth supplies no key, a 48-hex-char secret is generated. It must
	// surface only via ConsumerKey (truncated downstream), never in TokenHint.
	fake := newFakeAdmin(t)
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()
	a := newTestAdapter(t, srv)

	api := sampleAPI()
	spec := &adapter.ConsumerSpec{Name: "reader", AuthType: "key-auth"} // no Key
	res, err := a.CreateConsumer(context.Background(), api, spec)
	if err != nil {
		t.Fatalf("CreateConsumer: %v", err)
	}
	if res.ConsumerKey == "" {
		t.Fatal("ConsumerKey empty, want a generated apikey")
	}
	if strings.Contains(res.TokenHint, res.ConsumerKey) {
		t.Errorf("generated apikey leaked into TokenHint: hint=%q key=%q", res.TokenHint, res.ConsumerKey)
	}
	if !strings.Contains(res.TokenHint, "apikey: <key>") {
		t.Errorf("TokenHint = %q, want templated 'apikey: <key>'", res.TokenHint)
	}
}

func TestNew_RejectsBadAuth(t *testing.T) {
	_, err := New(adapter.Config{AdminURL: "http://x:9180", Options: map[string]string{"consumerAuth": "oauth2"}})
	if err == nil {
		t.Fatal("New accepted unsupported consumerAuth, want error")
	}
}
