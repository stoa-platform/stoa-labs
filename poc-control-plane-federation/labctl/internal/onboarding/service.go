package onboarding

import (
	"context"
	"fmt"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/governance"
)

// gitWriter is the subset of governance.Repo this service needs — the
// write-through-Git primitive (switch main, write the file, commit as the
// actor, idempotent no-op when the content is unchanged). Narrowed to an
// interface so the service is testable without a real git binary.
type gitWriter interface {
	CommitFiles(ctx context.Context, actor governance.Actor, files map[string][]byte, subject, body string) (governance.CommitInfo, error)
	Exists(ctx context.Context, ref, path string) bool
}

// Service is the write-through-Git onboarding engine. It owns NO gateway
// client: its only side effect is a commit in the governance repo (ADR-068).
type Service struct {
	Repo gitWriter
}

// Result is what POST /applications returns: the manifest path + the commit it
// landed in (so the caller can follow the PR / CI that converges the gateways).
type Result struct {
	Path    string                 `json:"path"`
	Created bool                   `json:"created"`
	Commit  governance.CommitInfo `json:"commit"`
}

// Onboard validates the request, projects it onto a manifest and writes that
// manifest to Git as one commit authored by `actor`. It returns field-level
// validation errors (non-nil) for a 400, or the commit result for a 201/200.
//
// It NEVER touches a gateway: the commit is the whole transaction. The client's
// CI (or a `labctl subscribe` run over the manifest) is what converges
// webMethods — keeping STOA off the data path and Git the single source of
// truth (ADR-067/068/069).
func (s *Service) Onboard(ctx context.Context, req Request, actor governance.Actor) (*Result, []string, error) {
	m, verrs := req.ToManifest()
	if len(verrs) > 0 {
		return nil, verrs, nil
	}

	content, err := m.YAML()
	if err != nil {
		return nil, nil, fmt.Errorf("render manifest: %w", err)
	}

	path := m.Path()
	existed := s.Repo.Exists(ctx, "main", path)

	subject := fmt.Sprintf("feat(partner): onboard %s/%s as-code", m.Metadata.Tenant, m.Metadata.Name)
	body := governance.TrailerBlock(
		"partner.onboard",
		fmt.Sprintf("tenants/%s/partners/%s", m.Metadata.Tenant, m.Metadata.Name),
		actor,
		"—",
	)

	commit, err := s.Repo.CommitFiles(ctx, actor, map[string][]byte{path: content}, subject, body)
	if err != nil {
		return nil, nil, fmt.Errorf("commit partner manifest: %w", err)
	}

	return &Result{Path: path, Created: !existed, Commit: commit}, nil, nil
}
