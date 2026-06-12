---
title: "ADR-075 — Multi-env webMethods sans gateway de promotion : rebuild-from-Git idempotent par env, différences portées par les aliases, et 3 APIs proxy admin sœurs allowlist OAuth2-scopées comme unique chemin vers les envs bas"
sidebar_label: "ADR-075 : Proxy admin wM multi-env"
status: "Proposé — en attente Council (GO/NO-GO)"
date: 2026-06-12
adr_number: 75
visibility: private
note: "Privé (stoa-labs). S'appuie sur ADR-069 (Git source de vérité), ADR-072 (médiation control-plane), ADR-074 (secrets Vault). Ne pas porter dans stoa-docs (public)."
---

# ADR-075 — Proxy admin wM multi-env

**Statut :** Proposé — en attente validation Council (GO/NO-GO).
**Date :** 2026-06-12.
**Contexte client (anonymisé) :** banque — webMethods API Gateway 10.15, chaîne d'environnements dev → rec → int → prod, Jenkins n'ayant de route réseau QUE vers la zone prod.
**Lié à :** [[adr-069-retention-moat-governance-source-of-truth]], [[adr-072-control-plane-mediation]], [[adr-074-vault-secrets]].

> ⚠️ **Confidentialité.** Topologie d'environnements et de promotion d'une banque. Vit dans `stoa-labs` (privé), **pas** dans `stoa-docs` (public).

---

## Décision (test « archi 40 ans / 30 secondes »)

> On ne promeut **pas un export** de gateway, on **reconstruit chaque env depuis Git** : `apply-uac --env {dev|rec|int|prod}` est **idempotent** et projette le **même contrat** partout ; **tout ce qui diffère par env** (backend, credential sortant) vit dans **deux aliases wM** (`{api}-backend`, `{api}-backend-cred`) — la résolution `${alias}` est **par requête**, changer la valeur re-route **instantanément**, sans réactivation. Comme Jenkins n'a de route que vers la prod, les envs bas sont administrés via **3 APIs proxy SŒURS** (`wm-admin-dev|rec|int`) portées par le wM **prod** : **même contrat allowlist** (uniquement les chemins admin que labctl utilise, **aucun DELETE**), chacune **OAuth2-scopée** (`deploy:{env}`) et routée `${alias}` vers le gateway de SON env — au lieu d'une seule API à routing conditionnel.
> **Test** : *peut-on reconstruire l'env rec à l'identique depuis un commit, et un pipeline qui détient le token hors-prod peut-il toucher la prod ?* Si la réponse n'est pas « oui » puis « non, le scope manque, fail-closed », la chaîne d'environnements n'est ni rejouable ni cloisonnée.

---

## Contexte et problème

1. **La « gateway de promotion » wM est une copie d'état opaque.** Le mécanisme produit (promotion management) duplique des objets d'un runtime vers un autre : c'est un **2e runtime à opérer**, un état **non diffable** (pas de PR, pas de revert), et une promotion **non rejouable** (l'état source bouge). À l'opposé d'ADR-069 (Git source de vérité) et de la convergence idempotente déjà prouvée par labctl (read-back-assert, re-apply défensif).
2. **Contrainte réseau réelle : Jenkins → prod uniquement.** Le CI du client n'a de flux ouvert que vers la zone prod. Les gateways dev/rec/int sont **injoignables** de Jenkins — il faut un chemin d'administration **médié**, pas une ouverture de flux par env (refusée par la sécurité réseau, à raison).
3. **Les différences par env** (URL backend, credential sortant) étaient embarquées dans la policy de routage — donc re-importer le contrat dans un autre env exigeait de réécrire la policy. Il faut **séparer le contrat (identique partout) de la matière par env**.

---

## Décision détaillée

### 1. Rebuild-from-Git idempotent par env

`labctl apply-uac --env {dev|rec|int|prod}` (chaîne lue dans `environments.yaml` du repo governance) projette le contrat UAC versionné sur la cible de l'env (`envs/{env}/targets[.cluster].yaml`). Le gate de promotion est **GIT** : un env sans `deploy.{env}.yaml` mergé est **skippé** (narration) ; la prod exige un `commit` **pinné** dans `deploy.prod.yaml` (la version déployée = la version approuvée). Re-apply = converge (read-only si déjà convergé) — **prouvé** : le PUT de re-import préserve la policy et l'action de routage `${alias}` sur ce build.

### 2. Les différences par env = deux aliases wM

- `{api}-backend` (endpoint alias) : l'URL backend de CET env. Le routage `straightThroughRouting` pointe `${<alias>}/${sys:resource_path}` — résolution **par requête**, un changement d'alias re-route **instantanément** sans réactivation de l'API.
- `{api}-backend-cred` (credential alias `httpTransportSecurityAlias`, HTTP_BASIC) : le credential sortant de CET env, référencé `${<alias>}` par l'action *Outbound Auth – Transport*.

Le contrat et la policy sont **identiques** dans tous les envs ; seules les **valeurs** d'aliases diffèrent — et elles viennent de Vault (ADR-074), jamais de Git.

### 3. Trois APIs proxy admin SŒURS (au lieu du routing conditionnel)

Le wM **prod** (seul joignable de Jenkins, seul pont vers le réseau interne `nonprod`) porte 3 APIs `wm-admin-{dev,rec,int}` :

- **Même contrat allowlist** (`gateways/webmethods/admin-proxy/wm-admin-proxy.openapi.yaml`) : UNIQUEMENT les chemins admin que labctl utilise (`/apis`, `/alias`, `/strategies`, `/scopes`, `/policyActions`, `/policies/{id}`, `/applications`, `/health`). **Aucun DELETE** : le rollback est un re-apply Git, jamais une suppression. Hors contrat → **404**.
- **OAuth2 par API sœur** : scope `deploy:{env}` + azp `ci-horsprod` exigés en entrée ; routage `${wm-admin-{env}}` vers le gateway de l'env ; Basic sortant depuis `wm-admin-{env}-cred` (valeurs `secret/stoa/envs/{env}/wm-admin`, posées par `scripts/setup-wm-admin-proxy.sh`, AppRole `proxy-provision` dédié).
- **Pourquoi des sœurs et pas une API unique à routing conditionnel** : la barrière d'autorisation devient **déclarative et par-ressource** (un scope = un env = une API, lisible dans le catalogue et auditable), au lieu d'une logique conditionnelle (header/path → env) **dans** la policy — invisible, non diffable, et dont une erreur d'écriture ouvre TOUS les envs. Trois objets identiques à un alias près = trivialement vérifiables.

Le client CI hors-prod (`ci-horsprod`, client_credentials) porte `deploy:dev+rec+int` **par défaut** et **jamais** `deploy:prod` : volé, il ne peut pas franchir la barrière prod (le scope n'existe pas pour lui).

---

## Findings du spike (REST 10.15, capturés LIVE data-plane)

À encoder tels quels — chacun a coûté une session de debug :

- **Endpoint alias** : `POST/PUT /rest/apigateway/alias`, body **NU** `{"name","type":"endpoint","endPointURI",…}` — casse EXACTE `endPointURI`. Read-back enveloppé `{"alias":{…}}`.
- **`${alias}` per-request** : le `straightThroughRouting` param `endpointUri` = `["${<alias>}/${sys:resource_path}"]`. Changer la **valeur** de l'alias re-route **instantanément** (sans réactivation).
- **⚠ PUT nu = no-op SILENCIEUX** : `PUT /policyActions/{id}` exige le body **ENVELOPPÉ** `{"policyAction":{"id":…}}` — un body nu renvoie **200 mais ne persiste RIEN**. D'où la règle : **toujours read-back-assert après PUT**.
- **Credential alias** : `httpAuthCredentials.password` doit être le **BASE64** du mot de passe (sinon stocké corrompu) ; au read-back le password est **masqué** (base64 d'astérisques) → drift sur `name`+`userName` seulement, **toujours réémettre le password au PUT**.
- **Outbound Auth – Transport** : paramètres dans **UN groupe imbriqué** `transportSecurity` (authType ALIAS / authMode NEW / alias `${cred}`) — à plat ⇒ **NPE 500** (`OutboundTransportSecurityFactory`).
- **Params inconnus à préserver** : l'UI ajoute `method: ["CUSTOM"]` au routage — le converge PUT le record **read-back** avec seulement `endpointUri` modifié.
- **Re-import** `PUT /apis/{id}` : policy + action routage **préservées** sur ce build (même id, `${alias}` intact) — la convergence reste **défensive** (read-only si déjà convergé).
- **Payload 200 Ko OK** ; chemin **hors contrat → 404** (c'est ce qui rend l'allowlist du proxy opposable).

---

## Modèle de sécurité par couches

| Couche | PoC | Cible banque |
|---|---|---|
| Réseau | `nonprod` **internal** : les gateways bas sans port publié ; le wM prod = **seul pont** | Zones/firewall existants **conservés** (mTLS inter-zones inclus) |
| Transport | HTTP compose interne | **mTLS conservé** + OAuth2 PAR-DESSUS (les couches s'empilent, aucune ne remplace l'autre) |
| AuthN/AuthZ entrante (proxy) | Bearer Keycloak : **scope `deploy:{env}` + azp `ci-horsprod` = opposables** (3/4 barrières enforce) | idem, AS bancaire |
| Audience | **fail-open sur le trial** (LIVE FINDING ADR-072/targets.yaml : l'introspection remote est inerte) — **jamais vendue comme barrière** ; projetée quand même pour un build qui l'honore | enforce via introspection RFC 7662 |
| Surface | **allowlist** par contrat (404 hors contrat), **aucun DELETE** | idem |
| Secrets | Vault, AppRole `proxy-provision` **dédié** (ni `stoa-ci` ni `stoa-labctl` ne lisent `envs/+/wm-admin` — 403 prouvé en démo) | idem + rotation |

---

## Process multi-env

| Transition | Gate |
|---|---|
| **→ dev, → rec** | push provider mergé → webhook → pipeline hors-prod (auto) — `deploy.dev/rec.yaml` au fil de l'eau |
| **rec → int** | promotion par référence (`pr_xxx`) **approuvée par l'équipe int** (`approverGroup`) → merge `deploy.int.yaml` → convergence |
| **int → prod** | promotion + **change ITSM approuvé** (`change_ref`, vérifié auprès de l'ITSM — 409 si draft, 503 si non configuré) + **preuve de validation** (`pv_ref`) + **4-yeux** (`approved_by != requested_by`, self-approval → 403) → `ci/Jenkinsfile.prod` (AUCUN trigger), gate **Git-natif** relu avant tout dispatch |
| **rollback** | `ci/Jenkinsfile.rollback` : revert **Git** ordonné par governance-api (raison + change ITSM, audité) + **re-apply idempotent** — jamais de suppression gateway |

---

## Conséquences

**Positives.** Chaque env est **reconstructible depuis un commit** (disaster recovery = re-apply) ; la promotion est un **merge diffable/réversible**, pas une copie d'état ; **pas de 2e runtime** de promotion à opérer ; Jenkins ne voit **jamais** un gateway bas ni son credential admin (token scopé uniquement, contre-épreuve réseau `getent hosts wm-mock-dev` → KO) ; le blast radius d'un token CI volé est **borné par scope** ; tout l'outillage existant (labctl idempotent, médiation ADR-072, Vault ADR-074) est **réutilisé tel quel** — le proxy est lui-même une API wM posée par `labctl apply`.

**Frontières / limites assumées.**
- **Audience fail-open sur le trial** : 3/4 barrières (signature + azp + scope). Documenté, jamais vendu.
- Le wM prod devient un **point de passage admin** des envs bas : sa dispo conditionne l'administration hors-prod (pas le data-plane des envs). Acceptable — c'est déjà l'actif le plus surveillé.
- **Latence double-hop** sur le plan admin uniquement (control plane, ADR-068 : jamais sur la transaction).
- Les mocks d'envs bas valident la **surface 10.15** et la résolution `${alias}` ; un wM réel par env reste la cible d'intégration finale.
- `host.docker.internal` (rollback job → governance-api host) est une commodité PoC, pas un modèle cible.

---

## Alternatives écartées

- **Promotion management wM (copie d'état)** — rejeté : runtime supplémentaire, état opaque non diffable, promotion non rejouable, à rebours d'ADR-069.
- **Une API proxy unique à routing conditionnel (header/path → env)** — rejeté : l'autorisation par env devient une logique cachée dans une policy (non diffable, erreur = tous les envs ouverts) ; trois APIs sœurs rendent la barrière **déclarative, par-ressource, opposable par scope**.
- **Ouvrir des flux Jenkins → chaque env** — rejeté : multiplie les routes inter-zones (la sécurité réseau du client dit non) ; le proxy réutilise la SEULE route existante en y ajoutant allowlist + OAuth2.
- **DELETE dans l'allowlist pour « nettoyer »** — rejeté : la suppression contournerait Git ; le rollback est un revert + re-apply (état toujours reconstructible).
