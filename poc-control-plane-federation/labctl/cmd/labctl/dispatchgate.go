package cmd

// dispatch-gate closes the TOCTOU window of the production ITSM gate (ADR-075,
// goal A6). The governance gate (4-eyes + ITSM approved + pin) is evaluated at
// MERGE/BUILD time; a change approved then REVOKED before the operator hits
// "deploy" would otherwise sail through. This re-checks the ITSM status LIVE at
// the instant of dispatch — the same authoritative Go check whether it runs
// inside `apply-uac` (fail-closed before any gateway write) or as a standalone
// pipeline stage (`labctl dispatch-gate`, so the Jenkinsfile need not
// re-implement the check in shell — one source of truth).
//
// It anchors on the DISPATCHED STATE, not on "some approved promotion": it
// reads the change_ref recorded in deploy.{env}.yaml (written by the promotion
// that enabled the env) and re-checks THAT change. A gated env whose dispatched
// state carries no change_ref is refused fail-closed.

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/governance"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/uac"
)

// dispatchGateError is a typed failure of the dispatch gate so callers derive a
// PRECISE audit reason: an ITSM outage or a missing change_ref must never be
// archived as an "itsm revocation" (forensics, ADR-070 — review of the A6 design).
type dispatchGateError struct {
	Code string // ITSM_NOT_APPROVED | ITSM_UNAVAILABLE | ITSM_NOT_CONFIGURED | NO_CHANGE_REF | ENVCHAIN_INVALID
	Msg  string
}

func (e *dispatchGateError) Error() string { return e.Msg }

// dispatchGateReason maps a gate error to its audit reason (ADR-070). A
// non-gate error keeps a generic reason.
func dispatchGateReason(err error) string {
	var g *dispatchGateError
	if errors.As(err, &g) {
		switch g.Code {
		case "ITSM_NOT_APPROVED":
			return "itsm_not_approved_at_dispatch"
		case "ITSM_UNAVAILABLE":
			return "itsm_unavailable_at_dispatch"
		case "ITSM_NOT_CONFIGURED":
			return "itsm_not_configured_at_dispatch"
		case "NO_CHANGE_REF":
			return "no_change_ref_in_dispatched_state"
		case "ENVCHAIN_INVALID":
			return "envchain_invalid"
		}
	}
	return "dispatch_gate_error"
}

// loadGovChain reads the governance repo's environments.yaml WITH its gates
// (uac.LoadEnvChain deliberately parses only the env NAMES). Absent file → the
// historical default chain (no itsmCheck gate); present-but-broken → fail-closed.
func loadGovChain(repo string) (governance.EnvChain, error) {
	raw, err := os.ReadFile(filepath.Join(repo, governance.EnvChainPath))
	if os.IsNotExist(err) {
		return governance.DefaultEnvChain(), nil
	}
	if err != nil {
		return governance.EnvChain{}, &dispatchGateError{Code: "ENVCHAIN_INVALID", Msg: fmt.Sprintf("dispatch gate: read %s: %v", governance.EnvChainPath, err)}
	}
	c, err := governance.ParseEnvChain(raw)
	if err != nil {
		return governance.EnvChain{}, &dispatchGateError{Code: "ENVCHAIN_INVALID", Msg: fmt.Sprintf("dispatch gate: %v", err)}
	}
	return c, nil
}

// preflightDispatchGate re-checks the ITSM gate LIVE for every gated environment
// that this run would actually dispatch — a SINGLE pass BEFORE any gateway write,
// so one revoked change blocks the whole run with zero partial dispatch. The set
// of gated envs is derived from the repo's gate config and the contracts'
// enabled deploys, NOT from the caller's --env flag alone: `--env any` re-checks
// EVERY gated+enabled env (a concrete gated env re-checks itself), so the gate
// cannot be skipped by dropping the flag. ITSM_URL selects the ITSM (empty =
// fail-closed when a gated env is in scope). Results are cached per change_ref.
func preflightDispatchGate(ctx context.Context, gchain governance.EnvChain, apis []uac.API, scope, env string) error {
	itsm := governance.NewITSMClient(os.Getenv("ITSM_URL"))
	cache := map[string]string{} // change_ref -> live status (one GET per distinct change)
	for _, a := range apis {
		if !inScope(scope, a.Tenant) {
			continue
		}
		if _, skip := uacSkipReason(a, env, gchain.Envs); skip {
			continue // draft/deprecated, no enabled deploy for env, or llm-only — never dispatched
		}
		envs := []string{env}
		if env == uac.EnvAny {
			envs = a.EnabledEnvsIn(uac.EnvAny, gchain.Envs)
		}
		for _, e := range envs {
			gate, ok := gchain.Gates[e]
			if !ok || !gate.ITSMCheck {
				continue // env not ITSM-gated — nothing to re-check
			}
			d, ok := a.Deploys[e]
			if !ok || !d.Enabled {
				continue // not actually dispatched to this env
			}
			if d.ChangeRef == "" {
				return &dispatchGateError{Code: "NO_CHANGE_REF", Msg: fmt.Sprintf(
					"[NO_CHANGE_REF] %s/%s→%s: le gate exige itsmCheck mais deploy.%s.yaml ne porte aucun change_ref (état dispatché non rattaché à un change ITSM) — apply refusé fail-closed",
					a.Tenant, a.Slug, e, e)}
			}
			st, seen := cache[d.ChangeRef]
			if !seen {
				if itsm == nil {
					return &dispatchGateError{Code: "ITSM_NOT_CONFIGURED", Msg: fmt.Sprintf(
						"[503 ITSM_NOT_CONFIGURED] %s/%s→%s exige itsmCheck mais ITSM_URL est vide — refus par défaut (fail-closed)",
						a.Tenant, a.Slug, e)}
				}
				var err error
				st, err = itsm.ChangeStatus(ctx, d.ChangeRef)
				if err != nil {
					return &dispatchGateError{Code: "ITSM_UNAVAILABLE", Msg: fmt.Sprintf(
						"[503 ITSM_UNAVAILABLE] %s/%s→%s: ITSM injoignable pour le change %s (%v) — refus par défaut",
						a.Tenant, a.Slug, e, d.ChangeRef, err)}
				}
				cache[d.ChangeRef] = st
			}
			if st != "approved" {
				return &dispatchGateError{Code: "ITSM_NOT_APPROVED", Msg: fmt.Sprintf(
					"[409 ITSM_NOT_APPROVED] %s/%s→%s: le change %s est %q à l'instant du dispatch (approuvé au merge, révoqué depuis) — AUCUN apply",
					a.Tenant, a.Slug, e, d.ChangeRef, st)}
			}
		}
	}
	return nil
}

// --- standalone subcommand (pipeline stage) ---------------------------------

var (
	dgRepoFlag   string
	dgEnvFlag    string
	dgTenantFlag string
)

var dispatchGateCmd = &cobra.Command{
	Use:   "dispatch-gate",
	Short: "Re-check the ITSM gate LIVE at dispatch time (anti-TOCTOU, ADR-075/A6)",
	Long: "dispatch-gate re-validates the production ITSM gate at the INSTANT of dispatch — the " +
		"authoritative Go check `apply-uac` runs internally, exposed as a standalone pipeline stage so " +
		"Jenkinsfile.prod need not re-implement it in shell. It reads the change_ref recorded in " +
		"deploy.{env}.yaml (the dispatched state) and refuses the deploy fail-closed when that change is " +
		"no longer approved in the ITSM (409), when the ITSM is unreachable/unset (503), or when a gated " +
		"state carries no change_ref. Exit 0 = still approved.",
	RunE: runDispatchGate,
}

func init() {
	dispatchGateCmd.Flags().StringVar(&dgRepoFlag, "repo", "", "governance repo path (tenants/{tenant}/apis/{slug}/deploy.{env}.yaml + environments.yaml)")
	dispatchGateCmd.Flags().StringVar(&dgEnvFlag, "env", "", "environment to gate (a concrete env; any = every gated+enabled env)")
	dispatchGateCmd.Flags().StringVar(&dgTenantFlag, "tenant", "", "restrict to this tenant (default $LABCTL_TENANT)")
	_ = dispatchGateCmd.MarkFlagRequired("repo")
	_ = dispatchGateCmd.MarkFlagRequired("env")
	rootCmd.AddCommand(dispatchGateCmd)
}

func runDispatchGate(cmd *cobra.Command, _ []string) error {
	ctx := cmd.Context()
	gchain, err := loadGovChain(dgRepoFlag)
	if err != nil {
		return err
	}
	if dgEnvFlag != uac.EnvAny && !uac.ValidEnvIn(dgEnvFlag, gchain.Envs) {
		return fmt.Errorf("dispatch-gate: unsupported --env %q (supported: %s, any)", dgEnvFlag, strings.Join(gchain.Envs, ", "))
	}
	apis, err := uac.LoadRepo(dgRepoFlag)
	if err != nil {
		return err
	}
	scope := dgTenantFlag
	if scope == "" {
		scope = strings.TrimSpace(os.Getenv("LABCTL_TENANT"))
	}
	if err := preflightDispatchGate(ctx, gchain, apis, scope, dgEnvFlag); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "dispatch gate OK — ITSM re-checké approved au dispatch (env %s, repo %s)\n", dgEnvFlag, dgRepoFlag)
	return nil
}
