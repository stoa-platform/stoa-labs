# HANDOFF — G3 : la référence de déploiement, portée aux dépôts d'équipe

**Session du 2026-08-26.** Branche `provision/probe-dev`, **42 commits**, rien n'est poussé
(ni `origin`, ni `gitea`). Arbre propre. Toutes les portes au vert.

| Porte | Résultat |
|---|---|
| `scripts/test-deploy-pin.sh` *(nouvelle)* | **60 / 0** |
| `scripts/test-team-publish-wiring.sh` | **116 / 116** |
| `scripts/test-env-chain.sh` | **4 / 0** |
| `scripts/test-jenkinsfile-lint.sh` | **13 / 13** |
| `make lint-ci` | vert `[1/4]`→`[4/4]`, `shellcheck rc=0` |

---

## À LIRE EN PREMIER — une décision t'attend, et elle bloque G4

**Le pin ne pinne pas ce que tu crois pour un saut au-delà du premier.**

`scripts/api-promote-request.sh:208` calcule la référence ainsi :

```bash
PIN=$(git -C "$TMP/team" log -1 --format=%H -- "apis/${API_NAME}.*")
```

C'est **le dernier commit de `main`** — jamais « ce que le palier source exécute ». La garde de
source, juste au-dessus, ouvre bien le marqueur du palier de départ… et n'en lit que `enabled` :
son `commit` et son `archive_sha256` ne sont lus par personne.

**Mesuré** par la revue finale, sur dépôt jetable :

```
C1  accounts-read v1.0.0    ← ce que le marqueur rec pinne, ce que rec SERT
C2  marqueur deploy.rec.yaml
C3  accounts-read v2.0.0    ← poussée sur main, JAMAIS déployée en rec
```

Une demande `rec → int` retient `PIN = C3` et écrit `version: 2.0.0` dans le marqueur `int`.
La PR annonce « promotion rec → int », l'approbateur merge, **int reçoit un état que rec n'a
jamais servi**. Rien ne rougit, à aucun étage. Idem homol, idem prod.

Le défaut est dans la **spécification**, pas dans le code : `design.md` §3.3 ne raisonne que sur
`dev → rec`, où « le dernier `main` » et « ce que dev exécute » coïncident par construction. Le
cas N > 1 n'y est traité nulle part.

**Le correctif fait ~10 lignes** (lire `commit` dans le marqueur source quand
`FROM_ENV != dev`, et refuser si `main` a divergé). **Mais la question est la tienne, pas la
mienne** : *une promotion peut-elle embarquer un état plus récent que le palier source ?*
Il y a de bonnes raisons de répondre oui (rattraper un correctif sans repasser par rec) comme
non (la chaîne à cinq paliers ne garantit plus rien). Je ne l'ai pas tranchée.

**Corollaire, déjà corrigé dans la doc.** Trois textes affirmaient mot pour mot que le digest
« FORCE la réutilisation des MÊMES octets d'un palier à l'autre… c'est ce qui distingue
*build once, deploy many* d'une intention ». **C'est faux tel que livré** : le digest n'est pas
chaîné d'un palier à l'autre, et un demandeur qui ré-exporte depuis la gateway source obtient un
zip neuf (horodatages) dont il colle le digest — la vérification passe. La propriété réellement
tenue est *les octets importés correspondent au digest que le demandeur a écrit*. Les trois
textes (`scripts/lib/deploy-pin.sh`, le gabarit, `design.md` §6) énoncent maintenant la propriété
réelle et **nomment** les deux dissymétries. Ne pas réintroduire l'affirmation.

---

## Ce qui est livré

**Avant tout : G1 a été committé** (`ec04970`). Ses livrables — `clients/_example/environments.yaml`,
`scripts/lib/env-chain.sh`, `envs/homol/`, les deux portes de preuve — étaient **non trackés**,
et G3 s'appuie dessus. Une worktree fraîche n'aurait rien compilé. Ses portes étaient vertes
(4/4, 12/12) avant que je le fasse.

### Le marqueur

`apis/<name>.deploy.<env>.yaml`, à côté de `apis/<name>.publish.yml`. Sept champs ; `commit` est
un **SHA de commit**, pas le SHA d'un fichier — donc `publish.yml`, `promote.yml` **et**
`openapi.yaml` sont relus à ce commit. Pinner le seul contrat aurait laissé les alias backend, le
GUID et le scope-mapping suivre `main` : le contrat figé, la configuration de déploiement en
dérive, et la contre-épreuve verte sans rien prouver.

`dev` ne porte **jamais** de marqueur : c'est l'env d'authoring, il suit HEAD par conception
(`labctl/internal/uac/pinned.go:15`).

**Divergence assumée avec ADR-076 §1**, qui dessinait le marqueur à la racine. Cette racine
supposait « un dépôt = une API » ; le squelette réellement livré porte `apis/` **et**
`applications/`, au pluriel. L'ADR est amendé, avec la raison écrite.

### Le résolveur — `scripts/lib/deploy-pin.sh`

Il lit le marqueur **au SHA mergé**, matérialise les manifestes **au SHA pinné** par `git show`,
et vérifie le digest. Il vit **dans le CI, en amont des deux moteurs** : aucun moteur ne porte de
logique de pin, et un refus est mécaniquement antérieur au play.

Refus nommés, tous fail-closed : `PIN_ABSENT`, `PIN_MALFORMED`, `PIN_NON_ANCETRE`,
`PIN_UNREADABLE`, `PIN_VERSION_MISMATCH`, `PROMOTE_MANIFEST_ABSENT`, `ARCHIVE_ABSENT`,
`ARCHIVE_PATH_RELATIVE`, `ARCHIVE_UNREADABLE`, `ARCHIVE_DIGEST_MISMATCH`, `DIGEST_ABSENT`,
`API_NAME_INVALIDE`, `ENV_INVALIDE`, `WORKDIR_INCREABLE`.

**`PIN_NON_ANCETRE` est la garde qui ne se devine pas.** Un `git clone` sans `--depth 1` récupère
**toutes** les branches, donc `git show <sha>:<path>` réussit sur un commit jamais mergé. Sans
elle, le pin déplace la confiance du merge vers un champ que le demandeur remplit lui-même.

### L'écrivain — `scripts/api-promote-request.sh`

Moteur du formulaire de promotion, calqué sur `api-request.sh`. Gardes **avant tout geste Git** :
chaîne (`env_chain_gate`, nouvelle fonction publique d'`env-chain.sh`), références exigées par la
porte d'arrivée, digest, palier source déployé. `team → repo` lu sur **Gitea `main`**, jamais le
worktree. Aucun token en argv ni en URL. Le marqueur est écrit par `yaml.safe_dump` — **pas** par
formatage de chaîne, voir plus bas pourquoi.

Il ne déploie rien : la décision est le merge.

### Le digest, bout à bout

`export.yml` l'émet **après** la sanitisation (un digest des octets bruts pinnerait des octets que
personne ne déploie) ; le CI le vérifie avant tout play ; `import.yml` le re-vérifie sur les octets
qu'il s'apprête à POSTer. **Deux fois, délibérément** : `DELIVERY-PROCESS.md` §3 définit les degrés
D0 (runbook) et D2 (`ansible-playbook` sans orchestrateur), où il n'y a **aucun** CI. Une garde qui
ne vivrait que dans le CI serait absente là où l'opérateur agit à la main.

### Le reste

`ci/Jenkinsfile.api-promote-request` (avec son bloc `environment{}` — le point de bascule client
qui évite de forker le fichier) ; `make lint-ci` shellchecke enfin les trois livrables shell ;
`clients/_example/apis/accounts-read.deploy.rec.yaml.example` part dans chaque nouveau dépôt
d'équipe via `team-apply.sh`.

---

## Ce que G3 ne prouve PAS, et c'est voulu

- **Le verrou dev-only n'est pas levé.** `scripts/team-publish.sh:82` garde `ENVN="${ENVN:-dev}"`.
  C'est **G4**, qui le remplace par la rétention de credential. Le lever ici aurait livré la
  moitié de G4 sans son remplacement : un contrôle retiré contre rien. Une épreuve vérifie qu'il
  est intact.
- **Donc « l'apply *en rec* projette ce contrat » n'est pas exerçable E2E.** Tout est prouvé hors
  ligne sur dépôt Git réel, contre-épreuves par sabotage comprises.
- **Le verbe archive n'est branché sur aucun saut** — c'est G5.
- **Le transport des octets d'un palier à l'autre n'existe pas** (pas de dépôt d'artefacts) — G5.
- **`DeployerGroup` (« qui déploie » à côté de « qui approuve ») n'est pas ajouté** — G2.
- **Tout le chemin post-`DRY_RUN`** (clone, push, PR Gitea) n'est exercé par aucune épreuve : il
  exige un Gitea vivant. `run_w` pose toujours `DRY_RUN=1`, donc `MARQUEUR_NON_ECRIT` aussi est
  non éprouvé.

---

## Deux leçons à porter — elles ont coûté cher

### 1. Une assertion ne se relit pas, elle se MUTE

**Cinq verts vacants distincts** ont été trouvés, chacun par mutation et jamais par relecture :

| Le vert vacant | Ce qu'il laissait passer |
|---|---|
| `grep` satisfait par le **commentaire** qui explique le correctif | le correctif pouvait disparaître, la porte restait verte |
| un fichier fouillé pour une chaîne **qu'il contient lui-même** | tout credential inventé « existait » |
| un sabotage qui **soudait** la porte au lieu de l'ouvrir | la contre-épreuve prouvait l'inverse de ce qu'elle annonçait |
| une épreuve d'implication **confondue par son fixture** (la porte prod porte les deux drapeaux) | l'implication pouvait disparaître sans rougir |
| l'épreuve « pas du code mort » satisfaite par la directive `# shellcheck source=` | sourcer ≠ appeler ; supprimer l'appel laissait 4 assertions vertes |

Le cinquième était **dans l'épreuve écrite pour fermer le quatrième**. Réflexe désormais : pour
toute garde, **retirer la garde visée et exiger le rouge**. Et ancrer les `grep` sur le code
**décommenté** (`sed 's/[[:space:]]*#.*$//'` avant de chercher).

### 2. Le piège `pipefail` — rencontré DEUX fois

Sous `set -uo pipefail`, `cmd | grep -q TOKEN && ok … || bad …` est **cassé** dès que `cmd` sort
non nul : le statut du pipeline est le code non nul le plus à **droite** parmi *toutes* les étapes,
pas celui de la dernière commande. Or les scripts de garde de ce dépôt sortent 1 à chaque refus.
La branche `&&` ne se déclenche donc **jamais**, même quand `grep` matche.

```
bash -c 'set -uo pipefail; f(){ echo MATCH; exit 1; }; f | grep -q MATCH && echo AND || echo OR'
→ OR
```

**Toujours** capturer dans un fichier puis grepper le fichier — c'est le motif que le reste de
`test-deploy-pin.sh` utilisait déjà et que le plan n'a pas suivi.

Piège maison voisin : une sonde qui empaquette des champs avec `|` casse dès qu'une valeur
contient `| default('')` (cas réel des `when:`/`that:` Ansible). Délimiteur `\x1f`.

---

## Points ouverts, par ordre de ce que je ferais

1. **Trancher l'arbitrage du pin** (§ À LIRE EN PREMIER). Bloque G4.
2. **Rouvrir la surchargeabilité d'`apim_ss_authoring_env` si le rôle devient déclenchable par un
   tiers.** Un reviewer l'a classée **CRITIQUE** (`-e apim_ss_authoring_env=prod` désarme les deux
   asserts d'un coup) ; **je l'ai parquée** en « réel, non bloquant » — aux degrés D0/D2
   l'opérateur lance le play lui-même, et la garde équivalente côté CI est scellée par une
   affectation sèche. La dissymétrie est nommée dans `defaults/main.yml`. **C'est mon arbitrage,
   pas un consensus.**
3. **Poser les deux gestes de G1 restés en attente** (bloqués par le classifieur, à lancer en
   `! bash`) : `bash scripts/setup-release-team.sh` puis
   `GITEA_TOKEN=<write:repository> bash scripts/seed-governance-chain.sh`. Dans cet ordre — la
   porte prod nomme `release-team`, et tant que le groupe n'existe pas une promotion vers prod est
   inapprouvable (fail-closed, mais bloquant).
4. **`PIN_NON_RESOLU` n'atteint jamais le commentaire de PR** (`_dp_fail` écrit sur stderr,
   `fail()` ne capture rien). Théorique aujourd'hui — tous les refus possibles en `dev` sont
   pré-empêchés en amont. Ce sera **la** surface de diagnostic de l'équipe le jour où G4 ouvre
   `rec` : à inscrire dans le brief G4, pas seulement dans un ledger.
5. **Hors `dev`, le branchement du résolveur est DURCISSANT, pas préservant** : avec `ENVN=rec` il
   exige marqueur + digest + archive là où la publication serait partie sur `per_env.rec`.
   Inatteignable aujourd'hui (seul `providers.dev.yml` existe), mais à dire avant G4.
6. **La contre-épreuve ⑫ n'est pas *concurrency-safe*** : deux exécutions simultanées de
   `test-deploy-pin.sh` se disputent la même fenêtre de sabotage. Observé en direct. En CI la
   suite tourne une fois ; à garder à l'esprit.

---

## Deux écarts de processus, dits plutôt que masqués

- **Deux commits (`3b976c6`, `4824d98`) ont été posés par le contrôleur, pas par un sous-agent
  implémenteur.** Dans les deux cas le travail et sa preuve étaient livrés mais non committés ;
  pour `3b976c6`, deux implémenteurs successifs avaient échoué sur un changement d'**une ligne**.
  Les mutations ont été rejouées par le contrôleur, arbre au repos, une exécution à la fois.
- **G1 a été committé sur décision de l'exploitant** en cours de session, après vérification que
  ses deux portes étaient vertes.

---

## Où lire le détail

- **Spécification** : `docs/superpowers/specs/2026-08-26-g3-reference-deploiement-depots-equipe-design.md`
- **Plan** (10 tâches, chaque épreuve avec sa raison d'être) :
  `docs/superpowers/plans/2026-08-26-g3-reference-deploiement-depots-equipe.md`
- **Ledger** — toutes les revues, tous les correctifs, les items parqués avec leur ruling, et
  l'addendum listant les défauts du plan trouvés par les implémenteurs :
  `.superpowers/sdd/2026-08-26-g3-reference-deploiement-depots-equipe/progress.md`
- **Revue finale de branche** (1 Critical, 6 Important, 6 Minor) et sa vague de correctifs :
  `final-review.md`, `final-fix-report.md`, `final-rereview.md` au même endroit.
- **GOAL** : `GOAL-cd-promotion-5-envs-2026-08-26.md` — G3 est fait, restent G2, G4, G5, G6, G7, G8.
