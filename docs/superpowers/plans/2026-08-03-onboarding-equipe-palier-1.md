# Onboarding d'équipe — palier 1 : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Faire de la création d'équipe un rôle Ansible piloté par un fichier déclaratif par environnement, et réparer la variable `apim_ss_require_team` qui ne commande aujourd'hui que les assertions.

**Architecture:** Le mock webMethods du dépôt gagne les surfaces Teams (`/users`, `/groups`, `/accessProfiles`, `/configurations/extended`) **avec leurs pièges à succès silencieux** — ce qui rend testable hors ligne tout ce qui suit. Une sonde partagée dans `apim_common` établit l'état de la feature et applique une table de vérité à quatre lignes. Un rôle `apim_team_onboard` pose Vault puis la gateway, à partir de `ansible/providers.<env>.yml`.

**Tech Stack:** Ansible (module `uri`, pas de collection tierce), Go stdlib (mock, `net/http` + `http.ServeMux` méthode+motif), Vault KV v2 en REST, bash pour le script de preuve.

**Spec :** `docs/superpowers/specs/2026-08-03-onboarding-equipe-design.md`

## Global Constraints

- **Ansible pur** — le client n'installe pas `labctl` ; toute mutation passe par `ansible.builtin.uri`.
- **Go stdlib uniquement** dans `mocks/webmethods/` — environnement air-gapped, `GOPROXY=off`, aucune dépendance nouvelle.
- **Fail-closed par défaut** — `apim_ss_require_team: true`, `apim_ss_teams_feature: auto`.
- **Aucun secret dans les logs** — `no_log: true` sur toute tâche touchant un mot de passe ou un token, y compris en `stoa_debug`.
- **Read-back après chaque écriture** — un code HTTP 2xx ne prouve rien sur cette API : les quatre pièges du spike F4 sont des succès silencieux.
- **Nommage** — `apim_onb_*` pour le rôle d'onboarding, `apim_ss_*` pour ce qui vit dans `apim_common` (convention existante du dépôt).
- **Racine de travail** — tous les chemins sont relatifs à `poc-control-plane-federation/` sauf mention contraire.

---

## Structure des fichiers

| Fichier | Responsabilité |
|---|---|
| `mocks/webmethods/admin_teams.go` | **créé** — les 4 surfaces Teams du mock et leurs pièges |
| `mocks/webmethods/admin_teams_test.go` | **créé** — tests des pièges (noms ignorés, feature OFF par défaut) |
| `mocks/webmethods/store.go` | **modifié** — 3 maps + 1 booléen |
| `mocks/webmethods/server.go` | **modifié** — enregistrement des routes |
| `ansible/roles/apim_common/tasks/teams-feature.yml` | **créé** — sonde + table de vérité (une seule place pour les deux rôles) |
| `ansible/roles/apim_common/defaults/main.yml` | **modifié** — `apim_ss_teams_feature` |
| `ansible/roles/apim_selfservice_app/tasks/main.yml` | **modifié** — la sonde commande le travail |
| `ansible/roles/apim_selfservice_app/tasks/{team,verify}.yml` | **modifié** — idem |
| `ansible/roles/apim_publish_api/tasks/{main,team,verify}.yml` | **modifié** — idem |
| `ansible/providers.dev.yml` | **créé** — la source déclarative |
| `ansible/roles/apim_team_onboard/defaults/main.yml` | **créé** — gabarits de convention |
| `ansible/roles/apim_team_onboard/tasks/resolve.yml` | **créé** — cible, garde du nom, dérivations |
| `ansible/roles/apim_team_onboard/tasks/vault.yml` | **créé** — secret, KV, policy |
| `ansible/roles/apim_team_onboard/tasks/gateway.yml` | **créé** — user, groupe, adhésion, accessProfile |
| `ansible/roles/apim_team_onboard/tasks/verify.yml` | **créé** — relecture des deux systèmes |
| `ansible/roles/apim_team_onboard/tasks/main.yml` | **créé** — orchestration |
| `ansible/onboard-team.yml` | **créé** — playbook |
| `ansible/tests/onboard/*.yml` | **créé** — fixtures des tests hors ligne |
| `ansible/test-onboard-guards.yml` | **créé** — boucle rapide hors ligne |
| `ansible/roles/apim_publish_api/tasks/approvers.yml` | **créé** — projection dans `owner` |
| `scripts/test-onboard-team.sh` | **créé** — les 7 preuves live |

---

## Task 1: Surfaces Teams du mock

Sans elles, tout le reste ne se teste que sur le cluster. Avec elles, la boucle est de quelques secondes.

**Files:**
- Create: `mocks/webmethods/admin_teams.go`
- Create: `mocks/webmethods/admin_teams_test.go`
- Modify: `mocks/webmethods/store.go:40-60` (struct `Store` + `NewStore`)
- Modify: `mocks/webmethods/server.go:91` (après la route keystore)

**Interfaces:**
- Consumes: `Store` (mutex + maps + `seq`), helpers existants de `admin.go` (`writeJSON`, `readJSON` — vérifier leurs noms réels avant d'écrire, cf. étape 1).
- Produces: routes `GET|PUT /rest/apigateway/configurations/extended`, `GET|POST /rest/apigateway/users`, `GET|POST /rest/apigateway/groups`, `PUT /rest/apigateway/groups/{id}`, `GET|POST /rest/apigateway/accessProfiles`, `PUT /rest/apigateway/accessProfiles/{id}`. Ids de la forme `%08d-0000-4000-8000-%012d`.

- [ ] **Step 1: Relever les helpers réels du mock**

Les noms ci-dessous sont supposés — vérifie-les avant d'écrire, et utilise ceux du dépôt :

```bash
cd poc-control-plane-federation/mocks/webmethods
grep -n 'func (s \*Server) writeJSON\|func writeJSON\|json.NewEncoder\|func (s \*Store) nextID\|seq\[' *.go | head -20
```

Note les signatures exactes d'écriture JSON et de génération d'id. Si le mock encode en ligne (`json.NewEncoder(w).Encode(...)`), fais pareil : ne crée pas un helper de plus.

- [ ] **Step 2: Écrire le test qui échoue**

`mocks/webmethods/admin_teams_test.go` :

```go
package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// post envoie un POST Basic-authentifié et rend le corps décodé.
func post(t *testing.T, srv *httptest.Server, path string, body any) map[string]any {
	t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest("POST", srv.URL+path, bytes.NewReader(b))
	req.SetBasicAuth("Administrator", "manage")
	req.Header.Set("Content-Type", "application/json")
	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatalf("POST %s: %v", path, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 && resp.StatusCode != 201 {
		t.Fatalf("POST %s: HTTP %d", path, resp.StatusCode)
	}
	var out map[string]any
	json.NewDecoder(resp.Body).Decode(&out)
	return out
}

func get(t *testing.T, srv *httptest.Server, path string) map[string]any {
	t.Helper()
	req, _ := http.NewRequest("GET", srv.URL+path, nil)
	req.SetBasicAuth("Administrator", "manage")
	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatalf("GET %s: %v", path, err)
	}
	defer resp.Body.Close()
	var out map[string]any
	json.NewDecoder(resp.Body).Decode(&out)
	return out
}

// La feature est ÉTEINTE par défaut : c'est l'état de l'environnement visé.
func TestTeamWorkDefaultsOff(t *testing.T) {
	srv := httptest.NewServer(NewServer().Handler())
	defer srv.Close()
	got := get(t, srv, "/rest/apigateway/configurations/extended")
	if got["enableTeamWork"] != "false" {
		t.Fatalf("enableTeamWork = %v, attendu \"false\"", got["enableTeamWork"])
	}
}

// LE PIÈGE : groupIds passés par NOM sont ignorés en silence — 200, liste vide.
// C'est le comportement mesuré du produit ; le rôle doit s'y casser les dents
// en test, pas en production.
func TestAccessProfileIgnoresGroupNames(t *testing.T) {
	srv := httptest.NewServer(NewServer().Handler())
	defer srv.Close()

	post(t, srv, "/rest/apigateway/groups", map[string]any{
		"name": "banking-demo-devs", "type": "local"})

	prof := post(t, srv, "/rest/apigateway/accessProfiles", map[string]any{
		"name": "banking-demo", "privilege": "111100101101100000001",
		"groupIds": []string{"banking-demo-devs"}, // un NOM, pas un UUID
	})

	ids, _ := prof["groupIds"].([]any)
	if len(ids) != 0 {
		t.Fatalf("groupIds = %v, attendu vide (les noms sont ignorés)", ids)
	}
}

// Le même appel avec l'UUID fonctionne — sans quoi le test précédent ne
// prouverait rien (il passerait aussi si la surface était inerte).
func TestAccessProfileAcceptsGroupUUID(t *testing.T) {
	srv := httptest.NewServer(NewServer().Handler())
	defer srv.Close()

	grp := post(t, srv, "/rest/apigateway/groups", map[string]any{
		"name": "banking-demo-devs", "type": "local"})
	gid, _ := grp["id"].(string)
	if gid == "" {
		t.Fatal("le groupe créé n'a pas d'id")
	}

	prof := post(t, srv, "/rest/apigateway/accessProfiles", map[string]any{
		"name": "banking-demo", "privilege": "111100101101100000001",
		"groupIds": []string{gid},
	})
	ids, _ := prof["groupIds"].([]any)
	if len(ids) != 1 || ids[0] != gid {
		t.Fatalf("groupIds = %v, attendu [%s]", ids, gid)
	}
}
```

Si `NewServer().Handler()` ne correspond pas à la construction réelle (relevée à l'étape 1), adapte les trois `httptest.NewServer(...)` — pas le reste.

- [ ] **Step 3: Lancer le test, vérifier qu'il échoue**

```bash
cd poc-control-plane-federation/mocks/webmethods && go test ./... -run 'TestTeamWork|TestAccessProfile' -v
```

Attendu : échec (routes 404, `enableTeamWork` absent).

- [ ] **Step 4: Étendre le Store**

Dans `store.go`, ajoute au struct `Store` :

```go
	users     map[string]map[string]any // id -> user record (raw)
	groups    map[string]map[string]any // id -> group record (raw)
	profiles  map[string]map[string]any // id -> accessProfile record (raw)
	teamWork  bool                      // enableTeamWork ; FAUX par défaut
```

et dans `NewStore()` :

```go
		users:    map[string]map[string]any{},
		groups:   map[string]map[string]any{},
		profiles: map[string]map[string]any{},
		teamWork: false,
```

- [ ] **Step 5: Écrire les handlers**

`mocks/webmethods/admin_teams.go` :

```go
package main

// Surfaces Teams du dialecte 10.15 — users, groupes, accessProfiles et le
// commutateur global enableTeamWork.
//
// Ces handlers existent pour reproduire des ÉCHECS SILENCIEUX, pas seulement
// des succès. Trois comportements mesurés sur la gateway (spike F4 T1,
// 2026-07-29) sont reproduits ici parce qu'un rôle qui ne s'y casse pas les
// dents en test se les cassera en production :
//
//   - userIds/groupIds passés par NOM : acceptés (200) et IGNORÉS. La liste
//     relue est vide. Aucun message, aucun code d'erreur.
//   - enableTeamWork vit sous le configId "extended" (PAS "extendedSettings")
//     et vaut "false" par défaut — l'état de l'environnement visé.
//   - la valeur est une CHAÎNE "true"/"false", pas un booléen JSON.
//
// Les ids sont des UUID DÉTERMINISTES (dérivés du compteur de Store) : le vrai
// produit en mint des aléatoires, mais un mock déterministe rend les tests
// reproductibles, et la seule propriété dont le rôle dépend est « l'id n'est
// pas le nom ».

import (
	"encoding/json"
	"fmt"
	"net/http"
)

// uuid rend un identifiant de forme UUID à partir du compteur de la famille.
func (s *Store) uuid(kind string) string {
	s.seq[kind]++
	n := s.seq[kind]
	return fmt.Sprintf("%08d-0000-4000-8000-%012d", n, n)
}

// --- configurations/extended -------------------------------------------------

func (s *Server) getExtended(w http.ResponseWriter, r *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	json.NewEncoder(w).Encode(map[string]any{
		"enableTeamWork": fmt.Sprintf("%t", s.store.teamWork),
	})
}

func (s *Server) putExtended(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	s.store.mu.Lock()
	if v, ok := body["enableTeamWork"]; ok {
		s.store.teamWork = fmt.Sprintf("%v", v) == "true"
	}
	s.store.mu.Unlock()
	s.getExtended(w, r)
}

// --- users -------------------------------------------------------------------

func (s *Server) listUsers(w http.ResponseWriter, r *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	out := []map[string]any{}
	for _, u := range s.store.users {
		out = append(out, u)
	}
	json.NewEncoder(w).Encode(map[string]any{"users": out})
}

func (s *Server) createUser(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	s.store.mu.Lock()
	id := s.store.uuid("user")
	body["id"] = id
	// Le mot de passe n'est jamais relu par le produit : on ne le stocke pas,
	// pour qu'aucun test ne puisse en dépendre par accident.
	delete(body, "password")
	s.store.users[id] = body
	s.store.mu.Unlock()
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(body)
}

// --- groupes -----------------------------------------------------------------

func (s *Server) listGroups(w http.ResponseWriter, r *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	out := []map[string]any{}
	for _, g := range s.store.groups {
		out = append(out, g)
	}
	json.NewEncoder(w).Encode(map[string]any{"groups": out})
}

func (s *Server) createGroup(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	s.store.mu.Lock()
	id := s.store.uuid("group")
	body["id"] = id
	body["userIds"] = s.keepKnown(body["userIds"], s.store.users)
	s.store.groups[id] = body
	s.store.mu.Unlock()
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(body)
}

func (s *Server) updateGroup(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var body map[string]any
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	// Le groupe système API-Gateway-Providers est adressé par son NOM, pas par
	// un UUID (mesuré : PUT /groups/API-Gateway-Providers). On le crée à la
	// volée s'il n'existe pas encore, comme le produit qui le livre d'usine.
	if _, ok := s.store.groups[id]; !ok {
		s.store.groups[id] = map[string]any{"id": id, "name": id, "systemDefined": true}
	}
	body["id"] = id
	body["userIds"] = s.keepKnown(body["userIds"], s.store.users)
	s.store.groups[id] = body
	json.NewEncoder(w).Encode(body)
}

// --- accessProfiles (les « teams ») ------------------------------------------

func (s *Server) listProfiles(w http.ResponseWriter, r *http.Request) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	out := []map[string]any{}
	for _, p := range s.store.profiles {
		out = append(out, p)
	}
	json.NewEncoder(w).Encode(map[string]any{"accessProfiles": out})
}

func (s *Server) createProfile(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	s.store.mu.Lock()
	id := s.store.uuid("profile")
	body["id"] = id
	body["groupIds"] = s.keepKnown(body["groupIds"], s.store.groups)
	s.store.profiles[id] = body
	s.store.mu.Unlock()
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(body)
}

func (s *Server) updateProfile(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var body map[string]any
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	if _, ok := s.store.profiles[id]; !ok {
		http.Error(w, "unknown accessProfile", http.StatusNotFound)
		return
	}
	body["id"] = id
	body["groupIds"] = s.keepKnown(body["groupIds"], s.store.groups)
	s.store.profiles[id] = body
	json.NewEncoder(w).Encode(body)
}

// keepKnown ne conserve que les entrées qui sont des ids CONNUS de la famille
// visée. C'est LE piège : le produit accepte n'importe quoi (200) et jette
// silencieusement ce qui n'est pas un id. Appelé sous verrou.
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
```

- [ ] **Step 6: Enregistrer les routes**

Dans `server.go`, juste après la ligne `PUT /rest/apigateway/configurations/keystore` :

```go
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
```

- [ ] **Step 7: Lancer les tests, vérifier qu'ils passent**

```bash
cd poc-control-plane-federation/mocks/webmethods && go test ./... -v
```

Attendu : les 3 nouveaux tests PASS, et **aucune régression** sur les tests existants.

- [ ] **Step 8: Commit**

```bash
git add mocks/webmethods/admin_teams.go mocks/webmethods/admin_teams_test.go \
        mocks/webmethods/store.go mocks/webmethods/server.go
git commit -m "test(mock): surfaces Teams du dialecte 10.15, pièges compris

users/groupes/accessProfiles/configurations extended. Les ids par NOM sont
acceptes puis ignores en silence, comme le produit : c'est ce comportement
qu'on veut voir casser un role en test plutot qu'en production."
```

---

## Task 2: Sonde Teams et table de vérité

**Files:**
- Create: `ansible/roles/apim_common/tasks/teams-feature.yml`
- Modify: `ansible/roles/apim_common/defaults/main.yml` (fin de fichier)
- Create: `ansible/test-onboard-guards.yml`

**Interfaces:**
- Consumes: `apim_ss_api_base`, `apim_ss_uri_defaults` (déjà posés par les rôles appelants), `apim_ss_require_team`.
- Produces: `apim_teams_enabled` (bool). Échecs nommés : `TEAMS_PROBE_FAILED`, `TEAMS_DISABLED`, `TEAMS_DEROGATION_STALE`.

- [ ] **Step 1: Déclarer la variable d'état**

Ajoute à la fin de `ansible/roles/apim_common/defaults/main.yml` :

```yaml
# --- état de la feature Teams (sonde partagee, tasks/teams-feature.yml) ------
# DEUX notions distinctes, ne pas les confondre :
#   apim_ss_teams_feature = ETAT DE LA PLATEFORME  (auto | off)
#   apim_ss_require_team  = POLITIQUE             (true | false)
# `auto` sonde GET /configurations/extended ; `off` court-circuite la sonde
# quand on ne veut pas interroger la gateway. Poser cette variable dans
# l'inventaire de l'environnement (depot plateforme, revu par PR) — JAMAIS
# dans un manifeste d'equipe ni dans un parametre de build : sinon « qui peut
# lancer un build » devient « qui peut desactiver le cloisonnement ».
apim_ss_teams_feature: "auto"
```

- [ ] **Step 2: Écrire le test qui échoue**

`ansible/test-onboard-guards.yml` :

```yaml
---
# Gardes HORS LIGNE de l'onboarding et de la sonde Teams. Aucune gateway
# reelle : le mock suffit, et les cas `off` ne sortent meme pas du process.
- name: "Sonde Teams — table de verite"
  hosts: webmethods
  gather_facts: false
  tasks:

    # feature OFF forcee + require_team false => on passe, teams desactivees
    - name: "OFF + derogation : la sonde rend false et ne refuse pas"
      ansible.builtin.import_role:
        name: apim_common
        tasks_from: teams-feature.yml
      vars:
        apim_ss_teams_feature: "off"
        apim_ss_require_team: false

    - name: "OFF + derogation : apim_teams_enabled doit etre false"
      ansible.builtin.assert:
        that: "not (apim_teams_enabled | bool)"
        fail_msg: "la sonde a rendu true alors que la feature est forcee off"
        success_msg: "OK — feature off, cloisonnement desactive"

    # feature OFF forcee + require_team true => refus TEAMS_DISABLED
    - name: "OFF + exigence : doit refuser"
      block:
        - ansible.builtin.import_role:
            name: apim_common
            tasks_from: teams-feature.yml
          vars:
            apim_ss_teams_feature: "off"
            apim_ss_require_team: true
        - ansible.builtin.fail:
            msg: "aucun refus alors que la feature est off et une team exigee"
      rescue:
        - ansible.builtin.assert:
            that: "'TEAMS_DISABLED' in (ansible_failed_result.msg | default(''))"
            fail_msg: >-
              refus obtenu mais pas le bon :
              {{ ansible_failed_result.msg | default('(sans message)') }}
            success_msg: "OK — TEAMS_DISABLED"
```

- [ ] **Step 3: Lancer le test, vérifier qu'il échoue**

```bash
cd poc-control-plane-federation
ansible-playbook -i ansible/inventory.lab.ini ansible/test-onboard-guards.yml
```

Attendu : échec `Could not find or access 'teams-feature.yml'`.

- [ ] **Step 4: Écrire la sonde**

`ansible/roles/apim_common/tasks/teams-feature.yml` :

```yaml
---
# roles/apim_common/tasks/teams-feature.yml — etat de la feature Teams.
#
# POURQUOI CE FICHIER EXISTE. `apim_ss_require_team` ne commandait que les deux
# assert (`TEAM_UNDEFINED`, `TEAM_CONFIRMED`) ; le travail reel — GET
# /accessProfiles, POST /assets/team — etait commande par `ss_team_name`, que le
# job pose TOUJOURS (`-e apim_ss_team=$TEAM`, derive de APIM_WM_CREDS_SUB). Le
# poser a false ne desactivait donc rien : constate le 2026-08-03 sur une
# gateway dont la feature est eteinte.
#
# LA LIGNE QUI COMPTE est la derniere de la table : feature ACTIVE + derogation
# posee => REFUS. Une derogation temporaire ne doit pas survivre par oubli a la
# cause qui l'a justifiee. Sans cette ligne, le jour ou le correctif passe en
# production, rien ne signale les environnements restes non cloisonnes.

- name: "Teams : sonde GET /configurations/extended (configId 'extended', PAS 'extendedSettings')"
  ansible.builtin.uri:
    url: "{{ apim_ss_api_base }}/configurations/extended"
  register: apim_ss_teams_probe
  changed_when: false
  failed_when: false
  when: "(apim_ss_teams_feature | default('auto')) == 'auto'"

- name: "Teams : la sonde a-t-elle abouti ?"
  ansible.builtin.set_fact:
    apim_ss_teams_probe_ok: >-
      {{ (apim_ss_teams_feature | default('auto')) != 'auto'
         or (apim_ss_teams_probe.status | default(0)) == 200 }}

# Fail-closed : ne pas savoir n'est pas une raison de passer. On ne refuse que
# si une team est exigee — sinon la sonde injoignable n'a aucune consequence.
- name: "Teams : FAIL-CLOSED — sonde injoignable alors qu'une team est exigee"
  ansible.builtin.assert:
    that: "apim_ss_teams_probe_ok | bool"
    fail_msg: >-
      TEAMS_PROBE_FAILED : GET {{ apim_ss_api_base }}/configurations/extended a
      rendu HTTP {{ apim_ss_teams_probe.status | default('(aucune reponse)') }}.
      L'etat de la feature Teams est inconnu et une team est exigee — on ne
      deploie pas dans le doute. Forcer apim_ss_teams_feature=off si la gateway
      ne porte pas cette surface.
  when: "apim_ss_require_team | default(true) | bool"

# La valeur est une CHAINE "true"/"false", pas un booleen JSON (mesure F4).
- name: "Teams : etat effectif de la feature"
  ansible.builtin.set_fact:
    apim_teams_enabled: >-
      {{ false if (apim_ss_teams_feature | default('auto')) == 'off'
         else ((apim_ss_teams_probe.json.enableTeamWork | default('false'))
               | string | lower == 'true') }}

- name: "Teams : FAIL-CLOSED — feature eteinte alors qu'une team est exigee"
  ansible.builtin.assert:
    that: "apim_teams_enabled | bool"
    fail_msg: >-
      TEAMS_DISABLED : la feature Teams est eteinte sur cette gateway et une
      team est exigee (apim_ss_require_team=true). Rien n'a ete ecrit. Soit
      activer la feature (geste d'ADMIN, hors pipeline :
      PUT /configurations/extended {"enableTeamWork":"true"}), soit poser la
      derogation apim_ss_require_team=false dans l'inventaire de
      l'environnement — jamais dans un manifeste.
  when: "apim_ss_require_team | default(true) | bool"

- name: "Teams : FAIL-CLOSED — derogation perimee (la feature est revenue)"
  ansible.builtin.assert:
    that: "not (apim_teams_enabled | bool)"
    fail_msg: >-
      TEAMS_DEROGATION_STALE : apim_ss_require_team=false alors que la feature
      Teams est ACTIVE sur cette gateway. La derogation avait pour cause une
      feature indisponible ; cette cause a disparu. Retirer la derogation de
      l'inventaire de l'environnement.
  when: "not (apim_ss_require_team | default(true) | bool)"

- name: "Teams : AVERTISSEMENT — cloisonnement desactive sur cet environnement"
  ansible.builtin.debug:
    msg: >-
      ⚠ TEAMS_OFF : feature Teams eteinte et derogation posee. Les applications
      et les APIs resteront en team Default — visibles et supprimables par
      toutes les equipes. Acceptable le temps qu'un correctif atteigne cet
      environnement, JAMAIS comme etat cible.
  when: "not (apim_teams_enabled | bool)"
```

- [ ] **Step 5: Lancer le test, vérifier qu'il passe**

```bash
cd poc-control-plane-federation
ansible-playbook -i ansible/inventory.lab.ini ansible/test-onboard-guards.yml
```

Attendu : les deux assertions PASS.

- [ ] **Step 6: Commit**

```bash
git add ansible/roles/apim_common/tasks/teams-feature.yml \
        ansible/roles/apim_common/defaults/main.yml \
        ansible/test-onboard-guards.yml
git commit -m "feat(common): sonde de la feature Teams et table de verite

apim_ss_teams_feature (etat plateforme) distinct de apim_ss_require_team
(politique). Refuse la derogation quand la feature est revenue, pour qu'un
contournement temporaire ne survive pas par oubli a sa cause."
```

---

## Task 3: La sonde commande le travail, pas seulement les assertions

C'est la correction du défaut constaté le 2026-08-03.

**Files:**
- Modify: `ansible/roles/apim_selfservice_app/tasks/main.yml` — ancres relevées le 2026-08-04 : `import_tasks: team-name.yml` (l. 25), `api-visibility.yml` (l. 54), `team.yml` (l. 107). Le travail sur la DCR a ajouté des fichiers au rôle sans déplacer ces trois points ; **vérifie les ancres par `grep -n 'import_tasks: team'`, ne te fie pas aux numéros.**
- Modify: `ansible/roles/apim_selfservice_app/tasks/team.yml:45` (le `when` du block)
- Modify: `ansible/roles/apim_selfservice_app/tasks/verify.yml:75`
- Modify: `ansible/roles/apim_publish_api/tasks/{main,team,verify}.yml` (mêmes points)
- Modify: `ansible/test-onboard-guards.yml`

**Interfaces:**
- Consumes: `apim_teams_enabled` (Task 2).
- Produces: aucune nouvelle interface — un changement de condition.

- [ ] **Step 1: Ajouter le test de non-régression**

Ajoute à la fin de `ansible/test-onboard-guards.yml` :

```yaml
    # LE DEFAUT CONSTATE le 2026-08-03 : un nom d'equipe resolu suffisait a
    # declencher GET /accessProfiles, meme derogation posee.
    - name: "Derogation : un nom d'equipe resolu ne doit PLUS declencher le travail"
      ansible.builtin.import_role:
        name: apim_common
        tasks_from: teams-feature.yml
      vars:
        apim_ss_teams_feature: "off"
        apim_ss_require_team: false

    - name: "Derogation : la condition du block team doit etre fausse"
      ansible.builtin.assert:
        that: "not ((ss_team_name | default('banking-demo') | length > 0) and (apim_teams_enabled | bool))"
        fail_msg: >-
          la condition composee est vraie alors que la feature est off — le role
          appellerait GET /accessProfiles (defaut du 2026-08-03).
        success_msg: "OK — nom d'equipe present mais feature off : travail saute"
```

- [ ] **Step 2: Lancer, vérifier que ça passe déjà**

```bash
cd poc-control-plane-federation
ansible-playbook -i ansible/inventory.lab.ini ansible/test-onboard-guards.yml
```

Ce test valide l'expression, pas encore son câblage : il doit passer. Les étapes 3-5 câblent l'expression dans les rôles ; l'étape 6 prouve le câblage.

- [ ] **Step 3: Appeler la sonde dans les deux rôles**

Dans `ansible/roles/apim_selfservice_app/tasks/main.yml`, juste avant `import_tasks: team-name.yml` (ligne 24) :

```yaml
    # ===== 0a. Etat de la feature Teams (commande les gardes qui suivent) =====
    - name: "Teams : sonde de la feature + table de verite"
      ansible.builtin.import_role:
        name: apim_common
        tasks_from: teams-feature.yml
```

Fais le même ajout dans `ansible/roles/apim_publish_api/tasks/main.yml`, avant son propre `import_tasks: team-name.yml`.

- [ ] **Step 4: Conditionner le travail**

`apim_selfservice_app/tasks/main.yml` — la garde de visibilité (ligne 55) :

```yaml
      when: "(ss_team_name | length > 0) and (apim_teams_enabled | bool)"
```

`apim_selfservice_app/tasks/team.yml` — le `when` du block (ligne 45) :

```yaml
  when: "(ss_team_name | length > 0) and (apim_teams_enabled | bool)"
```

`apim_selfservice_app/tasks/verify.yml` — l'assert (ligne 75) :

```yaml
      when: "(apim_ss_require_team | default(true) | bool) and (apim_teams_enabled | bool)"
```

Applique les trois mêmes changements aux fichiers homologues de `apim_publish_api`.

- [ ] **Step 5: Compléter le commentaire d'en-tête de `team-name.yml`**

Dans `apim_selfservice_app/tasks/team-name.yml` et son homologue, remplace la mention du repli lab par :

```yaml
# Le repli non cloisonne est commande par DEUX variables, pas une :
#   apim_ss_teams_feature (etat plateforme) et apim_ss_require_team (politique).
# Poser require_team=false ne suffit pas a desactiver les teams — il ne leve
# que les assert ; c'est la sonde qui commande le travail (apim_common/
# tasks/teams-feature.yml). Constate le 2026-08-03.
```

- [ ] **Step 6: Prouver le câblage contre le mock**

```bash
cd poc-control-plane-federation
docker compose -f docker-compose.poc.yml up -d wm-mock   # adapter au nom reel du service
ansible-playbook -i ansible/inventory.lab.ini ansible/selfservice-app.yml \
  -e apim_ss_require_team=false -e apim_ss_team=banking-demo -v 2>&1 | tee /tmp/derog.log
grep -c 'accessProfiles' /tmp/derog.log
```

Attendu : `0`. Le mock rend `enableTeamWork: "false"`, donc aucun appel `/accessProfiles` malgré `-e apim_ss_team=banking-demo`. C'est très exactement le défaut du 2026-08-03, mesuré fermé.

- [ ] **Step 7: Commit**

```bash
git add ansible/roles/apim_selfservice_app/tasks ansible/roles/apim_publish_api/tasks \
        ansible/test-onboard-guards.yml
git commit -m "fix(teams): le bouton commande le travail, plus seulement les assert

apim_ss_require_team=false ne desactivait rien : le block team etait commande
par ss_team_name, que le job pose toujours. La sonde conditionne desormais
team.yml, api-visibility.yml et l'assert de verify."
```

---

## Task 4: `providers.dev.yml`, gabarits et garde du nom

**Files:**
- Create: `ansible/providers.dev.yml`
- Create: `ansible/roles/apim_team_onboard/defaults/main.yml`
- Create: `ansible/roles/apim_team_onboard/tasks/resolve.yml`
- Create: `ansible/tests/onboard/providers-bad-name.yml`
- Modify: `ansible/test-onboard-guards.yml`

**Interfaces:**
- Consumes: `apim_onb_providers_file` (chemin), `apim_onb_team` (nom ciblé, optionnel).
- Produces: `onb` — dict de l'équipe résolue, augmenté de `user`, `group`, `kv_sub`, `policy`. Échecs nommés : `TEAM_NAME_INVALID`, `TEAM_NOT_DECLARED`.

- [ ] **Step 1: Écrire les fixtures et le test qui échoue**

`ansible/providers.dev.yml` :

```yaml
---
# Les equipes de l'environnement dev. Source declarative de l'onboarding :
# revue par PR, protegee par branch protection. C'est ici que l'appartenance
# d'une equipe devient un fait date.
#
# UNE LIGNE PAR EQUIPE. Tout le reste (user, groupe, chemin KV, policy) est
# DERIVE des gabarits de roles/apim_team_onboard/defaults/main.yml — les memes
# que ceux dont le CI derive la team a l'execution. Ne jamais denormaliser ici
# ce qui se derive la-bas : c'est ce qui garantit qu'ils ne divergent pas.
providers:
  - team: banking-demo
    description: "Equipe paiements — comptes et virements"
    repo: banking-demo/accounts-api      # declare des maintenant, consomme au palier 2
    approvers: ["A123456", "B789012"]    # matricules — projetes dans owner au publish
```

`ansible/tests/onboard/providers-bad-name.yml` :

```yaml
---
# Le nom d'equipe sert de segment de chemin Vault, de nom de policy ET de nom
# de team. `../autre` sortirait du chemin KV : c'est une evasion de chemin qui
# donnerait a une equipe les creds d'une autre, pas une coquetterie.
providers:
  - team: "../insurance-demo"
    description: "evasion de chemin"
    repo: "x/y"
    approvers: []
```

Ajoute à `ansible/test-onboard-guards.yml` :

```yaml
- name: "Onboarding — gardes hors ligne"
  hosts: webmethods
  gather_facts: false
  tasks:

    - name: "Nom d'equipe : une evasion de chemin doit etre refusee"
      block:
        - ansible.builtin.import_role:
            name: apim_team_onboard
            tasks_from: resolve.yml
          vars:
            apim_onb_providers_file: "tests/onboard/providers-bad-name.yml"
            apim_onb_team: "../insurance-demo"
        - ansible.builtin.fail:
            msg: "un nom d'equipe avec ../ a ete accepte"
      rescue:
        - ansible.builtin.assert:
            that: "'TEAM_NAME_INVALID' in (ansible_failed_result.msg | default(''))"
            fail_msg: >-
              refus obtenu mais pas le bon :
              {{ ansible_failed_result.msg | default('(sans message)') }}
            success_msg: "OK — TEAM_NAME_INVALID"

    - name: "Derivations : une equipe legitime rend les 4 noms attendus"
      ansible.builtin.import_role:
        name: apim_team_onboard
        tasks_from: resolve.yml
      vars:
        apim_onb_providers_file: "providers.dev.yml"
        apim_onb_team: "banking-demo"

    - name: "Derivations : verifier chacune"
      ansible.builtin.assert:
        that:
          - "onb.user   == 'svc-banking-demo'"
          - "onb.group  == 'banking-demo-devs'"
          - "onb.kv_sub == 'deploy/banking-demo/wm-admin'"
          - "onb.policy == 'deploy-banking-demo'"
        fail_msg: "derivations inattendues : {{ onb }}"
        success_msg: "OK — svc-/-devs/deploy-…/deploy- derives"

    - name: "Convention : la derivation du CI sur ce chemin KV rend bien l'equipe"
      ansible.builtin.assert:
        that: "(onb.kv_sub.split('/'))[1] == onb.team"
        fail_msg: >-
          le gabarit KV ne place pas le nom d'equipe en 2e segment — le
          `cut -d/ -f2` du CI deriverait une valeur fausse.
        success_msg: "OK — gabarit KV et derivation du CI concordent"
```

- [ ] **Step 2: Lancer, vérifier l'échec**

```bash
cd poc-control-plane-federation
ansible-playbook -i ansible/inventory.lab.ini ansible/test-onboard-guards.yml
```

Attendu : échec, rôle `apim_team_onboard` introuvable.

- [ ] **Step 3: Écrire les defaults**

`ansible/roles/apim_team_onboard/defaults/main.yml` :

```yaml
---
# roles/apim_team_onboard/defaults/main.yml
#
# LES GABARITS SONT LA CONVENTION. Elle n'existait nulle part : elle etait
# encodee deux fois dans un `cut -d/ -f2` (Jenkinsfile.selfservice:163,
# Jenkinsfile.publish-api:153) que rien ne nommait. La declarer ici la rend
# ASSERTABLE, et garantit que ce que l'onboarding pose et ce que le runtime
# derive ne peuvent pas diverger.
#
# Chez un client dont la disposition KV differe, surcharger apim_onb_kv_tpl —
# et poser APIM_TEAM dans le CI, puisque la derivation par cut ne s'applique
# plus.
apim_onb_user_tpl: "svc-{{ team }}"
apim_onb_group_tpl: "{{ team }}-devs"
apim_onb_kv_tpl: "deploy/{{ team }}/wm-admin"
apim_onb_policy_tpl: "deploy-{{ team }}"

# Groupe systeme dont l'appartenance conditionne l'acces a l'API d'admin
# (sinon 403 sur GET /apis). Distinct de la team : deux gestes, pas un.
apim_onb_system_group: "API-Gateway-Providers"

# Bitmask de privileges. Defaut = celui du profil systeme API-Gateway-Providers,
# comme le bootstrap F4. Le retrait de POST /apis (D6) n'est PAS tranche : il
# exige de lire les noms en console puis un bit-flip sur un profil JETABLE, avec
# capture du bitmask d'avant comme rollback. Le jour ou c'est tranche, cette
# valeur suffit a propager.
apim_onb_privilege: "111100101101100000001"

# Source declarative, relative au repertoire ansible/.
apim_onb_providers_file: "providers.dev.yml"

# Equipe ciblee ; vide = toutes celles du fichier.
apim_onb_team: ""

# Longueur du mot de passe genere (hex, donc 2 caracteres par octet).
apim_onb_password_bytes: 12
```

- [ ] **Step 4: Écrire `resolve.yml`**

`ansible/roles/apim_team_onboard/tasks/resolve.yml` :

```yaml
---
# roles/apim_team_onboard/tasks/resolve.yml — quelle equipe, et quels noms.
#
# La garde du nom n'est pas de la validation de confort. Le nom d'equipe sert
# SIMULTANEMENT de segment de chemin Vault, de nom de policy et de nom de team :
# `team: ../autre` produirait le chemin `deploy/../autre/wm-admin`, c'est-a-dire
# les creds d'une AUTRE equipe. C'est une evasion de chemin.

- name: "Providers : charger la source declarative"
  ansible.builtin.include_vars:
    file: "{{ apim_onb_providers_file }}"
    name: onb_src

- name: "Providers : entree de l'equipe ciblee"
  ansible.builtin.set_fact:
    onb_entry: >-
      {{ (onb_src.providers | default([])
          | selectattr('team', 'equalto', apim_onb_team)
          | list | first) | default({}) }}

- name: "Providers : FAIL-CLOSED — l'equipe doit etre declaree"
  ansible.builtin.assert:
    that: "onb_entry | length > 0"
    fail_msg: >-
      TEAM_NOT_DECLARED : '{{ apim_onb_team }}' est absente de
      {{ apim_onb_providers_file }}. Une equipe s'onboarde par une entree revue
      dans ce fichier, pas par un parametre de ligne de commande.

- name: "Nom d'equipe : FAIL-CLOSED — forme imposee"
  ansible.builtin.assert:
    that: "onb_entry.team is match('^[a-z0-9][a-z0-9-]{1,30}$')"
    fail_msg: >-
      TEAM_NAME_INVALID : '{{ onb_entry.team }}' — attendu
      ^[a-z0-9][a-z0-9-]{1,30}$. Ce nom devient un segment de chemin Vault, un
      nom de policy et un nom de team : tout caractere hors de cette forme est
      une evasion de chemin en puissance.
    success_msg: "TEAM_NAME_OK : '{{ onb_entry.team }}'"

- name: "Derivations : les quatre noms, depuis les gabarits"
  ansible.builtin.set_fact:
    onb: >-
      {{ onb_entry | combine({
           'user':   apim_onb_user_tpl,
           'group':  apim_onb_group_tpl,
           'kv_sub': apim_onb_kv_tpl,
           'policy': apim_onb_policy_tpl }) }}
  vars:
    team: "{{ onb_entry.team }}"

- name: "Derivations : journalisees (aucun secret)"
  ansible.builtin.debug:
    msg: >-
      equipe={{ onb.team }} user={{ onb.user }} groupe={{ onb.group }}
      kv={{ onb.kv_sub }} policy={{ onb.policy }}
```

- [ ] **Step 5: Lancer, vérifier que ça passe**

```bash
cd poc-control-plane-federation
ansible-playbook -i ansible/inventory.lab.ini ansible/test-onboard-guards.yml
```

Attendu : `TEAM_NAME_INVALID` levé sur la fixture, les trois assertions de dérivation PASS.

- [ ] **Step 6: Commit**

```bash
git add ansible/providers.dev.yml ansible/roles/apim_team_onboard/defaults \
        ansible/roles/apim_team_onboard/tasks/resolve.yml \
        ansible/tests/onboard ansible/test-onboard-guards.yml
git commit -m "feat(onboard): source declarative par env et gabarits de convention

La convention etait encodee deux fois dans un cut -d/ -f2 que rien ne nommait.
La declarer la rend assertable — et garantit que ce que l'onboarding pose et
ce que le runtime derive ne divergent pas. Garde du nom = anti-evasion de
chemin, pas du confort."
```

---

## Task 5: Volet Vault du rôle

**Files:**
- Create: `ansible/roles/apim_team_onboard/tasks/vault.yml`
- Modify: `scripts/setup-vault-userpass.sh:75-97` (retrait de la boucle de policies — étape 4)

**Interfaces:**
- Consumes: `onb` (Task 4), `apim_ss_vault_addr`, `apim_ss_vault_token`, `apim_ss_vault_kv_mount`, `apim_ss_vault_prefix` (posés par `apim_common/tasks/secrets.yml`).
- Produces: `onb_kv_path` (chemin `data/` complet), `onb_password_created` (bool — vrai si le secret vient d'être généré).

> **Revue du 2026-08-04.** `scripts/setup-vault-userpass.sh:75-97` créait déjà la policy `deploy-<tenant>`, et avec une forme que la première version de ce plan ignorait : lecture sur tout le sous-arbre du tenant **et écriture sur `apps/*`**. Deux conséquences, traitées aux étapes 3 et 4 : la forme est reprise verbatim, et la **propriété** de la policy passe au rôle — deux endroits qui écrivent la même policy, c'est la divergence garantie.

- [ ] **Step 1: Écrire le test qui échoue**

Ajoute à `ansible/test-onboard-guards.yml`, dans le play onboarding :

```yaml
    - name: "Vault : le chemin KV compose elide un prefixe vide"
      ansible.builtin.assert:
        that:
          - "([ '', onb.kv_sub ] | select | join('/')) == 'deploy/banking-demo/wm-admin'"
          - "([ 'stoa', onb.kv_sub ] | select | join('/')) == 'stoa/deploy/banking-demo/wm-admin'"
        fail_msg: "la composition du chemin KV ne suit pas la convention apim_common"
        success_msg: "OK — prefixe optionnel elide comme dans secrets.yml"
```

- [ ] **Step 2: Lancer, vérifier que ça passe**

```bash
cd poc-control-plane-federation
ansible-playbook -i ansible/inventory.lab.ini ansible/test-onboard-guards.yml
```

Ce test fixe la convention de composition avant de l'implémenter ; il doit passer.

- [ ] **Step 3: Écrire `vault.yml`**

`ansible/roles/apim_team_onboard/tasks/vault.yml` :

```yaml
---
# roles/apim_team_onboard/tasks/vault.yml — le secret, le KV, la policy.
#
# VAULT AVANT LA GATEWAY, et ce n'est pas cosmetique. Le mot de passe n'existe
# qu'une fois. Genere, pose sur la gateway, puis ecriture Vault en echec => un
# compte VIVANT dont le secret est PERDU, a reinitialiser a la main. Dans
# l'autre sens, un secret ecrit dont le compte n'existe pas est inoffensif : le
# run suivant le reprend.
#
# LE SECRET N'EST GENERE QUE S'IL EST ABSENT. Un re-run ne fait pas tourner le
# mot de passe — sinon rejouer l'onboarding casserait tous les jobs de l'equipe.
# La rotation est un geste separe, jamais un effet de bord.

- name: "Vault : chemins effectifs (prefixe optionnel, meme convention que secrets.yml)"
  ansible.builtin.set_fact:
    onb_kv_path: "{{ apim_ss_vault_kv_mount }}/data/{{ [apim_ss_vault_prefix, onb.kv_sub] | select | join('/') }}"
    onb_kv_logical: "{{ [apim_ss_vault_prefix, onb.kv_sub] | select | join('/') }}"

- name: "Vault : l'entree existe-t-elle deja ?"
  ansible.builtin.uri:
    url: "{{ apim_ss_vault_addr }}/v1/{{ onb_kv_path }}"
    headers: { X-Vault-Token: "{{ apim_ss_vault_token }}" }
    status_code: [200, 404]
    ca_path: "{{ apim_ss_ca_path | default('') or omit }}"
  register: onb_kv_get
  delegate_to: localhost
  changed_when: false
  no_log: true

- name: "Vault : generer le mot de passe UNIQUEMENT s'il est absent"
  ansible.builtin.set_fact:
    onb_password: "{{ lookup('password', '/dev/null length=' ~ (apim_onb_password_bytes | int * 2) ~ ' chars=hexdigits') }}"
    onb_password_created: true
  no_log: true
  when: "onb_kv_get.status == 404"

- name: "Vault : sinon reprendre celui qui est stocke (aucune rotation au re-run)"
  ansible.builtin.set_fact:
    onb_password: "{{ onb_kv_get.json.data.data[apim_ss_vault_wm_password_key] }}"
    onb_password_created: false
  no_log: true
  when: "onb_kv_get.status == 200"

- name: "Vault : ecrire l'entree KV v2 (username + password)"
  ansible.builtin.uri:
    url: "{{ apim_ss_vault_addr }}/v1/{{ onb_kv_path }}"
    method: POST
    headers: { X-Vault-Token: "{{ apim_ss_vault_token }}" }
    body_format: json
    body:
      data:
        "{{ apim_ss_vault_wm_user_key }}": "{{ onb.user }}"
        "{{ apim_ss_vault_wm_password_key }}": "{{ onb_password }}"
    status_code: [200, 204]
    ca_path: "{{ apim_ss_ca_path | default('') or omit }}"
  delegate_to: localhost
  no_log: true
  when: "onb_password_created | bool"

# La policy borne le perimetre au SEUL sous-arbre de l'equipe. C'est la douve :
# se reclamer de l'equipe X exige de savoir lire deploy/X/wm-admin (ADR-077).
#
# ⚠ FORME REPRISE VERBATIM de scripts/setup-vault-userpass.sh:75-97, qui creait
# deja cette policy avant ce role. L'ECRITURE sur apps/* n'est PAS decorative :
# c'est le mode OAuth2 `internal`, ou celui qui deploie une application de son
# tenant y stocke le client genere par la gateway. Une policy en LECTURE SEULE
# — ce que ce plan proposait avant la revue du 2026-08-04 — casserait ces
# deploiements EN SILENCE, et le symptome apparaitrait loin de la cause.
- name: "Vault : policy {{ onb.policy }} (lecture du sous-arbre, ecriture bornee a apps/)"
  vars:
    onb_tenant_root: "{{ [apim_ss_vault_prefix, 'deploy', onb.team] | select | join('/') }}"
  ansible.builtin.uri:
    url: "{{ apim_ss_vault_addr }}/v1/sys/policies/acl/{{ onb.policy }}"
    method: PUT
    headers: { X-Vault-Token: "{{ apim_ss_vault_token }}" }
    body_format: json
    body:
      policy: |
        # Perimetre de deploiement du tenant {{ onb.team }}.
        # LECTURE sur tout le sous-arbre du tenant ; ECRITURE limitee au seul
        # sous-arbre apps/ (mode OAuth2 internal : celui qui deploie une app de
        # SON tenant y stocke le client genere par la gateway — jamais ailleurs,
        # jamais un autre tenant). La segregation reste ENFORCEE ici, pas dans
        # le pipeline.
        path "{{ apim_ss_vault_kv_mount }}/data/{{ onb_tenant_root }}/*"          { capabilities = ["read"] }
        path "{{ apim_ss_vault_kv_mount }}/metadata/{{ onb_tenant_root }}/*"      { capabilities = ["read", "list"] }
        path "{{ apim_ss_vault_kv_mount }}/data/{{ onb_tenant_root }}/apps/*"     { capabilities = ["create", "update", "read"] }
        path "{{ apim_ss_vault_kv_mount }}/metadata/{{ onb_tenant_root }}/apps/*" { capabilities = ["read", "list"] }
    status_code: [200, 204]
    ca_path: "{{ apim_ss_ca_path | default('') or omit }}"
  delegate_to: localhost

- name: "Vault : etat (aucun secret dans le message)"
  ansible.builtin.debug:
    msg: >-
      KV={{ onb_kv_logical }}
      ({{ 'secret genere' if onb_password_created | bool else 'secret existant repris' }}),
      policy={{ onb.policy }}
```

- [ ] **Step 4: Retirer la policy du script d'amorçage (une seule source)**

Le rôle devient le propriétaire. Dans `scripts/setup-vault-userpass.sh`, remplace la boucle `for T in $TENANTS` qui écrit les policies (lignes 75-97) par un renvoi explicite :

```bash
# Les policies deploy-<tenant> sont desormais posees par le role Ansible
# apim_team_onboard (tasks/vault.yml) : c'est lui qui sait qu'une equipe
# existe, et il est joue a chaque onboarding. Les ecrire ici AUSSI ferait deux
# sources pour un meme objet — donc une divergence, tot ou tard, sans que rien
# ne la signale.
#
#   ansible-playbook -i ansible/inventory.lab.ini ansible/onboard-team.yml \
#     -e apim_onb_team=<tenant>
#
# Ce script continue de creer les IDENTITES userpass ; il ne cree plus leurs
# perimetres.
```

Vérifie ensuite qu'aucun autre appelant n'en dépendait :

```bash
cd poc-control-plane-federation
grep -rn 'deploy-\$T\|deploy-banking-demo\|deploy-payments-team' scripts/ ci/ ansible/ | grep -v onboard
```

Chaque résultat est un endroit qui **suppose** la policy déjà là. Si l'un d'eux tourne avant tout onboarding, il faut soit l'onboarder d'abord, soit lui faire appeler le rôle — pas remettre une deuxième écriture.

- [ ] **Step 5: Prouver contre un Vault de lab**

```bash
cd poc-control-plane-federation
export VAULT_ADDR=http://localhost:8200 VAULT_TOKEN=stoa-root-token
ansible-playbook -i ansible/inventory.lab.ini ansible/onboard-team.yml \
  -e apim_onb_team=onboard-probe -e apim_ss_vault_token=$VAULT_TOKEN 2>&1 | tail -20
```

Le playbook n'existe pas encore (Task 7) — si tu exécutes les tâches dans l'ordre, reporte cette étape à la fin de la Task 7 et note-la comme telle. Attendu à ce moment : `secret genere` au premier run, `secret existant repris` au second.

- [ ] **Step 6: Commit**

```bash
git add ansible/roles/apim_team_onboard/tasks/vault.yml ansible/test-onboard-guards.yml \
        scripts/setup-vault-userpass.sh
git commit -m "feat(onboard): volet Vault — secret, KV, policy bornee

Vault avant la gateway : un secret orphelin est inoffensif, un compte au
secret perdu ne l'est pas. Le secret n'est genere que s'il est absent — un
re-run ne doit pas casser les jobs de l'equipe."
```

---

## Task 6: Volet gateway du rôle

**Files:**
- Create: `ansible/roles/apim_team_onboard/tasks/gateway.yml`

**Interfaces:**
- Consumes: `onb` (Task 4), `onb_password` (Task 5), `apim_ss_api_base`, `apim_ss_uri_defaults`.
- Produces: `onb_user_id`, `onb_group_id`, `onb_profile_id` (UUID).

- [ ] **Step 1: Écrire `gateway.yml`**

```yaml
---
# roles/apim_team_onboard/tasks/gateway.yml — user, groupe, adhesion, team.
#
# QUATRE PIEGES, TOUS DES SUCCES SILENCIEUX (spike F4 T1, 2026-07-29) :
#   1. userIds/groupIds attendent des UUID ; les NOMS sont acceptes (200) et
#      IGNORES — liste relue vide, aucun message.
#   2. `privilege` est un BITMASK, pas une liste de noms.
#   3. l'adhesion au groupe systeme API-Gateway-Providers est un geste DISTINCT
#      de la team : sans elle, 403 sur GET /apis.
#   4. le groupe systeme s'adresse par son NOM, pas par un UUID.
# D'ou une relecture apres CHAQUE ecriture : un 200 ne prouve rien ici.

- name: "Gateway : lister les users"
  ansible.builtin.uri:
    url: "{{ apim_ss_api_base }}/users"
  register: onb_users
  changed_when: false

- name: "Gateway : id du user s'il existe"
  ansible.builtin.set_fact:
    onb_user_id: >-
      {{ (onb_users.json.users | default([])
          | selectattr('loginId', 'equalto', onb.user)
          | map(attribute='id') | list | first) | default('') }}

- name: "Gateway : creer le user technique"
  ansible.builtin.uri:
    url: "{{ apim_ss_api_base }}/users"
    method: POST
    body:
      loginId: "{{ onb.user }}"
      firstName: "svc"
      lastName: "{{ onb.team }}"
      password: "{{ onb_password }}"
      active: true
      type: "local"
    status_code: [200, 201]
  register: onb_user_create
  no_log: true
  when: "onb_user_id | length == 0"

- name: "Gateway : relire les users (l'id ne se deduit pas, il se relit)"
  ansible.builtin.uri:
    url: "{{ apim_ss_api_base }}/users"
  register: onb_users2
  changed_when: false
  when: "onb_user_id | length == 0"

- name: "Gateway : id du user apres creation"
  ansible.builtin.set_fact:
    onb_user_id: >-
      {{ (onb_users2.json.users | default([])
          | selectattr('loginId', 'equalto', onb.user)
          | map(attribute='id') | list | first) | default('') }}
  when: "onb_user_id | length == 0"

- name: "Gateway : FAIL-CLOSED — le user doit avoir un id"
  ansible.builtin.assert:
    that: "onb_user_id | length > 0"
    fail_msg: "USER_UNRESOLVED : '{{ onb.user }}' absent apres creation."

- name: "Gateway : lister les groupes"
  ansible.builtin.uri:
    url: "{{ apim_ss_api_base }}/groups"
  register: onb_groups
  changed_when: false

- name: "Gateway : id du groupe s'il existe"
  ansible.builtin.set_fact:
    onb_group_id: >-
      {{ (onb_groups.json.groups | default([])
          | selectattr('name', 'equalto', onb.group)
          | map(attribute='id') | list | first) | default('') }}

- name: "Gateway : creer le groupe (nu — les membres sont poses au PUT)"
  ansible.builtin.uri:
    url: "{{ apim_ss_api_base }}/groups"
    method: POST
    body:
      name: "{{ onb.group }}"
      description: "devs {{ onb.team }}"
      type: "local"
    status_code: [200, 201]
  when: "onb_group_id | length == 0"

- name: "Gateway : relire les groupes"
  ansible.builtin.uri:
    url: "{{ apim_ss_api_base }}/groups"
  register: onb_groups2
  changed_when: false

- name: "Gateway : id du groupe (apres creation eventuelle)"
  ansible.builtin.set_fact:
    onb_group_id: >-
      {{ (onb_groups2.json.groups | default([])
          | selectattr('name', 'equalto', onb.group)
          | map(attribute='id') | list | first) | default('') }}

- name: "Gateway : FAIL-CLOSED — le groupe doit avoir un id"
  ansible.builtin.assert:
    that: "onb_group_id | length > 0"
    fail_msg: "GROUP_UNRESOLVED : '{{ onb.group }}' absent apres creation."

# PIEGE 1 : userIds en UUID. Un loginId ici => 200 et membre absent.
- name: "Gateway : poser le membre du groupe (UUID, JAMAIS le loginId)"
  ansible.builtin.uri:
    url: "{{ apim_ss_api_base }}/groups/{{ onb_group_id }}"
    method: PUT
    body:
      id: "{{ onb_group_id }}"
      name: "{{ onb.group }}"
      description: "devs {{ onb.team }}"
      type: "local"
      userIds: ["{{ onb_user_id }}"]
    status_code: [200, 201]

- name: "Gateway : relire le groupe (LA porte de preuve du piege 1)"
  ansible.builtin.uri:
    url: "{{ apim_ss_api_base }}/groups"
  register: onb_groups3
  changed_when: false

- name: "Gateway : FAIL-CLOSED — le user est REELLEMENT membre"
  ansible.builtin.assert:
    that: >-
      onb_user_id in ((onb_groups3.json.groups | default([])
        | selectattr('id', 'equalto', onb_group_id)
        | map(attribute='userIds') | flatten | list))
    fail_msg: >-
      GROUP_MEMBER_UNCONFIRMED : apres PUT /groups/{{ onb_group_id }}, le user
      {{ onb.user }} n'est pas membre. Un 200 sans effet est le comportement
      connu quand userIds porte des NOMS au lieu d'UUID.
    success_msg: "GROUP_MEMBER_OK : {{ onb.user }} ∈ {{ onb.group }}"

- name: "Gateway : lister les accessProfiles"
  ansible.builtin.uri:
    url: "{{ apim_ss_api_base }}/accessProfiles"
  register: onb_profiles
  changed_when: false

- name: "Gateway : id de l'accessProfile s'il existe"
  ansible.builtin.set_fact:
    onb_profile_id: >-
      {{ (onb_profiles.json.accessProfiles | default([])
          | selectattr('name', 'equalto', onb.team)
          | map(attribute='id') | list | first) | default('') }}

- name: "Gateway : creer la team (accessProfile ; groupIds en UUID)"
  ansible.builtin.uri:
    url: "{{ apim_ss_api_base }}/accessProfiles"
    method: POST
    body:
      name: "{{ onb.team }}"
      description: "{{ onb.description | default('team ' ~ onb.team) }}"
      privilege: "{{ apim_onb_privilege }}"
      groupIds: ["{{ onb_group_id }}"]
    status_code: [200, 201]
  when: "onb_profile_id | length == 0"

- name: "Gateway : mettre a jour la team si elle existe deja"
  ansible.builtin.uri:
    url: "{{ apim_ss_api_base }}/accessProfiles/{{ onb_profile_id }}"
    method: PUT
    body:
      id: "{{ onb_profile_id }}"
      name: "{{ onb.team }}"
      description: "{{ onb.description | default('team ' ~ onb.team) }}"
      privilege: "{{ apim_onb_privilege }}"
      groupIds: ["{{ onb_group_id }}"]
    status_code: [200, 201]
  when: "onb_profile_id | length > 0"

- name: "Gateway : relire les accessProfiles (porte de preuve)"
  ansible.builtin.uri:
    url: "{{ apim_ss_api_base }}/accessProfiles"
  register: onb_profiles2
  changed_when: false

- name: "Gateway : id + groupes relus de la team"
  ansible.builtin.set_fact:
    onb_profile_rec: >-
      {{ (onb_profiles2.json.accessProfiles | default([])
          | selectattr('name', 'equalto', onb.team) | list | first) | default({}) }}

- name: "Gateway : FAIL-CLOSED — la team porte REELLEMENT son groupe"
  ansible.builtin.assert:
    that:
      - "onb_profile_rec | length > 0"
      - "onb_group_id in (onb_profile_rec.groupIds | default([]))"
    fail_msg: >-
      TEAM_GROUP_UNCONFIRMED : l'accessProfile '{{ onb.team }}' ne porte pas le
      groupe {{ onb.group }} ({{ onb_profile_rec.groupIds | default([]) }}).
      groupIds par NOM = reference morte silencieuse.
    success_msg: "TEAM_GROUP_OK : {{ onb.group }} ∈ accessProfile {{ onb.team }}"

- name: "Gateway : id de la team"
  ansible.builtin.set_fact:
    onb_profile_id: "{{ onb_profile_rec.id }}"

# PIEGE 3+4 : geste DISTINCT, groupe systeme adresse par son NOM.
- name: "Gateway : membres actuels du groupe systeme"
  ansible.builtin.set_fact:
    onb_sys_members: >-
      {{ (onb_groups3.json.groups | default([])
          | selectattr('name', 'equalto', apim_onb_system_group)
          | map(attribute='userIds') | flatten | list) }}

- name: "Gateway : adherer au groupe systeme (acces a l'API d'admin)"
  ansible.builtin.uri:
    url: "{{ apim_ss_api_base }}/groups/{{ apim_onb_system_group }}"
    method: PUT
    body:
      id: "{{ apim_onb_system_group }}"
      name: "{{ apim_onb_system_group }}"
      description: "Users added to this group can perform similar API Gateway Providers tasks."
      type: "local"
      systemDefined: true
      userIds: "{{ (onb_sys_members + [onb_user_id]) | unique }}"
    status_code: [200, 201]
  when: "onb_user_id not in onb_sys_members"
```

- [ ] **Step 2: Lancer contre le mock**

```bash
cd poc-control-plane-federation/mocks/webmethods && go run . &
sleep 1
cd ../..
ansible-playbook -i ansible/inventory.lab.ini ansible/onboard-team.yml \
  -e apim_onb_team=banking-demo -v
```

Le playbook arrive en Task 7 : si tu suis l'ordre, reporte cette étape après. Attendu : `GROUP_MEMBER_OK` et `TEAM_GROUP_OK`.

- [ ] **Step 3: Prouver que la relecture attrape bien le piège**

Modifie temporairement le `PUT /groups/{id}` pour envoyer `userIds: ["{{ onb.user }}"]` (le loginId au lieu de l'UUID), relance, et vérifie que le run **rougit** sur `GROUP_MEMBER_UNCONFIRMED`. Puis remets l'UUID.

C'est la seule façon de savoir que la porte de preuve fonctionne : une assertion jamais vue échouer n'est pas une assertion.

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/apim_team_onboard/tasks/gateway.yml
git commit -m "feat(onboard): volet gateway — user, groupe, adhesion, team

Relecture apres chaque ecriture : sur cette API les quatre pieges connus sont
des succes silencieux (200 + liste vide). Un code de retour ne prouve rien,
seule la relecture le fait."
```

---

## Task 7: Orchestration, vérification et playbook

**Files:**
- Create: `ansible/roles/apim_team_onboard/tasks/main.yml`
- Create: `ansible/roles/apim_team_onboard/tasks/verify.yml`
- Create: `ansible/onboard-team.yml`

**Interfaces:**
- Consumes: `resolve.yml`, `vault.yml`, `gateway.yml`.
- Produces: le playbook `ansible/onboard-team.yml`, paramétré par `-e apim_onb_team=<x>`.

- [ ] **Step 1: Écrire `main.yml`**

```yaml
---
# roles/apim_team_onboard/tasks/main.yml — onboarding d'UNE equipe.
#
# ORDRE NON NEGOCIABLE : resolve -> vault -> gateway -> verify.
# Vault avant la gateway parce qu'un secret orphelin est inoffensif alors qu'un
# compte vivant au secret perdu ne l'est pas (cf. en-tete de vault.yml).
#
# La sonde Teams ne conditionne RIEN ici : users, groupes et accessProfiles sont
# des objets RBAC qui existent independamment du cloisonnement. Le role les pose
# dans tous les cas et DIT ce qu'il en est — c'est ce qui permet d'onboarder
# pendant qu'un correctif attend sa validation.

- name: "Onboarding : resoudre l'equipe et ses noms derives"
  ansible.builtin.import_tasks: resolve.yml

- name: "Onboarding : secrets d'admin gateway (Vault, fallback PoC)"
  ansible.builtin.import_role:
    name: apim_common
    tasks_from: secrets.yml

- name: "Onboarding : etat de la feature Teams (informatif ici)"
  ansible.builtin.import_role:
    name: apim_common
    tasks_from: teams-feature.yml
  vars:
    apim_ss_require_team: false     # l'onboarding ne DEPEND pas de la feature

- name: "Onboarding — equipe '{{ onb.team }}'"
  module_defaults:
    ansible.builtin.uri: "{{ apim_ss_uri_defaults }}"
  block:
    - ansible.builtin.import_tasks: vault.yml
    - ansible.builtin.import_tasks: gateway.yml
    - ansible.builtin.import_tasks: verify.yml

- name: "Onboarding : etat de cloisonnement de l'equipe posee"
  ansible.builtin.debug:
    msg: >-
      {{ 'Equipe ' ~ onb.team ~ ' posee et ACTIVE : la feature Teams est allumee.'
         if apim_teams_enabled | bool
         else 'Equipe ' ~ onb.team ~ ' posee ; feature Teams ETEINTE — les objets '
              ~ 'existent, leur effet de cloisonnement est DORMANT jusqu a '
              ~ 'reactivation. Rien a rejouer le moment venu.' }}
```

- [ ] **Step 2: Écrire `verify.yml`**

```yaml
---
# roles/apim_team_onboard/tasks/verify.yml — relecture independante.
#
# Verify ne fait pas confiance aux faits poses par l'apply : il RELIT tout
# depuis les deux systemes. C'est ce qui distingue « le run n'a pas plante » de
# « l'equipe existe ».

- name: "Verify : relire les trois objets gateway"
  ansible.builtin.uri:
    url: "{{ apim_ss_api_base }}/{{ item }}"
  register: onb_v
  changed_when: false
  loop: ["users", "groups", "accessProfiles"]

- name: "Verify : indexer les relectures"
  ansible.builtin.set_fact:
    v_users: "{{ (onb_v.results | selectattr('item', 'equalto', 'users') | first).json.users | default([]) }}"
    v_groups: "{{ (onb_v.results | selectattr('item', 'equalto', 'groups') | first).json.groups | default([]) }}"
    v_profs: "{{ (onb_v.results | selectattr('item', 'equalto', 'accessProfiles') | first).json.accessProfiles | default([]) }}"

- name: "Verify : FAIL-CLOSED — les 4 objets existent et sont RELIES"
  ansible.builtin.assert:
    that:
      # le user existe
      - "(v_users | selectattr('loginId', 'equalto', onb.user) | list | length) == 1"
      # le user est membre de son groupe
      - "onb_user_id in (v_groups | selectattr('name', 'equalto', onb.group) | map(attribute='userIds') | flatten | list)"
      # le groupe est porte par la team
      - "onb_group_id in (v_profs | selectattr('name', 'equalto', onb.team) | map(attribute='groupIds') | flatten | list)"
      # le user a acces a l'API d'admin
      - "onb_user_id in (v_groups | selectattr('name', 'equalto', apim_onb_system_group) | map(attribute='userIds') | flatten | list)"
    fail_msg: >-
      ONBOARD_UNCONFIRMED : la chaine user -> groupe -> team -> groupe systeme
      est rompue pour '{{ onb.team }}'. Un maillon absent = une equipe qui
      existe a moitie : elle peut avoir un compte sans acces, ou une team sans
      membre.
    success_msg: >-
      ONBOARD_OK : {{ onb.user }} ∈ {{ onb.group }} ∈ accessProfile
      {{ onb.team }}, et {{ onb.user }} ∈ {{ apim_onb_system_group }}.

- name: "Verify : relire l'entree KV (existence, jamais la valeur)"
  ansible.builtin.uri:
    url: "{{ apim_ss_vault_addr }}/v1/{{ onb_kv_path }}"
    headers: { X-Vault-Token: "{{ apim_ss_vault_token }}" }
    ca_path: "{{ apim_ss_ca_path | default('') or omit }}"
  register: onb_v_kv
  delegate_to: localhost
  changed_when: false
  no_log: true

- name: "Verify : FAIL-CLOSED — l'entree KV porte le bon username"
  ansible.builtin.assert:
    that: "onb_v_kv.json.data.data[apim_ss_vault_wm_user_key] == onb.user"
    fail_msg: >-
      KV_MISMATCH : {{ onb_kv_logical }} ne porte pas
      '{{ onb.user }}'. Le CI derive la team du 2e segment de ce chemin : une
      entree qui ne correspond pas au compte donne une identite incoherente.
    success_msg: "KV_OK : {{ onb_kv_logical }} -> {{ onb.user }}"

- name: "Verify : la policy existe"
  ansible.builtin.uri:
    url: "{{ apim_ss_vault_addr }}/v1/sys/policies/acl/{{ onb.policy }}"
    headers: { X-Vault-Token: "{{ apim_ss_vault_token }}" }
    ca_path: "{{ apim_ss_ca_path | default('') or omit }}"
  register: onb_v_pol
  delegate_to: localhost
  changed_when: false
  failed_when: "onb_v_pol.status != 200"
```

- [ ] **Step 3: Écrire le playbook**

`ansible/onboard-team.yml` :

```yaml
---
# Onboarding d'une equipe (palier 1 : Vault + gateway ; le depot Gitea est au
# palier 2). Le nom d'equipe est OBLIGATOIRE et doit etre declare dans
# providers.<env>.yml.
#
#   ansible-playbook -i ansible/inventory.lab.ini ansible/onboard-team.yml \
#     -e apim_onb_team=banking-demo
#
# Choisir la source declarative de l'environnement :
#     -e apim_onb_providers_file=providers.dev.yml
- name: "Onboarding d'equipe"
  hosts: webmethods
  gather_facts: false
  tasks:
    - name: "FAIL-CLOSED — une equipe cible est obligatoire"
      ansible.builtin.assert:
        that: "apim_onb_team | default('') | length > 0"
        fail_msg: >-
          Passer -e apim_onb_team=<equipe>. Onboarder « toutes les equipes du
          fichier » d'un seul geste est volontairement absent : une erreur y
          serait multipliee par le nombre d'equipes.

    - ansible.builtin.import_role:
        name: apim_team_onboard
```

- [ ] **Step 4: Bout-en-bout contre le mock**

```bash
cd poc-control-plane-federation/mocks/webmethods && go run . &
sleep 1 && cd ../..
export VAULT_ADDR=http://localhost:8200 VAULT_TOKEN=stoa-root-token
ansible-playbook -i ansible/inventory.lab.ini ansible/onboard-team.yml \
  -e apim_onb_team=banking-demo -e apim_ss_vault_token=$VAULT_TOKEN
```

Attendu : `ONBOARD_OK`, `KV_OK`, et le message de cloisonnement dormant (le mock rend `enableTeamWork: "false"`).

- [ ] **Step 5: Prouver l'idempotence**

```bash
ansible-playbook -i ansible/inventory.lab.ini ansible/onboard-team.yml \
  -e apim_onb_team=banking-demo -e apim_ss_vault_token=$VAULT_TOKEN | tail -3
```

Attendu : `changed=0`, et `secret existant repris` dans la sortie de `vault.yml`. Si `changed` > 0, une tâche écrit sans condition — corrige-la avant de continuer.

- [ ] **Step 6: Commit**

```bash
git add ansible/roles/apim_team_onboard/tasks/main.yml \
        ansible/roles/apim_team_onboard/tasks/verify.yml ansible/onboard-team.yml
git commit -m "feat(onboard): orchestration, verification et playbook

verify relit tout depuis les deux systemes plutot que de croire l'apply :
c'est ce qui distingue « le run n'a pas plante » de « l'equipe existe »."
```

---

## Task 8: `approvers` projeté dans `owner` au publish

**Files:**
- Create: `ansible/roles/apim_publish_api/tasks/approvers.yml`
- Modify: `ansible/roles/apim_publish_api/tasks/main.yml` (après l'activation)
- Modify: `ansible/roles/apim_publish_api/defaults/main.yml`

**Interfaces:**
- Consumes: `pub_api_id` (nom réel à relever à l'étape 1), `ss_team_name`, `apim_onb_providers_file`.
- Produces: `apim_pub_approvers_field` (défaut `owner`), `apim_pub_approvers_join` (défaut `,`).

- [ ] **Step 1: MESURER l'encodage réel avant d'écrire quoi que ce soit**

Le champ et son encodage ne sont pas connus de ce plan — ils viennent du système existant du client. Relève-les :

```bash
cd poc-control-plane-federation
# 1. le nom de la variable qui porte l'id de l'API dans le role
grep -n 'pub_api_id\|ss_api_id\|register: pub_' ansible/roles/apim_publish_api/tasks/main.yml | head
# 2. la forme reelle du champ sur une API existante
curl -s -u Administrator:manage http://localhost:5555/rest/apigateway/apis \
  | python3 -m json.tool | grep -i -A2 -B2 'owner'
```

Note : le champ est-il une chaîne ou un tableau ? Est-il au niveau `apiResponse` ou `api` (piège déjà rencontré avec `teams`) ? **N'écris la tâche qu'une fois ces deux points établis** — un plan ne peut pas les deviner, et se tromper ici écrit des matricules dans un champ que personne ne lit.

- [ ] **Step 2: Déclarer les knobs**

Ajoute à `ansible/roles/apim_publish_api/defaults/main.yml` :

```yaml
# --- approbateurs (projection depuis providers.<env>.yml) --------------------
# La LISTE fait autorite dans providers.<env>.yml ; ce champ n'en est qu'une
# PROJECTION, ecrite a chaque publish. Le developpement custom qui scrute les
# approbations en attente lit ce champ : ne pas le renommer sans lui.
# Les deux knobs epousent l'encodage constate chez le client (cf. Task 8 etape 1).
apim_pub_approvers_field: "owner"
apim_pub_approvers_join: ","      # mettre "" pour ecrire un TABLEAU
apim_pub_providers_file: "providers.dev.yml"
```

- [ ] **Step 3: Écrire `approvers.yml`**

Adapte les deux lignes marquées à ce que l'étape 1 a établi :

```yaml
---
# roles/apim_publish_api/tasks/approvers.yml — projection de la liste d'approbateurs.
#
# POURQUOI AU PUBLISH ET PAS A L'ONBOARDING. Les APIs naissent APRES l'equipe et
# continueront de naitre : une liste posee une fois manquerait a la premiere API
# publiee le lendemain. Ecrite ici, a chaque publish, une API ayant derive
# revient dans le rang au publish suivant, sans geste particulier.
#
# La liste fait autorite dans providers.<env>.yml. Ce champ en est la PROJECTION.

- name: "Approbateurs : charger la source declarative"
  ansible.builtin.include_vars:
    file: "{{ apim_pub_providers_file }}"
    name: pub_prov

- name: "Approbateurs : liste de l'equipe"
  ansible.builtin.set_fact:
    pub_approvers: >-
      {{ (pub_prov.providers | default([])
          | selectattr('team', 'equalto', ss_team_name)
          | map(attribute='approvers') | flatten | list) }}

- name: "Approbateurs : rien a projeter (equipe absente ou liste vide)"
  ansible.builtin.debug:
    msg: >-
      APPROVERS_EMPTY : aucune liste pour '{{ ss_team_name }}' dans
      {{ apim_pub_providers_file }} — le champ
      {{ apim_pub_approvers_field }} est laisse tel quel.
  when: "pub_approvers | length == 0"

- name: "Approbateurs : projeter dans {{ apim_pub_approvers_field }}"
  when: "pub_approvers | length > 0"
  block:
    - name: "Approbateurs : relire l'API"
      ansible.builtin.uri:
        url: "{{ apim_ss_api_base }}/apis/{{ pub_api_id }}"   # <-- nom releve a l'etape 1
      register: pub_api_get
      changed_when: false

    - name: "Approbateurs : record de l'API"
      ansible.builtin.set_fact:
        pub_api_rec: "{{ pub_api_get.json.apiResponse.api }}"  # <-- niveau releve a l'etape 1

    - name: "Approbateurs : valeur projetee (chaine jointe OU tableau)"
      ansible.builtin.set_fact:
        pub_approvers_value: >-
          {{ (pub_approvers | join(apim_pub_approvers_join))
             if (apim_pub_approvers_join | length > 0) else pub_approvers }}

    - name: "Approbateurs : ecrire (write-always — une API ayant derive revient)"
      ansible.builtin.uri:
        url: "{{ apim_ss_api_base }}/apis/{{ pub_api_id }}"
        method: PUT
        body: >-
          {{ {'apiResponse': {'api': pub_api_rec | combine({apim_pub_approvers_field: pub_approvers_value})}} }}
        status_code: [200, 201]

    - name: "Approbateurs : relire et EXIGER la valeur"
      ansible.builtin.uri:
        url: "{{ apim_ss_api_base }}/apis/{{ pub_api_id }}"
      register: pub_api_after
      changed_when: false

    - name: "Approbateurs : FAIL-CLOSED — la projection a REELLEMENT eu lieu"
      ansible.builtin.assert:
        that: "(pub_api_after.json.apiResponse.api[apim_pub_approvers_field] | default('')) == pub_approvers_value"
        fail_msg: >-
          APPROVERS_UNCONFIRMED : apres PUT, le champ
          {{ apim_pub_approvers_field }} vaut
          '{{ pub_api_after.json.apiResponse.api[apim_pub_approvers_field] | default('(absent)') }}'
          au lieu de '{{ pub_approvers_value }}'. Le champ est peut-etre ignore
          par le produit a ce niveau d'enveloppe (cf. le piege teams, lu au
          niveau apiResponse et non api).
        success_msg: "APPROVERS_OK : {{ pub_approvers | length }} approbateur(s) projete(s)"
```

- [ ] **Step 4: Brancher dans `main.yml`**

Après l'activation de l'API et avant le scoping team :

```yaml
    - name: "Approbateurs : projeter la liste de l'equipe"
      ansible.builtin.import_tasks: approvers.yml
      when: "ss_team_name | length > 0"
```

- [ ] **Step 5: Prouver contre le mock**

```bash
cd poc-control-plane-federation
ansible-playbook -i ansible/inventory.lab.ini ansible/publish-api.yml \
  -e apim_ss_team=banking-demo -e apim_ss_require_team=false -v | grep APPROVERS_
```

Attendu : `APPROVERS_OK : 2 approbateur(s) projete(s)`.

- [ ] **Step 6: Commit**

```bash
git add ansible/roles/apim_publish_api/tasks/approvers.yml \
        ansible/roles/apim_publish_api/tasks/main.yml \
        ansible/roles/apim_publish_api/defaults/main.yml
git commit -m "feat(publish): projeter les approbateurs de l'equipe dans owner

La liste fait desormais autorite dans providers.<env>.yml ; owner n'en est
qu'une projection ecrite a chaque publish. Le developpement custom qui la lit
n'est pas touche — le jour ou il est remplace, seul l'ecrivain change."
```

---

## Task 9: Les sept preuves, sur dev

Les tâches précédentes prouvent contre le mock. Celle-ci prouve contre la vraie gateway — et lève l'hypothèse du §2 du spec.

**Files:**
- Create: `scripts/test-onboard-team.sh`

**Interfaces:**
- Consumes: le rôle complet, un Vault joignable, la gateway dev.
- Produces: une sortie `PASS n / FAIL n` sur le modèle de `scripts/setup-wm-admin-self-proxy.sh`.

- [ ] **Step 1: Écrire le script de preuve**

```bash
#!/usr/bin/env bash
# test-onboard-team.sh — les 7 preuves du palier 1, sur une equipe JETABLE.
#
# N'ecrit JAMAIS sur banking-demo ni insurance-demo : l'equipe de test est
# creee puis supprimee. La preuve 3 est la seule qui compte vraiment — les
# autres verifient que des objets existent, celle-la verifie que l'ISOLATION
# TIENT, donc que la derivation du CI est digne de confiance.
set -uo pipefail
cd "$(dirname "$0")/.."

T="${ONBOARD_PROBE_TEAM:-onboard-probe}"
VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-stoa-root-token}"
WM="${WM_GATEWAY_URL:-http://localhost:5555}"
A="${WM_ADMIN:-Administrator:manage}"
INV="${INVENTORY:-ansible/inventory.lab.ini}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

api() { curl -s -u "$A" -H 'Accept: application/json' "$WM/rest/apigateway/$1"; }
vlt() { curl -s -H "X-Vault-Token: $1" "$VAULT_ADDR/v1/$2" -o /dev/null -w '%{http_code}'; }

echo "== onboarding de l'equipe jetable $T =="
ansible-playbook -i "$INV" ansible/onboard-team.yml \
  -e "apim_onb_team=$T" -e "apim_ss_vault_token=$VAULT_TOKEN" >/tmp/onb1.log 2>&1 \
  || { bad "l'onboarding a echoue — voir /tmp/onb1.log"; exit 1; }

# --- 1. les 4 objets gateway existent et sont relies -------------------------
UID_=$(api users | python3 -c "
import json,sys
print(next((u['id'] for u in json.load(sys.stdin)['users'] if u['loginId']=='svc-$T'), ''))")
GID=$(api groups | python3 -c "
import json,sys
print(next((g['id'] for g in json.load(sys.stdin)['groups'] if g['name']=='$T-devs'), ''))")
LINKED=$(api accessProfiles | python3 -c "
import json,sys
p=next((p for p in json.load(sys.stdin)['accessProfiles'] if p['name']=='$T'), None)
print('yes' if p and '$GID' in (p.get('groupIds') or []) else 'no')")
SYS=$(api groups | python3 -c "
import json,sys
g=next((g for g in json.load(sys.stdin)['groups'] if g['name']=='API-Gateway-Providers'), None)
print('yes' if g and '$UID_' in (g.get('userIds') or []) else 'no')")
[ -n "$UID_" ] && [ -n "$GID" ] && [ "$LINKED" = yes ] && [ "$SYS" = yes ] \
  && ok "1. user/groupe/team/groupe systeme poses et relies" \
  || bad "1. chaine rompue (user=$UID_ groupe=$GID team=$LINKED systeme=$SYS)"

# --- 2. le secret et la policy existent --------------------------------------
[ "$(vlt "$VAULT_TOKEN" "secret/data/stoa/deploy/$T/wm-admin")" = 200 ] \
  && [ "$(vlt "$VAULT_TOKEN" "sys/policies/acl/deploy-$T")" = 200 ] \
  && ok "2. entree KV et policy deploy-$T presentes" || bad "2. KV ou policy absente"

# --- 3. LA DOUVE : la policy borne REELLEMENT la lecture ---------------------
TOK=$(curl -s -H "X-Vault-Token: $VAULT_TOKEN" -X POST \
  -d "{\"policies\":[\"deploy-$T\"],\"ttl\":\"5m\"}" \
  "$VAULT_ADDR/v1/auth/token/create" | python3 -c "
import json,sys; print(json.load(sys.stdin)['auth']['client_token'])")
MINE=$(vlt "$TOK" "secret/data/stoa/deploy/$T/wm-admin")
THEIRS=$(vlt "$TOK" "secret/data/stoa/deploy/banking-demo/wm-admin")
[ "$MINE" = 200 ] && [ "$THEIRS" = 403 ] \
  && ok "3. DOUVE : lit son KV (200), refuse celui d'une autre equipe (403)" \
  || bad "3. DOUVE ROMPUE : sien=$MINE autre=$THEIRS (attendu 200 / 403)"

# --- 4. la derivation du CI rend bien l'equipe -------------------------------
[ "$(printf '%s' "deploy/$T/wm-admin" | cut -d/ -f2)" = "$T" ] \
  && ok "4. la derivation du CI sur ce chemin KV rend '$T'" || bad "4. derivation incoherente"

# --- 5. re-run : rien ne change, le mot de passe ne tourne pas ---------------
BEFORE=$(curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/secret/data/stoa/deploy/$T/wm-admin" | sha256sum)
ansible-playbook -i "$INV" ansible/onboard-team.yml \
  -e "apim_onb_team=$T" -e "apim_ss_vault_token=$VAULT_TOKEN" >/tmp/onb2.log 2>&1
AFTER=$(curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/secret/data/stoa/deploy/$T/wm-admin" | sha256sum)
CH=$(grep -o 'changed=[0-9]*' /tmp/onb2.log | tail -1 | cut -d= -f2)
[ "$BEFORE" = "$AFTER" ] && [ "${CH:-1}" = 0 ] \
  && ok "5. re-run idempotent (changed=0) et mot de passe inchange" \
  || bad "5. re-run non idempotent (changed=${CH:-?}) ou secret rejoue"

# --- 6. L'HYPOTHESE DU SPEC : accessProfile pose feature ETEINTE -------------
TW=$(api configurations/extended | python3 -c "
import json,sys; print(json.load(sys.stdin).get('enableTeamWork','?'))")
if [ "$TW" = "false" ]; then
  [ "$LINKED" = yes ] \
    && ok "6. feature ETEINTE et accessProfile pose — l'onboarding n'est PAS bloque" \
    || bad "6. feature eteinte : l'accessProfile n'a pas ete pose (le palier 1 se reduit a Vault)"
else
  printf '  \033[33mSKIP\033[0m 6. feature ACTIVE (enableTeamWork=%s) : hypothese non testable ici\n' "$TW"
fi

# --- 7. suppression symetrique ----------------------------------------------
PID=$(api accessProfiles | python3 -c "
import json,sys
print(next((p['id'] for p in json.load(sys.stdin)['accessProfiles'] if p['name']=='$T'), ''))")
for u in "accessProfiles/$PID" "groups/$GID" "users/$UID_"; do
  curl -s -u "$A" -X DELETE "$WM/rest/apigateway/$u" -o /dev/null
done
curl -s -H "X-Vault-Token: $VAULT_TOKEN" -X DELETE \
  "$VAULT_ADDR/v1/secret/metadata/stoa/deploy/$T/wm-admin" -o /dev/null
curl -s -H "X-Vault-Token: $VAULT_TOKEN" -X DELETE \
  "$VAULT_ADDR/v1/sys/policies/acl/deploy-$T" -o /dev/null
GONE=$(api accessProfiles | python3 -c "
import json,sys
print('no' if any(p['name']=='$T' for p in json.load(sys.stdin)['accessProfiles']) else 'yes')")
[ "$GONE" = yes ] && [ "$(vlt "$VAULT_TOKEN" "sys/policies/acl/deploy-$T")" != 200 ] \
  && ok "7. suppression symetrique : rien d'orphelin" || bad "7. residus apres suppression"

echo "== $PASS PASS / $FAIL FAIL =="
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Rendre exécutable et lancer sur dev**

```bash
cd poc-control-plane-federation
chmod +x scripts/test-onboard-team.sh
VAULT_ADDR=... VAULT_TOKEN=... WM_GATEWAY_URL=... ./scripts/test-onboard-team.sh
```

Attendu : `7 PASS / 0 FAIL`.

- [ ] **Step 3: Consigner le résultat de la preuve 6**

C'est l'hypothèse du spec. Selon le résultat, mets à jour l'en-tête `status:` de `docs/superpowers/specs/2026-08-03-onboarding-equipe-design.md` :

- **PASS** → « Hypothèse §2 CONFIRMÉE le <date> : accessProfile posé feature éteinte. »
- **FAIL** → « Hypothèse §2 RÉFUTÉE le <date> : le palier 1 se réduit à Vault, la gateway attend le correctif. » — et ouvre une tâche pour retirer `gateway.yml` du chemin nominal.

Ne laisse pas le spec dire « à mesurer » une fois la mesure faite : un spec qui ment sur son propre état est pire qu'un spec absent.

- [ ] **Step 4: Commit**

```bash
git add scripts/test-onboard-team.sh docs/superpowers/specs/2026-08-03-onboarding-equipe-design.md
git commit -m "test(onboard): les 7 preuves du palier 1 sur equipe jetable

La preuve 3 (douve Vault) est la seule qui compte vraiment : les autres
verifient que des objets existent, celle-la verifie que l'isolation tient.
La preuve 6 leve l'hypothese du spec sur la feature eteinte."
```

---

## Auto-relecture

**Couverture du spec.** §1 → Task 3. §2 → Tasks 1, 6, 9 (preuve 6). §3 → Task 2. §4 → Task 4. §5 → Tasks 5, 6, 7. §6 → Task 8. §7 gardes → Tasks 4 (nom), 6 (relecture), 4 (convention) ; §7 preuves → Task 9. §8 palier 2 et hors périmètre → non planifié, conforme.

**Cohérence des noms.** `apim_teams_enabled` produit par Task 2, consommé par Tasks 3 et 7. `onb.{team,user,group,kv_sub,policy}` produit par Task 4, consommé par 5, 6, 7. `onb_user_id`/`onb_group_id`/`onb_profile_id` produits par Task 6, consommés par 7. `onb_kv_path`/`onb_kv_logical` produits par Task 5, consommés par 7.

**Deux inconnues assumées, traitées comme des mesures et non des hypothèses.**

1. Les helpers du mock (Task 1 étape 1) — relevés avant écriture plutôt que devinés.
2. Le champ `owner` et son encodage (Task 8 étape 1) — le plan refuse de deviner un format qui appartient au système existant du client, et bloque l'écriture de la tâche tant qu'il n'est pas relevé.

**Ordre d'exécution.** Les Tasks 5 et 6 portent des étapes de preuve qui dépendent du playbook créé en Task 7 ; elles sont marquées comme reportables. Exécuter dans l'ordre 1 → 9 et rejouer les preuves reportées à la fin de la Task 7.
