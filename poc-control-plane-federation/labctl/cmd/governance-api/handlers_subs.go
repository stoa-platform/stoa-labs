package main

import (
	"encoding/csv"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/governance"
)

// handleSubscriptions lists subscriptions (GET /subscriptions?tenant=&status=),
// scoped: non-admin callers only see their own tenant.
func (s *Server) handleSubscriptions(w http.ResponseWriter, r *http.Request, id governance.Identity) {
	ctx := r.Context()
	q := r.URL.Query()

	var tenants []string
	if governance.IsCPIAdmin(id.Roles) {
		if t := q.Get("tenant"); t != "" {
			tenants = []string{t}
		} else {
			all, err := s.Store.SubscriptionTenants(ctx)
			if err != nil {
				apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
				return
			}
			tenants = all
		}
	} else {
		if id.Tenant == "" {
			writeJSON(w, http.StatusOK, []governance.Subscription{})
			return
		}
		tenants = []string{id.Tenant}
	}

	out := []governance.Subscription{}
	status := q.Get("status")
	for _, t := range tenants {
		subs, err := s.Store.ListSubscriptions(ctx, t)
		if err != nil {
			continue
		}
		for _, sub := range subs {
			if status == "" || sub.Status == status {
				out = append(out, sub)
			}
		}
	}
	writeJSON(w, http.StatusOK, out)
}

// resolveSubscription locates the subscription within the caller's scope,
// auditing the refusal when it belongs to a foreign tenant.
func (s *Server) resolveSubscription(w http.ResponseWriter, r *http.Request, id governance.Identity, action string) *governance.Subscription {
	ctx := r.Context()
	subID := r.PathValue("id")
	tenants, err := s.Store.SubscriptionTenants(ctx)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return nil
	}
	sub, err := s.Store.FindSubscription(ctx, tenants, subID)
	if err != nil {
		apiError(w, http.StatusNotFound, "NOT_FOUND", err.Error())
		return nil
	}
	if !governance.CanAccessTenant(id, sub.Tenant) {
		s.auditDeny(id, action, sub.Tenant, subID, "FORBIDDEN")
		apiError(w, http.StatusForbidden, "FORBIDDEN", "accès refusé au tenant "+sub.Tenant)
		return nil
	}
	return sub
}

// decideSubscription factors approve/reject: update the YAML on main with the
// evidence pack in the same commit, then respond with the re-read state.
func (s *Server) decideSubscription(w http.ResponseWriter, r *http.Request, id governance.Identity, sub *governance.Subscription, action, status, reason string) {
	ctx := r.Context()
	decided := *sub
	decided.Status = status
	decided.Reason = reason
	if decided.CreatedAt == "" {
		decided.CreatedAt = time.Now().UTC().Format(time.RFC3339)
	}
	raw, err := governance.MarshalYAML(decided)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}

	actor := id.ToActor()
	evPath := s.Store.NextEvidencePath(ctx, sub.Tenant, sub.API, action)
	evidence := governance.Evidence{
		Action:   action,
		Actor:    governance.EvidenceActor{Username: actor.Username, Name: actor.Name, Email: actor.Email, Roles: actor.Roles},
		Tenant:   sub.Tenant,
		Resource: sub.API,
		Request: map[string]any{
			"subscription_id": sub.ID, "consumer": sub.Consumer,
			"requested_by": sub.RequestedBy, "reason": reason,
		},
		Checks: map[string]any{"rbac": "subscriptions:approve", "tenant_scope": sub.Tenant},
		Result: map[string]any{"status": status},
	}
	evFiles, err := governance.EvidenceFiles(evPath, evidence)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}
	files := map[string][]byte{governance.SubscriptionPath(sub.Tenant, sub.ID): raw}
	for p, b := range evFiles {
		files[p] = b
	}

	msg := fmt.Sprintf("gov(%s): %s %s", sub.Tenant, action, sub.ID)
	trailers := governance.TrailerBlock(action, sub.Tenant+"/"+sub.ID, actor, evPath)
	commit, err := s.Store.Repo.CommitFiles(ctx, actor, files, msg, trailers)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", err.Error())
		return
	}

	reread, err := s.Store.ReadSubscription(ctx, sub.Tenant, sub.ID)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", "relecture après commit: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"subscription": reread, "commit": commit, "evidence": evPath})
}

// handleSubscriptionApprove approves (POST /subscriptions/{id}/approve).
func (s *Server) handleSubscriptionApprove(w http.ResponseWriter, r *http.Request, id governance.Identity) {
	sub := s.resolveSubscription(w, r, id, "sub-approve")
	if sub == nil {
		return
	}
	if sub.Status == "approved" {
		apiError(w, http.StatusConflict, "NOT_PENDING", "la souscription est déjà approuvée")
		return
	}
	s.decideSubscription(w, r, id, sub, "sub-approve", "approved", "")
}

// handleSubscriptionReject rejects with mandatory reason
// (POST /subscriptions/{id}/reject).
func (s *Server) handleSubscriptionReject(w http.ResponseWriter, r *http.Request, id governance.Identity) {
	var body struct {
		Reason string `json:"reason"`
	}
	if err := readBody(r, &body, false); err != nil {
		apiError(w, http.StatusBadRequest, "BAD_REQUEST", err.Error())
		return
	}
	if body.Reason == "" {
		apiError(w, http.StatusBadRequest, "BAD_REQUEST", "le motif de rejet ('reason') est obligatoire")
		return
	}
	sub := s.resolveSubscription(w, r, id, "sub-reject")
	if sub == nil {
		return
	}
	s.decideSubscription(w, r, id, sub, "sub-reject", "rejected", body.Reason)
}

// ---- audit ----

// collectAudit aggregates git log of main + every open stoa/promote/* branch
// (§3): pending promotion commits are auditable before their merge.
func (s *Server) collectAudit(r *http.Request, id governance.Identity) ([]governance.AuditEntry, error) {
	ctx := r.Context()
	q := r.URL.Query()

	entries, err := s.Store.Repo.Log(ctx, []string{"main"}, nil, 0)
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	for _, e := range entries {
		seen[e.SHA] = true
	}
	branches, _ := s.Store.Repo.BranchesUnder(ctx, "stoa/promote")
	for _, br := range branches {
		extra, err := s.Store.Repo.Log(ctx, []string{"main.." + br}, nil, 0)
		if err != nil {
			continue
		}
		for _, e := range extra {
			if !seen[e.SHA] {
				seen[e.SHA] = true
				entries = append(entries, e)
			}
		}
	}

	// Scope: non-admin only sees its tenant's entries (platform-level commits
	// without a Resource trailer stay visible — they carry no tenant data).
	tenantFilter := ""
	if governance.IsCPIAdmin(id.Roles) {
		tenantFilter = q.Get("tenant")
	} else {
		tenantFilter = id.Tenant
	}
	action := q.Get("action")

	out := []governance.AuditEntry{}
	for _, e := range entries {
		if action != "" && e.Action != action {
			continue
		}
		if tenantFilter != "" && e.Resource != "" {
			if !strings.HasPrefix(e.Resource, tenantFilter+"/") {
				continue
			}
		}
		out = append(out, e)
	}
	// git log is already newest-first per ref; enforce global ordering by date.
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j].Date > out[j-1].Date; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out, nil
}

// handleAudit serves the audit trail (GET /audit?tenant=&limit=&action=).
func (s *Server) handleAudit(w http.ResponseWriter, r *http.Request, id governance.Identity) {
	entries, err := s.collectAudit(r, id)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", err.Error())
		return
	}
	limit := 100
	if l := r.URL.Query().Get("limit"); l != "" {
		if n, err := strconv.Atoi(l); err == nil && n > 0 {
			limit = n
		}
	}
	if len(entries) > limit {
		entries = entries[:limit]
	}
	writeJSON(w, http.StatusOK, entries)
}

// handleAuditExport streams the trail as a file (GET /audit/export?format=).
func (s *Server) handleAuditExport(w http.ResponseWriter, r *http.Request, id governance.Identity) {
	entries, err := s.collectAudit(r, id)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", err.Error())
		return
	}
	stamp := time.Now().UTC().Format("2006-01-02")
	switch r.URL.Query().Get("format") {
	case "csv":
		w.Header().Set("Content-Type", "text/csv; charset=utf-8")
		w.Header().Set("Content-Disposition", `attachment; filename="audit-`+stamp+`.csv"`)
		cw := csv.NewWriter(w)
		_ = cw.Write([]string{"sha", "sha7", "author", "email", "date", "action", "resource", "actor", "roles", "message", "signed", "evidence"})
		for _, e := range entries {
			_ = cw.Write([]string{
				e.SHA, e.SHA7, e.Author, e.Email, e.Date, e.Action, e.Resource,
				e.Actor, strings.Join(e.Roles, ","), e.Message, strconv.FormatBool(e.Signed), e.Evidence,
			})
		}
		cw.Flush()
	case "json", "":
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Content-Disposition", `attachment; filename="audit-`+stamp+`.json"`)
		_ = json.NewEncoder(w).Encode(entries)
	default:
		apiError(w, http.StatusBadRequest, "BAD_REQUEST", "format inconnu (csv|json)")
	}
}
