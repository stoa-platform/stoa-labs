---
title: "ADR-073 — Traces du webMethods réel vers Tempo : le tracer natif 10.15 est inroutable ; pont events→OTLP (Log Invocation → custom destination → wm-trace-bridge) = voie retenue, PoC ET cible (E2EM écarté : payant, refus client)"
sidebar_label: "ADR-073 : Traces wM → Tempo"
status: "Accepté — implémenté et vérifié in-situ 2026-06-12"
maturite_technique: "✅ Implémenté & vérifié in-situ (wm-trace-bridge, trace réelle)"
date: 2026-06-12
adr_number: 73
visibility: private
note: "Privé (stoa-labs). S'appuie sur ADR-068 (hors data-plane), ADR-070 (frontière OpenSearch=audit / otel-lgtm=ops, corrélation par trace_id). Ne pas porter dans stoa-docs (public)."
---

# ADR-073 — Traces du webMethods réel vers Grafana Tempo

**Statut :** Accepté — implémenté et vérifié in-situ (2026-06-12).
**Maturité technique :** ✅ Implémenté & vérifié in-situ (`observability/wm-trace-bridge/`, trace réelle Tempo) — seul ADR dont les deux axes (business + technique) sont alignés.
**Révision 2026-06-12 (même jour)** : l'agent **E2EM est écarté pour la cible** (produit payant — décision client). Le pont events→OTLP passe de « démonstrateur PoC » à **voie retenue PoC ET cible**, sous les conditions de durcissement listées en Conséquences.
**Date :** 2026-06-12.
**Contexte client (anonymisé) :** banque — webMethods API Gateway **10.15** (data-plane legacy), observabilité cible OTel/Tempo.
**Lié à :** [[adr-068-stoa-off-the-transaction-path]], [[adr-070-opensearch-txn-analytics]].

---

## Décision (test « archi 40 ans / 30 secondes »)

> Le « tracing » activable par API dans webMethods 10.15 (**Trace API**) est un **tracer de debug couplé en dur à l'API Data Store (Elasticsearch)** : il est **inroutable** vers un backend de traces, et **aucun export OTel n'existe dans le produit** (vérifié doc IBM 10.11/10.15/**11.1** — un upgrade n'y change rien). Pour avoir les transactions du gateway dans **Tempo**, on n'utilise PAS ce tracer : on fait publier au gateway ses **transaction events** (policy **Log Invocation** globale → **custom destination** « External endpoint », config persistée dans l'ES externe) vers un shim **`wm-trace-bridge`** qui les convertit en **spans OTLP** (`service.name=webmethods`), corrélés au `trace_id` du client via le `traceparent` stocké dans les headers de l'événement.
> **Test** : *une trace Tempo d'un appel `accounts-read` traversant le wM réel porte-t-elle le trace_id émis par le client, sans payload ni secret dans les attributs ?* → **Oui, vérifié** (trace `1111…8888`, spans SERVER+CLIENT, Authorization masquée à la source par le gateway).

---

## Contexte et problème

Le PoC fait tourner le **vrai** webMethods (`softwareag/apigateway-trial:10.15`). Le DoD fédération exige les **3 runtimes réels** visibles dans Grafana/Tempo (`service.name` par gateway, corrélation `trace_id`). Or seul le mock émettait de l'OTel ; et la question naïve — « le gateway sait tracer, routons ses traces vers Tempo » — ne marche pas :

- Le **Trace API** (bouton *Enable tracing*) capture policies/payloads/logs par requête mais **stocke exclusivement dans l'API Data Store** (event types `Mediator trace span`, `Server log trace span`, `Request response trace span` ; index `gateway_default_mediatortracespan`…). Seules opérations : archive/purge (+ export manuel de fichiers). **Aucune destination configurable.** C'est en outre un outil de debug : impact performance/stockage documenté, à laisser éteint.
- Les **Destinations** 10.15 (Elasticsearch, Email, SNMP, JDBC, custom…) ne transportent que des **events** (Error, Lifecycle, Policy violation, métriques, audit, transaction events via Log Invocation) — **jamais** les trace spans du tracer.
- **Zéro occurrence** d'OpenTelemetry/OTLP/Jaeger/Zipkin dans la doc produit API Gateway 10.11/10.15/11.1 (recherche exhaustive IBM Docs, scope SSAQ10). La seule capacité native « distributed tracing » est la **propagation passive** d'en-têtes B3 (`watt.server.http.forwardHeaders`/`forwardableHeaders`) — le gateway n'émet aucun span.

## Options considérées

| Option | Verdict | Pourquoi |
|---|---|---|
| Tracer natif → Tempo | ❌ impossible | couplé API Data Store, pas d'exporteur |
| **Agent E2EM self-hosted** (officiel IBM) | ❌ **écarté pour la cible** (révision même jour : produit **payant**, refus client) | C'était la seule voie « supportée éditeur » : javaagent `uha-apm-agent.jar` (héritage SkyWalking), supporte API GW 10.11/10.15/11.1, export **OTLP/HTTP uniquement** (`…:4318/v1/traces`, gRPC « planned ») ; **Grafana Tempo listé « Supported, V10.15 Fix 9 »** dans la matrice « Self-hosted agent configuration to share data with external systems » (doc E2EM, ibm.com/docs/en/wm-end-to-end-monitoring). Binaires sous entitlement IBM (Update Manager), licence produit SaaS E2EM — **coût rédhibitoire pour le client**. Conservé ici comme référence si la position change |
| **Pont events→OTLP** (`wm-trace-bridge`) | ✅ **RETENU — PoC ET cible** | 100 % features stock 10.15 (Log Invocation + custom destination = supportées éditeur, **sans licence additionnelle**), config en ES externe → survit au keepalive, shim Go <500 lignes hors tests (≈370 lignes de code) **dont l'opération nous incombe** (cf. conditions de durcissement en Conséquences), pattern identique au kafka-logger APISIX (ADR-070) |
| javaagent OTel générique sur la JVM IS | ❌ écarté | le listener HTTP d'IS est propriétaire (`com.wm.*`) → **aucun span SERVER**, seulement du bruit client (client ES interne) ; aucun retour terrain public |
| Otelscope (Nibble Technologies) | ❌ écarté | commercial tiers, support 10.15 non documenté publiquement |

## Architecture retenue (PoC)

```
client ──traceparent──▶ wM 10.15 (:5555 data-plane)
                          │ global policy «Transaction logging» (Log Invocation,
                          │ headers ON / payloads OFF, Always)
                          ▼
                  custom destination «StoaTraceBridge»
                  (External endpoint, POST 1 event JSON / requête)
                          │
                          ▼
                  wm-trace-bridge (Go, :9100)          ← observability/wm-trace-bridge/
                  ═══ LE Y ═══
                  branche 1 (ops) — événement → spans :
                    SERVER «GET accounts-read/accounts» [creationDate, +totalTime]
                    └─ CLIENT «native GET»              [externalCalls.callStartTime, .callEndTime]
                  trace_id = traceparent client (sinon B3, sinon nouveau)
                          │ OTLP/HTTP
                          ▼
                  otel-lgtm:4318 → Tempo (service.name=webmethods)

                  branche 2 (gouvernance) — JSON BRUT des events Transactional
                          │ Kafka «stoa.txn.webmethods»
                          ▼
                  Redpanda → Data Prepper (pipeline stoa-txn-webmethods :
                  normalise wM → schéma stoa.txn, redacte, capture stricte,
                  pivot trace_id extrait du traceparent stocké)
                          ▼
                  OpenSearch txn-{tenant} (mêmes data streams que APISIX)
```

**Frontière ADR-070 intacte** : OpenSearch = audit/gouvernance (capture model : succès=métadonnées, erreur=body+headers redactés) ; otel-lgtm/Tempo = ops temps réel. Le bridge n'écrit **que des métadonnées** dans les spans (pas de headers, pas de payloads — il ne fait que LIRE `traceparent`/`x-b3-*`) et, côté Y analytics, **ne transforme pas** : il publie le JSON brut, Data Prepper reste l'**autorité unique** de normalisation/redaction (ADR-070). Différence assumée vs APISIX : payloads OFF à la source (Log Invocation ne capture pas conditionnellement) → les erreurs partent **sans `response_body`** ; activer `storeResponsePayload` si l'audit body devient exigé. Bonus constaté : le gateway **masque `Authorization` à la source** (`**************`) dans les events. Corrélation : le pivot `trace_id` est extrait du `traceparent` stocké → la table OpenSearch et la trace Tempo du même appel partagent le même id (dashboard `stoa-fed-otel-txn`).

**Métriques (quick win)** : `GET :5555/metrics` (anonyme en Docker) scrapé par le Prometheus d'otel-lgtm (`observability/prometheus/prometheus-wm.yaml`, monté par l'overlay wm) — métriques par-API `sag_apigw_api_*` (10.15+). Gauges remises à zéro à chaque scrape, compteurs au restart (keepalive !) → lire en `increase()`.

## Découvertes in-situ (non documentées chez IBM)

1. **Une custom destination EST un policyAction** `templateKey=customDestination` (`POST /rest/apigateway/policyActions`) — collection Postman officielle du repo GitHub SoftwareAG, pas dans la doc.
2. **Log Invocation référence une custom destination par `{destinationType: "CUSTOM", ids: ["<customDestinationName>"]}`** — le paramètre `ids` n'apparaît **ni** dans le template (`/policyActionTemplates/logInvocation`), **ni** dans la doc, **ni** dans la collection Postman ; capturé sur ce que l'UI 10.15 enregistre. (`destinationType:"<nom>"` seul et `"CUSTOM"` sans `ids` sont acceptés par l'API mais **silencieusement ignorés** au runtime.)
3. Le dispatcher POSTe **un événement JSON par requête** (UA `Mozilla/4.0 [en] (WinNT; I)`), latence observée ≈ 10-40 s. Champs numériques **nullables** (`gatewayTime=null` au 1er appel post-boot). L'événement porte un tableau **`externalCalls`** (non documenté) donnant la **fenêtre exacte de l'appel natif** (`callStartTime`/`callEndTime`/`responseCode`).
4. `traceparent` est **déjà forwardé au backend** par le routing 10.15 (observé dans `nativeRequestHeaders`) bien qu'absent de `forwardableHeaders` par défaut — on aligne quand même la liste (`wm-otel-setup.sh` §4) pour `tracestate` et la conformité déclarée.
5. Le champ `active:false` des policyActions est un leurre (les policies enforced l'affichent aussi) ; la system policy `GlobalLogInvocationPolicy` (« Transaction logging ») s'active par `PUT /policies/GlobalLogInvocationPolicy/activate`.
6. **Les 401 « sans Authorization » ne génèrent AUCUN événement** : auth non-preemptive → le gateway le dit lui-même (`YAI.0102.0018I : A non-preemptive authentication request has been made. Hence, this will not be logged as a transaction/error event.`). Seuls les rejets **preemptive** (header Authorization présent mais invalide : signature altérée, JWT forgé, mauvais realm) produisent un PolicyViolation event — c'est le cas qui compte pour l'audit bancaire (attaque), l'anonyme pur n'étant visible que dans `sag_apigw_apicalls_total{code="401"}`.
7. Les custom destinations ne sont (re)chargées qu'au **boot** (`CustomDestinationInitializer`) : toute modification exige un restart du gateway pour prendre effet au runtime — piège de diagnostic (la config REST/UI paraît appliquée, le dispatcher vit sur l'ancienne). L'abonnement `customDestinationEvents` de la destination a été retiré (jamais observé livrer un POST ; inutile au pont, le poller lit l'ES).

## Conséquences

- ✅ DoD fédération : 3 gateways **réelles** dans Tempo avec corrélation `trace_id` client.
- ✅ Tout survit au keepalive (`docker restart`) : destination+policy en ES externe ; le mount Prometheus et le bridge sont du compose. Les `watt.*` (server.cnf) survivent au restart mais **pas au force-recreate** → relancer `./scripts/wm-otel-setup.sh` (idempotent).
- ⚠️ Les spans wM arrivent en **différé** (~10-40 s) et les durées sont **reconstruites** (`creationDate`/`totalTime`/`providerTime`) — fidèle pour l'analyse, pas du streaming temps réel. Assumé : ADR-068, STOA hors data-plane.
- ✅ Le span natif utilise la **fenêtre exacte** fournie par `externalCalls` (`callStartTime`/`callEndTime`) ; repli `providerTime` en fin de fenêtre si le tableau est absent (versions/fixpacks).
- ⚠️ Les events **PolicyViolation (rejets 401) ne sont pas dispatchés** vers la custom destination malgré l'abonnement ERROR+POLICYVIOLATION (observé 2×, ils arrivent bien dans l'ES interne) — les 401 restent couverts par `sag_apigw_api_tx_error_count` (Prometheus) et la voie analytics ADR-070 ; le bridge sait les convertir s'ils arrivent (testé sur fixture).
- 📌 **Pour la cible bancaire (révision même jour — E2EM écarté, produit payant)** : le **pont est la voie cible**. Les 4 conditions de durcissement sont **traitées en OSS** (implémentées et vérifiées le jour même) :
  - **HA/perte d'events → durable-first (Kafka/Redpanda)** : l'ingestion HTTP ne fait plus que persister l'event brut dans le topic ; l'émission des spans est un **consumer Kafka** (groupe `wm-trace-bridge-spans`, distinct de `data-prepper` — chacun lit tout). Bridge redémarré ou Tempo down = les events **attendent dans le topic**, zéro perte aval. At-least-once assumé (rare doublon de span > trou). Mode dégradé sans Kafka : émission directe. **Résidu** : l'entrée HTTP reste le point de dispatch unique du gateway → en cible, N réplicas stateless derrière un VIP/LB (déploiement, pas du code) ; un bridge down pendant la fenêtre de dispatch perd les events de cette fenêtre.
  - **Charge → harnais de mesure** : `scripts/wm-loadcheck.sh` compare p50/p95 policy ON/OFF (restaure l'état quoi qu'il arrive). Sur le trial émulé : ordre de grandeur seulement — à rejouer sur la cible avec un injecteur réel et la volumétrie bancaire. Repli : Log Invocation par-API au lieu de la global policy.
  - **Fragilité fixpack → harnais de contrat exécutable** : `scripts/wm-contract-check.sh` rejoue un appel et re-valide CHAQUE comportement non documenté contre le gateway vivant (`externalCalls` fenêtré, `responseCode` string, traceparent stocké, Authorization masquée, **noms de payloads connus** — toute nouveauté = FAIL explicite avec consigne de mise à jour). S'appuie sur `GET /debug/last-event` du bridge (dernier event brut). À lancer après chaque fixpack ; les fixtures réelles versionnées (`testdata/`) restent le harnais de non-régression unitaire.
  - **Angle mort 401 → poller PolicyViolation** : le gateway ne dispatche pas les rejets vers les custom destinations, mais il les écrit dans son API Data Store → le bridge **polle** `gateway_default_analytics_policyviolationevents*` (30 s, curseur=boot, pas de replay) et injecte chaque rejet dans le même chemin durable → **spans Error visibles dans Tempo**. Data Prepper les filtre (eventType ≠ Transactional) : parité analytics des 401 = extension possible du pipeline, non faite. Résidus inchangés : spans différés ~10-40 s, durées reconstruites (fenêtre native exacte via `externalCalls`).
