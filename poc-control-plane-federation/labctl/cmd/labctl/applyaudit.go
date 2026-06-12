package cmd

import (
	"context"
	"io"
	"log"
	"os"
	"os/exec"
	"strings"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/audit"
)

// applyAuditor records every gateway mutation (and the run-level denials) of an
// apply run to the per-tenant audit-apply-{tenant} index + the stdout OTel
// bridge (ADR-070). Attribution is Git-first (ADR-069): the human Actor is the
// COMMIT AUTHOR of the manifest, the cp-applier CI service account is the
// Principal — so even though the gateway only ever sees the platform admin
// credential, "who changed what for which tenant" is always recoverable.
//
// The OpenSearch sink is OPT-IN: an empty $OPENSEARCH_URL keeps the stdout sink
// only (still fully auditable), so a plain apply-uac run — and the test suite —
// never reaches OpenSearch unless asked to.
type applyAuditor struct {
	sink      audit.Sink
	repoDir   string
	principal principal
	fallback  string
}

func newApplyAuditor(repoDir string, prin principal, logw io.Writer) *applyAuditor {
	osURL := envOr("OPENSEARCH_URL", "") // empty → stdout-only sink (no network)
	rec := audit.NewRecorder(osURL, envOr("OPENSEARCH_USER", "admin"), os.Getenv("OPENSEARCH_PASSWORD"),
		boolEnvDefault("OPENSEARCH_INSECURE", true), log.New(logw, "", 0))
	rec.IndexPrefix = "audit-apply"
	rec.OTLPEndpoint = envOr("OTEL_EXPORTER_OTLP_ENDPOINT", "") // real Tempo span per mutation
	return &applyAuditor{sink: rec, repoDir: repoDir, principal: prin, fallback: envOr("LABCTL_ACTOR", "")}
}

// commitFor reads the author + sha of the last commit touching path — Git-first
// attribution (ADR-069). Empty when the repo is not a git worktree or the path
// is untracked (best-effort: attribution degrades, it never blocks an apply).
func (a *applyAuditor) commitFor(path string) (author, sha string) {
	if a.repoDir == "" || path == "" {
		return "", ""
	}
	out, err := exec.Command("git", "-C", a.repoDir, "log", "-1", "--format=%an%x1f%H", "--", path).Output()
	if err != nil {
		return "", ""
	}
	parts := strings.SplitN(strings.TrimSpace(string(out)), "\x1f", 2)
	if len(parts) != 2 {
		return "", ""
	}
	return parts[0], parts[1]
}

// actorFor resolves the responsible identity: the Git commit author when known
// (ADR-069), else the cp-applier principal, else $LABCTL_ACTOR, else "unknown".
// An audited event is never left unattributed.
func (a *applyAuditor) actorFor(commitAuthor string) string {
	if commitAuthor != "" {
		return commitAuthor
	}
	if a.principal.OK && a.principal.Actor != "" {
		return a.principal.Actor
	}
	if a.fallback != "" {
		return a.fallback
	}
	return "unknown"
}

// record stamps the cp-applier principal (the CI service account) onto the event
// and routes it to both sinks.
func (a *applyAuditor) record(ctx context.Context, ev audit.Event) {
	if a.principal.OK {
		ev.Principal = a.principal.Actor
	}
	a.sink.Record(ctx, ev)
}
