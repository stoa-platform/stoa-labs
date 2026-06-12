// Package governance is the engine behind cmd/governance-api: RBAC mirroring
// the Console Light contract (API-CONTRACT.md §2), JWT verification against
// Keycloak's JWKS, and a Git-backed store where every validated action is a
// signed commit (§3). Source of truth: console-light/API-CONTRACT.md.
package governance

import "sort"

// Identity is the authenticated caller, projected from the verified JWT
// (preferred_username, sub, name, email, realm_access.roles, tenant, groups).
type Identity struct {
	Username string   `json:"username"`
	Subject  string   `json:"subject"`
	Name     string   `json:"name"`
	Email    string   `json:"email"`
	Roles    []string `json:"roles"`
	Tenant   string   `json:"tenant"`
	Groups   []string `json:"groups"`
}

// Actor is the commit author: every governed write is committed with
// author = the human actor, committer = governance-bot (contract §3 rule 2).
type Actor struct {
	Username string
	Name     string
	Email    string
	Roles    []string
}

// ToActor projects the identity onto a Git commit author, with safe fallbacks
// so git never rejects an empty ident.
func (id Identity) ToActor() Actor {
	name := id.Name
	if name == "" {
		name = id.Username
	}
	if name == "" {
		name = "unknown"
	}
	email := id.Email
	if email == "" {
		u := id.Username
		if u == "" {
			u = "unknown"
		}
		email = u + "@stoa.local"
	}
	return Actor{Username: id.Username, Name: name, Email: email, Roles: id.Roles}
}

// rolePermissions is the contract §2 matrix, verbatim. The BFF is the
// authority: the UI only hides buttons.
var rolePermissions = map[string][]string{
	"cpi-admin": {
		"apis:read", "apis:update", "apis:publish",
		"promotions:read", "promotions:request", "promotions:approve",
		"subscriptions:read", "subscriptions:approve",
		"audit:read", "audit:export",
		"tenants:read", "targets:read",
		"users:read", "users:manage",
	},
	"tenant-admin": {
		"apis:read", "apis:update", "apis:publish",
		"promotions:read", "promotions:request",
		"subscriptions:read", "subscriptions:approve",
		"audit:read", "audit:export",
		"tenants:read", "targets:read",
	},
	"devops": {
		"apis:read",
		"promotions:read", "promotions:approve",
		"subscriptions:read",
		"audit:read",
		"tenants:read", "targets:read",
	},
	"viewer": {
		"apis:read",
		"promotions:read",
		"subscriptions:read",
		"audit:read",
		"tenants:read", "targets:read",
	},
}

// GovernanceRoles are the realm roles the console manages, in display order.
var GovernanceRoles = []string{"cpi-admin", "tenant-admin", "devops", "viewer"}

// RoleDescriptions are the static French descriptions served by GET /roles.
var RoleDescriptions = map[string]string{
	"cpi-admin":    "Administrateur plateforme — accès complet multi-tenant (tenants, utilisateurs, cibles de fédération).",
	"tenant-admin": "Administrateur de tenant — édite et publie les contrats de SON tenant, demande des promotions, approuve les souscriptions.",
	"devops":       "Approbateur — approuve ou rejette les promotions (principe des 4 yeux), lecture sur le reste.",
	"viewer":       "Auditeur / sécurité — lecture seule (contrats, promotions, audit) ; n'écrit rien.",
}

// PermissionsFor flattens the role set into a deduplicated, sorted permission
// list (the `permissions[]` of GET /me).
func PermissionsFor(roles []string) []string {
	seen := map[string]bool{}
	for _, r := range roles {
		for _, p := range rolePermissions[r] {
			seen[p] = true
		}
	}
	out := make([]string, 0, len(seen))
	for p := range seen {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// HasPermission reports whether any of the caller's roles grants perm.
func HasPermission(roles []string, perm string) bool {
	for _, r := range roles {
		for _, p := range rolePermissions[r] {
			if p == perm {
				return true
			}
		}
	}
	return false
}

// RolePermissions returns the permission list of one role (GET /roles).
func RolePermissions(role string) []string {
	perms := rolePermissions[role]
	out := make([]string, len(perms))
	copy(out, perms)
	return out
}

// IsCPIAdmin reports the all-tenants scope (contract §2: cpi-admin sees
// everything and may pass ?tenant= on list endpoints).
func IsCPIAdmin(roles []string) bool {
	for _, r := range roles {
		if r == "cpi-admin" {
			return true
		}
	}
	return false
}

// CanAccessTenant applies the tenant scoping rule: tenant-admin/devops/viewer
// only see the tenant of their `tenant` claim; cpi-admin sees all.
func CanAccessTenant(id Identity, tenant string) bool {
	if IsCPIAdmin(id.Roles) {
		return true
	}
	return id.Tenant != "" && id.Tenant == tenant
}
