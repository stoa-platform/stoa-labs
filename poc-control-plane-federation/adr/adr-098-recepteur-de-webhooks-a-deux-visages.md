---
title: "ADR-098 — Un Jenkinsfile qui NOMME son déclencheur dans un bloc déclaratif exige le plugin qui le porte, avant son premier stage. Le récepteur de webhooks devient un knob, le déclencheur est posé par le build, et le XML ne porte plus rien."
sidebar_label: "ADR-098 : le récepteur de webhooks (L6)"
status: "BROUILLON — spike en cours (2026-09-11). M1 mesuré 3/3."
maturite_technique: "⏳ en cours — les visages ne sont pas encore écrits ; ce document collecte les mesures qui fondent leur forme."
date: 2026-09-11
adr_number: 98
note: "Lot L6 du chantier forge-agnostique (après L1, L5, L3). Déclenché par un client sur GitLab dont le Jenkins ne peut PAS recevoir le plugin generic-webhook-trigger : la chaîne app-request s'arrêtait à la MR, l'aval (provision-plan, provision-apply, selfservice-app-deploy) mourant avant son premier stage."
lié: "[[adr-090-terminus-et-identite-de-forge]], [[adr-089-repli-application-par-pr]], [[adr-088-ordre-app-api]], [[adr-081-webhook-sonnette-jamais-autorite]], [[adr-076-gitops-api-lifecycle-repo-per-project]]"
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
référence A2 ([[adr-084-axe-qui-deploie]] pour la lignée du SHA de merge).

La question n'est donc pas « quel plugin choisir » mais « comment un même
Jenkinsfile peut-il porter deux récepteurs sans exiger les deux plugins ».

## Ce que le spike a mesuré (lab : Jenkins 2.541.3, GWT 2.4.3, 61 plugins)

| # | Mesure | Attendu | Mesuré |
|---|---|---|---|
| M1(a) | `triggers { gitlab(triggerOnPush: false) }` **déclaratif**, `gitlab-plugin` ABSENT | FAILURE au parse | ✅ **FAILURE**, `Invalid trigger type "gitlab". Valid trigger types: [upstream, cron, G…]` — aucun stage n'a tourné |
| M1(b) | le **même** symbole dans `script { if (false) { properties([pipelineTriggers([gitlab(…)])]) } }` | SUCCESS (jamais résolu) | ✅ **SUCCESS** |
| M1(c) | le même sous `if (true)` | FAILURE à l'invocation | ✅ **FAILURE**, `No such DSL method 'gitlab'` |

**Conséquence, et c'est la forme du lot** : Declarative valide ses directives
`triggers {}` à la compilation, contre les descripteurs **présents** ; un appel
scripté n'est résolu qu'à l'invocation. Le visage d'un plugin absent doit donc
être écrit en **scripté, sous un `if`** — et aucun `triggers { … }` déclaratif ne
peut subsister dans l'aval applicatif. Preuve : `scripts/spike-webhook-kind-m1.sh`
(jetable, trois jobs `spike-m1-*` supprimés en sortie, garde fail-closed qui
REFUSE si le plugin éprouvé est présent : mesurer l'inverse ne prouve rien).

<!-- M5, M2, M4 (installation du plugin au lab, doublon XML+properties(),
     fenêtre d'amorçage) et M6..M9 (payloads réels GitLab CE 17.11, table
     état×action, variables gitlab*, X-Gitlab-Token) s'ajoutent ici. -->

## Décision

À écrire une fois le spike complet (D1..D12 de la spec
`docs/superpowers/specs/2026-09-11-webhook-kind-deux-visages-design.md`).

## Preuves

| Preuve | Commande | Résultat |
|---|---|---|
| M1 — le symbole se résout au parse en déclaratif, à l'invocation en scripté | `JENKINS_UI=http://localhost:18080 bash scripts/spike-webhook-kind-m1.sh` | **3/3** (2026-09-11) |
