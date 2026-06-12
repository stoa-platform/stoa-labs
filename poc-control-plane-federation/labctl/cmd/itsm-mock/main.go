// Command itsm-mock is a minimal in-memory change-management (ITSM) mock for
// the production gate of the governance chain (environments.yaml itsmCheck):
// governance-api asks it whether a change reference is "approved" before
// merging a promotion. Stdlib only, state in memory behind a mutex — a lab
// stand-in for ServiceNow/Jira, never a production system.
//
//	GET  /health                     -> {"status":"ok"}
//	GET  /changes/{id}               -> {"id","status","summary"} (404 unknown)
//	POST /changes                    -> create {"id","status","summary"}
//	PUT  /changes/{id}/status        -> {"status":"approved"|...}
//
// Seed: ITSM_SEED is a JSON array (inline, or @/path/to/file), default:
// [{"id":"CHG-0001","status":"approved"},{"id":"CHG-0002","status":"draft"}].
// Listen: LISTEN_ADDR (default :8788). Run from labctl/:
//
//	go run ./cmd/itsm-mock
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
)

// change is one ITSM change record.
type change struct {
	ID      string `json:"id"`
	Status  string `json:"status"`
	Summary string `json:"summary,omitempty"`
}

// store is the in-memory change registry (mutex: the mock is concurrent-safe,
// like the gate evaluation calling it).
type store struct {
	mu      sync.Mutex
	changes map[string]change
}

// defaultSeed mirrors the demo script: one approved change, one draft.
const defaultSeed = `[{"id":"CHG-0001","status":"approved"},{"id":"CHG-0002","status":"draft"}]`

// loadSeed parses ITSM_SEED (inline JSON, or @path to a JSON file). An
// unreadable seed is fatal: a mock seeded with garbage would fail the demo
// later and further from the cause.
func loadSeed(raw string) (map[string]change, error) {
	if raw == "" {
		raw = defaultSeed
	}
	if strings.HasPrefix(raw, "@") {
		b, err := os.ReadFile(strings.TrimPrefix(raw, "@"))
		if err != nil {
			return nil, fmt.Errorf("itsm-mock: read seed file: %w", err)
		}
		raw = string(b)
	}
	var list []change
	if err := json.Unmarshal([]byte(raw), &list); err != nil {
		return nil, fmt.Errorf("itsm-mock: parse seed JSON: %w", err)
	}
	out := make(map[string]change, len(list))
	for _, c := range list {
		if c.ID == "" {
			return nil, fmt.Errorf("itsm-mock: seed entry without id")
		}
		out[c.ID] = c
	}
	return out, nil
}

// handler builds the routed mux (Go 1.22 method+pattern routing).
func handler(st *store) http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})

	mux.HandleFunc("GET /changes/{id}", func(w http.ResponseWriter, r *http.Request) {
		st.mu.Lock()
		c, ok := st.changes[r.PathValue("id")]
		st.mu.Unlock()
		if !ok {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "change inconnu: " + r.PathValue("id")})
			return
		}
		writeJSON(w, http.StatusOK, c)
	})

	mux.HandleFunc("POST /changes", func(w http.ResponseWriter, r *http.Request) {
		var c change
		if err := json.NewDecoder(r.Body).Decode(&c); err != nil || c.ID == "" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "corps JSON invalide (id requis)"})
			return
		}
		if c.Status == "" {
			c.Status = "draft" // un changement naît non approuvé (fail-closed)
		}
		st.mu.Lock()
		st.changes[c.ID] = c
		st.mu.Unlock()
		writeJSON(w, http.StatusCreated, c)
	})

	mux.HandleFunc("PUT /changes/{id}/status", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Status string `json:"status"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Status == "" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "corps JSON invalide (status requis)"})
			return
		}
		id := r.PathValue("id")
		st.mu.Lock()
		c, ok := st.changes[id]
		if ok {
			c.Status = body.Status
			st.changes[id] = c
		}
		st.mu.Unlock()
		if !ok {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "change inconnu: " + id})
			return
		}
		writeJSON(w, http.StatusOK, c)
	})

	return mux
}

// writeJSON renders v with the canonical content type.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func main() {
	seed, err := loadSeed(os.Getenv("ITSM_SEED"))
	if err != nil {
		log.Fatalf("%v", err)
	}
	st := &store{changes: seed}

	listen := os.Getenv("LISTEN_ADDR")
	if listen == "" {
		listen = ":8788"
	}
	log.Printf("itsm-mock: %d changes seeded, listen=%s (in-memory, lab only)", len(seed), listen)
	if err := http.ListenAndServe(listen, handler(st)); err != nil {
		log.Fatalf("itsm-mock: %v", err)
	}
}
