---
title: "ADR-098 — Un Jenkinsfile qui NOMME son déclencheur dans un bloc déclaratif exige le plugin qui le porte, avant son premier stage. Le récepteur de webhooks devient un knob, le déclencheur est posé par le build, et le XML ne porte plus rien."
sidebar_label: "ADR-098 : le récepteur de webhooks (L6)"
status: "Acté et prouvé le 2026-09-11 (phase 1), étendu à `team-apply` le 2026-09-12 (phase 2) — spike M1..M9 mesuré au lab (une prédiction RÉFUTÉE) ; `test-webhook-kind-gitlab-live.sh` (la chaîne entière par le GitLab Plugin) ; non-régression gwt : re-pose + amorçages relus, contre-épreuve WEBHOOK_KIND=foo ⇒ aucun déclencheur, webhook GWT réel, `test-a6-live.sh` **50/50**. Phase 2 : `test-team-apply-wiring.sh` **95/95**, deux défauts BLOQUANTS trouvés par relecture adverse AVANT tout build (lib bash sourcée dans un bloc `sh` = dash ; PR relue non reliée à l'objet appliqué) et fermés avec leurs portes."
maturite_technique: "✅ `WEBHOOK_KIND` (gwt | gitlab) décide du récepteur ; les **six** Jenkinsfile convertis (`provision-plan`, `provision-apply`, `selfservice-app-deploy` en phase 1, puis `team-apply`, `team-publish` et `team-promote` en phase 2 le 2026-09-12) posent déclencheur ET verrou par un `properties()` scripté, leurs XML ne portent AUCUNE propriété, et `setup-provision-jobs.sh` DÉDUIT du XML l'amorçage à imposer, l'attend et le relit. Les identités de `team-apply` sont RELUES sur la forge (`forge-merge-identity.sh`, `PAYLOAD_PERIME` sur les trois faits de la PR) — jamais prises dans le payload. ⚠ Reste à convertir (hors chaîne producteur) : `publish-api`, `provisioning-request`."
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
| `FORGE_IDENTITES_ILLISIBLES` | `forge-merge-identity.sh`, avant la garde | la forge ne répond pas : on ne se rabat **pas** sur le payload pour nourrir les quatre yeux |
| `PAYLOAD_PERIME` | `forge-merge-identity.sh`, après la relecture | la PR relue (`merged`, `merge_commit_sha`, `head.ref`) n'est pas celle qu'on s'apprête à appliquer |
| `REQUESTER_UNKNOWN` | `assert-merge-identity.sh` | demandeur absent — le quatre-yeux ne se **saute** plus, il refuse |

## Le récepteur n'est qu'une MOITIÉ (corrigé par mesure le 2026-09-12)

Écrit d'abord ainsi : convertir le récepteur ne rend pas le CORPS du job
forge-agnostique, et les sept scripts de la chaîne producteur composaient encore
`${GIT_HOST}/api/v1` en dur. **C'était vrai le matin, ce ne l'est plus.** Mesuré
sur `main` après le sous-lot 2 de L5 phase 2 : la liste `EN_ROUTAGE` de
`ci/lint-forge-literals.sh` est **VIDE**, et les seules occurrences de `/api/v1`
restant dans ces sept scripts sont des commentaires qui disent que le script ne
la compose plus. Les deux moitiés sont donc là.

Ce qui reste, et qu'il ne faut pas confondre avec « ça marche » :
- **l'aboutissement sur un GitLab réel n'est pas prouvé** — c'est la preuve live
  de L5 phase 2 (Task 15), pas un vert de porte hors ligne ;
- `scripts/lib/archive-store.sh` (seconde autorité ÉTROITE, transport binaire
  des paquets) ne parle encore qu'un visage ;
- les outils de poste **EXEMPTS nommément** (`setup-*`, `seed-governance-chain`)
  restent Gitea-seulement, par décision, avec leur raison écrite dans la porte.

La leçon de forme, elle, tient quoi qu'il arrive : **le vert d'une suite de
câblage dit que le job est joignable et que sa garde est juste, jamais que la
chaîne aboutit.** Et une affirmation de dette se relit par la mesure avant d'être
répétée — celle-ci a vécu une demi-journée.

## Ce que la relecture adverse a trouvé (2026-09-12, avant tout build)

Deux défauts **bloquants** dans la transformation de `team-apply`, tous deux
invisibles à une porte de littéraux — d'où deux portes de plus.

1. **La relecture de forge était écrite dans le bloc `sh`, donc en dash.**
   `. scripts/lib/forge-api.sh` PARSE côté Groovy (la porte de compilation était
   verte) et ne s'exécute pas : la lib est du bash, et `dash -n` la refuse
   (« 111: Syntax error: redirection unexpected »). Le step mourait sur deux
   messages de dash ne nommant aucun refus du dépôt, **après** avoir réveillé un
   humain et encaissé son mot de passe d'annuaire — sur les deux visages, Gitea
   comprise, qui marchait avant ce lot. Remède : `scripts/forge-merge-identity.sh`
   (bash, ses propres refus nommés), appelé `sh 'set +x; bash scripts/…'`. Porte :
   `ci/lint-jenkinsfiles.sh` joue `dash -n` sur **toute** lib sourcée dans un
   bloc `sh` de `ci/Jenkinsfile*` (portée dérivée), prouvée par deux mutations.
2. **Rien ne reliait la PR relue à l'objet appliqué.** `pr_get $PR_NUMBER` ne
   servait qu'aux deux identités, alors que `PR_NUMBER` est un fait du payload et
   que l'objet appliqué vient de `PR_BRANCH`/`MERGE_SHA`. Qui poste **son** merge
   avec le **numéro** d'une PR d'autrui faisait valider les quatre yeux par une
   PR étrangère, en vert. Remède : les trois confrontations `merged` /
   `merge_commit_sha` / `head.ref` → `PAYLOAD_PERIME`, comme la réconciliation de
   `provision-apply` ; une mutation par confrontation.

Et un **vert vacant** : dans `test-team-apply-wiring.sh`, `L_POST` était lu
(`${L_POST:-0}`) quinze lignes avant d'être affecté — `awk "NR>=0"` balayait tout
le fichier, et le contrôle « le seul `node()` est bien DANS le `post` » ne pouvait
plus rougir. La frontière corps/post est calculée avant usage, le repli **refuse**
au lieu de balayer, et une mutation (« le `node()` remonte dans le corps ») le
prouve.

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
- **Dettes nommées** : les **deux** Jenkinsfile restants (`publish-api`,
  `provisioning-request`) portent encore un bloc déclaratif — même motif à
  rejouer si leur récepteur doit changer de visage. La chaîne producteur, elle,
  est convertie : `team-apply`, `team-publish` et `team-promote` ont perdu leurs
  blocs déclaratifs le 2026-09-12, leurs XML sont à `<properties/>`, et leur
  `post{always}` est gardé AVANT le nœud (l'amorçage leur étant désormais imposé
  ET jugé, un post sans `timeout` faisait déclarer la POSE en échec) ; le
  `secretToken` par credential ; `FORGE_CRED_KIND` classé optionnel mais refusé
  si vide par onze pipelines.
- **Le `secretToken` est posé par le JOB, pas par le hook** — arbitré le
  2026-09-12 avec la session qui écrit les hooks. C'est le `properties()` du
  Jenkinsfile qui le fixe ; le hook doit envoyer une valeur ÉGALE à celle de CE
  job. Forme retenue pour la chaîne producteur : deux valeurs **distinctes** par
  défaut (`stoa-team-publish`, `stoa-team-promote`), chacune surchargeable par
  une globale Jenkins, promote retombant sur publish puis sur son littéral — un
  site qui pose UN seul secret sur ses deux hooks fonctionne donc sans knob
  supplémentaire. Ce n'est pas encore un secret : littéral en Git, ou globale
  lisible dans l'UI. Le token **authentifie l'appelant et ne dit rien du
  payload** (M9 : bon token + corps forgé ⇒ 500 sans build) — l'autorité
  d'intégrité reste la confrontation du dépôt réclamé à `providers.<env>.yml`.
- **Sous `gwt`, `team-publish` et `team-promote` partagent UN token**
  (`stoa-team-publish`) et portent des filtres IDENTIQUES : un seul appel
  réveille les DEUX jobs sur toute PR fusionnée d'un dépôt d'équipe, et le tri
  se fait plus tard, dans le `when` de chacun (`api/*` / `promote/*`). Sous le
  plugin, l'option A (deux webhooks par dépôt) est donc plus SERRÉE que le gwt,
  pas équivalente : `sourceBranchRegex` trie dans le récepteur, et
  `team-promote` ne construit plus jamais sur un merge `api/*`. À ne pas lire
  comme une divergence entre les deux visages.
- **Dettes nommées le 2026-09-12, en fermant les deux défauts ci-dessus** :
  1. *Le refus arrive après la pause* — **DEUX instances, ce qui change sa
     priorité** (la seconde trouvée le 2026-09-12, en relisant l'effet d'un hook
     latent sur un projet non déclaré).
     - `team-apply` : `FORGE_IDENTITES_ILLISIBLES` et `PAYLOAD_PERIME` tombent
       **après** que l'humain a été réveillé et a saisi son mot de passe
       d'annuaire. La garde des quatre yeux a besoin de `V_USER`, donc elle doit
       rester là — mais la **relecture** et les **confrontations** pourraient
       précéder l'`input`.
     - `team-publish` : une MR `api/*` fusionnée dans un dépôt que
       `providers.<env>.yml` ne déclare PAS passe le `when`
       (`ci/Jenkinsfile.team-publish:271-273`), **ouvre la pause nominative**
       (`:281`), et n'est refusée `REPO_NON_DECLARE` qu'une fois le script
       démarré (`:364`, `scripts/team-publish.sh:20`). Donc : on réveille
       quelqu'un, on encaisse son mot de passe, on refuse ensuite.
     Le geste est le même des deux côtés : un stage `agent any` de
     réconciliation AVANT l'`input` (motif `provision-apply`), qui rend
     l'exécuteur avant la pause — celle-ci reste donc à zéro exécuteur. Pour
     `team-publish`, ce stage porterait la confrontation dépôt→équipe. Non fait :
     il touche à la fois le récepteur (lot L6) et le corps (lot L5 phase 2), donc
     il s'arbitre.
  2. *Le visage `gwt` n'a aucun discriminant de branche* (`^closed\|true\||merge_request:merge$`) :
     **toute** PR fusionnée du dépôt plateforme construit `team-apply`, l'étape
     étant sautée par le `when`. Le visage `gitlab`, lui, filtre
     (`sourceBranchRegex: 'onboard/.*'`). Non corrigé **délibérément** : ce
     filtre a été mesuré payload par payload, et cette suite-là n'a pas
     d'évaluateur de regex (contrairement à `test-a0-wiring.sh`) — le changer à
     l'aveugle risquerait un apply qui ne part jamais, très au-delà du coût
     actuel (un build vide, désormais sans exécuteur au `post`).
  3. *`team-apply.sh` n'exige du `MERGE_SHA` que d'être non vide* — ni forme, ni
     `merge-base --is-ancestor`, contrairement à `provision-apply-reconcile.sh`.
     La forme est désormais jugée en amont (`forge-merge-identity.sh`) et le SHA
     confronté à la forge ; l'**ancestralité** reste non vérifiée.

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
| **Phase 2 — `team-publish` : le câblage** | `bash scripts/test-team-publish-wiring.sh` | **124/124** (2026-09-12) : XML vide + miroir `xml=absent jenkinsfile=present token=stoa-team-publish vars=16`, frontière corps/post (try + timeout au post SEULEMENT), garde nourrie de la forge RELUE sur le dépôt d'ÉQUIPE. Deux ancres VACANTES corrigées au passage : `grep 'assert-merge-identity.sh'` était vert grâce à l'en-tête en prose, et la boucle `for a in --merged-by …` cherchait ces options n'importe où dans le fichier |
| **Phase 2 — `team-promote` : le câblage** | `bash scripts/test-team-promote-wiring.sh` | **162 PASS / 0** (2026-09-12) : la section ① ne compare plus un miroir mais mesure l'ÉTAT VOULU ; les quatre yeux de ce job vivent DANS son script (conditionnés à la porte du palier), et son script relit déjà la forge — rien à rebrancher |
| **Phase 2 — `team-apply` : le câblage** | `bash scripts/test-team-apply-wiring.sh` | **108/108** (2026-09-12) : XML vide + miroir `xml=absent jenkinsfile=present token=stoa-team-apply vars=14`, récepteur structurel, 5 mutations sur les deux visages, 7 mutations sur la chaîne d'identité |
| **Phase 2 — le script d'identité S'EXÉCUTE** (§3quinquies) | idem | 5 refus de forme joués (`PR_NUMBER_INVALIDE`, `MERGE_SHA_INVALIDE`, `BRANCHE_REQUISE`, `FORGE_IDENTITES_ILLISIBLES`) + **le geste exact du Jenkinsfile joué par dash** + contre-épreuve : la lib sourcée sous dash meurt en « Syntax error » sans nommer aucun refus |
| **Phase 2 — le chemin NOMINAL, joué contre une fausse forge** (§3sexies) | idem | `MERGE_IDENTITY_OK` sur la PR #41 (oscar a fusionné la demande d'alice) ; trois charges utiles forgées refusées `PAYLOAD_PERIME` (numéro d'autrui, MÊME branche avec un autre merge, PR non fusionnée) ; **mutation de comportement** : la confrontation du `merge_commit_sha` retirée ⇒ la charge forgée PASSE, donc c'est cette ligne seule qui ferme le trou |
| **Phase 2 — le shell des blocs `sh`** | `ci/lint-jenkinsfiles.sh` | 10 sources de lib mesurées, toutes lues par `dash -n` ; deux mutations rougissent (la lib bash sourcée dans un bloc `sh`, une lib introuvable) |
| Portes hors ligne | `make lint-ci` | **20/20**, rc 0 (a0-wiring 257/257 dont §3bis et §8bis, provision-apply-wiring 148/148, setup-provision-jobs 69/69, a4 138/138, team-apply-wiring 108/108) |
