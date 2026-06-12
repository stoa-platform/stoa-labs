package main

// Integration test: replays over HTTP (httptest on the COMPLETE handler,
// Basic auth included) the exact call sequence of the labctl webmethods
// adapter, followed by the multi-env ${alias} routing converge the CI plan
// performs against the env mocks:
//
//	health → list → POST api (import) → activate → read-back →
//	GET policy → PUT routing action ${alias} (ENVELOPED, with read-back
//	assert against the naked-PUT trap) → POST endpoint alias →
//	data-plane resolve (per-request alias resolution).
//
// The mock module cannot import the real adapter (labctl keeps it under
// internal/), so the e2e proof with the real binary lives in smoke.sh; this
// test pins the same wire sequence in Go.

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// client is a tiny admin client speaking the adapter's dialect (Basic auth,
// JSON in/out) against a live httptest server.
type client struct {
	t    *testing.T
	base string
	http *http.Client
}

func (c *client) do(method, path string, body any, auth bool) (int, map[string]any) {
	c.t.Helper()
	var rd io.Reader
	if body != nil {
		buf, err := json.Marshal(body)
		if err != nil {
			c.t.Fatalf("marshal: %v", err)
		}
		rd = bytes.NewReader(buf)
	}
	req, err := http.NewRequest(method, c.base+path, rd)
	if err != nil {
		c.t.Fatalf("request: %v", err)
	}
	if auth {
		req.SetBasicAuth(testUser, testPass)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		c.t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var out map[string]any
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &out); err != nil {
			c.t.Fatalf("%s %s: decode %q: %v", method, path, raw, err)
		}
	}
	return resp.StatusCode, out
}

func TestIntegration_AdapterSequenceThenMultiEnvRouting(t *testing.T) {
	t.Setenv("JWT_ISSUER", "")
	srv := httptest.NewServer(NewServer().Handler())
	defer srv.Close()
	c := &client{t: t, base: srv.URL, http: srv.Client()}

	// 1. Health preflight: 401 without Basic, 200 green with it — exactly what
	// the adapter's fail-fast preflight relies on.
	if code, _ := c.do("GET", "/rest/apigateway/health", nil, false); code != 401 {
		t.Fatalf("health without auth = %d, want 401", code)
	}
	code, health := c.do("GET", "/rest/apigateway/health", nil, true)
	if code != 200 || health["status"] != "green" {
		t.Fatalf("health = %d %v, want 200 green", code, health)
	}

	// 2. Idempotency pre-list: empty envelope {"apiResponse":[]}.
	code, list := c.do("GET", "/rest/apigateway/apis", nil, true)
	if code != 200 {
		t.Fatalf("list = %d", code)
	}
	if items, _ := list["apiResponse"].([]any); len(items) != 0 {
		t.Fatalf("pre-list = %v, want empty", list)
	}

	// 3. Import (POST /apis) — nested create envelope, isActive=false.
	code, created := c.do("POST", "/rest/apigateway/apis", importBody("payments-init", "1.0.0"), true)
	if code != 201 {
		t.Fatalf("import = %d %v", code, created)
	}
	api := created["apiResponse"].(map[string]any)["api"].(map[string]any)
	apiID := api["id"].(string)
	if active, _ := api["isActive"].(bool); active {
		t.Fatal("import must not activate")
	}

	// 4. Separate activation + read-back (ensureActive).
	if code, _ := c.do("PUT", "/rest/apigateway/apis/"+apiID+"/activate", nil, true); code != 200 {
		t.Fatalf("activate = %d", code)
	}
	code, got := c.do("GET", "/rest/apigateway/apis/"+apiID, nil, true)
	api = got["apiResponse"].(map[string]any)["api"].(map[string]any)
	if code != 200 || api["isActive"] != true {
		t.Fatalf("post-activate read-back = %d %v", code, api)
	}
	polID := api["policies"].([]any)[0].(string)

	// 5. GET the default policy; locate the routing-stage action.
	code, polDoc := c.do("GET", "/rest/apigateway/policies/"+polID, nil, true)
	if code != 200 {
		t.Fatalf("get policy = %d", code)
	}
	pol := polDoc["policy"].(map[string]any)
	var actID string
	for _, st := range pol["policyEnforcements"].([]any) {
		sm := st.(map[string]any)
		if sm["stageKey"] == "routing" {
			actID = sm["enforcements"].([]any)[0].(map[string]any)["enforcementObjectId"].(string)
		}
	}
	if actID == "" {
		t.Fatal("default policy has no routing stage")
	}

	// 6. POST the endpoint alias (NAKED body, live-captured shape) and read it
	// back through the {"alias":{...}} envelope.
	code, alResp := c.do("POST", "/rest/apigateway/alias", map[string]any{
		"name":                  "payments-backend",
		"type":                  "endpoint",
		"endPointURI":           "http://dev.payments.internal:8081/v1",
		"optimizationTechnique": "None",
		"passSecurityHeaders":   true,
	}, true)
	if code != 201 {
		t.Fatalf("create alias = %d %v", code, alResp)
	}
	aliasID := alResp["alias"].(map[string]any)["id"].(string)

	// 7. THE TRAP first: a NAKED PUT on the routing action answers 200 but must
	// NOT persist — then the ENVELOPED converge (read-back, endpointUri only).
	code, _ = c.do("PUT", "/rest/apigateway/policyActions/"+actID, map[string]any{
		"id":          actID,
		"templateKey": "straightThroughRouting",
		"parameters":  []any{map[string]any{"templateKey": "endpointUri", "values": []any{"http://evil/${sys:resource_path}"}}},
	}, true)
	if code != 200 {
		t.Fatalf("naked PUT = %d, want 200 (silent no-op)", code)
	}
	_, actDoc := c.do("GET", "/rest/apigateway/policyActions/"+actID, nil, true)
	act := actDoc["policyAction"].(map[string]any)
	if uri := paramValue(act["parameters"].([]any), "endpointUri"); uri != "http://backend.internal:8080/base/${sys:resource_path}" {
		t.Fatalf("naked PUT persisted: endpointUri = %q", uri)
	}
	for _, p := range act["parameters"].([]any) {
		pm := p.(map[string]any)
		if pm["templateKey"] == "endpointUri" {
			pm["values"] = []any{"${payments-backend}/${sys:resource_path}"}
		}
	}
	code, _ = c.do("PUT", "/rest/apigateway/policyActions/"+actID, map[string]any{"policyAction": act}, true)
	if code != 200 {
		t.Fatalf("enveloped PUT = %d", code)
	}
	// Read-back assert (the discipline the trap makes mandatory) + the unknown
	// "method" param must have survived the converge.
	_, actDoc = c.do("GET", "/rest/apigateway/policyActions/"+actID, nil, true)
	act = actDoc["policyAction"].(map[string]any)
	if uri := paramValue(act["parameters"].([]any), "endpointUri"); uri != "${payments-backend}/${sys:resource_path}" {
		t.Fatalf("enveloped PUT did not stick: %q", uri)
	}
	if got := paramValue(act["parameters"].([]any), "method"); got != "CUSTOM" {
		t.Fatalf("method param lost on converge: %q", got)
	}

	// 8. Data-plane resolve: ${alias} substituted per request.
	dpURL := srv.URL + "/gateway/payments-init/1.0.0/accounts"
	resp, err := srv.Client().Get(dpURL)
	if err != nil {
		t.Fatalf("data-plane: %v", err)
	}
	var dp map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&dp)
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("data-plane = %d %v", resp.StatusCode, dp)
	}
	if dp["resolved_url"] != "http://dev.payments.internal:8081/v1/accounts" || dp["alias_resolved"] != true {
		t.Fatalf("data-plane resolution = %v", dp)
	}

	// 9. Multi-env switch: ONE alias PUT re-routes the next request (dev→rec),
	// no reactivation, no policy edit — the demo's load-bearing property.
	code, _ = c.do("PUT", "/rest/apigateway/alias/"+aliasID, map[string]any{
		"name":                  "payments-backend",
		"type":                  "endpoint",
		"endPointURI":           "http://rec.payments.internal:8082/v1",
		"optimizationTechnique": "None",
		"passSecurityHeaders":   true,
	}, true)
	if code != 200 {
		t.Fatalf("alias PUT = %d", code)
	}
	resp, err = srv.Client().Get(dpURL)
	if err != nil {
		t.Fatalf("data-plane: %v", err)
	}
	dp = map[string]any{}
	_ = json.NewDecoder(resp.Body).Decode(&dp)
	resp.Body.Close()
	if dp["resolved_url"] != "http://rec.payments.internal:8082/v1/accounts" {
		t.Fatalf("alias edit did not re-route: %v", dp)
	}

	// 10. Re-import (PUT /apis/{id}) preserves the ${alias} routing — the
	// defensive-convergence guarantee the CI plan leans on.
	code, _ = c.do("PUT", "/rest/apigateway/apis/"+apiID, importBody("payments-init", "1.0.0"), true)
	if code != 200 {
		t.Fatalf("re-import = %d", code)
	}
	_, actDoc = c.do("GET", "/rest/apigateway/policyActions/"+actID, nil, true)
	act = actDoc["policyAction"].(map[string]any)
	if uri := paramValue(act["parameters"].([]any), "endpointUri"); uri != "${payments-backend}/${sys:resource_path}" {
		t.Fatalf("re-import clobbered the routing: %q", uri)
	}
}

// TestIntegration_ConsumerSequence replays the adapter's CreateConsumer wire
// sequence: list apis → list applications → POST application → PUT
// /applications/{id}/apis — plus the get/update round-trip the OAuth2 binding
// uses (identifiers preserved through the envelope).
func TestIntegration_ConsumerSequence(t *testing.T) {
	t.Setenv("JWT_ISSUER", "")
	srv := httptest.NewServer(NewServer().Handler())
	defer srv.Close()
	c := &client{t: t, base: srv.URL, http: srv.Client()}

	code, created := c.do("POST", "/rest/apigateway/apis", importBody("accounts-read", "1.0.0"), true)
	if code != 201 {
		t.Fatalf("import = %d", code)
	}
	apiID := created["apiResponse"].(map[string]any)["api"].(map[string]any)["id"].(string)
	c.do("PUT", "/rest/apigateway/apis/"+apiID+"/activate", nil, true)

	code, appResp := c.do("POST", "/rest/apigateway/applications", map[string]any{
		"name": "partner-app", "description": "labctl consumer (Keycloak clientId kc-1)",
	}, true)
	if code != 201 {
		t.Fatalf("create app = %d", code)
	}
	appID := appResp["id"].(string)

	code, _ = c.do("PUT", "/rest/apigateway/applications/"+appID+"/apis",
		map[string]any{"apiIDs": []string{apiID}}, true)
	if code != 204 {
		t.Fatalf("associate = %d, want 204", code)
	}

	// OAuth2 binding round-trip: GET envelope {"applications":[{...}]}, mutate
	// identifiers/authStrategyIds only, PUT the whole record back.
	_, getResp := c.do("GET", "/rest/apigateway/applications/"+appID, nil, true)
	app := getResp["applications"].([]any)[0].(map[string]any)
	app["identifiers"] = []any{map[string]any{
		"key": "openIdClaims", "name": "azp", "value": []any{"kc-1"},
	}}
	code, putResp := c.do("PUT", "/rest/apigateway/applications/"+appID, app, true)
	if code != 200 {
		t.Fatalf("update app = %d %v", code, putResp)
	}
	back := putResp["applications"].([]any)[0].(map[string]any)
	if apis, _ := back["consumingAPIs"].([]any); len(apis) != 1 || apis[0] != apiID {
		t.Fatalf("consumingAPIs not preserved through the PUT: %v", back["consumingAPIs"])
	}
}

// TestIntegration_InboundAuthProjectionSequence replays the signature-only
// inbound-auth projection of `labctl apply` (the targets.yaml issuer/jwksUri
// path): list aliases → POST authServerAlias (NAKED) → list policyActions →
// POST evaluatePolicy (ENVELOPED) → GET policy → PUT policy with the IAM stage
// → read-back.
func TestIntegration_InboundAuthProjectionSequence(t *testing.T) {
	t.Setenv("JWT_ISSUER", "")
	srv := httptest.NewServer(NewServer().Handler())
	defer srv.Close()
	c := &client{t: t, base: srv.URL, http: srv.Client()}

	code, created := c.do("POST", "/rest/apigateway/apis", importBody("accounts-read", "1.0.0"), true)
	if code != 201 {
		t.Fatalf("import = %d", code)
	}
	api := created["apiResponse"].(map[string]any)["api"].(map[string]any)
	apiID := api["id"].(string)
	polID := api["policies"].([]any)[0].(string)
	c.do("PUT", "/rest/apigateway/apis/"+apiID+"/activate", nil, true)

	// Alias list carries the built-in LOCAL_IS "local" record (name lookups must
	// filter, like live); then POST the EXTERNAL alias, naked body.
	_, aliases := c.do("GET", "/rest/apigateway/alias", nil, true)
	if items, _ := aliases["alias"].([]any); len(items) != 1 {
		t.Fatalf("alias pre-list = %v, want only the local built-in", aliases)
	}
	code, _ = c.do("POST", "/rest/apigateway/alias", map[string]any{
		"name": "KeycloakStoaLab", "type": "authServerAlias", "authServerType": "EXTERNAL",
		"localIntrospectionConfig": map[string]any{
			"issuer":  "http://localhost:8480/realms/stoa-lab",
			"jwksuri": "http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/certs",
		},
	}, true)
	if code != 201 {
		t.Fatalf("create auth-server alias = %d", code)
	}

	// POST the Identify & Authorize action (ENVELOPED) — the display name comes
	// back NORMALISED, so matching by name would break here exactly as live.
	code, actResp := c.do("POST", "/rest/apigateway/policyActions", map[string]any{"policyAction": map[string]any{
		"names":       []any{map[string]any{"value": "Identify & Authorize JWT (labctl)", "locale": "en"}},
		"templateKey": "evaluatePolicy",
		"parameters": []any{
			map[string]any{"templateKey": "logicalConnector", "values": []any{"OR"}},
			map[string]any{"templateKey": "allowAnonymous", "values": []any{"false"}},
			map[string]any{"templateKey": "IdentificationRule", "parameters": []any{
				map[string]any{"templateKey": "applicationLookup", "values": []any{"open"}},
				map[string]any{"templateKey": "identificationType", "values": []any{"jwtClaims"}},
			}},
		},
		"active": true,
	}}, true)
	if code != 201 {
		t.Fatalf("create IAM action = %d", code)
	}
	iamAct := actResp["policyAction"].(map[string]any)
	iamID := iamAct["id"].(string)
	if name := iamAct["names"].([]any)[0].(map[string]any)["value"]; name != "Identify & Authorize" {
		t.Fatalf("action name not normalised: %v", name)
	}

	// Attach the IAM stage on the READ-BACK policy (wholesale-replacing PUT).
	_, polDoc := c.do("GET", "/rest/apigateway/policies/"+polID, nil, true)
	pol := polDoc["policy"].(map[string]any)
	pol["policyEnforcements"] = append(pol["policyEnforcements"].([]any), map[string]any{
		"stageKey":     "IAM",
		"enforcements": []any{map[string]any{"enforcementObjectId": iamID, "order": nil}},
	})
	code, _ = c.do("PUT", "/rest/apigateway/policies/"+polID, map[string]any{"policy": pol}, true)
	if code != 200 {
		t.Fatalf("attach IAM stage = %d", code)
	}
	_, after := c.do("GET", "/rest/apigateway/policies/"+polID, nil, true)
	if !policyHasStage(after["policy"].(map[string]any), "IAM", iamID) {
		t.Fatalf("IAM stage did not stick: %v", after)
	}
	// The routing stage must have survived the wholesale PUT (it was re-listed).
	if !policyHasStageKey(after["policy"].(map[string]any), "routing") {
		t.Fatal("routing stage lost through the policy PUT")
	}
}

func policyHasStage(pol map[string]any, stageKey, actionID string) bool {
	stages, _ := pol["policyEnforcements"].([]any)
	for _, st := range stages {
		sm, _ := st.(map[string]any)
		if sm == nil || sm["stageKey"] != stageKey {
			continue
		}
		enfs, _ := sm["enforcements"].([]any)
		for _, e := range enfs {
			if em, _ := e.(map[string]any); em != nil && em["enforcementObjectId"] == actionID {
				return true
			}
		}
	}
	return false
}

func policyHasStageKey(pol map[string]any, stageKey string) bool {
	stages, _ := pol["policyEnforcements"].([]any)
	for _, st := range stages {
		if sm, _ := st.(map[string]any); sm != nil && sm["stageKey"] == stageKey {
			return true
		}
	}
	return false
}
