package cmd

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/authz"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/governance"
)

// TestApplyToken locks the secret-handling contract: the token can be supplied
// via a 0600 FILE (so it never has to sit in the environment or a CI log), with
// LABCTL_TOKEN taking precedence when both are set.
func TestApplyToken(t *testing.T) {
	t.Setenv("LABCTL_TOKEN", "")
	t.Setenv("LABCTL_TOKEN_FILE", "")
	if got := applyToken(); got != "" {
		t.Errorf("no env/file: got %q, want empty", got)
	}
	f := filepath.Join(t.TempDir(), "tok")
	if err := os.WriteFile(f, []byte("  file-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LABCTL_TOKEN_FILE", f)
	if got := applyToken(); got != "file-token" {
		t.Errorf("file fallback: got %q, want file-token (trimmed)", got)
	}
	t.Setenv("LABCTL_TOKEN", "env-token")
	if got := applyToken(); got != "env-token" {
		t.Errorf("env must win over file: got %q, want env-token", got)
	}
}

// scopeFakeVerifier maps a raw token to the Identity it validates to (an unknown
// token errors — a forged/expired token without a live JWKS).
type scopeFakeVerifier struct{ m map[string]*governance.Identity }

func (f scopeFakeVerifier) Verify(_ context.Context, tok string) (*governance.Identity, error) {
	if id, ok := f.m[tok]; ok {
		return id, nil
	}
	return nil, errors.New("invalid token")
}

func TestInScope(t *testing.T) {
	if !inScope("", "anything") {
		t.Error("empty scope must admit every tenant")
	}
	if !inScope("banking-demo", "banking-demo") {
		t.Error("same tenant must be in scope")
	}
	if inScope("banking-demo", "payments-team") {
		t.Error("different tenant must be out of scope")
	}
}

func TestResolveScope(t *testing.T) {
	bank := principal{Actor: "ci-banking", Tenant: "banking-demo", OK: true}
	cases := []struct {
		name    string
		p       principal
		flag    string
		want    string
		wantErr bool
	}{
		{"unscoped", principal{}, "", "", false},
		{"flag only", principal{}, "banking-demo", "banking-demo", false},
		{"token binds scope", bank, "", "banking-demo", false},
		{"token + matching flag", bank, "banking-demo", "banking-demo", false},
		{"token + mismatching flag denied", bank, "payments-team", "", true},
	}
	for _, c := range cases {
		got, err := resolveScope(c.p, c.flag)
		if c.wantErr {
			if err == nil {
				t.Errorf("%s: expected cross-tenant error", c.name)
			}
			continue
		}
		if err != nil || got != c.want {
			t.Errorf("%s: resolveScope = (%q,%v), want (%q,nil)", c.name, got, err, c.want)
		}
	}
}

func TestResolvePrincipal(t *testing.T) {
	v := scopeFakeVerifier{m: map[string]*governance.Identity{
		"cp-banking": {Username: "ci-banking", Roles: []string{authz.RoleCPApplier}, Tenant: "banking-demo"},
		"no-role":    {Username: "ci-x", Roles: []string{"viewer"}, Tenant: "banking-demo"},
		"no-tenant":  {Username: "ci-y", Roles: []string{authz.RoleCPApplier}},
	}}
	ctx := context.Background()

	// absent token → unauthenticated operator path, no error
	if p, err := resolvePrincipal(ctx, v, ""); err != nil || p.OK {
		t.Errorf("empty token = (%+v,%v), want ({OK:false},nil)", p, err)
	}
	// valid cp-applier token → bound principal
	if p, err := resolvePrincipal(ctx, v, "cp-banking"); err != nil || !p.OK || p.Tenant != "banking-demo" || p.Actor != "ci-banking" {
		t.Errorf("cp-banking = (%+v,%v), want bound banking-demo principal", p, err)
	}
	// token without the role → hard error
	if _, err := resolvePrincipal(ctx, v, "no-role"); err == nil || !strings.Contains(err.Error(), authz.RoleCPApplier) {
		t.Errorf("no-role err = %v, want cp-applier role error", err)
	}
	// token without a tenant → hard error
	if _, err := resolvePrincipal(ctx, v, "no-tenant"); err == nil || !strings.Contains(err.Error(), "no tenant") {
		t.Errorf("no-tenant err = %v, want no-tenant error", err)
	}
	// forged/unknown token → hard error
	if _, err := resolvePrincipal(ctx, v, "forged"); err == nil {
		t.Errorf("forged token must error")
	}
}
