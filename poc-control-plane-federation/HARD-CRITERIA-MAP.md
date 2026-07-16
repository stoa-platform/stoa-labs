# Mapping — Ce que ce jet prouve vs critères durs de l'étude

> **Condition C2 du Council.** Le PoC prouve le **control plane de fédération** ; il ne couvre PAS tous les critères que l'étude classe *éliminatoires/élevés*. Ce document évite que le comité prenne le PoC pour la réponse complète. **Reverse Invoke = prochain must-prove nommé.**
>
> Anonymisation : « institution financière régulée (anonymisé) » / « BC ».
>
> **Màj 2026-07-03** : réconcilié avec [`EVIDENCE.md`](./EVIDENCE.md) — l'**analytique par fournisseur** (OpenSearch, ADR-070) passe de « ❌ NON » à « 🟡 PARTIEL » (tranche APISIX prouvée bout-en-bout ; tranches wM/WSO2 différées). Voir §1 (ligne 8), §2 et §4.

---

## 1. Ce que CE jet PROUVE (périmètre PoC fédération)

| # | Preuve | Réf. étude | Statut |
|---|---|---|---|
| 1 | Fédération multi-runtime (3 gw hétérogènes, 1 control plane) | §4.8, §7 (le trou) | ✅ couvert |
| 2 | UAC / Define Once, Expose Everywhere (1 OpenAPI → 3 gw) | §7 | ✅ couvert |
| 3 | Catalogue unifié (`labctl get apis`, 3 gw ; Backstage différé) | — | ✅ couvert |
| 4 | Self-service souscription (request→approve→creds) | — | ✅ couvert |
| 5 | Identité Oracle-master (Dex→Keycloak broker→3 gw) | §4.x identité | ✅ couvert (live) |
| 6 | Observabilité unifiée OTel (APISIX + webMethods + WSO2 → Tempo — goal A2, 2026-07-03) | §0.5 | ✅ 3/3 runtimes |
| 7 | Souveraineté (100 % local/self-hosted, 0 SaaS) | vs Axway Amplify | ✅ couvert |
| 8 | Analytique transactionnelle par fournisseur — OpenSearch (data stream + RBAC/FLS par tenant + redaction à un point unique + pivot `trace_id`) | §4.11, §0.6 | 🟡 tranche APISIX (wM/WSO2 différées) |

---

## 2. Ce que les CRITÈRES DURS exigent ENCORE (hors ce jet)

| Critère | Réf. étude | Sévérité | Couvert ? | Prochaine action |
|---|---|---|---|---|
| **Reverse Invoke / zéro entrant en zone de confiance** (DATA-PLANE) | §0.2, §4.2 | **🔴 ÉLIMINATOIRE** | n/a pour STOA | **Critère GATEWAY, pas un livrable STOA.** RI = pattern DMZ data-plane (le trafic externe atteint les APIs internes sans port entrant — cf. Reverse Gateway webMethods). C'est **transactionnel** → porté par la gateway qualifiée. À **vérifier produit par produit** (webMethods ✓ ; WSO2/APISIX/SAP à confirmer). Cf. [`../adr/adr-068-stoa-off-the-transaction-path.md`](../adr/adr-068-stoa-off-the-transaction-path.md). |
| **Orchestration zéro-entrant (must-prove STOA)** | dérivé §0.2 | 🔴 Élevé | ❌ NON | Le vrai must-prove de STOA : fédérer/configurer des gateways en topologie reverse-invoke/DMZ **sans réintroduire** d'entrant, et **canal de management STOA lui-même zéro-entrant** (agent sortant-only **ou** pull GitOps). STOA reste **hors du chemin transactionnel**. |
| **Analytique transactionnelle par fournisseur (OpenSearch)** | §4.11, §0.6 | 🟠 Élevé | 🟡 PARTIEL | **Prouvé bout-en-bout sur la tranche APISIX** (ADR-070 : data stream `txn-accounts-team` + RBAC/FLS par tenant + redaction à un point unique + pivot `trace_id` Tempo↔OpenSearch — cf. [`EVIDENCE.md`](./EVIDENCE.md) Preuve 6 bis). Restent **différées** : tranches wM (Log Invocation→Kafka) et WSO2 (Fluent Bit sidecar). |
| **Streaming gros fichiers > 500 Mo** | §0.4 | 🟠 Élevé | ❌ NON (OUT du MEGA) | URL pré-signées / passthrough — explicitement hors scope premier jet. À chiffrer séparément. |
| ESB / bus / BPM | MEGA OUT | — | ❌ NON (assumé) | Ajoutables ensuite (Camel, Artemis/Kafka) — hors scope. |

---

## 3. Reverse Invoke — clarification (à ne PAS sur-vendre)

> Correction d'une confusion initiale. Il y a **deux** « reverse invoke » distincts ; ne pas les mélanger devant le comité. Cf. [`../adr/adr-068-stoa-off-the-transaction-path.md`](../adr/adr-068-stoa-off-the-transaction-path.md).

- **Reverse Invoke transactionnel (celui de l'étude, éliminatoire)** = pattern **data-plane / DMZ** : le trafic externe atteint les APIs internes **sans port entrant** vers la zone (Reverse Gateway webMethods). **Il voit les transactions** → c'est une **capacité de la gateway qualifiée**, **pas de STOA**. STOA ne peut pas le « prouver » sans revendiquer une fonction data-plane qu'il **ne doit pas** avoir (un éditeur inconnu n'entre pas dans le transactionnel d'une BC).
- **Ce que STOA prouve à la place** : (a) **orchestrer** des gateways en topologie reverse-invoke/DMZ **sans réintroduire** d'entrant ; (b) **son propre canal de management en zéro-entrant** (agent de *config* sortant-only — sync/discovery/policy/creds rotatifs, jamais un proxy — **ou** un pull GitOps). STOA reste **hors du chemin des transactions**.
- **L'agent sortant-only « à côté de la gateway »** est un bon deal *control-plane* (valeur opérationnelle réelle sans toucher les flux), à condition d'être minimal/signé/auditable et **remplaçable par un pull GitOps** (pas de dépendance runtime dure en zone).

> **Message au comité (corrigé)** : « Le Reverse Invoke de votre data-plane reste l'affaire de vos gateways qualifiées. STOA n'y touche pas : il orchestre **à côté**, en sortant-only, sans jamais voir vos transactions. »

---

## 4. Tableau de synthèse (1 slide)

```
PROUVÉ (ce jet)                    │  À PROUVER côté STOA        │  HORS PÉRIMÈTRE STOA / chiffré
───────────────────────────────────┼────────────────────────────┼──────────────────────────────
Fédération 3 runtimes              │  Orchestration zéro-entrant │  🔴 Reverse Invoke data-plane
Define Once → 3 gw                 │  + management zéro-entrant  │     = capacité GATEWAY (webM ✓,
Catalogue + self-service           │                            │     WSO2/APISIX/SAP à vérifier)
Identité Oracle-master             │                            │  Streaming >500 Mo · ESB/bus/BPM
obs OTel (APISIX+webMethods)       │                            │
Analytique/fournisseur 🟡 APISIX   │                            │
Souveraineté (0 SaaS)              │                            │
```

_Ne jamais présenter la colonne 1 sans montrer les colonnes 2-3 : la crédibilité vient de l'honnêteté sur ce qui reste à prouver — et sur ce qui **n'est pas** à STOA de prouver (le Reverse Invoke transactionnel = gateway, pas STOA)._
