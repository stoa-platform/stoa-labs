package governance

import (
	"context"
	"fmt"
	"strings"

	"sigs.k8s.io/yaml"
)

// EnvChainPath is the optional chain configuration at the ROOT of the
// governance repo. Absent, the chain is DefaultEnvChain() — the historical
// dev → staging → production pipeline, verbatim.
const EnvChainPath = "environments.yaml"

// Gate is the control set guarding ONE promotion hop (keyed by the TARGET
// environment). Zero value = no specific control: anyone holding
// promotions:approve may approve, including the requester.
type Gate struct {
	// To is the target environment this gate guards.
	To string `json:"to"`
	// SelfApproval documents that the requester may approve their own hop.
	// Informational: self-approval is only BLOCKED when FourEyes is set.
	SelfApproval bool `json:"selfApproval"`
	// ApproverGroup, when set, restricts approval to members of this group
	// (the `groups` claim of the verified token).
	ApproverGroup string `json:"approverGroup"`
	// FourEyes blocks requester == approver (principe des 4 yeux).
	FourEyes bool `json:"fourEyes"`
	// RequireChangeRef makes the change reference (ITSM) mandatory at request.
	RequireChangeRef bool `json:"requireChangeRef"`
	// RequirePVRef makes the acceptance-report reference mandatory at request.
	RequirePVRef bool `json:"requirePVRef"`
	// ITSMCheck verifies change_ref is "approved" in the ITSM at approval
	// time — fail-closed: no client or unreachable ITSM refuses the hop.
	ITSMCheck bool `json:"itsmCheck"`
	// DeployerGroup, when set, names WHO may CARRY the apply toward this
	// environment — the OTHER directory (LDAP group → Vault policy), never the
	// KC `groups` claim: at dispatch time the only verified identity available
	// on every chain is the Vault token (ADR-084). Enforced at the two dispatch
	// sites (team-promote.sh §7.a, apply-uac preflight), NEVER at approve.
	DeployerGroup string `json:"deployerGroup"`
}

// EnvChain is the ordered promotion pipeline plus the per-hop gates
// (keyed by target environment).
type EnvChain struct {
	Envs  []string
	Gates map[string]Gate
}

// DefaultEnvChain is the behaviour WITHOUT environments.yaml, verbatim:
// dev → staging → production, with the historical 4-eyes gate on production.
func DefaultEnvChain() EnvChain {
	return EnvChain{
		Envs:  append([]string(nil), Environments...),
		Gates: map[string]Gate{"production": {To: "production", FourEyes: true}},
	}
}

// envChainFile is the on-disk shape of environments.yaml.
type envChainFile struct {
	Environments []string `json:"environments"`
	Gates        []Gate   `json:"gates"`
}

// ParseEnvChain decodes and validates an environments.yaml document.
// Fail-closed: a present-but-broken chain config is an error, never a silent
// fallback to the default.
func ParseEnvChain(raw []byte) (EnvChain, error) {
	var f envChainFile
	if err := yaml.Unmarshal(raw, &f); err != nil {
		return EnvChain{}, fmt.Errorf("parse %s: %w", EnvChainPath, err)
	}
	if len(f.Environments) == 0 {
		return EnvChain{}, fmt.Errorf("%s: 'environments' must list at least one environment", EnvChainPath)
	}
	seen := map[string]bool{}
	for _, e := range f.Environments {
		if e == "" {
			return EnvChain{}, fmt.Errorf("%s: empty environment name", EnvChainPath)
		}
		if seen[e] {
			return EnvChain{}, fmt.Errorf("%s: duplicate environment %q", EnvChainPath, e)
		}
		seen[e] = true
	}
	gates := map[string]Gate{}
	for _, g := range f.Gates {
		if !seen[g.To] {
			return EnvChain{}, fmt.Errorf("%s: gate 'to: %s' does not name a declared environment", EnvChainPath, g.To)
		}
		if _, dup := gates[g.To]; dup {
			return EnvChain{}, fmt.Errorf("%s: duplicate gate for environment %q", EnvChainPath, g.To)
		}
		gates[g.To] = g
	}
	return EnvChain{Envs: f.Environments, Gates: gates}, nil
}

// DeployerPolicy projects a deployerGroup name onto the Vault policy the
// carrier's token must hold. TWO verifiable families, fail-closed beyond them
// (a name outside the table is a declaration nothing can check — refuse LOUDLY,
// unlike approverGroup whose wrong name silently never matches):
//
//	apim-apply-<x>    → policy "apply-<x>"     (setup-vault-paliers.sh, per-palier)
//	apim-operator-<x> → policy "operator-deploy" (setup-vault-ldap.sh, terminus)
//
// The shell mirror is deployer_group_policy() in scripts/lib/env-chain.sh —
// same table, same refusals; any divergence is a bug (ADR-083 regime).
func (g Gate) DeployerPolicy() (string, error) {
	dg := g.DeployerGroup
	switch {
	case dg == "":
		return "", nil
	case strings.HasPrefix(dg, "apim-apply-") && dg != "apim-apply-":
		return "apply-" + strings.TrimPrefix(dg, "apim-apply-"), nil
	case strings.HasPrefix(dg, "apim-operator-") && dg != "apim-operator-":
		return "operator-deploy", nil
	default:
		return "", fmt.Errorf("deployerGroup %q: outside the two verifiable families (apim-apply-<x> | apim-operator-<x>)", dg)
	}
}

// EnvChain reads environments.yaml ON MAIN per request (no state outside Git).
// Absent file → DefaultEnvChain (the historical behaviour); present but
// malformed → error (fail-closed).
func (s *Store) EnvChain(ctx context.Context) (EnvChain, error) {
	if !s.Repo.Exists(ctx, "main", EnvChainPath) {
		return DefaultEnvChain(), nil
	}
	raw, err := s.Repo.ReadFile(ctx, "main", EnvChainPath)
	if err != nil {
		return EnvChain{}, err
	}
	return ParseEnvChain(raw)
}

// NextOf returns the environment that follows from in the chain, or false
// when from is unknown or terminal.
func (c EnvChain) NextOf(from string) (string, bool) {
	for i, e := range c.Envs {
		if e == from && i+1 < len(c.Envs) {
			return c.Envs[i+1], true
		}
	}
	return "", false
}

// First is the entry environment of the chain (where publish lands).
func (c EnvChain) First() string {
	if len(c.Envs) == 0 {
		return ""
	}
	return c.Envs[0]
}

// HopsString renders the allowed hops ("dev→staging, staging→production")
// for dynamic error messages.
func (c EnvChain) HopsString() string {
	hops := make([]string, 0, len(c.Envs))
	for i := 0; i+1 < len(c.Envs); i++ {
		hops = append(hops, c.Envs[i]+"→"+c.Envs[i+1])
	}
	return strings.Join(hops, ", ")
}
