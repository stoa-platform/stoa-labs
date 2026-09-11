# Forge agnostique, mode debug, branche par défaut — plan en cinq lots

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal :** qu'un client sur **GitLab**, dont la branche par défaut est **`master`**, déroule la chaîne app-request de bout en bout — et que, quand quelque chose casse, le log dise **quoi** (statut HTTP, redirection, chemin, branche, préfixe) sans qu'il faille solliciter l'auteur.

**Ce qui a déclenché ce plan (2026-09-09, CI client `ci-app-request`, GitLab) :** après `[2/4]`, `json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)` puis `REFUS: FORGE_ILLISIBLE`. Cause mesurée sur gitlab.com : la chaîne parle l'API de **Gitea** (`/api/v1/repos/…/pulls`, `Authorization: token`) ; GitLab répond à `/api/v1/…` par un **302 vers `/users/sign_in`**, `urllib` suit, reçoit du HTML, `json.load` meurt. Le client avait auparavant perdu **deux jours** sur `master` ≠ `main`, écrit en dur à 46 endroits exécutés.

**Architecture :** trois bibliothèques nouvelles, chacune autorité unique sur son sujet (patron `scripts/lib/repo-layout.sh`) — `scripts/lib/forge-api.sh` (verbes de forge normalisés, `FORGE_KIND=gitea|gitlab`, garde de réponse fail-closed et auto-diagnostique), `scripts/lib/git-base.sh` (branche par défaut : knob explicite > découverte `ls-remote --symref` > refus), `ci/lib/dbg.sh` (sortie de debug curatée, rédaction fail-closed, jamais `set -x`) — puis la chaîne app-request routée dessus, et le knob `DEBUG` câblé côté Jenkins.

**Tech Stack :** bash (`set -uo pipefail`, jamais `set -e` dans les scripts de chaîne, `set +x` partout), `python3` (urllib/json — le conteneur Jenkins n'a pas `jq`), `curl`, un **GitLab CE réel** dans le lab (`docker-compose.gitlab.yml`, port 13080) pour la preuve vivante, un stub python pour la preuve hors ligne.

**Enquêtes fondatrices :** `wf_fc859f5d-efe` (FORGE_ILLISIBLE, 4 agents) et `wf_04dc3551-4f3` (inventaire, 5 agents), 2026-09-09.

## Global Constraints

- **Aucun défaut de site dans le code livrable** (`ci/lint-config-knobs.sh`). `GIT_HOST` sans repli — `gitea-pr-confirm.sh:43` porte encore `${GIT_HOST:-http://gitea:3000}` : à retirer.
- **Aucun secret en argv, jamais `set -x`.** Le mode debug est une sortie CURATÉE sur stderr, passée par une rédaction qui masque par LITTÉRAL (le PAT de forge fait 40 hex : aucune des trois rédactions existantes — `_gc_redact`, `wm_redact_url`, `_vault_redact` — ne le reconnaît par forme). Sans python3 ⇒ `<rédaction indisponible>` et RIEN d'autre.
- **Refus nommés, en tête de message, sur stderr, AUTO-DIAGNOSTIQUES** : un refus de forge dit le statut HTTP, la redirection suivie (`Location`), le `Content-Type`, la taille et les 120 premiers octets EXPURGÉS du corps. Tags existants conservés (`FORGE_ILLISIBLE`, `FORGE_NON_CONFIRMEE`) — la distinction vit dans la PHRASE, pas dans un tag neuf (asserté par `test-app-request-a7.sh:279`, `test-repo-layout-portabilite.sh`).
- **Fail-closed.** Une réponse qui n'est pas de la forme attendue (liste attendue, objet reçu) est un REFUS — jamais « aucune PR » suivi d'un `push --force` (`provision-request.sh:707`, fail-open mesuré).
- **Une seule autorité par idée.** Interdire le littéral, jamais l'exiger : après L5, une porte de lint refuse `"token "` et `/api/v1` hors de `forge-api.sh`/`forge-identity.sh` ; après L3, elle refuse `-b main`, `origin/main`, `"base": "main"` hors de `git-base.sh`.
- **Toute épreuve rougit par mutation ou par DISCRIMINANT** (fixture au préfixe/branche/forge « autre » avec le knob pointant ailleurs ⇒ doit refuser). Un mock qui ne rend pas les vraies formes GitLab (302 sur `/api/v1`, `iid`, `username`, `opened`, `source_branch`, `diffs`, `notes`) ne prouve rien : la preuve de L5 se joue AUSSI contre le GitLab CE du lab.
- **Le compte `lint-ci` est épinglé** (`test-app-rollback-a6.sh` D.11 : `[20/20]`). Une porte neuve se câble SOUS une étape existante, sans rang, ou bump D.11 dans le même commit.
- **Faits Jenkins mesurés (test-a0-wiring.sh) :** un paramètre n'atteint le shell que par `withEnv([params…])` ; un `password` est altéré par `EnvVars.resolve` ; XML paramétré + `properties()` = HTTP 500 sur `buildWithParameters` ⇒ re-pose obligatoire ; 6 jobs sont déclenchés par webhook (pas de formulaire) ⇒ seule une GLOBALE les atteint.

---

## Structure des fichiers

| Fichier | Lot | Responsabilité |
|---|---|---|
| `scripts/provision-request.sh` | L1, L3, L5 | garde de la relecture des PR (699-716) et de la création (760-872) ; puis routage sur `forge-api.sh` |
| `scripts/test-app-request-a7.sh` | L1 | stub étendu : `body_mode` empty \| html \| redirect \| object \| echo_auth ; cas E6.6–E6.9 |
| `scripts/lib/forge-api.sh` + `scripts/lib/forge-api.py` *(créés)* | L5 | `forge_get/forge_post` gardés ; verbes `whoami`, `pr_open`, `pr_find_open_by_branch`, `pr_get`, `pr_files`, `comment_upsert`, `raw_file` ; `FORGE_KIND`, `forge_api_base` (slash final, `FORGE_API_BASE` pour un reverse-proxy) |
| `scripts/test-forge-api.sh` *(créé)* | L5 | mock à deux visages (gitea/gitlab, formes RÉELLES, 302 sur `/api/v1` côté gitlab) + mutations champ par champ |
| `scripts/test-forge-api-live.sh` *(créé)* | L5 | contre le GitLab CE du lab (13080) ET le Gitea du lab (13000) : mêmes verbes, mêmes assertions |
| `docker-compose.gitlab.yml` *(créé)* | L5 | la forge GitLab du lab, volume nommé, split-horizon `gitlab:80` / `localhost:13080` |
| `scripts/setup-gitlab-lab.sh` *(créé)* | L5 | groupe `ci`, projet miroir, PAT de service, webhook local autorisé — idempotent |
| `scripts/lib/gitea-pr-confirm.sh`, `scripts/lib/gitea-pr-comment.sh`, `scripts/provision-apply-reconcile.sh`, `scripts/app-rollback-request.sh` | L5 | routés sur `forge-api.sh` (chaîne app-request) |
| `ci/Jenkinsfile.provision-plan`, `.provision-apply` + `ci/jenkins/*.job.xml` | L5 | JSONPath du webhook remappés par `FORGE_KIND` (`$.object_attributes.iid`, `source_branch`, `merge_commit_sha`, `$.user.username`, `$.project.path_with_namespace`) |
| `scripts/lib/git-base.sh` *(créé)* | L3 | `git_base_init [url]`, `git_base_of <url>` mémoïsé ; refus `BRANCHE_PAR_DEFAUT_INCONNUE` |
| `scripts/test-git-base.sh` *(créé)* | L3 | bare HEAD→master sans knob ⇒ master ; bare vide ⇒ refus ; knob explicite ⇒ 0 `ls-remote` (shim git) |
| 10 scripts + 13 `job.xml` + 155 messages | L3 | `-b main`/`origin/main`/`"base":"main"` ⇒ `$GIT_BASE` ; XML substitués à la pose (`stage_xml`) |
| `ci/lib/dbg.sh` *(créé)* | L2 | `dbg`, `redact` (union `_vault_redact` + `Authorization: \S+ \S+` + `PRIVATE-TOKEN` + `://…@` + littéraux connus) ; `_vault_dbg/_vault_redact` y migrent |
| `scripts/test-dbg-redaction.sh` *(créé)* | L2 | sentinelles avec `/ @ espace tab` dans chaque secret, chemins nominal ET échec, `ps -Aww` sondé, python3 retiré du PATH ⇒ `<rédaction indisponible>` |
| `scripts/setup-jenkins-globals.sh` | L4a | `STOA_DEBUG` dans CONNUES et OPTIONNELLES |
| 12 Jenkinsfile à formulaire + XML | L4b | `booleanParam DEBUG` (copie de `publish-api:36/174`), pont `[ "$DEBUG" = true ] && export STOA_DEBUG=1` APRÈS `set +x`, jamais dans un `withEnv` qui porte un secret |

---

## Ordre et pourquoi

L1 (1 j) → **L5 phase 1** (2-3 j, c'est ce qui débloque le client) → L3 (2-3 j, le client est sur `master`) → L2 (2 j) → L4a (2 h) → L4b (1-2 j). L2/L4 avant L5 rendraient la panne lisible sans la fermer.

---

### Task 1 (L1) : la relecture des PR ouvertes ne meurt plus muette, et ne pousse plus en force sur un objet

**Files:**
- Modify: `scripts/provision-request.sh:699-716` (bloc `PY2`) et `:760-872` (helper `req()` du bloc `PY`)
- Modify: `scripts/test-app-request-a7.sh` (stub `_send` + `body_mode`, cas E6.6–E6.9)

- [ ] **RED** — étendre le stub : `ctl.body_mode` ∈ `empty` (200, corps vide), `html` (200 `text/html` `<!DOCTYPE html>…`), `redirect` (302 `Location: /users/sign_in` puis 200 HTML — comme gitlab.com), `object` (200 `{"message":"x"}` — le fail-open), `echo_auth` (200 HTML qui recopie l'en-tête `Authorization`). Quatre cas :
  - E6.6 `empty` ⇒ rc 2, `REFUS: FORGE_ILLISIBLE`, la phrase porte `HTTP 200`, `0 octet`, `Content-Type` ; AUCUN `Traceback` ; tête absente.
  - E6.7 `redirect` ⇒ idem, la phrase porte `302` et `/users/sign_in` — c'est la ligne que le client verra.
  - E6.8 `object` ⇒ rc 2, `REFUS: FORGE_ILLISIBLE` (« la forge a rendu un objet, une liste était attendue ») ; AUCUN push, aucun `--force`. **Avant : rc 0 et push en force.**
  - E6.9 `echo_auth` ⇒ la phrase porte `<secret masqué>` et JAMAIS `t-alice` (le token du stub).
- [ ] Vérifier RED : E6.6/E6.7 rouges sur `Traceback`, E6.8 rouge sur rc 0 + push, E6.9 rouge sur fuite.
- [ ] **GREEN** — dans `PY2` : lire `resp.read()` d'abord ; garder `resp.status`, `resp.headers.get("Content-Type")`, `resp.geturl()` ; refuser (stderr, `sys.exit(1)`) si corps vide, si non-JSON, si JSON non-liste ; la phrase : `HTTP <code> <type> <n> octets, URL finale <url expurgée>, début : <120 octets expurgés>`. Expurgation par LITTÉRAL `s.replace(tok, "<secret masqué>")` sous garde `len(tok) >= 8`. Ne PAS suivre les 3xx : `urllib.request.build_opener(NoRedirect)` et refus nommé « la forge redirige vers … : GIT_HOST doit être l'URL finale, et cette forge ne parle peut-être pas /api/v1 ». Même garde dans `req()` du bloc création (+ `timeout=30`, absent aujourd'hui).
- [ ] Le `|| fail` de la ligne 715 ne change pas de tag ; le python écrit la CAUSE sur stderr juste avant, la ligne `REFUS:` la suit.
- [ ] **Non-régression** : a7 complet, a2/a4/a6, `test-repo-layout-portabilite.sh` (R.1 attend encore `FORGE_ILLISIBLE` comme terminus — vérifier que la phrase enrichie ne casse pas son `grep`).
- [ ] Commit `fix(forge): la relecture des PR nomme ce que la forge a répondu, et refuse un objet au lieu de pousser en force`.

### Task 2 (L5) : `scripts/lib/forge-api.sh` — les verbes de forge, deux visages, une garde

**Files:**
- Create: `scripts/lib/forge-api.sh`, `scripts/lib/forge-api.py`
- Create: `scripts/test-forge-api.sh`
- Create: `scripts/setup-gitlab-lab.sh`, `scripts/test-forge-api-live.sh`

- [ ] **Contrat** (stdout `CLÉ=VALEUR`, rc 0 ; rc 2 + `REFUS: <TAG> :` sur stderr) :
  `forge whoami` → `LOGIN=` · `forge pr_open <head> <base> <titre> <fichier corps>` → `NUMBER= URL=` · `forge pr_find_open <head>` → `NUMBER= LOGIN=` ou `NUMBER=` vide · `forge pr_get <n>` → `STATE= HEAD_REF= HEAD_SHA= BASE_REF= SAME_REPO= MERGED= MERGE_SHA= MERGED_BY=` · `forge pr_files <n>` → un chemin par ligne · `forge comment_upsert <n> <marqueur> <fichier>` · `forge raw <chemin> <ref>` → contenu sur stdout.
- [ ] **Normalisation GitLab** (API v4, `PRIVATE-TOKEN` ou `Authorization: Bearer`) : projet = `GIT_REPO` URL-encodé (`ci%2Fstoa-labs`) ; `merge_requests` ; `iid`↔`number` ; `author.username`↔`user.login` ; `opened`↔`open` ; `source_branch`/`target_branch`↔`head.ref`/`base.ref` ; `sha`↔`head.sha` ; `source_project_id==target_project_id`↔`head.repo.full_name==repo` ; `merge_user.username`↔`merged_by.login` ; `/diffs`→`new_path`↔`/files`→`filename` ; `/notes`(PUT)↔`/issues/N/comments`(PATCH) ; `per_page`↔`limit` ; `raw` = `/repository/files/<chemin urlencodé>/raw?ref=`.
- [ ] **La garde** (une fonction, réutilisée par TOUS les verbes) : pas de suivi des 3xx ; refus si statut hors 2xx (avec corps expurgé), si `Content-Type` non JSON, si corps vide, si forme inattendue. Message auto-diagnostique, format de L1.
- [ ] **RED** : `test-forge-api.sh` — mock à deux visages (`FORGE_KIND` du mock indépendant de celui du client, c'est le DISCRIMINANT : `FORGE_KIND=gitea` contre un mock gitlab ⇒ refus nommé « 302 vers /users/sign_in »), chaque verbe sur chaque visage, mutation champ par champ (`iid`→`number` dans le mock gitlab ⇒ rouge, etc.).
- [ ] **GREEN**, puis **LIVE** : `setup-gitlab-lab.sh` (attend `/-/readiness`, crée le groupe `ci`, le projet, un PAT de service via `gitlab-rails runner` — le seul moyen sans UI —, autorise les webhooks locaux) ; `test-forge-api-live.sh` joue les mêmes assertions contre `localhost:13080` (gitlab) ET `localhost:13000` (gitea).
- [ ] Commit.

### Task 3 (L5) : router la chaîne app-request sur `forge-api.sh`

**Files:** `provision-request.sh` (PY2 + PY → `forge pr_find_open` / `forge pr_open`), `gitea-pr-confirm.sh` (→ `forge pr_get`, retirer le repli `gitea:3000`), `gitea-pr-comment.sh` (→ `forge comment_upsert`), `provision-apply-reconcile.sh`, `app-rollback-request.sh`, `forge-identity.sh` (`forge_login` → `forge whoami`).

- [ ] Un script à la fois, la suite de ce script verte après chaque routage (a7, a2, a4, a6, pr-comment).
- [ ] Les deux paires webhook (`provision-plan`, `provision-apply`) : JSONPath par `FORGE_KIND` ; filtre GitLab `^(open|reopen|update)$` / `^merge$`.
- [ ] Porte de lint : `"token "` et `/api/v1` INTERDITS hors des deux libs.
- [ ] **Preuve de bout en bout sur le GitLab du lab** : une demande app-request ouvre une MR, le plan la commente, l'apply la relit. C'est LE livrable du client.
- [ ] Commit.

### Task 4 (L3) : `scripts/lib/git-base.sh` — la branche par défaut, une autorité

**Files:** create `scripts/lib/git-base.sh`, `scripts/test-git-base.sh` ; modify les 10 scripts, 3 poseurs de XML, 13 XML, `setup-jenkins-globals.sh:122`.

- [x] **RED** `test-git-base.sh` : bare HEAD→`master`, aucun knob ⇒ `GIT_BASE=master` ; bare VIDE ⇒ `REFUS: BRANCHE_PAR_DEFAUT_INCONNUE` (jamais `main` deviné) ; `GIT_BASE=develop` explicite ⇒ gagne + ligne d'information si la découverte diverge ; shim `git` sur le PATH ⇒ avec knob explicite AUCUN `ls-remote` émis ; auth = même enveloppe que le clone (`GIT_CONFIG_COUNT`/askpass), la lib ne porte aucun secret.
- [x] Précédence : `GIT_BASE` non vide et ≠ `auto` > `git ls-remote --symref <url> HEAD` > refus. Sentinelle `auto` (Jenkins n'exporte pas une variable vide).
- [x] Trois familles de dépôts (plateforme, gouvernance, équipe) : `git_base_of <url>` mémoïsé par URL — un `GIT_BASE` global juste pour la plateforme peut être faux pour le dépôt d'équipe.
- [x] Les 33 sites exécutés ⇒ `"$GIT_BASE"` / `origin/$GIT_BASE` / `os.environ["GIT_BASE"]` ; les 13 XML ⇒ placeholder `*/__GIT_BASE__` substitué à la pose ; les 155 messages ⇒ interpolés (un refus qui dit « sur main » ment à un client `master`).
- [x] **Discriminant** : fixtures des suites a2/a6/a7 basculées `symbolic-ref HEAD refs/heads/master` SANS poser `GIT_BASE` ⇒ 0 rouge.
- [x] Hors lot, dette nommée : le Go de `labctl/` (46 `main` hors tests, surtout `cmd/governance-api`) et le paramètre `CARTO_PAGES_BRANCH` de `Jenkinsfile.carto` — les deux consignés dans ENVIRONNEMENTS.md § « La branche par défaut ».
- [x] **Porte** `ci/lint-branch-literals.sh` (ajout au plan, sous-lot 4c) : sous l'étape 2 de `make lint-ci`, elle refuse tout nom de branche écrit en dur dans les fichiers livrés — le littéral exécuté (A1) ET le mot `main` nu dans un message (A2). Exemptés nommés dans le fichier ; section M de mutation.
- [x] Commit (4a `d6c9515`+`2a066e5`, 4b `8964c69`+`7b6c869`, 4c ci-dessous).

### Task 5 (L2) : `ci/lib/dbg.sh` — verbeux sans fuite

**Files:** create `ci/lib/dbg.sh`, `scripts/test-dbg-redaction.sh` ; modify `ci/lib/vault-login.sh:41-77` (extraction), les scripts de la chaîne app-request (instrumentation), `provision-request.sh:752` (retirer le `grep -v "$FORGE_SECRET"` en argv).

- [x] `dbg <msg>` : stderr, préfixe `[dbg <script>]`, no-op si `STOA_DEBUG` vide/0/false, **return 0 toujours** (jamais modifier `$?`), jamais stdout (les libs rendent leur produit sur stdout).
- [x] `redact` : littéraux connus du process (`FORGE_SECRET`, `GITEA_TOKEN`, `FORGE_TOKEN`, `VAULT_USER_PASSWORD`, `WM_PASSWORD`, contenu des fichiers de token en argument, le b64 `user:secret`) + formes (`Authorization: \S+ \S+`, `PRIVATE-TOKEN: \S+`, `://[^/@]+@`, préfixes Vault `hvs.`/`hvb.`, JWT `eyJ`). Sans python3 ⇒ `<rédaction indisponible>` seul.
- [x] Instrumentation phase 1 (chaîne app-request) : autour de chaque clone/fetch/push (URL expurgée, branche, rc, stderr git expurgée) ; chaque appel de forge (`METHOD url → HTTP code (n octets)`) ; une ligne après chaque découverte (`SUB_PFX`, `REL_PATH`, `PROV_FILE` + existe ?, `GIT_BASE` + origine knob/découverte, identité, `FORGE_KIND`).
- [x] **RED** `test-dbg-redaction.sh` (gabarit D1/D2/D3 de `test-vault-user-login.sh:277-304`) : sentinelles portant `/ @ espace tab` ; absence sur stdout ET stderr des chemins nominal et d'échec ; présence d'un `HTTP <code>` (anti vert vacant) ; `ps -Aww` sondé avec contrôle positif ; mutation : retirer `redact` de `dbg` ⇒ rouge.
- [x] Commit.
- **Livré 2026-09-10/11** : la lib et sa suite sont nées avec L5 (`82f3c5d`, 108/108 — le `$?` est PRÉSERVÉ, pas remis à 0 : arbitrage C.1, en tête de `dbg.sh`) ; l'instrumentation en quatre commits sur `l2-debug-sans-fuite` — phase A, les autorités : `47f86fa` (forge-api.py écrit sa ligne HTTP avant toute cause, git-base.sh la ligne ls-remote / `GIT_BASE` / `GIT_BASE_ORIGINE`, vault-login.sh migre sur dbg.sh et ferme son `|| cat` fail-open ; forge-api 100/100, git-base 106/106, vault-login-offline 66/66) ; phase B, la chaîne : `f886542` (provision-request.sh + provision-apply-reconcile.sh ; le `grep -v "$(cat "$PUSH_TF")" | grep -v "$FORGE_SECRET"` sort de l'argv — le site était `:794`, pas `:752` ; a7 118/118, a2 226/226) et `5222377` (provision-plan.sh, gitea-pr-confirm/comment.sh, app-rollback-request.sh ×2 sites d'argv, forge-identity.sh relaie le whoami réussi ; le défaut de site `GIT_HOST` de provision-plan(-status).sh tombe ; a0-wiring 245/245, pr-comment 62/62, a6 159/159, a7 120/120) ; rebase sur `970cc10` puis `99a45f7` (deux épreuves de silence épinglent la ligne d'audit de git-base venue de L3 — a2 226/226, a6 159/159 ; git-base 111/111 après fusion de §J avec M.17/M.18). `make lint-ci` 20/20. Doc : ENVIRONNEMENTS.md § « Le mode debug sans fuite », en-tête de `dbg.sh` (« QUI PARLE PAR CETTE LIB »). Résiduels nommés dans la doc ; le knob Jenkins (case `DEBUG`, globale) reste Task 6.

### Task 6 (L4) : le knob DEBUG côté Jenkins

- [ ] **4a** `setup-jenkins-globals.sh:121,138` : `STOA_DEBUG` connue et optionnelle. Preuve : `--from-env` avec `STOA_DEBUG=1` ⇒ posée ; un build réel d'un job webhook-only ⇒ lignes `[dbg` présentes, sans ⇒ absentes.
- [ ] **4b** `booleanParam DEBUG` sur les 12 Jenkinsfile à formulaire (copie de `publish-api:36/174`) ; pont dans chaque `sh` APRÈS `set +x` : `[ "${DEBUG:-false}" = true ] && export STOA_DEBUG=1` ; `-e stoa_debug` aux `ansible-playbook`. Re-pose des jobs XML+`properties()` (fait 6) ; `test-team-request-wiring.sh:121-135` compte `string|choice` — adapter la regex des deux côtés ; EXPECTED_CHECKS des wiring à suivre.
- [ ] `ci/lint-jenkinsfiles.sh`, `make lint-ci`, `test-selfservice-form-live` (ordre des 8 params).
- [ ] Commit.

---

## Décisions prises le 2026-09-09

- GitLab : adaptateur commandé (L5 phase 1, chaîne app-request). Prérequis à obtenir du client : version, CE ou Premium, `/api/v4` joignable depuis l'agent, **PAT de service** (le couple user/mdp suffit pour `git`, pas pour `/api/v4`).
- GitLab, prérequis découvert à la relecture du routage : la **méthode de merge du projet doit être « merge commit »** — en fast-forward/squash `merge_commit_sha` est nul et A2/A6 refusent (fail-closed, nommé). Documenté dans ENVIRONNEMENTS.md § « Le visage de la forge ».
- GitLab, deux faits mesurés sur le CE du lab et absorbés par l'adaptateur/les harnais : le diff d'une MR est calculé en ASYNCHRONE (`prepared_at` nul ~4 s, `/diffs` vide ⇒ `pr_files` attend, borné `FORGE_PREPARE_WAIT`) ; un push HTTP > 1 Mio en chunked rend un 500 (`http.postBuffer` sur l'agent).
- Knob DEBUG : globale `STOA_DEBUG` **et** case `DEBUG` sur les formulaires.
- Branche : chaîne app-request **et** producteur, messages compris.
- GitLab CE **réel** dans le lab pour la preuve (l'utilisateur : « tu devrais passer sur gitlab en local pour valider tout cela »).

## Dettes nommées, non traitées ici

- GitLab CE n'a pas la protection de branche par utilisateurs/patterns (Premium) : ADR-081 « approbation = merge sous protection » à re-poser avec le client.
- `team-apply.sh` org/repo/hook (7 appels) : évitable si le client crée ses dépôts (D10).
- `forge_open_pr` prévu par la spec `2026-09-07` §8.4 doit consommer `forge-api.sh`, pas le dupliquer.
- ~60 `json.load` nus dans `setup-*/demo-*/phase3-*` : outils de lab joués devant un terminal, priorité nulle ; `assign-api-team.sh`, `repair-wm-dangling-policyaction.sh`, `seed-governance-chain.sh` sont des outils d'INCIDENT — à trancher (livrable ou « lab uniquement » en tête).
