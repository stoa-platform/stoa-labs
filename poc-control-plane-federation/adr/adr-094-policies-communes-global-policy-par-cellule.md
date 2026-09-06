---
title: "ADR-094 — Les policies communes d'une cellule sont portées par UNE global policy par cellule : l'objet est posé au jour 0 avec un identifiant Administrateur, le pipeline n'y inscrit que des noms d'API, et le quota est gouverné."
sidebar_label: "ADR-094 : le bouquet commun en global policy (P4)"
status: "Acté et prouvé le 2026-09-06 — `go test ./...` **557 ✅ / 0 ❌** sur labctl (10 neuves), `go vet` propre ; matrice P4 **38 ✅ / 0 ❌** dont la porte BOUT EN BOUT sur la webMethods 10.15 RÉELLE (quota mesuré au plan de données) et **6 mutations sur 6 rouges**, rejouée ; spike P4 **35 ✅ / 0 ❌** (7 verdicts) ; P2 rejoué 67/0, P3 rejoué 24/0 ; `make lint-ci` vert."
maturite_technique: "✅ Une global policy par cellule nommée de la table de vérité (`posture-<bouquet>`), portant `audit-log` + `rate-limit` avec le QUOTA gouverné de la cellule. Posée et activée par un play d'amorçage sous identifiant Administrateur ; le rôle de publication n'y fait qu'inscrire le NOM de son API (GET+PUT), en le retirant des autres cellules, avec double relecture fail-closed. ⚠ Le ciblage par tag reste RÉFUTÉ (P0) : le scope cible par `API_NAME`, obligatoirement combiné à une condition `HTTP_METHOD` sans laquelle il ne sélectionne rien."
date: 2026-09-06
adr_number: 94
note: "Jalon P4 du GOAL posture-par-exposition. Trois faits produits, tous mesurés en cours de route, ont commandé la conception : une condition de scope `API` SANS attribut sélectionne TOUTES les APIs (d'où une sentinelle) ; une `policyAction` n'a AUCUNE identité qu'on puisse écrire (d'où la policy comme ancre) ; et le stage `threatProtection` est refusé par /policies (d'où l'écart #1 d'ADR-091 précisé, pas levé)."
lié: "[[adr-093-tag-de-posture-pose-par-la-plateforme]], [[adr-092-posture-dans-la-chaine-du-producteur]], [[adr-091-taxonomie-exposition-table-de-verite]], [[adr-075-wm-admin-proxy-multienv]], [[adr-076-gitops-api-lifecycle-repo-per-project]]"
---

# ADR-094 — Le bouquet commun porté par une global policy par cellule (P4)

**Statut :** Acté et prouvé le 2026-09-06. Hors ligne : `go test ./...` **557 ✅ / 0 ❌**, `go vet` propre. Live : `scripts/test-p4-global-policy.sh` **38 ✅ / 0 ❌** sur la wM 10.15 réelle (`poc-webmethods-real`), dont **6 mutations rouges**, rejouée à l'identique. Spike préalable : `scripts/spike-p4-global-policy.py` **35 ✅ / 0 ❌**, sept verdicts.

## Contexte

P1 a nommé les dix cellules de la table de vérité et leur bouquet ; P2 a fait décider ce bouquet par le registre central ; P3 l'a rendu lisible sur l'objet API. Il restait à l'**appliquer** — et à l'appliquer une fois par cellule, pas une fois par API : c'est le test du GOAL, *« porter les policies communes de son niveau sans que personne ne les ait recopiées »*.

P0 avait déjà **réfuté** la voie que le besoin décrivait : `API_TAG` est dans l'énumération réelle, se persiste dans la policy, et ne sélectionne **rien**. Le repli était identifié et prouvé jusqu'au plan de données : `API_NAME`, **obligatoirement combiné à une condition `HTTP_METHOD`** — sans elle, une condition `API` ne sélectionne aucune API.

Restaient sept inconnues que ni le contrat de l'éditeur ni la documentation ne couvrent. Le spike P4 les a levées avant qu'une ligne ne soit écrite.

## Ce que le spike a mesuré (2026-09-05, wM 10.15 réelle)

| # | Question | Verdict |
|---|---|---|
| S1 | Une condition `API` peut-elle porter **plusieurs** `API_NAME` ? | **Oui**, en `logicalConnector: OR` — donc **une policy par CELLULE**, pas une par API. Témoin négatif : le même montage en `AND` ne sélectionne rien (le connecteur est bien lu). |
| S2 | L'appartenance se modifie-t-elle à chaud par le seul `GET`+`PUT` ? | **Oui**, dans les deux sens, sur une policy **active**, sans désactiver/réactiver — et le `PUT` de scope laisse les `policyEnforcements` intacts. |
| S3 | `throttle` (stage `LMT`) : forme réelle, et mord-il ? | **Oui** — 429 au plan de données au-delà du quota, et l'API hors scope n'est pas limitée. La forme n'est **dans aucun contrat publié** : relevée dans les templates du produit puis rejouée. |
| S4 | Le stage `threatProtection` est-il portable par une policy ? | **Non.** `/policies` le REFUSE (HTTP 400, `NullPointerException`) pour deux filtres différents et pour les deux portées. Sa seule surface est `/administration/threatprotection`, **gateway-wide**. |
| S5 | `https-only` en global policy entre-t-il en conflit avec l'action `transport` de la Default Policy de chaque API ? | **Non**, il s'active et l'appel en clair est refusé sur la seule API ciblée. *(Premier passage : faux vert — la mesure lisait le 429 du quota de S3. Corrigé par une API dédiée.)* |
| S6 | Contre-épreuve : retirer le ciblage rend-il l'appel ? | **Oui**, 200 revient. |
| S7 | Une condition `API` **sans attribut**, et la sonde d'appartenance sur une API **inactive** | ⚠ Une condition vide sélectionne **TOUTES** les APIs de la gateway. La sonde, elle, **répond sur une API inactive**. |

**Et un huitième fait, découvert en construisant :** `POST /policyActions` accepte un `names` et rend 201 — puis l'objet relu porte le **nom par défaut de son template** (« Log Invocation », « Traffic Optimization »), et `descriptions` reste vide. **Une policyAction n'a aucune identité qu'on puisse écrire.** Le premier rôle, qui les indexait par nom, en a créé 120 orphelines en quatre passages.

## Décision

### 1. Un objet par cellule, nommé, et le NOM est la seule ancre

Une global policy `posture-<bouquet>` par cellule nommée — dix objets. Le nom d'une **policy**, lui, est écrit et relu tel quel ; celui d'une **action** ne l'est pas. Les actions d'une cellule sont donc atteintes **par leur policy** (`policyEnforcements[].enforcements[].enforcementObjectId`), et par aucun autre chemin. La policy est le parent, les actions sont ses enfants.

### 2. Ce que la cellule porte : ce qui est commun, mesurable et sans propriétaire ailleurs

| Policy du bouquet | Côté | Pourquoi |
|---|---|---|
| `audit-log` | **commun** | stage `LMT`, action `logInvocation` — identique dans toutes les cellules |
| `rate-limit` | **commun** | stage `LMT`, action `throttle`, **avec le quota de la cellule** — mesuré mordant au plan de données |
| `https-only` | per-API | **mesuré portable** (S5) et laissé dehors **exprès** : P1 le vérifie déjà au read-back sur le `transportProtocol` de l'API. Déplacer l'APPLICATION vers un objet partagé pendant que la VÉRIFICATION continue de lire l'API, c'est ainsi qu'un contrôle cesse discrètement d'être vérifié. **P5 possède l'axe HTTPS, listener compris** — un axe, un propriétaire. C'est l'arbitrage que le GOAL laissait ouvert entre P4 et P5, et il est tranché ici, dans ce sens, avec la mesure au dossier pour le jour où P5 réunira les deux moitiés. |
| `threat-protection` | per-API | le stage existe côté produit mais `/policies` le refuse ; sa seule surface est gateway-wide, donc **indéclinable par cellule** (S4) |
| `ip-allowlist` | per-API | aucune surface de policy, et la forme « identifiant d'application » est mesurée **fail-open** (ADR-078) |
| `oauth2` / `mtls` / `apikey` | per-API | le stage `IAM` exige l'issuer, l'audience et l'alias **propres à l'API** |

La coupure est **mécanique** : `render.commonCarriable` décide, `Derive` répartit, et une épreuve exige que l'union soit le bouquet et l'intersection vide. Une policy qui tomberait entre les deux moitiés ne serait posée par personne — pendant que le demandeur lirait qu'elle l'est.

### 3. Le quota est GOUVERNÉ par cellule, parce qu'un `rate-limit` sans nombre n'est pas un contrôle

L'ensemble des policies communes est le **même dans les dix cellules** — les deux sont un plancher depuis P1. La seule chose qui peut distinguer deux bouquets communs est donc le **quota**. Et un quota que personne ne gouverne serait écrit par qui écrit l'objet, c'est-à-dire, à terme, par le demandeur : exactement ce que ce GOAL interdit.

La table de vérité gagne donc une colonne. Même discipline que P1 : **une cellule sans quota est un refus**, pas une cellule sans limite (épreuve par mutation à chaud).

Les valeurs sont des **défauts raisonnés, et une décision client** : le quota se resserre quand la population d'appelants s'élargit (l'ensemble interne est borné et identifié, le public ne l'est pas) et, à exposition égale, quand l'enjeu d'intégrité monte. Ce que P4 livre, c'est le mécanisme qui rend le nombre gouverné et appliqué par la machine ; les nombres eux-mêmes appartiennent au client.

|  | internal | external | internet |
|---|---|---|---|
| **VH** | 120/min | 60/min | 30/min |
| **H** | 300/min | 150/min | 60/min |
| **M** | 600/min | 300/min | 120/min |

(`m-internal-apikey` : 600/min, comme `m-internal`.)

### 4. La frontière des verbes : le pipeline n'a que GET et PUT

**Créer, activer et converger le contenu** d'une global policy appartiennent à un **play d'amorçage** (`ansible/apim-global-posture-setup.yml`), joué avec un identifiant **API Gateway Administrator** — un niveau *provider* ne suffit pas. Un autre identifiant, un autre moment, un autre journal.

Ce n'est pas une précaution de style. P0 a mesuré que **supprimer une global policy supprime en cascade ses `policyActions`, action SYSTÈME comprise**, et met toute activation d'API en NPE jusqu'au redémarrage. Les trois verbes retirés au pipeline sont exactement les trois qui portent ce risque. Ce qui lui reste, `GET` + `PUT /policies/{id}`, est aussi tout ce que l'allow-list du proxy d'administration (ADR-075) expose.

*(Corollaire mesuré pendant la mise au point : la cascade joue aussi quand un `PUT` **retire** un enforcement — les dix actions `entryProtocolPolicy` orphelinées par le passage de trois à deux actions ont disparu d'elles-mêmes. Bénin ici parce que ces actions n'appartenaient qu'à nous ; le jour où l'on référencerait une action du produit, ce serait l'incident du P0.)*

Le rôle de publication ne **supprime jamais**, ne **crée jamais**, n'**active jamais**. Il ne touche qu'au `scope`, en repartant de l'objet qu'il vient de lire, et il vérifie ensuite que les `policyEnforcements` n'ont pas bougé. Cette construction protège de l'accident et du bug ; elle ne protège pas d'un opérateur qui aurait déjà l'identifiant, et l'ADR le dit plutôt que de le laisser croire.

### 5. Rejoindre SA cellule, c'est QUITTER les autres

Le rôle retire le nom de l'API de **toutes** les cellules, remet la sentinelle, puis le rajoute à la sienne — le même calcul pour toutes, donc impossible à décaler. Sans le retrait, une API reclassée resterait membre de son ancienne cellule et porterait **deux quotas contradictoires**, sans que rien ne dise lequel fait foi. La relecture l'exige explicitement, et la mutation D5 le prouve.

### 6. La sentinelle : on ne vide jamais une liste de membres

Une condition `filterType: API` **sans attribut** ne sélectionne pas « aucune API » : elle les sélectionne **toutes** (S7). Une cellule créée vide au jour 0, ou vidée par le retrait de son dernier membre, appliquerait donc son quota à la gateway entière. La liste porte toujours `__posture_aucune_api__`, un nom qu'aucune API ne porte — mesuré, lui aussi, comme ne sélectionnant rien.

### 7. Deux relectures, parce qu'il y a deux façons différentes d'échouer

1. **la LISTE** — ce qui est persisté dans le scope. Sur cette gateway un `PUT` rend 200 sans écrire (mesuré au P0 sur `apiTags`) ; seule la relecture distingue « écrit » de « accepté puis ignoré ». C'est là aussi qu'on vérifie que le contenu n'a pas bougé.
2. **la SÉLECTION** — `GET /apis/{id}/globalPolicies`, c'est-à-dire ce que la gateway fait de cette liste. Une liste juste dans un objet inerte est le vert vacant le plus coûteux de ce GOAL, et il est atteignable : il suffit qu'une policy perde sa condition `HTTP_METHOD`. Le rôle refuse d'ailleurs d'écrire dans un tel objet (`POLICY_COMMUNE_INERTE`), et la mutation D6 le vérifie **sur la gateway**, pas dans un fichier.

L'appartenance est écrite **avant l'activation** de l'API — même règle que le tag de P3 : ce qui ne peut pas être confirmé n'est pas mis en service. Cette position n'est tenable que parce que la sonde répond sur une API **inactive** (S7 Q2), et c'est mesuré, pas supposé.

## Conséquences

- **Une cellule sans objet bloque la publication** (`POLICY_COMMUNE_ABSENTE`). Le play d'amorçage devient un préalable d'environnement, comme la PR de gouvernance l'est devenue en P2.
- **Le quota devient visible du demandeur**, dans le journal du build, avec la cellule qui le décide. C'est voulu : un refus 429 dont personne ne sait d'où il vient est un incident, pas un contrôle.
- **Concurrence assumée et fail-closed.** Deux publications simultanées dans la même cellule font un lire-modifier-réécrire de la même liste ; la perdante voit sa relecture échouer et son build rougir, avec le message qui dit de rejouer. Refus bruyant plutôt que perte silencieuse.
- **Le `PUT` d'un scope suffit à changer la posture d'une cellule entière.** Le pipeline en a le droit (l'allow-list l'expose déjà pour les policies d'API) ; ce qu'il n'a pas, c'est le droit d'en changer le CONTENU sans que la relecture le voie.
- **⚠ Limite assumée, constatée en fin de jalon : la liste des membres n'est pas ramassée.** Supprimer une API ne retire pas son nom du scope de sa cellule — les harnais P3 et P4 y ont laissé des noms d'APIs qui n'existent plus. C'est **inoffensif au plan de la sécurité** (un nom sans API ne sélectionne rien, exactement comme la sentinelle) mais c'est une **dérive d'inventaire** : au bout de quelques mois, la liste d'une cellule ne dit plus qui elle protège. Le retrait au moment de la suppression appartiendrait à un chemin « dépublier » que ce PoC n'a pas ; un ramasse-miettes du play d'amorçage (retirer les noms qu'aucune API ne porte) serait l'autre réponse — et il faudrait alors le faire **sans jamais vider la liste**, sentinelle comprise. Non fait, non caché.
- **Deux lectures manquent à l'allow-list du proxy d'administration** pour que ce jalon fonctionne à travers lui : `GET /rest/apigateway/policies` (résoudre la cellule par son nom) et `GET /rest/apigateway/apis/{id}/globalPolicies` (la relecture de sélection). **Aucune écriture nouvelle** — et sans la seconde, la porte du jalon serait un vert vacant. À porter dans le contrat du proxy avant tout déploiement client passant par lui.

## Ce que ce jalon a trouvé en chemin, et n'a pas corrigé

- **L'écart #1 d'ADR-091 est PRÉCISÉ, pas levé.** `threat-protection` a bien une surface sur wM 10.15 — le stage `threatProtection` et ses filtres (`jsonThreatProtectionFilter`, `MsgSizeLimitFilter`, `sqlInjectionFilter`, `ipdos`, `globalipdos`) existent dans le produit et les actions se créent. Mais `/policies` refuse de les porter, et `/administration/threatprotection` est **gateway-wide** : le contrôle existe, il n'est simplement pas déclinable par cellule. Une API `exposure=internet` reste donc structurellement rouge à la porte d'apply. **Question client :** `threat-protection` désigne-t-il chez vous un réglage gateway-wide (auquel cas il sort du bouquet et devient une exigence d'environnement) ou un WAF en amont (auquel cas il sort de cette chaîne) ?
- **`approvers.yml` reste cassé sur le produit réel** (décision client n°2, trouvée en P3). Le harnais P4 la contourne comme celui de P3, explicitement.

## Épreuves

```bash
cd labctl && go test ./... && go vet ./...      # 557 ✅ / 0 ❌
bash scripts/test-p4-global-policy.sh           # 38 ✅ / 0 ❌ (A→D)
python3 scripts/spike-p4-global-policy.py all   # 35 ✅ / 0 ❌, 7 verdicts
ansible-playbook -i ansible/inventory.lab.ini ansible/apim-global-posture-setup.yml
```

La porte du jalon est la section C : deux APIs de niveaux différents, la **même rafale de 35 appels**, et deux résultats — 429 sur la cellule `vh-internet` (quota 30/min), 200 partout sur `m-internet` (quota 120/min). Deux bouquets communs différents, mesurés côté plan de données. La contre-épreuve désactive la cellule et l'appel repasse.

## Ce que ce jalon ne fait pas

- Il ne pose **aucun** listener HTTPS et ne touche pas au protocole d'entrée par API : c'est P5, qui possède l'axe.
- Il ne réveille pas le deny-by-default du port : sa prémisse est tombée au P0.
- Il n'élargit **aucune écriture** de l'allow-list du proxy d'administration — il nomme deux lectures qui lui manquent.
- Il ne prétend rien sur ce que font Apigee, Kong, WSO2 ou AWS : la recherche du GOAL n'a jamais pu les couvrir.
