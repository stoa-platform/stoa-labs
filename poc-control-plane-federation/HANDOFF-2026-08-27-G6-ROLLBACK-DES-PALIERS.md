# HANDOFF — G6 : le repli, comme composant du déploiement

**Session du 2026-08-27 (après G2, même journée).** Branche `provision/probe-dev`,
lot G6 `3364d6a..f312d3c` + un commit de clôture (ce handoff), spec+plan compris
(`docs/superpowers/{specs,plans}/2026-08-27-g6-rollback-des-paliers*`).
**`gitea` est À JOUR** (`gitea/main = f312d3c`, trois pushes fast-forward en
session — les jobs du lab voient G2+G6). **`origin` (GitHub) n'a rien reçu**
depuis G5 — push optionnel, le CI du lab lit Gitea. Arbre propre hors handoff.

| Porte | Nature | Résultat |
|---|---|---|
| `go test ./cmd/governance-api` (+3 tests rollback) | hors-ligne, air-gapped | vert — dont `TestRollbackChangeRefAlignedWithITSMCheck` qui ROUGISSAIT sur l'ancien code |
| `scripts/test-rollback-paliers.sh` *(nouvelle)* — porte live | live (KC/Dex, proxies, mocks réels) | **22/0 ×2 + rejeu contrôleur (22/0)** |
| **Builds Jenkins réels** — LA porte du GOAL | live, lab | `stoa-prod-rollback` **#6 SUCCESS** (porte homol) · **#5 FAILURE attendue** (contre-épreuve `GATE_REFS_REQUIRED`) |
| `make lint-ci` | intégral | 8/8 (le script a rejoint la surface shellcheck) |
| Revue finale de branche | fable | 1 Critical + 1 Important + minors — **tous fixés** (`f312d3c`), re-review clean |

## À LIRE EN PREMIER — ce qui est prouvé

**Le rollback n'est plus prod-only.** `handlers_rollback.go` était déjà générique
par palier ; ce qui a changé : la garde change_ref s'aligne sur la demande
(`RequireChangeRef || ITSMCheck`, jamais `pv_ref` — l'état restauré a porté son
PV à sa promotion, ADR-085 D3), et `ci/Jenkinsfile.rollback` suit désormais **le
palier de sa promotion** : l'env est relu de `restored.environment` de la
réponse du POST (jamais saisi — D1), la chaîne est dérivée du clone post-revert,
le terminus se choisit par POSITION (D2), et deux voies de re-apply existent
(terminus = ci-applier/Vault direct ; intermédiaire = ci-horsprod via
`wm-admin-<env>` avec `VAULT_TOKEN_FILE` pour le preflight déployeur G2). Le
smoke mesure l'ÉTAT : catalogue du palier à la version N-1.

**Prouvé par builds** : #6 a rollbacké `pr-aa26f598` (homol) — palier DÉRIVÉ
(`terminus: no`), `restored` homol@1.0.1 pin `b3bb6d5`, commit gouverné
`a87ebc4` + evidence `rollback-005.json`, `deploy.homol.yaml` **verbatim** égal
au blob N-1, `SMOKE OK accounts-read@1.0.1`. #5 a refusé le MÊME champ
`CHANGE_REF` vide sur une promotion prod approuvée : HTTP 400
`GATE_REFS_REQUIRED` **de l'API** — même job, même formulaire, verdict opposé
selon le palier : la porte décide, jamais le formulaire.

## Deux défauts de code livré découverts PAR les preuves, et fermés

1. **`apply-uac` n'était pas idempotent sur une API wM ACTIVE** (`121f168`) :
   `webmethods.Publish` PUTtait la définition inconditionnellement, or le
   produit refuse le PUT sur une API active (ADR-079). Diagnostiqué **par
   mutation** (un 2ᵉ apply sans rollback échouait pareil) ; le PUT de définition
   est désormais **sauté** quand l'API trouvée est active (chemin nominal ET
   repli 409) — activation, inbound auth et alias routing convergent toujours.
   La dérive de définition sur une API active reste au **verbe archive (G8)**.
   Bonus : rendre le fake de test fidèle a fait tomber **6 tests préexistants**
   qui n'étaient verts que par infidélité du harnais — tous réparés par le fix
   production. Résiduel assumé (ADR-085) : la sévérité du mock est tenue pour
   fidèle au wM réel, pas re-sondée en G6.
2. **Un paramètre de build Jenkins VIDE est RETIRÉ de l'environnement**
   (`412aba4`, mesuré par le build #4) : `Run.getEnvironment()` montre
   `CHANGE_REF=[]` mais dash dit « parameter not set » → sous `set -u`, le sh
   mourait AVANT le POST. Fix : `"${CHANGE_REF:-}"` + validation en `${:-}`.
   Occurrence unique sur les 14 Jenkinsfile.

## La revue finale a attrapé un troisième défaut — dans un fix de revue

Le trap du stage intermédiaire (`rm -f …; vault_trap_revoke`) **masquait tout
échec du stage** : le `rm` réussi écrase `$?`, `vault_trap_revoke` sortait 0 —
un SMOKE KO devenait un build VERT (sonde dash : masked-rc=0). Fix `f312d3c` :
`vault_trap_revoke` accepte `${1:-$?}` (rétro-compatible avec les 3 traps nus
existants) et le trap capture `rc=$?` AVANT le rm. Leçon : le round 1 de revue
avait « réparé » le rm inaccessible en perdant le rc — **les deux ordres naïfs
sont faux**, il faut capturer.

## Gestes exploitant / suivis

1. **Optionnel : push `origin`** (GitHub n'a ni G2 ni G6).
2. **Après tout restart de `poc-vault`** (dev, en mémoire) : le `role_id` de
   l'AppRole `ci-pipeline` doit être réaligné sur le littéral des Jenkinsfile —
   `scratchpad` de session perdu, refaire via `scripts/setup-vault-approle.sh
   --mint ci-pipeline` + `docker exec` (le rapport T4 porte la séquence).
3. `scripts/jenkins-refresh-vault-secret.sh` échoue **en silence** (rc=1, aucun
   message) sans `VAULT_TOKEN` — une ligne d'erreur à ajouter (dette mineure).
4. **governance-api tourne sur l'hôte :8787** (prérequis runbook du job
   rollback), push fail-closed vers gitea via le token `g6-rollback-1787855700`
   (à révoquer si on l'arrête : commande dans le rapport T4).
5. Le token webhook/`team-publish #4` fantôme (G5) n'a pas été touché.

## Ce que G6 ne prouve PAS, et c'est dit

- **Le chemin d'échec du stage intermédiaire n'a pas été exercé par un build
  rouge délibéré** (motif F1 : une porte qui ne rougit jamais ne prouve rien).
  Le fix du trap est prouvé par sonde dash, pas par build. À jouer à l'occasion
  (casser le proxy → build rouge attendu).
- Le rollback du **terminus** par le job n'a pas été rejoué post-G6 (la voie
  terminus est l'existante, validée 2026-07-23 ; seuls les stages partagés ont
  bougé). La voie **nominative** (`VAULT_USER`) n'a pas été exercée en G6
  (builds en AppRole, acteur `service-account-ci-applier`).
- Le rollback de la chaîne **self-service** (re-pin du digest N-1 par PR neuve)
  est le parcours **G7** ; la conversion du verbe governance = **G8** (tension
  ADR-083 inchangée).
- Idée de garde future : un grep lint anti-motif `trap '…; vault_trap_revoke'`
  (toute commande avant le revoke) pour que la classe ne revienne pas.
- `REASON` part dans un printf JSON sans échappement (préexistant, opérateur
  privilégié) — à durcir en passant (json.dumps).

## État du lab en fin de session

`deploy.homol.yaml` du repo governance = état N-1 rollbacké (c'est LA trace,
ne pas « nettoyer ») ; `deploy.int.yaml` remis à v1.0.1 (`78c4659`) ; catalogue
homol sert légitimement `accounts-read@1.0.1` ; mocks int/homol remis à zéro
par la porte T3 (⑤, re-vérifié n=0) puis homol re-peuplé par le build #6 ;
`poc-webmethods-real` sous keepalive (fenêtre ~2-3 min post-recycle où les
proxies ne sont pas re-enregistrés — 404 `Service not found`, consigné) ;
Vault non re-seedé (socle intact).

## Où lire le détail

- **ADR** : `adr/adr-085-rollback-des-paliers.md`.
- **Spécification** : `docs/superpowers/specs/2026-08-27-g6-rollback-des-paliers-design.md`.
- **Plan** : `docs/superpowers/plans/2026-08-27-g6-rollback-des-paliers.md`.
- **Ledger** (rulings, revues, la correction de ruling du trap) :
  `.superpowers/sdd/2026-08-27-g6-rollback-des-paliers/progress.md` + rapports
  `task-N-report.md` (le T4 porte les consoles des builds).
- **Parcours opérateur** : `ENVIRONNEMENTS.md` § « Revenir en arrière (G6) ».
- **GOAL** : `GOAL-cd-promotion-5-envs-2026-08-26.md` — G1, G2, G3, G4, G5, G6
  faits ; **restent G7, G8**.
