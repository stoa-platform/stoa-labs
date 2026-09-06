---
title: "ADR-093 — Le tag de posture est posé par la plateforme, jamais par le demandeur : un espace de noms réservé dans le seul champ de tag écrivable, écrasé et relu deux fois."
sidebar_label: "ADR-093 : le tag posé par la plateforme (P3)"
status: "Acté et prouvé le 2026-09-05 — `go test ./...` **551 ✅ / 0 ❌** sur labctl (6 neuves), `go vet` propre ; matrice P3 **24 ✅ / 0 ❌** dont la porte BOUT EN BOUT sur la webMethods 10.15 RÉELLE et **5 mutations sur 5 rouges** ; P2 rejoué 67/0 ; `make lint-ci` vert."
maturite_technique: "✅ Le tag de la posture gouvernée est posé sur l'objet API par le rôle Ansible, dérivé par la même autorité que le bouquet (`labctl posture`), écrasant tout tag de posture écrit par le contrat du producteur, relu fail-closed (TAG_UNCONFIRMED) avant l'activation puis en fin de rôle. Sans coupure du data-plane (mesuré) : hors contrainte ADR-079, donc valable à tous les paliers. ⚠ Le tag n'est PAS un mécanisme de ciblage : P0 a réfuté le ciblage par tag des global policies — il est un fait d'inventaire et d'audit, lisible par `GET /tags`."
date: 2026-09-05
adr_number: 93
note: "Jalon P3 du GOAL posture-par-exposition. Le point dur n'était pas d'écrire un champ : c'était que le SEUL champ de tag écrivable de la 10.15 est celui que remplit la spec OpenAPI du producteur. La propriété ne pouvait donc pas se fonder sur « qui écrit en dernier » — d'où un espace de noms."
lié: "[[adr-092-posture-dans-la-chaine-du-producteur]], [[adr-091-taxonomie-exposition-table-de-verite]], [[adr-079-deploiement-promotion-multienv-import-archive]], [[adr-076-gitops-api-lifecycle-repo-per-project]]"
---

# ADR-093 — Le tag de posture est posé par la plateforme (P3)

**Statut :** Acté et prouvé le 2026-09-05. Hors ligne : `go test ./...` **551 ✅ / 0 ❌**, `go vet` propre. Live : matrice `scripts/test-p3-tag-plateforme.sh` **24 ✅ / 0 ❌** sur la wM 10.15 réelle (`poc-webmethods-real`), dont **5 mutations rouges**.

## Contexte

P2 (ADR-092) a fait entrer la posture dans la chaîne du producteur : le formulaire la collecte, le manifeste la déclare, le **registre central** la décide, et une déclaration plus faible est refusée par un code nommé relayé jusqu'à la PR. Mais rien de tout cela ne se voit **sur l'objet API**. Un exploitant qui regarde la gateway, un inventaire, un audit : aucun ne peut dire de quelle posture relève une API publiée.

P0 a mesuré le terrain, et deux de ses verdicts commandent entièrement ce jalon.

**Le champ `apiTags` est mort.** Inécrivable par toute surface essayée : `PUT /apis/{id}` nu rend **200 sans rien écrire**, `?overwriteTags=true` idem, l'enveloppe `apiResponse.api` rend 400, `PUT|POST /apis/{id}/tags` rend 500/400, `POST /tags` rend 405, le champ multipart à la création est ignoré. **Le seul porteur réel est `apiDefinition.tags`** — c'est-à-dire les `tags` de la spec OpenAPI — et c'est lui qu'indexe `GET /tags`.

**Donc le champ est PARTAGÉ avec le producteur.** La plateforme et le demandeur écrivent au même endroit. Le GOAL en tirait : « P3 doit écraser, pas compléter ».

**Et le tag n'est pas un mécanisme de ciblage.** Le spike A a réfuté le ciblage par tag des global policies (`API_TAG` est dans l'énum, se persiste, et ne sélectionne rien). Le tag est donc un fait d'**inventaire et d'audit**, pas un point d'application — ce qui ne le rend pas moins sensible : c'est ce que lira quelqu'un qui décide.

## Décision

### 1. Le tag est le NOM de la cellule, dans un espace de noms que la plateforme possède

`posture:<bouquet>` — `posture:vh-external`, `posture:m-internet`, `posture:m-internal-apikey`. Le bouquet est la cellule nommée de la table de vérité d'ADR-091 ; il y en a exactement dix, et deux cellules distinctes ne peuvent pas produire le même tag (épreuve d'injectivité).

Le préfixe `posture:` épouse la convention de tag déjà en vigueur dans le contrat UAC (`auth-exception:apikey`).

### 2. La propriété se fonde sur l'espace de noms, pas sur l'ordre d'écriture

Puisque le champ est partagé, « qui a écrit en dernier » ne peut rien fonder : le producteur repousse sa spec quand il veut. La règle est donc :

> **Tout tag portant le préfixe réservé appartient à la plateforme.** Le rôle les retire TOUS, puis pose exactement celui qu'il a dérivé.

Un contrat qui embarque `posture:m-internal` pour se déclarer plus anodin qu'il n'est **perd** ce tag ; il n'en gagne aucun. Mesuré live.

### 3. Écrasement de l'ESPACE DE NOMS, pas de la LISTE — et pourquoi le GOAL est amendé ici

Le GOAL disait « écraser, pas compléter ». Écraser la **liste entière** aurait été un dommage gratuit : les opérations OpenAPI **référencent leurs tags par nom** (`operation.tags`), et le contrat `apis/accounts-read.openapi.yaml` de ce dépôt en est l'exemple vivant — un tag `accounts` référencé par ses opérations. Les effacer casserait le regroupement documentaire du producteur **sans rien apporter à la sécurité**.

Ce que le jalon exige, c'est que le producteur ne puisse pas écrire **la posture** — pas qu'il perde ses étiquettes métier. L'écrasement porte donc sur l'espace de noms : **strictement plus fort qu'un ajout, strictement moins destructeur qu'un effacement**. Les deux moitiés sont tenues par des assertions distinctes, et chacune a sa mutation.

### 4. Une seule autorité, encore : le rôle ne compose rien

Le rôle ne concatène pas « préfixe + bouquet ». `labctl posture` rend désormais deux chaînes **finies** — `tag` et `tag_prefix` — dérivées par `render.PostureTag`, la fonction voisine de celle qui dérive le bouquet. Le rôle écrit `tag` verbatim et retire ce qui correspond à `tag_prefix`.

C'est la règle que P2 a posée (*la chaîne DEMANDE, elle ne re-décide pas*), appliquée à une chaîne de caractères. Une mutation le prouve : quand le rôle reprend le tag écrit par le producteur au lieu de celui de l'autorité, la porte vire au rouge.

### 5. Deux passes du MÊME fichier, et elles ne servent pas à la même chose

- **Pose, AVANT l'activation.** Toute écriture de définition est alors derrière (création, ré-import d'update, version minée) et l'API n'est pas en service. Une API dont le tag n'a pas pu être posé n'est donc **jamais activée**.
- **Relecture, en DERNIER mot du rôle.** Le rôle écrit encore après la pose (approbateurs, équipe, policies), et le mécanisme d'effacement est mesuré : **un `PUT` de définition sans `tags` efface le tag**, et `overwriteTags=false` n'en protège pas. La seconde passe **re-converge** puis relit.

Le fichier étant idempotent, la seconde passe ne coûte qu'un `GET` quand tout va bien.

### 6. Sans gouvernance, la plateforme ne pose RIEN — et le dit

Sans registre central (`POSTURE_NON_ARBITREE`, mode rejeu local d'ADR-092), il n'y a pas de posture gouvernée. Poser alors le tag de la posture **déclarée** reviendrait à laisser le demandeur choisir son propre tag, c'est-à-dire exactement ce que ce jalon interdit ; et retirer les tags réservés sans en poser aucun donnerait une API muette qu'on pourrait croire gouvernée. Le rôle ne touche donc à rien et l'annonce : `TAG_NON_ARBITRE`.

## Faits mesurés le 2026-09-05 sur la 10.15 réelle

- **Le `PUT /apis/{id}` de l'objet NU est accepté sur une API ACTIVE** : l'API reste active et le data-plane répond pendant toute l'opération. La pose du tag **ne croise donc pas la contrainte de zéro-coupure d'ADR-079** et n'est réservée à aucun palier. (Le refus 400 bien connu sur API active porte sur le `PUT` **multipart** de ré-import de contrat, pas sur celui-ci — la confusion entre les deux aurait fait croire P3 impossible hors dev.)
- **Le jeu de caractères d'un nom de tag est libre** : `:`, `/`, `.`, `-`, `=` sont tous acceptés et relus à l'identique. Le choix du séparateur est donc une décision de convention, pas une contrainte produit.
- **`GET /tags` indexe bien ce champ** : le tag posé y apparaît, ce qui donne à l'inventaire une surface de lecture globale.
- **L'enveloppe `{apiResponse:{api:…}}` est refusée en écriture** (400, « Both content stream and apiDefinition are empty ») : le `PUT` se fait sur l'objet **nu**.

## Ce que ce jalon a trouvé en chemin, et n'a pas corrigé

**`approvers.yml` est cassé sur le produit réel, et `owner` y est en lecture seule.** La tâche « Approbateurs » du rôle écrit avec l'enveloppe `{apiResponse:{api:…}}` : sur la wM 10.15 réelle elle rend **400**. Et même en objet nu, la relecture montre que **`owner` n'est pas écrit** (il reste `Administrator`). La tâche avait été prouvée contre le **mock** (`poc-webmethods`, :8090), qui accepte l'enveloppe et stocke le champ.

Ce n'est pas un défaut de P3 et ce n'est pas non plus un correctif d'une ligne : c'est **la décision client n°2 du GOAL** (« le fournisseur ou la catégorie ? »), dont la recherche disait déjà que `provider` et `owner` sont en lecture seule sur la gateway. Si l'information doit être portée, elle vit dans l'annuaire et le registre central, jamais dans l'objet API. Le harnais P3 **contourne explicitement** la tâche (équipe sans approbateurs ⇒ `APPROVERS_EMPTY`) et le dit dans son propre code, plutôt que de la faire taire.

## Conséquences

- **Un exploitant lit la posture sur la gateway.** `GET /tags` et le record de chaque API portent la cellule gouvernée. C'est un fait d'audit, pas un point d'application : P4 devra le rappeler, puisque le ciblage par tag est réfuté.
- **Le tag est un contrôle de sécurité que la gateway ne protège pas.** N'importe qui ayant les droits d'administration peut le réécrire. Ce que P3 garantit, c'est que **la chaîne** ne le laisse pas faire : à chaque passage du rôle, l'espace de noms est repris.
- **Une API publiée hors chaîne ne porte rien de fiable.** Le tag n'engage que si le rôle est passé. Le mode non arbitré le dit à voix haute.

## Épreuves

| Où | Quoi | Résultat |
|---|---|---|
| `cd labctl && go test ./...` | l'autorité : dérivation, injectivité, exception gouvernée, contrat JSON/texte avec la chaîne | **551 ✅ / 0 ❌** (6 neuves) |
| `bash scripts/test-p3-tag-plateforme.sh` §A | le tag suit le REGISTRE, pas la déclaration ; un refus ne rend aucun tag | hors ligne |
| §B (`ansible/test-tag-guards.yml`) | sans gouvernance : rien d'écrit, `TAG_NON_ARBITRE` au journal | hors ligne |
| §C | **la porte** : tag gouverné posé, tag forgé écrasé, tag métier préservé, un seul tag réservé, position des deux passes mesurée **dans le journal**, idempotence, survie à un ré-import | wM 10.15 **réelle** |
| §D | 5 mutations : non-retrait de l'espace de noms, écrasement des tags métier, reprise du tag du producteur, effacement postérieur à la pose (re-convergence), retrait de la relecture finale | **5/5 rouges** |
| `bash scripts/test-p2-posture-producteur.sh` | non-régression du jalon précédent | **67 ✅ / 0 ❌** |

## Ce que ce jalon ne fait pas

- Il ne pose **aucune policy** : le bouquet dérivé reste une exigence, pas une application (P4/P5).
- Il ne touche pas à la promotion par archive : le tag **survit** à l'archive (mesuré au spike D de P0), donc `apim_promote_api` n'a rien à changer — mais le tag d'une API promue est celui de l'env d'origine, ce qui reste correct puisque la posture est invariante par palier.
- Il ne corrige pas `approvers.yml` (voir plus haut) : c'est une décision client, pas une réparation.
