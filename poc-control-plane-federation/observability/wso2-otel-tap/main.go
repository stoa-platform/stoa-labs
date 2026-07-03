// Command wso2-otel-tap sits inline on WSO2 API Manager's OTLP/gRPC trace
// export (ADR-070/073, goal A3): WSO2 points its native OpenTelemetry exporter
// at THIS process instead of otel-lgtm. For every batch of spans the tap does
// the "Y":
//
//	WSO2 --OTLP/gRPC--> wso2-otel-tap ─┬─► forward (OTLP/gRPC) ─► otel-lgtm (Tempo, INCHANGÉ)
//	                                   └─► stoa.txn.wso2 record ─► Redpanda ─► Data Prepper ─► OpenSearch txn-{tenant}
//
// The transaction record carries the span's NATIVE W3C trace_id, so the
// governance/audit plane (OpenSearch) and the ops plane (Tempo) pivot on the
// SAME id — the APISIX/webMethods parity, now for WSO2. The tap NEVER redacts
// (spans carry no body; Data Prepper stays the single redaction authority) and
// NEVER blocks the trace path: a Kafka failure is logged, the forward still
// returns OK to the gateway.
package main

import (
	"context"
	"flag"
	"log"
	"net"
	"os"
	"os/signal"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	// WSO2's OTLP exporter compresses spans with gzip (setCompression("gzip"),
	// vérité bytecode OTLPTelemetry) — registering the gzip codec lets the gRPC
	// server DECOMPRESS them (sinon UNIMPLEMENTED "Decompressor is not installed
	// for grpc-encoding gzip"). Blank import = global codec registration.
	_ "google.golang.org/grpc/encoding/gzip"

	coltracepb "go.opentelemetry.io/proto/otlp/collector/trace/v1"
	tracepb "go.opentelemetry.io/proto/otlp/trace/v1"
)

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// tapServer implements the OTLP TraceService: forward + fan-out to Kafka.
type tapServer struct {
	coltracepb.UnimplementedTraceServiceServer
	forward   coltracepb.TraceServiceClient
	publisher txnPublisher
	tenants   tenantResolver
	// fwdErrors counts consecutive forward failures. A permanently-broken
	// forward would silently regress the A2 trace-federation (WSO2 sees its
	// OTLP export succeed against the tap while Tempo receives nothing), so we
	// make the failure LOUD and escalating instead of one quiet log line.
	fwdErrors atomic.Int64
	fwdOK     atomic.Int64
}

func (s *tapServer) Export(ctx context.Context, req *coltracepb.ExportTraceServiceRequest) (*coltracepb.ExportTraceServiceResponse, error) {
	// 1. Analytics branch FIRST (never lost if the forward errors): one
	// stoa.txn record per API trace, from the span's native attributes.
	var spans []*tracepb.Span
	for _, rs := range req.GetResourceSpans() {
		for _, ss := range rs.GetScopeSpans() {
			spans = append(spans, ss.GetSpans()...)
		}
	}
	for _, rec := range recordsFromTrace(spans, s.tenants) {
		s.publisher.Publish(rec.marshal())
		log.Printf("txn wso2 %s %s -> %d (trace_id=%s tenant=%s)",
			rec.HTTPMethod, rec.API, rec.HTTPStatus, rec.TraceID, rec.Tenant)
	}

	// 2. Forward the UNCHANGED batch to otel-lgtm so Tempo keeps the full WSO2
	// trace. If the collector is momentarily down we still answer OK — the
	// gateway must not stall on our forward, and WSO2's own BatchSpanProcessor
	// already retries. But a PERMANENTLY broken forward is an A2 regression with
	// no visible error (WSO2's exports all succeed against us), so we escalate:
	// log every failure while broken, and a recovery line once it works again.
	if s.forward != nil {
		if _, err := s.forward.Export(ctx, req); err != nil {
			n := s.fwdErrors.Add(1)
			s.fwdOK.Store(0)
			log.Printf("forward to collector FAILING (%d consécutifs): %v — Tempo ne reçoit plus les traces WSO2 (régression A2 ; vérifier FORWARD_OTLP_GRPC/otel-lgtm)", n, err)
		} else if s.fwdErrors.Swap(0) > 0 && s.fwdOK.Add(1) == 1 {
			log.Printf("forward to collector RÉTABLI — les traces WSO2 repartent vers Tempo")
		}
	}
	return &coltracepb.ExportTraceServiceResponse{}, nil
}

func main() {
	healthcheck := flag.Bool("healthcheck", false, "probe the listen port and exit (docker HEALTHCHECK)")
	flag.Parse()
	listen := envOr("LISTEN_ADDR", ":4317")
	if *healthcheck {
		// A ":4317" listen addr dials as "127.0.0.1:4317"; a "host:port" addr
		// dials as-is.
		dialAddr := listen
		if strings.HasPrefix(listen, ":") {
			dialAddr = "127.0.0.1" + listen
		}
		conn, err := net.DialTimeout("tcp", dialAddr, 2*time.Second)
		if err != nil {
			os.Exit(1)
		}
		_ = conn.Close()
		os.Exit(0)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Downstream collector (Tempo). Empty => forward disabled (tap still emits
	// analytics), so the process degrades gracefully in tests.
	var forward coltracepb.TraceServiceClient
	if target := os.Getenv("FORWARD_OTLP_GRPC"); target != "" {
		conn, err := grpc.NewClient(target, grpc.WithTransportCredentials(insecure.NewCredentials()))
		if err != nil {
			log.Fatalf("dial collector %q: %v", target, err)
		}
		defer conn.Close()
		forward = coltracepb.NewTraceServiceClient(conn)
		log.Printf("forwarding spans to %s", target)
	} else {
		log.Printf("FORWARD_OTLP_GRPC vide : forward désactivé (analytics seule)")
	}

	publisher, err := newTxnPublisher(os.Getenv("WSO2_TXN_KAFKA_BROKERS"), envOr("WSO2_TXN_KAFKA_TOPIC", "stoa.txn.wso2"))
	if err != nil {
		log.Fatalf("kafka init: %v", err)
	}
	defer publisher.Close()

	tenants := parseTenantMap(os.Getenv("WSO2_TENANT_MAP"), envOr("WSO2_DEFAULT_TENANT", "accounts-team"))

	lis, err := net.Listen("tcp", listen)
	if err != nil {
		log.Fatalf("listen %s: %v", listen, err)
	}
	srv := grpc.NewServer()
	coltracepb.RegisterTraceServiceServer(srv, &tapServer{forward: forward, publisher: publisher, tenants: tenants})

	go func() {
		<-ctx.Done()
		log.Printf("shutdown…")
		srv.GracefulStop()
	}()
	log.Printf("wso2-otel-tap OTLP/gRPC sur %s", listen)
	if err := srv.Serve(lis); err != nil {
		log.Fatalf("serve: %v", err)
	}
}
