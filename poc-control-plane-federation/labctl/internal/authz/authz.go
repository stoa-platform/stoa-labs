// Package authz is the SHARED control-plane authorization kernel: the OAuth2
// bearer extraction, RBAC role check, tenant derivation and caller-IP helpers
// used by BOTH management surfaces — the self-service write plane
// (cmd/onboarding-api) and the converge/apply plane (cmd/labctl apply-uac /
// subscribe). Extracting them here means there is ONE implementation of "who is
// the caller, what role do they hold, which tenant do they act for" — a single
// place to audit and reason about, instead of one copy per binary.
//
// It owns NO transport: it operates on a *governance.Identity already produced
// by governance.Verifier (local JWKS RS256, air-gapped) and on *http.Request for
// the HTTP plane. The CLI plane reuses the Identity-level helpers (HasRole,
// TenantOf) after verifying a service-account token with the same Verifier.
package authz

import (
	"context"
	"net"
	"net/http"
	"strings"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/governance"
)

// Realm roles gating the two control-plane surfaces. The role names a
// CAPABILITY, never a tenant — tenant scope is the token's tenant claim/group,
// enforced separately (TenantOf + the per-surface tenant match).
const (
	// RolePartnerOnboarder gates the self-service write plane (POST /applications).
	RolePartnerOnboarder = "partner-onboarder"
	// RoleCPApplier gates the converge/apply plane: the CI service-account that
	// runs `labctl apply-uac` against the shared gateways with platform creds.
	RoleCPApplier = "cp-applier"
)

// TokenVerifier is the subset of governance.Verifier the surfaces need, narrowed
// to an interface so tests inject a fake verifier (no live Keycloak / JWKS).
type TokenVerifier interface {
	Verify(ctx context.Context, token string) (*governance.Identity, error)
}

// BearerToken extracts the raw token from an "Authorization: Bearer <t>" header.
// It returns ("", false) when the header is absent or not a Bearer scheme — the
// no-token 401 path.
func BearerToken(r *http.Request) (string, bool) {
	h := strings.TrimSpace(r.Header.Get("Authorization"))
	if h == "" {
		return "", false
	}
	const pfx = "Bearer "
	if len(h) <= len(pfx) || !strings.EqualFold(h[:len(pfx)], pfx) {
		return "", false
	}
	tok := strings.TrimSpace(h[len(pfx):])
	if tok == "" {
		return "", false
	}
	return tok, true
}

// HasRole reports whether the identity carries the given realm role.
func HasRole(id *governance.Identity, role string) bool {
	for _, r := range id.Roles {
		if r == role {
			return true
		}
	}
	return false
}

// TenantOf derives the caller's tenant from the VALIDATED token, supporting BOTH
// supported encodings (in priority order):
//
//  1. a flat `tenant` claim (the onboarding-dev / cp-applier mapper writes this); or
//  2. membership of a single `/tenants/{tenant}` group (the Keycloak group
//     convention ADR-070 maps onto OpenSearch backend roles).
//
// It returns ("", false) when the token carries NO tenant — a token with the
// role but no tenant is unscoped and must be refused (403), never defaulted.
// Multiple distinct tenant groups are ambiguous and also rejected: a single
// management request acts for exactly one tenant.
func TenantOf(id *governance.Identity) (string, bool) {
	if t := strings.TrimSpace(id.Tenant); t != "" {
		return t, true
	}
	const pfx = "/tenants/"
	tenant := ""
	for _, g := range id.Groups {
		g = strings.TrimSpace(g)
		if !strings.HasPrefix(g, pfx) {
			continue
		}
		name := strings.Trim(strings.TrimPrefix(g, pfx), "/")
		// Only a leaf "/tenants/{tenant}" (no further nesting) is a tenant scope.
		if name == "" || strings.Contains(name, "/") {
			continue
		}
		if tenant != "" && tenant != name {
			return "", false // ambiguous: two different tenants
		}
		tenant = name
	}
	if tenant == "" {
		return "", false
	}
	return tenant, true
}

// TenantOrUnknown derives the tenant for AUDIT purposes on a failure path where
// a missing tenant should not abort the audit record (e.g. a role failure before
// the tenant is even relevant). It never gates a decision — only labels a record.
func TenantOrUnknown(id *governance.Identity) string {
	if t, ok := TenantOf(id); ok {
		return t
	}
	return "unknown"
}

// ActorName prefers the validated preferred_username, falling back to the JWT
// subject — the stable identifier of the authenticated caller for the audit log.
func ActorName(id *governance.Identity) string {
	if id.Username != "" && id.Username != "unknown" {
		return id.Username
	}
	if id.Subject != "" {
		return id.Subject
	}
	return id.Username
}

// ClientIP extracts the caller IP for the audit record: the first
// X-Forwarded-For hop when fronted by a gateway, else the TCP remote addr.
// Never trusted for authorization — only recorded.
func ClientIP(r *http.Request) string {
	if xff := strings.TrimSpace(r.Header.Get("X-Forwarded-For")); xff != "" {
		if i := strings.IndexByte(xff, ','); i >= 0 {
			return strings.TrimSpace(xff[:i])
		}
		return xff
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
