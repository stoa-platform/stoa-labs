---
title: "GOAL — La chaîne CD des applications : porter la DEMANDE d'une application de dev jusqu'en prod sur cinq paliers, par le même gitflow que les APIs — sans archive, parce que l'identité d'une application est par palier"
type: goal
status: "OUVERT le 2026-09-02 — relevé fait, sept jalons A1..A7 à livrer, quatre décisions client. Aucun code modifié par ce document."
date: 2026-09-02
lié: [GOAL-cd-promotion-5-envs-2026-08-26, GOAL-self-service-api-app-2026-07-09, adr-078-livrable-self-service-app-wm1015, adr-079-deploiement-promotion-multienv-import-archive, adr-081-ou-vit-la-decision-humaine, adr-082-ouverture-palier-retention-credential, adr-084-axe-qui-deploie-deployer-group, adr-085-rollback-des-paliers, adr-086-parcours-demandeur-pr-tableau-de-bord]
note: "Le GOAL CD du 2026-08-26 promettait dans son titre « APIs et applications » et a été soldé le 2026-08-27 avec huit jalons qui ne parlent que d'APIs. Ce document est la moitié manquante. Le relevé montre que le gitflow d'entrée (PR, merge, apply nominatif) existe pour les applications, mais qu'aucune des briques de la chaîne CD (référence pinnée, credential par palier, axe déployeur, rollback, terminus) n'y est branchée — et que le manifeste d'application n'est même pas multi-palier."
---

# GOAL — La chaîne CD des applications

**Origine.** Depuis le 2026-08-27, un producteur fait passer une API de dev à la prod en cinq PRs, chaque palier recevant exactement l'archive approuvée (G1..G8, ADR-082 à 087). Un consommateur, lui, ne peut **rien** faire passer : la voie `app-request` ouvre une PR par palier, l'applique sur le dernier `main` avec un credential unique, sans porte de chaîne, sans repli, et jamais au-delà de homol. Le formulaire propose pourtant `rec`, `int` et `homol` — **aucune épreuve du dépôt n'a jamais joué autre chose que `dev`** sur cette voie.

---

## Décision (test « archi 40 ans / 30 secondes »)

> **On ne promeut pas une application, on promeut sa DEMANDE.** Une API est un artefact unique qu'on transporte à l'identique (GUID iso, ADR-079) : « build once, deploy many ». Une application est une **identité par palier** — son `client_id` est `<app>-<env>` (claim `azp`, `scripts/provision-request.sh:421`), son certificat, sa plage IP et sa référence de clé backend vivent dans `per_env.<env>`, son secret sous `deploy/<tenant>/apps/<app>/<env>/`. Ce qui doit être identique d'un palier à l'autre n'est pas l'objet gateway, c'est le **contrat de consommation** : quelle API, quelle audience, quels identifiers opposés. L'archive n'est donc pas le verbe des applications — et `archiveKeepTypes` (`labctl/internal/adapter/webmethods/archive.go:56`) ne garde **volontairement** que `API`, `Policy`, `PolicyAction`, parce qu'une application archivée transporte ses clés.
>
> **Le verbe des applications est la convergence idempotente au palier**, portée par le moteur déjà prouvé (`apply-selfservice-application.py`, « crée/converge », identifiers opposés par règle IAM strict) — jamais un delete/create qui régénérerait la clé du consommateur. Ce verbe est acceptable là où le re-`POST` d'API ne l'est pas : une application n'est pas en ligne de trafic, c'est l'API qui l'est, et le lien app→API par GUID **survit** à la promotion de l'API (ADR-079, A3 mesuré).
>
> **Le gitflow est le même que pour les APIs, appliqué au manifeste.** Une PR par palier (`provision/<app>-<env>`, existante), la décision au merge (ADR-081), l'apply au **SHA mergé** et pas au dernier `main`, le credential du **seul** palier (AppRoles `apply-<env>` déjà posés par G4, jamais consommés par cette voie), l'axe « qui déploie » (ADR-084), un repli par palier (ADR-085), la PR comme tableau de bord (ADR-086). Rien de neuf à inventer : **sept briques existent pour les APIs, zéro n'est branchée sur les applications.**
>
> **L'ordre est une porte, pas une convention.** Une application consomme une API par `name + version`, résolue dans la gateway du palier. Si l'API n'a pas encore été promue au palier, l'apply de l'application doit **refuser, fermé**, et non créer une souscription orpheline ou tomber sur `sys:defaultApplication`.
>
> **Test :** *un consommateur peut-il faire passer son application de dev à la prod en cinq PRs, chacune n'écrivant que sa clé `per_env`, appliquée au SHA mergé avec le credential de son seul palier, refusée mécaniquement tant que l'API n'y est pas, réversible au SHA précédent sans changer de clé, et sans qu'un membre de sa propre équipe puisse l'approuver au-delà de rec ?* Si l'une de ces réponses n'est pas « oui, mécaniquement », on a un formulaire à quatre valeurs, pas une chaîne.

---

## Ce que le relevé a mesuré (2026-09-02)

**Ce qui existe et sert déjà les applications :**

| Pièce | Où | État |
|---|---|---|
| Porte d'entrée humaine | `ci/Jenkinsfile.app-request` → `scripts/provision-request.sh` | Livrée, PR `provision/<app>-<env>` + plan commenté |
| Porte d'entrée machine (OIG/CLI2) | `provisioning-request` → **le même** `provision-request.sh` | Livrée — les deux entrées partagent l'aval, la CD s'écrit une fois pour deux |
| Apply post-merge en pause nominative | `ci/jenkins/provision-apply.job.xml` → `selfservice-app-deploy` | Livré, dev seulement en pratique |
| Quatre-yeux au valideur | `scripts/lib/assert-merge-identity.sh` | Livré, appelé (`test-provision-apply-wiring.sh`) |
| Axe env dérivé de la chaîne | `provision-request.sh:140-144` (`env_chain_nonprod`, refus `ENV_INVALIDE`) | Livré par G4 (D6) — terminus exclu par structure |
| Rétention Vault par palier côté secrets d'app | write tenant resserré à `apps/+/<env>/*` (ADR-082, D3) | Livré — une écriture d'app au terminus meurt en 403 |
| Moteur de convergence | `scripts/apply-selfservice-application.py` (prototype, cible `labctl apply-consumer`) | Prouvé live 10.15 (ADR-078), identifiers cert/IP opposés |

**Ce qui existe pour les APIs et n'est PAS branché sur les applications :**

| Brique CD | APIs (livré G1..G8) | Applications (mesuré) |
|---|---|---|
| Référence pinnée (G3) | `deploy.<env>.yaml` + sha256 | **aucune** : `provision-apply.job.xml:40-42` lit `clients/provisioned/applications/<app>.ansible.yml` sur `main` ; `Jenkinsfile.selfservice` ne connaît pas `MERGE_SHA` |
| Credential par palier (G4) | AppRole `apply-<env>`, `envs/<env>/wm-admin` | **un seul** credential tenant `deploy/banking-demo/wm-admin` (`Jenkinsfile.selfservice:89`) + en-tête `X-Environment` vers le proxy multi-env (`:32`) — le palier est un **en-tête**, pas un credential |
| Axe déployeur (G2, ADR-084) | `deployerGroup` aux deux dispatchs | **absent** — sites d'enforcement : `Jenkinsfile.prod`, `Jenkinsfile.rollback`, `team-promote.sh` ; `provision-apply` n'en fait pas partie |
| Portes de chaîne (G1) | `approverGroup`, `fourEyes`, ITSM au dispatch | seul le 4-yeux mergeur≠demandeur ; `environments.yaml` **jamais lu** par `provision-apply` |
| Rollback (G6, ADR-085) | `Jenkinsfile.rollback`, tous paliers | **non couvert** |
| Terminus | voie directe prouvée (build #24, `operator-deploy`) | 403 structurel — **aucune voie prod n'existe** pour une application |
| Liste des paliers | dérivée d'`environments.yaml` | **deux listes en dur** : `ci/jenkins/app-request.job.xml:49`, `ci/Jenkinsfile.selfservice:44` |
| Preuve E2E | builds #18 à #24, GUID iso 4/4 | **zéro** épreuve avec `REQ_ENV ≠ dev` (`test-app-request-v*.sh`, `test-provision-apply-wiring.sh`) |

**Les trois trous propres aux applications — ceux que G1..G8 n'avaient pas à voir :**

1. **Le manifeste n'est pas multi-palier.** `provision-request.sh` **réécrit le fichier entier** par heredoc (`:383-422`) et n'y met **qu'un seul** palier : `per_env:\n    ${REQ_ENV}: {…}` (`:377`, `:399`). Une demande `rec` **efface** la clé `dev` dans Git. Le fichier `clients/provisioned/applications/paiements-sepa.ansible.yml` en est la preuve : il ne porte que `dev`. On ne peut pas pinner par palier un fichier qui ne sait décrire qu'un palier à la fois. (Limite déjà notée en mémoire `app-request-v3-increment`, item 2 — elle n'était qu'un inconfort ; elle devient bloquante.)
2. **L'ordre app/API n'est gardé nulle part.** Rien n'empêche de merger `provision/<app>-rec` alors que l'API consommée n'a jamais été promue en rec. Ce que fait alors la gateway n'est **pas mesuré** — et la mémoire `oracle-idp-gateway-sync` rappelle qu'un token valide non matché retombe sur `sys:defaultApplication` malgré `strict`.
3. **Le comportement en vol de la convergence n'est pas mesuré.** ADR-079 a mesuré 0-coupure pour l'import d'archive d'API ; personne n'a mesuré ce que fait la 10.15 pendant un `PUT /applications/{id}` qui change les identifiers d'une application active (règle IAM ré-évaluée en vol ? cache fantôme ? — la mémoire `oracle-idp-gateway-sync` note « retrait ≠ révocation (cache fantôme) » pour les stratégies). Un verbe dont on ne connaît pas l'effet en vol n'est pas un verbe de prod.

---

## Ce que le relevé a tranché — et ce qu'il n'a pas tranché

**Tranché : pas d'archive pour les applications.** Trois raisons cumulatives, aucune n'est une préférence : (a) `archiveKeepTypes` strippe `Application` **à dessein** — une application archivée embarque ses clés, et ADR-079 a dû stripper `PassmanData` pour la même raison ; (b) l'identité est par palier (`<app>-<env>`), donc l'objet transporté serait **faux** à l'arrivée ; (c) le lien app→API par GUID est **déjà** préservé par la promotion d'API — l'archive n'apporterait rien que la convergence n'ait pas. Rouvrir le filtre serait rouvrir la question des secrets qu'ADR-079 a fermée.

**Tranché : un seul gitflow, deux objets.** La PR par palier, le SHA mergé comme référence, le credential par palier, l'axe déployeur, la PR-tableau de bord — tout est réutilisé tel quel. Ce GOAL ne crée **aucun** mécanisme de gouvernance ; il branche ceux d'ADR-082/084/085/086 sur un deuxième objet. C'est exactement la thèse du GOAL du 2026-08-26 (« on ne construit pas une chaîne CD : on branche celle qui existe »), une fois de plus.

**Tranché : « build once, deploy many » ne s'applique pas, et il ne faut pas le simuler.** Ce qui est promu est le **contrat de consommation** ; l'identité change par palier par conception (segmentation, révocation locale sans effet sur les autres paliers). Prétendre transporter « la même application » masquerait cette différence au lieu de la gouverner.

**PAS tranché — à mesurer avant de l'écrire :**
- L'effet **en vol** d'une convergence d'application sur la 10.15 (trou n°3). C'est un spike, pas une opinion, et il conditionne A6.
- Ce que fait la gateway quand une application souscrit à une API **absente** du palier (trou n°2) : refus REST propre, ou souscription fantôme ? À mesurer avant d'écrire la porte A5, pour qu'elle refuse **avant** la gateway et non après.
- Aucune source réglementaire propre aux applications n'a été cherchée : l'art. 17(1)(b) du RTS DORA (indépendance approbateur/demandeur, « all changes ») s'applique à l'identique, et le GOAL du 2026-08-26 l'a déjà sourcé. Ne pas chercher un appui supplémentaire qu'on n'a pas.

---

## Jalons — chacun avec sa porte de preuve et sa contre-épreuve

### A1 — Le manifeste devient multi-palier : une demande n'écrit que sa clé

`provision-request.sh` cesse de réécrire le fichier. Une demande `<app>` en `<env>` **fusionne** `per_env.<env>` dans le manifeste existant (ou le crée s'il n'existe pas), et ne touche à rien d'autre. Les champs trans-paliers (`name`, `api`, `api_version`, `audience`, `mode`, `team`) sont **figés à la première demande** : une demande ultérieure qui les changerait est refusée (`CONTRAT_DIVERGENT`) — changer d'API consommée est une **nouvelle** application, pas une promotion.

Ce jalon règle au passage l'item 2 de `app-request-v3-increment` (app-liste) : le manifeste devient la liste.

**Porte A1 :** demande `dev` puis demande `rec` ⇒ le manifeste porte **deux** clés `per_env`, avec des `vault_sub` / `client_id` distincts.
**Contre-épreuve :** la demande `rec` ne modifie **aucun octet** hors de `per_env.rec` (diff vide ailleurs) ; une demande `rec` avec une autre `api` ⇒ `CONTRAT_DIVERGENT`, aucune branche créée.

### A2 — La référence : l'apply projette le SHA mergé, jamais le dernier `main`

`provision-apply` passe `MERGE_SHA` (déjà dans le webhook, déjà exploité par `team-apply.sh:67`) à `selfservice-app-deploy`, qui checkoute **ce** SHA et applique `per_env.<env>` tel que mergé. La PR reçoit en commentaire le SHA appliqué et le digest du bloc `per_env.<env>` — c'est la réponse à « qu'est-ce qui tourne en rec ? ».

**Décision de forme, tranchée comme pour les APIs :** pas de branche d'environnement, pas de fichier `deploy.<env>.yaml` supplémentaire — la PR `provision/<app>-<env>` **est** le fichier de déploiement du palier ; son SHA de merge est la référence.

**Porte A2 :** merger `provision/<app>-rec`, pousser un autre commit sur `main` **avant** de répondre à la pause ⇒ l'apply projette le SHA mergé, pas HEAD.
**Contre-épreuve :** webhook forgé sur une PR jamais mergée ⇒ `PAYLOAD_PERIME` (le motif G7 #25, rejoué sur cette voie) ; gateway inchangée.

### A3 — Le credential du seul palier

`selfservice-app-deploy` cesse de lire `deploy/<tenant>/wm-admin` + `X-Environment`. Il lit `envs/<env>/wm-admin` avec le credential du palier — l'AppRole `apply-<env>` posé par G4 pour la voie machine, le grant nominatif pour la voie humaine — **exactement** comme `team-promote` (« bob porte apply-int », build #19). Le proxy multi-env peut rester le transport ; il cesse d'être ce qui **décide** du palier.

Le terminus ne reçoit rien : ouvrir `prod` aux applications est un geste de credential (A7), jamais un edit.

**Porte A3 :** matrice 403 par palier rejouée sur la voie application (`test-palier-retention-live.sh` étendu) : le job de `rec` ne peut lire aucun `envs/int/*`.
**Contre-épreuve :** révoquer `apply-rec` ⇒ l'apply de l'application en rec échoue **fermé**, gateway inchangée, zéro connexion (le F4-canari, sur cette voie).

### A4 — Les portes de la chaîne et l'axe déployeur, au dispatch de `provision-apply`

`provision-apply` lit `environments.yaml` par la même lib que `team-promote` (`env-chain.sh` / dispatch gate) : `approverGroup`, `fourEyes`, `deployerGroup` (ADR-084, les trois refus nommés), ITSM au terminus. La garde `assert-merge-identity.sh` reste, et prend `--allow-self-approval` de la porte du palier au lieu d'un défaut.

Les deux listes en dur tombent : `app-request.job.xml:49` est **substituée à la pose** par `setup-team-onboard-jobs.sh` depuis `env_chain_nonprod` (le motif `<!--CHOICES:…-->` existe déjà pour `TEAMS` et `APIS`) ; `Jenkinsfile.selfservice:44` reste la seule liste manuelle, **documentée comme telle** (contrainte Declarative mesurée en G1).

**Porte A4 :** un demandeur sans `deployerGroup` du palier ⇒ refus nommé au dispatch, **rien écrit** ; membre de l'équipe demandeuse qui approuve rec→int ⇒ `FOUR_EYES_VIOLATION`.
**Contre-épreuve :** retirer un palier d'`environments.yaml` ⇒ le formulaire posé ne le propose plus **et** `provision-request.sh` le refuse (`ENV_INVALIDE`) — deux portes, une source.

### A5 — L'ordre app/API : refus fermé si l'API n'est pas au palier

Avant tout geste sur la gateway, l'apply vérifie que `api@api_version` **existe et est active** dans la gateway du palier. Sinon `API_NOT_PROMOTED`, rien écrit, message sur la PR nommant la promotion d'API manquante.

Prérequis : le spike du trou n°2 (que fait la gateway sur souscription à une API absente), pour que la porte soit **antérieure** à tout comportement gateway mal connu.

**Porte A5 :** application en rec, API jamais promue en rec ⇒ `API_NOT_PROMOTED`, aucune application créée ; promouvoir l'API (G5) puis rejouer ⇒ application créée, **souscrite au GUID promu** (le même qu'en dev, ADR-079 A3).
**Contre-épreuve :** API présente mais **inactive** en rec ⇒ refus (une souscription à une API inactive est une souscription à rien).

### A6 — Le repli : re-convergence au SHA précédent, sans changer de clé

`Jenkinsfile.rollback` (ADR-085) apprend l'objet application : re-appliquer le SHA de merge **précédent** de `provision/<app>-<env>` au palier. Le verbe étant la convergence idempotente, le rollback est un apply comme un autre — à condition que la convergence **préserve** le GUID de l'application et sa clé.

Prérequis : le spike du trou n°3 (effet en vol de la convergence). Si la 10.15 recycle la clé ou le cache d'identification pendant un `PUT`, ce jalon doit le dire et le mesurer, pas le supposer.

**Porte A6 :** deux applies successifs de la même application ⇒ **même GUID d'application, même clé** ; rollback rec ⇒ état de la gateway = état au SHA N-1 (identifiers, IP, cert), vérifié par lecture, pas par log.
**Contre-épreuve :** rollback vers un SHA dont l'API n'est plus au palier ⇒ `API_NOT_PROMOTED` (A5 tient aussi en repli) ; rollback au terminus sans référence ITSM ⇒ refus (le motif G6).

### A7 — Le terminus et le parcours complet, par builds réels

Ouverture de `prod` aux applications par le **même** geste de credential que G7 (`operator-deploy` étendu, voie directe, ITSM re-vérifié au dispatch). Puis le parcours entier : une application `dev → rec → int → homol → prod` en cinq PRs, cinq builds, chaque PR portant plan / résultat (demandée par / mergée par / portée par) / SHA appliqué.

Et la dette de preuve qui a permis ce trou d'exister : la suite `test-app-request-v*.sh` reçoit son **chemin nominal hors dev** (la leçon de `app-request-v3-increment` : une suite dont toutes les épreuves sont des refus ne teste jamais le chemin nominal).

**Porte A7 :** cinq builds verts, application présente et souscrite sur les cinq gateways à l'API promue (GUID identique 5/5), `client_id` distinct par palier, clé jamais transportée.
**Contre-épreuve :** `PAYLOAD_PERIME` et `ITSM_NOT_APPROVED` rejoués sur cette voie (les #25/#26 de G7) ; une application dont l'API n'est qu'en homol ne peut pas atteindre prod (A5 au terminus).

**Limite héritée, à écrire d'avance :** le terminus du lab est `wm-mock-prod` (l'importeur du produit réel refuse l'archive du mock, G7 builds #21/#23). Pour les applications la limite est **moindre** — la convergence n'est pas un import d'archive — mais le mock doit supporter `PUT /applications` et la règle IAM strict, ce qui n'est pas vérifié (mémoire `palier3-chaine-producteur` : « mock périmé/sans DELETE »).

---

## Décisions client bloquantes

1. **Une identité par palier, ou une identité trans-paliers ?** Le PoC pose `client_id = <app>-<env>`. C'est le choix qui **fonde** ce GOAL (pas d'archive, convergence par palier). Un client dont l'IdP ne délivre qu'un `client_id` par application, tous paliers confondus, change la donne : la claim devient trans-palier, seule la plage IP et le certificat restent `per_env`. Le mécanisme A1 le supporte (les champs figés changent de liste), mais la **décision de segmentation** est celle du client, pas la nôtre.
2. **Qui demande au-delà de dev — le consommateur lui-même, ou l'équipe productrice ?** C'est la décision n°1 du GOAL du 2026-08-26 (art. 17(1)(b) RTS DORA, « all changes »), posée cette fois pour le consommateur. Réglage d'`environments.yaml` ; mais une application en prod consomme une API de prod, et le producteur peut légitimement vouloir **voir** qui se branche sur lui : une option (d) « demande consommateur, approbation productrice » est exprimable par `approverGroup` et n'existe pas côté API.
3. **La voie machine (OIG/CLI2) peut-elle demander au-delà de dev ?** Aujourd'hui oui (`REQ_ENV` est un paramètre de l'API de provisioning). Si le client veut que l'annuaire ne déclenche que des demandes `dev`, c'est une garde à poser **à l'entrée machine**, pas dans `provision-request.sh` qui sert les deux voies.
4. **Qui porte `apply-prod` pour les applications ?** Le même `operator-deploy` que les APIs (une équipe release pour tout), ou un groupe distinct ? Ni le mécanisme ni le coût ne changent ; l'annuaire, si.

---

## Ce que ce GOAL ne fait pas

Il ne modifie rien. Il ne rouvre pas le verbe archive (ADR-079, ADR-083) et ne touche pas à la chaîne des APIs. Il ne ferme pas les deux fail-open natifs d'ADR-078 (TTL de clé global, `ipAllowlist` — ce dernier en cours de fermeture par la règle IAM strict) : ils sont des propriétés du palier, pas de la promotion, et restent tracés là où ils sont. Il ne fold pas `apply-selfservice-application.py` dans `labctl apply-consumer` : c'est la cible déclarée du prototype, et un jalon de parité (le motif G8) le jour où deux moteurs existeront pour les applications — aujourd'hui il n'y en a qu'un, ce qui est la seule situation où la parité ne coûte rien.
