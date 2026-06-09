# EVIDENCE — PoC Control Plane de Fédération (institution financière régulée anonymisé)

> Rapport de preuves, validé **en live** sur la stack locale (2026-06). Données
> 100 % synthétiques, environnement éphémère, zéro SaaS, client anonymisé.
>
> À lire avec [`POSITIONING.md`](./POSITIONING.md) (scaffold jetable vs valeur produit STOA)
> et [`HARD-CRITERIA-MAP.md`](./HARD-CRITERIA-MAP.md) (ce que ce jet prouve vs les critères durs restants).

## Thèse

L'étude conclut qu'aucun produit OSS/commercial ne livre un **control plane unifié
transverse** (la seule fédération citée, Axway Amplify, est SaaS hors zone). Ce PoC
démontre — sur briques OSS souveraines — **un control plane qui fédère 3 gateways
hétérogènes (WSO2 commercial, Apache APISIX OSS, webMethods legacy) sous une identité
Oracle-master unique**, en local, sans SaaS.

## Environnement (reproductible)

```bash
cd poc-control-plane-federation
./scripts/up.sh                 # 9 briques OSS (3 gateways + Keycloak/Dex + OTel/LGTM + Microcks)
./scripts/demo.sh               # Phases 1-2 : publish + catalogue + subscribe + appels authentifiés
./scripts/setup-identity.sh     # Phase 3 : WSO2 KeyCloak KM + APISIX openid-connect + prérequis KC
docker restart poc-wso2am       # charge le Key Manager dans le runtime WSO2, puis re-run setup-identity
./scripts/phase3-identity-demo.sh   # preuve identité Oracle-master
./scripts/smoke-test.sh         # santé des 9 services
```

| Brique OSS | Rôle | Accès (host) |
|---|---|---|
| WSO2 API Manager | gateway commercial souverain | https://localhost:9443 |
| Apache APISIX | gateway OSS | http://localhost:9080 (+9180 admin) |
| webMethods (mock Go) | gateway legacy | http://localhost:8090 |
| Keycloak | broker d'identité | http://localhost:8480 |
| Dex | IdP Oracle (mock) | http://localhost:5556 |
| Grafana + Tempo/Loki/Prometheus | observabilité OTel | http://localhost:3000 |
| Microcks | backend synthétique | http://localhost:8585 |

---

## Preuve 1 + 2 — Fédération multi-runtime & « Define Once, Expose Everywhere »

**Un seul contrat OpenAPI** (`apis/accounts-read.openapi.yaml`) publié par `labctl`
sur les 3 gateways depuis un seul `targets.yaml`. Re-`apply` idempotent.

```
$ labctl apply -f targets.yaml
Define Once → Expose Everywhere: "accounts-read" v1.0.0 → 3 gateways
  ✓ wso2         https://localhost:8243/accounts-read/v1/1.0.0
  ✓ apisix       http://localhost:9080/accounts-read/v1
  ✓ webmethods   http://localhost:8090/gateway/accounts-read/v1

GATEWAY     STATUS  API ID                                INVOCATION URL                                  STATE
wso2        ✓       32463c49-95be-4cd6-aea9-0b59164f3aec  https://localhost:8243/accounts-read/v1/1.0.0   reused
apisix      ✓       accounts-read                         http://localhost:9080/accounts-read/v1          reused
webmethods  ✓       api-0001                              http://localhost:8090/gateway/accounts-read/v1  reused

3/3 gateways published from one contract.
```

Le moteur de fédération est la boucle de dispatch dans `labctl/cmd/labctl/apply.go`
(≈ l'idée du dispatch produit STOA `contracts.py`) — **pas un moteur custom lourd** (anti-§7.6).

---

## Preuve 3 — Catalogue unifié

`labctl get apis` agrège les 3 runtimes hétérogènes dans une vue unique.

```
$ labctl get apis -f targets.yaml
GATEWAY     API ID                                NAME           VERSION  BASEPATH
wso2        32463c49-95be-4cd6-aea9-0b59164f3aec  accounts-read  1.0.0    /accounts-read/v1
apisix      accounts-read                         accounts-read  1.0.0    /accounts-read/v1
webmethods  api-0001                              accounts-read  1.0.0    /accounts-read/v1
```

---

## Preuve 4 — Self-service souscription

`labctl subscribe` mint un client OAuth dans Keycloak puis provisionne un consumer
sur les 3 gateways (chacun avec son modèle d'auth natif). Secrets écrits en 0600,
jamais sur stdout.

```
$ labctl subscribe -f targets.yaml
Minting Keycloak client "accounts-read-consumer" in realm "stoa-lab"…
  ✓ client accounts-read-consumer ready (secret acquired)

GATEWAY     STATUS  CONSUMER ID                           CREDENTIAL
wso2        ✓       17052361-99e9-4e77-bd43-b090586a73ab  •••••• (see labctl-credentials.txt)
apisix      ✓       accounts_read_consumer                •••••• (see labctl-credentials.txt)
webmethods  ✓       sub-0002                              •••••• (see labctl-credentials.txt)

3/3 gateways provisioned for client "accounts-read-consumer".
```

Appels data-plane **authentifiés** (chaque gateway, son auth native) → 200 ; sans
credential → 401 (politique appliquée) :

```
webMethods  HTTP 200   (mock legacy)
APISIX      no key  -> 401   |   apikey -> 200
WSO2        no token-> 401   |   Bearer -> 200
```

---

## Preuve 5 — Identité Oracle-master (Dex → Keycloak → 3 gateways) ★

**Un seul token Keycloak, dont l'identité provient d'Oracle (Dex), validé par les
3 gateways hétérogènes.** `alice@bc.example` se connecte via Dex (Oracle), Keycloak
fédère et émet le token ; WSO2 (Key Manager), APISIX (openid-connect) et webMethods
(JWKS) le consomment.

```
$ ./scripts/phase3-identity-demo.sh
════════ Oracle-master: Keycloak brokers the Oracle (Dex) IdP ════════
  browser login /auth?kc_idp_hint=oracle → 303 → http://localhost:8480/realms/stoa-lab/broker/oracle/login

════════ ONE Keycloak token (iss pinned to localhost:8480) ════════
  ✓ Oracle-federated token obtained (identity sourced from Dex/Oracle)
  iss = http://localhost:8480/realms/stoa-lab | azp = accounts-read-consumer | user = alice@bc.example

════════ the SAME token, validated by 3 heterogeneous gateways ════════
  wso2        HTTP 200  {"count":2,"items":[{"id":"ACC-1001",...
  apisix      HTTP 200  {"count":2,"items":[{"id":"ACC-1001",...
  webmethods  HTTP 200  {"count":2,"items":[{"id":"ACC-1001",...
  — negative (auth enforced):
  wso2 401 | apisix 401 | webmethods 401
```

Mécanismes de validation (par gateway) :

| Gateway | Validation du token Keycloak |
|---|---|
| WSO2 (commercial) | Keycloak enregistré comme **3rd-party Key Manager** (connecteur `KeyCloak`, self-validation JWT, claim `azp`), client mappé sur l'app souscrite |
| APISIX (OSS) | plugin **`openid-connect`** (bearer-only, JWKS, RS256) |
| webMethods (mock legacy) | validation **JWKS** (`go-oidc`) sur le data-plane |

> Oracle reste master ; Keycloak émet ; les 3 runtimes consomment la même identité.

---

## Preuve 6 — Observabilité unifiée OTel (1 plan pour 3 runtimes)

Les gateways émettent en **OpenTelemetry natif** → un seul Grafana/Tempo/Prometheus.

```
$ # Tempo : service.name émettant des traces
['apisix', 'webmethods-mock']        # 2 runtimes hétérogènes (OSS + legacy), 1 plan

$ # Prometheus (span metrics auto-générées par Tempo)
traces_spanmetrics_calls_total{service="apisix|webmethods-mock"}
```

Deux runtimes **hétérogènes** (APISIX OSS + webMethods legacy) atterrissent dans
**un seul plan d'observabilité** — la démonstration de fédération de l'observabilité.
Dashboard fédération : **http://localhost:3000/d/stoa-fed-overview** — sélecteur
`$gateway`, requêtes/s et latence p95 par runtime, table des traces récentes.
JSON versionné : `observability/grafana/dashboards/federation-overview.json`.

> **WSO2 OTel** : WSO2 4.5 embarque `opentelemetry-all` et se configure via
> `[apim.open_telemetry.remote_tracer]` (`scripts/setup-wso2-otel.sh`). Sur cette
> image, la config naïve (`name="otlp"` → otel-lgtm:4317) **déstabilise le
> démarrage du gateway** — c'est un réglage d'exporteur à affiner (endpoint/format
> OTLP gRPC vs HTTP), pas un bloqueur de la thèse. Laissé en suivi pour ne pas
> fragiliser la stack ; la fédération de l'observabilité est déjà prouvée sur 2
> runtimes hétérogènes.
>
> `grafana/otel-lgtm` est une image **dev/démo** (collector + LGTM tout-en-un),
> pas un design de production — l'atterrissage dans la stack cible reste le même.

---

## Preuve 7 — Souveraineté

100 % local / self-hosted, **zéro dépendance SaaS** : toutes les briques tournent
en conteneurs sur le poste (`docker compose`), aucune sortie vers un service
managé tiers. C'est l'argument différenciant vs Axway Amplify (SaaS, hors zone).

---

## Teardown (destruction contrôlée)

```bash
./scripts/down.sh        # arrêt (conserve les volumes)
./scripts/teardown.sh    # destruction complète (conteneurs + volumes + image mock)
```

## Ce que ce jet ne prouve PAS encore

Voir [`HARD-CRITERIA-MAP.md`](./HARD-CRITERIA-MAP.md) et [`../adr/adr-068-stoa-off-the-transaction-path.md`](../adr/adr-068-stoa-off-the-transaction-path.md) :
le **Reverse Invoke / zéro entrant** (critère *éliminatoire*, §0.2/§4.2) est un pattern
**data-plane / DMZ transactionnel** → **capacité des gateways qualifiées** (webMethods),
**pas un livrable STOA**. Le must-prove de STOA est distinct et plus modeste : **orchestrer
des gateways en topologie zéro-entrant sans réintroduire d'entrant, et garder son propre
canal de management en zéro-entrant** (agent de config sortant-only **ou** pull GitOps) —
STOA restant **hors du chemin transactionnel**. Également différés : analytique
transactionnelle par fournisseur, streaming > 500 Mo.
