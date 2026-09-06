# HANDOFF — P3 : le tag de posture est posé par la plateforme (2026-09-05)

**Jalon P3 du GOAL `posture-par-exposition`. LIVRÉ. ADR-093.**
`go test ./...` **551 ✅ / 0 ❌** · matrice P3 **24 ✅ / 0 ❌** (dont la porte BOUT EN BOUT sur la webMethods 10.15 **réelle** et **5/5 mutations rouges**) · P2 rejoué **67 ✅ / 0 ❌** · `make lint-ci` vert, **sans ligne ajoutée à la dette**.

**RIEN N'EST COMMITTÉ NI POUSSÉ** (branche `provision/probe-dev`, comme P2).

## Rejeu

```bash
cd poc-control-plane-federation
cd labctl && go test ./... && cd ..          # 551/0
bash scripts/test-p3-tag-plateforme.sh        # 24/0 — A,B hors ligne ; C,D exigent poc-webmethods-real
bash scripts/test-p2-posture-producteur.sh    # 67/0 — non-régression
make lint-ci                                  # 17/17
```

La section C **mute la gateway réelle** : elle crée `p3tag-<epoch>`, la publie, la met à jour, puis la supprime (trap). Les mutations sabotent `tag.yml` / `main.yml` et les restaurent à l'octet près (`cmp`). Si `poc-webmethods-real` est en train de se recycler (~20 min de keepalive), le harnais **attend jusqu'à 400 s** avant de sauter la section en le disant.

## Ce qui a été livré

| Fichier | Rôle |
|---|---|
| `labctl/internal/render/render.go` | `PostureTagPrefix` + `PostureTag(bundle)` — le tag est **dérivé** à côté du bouquet |
| `labctl/cmd/labctl/posture.go` | `tag` et `tag_prefix` dans la sortie JSON, `tag:` en sortie texte |
| `ansible/roles/apim_publish_api/tasks/tag.yml` | **NEUF** — pose, écrasement de l'espace de noms, relecture fail-closed `TAG_UNCONFIRMED` |
| `ansible/roles/apim_publish_api/tasks/main.yml` | deux appels du **même** fichier : pose avant l'activation, relecture en dernier |
| `ansible/test-tag-guards.yml` | **NEUF** — la branche non arbitrée, hors ligne |
| `scripts/test-p3-tag-plateforme.sh` | **NEUF** — la matrice |
| `adr/adr-093-…md`, `GOAL-…md` | la décision et son statut |
| `Makefile` | `scripts/lib/posture-authority.sh` entre dans le shellcheck (gap laissé par P2) |

## Les quatre faits qui ont décidé de la conception

1. **Le `PUT /apis/{id}` de l'objet NU passe sur une API ACTIVE, sans coupure.** Mesuré : l'API reste active, le data-plane répond pendant l'opération. Le refus 400 bien connu porte sur le `PUT` **multipart** de ré-import de contrat. **Conséquence : P3 ne croise pas ADR-079 et vaut à tous les paliers** — l'inverse aurait cantonné le jalon à dev.
2. **Le seul champ de tag écrivable est celui du producteur.** `apiTags` est mort (P0) ; `apiDefinition.tags` porte les `tags` de la spec OpenAPI. La propriété ne peut donc pas se fonder sur l'ordre d'écriture ⇒ **espace de noms réservé** `posture:`, repris à chaque passage du rôle.
3. **Écraser la liste entière aurait été un dommage gratuit.** Les opérations OpenAPI référencent leurs tags par nom ; `apis/accounts-read.openapi.yaml` de ce dépôt en est l'exemple (tag `accounts`). Le GOAL disait « écraser » ; l'ADR-093 **amende** : écrasement de l'espace de noms, pas de la liste. Plus fort qu'un ajout, moins destructeur qu'un effacement — deux assertions, deux mutations.
4. **Le jeu de caractères d'un nom de tag est libre** (`:` `/` `.` `-` `=` tous acceptés et relus à l'identique), et **`GET /tags` indexe bien ce champ**. Le séparateur est une convention, pas une contrainte.

## Les deux passes, et pourquoi la seconde n'est pas décorative

- **Pose avant l'activation** : une API dont le tag n'a pas pu être posé n'est **jamais activée**.
- **Relecture en dernier mot** : le rôle écrit encore après (approbateurs, équipe, policies), et un `PUT` de définition sans `tags` **efface** le tag (spike D de P0).

Un sabotage nu de la seconde passe ne prouverait rien — sur le chemin de mise à jour, la **pose** répare déjà, et aucun écrivain actuel du rôle n'efface après elle : le harnais resterait vert. **Un vert vacant, du type que P1 a trouvé en mesurant la couverture.** La mutation 4 **injecte** donc l'écriture postérieure (une réécriture de définition qui rétablit le tag du contrat) et mesure le rôle deux fois : avec la relecture, il **re-converge** et le prouve ; sans elle, il passe vert en laissant le tag du **producteur**.

## ⚠ Trouvé en chemin, NON corrigé — c'est la décision client n°2

**`approvers.yml` est cassé sur le produit réel.** Son `PUT` **enveloppé** (`{apiResponse:{api:…}}`) rend **400** (« Both content stream and apiDefinition are empty ») sur la wM 10.15 ; et même en objet **nu**, la relecture montre que **`owner` n'est pas écrit** (il reste `Administrator`) — le champ est en **lecture seule**, exactement ce que la recherche du GOAL disait de `provider`/`owner`.

La tâche avait été prouvée contre le **mock** (`poc-webmethods`, :8090), qui accepte l'enveloppe et stocke le champ. Ce n'est donc pas une régression : c'est une **divergence mock / produit** restée invisible tant que personne n'avait fait tourner ce chemin sur la 10.15.

Ce n'est pas un correctif d'une ligne : si l'information d'approbateurs doit être portée, elle vit dans l'annuaire et le registre central, pas dans l'objet API. **Le harnais P3 contourne la tâche explicitement et par écrit** (équipe sans approbateurs ⇒ `APPROVERS_EMPTY`) plutôt que de la faire taire. À trancher avec le client avant P7, qui traversera la même tâche.

## Pièges payés dans cette session

- **`go build -o … ./cmd/labctl` produit une archive `ar`, pas un exécutable** : le `main` est à la racine de `labctl/`. Le symptôme est un `command -v` qui échoue, donc un `POSTURE_AUTORITE_ABSENTE` qui accuse le poste au lieu du build. `scripts/lib/posture-authority.sh` fait la bonne chose ; l'appeler plutôt que bricoler un build à la main.
- **Ansible affiche le NOM des tâches SAUTÉES.** Une sonde « aucune écriture tentée » écrite comme `grep -q 'PUT /apis'` sur le journal est **verte quoi qu'il arrive** — le nom de la tâche contient le motif. Ce qui distingue « sautée » de « jouée », c'est le récapitulatif (`changed=0 failed=0`). Piège payé ici même, dans la section B.
- **Une mutation décrite en `sed` sur du Jinja ne mord pas.** Guillemets, accolades, tildes : l'expression finit ré-échappée et le sabotage ne change rien — mutation **muette**, donc vert menteur. Les mutations de ce harnais sont décrites en **Python** (`s = s.replace(…)`) et vérifiées par `cmp`.
- **Un playbook de garde doit vivre dans `ansible/`** : sinon le `roles_path` relatif au playbook ne trouve pas le rôle (`the role 'apim_publish_api' was not found`). D'où `ansible/test-tag-guards.yml`, comme `ansible/test-posture-guards.yml`.
- **`shellcheck` du Makefile tourne à la sévérité par défaut** : l'idiome `cond && ok || ko` y sort 15 notes SC2015. C'est pourquoi les harnais `test-p2-*` / `test-p3-*` restent hors de cette liste, comme tous leurs semblables ; seule la **bibliothèque** `posture-authority.sh` y entre.

## Reste

**P4..P7.** P4 dispose du fait `pub_posture` (bundle, policies, authn, tenant, source) **et** du tag, désormais posé et relu — mais il ne peut pas s'en servir pour **cibler** : le ciblage par tag est réfuté (P0, spike A), le repli est `HTTP_METHOD` + `API_NAME` ou le fan-out. Le tag reste un fait d'**inventaire et d'audit**.

Et, comme après P2 : **servir gitea/origin**. Tant que le dépôt plateforme n'est pas servi, le job du lab checkoute l'ancien rôle, et le `labctl` du conteneur `poc-jenkins` (2026-07-02) ne connaît ni `posture` ni son champ `tag`.
