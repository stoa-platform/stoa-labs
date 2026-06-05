# Mapping — Ce que ce jet prouve vs critères durs de l'étude

> **Condition C2 du Council.** Le PoC prouve le **control plane de fédération** ; il ne couvre PAS tous les critères que l'étude classe *éliminatoires/élevés*. Ce document évite que le comité prenne le PoC pour la réponse complète. **Reverse Invoke = prochain must-prove nommé.**
>
> Anonymisation : « institution financière régulée (anonymisé) » / « BC ».

---

## 1. Ce que CE jet PROUVE (périmètre PoC fédération)

| # | Preuve | Réf. étude | Statut |
|---|---|---|---|
| 1 | Fédération multi-runtime (3 gw hétérogènes, 1 control plane) | §4.8, §7 (le trou) | ✅ couvert |
| 2 | UAC / Define Once, Expose Everywhere (1 OpenAPI → 3 gw) | §7 | ✅ couvert |
| 3 | Catalogue unifié (Backstage, 3 gw) | — | ✅ couvert |
| 4 | Self-service souscription (request→approve→creds) | — | ✅ couvert |
| 5 | Identité Oracle-master (Dex→Keycloak broker→3 gw) | §4.x identité | ✅ couvert |
| 6 | Observabilité unifiée OTel (`trace_id` 3 gw → Tempo/Loki/Prom) | §0.5 | ✅ couvert |
| 7 | Souveraineté (100 % local/self-hosted, 0 SaaS) | vs Axway Amplify | ✅ couvert |

---

## 2. Ce que les CRITÈRES DURS exigent ENCORE (hors ce jet)

| Critère | Réf. étude | Sévérité | Couvert ? | Prochaine action |
|---|---|---|---|---|
| **Reverse Invoke / zéro flux entrant en zone de confiance** | §0.2, §4.2 | **🔴 ÉLIMINATOIRE** | ❌ NON | **PROCHAIN MUST-PROVE** — un comité BC peut bloquer seul là-dessus. C'est de la **topologie de déploiement** (le data-plane initie sortant vers le control plane), pas de la fédération → jet dédié `poc-reverse-invoke`. |
| **Analytique transactionnelle par fournisseur (OpenSearch)** | §4.11, §0.6 | 🟠 Élevé | ❌ NON | Le PoC fait de l'obs technique (traces/métriques/logs), pas l'analytique métier par fournisseur. Add-on : pipeline OTel → OpenSearch + dashboards par provider. |
| **Streaming gros fichiers > 500 Mo** | §0.4 | 🟠 Élevé | ❌ NON (OUT du MEGA) | URL pré-signées / passthrough — explicitement hors scope premier jet. À chiffrer séparément. |
| ESB / bus / BPM | MEGA OUT | — | ❌ NON (assumé) | Ajoutables ensuite (Camel, Artemis/Kafka) — hors scope. |

---

## 3. Reverse Invoke — pourquoi c'est le prochain jet prioritaire

- **Sévérité** : l'étude le pose en **éliminatoire** (§0.2, §4.2). Un produit qui exige un flux entrant vers la zone de confiance de la BC est écarté d'office, quel que soit le reste.
- **Indépendant de la fédération** : RI est une question de **topologie réseau** (agent data-plane en zone sensible qui n'ouvre que du sortant vers le control plane), pas du « 1 contrat → N gw » prouvé ici. Les deux preuves se composent mais se démontrent séparément.
- **Atout STOA** : l'architecture STOA prévoit déjà l'agent `stoa-connect` (sortant-only, heartbeat + SSE) — c'est précisément le pattern Reverse Invoke. Le jet `poc-reverse-invoke` réutiliserait ce mécanisme produit (≠ scaffold OSS jetable).

> **Message au comité** : « Ce jet prouve la fédération. Le Reverse Invoke — votre critère éliminatoire — est le prochain à démontrer, et c'est un point fort natif de STOA (agent sortant-only), pas une rustine. »

---

## 4. Tableau de synthèse (1 slide)

```
PROUVÉ (ce jet)              │  À PROUVER (must-prove)        │  HORS SCOPE (chiffré à part)
────────────────────────────┼───────────────────────────────┼──────────────────────────────
Fédération 3 runtimes        │  🔴 Reverse Invoke (élimin.)   │  Streaming >500 Mo
Define Once → 3 gw           │  🟠 Analytique par fournisseur │  ESB / bus / BPM
Catalogue + self-service     │     (OpenSearch)               │
Identité Oracle-master       │                               │
trace_id 3 gw → Tempo        │                               │
Souveraineté (0 SaaS)        │                               │
```

_Ne jamais présenter la colonne 1 sans montrer les colonnes 2-3 : la crédibilité vient de l'honnêteté sur ce qui reste à prouver._
