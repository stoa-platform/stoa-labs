package cmd

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/render"
)

var renderCmd = &cobra.Command{
	Use:   "render [api.yaml]",
	Short: "Derive the required security-policy bundle from a contract's integrity classification (ADR-076)",
	Long: "render turns 'security = f(integrity)' into a machine-derived, fail-closed fact: it reads a UAC " +
		"contract's classification (+ exposure/tags) and prints the required_policies bundle the gateway must " +
		"enforce — VH -> oauth2+mtls, H/M -> oauth2, M+auth-exception:apikey (internal) -> apikey; external adds " +
		"ip-allowlist; every tier gets rate-limit + audit-log. FAIL-CLOSED: an unknown classification or an " +
		"inconsistent apikey exception exits 1 — a project cannot ship a posture weaker than its integrity level. " +
		"Read-only; never touches a gateway.\n\nPath: the positional argument wins, else the shared -f/--file flag.",
	Args: cobra.MaximumNArgs(1),
	RunE: runRender,
}

func init() {
	rootCmd.AddCommand(renderCmd)
}

func runRender(cmd *cobra.Command, args []string) error {
	path := fileFlag
	if len(args) == 1 {
		path = args[0]
	}
	// Same loader as the apply-side enforcement gate: both read the SAME
	// contract subset the same way (render.LoadContract).
	c, err := render.LoadContract(path)
	if err != nil {
		return err
	}

	res, err := render.Derive(c.Input())
	if err != nil {
		// Fail-closed: a contract whose integrity level yields no valid bundle
		// must not merge. Surface on stderr, exit non-zero.
		fmt.Fprintf(cmd.ErrOrStderr(), "RENDER REJECTED: %s (%s): %v\n", c.Name, path, err)
		return fmt.Errorf("render rejected %s", path)
	}

	// Effective exposure: render.Derive defaults an empty exposure to "internal";
	// report that so the shown exposure matches the derived bundle.
	effExposure := render.EffectiveExposure(c.Exposure)

	out := cmd.OutOrStdout()
	if outputFlag == "json" {
		enc := json.NewEncoder(out)
		enc.SetIndent("", "  ")
		return enc.Encode(map[string]any{
			"name":              c.Name,
			"classification":    c.Classification,
			"exposure":          effExposure,
			"authn":             res.Authn,
			"required_policies": res.RequiredPolicies,
		})
	}
	fmt.Fprintf(out, "%s [classification=%s exposure=%s] -> authn=%s\n",
		c.Name, c.Classification, effExposure, res.Authn)
	fmt.Fprintf(out, "required_policies: %s\n", strings.Join(res.RequiredPolicies, ", "))
	return nil
}
