#!/usr/bin/env bash
# Phase 4 / goal A2 — wire WSO2's native OpenTelemetry exporter to the OTel
# collector so WSO2 joins APISIX + webMethods in the unified trace plane (Tempo).
# RÉSOLU (2026-07-03) : service.name=wso2 visible dans Tempo, spans complets
# (CORS/Key_Validation/Throttle/Backend_Latency/...), stack stable.
#
# POURQUOI la config naïve échouait (vérité BYTECODE, OTLPTelemetry.class de
# org.wso2.carbon.apimgt.tracing_9.31.86, wso2am:4.5.0) :
#   1. init() ne lit QUE `OpenTelemetry.RemoteTracer.Url` — jamais HostName/Port
#      (ces clés servent aux tracers jaeger/zipkin). hostname+port => url null.
#   2. init() EXIGE en plus une entrée Properties non vide (design "api-key New
#      Relic") : StringUtils.isNotEmpty(url) && isNotEmpty(headerValue), sinon
#      branche erreur => le champ openTelemetry reste NULL => NPE en aval au
#      démarrage de la gateway (9443/8243 refused = la "déstabilisation" vue).
#   3. L'exporteur est OtlpGrpcSpanExporter (gRPC => port 4317) et setEndpoint
#      (opentelemetry-java 1.11) exige un scheme http:// ou https://.
#   4. getTracerProviderResource merge service.name(caller) PUIS les
#      ResourceAttributes de la config (le dernier merge gagne) => on force
#      service.name=wso2 proprement via [[apim.open_telemetry.resource_attributes]].
#
# Persistance : la config est appendée DANS le conteneur (survit à un
# `docker restart`, PAS à un recreate — re-jouer ce script après un `up`
# --force-recreate, comme wm-otel-setup.sh).
set -euo pipefail
C=poc-wso2am
TOML=/home/wso2carbon/wso2am-4.5.0/repository/conf/deployment.toml

if docker exec "$C" sh -c "grep -q 'apim.open_telemetry' $TOML"; then
  echo "  WSO2 OTel already configured."
  exit 0
fi

docker exec "$C" sh -c "cp $TOML $TOML.pre-otel.bak && cat >> $TOML <<'EOF'

# goal A2: OTel OTLP -> otel-lgtm (Tempo). Vérité bytecode OTLPTelemetry :
# - SEUL 'url' est lu (jamais hostname/port) ; exporteur gRPC => scheme http:// + :4317
# - une entrée properties est OBLIGATOIRE (isNotEmpty(headerValue), design api-key NR)
# - resource_attributes service.name écrase le nom par défaut (dernier merge gagne)
[apim.open_telemetry]
remote_tracer.enable = true
remote_tracer.name = \"otlp\"
remote_tracer.url = \"http://otel-lgtm:4317\"

[[apim.open_telemetry.remote_tracer.properties]]
name = \"x-stoa-poc\"
value = \"1\"

[[apim.open_telemetry.resource_attributes]]
name = \"service.name\"
value = \"wso2\"
EOF"
echo "  appended [apim.open_telemetry] (otlp gRPC -> http://otel-lgtm:4317, service.name=wso2)"
echo "  → restarting WSO2 to apply (~2-3 min; le Key Manager Keycloak se recharge au boot)…"
docker restart "$C" >/dev/null
echo "  restarted. Vérifier :"
echo "    docker exec poc-otel-lgtm curl -s 'http://localhost:3200/api/search/tag/service.name/values'"
echo "    → doit lister \"wso2\" après un appel data-plane :8243 (même un 401 trace)."
