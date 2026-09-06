---
title: "ADR-091 — La taxonomie d'exposition : trois valeurs ENTRANTES, une table de vérité nommée, et un seul endroit qui dit le vocabulaire. L'exposition n'est pas une échelle, l'appelant public n'est pas énumérable, et une case sans nom est un refus."
sidebar_label: "ADR-091 : la taxonomie d'exposition (P1)"
status: "Acté et prouvé le 2026-09-04 — hors ligne `go test ./...` **524 ✅ / 0 ❌** sur labctl (dont render 33, enforce 18, govsource 9, governance 30, adapter/webmethods 100), `go vet` propre, et **5 mutations sur 5 rouges** (plancher retiré, ip-allowlist réintroduite en internet, Weaker rendu à l'échelle, verifyHTTPSOnly rendu menteur, schéma UAC désynchronisé)."
maturite_technique: "✅ Moteur de dérivation étendu et unifié : le vocabulaire a UNE autorité (internal/render), les trois recopies (governance.ValidateUAC, govsource, et l'aide CLI) sont supprimées, le miroir JSON qui ne peut pas importer Go est épinglé par une épreuve de dérive. ⛔ Écart #1 ASSUMÉ ET NOMMÉ : `threat-protection` n'a aucune surface mesurée sur wM 10.15 ni ouverte dans l'allow-list ADR-075 ⇒ verdict `unverifiable` au read-back ⇒ **toute API `exposure=internet` est structurellement rouge à la porte d'apply**, par honnêteté et non par oubli. Rien n'est encore porté côté rôle Ansible (P2/P3/P5) : ce sont des spécifications vérifiées, pas un livrable de chaîne."
date: 2026-09-04
adr_number: 91
note: "Ouvre le GOAL posture-par-exposition (P1) après P0. CORRIGE une erreur du GOAL lui-même : `external` n'a jamais décrit une exposition SORTANTE — le schéma UAC (`uac_contract_v1_schema.json`, champ exposure) et l'ADR-076 §108 le définissent tous deux comme entrant (il choisit l'ancre de confiance de l'APPELANT). Les trois valeurs s'alignent donc sur un axe unique qui recouvre l'inventaire OWASP API9:2023 (internal / partners / public) — SANS que le vocabulaire français puisse être présenté comme un vocabulaire OWASP (réserve portée par P0). Ferme au passage la question ouverte n°5 de l'ADR-076 (« internal/external = mot du client, confirmer le sens métier »)."
lié: "[[adr-076-gitops-api-lifecycle-repo-per-project]], [[adr-078-livrable-self-service-app-wm1015]], [[adr-079-deploiement-promotion-multienv-import-archive]], [[adr-075-wm-admin-proxy-multienv]]"
---

# ADR-091 — La taxonomie d'exposition : trois valeurs entrantes, une table de vérité nommée, une seule autorité (P1)

**Statut :** Acté et prouvé hors ligne le 2026-09-04. `go test ./...` **524 ✅ / 0 ❌**, `go vet` propre, **5/5 mutations rouges**. Aucune mesure live n'était requise : P1 est le jalon de la *dérivation*, et les faits produits dont il dépend ont été mesurés sur l'instance réelle par P0 (`HANDOFF-2026-09-04-P0-QUATRE-SPIKES-DE-POSTURE.md`).

## Contexte

Le GOAL (2026-09-04) ouvre P1 sur une question client déclarée bloquante : *« que signifie `internet` ? »*, avec cette prémisse — *« l'énoncé décrit un flux entrant, là où `external` décrit une exposition sortante ; les deux taxonomies ne se superposent pas »*.

**La prémisse est fausse, et nos propres artefacts la réfutent deux fois.** Le schéma UAC dit du champ `exposure` : *« Selects the trust anchor / IdP (internal vs partner) and whether an IP allowlist is mandatory »*. L'ADR-076 §108 dit : *« `external` ⇒ IdP partenaire (Keycloak EXTERNAL) + IP allowlist ; `internal` ⇒ IdP interne »*. Une ancre de confiance est celle de **l'appelant**. `external` a toujours été entrant, et il a toujours voulu dire **partenaire**.

Les trois valeurs se rangent alors sur **un seul axe**, celui que l'OWASP API9:2023 demande d'inventorier — *« who should have network access »*, public / internal / partners. Ce qui restait vraiment à trancher n'était pas le sens des mots mais **ce que `internet` impose que `external` n'impose pas**. Trois décisions client ont été prises le 2026-09-04.

## Décision

### 1. Trois valeurs, toutes ENTRANTES, sur l'axe « qui peut appeler »

| valeur | appelant | ancre de confiance | ses IP sources sont… |
|---|---|---|---|
| `internal` | dans le SI | IdP interne (wM LOCAL / realm interne) | sans objet |
| `external` | **partenaire identifié** | IdP partenaire | **énumérables** ⇒ ip-allowlist obligatoire |
| `internet` | **le public** | IdP public | **non énumérables** ⇒ ip-allowlist **interdite** |

Le vocabulaire français **n'est pas** le vocabulaire OWASP ; il le recouvre. On ne présente jamais l'un pour l'autre dans un livrable client (réserve de P0, tenue).

### 2. `internet` REMPLACE l'ip-allowlist, il ne l'ajoute pas

C'est la décision qui porte tout le reste. Une liste d'IP en face d'un appelant public est soit impossible, soit un `0.0.0.0/0` qui **satisfait la porte en ne protégeant rien**. P0 vient de mesurer exactement ce piège sur le deny-by-default d'un port — *« le pire résultat possible pour un contrôle de sécurité »*. On ne le reproduit pas un jalon plus loin. `internet` porte donc `threat-protection` (anti-abus) **à la place** de l'ip-allowlist.

**Conséquence directe : l'exposition n'est pas une échelle.** Entre `external` et `internet`, **les deux sens** perdent un contrôle obligatoire. Aucun rang ne peut exprimer cela (§7).

### 3. `https-only` est un PLANCHER, à toutes les cases

Le protocole d'entrée accepté est épinglé **par API** sur l'étage `transport` (`entryProtocolPolicy`), le levier que le spike C a mesuré vivant. Il ne coûte **aucun redémarrage** et ne croise donc pas la contrainte de zéro-coupure d'ADR-079. Ajouter un **listener** HTTPS est un geste tout autre, d'environnement, et qui **ne décide rien pour l'API** — le spike C l'a mesuré dans les deux sens : une API servie sur un listener HTTPS neuf reste refusée par son propre `entryProtocolPolicy=http`.

Coût assumé (décision client) : toute API existante qui n'épingle pas `transportProtocol: https` devient **rouge au pré-check**, à tous les niveaux — et non plus seulement dans la branche `mtls` où la vérification vivait cachée avant P1.

### 4. `VH × internet` est GOUVERNÉE, pas interdite

Un certificat client **est** distribuable à un appelant public, quand son IP ne l'est pas : c'est le modèle eIDAS/QWAC de la DSP2. La case existe, elle porte `oauth2+mtls`. Seule l'ip-allowlist devient intenable à cette exposition, jamais le certificat.

### 5. La table de vérité est NOMMÉE, et une case sans nom est un refus

```
            internal        external          internet
  VH     vh-internal      vh-external      vh-internet
   H      h-internal       h-external       h-internet
   M      m-internal       m-external       m-internet
```

…plus la seule case d'exception gouvernée, `m-internal-apikey`. Le nom de la case remonte jusqu'à la sortie de `labctl render`, jusqu'à `EnforcementRequirement.Bundle` et jusqu'au journal du build.

Une paire absente de cette table est **refusée** — pas dérivée par une règle générale, pas ramenée à un défaut. Étendre un vocabulaire redevient donc une décision **case par case**, prise ici, et non une généralisation implicite qui inventerait une posture que personne n'a arbitrée. La garde est prouvée **par mutation** (une case retirée à chaud, le refus doit tomber), sans quoi ce serait une branche qu'aucune entrée n'atteint — c'est-à-dire un vert vacant.

### 6. `render` est la SEULE autorité du vocabulaire

Avant P1, l'énumération `internal/external` était recopiée à la main **quatre fois** : `render.go`, `governance.ValidateUAC`, `govsource` (le registre central), et le schéma UAC. Une valeur ajoutée à l'une et oubliée à l'autre passait sans bruit. Les trois sites Go demandent désormais le vocabulaire à `render` (`ValidExposure`, `ValidClassification`, `Exposures()`, `Classifications()`). Le schéma JSON ne peut pas importer du Go : il garde une copie, et **une épreuve de dérive l'épingle** contre l'autorité — fail-closed, un schéma illisible échoue, il ne saute pas.

C'est le sens du titre du jalon : *une seule autorité*.

### 7. `Weaker()` devient de la CONTENANCE de bouquet, parce que l'exposition n'est pas une échelle

La garde anti-usurpation (goal A5, registre central) gardait deux axes avec un rang. Elle en garde désormais deux **de natures différentes** :

- **l'intégrité EST une échelle** : un rang inférieur est un affaiblissement, **même quand les deux niveaux dérivent le même bouquet** (M et H donnent tous deux `oauth2` aujourd'hui — déclarer M contre un H gouverné reste une tentative). Le rang survit donc, seul, pour cet axe ;
- **l'exposition n'en est pas une** : la comparaison est la **contenance** du bouquet dérivé. Le déclaré est plus faible dès qu'il ne contient pas toute policy du gouverné. Cela attrape les deux sens (`internet` déclaré contre `external` gouverné perd l'ip-allowlist ; `external` déclaré contre `internet` gouverné perd `threat-protection`), là où aucun rang ne le pouvait.

Fail-closed : un côté qui ne dérive pas est « plus faible ». La contenance est calculée **sans les tags** des deux côtés — le registre central ne porte que (classification, exposition) —, donc l'exception apikey reste hors de cette comparaison, exactement comme avant P1.

### 8. Écart #1, assumé et bruyant : `threat-protection` n'est pas vérifiable

wM 10.15 **a** une Threat Protection, mais elle est **serveur-large**, sa surface n'a **jamais été mesurée par ce projet**, et l'allow-list du proxy d'administration (ADR-075) ne l'ouvre pas. Il n'existe donc **aucun levier par-API** à pré-vérifier.

- **au pré-check** : un **avertissement** nommé — bloquer là interdirait la valeur d'exposition tout entière ;
- **au read-back** : `unverifiable`, **ce que la porte REFUSE**.

Donc : **une API `exposure=internet` est structurellement rouge à la porte d'apply**, jusqu'à ce que ce leg soit mesuré. C'est l'état honnête. Attester en silence un contrôle que personne n'a observé serait, une fois de plus, la garantie de papier.

## Ce que P1 ne fait pas

- Il ne touche **pas** au formulaire du producteur : collecter l'exposition est P2, et c'est là que le **registre central gagne contre le manifeste**.
- Il ne pose **aucun tag** sur l'API : c'est P3, et P0 a déjà corrigé le champ (`apiDefinition.tags`, jamais `apiTags` qui est mort).
- Il ne porte **rien** côté rôle Ansible. `labctl` reste parqué : ce qui est écrit ici est une **spécification vérifiée**, comme `transport.go` et `render.go` l'étaient déjà.
- Il ne mesure **rien de neuf** sur l'instance : les faits produits dont il dépend viennent de P0, sur la 10.15 réelle.

## Limites

- **`threat-protection` est un nom, pas encore un contrôle** (écart #1). Tant que son leg n'est pas mesuré, `internet` est dérivable, validable et refusé à l'apply.
- **Le vocabulaire reste déclaratif au niveau de la gateway.** P0 l'a établi : aucun champ d'API en 10.15 n'est protégé en écriture. L'autorité est le registre central ; P2 est la contrepartie obligatoire de cette conception, pas une amélioration ultérieure.
- **`https-only` sur APISIX et WSO2** tombe dans leur `default:` fail-closed, comme toute policy en A1 — ces moteurs étaient déjà structurellement rouges sous enforcement (goals A3/B1). Aucune régression, aucun progrès.
- **La décision client n°1 est tranchée, pas sourcée.** OWASP API9 prescrit d'*inventorier* l'axe d'exposition et rien de plus : il ne dit rien sur le fait d'en dériver des contrôles à l'exécution. Notre dérivation est une bonne pratique interne défendable, jamais une exigence sourcée — et elle ne doit pas être présentée autrement.

## Preuve

```
cd poc-control-plane-federation/labctl
go vet ./...
go test ./...                    # 524 ✅ / 0 ❌
go test ./internal/render/ -v    # la table de vérité complète, cellule par cellule
```

Épreuves qui portent la décision : `TestTruthTable` (les 10 cases nommées, **ensemble exact** de policies — une contenance laisserait passer une ip-allowlist en `internet`), `TestUngovernedCellIsRefused` (par **mutation** de la table), `TestWeakerExposureIsNotALadder`, `TestWeakerClassificationLadder`, `TestIPAllowlistIsExternalOnly`, `TestSchemaVocabularyDoesNotDrift`, `TestPrecheck_HTTPSOnlyIsAFloorAtEveryLevel`, `TestPrecheck_ThreatProtectionWarnsAndDefers`, `TestVerifyEnforcement_HTTPSOnlyCatchesPlaintextDrift`, `TestVerifyEnforcement_ThreatProtectionIsUnverifiable`.

Campagne de mutation (5/5 rouges, chacune sur une épreuve **nommée**) : plancher `https-only` retiré → `TestGate_UncoveredRequiredPolicyIsMissing` ; ip-allowlist réintroduite en `internet` → `TestPrecheck_InternetCarriesNoIPAllowlist` ; `Weaker` rendu à l'ancienne échelle → `TestWeakerExposureIsNotALadder` ; `verifyHTTPSOnly` rendu menteur → `TestVerifyEnforcement_HTTPSOnlyCatchesPlaintextDrift` ; schéma UAC désynchronisé → `TestSchemaVocabularyDoesNotDrift`.
