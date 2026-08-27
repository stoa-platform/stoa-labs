# HANDOFF — G5 : le verbe archive, porté par les deux moteurs

**Session du 2026-08-27.** Branche `provision/probe-dev`, **27 commits** de G5
(spec, plan, 11 tâches, leurs revues et la revue finale — `935bb07..8cd48b5`),
43 fichiers, +7133/−52. **Rien n'est poussé** : ni `origin` (resté au lot G4),
ni `gitea` (resté à `06afc4c` du 2026-08-07, PRÉ-G3 — voir le geste n°1, il
conditionne tout le rejeu). Arbre propre.

| Porte | Nature | Résultat |
|---|---|---|
| `scripts/test-promote-verb-live.sh` *(nouvelle)* — **LA porte du GOAL** | live, wM réel | **54/54 × les DEUX moteurs** — GUID iso, 0-coupure (3550/3550 et 4074/4074 requêtes 200 pendant l'import), `UPDATE_FORBIDDEN` rejouée |
| `scripts/test-archive-promotion.sh` (ADR-079, corrigée : purge ACDL) | live | **22/22 contre le mock ET contre le wM réel** (teamWork actif) — fidélité D7 tenue |
| `scripts/test-team-promote-wiring.sh` *(nouvelle)* | hors-ligne, `make lint-ci` [7/8] | **90/0** — chaque garde mutée ⇒ moteur jamais lancé, ordre prouvé par mutation |
| `scripts/test-archive-store.sh` *(nouvelle)* | hors-ligne, [6/8] | **24 assertions + garde de compte** |
| `go test ./mocks/webmethods -count=1` | hors-ligne, [8/8] *(nouvelle étape)* | **68 tests, 0 échec** |
| `make lint-ci` | intégral | **8/8 étapes vertes, rc=0** |
| E2E chaîne sur le lab (rapport T10) | live, script-par-script | merge PR → API active en `rec`, GUID iso via proxy — **par les DEUX moteurs** (PR #17 labctl, PR #18 ansible) ; F4 et TOCTOU fermées |

---

## À LIRE EN PREMIER — ce qui est prouvé, et la ligne exacte de ce qui ne l'est pas

**Le verbe des paliers est branché.** Le merge d'une PR `promote/<api>-<env>`
déclenche un apply réel : archive fetchée au registre par le digest du marqueur,
TOUTES les gardes mécaniquement antérieures à l'unique site moteur, import
0-coupure à GUID stable via le proxy `wm-admin-<env>`, résultat commenté sur la
PR. Les deux moteurs (`apim_promote_api` / `labctl promote`) sont vivants et ont
chacun prouvé la porte du GOAL sur le wM réel ET la chaîne complète sur le lab.

**La ligne d'honnêteté** (elle est aussi dans ADR-083 et ENVIRONNEMENTS.md) :
l'E2E a tourné **script-par-script** contre le vrai lab (Vault, Gitea, registre,
proxies, mocks) — **pas par des builds Jenkins**. Les jobs clonent un Gitea
resté pré-G3 ; la pause nominative (`input`) n'est donc pas exercée. Deux gestes
d'exploitant la débloquent (ci-dessous), puis la **checklist de rejeu**
(rapport T10, ligne 448, étapes 0-10, commandes prêtes) rejoue tout par les
builds réels.

---

## Les gestes exploitant (`! bash`) — dans cet ordre

1. **Pousser G5 sur Gitea** (fast-forward pur mesuré : `0 102`, aucun fichier
   propre à la lignée Gitea en jeu) :
   `git push gitea provision/probe-dev:main` — depuis `/Users/torpedo/hlfh-repos/stoa-labs`,
   avec le token du compte `ci` et `http.postBuffer` relevé (le lot passe le Mo).
   Script prêt : voir la checklist T10 étape 0. **Sans lui, aucun job du lab ne
   voit G3, G4 ni G5.**
2. **Le credential Jenkins `gitea-provision-token`** doit porter `write:package`
   (le registre d'archives le refuse sinon en 401 — mesuré dans les deux sens).
   Depuis `f144ebb` la convention de mint du dépôt est corrigée : **re-passer
   `bash scripts/setup-provision-request-job.sh` suffit** (le script `! bash
   update-jenkins-cred.sh` du scratchpad reste le raccourci sans re-pose).
3. Puis dérouler la **checklist de rejeu** (rapport T10 §CHECKLIST, étapes 1-10) :
   jobs re-posés, palier ouvert, export par le job, PR fraîche
   (⚠ **jamais rejouer une vieille PR dont la branche est supprimée** : Gitea
   rend alors `head.ref=refs/pull/N/head` et le build sort VERT sans rien faire
   — piège mesuré), merge humain, pause répondue, assertions, F4, TOCTOU.
   (Accessoirement : `origin` non plus n'a rien reçu — à pousser pour GitHub.)

---

## Ce qui est livré (l'essentiel ; le détail vit dans ADR-083)

1. **Le transport** : registre de packages génériques Gitea, **adressé par le
   contenu** (la version du package EST le sha256 de l'archive sanitizée) —
   `scripts/lib/archive-store.sh`, refus nommés `STORE_*`, l'URL se dérive du
   seul marqueur G3.
2. **L'export** : job `api-promote-export` (rôle en `action=export`, sanitize,
   push au registre, `EXPORT_CONFIRMED_SUMMARY guid=… sha256=… package=…`) ; le
   guid s'épingle dans `promote.yml` par une PR d'équipe.
3. **La consommation** : job `team-promote` (MÊME token webhook que
   team-publish — D1 **mesuré vrai**, 3 builds déclenchés sans second webhook),
   `scripts/team-promote.sh` : forme → knobs → branche/chaîne → réconciliation
   Gitea (identités comprises — jamais le payload) → topologie → ancêtreté →
   digest→fetch→résolveur G3 → refs de porte relues sur le marqueur MERGÉ →
   identité (4-yeux conditionnel à la porte, demandeur = `promoted_by` du
   marqueur) → palier Vault (`PALIER_FERME`) → **un** site moteur.
4. **Les deux moteurs pinnables** : `--archive` (labctl) / `apim_ss_archive_pin`
   (rôle), knob `PROMOTE_ENGINE` (ansible défaut | labctl) et `ADMIN_VIA`
   (proxy-oauth2 | direct) en `environment{}` du Jenkinsfile — jamais des
   paramètres ; `labctl`+`direct` = `COMBINAISON_NON_SUPPORTEE`.
5. **Le mock wM apprend `/archive`** (export nesté, import overwrite scoped,
   isActive, non-clobber d'alias, GUID iso, refus de collision nom+version,
   DELETE de teardown, **décodage `Content-Transfer-Encoding: base64`** — sans
   ce dernier le moteur ansible était injouable vers un palier mocké, mesuré).
6. **Le credential par palier consommé** (ADR-082 en action) : lecture
   `envs/<env>/wm-admin` = ticket d'entrée ; `envs/<env>/admin-oauth` par palier
   (valeur ci-horsprod partagée — limite nommée) ; policies `apply-<env>`
   étendues ; convention de mint des tokens ci corrigée (`write:package`).
7. **Réparations de terrain** : NPE policyAction fantôme du wM réel (8 policies)
   réparé ; proxy `wm-admin-homol` créé (matrice 20/0, verte pour la première
   fois) ; `allowDeactivate` projetable depuis `targets.yaml` (le fail-open
   silencieux est fermé) ; harnais ADR-079 purgé de l'ACDL (survit à
   `enableTeamWork=true`).

## Ce que G5 ne prouve PAS, et c'est voulu

- **La parité d'ÉTAT des deux moteurs** est **G8**. Deux écarts déjà au registre :
  `scope_mapping` vide (labctl refuse, ansible passe outre) ; le digest n'est
  vérifié que par le CI et le rôle, jamais par labctl (assumé, documenté).
- **`approverGroup` / « qui déclenche »** est **G2**. Et le **4-yeux est
  structurellement INERTE** sur cette chaîne tant que le plugin Jenkins
  `build-user-vars` n'est pas provisionné (`promoted_by` vaut `ci`) — câblé pour
  mordre sans changement le jour où le plugin nomme quelqu'un.
- **Le rollback des paliers** est **G6** ; le parcours complet dev→prod est
  **G7** ; la conversion du pipeline governance (tension « apply-uac reste le
  verbe de dev ») est **parquée, nommée dans ADR-083**.
- L'iso **inter-gateways** est inférée du GUID sur une gateway physique jouant
  les deux rôles — pas observée sur deux instances distinctes.

## Dettes et pièges consignés (à ne pas redécouvrir)

- **Frère du C1** : `team-publish`/`team-apply`/`provision-apply` font TOUJOURS
  confiance aux identités du payload webhook (`PR_MERGED_BY`) — un porteur du
  token GWT peut y auto-attester le mergeur. `team-promote` réconcilie, ses
  frères non. HORS périmètre G5 (chaînes prouvées G4), à traiter à part.
- Un palier ABSENT de `gates:` ⇒ auto-approbation admise (fail-open par
  omission de configuration — documenté dans ADR-083 et `environments.yaml`).
- L'exemple `clients/_example/apis/accounts-read.promote.yml` n'est **pas
  promouvable sur un lab frais** (vault_sub `envs/*/backends/accounts` que rien
  ne seede, `name` discordant publish/promote, openapi absent du dépôt d'équipe).
- 3 APIs legacy du wM réel (`accounts-read`, `customer-referential`,
  `payments-initiation`) restent **inactives sans stage IAM** (état antérieur,
  excision du NPE) — remède : `bash scripts/demo-multienv.sh`.
- `setup-vault-approle.sh` est un prérequis NON documenté de
  `setup-wm-admin-proxy.sh` (le Vault dev perd tout au restart).
- Les seeders passent des secrets en argv curl (pattern hérité, pré-G5).
- La mesure de fidélité D7 côté mock exige un conteneur SANS `JWT_ISSUER`
  (celui du compose garde son câblage Phase 3) — geste manuel, non scripté en CI.
- `api-promote-request` n'a toujours pas de `job.xml` (dette G3 documentée).

## État du lab à la fin de session

Fermé et propre : les 4 paliers à **403** pour oscar (`token_policies=
[operator-deploy]`, re-mesuré par le contrôleur), aucun asset jetable
(`g5live-*`, sondes registre, branches de preuve purgés), marqueur au digest
réel, catalogues dev=…/int=0/homol=0 et **rec=1 — l'API promue `t10-promote-api`
y est active, c'est l'état nominal de la preuve**. wM réel réparé (NPE), proxys
20/0, mocks rebuildés (homol compris). Vault dev re-seedé en session (il avait
tout perdu — il est EN MÉMOIRE : tout restart exige le re-seed, séquence connue
du jalon userpass).

## Où lire le détail

- **ADR** : `adr/adr-083-verbe-archive-deux-moteurs.md`.
- **Spécification** : `docs/superpowers/specs/2026-08-27-g5-verbe-archive-deux-moteurs-design.md`.
- **Plan** : `docs/superpowers/plans/2026-08-27-g5-verbe-archive-deux-moteurs.md`.
- **Ledger** (tous les rulings, revues, fixes) :
  `.superpowers/sdd/2026-08-27-g5-verbe-archive-deux-moteurs/progress.md` — avec
  `final-review.md` (0 Critical / 3 Important / 6 Minor, tous traités ou triés)
  et les rapports `task-N-report.md` (le T10 porte la checklist de rejeu).
- **Parcours opérateur** : `ENVIRONNEMENTS.md` § « Promouvoir une API (G5) ».
- **GOAL** : `GOAL-cd-promotion-5-envs-2026-08-26.md` — G1, G3, G4, G5 faits ;
  restent G2, G6, G7, G8.
