package governance

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

// Repo wraps the governance Git repository (contract §3). Every write goes
// through ONE global mutex (rule 7), is committed with author = the human
// actor and committer = governance-bot (rule 2), and the response content is
// RE-READ from Git after the commit (rule 1) — the HTTP payload never
// projects directly.
//
// Signing is the repo's own config (commit.gpgsign=true + SSH key, set by the
// seed script): the BFF never passes -S so test repos can switch it off.
type Repo struct {
	Dir string
	// PushRemote, when non-empty, makes every successful commit PUSH the current
	// branch to that remote (git push <remote> HEAD) — and a push failure IS a
	// commit failure (fail-closed: a consumer that re-clones the remote, like
	// Jenkinsfile.rollback's re-apply stage, must never observe a state older
	// than what the API just answered). Empty (the default) = strictly the old
	// local-only behaviour — labctl and every existing test are unaffected.
	// Wired from GOVERNANCE_GIT_PUSH_REMOTE by cmd/governance-api (ADR-075/078;
	// closes the tracked P1 debt "governance-api sans push Git").
	PushRemote string
	mu         sync.Mutex
}

// CommitInfo is the uniform commit echo returned by write endpoints.
type CommitInfo struct {
	SHA     string `json:"sha"`
	SHA7    string `json:"sha7"`
	Signed  bool   `json:"signed"`
	Message string `json:"message"`
}

// AuditEntry is one git-log record projected for GET /audit: identity fields
// from the commit, action metadata from the §3 trailers.
type AuditEntry struct {
	SHA      string   `json:"sha"`
	SHA7     string   `json:"sha7"`
	Author   string   `json:"author"`
	Email    string   `json:"email"`
	Date     string   `json:"date"`
	Action   string   `json:"action"`
	Resource string   `json:"resource"`
	Actor    string   `json:"actor"`
	Roles    []string `json:"roles"`
	Message  string   `json:"message"`
	Signed   bool     `json:"signed"`
	Evidence string   `json:"evidence"`
}

// OpenRepo validates that dir is a non-bare git worktree.
func OpenRepo(dir string) (*Repo, error) {
	abs, err := filepath.Abs(dir)
	if err != nil {
		return nil, fmt.Errorf("governance repo: resolve %s: %w", dir, err)
	}
	if st, err := os.Stat(filepath.Join(abs, ".git")); err != nil || !st.IsDir() {
		return nil, fmt.Errorf("governance repo: %s is not a git worktree (missing .git)", abs)
	}
	return &Repo{Dir: abs}, nil
}

// git runs one git command in the repo with the governance-bot committer
// identity pinned (author is set per-commit via --author).
func (r *Repo) git(ctx context.Context, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = r.Dir
	cmd.Env = append(os.Environ(),
		"GIT_COMMITTER_NAME=governance-bot",
		"GIT_COMMITTER_EMAIL=bot@stoa.local",
	)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	if err := cmd.Run(); err != nil {
		return out.String(), fmt.Errorf("git %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(out.String()))
	}
	return out.String(), nil
}

// TrailerBlock renders the §3 rule-3 commit body, in this exact order:
// Action, Resource, Actor, Roles, Evidence ("—" when no evidence pack).
func TrailerBlock(action, resource string, actor Actor, evidence string) string {
	if evidence == "" {
		evidence = "—"
	}
	return fmt.Sprintf("Action: %s\nResource: %s\nActor: %s\nRoles: %s\nEvidence: %s",
		action, resource, actor.Username, strings.Join(actor.Roles, ","), evidence)
}

// ReadFile returns the content of path at ref (e.g. "main", a branch, a sha).
// This is THE read primitive: responses are built from Git objects, never from
// the request payload.
func (r *Repo) ReadFile(ctx context.Context, ref, path string) ([]byte, error) {
	out, err := r.git(ctx, "show", ref+":"+path)
	if err != nil {
		return nil, err
	}
	return []byte(out), nil
}

// Exists reports whether path exists at ref.
func (r *Repo) Exists(ctx context.Context, ref, path string) bool {
	_, err := r.git(ctx, "cat-file", "-e", ref+":"+path)
	return err == nil
}

// ListDir lists the immediate entry names under dir at ref (empty slice when
// the directory does not exist).
func (r *Repo) ListDir(ctx context.Context, ref, dir string) ([]string, error) {
	out, err := r.git(ctx, "ls-tree", "--name-only", ref, strings.TrimSuffix(dir, "/")+"/")
	if err != nil {
		if strings.Contains(err.Error(), "Not a valid object name") ||
			strings.Contains(err.Error(), "exists on disk, but not in") {
			return nil, err
		}
		// Unknown path under a valid ref -> empty listing, not an error.
		return []string{}, nil
	}
	var names []string
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line == "" {
			continue
		}
		names = append(names, filepath.Base(line))
	}
	sort.Strings(names)
	return names, nil
}

// head returns the commit info of ref (HEAD by default).
func (r *Repo) head(ctx context.Context, ref string) (CommitInfo, error) {
	if ref == "" {
		ref = "HEAD"
	}
	out, err := r.git(ctx, "log", "-1", "--format=%H%x1f%h%x1f%G?%x1f%s", ref)
	if err != nil {
		return CommitInfo{}, err
	}
	f := strings.Split(strings.TrimRight(out, "\n"), "\x1f")
	if len(f) < 4 {
		return CommitInfo{}, fmt.Errorf("git log: unexpected head format %q", out)
	}
	return CommitInfo{SHA: f[0], SHA7: f[1], Signed: f[2] == "G", Message: f[3]}, nil
}

// writeWorktree writes files into the worktree (creating parents) and stages
// them. Caller holds the mutex and sits on the right branch.
func (r *Repo) writeWorktree(ctx context.Context, files map[string][]byte) error {
	paths := make([]string, 0, len(files))
	for p := range files {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	for _, p := range paths {
		full := filepath.Join(r.Dir, filepath.FromSlash(p))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			return fmt.Errorf("mkdir for %s: %w", p, err)
		}
		if err := os.WriteFile(full, files[p], 0o644); err != nil {
			return fmt.Errorf("write %s: %w", p, err)
		}
	}
	addArgs := append([]string{"add", "--"}, paths...)
	if _, err := r.git(ctx, addArgs...); err != nil {
		return err
	}
	return nil
}

// commit creates the commit with author = actor (committer stays the bot via
// env) and returns the resulting head. allowEmpty supports pure-audit commits
// (role-change) that carry no file delta.
func (r *Repo) commit(ctx context.Context, actor Actor, subject, body string, allowEmpty bool) (CommitInfo, error) {
	args := []string{"commit", "--author", fmt.Sprintf("%s <%s>", actor.Name, actor.Email), "-m", subject}
	if body != "" {
		args = append(args, "-m", body)
	}
	if allowEmpty {
		args = append(args, "--allow-empty")
	}
	if _, err := r.git(ctx, args...); err != nil {
		return CommitInfo{}, err
	}
	head, err := r.head(ctx, "HEAD")
	if err != nil {
		return CommitInfo{}, err
	}
	// Opt-in publish: the write is only DONE when the remote holds it. `HEAD`
	// pushes the branch we just committed on (main or a promotion branch).
	if r.PushRemote != "" {
		if _, err := r.git(ctx, "push", r.PushRemote, "HEAD"); err != nil {
			return CommitInfo{}, fmt.Errorf("commit %s created locally but push to %q failed (fail-closed): %w",
				head.SHA7, r.PushRemote, err)
		}
	}
	return head, nil
}

// CommitFiles is the direct-on-main write (publish dev, sub-approve, reject
// markers...): switch to main, write+stage, commit as actor, return head.
func (r *Repo) CommitFiles(ctx context.Context, actor Actor, files map[string][]byte, subject, body string) (CommitInfo, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, err := r.git(ctx, "switch", "main"); err != nil {
		return CommitInfo{}, err
	}
	if err := r.writeWorktree(ctx, files); err != nil {
		return CommitInfo{}, err
	}
	// Sauvegarde sans changement (contenu identique à HEAD) : ne pas échouer
	// sur "nothing to commit" — répondre avec le head courant, idempotent.
	if status, err := r.git(ctx, "status", "--porcelain"); err == nil && strings.TrimSpace(status) == "" {
		return r.head(ctx, "HEAD")
	}
	return r.commit(ctx, actor, subject, body, false)
}

// CommitEmpty records a pure-audit commit on main (e.g. role-change, deny):
// no file delta, only the message + trailers in the log.
func (r *Repo) CommitEmpty(ctx context.Context, actor Actor, subject, body string) (CommitInfo, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, err := r.git(ctx, "switch", "main"); err != nil {
		return CommitInfo{}, err
	}
	return r.commit(ctx, actor, subject, body, true)
}

// AppendFileAndCommit appends line to a worktree file (creating it) and
// commits — used for evidence/denials/denials.jsonl.
func (r *Repo) AppendFileAndCommit(ctx context.Context, actor Actor, path string, line []byte, subject, body string) (CommitInfo, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, err := r.git(ctx, "switch", "main"); err != nil {
		return CommitInfo{}, err
	}
	full := filepath.Join(r.Dir, filepath.FromSlash(path))
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		return CommitInfo{}, fmt.Errorf("mkdir for %s: %w", path, err)
	}
	existing, _ := os.ReadFile(full)
	if len(existing) > 0 && !bytes.HasSuffix(existing, []byte("\n")) {
		existing = append(existing, '\n')
	}
	content := append(existing, line...)
	if !bytes.HasSuffix(content, []byte("\n")) {
		content = append(content, '\n')
	}
	if err := os.WriteFile(full, content, 0o644); err != nil {
		return CommitInfo{}, fmt.Errorf("write %s: %w", path, err)
	}
	if _, err := r.git(ctx, "add", "--", path); err != nil {
		return CommitInfo{}, err
	}
	return r.commit(ctx, actor, subject, body, false)
}

// CreateBranchCommit opens a promotion branch from main, writes the files and
// commits on the branch, then returns to main (§3 rule 5).
func (r *Repo) CreateBranchCommit(ctx context.Context, actor Actor, branch string, files map[string][]byte, subject, body string) (CommitInfo, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, err := r.git(ctx, "switch", "-c", branch, "main"); err != nil {
		return CommitInfo{}, err
	}
	// Whatever happens, the worktree must come back to main.
	defer r.git(context.WithoutCancel(ctx), "switch", "main") //nolint:errcheck

	if err := r.writeWorktree(ctx, files); err != nil {
		return CommitInfo{}, err
	}
	return r.commit(ctx, actor, subject, body, false)
}

// MergeBranchCommit performs the approval merge (§3 rule 5): on main,
// `merge --no-ff --no-commit`, lay down the extra files (approved promotion
// marker + evidence pack) so they land INSIDE the merge commit, commit as
// actor, then delete the branch. Returns the merge commit.
func (r *Repo) MergeBranchCommit(ctx context.Context, actor Actor, branch string, files map[string][]byte, subject, body string) (CommitInfo, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, err := r.git(ctx, "switch", "main"); err != nil {
		return CommitInfo{}, err
	}
	if _, err := r.git(ctx, "merge", "--no-ff", "--no-commit", branch); err != nil {
		_, _ = r.git(context.WithoutCancel(ctx), "merge", "--abort")
		return CommitInfo{}, fmt.Errorf("merge %s: %w", branch, err)
	}
	if err := r.writeWorktree(ctx, files); err != nil {
		_, _ = r.git(context.WithoutCancel(ctx), "merge", "--abort")
		return CommitInfo{}, err
	}
	info, err := r.commit(ctx, actor, subject, body, false)
	if err != nil {
		_, _ = r.git(context.WithoutCancel(ctx), "merge", "--abort")
		return CommitInfo{}, err
	}
	if _, err := r.git(ctx, "branch", "-D", branch); err != nil {
		return info, fmt.Errorf("merged but failed to delete branch %s: %w", branch, err)
	}
	return info, nil
}

// DeleteBranch force-deletes a promotion branch (reject path).
func (r *Repo) DeleteBranch(ctx context.Context, branch string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, err := r.git(ctx, "switch", "main"); err != nil {
		return err
	}
	_, err := r.git(ctx, "branch", "-D", branch)
	return err
}

// BranchesUnder lists local branches under a literal prefix (e.g.
// "stoa/promote" returns every stoa/promote/... branch). for-each-ref's
// literal prefix matching is used on purpose: its glob patterns are
// WM_PATHNAME (`*` never crosses `/`), which silently misses the
// {tenant}/{slug}/{id} levels.
func (r *Repo) BranchesUnder(ctx context.Context, prefix string) ([]string, error) {
	out, err := r.git(ctx, "for-each-ref", "--format=%(refname:short)",
		"refs/heads/"+strings.TrimSuffix(prefix, "/"))
	if err != nil {
		return nil, err
	}
	var names []string
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line != "" {
			names = append(names, line)
		}
	}
	sort.Strings(names)
	return names, nil
}

// logFormat: record sep \x1e, field sep \x1f. %G? is "G" only for a verified
// signature (gpg.ssh.allowedSignersFile configured by the seed); anything
// else (N, B, U, E...) renders signed=false.
const logFormat = "--format=%x1e%H%x1f%h%x1f%an%x1f%ae%x1f%aI%x1f%G?%x1f%s%x1f%b"

// Log returns parsed commits for the given revision range (e.g. ["main"],
// ["main..branch"]) optionally limited to paths. limit<=0 means no limit.
func (r *Repo) Log(ctx context.Context, revs []string, paths []string, limit int) ([]AuditEntry, error) {
	args := []string{"log", logFormat}
	if limit > 0 {
		args = append(args, fmt.Sprintf("-n%d", limit))
	}
	args = append(args, revs...)
	if len(paths) > 0 {
		args = append(args, "--")
		args = append(args, paths...)
	}
	out, err := r.git(ctx, args...)
	if err != nil {
		return nil, err
	}
	return parseLog(out), nil
}

// parseLog decodes the \x1e/\x1f framed log output and extracts the §3
// trailers (Action/Resource/Actor/Roles/Evidence) from each body.
func parseLog(out string) []AuditEntry {
	var entries []AuditEntry
	for _, rec := range strings.Split(out, "\x1e") {
		rec = strings.TrimSpace(rec)
		if rec == "" {
			continue
		}
		f := strings.Split(rec, "\x1f")
		if len(f) < 7 {
			continue
		}
		e := AuditEntry{
			SHA:    f[0],
			SHA7:   f[1],
			Author: f[2],
			Email:  f[3],
			Date:   f[4],
			Signed: f[5] == "G",
			Roles:  []string{},
		}
		e.Message = f[6]
		if len(f) >= 8 {
			body := f[7]
			for _, line := range strings.Split(body, "\n") {
				line = strings.TrimSpace(line)
				switch {
				case strings.HasPrefix(line, "Action:"):
					e.Action = strings.TrimSpace(strings.TrimPrefix(line, "Action:"))
				case strings.HasPrefix(line, "Resource:"):
					e.Resource = strings.TrimSpace(strings.TrimPrefix(line, "Resource:"))
				case strings.HasPrefix(line, "Actor:"):
					e.Actor = strings.TrimSpace(strings.TrimPrefix(line, "Actor:"))
				case strings.HasPrefix(line, "Roles:"):
					csv := strings.TrimSpace(strings.TrimPrefix(line, "Roles:"))
					if csv != "" {
						e.Roles = strings.Split(csv, ",")
					}
				case strings.HasPrefix(line, "Evidence:"):
					ev := strings.TrimSpace(strings.TrimPrefix(line, "Evidence:"))
					if ev != "—" && ev != "-" {
						e.Evidence = ev
					}
				}
			}
		}
		entries = append(entries, e)
	}
	return entries
}

// DiffBranch returns the unified diff text and per-file numstat of
// main...branch (the promotion review payload).
func (r *Repo) DiffBranch(ctx context.Context, branch string) (string, []DiffFile, error) {
	diff, err := r.git(ctx, "diff", "main..."+branch)
	if err != nil {
		return "", nil, err
	}
	stat, err := r.git(ctx, "diff", "--numstat", "main..."+branch)
	if err != nil {
		return "", nil, err
	}
	files := []DiffFile{}
	for _, line := range strings.Split(strings.TrimSpace(stat), "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\t", 3)
		if len(parts) != 3 {
			continue
		}
		files = append(files, DiffFile{
			Path:      parts[2],
			Additions: atoiSafe(parts[0]),
			Deletions: atoiSafe(parts[1]),
		})
	}
	return diff, files, nil
}

// DiffFile is one entry of the promotion diff file list.
type DiffFile struct {
	Path      string `json:"path"`
	Additions int    `json:"additions"`
	Deletions int    `json:"deletions"`
}

// atoiSafe parses git numstat counters ("-" for binary -> 0).
func atoiSafe(s string) int {
	n := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0
		}
		n = n*10 + int(c-'0')
	}
	return n
}
