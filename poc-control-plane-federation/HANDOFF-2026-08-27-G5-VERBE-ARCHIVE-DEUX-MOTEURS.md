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
| E2E chaîne sur le lab (rapport T10) | live, **builds Jenkins** | merge PR → API active en `rec`, GUID iso via proxy — **par les DEUX moteurs** (`team-promote #13` ansible, `#14` labctl), pause `input` comprise ; F4 (`#15`) et TOCTOU (`#16`) fermées par builds |

---

## À LIRE EN PREMIER — ce qui est prouvé, et la ligne exacte de ce qui ne l'est pas

**Le verbe des paliers est branché.** Le merge d'une PR `promote/<api>-<env>`
déclenche un apply réel : archive fetchée au registre par le digest du marqueur,
TOUTES les gardes mécaniquement antérieures à l'unique site moteur, import
0-coupure à GUID stable via le proxy `wm-admin-<env>`, résultat commenté sur la
PR. Les deux moteurs (`apim_promote_api` / `labctl promote`) sont vivants et ont
chacun prouvé la porte du GOAL sur le wM réel ET la chaîne complète sur le lab.

**L'E2E est prouvé PAR DES BUILDS JENKINS RÉELS** (elle est aussi dans ADR-083 et
ENVIRONNEMENTS.md). Le push exploitant a été fait EN SESSION — `gitea/main =
646bf7b`, fast-forward `06afc4c..646bf7b` — et la chaîne a été rejouée en entier
par les jobs, **pause nominative (`input`) comprise** :

| build | verdict | ce qu'il prouve |
|---|---|---|
| `api-promote-export` **#1** | SUCCESS | export + push au registre, par le job |
| `team-promote` **#13** | SUCCESS | nominal, moteur **ansible** (le défaut) |
| `team-promote` **#14** | SUCCESS | moteur **labctl**, en overwrite du précédent |
| `team-promote` **#15** | FAILURE *attendue* | rétention **F4** (`PALIER_FERME`) |
| `team-promote` **#16** | FAILURE *attendue* | **TOCTOU** (`ARCHIVE_INTROUVABLE`) |
| `team-promote` **#17** | SUCCESS | remise en état nominale |

La pause est réelle : `input` id=`Promote`, `V_USER` (String) +
`V_PASS` (**PasswordParameterDefinition** — jamais posée sur un Jenkins réel
avant ce jour), répondue par `POST …/input/Promote/proceed`. Sur **#15** et
**#16**, le moteur n'a **jamais** été lancé (`grep -c 'PLAY \['` = 0) et le
catalogue de `rec` est resté à `n=0` — la référence avait été remise à vide
exprès, pour que « inchangé » veuille dire quelque chose.

La première preuve, elle, fut **script-par-script** contre le même lab : c'est
ce qui a permis d'isoler les écarts avant que la couche Jenkins n'existe. La
trace en reste au rapport T10 (§1 et POST-SCRIPTUM).

---

## Les gestes exploitant — **1 et 2 sont FAITS**

1. ~~**Pousser G5 sur Gitea**~~ — **FAIT en session par l'exploitant.**
   `gitea/main = 646bf7b` (fast-forward `06afc4c..646bf7b`, `0 102` mesuré avant,
   aucun fichier propre à la lignée Gitea perdu). Les jobs voient désormais G3,
   G4 et G5.
2. ~~**Donner `write:package` au credential `gitea-provision-token`**~~ —
   **FAIT, et par la voie du dépôt** : depuis `f144ebb` la convention de mint est
   corrigée, donc `bash scripts/setup-provision-request-job.sh` a suffi
   (`✅ credential posé (HTTP 302)`). Le correctif in-repo a rendu le geste
   bloqué inutile — c'est le bon dénouement, et le raccourci
   `update-jenkins-cred.sh` du scratchpad n'a pas servi. ⚠ Ce poseur re-pose
   aussi le job `provisioning-request` (effet de bord assumé).
3. **Reste, optionnel : pousser sur `origin` (GitHub)** — `origin` n'a rien
   reçu de G5. Sans conséquence pour le lab (le CI lit Gitea) ; à faire pour
   que GitHub reflète le jalon.

La **checklist de rejeu** (rapport T10 §CHECKLIST, étapes 0-10, commandes prêtes)
reste valable telle quelle pour rejouer la chaîne — ses étapes 0a/0b sont
désormais sans objet.

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

- **L'export n'est PAS reproductible bit-à-bit.** Ré-exporter la MÊME API
  produit un digest différent (`6a2ced5c…` puis `c9de1818…` sur deux exports
  consécutifs) alors que **le GUID, lui, ne bouge pas**
  (`14c2529e-0000-4000-8000-000000000003`). Ce n'est pas un défaut : c'est la
  conception — le GUID porte l'iso inter-gateways, le digest ne chaîne que *ces*
  octets-là d'un palier au suivant. **Conséquence d'exploitation : tout
  ré-export impose une PR de promotion NEUVE**, un marqueur ne se recycle pas.
- **Fenêtre keepalive du wM réel** (`restart-wm.sh`, cron `*/5`, `WM_MAX_MIN=20`) :
  elle coupe les builds en vol. Mesuré — `team-promote #12` a passé TOUTES les
  gardes puis `Connection refused` sur `webmethods-real:5555` ; le conteneur
  avait redémarré 2 min plus tôt. Le rejeu immédiat (`#13`) est vert. **Lancer
  les promotions juste après un cycle** : `docker inspect poc-webmethods-real`
  → `StartedAt` récent + `healthy`.
- **Gitea ferme la PR si on supprime puis recrée sa branche trop vite.** La PR
  #20 est ressortie `state=closed, merged=False` AVANT toute tentative de merge
  (timeline : `pull_push` puis `close`, par `ci`) — aucun script du dépôt ne
  ferme de PR, vérifié. Course entre le `DELETE` de la branche `promote/*` et sa
  recréation immédiate ; confirmé par différence (avec un `sleep` intercalé, la
  PR #21 est restée `open`). Remède : relire l'état, `PATCH {"state":"open"}`
  (→ 201), puis merger. Sans le savoir, on n'a qu'un `404 The target couldn't be
  found` parfaitement opaque.
- ⚠ **Ne jamais rejouer le webhook d'une PR dont la branche est supprimée** :
  Gitea rend alors `head.ref=refs/pull/N/head`, `team-promote` répond
  `hors promote/* — rien à promouvoir` et sort **rc=0** — un no-op SILENCIEUX qui
  ressemble à une réussite.
- **Build fantôme** : `team-publish #4` est resté « building » depuis 12:56Z,
  antérieur à la campagne de rejeu et non investigué. À tuer ou diagnostiquer.
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

Fermé et propre, **re-mesuré après le rejeu Jenkins** : les 4 paliers à **403**
pour oscar (`token_policies=['operator-deploy']`), aucun asset jetable
(`g5live-*`, sondes registre, branches de preuve purgés — **aucune branche
`promote/*` ne subsiste**), marqueur au digest réel (`c9de1818…238eb`, celui du
dernier export), catalogues **dev=0 / int=0 / homol=0** et **rec=1 — l'API
promue `t10-promote-api` v1.0.0 y est active, `id==guid`, c'est l'état nominal
de la preuve**. `PROMOTE_ENGINE` **retiré** des variables globales du nœud →
retour au défaut `ansible`. Jobs alignés sur `gitea/main = 646bf7b`. wM réel
réparé (NPE), proxys **20/0** (homol compris depuis `e128c77`), mocks rebuildés.
Vault dev re-seedé en session (il avait tout perdu — il est EN MÉMOIRE : tout
restart exige le re-seed, séquence connue du jalon userpass).

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
