// Package output defines the machine-readable result shapes shared by the
// labctl commands and the governance BFF (Console Light), plus the -o/--output
// format selection. The JSON forms are a CONTRACT: the per-target object is
// {gateway, type, ...} and every aggregate is {ok, targets:[...]}, so the same
// payload feeds the CLI table, the console's validation screen and the evidence
// pack. Keys are snake_case and stable — renaming one is a breaking change.
//
// Rules:
//   - in JSON mode, stdout carries the JSON document ONLY; human logs go to
//     stderr (commands enforce this, WriteJSON just encodes);
//   - no field shown in the human table may be dropped from the JSON view;
//   - no secret material ever appears in any report (same rule as the tables).
package output

import (
	"encoding/json"
	"fmt"
	"io"
)

// Format is the rendering mode selected by -o/--output.
type Format string

const (
	// FormatTable renders aligned human tables (the default).
	FormatTable Format = "table"
	// FormatJSON renders one stable JSON document on stdout, logs on stderr.
	FormatJSON Format = "json"
)

// ParseFormat validates an -o/--output value. The empty string means the
// default (table), so callers can pass the raw flag through.
func ParseFormat(s string) (Format, error) {
	switch s {
	case "", string(FormatTable):
		return FormatTable, nil
	case string(FormatJSON):
		return FormatJSON, nil
	default:
		return "", fmt.Errorf("unsupported output format %q (supported: table, json)", s)
	}
}

// Plan actions — what `labctl apply` WOULD do on one gateway. ActionUnknown is
// reserved for gateways the plan could not assess (unreachable, bad adapter);
// the plan is a report, so unknown never changes the exit code.
const (
	ActionCreate  = "create"
	ActionUpdate  = "update"
	ActionNone    = "none"
	ActionUnknown = "unknown"
)

// PublishTarget is the per-gateway outcome of `labctl apply`. Fields other than
// error are always emitted (stable shape); error is present only on failure.
type PublishTarget struct {
	Gateway       string `json:"gateway"`
	Type          string `json:"type"`
	APIID         string `json:"api_id"`
	RevisionID    string `json:"revision_id"`
	InvocationURL string `json:"invocation_url"`
	Published     bool   `json:"published"`
	Created       bool   `json:"created"`
	Error         string `json:"error,omitempty"`
}

// PublishReport is the `labctl apply` aggregate: OK is true only when every
// target published.
type PublishReport struct {
	OK      bool            `json:"ok"`
	Targets []PublishTarget `json:"targets"`
}

// ConsumerTarget is the per-gateway outcome of `labctl subscribe`.
// SECURITY: it deliberately has NO field for the data-plane secret material
// (consumerKey/consumerSecret) — stdout must never carry secrets, exactly like
// the human table. CredentialIssued only reports that a secret exists in the
// 0600 credentials file.
type ConsumerTarget struct {
	Gateway          string `json:"gateway"`
	Type             string `json:"type"`
	ConsumerID       string `json:"consumer_id"`
	SubscriptionID   string `json:"subscription_id,omitempty"`
	CredentialIssued bool   `json:"credential_issued"`
	TokenHint        string `json:"token_hint,omitempty"`
	Error            string `json:"error,omitempty"`
}

// ConsumerReport is the `labctl subscribe` aggregate. ClientID is the Keycloak
// OAuth client the consumers are bound to (an identifier, not a secret);
// CredentialsFile points at the 0600 file holding the full material.
type ConsumerReport struct {
	OK              bool             `json:"ok"`
	ClientID        string           `json:"client_id"`
	CredentialsFile string           `json:"credentials_file,omitempty"`
	Targets         []ConsumerTarget `json:"targets"`
}

// ListedAPI is one API in a gateway's catalog as seen by `labctl get apis`.
type ListedAPI struct {
	APIID    string `json:"api_id"`
	Name     string `json:"name"`
	Version  string `json:"version"`
	BasePath string `json:"base_path"`
}

// ListTarget is the per-gateway slice of the federated catalog. APIs is always
// an array (possibly empty), never null, so consumers can range without checks.
type ListTarget struct {
	Gateway string      `json:"gateway"`
	Type    string      `json:"type"`
	APIs    []ListedAPI `json:"apis"`
	Error   string      `json:"error,omitempty"`
}

// ListReport is the `labctl get apis` aggregate: OK is true only when every
// gateway answered its List call.
type ListReport struct {
	OK      bool         `json:"ok"`
	Targets []ListTarget `json:"targets"`
}

// PlanTarget is the per-gateway verdict of `labctl plan`: the action apply
// would take (create|update|none|unknown) and a human-readable reason.
type PlanTarget struct {
	Gateway string `json:"gateway"`
	Type    string `json:"type"`
	Action  string `json:"action"`
	Reason  string `json:"reason"`
}

// PlanReport is the `labctl plan` aggregate: OK is true only when every gateway
// could be assessed (no "unknown" action). The plan never mutates anything and
// never fails the process on unknown — OK lets machine consumers decide.
type PlanReport struct {
	OK      bool         `json:"ok"`
	Targets []PlanTarget `json:"targets"`
}

// WriteJSON encodes v as indented JSON on w, ending with one newline — the
// single stdout document of every command run with -o json.
func WriteJSON(w io.Writer, v any) error {
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false) // CLI/evidence output, not HTML — keep "<key>" literal
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}
