---
title: "ADR-089 — Le repli d'une application est une PR : `provision/<app>-<env>` dont la ligne `per_env.<env>` et le certificat du palier redeviennent, à l'octet, ceux du merge précédent (N-1), appliquée par la chaîne comme tout apply — même GUID, même clé. Lignée = PR mergées de la branche (forge) ordonnées par Git et bornées à la naissance du manifeste ; change_ref exigé au repli comme à la demande ; deux gardes de fenêtre (REPLI_EN_COURS, REPLI_PERIME)."
sidebar_label: "ADR-089 : le repli est une PR (A6)"
status: "Acté et prouvé le 2026-09-03 — hors ligne scripts/test-app-rollback-a6.sh 82/82 (fixture git + stub forge à journal + shim git, 5 mutations, gardes de fenêtre, câblage), make lint-ci [15/15] (18 Jenkinsfile compilent) ; suites voisines intactes (a0 176, wiring 142, a2 148, a4 133, a3 177, a5 48, pr-comment 44, a1 71, v3 35) ; par builds réels scripts/test-a6-live.sh 49/49 au 4e passage (état N-1 #154→#100, AUCUN_ETAT_PRECEDENT #15, état N #155→#101 même GUID/clé, repli #16→PR #511→#156→#102 SUCCESS gateway lue == N-1, repli du repli #17→#103, A5 en repli #18→#104 API_INACTIVE rien écrit puis rejeu SUCCESS, terminus #19 GATE_REFS_REQUIRED / #20 PALIER_ABSENT)."
maturite_technique: "✅ Script de demande de repli + formulaire Jenkins from SCM (coquille XML pure) ; aucune brique nouvelle en aval : la PR de repli est une PR provision/* comme les autres (réconciliation A2, portes A4, garde A3, rôle avec porte A5, verify). Limite structurelle : profondeur 1 (le repli du repli restaure N, jamais N-2) ; l'état restauré est l'état DÉCLARÉ par Git, pas l'état servi."
date: 2026-09-03
adr_number: 89
note: "Ferme le jalon A6 du GOAL cd-applications (2026-09-02). Port d'ADR-085 (G6 : le rollback d'une API écrit N-1 VERBATIM dans un commit NEUF sur main, puis re-applique ce commit) à l'objet dont « la PR est le fichier de déploiement » (GOAL :116) : le commit neuf est une PR. Dissout la limite « lignée du rôle épinglée au SHA » d'ADR-088 (un repli ne rejoue jamais un vieux rôle : il est appliqué à SON SHA de merge, arbre d'aujourd'hui). Consomme ADR-081 (la décision au merge), ADR-082/084 (les portes du palier s'appliquent au repli sans une ligne de code), ADR-088 (A5 tient en repli)."
lié: "[[adr-085-rollback-des-paliers]], [[adr-088-ordre-app-api]], [[adr-081-decision-au-merge]], [[adr-084-axe-qui-deploie-deployer-group]], [[adr-078-self-service-app]]"
---

# ADR-089 — Le repli d'une application est une PR (A6)

**Statut :** Acté, prouvé hors ligne 82/82 + `make lint-ci` [15/15] ; par builds réels sur le lab `scripts/test-a6-live.sh` **49/49** au 4e passage (chiffres dans le GOAL).

**Lié à :** [[adr-085-rollback-des-paliers]], [[adr-088-ordre-app-api]], [[adr-084-axe-qui-deploie-deployer-group]].

---

## Contexte

La chaîne CD des applications (GOAL 2026-09-02, A0..A5) sait promouvoir une **demande** palier par palier — une PR `provision/<app>-<env>` par palier, la décision au merge, l'apply au SHA mergé, le credential du seul palier, les portes de la chaîne, l'ordre app/API — mais **ne sait pas revenir en arrière**. Le GOAL nommait le levier prévu : « `Jenkinsfile.rollback` apprend l'objet application : re-appliquer le SHA de merge précédent de `provision/<app>-<env>` au palier », et l'aval `selfservice-app-deploy` annonçait un `MERGE_SHA` « saisi à la main sauf repli (A6) ».

Ce levier direct a trois défauts mesurés :

1. **`PALIER_SUPPLANTE`** (A2, `provision-apply-reconcile.sh`) refuse structurellement de re-projeter un état dépassé : rejouer le webhook de N-1 est refusé, et c'est juste — un repli n'est pas une exception à cette règle.
2. **La lignée du rôle** : l'aval checkoute l'arbre **entier** au `MERGE_SHA` (rôle, lib, gardes) ; re-appliquer le SHA N-1 rejouerait le rôle d'alors — la limite qu'ADR-088 avait dû écrire (« un repli vers un SHA antérieur à A5 rejoue le rôle sans porte »).
3. **Git ne dit plus la vérité** après un re-dispatch direct : `main` porte N, la gateway sert N-1, et le rejeu d'un webhook ancien défait le repli en silence.

Le spike S1 (2026-09-02, 10.15 réelle) avait établi la propriété qui fonde toute solution : la **convergence** d'une application est 0-coupure (4822/0), **GUID et clé stables** — et deux règles non négociables : la chaîne **ne désinscrit jamais** (une paire qui a servi est brûlée à la désinscription), le retrait est une **suspension**.

## Décision

### 1. Le repli est une PR, pas un SHA re-dispatché

`scripts/app-rollback-request.sh` (formulaire `ci/Jenkinsfile.app-rollback`, coquille `ci/jenkins/app-rollback.job.xml` sans propriété) ouvre une PR `provision/<app>-<env>` dont la ligne `per_env.<env>` et le certificat `certs/<app>-<env>.crt` redeviennent, **à l'octet**, ceux du merge **précédent** (N-1) de cette même branche. Puis la chaîne existante — merge (ADR-081) → `provision-apply` (portes A4 deux fois, pause nominative) → `selfservice-app-deploy` (garde A3, rôle avec porte A5, verify) — l'applique **comme tout apply**. Le verbe est la convergence idempotente : l'application garde son GUID et sa clé.

C'est le port exact d'**ADR-085** : G6 ne re-appliquait pas un vieux commit, il écrivait le contenu N-1 dans un **commit neuf** sur `main` puis re-appliquait ce commit. Ici « le fichier de déploiement du palier » est la PR (GOAL :116) — le commit neuf est une PR. Conséquences : `PALIER_SUPPLANTE` reste intact (la PR de repli est l'état le plus récent), la limite « lignée du rôle » d'ADR-088 **se dissout** (la PR de repli est appliquée à son SHA de merge, arbre d'aujourd'hui), Git redevient la vérité, et toutes les portes du palier s'appliquent **sans une ligne de code** — quatre yeux, `deployerGroup`, refs, ITSM, terminus par position, ordre app/API. Coût assumé : un merge humain — en `rec` (`selfApproval`) le demandeur merge lui-même ; en `int`+ c'est le quatre-yeux que DORA art. 17(1)(b) exige de **tout** changement, repli compris. Le levier direct (un `MERGE_SHA` de la lignée saisi sur l'aval) n'est pas retiré (propriété A2) mais **renommé** : ce n'est pas le repli, c'est un rejeu hors chaîne borné par A3.

### 2. La lignée : la forge dit les PR, Git les ordonne, la naissance du manifeste les borne

N et N-1 ne sont jamais saisis : ce sont les **PR mergées** de la branche (`GET /pulls?state=closed`, paginé ; `merged`, `head.ref` exact, `base.ref`, même dépôt — une PR mergée depuis un fork ⇒ `LIGNEE_AMBIGUE`), dont le `merge_commit_sha` est sur la **première parenté** de `main` (sinon `FORGE_INCOHERENTE` — jamais ignoré), **bornées** à la vie courante du manifeste (`BIRTH` = dernier commit de première parenté qui ajoute le fichier : un manifeste retiré puis recréé sous le même nom n'hérite pas d'une vie antérieure). Sans N ⇒ `AUCUNE_LIGNEE` ; sans N-1 ⇒ `AUCUN_ETAT_PRECEDENT` (le `NO_PREVIOUS_STATE` de G6) — remède nommé : le retrait est une suspension, pas un repli. Aucune dépendance au gabarit du sujet de merge de la forge (squash et rebase compatibles).

### 3. Ce qui est restauré, et comment on le sait

La **ligne candidate** est le mapping de N-1 à l'octet ⊕ `change_ref` (voir 4), construite **en mémoire avant tout verdict** : `ETAT_IDENTIQUE` se décide sur son digest (`app_manifest_digest_env`) contre `main` **et** le cert — jamais sur la ligne brute (cas réel : deux PR de prod qui ne diffèrent que par `change_ref`). La racine ne bouge pas (`RACINE_DIVERGENTE` si N-1 et N diffèrent hors `per_env`) ; `main` doit être l'état de N (`REFERENCE_DIVERGENTE` sinon — écriture hors flux). Après restauration dans le clone : `RESTAURATION_INFIDELE` si le digest relu ≠ le digest attendu calculé par la même lib sur une copie de N-1, `PERIMETRE_INATTENDU` si le diff sort de {manifeste, cert} ou touche plus d'une ligne du manifeste. Rien n'est poussé avant le dernier refus ; chaque étape imprime `ETAPE <nom>`.

### 4. `change_ref` exigé au repli comme à la demande ; `pv_ref` jamais

Si la porte du palier porte `requireChangeRef` ou `itsmCheck` (`env_chain_gate` ⇒ `GATE=1|…`, le prédicat de G6-D3 et de `provision-apply-gate.sh`), la demande de repli exige `CHANGE_REF` — `GATE_REFS_REQUIRED` **avant tout clone et tout appel de forge**, aucune PR ouverte. Fourni, il **remplace ou insère** `change_ref` dans la ligne restaurée (un vrai ITSM a passé le change de N-1 à « implemented » : un repli d'urgence porte **son** change) ; la ligne finale porte exactement une clé (`REF_DUPLIQUEE`, `LIGNE_AMBIGUE` : PyYAML avale une clé double en silence). `pv_ref` n'est ni exigé ni touché : le PV atteste la recette de l'état qu'on quitte, l'état restauré a porté le sien.

### 5. La PR ouverte, la branche, le bail

`EXIST` (idempotence) ne se décide jamais sur un marqueur du corps (éditable) : une PR ouverte est reprise **seulement** si son auteur est un login de service, dans le même dépôt, et si sa tête porte **exactement** le contenu qu'on allait pousser ; sinon `PR_EN_COURS`. Les PR de fork sont ignorées (le push ne les touche pas — sinon quiconque forke bloque tous les replis). La tête distante est relue : absente ou déjà mergée ⇒ **bail** `--force-with-lease=refs/heads/<b>:<tête>` ; des commits non mergés sans PR ⇒ `BRANCHE_NON_MERGEE`. Token par `GIT_ASKPASS`, jamais en URL ni argv.

### 6. Deux gardes de fenêtre

- **`REPLI_EN_COURS`** (`provision-request.sh`, amont, **avant** son push) : une demande ne réécrit jamais une PR de repli ouverte (tête de branche portant `Repli-Vers:`, relue par git, PR d'un login de service) ; le push de la demande passe en bail.
- **`REPLI_PERIME`** (`provision-apply-reconcile.sh` §4bis, aval, **conditionnel** au trailer `Repli-De:` du commit de branche `MERGE_SHA^2`) : au merge, `MERGE_SHA^1` (main juste avant) doit porter, pour ce palier, le même digest et le même cert (blob) que la référence `Repli-De` — sinon `main` a bougé entre la demande de repli et son merge, refus avant la pause. Inerte sans trailer : le réconciliateur est inchangé pour toute autre PR (A2 148/148).

### 7. La trace

Le commit de branche porte `Repli-De`, `Repli-Vers`, `Repli-Motif`, `Repli-Par` (identité informative du formulaire), `Repli-Digest`, `Change-Ref` ; le corps de la PR montre la ligne restaurée, le cert (restauré / supprimé / inchangé), le digest attendu — à comparer à la ligne « digest du manifeste effectif » du rapport de `provision-apply`. Le commit de merge et le rapport de PR sont la trace Git de l'acte ; G6 avait en plus un evidence pack et un marqueur `rolled_back` : non repris, la PR et son merge tiennent ce rôle sur cet objet. Quand N est lui-même un repli, la demande le dit (`REPLI_DU_REPLI`) et nomme le bon remède si l'apply de N a été refusé (rejouer son webhook, motif A2).

## Ce qui est prouvé

- **Hors ligne** `scripts/test-app-rollback-a6.sh` **82/82** (`make lint-ci` [15/15]) : fixture git réelle (`merge --no-ff`, ordre `rec#10 rec#11 dev#12 rec#13 dev#14`), stub forge paginé à journal, shim git ; A nominal (ligne et cert de N-1 à l'octet, diff d'une ligne, digest recalculé par la lib, trailers, corps, bail, jamais le token en argv) ; A' `change_ref` (porte avant tout clone, remplacement quoté et nu, `pv_ref` intact, le cas « ne diffère que par `change_ref` ») ; B vingt-neuf refus nommés, rien poussé ; B' `REPLI_EN_COURS` ; B'' `REPLI_PERIME` (quatre cas) ; C cinq mutations qui rougissent (préfixe de lignée, porte après la lignée, auto-vérification, `change_ref`, borne `BIRTH`) ; D câblage.
- **Par builds réels** `scripts/test-a6-live.sh` **49/49** au 4e passage — trois passages de mise au point du harnais, aucun défaut de code livré (état N-1, `AUCUN_ETAT_PRECEDENT` par build, état N, le repli — gateway lue sur l'objet : même GUID, même clé, identifiers == N-1, IP, cert ; Git ; PR —, le repli du repli, A5 en repli, le terminus).

## Limites nommées

- **État déclaré, pas servi** : la PR de repli restaure ce que la PR N-1 a mergé, même si son apply avait été refusé ; les portes rejouent. Aucun registre « appliqué » n'existe dans Git pour les applications (GOAL :116) — nommé, pas inventé.
- **Profondeur 1** : jamais N-2 ; « replier un repli mergé mais refusé à l'apply » restaure ce que la gateway sert déjà — la PR le dit, le remède est le rejeu du webhook.
- **Le cert de N reste sur la gateway après un repli vers « sans cert »** : le rôle préserve les dimensions absentes du manifeste et verify les ignore — dette du rôle ; A6 retire le fichier de Git et le dit dans la PR.
- **`REQUESTER_UNKNOWN` sur `int`+** tant qu'A7 n'ouvre pas les PR sous identité humaine : le repli en `rec` est la porte du GOAL, le terminus est prouvé jusqu'à `GATE_REFS_REQUIRED` puis `PALIER_ABSENT`.
- **La fenêtre PR de repli → merge** est tenue au merge (`REPLI_PERIME`), pas avant ; le knob de forge `block_on_outdated_branch` la fermerait pour toute PR — non posé sur le lab.
- **La branche `provision/*` n'est pas protégée** (seul `main` l'est) : d'où `EXIST` sur l'auteur et le contenu, jamais un marqueur, et le bail.
- **La suspension** (règle 2) n'est pas écrite : `isSuspended` n'existe nulle part dans le rôle — le verbe de retrait est un jalon à part.
- **Mono-gateway** : « état au SHA N-1 » se lit sur la 10.15 unique ; la contre-épreuve A5 en repli est jouée par désactivation (`API_INACTIVE`), `API_NOT_PROMOTED` ayant été prouvé par A5 sur la même porte.
- **La liste `ENV` du formulaire** est la chaîne entière (le repli est d'abord un geste de terminus) ; l'aval ne connaît que les paliers hors terminus — la porte refuse avant tout dispatch.

## Conséquences

- Un opérateur replie une application par un formulaire ; le mergeur voit **ce qui est restauré** (ligne, cert, digest, lignée) avant de décider ; l'apply est celui de tous les jours.
- A7 hérite : ouvrir les PR sous identité humaine lève `REQUESTER_UNKNOWN` sur les replis comme sur les demandes ; le terminus reçoit ses replis par le même formulaire.
- ADR-088 : la limite « lignée du rôle » est résolue (note datée dans l'ADR).
