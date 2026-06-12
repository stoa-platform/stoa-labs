package authz

import (
	"net/http/httptest"
	"testing"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/governance"
)

func TestBearerToken(t *testing.T) {
	cases := []struct {
		hdr      string
		wantTok  string
		wantOk   bool
	}{
		{"Bearer abc.def.ghi", "abc.def.ghi", true},
		{"bearer abc", "abc", true}, // scheme is case-insensitive
		{"  Bearer   spaced  ", "spaced", true},
		{"", "", false},
		{"Basic dXNlcjpwYXNz", "", false},
		{"Bearer ", "", false},
		{"Bearer", "", false},
	}
	for _, c := range cases {
		r := httptest.NewRequest("POST", "/applications", nil)
		if c.hdr != "" {
			r.Header.Set("Authorization", c.hdr)
		}
		tok, ok := BearerToken(r)
		if ok != c.wantOk || tok != c.wantTok {
			t.Errorf("BearerToken(%q) = (%q,%v), want (%q,%v)", c.hdr, tok, ok, c.wantTok, c.wantOk)
		}
	}
}

func TestHasRole(t *testing.T) {
	id := &governance.Identity{Roles: []string{"viewer", RolePartnerOnboarder}}
	if !HasRole(id, RolePartnerOnboarder) {
		t.Error("expected partner-onboarder present")
	}
	if HasRole(id, RoleCPApplier) {
		t.Error("cp-applier must be absent")
	}
	if HasRole(&governance.Identity{}, RolePartnerOnboarder) {
		t.Error("empty roles must not match")
	}
}

func TestTenantOf(t *testing.T) {
	cases := []struct {
		name   string
		id     governance.Identity
		want   string
		wantOk bool
	}{
		{"flat claim wins", governance.Identity{Tenant: "banking-demo", Groups: []string{"/tenants/payments-team"}}, "banking-demo", true},
		{"group fallback", governance.Identity{Groups: []string{"/tenants/payments-team"}}, "payments-team", true},
		{"group trailing slash", governance.Identity{Groups: []string{"/tenants/banking-demo/"}}, "banking-demo", true},
		{"no tenant", governance.Identity{Roles: []string{RolePartnerOnboarder}}, "", false},
		{"ambiguous groups", governance.Identity{Groups: []string{"/tenants/a", "/tenants/b"}}, "", false},
		{"nested group ignored", governance.Identity{Groups: []string{"/tenants/a/sub"}}, "", false},
		{"non-tenant group ignored", governance.Identity{Groups: []string{"/other/x"}}, "", false},
		{"duplicate same tenant ok", governance.Identity{Groups: []string{"/tenants/a", "/tenants/a"}}, "a", true},
	}
	for _, c := range cases {
		got, ok := TenantOf(&c.id)
		if got != c.want || ok != c.wantOk {
			t.Errorf("%s: TenantOf = (%q,%v), want (%q,%v)", c.name, got, ok, c.want, c.wantOk)
		}
	}
}

func TestTenantOrUnknown(t *testing.T) {
	if got := TenantOrUnknown(&governance.Identity{Tenant: "banking-demo"}); got != "banking-demo" {
		t.Errorf("got %q", got)
	}
	if got := TenantOrUnknown(&governance.Identity{}); got != "unknown" {
		t.Errorf("got %q, want unknown", got)
	}
}

func TestActorName(t *testing.T) {
	if got := ActorName(&governance.Identity{Username: "alice", Subject: "sub-1"}); got != "alice" {
		t.Errorf("got %q, want alice", got)
	}
	if got := ActorName(&governance.Identity{Username: "unknown", Subject: "sub-2"}); got != "sub-2" {
		t.Errorf("got %q, want sub-2 (fallback when username is the unknown sentinel)", got)
	}
	if got := ActorName(&governance.Identity{Subject: "sub-3"}); got != "sub-3" {
		t.Errorf("got %q, want sub-3", got)
	}
}

func TestClientIP(t *testing.T) {
	r := httptest.NewRequest("POST", "/applications", nil)
	r.RemoteAddr = "10.0.0.5:54321"
	if got := ClientIP(r); got != "10.0.0.5" {
		t.Errorf("remote addr: got %q, want 10.0.0.5", got)
	}
	r.Header.Set("X-Forwarded-For", "203.0.113.10, 10.0.0.1")
	if got := ClientIP(r); got != "203.0.113.10" {
		t.Errorf("xff first hop: got %q, want 203.0.113.10", got)
	}
}
