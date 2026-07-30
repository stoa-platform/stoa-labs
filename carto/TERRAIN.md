# Terrain mesuré — 2026-07-30

Gateway sondée : webMethods API Gateway 10.15 (cluster Kubernetes de labo).
Accès : admin REST `http://127.0.0.1:15555/rest/apigateway` (`Administrator:manage`,
`Accept: application/json` obligatoire, via tunnel local) ; API Data Store
(Elasticsearch) `http://127.0.0.1:19200` (idem). Toutes les valeurs
ci-dessous sont mesurées, pas devinées.

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

Plus vieil événement mesuré dans **`gateway_default_analytics_transactionalevents-*`**
(ES_INDEX retenu, voir V3) : `2026-07-30T17:17:29.637Z` → cet index vient
tout juste d'être activé (voir V3), sa profondeur ne reflète donc que la
durée de cette session de mesure, pas une rétention réelle. Requête (voir
`carto/tests/fixtures/oldest-event.json`) :
```
curl -s -H 'Content-Type: application/json' \
  'http://127.0.0.1:19200/gateway_default_analytics_transactionalevents*/_search' \
  -d '{ "size": 0, "aggs": { "oldest": { "min": { "field": "creationDate" } } } }'
```

Pour référence, mesuré aussi dans deux autres index déjà peuplés avant notre
intervention :
- `gateway_default_analytics_errorevents-*` : `2026-07-30T07:15:17.163Z`
  (≈ 1 jour avant capture).
- `gateway_default_analytics_lifecycleevents-*` : `2026-07-29T14:49:53.799Z`
  (correspond à la mise en service du cluster de labo lui-même, pas à une
  politique de rétention).

Conséquence : **aucune des profondeurs mesurées ici n'est transposable au
client.** Elles reflètent l'âge du labo et le moment où la journalisation a
été activée pendant cette tâche (voir V3), pas une rétention produit. À
re-mesurer sur un tenant qui tourne depuis longtemps, avec la politique de
journalisation déjà correctement configurée dès le départ. Ne pas figer de
valeur en dur dans le code — paramétrer la fenêtre.

## V3 — chemins d'administration, shape de l'agrégation, et pourquoi l'index était vide

Sources primaires (lues à la source, pas devinées) :
```
kubectl exec deploy/<gateway> -- ls \
  /opt/softwareag/IntegrationServer/instances/default/packages/WmAPIGateway/resources/apigatewayservices/
# → APIGatewayServiceManagement.json (APIs), APIGatewayApplication.json (Applications),
#   APIGatewayAdministration.json (destinations, /apitransactions, description des types d'événements),
#   APIGatewayPolicyManagement.json (policies, policyActions, policyStages)
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

### ES_INDEX / ES_API_FIELD / ES_APP_FIELD / ES_TIME_FIELD / ES_STATUS_FIELD

**Root cause trouvée et corrigée** (ne plus refaire cette investigation en
T2/T3). Le texte de description de `APIGatewayAdministration.json`
(paramètre `eventType` de `GET /apitransactions`) dit noir sur blanc :

> Transactional event: Provides a summary (request & response) of each
> runtime transaction in the system. **It is generated when a Log
> Invocation policy is included for the API.** For example, if an API has
> this policy attached to it, then for every invoke the system generates a
> transaction event.

Vérification mesurée : `GET /rest/apigateway/policies` liste une policy
**système, globale, nommée `GlobalLogInvocationPolicy`** (« Transaction
logging »), qui référence l'action `GlobalLogInvocationPolicyAction`
(templateKey `logInvocation`, stage `LMT`, `logGenerationFrequency: Always`
— donc conçue pour journaliser succès ET échecs). Cette policy système
était **`"active": false`** par défaut sur ce labo. C'est la cause unique et
suffisante du 0 document initial sur
`gateway_default_analytics_transactionalevents-*` : sans elle, aucune API
n'écrit jamais d'événement transactionnel, quel que soit le volume de
trafic.

Correction appliquée et vérifiée :
```
curl -sS -u Administrator:manage -H 'Accept: application/json' -X PUT \
  http://127.0.0.1:15555/rest/apigateway/policies/GlobalLogInvocationPolicy/activate
```
Après activation, du trafic réussi réel généré à travers le data-plane
(`carto-probe-app-active` : 35 appels, `carto-probe-app-low` : 9 appels,
`carto-probe-app-idle` : 0 appel) a bien produit des documents :
`gateway_default_analytics_transactionalevents-*` est passé de 0 à 47
documents, tous `"status": "SUCCESS"`, `"responseCode": "200"`, avec
`apiId` correctement renseigné et des volumes différenciés par
consommateur retrouvés dans l'agrégation (voir `aggregation-d90.json`).

Point annexe vérifié et écarté : les réglages de destination
(`configurations/gatewayDestinationConfig`,
`configurations/elasticsearchDestinationConfig`,
`configurations/desDestinationConfig`) n'exposent **aucune** bascule
`send*TransactionalEvent` (seuls `sendErrorEvent`, `sendPerformanceMetrics`,
`sendLifecycleEvent`, `sendPolicyViolationEvent`, et les `sendAuditlog*Event`
existent) — donc ce n'est pas un levier séparé pour ce type d'événement,
contrairement aux autres types. Le seul levier est la policy Log Invocation,
comme le dit la documentation. `PUT /apis/{apiId}/tracing/enable` (testé
également) est sans effet sur `transactionalevents` : il peuple
`gateway_default_mediatortracespan-*` et
`gateway_default_requestresponsetracespans-*` (traces d'appel brutes, avec
payloads, **sans champ `applicationId`**) — mécanisme différent, pas un
remplacement.

Mapping complet vérifié via
`GET /gateway_default_analytics_transactionalevents*/_mapping`.

Constantes retenues (mesurées, désormais sur l'index réellement conçu pour
cet usage) :
- `ES_INDEX` = `gateway_default_analytics_transactionalevents-*`
- `ES_API_FIELD` = `apiId`
- `ES_APP_FIELD` = `applicationId`
- `ES_TIME_FIELD` = `creationDate` (epoch millis)
- `ES_STATUS_FIELD` = `responseCode` (type `keyword`, chaîne à 3 chiffres —
  une comparaison lexicographique `gte "400"` fonctionne car tous les codes
  HTTP standards font 3 caractères, mais ce n'est pas un entier)

Différence de mapping notée entre index (à ne pas généraliser à tort) :
sur `errorevents`, `applicationId` est `text` + analyseur
`not_analyzed_ignorecase` (agrégation renvoie la valeur en minuscules) ;
sur `transactionalevents`, `applicationId` est `keyword` strict (agrégation
renvoie la casse d'origine, ex. `"Unknown"`). Les deux se comportent
correctement en `terms` agg, juste avec une casse différente.

## V4 — contact exploitable sur les Applications

Champ `contactEmails` existe dans le schéma (`Application.contactEmails`,
tableau de chaînes) mais est **vide (`[]`)** sur toutes les Applications
observées, y compris celles semées par cette tâche (nous ne l'avons pas
renseigné) et l'Application préexistante repérée sur ce labo avant notre
intervention. Conséquence : source externe nécessaire pour un contact
exploitable — laquelle n'est pas déterminée ici (pas d'annuaire
consommateurs disponible dans ce labo). À lever avec le client : LDAP
interne, CMDB, ou déclaratif au moment de l'enregistrement de l'Application.

## V5 — identification de l'appelant dans les événements

Le champ `applicationId` est-il toujours renseigné ? **Non — et après
correction du blocage V3, c'est maintenant vérifié sur du trafic réussi et
authentifié : `applicationId` vaut `"Unknown"` à 100 %, y compris pour des
appels 200 passés avec la clé API (`x-Gateway-APIKey`) d'une Application
déclarée consommatrice.** Ce n'est plus une limite de mesure (comme le
laissait penser l'ancienne hypothèse « pas d'événement de succès
disponible ») — **c'est un second problème, distinct et confirmé.**

Part d'événements sans appelant identifié : **100 % (47/47)** sur
`transactionalevents` après correction du blocage de journalisation, tous
succès confondus.

Ce qui a été tenté pour faire fonctionner l'identification par clé API,
dans l'ordre, chaque étape vérifiée par un appel réel suivi d'une lecture de
l'événement produit :
1. Policy `evaluatePolicy` (Identify & Authorize), `identificationType: apiKey`,
   `applicationLookup: relax` — `applicationId` reste `Unknown`.
2. En-tête confirmé exact par lecture de code (`config/resources/beans/
   gateway-core.xml`, `configurations/settings.extendedKeys.apiKeyHeader` =
   `x-Gateway-APIKey`) et vérifié réellement transmis (`curl -v`) — pas un
   problème de transport.
3. Clé API de l'Application re-vérifiée à jour (`GET /applications`,
   valeur courante de `accessTokens.apiAccessKey_credentials.apiAccessKey`)
   avant chaque test, Application bien déclarée consommatrice de l'API
   (`GET /applications/{id}/apis` confirme le lien).
4. `applicationLookup` basculé de `relax` à `strict` (« Registered
   applications », sémantiquement le bon choix ici) — pas de changement.
5. Scope de la policy globale élargi de « restreinte à `carto-probe-api` »
   à « aucune condition de scope » (toutes APIs REST) — pas de changement.
6. Policy désactivée puis réactivée pour forcer un recalcul de policy
   effective — pas de changement.
7. `order` d'enforcement explicite (`1`) au lieu de `null` sur le stage IAM
   — pas de changement.

Constat annexe : `GET /apis/{apiId}/globalPolicies` (censé lister les
policies globales actives applicables à une API) affiche
`["GlobalLogInvocationPolicy"]` mais **n'affiche jamais notre policy
personnalisée d'identification**, même active et sans condition de scope —
signe que cette policy n'est probablement pas correctement prise en compte
dans le pipeline effectif de l'API, sans qu'on ait pu établir pourquoi dans
le temps disponible (bug d'admin-endpoint qui ne liste que certains types de
policies système, ou policy réellement non appliquée : les deux hypothèses
restent ouvertes — la seconde est la plus probable puisqu'elle est cohérente
avec l'observation directe sur le trafic).

**Conclusion : l'identification de l'appelant par clé API ne fonctionne pas
dans ce labo, pour une cause non complètement diagnostiquée malgré une
investigation structurée (7 tentatives listées ci-dessus).** Ce n'est donc
plus seulement « à refaire » — c'est un vrai problème de fond à porter à
l'attention de l'équipe avant T2/T3 : **si ce comportement se reproduit chez
le client, la cartographie affichera 100 % du trafic sous un consommateur
« (non identifié) » et sera inutilisable pour répondre à « qui consomme
quoi ».** Recommandation : vérifier ce mécanisme en priorité sur un tenant
client réel (voire avec l'assistance du support Software AG), idéalement
avec un scénario d'authentification plus simple à auditer que `apiKey`
(par ex. HTTP Basic Auth avec les `identifiers` applicatifs, qui n'a pas été
testé ici faute de temps).

Conséquence pour le produit : tant que ce point n'est pas résolu, prévoir
dans l'UI un état « (non identifié) » comme cas *majoritaire attendu*, pas
comme cas résiduel.

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

ES_INDEX = "gateway_default_analytics_transactionalevents-*"
ES_API_FIELD = "apiId"
ES_APP_FIELD = "applicationId"   # mesuré "Unknown" à 100% ici — voir V5, préoccupation majeure
ES_TIME_FIELD = "creationDate"
ES_STATUS_FIELD = "responseCode"
```

Pré-requis d'exploitation à ne pas oublier chez le client (déduit de V3) :
**vérifier que la policy système `GlobalLogInvocationPolicy` (ou une policy
Log Invocation équivalente attachée à chaque API d'intérêt) est active**
avant de faire confiance à `transactionalevents` — sinon l'index reste vide
silencieusement, sans erreur, sans avertissement.

## Objets semés sur cette gateway de labo (à nettoyer)

Préfixe `carto-probe-` sur tout ce qui a été créé :

- API `carto-probe-api` v1.0.0, id `5ed95567-62e7-4a4e-a2da-441f0b276098`
  (backend : le même backend de test synthétique que l'API préexistante du
  labo, interne au cluster).
- Application `carto-probe-app-active`, id `4c329b2e-bcf7-45dc-996d-d5d9dfb538e0`
  (~35 appels réussis + quelques erreurs 405 générés).
- Application `carto-probe-app-low`, id `f06fa084-3745-4e6d-afac-98246b3c2757`
  (~9 appels réussis + 1 erreur 405 générés).
- Application `carto-probe-app-idle`, id `b168b889-f8e5-4ab2-bd11-bdf351942e8a`
  (déclarée consommatrice de `carto-probe-api`, **zéro appel émis** — cas
  central "déclaré sans trafic").
- Policy action `187e03ac-cf30-4bfb-9592-c7c568f8e73a` (Identify & Authorize,
  templateKey `evaluatePolicy`, apiKey, `allowAnonymous=true`, lookup
  `strict`) — n'a pas produit d'identification effective (voir V5).
- Policy globale `b37b96d2-4ac9-4868-a2e3-b1cbe951ab46` (initialement scopée
  à `carto-probe-api`, puis élargie à toutes APIs REST pendant le
  diagnostic), active.
- Policy service-scope orpheline `7287d306-62fb-48d6-a247-5e78dc76e20b`
  (créée puis non utilisée — remplacée par la policy globale ci-dessus ;
  peut être supprimée).
- Policy système `GlobalLogInvocationPolicy` : **activée par cette tâche**
  (`active: false` → `true`). ⚠ Ce changement est global à toute la gateway
  de labo (toutes les APIs présentes, pas seulement `carto-probe-api`) — à
  décider consciemment si on le laisse actif ou si on le redésactive lors du
  nettoyage, selon l'usage prévu du labo après cette tâche.

Suppression recommandée (ordre) : désactiver puis supprimer les 3
Applications, désactiver puis supprimer l'API, supprimer les 2 policies
custom et la policy action, via les mêmes chemins DELETE
(`/applications/{id}`, `/apis/{id}`, `/policies/{id}`, `/policyActions/{id}`).
Décider séparément du sort de `GlobalLogInvocationPolicy` (voir ci-dessus).
