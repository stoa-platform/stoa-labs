// Package httpx provides the shared HTTP client and small request helpers used
// by every gateway adapter: one place to opt into InsecureSkipVerify (WSO2's
// self-signed cert) and to issue JSON/raw calls with consistent error wrapping.
package httpx

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// NewClient returns an *http.Client. When insecure is true the transport skips
// TLS verification — required for WSO2's self-signed :9443/:8243 in the PoC.
func NewClient(insecure bool) *http.Client {
	tr := &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: insecure}, //nolint:gosec // PoC self-signed certs
	}
	return &http.Client{Timeout: 60 * time.Second, Transport: tr}
}

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
