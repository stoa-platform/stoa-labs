# PoC — Control Plane de Fédération sur briques OSS (réponse étude BC anonymisé)

> **Phase 0 — AUDIT & PLAN.** Repo cible : **`stoa-labs`** (privé). Approche : **inspiré de STOA, assemblé sur briques OSS** — pas de redéploiement de la stack propriétaire STOA.
> **GATE : ce plan attend une validation Council 8/10 (GO/NO-GO) avant tout code.**
>
> Anonymisation : « institution financière régulée (anonymisé) » / « BC » uniquement. Données 100 % synthétiques, environnement éphémère, zéro SaaS.

---

## 0. TL;DR pour le Council

**Thèse.** L'étude conclut qu'aucun produit OSS/commercial ne livre un control plane unifié transverse (§4.8, §7), la seule fédération citée étant Axway Amplify (SaaS, hors zone). Ce PoC démontre qu'on peut **assembler ce control plane de fédération à partir de briques OSS souveraines**, en s'inspirant de l'architecture STOA, **sans moteur custom maison** (anti-§7.6) : la pièce « fédération » est un **orchestrateur mince** (~quelques centaines de lignes) au-dessus d'APIs d'admin standard ; tout le reste est OSS sur étagère.

**Décision de design (vs PoC précédent).** On NE réutilise PAS la stack custom STOA (control-plane-api Python, stoa-gateway Rust, portail React). On en **reprend les idées** (UAC → contrat unique ; adapter pattern ; dispatch « 1 contrat → N gateways » ; broker OIDC ; observabilité corrélée) et on les **réimplémente sur OSS**. Trade-off assumé : **plus de glue d'intégration, moins de réuse de l'existant STOA** (~28-30 h Claude time vs ~20 h pour la voie « tout-STOA »), mais **bien plus souverain, lisible et non lié au produit** — argument décisif pour un comité de institution financière régulée.

**Choix structurants validés :**
| Axe | Choix |
|---|---|
| Catalogue + portail + self-service | **Backstage** (CNCF, OSS) |
| « Define Once » | **OpenAPI 3.x pur** (zéro schéma maison) |
| Runtimes fédérés | **3 hétérogènes** : WSO2 APIM (réel OSS) · Apache APISIX (réel OSS) · webMethods (mock, legacy commercial) |

---

## 0.bis Verdict Council & conditions (GO conditionnel ~7→8+/10)

Plan jugé solide (anti-§7.6, OSS-first, DoD discipliné) ; **2 conditions de cadrage** à verrouiller (sans ré-architecturer ; Phase 1 lançable en parallèle) :

- **C1 — Narratif « scaffold vs produit » (anti-auto-balle-GTM).** Le « ~300 LOC » prouve que le *dispatch* est facile ; il ne doit JAMAIS laisser croire que STOA = 300 lignes de glue (sinon la banque le recopie sans nous payer). `EVIDENCE.md` + pitch doivent séparer explicitement le **scaffold jetable du PoC** (`labctl`, démonstrateur) de la **valeur produit STOA** (Links maintenus vs N intégrations fragiles contre des admin APIs mouvantes, validation/drift des contrats, fédération credentials/policies multi-runtime, RBAC, audit, couche MCP/agent, support+SLA) — avec une réponse en une phrase à « pourquoi acheter STOA plutôt que recopier ce PoC ». → **livrable `POSITIONING.md`**.
- **C2 — Mapping critères durs de l'étude.** Le PoC prouve le control plane mais reste muet sur des critères *éliminatoires/élevés* : **Reverse Invoke / zéro entrant en zone de confiance** (§0.2, §4.2 — *éliminatoire*, un comité BC peut bloquer seul), analytique transactionnelle par fournisseur via OpenSearch (§4.11, §0.6), streaming gros fichiers >500 Mo (§0.4). Ajouter une section « ce que ce jet prouve vs ce que les critères durs exigent encore », **RI nommé comme prochain must-prove**. → **livrable `HARD-CRITERIA-MAP.md`**.

**Pièce maîtresse EVIDENCE :** la corrélation **`trace_id` de bout en bout à travers les 3 gateways hétérogènes jusqu'à Tempo** — *le* moment qui rend la fédération tangible. À mettre en avant, pas une capture parmi d'autres.

---

## 1. Stack de briques OSS (composant → brique → rôle)

| Couche | Brique OSS | Image (tag à confirmer Phase 1) | Rôle dans le PoC |
|---|---|---|---|
| Gateway « neuf » souverain | **WSO2 API Manager** | `wso2/wso2am` | Gateway réel #1 ; Publisher REST = cible de publication |
| Gateway OSS additionnel | **Apache APISIX** + etcd | `apache/apisix`, `bitnami/etcd` | Gateway réel #2 ; Admin API + plugin `opentelemetry` natif |
| Gateway legacy | **Mock webMethods (Go)** | build local | Gateway #3 ; émule l'admin REST `/rest/apigateway/*` (commercial legacy) — swap → `apigateway:10.15` sans refactor |
| Control plane / fédération | **`labctl` (orchestrateur mince, Go)** | build local | La SEULE pièce semi-custom : `apply` 1 OpenAPI → N adapters gateway (le « moteur » de fédération, ~300 LOC) |
| Catalogue + portail + self-service | **Backstage** | `backstage` (app buildée) | Catalogue unifié des 3 gateways + portail dev + scaffolder self-service |
| IdP master (mock Oracle) | **Dex** | `dexidp/dex` | Mock de l'IdP Oracle (OIDC upstream) — « Oracle reste master » |
| Broker d'identité | **Keycloak** | `quay.io/keycloak/keycloak` | Broke Dex(Oracle) en upstream, émet les tokens consommés par les 3 gateways |
| Observabilité | **OTel Collector** + **Grafana LGTM** | `otel/opentelemetry-collector-contrib`, `grafana/otel-lgtm` | OTLP des 3 gateways → 1 dashboard Grafana (Tempo/Loki/Prometheus) |
| Backend synthétique | **Microcks** | `quay.io/microcks/microcks-uber` | Mocke le backend depuis l'OpenAPI (zéro donnée réelle) |

> Tous publics/self-hostables, zéro SaaS. WSO2 APIM est lourd (~2-4 Go RAM) — empreinte à valider en Phase 1.

---

## 2. Ce qu'on emprunte conceptuellement à STOA (inspiration, pas copie)

| Idée STOA (source) | Transposition OSS dans `stoa-labs` |
|---|---|
| UAC « Define Once » (`uac_contract_v1_schema.json`) | **OpenAPI 3.x pur** + un `targets.yaml` léger (liste des gateways cibles) |
| Adapter pattern (`gateway_adapter_interface.py`, `adapter.go`) | Interface Go minimale `GatewayAdapter{ Publish, List, Health }`, 3 impls (wso2/apisix/webmethods) |
| Dispatch « 1 contrat → N gw » (`contracts.py:836-865`) | Boucle `labctl apply` sur `targets.yaml` → `adapter.Publish(openapi)` (~50 LOC) |
| Broker OIDC (`demo-federation/keycloak/*.json`) | Réutiliser la **structure** des realms/broker JSON comme template (config OSS Keycloak) |
| Corrélation Tempo↔Loki↔Prometheus (`datasources.yml`) | Reproduire la provisioning Grafana de corrélation traces↔logs↔métriques |
| webMethods admin surface (`adapters/webmethods/adapter.py` → `/rest/apigateway/*`) | Le mock Go expose **exactement** ces endpoints → l'interface reste fidèle au vrai produit |

---

## 3. Architecture cible du PoC (ASCII)

```
   dev (self-service via Backstage)            ┌───────── BACKSTAGE (OSS) ──────────┐
        │  "request access"                    │  Software/API catalog (3 gateways) │
        │                                      │  Scaffolder: subscribe → creds     │
        ▼                                      └───────┬───────────────┬────────────┘
   ┌─────────────────────────┐  register entities     │ provision     │ (token client)
   │  labctl apply -f         │◄───────────────────────┘               ▼
   │   accounts-read.openapi  │                                ┌─────────────────┐
   │   + targets.yaml         │     ┌── moteur fédération ──┐  │  Keycloak       │
   │  (orchestrateur mince Go)│     │ for t in targets:     │  │  (broker)       │
   └──────────┬───────────────┘     │   adapter[t].Publish  │  │  realm stoa-lab │◄── Dex
              │ Publish(OpenAPI)     └───────────────────────┘  │  Oracle=master  │   (mock
              ├──────────────┬────────────────┬────────────────┐└────────┬────────┘   Oracle
              ▼              ▼                 ▼                          │ tokens      OIDC)
    ┌──────────────┐ ┌──────────────┐ ┌────────────────────┐            │ consommés
    │ WSO2 APIM    │ │ Apache APISIX│ │ webMethods MOCK(Go)│◄───────────┘ par les 3 gw
    │ Publisher    │ │ Admin API    │ │ /rest/apigateway/* │
    │ (réel OSS)   │ │ (réel OSS)   │ │ (legacy stand-in)  │
    └──────┬───────┘ └──────┬───────┘ └─────────┬──────────┘
           │ OTLP           │ OTLP (plugin      │ OTLP
           │                │  opentelemetry)   │
           ▼                ▼                   ▼
        ┌──────────────────────────────────────────────┐        backend synthétique
        │  OTel Collector → Grafana LGTM               │   ┌──────────────────────┐
        │  Tempo · Loki · Prometheus                   │   │ Microcks (mock depuis │
        │  1 DASHBOARD, var $gateway = wso2|apisix|wm  │   │ OpenAPI, 0 donnée réel)│
        └──────────────────────────────────────────────┘   └──────────────────────┘
```

Chaîne identité : **Dex (Oracle master, mock) → Keycloak (broker, émetteur) → token validé par WSO2 + APISIX + webMethods**.

---

## 4. Liste exhaustive des artefacts (tout est neuf — repo greenfield)

> Le repo `stoa-labs` est vierge (README/LICENSE/.gitignore déjà posés). Tout ci-dessous est à créer sous `poc-control-plane-federation/`.

**Socle & compose**
1. `docker-compose.yml` — orchestration des 9 briques OSS.
2. `.env.example` — ports, domaines, placeholders (zéro secret en clair).

**Orchestrateur de fédération (la pièce semi-custom)**
3. `labctl/` (Go) — CLI `apply` (publication) **et `subscribe`** (provisioning : client KC + consumers sur les 3 gw) + interface `GatewayAdapter` + boucle de dispatch. **CLI-first** : la logique de provisioning vit ici, Backstage ne fait que l'appeler (filet de sécurité démo + renforce le récit « orchestrateur mince »).
4. `labctl/adapters/wso2.go` — Publish OpenAPI → WSO2 Publisher REST (create/publish).
5. `labctl/adapters/apisix.go` — Publish OpenAPI → APISIX Admin API (route/service/upstream).
6. `labctl/adapters/webmethods.go` — Publish OpenAPI → mock admin REST.
7. `labctl/adapters/backstage.go` — register l'API dans le catalogue Backstage.

**Mock legacy**
8. `mocks/webmethods/` (Go) — admin REST `/rest/apigateway/{is/health,apis,subscriptions}` + proxy data-plane + émission OTel. Interface = celle du vrai apigateway:10.15.

**Contrat (Define Once)**
9. `apis/accounts-read.openapi.yaml` — OpenAPI 3.x synthétique (`GET /accounts`, données fictives).
10. `apis/targets.yaml` — gateways cibles (`[wso2, apisix, webmethods]`).

**Identité**
11. `identity/dex/config.yaml` — mock Oracle (OIDC), users synthétiques (alice/bob).
12. `identity/keycloak/realm-stoa-lab.json` — realm broker + `identityProvider` oidc `oracle` (template depuis `demo-federation`).

**Catalogue / Portail (Backstage)**
13. `backstage/` — app Backstage (catalog + scaffolder).
14. `backstage/catalog/` — entités API/Component des 3 gateways.
15. `backstage/plugins/subscribe/` (scaffolder action) — flux self-service : request → approve → **appelle `labctl subscribe`** (provisioning consumer 3 gw + client KC). Backstage déclenche, `labctl` exécute.

**Observabilité**
16. `observability/otel-collector-config.yaml` — receivers OTLP → exporters LGTM.
17. `observability/grafana/federation-overview.json` — dashboard 3 runtimes, variable `$gateway`.
18. `observability/grafana/provisioning/` — datasources corrélées (Tempo↔Loki↔Prometheus).

**Scripts & evidence (DoD STOA)**
19. `scripts/up.sh` · `down.sh` · `teardown.sh` (destruction contrôlée).
20. `scripts/seed.sh` — bootstrap Keycloak/Dex + enregistrement des 3 gateways.
21. `scripts/demo.sh` — `labctl apply` → vérifie publication sur les 3 gw + appel data-plane.
22. `scripts/smoke-test.sh` — tests automatisés (healthy + e2e).
23. `EVIDENCE.md` (Phase 4) + captures/exports.
24. `README.md` du PoC (quickstart anonymisé).
25. `memory.md` / `plan.md` du repo — tenus à jour avant tout `/clear`.
26. **`POSITIONING.md`** (condition C1) — « scaffold PoC jetable vs valeur produit STOA » + one-liner « pourquoi acheter STOA ». À écrire AVANT la démo.
27. **`HARD-CRITERIA-MAP.md`** (condition C2) — « ce que ce jet prouve vs critères durs de l'étude » (RI éliminatoire en tête, prochain must-prove). À écrire AVANT la démo.

---

## 5. Découpage en sous-tickets (estimation Claude time, ÷10 vs traditionnel)

### Phase 1 — Socle OSS (docker-compose)
| # | Ticket | Claude time |
|---|---|---|
| T1 | `docker-compose.yml` + WSO2 APIM réel up + healthcheck | ~2 h |
| T2 | Apache APISIX + etcd + Admin API + plugin opentelemetry | ~1 h |
| T3 | Mock webMethods (Go) : admin REST + data-plane + OTel | ~2 h 30 |
| T4 | Dex (mock Oracle) + Keycloak broker realm + fédération OIDC | ~1 h 30 |
| T5 | OTel Collector + Grafana LGTM ; 3 gateways émettent en OTLP | ~1 h 30 |
| T6 | Microcks backend synthétique (import OpenAPI) | ~30 min |
| T7 | Backstage app scaffold + run + catalogue de base | ~2 h |
| T8 | **DoD Phase 1** : `compose up` tout healthy + Grafana voit les 3 gw | ~30 min |

### Phase 2 — `labctl` + Define Once
| # | Ticket | Claude time |
|---|---|---|
| T9 | `labctl` skeleton (CLI Go) + interface `GatewayAdapter` + dispatch loop | ~1 h |
| T10 | Adapter WSO2 (Publisher REST publish) | ~2 h |
| T11 | Adapter APISIX (Admin API route/service/upstream) | ~1 h |
| T12 | Adapter webMethods-mock | ~30 min |
| T13 | OpenAPI `accounts-read` + `targets.yaml` | ~30 min |
| T14 | `labctl apply` → publie sur 3 gw + register Backstage | ~1 h 30 |
| T15 | **DoD Phase 2** : 1 cmd → API live sur 3 gw + visible Backstage + data-plane OK | ~1 h |

### Phase 3 — Self-service + identité
| # | Ticket | Claude time |
|---|---|---|
| T16 | Backstage : entités API des 3 gw + découverte/catalogue unifié | ~1 h |
| T17 | `labctl subscribe` (provisioning consumer 3 gw + client KC) **puis** scaffolder action Backstage qui l'appelle — CLI-first | ~2 h 30 |
| T18 | Chaîne identité Dex(Oracle)→Keycloak broker→token consommé par 3 gw | ~2 h |
| T19 | **DoD Phase 3** : appel authentifié e2e via chaque gateway (token Oracle-master) | ~1 h |

### Phase 4 — Evidence
| # | Ticket | Claude time |
|---|---|---|
| T20 | Dashboard fédération (`$gateway` sur 3 runtimes) + atterrissage Tempo/Loki/Prom | ~1 h |
| T21 | `EVIDENCE.md` + captures (7 preuves) + `smoke-test.sh` + teardown | ~2 h |

**Total : ~28-30 h Claude time** (Phase 1 ≈ 12 h · Phase 2 ≈ 7 h · Phase 3 ≈ 6 h 30 · Phase 4 ≈ 3 h).

---

## 6. Décisions VERROUILLÉES (Council)

1. **Mock Oracle → Dex.** ✅ Lit comme un vrai IdP tiers ; fédération multi-produit plus crédible qu'un KC-broke-KC circulaire.
2. **Self-service → scaffolder action Backstage, provisioning dans `labctl`.** ✅ Backstage déclenche `labctl subscribe`. CLI-first = filet de sécurité démo (survit si Backstage déconne) + renforce « orchestrateur mince ».
3. **Grafana → `grafana/otel-lgtm` all-in-one.** ✅ 1 brique OTLP-in/Grafana-out. **EVIDENCE doit préciser : image dev/démo, pas le design prod** (coupe court à l'objection).
4. **`labctl` → Go.** ✅ Binaire unique kubectl-style fidèle à `stoactl` ; « lit produit » devant une banque mieux qu'un script Python.
5. **Empreinte → profil `light` + backup vidéo = CONDITION, pas option.** WSO2 analytics off dès le départ (≥16 Go RAM sinon menace la démo live). Vidéo de backup conforme au DoD.

---

## 7. Conformité aux contraintes non négociables

- ✅ **OSS-first** : 9 briques OSS sur étagère ; seul `labctl` + le mock webMethods sont du code (mince, justifié).
- ✅ **Inspiré-pas-copié de STOA** : on porte les idées (UAC→OpenAPI, adapter, dispatch, broker, obs corrélée), pas la stack propriétaire.
- ✅ **Anti-§7.6** : pas de moteur de fédération custom lourd — orchestrateur mince sur APIs d'admin standard.
- ✅ **Souveraineté** : 100 % local/self-hosted, zéro SaaS — l'argument vs Axway Amplify.
- ✅ **Anonymisation** : « BC / institution financière régulée (anonymisé) » uniquement.
- ✅ **Pas de secrets en clair** : `.env.example` + placeholders.
- ✅ **OTel natif partout** : 3 gateways → OTLP → LGTM.
- ✅ **DoD STOA** : scripts up/down/teardown + smoke-test à chaque phase.

---

## 8. GATE — GO CONDITIONNEL (Council ~7→8+/10)

**GO conditionnel accordé.** Phase 1 (T1-T8) lançable **en parallèle** du verrouillage des conditions :
- **C1** — `POSITIONING.md` (scaffold jetable vs valeur produit STOA) — à livrer avant la démo.
- **C2** — `HARD-CRITERIA-MAP.md` (jet vs critères durs, RI = prochain must-prove) — à livrer avant la démo.
- **Filet d'exécution** — provisioning dans `labctl` (T17 CLI-first) + profil `light` + backup vidéo (condition).

5 décisions §6 verrouillées. **Passage à 8+/10 conditionné à C1 + C2 livrés.**

_Phase 0 — repo cible `stoa-labs`. Choix de briques OSS ; tags d'images à confirmer en Phase 1 (per MEGA)._
