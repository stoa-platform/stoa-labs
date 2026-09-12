---
title: "ADR-098 — Un Jenkinsfile qui NOMME son déclencheur dans un bloc déclaratif exige le plugin qui le porte, avant son premier stage. Le récepteur de webhooks devient un knob, le déclencheur est posé par le build, et le XML ne porte plus rien."
sidebar_label: "ADR-098 : le récepteur de webhooks (L6)"
status: "Acté et prouvé le 2026-09-11 — spike M1..M9 mesuré au lab (une prédiction RÉFUTÉE) ; `test-webhook-kind-gitlab-live.sh` **26/26** (la chaîne entière par le GitLab Plugin) ; non-régression gwt : re-pose + amorçages relus, contre-épreuve WEBHOOK_KIND=foo ⇒ aucun déclencheur, webhook GWT réel, `test-a6-live.sh` **50/50** ; `make lint-ci` 20/20 (a0-wiring 257/257, provision-apply-wiring 148/148, setup-provision-jobs 69/69, a4 138/138)."
maturite_technique: "✅ `WEBHOOK_KIND` (gwt | gitlab) décide du récepteur ; les trois Jenkinsfile de l'aval applicatif posent déclencheur ET verrou par un `properties()` scripté, leurs XML ne portent AUCUNE propriété, et `setup-provision-jobs.sh` attend et relit l'amorçage. ⚠ RESTE BLOQUANT POUR UN CLIENT SUR FORGE PRIVÉE, hors périmètre : `provision-plan.sh` clone sans enveloppe d'authentification et ignore `GIT_CLONE_URL`."
date: 2026-09-11
adr_number: 98
note: "Lot L6 du chantier forge-agnostique (après L1, L5, L3). Déclenché par un client sur GitLab dont le Jenkins ne peut PAS recevoir le plugin generic-webhook-trigger : la chaîne app-request s'arrêtait à la MR, l'aval (provision-plan, provision-apply, selfservice-app-deploy) mourant avant son premier stage."
lié: "[[adr-090-terminus-et-identite-de-forge]], [[adr-089-repli-des-applications-par-pr]], [[adr-088-ordre-app-api]], [[adr-081-ou-vit-la-decision-humaine]], [[adr-076-gitops-api-lifecycle-repo-per-project]]"
---

# ADR-098 — Le récepteur de webhooks à deux visages (L6)

## Contexte : la chaîne s'arrête à la MR

Chez le client (GitLab CE, branche par défaut `master`), `ci-app-request`
fonctionne depuis L5/L3 : la demande ouvre la merge request
`provision/<app>-<env>`. L'aval, lui, ne peut pas être posé. `provision-plan` et
`provision-apply` déclarent leur webhook par un bloc **Declarative**
`triggers { GenericTrigger(...) }` — le plugin **generic-webhook-trigger**, que
ce Jenkins **ne peut pas recevoir**. Le job meurt avant son premier stage :
`Invalid trigger type "GenericTrigger"`. `selfservice-app-deploy` meurt de même,
mais à l'invocation, sur son `properties([pipelineTriggers([GenericTrigger(…)])])`
(`ci/Jenkinsfile.selfservice:186`) : ce hook-là n'est pourtant pas un hook de
forge (la gateway wM le sonne, `setup-provisioning-api.sh:113`) — il dépend
simplement du même plugin.

Ce Jenkins a le **GitLab Plugin** (« Build when a change is pushed to GitLab »,
URL `/project/<job>`), qui expose ce que la chaîne consomme :
`gitlabMergeRequestIid`, `gitlabSourceBranch`, `gitlabMergeRequestState`,
`gitlabMergedByUser` et — depuis la 1.7.13 — `gitlabMergeCommitSha`, la
référence A2 ([[adr-084-axe-qui-deploie-deployer-group]] pour la lignée du SHA de merge).

La question n'est donc pas « quel plugin choisir » mais « comment un même
Jenkinsfile peut-il porter deux récepteurs sans exiger les deux plugins ».

## Ce que le spike a mesuré (lab : Jenkins 2.541.3, GWT 2.4.3, 61 plugins)

| # | Mesure | Attendu | Mesuré |
|---|---|---|---|
| M1(a) | `triggers { gitlab(triggerOnPush: false) }` **déclaratif**, `gitlab-plugin` ABSENT | FAILURE au parse | ✅ **FAILURE**, `Invalid trigger type "gitlab". Valid trigger types: [upstream, cron, G…]` — aucun stage n'a tourné |
| M1(b) | le **même** symbole dans `script { if (false) { properties([pipelineTriggers([gitlab(…)])]) } }` | SUCCESS (jamais résolu) | ✅ **SUCCESS** |
| M1(c) | le même sous `if (true)` | FAILURE à l'invocation | ✅ **FAILURE**, `No such DSL method 'gitlab'` |
| M5 | `jenkins-plugin-cli --plugins gitlab-plugin` dans le conteneur + redémarrage | plugin actif, GWT intact, rien d'autre touché | ✅ `gitlab-plugin 1.2148.vf57e19a_56658` actif, `generic-webhook-trigger 2.4.3` intact, **aucun** des 61 plugins préexistants modifié ou désactivé ; 14 dépendances arrivées (61 → 75) ; `useAuthenticatedEndpoint=false` sur ce lab (un client sécurisé exigera le `secretToken`) |
| M2 | XML porteur d'un `GenericTrigger` **+** `properties([pipelineTriggers([GenericTrigger identique])])` | doublon au build 1, un seul au build 2 | ✅ à la pose `[1 GenericTrigger, 1 PipelineTriggersJobProperty]` ; après le build 1 **`[2, 2]` — DOUBLON** ; après le build 2 **`[1, 1]`** : les deux exemplaires retirés et celui du Jenkinsfile reposé. Le déclencheur du XML est **PERDU**, jamais « préservé ». Un `invoke` sur le doublon ne lance qu'**un** build (`allowSeveralTriggersPerBuild=false`) |
| M4 | XML `<properties/>` : le webhook avant / après l'amorçage | muet puis vivant | ✅ à la pose `[0 0 0 0]` ; `invoke?token` ⇒ **404 « aucun job »** ; `POST /project/<job>` (sans `GitLabPushTrigger`) ⇒ **200 SILENCIEUX, aucun build** ; amorçage ⇒ `[1 trigger, 1 option]` posés par le build ; `invoke?token` ⇒ **200 + le job**. Toute pose de XML ouvre donc une **fenêtre muette** jusqu'à la fin du premier build |
| M6 | les six événements réels d'une MR (GitLab CE 17.11), couples `(state, action)` | `merge_commit_sha` 40 hex à la fusion | ✅ `open→(opened,open)` · `push→(opened,update)` avec `oldrev` · `titre→(opened,update)` sans `oldrev` · `close→(closed,close)` · `reopen→(opened,reopen)` · `merge→(merged,merge)` avec **`merge_commit_sha` 40 hex**, égal à celui de l'API |
| M7 | table état×action → build des DEUX `gitlab(...)` de la spec, par builds réels | plan sur open/push/reopen, apply sur la fusion seule | ✅ plan : open **BUILD**, push **BUILD**, reopen **BUILD**, close —, merge — ; apply : merge **BUILD** et rien d'autre. ❌ **une prédiction réfutée** : le changement de **titre** (même SHA) **reconstruit** le plan — la garde « déjà construit » lue dans les sources ne s'applique pas. C'est la **parité** avec le GWT : le risque « comportement divergent selon le visage » TOMBE |
| M8 | les variables `gitlab*` posées dans un build | l'action n'est pas exposée | ✅ `gitlabActionType` vaut **`MERGE` même sur une ouverture** ⇒ le pipeline doit relire l'**ÉTAT** (`gitlabMergeRequestState`) ; `gitlabUserUsername` **nulle** sur un hook MR ; `gitlabMergedByUser` = l'**ACTEUR** (`root` même sur une ouverture) ; `gitlabMergeCommitSha` **nulle** (Groovy `null`, pas `""`) hors fusion |
| M9 | `X-Gitlab-Token` | fail-closed | ✅ absent ⇒ **401**, faux ⇒ **401** ; ⚠ bon token sur un corps **forgé et incomplet** ⇒ **500 sans build** (le handler du plugin ne se protège pas d'un payload qu'il ne peut pas résoudre) |

**Conséquences, et c'est la forme du lot** :

1. *(M1)*  Declarative valide ses directives
`triggers {}` à la compilation, contre les descripteurs **présents** ; un appel
scripté n'est résolu qu'à l'invocation. Le visage d'un plugin absent doit donc
être écrit en **scripté, sous un `if`** — et aucun `triggers { … }` déclaratif ne
peut subsister dans l'aval applicatif.
2. *(M2)* Garder le déclencheur dans le XML « par ceinture » ne protège de rien :
   c'est un doublon, puis une perte. Le XML de `provision-plan` et
   `provision-apply` doit donc ne porter **aucune** propriété, et le Jenkinsfile
   les poser **toutes** (déclencheur ET `disableConcurrentBuilds`).
3. *(M4)* Le déclencheur n'existe qu'après le premier build. Le poseur doit donc
   **attendre et relire** cet amorçage (`AMORCAGE_INCOMPLET` sinon) : sans cela
   il rend la main sur un job muet, et le silence du `POST /project/<job>`
   (200, aucun build) ne le dénoncerait jamais.

Preuves : `scripts/spike-webhook-kind-m1.sh` (trois jobs `spike-m1-*`, garde
fail-closed qui REFUSE si le plugin éprouvé est présent : mesurer l'inverse ne
prouve rien), `scripts/spike-webhook-kind-m5.sh` (idempotent, ne détruit pas sa
photo d'avant), `scripts/spike-webhook-kind-m2m4.sh` (deux jobs `spike-m2`,
`spike-m4`). Tous jetables : leurs jobs sont supprimés en sortie, même en échec.

4. *(M7, M8)* Le plugin **n'expose pas l'action** de la MR : le filtre
   open/merge ne peut vivre que dans les cases du déclencheur, et un état hors
   de son énumération y devient un joker. Le pipeline doit donc **relire
   l'état** (`opened` pour le plan, `merged` pour l'apply) — deux portes, jamais
   une seule, comme partout ailleurs dans cette chaîne.
5. *(M7)* La prédiction tirée des sources — « le plugin ne rejoue pas un SHA
   déjà construit, contrairement au GWT » — est **fausse**. Les deux visages
   sont à **parité** sur `update` et `reopen`. Aucun écart de comportement à
   documenter, et une limite de moins à porter au client.
6. *(M9)* Le `secretToken` est vérifié avant tout : sans lui, ou avec un mauvais,
   c'est 401. Mais un **bon** token sur un corps forgé fait **500** dans le
   handler du plugin — une raison de plus pour que la décision vive dans le
   pipeline (réconciliation, pause nominative) et jamais dans le récepteur
   ([[adr-081-ou-vit-la-decision-humaine]]).

## Décision

**Le récepteur de webhooks devient un knob, le déclencheur est posé par le
build, et le XML ne porte plus rien.**

1. **`WEBHOOK_KIND` = `gwt` | `gitlab`**, globale Jenkins, défaut `gwt`. Le knob
   nomme le **récepteur de webhooks de ce Jenkins**, pas le visage de la forge
   (`FORGE_KIND`) : un même GitLab peut être servi par l'un ou l'autre, et le
   déclencheur de `selfservice-app-deploy` — que la gateway wM sonne, pas une
   forge — dépend du même plugin. Optionnel, parce qu'absent il pose exactement
   ce que la chaîne faisait avant. Toute autre valeur ⇒ `WEBHOOK_KIND_INVALIDE`.
2. **Plus aucun bloc Declarative `triggers {}` ni `options {}`** dans l'aval
   applicatif : ils exigeraient le plugin au parse (M1). Le premier stage —
   « Contexte du webhook », sans agent, qui ne refusait rien jusqu'ici — pose
   `properties([disableConcurrentBuilds(), pipelineTriggers([<visage>])])` selon
   le knob, et **refuse avant de rien poser**.
3. **Les deux `job.xml` deviennent `<properties/>`.** Un XML porteur n'est pas
   une ceinture : c'est un doublon au build 1 et une perte au build 2 (M2).
4. **L'amorçage est attendu et relu** par `setup-provision-jobs.sh` : un job posé
   sans amorçage est muet, et son silence ne se dénonce pas (M4). La relecture
   exige **un** déclencheur de la classe qu'annonce `WEBHOOK_KIND` et **une**
   `DisableConcurrentBuildsJobProperty` — sinon `AMORCAGE_INCOMPLET`, rc 1.
5. **L'état est relu dans le pipeline.** Le plugin n'expose pas l'action (M8) et
   un état hors de son énumération devient un joker dans ses règles : le
   pipeline exige donc `opened` pour le plan, `merged` pour l'apply. Deux
   portes, jamais une seule — la doctrine de cette chaîne.
6. **Le `secretToken` est le mot du token GWT**, littéral dans le Jenkinsfile.
   C'est une sonnette, pas une autorité : la réconciliation relit la forge
   ([[adr-081-ou-vit-la-decision-humaine]]). Un vrai secret par site reste
   possible (credential + `withCredentials`) et est nommé en dette.
7. **Les défauts TRUE du plugin sont figés à false** — `ciSkip` en premier : une
   MR dont la description porte `[ci-skip]` n'aurait NI plan NI apply.
8. **Sous `gitlab`, `selfservice-app-deploy` n'a aucun hook direct** : il n'est
   atteint que par le `build job:` de `provision-apply`.

## Refus nommés

| Refus | Où | Quand |
|---|---|---|
| `WEBHOOK_KIND_INVALIDE` | les trois Jenkinsfile, **avant** `properties()` | la globale ne vaut ni `gwt` ni `gitlab` — aucun déclencheur n'est posé, et le formulaire précédent de `selfservice` reste en place |
| `AMORCAGE_INCOMPLET` | `setup-provision-jobs.sh`, après l'amorçage | build d'amorçage en échec, ou jamais fini dans `BOOTSTRAP_WAIT`, ou relecture ≠ 1 déclencheur de la classe attendue + 1 verrou (0 = job muet, 2 = le doublon, autre classe = le knob et le Jenkinsfile en désaccord) |
| `MERGE_SHA_INVALIDE` | `provision-apply-reconcile.sh` (inchangé) | le SHA arrive vide — en fast-forward ou squash, GitLab ne remplit pas `merge_commit_sha` |

## Conséquences et limites

- **Le déclencheur n'existe qu'après le premier build.** Toute re-pose de XML
  ouvre une fenêtre muette ; elle est désormais fermée par le poseur avant qu'il
  ne rende la main. Un client qui crée ses jobs à la main doit cliquer « Build
  Now » une fois : le build sort vert (« hors provision/* ») sans exécuteur.
- **En fast-forward ou squash, la chaîne refuse.** Le prérequis « merge commit »
  n'est pas une préférence : sans `merge_commit_sha`, il n'y a pas de référence
  A2 à projeter.
- **Angle mort assumé de la porte hors ligne** : aucune suite statique ne voit
  un `if` dont la condition ment (le miroir est aveugle à la conditionnalité —
  il lit le premier symbole qu'il trouve). Seule la preuve live le couvre, et
  c'est écrit dans la porte elle-même.
- **Le trou `locked` du plugin** : un état hors de son énumération devient un
  joker dans ses règles ; `triggerOpenMergeRequestOnPush: 'never'` le ferme sur
  `update` pour l'apply, et la relecture de l'état le ferme partout ailleurs.
- **Un bon token sur un corps forgé fait 500** dans le handler du plugin (M9) :
  aucun build, mais une erreur serveur plutôt qu'un refus propre. Rien à
  corriger chez nous ; à savoir en lisant les journaux d'un client.
- ✅ **Trouvé en prouvant ce lot, et FERMÉ le 2026-09-11** (hors périmètre L6,
  lot « forge privée » : `ec6ebfd`, `eb95760`, `2d9a997`) — la chaîne supposait
  **partout** une forge en lecture anonyme, et quatre gestes le montraient l'un
  après l'autre, chacun accusant autre chose : le clone du plan, la découverte du
  plan, la découverte puis le `fetch` de la réconciliation, et le `<scm>` des
  treize `job.xml` sans `credentialsId` (le checkout que Jenkins fait lui-même).
  Preuve : `test-webhook-kind-gitlab-live.sh` **28/28** contre un GitLab privé,
  `GIT_BASE` absente. Deux faits durables en sont sortis : le login de
  l'enveloppe est une **autorité unique** (`git_base_basic_login` — « x »
  convient à Gitea, jamais à GitLab), et une porte doit mesurer **chaque geste**,
  pas la présence d'un mécanisme dans un fichier (le défaut reculait d'un cran à
  chaque correctif partiel). Dette datée à cliquet : huit gestes nus dans la
  chaîne API/producteur.
- Ancienne rédaction, conservée pour la lignée du raisonnement :
  `scripts/provision-plan.sh:208` clone la plateforme **sans enveloppe
  d'authentification** et ignore `GIT_CLONE_URL` — seul de la chaîne à le faire.
  La lecture anonyme du Gitea du lab masquait ce trou ; sur une forge **privée**
  (le cas de tout client) le plan meurt `CLONE_ECHEC`. Ce n'est pas un effet du
  récepteur : c'est la marche suivante, et elle bloque un client sur GitLab
  privé. Même famille : la découverte de la branche par défaut (L3) ne
  s'authentifie pas non plus (`BRANCHE_PAR_DEFAUT_INCONNUE`) — contournable en
  posant `GIT_BASE`, ce que le refus dit lui-même.
- **Dettes nommées** : les cinq Jenkinsfile de la chaîne API (`team-apply`,
  `team-publish`, `team-promote`, `publish-api`, `provisioning-request`) portent
  encore un bloc déclaratif — même motif à rejouer avant tout client GitLab sur
  la chaîne producteur ; le `secretToken` par credential ; `FORGE_CRED_KIND`
  classé optionnel mais refusé si vide par onze pipelines.

## Preuves

| Preuve | Commande | Résultat |
|---|---|---|
| M1 — le symbole se résout au parse en déclaratif, à l'invocation en scripté | `JENKINS_UI=http://localhost:18080 bash scripts/spike-webhook-kind-m1.sh` | **3/3** (2026-09-11) |
| M5 — le lab porte les deux récepteurs | `bash scripts/spike-webhook-kind-m5.sh` | gitlab-plugin 1.2148 actif, GWT intact, 0 perdu (2026-09-11) |
| M2 + M4 — doublon puis perte ; fenêtre d'amorçage | `bash scripts/spike-webhook-kind-m2m4.sh` | **conformes** (2026-09-11) |
| M6..M9 — six événements réels, table état×action par builds, variables, token | `bash scripts/spike-webhook-kind-m6m9.sh` | table **mesurée** ; 1 prédiction réfutée (titre), corrigée dans la spec (2026-09-11) |
| **Le visage gitlab, chaîne entière par builds réels** | `JENKINS_UI=… bash scripts/test-webhook-kind-gitlab-live.sh` | **26/26** (2026-09-11) : plan sur ouverture (#1404) et sur push (#1405), apply sur la FUSION (#274) jusqu'à la pause nominative, `MERGE_SHA` == `merge_commit_sha` de l'API, MR fermée sans fusion ⇒ aucun apply, `/project/` sans token ⇒ 401, retour à `gwt` complet et `/project/` redevenu muet |
| Non-régression gwt — l'amorçage relu sur les VRAIS jobs | `GIT_HOST=… bash scripts/setup-provision-jobs.sh` | amorçages #236/#1353 SUCCESS, relecture 1 GenericTrigger + 1 verrou ; contre-épreuve `WEBHOOK_KIND=foo` ⇒ amorçage FAILURE, `WEBHOOK_KIND_INVALIDE` en console, **aucun** déclencheur posé, `AMORCAGE_INCOMPLET` |
| Non-régression gwt — la chaîne d'apply complète | `bash scripts/test-a6-live.sh` | **50/50** (2026-09-11), identique au vert du 2026-09-03 |
| Portes hors ligne | `make lint-ci` | **20/20**, rc 0 (a0-wiring 257/257 dont §3bis et §8bis, provision-apply-wiring 148/148, setup-provision-jobs 69/69, a4 138/138) |
