package webmethods

// Live integration test against the REAL softwareag/apigateway-trial:10.15
// running on http://localhost:5555 (docker-compose.wm.yml, container
// poc-webmethods-real, Basic Administrator:manage).
//
// GATED: it runs only when a flag file exists — /tmp/wm-live-test.flag or, as
// a workspace-local fallback, testdata/wm-live-test.flag next to this test —
// so `go test ./...` stays hermetic on CI and on machines without the gateway.
//
//	touch /tmp/wm-live-test.flag
//	go test -mod=vendor -run TestLive -v ./internal/adapter/webmethods/
//
// The test walks the full adapter contract — Health, Publish (import +
// activate), idempotent re-Publish, List, CreateConsumer (application +
// association), idempotent re-CreateConsumer — and logs every gateway-native
// id and URL so the run doubles as PoC evidence.

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/openapi"
)

// liveFlagFiles are the gate locations, checked in order. /tmp gates on mere
// existence; the workspace-local testdata fallback (for sandboxes where /tmp
// is not writable) additionally requires its content to start with "enabled",
// so it can be switched off by rewriting the file instead of deleting it.
var liveFlagFiles = []string{"/tmp/wm-live-test.flag", "testdata/wm-live-test.flag"}

func liveGatePresent() bool {
	if _, err := os.Stat(liveFlagFiles[0]); err == nil {
		return true
	}
	if raw, err := os.ReadFile(liveFlagFiles[1]); err == nil {
		return strings.HasPrefix(strings.TrimSpace(string(raw)), "enabled")
	}
	return false
}

func TestLive_RealGatewayPublishListConsumer(t *testing.T) {
	if !liveGatePresent() {
		t.Skipf("live gate absent (%v) — skipping real-gateway test (touch one to enable)", liveFlagFiles)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	ad, err := New(adapter.Config{
		Type:       gatewayName,
		Name:       gatewayName,
		AdminURL:   "http://localhost:5555",
		GatewayURL: "http://localhost:5555",
		Credentials: map[string]string{
			"username": "Administrator",
			"password": "manage",
		},
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	// Health: reachability + Basic credentials accepted.
	if err := ad.Health(ctx); err != nil {
		t.Fatalf("Health against the real gateway: %v", err)
	}
	t.Log("Health: OK (Basic Administrator accepted on /rest/apigateway/health)")

	// The real PoC contract, normalized exactly as `labctl apply` would.
	api, err := openapi.Load(
		"../../../../apis/accounts-read.openapi.yaml",
		"accounts-read",
		"http://microcks:8080/rest/Accounts+Read+API/1.0.0",
	)
	if err != nil {
		t.Fatalf("load PoC contract: %v", err)
	}

	// Publish #1: import + activate.
	res1, err := ad.Publish(ctx, api)
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}
	t.Logf("Publish #1: apiId=%s created=%v published=%v invocationURL=%s",
		res1.APIID, res1.Created, res1.Published, res1.InvocationURL)
	if res1.APIID == "" {
		t.Fatal("Publish returned an empty apiId")
	}
	if !res1.Published {
		t.Error("Publish #1: Published=false, want true (activation step failed?)")
	}

	// Publish #2: idempotent re-apply must converge on the SAME record.
	res2, err := ad.Publish(ctx, api)
	if err != nil {
		t.Fatalf("re-Publish: %v", err)
	}
	t.Logf("Publish #2: apiId=%s created=%v (want created=false, same id)", res2.APIID, res2.Created)
	if res2.Created {
		t.Error("re-Publish: Created=true, want false (idempotent update)")
	}
	if res2.APIID != res1.APIID {
		t.Errorf("re-Publish drifted apiId: %q -> %q", res1.APIID, res2.APIID)
	}

	// List: the published API is visible in the gateway-native view.
	list, err := ad.List(ctx)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	found := false
	for _, item := range list {
		t.Logf("List: id=%s name=%s version=%s basePath=%s", item.APIID, item.Name, item.Version, item.BasePath)
		if item.APIID == res1.APIID {
			found = true
		}
	}
	if !found {
		t.Errorf("List does not contain the published api %s", res1.APIID)
	}

	// CreateConsumer: application + association, then idempotent re-apply.
	spec := &adapter.ConsumerSpec{
		Name:     "labctl-live-consumer",
		ClientID: "accounts-read-consumer",
		AuthType: "oauth2",
	}
	c1, err := ad.CreateConsumer(ctx, api, spec)
	if err != nil {
		t.Fatalf("CreateConsumer: %v", err)
	}
	t.Logf("CreateConsumer #1: applicationId=%s consumerKey=%s hint=%s", c1.ConsumerID, c1.ConsumerKey, c1.TokenHint)
	c2, err := ad.CreateConsumer(ctx, api, spec)
	if err != nil {
		t.Fatalf("re-CreateConsumer: %v", err)
	}
	t.Logf("CreateConsumer #2: applicationId=%s (want same as #1)", c2.ConsumerID)
	if c1.ConsumerID != c2.ConsumerID {
		t.Errorf("CreateConsumer drifted application id: %q -> %q", c1.ConsumerID, c2.ConsumerID)
	}
}
