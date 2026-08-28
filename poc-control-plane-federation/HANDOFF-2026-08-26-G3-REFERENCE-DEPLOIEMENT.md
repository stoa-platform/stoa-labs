# HANDOFF — G3 : la référence de déploiement, portée aux dépôts d'équipe

**Session du 2026-08-26.** Branche `provision/probe-dev`, **46 commits**, **poussés sur `origin`**
(GitHub). `gitea` n'a **rien reçu** — voir plus bas, ça compte. Arbre propre.

| Porte | Résultat |
|---|---|
| `scripts/test-deploy-pin.sh` *(nouvelle)* | **78 / 0** |
| `scripts/test-team-publish-wiring.sh` | **116 / 116** |
| `scripts/test-env-chain.sh` | **4 / 0** |
| `scripts/test-jenkinsfile-lint.sh` | **13 / 13** |
| `make lint-ci` | vert `[1/4]`→`[4/4]`, `shellcheck rc=0` |

---

## À LIRE EN PREMIER — ce qui a été arbitré, et ce que ça te coûte

**La chaîne promeut désormais ce que le palier source exécute, pas « le dernier `main` ».**

Le premier jet ne le faisait pas. Le pin était `git log -1 main -- apis/<api>.*`, et le marqueur du
palier source était ouvert puis jeté sauf `enabled`. Mesuré sur dépôt jetable : rec servant v1.0.0
pendant que `main` porte v2.0.0, une demande `rec → int` écrivait **v2.0.0** — un état que rec n'a
jamais servi. La PR annonçait « rec → int », l'approbateur mergeait, **rien ne rougissait**.

Ton GOAL l'exigeait pourtant mot pour mot dans son test de réussite — *« chaque palier recevant
exactement l'archive approuvée et pas "le dernier main" »*. Le défaut était dans la **spécification**,
qui ne raisonnait que sur `dev → rec`, où les deux coïncident par construction.

**Arbitré : chaînage strict.** Au-delà de `dev`, le pin **et** le digest viennent du marqueur du
palier source. La version est relue **au commit retenu**, jamais sur l'arbre de travail.

### Ce que ça te coûte, et il faut le savoir avant de le découvrir

**Une correction ne saute aucun palier.** Un correctif urgent re-traverse `dev → rec → int → homol
→ prod`. C'est le prix de la garantie : sans lui, la chaîne documenterait un parcours au lieu de le
prouver. C'est écrit aux trois endroits où quelqu'un le lira (résolveur, gabarit, spécification).

### Ce que ça te rend

« Build once, deploy many » devient **vrai par le mécanisme**. Le digest voyage avec le pin, donc
les mêmes octets vont de dev jusqu'en prod. On avait dû écrire l'inverse dans la doc quelques heures
plus tôt — c'est annulé, et les trois textes sont à l'endroit.

**Nuance qui change la lecture du code :** ce qui tient la garantie, c'est le **refus**, pas
l'héritage. Le demandeur ressaisit le digest à chaque saut (la garde le lui impose : `TO_ENV` ne peut
jamais valoir `dev`, tête de chaîne). Il n'est simplement plus *cru* — il est confronté à celui du
palier source, et une divergence refuse (`DIGEST_CONTREDIT_SOURCE`). Le demandeur ne peut pas
substituer les octets en cours de route ; il peut seulement se tromper de recopie, et il est refusé.

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

Il porte aussi le **chaînage** (`resolve_promotion_pin`) et la **réconciliation du digest**
(`reconcile_promotion_digest`). Ces deux-là vivent dans la bibliothèque **parce qu'elles s'y
éprouvent hors ligne** : au site d'appel elles seraient dans le chemin post-`DRY_RUN`, qu'aucune
épreuve n'exerce.

Refus nommés, tous fail-closed — à l'apply : `PIN_ABSENT`, `PIN_MALFORMED`, `PIN_NON_ANCETRE`,
`PIN_UNREADABLE`, `PIN_VERSION_MISMATCH`, `PROMOTE_MANIFEST_ABSENT`, `ARCHIVE_ABSENT`,
`ARCHIVE_PATH_RELATIVE`, `ARCHIVE_UNREADABLE`, `ARCHIVE_DIGEST_MISMATCH`, `DIGEST_ABSENT`,
`API_NAME_INVALIDE`, `ENV_INVALIDE`, `WORKDIR_INCREABLE` ; au chaînage : `SOURCE_NON_DEPLOYEE`,
`PARSE_MARQUEUR_SOURCE`, `SOURCE_PIN_MALFORMED`, `SOURCE_DIGEST_ABSENT`, `SOURCE_VERSION_MISMATCH`,
`DIGEST_CONTREDIT_SOURCE`, `PIN_INTROUVABLE`.

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

Et depuis l'arbitrage, il **se chaîne** : hors `dev`, il est hérité du marqueur du palier source, et
`reconcile_promotion_digest` refuse un digest de formulaire qui le contredirait.

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

## Trois leçons à porter — elles ont coûté cher

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

### 3. Rendre une logique testable ne suffit pas — il faut éprouver qu'elle est APPELÉE

Le piège s'est refermé sur moi à la toute fin, et c'est le plus instructif. Constatant que le calcul
du pin vivait dans le chemin post-`DRY_RUN` qu'aucune épreuve n'exerce, je l'ai déplacé dans la
bibliothèque **pour qu'il devienne éprouvable** — et j'ai laissé le **seul appel** et la garde
`DIGEST_CONTREDIT_SOURCE` dans ce même chemin non testé. Le relecteur a retiré l'appel : **les trois
portes sont restées vertes**. La fonction devenait du code mort, le défaut qu'on venait d'arbitrer
revenait, et aucun voyant ne s'allumait.

C'est exactement ce que l'épreuve ⑳ existe pour empêcher sur le jumeau (« sourcer n'est pas
appeler ») — je ne l'avais pas appliqué au nouveau. **Déplacer une garantie ne la garantit pas :
il faut une épreuve sur le câblage, ancrée sur le code décommenté.**

## Points ouverts, par ordre de ce que je ferais

L'arbitrage du pin est **fermé** ; les neuf mineurs de sa revue aussi (aucun parqué). Reste :

1. **Pousser sur `gitea` dès que le lab est relancé** — `git push gitea provision/probe-dev`.
   `gitea` est **ce que lit le CI du lab**, et sa lignée n'a pas d'ancêtre commun avec GitHub. Tant
   qu'il n'a rien, aucun job du lab ne voit G3. Il n'a pas répondu de toute la session (timeout sur
   `localhost:13000`). Si le lot passe le mégaoctet, `http.postBuffer` est requis sur ce remote.
2. **Poser les deux gestes de G1 restés en attente** (bloqués par le classifieur, à lancer en
   `! bash`), dans cet ordre : `bash scripts/setup-release-team.sh` puis
   `GITEA_TOKEN=<write:repository> bash scripts/seed-governance-chain.sh`. La porte prod nomme
   `release-team` ; tant que le groupe n'existe pas, une promotion vers prod est inapprouvable —
   fail-closed, mais bloquant, et il vaut mieux le savoir avant de le découvrir.
3. **Rouvrir la surchargeabilité d'`apim_ss_authoring_env` si le rôle devient déclenchable par un
   tiers.** Un reviewer l'a classée **CRITIQUE** (`-e apim_ss_authoring_env=prod` désarme les deux
   asserts d'un coup) ; **je l'ai parquée** en « réel, non bloquant » — aux degrés D0/D2 l'opérateur
   lance le play lui-même, et la garde équivalente côté CI est scellée par une affectation sèche.
   La dissymétrie est nommée dans `defaults/main.yml`. **C'est mon arbitrage, pas un consensus.**
4. **`PIN_NON_RESOLU` n'atteint jamais le commentaire de PR** (`_dp_fail` écrit sur stderr, `fail()`
   ne capture rien). Théorique aujourd'hui — en `dev` tous les refus possibles sont pré-empêchés en
   amont. Ce sera **la** surface de diagnostic de l'équipe le jour où G4 ouvre `rec` : à inscrire
   dans le brief G4, pas seulement dans un ledger.
5. **Hors `dev`, le branchement du résolveur est DURCISSANT, pas préservant** : avec `ENVN=rec` il
   exige marqueur + digest + archive là où la publication serait partie sur `per_env.rec`.
   Inatteignable aujourd'hui (seul `providers.dev.yml` existe), mais à dire avant G4.
6. **La contre-épreuve ⑫ n'est pas *concurrency-safe*** : deux exécutions simultanées de
   `test-deploy-pin.sh` se disputent la même fenêtre de sabotage. Observé en direct. En CI la suite
   tourne une fois ; à garder à l'esprit.
7. **Pas de PR ouverte.** GitHub la propose :
   `https://github.com/stoa-platform/stoa-labs/pull/new/provision/probe-dev`. Non ouverte, non
   demandée.

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
- **Revue de l'arbitrage** (1 Critique, 3 Important, 9 Mineurs — tous traités, aucun parqué) :
  `arbitrage-review.md`, et le diff revu dans `arbitrage-chainage.diff`.
- **GOAL** : `GOAL-cd-promotion-5-envs-2026-08-26.md` — G3 est fait, restent G2, G4, G5, G6, G7, G8.
