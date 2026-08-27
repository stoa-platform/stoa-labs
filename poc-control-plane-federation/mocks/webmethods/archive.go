package main

// archive.go — the ADR-079 DEPLOYMENT VERB on the mock: GET /archive (export a
// portable asset archive) and POST /archive (import it, 0-downtime). Every
// behaviour below is pinned by three artifacts that already exist and are NOT
// negotiable — the mock serves them, they do not adapt to it:
//
//   - scripts/test-archive-promotion.sh — the live 22/22 campaign (2026-07-17);
//     T1..T10 are replayed against this surface unchanged (archive_test.go
//     mirrors each of their facts);
//   - labctl/internal/adapter/webmethods/archive.go (SanitizeArchive) — the
//     layout whitelist (API/** + APIGatewayAssets.acdl), the acdl purge regexes
//     and the isActive fail-closed;
//   - ansible/roles/apim_promote_api/files/sanitize_archive.py — the same, PLUS
//     one stricter constraint: it reads API/<entry>/<entry> for EVERY direct
//     child of API/ and treats it as an API record. Policy/PolicyAction records
//     therefore travel NESTED under their API's directory (a flat
//     API/Policy.<id>/… would make the role read a Policy as an API, fail its
//     isActive gate and break `apis | selectattr(id) | length == 1`).
//
// Layout emitted (raw export — the sanitizers strip the last two families):
//
//	APIGatewayAssets.acdl                                    manifest (assets + dependsOn)
//	ExportReport.json                                        report of the export
//	API/API.<id>/API.<id>                                    the API record
//	API/API.<id>/Policy.<pid>/Policy.<pid>                   its policies
//	API/API.<id>/PolicyAction.<aid>/PolicyAction.<aid>       their enforcement actions
//	Alias/Alias.<alid>/Alias.<alid>                          ONLY when an exported
//	                                                         endpointUri references ${<alias>}
//
// Import semantics (nothing beyond what the harness pins):
//   - only files under API/ and Alias/ named <Type>.<id> are read, at ANY depth
//     (the harness re-zips and re-synthesises archives); the manifest itself is
//     NOT interpreted — T1 imports an archive whose acdl still declares an Alias
//     whose payload was dropped, and expects every row Success;
//   - `overwrite` is a CSV of lowercase plurals, or "*"; a wrong casing or a
//     singular is silently NOT recognised (live-pinned);
//   - an existing asset outside the scope is REFUSED ("Asset already exists",
//     T3) and left intact — except an Alias, which is SKIPPED with Success and
//     overwritten:false so the target env keeps its own value (T7);
//   - isActive travels: an archive carrying isActive:false DEACTIVATES (T5);
//   - the whole switch happens under ONE store lock, so the data-plane (which
//     holds the read lock for a whole request) never sees a half-imported API —
//     that is the 0-downtime property T4 measures under load.

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"path"
	"sort"
	"strings"
)

// acdlEntry is the manifest both sanitizers require at the zip root.
const acdlEntry = "APIGatewayAssets.acdl"

// defaultOverwriteScope is the proven import scope (labctl's DefaultOverwrite):
// the API and its policy graph, never the env-local aliases.
const defaultOverwriteScope = "apis,policies,policyactions"

// archivePlural maps an asset type to the lowercase plural the `overwrite`
// query parameter uses — the ONLY spelling the product recognises.
var archivePlural = map[string]string{
	"API": "apis", "Policy": "policies", "PolicyAction": "policyactions", "Alias": "aliases",
}

// archiveTypeRank orders the ArchiveResult rows (dependency order, so a reader
// scanning the report top-down sees the API before its policy graph).
var archiveTypeRank = map[string]int{"API": 0, "Policy": 1, "PolicyAction": 2, "Alias": 3}

// --- export --------------------------------------------------------------------

// exportArchive serves GET /archive?apis=<id>[,<id>…] as a zip. Read lock only:
// an export never mutates. An unknown id is a 404 rather than a silently empty
// archive (the role's EXPORT_CONFIRMED assert would otherwise pass on nothing).
func (s *Server) exportArchive(w http.ResponseWriter, r *http.Request) {
	ids := splitCSV(r.URL.Query().Get("apis"))
	if len(ids) == 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "archive export requires ?apis=<id>[,<id>…]"})
		return
	}

	s.store.mu.RLock()
	defer s.store.mu.RUnlock()

	entries := map[string][]byte{} // archive path -> payload, written in acdl-first order below
	var order []string             // API/ and Alias/ payloads, in emission order
	var manifest archiveManifest
	aliases := map[string]bool{} // alias ids to embed (deduplicated)

	add := func(dir, typ, id string, rec any) error {
		body, err := json.MarshalIndent(rec, "", "  ")
		if err != nil {
			return err
		}
		name := path.Join(dir, typ+"."+id, typ+"."+id)
		entries[name] = body
		order = append(order, name)
		return nil
	}

	for _, id := range ids {
		api, ok := s.store.apis[id]
		if !ok {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "no API with id " + id})
			return
		}
		apiDir := path.Join("API", "API."+id)
		if err := add("API", "API", id, archiveAPIRecord(api)); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "archive export: " + err.Error()})
			return
		}
		apiAsset := manifest.asset("API."+id, "API")
		for _, polID := range api.Policies {
			pol := s.store.policies[polID]
			if pol == nil {
				continue // dangling policy reference: nothing to export, no manifest edge
			}
			if err := add(apiDir, "Policy", polID, pol); err != nil {
				writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "archive export: " + err.Error()})
				return
			}
			apiAsset.dependsOn("Policy." + polID)
			polAsset := manifest.asset("Policy."+polID, "Policy")
			for _, actID := range policyActionIDs(pol) {
				act := s.store.actions[actID]
				if act == nil {
					continue
				}
				if err := add(apiDir, "PolicyAction", actID, act); err != nil {
					writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "archive export: " + err.Error()})
					return
				}
				polAsset.dependsOn("PolicyAction." + actID)
				actAsset := manifest.asset("PolicyAction."+actID, "PolicyAction")
				// An ${alias} in the routing endpointUri drags the Alias asset
				// into the archive — the per-env value leak the sanitizers exist
				// to strip (T7 asserts the export DOES embed it).
				for _, name := range endpointURIAliases(act) {
					al := s.store.aliasByName(name)
					if al == nil {
						continue
					}
					alID, _ := al["id"].(string)
					if alID == "" {
						continue
					}
					actAsset.dependsOn("Alias." + alID)
					if !aliases[alID] {
						aliases[alID] = true
						if err := add("Alias", "Alias", alID, maskAlias(al)); err != nil {
							writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "archive export: " + err.Error()})
							return
						}
						manifest.asset("Alias."+alID, "Alias")
					}
				}
			}
		}
	}

	// ExportReport.json is part of the RAW export (both sanitizers strip it).
	report, err := json.MarshalIndent(map[string]any{
		"exportedOn": s.now().UTC().Format("2006-01-02T15:04:05Z"),
		"gateway":    "webmethods-mock",
		"assets":     manifest.names(),
	}, "", "  ")
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "archive export: " + err.Error()})
		return
	}

	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	write := func(name string, body []byte) error {
		f, err := zw.Create(name)
		if err != nil {
			return err
		}
		_, err = f.Write(body)
		return err
	}
	// acdl first, entries at the ROOT (no prefix) — the exact shape both
	// sanitizers re-emit, so a sanitized archive and a raw one are the same
	// object modulo what was stripped.
	err = write(acdlEntry, manifest.render())
	if err == nil {
		err = write("ExportReport.json", report)
	}
	for _, name := range order {
		if err != nil {
			break
		}
		err = write(name, entries[name])
	}
	if err == nil {
		err = zw.Close()
	}
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "archive export: " + err.Error()})
		return
	}

	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", `attachment; filename="APIGatewayAssets.zip"`)
	w.Header().Set("X-Gateway", "webmethods-mock")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(buf.Bytes())
}

// archiveAPIRecord is the API record as it travels: the wire keys the sanitizers
// read (id/apiName/apiVersion/isActive) PLUS apiDefinition, without which a
// re-import on a virgin gateway would restore an API that serves nothing (the
// data-plane allowlist is derived from it). Teams stay behind: they are env-local
// state, like alias values.
func archiveAPIRecord(rec *apiRecord) map[string]any {
	out := map[string]any{
		"id": rec.ID, "apiName": rec.APIName, "apiVersion": rec.APIVersion,
		"isActive": rec.IsActive, "type": rec.Type, "policies": rec.Policies,
	}
	if rec.Owner != "" {
		out["owner"] = rec.Owner
	}
	if rec.Definition != nil {
		out["apiDefinition"] = rec.Definition
	}
	return out
}

// policyActionIDs lists the enforcement action ids a policy references, in
// stage order (deterministic archives).
func policyActionIDs(pol map[string]any) []string {
	var out []string
	stages, _ := pol["policyEnforcements"].([]any)
	for _, st := range stages {
		sm, _ := st.(map[string]any)
		if sm == nil {
			continue
		}
		enfs, _ := sm["enforcements"].([]any)
		for _, e := range enfs {
			em, _ := e.(map[string]any)
			if em == nil {
				continue
			}
			if id, _ := em["enforcementObjectId"].(string); id != "" {
				out = append(out, id)
			}
		}
	}
	return out
}

// endpointURIAliases returns the alias NAMES a policy action's endpointUri
// references (${sys:resource_path} excluded — it is a per-request variable, not
// an asset).
func endpointURIAliases(act map[string]any) []string {
	uri := actionParamValue(act, "endpointUri")
	if uri == "" {
		return nil
	}
	var out []string
	for _, m := range placeholderRe.FindAllStringSubmatch(uri, -1) {
		if m[1] != resourcePathVar {
			out = append(out, m[1])
		}
	}
	return out
}

// --- the acdl manifest ----------------------------------------------------------

// archiveManifest builds APIGatewayAssets.acdl. Two rules make it survive the
// purge both sanitizers run over it with regexes:
//   - every asset is rendered in CLOSED form (<asset …></asset>), never
//     self-closing: their `<asset name="T\..*?</asset>` pattern would otherwise
//     swallow everything up to the NEXT asset's closing tag;
//   - assets keep insertion order (API, its policies, their actions, then the
//     aliases), so a reader follows the dependency chain top-down.
type archiveManifest struct {
	assets []*archiveAsset
	index  map[string]*archiveAsset
}

type archiveAsset struct {
	name, typ string
	deps      []string
}

func (m *archiveManifest) asset(name, typ string) *archiveAsset {
	if m.index == nil {
		m.index = map[string]*archiveAsset{}
	}
	if a, ok := m.index[name]; ok {
		return a
	}
	a := &archiveAsset{name: name, typ: typ}
	m.index[name] = a
	m.assets = append(m.assets, a)
	return a
}

// dependsOn records one edge, at most once.
func (a *archiveAsset) dependsOn(name string) {
	for _, d := range a.deps {
		if d == name {
			return
		}
	}
	a.deps = append(a.deps, name)
}

func (m *archiveManifest) names() []string {
	out := make([]string, 0, len(m.assets))
	for _, a := range m.assets {
		out = append(out, a.name)
	}
	return out
}

func (m *archiveManifest) render() []byte {
	var b strings.Builder
	b.WriteString("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<assets>\n")
	for _, a := range m.assets {
		fmt.Fprintf(&b, "  <asset name=%q type=%q>", a.name, a.typ)
		for _, d := range a.deps {
			fmt.Fprintf(&b, "<dependsOn>APIGateway:%s</dependsOn>", d)
		}
		b.WriteString("</asset>\n")
	}
	b.WriteString("</assets>\n")
	return []byte(b.String())
}

// --- import ---------------------------------------------------------------------

// archiveEntry is one asset payload found in the uploaded zip.
type archiveEntry struct {
	typ  string
	id   string
	path string
	body []byte
}

// importArchive serves POST /archive?overwrite=<types> (multipart "file").
func (s *Server) importArchive(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseMultipartForm(64 << 20); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid multipart body: " + err.Error()})
		return
	}
	file, _, err := r.FormFile("file")
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": `archive import requires a "file" part carrying the zip`})
		return
	}
	defer file.Close()
	raw, err := io.ReadAll(file)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid multipart body: " + err.Error()})
		return
	}
	entries, err := archiveEntriesOf(raw)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "archive import: " + err.Error()})
		return
	}
	if len(entries) == 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "archive import: the zip declares no importable asset (expected API/<Type>.<id>/<Type>.<id> entries)",
		})
		return
	}
	covered := overwriteScope(r.URL.Query().Get("overwrite"))

	// ONE critical section for the whole archive: the data-plane holds the read
	// lock for a whole request, so it never observes a partially applied import
	// (T4 measures exactly this under 4-way load).
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	rows := make([]any, 0, len(entries))
	for _, e := range entries {
		rows = append(rows, map[string]any{e.typ: s.applyArchiveEntry(e, covered)})
	}
	writeJSON(w, http.StatusCreated, map[string]any{"ArchiveResult": rows})
}

// archiveEntriesOf flattens the zip to the asset payloads under API/ and Alias/.
// Everything else — the manifest, ExportReport.json, PassmanData/… — is ignored
// SILENTLY (the harness imports archives that still declare stripped assets).
// Depth is not constrained: the product nests the policy graph under its API,
// and re-zipped or synthesised archives keep whatever depth they were given.
func archiveEntriesOf(raw []byte) ([]archiveEntry, error) {
	zr, err := zip.NewReader(bytes.NewReader(raw), int64(len(raw)))
	if err != nil {
		return nil, fmt.Errorf("not a zip: %w", err)
	}
	var out []archiveEntry
	seen := map[string]bool{}
	for _, f := range zr.File {
		if f.FileInfo().IsDir() {
			continue
		}
		top, _, nested := strings.Cut(f.Name, "/")
		if !nested || (top != "API" && top != "Alias") {
			continue
		}
		typ, id, ok := strings.Cut(path.Base(f.Name), ".")
		if !ok || id == "" || archivePlural[typ] == "" {
			continue
		}
		if seen[typ+"."+id] {
			continue
		}
		seen[typ+"."+id] = true
		rc, err := f.Open()
		if err != nil {
			return nil, fmt.Errorf("open %s: %w", f.Name, err)
		}
		body, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			return nil, fmt.Errorf("read %s: %w", f.Name, err)
		}
		out = append(out, archiveEntry{typ: typ, id: id, path: f.Name, body: body})
	}
	sort.SliceStable(out, func(i, j int) bool {
		if archiveTypeRank[out[i].typ] != archiveTypeRank[out[j].typ] {
			return archiveTypeRank[out[i].typ] < archiveTypeRank[out[j].typ]
		}
		return out[i].id < out[j].id
	})
	return out, nil
}

// overwriteScope parses the CSV of lowercase plurals. Casing and number are NOT
// forgiven — "APIs" or "api" are silently unrecognised on the product, and that
// silence is the trap the scoped-overwrite discipline is built on. "*" covers
// every type, aliases included (why labctl refuses it outright).
func overwriteScope(param string) map[string]bool {
	covered := map[string]bool{}
	for _, t := range splitCSV(param) {
		if t == "*" {
			for _, plural := range archivePlural {
				covered[plural] = true
			}
			continue
		}
		covered[t] = true
	}
	return covered
}

// splitCSV trims and drops empties.
func splitCSV(v string) []string {
	var out []string
	for _, p := range strings.Split(v, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// applyArchiveEntry imports ONE asset and returns its ArchiveResult row.
// Caller MUST hold the store write lock.
func (s *Server) applyArchiveEntry(e archiveEntry, covered map[string]bool) map[string]any {
	row := func(name, status, explanation string, overwritten bool) map[string]any {
		return map[string]any{
			"id": e.id, "name": name, "status": status,
			"overwritten": overwritten, "explanation": explanation,
		}
	}
	var rec map[string]any
	if err := json.Unmarshal(e.body, &rec); err != nil || rec == nil {
		return row("", "Failed", "Asset payload is not a JSON record ("+e.path+")", false)
	}
	// The ENTRY name carries the asset identity (the harness's L2 synthesis
	// rewrites path and record together); the record's own id is normalised onto
	// it so a hand-edited archive cannot split the two.
	rec["id"] = e.id
	name := archiveRecordName(e.typ, rec)

	exists := s.archiveAssetExists(e.typ, e.id)
	if exists && !covered[archivePlural[e.typ]] {
		if e.typ == "Alias" {
			// T7: an Alias outside the scope is SKIPPED, not refused — the
			// import succeeds and the target env keeps its own per-env value.
			return row(name, "Success", "Asset skipped: aliases are not covered by the overwrite scope", false)
		}
		// T3: refused, state INTACT, never a duplicate.
		return row(name, "Failed", "Asset already exists", false)
	}

	switch e.typ {
	case "API":
		// FAIL CLOSED on a (apiName, apiVersion) already held under ANOTHER id.
		// Letting it through would leave the store with two records answering
		// the same data-plane coordinates, and findAPIByNameVersion resolves by
		// MAP ITERATION — so /gateway/<name>/<version> would serve one or the
		// other at random and every measurement taken on it would float. The
		// scenario is a real G5 one: a tier where the API was published natively
		// (local guid) receiving the source tier's archive (source guid).
		// The house rule applies — never pick an identity in silence
		// (VERSION_BASE_AMBIGUE, SCOPE_AMBIGU, CERT_PATH_AMBIGUOUS): refuse and
		// name the collision. The real product's behaviour here is NOT pinned by
		// any spike; the mock chooses refusal rather than a guess.
		if other := s.apiHoldingNameVersion(e.id, rec); other != nil {
			return row(name, "Failed", fmt.Sprintf(
				"Asset refused: %s v%s already exists under guid %s — importing it as %s would create two records for the same name and version",
				other.APIName, other.APIVersion, other.ID, e.id), false)
		}
		s.importAPIRecord(e.id, rec)
	case "Policy":
		s.store.policies[e.id] = rec
	case "PolicyAction":
		s.store.actions[e.id] = rec
	case "Alias":
		s.store.aliases[e.id] = rec
	}
	if exists {
		return row(name, "Success", "Asset overwritten", true)
	}
	return row(name, "Success", "Asset created", false)
}

// apiHoldingNameVersion returns the API record already holding the (apiName,
// apiVersion) the entry carries, when it is NOT the entry's own id — i.e. the
// record an import would collide with. Caller MUST hold the store lock.
func (s *Server) apiHoldingNameVersion(id string, rec map[string]any) *apiRecord {
	name := stringOf(rec["apiName"])
	if name == "" {
		return nil
	}
	other := s.store.findAPIByNameVersion(name, stringOf(rec["apiVersion"]))
	if other == nil || other.ID == id {
		return nil // free coordinates, or the very record being overwritten
	}
	return other
}

// archiveAssetExists reports whether the target already holds that asset id.
// Caller MUST hold the store lock.
func (s *Server) archiveAssetExists(typ, id string) bool {
	switch typ {
	case "API":
		_, ok := s.store.apis[id]
		return ok
	case "Policy":
		_, ok := s.store.policies[id]
		return ok
	case "PolicyAction":
		_, ok := s.store.actions[id]
		return ok
	case "Alias":
		_, ok := s.store.aliases[id]
		return ok
	}
	return false
}

// archiveRecordName is the display name the ArchiveResult row carries (what the
// role prints when an import fails).
func archiveRecordName(typ string, rec map[string]any) string {
	switch typ {
	case "API":
		name, _ := rec["apiName"].(string)
		return name
	case "Alias":
		name, _ := rec["name"].(string)
		return name
	}
	names, _ := rec["names"].([]any)
	for _, n := range names {
		nm, _ := n.(map[string]any)
		if v, _ := nm["value"].(string); v != "" {
			return v
		}
	}
	return ""
}

// importAPIRecord creates or REPLACES an API record in place, keeping the id the
// archive carries (GUID ISO, T9/T10). isActive travels VERBATIM — an archive
// exported from an inactive API deactivates its target (T5, the proven trap).
// Env-local state that never travels is preserved on an overwrite: teams, and
// the definition when the archive carries none. Caller MUST hold the lock.
func (s *Server) importAPIRecord(id string, rec map[string]any) {
	prev := s.store.apis[id]
	active, _ := rec["isActive"].(bool)
	typ, _ := rec["type"].(string)
	if typ == "" {
		typ = "REST"
	}
	out := &apiRecord{
		ID:         id,
		APIName:    stringOf(rec["apiName"]),
		APIVersion: stringOf(rec["apiVersion"]),
		IsActive:   active,
		Type:       typ,
		Policies:   stringsOf(rec["policies"]),
		Owner:      stringOf(rec["owner"]),
		Teams:      defaultTeams(),
	}
	if def, ok := rec["apiDefinition"].(map[string]any); ok {
		out.Definition = def
	}
	if prev != nil {
		out.Teams = prev.Teams
		if out.Definition == nil {
			out.Definition = prev.Definition
		}
		if out.Owner == "" {
			out.Owner = prev.Owner
		}
	}
	s.store.apis[id] = out
	// A lineage the target does not know yet starts here, so the native
	// versioning gate ("latest only") has a pointer to compare against.
	if s.store.latestVersionID[out.APIName] == "" {
		s.store.latestVersionID[out.APIName] = id
	}
}

func stringOf(v any) string {
	s, _ := v.(string)
	return s
}

func stringsOf(v any) []string {
	list, _ := v.([]any)
	out := make([]string, 0, len(list))
	for _, item := range list {
		if s, ok := item.(string); ok {
			out = append(out, s)
		}
	}
	return out
}
