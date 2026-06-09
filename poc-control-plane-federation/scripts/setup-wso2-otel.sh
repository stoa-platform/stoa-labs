#!/usr/bin/env bash
# Phase 4 — wire WSO2's native OpenTelemetry exporter to the OTel collector so
# WSO2 joins APISIX + webMethods in the unified trace plane (Tempo).
#
# WSO2 4.5 ships opentelemetry-all and reads [apim.open_telemetry.remote_tracer]
# from deployment.toml (api-manager.xml.j2: <OpenTelemetry><RemoteTracer>). We
# append it in-container (idempotent) and restart — `docker restart` preserves
# the container fs, so the change survives. (A fresh `up`/recreate re-pulls the
# stock image, so re-run this script after a recreate.)
set -euo pipefail
C=poc-wso2am
TOML=/home/wso2carbon/wso2am-4.5.0/repository/conf/deployment.toml

if docker exec "$C" sh -c "grep -q 'apim.open_telemetry.remote_tracer' $TOML"; then
  echo "  WSO2 OTel already configured."
else
  docker exec "$C" sh -c "cat >> $TOML <<'EOF'

[apim.open_telemetry.remote_tracer]
enable = true
name = \"otlp\"
hostname = \"otel-lgtm\"
port = 4317
EOF"
  echo "  appended [apim.open_telemetry.remote_tracer] (otlp -> otel-lgtm:4317)"
  echo "  → restarting WSO2 to apply (≈3 min)…"
  docker restart "$C" >/dev/null
  echo "  restarted. Wait for healthy: docker compose -f docker-compose.poc.yml ps wso2am"
fi
