package governance

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// shellEnvChainPath is the shell mirror of Gate.DeployerPolicy.
//
// POURQUOI CE FICHIER EXISTE : les deux implémentations se déclarent « MIROIR
// EXACT » l'une de l'autre — envchain.go dit « any divergence is a bug »,
// env-chain.sh dit « Toute divergence Go/shell est un bug ». Deux tables
// écrites à la main, et RIEN qui les compare : envchain_test.go teste la table
// Go, test-deployer-gate-live.sh teste la table shell, chacune de son côté.
// Elles ont divergé — mesuré le 2026-09-06, sur le cas vide (Go rendait
// succès, le shell refusait) et sur la règle « apim-apply-<x> doit nommer le
// palier de sa porte » (écrite deux fois côté shell, absente côté Go).
//
// Un commentaire ne tient pas un miroir. Ce test le tient : il exécute LES
// DEUX sur la MÊME table et exige le même verdict.
const shellEnvChainPath = "../../../scripts/lib/env-chain.sh"

// deployerPolicyCase is ONE row of the shared truth table — the definition of
// the mirror, consumed by both engines below.
type deployerPolicyCase struct {
	name    string
	group   string // deployerGroup declared on the gate
	gateEnv string // the environment that gate guards (Gate.To)
	want    string // projected Vault policy when accepted
	wantRC  int    // 0 = accepted, 1 = outside the two families, 2 = wrong palier
}

// deployerPolicyTable is THE contract. Both engines are held to it, and to
// each other. Adding a row here obliges both implementations at once — which
// is the whole point.
var deployerPolicyTable = []deployerPolicyCase{
	// --- the two verifiable families, correctly declared --------------------
	{"palier famille apply", "apim-apply-int", "int", "apply-int", 0},
	{"palier homol", "apim-apply-homol", "homol", "apply-homol", 0},
	{"terminus famille operator", "apim-operator-prod", "prod", "operator-deploy", 0},
	{"terminus operator autre nom", "apim-operator-dr", "dr", "operator-deploy", 0},

	// --- hors des deux familles : refus BRUYANT (rc=1) ----------------------
	{"vide = pas de declaration", "", "rec", "", 1},
	{"groupe annuaire KC", "int-team", "int", "", 1},
	{"suffixe apply vide", "apim-apply-", "int", "", 1},
	{"suffixe operator vide", "apim-operator-", "prod", "", 1},
	{"groupe quelconque", "release-team", "int", "", 1},

	// --- famille apply mais <x> ne nomme PAS le palier de sa porte (rc=2) ---
	// La policy projetée « apply-int » n'ouvre pas le palier « homol » : sans
	// cette règle la déclaration « passerait » à la porte puis retomberait sur
	// le 403 de capacité — le refus déclaratif mentirait.
	{"apply nomme un autre palier", "apim-apply-int", "homol", "", 2},
	{"apply nomme le terminus", "apim-apply-prod", "int", "", 2},
}

// runShellDeployerPolicy invokes the shell mirror and returns (stdout, rc).
func runShellDeployerPolicy(t *testing.T, group, gateEnv string) (string, int) {
	t.Helper()
	if _, err := os.Stat(shellEnvChainPath); err != nil {
		t.Fatalf("le miroir shell est introuvable (%s): %v — le miroir ne peut pas être tenu", shellEnvChainPath, err)
	}
	cmd := exec.Command("bash", "-c",
		`set -u; . "$1"; deployer_group_policy "$2" "$3"`,
		"mirror", shellEnvChainPath, group, gateEnv)
	out, err := cmd.Output()
	rc := 0
	if err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf("bash %q/%q: %v", group, gateEnv, err)
		}
		rc = ee.ExitCode()
	}
	return strings.TrimSpace(string(out)), rc
}

// goDeployerPolicy maps Gate.DeployerPolicy onto the shared table's rc space.
func goDeployerPolicy(g Gate) (string, int) {
	pol, err := g.DeployerPolicy()
	if err == nil {
		return pol, 0
	}
	if IsDeployerPalierMismatch(err) {
		return "", 2
	}
	return "", 1
}

// TestDeployerPolicyMirror is the mechanism that was missing: ONE table, both
// engines, same verdict required. It fails if either engine drifts — and it
// fails if they agree on something the table does not sanction.
func TestDeployerPolicyMirror(t *testing.T) {
	for _, tc := range deployerPolicyTable {
		t.Run(tc.name, func(t *testing.T) {
			gate := Gate{To: tc.gateEnv, DeployerGroup: tc.group}
			goPol, goRC := goDeployerPolicy(gate)
			shPol, shRC := runShellDeployerPolicy(t, tc.group, tc.gateEnv)

			// 1. Go respecte le contrat.
			if goRC != tc.wantRC || goPol != tc.want {
				t.Errorf("Go   DeployerPolicy(group=%q, to=%q) = (%q, rc=%d) ; contrat = (%q, rc=%d)",
					tc.group, tc.gateEnv, goPol, goRC, tc.want, tc.wantRC)
			}
			// 2. Le shell respecte le contrat.
			if shRC != tc.wantRC || shPol != tc.want {
				t.Errorf("shell deployer_group_policy(%q, %q) = (%q, rc=%d) ; contrat = (%q, rc=%d)",
					tc.group, tc.gateEnv, shPol, shRC, tc.want, tc.wantRC)
			}
			// 3. Et surtout : ils se répondent l'un l'autre.
			if goRC != shRC || goPol != shPol {
				t.Errorf("DIVERGENCE Go/shell sur (group=%q, to=%q) : Go=(%q, rc=%d) shell=(%q, rc=%d)",
					tc.group, tc.gateEnv, goPol, goRC, shPol, shRC)
			}
		})
	}
}
