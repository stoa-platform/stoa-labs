package main

import (
	"fmt"
	"net/http"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/governance"
)

// handleTargets lists the federation gateways with a parallel health probe
// (GET /targets — 2s timeout, never blocking; empty list when no TARGETS_FILE).
func (s *Server) handleTargets(w http.ResponseWriter, r *http.Request, _ governance.Identity) {
	if s.TargetsFile == "" {
		writeJSON(w, http.StatusOK, []governance.TargetStatus{})
		return
	}
	ts, err := governance.LoadTargets(s.TargetsFile)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", "lecture TARGETS_FILE: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, governance.ProbeTargets(r.Context(), ts))
}

// handleUsers lists realm users with roles + tenant (GET /users, Keycloak
// Admin API — cpi-admin only via users:read).
func (s *Server) handleUsers(w http.ResponseWriter, r *http.Request, _ governance.Identity) {
	users, err := s.KC.ListUsers(r.Context())
	if err != nil {
		apiError(w, http.StatusBadGateway, "KEYCLOAK_UNAVAILABLE", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, users)
}

// handleUserRoles converges a user's governance roles in Keycloak and records
// the role-change as an audit commit (PUT /users/{id}/roles).
func (s *Server) handleUserRoles(w http.ResponseWriter, r *http.Request, id governance.Identity) {
	ctx := r.Context()
	userID := r.PathValue("id")
	var body struct {
		Roles []string `json:"roles"`
	}
	if err := readBody(r, &body, false); err != nil {
		apiError(w, http.StatusBadRequest, "BAD_REQUEST", err.Error())
		return
	}
	if body.Roles == nil {
		apiError(w, http.StatusBadRequest, "BAD_REQUEST", "champ 'roles' requis (liste, éventuellement vide)")
		return
	}
	if err := s.KC.SetUserRoles(ctx, userID, body.Roles); err != nil {
		apiError(w, http.StatusBadGateway, "KEYCLOAK_UNAVAILABLE", err.Error())
		return
	}
	user, err := s.KC.GetUser(ctx, userID)
	if err != nil {
		apiError(w, http.StatusBadGateway, "KEYCLOAK_UNAVAILABLE", err.Error())
		return
	}

	// The identity write lives in Keycloak; the AUDIT of the decision lives in
	// Git — an empty commit carrying the §3 trailers.
	actor := id.ToActor()
	msg := fmt.Sprintf("gov(platform): role-change %s", user.Username)
	trailers := governance.TrailerBlock("role-change", "platform/"+user.Username, actor, "")
	if _, err := s.Store.Repo.CommitEmpty(ctx, actor, msg, trailers); err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", "rôles mis à jour mais commit d'audit échoué: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"user": user})
}

// handleRoles serves the static §2 role definitions + Keycloak user counts
// (GET /roles — authenticated; counts fall back to 0 when KC is down).
func (s *Server) handleRoles(w http.ResponseWriter, r *http.Request, _ governance.Identity) {
	counts, err := s.KC.RoleUserCounts(r.Context())
	if err != nil {
		counts = map[string]int{}
	}
	out := make([]map[string]any, 0, len(governance.GovernanceRoles))
	for _, role := range governance.GovernanceRoles {
		out = append(out, map[string]any{
			"name":        role,
			"description": governance.RoleDescriptions[role],
			"permissions": governance.RolePermissions(role),
			"user_count":  counts[role],
		})
	}
	writeJSON(w, http.StatusOK, out)
}

// handleDashboard aggregates the governance overview (GET /dashboard),
// scoped to the caller's tenants.
func (s *Server) handleDashboard(w http.ResponseWriter, r *http.Request, id governance.Identity) {
	ctx := r.Context()

	tenants, err := s.Store.ListTenants(ctx)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}
	scoped := []governance.Tenant{}
	for _, t := range tenants {
		if governance.CanAccessTenant(id, t.ID) {
			scoped = append(scoped, t)
		}
	}

	contracts, pendingPromotions, pendingSubscriptions := 0, 0, 0
	for _, t := range scoped {
		contracts += t.APIsCount
		if promos, err := s.Store.ListPromotions(ctx, t.ID); err == nil {
			for _, p := range promos {
				if p.Status == "pending" {
					pendingPromotions++
				}
			}
		}
		if subs, err := s.Store.ListSubscriptions(ctx, t.ID); err == nil {
			for _, sub := range subs {
				if sub.Status == "pending" {
					pendingSubscriptions++
				}
			}
		}
	}

	lastCommits, err := s.collectAudit(r, id)
	if err != nil {
		lastCommits = []governance.AuditEntry{}
	}
	if len(lastCommits) > 5 {
		lastCommits = lastCommits[:5]
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"pending_promotions":    pendingPromotions,
		"pending_subscriptions": pendingSubscriptions,
		"contracts":             contracts,
		"tenants":               len(scoped),
		"last_commits":          lastCommits,
	})
}
