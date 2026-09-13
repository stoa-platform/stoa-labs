package main

import (
	"net/http"
	"testing"
)

// Le produit réel rend `apiResponse.api.apiDefinition` sur GET /apis/{id} — c'est
// le SEUL porteur du tag de posture (P3/ADR-093 : `apiDefinition.tags`, relu
// fail-closed par apim_publish_api/tasks/tag.yml:92/156). Tant que le mock ne le
// rendait pas, la publication mourait `TAG_UNCONFIRMED` sur le mock et jamais sur
// le produit : une infidélité qui a coûté huit preuves SKIP à la matrice GitLab
// (2026-09-12). Ces épreuves fixent le contrat : ce qui est importé ou ré-importé
// dans `apiDefinition` se relit dans l'enveloppe admin, sur GET et sur la liste.

func withTags(body map[string]any, tags ...string) map[string]any {
	def := body["apiDefinition"].(map[string]any)
	out := make([]any, 0, len(tags))
	for _, t := range tags {
		out = append(out, map[string]any{"name": t})
	}
	def["tags"] = out
	return body
}

func definitionOf(t *testing.T, env map[string]any) map[string]any {
	t.Helper()
	api, _ := env["api"].(map[string]any)
	def, ok := api["apiDefinition"].(map[string]any)
	if !ok {
		t.Fatalf("apiResponse.api ne porte pas apiDefinition : %v", api)
	}
	return def
}

func tagNames(t *testing.T, def map[string]any) []string {
	t.Helper()
	raw, _ := def["tags"].([]any)
	names := make([]string, 0, len(raw))
	for _, x := range raw {
		m, _ := x.(map[string]any)
		n, _ := m["name"].(string)
		names = append(names, n)
	}
	return names
}

func TestGetAPIReturnsAPIDefinitionWithTags(t *testing.T) {
	h := newTestServer(t)
	rr := doAdmin(t, h, "POST", "/rest/apigateway/apis", withTags(importBody("tags-api", "1.0.0"), "posture:internal"))
	if rr.Code != http.StatusCreated {
		t.Fatalf("import code = %d body=%s", rr.Code, rr.Body)
	}
	id := decode(t, rr)["apiResponse"].(map[string]any)["api"].(map[string]any)["id"].(string)

	got := doAdmin(t, h, "GET", "/rest/apigateway/apis/"+id, nil)
	if got.Code != http.StatusOK {
		t.Fatalf("GET code = %d body=%s", got.Code, got.Body)
	}
	def := definitionOf(t, decode(t, got)["apiResponse"].(map[string]any))
	if names := tagNames(t, def); len(names) != 1 || names[0] != "posture:internal" {
		t.Fatalf("GET apiDefinition.tags = %v, attendu [posture:internal]", names)
	}
	if _, ok := def["paths"].(map[string]any); !ok {
		t.Fatalf("GET apiDefinition ne porte pas paths : %v", def)
	}
}

func TestReimportTagsAreReadBack(t *testing.T) {
	h := newTestServer(t)
	rr := doAdmin(t, h, "POST", "/rest/apigateway/apis", importBody("retag-api", "1.0.0"))
	if rr.Code != http.StatusCreated {
		t.Fatalf("import code = %d body=%s", rr.Code, rr.Body)
	}
	id := decode(t, rr)["apiResponse"].(map[string]any)["api"].(map[string]any)["id"].(string)

	// Le geste de tag.yml : relire, fusionner apiDefinition.tags, PUT plat (API inactive), relire.
	put := doAdmin(t, h, "PUT", "/rest/apigateway/apis/"+id,
		map[string]any{"apiVersion": "1.0.0", "apiDefinition": withTags(importBody("retag-api", "1.0.0"), "posture:partner", "domaine:paiement")["apiDefinition"]})
	if put.Code != http.StatusOK {
		t.Fatalf("PUT code = %d body=%s", put.Code, put.Body)
	}
	got := doAdmin(t, h, "GET", "/rest/apigateway/apis/"+id, nil)
	names := tagNames(t, definitionOf(t, decode(t, got)["apiResponse"].(map[string]any)))
	if len(names) != 2 || names[0] != "posture:partner" || names[1] != "domaine:paiement" {
		t.Fatalf("après PUT, apiDefinition.tags = %v, attendu [posture:partner domaine:paiement]", names)
	}
}

func TestListAPIsCarriesAPIDefinition(t *testing.T) {
	h := newTestServer(t)
	rr := doAdmin(t, h, "POST", "/rest/apigateway/apis", withTags(importBody("listed-api", "1.0.0"), "posture:internal"))
	if rr.Code != http.StatusCreated {
		t.Fatalf("import code = %d body=%s", rr.Code, rr.Body)
	}
	list := doAdmin(t, h, "GET", "/rest/apigateway/apis", nil)
	items, _ := decode(t, list)["apiResponse"].([]any)
	if len(items) == 0 {
		t.Fatalf("liste vide : %s", list.Body)
	}
	found := false
	for _, it := range items {
		env, _ := it.(map[string]any)
		api, _ := env["api"].(map[string]any)
		if api["apiName"] == "listed-api" {
			found = true
			if _, ok := api["apiDefinition"].(map[string]any); !ok {
				t.Fatalf("la liste ne porte pas apiDefinition pour listed-api : %v", api)
			}
		}
	}
	if !found {
		t.Fatalf("listed-api absente de la liste")
	}
}
