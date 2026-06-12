package main

// Store is the in-memory state of the mock — the standalone equivalent of the
// real gateway's registry, guarded by one mutex (no persistence: a restart
// wipes the simulated dev/rec/int environments, acceptable for the CI demo).
//
// État en mémoire uniquement; tout accès passe par le mutex — les handlers ne
// touchent jamais une map sans verrou. // All access goes through the mutex.

import (
	"fmt"
	"sync"
)

// apiRecord is one imported API. The exported fields use the REAL 10.15 wire
// keys (record id is "id", NOT apiId; camelCase apiName/apiVersion) so the
// envelopes in admin.go serialize the product's exact shape.
type apiRecord struct {
	ID         string   `json:"id"`
	APIName    string   `json:"apiName"`
	APIVersion string   `json:"apiVersion"`
	IsActive   bool     `json:"isActive"`
	Type       string   `json:"type"`
	Policies   []string `json:"policies"`

	// Definition is the decoded apiDefinition of the LAST import — data-plane
	// only (resource allowlist matching), never serialized back to the admin
	// surface (the labctl adapter does not read it).
	Definition map[string]any `json:"-"`
}

// Store holds every gateway-side object family the labctl adapter (and the
// multi-env UAC converge) talks to. Generic records stay map[string]any so
// unknown fields round-trip verbatim, exactly like the real product preserves
// what it does not model.
type Store struct {
	mu         sync.RWMutex
	apis       map[string]*apiRecord
	policies   map[string]map[string]any // id -> policy record (raw)
	actions    map[string]map[string]any // id -> policyAction record (raw)
	aliases    map[string]map[string]any // id -> alias record (raw, password stored as received)
	apps       map[string]map[string]any // id -> application record (raw)
	appAPIs    map[string][]string       // appId -> associated apiIDs
	strategies map[string]map[string]any // id -> OAUTH2 strategy record (raw)
	scopes     map[string]map[string]any // id -> scope mapping record (raw)
	keystore   map[string]any            // gateway-wide keystore/truststore config
	seq        map[string]int            // per-kind id sequence
}

func NewStore() *Store {
	return &Store{
		apis:       map[string]*apiRecord{},
		policies:   map[string]map[string]any{},
		actions:    map[string]map[string]any{},
		aliases:    map[string]map[string]any{},
		apps:       map[string]map[string]any{},
		appAPIs:    map[string][]string{},
		strategies: map[string]map[string]any{},
		scopes:     map[string]map[string]any{},
		keystore: map[string]any{
			"truststoreName": "", "keystoreName": "", "signingAlias": "",
		},
		seq: map[string]int{},
	}
}

// nextID mints "wm-<kind>-NNNN" — stable, monotonic ids per object family,
// the same style as the labctl test fixtures. Caller MUST hold the lock.
func (s *Store) nextID(kind string) string {
	s.seq[kind]++
	return fmt.Sprintf("wm-%s-%04d", kind, s.seq[kind])
}

// findAPIByName returns the first API with apiName (any version) — the 409
// identity on POST /apis. Caller MUST hold the lock.
func (s *Store) findAPIByName(name string) *apiRecord {
	for _, a := range s.apis {
		if a.APIName == name {
			return a
		}
	}
	return nil
}

// findAPIByNameVersion resolves the data-plane coordinates
// /gateway/{apiName}/{apiVersion}. Caller MUST hold the lock.
func (s *Store) findAPIByNameVersion(name, version string) *apiRecord {
	for _, a := range s.apis {
		if a.APIName == name && a.APIVersion == version {
			return a
		}
	}
	return nil
}

// aliasByName returns the alias record with that name ("" id when absent).
// Alias names ARE the stable identity on 10.15 (re-POST of a name is a 409),
// and the ${aliasName} routing substitution resolves by name, not id.
// Caller MUST hold the lock.
func (s *Store) aliasByName(name string) map[string]any {
	for _, al := range s.aliases {
		if n, _ := al["name"].(string); n == name {
			return al
		}
	}
	return nil
}
