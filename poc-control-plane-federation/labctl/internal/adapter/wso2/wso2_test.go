package wso2

import (
	"context"
	"encoding/json"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
)

// hits records, per WSO2 endpoint, what the adapter actually emitted so the test
// can assert the corrected sequence (deploy-revision==200, change-lifecycle,
// multipart parts, validityTime string, ...).
type hits struct {
	mu sync.Mutex

	dcrCount       int
	tokenScopes    []string
	importBody     string // captured multipart additionalProperties part
	importHasFile  bool
	revisionBody   string
	deployBody     string
	deployRevQuery string
	deployHit      bool
	lifecycleHit   bool
	lifecycleQuery string

	subscribeBody string
	genKeysBody   string
	mapKeysBody   string
}

// newFakeWSO2 stands up an httptest.Server emulating the WSO2 4.5 publisher v4 +
// devportal v3 surface the adapter drives.
func newFakeWSO2(t *testing.T, h *hits) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()

	// --- DCR + token ---------------------------------------------------------
	mux.HandleFunc("/client-registration/v0.17/register", func(w http.ResponseWriter, r *http.Request) {
		h.mu.Lock()
		h.dcrCount++
		h.mu.Unlock()
		writeJSON(w, 200, map[string]string{
			"clientId":     "cid-123",
			"clientSecret": "csecret-123",
		})
	})
	mux.HandleFunc("/oauth2/token", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		h.mu.Lock()
		h.tokenScopes = append(h.tokenScopes, r.FormValue("scope"))
		h.mu.Unlock()
		writeJSON(w, 200, map[string]any{
			"access_token": "tok-abc", "token_type": "Bearer", "expires_in": 3600,
		})
	})

	// --- Publisher v4 --------------------------------------------------------
	mux.HandleFunc("/api/am/publisher/v4/apis/import-openapi", func(w http.ResponseWriter, r *http.Request) {
		mediaType, params, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
		if !strings.HasPrefix(mediaType, "multipart/") {
			t.Errorf("import-openapi: want multipart, got %q", mediaType)
		}
		mr := multipart.NewReader(r.Body, params["boundary"])
		for {
			part, err := mr.NextPart()
			if err == io.EOF {
				break
			}
			if err != nil {
				t.Fatalf("import-openapi: read part: %v", err)
			}
			data, _ := io.ReadAll(part)
			switch part.FormName() {
			case "file":
				h.mu.Lock()
				h.importHasFile = true
				h.mu.Unlock()
			case "additionalProperties":
				h.mu.Lock()
				h.importBody = string(data)
				h.mu.Unlock()
			}
		}
		writeJSON(w, 201, map[string]string{
			"id": "api-uuid-1", "name": "accounts-read", "version": "v1",
		})
	})
	mux.HandleFunc("/api/am/publisher/v4/apis/api-uuid-1/revisions", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		h.mu.Lock()
		h.revisionBody = string(body)
		h.mu.Unlock()
		writeJSON(w, 201, map[string]string{"id": "rev-9"})
	})
	mux.HandleFunc("/api/am/publisher/v4/apis/api-uuid-1/deploy-revision", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		h.mu.Lock()
		h.deployHit = true
		h.deployBody = string(body)
		h.deployRevQuery = r.URL.Query().Get("revisionId")
		h.mu.Unlock()
		// Verdict correction: deploy-revision success is HTTP 200, not 201.
		writeJSON(w, 200, []map[string]any{
			{"revisionUuid": "rev-9", "name": "Default", "vhost": "localhost", "status": "CREATED"},
		})
	})
	mux.HandleFunc("/api/am/publisher/v4/apis/change-lifecycle", func(w http.ResponseWriter, r *http.Request) {
		h.mu.Lock()
		h.lifecycleHit = true
		h.lifecycleQuery = r.URL.RawQuery
		h.mu.Unlock()
		writeJSON(w, 200, map[string]string{"lifecycleState": "PUBLISHED"})
	})
	// Search/list (used by idempotency probe, Health, List). Return empty so the
	// publish path imports a new API.
	mux.HandleFunc("/api/am/publisher/v4/apis", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"count": 0, "list": []any{}})
	})

	// --- DevPortal v3 --------------------------------------------------------
	mux.HandleFunc("/api/am/devportal/v3/apis", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"count": 1, "list": []map[string]string{
			{"id": "dev-api-1", "name": "accounts-read", "version": "v1"},
		}})
	})
	mux.HandleFunc("/api/am/devportal/v3/applications", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			writeJSON(w, 200, map[string]any{"count": 0, "list": []any{}})
			return
		}
		writeJSON(w, 201, map[string]string{"applicationId": "app-1", "name": "team-x"})
	})
	mux.HandleFunc("/api/am/devportal/v3/subscriptions", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		h.mu.Lock()
		h.subscribeBody = string(body)
		h.mu.Unlock()
		writeJSON(w, 201, map[string]string{"subscriptionId": "sub-1", "apiId": "dev-api-1", "applicationId": "app-1"})
	})
	mux.HandleFunc("/api/am/devportal/v3/applications/app-1/generate-keys", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		h.mu.Lock()
		h.genKeysBody = string(body)
		h.mu.Unlock()
		writeJSON(w, 200, map[string]string{"consumerKey": "ck-gen", "consumerSecret": "cs-gen", "keyType": "PRODUCTION"})
	})
	mux.HandleFunc("/api/am/devportal/v3/applications/app-1/map-keys", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		h.mu.Lock()
		h.mapKeysBody = string(body)
		h.mu.Unlock()
		writeJSON(w, 200, map[string]string{"consumerKey": "kc-client", "consumerSecret": "kc-secret", "keyType": "PRODUCTION"})
	})

	return httptest.NewTLSServer(mux)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func newTestAdapter(t *testing.T, url string) *Client {
	t.Helper()
	a, err := New(adapter.Config{
		Type:       "wso2",
		Name:       "wso2",
		AdminURL:   url,
		GatewayURL: "https://wso2am:8243",
		Insecure:   true, // httptest TLS server uses a self-signed cert
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return a.(*Client)
}

func sampleAPI() *adapter.NormalizedAPI {
	return &adapter.NormalizedAPI{
		Name:       "accounts-read",
		Version:    "v1",
		BasePath:   "/accounts-read/v1",
		BackendURL: "http://microcks:8080/rest/accounts",
		SpecPath:   "accounts.yaml",
		Spec:       []byte("openapi: 3.0.0\ninfo:\n  title: accounts-read\n"),
	}
}

func TestPublish_FullSequence(t *testing.T) {
	h := &hits{}
	srv := newFakeWSO2(t, h)
	defer srv.Close()

	c := newTestAdapter(t, srv.URL)
	res, err := c.Publish(context.Background(), sampleAPI())
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}

	// The crux of the verdict: BOTH deploy-revision and change-lifecycle ran.
	if !h.deployHit {
		t.Error("deploy-revision was never called")
	}
	if !h.lifecycleHit {
		t.Error("change-lifecycle was never called")
	}
	if !res.Published {
		t.Errorf("Published=false, want true after deploy + lifecycle")
	}
	if res.APIID != "api-uuid-1" {
		t.Errorf("APIID = %q, want api-uuid-1", res.APIID)
	}
	if res.RevisionID != "rev-9" {
		t.Errorf("RevisionID = %q, want rev-9", res.RevisionID)
	}
	if !res.Created {
		t.Errorf("Created=false, want true for a freshly imported API")
	}
	if res.InvocationURL != "https://wso2am:8243/accounts-read/v1" {
		t.Errorf("InvocationURL = %q", res.InvocationURL)
	}

	// deploy-revision: revisionId in QUERY, JSON ARRAY body with name+vhost.
	if h.deployRevQuery != "rev-9" {
		t.Errorf("deploy-revision ?revisionId = %q, want rev-9", h.deployRevQuery)
	}
	var deploy []map[string]any
	if err := json.Unmarshal([]byte(h.deployBody), &deploy); err != nil {
		t.Fatalf("deploy-revision body is not a JSON array: %v (%s)", err, h.deployBody)
	}
	if len(deploy) != 1 {
		t.Fatalf("deploy-revision array len = %d, want 1", len(deploy))
	}
	if deploy[0]["name"] != "Default" || deploy[0]["vhost"] != "localhost" {
		t.Errorf("deploy-revision element = %v, want name=Default vhost=localhost", deploy[0])
	}
	if deploy[0]["displayOnDevportal"] != true {
		t.Errorf("deploy-revision displayOnDevportal = %v, want true", deploy[0]["displayOnDevportal"])
	}

	// change-lifecycle: params in QUERY (apiId + action=Publish), no body.
	if !strings.Contains(h.lifecycleQuery, "action=Publish") {
		t.Errorf("change-lifecycle query = %q, want action=Publish", h.lifecycleQuery)
	}
	if !strings.Contains(h.lifecycleQuery, "apiId=api-uuid-1") {
		t.Errorf("change-lifecycle query = %q, want apiId=api-uuid-1", h.lifecycleQuery)
	}

	// import-openapi: file part present AND additionalProperties is stringified
	// JSON with name/context/endpointConfig/policies.
	if !h.importHasFile {
		t.Error("import-openapi: missing 'file' multipart part")
	}
	var props map[string]any
	if err := json.Unmarshal([]byte(h.importBody), &props); err != nil {
		t.Fatalf("additionalProperties not valid JSON: %v (%s)", err, h.importBody)
	}
	if props["name"] != "accounts-read" || props["context"] != "/accounts-read/v1" {
		t.Errorf("additionalProperties name/context wrong: %v", props)
	}
	if pol, ok := props["policies"].([]any); !ok || len(pol) != 1 || pol[0] != "Unlimited" {
		t.Errorf("additionalProperties.policies = %v, want [Unlimited]", props["policies"])
	}
	ep, _ := props["endpointConfig"].(map[string]any)
	if ep == nil || ep["endpoint_type"] != "http" {
		t.Errorf("additionalProperties.endpointConfig wrong: %v", props["endpointConfig"])
	}

	// DCR was performed and the password-grant requested the publisher scopes.
	if h.dcrCount == 0 {
		t.Error("DCR register was never called")
	}
	if len(h.tokenScopes) == 0 || !strings.Contains(h.tokenScopes[0], "apim:api_publish") {
		t.Errorf("token scope = %v, want apim:api_publish present", h.tokenScopes)
	}
}

func TestPublish_TokenCached(t *testing.T) {
	h := &hits{}
	srv := newFakeWSO2(t, h)
	defer srv.Close()

	c := newTestAdapter(t, srv.URL)
	if _, err := c.Publish(context.Background(), sampleAPI()); err != nil {
		t.Fatalf("first Publish: %v", err)
	}
	dcrAfterFirst := h.dcrCount
	if _, err := c.Publish(context.Background(), sampleAPI()); err != nil {
		t.Fatalf("second Publish: %v", err)
	}
	// The publisher token is cached: no extra DCR on the second publish.
	if h.dcrCount != dcrAfterFirst {
		t.Errorf("DCR called again after caching: %d -> %d", dcrAfterFirst, h.dcrCount)
	}
}

func TestCreateConsumer_GenerateKeys(t *testing.T) {
	h := &hits{}
	srv := newFakeWSO2(t, h)
	defer srv.Close()

	c := newTestAdapter(t, srv.URL)
	res, err := c.CreateConsumer(context.Background(), sampleAPI(), &adapter.ConsumerSpec{
		Name:             "team-x",
		ThrottlingPolicy: "Unlimited",
		// No ClientID -> self-issue via generate-keys.
	})
	if err != nil {
		t.Fatalf("CreateConsumer: %v", err)
	}
	if res.ConsumerID != "app-1" || res.SubscriptionID != "sub-1" {
		t.Errorf("ids = %q/%q, want app-1/sub-1", res.ConsumerID, res.SubscriptionID)
	}
	if res.ConsumerKey != "ck-gen" || res.ConsumerSecret != "cs-gen" {
		t.Errorf("keys = %q/%q, want ck-gen/cs-gen", res.ConsumerKey, res.ConsumerSecret)
	}

	// Subscribe must have run and referenced the resolved devApiId + appId.
	if !strings.Contains(h.subscribeBody, `"apiId":"dev-api-1"`) ||
		!strings.Contains(h.subscribeBody, `"applicationId":"app-1"`) {
		t.Errorf("subscribe body = %s, want apiId=dev-api-1 applicationId=app-1", h.subscribeBody)
	}

	// Verdict correction: validityTime is a STRING ("3600"), not a number.
	if !strings.Contains(h.genKeysBody, `"validityTime":"3600"`) {
		t.Errorf("generate-keys body = %s, want validityTime as string \"3600\"", h.genKeysBody)
	}
	if h.mapKeysBody != "" {
		t.Errorf("map-keys should not be called without ClientID; got %s", h.mapKeysBody)
	}
}

func TestCreateConsumer_MapExternalClient(t *testing.T) {
	h := &hits{}
	srv := newFakeWSO2(t, h)
	defer srv.Close()

	c := newTestAdapter(t, srv.URL)
	res, err := c.CreateConsumer(context.Background(), sampleAPI(), &adapter.ConsumerSpec{
		Name:         "team-x",
		ClientID:     "kc-client",
		ClientSecret: "kc-secret",
	})
	if err != nil {
		t.Fatalf("CreateConsumer: %v", err)
	}
	// With a Keycloak client supplied, map-keys is used (not generate-keys).
	if h.mapKeysBody == "" {
		t.Error("map-keys was not called despite ClientID being supplied")
	}
	if h.genKeysBody != "" {
		t.Errorf("generate-keys should not run when ClientID is supplied; got %s", h.genKeysBody)
	}
	if !strings.Contains(h.mapKeysBody, `"consumerKey":"kc-client"`) ||
		!strings.Contains(h.mapKeysBody, `"keyManager":"Resident Key Manager"`) {
		t.Errorf("map-keys body = %s, want consumerKey=kc-client keyManager=Resident Key Manager", h.mapKeysBody)
	}
	if res.ConsumerKey != "kc-client" {
		t.Errorf("ConsumerKey = %q, want kc-client", res.ConsumerKey)
	}
}

func TestPublish_IdempotentReuse(t *testing.T) {
	h := &hits{}
	// Custom server: the search endpoint returns an existing API so import is
	// skipped and Created must be false.
	mux := http.NewServeMux()
	mux.HandleFunc("/client-registration/v0.17/register", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]string{"clientId": "c", "clientSecret": "s"})
	})
	mux.HandleFunc("/oauth2/token", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"access_token": "t", "expires_in": 3600})
	})
	mux.HandleFunc("/api/am/publisher/v4/apis/import-openapi", func(w http.ResponseWriter, r *http.Request) {
		t.Error("import-openapi must NOT be called when API already exists")
		writeJSON(w, 201, map[string]string{"id": "should-not-happen"})
	})
	mux.HandleFunc("/api/am/publisher/v4/apis/existing-id/revisions", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 201, map[string]string{"id": "rev-x"})
	})
	mux.HandleFunc("/api/am/publisher/v4/apis/existing-id/deploy-revision", func(w http.ResponseWriter, r *http.Request) {
		h.mu.Lock()
		h.deployHit = true
		h.mu.Unlock()
		writeJSON(w, 200, []map[string]any{{"status": "CREATED"}})
	})
	mux.HandleFunc("/api/am/publisher/v4/apis/change-lifecycle", func(w http.ResponseWriter, r *http.Request) {
		h.mu.Lock()
		h.lifecycleHit = true
		h.mu.Unlock()
		writeJSON(w, 200, map[string]string{"lifecycleState": "PUBLISHED"})
	})
	mux.HandleFunc("/api/am/publisher/v4/apis", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"count": 1, "list": []map[string]string{
			{"id": "existing-id", "name": "accounts-read", "version": "v1"},
		}})
	})
	srv := httptest.NewTLSServer(mux)
	defer srv.Close()

	c := newTestAdapter(t, srv.URL)
	res, err := c.Publish(context.Background(), sampleAPI())
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if res.Created {
		t.Error("Created=true, want false when reusing an existing API")
	}
	if res.APIID != "existing-id" {
		t.Errorf("APIID = %q, want existing-id", res.APIID)
	}
	if !h.deployHit || !h.lifecycleHit {
		t.Error("deploy + lifecycle must still run on idempotent reuse")
	}
}

func TestName(t *testing.T) {
	c := newTestAdapter(t, "https://wso2am:9443")
	if c.Name() != "wso2" {
		t.Errorf("Name() = %q, want wso2", c.Name())
	}
}

func TestRegistered(t *testing.T) {
	// The package init() must have registered the factory under "wso2".
	a, err := adapter.New(adapter.Config{Type: "wso2", AdminURL: "https://wso2am:9443"})
	if err != nil {
		t.Fatalf("adapter.New(wso2): %v", err)
	}
	if a.Name() != "wso2" {
		t.Errorf("registered adapter Name() = %q, want wso2", a.Name())
	}
}
