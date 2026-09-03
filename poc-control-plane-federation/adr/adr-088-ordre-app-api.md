---
title: "ADR-088 — L'ordre app/API : une application ne se souscrit qu'à une API PROMUE et ACTIVE au palier. La porte vit dans le rôle (le seul site qui tient le credential du palier), à la place de la dernière lecture avant la première écriture ; quatre refus nommés (API_NOT_PROMOTED, API_VERSION_MISMATCH, API_AMBIGUE, API_INACTIVE) relayés avec leur phrase jusqu'à la PR ; verify relit l'API au palier et la souscription au GUID."
sidebar_label: "ADR-088 : l'ordre app/API (A5)"
status: "Acté et prouvé le 2026-09-03 — hors ligne scripts/test-selfservice-api-gate-a5.sh 48/48 (stub à journal + 3 mutations, mock Go, câblage, rapport, prototype), A3 177/177, make lint-ci [14/14] ; par builds réels scripts/test-a5-live.sh 33/33 au premier passage (provision-apply #135 → aval #78 API_INACTIVE rien écrit, PR #450 nommée ; rejeu #136 → #79 SUCCESS souscrite au même GUID ; #80 API_NOT_PROMOTED PR #451 ; #81 API_VERSION_MISMATCH PR #452)."
maturite_technique: "✅ Porte dans le rôle Ansible (la chaîne) ET dans le prototype Python (la spec du fold-in Go) ; lib de refus apim_common/tasks/refus.yml réutilisable par les autres gardes du rôle ; verify rejouable (une API désactivée après l'apply rougit au rejeu). Limite structurelle : la porte suit la lignée du rôle épinglée au SHA appliqué (un repli vers un SHA antérieur à A5 rejoue le rôle d'alors)."
date: 2026-09-03
adr_number: 88
note: "Ferme le trou n°2 du GOAL cd-applications (2026-09-02) mesuré par le spike S2 : la gateway 10.15 accepte la souscription à une API inactive (200, trafic 404) et le moteur posait tout ; une paire posée puis retirée est brûlée (S1-T3), donc la porte doit précéder l'écriture. Consomme ADR-079 (GUID stable à la promotion : la souscription relue au verify est au GUID promu), ADR-083 (le verbe archive est le remède nommé sur la PR), ADR-082/084 (le même relais de refus que PALIER_FERME et DEPLOYER_GROUP_REQUIRED, désormais avec la phrase). Prépare A6 (le repli hérite de la porte) et A7 (le terminus aussi)."
lié: "[[adr-078-self-service-app]], [[adr-079-deploiement-promotion-multienv-import-archive]], [[adr-083-verbe-archive-deux-moteurs]], [[adr-082-ouverture-palier-retention-credential]], [[adr-084-axe-qui-deploie-deployer-group]]"
---

# ADR-088 — L'ordre app/API : une application ne précède jamais son API au palier (A5)

**Statut :** Acté, prouvé hors ligne 48/48 + A3 177/177 + `make lint-ci` [14/14] ; par builds réels sur le lab `scripts/test-a5-live.sh` **33/33** au premier passage.

**Lié à :** [[adr-079-deploiement-promotion-multienv-import-archive]], [[adr-083-verbe-archive-deux-moteurs]], [[adr-082-ouverture-palier-retention-credential]], [[adr-084-axe-qui-deploie-deployer-group]].

---

## Contexte

La chaîne CD des applications (GOAL 2026-09-02, jalons A0..A4) branche la promotion par PR, la référence SHA, le credential du palier et les portes de la chaîne sur le **second objet** — mais rien n'y gardait **l'ordre app/API** : rien n'empêchait de merger `provision/<app>-rec` alors que l'API consommée n'a jamais été promue en rec. Le spike du 2026-09-02 (`scripts/spike-cd-applications.py`, 34/0 sur la 10.15 réelle) a mesuré ce que fait la gateway dans ce cas :

- **UUID inexistant** ⇒ `PUT …/apis` répond 400, sans fantôme (la gateway garde cette porte) ;
- **API inactive** ⇒ la souscription est **acceptée** (200, relue), le trafic répond 404, et la souscription **survit** à l'activation ;
- le **moteur** (prototype Python) refusait l'absente (rc 1, sans tag) et **acceptait l'inactive** (rc 0, application, IAM et injection posées) — résolution par `apiName` **seul** ;
- **une paire application/API qui a servi du trafic ne se ré-inscrit plus** après désinscription (500 irréversible, S1-T3) : la porte ne peut pas être « poser puis défaire ». Elle doit **précéder la première écriture**.

Le rôle Ansible (`apim_selfservice_app`, la chaîne réelle) résolvait déjà par nom **et** version (§1), mais ignorait `isActive`, et son refus était un `assert` anonyme (« absente — la publier d'abord ») qui n'atteignait jamais la PR : le demandeur lisait « EN ÉCHEC — voir la console ». `verify.yml` ne relisait ni l'activité de l'API ni la souscription.

## Décision

### 1. Le site : le rôle, à la place de la dernière lecture avant la première écriture

La porte remplace l'`assert` §1 de `ansible/roles/apim_selfservice_app/tasks/main.yml`, **à la même position** (après la sonde Teams et l'équipe, avant la garde de visibilité et avant `POST /applications`). Ce n'est pas l'ordre des lectures qui est la propriété, c'est **l'antériorité à la première écriture** — prouvée au journal d'un stub : sur un refus, aucun `POST`/`PUT`/`DELETE` n'atteint la gateway (et la mutation d'ordre, porte déplacée après la création, rougit). Le rôle est le **seul** site qui tient le credential du palier : la garde A3 (`selfservice-palier-gate.sh`) ne touche jamais la gateway et ne lit jamais le corps du ticket — y mettre A5 aurait fait lire ce credential par un shell, ce qu'A3 a retiré. Le Jenkinsfile **route** (deux chemins de fichiers de plus), le rôle **décide**.

### 2. Le prédicat, en quatre refus nommés, sur la liste déjà relue

Une seule lecture (`GET /apis`, déjà faite), puis, dans cet ordre : aucune entrée `apiName == api` ⇒ **`API_NOT_PROMOTED`** ; nom présent, aucune `apiVersion == api_version` ⇒ **`API_VERSION_MISMATCH`** (les versions présentes sont citées) ; plus d'une entrée nom+version ⇒ **`API_AMBIGUE`** (fail-closed, jamais `first`) ; l'entrée unique sans `isActive` **booléen vrai** ⇒ **`API_INACTIVE`** (absent, `null`, `"true"` en chaîne, `1` sont inactifs — ne pas savoir n'est pas une raison de passer ; la valeur vue est imprimée pour qu'un mock infidèle se diagnostique en une ligne) ; sinon le marqueur `API_AT_PALIER : '<api>' v<ver> active au palier '<env>' (id=<uuid>)`. Chaque phrase nomme l'API, la version, le palier, la base et **le remède** (`promote/<api>-<env>` par la chaîne des APIs, G5 ; ou activer l'API au palier) et se termine par « rien n'a été écrit ».

### 3. Le relais : une lib de refus, deux fichiers, la même chaîne jusqu'à la PR

`ansible/roles/apim_common/tasks/refus.yml` (additif) : tag (classe `[A-Z][A-Z0-9_]{2,40}`, assertée) → `apim_ss_refus_out` ; phrase (une ligne, ≤ 300) → `apim_ss_refus_detail_out` ; puis `fail` « `REFUS: <TAG> : <phrase>` ». `ci/Jenkinsfile.selfservice` passe `$WORKSPACE/.a3-refus` et `.a3-refus-detail` aux deux plays (converge, verify), les purge aux deux purges absolues, et son `post{always}` relaie `APPLIED_REFUSAL` **et** `APPLIED_REFUSAL_DETAIL` (sous classe, avec un tag seulement — fait Jenkins 11 mesuré en A4). `ci/Jenkinsfile.provision-apply` compose `REFUSAL_DETAIL = "aval <job #n> : <phrase>"` ; `scripts/provision-apply-comment.sh` ajoute le paragraphe « **L'ordre app/API** » pour l'ensemble **explicite** des quatre tags (jamais un préfixe), et une variante « la convergence a eu lieu » pour les deux refus de verify. La garde A3 gagne `REFUS_DETAIL_OUT` : `PALIER_FERME`, `DEPLOYER_GROUP_REQUIRED`… arrivent désormais sur la PR **avec leur phrase**.

### 4. Verify : le même prédicat, plus la souscription relue

`API_AT_PALIER_CONFIRMED` / `API_AT_PALIER_UNCONFIRMED` (même prédicat, via `refus.yml`) et `SUBSCRIPTION_CONFIRMED : '<app>' souscrite à '<api>' v<ver> (id=<uuid>)` / `SUBSCRIPTION_UNCONFIRMED` (`v_api_id ∈ consumingAPIs` de la liste relue). C'est ce qui rend « souscrite au GUID promu » **lisible** — et ce qu'A6 comparera avant/après repli. Verify est rejouable : une API désactivée **après** l'apply rougit au rejeu, ce que l'apply seul ne verrait plus.

### 5. Le prototype Python porte la même porte

`scripts/apply-selfservice-application.py` (la spec vérifiée du fold-in `labctl apply-consumer`) : `api_version` obligatoire (`CABLAGE_INCOMPLET`), nom + version + `isActive is True`, mêmes tags, `exit 1` avant tout `POST`. Le spike S2-T3 est réaligné (il attend désormais le refus) et reste rejouable.

## Ce qui est prouvé

- **Hors ligne, `scripts/test-selfservice-api-gate-a5.sh` 48/48** (dans `make lint-ci` [14/14]) : A. le rôle contre un stub gateway à **journal** (nom absent, version absente, `isActive:false`, `isActive` absent, `isActive:"true"`, doublon ⇒ les quatre refus, **zéro écriture**, tag et phrase écrits, la garde de visibilité pas même relue ; active avec une 1.0.1 inactive à côté ⇒ `API_AT_PALIER` puis la première écriture touche le canari ; apply manuel sans fichiers ; mode 0600) et **trois mutations** (`isActive` ignoré ⇒ l'inactive atteint `POST /applications` ; porte déplacée après la création ⇒ une écriture part avant le refus ; `refus.yml` sans l'écriture du tag ⇒ rien n'atteint la PR) ; B. verify contre le **mock Go** (`API_AT_PALIER_CONFIRMED` + `SUBSCRIPTION_CONFIRMED` au GUID, désactivation ⇒ `API_AT_PALIER_UNCONFIRMED`, souscription remplacée ⇒ `SUBSCRIPTION_UNCONFIRMED`, le mock fidèle sur `isActive`) ; C. le câblage (deux plays, purges, `post{always}` sous classe, `provision-apply`, ordre garde < préflight < converge < verify, porte < visibilité < création) ; D. le rapport (paragraphe présent pour `API_NOT_PROMOTED`, absent pour `PALIER_FERME`, variante verify, détail hostile nettoyé) ; E. le prototype (mêmes tags, `POST` atteint sur l'active, `CABLAGE_INCOMPLET` sans version).
- **`test-selfservice-palier-a3.sh` 177/177** (A.38-A.40 : `REFUS_DETAIL_OUT` écrit, purgé, absent sans la variable) ; suites voisines inchangées (A4 133, câblage 142, A2 148, A0 176, rapport 44, backend-key 27, internal-dcr 45, audience 13, cert-path 16).
- **Par builds réels, `scripts/test-a5-live.sh` 33/33 au premier passage (2026-09-03)** : **1.** `demo-selfservice` désactivée (trap de réactivation), demande rec sous `ci` mergée par alice ⇒ pause `provision-apply` #135 ⇒ aval `selfservice-app-deploy` **#78 FAILURE `REFUS: API_INACTIVE`** (isActive=False, id cité), ordre ticket < préflight < converge < REFUS, aucune tâche d'écriture, aucun verify, **application absente** de la gateway, `post{always}` relaie tag et phrase, amont « verdict FAILURE (API_INACTIVE) », PR #450 ❌ nommant l'API, paragraphe « L'ordre app/API », aval #78 cité ; **2.** réactivation (le même objet, même GUID `658620e8-…`) puis **rejeu du même webhook** ⇒ #136 → aval **#79 SUCCESS**, `API_AT_PALIER` avec le GUID, verify `API_AT_PALIER_CONFIRMED` + `SUBSCRIPTION_CONFIRMED` au même GUID, gateway `consumingAPIs ∋ GUID`, claim `<app>-rec`, PR ✅ ; **3.** nom jamais publié (PR #451) ⇒ aval **#80 `API_NOT_PROMOTED`**, rien écrit, la PR nomme `promote/<api>-rec` ; **4.** `demo-selfservice 9.9.9` (PR #452) ⇒ aval **#81 `API_VERSION_MISMATCH`** citant `1.0.0`, rien écrit. Mesure : 4 APIs inactives sur la gateway au départ ; passage ≈ 22 min sans recyclage keepalive rencontré.

## La mesure qui a coûté (à retenir)

Le mock du dépôt crée les APIs **inactives** (« import does NOT activate ») et quatre sondes hors ligne du rôle (`test-backend-key.sh`, `test-internal-dcr.sh` ×3 sites, et par elles les épreuves de clé backend, de DCR, d'audience) souscrivaient une application à une API **jamais activée** — exactement le fail-open qu'A5 ferme. Elles activent désormais leur API après l'avoir publiée, comme un producteur le ferait. Une suite verte peut exercer le trou qu'elle est censée garder ; c'est la porte qui l'a dit.

## Limites nommées

- **La lignée de la porte** : le rôle est celui de l'arbre pinné au `MERGE_SHA` (A2). Un repli (A6) vers un SHA **antérieur à A5** rejoue le rôle d'alors, sans porte — artefact du lab ; chez un client le rôle est livré avec A5 dès le premier SHA. Ce que le périmètre tient déjà : une PR `provision/*` ne peut pas modifier le rôle (`PR_HORS_PERIMETRE`), `main` n'est poussé que par `ci`. A6 devra le dire. — **Résolu le 2026-09-03 (ADR-089)** : le repli est une **PR** appliquée à **son** SHA de merge (arbre d'aujourd'hui, rôle d'aujourd'hui) — un repli ne rejoue jamais un vieux rôle ; aucun « plancher de SHA » n'est nécessaire.
- **Le plan ne sait pas** : `provision-plan` est en lecture seule, sans credential gateway ; le refus arrive à l'apply, sur la PR, avec le remède.
- **TOCTOU de quelques secondes** entre la porte et le `PUT …/apis` : la course propre de la gateway ; la souscription survit à l'activation (spike), verify le dit au rejeu.
- **Mono-gateway du lab** : « au palier rec » = « sur la 10.15 unique » ; « promouvoir vers rec » se joue par **réactivation** du même objet (GUID identique relu). La topologie par palier est celle du client.
- **Les autres gardes du rôle** (`TEAM_UNDEFINED`, `API_NOT_VISIBLE_TO_TEAM`, `TEAMS_DISABLED`, `ENV_UNDEFINED`, cert/IP) restent des `assert` non relayés : `refus.yml` existe désormais, les y router est un geste par garde.
- **Les refus de verify** ne sont pas un « rien écrit » : la convergence a eu lieu ; le rapport le dit autrement.
- `test-cert-rotation.sh` (live) échoue **avant** A5 sur `TEAM_UNDEFINED` : une dette antérieure (manifeste sans équipe, gateway avec Teams), constatée, non touchée.

## Conséquences

- **A6 hérite** : le repli est un apply comme un autre — « rollback vers un SHA dont l'API n'est plus au palier ⇒ `API_NOT_PROMOTED` » tient par construction, et `SUBSCRIPTION_CONFIRMED` donne le GUID à comparer avant/après.
- **A7 hérite** : au terminus, `apim_ss_api_base` est la base du terminus — « une application dont l'API n'est qu'en homol ne peut pas atteindre prod ». Le mock du terminus sert `isActive` booléen (mesuré en B.4) ; A7 le prouvera par build.
- Le formulaire `app-request` propose les APIs de `publish.yml` (chaîne d'authoring) — ergonomie ; la porte A5 est l'autorité.
