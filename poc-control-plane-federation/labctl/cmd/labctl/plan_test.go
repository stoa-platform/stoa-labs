package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/output"
)

// desiredAPI mirrors the fake contract used by writeFederation: title
// "Accounts Read API" slugs to "accounts-read-api", v1.0.0, /accounts-read/v1.
func desiredAPI() *adapter.NormalizedAPI {
	return &adapter.NormalizedAPI{
		Name:     "accounts-read-api",
		Version:  "1.0.0",
		BasePath: "/accounts-read/v1",
	}
}

func TestPlanAction(t *testing.T) {
	cases := []struct {
		name       string
		existing   []adapter.PublishedAPI
		wantAction string
		wantReason string // substring
	}{
		{
			name:       "empty catalog means create",
			existing:   nil,
			wantAction: output.ActionCreate,
			wantReason: "not present",
		},
		{
			name: "other APIs only still means create",
			existing: []adapter.PublishedAPI{
				{Name: "payments", Version: "1.0.0", BasePath: "/payments/v1", APIID: "p1"},
			},
			wantAction: output.ActionCreate,
			wantReason: "not present",
		},
		{
			name: "exact match means none",
			existing: []adapter.PublishedAPI{
				{Name: "accounts-read-api", Version: "1.0.0", BasePath: "/accounts-read/v1", APIID: "a1"},
			},
			wantAction: output.ActionNone,
			wantReason: "already published",
		},
		{
			name: "version drift means update",
			existing: []adapter.PublishedAPI{
				{Name: "accounts-read-api", Version: "0.9.0", BasePath: "/accounts-read/v1", APIID: "a1"},
			},
			wantAction: output.ActionUpdate,
			wantReason: "version 0.9.0 → 1.0.0",
		},
		{
			name: "basePath drift means update",
			existing: []adapter.PublishedAPI{
				{Name: "accounts-read-api", Version: "1.0.0", BasePath: "/accounts/v1", APIID: "a1"},
			},
			wantAction: output.ActionUpdate,
			wantReason: "basePath /accounts/v1 → /accounts-read/v1",
		},
		{
			name: "multi-version gateway with an exact hit means none",
			existing: []adapter.PublishedAPI{
				{Name: "accounts-read-api", Version: "0.9.0", BasePath: "/accounts-read/v1", APIID: "old"},
				{Name: "accounts-read-api", Version: "1.0.0", BasePath: "/accounts-read/v1", APIID: "cur"},
			},
			wantAction: output.ActionNone,
			wantReason: "already published",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			action, reason := planAction(desiredAPI(), tc.existing)
			if action != tc.wantAction {
				t.Errorf("action = %q, want %q (reason: %s)", action, tc.wantAction, reason)
			}
			if !strings.Contains(reason, tc.wantReason) {
				t.Errorf("reason = %q, want substring %q", reason, tc.wantReason)
			}
		})
	}
}

// The plan is a report: every action class shows up in the table and the exit
// code stays 0 even when a gateway is unreachable (action "unknown").
func TestRunPlan_ReportsAllActionsAndExitsZero(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-new, type: faketgt, adminUrl: http://a}
  - {name: gw-same, type: faketgt, adminUrl: http://b, credentials: {behavior: list-match}}
  - {name: gw-stale, type: faketgt, adminUrl: http://c, credentials: {behavior: list-stale}}
  - {name: gw-down, type: faketgt, adminUrl: http://d, credentials: {behavior: fail-list}}
`)
	out, err := runDispatch(t, runPlan, p)
	if err != nil {
		t.Fatalf("plan must exit 0 even with unreachable gateways, got: %v\n%s", err, out)
	}
	for _, want := range []string{
		"gw-new", output.ActionCreate,
		"gw-same", output.ActionNone,
		"gw-stale", output.ActionUpdate,
		"gw-down", output.ActionUnknown, "synthetic list error",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("plan table missing %q:\n%s", want, out)
		}
	}
}

// plan must be strictly read-only: no Publish/CreateConsumer reaches the
// adapters even when the plan says create/update, and no Backstage entity or
// credentials file is written.
func TestRunPlan_IsReadOnly(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-bad-publish, type: faketgt, adminUrl: http://a, credentials: {behavior: fail-publish}}
  - {name: gw-bad-consumer, type: faketgt, adminUrl: http://b, credentials: {behavior: fail-consumer}}
`)
	out, err := runDispatch(t, runPlan, p)
	if err != nil {
		t.Fatalf("plan: %v\n%s", err, out)
	}
	// fail-publish / fail-consumer would explode IF plan called Publish or
	// CreateConsumer; a clean "create" verdict proves it only listed.
	if strings.Contains(out, "synthetic publish error") || strings.Contains(out, "synthetic consumer error") {
		t.Errorf("plan invoked a mutating adapter call:\n%s", out)
	}
	if !strings.Contains(out, output.ActionCreate) {
		t.Errorf("plan should report create for both targets:\n%s", out)
	}
	// And no side-effect artifacts in the working dir.
	for _, f := range []string{"catalog-info.yaml", credentialsFile} {
		if _, statErr := os.Stat(filepath.Join(filepath.Dir(p), f)); statErr == nil {
			t.Errorf("plan wrote %s — it must be strictly read-only", f)
		}
	}
}

func TestRunPlan_AdapterBuildFailureIsUnknown(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-broken, type: faketgt, adminUrl: http://a, credentials: {behavior: fail-new}}
`)
	out, err := runDispatch(t, runPlan, p)
	if err != nil {
		t.Fatalf("plan must exit 0 on an unbuildable adapter, got: %v\n%s", err, out)
	}
	if !strings.Contains(out, output.ActionUnknown) || !strings.Contains(out, "synthetic adapter build failure") {
		t.Errorf("plan should report unknown + the adapter error:\n%s", out)
	}
}

func TestRunPlan_JSON(t *testing.T) {
	p := writeFederation(t, `targets:
  - {name: gw-new, type: faketgt, adminUrl: http://a}
  - {name: gw-down, type: faketgt, adminUrl: http://b, credentials: {behavior: fail-list}}
`)
	stdout, stderr, err := runDispatchFormat(t, runPlan, p, "json")
	if err != nil {
		t.Fatalf("plan -o json must exit 0, got: %v\n%s", err, stdout)
	}
	// stdout carries the JSON document ONLY; the narration went to stderr.
	if !strings.HasPrefix(strings.TrimSpace(stdout), "{") {
		t.Fatalf("stdout is not a bare JSON document:\n%s", stdout)
	}
	if !strings.Contains(stderr, "Plan (read-only)") {
		t.Errorf("human narration should be on stderr, got:\n%s", stderr)
	}
	var report output.PlanReport
	if err := json.Unmarshal([]byte(stdout), &report); err != nil {
		t.Fatalf("stdout is not valid JSON: %v\n%s", err, stdout)
	}
	if report.OK {
		t.Errorf("report.OK = true, want false (one gateway unknown)")
	}
	if len(report.Targets) != 2 {
		t.Fatalf("len(targets) = %d, want 2", len(report.Targets))
	}
	if report.Targets[0].Gateway != "gw-new" || report.Targets[0].Action != output.ActionCreate {
		t.Errorf("target[0] = %+v, want gw-new/create", report.Targets[0])
	}
	if report.Targets[1].Action != output.ActionUnknown || !strings.Contains(report.Targets[1].Reason, "synthetic list error") {
		t.Errorf("target[1] = %+v, want unknown + network reason", report.Targets[1])
	}
	if report.Targets[1].Type != "faketgt" {
		t.Errorf("target[1].Type = %q, want faketgt", report.Targets[1].Type)
	}
}
