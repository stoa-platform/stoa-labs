package cmd

import (
	"context"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/spf13/cobra"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/audit"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/cli"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/output"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/targets"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/uac"
)

var applyUACCmd = &cobra.Command{
	Use:   "apply-uac",
	Short: "Project the governance repo's published UAC contracts onto every target gateway",
	Long: "apply-uac is the Console→CI→federation bridge: it scans a GOVERNANCE repo " +
		"(tenants/{tenant}/apis/{slug}/api.yaml UAC v1 contracts + deploy.{env}.yaml markers), keeps " +
		"the published contracts holding an enabled deploy for --env (any = every enabled " +
		"environment), projects each one onto the gateway-agnostic NormalizedAPI and dispatches it " +
		"to every gateway in targets.yaml — the same engine, error semantics and exit code as " +
		"apply. The manifest is reused ONLY for its gateway fleet: its contract/backendUrl fields " +
		"belong to the OpenAPI flow and are deliberately ignored here (the governance repo is the " +
		"source of truth). Draft/deprecated contracts and disabled deploys are reported as skipped.",
	RunE: runApplyUAC,
}

// uacRepoFlag / uacEnvFlag are apply-uac's own flags; the manifest (-f) and the
// output format (-o) stay the shared persistent flags.
var (
	uacRepoFlag   string
	uacEnvFlag    string
	uacTenantFlag string
)

func init() {
	applyUACCmd.Flags().StringVar(&uacRepoFlag, "repo", "",
		"governance repo path (tenants/{tenant}/apis/{slug}/api.yaml + deploy.{env}.yaml)")
	applyUACCmd.Flags().StringVar(&uacEnvFlag, "env", uac.EnvAny,
		"environment gate: one env of the repo's chain (environments.yaml, default dev|staging|production) "+
			"or any. A concrete env resolves the PINNED contract version (deploy.{env}.commit); "+
			"any is the HEAD inventory view (drift surfaced as warnings)")
	applyUACCmd.Flags().StringVar(&uacTenantFlag, "tenant", "",
		"restrict apply to this tenant's contracts (default $LABCTL_TENANT). When $LABCTL_TOKEN "+
			"is a cp-applier token, the scope is BOUND to its tenant and a mismatching --tenant is denied")
	_ = applyUACCmd.MarkFlagRequired("repo")
	rootCmd.AddCommand(applyUACCmd)
}

// uacAPIReport is one UAC contract's slice of the apply-uac report: the
// governance coordinates (tenant/api) WRAP the unchanged apply per-target
// contract — the embedded output.PublishReport keeps its stable
// {ok, targets:[{gateway, type, ...}]} shape verbatim, so consumers of the
// apply JSON can read each entry without a new schema. Skipped contracts keep
// ok=true with an empty (non-null) targets array and carry the reason.
type uacAPIReport struct {
	Tenant   string   `json:"tenant"`
	API      string   `json:"api"`
	Version  string   `json:"version,omitempty"`
	BasePath string   `json:"base_path,omitempty"`
	Envs     []string `json:"envs,omitempty"`
	Skipped  bool     `json:"skipped,omitempty"`
	Reason   string   `json:"reason,omitempty"`
	output.PublishReport
}

// uacReport is the apply-uac aggregate: OK is true only when every dispatched
// gateway of every projected contract published.
type uacReport struct {
	OK   bool           `json:"ok"`
	Env  string         `json:"env"`
	APIs []uacAPIReport `json:"apis"`
}

func runApplyUAC(cmd *cobra.Command, _ []string) error {
	ctx := cmd.Context()
	format, err := output.ParseFormat(outputFlag)
	if err != nil {
		return err
	}
	if uacRepoFlag == "" {
		return fmt.Errorf("apply-uac: --repo (governance repo path) is required")
	}
	// The env chain is the repo's environments.yaml (absent → the default
	// dev/staging/production) — --env is validated against THAT chain.
	chain, err := uac.LoadEnvChain(uacRepoFlag)
	if err != nil {
		return fmt.Errorf("apply-uac: %w", err)
	}
	if !uac.ValidEnvIn(uacEnvFlag, chain) {
		return fmt.Errorf("apply-uac: unsupported --env %q (supported: %s, any)", uacEnvFlag, strings.Join(chain, ", "))
	}

	out := cmd.OutOrStdout()
	// Same stdout contract as apply: in json mode stdout carries the JSON
	// document ONLY; narration moves to stderr. In table mode log == out.
	log := out
	if format == output.FormatJSON {
		log = cmd.ErrOrStderr()
	}
	// Projection warnings (multi-backend, version drift) ALWAYS go to stderr:
	// they must survive table mode without corrupting the table and json mode
	// without polluting the document.
	warn := cmd.ErrOrStderr()

	tf, err := loadResolvedTargets(ctx, fileFlag)
	if err != nil {
		return err
	}
	apis, err := uac.LoadRepo(uacRepoFlag)
	if err != nil {
		return err
	}

	fmt.Fprintf(log, "Governance → Federation: %d UAC contracts (env %s) → %d gateways\n\n",
		len(apis), uacEnvFlag, len(tf.Targets))

	// --- tenant scoping (mediation): bind this apply run to ONE tenant on the
	// shared gateways. A cp-applier LABCTL_TOKEN binds the scope cryptographically;
	// --tenant / $LABCTL_TENANT narrows it; neither is the unscoped operator path.
	tenantSel := uacTenantFlag
	if tenantSel == "" {
		tenantSel = strings.TrimSpace(os.Getenv("LABCTL_TENANT"))
	}
	prin, err := resolvePrincipal(ctx, applyVerifier(), applyToken())
	if err != nil {
		return err
	}
	auditor := newApplyAuditor(uacRepoFlag, prin, warn)
	scope, err := resolveScope(prin, tenantSel)
	if err != nil {
		// The cross-tenant escalation IS the security event: audit the DENY before
		// failing (fail-closed, before any dispatch).
		auditor.record(ctx, audit.Event{
			Actor: auditor.actorFor(""), Action: audit.ActionApply,
			Tenant: prin.Tenant, Resource: tenantSel,
			Decision: audit.Deny, Reason: "cross_tenant", TraceID: audit.NewTraceID(),
		})
		return err
	}
	if prin.OK {
		fmt.Fprintf(log, "principal: %s (cp-applier, tenant %s)\n", prin.Actor, prin.Tenant)
	}
	if scope == "" {
		fmt.Fprintf(warn, "warning: apply-uac is UNSCOPED (every tenant). On a shared gateway, pass --tenant or a cp-applier $LABCTL_TOKEN to bind the run to one tenant.\n")
	} else {
		fmt.Fprintf(log, "tenant scope: %s\n\n", scope)
	}

	report := uacReport{OK: true, Env: uacEnvFlag, APIs: make([]uacAPIReport, 0, len(apis))}
	var rows [][]string
	published, total, projected, skipped := 0, 0, 0, 0
	for _, a := range apis {
		ar := uacAPIReport{Tenant: a.Tenant, API: a.Slug}
		ar.PublishReport = output.PublishReport{OK: true, Targets: []output.PublishTarget{}}

		// Tenant scope gate (mediation): a contract outside the bound tenant is
		// never dispatched — the run cannot mutate another tenant's resources on
		// the shared gateway, even holding the platform admin credential.
		if !inScope(scope, a.Tenant) {
			skipped++
			ar.Skipped, ar.Reason = true, fmt.Sprintf("out of tenant scope %q", scope)
			report.APIs = append(report.APIs, ar)
			fmt.Fprintf(log, "%s %s/%s skipped: out of tenant scope (%s)\n\n", cli.SKIP, a.Tenant, a.Slug, scope)
			continue
		}

		if reason, skip := uacSkipReason(a, uacEnvFlag, chain); skip {
			skipped++
			ar.Skipped, ar.Reason = true, reason
			report.APIs = append(report.APIs, ar)
			fmt.Fprintf(log, "%s %s/%s skipped: %s\n\n", cli.SKIP, a.Tenant, a.Slug, reason)
			continue
		}

		envs := a.EnabledEnvsIn(uacEnvFlag, chain)
		// Version pinning: for a CONCRETE env whose deploy carries a commit pin,
		// project the contract AS APPROVED by the gate (git show), not HEAD — the
		// pin replaces the drift warning. --env any stays the HEAD inventory view
		// with drift surfaced as warnings.
		if uacEnvFlag != uac.EnvAny && a.Deploys[uacEnvFlag].Commit != "" {
			if err := uac.ResolvePinned(uacRepoFlag, &a, uacEnvFlag); err != nil {
				// A pinned env that cannot be resolved is a governance repo defect:
				// fail loudly rather than silently serving HEAD (fail-closed).
				return err
			}
			fmt.Fprintf(log, "%s/%s pinned: %s\n", a.Tenant, a.Slug, sha7(a.Deploys[uacEnvFlag].Commit))
		} else {
			for _, w := range a.DriftWarnings(envs) {
				fmt.Fprintf(warn, "warning: %s/%s: %s\n", a.Tenant, a.Slug, w)
			}
		}
		api, warns, err := a.Project()
		if err != nil {
			// A published+enabled contract that cannot be projected is a
			// governance repo defect: fail loudly, like apply does on a broken
			// OpenAPI contract.
			return err
		}
		for _, w := range warns {
			fmt.Fprintf(warn, "warning: %s/%s: %s\n", a.Tenant, a.Slug, w)
		}
		projected++
		ar.Version, ar.BasePath, ar.Envs = api.Version, api.BasePath, envs

		// --- the dispatch: every target gets this projected contract ---
		fmt.Fprintf(log, "%s/%s v%s → %s (envs: %s)\n",
			a.Tenant, a.Slug, api.Version, api.BasePath, strings.Join(envs, ", "))
		outcomes := dispatchPublish(ctx, log, tf.Targets, api)
		fmt.Fprintln(log)

		// Audit every gateway mutation (ADR-070): one event per (tenant, gateway,
		// api), Git-attributed (ADR-069: actor = the manifest's commit author),
		// correlated by a per-contract trace_id (the OpenSearch↔OTel pivot).
		author, sha := auditor.commitFor(a.Path)
		traceID := audit.NewTraceID()
		for _, o := range outcomes {
			dec, reason := audit.Accept, "ok"
			if o.err != nil || o.res == nil {
				dec, reason = audit.Deny, "publish_failed"
			}
			auditor.record(ctx, audit.Event{
				Actor: auditor.actorFor(author), Action: audit.ActionPublish,
				Tenant: a.Tenant, Resource: a.Slug, Gateway: o.name,
				Decision: dec, Reason: reason, CommitSHA: sha, TraceID: traceID,
			})
		}

		ar.PublishReport = publishReport(outcomes)
		if !ar.PublishReport.OK {
			report.OK = false
		}
		total += len(outcomes)
		for _, o := range outcomes {
			if o.err != nil || o.res == nil {
				rows = append(rows, []string{a.Tenant, a.Slug, o.name, cli.FAIL, "", "", cli.Truncate(errStr(o.err), 48)})
				continue
			}
			published++
			created := "reused"
			if o.res.Created {
				created = "created"
			}
			rows = append(rows, []string{a.Tenant, a.Slug, o.name, cli.OK, o.res.APIID, o.res.InvocationURL, created})
		}
		report.APIs = append(report.APIs, ar)
	}

	// --- result (table for humans, one stable JSON document for machines) ---
	if format == output.FormatJSON {
		if err := output.WriteJSON(out, report); err != nil {
			return err
		}
	} else if len(rows) > 0 {
		cli.Table(out, []string{"TENANT", "API", "GATEWAY", "STATUS", "API ID", "INVOCATION URL", "STATE"}, rows)
	}

	fmt.Fprintf(log, "\n%d/%d gateway publications from %d projected UAC contracts (%d skipped).\n",
		published, total, projected, skipped)
	if failed := total - published; failed > 0 {
		// Same error shape and exit semantics as apply: partial failures still
		// publish the rest, then fail the process for CI.
		return fmt.Errorf("%d/%d gateways failed to publish", failed, total)
	}
	return nil
}

// uacSkipReason decides whether one governed API is projectable for env, and
// why not: only published contracts (draft/deprecated skip), with at least one
// enabled deploy matching --env, and with REST endpoints to project (llm-only
// contracts target the MCP plane). A skip is narration, never an error.
func uacSkipReason(a uac.API, env string, chain []string) (string, bool) {
	if a.Contract.Status != uac.StatusPublished {
		return fmt.Sprintf("status=%s (only published contracts are projected)", a.Contract.Status), true
	}
	if len(a.EnabledEnvsIn(env, chain)) == 0 {
		if env == uac.EnvAny {
			return "no enabled deploy in any environment", true
		}
		return fmt.Sprintf("no enabled deploy for env %s", env), true
	}
	if len(a.Contract.Endpoints) == 0 {
		return "no REST endpoints to project (llm-only contract)", true
	}
	return "", false
}

// sha7 shortens a commit SHA for narration.
func sha7(sha string) string {
	if len(sha) > 7 {
		return sha[:7]
	}
	return sha
}

// dispatchPublish runs one projected API through the registry-resolved adapter
// of every target — the same loop, per-gateway diagnostics and partial-failure
// semantics as runApply, minus the Backstage entity step (a UAC projection has
// no on-disk OpenAPI contract for catalog-info.yaml to reference).
func dispatchPublish(ctx context.Context, log io.Writer, tgts []targets.Target, api *adapter.NormalizedAPI) []publishOutcome {
	outcomes := make([]publishOutcome, 0, len(tgts))
	for _, t := range tgts {
		oc := publishOutcome{name: t.Name, typ: t.Type}
		ad, err := adapter.New(t.ToConfig())
		if err != nil {
			oc.err = err
			outcomes = append(outcomes, oc)
			fmt.Fprintf(log, "  %s %-12s adapter: %v\n", cli.FAIL, t.Name, err)
			continue
		}
		if err := ad.Health(ctx); err != nil {
			oc.err = fmt.Errorf("health: %w", err)
			outcomes = append(outcomes, oc)
			fmt.Fprintf(log, "  %s %-12s unreachable: %v\n", cli.FAIL, t.Name, err)
			continue
		}
		res, err := ad.Publish(ctx, api)
		oc.res, oc.err = res, err
		outcomes = append(outcomes, oc)
		if err != nil {
			fmt.Fprintf(log, "  %s %-12s publish: %v\n", cli.FAIL, t.Name, err)
			continue
		}
		fmt.Fprintf(log, "  %s %-12s %s\n", cli.OK, t.Name, res.InvocationURL)
	}
	return outcomes
}
