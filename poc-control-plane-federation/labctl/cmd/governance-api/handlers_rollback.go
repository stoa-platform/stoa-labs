package main

import (
	"fmt"
	"net/http"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/governance"
)

// handlePromotionRollback restores the PREVIOUS desired state of the target
// environment (POST .../promotions/{id}/rollback): deploy.{to}.yaml is taken
// VERBATIM from the commit before the approval — including ITS pinned Commit —
// and committed on main with a rolled_back marker + evidence pack. No 4-eyes
// here: we return to a state that WAS already approved; but the rollback is
// motivated (reason required, change_ref when the gate demands one) and
// audited like every governed write.
func (s *Server) handlePromotionRollback(w http.ResponseWriter, r *http.Request, id governance.Identity) {
	ctx := r.Context()
	tenant, promoID := r.PathValue("tenant"), r.PathValue("id")
	var body struct {
		Reason    string `json:"reason"`
		ChangeRef string `json:"change_ref"`
	}
	if err := readBody(r, &body, false); err != nil {
		apiError(w, http.StatusBadRequest, "BAD_REQUEST", err.Error())
		return
	}
	if body.Reason == "" {
		apiError(w, http.StatusBadRequest, "BAD_REQUEST", "le motif de rollback ('reason') est obligatoire")
		return
	}

	promo, err := s.Store.FindPromotion(ctx, tenant, promoID)
	if err != nil {
		apiError(w, http.StatusNotFound, "NOT_FOUND", err.Error())
		return
	}
	// Precondition: only an APPROVED promotion materialised a desired state
	// worth reverting; anything else is a conflict, not a rollback.
	if promo.Status != "approved" {
		apiError(w, http.StatusConflict, "NOT_APPROVED",
			fmt.Sprintf("seule une promotion approuvée peut être annulée (statut: %s)", promo.Status))
		return
	}

	chain, err := s.Store.EnvChain(ctx)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}
	// The rollback of a gated environment is itself a change: same change_ref
	// requirement as the forward hop (fail at the earliest).
	gate := chain.Gates[promo.To]
	if gate.RequireChangeRef && body.ChangeRef == "" {
		apiError(w, http.StatusBadRequest, "GATE_REFS_REQUIRED",
			fmt.Sprintf("le gate vers %s exige une référence de changement ('change_ref') pour un rollback", promo.To))
		return
	}

	deployPath := governance.DeployPath(tenant, promo.Slug, promo.To)
	hist, err := s.Store.Repo.Log(ctx, []string{"main"}, []string{deployPath}, 2)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", err.Error())
		return
	}
	if len(hist) < 2 {
		apiError(w, http.StatusConflict, "NO_PREVIOUS_STATE",
			fmt.Sprintf("aucun état antérieur de %s pour %s — rien à restaurer", promo.To, promo.Slug))
		return
	}
	prevSHA := hist[1].SHA
	// The restored content is the N-1 file VERBATIM (its own pinned Commit
	// included) — never re-synthesized from the request payload.
	prevRaw, err := s.Store.Repo.ReadFile(ctx, prevSHA, deployPath)
	if err != nil {
		apiError(w, http.StatusConflict, "NO_PREVIOUS_STATE",
			fmt.Sprintf("état antérieur de %s illisible à %.7s: %v", promo.To, prevSHA, err))
		return
	}
	prev, err := s.Store.ReadDeployment(ctx, prevSHA, tenant, promo.Slug, promo.To)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", err.Error())
		return
	}
	cur, err := s.Store.ReadDeployment(ctx, "main", tenant, promo.Slug, promo.To)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", err.Error())
		return
	}

	rolled := *promo
	rolled.Status = "rolled_back"
	rolled.Reason = body.Reason
	rolledRaw, err := governance.MarshalYAML(rolled)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}

	actor := id.ToActor()
	evPath := s.Store.NextEvidencePath(ctx, tenant, promo.Slug, "rollback")
	evidence := governance.Evidence{
		Action:   "rollback",
		Actor:    governance.EvidenceActor{Username: actor.Username, Name: actor.Name, Email: actor.Email, Roles: actor.Roles},
		Tenant:   tenant,
		Resource: promo.Slug,
		Request: map[string]any{
			"promotion_id": promo.ID, "environment": promo.To,
			"reason": body.Reason, "change_ref": body.ChangeRef,
			"from": map[string]any{"version": cur.Version, "commit": cur.Commit},
			"to":   map[string]any{"version": prev.Version, "commit": prev.Commit},
		},
		Checks: map[string]any{
			"previously_approved": true,
			"restored_from":       prevSHA,
		},
		Result: map[string]any{"status": "rolled_back", "restored_env": promo.To},
	}
	evFiles, err := governance.EvidenceFiles(evPath, evidence)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}
	files := map[string][]byte{
		deployPath: prevRaw,
		governance.PromotionPath(tenant, promoID): rolledRaw,
	}
	for p, b := range evFiles {
		files[p] = b
	}

	msg := fmt.Sprintf("gov(%s): rollback %s (%s)", tenant, promo.Slug, promo.To)
	trailers := governance.TrailerBlock("rollback", tenant+"/"+promoID, actor, evPath)
	commit, err := s.Store.Repo.CommitFiles(ctx, actor, files, msg, trailers)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", err.Error())
		return
	}

	// Rule 1: respond with what Git holds after the commit, never the payload.
	reread, err := s.Store.FindPromotion(ctx, tenant, promoID)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", "relecture après rollback: "+err.Error())
		return
	}
	restored, err := s.Store.ReadDeployment(ctx, "main", tenant, promo.Slug, promo.To)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", "relecture après rollback: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"promotion": reread,
		"restored":  map[string]any{"environment": promo.To, "version": restored.Version, "commit": restored.Commit},
		"commit":    map[string]any{"sha": commit.SHA, "sha7": commit.SHA7, "signed": commit.Signed},
		"evidence":  evPath,
	})
}
