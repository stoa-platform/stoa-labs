package cmd

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/authz"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/governance"
)

// principal is the verified identity acting on the management/apply plane: a CI
// service account presenting LABCTL_TOKEN (a cp-applier token). It is the bridge
// that makes the apply plane attributable and tenant-bound even though the
// gateway only ever sees the platform admin credential.
type principal struct {
	Actor  string // preferred_username / sub of the verified token
	Tenant string // tenant the token is scoped to (claim or /tenants/{t} group)
	OK     bool   // a verified principal was presented
}

// resolvePrincipal verifies an OPTIONAL LABCTL_TOKEN against the realm and
// returns the bound principal. An absent token yields ({OK:false}, nil) — the
// unauthenticated operator path (weaker, must rely on --tenant). A present token
// MUST validate, carry the cp-applier role, and carry exactly one tenant; any of
// those failing is a hard error (fail-closed: we never apply with a half-trusted
// principal). The Verifier reaches the IdP only — the apply plane's sole control
// egress besides the gateways.
func resolvePrincipal(ctx context.Context, v authz.TokenVerifier, token string) (principal, error) {
	token = strings.TrimSpace(token)
	if token == "" {
		return principal{}, nil
	}
	id, err := v.Verify(ctx, token)
	if err != nil {
		return principal{}, fmt.Errorf("LABCTL_TOKEN verification failed: %w", err)
	}
	if !authz.HasRole(id, authz.RoleCPApplier) {
		return principal{}, fmt.Errorf("LABCTL_TOKEN lacks the required role %q (the apply plane is gated by cp-applier)", authz.RoleCPApplier)
	}
	t, ok := authz.TenantOf(id)
	if !ok {
		return principal{}, fmt.Errorf("LABCTL_TOKEN carries no tenant (claim 'tenant' or group '/tenants/{tenant}') — an unscoped apply principal is refused")
	}
	return principal{Actor: authz.ActorName(id), Tenant: t, OK: true}, nil
}

// resolveScope computes the tenant scope this run may apply, and refuses a
// cross-tenant escalation. The scope is the tenant whose contracts will be
// projected; "" means UNSCOPED (every tenant — operator-trust mode, only
// reachable without a principal token, and the caller warns on it).
//
// Rules, in order:
//  1. A verified principal token BINDS the scope to its tenant. A --tenant that
//     names a DIFFERENT tenant is a cross-tenant attempt → error (the DENY):
//     holding the platform gateway creds must not let a banking job touch the
//     payments tenant. A --tenant equal to the token tenant is redundant-but-ok.
//  2. No principal, --tenant set: operator-selected scope (not cryptographically
//     bound, but still narrows the blast radius and is audited).
//  3. Neither: unscoped.
func resolveScope(p principal, flagTenant string) (string, error) {
	flagTenant = strings.TrimSpace(flagTenant)
	if p.OK {
		if flagTenant != "" && flagTenant != p.Tenant {
			return "", fmt.Errorf("cross-tenant denied: cp-applier principal %q is scoped to tenant %q and may not apply tenant %q",
				p.Actor, p.Tenant, flagTenant)
		}
		return p.Tenant, nil
	}
	return flagTenant, nil
}

// inScope reports whether a contract's tenant is within the resolved scope. An
// empty scope ("" = unscoped) admits every tenant.
func inScope(scope, tenant string) bool { return scope == "" || scope == tenant }

// applyVerifier builds the apply plane's token verifier from the environment
// (same realm/JWKS the onboarding plane uses; air-gapped local RS256). It is
// only exercised when LABCTL_TOKEN is set — construction performs no network I/O.
func applyVerifier() authz.TokenVerifier {
	kc := envOr("KEYCLOAK_URL", "http://localhost:8480")
	realm := envOr("KEYCLOAK_REALM", "stoa-lab")
	aud := envOr("LABCTL_AUDIENCE", "onboarding-api")
	v := governance.NewVerifierWithAudience(kc, realm, aud)
	// Split-horizon (CI inside the docker network): Keycloak pins a fixed
	// frontend URL, so the token's `iss` stays http://localhost:8480 even when the
	// token is minted via the in-network keycloak:8080. The issuer check must
	// match that `iss` (KEYCLOAK_URL), but the JWKS must be FETCHED from a
	// reachable URL — set KEYCLOAK_JWKS_URL to the in-network certs endpoint.
	if jwks := envOr("KEYCLOAK_JWKS_URL", ""); jwks != "" {
		v.JWKSURL = jwks
	}
	return v
}

// envOr reads an env var with a default.
func envOr(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

// applyToken returns the CI principal bearer for the apply plane. It prefers
// LABCTL_TOKEN_FILE (the path to a 0600 file holding the token) over LABCTL_TOKEN
// so the token NEVER has to appear in the process environment, on a command line,
// or in a CI log (a minted OAuth token is a live credential — keep it off the
// console). Whitespace is trimmed. Empty when neither is set (unauthenticated
// operator path).
func applyToken() string {
	if t := strings.TrimSpace(os.Getenv("LABCTL_TOKEN")); t != "" {
		return t
	}
	if f := strings.TrimSpace(os.Getenv("LABCTL_TOKEN_FILE")); f != "" {
		if b, err := os.ReadFile(f); err == nil {
			return strings.TrimSpace(string(b))
		}
	}
	return ""
}

// boolEnvDefault reads a boolean env var, falling back to def on absent/invalid.
func boolEnvDefault(key string, def bool) bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(key))) {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	default:
		return def
	}
}
