package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
	"sigs.k8s.io/yaml"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/governance"
)

var validatePublished bool

var validateCmd = &cobra.Command{
	Use:   "validate [api.yaml]",
	Short: "Validate a UAC contract (api.yaml) against the v1 rules — read-only, no gateway",
	Long: "validate re-checks a UAC contract file (the load-bearing subset of " +
		"uac_contract_v1_schema.json: required fields, enums incl. classification VH/H/M and " +
		"exposure internal/external, name/version patterns, and the destructive=>approval and " +
		"published=>endpoint, and integrity-consistency semantic rules — the last requires that " +
		"classification+exposure+tags yield a valid security posture, fail-closed via render). " +
		"Strictly local — it never touches a gateway. " +
		"A contract with status=published is checked with the publication gate automatically; " +
		"--published forces it. Exit 1 on any violation.\n\n" +
		"Path resolution: the positional argument wins, else the shared -f/--file flag.",
	Args: cobra.MaximumNArgs(1),
	RunE: runValidate,
}

func init() {
	validateCmd.Flags().BoolVar(&validatePublished, "published", false,
		"apply the publication gate (contract must expose >=1 endpoint)")
	rootCmd.AddCommand(validateCmd)
}

func runValidate(cmd *cobra.Command, args []string) error {
	path := fileFlag
	if len(args) == 1 {
		path = args[0]
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read %s: %w", path, err)
	}
	var contract map[string]any
	if err := yaml.Unmarshal(raw, &contract); err != nil {
		return fmt.Errorf("parse %s: %w", path, err)
	}

	// A published contract is always held to the publication gate; --published
	// forces it for a draft (pre-flight check before promotion).
	published := validatePublished
	if s, _ := contract["status"].(string); s == "published" {
		published = true
	}

	errs := governance.ValidateUAC(contract, published)
	if len(errs) == 0 {
		fmt.Fprintf(cmd.OutOrStdout(), "OK: %s is a valid UAC contract\n", path)
		return nil
	}
	fmt.Fprintf(cmd.ErrOrStderr(), "INVALID: %s — %d error(s):\n", path, len(errs))
	for _, e := range errs {
		fmt.Fprintf(cmd.ErrOrStderr(), "  - [%s] %s: %s\n", e.Code, e.Path, e.Message)
	}
	return fmt.Errorf("%d validation error(s) in %s", len(errs), path)
}
