---
title: "ADR-071 — Onboarding partenaire as-code : manifeste déclaratif par partenaire projeté par labctl, API self-service write-through-Git, certs publics + IP auditables par PR"
sidebar_label: "ADR-071 : Partner onboarding as-code"
status: "Proposé — en attente Council 8/10 (GO/NO-GO)"
maturite_technique: "✅ Livré & testé — onboarding as-code"
date: 2026-06-11
adr_number: 71
visibility: private
note: "Privé (stoa-labs). S'appuie sur ADR-067 (reuse-first / couche possédée portable), ADR-068 (hors data-plane), ADR-069 (douve de rétention / Git source de vérité). Ne pas porter dans stoa-docs (public)."
---

# ADR-071 — Onboarding partenaire as-code

**Statut :** Proposé — en attente validation Council 8/10 (GO/NO-GO). *(axe gouvernance/business — distinct de la maturité technique ci-dessous)*
**Maturité technique :** ✅ Livré & testé (`labctl/internal/onboarding`, `cmd/onboarding-api` ; DoD byte-compat + build air-gapped coché).
**Date :** 2026-06-11.
**Contexte client (anonymisé) :** banque — gateway webMethods API Gateway 10.15.
**Lié à :** [[adr-067-reuse-first-owned-portable-layer]], [[adr-068-stoa-off-the-transaction-path]], [[adr-069-retention-moat-governance-source-of-truth]].

> ⚠️ **Confidentialité.** Positionnement + topologie d'onboarding bancaire. Vit dans `stoa-labs` (privé), **pas** dans `stoa-docs` (public).

---

## Décision (test « archi 40 ans / 30 secondes »)

> Onboarder un partenaire/application sur la gateway devient **déclaratif**. Un **manifeste partenaire** (un fichier YAML par partenaire, par tenant) décrit l'intention : `clientId`, APIs souscrites, **token d'identité custom**, **liste d'IP**, **certificat PUBLIC**. **labctl** projette ce manifeste sur la gateway — application + souscription + stratégie + identifiers (token / `ipAddressRange` / `httpsCertificate` + truststore) — **idempotemment**. Le manifeste vit **dans Git** (GitOps/CI) ; une **API self-service write-through-Git** (`onboarding-api`, `POST /applications`) laisse le dev de l'IdP **écrire** ce manifeste (validé) **sans jamais toucher la gateway**.
> **Frontière nette** : l'API **valide et commit**, point. **STOA ne configure pas le flux**, ne touche pas le data-plane (ADR-068) ; **Git est la source de vérité** (ADR-069) ; ce qui est en Git est **non-secret et auditable par PR** (cert public + IP + tokens de test) — **les secrets (client secret, clés privées) vivent dans Vault/PAM**, jamais en Git.
> **Test** : *l'onboarding d'un partenaire est-il un diff Git revu par PR, rejouable et réversible — sans qu'aucun composant STOA ne soit sur le chemin de la transaction ?* Si non, c'est l'onboarding manuel d'aujourd'hui, et la douve n'existe pas.

---

## Contexte et problème

Aujourd'hui, onboarder un partenaire sur la gateway wM se fait **À LA MAIN**, via la console : (1) créer l'**application**, (2) y poser un **certificat public** (truststore + identifier), (3) déclarer une **liste d'IP**, (4) créer la **souscription** + la **stratégie**, (5) poser une **identité custom** dans un identifier de type **TOKEN**. C'est **documenté mais manuel** → non déclaratif, non rejouable, **non auditable** (qui a ajouté quelle IP, quand, pourquoi ? introuvable sans fouiller des logs gateway), source de dérive entre environnements et d'erreurs de copier-coller sur des éléments de sécurité (un IP de trop = une faille).

Ce gap **contredit** la proposition de valeur STOA :
- **ADR-067** (couche possédée portable, « Define Once → Expose Everywhere ») : si l'onboarding est manuel et propre à wM, il n'est ni portable ni neutre vendor.
- **ADR-068** (hors data-plane) : un onboarding « API → écrit direct dans wM » remettrait un composant STOA sur le chemin de contrôle runtime du partenaire.
- **ADR-069** (douve = Git source de vérité) : sans manifeste en Git, il n'y a **pas** de source de vérité auditable de **qui peut appeler quoi** — donc pas de douve sur l'onboarding.

Le **socle existe déjà** dans labctl et doit être **réutilisé, pas refait** :
- `labctl subscribe` (`cmd/labctl/subscribe.go`) provisionne un consumer : client Keycloak + application/consumer sur les 3 gateways.
- L'adapter wM (`internal/adapter/webmethods/consumer.go`) crée l'**application** wM avec un identifier `azp`/`openIdClaims` + `authStrategyIds` + la souscription ; la strategy/scope/policy IAM (`oauth2.go`/`inboundauth.go`) sont projetées.
- `targets.yaml` porte déjà `keycloak.consumerClientId` et le target webMethods.

Il manque : (a) un endroit **déclaratif** où décrire le partenaire (token/IP/cert), (b) la **projection** de ces trois éléments par l'adapter, (c) une **API self-service** pour que le dev de l'IdP s'auto-serve **sans accès gateway**.

## Forces en présence (decision drivers)

- **Auditabilité** : tout ajout d'IP / de cert / de token doit être un **diff Git revu par PR** (les 4 yeux), pas un clic non tracé en console.
- **Sécurité du Git** : cert **public** + IP + tokens de **test** = configuration non-secrète → **OK en Git**. Clé privée / client secret = **secret** → **Vault/PAM**, **jamais** committé. Garde **fail-closed** : une clé privée présentée est **refusée**.
- **Hors data-plane** (ADR-068) : l'API d'onboarding **n'appelle jamais** wM. Elle écrit un commit ; la **CI / `labctl`** convergent la gateway. Aucun composant STOA n'est sur le chemin du partenaire.
- **Reuse-first** (ADR-067) : réutiliser `labctl subscribe`, l'adapter wM, le moteur write-through-Git de `internal/governance` (commit signé, re-lecture depuis Git, idempotence). Ne **rien** réécrire.
- **Idempotence** : rejouer le manifeste converge (PUT/upsert par `(key,name)` ; commit identique = no-op). Champs absents → comportement actuel **inchangé** (`azp`/`openIdClaims` seuls).
- **Neutralité vendor** : le manifeste est **agnostique** ; wM matérialise les identifiers, les gateways qui ne modélisent pas d'identifiers par application (WSO2/APISIX) **ignorent** le bloc.

## Options considérées

1. **★ Manifeste déclaratif + projection labctl + API write-through-Git.** **Retenu.** Un fichier partenaire en Git, projeté idempotemment par l'adapter wM ; une API self-service qui **valide et commit** (jamais ne touche la gateway). Auditable, rejouable, hors data-plane, source de vérité unique.
2. **API qui écrit directement dans wM (REST admin).** *Rejeté.* Remet un composant STOA sur le chemin de contrôle runtime (rupture ADR-068) ; pas de diff revu (rupture du modèle 4 yeux / ADR-069) ; couple l'API à wM (rupture neutralité ADR-067) ; pas de réversibilité « `git revert` ».
3. **Statu quo documenté (runbook manuel).** *Rejeté comme cible.* C'est le gap actuel : non déclaratif, non auditable, non portable. Conservé seulement comme **fallback opérateur** (seed truststore hors-bande) quand un build gateway n'expose pas l'endpoint keystore.

## Décision retenue

### 1. Le manifeste partenaire (source de vérité)

Un fichier **par partenaire, par tenant** : `tenants/{tenant}/partners/{name}.yaml`. Son bloc `spec.partner` est **byte-compatible** avec `targets.Partner` (mêmes tags JSON) — donc `labctl subscribe` / la CI le lisent **tel quel**. Exemple :

```yaml
# tenants/banking-demo/partners/acme-payments.yaml
# Généré par onboarding-api (write-through-Git, ADR-071).
# NON-SECRET : cert public + IP + tokens de test, auditables par PR.
# Les secrets (client secret, clés privées) vivent dans Vault/PAM, JAMAIS ici.
# Projeté par `labctl subscribe` / la CI — l'API ne touche JAMAIS la gateway (ADR-068).
apiVersion: labctl.stoa.dev/v1
kind: PartnerOnboarding
metadata:
  name: acme-payments
  tenant: banking-demo
spec:
  clientId: acme-payments-client          # azp du token Keycloak ; le SECRET n'est PAS ici
  apis:
    - accounts-read                        # slugs d'API publiées auxquelles le partenaire souscrit
  partner:
    tokenIdentifiers:                      # -> identifier wM key "token" (identité custom)
      - partner-token-abc
    ipAllowlist:                           # -> identifier wM key "ipAddressRange"
      - 203.0.113.10
      - 10.60.30.1-10.60.30.30
      - 192.168.0.0/24
    publicCertRef: |                       # -> truststore + identifier wM key "httpsCertificate"
      -----BEGIN CERTIFICATE-----
      MIIB...                              # certificat PUBLIC uniquement ; clé privée REFUSÉE
      -----END CERTIFICATE-----
```

`publicCertRef` accepte un PEM **inline** (ci-dessus) **ou** un chemin résolu relativement au manifeste (`./partners/acme/public.crt`) — un fichier référencé absent est une erreur de config détectée au **load**, pas en plein `subscribe`.

### 2. La projection labctl (l'adapter wM — déjà livré)

L'adapter wM projette les trois champs optionnels sur l'application wM, **additivement et idempotemment** (`internal/adapter/webmethods/identifiers.go`, `truststore.go`) :

- **token** → identifier application `key: "token"` (singulier — vérifié sur le trial live ; `tokens` est rejeté 400).
- **IP** → identifier `key: "ipAddressRange"` (IP, CIDR, ou plage `a.b.c.d-e.f.g.h`).
- **cert public** → **deux temps** : (1) le PEM est inscrit au **truststore** gateway (`/configurations/keystore`, l'ancre de confiance du handshake) **avant** de lier l'identité ; (2) identifier `key: "httpsCertificate"` (corps DER base64). Sans truststore, le handshake échoue avant toute évaluation d'identité.

La projection **lit l'application, merge par `(key,name)`** sans toucher à `azp`/`openIdClaims` ni aux `authStrategyIds`, puis PUT l'enregistrement complet. **Convergé = aucun PUT.** Tous champs absents ⇒ aucune lecture/écriture supplémentaire, byte-identique à avant. Une **clé privée** dans `publicCertRef` est **refusée** (`assertNoPrivateKey`). Les gateways sans identifiers par application (WSO2/APISIX) ignorent le bloc.

### 3. L'API write-through-Git (`onboarding-api` — scaffold livré)

Un service Go autonome (`cmd/onboarding-api/`) expose `POST /applications` :

```
POST /applications
{ "name", "tenant", "clientId", "apis":[...],
  "ipAllowlist":[...], "publicCert":"<PEM public>", "tokenIdentifiers":[...] }
```

Pipeline : **valider** (`internal/onboarding/manifest.go` : slugs DNS, IP/CIDR/plage, présence d'un bloc CERTIFICATE, **refus de toute clé privée**, dédup) → **projeter** sur un `Manifest` → **écrire** ce manifeste dans le **repo governance** via le moteur write-through-Git **réutilisé** de `internal/governance.Repo` : `switch main` → write+stage → commit (auteur = l'acteur IdP, committer = `governance-bot`) → re-lecture **depuis Git**. **Idempotent** : un POST identique = contenu byte-identique = pas de nouveau commit (renvoie le head courant). Le commit porte les **trailers d'audit** §3 (`Action: partner.onboard`, `Resource`, `Actor`, `Roles`).

**L'API ne touche JAMAIS wM** (`Service` n'a **aucun** client gateway — vérifié par construction). Ensuite, la **CI** (ou un `labctl subscribe` sur le manifeste) converge la gateway. C'est exactement la séparation ADR-068 : l'API **gouverne** (commit), la CI **converge** (projection), STOA **n'est pas** sur le chemin de la transaction.

### 4. Frontière secrets / non-secrets

| Élément | Nature | Emplacement | Auditable par PR |
|---|---|---|---|
| Certificat **public** (PEM) | non-secret | **Git** (manifeste) | ✅ |
| Liste d'**IP** / ranges | non-secret | **Git** (manifeste) | ✅ |
| **Token** de test / identité custom non-sensible | non-secret | **Git** (manifeste) | ✅ |
| **client secret** Keycloak | secret | **Vault/PAM** (référencé), minté par `labctl subscribe` | ❌ jamais inline |
| **Clé privée** (toute forme) | secret | **Vault/PAM** | ❌ **refusée** par l'API et l'adapter |

## Conséquences

**Positives**
- **L'onboarding devient un diff Git revu par PR** : qui ajoute quelle IP / quel cert / quel token est **tracé, revu (4 yeux), rejouable, réversible** (`git revert`). Le gap manuel non auditable est **fermé**.
- **Hors data-plane strict** (ADR-068) : l'API ne fait qu'un commit ; aucun composant STOA sur le chemin du partenaire. La projection est confiée à la CI/labctl.
- **Source de vérité unique en Git** (ADR-069) : la douve s'étend à **qui peut appeler quoi** ; coût de sortie élevé (toute la posture d'accès partenaire est en Git, neutre vendor).
- **Reuse-first** (ADR-067) : réutilise `labctl subscribe`, l'adapter wM, le moteur write-through-Git de `internal/governance` — **zéro** réécriture du chemin de commit.
- **Idempotent & non-régressif** : champs absents ⇒ comportement actuel inchangé ; rejeu ⇒ no-op. Toute la suite de tests wM existante **reste verte**.
- **Sécurité par construction** : la clé privée est refusée à deux endroits (API + adapter) ; seuls cert public + IP + tokens non-sensibles atteignent Git.

**Négatives / risques (assumés)**
- **Clés d'identifiers wM pinnées sur le trial** (`token` / `ipAddressRange` / `httpsCertificate`) : l'enum 10.15 est fixe ; un drift de build se corrige en **un** endroit (vars de package overridables), mais reste à re-vérifier sur l'instance cliente.
- **wM flappe (trial ~25 min)** : la projection truststore est **best-effort** (un build sans `/configurations/keystore` ne casse pas le `subscribe` — l'identifier application reste l'attache d'identité ; le truststore peut être seedé hors-bande). À re-valider sur instance stable.
- **Le scaffold API n'a pas de RBAC/JWT** : l'acteur du commit vient des en-têtes `X-Actor-*` (un IdP/gateway le fronte en prod). La vérification JWT/RBAC complète reste la responsabilité de `governance-api` (contrat Console Light) si l'on fusionne les surfaces.
- **Souscription `apis[]`** : le manifeste **déclare** les APIs ; la création effective de la souscription/stratégie reste opérée par `labctl subscribe` à partir de `clientId` + des APIs — l'API d'onboarding **ne** crée **pas** la souscription elle-même (par dessein : elle commit, la CI converge).

## Non couvert / différé (à tracer ailleurs)

- **Fusion API onboarding ↔ governance-api** (RBAC/JWT Keycloak, contrat Console Light) si l'on veut une seule surface gouvernée.
- **Référencement Vault/PAM dans le manifeste** (syntaxe `vault://...` pour un token sensible) → tâche de design secrets.
- **Boucle CI complète** « PR mergée → `labctl subscribe` → gateway convergée » sur le repo governance Gitea (`ci/governance`) → tâche GitOps.
- **PR automatique vs commit direct main** : le scaffold commit sur `main` (write-through direct) ; un mode « ouvre une branche/PR » (revue 4-yeux obligatoire avant convergence) est un knob à ajouter (le moteur `CreateBranchCommit`/`MergeBranchCommit` existe déjà dans `internal/governance`).

## Références

- [[adr-067-reuse-first-owned-portable-layer]] (couche possédée portable / Define Once), [[adr-068-stoa-off-the-transaction-path]] (hors data-plane), [[adr-069-retention-moat-governance-source-of-truth]] (douve / Git source de vérité).
- PoC `stoa-labs` — code livré :
  - `labctl/internal/onboarding/manifest.go` (schéma manifeste + validation + refus clé privée), `service.go` (write-through-Git, jamais de gateway).
  - `labctl/cmd/onboarding-api/` (`POST /applications`, stdlib + YAML vendoré).
  - `labctl/internal/adapter/webmethods/identifiers.go`, `truststore.go`, `consumer.go` (projection token/IP/cert idempotente).
  - `labctl/internal/targets/targets.go` (`Partner`), `load.go` (résolution `publicCertRef`), `cmd/labctl/subscribe.go` (câblage `Partner` → `ConsumerSpec`).
  - `labctl/internal/governance/gitrepo.go` (moteur write-through-Git réutilisé : commit signé, re-lecture depuis Git, idempotence).
- Doc de référence interne : `stoa-infra/ansible/reconcile-webmethods/upsert-application.yml` (identifiers `azp`/`openIdClaims`), `sync-gateway-config.yml` (keystore/truststore).

## Definition of Done de cet ADR

- Validé Council **8/10** (GO/NO-GO).
- Le manifeste partenaire est **byte-compatible** avec `targets.Partner` (prouvé par test) — un fichier committé est projetable par `labctl` sans transformation.
- L'API write-through-Git **écrit un manifeste valide** dans le repo governance **et ne touche jamais la gateway** (prouvé : `POST /applications` httptest + test service sur repo git réel).
- La garde **clé privée refusée** est effective côté API et côté adapter (prouvé par test).
- Build/test **air-gapped vert** (`GOPROXY=off GOFLAGS=-mod=vendor go build/vet/test ./...`), suite wM existante **inchangée**.

---

## Décisions par défaut retenues (2026-06-11) — pour avancer

| # | Question ouverte | Défaut retenu | Note |
|---|---|---|---|
| 1 | Emplacement manifeste | **`tenants/{tenant}/partners/{name}.yaml`** | un fichier = une unité de PR/audit/revert |
| 2 | Schéma manifeste | **`apiVersion: labctl.stoa.dev/v1`, `kind: PartnerOnboarding`** ; `spec.partner` ≡ `targets.Partner` | projetable tel quel |
| 3 | Cert / IP / token en Git | **OUI** (non-secrets, auditables par PR) | clé privée / client secret → **Vault/PAM** |
| 4 | Garde clé privée | **refus fail-closed** (API + adapter) | jamais de secret en Git |
| 5 | Cible de l'API | **write-through-Git uniquement** (commit) | **jamais** la gateway (ADR-068) |
| 6 | Moteur de commit | **réutiliser `internal/governance.Repo`** | commit auteur=acteur, committer=bot, re-lecture Git, idempotent |
| 7 | Convergence gateway | **CI / `labctl subscribe`** lisant le manifeste | l'API gouverne, la CI converge |
| 8 | Clés identifiers wM | **`token` / `ipAddressRange` / `httpsCertificate`** (pinnées trial, vars overridables) | drift build = 1 endroit |
| 9 | Auth API | **`X-Actor-*` (scaffold)** ; JWT/RBAC = `governance-api` si fusion | IdP/gateway fronte en prod |
| 10 | Mode écriture | **commit direct `main`** (write-through) ; branche/PR = knob différé | moteur branche/merge déjà présent |
| 11 | ADR | **071, `visibility: private`** | — |
