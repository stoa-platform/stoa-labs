// Command wm-trace-bridge convertit les événements transactionnels que
// webMethods API Gateway 10.15 publie vers une custom destination « External
// endpoint » en spans OpenTelemetry, exportés en OTLP/HTTP vers otel-lgtm
// (Tempo). Le tracer natif du gateway est inroutable (couplé à l'API Data
// Store) et l'agent E2EM officiel est payant (écarté par le client) — ce pont
// est la voie retenue, PoC et cible, cf. adr/adr-073-wm-traces-tempo.md.
//
// Architecture durable-first (révision HA, mêmes ADR) quand Kafka est activé :
//
//	POST /events ──┐                       ┌─► consumer «wm-trace-bridge-spans» ─► spans OTLP → Tempo
//	               ├─► Redpanda (topic) ───┤
//	pv poller ─────┘                       └─► consumer «data-prepper» ─► OpenSearch txn-{tenant}
//
// L'ingestion ne fait que persister ; bridge redémarré ou Tempo down = les
// events attendent dans le topic. Sans Kafka (WM_TXN_KAFKA_BROKERS vide) :
// mode direct (spans émis dans le handler), sans branche analytics.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/trace"
)

const maxBodyBytes = 10 << 20 // les events wM font ~2-3 Ko ; large marge.

func contextBackground() context.Context { return context.Background() }

// lastEvent retient le dernier event brut reçu du gateway — exposé sur
// /debug/last-event pour le harnais de contrat (scripts/wm-contract-check.sh,
// re-validation des comportements non documentés à chaque fixpack).
type lastEvent struct {
	mu  sync.RWMutex
	raw []byte
	at  time.Time
}

func (l *lastEvent) Set(raw []byte) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.raw = append([]byte(nil), raw...)
	l.at = time.Now()
}

func (l *lastEvent) Get() ([]byte, time.Time) {
	l.mu.RLock()
	defer l.mu.RUnlock()
	return l.raw, l.at
}

// emitRaw parse UN event brut (un record Kafka ou un POST gateway) et émet
// ses spans. Utilisé par le consumer (mode durable) ou le handler (mode direct).
func emitRaw(tracer trace.Tracer, raw []byte) {
	evs, _, err := parseEvents(raw)
	if err != nil {
		log.Printf("parse error: %v (body %.200q)", err, string(raw))
		return
	}
	for _, ev := range evs {
		if ev.EventType == "" && ev.APIName == "" {
			continue
		}
		emit(tracer, ev)
		// Une ligne par event : c'est LE signal « les events arrivent »
		// quand on cherche ses traces (volume PoC ≈ 1 ligne/appel API).
		log.Printf("event %s %s/%s -> span(s) émis (status=%s code=%s)",
			ev.EventType, ev.APIName, ev.APIVersion, ev.Status, ev.ResponseCode)
	}
}

func main() {
	healthcheck := flag.Bool("healthcheck", false, "probe the local /health endpoint and exit (for docker HEALTHCHECK)")
	flag.Parse()
	addr := envOr("LISTEN_ADDR", ":9100")
	if *healthcheck {
		os.Exit(runHealthcheck(addr))
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	shutdownOTel, err := initOTel(ctx, envOr("OTEL_SERVICE_NAME", "webmethods"))
	if err != nil {
		log.Fatalf("otel init: %v", err)
	}
	tracer := otel.Tracer("wm-trace-bridge")

	brokers := os.Getenv("WM_TXN_KAFKA_BROKERS")
	topic := envOr("WM_TXN_KAFKA_TOPIC", "stoa.txn.webmethods")
	publisher, err := newTxnPublisher(brokers, topic)
	if err != nil {
		log.Fatalf("kafka init: %v", err)
	}
	durable := brokers != ""

	// dispatch = le point d'entrée unique des events (HTTP et pv poller) :
	// durable-first si Kafka, sinon émission directe.
	dispatch := func(raw []byte) {
		// Stamp a W3C trace context if the client did not propagate one, so the
		// txn analytics record AND the OTel span share ONE trace_id (APISIX
		// parity — 100% txn<->trace correlation, not only propagated calls).
		raw = ensureTraceparent(raw)
		if durable {
			publisher.Publish(raw)
		} else {
			emitRaw(tracer, raw)
		}
	}
	if durable {
		if err := runSpanConsumer(ctx, brokers, topic, "wm-trace-bridge-spans",
			func(raw []byte) { emitRaw(tracer, raw) }); err != nil {
			log.Fatalf("kafka consumer: %v", err)
		}
	}

	// Angle mort 401 : le gateway ne dispatche pas les PolicyViolation vers les
	// custom destinations → on les lit dans son API Data Store. URL vide = off.
	if pvURL := os.Getenv("WM_PV_POLL_URL"); pvURL != "" {
		runPVPoller(ctx, pvURL, 30*time.Second, dispatch)
		log.Printf("pv poller actif sur %s (spans Error pour les rejets 401/403)", pvURL)
	}

	var last lastEvent
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	// Harnais de contrat fixpack : dernier event brut reçu du gateway, tel quel.
	mux.HandleFunc("GET /debug/last-event", func(w http.ResponseWriter, _ *http.Request) {
		raw, at := last.Get()
		if raw == nil {
			http.Error(w, "no event received yet", http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Received-At", at.UTC().Format(time.RFC3339Nano))
		_, _ = w.Write(raw)
	})
	mux.HandleFunc("POST /events", func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(io.LimitReader(r.Body, maxBodyBytes))
		if err != nil {
			http.Error(w, "read error", http.StatusBadRequest)
			return
		}
		evs, raws, err := parseEvents(body)
		if err != nil {
			// On répond 200 quand même : le dispatcher du gateway n'a pas de
			// retry utile et un 4xx ne ferait que polluer ses logs. On trace
			// l'anomalie côté bridge pour diagnostic.
			log.Printf("parse error: %v (body %.200q)", err, string(body))
			w.WriteHeader(http.StatusOK)
			return
		}
		received := 0
		for i, ev := range evs {
			// Élément vide d'un tableau ([{}]) : rien à faire.
			if ev.EventType == "" && ev.APIName == "" {
				continue
			}
			last.Set(raws[i])
			dispatch(raws[i])
			received++
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]int{"received": received})
	})

	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		log.Printf("wm-trace-bridge listening on %s (otel=%q, kafka=%v)", addr, os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT"), durable)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("listen: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	shutCtx, cancelShut := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelShut()
	_ = srv.Shutdown(shutCtx)
	cancel() // stoppe consumer + poller
	publisher.Close()
	_ = shutdownOTel(shutCtx)
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// runHealthcheck sonde /health en-process : l'image distroless n'a ni curl ni
// wget (même pattern que mocks/webmethods).
func runHealthcheck(addr string) int {
	c := &http.Client{Timeout: 3 * time.Second}
	resp, err := c.Get("http://127.0.0.1" + addr + "/health")
	if err != nil {
		log.Printf("healthcheck: %v", err)
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}
