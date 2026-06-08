package webmethods

import (
	"context"
	"fmt"
	"net/http"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

// apiRecord is the webMethods API object as serialized by /rest/apigateway/apis.
// The json tags are the gateway's exact camelCase keys — apiId/apiName/...,
// NOT id/name/version. Field-name drift here is a silent-failure trap.
type apiRecord struct {
	APIID      string `json:"apiId,omitempty"`
	APIName    string `json:"apiName"`
	APIVersion string `json:"apiVersion,omitempty"`
	BasePath   string `json:"basePath"`
	BackendURL string `json:"backendUrl,omitempty"`
	CreatedAt  string `json:"createdAt,omitempty"`
}

// apiListEnvelope wraps GET /rest/apigateway/apis. The list endpoint returns an
// envelope {"apis":[...],"count":n}, NOT a bare array — unmarshal accordingly.
type apiListEnvelope struct {
	APIs  []apiRecord `json:"apis"`
	Count int         `json:"count"`
}

// listAPIs fetches all published APIs (no server-side filtering in the mock).
func (a *Adapter) listAPIs(ctx context.Context) ([]apiRecord, error) {
	url := a.adminPath("/apis")
	var env apiListEnvelope
	if _, err := httpx.JSON(ctx, a.http, http.MethodGet, url, a.authHeaders(), nil, &env); err != nil {
		return nil, fmt.Errorf("webmethods list apis: %w", err)
	}
	return env.APIs, nil
}

// findByName returns the existing API with matching apiName, or false.
func findByName(apis []apiRecord, name string) (apiRecord, bool) {
	for _, api := range apis {
		if api.APIName == name {
			return api, true
		}
	}
	return apiRecord{}, false
}

// Publish materialises the NormalizedAPI on this gateway. webMethods has a flat,
// single-create model with no deploy lifecycle, so the algorithm is:
//
//  1. PREFLIGHT health (gate on isAlive==true) so we never half-publish.
//  2. IDEMPOTENCY: list APIs, find one with the same apiName. If it exists and
//     is identical (basePath+backendUrl), reuse it (Created=false, skip create).
//     If it exists but differs, DELETE it (the mock has no update endpoint), then
//     fall through to recreate.
//  3. CREATE: POST /apis -> 201, capture the server-assigned apiId.
//  4. READ-BACK: GET /apis/{apiId} -> 200 to confirm the create actually stuck
//     (a 404 here means the create silently failed to persist).
//
// The InvocationURL is gatewayUrl + "/gateway" + the canonical (server-normalized)
// basePath, which is the live data-plane URL a consumer calls.
func (a *Adapter) Publish(ctx context.Context, api *adapter.NormalizedAPI) (*adapter.PublishResult, error) {
	// 1. Preflight — fail fast with a clear per-gateway diagnostic.
	if err := a.Health(ctx); err != nil {
		return nil, fmt.Errorf("webmethods publish preflight: %w", err)
	}

	// 2. Idempotency. The mock has no update endpoint, so republish == DELETE+POST.
	existing, err := a.listAPIs(ctx)
	if err != nil {
		return nil, fmt.Errorf("webmethods publish: %w", err)
	}
	created := true
	if cur, ok := findByName(existing, api.Name); ok {
		if sameAPI(cur, api) {
			// Identical: reuse without touching the gateway.
			return a.publishResult(cur, false), nil
		}
		// Drifted: delete so we can recreate with the desired fields.
		if err := a.deleteAPI(ctx, cur.APIID); err != nil {
			return nil, fmt.Errorf("webmethods publish: delete stale api %q: %w", cur.APIID, err)
		}
	}

	// 3. Create. Required: apiName + basePath. Server normalizes basePath and
	//    assigns apiId; the API is live the instant this returns 201.
	body := apiRecord{
		APIName:    api.Name,
		APIVersion: api.Version,
		BasePath:   api.BasePath,
		BackendURL: api.BackendURL,
	}
	var createdRec apiRecord
	url := a.adminPath("/apis")
	code, err := httpx.JSON(ctx, a.http, http.MethodPost, url, a.authHeaders(), body, &createdRec)
	if err != nil {
		return nil, fmt.Errorf("webmethods publish: create api: %w", err)
	}
	if code != http.StatusCreated {
		return nil, fmt.Errorf("webmethods publish: create api %q expected 201, got %d", api.Name, code)
	}
	if createdRec.APIID == "" {
		return nil, fmt.Errorf("webmethods publish: create api %q returned no apiId", api.Name)
	}

	// 4. Read-back to confirm persistence (404 here => create silently failed).
	canonical, err := a.getAPI(ctx, createdRec.APIID)
	if err != nil {
		return nil, fmt.Errorf("webmethods publish: read-back api %q: %w", createdRec.APIID, err)
	}

	return a.publishResult(canonical, created), nil
}

// sameAPI reports whether an existing record already matches the desired intent.
// We compare the fields the adapter controls (basePath, backendUrl); apiId and
// createdAt are server-assigned. basePath is compared on the server-normalized
// value the gateway echoed, against the desired path normalized the same way.
func sameAPI(cur apiRecord, want *adapter.NormalizedAPI) bool {
	return cur.BasePath == normalizeBasePath(want.BasePath) &&
		cur.BackendURL == want.BackendURL
}

// normalizeBasePath mirrors the server's normalization ("/"+Trim(slashes)) so
// the idempotency comparison matches what the gateway stores.
func normalizeBasePath(p string) string {
	p = trimSlashes(p)
	if p == "" {
		return "/"
	}
	return "/" + p
}

func trimSlashes(s string) string {
	for len(s) > 0 && s[0] == '/' {
		s = s[1:]
	}
	for len(s) > 0 && s[len(s)-1] == '/' {
		s = s[:len(s)-1]
	}
	return s
}

// getAPI reads one API by its server-assigned apiId. A 404 surfaces as an error.
func (a *Adapter) getAPI(ctx context.Context, apiID string) (apiRecord, error) {
	url := a.adminPath("/apis/" + apiID)
	var rec apiRecord
	if _, err := httpx.JSON(ctx, a.http, http.MethodGet, url, a.authHeaders(), nil, &rec); err != nil {
		return apiRecord{}, fmt.Errorf("get api %q: %w", apiID, err)
	}
	return rec, nil
}

// deleteAPI removes an API (used for the delete+recreate republish path). The
// mock returns 204 on success and 404 if absent; we accept either as "gone".
func (a *Adapter) deleteAPI(ctx context.Context, apiID string) error {
	url := a.adminPath("/apis/" + apiID)
	code, raw, err := httpx.Do(ctx, a.http, http.MethodDelete, url, a.authHeaders(), nil)
	if err != nil {
		return fmt.Errorf("delete api %q: %w", apiID, err)
	}
	if code == http.StatusNoContent || code == http.StatusNotFound {
		return nil
	}
	return fmt.Errorf("delete api %q expected 204, got %d: %s", apiID, code, truncate(raw, 300))
}

// publishResult builds the uniform PublishResult from the canonical record.
// InvocationURL uses the server-normalized basePath so it always points at the
// real live route. There is no revision concept here (RevisionID stays empty);
// Published is true because POST/201 makes the API serve immediately.
func (a *Adapter) publishResult(rec apiRecord, created bool) *adapter.PublishResult {
	return &adapter.PublishResult{
		Gateway:       gatewayName,
		APIID:         rec.APIID,
		RevisionID:    "",
		InvocationURL: a.gatewayURL + dataPrefix + rec.BasePath,
		Published:     true,
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
