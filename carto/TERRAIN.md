# Terrain client mesuré — 2026-07-30

Gateway sondée : webMethods API Gateway 10.15 (namespace `wm`, cluster labo Contabo).
Accès : admin REST `http://127.0.0.1:15555/rest/apigateway` (`Administrator:manage`,
`Accept: application/json` obligatoire) ; API Data Store (Elasticsearch)
`http://127.0.0.1:19200`. Toutes les valeurs ci-dessous sont mesurées, pas devinées.

## V1 — date de création des APIs et Applications

Champ Application : **`created`** — présent directement dans la liste
`GET /applications` (pas seulement dans le détail).
Exemple mesuré (application semée par cette tâche) :
`"created": "2026-07-30 16:59:33 GMT"`.

Champ API : **`creationDate`** — ABSENT de la liste `GET /apis`
(`apiResponse[].api` ne contient que `apiName, apiVersion, isActive, type,
tracingEnabled, publishedPortals, systemVersion, id`), mais PRÉSENT dans le
détail `GET /apis/{apiId}` (`apiResponse.api.creationDate`,
ex. `"2026-07-30 16:55:59 GMT"` pour `carto-probe-api`) ainsi qu'un
`lastModified`.

Commandes :
```
curl -sS -u Administrator:manage -H 'Accept: application/json' \
  http://127.0.0.1:15555/rest/apigateway/applications
curl -sS -u Administrator:manage -H 'Accept: application/json' \
  http://127.0.0.1:15555/rest/apigateway/apis
curl -sS -u Administrator:manage -H 'Accept: application/json' \
  http://127.0.0.1:15555/rest/apigateway/apis/<apiId>
```

Conséquence : la date de création des Applications est disponible sans appel
supplémentaire (liste). Pour les APIs, un second appel par API (détail) est
nécessaire pour obtenir `creationDate` — à budgéter dans T2/T3 (N+1 appels).
Le champ n'est pas ABSENT au sens strict, mais son coût d'accès diffère selon
l'entité ; documenté pour éviter la surprise en T9.

## V2 — rétention réelle des index d'analytics

Plus vieil événement mesuré (voir aussi la mise en garde ES_INDEX en V3) :

- Dans l'index retenu comme ES_INDEX (`gateway_default_analytics_errorevents-*`) :
  `2026-07-30T07:15:17.163Z` → **profondeur réelle ≈ 1 jour** (date du jour :
  2026-07-30). Requête (voir `carto/tests/fixtures/oldest-event.json`) :
  ```
  curl -s -H 'Content-Type: application/json' \
    'http://127.0.0.1:19200/gateway_default_analytics_errorevents*/_search' \
    -d '{ "size": 0, "aggs": { "oldest": { "min": { "field": "creationDate" } } } }'
  ```
- Dans `gateway_default_analytics_lifecycleevents-*` (événements de cycle de
  vie, plus anciens que les événements d'erreur) : `2026-07-29T14:49:53.799Z`
  → correspond à l'âge du cluster labo lui-même (stand-up récent), pas à une
  vraie politique de rétention.
- Dans `gateway_default_analytics_transactionalevents-*` : agrégation `min`
  renvoie `null` (0 document — voir V3, finding critique).

Conséquence : **la profondeur mesurée ici (~1 jour) reflète l'âge du labo, pas
une rétention produit.** Elle n'est PAS transposable telle quelle chez le
client : à re-mesurer sur un tenant qui tourne depuis longtemps. Ne pas figer
en dur "1 jour" comme fenêtre affichable dans le code — le paramétrer.

## V3 — chemins d'administration et shape de l'agrégation

Sources primaires (lues à la source, pas devinées) :
```
kubectl -n wm exec deploy/wm-apigateway -- ls \
  /opt/softwareag/IntegrationServer/instances/default/packages/WmAPIGateway/resources/apigatewayservices/
# → APIGatewayServiceManagement.json (APIs), APIGatewayApplication.json (Applications)
```

Liste des APIs         : `GET /rest/apigateway/apis`
  (`operationId: getAPIs`, params optionnels `apiIds`, `from`, `size`)
Détail d'une API        : `GET /rest/apigateway/apis/{apiId}`
Liste des Applications  : `GET /rest/apigateway/applications`
  (`operationId: getApplications`)
Détail d'une Application: `GET /rest/apigateway/applications/{applicationId}`

Lien déclaré (Application → APIs autorisées) :
`GET /rest/apigateway/applications/{applicationId}/apis`
→ réponse mesurée : `{"apiIDs": ["<uuid>", ...], "apis": [...détail complet...]}`.
Écriture (déclaration) : `POST` sur le même chemin, corps
**`{"apiIDs": ["<uuid>", ...]}`** (⚠ pas un tableau JSON nu — un tableau nu
`["<uuid>"]` renvoie 500 `{"errorDetails":null}`, mesuré en direct). Remplace
la liste complète des APIs déclarées (non additif).

DECLARED_PATH = `/applications/{applicationId}/apis`

ES_INDEX / ES_API_FIELD / ES_APP_FIELD / ES_TIME_FIELD / ES_STATUS_FIELD —
**finding critique, à lire en entier avant de recopier ces constantes** :

L'API Data Store expose plusieurs index d'événements
(`_cat/indices?v` → familles `gateway_default_analytics_<type>-*`). La
shape "idéale" décrite dans le brief (agrégation imbriquée api → consumer,
avec `last` et compteur d'erreurs) correspond exactement au mapping de
**`gateway_default_analytics_transactionalevents-*`**
(`apiId` keyword, `applicationId` keyword, `creationDate` date, `responseCode`
keyword, `httpMethod`, `totalTime`, etc. — mapping complet vérifié via
`GET /gateway_default_analytics_transactionalevents*/_mapping`).

**Mesuré en conditions réelles : cet index est resté à 0 document** après
plus de 50 appels data-plane réels (succès et erreurs, avec et sans clé
d'application, avant et après un redémarrage du pod, avec `tracingEnabled`
activé, avec 3 vérifications espacées et un `_refresh` forcé). Ni les
réglages `configurations/gatewayDestinationConfig`,
`configurations/elasticsearchDestinationConfig`,
`configurations/desDestinationConfig` (aucun n'expose de bascule
`sendTransactionalEvent` — seuls `sendErrorEvent`, `sendPerformanceMetrics`,
`sendLifecycleEvent`, `sendPolicyViolationEvent` existent), ni l'activation du
tracing par API (`PUT /apis/{apiId}/tracing/enable`, qui peuple en revanche
`gateway_default_mediatortracespan-*` et
`gateway_default_requestresponsetracespans-*` — traces d'appel brutes,
**sans champ `applicationId`**) n'ont débloqué d'écriture dans cet index.

L'index réellement peuplé par le trafic data-plane, avec les 4 champs requis,
est **`gateway_default_analytics_errorevents-*`** — mais il ne contient QUE
les invocations qui se terminent en erreur (`responseCode >= 400`), jamais
les succès. Champs mesurés sur un document réel :
```json
{"eventType":"Error","apiId":"...","apiName":"...","apiVersion":"...",
 "applicationId":"Unknown","applicationName":"Unknown","applicationIp":"...",
 "operationName":"/accounts","httpMethod":"get","responseCode":"405",
 "errorDesc":"Method not allowed : post","creationDate":1785431...,
 "correlationID":"..."}
```

Constantes retenues (mesurées, pas idéales) :
- `ES_INDEX` = `gateway_default_analytics_errorevents-*` (motif ES ;
  index concret vu : `gateway_default_analytics_errorevents_1785336568900-000001`)
- `ES_API_FIELD` = `apiId`
- `ES_APP_FIELD` = `applicationId`
- `ES_TIME_FIELD` = `creationDate` (epoch millis)
- `ES_STATUS_FIELD` = `responseCode` (type `keyword`/`text`, chaîne à 3
  chiffres — une comparaison lexicographique `gte "400"` fonctionne car tous
  les codes HTTP standards font 3 caractères, mais ce n'est pas un entier)

**Conséquence directe pour T2/T3 : l'agrégation de volumétrie par
consommateur, cœur du produit, ne peut aujourd'hui mesurer QUE le trafic en
erreur.** Le trafic réussi (la majorité des appels, y compris nos rafales
différenciées par Application) n'est tracé nulle part dans cet
environnement. C'est un blocage majeur pour la finalité du projet (cartographier
qui consomme quoi, pas seulement qui échoue), à vérifier en priorité absolue
sur le tenant client réel avant d'aller plus loin : il est plausible que ce
soit une limitation de cette image de démonstration/trial (licence limitée,
composant de collecte non démarré) plutôt qu'un comportement standard du
produit.

## V4 — contact exploitable sur les Applications

Champ `contactEmails` existe dans le schéma (`Application.contactEmails`,
tableau de chaînes) mais est **vide (`[]`)** sur toutes les Applications
observées, y compris celles semées par cette tâche (nous ne l'avons pas
renseigné) et l'Application préexistante `f3-proof-2026-07-29`.
Conséquence : source externe nécessaire pour un contact exploitable — laquelle
n'est pas déterminée ici (pas d'annuaire consommateurs disponible dans ce
labo). À lever avec le client : LDAP interne, CMDB, ou déclaratif au moment de
l'enregistrement de l'Application.

## V5 — identification de l'appelant dans les événements

Le champ `applicationId` est-il toujours renseigné ? **Non, jamais avec une
vraie identité observée dans cette campagne** : toutes les valeurs capturées
valent `"Unknown"` (ou `"unknown"` après normalisation par l'analyseur ES du
champ `applicationId` sur cet index, qui est `text` + `not_analyzed_ignorecase`,
pas un `keyword` strict — voir mapping mesuré).

Part d'événements sans appelant identifié : **100 % (12/12)** dans
l'échantillon capturé.

Mise en garde importante avant de généraliser cette mesure : les erreurs
capturées ici sont soit des `405 Method not allowed` (rejetées par la gateway
avant l'étage IAM où l'identification se produit — donc structurellement
`Unknown`, ce n'est pas un échec de la politique d'identification), soit des
`500 Downtime exception` / `404 Resource not found` antérieurs à notre
intervention. **Nous n'avons pas réussi, dans la fenêtre de temps disponible,
à produire une erreur authentifiée post-identification** (le backend
synthétique renvoie 200 pour toute route/id valide, donc pas de 4xx/5xx
métier après IAM). Une politique "Identify & Authorize Application" par clé
API (`x-Gateway-APIKey`, confirmé exact via
`config/resources/beans/gateway-core.xml` et
`configurations/settings.extendedKeys.apiKeyHeader`) a été créée et activée
(policy globale scope=API `carto-probe-api`), mais **son effet sur
l'attribution `applicationId` n'a pas pu être vérifié** faute d'un chemin
d'événement qui capture les succès (V3). À refaire dès que le blocage V3 est
levé.

Conséquence : tant que V3 n'est pas résolu, la quasi-totalité (voire la
totalité) des appels apparaîtront sous un consommateur « (non identifié) » —
recalibrer les attentes de la démo en conséquence.

## V6 — cible de publication

Non mesurée dans cette tâche (hors périmètre T0 : aucun mécanisme de dépôt/
publication de la cartographie n'a été sondé sur ce cluster — à traiter par
une tâche ultérieure une fois la collecte elle-même fiabilisée).

## Constantes à recopier dans le code

```python
API_FIELDS = {
    "id": "id",                    # GET /apis -> apiResponse[].api.id
    "name": "apiName",
    "version": "apiVersion",
    "isActive": "isActive",
    "creationDate": "creationDate",  # ABSENT de la liste, present dans /apis/{id} seulement
}
APP_FIELDS = {
    "id": "id",                    # GET /applications -> applications[].id
    "name": "name",
    "created": "created",          # present directement dans la liste
    "consumingAPIs": "consumingAPIs",
    "contactEmails": "contactEmails",  # vide dans ce labo (V4)
}
DECLARED_PATH = "/applications/{applicationId}/apis"   # GET -> {"apiIDs": [...]}; POST body = {"apiIDs": [...]}

ES_INDEX = "gateway_default_analytics_errorevents-*"   # voir avertissement V3 : erreurs uniquement
ES_API_FIELD = "apiId"
ES_APP_FIELD = "applicationId"
ES_TIME_FIELD = "creationDate"
ES_STATUS_FIELD = "responseCode"
```

## Objets semés sur cette gateway de labo (à nettoyer)

Préfixe `carto-probe-` sur tout ce qui a été créé :

- API `carto-probe-api` v1.0.0, id `5ed95567-62e7-4a4e-a2da-441f0b276098`
  (backend : `http://backend-dev.wm.svc.cluster.local:8080/accounts`, le même
  backend synthétique qu'`accounts-read`).
- Application `carto-probe-app-active`, id `4c329b2e-bcf7-45dc-996d-d5d9dfb538e0`
  (~40 appels générés, succès + erreurs 405).
- Application `carto-probe-app-low`, id `f06fa084-3745-4e6d-afac-98246b3c2757`
  (~10 appels générés, succès + erreurs 405).
- Application `carto-probe-app-idle`, id `b168b889-f8e5-4ab2-bd11-bdf351942e8a`
  (déclarée consommatrice de `carto-probe-api`, **zéro appel émis** — cas
  central "déclaré sans trafic").
- Policy action `187e03ac-cf30-4bfb-9592-c7c568f8e73a` (Identify & Authorize,
  templateKey `evaluatePolicy`, apiKey, `allowAnonymous=true`).
- Policy globale `b37b96d2-4ac9-4868-a2e3-b1cbe951ab46` (scope API_NAME =
  `carto-probe-api`), active.
- Policy service-scope orpheline `7287d306-62fb-48d6-a247-5e78dc76e20b`
  (créée puis non utilisée — remplacée par la policy globale ci-dessus ;
  peut être supprimée).

Suppression recommandée (ordre) : désactiver puis supprimer les 3
Applications, désactiver puis supprimer l'API, supprimer les 2 policies et la
policy action, via les mêmes chemins DELETE (`/applications/{id}`,
`/apis/{id}`, `/policies/{id}`, `/policyActions/{id}`).
