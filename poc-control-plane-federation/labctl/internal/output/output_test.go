package output

import (
	"bytes"
	"strings"
	"testing"
)

func TestParseFormat(t *testing.T) {
	cases := []struct {
		in      string
		want    Format
		wantErr bool
	}{
		{"", FormatTable, false},
		{"table", FormatTable, false},
		{"json", FormatJSON, false},
		{"yaml", "", true},
		{"JSON", "", true}, // strict: no case folding, the flag is a contract
	}
	for _, tc := range cases {
		got, err := ParseFormat(tc.in)
		if tc.wantErr {
			if err == nil {
				t.Errorf("ParseFormat(%q): expected error, got %q", tc.in, got)
			}
			continue
		}
		if err != nil || got != tc.want {
			t.Errorf("ParseFormat(%q) = (%q, %v), want (%q, nil)", tc.in, got, err, tc.want)
		}
	}
}

// The JSON key set is a CONTRACT with the governance BFF: this golden test
// fails on any rename/removal so the break is explicit, not silent.
func TestPublishReportJSONShapeIsStable(t *testing.T) {
	r := PublishReport{
		OK: false,
		Targets: []PublishTarget{
			{
				Gateway:       "wso2-dev",
				Type:          "wso2",
				APIID:         "uuid-1",
				RevisionID:    "rev-1",
				InvocationURL: "https://wso2am:8243/accounts-read/v1",
				Published:     true,
				Created:       true,
			},
			{Gateway: "apisix-dev", Type: "apisix", Error: "health: unreachable"},
		},
	}
	var buf bytes.Buffer
	if err := WriteJSON(&buf, r); err != nil {
		t.Fatalf("WriteJSON: %v", err)
	}
	want := `{
  "ok": false,
  "targets": [
    {
      "gateway": "wso2-dev",
      "type": "wso2",
      "api_id": "uuid-1",
      "revision_id": "rev-1",
      "invocation_url": "https://wso2am:8243/accounts-read/v1",
      "published": true,
      "created": true
    },
    {
      "gateway": "apisix-dev",
      "type": "apisix",
      "api_id": "",
      "revision_id": "",
      "invocation_url": "",
      "published": false,
      "created": false,
      "error": "health: unreachable"
    }
  ]
}
`
	if buf.String() != want {
		t.Errorf("PublishReport JSON drifted from the contract.\ngot:\n%s\nwant:\n%s", buf.String(), want)
	}
}

func TestConsumerReportJSONShapeIsStable(t *testing.T) {
	r := ConsumerReport{
		OK:              true,
		ClientID:        "accounts-read-consumer",
		CredentialsFile: "labctl-credentials.txt",
		Targets: []ConsumerTarget{
			{
				Gateway:          "apisix-dev",
				Type:             "apisix",
				ConsumerID:       "accounts_read_consumer",
				SubscriptionID:   "sub-0001",
				CredentialIssued: true,
				TokenHint:        "apikey: <key>",
			},
		},
	}
	var buf bytes.Buffer
	if err := WriteJSON(&buf, r); err != nil {
		t.Fatalf("WriteJSON: %v", err)
	}
	want := `{
  "ok": true,
  "client_id": "accounts-read-consumer",
  "credentials_file": "labctl-credentials.txt",
  "targets": [
    {
      "gateway": "apisix-dev",
      "type": "apisix",
      "consumer_id": "accounts_read_consumer",
      "subscription_id": "sub-0001",
      "credential_issued": true,
      "token_hint": "apikey: <key>"
    }
  ]
}
`
	if buf.String() != want {
		t.Errorf("ConsumerReport JSON drifted from the contract.\ngot:\n%s\nwant:\n%s", buf.String(), want)
	}
}

func TestListReportJSONShapeIsStable(t *testing.T) {
	r := ListReport{
		OK: false,
		Targets: []ListTarget{
			{
				Gateway: "wso2-dev",
				Type:    "wso2",
				APIs: []ListedAPI{
					{APIID: "uuid-1", Name: "accounts-read", Version: "1.0.0", BasePath: "/accounts-read/v1"},
				},
			},
			{Gateway: "webmethods-dev", Type: "webmethods", APIs: []ListedAPI{}, Error: "connection refused"},
		},
	}
	var buf bytes.Buffer
	if err := WriteJSON(&buf, r); err != nil {
		t.Fatalf("WriteJSON: %v", err)
	}
	want := `{
  "ok": false,
  "targets": [
    {
      "gateway": "wso2-dev",
      "type": "wso2",
      "apis": [
        {
          "api_id": "uuid-1",
          "name": "accounts-read",
          "version": "1.0.0",
          "base_path": "/accounts-read/v1"
        }
      ]
    },
    {
      "gateway": "webmethods-dev",
      "type": "webmethods",
      "apis": [],
      "error": "connection refused"
    }
  ]
}
`
	if buf.String() != want {
		t.Errorf("ListReport JSON drifted from the contract.\ngot:\n%s\nwant:\n%s", buf.String(), want)
	}
}

func TestPlanReportJSONShapeIsStable(t *testing.T) {
	r := PlanReport{
		OK: false,
		Targets: []PlanTarget{
			{Gateway: "wso2-dev", Type: "wso2", Action: ActionNone, Reason: "already published"},
			{Gateway: "apisix-dev", Type: "apisix", Action: ActionUnknown, Reason: "connection refused"},
		},
	}
	var buf bytes.Buffer
	if err := WriteJSON(&buf, r); err != nil {
		t.Fatalf("WriteJSON: %v", err)
	}
	want := `{
  "ok": false,
  "targets": [
    {
      "gateway": "wso2-dev",
      "type": "wso2",
      "action": "none",
      "reason": "already published"
    },
    {
      "gateway": "apisix-dev",
      "type": "apisix",
      "action": "unknown",
      "reason": "connection refused"
    }
  ]
}
`
	if buf.String() != want {
		t.Errorf("PlanReport JSON drifted from the contract.\ngot:\n%s\nwant:\n%s", buf.String(), want)
	}
}

// Empty target lists must serialize as [] (not null) so machine consumers can
// range over targets unconditionally.
func TestEmptyTargetsSerializeAsArray(t *testing.T) {
	var buf bytes.Buffer
	if err := WriteJSON(&buf, PublishReport{OK: true, Targets: []PublishTarget{}}); err != nil {
		t.Fatalf("WriteJSON: %v", err)
	}
	if strings.Contains(buf.String(), "null") {
		t.Errorf("empty targets rendered as null, want []:\n%s", buf.String())
	}
	if !strings.Contains(buf.String(), `"targets": []`) {
		t.Errorf("empty targets not rendered as []:\n%s", buf.String())
	}
}
