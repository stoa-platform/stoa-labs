package cmd

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/backstage"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/cli"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/enforce"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/openapi"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/output"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/targets"
)

var applyCmd = &cobra.Command{
	Use:   "apply",
	Short: "Publish the OpenAPI contract on every target gateway (Define Once, Expose Everywhere)",
	Long: "apply loads the single OpenAPI contract and dispatches it to every gateway in " +
		"targets.yaml through its adapter — the federation engine: one contract, N heterogeneous " +
		"runtimes. It also writes a Backstage catalog-info.yaml for the federated API.\n\n" +
		"ENFORCEMENT (ADR-076): when a UAC contract (api.yaml) sits next to the manifest — or is " +
		"named via --uac — apply derives the required security bundle from its integrity " +
		"classification and FAIL-CLOSES the run twice: [INTEGRITY_UNFULFILLED] when a target does " +
		"not declare the knobs the bundle requires (static, nothing written), and " +
		"[ENFORCEMENT_UNCONFIRMED] when the gateway's read-back state does not confirm the bundle " +
		"after publish. There is no opt-out flag; an UNCONFIRMED verdict does not deactivate the " +
		"API (pipeline-level gate — remediation is the red pipeline + the reconcile report).",
	RunE: runApply,
}

func init() {
	applyCmd.Flags().StringVar(&uacFlag, "uac", "",
		"UAC contract (api.yaml) driving the enforcement gate; default: api.yaml colocated with the manifest")
	applyCmd.Flags().StringVar(&classificationSourceFlag, "classification-source", "",
		"central integrity-classification registry (ADR-076 A5); default env LABCTL_CLASSIFICATION_SOURCE. When set, the classification is AUTHORITATIVE from this registry, not the project api.yaml")
	applyCmd.Flags().StringVar(&projectFlag, "project", "",
		"non-editable project identity for the central-classification lookup; default env LABCTL_PROJECT (the pipeline's PROJECT_NAME)")
	rootCmd.AddCommand(applyCmd)
}

type publishOutcome struct {
	name        string
	typ         string
	res         *adapter.PublishResult
	err         error
	enforcement []adapter.PolicyVerdict
}

func runApply(cmd *cobra.Command, _ []string) error {
	ctx := cmd.Context()
	format, err := output.ParseFormat(outputFlag)
	if err != nil {
		return err
	}
	out := cmd.OutOrStdout()
	// In json mode stdout must carry the JSON document ONLY; every human
	// progress line moves to stderr. In table mode log == out, so the rendering
	// is byte-identical to the historical output.
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

	fmt.Fprintf(log, "Define Once → Expose Everywhere: %q v%s → %d gateways\n", api.Name, api.Version, len(tf.Targets))
	fmt.Fprintf(log, "  contract: %s\n  backend:  %s\n\n", tf.Contract, backendOrPlaceholder(api.BackendURL))

	// --- enforcement gate 1/2: static pre-check, BEFORE any write ------------
	enf, err := loadEnforcement(fileFlag, api.Name)
	if err != nil {
		return err
	}
	if enf != nil {
		for _, w := range enf.warnings {
			fmt.Fprintf(log, "  %s %s\n", cli.SKIP, w)
		}
		fmt.Fprintf(log, "Enforcement ADR-076 (%s): classification=%s exposure=%s → authn=%s policies=[%s]\n",
			enf.contractPath, enf.req.Classification, enf.req.Exposure, enf.req.Authn, strings.Join(enf.req.Policies, ", "))
		var violations []string
		for _, t := range tf.Targets {
			v, warns := enforce.PrecheckTarget(t, enf.req)
			for _, w := range warns {
				fmt.Fprintf(log, "  %s %s: %s\n", cli.SKIP, t.Name, w)
			}
			for _, x := range v {
				violations = append(violations, t.Name+": "+x)
			}
		}
		if len(violations) > 0 {
			for _, v := range violations {
				fmt.Fprintf(log, "  %s %s\n", cli.FAIL, v)
			}
			return fmt.Errorf("[%s] %d violation(s): le manifeste n'implémente pas le bundle dérivé de la classification %s — rien n'a été écrit",
				enforce.CodeUnfulfilled, len(violations), enf.req.Classification)
		}
		fmt.Fprintln(log)
	}

	if api.BackendURL == "" {
		// No upstream resolved from targets.yaml backendUrl nor an absolute
		// servers[].url: gateways have nothing real to proxy to, so a "published"
		// status here can be a synthetic false positive (routes exist but the
		// data plane points nowhere). Surface it loudly.
		fmt.Fprintf(log, "  %s no backendUrl resolved (targets.yaml backendUrl empty and no absolute servers[].url) —\n", cli.FAIL)
		fmt.Fprintf(log, "    gateways have no real upstream to proxy to; a published status may be a synthetic false positive.\n\n")
	}

	// --- the dispatch loop: every target gets the SAME contract ---
	outcomes := make([]publishOutcome, 0, len(tf.Targets))
	endpoints := map[string]string{} // target NAME -> live invocation URL (for Backstage)
	for _, t := range tf.Targets {
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
		if err != nil {
			outcomes = append(outcomes, oc)
			fmt.Fprintf(log, "  %s %-12s publish: %v\n", cli.FAIL, t.Name, err)
			continue
		}
		// --- enforcement gate 2/2: read-back AFTER publish -------------------
		// The gateway's LIVE state must confirm the derived bundle; a target
		// whose adapter cannot read it back is unverifiable, hence refused. The
		// API stays published and ACTIVE on failure (pipeline-level gate, no
		// auto-deactivate): remediation is the red pipeline + reconcile + human.
		if enf != nil {
			verdicts, verr := verifyTargetEnforcement(ctx, ad, res.APIID, enf.req)
			oc.enforcement = verdicts
			if verr != nil {
				oc.err = verr
				outcomes = append(outcomes, oc)
				fmt.Fprintf(log, "  %s %-12s %v\n", cli.FAIL, t.Name, verr)
				continue
			}
		}
		outcomes = append(outcomes, oc)
		// Key by the unique target NAME, not ad.Name() (the gateway TYPE): two
		// targets of the same type (e.g. wso2-prod + wso2-dr) must NOT collide
		// into one Backstage endpoint — that would silently drop a gateway.
		endpoints[t.Name] = res.InvocationURL
		fmt.Fprintf(log, "  %s %-12s %s\n", cli.OK, t.Name, res.InvocationURL)
	}

	// Full verdict table (never overclaim: enforced/degraded annotations are
	// printed, not just failures). Narration writer — stderr in JSON mode.
	if enf != nil {
		fmt.Fprintf(log, "\nEnforcement (read-back, jamais l'intention):\n")
		for _, o := range outcomes {
			for _, v := range o.enforcement {
				fmt.Fprintf(log, "  %-12s %-12s %-12s %s\n", o.name, v.Policy, v.Status, v.Detail)
			}
		}
	}

	// --- result (table for humans, one stable JSON document for machines) ---
	report := publishReport(outcomes)
	failed := 0
	for _, o := range outcomes {
		if o.err != nil || o.res == nil {
			failed++
		}
	}
	if format == output.FormatJSON {
		if err := output.WriteJSON(out, report); err != nil {
			return err
		}
	} else {
		fmt.Fprintln(out)
		rows := make([][]string, 0, len(outcomes))
		for _, o := range outcomes {
			if o.err != nil || o.res == nil {
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
	}

	// --- Backstage federated entity (one API entity for all gateways) ---
	if len(endpoints) > 0 {
		writeBackstageEntity(log, tf, api, endpoints)
	}

	fmt.Fprintf(log, "\n%d/%d gateways published from one contract.\n", len(outcomes)-failed, len(outcomes))
	if failed > 0 {
		return fmt.Errorf("%d/%d gateways failed to publish", failed, len(outcomes))
	}
	return nil
}

// publishReport projects the per-target dispatch outcomes onto the stable
// machine-readable shape shared with the governance BFF. Nothing the human
// table shows is dropped: gateway, status (error presence), api id, invocation
// URL and created/reused all survive — plus revision_id and published, which
// the table folds away.
func publishReport(outcomes []publishOutcome) output.PublishReport {
	r := output.PublishReport{OK: true, Targets: make([]output.PublishTarget, 0, len(outcomes))}
	for _, o := range outcomes {
		t := output.PublishTarget{Gateway: o.name, Type: o.typ}
		if o.err != nil || o.res == nil {
			r.OK = false
			t.Error = errStr(o.err)
		}
		if o.res != nil {
			t.APIID = o.res.APIID
			t.RevisionID = o.res.RevisionID
			t.InvocationURL = o.res.InvocationURL
			t.Published = o.res.Published
			t.Created = o.res.Created
		}
		// Additive enforcement block (absent when the gate is off) — the CI
		// contract (.ok/.targets[].created/api_id) is attribute-accessed, so new
		// keys are safe.
		for _, v := range o.enforcement {
			t.Enforcement = append(t.Enforcement, output.EnforcementVerdict{
				Policy: v.Policy, Status: v.Status, Detail: v.Detail,
			})
		}
		r.Targets = append(r.Targets, t)
	}
	return r
}

// writeBackstageEntity renders the federated catalog-info.yaml next to the
// manifest and best-effort registers it with Backstage when reachable. Backstage
// itself is brought up in Phase 3, so registration failure is a SKIP, not an error.
// out is the human log writer (stdout in table mode, stderr in json mode — the
// entity notes are progress narration, not part of the machine result).
func writeBackstageEntity(out io.Writer, tf *targets.File, api *adapter.NormalizedAPI, endpoints map[string]string) {
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
