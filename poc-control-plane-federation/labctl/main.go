// Command labctl is the thin federation control plane for the PoC.
//
// Define Once, Expose Everywhere:
//
//	labctl apply     -f targets.yaml   # publish one OpenAPI on N gateways
//	labctl apply-uac --repo <gov-repo> -f targets.yaml   # project the governance repo's published UAC contracts
//	labctl plan      -f targets.yaml   # preview apply (read-only): create|update|none per gateway
//	labctl subscribe -f targets.yaml   # provision a consumer + Keycloak client
//	labctl get apis  -f targets.yaml   # list what each gateway exposes
//
// Every verb takes -o/--output table|json; json prints one stable document on
// stdout (logs on stderr) for the governance BFF and CI.
package main

import (
	"fmt"
	"os"

	cmd "github.com/stoa-platform/stoa-labs/poc/labctl/cmd/labctl"

	// Register the gateway adapters (init() side-effects) so cmd can resolve a
	// target type without importing each adapter package.
	_ "github.com/stoa-platform/stoa-labs/poc/labctl/internal/register"
)

func main() {
	if err := cmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
