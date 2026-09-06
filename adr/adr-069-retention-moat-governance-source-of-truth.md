---
title: "ADR-069 — Douve de rétention : la gouvernance comme source de vérité vendor-neutral (survit à SAP+Joule ET à un pull GitOps)"
sidebar_label: "ADR-069 : Douve de rétention"
status: "Proposé — en attente Council 8/10 (GO/NO-GO)"
date: 2026-06-09
adr_number: 69
visibility: private
note: "Privé (stoa-labs). Répond à la condition Council C2-067. Ne pas porter dans stoa-docs (public)."
---

# ADR-069 — Douve de rétention de STOA

**Statut :** Proposé — en attente validation Council 8/10.
**Date :** 2026-06-09.
**Contexte client (anonymisé) :** banque centrale (Eurosystème).
**Lié à :** [[adr-067-reuse-first-owned-portable-layer]], [[adr-068-stoa-off-the-transaction-path]]. **Répond à** la condition Council **C2-067**.

> ⚠️ Privé. Positionnement + engagement client.

---

## Décision (test « archi 40 ans / 30 secondes »)

> La douve durable de STOA n'est **ni de faire tourner quelque chose** (un **pull GitOps** le remplace — cf. ADR-068), **ni de fédérer des runtimes** (douve d'*acquisition*, érodée par la convergence SAP). C'est de devenir la **source de vérité de gouvernance inter-runtime** de la banque : le **graphe accumulé et autoritatif** — catalogue + contrats + identité fédérée + RBAC/policy + audit + souscriptions — **vendor-neutral** (au-dessus de SAP *et* du reste), couplé à une **fabric de contrats/connecteurs maintenue et *garantie* (produit, pas TMA)**.
> **Test de qualification d'une douve** : *survit-elle à un SAP+Joule compétent ET à un pull GitOps ?* + *est-ce une **source de vérité** (pas un miroir) et est-ce **productisé** (pas du service) ?* — si non aux quatre, ce n'est pas une douve.

---

## Contexte et problème

Le Council (C2-067, lentilles gekk0 / sceptique-produit / souveraineté) a posé l'objection structurelle : **le moat de STOA est un moat de *service* (maintenance, support, conformité), pas de *produit*** — donc recopiable par une ESN ou absorbable par SAP/IBM, sans le capital de confiance d'un inconnu. Aggravé par deux constats récents :

- **ADR-068** : STOA est **hors du data-plane** → il sort de là où sont l'argent et le lock-in transactionnel.
- **Modèle CLI-en-CI / GitOps pull** (décidé) : l'empreinte runtime de STOA peut se réduire à **une étape de CI**. Or *« faire tourner un agent »* n'est alors plus une douve — un pull GitOps suffit.

Donc : **si STOA ne traverse pas les transactions ET n'a pas besoin d'un runtime à demeure, où est la rétention ?** Cet ADR la nomme — ou acte qu'elle n'existe pas encore.

## Acquisition ≠ Rétention (à ne pas confondre)

| | Douve d'**acquisition** (pourquoi ils achètent) | Douve de **rétention** (pourquoi ils ne partent pas) |
|---|---|---|
| Exemples | Fédération multi-runtime, Define Once, souveraineté, wedge portail hors-zone | *cet ADR* |
| Faiblesse | Érodée par SAP-convergence + recopiable | Doit survivre à SAP+Joule **et** à un pull GitOps |

La fédération est un **argument de vente**, pas une douve de rétention : un produit dont la promesse est « vous pouvez partir quand vous voulez » (vendor-neutral) **capture mal**. La rétention doit venir d'**autre chose**.

## Décision retenue — les artefacts de rétention (et leurs conditions de réalité)

### Douve #1 — Le graphe de gouvernance comme **source de vérité organisationnelle** (douve de données / coût de sortie)
Le **record accumulé et autoritatif** : catalogue d'APIs cross-vendor + historique des contrats + mappings d'identité fédérée (multi-IdP) + décisions RBAC/policy + piste d'audit + graphe des souscriptions/consumers.
- **Survit à SAP+Joule ?** Oui — SAP gouverne **SAP** ; ce graphe gouverne **SAP *et* le reste** (legacy, OSS, cloud, partenaires). Un éditeur de runtime ne fera structurellement pas une bonne couche *multi-vendor* (ça aiderait à rester multi-vendor).
- **Survit à un pull GitOps ?** Oui — un pull **applique** un état désiré ; il **n'accumule pas** des années de vérité organisationnelle + historique. Le coût de sortie = **re-dériver** cette vérité ailleurs (comme on ne quitte pas un CMDB/IAM à la légère).
- **Condition de réalité (sinon fausse douve)** : STOA doit être **autoritatif** — les décisions (policy, RBAC, identité, approbations) **naissent dans STOA et se propagent** aux runtimes. Si STOA n'est qu'un **miroir** lecture-seule de SAP/des consoles, **aucune rétention**.

### Douve #2 — La **fabric de contrats/connecteurs maintenue et garantie** (productisée, pas TMA)
Le catalogue de **Links versionnés, testés en CI contre N versions d'admin API de gateway, avec garantie de non-régression**, + la **validation de contrat + détection de drift**.
- **Survit à un pull GitOps ?** Oui — le pull **applique**, il ne **maintient pas** les adapters contre des APIs qui bougent. La maintenance garantie est un livrable continu.
- **Condition de réalité** : ce doit être un **produit** (versions testées + SLA de non-régression = « on achète une garantie ») et **non une prestation** (un homme-jour de TMA qu'une ESN facture moins cher). C'est la distinction exacte exigée par gekk0.

### Douve #3 — La **gouvernance cross-vendor des agents / MCP** (douve avancée, spéculative)
Gouverner **comment les agents/IA consomment les APIs** (`safe_for_agents`, `requires_human_approval`, métadonnées LLM du contrat) **à travers les runtimes**.
- **Survit à Joule ?** Oui **si** Joule reste SAP-centré : gouverner Joule **+** d'autres agents **+** des APIs non-SAP est un espace que SAP-Joule ne possède pas par construction.
- **Condition de réalité** : marché naissant — c'est un **pari**, pas une douve acquise. À traiter dans son propre ADR (gouvernance agent/MCP).

## STOA must-prove (dérivé)

- **Autorité, pas miroir** : démontrer que policy/RBAC/identité **naissent dans STOA** et se propagent (sinon Douve #1 = 0).
- **Garantie, pas homme-jour** : un Link livré avec **CI de contrat + SLA de non-régression** versionné (sinon Douve #2 = TMA).

## Conséquences

**Positives**
- Déplace le moat de « faire tourner » (recopiable) vers **données autoritatives + garantie productisée** (coût de sortie + non-recopiable trivialement).
- Cohérent ADR-068 (hors data-plane) et CLI-en-CI : la valeur n'est **pas** le runtime, c'est la **source de vérité + la garantie**.
- Donne au Council des artefacts **nommés** et **testables** (test « survit à SAP+Joule ET GitOps »).

**Négatives / risques (assumés — franchise exigée)**
- **Borné par la fenêtre multi-runtime** (angle mort Council #4, non chiffré) : Douve #1 et #3 valent **tant que dure l'hétérogénéité**. Convergence pure-SAP → la douve se **réduit** à l'historique de gouvernance accumulé + le pont SAP. **À chiffrer** (combien de mois/années d'hétérogénéité ?) — c'est la variable la plus déterminante.
- **C'est un pari d'adoption** : « source de vérité autoritative » n'existe que si la banque **fait** de STOA l'autorité. Un inconnu obtient rarement ce statut tôt → cohérent avec le wedge **hors-zone d'abord** (ADR-068, C4-068) : on devient autoritatif sur la gouvernance **avant** toute empreinte sensible.
- **Le multi-clients reste un pari** (Council blind spot #2) : la douve « produit » ne s'amortit qu'avec un 2ᵉ logo, toujours non nommé.
- Douve #2 exige un **vrai investissement produit** (CI de contrat, matrice de versions, SLA) — sinon elle retombe en TMA.

## Decision gate (rétention)

> Pour tout investissement qu'on prétend « douve » : **« Survit-il à un SAP+Joule compétent ET à un pull GitOps ? Est-ce une source de vérité (pas un miroir) ? Est-ce productisé (pas du service) ? »** — **4 oui** = douve de rétention. Sinon = argument d'acquisition ou prestation.

## Non couvert / différé (à tracer ailleurs)

- **Chiffrage de la fenêtre multi-runtime** (la variable critique) → analyse dédiée.
- **TCO BUILD/RUN 5 ans** (Council C1-067) → Notion / template BdF.
- **Validation marché** (le deal existe-t-il + est-il réplicable, blind spot Council #2) → business.
- **ADR gouvernance agent/MCP** (Douve #3 détaillée).

## Références

- [[adr-067-reuse-first-owned-portable-layer]], [[adr-068-stoa-off-the-transaction-path]].
- Council `wsphvf287` — condition C2-067 (« nommer la douve de rétention »), lentilles gekk0 / sceptique-produit / souveraineté, angles morts #2 #3 #4.
- PoC `stoa-labs` — [`../poc-control-plane-federation/POSITIONING.md`](../poc-control-plane-federation/POSITIONING.md).

## Definition of Done de cet ADR

- Validé Council **8/10**.
- Les 3 douves sont **nommées, testées** (survit-SAP+Joule / survit-GitOps / source-de-vérité / productisé) et leurs **conditions de réalité** explicites.
- Le must-prove « autorité, pas miroir » + « garantie, pas homme-jour » est applicable au prochain jet.
