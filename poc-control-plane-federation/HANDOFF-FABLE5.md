# Handoff Fable 5 — État du labs STOA & plan séquencé (durcir → graduer)

> Analyse : stoa-labs (PoC control-plane-federation, accounts-team, console-light, stoa-platform-ci, adr) en profondeur ; monorepo `stoa` lu pour les points de raccordement. Date : 2026-07-03.

---

## 0. Verdict en une phrase

Le labs a **prouvé sa thèse** — un control plane sur briques OSS fédère 3 gateways hétérogènes (WSO2, APISIX, webMethods **réel** 10.15) sous identité Oracle-master, avec une discipline de preuve rare (scripts à compteurs 8/8, 11/11, 13/13, 19/19, `go test ./...` vert). Ce qui reste n'est plus « est-ce que ça marche » mais **(A) transformer l'aspirationnel documenté en enforcement réel** et **(B) faire atterrir les briques prouvées dans la plateforme `stoa`**, où deux d'entre elles (APISIX, WSO2) n'ont **aucune** existence.

---

## 1. Ce qui marche vraiment (labs)

| Chantier | Statut | Preuve concrète |
|---|---|---|
| Fédération 3 runtimes + Define Once/Expose Everywhere (ADR-071/072) | ✅ PROUVÉ live | `labctl apply` 3/3 gw depuis 1 OpenAPI ; `demo.sh`, `EVIDENCE.md` Preuves 1-4 |
| Identité Oracle-master (Dex→Keycloak→3 gw) | ✅ PROUVÉ live | `phase3-identity-demo.sh` : 1 token → 200×3 avec / 401×3 sans ; wM réel + WSO2 KM + APISIX oidc |
| Médiation control-plane (ADR-072) | ✅ PROUVÉ | `test-onboarding-matrix.sh` 8/8, `test-apply-scope.sh` 11/11, `test-apply-audit.sh` 13/13, `demo-mediation.sh` 11/11 |
| Secrets Vault as-code + rotation (ADR-074) | ✅ PROUVÉ | `internal/vault` KV v2 stdlib, fallback total, AppRole least-privilege (403 croisés labctl↔ci), `test-vault-rotation.sh` |
| CI multi-env sans gateway de promotion (ADR-075) | ✅ PROUVÉ | `demo-multienv.sh` 19/19 ; **vrai Jenkins** (`stoa-prod-deploy #2/#4 SUCCESS`, rollback signé) ; ITSM gate + 4-yeux + pin SHA |
| Analytics txn par fournisseur OpenSearch (ADR-070) | 🟡 PROUVÉ sur tranche APISIX | data-stream + RBAC + FLS + redaction 1-point ; pivot `trace_id` bidirectionnel Tempo↔OpenSearch |
| Traces wM réel → Tempo (ADR-073) | ✅ PROUVÉ (seul ADR « Accepté ») | `wm-trace-bridge` Log Invocation→OTLP, trace réelle vérifiée |
| GitOps cycle de vie API repo-par-projet (ADR-076) | 🟡 SOCLE livré | moteur `internal/render` + gate `INTEGRITY_INCONSISTENT` fail-closed ; enum client **VH/H/M migré** ; mTLS par-API (OAuth2 AND cert) live + Ansible |
| console-light (IHM gouvernance) | ✅ Démo-able E2E | `tsc` clean, Playwright multi-personas, chaîne UI→commit→Jenkins→3 gw réelles→HTTP 200 (`gov-build-6-console.log`) |
| accounts-team (repo-client GitOps type) | ✅ Fonctionnel | `labctl validate` OK, `labctl plan` diff réel contre wM live (1.0.0→1.0.3) |

**5 forces différenciantes réelles :** (1) discipline de preuve (compteurs PASS/FAIL + `exit 1` réels partout) ; (2) Vault as-code fail-closed intelligent (404=fallback légitime, 403/transport=erreur) sans jamais de root token ; (3) auto-critique dans les ADR eux-mêmes (ADR-076 liste ses 7 écarts) ; (4) multi-env sans 2e runtime de promotion (rebuild-from-Git + 3 proxies admin sœurs) ; (5) séparation control-plane/data-plane tenue de bout en bout (Kafka→Data Prepper, jamais la gateway qui traite).

---

## 2. Les gaps réels (prioritisés)

| # | Gap | Nature | Impact |
|---|---|---|---|
| G1 | **« Sécurité = f(intégrité) » non enforced** : le gate valide la cohérence mais ne vérifie pas que `target.yaml` implémente réellement le bundle dérivé ; `reconcile.yml` le fait en lecture seule, sans bloquer | Aspirationnel ADR-076 Phase 3 | Cœur du différenciateur GitOps encore « posé à la main » |
| G2 | **WSO2 OTel cassé** : config OTLP naïve déstabilise le démarrage du gateway → seul des 3 sans traces | Bug/réglage exporteur | Fédération obs = 2/3 runtimes, pas 3/3 |
| G3 | **Analytics parité incomplète** : tranche APISIX prouvée, tranches wM (Log Invocation→Kafka) et WSO2 (Fluent Bit sidecar) différées | Chantier à finir | Claim « par fournisseur » vrai sur 1/3 |
| G4 | **TokenProvider wM outbound câblé à la main** (2 policyActions), pas as-code | Dette de câblage | Rejoue le pattern « posé, pas possédé par l'apply » |
| G5 | **Poly-repo = 1 seul pilote** ; classification d'intégrité encore posée **dans le repo projet** (spoofable), pas dans un repo de gouvernance central | Non testé à l'échelle + faille de confiance | Modèle repo-par-projet pas prouvé au-delà de N=1 |
| G6 | **TOCTOU ITSM prod** : pas de re-check live de l'approbation à l'instant du dispatch | Faille temporelle | Gate contournable en théorie |
| G7 | **console-light** : webhook sur miroir de démo (`var/ci-mirror`), refus 4-yeux non exercé en E2E (`denials.jsonl` vide) | Câblage démo | Preuve E2E pas 100% de bout en bout |
| G8 | **Doc-drift & statut** : `HARD-CRITERIA-MAP.md` dit analytics ❌ NON alors qu'`EVIDENCE.md` la prouve ; tous les ADR 070-076 affichent « Proposé — Council » malgré un socle de code testé ; `accounts-team` VH mTLS câblé sur le mauvais port (:5555 vs :5543), statut `draft` | Hygiène/cohérence | Lecteur pressé rate 90% du travail livré |
| G9 | **audience wM non opposable** sur trial 10.15 (câblé, inerte) ; **dev/rec/int = mocks wM** ; **SSO OIDC OpenSearch** déféré ; **streaming >500 Mo** hors scope | Limites assumées | À garder documentées, pas à masquer |

---

## 3. Carte de graduation labs → `stoa` (points de raccordement)

| Brique labs | Point de greffe `stoa` | Verdict |
|---|---|---|
| Fédération control-plane | `control-plane-api/src/routers/federation.py` (master/sub-account **MCP**) | ⚠️ **Collision conceptuelle** — « fédération » existe déjà mais scope MCP tool-oriented, pas cross-runtime. Décider extend vs nouveau namespace |
| GitOps cycle de vie API | `routers/{api_lifecycle,git,reconciliation}.py` + `tenants/*/apis/*.yaml` | ✅ À réutiliser (drift/sync déjà là) |
| Moteur dérivation intégrité→sécurité | `services/uac_validator.py`, `api_lifecycle.py` | Greenfield côté plateforme — porter `internal/render` + `validate.go` |
| Gateway mTLS/OAuth2 | `stoa-gateway/src/auth/{mtls,oidc,jwt,dpop}.rs` | ✅ Très mature — **réutiliser, ne pas réimplémenter** |
| **APISIX** | — | 🔴 **GREENFIELD — aucune trace** dans le monorepo. Moule = `adapters/template/` + enum `gatewayType` CRD + doc sidecar |
| **WSO2** | — | 🔴 **GREENFIELD — aucune trace**. Idem |
| webMethods / Kong | `adapters/webmethods/`, `adapters/kong/` + doc sidecar | ✅ Prod-ready — réutiliser |
| CLI stoactl | `cli/` (dans le monorepo) | ⚠️ Code source **non tracké** dans le checkout (sparse-checkout cassé ?), **aucune CI** — clarifier avant d'étendre |
| Secrets/Vault | `control-plane-api/src/services/vault_client.py` | ✅ Étendre (chemins KV), ne pas recréer |
| CI multi-env | `.github/workflows/reusable-gitops-deploy.yml`, `promote-to-prod.yml` + repo externe `stoa-infra` (ArgoCD) | ✅ Réutiliser — mais **mapper** les gates (le labs est Jenkins+Ansible, la plateforme est GH Actions+ArgoCD) |
| RBAC / tenants / mTLS par tenant | `auth/rbac.py`, `routers/tenants.py`, `routers/tenant_ca.py` | ✅ Réutiliser |
| CRDs déclaratives | `charts/stoa-platform/crds/` + `stoa-operator` **vs** `tenants/*/apis/*.yaml` | ⚠️ **Deux mécanismes concurrents non unifiés** — le labs doit trancher lequel il étend |

**3 pièges à signaler à l'équipe `stoa` avant toute graduation :** collision « fédération » (MCP vs cross-runtime) ; double source-de-vérité déclarative (CRD K8s vs YAML GitOps) ; anomalie git `cli/src`.

---

## 4. PLAN SÉQUENCÉ — /goal pour Fable 5

> Chaque goal est auto-contenu (contexte + DoD + fichiers) pour être transmis tel quel. Effort : S (<0.5j) · M (1-2j) · L (3j+). Racine labs = `/Users/torpedo/hlfh-repos/stoa-labs`.

### PHASE A — Durcir le labs (rendre l'aspirationnel réel)

---
**/goal A1 — Enforcer « sécurité = f(intégrité) » (fermer l'aspirationnel ADR-076 Phase 3)**
- **Contexte** : le gate `governance.ValidateUAC` échoue en `INTEGRITY_INCONSISTENT` si le manifeste est incohérent, mais ne vérifie PAS que la gateway applique réellement le bundle de sécurité dérivé de la classification d'intégrité. C'est `reconcile.yml` qui le constate, en lecture seule, sans bloquer un merge.
- **Objectif** : faire du bundle dérivé un contrat *enforced* — au `labctl apply`, projeter le bundle (OAuth2/mTLS/rate-limit) selon la classification ET refuser (fail-closed) si le read-back gateway ne le confirme pas.
- **Critères d'acceptation** : un `target.yaml` VH sans mTLS effectif sur la gateway → apply **bloqué** (exit≠0, code explicite) ; un script de preuve type `test-integrity-enforce.sh` avec compteur PASS/FAIL et contre-épreuves ; `reconcile` passe de « rapport » à « gate » ou reste en défense-en-profondeur documentée.
- **Fichiers** : `poc-control-plane-federation/labctl/internal/render/`, `internal/governance/validate.go`, `stoa-platform-ci/deploy/reconcile.yml`, `accounts-team/target.yaml`.
- **Effort** : L. **Priorité** : 🔴 la plus haute (cœur du différenciateur).

---
**/goal A2 — Réparer WSO2 OTel → fédération d'observabilité 3/3 runtimes**
- **Contexte** : WSO2 4.5 embarque `opentelemetry-all` mais la config OTLP naïve (`name="otlp"` → otel-lgtm:4317) déstabilise le démarrage du gateway. APISIX + webMethods émettent déjà vers Tempo.
- **Objectif** : trouver le réglage exporteur OTLP correct (gRPC vs HTTP, endpoint/format) pour que WSO2 trace sans casser son démarrage, OU documenter proprement un sidecar OTel de repli.
- **Critères d'acceptation** : `service.name=wso2` visible dans Tempo sur un appel data-plane réel ; stack stable après `up.sh` ; `EVIDENCE.md` Preuve 6 passe de « 2/3 » à « 3/3 ».
- **Fichiers** : `scripts/setup-wso2-otel.sh`, `observability/`, `gateways/` (config WSO2).
- **Effort** : M. **Priorité** : 🟠.

---
> ✅ **A1 FAIT (2026-07-03).** Gate d'enforcement livré : découverte `api.yaml`
> colocalisé (ou `--uac`), pré-check statique `[INTEGRITY_UNFULFILLED]` avant toute
> écriture, read-back gateway `[ENFORCEMENT_UNCONFIRMED]` post-publish (verifier
> wM complet : strategy + scope mapping + action IAM toutes-règles + throttle LMT +
> logInvocation global + transport). Preuve `scripts/test-integrity-enforce.sh`
> **31/31 live** (contre-épreuve sabotage incluse) ; `go test ./...` vert ;
> chaîne CI fermée (deploy-one.yml api.yaml obligatoire, PR-gate couplage) ;
> docs à jour (ADR-076, EVIDENCE, accounts-team, stoa-platform-ci). Résiduels
> actés : anti-spoof classification → A5 ; APISIX/WSO2 read-back → A3/B1.

---
> ✅ **A2 FAIT (2026-07-03).** Cause racine au BYTECODE (`OTLPTelemetry.class`) :
> le tracer OTLP ne lit que `url` (jamais hostname/port) ET exige une entrée
> `properties` non vide, sinon NPE au boot (= la « déstabilisation »). Config
> correcte dans `setup-wso2-otel.sh` (gRPC `http://otel-lgtm:4317` + header
> factice + `resource_attributes service.name=wso2`). Prouvé : Tempo liste
> `['apisix','webmethods-mock','wso2']`, trace wso2 complète (Key_Validation →
> Backend_Latency), stack stable, zéro erreur d'export. EVIDENCE Preuve 6 → 3/3.

---
**/goal A3 — Compléter l'analytics par fournisseur (parité 3/3)**
- **Contexte** : ADR-070 prouvé sur la tranche APISIX (kafka-logger→Data Prepper→OpenSearch). Les tranches webMethods (Log Invocation→Kafka) et WSO2 (Fluent Bit sidecar) sont différées.
- **Objectif** : câbler les deux tranches manquantes vers le **même** OpenSearch, avec la **même** redaction 1-point et le pivot `trace_id`.
- **Critères d'acceptation** : 1 doc txn par gateway pour un appel réel, isolé par tenant, redacté (succès=méta seule, erreur=body+headers redactés) ; `trace_id` corrélable Tempo↔OpenSearch pour les 3 ; provisioning idempotent étendu.
- **Fichiers** : `observability/data-prepper/pipelines.yaml`, `observability/opensearch/provision/`, `wm-trace-bridge/`, adaptateurs `labctl/internal/adapter/{webmethods,wso2}/`.
- **Effort** : L. **Priorité** : 🟠.

---
> ✅ **A3 FAIT (2026-07-03).** Parité analytics txn 3/3. Le vrai reste-à-faire était
> WSO2 seul (APISIX + wM déjà livrés). Insight décisif : les logs fichier WSO2 ne
> portent AUCUN trace_id → « Fluent Bit sidecar » = impasse ; la seule source avec le
> trace_id W3C = les spans OTel (débloqués par A2). Livré : `wso2-otel-tap` (Go,
> récepteur OTLP/gRPC → forward Tempo + record `stoa.txn.wso2` par trace, trace_id
> natif) + pipeline `stoa-txn-wso2` (miroir apisix) + service compose (overlay
> analytics) + `setup-wso2-otel.sh` repointable. Preuve `scripts/test-txn-wso2.sh`
> **12/12** : pivot Tempo↔OpenSearch (même trace_id), dedup 1 doc/trace, 3/3, méta
> seules. Piège pinné : WSO2 exporte en gzip → codec gzip à enregistrer côté serveur.

---
**/goal A4 — TokenProvider webMethods outbound as-code**
- **Contexte** : le TokenProvider IS+Vault (creds body-based wM 10.15) est câblé à la main via 2 `policyActions`, pas projeté par `labctl apply`.
- **Objectif** : porter la config outbound (routing-by-alias + credential alias base64 + action outbound imbriquée sous `transportSecurity`) dans l'adaptateur, projetée à chaque apply, idempotente.
- **Critères d'acceptation** : re-apply idempotent recrée l'auth outbound sans intervention manuelle ; Basic injecté vu par le backend ; changement d'alias suivi immédiatement par le data-plane (déjà prouvé pour le routing, à étendre au TokenProvider).
- **Fichiers** : `labctl/internal/adapter/webmethods/{routing,inboundauth}.go`, `gateways/webmethods/token-provider/`.
- **Effort** : M. **Priorité** : 🟠.

---
> ✅ **A5 FAIT (2026-07-04).** Classification anti-spoof + poly-repo. Autorité de
> classification déplacée de l'`api.yaml` projet (éditable) vers un registre CENTRAL
> (`stoa-platform-ci/governance/classifications.yaml`, repo plateforme non éditable).
> `labctl apply` : bundle dérivé du CENTRAL, clé **(owner, api)** où owner=`LABCTL_PROJECT`
> (PROJECT_NAME du pipeline, non-éditable) → ferme le trou « pointer une ligne plus
> faible » (review B1). Codes : `[CLASSIFICATION_SPOOFED]` (downgrade/tenant), `[CLASSIFICATION_UNGOVERNED]`
> (API absente/empruntée). 2e repo pilote `payments-team` (H/internal, bundle SANS mtls
> ≠ accounts-team VH) déployé par le même pipeline. Preuve `test-classification-central.sh`
> **11/11** (bundles différents, spoof/emprunt/tenant/ungoverned refusés, faux governance/
> projet ignoré). Non-régression A1 : 31/31 live. Sans source → strictement A1.

---
**/goal A5 — Poly-repo réel + classification anti-spoof**
- **Contexte** : le modèle repo-par-projet n'a qu'**un** pilote (`accounts-team`), et la classification d'intégrité vit **dans le repo projet** (donc modifiable par l'équipe = spoofable).
- **Objectif** : (1) ajouter un 2e repo projet pilote (intégrité différente, ex. H ou M) pour prouver l'échelle ; (2) déplacer la classification dans un **repo de gouvernance central** non éditable par l'équipe API (cohérent avec la séparation des devoirs de `stoa-platform-ci`).
- **Critères d'acceptation** : 2 repos projets déployés par le même pipeline plateforme avec bundles de sécurité **différents** dérivés de leur classification centrale ; une PR équipe qui tente de rehausser sa propre classification → refusée (la source fait foi côté gouvernance).
- **Fichiers** : `accounts-team/` (+ nouveau repo frère), `stoa-platform-ci/`, `labctl/internal/render/`.
- **Effort** : L. **Priorité** : 🟠.

---
**/goal A6 — Fermer le TOCTOU du gate ITSM prod**
- **Contexte** : le gate prod (ITSM approved + 4-yeux + pin SHA) est vérifié au moment du merge/build, mais pas re-checké **live** à l'instant du dispatch — fenêtre TOCTOU.
- **Objectif** : re-valider l'approbation ITSM (et le 4-yeux) au dispatch prod, juste avant `apply`.
- **Critères d'acceptation** : une approbation ITSM révoquée entre build et dispatch → apply prod **bloqué** (`409 ITSM_NOT_APPROVED` rejoué au dispatch) ; contre-épreuve ajoutée à `demo-multienv.sh`.
- **Fichiers** : `poc-control-plane-federation/ci/Jenkinsfile.prod`, `envs/prod/`, `scripts/demo-multienv.sh`.
- **Effort** : M. **Priorité** : 🟡.

---
**/goal A7 — console-light : webhook réel + refus 4-yeux exercé E2E**
- **Contexte** : le webhook pointe sur un miroir de démo (`var/ci-mirror`) et le refus self-approval 4-yeux est couvert en unitaire mais jamais exercé en E2E (`denials.jsonl` vide, bouton juste désactivé).
- **Objectif** : brancher le webhook sur le vrai repo de gouvernance et ajouter un spec Playwright qui **tente** une self-approval et capture le refus.
- **Critères d'acceptation** : commit console → vrai repo → Jenkins → déploiement (chaîne déjà verte, sur repo réel) ; spec E2E qui produit une entrée dans `denials.jsonl` avec le refus 403 `SELF_APPROVAL_BLOCKED`.
- **Fichiers** : `console-light/` (config webhook, `ui/`, specs Playwright `50-*`), BFF `labctl/cmd/governance-api/`.
- **Effort** : M. **Priorité** : 🟡.

---
**/goal A8 — Hygiène doc & statut ADR (cheap, haute clarté)**
- **Contexte** : `HARD-CRITERIA-MAP.md` dit analytics « ❌ NON » alors qu'`EVIDENCE.md` la prouve ; les ADR 070-076 affichent tous « Proposé — Council » malgré un socle de code testé ; `accounts-team` câble VH mTLS sur `:5555` (sans enforcement) au lieu de `:5543`, et reste `draft`.
- **Objectif** : (1) réconcilier `HARD-CRITERIA-MAP.md` avec l'état réel ; (2) introduire un **statut à deux axes** dans les ADR (ratification business *vs* maturité technique) ; (3) corriger le port mTLS d'`accounts-team` ou documenter explicitement pourquoi :5555.
- **Critères d'acceptation** : zéro contradiction entre `EVIDENCE.md`, `HARD-CRITERIA-MAP.md` et les tables « PROUVÉ vs ASPIRATIONNEL » des ADR ; en-tête ADR montrant « Code : livré/testé » distinct de « Council : en attente ».
- **Fichiers** : `poc-control-plane-federation/HARD-CRITERIA-MAP.md`, `adr/adr-07*.md`, `accounts-team/{target.yaml,README}`.
- **Effort** : S. **Priorité** : 🟡 (à faire tôt — débloque la lisibilité pour tout le reste).

---

### PHASE B — Graduer vers la plateforme `stoa` (après A)

> Racine plateforme = `/Users/torpedo/hlfh-repos/stoa`. **Décisions transverses B0 à prendre AVANT de coder.**

---
**/goal B0 — Décisions d'architecture bloquantes (à trancher avec l'équipe stoa)**
- **Objectif** : trancher 3 collisions avant tout code de graduation. (1) **Fédération** : le modèle cross-runtime du labs étend-il `routers/federation.py` (MCP master/sub-account) ou vit-il dans un namespace distinct ? (2) **Source de vérité déclarative** : on étend `tenants/*/apis/*.yaml` + `reconciliation.py` (léger, déjà prod) OU on passe par de vraies CRD K8s reconciliées par `stoa-operator` ? (3) **CLI** : pourquoi `cli/src` n'est-il pas tracké dans le checkout (sparse-checkout cassé ?), et où vit la source canonique ?
- **Critères d'acceptation** : un mini-ADR de graduation dans `stoa-docs` (`docs/architecture/adr/`) actant les 3 choix ; référencé par B1-B7.
- **Effort** : S (décision) / **bloque** B1-B5. **Priorité** : 🔴 première.

---
**/goal B1 — Adaptateurs APISIX + WSO2 dans control-plane-api (greenfield)**
- **Contexte** : les deux gateways OSS que le labs prouve n'ont **aucune** existence dans le monorepo (ni adaptateur, ni valeur d'enum `gatewayType`, ni doc). webMethods/Kong/Gravitee/Apigee/AWS/Azure y sont déjà.
- **Objectif** : créer les adaptateurs APISIX et WSO2 sur le moule `adapters/template/`, en portant la logique prouvée dans `labctl/internal/adapter/{apisix,wso2}/` (publish, inboundAuth openid-connect, kafka-logger pour APISIX ; Key Manager pour WSO2).
- **Critères d'acceptation** : `adapters/apisix/` et `adapters/wso2/` avec `adapter.py`/`mappers.py`/`telemetry.py` conformes à `gateway_adapter_interface.py` ; `apisix` et `wso2` ajoutés à l'enum `gatewayType` du CRD `gatewayinstances.gostoa.dev.yaml` ; docs sidecar façon `docs/integrations/webmethods-sidecar-integration.md`.
- **Fichiers** : `stoa/control-plane-api/src/adapters/{apisix,wso2}/`, `charts/stoa-platform/crds/gatewayinstances.gostoa.dev.yaml`, source labs `labctl/internal/adapter/`.
- **Effort** : L. **Priorité** : 🔴 (débloque toute réutilisation labs côté plateforme).

---
**/goal B2 — Porter le moteur dérivation intégrité→sécurité dans control-plane-api**
- **Contexte** : la logique « sécurité = f(intégrité) » (durcie en A1) vit en Go dans `labctl/internal/render` + `validate.go`. La plateforme valide l'UAC via `services/uac_validator.py`.
- **Objectif** : porter la dérivation + le gate fail-closed dans `uac_validator.py` / `api_lifecycle.py`, avec le même code d'erreur `INTEGRITY_INCONSISTENT`.
- **Critères d'acceptation** : `POST .../validate` refuse un manifeste VH sans le bundle dérivé ; parité de comportement avec le labctl du labs (mêmes cas de test).
- **Fichiers** : `stoa/control-plane-api/src/services/uac_validator.py`, `routers/api_lifecycle.py` ; réf. labs `internal/render/`, `governance/validate.go`.
- **Effort** : M. **Dépend de** A1 + B0. **Priorité** : 🟠.

---
**/goal B3 — Étendre vault_client.py avec les patterns Vault prouvés au labs**
- **Contexte** : `control-plane-api/src/services/vault_client.py` (hvac, KV v2, dégradation gracieuse) gère les creds MCP externes. Le labs a prouvé AppRole least-privilège + rotation + fallback fail-closed pour des creds de gateway tierce et tokens de fédération.
- **Objectif** : étendre (pas recréer) `VaultClient` avec les chemins KV du labs (`secret/stoa/gateways/*`, `secret/stoa/envs/*/wm-admin`) et le modèle AppRole scopé par rôle (labctl≠ci).
- **Critères d'acceptation** : lecture des creds gateway tierce via `VaultClient` ; scopes croisés 403 reproduits ; aucune nouvelle classe client.
- **Fichiers** : `stoa/control-plane-api/src/services/vault_client.py` ; réf. labs `labctl/internal/vault/vault.go`, `scripts/setup-vault*.sh`.
- **Effort** : M. **Priorité** : 🟠.

---
**/goal B4 — Mapper le modèle de gates CI multi-env sur GitHub Actions + ArgoCD**
- **Contexte** : le labs prouve ITSM gate + 4-yeux + pin SHA + rollback git-revert en **Jenkins+Ansible**. La plateforme est **GitHub Actions + ArgoCD** (`reusable-gitops-deploy.yml`, `promote-to-prod.yml`, repo externe `stoa-infra`).
- **Objectif** : mapper (pas recopier) chaque gate labs sur l'équivalent GH Environments/ArgoCD : approbation ITSM → gate d'environnement + check, 4-yeux → required reviewers, pin SHA → « build once, promote » (déjà là), rollback → revert vers l'image N-1 taguée.
- **Critères d'acceptation** : un tableau de correspondance gate-par-gate ; au moins le gate ITSM et le 4-yeux fonctionnels sur un workflow de démo côté plateforme.
- **Fichiers** : `stoa/.github/workflows/{reusable-gitops-deploy,promote-to-prod}.yml` ; réf. labs `ci/Jenkinsfile{,.prod,.rollback}`, ADR-075.
- **Effort** : L. **Priorité** : 🟡.

---
**/goal B5 — Finaliser & étendre le CLI stoactl**
- **Contexte** : `stoa/cli/` a son code source **non tracké** dans le checkout (seuls README+CLAUDE.md le sont) et **aucune CI**. Le labs a des verbes prouvés (`apply`, `get apis`, `subscribe`, `plan`, `validate`, onboarding).
- **Objectif** : (1) résoudre l'anomalie de tracking (issue B0.3) ; (2) créer la CI `cli-ci.yml` manquante ; (3) porter les verbes labs pertinents (`onboard`, `federation`, `secrets`) sur le pattern `commands/{login,apply,get,status}`.
- **Critères d'acceptation** : `cli/src` tracké et buildable en CI ; `stoactl` expose les nouveaux verbes alignés sur les endpoints control-plane-api.
- **Fichiers** : `stoa/cli/`, `.github/workflows/` ; réf. labs `labctl/cmd/`.
- **Effort** : M (après clarification B0). **Priorité** : 🟡.

---
**/goal B6 — Réconcilier le concept de « fédération » (anti-collision)**
- **Contexte** : `routers/federation.py` existe déjà (orchestration MCP multi-account, master/sub-account, delegation tokens) — sémantique **différente** de la fédération cross-runtime du labs.
- **Objectif** : selon la décision B0.1, soit généraliser `federation_service.py` pour couvrir la fédération de gateways cross-runtime, soit introduire un namespace/nom distinct pour éviter la confusion produit.
- **Critères d'acceptation** : un seul modèle nommé sans ambiguïté ; doc dans `stoa-docs` ; pas de duplication de la logique de dispatch.
- **Fichiers** : `stoa/control-plane-api/src/routers/federation.py`, `services/federation_service.py`.
- **Effort** : M-L. **Dépend de** B0. **Priorité** : 🟡.

---

## 5. Ordonnancement recommandé

```
Phase A (durcir)   : A8 (tôt, cheap) → A1 (cœur) → A2, A3, A4 (parité runtimes) → A5, A6, A7
Phase B (graduer)  : B0 (décisions, bloquant) → B1 (APISIX/WSO2, débloque tout) → B2, B3 → B4, B5, B6
```

- **A8 d'abord** : peu coûteux, rend le reste lisible.
- **A1 est le pivot** : sans enforcement intégrité→sécurité, le différenciateur GitOps reste « posé à la main ».
- **B0 avant tout B** : les 3 collisions (fédération, double source-de-vérité, cli/src) doivent être tranchées sinon B1-B6 partent dans le mur.
- **B1 débloque la graduation** : tant qu'APISIX/WSO2 ne sont pas dans la plateforme, rien du labs OSS n'y atterrit.
