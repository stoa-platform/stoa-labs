// archive.go — the ADR-079 deployment verb: asset-archive export / sanitize /
// import against the 10.15 Archive REST surface, plus the parameterised
// alias/scope primitives the `labctl promote` command drives.
//
// Every shape here is SPIKE-PINNED live (2026-07-17, apigateway-trial:10.15 —
// campaign replayable via scripts/test-archive-promotion.sh, 22/22):
//
//   - EXPORT  GET  /rest/apigateway/archive?apis=<id>[,<id>…]  -> zip
//     { API/API.<guid>/… (naked JSON records), APIGatewayAssets.acdl (the
//     import MANIFEST: assets + dependsOn), ExportReport.json (ignorable) }.
//   - IMPORT  POST /rest/apigateway/archive?overwrite=<types> multipart
//     file=<zip> -> 201 + {"ArchiveResult":[{<Type>:{status,overwritten,…}}]}.
//     overwrite types are LOWERCASE PLURALS ("apis,policies,policyactions");
//     wrong casing/singular is SILENTLY not recognised; an asset in conflict
//     not covered by overwrite is SKIPPED without cascading (correct syntax).
//   - GUIDs travel with the archive: overwrite updates in place, a fresh
//     import on a virgin gateway re-creates the SAME guids (iso promotion),
//     and a fully SYNTHESISED archive with authored guids is accepted (L2).
//   - 0-DOWNTIME: overwriting an ACTIVE API swaps it in place (measured 3×
//     under load, including a routing change delivered by archive) — the
//     admin PUT path needs deactivate; the archive path never does.
//
// Traps the sanitizer exists to close (all proven):
//   - isActive:false in the archive DEACTIVATES the target API on import
//     (durable 404s) -> exporting an inactive API is refused, and the API
//     record is asserted active.
//   - the export of an ${alias}-routed API EMBEDS the Alias asset (the SOURCE
//     env's value) and, for credential aliases, a PassmanData/ entry carrying
//     the ENCRYPTED secret -> both are stripped (zip AND acdl: a declared
//     asset missing its payload fails its whole dependency branch).
//   - ${alias} is resolved name->id AT DEPLOY TIME (value read per request):
//     aliases must exist BEFORE the first import (alias-first) and are NEVER
//     delete/recreated — converge by PUT only; a broken binding is repaired
//     by re-importing the archive (0-downtime).
package webmethods

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"regexp"
	"sort"
	"strings"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

// archiveKeepTypes are the asset types a PORTABLE archive may carry. Everything
// else (Alias values, PassmanData secrets, users/teams…) is env-local state
// posed by the deployer, never by the artifact.
var archiveKeepTypes = map[string]bool{"API": true, "Policy": true, "PolicyAction": true}

// DefaultOverwrite is the proven import scope: the API and its policy graph,
// NEVER "aliases" (would clobber the target env's per-env values) and never
// "*" (same, plus it would seed foreign values on a virgin gateway).
const DefaultOverwrite = "apis,policies,policyactions"

// ArchiveAPIInfo is one API record found in an archive (the id-map material).
type ArchiveAPIInfo struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Version  string `json:"version"`
	IsActive bool   `json:"isActive"`
}

// SanitizeReport says what the sanitizer kept, dropped and rewrote.
type SanitizeReport struct {
	APIs             []ArchiveAPIInfo `json:"apis"`
	Stripped         []string         `json:"stripped"`
	RoutingRewritten []string         `json:"routingRewritten"`
}

// ImportRow is one flattened ArchiveResult entry.
type ImportRow struct {
	Type        string `json:"type"`
	Name        string `json:"name"`
	ID          string `json:"id"`
	Status      string `json:"status"`
	Overwritten bool   `json:"overwritten"`
	Explanation string `json:"explanation"`
}

// ExportArchive downloads the raw export zip for one API id. The caller is
// expected to run SanitizeArchive before persisting or shipping it.
func (a *Adapter) ExportArchive(ctx context.Context, apiID string) ([]byte, error) {
	url := a.adminPath("/archive?apis=" + apiID)
	headers := a.authHeaders()
	headers["Accept"] = "application/json"
	code, body, err := httpx.Do(ctx, a.http, http.MethodGet, url, headers, nil)
	if err != nil {
		return nil, fmt.Errorf("archive export %s: %w", apiID, err)
	}
	if code != http.StatusOK {
		return nil, fmt.Errorf("archive export %s: expected 200, got %d: %s", apiID, code, truncate(body, 300))
	}
	if !bytes.HasPrefix(body, []byte("PK")) {
		return nil, fmt.Errorf("archive export %s: response is not a zip (got %s)", apiID, truncate(body, 200))
	}
	return body, nil
}

// SanitizeArchive makes an export PORTABLE and SECRET-FREE (pure function):
//  1. whitelist API/** + APIGatewayAssets.acdl (drops Alias/, PassmanData/,
//     ExportReport.json — the proven minimal import set is acdl + API/);
//  2. purge the acdl manifest of non-whitelisted assets and their dependsOn
//     (a declared asset with no payload fails its dependency branch);
//  3. when routingAlias is non-empty, re-point every straightThroughRouting
//     endpointUri onto "${routingAlias}/${sys:resource_path}" — the authoring
//     env may publish a literal backend, the ARTIFACT always routes by alias;
//  4. fail closed on isActive:false (such an archive deactivates on import).
func SanitizeArchive(zipBytes []byte, routingAlias string) ([]byte, SanitizeReport, error) {
	rep := SanitizeReport{}
	zr, err := zip.NewReader(bytes.NewReader(zipBytes), int64(len(zipBytes)))
	if err != nil {
		return nil, rep, fmt.Errorf("sanitize: not a zip: %w", err)
	}

	var acdl []byte
	kept := map[string][]byte{} // archive-relative path -> content (API/** only)
	for _, f := range zr.File {
		if f.FileInfo().IsDir() {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return nil, rep, fmt.Errorf("sanitize: open %s: %w", f.Name, err)
		}
		data, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			return nil, rep, fmt.Errorf("sanitize: read %s: %w", f.Name, err)
		}
		switch {
		case f.Name == "APIGatewayAssets.acdl":
			acdl = data
		case strings.HasPrefix(f.Name, "API/"):
			kept[f.Name] = data
		default:
			rep.Stripped = append(rep.Stripped, f.Name)
		}
	}
	if acdl == nil {
		return nil, rep, fmt.Errorf("sanitize: APIGatewayAssets.acdl missing — not an API Gateway archive")
	}
	if len(kept) == 0 {
		return nil, rep, fmt.Errorf("sanitize: no API/ payload — the source API is a stub (empty export)")
	}

	// 2. purge the manifest: drop every asset type outside the whitelist,
	// and every dependsOn pointing at one.
	s := string(acdl)
	for _, t := range acdlTypes(s) {
		if archiveKeepTypes[t] {
			continue
		}
		s = regexp.MustCompile(`(?s)\s*<asset name="`+regexp.QuoteMeta(t)+`\.[^"]*".*?</asset>`).ReplaceAllString(s, "")
		s = regexp.MustCompile(`\s*<asset name="`+regexp.QuoteMeta(t)+`\.[^"]*"[^>]*/>`).ReplaceAllString(s, "")
		s = regexp.MustCompile(`\s*<dependsOn>APIGateway:`+regexp.QuoteMeta(t)+`\.[^<]*</dependsOn>`).ReplaceAllString(s, "")
		rep.Stripped = append(rep.Stripped, "acdl:"+t+".*")
	}
	acdl = []byte(s)

	// 3. + 4. walk the API records: rewrite routing, collect the id-map,
	// assert active.
	want := ""
	if routingAlias != "" {
		want = "${" + routingAlias + "}/${sys:resource_path}"
	}
	paths := make([]string, 0, len(kept))
	for p := range kept {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	for _, p := range paths {
		base := p[strings.LastIndex(p, "/")+1:]
		switch {
		case strings.HasPrefix(base, "PolicyAction.") && want != "":
			var rec map[string]any
			if err := json.Unmarshal(kept[p], &rec); err != nil {
				continue // non-JSON payloads travel verbatim
			}
			if tk, _ := rec["templateKey"].(string); tk != "straightThroughRouting" {
				continue
			}
			params, _ := rec["parameters"].([]any)
			changed := false
			for _, prm := range params {
				pm, _ := prm.(map[string]any)
				if pm == nil || pm["templateKey"] != "endpointUri" {
					continue
				}
				if vals, _ := pm["values"].([]any); len(vals) != 1 || vals[0] != want {
					pm["values"] = []any{want}
					changed = true
				}
			}
			if changed {
				out, err := json.MarshalIndent(rec, "", "  ")
				if err != nil {
					return nil, rep, fmt.Errorf("sanitize: re-marshal %s: %w", p, err)
				}
				kept[p] = out
				rep.RoutingRewritten = append(rep.RoutingRewritten, base)
			}
		case strings.HasPrefix(base, "API."):
			var rec struct {
				ID         string `json:"id"`
				APIName    string `json:"apiName"`
				APIVersion string `json:"apiVersion"`
				IsActive   bool   `json:"isActive"`
			}
			if err := json.Unmarshal(kept[p], &rec); err != nil || rec.ID == "" {
				continue
			}
			rep.APIs = append(rep.APIs, ArchiveAPIInfo{ID: rec.ID, Name: rec.APIName, Version: rec.APIVersion, IsActive: rec.IsActive})
		}
	}
	if len(rep.APIs) == 0 {
		return nil, rep, fmt.Errorf("sanitize: no API record found in API/")
	}
	for _, api := range rep.APIs {
		if !api.IsActive {
			return nil, rep, fmt.Errorf("sanitize: ARCHIVE_INACTIVE — %s v%s carries isActive:false; importing it would DEACTIVATE the target API (proven trap, ADR-079). Re-export from the active state", api.Name, api.Version)
		}
	}

	// re-zip, entries at the root exactly like the product's own export.
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	w, err := zw.Create("APIGatewayAssets.acdl")
	if err == nil {
		_, err = w.Write(acdl)
	}
	if err != nil {
		return nil, rep, fmt.Errorf("sanitize: write acdl: %w", err)
	}
	for _, p := range paths {
		w, err := zw.Create(p)
		if err == nil {
			_, err = w.Write(kept[p])
		}
		if err != nil {
			return nil, rep, fmt.Errorf("sanitize: write %s: %w", p, err)
		}
	}
	if err := zw.Close(); err != nil {
		return nil, rep, fmt.Errorf("sanitize: close zip: %w", err)
	}
	return buf.Bytes(), rep, nil
}

// acdlTypes lists the distinct asset-type prefixes declared in the manifest.
func acdlTypes(acdl string) []string {
	seen := map[string]bool{}
	for _, m := range regexp.MustCompile(`<asset name="([A-Za-z]+)\.`).FindAllStringSubmatch(acdl, -1) {
		seen[m[1]] = true
	}
	out := make([]string, 0, len(seen))
	for t := range seen {
		out = append(out, t)
	}
	sort.Strings(out)
	return out
}

// ArchiveTaintCheck fails closed when the zip still carries Alias/ or
// PassmanData/ entries: imported on a VIRGIN gateway those would SEED the
// source env's backend value (or ship an encrypted secret) — the artifact must
// be sanitized first.
func ArchiveTaintCheck(zipBytes []byte) error {
	zr, err := zip.NewReader(bytes.NewReader(zipBytes), int64(len(zipBytes)))
	if err != nil {
		return fmt.Errorf("archive: not a zip: %w", err)
	}
	for _, f := range zr.File {
		if strings.HasPrefix(f.Name, "Alias/") || strings.HasPrefix(f.Name, "PassmanData/") {
			return fmt.Errorf("archive: ARCHIVE_TAINTED — %s embedded (per-env value / encrypted secret must never travel; re-export through the sanitizer, ADR-079)", f.Name)
		}
	}
	return nil
}

// ImportArchive uploads the zip with the given overwrite scope and returns the
// flattened ArchiveResult rows. Fail-closed guards:
//   - overwrite must be scoped: "*" or any list containing "aliases" would
//     clobber the target env's alias values (proven);
//   - the archive must pass ArchiveTaintCheck;
//   - every row must be Success (an unexpected conflict/dependency failure is
//     an error, with the row's explanation surfaced).
func (a *Adapter) ImportArchive(ctx context.Context, zipBytes []byte, overwrite string) ([]ImportRow, error) {
	if overwrite == "" {
		overwrite = DefaultOverwrite
	}
	if overwrite == "*" {
		return nil, fmt.Errorf("archive import: overwrite=* would clobber the env-local alias values (proven trap, ADR-079) — use %q", DefaultOverwrite)
	}
	for _, t := range strings.Split(overwrite, ",") {
		if strings.TrimSpace(t) == "aliases" {
			return nil, fmt.Errorf("archive import: overwrite must NOT cover aliases (per-env values, ADR-079) — got %q", overwrite)
		}
	}
	if err := ArchiveTaintCheck(zipBytes); err != nil {
		return nil, err
	}

	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	part, err := mw.CreateFormFile("file", "archive.zip")
	if err == nil {
		_, err = part.Write(zipBytes)
	}
	if err == nil {
		err = mw.Close()
	}
	if err != nil {
		return nil, fmt.Errorf("archive import: build multipart: %w", err)
	}

	url := a.adminPath("/archive?overwrite=" + overwrite)
	headers := a.authHeaders()
	headers["Accept"] = "application/json"
	headers["Content-Type"] = mw.FormDataContentType()
	code, raw, err := httpx.Do(ctx, a.http, http.MethodPost, url, headers, &body)
	if err != nil {
		return nil, fmt.Errorf("archive import: %w", err)
	}
	if code != http.StatusOK && code != http.StatusCreated {
		return nil, fmt.Errorf("archive import: expected 200/201, got %d: %s", code, truncate(raw, 300))
	}

	var resp struct {
		ArchiveResult []map[string]ImportRow `json:"ArchiveResult"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return nil, fmt.Errorf("archive import: parse ArchiveResult: %w (%s)", err, truncate(raw, 300))
	}
	rows := make([]ImportRow, 0, len(resp.ArchiveResult))
	for _, entry := range resp.ArchiveResult {
		for typ, row := range entry {
			row.Type = typ
			rows = append(rows, row)
		}
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("archive import: empty ArchiveResult — the archive declared nothing importable: %s", truncate(raw, 300))
	}
	var failed []string
	for _, r := range rows {
		if r.Status != "Success" {
			failed = append(failed, fmt.Sprintf("%s %s (%s): %s", r.Type, r.Name, r.ID, r.Explanation))
		}
	}
	if len(failed) > 0 {
		return rows, fmt.Errorf("archive import: IMPORT_FAILED — %s", strings.Join(failed, " ; "))
	}
	return rows, nil
}

// VerifyAPIActive re-reads the API by guid and fails closed unless it is
// present AND active — the isActive trap surfaces here on the import side.
func (a *Adapter) VerifyAPIActive(ctx context.Context, apiID string) (wmAPI, error) {
	rec, err := a.getAPI(ctx, apiID)
	if err != nil {
		return wmAPI{}, fmt.Errorf("archive verify: %w", err)
	}
	if !rec.IsActive {
		return rec, fmt.Errorf("archive verify: IMPORT_UNCONFIRMED — %s v%s (guid %s) is INACTIVE after import (isActive trap, ADR-079): the data plane is DOWN; re-export from the active state and re-import", rec.APIName, rec.APIVersion, apiID)
	}
	return rec, nil
}

// InvokeSmoke GETs a data-plane path (e.g. "/my-api/1.0.0/ping", relative to
// the /gateway data prefix — same semantics as the Ansible role's smoke_path)
// and fails closed on any non-200 — the post-import smoke test.
func (a *Adapter) InvokeSmoke(ctx context.Context, path string) error {
	url := a.gatewayURL + dataPrefix + path
	code, raw, err := httpx.Do(ctx, a.http, http.MethodGet, url, nil, nil)
	if err != nil {
		return fmt.Errorf("smoke %s: %w", path, err)
	}
	if code != http.StatusOK {
		return fmt.Errorf("smoke %s: expected 200, got %d: %s", path, code, truncate(raw, 200))
	}
	return nil
}

// --- parameterised alias-first primitives (the promote command's toolbox) ----

// EnsureEndpointAliasValue converges the endpoint alias NAME onto url:
// absent -> POST (NAKED body, exact endPointURI casing); present -> PUT the
// read-back record with only endPointURI overwritten. NEVER delete/recreate
// (the ${alias} binding is resolved name->id at deploy time — a recreated id
// breaks routing durably). Read-back asserted, fail closed.
func (a *Adapter) EnsureEndpointAliasValue(ctx context.Context, name, url string) error {
	if name == "" || url == "" {
		return fmt.Errorf("endpoint alias: name and url are both required (got name=%q url set=%t)", name, url != "")
	}
	aliases, err := a.listAliases(ctx)
	if err != nil {
		return fmt.Errorf("endpoint alias: %w", err)
	}
	for _, al := range aliases {
		if al.Name != name {
			continue
		}
		if got, _ := al.Raw["endPointURI"].(string); got != url {
			al.Raw["endPointURI"] = url
			code, raw, perr := a.sendJSON(ctx, http.MethodPut, a.adminPath("/alias/"+al.ID), al.Raw)
			if perr != nil {
				return fmt.Errorf("endpoint alias %q: %w", name, perr)
			}
			if code != http.StatusOK && code != http.StatusCreated {
				return fmt.Errorf("endpoint alias %q: PUT expected 200/201, got %d: %s", name, code, truncate(raw, 300))
			}
		}
		return a.assertEndpointAliasValue(ctx, al.ID, name, url)
	}
	body := map[string]any{
		"name":                  name,
		"description":           "labctl promote: per-env backend endpoint alias (ADR-079, alias-first)",
		"type":                  "endpoint",
		"endPointURI":           url,
		"optimizationTechnique": "None",
		"passSecurityHeaders":   true,
	}
	code, raw, err := a.sendJSON(ctx, http.MethodPost, a.adminPath("/alias"), body)
	if err != nil {
		return fmt.Errorf("endpoint alias %q: %w", name, err)
	}
	if code != http.StatusCreated && code != http.StatusOK {
		return fmt.Errorf("endpoint alias %q: POST expected 200/201, got %d: %s", name, code, truncate(raw, 300))
	}
	id := parseAliasID(raw)
	if id == "" {
		id = a.lookupAliasID(ctx, name)
	}
	if id == "" {
		return fmt.Errorf("endpoint alias %q: no id in response and name lookup failed", name)
	}
	return a.assertEndpointAliasValue(ctx, id, name, url)
}

// assertEndpointAliasValue proves endPointURI persisted (the casing trap:
// wrong-cased fields are dropped silently by this surface).
func (a *Adapter) assertEndpointAliasValue(ctx context.Context, aliasID, name, want string) error {
	rec, err := a.getAliasRecord(ctx, aliasID)
	if err != nil {
		return fmt.Errorf("endpoint alias %q: read-back: %w", name, err)
	}
	if got, _ := rec["endPointURI"].(string); got != want {
		return fmt.Errorf("endpoint alias %q: endPointURI came back %q, want %q — the write did not persist (endPointURI casing?)", name, got, want)
	}
	return nil
}

// VerifyEndpointAliasValue re-reads the env-local backend alias WITHOUT
// writing: the verify half of the alias-first contract (mirror of the Ansible
// role's tasks/verify.yml ALIAS_DRIFT check — the G8 replayable gate).
func (a *Adapter) VerifyEndpointAliasValue(ctx context.Context, name, want string) error {
	aliases, err := a.listAliases(ctx)
	if err != nil {
		return err
	}
	for _, al := range aliases {
		if al.Name != name {
			continue
		}
		got, _ := al.Raw["endPointURI"].(string)
		if got != want {
			return fmt.Errorf("verify: ALIAS_DRIFT — alias %q carries %q, the env declares %q", name, got, want)
		}
		return nil
	}
	return fmt.Errorf("verify: ALIAS_MISSING — endpoint alias %q not found", name)
}

// EnsureCredentialAliasValue converges the httpTransportSecurityAlias NAME
// WRITE-ALWAYS (the stored password reads back masked — the only sound
// convergence is to re-emit the desired credentials on every apply).
// authType HTTP_BASIC and NTLM are spike-pinned (NTLM = same
// httpAuthCredentials container + domain); anything else is refused until its
// credential container is pinned by a spike — never a guessed shape.
// passwordB64 is the base64 of the real password (MANDATORY wire format).
func (a *Adapter) EnsureCredentialAliasValue(ctx context.Context, name, authType, user, passwordB64, domain string) error {
	if authType == "" {
		authType = "HTTP_BASIC"
	}
	if authType != "HTTP_BASIC" && authType != "NTLM" {
		return fmt.Errorf("credential alias %q: CRED_TYPE_UNSUPPORTED — authType %q (supported: HTTP_BASIC, NTLM; KERBEROS/OAUTH2/JWT need a shape spike first, ADR-079)", name, authType)
	}
	if authType == "NTLM" && domain == "" {
		return fmt.Errorf("credential alias %q: NTLM requires a domain", name)
	}
	if name == "" || user == "" || passwordB64 == "" {
		return fmt.Errorf("credential alias: name, user and password are required (name=%q user set=%t password set=%t)", name, user != "", passwordB64 != "")
	}
	creds := map[string]any{"userName": user, "password": passwordB64}
	if domain != "" {
		creds["domain"] = domain
	}
	aliases, err := a.listAliases(ctx)
	if err != nil {
		return fmt.Errorf("credential alias %q: %w", name, err)
	}
	for _, al := range aliases {
		if al.Name != name {
			continue
		}
		al.Raw["authType"] = authType
		al.Raw["httpAuthCredentials"] = creds
		code, raw, perr := a.sendJSON(ctx, http.MethodPut, a.adminPath("/alias/"+al.ID), al.Raw)
		if perr != nil {
			return fmt.Errorf("credential alias %q: %w", name, perr)
		}
		if code != http.StatusOK && code != http.StatusCreated {
			return fmt.Errorf("credential alias %q: PUT expected 200/201, got %d: %s", name, code, truncate(raw, 300))
		}
		return a.assertCredentialAliasValue(ctx, al.ID, name, authType, user, domain)
	}
	body := map[string]any{
		"name":                name,
		"description":         "labctl promote: per-env backend credentials (Vault, ADR-079)",
		"type":                "httpTransportSecurityAlias",
		"authType":            authType,
		"authMode":            "NEW",
		"httpAuthCredentials": creds,
	}
	code, raw, err := a.sendJSON(ctx, http.MethodPost, a.adminPath("/alias"), body)
	if err != nil {
		return fmt.Errorf("credential alias %q: %w", name, err)
	}
	if code != http.StatusCreated && code != http.StatusOK {
		return fmt.Errorf("credential alias %q: POST expected 200/201, got %d: %s", name, code, truncate(raw, 300))
	}
	id := parseAliasID(raw)
	if id == "" {
		id = a.lookupAliasID(ctx, name)
	}
	if id == "" {
		return fmt.Errorf("credential alias %q: no id in response and name lookup failed", name)
	}
	return a.assertCredentialAliasValue(ctx, id, name, authType, user, domain)
}

// assertCredentialAliasValue proves userName + authType (+domain) persisted.
// The password is NOT asserted (masked on read-back, by design — write-always).
func (a *Adapter) assertCredentialAliasValue(ctx context.Context, aliasID, name, authType, user, domain string) error {
	rec, err := a.getAliasRecord(ctx, aliasID)
	if err != nil {
		return fmt.Errorf("credential alias %q: read-back: %w", name, err)
	}
	if got, _ := rec["authType"].(string); got != authType {
		return fmt.Errorf("credential alias %q: authType came back %q, want %q", name, got, authType)
	}
	creds, _ := rec["httpAuthCredentials"].(map[string]any)
	if got, _ := creds["userName"].(string); got != user {
		return fmt.Errorf("credential alias %q: userName came back %q, want %q", name, got, user)
	}
	if domain != "" {
		if got, _ := creds["domain"].(string); got != domain {
			return fmt.Errorf("credential alias %q: domain came back %q, want %q", name, got, domain)
		}
	}
	return nil
}

// EnsureGenericAlias converges a SECRET-FREE alias declaratively: the record
// fields are merged over the read-back (PUT) or posted naked (POST), then
// asserted field by field. Secrets belong in EnsureCredentialAliasValue.
func (a *Adapter) EnsureGenericAlias(ctx context.Context, name string, record map[string]any) error {
	if name == "" || len(record) == 0 {
		return fmt.Errorf("generic alias: name and a non-empty record are required")
	}
	aliases, err := a.listAliases(ctx)
	if err != nil {
		return fmt.Errorf("generic alias %q: %w", name, err)
	}
	var id string
	for _, al := range aliases {
		if al.Name != name {
			continue
		}
		id = al.ID
		for k, v := range record {
			al.Raw[k] = v
		}
		code, raw, perr := a.sendJSON(ctx, http.MethodPut, a.adminPath("/alias/"+id), al.Raw)
		if perr != nil {
			return fmt.Errorf("generic alias %q: %w", name, perr)
		}
		if code != http.StatusOK && code != http.StatusCreated {
			return fmt.Errorf("generic alias %q: PUT expected 200/201, got %d: %s", name, code, truncate(raw, 300))
		}
		break
	}
	if id == "" {
		body := map[string]any{"name": name}
		for k, v := range record {
			body[k] = v
		}
		code, raw, err := a.sendJSON(ctx, http.MethodPost, a.adminPath("/alias"), body)
		if err != nil {
			return fmt.Errorf("generic alias %q: %w", name, err)
		}
		if code != http.StatusCreated && code != http.StatusOK {
			return fmt.Errorf("generic alias %q: POST expected 200/201, got %d: %s", name, code, truncate(raw, 300))
		}
		if id = parseAliasID(raw); id == "" {
			id = a.lookupAliasID(ctx, name)
		}
		if id == "" {
			return fmt.Errorf("generic alias %q: no id in response and name lookup failed", name)
		}
	}
	rec, err := a.getAliasRecord(ctx, id)
	if err != nil {
		return fmt.Errorf("generic alias %q: read-back: %w", name, err)
	}
	for k, want := range record {
		if got := rec[k]; fmt.Sprint(got) != fmt.Sprint(want) {
			return fmt.Errorf("generic alias %q: field %q came back %v, want %v (silent-drop surface — check the field casing)", name, k, got, want)
		}
	}
	return nil
}

// EnsureScopeMappingPerAPI converges the PER-API+VERSION scope mapping (the
// client model, ADR-079): ONE mapping per API — apiScopes is REPLACED with
// [apiID] (no multi-API accumulation to preserve: that shared-state model is
// exactly what this replaces). The mapping references the auth server BY NAME
// (env-local, must pre-exist — alias-first applies to the AS too) and the API
// by GUID, which the archive keeps stable: posed once it stays valid across
// every redeploy. Scope mappings do NOT travel in archives (proven both ways).
func (a *Adapter) EnsureScopeMappingPerAPI(ctx context.Context, mappingName, asAlias, externalScope, audience, apiID string) error {
	if mappingName == "" || asAlias == "" || externalScope == "" || apiID == "" {
		return fmt.Errorf("scope mapping: mappingName, asAlias, externalScope and apiID are all required")
	}
	// alias-first for the AS: a mapping onto a ghost auth server would be a
	// half-open gate — fail closed.
	aliases, err := a.listAliases(ctx)
	if err != nil {
		return fmt.Errorf("scope mapping %q: %w", mappingName, err)
	}
	found := false
	for _, al := range aliases {
		if al.Name == asAlias {
			found = true
			break
		}
	}
	if !found {
		return fmt.Errorf("scope mapping %q: SCOPE_AS_MISSING — auth-server alias %q does not exist on this env; pose it first (alias-first)", mappingName, asAlias)
	}

	required := []any{map[string]any{"authServerAlias": asAlias, "scopeName": externalScope}}
	scopes, err := a.listScopes(ctx)
	if err != nil {
		return fmt.Errorf("scope mapping %q: %w", mappingName, err)
	}
	for _, sc := range scopes {
		if name, _ := sc["scopeName"].(string); name != mappingName {
			continue
		}
		id, _ := sc["id"].(string)
		if id == "" {
			return fmt.Errorf("scope mapping %q: record has no id", mappingName)
		}
		sc["apiScopes"] = []any{apiID}
		sc["requiredAuthScopes"] = required
		sc["audience"] = audience
		code, raw, perr := a.sendJSON(ctx, http.MethodPut, a.adminPath("/scopes/"+id), sc)
		if perr != nil {
			return fmt.Errorf("scope mapping %q: %w", mappingName, perr)
		}
		if code != http.StatusOK && code != http.StatusCreated {
			return fmt.Errorf("scope mapping %q: PUT expected 200/201, got %d: %s", mappingName, code, truncate(raw, 300))
		}
		return a.assertScopeMappingBinds(ctx, mappingName, apiID)
	}
	body := map[string]any{
		"scopeName":          mappingName,
		"scopeDescription":   "labctl promote: per-API scope mapping (ADR-079)",
		"audience":           audience,
		"apiScopes":          []string{apiID},
		"requiredAuthScopes": required,
	}
	code, raw, err := a.sendJSON(ctx, http.MethodPost, a.adminPath("/scopes"), body)
	if err != nil {
		return fmt.Errorf("scope mapping %q: %w", mappingName, err)
	}
	if code != http.StatusCreated && code != http.StatusOK {
		return fmt.Errorf("scope mapping %q: POST expected 200/201, got %d: %s", mappingName, code, truncate(raw, 300))
	}
	return a.assertScopeMappingBinds(ctx, mappingName, apiID)
}

// assertScopeMappingBinds proves the mapping exists and lists apiID.
func (a *Adapter) assertScopeMappingBinds(ctx context.Context, mappingName, apiID string) error {
	scopes, err := a.listScopes(ctx)
	if err != nil {
		return fmt.Errorf("scope mapping %q: read-back: %w", mappingName, err)
	}
	for _, sc := range scopes {
		if name, _ := sc["scopeName"].(string); name != mappingName {
			continue
		}
		if scopeBindsAPI(sc, apiID) {
			return nil
		}
		return fmt.Errorf("scope mapping %q: read-back does not bind API %s", mappingName, apiID)
	}
	return fmt.Errorf("scope mapping %q: absent after write", mappingName)
}
