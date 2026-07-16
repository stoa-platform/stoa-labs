# Pattern « convention de nommage » — VALIDÉ sur webMethods API Gateway 10.15 réel

Test exécuté le 2026-06-12 sur `poc-webmethods-real` (softwareag/apigateway-trial:10.15)
avec l'echo-server `echo.py` comme token-endpoint + backend (il logge ce qu'il reçoit,
donc on voit si la substitution a réellement eu lieu).

## Le pattern (zéro fichier de conf par provider)

```
Stage requestPayloadProcessing
  1. Invoke webMethods IS  (templateKey: requestInvokeESB)        ← ordre 1
       service tokenPoC.gateway:setCreds : lit apiName du pipeline (RequestSpec),
       lit le secret (passman/Vault) avec les clés dérivées <apiName>.user/.password,
       pose les variables de contexte mx:<apiName>_user / mx:<apiName>_password
       (pub.apigateway.ctxvar:declare+setContextVariable, MessageContext du pipeline)
  2. Custom Extension      (templateKey: customPolicy)            ← ordre 2
       callout POST <token-endpoint du provider>
       body LIBRE par API (form ou JSON), substitution : ${credspoc_user}, ${credspoc_password}
       Transformation : ${credspoc_token} ← ${response[customExtension].payload.jsonPath[$.access_token]}
Stage routing
  3. Custom HTTP Header    (templateKey: customHttpHeaders)
       Authorization = Bearer ${credspoc_token}
  4. Straight Through Routing → backend
```

Preuve (logs echo) : le token-endpoint a reçu
`{"api":"credspoc","u_sans_prefix":"POC-USER-credspoc","p_sans_prefix":"POC-PASS-credspoc","scope":"openid"}`
et le backend a reçu `Authorization: Bearer POC-TOKEN-OK-12345`.

## Découvertes empiriques (les pièges)

| # | Constat validé |
|---|---|
| 1 | Une ctxvar déclarée `mx:credspoc_user` se référence **`${credspoc_user}`** (SANS le préfixe mx:). `${mx:credspoc_user}` rend vide. |
| 2 | Les ctxvars posées en requestPayloadProcessing **survivent jusqu'au stage routing** (et au-delà, portée SESSION). |
| 3 | Dans `responsePayloadMap` (Transformation de la Custom Extension), les champs JSON sont **inversés vs l'intuition** : `responseFromCustomPolicyExpression` = la **Variable cible** (`${credspoc_token}`), `targetPayloadExpression` = la **Value source** (`${response[customExtension].payload.jsonPath[$.access_token]}`). C'était LE blocage du premier essai. |
| 4 | La Transformation de la Custom Extension assigne à une **variable custom**, PAS directement à un header. Le header se pose ensuite via **Custom HTTP Header** (stage routing, supporte le variable framework). Écrire `${request.headers.authorization}` comme cible ne fait rien. |
| 5 | Une variable non résolue **vide toute la valeur** du header (`Bearer ${inconnu}` → `""`, pas `"Bearer "`). Fail-silent : prévoir une alerte (le backend répondra 401). |
| 6 | Ordre d'exécution dans requestPayloadProcessing : Invoke IS (orderPosition first) **avant** Custom Extension — requis et confirmé. |
| 7 | Noms de variables : caractères de type identifiant Java — dériver `safe = apiName.replaceAll("[^A-Za-z0-9_]","_")` (un apiName `creds-poc` casserait). |
| 8 | templateKeys 10.15 : Invoke IS = `requestInvokeESB` (héritage « Invoke ESB » Mediator), Custom Extension = `customPolicy`, stage Request Processing = `requestPayloadProcessing`. Source : `packages/WmAPIGateway/config/resources/policy-store/`. |

## Viewer local (façon Designer, sans Eclipse)

`viewer.html` : arborescence du package + policies à gauche, à droite le code Java
colorisé, les propriétés de chaque policy (avec les pièges annotés) et le
**diagramme du flux runtime** hit/miss — ce que ni Designer ni l'UI gateway ne
montrent. Autonome, zéro dépendance :

```bash
cd gateways/webmethods/token-provider/poc-naming-convention
python3 -m http.server 8099     # puis ouvrir http://localhost:8099/viewer.html
```

## Designer local (vue Eclipse officielle)

**IBM webMethods Service Designer** — gratuit (IBMid seul, pas de licence),
**natif macOS Apple Silicon** (macOS 15 supporté depuis 11.1 R01) :
- 11.1 R03 (recommandé pour cibler du 10.15) : https://www.ibm.com/resources/mrs/assets?source=WMS_Designers
- 12.1 R01 (Java Semeru 21, namespace renommé — plus éloigné du 10.15) : https://www.ibm.com/resources/mrs/assets?source=WMS_Designer_v121

Install : `.dmg` → `/Applications/wMServiceDesigner` → `sudo ./setup.sh`.
Si crash Gatekeeper au lancement : `sudo xattr -r -d com.apple.quarantine
/Applications/wMServiceDesigner` (ou lancer via `designerc.sh`).

Interop officielle : Service Development 11.1 ↔ IS 10.7→11.1 / API Gateway
10.1→11.1 ; IBM a levé la restriction « développer en 11.1, pousser vers 10.15 »
(ne pas utiliser de features 11.1). Le Designer 10.15 ne sera jamais republié.

⚠️ La version gratuite ne se connecte qu'à son **runtime local embarqué** (pas
d'IS distant → pas le 5555 du gateway ; réservé au Designer complet licencié).
Contournement (le package est dans le repo) :

```bash
cp -r package/TokenPoC /Applications/wMServiceDesigner/IntegrationServer/packages/
# puis démarrer le Local Development Server depuis Designer
```

Boucle de travail : retoucher dans le Designer local → déployer vers le gateway
via la procédure jcode/packageActivate ci-dessous. (Aucune extension VS Code ni
viewer web officiel n'existe en 2026 — Eclipse ou le viewer.html ci-dessus.)

## Déploiement du package (testé)

```bash
docker cp package/TokenPoC <ct>:/opt/softwareag/IntegrationServer/instances/default/packages/
docker exec -u root <ct> chown -R sagadmin /opt/.../packages/TokenPoC
docker exec <ct> sh -c 'cd /opt/.../instances/default/bin && ./jcode.sh makeall TokenPoC'
curl -u Administrator:*** "http://host:5555/invoke/wm.server.packages/packageActivate?package=TokenPoC"
```
Le node.ndf du service a été cloné depuis `WmPublic ns/pub/math/addInts` (signature
métadonnée sans incidence) — en environnement réel, créer le service dans Designer.

## Provisioning des policies (testé, fichiers dans ./policies/)

```bash
# 1-3 : POST /rest/apigateway/policyActions  (un par fichier)
# 4   : PUT  /rest/apigateway/policies/{policyId}  (stages avec les ids retournés)
```

## Pattern v2 — cache + condition (VALIDÉ aussi, même banc)

Réponse au « pas de cache » : la Custom Extension devient **conditionnelle** et un
cache JVM côté IS fait le pont entre les requêtes (les variables custom/contexte ont
une portée TRANSACTION : elles ne survivent jamais d'une requête à l'autre — le pont
IS est donc obligatoire).

```
requestPayloadProcessing
  1. Invoke IS  tokenPoC.gateway:prepare
       cache hit  -> pose mx:<api>_token            (la condition verra non-vide)
       cache miss -> pose mx:<api>_user/_password   (_token déclaré => résout à "")
  2. Custom Extension (CONDITION : ${<api>_token} equals "")
       -> ne s'exécute QUE sur cache miss ; Transformation : ${<api>_token} ← jsonPath
routing
  3. Custom HTTP Header : Authorization = Bearer ${<api>_token}   (hit ou miss)
responseProcessing
  4. Invoke IS  tokenPoC.gateway:store
       lit mx:<api>_token via getContextVariable -> écrit cache JVM avec TTL
```

Preuve (logs) : 3 appels API → **1 seul** appel /token ; backend reçoit 3× le même
`Bearer POC-TOKEN-N001` ; séquence IS : `CACHE MISS` → `STORED via=ctxvar` →
`CACHE HIT` ×2.

Découvertes v2 :
- La condition s'encode `transformationConditions { logicalConnector, transformationCondition
  { transformationVariable: "${<api>_token}", operator: "equals", value: "" } }` —
  « variable non résolue → vide » (piège n°5) devient ici une FEATURE : pas
  d'opérateur "not exists" nécessaire.
- **Le store de variables est partagé** : une variable assignée par la Transformation
  de la Custom Extension (`${<api>_token}`) se relit en stage Response via
  `pub.apigateway.ctxvar:getContextVariable("mx:<api>_token")`. Transformation,
  variable framework et API ctxvar = le même contexte Mediator/Synapse.
- Reste à charge : **thundering herd** au démarrage à froid (N requêtes parallèles
  = N callouts, pas de single-flight possible côté policy) et TTL fixe côté IS
  (60 s dans la démo ; en réel, transporter expires_in dans une 2e variable).

## Seeder + observabilité (tests réguliers, debug sans toucher l'IS)

Services compose (overlay `docker-compose.wm.yml`) :
- **wm-token-echo** (`poc-token-echo`) : token-endpoint + backend de l'API credspoc.
  `/token` rend un jeton unique (`POC-TOKEN-Nxxx`), `/backend/fail` simule un 500.
- **wm-token-seeder** (`poc-wm-token-seeder`) : toutes les 60 s, sonde nominale
  (vérifie le `Bearer` reçu par le backend, logge le jeton → les rotations de
  cache se lisent dans les logs) ; 1 cycle sur 5, sonde d'erreur `GET /fail`
  (traverse toute la chaîne token → event FAILURE).

```bash
docker compose -f docker-compose.poc.yml -f docker-compose.wm.yml up -d wm-token-echo wm-token-seeder
docker logs -f poc-wm-token-seeder      # JSON-lines: ok/ko, token, rotations
```

Où débugger (jamais besoin de l'IS) :
| Signal | Où |
|---|---|
| OK/KO + rotation de jeton | `docker logs poc-wm-token-seeder` |
| Spans par appel (SUCCESS/FAILURE, code, durée) | Grafana → Tempo, service `webmethods` (via StoaTraceBridge, ADR-073) |
| Events bruts JSON | OpenSearch `txn-*` (branche Kafka→Data Prepper) |
| Headers req/resp d'un appel | events Transactional (storeRequest/ResponseHeaders=true) |
| Ce que le provider/backend a reçu (substitution, Bearer) | `docker logs poc-token-echo` |

Vérifié in-situ : event `Transactional credspoc/1.0 → span émis (status=FAILURE code=500)`
pour la sonde d'erreur ; `storeRequestPayload=false` sur la policy globale Log
Invocation → **le password du callout ne part jamais dans les events** (conforme
à la règle de capture du PoC).

Angles morts connus :
- Un 404 « ressource inconnue » ne produit PAS d'event Transactional (la requête
  ne matche pas de ressource) — il atterrit dans `gateway_default_analytics_errorevents`
  (ES du gateway), que le bridge ne polle pas (il ne polle que les PolicyViolation).
  D'où la sonde d'erreur en 500-backend plutôt qu'en 404. Extension possible du
  bridge : poller aussi `errorevents`.
- L'UI Analytics du gateway est quasi vide par design (destination = StoaTraceBridge
  uniquement, pas « API Gateway ») : le debug se fait dans Grafana/OpenSearch.
- Le callout de la Custom Extension n'émet pas de span dédié : il se déduit du
  span API (durée) + logs echo. En cas d'`abortInCaseOfFailure`, l'échec du
  callout devient un event FAILURE de l'API.

## Limites / arbitrage avec l'approche « package TokenProvider »

1. Le pattern v2 couvre le cache ; si on accepte d'écrire `store`+`prepare` en IS,
   l'**hybride** (le service fait aussi le fetch, avec single-flight + Vault,
   cf. ../src/) reste plus simple opérationnellement : 2 policies au lieu de 4,
   pas de course au démarrage. Le v2 garde l'avantage « body du token-call
   déclaratif dans la policy, promu par variables de substitution ».
2. **Le mot de passe transite par le variable framework** : visible dans le payload
   du callout (tracer/Log Invocation avec capture de payload = fuite). Désactiver la
   capture des payloads de custom extension sur ces APIs ; cf. règle monitoring du
   PoC (jamais le request body).
3. Body et URL du token-call vivent dans la config de la policy par API : c'est le
   but (promotion via variables de substitution d'environnement), mais ça fait N
   configs de policy à gérer — l'industrialisation par l'API admin REST (labctl-like)
   est quasi indispensable au-delà de quelques APIs.
