package cmd

import "testing"

// Regression for backstage-spec-text-relative-path: the $text reference written
// into catalog-info.yaml must be relative to the manifest dir (the entity
// location), not the already-joined contract path. For `-f deploy/targets.yaml`
// + `contract: apis/x.yaml`, targets.Load joins to `deploy/apis/x.yaml`; the
// catalog lives under `deploy/`, so $text must be `apis/x.yaml`.
func TestBackstageSpecPath(t *testing.T) {
	cases := []struct {
		name        string
		manifestDir string
		specPath    string
		want        string
	}{
		{
			name:        "non-trivial manifest dir is stripped",
			manifestDir: "deploy",
			specPath:    "deploy/apis/x.yaml",
			want:        "apis/x.yaml",
		},
		{
			name:        "cwd manifest dir leaves path as-is",
			manifestDir: ".",
			specPath:    "apis/x.yaml",
			want:        "apis/x.yaml",
		},
		{
			name:        "nested manifest dir",
			manifestDir: "a/b",
			specPath:    "a/b/c/spec.yaml",
			want:        "c/spec.yaml",
		},
		{
			name:        "same file in manifest dir",
			manifestDir: "deploy",
			specPath:    "deploy/spec.yaml",
			want:        "spec.yaml",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := backstageSpecPath(tc.manifestDir, tc.specPath); got != tc.want {
				t.Errorf("backstageSpecPath(%q, %q) = %q, want %q",
					tc.manifestDir, tc.specPath, got, tc.want)
			}
		})
	}
}

func TestBackendOrPlaceholder(t *testing.T) {
	if got := backendOrPlaceholder(""); got != "(none)" {
		t.Errorf("empty backend = %q, want (none)", got)
	}
	if got := backendOrPlaceholder("http://mock:8080"); got != "http://mock:8080" {
		t.Errorf("backend passthrough = %q", got)
	}
}
