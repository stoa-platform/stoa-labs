---
title: "SPEC G3 — La référence de déploiement, portée jusqu'aux dépôts d'équipe"
type: spec
status: "Cadrée le 2026-08-26 sur relevé du dépôt. Trois décisions de conception tranchées avec l'exploitant (écrivain, digest, résolveur). À relire avant plan d'implémentation."
date: 2026-08-26
goal: GOAL-cd-promotion-5-envs-2026-08-26.md
jalon: G3
lié: [adr-076-gitops-api-lifecycle-repo-per-project, adr-079-deploiement-promotion-multienv-import-archive, adr-081-ou-vit-la-decision-humaine]
---

# SPEC G3 — La référence de déploiement dans les dépôts d'équipe

## 1. Ce que le relevé a mesuré (2026-08-26)

Quatre faits qui cadrent le travail, tous vérifiés dans le dépôt :

1. **Le squelette d'un dépôt d'équipe *est* `clients/_example/`.** `scripts/team-apply.sh:149` fait
   `cp -R clients/_example/. "$SK/"` puis pousse. Un dépôt d'équipe porte donc `apis/<name>.publish.yml`,
   `apis/<name>.promote.yml`, `apis/<name>.openapi.yaml`, `applications/`, et — depuis G1 —
   `environments.yaml`. Il ne porte **pas** la disposition `apis/{slug}/api.yaml` des pilotes
   `accounts-team`/`payments-team`, qui sont explicitement hors livrable
   (`DELIVERY-PROCESS.md:24`, « seul le **gabarit** part »).
2. **`deploy.<env>.yaml` n'existe que côté monorepo de gouvernance.** Écrit par
   `handlers_promotions.go:155` dans une branche de promotion, chemin
   `tenants/{tenant}/apis/{slug}/deploy.{env}.yaml` (`store.go:122`), relu par `ResolvePinned`
   (`pinned.go:33`) via `git show <commit>:<chemin relatif>` — donc **dans le même dépôt**, ce qui
   se transpose sans machinerie nouvelle.
3. **Le digest d'archive n'existe nulle part.** Zéro occurrence de `sha256`/`digest`/`checksum` dans
   `ansible/roles/apim_promote_api/` comme dans `labctl/`. `apim_promote.archive`
   (`defaults/main.yml:39`) n'est qu'un **chemin de fichier** : destination à l'export, source à
   l'import. Aucun dépôt d'artefacts n'existe, malgré la mention en commentaire.
4. **Rien ne promeut au-delà de dev.** `team-publish.sh:75` fige `ENVN="${ENVN:-dev}"`, avec le
   commentaire ligne 73 : `api/<name>-<version>` ne porte aucun axe d'environnement.

## 2. Décisions de conception

Trois forks tranchés avec l'exploitant, plus deux décidés ici et signalés comme tels.

| # | Question | Tranché | Conséquence |
|---|---|---|---|
| D1 | Qui écrit le marqueur ? | **Script self-service** (`api-promote-request.sh`), miroir d'`api-request.sh` | Aucun changement dans `governance-api` ; pas de registre `registry/projects.yaml` ; la porte reste jouée **au dispatch**, pas à la demande |
| D2 | Jusqu'où le digest ? | **Champ + vérification, obligatoire hors dev** | `archive_sha256` fail-closed dès la naissance ; le TRANSPORT des octets reste à G5 |
| D3 | Où vit la résolution ? | **Dans le CI, en amont des deux moteurs** | Une seule implémentation ; zéro dette G8 sur le pin ; refus mécaniquement antérieur au play |
| D4 | Emplacement du marqueur | `apis/<name>.deploy.<env>.yaml` | **Divergence assumée avec ADR-076 §1** (voir §3) |
| D5 | Ce que `commit` pinne | Un **SHA de commit**, tous les fichiers de l'API lus à ce SHA | `promote.yml` est pinné aussi — sans quoi la contre-épreuve est vacante (voir §3) |

**Pourquoi D1 plutôt que le poly-dépôt.** Étendre `governance.Repo` (aujourd'hui un unique
`OpenRepo(dir)`, `gitrepo.go:63`) à N dépôts d'équipe apporterait le refus **à la demande**
(`GATE_REFS_REQUIRED`, chaîne, `CONTRACT_MOVED`) — c'est le modèle prouvé. Le prix est
disproportionné pour G3 : abstraction de dépôt, authentification Gitea par dépôt, registre
`registry/projects.yaml` (prévu par ADR-076, inexistant), et toute la suite `handlers_promotions`
à rejouer. Le coût assumé de D1 est nommé : **une demande illégale s'ouvre puis échoue au dispatch,
au lieu d'être refusée d'emblée.** Les gardes d'entrée du §5 en récupèrent l'essentiel côté
formulaire — sans jamais prétendre que c'est équivalent, puisque ces gardes sont in-repo et donc
justiciables du même OWASP CICD-SEC-04 que le GOAL documente. La fermeture réelle reste G4.

**Pourquoi D3.** L'idiome existe déjà et il est verrouillé par un test : `team-publish.sh` résout
le chemin du contrat **hors du moteur** et le passe en extra-var, `resolve-env.yml:99` écrase ce que
le manifeste prétend porter, et `test-team-publish-wiring.sh:425-434` vérifie les deux côtés **et
leur ordre**. Faire porter le pin par les moteurs, au contraire, créerait deux implémentations de
la pièce dont dépend « qu'est-ce qui tourne exactement en homol » — la dette G8 sur son point le
plus critique. Et le GOAL l'exige par ailleurs : *« un refus de porte doit être mécaniquement
antérieur au play — jamais un simple ordre de stages dans un Jenkinsfile »*.

## 3. Le marqueur

### 3.1 Emplacement — divergence avec ADR-076

`apis/<name>.deploy.<env>.yaml`, à côté de `apis/<name>.publish.yml` et `apis/<name>.promote.yml`.

ADR-076 §1 dessine `deploy.{env}.yaml` **à la racine** du dépôt projet. Cette racine supposait
« un dépôt = un projet = une API ». Le squelette réellement posé porte `apis/` **et**
`applications/`, au pluriel : à la racine, deux APIs du même dépôt se disputeraient le même
fichier. Le nom plat suit la famille déjà en place (`.publish.yml`, `.promote.yml`,
`.openapi.yaml`) et reste trivialement globbable.

**À trancher à la relecture :** soit ADR-076 §1 est amendé sur ce point, soit la spec s'aligne sur
la racine et interdit les dépôts multi-API. La première branche est recommandée — le squelette
livré a déjà choisi le pluriel.

### 3.2 Schéma

Champs repris de `governance.Deployment` (`store.go:65`), plus un.

```yaml
# apis/accounts-read.deploy.rec.yaml
version: "1.0.0"           # version promue (contrôle croisé avec le manifeste lu au SHA)
enabled: true
promoted_by: alice         # identité du DEMANDEUR (l'approbation vit ailleurs)
message: "promotion dev → rec"
commit: 9f3c1ab...         # LE PIN : un SHA de commit du dépôt d'ÉQUIPE
change_ref: ""             # ancre anti-TOCTOU de la garde ITSM au dispatch (A6)
archive_sha256: "e3b0c4..." # OBLIGATOIRE dès que env != dev
```

### 3.3 Ce que `commit` pinne — et pourquoi ce n'est pas « le SHA de publish.yml »

Le GOAL écrit « pinnant le SHA de `apis/<name>.publish.yml` ». La spec pinne **un SHA de commit**,
et **tout fichier de cette API est lu à ce SHA** : `publish.yml`, `promote.yml`, `openapi.yaml`.
Deux raisons :

1. **Hors de dev, le verbe est l'import d'archive** (ADR-079), piloté par `promote.yml` — pas par
   `publish.yml`. Pinner le seul `publish.yml` laisserait les alias backend, le GUID et le
   scope-mapping suivre HEAD : le contrat serait figé et la configuration de déploiement, elle,
   dériverait. La contre-épreuve de G3 (« pousser un commit sur main ⇒ rec reste au pin »)
   passerait au vert **sans rien prouver**, puisque le commit poussé pourrait n'affecter que
   `promote.yml`.
2. `git show <commit>:<chemin>` accepte n'importe quel commit — c'est exactement ce que fait déjà
   `ResolvePinned` (`pinned.go:33`). Un SHA, N fichiers, aucune machinerie nouvelle.

La valeur écrite est **le dernier commit de `main` touchant `apis/<name>.*`**, pas HEAD : le pin
d'`accounts-read` ne bouge pas quand l'équipe modifie `payments-read` dans le même dépôt.

### 3.4 dev ne porte jamais de marqueur

Règle déjà en vigueur côté gouvernance (`pinned.go:15` : *« publish writes no pin: the entry
environment follows HEAD by design »*). dev est l'environnement d'authoring — le seul où le blip de
première création est toléré (ADR-079), donc le seul qui suit HEAD. Un marqueur `deploy.dev.yaml`
n'est pas une erreur, il est simplement sans objet ; la spec ne l'écrit pas et ne le lit pas.

## 4. Le résolveur — `scripts/lib/deploy-pin.sh`

Infrastructure partagée, sur le modèle d'`env-chain.sh` (G1) et `gitea-pr-comment.sh`. Une
fonction, `resolve_deploy_pin <clone> <api> <env> <workdir>`, qui **matérialise** les fichiers
résolus et exporte leurs chemins. Les moteurs ne voient que des chemins ; aucun des deux ne sait
ce qu'est un pin.

```
lit   apis/<name>.deploy.<env>.yaml   AU SHA MERGÉ         (l'état revu, jamais le payload)
puis  git show <commit>:apis/<name>.promote.yml   ->  <workdir>/<name>.promote.yml
      git show <commit>:apis/<name>.publish.yml   ->  <workdir>/<name>.publish.yml
      git show <commit>:apis/<name>.openapi.yaml  ->  <workdir>/<name>.openapi.yaml
```

### 4.1 Refus nommés, tous fail-closed

| Refus | Ce qu'il ferme |
|---|---|
| `PIN_ABSENT` | marqueur absent pour un env != dev — aucun repli sur HEAD |
| `PIN_MALFORMED` | marqueur illisible ou `commit` vide/non-hexadécimal |
| `PIN_NON_ANCETRE` | `commit` n'est pas ancêtre de `origin/main` |
| `PIN_UNREADABLE` | `git show` échoue — erreur, jamais un repli silencieux (`pinned.go:15-16`) |
| `DIGEST_ABSENT` | `archive_sha256` vide alors que env != dev |
| `PIN_VERSION_MISMATCH` | `version` du marqueur != `version` du manifeste lu au SHA pinné |
| `ARCHIVE_ABSENT` | l'archive nommée par le `promote.yml` résolu est introuvable — le digest ne peut pas être vérifié, donc on ne promeut pas |
| `ARCHIVE_DIGEST_MISMATCH` | sha256 des octets != `archive_sha256` du marqueur |

### 4.2 `PIN_NON_ANCETRE` — la garde qui ne se devine pas

`team-publish.sh:246` porte déjà `MERGE_SHA_NON_ANCETRE`, avec ce raisonnement, vérifié : un
`git clone` **sans** `--depth 1` récupère toutes les branches, donc un `git show <sha>:<path>`
réussit sur un commit qui n'a jamais été mergé. Le pin est la même surface, **un cran plus bas** :
une PR de promotion irréprochable en apparence peut pinner un SHA vivant sur une branche jamais
revue, et le contenu déployé viendrait de là. Sans cette garde, le pin déplace la confiance du
merge vers un champ que le demandeur remplit lui-même.

Implémentation : `git -C <clone> merge-base --is-ancestor <commit> origin/main`.

### 4.3 Câblage

Les chemins résolus sont passés en extra-vars aux moteurs, jamais lus depuis le worktree :
`apim_ss_contract_pin` existe déjà (`ansible/roles/apim_publish_api/defaults/main.yml:69`,
`resolve-env.yml:99`) et sert au contrat ; deux extra-vars du même genre portent les manifestes
résolus, plus une pour le digest :

| Extra-var | Contenu | État |
|---|---|---|
| `apim_ss_manifest` | chemin du `publish.yml` résolu | **existe** (`team-publish.sh:342`, `apim_publish_api/resolve-env.yml:20`) |
| `apim_promote_manifest` | chemin du `promote.yml` résolu | **existe** (`apim_promote_api/resolve-env.yml:19-22`) |
| `apim_ss_contract_pin` | chemin du contrat résolu | **existe** (`apim_publish_api/defaults/main.yml:69`, `resolve-env.yml:99`) |
| `apim_ss_archive_sha256` | le digest pinné, propagé au moteur | **nouveau** |
| `apim_ss_authoring_env` | nom de l'env d'authoring (défaut `dev`) | **nouveau** |

**Les trois premières existent déjà** : les deux moteurs chargent leur manifeste par **chemin**
(`include_vars`, précédence 18 — jamais `-e @fichier`, qui masquerait la fusion `per_env`). Le
résolveur n'a donc rien à inventer côté moteur : il produit des fichiers, et les vars qui les
désignent sont celles déjà en service. Seuls le digest et le nom de l'env d'authoring sont neufs.

Le rôle ne doit **jamais** retomber sur un chemin dérivé du manifeste lui-même.

## 5. L'écrivain — `scripts/api-promote-request.sh`

Moteur du formulaire « promouvoir une API », calqué structurellement sur `api-request.sh` : gardes
nommées **avant tout geste Git**, `team -> repo` lu dans `providers.<env>.yml` **sur Gitea main**
(jamais le worktree local), clone du dépôt d'équipe, branche, commit sous l'identité de service
`ci`, push par `GIT_CONFIG_COUNT/GIT_CONFIG_KEY_0/GIT_CONFIG_VALUE_0` (jamais de token en URL ni
en argv), PR par heredoc python, plan hors ligne commenté sur la PR.

**Entrées** (env, mappées depuis les paramètres du job) : `TEAM`, `API_NAME`, `FROM_ENV`, `TO_ENV`,
`MESSAGE`, `CHANGE_REF`, `PV_REF`, `ARCHIVE_SHA256`, `GITEA_TOKEN`, `GIT_REPO`.

**Gardes d'entrée, dans l'ordre :**

1. **Chaîne** — `TO_ENV` doit être le suivant de `FROM_ENV`, lu par `env_chain`
   (`scripts/lib/env-chain.sh`, livré en G1). Un saut `dev -> prod` n'est pas exprimable.
   Refus : `CHAINE_INVALIDE`.
2. **Refs de porte** — `change_ref` exigé si la porte d'arrivée porte `requireChangeRef` **ou**
   `itsmCheck` (il n'y a rien à vérifier sans lui) ; `pv_ref` exigé si `requirePVRef`. Miroir exact
   de `handlers_promotions.go:77-89`. Refus : `GATE_REFS_REQUIRED`.
3. **Digest** — `ARCHIVE_SHA256` obligatoire dès `TO_ENV != dev`, format `^[0-9a-f]{64}$`.
   Refus : `DIGEST_ABSENT` / `DIGEST_MALFORMED`.
4. **Source déployée** — `apis/<name>.deploy.<FROM_ENV>.yaml` présent et `enabled: true`.
   Exception : `FROM_ENV == dev`, où la présence de `apis/<name>.publish.yml` en tient lieu (dev
   n'a pas de marqueur, §3.4). Refus : `SOURCE_NON_DEPLOYEE`.

**Geste :** pin = dernier commit de `main` touchant `apis/<API_NAME>.*`
(`git log -1 --format=%H -- 'apis/<name>.*'`) ; écriture du marqueur ; branche
`promote/<name>-<TO_ENV>` ; commit ; push ; PR. Le script **n'importe rien** sur la gateway et ne
touche ni Vault ni la publication réelle : la décision reste le merge (ADR-081).

**Lecture de `environments.yaml` — corrigé à la livraison.** Ce paragraphe annonçait « celui du
**dépôt d'équipe** (posé par le squelette) ». C'est **impossible** : les gardes 1 et 2 tournent
*avant* le clone du dépôt d'équipe, par construction (le refus doit précéder tout geste Git). Ce
qui est réellement lu est le gabarit du **dépôt plateforme**
(`clients/_example/environments.yaml`, via `$STOA_ENV_CHAIN_FILE` sinon ce défaut). Une chaîne
cassée ou absente reste un refus fermé — `env-chain.sh` est fail-closed sur source
absente/vide/cassée.

**Trois sources, deux existent, et elles peuvent diverger.** L'écrivain lit le gabarit plateforme ;
`governance-api` — la porte réelle — lit `environments.yaml` sur `main` du dépôt **governance**
(`labctl/internal/governance/envchain.go`) ; `seed-governance-chain.sh` copie le gabarit vers
governance **une fois, dans un seul sens**. Une porte modifiée côté governance laisse donc les
gardes de l'écrivain sur une copie périmée : elles refusent **tôt**, elles ne font pas autorité.
Effet de bord assumé : `team-apply.sh` livre un `environments.yaml` dans chaque dépôt d'équipe, où
**rien ne le lit** aujourd'hui. Unifier la source est un item de G4.

Le point 2 des gardes d'entrée dit « miroir exact de `handlers_promotions.go:77-89` » : c'est vrai
de la **règle**, faux de la **source**.

## 6. Le digest, bout à bout

| Étape | Où | Quoi |
|---|---|---|
| Émission | `ansible/roles/apim_promote_api/tasks/export.yml` | `stat` avec `checksum_algorithm: sha256` **après** la sanitisation, affiché à côté d'`EXPORT_CONFIRMED` |
| Saisie | formulaire de promotion | le demandeur colle le digest, comme il colle déjà le `guid` |
| Pin | `apis/<name>.deploy.<env>.yaml` | `archive_sha256` |
| **Vérification 1 — CI** | `scripts/lib/deploy-pin.sh` | sha256 des octets de l'archive, comparé au pin, **avant** tout play ; refus `ARCHIVE_DIGEST_MISMATCH` |
| **Vérification 2 — moteur** | `ansible/roles/apim_promote_api/tasks/import.yml` | `assert` sur `apim_ss_archive_sha256` juste avant le POST |

**Pourquoi deux vérifications, et pourquoi ce n'est pas la duplication que D3 interdit.** D3
interdit de dupliquer la logique de **pin** (lire le marqueur, résoudre le SHA) — celle-là reste
unique, dans le CI. Le digest, lui, est vérifié deux fois pour deux raisons distinctes :

- **Côté CI**, parce que le GOAL exige qu'un refus soit *mécaniquement antérieur au play* : un
  digest faux ne doit pas lancer un play qui échouera, il doit empêcher le play.
- **Côté rôle**, parce que le rôle est le **livrable client** et qu'il tourne aussi **sans CI** :
  `DELIVERY-PROCESS.md` §3 définit les degrés D0 (runbook, l'opérateur joue les scripts) et D2
  (`ansible-playbook --tags`, sans orchestrateur). À ces degrés il n'y a **aucun** résolveur CI —
  une vérification qui n'existerait que dans le CI serait absente précisément là où l'opérateur
  agit à la main.

**La règle du rôle est fail-closed, pas « vérifie si on lui donne quelque chose ».** Un `assert`
qui ne se déclenche que si `apim_ss_archive_sha256` est non vide serait un fail-open : oublier
l'extra-var suffirait à désactiver le contrôle. La condition est donc l'environnement, pas la
présence de la variable — `apim_ss_env != apim_ss_authoring_env` (nouveau knob, défaut `dev`)
⇒ digest **exigé**, absent ⇒ refus `ARCHIVE_DIGEST_REQUIRED`.

**Ce que les deux vérifications tiennent, exactement.** Elles tiennent : *les octets importés
correspondent au digest pinné dans le marqueur du palier d'arrivée*.

Le digest reste **exigé au formulaire à chaque saut** (`DIGEST_ABSENT`) — `TO_ENV` ne peut jamais
valoir l'env d'authoring, qui est la tête de la chaîne, donc cette garde est inconditionnelle en
pratique. Hors env d'authoring, il n'est simplement plus **cru** : il est confronté à celui du
palier source, et une divergence refuse (`DIGEST_CONTREDIT_SOURCE`). Ce qui est écrit dans le
marqueur d'arrivée est celui du **palier source**. Le demandeur ne peut donc pas substituer les
octets en cours de route ; il peut seulement se tromper de recopie, et il est refusé.

**Ce qui tient l'arbitrage, c'est le REFUS, pas l'héritage** — l'héritage seul décrirait un
mécanisme qui ne se déclenche jamais.

### 6.1 Le chaînage — arbitré et fermé le 2026-08-26

**Ce qui était livré au premier jet, et pourquoi c'était faux.** Le pin venait du dernier `main` du
dépôt d'équipe, et `archive_sha256` était saisi au formulaire à chaque saut, indépendamment. Rien
ne comparait le palier N au palier N−1. Mesuré : rec servant v1.0.0 pendant que `main` porte
v2.0.0, une demande `rec → int` écrivait v2.0.0 — **un état que rec n'a jamais servi**, sans qu'aucune
garde ne rougisse. La chaîne à cinq paliers ne garantissait plus que homol a vu ce que int a vu.
Une version antérieure de ce paragraphe affirmait pourtant que la vérification « **force** la
réutilisation des mêmes octets d'un palier à l'autre » : c'était doublement faux.

**L'arbitrage.** La question — *une promotion peut-elle embarquer un état plus récent que le palier
source ?* — est d'exploitation, pas de revue. Elle a été posée à l'exploitant, qui a retenu le
**chaînage strict**. Le GOAL l'exigeait d'ailleurs déjà mot pour mot dans son test de réussite :
*« chaque palier recevant exactement l'archive approuvée et pas "le dernier main" »*.

**Ce qui est livré depuis.** `resolve_promotion_pin` (`scripts/lib/deploy-pin.sh`) porte les deux
régimes :

| Saut | Pin | Digest |
|---|---|---|
| depuis `dev` (env d'authoring, sans marqueur) | dernier commit de `main` touchant **cette** API | saisi au formulaire (sortie `EXPORT_CONFIRMED`) |
| tout autre saut | `commit` du marqueur **source** | `archive_sha256` du marqueur **source** |

La version est relue **au commit retenu**, jamais sur l'arbre de travail — sinon on écrirait la
version de `main` à côté d'un pin qui désigne autre chose. Un digest de formulaire qui
contredirait celui du palier source est refusé (`DIGEST_CONTREDIT_SOURCE`) : un saut ne substitue
pas les octets en cours de route. Un pin source mal formé est refusé (`SOURCE_PIN_MALFORMED`) et
**ne retombe jamais sur `main`** — ce serait rouvrir le défaut par la porte de service.

**Conséquence assumée :** une correction ne saute aucun palier ; elle re-traverse depuis `dev`.
C'est le prix de la garantie, et c'est ce qui rend la chaîne opposable plutôt que déclarative.

**Éprouvé** : ㉑, ㉑bis, ㉑ter, ㉑quater dans `scripts/test-deploy-pin.sh`, sur dépôt Git jetable.
Contre-épreuve par mutation : rétablir le calcul depuis `main` fait rougir cinq assertions.

**Hors périmètre, explicitement :** le **transport** de ces octets d'un palier à l'autre (dépôt
d'artefacts, registre de paquets) appartient à G5, qui porte le verbe archive. G3 livre le lien
vérifiable entre ce qui a été approuvé et ce qui sera importé — pas le magasin.

## 7. Preuve et contre-épreuves

`scripts/test-deploy-pin.sh`, sur un dépôt Git **réel et jetable** (`mktemp -d`), rejouable hors
ligne, sans gateway ni Vault :

| # | Épreuve | Verdict attendu |
|---|---|---|
| 1 | Marqueur pinnant C1 ; `main` avancé à C2 | le manifeste résolu est celui de **C1** |
| 2 | Idem, C2 ne touchant que `promote.yml` | `promote.yml` résolu est celui de **C1** (garde D5) |
| 3 | Marqueur absent, env != dev | `PIN_ABSENT` |
| 4 | `commit` non hexadécimal / marqueur cassé | `PIN_MALFORMED` |
| 5 | `commit` vivant sur une branche non mergée | `PIN_NON_ANCETRE` |
| 6 | `commit` inexistant | `PIN_UNREADABLE` |
| 7 | `archive_sha256` vide, env != dev | `DIGEST_ABSENT` |
| 8 | `version` du marqueur != version du manifeste au SHA | `PIN_VERSION_MISMATCH` |
| 9 | Digest ne correspondant pas aux octets | `ARCHIVE_DIGEST_MISMATCH` (côté CI) |
| 10 | Câblage : les extra-vars résolues sont passées, et le rôle les honore | modèle du test 17 (`test-team-publish-wiring.sh:425-434`), **les deux côtés** |
| 11 | Gardes d'entrée de l'écrivain : chaîne, refs de porte, digest, source | un refus par garde, aucun geste Git derrière |
| 12 | Rôle joué **sans** `apim_ss_archive_sha256` sur `apim_ss_env != dev` | `ARCHIVE_DIGEST_REQUIRED` — la garde du degré D0/D2 (§6) ; hors ligne par `--syntax-check` + play d'assert isolé |

**Contre-épreuve de la preuve elle-même** (motif F1 du GOAL socle : *une parité qui ne rougit
jamais ne prouve rien*) : le script joue un **sabotage** — retirer la garde
`merge-base --is-ancestor` du résolveur doit faire **rougir** l'épreuve 5, avec restauration
inconditionnelle par `trap`. Sans ce sabotage, l'épreuve 5 pourrait passer au vert pour la mauvaise
raison (par exemple un `git show` qui échoue de lui-même sur ce dépôt de test).

**Piège de porte à ne pas reproduire, mesuré en G1 :** `go test` rend `ok (cached)` après un
relâchement de porte quand le fichier saboté vit hors du module. Ici tout est shell, donc le piège
ne s'applique pas — mais la règle qui en découle si un test Go est ajouté plus tard : `-count=1`
obligatoire, et le sabotage joué, jamais supposé.

### 7.1 Ce que G3 ne prouve PAS — limite énoncée, pas découverte

La porte du GOAL dit : *« l'apply en rec projette ce contrat, pas le dernier main »*. **Elle n'est
pas exerçable E2E dans G3**, et c'est délibéré :

- `team-publish.sh:75` fige `ENVN="${ENVN:-dev}"`. **Lever ce verrou est le sujet de G4**, qui le
  remplace par la rétention de credential (policies Vault par palier). Le lever ici livrerait la
  moitié de G4 **sans** son remplacement : un contrôle retiré contre rien.
- Le verbe d'apply hors dev est l'import d'archive, branché par **G5**.

G3 livre donc : le marqueur, le résolveur avec ses refus nommés, le digest bout à bout, l'écrivain, et
une preuve N/N **sur dépôt Git réel** plus la preuve de câblage. La démonstration bout-en-bout
`dev -> rec` est la porte de **G4+G5**, où elle sera rejouée avec ce résolveur tel quel.

## 8. Inventaire des livrables

| Fichier | Nature |
|---|---|
| `scripts/lib/deploy-pin.sh` | nouveau — le résolveur et ses refus |
| `scripts/api-promote-request.sh` | nouveau — l'écrivain (formulaire de promotion) |
| `scripts/test-deploy-pin.sh` | nouveau — la preuve N/N + contre-épreuves |
| `ci/Jenkinsfile.api-promote-request` | nouveau — le job du formulaire (déclaratif, cf. dette « 3 jobs encore en Groovy inline ») |
| `clients/_example/apis/accounts-read.deploy.rec.yaml.example` | nouveau — le gabarit documenté du marqueur |
| `ansible/roles/apim_promote_api/tasks/export.yml` | modifié — émission du sha256 après sanitisation |
| `ansible/roles/apim_promote_api/tasks/import.yml` | modifié — `assert` fail-closed du digest (degrés D0/D2) |
| `ansible/roles/apim_promote_api/defaults/main.yml` | modifié — `apim_ss_archive_sha256`, `apim_ss_authoring_env` |
| `adr/adr-076-...md` | modifié — amendement §1 sur l'emplacement du marqueur (si D4 est confirmé) |

## 9. Questions ouvertes

1. **D4 / ADR-076 §1** — amender l'ADR sur l'emplacement du marqueur, ou aligner la spec sur la
   racine et interdire les dépôts multi-API ? (recommandation : amender)
2. **Les applications** — `applications/` du squelette ne reçoit aucun marqueur dans cette spec.
   Le GOAL G3 ne parle que d'APIs. À confirmer comme hors périmètre.
3. **Le job de promotion** — un formulaire par saut, ou un formulaire unique avec `TO_ENV` en
   liste ? La liste déroulante d'un `parameters {}` déclaratif est évaluée **à la pose du job**,
   hors workspace (piège mesuré en G1, `ci/Jenkinsfile.selfservice:34`) : elle ne peut pas dériver
   d'`environments.yaml`. Elle restera donc écrite à la main, comme l'autre.
