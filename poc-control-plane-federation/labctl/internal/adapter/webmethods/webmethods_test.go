package webmethods

// Unit tests against an httptest stand-in that reproduces the REAL
// apigateway:10.15 admin surface — Basic auth on /rest/apigateway/*, nested
// {"apiResponse": ...} envelopes, import payloads with apiDefinition, the
// separate activate lifecycle and the applications consumer model. Response
// shapes are ported from the live-validated career adapter (stoa-go).

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
)

const (
	testUser = "Administrator"
	testPass = "manage"
)

// storedAPI is the gateway-side record plus the last import payload received,
// so tests can assert what was actually sent.
type storedAPI struct {
	rec     wmAPI
	payload map[string]any
}

// mockGateway is an in-memory stand-in for the real webMethods API Gateway
// admin API. It enforces Basic auth (or a bearer token when configured) and
// serves the product's envelope shapes.
type mockGateway struct {
	mu      sync.Mutex
	apis    map[string]*storedAPI     // id -> record
	apps    map[string]*wmApplication // id -> application
	appRaw  map[string]map[string]any // id -> full raw application (identifiers/authStrategyIds round-trip)
	appAPIs map[string][]string       // appId -> associated apiIDs
	aliases map[string]map[string]any // id -> alias record (raw, product-shaped)
	actions map[string]map[string]any // id -> policyAction record (raw)
	// routingActions are the actions the IMPORT itself mints (the
	// straightThroughRouting of the default policy) — kept apart from
	// labctl-posted actions so tests can still count the latter, but MERGED
	// into the /policyActions list exactly like the live product serves them.
	routingActions map[string]map[string]any // id -> straightThroughRouting record
	policies       map[string]map[string]any // id -> policy record (raw)
	policyAPI      map[string]string         // policyId -> owning apiId
	strategies     map[string]map[string]any // id -> OAUTH2 strategy record (raw)
	scopes         map[string]map[string]any // id -> scope mapping record (raw)
	apiSeq         int
	appSeq         int
	aliasSeq       int
	actionSeq      int
	routeActSeq    int
	policySeq      int
	strategySeq    int
	scopeSeq       int
	requests       []string // "METHOD path" log, in order
	healthDoc      map[string]any
	// bearerToken, when non-empty, is ALSO accepted as "Authorization: Bearer
	// <token>" (the CI auth mode) in addition to the Basic pair.
	bearerToken        string
	conflictNextCreate bool // force a 409 on the next POST /apis
	// strictPolicyEdit mimics builds that refuse PUT /policies/{id} while the
	// owning API is active (exercises the deactivate→edit→reactivate cycle).
	strictPolicyEdit bool
	// silentActionPut mimics the live 10.15 trap generalised: PUT
	// /policyActions/{id} answers 200 but persists NOTHING — the adapter's
	// read-back assertion must turn this into a loud failure. (The mock ALWAYS
	// no-ops a NAKED, non-enveloped body, like the real product.)
	silentActionPut bool
	// dropRemoteIntrospection mimics a build that does NOT recognise the
	// remoteIntrospectionConfig field name: the alias create/update strips the
	// block silently (no error), so the read-back assertion must catch it.
	dropRemoteIntrospection bool
	// keystoreConfig is the gateway-wide keystore/truststore configuration the
	// /configurations/keystore surface round-trips (partner cert truststore).
	keystoreConfig map[string]any
	// noKeystoreEndpoint mimics a locked/older trial that does NOT expose
	// /configurations/keystore (404) — the truststore step must degrade
	// gracefully (best-effort) rather than fail the whole subscribe.
	noKeystoreEndpoint bool
}

func newMockGateway() *mockGateway {
	return &mockGateway{
		apis:           map[string]*storedAPI{},
		apps:           map[string]*wmApplication{},
		appRaw:         map[string]map[string]any{},
		appAPIs:        map[string][]string{},
		aliases:        map[string]map[string]any{},
		actions:        map[string]map[string]any{},
		routingActions: map[string]map[string]any{},
		policies:       map[string]map[string]any{},
		policyAPI:      map[string]string{},
		strategies:     map[string]map[string]any{},
		scopes:         map[string]map[string]any{},
		healthDoc:      map[string]any{"status": "green"},
		keystoreConfig: map[string]any{
			"truststoreName": "", "keystoreName": "", "signingAlias": "",
		},
	}
}

func (m *mockGateway) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /rest/apigateway/health", m.health)
	mux.HandleFunc("GET /rest/apigateway/apis", m.listAPIs)
	mux.HandleFunc("POST /rest/apigateway/apis", m.createAPI)
	mux.HandleFunc("GET /rest/apigateway/apis/{id}", m.getAPI)
	mux.HandleFunc("PUT /rest/apigateway/apis/{id}", m.updateAPI)
	mux.HandleFunc("POST /rest/apigateway/apis/{id}/versions", m.createVersionAPI)
	mux.HandleFunc("PUT /rest/apigateway/apis/{id}/activate", m.activateAPI)
	mux.HandleFunc("PUT /rest/apigateway/apis/{id}/deactivate", m.deactivateAPI)
	mux.HandleFunc("GET /rest/apigateway/applications", m.listApps)
	mux.HandleFunc("POST /rest/apigateway/applications", m.createApp)
	mux.HandleFunc("GET /rest/apigateway/applications/{id}", m.getApp)
	mux.HandleFunc("PUT /rest/apigateway/applications/{id}", m.updateApp)
	mux.HandleFunc("PUT /rest/apigateway/applications/{id}/apis", m.associate)
	mux.HandleFunc("GET /rest/apigateway/strategies", m.listStrategies)
	mux.HandleFunc("POST /rest/apigateway/strategies", m.createStrategy)
	mux.HandleFunc("PUT /rest/apigateway/strategies/{id}", m.updateStrategy)
	mux.HandleFunc("GET /rest/apigateway/scopes", m.listScopes)
	mux.HandleFunc("POST /rest/apigateway/scopes", m.createScope)
	mux.HandleFunc("PUT /rest/apigateway/scopes/{id}", m.updateScope)
	mux.HandleFunc("GET /rest/apigateway/alias", m.listAliases)
	mux.HandleFunc("GET /rest/apigateway/alias/{id}", m.getAlias)
	mux.HandleFunc("POST /rest/apigateway/alias", m.createAlias)
	mux.HandleFunc("PUT /rest/apigateway/alias/{id}", m.updateAlias)
	mux.HandleFunc("GET /rest/apigateway/policyActions", m.listActions)
	mux.HandleFunc("POST /rest/apigateway/policyActions", m.createAction)
	mux.HandleFunc("PUT /rest/apigateway/policyActions/{id}", m.updateAction)
	mux.HandleFunc("GET /rest/apigateway/policies/{id}", m.getPolicy)
	mux.HandleFunc("PUT /rest/apigateway/policies/{id}", m.updatePolicy)
	mux.HandleFunc("GET /rest/apigateway/configurations/keystore", m.getKeystore)
	mux.HandleFunc("PUT /rest/apigateway/configurations/keystore", m.putKeystore)
	// The real product answers 401 on missing/bad credentials. The mock
	// accepts Basic (testUser/testPass) and — when m.bearerToken is configured
	// — the matching "Bearer <token>" header (the CI auth mode).
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		m.mu.Lock()
		m.requests = append(m.requests, r.Method+" "+r.URL.Path)
		tok := m.bearerToken
		m.mu.Unlock()
		if tok != "" && r.Header.Get("Authorization") == "Bearer "+tok {
			mux.ServeHTTP(w, r)
			return
		}
		user, pass, ok := r.BasicAuth()
		if !ok || user != testUser || pass != testPass {
			w.Header().Set("WWW-Authenticate", `Basic realm="Integration Server"`)
			http.Error(w, `{"error":"Unauthorized"}`, http.StatusUnauthorized)
			return
		}
		mux.ServeHTTP(w, r)
	})
}

func (m *mockGateway) writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func (m *mockGateway) health(w http.ResponseWriter, _ *http.Request) {
	m.writeJSON(w, http.StatusOK, m.healthDoc)
}

// listAPIs serves the real envelope: {"apiResponse":[{"api":{...},"responseStatus":"SUCCESS"},...]}.
func (m *mockGateway) listAPIs(w http.ResponseWriter, _ *http.Request) {
	m.mu.Lock()
	defer m.mu.Unlock()
	items := make([]any, 0, len(m.apis))
	for _, a := range m.apis {
		items = append(items, map[string]any{"api": a.rec, "responseStatus": "SUCCESS"})
	}
	m.writeJSON(w, http.StatusOK, map[string]any{"apiResponse": items})
}

func (m *mockGateway) createAPI(w http.ResponseWriter, r *http.Request) {
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	name, _ := in["apiName"].(string)
	version, _ := in["apiVersion"].(string)
	if name == "" || in["apiDefinition"] == nil {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "apiName and apiDefinition are required"})
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.conflictNextCreate {
		m.conflictNextCreate = false
		m.writeJSON(w, http.StatusConflict, map[string]string{"error": "An API already exists with this name"})
		return
	}
	for _, a := range m.apis {
		if a.rec.APIName == name && a.rec.APIVersion == version {
			m.writeJSON(w, http.StatusConflict, map[string]string{"error": "An API already exists with this name and version"})
			return
		}
	}
	m.apiSeq++
	id := fmt.Sprintf("wm-api-%04d", m.apiSeq)
	// Import also mints the SERVICE-scoped default policy with transport +
	// routing stages, exactly like the real product (the inbound-auth
	// projection finds it through the api record's policies list). The routing
	// stage carries a REAL straightThroughRouting action whose endpointUri is
	// the native endpoint derived from the imported servers[] — plus the
	// "method":["CUSTOM"] param the UI adds, which converges must PRESERVE.
	m.routeActSeq++
	routeActID := fmt.Sprintf("wm-route-act-%04d", m.routeActSeq)
	m.routingActions[routeActID] = map[string]any{
		"id":          routeActID,
		"names":       []any{map[string]any{"value": "Straight Through Routing", "locale": "en"}},
		"templateKey": "straightThroughRouting",
		"parameters": []any{
			map[string]any{"templateKey": "endpointUri", "values": []any{importedServerURL(in)}},
			map[string]any{"templateKey": "method", "values": []any{"CUSTOM"}},
		},
		"active": true,
	}
	m.policySeq++
	polID := fmt.Sprintf("wm-pol-%04d", m.policySeq)
	m.policies[polID] = map[string]any{
		"id":    polID,
		"names": []any{map[string]any{"value": "Default Policy for API " + name, "locale": "English"}},
		"policyEnforcements": []any{
			map[string]any{"stageKey": "transport", "enforcements": []any{
				map[string]any{"enforcementObjectId": "wm-act-transport", "order": nil}}},
			map[string]any{"stageKey": "routing", "enforcements": []any{
				map[string]any{"enforcementObjectId": routeActID, "order": nil}}},
		},
		"policyScope":  "SERVICE",
		"systemPolicy": false,
		"global":       false,
		"active":       false,
	}
	m.policyAPI[polID] = id
	rec := wmAPI{ID: id, APIName: name, APIVersion: version, IsActive: false, Type: "REST", Policies: []string{polID}}
	m.apis[id] = &storedAPI{rec: rec, payload: in}
	// Real create response is nested: {"apiResponse":{"api":{...}}}.
	m.writeJSON(w, http.StatusCreated, map[string]any{
		"apiResponse": map[string]any{"api": rec, "responseStatus": "SUCCESS"},
	})
}

// createVersionAPI mirrors the native versioning endpoint (POST
// /apis/{id}/versions, 201 — vérifié live) : il MINT un nouveau record du
// même apiName avec newApiVersion (inactif, policy par défaut + action
// straightThroughRouting clonées du modèle d'import) — le chemin que
// l'adapter prend quand un nom existe sous une AUTRE version.
func (m *mockGateway) createVersionAPI(w http.ResponseWriter, r *http.Request) {
	baseID := r.PathValue("id")
	var in struct {
		NewAPIVersion string `json:"newApiVersion"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.NewAPIVersion == "" {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"errorDetails": "newApiVersion is required"})
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	base, ok := m.apis[baseID]
	if !ok {
		m.writeJSON(w, http.StatusNotFound, map[string]string{"errorDetails": "api not found"})
		return
	}
	m.apiSeq++
	id := fmt.Sprintf("wm-api-%04d", m.apiSeq)
	m.routeActSeq++
	routeActID := fmt.Sprintf("wm-route-act-%04d", m.routeActSeq)
	m.routingActions[routeActID] = map[string]any{
		"id":          routeActID,
		"names":       []any{map[string]any{"value": "Straight Through Routing", "locale": "en"}},
		"templateKey": "straightThroughRouting",
		"parameters": []any{
			map[string]any{"templateKey": "endpointUri", "values": []any{importedServerURL(base.payload)}},
			map[string]any{"templateKey": "method", "values": []any{"CUSTOM"}},
		},
		"active": true,
	}
	m.policySeq++
	polID := fmt.Sprintf("wm-pol-%04d", m.policySeq)
	m.policies[polID] = map[string]any{
		"id":    polID,
		"names": []any{map[string]any{"value": "Default Policy for API " + base.rec.APIName, "locale": "English"}},
		"policyEnforcements": []any{
			map[string]any{"stageKey": "transport", "enforcements": []any{
				map[string]any{"enforcementObjectId": "wm-act-transport", "order": nil}}},
			map[string]any{"stageKey": "routing", "enforcements": []any{
				map[string]any{"enforcementObjectId": routeActID, "order": nil}}},
		},
		"policyScope":  "SERVICE",
		"systemPolicy": false,
		"global":       false,
		"active":       false,
	}
	m.policyAPI[polID] = id
	rec := wmAPI{ID: id, APIName: base.rec.APIName, APIVersion: in.NewAPIVersion, IsActive: false, Type: "REST", Policies: []string{polID}}
	m.apis[id] = &storedAPI{rec: rec, payload: base.payload}
	m.writeJSON(w, http.StatusCreated, map[string]any{
		"apiResponse": map[string]any{"api": rec, "responseStatus": "SUCCESS"},
	})
}

// importedServerURL extracts servers[0].url from an import payload — the
// native endpoint the real product derives at import (and stores in the
// straightThroughRouting action of the default policy).
func importedServerURL(payload map[string]any) string {
	def, _ := payload["apiDefinition"].(map[string]any)
	if def == nil {
		return "http://backend.invalid"
	}
	servers, _ := def["servers"].([]any)
	if len(servers) == 0 {
		return "http://backend.invalid"
	}
	s0, _ := servers[0].(map[string]any)
	if s0 == nil {
		return "http://backend.invalid"
	}
	if u, _ := s0["url"].(string); u != "" {
		return u
	}
	return "http://backend.invalid"
}

func (m *mockGateway) getAPI(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	m.mu.Lock()
	defer m.mu.Unlock()
	a, ok := m.apis[id]
	if !ok {
		m.writeJSON(w, http.StatusNotFound, map[string]string{"error": "api not found"})
		return
	}
	m.writeJSON(w, http.StatusOK, map[string]any{
		"apiResponse": map[string]any{"api": a.rec, "responseStatus": "SUCCESS"},
	})
}

func (m *mockGateway) updateAPI(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	a, ok := m.apis[id]
	if !ok {
		m.writeJSON(w, http.StatusNotFound, map[string]string{"error": "api not found"})
		return
	}
	a.payload = in
	if v, _ := in["apiVersion"].(string); v != "" {
		a.rec.APIVersion = v
	}
	m.writeJSON(w, http.StatusOK, map[string]any{
		"apiResponse": map[string]any{"api": a.rec, "responseStatus": "SUCCESS"},
	})
}

func (m *mockGateway) activateAPI(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	m.mu.Lock()
	defer m.mu.Unlock()
	a, ok := m.apis[id]
	if !ok {
		m.writeJSON(w, http.StatusNotFound, map[string]string{"error": "api not found"})
		return
	}
	a.rec.IsActive = true
	m.writeJSON(w, http.StatusOK, map[string]any{"apiResponse": map[string]any{"api": a.rec}})
}

func (m *mockGateway) deactivateAPI(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	m.mu.Lock()
	defer m.mu.Unlock()
	a, ok := m.apis[id]
	if !ok {
		m.writeJSON(w, http.StatusNotFound, map[string]string{"error": "api not found"})
		return
	}
	a.rec.IsActive = false
	m.writeJSON(w, http.StatusOK, map[string]any{"apiResponse": map[string]any{"api": a.rec}})
}

// --- alias / policyActions / policies surfaces (inbound-auth projection) ----

// maskAliasHTTPCredentials returns a serving copy of the alias with
// httpAuthCredentials.password MASKED as the base64 of asterisks — the exact
// live read-back of an httpTransportSecurityAlias (the spike pinned it): the
// adapter must never key drift on the password nor write the mask back.
func maskAliasHTTPCredentials(al map[string]any) map[string]any {
	creds, ok := al["httpAuthCredentials"].(map[string]any)
	if !ok || creds == nil {
		return al
	}
	out := map[string]any{}
	for k, v := range al {
		out[k] = v
	}
	masked := map[string]any{}
	for k, v := range creds {
		masked[k] = v
	}
	if _, has := masked["password"]; has {
		masked["password"] = base64.StdEncoding.EncodeToString([]byte("********"))
	}
	out["httpAuthCredentials"] = masked
	return out
}

// listAliases serves the product envelope {"alias":[...]}, plus the built-in
// LOCAL_IS "local" alias the real gateway always carries (so name lookups must
// actually filter). Credential-alias passwords are MASKED, like live.
func (m *mockGateway) listAliases(w http.ResponseWriter, _ *http.Request) {
	m.mu.Lock()
	defer m.mu.Unlock()
	items := []any{map[string]any{
		"id": "local", "name": "local", "type": "authServerAlias", "authServerType": "LOCAL_IS",
	}}
	for _, al := range m.aliases {
		items = append(items, maskAliasHTTPCredentials(al))
	}
	m.writeJSON(w, http.StatusOK, map[string]any{"alias": items})
}

// createAlias takes the NAKED alias body (no envelope — a real 10.15 envelope
// inconsistency) and rejects duplicate names like the product does.
func (m *mockGateway) createAlias(w http.ResponseWriter, r *http.Request) {
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	name, _ := in["name"].(string)
	if name == "" {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "name is required"})
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, al := range m.aliases {
		if al["name"] == name {
			m.writeJSON(w, http.StatusConflict, map[string]string{"error": "Alias with name " + name + " already exists"})
			return
		}
	}
	if m.dropRemoteIntrospection {
		delete(in, "remoteIntrospectionConfig")
	}
	m.aliasSeq++
	in["id"] = fmt.Sprintf("wm-alias-%04d", m.aliasSeq)
	m.aliases[in["id"].(string)] = in
	m.writeJSON(w, http.StatusCreated, in)
}

func (m *mockGateway) updateAlias(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.aliases[id]; !ok {
		m.writeJSON(w, http.StatusNotFound, map[string]string{"error": "alias not found"})
		return
	}
	if m.dropRemoteIntrospection {
		delete(in, "remoteIntrospectionConfig")
	}
	in["id"] = id
	m.aliases[id] = in
	m.writeJSON(w, http.StatusOK, in)
}

// getAlias serves one alias by id, MASKING secret material exactly like the
// live MaskableEntity: remoteIntrospectionConfig.clientSecret -> "***" and
// httpAuthCredentials.password -> base64 of asterisks. The read-back
// assertions must not depend on secrets coming back in clear, and a build that
// masked a non-secret field too would (correctly) trip them.
func (m *mockGateway) getAlias(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	m.mu.Lock()
	defer m.mu.Unlock()
	al, ok := m.aliases[id]
	if !ok {
		m.writeJSON(w, http.StatusNotFound, map[string]string{"error": "alias not found"})
		return
	}
	out := map[string]any{}
	for k, v := range maskAliasHTTPCredentials(al) {
		out[k] = v
	}
	if rc, ok := out["remoteIntrospectionConfig"].(map[string]any); ok && rc != nil {
		masked := map[string]any{}
		for k, v := range rc {
			masked[k] = v
		}
		if _, has := masked["clientSecret"]; has {
			masked["clientSecret"] = "***"
		}
		out["remoteIntrospectionConfig"] = masked
	}
	m.writeJSON(w, http.StatusOK, map[string]any{"alias": out})
}

// listActions serves {"policyAction":[...]} (singular key, list value) — the
// labctl-posted actions MERGED with the import-minted routing actions, exactly
// like the live surface lists every template.
func (m *mockGateway) listActions(w http.ResponseWriter, _ *http.Request) {
	m.mu.Lock()
	defer m.mu.Unlock()
	items := make([]any, 0, len(m.actions)+len(m.routingActions))
	for _, act := range m.actions {
		items = append(items, act)
	}
	for _, act := range m.routingActions {
		items = append(items, act)
	}
	m.writeJSON(w, http.StatusOK, map[string]any{"policyAction": items})
}

// createAction takes the ENVELOPED body {"policyAction":{...}} and — like the
// real product — NORMALISES the display name to the template's own ("Identify
// & Authorize"), so adapters relying on custom action names would break here
// exactly as they do live. For outboundTransportAuthentication it reproduces
// the live NPE: FLAT parameters (no nested transportSecurity group) answer 500
// (OutboundTransportSecurityFactory), making the spike-pinned nested shape
// load-bearing in tests.
func (m *mockGateway) createAction(w http.ResponseWriter, r *http.Request) {
	var in struct {
		PolicyAction map[string]any `json:"policyAction"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.PolicyAction == nil {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "policyAction envelope is required"})
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	act := in.PolicyAction
	if tk, _ := act["templateKey"].(string); tk == "outboundTransportAuthentication" {
		if !hasNestedTransportSecurity(act) {
			m.writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": "java.lang.NullPointerException at com.softwareag.apigateway.core.factory.policy.OutboundTransportSecurityFactory",
			})
			return
		}
	}
	m.actionSeq++
	act["id"] = fmt.Sprintf("wm-action-%04d", m.actionSeq)
	if tk, _ := act["templateKey"].(string); tk == "evaluatePolicy" {
		act["names"] = []any{map[string]any{"value": "Identify & Authorize", "locale": "en"}}
	}
	m.actions[act["id"].(string)] = act
	m.writeJSON(w, http.StatusCreated, map[string]any{"policyAction": act})
}

// hasNestedTransportSecurity checks the spike-pinned outbound-auth shape: ONE
// "transportSecurity" parameter group carrying the actual params nested.
func hasNestedTransportSecurity(act map[string]any) bool {
	params, _ := act["parameters"].([]any)
	for _, p := range params {
		pm, _ := p.(map[string]any)
		if pm == nil {
			continue
		}
		if tk, _ := pm["templateKey"].(string); tk != "transportSecurity" {
			continue
		}
		nested, _ := pm["parameters"].([]any)
		return len(nested) > 0
	}
	return false
}

// updateAction PUTs one action in place (the LIVE edit the spike pinned —
// effect immediate, no deactivate/activate cycle), for BOTH labctl-posted and
// import-minted (routing) actions. It reproduces the live PUT trap: a NAKED
// (non-enveloped) body — or any body when silentActionPut is on — answers 200
// but persists NOTHING, so only an adapter that read-back-asserts notices.
func (m *mockGateway) updateAction(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var body map[string]any
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	cur, isRouting := m.routingActions[id]
	if !isRouting {
		cur = m.actions[id]
	}
	if cur == nil {
		m.writeJSON(w, http.StatusNotFound, map[string]string{"error": "policy action not found"})
		return
	}
	act, enveloped := body["policyAction"].(map[string]any)
	if !enveloped || m.silentActionPut {
		// SILENT NO-OP (live trap): 200 with the CURRENT record, nothing written.
		m.writeJSON(w, http.StatusOK, map[string]any{"policyAction": cur})
		return
	}
	act["id"] = id
	if tk, _ := act["templateKey"].(string); tk == "evaluatePolicy" {
		act["names"] = []any{map[string]any{"value": "Identify & Authorize", "locale": "en"}}
	}
	if isRouting {
		m.routingActions[id] = act
	} else {
		m.actions[id] = act
	}
	m.writeJSON(w, http.StatusOK, map[string]any{"policyAction": act})
}

func (m *mockGateway) getPolicy(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	m.mu.Lock()
	defer m.mu.Unlock()
	pol, ok := m.policies[id]
	if !ok {
		m.writeJSON(w, http.StatusNotFound, map[string]string{"error": "policy not found"})
		return
	}
	m.writeJSON(w, http.StatusOK, map[string]any{"policy": pol})
}

// updatePolicy takes {"policy":{...}} and REPLACES the record wholesale (the
// real PUT semantics — stages not re-listed are lost). With strictPolicyEdit
// it refuses while the owning API is active, to exercise the
// deactivate→edit→reactivate cycle.
func (m *mockGateway) updatePolicy(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var in struct {
		Policy map[string]any `json:"policy"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.Policy == nil {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "policy envelope is required"})
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.policies[id]; !ok {
		m.writeJSON(w, http.StatusNotFound, map[string]string{"error": "policy not found"})
		return
	}
	if m.strictPolicyEdit {
		if apiID := m.policyAPI[id]; apiID != "" {
			if api, ok := m.apis[apiID]; ok && api.rec.IsActive {
				m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "API is active; deactivate it to edit the policy"})
				return
			}
		}
	}
	in.Policy["id"] = id
	m.policies[id] = in.Policy
	m.writeJSON(w, http.StatusOK, map[string]any{"policy": in.Policy})
}

func (m *mockGateway) listApps(w http.ResponseWriter, _ *http.Request) {
	m.mu.Lock()
	defer m.mu.Unlock()
	list := make([]wmApplication, 0, len(m.apps))
	for _, app := range m.apps {
		list = append(list, *app)
	}
	m.writeJSON(w, http.StatusOK, wmApplicationsResponse{Applications: list})
}

func (m *mockGateway) createApp(w http.ResponseWriter, r *http.Request) {
	var in wmApplication
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.Name == "" {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "name is required"})
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.appSeq++
	in.ID = fmt.Sprintf("wm-app-%04d", m.appSeq)
	m.apps[in.ID] = &in
	// Seed the raw record the GET/PUT-by-id surface round-trips. The real
	// product mints an empty identifiers/authStrategyIds set on a fresh app.
	m.appRaw[in.ID] = map[string]any{
		"id":              in.ID,
		"name":            in.Name,
		"description":     in.Description,
		"identifiers":     []any{},
		"authStrategyIds": []any{},
	}
	// Real create response is the flat application object.
	m.writeJSON(w, http.StatusCreated, in)
}

// getApp serves the single-record envelope {"applications":[{...}]} for the raw
// application (carrying identifiers/authStrategyIds), like the real product.
func (m *mockGateway) getApp(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	m.mu.Lock()
	defer m.mu.Unlock()
	raw, ok := m.appRaw[id]
	if !ok {
		m.writeJSON(w, http.StatusNotFound, map[string]string{"error": "application not found"})
		return
	}
	m.writeJSON(w, http.StatusOK, map[string]any{"applications": []any{raw}})
}

// updateApp REPLACES the application record wholesale (the real PUT semantics),
// EXCEPT consumingAPIs which the gateway preserves (the spike pinned this: the
// PUT cannot clear the API binding). It echoes the enveloped record back.
func (m *mockGateway) updateApp(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	prev, ok := m.appRaw[id]
	if !ok {
		m.writeJSON(w, http.StatusNotFound, map[string]string{"error": "application not found"})
		return
	}
	// Reject an unknown identifier key with 400, exactly as the real gateway does
	// ("Undefined 'key' attribute value ..."). This makes the live-pinned keys
	// (token / ipAddressRange / httpsCertificate) load-bearing: a regression to a
	// non-enum key (e.g. "tokens") would fail the test, not silently pass.
	if ids, _ := in["identifiers"].([]any); ids != nil {
		for _, raw := range ids {
			entry, _ := raw.(map[string]any)
			if entry == nil {
				continue
			}
			k, _ := entry["key"].(string)
			if !wmIdentifierKeyEnum[k] {
				m.writeJSON(w, http.StatusBadRequest, map[string]string{
					"errorDetails": "Undefined 'key' attribute value '" + k + "'",
				})
				return
			}
		}
	}
	in["id"] = id
	// consumingAPIs is gateway-preserved across this PUT (not client-mutable).
	if v, had := prev["consumingAPIs"]; had {
		in["consumingAPIs"] = v
	}
	m.appRaw[id] = in
	// Keep the typed view's name/description in sync for the list surface.
	if app := m.apps[id]; app != nil {
		if n, _ := in["name"].(string); n != "" {
			app.Name = n
		}
	}
	m.writeJSON(w, http.StatusOK, map[string]any{"applications": []any{in}})
}

func (m *mockGateway) associate(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var in struct {
		APIIDs []string `json:"apiIDs"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.apps[id]; !ok {
		m.writeJSON(w, http.StatusNotFound, map[string]string{"error": "application not found"})
		return
	}
	m.appAPIs[id] = in.APIIDs
	w.WriteHeader(http.StatusNoContent)
}

// wmIdentifierKeyEnum is the fixed key enum the REAL 10.15 gateway enforces (it
// rejects an unknown `key` with a 400 listing exactly these). Pinned live by the
// onboarding write spike — note the SINGULAR `token` and `httpsCertificate`.
var wmIdentifierKeyEnum = map[string]bool{
	"httpBasicAuth": true, "accessProfile": true, "apiKey": true,
	"wssecX509Token": true, "wssecUsernameToken": true, "ipAddressRange": true,
	"hostNameAddress": true, "openIdClaims": true, "jwtClaims": true,
	"oAuth2Token": true, "payloadElement": true, "httpsCertificate": true,
	"XPathExpression": true, "kerberosToken": true, "token": true,
	"partnerId": true, "httpHeaders": true,
}

// getKeystore serves the gateway-wide keystore/truststore configuration (the
// real /configurations/keystore surface). A build configured to hide the
// endpoint answers 404, exercising the best-effort degrade path.
func (m *mockGateway) getKeystore(w http.ResponseWriter, _ *http.Request) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.noKeystoreEndpoint {
		m.writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
		return
	}
	m.writeJSON(w, http.StatusOK, m.keystoreConfig)
}

// putKeystore replaces the keystore/truststore configuration wholesale.
func (m *mockGateway) putKeystore(w http.ResponseWriter, r *http.Request) {
	if m.noKeystoreEndpoint {
		m.writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
		return
	}
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.keystoreConfig = in
	m.writeJSON(w, http.StatusOK, in)
}

// --- strategies / scopes surfaces (OAuth2 projection) -----------------------

// listStrategies serves the BARE array shape the live 10.15 returns.
func (m *mockGateway) listStrategies(w http.ResponseWriter, _ *http.Request) {
	m.mu.Lock()
	defer m.mu.Unlock()
	items := make([]any, 0, len(m.strategies))
	for _, st := range m.strategies {
		items = append(items, st)
	}
	m.writeJSON(w, http.StatusOK, items)
}

// createStrategy takes the NAKED strategy body, rejects duplicate names like
// the product, and answers with the ENVELOPED {"strategy":{...}} response.
func (m *mockGateway) createStrategy(w http.ResponseWriter, r *http.Request) {
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	name, _ := in["name"].(string)
	if name == "" {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "name is required"})
		return
	}
	if tk, _ := in["type"].(string); tk != "OAUTH2" {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "type must be OAUTH2 (uppercase)"})
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, st := range m.strategies {
		if st["name"] == name {
			m.writeJSON(w, http.StatusConflict, map[string]string{"error": "Strategy with name " + name + " already exists"})
			return
		}
	}
	m.strategySeq++
	in["id"] = fmt.Sprintf("wm-strat-%04d", m.strategySeq)
	m.strategies[in["id"].(string)] = in
	m.writeJSON(w, http.StatusCreated, map[string]any{"strategy": in})
}

func (m *mockGateway) updateStrategy(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.strategies[id]; !ok {
		m.writeJSON(w, http.StatusNotFound, map[string]string{"error": "strategy not found"})
		return
	}
	in["id"] = id
	m.strategies[id] = in
	m.writeJSON(w, http.StatusOK, map[string]any{"strategy": in})
}

// listScopes serves the {"scopes":[...]} envelope the live product returns.
func (m *mockGateway) listScopes(w http.ResponseWriter, _ *http.Request) {
	m.mu.Lock()
	defer m.mu.Unlock()
	items := make([]any, 0, len(m.scopes))
	for _, sc := range m.scopes {
		items = append(items, sc)
	}
	m.writeJSON(w, http.StatusOK, map[string]any{"scopes": items})
}

// createScope takes the NAKED scope body and rejects a duplicate scopeName.
func (m *mockGateway) createScope(w http.ResponseWriter, r *http.Request) {
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	name, _ := in["scopeName"].(string)
	if name == "" {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "scopeName is required"})
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, sc := range m.scopes {
		if sc["scopeName"] == name {
			m.writeJSON(w, http.StatusConflict, map[string]string{"error": "Scope " + name + " already exists"})
			return
		}
	}
	m.scopeSeq++
	in["id"] = fmt.Sprintf("wm-scope-%04d", m.scopeSeq)
	m.scopes[in["id"].(string)] = in
	m.writeJSON(w, http.StatusCreated, map[string]any{"scope": in})
}

func (m *mockGateway) updateScope(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		m.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.scopes[id]; !ok {
		m.writeJSON(w, http.StatusNotFound, map[string]string{"error": "scope not found"})
		return
	}
	in["id"] = id
	m.scopes[id] = in
	m.writeJSON(w, http.StatusOK, map[string]any{"scope": in})
}

// countExact counts requests whose "METHOD path" equals exactly want (so a
// PUT to /applications/{id} is not conflated with /applications/{id}/apis).
func (m *mockGateway) countExact(want string) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for _, r := range m.requests {
		if r == want {
			n++
		}
	}
	return n
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

// sampleSpec is a minimal OpenAPI 3.0 contract carrying the constructs the
// 10.15 compatibility layer must fix: a $ref response schema (RefProperty
// crash) and a path-only servers[].url (no real upstream).
const sampleSpec = `openapi: 3.0.3
info:
  title: Accounts Read API
  version: 1.0.0
servers:
  - url: /accounts-read/v1
paths:
  /accounts:
    get:
      operationId: listAccounts
      responses:
        "200":
          description: ok
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/AccountList"
components:
  schemas:
    AccountList:
      type: object
`

// newAdapter builds an adapter pointed at the test server, plus the sample API.
func newAdapter(t *testing.T, srv *httptest.Server) (*Adapter, *adapter.NormalizedAPI) {
	t.Helper()
	a, err := New(adapter.Config{
		Type:       gatewayName,
		Name:       gatewayName,
		AdminURL:   srv.URL,
		GatewayURL: "http://webmethods-real:5555",
		Credentials: map[string]string{
			"username": testUser,
			"password": testPass,
		},
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	api := &adapter.NormalizedAPI{
		Name:       "accounts-read",
		Version:    "1.0.0",
		BasePath:   "/accounts-read/v1",
		BackendURL: "http://microcks:8080/rest/accounts",
		Spec:       []byte(sampleSpec),
		SpecPath:   "apis/accounts-read.openapi.yaml",
	}
	return a.(*Adapter), api
}

func TestNew_FailsClosedWithoutCredentials(t *testing.T) {
	_, err := New(adapter.Config{AdminURL: "http://localhost:5555"})
	if err == nil {
		t.Fatal("New without credentials succeeded, want fail-closed error")
	}
	if !strings.Contains(err.Error(), "username") {
		t.Errorf("error %q should name the missing credentials", err.Error())
	}
}

func TestPublish_ImportsActivatesAndReadsBack(t *testing.T) {
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
	if res.APIID != "wm-api-0001" {
		t.Errorf("APIID = %q, want wm-api-0001", res.APIID)
	}
	if res.RevisionID != "" {
		t.Errorf("RevisionID = %q, want empty (no revision lifecycle)", res.RevisionID)
	}
	if !res.Published {
		t.Error("Published = false, want true (activated)")
	}
	if !res.Created {
		t.Error("Created = false, want true on first publish")
	}
	want := "http://webmethods-real:5555/gateway/accounts-read/1.0.0"
	if res.InvocationURL != want {
		t.Errorf("InvocationURL = %q, want %q", res.InvocationURL, want)
	}

	// Lifecycle: health preflight, one import POST, the separate activate PUT.
	if got := mock.countRequests("GET /rest/apigateway/health"); got != 1 {
		t.Errorf("health preflight count = %d, want 1", got)
	}
	if got := mock.countRequests("POST /rest/apigateway/apis"); got != 1 {
		t.Errorf("create count = %d, want 1", got)
	}
	if got := mock.countRequests("PUT /rest/apigateway/apis/wm-api-0001/activate"); got != 1 {
		t.Errorf("activate count = %d, want 1 (import alone does not serve traffic)", got)
	}

	// The gateway holds an ACTIVE record built from the import payload.
	stored := mock.apis["wm-api-0001"]
	if stored == nil {
		t.Fatal("server did not store the api")
	}
	if !stored.rec.IsActive {
		t.Error("stored isActive = false, want true after activate")
	}
	if got := stored.payload["type"]; got != "openapi" {
		t.Errorf("import payload type = %v, want openapi", got)
	}
	def, ok := stored.payload["apiDefinition"].(map[string]any)
	if !ok {
		t.Fatalf("apiDefinition is %T, want a JSON object", stored.payload["apiDefinition"])
	}
	// Backend re-point: servers[] must carry the authoritative upstream.
	servers, _ := def["servers"].([]any)
	if len(servers) != 1 {
		t.Fatalf("apiDefinition servers = %v, want exactly the injected backend", def["servers"])
	}
	if url := servers[0].(map[string]any)["url"]; url != api.BackendURL {
		t.Errorf("injected server url = %v, want %q", url, api.BackendURL)
	}
	// 10.15 RefProperty crash guard: no $ref must survive in response schemas.
	rawDef, _ := json.Marshal(def)
	if strings.Contains(string(rawDef), `"$ref"`) {
		t.Error("apiDefinition still contains a $ref response schema (10.15 RefProperty crash)")
	}
}

func TestPublish_IdempotentUpdatesInPlace(t *testing.T) {
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

	// Second publish with the SAME api must converge via PUT on the existing
	// record: same id, Created=false, exactly one POST overall.
	second, err := a.Publish(context.Background(), api)
	if err != nil {
		t.Fatalf("second Publish: %v", err)
	}
	if second.Created {
		t.Error("second publish Created = true, want false (idempotent update)")
	}
	if second.APIID != first.APIID {
		t.Errorf("apiId drifted: %q -> %q", first.APIID, second.APIID)
	}
	if len(mock.apis) != 1 {
		t.Fatalf("server holds %d apis after re-publish, want 1 (no duplicate)", len(mock.apis))
	}
	if got := mock.countRequests("POST /rest/apigateway/apis"); got != 1 {
		t.Errorf("create POST count = %d over two publishes, want 1", got)
	}
	if got := mock.countRequests("PUT /rest/apigateway/apis/" + first.APIID); got < 1 {
		t.Errorf("update PUT count = %d, want >= 1 (re-apply converges via PUT)", got)
	}
	// Already active after the first publish: no second activate call.
	if got := mock.countRequests("PUT /rest/apigateway/apis/" + first.APIID + "/activate"); got != 1 {
		t.Errorf("activate count = %d over two publishes, want 1 (already-active is left untouched)", got)
	}
}

func TestPublish_Conflict409FallsBackToPUT(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newAdapter(t, srv)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("seed Publish: %v", err)
	}

	// Same name, NEW version: the pre-list finds no name+version match, so the
	// adapter POSTs — and the gateway answers 409 (name conflict). Le produit
	// refuse AUSSI le changement de version in-place au PUT (prouvé live), donc
	// l'adapter doit minter la nouvelle version via POST /apis/{id}/versions
	// puis PUT le payload d'import dessus : les DEUX versions coexistent.
	mock.conflictNextCreate = true
	api.Version = "2.0.0"
	res, err := a.Publish(context.Background(), api)
	if err != nil {
		t.Fatalf("conflict Publish: %v", err)
	}
	if len(mock.apis) != 2 {
		t.Fatalf("server holds %d apis after version-conflict fallback, want 2 (v1 + v2 coexistent)", len(mock.apis))
	}
	if got := mock.apis[res.APIID].rec.APIVersion; got != "2.0.0" {
		t.Errorf("apiVersion of the minted record = %q, want 2.0.0", got)
	}
	if !res.Created {
		t.Errorf("Created = false after version mint, want true (new record)")
	}
	if !mock.apis[res.APIID].rec.IsActive {
		t.Errorf("minted version not activated by Publish")
	}
}

func TestPublish_SurfacesActionable401(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, err := New(adapter.Config{
		AdminURL:    srv.URL,
		GatewayURL:  srv.URL,
		Credentials: map[string]string{"username": "Administrator", "password": "wrong"},
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	herr := a.Health(context.Background())
	if herr == nil {
		t.Fatal("Health with bad credentials succeeded, want 401 error")
	}
	if !strings.Contains(herr.Error(), "401") {
		t.Errorf("error %q should carry the 401 status", herr.Error())
	}
}

func TestHealth_RejectsRedStatus(t *testing.T) {
	mock := newMockGateway()
	mock.healthDoc = map[string]any{"status": "red"}
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, _ := newAdapter(t, srv)
	if err := a.Health(context.Background()); err == nil {
		t.Fatal("Health succeeded with status=red, want error")
	}
}

func TestList_DecodesAPIResponseEnvelope(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newAdapter(t, srv)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	list, err := a.List(context.Background())
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(list) != 1 {
		t.Fatalf("List returned %d apis, want 1", len(list))
	}
	got := list[0]
	if got.Name != "accounts-read" || got.Version != "1.0.0" {
		t.Errorf("List item = %+v, want accounts-read v1.0.0", got)
	}
	if got.BasePath != "/gateway/accounts-read/1.0.0" {
		t.Errorf("BasePath = %q, want the derived /gateway/{name}/{version}", got.BasePath)
	}
	if got.Gateway != gatewayName {
		t.Errorf("Gateway = %q, want %q", got.Gateway, gatewayName)
	}
}

func TestCreateConsumer_CreatesApplicationAndAssociates(t *testing.T) {
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

	if res.ConsumerID != "wm-app-0001" {
		t.Errorf("ConsumerID = %q, want wm-app-0001", res.ConsumerID)
	}
	if res.ConsumerKey != spec.ClientID {
		t.Errorf("ConsumerKey = %q, want %q (echo of the Keycloak clientId)", res.ConsumerKey, spec.ClientID)
	}
	if res.ConsumerSecret != "" {
		t.Errorf("ConsumerSecret = %q, want empty (gateway mints no secret)", res.ConsumerSecret)
	}
	if !strings.Contains(res.TokenHint, spec.ClientID) {
		t.Errorf("TokenHint %q does not mention clientId", res.TokenHint)
	}

	// The application exists and is associated with the published API.
	app := mock.apps["wm-app-0001"]
	if app == nil {
		t.Fatal("server did not store the application")
	}
	if app.Name != "partner-app" {
		t.Errorf("application name = %q, want partner-app", app.Name)
	}
	if !strings.Contains(app.Description, spec.ClientID) {
		t.Errorf("application description %q does not record the clientId", app.Description)
	}
	if got := mock.appAPIs["wm-app-0001"]; len(got) != 1 || got[0] != "wm-api-0001" {
		t.Errorf("associated apiIDs = %v, want [wm-api-0001]", got)
	}
}

func TestCreateConsumer_IdempotentReusesApplication(t *testing.T) {
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
	if first.ConsumerID != second.ConsumerID {
		t.Errorf("application id drifted: %q -> %q", first.ConsumerID, second.ConsumerID)
	}
	if len(mock.apps) != 1 {
		t.Fatalf("server holds %d applications after re-apply, want 1 (no duplicate)", len(mock.apps))
	}
	if got := mock.countRequests("POST /rest/apigateway/applications"); got != 1 {
		t.Errorf("application POST count = %d, want 1", got)
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
	_, err := a.CreateConsumer(context.Background(), api, &adapter.ConsumerSpec{Name: "x"})
	if err == nil {
		t.Fatal("CreateConsumer with empty clientId succeeded, want error")
	}
	if !strings.Contains(err.Error(), "clientId") {
		t.Errorf("error %q does not mention clientId requirement", err.Error())
	}
}

func TestCreateConsumer_RequiresPublishedAPI(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newAdapter(t, srv)
	_, err := a.CreateConsumer(context.Background(), api, &adapter.ConsumerSpec{Name: "x", ClientID: "kc-1"})
	if err == nil {
		t.Fatal("CreateConsumer before Publish succeeded, want error")
	}
	if !strings.Contains(err.Error(), "not published") {
		t.Errorf("error %q should say the api is not published", err.Error())
	}
}

func TestSpecToJSON_RequiresContract(t *testing.T) {
	_, err := specToJSON(&adapter.NormalizedAPI{Name: "x", Version: "1.0.0"})
	if err == nil {
		t.Fatal("specToJSON without a contract succeeded, want error (import-only product)")
	}
}

func TestSpecFixes_DowngradeAndSanitize(t *testing.T) {
	out := downgradeOpenAPI31([]byte(`{"openapi":"3.1.0","info":{"title":"t"}}`))
	var parsed map[string]any
	if err := json.Unmarshal(out, &parsed); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if parsed["openapi"] != "3.0.3" {
		t.Errorf("openapi = %v, want 3.0.3 (10.15 rejects 3.1)", parsed["openapi"])
	}
	if got := sanitizeWMName("foo bar/baz"); got != "foo-bar-baz" {
		t.Errorf("sanitizeWMName = %q, want foo-bar-baz", got)
	}
}

func TestSpecFixes_BooleanAdditionalProperties(t *testing.T) {
	// Boolean additionalProperties breaks the PUT /apis update path on 10.15
	// (500 "Cannot construct instance of Schema") — proven live on the proxy
	// allowlist contract: import POST passes, the idempotent re-apply does not.
	in := []byte(`{"openapi":"3.0.0","components":{"schemas":{"free":{"type":"object","additionalProperties":true},"closed":{"type":"object","additionalProperties":false},"typed":{"type":"object","additionalProperties":{"type":"string"}}}}}`)
	out := objectifyBooleanAdditionalProperties(in)
	var parsed struct {
		Components struct {
			Schemas map[string]map[string]any `json:"schemas"`
		} `json:"components"`
	}
	if err := json.Unmarshal(out, &parsed); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	for _, name := range []string{"free", "closed"} {
		ap := parsed.Components.Schemas[name]["additionalProperties"]
		if m, ok := ap.(map[string]any); !ok || len(m) != 0 {
			t.Errorf("schemas.%s.additionalProperties = %v, want {} (boolean form rejected by 10.15 PUT)", name, ap)
		}
	}
	if ap, ok := parsed.Components.Schemas["typed"]["additionalProperties"].(map[string]any); !ok || ap["type"] != "string" {
		t.Errorf("schemas.typed.additionalProperties altered: %v, want untouched typed schema", parsed.Components.Schemas["typed"]["additionalProperties"])
	}
	// No boolean form → byte-identical no-op (the transform must not reorder
	// untouched documents).
	clean := []byte(`{"openapi":"3.0.0","paths":{}}`)
	if got := objectifyBooleanAdditionalProperties(clean); string(got) != string(clean) {
		t.Errorf("no-op rewrite changed the document: %s", got)
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
