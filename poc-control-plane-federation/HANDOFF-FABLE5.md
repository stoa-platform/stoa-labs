# Handoff Fable 5 — État du labs STOA & plan séquencé (durcir → graduer)

> Analyse : stoa-labs (PoC control-plane-federation, accounts-team, payments-team,
> console-light, stoa-platform-ci, adr) en profondeur ; monorepo `stoa` lu pour les
> points de raccordement. Créé 2026-07-03 ; **rafraîchi 2026-07-04** (Phase A cœur livrée).

---

## 0. Verdict en une phrase

Le labs a **prouvé sa thèse** — un control plane sur briques OSS fédère 3 gateways
hétérogènes (WSO2, APISIX, webMethods **réel** 10.15) sous identité Oracle-master, avec
une discipline de preuve rare. **Le cœur de la Phase A (durcir) est désormais livré** :
« sécurité = f(intégrité) » est **enforced** ET **anti-spoof**, l'observabilité et
l'analytics sont **3/3 runtimes**. Ce qui reste : quelques goals de finition Phase A
(A4/A6/A7) et surtout **(B) faire atterrir les briques prouvées dans la plateforme
`stoa`**, où deux d'entre elles (APISIX, WSO2) n'ont **aucune** existence.

---

## 0.bis Livré cette session (2026-07-03/04)

| Goal | Résultat | Preuve | Commits |
|---|---|---|---|
| **A8** — hygiène doc & statut ADR | ✅ | `HARD-CRITERIA-MAP` réconcilié ; ADR 070-076 statut à 2 axes (business vs maturité technique) | `630b1b0` |
| **A1** — enforcer « sécurité = f(intégrité) » | ✅ | gate `labctl apply` : pré-check `[INTEGRITY_UNFULFILLED]` + read-back gateway `[ENFORCEMENT_UNCONFIRMED]` ; `test-integrity-enforce.sh` **31/31 live** (contre-épreuve sabotage) | `e03cfee`, `6fac8b8`, `1925946` |
| **A2** — WSO2 OTel → traces 3/3 | ✅ | cause au bytecode (`url` seul + `properties` obligatoire) ; Tempo `['apisix','webmethods-mock','wso2']` | `558d435` |
| **A3** — analytics par fournisseur 3/3 | ✅ | `wso2-otel-tap` (spans OTel, pas les logs fichier) ; `test-txn-wso2.sh` **12/12**, pivot trace_id Tempo↔OpenSearch | `1a4442b`, `e3ab434` |
| **A5** — classification centrale anti-spoof + poly-repo | ✅ | registre central owner-keyé (`test-classification-central.sh` **11/11**) ; 2e repo pilote `payments-team` (H, bundle ≠ VH) | `3dc3766`, `5b4607a`, `58dddab` |

**Insights réutilisables (durement gagnés)** :
- **A1** : le read-back attrape ce que le projecteur ne corrige pas — l'action IAM AND
  wM est réutilisée telle quelle, un sabotage `allowAnonymous` n'est vu QUE par le gate.
- **A2** : « OTLP natif cassé » = config incomplète, pas une instabilité produit (vérité
  bytecode). Ne jamais présumer un bug produit sans lire le bytecode/la source.
- **A3** : les logs fichier WSO2 n'ont **pas** de trace_id → « Fluent Bit sidecar » (plan
  initial) = impasse. La seule source avec trace_id = les spans OTel. WSO2 exporte en
  **gzip** (codec serveur gRPC à enregistrer).
- **A5** : ne **jamais** keyer un lookup anti-spoof sur des champs projet-éditables. L'ancre
  doit être une identité injectée par le pipeline (`PROJECT_NAME`), pas l'`api.yaml`.
- **Méthode** : chaque goal a suivi comprendre → **review adversariale du design** →
  implémenter → prouver live → **review adversariale du diff** → docs. Les reviews de
  *design* ont attrapé des trous (A1 : faux négatif VH ; A5 : trou B1 de clé projet-éditable)
  AVANT d'écrire une ligne — c'est là que le gain est maximal.

⚠️ **État du trial wM** : la chaîne de versions de `accounts-read` est corrompue
(« Versioning only from latest » vers un record supprimé, cf. note A1). Un `apply`
plateforme réel du repo `accounts-team` bute EN AMONT du gate → **rebuild-from-Git sur
état sain requis** (teardown/up ou env neuf). Ce n'est pas un défaut du gate (les scripts
de preuve tournent sur API propre). Le trial **flappe** ~toutes les 20 min (santé 000
transitoire) — attendre health=200 avant tout spike.

---

## 1. Ce qui marche vraiment (labs) — à jour

| Chantier | Statut | Preuve concrète |
|---|---|---|
| Fédération 3 runtimes + Define Once/Expose Everywhere (ADR-071/072) | ✅ PROUVÉ live | `labctl apply` 3/3 gw depuis 1 OpenAPI ; `demo.sh`, `EVIDENCE.md` Preuves 1-4 |
| Identité Oracle-master (Dex→Keycloak→3 gw) | ✅ PROUVÉ live | `phase3-identity-demo.sh` : 1 token → 200×3 / 401×3 |
| Médiation control-plane (ADR-072) | ✅ PROUVÉ | `test-onboarding-matrix` 8/8, `test-apply-scope` 11/11, `test-apply-audit` 13/13, `demo-mediation` 11/11 |
| Secrets Vault as-code + rotation (ADR-074) | ✅ PROUVÉ | `internal/vault`, AppRole least-privilege (403 croisés), `test-vault-rotation.sh` |
| CI multi-env sans gateway de promotion (ADR-075) | ✅ PROUVÉ | `demo-multienv.sh` 19/19 ; **vrai Jenkins** ; ITSM gate + 4-yeux + pin SHA |
| **Observabilité OTel fédérée** | ✅ **3/3** (A2) | Tempo : APISIX + webMethods + **WSO2** ; `setup-wso2-otel.sh` |
| **Analytics txn par fournisseur (ADR-070)** | ✅ **3/3** (A3) | data-stream + RBAC/FLS + redaction 1-point + pivot trace_id ; `wso2-otel-tap` ; `test-txn-wso2.sh` 12/12 |
| Traces wM réel → Tempo (ADR-073) | ✅ PROUVÉ | `wm-trace-bridge` |
| **GitOps cycle de vie API (ADR-076)** | ✅ **enforced + anti-spoof** (A1+A5) | gate apply fail-closed (31/31) + classification centrale owner-keyée (11/11) ; enum VH/H/M |
| console-light (IHM gouvernance) | ✅ Démo-able E2E | `tsc` clean, Playwright multi-personas, UI→commit→Jenkins→3 gw→200 |
| accounts-team + **payments-team** (repos-clients GitOps) | ✅ Fonctionnels | 2 pilotes poly-repo, bundles différents dérivés du central |

---

## 2. Les gaps réels restants (les gaps A1/A2/A3/A5/A8 sont fermés)

| # | Gap | Nature | Goal |
|---|---|---|---|
| G4 | **TokenProvider wM outbound câblé à la main** (2 policyActions), pas as-code | Dette de câblage | **A4** |
| G6 | **TOCTOU ITSM prod** : pas de re-check live de l'approbation au dispatch | Faille temporelle | **A6** |
| G7 | **console-light** : webhook sur miroir de démo, refus 4-yeux non exercé E2E | Câblage démo | **A7** |
| G9 | **audience wM non opposable** (trial 10.15) ; **dev/rec/int = mocks wM** ; **SSO OIDC OpenSearch** déféré ; **streaming >500 Mo** hors scope | Limites assumées | — (documentées) |
| G10 | **read-back enforcement APISIX/WSO2** absent : tout target non-wM sous gate A1 = structurellement rouge (`unverifiable`) | Fail-closed assumé | **B1** (adaptateurs plateforme) |

---

## 3. Carte de graduation labs → `stoa` (points de raccordement)

| Brique labs | Point de greffe `stoa` | Verdict |
|---|---|---|
| Fédération control-plane | `control-plane-api/src/routers/federation.py` (master/sub-account **MCP**) | ⚠️ **Collision conceptuelle** (MCP vs cross-runtime) — décider extend vs namespace |
| GitOps cycle de vie API | `routers/{api_lifecycle,git,reconciliation}.py` + `tenants/*/apis/*.yaml` | ✅ À réutiliser (drift/sync déjà là) |
| Moteur dérivation intégrité→sécurité + **classification centrale** | `services/uac_validator.py`, `api_lifecycle.py` | Greenfield — porter `internal/render` + `internal/govsource` + `cmd/labctl/enforce.go` |
| Gateway mTLS/OAuth2 | `stoa-gateway/src/auth/{mtls,oidc,jwt,dpop}.rs` | ✅ Mature — **réutiliser, ne pas réimplémenter** |
| **APISIX** / **WSO2** | — | 🔴 **GREENFIELD — aucune trace**. Moule = `adapters/template/` + enum `gatewayType` CRD + doc sidecar |
| webMethods / Kong | `adapters/webmethods/`, `adapters/kong/` | ✅ Prod-ready — réutiliser |
| CLI stoactl | `cli/` (dans le monorepo) | ⚠️ Code source **non tracké** (sparse-checkout ?), **aucune CI** — clarifier |
| Secrets/Vault | `control-plane-api/src/services/vault_client.py` | ✅ Étendre (chemins KV) |
| CI multi-env | `.github/workflows/reusable-gitops-deploy.yml`, `promote-to-prod.yml` + `stoa-infra` (ArgoCD) | ✅ Réutiliser — **mapper** les gates (Jenkins+Ansible → GH Actions+ArgoCD) |
| RBAC / tenants / mTLS par tenant | `auth/rbac.py`, `routers/tenants.py`, `routers/tenant_ca.py` | ✅ Réutiliser |
| CRDs déclaratives | `charts/stoa-platform/crds/` + `stoa-operator` **vs** `tenants/*/apis/*.yaml` | ⚠️ **Deux mécanismes concurrents non unifiés** — trancher |

**3 pièges à signaler avant toute graduation :** collision « fédération » (MCP vs
cross-runtime) ; double source-de-vérité déclarative ; anomalie git `cli/src`.

---

## 4. PLAN — /goal restants pour Fable 5

> Chaque goal est auto-contenu (contexte + DoD + fichiers). Effort : S (<0.5j) · M (1-2j)
> · L (3j+). Racine labs = `/Users/torpedo/hlfh-repos/stoa-labs`.

### PHASE A — finition du labs (A1/A2/A3/A5/A8 déjà faits)

---
**/goal A4 — TokenProvider webMethods outbound as-code**
- **Contexte** : le TokenProvider IS+Vault (creds body-based wM 10.15) est câblé à la main
  via 2 `policyActions`, pas projeté par `labctl apply`.
- **Objectif** : porter la config outbound (routing-by-alias + credential alias base64 +
  action outbound imbriquée sous `transportSecurity`) dans l'adaptateur, projetée à chaque
  apply, idempotente.
- **Critères** : re-apply idempotent recrée l'auth outbound sans intervention ; Basic injecté
  vu par le backend ; changement d'alias suivi immédiatement (déjà prouvé pour le routing).
- **Fichiers** : `labctl/internal/adapter/webmethods/{routing,inboundauth}.go`,
  `gateways/webmethods/token-provider/`.
- **Effort** : M. **Priorité** : 🟠.

---
**/goal A6 — Fermer le TOCTOU du gate ITSM prod**
- **Contexte** : le gate prod (ITSM approved + 4-yeux + pin SHA) est vérifié au merge/build,
  pas re-checké **live** à l'instant du dispatch — fenêtre TOCTOU.
- **Objectif** : re-valider l'approbation ITSM (et le 4-yeux) au dispatch prod, juste avant `apply`.
- **Critères** : une approbation ITSM révoquée entre build et dispatch → apply prod **bloqué**
  (`409 ITSM_NOT_APPROVED` rejoué au dispatch) ; contre-épreuve dans `demo-multienv.sh`.
- **Fichiers** : `ci/Jenkinsfile.prod`, `envs/prod/`, `scripts/demo-multienv.sh`.
- **Effort** : M. **Priorité** : 🟡.

---
**/goal A7 — console-light : webhook réel + refus 4-yeux exercé E2E**
- **Contexte** : le webhook pointe sur un miroir de démo (`var/ci-mirror`) et le refus
  self-approval 4-yeux est couvert en unitaire mais jamais exercé en E2E (`denials.jsonl` vide).
- **Objectif** : brancher le webhook sur le vrai repo de gouvernance + un spec Playwright qui
  **tente** une self-approval et capture le refus.
- **Critères** : commit console → vrai repo → Jenkins → déploiement ; spec E2E qui produit une
  entrée `denials.jsonl` avec le 403 `SELF_APPROVAL_BLOCKED`.
- **Fichiers** : `console-light/` (config webhook, specs Playwright `50-*`), BFF
  `labctl/cmd/governance-api/`.
- **Effort** : M. **Priorité** : 🟡.

---

### PHASE B — Graduer vers la plateforme `stoa` (le gros du reste-à-faire)

> Racine plateforme = `/Users/torpedo/hlfh-repos/stoa`. **B0 à trancher AVANT tout code.**

---
**/goal B0 — Décisions d'architecture bloquantes (à trancher avec l'équipe stoa)**
- **Objectif** : trancher 3 collisions. (1) **Fédération** : le cross-runtime du labs étend-il
  `routers/federation.py` (MCP) ou un namespace distinct ? (2) **Source de vérité déclarative** :
  étendre `tenants/*/apis/*.yaml` + `reconciliation.py` OU de vraies CRD K8s (`stoa-operator`) ?
  (3) **CLI** : pourquoi `cli/src` n'est pas tracké, où vit la source canonique ?
- **Critères** : un mini-ADR de graduation dans `stoa-docs` actant les 3 choix ; réf. par B1-B6.
- **Effort** : S (décision) / **bloque** B1-B6. **Priorité** : 🔴 première.

---
**/goal B1 — Adaptateurs APISIX + WSO2 dans control-plane-api (greenfield)**
- **Contexte** : les 2 gateways OSS que le labs prouve n'ont **aucune** existence dans le
  monorepo. webMethods/Kong/Gravitee/Apigee/AWS/Azure y sont déjà.
- **Objectif** : créer les adaptateurs APISIX et WSO2 sur le moule `adapters/template/`, en
  portant la logique prouvée dans `labctl/internal/adapter/{apisix,wso2}/` (publish,
  inboundAuth openid-connect, kafka-logger APISIX ; Key Manager + **le fix OTel A2** WSO2).
- **Critères** : `adapters/{apisix,wso2}/` conformes à `gateway_adapter_interface.py` ; `apisix`
  et `wso2` ajoutés à l'enum `gatewayType` du CRD ; docs sidecar façon webMethods.
- **Fichiers** : `stoa/control-plane-api/src/adapters/{apisix,wso2}/`,
  `charts/stoa-platform/crds/gatewayinstances.gostoa.dev.yaml` ; réf. labs `labctl/internal/adapter/`.
- **Effort** : L. **Priorité** : 🔴 (débloque toute réutilisation labs côté plateforme).

---
**/goal B2 — Porter dérivation intégrité→sécurité + classification centrale dans control-plane-api**
- **Contexte** : la logique « sécurité = f(intégrité) » (A1) + le gate anti-spoof (A5) vivent en
  Go (`internal/render`, `internal/govsource`, `cmd/labctl/enforce.go`). La plateforme valide
  l'UAC via `services/uac_validator.py`.
- **Objectif** : porter la dérivation + le gate fail-closed + le registre central owner-keyé dans
  `uac_validator.py`/`api_lifecycle.py`, mêmes codes (`INTEGRITY_INCONSISTENT`,
  `INTEGRITY_UNFULFILLED`, `ENFORCEMENT_UNCONFIRMED`, `CLASSIFICATION_SPOOFED/UNGOVERNED`).
- **Critères** : `POST .../validate` refuse VH sans bundle ; une PR qui downgrade sa
  classification → refusée côté plateforme ; parité avec les cas de test du labs.
- **Fichiers** : `stoa/control-plane-api/src/services/uac_validator.py`, `routers/api_lifecycle.py` ;
  réf. labs `internal/{render,govsource}/`, `cmd/labctl/enforce.go`.
- **Effort** : M-L. **Dépend de** A1+A5+B0. **Priorité** : 🟠.

---
**/goal B3 — Étendre vault_client.py avec les patterns Vault prouvés au labs**
- **Contexte** : `vault_client.py` (hvac, KV v2, dégradation gracieuse) gère les creds MCP. Le
  labs a prouvé AppRole least-privilège + rotation + fallback fail-closed + write scopé par projet.
- **Objectif** : étendre (pas recréer) `VaultClient` avec les chemins du labs (`secret/stoa/gateways/*`,
  `secret/stoa/projects/<team>/*`) et le modèle AppRole scopé (labctl≠ci≠projet).
- **Critères** : lecture des creds gateway tierce via `VaultClient` ; scopes croisés 403 reproduits ;
  aucune nouvelle classe client.
- **Fichiers** : `stoa/control-plane-api/src/services/vault_client.py` ; réf. labs
  `labctl/internal/vault/vault.go`, `scripts/setup-vault*.sh`.
- **Effort** : M. **Priorité** : 🟠.

---
**/goal B4 — Mapper le modèle de gates CI multi-env sur GitHub Actions + ArgoCD**
- **Contexte** : le labs prouve ITSM gate + 4-yeux + pin SHA + rollback git-revert en
  **Jenkins+Ansible**. La plateforme est **GH Actions + ArgoCD**.
- **Objectif** : mapper (pas recopier) chaque gate : ITSM → gate d'environnement + check, 4-yeux →
  required reviewers, pin SHA → « build once, promote », rollback → revert image N-1.
- **Critères** : tableau de correspondance gate-par-gate ; ITSM + 4-yeux fonctionnels sur un
  workflow de démo.
- **Fichiers** : `stoa/.github/workflows/{reusable-gitops-deploy,promote-to-prod}.yml` ; réf. labs
  `ci/Jenkinsfile{,.prod,.rollback}`, ADR-075.
- **Effort** : L. **Priorité** : 🟡.

---
**/goal B5 — Finaliser & étendre le CLI stoactl**
- **Contexte** : `stoa/cli/` a son code source **non tracké** et **aucune CI**. Le labs a des verbes
  prouvés (`apply`, `get apis`, `subscribe`, `plan`, `validate`, onboarding).
- **Objectif** : (1) résoudre l'anomalie de tracking (B0.3) ; (2) créer `cli-ci.yml` ; (3) porter les
  verbes labs (`onboard`, `federation`, `secrets`) sur le pattern `commands/{login,apply,get,status}`.
- **Critères** : `cli/src` tracké et buildable en CI ; nouveaux verbes alignés sur control-plane-api.
- **Fichiers** : `stoa/cli/`, `.github/workflows/` ; réf. labs `labctl/cmd/`.
- **Effort** : M. **Priorité** : 🟡.

---
**/goal B6 — Réconcilier le concept de « fédération » (anti-collision)**
- **Contexte** : `routers/federation.py` existe déjà (MCP multi-account) — sémantique différente de
  la fédération cross-runtime du labs.
- **Objectif** : selon B0.1, généraliser `federation_service.py` OU introduire un namespace distinct.
- **Critères** : un seul modèle nommé sans ambiguïté ; doc dans `stoa-docs` ; pas de duplication.
- **Fichiers** : `stoa/control-plane-api/src/routers/federation.py`, `services/federation_service.py`.
- **Effort** : M-L. **Dépend de** B0. **Priorité** : 🟡.

---

## 5. Ordonnancement recommandé

```
Phase A (reste) : A4 · A6 · A7  (finition, indépendants)
Phase B (graduer) : B0 (décisions, bloquant) → B1 (APISIX/WSO2, débloque tout)
                    → B2, B3 → B4, B5, B6
```

- **B0 avant tout B** : les 3 collisions (fédération, double source-de-vérité, cli/src) doivent
  être tranchées sinon B1-B6 partent dans le mur.
- **B1 débloque la graduation** : tant qu'APISIX/WSO2 ne sont pas dans la plateforme, rien du labs
  OSS n'y atterrit — et le read-back enforcement (A1) y reste rouge (G10).
- **B2 capitalise A1+A5** : porter le gate enforced+anti-spoof dans la plateforme est ce qui
  transforme le différenciateur prouvé au labs en contrôle produit.
