package cmd

import (
	"context"
	"fmt"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/targets"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/vault"
)

// loadResolvedTargets loads the federation manifest and, WHEN Vault is configured
// (VAULT_ADDR set), OVERRIDES the credentials with secrets read from Vault at
// runtime: the gateway admin creds (secret/stoa/gateways/{target}) and the
// Keycloak admin + consumer secret (secret/stoa/keycloak). The platform secrets
// thus never depend on the targets.yaml placeholders — they live in Vault and
// are rotatable without a rebuild (ADR-074, concretizes ADR-072 gap (d)).
//
// Fallback is total: VAULT_ADDR unset → exactly targets.Load (the manifest
// literals), so every existing test and the current CI keep working unchanged.
// A target with no secret in Vault (404) keeps its manifest literal; only an
// unreachable/forbidden Vault is a hard error. No secret value is ever logged.
func loadResolvedTargets(ctx context.Context, path string) (*targets.File, error) {
	tf, err := targets.Load(path)
	if err != nil {
		return nil, err
	}
	c, ok := vault.FromEnv()
	if !ok {
		return tf, nil // no Vault → manifest literals
	}

	for i := range tf.Targets {
		t := &tf.Targets[i]
		sec, err := c.ReadKV(ctx, "gateways/"+t.Name)
		if err != nil {
			return nil, fmt.Errorf("resolving credentials for target %q from Vault: %w", t.Name, err)
		}
		if sec == nil {
			continue // not in Vault → keep the manifest literal
		}
		if t.Credentials == nil {
			t.Credentials = map[string]string{}
		}
		for k, v := range sec {
			if v != "" {
				t.Credentials[k] = v
			}
		}
	}

	// Keycloak n'est résolu QUE si le manifeste déclare un bloc keycloak (URL
	// non vide) : `apply` sur un manifeste sans subscribe (ex. les proxies
	// admin ADR-075) ne doit exiger aucun droit Vault sur secret/stoa/keycloak
	// — c'est ce qui permet la policy least-privilege proxy-provision. Un
	// manifeste QUI déclare keycloak garde le fail-closed (403 = erreur dure).
	if tf.Keycloak.URL == "" {
		return tf, nil
	}
	kc, err := c.ReadKV(ctx, "keycloak")
	if err != nil {
		return nil, fmt.Errorf("resolving Keycloak credentials from Vault: %w", err)
	}
	if v := kc["adminUsername"]; v != "" {
		tf.Keycloak.Admin.Username = v
	}
	if v := kc["adminPassword"]; v != "" {
		tf.Keycloak.Admin.Password = v
	}
	if v := kc["consumerClientSecret"]; v != "" {
		tf.Keycloak.ConsumerClientSecret = v
	}
	return tf, nil
}
