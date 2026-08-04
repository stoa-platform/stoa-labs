package main

// Server wires the 10.15-DIALECT admin surface (admin.go), the resolving
// data-plane (dataplane.go) and native OTel emission. The mock is a faithful
// stand-in for softwareag/apigateway-trial:10.15 AS THE LABCTL ADAPTER SPEAKS
// IT — envelopes, lifecycle and traps included — so it can play the dev/rec/int
// environments behind the production gateway's admin proxy: `labctl apply` and
// `labctl apply-uac` (type webmethods) pass against it end to end, and the
// multi-env ${alias} routing demo resolves per request.

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/metric"
)

type Server struct {
	store    *Store
	now      func() time.Time
	dpCalls  metric.Int64Counter
	dpErrors metric.Int64Counter
	// auth, when non-nil, enforces Keycloak Bearer JWT validation on the
	// data-plane (Phase 3). nil = no auth (Phase 1/2 + unit tests).
	auth *Authenticator
	// adminUser/adminPass guard /rest/apigateway/* with HTTP Basic, like the
	// real Integration Server. Env ADMIN_USER / ADMIN_PASSWORD, defaults
	// Administrator/manage (the trial image defaults targets.yaml carries).
	adminUser string
	adminPass string
}

func NewServer() *Server {
	meter := otel.Meter("webmethods-mock")
	calls, _ := meter.Int64Counter("webmethods_dataplane_requests_total",
		metric.WithDescription("Data-plane requests handled by the webMethods mock"))
	errs, _ := meter.Int64Counter("webmethods_dataplane_errors_total",
		metric.WithDescription("Data-plane requests refused (no API, inactive, out of contract, unresolved alias)"))
	return &Server{
		store:     NewStore(),
		now:       time.Now,
		dpCalls:   calls,
		dpErrors:  errs,
		auth:      NewAuthenticatorFromEnv(context.Background()),
		adminUser: envOr("ADMIN_USER", "Administrator"),
		adminPass: envOr("ADMIN_PASSWORD", "manage"),
	}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()

	// --- Admin REST surface (the exact dialect labctl's adapter speaks) ---
	admin := http.NewServeMux()
	admin.HandleFunc("GET /rest/apigateway/health", s.health)
	admin.HandleFunc("GET /rest/apigateway/apis", s.listAPIs)
	admin.HandleFunc("POST /rest/apigateway/apis", s.createAPI)
	admin.HandleFunc("GET /rest/apigateway/apis/{id}", s.getAPI)
	admin.HandleFunc("PUT /rest/apigateway/apis/{id}", s.updateAPI)
	admin.HandleFunc("POST /rest/apigateway/apis/{id}/versions", s.createVersionAPI)
	admin.HandleFunc("PUT /rest/apigateway/apis/{id}/activate", s.activateAPI)
	admin.HandleFunc("PUT /rest/apigateway/apis/{id}/deactivate", s.deactivateAPI)
	admin.HandleFunc("GET /rest/apigateway/alias", s.listAliases)
	admin.HandleFunc("POST /rest/apigateway/alias", s.createAlias)
	admin.HandleFunc("GET /rest/apigateway/alias/{id}", s.getAlias)
	admin.HandleFunc("PUT /rest/apigateway/alias/{id}", s.updateAlias)
	admin.HandleFunc("GET /rest/apigateway/policyActions", s.listActions)
	admin.HandleFunc("POST /rest/apigateway/policyActions", s.createAction)
	admin.HandleFunc("GET /rest/apigateway/policyActions/{id}", s.getAction)
	admin.HandleFunc("PUT /rest/apigateway/policyActions/{id}", s.updateAction)
	admin.HandleFunc("GET /rest/apigateway/policies/{id}", s.getPolicy)
	admin.HandleFunc("PUT /rest/apigateway/policies/{id}", s.updatePolicy)
	admin.HandleFunc("GET /rest/apigateway/applications", s.listApps)
	admin.HandleFunc("POST /rest/apigateway/applications", s.createApp)
	admin.HandleFunc("GET /rest/apigateway/applications/{id}", s.getApp)
	admin.HandleFunc("PUT /rest/apigateway/applications/{id}", s.updateApp)
	admin.HandleFunc("PUT /rest/apigateway/applications/{id}/apis", s.associateAPIs)
	admin.HandleFunc("GET /rest/apigateway/strategies", s.listStrategies)
	admin.HandleFunc("POST /rest/apigateway/strategies", s.createStrategy)
	admin.HandleFunc("GET /rest/apigateway/strategies/{id}", s.getStrategy)
	admin.HandleFunc("PUT /rest/apigateway/strategies/{id}", s.updateStrategy)
	admin.HandleFunc("PUT /rest/apigateway/strategies/{id}/refreshCredentials", s.refreshCredentials)
	admin.HandleFunc("GET /rest/apigateway/scopes", s.listScopes)
	admin.HandleFunc("POST /rest/apigateway/scopes", s.createScope)
	admin.HandleFunc("GET /rest/apigateway/scopes/{id}", s.getScope)
	admin.HandleFunc("PUT /rest/apigateway/scopes/{id}", s.updateScope)
	admin.HandleFunc("GET /rest/apigateway/configurations/keystore", s.getKeystore)
	admin.HandleFunc("PUT /rest/apigateway/configurations/keystore", s.putKeystore)
	admin.HandleFunc("GET /rest/apigateway/configurations/extended", s.getExtended)
	admin.HandleFunc("PUT /rest/apigateway/configurations/extended", s.putExtended)
	admin.HandleFunc("GET /rest/apigateway/users", s.listUsers)
	admin.HandleFunc("POST /rest/apigateway/users", s.createUser)
	admin.HandleFunc("GET /rest/apigateway/groups", s.listGroups)
	admin.HandleFunc("POST /rest/apigateway/groups", s.createGroup)
	admin.HandleFunc("PUT /rest/apigateway/groups/{id}", s.updateGroup)
	admin.HandleFunc("GET /rest/apigateway/accessProfiles", s.listProfiles)
	admin.HandleFunc("POST /rest/apigateway/accessProfiles", s.createProfile)
	admin.HandleFunc("PUT /rest/apigateway/accessProfiles/{id}", s.updateProfile)
	admin.HandleFunc("POST /rest/apigateway/transactionalEvents", s.events)

	// Legacy liveness route, kept OPEN (no Basic) on purpose: scripts/up.sh and
	// scripts/smoke-test.sh probe it without credentials. Everything else under
	// /rest/apigateway/* is Basic-auth'd like the real Integration Server.
	mux.HandleFunc("GET /rest/apigateway/is/health", s.legacyHealth)
	mux.Handle("/rest/apigateway/", s.requireBasicAuth(admin))

	// --- Data-plane: /gateway/{apiName}/{apiVersion}/{resource...} ---
	// Phase 3: when a Keycloak authenticator is configured, the data-plane
	// requires a valid Bearer JWT (the admin surface keeps its own Basic gate,
	// like a real gateway's management plane).
	if s.auth != nil {
		mux.Handle("/gateway/", s.auth.Middleware(http.HandlerFunc(s.dataPlane)))
	} else {
		mux.HandleFunc("/gateway/", s.dataPlane)
	}

	// Liveness for the docker healthcheck binary (plain, no auth).
	mux.HandleFunc("GET /health", s.legacyHealth)

	return mux
}

// requireBasicAuth guards the admin surface: the real product answers 401 with
// a Basic challenge on missing/bad credentials for EVERY /rest/apigateway/*
// call. Constant-time compare — fail closed, never leak which half mismatched.
func (s *Server) requireBasicAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, pass, ok := r.BasicAuth()
		userOK := subtle.ConstantTimeCompare([]byte(user), []byte(s.adminUser)) == 1
		passOK := subtle.ConstantTimeCompare([]byte(pass), []byte(s.adminPass)) == 1
		if !ok || !userOK || !passOK {
			w.Header().Set("WWW-Authenticate", `Basic realm="Integration Server"`)
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "Unauthorized"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Gateway", "webmethods-mock")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

// health serves the 10.15 admin health document. The labctl adapter treats a
// 200 as "reachable AND credentials accepted" and refuses status=red.
func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"status": "green", "gateway": "webmethods-mock"})
}

// legacyHealth keeps the historical mock liveness shape ({"isAlive":true}) for
// docker healthchecks and the existing up/smoke scripts.
func (s *Server) legacyHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"isAlive": true, "gateway": "webmethods-mock"})
}
