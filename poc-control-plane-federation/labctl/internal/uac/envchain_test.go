package uac

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadEnvChain_AbsentFallsBackToDefault(t *testing.T) {
	chain, err := LoadEnvChain(t.TempDir())
	if err != nil {
		t.Fatalf("LoadEnvChain: %v", err)
	}
	if strings.Join(chain, ",") != "dev,staging,production" {
		t.Errorf("chain = %v, want the default Envs", chain)
	}
}

func TestLoadEnvChain_CustomChain(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, EnvChainFile),
		[]byte("environments: [dev, rec, int, prod]\ngates:\n  - {to: prod, fourEyes: true}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	chain, err := LoadEnvChain(root)
	if err != nil {
		t.Fatalf("LoadEnvChain: %v", err)
	}
	if strings.Join(chain, ",") != "dev,rec,int,prod" {
		t.Errorf("chain = %v, want [dev rec int prod]", chain)
	}
}

func TestLoadEnvChain_BrokenFileFailsClosed(t *testing.T) {
	cases := map[string]string{
		"malformed yaml":     "environments: [dev\n",
		"empty environments": "environments: []\n",
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			if err := os.WriteFile(filepath.Join(root, EnvChainFile), []byte(body), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := LoadEnvChain(root); err == nil {
				t.Errorf("broken environments.yaml must error, not fall back")
			}
		})
	}
}

func TestValidEnvIn(t *testing.T) {
	chain := []string{"dev", "rec", "int", "prod"}
	for _, e := range []string{"dev", "rec", "int", "prod", "any"} {
		if !ValidEnvIn(e, chain) {
			t.Errorf("ValidEnvIn(%q) = false, want true", e)
		}
	}
	for _, e := range []string{"", "staging", "production", "PROD"} {
		if ValidEnvIn(e, chain) {
			t.Errorf("ValidEnvIn(%q) = true, want false", e)
		}
	}
}

func TestEnabledEnvsIn_ChainOrder(t *testing.T) {
	chain := []string{"dev", "rec", "int", "prod"}
	a := API{Deploys: map[string]Deploy{
		"prod": {Enabled: true},
		"dev":  {Enabled: true},
		"rec":  {Enabled: false},
		"qa":   {Enabled: true}, // off-chain env found in a repo
	}}
	if got := a.EnabledEnvsIn(EnvAny, chain); strings.Join(got, ",") != "dev,prod,qa" {
		t.Errorf("EnabledEnvsIn(any) = %v, want chain order then extras", got)
	}
	if got := a.EnabledEnvsIn("rec", chain); got != nil {
		t.Errorf("EnabledEnvsIn(rec) = %v, want nil (disabled)", got)
	}
	if got := a.EnabledEnvsIn("prod", chain); strings.Join(got, ",") != "prod" {
		t.Errorf("EnabledEnvsIn(prod) = %v, want [prod]", got)
	}
}
