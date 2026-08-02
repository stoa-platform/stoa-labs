---
title: "GOAL — Self-service de création d'APIs (producteur) et d'applications consommatrices (consommateur) sur webMethods API Gateway 10.15, piloté 100 % par API REST, isolé par équipe"
type: goal
status: "Cadré — prêt à exécuter. Socle déjà prouvé en live (spike #1 Teams scoping + spike #2 proxy OAuth2). Reste à industrialiser."
date: 2026-07-09
feeds_adr: 78
lié: [adr-075-wm-admin-proxy-multienv, adr-076-gitops-api-lifecycle-repo-per-project, adr-077-user-identity-to-vault-token-exchange]
note: "Déploiement on-premise."
---

# GOAL — Self-service API & application, 100 % API REST, isolé par équipe (wM 10.15)

**Origine.** Besoin client : permettre à une équipe (« toto ») de **créer ses APIs** et à ses consommateurs de **créer/supprimer leurs applications consommatrices** en **self-service**, **consommable en OAuth2 via API** (pas seulement via une UI), avec **isolation stricte par équipe** (« je ne vois ni ne touche les APIs/apps d'une autre équipe »), le tout **simple à installer et à maintenir chez un client**.

**Ce GOAL ne modifie rien.** C'est le plan d'objectif. L'implémentation fera l'objet d'ADR-078 + scripts, une fois ce cadrage validé.

---

## Décision (test « archi 40 ans / 30 secondes »)

> Le self-service se fait **sans nouveau produit lourd** : on assemble trois briques déjà prouvées, toutes pilotables en REST.
> **(P) Producteur — création d'API : GitOps déclaratif** (spec OpenAPI versionnée par équipe → CI → `POST /apis` + `POST /assets/team`). L'isolation producteur est **native** (la feature Teams de wM 10.15 scope les APIs sur l'admin REST — *prouvé*). C'est **ADR-076 (repo-par-projet), déjà en place**.
> **(C) Consommateur — création d'application : proxy admin-API OAuth2 à identité technique sortante par équipe** (*prouvé spike #2*), **+ deux gardes applicatives** (`owner` + `register`) qui ferment la seule brèche native (Teams **ne cloisonne pas** les applications — *prouvé spike #1*).
> **(I) Credentials — provisioning déclaratif via Keycloak** (Client Registration Service + Initial Access Tokens scopés par équipe), lié « client OAuth ↔ équipe ↔ APIs autorisées » par le **scope/claim** du token.
> **Le Developer Portal natif 10.15 n'est PAS le point de départ** — il est *headless* (REST complet) mais lourd, couplé Gateway 10.5+, et sa surface REST par identité non-admin reproduit **exactement** la limite de Teams (scope APIs, pas applications). On y bascule **plus tard**, seulement si le catalogue et le nombre d'équipes le justifient (§ Bascule).

**Test :** *une équipe peut-elle publier une API et provisionner une application consommatrice de bout en bout par des appels REST, sans qu'un opérateur plateforme touche la gateway, et sans jamais voir ni modifier l'asset d'une autre équipe ?* Si oui pour les deux volets, le self-service est réel. Le socle prouvé répond déjà « oui » au volet producteur et « oui, moyennant les 2 gardes » au volet consommateur.

---

## Recommandation classée (issue de la recherche + des 2 spikes)

| Rang | Approche | Volet | Verdict | Pilotable REST | Isolation équipe | Coût mise en place / maintenance |
|---|---|---|---|---|---|---|
| **1** | **GitOps / API-as-code déclaratif** (ADR-076) | Producteur | ✅ Socle en place, isolation Teams native prouvée | Oui (Git → CI → admin REST) | **Native** (Teams sur `/apis`) | Faible — réutilise l'existant |
| **1** | **Proxy admin-API OAuth2 + gardes app** (ADR-078, spike #2) | Consommateur | ✅ Prouvé live, 2 variantes | Oui (OAuth2 en façade) | Par identité sortante + gardes | Faible-moyen — 4 objets natifs/équipe |
| **2** | **Provisioning Keycloak déclaratif** (Client Registration + IAT) | Credentials | ✅ Standard éditeur, stable | Oui (REST natif KC) | Par Initial Access Token scopé équipe | Faible — API standard |
| **3** | **Developer Portal natif 10.15** (headless) | Producteur + Consommateur | ⚠️ Possible mais lourd, isolation non complète en REST | Oui (headless) | **Incomplète** en REST par non-admin (Teams-as-primitive REFUTÉ) | Élevé — produit séparé, couplage 10.5+ |

**Meilleur compromis simplicité × industrialisation × API × isolation = rangs 1+1+2 (l'hybride GitOps producteur + proxy OAuth2 consommateur + Keycloak).** Le Portal (rang 3) est une évolution, pas un prérequis.

---

## Pourquoi pas le Developer Portal natif en premier (faits de la recherche)

- **Headless confirmé** : les API REST du DevPortal 10.15 couvrent toutes les fonctions de l'UI (Applications, Approvals, OAuth tokens, Requests, Plans…). *Donc techniquement pilotable.* ✔
- **MAIS** : la disponibilité des ressources REST **dépend du privilège de l'appelant** (surface admin/agrégée, pas par identité d'équipe non-admin) — même angle mort que Teams.
- **REFUTÉ (0-3)** : le DevPortal **n'expose pas** de ressource « Teams » comme primitive d'isolation par tenant.
- **REFUTÉ (1-2)** : le portail **ne permet pas** au consommateur de s'auto-servir de bout en bout (compte + souscription + gestion de clés) **sans étape opérateur/provider**.
- **Couplage** : publier depuis la Gateway exige API Gateway 10.5+ (ok en 10.15) mais ajoute un produit à opérer/patcher/sauvegarder.

Conclusion : le Portal **n'apporte pas l'isolation par équipe gratuitement** et coûte un produit de plus. Notre proxy la fournit déjà, prouvé, avec ~90 % de briques natives.

---

## Architecture cible (3 briques, tout en REST)

```
PRODUCTEUR (créer une API)                     CONSOMMATEUR (créer une application)
─────────────────────────────                  ─────────────────────────────────────
repo Git équipe toto                            Client OAuth2 (app de la team toto)
  openapi/*.yaml                                   │ Bearer, scope selfservice:toto
     │ push → PR (4-yeux, gate)                     ▼
     ▼                                           apim-selfservice (proxy OAuth2)  ← spike #2
  CI (ADR-076)                                     │ inbound  : Identify&Authorize OAuth2 (scope)
   POST /apis (multipart import)                   │ identité : svc-toto (alias statique OU mapper dynamique)
   POST /assets/team → team toto                   │ gardes   : owner (list/get/delete) + register (GET /apis oracle)
     ▼                                              ▼
  Teams scope /apis NATIVEMENT                   /rest/apigateway (self-referencing, 1 hop)
   → toto ne voit que titi/tata                    → svc-toto ∈ team toto → scoping natif prouvé
   → tutu (team B) refusée 401

CREDENTIALS (lier client ↔ équipe ↔ APIs)
──────────────────────────────────────────
Keycloak — Client Registration Service + Initial Access Token scopé équipe
   → client OAuth confidentiel, mapper claim team=toto + scope selfservice:toto
   → cap de clients par IAT, service account rôle create-client uniquement
```

**Le lien « client applicatif ↔ équipe » = le scope/claim du token** (jamais un paramètre client), dérivé côté serveur. C'est le mécanisme prouvé (spike #2) et l'ancrage de l'isolation.

---

## Jalons (E1…E6) — chacun avec sa porte de preuve X/X

### E1 — Producteur : self-service de création d'API par GitOps *(socle ADR-076, à recompléter)*
Une équipe pousse une spec OpenAPI dans son repo → CI importe (`POST /apis` multipart) et assigne la team (`POST /assets/team`, UUID) → l'API est visible **uniquement** de sa team.
**Preuve E1 — RÉÉCRITE le 2026-07-31 : l'énoncé précédent était FAUX.**
~~publication cross-team (assigner une team dont on n'est pas membre) **refusée
400** « User cannot assign the specified team to API »~~ — **ce refus n'existe
pas sur la gateway du cluster.** Mesuré : un membre d'équipe reçoit **401 sur la
ressource `assets`**, même pour **sa propre** équipe (assigner une team est une
opération d'**admin**) ; et à l'admin — l'identité que la chaîne porte — le
produit n'oppose **aucun** refus cross-team (déplacer une API vers l'équipe d'un
tiers : **200**, relu). Le refus fin du spike #1 (2026-07-09, lab Docker) tenait
à une configuration de privilèges, pas à une propriété de la 10.15 : l'écrire
comme porte, c'était s'appuyer sur un accident. **Le cloisonnement est donc une
propriété de la CHAÎNE, à construire et à prouver.**

**Découverte non prévue, du même relevé** : une équipe peut publier **hors
chaîne** (`POST /apis` multipart → **201**) et son API atterrit en `Default`,
**lue 200 par une équipe tierce**. Sur les applications, E3 parlait d'« un geste
qu'on peut oublier » ; sur les APIs, l'équipe **ne peut pas** faire le geste —
publier sans la chaîne, c'est nécessairement publier pour tout le monde.

**Portes de remplacement (spec `2026-07-31-e1-producteur-gitops-design.md`) —
les cinq VERTES le 2026-08-02** sur la gateway du cluster, depuis un pod agent
portant le SA `jenkins-agent` :

| Porte | Mesure |
|---|---|
| **P-1** publication cloisonnée | `TEAM_CONFIRMED` — teams relues `['Administrators','banking-demo']`, `Default` retirée ; témoin `svc-banking-demo` **200**, `svc-insurance-demo` **401** ; catalogues divergents |
| **P-2** refus cross-team | `TEAM_FORBIDDEN`, build rouge — **et le catalogue prouve que rien n'a été créé** |
| **P-3** le 200 ne prouve rien | `assetType` retiré → POST **200**, teams **inchangées**, `TEAM_UNCONFIRMED`. La relecture est la porte, pas le code HTTP |
| **P-4** fail-closed sans équipe | `TEAM_UNDEFINED` plutôt qu'une API en `Default` |
| **P-5** injection par le manifeste | `MANIFEST_KEYS_FORBIDDEN` — `include_vars` charge le top-level à la précédence 18 : sans liste blanche, le manifeste de l'équipe détourne la base d'admin |
| contre-épreuve `verify` | on lui ment sur la team → `PUBLISH_UNCONFIRMED`. Un verify qui ne rougit jamais ne prouve rien |

P-4 et P-5 ont été joués avec la base d'admin sur un **port mort** : aucune
socket n'est ouverte, donc les gardes précèdent le réseau — un refus ne laisse
rien derrière lui.

**État :** le moteur (`apim_publish_api`) est à parité du chemin consommateur.
**Reste ouvert — et c'est ce qui fait l'autorité, pas la garde** : sur le chemin
**GitOps du cluster**, le `Jenkinsfile` vit dans le dépôt de l'équipe (job F4 =
`CpsScmFlowDefinition`), donc l'équipe écrit elle-même son `TEAM` et le
`serviceAccount` de son podTemplate. Les gardes sont réelles, leur **autorité**
ne l'est pas encore : il faut reposer le job en `CpsFlowDefinition` possédé par
la plateforme (geste exploitant). Sur le chemin **fidèle-client**
(`ci/Jenkinsfile.publish-api`), l'autorité est acquise — la team est dérivée du
chemin KV tenant-scopé, borné par la policy Vault du token nominatif.

### E2 — Consommateur : proxy self-service OAuth2 *(ADR-078, spike #2 prouvé)*
Exposer `/rest/apigateway` derrière un proxy OAuth2 avec identité technique sortante par équipe. Choisir la variante selon § Bascule.
**Preuve E2 :** matrice runtime — sans token → 401 ; token `toto` → liste scopée toto (tutu absent, par ID) ; token `teamb` → refus/scope teamb ; token forgé → 401 ; anti-spoof (`X-Team`/2ᵉ header Authorization) → team dérivée du token, pas du client.
**État :** **prouvé live** (N-proxies **et** mono-proxy), 3/3 sceptiques. Pièges consignés : alias `${nom}` obligatoire, `aud` JWT en **tableau**, callout en stage **transport**.

### E3 — Fermer la brèche : gardes applicatives *(le seul vrai reste-à-faire fonctionnel)*
Teams ne cloisonne **pas** les applications (spike #1 : delete cross-team 204, register d'une API invisible 201). Un unique service IS générique (préprocessing, pattern token-provider du PoC) garde 3 routes :
1. `DELETE`/`GET /applications/{id}` → exiger `owner == svc-<team>` (sinon 403).
2. `GET /applications` → filtrer la réponse sur `owner == svc-<team>`.
3. `POST /applications/{id}/apis` → `GET /apis/{apiId}` avec les creds de la team comme **oracle** (401 natif → refus 403).
**Preuve E3 :** `teamb` ne voit ni ne supprime l'app de `toto` ; register d'une API invisible refusé ; cycle create→register(tata)→delete par le propriétaire OK.

**Geste 1 — FERMÉ le 2026-07-31 : l'assignation de team est posée par la chaîne de création.**
`roles/apim_selfservice_app/tasks/team.yml` assigne l'application (`POST /assets/team`,
`assetType:"Application"`, `newTeams` = UUID d'accessProfile) **immédiatement après sa
création**, avant toute autre écriture, puis **relit** — `TEAM_CONFIRMED` exige la team
demandée présente **et** `Default` partie. Fail-closed par défaut (`apim_ss_require_team`) :
sans équipe résolue, le rôle refuse de déployer. L'équipe vient de `-e apim_ss_team`, que le
pipeline **dérive du chemin KV du compte de service** (`deploy/<tenant>/wm-admin`) — donc du
seul périmètre où le token nominatif a le droit d'écrire (policy Vault tenant-scopée) ; elle
l'emporte sur le `team:` du manifeste, que l'appelant écrit lui-même. `verify` porte la même
exigence, en lecture seule et rejouable.

Preuves live (gateway du cluster, relectures via le Service d'administration) :

| Ce qui est prouvé | Observé |
|---|---|
| assignation par la chaîne | `TEAM_CONFIRMED : teams=['Administrators','banking-demo']`, `Default` retirée ; re-run = no-op |
| **la relecture n'est pas décorative** | même POST **sans** `assetType` : **HTTP 200**, corps `{}`, teams **inchangées** (`['Administrators','Default']`) ; **avec** `assetType` : 200, message explicite, teams à jour |
| refus sans équipe | `TEAM_UNDEFINED` — build rouge |
| refus sur équipe inconnue de la gateway | `TEAM_UNKNOWN` |
| opt-out assumé et bruyant (lab sans Teams) | `TEAM_SKIPPED` |
| le garde attrape la brèche réelle | `verify` sur `demo-consumer-accounts-read` **avant** correction : `TEAM_UNCONFIRMED : teams=['Administrators','Default']` |

Contexte au moment de la mesure : les **7** applications de la gateway du cluster étaient en
team `Default`, **y compris celles posées par le lot B**. La brèche du spike #1 n'était pas
théorique — c'était l'état courant de la plateforme. Les deux applications de la chaîne sont
désormais cloisonnées ; celles des spikes antérieurs restent en `Default` (hors chaîne).

**Geste 2 — la garde du register : FERMÉE SUR LE CHEMIN GITOPS le 2026-07-31, résidu isolé.**

L'oracle prévu par le design — appeler `GET /apis/{id}` **avec les creds de l'équipe**, 401 natif
⇒ refus — **n'est pas disponible à la chaîne**, et c'est une découverte, pas un contournement :
un utilisateur d'ÉQUIPE se voit **refuser `POST /assets/team`** — *« The user: … is not authorized
to perform: POST on the resource: assets »*, **HTTP 401**. Assigner une team est une opération
d'**admin**. La chaîne tourne donc nécessairement sous une identité admin (compte de service
tenant-scopé côté Vault), et pour cette identité `GET /apis` **n'est pas scopé** : sa propre
visibilité ne dit rien de celle de l'équipe. Les deux gestes de E3 tirent sur la même corde —
celui qui peut cloisonner est précisément celui pour qui l'oracle est aveugle.

**Oracle retenu** : l'admin lit l'assignation de l'API elle-même — `GET /apis/{id}` →
`apiResponse.teams[]` (**niveau `apiResponse`** ; `api.teams` est vide — piège déjà relevé en F4).
Règle : l'équipe demandeuse doit y figurer, **ou** l'API doit être en `Default` (fourre-tout
visible de toutes). L'équivalence avec la visibilité réelle est **mesurée** : sous une identité
jetable de `insurance-demo`, `GET /apis` rendait exactement les APIs en `Default`
(`accounts-read-ans`, `carto-probe-api`) et pas `accounts-read` (team `banking-demo`).

| Cas (identité admin, comme la chaîne réelle) | Observé |
|---|---|
| `insurance-demo` → `accounts-read` (team `banking-demo`) | **`API_NOT_VISIBLE_TO_TEAM`**, build rouge, **et rien n'est créé** (garde en §1b, avant l'application) |
| `insurance-demo` → `accounts-read-ans` (team `Default`) | `REGISTER_ALLOWED` |
| `banking-demo` → `accounts-read` | `REGISTER_ALLOWED` |
| brèche re-mesurée sous identité d'équipe | `GET /apis/{accounts-read}` **401**, `PUT /applications/{app}/apis` **200**, `consumingAPIs` relus côté admin = l'API |

Même garde, même fichier, rejouée par `verify` — sinon l'accord des deux ne prouverait rien.

⚠ **RÉSIDU — le chemin DIRECT reste ouvert.** Cette garde ferme le chemin **GitOps**, celui par
lequel une application est réellement livrée chez le client (les équipes produit n'ont aucun accès
direct à la gateway, ADR-076/078). Elle ne ferme **pas** le chemin d'une équipe qui atteindrait
`/rest/apigateway` par le proxy OAuth2 (E2) et poserait l'association elle-même. C'est là, et **là
seulement**, que le service IS de préprocessing du design reste nécessaire — il ne s'écrit pas en
Ansible et n'a pas pu être déployé ni prouvé ici (déploiement IS = résidu manuel, cf. TokenProvider).

**État — le résiduel est TRANCHÉ (2026-07-31, mesuré sur la gateway du cluster).** Question posée : *une app **explicitement** assignée à une team via `/assets/team` devient-elle protégée nativement ?* **Oui pour les gardes 1 et 2, non pour la garde 3.** Le jalon se réduit donc à **une seule garde**, celle du register.

| Garde | Verdict mesuré |
|---|---|
| 1. `GET`/`DELETE /applications/{id}` cross-team | **TOMBE** — protection native |
| 2. filtre de `GET /applications` | **TOMBE** — protection native |
| 3. `POST/PUT /applications/{id}/apis` avec une API invisible | **RESTE ENTIÈRE** — brèche confirmée |

Protocole : app créée par `svc-banking-demo`, **ligne de base relevée avant assignation** (sans quoi un « non protégé » ne prouverait rien), assignation `POST /assets/team {assetType:"Application"}` **relue** (garde contre le 200 no-op silencieux), puis les gestes cross-team.

- **Avant** assignation (`teams: [Administrators(SYSTEM), Default(SYSTEM)]`) : `svc-insurance-demo` → `GET /applications/{id}` **200 ×5**, app **présente** dans sa liste (5 apps).
- **Après** assignation (relecture : `teams: [Administrators(SYSTEM), banking-demo(USER)]` — `Default` retiré, comme pour les APIs) : `svc-insurance-demo` → `GET /applications/{id}` **401 ×5**, app **absente** de la liste (4 apps), `DELETE` **401** et **l'app survit** (relue 200 par `Administrator`). Le propriétaire garde son accès (**200 ×3**) et le témoin `Administrator` reste vert (**200 ×3**) au même instant.
- **Garde 3, brèche confirmée par relecture bilatérale** : `svc-insurance-demo` ne peut pas lire `accounts-read` (`GET /apis/{id}` → **401**) mais `PUT /applications/{son app}/apis {"apiIDs":["<accounts-read>"]}` → **200**, et l'association est **réelle** : `consumingAPIs = ['f12b0b1f…']` sur l'app, et `GET /apis/{accounts-read}/applications` liste l'app d'insurance. Le refus de lecture n'est **pas** opposé à l'écriture d'association — l'oracle du design (401 natif ⇒ refus) reste donc nécessaire.

**Deux corrections de forme, apprises en se cognant :**
- Le refus natif est **401**, pas 403. Une garde qui rendrait 403 serait *plus* explicite que le produit, pas moins.
- Le corps de l'association est **`{"apiIDs":[…]}`** (comme le rôle `apim_selfservice_app`), **pas** un tableau nu : un tableau nu rend **500 `errorDetails:null`**. Un premier passage l'a pris pour un refus — c'était ma requête. C'est le **témoin** (même appel avec une API *visible*) qui l'a démasqué : sans lui, un échec ne distingue pas « refusé car invisible » de « mal formé ».

⚠️ **Mesure invalidée si elle passe par le Service `wm-apigateway`.** Il répartit sur **deux** déploiements (`rotation=a`/`b`) qui **ne sont pas en cluster** : ils partagent Elasticsearch sans synchroniser leur cache mémoire. Un objet écrit sur une réplique est donc **absent de l'autre** le temps que la convergence ait lieu, et la réplique qui l'ignore répond **`401 « User doesn't have permission »`** — un message qui parle d'autorisation alors qu'il s'agit d'un cache froid. Les trois premières passes de ce test en ont été polluées, y compris sur `Administrator`. Un 401 lu à travers ce Service ne distingue donc pas « refusé par le cloisonnement » de « réplique qui ne sait pas encore ».

La mesure ci-dessus est **épinglée sur l'IP d'un pod unique**, encadrée d'un témoin de stabilité (8 GET verts avant, 3 pendant) — même parade que celle retenue depuis par le **Service `wm-apigateway-admin`** (sélecteur `rotation=a`, additif, `deploy/bootstrap/wm/apigateway-admin/service.yaml`), qui donne aux pipelines une réplique unique pour relire ce qu'ils écrivent. **Toute vérification d'autorisation ou toute relecture après écriture doit passer par ce Service-là**, jamais par `wm-apigateway`, qui reste volontairement réparti pour la disponibilité du trafic public.

*Correction d'une explication que j'avais donnée trop vite : j'avais imputé ces 401 à des points d'accès **non prêts** dans l'EndpointSlice. Il y en avait bien, mais ils n'expliquent pas un 401 servi par une réplique **prête** — la cause est le cache non synchronisé, mesurée indépendamment le 2026-07-30 (commit `8a7b5cf`). Conséquence pratique : sonder un endpoint **authentifié** ne suffirait pas, puisqu'une réplique peut authentifier correctement et ignorer encore l'objet.*

### E4 — Credentials déclaratifs via Keycloak *(standard éditeur)*
Provisionner clients/credentials OAuth2 par API : Client Registration Service (provider par défaut) + **Initial Access Token** scopé équipe (délégation sans creds admin), service account limité au rôle `create-client`, mapper claim `team` + scope `selfservice:<team>`.
**Preuve E4 :** un IAT d'équipe crée un client confidentiel dont le token porte `team`/`scope` attendus ; cap de clients respecté ; aucun droit admin KC utilisé.
**État :** mécanique KC prouvée dans le PoC (spike #2 a créé clients+scopes+mappers en REST). *Éviter* l'API expérimentale « Client Admin API v2 / Operator CRD » (non prod) — rester sur provider par défaut + IAT (cap-race corrigé KC 26.0.0).

### E5 — Industrialisation : « ajouter une équipe en N appels »
Un rôle Ansible / script idempotent (famille `setup-wm-admin-proxy.sh`) qui, pour une équipe, pose : user technique + groupe + accessProfile (privilège « Manage applications ») + scope KC + (manifest de proxy **ou** entrée de mapping), en **read-back-assert**.
**Preuve E5 :** ajout d'une équipe en **1 commande**, relançable (converge), read-back de chaque objet ; suppression symétrique propre.
**État :** à écrire ; toutes les recettes REST unitaires sont prouvées et consignées ([[wm-1015-rest-shapes]]).

### E6 — Durcissement bancaire on-premise
- **SPOF mapper** (variante dynamique) : HA + creds depuis Vault (ADR-074), et transformer le fail-closed 500 en 502/503 propre pour le monitoring.
- **Drift out-of-band** : Git ne détecte pas une modif manuelle sur la gateway → job de réconciliation (extractor `gateway → Git`, alerte sur écart).
- **Auditabilité** : commits signés, branch protection, historique immuable (au-delà de la trace Git native, exigée en banque).
- **Break-glass** : procédure de changement d'urgence traçée.
**Preuve E6 :** mapper survit à la perte d'une instance ; un changement manuel injecté sur la gateway est **détecté** ; un déploiement non tracé Git est **refusé/alerté**.
**État :** à cadrer ; s'appuie sur ADR-074 (Vault) et le pattern extractor GitOps de la recherche.

---

## Industrialisation — coût d'ajout d'une équipe

| Objet | Où | Appels |
|---|---|---|
| user technique `svc-<team>` | Gateway REST | `POST /users` |
| groupe `<team>-devs` | Gateway REST | `POST /groups` |
| accessProfile (team) | Gateway REST | `POST /accessProfiles` (privilège `Manage applications`) |
| scope OAuth `selfservice:<team>` + mapper claim | Keycloak REST | `POST /client-scopes` (+ mapper) |
| variante N-proxies : proxy + alias | Gateway REST | `POST /apis` + `POST /alias` + policies |
| variante mono-proxy : entrée de mapping | mapper (config) | 1 ligne |

→ **variante mono-proxy = 4 objets + 1 ligne de mapping / équipe** ; **variante N-proxies = ~6 objets / équipe** mais politiques par équipe triviales. Tout scriptable (E5).

---

## Modèle opérationnel (fédéré — standard industrie confirmé)

- **Équipe plateforme** (centrale) : possède la gouvernance, le monitoring, les gardes (E3), le rôle d'ajout d'équipe (E5), le durcissement (E6). Détient l'accès en écriture à la gateway — **révoqué pour les équipes produit**.
- **Équipes produit** (décentralisées) : self-service via Git (producteur, E1) et OAuth2 (consommateur, E2) ; **aucun accès direct** à la gateway. Publication via PR (4-yeux, gate ITSM — ADR-075/076).

C'est le modèle « federated API management » documenté (Azure APIM workspaces comme référence de *pattern* ; la techno workspace n'existe pas en wM 10.15 — d'où notre implémentation admin-REST + proxy + CI).

---

## Critères de bascule

**Variante N-proxies (statique) → mono-proxy (dynamique)** quand : beaucoup d'équipes (> ~15-20) **ou** création d'équipes fréquente **ou** on veut une seule API à exploiter. Sinon N-proxies (zéro code custom dans le chemin d'identité, politiques par équipe triviales).

**Proxy OAuth2 → Developer Portal natif** quand : besoin d'un **catalogue produit riche** (documentation, essais, plans, marketplace) **et** volume d'équipes justifiant d'opérer un produit séparé **et** budget de patch/sauvegarde/couplage 10.5+ accepté. Tant que le besoin est « create/list/delete API + application par équipe en REST », le proxy est plus simple et suffit.

---

## Risques & limites 10.15 (assumés)

- **Hygiène team Default** : à l'activation de Teams, tout l'existant tombe en team `Default` (visible de tous). Prévoir un one-shot d'assignation (E5) ; `/assets/team` retire Default (prouvé).
- **Applications non cloisonnées nativement** — **requalifié le 2026-07-31, puis TRAITÉ le même jour côté chaîne** (`apim_selfservice_app/tasks/team.yml` : assignation + relecture fail-closed, `verify` aligné) : elles le sont *dès lors qu'elles sont assignées à une team*. La faille n'est donc pas l'absence de cloisonnement mais son **caractère facultatif** : une app laissée en `Default` reste visible et supprimable par tous. La protection dépend d'un geste qu'on peut oublier ⇒ l'assignation doit être posée **par la chaîne de création**, pas laissée à l'appelant. Reste à couvrir par E3 : la **garde 3** (register d'une API invisible), non fermée par l'assignation.
- **Deux répliques wM sans cluster ⇒ des 401 qui ne parlent pas d'autorisation** (hors E). Les instances `rotation=a`/`b` partagent Elasticsearch sans synchroniser leur cache mémoire : après une écriture, la relecture tombe une fois sur deux sur l'instance qui ne sait pas encore, et celle-ci répond `401 « User doesn't have permission »`. **Le message désigne la mauvaise cause** — c'est le piège à retenir, pas le comportement. **Déjà traité côté chemin d'écriture** par le Service `wm-apigateway-admin` (réplique unique, commit `8a7b5cf`) ; ce qui reste ouvert est la **convergence elle-même**, qui appartient au spike des répliques décalées (clustering Terracotta/Ignite). Tant qu'elle n'est pas acquise, la règle tient : les pipelines et les tests d'autorisation visent le Service d'administration, le trafic public garde le Service réparti.
- **Fail-open de la *valeur* d'`aud`** sur le trial (introspection remote inerte — finding ADR-075) ; un build client non-trial enforce l'aud sans changement de config. La *forme* (aud tableau) reste obligatoire.
- **SPOF mapper** (variante dynamique) → E6 (HA + Vault).
- **Fragilité trial** : crashs IS spontanés observés (restart auto Docker) — ne pas extrapoler au build client, mais le noter pour la démo.
- **Asymétrie des sources** (recherche) : les patterns fédéré/API-as-a-Product/APIOps sont surtout documentés sur Azure APIM ; le *pattern* transfère, l'*outillage* est à réimplémenter sur l'admin REST wM (ce que fait ce GOAL).

---

## Ce qui est déjà prouvé vs à faire

| | Prouvé live | À faire |
|---|---|---|
| Producteur (E1) | Isolation Teams native sur `/apis` (spike #1, 3/3) ; **les 5 portes vertes le 2026-08-02** — cloisonnement, refus cross-team sans rien créer, sabotage de l'`assetType` attrapé par la relecture, fail-closed sans équipe, injection par le manifeste refusée | Reposer le job GitOps du cluster en `CpsFlowDefinition` **possédé par la plateforme** — tant que le `Jenkinsfile` vit chez l'équipe, c'est elle qui écrit son `TEAM` (geste exploitant) |
| Consommateur (E2) | Proxy OAuth2, 2 variantes, anti-spoof (spike #2, 3/3) | Choisir la variante, généraliser |
| Gardes app (E3) | Gardes 1+2 assurées nativement dès l'assignation, **désormais POSÉE ET RELUE par la chaîne (geste 1)** ; garde 3 **fermée sur le chemin GitOps** par l'oracle `apiResponse.teams[]` (geste 2) — les deux prouvés live le 2026-07-31 | Service IS de préprocessing pour le **seul chemin direct** (équipe atteignant l'admin REST par le proxy E2) |
| Credentials (E4) | Clients/scopes/mappers KC en REST (spike #2) | Passer aux Initial Access Tokens scopés équipe |
| Industrialisation (E5) | Toutes les recettes REST unitaires | Rôle Ansible / script idempotent |
| Durcissement (E6) | — | HA mapper, drift detection, audit signé, break-glass |

**Chemin critique = E3 (gardes applications)** — c'était le seul manque *fonctionnel* ; E1/E2/E4 reposent sur du déjà-prouvé, E5/E6 sont de l'industrialisation. **Réduit des deux tiers le 2026-07-31** (gardes 1 et 2 assurées nativement dès l'assignation), **puis fermé sur le chemin GitOps le même jour** : l'assignation est posée et relue par la chaîne de création (geste 1), et la garde du register s'appuie sur l'assignation de l'API lue par l'admin (geste 2). **Ce qui reste n'est plus le chemin de livraison** : le service IS ne sert qu'au chemin *direct* (une équipe atteignant l'admin REST par le proxy E2), qui n'existe pas encore.

---

## Prochaine action proposée (hors de ce GOAL)

Sur validation : rédiger **ADR-078** (décision + JSON de policies exacts des deux variantes, tous capturés dans les évidences des spikes) et implémenter **E3** (le service IS de gardes) + ~~le test résiduel `/assets/team` sur application~~ **— résiduel exécuté le 2026-07-31, voir E3 ci-dessus.** E3 se re-cadre en deux gestes : (1) poser l'assignation de team **dans la chaîne de création** d'application (sinon la protection native reste facultative), (2) n'écrire de garde IS que pour le **register**. Le reste (E1/E4/E5) est de l'assemblage de briques prouvées.

*Sources recherche : IBM/webMethods DevPortal 10.15 (headless REST), Keycloak Client Registration Service, Azure APIM APIOps & workspaces (pattern de référence), InfoQ/Tyk/Kong (modèle fédéré). Socle empirique : spikes live 2026-07-09 (Teams scoping + proxy OAuth2), voir [[wm-1015-teams-scoping]] et [[wm-1015-rest-shapes]].*
