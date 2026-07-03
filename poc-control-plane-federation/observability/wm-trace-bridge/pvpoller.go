package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"
)

// Le gateway 10.15 ne dispatche PAS les PolicyViolation (rejets 401/403) vers
// les custom destinations (vérifié in-situ, ADR-073) — mais il les écrit dans
// son API Data Store (index gateway_default_analytics_policyviolationevents*).
// Ce poller OSS comble l'angle mort : il interroge l'ES du gateway et injecte
// chaque violation dans le même chemin que les autres events (topic Kafka si
// activé, sinon spans directs) → spans Error visibles dans Tempo.
//
// Curseur en mémoire initialisé à NOW : seuls les rejets postérieurs au boot
// du bridge sont émis (pas de replay d'historique, pas de doublons après
// restart — au pire un trou de quelques secondes, assumé).

const pvIndexPattern = "gateway_default_analytics_policyviolationevents*"

// parsePVHits extrait les _source bruts d'une réponse _search ES et le plus
// grand creationDate vu (nouveau curseur).
func parsePVHits(body []byte) ([][]byte, int64, error) {
	var resp struct {
		Hits struct {
			Hits []struct {
				Source json.RawMessage `json:"_source"`
			} `json:"hits"`
		} `json:"hits"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, 0, err
	}
	var raws [][]byte
	var maxCreation int64
	for _, h := range resp.Hits.Hits {
		var ev struct {
			CreationDate float64 `json:"creationDate"`
		}
		if err := json.Unmarshal(h.Source, &ev); err != nil || ev.CreationDate <= 0 {
			continue
		}
		raws = append(raws, []byte(h.Source))
		if c := int64(ev.CreationDate); c > maxCreation {
			maxCreation = c
		}
	}
	return raws, maxCreation, nil
}

// runPVPoller interroge périodiquement l'ES du gateway. esURL vide = désactivé.
func runPVPoller(ctx context.Context, esURL string, every time.Duration, dispatch func([]byte)) {
	cursor := time.Now().UnixMilli()
	client := &http.Client{Timeout: 10 * time.Second}
	ticker := time.NewTicker(every)
	go func() {
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
			query := fmt.Sprintf(`{"size":100,"sort":[{"creationDate":{"order":"asc"}}],"query":{"range":{"creationDate":{"gt":%d}}}}`, cursor)
			req, err := http.NewRequestWithContext(ctx, http.MethodPost,
				esURL+"/"+pvIndexPattern+"/_search", bytes.NewReader([]byte(query)))
			if err != nil {
				continue
			}
			req.Header.Set("Content-Type", "application/json")
			resp, err := client.Do(req)
			if err != nil {
				log.Printf("pv poller: %v (gateway ES injoignable — recycle en cours ?)", err)
				continue
			}
			body, err := io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes))
			_ = resp.Body.Close()
			if err != nil || resp.StatusCode != http.StatusOK {
				log.Printf("pv poller: HTTP %d (%v)", resp.StatusCode, err)
				continue
			}
			raws, maxCreation, err := parsePVHits(body)
			if err != nil {
				log.Printf("pv poller parse: %v", err)
				continue
			}
			for _, raw := range raws {
				dispatch(raw)
			}
			if maxCreation > cursor {
				cursor = maxCreation
			}
		}
	}()
}
