// Package register blank-imports every gateway adapter so their package init()
// functions register a Factory with the adapter registry. main imports this one
// package instead of each adapter, keeping cmd/ decoupled from concrete drivers.
package register

import (
	_ "github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter/apisix"
	_ "github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter/webmethods"
	_ "github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter/wso2"
)
