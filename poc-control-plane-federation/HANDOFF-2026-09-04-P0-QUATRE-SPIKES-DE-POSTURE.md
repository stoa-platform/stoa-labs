---
title: "P0 — les quatre spikes qui décident de la conception : quatre verdicts, dont deux qui déplacent le GOAL"
type: handoff
jalon: P0
goal: GOAL-posture-par-exposition-2026-09-04.md
date: 2026-09-04
preuve: "scripts/spike-p0-posture.py — 45 ✅ / 0 ❌ sur la wM 10.15 RÉELLE (poc-webmethods-real), rejoué"
status: "LIVRÉ — les quatre verdicts sont rendus. DEUX sont négatifs et changent des jalons : le ciblage par tag est RÉFUTÉ (P4), et le deny-by-default d'un port ne garde pas les APIs (P6). Un ADR est corrigé (ADR-078 §8)."
---

# P0 — quatre verdicts

**Ce que P0 devait produire** (GOAL, § P0) : *« quatre verdicts écrits, chacun avec la commande et la sortie qui l'établissent »*. Les voici. Tout a été mesuré sur l'instance **réelle** (`poc-webmethods-real`, wM API Gateway 10.15), jamais sur un contrat publié — et sur trois points, l'instance dit autre chose que le contrat.

Rejeu intégral :

```
python3 scripts/spike-p0-posture.py all      # 45 ✅ / 0 ❌
python3 scripts/spike-p0-posture.py A        # un spike à la fois
```

Le script ne pose rien de durable : actifs jetables `spikep0-*`, ménage en sortie, et une **garde d'intégrité** finale (voir l'incident, § 5).

---

## 1. Spike A — le ciblage par tag est RÉFUTÉ ; le ciblage par nom est PROUVÉ

### Le point dur du GOAL, tranché

Le GOAL laissait ouverte une contradiction interne au contrat de l'éditeur : `filterType` ne vaut que `[API, HTTP_METHOD]`, mais la description du même champ cite « tags », et `attributeName` expose `API_TAG`. **L'instance tranche, et pas dans le sens espéré.**

Les énumérations réelles, obtenues en faisant échouer volontairement la désérialisation :

```
ScopeConditionType : [HTTP_METHOD, API]
AttributeNames     : [HEAD, RESOURCE_OPERATION_TAG, API_VERSION, API_TAG, GET,
                      API_DESCRIPTION, PATCH, DELETE, METHOD_TAG, PUT, POST, API_NAME]
Operator           : [STARTS_WITH, GREATER_THAN, LESS_THAN, NOT_STARTS_WITH,
                      NOT_EQUALS, ENDS_WITH, EQUALS, NOT_CONTAINS, CONTAINS]
```

`API_TAG` est donc **accepté, valide, et persisté** dans la policy. Il ne sert à rien.

### Le modèle réel n'est pas celui que la recherche avait déduit

La recherche prévoyait `scopeConditions[].attributeName`. C'est faux : `ScopeCondition` n'a que **`filterType`, `logicalConnector`, `attributes`**, et `Attribute` n'a que **`value`, `attributeName`, `operation`**. La forme qui passe :

```json
{"filterType":"API","logicalConnector":"AND",
 "attributes":[{"attributeName":"API_TAG","operation":"EQUALS","value":"spikep0-vh"}]}
```

### La mesure, avec son témoin et sa contre-épreuve

| Scope | frappe l'API taguée | frappe l'API sans tag |
|---|---|---|
| `HTTP_METHOD` seul (**témoin positif**) | OUI | OUI |
| `API` seul (`API_NAME`) | **non** | non |
| `HTTP_METHOD` **+** `API_NAME` | **OUI** | non |
| `HTTP_METHOD` **+** `API_TAG` | **non** | non |

Deux faits, et le second n'était dans aucune source :

1. **Une condition `filterType: API` ne sélectionne RIEN toute seule.** Elle n'agit que **combinée à une condition `HTTP_METHOD`**. C'est ce qui a fait échouer les premières tentatives, tag comme nom — et c'est ce qui aurait fait conclure à tort que « les global policies ne marchent pas ».
2. **Combinée correctement, la sélection par NOM mord et discrimine ; la sélection par TAG ne mord sur rien**, y compris avec `CONTAINS` et y compris sur un tag préexistant (`accounts`) porté par trois APIs du lab.

Jusqu'au **plan de données**, avec une action d'identification stricte :

```
plan de données sous global policy par NOM : taguée=401  sans-tag=200
CONTRE-ÉPREUVE : policy désactivée → l'appel repasse en 200
```

### Pourquoi le tag ne peut pas mordre : `apiTags` est un champ mort

Le GOAL supposait `apiTags` écrivable (« tableau de chaînes libres »). Sur l'instance, **il n'est écrivable par aucune surface trouvée** :

| tentative | résultat |
|---|---|
| `PUT /apis/{id}` (objet nu) avec `apiTags` | **200 — et rien n'est écrit** (no-op menteur) |
| `PUT /apis/{id}?overwriteTags=true` | **200 — rien écrit** |
| `PUT /apis/{id}` enveloppé `apiResponse.api` | 400 « content stream and apiDefinition are empty » |
| `PUT` / `POST /apis/{id}/tags` | 500 / 400 |
| `POST /tags` | 405 |
| champ `apiTags` au multipart de création | 201, `apiTags` reste `null` |

**Le seul porteur de tag réel est `apiDefinition.tags`** — les `tags` OpenAPI —, il s'écrit sans difficulté par `PUT /apis/{id}` (objet nu), et c'est **lui** qu'indexe `GET /tags` (`{"tags":["accounts","spikep0-vh"]}`). Autrement dit : le tag visible de la gateway vient de **la spec du producteur**, et le scope `API_TAG` regarde un **autre champ**, qui reste vide.

> **Piège de méthode à retenir** : `GET /apis/{id}/tags` renvoie **le record complet de l'API** en 200. Les sous-chemins inconnus sont avalés. Sur cette gateway, **aucun 200 ne vaut preuve** — seule la mutation compte.

**Verdict A.** Ciblage par tag **RÉFUTÉ**. Le repli nommé par le GOAL — `API_NAME` + convention de nommage — est **prouvé disponible et discriminant**, à la condition non documentée d'être accompagné d'une condition `HTTP_METHOD`.

---

## 2. Spike B — la liste du port ne garde pas les APIs

### Les deux surfaces sont une seule liste

`/rest/apigateway/ports/{listenerKey}/accessMode` **existe** (ADR-078 §8 disait le contraire — corrigé). Et les deux surfaces pilotent **la même liste**, vérifié dans les deux sens :

- `PUT` REST `{"services":["pub.date:getCurrentDate"]}` → le formulaire WmRoot affiche exactement `pub.date:getCurrentDate` ;
- `addNode` par le formulaire → le REST relit `["pub.date:getCurrentDate","wm.server:ping"]`.

Sémantiques opposées, en revanche : le **REST réécrit en bloc** (13 entrées → 1 après un `PUT` d'une seule entrée : aucune opération additive, donc deux publications concurrentes s'écrasent) ; le **formulaire est additif**. Le choix du formulaire par ADR-078 reste le bon — mais pour la **concurrence**, pas parce que le REST manquerait.

### Ce que la liste garde vraiment

Mesuré sur un listener HTTP **jetable** (`:5598`), jamais sur `:5555` :

```
mode ALLOW :  /gateway/<api> → 200    /invoke/wm.server:ping → 200
POST accessMode=deny  (mutation confirmée : la liste se peuple de 13 services IS)
mode DENY  :  /invoke/wm.server:ping        (LISTÉ)     → 200
              /invoke/pub.date:getCurrentDate (NON listé) → 403 PortAccessException [ISS.0084.9101]
              /gateway/<api>/1.0.0/ping                  → 200  ← réponse du backend incluse
```

L'ACL est **vivante** — elle suit la liste à la mutation près. Et elle garde **`/invoke`**, c'est-à-dire les services de l'Integration Server. **Le dispatch de l'API Gateway lui échappe entièrement.**

**Verdict B.** La prémisse de P6 tombe : inscrire une API dans l'allow-list d'un port ne la protège de rien, l'en retirer ne la ferme pas. Le code écrit le 2026-07-15 n'est pas seulement **mort** (`apim_ss_port_manage: false`, personne ne le pose à `true`) — il est **braqué sur la mauvaise surface** pour l'objectif annoncé.

---

## 3. Spike C — la forme réelle d'un port HTTPS, et ce qu'elle ne fait pas

Le contrat publié décrit un `Port` **entièrement en chaînes**, sans `keystoreAlias`. Le record réel du listener `:5543` porte **24 champs absents du contrat**, dont ceux qui décident de tout :

```json
{"keyStore":"DEFAULT_IS_KEYSTORE","trustStore":"DEFAULT_IS_TRUSTSTORE",
 "clientAuth":"request","alias":"ssos","accessMode":"allow","services":[],
 "hostsList":[],"ipAccessType":"global","listenerKey":"HTTPSListener@5543", …}
```

Le keystore se désigne **par alias**, jamais par chemin. Et la forme relue **se rejoue** : `POST /ports` avec le record recopié (moins `uniqueID`/`key`/`listenerKey`/`primary`) crée le listener, `PUT /ports/enable {"listenerKey":…}` l'active, et la relecture confirme le bon keystore. Quirk de réponse à connaître : le `POST` renvoie la **clé** dans le champ `port` (`"port":"HTTPSListener@5599"`).

**Et surtout** — c'est le fait qui redéfinit l'axe 1 : l'API **est bien servie** sur le nouveau listener HTTPS (le dispatch la reconnaît nommément), mais elle est **refusée** :

```
{"Exception":"… Error Message:  Transport protocol not supported..
  Request Details: Service - spikep0-plain, Operation - /ping …"}
```

…par **son propre `entryProtocolPolicy`**, réglé sur `http`. Ajouter un listener HTTPS ne change **rien** au protocole accepté par une API. Le levier « HTTPS obligatoire » est **par API**, sur l'étage `transport` — exactement le mécanisme de `labctl/internal/adapter/webmethods/transport.go:89`, à porter côté rôle.

**Verdict C.** Forme relevée, rejeu prouvé, axe 1 automatisable. Mais l'axe « port HTTPS » et l'axe « API joignable seulement en HTTPS » sont **deux choses disjointes**, et c'est la seconde qui porte la posture.

> **Caveat de lab, à ne pas confondre avec un fait produit** : les listeners créés par `POST /ports` **n'ont pas survécu** à un redémarrage du conteneur du lab. À rejouer sur une instance à configuration persistée avant d'en conclure quoi que ce soit sur le produit.

---

## 4. Spike D — le tag survit à l'archive, et disparaît au premier update

- **Le tag est dans les octets de l'archive** (`GET /archive?apis=<guid>`, zip de zips — il faut descendre d'un niveau pour le voir).
- **Il survit à l'aller-retour** `POST /archive?overwrite=apis`, **GUID iso**.
- **Un `PUT /apis/{id}` dont la définition ne porte pas de `tags` EFFACE le tag** — et `?overwriteTags=false` ne l'en protège pas (`tags = []` après coup). Un `PUT` avec les tags les repose.

**Verdict D.** L'attribut est promouvable — il traverse la chaîne des cinq paliers. Mais toute mise à jour de définition le perd silencieusement : **re-pose + relecture fail-closed après CHAQUE écriture**, sinon la posture s'évapore au premier déploiement suivant. C'est la contre-épreuve que P3 devra porter, et elle est plus dure que ce que le GOAL supposait : le piège n'est pas `overwriteTags`, c'est le `PUT` lui-même.

---

## 5. Incident mesuré — et devenu une garde

Pendant l'exploration, la **suppression d'une global policy de test a supprimé en cascade la policyAction qu'elle référençait** — en l'occurrence l'action **système** `GlobalLogInvocationPolicyAction`, partagée avec la policy système « Transaction logging ». Conséquence immédiate : cette policy système référençait un fantôme, et **toute activation d'API tombait en `NullPointerException`** (le piège déjà documenté, `scripts/repair-wm-dangling-policyaction.sh`). Un redémarrage de la gateway a reconstitué l'action système ; aucune donnée du lab n'a été perdue.

Ce n'est pas un accident de manipulation, c'est un **fait produit de premier ordre pour P4** : un pipeline autorisé à créer et supprimer des global policies peut, par une suppression parfaitement légitime, **briquer le chemin d'activation de toute la gateway**. À verser à la décision client n°4 (« élargit-on l'allow-list du proxy d'administration à `POST /policies` ? ») — la question n'est pas seulement « qui peut changer la posture de toutes les APIs », c'est aussi « qui peut casser l'activation de toutes les APIs ».

Le spike ne peut plus le reproduire : il **clone** l'action de log au lieu de référencer celle du produit, **vide les enforcements avant toute suppression**, et se termine par une garde d'intégrité (`l'action SYSTÈME de log est intacte` / `aucune policy ne référence d'action fantôme`).

---

## 6. Ce que P0 déplace dans le GOAL

| Jalon | Effet des verdicts |
|---|---|
| **P1** taxonomie | Inchangé — décision client n°1 toujours ouverte. |
| **P2** exposition dans la chaîne | **Renforcé.** Le registre central n'est plus « la bonne pratique » : la gateway n'a **aucun** champ de classification protégé, et le seul tag écrivable vient de **la spec du producteur** — donc du spoofable par construction. |
| **P3** tag posé par la plateforme | **Change de champ et de contrainte.** Le tag se pose dans `apiDefinition.tags`, jamais dans `apiTags` (mort). Et il faut le **re-poser après chaque `PUT`**, pas seulement surveiller `overwriteTags`. |
| **P4** policies communes par global policy | **Bascule sur le repli.** Le ciblage par tag est réfuté ; reste `API_NAME` + convention (prouvé, avec la condition `HTTP_METHOD` obligatoire) ou le fan-out déjà prouvé. Le GOAL le dit au lieu de le maquiller. |
| **P5** HTTPS | **Simplifié et recentré.** Le levier est `entryProtocolPolicy` par API ; le listener est un objet d'environnement qui ne décide de rien pour l'API. La porte de P5 est déjà à moitié mesurée ici. |
| **P6** deny-by-default | **Prémisse tombée.** Ce jalon ne peut pas être « réveiller le mécanisme » : le mécanisme ne garde pas les APIs. À réécrire, ou à fermer en constatant que la protection cherchée n'existe pas sur cette surface. |
| **P7** porte de bout en bout | Inchangé dans son principe ; sa matrice devra porter le tag `apiDefinition.tags` et le protocole d'entrée, pas l'inscription au port. |

---

## 7. Ce que P0 n'a PAS établi

- **Pourquoi `API_TAG` ne matche pas.** On mesure qu'il ne matche ni `apiTags` (vide) ni `apiDefinition.tags` (rempli). On n'a pas établi *quel* champ il interroge — il se peut qu'aucun ne soit alimentable en 10.15. Suffisant pour décider, insuffisant pour l'affirmer à un éditeur.
- **Le stage `IAM` en global policy** n'est prouvé que **combiné à un scope par nom** (rayon d'action = notre seule API jetable). Un scope large avec IAM n'a **pas** été essayé : il aurait exigé une identification sur toutes les APIs du lab.
- **La persistance d'un port créé par REST** au redémarrage (voir le caveat du spike C).
- **Rien sur Apigee, Kong, WSO2, AWS** : la recherche n'avait pas pu les couvrir, P0 ne l'a pas fait non plus.
