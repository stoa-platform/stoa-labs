package governance

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
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

// chainRootKeys and chainGateKeys are the ONLY keys this document may carry.
// They mirror ALLOWED/root of env_chain_validate (scripts/lib/env-chain.sh) and
// are matched CASE-SENSITIVELY on purpose: `Gates:` and `fourEye:` are the two
// faults that used to pass. Neither UnmarshalStrict nor DisallowUnknownFields
// helps — both are case-INSENSITIVE (measured 2026-09-06), which is exactly how
// `FourEyes: true` silently became FourEyes=true while the shell readers saw no
// gate at all.
var (
	chainRootKeys = map[string]bool{"environments": true, "gates": true}
	chainGateKeys = map[string]bool{
		"to": true, "selfApproval": true, "approverGroup": true, "fourEyes": true,
		"requireChangeRef": true, "requirePVRef": true, "itsmCheck": true, "deployerGroup": true,
	}
	envNameRe   = regexp.MustCompile(`^[a-z0-9]+$`)
	groupNameRe = regexp.MustCompile(`^[A-Za-z0-9._-]*$`)
)

// ParseEnvChain decodes and validates an environments.yaml document.
// Fail-closed: a present-but-broken chain config is an error, never a silent
// fallback to the default. The rules below are the shell's, ported verbatim —
// TestParseEnvChainMirror runs BOTH engines over one table and also compares
// what the shell READERS see, because the worst faults are invisible to the
// validator alone.
func ParseEnvChain(raw []byte) (EnvChain, error) {
	// Strict: rejects a duplicated root key, which neither engine used to see.
	js, err := yaml.YAMLToJSONStrict(raw)
	if err != nil {
		return EnvChain{}, fmt.Errorf("parse %s: %w", EnvChainPath, err)
	}
	var rootKeys map[string]json.RawMessage
	if err := json.Unmarshal(js, &rootKeys); err != nil {
		return EnvChain{}, fmt.Errorf("%s: document racine : mapping attendu (%w)", EnvChainPath, err)
	}
	for k := range rootKeys {
		if !chainRootKeys[k] {
			return EnvChain{}, fmt.Errorf("%s: clé racine inconnue %q (attendu : environments, gates) — la casse compte", EnvChainPath, k)
		}
	}
	// Le TYPE, pas seulement la forme : sigs.k8s.io/yaml coerce `3` en "3", qui
	// passerait ^[a-z0-9]+$. Le shell refuse (isinstance(e, str)) — on refuse
	// aussi, sur la valeur JSON brute.
	if rawEnvs, ok := rootKeys["environments"]; ok {
		var es []json.RawMessage
		if err := json.Unmarshal(rawEnvs, &es); err != nil {
			return EnvChain{}, fmt.Errorf("%s: 'environments' : liste attendue (%w)", EnvChainPath, err)
		}
		for _, e := range es {
			if len(e) == 0 || e[0] != '"' {
				return EnvChain{}, fmt.Errorf("%s: environnement %s : chaîne attendue", EnvChainPath, string(e))
			}
		}
	}
	if rawGates, ok := rootKeys["gates"]; ok && string(rawGates) != "null" {
		var gs []map[string]json.RawMessage
		if err := json.Unmarshal(rawGates, &gs); err != nil {
			return EnvChain{}, fmt.Errorf("%s: 'gates' : liste attendue (%w)", EnvChainPath, err)
		}
		for i, g := range gs {
			for k := range g {
				if !chainGateKeys[k] {
					return EnvChain{}, fmt.Errorf("%s: gates[%d] : clé inconnue %q — la casse compte", EnvChainPath, i, k)
				}
			}
		}
	}

	var f envChainFile
	if err := yaml.Unmarshal(raw, &f); err != nil {
		return EnvChain{}, fmt.Errorf("parse %s: %w", EnvChainPath, err)
	}
	if len(f.Environments) == 0 {
		return EnvChain{}, fmt.Errorf("%s: 'environments' must list at least one environment", EnvChainPath)
	}
	seen := map[string]bool{}
	for _, e := range f.Environments {
		if !envNameRe.MatchString(e) {
			return EnvChain{}, fmt.Errorf("%s: environnement %q hors de [a-z0-9]+", EnvChainPath, e)
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
		if !groupNameRe.MatchString(g.ApproverGroup) {
			return EnvChain{}, fmt.Errorf("%s: porte %q : approverGroup hors de [A-Za-z0-9._-] (%q)", EnvChainPath, g.To, g.ApproverGroup)
		}
		if !groupNameRe.MatchString(g.DeployerGroup) {
			return EnvChain{}, fmt.Errorf("%s: porte %q : deployerGroup hors de [A-Za-z0-9._-] (%q)", EnvChainPath, g.To, g.DeployerGroup)
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
// The EMPTY group is refused here too — "no declaration" is the CALLER's case
// to skip (preflightDeployerGate does, so does every shell caller), never a
// projection this function invents. Returning ("", nil) made the empty group
// indistinguishable from a successful projection and diverged from the shell
// mirror, which has always refused it (mesuré 2026-09-06).
//
// Family apim-apply-<x>: <x> MUST name the palier this gate guards (g.To).
// Otherwise the declaration would "pass" here and then fall back on the 403 of
// capacity downstream — the declarative refusal would lie about the cause.
// That rule used to live in the shell CALLERS (twice) and nowhere in Go.
//
// The shell mirror is deployer_group_policy() in scripts/lib/env-chain.sh —
// same table, same refusals, and TestDeployerPolicyMirror executes BOTH over
// one table so a divergence cannot survive a `go test` (ADR-083 regime).
func (g Gate) DeployerPolicy() (string, error) {
	dg := g.DeployerGroup
	switch {
	case strings.HasPrefix(dg, "apim-apply-") && dg != "apim-apply-":
		palier := strings.TrimPrefix(dg, "apim-apply-")
		if palier != g.To {
			return "", &deployerPalierMismatch{msg: fmt.Sprintf(
				"deployerGroup %q declared on gate %q: the apim-apply-<x> family must name the palier of its own gate (apim-apply-%s) — the projected policy %q does not open %q",
				dg, g.To, g.To, "apply-"+palier, g.To)}
		}
		return "apply-" + palier, nil
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

// deployerPalierMismatch marks the refusal of a deployerGroup of the
// apim-apply-<x> family whose <x> does not name the palier its gate guards.
type deployerPalierMismatch struct{ msg string }

func (e *deployerPalierMismatch) Error() string { return e.msg }

// IsDeployerPalierMismatch reports whether err is that refusal.
func IsDeployerPalierMismatch(err error) bool {
	var m *deployerPalierMismatch
	return errors.As(err, &m)
}
