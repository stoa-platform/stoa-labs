// Command webmethods-mock is a faithful stand-in for the webMethods API
// Gateway admin REST surface used by the STOA webMethods Link, plus a minimal
// data-plane proxy and native OTel emission. It represents the bank's legacy
// commercial runtime in the federation PoC and can be swapped for a real
// `apigateway:10.15` without changing the Link.
package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

func main() {
	healthcheck := flag.Bool("healthcheck", false, "probe the local /health endpoint and exit (for docker HEALTHCHECK)")
	flag.Parse()
	if *healthcheck {
		os.Exit(runHealthcheck(envOr("LISTEN_ADDR", ":8080")))
	}

	addr := envOr("LISTEN_ADDR", ":8080")
	serviceName := envOr("OTEL_SERVICE_NAME", "webmethods-mock")

	ctx := context.Background()
	shutdownOTel, err := initOTel(ctx, serviceName)
	if err != nil {
		log.Fatalf("otel init: %v", err)
	}

	srv := NewServer()
	// otelhttp wraps the mux so every request emits a span natively.
	handler := otelhttp.NewHandler(srv.Handler(), "webmethods-mock")

	httpSrv := &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		log.Printf("webmethods-mock listening on %s (otel=%q)", addr, os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT"))
		if err := httpSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("listen: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	shutCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = httpSrv.Shutdown(shutCtx)
	_ = shutdownOTel(shutCtx)
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// runHealthcheck performs an in-process liveness probe so the distroless image
// (no curl/wget) can be health-checked via the binary itself.
func runHealthcheck(addr string) int {
	host := "127.0.0.1" + addr // addr like ":8080"
	c := &http.Client{Timeout: 3 * time.Second}
	resp, err := c.Get("http://" + host + "/health")
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
