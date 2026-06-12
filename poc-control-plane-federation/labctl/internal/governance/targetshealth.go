package governance

import (
	"context"
	"crypto/tls"
	"net/http"
	"os"
	"sync"
	"time"

	"sigs.k8s.io/yaml"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/targets"
)

// TargetStatus is one GET /targets element: a federation gateway plus a
// cheap parallel HTTP health probe (2s timeout, never blocking the demo).
type TargetStatus struct {
	Name       string `json:"name"`
	Type       string `json:"type"`
	AdminURL   string `json:"adminUrl"`
	GatewayURL string `json:"gatewayUrl"`
	Health     string `json:"health"` // up | down | unknown
	LatencyMS  *int64 `json:"latency_ms,omitempty"`
}

// LoadTargets reads TARGETS_FILE. It first tries targets.Load (the labctl
// loader, which also validates contract/backend fields); when that fails —
// e.g. a console-only manifest without a contract — it falls back to a
// tolerant parse of just the targets list.
func LoadTargets(path string) ([]targets.Target, error) {
	if f, err := targets.Load(path); err == nil {
		return f.Targets, nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var f targets.File
	if err := yaml.Unmarshal(raw, &f); err != nil {
		return nil, err
	}
	return f.Targets, nil
}

// ProbeTargets pings each target's adminUrl in parallel (GET, 2s timeout).
// Any HTTP response counts as "up" (the gateway control plane answered);
// transport errors are "down"; a missing adminUrl is "unknown".
func ProbeTargets(ctx context.Context, ts []targets.Target) []TargetStatus {
	out := make([]TargetStatus, len(ts))
	var wg sync.WaitGroup
	for i, t := range ts {
		out[i] = TargetStatus{
			Name:       t.Name,
			Type:       t.Type,
			AdminURL:   t.AdminURL,
			GatewayURL: t.GatewayURL,
			Health:     "unknown",
		}
		if t.AdminURL == "" {
			continue
		}
		wg.Add(1)
		go func(i int, adminURL string, insecure bool) {
			defer wg.Done()
			cctx, cancel := context.WithTimeout(ctx, 2*time.Second)
			defer cancel()
			req, err := http.NewRequestWithContext(cctx, http.MethodGet, adminURL, nil)
			if err != nil {
				out[i].Health = "down"
				return
			}
			client := &http.Client{
				Timeout: 2 * time.Second,
				Transport: &http.Transport{
					TLSClientConfig: &tls.Config{InsecureSkipVerify: insecure}, //nolint:gosec // PoC self-signed gateways
				},
			}
			start := time.Now()
			resp, err := client.Do(req)
			if err != nil {
				out[i].Health = "down"
				return
			}
			resp.Body.Close()
			ms := time.Since(start).Milliseconds()
			out[i].Health = "up"
			out[i].LatencyMS = &ms
		}(i, t.AdminURL, t.Insecure)
	}
	wg.Wait()
	return out
}
