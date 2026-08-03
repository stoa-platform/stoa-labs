---
title: "ADR-081 — Où vit la décision humaine dans la chaîne de provisioning self-service : le MERGE dans Git, pas une étape du CI. Le CI n'autorise pas, il exécute ce que Git a déjà décidé ; la demande et le plan fusionnent en un seul build pour que le demandeur n'ait qu'un endroit à regarder, et le statut de l'apply remonte sur la PR."
sidebar_label: "ADR-081 : la décision humaine vit dans le merge, pas dans le CI"
status: "Proposé — arbitrage client requis. La recommandation (décision dans Git) est motivée ci-dessous ; l'option CI-unique est décrite avec ce qu'elle coûterait, pour que le choix soit fait les yeux ouverts."
maturite_technique: "⚠️ Décision d'architecture, non prouvable par un test : elle porte sur l'ENDROIT où s'exerce une autorité humaine, pas sur un mécanisme. Ce qui est prouvé, en revanche, est ce qui en dépend : la garde d'identité du valideur (scripts/lib/assert-merge-identity.sh, 14/14) et son câblage dans provision-apply (scripts/test-provision-apply-wiring.sh, 13/13) ne prennent leur sens que si la décision reste le merge. La chaîne de provisioning elle-même est prouvée E2E (HANDOFF-PROVISIONING-CHAIN.md)."
date: 2026-08-03
adr_number: 81
note: "Précise ADR-076 (GitOps, repo-par-projet) et ADR-078 (livrable self-service) sur un point que ni l'un ni l'autre n'énonçait explicitement : la PR n'est pas une formalité de transport, elle EST l'acte d'autorisation."
---

# ADR-081 — Où vit la décision humaine : le merge dans Git, pas une étape du CI

**Statut :** Proposé — arbitrage client requis.

**Maturité technique :** ⚠️ Décision d'architecture. Elle n'est pas prouvable par un test : elle porte sur l'**endroit où s'exerce une autorité humaine**, pas sur un mécanisme. Ce qui est prouvé est ce qui en **dépend** — la garde `assert-merge-identity.sh` (14/14) et son câblage (13/13) ne signifient quelque chose que sous cette décision.

**Contexte.** La chaîne de provisioning self-service (prouvée E2E, `HANDOFF-PROVISIONING-CHAIN.md`) enchaîne trois jobs : `provisioning-request` rend un manifeste et ouvre une **Merge Request** ; `provision-plan` commente un plan en lecture seule sur la PR ; le **merge** ouvre `provision-apply`, qui met le build en pause, demande une identité Vault nominative, et applique.

Un besoin réel a été remonté : **le demandeur n'a pas de vision d'ensemble**. Il lance un job, doit aller voir une PR dans Gitea, puis un autre build ailleurs. Trois endroits pour une seule demande — mauvaise expérience, et du support en pure perte.

La proposition examinée : **un CI unique**. Le fournisseur saisit ses informations, le job crée la PR, la validation se fait dans une **étape du même run** avec les identifiants du valideur, ce qui déclenche la création. Le demandeur suit tout au même endroit.

**Lié à :** [[adr-071-partner-onboarding-as-code]], [[adr-074-vault-secrets]], [[adr-076-gitops-api-lifecycle-repo-per-project]], [[adr-077-user-identity-to-vault-token-exchange]], [[adr-078-livrable-self-service-app-wm1015]], [[adr-080-forge-git-du-lab-gitea-vs-gitlab]].

---

## Décision

**La décision humaine reste le MERGE de la Merge Request, dans Git. Le CI n'autorise rien : il exécute ce que Git a déjà décidé.**

Trois corollaires, qui traitent le besoin d'ergonomie sans déplacer l'autorité :

1. **La demande et le plan fusionnent en un seul build.** Le demandeur remplit le formulaire ; le même build crée la PR **et** affiche le plan. Deux jobs sur trois disparaissent de son parcours, sans toucher au point de décision.
2. **Le statut de l'apply remonte sur la PR.** Le plan y commente déjà ; l'apply y commente son résultat. La PR devient le tableau de bord de la demande — visible du demandeur, du valideur et de l'auditeur, au même endroit.
3. **Les quatre yeux sont imposés par la protection de branche Gitea**, pas par un job. Une garde de pipeline se contourne en déclenchant le job directement ; une protection de branche, non. La garde `assert-merge-identity.sh` reste une **défense en profondeur**, pas le contrôle principal.

## Pourquoi — les trois raisons, par ordre d'importance

### 1. Déplacer la validation dans le CI vide le merge de son sens

Si la validation est une étape du run, la PR n'a plus que deux issues, mauvaises toutes les deux :

- **le job merge lui-même** après l'`input` → la protection de branche est court-circuitée, les quatre yeux ne sont plus garantis par Git mais par un job, et le `merged_by` devient le compte de service du CI — la garde d'identité du valideur perd tout objet ;
- **la PR n'est jamais mergée** et le manifeste reste sur une branche → **Git cesse d'être la source de vérité**, ce qui contredit frontalement ADR-076.

Aujourd'hui la décision humaine est *dans* Git. La déplacer dans un build, c'est la sortir de l'artefact qui la conserve.

### 2. L'audit se dégrade

La décision est actuellement inscrite dans la forge : **qui** a mergé, **quand**, sur **quel diff exact**, avec les commentaires du plan attachés. Dans un CI unique, elle vit dans un log de build — soumis à la rotation et à la purge des anciens builds.

Pour une banque, **la PR est la pièce d'audit**. Un log Jenkins n'en est pas une : il est volatil par conception.

### 3. La concurrence — l'objection la plus concrète

`provision-apply` porte `disableConcurrentBuilds`, et c'est nécessaire : un apply à la fois. Un job unique qui attend une validation humaine **garderait ce verrou pendant des heures ou des jours** : toutes les autres demandes feraient la queue derrière un valideur absent.

Aujourd'hui seul l'apply est sérialisé, et il ne dure que le temps de l'apply. L'attente humaine, elle, se fait dans Git — où elle ne bloque personne.

S'y ajoute une fragilité : **un build en pause est un état vivant à préserver** (workspace, exécuteur, redémarrage du contrôleur). Un merge dans Git est durable et ne demande rien à personne.

## Ce que l'option CI-unique coûterait, si elle était retenue

Elle n'est pas absurde — elle est simplement plus chère qu'elle n'en a l'air. La retenir imposerait :

- de **remplacer** la garde d'identité du valideur par un contrôle des droits de réponse à l'`input`, que Jenkins exprime beaucoup plus grossièrement qu'une protection de branche ;
- de **reconstruire une piste d'audit** hors des logs de build, puisque c'est là que la décision serait consignée ;
- de **repenser la sérialisation** pour qu'une demande en attente ne bloque pas les autres — donc de renoncer à `disableConcurrentBuilds`, ou d'accepter la file ;
- d'**assumer l'écart avec ADR-076** : Git ne serait plus la source de vérité de ce qui est déployé.

## Conséquences

**Sur l'existant.** `scripts/lib/assert-merge-identity.sh` et son câblage dans `ci/jenkins/provision-apply.job.xml` sont **conditionnés par cette décision**. Sous la décision inverse, ils ne deviennent pas faux — ils deviennent **sans objet**, et le contrôle qu'ils portent doit être reconstruit ailleurs.

**Sur le travail à faire.** La fusion demande+plan et la remontée de statut sur la PR sont du travail neuf, non commencé. Elles ne changent aucune propriété de sécurité : elles déplacent de l'affichage, pas de l'autorité.

**Sur la frontière des secrets.** Cette décision est indépendante de la question « qui initialise Vault » (ADR-078 §2, voie A/B). Elle en fixe seulement le moment : l'écriture nominative a lieu **après** le merge, sous l'identité de celui qui a validé — ce qui n'est possible que si le merge existe comme événement distinct.

## Résiduel

- **Arbitrage client** : la décision est proposée, pas actée. C'est un choix d'organisation autant que d'architecture.
- **Le champ `merged_by`** de la charge utile Gitea est supposé présent et nommé ainsi ; la structure est standard mais n'a pas été observée sur un merge réel. En son absence la garde bloque en `MERGER_UNKNOWN` — échec bruyant, pas silencieux.
- **La correspondance login Gitea ↔ login d'annuaire** est supposée être l'identité. Si les deux annuaires divergent, la table de correspondance de la garde devient le maillon faible, et il faudra décider qui la tient.
