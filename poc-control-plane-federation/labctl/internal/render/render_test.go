package render

import (
	"strings"
	"testing"
)

func TestDerive(t *testing.T) {
	cases := []struct {
		name      string
		in        Input
		wantAuthn string
		wantHas   []string // policies that MUST be present
		wantErr   string   // substring; "" = expect success
	}{
		{"VH internal", Input{Classification: "VH", Exposure: "internal"}, "oauth2+mtls", []string{"oauth2", "mtls", "rate-limit", "audit-log"}, ""},
		{"VH external adds ip-allowlist", Input{Classification: "VH", Exposure: "external"}, "oauth2+mtls", []string{"oauth2", "mtls", "ip-allowlist"}, ""},
		{"H", Input{Classification: "H", Exposure: "internal"}, "oauth2", []string{"oauth2"}, ""},
		{"M default oauth2", Input{Classification: "M", Exposure: "internal"}, "oauth2", []string{"oauth2"}, ""},
		{"M apikey exception internal", Input{Classification: "M", Exposure: "internal", Tags: []string{AuthExceptionApiKey}}, "apikey", []string{"apikey"}, ""},
		{"exposure defaults to internal", Input{Classification: "H"}, "oauth2", []string{"oauth2"}, ""},

		{"unknown classification VVH rejected", Input{Classification: "VVH"}, "", nil, "inconnue"},
		{"empty classification rejected", Input{Classification: ""}, "", nil, "inconnue"},
		{"bad exposure rejected", Input{Classification: "H", Exposure: "public"}, "", nil, "exposure"},
		{"apikey exception on VH rejected", Input{Classification: "VH", Exposure: "internal", Tags: []string{AuthExceptionApiKey}}, "", nil, "uniquement M"},
		{"apikey exception on H rejected", Input{Classification: "H", Exposure: "internal", Tags: []string{AuthExceptionApiKey}}, "", nil, "uniquement M"},
		{"apikey exception external rejected", Input{Classification: "M", Exposure: "external", Tags: []string{AuthExceptionApiKey}}, "", nil, "uniquement internal"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			res, err := Derive(tc.in)
			if tc.wantErr != "" {
				if err == nil {
					t.Fatalf("expected error containing %q, got nil (res=%+v)", tc.wantErr, res)
				}
				if !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("error %q does not contain %q", err.Error(), tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if res.Authn != tc.wantAuthn {
				t.Errorf("authn = %q, want %q", res.Authn, tc.wantAuthn)
			}
			set := map[string]bool{}
			for _, p := range res.RequiredPolicies {
				set[p] = true
			}
			for _, want := range tc.wantHas {
				if !set[want] {
					t.Errorf("required_policies %v missing %q", res.RequiredPolicies, want)
				}
			}
			// apikey and oauth2 are mutually exclusive.
			if set["apikey"] && set["oauth2"] {
				t.Errorf("apikey and oauth2 both present: %v", res.RequiredPolicies)
			}
		})
	}
}
