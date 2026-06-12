# HANDOFF — PoC Control Plane de Fédération (stoa-labs)

> État au 2026-06-12. À lire en premier pour reprendre. Données synthétiques,
> client anonymisé (institution financière régulée anonymisé). Repo : `stoa-platform/stoa-labs` (privé).

## TL;DR

PoC **validé live de bout en bout** : un control plane souverain (briques OSS) **fédère
3 gateways hétérogènes** — WSO2 (commercial), Apache APISIX (OSS), webMethods (réel
10.15) — sous **une identité Oracle-master** (Dex→Keycloak). **6/7 preuves live**, la 7ᵉ
(souveraineté) par construction. Observabilité **fédérée et reliée** : OTel/LGTM
(ops/SRE, 2 runtimes) **+** analytics transactionnelle OpenSearch par fournisseur
(ADR-070) **+** pivot `trace_id` trace↔transaction **validé empiriquement** (WSO2 OTel
en suivi). Barrière OAuth2 wM **3/4 opposable** (audience câblée, non opposable sur
trial 10.15).

## Mise à jour 2026-06-12 — CI multi-env webMethods : promotion-from-Git + proxy admin (ADR-075)

La feature « promotion » wM (copie d'état opaque via une 2ᵉ gateway dédiée) est **remplacée**
par un **rebuild-from-Git idempotent par env** + **aliases wM** (les différences par env vivent
dans la VALEUR des aliases, l'asset est identique en Git). Démo `scripts/demo-multienv.sh`
**19/19 PASS** (contre-épreuves incluses). Pensé multi-env, applicable mono-env.
- **Chaîne d'envs** : `environments.yaml` à la racine du repo governance (`dev→rec→int→prod`,
  gates par hop : dev→rec self-approvable ; rec→int `approverGroup: int-team` (claim `groups`) ;
  int→prod 4-yeux + `change_ref`+`pv_ref` + **gate ITSM fail-closed** (mock `cmd/itsm-mock`,
  CHG-0001 approved / CHG-0002 draft ; 409 `ITSM_NOT_APPROVED`, 503 si injoignable)). Absent ⇒
  fallback dev→staging→production (zéro test cassé).
- **Pinning réel + rollback** : la promotion capture le SHA du contrat (`deploy.{env}.yaml:
  commit`, 409 `CONTRACT_MOVED` si le contrat bouge entre demande et approbation) ; `apply-uac
  --env X` projette le contrat **au SHA pinné** (`git show`). Rollback = endpoint
  `POST …/promotions/{id}/rollback` (restaure le deploy N-1 **avec son pin**, marker
  `rolled_back`, evidence motivée+change_ref ; 1er déploiement ⇒ 409 `NO_PREVIOUS_STATE`),
  puis re-apply idempotent. **Jamais de DELETE.**
- **Topologie lab** (`docker-compose.envs.yml`) : 3 mocks wM (dialecte 10.15 complet, réécrits —
  `labctl apply` passe contre eux, data-plane probant résolvant `${alias}`) sur réseau `nonprod`
  **internal**, AUCUN port ; le trial réel (= PROD) est le seul pont `[poc, nonprod]`. Contre-épreuve :
  `docker exec poc-jenkins getent hosts wm-mock-dev` → échec.
- **Proxy admin as-code** (remplace la gateway de promotion) : **3 APIs sœurs** `wm-admin-{env}`
  publiées PAR labctl sur le wM prod (contrat allowlist = les 17 chemins admin que labctl utilise,
  AUCUN DELETE) ; backend = endpoint alias `wm-admin-{env}` → mock de l'env ; outbound = credential
  alias (Basic admin de l'env, valeurs Vault `secret/stoa/envs/{env}/wm-admin` posées par l'AppRole
  `proxy-provision` — **Jenkins ne porte jamais les creds hors-prod**, contre-épreuve 403) ; inbound =
  OAuth2 `ci-horsprod` scopes `deploy:{dev,rec,int}` (PAS prod). Matrice `setup-wm-admin-proxy.sh`
  **15/15** (401 sans token, 401 mauvais scope, 200 légitime, 404 hors allowlist, 405 DELETE).
- **labctl** : adapter wM `bearerTokenFile` (XOR Basic, 0600) ; `routing.endpointAlias`/
  `credentialAlias` par target (`routing.go`, shapes 10.15 capturés live : `endPointURI`,
  PUT policyActions **enveloppé** sinon no-op silencieux, password credential alias en **base64**,
  action outbound **imbriquée** `transportSecurity` sinon NPE 500) ; `strategyName` dérivé par API ;
  fix `additionalProperties: true` (booléen) qui cassait le PUT de re-apply 10.15.
- **CI** : `ci/Jenkinsfile` = hors-prod (webhook `stoa-ci`, boucle dev→rec→int, **Git est le gate** —
  un env sans deploy mergé est skippé en narration) ; `ci/Jenkinsfile.prod` (AUCUN trigger, 1 paramètre
  `PROMOTION_ID`, gate Git-natif rejoué avant dispatch, smoke 401) ; `ci/Jenkinsfile.rollback` (1 clic
  exploit). ⚠ jobs Jenkins prod/rollback à créer dans Jenkins (sans GenericTrigger) + push Gitea pour
  que le job existant voie le nouveau Jenkinsfile.
- **Bringup** : compose envs → `setup-vault-envs.sh` → `setup-vault-approle.sh` (rôle
  `proxy-provision`) → `setup-ci-horsprod.sh` → `setup-wm-admin-proxy.sh` → `demo-multienv.sh`.
  ⚠ le dual-home du trial exige un recreate (config dans l'ES externe, rien ne se perd) ; en session
  un `docker network connect stoa-labs-poc_nonprod poc-webmethods-real` suffit.

## Mise à jour 2026-06-12 — Secrets depuis Vault (ADR-074, concrétise gap (d) d'ADR-072)

Les secrets plateforme ne vivent plus en placeholders `targets.yaml` / env / credentials
Jenkins : ils sont dans **Vault**, **lus à l'exécution**, **rotables sans rebuild**. Prouvé LIVE :
- **Infra** : service `vault` (hashicorp/vault dev-mode) dans `docker-compose.poc.yml`
  (`localhost:8200` / interne `vault:8200`, root token PoC `stoa-root-token`). Secrets KV v2
  `secret/stoa/{gateways/{wso2,apisix,webmethods},keycloak,ci,opensearch}` via `scripts/setup-vault.sh`.
- **Code** : paquet **`internal/vault`** (KV v2 REST via `internal/httpx`, **zéro dép vendorée**) ;
  wrapper **`cmd/labctl/loadResolvedTargets`** (override creds gateway + Keycloak ; `internal/targets`
  reste pur) appelé par apply/subscribe/plan/apply-uac ; **onboarding-api** prend `OPENSEARCH_PASSWORD`
  de Vault si vide ; **Jenkinsfile** ne porte plus qu'**un** credential `vault-token`.
- **Sémantique** : `VAULT_ADDR` set → Vault **autoritaire** (override), 404 → fallback littéral,
  403/transport → erreur fail-closed ; **sans** `VAULT_ADDR` → littéraux (**rétro-compat totale**).
- **Preuves** : `labctl apply` avec Vault → 3/3, **mauvaise clé Vault → APISIX 401** (lecture live),
  sans Vault → 3/3 ; onboarding-api sans `OPENSEARCH_PASSWORD` + Vault → 201 + doc audit ; stage CI
  **in-agent** → 9/9, **0 secret en clair** ; `scripts/test-vault-rotation.sh` **3/3** ; suite `-race`
  verte ; data-plane **3/3** préservé. **ADR-074** écrit.
- **Durcissement identités éphémères (addendum)** : root token statique → **AppRole least-privilege**
  (`scripts/setup-vault-approle.sh`). Policies par chemin `stoa-labctl` (gateways+keycloak) / `stoa-ci`
  (ci+opensearch) ; rôle `ci-pipeline` (les 2). Tokens **éphémères TTL 3min** (role_id non-secret +
  secret_id court). Prouvé live : token labctl→gateways 200/ci **403**, token ci→inverse, **aucun root**.
  `internal/vault` : token via **`VAULT_TOKEN_FILE`** (0600) OU **login AppRole** (`VAULT_ROLE_ID`+
  `VAULT_SECRET_ID`/`_FILE`). labctl apply via AppRole → 3/3 ; stage CI in-agent → **9/9, 0 fuite**.
- **Reste pour le VRAI job** : credential Jenkins **`vault-ci-secret-id`** (mint :
  `setup-vault-approle.sh --mint ci-pipeline`) + env Jenkins **`VAULT_ROLE_ID`** (non-secret). Prod :
  secret_id just-in-time (Vault Agent/response-wrap) + `num_uses=1` + rotation auto + Vault scellé.

## Mise à jour 2026-06-12 — traces du wM RÉEL dans Tempo (ADR-073)

Le trou « seul le mock webMethods émet de l'OTel » est **fermé** : le wM réel 10.15
trace désormais dans Tempo (`service.name=webmethods`), **corrélé au `trace_id`
client**. Vérifié live : appel `accounts-read` avec `traceparent` connu → trace
Tempo (span SERVER + span CLIENT `native GET`, parent = span du client).

- **Pas d'OTel natif en 10.15** (ni 10.11 ni 11.1 — vérifié doc IBM) ; le « Trace
  API » du gateway est un tracer de debug **inroutable** (couplé API Data Store).
  **Révision même jour : E2EM écarté pour la cible (produit payant, refus
  client) → le pont est la voie retenue PoC ET cible**, et les 4 conditions de
  durcissement sont **traitées en OSS** : (1) ingestion **durable-first** —
  l'event brut va dans Redpanda AVANT tout traitement, les spans sont émis par
  un consumer Kafka (groupe `wm-trace-bridge-spans`) → bridge/Tempo down = les
  events attendent dans le topic (résidu : l'entrée HTTP se réplique derrière
  un LB en cible) ; (2) charge : `scripts/wm-loadcheck.sh` (p50/p95 policy
  ON/OFF) ; (3) fixpack : `scripts/wm-contract-check.sh` re-valide chaque
  comportement non documenté contre le gateway vivant (via
  `GET /debug/last-event` du bridge) ; (4) angle mort 401 : poller des
  `policyviolationevents` de l'ES gateway → **spans Error dans Tempo**
  (`WM_PV_POLL_URL`, 30 s). **Règle découverte au passage** : un 401 SANS header
  Authorization (non-preemptive) ne génère AUCUN event côté gateway (log
  `YAI.0102.0018I` explicite) — seuls les rejets avec token invalide
  (preemptive, le cas « attaque ») produisent un PolicyViolation ; l'anonyme pur
  ne se voit que dans `sag_apigw_apicalls_total{code="401"}`. Tout le détail :
  `adr/adr-073-wm-traces-tempo.md`.
- **Pont PoC** : global policy « Transaction logging » (Log Invocation, headers ON
  / payloads OFF) → custom destination `StoaTraceBridge` (External endpoint) →
  `wm-trace-bridge` (Go, `observability/wm-trace-bridge/`, service compose dans
  `docker-compose.wm.yml`) → OTLP `otel-lgtm:4318`. Setup **idempotent** :
  `./scripts/wm-otel-setup.sh` (destination+policy persistées dans l'ES externe →
  survivent keepalive ET recreate ; les `watt.*` survivent au restart seulement).
  Le span natif utilise la **fenêtre exacte** `externalCalls.callStartTime/callEndTime`
  de l'événement (champ non documenté, capturé in-situ), repli `providerTime`.
- **Gotcha majeur découvert in-situ** : Log Invocation référence une custom
  destination par `{destinationType:"CUSTOM", ids:["<nom>"]}` — le param `ids`
  n'est **documenté nulle part** (capturé sur ce que l'UI enregistre) ; les autres
  formes sont acceptées par l'API mais ignorées au runtime. Le dispatcher POSTe
  1 event JSON/req, latence ~10-40 s, champs numériques nullables.
- **Métriques** : `/metrics` (anonyme, `sag_apigw_api_*`) scrapé par le Prometheus
  d'otel-lgtm (`observability/prometheus/prometheus-wm.yaml`, overlay wm —
  remplace le fichier ENTIER de l'image). Compteurs remis à zéro par le keepalive
  → lire en `increase()`. **⚠️ Gotcha overlay** : otel-lgtm doit être (re)créé
  avec **les deux `-f`** pour porter ce mount ; un `./scripts/up.sh` (base seule)
  le **recrée SANS** → scrape wM perdu + historique Tempo/Prom effacé, sans
  erreur. Après un up.sh : `docker compose -f docker-compose.poc.yml -f
  docker-compose.wm.yml up -d otel-lgtm` (puis re-régénérer du trafic).
- **Y analytics (révision même jour)** : le bridge publie aussi le JSON **brut**
  de chaque event Transactional sur Redpanda `stoa.txn.webmethods` (env
  `WM_TXN_KAFKA_BROKERS`, vide = désactivé) → pipeline Data Prepper
  `stoa-txn-webmethods` (normalisation wM → schéma stoa.txn, redaction, capture
  stricte, pivot `trace_id` extrait du traceparent stocké) → OpenSearch
  `txn-{tenant}`, comme APISIX. **Vérifié live** : doc `gateway=webmethods` avec
  `trace_id` = traceparent client. ⚠️ noms de payloads LIVE ≠ swagger
  (`nativeRequestPayload`/`nativeResponsePayload`) — couverts dans le drop.
  Erreurs sans `response_body` (payloads OFF à la source, assumé ADR-073).
  Dashboard : row « webMethods réel » ajoutée à `/d/stoa-fed-overview`
  (sag_apigw_* : tx/min par API, erreurs par code dont les 401 invisibles en
  traces, latence gateway vs backend).
- **Suite** : span natif positionné en fin de fenêtre (approximation) ; les events
  **PolicyViolation (401) ne sont PAS dispatchés** vers la custom destination
  (2 essais, abonnement ERROR+POLICYVIOLATION posé — ils vont bien dans l'ES
  interne ; piste : ces event types ne partent peut-être vers les destinations
  que depuis les policies d'alerte Monitor SLA, pas des rejets IAM). Les 401
  restent visibles via `sag_apigw_api_tx_error_count` et la voie analytics
  ADR-070 ; le bridge sait les convertir si un jour ils arrivent (testé sur
  fixture). WSO2 OTel toujours en suivi.

## Mise à jour 2026-06-12 — Médiation control-plane sur gateway mutualisée (ADR-072)

Passe « médiation » : fermer les 4 gaps du plan de contrôle sur une gateway **mutualisée**
(« on ne fait pas confiance au dev à 100 % »). **Modèle à 2 plans** — écriture
(`onboarding-api`) + convergence (`labctl apply-uac`). Itérations toutes **prouvées LIVE** :

- **It.0** Fondation sécu fermée : `internal/audit/audit_test.go` + matrice live onboarding
  (`scripts/test-onboarding-matrix.sh` **8/8** : 201 / 403 tenant_mismatch / 403 missing_role /
  401 + docs audit ACCEPT/DENY frais, pivot `trace_id`).
- **It.1** Noyau authz extrait dans **`internal/authz`** (`BearerToken`/`HasRole`/`TenantOf`/
  `ClientIP` + rôles `partner-onboarder`/`cp-applier`) — une seule vérité, `onboarding-api`
  re-câblé, **régression nulle**.
- **It.2** **Scoping tenant enforce** sur `apply-uac` (`scripts/test-apply-scope.sh` **11/11**) :
  intégrité `tenant_id`==chemin (anti-spoof, `internal/uac`), flag `--tenant`/`$LABCTL_TENANT`,
  token `cp-applier` (`$LABCTL_TOKEN`) qui **borne** le scope → **cross-tenant DENY** fail-closed
  avant tout dispatch. Code : `cmd/labctl/scope.go`.
- **It.3** **Attribution + audit de chaque mutation** (`scripts/test-apply-audit.sh` **13/13**) :
  `audit-apply-{tenant}`, `actor`=auteur du commit Git (ADR-069), `principal`=SA `cp-applier`,
  `commit_sha`, **pivot `trace_id`**, isolation viewer. Code : `cmd/labctl/applyaudit.go` +
  `internal/audit` (champs `resource`/`gateway`/`principal`) + provisioning
  `observability/opensearch/provision/apply/`.
- **It.4** **Rate-limit** du plan dev-facing (`scripts/test-onboarding-ratelimit.sh` **3/3**) :
  token-bucket par `actor+tenant` → `429` audité `rate_limited`. Code : `cmd/onboarding-api/ratelimit.go`
  (env `ONBOARDING_RATE_PER_MIN`, défaut 20).
- **It.5** **Démo end-to-end 2 tenants × 2 plans** (`scripts/demo-mediation.sh` **11/11**) :
  `banking-demo` + `payments-team` onboardent ET appliquent **leur propre API sur les mêmes
  gateways**, cross-tenant refusé partout, isolation **symétrique**. **ADR-072** écrit.

**Tenants canoniques** : `banking-demo` (re-tag de `accounts-read`, ex-`accounts-team`) +
`payments-team` — alignés sur Keycloak (`onboarder-banking`/`onboarder-payments`, rôles
`partner-onboarder`+`cp-applier`) et OpenSearch. `backstage.owner` re-taggé dans `targets*.yaml` ;
viewer txn `tenant-banking-demo-viewer` provisionné (`provision-banking-demo-txn.sh`).
**Data-plane re-vérifié 3/3** après re-tag (`phase3-identity-demo.sh`). **Gap (d)** (creds admin
toutes-puissantes) **acté + compensé** : le control plane EST la couche de scoping ; les creds
plateforme ne quittent jamais la CI ; non rétrofité sur `accounts-read` (data-plane préservé).
**Traces RÉELLES (post-passe)** : exporter OTLP/HTTP-JSON **stdlib zéro dép** dans `internal/audit`
→ un span par event vers `$OTEL_EXPORTER_OTLP_ENDPOINT/v1/traces` ; le `trace_id` (hex) du doc
OpenSearch est désormais un **span requêtable dans Tempo** (`scripts/test-otlp-traces.sh` 4/4).
**Compte de service CI** : `scripts/setup-ci-applier.sh` (client confidentiel `ci-applier`,
**client_credentials seul**, rôle `cp-applier`+tenant — pas de password ni creds gateway). Stage
médiation câblé dans `ci/Jenkinsfile` (clone `ci/governance`, mint ci-applier, `apply-uac --tenant`
+ OPENSEARCH/OTEL internes, **split-horizon** `KEYCLOAK_JWKS_URL`). **Prouvé LIVE dans l'agent
`poc-jenkins`** : build air-gapped Go1.26, **9/9 publications**, audit `actor=service-account-ci-applier`,
spans Tempo. **Reste** : déclencher le VRAI job (webhook) exige le **credential de push Gitea
`ci/stoa-labs`** (clone anon OK, push non — non deviné). Jenkins `:18080`, job `stoa-federation`.

Suites notées : déclenchement webhook Jenkins (push Gitea), rate-limit multi-réplicas (compteur
partagé), namespacing ressources, index-pattern OSD `txn-banking-demo`.

## Mise à jour 2026-06-11 — data-plane fermé sur 3 gateways RÉELLES

Le point resté ouvert (« invocation data-plane prouvée seulement sur APISIX/wM mock »)
est **fermé** — et le mock sort de la preuve :

- **webMethods RÉEL** (`softwareag/apigateway-trial:10.15`, `docker-compose.wm.yml`,
  UI `:19072`, data-plane `:5555/gateway/{api}/{version}`) remplace le mock dans
  `targets*.yaml`. UN token Oracle-master (alice via Dex→KC, `azp=accounts-read-consumer`)
  → **200 sur les 3** ; sans token / signature octet-altérée / JWT forgé clé attaquante /
  token realm `master` → **401 sur les 3** (matrice adversariale complète dans `EVIDENCE.md` §2026-06-11).
- **`inboundAuth` projeté par labctl** (la nouveauté structurante) : bloc optionnel du
  manifeste (`targets.yaml` + `targets.cluster.yaml`). Sur **wM** : alias auth-server
  externe `KeycloakStoaLab` (issuer `localhost:8480`, JWKS `keycloak:8080`) + action
  IAM « Identify & Authorize » (`jwtClaims`, `allowAnonymous=false`) — `webmethods/inboundauth.go`.
  Sur **APISIX** : plugin `openid-connect` (discovery in-network, `bearer_only`+`use_jwks`)
  posé sur chaque route au publish ET préservé au subscribe — `apisix/inboundauth.go`.
  **`apply` est convergent** : il ne peut plus écraser l'auth (c'était le bug du jour —
  l'étape §3/3 de `setup-identity.sh` devient redondante pour les routes projetées).
- **WSO2** : le 401 sur token valide = KM Keycloak enregistré mais pas chargé au runtime
  → `docker restart poc-wso2am` (gotcha déjà documenté, confirmé).
- `phase3-identity-demo.sh` cible le vrai wM et passe de bout en bout.

**Nouveaux gotchas / suites** :
- L'image **trial wM est instable** (redémarrages spontanés JVM/OSGi, boot 3-7 min,
  `restart: unless-stopped` la relève) — prévoir ça en démo ; la config projetée survit.
- wM : l'**identification applicative n'est pas projetée** — tout JWT valide passe en
  `sys:defaultApplication` (`applicationLookup=open`). Suite : lier `azp` → application
  (identifiers JWT claims sur `labctl-live-consumer`).
- `apply` **ne ramasse pas** les routes hors manifeste (pas de prune) : les routes APISIX
  `customer-referential-*` (200 SANS token) et `payments-initiation-*` (404 — service
  jamais importé dans Microcks) datent d'un apply antérieur sur un manifeste plus large.
  Le run CI (`targets.cluster.yaml` porte `inboundAuth` + `observability`) re-projette
  `accounts-read` correctement sur les 3 gateways (`openid-connect` + rewrite + kafka-logger
  côté APISIX) ; pour purger `customer-referential-*`/`payments-initiation-*` côté APISIX
  il faut les publier via le manifeste ou ajouter un prune.

### Topologie de ports webMethods (vérifiée in-situ 2026-06-11)

Le **data-plane d'invocation enforced** est le port **5555** (IS HTTP) :
`http://localhost:5555/gateway/{api}/{version}/...` → 200 avec token / **401 sans**
(le moteur API Gateway journalise le refus : index ES `…policyviolationevents`). C'est
aussi ce que route le Caddyfile du VPS source (`vps-wm.gostoa.dev → localhost:5555`).
**9072/9073 = console UI** (HTTP/HTTPS), **pas** le data-plane (un `/gateway/...` y rend
404 + HTML Tomcat). Mappés hôte : `:19072` (HTTP), `:19073` (HTTPS, ajouté ce jour).
La config (APIs/policies/alias) vit dans l'**ES externe** (`poc-wm-es`, volume) → un
`docker compose … up -d --no-deps --force-recreate webmethods-real` **ne perd rien**
(boot ~3 min ; image **amd64 émulée sur arm64** = lenteur/instabilité, `restart: unless-stopped`).

### ✅ Régression APISIX fermée (le CI fait `apply`, PAS `apply-uac` — précision 2026-06-11)

**Reformulation corrigée** (l'ancienne note « `apply-uac` (CI) rouvre le trou » était
imprécise) :

- **Le CI ne lance PAS `apply-uac`.** `ci/Jenkinsfile` fait : (1) build `labctl`
  **air-gapped frais** depuis le repo (`go build -trimpath`, `vendor/`, `GOPROXY=off`) ;
  (2) `apply -f targets.cluster.yaml` ; (3) `get apis`. `labctl` est **rebuild à chaque
  run** — il n'y a pas de « vieux binaire d'image » sur le chemin `apply`.
- **D'où venait la régression** : un `targets.cluster.yaml` jadis **périmé** (sans
  `inboundAuth`) appliqué par un **ancien code adapter** qui ne projetait pas
  `openid-connect`. Une route ré-appliquée perdait alors le barrage entrant (200 sans
  token) et le `kafka-logger`.
- **Ce qui la ferme** : (a) `inboundAuth.discoveryUrl` **dans `targets.cluster.yaml`**
  (target apisix) ; (b) l'adapter qui **projette ET préserve** `openid-connect` au
  `Publish` (`internal/adapter/apisix/inboundauth.go`, `publish.go`) ; (c) le **fix #9** :
  ne **jamais** poser `key-auth` quand `inboundAuth` est actif (`consumer.go`) ;
  (d) le bloc `observability` (target apisix) qui re-projette `kafka-logger` à chaque
  `apply` (ajouté ce jour à `targets.cluster.yaml`, sinon le run CI strippait
  `kafka-logger`). Set de plugins projeté = `{openid-connect, opentelemetry,
  proxy-rewrite, kafka-logger}`, **sans key-auth** ; data-plane **200 avec token / 401
  sans** (vérifié live).
- **`apply-uac`** projette **déjà** `inboundAuth` : il réutilise la **flotte** du
  manifeste via `t.ToConfig()` (`cmd/labctl/applyuac.go`), donc il pose `openid-connect`
  exactement comme `apply`. Son **seul écart** était le `backend_url` des **contrats UAC**
  (slug périmé `…/rest/accounts-read/1.0.0` au lieu de `…/rest/Accounts+Read+API/1.0.0`).
  Corrigé dans les **fixtures** (`internal/uac/uac_test.go`) ; un **test bout-en-bout**
  (`internal/adapter/apisix/uac_projection_test.go`,
  `TestApplyUAC_APISIXProjectsOpenIDConnectAndAccountsRewrite`) prouve que la projection
  UAC porte `openid-connect` + le rewrite vers `Accounts+Read+API`.
- **Gouvernance Gitea — FAIT (2026-06-11)** : le `backend_url` du contrat
  `tenants/banking-demo/apis/accounts-read/api.yaml` (repo `ci/governance`) est
  aligné sur `…/rest/Accounts+Read+API/1.0.0` (2 occurrences, lignes 12 & 16),
  via l'API Contents de Gitea (commit serveur dans le repo de **gouvernance**, pas
  dans ce repo PoC — la consigne « pas de commit git » vise le repo PoC). Le clone
  local `console-light/var/governance-repo` a été resync (ff `pull`). 0 occurrence
  du slug périmé `…/rest/accounts-read/1.0.0` côté Gitea et côté clone.

## Mise à jour 2026-06-11 — observabilité fédérée OTel + analytics ADR-070 reliées

**Les deux plans d'observabilité sont câblés ET reliés** par le `trace_id` W3C
(ADR-070). État live confirmé :

- **Plan OPS/SRE** — OTel/LGTM (`poc-otel-lgtm`) : Grafana http://localhost:3000
  (**ouvert, pas d'auth** — `/api/datasources` répond sans creds) + Tempo/Loki/
  Prometheus (3 datasources). APISIX + wM émettent OTel natif (OTLP 4317/4318).
- **Plan GOUVERNANCE/AUDIT** — OpenSearch https://localhost:9201
  (`admin` / `Stoa!Passw0rd2026`, `-k`) + Dashboards http://localhost:5601.
- **Dashboard de fédération** : **« STOA — Fédération (OTel + Transactions) »**,
  uid `stoa-fed-otel-txn` → http://localhost:3000/d/stoa-fed-otel-txn (live v6,
  6 panneaux dont la **table OpenSearch**). Datasource `OpenSearch-Txn` (type
  `elasticsearch`, OpenSearch 2.x) ajoutée.
- **Pivot trace ↔ transaction (BIDIRECTIONNEL, validé)** : `trace_id` réel
  `73ffd5332255a5de453384d4bc45eb4c` présent dans les **deux** plans (Tempo HTTP 200,
  `service.name=apisix`, span `opentelemetry-lua` réel **+** 1 doc OpenSearch
  `gateway=apisix status=success`). (1) **trace→txn** : correlation Grafana
  Tempo→OpenSearch-Txn (uid `efotpn446a5fkc`, `field=traceID`,
  `trace_id:"${__value.raw}"`) — posée par `apply.sh` (la datasource Tempo est
  read-only → pas provisionnable par fichier). (2) **txn→trace** : data link sur le
  champ `trace_id` du panneau table OpenSearch → Explore Tempo.

**Reproductibilité (les deux côtés, idempotent)** :

```bash
# 1) Provisioning OpenSearch à blanc (data stream + tenant + rôle/FLS + index-pattern)
observability/opensearch/provision/provision.sh          # 7 étapes idempotentes
# 2) Bridge Grafana (datasource OpenSearch + dashboard + correlation Tempo→OS)
observability/grafana/provisioning/apply.sh              # live, re-PUT par uid
```

- **Fichiers reproductibles Grafana** : `observability/grafana/provisioning/`
  (`datasources/opensearch-txn.yaml`, `dashboards/federation-otel-transactions.json`,
  `correlations/tempo-to-opensearch.yaml`). Bind-mountés dans otel-lgtm pour un `up`
  à froid ; `apply.sh` = le chemin live/impératif (et le SEUL chemin pour la
  correlation, source read-only). **NE PAS casser otel-lgtm ni les 3 datasources
  existantes.**
- **Provisioning OpenSearch** : `observability/opensearch/provision/` (01 template
  data-stream, 02 ISM, 03 rôle+FLS+tenant_perms, 04 user, 05 rolesmapping, 07 tenant
  Dashboards, 08 index-pattern saved-object ; `provision.sh` câble tout). **Reflète
  l'état LIVE** : `index_patterns` = `txn-accounts-team*` + `.ds-txn-accounts-team-*`,
  `masked_fields` PII, `tenant_permissions accounts-team → kibana_all_read`.

**Chaîne analytics (ADR-070, tranche APISIX bout-en-bout)** :
APISIX **kafka-logger** → topic `stoa.txn.apisix` (Redpanda `poc-analytics-redpanda`)
→ **Data Prepper** (`poc-analytics-data-prepper`, `observability/data-prepper/pipelines.yaml`,
**seule autorité de redaction** : IBAN/MONETARY/PII) → data stream `txn-accounts-team`.
Capture stricte : **succès = méta seule ; erreur = méta + response_body + headers
redactés** ; **jamais** le request body. Le `trace_id` exige
`plugin_attr.opentelemetry.set_ngx_var=true` dans `gateways/apisix/config.yaml`
(sinon `$opentelemetry_trace_id` vide → trace_id synthétique non corrélable — c'était
le piège, corrigé).

**Projeté par labctl** (pas posé à la main) :
- **kafka-logger APISIX** : `labctl/internal/adapter/apisix/kafkalogger.go` — projeté
  quand un bloc *observability/tenant* est au manifeste, sur chaque PUT de route
  (publish + re-PUT subscribe). Contraintes APISIX gérées : `log_format` FLAT
  obligatoire (sinon crash `:byte()` au log phase), `batch_max_size=1` (sinon Data
  Prepper rejette le START_ARRAY), kafka-logger dans la liste `plugins:` statique de
  `config.yaml`.
- **wM `oAuth2Token`** : l'action IAM est passée LIVE en
  `identificationType=oAuth2Token` (chemin strict `applicationLookup=strict`) au lieu
  de `jwtClaims` — projeté dans `webmethods/inboundauth.go`/`oauth2.go`. Cohérent avec
  la strategy `OAUTH2`, scope toujours imposé, **aucune régression**.

**Build air-gapped TOUT vert** (rejoué ce jour) :
`cd labctl && GOPROXY=off GOFLAGS=-mod=vendor go build ./... && go vet ./... &&
go test -count=1 ./...` → build OK, vet OK, tests OK (tous les paquets).

### État audience wM — 3/4 leviers opposables

Barrière OAuth2 wM (10.15 trial) : **signature/azp/scope opposables** (mesurés) ;
**audience câblée mais NON opposable** sur le trial. Diagnostiquée par 2 leviers :
(1) **introspection distante inerte** (`remoteIntrospectionConfig` câblé dans
`inboundauth.go` — `introspectionEndpoint` + `introspectionUser` requis par le
validator 10.15 — mais l'`aud` n'est pas opposé sous trial) ; (2) **`oAuth2Token`**
impose scope+application, pas l'audience sur ce runtime. Mécanisme **prêt pour un
build capable** ; gap documenté dans `EVIDENCE.md` (Preuve 5 bis). Ne pas bloquer
dessus.

### Gotchas observabilité (pour qui reprend)
- **Grafana ouvert (pas d'auth)** : provisionner via `/api/datasources`,
  `/api/dashboards/db`, `/api/datasources/uid/tempo/correlations` (live) **ET** écrire
  les fichiers `observability/grafana/provisioning/`. Tout idempotent.
- **wM flappe** (trial ~25 min, `restart: unless-stopped`) : si un test live wM
  échoue par flap, **noter et continuer** — ne pas bloquer.
- **trace_id synthétique** : un doc OpenSearch avec un trace_id de test
  (`e2e5xxerrtrace0001`) n'est PAS corrélable à Tempo. Toujours valider avec un
  **appel réel** → trace_id non synthétique présent dans les deux plans.
- **NE PAS toucher WSO2** (instable) pour l'OTel ; **NE PAS casser** otel-lgtm.

## Où c'est

```
poc-control-plane-federation/
├── PLAN.md POSITIONING.md HARD-CRITERIA-MAP.md EVIDENCE.md   # cadrage + preuves
├── README.md                                                # quickstart + état des phases
├── docker-compose.poc.yml  .env.example                     # socle (9 briques OSS)
├── docker-compose.ci.yml   ci/                              # CI bank-réaliste (Gitea+Jenkins)
├── apis/accounts-read.openapi.yaml                          # le contrat "Define Once"
├── targets.yaml (host)  targets.cluster.yaml (in-network)   # manifeste de fédération
├── labctl/   (+ vendor/ → build air-gapped)                 # l'orchestrateur (3 adapters)
├── mocks/webmethods/                                        # gateway legacy (Go, OTel + JWKS)
├── identity/{dex,keycloak}/  gateways/apisix/config.yaml      # (set_ngx_var pour trace_id)
├── observability/
│   ├── grafana/provisioning/{datasources,dashboards,correlations}/ + apply.sh   # bridge OTel↔txn
│   ├── opensearch/provision/{01..08}*.json + provision.sh     # data-stream/tenant/RBAC/FLS/index-pattern (ADR-070)
│   └── data-prepper/pipelines.yaml                            # collecteur normalisant/redactant
└── scripts/{up,down,teardown,smoke-test,demo,setup-identity,phase3-identity-demo,get-oracle-token,setup-wso2-otel}.sh
adr/  (privé)  adr-067 reuse-first · adr-068 hors-transactionnel · adr-069 douve de rétention · adr-070 analytics OpenSearch
```

## État des phases (toutes validées live sauf mention)

| Phase | Quoi | État |
|---|---|---|
| 0 | Plan + cadrage + ADR-067 | ✅ |
| 1 | Socle OSS (9 briques) | ✅ live |
| 2 | `labctl` Define Once → 3 gw (57 tests) | ✅ live |
| 3 | Identité Oracle-master (Dex→Keycloak→3 gw) | ✅ live |
| 4 | EVIDENCE + dashboard Grafana fédération | ✅ live |
| 5 | Analytics ADR-070 (tranche APISIX : data-stream/RBAC/FLS/redaction + pivot trace↔txn) | ✅ live |

## Reprendre la démo (stack up)

```bash
cd poc-control-plane-federation
./scripts/up.sh                      # 9 briques (WSO2 lent ~3min)
./scripts/demo.sh                    # publish + catalogue + subscribe + appels authentifiés
# Phase 3 (identité) — séquence à 2 temps pour WSO2 :
./scripts/setup-identity.sh          # enregistre le KeyCloak KM (+ APISIX oidc + prérequis KC)
docker restart poc-wso2am            # OBLIGATOIRE : WSO2 charge les KM au DÉMARRAGE
./scripts/setup-identity.sh          # re-run : map-keys réussit (KM chargé)
./scripts/phase3-identity-demo.sh    # 1 token Oracle (alice via Dex) → 200 sur les 3 gw
./scripts/smoke-test.sh
```

## Accès (synthétique)
- WSO2 Publisher/Devportal : https://localhost:9443/{publisher,devportal} — `admin`/`admin`
- Keycloak admin : http://localhost:8480/admin/ — `admin`/`admin` — realm `stoa-lab` (users `alice@bc.example`/`password`)
- Grafana : http://localhost:3000 — **ouvert (pas d'auth)** — dashboard `stoa-fed-otel-txn`
- OpenSearch : https://localhost:9201 (`admin`/`Stoa!Passw0rd2026`, `-k`) · Dashboards http://localhost:5601 · viewer tenant `accounts-viewer` (mdp dans `observability/opensearch/provision/04-internaluser-accounts-viewer.json`)
- Microcks : http://localhost:8585 — APISIX admin : `X-API-KEY: poc-apisix-admin-key` (9180)
- Clients : `poc-gateways`/`poc-gateways-secret` ; `accounts-read-consumer` (secret dans `labctl-credentials.txt`, gitignoré, régénéré par `subscribe`)

## Gotchas (pour qui reprend)
- **WSO2 : `docker restart` (pas recreate)** — recreate efface l'état H2 (APIs, KM, subs). Restart préserve + recharge le KM.
- **KM WSO2** : utiliser le connecteur **`KeyCloak`** (pas `default`=WSO2-IS → NPE `keyManagerServiceUrl`). Nécessite côté KC : un **client scope `default`** + rôles **`manage-clients`/`view-clients`** sur `poc-gateways` (le connecteur fait du DCR avec `scope=default`). `setup-identity.sh` applique tout ça (idempotent).
- **Issuer** : `KC_HOSTNAME=http://localhost:8480` épingle `iss` → tous les tokens (service-account ET broker Oracle) valident partout ; JWKS fetché en interne (`keycloak:8080`, BACKCHANNEL_DYNAMIC).
- **Keycloak recreate** efface les clients runtime (`accounts-read-consumer`) → re-jouer `demo.sh`.
- **`.env*` non éditables** (permission) → etcd (`quay.io/coreos/etcd`), port KC (`8480`), `JWT_ISSUER` sont **épinglés en dur dans le compose**.
- **`labctl` build air-gapped** : `cd labctl && GOPROXY=off GOFLAGS=-mod=vendor go build` (deps dans `vendor/`).
- **WSO2 OTel** : `setup-wso2-otel.sh` est **EXPÉRIMENTAL** — la config naïve a cassé le démarrage du gateway (reverté). À affiner avant usage.

## Décisions stratégiques (ADR privés — en attente Council 8/10)

| ADR | Décision | Council |
|---|---|---|
| 067 | Reuse-first — couche possédée portable, runtimes commodity fédérés (règle des 3 bacs) | **CONDITIONAL 6.8/10** |
| 068 | STOA **hors du chemin transactionnel** ; Reverse Invoke transactionnel = **capacité gateway**, pas STOA ; agent control-plane sortant-only (ou pull GitOps) | **CONDITIONAL 7.1/10** |
| 069 | **Douve de rétention** = gouvernance source-de-vérité vendor-neutral + fabric maintenue/garantie (survit à SAP+Joule ET à un pull GitOps) | Proposé |
| 070 | **Analytics transactionnelle OpenSearch multi-tenant** : collecteur normalisant = point de redaction unique auditable, RBAC/index par fournisseur, coexistence OTel (pivot trace_id) — **tranche APISIX prouvée live** | Proposé |

**Modèle d'exploitation acté** : **CLI-en-CI / GitOps pull**, **pas d'agent runtime**, build **air-gapped** (vendor/), **binaire signé exécuté par LEUR CI** (Jenkins) — zéro flux entrant. Scaffold CI : `docker-compose.ci.yml` + `ci/` (Gitea+Jenkins+webhooks), **à valider au premier run**.

## Conditions Council — état

- ✅ **Traitées (doc)** : C3-068 (evidence-pack cohérent), C2-068 (gate DORA + secrets→PAM/Vault), C4-067 (intention/médiation dans la gate), C2-067 (douve nommée = ADR-069).
- ⏳ **Business (à toi)** : **C1-067** chiffrage BUILD/RUN 5 ans (barrière n°1 à l'auto-balle) · **C3-067** propriété juridique du Bac possédé · **C4-068** stratégie d'entrée GTM (hors-zone d'abord) + partenaire ESN qualifié.
- ⏳ **Technique** : **C1-068** prouver que l'agent bat un pull GitOps (sinon : pas d'agent) · must-prove ADR-069 « autorité, pas miroir » + « garantie, pas homme-jour ».
- ⚠️ **Angles morts Council (non instruits)** : le deal BC existe-t-il + est-il réplicable (2ᵉ logo jamais nommé) · SAP+Joule = scénario central, pas de queue · **chiffrer la fenêtre multi-runtime** (la variable la plus déterminante).

## Threads ouverts (prochaines actions possibles)

1. **Ansible** (dernier échange) : « on a Ansible, pourquoi le CLI ? » → **rider Ansible** (Bac B), livrer STOA en **collection Ansible** OU `labctl` appelé depuis un playbook. Floor honnête : s'ils ne valorisent ni la logique maintenue ni la gouvernance, pas de deal. **À faire** : scaffolder un exemple Ansible + acter « outillage = Bac B » dans ADR-067.
2. **Valider la CI Jenkins live** (Gitea+Jenkins+webhook → un commit fédère l'API).
3. **Re-soumettre 067/068/069 au Council** après les arbitrages business.
4. **Backstage/RHDH** : non déployé ; le positionner comme **wedge produit hors-zone** (réponse partielle C4-068), pas comme preuve technique.
5. **Reverse Invoke (data-plane)** : c'est une **capacité gateway** à vérifier produit par produit (webMethods ✓, WSO2/APISIX/SAP à confirmer) — pas un jet STOA.

## Comment c'est construit
~6 workflows multi-agents (design+vérif adversariale, implémentation parallèle, review, fix, Council) + débogage live. Leçon récurrente : **la vérification adversariale réduit le risque, l'exécution live confirme la vérité** (ex. WSO2 `deploy-revision`=201 vs 200 que la vérif avait inversé ; connecteur KeyCloak vs default ; etc.).
