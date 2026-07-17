---
title: "ADR-079 — Déploiement & promotion multi-environnement sur gateways séparées segmentées (webMethods API Gateway 10.15) : import d'archive à GUID stables plutôt que rebuild-by-POST ou promotion native, conduit pluggable (hub-push VM → pull-agent cloud), alias & authorization-server par env posés hors archive, séparation source/artefact"
sidebar_label: "ADR-079 : déploiement/promotion multi-env (import archive, conduit pluggable)"
status: "Accepté (mécanisme) — topologie client actée (gateways SÉPARÉES segmentées + hub prod transitionnel, cible cloud sans gateway de promotion) ; mécanisme PROUVÉ live 22/22 + rôle apim_promote_api livré E2E ; restent les décisions client (dépôt d'artefacts, forme du pull-agent) et le résiduel bi-instances"
maturite_technique: "✅ Prouvé live (campagne de spikes 2026-07-17, apigateway-trial:10.15 réelle) — TOUTES les assertions : GUID préservés/iso (y compris env vierge), 0-coupure ×3 mesures (833/833, 741/741, 815/815 sous charge — y compris pendant un changement de routing livré par archive), souscriptions d'apps intactes, round-trip alias per-env complet, secrets hors archive (PassmanData découvert et strippé), L2 synthèse déterministe (GUID authored) ACCEPTÉE, scope-mappings hors archive (posés REST, AS par nom, API par GUID stable). 4 pièges découverts et fermés (isActive, clobber d'alias, ACDL-manifeste, binding nom→id). Rejouable : scripts/test-archive-promotion.sh 22/22 PASS. Rôle Ansible apim_promote_api LIVRÉ et prouvé E2E (EXPORT_CONFIRMED + PROMOTE_CONFIRMED + smoke 200, failed=0). Étayé aussi par (a) recherche éditeur (deep-research 2026-07-17, 99 agents, 25 claims vérifiés en 3-votes, 23 confirmés / 2 réfutés) : Software AG recommande la Promotion API, alias stage-scoped substitués à la promotion, GUID préservés à l'import overwrite same-ID, versioning inactive + Retain-applications, « Zero Downtime » doc = upgrade d'INSTANCE ≠ redeploy per-API ; (b) reverse-engineering de la base (labctl publish.go/routing.go, rôles Ansible). Résiduel : re-déroulé sur 2 instances physiques + E2E JWT bi-Keycloak (§ Résiduel)."
date: 2026-07-17
adr_number: 79
visibility: private
note: "Privé (stoa-labs). Révise le mécanisme de déploiement/MAJ wM par rapport à ADR-076 (rebuild-by-POST) et ADR-078 §7 (update deactivate→PUT→activate). Contexte client bancaire — ne pas porter dans stoa-docs (public). Voir mémoire projet wm-zero-downtime-deploy-constraint."
---

# ADR-079 — Déploiement & promotion multi-env (import d'archive à GUID stables, conduit pluggable)

**Statut :** Accepté (mécanisme prouvé + rôle livré). Topologie client **actée** (gateways séparées segmentées ; hub de promotion en prod aujourd'hui ; cible cloud **sans** gateway de promotion). Mécanisme **tranché et PROUVÉ** (import d'archive overwrite, pas rebuild-by-POST, pas promotion native) ; ex-points-suspendus **fermés** : hot-swap 0-coupure mesuré ×3, AS/scope-mapping tranché (par nom, hors archive, GUID stable).

**Maturité technique :** ✅ Prouvé live (campagne 2026-07-17) — toutes les assertions ✅, 4 pièges fermés, script 22/22, rôle `apim_promote_api` livré + prouvé E2E.
- ✅ **Étayé doc éditeur** (deep-research 2026-07-17) : (1) le repo DevOps officiel Software AG/IBM utilise la **Promotion API** (pas l'import/export) pour le CI/CD inter-env — *« The samples in this repository use the API Gateway Promotion APIs for automation of the Devops flow »* ; (2) les **alias stage-scoped** portent des valeurs par stage substituées à la promotion (tous types depuis 10.4, donc 10.15) ; (3) un import **same-ID écrase en place** avec le flag overwrite (sinon échoue « Asset already exists », jamais de doublon) — le graphe *« APIs, policies, policy actions, applications, scope mappings, aliases, users, groups and teams »* est écrasé/préservé ; (4) une nouvelle **version d'API est créée INACTIVE** quel que soit l'état de la source, activation explicite = bascule blue/green, option **Retain applications** ; (5) la fonctionnalité doc *« Zero Downtime / Upgrading Major Versions »* est un **upgrade d'INSTANCE** (blue-green + quiesce-drain + migration), **PAS** un redeploy per-API — ne pas la citer comme méthode de MAJ d'API.
- ✅ **Reverse-engineering de la base** : la base **reconstruit** l'API par `POST /apis` (clé `name+version`, `publish.go`) → GUID **différent par gateway** ; `PUT /apis/{id}` **refusé 400 sur API active** en 10.15 → cycle `deactivate→PUT→activate` = coupure (ADR-078 §7, prouvé live). Le moteur Go gère **déjà** l'endpoint alias (`endPointURI` per-env, `targets.yaml`) et le credential alias (Vault) comme des **appels REST séparés** de l'API (`routing.go`) — le bon pattern d'alias existe donc déjà côté Go, absent du rôle Ansible producteur.
- ✅ **Prouvé live (campagne 2026-07-17, `apigateway-trial:10.15` réelle — § Preuves de spike)** : GUID préservés/iso y compris env vierge ; 0-coupure ×3 mesures sous charge (dont un changement de routing livré par archive) ; souscriptions intactes ; round-trip alias per-env complet (flip à chaud, non-clobber, 2 parades au clobber) ; secrets hors archive (PassmanData strippé, chaîne Vault-first wire-testée) ; **L2 synthèse à GUID authored acceptée** ; scope-mappings posés par REST (AS par nom, API par GUID stable). **4 pièges découverts et fermés** : `isActive`, clobber d'alias, ACDL-manifeste (strip zip seul = cascade), binding nom→id (jamais delete/recreate).
- ✅ **Livré et prouvé E2E** : rôle **`apim_promote_api`** (export sanitizé + import alias-first 0-coupure) — run réel `ansible-playbook` : `EXPORT_CONFIRMED` (id-map, routing réécrit `${alias}`) puis `PROMOTE_CONFIRMED` (GUID iso, active, smoke 200), `failed=0`. Garde `UPDATE_FORBIDDEN` posée dans `apim_publish_api` (deactivate interdit hors env d'authoring). Preuve rejouable : `scripts/test-archive-promotion.sh` (22/22).

**Contexte client (anonymisé) :** banque. **Cible = gateways webMethods API Gateway 10.15 SÉPARÉES par environnement** (`dev / rec / int / homol / prod`), **flux réseau inter-environnements FERMÉS** (segmentation). Le client a **zéro tolérance à la coupure** du data-plane : **désactiver une API est inconcevable** — **sauf en `dev` à l'onboarding initial** (blip de première création toléré). En pratique le client déploie déjà via **export/import d'archive** ou l'outil de promotion et observe **zéro coupure**. Vault est disponible et gouverné. Solution réseau en place (VM) : une **gateway de promotion (hub) placée en prod**, flux ouverts vers tous les envs. **À terme (cloud), le client ne veut PAS faire tourner une gateway juste pour les promotions.** État actuel du stockage : l'**archive d'export unzipée est stockée dans Git** — jugé insatisfaisant par le client.

**Lié à :** [[adr-071-partner-onboarding-as-code]], [[adr-074-vault-secrets]], [[adr-075-wm-admin-proxy-multienv]], [[adr-076-gitops-api-lifecycle-repo-per-project]], [[adr-078-livrable-self-service-app-wm1015]].

> **Relation de révision.** Cet ADR **révise le mécanisme de déploiement/MAJ wM** de deux ADR antérieurs : il remplace, pour la **MAJ d'API**, le `deactivate→PUT→activate` d'**ADR-078 §7** (coupure, disqualifié chez ce client) ; et il remplace, pour la **projection wM**, le **rebuild-by-POST** implicite d'**ADR-076** (GUID non-iso, casse le graphe lié) par un **import d'archive à GUID stables**. La topologie **mono-proxy `X-Environment`** d'**ADR-075** est une **simplification de lab** : la cible client est **N gateways séparées** (un endpoint d'admin par env), ce que le conduit pull-agent adresse nativement.

> ⚠️ **Confidentialité.** Modèle de déploiement, topologie réseau et frontière secrets d'une banque. Vit dans `stoa-labs` (privé), **pas** dans `stoa-docs`.

---

## Décision (test « archi 40 ans / 30 secondes »)

> L'**unité de déploiement n'est pas une API qu'on recrée, c'est un bundle d'assets à GUID stables qu'on transporte.** Parce que tout le graphe webMethods — **scope-mappings**, applications/souscriptions, policies, assignation d'équipe, corrélation analytics — est **accroché au GUID de l'API**, reconstruire l'API par `POST` (chaque gateway forge son GUID) **orpheline le graphe** : livrer en prod obligerait à **refaire le scope-mapping** et re-câbler les souscriptions à la main. On déploie donc par **import d'archive avec `overwrite`**, qui **préserve les GUID** et écrase l'asset **en place, sans désactivation** (hot-swap ; les requêtes en vol terminent sur l'ancienne définition). Le `deactivate→PUT→activate` de l'API admin brute est **banni** (coupure) — sauf `dev` à l'onboarding.
>
> On **n'utilise ni la promotion native chaînée** (impossible sous segmentation : elle exige que chaque gateway atteigne la suivante, et elle rend la gateway-source autoritaire = drift) **ni une gateway dédiée à la promotion** (l'import tourne contre l'API admin de la gateway **cible elle-même** — un **job CI suffit**, la base le prouve déjà). Le « hub gateway en prod » est un **artefact réseau** du monde VM segmenté, **transitionnel**.
>
> On **sépare la source de vérité de l'artefact** : **Git** porte les **descripteurs authored** (OpenAPI + policies + scopes + scope-mappings), les **valeurs d'alias par env** (URL, *références* de creds — **jamais** les secrets) et un **id-map à GUID épinglés** ; l'**archive est un artefact de build** tagué dans un **dépôt d'artefacts**, **pas** dans Git. Les **valeurs qui changent par env** (backend, creds, authorization-server du scope-mapping) vivent dans des **alias/assets posés hors archive**, **réconciliés par le déployeur de l'env AVANT l'import de l'API** (alias-first), le secret venant du **Vault local à l'env**.
>
> Le **conduit est pluggable** : **invariant** = artefact + sémantique d'import (overwrite / alias-per-env / secrets Vault / alias-first) ; **variable** = transport, **hub-push (VM, aujourd'hui) → déployeur pull par env (cloud, cible)**.
>
> **Test** : *une même archive à GUID stables peut-elle être livrée à N gateways séparées et segmentées, mettre à jour une API active **sans une seule 5xx en vol**, en préservant scope-mappings et souscriptions, en faisant pointer chaque env vers son backend / son Keycloak / ses creds **sans éditer l'API ni mettre un secret dans l'archive ou dans Git**, et **sans faire tourner une gateway juste pour promouvoir** ?* Si l'une de ces réponses n'est pas « oui, mécaniquement », le modèle **retombe** soit dans la coupure, soit dans le graphe cassé, soit dans le secret-in-repo.

---

## Contexte et problème

La base **fonctionne** mais son mécanisme de déploiement wM est **inadapté à la cible client**. Quatre écarts, chacun tranché ci-dessous :

1. **Rebuild-by-POST → GUID non-iso → graphe cassé.** La base publie par `POST /apis` (clé `name+version`). Chaque gateway forge **son propre GUID**. Or scope-mappings, applications/souscriptions, policies et assignation d'équipe **référencent l'API par son GUID** (c'est *pourquoi* le versioning a une option « Retain applications »). Conséquence **mécanique** : livrer en prod puis **devoir refaire le scope-mapping** — inacceptable. Le repli « `name+version` suffit » ne tient **que** pour l'API nue.
2. **MAJ = coupure.** Le `PUT /apis/{id}` admin est **refusé 400 sur API active** (10.15, prouvé) → `deactivate→PUT→activate`. Le client **n'accepte aucune désactivation** (hors `dev` onboarding).
3. **Topologie réelle = gateways séparées segmentées.** Pas de flux inter-env → la promotion **native chaînée** `dev→…→prod` est **impossible**. Solution actuelle = **hub gateway en prod** avec flux vers tous les envs ; le client veut **s'en débarrasser** sur le cloud.
4. **Source de vérité = dump d'export dans Git.** L'archive unzipée stockée dans Git est une **sérialisation machine** (diffs bruyants), peut **contenir des secrets** (secret-in-repo, rédhibitoire en banque), est **couplée à la version** de gateway, et sa **provenance** dépend de quelle gateway a exporté.

---

## Options considérées

### A. Verbe de déploiement wM

| Option | Description | Verdict |
|---|---|---|
| **A1. `POST /apis` rebuild (base actuelle)** | Reconstruit l'API depuis l'OpenAPI, clé `name+version` | ✘ **GUID par gateway** (graphe orphelin) + **MAJ = coupure** (`PUT` 400 sur actif) |
| **A2. ★ Import d'archive `overwrite`** | Transporte le bundle d'assets à GUID stables ; import contre l'admin de la **cible** | ✅ **GUID préservés** (graphe intact) + **hot-swap en place** (0-coupure, à prouver) ; l'archive doit **exclure** la valeur d'alias per-env |
| **A3. Promotion Management API native** | Stages + `stagingURL`, substitution d'alias intégrée ; **reco Software AG** | ◐ Exige des **flux inter-gateway** (KO sous segmentation) **et** une gateway pour la porter ; rend la **gateway-source autoritaire** (drift) ⇒ écartée malgré la reco éditeur |

**Retenu : A2.** Déviation **assumée** de la reco éditeur (A3) : la Promotion API suppose la connectivité inter-stages (que la **segmentation interdit**) et fait de la gateway la source (contre notre posture Git). L'import d'archive est **vendor-supporté** (Archive REST API), **préserve les GUID**, tourne contre l'admin de la **cible** (donc **sans gateway de promotion**), et n'est qu'un **changement de verbe** par rapport à la base (qui importe déjà depuis un job CI).

### B. Conduit (transport vers les envs)

| Option | Description | Verdict |
|---|---|---|
| **B1. Hub gateway en prod, push (VM, actuel)** | Une gateway hub avec flux vers tous les envs importe dans chaque cible | ◐ **Transitionnel** : marche, mais = gateway en plus + **pont inter-env** (cible de grande valeur) ; le client veut la retirer sur cloud |
| **B2. ★ Déployeur pull par env (cloud, cible)** | Un job/agent **dans chaque env** pull l'archive + config + Vault local → importe dans la gateway **locale** | ✅ **0 gateway dédiée**, **0 flux inter-env**, **pont supprimé**, least-privilege trivial ; **outbound-initiated** (rien n'entre dans l'env) |

**Retenu : B2 en cible, B1 transitionnel** — via le **conduit pluggable** (§ Décision 3). Le placement du hub **en prod** (B1) est **conservé tel quel** en transition : il rend l'import prod **intra-zone** (aucun nouveau flux entrant en prod), seuls les flux **hub→env-inférieur** traversent (sens descendant).

### C. Source de vérité

| Option | Description | Verdict |
|---|---|---|
| **C1. Archive unzipée dans Git (actuel)** | Le dump d'export est la source | ✘ Sérialisation machine (diffs sales), risque **secret-in-repo**, couplé version, provenance ambiguë |
| **C2. Archive zipée dans Git** | Blob binaire versionné | ✘✘ Ni diff ni revue ; artefact dans un repo de sources |
| **C3. ★ Sources dans Git + archive en dépôt d'artefacts** | Git = descripteurs + valeurs d'alias per-env + id-map GUID ; archive = artefact de build tagué | ✅ Revue propre, **0 secret dans Git**, artefact reproductible, GUID épinglés hors du dump |

**Retenu : C3.**

### D. Alias / valeurs qui changent par env

| Option | Description | Verdict |
|---|---|---|
| **D1. Patcher l'archive par env (overlay type `aliases.json`)** | Réécrire la valeur d'alias dans l'archive avant import | ✘ Remet le **secret dans l'artefact** ; fragile (re-zip/checksum/provenance) ; acceptable au plus pour une URL **non-secrète** |
| **D2. Modifier l'alias APRÈS le déploiement** | Import puis correction de l'alias | ◐ **Fenêtre de routing faux** au premier déploiement d'un env neuf |
| **D3. ★ Alias hors archive, posé env-local, AVANT l'import (alias-first)** | L'API ne porte que la **référence** `${alias}` ; la valeur vit dans l'alias, posée par le déployeur (URL ← Git per-env, **secret ← Vault local**) **avant** l'import de l'API | ✅ Archive **env-invariante**, **0 secret** dans l'archive, ordre de bootstrap correct ; **déjà fait côté Go** (`routing.go`) |

**Retenu : D3.** Impératif d'implémentation : **exclure la valeur d'alias de l'archive d'API** (sinon l'import overwrite écraserait la valeur locale). Même principe pour la **référence d'authorization-server** d'un scope-mapping (valeur per-env).

---

## Décision retenue

### 1. Unité de déploiement = bundle à GUID stables, par import overwrite

L'archive transporte l'API **et ses assets liés** (scopes, **scope-mappings**, policies, éventuellement applications) **avec leurs GUID**. L'import avec `overwrite` **écrase en place** si l'asset existe (même GUID) — **jamais de doublon, jamais de nouveau GUID**. C'est ce qui garde le graphe **cohérent d'une gateway à l'autre**. `POST /apis` (rebuild) est **abandonné** pour le chemin client.

- **0-coupure (PROUVÉ, spike 2026-07-17)** : l'import overwrite écrase l'asset **actif en place sans coupure** — 833/833 requêtes 200 pendant un overwrite de 2,8 s sous charge 4-voies (vs le `PUT` admin refusé 400 sur API active, chemin abandonné).
- **🔴 RÈGLE ISSUE DU SPIKE — `isActive:true` obligatoire dans l'archive.** Une archive `isActive:false` **désactive l'API à l'import** (piège prouvé : 557/557 en 404 durable, pas un blip). Le build doit **exporter depuis l'état actif** ou **forcer `isActive:true`** dans l'archive livrée. Sans ça, chaque déploiement coupe l'API. (Fail-closed **des deux côtés** dans le rôle : `EXPORT_REFUSED` sur API inactive, `IMPORT_UNCONFIRMED` si inactive après import.)
- **🔴 RÈGLE — `overwrite` scoped, jamais `*` ni `aliases`.** `overwrite=apis,policies,policyactions` : un Alias résiduel dans une archive est alors **skippé** au lieu de **clobber** la valeur per-env locale (prouvé). Le rôle **refuse** `*`/`aliases` (fail-closed).
- **Jamais désactiver**, sauf **`dev` à l'onboarding initial** — **enforcé** : `apim_publish_api` refuse `update:true` hors `apim_pub_deactivate_envs` (`UPDATE_FORBIDDEN`, pointe vers `apim_promote_api`).

### 2. Changement cassant = versioning, pas édition en place

Pour un changement **non rétro-compatible** : **créer une nouvelle version d'API** (créée **INACTIVE** quel que soit l'état de la source) → **activer explicitement** (bascule blue/green) → **Retain applications** (les consommateurs gardent clés/souscriptions) → retirer l'ancienne. Contrainte CI : une version ne se crée **que depuis la dernière**. **Ne pas confondre** avec la feature doc *« Zero Downtime upgrade »* (= upgrade d'**instance**, hors sujet per-API).

### 3. Conduit pluggable — invariant vs variable

**Invariant (ne change jamais avec le transport) :**
- l'**artefact** : source Git (descripteurs + valeurs d'alias per-env + id-map GUID) + **archive taguée** en dépôt d'artefacts ;
- la **sémantique d'import** : `overwrite`, **alias-first**, **alias/AS per-env posés hors archive**, **secrets ← Vault de l'env cible**.

**Variable (le transport) :**

```
  TRANSITION (VM, aujourd'hui) — B1 hub-push
    CI (release taguée, vettée 4-yeux/ITSM) ──▶ hub gateway (prod, flux vers tous les envs)
                                                   └─ importe (overwrite) dans chaque gateway cible

  CIBLE (cloud) — B2 pull-agent par env
    chaque env: job/agent (K8s Job/CronJob/opérateur, ou runner CI dial-out)
        1. PULL archive taguée (dépôt d'artefacts) + config per-env (Git) + secrets (Vault LOCAL)
        2. réconcilie aliases + AS du scope-mapping (alias-first)
        3. IMPORT overwrite dans la gateway LOCALE (intra-env)
    → 0 flux inter-env ; outbound-initiated ; rien n'entre dans l'env
```

Le passage B1→B2 **ne touche ni l'artefact ni la sémantique** — c'est la propriété qui rend l'ADR « 40 ans ».

### 4. Source de vérité — séparer source et artefact

- **Git (source authored, reviewable, 0 secret)** : descripteurs (OpenAPI + policies + scopes + **scope-mappings**) ; **valeurs d'alias par env** (URL backend, *références* de creds, référence d'AS) ; **id-map à GUID épinglés** (API/scopes/apps, capturés une fois depuis l'export « golden »).
- **Dépôt d'artefacts (Nexus/Artifactory/OCI)** : l'**archive**, produite par la CI, **versionnée par tag de release**. **Pas dans Git.**
- **Deux niveaux de maturité de production de l'archive** (§ Décision 6).

### 5. Valeurs per-env = alias/assets posés hors archive, alias-first

L'API ne porte que des **références** `${alias}` (env-invariantes). Les **valeurs** (backend, creds, **authorization-server du scope-mapping**) sont des **assets séparés** posés/réconciliés par le **déployeur de l'env** **avant** l'import de l'API :
- URL backend ← config per-env (Git) ; **secret de creds ← Vault local à l'env** ;
- **AS du scope-mapping** (issuer/jwks/aud/client_id — Keycloak **différent par env**, cf. `per_env` d'ADR-078 §6) ← config per-env + Vault.

**Exclure ces valeurs de l'archive** (sinon overwrite les clobbe — prouvé) : le **sanitize d'export** strip `Alias/` + `PassmanData/` + purge l'ACDL, **et** re-pointe le routing sur `${backend_alias}` (l'authoring peut publier littéral, l'artefact livré route **toujours** par alias) ; l'import **refuse** une archive tainted et n'overwrite **jamais** le type `aliases`. **Règles de vie d'un alias (piège binding prouvé)** : `${alias}` est résolu **nom→id au déploiement** de l'API — **jamais delete/recreate** (502 durable), converger **par PUT** ; **alias-first** avant le premier import (alias manquant = 502 bruyant, réparable à chaud par re-import). Implémenté dans `apim_promote_api` (`tasks/alias.yml`, write-always pour les creds ← Vault) — aligné sur le moteur Go (`routing.go`).

### 6. Deux niveaux de maturité de l'archive

| Niveau | Production de l'archive | Compromis |
|---|---|---|
| **L1 — golden archive sanitizée** | Exportée depuis l'authoring (rôle `apim_promote_api` action=export), **capture l'id-map** ; promue inchangée | Simple, sûr, GUID stables ; c'est le **rôle livré** |
| **L2 — ★ synthèse déterministe** | La CI **fabrique** l'archive depuis (descripteurs + id-map à **GUID injectés**) | Git **pleinement autoritaire**, **0 dump**, aligné [[adr-076-gitops-api-lifecycle-repo-per-project]] ; **✅ FAISABILITÉ PROUVÉE** au spike : archive 100 % synthétisée (GUID `uuidgen`, sans `ExportReport.json` — set minimal `acdl` + `API/`) **acceptée**, GUID authored = GUID gateway, invoke OK |

**Départ L1 (livré), cible L2 (faisabilité prouvée — reste le générateur CI à écrire).** Le passage L1→L2 est **transparent** pour le conduit et la sémantique.

### 7. Gardes-fous du conduit (les deux transports)

- N'importer que des **archives vettées CI + 4-yeux/ITSM** (jamais d'ad-hoc) : la gate existante (`denials.jsonl`/governance) s'assoit **devant** l'action d'import.
- **Audit de chaque import** : qui / quoi / quand / **checksum d'archive** / env cible.
- Creds admin de la cible en **least-privilege** (droit d'import d'assets API, pas root infra), **par env, depuis Vault, rotés**.
- **B1 spécifiquement** : le hub est un **pont inter-environnements = cible de très grande valeur** — durci aux standards **prod** (puisqu'il atteint la prod), n'exécute que des archives signées/vettées.

---

## Preuves de spike (campagne complète 2026-07-17, `apigateway-trial:10.15` réelle)

Assets jetables `spike079-*`, gateway restaurée à l'identique en fin de campagne (0 résidu, vérifié). **Rejouable : `scripts/test-archive-promotion.sh` — 22/22 PASS.** Shapes REST **découvertes en live** (aucune n'était dans le code) :

| Opération | Appel | Notes |
|---|---|---|
| **Export** | `GET /rest/apigateway/archive?apis=<id>` (`,`-séparé) | zip = `API/API.<guid>/…` (JSON) + `APIGatewayAssets.acdl` (**le MANIFESTE** : GUID + `dependsOn`) + `ExportReport.json` (inutile à l'import) |
| **Import** | `POST /rest/apigateway/archive?overwrite=<types>` multipart `file=@zip` | HTTP 201 ; rapport `ArchiveResult[]` : `{status, overwritten, explanation, dependencyFailed}` par asset |
| **overwrite** | `*` = tout ; sinon **types pluriels minuscules** : `apis,policies,policyactions,aliases,…` | casse/singulier **silencieusement non reconnus** (= aucun overwrite) ; `apis` seul → échec en **cascade** (les policies non couvertes bloquent l'API) — confirme « il faut overwrite l'API **et** les policies » |

**A1 — GUID + graphe préservés ✅** : sans `overwrite` → `Failed "Asset already exists"`, **jamais de doublon** ; avec → API+Policy+PolicyActions `overwritten:true`, **mêmes GUID**. Sur **env vierge** (delete complet puis import fresh) → **tous les GUID de l'archive recréés à l'identique** = **promotion iso prouvée**.

**A2 — 0-coupure ✅ (3 mesures)** : 833/833 puis 741/741 puis 815/815 requêtes **200** sous charge 4-voies pendant l'overwrite (fenêtres 2,8 s à 14 s), **y compris pendant un CHANGEMENT DE ROUTING** (littéral → `${alias}`) livré par l'archive. **L'import d'archive est le chemin d'écriture universel 0-coupure** — il crée/modifie/attache aussi des policyActions sur une API active (prouvé : ajout d'une action outbound-auth par archive, jamais de désactivation), là où le `PUT` admin exige deactivate.

**🔴 A2bis — piège `isActive`** : une archive `isActive:false` **DÉSACTIVE l'API à l'import** (557/557 en **404 durable**, pas un blip). Ré-export depuis l'état actif → `isActive:true` → run propre. ⇒ l'archive livrée **DOIT** porter `isActive:true` (le rôle export/import le **fail-close** des deux côtés). Sur env vierge, une archive `isActive:true` **arrive active** (bon pour la promotion).

**A3 — souscriptions ✅** : application + registration (`PUT /applications/{id}/apis {"apiIDs":[guid]}`) **intactes après overwrite** — le lien app→API par GUID survit. (Corollaire mesuré : une app **souscrite bloque le `DELETE` de l'API** — la retirer d'abord dans un teardown.)

**A4 — per-env par alias ✅ (round-trip complet)** :
- le backend est **embarqué en dur** dans l'export (`nativeEndpoint.uri` + routing `endpointUri`, `alias:false`) → une archive à URL littérale est **clouée à l'env source** ⇒ router `${alias}` est **nécessaire** ;
- **flip de valeur d'alias = re-routage à chaud PAR REQUÊTE** (sans toucher l'API) ; re-import → **valeur locale préservée** (l'archive ne portant pas l'alias) ;
- **🔴 piège clobber** : l'export d'une API routée `${alias}` **EMBARQUE l'Alias** (valeur de l'env source) + entrée ACDL ; importé `overwrite=*`, il **écrase la valeur locale** (prouvé : `int` → `prod`). **Parades prouvées** : ① `overwrite=apis,policies,policyactions` (sans `aliases`) → l'Alias embarqué est **skippé sans cascade**, API/policies overwrités, valeur locale intacte ; ② archive **alias-free** = strip `Alias/` du zip **ET purge de l'ACDL** (asset + `dependsOn`) — le strip du zip **seul** échoue en cascade (l'ACDL est le manifeste). Le rôle applique **les deux** (sanitize à l'export + overwrite scoped + `ARCHIVE_TAINTED` fail-closed à l'import : un Alias embarqué **seederait la valeur de dev** sur un env vierge) ;
- **🔴 piège binding** : `${alias}` est résolu **nom→id AU DÉPLOIEMENT** de l'API (la valeur est lue par requête ensuite). Un alias **delete/recréé** (nouvel id, même nom) casse le routage **durablement** (502 `Downtime exception`), même une fois recréé. **Réparation 0-coupure : ré-importer l'archive** (re-résolution). ⇒ **jamais delete/recreate un alias — converger par PUT** ; **alias-first** avant le premier import (sinon 502 bruyant — fail-fort, pas de mauvais backend silencieux) ;
- **AS du scope-mapping** : strategy (`authServerAlias`) et scope (`requiredAuthScopes[].authServerAlias`) référencent l'AS **par NOM** → portable, l'alias auth-server étant posé par env (même nom, valeurs locales — `inbound.yml` le fait déjà).

**A4ter — types d'alias (complété 2026-07-17 soir)** : enum produit des `authType` du transport-security **épinglé par sonde d'erreur** : `ALIAS, NTLM, OAUTH2, REMOVE_INCOMING_HTTP_HEADERS, JWT, KERBEROS, HTTP_BASIC`. **NTLM prouvé live** : même conteneur `httpAuthCredentials` que BASIC **+ `domain`** (persisté au read-back, password masqué → write-always identique) ; **simple alias prouvé** : `{type:"simple", value}`. Rôle : `cred_alias.auth_type` HTTP_BASIC|NTLM (E2E `failed=0` : NTLM ← Vault avec `domain`, converge + read-back authType/user/domain) + bloc `aliases[]` générique sans secret (converge par nom, read-back champ à champ). KERBEROS/OAUTH2/JWT : **refusés fail-closed** (`CRED_TYPE_UNSUPPORTED`) tant que leur conteneur de creds n'est pas épinglé par spike. Le **strip** du sanitize et l'anti-clobber sont eux **type-agnostiques** (tout `Alias/*` + `PassmanData/*`).

**A5 — secrets hors archive ✅** : l'export d'un credential alias embarque le password **masqué** dans `Alias/` **mais le VRAI secret chiffré dans `PassmanData/`** (`EntrustAes` + salt — clé d'instance). ⇒ du matériel secret **voyage** dans une archive non-sanitizée : interdit banque, le sanitize **strip `Alias/` + `PassmanData/`**. Wire-test de la chaîne Vault-first : creds posées **par REST** (write-always, base64) + action outbound `${cred-alias}` livrée **par archive** → le backend reçoit **le vrai** `Basic backend-user:s3cret-pw`. Chaîne complète prouvée sans secret dans l'artefact.

**L2 — synthèse déterministe ✅ PROUVÉE** : archive **100 % fabriquée** (4 GUID choisis par `uuidgen`, jamais issus d'un export, **sans `ExportReport.json`** — set minimal = `APIGatewayAssets.acdl` + `API/`) → import accepté, **GUID authored = GUID gateway**, API **active**, invoke OK via `${alias}`. La CI peut **fabriquer l'artefact depuis Git** (descripteurs + id-map) sans jamais dépendre d'un export golden.

**Scope-mappings — ne voyagent PAS dans l'archive REST (doublement prouvé, complété 2026-07-17 soir)** : à l'**export**, `?apis=` ne les inclut pas et **9 noms de param candidats** (`scopes`, `oauthScopes`, `scopeMappings`, …) sont refusés ; à l'**import**, **5 types synthétisés** (`OAuthScope`, `Scope`, `OAuth2Scope`, `ScopeMapping`, `OAuthScopeMapping`) sont **ignorés en silence** (`ArchiveResult` vide — famille no-op). *(Piste résiduelle : tracer l'écran Export de l'UI admin si elle liste les scopes OAuth — extension Chrome non connectée au moment du test.)* ⇒ posés **par REST `/scopes`**, AS **par nom**, API **par GUID stable**.

**Modèle de scope-mapping — PER-API+VERSION (acté, aligné client)** : **un mapping par API+version** (`scopeName = "<name>:<version>"`), 1:1 avec l'unité de déploiement — pas d'état partagé multi-API à re-fusionner (l'ancien modèle de la base — un mapping par `AS:scope-externe` dont `apiScopes` **accumule** les APIs — recréerait un risque de clobber type-alias à l'apply). Le nom du mapping est **organisationnel** (le token matche `requiredAuthScopes.scopeName` = scope externe). Implémenté : `apim_publish_api/inbound.yml` (défaut per-API, ancien nommage via `inbound.scope_mapping_name`) + **`apim_promote_api/tasks/scope.yml`** (converge idempotent après import, fail-closed `SCOPE_AS_MISSING` si l'AS de l'env n'existe pas — alias-first pour l'AS aussi). **Prouvé E2E** (`failed=0`) : convergence d'un mapping existant, et **env vierge** → mapping **recréé lié au même GUID**, même nom — « le même scope mapping tout au long ».

## Alignement moteur Go — PORT LIVRÉ (2026-07-18)

Le binaire Go reste **parqué pour ce client** (provenance, ADR-078) — le livrable est Ansible — mais le moteur du lab est désormais **iso-sémantique**, port prouvé E2E sur la 10.15 live (`EXPORT_CONFIRMED` puis `PROMOTE_CONFIRMED`, sur **le même manifeste `.promote.yml`** que le rôle Ansible — un manifeste, deux moteurs) :

1. **Verbe archive** : `internal/adapter/webmethods/archive.go` — `ExportArchive` / `SanitizeArchive` (pure : whitelist API/+acdl, purge ACDL, strip Alias/PassmanData/ExportReport, réécriture routing `${backend_alias}` **idempotente**, fail-closed `ARCHIVE_INACTIVE`) / `ImportArchive` (refus `*`/`aliases`, `ARCHIVE_TAINTED`, rows aplatis fail-closed) / `VerifyAPIActive` (piège isActive) / `InvokeSmoke` — et la commande **`labctl promote`** (`cmd/labctl/promote.go` : merge `per_env` récursif fail-closed `ENV_UNDEFINED`, alias-first, Vault via `internal/vault`, `GUID_MISMATCH`, scope per-API, smoke).
2. **Alias** : primitives paramétrées `EnsureEndpointAliasValue` / `EnsureCredentialAliasValue` (**HTTP_BASIC + NTLM**, `domain`, write-always, autres types refusés `CRED_TYPE_UNSUPPORTED`) / `EnsureGenericAlias` (sans secret, read-back champ à champ) — `routing.go` délègue (plus de duplication), knobs `routingCredentialAuthType`/`routingCredentialDomain`.
3. **Scopes** : `scopeMappingName` **per-API+version par défaut** (`"<name>:<version>"`, `oauth2.go`), legacy partagé via l'option `inboundScopeMappingName` ; `EnsureScopeMappingPerAPI` (REPLACE `apiScopes=[guid]`, fail-closed `SCOPE_AS_MISSING`).
4. **Garde anti-deactivate** : knob adapter `allowDeactivate` (défaut `true` = lab) — à `false`, tout deactivate = **`UPDATE_FORBIDDEN` (ADR-079)** dans `setAPIActive`, le point unique des cycles guarded ; les configs d'envs non-authoring du client le posent à `false`.

Tests : suite Go **22 packages verts** — `archive_test.go` (sanitize strip+purge+rewrite+isActive, gardes overwrite/taint, aplatissement rows, gate deactivate) + `promote_test.go` (merge per_env, `ENV_UNDEFINED`) + `oauth2_test.go` migré per-API. **Impact lab assumé** : le naming per-API s'applique aux prochains applies (les mappings partagés `KeycloakStoaLab:*` existants restent en place, inoffensifs — rebuild-from-Git ; l'ancien nommage reste forçable par option).

## Résiduel (hors périmètre de cette campagne)

1. **Multi-instances physiques** : la campagne simule l'env vierge par delete+import sur **une** gateway (GUID iso prouvé au niveau du mécanisme — l'UUID est dans l'archive, pas généré par la cible). À re-dérouler sur 2 instances réelles à la livraison (le client observe déjà ce comportement en prod).
2. **Leg AS end-to-end** : le référencement **par nom** est prouvé (shapes + inbound.yml) ; un E2E JWT complet dev-KC→prod-KC (token accepté après bascule d'env) reste à jouer sur un env bi-Keycloak.
3. **PassmanData inter-instances** : le secret chiffré voyage ; son déchiffrement sur une **autre** instance (clé Passman différente ?) n'est pas testé — sans objet pour nous (on strip), à savoir si un client importe des archives non-sanitizées.

---

## Points ouverts — TOUS FERMÉS par la campagne du 2026-07-17

1. ✅ **Flag overwrite** : `overwrite=*` ou **types pluriels minuscules** (`apis,policies,policyactions,aliases,…`) ; casse/singulier **silencieusement ignorés** ; sans le flag, same-ID = `Failed "Asset already exists"` (jamais de doublon). Un asset en conflit **non couvert** est **skippé sans cascade** (bonne syntaxe) ; `apis` **sans** `policies` échoue **en cascade** (dépendances).
2. ✅ **Hot-swap 0-coupure à l'import** : prouvé ×3 sous charge (le 400 du `PUT` admin est un chemin distinct, abandonné).
3. ✅ **AS du scope-mapping** : référencé **par NOM** (`authServerAlias`) dans strategy et scope — l'AS est un **asset env-local posé alias-first** (même nom, valeurs locales) ; les scope-mappings **ne voyagent pas** dans l'archive (posés par REST `/scopes`, API référencée par GUID **stable**).
4. ✅ **Bootstrap** : alias manquant à l'import → l'import **réussit** mais l'invoke = **502 bruyant** (« Downtime exception ») — pas de mauvais backend silencieux ; la création de l'alias **après** ne suffit pas (binding nom→id au déploiement) → **re-import 0-coupure** re-binde. Ordre : **aliases (+AS) → import → scopes/apps** (une app souscrite **bloque** le delete d'API, mesuré).
5. ✅ **GUID sous Promotion API** : sans objet — A2/import retenu et suffisant.

---

## Conséquences

- **Positif.** Un **seul artefact à GUID stables** → graphe (scope-mappings/apps) **intact** en prod, **fin du « refaire le scope-mapping »**. **0-coupure** aligné sur l'exigence bancaire. **Sortie du dump-en-Git** (0 secret, revue propre). **Cible cloud sans gateway de promotion** = moins d'infra, **0 flux inter-env**, **pont supprimé**. Réutilise l'alias-management **déjà écrit côté Go**. Conduit **pluggable** → on **livre le hub VM maintenant**, on **migre au pull-agent cloud** sans refonte.
- **Négatif / coûts.** Changement de **verbe** (POST→import) dans l'adapter wM + **port de l'alias endpoint dans le rôle Ansible**. **Id-map à gérer** (capture initiale + discipline). L2 = **développement** (synthèse d'archive) non garanti → repli L1. Dépôt d'artefacts à opérer. Le hub B1 reste, en transition, un actif **sensible** (durcissement prod).
- **Réversibilité.** L1 est proche de l'existant (export/import) → **repli sûr** si L2 ne se prouve pas. Le conduit B1 (hub) reste valide tant que le cloud n'est pas là. Retirer `VAULT_ADDR` → fallback ADR-074. Le lab (mono-proxy `X-Environment`, ADR-075) reste intact pour les autres use cases.

## Alternatives écartées

- **Promotion Management API native (A3)** — reco éditeur, mais exige la **connectivité inter-stages** (KO segmentation) et une **gateway** pour la porter ; rend la gateway-source autoritaire (drift). Écartée avec justification.
- **Rebuild-by-POST (A1, base actuelle)** — GUID par gateway (graphe cassé) + MAJ = coupure. Abandonnée pour le chemin client.
- **Gateway dédiée à la promotion, en cible** — inutile (l'import tourne contre l'admin de la cible) et coûteuse sur cloud ; conservée **uniquement en transition** (B1).
- **Overlay qui patche l'archive par env (D1, type `aliases.json`)** — secret-in-artefact + fragilité ; alias posé hors archive préféré (D3).
- **Archive (zipée ou unzipée) comme source de vérité dans Git (C1/C2)** — dump machine, secret-in-repo, couplage version.
- **`deactivate→PUT→activate` pour la MAJ (ADR-078 §7)** — coupure ; remplacé par import overwrite / versioning.

## Décisions client — tranchées et restantes

**Tranchées :**
1. ✅ **Topologie = gateways séparées segmentées** (dev/rec/int/homol/prod, flux inter-env fermés).
2. ✅ **Transition = hub de promotion en prod** (flux vers tous les envs) — **conduit push**.
3. ✅ **Cible cloud = PAS de gateway de promotion** → **déployeur pull par env**.
4. ✅ **Jamais désactiver** une API — **sauf `dev` à l'onboarding**.

**À trancher :**
5. **L1 (golden archive) vs L2 (synthèse déterministe)** — dépend de la **faisabilité de synthèse** (assertion L2 du spike). Reco : démarrer **L1**, viser L2.
6. **Dépôt d'artefacts** (Nexus / Artifactory / OCI registry — lequel est déjà gouverné chez le client ?).
7. **Où vit l'id-map** (dans le repo de sources à côté des descripteurs — reco) et **comment il est capturé** (export golden initial).
8. **Forme du pull-agent cloud** (K8s Job/CronJob/opérateur si gateways en K8s ; runner CI dial-out sinon).

## Definition of Done de cet ADR

- [x] **Campagne de spikes** exécutée (2026-07-17), **preuve rejouable 22/22** (`scripts/test-archive-promotion.sh`) : graphe/GUID préservés + iso env vierge, 0-coupure ×3 sous charge, souscriptions intactes, round-trip alias per-env, secrets hors archive, L2 synthèse, pièges isActive/clobber/ACDL/binding. *(Résiduel : re-déroulé sur 2 instances physiques + E2E JWT bi-KC — § Résiduel.)*
- [x] **Verbe de déploiement** : rôle **`apim_promote_api`** (export sanitizé → import overwrite à GUID épinglé), prouvé E2E `failed=0` ; `deactivate→PUT→activate` **interdit hors authoring** (`UPDATE_FORBIDDEN` dans `apim_publish_api`).
- [x] **Alias per-env portés au rôle Ansible** : `tasks/alias.yml` — endpoint alias (PUT-converge, jamais delete/recreate) + credential alias (Vault, write-always), **alias-first** avant import.
- [x] **AS du scope-mapping** : tranché — référencé **par nom**, posé env-local (`inbound.yml` existant) ; scope-mappings **hors archive**, liés au GUID stable ; fail-closed `ENV_UNDEFINED` sur per_env.
- [x] **Source/artefact séparés** : manifeste `.promote.yml` (id-map `guid:` + valeurs d'alias per-env, 0 secret) dans Git ; archive = **artefact sanitizé** produit par le rôle (piège : **ne pas** le committer). *(Côté client : brancher le dépôt d'artefacts — décision 6.)*
- [ ] **Conduit** : la sémantique (rôle) est **conduit-agnostique** — reste à câbler l'exécution B1 (job hub VM) puis B2 (pull-agent par env) chez le client.
- [ ] **Gardes-fous** : 4-yeux/ITSM devant l'import (gate governance existante à asseoir sur `promote-api.yml`), audit checksum, creds cible least-privilege ← Vault.
- [x] **L1 livré** ; **L2 statué : faisabilité PROUVÉE** (générateur CI de synthèse = étape suivante).

## Références

- **Recherche 2026-07-17** (deep-research, 99 agents, 25 claims vérifiés 3-votes, 23 confirmés / 2 réfutés). Sources primaires : repo DevOps officiel `SoftwareAG/webmethods-api-gateway-devops` (→ `ibm-wm-transition`) — Promotion API primaire, alias stage-scoped substitués, flat-file en VCS ; IBM 10.15 *API Archive* — UUID unique across installations, overwrite same-ID en place ; IBM/webMethods 10.15 *Versioning* — nouvelle version inactive, Retain applications, version depuis la dernière ; IBM 10.15 *Upgrading Major Versions in Zero Downtime* — upgrade d'INSTANCE (≠ per-API). Source communautaire (`thesse1/webmethods-api-gateway-staging`) : archive binaire + overlay `aliases.json` (anti-pattern secret-en-clair noté).
- **Livrable (cette campagne)** : rôle `ansible/roles/apim_promote_api/` (defaults, resolve-env, secrets, export + `files/sanitize_archive.py`, alias, import, verify), playbooks `ansible/promote-api{,-verify}.yml`, manifeste `clients/_example/apis/accounts-read.promote.yml`, garde `UPDATE_FORBIDDEN` dans `apim_publish_api`, preuve `scripts/test-archive-promotion.sh` (22/22).
- **Reverse-engineering de la base** : `labctl/internal/adapter/webmethods/publish.go` (POST/PUT, `name+version`), `routing.go` (endpoint/credential alias REST séparés, re-point per-request), rôles Ansible `apim_publish_api`/`apim_selfservice_app`, `envs/{env}/targets.yaml` (`endpointAlias.url` per-env), `ci/Jenkinsfile.*`, `DELIVERY-PROCESS.md`.
- **Mémoire projet** : `wm-zero-downtime-deploy-constraint` (contrainte 0-coupure + topologie + hub + cible cloud), `wm-1015-rest-shapes`, `gitops-api-lifecycle-adr076`, `livrable-self-service-adr078`.
- ADR-075 (multi-env, mono-proxy `X-Environment` — simplification lab), ADR-076 (GitOps lifecycle, classification→policies, rebuild-from-Git **révisé ici**), ADR-078 §6-7 (per_env, lifecycle update **révisé ici**), ADR-074 (Vault), ADR-071 (onboarding-as-code).
