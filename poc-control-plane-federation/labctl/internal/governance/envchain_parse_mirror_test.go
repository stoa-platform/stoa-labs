package governance

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// envchain_parse_mirror_test.go — D1 : la chaîne d'environnements avait TROIS
// lecteurs (ce paquet, internal/uac, et scripts/lib/env-chain.sh), tenus par un
// commentaire — env-chain.sh affirmait « une chaîne acceptée ici l'est par Go —
// le sens sûr ».
//
// C'était FAUX, et pas dans le sens rassurant. Mesuré le 2026-09-06 :
//
//   - `Gates:` (une majuscule) : `env_chain_validate` rend 0, les LECTEURS
//     shell ne voient plus aucune porte (fourEyes=0, itsmCheck=0), et Go
//     applique les deux. Le MÊME fichier, quatre-yeux + ITSM opposés d'un côté
//     et absents de l'autre, déclaré valide. C'est le fail-open du lot.
//   - `Environments:` (idem) : le shell refuse, Go accepte.
//   - `fourEye: true` (vraie faute de frappe) : le shell refuse, Go accepte en
//     silence avec FourEyes=false — porte relâchée.
//
// Ce fichier remplace le commentaire par un mécanisme : UNE table, les DEUX
// moteurs exécutés dessus, et — pour tout document accepté — les champs de
// porte relus par les LECTEURS shell et comparés champ à champ au Gate de Go.
// Tenir le validateur seul ne suffisait pas : les cas les plus dangereux sont
// invisibles à `env_chain_validate` et ne se voient que sur les lecteurs.

// chainCase is one row of the shared contract.
type chainCase struct {
	name   string
	body   string
	accept bool // le document est-il acceptable ?
	envs   []string
	gates  map[string]Gate // comparé aux LECTEURS shell quand accept
}

const okChain = "environments: [dev, rec, prod]\n"

var parseChainTable = []chainCase{
	{
		name:   "nominal avec porte complete",
		body:   okChain + "gates:\n  - to: prod\n    fourEyes: true\n    itsmCheck: true\n    approverGroup: release-team\n    deployerGroup: apim-operator-prod\n",
		accept: true,
		envs:   []string{"dev", "rec", "prod"},
		gates: map[string]Gate{"prod": {
			To: "prod", FourEyes: true, ITSMCheck: true,
			ApproverGroup: "release-team", DeployerGroup: "apim-operator-prod",
		}},
	},
	{name: "sans gates", body: okChain, accept: true, envs: []string{"dev", "rec", "prod"}, gates: map[string]Gate{}},
	{name: "gates null", body: okChain + "gates:\n", accept: true, envs: []string{"dev", "rec", "prod"}, gates: map[string]Gate{}},

	// --- LE FAIL-OPEN : une majuscule a la racine -----------------------------
	// `Gates:` etait accepte par env_chain_validate, ignore par les lecteurs
	// shell (aucune porte) et APPLIQUE par Go. Verdict de securite oppose sur
	// le meme fichier.
	{name: "racine Gates majuscule", body: okChain + "Gates:\n  - to: prod\n    fourEyes: true\n    itsmCheck: true\n", accept: false},
	{name: "racine Environments majuscule", body: "Environments: [dev, prod]\n", accept: false},
	{name: "racine cle etrangere", body: okChain + "wibble: 1\n", accept: false},

	// --- cles de porte : la faute de frappe doit etre BRUYANTE ----------------
	{name: "cle foureyes minuscule", body: okChain + "gates: [{to: prod, foureyes: true}]\n", accept: false},
	{name: "cle fourEye faute de frappe", body: okChain + "gates: [{to: prod, fourEye: true}]\n", accept: false},
	{name: "cle FourEyes casse haute", body: okChain + "gates: [{to: prod, FourEyes: true}]\n", accept: false},
	{name: "cle de porte etrangere", body: okChain + "gates: [{to: prod, wibble: true}]\n", accept: false},

	// --- booleens : un booleen YAML, pas une verite Python --------------------
	{name: "bool en chaine", body: okChain + "gates: [{to: prod, fourEyes: \"true\"}]\n", accept: false},
	{name: "bool en entier", body: okChain + "gates: [{to: prod, fourEyes: 1}]\n", accept: false},
	{name: "bool yes accepte", body: okChain + "gates: [{to: prod, fourEyes: yes}]\n", accept: true,
		envs: []string{"dev", "rec", "prod"}, gates: map[string]Gate{"prod": {To: "prod", FourEyes: true}}},

	// --- la liste des paliers -------------------------------------------------
	{name: "palier vide", body: "environments: [dev, \"\", prod]\n", accept: false},
	{name: "palier duplique", body: "environments: [dev, dev]\n", accept: false},
	{name: "palier casse haute", body: "environments: [dev, PROD]\n", accept: false},
	{name: "palier avec tiret", body: "environments: [dev, pre-prod]\n", accept: false},
	{name: "palier entier", body: "environments: [dev, 3]\n", accept: false},
	{name: "environments absent", body: "gates: []\n", accept: false},
	{name: "environments vide", body: "environments: []\n", accept: false},
	{name: "environments scalaire", body: "environments: dev\n", accept: false},

	// --- les portes -----------------------------------------------------------
	{name: "porte vers palier non declare", body: okChain + "gates: [{to: itn}]\n", accept: false},
	{name: "porte dupliquee", body: okChain + "gates: [{to: prod}, {to: prod}]\n", accept: false},
	{name: "porte sans to", body: okChain + "gates: [{fourEyes: true}]\n", accept: false},
	{name: "gates mapping au lieu de liste", body: okChain + "gates: {to: prod}\n", accept: false},

	// --- les noms -------------------------------------------------------------
	{name: "approverGroup avec espace", body: okChain + "gates: [{to: prod, approverGroup: \"a b\"}]\n", accept: false},
	// Go ne distingue pas un champ absent d'une chaine vide (string, pas
	// *string) : l'alignement se fait par le bas, et le shell cesse de refuser.
	{name: "deployerGroup vide", body: okChain + "gates: [{to: prod, deployerGroup: \"\"}]\n", accept: true,
		envs: []string{"dev", "rec", "prod"}, gates: map[string]Gate{"prod": {To: "prod"}}},

	// --- formes brutes --------------------------------------------------------
	{name: "racine liste", body: "- dev\n- prod\n", accept: false},
	{name: "YAML malforme", body: "environments: [dev\n", accept: false},
}

// shellChain runs one env-chain.sh function against a document written to a
// temp file, exactly as every caller does (via $STOA_ENV_CHAIN_FILE).
func shellChain(t *testing.T, body, fn string, args ...string) (string, int) {
	t.Helper()
	if _, err := os.Stat(shellEnvChainPath); err != nil {
		t.Fatalf("miroir shell introuvable (%s): %v", shellEnvChainPath, err)
	}
	f := filepath.Join(t.TempDir(), "environments.yaml")
	if err := os.WriteFile(f, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	argv := append([]string{"bash", "-c",
		`set -u; export STOA_ENV_CHAIN_FILE="$2"; . "$1"; f="$3"; shift 3; "$f" "$@"`,
		"mirror", shellEnvChainPath, f, fn}, args...)
	cmd := exec.Command(argv[0], argv[1:]...)
	out, err := cmd.Output()
	rc := 0
	if err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf("bash %s: %v", fn, err)
		}
		rc = ee.ExitCode()
	}
	return strings.TrimSpace(string(out)), rc
}

// TestParseEnvChainMirror holds the two engines to one table — acceptance AND,
// for every accepted document, the gate fields the shell READERS actually see.
func TestParseEnvChainMirror(t *testing.T) {
	for _, tc := range parseChainTable {
		t.Run(tc.name, func(t *testing.T) {
			c, goErr := ParseEnvChain([]byte(tc.body))
			goAccept := goErr == nil
			_, shRC := shellChain(t, tc.body, "env_chain_validate")
			shAccept := shRC == 0

			if goAccept != tc.accept {
				t.Errorf("Go ParseEnvChain accepte=%v (err=%v) ; contrat=%v", goAccept, goErr, tc.accept)
			}
			if shAccept != tc.accept {
				t.Errorf("shell env_chain_validate accepte=%v (rc=%d) ; contrat=%v", shAccept, shRC, tc.accept)
			}
			if goAccept != shAccept {
				t.Fatalf("DIVERGENCE Go/shell sur l'acceptation : Go=%v (err=%v) shell=%v (rc=%d)", goAccept, goErr, shAccept, shRC)
			}
			if !tc.accept {
				return
			}

			// La liste des paliers, vue par les deux.
			if got := strings.Join(c.Envs, " "); got != strings.Join(tc.envs, " ") {
				t.Errorf("Go envs = %q ; contrat %q", got, strings.Join(tc.envs, " "))
			}
			if got, rc := shellChain(t, tc.body, "env_chain"); rc != 0 || got != strings.Join(tc.envs, " ") {
				t.Errorf("shell env_chain = %q (rc=%d) ; contrat %q", got, rc, strings.Join(tc.envs, " "))
			}

			// LES PORTES, telles que les LECTEURS shell les voient — c'est
			// cette moitié qui attrape le cas `Gates:`, invisible au validateur.
			for _, env := range tc.envs {
				want := tc.gates[env] // zéro value = aucune porte
				gotGo := c.Gates[env]
				if gotGo.FourEyes != want.FourEyes || gotGo.ITSMCheck != want.ITSMCheck ||
					gotGo.ApproverGroup != want.ApproverGroup || gotGo.DeployerGroup != want.DeployerGroup {
					t.Errorf("Go gate[%s] = %+v ; contrat %+v", env, gotGo, want)
				}
				fe, _ := shellChain(t, tc.body, "env_chain_gate_four_eyes", env)
				ic, _ := shellChain(t, tc.body, "env_chain_gate_itsm_check", env)
				ag, _ := shellChain(t, tc.body, "env_chain_approver_group", env)
				dg, _ := shellChain(t, tc.body, "env_chain_gate_deployer_group", env)
				shFE, shIC := fe == "FOUREYES=1", ic == "ITSMCHECK=1"
				if shFE != want.FourEyes || shIC != want.ITSMCheck || ag != want.ApproverGroup || dg != want.DeployerGroup {
					t.Errorf("LECTEURS shell gate[%s] : fourEyes=%v itsm=%v approver=%q deployer=%q ; contrat %+v",
						env, shFE, shIC, ag, dg, want)
				}
				if shFE != gotGo.FourEyes || shIC != gotGo.ITSMCheck {
					t.Errorf("DIVERGENCE Go/lecteurs shell sur la porte %s : Go(fourEyes=%v itsm=%v) shell(fourEyes=%v itsm=%v) — MÊME fichier, verdict de sécurité opposé",
						env, gotGo.FourEyes, gotGo.ITSMCheck, shFE, shIC)
				}
			}
		})
	}
}

// TestDefaultChainsAreOne : uac.Envs et governance.Environments étaient deux
// littéraux identiques que RIEN ne liait. Le repli « fichier absent » est une
// divergence délibérée et documentée (le shell est fail-closed, Go retombe sur
// la chaîne historique) — mais les deux replis Go doivent au moins être UN.
func TestDefaultChainsAreOne(t *testing.T) {
	got := strings.Join(DefaultEnvChain().Envs, " ")
	want := strings.Join(Environments, " ")
	if got != want {
		t.Errorf("DefaultEnvChain = %q, Environments = %q", got, want)
	}
}
