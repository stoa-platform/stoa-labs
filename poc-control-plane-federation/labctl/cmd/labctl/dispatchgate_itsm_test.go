package cmd

import (
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"strings"
	"testing"
)

// itsmServerCode serves an arbitrary HTTP status for any /changes/{id} GET.
func itsmServerCode(t *testing.T, code int) *httptest.Server {
	t.Helper()
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(code)
		_, _ = w.Write([]byte(`{"error":"no such change"}`))
	}))
	t.Cleanup(s.Close)
	return s
}

// TestDispatchGate_UnknownChangeIsNotApproved pins DIVERGENCE #1 (mesurée
// 2026-09-06). Both engines refuse a 404 — but they used to disagree on WHY,
// and the "why" is the audit reason archived for the run:
//
//	shell (provision-apply-gate.sh) : 404 → ITSM_NOT_APPROVED
//	                                  « un change inconnu n'est pas un change approuvé »
//	Go   (this gate)                : 404 → ITSM_UNAVAILABLE  ← faux
//
// ITSM_UNAVAILABLE says "the ITSM is down", which sends the on-call to the
// wrong system: the ITSM answered perfectly, it simply does not know that
// change (a typo'd change_ref, or one deleted since the merge). The Go file's
// own header demands this distinction — "an ITSM outage or a missing
// change_ref must never be archived as an 'itsm revocation' (forensics,
// ADR-070)"; an unknown change must not be archived as an outage either.
func TestDispatchGate_UnknownChangeIsNotApproved(t *testing.T) {
	repo := dgWriteRepo(t, "CHG-0001", true)
	t.Setenv("ITSM_URL", itsmServerCode(t, http.StatusNotFound).URL)
	err := gate(t, repo, "prod")
	if err == nil {
		t.Fatal("un change INCONNU de l'ITSM doit refuser fail-closed")
	}
	if !strings.Contains(err.Error(), "ITSM_NOT_APPROVED") {
		t.Fatalf("404 must refuse with ITSM_NOT_APPROVED (shell mirror), got %v", err)
	}
	if got := dispatchGateReason(err); got != "itsm_not_approved_at_dispatch" {
		t.Errorf("audit reason = %q, want itsm_not_approved_at_dispatch", got)
	}
}

// TestDispatchGate_ServerErrorStaysUnavailable is the counter-proof: the fix
// must SPLIT 404 out, not repaint every non-200 as "not approved". A 500 is a
// broken ITSM and must keep saying so.
func TestDispatchGate_ServerErrorStaysUnavailable(t *testing.T) {
	repo := dgWriteRepo(t, "CHG-0001", true)
	t.Setenv("ITSM_URL", itsmServerCode(t, http.StatusInternalServerError).URL)
	err := gate(t, repo, "prod")
	if err == nil || !strings.Contains(err.Error(), "ITSM_UNAVAILABLE") {
		t.Fatalf("HTTP 500 must stay ITSM_UNAVAILABLE, got %v", err)
	}
	if got := dispatchGateReason(err); got != "itsm_unavailable_at_dispatch" {
		t.Errorf("audit reason = %q, want itsm_unavailable_at_dispatch", got)
	}
}

// shellGatePath is the OTHER engine's ITSM mapping. It is inline shell (no
// sourceable function), so it cannot be executed here the way the deployer
// mirror is. What CAN be held mechanically is its table: this test goes red if
// someone edits the shell branches without editing the Go ones above.
const shellGatePath = "../../../scripts/provision-apply-gate.sh"

func TestITSMCodeMappingMirrorsShell(t *testing.T) {
	raw, err := os.ReadFile(shellGatePath)
	if err != nil {
		t.Fatalf("read %s: %v — le miroir shell ne peut pas être tenu", shellGatePath, err)
	}
	src := string(raw)
	for _, want := range []struct {
		name string
		re   string
	}{
		{"404 → ITSM_NOT_APPROVED", `(?m)^\s*404\)\s*refus ITSM_NOT_APPROVED`},
		{"autre code → ITSM_UNAVAILABLE", `(?m)^\s*\*\)\s*refus ITSM_UNAVAILABLE`},
		{"200 non-approved → ITSM_NOT_APPROVED", `refus ITSM_NOT_APPROVED "le change '\$\{MK_CHANGE\}' est '\$\{ITSM_STATUS`},
	} {
		if !regexp.MustCompile(want.re).MatchString(src) {
			t.Errorf("la table ITSM du shell a bougé : %q introuvable dans %s — les deux moteurs ne sont plus tenus", want.name, shellGatePath)
		}
	}
}
