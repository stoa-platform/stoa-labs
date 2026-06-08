// Package cmd implements the labctl CLI: a thin, kubectl-style orchestrator that
// publishes one OpenAPI contract across N heterogeneous gateways
// ("Define Once, Expose Everywhere") and provisions consumers + Keycloak clients.
package cmd

import (
	"github.com/spf13/cobra"
)

// Version is over/under-written at build time (-ldflags) or kept as the default.
var Version = "0.1.0-poc"

// fileFlag is the federation manifest path, shared by apply/subscribe/get.
var fileFlag string

var rootCmd = &cobra.Command{
	Use:   "labctl",
	Short: "labctl — thin federation control plane for the PoC",
	Long: "labctl publishes a single OpenAPI contract across heterogeneous API " +
		"gateways (WSO2, Apache APISIX, webMethods) from one targets.yaml, and " +
		"provisions consumers with an out-of-band Keycloak OAuth client.\n\n" +
		"This is a PoC demonstrator (scaffold), not a product — see POSITIONING.md.",
	SilenceUsage: true,
	// main prints the error once on stderr; don't let cobra also print it.
	SilenceErrors: true,
}

func init() {
	rootCmd.PersistentFlags().StringVarP(&fileFlag, "file", "f", "targets.yaml",
		"federation manifest (targets.yaml)")
}

// Execute runs the root command.
func Execute() error {
	return rootCmd.Execute()
}
