package main

// Palier 3, Task 6 (fix round 1) : les faits MESURÉS le 2026-08-05 sur la vraie
// 10.15 qui gouvernent la garde d'appartenance de lignée du rôle
// apim_publish_api (VERSION_BASE_FOREIGN), plus le fait de forme dont dépend
// son témoin de souscription.
//
// Chaque test ici a été vu ROUGIR sans le code qu'il cloue (contre-épreuve
// exigée en revue : un fix sans test qui rougit n'est pas cloué).

import (
	"net/http"
	"testing"
)

// --- forme : consumingAPIs présent-et-vide -----------------------------------

// TestCreateApp_ConsumingAPIsPresentAndEmpty cloue le fix du commit 8ae8ab9.
//
// MESURÉ le 2026-08-05 : une application créée à l'instant et JAMAIS associée
// porte "consumingAPIs":[] — la clé est PRÉSENTE — aussi bien dans
// GET /applications (liste) que dans GET /applications/{id}.
//
// La PRÉSENCE est ce qui est porteur, pas la valeur : version.yml distingue
// « aucun abonné » (clé présente, liste vide) de « la forme qui porte les
// abonnés a disparu » (clé absente ⇒ VERSION_SUBS_SHAPE_UNKNOWN). Un témoin
// vide par accident de forme passerait pour une preuve.
//
// D'où l'assertion en DEUX temps avec le `ok` de l'assertion de type — un
// `raw, _ := app["consumingAPIs"].([]any)` avale l'absence et rendrait ce test
// vert sans le fix (c'est exactement le trou relevé en revue).
func TestCreateApp_ConsumingAPIsPresentAndEmpty(t *testing.T) {
	h := newTestServer(t)
	rr := doAdmin(t, h, "POST", "/rest/apigateway/applications", map[string]any{"name": "p3t6-fresh"})
	if rr.Code != http.StatusCreated {
		t.Fatalf("create app = %d body=%s", rr.Code, rr.Body)
	}
	appID := decode(t, rr)["id"].(string)

	for _, probe := range []struct {
		what string
		app  map[string]any
	}{
		{"GET /applications/{id}", appRecordSingle(t, h, appID)},
		{"GET /applications (liste)", appRecordInList(t, h, appID)},
	} {
		raw, present := probe.app["consumingAPIs"]
		if !present {
			t.Errorf("%s : clé consumingAPIs ABSENTE sur une application fraîche — "+
				"mesurée PRÉSENTE (et vide) le 2026-08-05 ; son absence rendrait le témoin "+
				"de souscription du rôle vide par accident de forme", probe.what)
			continue
		}
		list, isList := raw.([]any)
		if !isList {
			t.Errorf("%s : consumingAPIs = %T, attendu un tableau", probe.what, raw)
			continue
		}
		if len(list) != 0 {
			t.Errorf("%s : consumingAPIs = %v, attendu vide (jamais associée)", probe.what, list)
		}
	}
}

func appRecordSingle(t *testing.T, h http.Handler, appID string) map[string]any {
	t.Helper()
	rr := doAdmin(t, h, "GET", "/rest/apigateway/applications/"+appID, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("get app = %d body=%s", rr.Code, rr.Body)
	}
	return decode(t, rr)["applications"].([]any)[0].(map[string]any)
}

func appRecordInList(t *testing.T, h http.Handler, appID string) map[string]any {
	t.Helper()
	rr := doAdmin(t, h, "GET", "/rest/apigateway/applications", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("list apps = %d body=%s", rr.Code, rr.Body)
	}
	for _, raw := range decode(t, rr)["applications"].([]any) {
		app := raw.(map[string]any)
		if app["id"] == appID {
			return app
		}
	}
	t.Fatalf("application %s absente de la liste", appID)
	return nil
}

// --- teams : la surface dont dépend VERSION_BASE_FOREIGN ---------------------

// teamsOfAPI reads the teams of an API from the SINGLE GET, at the apiResponse
// level (NOT apiResponse.api.teams, null on the real product).
func teamsOfAPI(t *testing.T, h http.Handler, apiID string) []string {
	t.Helper()
	rr := doAdmin(t, h, "GET", "/rest/apigateway/apis/"+apiID, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("get api = %d body=%s", rr.Code, rr.Body)
	}
	return teamNames(t, decode(t, rr)["apiResponse"].(map[string]any))
}

// teamsOfAPIInList reads the same thing from the LIST — the call the role
// actually uses to scope a lineage without paying a GET per sibling.
func teamsOfAPIInList(t *testing.T, h http.Handler, apiID string) []string {
	t.Helper()
	rr := doAdmin(t, h, "GET", "/rest/apigateway/apis", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("list apis = %d body=%s", rr.Code, rr.Body)
	}
	for _, raw := range decode(t, rr)["apiResponse"].([]any) {
		item := raw.(map[string]any)
		if item["api"].(map[string]any)["id"] == apiID {
			return teamNames(t, item)
		}
	}
	t.Fatalf("api %s absente de la liste", apiID)
	return nil
}

func teamNames(t *testing.T, envelope map[string]any) []string {
	t.Helper()
	raw, present := envelope["teams"]
	if !present {
		t.Fatalf("clé `teams` ABSENTE de l'enveloppe apiResponse — mesurée présente le 2026-08-05")
	}
	out := []string{}
	for _, v := range raw.([]any) {
		out = append(out, v.(map[string]any)["name"].(string))
	}
	return out
}

func mkProfile(t *testing.T, h http.Handler, name string) string {
	t.Helper()
	rr := doAdmin(t, h, "POST", "/rest/apigateway/accessProfiles", map[string]any{"name": name})
	if rr.Code != http.StatusCreated {
		t.Fatalf("create accessProfile = %d body=%s", rr.Code, rr.Body)
	}
	return decode(t, rr)["id"].(string)
}

// TestAPI_FreshImport_IsInDefaultTeam : une API importée naît en
// [Administrators, Default] — et `Default` est la moitié qui compte : tant
// qu'elle est là, TOUTES les équipes lisent l'API (mesuré le 2026-07-31).
// Les DEUX surfaces (unitaire et liste) doivent la porter : la garde du rôle
// lit la LISTE, un test qui ne couvrirait que l'unitaire la laisserait aveugle.
func TestAPI_FreshImport_IsInDefaultTeam(t *testing.T) {
	h := newTestServer(t)
	apiID, _ := importAPI(t, h, "p3t6-teams-fresh", "1.0.0")
	for what, got := range map[string][]string{
		"unitaire": teamsOfAPI(t, h, apiID),
		"liste":    teamsOfAPIInList(t, h, apiID),
	} {
		if !containsStr(got, "Default") || !containsStr(got, "Administrators") {
			t.Errorf("teams (%s) = %v, attendu [Administrators, Default]", what, got)
		}
	}
}

// TestAssignTeam_WrongAssetType_IsSilentNoOp : LE piège de POST /assets/team —
// sans `assetType` (ou avec un autre), le produit répond 200 et ne fait RIEN.
// Le contre-témoin (même appel, assetType correct) est dans le MÊME test : sans
// lui, un handler cassé rendrait ce test vert pour la mauvaise raison.
func TestAssignTeam_WrongAssetType_IsSilentNoOp(t *testing.T) {
	h := newTestServer(t)
	apiID, _ := importAPI(t, h, "p3t6-teams-noop", "1.0.0")
	profID := mkProfile(t, h, "payments-team")

	rr := doAdmin(t, h, "POST", "/rest/apigateway/assets/team", map[string]any{
		"assetIds": []string{apiID}, "newTeams": []string{profID}, // assetType MANQUANT
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("assetType manquant = %d, attendu 200 (le refus est SILENCIEUX)", rr.Code)
	}
	if got := teamsOfAPI(t, h, apiID); containsStr(got, "payments-team") {
		t.Errorf("teams = %v : l'assignation a pris effet SANS assetType — le piège n'est plus reproduit", got)
	}

	rr = doAdmin(t, h, "POST", "/rest/apigateway/assets/team", map[string]any{
		"assetIds": []string{apiID}, "assetType": "API", "newTeams": []string{profID},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("assignation correcte = %d body=%s", rr.Code, rr.Body)
	}
	got := teamsOfAPI(t, h, apiID)
	if !containsStr(got, "payments-team") {
		t.Errorf("teams = %v, attendu payments-team présente", got)
	}
	if containsStr(got, "Default") {
		t.Errorf("teams = %v : `Default` doit PARTIR dès qu'une équipe est posée (sinon l'API reste lue par toutes)", got)
	}
}

// TestAssignTeam_UnknownProfileIsDroppedSilently : `newTeams` attend des UUID
// d'accessProfile ; une entrée inconnue est jetée sans erreur (même règle que
// partout ailleurs sur ce produit). L'API retombe alors sur Administrators
// SEULE — donc plus de Default non plus : un appel « réussi » peut laisser
// l'asset sans l'équipe demandée.
func TestAssignTeam_UnknownProfileIsDroppedSilently(t *testing.T) {
	h := newTestServer(t)
	apiID, _ := importAPI(t, h, "p3t6-teams-unknown", "1.0.0")
	rr := doAdmin(t, h, "POST", "/rest/apigateway/assets/team", map[string]any{
		"assetIds": []string{apiID}, "assetType": "API",
		"newTeams": []string{"une-equipe-qui-n-existe-pas"},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("profil inconnu = %d, attendu 200 (jeté en silence)", rr.Code)
	}
	if got := teamsOfAPI(t, h, apiID); containsStr(got, "une-equipe-qui-n-existe-pas") {
		t.Errorf("teams = %v : un id d'équipe inconnu ne doit JAMAIS être retenu", got)
	}
}

// TestCreateVersionAPI_InheritsBaseTeams — MESURÉ le 2026-08-05 sur la vraie
// 10.15 : base assignée à `payments-team` (Default retirée) puis mint → la
// version minée naît avec [Administrators, payments-team], PAS en Default.
//
// C'est le fait qui rend la capture cross-lignée grave : miner dans la lignée
// d'une autre équipe dépose la nouvelle version DANS son périmètre à elle.
func TestCreateVersionAPI_InheritsBaseTeams(t *testing.T) {
	h := newTestServer(t)
	baseID, _ := importAPI(t, h, "p3t6-teams-inherit", "1.0.0")
	profID := mkProfile(t, h, "payments-team")
	rr := doAdmin(t, h, "POST", "/rest/apigateway/assets/team", map[string]any{
		"assetIds": []string{baseID}, "assetType": "API", "newTeams": []string{profID},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("assignation = %d body=%s", rr.Code, rr.Body)
	}

	rr = doAdmin(t, h, "POST", "/rest/apigateway/apis/"+baseID+"/versions",
		map[string]any{"newApiVersion": "2.0", "retainApplications": true})
	if rr.Code != http.StatusCreated {
		t.Fatalf("mint = %d body=%s", rr.Code, rr.Body)
	}
	newID := decode(t, rr)["apiResponse"].(map[string]any)["api"].(map[string]any)["id"].(string)

	got := teamsOfAPI(t, h, newID)
	if !containsStr(got, "payments-team") {
		t.Errorf("teams de la version minée = %v, attendu l'héritage de payments-team", got)
	}
	if containsStr(got, "Default") {
		t.Errorf("teams de la version minée = %v : elle ne retombe PAS en Default (mesuré)", got)
	}
}

// TestCreateVersionAPI_UnknownBase_Is401 : sur cette 10.15, une ressource
// absente — supprimée OU jamais existante — rend 401, PAS 404 (mesuré au spike
// T1, y compris avec un GUID inventé). Le rôle n'interprète aucun code
// particulier (tout non-2xx ⇒ VERSION_CREATE_FAILED), mais le mock ne doit pas
// enseigner un 404 que le produit ne rend jamais.
func TestCreateVersionAPI_UnknownBase_Is401(t *testing.T) {
	h := newTestServer(t)
	rr := doAdmin(t, h, "POST", "/rest/apigateway/apis/00000000-0000-4000-8000-000000000000/versions",
		map[string]any{"newApiVersion": "2.0", "retainApplications": true})
	if rr.Code != http.StatusUnauthorized {
		t.Errorf("POST /versions sur un id inconnu = %d, attendu 401 (fait mesuré, pas 404)", rr.Code)
	}
}

// ── A7 (ADR-090) : le produit assigne aussi les APPLICATIONS ────────────────
//
// Spike ownership du 2026-08-04 (mémoire wm-1015-app-ownership-team) :
// POST /assets/team avec assetType "Application" cloisonne l'application ;
// le rôle apim_selfservice_app (team.yml) relit teams[] juste après et EXIGE
// la team présente ET `Default` partie — mesuré le 2026-09-03 : sans cette
// fidélité, le rôle réel s'arrêtait sur TEAM_UNCONFIRMED contre ce mock,
// après avoir passé la porte A5 et créé l'application.

func teamsOfApp(t *testing.T, h http.Handler, appID string) []string {
	t.Helper()
	rr := doAdmin(t, h, "GET", "/rest/apigateway/applications/"+appID, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("GET application = %d body=%s", rr.Code, rr.Body)
	}
	apps, _ := decode(t, rr)["applications"].([]any)
	if len(apps) != 1 {
		t.Fatalf("enveloppe applications[] attendue, reçu %s", rr.Body)
	}
	return teamNamesOf(apps[0])
}

func teamsOfAppInList(t *testing.T, h http.Handler, appID string) []string {
	t.Helper()
	rr := doAdmin(t, h, "GET", "/rest/apigateway/applications", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("GET applications = %d", rr.Code)
	}
	apps, _ := decode(t, rr)["applications"].([]any)
	for _, a := range apps {
		if m, _ := a.(map[string]any); m != nil && m["id"] == appID {
			return teamNamesOf(m)
		}
	}
	t.Fatalf("application %s absente de la liste", appID)
	return nil
}

func teamNamesOf(app any) []string {
	m, _ := app.(map[string]any)
	refs, _ := m["teams"].([]any)
	out := []string{}
	for _, r := range refs {
		if rm, _ := r.(map[string]any); rm != nil {
			if n, _ := rm["name"].(string); n != "" {
				out = append(out, n)
			}
		}
	}
	return out
}

func TestAssignTeam_Application_SetsTeams(t *testing.T) {
	h := newTestServer(t)
	rr := doAdmin(t, h, "POST", "/rest/apigateway/applications", map[string]any{"name": "a7-app"})
	if rr.Code != http.StatusCreated {
		t.Fatalf("POST application = %d body=%s", rr.Code, rr.Body)
	}
	appID, _ := decode(t, rr)["id"].(string)
	if appID == "" {
		t.Fatalf("application créée sans id : %s", rr.Body)
	}
	// Une application NEUVE est visible de toutes les équipes : Default + Administrators
	// (c'est ce que ss_team_converged du rôle teste avant d'écrire).
	if got := teamsOfApp(t, h, appID); !containsStr(got, "Default") || !containsStr(got, "Administrators") {
		t.Errorf("teams d'une application neuve = %v, attendu [Administrators, Default]", got)
	}
	profID := mkProfile(t, h, "banking-demo")

	// Le piège reste reproduit : sans assetType, 200 et RIEN ne se passe.
	rr = doAdmin(t, h, "POST", "/rest/apigateway/assets/team", map[string]any{
		"assetIds": []string{appID}, "newTeams": []string{profID},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("assetType manquant = %d, attendu 200 (refus silencieux)", rr.Code)
	}
	if got := teamsOfApp(t, h, appID); containsStr(got, "banking-demo") {
		t.Errorf("teams = %v : l'assignation a pris effet SANS assetType", got)
	}

	// Avec assetType Application : la team est posée, Default part — relu sur
	// l'objet ET sur la liste (le rôle relit l'objet ; verify relit la liste).
	rr = doAdmin(t, h, "POST", "/rest/apigateway/assets/team", map[string]any{
		"assetIds": []string{appID}, "assetType": "Application", "newTeams": []string{profID},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("assignation Application = %d body=%s", rr.Code, rr.Body)
	}
	for what, got := range map[string][]string{"objet": teamsOfApp(t, h, appID), "liste": teamsOfAppInList(t, h, appID)} {
		if !containsStr(got, "banking-demo") {
			t.Errorf("teams (%s) = %v, attendu banking-demo présente", what, got)
		}
		if containsStr(got, "Default") {
			t.Errorf("teams (%s) = %v : Default doit PARTIR dès qu'une équipe est posée", what, got)
		}
		if !containsStr(got, "Administrators") {
			t.Errorf("teams (%s) = %v : Administrators est conservée (mesuré sur le produit)", what, got)
		}
	}

	// Un PUT de convergence sans `teams` (le rôle peut en émettre) les CONSERVE,
	// comme consumingAPIs — le produit ne les édite pas par PUT.
	rr = doAdmin(t, h, "PUT", "/rest/apigateway/applications/"+appID, map[string]any{"name": "a7-app", "identifiers": []any{}})
	if rr.Code != http.StatusOK {
		t.Fatalf("PUT application = %d body=%s", rr.Code, rr.Body)
	}
	if got := teamsOfApp(t, h, appID); !containsStr(got, "banking-demo") || containsStr(got, "Default") {
		t.Errorf("teams après PUT sans teams = %v : elles devaient être conservées", got)
	}
}
