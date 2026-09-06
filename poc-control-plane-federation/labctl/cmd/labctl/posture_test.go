package cmd

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/spf13/cobra"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/render"
)

// P2 (GOAL posture-par-exposition) — `labctl posture` is the ONE entry point
// the PRODUCER chain (bash + Ansible) calls to learn which posture actually
// applies to an API. It exists so that the truth table and the anti-downgrade
// comparison stay in ONE implementation: a Jinja/bash re-derivation would be
// the fifth hand-copy P1 spent a jalon removing.
//
// Every case below asserts on the SAME mechanism the apply-side gate uses
// (resolveCentralClassification) — that shared call is the point.

// runPostureCmd drives runPosture with a throw-away cobra command so stdout and
// stderr are captured; it returns (stdout, err).
func runPostureCmd(t *testing.T) (string, error) {
	t.Helper()
	c := &cobra.Command{}
	var out bytes.Buffer
	c.SetOut(&out)
	c.SetErr(&out)
	err := runPosture(c, nil)
	return out.String(), err
}

// withPostureFlags sets the command's flag vars for one test and restores them.
func withPostureFlags(t *testing.T, api, tenant, class, exposure string) {
	t.Helper()
	pa, pt, pc, pe := postureAPIFlag, postureTenantFlag, postureClassificationFlag, postureExposureFlag
	postureAPIFlag, postureTenantFlag, postureClassificationFlag, postureExposureFlag = api, tenant, class, exposure
	t.Cleanup(func() {
		postureAPIFlag, postureTenantFlag, postureClassificationFlag, postureExposureFlag = pa, pt, pc, pe
	})
}

// withOutput pins -o for one test (the flag is a package var shared with the
// other commands).
func withOutput(t *testing.T, format string) {
	t.Helper()
	prev := outputFlag
	outputFlag = format
	t.Cleanup(func() { outputFlag = prev })
}

const postureReg = `apiVersion: governance.stoa.io/v1
kind: ClassificationRegistry
classifications:
  - {owner: accounts-team, tenant: banking-demo, api: accounts-read, classification: VH, exposure: external}
  - {owner: payments-team, tenant: payments-team, api: payments-read, classification: H, exposure: internal}
`

// LA PORTE P2, cas nominal : the demand agrees with the registry, and the line
// the build log will carry says WHERE the retained value came from.
func TestPosture_NominalAnnouncesTheCentralSource(t *testing.T) {
	withCentral(t, postureReg, "accounts-team")
	withPostureFlags(t, "accounts-read", "banking-demo", "VH", "external")
	withOutput(t, "table")

	out, err := runPostureCmd(t)
	if err != nil {
		t.Fatalf("a demand that agrees with governance must resolve: %v\n%s", err, out)
	}
	for _, want := range []string{"accounts-read", "classification=VH", "exposure=external",
		"bundle=vh-external", "source=central"} {
		if !strings.Contains(out, want) {
			t.Errorf("la ligne du journal ne porte pas %q:\n%s", want, out)
		}
	}
}

// A demand STRONGER than the registry is not a spoof: over-declaration is
// harmless (the bundle derives from central anyway) and is surfaced, not blocked.
func TestPosture_OverDeclarationWarnsAndCentralStillWins(t *testing.T) {
	withCentral(t, postureReg, "payments-team")
	withPostureFlags(t, "payments-read", "", "VH", "internal") // demand over-declares VH
	withOutput(t, "table")

	out, err := runPostureCmd(t)
	if err != nil {
		t.Fatalf("over-declaration must not block: %v\n%s", err, out)
	}
	if !strings.Contains(out, "classification=H") {
		t.Errorf("central H must win over the demanded VH:\n%s", out)
	}
	if !strings.Contains(out, "declared: classification=VH") {
		t.Errorf("the DEMANDED posture must stay visible in the log:\n%s", out)
	}
	if !strings.Contains(out, "sur-provisionné") {
		t.Errorf("over-declaration must be surfaced as a warning:\n%s", out)
	}
}

// LA CONTRE-ÉPREUVE P2, axe intégrité : a weaker demand is refused, by NAME.
func TestPosture_WeakerClassificationIsRefusedSpoofed(t *testing.T) {
	withCentral(t, postureReg, "accounts-team")
	withPostureFlags(t, "accounts-read", "", "M", "external") // VH -> M
	withOutput(t, "table")

	out, err := runPostureCmd(t)
	if err == nil {
		t.Fatalf("a downgrade VH->M must be refused:\n%s", out)
	}
	if !strings.Contains(err.Error(), "CLASSIFICATION_SPOOFED") {
		t.Errorf("refusal must carry the named code, got: %v", err)
	}
}

// LA CONTRE-ÉPREUVE P2, axe exposition — the one P1 made expressible: declaring
// `internal` when governance says `external` drops the ip-allowlist. No rank
// says that; bundle containment does.
func TestPosture_WeakerExposureIsRefusedSpoofed(t *testing.T) {
	withCentral(t, postureReg, "accounts-team")
	withPostureFlags(t, "accounts-read", "", "VH", "internal") // external -> internal
	withOutput(t, "table")

	out, err := runPostureCmd(t)
	if err == nil {
		t.Fatalf("declaring internal against a governed external must be refused:\n%s", out)
	}
	if !strings.Contains(err.Error(), "CLASSIFICATION_SPOOFED") {
		t.Errorf("refusal must carry the named code, got: %v", err)
	}
	if !strings.Contains(err.Error(), "exposure") {
		t.Errorf("the refusal must name the axis that failed, got: %v", err)
	}
}

// The OTHER direction of the same non-ladder: `internet` against a governed
// `external` drops the ip-allowlist too. A rank-based comparison would have
// waved this through as "more exposed = stronger".
func TestPosture_InternetAgainstGovernedExternalIsAlsoWeaker(t *testing.T) {
	withCentral(t, postureReg, "accounts-team")
	withPostureFlags(t, "accounts-read", "", "VH", "internet")
	withOutput(t, "table")

	out, err := runPostureCmd(t)
	if err == nil {
		t.Fatalf("internet drops the governed ip-allowlist — must be refused:\n%s", out)
	}
	if !strings.Contains(err.Error(), "CLASSIFICATION_SPOOFED") {
		t.Errorf("refusal must carry the named code, got: %v", err)
	}
}

// An API the demanding team does not own in the registry: UNGOVERNED, never a
// fallback to what the demand declared.
func TestPosture_UngovernedAPIIsRefused(t *testing.T) {
	withCentral(t, postureReg, "accounts-team")
	withPostureFlags(t, "accounts-secret", "", "VH", "external")
	withOutput(t, "table")

	out, err := runPostureCmd(t)
	if err == nil {
		t.Fatalf("an API absent from the registry must not resolve:\n%s", out)
	}
	if !strings.Contains(err.Error(), "CLASSIFICATION_UNGOVERNED") {
		t.Errorf("refusal must carry the named code, got: %v", err)
	}
}

// Line-borrowing: the demand names another team's API. The lookup key is the
// PIPELINE-injected identity, so the row is simply not visible.
func TestPosture_BorrowingAnotherTeamsRowIsUngoverned(t *testing.T) {
	withCentral(t, postureReg, "accounts-team")
	withPostureFlags(t, "payments-read", "", "H", "internal")
	withOutput(t, "table")

	if _, err := runPostureCmd(t); err == nil || !strings.Contains(err.Error(), "CLASSIFICATION_UNGOVERNED") {
		t.Fatalf("accounts-team must not reach payments-read's row, got: %v", err)
	}
}

// A tenant CLAIMED and wrong is a spoof (same rule as the apply-side gate).
func TestPosture_ClaimedTenantMustMatch(t *testing.T) {
	withCentral(t, postureReg, "accounts-team")
	withPostureFlags(t, "accounts-read", "payments-team", "VH", "external")
	withOutput(t, "table")

	if _, err := runPostureCmd(t); err == nil || !strings.Contains(err.Error(), "CLASSIFICATION_SPOOFED") {
		t.Fatalf("a falsified tenant claim must be refused, got: %v", err)
	}
}

// No tenant CLAIMED (the producer manifest carries none) is not a spoof: there
// is nothing to lie about. The anti-spoof anchor is the (owner, api) key, and
// the resolved tenant is REPORTED so the chain can log it.
func TestPosture_NoTenantClaimIsNotASpoof(t *testing.T) {
	withCentral(t, postureReg, "accounts-team")
	withPostureFlags(t, "accounts-read", "", "VH", "external")
	withOutput(t, "json")

	out, err := runPostureCmd(t)
	if err != nil {
		t.Fatalf("an unclaimed tenant must not be treated as a mismatch: %v\n%s", err, out)
	}
	var doc struct {
		Tenant string `json:"tenant"`
	}
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatalf("json: %v\n%s", err, out)
	}
	if doc.Tenant != "banking-demo" {
		t.Errorf("tenant = %q, want the registry's banking-demo (reported, not claimed)", doc.Tenant)
	}
}

// A broken/unreadable registry must NEVER fall back to the demand.
func TestPosture_BrokenRegistryRefusesInsteadOfFallingBack(t *testing.T) {
	p := filepath.Join(t.TempDir(), "classifications.yaml")
	if err := os.WriteFile(p, []byte("classifications: [ {owner: a}\n"), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	t.Setenv("LABCTL_PROJECT", "")
	t.Setenv("LABCTL_CLASSIFICATION_SOURCE", "")
	prevSrc, prevProj := classificationSourceFlag, projectFlag
	classificationSourceFlag, projectFlag = p, "accounts-team"
	t.Cleanup(func() { classificationSourceFlag, projectFlag = prevSrc, prevProj })

	withPostureFlags(t, "accounts-read", "", "VH", "external")
	withOutput(t, "table")

	if _, err := runPostureCmd(t); err == nil || !strings.Contains(err.Error(), "CLASSIFICATION_UNGOVERNED") {
		t.Fatalf("a broken registry must refuse, got: %v", err)
	}
}

// A source configured WITHOUT the pipeline identity cannot do a governed
// lookup — refuse, never resolve on the demand alone.
func TestPosture_SourceWithoutProjectIdentityRefuses(t *testing.T) {
	withCentral(t, postureReg, "") // source set, identity empty
	withPostureFlags(t, "accounts-read", "", "VH", "external")
	withOutput(t, "table")

	if _, err := runPostureCmd(t); err == nil || !strings.Contains(err.Error(), "CLASSIFICATION_UNGOVERNED") {
		t.Fatalf("no project identity must refuse, got: %v", err)
	}
}

// Without any source, the command still answers — from the DEMAND — and says
// so. The chain is what makes the source mandatory (a caller that forgets it
// must not silently believe it got a governed answer), so the label is the
// load-bearing part here.
func TestPosture_NoSourceAnswersFromTheDemandAndLabelsIt(t *testing.T) {
	t.Setenv("LABCTL_PROJECT", "")
	t.Setenv("LABCTL_CLASSIFICATION_SOURCE", "")
	prevSrc, prevProj := classificationSourceFlag, projectFlag
	classificationSourceFlag, projectFlag = "", ""
	t.Cleanup(func() { classificationSourceFlag, projectFlag = prevSrc, prevProj })

	withPostureFlags(t, "accounts-read", "", "M", "internal")
	withOutput(t, "json")

	out, err := runPostureCmd(t)
	if err != nil {
		t.Fatalf("no source is A1 behaviour, not an error: %v\n%s", err, out)
	}
	var doc struct {
		Source string `json:"source"`
		Class  string `json:"classification"`
	}
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatalf("json: %v\n%s", err, out)
	}
	if doc.Source != "demande" {
		t.Errorf("source = %q, want %q — an ungoverned answer must announce itself", doc.Source, "demande")
	}
	if doc.Class != "M" {
		t.Errorf("classification = %q, want the demanded M", doc.Class)
	}
}

// An ungoverned CELL (vocabulary valid on both axes, no named bouquet) is
// refused with the shared integrity code — the P1 fail-closed, reached through
// this command too.
func TestPosture_UnknownExposureIsInconsistent(t *testing.T) {
	t.Setenv("LABCTL_PROJECT", "")
	t.Setenv("LABCTL_CLASSIFICATION_SOURCE", "")
	prevSrc, prevProj := classificationSourceFlag, projectFlag
	classificationSourceFlag, projectFlag = "", ""
	t.Cleanup(func() { classificationSourceFlag, projectFlag = prevSrc, prevProj })

	withPostureFlags(t, "accounts-read", "", "VH", "dmz") // not a governed value
	withOutput(t, "table")

	if _, err := runPostureCmd(t); err == nil || !strings.Contains(err.Error(), "INTEGRITY_INCONSISTENT") {
		t.Fatalf("an unknown exposure must be refused by name, got: %v", err)
	}
}

// The JSON contract the Ansible role parses: every field the chain reads must
// be there, and required_policies must be the DERIVED bundle of the CENTRAL
// values, not of the demand.
func TestPosture_JSONCarriesTheGovernedBundle(t *testing.T) {
	withCentral(t, postureReg, "accounts-team")
	withPostureFlags(t, "accounts-read", "banking-demo", "VH", "external")
	withOutput(t, "json")

	out, err := runPostureCmd(t)
	if err != nil {
		t.Fatalf("posture: %v\n%s", err, out)
	}
	var doc struct {
		Name             string   `json:"name"`
		Classification   string   `json:"classification"`
		Exposure         string   `json:"exposure"`
		Bundle           string   `json:"bundle"`
		Authn            string   `json:"authn"`
		RequiredPolicies []string `json:"required_policies"`
		Source           string   `json:"source"`
		DeclaredClass    string   `json:"declared_classification"`
		DeclaredExposure string   `json:"declared_exposure"`
	}
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatalf("json: %v\n%s", err, out)
	}
	if doc.Name != "accounts-read" || doc.Classification != "VH" || doc.Exposure != "external" {
		t.Errorf("identity/posture = %+v", doc)
	}
	if doc.Bundle != "vh-external" {
		t.Errorf("bundle = %q, want the NAMED cell vh-external", doc.Bundle)
	}
	if doc.Source != "central" {
		t.Errorf("source = %q, want central", doc.Source)
	}
	if doc.DeclaredClass != "VH" || doc.DeclaredExposure != "external" {
		t.Errorf("the demand must be echoed back: %+v", doc)
	}
	for _, want := range []string{"mtls", "oauth2", "ip-allowlist", "rate-limit", "audit-log", "https-only"} {
		found := false
		for _, p := range doc.RequiredPolicies {
			if p == want {
				found = true
			}
		}
		if !found {
			t.Errorf("required_policies %v manque %q", doc.RequiredPolicies, want)
		}
	}
}

// An empty demanded exposure defaults to internal HERE too — same single
// place (render.EffectiveExposure), reported effective so the log never shows
// a blank where a value was used.
func TestPosture_EmptyExposureIsReportedEffective(t *testing.T) {
	t.Setenv("LABCTL_PROJECT", "")
	t.Setenv("LABCTL_CLASSIFICATION_SOURCE", "")
	prevSrc, prevProj := classificationSourceFlag, projectFlag
	classificationSourceFlag, projectFlag = "", ""
	t.Cleanup(func() { classificationSourceFlag, projectFlag = prevSrc, prevProj })

	withPostureFlags(t, "accounts-read", "", "M", "")
	withOutput(t, "table")

	out, err := runPostureCmd(t)
	if err != nil {
		t.Fatalf("posture: %v\n%s", err, out)
	}
	if !strings.Contains(out, "exposure=internal") {
		t.Errorf("an empty exposure must be reported as its effective value:\n%s", out)
	}
}

// --api is the lookup key: without it the command must refuse rather than
// resolve on an empty name (which would silently be UNGOVERNED for a reason
// the operator did not cause).
func TestPosture_MissingAPINameRefuses(t *testing.T) {
	withCentral(t, postureReg, "accounts-team")
	withPostureFlags(t, "", "", "VH", "external")
	withOutput(t, "table")

	if _, err := runPostureCmd(t); err == nil || !strings.Contains(err.Error(), "--api") {
		t.Fatalf("a missing --api must be named as such, got: %v", err)
	}
}

// A value outside the governed vocabulary must be named as such, EVEN when a
// registry is configured. Weaker() is fail-closed — it answers "weaker" for
// anything it cannot derive — so without this guard the refusal would read
// "your posture is weaker than governance" to someone who simply mistyped a
// value, and never mention that the value does not exist.
func TestPosture_UnknownDeclaredValueIsNamedNotCalledADowngrade(t *testing.T) {
	for _, tc := range []struct{ name, class, exposure, want string }{
		{"exposition inconnue", "H", "dmz", `exposure="dmz"`},
		{"classification inconnue", "XL", "internal", `classification="XL"`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			withCentral(t, postureReg, "payments-team")
			withPostureFlags(t, "payments-read", "", tc.class, tc.exposure)
			withOutput(t, "table")

			_, err := runPostureCmd(t)
			if err == nil {
				t.Fatalf("une valeur hors vocabulaire doit être refusée")
			}
			if !strings.Contains(err.Error(), "INTEGRITY_INCONSISTENT") {
				t.Errorf("code = %v, want [INTEGRITY_INCONSISTENT] (pas un downgrade)", err)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("le refus ne cite pas la valeur fautive %s : %v", tc.want, err)
			}
			if strings.Contains(err.Error(), "PLUS FAIBLE") {
				t.Errorf("le refus accuse un downgrade alors que la valeur n'existe pas : %v", err)
			}
		})
	}
}

// ── P3 (ADR-093) : le TAG que le rôle Ansible écrira sur la gateway ─────────
//
// Le rôle ne compose RIEN : il reçoit `tag` fini et `tag_prefix` pour savoir ce
// qu'il doit retirer. Ces deux champs sont donc un CONTRAT avec la chaîne, au
// même titre que les codes de refus — s'ils disparaissaient de la sortie, le
// rôle poserait un tag vide et la relecture le dirait, mais trop tard.
func TestPosture_JSONCarriesTheTagTheRoleWillPose(t *testing.T) {
	withCentral(t, postureReg, "accounts-team")
	withPostureFlags(t, "accounts-read", "banking-demo", "VH", "external")
	withOutput(t, "json")

	out, err := runPostureCmd(t)
	if err != nil {
		t.Fatalf("posture: %v\n%s", err, out)
	}
	var doc struct {
		Bundle    string `json:"bundle"`
		Tag       string `json:"tag"`
		TagPrefix string `json:"tag_prefix"`
	}
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatalf("json: %v\n%s", err, out)
	}
	if doc.Tag != render.PostureTag(doc.Bundle) {
		t.Errorf("tag = %q, want %q (le tag DOIT être dérivé du bouquet, pas composé ailleurs)",
			doc.Tag, render.PostureTag(doc.Bundle))
	}
	if doc.TagPrefix != render.PostureTagPrefix {
		t.Errorf("tag_prefix = %q, want %q", doc.TagPrefix, render.PostureTagPrefix)
	}
	if !strings.HasPrefix(doc.Tag, doc.TagPrefix) {
		t.Errorf("le tag %q doit tomber dans l'espace de noms %q qu'il annonce", doc.Tag, doc.TagPrefix)
	}
}

// LE POINT DU JALON, vu depuis l'autorité : ce que le rôle posera est le tag de
// la posture GOUVERNÉE, jamais celui de la posture DÉCLARÉE. Une demande qui
// sur-déclare (acceptée, corrigée) doit donc recevoir le tag du registre.
func TestPosture_TagFollowsTheGovernedPostureNotTheDeclaredOne(t *testing.T) {
	withCentral(t, postureReg, "payments-team")
	// Le registre gouverne payments-read en H/internal ; la demande sur-déclare VH.
	withPostureFlags(t, "payments-read", "", "VH", "internal")
	withOutput(t, "json")

	out, err := runPostureCmd(t)
	if err != nil {
		t.Fatalf("posture: %v\n%s", err, out)
	}
	var doc struct {
		Tag                  string `json:"tag"`
		DeclaredClassificati string `json:"declared_classification"`
	}
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatalf("json: %v\n%s", err, out)
	}
	if doc.Tag != render.PostureTagPrefix+"h-internal" {
		t.Errorf("tag = %q, want %sh-internal — le tag suit le REGISTRE, pas la déclaration %q",
			doc.Tag, render.PostureTagPrefix, doc.DeclaredClassificati)
	}
}

// La sortie TEXTE la porte aussi : c'est elle que lit un humain dans le journal
// du build, et c'est par elle qu'on constate de visu quel tag a été posé.
func TestPosture_TextOutputAnnouncesTheTag(t *testing.T) {
	withCentral(t, postureReg, "accounts-team")
	withPostureFlags(t, "accounts-read", "", "VH", "external")
	withOutput(t, "text")

	out, err := runPostureCmd(t)
	if err != nil {
		t.Fatalf("posture: %v\n%s", err, out)
	}
	if !strings.Contains(out, "tag: "+render.PostureTagPrefix+"vh-external") {
		t.Errorf("la sortie texte n'annonce pas le tag :\n%s", out)
	}
}
