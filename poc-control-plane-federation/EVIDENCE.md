# EVIDENCE — PoC Control Plane de Fédération (banque centrale Eurosystème)

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
| Grafana + Tempo/Loki/Prometheus | observabilité OTel (ops/SRE) | http://localhost:3000 |
| OpenSearch + Dashboards | analytics transactionnelle / audit (ADR-070) | https://localhost:9201 · http://localhost:5601 |
| Redpanda + Data Prepper | bus + collecteur normalisant/redactant (ADR-070) | (in-network) |
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

## 2026-06-11 — Data-plane bout-en-bout : 3 gateways réelles, auth imposée

**Le mock webMethods sort de la preuve** : la cible est désormais le **vrai**
webMethods API Gateway (`softwareag/apigateway-trial:10.15`, conteneur
`poc-webmethods-real`, data-plane `http://localhost:5555/gateway/accounts-read/1.0.0/...`).
`scripts/phase3-identity-demo.sh` est mis à jour en conséquence (`:8090` → `:5555`).

**Chemin du token (inchangé)** : `alice@bc.example` se connecte chez Dex (Oracle),
Keycloak (realm `stoa-lab`) fédère via le broker et émet un JWT RS256 avec
`iss=http://localhost:8480/realms/stoa-lab`, `azp=accounts-read-consumer` — le
**même** token est présenté aux 3 data-planes.

**Ce qui a été corrigé aujourd'hui** :

- **WSO2** : le Key Manager Keycloak est chargé dans le runtime (restart du
  conteneur) — la validation self-JWT (claim `azp`) est effective ;
- **APISIX** : route réécrite vers le backend Microcks `Accounts+Read+API`
  (`proxy-rewrite`) + plugin `openid-connect` posé par `setup-identity.sh` ;
- **webMethods réel** : auth entrante **projetée par le control plane** —
  `labctl apply` crée l'alias auth-server `KeycloakStoaLab` (issuer
  `localhost:8480`, JWKS `keycloak:8080` — deux horizons réseau) et attache
  l'action IAM « Identify & Authorize » (`jwtClaims`, `allowAnonymous=false`)
  au stage IAM de la policy de l'API `accounts-read` (cf. `targets.yaml`
  `inboundAuth`, adapter `labctl/internal/adapter/webmethods/inboundauth.go`).

**Matrice mesurée** (token frais TTL ~5 min ; « sans token » mesuré **deux fois**
pour écarter tout effet de cache — résultats identiques) :

```
                      avec token        sans token (×2)   token forgé
wso2       :8243      200 {"count":2,…  401               —
apisix     :9080      200 {"count":2,…  200  ✗ RÉGRESSION —
webmethods :5555      200 {"count":2,…  401               401 "Unauthorized application request"
```

- **webMethods réel** : ✓ 200 + corps Microcks avec le token Oracle-master,
  **401 sans token et 401 avec un JWT forgé** (signature non vérifiable au JWKS)
  — l'auth entrante imposée par labctl est effective.
- **WSO2** : ✓ 200 / 401 (`900902 Missing Credentials`).
- **APISIX** : ✗ **régression constatée au moment de la preuve finale** — un
  re-apply `labctl` (routes réécrites le 2026-06-11 10:55:58) a **écrasé le
  plugin `openid-connect`** posé par `setup-identity.sh` (limitation connue de
  l'adapter : il ne préserve pas les plugins externes au re-apply). Remédiation
  en une commande : rejouer l'étape 3/3 de `./scripts/setup-identity.sh`
  (PUT des routes `accounts-read-0/1` avec `openid-connect`), puis corriger
  l'adapter APISIX pour préserver/projeter l'auth entrante (même modèle
  `inboundAuth` que webMethods). Non rejoué dans cette session (modification
  d'APISIX non autorisée ici) — la matrice ci-dessus est l'état **mesuré**, pas
  l'état visé.

> Bilan : l'auth entrante est **prouvée sur le webMethods réel** (le runtime le
> plus legacy) et sur WSO2 ; sur APISIX elle est posée par `setup-identity.sh`
> mais pas encore **possédée** par le control plane — c'est l'écart restant
> (projeter `inboundAuth` côté APISIX comme côté webMethods).

**Dénouement (même jour) — l'écart est fermé structurellement** : le modèle
`inboundAuth` est porté à l'adapter APISIX. Le target `apisix` de `targets.yaml`
déclare `inboundAuth.discoveryUrl`
(`http://keycloak:8080/realms/stoa-lab/.well-known/openid-configuration`) et
l'adapter (`labctl/internal/adapter/apisix/inboundauth.go`, miroir de
`webmethods/inboundauth.go`) projette le plugin **`openid-connect`** prouvé
(bearer-only, `use_jwks`, RS256) sur **chaque** PUT de route — par `Publish` au
apply **et** par le re-PUT wholesale de `CreateConsumer` au subscribe. La
régression ci-dessus ne peut plus se produire : l'auth entrante n'est plus un
état posé à la main que l'apply écrase, c'est l'apply lui-même qui la porte.
Validation fail-closed des deux côtés (`load.go` au parse, `New()` à la
construction) ; sans bloc `inboundAuth`, comportement strictement inchangé.

**Convergence rejouée** : `labctl apply -f targets.yaml` ×2 → 3/3 gateways
`reused`, `openid-connect` présent sur `accounts-read-0` **et** `-1` (GET admin :
discovery conforme au manifeste, `proxy-rewrite` toujours vers
`/rest/Accounts+Read+API/1.0.0`), 6 routes au total (zéro doublon), et côté
webMethods toujours **1 alias / 1 action / 1 stage IAM** — l'idempotence tient
sur les deux runtimes.

**Matrice finale mesurée** (token frais à chaque passe ; « sans token » mesuré
**deux fois**, résultats identiques avant et après le re-apply) :

```
                      avec token        sans token (×2)   token forgé
wso2       :8243      200 {"count":2,…  401               —
apisix     :9080      200 {"count":2,…  401  ✓ corrigé    —
webmethods :5555      200 {"count":2,…  401               401
```

`./scripts/phase3-identity-demo.sh` rejoue désormais la preuve de bout en bout :
token Oracle-master (`alice@bc.example` via Dex, `azp=accounts-read-consumer`)
→ **200×3** avec le token, **401×3** sans.

> La régression a eu lieu — elle est documentée ci-dessus telle que mesurée.
> Le fix n'est pas un re-patch manuel mais un transfert de possession : les
> **trois** runtimes valident maintenant la même identité via une auth entrante
> déclarée au manifeste et projetée par `labctl apply`.

---

## Preuve 5 bis — Barrière OAuth2 webMethods : 3/4 leviers opposables (gap documenté)

Sur le **webMethods réel** (`apigateway-trial:10.15`), le control plane projette
une barrière OAuth2 complète. **3 des 4 leviers** sont **opposables** (mesurés
adversarialement) ; le 4ᵉ (**audience**) est **câblé dans `labctl`** mais **non
opposable sur le trial 10.15** — gap honnête, mécanisme prêt pour un build capable.

| Levier (claim) | État | Preuve |
|---|---|---|
| **Signature** (JWKS RS256) | ✅ opposable | token forgé / signature octet-altérée → **401** ; token valide → **200** |
| **azp** (application) | ✅ opposable | identifier `azp == accounts-read-consumer` mappé sur la strategy ; mauvais `azp` → refusé |
| **scope** | ✅ opposable | scope-mapping `requiredAuthScopes` lié à l'API ; token sans scope → **403/401** (chemin strict `oAuth2Token`) |
| **audience** (`aud`) | ⚠️ **câblé, non opposable sur 10.15 trial** | cf. ci-dessous — 2 leviers prouvent le diagnostic |

**Pourquoi l'audience n'est pas opposable sur ce runtime** — prouvé par **deux
leviers indépendants** :

1. **Introspection distante inerte** — l'alias bascule de la validation JWKS
   **OFFLINE** (`localIntrospectionConfig`, qui **ne vérifie jamais `aud`**) vers
   l'**introspection RFC 7662 distante** (`remoteIntrospectionConfig`, où le
   resource-server checke `aud` contre `strategy.audience`). Le mécanisme est
   **entièrement câblé** dans l'adapter
   (`labctl/internal/adapter/webmethods/inboundauth.go` : `introspectionEndpoint`,
   `introspectionUser` requis par l'`AuthServerAliasValidator` 10.15) — mais sur
   l'image **trial**, le chemin reste **inerte** (l'`aud` n'est pas opposé).
2. **`oAuth2Token`** — l'action IAM passe de `jwtClaims` (signature seule) à
   **`identificationType=oAuth2Token`** (chemin strict : `applicationLookup=strict`)
   qui **impose scope + application**, mais **pas l'audience** sur ce runtime.
   (Passage validé **live** ; cohérent avec la strategy `OAUTH2`, scope toujours
   imposé, **aucune régression** vs le mode `openIdClaims` antérieur.)

> **Bilan** : signature/azp/scope sont **prouvés opposables** ; l'audience est
> **diagnostiquée non opposable sur le trial 10.15** et son enforcement est
> **câblé** dans `labctl` (introspection distante) — un build capable l'active sans
> re-design. Gap documenté, pas masqué.

---

## Preuve 6 — Observabilité fédérée OTel + corrélation trace ↔ transaction ★

L'observabilité est portée par **deux plans complémentaires** (ADR-070), reliés par
un **pivot unique : le `trace_id` W3C**.

- **Plan OPS/SRE temps réel** — OTel/LGTM (`grafana/otel-lgtm`, conteneur
  `poc-otel-lgtm`) : Grafana (http://localhost:3000) + **Tempo** (traces) + **Loki**
  (logs) + **Prometheus** (span-metrics auto-générées). APISIX et webMethods émettent
  en **OpenTelemetry natif** (OTLP 4317/4318) → un seul plan transverse.
- **Plan GOUVERNANCE/AUDIT** — OpenSearch (analytics transactionnelle, ADR-070, cf.
  section suivante) : un document par transaction, redacté, isolé par tenant.

```
$ # Tempo : service.name émettant des traces (goal A2, 2026-07-03 : WSO2 rejoint)
['apisix', 'webmethods-mock', 'wso2']   # 3/3 runtimes hétérogènes, 1 plan

$ # Prometheus (span metrics auto-générées par Tempo)
traces_spanmetrics_calls_total{service="apisix|webmethods-mock|wso2"}
```

### Dashboard de fédération (versionné + provisionné live)

Dashboard **« STOA — Fédération (OTel + Transactions) »** — uid `stoa-fed-otel-txn`,
**http://localhost:3000/d/stoa-fed-otel-txn** (6 panneaux : RPS/latence p95 par
runtime depuis Prometheus/Tempo + **table des transactions OpenSearch**). Grafana est
ouvert (pas d'auth) ; il est provisionné **et** versionné, des deux côtés :

- **fichiers reproductibles** : `observability/grafana/provisioning/` (datasource
  `OpenSearch-Txn`, dashboard `dashboards/federation-otel-transactions.json`,
  correlation `correlations/tempo-to-opensearch.yaml`) ;
- **chemin live/idempotent** : `observability/grafana/provisioning/apply.sh` (re-PUT
  par uid si présent, POST sinon ; la correlation Tempo→OpenSearch passe par `apply.sh`
  car la datasource source Tempo est read-only — non provisionnable par fichier).

### Le pivot trace ↔ transaction (validé empiriquement)

Le schéma `stoa.txn` porte un champ `trace_id`. Un appel data-plane réel produit
**le même `trace_id` W3C dans les deux plans** → on pivote de l'un à l'autre :

```
trace_id = 73ffd5332255a5de453384d4bc45eb4c        # VRAI trace_id W3C (non synthétique)

  Tempo (OTLP)      GET /api/traces/<trace_id>  → 200  service.name=apisix
                    span "opentelemetry-lua" réel (APISIX)
  OpenSearch (txn)  term trace_id:"<trace_id>"  → 1 doc  gateway=apisix
                    api=accounts-read  status=success
```

- **trace → transaction** : *correlation* Grafana **Tempo → OpenSearch-Txn**
  (uid `efotpn446a5fkc`, `field=traceID`, requête `trace_id:"${__value.raw}"`) —
  posée par `apply.sh`.
- **transaction → trace** : *data link* sur le champ `trace_id` du panneau table
  OpenSearch → **Explore Tempo**.

> Le lien est **bidirectionnel sur le `trace_id` W3C**. Condition technique : le
> `trace_id` doit être **réel**, pas synthétique. Elle est remplie en activant
> `plugin_attr.opentelemetry.set_ngx_var=true` dans `gateways/apisix/config.yaml`
> — sans quoi `$opentelemetry_trace_id` est vide dans le `log_format` du kafka-logger
> (le doc OpenSearch ne porterait alors qu'un identifiant local, non corrélable à
> Tempo). Le `request_id` déterministe sert de filet **anti-sampling** (ADR-070).

> **WSO2 OTel — RÉSOLU (goal A2, 2026-07-03)** : cause racine trouvée au
> **bytecode** (`OTLPTelemetry.class`, tracing_9.31.86) — le tracer OTLP ne lit
> QUE `remote_tracer.url` (jamais hostname/port, clés jaeger/zipkin) **et** exige
> une entrée `[[remote_tracer.properties]]` non vide (design api-key New Relic) ;
> sinon le champ `openTelemetry` reste null → NPE au boot = la « déstabilisation »
> observée. Config correcte (`scripts/setup-wso2-otel.sh`) : `url =
> "http://otel-lgtm:4317"` (exporteur **gRPC**, scheme obligatoire), une propriété
> header factice, et `[[resource_attributes]] service.name=wso2` (le dernier merge
> gagne sur le nom par défaut). Prouvé live : trace
> `e1985c23c6cde9082668a541a06dab6f` — `rootServiceName=wso2`, spans complets
> (CORS → Key_Validation → Throttle → Request_Mediation → **Backend_Latency** →
> Response_Mediation, `GET--/accounts`), stack stable (9443/8243 en 200, zéro
> erreur d'export). Persistance : config in-container (survit au restart, re-jouer
> le script après un recreate, comme wm-otel-setup.sh).
>
> `grafana/otel-lgtm` est une image **dev/démo** (collector + LGTM tout-en-un),
> pas un design de production — l'atterrissage dans la stack cible reste le même.

---

## Preuve 6 bis — Analytics transactionnelle par fournisseur (ADR-070)

Le **plan de gouvernance/audit** : toutes les transactions (succès **et** erreur)
centralisées dans **un OpenSearch unique**, **isolées par fournisseur** et **redactées
à un seul endroit auditable**. C'est l'analytique transactionnelle per-fournisseur
que la thèse listait comme « pas encore prouvée » — désormais prouvée bout-en-bout
**sur les 3 tranches (APISIX + webMethods + WSO2)** : goal A3 (2026-07-03) ferme la
parité, `scripts/test-txn-wso2.sh` **12/12**. Agrégat live des `gateway` portant des
docs txn : `{apisix, webmethods, wso2}`.

**Chaîne d'ingestion** (off the transaction path, ADR-068 — la gateway *émet*, ne
*traite* pas) :

```
APISIX (kafka-logger)  →  topic stoa.txn.apisix  (Redpanda, poc-analytics-redpanda)
   →  Data Prepper (poc-analytics-data-prepper, observability/data-prepper/pipelines.yaml)
   →  OpenSearch data stream txn-accounts-team  (backing .ds-txn-accounts-team-*)
```

**Le collecteur (Data Prepper) est la SEULE autorité de redaction** (ADR-070) — la
gateway ne ship **jamais** de body brut. Règle de capture stricte (pipeline) :

| Issue | Ce qui est indexé |
|---|---|
| **succès** (`status<400`) | **métadonnées seules** (tenant/provider/api, trace_id, latence, http_*) |
| **erreur** (`status>=400`) | méta + `response_body` **redacté** + `request_headers`/`response_headers` **redactés** |

Redaction **déterministe** appliquée **avant** indexation : IBAN FR (garde 4+4,
masque le milieu), montants/soldes (`balance|amount|montant|solde|…` → masqué), et
suppression des en-têtes sensibles bruts (`Authorization`/`Cookie`/`Set-Cookie`) —
`redaction_applied=true` est stampé. Aucune PII non-redactée n'atteint
`txn-{tenant}-*`.

**Isolation tenant + RBAC par fournisseur** (vérifié live) :

| Objet | Valeur live |
|---|---|
| **data stream** | `txn-accounts-team` → backing `.ds-txn-accounts-team-000001` |
| **tenant Dashboards** | `accounts-team` |
| **rôle** | `tenant-accounts-team-viewer` — `index_patterns` = `txn-accounts-team*` + `.ds-txn-accounts-team-*` |
| **FLS / field masking** | `user_ip`, `user_agent`, `response_body`, `request_headers.*`, `response_headers.*` |
| **tenant_permissions** | `accounts-team` → `kibana_all_read` |
| **user** | `accounts-viewer` (read-only, scope au seul tenant) |

> **Double rempart PII** : la donnée est **redactée à l'ingestion** (collecteur =
> autorité) **et** **masquée à l'affichage** (FLS du rôle). Le FLS seul ne suffit
> pas (la donnée brute resterait indexée) — d'où la redaction obligatoire en amont.

**Provisioning reproductible** (`observability/opensearch/provision/provision.sh`,
idempotent) : un run à blanc reproduit **tout** — template data-stream (01) + ISM
rétention (02) + tenant Dashboards (07) + rôle/FLS (03) + user (04) + roles-mapping
(05) + l'index-pattern saved-object `txn-accounts-team` (08, sur le tenant
`accounts-team`). C'est le miroir de ce que `labctl` projette
(« Define Once → Observe Everywhere »).

**Projection par le control plane** (`labctl`) : quand le manifeste porte un bloc
*observability/tenant*, l'adapter APISIX
(`labctl/internal/adapter/apisix/kafkalogger.go`) **projette le plugin `kafka-logger`**
sur chaque route au publish **et** au re-PUT du subscribe — le `log_format` est la
projection FLAT du schéma `stoa.txn` (contrainte APISIX : tout `log_format` doit être
une string plate, `batch_max_size=1` pour que Data Prepper désérialise un objet par
record). L'émission n'est pas un état posé à la main : c'est l'`apply` qui la porte.

### Tranche WSO2 (goal A3, 2026-07-03) — parité 3/3, source = spans OTel natifs

WSO2 n'expose sa transaction data-plane (8243, PassThrough/Synapse) dans **aucun log
fichier porteur du trace_id** (`apim_metrics.log` off, `http_access` sans trace_id) :
la **seule** source qui porte le trace_id W3C est les **spans OTel** (débloqués par
le goal A2). D'où le `wso2-otel-tap` (`observability/wso2-otel-tap/`, Go) — le même
rôle « Y » que `wm-trace-bridge`, côté spans :

```
WSO2 :8243 --OTLP/gRPC(gzip)--> wso2-otel-tap ─┬─► forward OTLP ─► otel-lgtm (Tempo, INCHANGÉ)
                                               └─► stoa.txn.wso2 (Redpanda) ─► Data Prepper
                                                     (pipeline stoa-txn-wso2) ─► OpenSearch txn-{tenant}
```

Le tap reçoit l'export OTLP de WSO2 (repointé `remote_tracer.url=wso2-otel-tap:4317`),
**forwarde chaque batch tel quel** à otel-lgtm (Tempo garde la trace WSO2 complète) et
**émet un record `stoa.txn` PLAT par TRACE d'API** — sélection du **span RACINE**
(`parent_span_id` vide) qui, seul sur WSO2 4.5, porte `span.api.name` +
`span.http.response.status.code` (vérifié live ; les enfants `GET--/x`, `API:*_Latency`
ne les portent pas). Cette règle rend le « 1 doc/trace » **structurel et
indépendant du batching** : si le BatchSpanProcessor de WSO2 fragmente une trace sur
plusieurs exports, les enfants (sans attrs) ne produisent rien, seul le root émet —
zéro double-comptage, et la latence est celle de la requête globale (jamais un
enfant). Vers `stoa.txn.wso2`. Le record porte le **trace_id
NATIF du span** → pivot Tempo↔OpenSearch identique aux deux autres tranches. Les spans
ne portant aucun corps, la capture est **métadonnées seules par construction**
(ADR-070) ; Data Prepper reste l'autorité de redaction unique. Tenant résolu
`api→tenant` (les spans WSO2 ne portent pas de tenant) + filet pipeline.

**Preuve mesurée** (`scripts/test-txn-wso2.sh`, 12/12) : un appel WSO2 → trace_id
`fc34bcf9709b2b2d896818b9de66aa85` présent **dans Tempo** (`service.name=wso2`, trace
complète) **et dans OpenSearch** `.ds-txn-accounts-team-*` (`gateway=wso2`,
`http_status=404`, `status=error`, `latency_ms=7.09`, `consumer_id`,
`redaction_applied=true`, `@timestamp`=heure du span) — **1 seul doc** pour ce
trace_id (dedup par trace), **aucun** `response_body`/`request_headers` (métadonnées
seules). Piège pinné : WSO2 exporte en **gzip** (`setCompression("gzip")`, bytecode) →
le serveur gRPC du tap enregistre le codec gzip (sinon `UNIMPLEMENTED: Decompressor
not installed`).

> **Restent différés** (hors A3) : rien sur la parité analytics (3/3 atteinte). Le tap
> vit dans l'overlay analytics ; en socle seul, WSO2 pointe otel-lgtm en direct (A2,
> traces 3/3). Un cas **succès** (200) n'a pas été capturé faute de backend sain sur le
> trial (chaîne de versions accounts-read gâtée, cf. note goal A1) ; le chemin succès =
> métadonnées seules est prouvé par construction (spans sans corps) + le test wM.

---

## Preuve 7 — Souveraineté

100 % local / self-hosted, **zéro dépendance SaaS** : toutes les briques tournent
en conteneurs sur le poste (`docker compose`), aucune sortie vers un service
managé tiers. C'est l'argument différenciant vs Axway Amplify (SaaS, hors zone).

---

## 2026-07-04 — Classification CENTRALE anti-spoof + poly-repo réel (ADR-076 écart #1, goal A5) ★

**Validé, `scripts/test-classification-central.sh` → 11/11.** L'écart #1 d'ADR-076
(la classification d'intégrité vivait dans l'`api.yaml` du repo PROJET, éditable →
une équipe pouvait déclarer M pour éviter le mTLS d'une donnée VH) est **fermé** :
l'autorité passe à un **registre central** (`stoa-platform-ci/governance/classifications.yaml`,
repo plateforme non éditable ; en prod = repo `data-governance`).

`labctl apply` reçoit la source (`LABCTL_CLASSIFICATION_SOURCE`) + l'**identité projet
non-éditable** (`LABCTL_PROJECT` = `PROJECT_NAME` du Jenkinsfile plateforme). Le bundle
de sécurité est **dérivé du central** (autoritaire) ; l'`api.yaml` projet n'est qu'une
**référence** qui doit ne pas être plus faible.

**Ancre anti-spoof (le point dur, corrigé en review)** : la clé de lookup est
**(owner, api)** où `owner` vient du pipeline, JAMAIS de l'`api.yaml`. Un projet ne voit
que ses propres entrées → il ne peut pas « pointer la ligne plus faible d'un autre
projet » en renommant son `api.yaml` (le trou qu'un design naïf keyé sur `(tenant_id,
name)` — tous deux projet-éditables — aurait laissé ouvert).

**Matrice mesurée** (2 repos pilotes, MÊME pipeline/binaire) :

```
                              central   → bundle dérivé
accounts-team / accounts-read  VH/ext   → oauth2+mtls+rate-limit+audit-log+ip-allowlist
payments-team / payments-read  H/int    → oauth2+rate-limit+audit-log  (PAS de mtls) ✓ différent

  downgrade api.yaml VH→M (accounts-team)            → [CLASSIFICATION_SPOOFED]
  accounts-team prétend servir payments-read         → [CLASSIFICATION_UNGOVERNED] (emprunt refusé)
  tenant_id falsifié (banking-demo→payments-team)    → [CLASSIFICATION_SPOOFED]
  API renommée absente du registre                   → [CLASSIFICATION_UNGOVERNED]
  faux governance/ planté DANS le repo projet        → IGNORÉ (seul le chemin plateforme fait foi)
  sans source (dev-local/PR-gate)                    → comportement A1 (déclaration projet) — non-régression
```

- **Séparation des devoirs** : le PR-gate projet reste aveugle au central (feedback
  rapide) → une équipe voit son PR VERT puis est **refusée au deploy** plateforme.
  L'autorité est le gate plateforme, jamais le repo projet.
- **Non-régression A1** : `test-integrity-enforce.sh` reste **31/31 live** (le chemin
  partagé est inchangé sans `LABCTL_CLASSIFICATION_SOURCE`).
- **Onboarding** (fail-closed) : une API absente du registre ne déploie pas
  (`UNGOVERNED`) — l'enregistrer = une PR vers la source de gouvernance (data-governance),
  sérialisée, pas self-service.

---

## 2026-06-12 — CI multi-env webMethods : promotion-from-Git, proxy admin, rollback (ADR-075) ★

**Validé live, `scripts/demo-multienv.sh` → 19/19 PASS** (dont 5 contre-épreuves
fail-closed), sur la topologie `docker-compose.envs.yml` (3 mocks wM dialecte 10.15
sur réseau `nonprod` interne, trial réel = PROD, seul pont `[poc, nonprod]`).

- **Spike préalable sur le trial 10.15** (méthodologie capture-from-UI) : `${alias}`
  résolu **par requête** dans `straightThroughRouting` (switch d'env par un seul PUT
  d'alias, sans réactivation) ; payload 200 Ko traverse le data-plane ; PUT
  `/policyActions` **enveloppé obligatoire** (body nu = 200 no-op silencieux) ;
  credential alias `httpAuthCredentials.password` **en base64** ; action outbound
  **imbriquée** sous `transportSecurity` (à plat = NPE 500).
- **Routing-by-alias dans labctl** (`routing.go`) : prouvé live sur le trial —
  apply → data-plane via `${api}-backend` + **Basic injecté par credential alias**
  (`liveuser:livepass` vu par le backend), re-apply idempotent, valeur d'alias
  changée → le data-plane suit immédiatement.
- **Proxy admin** : matrice `setup-wm-admin-proxy.sh` **15/15** — sans token 401 ;
  token sans le scope de l'env 401 ; `ci-horsprod` (scopes `deploy:{dev,rec,int}`)
  200 ; `/rest/apigateway/users` hors allowlist 404 ; DELETE 405. `labctl apply`
  complet **à travers le proxy** (bearer → credential alias → admin mock) sans que
  le client ne porte les creds admin de l'env.
- **Chaîne de gates** : dev/rec auto au merge (gate Git, env non mergé = skip
  narratif) ; rec→int approuvé par référence `pr_…` par un membre `int-team`
  (claim `groups`) ; int→prod = `change_ref`+`pv_ref` requis + **ITSM approved**
  + 4-yeux ; apply prod au **SHA pinné** (`deploy.prod.yaml: commit`).
- **Rollback exploit 1-clic** : restaure le `deploy.prod.yaml` N-1 (avec SON pin),
  marker `rolled_back` + evidence motivée, re-apply idempotent. **Jamais de DELETE.**
- **Contre-épreuves** : ITSM draft → 409 `ITSM_NOT_APPROVED` ; self-approval prod →
  403 `SELF_APPROVAL_BLOCKED` ; rollback d'un 1er déploiement → 409
  `NO_PREVIOUS_STATE` ; `poc-jenkins` ne résout pas `wm-mock-dev` (isolement réseau) ;
  AppRole `ci-pipeline` lit `secret/stoa/envs/dev/wm-admin` → **403 Vault**.
- **★ Exécuté sur le VRAI Jenkins** (pas seulement le script de démo) : webhook Gitea →
  `stoa-federation` **#29 UNSTABLE-by-design** (stage legacy WSO2 jaune — état revisions
  à nettoyer, hors-sujet ; chaîne dev→rec→int **verte** via les proxies, pins respectés) ;
  `stoa-prod-deploy #2/#4` **SUCCESS** (gate Git rejoué : approved/4-yeux/CHG/PV/pin —
  v1.0.0 puis v1.0.1 via le **versioning natif** `POST /apis/{id}/versions`, trouvé par
  l'échec du #3 : le trial refuse POST frais ET PUT in-place pour une nouvelle version) ;
  `stoa-prod-rollback #2` **SUCCESS** (revert **signé** `dc8e0a4` : v1.0.0 + son pin
  restaurés, marker `rolled_back` motivé, re-apply idempotent, smoke 401 — les deux
  versions coexistent sur la gateway, **Git pin celle qui fait foi**).

---

## 2026-07-03 — Enforcement « sécurité = f(intégrité) » au `labctl apply` (ADR-076, écart résiduel fermé) ★

**Validé live, `scripts/test-integrity-enforce.sh` → 31/31 PASS** contre le
webMethods réel (`apigateway-trial:10.15`). Le bundle dérivé de la classification
d'intégrité n'est plus seulement *validé* (INTEGRITY_INCONSISTENT au merge) et
*constaté* (rapport de réconciliation) — il est **enforcé fail-closed à l'apply**,
en deux gates, quand un contrat UAC (`api.yaml`) est colocalisé au manifeste
(layout repo-par-projet) ou nommé via `--uac` (aucun flag d'opt-out) :

- **Gate 1 — pré-check statique `[INTEGRITY_UNFULFILLED]`** : chaque target doit
  déclarer les knobs du bundle (VH ⇒ `inboundAuth.mtls` + `transportProtocol:
  https` + `audience/scope` + `rateLimit`) — sinon refus **avant toute écriture**
  (prouvé : compte d'APIs gateway identique avant/après le refus).
- **Gate 2 — read-back gateway `[ENFORCEMENT_UNCONFIRMED]`** : après publish,
  l'état **RELU** doit confirmer le bundle — strategy `OIDC-<api>`, scope mapping
  lié à l'apiID, action IAM **toutes-règles** (AND oAuth2Token+httpsCertificate,
  `allowAnonymous=false`), throttle LMT (limite relue > 0), `logInvocation`
  global actif avec `storeRequestPayload=false` (posture ADR-070), transport
  `[https]`. Verdicts imprimés en entier (table + bloc JSON additif — le contrat
  CI `.ok/.created/.api_id` est inchangé).

```
1. VH sans jambe mTLS        -> rc=1 [INTEGRITY_UNFULFILLED], RIEN écrit
2. VH conforme               -> rc=0 ; oauth2/mtls/rate-limit/audit-log=enforced,
                                ip-allowlist=degraded, audience annotée 3/4 (trial)
3. re-apply                  -> rc=0 (idempotent, read-only)
4. CONTRE-ÉPREUVE sabotage   -> allowAnonymous→true (hors-bande, action IAM AND
   partagée — que le projecteur NE converge JAMAIS) : re-apply rc=1
   [ENFORCEMENT_UNCONFIRMED] mtls=missing ; restore prouvé ; re-apply rc=0
5. H sans inboundAuth        -> rc=1 [INTEGRITY_UNFULFILLED] (oauth2)
6. VH sur apisix             -> rc=1 (mtls/rate-limit non projetables en A1 — honnête)
7. M+apikey exposure=external-> rc=1 [INTEGRITY_INCONSISTENT] (même code que validate)
```

**Chaîne CI fermée** : `stoa-platform-ci/deploy/deploy-one.yml` rend `api.yaml`
**obligatoire** (stat + assert explicite — supprimer le contrat ne désactive pas
le gate en douce) et le copie dans le workspace de rendu → le gate s'active dans
le pipeline plateforme sans autre changement (`rc≠0` déjà gaté) ; le PR-gate
d'`accounts-team` (pr-check.yml + pr-check.sh) asserte le couplage
`target.yaml ⇒ api.yaml colocalisé` dès la PR.

**Sémantique assumée (jamais surclamée)** :
- Un verdict UNCONFIRMED **ne désactive pas l'API** — gate niveau pipeline
  (cohérent rollback-sans-DELETE) ; remédiation = pipeline rouge + rapport de
  réconciliation + humain. Le verify est un instantané à l'apply ; une mutation
  hors-bande ultérieure est vue au prochain apply (prouvé par le cas 4) ou par
  `reconcile` (read-only, non bloquant — défense en profondeur).
- Le gate garantit **bundle(classification déclarée) ⊆ enforced** ; il ne prouve
  PAS que la classification déclarée est la bonne (anti-downgrade = écart ADR-076
  #1, classification en gouvernance centrale — goal A5). Un target plus fort que
  son bundle déclenche un warning « classification sous-déclarée ? ».
- Les verdicts self-reported viennent du code in-repo (`labctl/internal/adapter/
  webmethods/enforce.go`), pas d'une attestation externe ; `unverifiable` = refus.

**Constat annexe (état du trial, hors A1)** : l'apply plateforme du repo réel
`accounts-team` active correctement le gate (pré-check VH passé) mais est bloqué
EN AMONT du gate par un état gâté du trial (47h+ d'expérimentations) : le record
`accounts-read v1.0.3` refusait le PUT in-place (500 « Error message: null »,
même famille que l'échec prod-deploy #3 du 2026-06-12) ; sa purge `forceDelete`
a ensuite exposé une **corruption de la chaîne de versions** (« Versioning is
allowed only from latest version » sur la base 1.0.2 — la métadonnée *latest*
pointe un record supprimé). Le rapport de réconciliation lit désormais
honnêtement la dernière version présente (1.0.2, IAM sans règle cert = drift
réel vs le manifeste VH). Remédiation = rebuild-from-Git sur état sain
(teardown/up ou env neuf) — opération d'environnement, PAS un défaut du gate :
la preuve 31/31 couvre create + converge + drift sur API propre, et le
read-back audit-log/reconcile a été validé live sur ce même trial.

## 2026-07-05 — Identité UTILISATEUR jusqu'à Vault : token exchange RFC 8693 (ADR-077) ★

**Contrainte client (IT)** : « c'est un **utilisateur** qui se connecte au Vault, pas une
application » — ET des jobs Jenkins non interactifs. Réponse prouvée : la session
Keycloak de l'utilisateur est propagée par **token exchange standard (RFC 8693)** en un
JWT court (5 min, `aud=vault`, **`tenant=<son tenant>`**) que le job CI présente à
`auth/jwt/login` ; le token Vault obtenu est **nominatif ET tenant-scopé** (entité =
l'utilisateur, TTL 10 min, policy **templatée par tenant**, révoqué en fin de build avec
**preuve de mort**). **Zéro credential côté chaîne CI** : ni mot de passe, ni AppRole,
ni token longue durée — le job `stoa-user-deploy` ne détient rien.

```
alice (humaine, Dex/Oracle) ─auth_code─▶ Keycloak 26.3.4
  ─exchange RFC 8693 (vault-exchange, audience=vault)─▶ JWT 300 s sub=alice
    aud=vault tenant=banking-demo
  ─webhook (payload masqué)─▶ Jenkins stoa-user-deploy (AUCUN credential propre)
  ─auth/jwt/login─▶ token Vault NOMINATIF (display_name=jwt-alice@bc.example)
  ─▶ READ deploy/banking-demo (200) · CROSS-TENANT payments-team 403 · hors
    périmètre 403 · revoke-self VÉRIFIÉ (lookup-self → 403) en fin de build
```

**Preuve : `./scripts/test-user-vault-jwt.sh` → 24/24 PASS** (2026-07-05, durci après
review adversariale), dont :
- chaîne nominale 13/13 (claims du JWT échangé : `preferred_username=alice@bc.example`,
  `aud=vault`, `azp=vault-exchange`, `tenant=banking-demo` — la délégation est TRACÉE et
  la **ségrégation par tenant enforcée** : cross-tenant → 403) ;
- E2E CI 6/6 : build Jenkins SUCCESS, identité humaine attestée dans le log, token
  révoqué **et prouvé mort**, **aucun jeton dans le log** (`printContributedVariables=
  false` + `set +x` + jetons hors argv), webhook **sans** jeton → build **FAILURE** ;
- contre-épreuves 5/5 : token non échangé → Vault refuse (`bound_audiences` + `azp`) ;
  subject token de service non adressé → **Keycloak refuse l'exchange** ; carol (viewer)
  → **Vault refuse** (`bound_claims realm_access.roles`) ; **audit Vault nominatif scopé
  à ce run**, y compris pour les refus.

**Changements d'environnement** : Keycloak **26.1.4 → 26.3.4** (l'exchange standard est
GA depuis 26.2 ; image hardcodée dans `docker-compose.poc.yml` — la variable
`KEYCLOAK_IMAGE` de `.env`/`.env.example` n'est plus consommée, à réaligner à la main) ;
clients `vault-exchange` (+ mapper `tenant`) /`vault` + mappers d'adressage dans
`realm-stoa-lab.json` ; `setup-user-vault-jwt.sh` (KC scope dynamique + Vault
jwt/policy templatée/rôle/audit) ; `setup-user-deploy-job.sh` (job Jenkins sans
credential). Runbook post-recreate Keycloak : ADR-077 §Restauration (pièges : usernames
fédérés = `<user>@bc.example`, `unmanagedAttributePolicy`, client runtime).

**Wiring console → chaîne A (livré le même jour)** : au `promote-approve`, la
governance-api échange le Bearer de **l'approbateur** (RFC 8693) et déclenche
`stoa-user-deploy` avec le JWT — opt-in env (`USER_DEPLOY_WEBHOOK_URL` +
`VAULT_EXCHANGE_SECRET[_FILE]`), dispatch asynchrone, réponse `user_deploy:
dispatched`. **Preuve : `./scripts/test-console-user-deploy.sh` → 12/12 PASS** —
UNE action utilisateur (bob approuve, 4-yeux intact) et c'est l'identité de **bob**
(pas dave le demandeur, pas un service account) que Vault voit : build Jenkins
SUCCESS **corrélé à LA promotion** (hint), `identite=bob@bc.example
tenant=banking-demo`, token prouvé mort, zéro jeton dans les logs BFF et Jenkins
(JWT **et** token du webhook — URL redactée au boot). + 7 tests unitaires Go sous
`-race` (contrat d'exchange, refus → pas de webhook, hook approve, refus 4-yeux →
zéro dispatch, exchange KO → approve reste 200, flux inchangé sans wiring, opt-in
env fail-fast).

**Limites documentées** : pas d'humain = pas de déploiement (propriété de
gouvernance assumée) ; jobs planifiés → AppRole (ADR-074) inchangé ; lien
approbation→exchange organisationnel (ADR-077 §Limites 7).

## 2026-07-09 — É0 : levée des 4 bloqueurs transverses du livrable (DELIVERY-PROCESS §4) ★

Les quatre bloqueurs qui gataient TOUTES les briques dès qu'on quitte le poste
du lab (critique de transposabilité 2026-07-09) sont levés :

1. **Proxy sortant d'entreprise** — les DEUX transports HTTP de labctl
   (`internal/httpx.NewClient`, sonde `targetshealth`) portent désormais
   `Proxy: http.ProxyFromEnvironment` : derrière un egress proxy bancaire,
   `HTTP(S)_PROXY`/`NO_PROXY` suffisent, aucun rebuild.
2. **CA d'entreprise** — knob `LABCTL_CA_FILE` (tous les adapters + sonde) et
   `VAULT_CACERT` (client Vault, nom standard, fallback `LABCTL_CA_FILE`) :
   bundle PEM AJOUTÉ au trust système (`RootCAs`), **fail-closed** si le fichier
   est illisible ou sans certificat (erreur à chaque requête, jamais de repli
   silencieux). `Insecure` reste l'échappatoire PoC, plus jamais nécessaire chez
   un client. Les 3 scripts de provision OpenSearch perdent leur `-k` câblé :
   `OPENSEARCH_CA_FILE` (--cacert, prioritaire) / `OPENSEARCH_INSECURE`
   (défaut PoC true — certs démo self-signed).
3. **Auth Git** — plus aucun `git clone` d'URL en dur dans les 4 Jenkinsfiles
   (ci/Jenkinsfile{,.prod,.rollback} + stoa-platform-ci/Jenkinsfile.deploy) :
   knob `GOVERNANCE_GIT_URL` (resp. `PROJECT_REPO`) surchargeable au niveau job
   + convention `GIT_CREDENTIALS_ID` OPTIONNELLE (vide = anonyme PoC, posé =
   credential usernamePassword injecté via un helper `GIT_ASKPASS` éphémère —
   le secret ne touche ni l'URL du remote, ni argv, ni le log).
4. **Release binaire** — `make release` : 3 binaires livrables (labctl,
   governance-api, onboarding-api) × 3 archs (linux/amd64 minimum contractuel,
   linux/arm64, darwin/arm64), **versionnés** (ldflags → `labctl version`,
   traçable au commit), `SHA256SUMS` vérifiable (`sha256sum -c`), **SBOM
   SPDX-2.3** généré depuis `vendor/modules.txt` (purl golang par module) —
   le tout **air-gapped** (`GOPROXY=off -mod=vendor`), buildé hors zone :
   l'agent Jenkins client reçoit les binaires, jamais le toolchain Go.

**Preuve : `./scripts/test-e0-blockers.sh` → 18/18 PASS** — dont preuves au
niveau du BINAIRE LIVRÉ (pas seulement des tests unitaires) : l'appel admin vers
un host non résolvable TRANSITE par un faux `HTTP_PROXY` local (requête
absolute-form observée) ; face à un HTTPS signé par une CA inconnue, échec x509
SANS knob (contrôle) et handshake accepté AVEC `LABCTL_CA_FILE` ; ELF x86-64
vérifié au `file`, checksums re-vérifiés, SBOM re-parsé. + tests Go
(`internal/httpx`, `internal/vault`) sous `-race`, suite complète verte.
S'exécute HORS ZONE : aucun service du compose requis.

## 2026-07-17 — L'« upload de certificat binaire » de l'UI wM est un MYTHE (ADR-078 écart n°5 RÉFUTÉ) ★

**Croyance réfutée** (spike 2026-07-15) : « le REST refuse le binaire, donc sur une
version touchée par le bug de hash base64 le cert de l'app doit se poser à la main
dans l'UI (export `.cer` binaire Windows) ⇒ labctl ne peut pas ». Le raisonnement
supposait que l'UI transporte des **octets bruts**. **Trace réseau : elle ne le fait
pas.**

**Protocole** (gateway RÉELLE `apigateway-trial:10.15`, app **jetable**
`spike-cert-binary` créée puis détruite — gateway restaurée à ses 4 apps) :

1. `openssl x509 -outform DER` → `.cer` **binaire** vrai (855 o, entête `30 82 03 53`,
   `file` = « Certificate, Version=3 »).
2. UI **de l'API Gateway** (`http://localhost:19072/apigatewayui/`, *pas* le
   Designer) → *Application → Edit → Identifiers → Client certificates → Browse →
   Add → Save*, en capturant le réseau (Playwright).
3. Read-back `GET :5555/rest/apigateway/applications/{id}` + comparaison d'octets.

**Ce que l'UI envoie réellement** (capture verbatim) :

```
PUT /apigatewayui/apigateway/applications/{id}      Content-Type: application/json
"identifiers":[{"value":["MIIDUzCCAjugAwIBAgIU..."],"name":"demo-client-binary.cer","key":"httpsCertificate"}]
```

Le champ `<input type=file accept=".cer,.der,.pem,.crt">` est lu **en JS** et
**base64-encodé côté client** : PUT JSON ordinaire, aucun `multipart`, aucun
`octet-stream`. **Il n'existe aucun chemin binaire dans le produit.**

**Mesure décisive** — octets stockés par la gateway, les deux voies :

| Voie | `name` | `sha256(valeur stockée)` | `== base64(DER)` |
|---|---|---|---|
| UI (`.cer` **binaire**, Browse+Add+Save) | `demo-client-binary.cer` | `ff18b2a650aee4e3bdc606835b88274af7b237060480a05f17893b9274970474` | ✅ |
| REST (labctl, `base64(DER)`) | `partner-cert` | `ff18b2a650aee4e3bdc606835b88274af7b237060480a05f17893b9274970474` | ✅ |

**Identiques au bit près** (même longueur 1140, même sha256), et le PUT de l'UI est
relu tel quel par le REST `:5555` ⇒ **même API derrière**, comme supposé.

**Conséquence** : un bug de hash de vérification ne peut pas discriminer les deux
voies — elles déposent les **mêmes octets** ; il les touche **toutes les deux ou
aucune**. « Exporter en binaire + passer par l'UI » ne contourne donc **rien** ; le
contournement n'a jamais existé, seule la croyance qu'un `.cer` binaire *reste*
binaire jusqu'à la gateway. Si un bug de hash se manifeste sur une version de fix
client, la cause est **ailleurs** (matière stockée ou parsing runtime, pas
l'encodage du transport) — **et l'UI n'y échappera pas non plus**.

⇒ **Aucun résidu manuel sur le cert** : cert + plage IP + clé backend = **100 %
REST/labctl**. `identifiers.go` envoyait déjà la bonne forme (`{name, key:
httpsCertificate, value:[base64(DER)]}`) — **aucun changement de code requis** côté Go.
*(Faits du 2026-07-15 conservés : le REST refuse le binaire brut et l'hex — 400 —,
n'accepte que `base64(DER)` ou le PEM complet, stockés verbatim sans parsing. C'est
cohérent : l'UI non plus n'envoie que du base64.)*

### Volet Ansible : « via Ansible c'est aussi bon ? » — OUI après avoir fermé 2 bugs LATENTS

Le livrable client, c'est le **rôle Ansible** (le Go est parqué). Il fallait donc le
prouver LIVE, pas raisonner par analogie. Rôle `apim_selfservice_app` lancé contre la
10.15 réelle sur une app **jetable** (`spike-cert-ansible`, `enforce:[]` + backend
neutralisé pour isoler l'écriture du cert et ne PAS toucher la policy de l'API de
démo ; app supprimée ensuite — gateway restaurée à ses 4 apps). **Résultat cert :
identité au bit près avec les deux autres voies.**

| Voie | sha256(valeur stockée) |
|---|---|
| UI (`.cer` binaire) | `ff18b2a650aee4e3bdc606835b88274af7b237060480a05f17893b9274970474` |
| REST (labctl `base64(DER)`) | `ff18b2a650aee4e3bdc606835b88274af7b237060480a05f17893b9274970474` |
| **Ansible (rôle, PEM→strip→base64)** | `ff18b2a650aee4e3bdc606835b88274af7b237060480a05f17893b9274970474` |

Idempotent (RUN 2 : pas de doublon d'identifier, même hash). MAIS le premier run a
révélé **deux bugs que le rôle portait sans le savoir** — tous deux masqués jusque-là
parce que les runs « prouvés » du 2026-07-15 trouvaient l'app **déjà créée** par le
moteur Python et **sans** `public_cert_ref` :

- **BUG 1 — création d'app CASSÉE à chaque fois (raison d'être du rôle).** `set_fact
  ss_app_id: {{ a.id | default((a.applications|first).id) }}` : Jinja évalue
  l'**argument** de `default()` **eagerly** → `.applications` déréférencé même quand
  `.id` existe → `'dict object' has no attribute 'applications'` à **chaque** POST.
  Le chemin de création n'avait donc **jamais** tourné live. **Fix** : expression
  conditionnelle `a.id if ('id' in a) else …` (paresseuse) + assert `APP_ID_UNRESOLVED`.
- **BUG 2 — extraction de cert qui CORROMPT en silence deux formats clients courants.**
  Le rôle faisait « retirer BEGIN/END sur TOUT le fichier puis filtrer le non-base64 ».
  Mesuré contre la gateway :
  - **PEM en chaîne** (leaf + intermédiaire, ordre openssl standard) → les 2 corps
    **concaténés** en un blob (1140 → 2272 car., décode en 1702 o) ;
  - **PEM à en-tête texte** (`Bag Attributes`, `subject=` : exports Windows/Java
    courants) → les **lettres de l'en-tête** survivent au filtre et préfixent le
    base64 (1140 → 1200 car., ne décode même plus).

  La gateway stockant **verbatim** (elle ne parse pas), l'apply aurait dit
  « convergé » avec une **identité morte** (le cert présenté ne matcherait jamais →
  401 au handshake). La **spec Go**, elle, était déjà correcte (`pem.Decode` = premier
  bloc, décodé proprement — même `sha256` sur les deux formats) : c'est la
  **transcription Ansible** qui avait dévié de la spec. **Fix** : isoler le PREMIER
  bloc CERTIFICATE (équivalent `pem.Decode`) + trois assertions fail-closed
  (bloc présent, corps non vide, longueur multiple de 4).

**Preuves du fix, live** : `chain.pem` et `bagattr.pem` → `CERT_OK` + `sha256`
`ff18b2a6…` (SAIN) ; `garbage.pem` (sans bloc) → **refusé** `CERT_INVALID` (au lieu
d'une corruption silencieuse). Aucune autre extraction naïve ailleurs dans `ansible/`
(grep). ⇒ Réponse à la question : **oui, le cert par Ansible est bon — désormais aussi
robuste que la spec Go, et fail-closed sur les PEM non conformes.**

### Même crible sur le rôle PRODUCTEUR `apim_publish_api` (from-scratch live)

Appliqué la même méthode au rôle producteur (import OpenAPI → activate → inbound) :
audit des captures d'id, puis exécution **from-scratch** sur des APIs **jetables**
(nettoyées ensuite — gateway ramenée à ses 10 APIs, 0 résidu alias/strategy/scope/
action). Deux enseignements — un faux suspect écarté, un vrai bug fermé.

**Faux suspect (écarté par la mesure).** `inbound.yml:169`
`{{ x.policyAction.id | default(x.id) }}` ressemblait au BUG 1 du consommateur (défaut
`default()` évalué eagerly). **Mais non** : testé en isolation sur la vraie forme
`{policyAction:{id}}`, il renvoie l'id **sans erreur**. La différence avec le
consommateur : là, le défaut était `(x.applications | first).id` — le **filtre `first`
force** l'évaluation d'un `Undefined` et lève ; ici `x.id` est un accès d'attribut **nu**
→ `Undefined` non forcé, ignoré par `default()`. Confirmé **live** : run oauth2
from-scratch (empreinte `oAuth2Token` inexistante ⇒ chemin de **création** d'action
réellement exécuté) → `ok=42 failed=0`, puis `PUBLISH_CONFIRMED` + `INBOUND_CONFIRMED`
+ `OAUTH2_CONFIRMED`, idempotent. Les captures `main.yml:93` (`apiResponse.api.id`,
forme du POST multipart vérifiée) et `team.yml:19` sont saines aussi. **Leçon : ne pas
« corriger » par analogie — le motif jumeau n'était pas le même bug.**

**Vrai bug — un contrat OpenAPI en JSON échoue à l'import (400), silencieusement
réservé au YAML.** Le rôle lit le contrat par `lookup('file')` et le pousse en
`form-multipart`. Mesuré : contrat **YAML** → publié ; contrat **JSON** (cas client
courant) → **400 « input openapi file is not valid »**. Isolé par croisement
**contenu × extension** (contenu YAML sous nom `.json` → OK ; contenu JSON sous nom
`.yaml` → 400) : **c'est le contenu, pas l'extension**. Or `curl` publie ce même JSON
sans souci (201) ⇒ défaut **100 % côté Ansible**. Capture du corps multipart émis :
la partie `file` contenait `{'openapi': '3.0.3', …}` — **guillemets SIMPLES, un repr
de dict Python, pas du JSON**. Mécanisme : un contrat JSON commence par `{` ; le
**templating natif d'Ansible coerce** la string en dict, que l'encodeur multipart
`str()` en repr Python → JSON invalide. Le YAML (ne commençant pas par `{`) survivait,
d'où le masquage. **Fix** : `| string` sur le `lookup('file')` des DEUX chemins (import
POST + update PUT) — fige la valeur en texte avant coercion. Prouvé sur l'echo-server
(partie `file` repasse en guillemets doubles) **et live** : contrat JSON from-scratch
→ `PUBLISH_CONFIRMED` ; YAML → non-régression verte.

⇒ Réponse : le rôle producteur était **plus sain** que le consommateur (ses chemins de
création fonctionnaient from-scratch), mais il **refusait tout contrat JSON** — corrigé.
*(Non exercé, assumé : `team.yml` — Teams désactivé au lab, shape POST /assets/team
best-effort ; à valider chez le client.)*

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
STOA restant **hors du chemin transactionnel**.

L'**analytique transactionnelle par fournisseur** (longtemps listée ici comme non
prouvée) est **désormais démontrée sur les 3 tranches** (APISIX + webMethods + WSO2 ;
Preuve 6 bis, ADR-070, goals A3) : data stream + RBAC + FLS + redaction à un point
unique + pivot `trace_id`, bout-en-bout, parité 3/3. **WSO2 OTel** (goal A2) et sa
tranche analytics (goal A3) sont **résolus** (le « Fluent Bit sidecar » envisagé était
une impasse : les logs fichier WSO2 ne portent pas le trace_id — la source retenue est
les spans OTel via `wso2-otel-tap`). Restent **différés** : l'enforcement **audience**
wM (câblé, non opposable sur trial 10.15) et le streaming > 500 Mo.

## 2026-07-24 — Identité runtime d'une application OAuth2 wM 10.15 : la STRATÉGIE, pas la claim ★

**Question de départ** (design provisioning OIG/CLI2 → gateway) : « la claim
d'identification est-elle un paramètre (azp, client_id, toto…), et une bascule de
claim peut-elle être 0-coupure ? » Deux volets, assets jetables, cleanup par trap.

**Volet A — stockage** (`scripts/spike-claim-identifier.sh`, **11/11**) : le nom de
la claim d'un identifier `openIdClaims` est une donnée libre (toto/client_id/
x-custom-claim acceptés et relus) ; deux identifiers de noms différents coexistent ;
un identifier porte deux valeurs ; rejeu idempotent. ÉCART chaîne de livraison :
`consumer-auth.yml` fait `rejectattr('openIdClaims')` → n'en laisse jamais qu'un.

**Volet B — runtime** (`scripts/spike-claim-runtime.sh`, **11/11**, banc d'essai
`accounts-read/1.0.0` strict/oAuth2Token JAMAIS modifiée, oracle = `Application:<nom>`
dans le body d'erreur backend) — le stockage MENTAIT par omission :

- **R1** : une app SANS identifier mais avec stratégie est identifiée → le matching
  est `token.azp/client_id == strategy.clientId` (l'AS externe étant l'alias).
- **R2** : l'identifier `openIdClaims/azp` SEUL (clientId vierge) n'identifie PAS →
  **l'identifier de claim est décoratif au runtime**. Le volet A ne le voyait pas.
- **R3** : un nom de claim custom (`x-spike-claim`) n'est évalué NI en `openIdClaims`
  NI en `jwtClaims` → **« la claim est un paramètre » est FAUX au runtime 10.15**.
- **R4** : DEUX stratégies (clientId ancien + nouveau) attachées à la même app
  matchent SIMULTANÉMENT → **rotation 0-coupure par recouvrement de stratégies**.
- **R5** : détach + DELETE de la stratégie → un token FRAIS matche ENCORE (cache/
  registre runtime ; le mapping fantôme survit aux runs — un clientId ayant un jour
  porté une stratégie supprimée rend `Application:null` durablement). **Retrait ≠
  révocation** : révoquer = désactiver le client sur l'IdP / suspendre l'app.
- **R2bis (sécurité)** : token VALIDE (signature+aud OK) sans stratégie matchante →
  le backend est atteint en `Application:sys:defaultApplication` — pas de 401,
  malgré `applicationLookup=strict`. À fermer avant toute opposabilité par app.

**Livrable pipeline** (Ansible-only, lisible Jenkins — demande utilisateur) :
`ansible/strategy-rotation.yml` + `roles/apim_selfservice_app/tasks/rotate-strategy.yml`
— phase `overlap` (pose + attache la stratégie du nouveau clientId, additif strict)
puis phase `retire` (détache + supprime par clientId, fail-closed si l'app resterait
sans identité, avertissement retrait≠révocation). **Prouvé E2E sur le lab** :
overlap sur `demo-consumer-idp` → 4 stratégies ; retire → `authStrategyIds`
octet-identiques à l'origine, objet stratégie purgé.

**Conséquence design** (mémoire `oracle-idp-gateway-sync`) : le pipeline de
provisioning pilote la STRATÉGIE (clientId imposé = clé d'idempotence ET identité
runtime) ; l'identifier de claim reste projetable pour la doc/UI mais n'est pas un
contrôle ; la rotation d'un client OAuth2 (OIG ou local) = overlap → bascule →
retire + révocation SUR L'IdP.

## 2026-07-24 — L'API `provisioning` qui fronte Jenkins sur la gateway (skeleton fail-closed) ★

Concrétise le point de bascule du design (OIG/CLI2 sont des APPLICATIONS ; ils
n'attaquent jamais Jenkins en direct) : `scripts/setup-provisioning-api.sh`
(10/10, idempotent, crée aussi le job cible `provisioning-webhook`) pose sur wM
10.15 une API `provisioning/1.0` routée vers le Generic Webhook Trigger de Jenkins.

PROUVÉ :
- **Routing gateway → Jenkins** : le corps GWT renvoie `{"triggered":true,
  "resolvedVariables":{"caller":"<cid>"}}` — l'appel qui traverse la gateway
  déclenche bien un build (oracle = corps GWT, PAS nextBuildNumber qui ment via
  quiet-period). Routing figé via archive-patch (`endpointUri` =
  `http://jenkins:8080/generic-webhook-trigger/invoke?token=stoa-provisioning`).
- **Fail-closed anonyme** : sans stage IAM l'API était OUVERTE (sans token →
  200 + build). Après ajout du stage IAM strict/oAuth2Token (action partagée
  a5a8a079), sans token → **401**. C'est la différence entre « router vers
  Jenkins » et « n'y laisser router que des appelants ».
- **Deux appelants = deux applications** : clients KC `oig-provisioner` /
  `cli2-provisioner` (aud=provisioning), une stratégie OAUTH2 par appelant
  (clientId = son client), app + identifier azp + souscription.

FINITION IDENTIFIÉE (honnête) : l'API bâtie en REST NU n'a PAS le binding
**inbound-auth** (issuer/JWKS/introspection) que `labctl apply` câble via
`targets.yaml`. Conséquence : l'app EST identifiée (`Application:oig-provisioner`
dans l'erreur) mais le JWT n'est pas validé → « Token invalid or expired » (401).
Contre-preuve : le MÊME token KC passe l'auth sur `accounts-read` (→404 backend)
et échoue sur `provisioning` (→401) — c'est bien un manque de config niveau-API,
pas d'identité. L'état livré est donc **fail-closed** (rejette tout le monde tant
que le trust n'est pas câblé) — sûr, non fonctionnel pour les appelants.
→ Étape suivante = FederationTarget labctl (comme accounts-read/wm-admin-self)
routé vers Jenkins, qui câble le trust ET, via l'**introspection distante**,
ferme le trou audience R2bis (un token aud≠provisioning est alors rejeté).

TROU R2bis rappelé et MESURÉ ici : la 3e voix (tiers `accounts-read-consumer`,
aud=accounts-read) est actuellement rejetée (fail-closed global), mais le point à
garder est que SANS enforcement d'audience un token valide d'une autre API
passerait en `sys:defaultApplication` — d'où l'introspection en finition.
