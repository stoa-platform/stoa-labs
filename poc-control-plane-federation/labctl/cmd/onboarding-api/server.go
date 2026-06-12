package main

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/audit"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/authz"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/onboarding"
)

// Server wires the HTTP surface onto the onboarding engine. POST /applications
// is now an AUTHENTICATED, RBAC-gated, audited write:
//
//   - OAuth2/OIDC: it REQUIRES a Keycloak Bearer (realm stoa-lab) and VALIDATES
//     it locally against the realm JWKS (RS256 + iss + exp + aud) — the same
//     stdlib verifier the governance-api uses (no introspection round-trip, no
//     new dependency: air-gapped). The commit actor is derived from the VALIDATED
//     claims (sub / preferred_username), never from a forgeable X-Actor-* header.
//   - RBAC multi-tenant: the token MUST carry the realm role partner-onboarder
//     AND a tenant (claim `tenant` or group `/tenants/{tenant}`); the body's
//     tenant MUST equal the token's tenant. Role absent → 403; tenant mismatch
//     → 403; no/forged/expired token → 401.
//   - Audit: EVERY decision (ACCEPT and DENY) is recorded to a per-tenant
//     OpenSearch index and to a structured stdout line carrying a W3C trace_id
//     (the audit↔OTel pivot, ADR-070).
//
// The Git service account stays server-side: the push credential is the repo's,
// never the developer's (Vault + rotation in prod — see the package docs).
type Server struct {
	Svc      *onboarding.Service
	Verifier authz.TokenVerifier
	Audit    audit.Sink
	// Limiter throttles the shared management plane per authenticated principal
	// (actor+tenant). Nil disables throttling (the handler stays usable in tests).
	Limiter *rateLimiter
}

// Handler builds the routed mux (Go 1.22 method+pattern routing). /healthz is
// unauthenticated (liveness only); /applications is fully gated.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /applications", s.handleOnboard)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	return mux
}

// handleOnboard is the gated write. It authenticates, authorizes (role+tenant),
// validates the body, commits the manifest as the VALIDATED actor, and audits
// the outcome. The body tenant is checked against the TOKEN tenant before any
// write, so a tenant mismatch never touches Git.
func (s *Server) handleOnboard(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	traceID := audit.NewTraceID()
	w.Header().Set("X-Trace-Id", traceID)
	ip := authz.ClientIP(r)

	// emit records one decision to both audit sinks and writes the HTTP reply.
	emit := func(status int, decision audit.Decision, reason, actor, tenant, partner, commitSHA string, body any) {
		s.Audit.Record(ctx, audit.Event{
			Actor:      orDash(actor),
			Action:     audit.ActionOnboard,
			Tenant:     tenant,
			Partner:    orDash(partner),
			Decision:   decision,
			Reason:     reason,
			CommitSHA:  commitSHA,
			TraceID:    traceID,
			ClientIP:   ip,
			HTTPStatus: status,
		})
		writeJSON(w, status, body)
	}

	// 1) OAuth2: require + validate a Bearer. No token / not Bearer → 401.
	tok, ok := authz.BearerToken(r)
	if !ok {
		emit(http.StatusUnauthorized, audit.Deny, "no_token", "", "unknown", "",
			"", errBody("UNAUTHENTICATED", "missing or malformed Bearer token"))
		return
	}
	id, err := s.Verifier.Verify(ctx, tok)
	if err != nil {
		// Forged signature, wrong issuer, expired, wrong audience: all 401.
		emit(http.StatusUnauthorized, audit.Deny, "invalid_token", "", "unknown", "",
			"", errBody("UNAUTHENTICATED", "token verification failed"))
		return
	}
	actor := authz.ActorName(id)

	// 2) RBAC: require the partner-onboarder realm role. Absent → 403.
	if !authz.HasRole(id, RequiredRole) {
		emit(http.StatusForbidden, audit.Deny, "missing_role", actor, authz.TenantOrUnknown(id), "",
			"", errBody("FORBIDDEN", "token lacks the required role "+RequiredRole))
		return
	}

	// 3) RBAC: the token MUST carry a tenant. Unscoped → 403.
	tokenTenant, ok := authz.TenantOf(id)
	if !ok {
		emit(http.StatusForbidden, audit.Deny, "no_tenant", actor, "unknown", "",
			"", errBody("FORBIDDEN", "token carries no tenant (claim 'tenant' or group '/tenants/{tenant}')"))
		return
	}

	// 3b) Rate-limit the authenticated principal (actor+tenant) on the SHARED
	//     management plane: one tenant's dev must not flood it and starve others.
	//     The DENY is audited like any other refusal (the burst is a security
	//     signal), with HTTP 429.
	if !s.Limiter.allow(actor+"|"+tokenTenant, time.Now()) {
		emit(http.StatusTooManyRequests, audit.Deny, "rate_limited", actor, tokenTenant, "",
			"", errBody("RATE_LIMITED", "too many onboarding requests for this principal; retry shortly"))
		return
	}

	// 4) Parse the body. A bad body is audited under the token tenant (we know
	//    the authenticated caller) so the DENY is attributable.
	var req onboarding.Request
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		emit(http.StatusBadRequest, audit.Deny, "invalid_body", actor, tokenTenant, "",
			"", errBody("INVALID_BODY", err.Error()))
		return
	}

	// 5) RBAC multi-tenant: the body tenant MUST equal the token tenant. A
	//    mismatch is the cross-tenant attack the X-Actor-* design could not stop;
	//    it is refused 403 BEFORE any Git write.
	if req.Tenant != tokenTenant {
		emit(http.StatusForbidden, audit.Deny, "tenant_mismatch", actor, tokenTenant, req.Name,
			"", errBody("FORBIDDEN", "body tenant does not match the token tenant"))
		return
	}

	// 6) Commit the manifest as the VALIDATED actor.
	result, verrs, err := s.Svc.Onboard(ctx, req, id.ToActor())
	if len(verrs) > 0 {
		emit(http.StatusBadRequest, audit.Deny, "validation_failed", actor, tokenTenant, req.Name,
			"", map[string]any{"error": "VALIDATION_FAILED", "fields": verrs})
		return
	}
	if err != nil {
		emit(http.StatusInternalServerError, audit.Deny, "write_failed", actor, tokenTenant, req.Name,
			"", errBody("WRITE_FAILED", err.Error()))
		return
	}

	status := http.StatusOK
	if result.Created {
		status = http.StatusCreated
	}
	emit(status, audit.Accept, "ok", actor, tokenTenant, req.Name, result.Commit.SHA, result)
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func errBody(code, msg string) map[string]string {
	return map[string]string{"error": code, "message": msg}
}
