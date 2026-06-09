# HANDOFF — PoC Control Plane de Fédération (stoa-labs)

> État au 2026-06-09. À lire en premier pour reprendre. Données synthétiques,
> client anonymisé (institution financière régulée anonymisé). Repo : `stoa-platform/stoa-labs` (privé).

## TL;DR

PoC **validé live de bout en bout** : un control plane souverain (briques OSS) **fédère
3 gateways hétérogènes** — WSO2 (commercial), Apache APISIX (OSS), webMethods (mock legacy)
— sous **une identité Oracle-master** (Dex→Keycloak). **6/7 preuves live**, la 7ᵉ
(souveraineté) par construction. Observabilité **2/3** (WSO2 OTel en suivi).

## Où c'est

```
poc-control-plane-federation/
├── PLAN.md POSITIONING.md HARD-CRITERIA-MAP.md EVIDENCE.md   # cadrage + preuves
├── README.md                                                # quickstart + état des phases
├── docker-compose.poc.yml  .env.example                     # socle (9 briques OSS)
├── docker-compose.ci.yml   ci/                              # CI bank-réaliste (Gitea+Jenkins)
├── apis/accounts-read.openapi.yaml                          # le contrat "Define Once"
├── targets.yaml (host)  targets.cluster.yaml (in-network)   # manifeste de fédération
├── labctl/   (+ vendor/ → build air-gapped)                 # l'orchestrateur (3 adapters)
├── mocks/webmethods/                                        # gateway legacy (Go, OTel + JWKS)
├── identity/{dex,keycloak}/  gateways/apisix/  observability/
└── scripts/{up,down,teardown,smoke-test,demo,setup-identity,phase3-identity-demo,get-oracle-token,setup-wso2-otel}.sh
adr/  (privé)  adr-067 reuse-first · adr-068 hors-transactionnel · adr-069 douve de rétention
```

## État des phases (toutes validées live sauf mention)

| Phase | Quoi | État |
|---|---|---|
| 0 | Plan + cadrage + ADR-067 | ✅ |
| 1 | Socle OSS (9 briques) | ✅ live |
| 2 | `labctl` Define Once → 3 gw (57 tests) | ✅ live |
| 3 | Identité Oracle-master (Dex→Keycloak→3 gw) | ✅ live |
| 4 | EVIDENCE + dashboard Grafana | ✅ (obs 2/3) |

## Reprendre la démo (stack up)

```bash
cd poc-control-plane-federation
./scripts/up.sh                      # 9 briques (WSO2 lent ~3min)
./scripts/demo.sh                    # publish + catalogue + subscribe + appels authentifiés
# Phase 3 (identité) — séquence à 2 temps pour WSO2 :
./scripts/setup-identity.sh          # enregistre le KeyCloak KM (+ APISIX oidc + prérequis KC)
docker restart poc-wso2am            # OBLIGATOIRE : WSO2 charge les KM au DÉMARRAGE
./scripts/setup-identity.sh          # re-run : map-keys réussit (KM chargé)
./scripts/phase3-identity-demo.sh    # 1 token Oracle (alice via Dex) → 200 sur les 3 gw
./scripts/smoke-test.sh
```

## Accès (synthétique)
- WSO2 Publisher/Devportal : https://localhost:9443/{publisher,devportal} — `admin`/`admin`
- Keycloak admin : http://localhost:8480/admin/ — `admin`/`admin` — realm `stoa-lab` (users `alice@bc.example`/`password`)
- Grafana : http://localhost:3000 — `admin`/`admin` — dashboard `stoa-fed-overview`
- Microcks : http://localhost:8585 — APISIX admin : `X-API-KEY: poc-apisix-admin-key` (9180)
- Clients : `poc-gateways`/`poc-gateways-secret` ; `accounts-read-consumer` (secret dans `labctl-credentials.txt`, gitignoré, régénéré par `subscribe`)

## Gotchas (pour qui reprend)
- **WSO2 : `docker restart` (pas recreate)** — recreate efface l'état H2 (APIs, KM, subs). Restart préserve + recharge le KM.
- **KM WSO2** : utiliser le connecteur **`KeyCloak`** (pas `default`=WSO2-IS → NPE `keyManagerServiceUrl`). Nécessite côté KC : un **client scope `default`** + rôles **`manage-clients`/`view-clients`** sur `poc-gateways` (le connecteur fait du DCR avec `scope=default`). `setup-identity.sh` applique tout ça (idempotent).
- **Issuer** : `KC_HOSTNAME=http://localhost:8480` épingle `iss` → tous les tokens (service-account ET broker Oracle) valident partout ; JWKS fetché en interne (`keycloak:8080`, BACKCHANNEL_DYNAMIC).
- **Keycloak recreate** efface les clients runtime (`accounts-read-consumer`) → re-jouer `demo.sh`.
- **`.env*` non éditables** (permission) → etcd (`quay.io/coreos/etcd`), port KC (`8480`), `JWT_ISSUER` sont **épinglés en dur dans le compose**.
- **`labctl` build air-gapped** : `cd labctl && GOPROXY=off GOFLAGS=-mod=vendor go build` (deps dans `vendor/`).
- **WSO2 OTel** : `setup-wso2-otel.sh` est **EXPÉRIMENTAL** — la config naïve a cassé le démarrage du gateway (reverté). À affiner avant usage.

## Décisions stratégiques (ADR privés — en attente Council 8/10)

| ADR | Décision | Council |
|---|---|---|
| 067 | Reuse-first — couche possédée portable, runtimes commodity fédérés (règle des 3 bacs) | **CONDITIONAL 6.8/10** |
| 068 | STOA **hors du chemin transactionnel** ; Reverse Invoke transactionnel = **capacité gateway**, pas STOA ; agent control-plane sortant-only (ou pull GitOps) | **CONDITIONAL 7.1/10** |
| 069 | **Douve de rétention** = gouvernance source-de-vérité vendor-neutral + fabric maintenue/garantie (survit à SAP+Joule ET à un pull GitOps) | Proposé |

**Modèle d'exploitation acté** : **CLI-en-CI / GitOps pull**, **pas d'agent runtime**, build **air-gapped** (vendor/), **binaire signé exécuté par LEUR CI** (Jenkins) — zéro flux entrant. Scaffold CI : `docker-compose.ci.yml` + `ci/` (Gitea+Jenkins+webhooks), **à valider au premier run**.

## Conditions Council — état

- ✅ **Traitées (doc)** : C3-068 (evidence-pack cohérent), C2-068 (gate DORA + secrets→PAM/Vault), C4-067 (intention/médiation dans la gate), C2-067 (douve nommée = ADR-069).
- ⏳ **Business (à toi)** : **C1-067** chiffrage BUILD/RUN 5 ans (barrière n°1 à l'auto-balle) · **C3-067** propriété juridique du Bac possédé · **C4-068** stratégie d'entrée GTM (hors-zone d'abord) + partenaire ESN qualifié.
- ⏳ **Technique** : **C1-068** prouver que l'agent bat un pull GitOps (sinon : pas d'agent) · must-prove ADR-069 « autorité, pas miroir » + « garantie, pas homme-jour ».
- ⚠️ **Angles morts Council (non instruits)** : le deal BC existe-t-il + est-il réplicable (2ᵉ logo jamais nommé) · SAP+Joule = scénario central, pas de queue · **chiffrer la fenêtre multi-runtime** (la variable la plus déterminante).

## Threads ouverts (prochaines actions possibles)

1. **Ansible** (dernier échange) : « on a Ansible, pourquoi le CLI ? » → **rider Ansible** (Bac B), livrer STOA en **collection Ansible** OU `labctl` appelé depuis un playbook. Floor honnête : s'ils ne valorisent ni la logique maintenue ni la gouvernance, pas de deal. **À faire** : scaffolder un exemple Ansible + acter « outillage = Bac B » dans ADR-067.
2. **Valider la CI Jenkins live** (Gitea+Jenkins+webhook → un commit fédère l'API).
3. **Re-soumettre 067/068/069 au Council** après les arbitrages business.
4. **Backstage/RHDH** : non déployé ; le positionner comme **wedge produit hors-zone** (réponse partielle C4-068), pas comme preuve technique.
5. **Reverse Invoke (data-plane)** : c'est une **capacité gateway** à vérifier produit par produit (webMethods ✓, WSO2/APISIX/SAP à confirmer) — pas un jet STOA.

## Comment c'est construit
~6 workflows multi-agents (design+vérif adversariale, implémentation parallèle, review, fix, Council) + débogage live. Leçon récurrente : **la vérification adversariale réduit le risque, l'exécution live confirme la vérité** (ex. WSO2 `deploy-revision`=201 vs 200 que la vérif avait inversé ; connecteur KeyCloak vs default ; etc.).
