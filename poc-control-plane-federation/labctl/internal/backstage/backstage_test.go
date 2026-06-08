package backstage

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"sigs.k8s.io/yaml"
)

// sampleInput is the federated accounts-read API published to all three PoC
// gateways.
func sampleInput() EntityInput {
	return EntityInput{
		Name:     "accounts-read",
		Owner:    "accounts-team",
		System:   "accounts",
		SpecPath: "./apis/accounts-read.openapi.yaml",
		Endpoints: map[string]string{
			"wso2":       "https://wso2am:8243/accounts-read/v1",
			"apisix":     "http://apisix:9080/accounts-read/v1",
			"webmethods": "http://webmethods-mock:8080/gateway/accounts-read/v1",
		},
	}
}

func TestGenerateEntity_LabelsAnnotationsAndSpec(t *testing.T) {
	out, err := GenerateEntity(sampleInput())
	if err != nil {
		t.Fatalf("GenerateEntity: %v", err)
	}

	// Round-trip through YAML so we assert on the parsed structure, not on
	// string formatting.
	var got struct {
		APIVersion string `json:"apiVersion"`
		Kind       string `json:"kind"`
		Metadata   struct {
			Name        string            `json:"name"`
			Labels      map[string]string `json:"labels"`
			Annotations map[string]string `json:"annotations"`
		} `json:"metadata"`
		Spec struct {
			Type       string `json:"type"`
			Lifecycle  string `json:"lifecycle"`
			Owner      string `json:"owner"`
			System     string `json:"system"`
			Definition struct {
				Text string `json:"$text"`
			} `json:"definition"`
		} `json:"spec"`
	}
	if err := yaml.Unmarshal(out, &got); err != nil {
		t.Fatalf("unmarshal generated yaml: %v\n---\n%s", err, out)
	}

	if got.APIVersion != "backstage.io/v1alpha1" {
		t.Errorf("apiVersion = %q, want backstage.io/v1alpha1", got.APIVersion)
	}
	if got.Kind != "API" {
		t.Errorf("kind = %q, want API", got.Kind)
	}
	if got.Metadata.Name != "accounts-read" {
		t.Errorf("metadata.name = %q, want accounts-read", got.Metadata.Name)
	}

	// One boolean label per gateway: gateway.stoa.io/<gw>: "true".
	for _, gw := range []string{"wso2", "apisix", "webmethods"} {
		key := "gateway.stoa.io/" + gw
		if got.Metadata.Labels[key] != "true" {
			t.Errorf("label %s = %q, want \"true\"", key, got.Metadata.Labels[key])
		}
	}

	// One endpoint annotation per gateway: stoa.io/<gw>-endpoint: <invocationURL>.
	wantEndpoints := map[string]string{
		"stoa.io/wso2-endpoint":       "https://wso2am:8243/accounts-read/v1",
		"stoa.io/apisix-endpoint":     "http://apisix:9080/accounts-read/v1",
		"stoa.io/webmethods-endpoint": "http://webmethods-mock:8080/gateway/accounts-read/v1",
	}
	for key, want := range wantEndpoints {
		if got.Metadata.Annotations[key] != want {
			t.Errorf("annotation %s = %q, want %q", key, got.Metadata.Annotations[key], want)
		}
	}

	// Spec fixed shape.
	if got.Spec.Type != "openapi" {
		t.Errorf("spec.type = %q, want openapi", got.Spec.Type)
	}
	if got.Spec.Lifecycle != "experimental" {
		t.Errorf("spec.lifecycle = %q, want experimental", got.Spec.Lifecycle)
	}
	if got.Spec.Owner != "accounts-team" {
		t.Errorf("spec.owner = %q, want accounts-team", got.Spec.Owner)
	}
	if got.Spec.System != "accounts" {
		t.Errorf("spec.system = %q, want accounts", got.Spec.System)
	}
	if got.Spec.Definition.Text != "./apis/accounts-read.openapi.yaml" {
		t.Errorf("spec.definition.$text = %q, want ./apis/accounts-read.openapi.yaml", got.Spec.Definition.Text)
	}
}

// TestGenerateEntity_RawSurface asserts the exact YAML keys are present, so a
// refactor that drops the $text definition or the prefixes is caught.
func TestGenerateEntity_RawSurface(t *testing.T) {
	out, err := GenerateEntity(sampleInput())
	if err != nil {
		t.Fatalf("GenerateEntity: %v", err)
	}
	s := string(out)
	for _, want := range []string{
		"apiVersion: backstage.io/v1alpha1",
		"kind: API",
		"$text: ./apis/accounts-read.openapi.yaml",
		"gateway.stoa.io/wso2",
		"gateway.stoa.io/apisix",
		"gateway.stoa.io/webmethods",
		"stoa.io/wso2-endpoint",
		"stoa.io/apisix-endpoint",
		"stoa.io/webmethods-endpoint",
	} {
		if !strings.Contains(s, want) {
			t.Errorf("generated yaml missing %q\n---\n%s", want, s)
		}
	}
}

func TestGenerateEntity_OmitsEmptySystem(t *testing.T) {
	in := sampleInput()
	in.System = ""
	out, err := GenerateEntity(in)
	if err != nil {
		t.Fatalf("GenerateEntity: %v", err)
	}
	if strings.Contains(string(out), "system:") {
		t.Errorf("expected no system key when System empty\n---\n%s", out)
	}
}

func TestGenerateEntity_Validation(t *testing.T) {
	if _, err := GenerateEntity(EntityInput{SpecPath: "x"}); err == nil {
		t.Error("expected error on empty Name")
	}
	if _, err := GenerateEntity(EntityInput{Name: "x"}); err == nil {
		t.Error("expected error on empty SpecPath")
	}
}

// registerServer captures what RegisterLocation sends and replies with the
// given status + body.
func registerServer(t *testing.T, status int, respBody string) (*httptest.Server, *capturedReq) {
	t.Helper()
	cap := &capturedReq{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cap.method = r.Method
		cap.path = r.URL.Path
		cap.contentType = r.Header.Get("Content-Type")
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &cap.body)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, respBody)
	}))
	t.Cleanup(srv.Close)
	return srv, cap
}

type capturedReq struct {
	method      string
	path        string
	contentType string
	body        map[string]string
}

func (c *capturedReq) assertWellFormed(t *testing.T, wantTarget string) {
	t.Helper()
	if c.method != http.MethodPost {
		t.Errorf("method = %q, want POST", c.method)
	}
	if c.path != "/api/catalog/locations" {
		t.Errorf("path = %q, want /api/catalog/locations", c.path)
	}
	if !strings.HasPrefix(c.contentType, "application/json") {
		t.Errorf("Content-Type = %q, want application/json", c.contentType)
	}
	if c.body["type"] != "url" {
		t.Errorf("body.type = %q, want url", c.body["type"])
	}
	if c.body["target"] != wantTarget {
		t.Errorf("body.target = %q, want %q", c.body["target"], wantTarget)
	}
}

const target = "https://github.com/stoa-platform/apis/blob/main/accounts-read/catalog-info.yaml"

func TestRegisterLocation_Created201(t *testing.T) {
	srv, cap := registerServer(t, http.StatusCreated,
		`{"location":{"id":"abc","type":"url","target":"`+target+`"},"entities":[]}`)

	if err := RegisterLocation(context.Background(), srv.URL, target); err != nil {
		t.Fatalf("RegisterLocation on 201: unexpected error: %v", err)
	}
	cap.assertWellFormed(t, target)
}

func TestRegisterLocation_Conflict409IsSuccess(t *testing.T) {
	srv, cap := registerServer(t, http.StatusConflict,
		`{"error":{"name":"ConflictError","message":"Location already exists"}}`)

	// 409 ConflictError = already registered = success (idempotent).
	if err := RegisterLocation(context.Background(), srv.URL, target); err != nil {
		t.Fatalf("RegisterLocation on 409: want success, got error: %v", err)
	}
	cap.assertWellFormed(t, target)
}

func TestRegisterLocation_ServerErrorFails(t *testing.T) {
	srv, _ := registerServer(t, http.StatusInternalServerError, `{"error":"boom"}`)
	if err := RegisterLocation(context.Background(), srv.URL, target); err == nil {
		t.Error("expected error on 500, got nil")
	}
}

func TestRegisterLocation_Validation(t *testing.T) {
	if err := RegisterLocation(context.Background(), "", target); err == nil {
		t.Error("expected error on empty backstageURL")
	}
	if err := RegisterLocation(context.Background(), "http://x", ""); err == nil {
		t.Error("expected error on empty targetURL")
	}
}
