package httpx

// This file is named to sort BEFORE client_test.go: net/http resolves
// HTTP_PROXY/HTTPS_PROXY once per process (envProxyOnce) at the first
// ProxyFromEnvironment call, so the proxy test must issue the first request of
// the test binary — any earlier request would freeze an empty proxy config.

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestNewClientHonorsProxyEnv proves the É0 fix: behind an egress proxy
// (HTTP_PROXY set), labctl's admin calls go THROUGH the proxy instead of
// attempting a direct (firewalled) connection. The fake proxy answers for a
// non-resolvable host — the request can only succeed via the proxy.
func TestNewClientHonorsProxyEnv(t *testing.T) {
	var sawAbsoluteForm bool
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// A proxied HTTP request arrives in absolute form: GET http://host/path.
		sawAbsoluteForm = r.URL.IsAbs() && r.URL.Host == "gateway.example.invalid"
		_, _ = io.WriteString(w, "via-proxy")
	}))
	defer proxy.Close()

	t.Setenv("HTTP_PROXY", proxy.URL)
	t.Setenv("NO_PROXY", "")

	c := NewClient(false)
	code, body, err := Do(context.Background(), c, http.MethodGet, "http://gateway.example.invalid/health", nil, nil)
	if err != nil {
		t.Fatalf("request via proxy: %v", err)
	}
	if code != http.StatusOK || string(body) != "via-proxy" {
		t.Fatalf("expected proxied 200/via-proxy, got %d/%q", code, body)
	}
	if !sawAbsoluteForm {
		t.Fatal("proxy did not receive an absolute-form request — transport bypassed HTTP_PROXY")
	}
}
