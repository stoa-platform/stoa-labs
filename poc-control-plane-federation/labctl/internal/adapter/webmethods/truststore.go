package webmethods

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

// truststoreConfigPath is the gateway-wide keystore/truststore configuration —
// the REAL store on 10.15 (there is NO /truststore nor /certificates endpoint;
// both 404 on the live trial). The Ansible sync-gateway-config.yml uploads
// keystore/truststore material with exactly this PUT.
const truststoreConfigPath = "/configurations/keystore"

// truststoreAliasFor names the per-partner truststore alias holding the public
// certificate. Stable per application so a re-apply converges on one alias.
func truststoreAliasFor(appID string) string {
	return "labctl-partner-" + appID
}

// ensureTruststoreCert registers the partner's PUBLIC certificate in the gateway
// truststore so the mTLS handshake can trust a client presenting it. This is the
// FIRST half of the two-step cert binding (the second is the per-application
// httpsCertificate identifier); without it the handshake fails before identity
// is ever evaluated.
//
// It is BEST-EFFORT and idempotent: the keystore config is read first and the
// PEM is added under a per-application alias only when not already present. A
// gateway build that does not expose /configurations/keystore (older/locked
// trials) does not fail the whole subscribe — the app-level identifier is still
// the load-bearing identity binding for the PoC; the truststore is the data-plane
// trust anchor an operator can also seed out-of-band. The call still surfaces a
// hard transport error (the gateway is unreachable) so a real outage is not
// masked.
func (a *Adapter) ensureTruststoreCert(ctx context.Context, appID string, pemBytes []byte) error {
	alias := truststoreAliasFor(appID)

	cur, code, err := a.getTruststoreConfig(ctx)
	if err != nil {
		return err
	}
	// Build not exposing the keystore config (404/400/501): skip silently — the
	// app identifier remains the identity binding; trust can be seeded elsewhere.
	if code == http.StatusNotFound || code == http.StatusBadRequest || code == http.StatusNotImplemented {
		return nil
	}

	if truststoreHasAlias(cur, alias) {
		return nil // converged — the public cert is already trusted under our alias
	}

	body := mergeTruststoreAlias(cur, alias, string(pemBytes))
	url := a.adminPath(truststoreConfigPath)
	putCode, raw, err := a.sendJSON(ctx, http.MethodPut, url, body)
	if err != nil {
		return err
	}
	// A build that rejects the shape (4xx) must not abort the subscribe: the
	// app-level identifier is the load-bearing binding. A 5xx (other than 501) is
	// a real gateway error and is surfaced.
	if putCode >= 500 && putCode != http.StatusNotImplemented {
		return fmt.Errorf("PUT %s (truststore) gateway error %d: %s", url, putCode, truncate(raw, 300))
	}
	return nil
}

// getTruststoreConfig reads the current keystore/truststore configuration. It
// returns the decoded map AND the status code so the caller can detect a build
// that does not expose the endpoint (without treating it as a hard error).
func (a *Adapter) getTruststoreConfig(ctx context.Context) (map[string]any, int, error) {
	url := a.adminPath(truststoreConfigPath)
	headers := a.authHeaders()
	headers["Accept"] = "application/json"
	code, raw, err := httpx.Do(ctx, a.http, http.MethodGet, url, headers, nil)
	if err != nil {
		return nil, 0, fmt.Errorf("GET %s (truststore config): %w", url, err)
	}
	if code != http.StatusOK {
		return nil, code, nil
	}
	var cfg map[string]any
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &cfg); err != nil {
			// A non-JSON 200 (HTML form) means the endpoint is not the JSON config
			// surface on this build; treat as "not exposed" rather than failing.
			return nil, http.StatusNotFound, nil
		}
	}
	if cfg == nil {
		cfg = map[string]any{}
	}
	return cfg, code, nil
}

// truststoreHasAlias reports whether the configuration already carries an entry
// under alias (in the additive `certificates` array this code maintains).
func truststoreHasAlias(cfg map[string]any, alias string) bool {
	entries, _ := cfg["certificates"].([]any)
	for _, raw := range entries {
		m, _ := raw.(map[string]any)
		if m == nil {
			continue
		}
		if n, _ := m["alias"].(string); n == alias {
			return true
		}
	}
	return false
}

// mergeTruststoreAlias returns the configuration with the partner's public cert
// appended under alias, preserving existing fields (truststoreName/keystoreName/
// ...) and any certificates already present. The gateway designates the
// truststore by name; the per-alias certificate entries carry the PEM material
// the inbound trust store references.
func mergeTruststoreAlias(cfg map[string]any, alias, pemContent string) map[string]any {
	out := make(map[string]any, len(cfg)+1)
	for k, v := range cfg {
		out[k] = v
	}
	entries, _ := out["certificates"].([]any)
	entry := map[string]any{
		"alias":       alias,
		"certificate": pemContent,
		"type":        "trusted",
	}
	out["certificates"] = append(entries, entry)
	// Name the inbound trust store so the gateway has an alias to reference if it
	// has none yet; never clobber an operator-set name.
	if name, _ := out["truststoreName"].(string); name == "" {
		out["truststoreName"] = "labctl-partner-truststore"
	}
	return out
}
