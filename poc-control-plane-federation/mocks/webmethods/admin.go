package main

// Admin REST surface at the EXACT 10.15 dialect the labctl adapter speaks —
// envelopes, lifecycle AND traps, all live-captured on the data-plane spike:
//
//   - APIs are created by IMPORT (POST /apis {apiName, apiVersion, type,
//     apiDefinition}) and import does NOT activate (isActive=false; separate
//     PUT /apis/{id}/activate). List = {"apiResponse":[{"api":{...}}]},
//     single/create = {"apiResponse":{"api":{...}}}. POST /apis ALSO accepts
//     multipart/form-data (fields apiName/apiVersion/type + a "file" part
//     carrying the raw contract) — the EXACT shape ansible/roles/
//     apim_publish_api/tasks/main.yml sends (relevé le 2026-08-05 : PAS
//     "apiDefinition", le champ fichier s'appelle "file"; see contract.go).
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
	"os"
	"sort"
	"strings"
)

// --- APIs (import / lifecycle) ----------------------------------------------

// apiEnvelope is the nested item shape
// {"api":{...},"responseStatus":"SUCCESS","teams":[...]}.
//
// `teams` sits at the ENVELOPE level, never inside "api" — measured on the real
// 10.15 (2026-08-05): GET /apis/{id} answers apiResponse.teams=[{id,name,
// source}] while apiResponse.api.teams is null, and GET /apis (list) carries the
// SAME teams key on every item. Both levels matter: apim_publish_api reads the
// LIST to decide whether a version lineage belongs to the requesting team
// (VERSION_BASE_FOREIGN) without paying an extra call per sibling.
func apiEnvelope(rec *apiRecord) map[string]any {
	return map[string]any{"api": rec, "responseStatus": "SUCCESS", "teams": teamRefs(rec.Teams)}
}

// teamRefs inflates team NAMES into the product's {id,name,source} refs. System
// profiles carry id==name (already the mock's convention for preinstalled
// objects), and "source":"SYSTEM" is what the live gateway returns for both
// Administrators and Default.
func teamRefs(names []string) []any {
	out := make([]any, 0, len(names))
	for _, n := range names {
		out = append(out, map[string]any{"id": n, "name": n, "source": "SYSTEM"})
	}
	return out
}

// defaultTeams is what a freshly imported API carries — measured live:
// [Administrators, Default]. `Default` is the one that matters: while it is
// there, EVERY team reads the API (mesuré le 2026-07-31), which is why
// apim_publish_api asserts its removal after assigning a team.
func defaultTeams() []string { return []string{"Administrators", "Default"} }

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

// createAPI serves POST /apis in the TWO shapes the real product accepts:
// a flat JSON body ({"apiName":...,"apiDefinition":{...}}), or
// multipart/form-data (fields apiName/apiVersion/type + a "file" part
// carrying the raw OpenAPI contract) — the shape apim_publish_api actually
// sends (relevé le 2026-08-05, ansible/roles/apim_publish_api/tasks/main.yml:
// "file":{content,filename,mime_type}, NOT "apiDefinition" — a wrong guess
// corrected before implementing). Dispatched on Content-Type, like the real
// Integration Server's REST binding.
func (s *Server) createAPI(w http.ResponseWriter, r *http.Request) {
	apiName, apiVersion, definition, msg := decodeAPICreateBody(r)
	if msg != "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": msg})
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	// 409 on ANY apiName collision (same or another version) — the product's
	// name conflict the adapter's 409→re-list→PUT fallback is tested against.
	if s.store.findAPIByName(apiName) != nil {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "An API already exists with the name " + apiName})
		return
	}
	id := s.store.nextID("api")
	polID := s.mintDefaultPolicy(id, apiName, definition)
	rec := &apiRecord{
		ID:         id,
		APIName:    apiName,
		APIVersion: apiVersion,
		IsActive:   false, // import does NOT activate (separate lifecycle step)
		Type:       "REST",
		Policies:   []string{polID},
		Definition: definition,
		Teams:      defaultTeams(),
	}
	s.store.apis[id] = rec
	// The FIRST record of a name is, by construction, its own lineage's latest
	// version — createVersionAPI's "latest only" gate (mesuré 2026-08-05) reads
	// this pointer.
	s.store.latestVersionID[apiName] = id
	writeJSON(w, http.StatusCreated, map[string]any{"apiResponse": apiEnvelope(rec)})
}

// decodeAPICreateBody extracts (apiName, apiVersion, apiDefinition) from
// either wire shape. Returns a non-empty msg (never both a definition and a
// msg) on any validation failure.
func decodeAPICreateBody(r *http.Request) (apiName, apiVersion string, definition map[string]any, msg string) {
	if strings.HasPrefix(r.Header.Get("Content-Type"), "multipart/form-data") {
		if err := r.ParseMultipartForm(20 << 20); err != nil {
			return "", "", nil, "invalid multipart body: " + err.Error()
		}
		apiName = r.FormValue("apiName")
		apiVersion = r.FormValue("apiVersion")
		file, fh, err := r.FormFile("file")
		if err != nil {
			return "", "", nil, `multipart body requires a "file" part with the OpenAPI contract`
		}
		defer file.Close()
		// readPart honours Content-Transfer-Encoding: base64 (multipart.go) —
		// the encoding ansible.builtin.uri applies to a binary part.
		raw, err := readPart(file, fh)
		if err != nil {
			return "", "", nil, "invalid multipart body: " + err.Error()
		}
		definition = parseContractDoc(raw)
	} else {
		var in struct {
			APIName       string         `json:"apiName"`
			APIVersion    string         `json:"apiVersion"`
			APIDefinition map[string]any `json:"apiDefinition"`
		}
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
			return "", "", nil, "invalid body"
		}
		apiName, apiVersion, definition = in.APIName, in.APIVersion, in.APIDefinition
	}
	if apiName == "" || definition == nil {
		return "", "", nil, "apiName and apiDefinition (or a multipart \"file\" part) are required"
	}
	return apiName, apiVersion, definition, ""
}

// createVersionAPI mirrors the native versioning endpoint (POST
// /apis/{id}/versions, 201 — vérifié live sur le trial ET sur la vraie 10.15
// du lab, spike-api-versions-1015, 2026-08-05) : mint d'un NOUVEAU record du
// même apiName avec newApiVersion (inactif, policy par défaut CLONÉE — M2).
// C'est le fallback de labctl quand un nom existe sous une AUTRE version (le
// produit refuse POST frais ET PUT in-place).
//
// Trois faits MESURÉS (pas déduits) le 2026-08-05, tous reproduits ici :
//
//   - M1/BONUS : {"newApiVersion":...} SEUL suffit (201) ; un numéro déjà
//     miné pour ce apiName est refusé 400 avec le message exact du produit ;
//     {id} doit être la DERNIÈRE version connue de l'apiName — refusé 400
//     "Versioning is allowed only from latest version" sinon, y compris pour
//     un DEUXIÈME appel sur le MÊME id juste après un premier succès (le mint
//     fait AVANCER le pointeur latestVersionID).
//   - M3 [DÉCISIF] : retainApplications:true (booléen, casse EXACTE) propage
//     la nouvelle version dans consumingAPIs des apps déjà souscrites à la
//     base. Absent, false, OU MAL CASÉ ("RetainApplications") : AUCUN effet —
//     201 dans tous les cas, la souscription est perdue EN SILENCE. La base
//     reste souscrite dans TOUS les cas (jamais désabonnée par ce endpoint).
func (s *Server) createVersionAPI(w http.ResponseWriter, r *http.Request) {
	baseID := r.PathValue("id")
	var raw map[string]any
	if err := json.NewDecoder(r.Body).Decode(&raw); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"errorDetails": "newApiVersion is required"})
		return
	}
	newVersion, _ := raw["newApiVersion"].(string)
	if newVersion == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"errorDetails": "newApiVersion is required"})
		return
	}
	// EXACT map-key lookup — NOT a decoded struct field. encoding/json's
	// struct decoding matches JSON keys to Go struct tags CASE-INSENSITIVELY
	// by default, which would silently accept "RetainApplications" too — the
	// opposite of the measured product behaviour. A map[string]any preserves
	// the JSON object's keys verbatim, so raw["retainApplications"] is unset
	// (zero value false) whenever the caller sent any other casing.
	retain, _ := raw["retainApplications"].(bool)

	s.store.mu.Lock()
	defer s.store.mu.Unlock()

	base, ok := s.store.apis[baseID]
	if !ok {
		// 401 et NON 404 : sur cette 10.15, un GET/POST visant une ressource
		// supprimée — ou un GUID qui n'a JAMAIS existé — répond « User doesn't
		// have permission to manage this API », même en Administrator (mesuré
		// au spike T1, 2026-08-05, y compris avec un GUID inventé).
		writeJSON(w, http.StatusUnauthorized, map[string]string{
			"errorDetails": "User doesn't have permission to manage this API",
		})
		return
	}
	if s.store.latestVersionID[base.APIName] != baseID {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"errorDetails": "Versioning is allowed only from latest version",
		})
		return
	}
	if s.store.findAPIByNameVersion(base.APIName, newVersion) != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"errorDetails": "Unable to version the API " + base.APIName + " with version " + newVersion + " that already exists.",
		})
		return
	}

	id := s.store.nextID("api")
	// M2 (mesuré) : policies[] = un CLONE (mintDefaultPolicy mint de nouveaux
	// ids de policy/action, jamais un partage de ceux de la base) ;
	// isActive:false — exactement comme un premier import.
	polID := s.mintDefaultPolicy(id, base.APIName, base.Definition)
	rec := &apiRecord{
		ID:         id,
		APIName:    base.APIName,
		APIVersion: newVersion,
		IsActive:   false,
		Type:       "REST",
		Policies:   []string{polID},
		Definition: base.Definition,
		// La version minée HÉRITE des teams de la base — MESURÉ le 2026-08-05
		// sur la vraie 10.15 : base assignée à `payments-team` (Default retirée)
		// puis mint → la nouvelle version naît avec [Administrators,
		// payments-team], PAS en Default. C'est ce qui rend la capture
		// cross-lignée si grave : une version minée dans la lignée d'autrui
		// atterrit DANS le périmètre de cette équipe (garde VERSION_BASE_FOREIGN).
		Teams: append([]string{}, base.Teams...),
	}
	s.store.apis[id] = rec
	// This record becomes the new latest of the lineage — baseID stops being
	// versionable from here, exactly like the measured gateway.
	s.store.latestVersionID[base.APIName] = id

	if retain {
		s.retainSubscriptions(baseID, id)
	}

	writeJSON(w, http.StatusCreated, map[string]any{"apiResponse": apiEnvelope(rec)})
}

// retainSubscriptions reproduces the measured retainApplications:true effect
// (M3, 2026-08-05): every application currently subscribed to baseID also
// gains newID in its consumingAPIs/appAPIs — baseID's own subscription is
// left untouched (the product never desubscribes the base on /versions).
// Caller MUST hold the store lock.
func (s *Server) retainSubscriptions(baseID, newID string) {
	for appID, apiIDs := range s.store.appAPIs {
		subscribed := false
		for _, id := range apiIDs {
			if id == baseID {
				subscribed = true
				break
			}
		}
		if !subscribed {
			continue
		}
		updated := append(append([]string{}, apiIDs...), newID)
		s.store.appAPIs[appID] = updated
		if app := s.store.apps[appID]; app != nil {
			app["consumingAPIs"] = updated
		}
	}
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

// updateAPI serves THREE distinct callers on the same route:
//   - the re-import, flat JSON {"apiVersion":..., "apiDefinition":...}
//     (labctl's defensive convergence) OR multipart/form-data (apim_publish_api's
//     update-in-place, main.yml:103-121 — SAME "file"/apiVersion/type fields as
//     createAPI, relevé 2026-08-05): refreshes the definition/version but
//     PRESERVES the policy and the routing action (same ids, ${alias} routing
//     intact) — the live-observed behaviour both callers rely on;
//   - the field projection (Task 8, {"apiResponse":{"api":{...}}} — the SAME
//     envelope GET returns): writes scalar fields the read-back exposes at
//     api-level, currently only "owner" (approvers projection). ⚠ UNVERIFIED
//     shape: only the GET/read envelope of `owner` was captured live on the
//     real 10.15 gateway — nobody has confirmed THIS is the body the real
//     product expects to WRITE it. Modeled here so approvers.yml's fail-closed
//     read-back assert has something real to prove itself against; treat as a
//     residual risk to confirm live before this ships to a client.
//
// A re-import (either wire shape) on an ACTIVE API is refused 400 — prouvé
// live, documented at ansible/roles/apim_publish_api/tasks/main.yml:70-72/97
// and adr/adr-078 ("le PUT est REFUSÉ (400) sur une API active"), hence the
// role's deactivate→PUT→activate dance (ADR-079). The FIELD PROJECTION is
// NOT gated by isActive: approvers.yml writes owner to an ALREADY-ACTIVE API
// (main.yml runs Approbateurs AFTER Activate) and that must keep working — the
// gate only fires when the body actually carries a new version/definition.
// ⚠ errorDetails text below is RECONSTRUCTED, not measured: main.yml/adr-078
// only capture the FACT (400 on active) and never the exact wire message —
// unlike createVersionAPI's messages (task-1-report.md), no spike captured
// this one's body. Neither the role nor this mock's tests compare that text
// (only the status code), so this is not currently load-bearing; confirm live
// before treating the string itself as a contract.
func (s *Server) updateAPI(w http.ResponseWriter, r *http.Request) {
	apiVersion, definition, owner, isReimport, msg := decodeAPIUpdateBody(r)
	if msg != "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": msg})
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	rec, ok := s.store.apis[r.PathValue("id")]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "api not found"})
		return
	}
	if isReimport && rec.IsActive {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"errorDetails": "Api is Active, please deactivate before update",
		})
		return
	}
	if apiVersion != "" {
		rec.APIVersion = apiVersion
	}
	if definition != nil {
		rec.Definition = definition
	}
	if owner != nil {
		rec.Owner = *owner
	}
	writeJSON(w, http.StatusOK, map[string]any{"apiResponse": apiEnvelope(rec)})
}

// decodeAPIUpdateBody extracts (apiVersion, apiDefinition, owner) from either
// wire shape PUT /apis/{id} accepts, and reports whether the body is a
// RE-IMPORT (carries a new version/definition — multipart ALWAYS is, since it
// always carries a "file") as opposed to a pure field projection (JSON
// apiResponse.api.owner envelope only). Returns a non-empty msg on any
// validation failure.
func decodeAPIUpdateBody(r *http.Request) (apiVersion string, definition map[string]any, owner *string, isReimport bool, msg string) {
	if strings.HasPrefix(r.Header.Get("Content-Type"), "multipart/form-data") {
		if err := r.ParseMultipartForm(20 << 20); err != nil {
			return "", nil, nil, false, "invalid multipart body: " + err.Error()
		}
		apiVersion = r.FormValue("apiVersion")
		file, fh, err := r.FormFile("file")
		if err != nil {
			return "", nil, nil, false, `multipart body requires a "file" part with the OpenAPI contract`
		}
		defer file.Close()
		raw, err := readPart(file, fh) // base64 part -> decoded (multipart.go)
		if err != nil {
			return "", nil, nil, false, "invalid multipart body: " + err.Error()
		}
		return apiVersion, parseContractDoc(raw), nil, true, ""
	}
	var in struct {
		APIVersion    string         `json:"apiVersion"`
		APIDefinition map[string]any `json:"apiDefinition"`
		APIResponse   struct {
			API struct {
				Owner *string `json:"owner"`
			} `json:"api"`
		} `json:"apiResponse"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		return "", nil, nil, false, "invalid body"
	}
	isReimport = in.APIVersion != "" || in.APIDefinition != nil
	return in.APIVersion, in.APIDefinition, in.APIResponse.API.Owner, isReimport, ""
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

// deleteAPI is the teardown leg of the archive verb (ADR-079): an environment is
// wiped API-first, then aliases. Two refusals are REAL ordering constraints the
// promotion harness relies on (scripts/test-archive-promotion.sh, T9) — a delete
// that silently no-ops would make the "virgin gateway" proof lie:
//   - an ACTIVE API is not deletable (deactivate first);
//   - an API a live application subscribes to is not deletable (un-subscribe, or
//     delete the application, first).
//
// The delete CASCADES to the API's own policy graph (policies + their
// enforcement actions): they are minted per API by the import, and a leftover
// would make the next fresh import report "Asset already exists" for assets the
// gateway is supposed to have forgotten.
func (s *Server) deleteAPI(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	rec, ok := s.store.apis[id]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "api not found"})
		return
	}
	if rec.IsActive {
		writeJSON(w, http.StatusConflict, map[string]string{
			"errorDetails": "API " + rec.APIName + " is active — deactivate it before deleting",
		})
		return
	}
	if apps := s.appsSubscribedTo(id); len(apps) > 0 {
		writeJSON(w, http.StatusConflict, map[string]string{
			"errorDetails": "API " + rec.APIName + " is used by application(s) " + strings.Join(apps, ", ") + " — remove the subscription first",
		})
		return
	}
	for _, polID := range rec.Policies {
		if pol := s.store.policies[polID]; pol != nil {
			for _, actID := range policyActionIDs(pol) {
				delete(s.store.actions, actID)
			}
		}
		delete(s.store.policies, polID)
	}
	delete(s.store.apis, id)
	if s.store.latestVersionID[rec.APIName] == id {
		s.repointLineage(rec.APIName)
	}
	w.WriteHeader(http.StatusNoContent)
}

// repointLineage re-establishes latestVersionID for a name whose pointed record
// was just destroyed. Dropping the key outright would DEAD-END the lineage
// whenever older versions survive: createVersionAPI only accepts the id the
// pointer names ("Versioning is allowed only from latest version") and createAPI
// 409s on the name, so nothing could version the survivors and nothing could
// re-create the name either. The pointer is therefore deleted only when the name
// is gone entirely, and otherwise moved to the most recently MINTED survivor —
// ids of one family sort in creation order (nextID, store.go), so the greatest
// id is the newest record. Deliberately NOT the highest apiVersion: this product
// mints versions in any order (1.0.0 versioned FROM 1.0.1 was measured live,
// 2026-08-06), so "latest" is a chronology, never a semver comparison.
// Caller MUST hold the store lock.
func (s *Server) repointLineage(apiName string) {
	newest := ""
	for _, other := range s.store.apis {
		if other.APIName == apiName && other.ID > newest {
			newest = other.ID
		}
	}
	if newest == "" {
		delete(s.store.latestVersionID, apiName)
		return
	}
	s.store.latestVersionID[apiName] = newest
}

// appsSubscribedTo lists the application ids currently bound to an API.
// Caller MUST hold the store lock.
func (s *Server) appsSubscribedTo(apiID string) []string {
	var out []string
	for appID, ids := range s.store.appAPIs {
		for _, id := range ids {
			if id == apiID {
				out = append(out, appID)
				break
			}
		}
	}
	sort.Strings(out)
	return out
}

// --- aliases (endpoint / credential / auth-server) ---------------------------

// localISAlias is the built-in LOCAL_IS alias the real gateway always carries —
// served so name lookups must actually filter, like live.
//
// It carries `scopes` ("List of scopes available in the authorization server",
// AuthServerAlias schema): the local AS ships a DEFAULT scope, which is what a
// self-service client is bound to when the manifest declares none. Overridable
// via WM_LOCAL_SCOPES (comma-separated) so a proof can replay the ambiguous
// build (several scopes, no obvious default) and the empty one.
var localISAlias = func() map[string]any {
	names := []string{"$sys:default"}
	if v := os.Getenv("WM_LOCAL_SCOPES"); v != "" {
		names = nil
		for _, n := range strings.Split(v, ",") {
			if n = strings.TrimSpace(n); n != "" {
				names = append(names, n)
			}
		}
	}
	scopes := make([]any, 0, len(names))
	for _, n := range names {
		scopes = append(scopes, map[string]any{"name": n, "description": "scope of the local authorization server"})
	}
	return map[string]any{
		"id": "local", "name": "local", "type": "authServerAlias", "authServerType": "LOCAL_IS",
		"scopes": scopes,
	}
}()

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

// deleteAlias removes a per-env alias (the last teardown step, after the APIs
// that route through it). The mock does NOT refuse a still-referenced alias: on
// the product a routing pointing at a ghost alias fails at request time, which
// the data-plane already reproduces (502, fail closed).
func (s *Server) deleteAlias(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	if _, ok := s.store.aliases[id]; !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "alias not found"})
		return
	}
	delete(s.store.aliases, id)
	w.WriteHeader(http.StatusNoContent)
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
	// consumingAPIs is present-and-empty on a brand-new application — MEASURED
	// on the real 10.15 (2026-08-05, P3-T6): an app created and never
	// associated carries "consumingAPIs":[] in BOTH GET /applications (list)
	// and GET /applications/{id}. The KEY's presence is load-bearing:
	// apim_publish_api/tasks/version.yml uses "no record carries the key" as
	// the signal that the subscription witness would be silently empty
	// (VERSION_SUBS_SHAPE_UNKNOWN) rather than genuinely unsubscribed.
	if _, ok := in["consumingAPIs"]; !ok {
		in["consumingAPIs"] = []any{}
	}
	// A7 : une application NEUVE est visible de toutes les équipes — teams
	// [Administrators, Default] inflatés, comme une API importée (defaultTeams).
	// C'est ce que ss_team_converged du rôle lit avant d'écrire.
	if _, ok := in["teams"]; !ok {
		in["teams"] = teamRefs(defaultTeams())
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
	// A7 : teams[] est posée par POST /assets/team, jamais éditée par PUT — un
	// corps qui ne la porte pas la conserve (comme consumingAPIs).
	if v, had := prev["teams"]; had {
		if _, given := in["teams"]; !given {
			in["teams"] = v
		}
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

// listAppAPIs serves GET /applications/{id}/apis {"apiIDs":[...]} — the read
// side of associateAPIs, and the ONLY witness that a subscription survived an
// archive overwrite (scripts/test-archive-promotion.sh, T8). Without it the
// promotion harness cannot tell "still subscribed" from "silently unsubscribed".
func (s *Server) listAppAPIs(w http.ResponseWriter, r *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	if _, ok := s.store.apps[r.PathValue("id")]; !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "application not found"})
		return
	}
	ids := s.store.appAPIs[r.PathValue("id")]
	if ids == nil {
		ids = []string{} // present-and-empty, like consumingAPIs on a fresh app
	}
	writeJSON(w, http.StatusOK, map[string]any{"apiIDs": ids})
}

// deleteApp removes an application AND its subscriptions — the first teardown
// step: while it exists, the APIs it consumes cannot be deleted (deleteAPI's
// 409), which is the ordering the promotion harness follows.
func (s *Server) deleteApp(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	if _, ok := s.store.apps[id]; !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "application not found"})
		return
	}
	delete(s.store.apps, id)
	delete(s.store.appAPIs, id)
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
		// The LIVE list serves the secret IN CLEAR — that is the whole point.
		rec := s.store.strategies[id]
		if os.Getenv("WM_MASK_STRATEGY_CREDENTIAL") == "1" {
			rec = maskStrategy(rec)
		}
		items = append(items, rec)
	}
	writeJSON(w, http.StatusOK, items)
}

// --- dynamic client registration (local authorization server) ------------------
//
// Shapes from the product's own swagger (SoftwareAG/webmethods-api-gateway,
// apigatewayservices/APIGatewayApplication.json, "API Gateway Application
// Management Service"):
//
//	StrategyRequest.clientId  — "should be provided when the dynamic client
//	                            registration is NOT used to generate the
//	                            credentials for the strategy" (exclusive of dcrConfig);
//	dcrConfig (INPUT)         — clientType PUBLIC|CONFIDENTIAL, allowedGrantTypes
//	                            from a closed enum, scopes, clientName,
//	                            applicationType, redirectUris, expirationInterval,
//	                            refreshCount;
//	clientRegistration (OUTPUT, read-only) — the client the gateway MINTED:
//	                            clientId, clientSecret, name, type "confidential",
//	                            tokenLifetime, tokenRefreshLimit, clScopes and one
//	                            <grant>Allowed boolean per grant type.
//
// The mock mints deterministic ids (wm-client-000N / wm-secret-000N) so proofs
// are reproducible. WM_MASK_STRATEGY_CREDENTIAL=1 makes GET/list answer "***" for
// clientRegistration.clientSecret — the pessimistic build where the secret is
// readable ONLY in the create response, which the role must survive.
var wmGrantTypeEnum = map[string]bool{
	"authorization_code": true, "password": true, "client_credentials": true,
	"refresh_token": true, "implicit": true,
}

// validateDCR mirrors the product's closed enums. Returns "" when acceptable.
func validateDCR(dcr map[string]any) string {
	switch ct, _ := dcr["clientType"].(string); ct {
	case "PUBLIC", "CONFIDENTIAL":
	default:
		return "Undefined 'clientType' attribute value '" + ct + "', should be one of [PUBLIC, CONFIDENTIAL]"
	}
	grants, _ := dcr["allowedGrantTypes"].([]any)
	if len(grants) == 0 {
		return "dcrConfig.allowedGrantTypes is required"
	}
	for _, g := range grants {
		gs, _ := g.(string)
		if !wmGrantTypeEnum[gs] {
			return "Undefined 'allowedGrantTypes' attribute value '" + gs + "', should be one of [authorization_code, password, client_credentials, refresh_token, implicit]"
		}
	}
	return ""
}

// mintClient generates (or rotates) the OAuth client of a DCR strategy, writing
// both strategy.clientId and the read-only clientRegistration block. Caller MUST
// hold the lock. keepID rotates the SECRET only (refreshCredentials semantics).
func (s *Server) mintClient(strat map[string]any, keepID bool) {
	dcr, _ := strat["dcrConfig"].(map[string]any)
	if dcr == nil {
		return
	}
	clientID, _ := strat["clientId"].(string)
	if !keepID || clientID == "" {
		clientID = s.store.nextID("client")
	}
	grants := map[string]bool{}
	if list, ok := dcr["allowedGrantTypes"].([]any); ok {
		for _, g := range list {
			gs, _ := g.(string)
			grants[gs] = true
		}
	}
	name, _ := dcr["clientName"].(string)
	if name == "" {
		name, _ = strat["name"].(string)
	}
	scopes := dcr["scopes"]
	if scopes == nil {
		scopes = []any{}
	}
	redirects := dcr["redirectUris"]
	if redirects == nil {
		redirects = []any{}
	}
	ct, _ := dcr["clientType"].(string)
	strat["clientId"] = clientID
	strat["clientRegistration"] = map[string]any{
		"clientId":                 clientID,
		"clientSecret":             s.store.nextID("secret"),
		"name":                     name,
		"version":                  "1.0",
		"type":                     strings.ToLower(ct),
		"enabled":                  true,
		"tokenLifetime":            dcr["expirationInterval"],
		"tokenRefreshLimit":        dcr["refreshCount"],
		"redirectUris":             redirects,
		"clScopes":                 scopes,
		"authCodeAllowed":          grants["authorization_code"],
		"implicitAllowed":          grants["implicit"],
		"clientCredentialsAllowed": grants["client_credentials"],
		"resourceOwnerAllowed":     grants["password"],
	}
	// The gateway normalises the config it echoes back (clientName + version),
	// which is why the role compares desired ⊆ live and never for equality.
	dcr["clientName"] = name
	dcr["clientVersion"] = "1.0"
}

// maskStrategy hides the minted secret, reproducing the live 10.15 asymmetry
// measured on 2026-08-03 (apigateway-trial:10.15, throwaway strategy):
//
//	POST /strategies      -> clientSecret "********************************"
//	GET  /strategies/{id} -> clientSecret "********************************"
//	GET  /strategies       -> clientSecret IN CLEAR
//
// So the ONLY surface that yields a usable credential is the LIST — the same
// family of product inconsistency as the envelope (bare list vs enveloped
// single). Callers that read the create response get asterisks, which is
// exactly the trap the role must not fall into.
//
// WM_MASK_STRATEGY_CREDENTIAL=1 masks the LIST too: the pessimistic build where the
// secret is never readable, which the role must survive via its Vault fallback.
func maskStrategy(rec map[string]any) map[string]any {
	cr, ok := rec["clientRegistration"].(map[string]any)
	if !ok || cr == nil {
		return rec
	}
	out := make(map[string]any, len(rec))
	for k, v := range rec {
		out[k] = v
	}
	masked := make(map[string]any, len(cr))
	for k, v := range cr {
		masked[k] = v
	}
	if _, has := masked["clientSecret"]; has {
		masked["clientSecret"] = strings.Repeat("*", 32) // live width, measured 2026-08-03
	}
	out["clientRegistration"] = masked
	return out
}

// createStrategy takes the NAKED body (type UPPERCASE "OAUTH2" enforced),
// rejects duplicate names and answers ENVELOPED {"strategy":{...}} — live.
// A body carrying dcrConfig MINTS the client (clientId + clientRegistration);
// clientId and dcrConfig are mutually exclusive, as the schema states.
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
	dcr, hasDCR := in["dcrConfig"].(map[string]any)
	if hasDCR {
		if cid, _ := in["clientId"].(string); cid != "" {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "clientId must not be provided when dcrConfig generates the credentials"})
			return
		}
		if msg := validateDCR(dcr); msg != "" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": msg})
			return
		}
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
	if hasDCR {
		s.mintClient(in, false)
	}
	s.store.strategies[in["id"].(string)] = in
	// Live masks the secret in the CREATE response too (see maskStrategy).
	writeJSON(w, http.StatusCreated, map[string]any{"strategy": maskStrategy(in)})
}

func (s *Server) getStrategy(w http.ResponseWriter, r *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	st, ok := s.store.strategies[r.PathValue("id")]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "strategy not found"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"strategy": maskStrategy(st)})
}

// refreshCredentials rotates the SECRET of a DCR strategy in place (the clientId
// survives). "Applicable only when dynamic client registration (generate
// credentials) is enabled in the strategy" — a strategy without dcrConfig is
// rejected rather than silently no-op'ed.
func (s *Server) refreshCredentials(w http.ResponseWriter, r *http.Request) {
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	st, ok := s.store.strategies[r.PathValue("id")]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "strategy not found"})
		return
	}
	if _, hasDCR := st["dcrConfig"].(map[string]any); !hasDCR {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "refreshCredentials applies only to strategies using dynamic client registration"})
		return
	}
	// MEASURED LIVE: refresh mints a WHOLE NEW client — the clientId changes
	// too, it is not a secret-only renewal. Anything holding the old clientId
	// is broken by this call, which is why the role never plays it on apply.
	s.mintClient(st, false)
	writeJSON(w, http.StatusOK, map[string]any{"strategy": maskStrategy(st)})
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
