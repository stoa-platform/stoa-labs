# L5 phase 2 — la chaîne producteur ne parle plus qu'à l'autorité de forge

*Spec de design, 2026-09-12. Statut : validée section par section avec l'utilisateur
(approche A), à relire avant le plan d'implémentation.*

## 1. Le problème

L5 phase 1 (`82f3c5d`, 2026-09-09) a créé **une seule autorité** pour parler à la forge,
`scripts/lib/forge-api.sh` + `scripts/lib/forge-api.py` — visage `FORGE_KIND=gitea|gitlab`,
base d'API, en-tête d'authentification, garde de réponse, formes normalisées — et y a routé
la **chaîne app-request**. La **chaîne producteur** (onboarder une équipe, publier une API,
promouvoir, exporter) parle encore l'API de Gitea en direct : la cartographie du 2026-09-12
compte **48 interactions avec la forge dans 15 fichiers**, dont 20 déjà couvertes par un
verbe existant (ouverture et lecture de PR, commentaires, `raw`) et 28 sans verbe. Sur un
GitLab, chacune meurt en accusant autre chose que la cause : `/api/v1` ⇒ 302 vers
`/users/sign_in`, `number` absent, `empty` absent, `html_url` absent.

Les 28 sans verbe se répartissent en trois familles :

| Famille | Sites | Ce que D10 en fait |
|---|---|---|
| création d'org, de dépôt, de hook, de protection (`team-apply.sh` §2, `repo-protection.sh`, `setup-repo-protections.sh`) | 13 | **supprimée de la chaîne** (§3) |
| registre de paquets génériques (`archive-store.sh`, appelé par `api-promote-export` et `team-promote`) | 4 | **second visage** (§5) |
| liens humains composés à la forme Gitea (`/pulls/N`, `/src/commit/<sha>/<chemin>`) et lectures diverses | 11 | **helpers de l'autorité** (§4.4) |

## 2. Décisions prises (2026-09-12, utilisateur)

- **D10 profond.** Chez le client, **le client crée les dépôts d'équipe, leurs webhooks et
  la protection de branche**. La chaîne ne crée plus rien sur la forge, **sur aucun
  visage** (Gitea du lab compris) : une seule conduite. Le lab pré-crée ses dépôts jetables
  par un outil de poste.
- **Preuve.** Les scripts routés sont prouvés **en direct sur le GitLab CE réel du lab**
  (variante GitLab de la matrice producteur : MR ouvertes par les scripts, mergées par
  l'API, apply joués en direct). En parallèle, la session voisine livre **L6 phase 2** : les
  récepteurs de webhooks des jobs `team-apply`, `team-publish`, `team-promote` à deux
  visages. La preuve de bout en bout **par webhooks GitLab** vient quand les deux lots sont
  posés.
- **Approche A** : verbes normalisés dans l'adaptateur unique, D10 appliqué dans
  `team-apply`, `archive-store` à deux visages, porte étendue. Les approches « verbe
  générique `forge call` » (le parsing de visage se disperse dans sept scripts) et
  « réécriture python des scripts » (casse le canal du secret par descripteur 3 et toutes
  les ancres bash) sont écartées.
- **`team-apply` garde son idempotence** : un dépôt existant **non vide** est « déjà
  initialisé, étape sautée », pas un refus. `DEPOT_NON_VIDE` reste réservé à l'outil
  `publish` de la spec `2026-09-07-init-depots-fournisseurs-design.md` (§8.1), qui n'a pas
  la même contrainte de rejeu.

## 3. Objectifs et non-objectifs

**Objectifs.**
1. Aucun script de la chaîne producteur ne porte plus `/api/v1`, `Authorization: token`,
   `urlopen`, ni une forme propre à un visage (`number`/`iid`, `empty`/`empty_repo`,
   `html_url`/`web_url`, `/pulls/`, `/src/commit/`).
2. `team-apply` applique D10 : il **lit** le dépôt d'équipe, refuse `DEPOT_ABSENT`, pousse
   le squelette dans un dépôt vide, commente ; il ne crée ni org, ni dépôt, ni hook, ni
   protection, et ne lit plus le jeton org-admin dans Vault.
3. L'adaptateur gagne les verbes strictement nécessaires (`repo_get`, `raw` à ref
   optionnelle) et les helpers de liens ; `forge_auth_write` dérive l'en-tête du visage.
4. `archive-store` fonctionne sur GitLab (registre par projet).
5. La porte `ci/lint-forge-literals.sh` couvre toute la chaîne producteur et ferme ses
   angles morts.
6. Chaque verbe neuf est prouvé hors ligne (mock à deux visages, mutations) et en live sur
   les deux forges ; la chaîne producteur est prouvée en direct sur le GitLab du lab.

**Non-objectifs (dettes nommées, pas des oublis).**
- Les **récepteurs de webhooks** des jobs `team-*` (JSONPath GitLab, `WEBHOOK_KIND`) :
  L6 phase 2, session voisine (§9).
- La **création** de groupes, projets, hooks, membres, protections sur GitLab : D10.
- L'outil `publish` / `init-depots-fournisseurs.sh` de la spec 2026-09-07 (paliers 3-5) :
  chantier séparé ; cette spec lui prépare `repo_get` et `pr_open`.
- Les défauts de site `GIT_HOST=http://gitea:3000` restants (13, dont trois dans la chaîne
  producteur) : lot « littéraux de site », déjà nommé par L2.
- ADR-081 « approbation = merge sous protection » : son corollaire 3 (quatre yeux par
  protection nominative) devient un **prérequis de forge** ; la re-pose avec le client sur
  GitLab CE (protection par rôle, pas par utilisateur) reste un arbitrage client.

## 4. L'adaptateur : verbes, helpers, corrections

Contrat inchangé : stdout `CLÉ=VALEUR`, rc 0 ; rc 2 + `REFUS: <TAG> : <cause>` sur stderr,
cause auto-diagnostique (statut, redirection, corps expurgé) ; le secret ne passe jamais en
argv (descripteur 3, `FORGE_SECRET_FILE`, ou env) ; `GIT_REPO` désigne le dépôt visé — un
script qui parle à un **autre** dépôt que le sien le positionne le temps de l'appel
(`GIT_REPO="$REPO_FULL" forge …`, gabarit de `team-publish.sh`).

### 4.1 `repo_get` (nouveau)

`forge repo_get` → `EXISTS=0|1 EMPTY=0|1 DEFAULT_BRANCH=<nom ou vide> URL=<web>`.

| Visage | Endpoint | `EMPTY` | `DEFAULT_BRANCH` |
|---|---|---|---|
| gitea | `GET repos/{owner}/{repo}` | `empty` | `default_branch` |
| gitlab | `GET projects/{owner%2Frepo}` | `empty_repo` | `default_branch` (vide sur un projet vide) |

- Un **404** rend `EXISTS=0 EMPTY= DEFAULT_BRANCH=` avec **rc 0** : l'absence est une
  réponse, pas une panne. La ligne de cause (stderr, informative) précise que sur GitLab un
  404 vaut aussi « invisible pour ce jeton ».
- Tout autre statut hors 2xx, une redirection, un corps non JSON ou sans les champs
  attendus ⇒ refus (garde `call()` existante). `EXISTS=1` sans champ `empty`/`empty_repo`
  lisible ⇒ refus : jamais « non vide » par défaut (discipline fail-closed reprise de
  `team-apply.sh:243`).
- C'est le **seul** verbe neuf qui lit un dépôt ; aucun verbe de création n'est ajouté.

### 4.2 `raw` : ref optionnelle

`forge raw <chemin> [ref]`. La doc de `forge-api.sh:18` le promettait ; le registre des
verbes exigeait deux arguments. `main()` accepte désormais un nombre d'arguments **minimal
et maximal** par verbe (au lieu de tronquer en silence les surnuméraires) ; `raw` = (1, 2).
Sans ref : HEAD du projet côté GitLab (mesuré CE 17.11 : 200, `X-Gitlab-Commit-Id` = tête
de `main`), HEAD côté Gitea. Prérequis client écrit : GitLab ≥ 13.12 (`ref` optionnelle
sur `/raw`).

### 4.3 `forge_auth_write` dérive du visage

`scripts/lib/forge-identity.sh` : `mode=${FORGE_API_AUTH:-token}` devient « `FORGE_API_AUTH`
si posée, sinon **dérivée de `FORGE_KIND`** (`token` gitea, `private-token` gitlab) », et
`bearer` est accepté (`Authorization: Bearer`). C'est ce que `forge-api.py:212-230`,
`setup-jenkins-globals.sh:127-129` et ENVIRONNEMENTS.md promettent déjà. Après ce lot,
`forge_auth_write` n'a plus que deux consommateurs : `archive-store.sh` (transport binaire)
et `setup-repo-protections.sh` (outil d'exploitant, Gitea seul).

### 4.4 Les liens humains

Deux helpers **shell** dans `forge-api.sh`, jamais de composition dans les scripts :

- `forge_web_url <url-rendue-par-un-verbe>` : rend l'URL telle quelle, sauf si
  `GIT_WEB_HOST` est posée **et** différente de `GIT_HOST` — alors le préfixe `GIT_HOST`
  est remplacé par `GIT_WEB_HOST` (le knob garde son rôle : vue poste contre vue conteneur).
- `forge_web_file_url <sha> <chemin>` : `{web}/{GIT_REPO}/src/commit/{sha}/{chemin}`
  (gitea), `{web}/{GIT_REPO}/-/blob/{sha}/{chemin}` (gitlab), `{web}` = `GIT_WEB_HOST`
  sinon `GIT_HOST`.

Les scripts n'écrivent plus `/pulls/N` : `pr_open` et `pr_get` rendent `URL=`.

### 4.5 Ce qui n'est pas ajouté

- Pas de `pr_ensure` général : `team-request` et `api-request` gardent leur refus nommé au
  rejeu (une branche déjà poussée est un signal, pas un état à absorber) ; seul
  `api-promote-export`, dont le rejeu est **nominal** (`push -f` de la branche d'épinglage,
  spec 2026-08-28 §104-107), enchaîne `pr_find_open <head>` puis `pr_open`.
- Pas de verbe de commentaire sans marqueur : la doctrine « un commentaire par rôle »
  (`gitea-pr-comment.sh:19-22`) s'applique (§6).

## 5. `archive-store` à deux visages

| | Gitea | GitLab |
|---|---|---|
| adressage | par **propriétaire** : `/api/packages/{ARCHIVE_STORE_OWNER}/generic/{nom}/{version}/{fichier}` | par **projet** : `/api/v4/projects/{ARCHIVE_STORE_PROJECT url-encodé}/packages/generic/{nom}/{version}/{fichier}` |
| knob | `ARCHIVE_STORE_OWNER` (défaut `ci`, inchangé) | `ARCHIVE_STORE_PROJECT` (`groupe/projet`), **obligatoire** sous ce visage : refus `ARCHIVE_STORE_PROJECT_REQUIS` |
| droits | `write:package` | Developer (PUT), Reporter (GET) ; scope `api` |
| en-tête | `forge_auth_write` (§4.3) | idem |
| réponses | GET 200/404, PUT 201 | GET 200/404 (404 = aussi « pas le droit »), PUT 201 |

La composition d'URL passe par **une** fonction à deux branches dans la lib ; sonde,
`PUT` à 201, fetch par digest, `STORE_CONFLIT_CONTENU`, `STORE_HTTP_<code>`,
`STORE_DIGEST_MISMATCH` ne bougent pas. Le transport reste en `curl` (l'adaptateur python
ne parle que JSON) : `archive-store.sh` est une **seconde autorité, étroite et nommée**,
pour les paquets — la porte la contrôle (§7). Le lab GitLab reçoit un projet d'artefacts
(`ci/archives`, privé) créé par `setup-gitlab-lab.sh`, et `ARCHIVE_STORE_PROJECT=ci/archives`
entre dans les globales du lab.

## 6. Le routage, script par script

Politique d'échec commune : un verbe qui refuse rend une **cause nommée** (jamais une
trace python) ; le **verdict** d'un plan ou d'un apply ne dépend jamais du succès de son
**rapport** (commentaire) — l'échec du commentaire est un avertissement nommé sur stderr,
visible dans le build (politique déjà en place dans `api-request.sh:675-678`).

| Script | Aujourd'hui | Après | Notes |
|---|---|---|---|
| `team-request.sh` | :241 POST pulls (urllib) ; :287 POST comments **muet** | `forge pr_open` ; `forge comment_upsert <n> '<!-- team-request-plan -->' <fichier>` avec avertissement nommé si refus | lien = `forge_web_url "$URL"` |
| `team-apply.sh` | :112 `comment()` ; §2 org/repo/hooks/protection (7 appels) + `repo-protection.sh` ; jeton org-admin Vault | `forge repo_get` puis conduite D10 (§6.1) ; `comment_upsert` sous `<!-- team-apply -->` ; un seul ❌ | plus de Vault `gitea-org-admin`, plus de `pose_branch_protection`, plus de `TEAM_PUBLISH_WEBHOOK_URL` |
| `team-publish.sh` | :219 GET pulls (urllib) ; :538 lien `/pulls/N` | `GIT_REPO="$repo" forge pr_get` (`MERGED`, `MERGE_SHA`, `HEAD_REF`, `BASE_REF`, `MERGED_BY`) ; lien = `URL` | déjà sur `comment_upsert` |
| `team-promote.sh` | :279 GET pulls ; :805 lien | idem `pr_get` ; lien = `URL` | déjà sur `comment_upsert` ; `archive-store` §5 |
| `api-request.sh` | :523 POST pulls ; :667 POST comments | `GIT_REPO="$REPO_FULL" forge pr_open` ; `comment_upsert` sous `<!-- api-request -->` | ce marqueur est déjà lu par `test-p7-bout-en-bout.sh:1036` (pin vacant aujourd'hui) |
| `api-promote-request.sh` | :247 raw sans ref (curl 20 s) ; :402 POST pulls (`html_url`) | `forge raw <PROV_REL>` ; `pr_open` (`URL`) | `FORGE_TIMEOUT` remplace `--max-time 20` |
| `api-promote-export.sh` | :115 raw ; :256 archive-store ; :297 POST pulls + repli 409 | `raw` ; §5 ; `pr_find_open <head>` puis `pr_open` | le 409 n'est plus lu : la retrouvaille précède l'ouverture |
| `lib/repo-protection.sh` | 3 appels Gitea | **inchangée**, plus appelée par la chaîne | outil d'exploitant seulement |
| `setup-repo-protections.sh` | alias `FORGE_SECRET` mort (:143-144) | alias corrigé (forme canonique) ; refus nommé `PROTECTION_GITEA_SEULEMENT` si `FORGE_KIND=gitlab` (prérequis client) | reste livrable, Gitea seul |
| `seed-governance-chain.sh` | alias mort (:44-45) ; `main` en dur (:98) | alias corrigé ; `raw` via l'adaptateur | reste **outil de lab** (déjà exempté par `lint-branch-literals`) |
| `lib/generate-choices.sh`, `app-request-choices.sh`, `provision-plan-status.sh` | gestes git / déjà routés | **rien** | hors périmètre, constaté par la carte |
| `provision-plan.sh:339` | lien `/src/commit/` | `forge_web_file_url` | chaîne app-request, un oubli de phase 1 |

Aucun `withEnv`, aucun Jenkinsfile touché par ce lot : les knobs `FORGE_KIND`,
`FORGE_API_AUTH`, `FORGE_API_BASE` des `environment{}` de `team-*` sont posés par la
session voisine dans L6 phase 2 (§9). Les scripts lisent ces knobs dans l'environnement
comme `provision-plan.sh` le fait déjà.

### 6.1 `team-apply` sous D10 — la conduite

| `repo_get` | Conduite | Note sur la PR |
|---|---|---|
| refus (forge injoignable, secret refusé, forme inattendue) | `fail` avec la cause du verbe | ❌ `team-apply` … |
| `EXISTS=0` | **refus `DEPOT_ABSENT`** : « le dépôt `<REPO_FULL>` n'existe pas (ou n'est pas visible pour ce jeton) — le client le crée **vide** sur la forge (prérequis D10, ENVIRONNEMENTS.md § Prérequis côté client), puis rejoue ce merge » ; rc 2 | ❌ avec le prérequis nommé |
| `EXISTS=1 EMPTY=1` | squelette ADR-076 poussé sur `DEFAULT_BRANCH` si la forge l'annonce, sinon `GIT_BASE` de la plateforme ; puis onboarding Ansible | « dépôt `<REPO_FULL>` : vide, squelette poussé » |
| `EXISTS=1 EMPTY=0` | rien de poussé ; onboarding Ansible (idempotent) | « dépôt `<REPO_FULL>` : déjà initialisé, étape sautée » |

Le push du squelette garde l'enveloppe `git_base_avec_basic "$(git_base_basic_login)"
FORGE_SECRET` posée par la session voisine — c'est **le secret de forge ordinaire** qui
pousse, le porteur de `gitea-provision-token` au lab. Le jeton org-admin, sa lecture Vault
(`secret/stoa/ci/gitea-org-admin`) et la dette « docker exec est la seule voie pour le
minter » disparaissent de la chaîne. Le webhook du dépôt d'équipe vers `team-publish` et la
protection de sa branche par défaut sont des **prérequis de forge** (client, ou harnais du
lab) ; `team-apply` ne les vérifie pas (lister les hooks exige Maintainer sur GitLab, un
faux avertissement serait pire qu'un prérequis écrit).

### 6.2 Le lab

- `scripts/setup-team-repos.sh` (**outil de poste**, exempté de la porte avec sa raison) :
  crée un dépôt d'équipe **vide** sur la forge du lab, deux visages — Gitea par l'API
  d'admin (org + dépôt, comme `test-team-onboarding-chain.sh` le fait déjà en teardown
  inversé), GitLab par l'API avec le PAT de service (groupe existant `ci`, projet privé,
  `initialize_with_readme=false`, méthode de merge « merge commit ») —, puis y pose le hook
  vers `team-publish` (forme du visage : GWT `?token=` ou hook de projet GitLab) et la
  protection de la branche par défaut (Gitea : `repo-protection.sh` ; GitLab CE : par rôle).
  Idempotent, `--print`, refus nommés.
- `test-team-onboarding-chain.sh` et `test-producer-chain.sh` pré-créent le dépôt jetable
  avant `team-apply` ; leurs assertions « 404 → 200 » deviennent « vide → squelette poussé »
  et « déjà initialisé » ; le teardown ne change pas. Une nouvelle preuve joue le refus
  `DEPOT_ABSENT` (dépôt non pré-créé ⇒ ❌ nommé sur la PR, rien de poussé).
- `test-palier-retention.sh` ⑭ (protection posée par `team-apply`, ordre push < pose <
  webhook) se **retourne** : `team-apply` ne source plus `repo-protection.sh`, n'appelle
  ni `pose_branch_protection` ni `TEAM_PUBLISH_WEBHOOK_URL`, et porte le refus
  `DEPOT_ABSENT` ; mutants : réintroduire un appel à `pose_branch_protection` rougit,
  retirer `DEPOT_ABSENT` rougit.

## 7. La porte `ci/lint-forge-literals.sh`

- `ROUTES` s'étend à `team-request.sh`, `team-apply.sh`, `team-publish.sh`,
  `team-promote.sh`, `api-request.sh`, `api-promote-request.sh`, `api-promote-export.sh`,
  `lib/archive-store.sh`. `repo-protection.sh`, `setup-repo-protections.sh`,
  `seed-governance-chain.sh`, `setup-team-repos.sh` et `setup-gitlab-lab.sh` sont
  **exemptés nommément avec leur raison** (outil d'exploitant Gitea seul, outil de lab).
- Le motif `json.load(` ne compte plus les lectures qui ne visent pas la forge : la porte
  ne le retient que sur une ligne qui porte aussi `GIT_HOST`, `FORGE_`, `urlopen` ou un
  chemin d'API (Vault, ITSM, payload local ne rougissent plus).
- Deux motifs neufs : `/api/packages` hors d'`archive-store.sh`, et les formes de lien
  Gitea `/pulls/`, `/src/commit/` hors des autorités.
- Discriminant conservé : une copie mutée d'un fichier routé portant `/api/v1` rougit ;
  un fichier exempté portant un motif ne rougit pas mais **apparaît** dans le rapport
  (« dette nommée, pas silence »).

## 8. Épreuves et preuves

**Hors ligne (sous `make lint-ci`).**
- `test-forge-api.sh` : routes du mock à deux visages pour `GET repos/{o}/{r}` /
  `GET projects/{id}` (états absent / vide / non vide, corps sans champ `empty` ⇒ refus),
  `raw` sans ref (le mock **rend 400 sur `ref=` vide** côté gitlab, comme le vrai), les
  helpers de liens ; mutations champ par champ (`empty_repo` renommé, 404 transformé en 403,
  `web_url` absent) ; discriminant de visage sur chaque verbe neuf ; la troncature silencieuse
  des arguments surnuméraires est un mutant qui rougit.
- `test-archive-store.sh` : la composition d'URL des deux visages, le refus
  `ARCHIVE_STORE_PROJECT_REQUIS`, l'en-tête dérivé du visage (§4.3), stub à deux routes.
- Chaque script routé garde sa suite verte : `test-team-request-wiring` (sonde réelle),
  `test-team-publish-wiring` (ses ancres :404-421 passent d'expressions python au verbe),
  `test-team-promote-wiring`, `test-api-request-wiring`, `test-deploy-pin` (:576 ancre
  `repos/…/raw` ⇒ `forge raw`), `test-repo-layout-portabilite` (stubs `split("/raw/")`),
  `test-palier-retention` (§6.2), `test-p7-bout-en-bout` (marqueur `api-request` vivant),
  `test-generate-choices` (pins de `comment "✅`), `test-app-request-a7` (E0.10-E0.14 :
  `forge_auth_write` sans `FORGE_API_AUTH` sous `FORGE_KIND=gitlab`).
- La porte §7 avec ses mutants.

**Live (à la main, deux forges du lab).**
- `test-forge-api-live.sh` : `repo_get` sur un projet absent / vide / non vide, `raw` sans
  ref, liens ; nettoyage par les verbes existants.
- `test-producer-chain-gitlab.sh` (**nouveau**) : équipe et dépôts jetables **pré-créés**
  par `setup-team-repos.sh` sur le GitLab du lab ; `team-request.sh` joué en direct ⇒ MR
  sur le dépôt plateforme, commentée ; merge par l'API ⇒ `team-apply.sh` joué en direct sur
  le SHA mergé ⇒ squelette poussé, ✅ ; `api-request.sh` ⇒ MR sur le dépôt d'équipe,
  commentée sous `<!-- api-request -->` ; merge par l'API ⇒ `team-publish.sh` en direct sur
  le SHA mergé (mock webMethods du lab) ; `api-promote-request` / `api-promote-export` /
  `team-promote` de même avec l'archive au registre `ci/archives` ; contre-épreuves :
  `DEPOT_ABSENT` (dépôt non pré-créé), `FORGE_KIND=gitea` contre GitLab ⇒ refus nommé
  « REDIRIGE vers /users/sign_in » ; sondage `ps -Aww` : aucun secret en argv ; teardown
  symétrique. Cette matrice **ne passe pas par les webhooks** : c'est la limite écrite, levée
  par la preuve commune avec L6 phase 2.

## 9. Frontière avec L6 phase 2 (session voisine)

| À la session voisine | À ce lot |
|---|---|
| `ci/Jenkinsfile.team-apply`, `.team-publish`, `.team-promote`, leurs `job.xml`, `setup-team-onboard-jobs.sh` (pose, amorçage), les parties déclencheur/JSONPath de `test-team-*-wiring.sh`, sa suite live ; **elle pose `FORGE_KIND`/`FORGE_API_AUTH`/`FORGE_API_BASE` dans les `environment{}`** | tous les scripts de la chaîne producteur, `forge-api.py/.sh`, `forge-identity.sh`, `ci/lint-forge-literals.sh`, `test-forge-api*.sh`, `archive-store.sh` et sa suite, `repo-protection.sh`, `setup-repo-protections.sh`, `setup-team-repos.sh`, `test-producer-chain-gitlab.sh`, ENVIRONNEMENTS.md (sections de ce lot), ADR-099 |

Règle des suites partagées (`test-team-*-wiring.sh`) : **fichier entier à un seul
éditeur**, sur demande explicite, jamais deux éditeurs dans une même suite (un
`EXPECTED_CHECKS` se perd ainsi). Un seul éditeur par fichier, « SHA committé » avant tout
push, gitea et origin poussés ensemble par ce lot.

## 10. Documentation et ADR

- ENVIRONNEMENTS.md : un bloc **« Prérequis côté client »** unifié (L5 : PAT, merge commit,
  webhooks locaux, `master` ; L6 : hooks de projet vers `provision-*` ; **D10** : dépôts
  d'équipe vides, leur hook vers `team-publish`, leur protection de branche ;
  `ARCHIVE_STORE_PROJECT`), le tableau des verbes de l'adaptateur (existants + neufs), la
  conduite de `team-apply`, l'outil de poste du lab, la matrice GitLab.
- **ADR-099 — « La chaîne ne crée rien sur la forge »** : décision (D10 profond), ce qu'elle
  déplace (la protection d'ADR-082 §3 et les quatre yeux d'ADR-081 corollaire 3 deviennent
  des prérequis de forge), conséquences (plus de jeton org-admin, une conduite par visage,
  outil de lab), refus nommés, limites (GitLab CE : protection par rôle), preuves.
- Plan `2026-09-09-forge-agnostique-debug-branche.md` : une **Task 8 (L5 phase 2)** avec
  ses cases, et les cases des Tasks 2-3 cochées a posteriori (livrées par `82f3c5d`).

## 11. Ordre des sous-lots

Chacun : porte TDD rouge d'abord, code, suites voisines vertes, `make lint-ci` 20/20,
relecture adverse à trois lentilles (conformité, fuite, hygiène des épreuves), commit.

1. **Fondations** — `repo_get`, `raw` à ref optionnelle et arguments bornés, helpers de
   liens, `forge_auth_write` dérivé du visage, routes et mutations du mock, porte étendue
   (ROUTES posées **avant** le routage : la porte rougit, puis chaque sous-lot la remet au
   vert fichier par fichier).
2. **PR et commentaires** — `team-request`, `api-request`, `api-promote-request`,
   `api-promote-export` (hors archive), `team-publish`, `team-promote` (`pr_get`, liens),
   `provision-plan.sh:339`.
3. **`team-apply` sous D10** — conduite §6.1, `setup-team-repos.sh`, suites §6.2,
   `setup-repo-protections.sh` et `seed-governance-chain.sh` (alias, refus de visage).
4. **`archive-store`** — deux visages, `ci/archives` au lab, `api-promote-export` et
   `team-promote`.
5. **Preuve GitLab** — `test-forge-api-live.sh` étendue, `test-producer-chain-gitlab.sh`.
6. **Doc et ADR** — §10.

## 12. Risques et points ouverts

- **404 ambigu sur GitLab** (`repo_get`) : « absent » et « invisible pour ce jeton » se
  confondent ; le refus `DEPOT_ABSENT` le dit, et la matrice GitLab joue les deux cas.
- **`DEFAULT_BRANCH` d'un projet GitLab vide** : le champ peut être vide ou porter le défaut
  de l'instance ; la conduite §6.1 pousse sur ce que la forge annonce, sinon `GIT_BASE`, et
  `api-request` découvre ensuite la HEAD par `git_base_of` (L3) — à mesurer en live avant
  de figer (spike d'une heure, sous-lot 3).
- **Rejeu des commentaires** : `comment_upsert` remplace le commentaire du même rôle ; les
  suites qui lisaient « le dernier commentaire » (`c[-1]`) lisent désormais par marqueur.
- **Les cinq logins `x` en dur** des push (`api-request`, `api-promote-request`,
  `api-promote-export`, `team-apply`, `team-request`) sont fermés par la session voisine
  **avant** l'ouverture de ces fichiers par ce lot (fenêtre en cours le 2026-09-12).
- **Registre GitLab** : les droits (Developer pour `PUT`) et la visibilité de `ci/archives`
  pour le PAT de service sont à mesurer au sous-lot 4 ; un 404 de GET sur GitLab peut être
  un défaut de droit, la cause le dit.
