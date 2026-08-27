---
title: "ADR-086 — Le parcours du demandeur : une PR par saut, la PR comme tableau de bord. Le formulaire n'a aucune autorité ; la décision est le merge, l'apply remonte sur la PR avec ses trois identités (demandeur / mergeur / porteur) ; le terminus s'atteint par POSITION (voie directe, jamais de proxy) et l'ITSM est re-vérifié au dispatch de la chaîne d'équipe."
sidebar_label: "ADR-086 : le parcours du demandeur (G7)"
status: "Acté et prouvé hors-ligne : test-team-promote-wiring.sh 160/0 (dont G7-a..g — voie du terminus par mutation, ITSM draft/inconnu/panne/non-configuré ⇒ moteur jamais lancé, commentaire RELU tel que posté), test-env-chain.sh 11/0 (lecteurs terminus/itsmCheck + contre-épreuves source cassée), make lint-ci 8/8. Live (builds Jenkins) : à jouer — le parcours complet dev→rec→int→homol→prod par builds réels est LA porte du GOAL, référencée ici une fois jouée, jamais avant."
maturite_technique: "✅ Mécanisme prouvé hors-ligne (chaque refus nouveau ⇒ stub moteur JAMAIS invoqué, ordre prouvé par mutation et par la liste ordonnée des jetons). Résiduel nommé : le parcours live par builds n'était pas joué à l'écriture ; approverGroup toujours pas enforced au merge (protection de branche, ADR-081) ; 4-yeux pipeline inerte tant que build-user-vars manque (promoted_by=ci) ; parité d'état des deux moteurs = G8."
date: 2026-08-27
adr_number: 86
note: "Consomme ADR-081 (la décision EST le merge — ce jalon ne déplace aucune autorité, il rend le tableau de bord VRAI), ADR-083 (le verbe archive et ses gardes antérieures au moteur — G7 y ajoute deux gardes, mêmes règles), ADR-082 (ouvrir le terminus = un geste de credential, ici étendu au DERNIER palier), ADR-084 (le porteur est l'identité Vault de la pause — G7 la NOMME sur la PR), ADR-075/A6 (l'anti-TOCTOU ITSM au dispatch, porté au second monde — la chaîne d'équipe)."
lié: "[[adr-081-ou-vit-la-decision-humaine]], [[adr-083-verbe-archive-deux-moteurs]], [[adr-082-ouverture-palier-retention-credential]], [[adr-084-axe-qui-deploie-deployer-group]], [[adr-085-rollback-des-paliers]]"
---

# ADR-086 — Le parcours du demandeur : une PR, un tableau de bord

**Statut :** Acté, prouvé hors-ligne ; parcours live par builds = la porte G7 du GOAL.

**Lié à :** [[adr-081-ou-vit-la-decision-humaine]], [[adr-083-verbe-archive-deux-moteurs]],
[[adr-082-ouverture-palier-retention-credential]], [[adr-084-axe-qui-deploie-deployer-group]].

---

## Contexte

G5 a branché le verbe (merge d'une PR `promote/<api>-<env>` ⇒ import d'archive
réel, gardes antérieures au moteur, résultat commenté). G2 a posé l'axe « qui
déploie », G4 la rétention par palier, G6 le repli. Le **parcours complet** du
demandeur — dev → rec → int → homol → prod, une PR par saut — restait pourtant
impossible À PARCOURIR, pour quatre raisons mesurées le 2026-08-27 :

1. **Le terminus était inatteignable sur la chaîne d'équipe.** Le gabarit
   d'admin résout `wm-admin-<env>` — or aucun proxy n'existe devant le dernier
   palier (exclusion STRUCTURELLE, G4 : `env_chain_nonprod` partout,
   `ci-horsprod` sans le terminus). Aucun secret `envs/prod/wm-admin` n'était
   seedé, et `operator-deploy` — la policy que `deployerGroup:
   apim-operator-prod` projette — ne le lisait pas : §7.b aurait refusé
   `PALIER_FERME` pour TOUT le monde, oscar compris.
2. **`itsmCheck` n'était pas re-vérifié au dispatch de cette chaîne.** La porte
   prod le déclare ; à la demande il se réduit (voulu) à « change_ref
   présent » ; côté governance, A6 le re-vérifie au dispatch. Côté équipe :
   personne. Une porte qui déclare un contrôle que rien n'exécute est une
   porte qui ment.
3. **Le corps de PR mentait** : « ⚠ Ce merge n'applique rien aujourd'hui …
   quand G4 et G5 auront ouvert le palier » — périmé depuis G5. Le lecteur
   mergait en croyant ne rien déclencher.
4. **Le commentaire d'apply ne nommait pas le porteur.** « Demandée par X,
   mergée par Y » — l'identité qui a PORTÉ l'apply (V_USER, le login Vault de
   la pause) restait à déduire du code (elle est égale au mergeur par
   `MERGER_MISMATCH`). La lettre de G7 exige qu'elle se LISE.

## Décision

### D1 — La voie du terminus se dérive de la POSITION, jamais du nom

`team-promote.sh` §1bis : si `TO_ENV` est le **dernier** palier de la chaîne
(`env_chain_terminus`, lecteur sœur fail-closed), la voie d'admin est
**directe** — `EFFECTIVE_VIA=direct`, gabarit `APIM_DIRECT_BASE_TPL` (défaut
Jenkinsfile : la gateway réelle, `http://webmethods-real:5555/rest/apigateway`),
moteur **ansible seulement** (le rôle lit les creds `envs/<terminus>/wm-admin`
dans Vault LUI-MÊME ; labctl ⇒ `COMBINAISON_NON_SUPPORTEE`, même raison que
labctl+direct : bearer-only, et il n'y a pas de proxy OAuth2 devant le
terminus). Le knob `ADMIN_VIA` ne pilote QUE les paliers intermédiaires. Deux
refus nommés, AVANT tout réseau : `TERMINUS_SANS_VOIE` (gabarit absent),
`COMBINAISON_NON_SUPPORTEE`.

**Écarté :** poser un proxy `wm-admin-prod` (rouvrirait ce que G4 a fermé par
structure) ; router prod par la chaîne governance (le parcours du demandeur
vit dans SON dépôt — ADR-076/081 ; « chaque saut visible sur SA PR »).

C'est le dessin de `ci/Jenkinsfile.rollback` (G6) — terminus par position,
deux voies — porté au seul autre endroit qui vise des paliers.

### D2 — Ouvrir le terminus reste un geste de credential, et il reste humain

- `setup-vault-envs.sh` seed `envs/<terminus>/wm-admin` (dérivé de la chaîne ;
  défauts = `WM_USER`/`WM_PASS` de `setup-vault.sh`, surchargeables
  `WM_<TERMINUS>_*`). **Pas** de `envs/<terminus>/admin-oauth` : aucune voie
  OAuth2 n'existe vers le terminus, en seeder une laisserait croire le
  contraire.
- La policy `operator-deploy` (`setup-vault-userpass.sh`) gagne la lecture de
  `secret/{data,metadata}/stoa/envs/<terminus>/wm-admin` — terminus dérivé,
  jamais « prod » en dur.
- Les policies `apply-<env>` et le pipeline hors-prod ne changent PAS. Déployer
  le terminus exige un humain du groupe d'annuaire (`apim-operator-prod` —
  oscar au lab) ; le repli AppRole machine reste refusé
  `DEPLOYER_GROUP_REQUIRED` (conséquence assumée, documentée dans
  `environments.yaml`).

### D3 — L'ITSM re-vérifié au dispatch de la chaîne d'équipe (§6ter)

Miroir d'A6 au seul site de dispatch de cette chaîne, APRÈS la garde
d'identité (§6bis — elle ne touche rien d'externe, elle reste première) et
AVANT Vault (§7 — aucun secret présenté avant ce verdict) :

- porte sans `itsmCheck` ⇒ rien (rec, int, homol) ;
- porte avec `itsmCheck` ⇒ `GET ${ITSM_URL}/changes/<change_ref>` doit rendre
  `status=approved`. **Trois refus distincts, jamais fondus** (forensics
  ADR-070) : `ITSM_NOT_CONFIGURED` (URL absente — un contrôle déclaré doit
  pouvoir s'exécuter), `ITSM_UNAVAILABLE` (HTTP ≠ 200/404, réponse illisible),
  `ITSM_NOT_APPROVED` (statut ≠ approved, ET change inconnu — un 404 n'est pas
  une panne, c'est un change qui n'existe pas).
- Le `change_ref` MERGÉ est re-vérifié en FORME (`REF_INVALIDE`, classe
  `[A-Za-z0-9._-]`) avant de devenir un segment d'URL : l'anti-TOCTOU vaut
  pour la forme aussi — la garde de la demande ne dit rien de ce qui a été
  mergé.

### D4 — Le tableau de bord dit la vérité

- Le corps de PR d'`api-promote-request.sh` décrit le flux RÉEL (merge ⇒
  webhook ⇒ pause nominative ⇒ import d'archive ⇒ résultat commenté) et,
  quand la porte d'arrivée déclare `itsmCheck`, l'ANNONCE avec la référence
  concernée — le lecteur sait avant de merger.
- Le commentaire de succès nomme les **trois identités, trois statuts** :
  `demandée par X, mergée par Y, portée par Z`. Le porteur (V_USER) est égal
  au mergeur par la garde — mais une égalité tenue par une garde doit se lire
  sur la PR, pas se déduire du code.

## Les preuves hors-ligne (jouées à l'écriture)

| Épreuve | Verdict |
|---|---|
| `scripts/test-team-promote-wiring.sh` | **160/0** — G7-a (nominal terminus : basic + `envs/prod/wm-admin`, jamais oauth2, base directe, UNE invocation, commentaire RELU tel que posté avec les trois identités), G7-b/c (refus terminus, moteur jamais lancé), G7-d (l'intermédiaire reste oauth2), G7-e (approved ⇒ dispatch), G7-f i-iv (draft / inconnu 404 / panne 503 / URL absente ⇒ refus nommé, moteur jamais lancé), G7-g (`REF_INVALIDE` sur la valeur MERGÉE) ; jetons nouveaux insérés dans la liste ORDONNÉE (`ordre_verdict` + `ordre_relatif_verdict`, mutations rejouées) |
| `scripts/test-env-chain.sh` | **11/0** — lecteurs `env_chain_terminus` / `env_chain_gate_itsm_check`, contre-épreuves source absente ⇒ refus fermé |
| `make lint-ci` | **8/8** (14 Jenkinsfile compilent, shellcheck, go test mock 68 tests) |

Le harnais du stub a un **défaut STRICT pour l'ITSM** : sans déclaration
explicite du cas, `/changes/<id>` rend 404 — la valeur qui refuse le plus. Un
cas nominal doit dire `set_itsm 200 approved` ; l'oublier ne peut pas verdir.

## Conséquences

- Le parcours complet est MÉCANIQUEMENT possible : quatre PRs (rec, int,
  homol, prod), chacune tableau de bord de son saut. La porte G7 du GOAL se
  prouve par builds Jenkins réels — export, quatre merges, quatre pauses
  répondues par le mergeur, contre-épreuve `PAYLOAD_PERIME` (webhook tiré sur
  une PR NON mergée ⇒ refus, moteur jamais lancé) et `ITSM_NOT_APPROVED` par
  build.
- Un client dont le terminus ne s'appelle pas « prod » ne change RIEN : la
  position décide, les noms suivent `environments.yaml`.
- Le saut prod de la chaîne d'équipe porte désormais le MÊME anti-TOCTOU ITSM
  que la chaîne governance — deux mondes, une règle.

## Limites nommées (héritées et maintenues, jamais maquillées)

- **`approverGroup` n'est toujours pas enforced au merge** — c'est la
  protection de branche (ADR-081) ; reste nommé de G2.
- **Le 4-yeux pipeline est inerte tant que `build-user-vars` manque**
  (`promoted_by=ci`) — le câblage mord sans changement le jour où le plugin
  nomme quelqu'un (G2/G5).
- **La parité d'état des deux moteurs = G8.** Le terminus n'accepte que le
  moteur ansible — un écart de plus à consigner au registre de parité.
- **Le client OAuth `ci-horsprod` reste partagé** entre paliers hors-prod
  (limite G5, parking n°2).
- `team-publish`/`team-apply`/`provision-apply` font toujours confiance aux
  identités du payload webhook (frère du C1) — hors périmètre, nommé.
