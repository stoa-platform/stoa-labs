# Initialisation des dépôts fournisseurs depuis un parc existant — design

**Date** : 2026-09-07
**État** : design validé section par section, spec à relire avant plan d'implémentation
**Chantier** : A (le script). Le chantier B est nommé §13, il n'est pas dans ce périmètre.

---

## 1. Le problème

Un client (banque) exploite un parc webMethods API Gateway 10.15 **créé à la main** : des
équipes, des APIs, des applications, aucune trace en Git. Il veut passer à la chaîne
GitOps du PoC (ADR-075/076/079), qui suppose un **dépôt fournisseur par équipe** portant
`apis/<nom>.publish.yml` + `apis/<nom>.openapi.yaml`.

Aujourd'hui, ce passage est entièrement manuel : relever chaque nom et chaque version sur
la gateway, écrire un manifeste par API, créer un dépôt par équipe, ouvrir une PR. Sur un
parc réel, c'est infaisable sans erreur — et une erreur produit un dépôt que la chaîne
refusera plus tard, plus loin, avec un message moins clair.

Ce document conçoit l'outil qui fait ce passage.

## 2. Les décisions, et qui les a prises

Toutes prises par le porteur du chantier au cours du brainstorming du 2026-09-07 :

| # | Décision | Alternative écartée |
|---|---|---|
| D1 | La source du scan est **la gateway par REST** | un arbre de fichiers, un inventaire à la main |
| D2 | Le groupement se fait par **`teams[]` déjà présentes** sur la gateway | table de correspondance, convention de nommage |
| D3 | La sortie est **une PR par fournisseur**, plus une PR plateforme | arbre local seul, push direct sur `main` |
| D4 | Les manifestes sont **complets**, pas un simple catalogue | catalogue `name`+`version`, TODO de contrat |
| D5 | Les manifestes d'application vont **dans le dépôt fournisseur** | dans le dépôt plateforme (l'architecture actuelle) |
| D6 | **A d'abord, B ensuite**, avec avertissement daté | B d'abord, écriture aux deux endroits, un seul chantier |
| D7 | Découpe en **trois étages** `scan` / `render` / `publish` | une passe, ou `--plan`/`--apply` |
| D8 | Le contrat vient d'**`apiDefinition`**, `/archive` est **sondé** sans dépendance | archive seule, archive puis repli |
| D9 | **`estate.<env>.json`**, un par palier, **jamais committé par l'outil** | un fichier unique, un artefact versionné |
| D10 | `publish` **ne crée pas les dépôts** — il les exige existants et vides | adaptateur de forge, s'arrêter à la branche, Gitea seul |

## 3. Non-objectifs

Ce chantier **ne fait pas** :

- **Écrire sur la gateway.** Aucun étage n'assigne une équipe, n'active une API, ne
  publie. Les gestes correctifs sont *proposés* dans un rapport.
- **Créer des dépôts sur la forge** (D10). Le client les crée, vides.
- **Étendre la chaîne pour lire `applications/` dans un dépôt fournisseur** — chantier B.
- **Fabriquer une identité de lecture seule** sur la gateway — livrable séparé, §13.
- **Importer un contrat OpenAPI depuis une archive.** `apiDefinition` est la source (D8).
- **Déclarer une posture.** La classification est centrale et owner-keyée ; l'outil la
  reprend quand elle existe et la *propose* sinon.

## 4. Architecture

```
scan     gateway REST ──▶ estate.<env>.json + contrats/   LECTURE SEULE, seul étage réseau gateway
render   estate.<env>.json ──▶ arbre local                PUR : ni réseau, ni secret, ni forge
publish  arbre local ──▶ branches + PRs                   seul étage qui écrit, forge seulement
```

Trois exécutables distincts, plus un `init-depots-fournisseurs.sh` qui enchaîne les trois
pour l'usage courant. La découpe sert trois fins :

1. `render` est une fonction pure, donc **prouvable hors ligne** par les suites existantes.
   C'est l'étage qui porte les contrats de sortie opposables (§7) — les prouver ne doit pas
   exiger une gateway.
2. `estate.<env>.json` est un **artefact relisible et rejouable**. L'inventaire d'un parc
   est en soi un livrable client.
3. Le seul étage qui écrit est isolé, donc **rejouable seul** quand une PR échoue au
   vingt-deuxième dépôt.

## 5. Étage `scan`

### 5.1 La base d'admin est proxifiée

Chez le client, l'API d'admin **n'est pas exposée en direct** : elle est proxifiée **sur la
gateway elle-même** (`gateways/webmethods/admin-proxy/targets.wm-admin-self.yaml:4-5`).
La base se compose :

```
<APIM_PROXY_HOST>/gateway/<APIM_PROXY_API>/<APIM_PROXY_VER><APIM_PROXY_PATH>
```

La fonction de composition **existe déjà en bash** — `scripts/selfservice-palier-gate.sh:104-125`
— avec la substitution `__ENV__`, l'ordre de priorité (position dans la chaîne > `ADMIN_VIA` >
`APIM_PROXY_BASE` > les quatre morceaux) et ses refus nommés.

**Préalable au chantier** (§10) : elle est inextractible en l'état (script monolithique,
`refus()` fait `exit 1`, `trap … EXIT`). Elle doit être extraite dans
`scripts/lib/apim-base.sh`, sourcée par la garde **et** par `scan`. Le dépôt a ce réflexe :
`scripts/lib/vault-kv.sh` a été créé pour la même raison.

Trois règles héritées, non réécrites :

- `ADMIN_VIA` vide ⇒ `VIA_INCONNU`. Un repli silencieux vers `direct/basic` a déjà été un
  bug réel (`selfservice-palier-gate.sh:62-66`).
- Le mode d'auth est **dérivé** de la voie : `direct → basic`, `proxy → oauth2`.
- **Aucun défaut de site** dans le code livrable (`ci/lint-config-knobs.sh`, porte
  `make lint-ci`). `scan` exige ses knobs, il n'invente pas d'URL de lab.

### 5.2 Les endpoints

Le contrat du proxy est une **allowlist** : hors contrat, le wM réel rend 404. Les sept
endpoints du scan sont **tous déclarés** dans `gateways/webmethods/admin-proxy/wm-admin-proxy.openapi.yaml` :

| endpoint | ligne | usage |
|---|---|---|
| `GET /health` | 34-38 | **non requis** — cf. §5.5 : chez ce client il n'est pas joignable depuis l'externe |
| `GET /apis` | 39-43 | GUID, nom, version, `isActive`, **et `teams[]`** |
| `GET /apis/{id}` | 49-54 | `apiResponse.api.apiDefinition` — le contrat |
| `GET /applications` | 180-184 | liste |
| `GET /applications/{id}` | 190-195 | owner/ownerType, teams, souscriptions, identifiants |
| `GET /accessProfiles` | 208-214 | UUID d'équipe |
| `GET /archive?apis=<guid>` | 223-233 | **sondé seulement**, cf. §5.5 |

**Aucune évolution du contrat du proxy n'est à négocier avec le client.**

### 5.3 Deux faits de forme du produit, à absorber

- Les `teams` vivent au niveau de l'**entrée `apiResponse`**, pas dans `api` :
  `apiResponse.api.teams` est `null` sur la 10.15 réelle (mesuré 2026-08-05,
  `mocks/webmethods/store.go:42-48`). Un seul `GET /apis` suffit donc pour grouper — pas de N+1.
- Les **enveloppes sont incohérentes** (`/apis` → `apiResponse`, `/applications` →
  `applications`, `/policyActions` → clé singulière pour une liste, `/strategies` →
  **tableau nu**). Le normaliseur existe :
  `ansible/roles/apim_selfservice_app/tasks/strategies-list.yml:45-53`.
- `isActive` se lit en **booléen JSON strict** : absent, `null`, `"true"` (chaîne) ou `1`
  valent inactif (`apim_selfservice_app/tasks/main.yml:55-56`).

### 5.4 Les huit situations que `scan` nomme

Aucune n'interrompt le run. Chacune exclut l'objet de la génération et l'inscrit au rapport.

| # | Situation | Verdict | Geste proposé |
|---|---|---|---|
| 1 | API en `[Administrators, Default]` seulement | `API_NON_APPROPRIEE` | `assign-api-team.sh --team <x>` — **sauf** les APIs d'infra plateforme, qui restent en `Default` délibérément |
| 2 | Lignée mixte (une version en `Default`) | `LIGNEE_PARTIELLEMENT_ETRANGERE` | la garde est ∀ sur la lignée (`version.yml:272-280`) |
| 3 | API dans plusieurs équipes réelles | `API_MULTI_EQUIPES` | **trou du dépôt** : le prédicat est `contains`, non exclusif. L'outil refuse de trancher |
| 4 | API inactive | `CONTRAT_NON_EXTRACTIBLE_API_INACTIVE` | activer au palier, puis rescanner |
| 5 | Nom hors `^[a-z0-9][a-z0-9-]{1,30}$` ou version hors `X.Y[.Z]` | `NOM_HORS_REGEXP` / `VERSION_HORS_REGEXP` | le nom est un **segment de chemin** : hors classe, c'est une évasion de chemin |
| 6 | API absente du registre de gouvernance | `CLASSIFICATION_UNGOVERNED` | proposer la ligne au dépôt de gouvernance |
| 7 | Application `ownerType=user` | `APP_PROPRIETE_INDIVIDUELLE` | la 10.15 masque l'`apiAccessKey` à tout non-propriétaire, Administrator compris |
| 8 | Dépôt déclaré par deux équipes | `REPO_AMBIGU` | refus existant, gabarit `team-publish.sh:244` |

### 5.5 Le préflight, et la sonde d'archive

**Le préflight ne vise PAS `/health`.** Chez ce client, `/health` n'est pas joignable depuis
l'externe, et le dépôt avait déjà prévu ce cas mot pour mot
(`ci/Jenkinsfile.selfservice:503-507` : « chez un client, /health peut être injoignable depuis
la VIP, ou filtré en amont »). Il n'y a **rien à proxifier** : ce que `/health` prouve n'a rien
d'unique.

La sonde de vie est **`GET /apis` sans jeton**, à travers le proxy. Le préflight accepte
`200 401` — et le 401 n'est pas une tolérance, c'est la preuve la plus forte : il dit que le
proxy est vivant **et** que son OAuth2 est déjà enforce (`Jenkinsfile.selfservice:518-519`).
`GET /apis` est déjà déclaré au contrat (l.39-43), donc cette sonde ne coûte aucun endpoint.

Trois knobs repris tels quels du pipeline, jamais réinventés : `APIM_PREFLIGHT=off` (désactive),
`APIM_PREFLIGHT_URL` (vise une autre sonde), `APIM_PREFLIGHT_CODES` (défaut `200 401`).
Le défaut de `scan` est `<BASE>/apis`, pas `<BASE>/health`.

Les cinq autres endpoints sont sondés au premier passage, avec jeton, et le résultat est
inscrit dans `provenance.sondes`.

`GET /archive` est **sondé une fois et rapporté**, jamais en dépendance : son GET est
déclaré au contrat, mais sa **réponse** y est typée `application/json` uniquement
(`components/responses/proxied`, l.275-282) et **aucun export n'a jamais été joué à travers
le proxy** dans tout le dépôt. Ce qui est prouvé, c'est le binaire *montant*
(`POST /archive` multipart, builds Jenkins réels vers `wm-mock-rec` via `wm-admin-rec`).
La sonde vérifie les octets magiques `PK\x03\x04` et rend `archive_zip: OK | KO | NON_MESURE`.

### 5.6 La garde de troncature

**Rien dans le dépôt ne prouve que `GET /apis` rend le parc complet.** Aucun appelant ne
pagine ; toutes les mesures live portent sur ~10 APIs. Sur une instance de banque, un
fournisseur entier peut manquer **en silence**, et un group-by sur une liste tronquée est
une erreur qu'on ne voit jamais.

`scan` refuse `PARC_POSSIBLEMENT_TRONQUE` dans **deux** cas, sans seuil deviné :

1. **Contre-compte obligatoire au premier passage.** `SCAN_PARC_ATTENDU` (nombre d'APIs et
   d'applications relevé en console par l'ops du client) est **exigé**, sans défaut. Si le
   compte rendu par la gateway diffère, `scan` refuse. Aux passages suivants, le contre-compte
   du dernier `estate.<env>.json` sert de référence et toute **baisse** inexpliquée refuse.
2. **Tout indice de pagination** dans la réponse (entête `Link`/`X-Total-Count`, champ
   `totalCount`/`hasMore`/`nextCursor` dans l'enveloppe) refuse immédiatement — le dépôt n'a
   aucun appelant qui pagine, donc aucun code pour le faire correctement.

Un inventaire partiel qui a l'air complet est le pire produit possible ici : un fournisseur
entier manquant ne se voit pas, et le group-by ment sans rien signaler.

### 5.7 Diagnostic d'échec

Un 401 a **deux** causes : mauvais identifiant, **ou** compte hors de tout groupe d'admin
(`setup-wm-palier-admins.sh:19-21`). `scan` les distingue — sinon on fait relancer un login
en boucle et on **verrouille un compte AD**. La formulation à servir à l'ops existe déjà :
`ci/Jenkinsfile.carto:567-569`.

## 6. Le format `estate.<env>.json`

```json
{
  "schema": 1,
  "provenance": {
    "base": "https://apim.vip.interne:5543/gateway/wm-admin-dev/1.0/rest/apigateway",
    "env": "dev", "via": "proxy-oauth2", "scanned_at": "2026-09-07T10:12:33Z",
    "sondes": { "preflight": 401, "apis": 200, "applications": 200, "archive_zip": "NON_MESURE" }
  },
  "comptes": { "apis": 47, "lignees": 31, "applications": 12, "equipes": 6, "troncature": "OK" },
  "equipes": [ { "nom": "toto", "uuid": "8f3c…", "source": "local" } ],
  "lignees": [
    { "nom": "paiements", "equipe": "toto", "verdict": "OK",
      "versions": [
        { "version": "1.0.0", "guid": "a1b2…", "isActive": true,
          "teams": ["toto", "Administrators"],
          "contrat": { "source": "apiDefinition",
                       "fichier": "contrats/paiements-1.0.0.openapi.yaml", "sha256": "…" } } ] }
  ],
  "applications": [
    { "nom": "app-front", "id": "c9d1…", "ownerType": "team", "owner": "toto",
      "souscriptions": [ { "nom": "paiements", "version": "1.0.0" } ],
      "identifiants": [ { "type": "apiKey", "valeur": "NON_TRANSPORTEE" },
                        { "type": "ip", "valeurs": ["10.0.0.0/8"] } ],
      "verdict": "OK" }
  ],
  "refus": [ { "objet": "virements", "code": "API_MULTI_EQUIPES",
               "detail": "teams=[toto, titi]", "geste": "arbitrer, puis rescanner" } ]
}
```

Cinq règles de format, non négociables :

1. **Aucun secret n'entre ici.** Les identifiants sont enregistrés par *type*, jamais par
   valeur. Pour une application `ownerType=user`, on écrit
   `CLE_MASQUEE_PROPRIETAIRE_UTILISATEUR` — la 10.15 rendrait 32 astérisques, et écrire le
   masque serait un vert menteur. `provenance.base` est expurgée.
2. **Le contrat OpenAPI est un fichier à côté**, référencé par chemin **et `sha256`.
   `render` refuse si l'empreinte ne correspond pas.
3. **La lignée est l'unité**, pas la version — parce que la garde de publication est ∀ sur
   la lignée du nom.
4. **Ordre déterministe** (tri par nom puis version) : deux scans du même parc donnent deux
   fichiers identiques octet pour octet, donc `diff` suit le parc gratuitement.
5. **`schema` est versionné** et `render` fail-close dessus : `ESTATE_SCHEMA_INCONNU`.

Un fichier **par palier** (les GUID et l'activité diffèrent), **jamais committé par
l'outil** : c'est la carte du SI du client, à lui de décider s'il l'archive.

## 7. Étage `render`

Fonction **pure** : `estate.<env>.json` + `contrats/` → un arbre local. Aucun réseau,
aucun secret, aucun accès forge.

### 7.1 Il n'écrit aucun gabarit nouveau

| Objet | Gabarit existant | Substitution |
|---|---|---|
| API | `gateways/templates/publish.yml.tmpl` | **cinq** marqueurs, un `sed` (`api-request.sh:416-421`) : `__API_NAME__`, `__API_VERSION__`, `__INBOUND_MODE__`, `__CLASSIFICATION__`, `__EXPOSURE__` |
| Application | les deux heredocs de `provision-request.sh:595-641` | clé racine `apim_ss_app`, variantes `idp` / `internal` |

Le contrôle post-rendu est repris tel quel : aucun `__X__` ne survit, sinon
`GABARIT_NON_SUBSTITUE` (`api-request.sh:426-427`). Deux lignes qui protègent du jour où le
gabarit gagnera un marqueur que le générateur ne connaît pas.

Le gabarit **quote déjà** `name:` et `version:` (`publish.yml.tmpl:39-40`) : le piège
YAML `1.10 → 1.1` est fermé par construction sur ce chemin.

### 7.2 Trois contrats de sortie, à l'octet

1. `contract:` n'a **qu'une** forme légitime :
   `"{{ (pub_manifest_path | dirname) }}/<name>.openapi.yaml"`. `team-publish.sh:320,328-331`
   fait une **égalité de chaîne exacte**, avec le nom lu sur la *branche*. Toute autre
   valeur ⇒ `MANIFEST_CONTRACT_INVALIDE`, avant tout `ansible-playbook`.
2. **Une seule clé racine `apim_api:`** ⇒ sinon `MANIFEST_KEYS_FORBIDDEN`. Pas de bloc
   `metadata:` ou `provenance:` : la provenance vit dans `estate.<env>.json` et le README.
3. **Chemins** : `apis/<name>.publish.yml` et `apis/<name>.openapi.yaml` côte à côte à la
   **racine** du dépôt fournisseur.

`team-publish.sh:155-159` coupe la branche au **dernier tiret** : un nom d'API peut porter
des tirets, **une version jamais**. `render` refuse `VERSION_AVEC_TIRET`.

### 7.3 L'arbre produit

```
sortie/
├── estate.dev.json
├── contrats/paiements-1.0.0.openapi.yaml
├── depots/
│   ├── toto/
│   │   ├── apis/paiements.publish.yml
│   │   ├── apis/paiements.openapi.yaml
│   │   ├── applications/app-front.ansible.yml    ⚠ inerte jusqu'au chantier B
│   │   └── README.md
│   └── titi/…
├── plateforme/
│   └── ansible/providers.dev.yml.fragment
└── rapport.md
```

### 7.4 Ce qu'il refuse de produire

Toute lignée dont le verdict n'est pas `OK` **ne produit aucun fichier** — elle va au
`rapport.md` avec son geste. Générer un dépôt pour une lignée refusée, c'est produire
quelque chose que la chaîne rejettera plus tard, plus loin, avec un message moins clair.

La **posture** n'est jamais inventée : `classification`/`exposure` sont repris du registre
central quand la ligne existe ; sinon l'API va au rapport avec la ligne à proposer.
Déclarer plus faible que le registre est refusé `CLASSIFICATION_SPOOFED` avant le premier
appel gateway.

### 7.5 L'avertissement du README (D5 + D6)

Chaque `depots/<équipe>/README.md` porte, daté du jour de génération :

> `applications/` est produit par l'initialisation mais **la chaîne ne le lit pas encore** :
> les manifestes d'application sont aujourd'hui consommés dans le dépôt plateforme
> (`clients/provisioned/applications/`, `MANIFEST_DIR`). Ces fichiers sont **inertes**
> jusqu'au chantier B.

C'est la seule protection contre un fichier présent, plausible, que personne ne lit — le
piège déjà payé avec `environments.yaml` dans un dépôt d'équipe.

Le README dit aussi sous quelle identité le scan a tourné (§9.2).

## 8. Étage `publish`

Seul étage qui écrit, et **uniquement sur la forge**. Jamais sur la gateway, jamais sur `main`.

### 8.1 Il ne crée pas les dépôts (D10)

Les dépôts sont créés par le client sur sa forge, **vides**. `publish` exige qu'ils
existent et soient vides — sinon `DEPOT_ABSENT` ou `DEPOT_NON_VIDE`, avec le nom attendu.
Le parse de l'état du dépôt est fail-closed : un HTTP 200 dont le corps ne se parse pas
**refuse**, il n'est jamais lu comme « non vide » par défaut (discipline `team-apply.sh:190-196`).

Cela réduit la surface spécifique à la forge à **un seul appel** : l'ouverture de la PR/MR
(§8.4).

### 8.2 Les helpers repris

| Geste | Helper | Ce qu'il apporte |
|---|---|---|
| En-tête d'auth | `scripts/lib/forge-identity.sh` → `forge_auth_write` | `FORGE_API_AUTH` : `token` (Gitea) \| `private-token` (GitLab) \| `basic` ; mode inconnu ⇒ `FORGE_API_AUTH_INCONNU` rc 2 |
| Push | `forge_askpass` (motif A7) | conserve le schéma de `GIT_HOST` (bug nommé : `http://https://forge.client/…`), n'écrit pas `x:` en dur |
| Confirmation de PR | `scripts/lib/gitea-pr-confirm.sh` | relit la forge avant de croire au succès ⇒ `FORGE_NON_CONFIRMEE` |
| Verdict sur la PR | `scripts/lib/gitea-pr-comment.sh` | upsert idempotent par marqueur HTML invisible, paginé jusqu'à page vide |

Le motif de push n'est pas un détail : `team-apply.sh:210-226` documente une mesure
`ps -Aww` sur un run réel montrant le jeton **en clair dans l'argv** de `git push` et de son
enfant `git-remote-http`. `forge_askpass` ferme cela mieux que `GIT_CONFIG_*` et c'est la
forme la plus récente du dépôt.

### 8.3 La branche

`init/<env>-<YYYYMMDD>` (ex. `init/dev-20260907`), **pas** `api/<nom>-<version>` : une PR d'initialisation porte
plusieurs APIs.

**Vérifié** : une branche hors `api/*` mergée sur un dépôt fournisseur est un **no-op vert**.
`team-publish.sh:153` fait `case "$PR_BRANCH" in api/*) ;; *) echo "hors api/* — rien à
publier"; exit 0;; esac`. Le Jenkinsfile garde le stage (`:164`), ne réveille personne
(`:160`) et ne commente même pas la PR (`:273-277`). Aucune porte supplémentaire à écrire.

**Conséquence à écrire dans le rapport** : merger la PR d'initialisation **ne publie rien**.
Elle dépose des fichiers. La publication de chaque API reste le parcours normal
(`api-request` → branche `api/<nom>-<version>` → merge → `team-publish`).

### 8.4 Le seul appel spécifique à la forge

L'ouverture de PR/MR diffère : Gitea `POST /api/v1/repos/<owner>/<repo>/pulls`, GitLab
`POST /projects/:id/merge_requests`. Elle est isolée dans **une** fonction
`forge_open_pr`, avec :

- une implémentation Gitea (le lab, reprise de `api-request.sh:473-479` — python3, jamais
  `jq`, jeton par environnement, jamais en argv) ;
- une implémentation GitLab : le projet est résolu par son chemin **URL-encodé**
  (`/projects/<groupe%2Fprojet>/merge_requests`), jamais par un id numérique que l'outil
  n'a aucun moyen de connaître ;
- un **repli** quand la forge n'est pas reconnue : imprimer l'URL d'ouverture de MR et
  rendre `PR_A_OUVRIR_MANUELLEMENT` — l'outil reste utilisable, il ne ment pas sur ce
  qu'il a fait.

### 8.5 La PR sur le dépôt plateforme

En plus d'une PR par fournisseur, `publish` ouvre **une** PR sur le dépôt plateforme, portant
les entrées `providers.<env>.yml` rendues en §7.3 — une ligne `team:` + `repo:` par équipe.

Trois différences avec les PR fournisseurs :

- Le dépôt plateforme **existe déjà** : D10 ne s'y applique pas, `publish` ne vérifie que la
  branche de base et le droit d'écriture.
- Le fragment est **fusionné**, jamais substitué : `publish` relit `ansible/providers.<env>.yml`
  sur la base, ajoute les équipes absentes, et **refuse `PROVIDERS_CONFLIT`** si une équipe y
  figure déjà avec un `repo:` différent — c'est le cas où deux vérités s'affrontent, et il ne
  se tranche pas tout seul.
- Elle doit être mergée **avant** les PR fournisseurs : sans son entrée `repo:`, la liste du
  formulaire ne verra pas les dépôts. `publish` le dit dans le `rapport.md` et dans le corps
  de chaque PR.

Elle porte le même préfixe de branche, `init/<env>-<YYYYMMDD>`.

### 8.5 Idempotence

Chaque écriture est idempotente et **confirmée par relecture** : branche poussée sur
elle-même, PR listée d'abord et filtrée côté client sur `head.ref` (⇒ `EXIST <n>` sans
créer), commentaire upserté par marqueur. Un `publish` interrompu se rejoue sans dégât —
ce qui compte quand le parc fait quarante dépôts et que le vingt-deuxième tombe sur un timeout.

## 9. Secrets et portabilité

### 9.1 L'identité vers la gateway

Deux chemins Vault par palier :

| Chemin | Rôle |
|---|---|
| `envs/<env>/wm-admin` | **le ticket d'entrée** : GET 200 exigé avant tout contact gateway, **même en proxy** ; le corps n'est jamais lu. `PALIER_FERME` sinon |
| `envs/<env>/admin-oauth` | `client_id`, `client_secret`, `token_url` |

La policy par palier fait **exactement quatre chemins en lecture**, testée par mutation :
`scan` n'a besoin d'**aucun droit Vault nouveau** tant qu'il écrit son inventaire en local.

Deux pièges câblés dès le départ :

- **`apim_ss_oauth_client_auth` doit valoir `basic`** chez ce client. Le défaut du dépôt
  est `post`, et l'AS *local* de la gateway répond « Transport protocol must be HTTPS »
  (`apim_common/defaults/main.yml:44-51`, sondé live).
- Le `token_url` vient de Vault par défaut ; une variable d'environnement n'est passée que
  si elle est **non vide**, sinon un extra-var vide masquerait Vault.

### 9.2 Identité de lecture seule : nommée, pas livrée

`scan` ne fait que des GET, donc une identité en lecture seule suffirait. Le mécanisme
existe (`accessProfile` + bitmask `privilege`), mais le bitmask par défaut est une **copie
de celui d'`API-Gateway-Providers`** et le retrait de `POST /apis` **n'est pas tranché**
(`apim_team_onboard/defaults/main.yml:22-28`) : il exige un profil jetable, un bit-flip, et
la capture du bitmask d'avant comme rollback.

Hors périmètre. `scan` tourne sous l'identité d'admin du palier, **et son README le dit**.

### 9.3 Tourner sans Vault

Non négociable. Doctrine déjà écrite : `ci/lib/carto-secrets.sh:29-37` — « **LE DÉFAUT EST
"PAS DE VAULT", ET C'EST DÉLIBÉRÉ** ». Deux sources, bascule **chemin par chemin** :
credential Jenkins, ou Vault AppRole. `scan` reprend `carto_secrets_resolve()`.

### 9.4 La CA : un knob, trois endpoints

Un **unique** bundle PEM doit couvrir la gateway, l'IdP OAuth2 **et** Vault — concaténés
s'ils diffèrent (`apim_common/defaults/main.yml:20-26`). En bash, précédence `VAULT_CACERT`
puis `LABCTL_CA_FILE` (`ci/lib/vault-login.sh:102-105`).

### 9.5 Ce qui ne traverse jamais vers Git

| Objet | Ce qui est écrit |
|---|---|
| Clé d'API d'une application | `NON_TRANSPORTEE`, ou `CLE_MASQUEE_PROPRIETAIRE_UTILISATEUR` |
| Secret d'un credential alias | jamais — le manifeste porte le **chemin Vault** |
| Archive d'export | jamais écrite dans un dépôt (`PassmanData/`, `Alias/`) |
| Base d'admin dans un message | expurgée |

Côté forge, le script ne connaît que `FORGE_SECRET` + `FORGE_USER` (alias `GITEA_TOKEN`),
quel que soit le type de credential.

## 10. Préalable au chantier

**Extraire la composition de la base d'admin** de `scripts/selfservice-palier-gate.sh:104-125`
vers `scripts/lib/apim-base.sh`, sourcée par la garde **et** par `scan`, avec ses refus
nommés inchangés (`APIM_BASE_INVALIDE`, `TERMINUS_SANS_VOIE`, `VIA_INCONNU`).

C'est un refactor à comportement constant, prouvé par les épreuves existantes de la garde
(`scripts/test-selfservice-palier-a3.sh`) plus une épreuve de parité : la lib et la garde
composent la même base sur la même entrée. Une base d'admin recopiée est la garantie qu'un
jour les deux divergeront.

## 10 bis. Ordre d'implémentation

La spec tient en un seul plan à condition de la dérouler dans cet ordre — chaque palier est
livrable et prouvable seul :

1. **`scripts/lib/apim-base.sh`** (§10) — refactor à comportement constant, prouvé par les
   épreuves existantes plus une épreuve de parité.
2. **`scan`** — jusqu'à `estate.<env>.json` + `contrats/` + `rapport.md`. Prouvable contre le
   mock, puis un préflight live.
3. **`render`** — l'étage le plus dense en contrats de sortie, **intégralement hors ligne**.
4. **`publish`** — le seul qui écrit, prouvé sur Gitea du lab.
5. **`init-depots-fournisseurs.sh`** — l'enchaînement des trois.

Un palier qui ne rougit pas par mutation n'est pas livré.

## 11. Les refus nommés

| Étage | Refus | Cause |
|---|---|---|
| scan | `VIA_INCONNU` | `ADMIN_VIA` absent ou hors `direct\|proxy-oauth2` |
| scan | `APIM_BASE_INVALIDE` | un composant vide, ou base non http(s) |
| scan | `PALIER_FERME` | pas de lecture sur `envs/<env>/wm-admin` |
| scan | `PARC_POSSIBLEMENT_TRONQUE` | seuil atteint ou entête de pagination |
| scan | `API_NON_APPROPRIEE` | teams ⊆ profils système |
| scan | `LIGNEE_PARTIELLEMENT_ETRANGERE` | une version de la lignée non confirmée |
| scan | `API_MULTI_EQUIPES` | plusieurs équipes réelles |
| scan | `NOM_HORS_REGEXP` / `VERSION_HORS_REGEXP` | classe opposable violée |
| scan | `CONTRAT_NON_EXTRACTIBLE_API_INACTIVE` | `isActive` ≠ `true` |
| scan | `CLASSIFICATION_UNGOVERNED` | absente du registre central |
| scan | `APP_PROPRIETE_INDIVIDUELLE` | `ownerType=user` |
| scan | `REPO_AMBIGU` | dépôt déclaré par deux équipes |
| render | `ESTATE_SCHEMA_INCONNU` | `schema` non supporté |
| render | `CONTRAT_EMPREINTE_INVALIDE` | `sha256` ne correspond pas |
| render | `GABARIT_NON_SUBSTITUE` | un `__X__` survit au rendu |
| render | `VERSION_AVEC_TIRET` | la branche `api/<n>-<v>` serait mal parsée |
| publish | `DEPOT_ABSENT` / `DEPOT_NON_VIDE` | prérequis D10 non tenu |
| publish | `FORGE_API_AUTH_INCONNU` | mode d'auth forge hors liste |
| publish | `FORGE_NON_CONFIRMEE` | la relecture ne confirme pas la PR |
| publish | `PR_A_OUVRIR_MANUELLEMENT` | forge non reconnue — repli assumé, pas un échec |

## 12. Plan de preuve

| Étage | Où | Comment |
|---|---|---|
| `apim-base.sh` | hors ligne | parité lib ↔ garde sur les mêmes entrées ; les 3 refus par mutation |
| `scan` | hors ligne | contre `mocks/webmethods` : enveloppes, `teams[]` au niveau entrée, `isActive` strict, les 8 verdicts, la garde de troncature |
| `scan` | live | préflight `GET /apis` **sans jeton** à travers le self-proxy (200 ou 401) ; sonde `/archive` (octets magiques) |
| `render` | **hors ligne, intégralement** | les 3 contrats de sortie à l'octet ; les 5 verdicts qui ne produisent rien ; `GABARIT_NON_SUBSTITUE` et `VERSION_AVEC_TIRET` par mutation ; déterminisme (deux rendus identiques `cmp -s`) |
| `publish` | live Gitea | dépôt vide → branche → PR → confirmation ; rejeu complet sans dégât ; `DEPOT_NON_VIDE` ; PR `init/` mergée ⇒ `team-publish` vert sans rien publier |
| tout | `make lint-ci` | `lint-config-knobs` (aucun défaut de site), `shellcheck`, compilation des Jenkinsfile |

Chaque épreuve ajoutée doit **rougir par mutation** — une épreuve qui ne rougit jamais est
un vert vacant, et ce dépôt en a déjà payé le prix.

## 13. Chantiers dérivés, nommés et hors périmètre

- **B — la chaîne lit `applications/` dans le dépôt fournisseur.** Aujourd'hui
  `MANIFEST_DIR=clients/provisioned/applications` dans `provision-request.sh:204`,
  `provision-plan.sh:61`, `provision-apply-reconcile.sh:99`, `provision-apply-gate.sh:69`,
  plus `app-rollback-request.sh:70`. Jusque-là, les `applications/` générés sont **inertes**
  (D6, avertissement §7.5).
- **Identité de lecture seule sur la gateway** (§9.2) — méthode écrite, jamais jouée.
- **Adaptateur de forge complet** — si un jour `team-apply` et `api-request` doivent créer
  des dépôts sur GitLab, la surface Gitea (`/api/v1/orgs`, `POST /orgs/<org>/repos`,
  `x:` en dur dans `team-apply.sh:221`, `team-request.sh:179`, `api-request.sh:443`) devra
  être abstraite. D10 l'évite pour ce chantier, elle ne le résout pas.
- **Import de contrat depuis une archive + sonde de dérive** — le dépôt ne détecte pas
  qu'un contrat en Git diverge de ce que la gateway sert.
- **`API_MULTI_EQUIPES`** — le dépôt n'a aucun refus pour ce cas (§5.4 n°3). L'outil le
  nomme ; fermer le trou côté chaîne est un travail à part.

## 14. Risques et paris

| Risque | Portée | Traitement |
|---|---|---|
| `GET /apis` tronque sur un gros parc | **élevée** — jamais mesuré au-delà de ~10 APIs | garde `PARC_POSSIBLEMENT_TRONQUE` (§5.6) |
| `teams[]` absent de `GET /applications` en réel | moyenne — vrai du mock seulement | N+1 `GET /applications/{id}` assumé dès le départ |
| `/archive` ne traverse pas le proxy | faible impact | sondé, jamais en dépendance (D8) |
| Le client refuse une identité d'admin pour le scan | moyenne | §9.2 nomme le livrable ; en attendant, l'admin du palier |
| `render` testé contre le mock ne voit jamais `apiDefinition` | certaine | le mock ne le sérialise pas (`store.go:37-40`) : les épreuves de contrat utilisent des `estate.json` **fabriqués**, pas le mock |
