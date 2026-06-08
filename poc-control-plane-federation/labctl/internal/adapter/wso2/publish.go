package wso2

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"mime/multipart"
	"net/url"
	"path/filepath"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

// --- Publisher REST API DTOs -------------------------------------------------

// apiSummary is one element of a Publisher /apis search/list response.
type apiSummary struct {
	ID            string `json:"id"`
	Name          string `json:"name"`
	Version       string `json:"version"`
	Context       string `json:"context"`
	LifeCycleStat string `json:"lifeCycleStatus"`
}

type apiSearchResponse struct {
	Count int          `json:"count"`
	List  []apiSummary `json:"list"`
}

// importResponse is the body returned by import-openapi (201).
type importResponse struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Version string `json:"version"`
	Context string `json:"context"`
}

// revisionResponse is returned by POST /apis/{id}/revisions and is one element
// of the GET /apis/{id}/revisions list. deploymentInfo is non-empty when the
// revision is currently deployed onto a gateway (a deployed revision cannot be
// deleted, so we must undeploy it first).
type revisionResponse struct {
	ID             string           `json:"id"`
	Description    string           `json:"description"`
	DeploymentInfo []deploymentInfo `json:"deploymentInfo"`
}

// deploymentInfo describes where a revision is deployed (gateway env name).
type deploymentInfo struct {
	Name string `json:"name"`
}

// revisionList is the GET /apis/{id}/revisions response.
type revisionList struct {
	Count int                `json:"count"`
	List  []revisionResponse `json:"list"`
}

// deployment is one element of the deploy-revision request/response array.
type deployment struct {
	Name               string `json:"name"`
	Vhost              string `json:"vhost"`
	DisplayOnDevportal bool   `json:"displayOnDevportal"`
}

// additionalProperties is the API metadata uploaded (stringified) alongside the
// OpenAPI file in the import-openapi multipart request.
type additionalProperties struct {
	Name           string         `json:"name"`
	Version        string         `json:"version"`
	Context        string         `json:"context"`
	EndpointConfig endpointConfig `json:"endpointConfig"`
	Policies       []string       `json:"policies"`
}

type endpointConfig struct {
	EndpointType        string      `json:"endpoint_type"`
	ProductionEndpoints endpointURL `json:"production_endpoints"`
	SandboxEndpoints    endpointURL `json:"sandbox_endpoints"`
}

type endpointURL struct {
	URL string `json:"url"`
}

// Publish materialises api on WSO2 and makes it serve live, subscribable
// traffic. It is idempotent: an existing name+version is reused (Created=false)
// rather than duplicated. Sequence: import-openapi (201) -> create revision ->
// deploy-revision (200) -> change-lifecycle=Publish (200).
func (c *Client) Publish(ctx context.Context, api *adapter.NormalizedAPI) (*adapter.PublishResult, error) {
	ctx, cancel := withDeadline(ctx)
	defer cancel()

	tok, err := c.ensureToken(ctx)
	if err != nil {
		return nil, fmt.Errorf("wso2 publish: %w", err)
	}

	// 1. Idempotency probe: reuse an existing API with the same name+version.
	apiID, created, err := c.findOrImport(ctx, tok, api)
	if err != nil {
		return nil, err
	}

	// 2. Create a deployable revision (mandatory in 4.x). WSO2 4.x caps an API
	//    at 5 revisions, so make room first to keep repeated apply convergent.
	if err := c.ensureRevisionSlot(ctx, tok, apiID); err != nil {
		return nil, err
	}
	revisionID, err := c.createRevision(ctx, tok, apiID)
	if err != nil {
		return nil, err
	}

	// 3. Deploy the revision onto the gateway — the #1 forgotten step. Success
	//    is HTTP 200 (NOT 201), with the returned APIRevisionDeployment array.
	if err := c.deployRevision(ctx, tok, apiID, revisionID); err != nil {
		return nil, err
	}

	// 4. Move the lifecycle to PUBLISHED (separate concern from deploy).
	if err := c.changeLifecycle(ctx, tok, apiID, "Publish"); err != nil {
		return nil, err
	}

	return &adapter.PublishResult{
		Gateway:       "wso2",
		APIID:         apiID,
		RevisionID:    revisionID,
		InvocationURL: c.invocationURL(api.BasePath),
		Published:     true,
		Created:       created,
	}, nil
}

// findOrImport returns an existing apiId (created=false) when an API with the
// same name+version is already present, otherwise it imports the OpenAPI spec
// and returns the new apiId (created=true).
func (c *Client) findOrImport(ctx context.Context, tok string, api *adapter.NormalizedAPI) (string, bool, error) {
	query := fmt.Sprintf("name:%s version:%s", api.Name, api.Version)
	var search apiSearchResponse
	if _, err := httpx.JSON(ctx, c.hc, "GET",
		c.adminURL+publisherBase+"/apis?query="+queryEscape(query),
		bearer(tok), nil, &search); err != nil {
		return "", false, fmt.Errorf("wso2 publish: probe existing api: %w", err)
	}
	for _, a := range search.List {
		if a.Name == api.Name && a.Version == api.Version {
			return a.ID, false, nil
		}
	}
	id, err := c.importOpenAPI(ctx, tok, api)
	if err != nil {
		return "", false, err
	}
	return id, true, nil
}

// importOpenAPI creates the API by importing the verbatim OpenAPI definition.
// The spec bytes go in the multipart "file" part and the API metadata in the
// "additionalProperties" part as STRINGIFIED JSON. Expects 201 Created.
func (c *Client) importOpenAPI(ctx context.Context, tok string, api *adapter.NormalizedAPI) (string, error) {
	props := additionalProperties{
		Name:    api.Name,
		Version: api.Version,
		Context: api.BasePath,
		EndpointConfig: endpointConfig{
			EndpointType:        "http",
			ProductionEndpoints: endpointURL{URL: api.BackendURL},
			SandboxEndpoints:    endpointURL{URL: api.BackendURL},
		},
		Policies: []string{defaultThrottle},
	}
	propsJSON, err := json.Marshal(props)
	if err != nil {
		return "", fmt.Errorf("wso2 publish: marshal additionalProperties: %w", err)
	}

	body, contentType, err := buildImportMultipart(api, propsJSON)
	if err != nil {
		return "", fmt.Errorf("wso2 publish: build import-openapi multipart: %w", err)
	}

	headers := map[string]string{
		"Authorization": "Bearer " + tok,
		"Content-Type":  contentType,
		"Accept":        "application/json",
	}
	code, raw, err := httpx.Do(ctx, c.hc, "POST",
		c.adminURL+publisherBase+"/apis/import-openapi", headers, body)
	if err != nil {
		return "", fmt.Errorf("wso2 publish: import-openapi: %w", err)
	}
	if code != 201 {
		return "", fmt.Errorf("wso2 publish: import-openapi -> %d (want 201): %s", code, string(raw))
	}
	var out importResponse
	if err := unmarshalJSON(raw, &out); err != nil {
		return "", fmt.Errorf("wso2 publish: decode import-openapi response: %w", err)
	}
	if out.ID == "" {
		return "", fmt.Errorf("wso2 publish: import-openapi returned empty api id")
	}
	return out.ID, nil
}

// buildImportMultipart assembles the import-openapi body: a "file" part holding
// the OpenAPI bytes plus an "additionalProperties" part holding the stringified
// metadata JSON.
func buildImportMultipart(api *adapter.NormalizedAPI, propsJSON []byte) (*bytes.Buffer, string, error) {
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)

	filename := "openapi.yaml"
	if api.SpecPath != "" {
		filename = filepath.Base(api.SpecPath)
	}
	fw, err := mw.CreateFormFile("file", filename)
	if err != nil {
		return nil, "", err
	}
	if _, err := fw.Write(api.Spec); err != nil {
		return nil, "", err
	}

	// additionalProperties is a stringified JSON form field, not a file.
	if err := mw.WriteField("additionalProperties", string(propsJSON)); err != nil {
		return nil, "", err
	}
	if err := mw.Close(); err != nil {
		return nil, "", err
	}
	return &buf, mw.FormDataContentType(), nil
}

// revisionMax is WSO2 API-M 4.x's per-API revision cap. Exceeding it makes
// POST /apis/{id}/revisions fail (900981 "Maximum number of revisions
// exceeded"), which would break a repeated `labctl apply` of an unchanged API.
const revisionMax = 5

// createRevision creates a deployable revision and returns its id. On a POST
// failure (typically the per-API revision cap of WSO2 4.x) it prunes the oldest
// non-deployed revision and retries once, so re-apply stays convergent.
func (c *Client) createRevision(ctx context.Context, tok, apiID string) (string, error) {
	in := map[string]string{"description": "labctl revision"}
	var out revisionResponse
	code, err := httpx.JSON(ctx, c.hc, "POST",
		c.adminURL+publisherBase+"/apis/"+url.PathEscape(apiID)+"/revisions", bearer(tok), in, &out)
	if err != nil {
		// WSO2 4.x caps at 5 revisions: the 6th POST returns a non-2xx. Purge the
		// oldest non-deployed revision and retry once before giving up.
		if rErr := c.pruneOldestRevision(ctx, tok, apiID); rErr != nil {
			return "", fmt.Errorf("wso2 publish: create revision (%d): %w; prune failed: %v", code, err, rErr)
		}
		code, err = httpx.JSON(ctx, c.hc, "POST",
			c.adminURL+publisherBase+"/apis/"+url.PathEscape(apiID)+"/revisions", bearer(tok), in, &out)
		if err != nil {
			return "", fmt.Errorf("wso2 publish: create revision after prune (%d): %w", code, err)
		}
	}
	if out.ID == "" {
		return "", fmt.Errorf("wso2 publish: create revision returned empty id")
	}
	return out.ID, nil
}

// listRevisions returns the revisions currently held by the API (oldest-first).
func (c *Client) listRevisions(ctx context.Context, tok, apiID string) ([]revisionResponse, error) {
	var list revisionList
	if _, err := httpx.JSON(ctx, c.hc, "GET",
		c.adminURL+publisherBase+"/apis/"+url.PathEscape(apiID)+"/revisions",
		bearer(tok), nil, &list); err != nil {
		return nil, fmt.Errorf("wso2 publish: list revisions: %w", err)
	}
	return list.List, nil
}

// ensureRevisionSlot keeps the API under WSO2's per-API revision cap (default 5)
// by pruning the oldest revision when the list is already full, so a repeated
// apply of an unchanged contract stays convergent instead of failing at the cap.
func (c *Client) ensureRevisionSlot(ctx context.Context, tok, apiID string) error {
	list, err := c.listRevisions(ctx, tok, apiID)
	if err != nil {
		return err
	}
	if len(list) < revisionMax {
		return nil // under the cap, there is room to create.
	}
	return c.pruneRevision(ctx, tok, apiID, list)
}

// pruneOldestRevision lists the revisions and deletes the oldest non-deployed
// one (undeploying it first when needed). Used as the recovery path when a
// create-revision POST is rejected at the cap.
func (c *Client) pruneOldestRevision(ctx context.Context, tok, apiID string) error {
	list, err := c.listRevisions(ctx, tok, apiID)
	if err != nil {
		return err
	}
	if len(list) == 0 {
		return fmt.Errorf("wso2 publish: no revision to prune")
	}
	return c.pruneRevision(ctx, tok, apiID, list)
}

// pruneRevision picks the oldest non-deployed revision (falling back to the
// oldest one, undeploying it first), and DELETEs it. list is oldest-first.
func (c *Client) pruneRevision(ctx context.Context, tok, apiID string, list []revisionResponse) error {
	// Prefer the oldest revision that is not currently deployed.
	victim := list[0]
	found := false
	for _, r := range list {
		if len(r.DeploymentInfo) == 0 {
			victim = r
			found = true
			break
		}
	}
	if !found {
		// All revisions are deployed; undeploy the oldest before deleting it.
		body := []deployment{{Name: c.gatewayEnv, Vhost: c.vhost}}
		_, _ = httpx.JSON(ctx, c.hc, "POST",
			c.adminURL+publisherBase+"/apis/"+url.PathEscape(apiID)+
				"/undeploy-revision?revisionId="+queryEscape(victim.ID),
			bearer(tok), body, nil)
	}
	if _, err := httpx.JSON(ctx, c.hc, "DELETE",
		c.adminURL+publisherBase+"/apis/"+url.PathEscape(apiID)+"/revisions/"+url.PathEscape(victim.ID),
		bearer(tok), nil, nil); err != nil {
		return fmt.Errorf("wso2 publish: delete oldest revision: %w", err)
	}
	return nil
}

// deployRevision deploys the revision onto the gateway environment. The body is
// a JSON ARRAY of deployment objects and the revisionId is a QUERY param.
// Success is HTTP 200 (verdict correction — not 201).
func (c *Client) deployRevision(ctx context.Context, tok, apiID, revisionID string) error {
	body := []deployment{{
		Name:               c.gatewayEnv,
		Vhost:              c.vhost,
		DisplayOnDevportal: true,
	}}
	deployURL := c.adminURL + publisherBase + "/apis/" + url.PathEscape(apiID) +
		"/deploy-revision?revisionId=" + queryEscape(revisionID)

	code, err := httpx.JSON(ctx, c.hc, "POST", deployURL, bearer(tok), body, nil)
	if err != nil {
		// httpx.JSON only errors on non-2xx/transport; surface the diagnostic.
		return fmt.Errorf("wso2 publish: deploy-revision (404=>bad gatewayEnv/vhost): %w", err)
	}
	if code != 200 {
		return fmt.Errorf("wso2 publish: deploy-revision -> %d (want 200)", code)
	}
	return nil
}

// changeLifecycle moves the API lifecycle (action passed as a QUERY param, no
// body). Expects 200/202.
func (c *Client) changeLifecycle(ctx context.Context, tok, apiID, action string) error {
	lcURL := c.adminURL + publisherBase + "/apis/change-lifecycle?apiId=" +
		queryEscape(apiID) + "&action=" + queryEscape(action)

	code, raw, err := httpx.Do(ctx, c.hc, "POST", lcURL, bearer(tok), nil)
	if err != nil {
		return fmt.Errorf("wso2 publish: change-lifecycle %s: %w", action, err)
	}
	if code != 200 && code != 202 {
		return fmt.Errorf("wso2 publish: change-lifecycle %s -> %d (want 200/202): %s",
			action, code, string(raw))
	}
	return nil
}

// unmarshalJSON is a tiny shared decode helper used where we read a raw body
// from httpx.Do (which, unlike httpx.JSON, does not decode for us).
func unmarshalJSON(raw []byte, out any) error {
	if len(bytes.TrimSpace(raw)) == 0 {
		return fmt.Errorf("empty response body")
	}
	return json.Unmarshal(raw, out)
}
