package governance

import (
	"fmt"
	"regexp"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/render"
)

// UAC validation (contract §5). The BFF is the authority: it re-validates
// every contract before commit, in stdlib Go — not a full JSON Schema engine,
// but the load-bearing subset of uac_contract_v1_schema.json: required
// fields, enums, the name/version patterns, plus the three semantic rules:
//   - destructive endpoint  => requires_human_approval (DESTRUCTIVE_REQUIRES_APPROVAL)
//   - published contract    => at least one endpoint   (PUBLISHED_REQUIRES_ENDPOINT)
//   - classification+exposure+tags => a derivable security posture, fail-closed
//     via render.Derive (INTEGRITY_INCONSISTENT) — ADR-076 Phase 3
//
// The UI does the rich validation with ajv on the same schema (GET /schema/uac).

// ValidationError is one entry of the {valid, errors[]} response.
type ValidationError struct {
	Path    string `json:"path"`
	Message string `json:"message"`
	Code    string `json:"code,omitempty"`
}

var (
	namePattern    = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*[a-z0-9]$`)
	versionPattern = regexp.MustCompile(`^\d+\.\d+\.\d+$`)
)

var (
	classificationEnum = map[string]bool{"VH": true, "H": true, "M": true}
	exposureEnum       = map[string]bool{"internal": true, "external": true}
	statusEnum         = map[string]bool{"draft": true, "published": true, "deprecated": true}
	methodEnum         = map[string]bool{"GET": true, "POST": true, "PUT": true, "PATCH": true, "DELETE": true, "HEAD": true, "OPTIONS": true}
	sideEffectsEnum    = map[string]bool{"none": true, "read": true, "write": true, "destructive": true}
)

// ValidateUAC checks contract (a YAML/JSON-decoded object). published=true
// adds the publication gate (>=1 endpoint). It returns the full error list so
// the editor can render everything at once.
func ValidateUAC(contract map[string]any, published bool) []ValidationError {
	var errs []ValidationError
	add := func(path, code, format string, a ...any) {
		errs = append(errs, ValidationError{Path: path, Code: code, Message: fmt.Sprintf(format, a...)})
	}

	// --- required top-level fields ---
	name, _ := contract["name"].(string)
	if name == "" {
		add("name", "REQUIRED", "le champ 'name' est requis")
	} else {
		if len(name) > 255 {
			add("name", "MAX_LENGTH", "'name' dépasse 255 caractères")
		}
		if !namePattern.MatchString(name) {
			add("name", "PATTERN", "'name' doit être en kebab-case ([a-z0-9][a-z0-9-]*[a-z0-9]) : %q invalide", name)
		}
	}

	version, _ := contract["version"].(string)
	if version == "" {
		add("version", "REQUIRED", "le champ 'version' est requis")
	} else if !versionPattern.MatchString(version) {
		add("version", "PATTERN", "'version' doit être un semver X.Y.Z : %q invalide", version)
	}

	tenantID, _ := contract["tenant_id"].(string)
	if tenantID == "" {
		add("tenant_id", "REQUIRED", "le champ 'tenant_id' est requis")
	}

	classification, _ := contract["classification"].(string)
	if classification == "" {
		add("classification", "REQUIRED", "le champ 'classification' est requis")
	} else if !classificationEnum[classification] {
		add("classification", "ENUM", "'classification' doit être VH, H ou M : %q invalide", classification)
	}

	// exposure (optionnel) — load-bearing : sélectionne l'ancre de confiance / IdP
	// et l'obligation d'allowlist IP (ADR-076). Absent => hérité par défaut au render.
	exposure, _ := contract["exposure"].(string)
	if exposure != "" && !exposureEnum[exposure] {
		add("exposure", "ENUM", "'exposure' doit être internal ou external : %q invalide", exposure)
	}

	// Cohérence intégrité -> stratégie (ADR-076 Phase 3) : la posture de sécurité
	// est une fonction DÉRIVÉE de la classification. Un contrat dont classification
	// + exposure + tags ne produisent AUCUN bundle valide (niveau inconnu, ou
	// exception apikey hors M/internal) est rejeté fail-closed — un projet ne peut
	// pas shipper une posture plus faible que son niveau d'intégrité. On ne le lance
	// que si la classification est un enum valide (sinon l'erreur ENUM suffit).
	if classificationEnum[classification] && (exposure == "" || exposureEnum[exposure]) {
		var tags []string
		if raw, ok := contract["tags"].([]any); ok {
			for _, t := range raw {
				if s, ok := t.(string); ok {
					tags = append(tags, s)
				}
			}
		}
		if _, rerr := render.Derive(render.Input{Classification: classification, Exposure: exposure, Tags: tags}); rerr != nil {
			add("classification", render.CodeIntegrityInconsistent, "stratégie de sécurité non dérivable : %v", rerr)
		}
	}

	status, _ := contract["status"].(string)
	if status == "" {
		add("status", "REQUIRED", "le champ 'status' est requis")
	} else if !statusEnum[status] {
		add("status", "ENUM", "'status' doit être draft, published ou deprecated : %q invalide", status)
	}

	// --- endpoints ---
	endpoints, epOK := contract["endpoints"].([]any)
	if raw, present := contract["endpoints"]; present && !epOK && raw != nil {
		add("endpoints", "TYPE", "'endpoints' doit être un tableau")
	}
	for i, raw := range endpoints {
		base := fmt.Sprintf("endpoints[%d]", i)
		ep, ok := raw.(map[string]any)
		if !ok {
			add(base, "TYPE", "chaque endpoint doit être un objet")
			continue
		}
		path, _ := ep["path"].(string)
		if path == "" {
			add(base+".path", "REQUIRED", "le champ 'path' est requis")
		}
		backendURL, _ := ep["backend_url"].(string)
		if backendURL == "" {
			add(base+".backend_url", "REQUIRED", "le champ 'backend_url' est requis")
		}
		methods, mOK := ep["methods"].([]any)
		if !mOK || len(methods) == 0 {
			add(base+".methods", "REQUIRED", "au moins une méthode HTTP est requise")
		} else {
			for j, m := range methods {
				ms, _ := m.(string)
				if !methodEnum[ms] {
					add(fmt.Sprintf("%s.methods[%d]", base, j), "ENUM",
						"méthode HTTP invalide %q (GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS)", ms)
				}
			}
		}

		// --- endpoint.llm (MCP projection metadata) ---
		llmRaw, present := ep["llm"]
		if !present || llmRaw == nil {
			continue
		}
		llm, ok := llmRaw.(map[string]any)
		if !ok {
			add(base+".llm", "TYPE", "'llm' doit être un objet")
			continue
		}
		for _, req := range []string{"summary", "intent", "tool_name"} {
			if s, _ := llm[req].(string); s == "" {
				add(base+".llm."+req, "REQUIRED", "le champ '%s' est requis", req)
			}
		}
		sideEffects, _ := llm["side_effects"].(string)
		if sideEffects == "" {
			add(base+".llm.side_effects", "REQUIRED", "le champ 'side_effects' est requis")
		} else if !sideEffectsEnum[sideEffects] {
			add(base+".llm.side_effects", "ENUM",
				"'side_effects' doit être none, read, write ou destructive : %q invalide", sideEffects)
		}
		if _, ok := llm["safe_for_agents"].(bool); !ok {
			add(base+".llm.safe_for_agents", "REQUIRED", "le champ booléen 'safe_for_agents' est requis")
		}
		approval, approvalOK := llm["requires_human_approval"].(bool)
		if !approvalOK {
			add(base+".llm.requires_human_approval", "REQUIRED", "le champ booléen 'requires_human_approval' est requis")
		}
		if examples, ok := llm["examples"].([]any); !ok || len(examples) == 0 {
			add(base+".llm.examples", "REQUIRED", "au moins un exemple est requis")
		}

		// Semantic rule (§5): destructive => requires_human_approval.
		if sideEffects == "destructive" && !(approvalOK && approval) {
			add(base+".llm.requires_human_approval", "DESTRUCTIVE_REQUIRES_APPROVAL",
				"un endpoint avec side_effects=destructive DOIT exiger une approbation humaine (requires_human_approval: true)")
		}
	}

	// Publication gate (§5 mode published): at least one endpoint — SAUF contrat
	// llm-only (le schéma then.anyOf accepte endpoints>=1 OU un llm_config valide).
	if published && len(endpoints) == 0 && contract["llm_config"] == nil {
		add("endpoints", "PUBLISHED_REQUIRES_ENDPOINT",
			"un contrat publié doit exposer au moins un endpoint (ou un llm_config)")
	}

	return errs
}
