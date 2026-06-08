// Command labctl is the thin federation control plane for the PoC.
//
// Define Once, Expose Everywhere:
//
//	labctl apply     -f targets.yaml   # publish one OpenAPI on N gateways
//	labctl subscribe -f targets.yaml   # provision a consumer + Keycloak client
//	labctl get apis  -f targets.yaml   # list what each gateway exposes
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
