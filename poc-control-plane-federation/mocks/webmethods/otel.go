package main

import (
	"context"
	"os"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

// initOTel wires native OTLP/HTTP export of traces and metrics. When
// OTEL_EXPORTER_OTLP_ENDPOINT is empty the global no-op providers are kept,
// so the mock (and its tests) run fine without a collector.
//
// The endpoint is the host:port of an OTLP/HTTP collector, e.g.
// "otel-collector:4318" (no scheme). Insecure by design for a local PoC.
func initOTel(ctx context.Context, serviceName string) (func(context.Context) error, error) {
	endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if endpoint == "" {
		return func(context.Context) error { return nil }, nil
	}

	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName(serviceName),
			semconv.ServiceVersion("0.1.0"),
			// Labels the federation: every runtime tags itself so a single
			// Grafana dashboard can split by $gateway.
			semconv.DeploymentEnvironment("poc"),
		),
	)
	if err != nil {
		return nil, err
	}

	traceExp, err := otlptracehttp.New(ctx,
		otlptracehttp.WithEndpoint(endpoint),
		otlptracehttp.WithInsecure(),
	)
	if err != nil {
		return nil, err
	}
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(traceExp),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)

	metricExp, err := otlpmetrichttp.New(ctx,
		otlpmetrichttp.WithEndpoint(endpoint),
		otlpmetrichttp.WithInsecure(),
	)
	if err != nil {
		return nil, err
	}
	mp := metric.NewMeterProvider(
		metric.WithReader(metric.NewPeriodicReader(metricExp, metric.WithInterval(10*time.Second))),
		metric.WithResource(res),
	)
	otel.SetMeterProvider(mp)

	return func(ctx context.Context) error {
		_ = tp.Shutdown(ctx)
		return mp.Shutdown(ctx)
	}, nil
}
