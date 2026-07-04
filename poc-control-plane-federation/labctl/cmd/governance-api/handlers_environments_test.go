package main

import "testing"

// The /environments endpoint is the UI's source of truth for the promotion
// chain and its per-hop gates (so no env name is hardcoded client-side).
func TestEnvironmentsExposesChainAndGates(t *testing.T) {
	_, h, fix := newTestServer(t)
	alice := fix.sign(t, "alice", "Alice Martin", "banking-demo", []string{"tenant-admin"})

	code, body := do(t, h, "GET", "/api/v1/environments", alice, nil)
	if code != 200 {
		t.Fatalf("GET /environments = %d %v", code, body)
	}
	envs, _ := body["environments"].([]any)
	if len(envs) == 0 {
		t.Fatalf("environments must be a non-empty chain: %v", body)
	}
	// The default chain (no environments.yaml in the seed) terminates in a
	// production hop gated by 4-eyes — the gate the UI reads to decide whether
	// to block self-approval and require change_ref/pv_ref.
	gates, _ := body["gates"].(map[string]any)
	prod, _ := gates["production"].(map[string]any)
	if prod == nil || prod["fourEyes"] != true {
		t.Fatalf("expected a production hop with fourEyes=true, got gates=%v", gates)
	}
}

// Chain metadata is not public — it needs the same auth as /me.
func TestEnvironmentsRequiresAuth(t *testing.T) {
	_, h, _ := newTestServer(t)
	if code, body := do(t, h, "GET", "/api/v1/environments", "", nil); code != 401 || errCode(body) != "UNAUTHORIZED" {
		t.Fatalf("unauthenticated /environments = %d %v, want 401 UNAUTHORIZED", code, body)
	}
}
