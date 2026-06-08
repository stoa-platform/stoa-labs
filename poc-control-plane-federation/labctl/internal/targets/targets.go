// Package targets loads the labctl federation manifest (targets.yaml) and
// projects each target onto an adapter.Config. It is the single source of truth
// for "which gateways, at which URLs, with which knobs".
package targets

import "github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"

// File is the parsed targets.yaml.
type File struct {
	APIVersion string `json:"apiVersion"`
	Kind       string `json:"kind"`

	// Name optionally overrides the API name (else derived from the contract
	// title). Keeps WSO2 context / APISIX ids / Backstage entity name aligned.
	Name string `json:"name"`

	// Contract is the path to the single OpenAPI document ("Define Once").
	Contract string `json:"contract"`

	// BackendURL is the authoritative upstream the gateways proxy to.
	BackendURL string `json:"backendUrl"`

	Targets   []Target  `json:"targets"`
	Keycloak  Keycloak  `json:"keycloak"`
	Backstage Backstage `json:"backstage"`
}

// Target is one gateway entry.
type Target struct {
	Name       string `json:"name"`
	Type       string `json:"type"`
	AdminURL   string `json:"adminUrl"`
	GatewayURL string `json:"gatewayUrl"`
	Insecure   bool   `json:"insecure"`

	// WSO2-specific.
	GatewayEnv string `json:"gatewayEnv"`
	Vhost      string `json:"vhost"`

	// APISIX-specific data-plane consumer auth: "jwt-auth" | "key-auth".
	ConsumerAuth string `json:"consumerAuth"`

	Credentials map[string]string `json:"credentials"`
}

// Keycloak holds the out-of-band OAuth client settings used by `labctl subscribe`.
type Keycloak struct {
	URL   string `json:"url"`
	Realm string `json:"realm"`
	Admin struct {
		Username string `json:"username"`
		Password string `json:"password"`
	} `json:"admin"`
	ConsumerClientID     string `json:"consumerClientId"`
	ConsumerClientSecret string `json:"consumerClientSecret"`
}

// Backstage holds catalog registration settings (Phase 3).
type Backstage struct {
	URL    string `json:"url"`
	Owner  string `json:"owner"`
	System string `json:"system"`
}

// ToConfig projects a Target onto the adapter construction Config, folding the
// adapter-specific knobs into Options.
func (t Target) ToConfig() adapter.Config {
	return adapter.Config{
		Type:        t.Type,
		Name:        t.Name,
		AdminURL:    t.AdminURL,
		GatewayURL:  t.GatewayURL,
		Credentials: t.Credentials,
		Insecure:    t.Insecure,
		Options: map[string]string{
			"gatewayEnv":   t.GatewayEnv,
			"vhost":        t.Vhost,
			"consumerAuth": t.ConsumerAuth,
		},
	}
}
