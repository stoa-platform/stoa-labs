---
title: "ADR-076 — Cycle de vie d'API GitOps repo-par-projet : classification d'intégrité → stratégie de sécurité DÉRIVÉE as-code, catalogue de policies central non-affaiblissable, promotion trunk + marqueurs (main = cible prod)"
sidebar_label: "ADR-076 : GitOps API lifecycle repo-par-projet"
status: "Proposé — en attente Council (GO/NO-GO)"
date: 2026-07-01
adr_number: 76
visibility: private
note: "Privé (stoa-labs). S'appuie sur ADR-067 (reuse-first / couche possédée portable), ADR-068 (hors data-plane), ADR-069 (Git source de vérité), ADR-071 (onboarding partenaire as-code), ADR-072 (médiation control-plane), ADR-074 (secrets Vault), ADR-075 (proxy admin wM multi-env). Ne pas porter dans stoa-docs (public)."
---

# ADR-076 — Cycle de vie d'API GitOps repo-par-projet

**Statut :** Proposé — en attente validation Council (GO/NO-GO).
**Date :** 2026-07-01.
**Contexte client (anonymisé) :** banque — webMethods API Gateway 10.15, chaîne dev → rec → int → prod (ADR-075), demande d'**un repo Git par projet** avec cycle de vie « création/modif d'API → création sur la gateway → publication par env », **stratégie de sécurité fonction du niveau d'intégrité de la donnée**, certificats (mTLS), OAuth2 interne/externe, filtrage IP, tokens custom, et si possible **global policies + filtrage par tag**.
**Lié à :** [[adr-067-reuse-first-owned-portable-layer]], [[adr-068-stoa-off-the-transaction-path]], [[adr-069-retention-moat-governance-source-of-truth]], [[adr-071-partner-onboarding-as-code]], [[adr-072-control-plane-mediation]], [[adr-074-vault-secrets]], [[adr-075-wm-admin-proxy-multienv]].

> ⚠️ **Confidentialité.** Topologie de gouvernance d'APIs d'une banque + matrice de sécurité par niveau d'intégrité. Vit dans `stoa-labs` (privé), **pas** dans `stoa-docs` (public).

---

## Décision (test « archi 40 ans / 30 secondes »)

> Chaque projet a **un repo Git** qui est un **shard byte-compatible** du schéma de gouvernance déjà prouvé (ADR-069/072/075) : l'équipe y pousse le **contrat** (`openapi.yaml`) et un **manifeste UAC** (`api.yaml` : classification d'intégrité + tags + exposure) ; **elle ne pose jamais une policy à la main**. La **stratégie de sécurité est DÉRIVÉE** de la classification par `labctl render` (`classification → bundle de policies concret`), **épinglée** dans `strategy.lock`, et **vérifiée fail-closed** (`validate` refuse le merge d'une API `VH` sans mTLS). Les policies sont **possédées centralement** dans un catalogue de gouvernance que le repo projet **ne peut pas affaiblir** — une équipe ne peut **physiquement pas** shipper une posture plus faible que son niveau. La promotion reste **trunk + marqueurs `deploy.{env}.yaml`** (forme prouvée 19/19), **`main` = cible de promotion prod** ; create → publish → promote → rollback réutilisent tel quel l'existant (ADR-071/072/075, Vault ADR-074, TokenProvider).
> **Test** : *une équipe projet peut-elle, depuis SON repo, faire baisser la barrière de sécurité en dessous du niveau d'intégrité de sa donnée — sans qu'un `validate` fail-closed et un catalogue central hors de son repo l'en empêchent ?* Si la réponse n'est pas « non, mécaniquement impossible », alors « sécurité = f(intégrité) » est un slogan, pas un contrôle.

---

## Contexte et problème

**Où on en est (prouvé le 2026-06-12).** Une chaîne de promotion GitOps `dev → rec → int → prod` tourne (3 pipelines Jenkins + `governance-api` sur **un** repo de gouvernance) : gates par saut (`environments.yaml`), pinning de version réel (SHA `api.yaml` dans `deploy.{env}.yaml`), prod **zéro-trust** re-validée avant tout dispatch, rollback = git-revert + re-apply (aucun DELETE gateway). Preuves : `demo-multienv.sh` **19/19**, `stoa-prod-deploy #2/#4`, `stoa-prod-rollback #2`, matrice proxy admin 15/15.

**Trois écarts avec la cible client :**
1. **Ce n'est pas repo-par-projet.** Un « projet » = un sous-arbre `tenants/{tenant}/apis/{slug}/` d'**un monorepo** de gouvernance. Tenants : `banking-demo`, `payments-team` ; une seule API : `accounts-read`.
2. **webMethods-only.** dev/rec/int sont des **mocks** wM 10.15 (réseau `nonprod`) ; seul prod = le vrai trial. WSO2 déféré, APISIX hors chaîne multi-env.
3. **La sécurité pilotée par l'intégrité (état initial → corrigé).** `classification` *était* un enum validé mais non dérivé (`labctl/internal/uac/uac.go` exclut `classification`/`required_policies` de la projection ; `validate.go` ne dérivait rien). **Comblé depuis** : `internal/render` intégré à `governance.ValidateUAC`, **fail-closed** (`INTEGRITY_INCONSISTENT`) — un contrat dont l'intégrité ne dérive pas est rejeté (cf. §Modèle de sécurité). **Écart résiduel** : le gate ne vérifie pas encore que `target.yaml` *implémente réellement* le bundle dérivé (enforcement partiel, cf. rapport de réconciliation).

Ce gap contredit le pitch STOA : sans dérivation ni catalogue central, « sécurité = f(intégrité) » n'est **pas** un contrôle opposable à un régulateur.

## Options considérées

1. **Manifeste-first déclaratif** (repo = `openapi.yaml` + `api-strategy.yaml`, policies rendues par une lib partagée, env = branche). Bonne ergonomie ; mais branche-par-env longue-durée **diverge** du modèle prouvé (trunk + marqueurs) et perd la vue audit single-tree.
2. **Aligné schéma STOA (CRD-like)** : le repo est un shard du schéma de gouvernance prouvé → zéro ré-invention, portable vers le produit. **Socle retenu.**
3. **Global-policy + tag-driven** : APIs taguées par intégrité, policies globales scoping par tag. Le catalogue central est le bon *moat* ; mais réduire le repo à « juste des tags » masque la classification (donnée régulateur de premier ordre) et la global-policy native par tag est **non vérifiée** sur wM 10.15.

**★ Retenu : blend socle (2) + greffes.** Socle aligné-STOA ; **greffe de (1)** = `labctl render` + `strategy.lock` comme *implémentation* concrète du moteur de dérivation (le maillon que le schéma attend) ; **greffe de (3)** = le **catalogue de policies central non-affaiblissable** + la distinction honnête *tag fan-out prouvé* vs *global-policy native derrière spike*. On **garde le trunk + marqueurs** (pas de branche-par-env) et la **classification comme champ UAC de premier ordre** (le tag n'étant que la 2e couche orthogonale : exposure / pii / domaine).

## Décision retenue

### 1. Le repo projet = shard byte-compatible du schéma de gouvernance

```
apis/{slug}/
  openapi.yaml          # le contrat (artefact de base — Phase 1)
  api.yaml              # manifeste UAC : classification d'intégrité + tags + exposure
                        #                 + RÉFÉRENCE (read-only) à la classification centrale
  target.yaml           # gateways cibles (réutilise le modèle FederationTarget)
deploy.{env}.yaml       # marqueurs desired-state pinnés — ÉCRITS par la promotion, pas par l'équipe
strategy.lock           # bundle de policies DÉRIVÉ + épinglé (sortie de `labctl render`)
```

Byte-compatible avec le monorepo actuel ⇒ split/merge **sans changement de schéma**, agrégation via `registry/projects.yaml` (tenant → repo). L'équipe pousse **uniquement** `openapi.yaml` + `api.yaml` (+ `target.yaml`) ; `deploy.*` et `strategy.lock` sont **dérivés/gouvernés**, jamais édités à la main.

### 2. Moteur de DÉRIVATION `classification → required_policies` (le maillon manquant)

- `labctl render` : `classification (+ exposure/tags) → bundle de policies concret` (alias auth-server, stratégie OAUTH2, scope, Identify&Authorize, mTLS, IP, rate-limit, audit). Sortie **épinglée** dans `strategy.lock`.
- Gate de cohérence **fail-closed** (`validate`) : une API `VH` sans jambe mTLS, une `H`/`M` sans OAuth2, un `apiKey` sur `H`/`VH` ⇒ **merge refusé**. La stratégie devient une **fonction machine-vérifiée** du niveau d'intégrité — pas une description.

### 3. Catalogue de policies CENTRAL non-affaiblissable

`governance/policy/` (dans le repo de gouvernance central, **hors** repo projet) : `integrity-matrix.yaml`, `global-policies.yaml`, `exposure.yaml`. Le repo projet **référence** un niveau ; il **ne peut pas** redéfinir ce qu'un niveau exige. C'est le *moat* sécurité : le pipeline projette ce que le catalogue central impose, le projet ne fait que déclarer son intention.

### 4. Modèle git : trunk + marqueurs, `main` = cible prod

Trunk source de vérité + marqueurs `deploy.{env}.yaml` (desired-state pinné) + branches PR de promotion courtes. **`main` = cible de promotion prod** (pas une branche par-env). Vue audit **single-tree** (4-yeux / evidence / pinning / rollback diffables). *Option hybride* si besoin visuel : miroirs `env/*` read-only fast-forwardés (la vérité reste en Git).

### 5. Custom tokens — deux chemins, jamais confondus

- **INBOUND** = identifier wM `token` (le client présente un token d'identité custom) — déjà prouvé (ADR-071).
- **OUTBOUND** = les credentials de l'API **au niveau gateway** = le **TokenProvider** de ce repo (profil Vault-backed `keycloak-ropc` / `oauth2-client-credentials` / `legacy-json-login`, injecté en `Authorization: Bearer`, invalidé sur 401). **Gap** : ses 2 policyActions sont câblées **à la main** aujourd'hui → cible : **projetées as-code** par labctl (même pattern admin-REST qu'ADR-075).

---

## Matrice intégrité → stratégie (échelle LITTÉRALE client `VH / H / M`)

> **Échelle arrêtée avec le client (2026-07-01, décision #1 tranchée).** `VH` (Very High) > `H` (High) > `M` (Medium, plancher). On **abandonne** l'enum DORA `H/VH/VVH` du schéma actuel — **alignement sur le vocabulaire de l'auditeur**. Si un tier « critique » émerge plus tard, il se mappe 1:1 sur le `VVH` du produit STOA (extension non-cassante).

| Niveau | Authn | Enforcement webMethods 10.15 (concret) | Tag | Exposure |
|---|---|---|---|---|
| **VH** (Very High) | **OAuth2 + mTLS** | alias auth-server (`POST /alias`, EXTERNAL, `localIntrospectionConfig`) + `OAUTH2` strategy (`POST /strategies`) + scope + `Identify&Authorize` (`identificationType=oAuth2Token`, `applicationLookup=strict`, stage **IAM** UPPERCASE, **read-back obligatoire** — PUT nu = no-op silencieux) **+** identifier `httpsCertificate` (DER base64) + `PUT /configurations/keystore` + toggle transport *require client cert* | `integrity:VH` | ext ⇒ IdP partenaire **+ IP allowlist obligatoire** |
| **H** (High) | OAuth2 | idem VH **moins** la jambe `httpsCertificate`/keystore | `integrity:H` | ext / int |
| **M** (Medium, défaut) | **OAuth2** | identique à H — pas de downgrade silencieux vers ApiKey | `integrity:M` | ext / int |
| **M** — variante ApiKey | ApiKey-only (**permis pour M**, choix client) | identifier `apiKey` + `Identify&Authorize(apiKey)` — `exposure:internal` + tag `auth-exception:apikey` (auditable) ; `render` **refuse** apiKey pour `H`/`VH` | `integrity:M + auth-exception:apikey` | **internal** (reco) |

**Plancher M** : le client n'a nommé que `VH/H/M`. **À confirmer** : existe-t-il un niveau **L** (Low) sous M ? Si oui il s'y loge (reco : ApiKey ou ouvert, `internal` uniquement).

**Impact enum (décision #1) — localisé, pas de cross-repo produit :** `H/VH/VVH` → `VH/H/M` touche **4 sites** dans ce repo — `labctl/cmd/governance-api/uac_contract_v1_schema.json:109` (enum + description l.110), `labctl/internal/governance/validate.go:34` (`classificationEnum`) + `:79` (message d'erreur), et 1-2 fixtures de test. `VH` reste valide (tests inchangés), `VVH` devient invalide (aucune donnée on-disk ne l'utilise), `M` est ajouté. **Ce n'est PAS** le changement Rust+Python cross-repo du produit — celui-là n'intervient qu'en Phase 8 (réconciliation STOA).

**Exposure :** `external` ⇒ IdP partenaire (Keycloak EXTERNAL) + IP allowlist ; `internal` ⇒ IdP interne (wM LOCAL ou realm KC interne). Deux ancres de confiance = 2 alias/stratégies sélectionnés par le tag `exposure:*`.

**« Apply policy by tag » + global policies :** **prouvé en fan-out control-plane** (labctl projette per-API par requête de tag). La **global-policy native wM filtrée par tag** (`POST /policies` `policyScope=GLOBAL`) est **non vérifiée** sur 10.15 (ADR-070 a rejeté le filtre par tag pour l'observabilité) **et absente de l'allowlist du proxy admin** → **derrière un spike gate, jamais promise avant preuve**.

---

## Modèle de sécurité par couches — PROUVÉ vs ASPIRATIONNEL (revue adversariale institution financière régulée)

> ⚠️ **Le squelette GitOps est bank-grade et prouvé. La règle « sécurité = f(intégrité) » est désormais DÉRIVÉE + VALIDÉE fail-closed (Phase 3 livrée : `render` intégré à `ValidateUAC`) et RÉCONCILIÉE par un rapport read-back — mais l'ENFORCEMENT au data-plane reste PARTIEL sur ce trial (voir tableau). Ne présenter chaque leg comme *enforced* qu'au vu du rapport de réconciliation, jamais de l'intention.** Cette honnêteté protège le POSITIONING (C1) : la valeur STOA est le **catalogue maintenu + le moteur de dérivation + les Links** à travers les dérives de version, jamais « les 300 lignes de pipeline ».

| Couche | Statut | Détail |
|---|---|---|
| Prod fail-closed | ✅ **PROUVÉ** | `ci/Jenkinsfile.prod:50-88` re-clone, re-lit le marqueur mergé + `deploy.prod.yaml` pinné, assert `status=approved`/`to=prod`/4-yeux/`change_ref`/`pv_ref`/commit, `error()` **avant** tout appel gateway. |
| 4-yeux | ✅ **PROUVÉ** | `SELF_APPROVAL_BLOCKED` côté governance-api **+** re-check dans le gate pipeline. |
| Rollback sans DELETE | ✅ **PROUVÉ** | git-revert + re-apply idempotent ; l'allowlist proxy n'a aucun verbe DELETE. |
| Secrets hors-Git | ✅ **PROUVÉ** | Vault AppRole (ADR-074), tokens court-TTL 0600, `set +x`, `ci-horsprod` porte `deploy:dev+rec+int`, jamais `deploy:prod`. |
| Pinning de version | ✅ **PROUVÉ** | SHA `api.yaml` dans `deploy.{env}.yaml`, re-check à l'approbation (`CONTRACT_MOVED`), prod refuse un commit vide. |
| **Sécurité = f(intégrité)** | 🟡 **DÉRIVÉE + VALIDÉE + RÉCONCILIÉE ; enforcement PARTIEL (trial)** | Le moteur `internal/render` dérive `required_policies` **fail-closed** (intégré `governance.ValidateUAC` → `INTEGRITY_INCONSISTENT`). Un **rapport de réconciliation** (Ansible, read-backs LIVE) classe chaque policy `enforced/degraded/blocked` par API — pour **ne jamais surclamer**. État réel accounts-read VH/external : oauth2=ENFORCED\* (3/4 ; audience fail-open trial), audit-log=ENFORCED (global logInvocation, métadonnées seules), ip-allowlist=DÉGRADÉ (consommateur), rate-limit=NON ENFORCED (throttle à livrer), **mtls=NON CÂBLÉ pour accounts-read** (son data-plane est HTTP :5555). **Capacité mTLS PROUVÉE sur ce trial** via le listener :5543 (`clientAuth=require` + CA client dans `DEFAULT_IS_TRUSTSTORE`, IS redémarré : no-cert & rogue-cert rejetés, trusted-cert handshake OK/401) — donc **PAS structurellement impossible**. Gap : router accounts-read sur :5543 + projeter keystore/`require-cert` as-code (keystore hors allowlist ADR-075). Flip + keytool + restart = couche IS-admin/Ansible, pas l'API apigateway. |
| **mTLS (VH)** | 🟡 **CAPACITÉ PROUVÉE (:5543, hors REST) — projection as-code + wiring accounts-read PENDING** | Handshake `clientAuth=require` **prouvé** sur :5543 (no-cert & rogue-cert rejetés, trusted-cert OK) via flip UI + keytool CA + restart. Reste : `PUT /configurations/keystore` **hors allowlist** ADR-075, toggle *require client cert* non projeté as-code, et accounts-read encore routé sur :5555. **→ Phase 4/7.** |
| **Global-policy native par tag** | ❌ **NON VÉRIFIÉ** | `POST /policies?scope=GLOBAL` hors allowlist + filtre tag non prouvé. **→ Phase 7 (spike).** |
| Audience OAuth2 | ⚠️ **fail-open sur le trial** | introspection remote inerte ⇒ 3/4 barrières (issuer/signature/scope/azp). Jamais vendue comme barrière (cf. ADR-075). |

## Écarts d'enforcement connus (à combler tier par tier, chacun derrière son spike)

1. **Tag-spoof / classification auto-déclarée** : le niveau est posé par l'équipe **dans son propre repo** ; CODEOWNERS y est éditable ⇒ pas de 4-yeux indépendant. **Correctif : la classification est assignée dans le repo de gouvernance central (data-governance) ; le repo projet n'en porte qu'une référence read-only.** Le projet *demande* un niveau, il ne *fixe* pas celui que le moteur de policy croit.
2. **mTLS — handshake DÉJÀ prouvé** hors-bande sur :5543 (`clientAuth=require`, no-cert & rogue-cert rejetés, trusted-cert OK). Reste à **l'automatiser as-code** : ajouter `/configurations/keystore` à l'allowlist ADR-075, projeter le toggle *require client cert*, et **router accounts-read sur le listener mTLS**.
3. **Global-policy native** : ajouter `POST/GET /policies` à l'allowlist + spike live du filtre par tag **avant** tout claim natif.
4. **TOCTOU ITSM** : le gate prod (`Jenkinsfile.prod:77`) ne vérifie que `change_ref` non-vide ; ajouter un **re-check ITSM live** au dispatch (fail-closed 503 / 409 not-approved), sinon un changement retiré après approbation part quand même.
5. **Garde clé-privée bypassable** : `strings.Contains("PRIVATE KEY")` (`manifest.go:250`) laisse passer une clé DER base64 sans header ⇒ **parser/typer le PEM/DER (assert = certificat)**.
6. **Gate prod hardcodé mono-tenant** (`banking-demo`) ⇒ paramétrer tenant/chemin pour le poly-repo, sinon le zéro-trust ne couvre qu'un tenant.
7. **`apiKey`-mode sur wM** : prouvé seulement sur APISIX (`key-auth`) ; l'`Identify&Authorize(apiKey)` reste à projeter sur wM.

## Phasing (incrémental, réversible)

- **Phase 0 — Trancher les décisions bloquantes** (ci-dessous) + faire ratifier ADR-071/072/075/076 par le Council. Rien d'irréversible.
- **Phase 1 (première marche, demandée) — « push base defs to git »** : un repo projet pilote (`accounts-team`), shard byte-compatible. L'équipe pousse **seulement** `openapi.yaml` + `api.yaml` + `target.yaml`. CI de PR **read-only** : commitlint + `validate` UAC + `labctl plan` dry-run. **Aucune écriture gateway.**
- **Phase 2 — CREATE → PUBLISH sur dev** : webhook par repo (`registry/projects.yaml`) → `ci/Jenkinsfile` hors-prod → `labctl build` air-gapped → `apply` (`POST /apis` import) → `apply-uac --env dev`.
- **Phase 3 — Moteur de DÉRIVATION** `classification → required_policies` + `labctl render` + gate fail-closed. *La sécurité devient une fonction machine-vérifiée du niveau.* (Ferme l'écart n°1 de la §aspirationnel.)
- **Phase 4 — Application déployée AVEC l'API** : `labctl subscribe` dans le même run — cert mTLS (`httpsCertificate` + keystore, +allowlist), IP filtering (`ipAddressRange`), token INBOUND. Réutilise ADR-071.
- **Phase 5 — Catalogue central + tag fan-out** (couche prouvée) : `governance/policy` ; labctl résout `tag → bundle` et fan-out per-API. « Apply policy by tag » + IP filtering, honnêtement en control-plane routing.
- **Phase 6 — Promotion complète rec → int → prod + rollback par repo** : brancher `Jenkinsfile.prod`/`.rollback` sur le pilote, rejouer le 19/19 en poly-repo, étendre à `payments-team`.
- **Phase 7 — Combler les écarts d'enforcement** (chacun un spike) : mTLS require-cert, apiKey-mode wM, 2e alias internal/external, TokenProvider outbound as-code, **spike global-policy native**, vrai wM par env.
- **Phase 8 — Portabilité produit** : réconcilier avec STOA (CRD tenant, `VALID_PROMOTION_CHAINS`, `GatewayPolicyBinding` + dimension label-selector net-new), refléter dans stoa-docs. **Ne jamais** présenter ce scaffold comme le produit fini (POSITIONING C1).

## Décisions à trancher (Phase 0)

| # | Question | Reco | Note |
|---|---|---|---|
| 1 | **Échelle d'intégrité** ✅ **TRANCHÉE (2026-07-01)** | **Échelle LITTÉRALE client `VH/H/M`** (M = plancher) pour s'aligner sur le vocabulaire de l'auditeur ; « M/ApiKey » = OAuth2 par défaut, ApiKey-only permis pour M (`internal` + tag auditable). | Impact schéma **localisé** (§Impact enum) : `uac_contract_v1_schema.json` + `validate.go` — ~4 fichiers, pas le cross-repo produit. Reste : confirmer un éventuel niveau **L** sous M. |
| 2 | **Modèle git** : branches par-env vs **trunk + marqueurs** | Trunk + marqueurs (prouvé 19/19), `main`=cible prod ; hybride miroir `env/*` si besoin visuel | vue audit single-tree préservée |
| 3 | **Topologie** : poly-repo (demandé) vs monorepo | **Poly-repo byte-compatible** avec le monorepo (repli possible) + `registry/projects.yaml` | réversible par design |
| 4 | **Tag / global-policy** day-1 | Fan-out control-plane day-1 ; global-policy native **derrière spike** | ne jamais claim le natif avant preuve |
| 5 | **OAuth2 internal vs external** | internal = IdP interne / external = IdP partenaire (2 alias/stratégies par `exposure:*`) | « internal/external » = mot du client, confirmer le sens métier |
| 6 | **Custom tokens** : inbound / outbound / les deux | Les deux, distincts ; outbound (TokenProvider Vault-backed) central → as-code | confirmer la priorité du 1er cas d'usage |

## Conséquences

**Positives.** Un repo par projet **byte-compatible** avec le socle prouvé (split/merge sans schéma) ; la sécurité devient une **fonction dérivée + fail-closed** du niveau d'intégrité (opposable régulateur) ; un **catalogue central** qu'aucun repo projet ne peut affaiblir ; réutilisation intégrale d'`apply`/`subscribe`/`apply-uac`/proxies ADR-075/Vault ADR-074/TokenProvider ; l'additif (`render` + catalogue + multibranch) reste **mince** — le « dur » (Links maintenus, matrice, drift) reste la valeur produit (POSITIONING C1).

**Limites / risques assumés.** La matrice intégrité est **aspirationnelle jusqu'à Phase 3** ; mTLS/global-policy native derrière allowlist + spike ; dev/rec/int restent des **mocks** (vrai wM par env = cible) ; **blast-radius** du catalogue central (une mauvaise édition déplace toutes les APIs d'un niveau → exige son propre 4-yeux + `strategy.lock` par repo) ; **poly-repo plumbing** (N webhooks, dérive de catalogue entre repos, sérialisation prod à repenser) ; ADR-071/072/075/076 **non ratifiés** (`host.docker.internal` du rollback = commodité PoC).

## Alternatives écartées

- **Manifeste-first pur (branche-par-env)** — rejeté : diverge du modèle prouvé trunk+marqueurs, perd la vue audit single-tree.
- **Tag-driven pur (repo ultra-thin)** — rejeté : masque la classification comme simple tag ; on la garde comme champ UAC de premier ordre régulateur-facing.
- **Global-policy native wM par tag day-1** — rejeté (day-1) : non vérifié sur 10.15 + hors allowlist ; livré en fan-out control-plane, native derrière spike.
- **Classification posée par l'équipe dans son propre repo** — rejeté : downgrade-spoofable ; assignée centralement (data-governance), référencée read-only par le projet.
- **Monorepo conservé** — non retenu comme cible (le client demande le poly-repo) mais **gardé byte-compatible** comme filet de repli.

## Definition of Done de cet ADR

- Décisions Phase 0 tranchées (surtout #1, l'échelle d'intégrité) et ADR ratifié Council (GO/NO-GO).
- Repo pilote `accounts-team` **byte-compatible** (prouvé : un fichier committé est projetable par labctl sans transformation).
- CI de PR read-only verte (commitlint + `validate` + `labctl plan`) **sans toucher une gateway**.
- Aucun secret en Git ; garde clé-privée **durcie** (parse/type PEM/DER).
- La matrice intégrité **n'est présentée comme enforced qu'après Phase 3** (dérivation + gate fail-closed livrés et prouvés).

## Références

- [[adr-069-retention-moat-governance-source-of-truth]], [[adr-071-partner-onboarding-as-code]], [[adr-072-control-plane-mediation]], [[adr-074-vault-secrets]], [[adr-075-wm-admin-proxy-multienv]].
- PoC `stoa-labs` — briques réutilisées : `ci/Jenkinsfile{,.prod,.rollback}`, `labctl/` (dispatch + adapters + `internal/uac` + `internal/governance` + `cmd/governance-api`), `envs/{env}/targets.cluster.yaml`, `gateways/webmethods/token-provider/` (TokenProvider outbound).
- `POSITIONING.md` (garde-fou C1 : ne jamais réduire STOA au pipeline de glue).
