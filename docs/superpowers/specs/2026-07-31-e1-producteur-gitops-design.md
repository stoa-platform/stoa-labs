---
title: "E1 — Self-service producteur par GitOps : la chaîne garantit ce que le produit ne garantit pas (spécification)"
type: spec
status: "Cadré sur une mesure du 2026-07-31 qui RÉFUTE la porte de preuve écrite au GOAL. À valider avant plan d'implémentation."
date: 2026-07-31
lié: [GOAL-self-service-api-app-2026-07-09, GOAL-socle-vers-gateway-2026-07-28, 2026-07-29-f4-chaine-publication-design, adr-076-gitops-api-lifecycle-repo-per-project, adr-078-livrable-self-service-app-wm1015]
---

# E1 — Self-service producteur par GitOps (spécification)

## En une phrase

La moitié « publication scopée » de E1 est acquise depuis F4 ; la moitié
« refus cross-team » ne l'est pas, **et son énoncé est faux** : la gateway
n'oppose aucun refus cross-team à l'identité que la chaîne porte. Cette
spécification remplace une porte de preuve à observer par une garde à
construire, et met le moteur du producteur à parité avec celui du consommateur.

---

## 1. Terrain — ce que la gateway refuse RÉELLEMENT (mesuré le 2026-07-31)

Le GOAL attendait de E1 : *« publication cross-team (assigner une team dont on
n'est pas membre) **refusée 400** “User cannot assign the specified team to
API” »* — constat du spike #1 du 2026-07-09, **sur le lab Docker**. Rejoué sur
la gateway du cluster, il ne se reproduit pas.

Protocole : API jetable créée pour la mesure puis supprimée (`204`) ;
`accounts-read`, qui sert le trafic public, n'est jamais touchée ; **toutes**
les requêtes visent le Service d'administration (réplique unique) — à travers
`wm-apigateway` un 401 ne distingue pas un refus d'un cache froid ; chaque refus
est opposé à un **témoin** bien formé, sans quoi un échec ne se distingue pas
d'une requête malformée (leçon du 2026-07-31, garde 3 de E3).

| Geste | Identité | Observé |
|---|---|---|
| `POST /assets/team` — **sa propre** API, **sa propre** team | `svc-banking-demo` | **401** « The user: svc-banking-demo is not authorized to perform: POST on the resource: assets » |
| `POST /assets/team` — team d'une **autre** équipe | `svc-banking-demo` | **401**, message identique |
| `GET /apis/{id}` — API d'une autre équipe | `svc-insurance-demo` | **401** « User doesn't have permission to manage this API » |
| `POST /assets/team` — se l'attribuer | `svc-insurance-demo` | **401** |
| Déplacer une API de `banking-demo` vers `insurance-demo` | **admin** | **200**, relu `['Administrators','insurance-demo']` — **aucun refus** |
| `POST /apis` multipart | `svc-banking-demo` | **201** — l'équipe **peut** publier |
| Team de l'API ainsi créée | — | **`Default`** ; une équipe tierce la lit : **200** |
| Témoin : `GET /apis/{id}` de sa propre API | `svc-banking-demo` | **200** |

**Ce que la mesure établit :**

1. **Le 400 du GOAL n'existe pas ici.** Le produit ne refuse pas *le
   cross-team* ; il refuse la ressource `assets` à **tout non-admin**, y
   compris pour sa propre équipe. Le refus fin observé le 2026-07-09 tenait
   à une configuration de privilèges du lab Docker, pas à une propriété de la
   10.15 — l'écrire comme porte de preuve, c'était s'appuyer sur un accident.
2. **L'isolation en lecture, elle, mord** : une équipe tierce ne lit pas l'API
   d'une autre (401). C'est le socle de P-1, et il tient.
3. **L'identité que la chaîne porte n'a aucun garde-fou.** Assigner une team
   est une opération d'admin ; l'admin déplace n'importe quelle API vers
   n'importe quelle équipe. C'est le même nœud que la garde 3 de E3 :
   *celui qui peut cloisonner est précisément celui à qui rien n'est opposé.*
4. **Découverte non prévue** : une équipe peut publier **hors chaîne**, et son
   API atterrit en `Default` — visible de toutes. Sur les applications, E3
   avait qualifié la protection de « geste qu'on peut oublier » ; sur les APIs
   c'est pire : **l'équipe ne peut pas faire le geste**, puisqu'`assets` lui
   est refusé. Publier sans la chaîne, c'est nécessairement publier en clair
   pour tout le monde.

**Le point qui commande toute l'architecture** : le job F4 est un
`CpsScmFlowDefinition` de `scriptPath: Jenkinsfile` **pris dans le dépôt de
l'équipe** (`banking-demo/accounts-api.git`,
`docs/superpowers/plans/2026-07-29-f4-jenkins-publish-job.xml:36-53`). L'équipe
écrit donc elle-même le `TEAM='banking-demo'` de son pipeline — et aussi le
`serviceAccount:` de son podTemplate. **Aucune dérivation logée dans ce fichier
n'est infalsifiable**, quelle que soit son ingéniosité.

### État du moteur producteur, comparé au moteur consommateur

`apim_selfservice_app` a été durci le 2026-07-31 (E3, gestes 1 et 2).
`apim_publish_api` ne l'a pas été. Le fichier porte d'ailleurs son propre
avertissement : « ⚠ NON TESTÉ LIVE ».

| | Producteur — `apim_publish_api/tasks/team.yml` | Consommateur — `apim_selfservice_app` |
|---|---|---|
| `assetType` dans le POST | **absent** → 200 no-op silencieux | présent (`team.yml:75`) |
| Relecture fail-closed | **aucune** | `TEAM_CONFIRMED` / `TEAM_UNCONFIRMED` |
| Origine de l'équipe | `apim_api.team` — **le manifeste que l'équipe écrit** | extra-var du pipeline **>** manifeste (`team-name.yml:16-21`) |
| Assignation obligatoire ? | **optionnelle** (`main.yml`, `when: apim_api.team \| length > 0`) | fail-closed `TEAM_UNDEFINED` |
| `verify` contrôle-t-il la team ? | **non** — `PUBLISH_CONFIRMED` est muet sur l'isolation | oui |

---

## 2. Objectif et porte de preuve (celle du GOAL est remplacée)

**Objectif.** Le producteur publie par GitOps, et **la chaîne** — pas le
produit — garantit qu'il publie **dans sa propre équipe**.

| Porte | Attendu |
|---|---|
| **P-1 — isolation** *(acquise en F4, rejouée après bascule de moteur)* | push d'une spec sur le dépôt de `banking-demo` → API active, teams relues `['Administrators','banking-demo']`, `Default` absente ; `svc-insurance-demo` → `GET /apis` ne la contient pas et `GET /apis/{id}` → 401 |
| **P-2 — refus cross-team** | un manifeste demandant `team: insurance-demo` depuis le dépôt de `banking-demo` → **build rouge `TEAM_FORBIDDEN`**, statut de commit rouge, et **rien n'est ni créé ni déplacé** (relecture : catalogue et teams inchangés) |
| **P-3 — le 200 ne prouve rien** | `POST /assets/team` **sans** `assetType` → 200 et teams inchangées ⇒ le rôle **rougit**. La relecture est la porte, pas le code HTTP |
| **P-4 — fail-closed sans équipe** | ni extra-var ni `team:` → refus de publier (`TEAM_UNDEFINED`), plutôt qu'une API en `Default` visible de toutes |
| **P-5 — injection par le manifeste** | un manifeste déclarant une clé hors liste blanche (p. ex. `apim_ss_api_base`) → **build rouge `MANIFEST_KEYS_FORBIDDEN`**, avant tout appel à la gateway |

**Contre-épreuves de sabotage** (une garde qui ne rougit jamais ne prouve rien) :

1. retirer `assetType` du rôle → **P-3 rouge** ;
2. écrire `team: insurance-demo` dans le manifeste alors que le job porte
   `banking-demo` → **P-2 rouge**, et le catalogue relu prouve qu'aucune API
   n'a été créée ;
3. demander une team inconnue de la gateway → `TEAM_UNKNOWN`, build rouge ;
4. ajouter `apim_ss_api_base: http://ailleurs` au manifeste → **P-5 rouge**.

**Ce que ces portes ne prouvent pas, et qu'il faut dire** : elles portent sur le
chemin **GitOps**, le seul par lequel une API est livrée dans le modèle cible
(les équipes produit n'ont aucun accès direct à la gateway — ADR-076/078).
Elles ne disent rien du chemin **direct** d'une équipe qui atteindrait l'admin
REST par le proxy OAuth2 de E2. C'est la même frontière que celle actée pour la
garde 3 de E3, et elle doit être répétée ici, pas supposée connue.

---

## 3. Décisions

### D1 — La chaîne cluster passe au rôle Ansible `apim_publish_api`

F4 avait tranché l'inverse (spec F4 §D1 : « écartée : la chaîne Ansible
`apim_publish_api` du PoC — fidèle client mais le GOAL désigne labctl et
l'image du socle le porte déjà »). **Cette spécification renverse cette
décision**, et il faut le dire ainsi plutôt que de laisser deux moteurs
coexister sans l'avoir choisi.

Motif : tout le durcissement à écrire (assetType, relecture, dérivation
d'équipe, liste blanche, `verify`) vit dans le rôle. Le laisser hors du chemin
réel, c'est maintenir deux implémentations des mêmes quirks wM — et n'en
prouver qu'une. `ansible-core` est dans l'image `jenkins-go`
(`ci/jenkins/Dockerfile`), et le chemin consommateur lance déjà un rôle Ansible
(`ci/Jenkinsfile.selfservice`). La bascule aligne les deux chemins.

Conséquence : la dette « `team:` natif dans labctl (moteur unique ADR-076) »
**devient sans objet** pour E1 et doit être retirée du GOAL avec sa raison —
pas simplement rayée. `labctl` reste la spec vérifiée parquée (contrainte de
provenance, POSITIONING §7.6).

*Écartées :* garder `labctl apply` + curl durci (évite de retoucher une chaîne
verte, mais laisse le rôle Ansible non prouvé live et deux moteurs à corriger) ;
étendre `labctl` au `team:` (le plus propre à terme, mais exige de reconstruire
l'image — fenêtre exploitant et dérive de plugins, ce que F4 avait voulu éviter).

### D2 — Le job Jenkins possède la définition du pipeline

Le job passe de `CpsScmFlowDefinition` à **`CpsFlowDefinition` (script inline)**.
Le script porte `TEAM`, le `serviceAccount` du podTemplate, l'URL du dépôt à
cloner et le chemin du manifeste. Il clone le dépôt d'équipe **pour ses données
seulement** : contrat OpenAPI + manifeste. Le dépôt d'équipe **perd son
`Jenkinsfile`**.

C'est la seule décision qui rend la garde réelle. Tant que le pipeline vient du
dépôt de l'équipe, `TEAM` est une valeur que l'équipe écrit, et toute garde
placée en aval raisonne sur une donnée falsifiée.

*Écartées :* shared library (du Groovy dans un dépôt de plus, appelé par un
`@Library` **depuis le Jenkinsfile qu'on veut supprimer** — la propriété n'est
pas déplacée, seulement l'indirection) ; garder `CpsScmFlowDefinition` en
comptant sur une garde en aval (rien en aval ne connaît l'équipe légitime).

**Dette explicite :** un script inline n'est pas versionné tant que JCasC n'est
pas posé. Parade retenue, déjà pratiquée en F4 : le `config.xml` du job est
exporté dans le dépôt comme **copie de reconstruction**, avec les secrets
substitués. Ce n'est pas du versionnement — c'est de la reconstructibilité, et
le document doit le dire pour ne pas se payer de mots.

### D3 — L'équipe vient du pipeline ; une divergence du manifeste est une ERREUR

Portage de `team-name.yml` au producteur, **avec un durcissement de plus**.
Chemin consommateur : l'extra-var l'emporte, le manifeste est ignoré en silence.
Chemin producteur : si le manifeste déclare une `team:` **différente** de celle
du pipeline, le rôle **échoue** (`TEAM_FORBIDDEN`).

Motif : ignorer silencieusement une demande cross-team la rend indétectable —
l'équipe qui l'a écrite ne l'apprend jamais, et la plateforme non plus. La
faire rougir la trace dans le statut de commit, où elle est lisible par les deux.
Une `team:` **identique** à celle du pipeline reste acceptée (redondance
inoffensive, utile en lecture du manifeste).

### D4 — La garde joue AVANT l'import

L'ordre est une propriété, pas un détail : la résolution d'équipe et le contrôle
de cohérence s'exécutent **avant** `POST /apis`. Sinon un refus cross-team
laisse derrière lui une API créée, non assignée, donc en `Default` — visible de
toutes. Le refus aurait produit exactement le défaut qu'il prétend empêcher.

Même motif et même position que la garde du register de E3 (`main.yml` §1b,
« et rien n'est créé »).

### D5 — Liste blanche stricte des clés du manifeste

`resolve-env.yml` charge le manifeste par `include_vars` (précédence 18) : **tout
top-level du fichier devient une variable Ansible**. Les extra-vars du pipeline
(précédence 22) gagnent, mais une variable que le pipeline ne passe pas est à la
merci du manifeste — `apim_ss_api_base`, `apim_ss_vault_wm_creds_sub`,
`apim_ss_auth_mode`…

Le rôle **refuse** un manifeste déclarant une clé hors liste blanche, avant tout
appel à la gateway. **La liste blanche est exactement `apim_api`** — un
manifeste ne déclare rien d'autre au top-level. Toute clé qu'on voudrait y
ajouter plus tard exige une ligne de spécification qui dit laquelle et
pourquoi ; une liste qui s'élargit par commodité ne garde plus rien.

Le pipeline passe **en plus** en extra-var toute variable de sécurité
(base d'admin, chemin KV du compte de service, équipe, mount et préfixe KV,
mode d'authentification). Les deux, parce qu'une liste blanche qu'on oublie
d'étendre échoue en fermant (build rouge, corrigible) tandis qu'un `-e` qu'on
oublie d'ajouter échoue en ouvrant (silencieux) — c'est exactement le motif
« une garantie écrite mais fausse coûte plus cher que son absence » du handoff F5.

### D6 — Retirer la création d'API aux comptes `svc-<team>`

La mesure M4 montre qu'une équipe publie hors chaîne, en `Default`. Décision :
**retirer le privilège d'écriture sur les APIs** à l'accessProfile d'équipe, en
conservant la lecture scopée dont P-1 dépend et dont E2 aura besoin comme
identité sortante.

**Ce que la mesure du 2026-07-31 dit du terrain** (lecture seule) :

| Profil | Longueur | Bitmask |
|---|---|---|
| `Administrators` | 64 | tous les bits à 1 |
| `API-Gateway-Providers` (système) | 21 | `111100101101100000001` |
| `banking-demo` | 21 | **copie exacte** du profil système |
| `insurance-demo` | 21 | **copie exacte** du profil système |
| `Default` | 0 | *(vide)* |

Deux conséquences directes :

1. **Les équipes de démonstration ont exactement les privilèges du profil
   système des fournisseurs** — aucun bit de différence. Elles n'ont jamais été
   restreintes ; le bitmask a été copié tel quel au bootstrap F4
   (`docs/superpowers/plans/2026-07-29-f4-teams-bootstrap.sh`).
2. **Le bitmask est opaque en REST.** Aucun endpoint ne nomme les privilèges :
   `/accessProfiles/privileges`, `/privileges`, `/permissions`,
   `/accessProfiles/permissions` → **404** les quatre. On ne peut donc pas
   dériver « quel bit porte la création d'API » d'une lecture de l'API d'admin.

**Protocole de décomposition retenu — nommer, puis prouver.** Les deux, parce
que ni l'un ni l'autre ne suffit :

- **Nommer** : la console d'administration liste les privilèges sous forme de
  cases nommées. Elle est de nouveau joignable depuis le correctif du
  2026-07-31 (`HANDOFF-2026-07-31-CONSOLE-WM-SESSION.md`) — le Service à
  réplique unique, sans quoi la session rebondit entre deux JVM. Une lecture de
  la console donne la correspondance bit → nom, qu'aucune mesure ne donnerait
  aussi vite.
- **Prouver** : la correspondance lue n'est pas une preuve d'effet. Le bit
  identifié est mis à 0 sur un accessProfile **jetable**, porté par un
  utilisateur jetable, et `POST /apis` est rejoué. Dix bits sont à 1
  (positions 0-3, 6, 8-9, 11-12, 20) : si le nom lu en console se révèle faux,
  une bisection sur ces dix bits tranche en quatre passes.

Rien n'est écrit sur `banking-demo` ni `insurance-demo` avant que le couple
(nom lu, effet mesuré) concorde sur le profil jetable.

**Fail-closed du changement lui-même** : après retrait, re-mesurer (a) `POST
/apis` par l'équipe → refusé ; (b) `GET /apis` scopé → **toujours** vert (sans
quoi P-1 tombe et l'isolation n'est plus démontrable) ; (c) l'identité sortante
de E2 → intacte. Si (b) ou (c) rougit, **remettre le bitmask** et consigner la
brèche comme dette assumée plutôt que de casser une preuve acquise. Le rollback
est un `PUT /accessProfiles/{id}` avec la valeur d'avant, capturée avant
d'écrire.

### D7 — `verify.yml` contrôle la team

`PUBLISH_CONFIRMED` s'étend : l'API est publiée, active, **et** portée par la
team attendue avec `Default` absente. En l'état il verdit sur une API visible de
toutes, ce qui est plus dangereux que pas de `verify` du tout — il atteste une
propriété qu'il ne contrôle pas.

Le `verify` rejoue la **même** garde que la convergence, dans le même fichier,
en lecture seule. Deux implémentations d'accord entre elles ne prouveraient rien
d'autre que leur accord.

### D8 — Le GOAL est corrigé, pas rafistolé

La porte E1 du GOAL est réfutée par la mesure. Elle doit être **remplacée**, en
disant que l'énoncé précédent était faux et pourquoi — pas rayée comme si elle
avait été tenue. Même traitement que le keepalive `*/25` du handoff F4
(« LA DETTE N'EXISTE PAS », consignée comme erreur corrigée). Retirer une porte
sans dire qu'elle ne mesurait rien laisserait croire qu'on l'a passée.

---

## 4. Périmètre

**Dans E1 :** les cinq portes, les huit décisions, le rôle `apim_publish_api`,
le job de publication, le dépôt d'équipe de démonstration, le GOAL et l'ADR-076
mis à jour.

**Hors E1, et pourquoi :**

- **Un SA k8s + un rôle Vault + un chemin KV par équipe.** Défense en
  profondeur réelle, mais qui n'ajoute rien tant que D2 tient : elle protège
  contre un pipeline malveillant, or D2 retire à l'équipe l'écriture du
  pipeline. Sa place est E5 (onboarding d'une équipe en une commande), où les
  trois objets se posent avec les autres.
- **La réconciliation hors chaîne** (relire `GET /apis`, comparer à l'origine,
  alerter sur écart). Détective, pas préventive ; couvre en revanche la dérive
  out-of-band, qui appartient à E6.
- **Le chemin direct** (équipe atteignant l'admin REST par le proxy E2) : il
  n'existe pas encore, et le fermer demande le service IS de préprocessing —
  même frontière que la garde 3 de E3.

---

## 5. Risques et limites (assumés)

- **La bascule de moteur retouche une chaîne verte.** F4 est prouvé avec
  `labctl` ; passer à Ansible invalide cette preuve jusqu'à ce que P-1 soit
  **rejouée**, pas supposée. C'est le coût de D1, et il se paie en mesure.
- **Retirer un bit de privilège peut casser P-1 ou E2.** D'où le rollback
  capturé avant écriture (D6). Le risque est réel : le bitmask n'a jamais été
  décomposé.
- **Le manifeste reste écrit par l'équipe.** La liste blanche est la seule
  barrière ; toute clé de service ajoutée plus tard doit y être inscrite
  *explicitement*, faute de quoi elle redevient injectable.
- **Deux répliques wM sans cluster.** Toute relecture, toute mesure
  d'autorisation vise le Service d'administration. Un 401 lu à travers
  `wm-apigateway` ne distingue pas un refus d'un cache froid — piège mesuré le
  2026-07-30, et qui a pollué trois passes d'une mesure de E3.
- **Cycle trial `*/20` par réplique.** Toute étape de la chaîne attend la santé
  de la gateway avant de consommer une identité, plutôt que d'échouer au milieu
  sur un « connection refused » cryptique (motif déjà présent dans les deux
  pipelines).
- **Le job inline n'est pas versionné.** Reconstructible, pas versionné — dette
  nommée en D2, à solder par JCasC.

---

## 6. Traçabilité

- Mesure du 2026-07-31 : matrice de refus par identité, gateway du cluster,
  Service d'administration, API jetable créée puis supprimée (`204`).
- État antérieur : F4 (`HANDOFF-2026-07-29-F4-CHAINE-PUBLICATION.md`,
  spec F4 §D1/D2), E3 (`GOAL-self-service-api-app-2026-07-09.md` § E3, gestes 1
  et 2 du 2026-07-31).
- Code visé : `ansible/roles/apim_publish_api/` (tasks `main`, `team`,
  `resolve-env`, `verify`), `ci/` (job de publication),
  `docs/superpowers/plans/2026-07-29-f4-jenkins-publish-job.xml`.
