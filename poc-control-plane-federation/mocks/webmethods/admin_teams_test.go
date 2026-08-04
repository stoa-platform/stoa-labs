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

// LE PIÈGE : groupIds passés par NOM (custom) sont ignorés en silence — 200,
// liste vide. C'est le comportement mesuré du produit ; le rôle doit s'y
// casser les dents en test, pas en production.
func TestAccessProfileIgnoresGroupNames(t *testing.T) {
	srv := httptest.NewServer(NewServer().Handler())
	defer srv.Close()

	post(t, srv, "/rest/apigateway/groups", map[string]any{
		"name": "banking-demo-devs", "type": "local"})

	prof := post(t, srv, "/rest/apigateway/accessProfiles", map[string]any{
		"name": "banking-demo", "privilege": "111100101101100000001",
		"groupIds": []string{"banking-demo-devs"}, // un NOM custom, pas un UUID
	})

	ids, _ := prof["groupIds"].([]any)
	if len(ids) != 0 {
		t.Fatalf("groupIds = %v, attendu vide (les noms custom sont ignorés)", ids)
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

// LE MÊME PIÈGE, un cran plus bas : userIds passés par loginId (custom) sont
// ignorés en silence — 200, liste vide. createGroup partage keepKnown avec
// createProfile, mais ce chemin de code n'était jusqu'ici jamais exercé par
// un test dédié (constat de revue, round 1).
func TestGroupIgnoresUserLoginNames(t *testing.T) {
	srv := httptest.NewServer(NewServer().Handler())
	defer srv.Close()

	post(t, srv, "/rest/apigateway/users", map[string]any{
		"firstName": "Jane", "lastName": "Doe", "loginId": "jane.doe", "password": "x"})

	grp := post(t, srv, "/rest/apigateway/groups", map[string]any{
		"name": "banking-demo-devs", "type": "local",
		"userIds": []string{"jane.doe"}, // un loginId custom, pas un UUID
	})

	ids, _ := grp["userIds"].([]any)
	if len(ids) != 0 {
		t.Fatalf("userIds = %v, attendu vide (les loginId custom sont ignorés)", ids)
	}
}

// Le même appel avec l'UUID de l'utilisateur réellement créé fonctionne —
// sans quoi le test précédent ne prouverait rien (il passerait aussi si la
// surface était inerte).
func TestGroupAcceptsUserUUID(t *testing.T) {
	srv := httptest.NewServer(NewServer().Handler())
	defer srv.Close()

	usr := post(t, srv, "/rest/apigateway/users", map[string]any{
		"firstName": "Jane", "lastName": "Doe", "loginId": "jane.doe", "password": "x"})
	uid, _ := usr["id"].(string)
	if uid == "" {
		t.Fatal("l'utilisateur créé n'a pas d'id")
	}

	grp := post(t, srv, "/rest/apigateway/groups", map[string]any{
		"name": "banking-demo-devs", "type": "local",
		"userIds": []string{uid},
	})
	ids, _ := grp["userIds"].([]any)
	if len(ids) != 1 || ids[0] != uid {
		t.Fatalf("userIds = %v, attendu [%s]", ids, uid)
	}
}

// Les groupes SYSTÈME (livrés d'usine) ont id == name — mesuré 2026-08-03.
// Passer leur NOM comme groupId réussit donc : ce n'est PAS une exception au
// piège du dessus, c'est la même règle keepKnown appliquée à un id différent.
// Sans ce test, on pourrait croire à tort que TOUT nom de groupe est rejeté.
func TestAccessProfileAcceptsSystemGroupName(t *testing.T) {
	srv := httptest.NewServer(NewServer().Handler())
	defer srv.Close()

	prof := post(t, srv, "/rest/apigateway/accessProfiles", map[string]any{
		"name": "banking-demo", "privilege": "111100101101100000001",
		"groupIds": []string{"API-Gateway-Providers"}, // groupe SYSTÈME : id == name
	})
	ids, _ := prof["groupIds"].([]any)
	if len(ids) != 1 || ids[0] != "API-Gateway-Providers" {
		t.Fatalf("groupIds = %v, attendu [API-Gateway-Providers] (id==name pour un groupe système)", ids)
	}
}

// Les accessProfiles SYSTÈME sont préinstallés avec leurs groupIds mesurés en
// clair sur la gateway — la table de vérité des rôles suivants en dépend.
func TestSystemAccessProfilesPreinstalled(t *testing.T) {
	srv := httptest.NewServer(NewServer().Handler())
	defer srv.Close()

	got := get(t, srv, "/rest/apigateway/accessProfiles")
	profiles, _ := got["accessProfiles"].([]any)
	byID := map[string]map[string]any{}
	for _, raw := range profiles {
		p, _ := raw.(map[string]any)
		if p == nil {
			continue
		}
		id, _ := p["id"].(string)
		byID[id] = p
	}

	def, ok := byID["Default"]
	if !ok {
		t.Fatal("accessProfile système 'Default' absent")
	}
	if def["id"] != "Default" || def["name"] != "Default" {
		t.Fatalf("Default: id/name = %v/%v, attendu Default/Default (id==name)", def["id"], def["name"])
	}
	ids, _ := def["groupIds"].([]any)
	if len(ids) != 1 || ids[0] != "Everybody" {
		t.Fatalf("Default.groupIds = %v, attendu [Everybody]", ids)
	}

	admins, ok := byID["Administrators"]
	if !ok {
		t.Fatal("accessProfile système 'Administrators' absent")
	}
	adminIDs, _ := admins["groupIds"].([]any)
	if len(adminIDs) != 2 {
		t.Fatalf("Administrators.groupIds = %v, attendu 2 entrées", adminIDs)
	}
}
