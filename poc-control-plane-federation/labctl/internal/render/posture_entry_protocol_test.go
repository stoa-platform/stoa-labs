package render

import "testing"

// Jalon P5 (ADR-095) — le protocole d'entrée, par API.
//
// Ce que ces épreuves tiennent : le protocole à poser sur l'API est DÉRIVÉ de
// la moitié per-API du bouquet, jamais réaffirmé à côté d'elle ; il vaut
// exactement le vocabulaire du produit ; et il est présent partout où
// `https-only` l'est — c'est-à-dire, depuis le plancher de P1, dans toutes les
// cellules nommées.

// TestEntryProtocolFollowsTheHalfThatOwnsIt est l'épreuve que P4 a explicitement
// demandé d'écrire : elle rend MÉCANIQUE le couplage entre « qui applique
// https-only » et « qui le vérifie ».
//
// P4 a mesuré que `https-only` est portable par la global policy d'une cellule
// et l'a laissée per-API parce que P1 la vérifie au read-back sur le
// transportProtocol de l'API. Le risque de cette décision est qu'elle se
// défasse par inadvertance : quelqu'un ajoute `https-only` à `commonCarriable`,
// l'application part vers l'objet partagé — et le rôle continue de poser le
// protocole sur l'API, ou cesse de le poser sans que la vérification suive.
// Cette épreuve interdit les deux dérives : `EntryProtocol` non vide SI ET
// SEULEMENT SI `https-only` est dans la moitié per-API.
func TestEntryProtocolFollowsTheHalfThatOwnsIt(t *testing.T) {
	for bundle, in := range derivableCells(t) {
		res, err := Derive(in)
		if err != nil {
			t.Fatalf("%s : %v", bundle, err)
		}
		perAPI := contains(res.PerAPIPolicies, PolicyHTTPSOnly)
		common := contains(res.CommonPolicies, PolicyHTTPSOnly)
		switch {
		case perAPI && res.EntryProtocol == "":
			t.Errorf("%s : https-only est per-API mais aucun protocole d'entrée n'est dérivé — le rôle ne poserait RIEN sur l'API que P1 relit", bundle)
		case !perAPI && res.EntryProtocol != "":
			t.Errorf("%s : protocole d'entrée %q dérivé alors que https-only n'est pas dans la moitié per-API (%v)", bundle, res.EntryProtocol, res.PerAPIPolicies)
		case common && res.EntryProtocol != "":
			t.Errorf("%s : https-only est passée du côté COMMUN et le protocole est TOUJOURS posé sur l'API — l'application serait double et la vérification ne dirait plus laquelle mord", bundle)
		}
	}
}

// TestEntryProtocolIsTheProductVocabulary : la valeur part telle quelle dans le
// paramètre `protocol` de l'action entryProtocolPolicy. Une casse ou un synonyme
// (« HTTPS », « tls ») serait accepté par la gateway avec un 200 puis relu
// autrement — la classe de faux vert que ce projet paie depuis P0.
func TestEntryProtocolIsTheProductVocabulary(t *testing.T) {
	if EntryProtocolHTTPS != "https" {
		t.Fatalf("EntryProtocolHTTPS = %q ; le produit lit exactement \"https\" (mesuré, spike P5 S4)", EntryProtocolHTTPS)
	}
	res, err := Derive(Input{Classification: ClassificationVH, Exposure: ExposureInternet})
	if err != nil {
		t.Fatal(err)
	}
	if res.EntryProtocol != EntryProtocolHTTPS {
		t.Errorf("vh-internet : protocole d'entrée %q, attendu %q", res.EntryProtocol, EntryProtocolHTTPS)
	}
}

// TestEveryNamedCellPinsHTTPS : `https-only` est un PLANCHER depuis P1, donc
// aucune cellule ne doit sortir de Derive sans protocole d'entrée. Une cellule
// qui en manquerait publierait une API joignable en clair tout en affichant un
// tag de posture gouvernée — exactement la garantie de papier que P0 a démontée.
func TestEveryNamedCellPinsHTTPS(t *testing.T) {
	for bundle, in := range derivableCells(t) {
		res, _ := Derive(in)
		if res.EntryProtocol != EntryProtocolHTTPS {
			t.Errorf("cellule %q : protocole d'entrée %q — https-only est pourtant un plancher de toutes les cases (ADR-091)", bundle, res.EntryProtocol)
		}
	}
}

// TestEntryProtocolForIsFailClosedOnAnEmptyHalf : la fonction ne devine pas.
// Une moitié per-API vide (ou qui ne nomme pas https-only) rend "" — et le rôle
// traite "" comme « ne rien poser », pas comme « poser le défaut ». Sans cette
// épreuve, une implémentation qui rendrait toujours "https" passerait les
// autres tests, puisque toutes les cellules réelles l'exigent.
func TestEntryProtocolForIsFailClosedOnAnEmptyHalf(t *testing.T) {
	if got := EntryProtocolFor(nil); got != "" {
		t.Errorf("EntryProtocolFor(nil) = %q, attendu \"\"", got)
	}
	if got := EntryProtocolFor([]string{PolicyOAuth2, PolicyRateLimit}); got != "" {
		t.Errorf("EntryProtocolFor(sans https-only) = %q, attendu \"\"", got)
	}
	if got := EntryProtocolFor([]string{PolicyOAuth2, PolicyHTTPSOnly}); got != EntryProtocolHTTPS {
		t.Errorf("EntryProtocolFor(avec https-only) = %q, attendu %q", got, EntryProtocolHTTPS)
	}
}
