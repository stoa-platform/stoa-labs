package main

// Admin REST surface at the EXACT 10.15 dialect the labctl adapter speaks —
// envelopes, lifecycle AND traps, all live-captured on the data-plane spike:
//
//   - APIs are created by IMPORT (POST /apis {apiName, apiVersion, type,
//     apiDefinition}) and import does NOT activate (isActive=false; separate
//     PUT /apis/{id}/activate). List = {"apiResponse":[{"api":{...}}]},
//     single/create = {"apiResponse":{"api":{...}}}.
//   - Import mints the SERVICE-scoped "Default Policy for API <name>" with
//     transport + routing stages; the routing action is a REAL
//     straightThroughRouting policyAction at servers[0].url +
//     "/${sys:resource_path}" (plus the "method":["CUSTOM"] param the UI adds
//     live — converge code MUST preserve unknown params).
//   - Re-import (PUT /apis/{id}) PRESERVES the policy and the routing action
//     (same id, ${alias} intact) — observed live on this build.
//   - Aliases take a NAKED body and answer {"alias":{...}}; the endpoint type
//     requires "endPointURI" (EXACT casing); the credential alias masks its
//     password on read-back as the BASE64 OF ASTERISKS (never the secret).
//   - PUT /policyActions/{id} REQUIRES the {"policyAction":{...}} envelope: a
//     naked body answers 200 WITHOUT persisting (the silent no-op trap that
//     makes labctl's read-back asserts load-bearing).
//   - outboundTransportAuthentication parameters must be ONE nested
//     transportSecurity group; FLAT parameters reproduce the live NPE 500
//     (OutboundTransportSecurityFactory).

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"sort"
	"strings"
)

// --- APIs (import / lifecycle) ----------------------------------------------

// apiEnvelope is the nested item shape {"api":{...},"responseStatus":"SUCCESS"}.
func apiEnvelope(rec *apiRecord) map[string]any {
	return map[string]any{"api": rec, "responseStatus": "SUCCESS"}
}

func (s *Server) listAPIs(w http.ResponseWriter, _ *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	recs := make([]*apiRecord, 0, len(s.store.apis))
	for _, a := range s.store.apis {
		recs = append(recs, a)
	}
	// Stable order (by id) so re-list diffs are deterministic in demos.
	sort.Slice(recs, func(i, j int) bool { return recs[i].ID < recs[j].ID })
	items := make([]any, 0, len(recs))
	for _, a := range recs {
		items = append(items, apiEnvelope(a))
	}
	writeJSON(w, http.StatusOK, map[string]any{"apiResponse": items})
}

func (s *Server) createAPI(w http.ResponseWriter, r *http.Request) {
	var in struct {
		APIName       string         `json:"apiName"`
		APIVersion    string         `json:"apiVersion"`
		Type          string         `json:"type"`
		APIDefinition map[string]any `json:"apiDefinition"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	if in.APIName == "" || in.APIDefinition == nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "apiName and apiDefinition are required"})
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	// 409 on ANY apiName collision (same or another version) — the product's
	// name conflict the adapter's 409→re-list→PUT fallback is tested against.
	if s.store.findAPIByName(in.APIName) != nil {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "An API already exists with the name " + in.APIName})
		return
	}
	id := s.store.nextID("api")
	polID := s.mintDefaultPolicy(id, in.APIName, in.APIDefinition)
	rec := &apiRecord{
		ID:         id,
		APIName:    in.APIName,
		APIVersion: in.APIVersion,
		IsActive:   false, // import does NOT activate (separate lifecycle step)
		Type:       "REST",
		Policies:   []string{polID},
		Definition: in.APIDefinition,
	}
	s.store.apis[id] = rec
	writeJSON(w, http.StatusCreated, map[string]any{"apiResponse": apiEnvelope(rec)})
}

// mintDefaultPolicy creates the SERVICE-scoped default policy + its enforcement
// actions, exactly like the import on the real product:
//   - routing: a straightThroughRouting action at servers[0].url +
//     "/${sys:resource_path}", carrying the extra "method":["CUSTOM"] param the
//     live UI adds (the unknown-param-preservation trap for converge code);
//   - transport: a placeholder enablement action (templateKey NOT live-captured
//     — only the routing action is load-bearing for labctl and the demo).
//
// Caller MUST hold the store lock.
func (s *Server) mintDefaultPolicy(apiID, apiName string, def map[string]any) string {
	routingID := s.store.nextID("action")
	s.store.actions[routingID] = map[string]any{
		"id":          routingID,
		"names":       []any{map[string]any{"value": "Straight Through Routing", "locale": "en"}},
		"templateKey": "straightThroughRouting",
		"parameters": []any{
			map[string]any{"templateKey": "endpointUri", "values": []any{defaultEndpointURI(def)}},
			// The live UI posts this param alongside endpointUri: converge code
			// must PUT the read-back record (preserving it), never a minimal body.
			map[string]any{"templateKey": "method", "values": []any{"CUSTOM"}},
		},
		"active": true,
	}
	transportID := s.store.nextID("action")
	s.store.actions[transportID] = map[string]any{
		"id":          transportID,
		"names":       []any{map[string]any{"value": "Enable HTTP/HTTPS", "locale": "en"}},
		"templateKey": "transportEnablement", // placeholder key (not live-captured)
		"parameters":  []any{},
		"active":      true,
	}
	polID := s.store.nextID("pol")
	s.store.policies[polID] = map[string]any{
		"id":    polID,
		"names": []any{map[string]any{"value": "Default Policy for API " + apiName, "locale": "English"}},
		"policyEnforcements": []any{
			map[string]any{"stageKey": "transport", "enforcements": []any{
				map[string]any{"enforcementObjectId": transportID, "order": nil}}},
			map[string]any{"stageKey": "routing", "enforcements": []any{
				map[string]any{"enforcementObjectId": routingID, "order": nil}}},
		},
		"policyScope":  "SERVICE",
		"systemPolicy": false,
		"global":       false,
		"active":       false,
	}
	_ = apiID // kept for symmetry; the api record references the policy id
	return polID
}

// defaultEndpointURI derives the native routing target from the imported
// document: servers[0].url + "/${sys:resource_path}" (what the real import
// writes into the default straightThroughRouting action).
func defaultEndpointURI(def map[string]any) string {
	base := ""
	if servers, _ := def["servers"].([]any); len(servers) > 0 {
		if first, _ := servers[0].(map[string]any); first != nil {
			base, _ = first["url"].(string)
		}
	}
	return strings.TrimRight(base, "/") + "/${sys:resource_path}"
}

func (s *Server) getAPI(w http.ResponseWriter, r *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	rec, ok := s.store.apis[r.PathValue("id")]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "api not found"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"apiResponse": apiEnvelope(rec)})
}

// updateAPI is the re-import: it refreshes the definition/version but PRESERVES
// the policy and the routing action (same ids, ${alias} routing intact) — the
// live-observed behaviour labctl's defensive convergence relies on.
func (s *Server) updateAPI(w http.ResponseWriter, r *http.Request) {
	var in struct {
		APIVersion    string         `json:"apiVersion"`
		APIDefinition map[string]any `json:"apiDefinition"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	rec, ok := s.store.apis[r.PathValue("id")]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "api not found"})
		return
	}
	if in.APIVersion != "" {
		rec.APIVersion = in.APIVersion
	}
	if in.APIDefinition != nil {
		rec.Definition = in.APIDefinition
	}
	writeJSON(w, http.StatusOK, map[string]any{"apiResponse": apiEnvelope(rec)})
}

func (s *Server) activateAPI(w http.ResponseWriter, r *http.Request) {
	s.setActive(w, r, true)
}

func (s *Server) deactivateAPI(w http.ResponseWriter, r *http.Request) {
	s.setActive(w, r, false)
}

func (s *Server) setActive(w http.ResponseWriter, r *http.Request, active bool) {
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	rec, ok := s.store.apis[r.PathValue("id")]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "api not found"})
		return
	}
	rec.IsActive = active
	writeJSON(w, http.StatusOK, map[string]any{"apiResponse": apiEnvelope(rec)})
}

// --- aliases (endpoint / credential / auth-server) ---------------------------

// localISAlias is the built-in LOCAL_IS alias the real gateway always carries —
// served so name lookups must actually filter, like live.
var localISAlias = map[string]any{
	"id": "local", "name": "local", "type": "authServerAlias", "authServerType": "LOCAL_IS",
}

func (s *Server) listAliases(w http.ResponseWriter, _ *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	items := []any{localISAlias}
	ids := make([]string, 0, len(s.store.aliases))
	for id := range s.store.aliases {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		items = append(items, maskAlias(s.store.aliases[id]))
	}
	writeJSON(w, http.StatusOK, map[string]any{"alias": items})
}

// createAlias takes the NAKED alias body (no envelope — a real 10.15
// inconsistency), rejects duplicate names, validates the per-type required
// fields and answers {"alias":{...}} like the live POST.
func (s *Server) createAlias(w http.ResponseWriter, r *http.Request) {
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	name, _ := in["name"].(string)
	if name == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "name is required"})
		return
	}
	if msg := validateAliasBody(in); msg != "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": msg})
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	if s.store.aliasByName(name) != nil || name == "local" {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "Alias with name " + name + " already exists"})
		return
	}
	in["id"] = s.store.nextID("alias")
	s.store.aliases[in["id"].(string)] = in
	writeJSON(w, http.StatusCreated, map[string]any{"alias": maskAlias(in)})
}

func (s *Server) getAlias(w http.ResponseWriter, r *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	al, ok := s.store.aliases[r.PathValue("id")]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "alias not found"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"alias": maskAlias(al)})
}

// updateAlias replaces the record wholesale (naked body). The caller must
// re-emit the credential password on every PUT — the read-back is masked, so a
// PUT echoing a read-back without re-emitting would store the mask; the mock
// stores whatever it is given, exactly like the product.
func (s *Server) updateAlias(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	if msg := validateAliasBody(in); msg != "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": msg})
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	if _, ok := s.store.aliases[id]; !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "alias not found"})
		return
	}
	in["id"] = id
	s.store.aliases[id] = in
	writeJSON(w, http.StatusOK, map[string]any{"alias": maskAlias(in)})
}

// validateAliasBody enforces the per-type required fields the spike pinned:
//   - endpoint: "endPointURI" non-empty, EXACT casing (a wrong-cased field
//     would be stored inert and break routing silently — fail closed instead);
//   - httpTransportSecurityAlias: httpAuthCredentials.userName + password
//     present. The password's base64-ness is NOT validated here: the product
//     stores a non-base64 password CORRUPTED, and the mock surfaces that at
//     data-plane resolution (see resolveOutboundAuth).
//
// Returns "" when valid.
func validateAliasBody(in map[string]any) string {
	switch t, _ := in["type"].(string); t {
	case "endpoint":
		if uri, _ := in["endPointURI"].(string); uri == "" {
			return `endpoint alias requires a non-empty "endPointURI" (EXACT casing — endpointUri/endpointURI are silently inert on the product)`
		}
	case "httpTransportSecurityAlias":
		creds, _ := in["httpAuthCredentials"].(map[string]any)
		user, _ := creds["userName"].(string)
		pass, _ := creds["password"].(string)
		if user == "" || pass == "" {
			return `httpTransportSecurityAlias requires httpAuthCredentials.userName and .password (password = BASE64 of the secret, or it is stored corrupted)`
		}
	}
	return ""
}

// maskAlias returns a read-shape copy of the alias: the credential password
// comes back as the BASE64 OF ASTERISKS (matching the decoded length — never
// the secret), and remoteIntrospectionConfig.clientSecret as "***", exactly
// like the live MaskableEntity behaviour.
func maskAlias(rec map[string]any) map[string]any {
	out := make(map[string]any, len(rec))
	for k, v := range rec {
		out[k] = v
	}
	if creds, ok := out["httpAuthCredentials"].(map[string]any); ok && creds != nil {
		masked := make(map[string]any, len(creds))
		for k, v := range creds {
			masked[k] = v
		}
		if pw, _ := masked["password"].(string); pw != "" {
			masked["password"] = maskedPassword(pw)
		}
		out["httpAuthCredentials"] = masked
	}
	if rc, ok := out["remoteIntrospectionConfig"].(map[string]any); ok && rc != nil {
		masked := make(map[string]any, len(rc))
		for k, v := range rc {
			masked[k] = v
		}
		if _, has := masked["clientSecret"]; has {
			masked["clientSecret"] = "***"
		}
		out["remoteIntrospectionConfig"] = masked
	}
	return out
}

// maskedPassword renders base64("***...") with one asterisk per decoded byte
// (8 when the stored value is not base64 — the corrupted-storage case).
func maskedPassword(stored string) string {
	n := 8
	if raw, err := base64.StdEncoding.DecodeString(stored); err == nil && len(raw) > 0 {
		n = len(raw)
	}
	return base64.StdEncoding.EncodeToString([]byte(strings.Repeat("*", n)))
}

// --- policyActions ------------------------------------------------------------

func (s *Server) listActions(w http.ResponseWriter, _ *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	items := make([]any, 0, len(s.store.actions))
	ids := make([]string, 0, len(s.store.actions))
	for id := range s.store.actions {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		items = append(items, s.store.actions[id])
	}
	// Singular key, list value — a real 10.15 envelope inconsistency.
	writeJSON(w, http.StatusOK, map[string]any{"policyAction": items})
}

func (s *Server) getAction(w http.ResponseWriter, r *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	act, ok := s.store.actions[r.PathValue("id")]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "policy action not found"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"policyAction": act})
}

func (s *Server) createAction(w http.ResponseWriter, r *http.Request) {
	var in struct {
		PolicyAction map[string]any `json:"policyAction"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.PolicyAction == nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "policyAction envelope is required"})
		return
	}
	if flatOutboundParams(in.PolicyAction) {
		writeOutboundNPE(w)
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	act := in.PolicyAction
	act["id"] = s.store.nextID("action")
	normalizeActionName(act)
	s.store.actions[act["id"].(string)] = act
	writeJSON(w, http.StatusCreated, map[string]any{"policyAction": act})
}

// updateAction reproduces the live PUT trap: the body MUST be ENVELOPED
// {"policyAction":{...}} — a NAKED body answers 200 and persists NOTHING (the
// silent no-op that makes read-back assertions load-bearing in labctl). An
// enveloped body replaces the action in place (live edit, immediate effect).
func (s *Server) updateAction(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var raw map[string]json.RawMessage
	if err := json.NewDecoder(r.Body).Decode(&raw); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	existing, ok := s.store.actions[id]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "policy action not found"})
		return
	}
	inner, enveloped := raw["policyAction"]
	if !enveloped {
		// THE TRAP: 200, current record echoed, nothing persisted.
		writeJSON(w, http.StatusOK, map[string]any{"policyAction": existing})
		return
	}
	var act map[string]any
	if err := json.Unmarshal(inner, &act); err != nil || act == nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "policyAction envelope is required"})
		return
	}
	if flatOutboundParams(act) {
		writeOutboundNPE(w)
		return
	}
	act["id"] = id
	normalizeActionName(act)
	s.store.actions[id] = act
	writeJSON(w, http.StatusOK, map[string]any{"policyAction": act})
}

// normalizeActionName mimics the product normalising the display name of
// Identify & Authorize (evaluatePolicy) actions — adapters matching actions by
// custom name break here exactly as they do live.
func normalizeActionName(act map[string]any) {
	if tk, _ := act["templateKey"].(string); tk == "evaluatePolicy" {
		act["names"] = []any{map[string]any{"value": "Identify & Authorize", "locale": "en"}}
	}
}

// flatOutboundParams detects the live NPE trap on Outbound Auth – Transport:
// the action's parameters MUST be ONE nested group
// [{"templateKey":"transportSecurity","parameters":[authType/authMode/alias]}].
// authType/authMode/alias AT THE TOP LEVEL (flat) crash the real product with
// an NPE 500 in OutboundTransportSecurityFactory.
func flatOutboundParams(act map[string]any) bool {
	if tk, _ := act["templateKey"].(string); tk != "outboundTransportAuthentication" {
		return false
	}
	params, _ := act["parameters"].([]any)
	hasGroup := false
	for _, p := range params {
		pm, _ := p.(map[string]any)
		if pm == nil {
			continue
		}
		switch tk, _ := pm["templateKey"].(string); tk {
		case "transportSecurity":
			hasGroup = true
		case "authType", "authMode", "alias":
			return true // flat parameter at top level -> live NPE
		}
	}
	return !hasGroup // no nested group at all is the same crash live
}

// writeOutboundNPE reproduces the product's 500 on a flat outbound-auth body.
func writeOutboundNPE(w http.ResponseWriter) {
	writeJSON(w, http.StatusInternalServerError, map[string]string{
		"errorDetails": "java.lang.NullPointerException at com.softwareag.apigateway.core.factory.policy.OutboundTransportSecurityFactory (parameters must be one nested transportSecurity group, not flat)",
	})
}

// --- policies -----------------------------------------------------------------

func (s *Server) getPolicy(w http.ResponseWriter, r *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	pol, ok := s.store.policies[r.PathValue("id")]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "policy not found"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"policy": pol})
}

// updatePolicy takes {"policy":{...}} and REPLACES the record wholesale — the
// real PUT semantics: stages not re-listed are LOST, which is why labctl always
// mutates the read-back record instead of composing one.
func (s *Server) updatePolicy(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var in struct {
		Policy map[string]any `json:"policy"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.Policy == nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "policy envelope is required"})
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	if _, ok := s.store.policies[id]; !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "policy not found"})
		return
	}
	in.Policy["id"] = id
	s.store.policies[id] = in.Policy
	writeJSON(w, http.StatusOK, map[string]any{"policy": in.Policy})
}

// --- applications (consumer model) ---------------------------------------------

func (s *Server) listApps(w http.ResponseWriter, _ *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	items := make([]any, 0, len(s.store.apps))
	ids := make([]string, 0, len(s.store.apps))
	for id := range s.store.apps {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		items = append(items, s.store.apps[id])
	}
	writeJSON(w, http.StatusOK, map[string]any{"applications": items})
}

func (s *Server) createApp(w http.ResponseWriter, r *http.Request) {
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	if name, _ := in["name"].(string); name == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "name is required"})
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	in["id"] = s.store.nextID("app")
	// A fresh application carries empty identifier/strategy sets, like live.
	if _, ok := in["identifiers"]; !ok {
		in["identifiers"] = []any{}
	}
	if _, ok := in["authStrategyIds"]; !ok {
		in["authStrategyIds"] = []any{}
	}
	s.store.apps[in["id"].(string)] = in
	// The real create response is the FLAT application object.
	writeJSON(w, http.StatusCreated, in)
}

// getApp serves the single-record envelope {"applications":[{...}]}.
func (s *Server) getApp(w http.ResponseWriter, r *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	app, ok := s.store.apps[r.PathValue("id")]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "application not found"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"applications": []any{app}})
}

// wmIdentifierKeyEnum is the fixed identifier-key enum the REAL 10.15 enforces
// (unknown keys are rejected 400) — pinned live; note the SINGULAR "token" and
// "httpsCertificate".
var wmIdentifierKeyEnum = map[string]bool{
	"httpBasicAuth": true, "accessProfile": true, "apiKey": true,
	"wssecX509Token": true, "wssecUsernameToken": true, "ipAddressRange": true,
	"hostNameAddress": true, "openIdClaims": true, "jwtClaims": true,
	"oAuth2Token": true, "payloadElement": true, "httpsCertificate": true,
	"XPathExpression": true, "kerberosToken": true, "token": true,
	"partnerId": true, "httpHeaders": true,
}

// updateApp REPLACES the application wholesale (real PUT semantics), EXCEPT
// consumingAPIs which the gateway preserves (the PUT cannot clear the API
// binding). Unknown identifier keys are rejected 400 like live.
func (s *Server) updateApp(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	prev, ok := s.store.apps[id]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "application not found"})
		return
	}
	if ids, _ := in["identifiers"].([]any); ids != nil {
		for _, raw := range ids {
			entry, _ := raw.(map[string]any)
			if entry == nil {
				continue
			}
			if k, _ := entry["key"].(string); !wmIdentifierKeyEnum[k] {
				writeJSON(w, http.StatusBadRequest, map[string]string{
					"errorDetails": "Undefined 'key' attribute value '" + k + "'",
				})
				return
			}
		}
	}
	in["id"] = id
	if v, had := prev["consumingAPIs"]; had {
		in["consumingAPIs"] = v // gateway-preserved across the PUT
	}
	s.store.apps[id] = in
	writeJSON(w, http.StatusOK, map[string]any{"applications": []any{in}})
}

// associateAPIs registers the APIs an application may invoke:
// PUT /applications/{id}/apis {"apiIDs":[...]} — the set REPLACES the previous
// one and surfaces as the gateway-preserved consumingAPIs field.
func (s *Server) associateAPIs(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var in struct {
		APIIDs []string `json:"apiIDs"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	app, ok := s.store.apps[id]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "application not found"})
		return
	}
	s.store.appAPIs[id] = in.APIIDs
	app["consumingAPIs"] = in.APIIDs
	w.WriteHeader(http.StatusNoContent)
}

// --- strategies / scopes (OAuth2 projection) -----------------------------------

// listStrategies serves the BARE array shape the live 10.15 returns (one of
// the product's envelope inconsistencies — scopes ARE enveloped).
func (s *Server) listStrategies(w http.ResponseWriter, _ *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	items := make([]any, 0, len(s.store.strategies))
	ids := make([]string, 0, len(s.store.strategies))
	for id := range s.store.strategies {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		items = append(items, s.store.strategies[id])
	}
	writeJSON(w, http.StatusOK, items)
}

// createStrategy takes the NAKED body (type UPPERCASE "OAUTH2" enforced),
// rejects duplicate names and answers ENVELOPED {"strategy":{...}} — live.
func (s *Server) createStrategy(w http.ResponseWriter, r *http.Request) {
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	name, _ := in["name"].(string)
	if name == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "name is required"})
		return
	}
	if tk, _ := in["type"].(string); tk != "OAUTH2" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "type must be OAUTH2 (uppercase)"})
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	for _, st := range s.store.strategies {
		if st["name"] == name {
			writeJSON(w, http.StatusConflict, map[string]string{"error": "Strategy with name " + name + " already exists"})
			return
		}
	}
	in["id"] = s.store.nextID("strat")
	s.store.strategies[in["id"].(string)] = in
	writeJSON(w, http.StatusCreated, map[string]any{"strategy": in})
}

func (s *Server) getStrategy(w http.ResponseWriter, r *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	st, ok := s.store.strategies[r.PathValue("id")]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "strategy not found"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"strategy": st})
}

func (s *Server) updateStrategy(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	if _, ok := s.store.strategies[id]; !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "strategy not found"})
		return
	}
	in["id"] = id
	s.store.strategies[id] = in
	writeJSON(w, http.StatusOK, map[string]any{"strategy": in})
}

// listScopes serves the {"scopes":[...]} envelope the live product returns.
func (s *Server) listScopes(w http.ResponseWriter, _ *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	items := make([]any, 0, len(s.store.scopes))
	ids := make([]string, 0, len(s.store.scopes))
	for id := range s.store.scopes {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		items = append(items, s.store.scopes[id])
	}
	writeJSON(w, http.StatusOK, map[string]any{"scopes": items})
}

func (s *Server) createScope(w http.ResponseWriter, r *http.Request) {
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	name, _ := in["scopeName"].(string)
	if name == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "scopeName is required"})
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	for _, sc := range s.store.scopes {
		if sc["scopeName"] == name {
			writeJSON(w, http.StatusConflict, map[string]string{"error": "Scope " + name + " already exists"})
			return
		}
	}
	in["id"] = s.store.nextID("scope")
	s.store.scopes[in["id"].(string)] = in
	writeJSON(w, http.StatusCreated, map[string]any{"scope": in})
}

func (s *Server) getScope(w http.ResponseWriter, r *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	sc, ok := s.store.scopes[r.PathValue("id")]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "scope not found"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"scope": sc})
}

func (s *Server) updateScope(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	if _, ok := s.store.scopes[id]; !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "scope not found"})
		return
	}
	in["id"] = id
	s.store.scopes[id] = in
	writeJSON(w, http.StatusOK, map[string]any{"scope": in})
}

// --- keystore / events ----------------------------------------------------------

// getKeystore serves the gateway-wide keystore/truststore configuration
// (/configurations/keystore — the partner-cert truststore surface).
func (s *Server) getKeystore(w http.ResponseWriter, _ *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	writeJSON(w, http.StatusOK, s.store.keystore)
}

// putKeystore replaces the keystore/truststore configuration wholesale.
func (s *Server) putKeystore(w http.ResponseWriter, r *http.Request) {
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	s.store.keystore = in
	writeJSON(w, http.StatusOK, in)
}

// events accepts and drops transactional events (legacy surface, kept).
func (s *Server) events(w http.ResponseWriter, r *http.Request) {
	_, _ = io.Copy(io.Discard, r.Body)
	w.WriteHeader(http.StatusAccepted)
}
