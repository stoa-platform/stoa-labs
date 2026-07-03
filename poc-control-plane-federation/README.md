# PoC — Control Plane de Fédération (briques OSS)

Démonstrateur : **un control plane assemblé sur briques OSS fédère 3 gateways hétérogènes** (WSO2 API Manager, Apache APISIX, webMethods mock) — réponse au trou identifié par une étude « alternatives API Management & intégration » d'une **banque centrale (Eurosystème)**.

> ⚠️ Scaffold de **démonstration**, pas le produit. Lire [`POSITIONING.md`](./POSITIONING.md) (scaffold jetable vs valeur produit STOA) et [`HARD-CRITERIA-MAP.md`](./HARD-CRITERIA-MAP.md) (ce que ce jet prouve vs critères durs, dont le Reverse Invoke). Cadre stratégique : [`../adr/adr-067-reuse-first-owned-portable-layer.md`](../adr/adr-067-reuse-first-owned-portable-layer.md).
>
> Tout est **synthétique**, local, éphémère. Zéro SaaS, zéro donnée réelle, zéro secret en clair.

## État

| Phase | Contenu | État |
|-------|---------|------|
| 0 | Plan + cadrage ([`PLAN.md`](./PLAN.md)) | ✅ GO conditionnel Council |
| 1 | Socle OSS (docker-compose, 3 gateways + identité + obs) | ✅ **validé live** (`up.sh` + `smoke-test.sh`) |
| 2 | `labctl` + Define Once (1 OpenAPI → 3 gateways) | ✅ **validé live** (`demo.sh` : publish + catalogue + subscribe + appels authentifiés 200×3) |
| **3** | **Identité Oracle-master (Dex → Keycloak → 3 gateways)** | ✅ **validé live** (`setup-identity.sh` + `phase3-identity-demo.sh`) |
| 4 | Evidence report + observabilité | ✅ [`EVIDENCE.md`](./EVIDENCE.md) (preuves live) + dashboard Grafana `stoa-fed-overview` (OTel : APISIX + webMethods + WSO2 — **3/3**, goal A2 2026-07-03) |

### Phase 3 — un token Keycloak (fédéré depuis Oracle/Dex) validé par les 3 gateways

```bash
./scripts/setup-identity.sh         # enregistre le KeyCloak Key Manager (+ APISIX oidc + prérequis KC)
docker restart poc-wso2am           # OBLIGATOIRE : WSO2 charge les Key Managers au DÉMARRAGE (~3 min)
./scripts/setup-identity.sh         # re-run idempotent : le map-keys réussit (KM désormais chargé)
./scripts/phase3-identity-demo.sh   # alice@oracle (via Dex) → 1 token → 200 sur WSO2 + APISIX + webMethods
```

> Le restart + re-run est requis car WSO2 ne charge les Key Managers qu'au démarrage ; `setup-identity.sh` est idempotent (re-jouable sans risque).

| Gateway | Validation du token Keycloak | Preuve |
|---------|------------------------------|--------|
| WSO2 (commercial) | Keycloak enregistré comme **Key Manager** (connecteur `KeyCloak`, self-validation JWT, claim `azp`) | 200 |
| APISIX (OSS) | plugin **`openid-connect`** (bearer-only, JWKS) | 200 |
| webMethods (mock legacy) | **go-oidc** JWKS sur le data-plane | 200 |

Oracle reste master (login `alice@bc.example` via Dex), Keycloak émet le token, les 3 runtimes hétérogènes le consomment. Sans token → 401 partout. Détail WSO2 : le KM doit être (re)chargé au **démarrage** de WSO2 — `setup-identity.sh` enregistre le KM, puis `docker restart poc-wso2am`, puis re-run pour le mapping (le script est idempotent).

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
| Observabilité | **Grafana otel-lgtm** (Collector + Tempo/Loki/Prometheus) | 1 dashboard, OTLP des **3/3** gateways (APISIX + webMethods + WSO2 — `setup-wso2-otel.sh`, goal A2) |
| Backend | **Microcks** + MongoDB | backend synthétique depuis OpenAPI |

Détail et numéros de tickets : [`PLAN.md`](./PLAN.md) §5.

## Tests

```bash
( cd mocks/webmethods && go test ./... )   # mock webMethods (unitaire)
```
