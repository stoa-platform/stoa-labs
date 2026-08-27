package main

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/governance"
)

// handlePromotions lists a tenant's promotions, optionally filtered by
// ?status= (GET /tenants/{t}/promotions).
func (s *Server) handlePromotions(w http.ResponseWriter, r *http.Request, _ governance.Identity) {
	tenant := r.PathValue("tenant")
	list, err := s.Store.ListPromotions(r.Context(), tenant)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}
	if status := r.URL.Query().Get("status"); status != "" {
		filtered := []governance.Promotion{}
		for _, p := range list {
			if p.Status == status {
				filtered = append(filtered, p)
			}
		}
		list = filtered
	}
	if list == nil {
		list = []governance.Promotion{}
	}
	writeJSON(w, http.StatusOK, list)
}

// handlePromotionRequest opens the governed promotion branch
// (POST /tenants/{t}/promotions, §3 rule 5): branch stoa/promote/{t}/{slug}/{id}
// carrying deploy.{to}.yaml + the pending promotions/{t}/{id}.yaml marker.
func (s *Server) handlePromotionRequest(w http.ResponseWriter, r *http.Request, id governance.Identity) {
	ctx := r.Context()
	tenant := r.PathValue("tenant")
	var body struct {
		Slug      string `json:"slug"`
		From      string `json:"from"`
		To        string `json:"to"`
		Message   string `json:"message"`
		ChangeRef string `json:"change_ref"`
		PVRef     string `json:"pv_ref"`
	}
	if err := readBody(r, &body, false); err != nil {
		apiError(w, http.StatusBadRequest, "BAD_REQUEST", err.Error())
		return
	}
	if body.Message == "" {
		apiError(w, http.StatusBadRequest, "BAD_REQUEST", "le message d'audit est obligatoire")
		return
	}
	if len(body.Message) > 1000 {
		apiError(w, http.StatusBadRequest, "BAD_REQUEST", "le message d'audit dépasse 1000 caractères")
		return
	}
	// The chain (environments.yaml on main, default dev→staging→production) is
	// re-read per request: no state outside Git.
	chain, err := s.Store.EnvChain(ctx)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}
	if next, ok := chain.NextOf(body.From); !ok || next != body.To {
		apiError(w, http.StatusBadRequest, "BAD_REQUEST",
			"chaîne de promotion invalide (autorisées: "+chain.HopsString()+")")
		return
	}
	// Gate refs — fail at the earliest: the references the TARGET gate demands
	// are checked at REQUEST time, not discovered at approval. itsmCheck implies
	// a change_ref (there is nothing to verify without one).
	gate := chain.Gates[body.To]
	if (gate.RequireChangeRef || gate.ITSMCheck) && body.ChangeRef == "" {
		apiError(w, http.StatusBadRequest, "GATE_REFS_REQUIRED",
			fmt.Sprintf("le gate vers %s exige une référence de changement ('change_ref')", body.To))
		return
	}
	if gate.RequirePVRef && body.PVRef == "" {
		apiError(w, http.StatusBadRequest, "GATE_REFS_REQUIRED",
			fmt.Sprintf("le gate vers %s exige une référence de PV de recette ('pv_ref')", body.To))
		return
	}
	contract, err := s.Store.ReadContract(ctx, "main", tenant, body.Slug)
	if err != nil {
		apiError(w, http.StatusNotFound, "NOT_FOUND", fmt.Sprintf("contrat %s/%s introuvable", tenant, body.Slug))
		return
	}
	// The source environment must hold a deployed version to promote.
	deployments, err := s.Store.Deployments(ctx, tenant, body.Slug)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}
	src := deployments[body.From]
	if src == nil {
		apiError(w, http.StatusBadRequest, "BAD_REQUEST",
			fmt.Sprintf("aucun déploiement %s pour %s — rien à promouvoir", body.From, body.Slug))
		return
	}
	version := src.Version
	if version == "" {
		version, _ = contract["version"].(string)
	}
	// Real version pinning: the deploy marker records the api.yaml main SHA at
	// request time; the approval re-checks it (CONTRACT_MOVED on drift).
	pinSHA, err := s.Store.ContractHeadSHA(ctx, tenant, body.Slug)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", err.Error())
		return
	}

	promoID := governance.NewID("pr")
	branch := governance.PromotionBranch(tenant, body.Slug, promoID)
	now := time.Now().UTC().Format(time.RFC3339)
	promo := governance.Promotion{
		ID:          promoID,
		Slug:        body.Slug,
		From:        body.From,
		To:          body.To,
		RequestedBy: id.Username,
		Message:     body.Message,
		Status:      "pending",
		CreatedAt:   now,
		Branch:      branch,
		ChangeRef:   body.ChangeRef,
		PVRef:       body.PVRef,
	}
	promoRaw, err := governance.MarshalYAML(promo)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}
	deployRaw, err := governance.MarshalYAML(governance.Deployment{
		Version: version, Enabled: true, PromotedBy: id.Username, Message: body.Message, Commit: pinSHA,
		// Anchor the dispatch gate (A6) on THIS state: the change that authorised
		// this promotion travels into the deploy marker, so a live ITSM re-check
		// at apply time targets exactly the state being dispatched.
		ChangeRef: body.ChangeRef,
	})
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}

	actor := id.ToActor()
	msg := fmt.Sprintf("gov(%s): promote-request %s", tenant, body.Slug)
	trailers := governance.TrailerBlock("promote-request", tenant+"/"+promoID, actor, "")
	if _, err := s.Store.Repo.CreateBranchCommit(ctx, actor, branch, map[string][]byte{
		governance.DeployPath(tenant, body.Slug, body.To): deployRaw,
		governance.PromotionPath(tenant, promoID):         promoRaw,
	}, msg, trailers); err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", err.Error())
		return
	}

	// Rule 1: respond with the promotion as Git sees it (re-read from the branch).
	reread, err := s.Store.FindPromotion(ctx, tenant, promoID)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", "relecture après commit: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"promotion": reread})
}

// handlePromotionDiff is the merge-request review payload
// (GET .../promotions/{id}/diff): real `git diff main...branch`.
func (s *Server) handlePromotionDiff(w http.ResponseWriter, r *http.Request, _ governance.Identity) {
	ctx := r.Context()
	tenant, promoID := r.PathValue("tenant"), r.PathValue("id")
	promo, err := s.Store.FindPromotion(ctx, tenant, promoID)
	if err != nil {
		apiError(w, http.StatusNotFound, "NOT_FOUND", err.Error())
		return
	}
	if promo.Status != "pending" || promo.Branch == "" {
		writeJSON(w, http.StatusOK, map[string]any{"diff": "", "files": []governance.DiffFile{}})
		return
	}
	diff, files, err := s.Store.Repo.DiffBranch(ctx, promo.Branch)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"diff": diff, "files": files})
}

// handlePromotionApprove merges the promotion branch (POST .../approve):
// the TARGET gate (environments.yaml, default = 4-eyes on production) is
// evaluated server-side and every refusal is audited. The approval itself is a
// signed --no-ff merge on main carrying the approved marker + evidence pack.
func (s *Server) handlePromotionApprove(w http.ResponseWriter, r *http.Request, id governance.Identity) {
	ctx := r.Context()
	tenant, promoID := r.PathValue("tenant"), r.PathValue("id")
	var body struct {
		Message string `json:"message"`
	}
	if err := readBody(r, &body, true); err != nil {
		apiError(w, http.StatusBadRequest, "BAD_REQUEST", err.Error())
		return
	}

	promo, err := s.Store.FindPromotion(ctx, tenant, promoID)
	if err != nil {
		apiError(w, http.StatusNotFound, "NOT_FOUND", err.Error())
		return
	}
	if promo.Status != "pending" || promo.Branch == "" {
		apiError(w, http.StatusConflict, "NOT_PENDING", fmt.Sprintf("la promotion %s est déjà %s", promoID, promo.Status))
		return
	}

	chain, err := s.Store.EnvChain(ctx)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}
	gate := chain.Gates[promo.To]

	// (1) 4-yeux: the requester may not approve their own promotion on a
	// fourEyes hop (default chain: production).
	if gate.FourEyes && promo.RequestedBy == id.Username {
		s.auditDeny(id, "promote-approve", tenant, promoID, "SELF_APPROVAL_BLOCKED")
		apiError(w, http.StatusForbidden, "SELF_APPROVAL_BLOCKED",
			"principe des 4 yeux : le demandeur ne peut pas approuver sa propre promotion vers "+promo.To)
		return
	}

	// (2) approver group: the gate may bind approval to a `groups` claim.
	if gate.ApproverGroup != "" && !hasGroup(id.Groups, gate.ApproverGroup) {
		s.auditDeny(id, "promote-approve", tenant, promoID, "GATE_GROUP_REQUIRED")
		apiError(w, http.StatusForbidden, "GATE_GROUP_REQUIRED",
			fmt.Sprintf("le gate vers %s exige l'appartenance au groupe %q", promo.To, gate.ApproverGroup))
		return
	}

	// (3) ITSM: change_ref must be "approved" in the change-management system.
	// Fail-closed: no client → 503, unreachable/HTTP error → 503, anything but
	// approved → 409, all before touching Git.
	itsmStatus := ""
	if gate.ITSMCheck {
		if s.ITSM == nil {
			apiError(w, http.StatusServiceUnavailable, "ITSM_NOT_CONFIGURED",
				"le gate vers "+promo.To+" exige une vérification ITSM mais aucun ITSM n'est configuré (ITSM_URL) — refus par défaut")
			return
		}
		st, err := s.ITSM.ChangeStatus(ctx, promo.ChangeRef)
		if err != nil {
			apiError(w, http.StatusServiceUnavailable, "ITSM_UNAVAILABLE",
				"vérification ITSM impossible (refus par défaut): "+err.Error())
			return
		}
		if st != "approved" {
			s.auditDeny(id, "promote-approve", tenant, promoID, "ITSM_NOT_APPROVED")
			apiError(w, http.StatusConflict, "ITSM_NOT_APPROVED",
				fmt.Sprintf("le changement %s est %q dans l'ITSM (attendu: approved)", promo.ChangeRef, st))
			return
		}
		itsmStatus = st
	}

	// (4) version pin: the contract must not have moved on main between the
	// request and the approval — otherwise the reviewer approved another text.
	pinned := ""
	if d, err := s.Store.ReadDeployment(ctx, promo.Branch, tenant, promo.Slug, promo.To); err == nil {
		pinned = d.Commit
	}
	if pinned != "" {
		cur, err := s.Store.ContractHeadSHA(ctx, tenant, promo.Slug)
		if err != nil {
			apiError(w, http.StatusInternalServerError, "GIT_ERROR", err.Error())
			return
		}
		if cur != pinned {
			s.auditDeny(id, "promote-approve", tenant, promoID, "CONTRACT_MOVED")
			apiError(w, http.StatusConflict, "CONTRACT_MOVED",
				fmt.Sprintf("le contrat %s a changé sur main depuis la demande (pin %.7s, tête %.7s) — refaire une demande de promotion",
					promo.Slug, pinned, cur))
			return
		}
	}

	now := time.Now().UTC().Format(time.RFC3339)
	approved := *promo
	approved.Status = "approved"
	approved.ApprovedBy = id.Username
	approved.ApprovedAt = now
	approved.Branch = "" // the branch dies with the merge; status = position in Git
	approvedRaw, err := governance.MarshalYAML(approved)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}

	actor := id.ToActor()
	evPath := s.Store.NextEvidencePath(ctx, tenant, promo.Slug, "promote-approve")
	// The gate evaluation joins the pack: which hop, which controls, what the
	// ITSM answered — the evidence shows WHY this approval was legitimate.
	gateCheck := map[string]any{
		"hop":            promo.From + "→" + promo.To,
		"four_eyes":      gate.FourEyes,
		"approver_group": gate.ApproverGroup,
		"pv_ref":         promo.PVRef,
		// deployer_group is MATERIALIZED here, never EVALUATED here: carrying the
		// deploy is a dispatch-time act (ADR-084) — the refusal lives at the two
		// dispatch sites, where the carrier's Vault token exists. The only identity
		// this handler holds is the Keycloak one, which says nothing about that
		// OTHER directory; recording the group the deploy is OWED to is what this
		// site can honestly do.
		"deployer_group": gate.DeployerGroup,
	}
	if gate.ITSMCheck {
		gateCheck["itsm"] = map[string]any{"change_ref": promo.ChangeRef, "status": itsmStatus}
	}
	evidence := governance.Evidence{
		Action:   "promote-approve",
		Actor:    governance.EvidenceActor{Username: actor.Username, Name: actor.Name, Email: actor.Email, Roles: actor.Roles},
		Tenant:   tenant,
		Resource: promo.Slug,
		Request: map[string]any{
			"from": promo.From, "to": promo.To,
			"promotion_id": promo.ID, "message": body.Message,
		},
		Checks: map[string]any{
			"schema_valid": true,
			"four_eyes": map[string]any{
				"requested_by": promo.RequestedBy,
				"approved_by":  id.Username,
				"distinct":     promo.RequestedBy != id.Username,
			},
			"gate": gateCheck,
		},
		Result:   map[string]any{"merge_commit": "(le commit de merge contenant cette évidence)", "signed": true},
		Negative: s.selfApprovalNegative(tenant, promoID),
	}
	evFiles, err := governance.EvidenceFiles(evPath, evidence)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}
	files := map[string][]byte{governance.PromotionPath(tenant, promoID): approvedRaw}
	for p, b := range evFiles {
		files[p] = b
	}

	msg := fmt.Sprintf("gov(%s): promote-approve %s", tenant, promo.Slug)
	trailers := governance.TrailerBlock("promote-approve", tenant+"/"+promoID, actor, evPath)
	mergeCommit, err := s.Store.Repo.MergeBranchCommit(ctx, actor, promo.Branch, files, msg, trailers)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", err.Error())
		return
	}

	// Chaîne A (ADR-077) : l'approbation vient d'être COMMITÉE — on propage
	// l'IDENTITÉ de l'approbateur vers le canal de déploiement (exchange
	// RFC 8693 → job Jenkins sans credential) IMMÉDIATEMENT, avant même la
	// relecture : un échec de re-lecture ne doit pas perdre l'effet d'une
	// approbation déjà actée dans Git. Le Bearer brut est capturé ici (la
	// requête meurt avec le handler).
	userDeploy := "not_configured"
	if s.UserDeploy != nil {
		userDeploy = "dispatched"
		s.dispatchUserDeploy(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "),
			tenant, promoID, id.Username)
	}

	reread, err := s.Store.FindPromotion(ctx, tenant, promoID)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", "relecture après merge: "+err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"promotion":    reread,
		"merge_commit": map[string]any{"sha": mergeCommit.SHA, "sha7": mergeCommit.SHA7, "signed": mergeCommit.Signed},
		"evidence":     evPath,
		"user_deploy":  userDeploy,
	})
}

// hasGroup reports membership of one group in the token's `groups` claim.
func hasGroup(groups []string, want string) bool {
	for _, g := range groups {
		if g == want {
			return true
		}
	}
	return false
}

// selfApprovalNegative builds the §6 "negative" line when this promotion
// previously hit a SELF_APPROVAL_BLOCKED denial (read from denials.jsonl).
func (s *Server) selfApprovalNegative(tenant, promoID string) string {
	raw, err := os.ReadFile(filepath.Join(s.Store.Repo.Dir, filepath.FromSlash(governance.DenialsPath)))
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(raw), "\n") {
		if strings.Contains(line, `"SELF_APPROVAL_BLOCKED"`) && strings.Contains(line, `"`+promoID+`"`) && strings.Contains(line, `"`+tenant+`"`) {
			// Extract the denied user for the narrative.
			user := "le demandeur"
			if i := strings.Index(line, `"user":"`); i >= 0 {
				rest := line[i+len(`"user":"`):]
				if j := strings.Index(rest, `"`); j > 0 {
					user = rest[:j]
				}
			}
			return fmt.Sprintf("l'auto-approbation par %s a été refusée en 403 (voir %s)", user, governance.DenialsPath)
		}
	}
	return ""
}

// handlePromotionReject records the motivated refusal (POST .../reject, §3
// rule 5): rejected marker + evidence committed on main, branch deleted.
func (s *Server) handlePromotionReject(w http.ResponseWriter, r *http.Request, id governance.Identity) {
	ctx := r.Context()
	tenant, promoID := r.PathValue("tenant"), r.PathValue("id")
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

	promo, err := s.Store.FindPromotion(ctx, tenant, promoID)
	if err != nil {
		apiError(w, http.StatusNotFound, "NOT_FOUND", err.Error())
		return
	}
	if promo.Status != "pending" || promo.Branch == "" {
		apiError(w, http.StatusConflict, "NOT_PENDING", fmt.Sprintf("la promotion %s est déjà %s", promoID, promo.Status))
		return
	}

	rejected := *promo
	rejected.Status = "rejected"
	rejected.Reason = body.Reason
	rejected.ApprovedBy = ""
	branch := promo.Branch
	rejected.Branch = ""
	rejectedRaw, err := governance.MarshalYAML(rejected)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}

	actor := id.ToActor()
	evPath := s.Store.NextEvidencePath(ctx, tenant, promo.Slug, "promote-reject")
	evidence := governance.Evidence{
		Action:   "promote-reject",
		Actor:    governance.EvidenceActor{Username: actor.Username, Name: actor.Name, Email: actor.Email, Roles: actor.Roles},
		Tenant:   tenant,
		Resource: promo.Slug,
		Request: map[string]any{
			"from": promo.From, "to": promo.To,
			"promotion_id": promo.ID, "reason": body.Reason,
		},
		Checks: map[string]any{"motivated_rejection": true, "requested_by": promo.RequestedBy},
		Result: map[string]any{"status": "rejected", "branch_deleted": branch},
	}
	evFiles, err := governance.EvidenceFiles(evPath, evidence)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}
	files := map[string][]byte{governance.PromotionPath(tenant, promoID): rejectedRaw}
	for p, b := range evFiles {
		files[p] = b
	}

	msg := fmt.Sprintf("gov(%s): promote-reject %s", tenant, promo.Slug)
	trailers := governance.TrailerBlock("promote-reject", tenant+"/"+promoID, actor, evPath)
	if _, err := s.Store.Repo.CommitFiles(ctx, actor, files, msg, trailers); err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", err.Error())
		return
	}
	if err := s.Store.Repo.DeleteBranch(ctx, branch); err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", "marqueur commité mais suppression de branche échouée: "+err.Error())
		return
	}

	reread, err := s.Store.FindPromotion(ctx, tenant, promoID)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", "relecture après rejet: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"promotion": reread})
}
