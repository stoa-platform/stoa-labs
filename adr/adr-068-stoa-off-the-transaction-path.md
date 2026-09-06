---
title: "ADR-068 — STOA hors du chemin transactionnel : control plane sortant-only ; Reverse Invoke transactionnel = capacité gateway"
sidebar_label: "ADR-068 : STOA hors data-plane"
status: "Proposé — en attente Council 8/10 (GO/NO-GO)"
date: 2026-06-09
adr_number: 68
visibility: private
note: "Hébergé dans stoa-labs (privé) — engagement client anonymisé + positionnement. Ne pas porter dans stoa-docs (public)."
---

# ADR-068 — STOA hors du chemin transactionnel

**Statut :** Proposé — en attente validation Council 8/10 (GO/NO-GO).
**Date :** 2026-06-09.
**Contexte client (anonymisé) :** banque centrale (Eurosystème).
**Lié à :** [[adr-067-reuse-first-owned-portable-layer]].

> ⚠️ **Confidentialité.** Positionnement + engagement client. Vit dans `stoa-labs` (privé), **pas** dans `stoa-docs` (public).

---

## Décision (test « archi 40 ans / 30 secondes »)

> **STOA ne traverse JAMAIS les transactions clients.** Le data-plane (les flux applicatifs) reste sur les **gateways qualifiées** (webMethods, WSO2, SAP). L'empreinte de STOA dans la zone de confiance se limite à un **agent de *contrôle* sortant-only** (sync de config, discovery, policy, **déclenchement de rotation de credentials *via un PAM/Vault qualifié* — STOA ne porte pas les secrets**, santé) — **jamais un proxy de transactions**, et idéalement **remplaçable par un pull GitOps**.
> Corollaire : le **Reverse Invoke transactionnel** (zéro-entrant data-plane, critère *éliminatoire* de l'étude) est une **capacité des gateways**, **pas un livrable STOA**.

---

## Contexte et problème

Stress-test honnête du récit « fédération » : **une banque centrale ne met pas un composant d'un éditeur inconnu, non qualifié, sans références chez des pairs, dans le chemin de ses transactions clients.** La qualification d'un composant transactionnel en BC se compte en années (due diligence éditeur, certifications, pentests, escrow de code, viabilité financière, références). Un éditeur en structure légère (solo + canal ESN) n'a pas ce capital de confiance pour du transactionnel — inutile de se raconter le contraire.

Deux notions ont été **confondues** et doivent être séparées :

| | « Reverse Invoke » de l'étude (§0.2, §4.2) | « agent sortant » de STOA |
|---|---|---|
| Plan | **Data-plane** (nord-sud, transactions) | **Control-plane** (config) |
| Pattern | DMZ / reverse connection : le trafic externe atteint les APIs internes **sans port entrant** vers la zone (cf. **Reverse Gateway webMethods**) | agent qui **compose vers le control plane** pour recevoir config/policies |
| Qui le porte | **La gateway** (capacité produit) | STOA (ou un pull GitOps) |
| Voit les transactions ? | **Oui** | **Non, jamais** |

Le Reverse Invoke éliminatoire est **transactionnel** → c'est l'affaire des gateways, **pas de STOA**.

## Forces en présence (decision drivers)

- Un inconnu non qualifié **ne passe pas** dans le transactionnel d'une BC.
- Le moat durable de STOA = la **couche de contrôle/gouvernance** (ADR-067, Bac A), **runtime-agnostique**, hors du chemin des données.
- Le zéro-entrant en zone de confiance s'applique à **deux** flux distincts : le **data-plane** (boulot de la gateway) ET le **canal de management** de STOA (boulot de STOA).
- Un agent de **config** sortant-only se qualifie comme un **runner GitOps / agent de monitoring** (barre acceptable) — pas comme un composant transactionnel (barre infranchissable pour un inconnu).

## Décision retenue

1. **STOA ne traverse jamais les transactions.** Data-plane = gateways qualifiées. STOA est à côté, pas dedans. (Le PoC l'illustre déjà : `labctl` configure les gateways ; les appels data-plane ne passent jamais par STOA.)
2. **Empreinte STOA en zone = agent control-plane sortant-only** : sync config, discovery, policy-as-code, **orchestration de rotation de secrets *déléguée à un PAM/Vault qualifié* (STOA ne stocke/n'injecte pas de secret en propre)**, heartbeat/santé. **Jamais un proxy.** Conçu pour être **remplaçable par un pull GitOps** → STOA n'est pas une dépendance runtime *dure* dans la zone. C'est « un bon deal » : valeur opérationnelle réelle (sync live, rotation orchestrée) **sans toucher les flux ni porter les secrets**.
3. **Reverse Invoke transactionnel = critère GATEWAY**, à vérifier **produit par produit** (webMethods ✓ ; WSO2 / APISIX / SAP Integration Suite à confirmer). **Pas un livrable STOA.**

**Decision gate** (tout nouvel élément qu'on envisage de mettre en zone de confiance) — **deux questions, pas une** (le simple « voit-il un flux ? » est insuffisant au sens DORA) :
1. **« Voit-il / peut-il modifier une transaction ? »** (data-plane) → **Oui** = ce n'est PAS STOA, c'est la gateway qualifiée.
2. **« Peut-il altérer la sécurité, l'intégrité ou la disponibilité d'une fonction importante ? »** (test DORA) → **Oui** = composant **sensible, in-scope DORA** même en control-plane (un agent qui pousse des policies ou déclenche des rotations de secrets l'est) → **traitement renforcé**, pas « barre basse » : signature/SBOM, **secrets délégués à un PAM/Vault déjà qualifié**, least-privilege, plan d'exit testé.

**Deux *non*** = candidat control-plane standard, sous conditions (ci-dessous).

**Conditions non négociables de l'agent control-plane** (si agent plutôt que pull) : sortant-only vers **un control plane auto-hébergé** (egress allow-listé, mTLS), **build signé + reproductible** (SBOM), image minimale non-root, least-privilege réseau, audit trail, **secrets délégués à un PAM/Vault qualifié (l'agent ne stocke ni n'injecte de secret en propre — un éditeur inconnu portant l'injection de secrets en zone BC = NO-GO par défaut)**, inventorié DORA ICT comme composant pouvant altérer une fonction importante.

## STOA « must-prove » (corrigé)

Ce que STOA doit réellement démontrer (et qui **remplace** l'ancien « prouver le Reverse Invoke ») :

- **Orchestrer/fédérer des gateways déployées en topologie reverse-invoke/DMZ** sans **réintroduire** de flux entrant vers la zone de confiance.
- **Canal de management STOA lui-même zéro-entrant** (agent sortant-only **ou** pull GitOps).

## Conséquences

**Positives**
- Élimine l'objection mortelle « inconnu dans le transactionnel ». Le pitch ne ment plus.
- Aligné ADR-067 : la valeur durable est la couche possédée **hors data-plane**, donc **non soumise** à la qualification pluriannuelle d'un composant transactionnel.
- Barre de confiance abaissée : agent de config (≈ runner GitOps), pas composant de flux.

**Négatives / risques (assumés)**
- La valeur en zone est « control-plane only » → l'agent doit apporter **assez** (sync live, creds rotatifs, discovery) pour se justifier **face à un simple pull GitOps**, sinon : pas d'agent.
- Le récit « fédération » ne doit **jamais** déraper vers « STOA voit les flux » — vigilance commerciale permanente.
- Même control-plane-only, un agent en zone reste scruté (signature, reproductibilité, egress) ; pour un éditeur inconnu, **la première vente passe probablement hors zone** (gouvernance/portail/catalogue) avant toute empreinte runtime.

## Non couvert / différé (à tracer ailleurs)

- **Wedge GTM** : entrer par la couche gouvernance/portail/catalogue **hors zone de confiance** (faible risque, forte visibilité, zéro transaction) ; références d'abord, empreinte runtime ensuite — ou via un intégrateur/éditeur déjà qualifié. → Notion (business).
- **Couche MCP/agent** (`stoa-gateway` mode edge-mcp) : c'est un **data-plane pour le trafic agent/MCP**, une surface distincte des transactions bancaires classiques — à traiter dans son propre ADR (mêmes contraintes de qualification si elle touche des flux sensibles).

## Références

- Étude alternatives API Management & intégration (interne, anonymisé) — §0.2, §4.2 (Reverse Invoke / zéro-entrant, éliminatoire).
- [[adr-067-reuse-first-owned-portable-layer]] — couche possédée portable / runtimes commodity.
- PoC `stoa-labs` — [`../poc-control-plane-federation/POSITIONING.md`](../poc-control-plane-federation/POSITIONING.md), [`../poc-control-plane-federation/HARD-CRITERIA-MAP.md`](../poc-control-plane-federation/HARD-CRITERIA-MAP.md) (corrigé en cohérence).

## Definition of Done de cet ADR

- Validé Council **8/10** (GO/NO-GO).
- La decision gate « voit-il une transaction ? » est applicable telle quelle à toute décision d'empreinte en zone de confiance.
- `HARD-CRITERIA-MAP.md` corrigé : Reverse Invoke reclassé en critère **gateway**, et le must-prove STOA reformulé (orchestrer zéro-entrant + management zéro-entrant).
