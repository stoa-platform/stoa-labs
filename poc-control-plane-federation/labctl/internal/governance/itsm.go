package governance

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// ITSMClient queries the change-management system (cmd/itsm-mock in the lab, a
// real ITSM in production) for the status of a change reference — the external
// control of the production gate. Fail-closed by construction: every transport
// or HTTP error surfaces to the caller, a promotion is NEVER approved on a
// silent ITSM failure.
type ITSMClient struct {
	BaseURL string
	client  *http.Client
}

// NewITSMClient builds the client; an empty base returns nil — "ITSM not
// configured", which the gate evaluation treats as a 503 refusal (fail-closed),
// never as a pass.
func NewITSMClient(base string) *ITSMClient {
	base = strings.TrimRight(base, "/")
	if base == "" {
		return nil
	}
	return &ITSMClient{BaseURL: base, client: &http.Client{Timeout: 5 * time.Second}}
}

// ErrChangeUnknown is returned when the ITSM answers 404: the change does not
// exist. It is NOT an outage — the ITSM answered, and it answered that it has
// no such change (a typo'd change_ref, or one deleted since the merge). The
// caller must archive it as "not approved", never as "ITSM unavailable":
// pointing the on-call at a healthy ITSM is a diagnosis that lies. Mirror of
// the shell gate, which has always said so (provision-apply-gate.sh:
// `404) refus ITSM_NOT_APPROVED … un change inconnu n'est pas un change
// approuvé`). Divergence mesurée et fermée le 2026-09-06.
var ErrChangeUnknown = errors.New("itsm: change unknown")

// ChangeStatus GETs {base}/changes/{id} and returns its "status" field.
// Anything but a 200 with a non-empty status is an error; a 404 is
// ErrChangeUnknown so callers can tell "no such change" from "ITSM broken".
func (c *ITSMClient) ChangeStatus(ctx context.Context, id string) (string, error) {
	if id == "" {
		return "", fmt.Errorf("itsm: empty change reference")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.BaseURL+"/changes/"+url.PathEscape(id), nil)
	if err != nil {
		return "", fmt.Errorf("itsm: build request: %w", err)
	}
	resp, err := c.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("itsm: fetch change %s: %w", id, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return "", fmt.Errorf("%w: %s", ErrChangeUnknown, id)
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("itsm: change %s -> HTTP %d", id, resp.StatusCode)
	}
	var doc struct {
		ID     string `json:"id"`
		Status string `json:"status"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
		return "", fmt.Errorf("itsm: decode change %s: %w", id, err)
	}
	if doc.Status == "" {
		return "", fmt.Errorf("itsm: change %s has no status", id)
	}
	return doc.Status, nil
}
