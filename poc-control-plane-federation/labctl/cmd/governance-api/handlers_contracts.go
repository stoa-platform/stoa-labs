package main

import (
	"fmt"
	"net/http"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/governance"
)

// handleMe echoes the verified identity + computed permissions (GET /me).
func (s *Server) handleMe(w http.ResponseWriter, r *http.Request, id governance.Identity) {
	roles := []string{}
	for _, role := range id.Roles {
		// Only surface the governance roles (realm tokens also carry
		// default-roles-*, offline_access...).
		for _, g := range governance.GovernanceRoles {
			if role == g {
				roles = append(roles, role)
			}
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"username":    id.Username,
		"name":        id.Name,
		"email":       id.Email,
		"roles":       roles,
		"permissions": governance.PermissionsFor(id.Roles),
		"tenant":      id.Tenant,
	})
}

// handleSchema serves the embedded UAC v1 JSON Schema raw (GET /schema/uac):
// the UI validates live with ajv on the exact same document.
func (s *Server) handleSchema(w http.ResponseWriter, _ *http.Request, _ governance.Identity) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(s.Schema)
}

// handleTenants lists tenants from Git, scoped (GET /tenants).
func (s *Server) handleTenants(w http.ResponseWriter, r *http.Request, id governance.Identity) {
	all, err := s.Store.ListTenants(r.Context())
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}
	out := []governance.Tenant{}
	for _, t := range all {
		if governance.CanAccessTenant(id, t.ID) {
			out = append(out, t)
		}
	}
	writeJSON(w, http.StatusOK, out)
}

// handleContracts is the per-tenant catalogue (GET /tenants/{t}/contracts).
func (s *Server) handleContracts(w http.ResponseWriter, r *http.Request, id governance.Identity) {
	tenant := r.PathValue("tenant")
	list, err := s.Store.ListContracts(r.Context(), tenant)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, list)
}

// handleContractDetail returns contract + git history + per-env desired state
// (GET /tenants/{t}/contracts/{slug}).
func (s *Server) handleContractDetail(w http.ResponseWriter, r *http.Request, id governance.Identity) {
	ctx := r.Context()
	tenant, slug := r.PathValue("tenant"), r.PathValue("slug")
	contract, err := s.Store.ReadContract(ctx, "main", tenant, slug)
	if err != nil {
		apiError(w, http.StatusNotFound, "NOT_FOUND", fmt.Sprintf("contrat %s/%s introuvable", tenant, slug))
		return
	}
	versions, err := s.Store.ContractVersions(ctx, tenant, slug)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}
	deployments, err := s.Store.Deployments(ctx, tenant, slug)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"contract":    contract,
		"versions":    versions,
		"deployments": deployments,
	})
}

// handleValidate validates a candidate contract without writing anything
// (POST .../validate) — draft mode unless the payload says published.
func (s *Server) handleValidate(w http.ResponseWriter, r *http.Request, _ governance.Identity) {
	var body struct {
		Contract map[string]any `json:"contract"`
	}
	if err := readBody(r, &body, false); err != nil {
		apiError(w, http.StatusBadRequest, "BAD_REQUEST", err.Error())
		return
	}
	if body.Contract == nil {
		apiError(w, http.StatusBadRequest, "BAD_REQUEST", "champ 'contract' requis")
		return
	}
	status, _ := body.Contract["status"].(string)
	errs := governance.ValidateUAC(body.Contract, status == "published")
	if errs == nil {
		errs = []governance.ValidationError{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"valid": len(errs) == 0, "errors": errs})
}

// handlePutContract saves a draft (PUT .../contracts/{slug}): validate (draft
// mode) -> write api.yaml -> commit as actor -> RE-READ from Git -> respond
// with the re-read content (§3 rule 1).
func (s *Server) handlePutContract(w http.ResponseWriter, r *http.Request, id governance.Identity) {
	ctx := r.Context()
	tenant, slug := r.PathValue("tenant"), r.PathValue("slug")
	var body struct {
		Contract map[string]any `json:"contract"`
		Message  string         `json:"message"`
	}
	if err := readBody(r, &body, false); err != nil {
		apiError(w, http.StatusBadRequest, "BAD_REQUEST", err.Error())
		return
	}
	if body.Contract == nil {
		apiError(w, http.StatusBadRequest, "BAD_REQUEST", "champ 'contract' requis")
		return
	}
	// The slug is the directory: pin name and tenant_id to the path.
	if name, _ := body.Contract["name"].(string); name == "" {
		body.Contract["name"] = slug
	} else if name != slug {
		apiError(w, http.StatusBadRequest, "BAD_REQUEST", fmt.Sprintf("le 'name' du contrat (%s) doit égaler le slug (%s)", name, slug))
		return
	}
	if t, _ := body.Contract["tenant_id"].(string); t == "" {
		body.Contract["tenant_id"] = tenant
	} else if t != tenant {
		apiError(w, http.StatusBadRequest, "BAD_REQUEST", "le 'tenant_id' du contrat doit égaler le tenant du chemin")
		return
	}

	if errs := governance.ValidateUAC(body.Contract, false); len(errs) > 0 {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{
			"error":  map[string]string{"code": "VALIDATION_FAILED", "message": "le contrat ne respecte pas le schéma UAC v1"},
			"errors": errs,
		})
		return
	}

	raw, err := governance.MarshalYAML(body.Contract)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}

	actor := id.ToActor()
	msg := body.Message
	if msg == "" {
		msg = fmt.Sprintf("gov(%s): draft %s", tenant, slug)
	} else {
		msg = fmt.Sprintf("gov(%s): draft %s — %s", tenant, slug, msg)
	}
	trailers := governance.TrailerBlock("draft", tenant+"/"+slug, actor, "")
	commit, err := s.Store.Repo.CommitFiles(ctx, actor,
		map[string][]byte{governance.ContractPath(tenant, slug): raw}, msg, trailers)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", err.Error())
		return
	}

	// Rule 1: never project the payload — re-read what Git holds.
	reread, err := s.Store.ReadContract(ctx, "main", tenant, slug)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", "relecture après commit: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"contract": reread, "commit": commit})
}

// handlePublish publishes to the FIRST environment of the chain (POST
// .../publish — dev by default): validate published mode, status=published +
// deploy.{first}.yaml + evidence pack, ONE commit on main (§3 rule 4 — direct
// mode assumed for the entry environment).
func (s *Server) handlePublish(w http.ResponseWriter, r *http.Request, id governance.Identity) {
	ctx := r.Context()
	tenant, slug := r.PathValue("tenant"), r.PathValue("slug")
	var body struct {
		Message string `json:"message"`
	}
	if err := readBody(r, &body, false); err != nil {
		apiError(w, http.StatusBadRequest, "BAD_REQUEST", err.Error())
		return
	}
	if body.Message == "" {
		apiError(w, http.StatusBadRequest, "BAD_REQUEST", "le champ 'message' est obligatoire pour publier")
		return
	}
	chain, err := s.Store.EnvChain(ctx)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}
	firstEnv := chain.First()

	contract, err := s.Store.ReadContract(ctx, "main", tenant, slug)
	if err != nil {
		apiError(w, http.StatusNotFound, "NOT_FOUND", fmt.Sprintf("contrat %s/%s introuvable", tenant, slug))
		return
	}
	contract["status"] = "published"
	if errs := governance.ValidateUAC(contract, true); len(errs) > 0 {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{
			"error":  map[string]string{"code": "VALIDATION_FAILED", "message": "le contrat ne peut pas être publié"},
			"errors": errs,
		})
		return
	}

	version, _ := contract["version"].(string)
	contractRaw, err := governance.MarshalYAML(contract)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}
	deployRaw, err := governance.MarshalYAML(governance.Deployment{
		Version: version, Enabled: true, PromotedBy: id.Username, Message: body.Message,
	})
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}

	actor := id.ToActor()
	evPath := s.Store.NextEvidencePath(ctx, tenant, slug, "publish")
	evidence := governance.Evidence{
		Action:   "publish",
		Actor:    governance.EvidenceActor{Username: actor.Username, Name: actor.Name, Email: actor.Email, Roles: actor.Roles},
		Tenant:   tenant,
		Resource: slug,
		Request:  map[string]any{"message": body.Message, "environment": firstEnv, "version": version},
		Checks:   map[string]any{"schema_valid": true, "published_gate": "≥1 endpoint"},
		Result:   map[string]any{"commit": "(le commit contenant cette évidence)", "deployed": firstEnv, "status": "published"},
	}
	evFiles, err := governance.EvidenceFiles(evPath, evidence)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "INTERNAL", err.Error())
		return
	}

	files := map[string][]byte{
		governance.ContractPath(tenant, slug):         contractRaw,
		governance.DeployPath(tenant, slug, firstEnv): deployRaw,
	}
	for p, b := range evFiles {
		files[p] = b
	}

	msg := fmt.Sprintf("gov(%s): publish %s", tenant, slug)
	trailers := governance.TrailerBlock("publish", tenant+"/"+slug, actor, evPath)
	commit, err := s.Store.Repo.CommitFiles(ctx, actor, files, msg, trailers)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "GIT_ERROR", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"commit": commit, "evidence": evPath})
}
