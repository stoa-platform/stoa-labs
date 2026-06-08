# PoC — Control Plane de Fédération (briques OSS)

Démonstrateur : **un control plane assemblé sur briques OSS fédère 3 gateways hétérogènes** (WSO2 API Manager, Apache APISIX, webMethods mock) — réponse au trou identifié par une étude « alternatives API Management & intégration » d'une **institution financière régulée (anonymisé)**.

> ⚠️ Scaffold de **démonstration**, pas le produit. Lire [`POSITIONING.md`](./POSITIONING.md) (scaffold jetable vs valeur produit STOA) et [`HARD-CRITERIA-MAP.md`](./HARD-CRITERIA-MAP.md) (ce que ce jet prouve vs critères durs, dont le Reverse Invoke). Cadre stratégique : [`../adr/adr-067-reuse-first-owned-portable-layer.md`](../adr/adr-067-reuse-first-owned-portable-layer.md).
>
> Tout est **synthétique**, local, éphémère. Zéro SaaS, zéro donnée réelle, zéro secret en clair.

## État

| Phase | Contenu | État |
|-------|---------|------|
| 0 | Plan + cadrage ([`PLAN.md`](./PLAN.md)) | ✅ GO conditionnel Council |
| 1 | Socle OSS (docker-compose, 3 gateways + identité + obs) | ✅ écrit ; DoD live = `up` sur ton Docker |
| **2** | **`labctl` + Define Once (1 OpenAPI → 3 gateways)** | **🚧 implémenté, 34 tests verts ; DoD live en attente du stack** |
| 3 | Self-service Backstage + identité Oracle-master | ⏳ |
| 4 | Evidence report (corrélation `trace_id` 3 gateways) | ⏳ |

## labctl — l'orchestrateur de fédération (Phase 2)

`labctl` est le scaffold mince qui prouve **« Define Once, Expose Everywhere »** : un
seul contrat OpenAPI ([`apis/accounts-read.openapi.yaml`](./apis/accounts-read.openapi.yaml))
publié sur 3 runtimes hétérogènes depuis un seul [`targets.yaml`](./targets.yaml).

```bash
( cd labctl && go build -o /tmp/labctl . )

/tmp/labctl apply     -f targets.yaml   # publie le contrat sur WSO2 + APISIX + webMethods
/tmp/labctl get apis  -f targets.yaml   # catalogue unifié des 3 gateways
/tmp/labctl subscribe -f targets.yaml   # client Keycloak → consumer sur les 3 gateways
```

Adapters : `internal/adapter/{wso2,apisix,webmethods}` (un par runtime, derrière une
interface commune `adapter.Adapter`). Le « moteur de fédération » est la boucle de
dispatch dans `cmd/labctl/apply.go`. Tests : `( cd labctl && go test ./... )`.

## Quickstart (Phase 1)

Prérequis : Docker + Docker Compose. Profil light, mais prévoir ~16 Go RAM (WSO2 est lourd).

```bash
cd poc-control-plane-federation
cp .env.example .env          # vérifier/ajuster les tags d'images
./scripts/up.sh               # build le mock + up + attend les healthchecks
./scripts/smoke-test.sh       # DoD Phase 1 : les 3 gateways + identité + obs répondent
./scripts/down.sh             # arrêt (volumes conservés)
./scripts/teardown.sh         # destruction contrôlée (volumes + image mock)
```

## Composants (briques OSS)

| Couche | Brique | Rôle |
|--------|--------|------|
| Gateway #1 | **WSO2 API Manager** (réel) | gateway « neuf » souverain |
| Gateway #2 | **Apache APISIX** (réel) + etcd | gateway OSS additionnel |
| Gateway #3 | **webMethods mock** (`mocks/webmethods`, Go) | legacy commercial stand-in |
| Identité | **Keycloak** (broker) + **Dex** (mock Oracle) | Oracle master → Keycloak émet, 3 gateways consomment |
| Observabilité | **Grafana otel-lgtm** (Collector + Tempo/Loki/Prometheus) | 1 dashboard, OTLP des 3 gateways |
| Backend | **Microcks** + MongoDB | backend synthétique depuis OpenAPI |

Détail et numéros de tickets : [`PLAN.md`](./PLAN.md) §5.

## Tests

```bash
( cd mocks/webmethods && go test ./... )   # mock webMethods (unitaire)
```
