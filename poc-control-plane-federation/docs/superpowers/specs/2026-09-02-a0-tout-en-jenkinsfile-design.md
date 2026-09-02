---
title: "A0 — Tout en Jenkinsfile : les trois jobs de l'aval applicatif sortent du XML, le formulaire app-request aussi"
type: design
status: "EN COURS 2026-09-02 — spec écrite après deux spikes de mesure sur le lab (properties() scripté dans un pipeline déclaratif)"
date: 2026-09-02
lié: [GOAL-cd-applications-2026-09-02, 2026-09-02-a2-reference-sha-merge-design, adr-082-ouverture-palier-retention-credential]
---

# A0 — Tout en Jenkinsfile

## Porte (reprise du GOAL, non négociable)

- **Porte :** `make lint-ci` compile les trois nouveaux Jenkinsfile ; les trois XML ne contiennent **aucun** `<script>` ; le miroir XML/Jenkinsfile des triggers est vérifié par le test de miroir existant (`scripts/test-team-publish-wiring.sh`), étendu aux trois jobs ; un build réel de chaque job sur la voie dev rend le **même** résultat qu'avant conversion (PR, plan commenté, apply).
- **Contre-épreuve :** un paramètre saisi `RAW>${JENKINS_HOME}<FIN` arrive **intact** au script (le fait mesuré du 2026-08-06, rejoué) ; retirer le bloc `triggers` du XML ⇒ le test de miroir rougit.
- **Les paramètres sortent aussi du XML, y compris les listes déroulantes** : `properties([parameters([…])])` posé depuis le Jenkinsfile (précédent `ci/Jenkinsfile.carto`), listes recalculées à chaque build ; limite écrite d'avance : les listes sont **rafraîchies au build précédent** (un build d'amorçage à la pose) ; l'autorité reste dans les gardes du script.

## État courant (relevé du 2026-09-02, à ne pas re-dériver)

| Pièce | Fait mesuré |
|---|---|
| `ci/jenkins/provision-plan.job.xml` | `CpsFlowDefinition`, Groovy inline : `node { git url: gitea/ci/stoa-labs main ; withCredentials(gitea-provision-token) { dir(poc) { sh 'set +x; GIT_WEB_HOST=http://localhost:13000 bash scripts/provision-plan.sh' } } }` ; trigger GWT `stoa-provision-plan`, 3 clés (`PR_BRANCH`, `PR_NUMBER`, `PR_ACTION`), filtre `^(opened\|reopened\|synchronized)$`, `printPostContent=false` ; `disableConcurrentBuilds` |
| `ci/jenkins/provisioning-request.job.xml` | `CpsFlowDefinition`, Groovy inline : `node { git … ; withCredentials(…) { dir(poc) { sh 'set +x; bash scripts/provision-request.sh' } } }` ; trigger GWT `stoa-provision-request`, 7 clés `REQ_APP/REQ_ENV/REQ_CLIENT_ID/REQ_API/REQ_API_VER/REQ_AUDIENCE/REQ_CALLER`, **sans filtre**, `printPostContent=true` ; pas de `disableConcurrentBuilds` |
| `ci/jenkins/provision-apply.job.xml` | déjà coquille from SCM (A2) — **hors périmètre de code**, dans le périmètre du miroir |
| `ci/jenkins/app-request.job.xml` | coquille from SCM **mais** 11 `<parameterDefinitions>` dont deux marqueurs `<!--CHOICES:TEAMS-->` / `<!--CHOICES:APIS-->` substitués à la pose par `setup-team-onboard-jobs.sh` (`scripts/lib/generate-choices.sh`) ; `REQ_ENV` en dur `dev/rec/int/homol` (épreuve ㉑octies de `test-palier-retention.sh` le lit par ElementTree) |
| Lab | Jenkins 2.541.3, `workflow-multibranch 821`, `pipeline-model-definition 2.2291`, `generic-webhook-trigger 2.4.2` ; hooks Gitea `ci/stoa-labs` : `stoa-provision-plan` et `stoa-provision-apply` sur `pull_request*` ; `provision-plan` #691 SUCCESS, `provisioning-request` #10 FAILURE, `app-request` #33 SUCCESS, `provision-apply` #86 (A2) |

**Faits mesurés le 2026-09-02 (job jetable `a0-spike`, supprimé), qui FONDENT le design du formulaire :**

1. `properties([parameters([…])])` appelé dans un `script{}` d'un pipeline déclaratif **pose** les paramètres sur un job dont le XML n'en déclare aucun (`params` vides avant, 4 définitions après) ; les builds suivants les **conservent** (Declarative ne retire que ce qu'il a lui-même posé).
2. Le même appel **préserve** les propriétés venues du XML et non listées : `PipelineTriggersJobProperty` (token intact) et `DisableConcurrentBuildsJobProperty` — le step est traqué (`JobPropertyTrackerAction`), il ne fait pas table rase. Corollaire : le miroir `<triggers>` XML/Jenkinsfile garde son régime (le XML gagne).
3. Un premier choix **vide** (`['']+liste`) est accepté par `choice(...)`.
4. Les paramètres posés ainsi subissent toujours `EnvVars.resolve()` : `RAW>${JENKINS_HOME}<FIN` arrive `RAW>/var/jenkins_home<FIN` par le canal natif, intact par `withEnv(["X=${params.X}"])`. La ré-injection brute reste **obligatoire**.
5. Un `POST config.xml` (re-pose) **efface** les paramètres posés par le build ⇒ un build d'amorçage est nécessaire après CHAQUE pose.
6. Un build lancé sur un job **sans** définition de paramètre lie **zéro** paramètre (`params.size()==0`, `params.APP==null`) ; après `properties()` dans le même build, `params.X` retombe sur le défaut de la définition ; `buildWithParameters` remplit les champs omis avec leur défaut (`''`, jamais null) ; `POST /build` sur un job paramétré rend **400**.

## Décisions

### D1 — `provision-plan` : Jenkinsfile déclaratif from SCM, parité stricte

`ci/Jenkinsfile.provision-plan` : `agent any` (aucune pause, le checkout implicite repose le dépôt), `options { disableConcurrentBuilds() }` (miroir du XML), `triggers { GenericTrigger(token 'stoa-provision-plan', 3 clés, `regexpFilterText '$PR_ACTION'`, `regexpFilterExpression '^(opened|reopened|synchronized)$'`, `printContributedVariables true`, `printPostContent false`) }` — **miroir exact** du XML. `environment` : `GIT_HOST`, `GIT_REPO`, `GIT_WEB_HOST` (défaut `http://localhost:13000`, la valeur que le Groovy codait en dur), `GITEA_CREDENTIALS_ID` (défaut `gitea-provision-token`). Deux stages : « Contexte du webhook » (nomme le build `plan <app>/<env> (PR #n)` ou `hors provision/* (PR #n)`) et « Plan lecture seule » gardé `when { beforeAgent true ; PR_BRANCH startsWith 'provision/' }` — une PR étrangère (onboard/*, promote/*, docs) **n'alloue aucun agent** et sort verte, exactement le résultat du Groovy (le script rendait `IGNORE … exit 0`). Le script garde sa propre garde `provision/*` : le pipeline filtre, le script refuse. Chaîne `sh` en quotes SIMPLES : `set +x; bash scripts/provision-plan.sh` sous `withCredentials([string(credentialsId: env.GITEA_CREDENTIALS_ID, variable: 'GITEA_TOKEN')])` et `dir('poc-control-plane-federation')`. Aucun `parameters {}` (valeurs du webhook seulement). Pas de `post{}` : parité (le script commente lui-même la PR ; le statut-build sous marqueur distinct est une dette hors A0, tracée).

### D2 — `provisioning-request` : idem, la voie machine reste sans un seul champ

`ci/Jenkinsfile.provisioning-request` : `agent any`, **pas** d'`options` (parité : deux demandes concurrentes visent deux branches), `triggers { GenericTrigger(token 'stoa-provision-request', 7 clés `$.app … $.caller`, **sans filtre**, `printContributedVariables true`, `printPostContent true`) }` — miroir exact. `environment` : `GIT_HOST`, `GIT_REPO`, `GITEA_CREDENTIALS_ID`. Stages : « Contexte du webhook » (`demande <app>/<env> (<caller>)`) puis « Ouvrir la demande » : `sh 'set +x; bash scripts/provision-request.sh'` sous credential et `dir`. **Aucune** liste de champs dans le pipeline — la voie machine hérite de tout enrichissement du script (argument empirique de `ci-jenkinsfile-refactor`). Pas de `withEnv` : les variables viennent du GWT, lues par le shell (parité).

### D3 — Les coquilles XML

Squelette identique à `provision-apply.job.xml` : en-tête qui explique le miroir, `<description>` mise à jour (« PIPELINE FROM SCM … ce job ne contient AUCUN Groovy »), `<properties>` = miroir des triggers (+ `DisableConcurrentBuildsJobProperty` pour `provision-plan`), `CpsScmFlowDefinition` (`http://gitea:3000/ci/stoa-labs.git`, `*/main`, `scriptPath poc-control-plane-federation/ci/Jenkinsfile.<job>`, `lightweight=false`). Zéro `<script>`, zéro `<sandbox>`.

### D4 — `app-request` : le formulaire est posé par le Jenkinsfile, les listes viennent du dépôt

- **Stage 1 « Formulaire — listes dérivées du dépôt »** (agent any, `checkout scm` implicite) : capture `env.FORM_BOOTSTRAP = (params.size() == 0) ? 'true' : 'false'` **AVANT** tout `properties()` (fait 6) ; `sh 'set +x; CHOICES_OUT="$WORKSPACE/.a0-choices.env" bash scripts/app-request-choices.sh'` sous `withCredentials(GITEA_TOKEN)` et `dir(poc)` ; relecture par `readFile` (pas de `readProperties`, plugin absent), trois listes `ENVS`/`TEAMS`/`APIS` (`tokenize(' ')`) ; **fail-closed** (`FORMULAIRE_VIDE` si une liste est vide — double du refus du script) ; puis `properties([parameters([ … 11 paramètres … ])])` avec `choice(REQ_ENV, envs)`, `choice(TEAM, [''] + teams)`, `choice(API, apis)`, `choice(MODE, ['idp','internal'])`, `choice(CERT_ROTATION, ['replace','overlap'])`, `string` (APP, CLIENT_ID, BACKEND_KEY_REF, BACKEND_KEY_FIELD), `text` (IP_ALLOWLIST, CERT_PEM) — descriptions reprises **verbatim** du XML. Le build d'amorçage prend le nom `amorçage du formulaire (aucune demande)` et sort vert sans rien demander.
- **Stages 2 et 3** (contexte, ouverture de la PR) : inchangés, gardés `when { expression { env.FORM_BOOTSTRAP != 'true' } }`. Une saisie humaine `APP` vide reste refusée par `provision-request.sh` (`REQ_APP:?`, build rouge) : **aucun changement de sémantique pour l'humain**, le seul build vert sans demande est l'amorçage, et il se nomme.
- **`scripts/app-request-choices.sh`** (nouveau, moteur, testable hors ligne) : `ENVS` = `env_chain_nonprod` (`scripts/lib/env-chain.sh`, source `clients/_example/environments.yaml` du clone — la même que `provision-request.sh`, qui refuse `ENV_INVALIDE`) ; `TEAMS`/`APIS` = `generate_choices_teams_raw`/`generate_choices_apis_raw` (D5) sur **Gitea main** (même contrat fail-closed que le poseur, `CHOICES_SKIPPED_REPOS` propagé sur stderr), env scellé sur `DEPLOY_PIN_AUTHORING_ENV` (`scripts/lib/deploy-pin.sh`, G4/ADR-082). Sortie : fichier `CHOICES_OUT` de trois lignes `ENVS=…`/`TEAMS=…`/`APIS=…` (valeurs séparées par un espace — les noms sont garantis sans espace par les gardes amont), écrit **seulement** sur succès ; rc 1 sinon, nommé.
- `ci/jenkins/app-request.job.xml` : coquille pure — aucun `<parameterDefinitions>`, aucun marqueur, `<triggers/>` vide (miroir : le Jenkinsfile ne déclare aucun déclencheur). L'en-tête explique l'inversion (le XML ne fait plus autorité sur rien).
- **Autorité** : les listes sont de l'ergonomie. Un choix périmé meurt fermé dans le script (`ENV_INVALIDE`, `TEAM_NOT_DECLARED`, `REQ_API:?`/`API_FORMAT_INVALIDE`) ; un `buildWithParameters` par API peut soumettre n'importe quelle valeur, comme avant.
- **Limite écrite d'avance** : listes rafraîchies au build **précédent** ; après un onboarding, la re-pose de `team-apply.sh` (`setup-team-onboard-jobs.sh JOBS="app-request api-request"`) re-pose la coquille et déclenche l'amorçage (D6) ⇒ la nouvelle équipe apparaît dès la fin de ce build.

### D5 — `generate-choices.sh` : variantes brutes, wrappers XML inchangés

`generate_choices_teams_raw <env>` / `generate_choices_apis_raw <env>` rendent une valeur **par ligne**, non échappée ; les fonctions existantes deviennent des wrappers (`printf '<string>%s</string>'` + `_gc_escape`) à sortie **identique** — `test-generate-choices.sh` doit rester vert sans modification. Le marqueur `CHOICES_SKIPPED_REPOS=<n>` reste émis par la variante brute des APIs (donc par le wrapper).

### D6 — La pose : `BOOTSTRAP_JOBS`, et deux mécanismes qui coexistent

- `scripts/setup-provision-jobs.sh` : knob `BOOTSTRAP_JOBS` (liste de noms) — après une pose **réussie** d'un job listé, `POST /job/<j>/build` (crumb, `jcurl`) attendu **201** (« build d'amorçage déclenché ») ; 400 = « job déjà paramétré — amorçage sans pose » ⇒ avertissement + RC=1 (bruyant, jamais silencieux) ; `DRY_RUN` l'annonce. Fire-and-forget : aucune attente (le build a besoin d'un exécuteur, `team-apply.sh` l'appelle depuis un nœud). En-tête corrigé : plus aucun job en Groovy inline.
- `scripts/setup-team-onboard-jobs.sh` : passe `BOOTSTRAP_JOBS=app-request` (si présent dans `JOBS`) au délégué ; `app-request` n'a plus de marqueur ⇒ copié **tel quel** (garantie NO-OP existante), `GITEA_TOKEN` n'est plus requis pour lui. `api-request` (chaîne API, hors périmètre) garde ses marqueurs : les deux mécanismes coexistent, dit dans les en-têtes.
- `team-apply.sh` / `team-publish.sh` : code inchangé ; commentaire ajusté (le rafraîchissement d'`app-request` = re-pose + amorçage).

### D7 — Le miroir devient une lib, appliquée aux trois jobs

`scripts/lib/gwt-mirror.sh` : `gwt_mirror_diff <xml> <jenkinsfile>` extrait du XML (ElementTree) le `GenericTrigger` — token, `regexpFilterText`, `regexpFilterExpression`, `printPostContent`, `printContributedVariables`, l'ensemble des couples `(key, value)` — et du Jenkinsfile (vue code, commentaires blanchis) le bloc `GenericTrigger(...)` par regex ; compare champ à champ ; imprime `MIROIR_OK` ou des lignes `DIVERGENCE <champ> xml=<…> jenkinsfile=<…>`, rc 1 sur divergence, rc 2 si l'un des deux n'a pas de trigger alors que l'autre en a un, rc 0 « aucun trigger des deux côtés » (cas `app-request`). Utilisée : (a) dans `test-a0-wiring.sh` sur les **trois** jobs (`provision-apply`, `provision-plan`, `provisioning-request`) + `app-request` (absence des deux côtés) ; (b) dans `test-team-publish-wiring.sh` (§3ter, trois contrôles) — la porte du GOAL nomme ce fichier. Contre-épreuve intégrée : le XML privé de son bloc `<triggers>` (copie mutée) ⇒ rc 2 ; une valeur altérée ⇒ rc 1.

### D8 — Les épreuves

- **Nouveau** `scripts/test-a0-wiring.sh` (hors ligne, total attendu écrit en dur) : §1 coquilles (les 4 XML : `CpsScmFlowDefinition`, `scriptPath`, `lightweight=false`, **zéro** `<script>`/`CpsFlowDefinition`/`<sandbox>`, XML parsable) ; §2 miroir (lib, 3 jobs + app-request sans trigger) ; §3 `Jenkinsfile.provision-plan` (déclaratif, `disableConcurrentBuilds`, garde `provision/*` `beforeAgent`, `sh` en quotes simples, script invoqué sous `dir` + credential, `GIT_WEB_HOST` défaut `localhost:13000`, aucun `git url:`, aucun `parameters {`) ; §4 `Jenkinsfile.provisioning-request` (idem, sans options, sans filtre, `printPostContent: true`, aucun champ listé, aucun `withEnv`) ; §5 `app-request` : XML sans paramètre ni marqueur, Jenkinsfile : `FORM_BOOTSTRAP` capturé **avant** `properties(` (ordre par numéros de ligne), `properties([parameters([` en vue code, les 11 noms avec leur type, `choices: envs`/`[''] + teams`/`choices: apis`, aucune liste de paliers littérale, `readFile` du fichier de choix, `when` sur les deux stages suivants, ré-injection brute des 10 champs conservée, `bash scripts/app-request-choices.sh` sous credential ; §6 `app-request-choices.sh` **fonctionnel hors ligne** (bare repos locaux, `STOA_ENV_CHAIN_FILE`) : trois lignes attendues, `TEAMS` sans doublon, marqueur `CHOICES_SKIPPED_REPOS` sur stderr ; mutations : providers vide ⇒ rc≠0 et **aucun** fichier écrit ; chaîne illisible ⇒ rc≠0 ; §7 pose : `BOOTSTRAP_JOBS` câblé (`setup-team-onboard-jobs.sh` → `setup-provision-jobs.sh` → `POST /job/<j>/build`), plus de substitution possible pour `app-request` (aucun marqueur) ; §8 mutations du miroir (D7) ; §9 lint : les nouveaux Jenkinsfile sont dans `ci/` (donc compilés par `lint-jenkinsfiles.sh`), les nouveaux shells shellcheckés ; §10 total.
- **Réalignés** : `test-app-request-wiring.sh` (§3 inversé : paramètres HORS du XML, posés par le Jenkinsfile), `test-app-request-v2.sh` §B et `test-app-request-v3.sh` §B1/B3 (le XML posé est **identique** à la source, l'amorçage est déclenché, les classes de paramètre se lisent dans le Jenkinsfile : `text(name: 'IP_ALLOWLIST'`), `test-generate-choices.sh` §9 (faux Jenkins accepte `/build`), `test-palier-retention.sh` ㉑octies (la liste `REQ_ENV` n'est plus dans le XML : elle est dérivée de `env_chain_nonprod` par `app-request-choices.sh`, et le Jenkinsfile ne porte aucune liste littérale — quatre contrôles conservés), `test-setup-provision-jobs.sh` (section `BOOTSTRAP_JOBS` : POST build après pose, jamais en DRY_RUN, jamais sans demande, 400 ⇒ RC=1).
- `make lint-ci` : [11/11] `test-a0-wiring.sh` ; shellcheck étendu à `scripts/app-request-choices.sh`, `scripts/lib/gwt-mirror.sh`, `scripts/lib/generate-choices.sh` (deux SC2181 à corriger au passage).

### D9 — La preuve par builds réels : `scripts/test-a0-live.sh`

Fail-closed, jamais de skip muet (`LAB_ABSENT`/`PREREQUIS`). Entrées : `JENKINS_UI`, `GITEA_URL` ; token `ci` minté via `docker exec poc-gitea` (ou `GITEA_TOKEN_FILE`). Séquence :
1. **Pose** : `JOBS="provision-plan provisioning-request" setup-provision-jobs.sh` ; `JOBS=app-request setup-team-onboard-jobs.sh` (amorçage inclus) ; attendre le build d'amorçage `SUCCESS` ; relire la config des 4 jobs : `CpsScmFlowDefinition`, aucun `<script>` ; `app-request` : 11 paramètres, `REQ_ENV` == `env_chain_nonprod`, `TEAM` = `''` + équipes de `providers.dev.yml`, `API` non vide.
2. **Porte voie machine** : `POST generic-webhook-trigger/invoke?token=stoa-provision-request` body `{app:a0m<ts>, env:dev, clientId, api, apiVersion, audience, caller:oig-provisioner}` ⇒ `provisioning-request` #N SUCCESS, PR `provision/a0m<ts>-dev` ouverte, puis `provision-plan` déclenché par le hook Gitea ⇒ commentaire de plan sur la PR (✅) — **même résultat qu'avant conversion**.
3. **Porte voie humaine** : `buildWithParameters` sur `app-request` (`APP=a0h<ts>`, `REQ_ENV=dev`, `API=<premier choix relu>`, `MODE=internal`) ⇒ SUCCESS, PR ouverte, plan commenté.
4. **Contre-épreuve** : `buildWithParameters` avec `IP_ALLOWLIST=RAW>${JENKINS_HOME}<FIN` ⇒ FAILURE, la console porte le libellé **littéral** dans le refus `IP_ALLOWLIST_INVALID` (et jamais `/var/jenkins_home`), aucune branche `provision/a0r<ts>-dev`.
5. **Nettoyage** : PR fermées, branches supprimées (rien n'a atteint `main`).
`provision-apply` n'est pas re-joué : A0 ne le touche pas, son build réel est celui d'A2 (#84, le même jour).

## Ce que A0 ne fait pas

- Ne convertit pas `api-request` ni `selfservice-app-deploy` (liste `ENVIRONMENT` en dur de `Jenkinsfile.selfservice:44`) : A4 les prend (« les deux listes en dur tombent par le mécanisme d'A0 »).
- N'ajoute pas de `post{always}` statut-build à `provision-plan`/`provisioning-request` (parité stricte ; dette nommée).
- Ne change ni `provision-request.sh`, ni `provision-plan.sh`, ni le rôle.

## Rollout (ordre)

`git push gitea HEAD:main` → `JOBS="provision-plan provisioning-request" bash scripts/setup-provision-jobs.sh` → `JOBS=app-request bash scripts/setup-team-onboard-jobs.sh` (pose + amorçage) → vérifier `GET /job/app-request/api/json?tree=property[parameterDefinitions[name]]`. Sur un Jenkins où `app-request` n'a pas encore été amorcé, le bouton « Build » (sans paramètre) **est** l'amorçage : le formulaire apparaît au build suivant.
