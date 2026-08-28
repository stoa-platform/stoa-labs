package main

// Tests of the /archive surface — the ADR-079 deployment verb. Every assertion
// here mirrors ONE fact of scripts/test-archive-promotion.sh (T1..T10, the live
// 22/22 campaign of 2026-07-17) or ONE layout constraint of the two sanitizers
// that read what this export emits (labctl SanitizeArchive and the Ansible role's
// files/sanitize_archive.py). The sanitizers are NOT imported (the mock module is
// standalone): their CHECKS are re-expressed here.

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"path"
	"strings"
	"sync"
	"testing"
)

// --- helpers ------------------------------------------------------------------

// exportArchiveEntries GETs the raw export of one API and returns the zip
// flattened to path -> content (directory entries dropped, like every consumer).
func exportArchiveEntries(t *testing.T, h http.Handler, apiID string) map[string][]byte {
	t.Helper()
	req := httptest.NewRequest("GET", "/rest/apigateway/archive?apis="+apiID, nil)
	req.SetBasicAuth(testUser, testPass)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("export code = %d body=%s", rr.Code, rr.Body)
	}
	raw := rr.Body.Bytes()
	if !bytes.HasPrefix(raw, []byte("PK")) {
		t.Fatalf("export is not a zip (labctl ExportArchive asserts the PK prefix): %.80s", raw)
	}
	return unzipEntries(t, raw)
}

func unzipEntries(t *testing.T, raw []byte) map[string][]byte {
	t.Helper()
	zr, err := zip.NewReader(bytes.NewReader(raw), int64(len(raw)))
	if err != nil {
		t.Fatalf("open zip: %v", err)
	}
	out := map[string][]byte{}
	for _, f := range zr.File {
		if f.FileInfo().IsDir() {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			t.Fatalf("open %s: %v", f.Name, err)
		}
		data, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			t.Fatalf("read %s: %v", f.Name, err)
		}
		out[f.Name] = data
	}
	return out
}

// zipEntries re-emits entries at the root, acdl first — the same shape the
// sanitizers re-zip and the harness rebuilds with `zip -qrX`.
func zipEntries(t *testing.T, entries map[string][]byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	write := func(name string) {
		w, err := zw.Create(name)
		if err == nil {
			_, err = w.Write(entries[name])
		}
		if err != nil {
			t.Fatalf("zip %s: %v", name, err)
		}
	}
	if _, ok := entries[acdlEntry]; ok {
		write(acdlEntry)
	}
	for name := range entries {
		if name != acdlEntry {
			write(name)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("close zip: %v", err)
	}
	return buf.Bytes()
}

// importArchive POSTs the entries as the multipart "file" part, exactly like
// labctl's ImportArchive and the role's form-multipart body.
func importArchive(t *testing.T, h http.Handler, query string, entries map[string][]byte) *httptest.ResponseRecorder {
	t.Helper()
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	part, err := mw.CreateFormFile("file", "archive.zip")
	if err == nil {
		_, err = part.Write(zipEntries(t, entries))
	}
	if err == nil {
		err = mw.Close()
	}
	if err != nil {
		t.Fatalf("build multipart: %v", err)
	}
	req := httptest.NewRequest("POST", "/rest/apigateway/archive"+query, &body)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.SetBasicAuth(testUser, testPass)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	return rr
}

// archiveRow is one flattened ArchiveResult entry — the shape labctl's
// []map[string]ImportRow and the role's `dict2items` both read.
type archiveRow struct {
	Type        string
	ID          string `json:"id"`
	Name        string `json:"name"`
	Status      string `json:"status"`
	Overwritten bool   `json:"overwritten"`
	Explanation string `json:"explanation"`
}

func archiveRows(t *testing.T, rr *httptest.ResponseRecorder) []archiveRow {
	t.Helper()
	if rr.Code != http.StatusOK && rr.Code != http.StatusCreated {
		t.Fatalf("import code = %d body=%s", rr.Code, rr.Body)
	}
	var resp struct {
		ArchiveResult []map[string]archiveRow `json:"ArchiveResult"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("parse ArchiveResult %q: %v", rr.Body, err)
	}
	var rows []archiveRow
	for _, entry := range resp.ArchiveResult {
		if len(entry) != 1 {
			t.Fatalf("an ArchiveResult entry must carry exactly ONE type key (to_entries/dict2items), got %d", len(entry))
		}
		for typ, row := range entry {
			row.Type = typ
			rows = append(rows, row)
		}
	}
	if len(rows) == 0 {
		t.Fatalf("empty ArchiveResult: %s", rr.Body)
	}
	return rows
}

func rowOfType(t *testing.T, rows []archiveRow, typ string) archiveRow {
	t.Helper()
	for _, r := range rows {
		if r.Type == typ {
			return r
		}
	}
	t.Fatalf("no %s row in %+v", typ, rows)
	return archiveRow{}
}

func countStatus(rows []archiveRow, status string) int {
	n := 0
	for _, r := range rows {
		if r.Status == status {
			n++
		}
	}
	return n
}

// aliasRoutedAPI is the harness setup: an endpoint alias, an API, and the
// routing action re-pointed onto ${alias}/${sys:resource_path}.
func aliasRoutedAPI(t *testing.T, h http.Handler, apiName, aliasName, uri string) (apiID, aliasID string) {
	t.Helper()
	rr := doAdmin(t, h, "POST", "/rest/apigateway/alias", map[string]any{
		"name": aliasName, "type": "endpoint", "endPointURI": uri,
	})
	if rr.Code != http.StatusCreated {
		t.Fatalf("create alias = %d body=%s", rr.Code, rr.Body)
	}
	aliasID = decode(t, rr)["alias"].(map[string]any)["id"].(string)
	apiID, polID := importAPI(t, h, apiName, "1.0.0")
	putRoutingURI(t, h, routingActionID(t, h, polID), "${"+aliasName+"}/${sys:resource_path}")
	return apiID, aliasID
}

func apiIsActive(t *testing.T, h http.Handler, apiID string) bool {
	t.Helper()
	rr := doAdmin(t, h, "GET", "/rest/apigateway/apis/"+apiID, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("get api = %d body=%s", rr.Code, rr.Body)
	}
	api := decode(t, rr)["apiResponse"].(map[string]any)["api"].(map[string]any)
	active, _ := api["isActive"].(bool)
	return active
}

func aliasURI(t *testing.T, h http.Handler, aliasID string) string {
	t.Helper()
	rr := doAdmin(t, h, "GET", "/rest/apigateway/alias/"+aliasID, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("get alias = %d body=%s", rr.Code, rr.Body)
	}
	uri, _ := decode(t, rr)["alias"].(map[string]any)["endPointURI"].(string)
	return uri
}

// mutateAPIRecord rewrites one field of the API record inside the entries, the
// way T5 (python) and T10 (jq/python) patch an extracted archive.
func mutateAPIRecord(t *testing.T, entries map[string][]byte, apiID, field string, value any) {
	t.Helper()
	name := "API/API." + apiID + "/API." + apiID
	raw, ok := entries[name]
	if !ok {
		t.Fatalf("no API record at %s (entries: %v)", name, entryNames(entries))
	}
	var rec map[string]any
	if err := json.Unmarshal(raw, &rec); err != nil {
		t.Fatalf("API record is not JSON: %v", err)
	}
	rec[field] = value
	out, err := json.Marshal(rec)
	if err != nil {
		t.Fatalf("re-marshal: %v", err)
	}
	entries[name] = out
}

func entryNames(entries map[string][]byte) []string {
	names := make([]string, 0, len(entries))
	for n := range entries {
		names = append(names, n)
	}
	return names
}

// --- export layout (what the two sanitizers require) ---------------------------

func TestExportLayout(t *testing.T) {
	h := newTestServer(t)
	apiID, aliasID := aliasRoutedAPI(t, h, "accounts-read", "env-backend", "http://dev.internal:8081/base")
	entries := exportArchiveEntries(t, h, apiID)

	// The manifest is the import contract of both sanitizers; the RAW export
	// also carries ExportReport.json (which they strip).
	if _, ok := entries[acdlEntry]; !ok {
		t.Fatalf("export carries no %s: %v", acdlEntry, entryNames(entries))
	}
	if _, ok := entries["ExportReport.json"]; !ok {
		t.Errorf("raw export must carry ExportReport.json (stripped downstream): %v", entryNames(entries))
	}

	// API record: id/apiName/apiVersion/isActive are what SanitizeArchive and
	// sanitize_archive.py read; apiDefinition is what makes a virgin import
	// serve traffic again.
	recPath := "API/API." + apiID + "/API." + apiID
	raw, ok := entries[recPath]
	if !ok {
		t.Fatalf("no API record at %s: %v", recPath, entryNames(entries))
	}
	var rec map[string]any
	if err := json.Unmarshal(raw, &rec); err != nil {
		t.Fatalf("API record is not JSON: %v", err)
	}
	if rec["id"] != apiID || rec["apiName"] != "accounts-read" || rec["apiVersion"] != "1.0.0" {
		t.Errorf("API record = %v, want id/apiName/apiVersion of the exported API", rec)
	}
	if active, _ := rec["isActive"].(bool); !active {
		t.Errorf("API record isActive = %v, want true (the API is active)", rec["isActive"])
	}
	if _, ok := rec["apiDefinition"].(map[string]any); !ok {
		t.Errorf("API record carries no apiDefinition — a virgin import could not serve traffic")
	}

	// sanitize_archive.py walks os.listdir("API") and reads API/<e>/<e> as an
	// API record: every DIRECT child of API/ must therefore be an API.<id>
	// directory, or the role's `apis | selectattr(id) | length == 1` breaks and
	// the isActive fail-closed fires on a Policy record.
	for name := range entries {
		if !strings.HasPrefix(name, "API/") {
			continue
		}
		child := strings.SplitN(strings.TrimPrefix(name, "API/"), "/", 2)[0]
		if !strings.HasPrefix(child, "API.") {
			t.Errorf("API/%s is a direct child of API/ — sanitize_archive.py would read it as an API record", child)
		}
	}

	// The policy graph travels under the API, one record per asset directory.
	var policies, actions, routing []string
	for name := range entries {
		switch base := path.Base(name); {
		case strings.HasPrefix(base, "Policy."):
			policies = append(policies, name)
		case strings.HasPrefix(base, "PolicyAction."):
			actions = append(actions, name)
		}
		if strings.HasPrefix(name, "API/") && strings.Contains(string(entries[name]), "straightThroughRouting") {
			routing = append(routing, name)
		}
	}
	if len(policies) != 1 {
		t.Errorf("export carries %d Policy records, want 1: %v", len(policies), policies)
	}
	if len(actions) != 2 {
		t.Errorf("export carries %d PolicyAction records, want 2 (routing + transport): %v", len(actions), actions)
	}
	// `grep -rl straightThroughRouting .../API` must resolve to ONE file: the
	// harness feeds its output to jq as a single path.
	if len(routing) != 1 {
		t.Errorf("%d files under API/ mention straightThroughRouting, want exactly 1: %v", len(routing), routing)
	}

	// T7: the export of an ${alias}-routed API EMBEDS the Alias asset (the fact
	// the sanitizers exist to strip).
	aliasPath := "Alias/Alias." + aliasID + "/Alias." + aliasID
	if _, ok := entries[aliasPath]; !ok {
		t.Fatalf("no Alias asset at %s — T7 asserts the export embeds it: %v", aliasPath, entryNames(entries))
	}

	// The acdl must satisfy both sanitizers' regexes: every declared asset, and
	// a dependsOn per edge. The Alias asset is emitted in CLOSED form so the
	// `<asset name="Alias\..*?</asset>` purge cannot swallow a neighbour.
	acdl := string(entries[acdlEntry])
	for _, want := range []string{
		`<asset name="API.` + apiID + `" type="API">`,
		`<asset name="Alias.` + aliasID + `" type="Alias"></asset>`,
		`<dependsOn>APIGateway:Alias.` + aliasID + `</dependsOn>`,
	} {
		if !strings.Contains(acdl, want) {
			t.Errorf("acdl misses %q:\n%s", want, acdl)
		}
	}
	if strings.Contains(acdl, `type="Alias"/>`) {
		t.Errorf("self-closing Alias asset: the sanitizers' `.*?</asset>` purge would eat the next asset:\n%s", acdl)
	}
}

func TestExport_UnknownAPIIs404(t *testing.T) {
	h := newTestServer(t)
	req := httptest.NewRequest("GET", "/rest/apigateway/archive?apis=ghost", nil)
	req.SetBasicAuth(testUser, testPass)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("export of an unknown id = %d, want 404", rr.Code)
	}
}

// --- import: conflict without overwrite (T3) -----------------------------------

func TestImportConflictWithoutOverwrite(t *testing.T) {
	h := newTestServer(t)
	apiID, _ := aliasRoutedAPI(t, h, "accounts-read", "env-backend", "http://dev.internal:8081/base")
	entries := exportArchiveEntries(t, h, apiID)

	rows := archiveRows(t, importArchive(t, h, "", entries))
	if countStatus(rows, "Failed") == 0 {
		t.Errorf("import without overwrite = %+v, want at least one Failed/Asset already exists", rows)
	}
	api := rowOfType(t, rows, "API")
	if api.Status != "Failed" || api.Explanation != "Asset already exists" {
		t.Errorf("API row = %+v, want Failed/\"Asset already exists\"", api)
	}
	if api.Overwritten {
		t.Errorf("a refused asset must not report overwritten:true (%+v)", api)
	}

	// T3: no duplication — the catalogue still holds ONE record for the guid.
	rr := doAdmin(t, h, "GET", "/rest/apigateway/apis", nil)
	items := decode(t, rr)["apiResponse"].([]any)
	seen := 0
	for _, it := range items {
		api := it.(map[string]any)["api"].(map[string]any)
		if api["id"] == apiID {
			seen++
		}
	}
	if seen != 1 {
		t.Errorf("guid %s appears %d times in the catalogue, want 1", apiID, seen)
	}
	if !apiIsActive(t, h, apiID) {
		t.Errorf("a refused import must leave the API untouched (it went inactive)")
	}
}

// --- import: the isActive trap (T5) --------------------------------------------

func TestImportOverwriteAppliesIsActive(t *testing.T) {
	h := newTestServer(t)
	apiID, _ := aliasRoutedAPI(t, h, "accounts-read", "env-backend", "http://dev.internal:8081/base")
	entries := exportArchiveEntries(t, h, apiID)

	inactive := map[string][]byte{}
	for k, v := range entries {
		inactive[k] = v
	}
	mutateAPIRecord(t, inactive, apiID, "isActive", false)

	rows := archiveRows(t, importArchive(t, h, "?overwrite="+defaultOverwriteScope, inactive))
	if n := countStatus(rows, "Success"); n != len(rows) {
		t.Fatalf("scoped overwrite = %+v, want every row Success", rows)
	}
	if api := rowOfType(t, rows, "API"); !api.Overwritten {
		t.Errorf("API row = %+v, want overwritten:true", api)
	}
	if apiIsActive(t, h, apiID) {
		t.Errorf("T5: an isActive:false archive must DEACTIVATE the API (the proven trap)")
	}

	// Re-importing the active archive repairs it — the 0-downtime repair path.
	rows = archiveRows(t, importArchive(t, h, "?overwrite="+defaultOverwriteScope, entries))
	if n := countStatus(rows, "Success"); n != len(rows) {
		t.Fatalf("repair import = %+v, want every row Success", rows)
	}
	if !apiIsActive(t, h, apiID) {
		t.Errorf("T5: re-importing isActive:true must re-activate")
	}
}

// --- import on a virgin gateway (T9) -------------------------------------------

func TestImportVirginKeepsGUID(t *testing.T) {
	h := newTestServer(t)
	apiID, _ := aliasRoutedAPI(t, h, "accounts-read", "env-backend", "http://dev.internal:8081/base")
	entries := exportArchiveEntries(t, h, apiID)

	if rr := doAdmin(t, h, "PUT", "/rest/apigateway/apis/"+apiID+"/deactivate", nil); rr.Code != http.StatusOK {
		t.Fatalf("deactivate = %d", rr.Code)
	}
	if rr := doAdmin(t, h, "DELETE", "/rest/apigateway/apis/"+apiID, nil); rr.Code != http.StatusNoContent {
		t.Fatalf("delete api = %d body=%s, want 204", rr.Code, rr.Body)
	}
	if rr := doAdmin(t, h, "GET", "/rest/apigateway/apis/"+apiID, nil); rr.Code != http.StatusNotFound {
		t.Fatalf("get after delete = %d, want 404", rr.Code)
	}

	// No overwrite scope at all: on a virgin gateway EVERY asset is created —
	// which only holds if deleting the API dropped its policy graph too.
	rows := archiveRows(t, importArchive(t, h, "", entries))
	if n := countStatus(rows, "Success"); n != len(rows) {
		t.Fatalf("virgin import = %+v, want every row Success", rows)
	}
	for _, r := range rows {
		if r.Overwritten {
			t.Errorf("virgin import row %+v reports overwritten:true", r)
		}
	}
	if api := rowOfType(t, rows, "API"); api.ID != apiID {
		t.Errorf("API row id = %q, want the archive's guid %q (GUID ISO)", api.ID, apiID)
	}
	if !apiIsActive(t, h, apiID) {
		t.Errorf("T9: the re-created API must arrive ACTIVE (archive isActive:true)")
	}
	// The routing (and the definition it needs) survived the round trip.
	rr := do(t, h, "GET", "/gateway/accounts-read/1.0.0/accounts", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("data-plane after virgin import = %d body=%s", rr.Code, rr.Body)
	}
	if got := decode(t, rr)["resolved_url"]; got != "http://dev.internal:8081/base/accounts" {
		t.Errorf("resolved_url = %v, want the ${alias} routing restored by the archive", got)
	}
}

// --- import: the alias skip (T6/T7) --------------------------------------------

func TestImportSkipsUncoveredAlias(t *testing.T) {
	h := newTestServer(t)
	apiID, aliasID := aliasRoutedAPI(t, h, "accounts-read", "env-backend", "http://dev.internal:8081/base")
	entries := exportArchiveEntries(t, h, apiID)

	// The target env flips its own alias value (T6: per-request, no API touch).
	if rr := doAdmin(t, h, "PUT", "/rest/apigateway/alias/"+aliasID, map[string]any{
		"name": "env-backend", "type": "endpoint", "endPointURI": "http://prod.internal:8083/base",
	}); rr.Code != http.StatusOK {
		t.Fatalf("flip alias = %d body=%s", rr.Code, rr.Body)
	}

	rows := archiveRows(t, importArchive(t, h, "?overwrite="+defaultOverwriteScope, entries))
	alias := rowOfType(t, rows, "Alias")
	if alias.Overwritten {
		t.Errorf("T7: an Alias outside the overwrite scope must report overwritten:false (%+v)", alias)
	}
	if alias.Status != "Success" {
		t.Errorf("T7: the skipped Alias must not fail the import (%+v)", alias)
	}
	if got := aliasURI(t, h, aliasID); got != "http://prod.internal:8083/base" {
		t.Errorf("alias value = %q, want the LOCAL value intact (no clobber)", got)
	}

	// …and covering aliases IS the clobber (why labctl and the role refuse it).
	rows = archiveRows(t, importArchive(t, h, "?overwrite=apis,policies,policyactions,aliases", entries))
	if alias := rowOfType(t, rows, "Alias"); !alias.Overwritten {
		t.Errorf("overwrite=…,aliases must clobber (%+v)", alias)
	}
	if got := aliasURI(t, h, aliasID); got != "http://dev.internal:8081/base" {
		t.Errorf("alias value = %q, want the SOURCE env value (clobbered)", got)
	}
}

// wrong casing / singular is silently NOT recognised (labctl's pinned fact).
func TestImportOverwriteCasingIsNotForgiving(t *testing.T) {
	h := newTestServer(t)
	apiID, _ := aliasRoutedAPI(t, h, "accounts-read", "env-backend", "http://dev.internal:8081/base")
	entries := exportArchiveEntries(t, h, apiID)

	rows := archiveRows(t, importArchive(t, h, "?overwrite=APIs,Policies", entries))
	if api := rowOfType(t, rows, "API"); api.Status != "Failed" {
		t.Errorf("overwrite=APIs must NOT be recognised (%+v)", api)
	}
	rows = archiveRows(t, importArchive(t, h, "?overwrite=api,policy,policyaction", entries))
	if api := rowOfType(t, rows, "API"); api.Status != "Failed" {
		t.Errorf("singular overwrite types must NOT be recognised (%+v)", api)
	}
	// "*" covers everything, aliases included (which is why labctl refuses it).
	rows = archiveRows(t, importArchive(t, h, "?overwrite=*", entries))
	if n := countStatus(rows, "Success"); n != len(rows) {
		t.Errorf("overwrite=* = %+v, want every row Success", rows)
	}
}

// --- 0-downtime under load (T4) ------------------------------------------------

// rekeyPolicyGraph returns the archive with FRESH Policy/PolicyAction ids (paths
// and payloads rewritten together, the way the harness's L2 synthesis does).
// It is what gives the 0-downtime test its teeth: the API record is applied
// first, so an import that does not switch the whole archive under ONE lock
// leaves the API pointing at a policy graph that is not there yet — and the
// data-plane answers 502 instead of 200. With identical ids no window exists and
// the test would prove nothing.
func rekeyPolicyGraph(t *testing.T, entries map[string][]byte) map[string][]byte {
	t.Helper()
	ids := map[string]string{}
	for name := range entries {
		for _, prefix := range []string{"Policy.", "PolicyAction."} {
			if base := path.Base(name); strings.HasPrefix(base, prefix) {
				old := strings.TrimPrefix(base, prefix)
				ids[old] = old + "-b"
			}
		}
	}
	if len(ids) == 0 {
		t.Fatal("no policy graph to re-key")
	}
	sub := func(s string) string {
		for old, fresh := range ids {
			s = strings.ReplaceAll(s, old, fresh)
		}
		return s
	}
	out := map[string][]byte{}
	for name, body := range entries {
		if strings.HasPrefix(name, "API/") {
			out[sub(name)] = []byte(sub(string(body)))
			continue
		}
		out[name] = body
	}
	return out
}

func TestImportIsAtomicUnderLoad(t *testing.T) {
	h := newTestServer(t)
	apiID, _ := aliasRoutedAPI(t, h, "accounts-read", "env-backend", "http://dev.internal:8081/base")
	entries := rekeyPolicyGraph(t, exportArchiveEntries(t, h, apiID))

	var wg sync.WaitGroup
	stop := make(chan struct{})
	codes := make(chan int, 4096)
	for i := 0; i < 4; i++ { // the harness's 4-way load
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				rr := do(t, h, "GET", "/gateway/accounts-read/1.0.0/accounts", nil)
				codes <- rr.Code
			}
		}()
	}
	for i := 0; i < 20; i++ {
		if rr := importArchive(t, h, "?overwrite="+defaultOverwriteScope, entries); rr.Code != http.StatusCreated && rr.Code != http.StatusOK {
			t.Errorf("import under load = %d body=%s", rr.Code, rr.Body)
		}
	}
	close(stop)
	wg.Wait()
	close(codes)
	total, bad := 0, 0
	for c := range codes {
		total++
		if c != http.StatusOK {
			bad++
		}
	}
	if total < 50 {
		t.Fatalf("load generated only %d requests — too thin to prove anything", total)
	}
	if bad != 0 {
		t.Errorf("T4: %d/%d data-plane requests were not 200 during the overwrite", bad, total)
	}
}

// --- import: what it must ignore, and refuse ------------------------------------

func TestImportIgnoresUnknownEntries(t *testing.T) {
	h := newTestServer(t)
	apiID, _ := aliasRoutedAPI(t, h, "accounts-read", "env-backend", "http://dev.internal:8081/base")
	entries := exportArchiveEntries(t, h, apiID)
	entries["PassmanData/passman.dat"] = []byte("encrypted-secret")
	entries["ExportReport.json"] = []byte(`{"whatever":true}`)

	rows := archiveRows(t, importArchive(t, h, "?overwrite="+defaultOverwriteScope, entries))
	for _, r := range rows {
		if r.Type != "API" && r.Type != "Policy" && r.Type != "PolicyAction" && r.Type != "Alias" {
			t.Errorf("unexpected row type %q (%+v)", r.Type, r)
		}
	}
}

func TestImportRefusesGarbage(t *testing.T) {
	h := newTestServer(t)
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	part, _ := mw.CreateFormFile("file", "archive.zip")
	part.Write([]byte("not a zip at all"))
	mw.Close()
	req := httptest.NewRequest("POST", "/rest/apigateway/archive", &body)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.SetBasicAuth(testUser, testPass)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("import of a non-zip = %d, want 400", rr.Code)
	}
}

// --- teardown DELETEs (the harness's cleanup + T9 ordering) ---------------------

func TestDeleteAPI_RefusesActiveAndSubscribed(t *testing.T) {
	h := newTestServer(t)
	apiID, aliasID := aliasRoutedAPI(t, h, "accounts-read", "env-backend", "http://dev.internal:8081/base")

	if rr := doAdmin(t, h, "DELETE", "/rest/apigateway/apis/"+apiID, nil); rr.Code != http.StatusConflict {
		t.Fatalf("delete of an ACTIVE api = %d, want 409", rr.Code)
	}
	if rr := doAdmin(t, h, "PUT", "/rest/apigateway/apis/"+apiID+"/deactivate", nil); rr.Code != http.StatusOK {
		t.Fatalf("deactivate = %d", rr.Code)
	}

	rr := doAdmin(t, h, "POST", "/rest/apigateway/applications", map[string]any{"name": "spike-app", "version": "1.0"})
	if rr.Code != http.StatusCreated {
		t.Fatalf("create app = %d body=%s", rr.Code, rr.Body)
	}
	appID := decode(t, rr)["id"].(string)
	if rr := doAdmin(t, h, "PUT", "/rest/apigateway/applications/"+appID+"/apis",
		map[string]any{"apiIDs": []string{apiID}}); rr.Code != http.StatusNoContent {
		t.Fatalf("associate = %d", rr.Code)
	}
	if rr := doAdmin(t, h, "DELETE", "/rest/apigateway/apis/"+apiID, nil); rr.Code != http.StatusConflict {
		t.Fatalf("delete of a SUBSCRIBED api = %d, want 409", rr.Code)
	}

	// Teardown order of the harness: application, then API, then alias.
	if rr := doAdmin(t, h, "DELETE", "/rest/apigateway/applications/"+appID, nil); rr.Code != http.StatusNoContent {
		t.Fatalf("delete app = %d body=%s", rr.Code, rr.Body)
	}
	if rr := doAdmin(t, h, "GET", "/rest/apigateway/applications/"+appID, nil); rr.Code != http.StatusNotFound {
		t.Errorf("get deleted app = %d, want 404", rr.Code)
	}
	if rr := doAdmin(t, h, "DELETE", "/rest/apigateway/apis/"+apiID, nil); rr.Code != http.StatusNoContent {
		t.Fatalf("delete api = %d body=%s", rr.Code, rr.Body)
	}
	if rr := doAdmin(t, h, "DELETE", "/rest/apigateway/alias/"+aliasID, nil); rr.Code != http.StatusNoContent {
		t.Fatalf("delete alias = %d body=%s", rr.Code, rr.Body)
	}
	for _, p := range []string{"/rest/apigateway/apis/" + apiID, "/rest/apigateway/alias/" + aliasID,
		"/rest/apigateway/applications/" + appID} {
		if rr := doAdmin(t, h, "DELETE", p, nil); rr.Code != http.StatusNotFound {
			t.Errorf("second DELETE %s = %d, want 404", p, rr.Code)
		}
	}
}

// T8: an application's subscription is bound BY GUID and survives an overwrite —
// which the harness can only witness through GET /applications/{id}/apis.
func TestSubscriptionSurvivesOverwrite(t *testing.T) {
	h := newTestServer(t)
	apiID, _ := aliasRoutedAPI(t, h, "accounts-read", "env-backend", "http://dev.internal:8081/base")
	entries := exportArchiveEntries(t, h, apiID)

	rr := doAdmin(t, h, "POST", "/rest/apigateway/applications", map[string]any{"name": "spike-app", "version": "1.0"})
	appID := decode(t, rr)["id"].(string)
	if rr := doAdmin(t, h, "PUT", "/rest/apigateway/applications/"+appID+"/apis",
		map[string]any{"apiIDs": []string{apiID}}); rr.Code != http.StatusNoContent {
		t.Fatalf("associate = %d", rr.Code)
	}
	if rows := archiveRows(t, importArchive(t, h, "?overwrite="+defaultOverwriteScope, entries)); countStatus(rows, "Success") != len(rows) {
		t.Fatalf("overwrite = %+v, want every row Success", rows)
	}
	rr = doAdmin(t, h, "GET", "/rest/apigateway/applications/"+appID+"/apis", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("get subscriptions = %d body=%s", rr.Code, rr.Body)
	}
	ids, _ := decode(t, rr)["apiIDs"].([]any)
	if len(ids) != 1 || ids[0] != apiID {
		t.Errorf("apiIDs = %v, want the subscription to %s intact after the overwrite", ids, apiID)
	}
	if rr := doAdmin(t, h, "GET", "/rest/apigateway/applications/ghost/apis", nil); rr.Code != http.StatusNotFound {
		t.Errorf("subscriptions of an unknown app = %d, want 404", rr.Code)
	}
}

// mintVersion asks for a new version of a lineage and returns (status, newID).
func mintVersion(t *testing.T, h http.Handler, baseID, version string) (int, string) {
	t.Helper()
	rr := doAdmin(t, h, "POST", "/rest/apigateway/apis/"+baseID+"/versions",
		map[string]any{"newApiVersion": version})
	if rr.Code != http.StatusCreated {
		return rr.Code, ""
	}
	api := decode(t, rr)["apiResponse"].(map[string]any)["api"].(map[string]any)
	return rr.Code, api["id"].(string)
}

func deleteInactiveAPI(t *testing.T, h http.Handler, id string) {
	t.Helper()
	if rr := doAdmin(t, h, "PUT", "/rest/apigateway/apis/"+id+"/deactivate", nil); rr.Code != http.StatusOK {
		t.Fatalf("deactivate %s = %d", id, rr.Code)
	}
	if rr := doAdmin(t, h, "DELETE", "/rest/apigateway/apis/"+id, nil); rr.Code != http.StatusNoContent {
		t.Fatalf("delete %s = %d body=%s", id, rr.Code, rr.Body)
	}
}

// Deleting the record the lineage pointer names must not strand the survivors:
// they would be unversionable ("latest version" gate) AND un-recreatable (409 on
// the name) — a dead end.
func TestDeleteAPI_KeepsTheVersionLineageAlive(t *testing.T) {
	h := newTestServer(t)
	// A three-version lineage, so deleting the latest leaves TWO survivors and
	// "which one the pointer lands on" is an observable choice.
	v1, _ := importAPI(t, h, "accounts-read", "1.0.0")
	_, v2 := mintVersion(t, h, v1, "2.0.0")
	_, v3 := mintVersion(t, h, v2, "3.0.0")
	if v2 == "" || v3 == "" {
		t.Fatalf("lineage setup failed (v2=%q v3=%q)", v2, v3)
	}

	deleteInactiveAPI(t, h, v3)

	// The pointer must land on the most recently minted SURVIVOR (v2), not on
	// v1 and not nowhere.
	if code, id := mintVersion(t, h, v2, "4.0.0"); code != http.StatusCreated {
		t.Errorf("versioning from the surviving latest = %d, want 201 (the lineage is stranded)", code)
	} else if id == "" {
		t.Error("mint from v2 returned no id")
	}
	if code, _ := mintVersion(t, h, v1, "5.0.0"); code != http.StatusBadRequest {
		t.Errorf("versioning from an OLDER survivor = %d, want 400 (the pointer must name the newest)", code)
	}

	// And when the name disappears entirely, the pointer must go with it: the
	// name becomes free for a fresh POST /apis again.
	for _, id := range apiIDsOfName(t, h, "accounts-read") {
		deleteInactiveAPI(t, h, id)
	}
	rr := doAdmin(t, h, "POST", "/rest/apigateway/apis", importBody("accounts-read", "1.0.0"))
	if rr.Code != http.StatusCreated {
		t.Fatalf("re-creating a fully deleted name = %d body=%s, want 201", rr.Code, rr.Body)
	}
}

// apiIDsOfName lists the catalogue ids carrying an apiName.
func apiIDsOfName(t *testing.T, h http.Handler, name string) []string {
	t.Helper()
	rr := doAdmin(t, h, "GET", "/rest/apigateway/apis", nil)
	var out []string
	for _, it := range decode(t, rr)["apiResponse"].([]any) {
		api := it.(map[string]any)["api"].(map[string]any)
		if api["apiName"] == name {
			out = append(out, api["id"].(string))
		}
	}
	return out
}

// The G5 collision: a tier where the API was published NATIVELY (local guid)
// receives the source tier's archive (source guid). Two records for one
// name+version would make findAPIByNameVersion — a map iteration — serve one or
// the other at random, so the import refuses that line and mutates nothing.
func TestImportRefusesNameVersionHeldByAnotherGUID(t *testing.T) {
	h := newTestServer(t)
	sourceID, _ := aliasRoutedAPI(t, h, "accounts-read", "env-backend", "http://dev.internal:8081/base")
	entries := exportArchiveEntries(t, h, sourceID)

	// The target tier: same name+version, minted locally under its OWN guid.
	deleteInactiveAPI(t, h, sourceID)
	rr := doAdmin(t, h, "POST", "/rest/apigateway/apis", importBody("accounts-read", "1.0.0"))
	if rr.Code != http.StatusCreated {
		t.Fatalf("local publish = %d body=%s", rr.Code, rr.Body)
	}
	localID := decode(t, rr)["apiResponse"].(map[string]any)["api"].(map[string]any)["id"].(string)
	if localID == sourceID {
		t.Fatal("the local record must carry a DIFFERENT guid for this test to mean anything")
	}

	rows := archiveRows(t, importArchive(t, h, "?overwrite="+defaultOverwriteScope, entries))
	api := rowOfType(t, rows, "API")
	if api.Status != "Failed" {
		t.Errorf("API row = %+v, want Failed (the name+version is held by another guid)", api)
	}
	if !strings.Contains(api.Explanation, localID) {
		t.Errorf("explanation = %q, want it to NAME the colliding guid %s", api.Explanation, localID)
	}
	if api.Overwritten {
		t.Errorf("a refused line must not report overwritten:true (%+v)", api)
	}
	// Nothing mutated for that line: the source guid was NOT created…
	if rr := doAdmin(t, h, "GET", "/rest/apigateway/apis/"+sourceID, nil); rr.Code != http.StatusNotFound {
		t.Errorf("source guid after the refusal = %d, want 404 (nothing must be created)", rr.Code)
	}
	// …and the local record still holds the coordinates, alone.
	if ids := apiIDsOfName(t, h, "accounts-read"); len(ids) != 1 || ids[0] != localID {
		t.Errorf("catalogue = %v, want the local record %s alone", ids, localID)
	}
	// The rest of the archive follows the normal semantics (fresh ids here).
	for _, r := range rows {
		if r.Type != "API" && r.Status != "Success" {
			t.Errorf("row %+v: the other assets must follow the normal semantics", r)
		}
	}
}

func TestDeleteAPI_DropsItsPolicyGraph(t *testing.T) {
	h := newTestServer(t)
	apiID, polID := importAPI(t, h, "accounts-read", "1.0.0")
	actID := routingActionID(t, h, polID)
	if rr := doAdmin(t, h, "PUT", "/rest/apigateway/apis/"+apiID+"/deactivate", nil); rr.Code != http.StatusOK {
		t.Fatalf("deactivate = %d", rr.Code)
	}
	if rr := doAdmin(t, h, "DELETE", "/rest/apigateway/apis/"+apiID, nil); rr.Code != http.StatusNoContent {
		t.Fatalf("delete api = %d body=%s", rr.Code, rr.Body)
	}
	if rr := doAdmin(t, h, "GET", "/rest/apigateway/policies/"+polID, nil); rr.Code != http.StatusNotFound {
		t.Errorf("policy after API delete = %d, want 404 (a leftover breaks the virgin re-import)", rr.Code)
	}
	if rr := doAdmin(t, h, "GET", "/rest/apigateway/policyActions/"+actID, nil); rr.Code != http.StatusNotFound {
		t.Errorf("policy action after API delete = %d, want 404", rr.Code)
	}
}
