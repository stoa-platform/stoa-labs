package cmd

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/backstage"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/cli"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/openapi"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/targets"
)

var applyCmd = &cobra.Command{
	Use:   "apply",
	Short: "Publish the OpenAPI contract on every target gateway (Define Once, Expose Everywhere)",
	Long: "apply loads the single OpenAPI contract and dispatches it to every gateway in " +
		"targets.yaml through its adapter — the federation engine: one contract, N heterogeneous " +
		"runtimes. It also writes a Backstage catalog-info.yaml for the federated API.",
	RunE: runApply,
}

func init() {
	rootCmd.AddCommand(applyCmd)
}

type publishOutcome struct {
	name string
	typ  string
	res  *adapter.PublishResult
	err  error
}

func runApply(cmd *cobra.Command, _ []string) error {
	ctx := cmd.Context()
	out := cmd.OutOrStdout()

	tf, err := targets.Load(fileFlag)
	if err != nil {
		return err
	}
	api, err := openapi.Load(tf.Contract, tf.Name, tf.BackendURL)
	if err != nil {
		return err
	}

	fmt.Fprintf(out, "Define Once → Expose Everywhere: %q v%s → %d gateways\n", api.Name, api.Version, len(tf.Targets))
	fmt.Fprintf(out, "  contract: %s\n  backend:  %s\n\n", tf.Contract, backendOrPlaceholder(api.BackendURL))

	if api.BackendURL == "" {
		// No upstream resolved from targets.yaml backendUrl nor an absolute
		// servers[].url: gateways have nothing real to proxy to, so a "published"
		// status here can be a synthetic false positive (routes exist but the
		// data plane points nowhere). Surface it loudly.
		fmt.Fprintf(out, "  %s no backendUrl resolved (targets.yaml backendUrl empty and no absolute servers[].url) —\n", cli.FAIL)
		fmt.Fprintf(out, "    gateways have no real upstream to proxy to; a published status may be a synthetic false positive.\n\n")
	}

	// --- the dispatch loop: every target gets the SAME contract ---
	outcomes := make([]publishOutcome, 0, len(tf.Targets))
	endpoints := map[string]string{} // gateway -> live invocation URL (for Backstage)
	for _, t := range tf.Targets {
		oc := publishOutcome{name: t.Name, typ: t.Type}
		ad, err := adapter.New(t.ToConfig())
		if err != nil {
			oc.err = err
			outcomes = append(outcomes, oc)
			fmt.Fprintf(out, "  %s %-12s adapter: %v\n", cli.FAIL, t.Name, err)
			continue
		}
		if err := ad.Health(ctx); err != nil {
			oc.err = fmt.Errorf("health: %w", err)
			outcomes = append(outcomes, oc)
			fmt.Fprintf(out, "  %s %-12s unreachable: %v\n", cli.FAIL, t.Name, err)
			continue
		}
		res, err := ad.Publish(ctx, api)
		oc.res, oc.err = res, err
		outcomes = append(outcomes, oc)
		if err != nil {
			fmt.Fprintf(out, "  %s %-12s publish: %v\n", cli.FAIL, t.Name, err)
			continue
		}
		endpoints[ad.Name()] = res.InvocationURL
		fmt.Fprintf(out, "  %s %-12s %s\n", cli.OK, t.Name, res.InvocationURL)
	}

	// --- result table ---
	fmt.Fprintln(out)
	rows := make([][]string, 0, len(outcomes))
	failed := 0
	for _, o := range outcomes {
		if o.err != nil || o.res == nil {
			failed++
			rows = append(rows, []string{o.name, cli.FAIL, "", "", cli.Truncate(errStr(o.err), 48)})
			continue
		}
		created := "reused"
		if o.res.Created {
			created = "created"
		}
		rows = append(rows, []string{o.name, cli.OK, o.res.APIID, o.res.InvocationURL, created})
	}
	cli.Table(out, []string{"GATEWAY", "STATUS", "API ID", "INVOCATION URL", "STATE"}, rows)

	// --- Backstage federated entity (one API entity for all gateways) ---
	if len(endpoints) > 0 {
		writeBackstageEntity(cmd, tf, api, endpoints)
	}

	fmt.Fprintf(out, "\n%d/%d gateways published from one contract.\n", len(outcomes)-failed, len(outcomes))
	if failed > 0 {
		return fmt.Errorf("%d/%d gateways failed to publish", failed, len(outcomes))
	}
	return nil
}

// writeBackstageEntity renders the federated catalog-info.yaml next to the
// manifest and best-effort registers it with Backstage when reachable. Backstage
// itself is brought up in Phase 3, so registration failure is a SKIP, not an error.
func writeBackstageEntity(cmd *cobra.Command, tf *targets.File, api *adapter.NormalizedAPI, endpoints map[string]string) {
	out := cmd.OutOrStdout()

	manifestDir := filepath.Dir(fileFlag)
	specPath := backstageSpecPath(manifestDir, api.SpecPath)

	entity, err := backstage.GenerateEntity(backstage.EntityInput{
		Name:      api.Name,
		Owner:     tf.Backstage.Owner,
		System:    tf.Backstage.System,
		SpecPath:  specPath,
		Endpoints: endpoints,
	})
	if err != nil {
		fmt.Fprintf(out, "\n%s backstage entity: %v\n", cli.SKIP, err)
		return
	}
	dst := filepath.Join(manifestDir, "catalog-info.yaml")
	if err := os.WriteFile(dst, entity, 0o644); err != nil {
		fmt.Fprintf(out, "\n%s write %s: %v\n", cli.SKIP, dst, err)
		return
	}
	fmt.Fprintf(out, "\n%s Backstage entity written: %s (%d gateways federated)\n", cli.OK, dst, len(endpoints))
	if tf.Backstage.URL != "" {
		fmt.Fprintf(out, "%s Backstage live registration deferred to Phase 3 (serve %s and `labctl register`).\n", cli.SKIP, dst)
	}
}

func errStr(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

// backendOrPlaceholder renders the upstream URL, or an explicit "(none)" marker
// when no backend was resolved, so the header line never shows a misleading
// empty value next to "backend:".
func backendOrPlaceholder(backend string) string {
	if backend == "" {
		return "(none)"
	}
	return backend
}

// backstageSpecPath re-expresses specPath relative to manifestDir, the directory
// the catalog-info.yaml is written to. Backstage resolves definition.$text
// RELATIVE TO THE ENTITY LOCATION, and specPath (api.SpecPath) is the
// already-joined contract path (manifest-dir-relative or absolute), so passing
// it raw would double the manifest dir (e.g. `deploy/deploy/apis/x.yaml`). If
// Rel fails (e.g. an absolute contract on another volume) the original path is
// kept rather than emitting a broken relative reference.
func backstageSpecPath(manifestDir, specPath string) string {
	if rel, err := filepath.Rel(manifestDir, specPath); err == nil {
		return rel
	}
	return specPath
}
