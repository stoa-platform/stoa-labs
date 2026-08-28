package webmethods

// deactivategate_test.go — the ADR-079 deactivate gate, tested along the WHOLE
// chain a user actually drives: targets.yaml -> targets.Load -> Target.ToConfig
// -> adapter.New -> setAPIActive.
//
// WHY NOT REUSE TestSetAPIActive_DeactivateGate. That test builds an Adapter as
// a struct literal and sets `allowDeactivate` by hand, so it proves the gate
// BEHAVES — and nothing about whether anything can ever reach it. It stayed
// green while the knob was unreachable in practice: the adapter read
// Opt("allowDeactivate") but ToConfig never emitted that key, so a targets file
// declaring `allowDeactivate: false` closed nothing. The seam these two tests
// leave between them is exactly where the fail-open lived, so this one crosses
// it end to end and pins the YAML key by name.

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/targets"
)

// adapterFromTargets writes a targets.yaml carrying the given target-level YAML
// snippet, loads it the way the CLI does, and returns the built webMethods
// adapter pointed at adminURL.
func adapterFromTargets(t *testing.T, adminURL, snippet string) *Adapter {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "targets.yaml")
	doc := `apiVersion: labctl.stoa.io/v1
kind: FederationTarget
name: gate-probe
contract: contract.yaml
targets:
  - name: wm
    type: webmethods
    adminUrl: ` + adminURL + `
    gatewayUrl: ` + adminURL + `
    credentials:
      username: u
      password: p
` + snippet
	if err := os.WriteFile(path, []byte(doc), 0o600); err != nil {
		t.Fatalf("write targets: %v", err)
	}
	tf, err := targets.Load(path)
	if err != nil {
		t.Fatalf("targets.Load: %v", err)
	}
	ad, err := New(tf.Targets[0].ToConfig())
	if err != nil {
		t.Fatalf("adapter.New: %v", err)
	}
	wm, ok := ad.(*Adapter)
	if !ok {
		t.Fatalf("target did not build a webMethods adapter")
	}
	return wm
}

func TestDeactivateGate_ProjectedFromTargetsFile(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	cases := []struct {
		name    string
		snippet string
		refused bool
	}{
		// The knob the fix exists for: a non-authoring stage closes the gate.
		{"allowDeactivate false closes the gate", "    allowDeactivate: false\n", true},
		// Absent MUST keep the documented default (true). A plain bool field
		// would have decoded the absent key as false and silently closed every
		// existing targets file — that is why the field is a *bool.
		{"absent keeps the default (open)", "", false},
		// Stating the default explicitly must behave like the default.
		{"allowDeactivate true keeps it open", "    allowDeactivate: true\n", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			wm := adapterFromTargets(t, srv.URL, tc.snippet)
			err := wm.setAPIActive(context.Background(), "api-1", false)
			switch {
			case tc.refused && (err == nil || !strings.Contains(err.Error(), "UPDATE_FORBIDDEN")):
				t.Fatalf("deactivate err = %v, want UPDATE_FORBIDDEN (ADR-079 gate)", err)
			case !tc.refused && err != nil:
				t.Fatalf("deactivate should be allowed here: %v", err)
			}
			// Activation is never gated — the gate exists to protect a live data
			// plane, and activating cuts nothing.
			if err := wm.setAPIActive(context.Background(), "api-1", true); err != nil {
				t.Fatalf("activate must always flow: %v", err)
			}
		})
	}
}

// TestDeactivateGate_ProjectedOption pins the OPTION KEY itself: the name the
// targets projection writes has to be the name the adapter reads. A rename on
// either side alone turns the gate back into decoration, and nothing else in
// the suite would notice.
func TestDeactivateGate_ProjectedOption(t *testing.T) {
	no, yes := false, true
	for _, tc := range []struct {
		name string
		in   *bool
		want string // Opt(...) with the adapter's own default
	}{
		{"nil falls back to the adapter default", nil, "true"},
		{"false is projected verbatim", &no, "false"},
		{"true is projected verbatim", &yes, "true"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := targets.Target{
				Name: "wm", Type: "webmethods", AdminURL: "http://x",
				Credentials:     map[string]string{"username": "u", "password": "p"},
				AllowDeactivate: tc.in,
			}.ToConfig()
			if got := cfg.Opt("allowDeactivate", "true"); got != tc.want {
				t.Fatalf("Opt(allowDeactivate) = %q, want %q", got, tc.want)
			}
			if tc.in == nil {
				if _, present := cfg.Options["allowDeactivate"]; present {
					t.Errorf("an absent knob must not be emitted at all (it would pin the default in place)")
				}
			}
		})
	}
}
