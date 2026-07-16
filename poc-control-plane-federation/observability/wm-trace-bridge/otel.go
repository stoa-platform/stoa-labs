package main

import (
	"context"
	"os"
	"strings"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

// initOTel câble l'export OTLP/HTTP des traces (même pattern que
// mocks/webmethods/otel.go, traces seules : le bridge ne produit pas de
// métriques). Sans OTEL_EXPORTER_OTLP_ENDPOINT, providers no-op : le bridge
// (et ses tests) tournent sans collecteur.
func initOTel(ctx context.Context, serviceName string) (func(context.Context) error, error) {
	endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if endpoint == "" {
		return func(context.Context) error { return nil }, nil
	}

	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName(serviceName),
			semconv.ServiceVersion("0.1.0"),
			// Même tag fédération que les autres runtimes : le dashboard
			// Grafana splitte par $gateway via service.name.
			semconv.DeploymentEnvironment("poc"),
		),
	)
	if err != nil {
		return nil, err
	}

	// Deux formes acceptées : la convention host:port du repo (otel-lgtm:4318)
	// et la forme URL standard OTel (http://otel-lgtm:4318) — WithEndpoint sur
	// une URL fabriquerait http://http://… et perdrait 100 % des exports.
	var opts []otlptracehttp.Option
	if strings.Contains(endpoint, "://") {
		opts = append(opts, otlptracehttp.WithEndpointURL(endpoint))
	} else {
		opts = append(opts, otlptracehttp.WithEndpoint(endpoint), otlptracehttp.WithInsecure())
	}
	traceExp, err := otlptracehttp.New(ctx, opts...)
	if err != nil {
		return nil, err
	}
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(traceExp),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)

	return tp.Shutdown, nil
}
