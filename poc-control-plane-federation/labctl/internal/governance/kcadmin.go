package governance

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

// KCAdmin speaks the Keycloak Admin REST API for the users/roles screens,
// using the same mechanics as internal/keycloak (password grant on the
// master realm with the built-in admin-cli public client — PoC credentials).
type KCAdmin struct {
	Base          string // e.g. http://localhost:8480 (no trailing slash)
	Realm         string // e.g. stoa-lab
	AdminUser     string
	AdminPassword string

	client *http.Client
}

// NewKCAdmin builds the admin client.
func NewKCAdmin(base, realm, user, password string) *KCAdmin {
	return &KCAdmin{
		Base:          strings.TrimRight(base, "/"),
		Realm:         realm,
		AdminUser:     user,
		AdminPassword: password,
		client:        &http.Client{Timeout: 10 * time.Second},
	}
}

// KCUser is one GET /users element.
type KCUser struct {
	ID        string   `json:"id"`
	Username  string   `json:"username"`
	Email     string   `json:"email"`
	Roles     []string `json:"roles"`
	Tenant    string   `json:"tenant,omitempty"`
	Federated bool     `json:"federated"`
}

// rawUser is the Keycloak UserRepresentation subset we read.
type rawUser struct {
	ID             string              `json:"id"`
	Username       string              `json:"username"`
	Email          string              `json:"email"`
	FederationLink string              `json:"federationLink"`
	Attributes     map[string][]string `json:"attributes"`
}

// roleRep is the Keycloak RoleRepresentation subset.
type roleRep struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// token obtains an admin access token from the master realm.
func (k *KCAdmin) token(ctx context.Context) (string, error) {
	endpoint := k.Base + "/realms/master/protocol/openid-connect/token"
	form := url.Values{
		"client_id":  {"admin-cli"},
		"username":   {k.AdminUser},
		"password":   {k.AdminPassword},
		"grant_type": {"password"},
	}
	headers := map[string]string{
		"Content-Type": "application/x-www-form-urlencoded",
		"Accept":       "application/json",
	}
	code, raw, err := httpx.Do(ctx, k.client, "POST", endpoint, headers, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	if code < 200 || code >= 300 {
		return "", fmt.Errorf("POST %s -> %d", endpoint, code)
	}
	var tr struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.Unmarshal(raw, &tr); err != nil || tr.AccessToken == "" {
		return "", fmt.Errorf("keycloak admin: token response carried no access_token")
	}
	return tr.AccessToken, nil
}

func (k *KCAdmin) realmURL(parts ...string) string {
	segs := make([]string, 0, len(parts))
	for _, p := range parts {
		segs = append(segs, url.PathEscape(p))
	}
	return k.Base + "/admin/realms/" + url.PathEscape(k.Realm) + "/" + strings.Join(segs, "/")
}

// governanceRole reports whether name is one of the console-managed roles.
func governanceRole(name string) bool {
	for _, r := range GovernanceRoles {
		if r == name {
			return true
		}
	}
	return false
}

// userRoles reads the user's realm role-mappings filtered to the governance
// roles (default-roles-*, offline_access etc. stay out of the console).
func (k *KCAdmin) userRoles(ctx context.Context, auth map[string]string, userID string) ([]string, error) {
	var reps []roleRep
	if _, err := httpx.JSON(ctx, k.client, "GET", k.realmURL("users", userID, "role-mappings", "realm"), auth, nil, &reps); err != nil {
		return nil, err
	}
	roles := []string{}
	for _, r := range reps {
		if governanceRole(r.Name) {
			roles = append(roles, r.Name)
		}
	}
	return roles, nil
}

// projectUser maps a raw Keycloak user (plus its roles) onto the API shape.
func (k *KCAdmin) projectUser(ctx context.Context, auth map[string]string, u rawUser) KCUser {
	out := KCUser{ID: u.ID, Username: u.Username, Email: u.Email, Roles: []string{}}
	if roles, err := k.userRoles(ctx, auth, u.ID); err == nil {
		out.Roles = roles
	}
	if t, ok := u.Attributes["tenant"]; ok && len(t) > 0 {
		out.Tenant = t[0]
	}
	if u.FederationLink != "" {
		out.Federated = true
	} else {
		var fed []map[string]any
		if _, err := httpx.JSON(ctx, k.client, "GET", k.realmURL("users", u.ID, "federated-identity"), auth, nil, &fed); err == nil && len(fed) > 0 {
			out.Federated = true
		}
	}
	return out
}

// ListUsers returns the realm users with their governance roles, tenant
// attribute and federation flag (GET /users).
func (k *KCAdmin) ListUsers(ctx context.Context) ([]KCUser, error) {
	tok, err := k.token(ctx)
	if err != nil {
		return nil, err
	}
	auth := map[string]string{"Authorization": "Bearer " + tok}
	var raws []rawUser
	if _, err := httpx.JSON(ctx, k.client, "GET", k.realmURL("users")+"?max=500", auth, nil, &raws); err != nil {
		return nil, err
	}
	out := make([]KCUser, 0, len(raws))
	for _, u := range raws {
		out = append(out, k.projectUser(ctx, auth, u))
	}
	return out, nil
}

// GetUser returns one user by id (used to echo the updated user).
func (k *KCAdmin) GetUser(ctx context.Context, id string) (*KCUser, error) {
	tok, err := k.token(ctx)
	if err != nil {
		return nil, err
	}
	auth := map[string]string{"Authorization": "Bearer " + tok}
	var u rawUser
	if _, err := httpx.JSON(ctx, k.client, "GET", k.realmURL("users", id), auth, nil, &u); err != nil {
		return nil, err
	}
	user := k.projectUser(ctx, auth, u)
	return &user, nil
}

// SetUserRoles converges the user's governance realm roles onto want
// (add the missing, remove the extra; non-governance roles untouched).
func (k *KCAdmin) SetUserRoles(ctx context.Context, userID string, want []string) error {
	for _, r := range want {
		if !governanceRole(r) {
			return fmt.Errorf("unknown role %q (allowed: %s)", r, strings.Join(GovernanceRoles, ", "))
		}
	}
	tok, err := k.token(ctx)
	if err != nil {
		return err
	}
	auth := map[string]string{"Authorization": "Bearer " + tok}

	var all []roleRep
	if _, err := httpx.JSON(ctx, k.client, "GET", k.realmURL("roles")+"?max=200", auth, nil, &all); err != nil {
		return fmt.Errorf("list realm roles: %w", err)
	}
	byName := map[string]roleRep{}
	for _, r := range all {
		byName[r.Name] = r
	}

	current, err := k.userRoles(ctx, auth, userID)
	if err != nil {
		return fmt.Errorf("read user roles: %w", err)
	}
	cur := map[string]bool{}
	for _, r := range current {
		cur[r] = true
	}
	wantSet := map[string]bool{}
	for _, r := range want {
		wantSet[r] = true
	}

	var toAdd, toRemove []roleRep
	for r := range wantSet {
		if !cur[r] {
			rep, ok := byName[r]
			if !ok {
				return fmt.Errorf("realm role %q does not exist in Keycloak", r)
			}
			toAdd = append(toAdd, rep)
		}
	}
	for r := range cur {
		if !wantSet[r] {
			if rep, ok := byName[r]; ok {
				toRemove = append(toRemove, rep)
			}
		}
	}

	mappingURL := k.realmURL("users", userID, "role-mappings", "realm")
	if len(toAdd) > 0 {
		if _, err := httpx.JSON(ctx, k.client, "POST", mappingURL, auth, toAdd, nil); err != nil {
			return fmt.Errorf("add roles: %w", err)
		}
	}
	if len(toRemove) > 0 {
		if _, err := httpx.JSON(ctx, k.client, "DELETE", mappingURL, auth, toRemove, nil); err != nil {
			return fmt.Errorf("remove roles: %w", err)
		}
	}
	return nil
}

// RoleUserCounts returns user counts per governance role (GET /roles).
func (k *KCAdmin) RoleUserCounts(ctx context.Context) (map[string]int, error) {
	tok, err := k.token(ctx)
	if err != nil {
		return nil, err
	}
	auth := map[string]string{"Authorization": "Bearer " + tok}
	out := map[string]int{}
	for _, role := range GovernanceRoles {
		var users []struct {
			ID string `json:"id"`
		}
		if _, err := httpx.JSON(ctx, k.client, "GET", k.realmURL("roles", role, "users")+"?max=1000", auth, nil, &users); err != nil {
			out[role] = 0
			continue
		}
		out[role] = len(users)
	}
	return out, nil
}
