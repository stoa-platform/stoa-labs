package governance

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// branchref_mirror_test.go — D8 : le nom de branche `<prefixe>/<app>-<palier>`
// était découpé à SEPT endroits, en deux langages, avec quatre comportements
// différents sur les mêmes entrées.
//
// Le défaut réel n'était pas la duplication : c'était le BLANCHIMENT SILENCIEUX
// de provision-plan.sh — `ENVV="${PR_BRANCH##*-}"` puis, si le palier n'est pas
// dans la chaîne hors-prod, `ENVV=""`. En aval, `${ENVV:+-e apim_ss_env=...}`
// fait simplement DISPARAÎTRE l'extra-var : le PLAN présenté au demandeur porte
// alors sur le palier par défaut du rôle, pas sur celui que sa branche nomme.
// Aucun refus, aucun signal.
//
// ⚠ RÉGIME DÉGRADÉ, dit comme tel : il n'existe AUCUNE implémentation Go du
// découpage (vérifié : zéro `provision/` dans labctl/*.go). Ce n'est donc pas un
// miroir à deux moteurs comme TestDeployerPolicyMirror — c'est un test de
// CONTRAT à un moteur. Sa valeur : porter la table dans `go test`, la seule
// porte que le dépôt exécute à chaque passage, et interdire la dérive du shell.
// Le jour où un moteur Go apparaît, la table l'attend.

const shellBranchRefPath = "../../../scripts/lib/branch-ref.sh"

// branchCase — une ligne du contrat. rc : 0 ok · 1 mauvais préfixe ·
// 2 pas de suffixe -<palier> · 3 nom d'app hors classe · 4 palier hors classe.
type branchCase struct {
	name, ref, prefix string
	wantApp, wantEnv  string
	wantRC            int
}

var branchRefTable = []branchCase{
	{"nominal", "provision/mon-app-dev", "provision/", "mon-app", "dev", 0},
	// LE cas qui sépare `##*-` (dernier tiret) de `#*-` (premier) :
	{"app a plusieurs tirets", "provision/mon-app-multi-mot-prod", "provision/", "mon-app-multi-mot", "prod", 0},
	{"app sans tiret", "provision/app-dev", "provision/", "app", "dev", 0},
	// L'appartenance A LA CHAINE n'est PAS l'affaire du decoupage : `zeta` est
	// une forme valide. C'est l'APPELANT qui doit refuser un palier hors chaine
	// — par un refus NOMME, jamais en blanchissant la variable.
	{"palier bien forme mais inconnu", "provision/a-b-zeta", "provision/", "a-b", "zeta", 0},
	{"autre prefixe", "onboard/equipe-rec", "onboard/", "equipe", "rec", 0},

	{"mauvais prefixe", "feature/x-dev", "provision/", "", "", 1},
	{"prefixe nu", "provision/", "provision/", "", "", 2},
	{"sans tiret", "provision/x", "provision/", "", "", 2},

	{"app en casse haute", "provision/APP-dev", "provision/", "", "", 3},
	{"app vide", "provision/-dev", "provision/", "", "", 3},
	{"app avec un point", "provision/mon.app-dev", "provision/", "", "", 3},
	{"app commencant par un tiret", "provision/-mon-app-dev", "provision/", "", "", 3},

	{"palier vide", "provision/app-", "provision/", "", "", 4},
	{"palier en casse haute", "provision/app-DEV", "provision/", "", "", 4},
	{"palier avec un point", "provision/app-de.v", "provision/", "", "", 4},
}

func runShellBranchSplit(t *testing.T, lib, ref, prefix string) (string, string, int) {
	t.Helper()
	if _, err := os.Stat(lib); err != nil {
		t.Fatalf("lib introuvable (%s): %v — le contrat ne peut pas être tenu", lib, err)
	}
	cmd := exec.Command("bash", "-c",
		`set -u; . "$1"; branch_split "$2" "$3"`, "mirror", lib, ref, prefix)
	out, err := cmd.Output()
	rc := 0
	if err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf("bash branch_split: %v", err)
		}
		rc = ee.ExitCode()
	}
	f := strings.Fields(strings.TrimSpace(string(out)))
	app, env := "", ""
	if len(f) == 2 {
		app, env = f[0], f[1]
	}
	return app, env, rc
}

func TestBranchSplitContract(t *testing.T) {
	for _, tc := range branchRefTable {
		t.Run(tc.name, func(t *testing.T) {
			app, env, rc := runShellBranchSplit(t, shellBranchRefPath, tc.ref, tc.prefix)
			if rc != tc.wantRC || app != tc.wantApp || env != tc.wantEnv {
				t.Errorf("branch_split(%q, %q) = (app=%q, env=%q, rc=%d) ; contrat (app=%q, env=%q, rc=%d)",
					tc.ref, tc.prefix, app, env, rc, tc.wantApp, tc.wantEnv, tc.wantRC)
			}
		})
	}
}

// TestBranchSplitMutantRougit — « une parité qui ne rougit jamais ne prouve
// rien ». On substitue le découpage au DERNIER tiret par le PREMIER dans une
// copie de la lib, et on exige qu'au moins une ligne de la table diverge.
// Témoin garanti : provision/mon-app-multi-mot-prod.
func TestBranchSplitMutantRougit(t *testing.T) {
	raw, err := os.ReadFile(shellBranchRefPath)
	if err != nil {
		t.Fatalf("read %s: %v", shellBranchRefPath, err)
	}
	mutated := strings.Replace(string(raw), `${rest##*-}`, `${rest#*-}`, 1)
	if mutated == string(raw) {
		t.Fatalf("l'ancre de mutation ${rest##*-} est absente — ré-ancrer la contre-épreuve")
	}
	lib := t.TempDir() + "/branch-ref.sh"
	if err := os.WriteFile(lib, []byte(mutated), 0o600); err != nil {
		t.Fatal(err)
	}
	diverged := 0
	for _, tc := range branchRefTable {
		app, env, rc := runShellBranchSplit(t, lib, tc.ref, tc.prefix)
		if rc != tc.wantRC || app != tc.wantApp || env != tc.wantEnv {
			diverged++
		}
	}
	if diverged == 0 {
		t.Error("le mutant (découpage au PREMIER tiret) passe toute la table — la table est vacante")
	}
}
