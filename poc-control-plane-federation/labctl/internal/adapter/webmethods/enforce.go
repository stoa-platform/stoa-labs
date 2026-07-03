package webmethods

// Enforcement read-back (ADR-076 Phase 3, goal A1): a strictly READ-ONLY pass
// that confirms — from the gateway's live state, by the exact apiID Publish
// returned — that the security bundle derived from the contract's integrity
// classification is enforced. This is the verifier the apply gate calls AFTER
// projection; it deliberately does NOT reuse the projection's idempotence
// helpers, because those encode projector assumptions the read-back must not
// inherit (pinned by the adversarial design review):
//
//   - isIdentifyAction EXCLUDES the OAuth2+cert AND action, and
//     actionInMode/nestedRuleParams only read the FIRST IdentificationRule —
//     both would produce guaranteed false negatives on a VH API, where the IAM
//     stage references the shared AND action and rule ORDER is not pinned at
//     read-back. The verifier reads ALL rules (actionIdentificationRules).
//   - logicalConnector/allowAnonymous are written as strings but NEVER re-read
//     anywhere else in this package; their read-back type is not pinned on the
//     trial. All scalar reads are type-tolerant (string/bool/number).
//   - the throttle limit lives in the NESTED throttleRule group no existing
//     helper parses; throttleRuleValue reads it tolerantly. The throttle action
//     is SHARED across APIs (each apply re-PUTs its own limit), so the verdict
//     keys on value > 0 and ANNOTATES the limit instead of requiring equality.
//   - the OAuth2 scope barrier is fail-open if the scope mapping is unbound:
//     the oauth2 verdict re-reads the mapping (scopeBindsAPI +
//     scopeRequiresAuthScope), not just the strategy and the IAM action.
//
// Never overclaim: what cannot be read on THIS runtime is degraded (documented
// weaker mechanism) or unverifiable — and the audience barrier is annotated as
// fail-open on the 10.15 trial (3/4 barriers) whenever remote introspection is
// not in play, mirroring the reconcile report's honesty rules.

import (
	"context"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

// Fixed ids of the GLOBAL transaction-logging objects (audit-log leg, ADR-070):
// the system policy and its Log Invocation action ship with these literal ids
// on 10.15 (see scripts/wm-otel-setup.sh, which PUTs them by id).
const (
	globalLogInvocationPolicyID = "GlobalLogInvocationPolicy"
	globalLogInvocationActionID = "GlobalLogInvocationPolicyAction"
)

// Compile-time proof the adapter implements the optional capability.
var _ adapter.EnforcementVerifier = (*Adapter)(nil)

// VerifyEnforcement reads the live state of the published API and reports, per
// required policy, whether the gateway enforces it. Read-only; transport-level
// failures return an error (the gate treats them as unconfirmed).
func (a *Adapter) VerifyEnforcement(ctx context.Context, apiID string, want adapter.EnforcementRequirement) (*adapter.EnforcementReport, error) {
	rec, err := a.getAPI(ctx, apiID)
	if err != nil {
		return nil, fmt.Errorf("enforcement read-back: %w", err)
	}
	_, policy, err := a.findServicePolicy(ctx, rec.Policies)
	if err != nil {
		return nil, fmt.Errorf("enforcement read-back: %w", err)
	}

	// Resolve every action of the stages the bundle can touch, by DIRECT GET
	// (enveloped or naked shape). Every enforcement of the FIRST matching stage
	// group is scanned (stageEnforcementIDs stops at the first stageKey match —
	// 10.15 does not mint duplicate stage groups; verifyMTLS likewise settles on
	// the first entryProtocolPolicy action of the transport stage).
	iamActions, err := a.stageActions(ctx, policy, stageIAM)
	if err != nil {
		return nil, err
	}

	// An inactive API enforces NOTHING at the data plane: every leg would be
	// moot. Hard error (=> ENFORCEMENT_UNCONFIRMED), not a verdict — near
	// unreachable after Publish's ensureActive, kept fail-closed regardless.
	if !rec.IsActive {
		return nil, fmt.Errorf("enforcement read-back: api %s relue isActive=false — rien n'est enforced au data-plane", apiID)
	}

	rep := &adapter.EnforcementReport{}
	for _, p := range want.Policies {
		var v adapter.PolicyVerdict
		switch p {
		case "oauth2":
			v = a.verifyOAuth2(ctx, rec, apiID, iamActions)
		case "mtls":
			v = a.verifyMTLS(ctx, policy, iamActions)
		case "rate-limit":
			v = a.verifyRateLimit(ctx, policy)
		case "audit-log":
			v = a.verifyAuditLog(ctx)
		case "ip-allowlist":
			v = adapter.PolicyVerdict{
				Policy: p, Status: adapter.VerdictDegraded,
				Detail: "enforced au consommateur (identifier ipAddressRange à la souscription, ADR-071) — pas de policy IP API-level sur wM 10.15",
			}
		case "apikey":
			v = adapter.PolicyVerdict{
				Policy: p, Status: adapter.VerdictUnverifiable,
				Detail: "mode apiKey non projeté sur webMethods (écart ADR-076 #7)",
			}
		default:
			v = adapter.PolicyVerdict{
				Policy: p, Status: adapter.VerdictUnverifiable,
				Detail: "policy inconnue de ce verifier (fail-closed)",
			}
		}
		rep.Verdicts = append(rep.Verdicts, v)
	}
	return rep, nil
}

// --- per-policy verdicts -----------------------------------------------------

// verifyOAuth2 confirms the full OAuth2 barrier: an OAUTH2 strategy named after
// the GATEWAY record's apiName (never the manifest name — the record is already
// sanitized), a scope mapping bound to THIS apiID gating on (alias, scope), and
// an IAM action with allowAnonymous=false carrying a (strict, oAuth2Token)
// rule. The audience is annotated fail-open on the trial (3/4 barriers) unless
// remote introspection is configured.
func (a *Adapter) verifyOAuth2(ctx context.Context, rec wmAPI, apiID string, iamActions []map[string]any) adapter.PolicyVerdict {
	miss := func(detail string) adapter.PolicyVerdict {
		return adapter.PolicyVerdict{Policy: "oauth2", Status: adapter.VerdictMissing, Detail: detail}
	}
	if a.inbound == nil || !a.inbound.oauth2Enabled() {
		return miss("le manifeste ne déclare pas le chemin OAuth2 (inboundAuth.audience) — état requis non confirmable")
	}

	// Read failures are UNVERIFIABLE (infra/API unreadable), not missing
	// (absent/drifted): both fail the gate, but machine consumers of the status
	// field must be able to tell "security drift" from "could not read". The
	// detail stays a FIXED string — httpx errors embed raw response-body
	// fragments, which the C7 whitelist forbids in verdicts.
	unread := func(what string) adapter.PolicyVerdict {
		return adapter.PolicyVerdict{Policy: "oauth2", Status: adapter.VerdictUnverifiable, Detail: what + " illisible(s) au read-back (erreur de lecture admin)"}
	}

	// 1. Strategy, by the gateway-record-derived name.
	wantStrategy := strategyName(rec.APIName)
	strategies, err := a.listStrategies(ctx)
	if err != nil {
		return unread("strategies")
	}
	found := false
	for _, st := range strategies {
		if st.Name == wantStrategy {
			found = true
			break
		}
	}
	if !found {
		return miss("strategy " + wantStrategy + " absente")
	}

	// 2. Scope mapping bound to THIS api, gating on (alias, scope) and pinning
	// the configured audience — the scope barrier is fail-open without the
	// binding, and an out-of-band audience drift on the mapping would matter on
	// any build that honours remote introspection.
	scopes, err := a.listScopes(ctx)
	if err != nil {
		return unread("scope mappings")
	}
	scopeOK := false
	for _, sc := range scopes {
		audience, _ := sc["audience"].(string)
		if scopeBindsAPI(sc, apiID) && a.scopeRequiresAuthScope(sc) && audience == a.inbound.audience {
			scopeOK = true
			break
		}
	}
	if !scopeOK {
		return miss("aucun scope mapping ne lie cette API à (" + a.inbound.aliasName + ", " + a.inbound.scope + ") avec l'audience configurée — barrière scope fail-open")
	}

	// 3. IAM action: allowAnonymous=false + a (strict, oAuth2Token) rule,
	// scanned across ALL rules of ALL IAM enforcements.
	if !anyIAMAction(iamActions, func(act map[string]any) bool {
		return actionParamString(act, "allowAnonymous") == "false" &&
			hasIdentificationRule(act, "strict", "oAuth2Token")
	}) {
		return miss("aucune action IAM avec allowAnonymous=false et une règle (strict, oAuth2Token)")
	}

	// DECISION (design review, lens B S2): the status stays `enforced` with the
	// fail-open audience carried as an ANNOTATION — matching the repo-wide canon
	// (reconcile "ENFORCED*", ADR-076 status table). `degraded` is reserved for
	// structurally weaker MECHANISMS (e.g. consumer-side ip-allowlist); the
	// audience gap is a build limitation of the trial, annotated, never claimed.
	detail := "strategy " + wantStrategy + " + scope mapping lié + action IAM strict/oAuth2Token"
	if !a.inbound.remoteIntrospectionEnabled() {
		detail += " — audience non opposable sur trial 10.15 => 3/4 barrières (sig+issuer+scope+azp)"
	}
	return adapter.PolicyVerdict{Policy: "oauth2", Status: adapter.VerdictEnforced, Detail: detail}
}

// verifyMTLS confirms the VH leg: an IAM action whose rules include BOTH
// (strict, oAuth2Token) AND (strict, httpsCertificate), with
// logicalConnector=AND and allowAnonymous=false — plus the transport stage
// pinned to protocol [https] so the API is only reachable through the TLS
// listener. The listener clientAuth mode and the CA truststore stay IS-admin
// facts (ansible/is-mtls-setup.yml), outside this REST surface.
func (a *Adapter) verifyMTLS(ctx context.Context, policy map[string]any, iamActions []map[string]any) adapter.PolicyVerdict {
	miss := func(detail string) adapter.PolicyVerdict {
		return adapter.PolicyVerdict{Policy: "mtls", Status: adapter.VerdictMissing, Detail: detail}
	}
	if !anyIAMAction(iamActions, func(act map[string]any) bool {
		return actionParamString(act, "logicalConnector") == "AND" &&
			actionParamString(act, "allowAnonymous") == "false" &&
			hasIdentificationRule(act, "strict", "oAuth2Token") &&
			hasIdentificationRule(act, "strict", identificationTypeCert)
	}) {
		return miss("aucune action IAM AND(oAuth2Token, httpsCertificate) avec allowAnonymous=false — la barrière cert n'est pas opposée")
	}

	transportActions, err := a.stageActions(ctx, policy, stageTransport)
	if err != nil {
		return adapter.PolicyVerdict{Policy: "mtls", Status: adapter.VerdictUnverifiable, Detail: "stage transport illisible au read-back (erreur de lecture admin)"}
	}
	for _, act := range transportActions {
		if tk, _ := act["templateKey"].(string); tk != "entryProtocolPolicy" {
			continue
		}
		if actionProtocolIs(act, "https") {
			return adapter.PolicyVerdict{
				Policy: "mtls", Status: adapter.VerdictEnforced,
				Detail: "action IAM AND(oAuth2Token, httpsCertificate) + transport protocol=[https] (listener clientAuth/CA = couche IS-admin, hors REST)",
			}
		}
		return miss("l'action transport entryProtocolPolicy n'est pas [https] — l'API reste joignable hors du listener TLS")
	}
	return miss("aucune action entryProtocolPolicy sur le stage transport")
}

// verifyRateLimit confirms a throttle action with a positive limit on the LMT
// stage. The action is SHARED across APIs and re-PUT by each apply, so the
// verdict keys on value > 0 and annotates the limit currently stored.
func (a *Adapter) verifyRateLimit(ctx context.Context, policy map[string]any) adapter.PolicyVerdict {
	actions, err := a.stageActions(ctx, policy, stageLMT)
	if err != nil {
		return adapter.PolicyVerdict{Policy: "rate-limit", Status: adapter.VerdictUnverifiable, Detail: "stage LMT illisible au read-back (erreur de lecture admin)"}
	}
	for _, act := range actions {
		if !isThrottleAction(act) {
			continue
		}
		if limit, ok := throttleRuleValue(act); ok && limit > 0 {
			return adapter.PolicyVerdict{
				Policy: "rate-limit", Status: adapter.VerdictEnforced,
				Detail: fmt.Sprintf("throttle LMT relu, limite=%d (429 au-delà, non fail-open ; action partagée: la limite est celle du dernier apply)", limit),
			}
		}
		return adapter.PolicyVerdict{Policy: "rate-limit", Status: adapter.VerdictMissing, Detail: "action throttle présente mais throttleRule.value non positif au read-back"}
	}
	return adapter.PolicyVerdict{Policy: "rate-limit", Status: adapter.VerdictMissing, Detail: "aucune action throttle sur le stage LMT"}
}

// verifyAuditLog confirms the GLOBAL transaction-logging pair by fixed ids:
// the system policy is active AND its Log Invocation action ships metadata
// only (storeRequestPayload=false — the ADR-070 redaction posture; the request
// body must never be captured).
func (a *Adapter) verifyAuditLog(ctx context.Context) adapter.PolicyVerdict {
	miss := func(detail string) adapter.PolicyVerdict {
		return adapter.PolicyVerdict{Policy: "audit-log", Status: adapter.VerdictMissing, Detail: detail}
	}
	// Taxonomy note: an unreadable global pair stays MISSING (not unverifiable)
	// — the dominant real cause is ABSENCE (fresh gateway, wm-otel-setup never
	// run: the GET 404s), which genuinely is "not enforced on this gateway".
	// Details are fixed strings (C7: no raw error/record fragments).
	pol, err := a.getPolicy(ctx, globalLogInvocationPolicyID)
	if err != nil {
		return miss("policy globale " + globalLogInvocationPolicyID + " illisible/absente (wm-otel-setup non joué sur cette gateway ?)")
	}
	if scalarString(pol["active"]) != "true" {
		return miss("policy globale " + globalLogInvocationPolicyID + " inactive")
	}
	act, err := a.getPolicyActionByID(ctx, globalLogInvocationActionID)
	if err != nil {
		return miss("action globale " + globalLogInvocationActionID + " illisible/absente (wm-otel-setup non joué sur cette gateway ?)")
	}
	if actionParamString(act, "storeRequestPayload") != "false" {
		return miss("storeRequestPayload n'est pas false — posture de redaction ADR-070 violée (le request body ne doit JAMAIS être capturé)")
	}
	return adapter.PolicyVerdict{
		Policy: "audit-log", Status: adapter.VerdictEnforced,
		Detail: "logInvocation global actif, storeRequestPayload=false (métadonnées seules, ADR-070)",
	}
}

// --- read-back primitives ----------------------------------------------------

// getPolicyActionByID GETs one policy action DIRECTLY by id and unwraps the
// enveloped ({"policyAction":{...}}) or naked record shape — the same
// double-shape the transport projection pinned live.
func (a *Adapter) getPolicyActionByID(ctx context.Context, id string) (map[string]any, error) {
	url := a.adminPath("/policyActions/" + id)
	var raw map[string]any
	if _, err := httpx.JSON(ctx, a.http, http.MethodGet, url, a.authHeaders(), nil, &raw); err != nil {
		return nil, fmt.Errorf("get policy action %s: %w", id, err)
	}
	if pa, ok := raw["policyAction"].(map[string]any); ok && pa != nil {
		return pa, nil
	}
	return raw, nil
}

// stageActions resolves EVERY enforcement of the named stage to its action
// record (direct GETs). An unreadable action is a hard error — the gate must
// not pass on a stage it could not fully read.
func (a *Adapter) stageActions(ctx context.Context, policy map[string]any, stageKey string) ([]map[string]any, error) {
	ids := stageEnforcementIDs(policy, stageKey)
	out := make([]map[string]any, 0, len(ids))
	for _, id := range ids {
		act, err := a.getPolicyActionByID(ctx, id)
		if err != nil {
			return nil, fmt.Errorf("enforcement read-back: stage %s: %w", stageKey, err)
		}
		out = append(out, act)
	}
	return out, nil
}

func anyIAMAction(actions []map[string]any, pred func(map[string]any) bool) bool {
	for _, act := range actions {
		if pred(act) {
			return true
		}
	}
	return false
}

// identificationRule is one (applicationLookup, identificationType) pair of an
// evaluatePolicy action.
type identificationRule struct {
	lookup string
	idType string
}

// actionIdentificationRules reads EVERY IdentificationRule of an action with
// both of its fields — unlike nestedRuleParams/actionInMode, which stop at the
// first rule and would misread the two-rule AND action if the product reorders
// rules at read-back.
func actionIdentificationRules(action map[string]any) []identificationRule {
	if tk, _ := action["templateKey"].(string); tk != "evaluatePolicy" {
		return nil
	}
	params, _ := action["parameters"].([]any)
	var out []identificationRule
	for _, p := range params {
		pm, _ := p.(map[string]any)
		if pm == nil {
			continue
		}
		if tk, _ := pm["templateKey"].(string); tk != "IdentificationRule" {
			continue
		}
		var r identificationRule
		nested, _ := pm["parameters"].([]any)
		for _, n := range nested {
			nm, _ := n.(map[string]any)
			if nm == nil {
				continue
			}
			tk, _ := nm["templateKey"].(string)
			values, _ := nm["values"].([]any)
			if len(values) == 0 {
				continue
			}
			switch tk {
			case "applicationLookup":
				r.lookup = scalarString(values[0])
			case "identificationType":
				r.idType = scalarString(values[0])
			}
		}
		out = append(out, r)
	}
	return out
}

// hasIdentificationRule reports whether ANY rule matches (lookup, idType).
func hasIdentificationRule(action map[string]any, lookup, idType string) bool {
	for _, r := range actionIdentificationRules(action) {
		if r.lookup == lookup && r.idType == idType {
			return true
		}
	}
	return false
}

// actionParamString reads a TOP-LEVEL action parameter's first value as a
// string, tolerating string/bool/number — these params are written as strings
// but never re-read anywhere else, so their read-back type is not pinned on
// the trial (adversarial-review finding).
func actionParamString(action map[string]any, key string) string {
	values := actionParamValues(action, key)
	if len(values) == 0 {
		return ""
	}
	return scalarString(values[0])
}

// throttleRuleValue reads throttleRule.value from the throttle action's NESTED
// parameter group, tolerating string and number encodings. ok=false when the
// group or the value is absent/unparseable.
func throttleRuleValue(action map[string]any) (int, bool) {
	params, _ := action["parameters"].([]any)
	for _, p := range params {
		pm, _ := p.(map[string]any)
		if pm == nil {
			continue
		}
		if tk, _ := pm["templateKey"].(string); tk != "throttleRule" {
			continue
		}
		nested, _ := pm["parameters"].([]any)
		for _, n := range nested {
			nm, _ := n.(map[string]any)
			if nm == nil {
				continue
			}
			if tk, _ := nm["templateKey"].(string); tk != "value" {
				continue
			}
			values, _ := nm["values"].([]any)
			if len(values) == 0 {
				return 0, false
			}
			s := scalarString(values[0])
			v, err := strconv.Atoi(strings.TrimSpace(s))
			if err != nil {
				return 0, false
			}
			return v, true
		}
		return 0, false
	}
	return 0, false
}

// scalarString renders a JSON scalar (string, bool, float64) as its canonical
// string form; "" for anything else.
func scalarString(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case bool:
		return strconv.FormatBool(x)
	case float64:
		if x == float64(int64(x)) {
			return strconv.FormatInt(int64(x), 10)
		}
		return strconv.FormatFloat(x, 'f', -1, 64)
	}
	return ""
}
