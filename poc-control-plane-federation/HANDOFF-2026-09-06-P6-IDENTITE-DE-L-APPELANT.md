# HANDOFF — P6 : le refus par défaut, sur la surface qui garde vraiment le dispatch

**Date :** 2026-09-06 · **Jalon :** P6 du GOAL `GOAL-posture-par-exposition-2026-09-04.md` · **ADR :** `adr/adr-096-identite-appelant-refus-par-defaut.md` · **Branche :** `provision/probe-dev`, **NON committé** (comme P2..P5).

---

## Ce qu'il faut savoir en trente secondes

Le jalon devait « réveiller le deny-by-default d'un port ». Sa prémisse était tombée (le mode d'accès d'un port garde `/invoke`, pas le dispatch `/gateway`). En cherchant la surface qui garde vraiment les APIs, on a trouvé pire que le jalon manquant :

> **La chaîne publiait des APIs `external` dont l'`ip-allowlist` — la règle propre de cette cellule depuis ADR-091 — n'était opposée par RIEN.** Le drapeau qui pose la règle (`EnforceInboundIdentifiers`) n'était positionné nulle part : ni CLI, ni manifeste, ni pipeline. La primitive Go existait, testée, morte. Et le read-back rendait pour cette policy un verdict `degraded — enforced au consommateur`, c'est-à-dire une phrase qu'aucune mesure ne soutenait.

P6 pose la règle, la vérifie, et supprime le verdict de complaisance. **48 ✅ / 0 ❌ au premier passage live**, dont la porte au plan de données et sa contre-épreuve.

---

## La porte, littéralement

Sur la webMethods 10.15 réelle, la MÊME API publiée par la chaîne, le MÊME appelant :

| Mesure | Résultat |
|---|---|
| allow-list de l'application **hors** de portée de l'appelant | **403** |
| allow-list remplacée par l'IP de l'appelant | **200** |
| allow-list remise hors de portée | **403** |
| **règle retirée**, allow-list toujours hors de portée | **200** ← la contre-épreuve |
| rôle rejoué après cette dérive hors bande | la règle est **re-posée**, 403 |
| troisième passage | converge, n'écrit rien |

Sans la quatrième ligne, le 403 des trois premières n'était attribuable à rien.

---

## Les faits produits mesurés (à ne pas re-découvrir)

Spike `scripts/spike-p6-deny-by-default.py`, **49 ✅ / 0 ❌**, neuf verdicts.

1. **Une API publiée sert n'importe qui.** Stage IAM vide, appel anonyme 200. Il n'y avait pas de refus par défaut à réveiller : il y en avait un à poser.
2. **Un identifier posé n'oppose rien.** Application souscrite, `ipAddressRange` écrit et relu, appelant hors plage : **servi**. C'est le fail-open qu'ADR-078 avait nommé en juillet.
3. **Un joker n'identifie personne.** `0.0.0.0-255.255.255.255` → **403**. On ne peut donc pas neutraliser le contrôle en élargissant la plage.
4. **`sys:defaultApplication` ne rouvre pas la porte.** Une seconde application souscrite sans identifier ne sauve pas l'appelant hors plage.
5. **⚠ DÉTACHER UNE ACTION LA DÉTRUIT.** `PUT /policies/{id}` qui retire une action du stage **supprime l'objet**. Les autres policies gardent un UUID mort : leur plan de données **continue de refuser** (403 — pas de fail-open), mais **leur prochaine activation échoue en 500** *« Policy action does not exist »*. Un `PUT` citant une action **valide** répare. **C'est le mécanisme du NPE que ce projet documentait depuis juillet** : personne n'avait supprimé l'action, il avait suffi de la détacher ailleurs.
6. **Deux actions au stage IAM : HTTP 409.** Les dimensions se fusionnent dans un objet unique ; elles ne s'empilent pas.
7. **Posable sur une API INACTIVE, survit à l'activation** → la tâche va avant l'activation.
8. **Survit au ré-import de contrat** (contrairement au tag de P3) → une seule passe.

---

## Ce qui a été livré

| Fichier | Rôle |
|---|---|
| `labctl/internal/render/render.go` | `CallerIdentityFor(perAPI)` + champ `Result.CallerIdentity` — dérivé de la moitié PER-API, jamais du bouquet |
| `labctl/cmd/labctl/posture.go` | `caller_identity` en JSON **et** en sortie texte (le journal du build le montre) |
| `labctl/internal/adapter/webmethods/enforce.go` | `verifyIPAllowlist` — lit l'action IAM, exige `allowAnonymous=false` + `(strict, ipAddressRange)`. **`missing`**, plus `degraded` |
| `labctl/internal/adapter/webmethods/selfservice.go` | `identifyRulesActionBody` (lookup PAR règle), `callerIdentityRules`, `ensureCallerIdentityAction` |
| `labctl/internal/adapter/webmethods/inboundauth.go` | `ipAllowlist` dans la config inbound + branchement dans `ensureIdentifyAction` |
| `labctl/internal/targets/targets.go` | `InboundAuth.IPAllowlist` → option `inboundIPAllowlist` |
| `labctl/internal/enforce/enforce.go` | pré-check : `external` sans `inboundAuth.ipAllowlist` = **violation nommée**, avant toute écriture |
| `ansible/roles/apim_publish_api/tasks/caller-identity.yml` | **le livrable** : une action par API, posée avant l'activation, read-back strict des deux côtés |
| `ansible/roles/apim_publish_api/tasks/inbound.yml` | ne touche **plus** au stage IAM (un axe, un propriétaire) — garde alias/strategy/scope |
| `ansible/roles/apim_publish_api/tasks/main.yml` | import de `caller-identity.yml` **avant** l'activation |
| `ansible/is-iam-action-split.yml` + `ansible/tasks/iam-action-split-one.yml` | la conversion jour-0 des actions partagées |
| `scripts/spike-p6-deny-by-default.py` | le spike, 9 verdicts |
| `scripts/test-p6-deny-by-default.sh` | la matrice A→D |
| `Makefile` | le harnais P6 entre au shellcheck de `lint-ci` |

**Épreuves neuves :** `posture_caller_identity_test.go` (4), `TestVerifyEnforcement_IPAllowlistMissingWhenNotDeclared`, `TestPrecheck_WebmethodsExternalWithoutIPAllowlistFails`, `TestPrecheck_IPAllowlistNotDemandedOutsideExternal`.

---

## Preuves

| Preuve | Commande | Résultat |
|---|---|---|
| Spike produit | `python3 scripts/spike-p6-deny-by-default.py all` | **49 ✅ / 0 ❌** |
| Matrice P6 | `bash scripts/test-p6-deny-by-default.sh` | **48 ✅ / 0 ❌**, rejouée à l'identique (4 mutations) |
| Go | `cd labctl && go test ./...` | **568 ✅ / 0 ❌** |
| Non-régression P2 | `bash scripts/test-p2-posture-producteur.sh` | 67 / 0 |
| Non-régression P3 | `bash scripts/test-p3-tag-plateforme.sh` | 24 / 0 |
| Non-régression P4 | `bash scripts/test-p4-global-policy.sh` | 38 / 0 |
| Non-régression P5 | `bash scripts/test-p5-https.sh` | 54 / 0 |

---

## Pièges de harnais rencontrés (et corrigés)

- **Le lab recycle la gateway toutes les ~20 min** (`cron */5` → `restart-wm.sh`, licence d'essai). Après une reprise, l'admin répond 200 en **lecture** bien avant d'accepter une **écriture** : `POST /apis` rend 400 et `PUT /policies` rend 500 pendant que `GET /apis` rend déjà 200. Une porte de disponibilité qui ne teste que la lecture laisse entrer le harnais trop tôt — et il rougit pour une raison qui n'est pas celle qu'il mesure. **La porte du spike ÉCRIT** (une API jetable, aussitôt supprimée), et son nom porte un UUID pour qu'un reste de run tué ne la bloque pas.
- **Le dispatch rend 404 « Service not found »** pendant plusieurs dizaines de secondes après une reprise, sur une API pourtant présente à l'admin. Toute mesure du plan de données passe par un `settle()` qui attend un code du **vocabulaire du jalon** (200/401/403).
- **Deux verts vacants écrits puis corrigés dans ce jalon même** : (1) les verdicts du spike étaient d'abord écrits **en dur** — « LA PORTE TIENT » s'affichait alors que les épreuves échouaient ; ils sont désormais **dérivés des mesures** ; (2) `get_action` rend `(record, code)` et le couple avait été lu à l'envers, si bien que « le détachement a DÉTRUIT l'objet » comparait un dict à 200. Corrigé, la mesure rend **404**.
- **L'enveloppe de `GET /apis` est `apiResponse`**, pas `apis` : un purgeur qui cherchait la mauvaise clé ne trouvait jamais rien, et la création suivante échouait en 400 sur un nom déjà pris — 400 qu'on aurait pu lire comme un fait produit.
- **L'IP de l'appelant est déterminée, pas devinée** : les appels partent du conteneur vers son adresse de réseau, et `docker inspect` la donne. Un joker aurait été plus court à écrire et n'aurait rien prouvé — il rend d'ailleurs 403.

---

## Ce qui reste

- **P7** — la porte de bout en bout par builds réels, et la contre-épreuve de tout le GOAL (un producteur qui se déclare moins exposé obtient exactement la même posture).
- **Écart #1 `threat-protection`** — inchangé, c'est une question client (dispositif gateway ou WAF en amont ?). Une API `internet` reste structurellement rouge à l'apply.
- **La conversion `is-iam-action-split.yml` a été jouée en mode AUDIT** (`-e apim_split_converge=false`, lecture seule) sur le lab : elle s'exécute, et elle trouve une situation réelle — *« 15 APIs, 26 policies, 3 actions IAM référencées, dont 1 PARTAGÉE : af8604b6-… »*. **La conversion elle-même n'a PAS été lancée** : elle réécrit les policies de plusieurs APIs et, si elle échouait en route, laisserait les APIs non converties non réactivables. C'est un geste d'exploitation, à faire à un moment choisi — `ansible-playbook -i ansible/inventory.lab.ini ansible/is-iam-action-split.yml`. Tant qu'elle n'est pas jouée, toute publication `external` d'une API partageant cette action sera refusée `ACTION_IAM_PARTAGEE` : c'est le comportement voulu, pas une panne.
- **Le côté Go garde sa stratégie d'objet PARTAGÉ** (`ensureMtlsIdentifyAction`, `ensureSelfServiceIdentifyAction`) : même risque de destruction croisée, **nommé** dans l'ADR plutôt que corrigé à la sauvette. À reprendre quand la chaîne GitOps repassera dans ce coin.
- **Rien n'est committé** : P2..P6 attendent ensemble sur `provision/probe-dev`.

---

## À annoncer au client

1. **Une API `external` gouvernée n'est plus joignable depuis une IP non déclarée.** Comme le HTTPS de P5, ce n'est pas la plateforme qui coupe, c'est le contrôle qui s'applique — mais la première publication gouvernée casse les appelants non recensés. **Le recensement des IP partenaires devient un préalable**, et c'est la contrepartie exacte du choix d'ADR-091 (`external` = partenaire énumérable).
2. **`internet` n'exige aucune allow-list**, et c'est délibéré : l'appelant public n'est pas énumérable.
3. **Un joker ne désactive pas le contrôle.** Pour lever la restriction, il faut changer l'exposition **au registre central** — donc passer par la gouvernance, ce qui est le but.
4. **Une conversion jour-0 est à jouer** sur tout environnement où plusieurs APIs partagent une action d'identification, avant la première publication gouvernée.
