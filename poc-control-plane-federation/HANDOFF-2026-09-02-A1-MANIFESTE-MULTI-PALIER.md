---
title: "HANDOFF — A1 : le manifeste d'application devient multi-palier"
type: handoff
date: 2026-09-02
status: "LIVRÉ — preuve 71/71 (lib hors ligne 41, gardes 8, parcours dev → rec contre le Gitea du lab 22) ; non-régression v2 19/19, v3 34/34, wiring 35/35, pr-comment 33/33, rétention 130/0 ; committé sur provision/probe-dev"
lié: [GOAL-cd-applications-2026-09-02, docs/superpowers/specs/2026-09-02-a1-manifeste-multi-palier-design.md, docs/superpowers/plans/2026-09-02-a1-manifeste-multi-palier.md, SPIKE-2026-09-02-cd-applications-convergence-et-souscription]
---

# A1 — ce qui a été livré

**La porte du GOAL tient** : demande `dev` puis `rec` ⇒ le manifeste porte `per_env.dev` **et** `per_env.rec` avec des `client_id` (idp) / `vault_sub` (internal) distincts ; la demande `rec` n'ajoute **qu'une ligne** (diff base→rec mesuré = 1 ligne ajoutée, 0 retirée) ; une demande avec une autre `api` (ou version fournie différente, ou appelant d'un autre mode) ⇒ `CONTRAT_DIVERGENT`, **aucune branche distante** créée.

## Fichiers

| Fichier | Rôle |
|---|---|
| `scripts/lib/app-manifest.sh` (nouveau) | `app_manifest_read` (KEY=VALUE bornés, `MANIFESTE_LEGACY` / `MANIFESTE_INVALIDE`), `app_manifest_check_contract` (7 args, toutes les divergences), `app_manifest_merge_env` (fusion ligne à ligne, auto-vérification, écriture atomique). PyYAML en `BaseLoader` (aucun typage). |
| `scripts/provision-request.sh` | source la lib ; défauts différés (héritage EXACT de version/audience/team absentes) ; gardes neuves `AUDIENCE_INVALID`, `API_VERSION_INVALID`, `CALLER_INVALID` ; lecture → héritage → contrat → garde providers (`grep -Fxq`) → `checkout -B` ; ligne de palier commune ; création (forme A1) ou fusion ; relecture fail-closed du manifeste créé ; certificat `certs/<app>-<env>.crt` ; rejeu sans commit (fetch + diff d'arbre) ; rejeu après merge ⇒ exit 0 sans PR ; corps de PR (« première demande » / « per_env.<env> fusionné — paliers déjà déclarés », team héritée nommée). |
| `scripts/test-app-request-a1.sh` (nouveau) | la preuve, 71/71 ; `A1_OFFLINE=1` = sections A/B seules (dans `make lint-ci` [9/9]). |
| `scripts/testdata/app-request-v2/golden-*.ansible.yml` | régénérés (contrat machine changé volontairement : claim par palier, description sans palier, en-tête A1). |
| `clients/provisioned/applications/paiements-sepa.ansible.yml` | migré à la main (claim.value → `per_env.dev`). |
| `scripts/test-app-request-v2.sh`, `-v3.sh` | cert `<app>-dev.crt` ; précondition « l'app golden n'existe pas sur main » (par code HTTP) ; provenance/recette des goldens réécrites. |
| `Makefile`, `ansible/roles/apim_selfservice_app/README.md`, `ci/jenkins/app-request.job.xml` | lint-ci (lib shellcheckée + étape [9/9]), forme A1 de la claim documentée, texte d'aide du paramètre certificat (`<app>-<env>.crt`, à re-poser via `scripts/setup-team-onboard-jobs.sh`). |

## Forme du manifeste (contrat machine A1)

Racine figée à la première demande : `name`, `api`, `api_version`, `auth.audience`, `auth.mode`, `team` ; en idp la racine ne porte que `claim: { name: "azp" }`. Une ligne flow par palier : `    <env>: { auth: { claim: { value: "<client_id>" } } | auth: { vault_sub: "…" }, ip_allowlist, public_cert_ref, cert_rotation, backend_key_ref, backend_key_field }`. Une ligne de palier ne peut **pas** porter un champ trans-palier (le rôle fusionne récursivement — refus `MANIFESTE_INVALIDE` à la lecture comme à la fusion). Chaque palier porte obligatoirement son identité (`claim.value` / `vault_sub`).

## Ce que la critique adverse et la revue ont apporté (33 points, tous traités)

Spec (15 confirmés) : `safe_load` typait `1.10` en `1.1` (⇒ BaseLoader) ; team héritée non re-validée et interpolée en regex dans la garde providers (⇒ bornes à la lecture + `grep -Fxq`) ; `REQ_CALLER` = `$.caller` du body, non filtré, interpolé dans l'en-tête et la description (⇒ `CALLER_INVALID` ; la prémisse « anti-spoof » du commentaire historique est fausse tant que la gateway n'injecte pas l'identité — c'est la step d'APIsation) ; rejeu après merge ⇒ 404 sur `POST /pulls` (⇒ exit 0 « déjà mergée ») ; `per_env: {}` / tête commentée ⇒ clé dupliquée avalée (⇒ regex ancrées, conversion, comptage) ; supprimer la base jetable **ferme** les PR (Gitea `CloseBranchPulls`, `merged=false` ⇒ n'arme pas `provision-apply`) ; seul `providers.dev.yml` existe dans le lab (⇒ fixture posée sur la base jetable, `PROVIDERS_MISSING` prouvé fail-closed sur `int`).
Code (18, dont 8 non vérifiés par sous-agents — limite de session — et vérifiés à la main) : une ligne de palier pouvait **surcharger** `api`/`team`/`audience` (⇒ refus) ; clés citées `"dev":` / dupliquées (⇒ reconnaissance + comptage) ; audience absente redérivée en `REQ_API` ⇒ divergence mensongère (⇒ héritage exact, C.8b) ; suite dépendante du cwd (⇒ `cd "$REPO"`) ; token en argv dans un helper de test (⇒ env) ; textes périmés (compteurs, provenance des goldens, citation, classes, TENANT).

## Pièges mesurés (à retenir)

- `diff a b | grep -q` sous `pipefail` rend le rc de `diff` ; helper `dif(){ diff … || true; }`.
- lire une PR par `pulls?state=all&limit=50` filtré sur `head.ref` est flaky à ~300 PR jetables ; lire par numéro.
- ne **jamais** merger une PR de test par l'API (déclenche `provision-apply`, attente d'`input`) ; « merge simulé » = API `contents` sur une base jetable, jamais `main`.
- le raw Gitea d'un fichier absent rend un corps JSON non vide : tester le code HTTP, pas `-n`.
- les sous-agents ont heurté la limite de session en cours de revue (reset 18:50) : deux lentilles (« silent », « tests ») n'ont jamais rendu — relues à la main (rc de la lib toujours suivi d'`exit 2`, mutations api/version/mode/team/legacy/quoted/dup/override toutes couvertes).

## Gestes restants

1. **Pousser sur `gitea` `ci/stoa-labs` main** (la lignée lue par le CI du lab) : sans ce push, `paiements-sepa` sur le lab reste en forme ancienne ⇒ `MANIFESTE_LEGACY` à la prochaine demande ; les jobs lisent aussi `scripts/provision-request.sh` depuis gitea. Le push suit la règle de la mémoire `trois-depots-ci-gitea` (lignée sans ancêtre commun, 6 fichiers propres à préserver, `http.postBuffer`).
2. Re-poser `app-request` (`scripts/setup-team-onboard-jobs.sh`) pour le texte d'aide du certificat — cosmétique.
3. A0 (tout en Jenkinsfile) reste indépendant ; A2 (apply au SHA mergé) est le prochain jalon et se branche sur cette forme.
4. Décision client n°1 (identité par palier ou trans-palier) : le mécanisme supporte les deux (les champs figés changent de liste), la segmentation reste à trancher.
