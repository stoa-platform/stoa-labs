# Observabilité — otel-lgtm

Le PoC utilise l'image all-in-one **`grafana/otel-lgtm`** qui embarque :

- un **OpenTelemetry Collector** (réception OTLP gRPC `:4317` / HTTP `:4318`),
- **Tempo** (traces), **Loki** (logs), **Prometheus/Mimir** (métriques),
- **Grafana** (`:3000`) avec les datasources déjà provisionnées et corrélées.

> Décision Council #3 : all-in-one pour le PoC. **À écrire dans `EVIDENCE.md` : `otel-lgtm` est une image dev/démo, pas un design de production** (coupe court à l'objection comité).

Les 3 gateways émettent en OTLP natif vers cette image :

| Gateway | Mécanisme OTel | `service.name` |
|---------|----------------|----------------|
| WSO2 API Manager | config OTel WSO2 → OTLP | `wso2` (à câbler Phase 1/2) |
| Apache APISIX | plugin `opentelemetry` natif → `otel-lgtm:4318` | `apisix` |
| webMethods mock | SDK OTel Go (`otelhttp` + OTLP/HTTP) → `otel-lgtm:4318` | `webmethods-mock` |

**DoD Phase 1** : les 3 `service.name` apparaissent dans Grafana (Explore → Tempo/Prometheus).

`grafana/dashboards/federation-overview.json` (variable `$gateway`) est produit en **Phase 4** (T20) — pièce maîtresse de l'EVIDENCE : la corrélation `trace_id` d'un appel traversant les 3 runtimes hétérogènes jusqu'à Tempo.
