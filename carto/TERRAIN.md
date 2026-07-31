# Terrain mesuré — 2026-07-30, refondu le 2026-07-31

Gateway sondée : webMethods API Gateway 10.15 (cluster Kubernetes de labo).
Accès : REST `http://127.0.0.1:15555/rest/apigateway`
(`Accept: application/json` obligatoire, via tunnel local). Toutes les valeurs
ci-dessous sont mesurées, pas devinées.

> **Refonte du 2026-07-31 — ce qui a changé dans ce document.** La collecte du
> trafic interrogeait l'**Elasticsearch interne** de la gateway (API Data
> Store, port 9200). Elle passe désormais par l'**API publique de la gateway**,
> `GET /transactionalEvents/_count` et `/_search`. Les sections V2 et V3 sont
> réécrites en conséquence : le nom d'index, le motif d'étoile et les noms de
> champs Elasticsearch **sont sans objet** — il n'y a plus d'index à nommer ni
> de champ à deviner. La raison n'est pas esthétique : une NetworkPolicy du
> cluster n'ouvre cet Elasticsearch **qu'aux pods de la gateway**. Un agent de
> CI ne l'atteint pas, ni ici ni chez un client, où personne n'ouvre son API
> Data Store à un tiers. La refonte **supprime deux dépendances**
> (`WM_ES_URL`, `WM_ES_INDEX`) au lieu d'en ajouter.

**Identifiants** : les commandes ci-dessous lisent le compte d'administration
dans `$WM_USER` / `$WM_PASS` ; aucun identifiant n'est écrit dans ce dépôt,
qui est public. Le compte utilisé lors de la mesure était le compte
d'administration **par défaut du produit** sur un labo jetable — le nommer ici
reviendrait à publier une paire d'identifiants fonctionnelle. Pour rejouer :

```
export WM_USER='<compte lecture seule>' WM_PASS='<mot de passe>'
```

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
curl -sS -u "$WM_USER:$WM_PASS" -H 'Accept: application/json' \
  http://127.0.0.1:15555/rest/apigateway/applications
curl -sS -u "$WM_USER:$WM_PASS" -H 'Accept: application/json' \
  http://127.0.0.1:15555/rest/apigateway/apis
curl -sS -u "$WM_USER:$WM_PASS" -H 'Accept: application/json' \
  http://127.0.0.1:15555/rest/apigateway/apis/<apiId>
```

Conséquence : la date de création des Applications est disponible sans appel
supplémentaire (liste). Pour les APIs, un second appel par API (détail) est
nécessaire pour obtenir `creationDate` — à budgéter dans T2/T3 (N+1 appels).
Le champ n'est pas ABSENT au sens strict, mais son coût d'accès diffère selon
l'entité ; documenté pour éviter la surprise en T9.

## V2 — profondeur réellement couverte, sans agrégation `min`

**C'est le problème que la refonte a dû résoudre par elle-même.** La
profondeur couverte venait d'une agrégation `min` sur l'Elasticsearch. Cette
route disparaît, et la garantie qu'elle portait est centrale : *on n'affiche
jamais une profondeur qu'on n'a pas*, sinon on conclut « cette API n'a plus de
consommateur » à propos d'une API appelée hors fenêtre.

**Ce qui n'existe pas** dans l'API publique : aucune route d'agrégation sur
les événements. `POST /search/_aggregations` ne traite que les *assets* (API,
application, policy…) — vérifié, à ne pas re-tenter. Et `_search` n'accepte
**ni tri ni pagination profonde** : au-delà d'environ 10 000, `from` est
refusé (`using [from] is not allowed in a scroll context`), ce qui interdit le
raccourci « aller directement au dernier événement ».

**Ce qui marche, et qui est retenu** : une **recherche dichotomique sur la
borne haute**. La fonction « existe-t-il un événement entre `now - 90 j` et
`T` ? » est croissante en `T`, donc dichotomisable ; chaque sonde est un
`_count` dont la réponse est minuscule. Une vingtaine de requêtes suffit pour
encadrer le plus vieil événement **à la seconde**, puis une dernière page de
taille 1 dans cette tranche d'une seconde en donne l'horodatage exact. Le coût
est **constant** : il ne dépend ni du volume de trafic, ni du nombre d'APIs.

**Vérification croisée** (le point qui donne confiance dans la méthode) : la
dichotomie sur l'API publique et l'ancienne agrégation `min` sur
l'Elasticsearch rendent **la même valeur**, `2026-07-30T17:17:29.637Z`.

Cette profondeur-là reflète l'âge du labo et le moment où la journalisation a
été activée (voir V3), **pas** une rétention produit : aucune des profondeurs
mesurées ici n'est transposable au client. À re-mesurer sur un tenant qui
tourne depuis longtemps.

Limite honnête à connaître : ce qu'on établit est l'âge du **plus vieil
événement encore présent**, pas la politique de rétention déclarée. Un tenant
sans trafic ancien affichera une profondeur courte alors que sa rétention est
longue — c'est exactement ce qu'on veut (on n'annonce que ce qu'on a), mais il
ne faut pas lire `coveredDays` comme « rétention configurée ». Si la fenêtre
demandée ne contient **aucun** événement, la profondeur vaut 0 et
`oldestEvent` vaut `null` : inconnu, jamais inventé.

Ce qu'il ne faut jamais figer en dur, c'est la **profondeur annoncée** : le
collecteur demande une fenêtre longue de 90 jours (constante assumée, voir
`carto/collect/__main__.py`) mais **mesure** ce qu'il a réellement
(`window.coveredDays`) et n'affiche jamais que cette profondeur-là. Une option
qui aurait fait varier la fenêtre demandée sans faire varier les comptages a
existé (`--days`) : elle a été retirée en revue de branche, elle ne changeait
que l'étiquette.

## V3 — chemins publics, contrat des routes d'événements, et pourquoi rien n'était journalisé

Sources primaires (lues à la source, pas devinées) :
```
kubectl exec deploy/<gateway> -- ls \
  /opt/softwareag/IntegrationServer/instances/default/packages/WmAPIGateway/resources/apigatewayservices/
# → APIGatewayServiceManagement.json (APIs), APIGatewayApplication.json (Applications),
#   APIGatewayTransactionalEvent.json (/transactionalEvents/_count et /_search),
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

### Le contrat des deux routes d'événements (mesuré le 2026-07-31)

**Sans objet depuis la refonte : le nom d'index, le motif d'étoile et les
noms de champs Elasticsearch.** Ils ne sont plus une entrée de configuration
du produit — il n'y a plus d'index à nommer ni de champ à deviner. Ce qui
suit les remplace : le contrat réellement exposé par la gateway.

```
GET /rest/apigateway/transactionalEvents/_count
GET /rest/apigateway/transactionalEvents/_search
```
Identifiants en Basic, les mêmes que l'administration. Paramètres documentés
dans le Swagger : `apiName`, `apiVersion`, `apiId`, `applicationName`,
`applicationId`, `packageName`, `packageId`, `planName`, `planId`,
`fromDate`, `toDate` ; `_search` accepte en plus `from` et `size`.

**Dates.** `fromDate` et `toDate` sont **obligatoires** ; le Swagger annonce
`YYYY-MM-DD`, la forme `YYYY-MM-DD HH:MM:SS` est acceptée et filtre bien à la
seconde (vérifié : `toDate=2026-07-30 17:20:00` sur 48 événements en rend 27).
Les bornes sont interprétées dans le fuseau du serveur, **UTC** sur ce labo
(`date -u` dans le conteneur = `date`) ; le collecteur émet donc de l'UTC.

**Il faut au moins un filtre en plus des dates**, sinon la gateway refuse :
`{"errorDetails":" Insufficient parameters. …"}` (HTTP 400, le détail est
dans le corps — `carto/collect/gateway.py` le relit pour que l'exploitant
lise autre chose que « Bad Request »).

**PIÈGE MAJEUR — l'absence de résultat de `_count` est une CHAÎNE.**
Succès : `{"count":[{"apiId":"…","apiName":"…","apiVersion":"…","count":48}]}`.
Rien ne correspond : `{"count":" No records found."}`. Un code qui ferait
`for row in reponse["count"]` itérerait sur les **caractères** de cette
chaîne et fabriquerait une ligne de trafic par lettre. `_search`, lui, rend
bien une liste vide : `{"transaction":[]}`. Les deux formes sont capturées
telles quelles dans `carto/tests/fixtures/transactional-events.json`.

**`_count` regroupe par API.** Une requête filtrée sur une seule application
rend **une ligne par API** consommée par cette application. C'est ce qui rend
la collecte bon marché : une requête par application donne toutes ses arêtes,
y compris celles qui ne sont pas déclarées.

**Les filtres de nom sont des EXPRESSIONS RÉGULIÈRES ANCRÉES, insensibles à
la casse.** Le Swagger le dit à demi-mot (« regular expressions can be used
like `API_.*` »), la mesure le confirme : `apiName=carto.*` matche
`carto-probe-api`, `apiName=carto-probe` ne matche **rien** (ancrage),
`apiName=CARTO-PROBE-API` matche (casse ignorée), `apiName=*` est une regex
invalide et ne matche rien, `apiName=.*` matche tout. Conséquence
opérationnelle : **toute valeur qui doit valoir pour elle-même doit être
échappée** (`analytics.escape_regex`) — une application nommée `paie.v2`
matcherait sinon `paieXv2`, et une application nommée `a+` ne matcherait rien.
`.*` est aussi la seule façon d'obtenir « tout le trafic » puisque les dates
seules sont refusées.

**`applicationId` ne matche PAS la valeur que la gateway écrit.** Mesuré :
les événements portent `applicationId: "Unknown"` (V5), et pourtant
`applicationId=Unknown` rend `No records found`, alors que
`applicationName=Unknown` rend bien tout le trafic. Le point d'entrée met
apparemment la valeur en minuscules avant d'interroger un champ `keyword`
strict. **La dimension consommateur passe donc par le NOM d'application, pas
par l'identifiant** — et c'est le nom qui est remonté à l'identifiant via
l'inventaire. Corollaire porté par le code (`analytics.consumers_by_name`) :
deux applications homonymes à la casse près, une application sans nom, ou une
application nommée `Unknown`, rendent la dimension consommateur non fiable →
refus franc plutôt que double comptage ou usurpation.

**Le paramètre `status` n'est pas documenté mais filtre réellement — sur
`_count` seulement.** Mesuré : `status=SUCCESS` → 756 sur `accounts-read`,
`status=FAILURE` → 1, total → 757 ; `status=.*` → 757. C'est **la seule façon
bornée d'obtenir un taux d'erreur**, `_count` ne sachant pas compter les
échecs autrement. Deux précautions, toutes deux mesurées :
- un paramètre **inconnu est ignoré en silence** (`zzzbogus=nimportequoi` ne
  change rien au résultat). Si `status` disparaissait à une montée de version,
  les succès vaudraient le total et **toutes** les arêtes afficheraient
  `errorRate 0.0` sans un mot. D'où la sonde émise à chaque collecte
  (`analytics._sonde_du_filtre_statut`) : elle demande un statut impossible et
  refuse de publier s'il revient du trafic ;
- sur `_search`, `status` **casse la requête** : la réponse est
  `{"transaction":[]}` quel que soit le statut demandé, même `SUCCESS`. Ne
  jamais le passer à `_search`.

**`_search` rend les événements du plus récent au plus ancien** (vérifié sur
une page complète de 48). Une page `from=0&size=1` donne donc la date du
dernier appel d'une arête en **une** requête — c'est le seul endroit où le
collecteur lit un événement unitaire. Au-delà d'environ 10 000, `from` est
refusé (« using [from] is not allowed in a scroll context ») : la pagination
profonde n'est pas une option, ni pour remonter le trafic, ni pour atteindre
le plus vieil événement (voir V2).

**Forme d'un événement** (mesurée) : `apiId`, `apiName`, `apiVersion`,
`applicationId`, `applicationName`, `applicationIp`, `creationDate`,
`httpMethod`, `nativeURL`, `operationName`, `providerTime`, `responseCode`,
`serverID`, `status`, `totalDataSize`, `totalTime`, `callbackRequest`.
`creationDate` est un **entier en millisecondes** depuis l'époque (et non une
chaîne ISO comme le rendait l'agrégation Elasticsearch) ; `responseCode` est
une **chaîne** ; `status` vaut `SUCCESS` ou `FAILURE`.

Route à ne pas explorer : `POST /search/_aggregations` ne traite que les
*assets* (API, application, policy…), pas les événements. Vérifié, écarté.
`GET /apitransactions` est un **téléchargement d'archive** en masse, pas une
lecture analytique.

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
suffisante du 0 événement initial : sans elle, aucune API n'écrit jamais
d'événement transactionnel, quel que soit le volume de trafic. **Ce mode de
défaillance survit entièrement à la refonte** — il ne dépend pas de la façon
dont on lit les événements, mais du fait que la gateway les écrive. Il reste
donc le premier geste de diagnostic devant une carto où personne n'appelle
personne.

Correction appliquée et vérifiée :
```
curl -sS -u "$WM_USER:$WM_PASS" -H 'Accept: application/json' -X PUT \
  http://127.0.0.1:15555/rest/apigateway/policies/GlobalLogInvocationPolicy/activate
```
Après activation, du trafic réussi réel généré à travers le data-plane
(`carto-probe-app-active` : 39 appels au total sur toute la tâche,
`carto-probe-app-low` : 9 appels, `carto-probe-app-idle` : 0 appel) a bien
produit des événements : le comptage de `carto-probe-api` est passé de 0 à
48, tous `"status": "SUCCESS"`, `"responseCode": "200"`, avec `apiId`
correctement renseigné. Les volumes différenciés par consommateur (39 vs 9)
ne sont PAS retrouvés dans `applicationId` ni dans `applicationName` — voir
V5, qui explique pourquoi et ce qui a été fait à la place dans
`carto/tests/fixtures/observed.json`.

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
`gateway_default_mediatortracespan*` et
`gateway_default_requestresponsetracespans*` (traces d'appel brutes, avec
payloads, **sans champ `applicationId`**) — mécanisme différent, pas un
remplacement.

Mapping interne relevé à l'époque de l'accès direct
(`GET /gateway_default_analytics_transactionalevents*/_mapping`) — **conservé
uniquement comme explication**, plus comme dépendance : `applicationId` y est
un `keyword` strict alors que, sur `errorevents`, c'est un `text` analysé
`not_analyzed_ignorecase`. C'est très probablement ce qui explique que le
filtre public `applicationId=Unknown` ne matche rien tandis que
`applicationName=Unknown` matche tout (le point d'entrée met la valeur en
minuscules avant d'interroger). Le produit n'en dépend plus : il filtre par
nom d'application.

Le taux d'erreur ne se lit plus par une comparaison `range` sur
`responseCode` (qui était **lexicographique**, ce champ étant un `keyword`, et
n'avait pu être exercée qu'avec un seul code — `"200"`, 48/48). Il se déduit
désormais d'un comptage : `erreurs = total − total(status=SUCCESS)`, deux
`_count` par API et par application sur la fenêtre longue. Cette définition ne
dépend d'aucune convention de codage ni d'aucun ordre lexicographique, et
reste juste si la gateway introduit d'autres valeurs de `status` que
`SUCCESS` / `FAILURE`.

Réserve à porter au client, inchangée par la refonte : l'échantillon du labo
ne contient presque pas d'échecs (1 sur 805 événements toutes APIs
confondues), et les erreurs `405` produites pendant T0 ne sont **jamais**
arrivées jusqu'aux événements transactionnels. Le taux d'erreur du produit est
donc structurellement correct mais **très peu exercé** : à reconfirmer sur un
tenant qui produit réellement des `4xx`/`5xx`.

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

Part d'événements sans appelant identifié : **100 % (48/48)** sur
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

**Deuxième passe, sur demande explicite : chercher un gabarit qui marche
déjà sur le catalogue plutôt que de continuer à deviner une configuration.**
8. Inventaire complet des policies du labo (`GET /policies`) : seulement 5
   au total. `accounts-read` (l'API antérieure à notre passage) porte
   `Default Policy for API accounts-read` (id `b15a72e9-...`), qui n'a que
   les stages `transport` (Enable HTTP/HTTPS) et `routing` (Straight
   Through Routing) — **aucun stage `IAM`, donc aucune identification**.
   C'est exactement la même forme que la policy par défaut de
   `carto-probe-api`. **Aucune des deux APIs du catalogue ne porte de
   policy d'identification préexistante à copier** — les deux seules
   policies au stage `IAM` de tout le labo sont celles que nous avons
   créées nous-mêmes. Il n'existe donc pas de gabarit "self-service" à
   reproduire sur cette gateway ; ce n'est pas qu'on ne l'a pas trouvé, il
   n'y en a pas.
9. Association Application↔API dans les deux sens : `GET
   /applications/{id}/apis` (déjà fait) **et** `GET /apis/{apiId}/applications`
   (sens inverse), les deux confirment que les 3 Applications
   `carto-probe-*` sont bien associées à `carto-probe-api`
   (`consumingAPIs` contient l'id de l'API des deux côtés). Ce n'est donc
   pas un défaut d'association clé↔API.
10. `carto-probe-api` elle-même désactivée puis réactivée (`PUT
    /apis/{apiId}/deactivate` puis `/activate`, pas seulement la policy)
    pour forcer le recalcul de son jeu de policies effectif — nouvel appel
    réel avec clé API valide juste après : **`applicationId` toujours
    `Unknown`**.

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

**Conclusion, après deux passes d'investigation (10 tentatives/vérifications
au total, dont la comparaison avec le seul autre API du catalogue) :
l'identification de l'appelant par clé API ne fonctionne pas dans ce labo,
pour une cause structurelle non complètement diagnostiquée — et il n'existe
aucun gabarit fonctionnel dans ce catalogue pour la débloquer.** Ce n'est
plus « à refaire » — c'est un vrai problème de fond à porter à l'attention
de l'équipe avant T2/T3 : **si ce comportement se reproduit chez le client,
la cartographie affichera 100 % du trafic sous un consommateur « (non
identifié) » et sera inutilisable pour répondre à « qui consomme quoi ».**
Recommandation : vérifier ce mécanisme **en priorité** sur un tenant client
réel (voire avec l'assistance du support Software AG), idéalement avec un
scénario d'authentification plus simple à auditer que `apiKey` (par ex.
HTTP Basic Auth avec les `identifiers` applicatifs, qui n'a pas été testé
ici faute de temps).

**Re-vérifié le 2026-07-31, après la refonte : rien n'a changé, et on sait
maintenant que ce n'était pas un artefact de la façon de lire.** L'API
publique confirme la même chose que l'Elasticsearch : `applicationName=Unknown`
compte **tout** le trafic (805 événements sur 805, toutes APIs confondues),
et aucune des applications enregistrées ne remonte le moindre appel. La
collecte réelle sort donc `trafic_non_identifie=100.0%`. Le changement de
route n'était pas une piste de résolution de V5 et ne prétend pas l'être.

**Décision prise sur ce point (arrêt de l'investigation, cf. consigne) :**
la substitution documentée est **toujours nécessaire** et a été reconduite sur
la nouvelle forme de fixture. `carto/tests/fixtures/observed.json` conserve les
volumes et horodatages mesurés mais **substitue** les deux identifiants de
consommateur des arêtes de `carto-probe-api` : la gateway avait réellement
renseigné `Unknown` pour les 48 événements ; ces valeurs ont été remplacées par
les identifiants réels de `carto-probe-app-active` (39 appels réels) et
`carto-probe-app-low` (9 appels réels), reconstruits à partir du journal des
appels de T0 (chaque lot ciblait une clé précise, retrouvable via le motif de
l'URL native — la gateway elle-même ne fait pas cette distinction).
`carto-probe-app-idle` (zéro appel) n'apparaît dans aucune arête observée, ce
qui est la forme correcte : un consommateur silencieux ne peut structurellement
pas apparaître dans un comptage d'événements, c'est la jointure déclaré×observé
qui doit le révéler. La ligne de l'API `accounts-read` (757 appels, 1 erreur)
est en revanche laissée **telle que la gateway la rend**, portée par le
consommateur fantôme `Unknown` : la fixture exerce ainsi les deux cas à la
fois, et affiche ~94 % de trafic non identifié. **Le fichier porte en tête
(`_meta`) un avertissement explicite qui distingue ce qui est mesuré de ce qui
est substitué — ne pas retirer cet avertissement en aval.** Les formes brutes
des deux routes, elles, sont capturées sans aucune retouche dans
`carto/tests/fixtures/transactional-events.json`.

Conséquence pour le produit : tant que ce point n'est pas résolu, prévoir
dans l'UI un état « (non identifié) » comme cas *majoritaire attendu*, pas
comme cas résiduel. Depuis la refonte, ce trafic n'est plus lu comme une
valeur d'agrégation mais calculé comme un **résidu** : volume total de l'API,
moins la somme de ses applications identifiées. Les deux lectures se
recoupent exactement sur ce labo, et le résidu a l'avantage de rester juste
même si la gateway écrivait un jour autre chose que `Unknown`.

## V7 — coût de la collecte, et le risque qu'on n'a pas pu mesurer

Stratégie retenue (elle n'énumère **aucun** événement pour mesurer un
volume) :

1. un `_count` par **application** et par fenêtre — la réponse étant déjà
   regroupée par API, une requête donne toutes les arêtes de cette
   application, **y compris celles qui ne sont pas déclarées** ;
2. un `_count` par **API** et par fenêtre — le volume total de l'API ;
3. le trafic non attribué d'une API = son total moins la somme de ses
   applications. **Résidu calculé, sans énumérer un seul événement.**

Coût mesuré sur le labo (3 APIs, 6 applications, 805 événements) : **~70
requêtes, 8 secondes**, dont ~26 pour la seule profondeur couverte (V2). La
formule est bornée par la configuration :

```
3 x (nb_apis + nb_applications)   volumes des trois fenêtres
+   (nb_apis + nb_applications)   volumes en succès (fenêtre longue seule)
+   nb_arêtes_observées           date du dernier appel (_search size=1)
+   ~26                           profondeur réellement couverte
+   1                             sonde du paramètre `status`
```

Rien là-dedans ne dépend du volume de trafic : c'est la propriété qui rend le
job tenable chez un client à des millions d'appels, et elle est **testée**
(`test_le_cout_de_la_collecte_ne_depend_pas_du_volume_de_trafic`).

Pourquoi un `_count` par API plutôt qu'un seul `apiName=.*` : parce que le
second économiserait `3 x nb_apis` requêtes au prix d'un risque non mesuré,
détaillé juste en dessous.

### Le risque non mesuré : le plafond de regroupement de `_count`

`_count` renvoie **une ligne par API**. Ce regroupement a très probablement un
plafond côté gateway (une agrégation `terms` a toujours une taille). **Ce
labo n'a que 3 APIs, dont 2 avec du trafic : impossible de le mesurer ici.**

Conséquence si le plafond existait et était franchi chez un client : les
requêtes par **application** perdraient des lignes, et le trafic concerné
basculerait en silence dans le **résidu** — c'est-à-dire dans « trafic non
identifié ». La carto ne deviendrait donc pas fausse dans le sens dangereux
(elle n'affirmerait pas qu'une API est morte), mais elle sous-estimerait la
dimension consommateur en la déclarant inconnue. Deux garde-fous existent
déjà : les requêtes par **API** portent un `apiId` et ne rendent qu'une
ligne (aucun regroupement à tronquer, donc les volumes totaux restent justes),
et un résidu anormalement élevé est déjà porté au contrat de données par
`unidentifiedCallShare`, avec alerte du rendu au-delà de 50 %.

**À mesurer en priorité chez le client, sur un tenant à plusieurs dizaines
d'APIs** : émettre `_count?applicationName=.*&fromDate=…&toDate=…` et compter
les lignes rendues. Si ce nombre plafonne sur une valeur ronde (10, 100,
1 000) alors que le catalogue est plus grand, le plafond existe — et il faut
alors passer les requêtes par application à une granularité `apiId` explicite
(coût : `nb_apis x nb_applications`, à arbitrer).

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

# Trafic — API PUBLIQUE de la gateway, plus aucun accès à l'Elasticsearch
# interne. Les anciennes constantes ES_INDEX / ES_API_FIELD / ES_APP_FIELD /
# ES_TIME_FIELD / ES_STATUS_FIELD sont SANS OBJET (voir V3).
COUNT_PATH  = "/transactionalEvents/_count"    # groupé par API ; " No records found." = CHAÎNE
SEARCH_PATH = "/transactionalEvents/_search"   # ordre décroissant ; jamais avec `status`
DATE_FORMAT = "%Y-%m-%d %H:%M:%S"              # UTC ; fromDate ET toDate obligatoires
MATCH_ALL   = ".*"                             # les filtres de nom sont des regex ANCRÉES
STATUS_PARAM = "status"                        # non documenté mais filtre — sondé à chaque collecte
UNIDENTIFIED_CONSUMER_ID = "Unknown"           # ce que la gateway écrit faute d'identification (V5)
```

**Question ouverte à vérifier en priorité absolue chez le client, avant
toute promesse sur la dimension consommateur du produit** (voir V5) :
*l'identification de l'application appelante est-elle effective dans les
événements transactionnels de LEUR gateway ?* Si non, la cartographie
observée (par opposition à la cartographie déclarée) n'a pas de dimension
consommateur exploitable, quel que soit le reste du pipeline de collecte.
La refonte du 2026-07-31 ne l'a pas levée : elle l'a **re-vérifiée par une
autre route et confirmée**. Le filtre à interroger chez eux est
`applicationName` (mesuré fonctionnel), pas `applicationId` (mesuré
inopérant sur la valeur réellement écrite).

Pré-requis d'exploitation à ne pas oublier chez le client (déduit de V3) :
**vérifier que la policy système `GlobalLogInvocationPolicy` (ou une policy
Log Invocation équivalente attachée à chaque API d'intérêt) est active**
avant de faire confiance aux événements transactionnels — sinon la gateway
n'en écrit aucun, silencieusement, sans erreur, sans avertissement.

## Objets semés sur cette gateway de labo (à nettoyer)

Préfixe `carto-probe-` sur tout ce qui a été créé :

- API `carto-probe-api` v1.0.0, id `5ed95567-62e7-4a4e-a2da-441f0b276098`
  (backend : le même backend de test synthétique que l'API préexistante du
  labo, interne au cluster).
- Application `carto-probe-app-active`, id `4c329b2e-bcf7-45dc-996d-d5d9dfb538e0`
  (39 appels réussis + quelques erreurs 405 générés).
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
