# HANDOFF — G7 : le parcours du demandeur, une PR, un tableau de bord

**Session du 2026-08-27.** Branche `provision/probe-dev`, lot G7 (spec, plan,
7 commits de code/docs). **Gitea est servi au fil de l'eau** (les jobs ont
tourné sur la définition G7). ADR-086 ; parcours opérateur
`ENVIRONNEMENTS.md` § « Le parcours du demandeur (G7) » ; GOAL : **restent G8
uniquement** (G1-G7 faits).

| Porte | Nature | Résultat |
|---|---|---|
| Parcours complet dev→rec→int→homol→prod | **BUILDS Jenkins réels** | `api-promote-export #2` puis `team-promote` **#18/#19/#20/#24 SUCCESS** — 4 PRs (#22-25), GUID `14c2529e-…003` actif et IDENTIQUE sur les 4 paliers |
| Contre-épreuve du GOAL (PR jamais mergée) | build | **#25 FAILURE `PAYLOAD_PERIME`** — webhook forgé sur PR #26 ouverte, moteur jamais lancé (`PLAY`=0), catalogue rec inchangé (n=1) |
| Contre-épreuve ITSM (anti-TOCTOU au dispatch) | build | **#26 FAILURE `ITSM_NOT_APPROVED`** — la MÊME PR verte en #24 refuse dès que CHG-0001 repasse `draft` |
| `scripts/test-team-promote-wiring.sh` | hors-ligne | **160/0** (G7-a..g : voie terminus, ITSM ×4, REF_INVALIDE au mergé, commentaire RELU tel que posté) |
| `scripts/test-env-chain.sh` | hors-ligne | **11/0** (lecteurs `env_chain_terminus` / `env_chain_gate_itsm_check` + refus fermés) |
| `make lint-ci` | intégral | **8/8** |

## Ce qui est livré

1. **La voie du TERMINUS par POSITION** (`team-promote.sh` §1bis, miroir du
   dessin G6) : dernier palier ⇒ voie DIRECTE (`EFFECTIVE_VIA=direct`,
   `APIM_DIRECT_BASE_TPL`, moteur ansible seul — labctl refusé
   `COMBINAISON_NON_SUPPORTEE`), refus `TERMINUS_SANS_VOIE` avant tout réseau.
   `ADMIN_VIA` ne pilote plus QUE les paliers intermédiaires.
2. **§6ter — l'ITSM re-vérifié au dispatch de la chaîne d'équipe** (miroir
   A6) : `ITSM_NOT_CONFIGURED` / `ITSM_UNAVAILABLE` / `ITSM_NOT_APPROVED`
   (404 = change inconnu = NOT_APPROVED), fail-closed, entre §6bis et §7 ;
   `ITSM_URL` knob Jenkinsfile (défaut `http://itsm-mock:8788`) ; la classe
   `REF_INVALIDE` re-vérifiée sur le change_ref MERGÉ (segment d'URL).
3. **Ouvrir le terminus = geste de credential** : `setup-vault-envs.sh` seed
   `envs/<terminus>/wm-admin` (dérivé de la chaîne, knobs `WM_<TERMINUS>_*`),
   JAMAIS de admin-oauth terminus ; policy `operator-deploy` étendue au
   secret du terminus (dérivé aussi).
4. **Le tableau de bord dit la vérité** : corps de PR réécrit (le paragraphe
   « ce merge n'applique rien » était périmé depuis G5), annonce itsmCheck à
   la demande, commentaire d'apply à TROIS identités (demandée / mergée /
   **portée**), et le CORPS du refus produit remonte sur la PR
   (`return_content` + capture `.{1,400}`).
5. **`wm-mock-prod`** (compose) — terminus du LAB, **seul mock sur le réseau
   `poc`** : le terminus s'attaque en direct par le pipeline, c'est son
   contrat, pas une entorse à la ségrégation.

## LA MESURE de la session — la limite mock→réel (builds #21/#23)

Le saut prod initial visait la gateway RÉELLE : toutes les portes G7 sont
passées (itsm approved, operator-deploy, palier ouvert, voie directe), puis le
PRODUIT a refusé l'import — **HTTP 400 « No assets found in the ACDL import
file »**. L'ACDL du produit est un `asset_composite` aux namespaces
SoftwareAG avec des payloads d'assets de qualité produit ; celui du mock est
une imitation minimale. Rendre l'export du mock importable par le produit =
réimplémenter la persistance du produit — REFUSÉ (non borné, sans valeur
client : en engagement réel, tous les paliers sont des gateways réelles).
D'où le terminus mock homogène ; le verbe réel→réel reste prouvé par ADR-079
(22/22, rejoué G5 contre cette même gateway).

## Gestes faits en session (état du lab)

- Push gitea au fil de l'eau (les jobs lisent la définition G7).
- Vault : `envs/prod/wm-admin` = creds de `wm-mock-prod` ; policy
  `operator-deploy` étendue ; **grants** (ADR-082) : bob += `apply-rec,
  apply-int` (userpass), carol += `apply-homol` — le mount de pause du lab est
  `userpass` ; les groupes LDAP (annuaire n°2 : bob=int, carol=homol,
  oscar=prod) sont posés et vérifiés (`setup-deployer-groups.sh` 9/0), et le
  login `ldap/` projette les mêmes policies (mesuré).
- Gitea : utilisateurs **bob et carol créés** (+ tokens g7-*, collaborateurs
  write sur `banking-demo/accounts-api`) ; PRs #22-25 = la trace du parcours ;
  PR #26 fermée (sonde) ; **toutes les branches `promote/*` purgées** (⚠ ne
  jamais rejouer leurs webhooks : no-op VERT, piège G5).
- Jenkins : variable globale **`APIM_DIRECT_BASE_TPL` =
  `http://wm-mock-prod:8080/rest/apigateway`** (knob de LAB — chez un client
  le défaut du Jenkinsfile vise la gateway réelle). Posée par script console.
- ITSM : CHG-0001 restauré `approved`.
- Catalogues : t10-promote-api ACTIF sur rec/int/homol/**prod**, GUID iso —
  c'est l'état nominal de la preuve. Authoring (webmethods-mock) inchangé.
- Tokens gitea de session dans le scratchpad (`g7-tokens.env`) — périssables
  avec la session ; en recréer par `gitea admin user generate-access-token`.

## Pièges mesurés (à ne pas redécouvrir)

- **zsh ne word-split pas** les variables non quotées (`for e in $envs` → un
  seul tour) et son builtin `.` cherche dans `$PATH` un nom sans slash
  (`. .env.lab-users` échoue ; `. ./.env.lab-users` marche).
- **La capture du corps ré-échappé** : `"content": "[^"]*` s'arrête au premier
  `\"` — utiliser `.{1,400}` (mesuré build #22 : seul `{\` remontait).
- **Fenêtre keepalive** : le wM réel recycle ~20 min ; le saut #21 a été lancé
  APRÈS un cycle frais (attente du restart mesurée sur `StartedAt`).
- Le webhook forgé sur PR ouverte DÉCLENCHE le build (le filtre regex ne voit
  que le payload) — c'est la réconciliation §2 qui refuse ; la pause est donc
  répondue AVANT le refus, et c'est voulu (l'identité ne précède jamais la
  vérité de la PR).

## Restes (après G7)

- **G8** — parité d'état des deux moteurs (dernier jalon du GOAL). Écart de
  plus au registre : le terminus n'accepte que le moteur ansible.
- `origin` (GitHub) en retard depuis G5 — le CI lit Gitea ; push optionnel.
- Frère du C1 : team-publish/team-apply/provision-apply croient encore les
  identités du payload — hors périmètre, nommé.
- 4-yeux pipeline inerte tant que `build-user-vars` manque (`promoted_by=ci`).

## Où lire le détail

- **ADR** : `adr/adr-086-parcours-demandeur-pr-tableau-de-bord.md` (tableau
  des 9 builds + la limite mesurée).
- **Spec** : `docs/superpowers/specs/2026-08-27-g7-parcours-du-demandeur-design.md`.
- **Plan** : `docs/superpowers/plans/2026-08-27-g7-parcours-du-demandeur.md`.
- **Parcours opérateur** : `ENVIRONNEMENTS.md` § « Le parcours du demandeur (G7) ».
