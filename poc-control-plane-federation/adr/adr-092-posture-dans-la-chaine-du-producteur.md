---
title: "ADR-092 — La posture entre dans la chaîne du producteur : le formulaire la collecte, le manifeste la déclare, le registre central la décide. Une déclaration plus faible est refusée par un code nommé, relayé jusqu'à la PR."
sidebar_label: "ADR-092 : la posture dans la chaîne du producteur (P2)"
status: "Acté et prouvé le 2026-09-05 — `go test ./...` **545 ✅ / 0 ❌** sur labctl (dont 21 neuves, 19 sur `labctl posture`), `go vet` propre ; matrice P2 hors ligne + BOUT EN BOUT sur le Gitea du lab ; 4 mutations sur 4 rouges ; `make lint-ci` vert (18 Jenkinsfile, knobs, shellcheck) SANS aucune nouvelle ligne de dette."
maturite_technique: "✅ Chaîne producteur complète : formulaire (2 listes), gabarit, manifeste, plan de PR, rôle Ansible et pipeline post-merge arbitrent tous contre LE MÊME registre central, via UNE seule autorité (`labctl posture`). Refus nommés relayés jusqu'au commentaire de PR, prouvés sur des dépôts réels. ⚠ Conséquence assumée : une API absente du registre ne peut plus être publiée (CLASSIFICATION_UNGOVERNED) — l'enregistrement par la gouvernance devient un préalable, pas une formalité. ⛔ Hérité de l'ADR-091 : `exposure=internet` reste structurellement rouge à l'apply tant que `threat-protection` n'a pas de surface mesurée."
date: 2026-09-05
adr_number: 92
note: "Jalon P2 du GOAL posture-par-exposition. Le point dur n'était pas de faire circuler deux champs de plus : c'était de décider QUI tranche, et de le faire sans réécrire la table de vérité une cinquième fois. La recherche de P0 rend ce point non négociable — la gateway ne protège AUCUN de ses champs en écriture, donc l'autorité doit rester hors d'elle."
lié: "[[adr-091-taxonomie-exposition-table-de-verite]], [[adr-076-gitops-api-lifecycle-repo-per-project]], [[adr-081-decision-au-merge]], [[adr-075-wm-admin-proxy-multienv]]"
---

# ADR-092 — La posture entre dans la chaîne du producteur (P2)

**Statut :** Acté et prouvé le 2026-09-05. Hors ligne : `go test ./...` **545 ✅ / 0 ❌**, `go vet` propre, `make lint-ci` vert. Bout en bout : demande réelle sur le Gitea du lab, PR réelle, commentaire réel — porte et contre-épreuve. 4 mutations sur 4 rouges.

## Contexte

P1 (ADR-091) a fait de `internal | external | internet` un vocabulaire gouverné, avec une table de vérité nommée et **une seule autorité** : `internal/render`. Mais tout cela vivait dans un binaire que la chaîne du producteur n'appelait nulle part. Le formulaire « publier une API » collectait huit champs, **aucun de posture** ; le manifeste de publication n'en portait pas ; le rôle `apim_publish_api` n'en connaissait pas le mot.

Deux faits mesurés bornent la conception :

1. **La gateway ne protège AUCUN de ses champs en écriture** (P0). Un champ de posture posé sur l'API n'est donc pas une garantie : c'est un miroir. L'autorité doit vivre **hors** de la gateway.
2. **Le registre central existe déjà et il est prouvé** (goal A5, `scripts/test-classification-central.sh`) : la classification d'intégrité y est assignée par la gouvernance de la donnée, clé `(owner, api)` où `owner` est l'identité **non éditable** injectée par le pipeline. Le trou « emprunt de ligne » y est fermé, l'ancrage (un faux `governance/` glissé dans le dépôt projet est ignoré) y est prouvé.

Le jalon ne consiste donc pas à inventer un mécanisme, mais à **brancher la chaîne producteur sur celui qui existe** — sans le dupliquer.

## Décision

### 1. La demande DÉCLARE, le registre DÉCIDE

Le formulaire collecte deux listes (`CLASSIFICATION`, `EXPOSURE`) ; `api-request.sh` les écrit dans `apis/<name>.publish.yml` ; le rôle les lit. Mais à aucun moment cette valeur ne décide : elle est **comparée** à celle du registre central, et c'est celle du registre qui dérive le bouquet.

| la demande… | verdict | code |
|---|---|---|
| concorde avec le registre | publie, posture du registre | — |
| déclare **plus fort** | publie, posture du registre, **écart signalé** | (avertissement `sur-provisionné`) |
| déclare **plus faible** | **refus** | `CLASSIFICATION_SPOOFED` |
| porte une valeur hors vocabulaire | **refus** | `INTEGRITY_INCONSISTENT` |
| porte une API absente du registre | **refus** | `CLASSIFICATION_UNGOVERNED` |
| ne déclare rien | **refus** | `POSTURE_MANQUANTE` |

**Pourquoi exiger une déclaration puisque le registre tranche ?** Parce qu'une demande qui n'engage rien ne peut pas être *reprise*. Sans déclaration il n'y a rien à comparer, donc rien à refuser, donc rien à apprendre à l'équipe. Le refus est le seul moment où le désaccord entre ce que l'équipe croit publier et ce que la gouvernance a décidé devient **visible**, et il devient visible **là où l'équipe regarde** : sur sa PR.

### 2. Une seule autorité, appelée — jamais réécrite : `labctl posture`

La chaîne producteur est en bash et en Ansible ; ni l'un ni l'autre ne peut importer du Go. La tentation était d'écrire la comparaison en Jinja. Elle est refusée, et pas par principe :

- l'intégrité est une **échelle** (un rang suffirait) ;
- l'exposition **n'en est pas une** (ADR-091 §7) — `internet` REMPLACE l'ip-allowlist par `threat-protection`, donc déclarer `internal` contre un `external` gouverné perd un contrôle, **et** déclarer `internet` contre ce même `external` en perd un autre. La seule formulation juste est la **contenance de bouquet**, dérivée de la table de vérité.

Une recopie Jinja de cela aurait été la **cinquième** copie du vocabulaire que P1 a passé un jalon à supprimer, sur l'axe le plus piégeux. D'où une commande, `labctl posture`, qui expose au shell la fonction que `labctl apply` exécute déjà — `resolveCentralClassification`, **la même**, avec les mêmes codes. Trois appelants, une implémentation :

```
formulaire Jenkins ─▶ api-request.sh ─┬─ §1b  labctl posture (vocabulaire seul, SANS registre)
                                       └─ §5b  labctl posture --classification-source ▶ commentaire de PR
        merge (ADR-081) ─▶ team-publish.sh ─▶ rôle apim_publish_api
                                                └─ posture.yml ─▶ labctl posture --classification-source
```

### 3. Deux moments, et ce n'est pas une redondance

**Au plan de la PR** (`api-request.sh` §5b) : l'arbitrage a lieu **après** l'ouverture de la PR, délibérément. Le refus doit être *relayé* : une PR qui n'existe pas ne porte aucun commentaire, et un demandeur qui ne lit que le log d'un build n'apprend rien. Le verdict `❌ PLAN EN ÉCHEC — NE PAS MERGER : [CLASSIFICATION_SPOOFED] …` est **le livrable de ce jalon côté humain**.

**Au rôle** (`posture.yml`) : l'arbitrage est rejoué avant le premier appel à la gateway, avant les secrets. Le plan est un **avis précoce**, pas une autorisation — entre le plan et le merge, le registre a pu changer, et le manifeste a pu être édité sur la branche. C'est le motif « champ requis aux deux couches » déjà éprouvé sur cette chaîne.

### 4. Ce qui refuse AVANT la PR, et ce qui refuse APRÈS

La ligne de partage n'est pas arbitraire :

- **défaut de la DEMANDE** (champ vide, valeur hors vocabulaire) → refus **avant tout geste Git**, rien n'est écrit ;
- **panne d'INFRASTRUCTURE** (registre injoignable, absent, binaire d'autorité manquant) → refus **avant tout geste Git** aussi : ce n'est pas la faute du demandeur, et lui ouvrir une PR pour y coller un ❌ ferait porter le chapeau à la mauvaise personne ;
- **désaccord avec la GOUVERNANCE** (downgrade, API non enregistrée) → PR ouverte, refus **relayé dans son commentaire** : c'est une conversation entre l'équipe et la gouvernance, elle a besoin d'un lieu.

### 5. Le registre vit dans un dépôt SÉPARÉ, et c'est tout l'ancrage

`GOVERNANCE_REPO` / `GOVERNANCE_PATH` désignent un dépôt que **ni l'équipe API ni la plateforme d'exécution** n'écrivent — chez le client, le dépôt `data-governance`. Il est cloné **frais sur `main`** à chaque demande et à chaque publication, jamais lu dans le worktree : même discipline que `providers.<env>.yml`, et pour la même raison. Un registre que l'équipe pourrait éditer ne serait que sa propre déclaration relue deux fois.

Ces deux knobs n'ont **aucune valeur par défaut**. La porte `ci/lint-config-knobs.sh` l'impose, et elle a raison ici plus qu'ailleurs : un repli de lab ferait publier une API sous une gouvernance qui n'est pas celle du client, **sans le dire**. Absents, les scripts refusent en se nommant (`CHAMP_REQUIS : GOVERNANCE_REPO`).

### 6. Le formulaire est un miroir de plus, donc il est épinglé

Le XML du job ne peut pas importer du Go non plus. Ses deux listes déroulantes sont donc pinnées à `render` par une épreuve de dérive, `TestProducerFormVocabularyDoesNotDrift` — exactement le mécanisme que P1 a posé pour le schéma JSON. Sans elle : une valeur offerte au demandeur mais inconnue du moteur produit un refus que le demandeur n'a pas causé ; une valeur gouvernée mais absente de la liste est simplement inatteignable, en silence. Rien d'autre ne lit ce fichier.

## Ce que P2 ne fait pas

- **Il ne pose rien sur la gateway.** La posture décide du bouquet ; poser le **tag** dérivé sur l'API est P3, et P0 a déjà mesuré que le champ n'est pas celui qu'on croyait (`apiDefinition.tags`, pas `apiTags`, et tout `PUT` sans `tags` l'efface).
- **Il n'enforce pas les policies.** Le pré-check et le read-back restent ceux d'ADR-076/091, côté `labctl apply`.
- **Il ne touche pas la chaîne consommateur** (`app-request`) ni la promotion (`api-promote-*`).

## Limites, assumées et nommées

1. **Une API non enregistrée ne peut plus être publiée.** C'est le comportement gouverné voulu (le registre le dit depuis A5 : *« une API absente d'ici ne peut pas déployer »*), mais il déplace un préalable dans le parcours réel : la PR gouvernance doit précéder la première demande. Le commentaire de PR le dit en toutes lettres ; le runbook client doit le dire aussi.
2. **Le manifeste ne déclare pas de tenant.** L'équipe est l'unité de cloisonnement de cette chaîne, et l'ancre anti-spoof est le couple `(équipe, api)` — non éditable. `labctl posture` accepte donc qu'aucun tenant ne soit **réclamé** (rien à falsifier) tout en refusant un tenant réclamé et faux, exactement comme `labctl apply`. Le tenant gouverné est **rendu** et journalisé.
3. **Le mode « sans registre » existe** (`apim_pub_classification_source` vide) : le rôle se comporte comme avant ce jalon. Ce n'est pas une porte dérobée mais le mode rejeu local, et il est **bruyant** (`POSTURE_NON_ARBITREE`). Ce qui empêche le silence, c'est que la chaîne, elle, pose toujours la source — vérifié par une épreuve de câblage et par une mutation.
4. **`exposure=internet` reste rouge à l'apply**, hérité de l'écart #1 d'ADR-091. La chaîne producteur sait désormais le déclarer, le gouverner et le refuser ; elle ne sait toujours pas le déployer.

## Preuve

| épreuve | rejeu |
|---|---|
| moteur + autorité CLI (21 épreuves neuves) | `cd labctl && go test ./...` → **545 ✅ / 0 ❌** |
| dérive du formulaire vs moteur | `go test ./internal/render/ -run TestProducerForm` |
| matrice P2 (A→H : autorité, formulaire, gabarit, gardes, rôle, câblage, **bout en bout**, mutations) | `bash scripts/test-p2-posture-producteur.sh` |
| garde de posture du rôle, hors ligne | `ansible-playbook -i ansible/inventory.lab.ini ansible/test-posture-guards.yml -e …` |
| non-régression de la porte producteur | `bash scripts/test-api-request.sh` → **28 ✅ / 0 ❌** |
| portes CI (Jenkinsfile, knobs, shellcheck) | `make lint-ci` |

**Les quatre mutations** (chacune restaurée à l'octet près, chacune vérifiée par une épreuve de COMPORTEMENT — jamais par un grep de la ligne qu'on vient de retirer) :

| sabotage | ce qui tombe |
|---|---|
| le registre n'atteint plus l'autorité | la garde `source == central` du rôle |
| la garde de présence accepte une posture vide | le refus cesse d'être **nommé** `POSTURE_MANQUANTE` |
| `CLASSIFICATION` n'est plus obligatoire | `CHAMP_REQUIS : CLASSIFICATION` disparaît |
| le gabarit ne porte plus la classification | le manifeste rendu ne déclare plus de posture |
