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
**Preuve E1 :** membre `toto` publie `titi` → visible de `toto`, **absente** pour `teamb` (GET /apis scopé) ; publication cross-team (assigner une team dont on n'est pas membre) **refusée 400** « User cannot assign the specified team to API ».
**État :** isolation native **déjà prouvée** (spike #1, 3/3 sceptiques) ; reste à câbler le pas « repo → CI → import+assign » sur le template ADR-076.

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

⚠️ **Mesure invalidée si elle passe par le Service.** `wm-apigateway` porte désormais **deux** déploiements (`rotation=a`/`b`, redémarrages décalés) et son EndpointSlice expose des adresses **non prêtes** : les appels y sont répartis et rendent des **401 intermittents, y compris sur `Administrator`**. Un 401 lu à travers le Service ne distingue pas « refusé par le cloisonnement » de « réplique en cours de démarrage » — les trois premières passes en ont été polluées. La mesure ci-dessus est **épinglée sur l'IP d'un pod prêt**, encadrée d'un témoin de stabilité (8 GET verts avant, 3 pendant). *Voir la dette d'exploitation ouverte par ce constat, ci-dessous.*

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
- **Applications non cloisonnées nativement** — **requalifié le 2026-07-31** : elles le sont *dès lors qu'elles sont assignées à une team*. La faille n'est donc pas l'absence de cloisonnement mais son **caractère facultatif** : une app laissée en `Default` reste visible et supprimable par tous. La protection dépend d'un geste qu'on peut oublier ⇒ l'assignation doit être posée **par la chaîne de création**, pas laissée à l'appelant. Reste à couvrir par E3 : la **garde 3** (register d'une API invisible), non fermée par l'assignation.
- **Nouvelle dette d'exploitation (hors E, relevée le 2026-07-31)** : le Service `wm-apigateway` route vers des répliques **non prêtes** — la sonde de disponibilité passe au vert **avant** que webMethods sache authentifier, donc l'admin REST rend des **401 intermittents** sous une identité valide. Même classe de défaut que le constat F5 (« `/health` remonte ~85 s avant que l'API soit invocable ») : la sonde ment sur ce qu'elle atteste. Conséquence directe : **toute mesure d'autorisation passant par le Service est ininterprétable**. À corriger par une sonde de disponibilité qui interroge un endpoint **authentifié**.
- **Fail-open de la *valeur* d'`aud`** sur le trial (introspection remote inerte — finding ADR-075) ; un build client non-trial enforce l'aud sans changement de config. La *forme* (aud tableau) reste obligatoire.
- **SPOF mapper** (variante dynamique) → E6 (HA + Vault).
- **Fragilité trial** : crashs IS spontanés observés (restart auto Docker) — ne pas extrapoler au build client, mais le noter pour la démo.
- **Asymétrie des sources** (recherche) : les patterns fédéré/API-as-a-Product/APIOps sont surtout documentés sur Azure APIM ; le *pattern* transfère, l'*outillage* est à réimplémenter sur l'admin REST wM (ce que fait ce GOAL).

---

## Ce qui est déjà prouvé vs à faire

| | Prouvé live | À faire |
|---|---|---|
| Producteur (E1) | Isolation Teams native sur `/apis` (spike #1, 3/3) | Câbler repo→CI→import+assign sur template ADR-076 |
| Consommateur (E2) | Proxy OAuth2, 2 variantes, anti-spoof (spike #2, 3/3) | Choisir la variante, généraliser |
| Gardes app (E3) | Oracle = refus natif prouvé ; **gardes 1+2 rendues inutiles par l'assignation de team (mesuré 2026-07-31)** | Écrire le service IS pour la **seule garde 3** (register) ; **et rendre l'assignation systématique** — c'est elle qui protège |
| Credentials (E4) | Clients/scopes/mappers KC en REST (spike #2) | Passer aux Initial Access Tokens scopés équipe |
| Industrialisation (E5) | Toutes les recettes REST unitaires | Rôle Ansible / script idempotent |
| Durcissement (E6) | — | HA mapper, drift detection, audit signé, break-glass |

**Chemin critique = E3 (gardes applications)** — c'est le seul manque *fonctionnel* ; E1/E2/E4 reposent sur du déjà-prouvé, E5/E6 sont de l'industrialisation. **Réduit des deux tiers le 2026-07-31** : il ne reste que la garde 3 (register), les gardes 1 et 2 étant assurées nativement par l'assignation de team. Le coût bascule du *service IS* vers l'**automatisation de l'assignation** — c'est elle qui protège, et rien ne l'impose aujourd'hui.

---

## Prochaine action proposée (hors de ce GOAL)

Sur validation : rédiger **ADR-078** (décision + JSON de policies exacts des deux variantes, tous capturés dans les évidences des spikes) et implémenter **E3** (le service IS de gardes) + ~~le test résiduel `/assets/team` sur application~~ **— résiduel exécuté le 2026-07-31, voir E3 ci-dessus.** E3 se re-cadre en deux gestes : (1) poser l'assignation de team **dans la chaîne de création** d'application (sinon la protection native reste facultative), (2) n'écrire de garde IS que pour le **register**. Le reste (E1/E4/E5) est de l'assemblage de briques prouvées.

*Sources recherche : IBM/webMethods DevPortal 10.15 (headless REST), Keycloak Client Registration Service, Azure APIM APIOps & workspaces (pattern de référence), InfoQ/Tyk/Kong (modèle fédéré). Socle empirique : spikes live 2026-07-09 (Teams scoping + proxy OAuth2), voir [[wm-1015-teams-scoping]] et [[wm-1015-rest-shapes]].*
