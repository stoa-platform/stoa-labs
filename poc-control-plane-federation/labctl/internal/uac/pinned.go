package uac

import (
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"

	"sigs.k8s.io/yaml"
)

// ResolvePinned replaces a's contract with the version PINNED by
// deploy.{env}.Commit — the api.yaml main SHA the governance gate approved —
// read straight from the Git object store of the checkout (git show). An empty
// or absent pin is a no-op (publish writes no pin: the entry environment
// follows HEAD by design). Any git failure is an error: a pinned environment
// must NEVER silently fall back to HEAD (fail-closed).
func ResolvePinned(root string, a *API, env string) error {
	d, ok := a.Deploys[env]
	if !ok || d.Commit == "" {
		return nil
	}
	rel, err := filepath.Rel(root, a.Path)
	if err != nil {
		return fmt.Errorf("pinned contract %s/%s: relative path: %w", a.Tenant, a.Slug, err)
	}
	rel = filepath.ToSlash(rel)

	out, err := exec.Command("git", "-C", root, "show", d.Commit+":"+rel).Output()
	if err != nil {
		detail := err.Error()
		var ee *exec.ExitError
		if errors.As(err, &ee) && len(ee.Stderr) > 0 {
			detail = strings.TrimSpace(string(ee.Stderr))
		}
		return fmt.Errorf("pinned contract %s/%s: git show %s:%s: %s", a.Tenant, a.Slug, d.Commit, rel, detail)
	}
	var c Contract
	if err := yaml.Unmarshal(out, &c); err != nil {
		return fmt.Errorf("pinned contract %s/%s@%s: parse: %w", a.Tenant, a.Slug, d.Commit, err)
	}
	a.Contract = c
	return nil
}
