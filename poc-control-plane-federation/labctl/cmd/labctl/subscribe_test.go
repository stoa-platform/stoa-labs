package cmd

import (
	"strings"
	"testing"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
)

// maskCredential must NEVER return secret material — not the apikey, not the
// consumerKey/secret. It only reports presence so the table stays informative.
func TestMaskCredential_NoSecretLeak(t *testing.T) {
	secret := "ab12cd34ef56gh78ij90kl12mn34" // looks like a real apikey
	res := &adapter.ConsumerResult{
		ConsumerID:     "app-1",
		ConsumerKey:    secret,
		ConsumerSecret: "s3cr3t-signing-material",
	}
	got := maskCredential(res)
	if strings.Contains(got, secret) {
		t.Fatalf("maskCredential leaked the consumerKey: %q", got)
	}
	if strings.Contains(got, res.ConsumerSecret) {
		t.Fatalf("maskCredential leaked the consumerSecret: %q", got)
	}
	// Even a 6-char prefix must not appear.
	if strings.Contains(got, secret[:6]) {
		t.Fatalf("maskCredential leaked a secret prefix: %q", got)
	}
	if !strings.Contains(got, credentialsFile) {
		t.Errorf("masked cell should point to the credentials file, got %q", got)
	}
}

// A gateway with no secret material (e.g. webMethods mock) renders "(none)".
func TestMaskCredential_NoSecret(t *testing.T) {
	res := &adapter.ConsumerResult{ConsumerID: "sub-1"}
	if got := maskCredential(res); got != "(none)" {
		t.Errorf("no-secret credential = %q, want (none)", got)
	}
}

// renderCredentials must write the banner and the FULL secret material (this is
// the file written 0600), while a TokenHint template is recorded verbatim.
func TestRenderCredentials_BannerAndFullSecrets(t *testing.T) {
	outcomes := []consumerOutcome{
		{
			name: "wso2",
			res: &adapter.ConsumerResult{
				ConsumerID:     "app-42",
				SubscriptionID: "sub-7",
				ConsumerKey:    "WSO2-CONSUMER-KEY",
				ConsumerSecret: "WSO2-CONSUMER-SECRET",
				TokenHint:      "POST /token Basic(consumerKey:consumerSecret) grant_type=client_credentials",
			},
		},
		{
			name: "apisix",
			res: &adapter.ConsumerResult{
				ConsumerID:  "consumer_x",
				ConsumerKey: "APISIX-APIKEY",
				TokenHint:   "send header apikey: <key> to http://apisix:9080/x/v1",
			},
		},
		{name: "broken", res: nil, err: errSentinel{}},
	}

	var b strings.Builder
	if err := renderCredentials(&b, "demo-client", "KEYCLOAK-SUPER-SECRET", outcomes); err != nil {
		t.Fatalf("renderCredentials: %v", err)
	}
	doc := b.String()

	if !strings.Contains(doc, "PoC synthetic credentials") {
		t.Errorf("missing banner; got:\n%s", doc)
	}
	for _, want := range []string{
		"demo-client",
		"KEYCLOAK-SUPER-SECRET",
		"WSO2-CONSUMER-KEY",
		"WSO2-CONSUMER-SECRET",
		"sub-7",
		"APISIX-APIKEY",
		"send header apikey: <key>",
	} {
		if !strings.Contains(doc, want) {
			t.Errorf("credentials file missing %q; got:\n%s", want, doc)
		}
	}
	// The nil-result outcome must be skipped, not panic / emit an empty section.
	if strings.Contains(doc, "[broken]") {
		t.Errorf("nil-result outcome should be skipped; got:\n%s", doc)
	}
}

type errSentinel struct{}

func (errSentinel) Error() string { return "boom" }
