---
title: "P1 — la taxonomie d'exposition : trois valeurs entrantes, une table de vérité nommée, une seule autorité"
type: handoff
jalon: P1
goal: GOAL-posture-par-exposition-2026-09-04.md
adr: adr/adr-091-taxonomie-exposition-table-de-verite.md
date: 2026-09-04
preuve: "labctl : go vet propre, go test ./... 524 ✅ / 0 ❌ (render 33, enforce 18, govsource 9, governance 30, adapter/webmethods 100) ; campagne de mutation 5/5 rouges"
status: "LIVRÉ. Les trois décisions client de la taxonomie sont tranchées. Une erreur du GOAL est corrigée. UN écart nommé reste ouvert et rend `exposure=internet` rouge à l'apply — délibérément."
---

# P1 — ce qui a été livré, et ce qu'il faut savoir avant P2

## La prise du jour : le GOAL se trompait sur son propre vocabulaire

Le GOAL ouvrait P1 sur *« `external` décrit une exposition sortante »*. Deux artefacts du dépôt disent l'inverse — `uac_contract_v1_schema.json` (*« Selects the trust anchor / IdP (internal vs partner) »*) et `adr-076:108` (*« `external` ⇒ IdP partenaire + IP allowlist »*). Une ancre de confiance est celle de **l'appelant**.

`external` a toujours été **entrant** et a toujours voulu dire **partenaire**. La décision client n°1 se dissolvait donc à moitié toute seule, et la moitié dure — *que impose `internet` que `external` n'impose pas ?* — a été posée au client avec sa table, puis tranchée.

**Réflexe à garder :** quand un GOAL énonce un fait sur nos propres objets, le vérifier dans le schéma et l'ADR avant de construire dessus. Ici, une heure de conception serait partie sur deux taxonomies qui ne se superposent pas — alors qu'il n'y en a qu'une.

## Les trois décisions client (2026-09-04)

1. **`internet` REMPLACE l'ip-allowlist** par `threat-protection`. Motif : un appelant public n'est pas énumérable ; une liste `0.0.0.0/0` satisferait la porte en ne protégeant rien — le piège exact que P0 venait de mesurer sur le deny-by-default d'un port.
2. **`VH × internet` est gouvernée, pas interdite.** Un certificat client est distribuable à un appelant public quand son IP ne l'est pas : modèle eIDAS/QWAC (DSP2).
3. **`https-only` est un plancher à toutes les cases**, `internal` compris. Levier `entryProtocolPolicy` **par API** (spike C), sans redémarrage, donc hors contrainte ADR-079.

## Ce qui a changé dans le code

| Fichier | Changement |
|---|---|
| `labctl/internal/render/render.go` | Table de vérité **nommée** (9 cases + `m-internal-apikey`), plancher `https-only`, axe d'exposition à 3 valeurs, `Result.Bundle`, `Weaker()` en **contenance de bouquet**, vocabulaire **exporté** (`ValidExposure`, `Exposures()`, …) |
| `labctl/internal/governance/validate.go` | Enum recopiée **supprimée** → délègue à `render` |
| `labctl/internal/govsource/registry.go` | Enum recopiée **supprimée** → délègue à `render` |
| `labctl/cmd/governance-api/uac_contract_v1_schema.json` | `internet` ajouté ; descriptions corrigées (exposition **entrante**) |
| `labctl/internal/enforce/enforce.go` | Pré-check `https-only` (tous niveaux) ; `threat-protection` en **avertissement** ; `Bundle` porté dans l'exigence |
| `labctl/internal/adapter/webmethods/enforce.go` | `verifyHTTPSOnly` (stage transport) ; `threat-protection` → `unverifiable` nommé |
| `labctl/internal/render/schema_drift_test.go` | **neuf** — épingle le miroir JSON contre l'autorité Go |

## L'écart à porter, et il est bruyant par choix

**`threat-protection` est un nom, pas encore un contrôle.** wM 10.15 a bien une Threat Protection, mais elle est **serveur-large**, sa surface n'a jamais été mesurée par ce projet, et l'allow-list ADR-075 ne l'ouvre pas.

⇒ **Toute API `exposure=internet` est structurellement ROUGE à la porte d'apply.** Ce n'est pas un oubli : attester en silence un contrôle que personne n'a observé serait la garantie de papier que P0 a démontée. Mais il faut le dire au client tel quel — `internet` est dérivable et validable, **pas déployable**, avant que ce leg existe.

**Question client qui en découle**, à poser avant P5 : *`threat-protection` désigne-t-il chez vous un dispositif de la gateway, ou un WAF en amont ?* Si c'est un WAF, l'écart se ferme par une **déclaration d'amont exigée dans le manifeste** (l'option n°3 de la question posée le 2026-09-04) plutôt que par un leg de vérification.

## Méthode : cinq mutations, cinq rouges nommés

Tout était vert au premier jet — ce qui, ici, ne prouve rien : `verifyHTTPSOnly` était à **0,0 % de couverture**, un vert parfaitement vacant. La couverture l'a montré, la mutation l'a réglé.

| sabotage | épreuve qui tombe |
|---|---|
| plancher `https-only` retiré | `TestGate_UncoveredRequiredPolicyIsMissing` |
| ip-allowlist réintroduite en `internet` | `TestPrecheck_InternetCarriesNoIPAllowlist` |
| `Weaker` rendu à l'ancienne échelle | `TestWeakerExposureIsNotALadder` |
| `verifyHTTPSOnly` rendu menteur | `TestVerifyEnforcement_HTTPSOnlyCatchesPlaintextDrift` |
| schéma UAC désynchronisé | `TestSchemaVocabularyDoesNotDrift` |

## Ce qui attend P2

- Le formulaire du producteur collecte **exposition + classification** (aujourd'hui : huit champs, aucun de posture).
- Le **registre central gagne contre le manifeste** — mécanisme déjà prouvé (`scripts/test-classification-central.sh`), et `Weaker()` est désormais correct sur les trois valeurs, donc la contre-épreuve « déclarer moins exposé » est mécaniquement détectable dans les deux sens.
- Le code de refus `CLASSIFICATION_SPOOFED` existe et est relayé ; rien de neuf à inventer côté codes.
- **Piège attendu** : le manifeste porte une exposition, mais la 10.15 ne protège **aucun** champ en écriture (P0). L'autorité doit rester hors gateway, la gateway n'en étant que le miroir.
