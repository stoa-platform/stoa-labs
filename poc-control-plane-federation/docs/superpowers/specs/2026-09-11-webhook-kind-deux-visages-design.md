# Le récepteur de webhooks à deux visages (`WEBHOOK_KIND`) — design

**Date** : 2026-09-11
**État** : design validé section par section, spec à relire avant plan d'implémentation
**Lot** : L6 du plan forge-agnostique (`docs/superpowers/plans/2026-09-09-forge-agnostique-debug-branche.md`)
**Périmètre** : la chaîne app-request seulement — `provision-plan`, `provision-apply`,
`selfservice-app-deploy`. Les cinq Jenkinsfile de la chaîne API qui portent le même
déclencheur (`team-apply`, `team-publish`, `team-promote`, `publish-api`,
`provisioning-request`) sont une dette nommée §12, pas dans ce périmètre.

---

## 1. Le problème

Chez le client (GitLab, branche `master`), `ci-app-request` fonctionne et ouvre la MR
`provision/<app>-<env>`. L'aval — `provision-plan` sur l'ouverture, `provision-apply`
sur la fusion — ne peut pas être posé : les deux Jenkinsfile déclarent leur webhook par
un bloc Declarative `triggers { GenericTrigger(...) }` (plugin
**generic-webhook-trigger**), et ce plugin **ne peut pas être installé** sur le Jenkins
du client. Le build meurt au parse : `Invalid trigger type "GenericTrigger"`.

Le Jenkins du client a le **GitLab Plugin** (« Build when a change is pushed to
GitLab », URL `/project/<job>`). Il expose ce que la chaîne consomme :
`gitlabMergeRequestIid`, `gitlabSourceBranch`, `gitlabMergeRequestState`,
`gitlabMergedByUser` et — depuis la 1.7.13 — `gitlabMergeCommitSha`, la référence A2.

Deux faits aggravants, découverts pendant la conception :

- `selfservice-app-deploy` est **déjà cassé** sur ce Jenkins : son
  `properties([pipelineTriggers([GenericTrigger(...)])])` (`ci/Jenkinsfile.selfservice:186`)
  s'exécute à chaque build ⇒ `No such DSL method 'GenericTrigger'`. Ce déclencheur n'est
  pas un hook de forge (il sert à la gateway wM, `setup-provisioning-api.sh:113`, et au
  `build job:` de `provision-apply`), mais il dépend du même plugin.
- Le plugin GitLab n'expose **pas** `object_attributes.action` (`gitlabActionType` vaut
  toujours `MERGE` sur un hook MR) : le filtre open/merge du GWT (`regexpFilterText`)
  n'a pas d'équivalent variable ; il se fait par les cases du trigger, et le pipeline
  relit l'**état** de la MR.

## 2. Les décisions, et qui les a prises

Toutes prises par le porteur du chantier le 2026-09-11 :

| # | Décision | Alternative écartée |
|---|---|---|
| D1 | Le déclencheur est **posé par le Jenkinsfile** dans un `properties()` scripté, selon un knob ; plus aucun bloc Declarative `triggers {}` / `options {}` | job « sonnette » par site + chaîne paramétrée (B) ; polling cron via forge-api (C) |
| D2 | **Tout scripté, XML sans aucune propriété** (`<properties/>`) — le modèle de `selfservice-app-deploy`, seule combinaison mesurée stable (fait 10, 2026-09-02) | XML seule autorité sous gwt et Jenkinsfile muet (B') |
| D3 | Le knob se nomme **`WEBHOOK_KIND`** = le récepteur de webhooks de ce Jenkins (`gwt` \| `gitlab`) | `FORGE_TRIGGER` (faux : le hook de selfservice n'est pas un hook de forge) |
| D4 | Défaut **`gwt`** (= l'état actuel, comme `FORGE_KIND` vaut `gitea`), knob OPTIONNEL, fail-closed sur toute valeur non vide inconnue | fail-closed sur vide (reproduirait la divergence `FORGE_CRED_KIND`) |
| D5 | Le `secretToken` du visage gitlab est un **littéral, le même mot que le token GWT** (`stoa-provision-plan` / `stoa-provision-apply`) — une sonnette, pas une autorité | globale Jenkins (refusée par la garde de nom `*TOKEN*`) ; credential lu par `withCredentials` (décision client, notée §12) |
| D6 | Filtre de branche du plugin **en plus** de la porte Groovy (`RegexBasedFilter`, `provision/.*`) | `All` (chaque MR du dépôt client produirait un build « hors provision/* ») |
| D7 | Le pipeline **relit l'état** (`gitlabMergeRequestState`) : plan exige `opened`, apply exige `merged` ; hors état ⇒ build vert « hors événement », stages sautés | faire confiance aux cases du trigger seules (trou `state=locked` ⇒ joker) |
| D8 | Un `gitlabMergeCommitSha` vide (fast-forward / squash) tombe dans le refus **existant** `MERGE_SHA_INVALIDE` (`scripts/provision-apply-reconcile.sh:157`) | relire le SHA sur la forge (affaiblirait `PAYLOAD_PERIME`) |
| D9 | Sous `gitlab`, `selfservice-app-deploy` ne pose **aucun** hook direct : il n'est atteint que par `build job:` | un second knob pour le hook direct |
| D10 | `setup-provision-jobs.sh` **attend et relit** l'amorçage (fail-closed), comme `setup-selfservice-job.sh` | amorçage fire-and-forget (fenêtre muette silencieuse) |
| D11 | Spike au lab **avant tout code** : les faits porteurs lus dans les sources sont mesurés (M1..M9) et entrent dans l'ADR | écrire sur la foi de la lecture |
| D12 | Le lab garde les **deux** récepteurs (`gitlab-plugin` ajouté à `ci/jenkins/Dockerfile`) pour que la preuve soit rejouable | preuve sur un Jenkins jetable, non rejouable |

## 3. Non-objectifs

- Les cinq Jenkinsfile de la chaîne API (§12).
- Le hook direct de `selfservice-app-deploy` sous un autre récepteur que GWT (la gateway
  wM sonne un JSON arbitraire, que seul GWT lit).
- Un vrai secret par site pour le `secretToken` (§12, décision client).
- La divergence `FORGE_CRED_KIND` (optionnel dans le poseur, refusé si vide par 11
  pipelines) ; l'amorçage rouge de `selfservice-app-deploy` depuis `09682b8`
  (`${MANIFEST:?}`) ; le harnais `test-selfservice-form-live.sh` périmé.
- La réconciliation A2 : inchangée, elle garde la charge de tout refus sur `MERGE_SHA`.

## 4. Ce qui est établi (lu, à ne pas re-dériver)

### 4.1 Jenkins — pourquoi la forme scriptée, et pourquoi le XML doit être vide

- **Declarative valide `triggers {}` à la compilation** contre les `TriggerDescriptor`
  présents (`pipeline-model-definition`, `ModelValidatorImpl`) ⇒ `Invalid trigger type`
  si le plugin est absent, avant tout stage. En **scripté**, `GenericTrigger(...)` et
  `gitlab(...)` sont des appels résolus à l'**invocation** (`DSL.invokeMethod`) : une
  branche `if` non exécutée n'invoque rien. Lu dans les sources, **jamais mesuré au lab**
  ⇒ mesure M1. Corollaire : `triggers { gitlab(...) }` déclaratif est impossible sur un
  site sans le plugin GitLab — le visage gitlab **doit** être scripté et sous `if`.
- **`JobPropertyStep.run()`** (workflow-multibranch) ne retire que les propriétés dont le
  descripteur est dans le `JobPropertyTrackerAction` du build précédent — ou **toutes**
  si le build précédent a joué le step sans tracker (cas d'un `POST config.xml`, qui
  efface le tracker) — puis `job.addProperty()` pour chacune, **sans dédoublonnage**.
  Conséquence mesurée au lab le 2026-09-02 (fait 10, `ci/Jenkinsfile.selfservice:158-167`,
  `ENVIRONNEMENTS.md:1099-1107`) : XML porteur d'un trigger + `properties(pipelineTriggers)`
  ⇒ **doublon** au build 1, puis au build 2 les deux exemplaires sont retirés et celui du
  Jenkinsfile reposé — le trigger XML n'est pas préservé, il est perdu ; un job re-posé
  perd ses `options{}`/`triggers{}` déclaratifs au premier build. Seule combinaison
  stable : tout dans `properties()` + XML sans aucune propriété + amorçage.
  **L'entête de `scripts/lib/gwt-mirror.sh:11` (« un `properties()` scripté le préserve
  aussi ») n'est vrai que pour un `properties()` qui ne liste pas `pipelineTriggers`** —
  à corriger.
- Le premier stage de plan et d'apply, « Contexte du webhook » (`provision-plan:148-178`,
  `provision-apply:188-218`), tourne **sans agent** et ne refuse rien ; hors
  `provision/*` il nomme le build et le laisse **vert**, les stages suivants étant sautés
  par `when { beforeAgent true; expression startsWith('provision/') }`. Un build manuel
  (aucune variable de webhook) sort donc vert sans exécuteur : c'est l'amorçage.
- `scripts/lib/gwt-mirror.sh` prend la **première** occurrence de `GenericTrigger\s*\(`
  dans la vue code (lignes `//` blanchies), équilibre les parenthèses, lit les champs par
  regex à quotes **simples** et les couples `[key: '…', value: '…']` stricts. Aveugle au
  construct englobant, à la position et à un `if` autour. Mesuré : `test-a0-wiring.sh`
  201/201 sur une copie où le bloc est déplacé dans un `properties()`. Ce qui le rougit :
  quotes doubles, GString, virgule finale dans une map, ordre inversé, un
  `GenericTrigger(` dans un `/* */` ou une chaîne avant le vrai appel.

### 4.2 Plugin GitLab (source `jenkinsci/gitlab-plugin` `f57e19a`, release 1.2148)

- URL `/project/<job>` (ou `/project/<dossier>/<job>`), routage par en-tête
  `X-Gitlab-Event` ; endpoint hors crumb. Si le job n'a pas de `GitLabPushTrigger`, le
  POST rend **200 silencieux** — même contrainte d'amorçage qu'un `properties()`.
- Sans `secretToken`, le POST exige la permission `Item.BUILD` quand
  `useAuthenticatedEndpoint` est vrai (global, **défaut TRUE**) ⇒ 403 anonyme ; avec
  `secretToken`, comparaison avec `X-Gitlab-Token`, 401 sinon.
- Le déclenchement n'exige **aucune** « GitLab connection » ; seuls `pendingBuildName` et
  les statuts en ont besoin. `addNoteOnMergeRequest` / `addCiMessage` /
  `addVoteOnMergeRequest` / `acceptMergeRequestOnSuccess` sont `transient`, false, lus
  par une migration one-shot : no-op en Pipeline.
- Défauts Java **TRUE** à figer : `triggerOnPush`, `triggerOnMergeRequest`,
  `triggerOnNoteRequest`, `ciSkip` (une MR dont la description contient `[ci-skip]`
  n'aurait ni plan ni apply), `setBuildDescription`. `triggerOpenMergeRequestOnPush`
  vaut `null` par défaut, et `null ≠ never`.
- Règles MR (reject puis accept) : `never` rejette `{opened,updated,null}×{update,null}` ;
  `triggerOnMergeRequest` accepte `{opened,reopened,null}×toute action` ;
  `triggerOnAcceptedMergeRequest` accepte `tout état×{merge}` ; un état hors enum
  (`locked`) devient `null` = **joker**. Garde « déjà construit » : sautée pour
  open/approved/merge, jouée pour reopen/update/close (même SHA + même état + même cible
  ⇒ pas de build) — le plugin **ne rejoue pas** un plan sur un simple changement de titre,
  GWT si. Sans conséquence fonctionnelle : le commentaire de plan est par SHA
  (`comment_upsert`).
- Variables d'un build MR : `gitlabMergeRequestIid`, `gitlabSourceBranch`,
  `gitlabTargetBranch`, `gitlabMergeRequestState` (`opened|closed|merged|…`),
  `gitlabMergeCommitSha` (**toujours présente, vide si null** — fast-forward/squash),
  `gitlabMergedByUser` (= `hook.user.username`, l'acteur, y compris sur open),
  `gitlabActionType` (= `MERGE` pour tout hook MR). `gitlabUserUsername` est **vide** sur
  un hook MR.
- `RegexBasedFilter(sourceBranchRegex, targetBranchRegex)` s'applique aux hooks MR
  (source = `source_branch`, **match complet**).
- Symbole `gitlab` (@Symbol) depuis 1.4.5 ; `gitlabMergeCommitSha` depuis **1.7.13**
  (2023-05-11) — prérequis client.

### 4.3 Ce que le lab a, et n'a pas

- Jenkins 2.541.3, GWT 2.4.3, **gitlab-plugin absent**, `useSecurity:false`, egress vers
  updates.jenkins.io, `jenkins-plugin-cli` présent (`ci/jenkins/Dockerfile:39` installe
  `git workflow-aggregator generic-webhook-trigger pipeline-stage-view kubernetes` sans
  pin).
- GitLab CE 17.11 : `gitlab:80` depuis Jenkins, `localhost:13080` depuis le poste,
  `allow_local_requests_from_web_hooks_and_services=true`, projet `ci/stoa-labs` id 1,
  **0 webhook** ; `setup-gitlab-lab.sh` n'en pose aucun.
- Seuls `test-a6-live.sh:220` et `test-a7-live.sh:206` sonnent
  `invoke?token=stoa-provision-apply` ; `test-a4-live.sh` passe par le hook Gitea réel ;
  `test-app-request-gitlab-live.sh` ne touche jamais Jenkins.

## 5. Le knob

| Knob | Valeurs | Défaut | Rôle |
|---|---|---|---|
| `WEBHOOK_KIND` | `gwt` \| `gitlab` | `gwt` | le **récepteur de webhooks** de ce Jenkins : le plugin qui reçoit les POST et pose les variables. `gwt` = generic-webhook-trigger (`/generic-webhook-trigger/invoke?token=`) ; `gitlab` = GitLab Plugin (`/project/<job>` + `X-Gitlab-Token`) |

- Lecture dans chaque Jenkinsfile : `WEBHOOK_KIND = "${env.WEBHOOK_KIND ?: 'gwt'}"` dans
  `environment {}` (motif des knobs de site ; `gwt` n'est ni une URL ni un identifiant de
  site, `ci/lint-config-knobs.sh` le laisse passer).
- `setup-jenkins-globals.sh` : entête (= `--help`), liste CONNUES, liste OPTIONNELLES
  (parce que le défaut existe — ne pas reproduire la divergence `FORGE_CRED_KIND`). Le
  poseur ne valide pas la valeur, la validation vit dans le Jenkinsfile.
- Refus : `REFUS: WEBHOOK_KIND_INVALIDE : '<v>' — attendu gwt|gitlab`, prononcé **avant**
  le `properties()` ⇒ aucun déclencheur posé ; le job reste muet plutôt que mal câblé.

## 6. Les deux visages, dans le premier stage

Dans le `script {}` de « Contexte du webhook », **avant** `env.PR_BRANCH = …` :

```groovy
def hook = env.WEBHOOK_KIND
if (hook == 'gwt') {
  properties([disableConcurrentBuilds(),
              pipelineTriggers([GenericTrigger( /* octet pour octet l'actuel */ )])])
} else if (hook == 'gitlab') {
  properties([disableConcurrentBuilds(),
              pipelineTriggers([gitlab( /* table ci-dessous */ )])])
} else {
  error("REFUS: WEBHOOK_KIND_INVALIDE : '${hook}' — attendu gwt|gitlab (globale Jenkins WEBHOOK_KIND)")
}
```

Contraintes de forme (portes existantes) : le corps `GenericTrigger(...)` est déplacé
**à l'identique** (quotes simples, `\\|`, maps `[key:, value:]` nues, aucune virgule
finale) — le miroir le relit ; un seul `GenericTrigger(` et un seul `gitlab(` en vue
code ; jamais `GenericTrigger(` dans un `/* */` ni dans une chaîne avant l'appel ; pas le
mot `input`, pas de `try/catch` avant `post {}` (a0-wiring `:182,:185`) ;
`disableConcurrentBuilds()` migre dans le `properties()` (le `options {}` déclaratif
disparaît, fait 10).

### 6.1 Visage `gitlab`

| Champ | provision-plan | provision-apply |
|---|---|---|
| `triggerOnMergeRequest` | **true** | false |
| `triggerOnAcceptedMergeRequest` | false | **true** |
| `triggerOpenMergeRequestOnPush` | `'source'` | `'never'` (ferme la règle « updated/null × update » sur un état `locked`) |
| `triggerOnPush`, `triggerOnNoteRequest`, `ciSkip`, `setBuildDescription`, `skipWorkInProgressMergeRequest`, `triggerOnClosedMergeRequest`, `triggerOnApprovedMergeRequest`, `triggerOnPipelineEvent`, `triggerToBranchDeleteRequest`, `cancelPendingBuildsOnUpdate`, `cancelRunningBuildsOnUpdate` | false | false |
| `branchFilterType` / `sourceBranchRegex` / `targetBranchRegex` | `'RegexBasedFilter'` / `'provision/.*'` / `'.*'` | idem |
| `secretToken` | `'stoa-provision-plan'` | `'stoa-provision-apply'` |

Non posés : `addNoteOnMergeRequest`, `addCiMessage`, `addVoteOnMergeRequest`,
`acceptMergeRequestOnSuccess` (no-op), `pendingBuildName` (exige une connexion),
`noteRegex`, `includeBranchesSpec`/`excludeBranchesSpec`.

Table attendue état × action → build (à confirmer par M7) :

- **plan** : `opened/open` BUILD ; `opened/update` BUILD si nouveau SHA, sinon rien ;
  `opened/reopen` BUILD si SHA jamais construit dans cet état ; `merged/*`, `closed/*`,
  approbations : rien.
- **apply** : `merged/merge` BUILD (nominal) ; tout le reste : rien.

### 6.2 Le troisième visage dans « Contexte du webhook »

Le fait unifié gagne un repli de plus, dans l'ordre Gitea → GWT/GitLab → plugin GitLab :

- plan : `PR_BRANCH ?: GL_SOURCE_BRANCH ?: gitlabSourceBranch` ;
  `PR_NUMBER ?: GL_IID ?: gitlabMergeRequestIid` ;
  `PR_ACTION ?: (gitlabMergeRequestState ? "merge_request:${state}" : '')` (journal). Si
  `gitlabMergeRequestState` est posé et ≠ `opened` ⇒ build nommé
  « hors événement (state=…) », vert, stages sautés (même geste que « hors provision/* »).
- apply : idem, plus `MERGE_SHA ?: GL_MERGE_SHA ?: gitlabMergeCommitSha` ; état exigé
  `merged`. SHA vide ⇒ `MERGE_SHA_INVALIDE` par la réconciliation (D8).
  `GL_USER ?: gitlabMergedByUser` → journal seulement ; la garde d'identité relit la forge.
- selfservice : `pipelineTriggers(hook == 'gwt' ? [GenericTrigger(…actuel…)] : [])`,
  même lecture et même refus du knob.

### 6.3 Le `secretToken`

Un littéral dans le Jenkinsfile, le même mot que le token GWT. C'est une sonnette : un
payload forgé finit en `FORGE_NON_CONFIRMEE` (plan) ou `PAYLOAD_PERIME` (apply) ; un
rejeu d'une MR réellement mergée n'est qu'une convergence idempotente qui bute sur la
pause nominative. Le client saisit ce mot dans le champ « Secret Token » de ses deux
webhooks. Un vrai secret par site (credential Jenkins lu par `withCredentials(string)`
avant le `properties()`) est une décision client, notée §12.

## 7. XML et poseur

- `ci/jenkins/provision-plan.job.xml` et `provision-apply.job.xml` : `<properties/>`
  (plus de `PipelineTriggersJobProperty`, plus de `DisableConcurrentBuildsJobProperty`).
  Le reste de la coquille (scm, `__GIT_BASE__`, `scriptPath`, `lightweight=false`)
  inchangé.
- `scripts/setup-provision-jobs.sh` : `BOOTSTRAP_JOBS` **attendu et relu** — après la pose,
  `POST /job/<J>/build`, attente bornée de la fin du build (360 s, motif
  `setup-selfservice-job.sh:339-375`), puis relecture de `config.xml` fail-closed :
  exactement **1** trigger de la classe attendue par `WEBHOOK_KIND` (`GenericTrigger` ou
  `GitLabPushTrigger`) et **1** `DisableConcurrentBuildsJobProperty` ; sinon refus nommé
  (`AMORCAGE_INCOMPLET`) et rc ≠ 0. Le défaut de `BOOTSTRAP_JOBS` devient
  `provision-apply provision-plan` (un job posé sans amorçage est un job muet).
- Fenêtre muette : tout `POST config.xml` tue le webhook jusqu'au build suivant (fait 10).
  Elle est désormais **fermée par le poseur** avant de rendre la main ; documentée.

Chez un client sans poseur (jobs créés à la main) : type **Pipeline**, « Pipeline script
from SCM », `Lightweight checkout` décoché, aucun trigger coché, puis « Build Now » une
fois — le build sort vert « hors provision/* » et pose le déclencheur.

## 8. La porte hors ligne (`make lint-ci`)

- `scripts/test-a0-wiring.sh`
  - §2 : `mirror_expect` plan/apply ⇒ le miroir rend `DIVERGENCE trigger xml=absent
    jenkinsfile=present` (rc 2) = **état voulu** ; le comptage `vars=7/14` est repris par
    un extracteur Jenkinsfile-seul ajouté à `gwt-mirror.sh` (`gwt_jf_vars`). Mutation :
    un XML qui reprend un `<triggers>` ⇒ rouge.
  - §8 : (a) « Jenkinsfile privé de `GenericTrigger(` ⇒ `AUCUN_TRIGGER` contre XML vide » ;
    (b)(c) sed sur le **Jenkinsfile** (plus sur le XML) ; (d)(e) inchangés.
  - `:156` : `disableConcurrentBuilds(),` **dans** `properties([`.
  - Nouveau **§3bis** (structurel) : `properties([` avant `env.PR_BRANCH =` en vue code ;
    les deux comparaisons `== 'gwt'` et `== 'gitlab'` ; `error(.REFUS: WEBHOOK_KIND_INVALIDE` ;
    exactement un `GenericTrigger(` et un `gitlab(` ; le `gitlab(` porte la table §6.1
    (plan : `triggerOnMergeRequest: true`, `triggerOnAcceptedMergeRequest: false` ; apply :
    l'inverse + `triggerOpenMergeRequestOnPush: 'never'` ; les deux : `triggerOnPush: false`,
    `triggerOnNoteRequest: false`, `ciSkip: false`, `secretToken:`) ; troisième visage
    (`gitlabSourceBranch`, `gitlabMergeRequestIid`, apply : `gitlabMergeCommitSha`).
    Mutations qui doivent rougir : inverser un `true/false`, retirer le `else error`,
    déplacer `properties([` après `env.PR_BRANCH =`, commenter `gitlab(`.
  - `EXPECTED_CHECKS` recalculé.
- `scripts/test-provision-apply-wiring.sh` `:83-84` (XML DisableConcurrentBuilds), `:88-89`
  (littéral `options { disableConcurrentBuilds() }`), `:110-117` (jumeaux XML) réécrits ;
  `EXPECTED_CHECKS` recalculé ; `scripts/test-provision-apply-a4.sh:485-489` (« 152/152 »)
  suivi.
- `scripts/test-team-publish-wiring.sh` §3ter : rc 2 attendu pour plan/apply, `MIROIR_OK`
  pour `provisioning-request` (hors périmètre, toujours déclaratif).
- `scripts/test-setup-provision-jobs.sh` : l'attente + relecture de l'amorçage (mock
  Jenkins : build qui finit, `config.xml` avec 1/0/2 triggers ⇒ vert/rouge/rouge).
- `scripts/lib/gwt-mirror.sh` : entête corrigé ; `gwt_jf_vars` ajouté ; la comparaison
  existante n'est pas touchée.
- **Angle mort assumé** : aucune suite statique ne voit un `if` cassé (le miroir est
  aveugle à la conditionnalité). Seule la preuve live M10 le couvre. Écrit dans l'ADR.

## 9. Le spike, puis les preuves live

### 9.1 Spike au lab (jetable, avant tout code) — sortie : table de l'ADR

| # | Mesure | Attendu |
|---|---|---|
| M1 | **Avant** d'installer gitlab-plugin, job jetable : (a) `triggers { gitlab(token…) }` déclaratif ; (b) `script { if (false) { properties([pipelineTriggers([gitlab(...)])]) } }` ; (c) `if (true)` | (a) FAILURE au parse `Invalid trigger type "gitlab"` ; (b) SUCCESS ; (c) `No such DSL method 'gitlab'` — le miroir exact du client sans GWT |
| M5 | `docker exec <jenkins> jenkins-plugin-cli --plugins gitlab-plugin` + restart ; `/pluginManager/api/json` | gitlab-plugin présent, GWT 2.4.3 et les autres intacts ; **attendre 10 min** (cache de parse Declarative) avant M2+ |
| M2 | Job jetable : XML porteur `GenericTrigger` token T + Jenkinsfile `properties([pipelineTriggers([GenericTrigger T])])` ; compter `PipelineTriggersJobProperty` dans `config.xml` après #1 et #2 ; POST `invoke?token=T` entre les deux | 2 après #1 (doublon), 1 après #2 ; nombre d'items de file mesuré |
| M4 | XML `<properties/>` ; POST `invoke?token` et `POST /project/<job>` **avant** la fin de l'amorçage, puis après | avant : 404 / 200 silencieux sans build ; après : 200 + build / build |
| M6 | Webhook de projet GitLab (MR events, secret) vers un job jetable `printPostContent` : jouer open, push, titre, reopen, merge, close | pour chaque : `(state, action)`, `oldrev`, `merge_commit_sha` (40 hex au merge en méthode merge commit, null en fast-forward), `user.username` |
| M7 | Deux jobs jetables avec les `gitlab(...)` de §6.1, webhook sur `/project/<job>`, rejouer les 6 événements | table §6.1 ; contre-épreuve reopen sans nouveau commit ⇒ pas de build (« already been built ») |
| M8 | `sh 'env \| grep ^gitlab'` dans un build MR | présence/valeurs de `gitlabMergeRequestIid`, `gitlabSourceBranch`, `gitlabMergeCommitSha`, `gitlabMergedByUser`, `gitlabMergeRequestState` ; absence d'une variable portant `action` |
| M9 | POST `/project/<job>` sans `X-Gitlab-Token` ; avec | 401 ; build |

Si M1 ou M6 contredisent la lecture, retour à la section 4 avant d'écrire.

### 9.2 Non-régression `gwt` (après le code)

- M10 : re-pose XML + amorçage relu ⇒ `config.xml` = 1 `GenericTrigger` + 1
  `DisableConcurrentBuildsJobProperty` ; `WEBHOOK_KIND=foo` ⇒ FAILURE nommé
  `WEBHOOK_KIND_INVALIDE` et **aucun** trigger ; retour `gwt`.
- `test-a6-live.sh` 50/50 et `test-a7-live.sh` 99/99 inchangés (les deux seuls harnais
  qui sonnent `invoke?token=stoa-provision-apply`) ; `test-a4-live.sh` (hook Gitea réel).

### 9.3 Nouveau harnais `scripts/test-webhook-kind-gitlab-live.sh`

Prérequis : `.env.gitlab-lab`, gitlab-plugin installé, globales `WEBHOOK_KIND=gitlab
FORGE_KIND=gitlab GIT_HOST=http://gitlab:80 GIT_REPO=ci/stoa-labs FORGE_CRED_KIND=secret-text`
+ credential PAT.

0. `/pluginManager` : gitlab-plugin et GWT présents.
1. Webhook de projet (`POST /api/v4/projects/1/hooks`, `url=http://jenkins:8080/project/provision-plan`
   et `/project/provision-apply`, `merge_requests_events=true`, `push_events=false`,
   `token=<mot>`) — idempotent, retiré en Z.
2. Re-pose XML + amorçage relu : 1 `GitLabPushTrigger` par job, 0 `GenericTrigger`.
3. `provision-request.sh` (réutiliser `req()` de `test-app-request-gitlab-live.sh:102-113`)
   ⇒ `jnext provision-plan` ⇒ build, commentaire de plan sur la MR par `comment_upsert`.
4. Titre modifié ⇒ **pas** de build ; push d'un commit ⇒ build.
5. Merge (méthode merge commit) ⇒ build apply jusqu'à la pause `input` ; `MERGE_SHA`
   40 hex == `GET /merge_requests/:iid` `.merge_commit_sha`.
6. Contre-épreuves : close sans merge ⇒ 0 build apply ; POST sans `X-Gitlab-Token` ⇒ 401 ;
   `WEBHOOK_KIND=gwt` re-posé ⇒ `/project/` ⇒ 200 sans build, `invoke?token` ⇒ build.
Z. MR fermée, branche et hooks supprimés, globales restaurées, XML/amorçage `gwt`
   rejoués, `test-a6-live.sh` vert.

Pièges déjà connus à intégrer : `prepared_at` asynchrone (`FORGE_PREPARE_WAIT`),
`http.postBuffer`, keepalive Jenkins, jamais éditer un bash qui tourne.

## 10. Doc, ADR, plan

- `ENVIRONNEMENTS.md` : nouvelle section `## Le récepteur de webhooks (L6 — 2026-09-11)`
  (gabarit L5/L3 : incident, une seule autorité, table Knobs, **Prérequis côté client
  GitLab** — plugin ≥ 1.7.13, webhooks « Merge request events » seulement, Secret Token =
  le mot, méthode merge commit, `/project/<job>` joignable —, la porte, dettes, au lab) ;
  correction des quatre « c'est le XML qui gagne » (`:177-179`, `:258-261`, `:611-613`,
  `:1006-1009`) ; l'amorçage « premier Build Now » raccroché au cas GitLab.
- Entêtes à réécrire : `provision-plan:77-84`, `provision-apply:86-90`,
  `gwt-mirror.sh:5-11`, `setup-provision-jobs.sh:14-16`.
- **ADR-098** `adr/adr-098-recepteur-de-webhooks-a-deux-visages.md` (gabarit ADR-097) :
  Contexte, « Ce que le spike a mesuré » (M1..M9), Décision (D1..D12), Refus nommés
  (`WEBHOOK_KIND_INVALIDE`, `AMORCAGE_INCOMPLET`), Conséquences et limites (parité
  `update` imparfaite, SHA vide en fast-forward, angle mort du miroir, trou `locked`),
  Preuves (table).
- Plan forge-agnostique : `### Task 7 (L6)`, ligne « Structure des fichiers », « Ordre et
  pourquoi » (après L5/L3, en parallèle de L2/L4), cases L1/L5/L3 cochées, `:124` corrigé.
- `ci/jenkins/Dockerfile:39` : `gitlab-plugin` ajouté (D12).

## 11. Ordre de travail et livraison

1. Spike §9.1 (M1 → M5 → M2/M4 → M6..M9) ; table dans l'ADR (brouillon).
2. Porte hors ligne §8 en TDD (rouge d'abord, mutations).
3. Code §5-§7 ; `make lint-ci` vert.
4. Preuves live §9.2 puis §9.3.
5. Doc §10 ; ADR finalisé avec les preuves.
6. Commits par lot sur `main`, poussés gitea + origin ; copie client **en bloc** après le
   vert live (règle des trois dépôts).

Chez le client, après livraison : globale `WEBHOOK_KIND=gitlab` ; 3 jobs Pipeline à la
main ; « Build Now » sur chacun ; 2 webhooks `https://<jenkins>/project/provision-plan` et
`/project/provision-apply` (Merge request events seulement, Secret Token = le mot) ;
version du plugin GitLab ≥ 1.7.13 à confirmer.

## 12. Dettes nommées (hors périmètre, à porter dans l'ADR)

- Les cinq Jenkinsfile de la chaîne API (`team-apply`, `team-publish`, `team-promote`,
  `publish-api`, `provisioning-request`) : même motif à rejouer avant tout client GitLab
  sur la chaîne producteur.
- `secretToken` : un vrai secret par site (credential + `withCredentials(string)` avant le
  `properties()`) si la sécurité du client l'exige.
- Divergence `FORGE_CRED_KIND` (optionnel dans le poseur, refusé si vide par 11 pipelines).
- Amorçage rouge de `selfservice-app-deploy` depuis `09682b8` ; `test-selfservice-form-live.sh`
  périmé.
- Trou `state=locked` du plugin GitLab (état hors enum = joker ; NPE possible dans
  `MergeRequestHookTriggerHandlerImpl` sans garde null).
- Parité `update` imparfaite entre les deux visages (GWT rejoue un plan sur tout `update`,
  le plugin seulement sur un nouveau SHA).
