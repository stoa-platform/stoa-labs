package webmethods

// Unit tests for the routing-by-alias projection (endpoint alias + ${alias}
// straightThroughRouting + optional credential alias / Outbound Auth –
// Transport) and for the bearer-token auth mode, against the same httptest
// mock as webmethods_test.go. The mock reproduces the live-pinned 10.15 traps
// the projection must survive: the EXACT endPointURI casing, the MASKED
// credential-alias password on read-back (base64 of asterisks), the silent
// 200-no-op on a non-enveloped policyAction PUT, and the NPE 500 on FLAT
// outbound-auth parameters.

import (
	"context"
	"encoding/base64"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
)

const (
	testBackendDevURL = "http://backend-dev:8080/rest/accounts"
	testBackendUser   = "svc-accounts"
	testBackendPass   = "be-pass-s3cret"
)

// newRoutingAdapter builds an adapter with the routing knobs folded into
// Options exactly as targets.Target.ToConfig does. withCred adds the
// credential-alias projection (+ backend credentials).
func newRoutingAdapter(t *testing.T, srv *httptest.Server, withCred bool) (*Adapter, *adapter.NormalizedAPI) {
	t.Helper()
	creds := map[string]string{
		"username": testUser,
		"password": testPass,
	}
	opts := map[string]string{
		"routingEndpointAliasName": "{api}-backend",
		"routingEndpointAliasUrl":  testBackendDevURL,
	}
	if withCred {
		opts["routingCredentialAliasName"] = "{api}-backend-cred"
		creds["backendUsername"] = testBackendUser
		creds["backendPassword"] = testBackendPass
	}
	a, err := New(adapter.Config{
		Type:        gatewayName,
		Name:        gatewayName,
		AdminURL:    srv.URL,
		GatewayURL:  "http://webmethods-real:5555",
		Credentials: creds,
		Options:     opts,
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

// aliasByName returns the mock alias with the given name (nil when absent).
func aliasByName(mock *mockGateway, name string) map[string]any {
	for _, al := range mock.aliases {
		if al["name"] == name {
			return al
		}
	}
	return nil
}

// onlyRoutingAction returns the single import-minted straightThroughRouting
// action in the mock.
func onlyRoutingAction(t *testing.T, mock *mockGateway) map[string]any {
	t.Helper()
	if len(mock.routingActions) != 1 {
		t.Fatalf("mock holds %d routing actions, want 1", len(mock.routingActions))
	}
	for _, act := range mock.routingActions {
		return act
	}
	return nil
}

func TestPublish_RoutingCreatesEndpointAliasAndRoutesViaAlias(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newRoutingAdapter(t, srv, false)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	// Endpoint alias: the spike-pinned shape, EXACT endPointURI casing.
	al := aliasByName(mock, "accounts-read-backend")
	if al == nil {
		t.Fatalf("endpoint alias accounts-read-backend not created; aliases: %v", mock.aliases)
	}
	if al["type"] != "endpoint" {
		t.Errorf("alias type = %v, want endpoint", al["type"])
	}
	if al["endPointURI"] != testBackendDevURL {
		t.Errorf("alias endPointURI = %v, want %q", al["endPointURI"], testBackendDevURL)
	}
	if al["optimizationTechnique"] != "None" {
		t.Errorf("alias optimizationTechnique = %v, want None", al["optimizationTechnique"])
	}
	if al["passSecurityHeaders"] != true {
		t.Errorf("alias passSecurityHeaders = %v, want true", al["passSecurityHeaders"])
	}

	// The straightThroughRouting action routes via ${alias}/${sys:resource_path}
	// — and the UI-added "method":["CUSTOM"] param SURVIVED the converge PUT.
	act := onlyRoutingAction(t, mock)
	want := "${accounts-read-backend}/${sys:resource_path}"
	if got := firstStringValue(actionParamValues(act, "endpointUri")); got != want {
		t.Errorf("routing endpointUri = %q, want %q", got, want)
	}
	if got := firstStringValue(actionParamValues(act, "method")); got != "CUSTOM" {
		t.Errorf("method param = %q, want CUSTOM preserved (unknown params must survive the converge)", got)
	}
}

func TestPublish_RoutingIdempotentSecondRun(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newRoutingAdapter(t, srv, false)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("first Publish: %v", err)
	}
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("second Publish: %v", err)
	}

	// One alias POST, one action converge PUT — the second run is read-only
	// (the re-import preserves the policy/action, like the live build).
	if got := mock.countRequests("POST /rest/apigateway/alias"); got != 1 {
		t.Errorf("POST /alias count = %d over two publishes, want 1", got)
	}
	if got := mock.countRequests("PUT /rest/apigateway/alias/"); got != 0 {
		t.Errorf("PUT /alias count = %d, want 0 (no drift)", got)
	}
	if got := mock.countRequests("PUT /rest/apigateway/policyActions/"); got != 1 {
		t.Errorf("PUT /policyActions count = %d over two publishes, want 1 (converged once)", got)
	}
	if len(mock.aliases) != 1 {
		t.Errorf("aliases after re-apply = %d, want 1", len(mock.aliases))
	}
}

func TestPublish_RoutingConvergesDriftedEndpointAliasInPlace(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	// Pre-seed the alias under the SAME name but a stale URL (e.g. the uat
	// manifest applied over a dev gateway): converge via PUT, never POST a
	// duplicate, and preserve gateway-enriched fields.
	mock.aliases["alias-old"] = map[string]any{
		"id": "alias-old", "name": "accounts-read-backend",
		"type":                  "endpoint",
		"endPointURI":           "http://backend-old:8080/rest/accounts",
		"optimizationTechnique": "None",
		"passSecurityHeaders":   true,
		"owner":                 "Administrator", // gateway-enriched field to preserve
	}

	a, api := newRoutingAdapter(t, srv, false)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	if got := mock.countRequests("POST /rest/apigateway/alias"); got != 0 {
		t.Errorf("POST /alias count = %d, want 0 (converge via PUT)", got)
	}
	if got := mock.countRequests("PUT /rest/apigateway/alias/alias-old"); got != 1 {
		t.Errorf("PUT /alias/alias-old count = %d, want 1", got)
	}
	al := aliasByName(mock, "accounts-read-backend")
	if al["endPointURI"] != testBackendDevURL {
		t.Errorf("alias endPointURI = %v, want converged %q", al["endPointURI"], testBackendDevURL)
	}
	if _, ok := al["owner"]; !ok {
		t.Error("alias update dropped the gateway-enriched owner field (must PUT the full read-back record)")
	}
}

func TestPublish_RoutingCredentialAliasAndOutboundAuth(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newRoutingAdapter(t, srv, true)
	res, err := a.Publish(context.Background(), api)
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}

	// Credential alias: HTTP_BASIC/NEW with the password sent as BASE64 (a
	// clear password is stored corrupt on the live build).
	cred := aliasByName(mock, "accounts-read-backend-cred")
	if cred == nil {
		t.Fatalf("credential alias not created; aliases: %v", mock.aliases)
	}
	if cred["type"] != "httpTransportSecurityAlias" || cred["authType"] != "HTTP_BASIC" || cred["authMode"] != "NEW" {
		t.Errorf("credential alias shape = type:%v authType:%v authMode:%v", cred["type"], cred["authType"], cred["authMode"])
	}
	creds, _ := cred["httpAuthCredentials"].(map[string]any)
	if creds == nil {
		t.Fatal("credential alias has no httpAuthCredentials")
	}
	if creds["userName"] != testBackendUser {
		t.Errorf("userName = %v, want %q", creds["userName"], testBackendUser)
	}
	wantB64 := base64.StdEncoding.EncodeToString([]byte(testBackendPass))
	if creds["password"] != wantB64 {
		t.Errorf("password = %v, want base64 %q (clear passwords are stored corrupt)", creds["password"], wantB64)
	}

	// Outbound Auth – Transport: ONE nested transportSecurity group (the FLAT
	// shape would have 500'd in the mock), alias=${credAlias}, attached to the
	// routing stage of the service policy.
	var outAct map[string]any
	var outID string
	for id, act := range mock.actions {
		if act["templateKey"] == "outboundTransportAuthentication" {
			outAct, outID = act, id
		}
	}
	if outAct == nil {
		t.Fatalf("outbound transport auth action not created; actions: %v", mock.actions)
	}
	if got := outboundAuthAlias(outAct); got != "${accounts-read-backend-cred}" {
		t.Errorf("outbound auth alias = %q, want ${accounts-read-backend-cred}", got)
	}
	if got := firstStringValue(transportSecurityParamValues(outAct, "authType")); got != "ALIAS" {
		t.Errorf("outbound auth authType = %q, want ALIAS", got)
	}
	polID := mock.apis[res.APIID].rec.Policies[0]
	if !policyStageReferences(mock.policies[polID], stageRouting, outID) {
		t.Errorf("routing stage does not reference the outbound auth action %q", outID)
	}
	// The import-minted straightThroughRouting enforcement survived the attach.
	act := onlyRoutingAction(t, mock)
	if !policyStageReferences(mock.policies[polID], stageRouting, act["id"].(string)) {
		t.Error("routing stage lost the straightThroughRouting enforcement after the wholesale PUT")
	}
}

func TestPublish_RoutingCredentialAliasWriteAlwaysReemitsPassword(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newRoutingAdapter(t, srv, true)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("first Publish: %v", err)
	}
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("second Publish: %v", err)
	}

	// The stored password is never readable (masked on read-back), so drift is
	// undetectable — the credential alias is WRITE-ALWAYS: the second run
	// re-emits it via a PUT. Idempotence is proven by stable ids (no duplicate
	// alias) and a re-emitted REAL password, not by the absence of a PUT.
	if got := mock.countRequests("POST /rest/apigateway/alias"); got != 2 {
		t.Errorf("POST /alias count = %d over two publishes, want 2 (endpoint + credential, once each)", got)
	}
	if got := mock.countRequests("PUT /rest/apigateway/alias/"); got != 1 {
		t.Errorf("PUT /alias count = %d over two publishes, want 1 (credential alias re-emitted write-always on the 2nd run; endpoint alias converged so no PUT)", got)
	}
	if len(mock.aliases) != 2 {
		t.Errorf("aliases after re-apply = %d, want 2 (no duplicate from the write-always PUT)", len(mock.aliases))
	}
	cred := aliasByName(mock, "accounts-read-backend-cred")
	creds, _ := cred["httpAuthCredentials"].(map[string]any)
	wantB64 := base64.StdEncoding.EncodeToString([]byte(testBackendPass))
	if creds["password"] != wantB64 {
		t.Errorf("stored password after re-apply = %v, want the REAL base64 %q re-emitted (never the read-back mask)", creds["password"], wantB64)
	}
	if got := mock.countRequests("POST /rest/apigateway/policyActions"); got != 1 {
		t.Errorf("POST /policyActions count = %d over two publishes, want 1", got)
	}
	if got := mock.countRequests("PUT /rest/apigateway/policies/"); got != 1 {
		t.Errorf("PUT /policies count = %d over two publishes, want 1 (attach once)", got)
	}
}

// A same-user password rotation (the DoD-3 case the old userName-keyed drift
// check missed) must actually reach the gateway: the write-always convergence
// re-emits the NEW base64 password on the next apply.
func TestPublish_RoutingCredentialWriteAlwaysProjectsPasswordRotation(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	// Apply #1 creates the credential alias with the original password.
	a1, api := newRoutingAdapter(t, srv, true)
	if _, err := a1.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish #1: %v", err)
	}

	// Rotate the backend password (SAME userName) and apply again with a second
	// adapter against the SAME gateway — the alias already exists.
	rotated := "be-pass-ROTATED-v2"
	a2, err := New(adapter.Config{
		Type:       gatewayName,
		Name:       gatewayName,
		AdminURL:   srv.URL,
		GatewayURL: "http://webmethods-real:5555",
		Credentials: map[string]string{
			"username":        testUser,
			"password":        testPass,
			"backendUsername": testBackendUser, // unchanged
			"backendPassword": rotated,
		},
		Options: map[string]string{
			"routingEndpointAliasName":   "{api}-backend",
			"routingEndpointAliasUrl":    testBackendDevURL,
			"routingCredentialAliasName": "{api}-backend-cred",
		},
	})
	if err != nil {
		t.Fatalf("New (rotated): %v", err)
	}
	if _, err := a2.(*Adapter).Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish #2 (rotated): %v", err)
	}

	cred := aliasByName(mock, "accounts-read-backend-cred")
	creds, _ := cred["httpAuthCredentials"].(map[string]any)
	if creds["userName"] != testBackendUser {
		t.Errorf("userName = %v, want unchanged %q", creds["userName"], testBackendUser)
	}
	wantB64 := base64.StdEncoding.EncodeToString([]byte(rotated))
	if creds["password"] != wantB64 {
		t.Errorf("stored password after rotation = %v, want the NEW base64 %q — a same-user rotation must be projected (was the missed DoD-3 bug)", creds["password"], wantB64)
	}
	if len(mock.aliases) != 2 {
		t.Errorf("aliases after rotation = %d, want 2 (converge in place, no duplicate)", len(mock.aliases))
	}
}

// A SECOND outboundTransportAuthentication action on the routing stage (a
// duplicate/orphan of a prior run, or an injected action re-pointing the
// backend credentials) must fail the convergence LOUDLY — never let the
// first-match converge and leave the extra one live (the A1 first-rule-only
// false-negative class).
func TestPublish_RoutingRefusesDuplicateOutboundAction(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	a, api := newRoutingAdapter(t, srv, true)
	res, err := a.Publish(context.Background(), api)
	if err != nil {
		t.Fatalf("Publish #1: %v", err)
	}

	// Inject a second outbound-auth action and attach it to the routing stage.
	polID := mock.apis[res.APIID].rec.Policies[0]
	mock.actions["dupe-outbound"] = map[string]any{
		"id":          "dupe-outbound",
		"names":       []any{map[string]any{"value": "Outbound Auth - Transport (injected)", "locale": "en"}},
		"templateKey": "outboundTransportAuthentication",
		"parameters": []any{map[string]any{
			"templateKey": "transportSecurity",
			"parameters": []any{
				map[string]any{"templateKey": "authType", "values": []any{"ALIAS"}},
				map[string]any{"templateKey": "authMode", "values": []any{"NEW"}},
				map[string]any{"templateKey": "alias", "values": []any{"${attacker-cred}"}},
			},
		}},
		"active": true,
	}
	if !appendStageEnforcement(mock.policies[polID], stageRouting, "dupe-outbound") {
		t.Fatal("could not attach the duplicate action to the routing stage")
	}

	_, err = a.Publish(context.Background(), api)
	if err == nil {
		t.Fatal("Publish succeeded with two outboundTransportAuthentication actions on the routing stage, want a fail-closed refusal")
	}
	if !strings.Contains(err.Error(), "outboundTransportAuthentication actions") || !strings.Contains(err.Error(), "ambiguous") {
		t.Errorf("error %q should name the ambiguous duplicate outbound actions and refuse to converge", err.Error())
	}
}

func TestPublish_RoutingDriftedCredentialUserReemitsPassword(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	// Pre-seed the credential alias with a STALE userName (and the masked
	// password a previous read-back would carry): the converge must PUT the
	// record with the REAL base64 password re-emitted — writing the mask back
	// would corrupt the stored credential.
	mock.aliases["cred-old"] = map[string]any{
		"id": "cred-old", "name": "accounts-read-backend-cred",
		"type": "httpTransportSecurityAlias", "authType": "HTTP_BASIC", "authMode": "NEW",
		"httpAuthCredentials": map[string]any{
			"userName": "old-user",
			"password": base64.StdEncoding.EncodeToString([]byte("********")),
		},
	}

	a, api := newRoutingAdapter(t, srv, true)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	if got := mock.countRequests("PUT /rest/apigateway/alias/cred-old"); got != 1 {
		t.Errorf("PUT /alias/cred-old count = %d, want 1 (userName drift)", got)
	}
	cred := mock.aliases["cred-old"]
	creds, _ := cred["httpAuthCredentials"].(map[string]any)
	if creds["userName"] != testBackendUser {
		t.Errorf("userName = %v, want converged %q", creds["userName"], testBackendUser)
	}
	wantB64 := base64.StdEncoding.EncodeToString([]byte(testBackendPass))
	if creds["password"] != wantB64 {
		t.Errorf("password = %v, want the REAL base64 %q re-emitted (never the read-back mask)", creds["password"], wantB64)
	}
}

func TestPublish_RoutingSilentNoopPUTFailsLoud(t *testing.T) {
	mock := newMockGateway()
	mock.silentActionPut = true
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	// The build answers 200 on the action PUT but persists NOTHING (the trap a
	// naked body triggers live): the read-back assertion must fail the publish
	// LOUDLY instead of leaving the API routed at the import-time backend.
	a, api := newRoutingAdapter(t, srv, false)
	_, err := a.Publish(context.Background(), api)
	if err == nil {
		t.Fatal("Publish succeeded under the silent action-PUT no-op, want a read-back failure")
	}
	if !strings.Contains(err.Error(), "did not persist") {
		t.Errorf("error %q should say the PUT did not persist (silent no-op caught by read-back)", err.Error())
	}
}

func TestPublish_NoRoutingBlockTouchesNoRoutingSurface(t *testing.T) {
	mock := newMockGateway()
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	// Plain adapter (no routing in the manifest): behavior must be
	// byte-identical to before the feature — ZERO calls on the alias/action
	// surfaces.
	a, api := newAdapter(t, srv)
	if _, err := a.Publish(context.Background(), api); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	for _, prefix := range []string{
		"GET /rest/apigateway/alias",
		"POST /rest/apigateway/alias",
		"PUT /rest/apigateway/alias",
		"GET /rest/apigateway/policyActions",
		"POST /rest/apigateway/policyActions",
		"PUT /rest/apigateway/policyActions",
		"PUT /rest/apigateway/policies/",
	} {
		if got := mock.countRequests(prefix); got != 0 {
			t.Errorf("%s count = %d without a routing block, want 0", prefix, got)
		}
	}
	// The import-time endpointUri is untouched.
	act := onlyRoutingAction(t, mock)
	if got := firstStringValue(actionParamValues(act, "endpointUri")); got != api.BackendURL {
		t.Errorf("endpointUri = %q, want the import-time backend %q untouched", got, api.BackendURL)
	}
}

// --- bearer-token auth mode --------------------------------------------------

// writeTokenFile writes a 0600 token file and returns its path.
func writeTokenFile(t *testing.T, content string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "wm-token")
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatalf("write token file: %v", err)
	}
	return p
}

func TestNew_BearerTokenFileModePublishes(t *testing.T) {
	mock := newMockGateway()
	mock.bearerToken = "tok-ci-123"
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	// The file content is whitespace-padded on purpose: the adapter must trim.
	tokenFile := writeTokenFile(t, "  tok-ci-123\n")
	a, err := New(adapter.Config{
		Type:        gatewayName,
		Name:        gatewayName,
		AdminURL:    srv.URL,
		GatewayURL:  "http://webmethods-real:5555",
		Credentials: map[string]string{"bearerTokenFile": tokenFile},
	})
	if err != nil {
		t.Fatalf("New (bearer mode): %v", err)
	}
	api := &adapter.NormalizedAPI{
		Name:       "accounts-read",
		Version:    "1.0.0",
		BasePath:   "/accounts-read/v1",
		BackendURL: "http://microcks:8080/rest/accounts",
		Spec:       []byte(sampleSpec),
		SpecPath:   "apis/accounts-read.openapi.yaml",
	}
	// The mock ONLY accepts "Bearer tok-ci-123" for this adapter (the Basic
	// pair would also pass, but the adapter has none) — a full publish proves
	// the header on every call of the lifecycle.
	res, err := a.Publish(context.Background(), api)
	if err != nil {
		t.Fatalf("Publish (bearer mode): %v", err)
	}
	if !res.Published {
		t.Error("Published = false in bearer mode, want true")
	}
}

func TestNew_BearerRejectsWrongToken(t *testing.T) {
	mock := newMockGateway()
	mock.bearerToken = "tok-ci-123"
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	tokenFile := writeTokenFile(t, "tok-WRONG")
	a, err := New(adapter.Config{
		AdminURL:    srv.URL,
		Credentials: map[string]string{"bearerTokenFile": tokenFile},
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	herr := a.Health(context.Background())
	if herr == nil {
		t.Fatal("Health with a wrong bearer token succeeded, want 401")
	}
	if !strings.Contains(herr.Error(), "401") {
		t.Errorf("error %q should carry the 401 status", herr.Error())
	}
}

func TestNew_BearerFailClosedModes(t *testing.T) {
	tokenFile := writeTokenFile(t, "tok-ci-123")

	// Mixed modes: bearerTokenFile + Basic -> refuse (ambiguous intent).
	if _, err := New(adapter.Config{
		AdminURL: "http://localhost:5555",
		Credentials: map[string]string{
			"bearerTokenFile": tokenFile,
			"username":        testUser,
			"password":        testPass,
		},
	}); err == nil || !strings.Contains(err.Error(), "exactly ONE auth mode") {
		t.Errorf("New with mixed modes = %v, want fail-closed 'exactly ONE auth mode'", err)
	}

	// No mode at all -> refuse.
	if _, err := New(adapter.Config{AdminURL: "http://localhost:5555"}); err == nil {
		t.Error("New without any credentials succeeded, want fail-closed")
	}

	// Missing token file -> refuse with the path in the error.
	if _, err := New(adapter.Config{
		AdminURL:    "http://localhost:5555",
		Credentials: map[string]string{"bearerTokenFile": "/nonexistent/wm-token"},
	}); err == nil || !strings.Contains(err.Error(), "/nonexistent/wm-token") {
		t.Errorf("New with a missing token file = %v, want fail-closed naming the path", err)
	}

	// Empty (whitespace-only) token -> refuse.
	emptyFile := writeTokenFile(t, "   \n")
	if _, err := New(adapter.Config{
		AdminURL:    "http://localhost:5555",
		Credentials: map[string]string{"bearerTokenFile": emptyFile},
	}); err == nil || !strings.Contains(err.Error(), "empty") {
		t.Errorf("New with an empty token file = %v, want fail-closed 'empty'", err)
	}

	// Group/world-readable file -> refuse (the token is a credential).
	looseFile := filepath.Join(t.TempDir(), "wm-token-loose")
	if err := os.WriteFile(looseFile, []byte("tok"), 0o644); err != nil {
		t.Fatalf("write loose token file: %v", err)
	}
	if _, err := New(adapter.Config{
		AdminURL:    "http://localhost:5555",
		Credentials: map[string]string{"bearerTokenFile": looseFile},
	}); err == nil || !strings.Contains(err.Error(), "chmod 600") {
		t.Errorf("New with a 0644 token file = %v, want fail-closed 'chmod 600'", err)
	}
}

// Bearer mode has no Basic username to default the introspection Gateway user
// from: the remote-introspection projection must fail closed with a message
// guiding to inboundAuth.introspectionUser.
func TestNew_BearerModeIntrospectionUserFailsClosed(t *testing.T) {
	tokenFile := writeTokenFile(t, "tok-ci-123")
	_, err := New(adapter.Config{
		AdminURL:    "http://localhost:5555",
		Credentials: map[string]string{"bearerTokenFile": tokenFile},
		Options: map[string]string{
			"inboundAuthIssuer":                    testIssuer,
			"inboundAuthJwksUri":                   testJWKS,
			"inboundAuthAudience":                  testAudience,
			"inboundAuthScope":                     testScope,
			"inboundAuthClientId":                  testClientID,
			"inboundAuthIntrospectionEndpoint":     testIntrospectionEndpoint,
			"inboundAuthIntrospectionClientId":     testIntrospectionClientID,
			"inboundAuthIntrospectionClientSecret": testIntrospectionSecret,
		},
	})
	if err == nil {
		t.Fatal("New in bearer mode with remote introspection and no introspectionUser succeeded, want fail-closed")
	}
	if !strings.Contains(err.Error(), "inboundAuth.introspectionUser") {
		t.Errorf("error %q should guide to inboundAuth.introspectionUser", err.Error())
	}
}
