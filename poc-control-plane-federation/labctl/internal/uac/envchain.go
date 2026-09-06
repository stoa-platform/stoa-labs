package uac

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/governance"
)

// EnvChainFile is the optional chain configuration at the ROOT of the
// governance repo working copy — the SAME file, under the SAME name, that
// governance-api reads on main. Aliased, not re-declared: two constants with
// the same value are two things that can drift.
const EnvChainFile = governance.EnvChainPath

// LoadEnvChain reads the ordered environment list from environments.yaml in
// the CI checkout. Absent file → the default chain; present but malformed →
// error (fail-closed: a broken chain config never silently falls back).
//
// This used to be a THIRD parser of the same document, and a laxist one: it
// accepted an empty environment name, a duplicated environment, a gate toward
// an undeclared environment — all things governance.ParseEnvChain refuses.
// apply-uac read the same file twice with the two parsers (uac here for --env
// and the enabled-env derivation, governance for the preflights); the strict
// one happened to run first, so the laxity was masked BY ORDERING, not by
// design. It now delegates: one parser, one verdict.
func LoadEnvChain(root string) ([]string, error) {
	raw, err := os.ReadFile(filepath.Join(root, EnvChainFile))
	if err != nil {
		if os.IsNotExist(err) {
			return append([]string(nil), governance.DefaultEnvChain().Envs...), nil
		}
		return nil, fmt.Errorf("read %s: %w", EnvChainFile, err)
	}
	c, err := governance.ParseEnvChain(raw)
	if err != nil {
		return nil, err
	}
	return c.Envs, nil
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
