package vault

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// kvpath_mirror_test.go — D5-R1 : la composition du chemin KV v2 est LA seule
// vraie règle dupliquée du lot Vault (les 1 080 lignes des trois clients sont
// trois transports HTTP dans trois runtimes, pas trois copies d'une règle).
//
// Elle existe en quatre versions, et le Go était FAUX sur le cas client
// documenté. Le rôle Ansible nomme le défaut lui-même
// (apim_common/tasks/secrets.yml) :
//
//	« un chemin <prefix>/<sub> avec segment vide donnerait un slash final
//	  (404 Vault) ou double (301). `select` élimine les segments vides. »
//
// Ansible élide, le shell élide, le Go concaténait : `secret/data//envs/dev/x`.
// Et `FromEnv` ne savait pas exprimer « préfixe explicitement vide » — envOr
// rend le défaut "stoa" pour une variable vide comme pour une absente — donc un
// client à entrées PLATES (mount secret_DEV, pas de préfixe : la configuration
// mesurée chez le client) ne pouvait pas configurer le binaire du tout.

const shellVaultKVPath = "../../../scripts/lib/vault-kv.sh"

type kvPathCase struct {
	name, mount, prefix, sub, want string
}

var kvPathTable = []kvPathCase{
	{"prefixe nominal", "secret", "stoa", "envs/dev/wm-admin", "secret/data/stoa/envs/dev/wm-admin"},
	// LE cas client : entrées à plat, aucun préfixe. Le Go rendait
	// `secret/data//envs/dev/wm-admin` — 301, puis 404.
	{"sans prefixe", "secret", "", "envs/dev/wm-admin", "secret/data/envs/dev/wm-admin"},
	{"mount par palier sans prefixe", "secret_DEV", "", "wm-admin", "secret_DEV/data/wm-admin"},
	{"prefixe a plusieurs segments", "kv", "a/b", "c", "kv/data/a/b/c"},
	{"sub avec slashs parasites", "secret", "stoa", "/envs/dev/", "secret/data/stoa/envs/dev"},
	{"prefixe avec slashs parasites", "secret", "/stoa/", "envs/dev", "secret/data/stoa/envs/dev"},
	{"mount avec slash final", "secret/", "stoa", "x", "secret/data/stoa/x"},
}

func runShellKVDataPath(t *testing.T, mount, prefix, sub string) string {
	t.Helper()
	if _, err := os.Stat(shellVaultKVPath); err != nil {
		t.Fatalf("miroir shell introuvable (%s): %v", shellVaultKVPath, err)
	}
	cmd := exec.Command("bash", "-c",
		`set -u; . "$1"; APIM_KV_MOUNT="$2" APIM_KV_PREFIX="$3" kv_data_path "$4"`,
		"mirror", shellVaultKVPath, mount, prefix, sub)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("bash kv_data_path(%q,%q,%q): %v", mount, prefix, sub, err)
	}
	return strings.TrimSpace(string(out))
}

// TestKVDataPathMirror holds Go and shell to one table.
func TestKVDataPathMirror(t *testing.T) {
	for _, tc := range kvPathTable {
		t.Run(tc.name, func(t *testing.T) {
			got := KVDataPath(tc.mount, tc.prefix, tc.sub)
			sh := runShellKVDataPath(t, tc.mount, tc.prefix, tc.sub)
			if got != tc.want {
				t.Errorf("Go KVDataPath(%q,%q,%q) = %q ; contrat %q", tc.mount, tc.prefix, tc.sub, got, tc.want)
			}
			if sh != tc.want {
				t.Errorf("shell kv_data_path(%q,%q,%q) = %q ; contrat %q", tc.mount, tc.prefix, tc.sub, sh, tc.want)
			}
			if got != sh {
				t.Errorf("DIVERGENCE Go/shell : Go=%q shell=%q", got, sh)
			}
		})
	}
}

// TestPrefixUnsetVsExplicitlyEmpty : « absent » et « vide » ne sont pas la même
// chose. Absent ⇒ le défaut historique "stoa" (aucun déploiement existant ne
// bouge). Vide ⇒ entrées à plat, la configuration client mesurée. envOr
// confondait les deux, donc le second était INEXPRIMABLE.
func TestPrefixUnsetVsExplicitlyEmpty(t *testing.T) {
	t.Setenv("VAULT_ADDR", "http://vault:8200")

	os.Unsetenv("VAULT_PREFIX")
	c, ok := FromEnv()
	if !ok {
		t.Fatal("FromEnv")
	}
	if got := KVDataPath(c.mount, c.prefix, "x"); got != "secret/data/stoa/x" {
		t.Errorf("VAULT_PREFIX absent ⇒ %q, want secret/data/stoa/x (défaut historique)", got)
	}

	t.Setenv("VAULT_PREFIX", "")
	c, ok = FromEnv()
	if !ok {
		t.Fatal("FromEnv")
	}
	if got := KVDataPath(c.mount, c.prefix, "x"); got != "secret/data/x" {
		t.Errorf("VAULT_PREFIX explicitement vide ⇒ %q, want secret/data/x (entrées à plat)", got)
	}
}
