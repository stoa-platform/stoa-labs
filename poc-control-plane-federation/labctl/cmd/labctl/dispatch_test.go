package cmd

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/spf13/cobra"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/keycloak"
)

// fakeTarget is a registry-backed adapter whose behavior is driven by the
// per-target credential "behavior", so the apply/subscribe dispatch loops can be
// exercised end-to-end (adapter.New resolution + ToConfig + partial-failure
// aggregation + exit code) without any live gateway.
type fakeTarget struct {
	name     string
	behavior string
}

func (f *fakeTarget) Name() string { return "faketgt" }

func (f *fakeTarget) Health(context.Context) error {
	if f.behavior == "fail-health" {
		return fmt.Errorf("synthetic unreachable")
	}
	return nil
}

func (f *fakeTarget) Publish(_ context.Context, api *adapter.NormalizedAPI) (*adapter.PublishResult, error) {
	if f.behavior == "fail-publish" {
		return nil, fmt.Errorf("synthetic publish error")
	}
	return &adapter.PublishResult{
		Gateway:       f.name,
		APIID:         "id-" + f.name,
		InvocationURL: "http://" + f.name + api.BasePath,
		Published:     true,
		Created:       true,
	}, nil
}

// List behaviors mirror the fake contract below (title "Accounts Read API"
// slugs to "accounts-read-api", v1.0.0, basePath /accounts-read/v1) so the
// plan/get logic can be exercised against in-memory catalogs:
//   - "fail-list":   the gateway cannot be listed (network error);
//   - "list-match":  the desired API is already published as-is;
//   - "list-stale":  same name published at an older version (drift);
//   - default:       empty catalog.
func (f *fakeTarget) List(context.Context) ([]adapter.PublishedAPI, error) {
	switch f.behavior {
	case "fail-list":
		return nil, fmt.Errorf("synthetic list error")
	case "list-match":
		return []adapter.PublishedAPI{{
			Gateway: "faketgt", APIID: "id-" + f.name, Name: "accounts-read-api",
			Version: "1.0.0", BasePath: "/accounts-read/v1",
		}}, nil
	case "list-stale":
		return []adapter.PublishedAPI{{
			Gateway: "faketgt", APIID: "id-" + f.name, Name: "accounts-read-api",
			Version: "0.9.0", BasePath: "/accounts-read/v1",
		}}, nil
	}
	return nil, nil
}

func (f *fakeTarget) CreateConsumer(context.Context, *adapter.NormalizedAPI, *adapter.ConsumerSpec) (*adapter.ConsumerResult, error) {
	if f.behavior == "fail-consumer" {
		return nil, fmt.Errorf("synthetic consumer error")
	}
	return &adapter.ConsumerResult{Gateway: f.name, ConsumerID: "c-" + f.name, ConsumerKey: "k-" + f.name}, nil
}

func init() {
	adapter.Register("faketgt", func(cfg adapter.Config) (adapter.Adapter, error) {
		if cfg.Cred("behavior", "ok") == "fail-new" {
			return nil, fmt.Errorf("synthetic adapter build failure")
		}
		return &fakeTarget{name: cfg.Name, behavior: cfg.Cred("behavior", "ok")}, nil
	})
}

const fakeContract = `openapi: 3.0.0
info:
  title: Accounts Read API
  version: 1.0.0
servers:
  - url: /accounts-read/v1
paths:
  /accounts:
    get: {}
`

// writeFederation writes contract.yaml + targets.yaml into a temp dir and
// returns the manifest path. targetsBody is appended after the contract line.
func writeFederation(t *testing.T, targetsBody string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "contract.yaml"), []byte(fakeContract), 0o600); err != nil {
		t.Fatalf("write contract: %v", err)
	}
	p := filepath.Join(dir, "targets.yaml")
	body := "contract: contract.yaml\nbackendUrl: http://backend:8080\n" + targetsBody
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	return p
}

// runDispatch points fileFlag at manifestPath, chdirs into its dir (so any
// catalog-info.yaml / labctl-credentials.txt land in the temp dir, not the repo),
// and invokes fn with a context + captured stdout.
func runDispatch(t *testing.T, fn func(*cobra.Command, []string) error, manifestPath string) (string, error) {
	stdout, _, err := runDispatchFormat(t, fn, manifestPath, "table")
	return stdout, err
}

// runDispatchFormat is runDispatch with an explicit -o format and separate
// stdout/stderr capture, so the json-mode contract (stdout = the document ONLY,
// human logs on stderr) can be asserted.
func runDispatchFormat(t *testing.T, fn func(*cobra.Command, []string) error, manifestPath, format string) (stdout, stderr string, err error) {
	t.Helper()
	prevFlag, prevOutput := fileFlag, outputFlag
	fileFlag, outputFlag = manifestPath, format
	prevWd, _ := os.Getwd()
	if err := os.Chdir(filepath.Dir(manifestPath)); err != nil {
		t.Fatalf("chdir: %v", err)
	}
	t.Cleanup(func() { fileFlag, outputFlag = prevFlag, prevOutput; _ = os.Chdir(prevWd) })

	cmd := &cobra.Command{}
	cmd.SetContext(context.Background())
	var outBuf, errBuf bytes.Buffer
	cmd.SetOut(&outBuf)
	cmd.SetErr(&errBuf)
	err = fn(cmd, nil)
	return outBuf.String(), errBuf.String(), err
}

func TestRunApply_AllSuccess(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a}
  - {name: gw-b, type: faketgt, adminUrl: http://b}
  - {name: gw-c, type: faketgt, adminUrl: http://c}
`)
	out, err := runDispatch(t, runApply, p)
	if err != nil {
		t.Fatalf("runApply: unexpected error: %v\n%s", err, out)
	}
	if !strings.Contains(out, "3/3 gateways published from one contract") {
		t.Errorf("output missing 3/3 summary:\n%s", out)
	}
	// Backstage entity for all 3 distinct target names must be written.
	if !strings.Contains(out, "3 gateways federated") {
		t.Errorf("Backstage entity should federate 3 gateways:\n%s", out)
	}
}

// The single most load-bearing guarantee: when one gateway fails, the others
// still publish AND apply returns a non-nil error (non-zero exit).
func TestRunApply_PartialPublishFailureStillPublishesRestAndErrors(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-ok-1, type: faketgt, adminUrl: http://a}
  - {name: gw-bad, type: faketgt, adminUrl: http://b, credentials: {behavior: fail-publish}}
  - {name: gw-ok-2, type: faketgt, adminUrl: http://c}
`)
	out, err := runDispatch(t, runApply, p)
	if err == nil {
		t.Fatalf("runApply returned nil error on a partial failure; output:\n%s", out)
	}
	if !strings.Contains(err.Error(), "1/3 gateways failed to publish") {
		t.Errorf("error = %v, want '1/3 gateways failed to publish'", err)
	}
	if !strings.Contains(out, "2/3 gateways published from one contract") {
		t.Errorf("output missing 2/3 summary (others must still publish):\n%s", out)
	}
	if !strings.Contains(out, "synthetic publish error") {
		t.Errorf("output should surface the failing gateway's error:\n%s", out)
	}
}

func TestRunApply_UnreachableGatewayFailsFastPerGateway(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-ok, type: faketgt, adminUrl: http://a}
  - {name: gw-down, type: faketgt, adminUrl: http://b, credentials: {behavior: fail-health}}
`)
	out, err := runDispatch(t, runApply, p)
	if err == nil {
		t.Fatalf("expected error on unreachable gateway; output:\n%s", out)
	}
	if !strings.Contains(out, "unreachable") {
		t.Errorf("output should report the unreachable gateway:\n%s", out)
	}
	if !strings.Contains(out, "1/2 gateways published from one contract") {
		t.Errorf("output missing 1/2 summary:\n%s", out)
	}
}

func TestRunApply_AdapterBuildFailure(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-ok, type: faketgt, adminUrl: http://a}
  - {name: gw-broken, type: faketgt, adminUrl: http://b, credentials: {behavior: fail-new}}
`)
	out, err := runDispatch(t, runApply, p)
	if err == nil {
		t.Fatalf("expected error on adapter build failure; output:\n%s", out)
	}
	if !strings.Contains(out, "synthetic adapter build failure") {
		t.Errorf("output should surface the adapter construction error:\n%s", out)
	}
}

// withFakeKeycloak stubs the Keycloak client-provisioning step so subscribe's
// dispatch loop can be tested without a live Keycloak.
func withFakeKeycloak(t *testing.T, ret func(keycloak.Config) (string, string, error)) {
	t.Helper()
	prev := ensureClient
	ensureClient = func(_ context.Context, cfg keycloak.Config) (string, string, error) { return ret(cfg) }
	t.Cleanup(func() { ensureClient = prev })
}

// withFakeConsumerAuth stubs the Keycloak consumer-auth step (audience mapper +
// default scope) and records the calls so the wiring can be asserted.
func withFakeConsumerAuth(t *testing.T, fn func(keycloak.ConsumerAuthConfig) error) {
	t.Helper()
	prev := ensureConsumerAuth
	ensureConsumerAuth = func(_ context.Context, cfg keycloak.ConsumerAuthConfig) error { return fn(cfg) }
	t.Cleanup(func() { ensureConsumerAuth = prev })
}

const keycloakBlock = `keycloak:
  url: http://keycloak:8080
  realm: stoa-lab
  consumerClientId: accounts-read-consumer
`

func TestRunSubscribe_AllSuccessWritesCredentials(t *testing.T) {
	withFakeKeycloak(t, func(keycloak.Config) (string, string, error) { return "cid", "csec", nil })
	p := writeFederation(t, keycloakBlock+`targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a}
  - {name: gw-b, type: faketgt, adminUrl: http://b}
`)
	out, err := runDispatch(t, runSubscribe, p)
	if err != nil {
		t.Fatalf("runSubscribe: unexpected error: %v\n%s", err, out)
	}
	if !strings.Contains(out, "2/2 gateways provisioned") {
		t.Errorf("output missing 2/2 summary:\n%s", out)
	}
	// The 0600 credentials file must have been written next to the run (CWD).
	if _, statErr := os.Stat(filepath.Join(filepath.Dir(p), credentialsFile)); statErr != nil {
		t.Errorf("credentials file not written: %v", statErr)
	}
}

func TestRunSubscribe_PartialFailureAggregatesAndErrors(t *testing.T) {
	withFakeKeycloak(t, func(keycloak.Config) (string, string, error) { return "cid", "csec", nil })
	p := writeFederation(t, keycloakBlock+`targets:
  - {name: gw-ok, type: faketgt, adminUrl: http://a}
  - {name: gw-bad, type: faketgt, adminUrl: http://b, credentials: {behavior: fail-consumer}}
`)
	out, err := runDispatch(t, runSubscribe, p)
	if err == nil {
		t.Fatalf("expected error on partial subscribe failure; output:\n%s", out)
	}
	if !strings.Contains(err.Error(), "1/2 gateways failed to provision") {
		t.Errorf("error = %v, want '1/2 gateways failed to provision'", err)
	}
	if !strings.Contains(out, "1/2 gateways provisioned") {
		t.Errorf("output missing 1/2 summary:\n%s", out)
	}
}

func TestRunSubscribe_KeycloakFailureAbortsBeforeDispatch(t *testing.T) {
	withFakeKeycloak(t, func(keycloak.Config) (string, string, error) {
		return "", "", fmt.Errorf("synthetic KC down")
	})
	p := writeFederation(t, keycloakBlock+`targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a}
`)
	_, err := runDispatch(t, runSubscribe, p)
	if err == nil || !strings.Contains(err.Error(), "keycloak:") {
		t.Fatalf("err = %v, want a 'keycloak: ...' error", err)
	}
}

// When a target's inboundAuth declares an audience, subscribe must converge the
// Keycloak consumer auth (audience mapper + default scope) BEFORE provisioning
// the gateways, with the audience+scope projected from the manifest.
func TestRunSubscribe_ConvergesConsumerAuthWhenAudiencePresent(t *testing.T) {
	withFakeKeycloak(t, func(keycloak.Config) (string, string, error) { return "accounts-read-consumer", "csec", nil })
	var got keycloak.ConsumerAuthConfig
	calls := 0
	withFakeConsumerAuth(t, func(cfg keycloak.ConsumerAuthConfig) error { calls++; got = cfg; return nil })

	p := writeFederation(t, keycloakBlock+`targets:
  - name: wm
    type: faketgt
    adminUrl: http://wm
    inboundAuth:
      issuer: http://localhost:8480/realms/stoa-lab
      jwksUri: http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/certs
      audience: accounts-read
      scope: accounts.read
`)
	if _, err := runDispatch(t, runSubscribe, p); err != nil {
		t.Fatalf("runSubscribe: %v", err)
	}
	if calls != 1 {
		t.Fatalf("ensureConsumerAuth calls = %d, want 1", calls)
	}
	if got.Audience != "accounts-read" || got.Scope != "accounts.read" {
		t.Errorf("consumer auth (aud,scope) = (%q,%q), want (accounts-read, accounts.read)", got.Audience, got.Scope)
	}
	if got.ClientID != "accounts-read-consumer" {
		t.Errorf("consumer auth ClientID = %q, want accounts-read-consumer", got.ClientID)
	}
}

// Without an audience anywhere, the consumer-auth step is SKIPPED (the
// signature-only path needs no Keycloak audience/scope writes).
func TestRunSubscribe_SkipsConsumerAuthWithoutAudience(t *testing.T) {
	withFakeKeycloak(t, func(keycloak.Config) (string, string, error) { return "cid", "csec", nil })
	calls := 0
	withFakeConsumerAuth(t, func(keycloak.ConsumerAuthConfig) error { calls++; return nil })
	p := writeFederation(t, keycloakBlock+`targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a}
`)
	if _, err := runDispatch(t, runSubscribe, p); err != nil {
		t.Fatalf("runSubscribe: %v", err)
	}
	if calls != 0 {
		t.Errorf("ensureConsumerAuth calls = %d, want 0 (no audience)", calls)
	}
}

// A consumer-auth failure aborts subscribe BEFORE provisioning gateways (the
// token would not satisfy the barrier the adapters install).
func TestRunSubscribe_ConsumerAuthFailureAborts(t *testing.T) {
	withFakeKeycloak(t, func(keycloak.Config) (string, string, error) { return "cid", "csec", nil })
	withFakeConsumerAuth(t, func(keycloak.ConsumerAuthConfig) error { return fmt.Errorf("synthetic mapper failure") })
	p := writeFederation(t, keycloakBlock+`targets:
  - name: wm
    type: faketgt
    adminUrl: http://wm
    inboundAuth:
      issuer: http://localhost:8480/realms/stoa-lab
      jwksUri: http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/certs
      audience: accounts-read
      scope: accounts.read
`)
	_, err := runDispatch(t, runSubscribe, p)
	if err == nil || !strings.Contains(err.Error(), "consumer auth") {
		t.Fatalf("err = %v, want a 'consumer auth' error", err)
	}
}

func TestRunSubscribe_MissingKeycloakConfig(t *testing.T) {
	withFakeKeycloak(t, func(keycloak.Config) (string, string, error) { return "cid", "csec", nil })
	p := writeFederation(t, `targets:
  - {name: gw-a, type: faketgt, adminUrl: http://a}
`)
	_, err := runDispatch(t, runSubscribe, p)
	if err == nil || !strings.Contains(err.Error(), "keycloak.url and keycloak.consumerClientId are required") {
		t.Fatalf("err = %v, want a missing-keycloak-config error", err)
	}
}
