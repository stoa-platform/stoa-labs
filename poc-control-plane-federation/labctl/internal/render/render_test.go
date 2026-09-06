package render

import (
	"reflect"
	"strings"
	"testing"
)

// TestTruthTable is the P1 gate: the COMPLETE exposure x classification matrix,
// every cell asserted by its NAME and by the EXACT policy set it produces.
// Exactness is the point — a "contains" assertion would not catch an
// ip-allowlist leaking into an internet cell, which is precisely the mistake
// this jalon exists to make impossible.
func TestTruthTable(t *testing.T) {
	cases := []struct {
		in         Input
		wantBundle string
		wantAuthn  string
		want       []string // EXACT sorted policy set
	}{
		// --- internal: the exposure axis adds nothing -----------------------
		{Input{Classification: "VH", Exposure: "internal"}, "vh-internal", "oauth2+mtls",
			[]string{"audit-log", "https-only", "mtls", "oauth2", "rate-limit"}},
		{Input{Classification: "H", Exposure: "internal"}, "h-internal", "oauth2",
			[]string{"audit-log", "https-only", "oauth2", "rate-limit"}},
		{Input{Classification: "M", Exposure: "internal"}, "m-internal", "oauth2",
			[]string{"audit-log", "https-only", "oauth2", "rate-limit"}},

		// --- external: partner, source IPs ARE enumerable -> ip-allowlist ---
		{Input{Classification: "VH", Exposure: "external"}, "vh-external", "oauth2+mtls",
			[]string{"audit-log", "https-only", "ip-allowlist", "mtls", "oauth2", "rate-limit"}},
		{Input{Classification: "H", Exposure: "external"}, "h-external", "oauth2",
			[]string{"audit-log", "https-only", "ip-allowlist", "oauth2", "rate-limit"}},
		{Input{Classification: "M", Exposure: "external"}, "m-external", "oauth2",
			[]string{"audit-log", "https-only", "ip-allowlist", "oauth2", "rate-limit"}},

		// --- internet: public, NOT enumerable -> threat-protection, and the
		// ip-allowlist is REPLACED, never added. VH stays reachable here: the
		// certificate is distributable to a public caller even when its IP is
		// not (eIDAS/QWAC model, client decision 2026-09-04).
		{Input{Classification: "VH", Exposure: "internet"}, "vh-internet", "oauth2+mtls",
			[]string{"audit-log", "https-only", "mtls", "oauth2", "rate-limit", "threat-protection"}},
		{Input{Classification: "H", Exposure: "internet"}, "h-internet", "oauth2",
			[]string{"audit-log", "https-only", "oauth2", "rate-limit", "threat-protection"}},
		{Input{Classification: "M", Exposure: "internet"}, "m-internet", "oauth2",
			[]string{"audit-log", "https-only", "oauth2", "rate-limit", "threat-protection"}},

		// --- the single governed exception cell -----------------------------
		{Input{Classification: "M", Exposure: "internal", Tags: []string{AuthExceptionApiKey}}, "m-internal-apikey", "apikey",
			[]string{"apikey", "audit-log", "https-only", "rate-limit"}},

		// --- the default is internal, and it is the SAME cell ----------------
		{Input{Classification: "H"}, "h-internal", "oauth2",
			[]string{"audit-log", "https-only", "oauth2", "rate-limit"}},
	}

	seen := map[string]bool{}
	for _, tc := range cases {
		name := tc.wantBundle
		if tc.in.Exposure == "" {
			name += "/exposure-absente"
		}
		t.Run(name, func(t *testing.T) {
			res, err := Derive(tc.in)
			if err != nil {
				t.Fatalf("Derive(%+v) = erreur %v, attendu un bouquet", tc.in, err)
			}
			if res.Bundle != tc.wantBundle {
				t.Errorf("bundle = %q, want %q", res.Bundle, tc.wantBundle)
			}
			if res.Authn != tc.wantAuthn {
				t.Errorf("authn = %q, want %q", res.Authn, tc.wantAuthn)
			}
			if !reflect.DeepEqual(res.RequiredPolicies, tc.want) {
				t.Errorf("required_policies = %v, want EXACTEMENT %v", res.RequiredPolicies, tc.want)
			}
		})
		seen[tc.wantBundle] = true
	}

	// Every named cell of the table must be covered by a case above: a cell
	// added without a test would otherwise ship underived and unmeasured.
	for class, byExposure := range bundleNames {
		for exposure, bundle := range byExposure {
			if !seen[bundle] {
				t.Errorf("cellule %s/%s (%q) présente dans la table de vérité mais NON couverte par un cas de test", class, exposure, bundle)
			}
		}
	}
}

// TestFloorPoliciesEverywhere pins the invariant separately from the table, so
// removing a floor policy fails HERE with an unambiguous message rather than
// only as nine confusing set mismatches.
func TestFloorPoliciesEverywhere(t *testing.T) {
	for _, class := range Classifications() {
		for _, exposure := range Exposures() {
			res, err := Derive(Input{Classification: class, Exposure: exposure})
			if err != nil {
				t.Fatalf("%s/%s: %v", class, exposure, err)
			}
			have := map[string]bool{}
			for _, p := range res.RequiredPolicies {
				have[p] = true
			}
			for _, floor := range floorPolicies {
				if !have[floor] {
					t.Errorf("%s/%s: policy plancher %q absente de %v", class, exposure, floor, res.RequiredPolicies)
				}
			}
		}
	}
}

// TestIPAllowlistIsExternalOnly states the load-bearing consequence of the
// internet value in one place: a public caller is not enumerable, so an
// ip-allowlist there would be either impossible or a 0.0.0.0/0 fiction that
// satisfies the gate while protecting nothing.
func TestIPAllowlistIsExternalOnly(t *testing.T) {
	for _, class := range Classifications() {
		for _, exposure := range Exposures() {
			res, err := Derive(Input{Classification: class, Exposure: exposure})
			if err != nil {
				t.Fatalf("%s/%s: %v", class, exposure, err)
			}
			has := func(p string) bool {
				for _, x := range res.RequiredPolicies {
					if x == p {
						return true
					}
				}
				return false
			}
			if want := exposure == ExposureExternal; has(PolicyIPAllowlist) != want {
				t.Errorf("%s/%s: ip-allowlist présent=%v, attendu %v", class, exposure, has(PolicyIPAllowlist), want)
			}
			if want := exposure == ExposureInternet; has(PolicyThreatProtection) != want {
				t.Errorf("%s/%s: threat-protection présent=%v, attendu %v", class, exposure, has(PolicyThreatProtection), want)
			}
		}
	}
}

// TestDeriveRefusals is the contre-épreuve: every combination that is not
// governed must be REFUSED, never silently defaulted.
func TestDeriveRefusals(t *testing.T) {
	cases := []struct {
		name    string
		in      Input
		wantErr string // substring
	}{
		{"classification inconnue", Input{Classification: "VVH"}, "inconnue"},
		{"classification vide", Input{Classification: ""}, "inconnue"},
		{"classification en minuscules", Input{Classification: "vh", Exposure: "internal"}, "inconnue"},
		{"exposure inconnue", Input{Classification: "H", Exposure: "public"}, "exposure"},
		{"exposure OWASP non transposée", Input{Classification: "H", Exposure: "partners"}, "exposure"},
		{"exposure en majuscules", Input{Classification: "H", Exposure: "INTERNET"}, "exposure"},
		{"apikey sur VH", Input{Classification: "VH", Exposure: "internal", Tags: []string{AuthExceptionApiKey}}, "uniquement M"},
		{"apikey sur H", Input{Classification: "H", Exposure: "internal", Tags: []string{AuthExceptionApiKey}}, "uniquement M"},
		{"apikey en external", Input{Classification: "M", Exposure: "external", Tags: []string{AuthExceptionApiKey}}, "uniquement internal"},
		{"apikey en internet", Input{Classification: "M", Exposure: "internet", Tags: []string{AuthExceptionApiKey}}, "uniquement internal"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			res, err := Derive(tc.in)
			if err == nil {
				t.Fatalf("attendu un refus contenant %q, obtenu nil (res=%+v)", tc.wantErr, res)
			}
			if !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("refus %q ne contient pas %q", err.Error(), tc.wantErr)
			}
		})
	}
}

// TestUngovernedCellIsRefused proves the refusal MECHANICALLY, by mutation:
// a vocabulary value that is valid on both axes but whose cell carries no name
// must be refused, not given a posture nobody arbitrated. Without this test the
// guard is a branch no input can reach, i.e. an unproven claim.
func TestUngovernedCellIsRefused(t *testing.T) {
	saved := bundleNames[ClassificationM][ExposureInternet]
	delete(bundleNames[ClassificationM], ExposureInternet)
	defer func() { bundleNames[ClassificationM][ExposureInternet] = saved }()

	res, err := Derive(Input{Classification: "M", Exposure: "internet"})
	if err == nil {
		t.Fatalf("cellule sans nom acceptée (res=%+v) — la garde ne mord pas", res)
	}
	if !strings.Contains(err.Error(), "non gouvernée") {
		t.Fatalf("refus %q ne nomme pas la cellule non gouvernée", err.Error())
	}
}

// TestWeakerRegression keeps the pre-P1 behaviour byte-for-byte: the anti-spoof
// gate of goal A5 must not have changed meaning on the two-value vocabulary.
func TestWeakerRegression(t *testing.T) {
	cases := []struct {
		class, exp, wClass, wExp string
		want                     bool
	}{
		{"M", "internal", "VH", "external", true},   // both weaker
		{"H", "internal", "VH", "external", true},   // class weaker
		{"VH", "internal", "VH", "external", true},  // exposure weaker (drops ip-allowlist)
		{"VH", "external", "VH", "external", false}, // equal
		{"VH", "external", "H", "internal", false},  // stronger (over-declaration)
		{"H", "external", "H", "external", false},   // equal
		{"M", "internal", "M", "internal", false},   // equal
		{"VH", "internal", "H", "internal", false},  // stronger class, same exposure
		{"H", "external", "H", "internal", false},   // over-exposed (not weaker)
	}
	for _, c := range cases {
		if got := Weaker(c.class, c.exp, c.wClass, c.wExp); got != c.want {
			t.Errorf("Weaker(%s/%s vs %s/%s) = %v, want %v", c.class, c.exp, c.wClass, c.wExp, got, c.want)
		}
	}
}

// TestWeakerExposureIsNotALadder is the P1 claim under test. Because internet
// REPLACES the ip-allowlist rather than adding to it, BOTH directions between
// external and internet drop a mandatory control — so no rank could express the
// comparison, and bundle containment is the only correct answer.
func TestWeakerExposureIsNotALadder(t *testing.T) {
	for _, class := range Classifications() {
		// external -> internet drops the ip-allowlist.
		if !Weaker(class, ExposureInternet, class, ExposureExternal) {
			t.Errorf("%s: déclarer internet quand le registre dit external n'est pas vu comme un affaiblissement (l'ip-allowlist disparaît)", class)
		}
		// internet -> external drops threat-protection.
		if !Weaker(class, ExposureExternal, class, ExposureInternet) {
			t.Errorf("%s: déclarer external quand le registre dit internet n'est pas vu comme un affaiblissement (threat-protection disparaît)", class)
		}
		// internal is weaker than both outward values.
		if !Weaker(class, ExposureInternal, class, ExposureExternal) {
			t.Errorf("%s: internal vs external gouverné devrait être plus faible", class)
		}
		if !Weaker(class, ExposureInternal, class, ExposureInternet) {
			t.Errorf("%s: internal vs internet gouverné devrait être plus faible", class)
		}
		// Over-declaring outward is harmless over-provisioning, never weaker.
		if Weaker(class, ExposureExternal, class, ExposureInternal) {
			t.Errorf("%s: sur-déclarer external quand le registre dit internal n'est pas un affaiblissement", class)
		}
		if Weaker(class, ExposureInternet, class, ExposureInternal) {
			t.Errorf("%s: sur-déclarer internet quand le registre dit internal n'est pas un affaiblissement", class)
		}
	}
}

// TestWeakerReflexive: no governed cell is ever weaker than itself — otherwise
// a compliant project would be accused of spoofing its own governed posture.
func TestWeakerReflexive(t *testing.T) {
	for _, class := range Classifications() {
		for _, exposure := range Exposures() {
			if Weaker(class, exposure, class, exposure) {
				t.Errorf("%s/%s est déclaré plus faible que lui-même", class, exposure)
			}
		}
	}
}

// TestWeakerClassificationLadder: integrity IS a ladder, and stays one even
// where two levels derive the same bundle (M and H both yield oauth2 today —
// containment alone would miss that downgrade, which is why the rank guard
// survives P1).
func TestWeakerClassificationLadder(t *testing.T) {
	for _, exposure := range Exposures() {
		if !Weaker("M", exposure, "H", exposure) {
			t.Errorf("%s: M déclaré contre H gouverné doit rester un affaiblissement, malgré un bouquet identique", exposure)
		}
		if !Weaker("H", exposure, "VH", exposure) {
			t.Errorf("%s: H déclaré contre VH gouverné doit être un affaiblissement", exposure)
		}
		if Weaker("VH", exposure, "M", exposure) {
			t.Errorf("%s: VH déclaré contre M gouverné est une sur-déclaration, pas un affaiblissement", exposure)
		}
	}
}

// TestWeakerFailsClosed: a posture that does not derive at all is weaker.
func TestWeakerFailsClosed(t *testing.T) {
	if !Weaker("H", "carrier-pigeon", "H", "internal") {
		t.Error("une exposure indérivable doit être traitée comme un affaiblissement (fail-closed)")
	}
	if !Weaker("H", "internal", "H", "carrier-pigeon") {
		t.Error("un niveau gouverné indérivable doit être traité comme un affaiblissement (fail-closed)")
	}
}

// TestVocabularyAccessors guards the exported vocabulary the rest of the
// codebase now depends on instead of carrying its own copy.
func TestVocabularyAccessors(t *testing.T) {
	if got := Exposures(); !reflect.DeepEqual(got, []string{"internal", "external", "internet"}) {
		t.Errorf("Exposures() = %v", got)
	}
	if got := Classifications(); !reflect.DeepEqual(got, []string{"VH", "H", "M"}) {
		t.Errorf("Classifications() = %v", got)
	}
	for _, e := range Exposures() {
		if !ValidExposure(e) {
			t.Errorf("ValidExposure(%q) = false", e)
		}
	}
	// The empty string defaults, it is NOT a member of the vocabulary: a caller
	// that means "absent" must say so through EffectiveExposure.
	if ValidExposure("") {
		t.Error(`ValidExposure("") = true — la chaîne vide n'est pas une valeur du vocabulaire`)
	}
	if EffectiveExposure("") != ExposureInternal {
		t.Error("EffectiveExposure(\"\") doit valoir internal")
	}
	if ValidClassification("") || ValidClassification("VVH") {
		t.Error("ValidClassification accepte une valeur hors vocabulaire")
	}
}

// ── P3 (ADR-093) : le tag que la plateforme pose sur l'objet gateway ─────────
//
// Le tag est le NOM de la cellule, dans un espace de noms que la plateforme
// possède. Ces épreuves tiennent les trois propriétés dont dépend le jalon :
// il est dérivé (pas choisi), il est reconnaissable à son préfixe, et il n'y en
// a QU'UN par cellule gouvernée.

func TestPostureTagIsTheNamedCellInsideTheReservedNamespace(t *testing.T) {
	for _, c := range Classifications() {
		for _, e := range Exposures() {
			res, err := Derive(Input{Classification: c, Exposure: e})
			if err != nil {
				t.Fatalf("Derive(%s,%s): %v", c, e, err)
			}
			tag := PostureTag(res.Bundle)
			if !strings.HasPrefix(tag, PostureTagPrefix) {
				t.Errorf("tag %q hors de l'espace de noms réservé %q", tag, PostureTagPrefix)
			}
			if strings.TrimPrefix(tag, PostureTagPrefix) != res.Bundle {
				t.Errorf("tag %q ne porte pas le bouquet nommé %q", tag, res.Bundle)
			}
		}
	}
}

// Deux cellules DIFFÉRENTES ne peuvent pas produire le même tag : sans quoi le
// tag ne dirait rien de la posture, et un downgrade deviendrait invisible sur
// l'objet gateway — précisément ce que ce jalon existe pour empêcher.
func TestPostureTagIsInjectiveOverTheTruthTable(t *testing.T) {
	seen := map[string]string{}
	cases := []Input{}
	for _, c := range Classifications() {
		for _, e := range Exposures() {
			cases = append(cases, Input{Classification: c, Exposure: e})
		}
	}
	// …y compris la cellule d'exception gouvernée, qui doit porter son propre tag.
	cases = append(cases, Input{Classification: ClassificationM, Exposure: ExposureInternal, Tags: []string{AuthExceptionApiKey}})

	for _, in := range cases {
		res, err := Derive(in)
		if err != nil {
			t.Fatalf("Derive(%+v): %v", in, err)
		}
		tag := PostureTag(res.Bundle)
		key := in.Classification + "/" + EffectiveExposure(in.Exposure) + "/" + strings.Join(in.Tags, "+")
		if prev, dup := seen[tag]; dup {
			t.Errorf("tag %q produit par DEUX cellules : %s et %s", tag, prev, key)
		}
		seen[tag] = key
	}
	if len(seen) != 10 {
		t.Errorf("%d tags distincts, attendu 10 (9 cellules + m-internal-apikey)", len(seen))
	}
}

// L'exception gouvernée m-internal-apikey EST une posture à part entière : son
// tag doit la nommer, sinon une API en apikey se lirait sur la gateway comme
// une API en oauth2.
func TestPostureTagNamesTheGovernedException(t *testing.T) {
	res, err := Derive(Input{Classification: ClassificationM, Exposure: ExposureInternal, Tags: []string{AuthExceptionApiKey}})
	if err != nil {
		t.Fatalf("Derive: %v", err)
	}
	if got, want := PostureTag(res.Bundle), PostureTagPrefix+"m-internal-apikey"; got != want {
		t.Errorf("tag = %q, want %q", got, want)
	}
}
