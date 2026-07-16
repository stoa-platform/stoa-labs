// Package vault reads secrets from a HashiCorp Vault KV v2 mount over its REST
// API — plain JSON over HTTP, NO Vault SDK (air-gapped: reuses internal/httpx,
// adds no vendored dependency). It lets labctl and onboarding-api fetch
// credentials AT RUNTIME instead of carrying placeholders in targets.yaml / env
// / CI credentials (ADR-074, concretizing the ADR-072 gap (d): the platform
// secrets never sit in Git and are rotatable without a rebuild).
//
// When VAULT_ADDR is unset the package is a NO-OP (Enabled() == false): callers
// fall back to their literal/env values, so behaviour is unchanged without Vault
// (every existing test and the current CI keep working).
package vault

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"strings"
	"sync"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/httpx"
)

// Client reads KV v2 secrets under {mount}/data/{prefix}/…
//
// Authentication, in priority order: a static token (VAULT_TOKEN_FILE, a 0600
// file — preferred so the token never sits in the env or an argv — then
// VAULT_TOKEN); else an EPHEMERAL AppRole login (VAULT_ROLE_ID + VAULT_SECRET_ID
// / VAULT_SECRET_ID_FILE → a short-TTL token scoped to the role's policy). The
// AppRole path is the hardened model (ADR-074): no long-lived root token — the
// caller presents a public role_id + a short-lived secret_id and gets a token
// that reads only its perimeter and expires.
type Client struct {
	addr     string
	mount    string
	prefix   string
	hc       *http.Client
	roleID   string
	secretID string

	mu    sync.Mutex
	token string // static token, or the AppRole token after first login
}

// Enabled reports whether Vault resolution is configured (VAULT_ADDR set). A
// cheap guard callers use before bothering to build a Client.
func Enabled() bool { return strings.TrimSpace(os.Getenv("VAULT_ADDR")) != "" }

// FromEnv builds a Client from VAULT_ADDR / VAULT_TOKEN / VAULT_KV_MOUNT
// (default "secret") / VAULT_PREFIX (default "stoa") / VAULT_INSECURE /
// VAULT_CACERT (the standard Vault CLI knob — enterprise CA bundle; falls back
// to LABCTL_CA_FILE so one knob can cover gateways AND Vault). It returns
// (nil, false) when VAULT_ADDR is empty — the no-op path.
func FromEnv() (*Client, bool) {
	addr := strings.TrimSpace(os.Getenv("VAULT_ADDR"))
	if addr == "" {
		return nil, false
	}
	return &Client{
		addr:     strings.TrimRight(addr, "/"),
		token:    resolveStaticToken(),
		roleID:   strings.TrimSpace(os.Getenv("VAULT_ROLE_ID")),
		secretID: resolveSecretID(),
		mount:    envOr("VAULT_KV_MOUNT", "secret"),
		prefix:   envOr("VAULT_PREFIX", "stoa"),
		hc:       httpx.NewClientCA(boolEnv("VAULT_INSECURE"), envOr("VAULT_CACERT", os.Getenv("LABCTL_CA_FILE"))),
	}, true
}

// resolveStaticToken prefers VAULT_TOKEN_FILE (a 0600 file — the token never has
// to appear in the process env or a command line) over VAULT_TOKEN.
func resolveStaticToken() string {
	if v := readFileTrim(os.Getenv("VAULT_TOKEN_FILE")); v != "" {
		return v
	}
	return strings.TrimSpace(os.Getenv("VAULT_TOKEN"))
}

// resolveSecretID prefers VAULT_SECRET_ID_FILE over VAULT_SECRET_ID (the
// secret_id is itself a secret — keep it off the env/argv when possible).
func resolveSecretID() string {
	if v := readFileTrim(os.Getenv("VAULT_SECRET_ID_FILE")); v != "" {
		return v
	}
	return strings.TrimSpace(os.Getenv("VAULT_SECRET_ID"))
}

func readFileTrim(path string) string {
	path = strings.TrimSpace(path)
	if path == "" {
		return ""
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// ensureToken returns a usable Vault token, performing an AppRole login on first
// use when no static token was provided. The resulting ephemeral token is cached
// for the process lifetime (a labctl run is short — well within the token TTL).
func (c *Client) ensureToken(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.token != "" {
		return c.token, nil
	}
	if c.roleID == "" || c.secretID == "" {
		return "", fmt.Errorf("vault: no token (set VAULT_TOKEN/_FILE) and no AppRole (set VAULT_ROLE_ID + VAULT_SECRET_ID/_FILE)")
	}
	var out struct {
		Auth struct {
			ClientToken string `json:"client_token"`
		} `json:"auth"`
	}
	url := c.addr + "/v1/auth/approle/login"
	in := map[string]string{"role_id": c.roleID, "secret_id": c.secretID}
	if _, err := httpx.JSON(ctx, c.hc, http.MethodPost, url, nil, in, &out); err != nil {
		return "", fmt.Errorf("vault approle login: %w", err)
	}
	if out.Auth.ClientToken == "" {
		return "", fmt.Errorf("vault approle login: empty client_token")
	}
	c.token = out.Auth.ClientToken // ephemeral, scoped to the role's policy
	return c.token, nil
}

// ReadKV reads the KV v2 secret at {prefix}/{sub}. A 404 (secret not
// provisioned for this path) returns (nil, nil) so the caller can keep its
// literal/env fallback — Vault overrides WHERE it has the secret, not blindly.
// A transport or auth failure (Vault unreachable, 403) IS an error (fail closed:
// a configured-but-broken Vault must surface, not silently fall back).
func (c *Client) ReadKV(ctx context.Context, sub string) (map[string]string, error) {
	url := fmt.Sprintf("%s/v1/%s/data/%s/%s", c.addr, c.mount, c.prefix, strings.Trim(sub, "/"))
	var out struct {
		Data struct {
			Data map[string]string `json:"data"`
		} `json:"data"`
	}
	tok, err := c.ensureToken(ctx)
	if err != nil {
		return nil, err
	}
	headers := map[string]string{"X-Vault-Token": tok}
	code, err := httpx.JSON(ctx, c.hc, http.MethodGet, url, headers, nil, &out)
	if code == http.StatusNotFound {
		return nil, nil // not provisioned here — caller falls back to literal
	}
	if err != nil {
		return nil, fmt.Errorf("vault read %s: %w", sub, err)
	}
	return out.Data.Data, nil
}

func envOr(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func boolEnv(key string) bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(key))) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}
