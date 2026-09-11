---
title: "ADR-098 — Un Jenkinsfile qui NOMME son déclencheur dans un bloc déclaratif exige le plugin qui le porte, avant son premier stage. Le récepteur de webhooks devient un knob, le déclencheur est posé par le build, et le XML ne porte plus rien."
sidebar_label: "ADR-098 : le récepteur de webhooks (L6)"
status: "BROUILLON — spike COMPLET (2026-09-11) : M1 3/3, M5, M2, M4, M6..M9 mesurés au lab ; une prédiction RÉFUTÉE (la garde « déjà construit » du plugin). Le code des visages reste à écrire."
maturite_technique: "⏳ en cours — les visages ne sont pas encore écrits ; ce document collecte les mesures qui fondent leur forme."
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

À écrire une fois le spike complet (D1..D12 de la spec
`docs/superpowers/specs/2026-09-11-webhook-kind-deux-visages-design.md`).

## Preuves

| Preuve | Commande | Résultat |
|---|---|---|
| M1 — le symbole se résout au parse en déclaratif, à l'invocation en scripté | `JENKINS_UI=http://localhost:18080 bash scripts/spike-webhook-kind-m1.sh` | **3/3** (2026-09-11) |
| M5 — le lab porte les deux récepteurs | `bash scripts/spike-webhook-kind-m5.sh` | gitlab-plugin 1.2148 actif, GWT intact, 0 perdu (2026-09-11) |
| M2 + M4 — doublon puis perte ; fenêtre d'amorçage | `bash scripts/spike-webhook-kind-m2m4.sh` | **conformes** (2026-09-11) |
| M6..M9 — six événements réels, table état×action par builds, variables, token | `bash scripts/spike-webhook-kind-m6m9.sh` | table **mesurée** ; 1 prédiction réfutée (titre), corrigée dans la spec (2026-09-11) |
