package cmd

import (
	"context"
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/cli"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/openapi"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/output"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/targets"
)

var planCmd = &cobra.Command{
	Use:   "plan",
	Short: "Preview what apply would change on every gateway, without touching anything",
	Long: "plan compares the desired contract (the manifest's normalized API) with what each " +
		"gateway currently exposes (Adapter.List) and reports the action apply would take per " +
		"target: create, update or none. It is strictly read-only — nothing is published, no " +
		"consumer is provisioned. An unreachable gateway is reported as action \"unknown\" with " +
		"the network error as reason; the plan is a report, so the exit code stays 0.",
	RunE: runPlan,
}

func init() {
	rootCmd.AddCommand(planCmd)
}

func runPlan(cmd *cobra.Command, _ []string) error {
	ctx := cmd.Context()
	format, err := output.ParseFormat(outputFlag)
	if err != nil {
		return err
	}
	out := cmd.OutOrStdout()
	// In json mode stdout must carry the JSON document ONLY; human progress
	// lines move to stderr. In table mode log == out.
	log := out
	if format == output.FormatJSON {
		log = cmd.ErrOrStderr()
	}

	tf, err := loadResolvedTargets(ctx, fileFlag)
	if err != nil {
		return err
	}
	api, err := openapi.Load(tf.Contract, tf.Name, tf.BackendURL)
	if err != nil {
		return err
	}

	fmt.Fprintf(log, "Plan (read-only): %q v%s against %d gateways\n\n", api.Name, api.Version, len(tf.Targets))

	report := output.PlanReport{OK: true, Targets: make([]output.PlanTarget, 0, len(tf.Targets))}
	for _, t := range tf.Targets {
		pt := output.PlanTarget{Gateway: t.Name, Type: t.Type}
		pt.Action, pt.Reason = planTarget(ctx, t, api)
		if pt.Action == output.ActionUnknown {
			// The gateway could not be assessed — surface it in OK for machine
			// consumers, but NEVER in the exit code: the plan is a report.
			report.OK = false
		}
		report.Targets = append(report.Targets, pt)
	}

	if format == output.FormatJSON {
		if err := output.WriteJSON(out, report); err != nil {
			return err
		}
	} else {
		rows := make([][]string, 0, len(report.Targets))
		for _, pt := range report.Targets {
			rows = append(rows, []string{pt.Gateway, pt.Action, pt.Reason})
		}
		cli.Table(out, []string{"GATEWAY", "ACTION", "REASON"}, rows)
	}

	fmt.Fprintf(log, "\nplan changed nothing — run `labctl apply -f %s` to converge.\n", fileFlag)
	return nil
}

// planTarget resolves one target's adapter, lists its current catalog and
// decides the action. Resolution/network failures degrade to "unknown" — the
// gateway may be temporarily down, and a plan must stay a faithful report, not
// a gate.
func planTarget(ctx context.Context, t targets.Target, api *adapter.NormalizedAPI) (action, reason string) {
	ad, err := adapter.New(t.ToConfig())
	if err != nil {
		return output.ActionUnknown, "adapter: " + err.Error()
	}
	existing, err := ad.List(ctx)
	if err != nil {
		return output.ActionUnknown, err.Error()
	}
	return planAction(api, existing)
}

// planAction compares the desired NormalizedAPI with one gateway's current
// listing — the read-only mirror of what Publish's Created flag reports after
// the fact. Match key is the API Name (the stable slug every adapter publishes
// under); among same-name entries, an exact (version, basePath) hit means
// "none", anything else means "update". No name hit means "create".
func planAction(desired *adapter.NormalizedAPI, existing []adapter.PublishedAPI) (action, reason string) {
	var named []adapter.PublishedAPI
	for _, a := range existing {
		if a.Name == desired.Name {
			named = append(named, a)
		}
	}
	if len(named) == 0 {
		return output.ActionCreate, fmt.Sprintf("API %q not present on this gateway", desired.Name)
	}
	for _, a := range named {
		if a.Version == desired.Version && a.BasePath == desired.BasePath {
			return output.ActionNone, fmt.Sprintf("API %q v%s already published (id %s)", a.Name, a.Version, a.APIID)
		}
	}
	// Describe the drift against the first same-name entry (gateways with one
	// API per name — the labctl model — have exactly one).
	a := named[0]
	var diffs []string
	if a.Version != desired.Version {
		diffs = append(diffs, fmt.Sprintf("version %s → %s", a.Version, desired.Version))
	}
	if a.BasePath != desired.BasePath {
		diffs = append(diffs, fmt.Sprintf("basePath %s → %s", a.BasePath, desired.BasePath))
	}
	return output.ActionUpdate, fmt.Sprintf("API %q exists (id %s) but drifts: %s",
		a.Name, a.APIID, strings.Join(diffs, ", "))
}
