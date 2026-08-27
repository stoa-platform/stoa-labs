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
// from the YAML this repo's contracts use — it is NOT a general YAML parser:
// no anchors, no multi-line scalars, no quoting rules. TWO layouts are read,
// because two callers write them: the block style of apis/*.openapi.yaml
// (2-space mappings, "- " sequences, unquoted scalars) and the SINGLE-LINE FLOW
// style of scripts/test-archive-promotion.sh (`servers: [ { url: … } ]`,
// `paths: { /ping: { … } }`). Flow style was long unsupported, and the failure
// was SILENT and total: an unparsed document yields an empty apiDefinition, so
// the routing loses its backend and the allowlist exposes NOTHING — every
// data-plane call 404s while the admin surface looks perfectly healthy. A flow
// collection spanning several lines is still out of scope.
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
		// "key:" alone opens a block collection; "key: <rest>" on one line is a
		// flow collection (or a scalar, which yields nothing here).
		key, rest, ok := strings.Cut(lines[i].text, ":")
		if !ok {
			continue
		}
		rest = strings.TrimSpace(rest)
		switch key {
		case "servers":
			url := firstSeqURLAfter(lines, i)
			if rest != "" {
				url = flowSeqFirstField(rest, "url")
			}
			if url != "" {
				out["servers"] = []any{map[string]any{"url": url}}
			}
		case "paths":
			if rest != "" {
				out["paths"] = flowMapKeys(rest)
				continue
			}
			out["paths"] = childKeysAfter(lines, i)
		}
	}
	return out
}

// flowBody strips the delimiters of a flow collection, reporting whether s is
// one at all.
func flowBody(s string, open, close byte) (string, bool) {
	s = strings.TrimSpace(s)
	if len(s) < 2 || s[0] != open || s[len(s)-1] != close {
		return "", false
	}
	return s[1 : len(s)-1], true
}

// flowSplit cuts a flow collection's body on its TOP-LEVEL commas — nested
// collections and quoted scalars keep theirs (`{ /ping: { get: {…} } }` is ONE
// item, and so is `{ '200': { description: ok } }`).
func flowSplit(s string) []string {
	var out []string
	depth, start := 0, 0
	var quote rune
	for i, r := range s {
		switch {
		case quote != 0:
			if r == quote {
				quote = 0
			}
		case r == '\'' || r == '"':
			quote = r
		case r == '{' || r == '[':
			depth++
		case r == '}' || r == ']':
			depth--
		case r == ',' && depth == 0:
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	return append(out, s[start:])
}

// flowMapKeys collects the top-level keys of a flow mapping — the flow twin of
// childKeysAfter (values ignored, resourceInContract never reads them).
func flowMapKeys(s string) map[string]any {
	out := map[string]any{}
	body, ok := flowBody(s, '{', '}')
	if !ok {
		return out
	}
	for _, item := range flowSplit(body) {
		k, _, ok := strings.Cut(item, ":")
		if !ok {
			continue
		}
		if k = strings.Trim(strings.TrimSpace(k), `"'`); k != "" {
			out[k] = map[string]any{}
		}
	}
	return out
}

// flowSeqFirstField returns a scalar field of the FIRST item of a flow sequence
// — the flow twin of firstSeqURLAfter, and it stops at item 0 for the same
// reason (only servers[0] feeds the routing).
func flowSeqFirstField(s, field string) string {
	body, ok := flowBody(s, '[', ']')
	if !ok {
		return ""
	}
	items := flowSplit(body)
	if len(items) == 0 {
		return ""
	}
	inner, ok := flowBody(items[0], '{', '}')
	if !ok {
		return ""
	}
	for _, kv := range flowSplit(inner) {
		if v, ok := yamlScalarField(strings.TrimSpace(kv), field); ok {
			return v
		}
	}
	return ""
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
