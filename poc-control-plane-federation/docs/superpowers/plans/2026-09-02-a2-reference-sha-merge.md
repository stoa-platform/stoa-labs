---
title: "Plan — A2, la référence : l'apply d'application projette le SHA mergé"
type: plan
status: "EXÉCUTÉ le 2026-09-02 — T1..T7, preuve par builds réels 60/60 (5 exécutions live : 3 défauts de mécanique Jenkins trouvés et corrigés par les builds)"
date: 2026-09-02
spec: docs/superpowers/specs/2026-09-02-a2-reference-sha-merge-design.md
---

# A2 — plan d'implémentation

> **Pour un exécutant sans contexte** : lire d'abord la spec (D1..D10) ; chaque tâche nomme son épreuve AVANT son code (TDD) ; la preuve finale est par BUILDS réels sur le lab (T7), les tâches T1..T6 sont vérifiables hors ligne.

**But :** `provision-apply` capte `MERGE_SHA`, le réconcilie avec Gitea, le passe à `selfservice-app-deploy` qui checkoute CE SHA, confirme ce qu'il a projeté, et la PR reçoit SHA + digest du bloc `per_env.<env>`.

**Architecture :** conversion de `provision-apply` en Jenkinsfile déclaratif from SCM (coquille XML miroir) ; réconciliation par script bash+python ; digest par la lib `app-manifest.sh` ; aval étendu d'un stage « Référence » ; rapport de PR étendu. Aucun changement au rôle Ansible, au moteur, à `provision-request.sh`.

**Contraintes globales (spec) :** aucun `job.xml` porteur de logique ; shell de l'agent = dash (lib bash via `bash -c`) ; valeurs externes lues par le shell, jamais interpolées par Groovy ; refus nommés stables ; le XML `<triggers>` gagne sur le Jenkinsfile (miroir exact, 7 clés) ; défaut `APPLY_ADMIN_VIA=proxy-oauth2` (client), lab = `direct`.

---

## T1 — `app_manifest_digest_env` (lib) — FAIT

**Fichiers :** modifier `scripts/lib/app-manifest.sh` (4e fonction + en-tête) ; créer `scripts/test-provision-apply-a2.sh` section A.

**Interface produite :** `app_manifest_digest_env <fichier> <env>` → stdout `sha256:<64hex>` (une ligne), rc 0 ; rc 2 + `REFUS: PALIER_INVALIDE|MANIFESTE_INVALIDE|MANIFESTE_LEGACY|PALIER_ABSENT` sur stderr. Algorithme : `sha256(json.dumps(per_env[env], sort_keys=True, separators=(",",":"), ensure_ascii=False).encode("utf-8"))` sur le mapping relu par `yaml.BaseLoader`.

- [x] Épreuves A.0–A.12 écrites (existence, forme, dev≠rec, contrôle positif de l'algorithme recalculé sans la lib, stabilité au re-sérialisage, sensibilité à une valeur, insensibilité à un autre palier, PALIER_ABSENT nommant les paliers, per_env vide, clé hors classe, fichier absent, legacy, internal, sortie d'une seule ligne) — rouge 2/15 (deux verts vacants sur des vides égaux → durcis par `[ -n … ]`).
- [x] Fonction ajoutée en fin de lib (réutilise `app_manifest_read` pour bornes et legacy ; stdout de la lecture redirigé) — vert 15/15 ; `A1_OFFLINE=1 test-app-request-a1.sh` 49/49 (non-régression).

## T2 — `scripts/provision-apply-reconcile.sh` — FAIT

**Fichiers :** créer `scripts/provision-apply-reconcile.sh` ; section B + D de la suite.

**Interface produite :** entrées env `PR_BRANCH PR_NUMBER MERGE_SHA GITEA_TOKEN RECONCILE_OUT [GIT_HOST GIT_REPO GIT_WEB_HOST MANIFEST_DIR]` ; sortie `RECONCILE_OUT` = `GITEA_MERGED_BY= GITEA_REQUESTER= APP_NAME= ENV_NAME= MANIFEST=` (écrit seulement si tout concorde) ; rc 1 + `REFUS: <TAG> : …` (`PR_NUMBER_INVALIDE MERGE_SHA_INVALIDE BRANCH_FORMAT_INVALIDE GITEA_RECONCILE_ECHEC PAYLOAD_PERIME MERGER_UNKNOWN`), chaque refus commenté sur la PR (best-effort) via `provision-apply-comment.sh` (`APPLY_RESULT=REFUSED REFUSAL=<TAG>`).

- [x] Stub Gitea (python `http.server`, `ctl.json`, journal HTTP, commentaires capturés) ; épreuves B.1–B.10 (nominal : identités = Gitea pas payload ; non mergée, SHA/head/base divergents ⇒ `PAYLOAD_PERIME` ; `merged_by` vide ⇒ `MERGER_UNKNOWN` ; saut de ligne ⇒ `GITEA_RECONCILE_ECHEC` ; 500 / JSON cassé / `[]` / 401 ⇒ `GITEA_RECONCILE_ECHEC` ; sept refus de forme sans aucun `/pulls/` ; découpage au dernier tiret).
- [x] Mutations D.1–D.5 : retirer la comparaison SHA / base / merged / head ⇒ le scénario correspondant PASSE (rc 0) sur le mutant ; l'original refuse toujours.
- [x] Piège rencontré : `SELF_DIR` résolu APRÈS le `cd` ⇒ attrapé par `test-pr-comment.sh` §10 — corrigé (résolu avant).

## T3 — `scripts/provision-apply-comment.sh` : SHA, digest, refus — FAIT

**Interface produite :** entrées optionnelles `APPLIED_SHA APPLIED_DIGEST REFUSAL REFUSAL_DETAIL GIT_WEB_HOST` ; `APPLY_RESULT=REFUSED` accepté sans `VALIDATOR` ; corps INCHANGÉ sans ces variables.

- [x] Section C : C.1 corps d'aujourd'hui (rétro-compatible) ; C.2 SHA + lien `<GIT_WEB_HOST>/<repo>/commit/<sha>` + digest nommant le palier ; C.3 REFUSED sans identité ; C.4 FAILURE + `SHA_NON_CONFIRME` + SHA annoncé par l'aval ; C.5 SUCCESS sans VALIDATOR refusé. `test-pr-comment.sh` 37/37.

## T4 — l'aval : stage « Référence » dans `ci/Jenkinsfile.selfservice` — FAIT (à prouver par build)

**Fichiers :** modifier `ci/Jenkinsfile.selfservice` (paramètre `MERGE_SHA`, stage avant PLAN) ; `scripts/setup-selfservice-job.sh` (XML : `MERGE_SHA`, `ADMIN_VIA`, `DEBUG` déclarés à la pose).

**Interface produite :** paramètre `MERGE_SHA` ; `env.APPLIED_SHA` / `env.APPLIED_DIGEST` posés (lisibles en `buildVariables`) ; refus `MERGE_SHA_INVALIDE`, `MERGE_SHA_NON_ANCETRE`, palier absent au SHA (fermés, avant tout appel gateway).

- [x] `git fetch -q origin main` → `merge-base --is-ancestor` → `git checkout` → digest via `bash -c '. scripts/lib/app-manifest.sh && app_manifest_digest_env …'` (dash sur l'agent) ; sans `MERGE_SHA` : HEAD annoncé, digest best-effort.
- [x] `ci/lint-jenkinsfiles.sh` : 15/15 compilent.

## T5 — l'amont : `ci/Jenkinsfile.provision-apply` + coquille XML + câblage — FAIT (à prouver par build)

**Fichiers :** créer `ci/Jenkinsfile.provision-apply` ; réécrire `ci/jenkins/provision-apply.job.xml` (coquille, 7 clés) ; réécrire `scripts/test-provision-apply-wiring.sh` ; adapter `scripts/test-pr-comment.sh` §8 ; commenter `scripts/setup-provision-jobs.sh`.

- [x] Stages : Contexte (displayName « apply <app>/<env> (PR #n) ») → Réconciliation (`agent any`, `beforeAgent`, token Gitea, `RECONCILE_OUT=$WORKSPACE/.a2-reconcile.env`, relu par `readFile` → `env.setProperty`) → Appliquer (`beforeInput`, `input` V_USER/V_PASS, `agent any`, garde nourrie par `GITEA_MERGED_BY/GITEA_REQUESTER`, `build(... propagate: false)` avec `MERGE_SHA`, confrontation `APPLIED_SHA != MERGE_SHA` ⇒ `SHA_NON_CONFIRME`, rapport `|| true`, `error()`), `post{always}` statut sous `<!-- provision-apply-build -->`.
- [x] Câblage 112/112 (coquille sans `<script>`, miroir des 7 clés/token/filtre, ordre réconciliation < input < garde < build < rapport < error, paires option/variable de la garde, MERGE_SHA passé, propagate false, SHA_NON_CONFIRME, post, aval : paramètre + ancrage < checkout < Plan < Apply, setup-selfservice-job déclare MERGE_SHA).
- [x] `make lint-ci` : `[10/10]` = suite A2 hors ligne + câblage ; shellcheck étendu aux deux scripts.

## T5bis — Amendements de la critique adverse (32 points confirmés / 40, 1 bloquant) — FAIT

- [x] **PALIER_SUPPLANTE** (bloquant) : la réconciliation relit `main` par git (`fetch`, `is-ancestor`, digest du manifeste effectif au SHA mergé vs `origin/main`) — épreuves B.12 (+ contrôles autre palier / reformatage / manifeste retiré) et mutation D.6 ; le harnais hors ligne porte un dépôt git local (origin nu + clone).
- [x] `PR_HORS_PERIMETRE` (`/pulls/<n>/files` ⊆ manifeste + cert du palier) — B.11, mutation D.5.
- [x] Schéma de la réponse Gitea vérifié (champs présents) — B.8e.
- [x] Commentaire de refus : seulement si la forge confirme une PR `provision/*` (facts `GITEA_HEAD_REF`), marqueur `provision-apply-refus`, « CE webhook n'a rien appliqué », valeurs de forme jamais recopiées (journal `%q`) — B.4/B.7/B.8/B.9/B.14, C.3/C.6/C.7/C.8.
- [x] Aval : `MERGE_SHA_REQUIS` (upstreamBuilds), lignée first-parent, `APPLIED_SHA = git rev-parse HEAD` après checkout, `APPLIED_*` écrits après le verify seulement, mode `pinned`/`head`.
- [x] Amont : stage d'apply SANS agent (`build` hors nœud), `withEnv(['V_PASS='])` autour des deux `sh`, assignations explicites depuis `readFile`, confrontation `pinned && SHA`, `EXPECTED_SHA` au rapport, post gaté par `GITEA_HEAD_REF`.
- [x] Digest = manifeste EFFECTIF (racine ⊕ palier, `combine(recursive=True)`) — A.3/A.3b/A.5c.
- [x] Câblage : vue code sans commentaires `//` ni `#`, 138/138. Live : build résolu depuis l'item de file GWT, PUT confirmé, gateway fail-closed, contre-épreuve 2 (rejeu ⇒ `PALIER_SUPPLANTE`).

## T6 — Documents — FAIT (statut GOAL après la preuve)

- [x] `ENVIRONNEMENTS.md` : section « La référence d'une application (A2) » — mécanisme, rollout (D9), knob `APPLY_ADMIN_VIA`, identité alice, marqueurs, limites.
- [x] `GOAL-cd-applications-2026-09-02.md` : A2 LIVRÉ (chiffres), statut en tête.
- [x] `ci/README.selfservice.md` : `MERGE_SHA`, stage Référence, `Jenkinsfile.provision-apply`.
- [x] Spec : statut + amendements de la critique adverse.

## T7 — Rollout lab + preuve par BUILDS (`scripts/test-provision-apply-a2-live.sh`)

Ordre contraint (spec D9) :

- [x] 1. commit + `git push gitea HEAD:main` (le CI lit gitea) — `75a42e6`, puis correctifs rebasés sur les commits d'artefacts de la suite live.
- [x] 2. `bash scripts/setup-selfservice-job.sh` — amorçage #28 SUCCESS (`REFERENCE_MODE=head`), 8 paramètres dont `MERGE_SHA`.
- [x] 3. `JOBS=provision-apply bash scripts/setup-provision-jobs.sh` — coquille from SCM posée (HTTP 200, historique conservé).
- [x] 4. `APPLY_ADMIN_VIA=direct` en variable globale Jenkins (script console).
- [x] 5. alice créée dans Gitea + collaboratrice `write` par la suite live (laissée en place).
- [x] 6. Suite live **60/60** (5e exécution ; #74 harnais RAW_HC, #75 PasswordParameterValue/String, #78 Secret.fromString hors sandbox, #81 b.absoluteUrl sans URL racine — chacun corrigé, câblage ancré) : porte (demande rec `a2p<ts>`, merge par alice, pause atteinte, commit API sur `main` changeant `per_env.rec`, réponse V_USER=alice, build vert ; vérités : log aval `APPLIED_SHA=<MERGE_SHA>`, commentaire = SHA + digest du bloc mergé (recalculé localement) ≠ digest HEAD, gateway : identifier `ipAddressRange` = `10.42.0.1-10.42.0.1`) ; contre-épreuve (PR `a2q<ts>` ouverte, webhook forgé ⇒ FAILURE `PAYLOAD_PERIME`, jamais en pause, compte des builds aval inchangé, aucune app `a2q` sur la gateway, PR commentée) ; nettoyage.
- [x] 7. mémoire `a2-reference-sha-merge` : chiffres, pièges mesurés.
