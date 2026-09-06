package render

import (
	"bytes"
	"encoding/json"
	"encoding/xml"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// The mirrors of this package's vocabulary that cannot import it:
//   - schemaPath: the UAC JSON schema the BFF serves and the UI validates
//     against with ajv;
//   - formPath: the PRODUCER's Jenkins form (jalon P2) — the two drop-downs a
//     human picks a posture from. Jenkins job XML cannot import Go either, so
//     it keeps a copy and this file is what stops it drifting.
const (
	schemaPath = "../../cmd/governance-api/uac_contract_v1_schema.json"
	formPath   = "../../../ci/jenkins/api-request.job.xml"
)

// TestSchemaVocabularyDoesNotDrift is the mechanical replacement for the
// hand-copied enums P1 removed. Go callers now ask render for the vocabulary;
// JSON cannot, so the schema keeps a copy and THIS test is what stops it
// drifting. A value added to the engine and forgotten in the schema would
// otherwise be accepted by the derivation and rejected by the BFF/UI — the
// exact silent divergence this jalon exists to close.
//
// Fail-closed by design: an unreadable or restructured schema FAILS here, it
// never skips.
func TestSchemaVocabularyDoesNotDrift(t *testing.T) {
	raw, err := os.ReadFile(filepath.Clean(schemaPath))
	if err != nil {
		t.Fatalf("schéma UAC illisible (%s) : %v — le miroir du vocabulaire doit rester vérifiable", schemaPath, err)
	}
	var doc struct {
		Defs map[string]struct {
			Enum []string `json:"enum"`
		} `json:"$defs"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("schéma UAC non décodable : %v", err)
	}

	for _, tc := range []struct {
		def  string
		want []string
	}{
		{"Exposure", Exposures()},
		{"Classification", Classifications()},
	} {
		got, ok := doc.Defs[tc.def]
		if !ok {
			t.Errorf("$defs.%s absent du schéma UAC", tc.def)
			continue
		}
		if !reflect.DeepEqual(got.Enum, tc.want) {
			t.Errorf("$defs.%s.enum = %v, mais render fait autorité et dit %v — le schéma a dérivé", tc.def, got.Enum, tc.want)
		}
	}
}

// TestProducerFormVocabularyDoesNotDrift pins the producer's Jenkins form
// (jalon P2) to this package. The form is where a human PICKS a posture: a
// drop-down offering a value the engine does not govern produces a demand that
// is refused only later, at the plan or at the apply, with a code the demander
// did not cause — and a value the engine governs but the form omits is simply
// unreachable, silently. Neither shows up in any other test, because nothing
// else reads this file.
//
// Fail-closed like its JSON twin: an unreadable or restructured form FAILS, it
// never skips.
func TestProducerFormVocabularyDoesNotDrift(t *testing.T) {
	raw, err := os.ReadFile(filepath.Clean(formPath))
	if err != nil {
		t.Fatalf("formulaire producteur illisible (%s) : %v — le miroir du vocabulaire doit rester vérifiable", formPath, err)
	}
	// Jenkins writes `<?xml version='1.1' …?>`; Go's encoding/xml supports 1.0
	// only and refuses the document on the declaration alone. The declaration
	// carries nothing this test reads, so it is dropped rather than parsed.
	if i := bytes.Index(raw, []byte("?>")); i >= 0 && bytes.HasPrefix(raw, []byte("<?xml")) {
		raw = raw[i+2:]
	}
	var doc struct {
		Params []struct {
			Name    string   `xml:"name"`
			Choices []string `xml:"choices>a>string"`
		} `xml:"properties>hudson.model.ParametersDefinitionProperty>parameterDefinitions>hudson.model.ChoiceParameterDefinition"`
	}
	if err := xml.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("formulaire producteur non décodable : %v", err)
	}
	got := map[string][]string{}
	for _, p := range doc.Params {
		got[p.Name] = p.Choices
	}

	for _, tc := range []struct {
		param string
		want  []string
	}{
		{"CLASSIFICATION", Classifications()},
		{"EXPOSURE", Exposures()},
	} {
		have, ok := got[tc.param]
		if !ok {
			t.Errorf("paramètre %s absent du formulaire producteur — la demande ne collecte pas la posture", tc.param)
			continue
		}
		if !reflect.DeepEqual(have, tc.want) {
			t.Errorf("choices de %s = %v, mais render fait autorité et dit %v — le formulaire a dérivé", tc.param, have, tc.want)
		}
	}
}
