package governance

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"sort"
	"strings"

	"sigs.k8s.io/yaml"
)

// Store layers the governance domain (contract §3 file layout) on top of the
// Git repo: tenants/{t}/tenant.yaml, tenants/{t}/apis/{slug}/api.yaml +
// deploy.{env}.yaml, promotions/{t}/{id}.yaml, subscriptions/{t}/{id}.yaml,
// evidence/{t}/{slug}/{action}-{NNN}.{json,md}.
type Store struct {
	Repo *Repo
}

// Environments is the DEFAULT promotion chain (dev -> staging -> production),
// used when the repo carries no environments.yaml (see envchain.go).
var Environments = []string{"dev", "staging", "production"}

// Tenant is one GET /tenants element.
type Tenant struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	DisplayName string `json:"displayName"`
	Tier        string `json:"tier"`
	Status      string `json:"status"`
	APIsCount   int    `json:"apis_count"`
}

// ContractSummary is one GET /tenants/{t}/contracts element.
type ContractSummary struct {
	Slug           string      `json:"slug"`
	Name           string      `json:"name"`
	Version        string      `json:"version"`
	Status         string      `json:"status"`
	Classification string      `json:"classification"`
	EndpointsCount int         `json:"endpoints_count"`
	UpdatedAt      string      `json:"updated_at"`
	LastCommit     *LastCommit `json:"last_commit"`
}

// LastCommit is the compact commit echo on contract listings.
type LastCommit struct {
	SHA7   string `json:"sha7"`
	Author string `json:"author"`
	Date   string `json:"date"`
}

// Version is one entry of the contract history tab.
type Version struct {
	SHA     string `json:"sha"`
	SHA7    string `json:"sha7"`
	Author  string `json:"author"`
	Date    string `json:"date"`
	Message string `json:"message"`
	Signed  bool   `json:"signed"`
}

// Deployment is the desired state per environment (deploy.{env}.yaml).
// Commit pins the api.yaml main SHA the promotion was requested against —
// real version pinning, re-checked at approval (CONTRACT_MOVED).
type Deployment struct {
	Version    string `json:"version"`
	Enabled    bool   `json:"enabled"`
	PromotedBy string `json:"promoted_by"`
	Message    string `json:"message,omitempty"`
	Commit     string `json:"commit,omitempty"`
	// ChangeRef records the ITSM change that authorised this dispatched state
	// (the promotion's change_ref). It makes the marker self-describing so the
	// dispatch gate (A6) can re-check ITSM LIVE against the state it projects,
	// closing the TOCTOU between merge/build and dispatch.
	ChangeRef string `json:"change_ref,omitempty"`
}

// Promotion mirrors promotions/{t}/{id}.yaml. Its status IS its position in
// Git (§3 rule 6): open branch = pending, merged marker = approved, rejected
// marker on main = rejected.
type Promotion struct {
	ID          string `json:"id"`
	Slug        string `json:"slug"`
	From        string `json:"from"`
	To          string `json:"to"`
	RequestedBy string `json:"requested_by"`
	Message     string `json:"message"`
	Status      string `json:"status"`
	CreatedAt   string `json:"created_at"`
	Branch      string `json:"branch,omitempty"`
	ApprovedBy  string `json:"approved_by,omitempty"`
	ApprovedAt  string `json:"approved_at,omitempty"`
	Reason      string `json:"reason,omitempty"`
	// ChangeRef / PVRef are the external references the target gate may
	// require (requireChangeRef / requirePVRef in environments.yaml).
	ChangeRef string `json:"change_ref,omitempty"`
	PVRef     string `json:"pv_ref,omitempty"`
}

// Subscription mirrors subscriptions/{t}/{id}.yaml.
type Subscription struct {
	ID          string `json:"id"`
	Tenant      string `json:"tenant"`
	API         string `json:"api"`
	Consumer    string `json:"consumer"`
	RequestedBy string `json:"requested_by"`
	Status      string `json:"status"`
	CreatedAt   string `json:"created_at,omitempty"`
	Reason      string `json:"reason,omitempty"`
}

// ---- paths ----

func tenantYAMLPath(t string) string { return "tenants/" + t + "/tenant.yaml" }

func contractPath(t, slug string) string { return "tenants/" + t + "/apis/" + slug + "/api.yaml" }

func deployPath(t, slug, env string) string {
	return "tenants/" + t + "/apis/" + slug + "/deploy." + env + ".yaml"
}

func promotionPath(t, id string) string { return "promotions/" + t + "/" + id + ".yaml" }

func subscriptionPath(t, id string) string { return "subscriptions/" + t + "/" + id + ".yaml" }

func promotionBranch(t, slug, id string) string {
	return "stoa/promote/" + t + "/" + slug + "/" + id
}

// DenialsPath is the append-only RBAC denial trail (contract §2).
const DenialsPath = "evidence/denials/denials.jsonl"

// ---- tenants ----

// ListTenants reads tenants/*/tenant.yaml on main. Unknown fields fall back
// to the directory name so a minimal seed still lists.
func (s *Store) ListTenants(ctx context.Context) ([]Tenant, error) {
	ids, err := s.Repo.ListDir(ctx, "main", "tenants")
	if err != nil {
		return nil, err
	}
	out := make([]Tenant, 0, len(ids))
	for _, id := range ids {
		t := Tenant{ID: id, Name: id, DisplayName: id, Status: "active"}
		if raw, err := s.Repo.ReadFile(ctx, "main", tenantYAMLPath(id)); err == nil {
			var m map[string]any
			if yaml.Unmarshal(raw, &m) == nil {
				// The seed writes a K8s-style manifest (metadata/spec); accept
				// flat keys too.
				flat := m
				if meta, ok := m["metadata"].(map[string]any); ok {
					flat = meta
				}
				if v, _ := flat["name"].(string); v != "" {
					t.Name = v
				}
				if v, _ := flat["displayName"].(string); v != "" {
					t.DisplayName = v
				} else if v, _ := flat["display_name"].(string); v != "" {
					t.DisplayName = v
				}
				if v, _ := flat["tier"].(string); v != "" {
					t.Tier = v
				}
				if v, _ := m["status"].(string); v != "" {
					t.Status = v
				} else if spec, ok := m["spec"].(map[string]any); ok {
					if v, _ := spec["status"].(string); v != "" {
						t.Status = v
					}
				}
			}
		}
		slugs, _ := s.Repo.ListDir(ctx, "main", "tenants/"+id+"/apis")
		t.APIsCount = len(slugs)
		out = append(out, t)
	}
	return out, nil
}

// TenantExists checks the tenant directory on main.
func (s *Store) TenantExists(ctx context.Context, tenant string) bool {
	return s.Repo.Exists(ctx, "main", tenantYAMLPath(tenant)) ||
		s.Repo.Exists(ctx, "main", "tenants/"+tenant+"/apis")
}

// ---- contracts ----

// ReadContract parses api.yaml at ref into a JSON-compatible object.
func (s *Store) ReadContract(ctx context.Context, ref, tenant, slug string) (map[string]any, error) {
	raw, err := s.Repo.ReadFile(ctx, ref, contractPath(tenant, slug))
	if err != nil {
		return nil, err
	}
	var m map[string]any
	if err := yaml.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("parse %s: %w", contractPath(tenant, slug), err)
	}
	return m, nil
}

// ListContracts builds the catalogue rows for one tenant from main.
func (s *Store) ListContracts(ctx context.Context, tenant string) ([]ContractSummary, error) {
	slugs, err := s.Repo.ListDir(ctx, "main", "tenants/"+tenant+"/apis")
	if err != nil {
		return nil, err
	}
	out := make([]ContractSummary, 0, len(slugs))
	for _, slug := range slugs {
		c, err := s.ReadContract(ctx, "main", tenant, slug)
		if err != nil {
			continue // tolerate stray dirs in the seed
		}
		sum := ContractSummary{Slug: slug}
		sum.Name, _ = c["name"].(string)
		if sum.Name == "" {
			sum.Name = slug
		}
		sum.Version, _ = c["version"].(string)
		sum.Status, _ = c["status"].(string)
		sum.Classification, _ = c["classification"].(string)
		if eps, ok := c["endpoints"].([]any); ok {
			sum.EndpointsCount = len(eps)
		}
		if hist, err := s.Repo.Log(ctx, []string{"main"}, []string{contractPath(tenant, slug)}, 1); err == nil && len(hist) > 0 {
			sum.UpdatedAt = hist[0].Date
			sum.LastCommit = &LastCommit{SHA7: hist[0].SHA7, Author: hist[0].Author, Date: hist[0].Date}
		}
		out = append(out, sum)
	}
	return out, nil
}

// ContractVersions is the git history of one api.yaml on main.
func (s *Store) ContractVersions(ctx context.Context, tenant, slug string) ([]Version, error) {
	hist, err := s.Repo.Log(ctx, []string{"main"}, []string{contractPath(tenant, slug)}, 0)
	if err != nil {
		return nil, err
	}
	out := make([]Version, 0, len(hist))
	for _, h := range hist {
		out = append(out, Version{SHA: h.SHA, SHA7: h.SHA7, Author: h.Author, Date: h.Date, Message: h.Message, Signed: h.Signed})
	}
	return out, nil
}

// Deployments reads deploy.{env}.yaml per environment of the configured chain
// (nil when absent). Chain-aware: environments.yaml drives the env list, the
// default chain is the fallback.
func (s *Store) Deployments(ctx context.Context, tenant, slug string) (map[string]*Deployment, error) {
	chain, err := s.EnvChain(ctx)
	if err != nil {
		return nil, err
	}
	out := map[string]*Deployment{}
	for _, env := range chain.Envs {
		out[env] = nil
		if d, err := s.ReadDeployment(ctx, "main", tenant, slug, env); err == nil {
			out[env] = d
		}
	}
	return out, nil
}

// ReadDeployment decodes one deploy.{env}.yaml at ref.
func (s *Store) ReadDeployment(ctx context.Context, ref, tenant, slug, env string) (*Deployment, error) {
	raw, err := s.Repo.ReadFile(ctx, ref, deployPath(tenant, slug, env))
	if err != nil {
		return nil, err
	}
	var d Deployment
	if err := yaml.Unmarshal(raw, &d); err != nil {
		return nil, fmt.Errorf("parse %s@%s: %w", deployPath(tenant, slug, env), ref, err)
	}
	return &d, nil
}

// ContractHeadSHA is the SHA of the last main commit touching api.yaml — the
// pin written at promotion request and re-checked at approval.
func (s *Store) ContractHeadSHA(ctx context.Context, tenant, slug string) (string, error) {
	hist, err := s.Repo.Log(ctx, []string{"main"}, []string{contractPath(tenant, slug)}, 1)
	if err != nil {
		return "", err
	}
	if len(hist) == 0 {
		return "", fmt.Errorf("contract %s/%s: no history on main", tenant, slug)
	}
	return hist[0].SHA, nil
}

// MarshalYAML renders a JSON-tagged value as YAML (sigs.k8s.io/yaml).
func MarshalYAML(v any) ([]byte, error) { return yaml.Marshal(v) }

// ---- promotions ----

// parsePromotion decodes promotions/{t}/{id}.yaml at ref.
func (s *Store) parsePromotion(ctx context.Context, ref, tenant, id string) (*Promotion, error) {
	raw, err := s.Repo.ReadFile(ctx, ref, promotionPath(tenant, id))
	if err != nil {
		return nil, err
	}
	var p Promotion
	if err := yaml.Unmarshal(raw, &p); err != nil {
		return nil, fmt.Errorf("parse %s@%s: %w", promotionPath(tenant, id), ref, err)
	}
	return &p, nil
}

// FindPromotion resolves a promotion by id: first on an open branch
// (pending), else on main (approved/rejected marker). The returned branch
// name is set only while the branch is open.
func (s *Store) FindPromotion(ctx context.Context, tenant, id string) (*Promotion, error) {
	branches, err := s.Repo.BranchesUnder(ctx, "stoa/promote/"+tenant)
	if err == nil {
		for _, br := range branches {
			if !strings.HasSuffix(br, "/"+id) {
				continue
			}
			p, err := s.parsePromotion(ctx, br, tenant, id)
			if err != nil {
				return nil, err
			}
			p.Status = "pending"
			p.Branch = br
			return p, nil
		}
	}
	if s.Repo.Exists(ctx, "main", promotionPath(tenant, id)) {
		return s.parsePromotion(ctx, "main", tenant, id)
	}
	return nil, fmt.Errorf("promotion %s/%s not found", tenant, id)
}

// ListPromotions returns open-branch promotions (pending) plus the
// approved/rejected markers on main, newest first.
func (s *Store) ListPromotions(ctx context.Context, tenant string) ([]Promotion, error) {
	var out []Promotion
	seen := map[string]bool{}

	branches, err := s.Repo.BranchesUnder(ctx, "stoa/promote/"+tenant)
	if err != nil {
		return nil, err
	}
	for _, br := range branches {
		parts := strings.Split(br, "/")
		id := parts[len(parts)-1]
		p, err := s.parsePromotion(ctx, br, tenant, id)
		if err != nil {
			continue
		}
		p.Status = "pending"
		p.Branch = br
		out = append(out, *p)
		seen[p.ID] = true
	}

	ids, _ := s.Repo.ListDir(ctx, "main", "promotions/"+tenant)
	for _, f := range ids {
		id := strings.TrimSuffix(f, ".yaml")
		if id == f || seen[id] {
			continue
		}
		p, err := s.parsePromotion(ctx, "main", tenant, id)
		if err != nil {
			continue
		}
		out = append(out, *p)
	}

	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt > out[j].CreatedAt })
	return out, nil
}

// ---- subscriptions ----

// ListSubscriptions reads subscriptions/{tenant}/*.yaml on main (one tenant).
func (s *Store) ListSubscriptions(ctx context.Context, tenant string) ([]Subscription, error) {
	files, err := s.Repo.ListDir(ctx, "main", "subscriptions/"+tenant)
	if err != nil {
		return nil, err
	}
	out := make([]Subscription, 0, len(files))
	for _, f := range files {
		id := strings.TrimSuffix(f, ".yaml")
		if id == f {
			continue
		}
		sub, err := s.ReadSubscription(ctx, tenant, id)
		if err != nil {
			continue
		}
		out = append(out, *sub)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt > out[j].CreatedAt })
	return out, nil
}

// SubscriptionTenants lists the tenants that have subscriptions.
func (s *Store) SubscriptionTenants(ctx context.Context) ([]string, error) {
	return s.Repo.ListDir(ctx, "main", "subscriptions")
}

// ReadSubscription decodes one subscription, backfilling tenant/id and a
// created_at from the file's first commit when absent.
func (s *Store) ReadSubscription(ctx context.Context, tenant, id string) (*Subscription, error) {
	raw, err := s.Repo.ReadFile(ctx, "main", subscriptionPath(tenant, id))
	if err != nil {
		return nil, err
	}
	var sub Subscription
	if err := yaml.Unmarshal(raw, &sub); err != nil {
		return nil, fmt.Errorf("parse %s: %w", subscriptionPath(tenant, id), err)
	}
	if sub.ID == "" {
		sub.ID = id
	}
	if sub.Tenant == "" {
		sub.Tenant = tenant
	}
	if sub.CreatedAt == "" {
		if hist, err := s.Repo.Log(ctx, []string{"main"}, []string{subscriptionPath(tenant, id)}, 0); err == nil && len(hist) > 0 {
			sub.CreatedAt = hist[len(hist)-1].Date // first commit touching the file
		}
	}
	return &sub, nil
}

// FindSubscription locates a subscription id across the given tenants.
func (s *Store) FindSubscription(ctx context.Context, tenants []string, id string) (*Subscription, error) {
	for _, t := range tenants {
		if s.Repo.Exists(ctx, "main", subscriptionPath(t, id)) {
			return s.ReadSubscription(ctx, t, id)
		}
	}
	return nil, fmt.Errorf("subscription %s not found", id)
}

// ---- evidence ----

// NextEvidencePath allocates evidence/{tenant}/{slug}/{action}-{NNN}.json
// (NNN = zero-padded sequence per action, derived from what main already
// holds — deterministic, no state outside Git).
func (s *Store) NextEvidencePath(ctx context.Context, tenant, slug, action string) string {
	dir := "evidence/" + tenant + "/" + slug
	existing, _ := s.Repo.ListDir(ctx, "main", dir)
	n := 0
	prefix := action + "-"
	for _, f := range existing {
		if strings.HasPrefix(f, prefix) && strings.HasSuffix(f, ".json") {
			n++
		}
	}
	return fmt.Sprintf("%s/%s-%03d.json", dir, action, n+1)
}

// NewID mints a short random identifier (promotions, e.g. "pr-1a2b3c4d").
func NewID(prefix string) string {
	b := make([]byte, 4)
	if _, err := rand.Read(b); err != nil {
		return prefix + "-00000000"
	}
	return prefix + "-" + hex.EncodeToString(b)
}

// PromotionBranch exposes the §3 branch naming for one promotion.
func PromotionBranch(tenant, slug, id string) string { return promotionBranch(tenant, slug, id) }

// ContractPath / DeployPath / PromotionPath / SubscriptionPath expose the §3
// layout to the handlers.
func ContractPath(t, slug string) string { return contractPath(t, slug) }

func DeployPath(t, slug, env string) string { return deployPath(t, slug, env) }

func PromotionPath(t, id string) string { return promotionPath(t, id) }

func SubscriptionPath(t, id string) string { return subscriptionPath(t, id) }
