package main

import "github.com/stoa-platform/stoa-labs/poc/labctl/internal/authz"

// RequiredRole is the realm role a token MUST carry to onboard a partner. The
// onboarding-api is a partner-management surface, so the role names the
// capability, not a tenant — tenant scope comes from the token's tenant claim/
// group, enforced separately against the body. The authorization kernel itself
// (bearer extraction, role check, tenant derivation, caller IP) lives in the
// shared internal/authz package, reused by the apply plane.
const RequiredRole = authz.RolePartnerOnboarder
