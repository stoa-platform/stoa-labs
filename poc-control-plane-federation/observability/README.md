# Observabilité — otel-lgtm

Le PoC utilise l'image all-in-one **`grafana/otel-lgtm`** qui embarque :

- un **OpenTelemetry Collector** (réception OTLP gRPC `:4317` / HTTP `:4318`),
- **Tempo** (traces), **Loki** (logs), **Prometheus/Mimir** (métriques),
- **Grafana** (`:3000`) avec les datasources déjà provisionnées et corrélées.

> Décision Council #3 : all-in-one pour le PoC. **À écrire dans `EVIDENCE.md` : `otel-lgtm` est une image dev/démo, pas un design de production** (coupe court à l'objection comité).

Les 3 gateways émettent en OTLP natif vers cette image :

| Gateway | Mécanisme OTel | `service.name` |
|---------|----------------|----------------|
| WSO2 API Manager | tracer OTLP natif (`[apim.open_telemetry]`, exporteur **gRPC** → `otel-lgtm:4317`) — `scripts/setup-wso2-otel.sh` (goal A2 2026-07-03 : `url` + une entrée `properties` OBLIGATOIRES, vérité bytecode `OTLPTelemetry` ; config in-container, re-jouer après recreate) | `wso2` |
| Apache APISIX | plugin `opentelemetry` natif → `otel-lgtm:4318` | `apisix` |
| webMethods mock | SDK OTel Go (`otelhttp` + OTLP/HTTP) → `otel-lgtm:4318` | `webmethods-mock` |
| webMethods **réel** 10.15 | **pas d'OTel natif** (ADR-073) : Log Invocation globale → custom destination → `wm-trace-bridge` = **le Y** : (1) events→spans OTLP → `otel-lgtm:4318` ; (2) JSON brut → Redpanda `stoa.txn.webmethods` → Data Prepper → OpenSearch `txn-{tenant}` ; setup `scripts/wm-otel-setup.sh` | `webmethods` |

Le wM réel expose aussi `GET :5555/metrics` (Prometheus, anonyme en Docker), scrapé
via `observability/prometheus/prometheus-wm.yaml` (monté par `docker-compose.wm.yml`
par-dessus la config de l'image — remplacement du fichier ENTIER). **otel-lgtm doit
être (re)créé avec les deux `-f`** pour porter ce mount ; `scripts/up.sh` (base
seule) le recrée sans, silencieusement. Spans wM en différé ~10-40 s (dispatch
d'events), fenêtre native exacte via `externalCalls` — cf. ADR-073.

**Plan GOUVERNANCE/AUDIT — analytics transactionnelle par fournisseur (ADR-070, parité 3/3)** :
chaque runtime alimente aussi un `stoa.txn.{provider}` (Redpanda → Data Prepper →
OpenSearch `txn-{tenant}`), pivotable au plan traces par le `trace_id` :

| Provider | Source txn → Kafka | Pipeline Data Prepper |
|---|---|---|
| APISIX | plugin `kafka-logger` (projeté par labctl) → `stoa.txn.apisix` | `stoa-txn-apisix` |
| webMethods réel | `wm-trace-bridge` (events Log Invocation) → `stoa.txn.webmethods` | `stoa-txn-webmethods` |
| **WSO2** | **`wso2-otel-tap`** (goal A3) : tap OTLP/gRPC → **forward** spans à otel-lgtm (Tempo inchangé) **+** record `stoa.txn` par trace (trace_id natif du span) → `stoa.txn.wso2`. WSO2 pointe `remote_tracer.url=wso2-otel-tap:4317` (overlay analytics ; socle seul = otel-lgtm direct). Piège : WSO2 exporte en **gzip** (codec à enregistrer côté serveur gRPC) | `stoa-txn-wso2` |

**DoD Phase 1** : les 3 `service.name` apparaissent dans Grafana (Explore → Tempo/Prometheus).

`grafana/dashboards/federation-overview.json` (variable `$gateway`) est produit en **Phase 4** (T20) — pièce maîtresse de l'EVIDENCE : la corrélation `trace_id` d'un appel traversant les 3 runtimes hétérogènes jusqu'à Tempo.
