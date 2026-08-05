package main

// contract.go decodes the OpenAPI document carried by POST /apis when it
// arrives as the multipart "file" part (createAPI, admin.go) — the shape
// apim_publish_api actually sends (mesuré 2026-08-05, ansible/roles/
// apim_publish_api/tasks/main.yml). The JSON path already round-trips the
// full document (json.Unmarshal into map[string]any); the YAML path does
// NOT: this repo's contracts (apis/*.openapi.yaml) are YAML, and pulling in
// a YAML dependency (e.g. gopkg.in/yaml.v3) is unnecessary — the mock's
// data-plane (dataplane.go) reads exactly TWO things off apiDefinition:
// servers[0].url (defaultEndpointURI, admin.go) and the top-level keys of
// `paths` (resourceInContract, dataplane.go — VALUES are never read, only
// keys). contractFromYAML is scoped to extracting exactly those two things
// from the block-style YAML this repo's contracts use (2-space mappings, "- "
// sequences, unquoted scalars) — it is NOT a general YAML parser: no
// anchors, no flow style ({}/[]), no multi-line scalars, no quoting rules.
// Stdlib only (encoding/json + strings), so the mock keeps building
// air-gapped.

import (
	"encoding/json"
	"strings"
)

// parseContractDoc decodes the multipart "file" part into the same
// map[string]any apiDefinition shape the JSON import path already carries.
// JSON is tried first — general and exact, and the product accepts JSON
// contracts too (main.yml's mime_type:"application/x-yaml" is a fixed label,
// not a claim about the actual bytes). A document that is not valid JSON
// falls back to the scoped YAML extraction below. A document neither parser
// can make sense of still imports (matching the product's own leniency
// elsewhere) with an empty definition — the routing endpoint defaults to
// "/${sys:resource_path}" and the allowlist exposes nothing, rather than
// failing the whole import over a document the mock could not read.
func parseContractDoc(raw []byte) map[string]any {
	var def map[string]any
	if err := json.Unmarshal(raw, &def); err == nil && def != nil {
		return def
	}
	return contractFromYAML(raw)
}

// yline is one non-blank, non-comment YAML line, with its leading-space
// indent already measured.
type yline struct {
	indent int
	text   string
}

func yamlLines(data []byte) []yline {
	var out []yline
	for _, raw := range strings.Split(string(data), "\n") {
		line := strings.TrimRight(raw, "\r")
		trimmed := strings.TrimLeft(line, " ")
		if trimmed == "" || strings.HasPrefix(trimmed, "#") || trimmed == "---" {
			continue
		}
		out = append(out, yline{indent: len(line) - len(trimmed), text: trimmed})
	}
	return out
}

// contractFromYAML extracts {"servers":[{"url":...}], "paths":{...}} from a
// block-style OpenAPI YAML document — see file doc comment for scope.
func contractFromYAML(data []byte) map[string]any {
	lines := yamlLines(data)
	out := map[string]any{}
	for i := 0; i < len(lines); i++ {
		switch lines[i].text {
		case "servers:":
			if url := firstSeqURLAfter(lines, i); url != "" {
				out["servers"] = []any{map[string]any{"url": url}}
			}
		case "paths:":
			out["paths"] = childKeysAfter(lines, i)
		}
	}
	return out
}

// firstSeqURLAfter looks at the sequence following a "servers:" header at
// lines[header].indent, and returns the "url" scalar of its FIRST item
// ("- url: <value>", or "url:" on a line nested under a bare "-").
func firstSeqURLAfter(lines []yline, header int) string {
	headerIndent := lines[header].indent
	for i := header + 1; i < len(lines) && lines[i].indent > headerIndent; i++ {
		if !strings.HasPrefix(lines[i].text, "- ") {
			continue
		}
		item := strings.TrimPrefix(lines[i].text, "- ")
		if v, ok := yamlScalarField(item, "url"); ok {
			return v
		}
		// "- " starts a nested mapping (url: on a following, deeper-indented
		// line) — scan until the next sequence item or dedent.
		itemIndent := lines[i].indent
		for j := i + 1; j < len(lines) && lines[j].indent > itemIndent; j++ {
			if v, ok := yamlScalarField(lines[j].text, "url"); ok {
				return v
			}
		}
		return "" // first item found, no "url" in it — stop (only item 0 matters)
	}
	return ""
}

// childKeysAfter collects the mapping keys immediately nested under a
// header line (e.g. "paths:") — one level of indent deeper than the header,
// values ignored (resourceInContract never reads them). Returns a non-nil,
// possibly-empty map.
func childKeysAfter(lines []yline, header int) map[string]any {
	out := map[string]any{}
	headerIndent := lines[header].indent
	childIndent := -1
	for i := header + 1; i < len(lines) && lines[i].indent > headerIndent; i++ {
		if childIndent == -1 {
			childIndent = lines[i].indent
		}
		if lines[i].indent != childIndent {
			continue // deeper — a child's own nested body, not a sibling key
		}
		key := strings.TrimSuffix(lines[i].text, ":")
		if idx := strings.Index(lines[i].text, ": "); idx >= 0 {
			key = lines[i].text[:idx]
		}
		key = strings.Trim(key, `"'`)
		if key != "" {
			out[key] = map[string]any{} // value unused by resourceInContract
		}
	}
	return out
}

// yamlScalarField reports whether text is "field: value" (any value) and
// returns the trimmed, unquoted value.
func yamlScalarField(text, field string) (string, bool) {
	prefix := field + ":"
	if !strings.HasPrefix(text, prefix) {
		return "", false
	}
	v := strings.TrimSpace(strings.TrimPrefix(text, prefix))
	v = strings.Trim(v, `"'`)
	return v, v != ""
}
