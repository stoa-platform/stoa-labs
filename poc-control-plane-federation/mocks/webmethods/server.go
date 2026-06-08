package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"sync"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
)

// API mirrors the subset of the webMethods API Gateway admin model that the
// STOA webMethods adapter relies on. The mock is intentionally a faithful
// stand-in: the same surface a real `apigateway:10.15` exposes, so the Link
// can be repointed at the real product without changing its code.
type API struct {
	ID         string `json:"apiId"`
	Name       string `json:"apiName"`
	Version    string `json:"apiVersion"`
	BasePath   string `json:"basePath"`
	BackendURL string `json:"backendUrl"`
	CreatedAt  string `json:"createdAt"`
}

// Subscription mirrors a webMethods application subscription (consumer).
type Subscription struct {
	ID          string `json:"subscriptionId"`
	Application string `json:"applicationName"`
	APIID       string `json:"apiId"`
	ClientID    string `json:"clientId"`
	CreatedAt   string `json:"createdAt"`
}

// Store is the in-memory state of the mock. Synthetic only, no persistence.
type Store struct {
	mu   sync.RWMutex
	apis map[string]*API
	subs map[string]*Subscription
	seq  int
}

func NewStore() *Store {
	return &Store{apis: map[string]*API{}, subs: map[string]*Subscription{}}
}

func (s *Store) nextID(prefix string) string {
	s.seq++
	return fmt.Sprintf("%s-%04d", prefix, s.seq)
}

// Server wires the admin REST surface, the data-plane proxy and OTel metrics.
type Server struct {
	store    *Store
	now      func() time.Time
	dpCalls  metric.Int64Counter
	dpErrors metric.Int64Counter
	// auth, when non-nil, enforces Keycloak Bearer JWT validation on the
	// data-plane (Phase 3). nil = no auth (Phase 1/2 + unit tests).
	auth *Authenticator
}

func NewServer() *Server {
	meter := otel.Meter("webmethods-mock")
	calls, _ := meter.Int64Counter("webmethods_dataplane_requests_total",
		metric.WithDescription("Data-plane requests handled by the webMethods mock"))
	errs, _ := meter.Int64Counter("webmethods_dataplane_errors_total",
		metric.WithDescription("Data-plane requests with no matching API"))
	return &Server{
		store:    NewStore(),
		now:      time.Now,
		dpCalls:  calls,
		dpErrors: errs,
		auth:     NewAuthenticatorFromEnv(context.Background()),
	}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()

	// --- Admin REST surface (what the STOA webMethods adapter calls) ---
	mux.HandleFunc("GET /rest/apigateway/is/health", s.health)
	mux.HandleFunc("GET /rest/apigateway/apis", s.listAPIs)
	mux.HandleFunc("POST /rest/apigateway/apis", s.createAPI)
	mux.HandleFunc("GET /rest/apigateway/apis/{id}", s.getAPI)
	mux.HandleFunc("DELETE /rest/apigateway/apis/{id}", s.deleteAPI)
	mux.HandleFunc("GET /rest/apigateway/subscriptions", s.listSubscriptions)
	mux.HandleFunc("POST /rest/apigateway/subscriptions", s.createSubscription)
	mux.HandleFunc("POST /rest/apigateway/transactionalEvents", s.events)

	// --- Data-plane: everything under /gateway/<basePath>/... ---
	// Phase 3: when a Keycloak authenticator is configured, the data-plane
	// requires a valid Bearer JWT (the admin surface above stays open, like a
	// real gateway's management plane).
	if s.auth != nil {
		mux.Handle("/gateway/", s.auth.Middleware(http.HandlerFunc(s.dataPlane)))
	} else {
		mux.HandleFunc("/gateway/", s.dataPlane)
	}

	// Liveness for docker healthcheck (plain, no auth).
	mux.HandleFunc("GET /health", s.health)

	return mux
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Gateway", "webmethods-mock")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	// webMethods /is/health returns an "isAlive" envelope.
	writeJSON(w, http.StatusOK, map[string]any{"isAlive": true, "gateway": "webmethods-mock"})
}

func (s *Server) listAPIs(w http.ResponseWriter, _ *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	out := make([]*API, 0, len(s.store.apis))
	for _, a := range s.store.apis {
		out = append(out, a)
	}
	writeJSON(w, http.StatusOK, map[string]any{"apis": out, "count": len(out)})
}

func (s *Server) createAPI(w http.ResponseWriter, r *http.Request) {
	var in API
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	if in.Name == "" || in.BasePath == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "apiName and basePath are required"})
		return
	}
	in.BasePath = "/" + strings.Trim(in.BasePath, "/")
	s.store.mu.Lock()
	in.ID = s.store.nextID("api")
	in.CreatedAt = s.now().UTC().Format(time.RFC3339)
	if in.Version == "" {
		in.Version = "1.0.0"
	}
	s.store.apis[in.ID] = &in
	s.store.mu.Unlock()
	writeJSON(w, http.StatusCreated, in)
}

func (s *Server) getAPI(w http.ResponseWriter, r *http.Request) {
	s.store.mu.RLock()
	a, ok := s.store.apis[r.PathValue("id")]
	s.store.mu.RUnlock()
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "api not found"})
		return
	}
	writeJSON(w, http.StatusOK, a)
}

func (s *Server) deleteAPI(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	s.store.mu.Lock()
	_, ok := s.store.apis[id]
	delete(s.store.apis, id)
	s.store.mu.Unlock()
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "api not found"})
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) listSubscriptions(w http.ResponseWriter, _ *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	out := make([]*Subscription, 0, len(s.store.subs))
	for _, sub := range s.store.subs {
		out = append(out, sub)
	}
	writeJSON(w, http.StatusOK, map[string]any{"subscriptions": out, "count": len(out)})
}

func (s *Server) createSubscription(w http.ResponseWriter, r *http.Request) {
	var in Subscription
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	if in.Application == "" || in.ClientID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "applicationName and clientId are required"})
		return
	}
	s.store.mu.Lock()
	in.ID = s.store.nextID("sub")
	in.CreatedAt = s.now().UTC().Format(time.RFC3339)
	s.store.subs[in.ID] = &in
	s.store.mu.Unlock()
	writeJSON(w, http.StatusCreated, in)
}

func (s *Server) events(w http.ResponseWriter, r *http.Request) {
	// webMethods pushes transactional events here; the mock accepts and drops.
	_, _ = io.Copy(io.Discard, r.Body)
	w.WriteHeader(http.StatusAccepted)
}

// dataPlane routes /gateway/<basePath>/... to the registered backend (reverse
// proxy) or returns a synthetic response when no backend URL is configured.
func (s *Server) dataPlane(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/gateway")
	api := s.matchAPI(path)
	if api == nil {
		s.dpErrors.Add(r.Context(), 1)
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "no API registered for path", "path": path})
		return
	}
	s.dpCalls.Add(r.Context(), 1, metric.WithAttributes(
		attribute.String("api", api.Name),
		attribute.String("basePath", api.BasePath),
	))

	if api.BackendURL != "" {
		target, err := url.Parse(api.BackendURL)
		if err != nil {
			writeJSON(w, http.StatusBadGateway, map[string]string{"error": "bad backend url"})
			return
		}
		proxy := httputil.NewSingleHostReverseProxy(target)
		r.URL.Path = strings.TrimPrefix(path, api.BasePath)
		r.Host = target.Host
		proxy.ServeHTTP(w, r)
		return
	}

	// Synthetic response — zero real data.
	writeJSON(w, http.StatusOK, map[string]any{
		"gateway":   "webmethods-mock",
		"api":       api.Name,
		"path":      path,
		"synthetic": true,
		"data":      []any{},
	})
}

func (s *Server) matchAPI(path string) *API {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	var best *API
	for _, a := range s.store.apis {
		if path == a.BasePath || strings.HasPrefix(path, a.BasePath+"/") {
			if best == nil || len(a.BasePath) > len(best.BasePath) {
				best = a
			}
		}
	}
	return best
}
