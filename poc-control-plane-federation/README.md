# PoC — Control Plane de Fédération (briques OSS)

Démonstrateur : **un control plane assemblé sur briques OSS fédère 3 gateways hétérogènes** (WSO2 API Manager, Apache APISIX, webMethods mock) — réponse au trou identifié par une étude « alternatives API Management & intégration » d'une **institution financière régulée (anonymisé)**.

> ⚠️ Scaffold de **démonstration**, pas le produit. Lire [`POSITIONING.md`](./POSITIONING.md) (scaffold jetable vs valeur produit STOA) et [`HARD-CRITERIA-MAP.md`](./HARD-CRITERIA-MAP.md) (ce que ce jet prouve vs critères durs, dont le Reverse Invoke). Cadre stratégique : [`../adr/adr-067-reuse-first-owned-portable-layer.md`](../adr/adr-067-reuse-first-owned-portable-layer.md).
>
> Tout est **synthétique**, local, éphémère. Zéro SaaS, zéro donnée réelle, zéro secret en clair.

## État

| Phase | Contenu | État |
|-------|---------|------|
| 0 | Plan + cadrage ([`PLAN.md`](./PLAN.md)) | ✅ GO conditionnel Council |
| **1** | **Socle OSS (docker-compose, 3 gateways + identité + obs)** | **🚧 en cours** |
| 2 | `labctl` + Define Once (1 OpenAPI → 3 gateways) | ⏳ |
| 3 | Self-service Backstage + identité Oracle-master | ⏳ |
| 4 | Evidence report (corrélation `trace_id` 3 gateways) | ⏳ |

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
