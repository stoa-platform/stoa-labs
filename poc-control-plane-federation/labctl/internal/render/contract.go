package render

import (
	"fmt"
	"os"

	"sigs.k8s.io/yaml"
)

// ContractSubset is the security-relevant, on-disk subset of a UAC contract
// (api.yaml): exactly the fields Derive consumes plus the name/tenant used to
// cross-check the contract against the federation manifest and the central
// classification registry (goal A5). Shared by the `labctl render` command and
// the apply-side enforcement gate so both read the SAME fields the same way.
type ContractSubset struct {
	Name           string   `json:"name"`
	TenantID       string   `json:"tenant_id"`
	Classification string   `json:"classification"`
	Exposure       string   `json:"exposure"`
	Tags           []string `json:"tags"`
}

// Input projects the subset onto Derive's input.
func (c ContractSubset) Input() Input {
	return Input{Classification: c.Classification, Exposure: c.Exposure, Tags: c.Tags}
}

// LoadContract reads and decodes the subset from an api.yaml path. Read or
// parse failures are hard errors (a present-but-broken contract must never
// silently disable the gate that keys on it).
func LoadContract(path string) (ContractSubset, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return ContractSubset{}, fmt.Errorf("read %s: %w", path, err)
	}
	var c ContractSubset
	if err := yaml.Unmarshal(raw, &c); err != nil {
		return ContractSubset{}, fmt.Errorf("parse %s: %w", path, err)
	}
	return c, nil
}
