package webmethods

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

// wmAPI is the webMethods API object as serialized under the apiResponse
// envelopes. The json tags are the real product's exact keys: the record id is
// "id" (NOT apiId), names/versions are camelCase apiName/apiVersion.
type wmAPI struct {
	ID         string `json:"id"`
	APIName    string `json:"apiName"`
	APIVersion string `json:"apiVersion"`
	IsActive   bool   `json:"isActive"`
	Type       string `json:"type"`

	// Policies lists the ids of the policies attached to the API (the
	// SERVICE-scoped "Default Policy for API <name>" created on import lives
	// here) — the entry point of the inbound-auth IAM projection.
	Policies []string `json:"policies"`
}

// wmAPIWrapper handles the nested item shape {"api":{...},"responseStatus":"SUCCESS"}.
type wmAPIWrapper struct {
	API            wmAPI  `json:"api"`
	ResponseStatus string `json:"responseStatus"`
}

// wmAPIsResponse wraps GET /rest/apigateway/apis:
// {"apiResponse":[{...},...]} — an envelope, not a bare array. Items are kept
// raw because the gateway serves them either nested ({"api":{...}}) or flat.
type wmAPIsResponse struct {
	APIResponse []json.RawMessage `json:"apiResponse"`
}

// decodeAPIItem accepts both the nested wrapper and the flat record shape.
func decodeAPIItem(raw json.RawMessage) (wmAPI, bool) {
	var wrapper wmAPIWrapper
	if err := json.Unmarshal(raw, &wrapper); err == nil && wrapper.API.ID != "" {
		return wrapper.API, true
	}
	var flat wmAPI
	if err := json.Unmarshal(raw, &flat); err == nil && flat.ID != "" {
		return flat, true
	}
	return wmAPI{}, false
}

// listAPIs fetches all APIs known to the gateway.
func (a *Adapter) listAPIs(ctx context.Context) ([]wmAPI, error) {
	url := a.adminPath("/apis")
	var env wmAPIsResponse
	if _, err := httpx.JSON(ctx, a.http, http.MethodGet, url, a.authHeaders(), nil, &env); err != nil {
		return nil, fmt.Errorf("webmethods list apis: %w", err)
	}
	out := make([]wmAPI, 0, len(env.APIResponse))
	for _, raw := range env.APIResponse {
		if rec, ok := decodeAPIItem(raw); ok {
			out = append(out, rec)
		}
	}
	return out, nil
}

// findByNameVersion returns the existing API matching apiName AND apiVersion
// (the identity used for idempotent re-apply), or false.
func findByNameVersion(apis []wmAPI, name, version string) (wmAPI, bool) {
	for _, api := range apis {
		if api.APIName == name && api.APIVersion == version {
			return api, true
		}
	}
	return wmAPI{}, false
}

// findByName returns the first API matching apiName only — used by
// CreateConsumer to resolve the published apiId (version-agnostic).
func findByName(apis []wmAPI, name string) (wmAPI, bool) {
	for _, api := range apis {
		if api.APIName == name {
			return api, true
		}
	}
	return wmAPI{}, false
}

// latestByName returns the name-matching API with the HIGHEST apiVersion.
// webMethods refuses "create version" from any base but the newest ("Versioning
// is allowed only from latest version", proven live), so the version-mint
// fallback MUST select the latest existing version — the first name match in
// gateway list order is not guaranteed to be it.
//
// ⚠ DETTE CONNUE, MESURÉE LE 2026-08-05 (P3-T6) : « plus grand numéro » ≠
// « dernière version ». Sur la vraie 10.15 du lab, la lignée `accounts-read`
// porte 1.0.1 (créée le 07-04) et 1.0.0 (créée le 07-05, MINÉE DEPUIS 1.0.1) :
// la dernière version est donc 1.0.0, et ce tri choisirait 1.0.1 — d'où le
// HTTP 400 « Versioning is allowed only from latest version » que la fonction
// prétend éviter. GET /apis n'expose aucun marqueur de « dernière » (seul le
// GET unitaire porte `nextVersion`, null en bout de chaîne — piste non
// éprouvée, une seule lignée observée).
//
// Ce chemin reste VIVANT (scripts/demo-multienv.sh) et n'est PAS réécrit ici :
// deux voies de naissance d'une version coexistent donc, et seule l'autre est
// prouvée. La voie Ansible (rôle apim_publish_api, tasks/version.yml) refuse
// plutôt que de deviner — VERSION_BASE_AMBIGUE dès que la lignée compte
// plusieurs versions. Voir ansible/roles/apim_publish_api/README.md, section
// « Nouvelle version ».
func latestByName(apis []wmAPI, name string) (wmAPI, bool) {
	var latest wmAPI
	found := false
	for _, api := range apis {
		if api.APIName != name {
			continue
		}
		if !found || apiVersionLess(latest.APIVersion, api.APIVersion) {
			latest, found = api, true
		}
	}
	return latest, found
}

// apiVersionLess compares dotted versions component-wise and NUMERICALLY so
// 1.0.10 > 1.0.2 (a lexical sort gets that wrong). Non-numeric components fall
// back to a per-component string compare; a prefix-equal shorter version sorts
// lower. The UAC schema enforces X.Y.Z, so the numeric path is the norm.
func apiVersionLess(a, b string) bool {
	as, bs := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(as) && i < len(bs); i++ {
		ai, aerr := strconv.Atoi(as[i])
		bi, berr := strconv.Atoi(bs[i])
		if aerr != nil || berr != nil {
			if as[i] != bs[i] {
				return as[i] < bs[i]
			}
			continue
		}
		if ai != bi {
			return ai < bi
		}
	}
	return len(as) < len(bs)
}

// importPayload builds the real 10.15 import body:
// {apiName, apiVersion, type: "openapi"|"swagger", apiDefinition: <document>}.
// The OpenAPI document is converted to JSON, passed through the 10.15
// compatibility fixes (spec.go) and re-pointed at the authoritative backend.
func importPayload(api *adapter.NormalizedAPI) (map[string]any, error) {
	specJSON, err := specToJSON(api)
	if err != nil {
		return nil, err
	}
	specType := "openapi"
	if bytes.Contains(specJSON, []byte(`"swagger"`)) {
		specType = "swagger"
	}
	return map[string]any{
		"apiName":       sanitizeWMName(api.Name),
		"apiVersion":    api.Version,
		"type":          specType,
		"apiDefinition": json.RawMessage(specJSON),
	}, nil
}

// Publish materialises the NormalizedAPI on the real gateway. 10.15 has an
// import + separate-activation lifecycle, so the algorithm is:
//
//  1. PREFLIGHT health (reachability + Basic auth accepted) so we never
//     half-publish with a clear per-gateway diagnostic.
//  2. IDEMPOTENCY: list APIs, find one with the same apiName+apiVersion.
//     Found    -> PUT /apis/{id} with the import payload (update, Created=false).
//     Not found-> POST /apis (create, Created=true). A 409 on POST means a
//     concurrent/stale name conflict: re-list once and fall back to PUT on the
//     conflicting record (career C.2 pattern — one retry, no loop).
//  3. ACTIVATE: read back GET /apis/{id}; if isActive=false,
//     PUT /apis/{id}/activate, then confirm. Import alone does NOT serve
//     traffic on this product.
//
// The InvocationURL is the gateway's default execution endpoint for an
// imported API: gatewayUrl + /gateway/{apiName}/{apiVersion}.
func (a *Adapter) Publish(ctx context.Context, api *adapter.NormalizedAPI) (*adapter.PublishResult, error) {
	// 1. Preflight — fail fast with a clear per-gateway diagnostic.
	if err := a.Health(ctx); err != nil {
		return nil, fmt.Errorf("webmethods publish preflight: %w", err)
	}

	payload, err := importPayload(api)
	if err != nil {
		return nil, fmt.Errorf("webmethods publish: %w", err)
	}
	wmName := sanitizeWMName(api.Name)

	// 2. Idempotency: find by apiName+apiVersion, PUT update when present.
	existing, err := a.listAPIs(ctx)
	if err != nil {
		return nil, fmt.Errorf("webmethods publish: %w", err)
	}

	var apiID string
	created := false
	if cur, ok := findByNameVersion(existing, wmName, api.Version); ok {
		if err := a.updateAPI(ctx, cur.ID, payload); err != nil {
			return nil, fmt.Errorf("webmethods publish: update api %q (%s): %w", wmName, cur.ID, err)
		}
		apiID = cur.ID
	} else {
		apiID, created, err = a.createAPI(ctx, wmName, payload)
		if err != nil {
			return nil, fmt.Errorf("webmethods publish: %w", err)
		}
	}

	// 3. Activate (separate lifecycle step on the real product) + read-back.
	canonical, err := a.ensureActive(ctx, apiID, wmName)
	if err != nil {
		return nil, fmt.Errorf("webmethods publish: %w", err)
	}

	// 4. Inbound auth projection (optional inboundAuth manifest block): alias
	// + Identify & Authorize action + IAM stage on the API's policy. Runs
	// AFTER the import/update on purpose — a re-import may touch the policy,
	// and this step re-reads and converges whatever state it left. No-op when
	// the manifest carries no inboundAuth (zero extra calls).
	if err := a.ensureInboundAuth(ctx, canonical.ID, canonical.APIName, canonical.APIVersion); err != nil {
		return nil, fmt.Errorf("webmethods publish: %w", err)
	}

	// 5. Routing-by-alias projection (optional routing manifest block): endpoint
	// alias (+ credential alias) and the straightThroughRouting action re-pointed
	// at ${alias}/${sys:resource_path}. NOTE: injectBackendServer (spec.go) stays
	// applied even in this mode — the import NEEDS a real servers[] entry to
	// derive a native endpoint — but the EFFECTIVE routing then comes from the
	// alias (resolved PER REQUEST), making the backend an env-switchable value.
	// No-op when the manifest carries no routing block (zero extra calls).
	if err := a.ensureRouting(ctx, canonical.ID, canonical.APIName); err != nil {
		return nil, fmt.Errorf("webmethods publish: %w", err)
	}

	// 6. Rate-limit projection (optional rateLimit manifest block): a "Traffic
	// Optimization" throttle action on the LMT stage, rejecting requests over the
	// limit with 429. Runs AFTER inbound auth (its dependentActions=[evaluatePolicy]
	// need the IAM action present). No-op when the manifest carries no rateLimit.
	if err := a.ensureThrottle(ctx, canonical.ID, canonical.APIName); err != nil {
		return nil, fmt.Errorf("webmethods publish: %w", err)
	}

	// 7. Transport protocol (optional transportProtocol manifest block): pin the
	// API's entryProtocolPolicy (e.g. https-only for end-to-end mTLS on a
	// clientAuth=require listener). No-op when the manifest leaves it unset.
	if err := a.ensureTransportProtocol(ctx, canonical.ID); err != nil {
		return nil, fmt.Errorf("webmethods publish: %w", err)
	}

	return a.publishResult(canonical, created), nil
}

// createAPI POSTs the import payload and reports (id, created). On a name
// conflict (409, or the trial's 400 "API with apiName … already exists") it
// re-lists ONCE and converges:
//   - same name+version exists -> PUT on that record (created=false);
//   - name exists under ANOTHER version -> le produit REFUSE un POST frais ET
//     le changement de version in-place au PUT (400, prouvé live en déployant
//     v1.0.1 par-dessus v1.0.0 — stoa-prod-deploy #3). Le chemin natif wM est
//     l'endpoint de VERSIONING : POST /apis/{id}/versions {newApiVersion,
//     retainApplications} mint un NOUVEAU record (policies/applications
//     clonées), puis le payload d'import est PUT dessus pour servir NOTRE
//     contrat (le clone copie l'ancienne spec). Les deux versions coexistent
//     sur la gateway — Git (deploy.{env}.yaml) reste l'autorité sur la version
//     qu'un env pin.
//
// A conflict with no matching record is a ghost conflict and surfaces as an
// error (career C.2 semantics — one retry, no loop).
func (a *Adapter) createAPI(ctx context.Context, wmName string, payload map[string]any) (string, bool, error) {
	url := a.adminPath("/apis")
	code, raw, err := a.sendJSON(ctx, http.MethodPost, url, payload)
	if err != nil {
		return "", false, fmt.Errorf("create api %q: %w", wmName, err)
	}
	nameConflict := code == http.StatusConflict ||
		(code == http.StatusBadRequest && bytes.Contains(raw, []byte("already exists")))
	if nameConflict {
		refreshed, lerr := a.listAPIs(ctx)
		if lerr != nil {
			return "", false, fmt.Errorf("create api %q: %d conflict and re-list failed: %w", wmName, code, lerr)
		}
		wantVersion, _ := payload["apiVersion"].(string)
		if cur, ok := findByNameVersion(refreshed, wmName, wantVersion); ok {
			if uerr := a.updateAPI(ctx, cur.ID, payload); uerr != nil {
				return "", false, fmt.Errorf("create api %q: conflict→PUT fallback on %s: %w", wmName, cur.ID, uerr)
			}
			return cur.ID, false, nil
		}
		// Mint the new version from the LATEST existing version — wM rejects
		// versioning from any other base ("only from latest version").
		cur, ok := latestByName(refreshed, wmName)
		if !ok {
			return "", false, fmt.Errorf("create api %q: %d conflict but API absent from re-list (ghost conflict): %s", wmName, code, truncate(raw, 300))
		}
		newID, verr := a.createVersion(ctx, cur.ID, wmName, wantVersion)
		if verr != nil {
			return "", false, verr
		}
		if uerr := a.updateAPI(ctx, newID, payload); uerr != nil {
			return "", false, fmt.Errorf("create api %q: version %s mintée (%s) mais PUT d'import KO: %w", wmName, wantVersion, newID, uerr)
		}
		return newID, true, nil
	}
	if code != http.StatusCreated && code != http.StatusOK {
		return "", false, fmt.Errorf("create api %q: expected 200/201, got %d: %s", wmName, code, truncate(raw, 300))
	}
	id := parseCreateResponseID(raw)
	if id == "" {
		return "", false, fmt.Errorf("create api %q: response carries no api id: %s", wmName, truncate(raw, 300))
	}
	return id, true, nil
}

// createVersion mints a NEW version record of an existing API via the native
// versioning endpoint (POST /apis/{id}/versions, 201 — vérifié live sur le
// trial). retainApplications garde les souscriptions des consumers sur la
// nouvelle version (le modèle ADR-072 : l'identité consumer est UNE, les
// versions sont des déploiements).
func (a *Adapter) createVersion(ctx context.Context, baseID, wmName, newVersion string) (string, error) {
	if newVersion == "" {
		return "", fmt.Errorf("create version of %q: empty target apiVersion", wmName)
	}
	url := a.adminPath("/apis/" + baseID + "/versions")
	code, raw, err := a.sendJSON(ctx, http.MethodPost, url, map[string]any{
		"newApiVersion":      newVersion,
		"retainApplications": true,
	})
	if err != nil {
		return "", fmt.Errorf("create version %q of %q: %w", newVersion, wmName, err)
	}
	if code != http.StatusCreated && code != http.StatusOK {
		return "", fmt.Errorf("create version %q of %q: POST %s expected 200/201, got %d: %s", newVersion, wmName, url, code, truncate(raw, 300))
	}
	id := parseCreateResponseID(raw)
	if id == "" {
		return "", fmt.Errorf("create version %q of %q: response carries no api id: %s", newVersion, wmName, truncate(raw, 300))
	}
	return id, nil
}

// updateAPI PUTs the import payload onto an existing record. 200/201 are
// success. Any other status surfaces with the (truncated) body so the failure
// is actionable.
func (a *Adapter) updateAPI(ctx context.Context, apiID string, payload map[string]any) error {
	url := a.adminPath("/apis/" + apiID)
	code, raw, err := a.sendJSON(ctx, http.MethodPut, url, payload)
	if err != nil {
		return err
	}
	if code != http.StatusOK && code != http.StatusCreated {
		return fmt.Errorf("PUT %s expected 200/201, got %d: %s", url, code, truncate(raw, 300))
	}
	return nil
}

// sendJSON marshals payload and issues one request, returning status + raw
// body without treating non-2xx as an error — callers branch on the code
// (409 fallback, actionable messages).
func (a *Adapter) sendJSON(ctx context.Context, method, url string, payload map[string]any) (int, []byte, error) {
	data, err := json.Marshal(payload)
	if err != nil {
		return 0, nil, fmt.Errorf("marshal payload for %s %s: %w", method, url, err)
	}
	headers := a.authHeaders()
	headers["Content-Type"] = "application/json"
	headers["Accept"] = "application/json"
	return httpx.Do(ctx, a.http, method, url, headers, bytes.NewReader(data))
}

// parseCreateResponseID extracts the API id from a POST /apis response body.
// Handles both the nested ({"apiResponse":{"api":{"id":...}}}) and flat
// (top-level {"id":...}) shapes the product serves.
func parseCreateResponseID(respBody []byte) string {
	var createResp struct {
		APIResponse struct {
			API struct {
				ID string `json:"id"`
			} `json:"api"`
		} `json:"apiResponse"`
		ID string `json:"id"`
	}
	if err := json.Unmarshal(respBody, &createResp); err != nil {
		return ""
	}
	if createResp.APIResponse.API.ID != "" {
		return createResp.APIResponse.API.ID
	}
	return createResp.ID
}

// getAPI reads one API by id. The single-record envelope is
// {"apiResponse":{"api":{...}}}; a flat record is also accepted.
func (a *Adapter) getAPI(ctx context.Context, apiID string) (wmAPI, error) {
	url := a.adminPath("/apis/" + apiID)
	var raw json.RawMessage
	if _, err := httpx.JSON(ctx, a.http, http.MethodGet, url, a.authHeaders(), nil, &raw); err != nil {
		return wmAPI{}, fmt.Errorf("get api %q: %w", apiID, err)
	}
	var nested struct {
		APIResponse wmAPIWrapper `json:"apiResponse"`
	}
	if err := json.Unmarshal(raw, &nested); err == nil && nested.APIResponse.API.ID != "" {
		return nested.APIResponse.API, nil
	}
	if rec, ok := decodeAPIItem(raw); ok {
		return rec, nil
	}
	return wmAPI{}, fmt.Errorf("get api %q: unrecognized response shape: %s", apiID, truncate(raw, 300))
}

// ensureActive reads the record back and activates it when isActive=false
// (PUT /apis/{id}/activate, separate lifecycle step), then re-reads to return
// the canonical post-activation record. Already-active records are left
// untouched so re-apply stays idempotent.
func (a *Adapter) ensureActive(ctx context.Context, apiID, wmName string) (wmAPI, error) {
	rec, err := a.getAPI(ctx, apiID)
	if err != nil {
		return wmAPI{}, fmt.Errorf("read-back %q: %w", wmName, err)
	}
	if rec.IsActive {
		return rec, nil
	}
	url := a.adminPath("/apis/" + apiID + "/activate")
	code, raw, err := httpx.Do(ctx, a.http, http.MethodPut, url, a.authHeaders(), nil)
	if err != nil {
		return wmAPI{}, fmt.Errorf("activate %q: %w", wmName, err)
	}
	if code != http.StatusOK && code != http.StatusNoContent {
		return wmAPI{}, fmt.Errorf("activate %q: PUT %s expected 200/204, got %d: %s", wmName, url, code, truncate(raw, 300))
	}
	after, err := a.getAPI(ctx, apiID)
	if err != nil {
		return wmAPI{}, fmt.Errorf("post-activate read-back %q: %w", wmName, err)
	}
	if !after.IsActive {
		return wmAPI{}, fmt.Errorf("activate %q: gateway still reports isActive=false after activate", wmName)
	}
	return after, nil
}

// publishResult builds the uniform PublishResult from the canonical record.
// The real product has no revision lifecycle (RevisionID stays empty);
// Published mirrors the activation state. InvocationURL is the default
// execution endpoint of an imported API: /gateway/{apiName}/{apiVersion}.
func (a *Adapter) publishResult(rec wmAPI, created bool) *adapter.PublishResult {
	return &adapter.PublishResult{
		Gateway:       gatewayName,
		APIID:         rec.ID,
		RevisionID:    "",
		InvocationURL: a.gatewayURL + dataPrefix + "/" + rec.APIName + "/" + rec.APIVersion,
		Published:     rec.IsActive,
		Created:       created,
	}
}

// truncate shortens a body for error messages (mirrors httpx behaviour).
func truncate(b []byte, n int) string {
	if len(b) <= n {
		return string(b)
	}
	return string(b[:n]) + "…"
}
