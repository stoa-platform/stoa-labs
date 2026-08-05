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

	// Owner mirrors the client's custom "approvers projected into owner" field
	// (Task 8, ADR pending) — measured live at apiResponse.api.owner (api level,
	// NOT apiResponse level, unlike `teams`), a STRING, absent from GET /apis
	// (list) and present on GET /apis/{id} (single). omitempty reproduces the
	// absent-until-first-write behaviour: a freshly imported API carries no
	// owner in the mock (the real gateway's own default is the creator's login,
	// never captured live — out of scope to reproduce).
	Owner string `json:"owner,omitempty"`

	// Definition is the decoded apiDefinition of the LAST import — data-plane
	// only (resource allowlist matching), never serialized back to the admin
	// surface (the labctl adapter does not read it).
	Definition map[string]any `json:"-"`

	// Teams is the API's team scoping. `json:"-"` is LOAD-BEARING: measured on
	// the real 10.15 (2026-08-05), teams live at the apiResponse level and
	// `apiResponse.api.teams` is NULL — the envelope emits them, the record
	// never does (viser le mauvais niveau donne un « aucune team » silencieux,
	// piège déjà épinglé dans apim_publish_api/tasks/team.yml). Names only here;
	// apiEnvelope re-inflates the {id,name,source} shape.
	Teams []string `json:"-"`
}

// Store holds every gateway-side object family the labctl adapter (and the
// multi-env UAC converge) talks to. Generic records stay map[string]any so
// unknown fields round-trip verbatim, exactly like the real product preserves
// what it does not model.
type Store struct {
	mu       sync.RWMutex
	apis     map[string]*apiRecord
	policies map[string]map[string]any // id -> policy record (raw)
	actions  map[string]map[string]any // id -> policyAction record (raw)
	aliases  map[string]map[string]any // id -> alias record (raw, password stored as received)
	apps     map[string]map[string]any // id -> application record (raw)
	appAPIs  map[string][]string       // appId -> associated apiIDs
	// latestVersionID tracks, per apiName lineage, which record id is
	// currently the "latest" version — the ONLY id createVersionAPI accepts
	// (mesuré 2026-08-05, spike-api-versions-1015: "Versioning is allowed
	// only from latest version", HTTP 400 including on a SECOND call against
	// the SAME id right after a first successful mint). Set at import
	// (createAPI) and advanced on every successful mint (createVersionAPI).
	latestVersionID map[string]string
	strategies      map[string]map[string]any // id -> OAUTH2 strategy record (raw)
	scopes          map[string]map[string]any // id -> scope mapping record (raw)
	keystore        map[string]any            // gateway-wide keystore/truststore config
	users           map[string]map[string]any // id -> user record (raw)
	groups          map[string]map[string]any // id -> group record (raw); system groups (id==name) preinstalled
	profiles        map[string]map[string]any // id -> accessProfile record (raw); system profiles (id==name) preinstalled
	teamWork        bool                      // enableTeamWork (configurations/extended); false by default
	seq             map[string]int            // per-kind id sequence
}

func NewStore() *Store {
	return &Store{
		apis:            map[string]*apiRecord{},
		policies:        map[string]map[string]any{},
		actions:         map[string]map[string]any{},
		aliases:         map[string]map[string]any{},
		apps:            map[string]map[string]any{},
		appAPIs:         map[string][]string{},
		latestVersionID: map[string]string{},
		strategies:      map[string]map[string]any{},
		scopes:          map[string]map[string]any{},
		keystore: map[string]any{
			"truststoreName": "", "keystoreName": "", "signingAlias": "",
		},
		users: map[string]map[string]any{},
		// Groupes SYSTÈME livrés d'usine par la vraie gateway : id == name
		// (mesuré 2026-08-03), contrairement aux groupes CUSTOM créés par POST
		// (id UUID). keepKnown() en dépend : un nom de groupe système EST un id
		// connu, un nom de groupe custom ne l'est jamais.
		groups: map[string]map[string]any{
			"Administrators": {
				"id": "Administrators", "name": "Administrators", "systemDefined": true,
			},
			"API-Gateway-Administrators": {
				"id": "API-Gateway-Administrators", "name": "API-Gateway-Administrators", "systemDefined": true,
			},
			"API-Gateway-Providers": {
				"id": "API-Gateway-Providers", "name": "API-Gateway-Providers", "systemDefined": true,
			},
			"Everybody": {
				"id": "Everybody", "name": "Everybody", "systemDefined": true,
			},
		},
		// AccessProfiles SYSTÈME, même règle id==name ; groupIds mesurés en clair
		// sur la gateway.
		profiles: map[string]map[string]any{
			"Administrators": {
				"id": "Administrators", "name": "Administrators", "systemDefined": true,
				"groupIds": []any{"Administrators", "API-Gateway-Administrators"},
			},
			"API-Gateway-Providers": {
				"id": "API-Gateway-Providers", "name": "API-Gateway-Providers", "systemDefined": true,
				"groupIds": []any{"API-Gateway-Providers"},
			},
			"Default": {
				"id": "Default", "name": "Default", "systemDefined": true,
				"groupIds": []any{"Everybody"},
			},
		},
		teamWork: false,
		seq:      map[string]int{},
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
