package webmethods

import "testing"

// TestNormalizeIPRange pins the from-to normalization that closes the CIDR
// silent-drop and the UI-hides-a-bare-single quirks (both live-pinned 2026-07-15).
func TestNormalizeIPRange(t *testing.T) {
	cases := []struct{ in, want string }{
		{"192.168.65.1", "192.168.65.1-192.168.65.1"},           // single -> X-X
		{" 10.0.0.7 ", "10.0.0.7-10.0.0.7"},                     // trimmed
		{"10.60.30.1-10.60.30.30", "10.60.30.1-10.60.30.30"},    // range unchanged
		{"192.168.65.0/24", "192.168.65.0-192.168.65.255"},      // CIDR -> first-last
		{"10.0.0.0/8", "10.0.0.0-10.255.255.255"},               // CIDR /8
	}
	for _, c := range cases {
		got, err := normalizeIPRange(c.in)
		if err != nil {
			t.Errorf("normalizeIPRange(%q) error: %v", c.in, err)
			continue
		}
		if got != c.want {
			t.Errorf("normalizeIPRange(%q) = %q, want %q", c.in, got, c.want)
		}
	}
	if _, err := normalizeIPRange("not-an-ip"); err == nil {
		t.Error("normalizeIPRange(\"not-an-ip\") should error")
	}
}

// ruleTypesOf extracts the (applicationLookup, identificationType) of every
// IdentificationRule of an enveloped policyAction body, in order.
func ruleTypesOf(t *testing.T, body map[string]any) (connector string, anon string, rules [][2]string) {
	t.Helper()
	action, _ := body["policyAction"].(map[string]any)
	if action == nil {
		t.Fatalf("body carries no policyAction envelope: %v", body)
	}
	if tk, _ := action["templateKey"].(string); tk != "evaluatePolicy" {
		t.Fatalf("templateKey = %q, want evaluatePolicy", tk)
	}
	params, _ := action["parameters"].([]any)
	for _, p := range params {
		pm, _ := p.(map[string]any)
		vals, _ := pm["values"].([]any)
		v0 := ""
		if len(vals) > 0 {
			v0, _ = vals[0].(string)
		}
		switch pm["templateKey"] {
		case "logicalConnector":
			connector = v0
		case "allowAnonymous":
			anon = v0
		case "IdentificationRule":
			var lookup, idType string
			nested, _ := pm["parameters"].([]any)
			for _, n := range nested {
				nm, _ := n.(map[string]any)
				nv, _ := nm["values"].([]any)
				s := ""
				if len(nv) > 0 {
					s, _ = nv[0].(string)
				}
				switch nm["templateKey"] {
				case "applicationLookup":
					lookup = s
				case "identificationType":
					idType = s
				}
			}
			rules = append(rules, [2]string{lookup, idType})
		}
	}
	return connector, anon, rules
}

// TestIdentifyAndActionBody_CertIP asserts the self-service enforcement body:
// AND, no-anonymous, and one strict rule PER dimension (cert + IP) — the rule
// set that OPPOSES the identifiers and closes the fail-open (ADR-078).
func TestIdentifyAndActionBody_CertIP(t *testing.T) {
	body := identifyAndActionBody("", "identify (demo)", []string{identificationTypeCert, identificationTypeIP})
	connector, anon, rules := ruleTypesOf(t, body)
	if connector != "AND" {
		t.Errorf("logicalConnector = %q, want AND", connector)
	}
	if anon != "false" {
		t.Errorf("allowAnonymous = %q, want false", anon)
	}
	want := [][2]string{{"strict", "httpsCertificate"}, {"strict", "ipAddressRange"}}
	if len(rules) != len(want) {
		t.Fatalf("rules = %v, want %v", rules, want)
	}
	for i, w := range want {
		if rules[i] != w {
			t.Errorf("rule[%d] = %v, want %v", i, rules[i], w)
		}
	}
	// no id on a create body; id set on a converge body
	if _, ok := body["policyAction"].(map[string]any)["id"]; ok {
		t.Error("create body must not carry an id")
	}
	if id := identifyAndActionBody("abc123", "x", []string{identificationTypeIP})["policyAction"].(map[string]any)["id"]; id != "abc123" {
		t.Errorf("converge body id = %v, want abc123", id)
	}
}

// TestMtlsIdentifyActionBody_Unchanged pins that the mtls refactor onto the
// general builder preserves the live-validated OAuth2+cert AND shape.
func TestMtlsIdentifyActionBody_Unchanged(t *testing.T) {
	connector, anon, rules := ruleTypesOf(t, mtlsIdentifyActionBody(""))
	if connector != "AND" || anon != "false" {
		t.Fatalf("connector=%q anon=%q, want AND/false", connector, anon)
	}
	want := [][2]string{{"strict", "oAuth2Token"}, {"strict", "httpsCertificate"}}
	if len(rules) != len(want) {
		t.Fatalf("rules = %v, want %v", rules, want)
	}
	for i, w := range want {
		if rules[i] != w {
			t.Errorf("rule[%d] = %v, want %v", i, rules[i], w)
		}
	}
	// the mtls fingerprint (isMtlsIdentifyAction) must still recognize it.
	if !isMtlsIdentifyAction(mtlsIdentifyActionBody("")["policyAction"].(map[string]any)) {
		t.Error("isMtlsIdentifyAction no longer recognizes its own body after refactor")
	}
}
