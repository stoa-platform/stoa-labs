package webmethods

// Per-API mTLS enforcement at the IAM stage (ADR-076 VH leg, request-mode model).
// With the HTTPS listener in clientAuth=REQUEST (cert optional at transport), a
// VH API still needs mTLS ENFORCED: this projects an Identify & Authorize action
// that requires BOTH an OAuth2 token AND a trusted client certificate
// (logicalConnector=AND, allowAnonymous=false, two IdentificationRules —
// oAuth2Token + httpsCertificate). A no-cert request is then rejected 401 at IAM
// even though the transport let it through. Pinned live on apigateway:10.15:
//   - identificationType httpsCertificate ("SSL Certificate") IS a valid IAM id type;
//   - IdentificationRule is an array, so OAuth2 AND cert is one action;
//   - the client cert must map to a consumer application's httpsCertificate
//     identifier (labctl subscribe / identifiers.go), else the cert rule fails.
//
// Two SHARED actions coexist (not per-API, to avoid action sprawl): the
// oauth2-only Identify action (H/M APIs) and this OAuth2+cert action (VH APIs).
// They are told apart by the presence of an httpsCertificate rule — isIdentifyAction
// EXCLUDES this action so the oauth2 finder never converges (strips) its cert rule.

import (
	"context"
	"fmt"
	"net/http"
)

// mtlsActionName is the display name POSTed with the OAuth2+cert action
// (documentation only: matching is on the rule fingerprint, never the name).
const mtlsActionName = "Identify & Authorize (OAuth2+mTLS) (labctl)"

// identificationTypeCert is the IAM identificationType for a trusted client
// certificate ("SSL Certificate" in the UI). Same key as the consumer app's
// httpsCertificate identifier the cert must map to.
const identificationTypeCert = "httpsCertificate"

// actionRuleTypes returns the identificationType of EVERY IdentificationRule of an
// evaluatePolicy action (nestedRuleParams only sees the first rule; the AND action
// carries several).
func actionRuleTypes(action map[string]any) []string {
	if tk, _ := action["templateKey"].(string); tk != "evaluatePolicy" {
		return nil
	}
	params, _ := action["parameters"].([]any)
	var out []string
	for _, p := range params {
		pm, _ := p.(map[string]any)
		if pm == nil {
			continue
		}
		if tk, _ := pm["templateKey"].(string); tk != "IdentificationRule" {
			continue
		}
		nested, _ := pm["parameters"].([]any)
		for _, n := range nested {
			nm, _ := n.(map[string]any)
			if nm == nil {
				continue
			}
			if tk, _ := nm["templateKey"].(string); tk == "identificationType" {
				if values, _ := nm["values"].([]any); len(values) > 0 {
					if s, _ := values[0].(string); s != "" {
						out = append(out, s)
					}
				}
			}
		}
	}
	return out
}

// isMtlsIdentifyAction reports whether an action is THE OAuth2+cert IAM action —
// exactly {oAuth2Token, httpsCertificate}. It matches on the exact rule-type set
// (not merely "has a cert rule") so it never grabs the self-service cert+IP
// action {httpsCertificate, ipAddressRange}, which also carries a cert rule.
func isMtlsIdentifyAction(action map[string]any) bool {
	return actionMatchesRuleTypes(action, []string{"oAuth2Token", identificationTypeCert})
}

// mtlsIdentifyActionBody builds the ENVELOPED OAuth2+cert IAM action body: an AND
// of oAuth2Token and httpsCertificate, both applicationLookup=strict (each must
// resolve to the SAME consumer app: the token via azp/openIdClaims, the cert via
// httpsCertificate). allowAnonymous=false => a request missing either is rejected
// 401. It is the OAuth2+cert case of the general identifyAndActionBody
// (selfservice.go).
func mtlsIdentifyActionBody(id string) map[string]any {
	return identifyAndActionBody(id, mtlsActionName, []string{"oAuth2Token", identificationTypeCert})
}

// ensureMtlsIdentifyAction finds the shared OAuth2+cert IAM action (by its cert-rule
// fingerprint) or creates it, and returns its id. The body is fixed, so a present
// action is reused as-is (no PUT).
func (a *Adapter) ensureMtlsIdentifyAction(ctx context.Context) (string, error) {
	actions, err := a.listPolicyActions(ctx)
	if err != nil {
		return "", err
	}
	for _, act := range actions {
		if !isMtlsIdentifyAction(act) {
			continue
		}
		if id, _ := act["id"].(string); id != "" {
			return id, nil // converged — idempotent no-op
		}
	}
	url := a.adminPath("/policyActions")
	code, raw, err := a.sendJSON(ctx, http.MethodPost, url, mtlsIdentifyActionBody(""))
	if err != nil {
		return "", fmt.Errorf("mtls: create OAuth2+cert action: %w", err)
	}
	if code != http.StatusCreated && code != http.StatusOK {
		return "", fmt.Errorf("mtls: create OAuth2+cert action: expected 200/201, got %d: %s", code, truncate(raw, 300))
	}
	id := parsePolicyActionID(raw)
	if id == "" {
		return "", fmt.Errorf("mtls: create OAuth2+cert action: response carries no id: %s", truncate(raw, 300))
	}
	return id, nil
}
