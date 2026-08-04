package main

// Surfaces Teams du dialecte 10.15 — users, groupes, accessProfiles et le
// commutateur global enableTeamWork.
//
// Ces handlers existent pour reproduire des ÉCHECS SILENCIEUX, pas seulement
// des succès. Comportements mesurés sur la gateway (spike F4 T1, 2026-08-03)
// sont reproduits ici parce qu'un rôle qui ne s'y casse pas les dents en test
// se les cassera en production :
//
//   - userIds/groupIds passés par un NOM CUSTOM : acceptés (200) et IGNORÉS —
//     la liste relue est vide, aucun message, aucun code d'erreur. Mais pour
//     les objets SYSTÈME préinstallés (groupes Administrators,
//     API-Gateway-Administrators, API-Gateway-Providers, Everybody ;
//     accessProfiles Administrators, API-Gateway-Providers, Default),
//     id == name : leur nom EST donc un id connu, et passe. Ce n'est pas une
//     exception au piège — même règle (keepKnown, id connu ou pas), id
//     différent. Voir Store.NewStore() dans store.go.
//   - enableTeamWork vit sous le configId "extended" (PAS "extendedSettings")
//     et vaut "false" par défaut — l'état de l'environnement visé. La vraie
//     gateway l'expose au milieu de 109 autres clés ; le mock n'en rend qu'une.
//   - la valeur est une CHAÎNE "true"/"false", pas un booléen JSON.
//
// Les ids CUSTOM (créés par POST) sont des UUID DÉTERMINISTES (dérivés du
// compteur de Store) : le vrai produit en mint des aléatoires (mesuré :
// 1fcddbf2-f8f5-4f19-9b85-860b708f1f3a), mais un mock déterministe rend les
// tests reproductibles, et la seule propriété dont le rôle dépend est « l'id
// n'est pas le nom ».

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
)

// uuid rend un identifiant de forme UUID à partir du compteur de la famille
// donnée. Caller MUST hold the lock.
func (s *Store) uuid(kind string) string {
	s.seq[kind]++
	n := s.seq[kind]
	return fmt.Sprintf("%08d-0000-4000-8000-%012d", n, n)
}

// --- configurations/extended -------------------------------------------------

func (s *Server) getExtended(w http.ResponseWriter, _ *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	writeJSON(w, http.StatusOK, map[string]any{
		"enableTeamWork": fmt.Sprintf("%t", s.store.teamWork),
	})
}

func (s *Server) putExtended(w http.ResponseWriter, r *http.Request) {
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	s.store.mu.Lock()
	if v, ok := in["enableTeamWork"]; ok {
		s.store.teamWork = fmt.Sprintf("%v", v) == "true"
	}
	s.store.mu.Unlock()
	s.getExtended(w, r)
}

// --- users ---------------------------------------------------------------------

func (s *Server) listUsers(w http.ResponseWriter, _ *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	ids := make([]string, 0, len(s.store.users))
	for id := range s.store.users {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	items := make([]any, 0, len(ids))
	for _, id := range ids {
		items = append(items, s.store.users[id])
	}
	writeJSON(w, http.StatusOK, map[string]any{"users": items})
}

func (s *Server) createUser(w http.ResponseWriter, r *http.Request) {
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	id := s.store.uuid("user")
	in["id"] = id
	// Le mot de passe n'est jamais relu par le produit : on ne le stocke pas,
	// pour qu'aucun test ne puisse en dépendre par accident.
	delete(in, "password")
	s.store.users[id] = in
	writeJSON(w, http.StatusCreated, in)
}

// --- groupes ---------------------------------------------------------------------

func (s *Server) listGroups(w http.ResponseWriter, _ *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	ids := make([]string, 0, len(s.store.groups))
	for id := range s.store.groups {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	items := make([]any, 0, len(ids))
	for _, id := range ids {
		items = append(items, s.store.groups[id])
	}
	writeJSON(w, http.StatusOK, map[string]any{"groups": items})
}

func (s *Server) createGroup(w http.ResponseWriter, r *http.Request) {
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	id := s.store.uuid("group")
	in["id"] = id
	in["userIds"] = s.keepKnown(in["userIds"], s.store.users)
	s.store.groups[id] = in
	writeJSON(w, http.StatusCreated, in)
}

// updateGroup REPLACES a group wholesale, like updateApp/updateAction
// elsewhere in this mock. Unlike the brief's first draft, it does NOT
// auto-create missing ids: the system groups (API-Gateway-Providers included)
// are preinstalled by NewStore(), so a PUT to an unknown id is genuinely an
// error, exactly like every other update handler in this file.
func (s *Server) updateGroup(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	if _, ok := s.store.groups[id]; !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "group not found"})
		return
	}
	in["id"] = id
	in["userIds"] = s.keepKnown(in["userIds"], s.store.users)
	s.store.groups[id] = in
	writeJSON(w, http.StatusOK, in)
}

// --- accessProfiles (les « teams ») ------------------------------------------

func (s *Server) listProfiles(w http.ResponseWriter, _ *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	ids := make([]string, 0, len(s.store.profiles))
	for id := range s.store.profiles {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	items := make([]any, 0, len(ids))
	for _, id := range ids {
		items = append(items, s.store.profiles[id])
	}
	writeJSON(w, http.StatusOK, map[string]any{"accessProfiles": items})
}

func (s *Server) createProfile(w http.ResponseWriter, r *http.Request) {
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	id := s.store.uuid("profile")
	in["id"] = id
	in["groupIds"] = s.keepKnown(in["groupIds"], s.store.groups)
	s.store.profiles[id] = in
	writeJSON(w, http.StatusCreated, in)
}

func (s *Server) updateProfile(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var in map[string]any
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	if _, ok := s.store.profiles[id]; !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "accessProfile not found"})
		return
	}
	in["id"] = id
	in["groupIds"] = s.keepKnown(in["groupIds"], s.store.groups)
	s.store.profiles[id] = in
	writeJSON(w, http.StatusOK, in)
}

// keepKnown ne conserve que les entrées qui sont des ids CONNUS de la famille
// visée. C'est LE piège : le produit accepte n'importe quoi (200) et jette
// silencieusement ce qui n'est pas un id. Pour les objets SYSTÈME préinstallés
// (id == name), passer le NOM fonctionne donc — ce n'est pas une exception au
// piège, juste la conséquence de leur id particulier. Caller MUST hold the lock.
func (s *Server) keepKnown(raw any, known map[string]map[string]any) []any {
	out := []any{}
	list, ok := raw.([]any)
	if !ok {
		return out
	}
	for _, v := range list {
		if id, ok := v.(string); ok {
			if _, exists := known[id]; exists {
				out = append(out, id)
			}
		}
	}
	return out
}
