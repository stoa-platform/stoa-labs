package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func newTestServer() http.Handler {
	return NewServer().Handler()
}

func do(t *testing.T, h http.Handler, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatalf("encode: %v", err)
		}
	}
	req := httptest.NewRequest(method, path, &buf)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	return rr
}

func TestHealth(t *testing.T) {
	rr := do(t, newTestServer(), "GET", "/rest/apigateway/is/health", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("health code = %d", rr.Code)
	}
	var out map[string]any
	_ = json.Unmarshal(rr.Body.Bytes(), &out)
	if out["isAlive"] != true {
		t.Fatalf("expected isAlive true, got %v", out)
	}
}

func TestRegisterListAndDataPlane(t *testing.T) {
	h := newTestServer()

	// Register an API (what the STOA Link does from one OpenAPI contract).
	rr := do(t, h, "POST", "/rest/apigateway/apis", map[string]string{
		"apiName":  "accounts-read",
		"basePath": "/accounts",
	})
	if rr.Code != http.StatusCreated {
		t.Fatalf("create code = %d body=%s", rr.Code, rr.Body)
	}
	var created API
	if err := json.Unmarshal(rr.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if created.ID == "" || created.BasePath != "/accounts" {
		t.Fatalf("unexpected created api: %+v", created)
	}

	// List must show it.
	rr = do(t, h, "GET", "/rest/apigateway/apis", nil)
	var list struct {
		Count int `json:"count"`
	}
	_ = json.Unmarshal(rr.Body.Bytes(), &list)
	if list.Count != 1 {
		t.Fatalf("expected 1 api, got %d", list.Count)
	}

	// Data-plane call on the registered basePath → synthetic 200.
	rr = do(t, h, "GET", "/gateway/accounts/123", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("dataplane code = %d body=%s", rr.Code, rr.Body)
	}
	var dp map[string]any
	_ = json.Unmarshal(rr.Body.Bytes(), &dp)
	if dp["api"] != "accounts-read" || dp["synthetic"] != true {
		t.Fatalf("unexpected dataplane body: %v", dp)
	}
}

func TestDataPlaneUnknownPath(t *testing.T) {
	rr := do(t, newTestServer(), "GET", "/gateway/unknown/x", nil)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("expected 404 for unknown path, got %d", rr.Code)
	}
}

func TestCreateSubscription(t *testing.T) {
	rr := do(t, newTestServer(), "POST", "/rest/apigateway/subscriptions", map[string]string{
		"applicationName": "dev-app",
		"clientId":        "kc-client-123",
	})
	if rr.Code != http.StatusCreated {
		t.Fatalf("sub code = %d body=%s", rr.Code, rr.Body)
	}
	var sub Subscription
	_ = json.Unmarshal(rr.Body.Bytes(), &sub)
	if sub.ID == "" {
		t.Fatalf("expected subscription id, got %+v", sub)
	}
}

func TestCreateAPIValidation(t *testing.T) {
	rr := do(t, newTestServer(), "POST", "/rest/apigateway/apis", map[string]string{"apiName": "no-basepath"})
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for missing basePath, got %d", rr.Code)
	}
}
