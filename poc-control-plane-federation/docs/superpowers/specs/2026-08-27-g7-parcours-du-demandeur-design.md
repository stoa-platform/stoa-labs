# G7 — Le parcours du demandeur : une PR, un tableau de bord

**Date** : 2026-08-27 · **Jalon** : G7 de `GOAL-cd-promotion-5-envs-2026-08-26.md`
**Ancrages** : ADR-081 (la décision est le merge), ADR-079/083 (verbe archive,
deux moteurs), ADR-082 (rétention par palier), ADR-084 (axe déployeur),
ADR-085 (repli des paliers), ADR-075/A6 (anti-TOCTOU ITSM au dispatch).

## Ce que G7 doit prouver (la lettre du GOAL)

> **Porte G7 :** une promotion complète `dev → rec → int → homol → prod`,
> chaque saut visible sur sa PR, chaque apply commenté avec son résultat et
> l'identité qui l'a porté.
> **Contre-épreuve :** déclencher le job de promotion **sans** la PR mergée ⇒
> refus.

ADR-081 tient : le demandeur ne « lance pas un job de déploiement » — il ouvre
une **PR de promotion** portant le marqueur `apis/<api>.deploy.<env>.yaml`, et
le statut de l'apply y remonte. Le formulaire Jenkins reste une porte d'entrée ;
il ne porte **aucune autorité**.

## Ce qui existe déjà (mesuré le 2026-08-27, à ne pas reconstruire)

| Pièce | Où | État |
|---|---|---|
| PR de promotion + plan commenté | `scripts/api-promote-request.sh` | Livré (G3/G5) |
| Merge ⇒ webhook ⇒ pause nominative ⇒ apply | `ci/Jenkinsfile.team-promote` + `scripts/team-promote.sh` | Livré, prouvé par builds (G5 #13/#14) |
| Résultat commenté sur la PR (succès/échec + statut build) | `team-promote.sh` §9 + `post{}` du Jenkinsfile | Livré |
| Refus « PR non mergée » | `team-promote.sh` §2 (réconciliation Gitea, `PAYLOAD_PERIME`) | Livré, jamais prouvé par build |
| Saut rec prouvé E2E | builds `team-promote #13/#14` | G5 |
| Rollback tous paliers | G6 (ADR-085) | Livré |

**G7 n'invente pas le mécanisme : il ferme ce qui empêche de le parcourir en
entier, et le prouve de bout en bout.**

## Les quatre trous mesurés

1. **Le terminus est inatteignable sur la chaîne d'équipe.** Le gabarit
   `APIM_API_BASE_TPL` résout `wm-admin-<env>` — or il n'existe **aucun** proxy
   `wm-admin-prod` (exclusion STRUCTURELLE du terminus, G4 :
   `env_chain_nonprod` partout, `ci-horsprod` sans `deploy:prod`). Aucun secret
   `envs/prod/wm-admin` n'est seedé nulle part (`setup-vault-envs.sh` boucle
   sur `env_chain_nonprod`), et la policy `operator-deploy` (celle que
   `deployerGroup: apim-operator-prod` projette) ne lit que `stoa/ci`,
   `stoa/opensearch` et `stoa/gateways/*` — le §7.b de `team-promote.sh`
   (`PALIER_FERME` sur `envs/<env>/wm-admin`) refuserait donc **tout** saut
   vers prod, y compris pour oscar.
2. **`itsmCheck` n'est pas re-vérifié au dispatch de la chaîne d'équipe.** La
   porte prod le déclare ; `env_chain_gate` le réduit à « change_ref présent »
   (voulu, à la demande) — mais au dispatch (`team-promote.sh`), rien n'appelle
   l'ITSM. Sur la chaîne governance, A6/ADR-075 a fermé exactement ce trou
   (`labctl dispatch-gate`, refus `ITSM_NOT_APPROVED` / `ITSM_UNAVAILABLE` /
   `ITSM_NOT_CONFIGURED`). Livrer le saut prod de la chaîne d'équipe avec une
   porte qui déclare un contrôle que personne n'exécute serait une porte qui
   ment.
3. **Le tableau de bord ment.** Le corps de PR d'`api-promote-request.sh` dit
   encore « ⚠ Ce merge n'applique rien aujourd'hui … quand G4 (verrou
   dev-only) et G5 (verbe archive) auront ouvert le palier » — périmé depuis
   G5 : le merge déclenche l'apply réel.
4. **Le commentaire d'apply ne nomme pas le porteur.** Il dit « demandée par X,
   mergée par Y » ; la lettre de G7 exige **l'identité qui a porté l'apply**
   (`V_USER`, l'identité Vault de la pause). Elle est égale au mergeur par la
   garde `MERGER_MISMATCH` — mais « égal par une garde » doit se LIRE sur la
   PR, pas se déduire du code.

## Décisions de conception

### D1 — La voie du terminus se dérive de la POSITION, jamais du nom

Précédent : `ci/Jenkinsfile.rollback` (G6) calcule `terminus: yes|no` en
comparant le palier au **dernier** de la chaîne, et route deux voies
(intermédiaire = proxy `wm-admin-<env>` via ci-horsprod ; terminus = accès
direct). `team-promote.sh` adopte le même dessin :

- Nouvelle fonction sœur `env_chain_terminus` dans `scripts/lib/env-chain.sh`
  (dernier palier de la chaîne, fail-closed sur source illisible — jamais un
  4e champ de `env_chain_gate`, motif documenté sur la lib).
- Si `TO_ENV` est le terminus : la voie effective est **directe** (l'admin de
  la gateway elle-même, Basic) — `APIM_DIRECT_BASE_TPL` requis (refus nommé
  `TERMINUS_SANS_VOIE` s'il manque, dès que `TO_ENV` est connu, avant tout
  réseau), moteur **ansible seulement** (`PROMOTE_ENGINE=labctl` + terminus ⇒
  `COMBINAISON_NON_SUPPORTEE`, même raison que labctl+direct : le moteur
  labctl ne s'authentifie que par bearer, et il n'y a pas de proxy OAuth2
  devant le terminus). Le rôle Ansible lit les creds **lui-même** dans Vault
  (`apim_ss_vault_wm_creds_sub=envs/<terminus>/wm-admin`) — aucun secret
  matérialisé par le script.
- Les paliers intermédiaires gardent le régime actuel (`ADMIN_VIA`, défaut
  proxy-oauth2). Le knob `ADMIN_VIA` ne pilote QUE les paliers non terminaux ;
  le terminus est direct par STRUCTURE, pas par réglage.
- `ci/Jenkinsfile.team-promote` gagne le défaut
  `APIM_DIRECT_BASE_TPL = http://webmethods-real:5555/rest/apigateway`
  (surchargeable, motif `env.X ?: défaut` — `__ENV__` absent du gabarit est
  licite, `sed` no-op).

**Écarté :** poser un proxy `wm-admin-prod` — il rouvrirait ce que G4 a fermé
par structure (le client OAuth ci-horsprod devrait porter `deploy:prod`).
**Écarté :** router le saut prod par la chaîne governance — le parcours du
demandeur vit dans SON dépôt (ADR-076/081) ; la lettre de G7 est « chaque saut
visible sur SA PR ».

### D2 — Ouvrir le terminus reste un geste, et il reste humain

- `scripts/setup-vault-envs.sh` seed en plus `envs/<terminus>/wm-admin`
  (surcharges `WM_<TERMINUS>_USER/PASS`, défaut = les creds admin de la
  gateway réelle, mêmes knobs que `setup-vault.sh`). **Pas** de
  `envs/<terminus>/admin-oauth` : il n'y a pas de proxy devant le terminus, et
  en seeder un laisserait croire qu'une voie OAuth2 existe.
- La policy `operator-deploy` (`scripts/setup-vault-userpass.sh`) gagne la
  lecture de `secret/{data,metadata}/stoa/envs/<terminus>/wm-admin`, terminus
  **dérivé** de `env_chain` (le script source `lib/env-chain.sh`, fail-closed).
- Les policies `apply-<env>` et le pipeline hors-prod ne changent PAS : le
  terminus reste exclu par structure. Ouvrir prod = être membre du groupe
  d'annuaire `apim-operator-prod` (oscar au lab) — le repli AppRole de la
  machine reste refusé `DEPLOYER_GROUP_REQUIRED` (conséquence assumée,
  documentée dans `environments.yaml`).

### D3 — §6ter : l'ITSM re-vérifié au dispatch de la chaîne d'équipe

Miroir d'A6, au seul site de dispatch de cette chaîne :

- Nouvelle fonction sœur `env_chain_gate_itsm_check <env>` → `ITSMCHECK=0|1`.
- Dans `team-promote.sh`, **après** la garde d'identité (§6bis — elle ne
  touche rien d'externe, elle reste première) et **avant** Vault (§7) : si la
  porte déclare `itsmCheck`, `GET ${ITSM_URL}/changes/<change_ref>` doit
  répondre `status=approved`. Refus nommés, fail-closed :
  `ITSM_NOT_CONFIGURED` (porte déclarée, `ITSM_URL` absent),
  `ITSM_UNAVAILABLE` (HTTP ≠ 200, timeout), `ITSM_NOT_APPROVED`.
- Le `change_ref` du marqueur MERGÉ devient un segment d'URL : la classe
  `[A-Za-z0-9._-]` (déjà exigée à la demande, `REF_INVALIDE`) est re-vérifiée
  au §6 sur la valeur mergée — l'anti-TOCTOU vaut pour la forme aussi.
- `ci/Jenkinsfile.team-promote` : `ITSM_URL = ${env.ITSM_URL ?: 'http://itsm-mock:8788'}`.

### D4 — Le tableau de bord dit la vérité

- `api-promote-request.sh` : le paragraphe périmé du corps de PR est remplacé
  par le flux réel (merge → webhook → pause nominative → apply → commentaire
  de résultat) ; quand la porte d'arrivée déclare `itsmCheck`, le corps
  l'annonce (« le change sera re-vérifié approved au dispatch »).
- `team-promote.sh` §9 : le commentaire de succès nomme le **porteur** —
  « portée par \`$VAULT_IDENTITY_USER\` » — à côté du demandeur et du mergeur.
  (Trois identités, trois statuts : demandé / mergé / porté.)

### D5 — Les preuves

**Hors-ligne** (extension, jamais de nouveau harnais parallèle) :
- `scripts/test-env-chain.sh` : les deux nouveaux lecteurs
  (`env_chain_terminus`, `env_chain_gate_itsm_check`), avec sabotage
  (itsmCheck retiré de la porte prod ⇒ le lecteur le dit ; source cassée ⇒
  refus fermé).
- `scripts/test-team-promote-wiring.sh` : nouvelles épreuves —
  (a) `TO_ENV=terminus` ⇒ moteur invoqué avec la voie directe
  (`apim_ss_auth_mode=basic`, `wm_creds_sub=envs/<terminus>/wm-admin`), jamais
  oauth2 ; (b) `APIM_DIRECT_BASE_TPL` absent + terminus ⇒ `TERMINUS_SANS_VOIE`,
  moteur jamais lancé ; (c) labctl + terminus ⇒ `COMBINAISON_NON_SUPPORTEE` ;
  (d) itsmCheck déclaré : approved ⇒ passe, not-approved / injoignable / URL
  absente ⇒ refus nommé AVANT moteur ; (e) l'ORDRE prouvé par mutation
  (§6bis avant §6ter avant §7 — inverser fait rougir).
- `make lint-ci` intégral vert.

**Live — LA porte du GOAL, par builds Jenkins réels :**
1. API publiée en dev (team-publish, ou remise en état `demo-multienv`), export
   (`api-promote-export`), guid pinné.
2. Quatre PR de promotion, une par saut : `promote/<api>-rec` (selfApproval),
   `-int` (mergée/portée par bob, `apim-apply-int`), `-homol` (carol,
   `apim-apply-homol`, PV exigé), `-prod` (oscar, `apim-operator-prod`,
   change+PV+itsm approved). Chaque build : pause répondue par le mergeur,
   apply vert, **la PR porte** le plan (corps), le résultat (pin, digest,
   moteur, demandeur/mergeur/porteur) et le statut build.
3. Vérité d'état après chaque saut : catalogue du palier (l'API active,
   `id==guid` iso), terminus compris (catalogue de la gateway réelle).
4. **Contre-épreuve du GOAL, par build** : webhook tiré à la main sur une PR
   **ouverte** (payload prétendant `merged=true`) ⇒ build FAILURE,
   `PAYLOAD_PERIME` commenté, moteur jamais lancé (`grep -c 'PLAY ['` = 0),
   catalogue inchangé. Variante marqueur : palier sans marqueur mergé ⇒
   `PIN_ABSENT` (le gate Git du GOAL).
5. Contre-épreuve ITSM par build : change au statut `draft` sur le saut prod ⇒
   FAILURE `ITSM_NOT_APPROVED`, moteur jamais lancé ; repasse `approved` ⇒
   vert (anti-TOCTOU montré, pas raconté).

**Gestes d'ouverture au lab** (G4/G2, PAS du code) : groupes déployeurs posés
(bob=int, carol=homol via `setup-deployer-groups.sh` ; oscar=prod existant),
palier rec ouvert au demandeur (grant `apply-rec` — même geste qu'au rejeu G5),
seeds Vault rejoués si le conteneur a redémarré (Vault dev = en mémoire).

## Ce que G7 ne fait PAS (limites nommées, héritées et maintenues)

- `approverGroup` toujours pas enforced au merge (= protection de branche,
  ADR-081 — reste nommé de G2).
- 4-yeux pipeline inerte tant que `build-user-vars` manque (`promoted_by=ci`) —
  reste nommé de G2/G5 ; G7 n'y touche pas, le câblage mord le jour où le
  plugin nomme quelqu'un.
- La parité d'état des deux moteurs = G8. Le parcours live tourne au moteur
  défaut (ansible) ; labctl reste prouvé par G5 sur rec.
- `team-publish`/`team-apply`/`provision-apply` font toujours confiance aux
  identités du payload (frère du C1) — hors périmètre, nommé.
- Le client OAuth `ci-horsprod` reste partagé entre paliers hors-prod (limite
  G5, parking n°2).

## Risques d'exécution connus (mesurés aux jalons précédents)

Fenêtre keepalive du wM réel (lancer les promotions après un cycle) ; Vault
dev en mémoire (re-seed complet si restart, séquence du jalon userpass) ;
course delete/recreate de branche `promote/*` (PATCH state=open) ; ne jamais
rejouer le webhook d'une PR à branche supprimée (no-op vert) ; un ré-export
change le digest ⇒ PR de promotion neuve, jamais un marqueur recyclé.

## Livrables documentaires

- **ADR-086 — Le parcours du demandeur : une PR, un tableau de bord** (la
  décision D1-D4, les refus nommés, les limites).
- `ENVIRONNEMENTS.md` § « Le parcours du demandeur (G7) » — le pas-à-pas des
  cinq paliers, qui merge quoi, qui répond à quelle pause.
- `GOAL-cd-promotion-5-envs-2026-08-26.md` : G7 marqué FAIT avec ses preuves.
