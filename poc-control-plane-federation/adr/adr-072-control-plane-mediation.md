---
title: "ADR-072 — Médiation control-plane sur gateway mutualisée : le dev ne touche jamais l'admin gateway ; le control plane authentifie, autorise scoped-tenant, applique avec les creds plateforme, audite chaque mutation et rate-limite"
sidebar_label: "ADR-072 : Médiation control-plane"
status: "Proposé — en attente Council 8/10 (GO/NO-GO)"
maturite_technique: "✅ Livré & prouvé live — médiation (scripts 8/8·11/11·13/13·11/11)"
date: 2026-06-12
adr_number: 72
visibility: private
note: "Privé (stoa-labs). S'appuie sur ADR-067 (reuse-first), ADR-068 (hors data-plane), ADR-069 (Git source de vérité), ADR-070 (analytics/audit OpenSearch + pivot OTel), ADR-071 (onboarding as-code). Ne pas porter dans stoa-docs (public)."
---

# ADR-072 — Médiation control-plane (gateway mutualisée)

**Statut :** Proposé — en attente validation Council 8/10 (GO/NO-GO). *(axe gouvernance/business — distinct de la maturité technique ci-dessous)*
**Maturité technique :** ✅ Livré & prouvé live — scripts à compteurs (`test-onboarding-matrix` 8/8, `test-apply-scope` 11/11, `test-apply-audit` 13/13, `demo-mediation` 11/11).
**Date :** 2026-06-12.
**Contexte client (anonymisé) :** banque — gateways hétérogènes (WSO2 4.5, Apache APISIX 3.11, webMethods 10.15) **mutualisées** entre équipes/tenants.
**Lié à :** [[adr-067-reuse-first-owned-portable-layer]], [[adr-068-stoa-off-the-transaction-path]], [[adr-069-retention-moat-governance-source-of-truth]], [[adr-070-opensearch-txn-analytics]], [[adr-071-partner-onboarding-as-code]].

> ⚠️ **Confidentialité.** Topologie d'accès control-plane d'une banque. Vit dans `stoa-labs` (privé), **pas** dans `stoa-docs` (public).

---

## Décision (test « archi 40 ans / 30 secondes »)

> Sur une gateway **mutualisée**, un développeur **ne touche JAMAIS l'API d'admin** de la gateway. Le **control plane médie** chaque changement : il **authentifie** (OAuth2/OIDC, JWKS RS256 local), **autorise scoped-tenant** (RBAC : rôle `partner-onboarder` côté écriture, rôle `cp-applier` côté apply, **liés à un tenant** par claim/groupe), **applique avec les creds plateforme** (que le dev ne voit jamais), **audite CHAQUE mutation** (index OpenSearch par tenant + `trace_id`, attribution Git), et **rate-limite** le plan management. Deux plans : **écriture** (`onboarding-api`, le dev écrit un manifeste validé) et **convergence/apply** (`labctl apply-uac`, la CI projette sur les gateways).
> **Test** : *un dev qui détient (par accident ou malveillance) les creds plateforme peut-il toucher les ressources d'un AUTRE tenant sur la gateway partagée, ou faire un changement non attribuable ?* Si oui, la gateway mutualisée est une passoire. La réponse doit être **non, fail-closed, et tracé**.

---

## Contexte et problème

L'onboarding as-code (ADR-071) a fermé le **plan d'écriture** : le dev POST un manifeste, `onboarding-api` l'authentifie + autorise + audite et **commit en Git** sans toucher la gateway. Mais le **plan de convergence** (`labctl apply-uac` / `subscribe`, exécuté par la CI **avec les creds plateforme**) restait **nu** : aucun acteur, aucun tenant enforce, aucun audit, aucun rate-limit.

Or l'**API d'admin d'une gateway est toute-puissante** (un `X-API-KEY` APISIX, un Basic `Administrator` webMethods, un password-grant WSO2 = tout le fleet). Sur une gateway **mutualisée** entre équipes (`banking-demo`, `payments-team`, …) où « **on ne fait pas confiance au dev à 100 %** », quatre trous restaient ouverts :

- **(a) Scoping tenant à l'apply** — un job qui applique pouvait toucher **n'importe quel** tenant.
- **(b) Attribution end-to-end** — un changement gateway n'était relié à **personne** (la gateway ne voit que `Administrator`).
- **(c) Rate-limit du plan management** — un dev pouvait **noyer** le plan partagé.
- **(d) Creds non-scopées** — l'admin gateway ne sait pas restreindre par tenant.

Ces trous **contredisent** la proposition STOA : ADR-068 (hors data-plane) et ADR-069 (Git source de vérité) ne valent que si **qui change quoi, pour quel tenant** est *enforce* et *tracé* sur le plan de contrôle lui-même.

---

## Décision détaillée — le modèle à deux plans

| Plan | Surface | AuthN | AuthZ (RBAC) | Audit | Rate-limit |
|------|---------|-------|--------------|-------|------------|
| **Écriture** (face dev) | `onboarding-api` `POST /applications` | Bearer Keycloak (JWKS RS256, `iss`+`exp`+`aud`) | rôle `partner-onboarder` + `body.tenant == token.tenant` | `audit-onboarding-{tenant}` + `trace_id` | **token-bucket par `actor+tenant`** → `429` |
| **Convergence** (CI, creds plateforme) | `labctl apply-uac` / `subscribe` | Bearer `cp-applier` optionnel (`LABCTL_TOKEN`) | rôle `cp-applier` + tenant du token **borne** le scope ; `--tenant` doit y correspondre | `audit-apply-{tenant}` + `trace_id` | cap de run (batch CI) |

**Noyau partagé** : un seul module `internal/authz` (extraction Bearer, check rôle, dérivation tenant claim/`/tenants/{t}`, IP) sert les **deux** binaires — une seule vérité « qui est l'appelant, quel rôle, quel tenant ».

### Comment les 4 gaps sont fermés

- **(a) Scoping tenant — ENFORCE, fail-closed.**
  1. **Intégrité** : le `tenant_id` d'un contrat UAC *published* DOIT égaler le tenant de son **chemin** `tenants/{tenant}/…` ; sinon le load **échoue** (anti-spoof : un contrat ne peut pas usurper l'identité d'un autre tenant).
  2. **Borne** : un token `cp-applier` **lie** le scope à son tenant ; `--tenant` divergent → **DENY** (« cross-tenant denied »), *avant tout dispatch*. Sans token, `--tenant`/`$LABCTL_TENANT` filtre (plus faible, documenté) ; sans rien → run **UNSCOPED** averti.
  3. Un contrat hors-scope est **skippé**, jamais projeté → un job ne peut **pas** muter les ressources d'un autre tenant **même en détenant les creds plateforme**.

- **(b) Attribution end-to-end — Git-first (ADR-069).** Chaque mutation gateway (`api.publish` / `consumer.subscribe`) → un event `{actor, principal, tenant, resource, gateway, decision, reason, commit_sha, trace_id}` dans `audit-apply-{tenant}`. `actor` = **auteur du commit** du manifeste (le dev responsable, lu via `git log`) ; `principal` = le **service account CI** `cp-applier`. Corrélation OTel par `trace_id` (ADR-070). La gateway ne voyant que `Administrator`, l'attribution dev/projet vient **du control plane**.

- **(c) Rate-limit — ENFORCE.** Middleware token-bucket in-process par `actor+tenant` sur `onboarding-api` (stdlib seul, air-gapped) → `429` **audité** `reason=rate_limited` au-delà du seuil (`ONBOARDING_RATE_PER_MIN`, défaut 20). Un tenant ne peut **pas** affamer le plan partagé.

- **(d) Creds non-scopées — ACTÉ + COMPENSÉ (documenté).** L'API d'admin gateway **est** toute-puissante : aucune des 3 gateways ne sait restreindre un credential admin « à un tenant ». **Le control plane EST la couche de scoping** : (i) les creds plateforme **ne quittent jamais** la CI/le control plane (le dev ne présente qu'un token OAuth — jamais l'`X-API-KEY`/Basic) ; (ii) le binding tenant (a) empêche un principal d'agir hors de son tenant ; (iii) le namespacing par tenant des **noms** de ressources est appliqué **là où c'est faisable pour les nouvelles ressources**, **non rétrofité** sur `accounts-read` pour préserver le data-plane prouvé (3/3). C'est une **frontière de confiance explicite**, pas une faille cachée.

### Matrice de flux (egress minimal)

- **Dev** → PR Git **ou** `onboarding-api` (HTTPS). **Dev ⇏ admin gateway.**
- **`onboarding-api` & CI/`labctl`** → IdP (Keycloak, JWKS) + gateways (admin) + OpenSearch (audit). **Rien d'autre.**
- L'egress audit→OpenSearch est celui du **control plane**, jamais du poste dev.

---

## Conséquences

**Positives.** Sur la gateway mutualisée : un changement cross-tenant est **refusé fail-closed et audité** ; chaque mutation est **attribuable** (dev + projet + commit + principal CI) et **isolée par tenant** dans OpenSearch (un viewer tenant lit `audit-*-{tenant}*` **uniquement**) ; le plan partagé est **protégé** du flooding ; le dev n'a **jamais** les creds gateway. Identité tenant **unique** sur les 3 plans (écriture/apply/data) après alignement `backstage.owner = banking-demo`.

**Frontières / limites assumées.**
- **(d)** reste une frontière de confiance : qui détient les creds plateforme (la CI) est *de facto* tout-puissant sur la gateway. La mitigation est organisationnelle (creds en Vault/PAM, rotation, le dev n'y accède pas) + le scoping control-plane. Documenté, non masqué.
- **Rate-limit in-process** : par instance `onboarding-api`. Un déploiement multi-réplicas exige un compteur **partagé** (Redis/gateway) — noté.
- **Audience `cp-applier`** : réutilise `aud=onboarding-api` dans le PoC ; en prod, un client/audience CI dédié.
- **Namespacing ressources** : non rétrofité sur `accounts-read` (data-plane 3/3 préservé). Suite : convention de nommage par tenant pour les nouvelles API.
- **txn-banking-demo Dashboards** : le rôle/sécurité viewer est provisionné ; l'index-pattern OSD (UI) est une suite cosmétique.

---

## Preuves (LIVE — « test vraiment avant de crier victoire »)

Tout est **rejouable** (air-gapped build, tokens Keycloak réels, OpenSearch réel, gateways réelles) :

| Script | Prouve | Résultat |
|--------|--------|----------|
| `scripts/test-onboarding-matrix.sh` | Write plane : 201 / 403 tenant_mismatch / 403 missing_role / 401 + audit ACCEPT/DENY | 8/8 |
| `scripts/test-apply-scope.sh` | Scoping apply : filtre `--tenant`, anti-spoof `tenant_id`, **cross-tenant DENY**, token borne le scope, UNSCOPED averti | 11/11 |
| `scripts/test-apply-audit.sh` | Audit apply : docs `audit-apply-{tenant}`, actor=auteur commit, principal cp-applier, `commit_sha`, **pivot `trace_id`**, isolation viewer | 13/13 |
| `scripts/test-onboarding-ratelimit.sh` | Rate-limit : 3×201 puis 429 **audité** `rate_limited` | 3/3 |
| `scripts/demo-mediation.sh` | **End-to-end 2 tenants × 2 plans** : banking + payments onboardent + appliquent leur propre API sur les **mêmes** gateways, cross-tenant refusé partout, isolation **symétrique** | 11/11 |
| `scripts/phase3-identity-demo.sh` | Data-plane préservé après re-tag : **1 token Oracle → 200 sur les 3 gateways**, 401 sans token | 3/3 |

---

## Alternatives écartées

- **Faire confiance au `--tenant` opérateur seul** (sans token) — rejeté : c'est une *sélection*, pas une *enforcement* ; un opérateur malveillant met n'importe quelle valeur. Le binding par token `cp-applier` est l'enforcement.
- **Per-tenant gateway admin credential** — impossible : les 3 gateways n'offrent pas de credential admin scopé-tenant. D'où (d) : le control plane est la couche de scoping.
- **Audit dans la même famille d'index que l'onboarding** — rejeté : `audit-apply-{tenant}` séparé garde write-plane vs apply-plane interrogeables distinctement ; le même viewer tenant (`audit-*-{tenant}*`) couvre les deux.
