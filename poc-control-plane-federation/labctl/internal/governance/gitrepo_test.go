package governance

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// gitT runs a git command in dir, failing the test on error. Global/system
// config is masked so a developer's commit.gpgsign=true cannot leak in.
func gitT(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(),
		"GIT_CONFIG_GLOBAL=/dev/null",
		"GIT_CONFIG_SYSTEM=/dev/null",
		"GIT_COMMITTER_NAME=seed",
		"GIT_COMMITTER_EMAIL=seed@test.local",
		"GIT_AUTHOR_NAME=seed",
		"GIT_AUTHOR_EMAIL=seed@test.local",
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return string(out)
}

// newTestRepo creates a throwaway governance repo: git init on main, identity
// configured, SIGNATURE OFF (the seed enables it in the real repo), one seed
// commit so refs exist.
func newTestRepo(t *testing.T) *Repo {
	t.Helper()
	dir := t.TempDir()
	gitT(t, dir, "init", "-b", "main")
	gitT(t, dir, "config", "user.name", "seed")
	gitT(t, dir, "config", "user.email", "seed@test.local")
	gitT(t, dir, "config", "commit.gpgsign", "false")
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("seed\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitT(t, dir, "add", "README.md")
	gitT(t, dir, "commit", "-m", "seed: init")

	repo, err := OpenRepo(dir)
	if err != nil {
		t.Fatalf("OpenRepo: %v", err)
	}
	return repo
}

var alice = Actor{Username: "alice", Name: "Alice Martin", Email: "alice@bank.example", Roles: []string{"tenant-admin"}}

func TestCommitFilesAuthorTrailersAndReread(t *testing.T) {
	repo := newTestRepo(t)
	ctx := context.Background()

	path := "tenants/banking-demo/apis/payments/api.yaml"
	content := []byte("name: payments\nversion: 1.0.0\n")
	body := TrailerBlock("draft", "banking-demo/payments", alice, "")
	commit, err := repo.CommitFiles(ctx, alice, map[string][]byte{path: content},
		"gov(banking-demo): draft payments", body)
	if err != nil {
		t.Fatalf("CommitFiles: %v", err)
	}
	if commit.SHA == "" || commit.SHA7 == "" {
		t.Fatalf("commit info incomplete: %+v", commit)
	}
	if commit.Signed {
		t.Fatalf("test repo has signing off, commit must report signed=false")
	}

	// Invariant 1: the response content is what Git holds.
	got, err := repo.ReadFile(ctx, "main", path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if string(got) != string(content) {
		t.Fatalf("re-read mismatch: %q", got)
	}

	// Invariant 2: author = actor, committer = governance-bot.
	out := gitT(t, repo.Dir, "log", "-1", "--format=%an|%ae|%cn|%ce")
	want := "Alice Martin|alice@bank.example|governance-bot|bot@stoa.local"
	if strings.TrimSpace(out) != want {
		t.Fatalf("identity = %q, want %q", strings.TrimSpace(out), want)
	}

	// Invariant 3: subject + trailers parse back through the audit log.
	entries, err := repo.Log(ctx, []string{"main"}, nil, 1)
	if err != nil {
		t.Fatalf("Log: %v", err)
	}
	e := entries[0]
	if e.Message != "gov(banking-demo): draft payments" {
		t.Fatalf("subject = %q", e.Message)
	}
	if e.Action != "draft" || e.Resource != "banking-demo/payments" || e.Actor != "alice" {
		t.Fatalf("trailers not parsed: %+v", e)
	}
	if len(e.Roles) != 1 || e.Roles[0] != "tenant-admin" {
		t.Fatalf("roles = %v", e.Roles)
	}
	if e.Evidence != "" {
		t.Fatalf("evidence should be empty for '—', got %q", e.Evidence)
	}
	if e.Signed {
		t.Fatalf("unsigned commit must parse as signed=false")
	}
}

func TestPromotionBranchMergeNoFF(t *testing.T) {
	repo := newTestRepo(t)
	ctx := context.Background()
	bob := Actor{Username: "bob", Name: "Bob Approver", Email: "bob@bank.example", Roles: []string{"devops"}}

	branch := "stoa/promote/banking-demo/payments/pr-0001"
	promoPath := "promotions/banking-demo/pr-0001.yaml"
	deployPath := "tenants/banking-demo/apis/payments/deploy.production.yaml"

	if _, err := repo.CreateBranchCommit(ctx, alice, branch, map[string][]byte{
		promoPath:  []byte("id: pr-0001\nstatus: pending\n"),
		deployPath: []byte("version: 1.0.0\nenabled: true\n"),
	}, "gov(banking-demo): promote-request payments",
		TrailerBlock("promote-request", "banking-demo/pr-0001", alice, "")); err != nil {
		t.Fatalf("CreateBranchCommit: %v", err)
	}

	// Worktree must be back on main; the branch holds the files, main not yet.
	if cur := strings.TrimSpace(gitT(t, repo.Dir, "branch", "--show-current")); cur != "main" {
		t.Fatalf("worktree left on %q, want main", cur)
	}
	if repo.Exists(ctx, "main", promoPath) {
		t.Fatalf("pending marker must not be on main before merge")
	}
	if !repo.Exists(ctx, branch, promoPath) {
		t.Fatalf("pending marker missing on branch")
	}

	// The review diff is a real git diff main...branch.
	diff, files, err := repo.DiffBranch(ctx, branch)
	if err != nil {
		t.Fatalf("DiffBranch: %v", err)
	}
	if !strings.Contains(diff, "deploy.production.yaml") || len(files) != 2 {
		t.Fatalf("diff incomplete: files=%v", files)
	}

	// Approve = merge --no-ff with the approved marker + evidence INSIDE the
	// merge commit.
	merge, err := repo.MergeBranchCommit(ctx, bob, branch, map[string][]byte{
		promoPath: []byte("id: pr-0001\nstatus: approved\napproved_by: bob\n"),
		"evidence/banking-demo/payments/promote-approve-001.json": []byte("{}\n"),
	}, "gov(banking-demo): promote-approve payments",
		TrailerBlock("promote-approve", "banking-demo/pr-0001", bob, "evidence/banking-demo/payments/promote-approve-001.json"))
	if err != nil {
		t.Fatalf("MergeBranchCommit: %v", err)
	}

	// Real merge commit: two parents.
	parents := strings.Fields(strings.TrimSpace(gitT(t, repo.Dir, "log", "-1", "--format=%P", merge.SHA)))
	if len(parents) != 2 {
		t.Fatalf("merge commit has %d parents, want 2 (--no-ff)", len(parents))
	}
	// Branch is gone; approved marker and evidence are on main.
	if br, err := repo.BranchesUnder(ctx, "stoa/promote"); err != nil || len(br) != 0 {
		t.Fatalf("promotion branch should be deleted, got %v (%v)", br, err)
	}
	marker, err := repo.ReadFile(ctx, "main", promoPath)
	if err != nil || !strings.Contains(string(marker), "approved") {
		t.Fatalf("approved marker not on main: %q %v", marker, err)
	}
	if !repo.Exists(ctx, "main", "evidence/banking-demo/payments/promote-approve-001.json") {
		t.Fatalf("evidence must land in the merge commit")
	}
}

func TestRejectDeletesBranchAndKeepsMarker(t *testing.T) {
	repo := newTestRepo(t)
	ctx := context.Background()

	branch := "stoa/promote/banking-demo/payments/pr-0002"
	if _, err := repo.CreateBranchCommit(ctx, alice, branch,
		map[string][]byte{"promotions/banking-demo/pr-0002.yaml": []byte("id: pr-0002\nstatus: pending\n")},
		"gov(banking-demo): promote-request payments", ""); err != nil {
		t.Fatalf("CreateBranchCommit: %v", err)
	}
	if _, err := repo.CommitFiles(ctx, alice,
		map[string][]byte{"promotions/banking-demo/pr-0002.yaml": []byte("id: pr-0002\nstatus: rejected\nreason: trop risqué\n")},
		"gov(banking-demo): promote-reject payments",
		TrailerBlock("promote-reject", "banking-demo/pr-0002", alice, "")); err != nil {
		t.Fatalf("reject CommitFiles: %v", err)
	}
	if err := repo.DeleteBranch(ctx, branch); err != nil {
		t.Fatalf("DeleteBranch: %v", err)
	}
	if br, _ := repo.BranchesUnder(ctx, "stoa/promote"); len(br) != 0 {
		t.Fatalf("branch should be force-deleted, got %v", br)
	}
	marker, err := repo.ReadFile(ctx, "main", "promotions/banking-demo/pr-0002.yaml")
	if err != nil || !strings.Contains(string(marker), "rejected") {
		t.Fatalf("rejected marker missing on main: %q %v", marker, err)
	}
}

func TestAppendFileAndCommitDenials(t *testing.T) {
	repo := newTestRepo(t)
	ctx := context.Background()
	bot := Actor{Username: "viewer1", Name: "governance-bot", Email: "bot@stoa.local", Roles: []string{"viewer"}}

	for _, line := range []string{`{"user":"viewer1","code":"FORBIDDEN"}`, `{"user":"alice","code":"SELF_APPROVAL_BLOCKED"}`} {
		if _, err := repo.AppendFileAndCommit(ctx, bot, DenialsPath, []byte(line),
			"deny(banking-demo): test by "+bot.Username,
			TrailerBlock("deny", "banking-demo/test", bot, DenialsPath)); err != nil {
			t.Fatalf("AppendFileAndCommit: %v", err)
		}
	}
	got, err := repo.ReadFile(ctx, "main", DenialsPath)
	if err != nil {
		t.Fatalf("ReadFile denials: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(string(got)), "\n")
	if len(lines) != 2 || !strings.Contains(lines[1], "SELF_APPROVAL_BLOCKED") {
		t.Fatalf("denials.jsonl = %q", got)
	}
	entries, err := repo.Log(ctx, []string{"main"}, []string{DenialsPath}, 0)
	if err != nil || len(entries) != 2 {
		t.Fatalf("expected 2 deny commits, got %d (%v)", len(entries), err)
	}
	if entries[0].Action != "deny" {
		t.Fatalf("deny trailer not parsed: %+v", entries[0])
	}
}

func TestListDirAndExistsOnMissingPaths(t *testing.T) {
	repo := newTestRepo(t)
	ctx := context.Background()

	if repo.Exists(ctx, "main", "tenants/nope/tenant.yaml") {
		t.Fatal("Exists must be false for a missing path")
	}
	names, err := repo.ListDir(ctx, "main", "tenants")
	if err != nil {
		t.Fatalf("ListDir on missing dir: %v", err)
	}
	if len(names) != 0 {
		t.Fatalf("expected empty listing, got %v", names)
	}
}
