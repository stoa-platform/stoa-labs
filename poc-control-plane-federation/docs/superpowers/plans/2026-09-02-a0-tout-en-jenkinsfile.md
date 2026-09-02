---
title: "Plan — A0, tout en Jenkinsfile : provision-plan, provisioning-request et le formulaire app-request sortent du XML"
type: plan
status: "EN COURS 2026-09-02"
date: 2026-09-02
spec: docs/superpowers/specs/2026-09-02-a0-tout-en-jenkinsfile-design.md
---

# A0 — plan d'implémentation

> **Pour un exécutant sans contexte** : lire la spec (D1..D9) ; chaque tâche nomme son épreuve AVANT son code ; la preuve finale est par BUILDS réels (T8), T1..T7 sont vérifiables hors ligne.

**But :** plus un seul `job.xml` porteur de logique sur l'aval applicatif ; le formulaire `app-request` posé par son Jenkinsfile ; miroir des triggers vérifié par une lib sur les trois jobs.

**Contraintes (spec) :** parité stricte des deux conversions ; `sh` en quotes simples ; `withEnv([params…])` conservé (fait 4) ; `FORM_BOOTSTRAP` capturé AVANT `properties()` (fait 6) ; XML = coquille + miroir (le XML gagne) ; fail-closed partout, jamais de skip muet.

---

## T1 — `scripts/lib/gwt-mirror.sh` + squelette de `scripts/test-a0-wiring.sh` (§1, §2, §8)
- [ ] épreuves : §1 coquilles (4 XML), §2 miroir 3 jobs + app-request sans trigger, §8 mutations (triggers retirés ⇒ rc 2 ; valeur altérée ⇒ rc 1) — rouge sur provision-plan/provisioning-request (encore inline).
- [ ] lib : `gwt_mirror_diff <xml> <jenkinsfile>` (python inline, vue code sans commentaires).

## T2 — `ci/Jenkinsfile.provision-plan` + coquille `provision-plan.job.xml` (§3)
- [ ] épreuves §3 écrites ; rouge.
- [ ] Jenkinsfile déclaratif (D1) ; XML réduit (D3) ; `make lint-ci` [1/10] compile.

## T3 — `ci/Jenkinsfile.provisioning-request` + coquille (§4)
- [ ] épreuves §4 ; rouge → vert.

## T4 — `generate-choices.sh` (variantes brutes, D5) + `scripts/app-request-choices.sh` (§6)
- [ ] épreuves §6 fonctionnelles hors ligne (bare repos, `STOA_ENV_CHAIN_FILE`, mutations) ; rouge.
- [ ] lib + script ; `test-generate-choices.sh` reste vert SANS modification.

## T5 — `ci/Jenkinsfile.app-request` (formulaire posé, D4) + coquille `app-request.job.xml` (§5)
- [ ] épreuves §5 ; rouge → vert ; `test-app-request-wiring.sh` réaligné (§3 inversé), total mis à jour.

## T6 — La pose : `BOOTSTRAP_JOBS` (D6) + réalignement des suites (§7)
- [ ] `test-setup-provision-jobs.sh` : section BOOTSTRAP (POST build après pose ; jamais en DRY_RUN ; 400 ⇒ RC=1) ; rouge → vert.
- [ ] `setup-provision-jobs.sh`, `setup-team-onboard-jobs.sh` (BOOTSTRAP_JOBS=app-request), commentaires `team-apply.sh`/`team-publish.sh`.
- [ ] `test-app-request-v2.sh` §B, `test-app-request-v3.sh` §B1/B3, `test-generate-choices.sh` §9 (faux Jenkins accepte `/build`), `test-palier-retention.sh` ㉑octies — verts.

## T7 — Miroir étendu (D7 b) + porte de lint
- [ ] `test-team-publish-wiring.sh` §3ter (3 contrôles, total +3) ; Makefile : shellcheck étendu (+ SC2181 de generate-choices) ; [11/11] `test-a0-wiring.sh` ; `make lint-ci` vert.

## T8 — Preuve par builds réels : `scripts/test-a0-live.sh` (D9)
- [ ] pose + amorçage, état relu, porte machine, porte humaine, contre-épreuve RAW, nettoyage — X/X.

## T9 — Docs + commit + gitea
- [ ] `ENVIRONNEMENTS.md` (A0 livré, rollout), `ci/README.selfservice.md` (2 lignes), GOAL (A0 LIVRÉ), en-têtes ; commit ; `git push gitea HEAD:main` (le CI lit gitea).
