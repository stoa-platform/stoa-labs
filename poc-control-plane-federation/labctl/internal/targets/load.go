package targets

import (
	"fmt"
	"os"
	"path/filepath"

	"sigs.k8s.io/yaml"
)

// Load reads and validates a targets.yaml. The contract path is resolved
// relative to the manifest file's directory so `labctl apply -f x/targets.yaml`
// works from anywhere.
func Load(path string) (*File, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read targets %s: %w", path, err)
	}
	var f File
	if err := yaml.Unmarshal(raw, &f); err != nil {
		return nil, fmt.Errorf("parse targets %s: %w", path, err)
	}
	if f.Contract == "" {
		return nil, fmt.Errorf("targets %s: 'contract' is required", path)
	}
	if len(f.Targets) == 0 {
		return nil, fmt.Errorf("targets %s: at least one target is required", path)
	}
	dir := filepath.Dir(path)
	if !filepath.IsAbs(f.Contract) {
		f.Contract = filepath.Join(dir, f.Contract)
	}
	seen := map[string]bool{}
	for i, t := range f.Targets {
		if t.Name == "" || t.Type == "" {
			return nil, fmt.Errorf("targets %s: target #%d needs name and type", path, i)
		}
		if t.AdminURL == "" {
			return nil, fmt.Errorf("targets %s: target %q needs adminUrl", path, t.Name)
		}
		if seen[t.Name] {
			return nil, fmt.Errorf("targets %s: duplicate target name %q", path, t.Name)
		}
		seen[t.Name] = true
	}
	return &f, nil
}
