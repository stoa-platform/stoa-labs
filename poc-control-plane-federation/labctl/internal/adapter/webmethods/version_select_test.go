package webmethods

import "testing"

func TestApiVersionLess(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"1.0.0", "1.0.1", true},
		{"1.0.1", "1.0.0", false},
		{"1.0.2", "1.0.10", true},  // numeric, not lexical: 2 < 10
		{"1.0.10", "1.0.2", false}, // the regression this fix closes
		{"1.0.0", "1.0.0", false},  // equal
		{"1.0", "1.0.0", true},     // prefix-equal, shorter is less
		{"2.0.0", "1.9.9", false},
		{"1.9.9", "2.0.0", true},
	}
	for _, c := range cases {
		if got := apiVersionLess(c.a, c.b); got != c.want {
			t.Errorf("apiVersionLess(%q,%q) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
}

func TestLatestByName(t *testing.T) {
	apis := []wmAPI{
		{ID: "id-100", APIName: "accounts-read", APIVersion: "1.0.0"},
		{ID: "id-1010", APIName: "accounts-read", APIVersion: "1.0.10"}, // latest, out of list order
		{ID: "id-101", APIName: "accounts-read", APIVersion: "1.0.1"},
		{ID: "id-102", APIName: "accounts-read", APIVersion: "1.0.2"},
		{ID: "other", APIName: "payments", APIVersion: "9.9.9"},
	}
	got, ok := latestByName(apis, "accounts-read")
	if !ok {
		t.Fatal("expected a match")
	}
	if got.ID != "id-1010" || got.APIVersion != "1.0.10" {
		t.Errorf("latest = %s/%s, want id-1010/1.0.10 (numeric latest, not first-in-list)", got.ID, got.APIVersion)
	}
	if _, ok := latestByName(apis, "absent"); ok {
		t.Error("expected no match for absent name")
	}
}
