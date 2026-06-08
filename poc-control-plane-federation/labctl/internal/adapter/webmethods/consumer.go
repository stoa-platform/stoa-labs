package webmethods

import (
	"context"
	"fmt"
	"net/http"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

// subscription is the webMethods subscription object as serialized by
// /rest/apigateway/subscriptions. Exact camelCase keys, NOT id/name. There is
// no clientSecret in this model — webMethods does not mint credentials here.
type subscription struct {
	SubscriptionID  string `json:"subscriptionId,omitempty"`
	ApplicationName string `json:"applicationName"`
	APIID           string `json:"apiId,omitempty"`
	ClientID        string `json:"clientId"`
	CreatedAt       string `json:"createdAt,omitempty"`
}

// subListEnvelope wraps GET /rest/apigateway/subscriptions:
// {"subscriptions":[...],"count":n} — an envelope, not a bare array.
type subListEnvelope struct {
	Subscriptions []subscription `json:"subscriptions"`
	Count         int            `json:"count"`
}

// listSubscriptions fetches all subscriptions (the mock does no filtering).
func (a *Adapter) listSubscriptions(ctx context.Context) ([]subscription, error) {
	url := a.adminPath("/subscriptions")
	var env subListEnvelope
	if _, err := httpx.JSON(ctx, a.http, http.MethodGet, url, a.authHeaders(), nil, &env); err != nil {
		return nil, fmt.Errorf("webmethods list subscriptions: %w", err)
	}
	return env.Subscriptions, nil
}

// findSubscription returns an existing subscription matching both
// applicationName AND apiId (the identity used for idempotent re-apply).
func findSubscription(subs []subscription, appName, apiID string) (subscription, bool) {
	for _, s := range subs {
		if s.ApplicationName == appName && s.APIID == apiID {
			return s, true
		}
	}
	return subscription{}, false
}

// CreateConsumer provisions a webMethods subscription binding an application +
// clientId to a published API. This gateway does NOT mint credentials and has NO
// app-create step: the clientId is caller-supplied (minted out-of-band in
// Keycloak by `labctl subscribe`) and is REQUIRED here.
//
// Algorithm:
//  1. INTEGRITY: GET /apis/{apiId} to confirm the API exists. The mock does NOT
//     validate apiId on subscriptions, so we check it ourselves — otherwise a
//     dangling subscription would be created silently.
//  2. IDEMPOTENCY: list subscriptions; if one with the same applicationName AND
//     apiId exists, reuse it (no update/delete endpoint exists for subscriptions).
//  3. SUBSCRIBE: POST /subscriptions {applicationName, clientId, apiId} -> 201,
//     capture the server-assigned subscriptionId.
//
// publishResult must carry the apiId of the target API (from a prior Publish);
// we re-derive it here from `api` by locating the published record by name so
// CreateConsumer can be called independently of an in-memory PublishResult.
func (a *Adapter) CreateConsumer(ctx context.Context, api *adapter.NormalizedAPI, spec *adapter.ConsumerSpec) (*adapter.ConsumerResult, error) {
	if spec == nil || spec.ClientID == "" {
		return nil, fmt.Errorf("webmethods consumer: clientId is required (mint it in Keycloak first)")
	}
	if spec.Name == "" {
		return nil, fmt.Errorf("webmethods consumer: applicationName is required")
	}

	// Resolve the target apiId from the published APIs by name (the API must have
	// been published first).
	apis, err := a.listAPIs(ctx)
	if err != nil {
		return nil, fmt.Errorf("webmethods consumer: %w", err)
	}
	target, ok := findByName(apis, api.Name)
	if !ok {
		return nil, fmt.Errorf("webmethods consumer: api %q is not published — call Publish first", api.Name)
	}
	apiID := target.APIID

	// 1. Integrity: confirm the API exists (the mock won't validate apiId for us).
	if _, err := a.getAPI(ctx, apiID); err != nil {
		return nil, fmt.Errorf("webmethods consumer: integrity check: %w", err)
	}

	// 2. Idempotency: reuse an existing subscription for the same app+api.
	subs, err := a.listSubscriptions(ctx)
	if err != nil {
		return nil, fmt.Errorf("webmethods consumer: %w", err)
	}
	if cur, found := findSubscription(subs, spec.Name, apiID); found {
		return a.consumerResult(cur, spec.ClientID), nil
	}

	// 3. Subscribe. Required: applicationName + clientId. Server assigns
	//    subscriptionId; expect 201.
	body := subscription{
		ApplicationName: spec.Name,
		ClientID:        spec.ClientID,
		APIID:           apiID,
	}
	var createdSub subscription
	url := a.adminPath("/subscriptions")
	code, err := httpx.JSON(ctx, a.http, http.MethodPost, url, a.authHeaders(), body, &createdSub)
	if err != nil {
		return nil, fmt.Errorf("webmethods consumer: subscribe: %w", err)
	}
	if code != http.StatusCreated {
		return nil, fmt.Errorf("webmethods consumer: subscribe %q expected 201, got %d", spec.Name, code)
	}
	if createdSub.SubscriptionID == "" {
		return nil, fmt.Errorf("webmethods consumer: subscribe %q returned no subscriptionId", spec.Name)
	}

	return a.consumerResult(createdSub, spec.ClientID), nil
}

// consumerResult builds the uniform ConsumerResult. webMethods has no secret in
// this model, so ConsumerSecret stays empty and ConsumerKey echoes the supplied
// clientId. The TokenHint documents that the mock has no auth but a real
// apigateway:10.15 expects the Keycloak bearer for this clientId.
func (a *Adapter) consumerResult(sub subscription, clientID string) *adapter.ConsumerResult {
	return &adapter.ConsumerResult{
		Gateway:        gatewayName,
		ConsumerID:     sub.SubscriptionID,
		SubscriptionID: sub.SubscriptionID,
		ConsumerKey:    clientID,
		ConsumerSecret: "",
		TokenHint:      "mock has no auth; in real apigateway:10.15 present the Keycloak bearer for clientId " + clientID,
	}
}
