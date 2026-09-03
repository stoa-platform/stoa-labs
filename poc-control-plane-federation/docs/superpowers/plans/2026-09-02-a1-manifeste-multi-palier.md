---
title: "Plan — A1, le manifeste d'application devient multi-palier"
type: plan
status: "EXÉCUTÉ le 2026-09-02 — 6 tâches, TDD, preuve 71/71 + non-régression v2 19/19 / v3 34/34"
date: 2026-09-02
spec: docs/superpowers/specs/2026-09-02-a1-manifeste-multi-palier-design.md
---

# Plan A1 — six tâches, chacune rouge puis verte

Contexte : GOAL-cd-applications-2026-09-02 §A1. Spec : D1..D9 du design. Les tâches sont dans l'ordre où elles ont été jouées ; chaque tâche nomme son épreuve **avant** son code.

## T1 — La suite hors ligne de la lib (rouge)

`scripts/test-app-request-a1.sh`, section A : 41 épreuves sur des fichiers locaux — lecture (KEY=VALUE, paliers dans l'ordre du fichier), forme ancienne refusée (`MANIFESTE_LEGACY`), YAML cassé / sans `apim_ss_app` (`MANIFESTE_INVALIDE`), contrat identique accepté, une divergence, trois divergences toutes listées, `team` (vide/vide, figée/vide, vide/fournie, `name`), fusion (insertion = une ligne ajoutée ; remplacement = une ligne changée, ordre préservé ; idempotence ; `dev` vs `dev2` ; bloc absent ; sans newline final ; auto-vérification sur inline non-mapping et mal fermé ; palier en style block ; clé d'env hors classe ; lecture après fusion ; mode internal).
Section B : `bash -n`, shellcheck de la lib, le script source la lib, trois gardes hors ligne neuves (`AUDIENCE_INVALID`, `API_VERSION_INVALID`, `CALLER_INVALID`) qui sortent avant `[1/4]`.
Knob `A1_OFFLINE=1` (sections A/B seules) — la section C mintait sinon un token via docker et touchait le lab (mesuré au premier run).

Piège mesuré en T1 : `diff a b | grep …` sous `pipefail` rend le rc de `diff` (1 dès que les fichiers diffèrent) — helper `dif(){ diff "$1" "$2" || true; }`.

## T2 — `scripts/lib/app-manifest.sh` (vert)

Trois fonctions bash 3.2, chacune un `python3 - <<'PY'` : `app_manifest_read`, `app_manifest_check_contract` (7 args, toutes les divergences), `app_manifest_merge_env` (fusion ligne à ligne, mapping passé par l'environnement, auto-vérification `got != want` avant toute écriture). Refus = stderr `REFUS: <TAG> : …` + `return 2` (jamais `exit`, la lib est sourcée).

## T3 — Branchement dans `scripts/provision-request.sh`

- source de la lib après `env-chain.sh` (même base cwd) ;
- `REQ_API_VER_IN` / `REQ_AUDIENCE_IN` gardés bruts ; défauts appliqués seulement sans manifeste ; gardes hors ligne sur les valeurs fournies ;
- après le clone, avant `git checkout -B` : `app_manifest_read || exit 2`, héritage version/audience/team (trace « team héritée du manifeste »), `app_manifest_check_contract || exit 2`, puis la garde `providers.<env>.yml` du palier visé (sur la team héritée aussi) ;
- ligne du palier commune aux deux modes (`PER_ENV_AUTH` + items : ip, cert+rotation, clé backend) ; fusion si le manifeste existe, heredoc de création sinon (claim `{ name }` à la racine, description sans palier, en-tête A1) ;
- certificat `certs/<app>-<env>.crt` ;
- rejeu : `git fetch --depth 1 <branche>` + `git diff --cached --quiet FETCH_HEAD -- .` ⇒ ni commit ni push si l'arbre est déjà celui de la branche distante ;
- corps de PR : « manifeste : première demande (créé) » ou « per_env.<env> fusionné — paliers déjà déclarés : … ».

## T4 — Contrat machine : golden files régénérés, manifeste démo migré, v2 adaptée

`scripts/testdata/app-request-v2/golden-{idp,internal}.ansible.yml` réécrits à la forme A1 (geste explicite prévu par l'en-tête de la section C de v2). `clients/provisioned/applications/paiements-sepa.ansible.yml` migré à la main (claim.value → per_env.dev). `test-app-request-v2.sh` : chemin de certificat `<app>-dev.crt`.

## T5 — Section C contre le Gitea du lab (vert 22/22)

Base jetable `p3a1-base-<ts>` créée depuis `main` par l'API, passée en `GIT_BASE` ; « merge simulé » par l'API `contents` (jamais de merge de PR : l'événement `closed|merged` déclencherait `provision-apply` sur le Jenkins du lab, en attente d'`input`). Parcours idp dev → rec (porte + contre-épreuve 1 par diff = une ligne), rejeu (même SHA), autre api / version fournie / autre mode ⇒ `CONTRAT_DIVERGENT` sans branche (contre-épreuve 2), mode internal (vault_sub distincts), certificat par palier, forme ancienne ⇒ `MANIFESTE_LEGACY`, team héritée avec `providers.rec.yml` posé sur la base (fixture) et `providers.int.yml` absent ⇒ `PROVIDERS_MISSING`.

Piège mesuré en T5 : le corps de PR lu via `pulls?state=all&limit=50` filtré par `head.ref` est flaky sur un dépôt à ~300 PR jetables (ordre non fiable) — lecture par numéro (`PR_URL=…/pulls/N` imprimé par le script).

## T6 — Porte de lint, textes adjacents, statut

`make lint-ci` : lib shellcheckée, étape `[9/9]` = suite A1 hors ligne. README du rôle (forme A1 de la claim), description du paramètre certificat de `ci/jenkins/app-request.job.xml` (`<app>-<env>.crt`), GOAL (A1 LIVRÉ 71/71). Non-régression rejouée : v2 19/19, v3 34/34, wiring 35/35, pr-comment 33/33, rétention 130/0, shellcheck de la liste lint-ci propre.
