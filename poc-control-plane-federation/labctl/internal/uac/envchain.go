package uac

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"sigs.k8s.io/yaml"
)

// EnvChainFile is the optional chain configuration at the ROOT of the
// governance repo working copy (the same environments.yaml governance-api
// reads on main). Absent, the chain is the default Envs — the historical
// dev → staging → production pipeline, verbatim.
const EnvChainFile = "environments.yaml"

// LoadEnvChain reads the ordered environment list from environments.yaml in
// the CI checkout. Absent file → the default Envs; present but malformed or
// empty → error (fail-closed: a broken chain config never silently falls back).
func LoadEnvChain(root string) ([]string, error) {
	raw, err := os.ReadFile(filepath.Join(root, EnvChainFile))
	if err != nil {
		if os.IsNotExist(err) {
			return append([]string(nil), Envs...), nil
		}
		return nil, fmt.Errorf("read %s: %w", EnvChainFile, err)
	}
	var doc struct {
		Environments []string `json:"environments"`
	}
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		return nil, fmt.Errorf("parse %s: %w", EnvChainFile, err)
	}
	if len(doc.Environments) == 0 {
		return nil, fmt.Errorf("%s: 'environments' must list at least one environment", EnvChainFile)
	}
	return doc.Environments, nil
}

// ValidEnvIn reports whether env is a known --env value against an explicit
// chain (one of chain, or EnvAny).
func ValidEnvIn(env string, chain []string) bool {
	if env == EnvAny {
		return true
	}
	for _, e := range chain {
		if env == e {
			return true
		}
	}
	return false
}

// EnabledEnvsIn is EnabledEnvs against an explicit chain: a concrete env
// yields at most that env; EnvAny yields the union, chain order first, then
// any other environment found in the repo, alphabetically.
func (a API) EnabledEnvsIn(env string, chain []string) []string {
	if env != EnvAny {
		if d, ok := a.Deploys[env]; ok && d.Enabled {
			return []string{env}
		}
		return nil
	}
	var envs []string
	for e, d := range a.Deploys {
		if d.Enabled {
			envs = append(envs, e)
		}
	}
	sort.Slice(envs, func(i, j int) bool {
		ri, rj := envRankIn(envs[i], chain), envRankIn(envs[j], chain)
		if ri != rj {
			return ri < rj
		}
		return envs[i] < envs[j]
	})
	return envs
}

// envRankIn positions env in the chain (len(chain) for extras → sorted last).
func envRankIn(env string, chain []string) int {
	for i, e := range chain {
		if env == e {
			return i
		}
	}
	return len(chain)
}
