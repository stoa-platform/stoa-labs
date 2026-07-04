package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/governance"
)

// Server wires the HTTP surface (contract §4) onto the governance engine.
// RBAC is enforced HERE, server-side — the UI only hides buttons (§2).
type Server struct {
	Store       *governance.Store
	Verifier    *governance.Verifier
	KC          *governance.KCAdmin
	TargetsFile string
	UIDist      string
	Schema      []byte
	// ITSM is the change-management client of the itsmCheck gate. nil = not
	// configured: an itsmCheck hop then refuses with 503 (fail-closed).
	ITSM *governance.ITSMClient

	// denialWG tracks the asynchronous 403-audit commits so tests (and a
	// graceful shutdown) can wait for the trail to land in Git.
	denialWG sync.WaitGroup
}

// corsOrigin is the only allowed dev origin (contract §7).
const corsOrigin = "http://localhost:5173"

// handlerFunc is an authenticated handler.
type handlerFunc func(w http.ResponseWriter, r *http.Request, id governance.Identity)

// Handler builds the routed mux (Go 1.22 method+pattern routing) wrapped with
// CORS for /api/*.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()

	// --- identity & static ---
	mux.HandleFunc("GET /api/v1/me", s.auth(s.handleMe))
	mux.HandleFunc("GET /api/v1/environments", s.auth(s.handleEnvironments))
	mux.HandleFunc("GET /api/v1/schema/uac", s.auth(s.handleSchema))
	mux.HandleFunc("GET /api/v1/roles", s.auth(s.handleRoles))
	mux.HandleFunc("GET /api/v1/dashboard", s.auth(s.handleDashboard))

	// --- tenants & contracts ---
	mux.HandleFunc("GET /api/v1/tenants", s.perm("tenants:read", s.handleTenants))
	mux.HandleFunc("GET /api/v1/tenants/{tenant}/contracts", s.perm("apis:read", s.tenantScoped("apis:read", s.handleContracts)))
	mux.HandleFunc("GET /api/v1/tenants/{tenant}/contracts/{slug}", s.perm("apis:read", s.tenantScoped("apis:read", s.handleContractDetail)))
	mux.HandleFunc("POST /api/v1/tenants/{tenant}/contracts/{slug}/validate", s.perm("apis:read", s.tenantScoped("apis:validate", s.handleValidate)))
	mux.HandleFunc("PUT /api/v1/tenants/{tenant}/contracts/{slug}", s.perm("apis:update", s.tenantScoped("apis:update", s.handlePutContract)))
	mux.HandleFunc("POST /api/v1/tenants/{tenant}/contracts/{slug}/publish", s.perm("apis:publish", s.tenantScoped("apis:publish", s.handlePublish)))

	// --- promotions ---
	mux.HandleFunc("GET /api/v1/tenants/{tenant}/promotions", s.perm("promotions:read", s.tenantScoped("promotions:read", s.handlePromotions)))
	mux.HandleFunc("POST /api/v1/tenants/{tenant}/promotions", s.perm("promotions:request", s.tenantScoped("promotions:request", s.handlePromotionRequest)))
	mux.HandleFunc("GET /api/v1/tenants/{tenant}/promotions/{id}/diff", s.perm("promotions:read", s.tenantScoped("promotions:read", s.handlePromotionDiff)))
	mux.HandleFunc("POST /api/v1/tenants/{tenant}/promotions/{id}/approve", s.perm("promotions:approve", s.tenantScoped("promotions:approve", s.handlePromotionApprove)))
	mux.HandleFunc("POST /api/v1/tenants/{tenant}/promotions/{id}/reject", s.perm("promotions:approve", s.tenantScoped("promotions:reject", s.handlePromotionReject)))
	mux.HandleFunc("POST /api/v1/tenants/{tenant}/promotions/{id}/rollback", s.perm("promotions:approve", s.tenantScoped("promotions:rollback", s.handlePromotionRollback)))

	// --- subscriptions ---
	mux.HandleFunc("GET /api/v1/subscriptions", s.perm("subscriptions:read", s.handleSubscriptions))
	mux.HandleFunc("POST /api/v1/subscriptions/{id}/approve", s.perm("subscriptions:approve", s.handleSubscriptionApprove))
	mux.HandleFunc("POST /api/v1/subscriptions/{id}/reject", s.perm("subscriptions:approve", s.handleSubscriptionReject))

	// --- audit, targets, users ---
	mux.HandleFunc("GET /api/v1/audit", s.perm("audit:read", s.handleAudit))
	mux.HandleFunc("GET /api/v1/audit/export", s.perm("audit:export", s.handleAuditExport))
	mux.HandleFunc("GET /api/v1/targets", s.perm("targets:read", s.handleTargets))
	mux.HandleFunc("GET /api/v1/users", s.perm("users:read", s.handleUsers))
	mux.HandleFunc("PUT /api/v1/users/{id}/roles", s.perm("users:manage", s.handleUserRoles))

	// Unknown API paths -> JSON 404 (not the SPA fallback).
	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
		apiError(w, http.StatusNotFound, "NOT_FOUND", "route inconnue: "+r.Method+" "+r.URL.Path)
	})

	// Built UI (prod mode) on / when UI_DIST is set.
	if s.UIDist != "" {
		mux.Handle("/", spaHandler(s.UIDist))
	}

	return s.cors(mux)
}

// cors allows the Vite dev origin on /api/* and answers preflights.
func (s *Server) cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/") {
			w.Header().Set("Access-Control-Allow-Origin", corsOrigin)
			w.Header().Set("Vary", "Origin")
			if r.Method == http.MethodOptions {
				w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
				w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
				w.Header().Set("Access-Control-Max-Age", "600")
				w.WriteHeader(http.StatusNoContent)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

// auth verifies the Bearer token and hands the identity to the handler.
func (s *Server) auth(next handlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		h := r.Header.Get("Authorization")
		if !strings.HasPrefix(h, "Bearer ") {
			apiError(w, http.StatusUnauthorized, "UNAUTHORIZED", "jeton Bearer manquant")
			return
		}
		id, err := s.Verifier.Verify(r.Context(), strings.TrimPrefix(h, "Bearer "))
		if err != nil {
			apiError(w, http.StatusUnauthorized, "UNAUTHORIZED", err.Error())
			return
		}
		next(w, r, *id)
	}
}

// perm gates the handler on one §2 permission. Every refusal is audited
// (denials.jsonl + deny commit), asynchronously and non-blocking.
func (s *Server) perm(permission string, next handlerFunc) http.HandlerFunc {
	return s.auth(func(w http.ResponseWriter, r *http.Request, id governance.Identity) {
		if !governance.HasPermission(id.Roles, permission) {
			s.auditDeny(id, permission, r.PathValue("tenant"), r.Method+" "+r.URL.Path, "FORBIDDEN")
			apiError(w, http.StatusForbidden, "FORBIDDEN", "permission requise: "+permission)
			return
		}
		next(w, r, id)
	})
}

// tenantScoped enforces the §2 tenant isolation on /tenants/{tenant}/...
// routes: non-cpi-admin callers only reach their own tenant.
func (s *Server) tenantScoped(action string, next handlerFunc) handlerFunc {
	return func(w http.ResponseWriter, r *http.Request, id governance.Identity) {
		tenant := r.PathValue("tenant")
		if !governance.CanAccessTenant(id, tenant) {
			s.auditDeny(id, action, tenant, r.Method+" "+r.URL.Path, "FORBIDDEN")
			apiError(w, http.StatusForbidden, "FORBIDDEN", "accès refusé au tenant "+tenant)
			return
		}
		next(w, r, id)
	}
}

// auditDeny implements "tout 403 est audité" (§2): append to
// evidence/denials/denials.jsonl + bot commit `deny({tenant}): {action} by
// {user}` — asynchronous, never blocking the 403 response.
func (s *Server) auditDeny(id governance.Identity, action, tenant, resource, code string) {
	if tenant == "" {
		tenant = "platform"
	}
	entry := map[string]any{
		"ts":       time.Now().UTC().Format(time.RFC3339),
		"user":     id.Username,
		"roles":    id.Roles,
		"tenant":   tenant,
		"action":   action,
		"resource": resource,
		"code":     code,
	}
	line, err := json.Marshal(entry)
	if err != nil {
		return
	}
	bot := governance.Actor{Username: id.Username, Name: "governance-bot", Email: "bot@stoa.local", Roles: id.Roles}
	subject := fmt.Sprintf("deny(%s): %s by %s", tenant, action, id.Username)
	body := governance.TrailerBlock("deny", tenant+"/"+action, governance.Actor{Username: id.Username, Roles: id.Roles, Name: id.Name, Email: id.Email}, governance.DenialsPath)

	s.denialWG.Add(1)
	go func() {
		defer s.denialWG.Done()
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if _, err := s.Store.Repo.AppendFileAndCommit(ctx, bot, governance.DenialsPath, line, subject, body); err != nil {
			log.Printf("governance-api: denial audit failed: %v", err)
		}
	}()
}

// WaitDenials blocks until pending denial audits are committed (tests).
func (s *Server) WaitDenials() { s.denialWG.Wait() }

// ---- JSON helpers ----

// writeJSON renders v with the canonical content type.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// apiError renders the contract error envelope {error: {code, message}}.
func apiError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{
		"error": map[string]string{"code": code, "message": message},
	})
}

// readBody decodes a JSON request body into v (empty body allowed when
// optional=true).
func readBody(r *http.Request, v any, optional bool) error {
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(v); err != nil {
		if optional && err.Error() == "EOF" {
			return nil
		}
		return fmt.Errorf("corps JSON invalide: %w", err)
	}
	return nil
}

// spaHandler serves the built UI with an index.html fallback for client-side
// routes.
func spaHandler(dist string) http.Handler {
	fs := http.FileServer(http.Dir(dist))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := filepath.Join(dist, filepath.Clean("/"+r.URL.Path))
		if st, err := os.Stat(path); err != nil || st.IsDir() {
			if r.URL.Path != "/" {
				http.ServeFile(w, r, filepath.Join(dist, "index.html"))
				return
			}
		}
		fs.ServeHTTP(w, r)
	})
}
