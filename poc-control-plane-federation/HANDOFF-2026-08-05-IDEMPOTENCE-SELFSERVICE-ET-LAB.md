# HANDOFF — 2026-08-05 : le rôle self-service réécrivait la gateway à chaque apply, et le compteur ne pouvait pas le voir

_Dépôt `stoa-labs`. Commits `84d0c40` (correctif + test) et `6163624` (script
d'élévation), sur `origin/main` ET `gitea/main` (fusions `82ae208`/`3803942` sur
la lignée gitea). Preuve finale : builds Jenkins `selfservice-app-deploy` #25/#26._

## En une phrase

Le retour de terrain « Ansible est éphémère dans le pipeline, donc pas
d'idempotence — faut-il sauvegarder l'inventory ? » désignait le mauvais
suspect : l'idempotence Ansible ne se sauvegarde pas, elle se **recalcule en
lisant la cible** — et c'est le rôle qui ne lisait pas avant d'écrire, pendant
qu'un `changed=0` structurellement vert masquait tout.

---

## 1. Le diagnostic, mesuré avant de toucher quoi que ce soit

Trois applies successifs du **même** manifeste (`demo-consumer`), commande
exacte du pipeline, gateway wM réelle :

| | `lastupdated` | UUID identifier `ip-allowlist` | PLAY RECAP |
|---|---|---|---|
| run 1 | 11:29:00 | `13fe3ee4…` | `changed=0` |
| run 2 | 11:29:23 | `35e7ae73…` | `changed=0` |
| run 3 | 11:30:01 | `ec73c6f9…` | `changed=0` |

Deux faits, dont le second est le plus grave :

- **l'identifier est détruit et recréé à chaque run** — même valeur, UUID neuf.
  wM ne met pas les identifiers à jour en place. Coût : références par id
  cassées en silence (export/import, audit, reprise), piste d'audit qui bouge
  sans changement, fenêtre de non-identification à chaque recréation, PUT sur
  une API active hors du cadre [[ADR-079]] ;
- **`changed=0` toujours** — y compris sur le run qui retirait réellement la
  team `Default`. `ansible.builtin.uri` ne fait AUCUNE détection de changement :
  il rend `ok` qu'il ait écrit ou non. Le compteur d'idempotence du pipeline ne
  pouvait pas voir le défaut — même famille que les cinq garde-fous verts du
  handoff 2026-08-03/04.

**Ce que l'inventory n'y était pour rien** : `inventory.lab.ini` fait deux
lignes, zéro état, versionné. Le sauvegarder n'aurait rien changé. Pas de state
file à inventer non plus : il introduirait la dérive state/réel que le modèle
Ansible évite précisément.

## 2. Cause racine : cinq écritures inconditionnelles

| # | Écriture | Fichier | Garde ajoutée |
|---|---|---|---|
| 1 | `POST /assets/team` | `team.yml` | la relecture fail-closed existante joue aussi AVANT |
| 2 | `PUT /applications/{id}/apis` | `main.yml` | `consumingAPIs` déjà porté par la liste relue en §2 |
| 3 | `PUT /applications/{id}` (identifiers) | `main.yml` | empreinte `key/name/value` des dimensions gérées |
| 4 | `PUT /policyActions/{id}` | `backend.yml` | comparaison `headerKey`/`headerValue` |
| 5 | `PUT /applications/{id}` (auth) | `consumer-auth.yml` | claim `openIdClaims` + appartenance à `authStrategyIds` |

La #5 n'était pas dans le diagnostic initial : trouvée en auditant les fichiers
restants — non exercée par `demo-consumer` (pas de bloc `auth:`), mais elle
frappait tous les manifestes OAuth2, donc le chemin idp des builds webhook.

Aucun appel REST supplémentaire : la donnée de comparaison était déjà relue
partout. Le patron correct existait déjà dans les mêmes fichiers
(`ss_iam_attached`, `bk_hdr_id not in bk_routing_ids`) — il n'avait simplement
pas été appliqué aux cinq autres. Et `changed_when:` explicite posé sur toutes
les écritures : le recap est redevenu un signal.

**Deux pièges de comparaison** qui auraient produit des gardes vertes inutiles :

- comparer le record fusionné au record relu ne marche PAS — la gateway ajoute
  un `id` à chaque identifier, absent de l'ensemble désiré : les dicts diffèrent
  TOUJOURS. Comparer les seuls champs gouvernés par le manifeste, valeurs triées ;
- `active` est EXCLU de la comparaison des policyActions : la gateway ne le
  relit jamais (mesuré — les 10 actions rendent `active=false`, y compris
  celles créées avec `active: true`). L'inclure ferait diverger à tous les coups.

## 3. Le test discriminant — et pourquoi il a cette forme

`scripts/test-idempotence-selfservice.sh`, **vérifié ROUGE (6/10) sur le code
d'avant**, 10/10 après. Il n'exige pas seulement `changed=0` au re-run — le code
buggé le donnait déjà. Il exige AUSSI :

- `changed>0` sur le run qui CRÉE (un compteur toujours nul échoue) ;
- une écriture qui REPART quand le manifeste change (un rôle qui n'écrit plus
  jamais passerait sinon pour idempotent — il serait juste mort) ;
- la gateway **immobile au re-run**, mesurée sur `(lastupdated, UUID
  identifiers, teams)` — pas sur le recap.

Non-régression : cert-rotation 7/7 (purge overlap comprise — la zone la plus
exposée par la garde #3), backend-key 27/27, internal-dcr 45/45, auth-audience
13/13, cert-path-resolution 16/16, cert-format 12/12, verify du pipeline vert.

## 4. Publication : la divergence gitea, prise correctement cette fois

Le push gitea a d'abord été **rejeté** — la réf de suivi locale était périmée
(jamais de `fetch gitea` dans la session). L'écart réel : gitea/main portait
**52 commits** (onboarding paliers 1/2) absents de `main`. Fusion sur branche
jetable, **zéro conflit**, puis — parce que les deux lignées touchaient les
mêmes fichiers (la sonde `apim_teams_enabled` côté gitea, les gardes côté main)
— **preuves rejouées sur l'arbre fusionné** avant push : 10/10, 7/7, 13/13,
verify vert.

Résiduel assumé : `origin/main` (GitHub) n'a toujours PAS les 52 commits
d'onboarding — décision d'intégration à prendre (mémoire : le squash GitHub y
produit des conflits add/add trompeurs).

## 5. Remise en état du lab — Vault dev-mode est EN MÉMOIRE

Le job Jenkins ne pouvait pas prouver l'E2E : le restart Vault d'il y a ~40 h
avait tout effacé, re-seed partiel. Séquence complète rejouée (détail pas-à-pas
dans la mémoire `vault-user-password-login`) :

1. mots de passe frais → `.env.lab-users` (gitignoré 0600) — les `*-lab-2026`
   sont **brûlés** (publics) ;
2. ⚠ `docker rm -f -v poc-openldap` d'abord : `up -d` REDÉMARRE le vieux
   conteneur avec l'annuaire d'époque (mots de passe brûlés), et le seed
   « ignore les entrées existantes » — logins refusés sans explication ;
3. `setup-vault-userpass.sh` + `setup-vault-ldap.sh` (alice/bob/carol/oscar,
   mount `ldap`, mapping groupe→policy) ;
4. `setup-vault.sh` — `CI_APPLIER_SECRET` récolté via kcadm (realm `stoa-lab`),
   `OPENSEARCH_PASSWORD` dans l'env du conteneur opensearch ;
5. entrées témoin `deploy/{banking-demo,payments-team}/demo` (T6 du harnais) ;
6. mot de passe gateway des `svc-*` réaligné sur Vault — ⚠ le rôle d'onboarding
   REPREND le mot de passe Vault existant et ne re-pose jamais celui d'un user
   gateway déjà créé : cette dérive-là se répare à la main ;
7. équipes `banking-demo`/`payments-team` via `ansible/onboard-team.yml`
   (lignée gitea) — `ONBOARD_OK` + `VERIFY_OK` ×2 ;
8. `svc-*` ∈ **API-Gateway-Administrators** : `POST /assets/team` est un geste
   d'ADMIN (build #24 rouge sinon). Le classifieur bloque l'élévation depuis
   l'agent → `scripts/fix-svc-admin-group.sh` + `! bash` (relecture fail-closed
   intégrée).

Preuve : `test-vault-user-login.sh` **37/37**.

## 6. La preuve finale — l'idempotence par le pipeline réel

| Build | Résultat | Ce qu'il prouve |
|---|---|---|
| #24 | FAILURE | 401 sur `POST /assets/team` → a désigné l'étape 8 ci-dessus |
| #25 | **SUCCESS** | converge `changed=1` (cloisonnement `banking-demo` — le SEUL vrai changement, correctement signalé), verify `TEAM/ENFORCEMENT/OUTBOUND_CONFIRMED`, token nominatif révoqué avec preuve de mort |
| #26 | **SUCCESS** | converge `changed=0`, `IDENTIFIERS_CONVERGED` + `BACKEND_HEADER_CONVERGED` en console, **record gateway strictement identique** (UUID `25bf9f58` inchangé, `lastupdated` figé) |

Constat au passage : `POST /assets/team` ne bump PAS `lastupdated` de
l'application (opération de scope asset).

## 7. Ce qu'il faut retenir

- **« Éphémère donc pas idempotent » est un faux syllogisme** : un contrôleur
  Ansible jetable est le mode nominal. Si le re-run réécrit, c'est que le code
  n'a pas de lecture-avant-écriture — l'état de référence est LA CIBLE.
- **`uri` ne compte jamais `changed`** : tout rôle bâti dessus a un recap
  décoratif tant que `changed_when` n'est pas posé tâche par tâche. Un compteur
  qui ne peut pas devenir rouge ne garde rien.
- **Un test d'idempotence doit tester les deux sens** : immobilité au re-run ET
  reprise d'écriture au changement. Et être vérifié rouge sur le code d'avant.
- **Comparer des dicts entiers relus à des dicts désirés échoue par
  construction** dès que le serveur enrichit ses réponses (`id`, `active`) :
  comparer les champs gouvernés, rien d'autre.

## 8. Reste ouvert

- intégration des 52 commits d'onboarding vers GitHub (décision à prendre) ;
- question client d'origine : leur pipeline a très probablement le même défaut —
  le plan de correction (lecture-avant-écriture + `changed_when` + test
  discriminant) est transposable tel quel ;
- MFA annuaire = toujours la question bloquante n°1 de la voie A (ADR-078).
