package render

import "testing"

// Jalon P6 (ADR-096) — le refus par défaut, sur la surface qui garde le dispatch.
//
// Ce que ces épreuves tiennent : la dimension d'identification à exiger sur
// l'API est DÉRIVÉE de la moitié per-API du bouquet ; elle vaut exactement le
// vocabulaire du produit ; et elle apparaît dans les cellules `external` et
// SEULEMENT là — parce que c'est `external` qui exige l'ip-allowlist (ADR-091),
// `internet` la REMPLAÇANT par threat-protection (l'appelant public n'est pas
// énumérable) et `internal` n'en demandant aucune.

// TestCallerIdentityFollowsTheHalfThatOwnsIt est la jumelle de
// TestEntryProtocolFollowsTheHalfThatOwnsIt, et elle existe pour la même raison.
//
// `ip-allowlist` est aujourd'hui dans la moitié PER-API parce que la gateway
// n'offre AUCUNE surface partagée pour elle (P4 l'a mesuré, commonCarriable le
// consigne). Le jour où quelqu'un l'y déplacerait, la dimension cesserait d'être
// dérivée, le rôle cesserait de la poser — et il faut que ce soit MÉCANIQUE,
// pas silencieux : sinon l'application partirait d'un côté pendant que
// verifyIPAllowlist continuerait de relire l'action IAM de l'API, et le contrôle
// cesserait discrètement d'être vérifié. C'est exactement la dérive que P5 a
// nommée et refusé de laisser possible.
func TestCallerIdentityFollowsTheHalfThatOwnsIt(t *testing.T) {
	for bundle, in := range derivableCells(t) {
		res, err := Derive(in)
		if err != nil {
			t.Fatalf("%s : %v", bundle, err)
		}
		perAPI := contains(res.PerAPIPolicies, PolicyIPAllowlist)
		common := contains(res.CommonPolicies, PolicyIPAllowlist)
		has := contains(res.CallerIdentity, IdentificationIPRange)
		switch {
		case perAPI && !has:
			t.Errorf("%s : ip-allowlist est per-API mais aucune dimension d'identification n'est dérivée — le rôle ne poserait RIEN, et l'allow-list des applications n'opposerait rien (fail-open ADR-078)", bundle)
		case !perAPI && has:
			t.Errorf("%s : dimension %q dérivée alors qu'ip-allowlist n'est pas dans la moitié per-API (%v)", bundle, IdentificationIPRange, res.PerAPIPolicies)
		case common && has:
			t.Errorf("%s : ip-allowlist est passée du côté COMMUN et la dimension est TOUJOURS posée sur l'API — l'application serait double et la vérification ne dirait plus laquelle mord", bundle)
		}
	}
}

// TestCallerIdentityIsExactlyTheExternalCells : la dimension réseau est la règle
// PROPRE d'`external`, et d'elle seule. Cette épreuve interdit les deux erreurs
// symétriques : l'oublier sur `external` (le contrôle disparaît), et l'ajouter
// sur `internet` (où ADR-091 la remplace par threat-protection, précisément
// parce que l'appelant public n'est pas énumérable — une allow-list y serait
// soit vide, soit un joker, et le spike P6 S3 a mesuré qu'un joker
// 0.0.0.0-255.255.255.255 n'identifie PERSONNE : 403).
func TestCallerIdentityIsExactlyTheExternalCells(t *testing.T) {
	for bundle, in := range derivableCells(t) {
		res, _ := Derive(in)
		want := in.Exposure == ExposureExternal
		got := contains(res.CallerIdentity, IdentificationIPRange)
		if want != got {
			t.Errorf("cellule %q (exposure=%s) : dimension réseau posée=%v, attendu %v — la règle propre d'external est l'ip-allowlist (ADR-091)",
				bundle, in.Exposure, got, want)
		}
	}
}

// TestCallerIdentityIsTheProductVocabulary : la valeur part telle quelle dans le
// paramètre `identificationType` de la règle. Un synonyme (« ipRange »,
// « ipAddress ») serait accepté à l'écriture puis n'identifierait jamais
// personne — un contrôle posé, relu, et inerte : le vert vacant que ce GOAL
// traque depuis P0.
func TestCallerIdentityIsTheProductVocabulary(t *testing.T) {
	if IdentificationIPRange != "ipAddressRange" {
		t.Fatalf("IdentificationIPRange = %q ; le produit lit exactement \"ipAddressRange\" (énum mesurée, ADR-071/078 et spike P6 S3)", IdentificationIPRange)
	}
}

// TestCallerIdentityForIsFailClosedOnAnEmptyHalf : la fonction ne devine pas.
// Une moitié per-API vide rend nil — et le rôle traite nil comme « ne rien
// exiger », pas comme « exiger le défaut ». Sans cette épreuve, une
// implémentation qui rendrait toujours la dimension passerait les autres, et
// toute API internal deviendrait injoignable sans qu'aucune épreuve ne le dise.
func TestCallerIdentityForIsFailClosedOnAnEmptyHalf(t *testing.T) {
	if got := CallerIdentityFor(nil); len(got) != 0 {
		t.Errorf("CallerIdentityFor(nil) = %v, attendu vide", got)
	}
	if got := CallerIdentityFor([]string{PolicyOAuth2, PolicyHTTPSOnly}); len(got) != 0 {
		t.Errorf("CallerIdentityFor(sans ip-allowlist) = %v, attendu vide", got)
	}
	got := CallerIdentityFor([]string{PolicyOAuth2, PolicyIPAllowlist})
	if len(got) != 1 || got[0] != IdentificationIPRange {
		t.Errorf("CallerIdentityFor(avec ip-allowlist) = %v, attendu [%s]", got, IdentificationIPRange)
	}
}
