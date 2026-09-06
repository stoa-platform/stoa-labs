---
title: "P2 — la posture entre dans la chaîne du producteur : la demande déclare, le registre central décide, et le refus arrive sur la PR"
type: handoff
jalon: P2
goal: GOAL-posture-par-exposition-2026-09-04.md
adr: adr/adr-092-posture-dans-la-chaine-du-producteur.md
date: 2026-09-05
preuve: "labctl : go vet propre, go test ./... 545 ✅ / 0 ❌ (21 épreuves neuves) ; matrice P2 scripts/test-p2-posture-producteur.sh 67 ✅ / 0 ❌ (dont le BOUT EN BOUT sur le Gitea du lab et 4 mutations sur 4 rouges) ; non-régression scripts/test-api-request.sh 28 ✅ / 0 ❌ ; câblage scripts/test-api-request-wiring.sh 55/55 ; make lint-ci vert, SANS aucune ligne ajoutée à la dette de knobs."
status: "LIVRÉ. La porte et la contre-épreuve sont tenues sur des dépôts RÉELS (PR réelles, commentaires réels). UN geste reste, et il appartient à l'humain : servir gitea/origin pour qu'un BUILD JENKINS réel rejoue la même chose depuis le formulaire."
---

# P2 — ce qui a été livré, et ce qu'il faut savoir avant P3

## La prise du jour : le vrai sujet n'était pas de transporter deux champs

Le jalon se lit « le formulaire collecte, le manifeste porte, le rôle lit ». Fait comme ça, c'est une demi-journée de plomberie — et une régression de conception. Parce que **la question de P2 n'est pas où la posture voyage, c'est qui la tranche**, et P0 avait déjà répondu : la gateway ne protège **aucun** de ses champs en écriture. Une posture inscrite sur l'API n'est donc pas une garantie, c'est un miroir.

Le mécanisme d'autorité existait déjà (registre central, goal A5) mais **la chaîne producteur ne l'appelait nulle part** : elle vit en bash et en Ansible, et la table de vérité vit en Go. La tentation évidente — réécrire la comparaison en Jinja — aurait été la **cinquième recopie** du vocabulaire que P1 venait de supprimer, et sur l'axe le plus piégeux : l'exposition n'est pas une échelle, donc aucun rang ne l'exprime.

**Ce qui a été fait à la place : une commande.** `labctl posture` expose au shell la fonction que `labctl apply` exécute déjà (`resolveCentralClassification`), avec les mêmes codes. Trois appelants — la garde d'entrée, le plan de la PR, le rôle — une implémentation.

**Réflexe à garder :** quand une chaîne écrite dans un langage a besoin d'une décision qui vit dans un autre, la bonne réponse est presque toujours *appeler*, pas *réécrire*. Le coût d'une commande de plus est visible ; celui d'une règle dupliquée ne l'est que le jour où les deux divergent.

## Ce qui a changé

| Fichier | Changement |
|---|---|
| `labctl/cmd/labctl/posture.go` | **neuf** — la commande d'autorité : `--project/--api/--declared-*/--classification-source`, texte greppable ou JSON, codes inchangés |
| `labctl/cmd/labctl/enforce.go` | `resolveCentralClassification` gagne `tenantClaimed` ; **vocabulaire de la demande vérifié AVANT `Weaker`** (voir plus bas) ; tenant résolu rendu à l'appelant |
| `labctl/internal/render/schema_drift_test.go` | le formulaire Jenkins devient le **second miroir épinglé** (`TestProducerFormVocabularyDoesNotDrift`) |
| `ci/jenkins/api-request.job.xml` | deux listes : `CLASSIFICATION` (VH/H/M), `EXPOSURE` (internal/external/internet) |
| `ci/Jenkinsfile.api-request` / `.team-publish` | routage `withEnv` des deux valeurs BRUTES ; knobs `GOVERNANCE_REPO` / `GOVERNANCE_PATH` / `LABCTL_BIN`, **sans défaut de lab** |
| `gateways/templates/publish.yml.tmpl` | `apim_api.classification` / `apim_api.exposure` |
| `scripts/api-request.sh` | §1b gardes de posture (présence, classe, vocabulaire **demandé à l'autorité**) ; §2a clone du registre ; §5b arbitrage central **dans le plan** ; verdict et posture relayés au commentaire de PR |
| `scripts/team-publish.sh` | §4b clone du registre (dépôt séparé, fail-closed) ; `-e apim_pub_classification_source` au rôle ; `POSTURE_RETENUE` remontée au ✅ de la PR |
| `ansible/roles/apim_publish_api/tasks/posture.yml` | **neuf** — la garde du rôle, avant les secrets et avant le premier appel gateway |
| `ansible/test-posture-guards.yml` | **neuf** — la même garde, jouable hors ligne |
| `scripts/lib/posture-authority.sh` | **neuf** — résout le binaire d'autorité pour les harnais (build du dépôt > PATH) |
| `scripts/test-p2-posture-producteur.sh` | **neuf** — la matrice du jalon (A→H) |

## Trois décisions de conception qui méritent d'être connues

### 1. Le refus de gouvernance arrive APRÈS l'ouverture de la PR — délibérément

La contre-épreuve du GOAL dit « relayé jusqu'à la PR ». Une PR qui n'existe pas ne porte aucun commentaire. L'arbitrage central est donc **au plan**, pas à la garde d'entrée. La ligne de partage retenue :

- défaut de la **demande** (champ vide, valeur inconnue) → refus **avant tout geste Git** ;
- panne d'**infrastructure** (registre injoignable, binaire absent) → refus **avant tout geste Git** aussi : ouvrir une PR pour y coller un ❌ ferait porter le chapeau au demandeur ;
- désaccord avec la **gouvernance** (downgrade, API non enregistrée) → PR ouverte, refus **dans son commentaire**.

Piège concret rencontré : `LABCTL_CLASSIFICATION_SOURCE` est aussi lue par `labctl posture` depuis l'**environnement**. Un nœud Jenkins qui la porterait ferait consulter le registre **dès la garde d'entrée** — et une API pas encore enregistrée (le cas normal d'un `create`) serait refusée avant qu'aucune PR n'existe. L'appel d'entrée vide donc explicitement les deux jumelles d'environnement. Une épreuve le vérifie.

### 2. Le tenant : ne pas réclamer n'est pas mentir

Le manifeste de publication ne déclare pas de tenant (l'équipe est son unité de cloisonnement). Le contrôle de tenant de `labctl apply` aurait alors refusé **chaque** appel du producteur. La réponse n'est pas d'affaiblir le contrôle mais de le rendre **explicite** : `resolveCentralClassification(c, tenantClaimed)`. `apply` passe `true` sans condition — un `api.yaml` qui *supprime* `tenant_id` reste un spoof, et une épreuve neuve l'épingle. `posture` passe `false` quand rien n'est réclamé : l'ancre anti-spoof reste le couple `(équipe, api)`, que personne ne peut éditer. Le tenant gouverné est **rendu** et journalisé.

### 3. Une valeur inconnue n'est pas un downgrade

`Weaker()` est fail-closed : ce qu'il ne sait pas dériver, il le déclare « plus faible ». Le verdict restait juste (refus) mais le **message** accusait un downgrade quelqu'un qui avait simplement tapé `dmz`. Corrigé : le vocabulaire de la demande est vérifié **avant** la comparaison, et le refus nomme la vraie cause (`INTEGRITY_INCONSISTENT`, avec la valeur fautive citée). Trouvé par la matrice, pas par relecture.

## La méthode : quatre mutations, et deux témoins qui mentaient

Tout était vert au premier jet de la matrice — sauf que six cas ont rougi pour de bonnes raisons (dont les deux ci-dessus). Puis les **mutations** ont trouvé ce que les assertions ne voyaient pas :

| sabotage | ce qui tombe |
|---|---|
| le registre n'atteint plus l'autorité | la garde `source == central` du rôle |
| la garde de présence accepte une posture vide | le refus cesse d'être **nommé** `POSTURE_MANQUANTE` |
| `CLASSIFICATION` n'est plus obligatoire | `CHAMP_REQUIS : CLASSIFICATION` disparaît |
| le gabarit ne porte plus la classification | le manifeste rendu ne déclare plus de posture |

**Deux pièges de harnais, payés ici :**

1. **Un témoin de mutation vérifié par un `grep` de la ligne qu'on vient de retirer est circulaire** — il prouve sa propre présence, pas qu'elle porte quelque chose. Les quatre témoins sont donc des épreuves de **comportement**, et le harnais exige qu'elles soient **vertes avant** le sabotage : sans quoi leur rouge d'après ne dirait rien. Deux mutations sur quatre ont d'abord été rejetées par cette règle.
2. **`set -o pipefail` + `cmd | grep -q` sur une commande qui REFUSE** : le pipeline rend le code de `cmd`, jamais celui de `grep`. Les deux témoins concernés étaient rouges en permanence — donc muets. Capturer la sortie en variable, puis grepper. (Piège déjà payé en A4 ; il revient dès qu'on observe un refus.)
3. **La garde `POSTURE_MANQUANTE` n'est pas le seul rempart** : `labctl` refuse aussi une classification vide. Ce qu'elle ajoute est le **nom**. Le témoin porte donc sur le nom, pas sur le simple fait qu'il y ait un refus — sinon la mutation passe pour « non détectée » alors qu'un message vient d'être perdu.

## Les conséquences à annoncer au client

1. **Une API absente du registre ne peut plus être publiée.** C'est le comportement gouverné voulu, mais il déplace un préalable dans le parcours : la **PR gouvernance précède la première demande**. Le commentaire de PR le dit ; le runbook doit le dire aussi.
2. **`GOVERNANCE_REPO` / `GOVERNANCE_PATH` n'ont aucun défaut.** Absents, la chaîne refuse en se nommant. C'est la porte `ci/lint-config-knobs.sh` qui l'exige, et elle a raison ici plus qu'ailleurs : un repli de lab ferait arbitrer la posture contre une gouvernance qui n'est pas celle du client, **sans le dire**. Les poser en variables globales du contrôleur : `scripts/setup-jenkins-globals.sh`.
3. **`exposure=internet` reste rouge à l'apply** (écart #1 d'ADR-091, inchangé). La chaîne sait le déclarer, le gouverner et le refuser ; elle ne sait toujours pas le déployer.

## Ce qui reste, et qui appartient à l'humain

- **Servir gitea/origin.** Rien n'est committé ni poussé. Tant que le dépôt plateforme n'est pas servi, le job `api-request` du lab checkoute l'ancien script : le **BUILD JENKINS** réel ne peut pas rejouer la porte. Tout le reste de la porte EST prouvé sur des dépôts réels (PR et commentaires réels, section G de la matrice) — c'est le même script, lancé par la même commande que le job (`bash scripts/api-request.sh`).
- **Après la mise à disposition** : re-poser le formulaire (`scripts/setup-team-onboard-jobs.sh`, JOBS="api-request") pour que les deux listes apparaissent, poser les deux globales, puis rejouer `scripts/test-producer-chain.sh` (qui archive `HEAD`, donc exige le commit) — il seede désormais son propre registre scratch et passe `GOVERNANCE_REPO` au job.
- **Le lab n'a PAS été muté** : le `labctl` du conteneur Jenkins date du 2026-07-02 et ne connaît pas `posture`. À remplacer au moment de servir le dépôt, sinon la chaîne refusera `POSTURE_AUTORITE_ABSENTE` — un refus juste, mais qui accuserait le socle.
- **Le registre du lab ne gouverne que `accounts-team` et `payments-team`**, alors que la seule équipe de `providers.dev.yml` portant un dépôt est `banking-demo`. Une ligne à ajouter côté gouvernance avant toute demande réelle sur le lab.

## Ce qui attend P3

- Le tag dérivé se pose sur `apiDefinition.tags` par `PUT /apis/{id}` — **pas** `apiTags`, mort (P0). Et **tout** `PUT` de définition sans `tags` l'efface, `overwriteTags=false` compris.
- La posture EFFECTIVE est déjà disponible dans le rôle sous `pub_posture` (fait Ansible : `classification`, `exposure`, `bundle`, `authn`, `required_policies`, `tenant`, `source`). P3 n'a donc rien à re-résoudre : le tag se dérive de `pub_posture.bundle`, jamais du manifeste.
