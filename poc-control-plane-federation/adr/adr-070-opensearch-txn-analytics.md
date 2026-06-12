---
title: "ADR-070 — Analytics transactionnelle centralisée OpenSearch multi-tenant : collecteur normalisant comme point de contrôle unique, RBAC par fournisseur"
sidebar_label: "ADR-070 : Analytics OpenSearch multi-tenant"
status: "Proposé — en attente Council 8/10 (GO/NO-GO)"
date: 2026-06-11
adr_number: 70
visibility: private
note: "Privé (stoa-labs). S'appuie sur ADR-067 (reuse-first), ADR-068 (hors data-plane), ADR-069 (douve de rétention). Ne pas porter dans stoa-docs (public)."
---

# ADR-070 — Analytics transactionnelle centralisée OpenSearch multi-tenant

**Statut :** Proposé — en attente validation Council 8/10 (GO/NO-GO).
**Date :** 2026-06-11.
**Contexte client (anonymisé) :** institution financière régulée (anonymisé).
**Lié à :** [[adr-067-reuse-first-owned-portable-layer]], [[adr-068-stoa-off-the-transaction-path]], [[adr-069-retention-moat-governance-source-of-truth]].

> ⚠️ **Confidentialité.** Positionnement + données synthétiques bancaires. Vit dans `stoa-labs` (privé), **pas** dans `stoa-docs` (public).

---

## Décision (test « archi 40 ans / 30 secondes »)

> On centralise l'analytique transactionnelle des N gateways dans **UN OpenSearch de gouvernance**, avec **un index par fournisseur/tenant** (`txn-{tenant}-*`) et un **RBAC par index-pattern**. Les gateways **émettent seulement** (méta + body tronqué/conditionnel) vers **Redpanda** ; **un collecteur unique (Data Prepper)** est le **SEUL** endroit où l'on **normalise** au schéma commun `stoa.txn`, **redacte de façon déterministe** (IBAN/soldes/PII) et **route** vers l'index du tenant. La redaction et le schéma vivent **à un seul endroit, auditable**.
> **Frontière nette** : OpenSearch = audit/gouvernance/per-fournisseur (rétention longue, RBAC strict) ; **OTel/LGTM = ops/SRE temps réel**. Corrélation par **traceId** (+ un `request_id` déterministe anti-sampling). **Aucune duplication** du transactionnel dans Loki.
> **Test** : *un fournisseur voit-il UNIQUEMENT ses transactions ? La redaction est-elle appliquée à UN seul endroit auditable ? Le schéma est-il identique quelle que soit la gateway ?* — si non aux trois, ce n'est pas la cible bancaire.

---

## Contexte et problème

Besoin : une **analytique transactionnelle centralisée sur OpenSearch** (tous les appels, succès + erreur), avec **RBAC par fournisseur/tenant** — un fournisseur ne voit **que** ses transactions. Le RBAC impose une gestion **par index** (index-par-tenant, ou tenant×API). Contenu retenu : **métadonnées + payload REDACTÉ** (jamais le body complet ; IBAN/soldes/PII redactés). Séparément et plus tard : la stack OTel temps réel (Grafana/Tempo/Loki/Prometheus) — penser la **coexistence**.

Chaque gateway a **sa** façon d'émettre, et elles sont **hétérogènes** :
- **APISIX 3.11** : plugins logger (kafka-logger/elasticsearch-logger) + OTel ; index/topic **statique par route** (pas de routage runtime par tenant).
- **webMethods 10.15** : policy Log Invocation + **UNE** destination ES, index **non-paramétrable** ; ne supporte pas OpenSearch en data store interne → OpenSearch central **séparé**.
- **WSO2 4.5** : analytics fichier (`apim_metrics.log`) relu par Fluent Bit ; **pas** de routage tenant→index natif, **pas** de payload natif, **pas** de redaction native.

L'utilisateur propose, pour wM, une **« GLOBAL policy filtrée par TAG → un index par tenant »**. Il faut trancher sa faisabilité réelle.

La valeur STOA en jeu (ADR-067) : **neutralité vendor** — « Define Once → Observe Everywhere ». Si le schéma commun est défini **N fois** côté gateway, on a **N sources de vérité** et l'ajout d'un 4ᵉ runtime re-câble un schéma entier. Pour une banque, l'**auditabilité d'UNE règle de redaction** prime.

## Forces en présence (decision drivers)

- **Conformité** : un IBAN ne doit **jamais** être indexé en clair → un **point de redaction déterministe unique**, auditable.
- **Neutralité vendor** : un **schéma commun** et un **pattern d'index** identiques pour les 3 gateways (et le 4ᵉ).
- **RBAC par fournisseur** : isolation **physique** par index + rétention séparable par tenant (douve ADR-069).
- **Hors data-plane** (ADR-068) : labctl **configure**, ne **traite** pas les transactions ; les briques d'ingestion sont du **commodity OSS** (Bac B), pas du custom STOA dans le flux.
- **Reuse-first** (ADR-067) : Redpanda, Data Prepper, Keycloak, OTel **réutilisés**, pas reconstruits.
- **Coexistence OTel** : éviter la duplication ; corrélation par traceId ; frontières RBAC distinctes.

## Options considérées

1. **★ Collecteur-central normalisant** — Gateways → Redpanda → Data Prepper (normalise + redacte + route) → OpenSearch index-par-tenant. **Retenu.** Point de contrôle unique, schéma + redaction centralisés, RBAC homogène.
2. **Hybride tag-à-la-source + routage-collecteur** — même squelette, mais une part d'enrichissement/redaction **à la source** (Data Masking wM, custom MetricReporter WSO2). *Rejeté comme cible* (mais **greffé** en partie) : réintroduit une **double-vérité** (redaction inégale à la source) → auditabilité diluée. Plusieurs de ses idées sont **conservées** (cf. Décision retenue).
3. **Direct-Write** — chaque gateway écrit OpenSearch (zéro collecteur). *Rejeté comme cible* : schéma défini 3 fois (3 sources de vérité) ; **aucun** point de redaction déterministe (IBAN en clair possible) ; wM = compat ES8 fragile + index non-templatable (casse la rétention par tenant, rupture ADR-069) ; WSO2 = Fluent Bit obligatoire (pas « direct »). **Utile uniquement** comme tranche de démo APISIX rapide.

## Décision retenue

**Architecture** : `Gateways → Redpanda (3 topics par gateway) → Data Prepper → OpenSearch (txn-{tenant}-*)`. **OTel/LGTM en parallèle** pour l'ops.

**Greffes intégrées au gagnant (Option 1) :**
- **[d'Option 2] Topics par gateway** (`stoa.txn.apisix|webmethods|wso2`) consommés par UNE source kafka multi-topics — fidélité au natif, lag/debug par-gateway — convergeant vers le **même** schéma `stoa.txn`.
- **[d'Option 2] Réutiliser le crochet Ansible wM** (`apply-policies-to-api.yml` : loggingPolicy + logDestinations KAFKA + redactPatterns) comme premier émetteur (reuse-first).
- **[d'Option 2] `request_id` déterministe** en plus du traceId W3C : filet **anti-sampling** (si la trace n'est pas échantillonnée, `$opentelemetry_trace_id` est vide — issue #7903 — la corrélation audit↔ops casse).
- **[d'Option 2] Variante collecteur léger Go** (modèle `log_writer` : buffer 500/flush 5s, circuit-breaker fail-open) si Data Prepper s'avère lourd pour le PoC.
- **[d'Option 3] Corrélation OTel au plus près APISIX** : `opentelemetry` + `kafka-logger` dans le **même** bloc plugins de route ; activer `set_ngx_var=true` (absent du `config.yaml` actuel) pour stamper le `trace_id` à la source.
- **[d'Option 3] Tranche de démo APISIX frugale** (0 conteneur côté gateway) pour prouver la boucle labctl, **puis** poser Data Prepper/OpenSearch.

**Schéma commun `stoa.txn`** (champs typés) : `tenant/provider/api/api_version/gateway` (routage+identité), `trace_id/span_id/request_id` (corrélation), `@timestamp/status/http_*/latency_ms` (résultat), `consumer_id/user_name/user_ip/user_agent` (PII, FLS), `request_body/response_body` (redactés, jamais bruts) + `redaction_applied/redacted_fields` (audit), `retention_tier/schema_version` (gouvernance). Les 3 mappings d'entrée convergent ici.

**Index** : **index-par-tenant** par défaut (`txn-{tenant}-%{yyyy.MM.dd}`, routé par `${tenant}` au collecteur), `index-par-tenant-par-API` pour gros fournisseurs (tiering + ISM delete obligatoires), **DLS partagé** uniquement en échappatoire haute-cardinalité (rétention non séparable → fragilise ADR-069).

**Redaction** : **collecteur = autorité** (allow-list de champs, substitute_string IBAN/soldes, exclude_keys PII) ; gateway = best-effort (troncature/conditionnel/en-têtes) ; **FLS = affichage seulement** (la donnée brute reste indexée → redaction OBLIGATOIRE en amont).

**RBAC** : rôle `tenant-{tenant}-viewer` ↔ index-pattern `txn-{tenant}-*` ; FLS sur champs `_meta.pii=true` ; Dashboards multi-tenancy (saved objects, **pas** les données) ; **SSO OIDC Keycloak** (realm `stoa-lab`) ; `roles_mapping` group/claim KC → rôle tenant (remplace les backend_roles statiques codés en dur).

**Rétention/ISM** : une policy ISM par pattern `txn-{tenant}-*`, durée par `retention_tier` (régulé ~7 ans, standard 90j, short 30j — à confirmer compliance) ; rollover + delete provisionnés par labctl (modèle `init-opensearch.sh`).

**Verdict wM « global policy filtrée par tag → index par tenant »** : **faisable comme ACTIVATION/ÉMISSION** (la global policy + le tag ACTIVENT le logging/masking et stampent le champ `tenant`), **INFAISABLE comme ROUTAGE d'index** (destination ES unique, index non-paramétrable). → **garder wM en émetteur, déléguer le routage d'index au collecteur**. C'est l'alternative collecteur qui réconcilie l'idée avec la réalité des destinations wM.

**Coexistence OTel** : OpenSearch = audit/gouvernance/per-fournisseur (RBAC tenant cloisonné, rétention longue) ; LGTM = ops/SRE temps réel (SRE transverse). Corrélation par `trace_id` (+ `request_id` anti-sampling). **Ne pas** réinjecter le transactionnel dans Loki ; OpenSearch reste l'autorité.

**Decision gate** (tout nouvel élément d'analytique transactionnelle) — **trois questions** :
1. **La redaction passe-t-elle par UN point unique auditable ?** Non → on retombe dans la double-vérité (Option 2/3) → re-router au collecteur.
2. **Le schéma `stoa.txn` est-il produit identique quelle que soit la gateway ?** Non → source de vérité multiple → dette C2.
3. **L'isolation tenant est-elle PHYSIQUE (index-pattern) avec rétention séparable ?** Non → fragilise la douve ADR-069 → préférer index-par-tenant à DLS partagé.

## Conséquences

**Positives**
- **Un seul point de redaction déterministe auditable** (exigence bancaire) ; un seul schéma → neutralité vendor (ADR-067).
- **RBAC + rétention par fournisseur** physiques (index-pattern) → douve ADR-069 renforcée (source de vérité transactionnelle autoritative, coût de sortie élevé).
- **Hors data-plane** (ADR-068) : labctl configure ; le flux ne traverse aucun composant STOA-propriétaire ; ingestion = commodity OSS (Bac B).
- **Coexistence OTel propre** : corrélation par traceId sans duplication ; frontières RBAC nettes.
- **Démo progressive** : APISIX frugal d'abord (boucle labctl prouvée vite), collecteur ensuite.

**Négatives / risques (assumés)**
- **4 services à ajouter** (Redpanda + Data Prepper + OpenSearch + Dashboards) : **non présents** dans `docker-compose.poc.yml` aujourd'hui (le contexte « Redpanda déjà là » est **faux** dans ce repo) → `opsComplexity` réelle, impact DoD Phase 1.
- **Gap d'implémentation** : `log_writer`/`provisioner` (index par tenant, DLS/FLS/ISM) = code STOA Python **non présent** → à **porter** en Go/sidecar. Aucun adapter telemetry WSO2 STOA (plus gros gap). kafka-logger APISIX, moteur PII, artefacts OpenSearch : **à construire** (la mention « PII masker éprouvé » est **aspirationnelle**).
- **À valider sur instances live** : (1) wM Data Masking sur la donnée **stockée** vers destination (option « Apply for ») ; (2) global policy « filter by tag » 10.15 ; (3) push subscriptions sous licence **trial** (perte au reset → fallback poll) ; (4) export WSO2 4.5 → Kafka (custom MetricReporter/Fluent Bit non testé) ; (5) compat `_bulk` ES8/OpenSearch de l'`elasticsearch-logger` APISIX (cible ES7) → préférer kafka-logger→collecteur.
- **« Soldes/montants »** non couverts par les patterns PII par défaut → PIIType bancaire custom, sinon ne pas logger ces champs.
- **Cardinalité tenants** : index-par-tenant-par-API risque l'explosion de shards → tiering + ISM delete ; bascule DLS partagé documentée comme échappatoire, pas nominal.
- **Sampling agressif** en prod : sans `request_id` déterministe, la corrélation audit↔ops casse (issue #7903) — d'où la greffe.

## Non couvert / différé (à tracer ailleurs)

- **Atterrissage prod OTel** (otel-lgtm = image dev/démo) : Tempo/Loki/Prom séparés, rétention → topologie d'observabilité prod, hors de cet ADR.
- **Routage souveraineté** (un tenant régulé → cluster OpenSearch isolé via conditional routing Data Prepper) → cas régulé dédié.
- **Sync dynamique group Keycloak → role OpenSearch** (remplaçant les backend_roles statiques) → tâche d'implémentation labctl.
- **Durées de rétention par tier** (DORA 7 ans ?) → cadrage compliance avec le client.

## Références

- [[adr-067-reuse-first-owned-portable-layer]] (reuse-first, Bac B commodity), [[adr-068-stoa-off-the-transaction-path]] (hors data-plane), [[adr-069-retention-moat-governance-source-of-truth]] (douve de rétention / source de vérité).
- PoC `stoa-labs` — `docker-compose.poc.yml` (services présents), `targets.yaml` (owner/system = base tenant), `labctl/internal/adapter/apisix/publish.go` (`sharedPlugins`/`routeLabels` = levier de projection), `gateways/apisix/config.yaml` (OTel sans `set_ngx_var`).
- OpenSearch Data Prepper (kafka source / opensearch sink / `index: ${tenant}` / conditional routing), OpenSearch Security (role↔index-pattern, FLS/DLS, OIDC), ISM (rollover/rétention).

## Definition of Done de cet ADR

- Validé Council **8/10** (GO/NO-GO).
- La decision gate « redaction unique / schéma unique / isolation physique » est applicable telle quelle.
- Le verdict wM (« émission oui, routage d'index non → collecteur ») est tranché et documenté.
- La liste des 4 services à ajouter + les gaps d'implémentation sont explicites (pas de « déjà présent » faux).


---

## Décisions par défaut retenues (2026-06-11) — pour avancer

| # | Question ouverte | Défaut retenu | Note |
|---|---|---|---|
| 1 | Collecteur | **Data Prepper** (déclaratif, reuse-first) ; Go léger = repli | empreinte à surveiller à côté des JVM WSO2/wM |
| 2 | Topics | **3 topics par gateway** convergeant vers `stoa.txn` | lag/debug séparés |
| 3 | Granularité index | **index-par-tenant** `txn-{tenant}-*` | -par-API option gros fournisseurs |
| 4 | Rétention/tier | prod **7a/90j/30j** ; PoC compressé **7j/3j/1j** | ⚠️ 7 ans (DORA) à confirmer compliance |
| 5 | Solde/montant | **PIIType custom `MONETARY`, redacté** | comme IBAN |
| 6 | Redaction wM | **collecteur = autorité unique** ; masking wM best-effort validé | ne bloque pas |
| 7 | wM subscriptions | **poll** (robuste reset trial) | push+reconciler = prod |
| 8 | Export WSO2 | **Fluent Bit sidecar** | MetricReporter custom = prod |
| 9 | APISIX→store | **kafka-logger → collecteur** | évite risque `_bulk` ES8 |
| 10 | Socle / ordre | **poser les 4 services**, câbler APISIX → wM → WSO2 (1 tenant d'abord) | pas de tranche jetable |
| 11 | DLS partagé | index-par-tenant ; bascule DLS si **> ~1000 tenants** | seuil à affiner |
| 12 | SSO Dashboards | **OIDC realm `stoa-lab`** + `role_mapping` projeté par labctl ; watcher dynamique différé | « même IdP » API+analytics |
| 13 | ADR | **070, `visibility: private`** | — |

**Plan de build dérivé** : (1) socle 4 services (Redpanda/OpenSearch/Dashboards/Data Prepper) ; (2) tranche APISIX bout-en-bout 1 tenant (kafka-logger+tag → Data Prepper normalise/redacte/route → OpenSearch + RBAC/ISM/SSO) ; (3) wM (Log Invocation+poll) puis WSO2 (Fluent Bit). La passe monitoring = tranche (2).

---

## Raffinements à la mise en œuvre (2026-06-11) — tranche APISIX prouvée live

La **tranche (2)** du plan de build est **réalisée et validée en live** sur la stack
locale (données synthétiques). Trois raffinements de l'ADR, fidèles à la décision
retenue, sont actés à l'usage :

### 1. Data streams par tenant (raffinement du modèle d'index)

Le modèle d'index nominal `txn-{tenant}-%{yyyy.MM.dd}` est raffiné en **data stream
OpenSearch par tenant** (`txn-{tenant}` → backing indices `.ds-txn-{tenant}-NNNNNN`,
ex. `txn-accounts-team` / `.ds-txn-accounts-team-000001`). C'est le **même** objectif —
isolation physique par fournisseur, rétention séparable (douve ADR-069) — exprimé
avec l'abstraction native d'OpenSearch pour les données append-only horodatées :
rollover/ISM gérés par le data stream, write index unique, **aucune écriture directe**
sur un backing index. Conséquence sur le RBAC : le rôle `tenant-{tenant}-viewer` couvre
**à la fois** l'alias (`txn-{tenant}*`) **et** les backing indices
(`.ds-txn-{tenant}-*`) — sinon la recherche derrière l'alias est refusée (les `.ds-*`
ne sont pas couverts par `txn-{tenant}*`). La decision gate Q3 (isolation **physique**
par index-pattern, rétention séparable) tient telle quelle.

### 2. Coexistence OTel rendue concrète — le pivot `trace_id`

La « coexistence OTel » (corrélation par `trace_id`, sans duplication dans Loki) n'est
plus seulement un principe : elle est **matérialisée et validée empiriquement**. Un
appel data-plane réel produit le **même `trace_id` W3C** dans les deux plans —
une **trace dans Tempo** (`service.name=apisix`, span `opentelemetry-lua` réel) **et**
un **document transactionnel dans OpenSearch** (`txn-accounts-team`) — et l'on
**pivote bidirectionnellement** : correlation Grafana Tempo→OpenSearch (trace→txn) +
data link sur `trace_id` côté table OpenSearch (txn→trace). **Condition** confirmée :
`plugin_attr.opentelemetry.set_ngx_var=true` dans `gateways/apisix/config.yaml` (absent
par défaut, cf. la greffe [d'Option 3]) — sans quoi `$opentelemetry_trace_id` est vide
dans le `log_format` kafka-logger et la corrélation casse. Le filet `request_id`
déterministe reste l'anti-sampling. **OpenSearch demeure l'autorité du transactionnel ;
Loki n'en reçoit aucune copie.** Frontières RBAC distinctes inchangées.

### 3. Identification `oAuth2Token` (cohérence strategy OAuth2)

Côté **identité entrante** des APIs (ADR-068 : labctl *configure*, ne *traite* pas),
l'action IAM webMethods qui borde l'analytique transactionnelle passe de
`identificationType=jwtClaims` (signature seule) à **`identificationType=oAuth2Token`**
(chemin strict, `applicationLookup=strict`) — **cohérent avec la strategy `OAUTH2`**
projetée : scope toujours imposé, application (`azp`) liée, **aucune régression** vs le
mode `openIdClaims` antérieur. (L'identifiant d'application reste mappé sur la dimension
`openIdClaims` de la strategy ; c'est l'**action** qui bascule en `oAuth2Token`.)
Note de portée : sur l'image **trial 10.15**, l'**audience** (`aud`) n'est **pas
opposable** (la validation JWKS offline ne vérifie jamais `aud` ; l'introspection
distante RFC 7662 — qui l'opposerait — est **câblée mais inerte** sous trial). Le
mécanisme est prêt pour un build capable ; gap documenté dans `EVIDENCE.md`.

**Provisioning reproductible** : `observability/opensearch/provision/provision.sh`
(idempotent, 7 étapes : template data-stream + ISM + tenant Dashboards + rôle/FLS +
user + roles-mapping + index-pattern saved-object) reproduit **tout** à blanc — miroir
de ce que `labctl` projette. Côté bridge OTel : `observability/grafana/provisioning/`
(+ `apply.sh` pour la correlation, source Tempo read-only). La redaction reste **au seul
collecteur** (`observability/data-prepper/pipelines.yaml` : IBAN/MONETARY/PII), capture
stricte **succès=méta / erreur=response_body+headers redactés**, jamais le request body.
