// Package httpx provides the shared HTTP client and small request helpers used
// by every gateway adapter: one place to opt into InsecureSkipVerify (WSO2's
// self-signed cert), to honor the enterprise egress knobs (proxy + CA bundle),
// and to issue JSON/raw calls with consistent error wrapping.
package httpx

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// NewClient returns an *http.Client honoring the enterprise egress knobs:
//
//   - HTTP_PROXY / HTTPS_PROXY / NO_PROXY — behind a bank egress proxy every
//     admin call must go through it (and NO_PROXY exempts in-zone gateways);
//   - LABCTL_CA_FILE — a PEM bundle APPENDED to the system roots, for gateways
//     serving certificates from an enterprise CA the OS store does not know.
//
// When insecure is true the transport skips TLS verification — the PoC escape
// hatch for WSO2's self-signed :9443/:8243; a client site sets LABCTL_CA_FILE
// instead and never needs Insecure.
func NewClient(insecure bool) *http.Client {
	return NewClientCA(insecure, os.Getenv("LABCTL_CA_FILE"))
}

// NewClientCA is NewClient with an explicit CA bundle path — for callers whose
// CA knob is not LABCTL_CA_FILE (internal/vault honors the standard
// VAULT_CACERT). An empty caFile means system roots only.
//
// A caFile that is set but unreadable or holds no PEM certificate FAILS CLOSED:
// every request through the returned client errors with the cause, instead of
// silently verifying against the system pool the operator asked to extend.
func NewClientCA(insecure bool, caFile string) *http.Client {
	tlsCfg := &tls.Config{InsecureSkipVerify: insecure} //nolint:gosec // PoC self-signed certs, opt-in per target
	if caFile = strings.TrimSpace(caFile); caFile != "" {
		pool, err := loadCAPool(caFile)
		if err != nil {
			return &http.Client{Timeout: 60 * time.Second, Transport: errorTransport{err}}
		}
		tlsCfg.RootCAs = pool
	}
	tr := &http.Transport{
		Proxy:           http.ProxyFromEnvironment,
		TLSClientConfig: tlsCfg,
	}
	return &http.Client{Timeout: 60 * time.Second, Transport: tr}
}

// loadCAPool returns the system roots extended with the PEM bundle at path —
// extended, not replaced, so one knob covers both enterprise-CA gateways and
// public endpoints in the same run.
func loadCAPool(path string) (*x509.CertPool, error) {
	pemBytes, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read CA bundle %s: %w", path, err)
	}
	pool, err := x509.SystemCertPool()
	if err != nil || pool == nil {
		pool = x509.NewCertPool()
	}
	if !pool.AppendCertsFromPEM(pemBytes) {
		return nil, fmt.Errorf("CA bundle %s: no PEM certificate found", path)
	}
	return pool, nil
}

// errorTransport surfaces a client-construction error at request time, keeping
// NewClient's no-error signature for its many call sites while staying
// fail-closed on a broken CA knob.
type errorTransport struct{ err error }

func (t errorTransport) RoundTrip(*http.Request) (*http.Response, error) { return nil, t.err }

// Do issues a request and returns status code + raw body. headers and body may
// be nil. It never treats non-2xx as a transport error; callers decide.
func Do(ctx context.Context, c *http.Client, method, url string, headers map[string]string, body io.Reader) (int, []byte, error) {
	req, err := http.NewRequestWithContext(ctx, method, url, body)
	if err != nil {
		return 0, nil, fmt.Errorf("build %s %s: %w", method, url, err)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := c.Do(req)
	if err != nil {
		return 0, nil, fmt.Errorf("%s %s: %w", method, url, err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return resp.StatusCode, nil, fmt.Errorf("read %s %s: %w", method, url, err)
	}
	return resp.StatusCode, raw, nil
}

// JSON sends an optional JSON body and decodes a 2xx JSON response into out
// (out may be nil to ignore the body). On a non-2xx status it returns an error
// carrying the status and the response body, which is what makes adapter
// failures actionable ("403 on deploy-revision: ...").
func JSON(ctx context.Context, c *http.Client, method, url string, headers map[string]string, in, out any) (int, error) {
	var rdr io.Reader
	h := map[string]string{"Accept": "application/json"}
	for k, v := range headers {
		h[k] = v
	}
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return 0, fmt.Errorf("marshal body for %s %s: %w", method, url, err)
		}
		rdr = bytes.NewReader(b)
		h["Content-Type"] = "application/json"
	}
	code, raw, err := Do(ctx, c, method, url, h, rdr)
	if err != nil {
		return code, err
	}
	if code < 200 || code >= 300 {
		return code, fmt.Errorf("%s %s -> %d: %s", method, url, code, truncate(raw, 600))
	}
	if out != nil && len(bytes.TrimSpace(raw)) > 0 {
		if err := json.Unmarshal(raw, out); err != nil {
			return code, fmt.Errorf("decode %s %s response: %w", method, url, err)
		}
	}
	return code, nil
}

func truncate(b []byte, n int) string {
	if len(b) <= n {
		return string(b)
	}
	return string(b[:n]) + "…"
}
