package governance

import "testing"

// validContract builds a minimal valid UAC v1 contract (1 endpoint).
func validContract() map[string]any {
	return map[string]any{
		"name":           "payments-initiation",
		"version":        "1.0.0",
		"tenant_id":      "banking-demo",
		"classification": "VH",
		"status":         "draft",
		"endpoints": []any{
			map[string]any{
				"path":        "/payments",
				"methods":     []any{"POST"},
				"backend_url": "http://backend:8080",
			},
		},
	}
}

// hasCode reports whether one error carries the given code on the given path.
func hasCode(errs []ValidationError, path, code string) bool {
	for _, e := range errs {
		if e.Path == path && e.Code == code {
			return true
		}
	}
	return false
}

func TestValidDraftPasses(t *testing.T) {
	if errs := ValidateUAC(validContract(), false); len(errs) != 0 {
		t.Fatalf("expected no errors, got %v", errs)
	}
}

func TestDestructiveRequiresHumanApproval(t *testing.T) {
	c := validContract()
	ep := c["endpoints"].([]any)[0].(map[string]any)
	ep["llm"] = map[string]any{
		"summary":                 "Annule un paiement",
		"intent":                  "annulation",
		"tool_name":               "cancel_payment",
		"side_effects":            "destructive",
		"safe_for_agents":         false,
		"requires_human_approval": false, // the violation
		"examples":                []any{map[string]any{"input": map[string]any{}}},
	}
	errs := ValidateUAC(c, false)
	if !hasCode(errs, "endpoints[0].llm.requires_human_approval", "DESTRUCTIVE_REQUIRES_APPROVAL") {
		t.Fatalf("expected DESTRUCTIVE_REQUIRES_APPROVAL, got %v", errs)
	}

	// Fixing the flag clears the rule.
	ep["llm"].(map[string]any)["requires_human_approval"] = true
	if errs := ValidateUAC(c, false); len(errs) != 0 {
		t.Fatalf("expected no errors once approval required, got %v", errs)
	}
}

func TestDestructiveMissingApprovalFieldStillFlagged(t *testing.T) {
	c := validContract()
	ep := c["endpoints"].([]any)[0].(map[string]any)
	ep["llm"] = map[string]any{
		"summary":         "Annule un paiement",
		"intent":          "annulation",
		"tool_name":       "cancel_payment",
		"side_effects":    "destructive",
		"safe_for_agents": false,
		// requires_human_approval absent
		"examples": []any{map[string]any{"input": map[string]any{}}},
	}
	errs := ValidateUAC(c, false)
	if !hasCode(errs, "endpoints[0].llm.requires_human_approval", "DESTRUCTIVE_REQUIRES_APPROVAL") {
		t.Fatalf("missing field must still trigger the destructive rule, got %v", errs)
	}
}

func TestPublishedRequiresEndpoint(t *testing.T) {
	c := validContract()
	c["status"] = "published"
	c["endpoints"] = []any{}
	errs := ValidateUAC(c, true)
	if !hasCode(errs, "endpoints", "PUBLISHED_REQUIRES_ENDPOINT") {
		t.Fatalf("expected PUBLISHED_REQUIRES_ENDPOINT, got %v", errs)
	}
}

func TestRequiredEnumAndPatternChecks(t *testing.T) {
	c := map[string]any{
		"name":           "Bad_Name",
		"version":        "1.0",
		"classification": "LOW",
		"status":         "live",
		"endpoints": []any{
			map[string]any{
				"path":    "",
				"methods": []any{"FETCH"},
			},
		},
	}
	errs := ValidateUAC(c, false)
	for _, want := range []struct{ path, code string }{
		{"name", "PATTERN"},
		{"version", "PATTERN"},
		{"tenant_id", "REQUIRED"},
		{"classification", "ENUM"},
		{"status", "ENUM"},
		{"endpoints[0].path", "REQUIRED"},
		{"endpoints[0].backend_url", "REQUIRED"},
		{"endpoints[0].methods[0]", "ENUM"},
	} {
		if !hasCode(errs, want.path, want.code) {
			t.Errorf("missing error %s on %s in %v", want.code, want.path, errs)
		}
	}
}
