package main

// Unit tests of the 10.15-dialect surface — envelopes, lifecycle and TRAPS
// (naked PUT no-op, flat outbound NPE, masked credential password). The full
// labctl-adapter sequence is replayed in integration_test.go.

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const (
	testUser = "Administrator"
	testPass = "manage"
)

func newTestServer(t *testing.T) http.Handler {
	t.Helper()
	t.Setenv("JWT_ISSUER", "") // data-plane auth off in unit tests
	return NewServer().Handler()
}

// doAdmin issues one admin call WITH Basic auth (the product enforces it on
// every /rest/apigateway/* call).
func doAdmin(t *testing.T, h http.Handler, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	return doRaw(t, h, method, path, body, true)
}

// do issues one call WITHOUT credentials (data-plane, or 401 checks).
func do(t *testing.T, h http.Handler, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	return doRaw(t, h, method, path, body, false)
}

func doRaw(t *testing.T, h http.Handler, method, path string, body any, auth bool) *httptest.ResponseRecorder {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatalf("encode: %v", err)
		}
	}
	req := httptest.NewRequest(method, path, &buf)
	if auth {
		req.SetBasicAuth(testUser, testPass)
	}
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	return rr
}

func decode(t *testing.T, rr *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode %q: %v", rr.Body.String(), err)
	}
	return out
}

// importBody is a minimal import payload: one templated path, one fixed path,
// a servers[0].url the default routing action must derive from.
func importBody(name, version string) map[string]any {
	return map[string]any{
		"apiName":    name,
		"apiVersion": version,
		"type":       "openapi",
		"apiDefinition": map[string]any{
			"openapi": "3.0.3",
			"info":    map[string]any{"title": name, "version": version},
			"servers": []any{map[string]any{"url": "http://backend.internal:8080/base"}},
			"paths": map[string]any{
				"/accounts":      map[string]any{"get": map[string]any{}},
				"/accounts/{id}": map[string]any{"get": map[string]any{}},
			},
		},
	}
}

// importAPI creates + activates one API and returns (apiID, policyID).
func importAPI(t *testing.T, h http.Handler, name, version string) (string, string) {
	t.Helper()
	rr := doAdmin(t, h, "POST", "/rest/apigateway/apis", importBody(name, version))
	if rr.Code != http.StatusCreated {
		t.Fatalf("import code = %d body=%s", rr.Code, rr.Body)
	}
	env := decode(t, rr)["apiResponse"].(map[string]any)
	api := env["api"].(map[string]any)
	id, _ := api["id"].(string)
	if id == "" {
		t.Fatalf("import response carries no id: %s", rr.Body)
	}
	if active, _ := api["isActive"].(bool); active {
		t.Fatal("import must NOT activate (isActive=true right after POST)")
	}
	if rr := doAdmin(t, h, "PUT", "/rest/apigateway/apis/"+id+"/activate", nil); rr.Code != http.StatusOK {
		t.Fatalf("activate code = %d body=%s", rr.Code, rr.Body)
	}
	pols, _ := api["policies"].([]any)
	if len(pols) != 1 {
		t.Fatalf("import minted %d policies, want 1 (Default Policy)", len(pols))
	}
	return id, pols[0].(string)
}

// routingActionID extracts the routing-stage action id from a policy document.
func routingActionID(t *testing.T, h http.Handler, policyID string) string {
	t.Helper()
	rr := doAdmin(t, h, "GET", "/rest/apigateway/policies/"+policyID, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("get policy code = %d body=%s", rr.Code, rr.Body)
	}
	pol := decode(t, rr)["policy"].(map[string]any)
	for _, st := range pol["policyEnforcements"].([]any) {
		sm := st.(map[string]any)
		if sm["stageKey"] != "routing" {
			continue
		}
		enfs := sm["enforcements"].([]any)
		return enfs[0].(map[string]any)["enforcementObjectId"].(string)
	}
	t.Fatal("policy has no routing stage")
	return ""
}

// --- auth gate ----------------------------------------------------------------

func TestAdminSurface_RequiresBasicAuth(t *testing.T) {
	h := newTestServer(t)
	rr := do(t, h, "GET", "/rest/apigateway/health", nil)
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("health without credentials = %d, want 401", rr.Code)
	}
	if got := rr.Header().Get("WWW-Authenticate"); !strings.Contains(got, "Basic") {
		t.Errorf("missing Basic challenge, got %q", got)
	}
	rr = doAdmin(t, h, "GET", "/rest/apigateway/health", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("health with credentials = %d, want 200", rr.Code)
	}
	if status := decode(t, rr)["status"]; status != "green" {
		t.Errorf("health status = %v, want green", status)
	}
}

func TestLegacyHealth_StaysOpen(t *testing.T) {
	// scripts/up.sh and smoke-test.sh probe this route without credentials.
	rr := do(t, newTestServer(t), "GET", "/rest/apigateway/is/health", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("legacy health = %d, want 200 (open)", rr.Code)
	}
	if alive := decode(t, rr)["isAlive"]; alive != true {
		t.Errorf("isAlive = %v, want true", alive)
	}
}

// --- import lifecycle -----------------------------------------------------------

func TestImport_MintsDefaultPolicyAndRoutingAction(t *testing.T) {
	h := newTestServer(t)
	_, polID := importAPI(t, h, "accounts-read", "1.0.0")

	actID := routingActionID(t, h, polID)
	rr := doAdmin(t, h, "GET", "/rest/apigateway/policyActions/"+actID, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("get action code = %d body=%s", rr.Code, rr.Body)
	}
	act := decode(t, rr)["policyAction"].(map[string]any)
	if act["templateKey"] != "straightThroughRouting" {
		t.Errorf("templateKey = %v, want straightThroughRouting", act["templateKey"])
	}
	params := act["parameters"].([]any)
	uri := paramValue(params, "endpointUri")
	if uri != "http://backend.internal:8080/base/${sys:resource_path}" {
		t.Errorf("default endpointUri = %q, want servers[0].url + /${sys:resource_path}", uri)
	}
	// The UI's extra param the live build carries — converge code must preserve it.
	if got := paramValue(params, "method"); got != "CUSTOM" {
		t.Errorf("method param = %q, want CUSTOM", got)
	}
}

func TestImport_NameConflictIs409(t *testing.T) {
	h := newTestServer(t)
	importAPI(t, h, "accounts-read", "1.0.0")
	// Same name under ANOTHER version: the product's 409 the adapter falls back on.
	rr := doAdmin(t, h, "POST", "/rest/apigateway/apis", importBody("accounts-read", "2.0.0"))
	if rr.Code != http.StatusConflict {
		t.Fatalf("re-import same name = %d, want 409", rr.Code)
	}
}

func TestReimport_PreservesPolicyAndRoutingAction(t *testing.T) {
	h := newTestServer(t)
	apiID, polID := importAPI(t, h, "accounts-read", "1.0.0")
	actID := routingActionID(t, h, polID)

	// Re-point the routing at an ${alias} (enveloped PUT), then re-import.
	doAdmin(t, h, "POST", "/rest/apigateway/alias", map[string]any{
		"name": "env-backend", "type": "endpoint",
		"endPointURI":           "http://dev.internal:8081/base",
		"optimizationTechnique": "None", "passSecurityHeaders": true,
	})
	putRoutingURI(t, h, actID, "${env-backend}/${sys:resource_path}")

	rr := doAdmin(t, h, "PUT", "/rest/apigateway/apis/"+apiID, importBody("accounts-read", "1.0.0"))
	if rr.Code != http.StatusOK {
		t.Fatalf("re-import code = %d body=%s", rr.Code, rr.Body)
	}
	// Policy id unchanged, ${alias} routing intact — the live-observed behaviour.
	env := decode(t, rr)["apiResponse"].(map[string]any)["api"].(map[string]any)
	if got := env["policies"].([]any)[0].(string); got != polID {
		t.Errorf("policy id after re-import = %q, want %q (preserved)", got, polID)
	}
	rr = doAdmin(t, h, "GET", "/rest/apigateway/policyActions/"+actID, nil)
	act := decode(t, rr)["policyAction"].(map[string]any)
	if uri := paramValue(act["parameters"].([]any), "endpointUri"); uri != "${env-backend}/${sys:resource_path}" {
		t.Errorf("routing after re-import = %q, want the ${alias} intact", uri)
	}
}

// putRoutingURI converges the routing action like labctl does: read back, set
// ONLY endpointUri, PUT the whole record ENVELOPED.
func putRoutingURI(t *testing.T, h http.Handler, actID, uri string) {
	t.Helper()
	rr := doAdmin(t, h, "GET", "/rest/apigateway/policyActions/"+actID, nil)
	act := decode(t, rr)["policyAction"].(map[string]any)
	for _, p := range act["parameters"].([]any) {
		pm := p.(map[string]any)
		if pm["templateKey"] == "endpointUri" {
			pm["values"] = []any{uri}
		}
	}
	rr = doAdmin(t, h, "PUT", "/rest/apigateway/policyActions/"+actID, map[string]any{"policyAction": act})
	if rr.Code != http.StatusOK {
		t.Fatalf("enveloped PUT code = %d body=%s", rr.Code, rr.Body)
	}
}

// --- the policyActions PUT trap ---------------------------------------------------

func TestPolicyActionPUT_NakedBodyIsSilentNoOp(t *testing.T) {
	h := newTestServer(t)
	_, polID := importAPI(t, h, "accounts-read", "1.0.0")
	actID := routingActionID(t, h, polID)

	// NAKED body (no {"policyAction":...} envelope): the product answers 200
	// and persists NOTHING — reproduce exactly, so read-back asserts matter.
	naked := map[string]any{
		"id":          actID,
		"templateKey": "straightThroughRouting",
		"parameters": []any{
			map[string]any{"templateKey": "endpointUri", "values": []any{"http://evil.example/${sys:resource_path}"}},
		},
	}
	rr := doAdmin(t, h, "PUT", "/rest/apigateway/policyActions/"+actID, naked)
	if rr.Code != http.StatusOK {
		t.Fatalf("naked PUT code = %d, want 200 (the silent no-op trap)", rr.Code)
	}
	rr = doAdmin(t, h, "GET", "/rest/apigateway/policyActions/"+actID, nil)
	act := decode(t, rr)["policyAction"].(map[string]any)
	if uri := paramValue(act["parameters"].([]any), "endpointUri"); strings.Contains(uri, "evil") {
		t.Fatalf("naked PUT PERSISTED (%q) — the trap must be a no-op", uri)
	}
}

func TestOutboundAuthAction_FlatParamsNPE500(t *testing.T) {
	h := newTestServer(t)
	flat := map[string]any{"policyAction": map[string]any{
		"names":       []any{map[string]any{"value": "Outbound Auth", "locale": "en"}},
		"templateKey": "outboundTransportAuthentication",
		"parameters": []any{ // FLAT — the live NPE shape
			map[string]any{"templateKey": "authType", "values": []any{"ALIAS"}},
			map[string]any{"templateKey": "authMode", "values": []any{"NEW"}},
			map[string]any{"templateKey": "alias", "values": []any{"${creds}"}},
		},
	}}
	rr := doAdmin(t, h, "POST", "/rest/apigateway/policyActions", flat)
	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("flat outbound POST = %d, want 500 (OutboundTransportSecurityFactory NPE)", rr.Code)
	}
	if !strings.Contains(rr.Body.String(), "NullPointerException") {
		t.Errorf("500 body should mimic the NPE, got %s", rr.Body)
	}
}

// --- aliases ----------------------------------------------------------------------

func TestEndpointAlias_RequiresExactCasing(t *testing.T) {
	h := newTestServer(t)
	rr := doAdmin(t, h, "POST", "/rest/apigateway/alias", map[string]any{
		"name": "bad", "type": "endpoint",
		"endpointUri": "http://x", // wrong casing — inert on the product
	})
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("wrong-cased endPointURI = %d, want 400 (fail closed)", rr.Code)
	}
	if !strings.Contains(rr.Body.String(), "endPointURI") {
		t.Errorf("error should name the exact field, got %s", rr.Body)
	}
}

func TestCredentialAlias_PasswordMaskedOnReadBack(t *testing.T) {
	h := newTestServer(t)
	secret := base64.StdEncoding.EncodeToString([]byte("s3cret"))
	rr := doAdmin(t, h, "POST", "/rest/apigateway/alias", map[string]any{
		"name": "dev-creds", "type": "httpTransportSecurityAlias",
		"authType": "HTTP_BASIC", "authMode": "NEW",
		"httpAuthCredentials": map[string]any{"userName": "svc-dev", "password": secret},
	})
	if rr.Code != http.StatusCreated {
		t.Fatalf("create credential alias = %d body=%s", rr.Code, rr.Body)
	}
	al := decode(t, rr)["alias"].(map[string]any)
	id := al["id"].(string)

	rr = doAdmin(t, h, "GET", "/rest/apigateway/alias/"+id, nil)
	got := decode(t, rr)["alias"].(map[string]any)
	creds := got["httpAuthCredentials"].(map[string]any)
	masked := creds["password"].(string)
	if masked == secret {
		t.Fatal("password came back IN CLEAR — must be masked")
	}
	want := base64.StdEncoding.EncodeToString([]byte("******")) // len("s3cret") asterisks
	if masked != want {
		t.Errorf("masked password = %q, want base64 of asterisks %q", masked, want)
	}
}

func TestAlias_DuplicateNameIs409(t *testing.T) {
	h := newTestServer(t)
	body := map[string]any{
		"name": "dup", "type": "endpoint", "endPointURI": "http://x",
		"optimizationTechnique": "None", "passSecurityHeaders": true,
	}
	if rr := doAdmin(t, h, "POST", "/rest/apigateway/alias", body); rr.Code != http.StatusCreated {
		t.Fatalf("first create = %d", rr.Code)
	}
	if rr := doAdmin(t, h, "POST", "/rest/apigateway/alias", body); rr.Code != http.StatusConflict {
		t.Fatalf("duplicate create = %d, want 409", rr.Code)
	}
}

// --- data-plane --------------------------------------------------------------------

func TestDataPlane_InactiveAndAllowlist(t *testing.T) {
	h := newTestServer(t)
	rr := doAdmin(t, h, "POST", "/rest/apigateway/apis", importBody("accounts-read", "1.0.0"))
	api := decode(t, rr)["apiResponse"].(map[string]any)["api"].(map[string]any)
	id := api["id"].(string)

	// Imported but NOT activated: 503, import does not serve traffic.
	if rr := do(t, h, "GET", "/gateway/accounts-read/1.0.0/accounts", nil); rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("inactive api = %d, want 503", rr.Code)
	}
	doAdmin(t, h, "PUT", "/rest/apigateway/apis/"+id+"/activate", nil)

	// In-contract fixed and templated paths resolve.
	for _, path := range []string{"/gateway/accounts-read/1.0.0/accounts", "/gateway/accounts-read/1.0.0/accounts/123"} {
		rr := do(t, h, "GET", path, nil)
		if rr.Code != http.StatusOK {
			t.Fatalf("%s = %d body=%s", path, rr.Code, rr.Body)
		}
		body := decode(t, rr)
		if body["mock"] != true || body["api"] != "accounts-read" {
			t.Errorf("%s body = %v", path, body)
		}
	}
	// Out of contract: allowlist 404.
	if rr := do(t, h, "GET", "/gateway/accounts-read/1.0.0/not-in-contract", nil); rr.Code != http.StatusNotFound {
		t.Fatalf("out-of-contract = %d, want 404", rr.Code)
	}
	// Unknown api/version: 404.
	if rr := do(t, h, "GET", "/gateway/nope/9.9.9/accounts", nil); rr.Code != http.StatusNotFound {
		t.Fatalf("unknown api = %d, want 404", rr.Code)
	}
}

func TestDataPlane_AliasRoutingResolvesPerRequest(t *testing.T) {
	h := newTestServer(t)
	_, polID := importAPI(t, h, "accounts-read", "1.0.0")
	actID := routingActionID(t, h, polID)

	// Default routing (no alias): servers[0].url + resource.
	rr := do(t, h, "GET", "/gateway/accounts-read/1.0.0/accounts", nil)
	body := decode(t, rr)
	if body["resolved_url"] != "http://backend.internal:8080/base/accounts" {
		t.Errorf("default resolved_url = %v", body["resolved_url"])
	}
	if body["alias_resolved"] != false {
		t.Errorf("alias_resolved = %v, want false before ${alias} routing", body["alias_resolved"])
	}

	// ${alias} routing: POST the endpoint alias, re-point the action (enveloped).
	rr = doAdmin(t, h, "POST", "/rest/apigateway/alias", map[string]any{
		"name": "env-backend", "type": "endpoint",
		"endPointURI":           "http://dev.internal:8081/base",
		"optimizationTechnique": "None", "passSecurityHeaders": true,
	})
	if rr.Code != http.StatusCreated {
		t.Fatalf("create alias = %d body=%s", rr.Code, rr.Body)
	}
	aliasID := decode(t, rr)["alias"].(map[string]any)["id"].(string)
	putRoutingURI(t, h, actID, "${env-backend}/${sys:resource_path}")

	rr = do(t, h, "GET", "/gateway/accounts-read/1.0.0/accounts", nil)
	body = decode(t, rr)
	if body["resolved_url"] != "http://dev.internal:8081/base/accounts" {
		t.Errorf("dev resolved_url = %v", body["resolved_url"])
	}
	if body["alias_resolved"] != true {
		t.Errorf("alias_resolved = %v, want true", body["alias_resolved"])
	}

	// PER-REQUEST resolution: editing the alias re-routes instantly, no
	// reactivation, no policy edit.
	rr = doAdmin(t, h, "PUT", "/rest/apigateway/alias/"+aliasID, map[string]any{
		"name": "env-backend", "type": "endpoint",
		"endPointURI":           "http://rec.internal:8082/base",
		"optimizationTechnique": "None", "passSecurityHeaders": true,
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("update alias = %d body=%s", rr.Code, rr.Body)
	}
	rr = do(t, h, "GET", "/gateway/accounts-read/1.0.0/accounts", nil)
	if got := decode(t, rr)["resolved_url"]; got != "http://rec.internal:8082/base/accounts" {
		t.Errorf("rec resolved_url = %v (alias edit must re-route per request)", got)
	}

	// Missing alias: fail CLOSED (502), never a half-substituted passthrough.
	putRoutingURI(t, h, actID, "${ghost-alias}/${sys:resource_path}")
	if rr := do(t, h, "GET", "/gateway/accounts-read/1.0.0/accounts", nil); rr.Code != http.StatusBadGateway {
		t.Fatalf("missing alias = %d, want 502", rr.Code)
	}
}

func TestDataPlane_OutboundAuthResolvesCredentialAlias(t *testing.T) {
	h := newTestServer(t)
	_, polID := importAPI(t, h, "accounts-read", "1.0.0")

	secret := base64.StdEncoding.EncodeToString([]byte("s3cret"))
	doAdmin(t, h, "POST", "/rest/apigateway/alias", map[string]any{
		"name": "dev-creds", "type": "httpTransportSecurityAlias",
		"authType": "HTTP_BASIC", "authMode": "NEW",
		"httpAuthCredentials": map[string]any{"userName": "svc-dev", "password": secret},
	})

	// POST the outbound action (the live shape: ONE nested transportSecurity
	// group) and attach it to the policy's routing stage.
	rr := doAdmin(t, h, "POST", "/rest/apigateway/policyActions", map[string]any{"policyAction": map[string]any{
		"names":       []any{map[string]any{"value": "Outbound Auth – Transport", "locale": "en"}},
		"templateKey": "outboundTransportAuthentication",
		"parameters": []any{map[string]any{
			"templateKey": "transportSecurity",
			"parameters": []any{
				map[string]any{"templateKey": "authType", "values": []any{"ALIAS"}},
				map[string]any{"templateKey": "authMode", "values": []any{"NEW"}},
				map[string]any{"templateKey": "alias", "values": []any{"${dev-creds}"}},
			},
		}},
		"active": true,
	}})
	if rr.Code != http.StatusCreated {
		t.Fatalf("create outbound action = %d body=%s", rr.Code, rr.Body)
	}
	outID := decode(t, rr)["policyAction"].(map[string]any)["id"].(string)

	// Read-modify-write of the policy (the PUT replaces stages wholesale).
	rr = doAdmin(t, h, "GET", "/rest/apigateway/policies/"+polID, nil)
	pol := decode(t, rr)["policy"].(map[string]any)
	for _, st := range pol["policyEnforcements"].([]any) {
		sm := st.(map[string]any)
		if sm["stageKey"] == "routing" {
			sm["enforcements"] = append(sm["enforcements"].([]any),
				map[string]any{"enforcementObjectId": outID, "order": nil})
		}
	}
	rr = doAdmin(t, h, "PUT", "/rest/apigateway/policies/"+polID, map[string]any{"policy": pol})
	if rr.Code != http.StatusOK {
		t.Fatalf("put policy = %d body=%s", rr.Code, rr.Body)
	}

	rr = do(t, h, "GET", "/gateway/accounts-read/1.0.0/accounts", nil)
	body := decode(t, rr)
	if got := body["outbound_auth"]; got != "Basic svc-dev:***" {
		t.Errorf("outbound_auth = %v, want Basic svc-dev:*** (never the secret)", got)
	}
	if s := rr.Body.String(); strings.Contains(s, "s3cret") || strings.Contains(s, secret) {
		t.Fatal("data-plane response leaked the credential password")
	}
}

// --- consumer model ------------------------------------------------------------------

func TestApplications_EnvelopesAndIdentifierEnum(t *testing.T) {
	h := newTestServer(t)
	rr := doAdmin(t, h, "POST", "/rest/apigateway/applications", map[string]any{
		"name": "partner-app", "description": "labctl consumer",
	})
	if rr.Code != http.StatusCreated {
		t.Fatalf("create app = %d body=%s", rr.Code, rr.Body)
	}
	id := decode(t, rr)["id"].(string) // flat create response, like live

	// Single-record envelope {"applications":[{...}]}.
	rr = doAdmin(t, h, "GET", "/rest/apigateway/applications/"+id, nil)
	list := decode(t, rr)["applications"].([]any)
	if len(list) != 1 {
		t.Fatalf("get app envelope = %s", rr.Body)
	}

	// Associate, then prove consumingAPIs survives a whole-record PUT.
	rr = doAdmin(t, h, "PUT", "/rest/apigateway/applications/"+id+"/apis",
		map[string]any{"apiIDs": []string{"wm-api-0001"}})
	if rr.Code != http.StatusNoContent {
		t.Fatalf("associate = %d", rr.Code)
	}
	app := list[0].(map[string]any)
	app["identifiers"] = []any{map[string]any{
		"key": "openIdClaims", "name": "azp", "value": []any{"kc-client"},
	}}
	delete(app, "consumingAPIs") // a client PUT cannot clear the binding
	rr = doAdmin(t, h, "PUT", "/rest/apigateway/applications/"+id, app)
	if rr.Code != http.StatusOK {
		t.Fatalf("update app = %d body=%s", rr.Code, rr.Body)
	}
	got := decode(t, rr)["applications"].([]any)[0].(map[string]any)
	if apis, _ := got["consumingAPIs"].([]any); len(apis) != 1 {
		t.Errorf("consumingAPIs after PUT = %v, want preserved", got["consumingAPIs"])
	}

	// Unknown identifier key: 400 with the live errorDetails shape.
	app["identifiers"] = []any{map[string]any{"key": "tokens", "name": "x", "value": []any{"v"}}}
	rr = doAdmin(t, h, "PUT", "/rest/apigateway/applications/"+id, app)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("unknown identifier key = %d, want 400", rr.Code)
	}
	if !strings.Contains(rr.Body.String(), "Undefined 'key'") {
		t.Errorf("400 body should carry the live errorDetails, got %s", rr.Body)
	}
}

func TestStrategiesAndScopes_Envelopes(t *testing.T) {
	h := newTestServer(t)
	// Strategy: naked body, type must be UPPERCASE OAUTH2, ENVELOPED response.
	rr := doAdmin(t, h, "POST", "/rest/apigateway/strategies", map[string]any{
		"name": "OIDC-accounts-read", "type": "oauth2",
	})
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("lowercase oauth2 = %d, want 400", rr.Code)
	}
	rr = doAdmin(t, h, "POST", "/rest/apigateway/strategies", map[string]any{
		"name": "OIDC-accounts-read", "type": "OAUTH2",
		"authServerAlias": "KeycloakStoaLab", "clientId": "consumer", "audience": "accounts-read",
	})
	if rr.Code != http.StatusCreated {
		t.Fatalf("create strategy = %d body=%s", rr.Code, rr.Body)
	}
	if _, ok := decode(t, rr)["strategy"]; !ok {
		t.Fatalf("strategy create response not enveloped: %s", rr.Body)
	}
	// List is the BARE array shape on this build.
	rr = doAdmin(t, h, "GET", "/rest/apigateway/strategies", nil)
	var arr []map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &arr); err != nil || len(arr) != 1 {
		t.Fatalf("strategies list must be a bare array, got %s", rr.Body)
	}

	// Scope mapping: naked body, {"scopes":[...]} list envelope.
	rr = doAdmin(t, h, "POST", "/rest/apigateway/scopes", map[string]any{
		"scopeName": "KeycloakStoaLab:accounts.read", "apiScopes": []any{"wm-api-0001"},
	})
	if rr.Code != http.StatusCreated {
		t.Fatalf("create scope = %d body=%s", rr.Code, rr.Body)
	}
	rr = doAdmin(t, h, "GET", "/rest/apigateway/scopes", nil)
	if scopes, _ := decode(t, rr)["scopes"].([]any); len(scopes) != 1 {
		t.Fatalf("scopes list envelope = %s", rr.Body)
	}
}
