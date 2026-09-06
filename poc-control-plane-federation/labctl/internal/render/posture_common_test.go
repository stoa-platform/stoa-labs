package render

import (
	"fmt"
	"testing"
)

// Jalon P4 (ADR-094) — le bouquet COMMUN et son quota.
//
// Ce que ces épreuves tiennent, et qu'aucune relecture ne tient : la table de
// vérité ne peut plus gagner une cellule sans que quelqu'un décide son quota ;
// la coupure entre « ce qu'un objet partagé porte » et « ce qui reste sur
// l'API » est mécanique et exhaustive ; et deux cellules de niveaux différents
// portent des bouquets communs DIFFÉRENTS — la prémisse même de la porte du
// jalon, mesurée côté plan de données par le harnais.

// derivableCells énumère les cellules que Derive peut réellement produire, en
// passant par Derive lui-même plutôt qu'en recopiant bundleNames : une cellule
// qui n'est atteignable par aucune entrée ne serait pas gouvernée, elle serait
// morte.
func derivableCells(t *testing.T) map[string]Input {
	t.Helper()
	out := map[string]Input{}
	for _, c := range Classifications() {
		for _, e := range Exposures() {
			in := Input{Classification: c, Exposure: e}
			res, err := Derive(in)
			if err != nil {
				t.Fatalf("Derive(%s,%s) refusée alors que la cellule est nommée : %v", c, e, err)
			}
			out[res.Bundle] = in
		}
	}
	in := Input{Classification: ClassificationM, Exposure: ExposureInternal, Tags: []string{AuthExceptionApiKey}}
	res, err := Derive(in)
	if err != nil {
		t.Fatalf("Derive de la cellule d'exception refusée : %v", err)
	}
	out[res.Bundle] = in
	return out
}

// TestEveryNamedCellHasAGovernedQuota est la garde d'extension : ajouter une
// valeur à l'un des deux axes force à décider le quota de chaque cellule neuve,
// au lieu de lui en faire hériter un en silence. Symétrique de la garde de P1
// « une case sans nom est un refus ».
func TestEveryNamedCellHasAGovernedQuota(t *testing.T) {
	cells := derivableCells(t)
	for bundle := range cells {
		q, ok := QuotaFor(bundle)
		if !ok {
			t.Errorf("cellule %q dérivable mais SANS quota gouverné", bundle)
			continue
		}
		if q.Requests <= 0 || q.Interval <= 0 || q.Unit == "" {
			t.Errorf("cellule %q : quota incomplet %+v", bundle, q)
		}
	}
	// L'inverse : pas de quota orphelin. Une ligne de la table des quotas qui ne
	// correspond à aucune cellule dérivable serait une décision prise pour une
	// posture que personne ne peut demander — donc un leurre à l'audit.
	for _, bundle := range Cells() {
		if _, ok := cells[bundle]; !ok {
			t.Errorf("quota gouverné pour %q, qui n'est dérivable par aucune entrée", bundle)
		}
	}
}

// TestCellWithoutQuotaIsRefused prouve que la garde est FERMÉE, pas décorative :
// on retire à chaud le quota d'une cellule et Derive doit refuser. Sans cette
// épreuve, la branche d'erreur ne serait atteinte par aucune entrée et pourrait
// être supprimée sans qu'un test ne bouge.
func TestCellWithoutQuotaIsRefused(t *testing.T) {
	const victim = "h-external"
	saved, ok := bundleQuotas[victim]
	if !ok {
		t.Fatalf("la cellule témoin %q n'a pas de quota — l'épreuve ne mesure rien", victim)
	}
	delete(bundleQuotas, victim)
	defer func() { bundleQuotas[victim] = saved }()

	if _, err := Derive(Input{Classification: ClassificationH, Exposure: ExposureExternal}); err == nil {
		t.Fatalf("une cellule sans quota gouverné a été DÉRIVÉE : `%s` serait un mot, pas un contrôle", PolicyRateLimit)
	}
}

// TestBundleSplitIsExhaustiveAndDisjoint : la coupure ne perd rien et ne compte
// rien deux fois. C'est ce qui autorise le rôle à ne poser que la moitié
// per-API en sachant que l'autre moitié est portée ailleurs — s'il en manquait
// une, une policy du bouquet ne serait appliquée par personne.
func TestBundleSplitIsExhaustiveAndDisjoint(t *testing.T) {
	for bundle, in := range derivableCells(t) {
		res, err := Derive(in)
		if err != nil {
			t.Fatalf("%s : %v", bundle, err)
		}
		seen := map[string]int{}
		for _, p := range res.CommonPolicies {
			seen[p]++
		}
		for _, p := range res.PerAPIPolicies {
			seen[p]++
		}
		for _, p := range res.RequiredPolicies {
			switch seen[p] {
			case 0:
				t.Errorf("%s : la policy %q du bouquet n'est ni commune ni per-API — personne ne la pose", bundle, p)
			case 1: // bien
			default:
				t.Errorf("%s : la policy %q est des DEUX côtés de la coupure", bundle, p)
			}
			delete(seen, p)
		}
		for p := range seen {
			t.Errorf("%s : la coupure invente la policy %q, absente du bouquet", bundle, p)
		}
	}
}

// TestCommonHalfIsExactlyWhatTheGatewayWasMeasuredToCarry épingle la liste aux
// mesures du spike P4 (2026-09-05, wM 10.15 réelle) ET à l'arbitrage qui les
// accompagne. `threat-protection` est per-API parce que /policies REFUSE son
// stage (HTTP 400 NullPointerException, deux filtres, deux portées) ;
// `ip-allowlist` parce qu'aucune surface de policy ne l'exprime ; `https-only`
// parce que P5 possède l'axe HTTPS et que P1 le vérifie déjà sur l'API
// elle-même — celle-là est portable, et laissée dehors exprès. Le jour où l'un
// des trois change de côté, c'est ICI que la décision se prend.
func TestCommonHalfIsExactlyWhatTheGatewayWasMeasuredToCarry(t *testing.T) {
	carriable := map[string]bool{PolicyAuditLog: true, PolicyRateLimit: true}
	for bundle, in := range derivableCells(t) {
		res, _ := Derive(in)
		for _, p := range res.CommonPolicies {
			if !carriable[p] {
				t.Errorf("%s : %q est annoncée COMMUNE alors qu'aucune mesure ne l'a portée en global policy", bundle, p)
			}
		}
		for _, p := range res.PerAPIPolicies {
			if carriable[p] {
				t.Errorf("%s : %q est mesurée portable en global policy mais reste per-API", bundle, p)
			}
		}
	}
	// Les deux exclusions nommées, vérifiées là où elles apparaissent.
	res, _ := Derive(Input{Classification: ClassificationM, Exposure: ExposureInternet})
	if !contains(res.PerAPIPolicies, PolicyThreatProtection) {
		t.Errorf("m-internet : threat-protection devrait rester per-API (stage refusé par /policies, spike S4)")
	}
	res, _ = Derive(Input{Classification: ClassificationM, Exposure: ExposureExternal})
	if !contains(res.PerAPIPolicies, PolicyIPAllowlist) {
		t.Errorf("m-external : ip-allowlist devrait rester per-API (aucune surface de policy)")
	}
	// https-only : MESURÉE portable en global policy (spike S5) et laissée
	// per-API tout de même — l'arbitrage P4/P5 que le GOAL laissait ouvert.
	// Cette assertion existe pour que le jour où quelqu'un la déplace, il le
	// fasse en connaissance de cause et déplace la VÉRIFICATION avec.
	res, _ = Derive(Input{Classification: ClassificationVH, Exposure: ExposureInternal})
	if !contains(res.PerAPIPolicies, PolicyHTTPSOnly) {
		t.Errorf("vh-internal : https-only doit rester per-API tant que verifyHTTPSOnly relit le transportProtocol de l'API (P5 possède l'axe)")
	}
}

// TestTwoLevelsCarryDifferentCommonBundles est la PRÉMISSE de la porte du jalon
// (« deux APIs de niveaux différents, deux bouquets communs différents, mesurés
// côté plan de données »). Comme l'ENSEMBLE des policies communes est le même
// partout — les deux sont un plancher depuis P1 — la seule chose qui peut
// différer est le quota. Si cette épreuve tombe, la porte du jalon n'est plus
// mesurable et il faut le dire, pas la contourner.
func TestTwoLevelsCarryDifferentCommonBundles(t *testing.T) {
	vh, err := Derive(Input{Classification: ClassificationVH, Exposure: ExposureInternal})
	if err != nil {
		t.Fatal(err)
	}
	m, err := Derive(Input{Classification: ClassificationM, Exposure: ExposureInternal})
	if err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(vh.CommonPolicies) != fmt.Sprint(m.CommonPolicies) {
		t.Fatalf("hypothèse cassée : les ENSEMBLES diffèrent (%v vs %v) — l'épreuve doit alors mesurer autre chose que le quota",
			vh.CommonPolicies, m.CommonPolicies)
	}
	if vh.Quota == m.Quota {
		t.Errorf("vh-internal et m-internal portent le MÊME quota %+v : rien ne distingue leurs bouquets communs au plan de données",
			vh.Quota)
	}
	// Et l'ordre annoncé dans la table : à exposition égale, plus l'enjeu
	// d'intégrité est haut, moins la rafale a de place.
	if !(vh.Quota.Requests < m.Quota.Requests) {
		t.Errorf("VH (%d) devrait être plus serré que M (%d) à exposition égale", vh.Quota.Requests, m.Quota.Requests)
	}
	// À intégrité égale, plus la population d'appelants s'élargit, plus le quota
	// se resserre — l'axe d'exposition, qui n'est pas une échelle de sécurité,
	// EST une échelle de population d'appelants.
	var prev int
	for i, e := range Exposures() {
		r, err := Derive(Input{Classification: ClassificationH, Exposure: e})
		if err != nil {
			t.Fatal(err)
		}
		if i > 0 && r.Quota.Requests >= prev {
			t.Errorf("h-%s : quota %d, pas plus serré que l'exposition précédente (%d)", e, r.Quota.Requests, prev)
		}
		prev = r.Quota.Requests
	}
}

// TestPolicyNameAndSentinelAreComposedHere : le nom de l'objet et la sentinelle
// arrivent FINIS aux appelants, comme le tag de P3. Un rôle Ansible qui
// concaténerait « posture- » + bouquet serait une cinquième recopie de
// vocabulaire, et une sentinelle recopiée à la main est une sentinelle qu'un
// jour quelqu'un écrit de travers — auquel cas la policy de la cellule cesse
// d'être bornée et frappe TOUTES les APIs (mesuré, spike S7).
func TestPolicyNameAndSentinelAreComposedHere(t *testing.T) {
	for _, bundle := range Cells() {
		if got, want := PosturePolicyName(bundle), PosturePolicyPrefix+bundle; got != want {
			t.Errorf("PosturePolicyName(%q) = %q, attendu %q", bundle, got, want)
		}
	}
	if PostureMemberSentinel == "" {
		t.Fatal("la sentinelle est vide — une condition API sans attribut sélectionne TOUTES les APIs (spike S7)")
	}
	// La sentinelle ne doit ressembler à aucun nom d'API plausible : c'est tout
	// ce qui la rend sûre.
	for _, bad := range []string{"", "default", "api", "*"} {
		if PostureMemberSentinel == bad {
			t.Errorf("sentinelle %q : un nom qu'une API pourrait porter", bad)
		}
	}
}

func contains(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}
