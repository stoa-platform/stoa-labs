# TokenProvider — acquisition de jetons body-based pour webMethods API Gateway 10.15

Package Integration Server générique répondant au gap 10.15 : un backend exige
user/password (ou client_id/secret) **dans le body** d'un appel de récupération
de jeton, et aucun mécanisme natif (alias, outbound auth) ne permet de stocker
ce secret de façon chiffrée ni d'aller chercher le jeton dynamiquement —
confirmé sur docs IBM 10.15 et inchangé en 11.1 côté API Gateway.

**Principe : un seul package, zéro code par provider.** Chaque provider est un
fichier JSON (`config/profiles/<nom>.json`) qui décrit l'appel de jeton (URL
templatée, body templaté form/JSON, scopes, realm…), où trouver les
credentials dans Vault, comment extraire le jeton de la réponse et comment
l'injecter. Ajouter un provider = déposer un profil + écrire le secret dans
Vault + 2 policies sur l'API. Voir `config/provider.schema.json` et les trois
exemples contrastés :

| Profil | Pattern couvert |
|---|---|
| `keycloak-ropc.example.json` | grant password form-urlencoded, realm dans l'URL, scope |
| `legacy-json-login.example.json` | login JSON propriétaire, jeton dans `data.jwt`, TTL fixe |
| `oauth2-client-credentials.example.json` | la cible saine post-challenge backend : client_credentials + Basic auth |

## Architecture

```
Consommateur ──▶ API Gateway 10.15 (tourne sur un IS)
                  │ Request Processing
                  │  1. Request Transformation : pose X-Token-Profile: <profil>   (ÉCRASE toujours)
                  │  2. Invoke webMethods IS  : tokenProvider.gateway:injectAuthHeader
                  │       │
                  │       ▼ (classes wm.tokenprovider, même JVM)
                  │     TokenCache (par profil, single-flight, renouvellement à 80% du TTL)
                  │       └─ TokenService : Vault (creds) + template → POST endpoint de jeton
                  │            └─ VaultClient : AppRole (secret-zero dans l'outbound password store)
                  │     → pose Authorization: Bearer xxx, retire X-Token-Profile
                  │ Routing ──▶ Backend (JWT)
                  │ Response Processing (optionnel)
                  │  3. Invoke webMethods IS : tokenProvider.gateway:onBackendResponse
                  │     → si 401 : invalide le cache du profil (rotation/révocation)
```

Les secrets ne sont **jamais** : dans un alias gateway, dans la config d'une
policy, dans un fichier du package, dans les logs ou les messages d'erreur.
Seul secret local : le `secret_id` AppRole, dans l'outbound password store de
l'IS (chiffré passman, services `pub.security.outboundPasswords:*` — store
supporté par l'éditeur pour des secrets custom).

## Installation

1. **Créer le package IS** `TokenProvider` sur l'IS de la gateway (la policy
   *Invoke webMethods IS* n'invoque que des services **locaux** — contrainte
   documentée 10.15/11.1).
2. **Copier les sources** `src/wm/tokenprovider/*.java` dans
   `packages/TokenProvider/code/source/wm/tokenprovider/` puis compiler avec
   `instances/<instance>/bin/jcode.sh makeall TokenProvider` (variable
   `IS_DIR` exportée ; sur Microservices Runtime le script est directement
   sous `bin/`) — ou : Designer → code partagé. Les `com.wm.*` sont fournis
   par l'IS ; hors IS, compiler contre `wm-isclient.jar` pour les tests
   unitaires.
3. **Créer 3 services Java** dans Designer (folder `tokenProvider.gateway` et
   `tokenProvider.admin`), corps d'une ligne :
   - `tokenProvider.gateway:injectAuthHeader` → `wm.tokenprovider.GatewayAdapter.injectAuthHeader(pipeline);`
   - `tokenProvider.gateway:onBackendResponse` → `wm.tokenprovider.GatewayAdapter.onBackendResponse(pipeline);`
   - `tokenProvider.admin:reload` → `wm.tokenprovider.GatewayAdapter.reload(pipeline);`
4. **ACL : Internal** (ou ACL dédiée) sur ces services — ils ne doivent pas
   être invocables via `/invoke` par un consommateur. La policy gateway les
   exécute via *Run as User*.
5. **Config** : déposer `config/vault.json` (depuis l'exemple) et
   `config/profiles/<nom>.json` dans `packages/TokenProvider/config/`.
6. **Secret-zero** : stocker `role_id`/`secret_id` AppRole dans l'outbound
   password store (clés `tokenprovider.vault.roleid` / `.secretid`) via un
   petit flow d'init appelant `pub.security.outboundPasswords:setPassword`,
   exécuté une fois par environnement puis supprimé — jamais de valeur en git.
7. **Audit/logs** : sur les services `tokenProvider.*` : audit *Include
   pipeline = Never*, pas de *pipeline debug* en prod
   (`watt.server.pipeline.processor`), pas de savePipeline.

## Câblage d'une API dans API Gateway

Stage **Request Processing** :
1. *Request Transformation* → Header/Query/Path Transformation → section
   **Add/Modify** : Variable `X-Token-Profile`, Value `legacy-json-login`
   (ou `${tokenProfileAlias}`).
   ⚠️ « Modify » remplace la valeur d'un header entrant de même nom —
   **vérifier ce comportement en recette** (la doc 10.15 ne l'énonce pas
   formellement) : un consommateur ne doit jamais pouvoir choisir le profil
   lui-même (vol de jeton inter-API). Défense en profondeur côté code : le
   header est retiré avant routage (doublons compris) et seuls les profils
   déclarés dans `config/profiles/` existent.
2. *Invoke webMethods IS* → service `tokenProvider.gateway:injectAuthHeader`,
   **Comply to IS Spec = true** (spec
   `pub.apigateway.invokeISService.specifications:RequestSpec`), *Run as User*
   dédié.

Stage **Response Processing** (optionnel mais recommandé) :
3. *Invoke webMethods IS* → `tokenProvider.gateway:onBackendResponse` :
   invalide jeton **et** secret Vault du profil si le backend répond 401
   (jeton révoqué, credentials tournés) — l'appel suivant repart à neuf.
   Le profil transite du stage Request au stage Response via une variable de
   contexte API Gateway (`pub.apigateway.ctxvar:*`, variable
   `mx:TOKEN_PROVIDER_PROFILE`, portée SESSION documentée).

### Généricité et variables de substitution

- **Le dev est unique** : mêmes services, mêmes policies pour toutes les APIs ;
  seule la valeur de `X-Token-Profile` change par API.
- **Par environnement**, deux approches cumulables :
  - valeur du header via un **alias simple** `${tokenProfileAlias}` (la
    substitution `${alias}` fonctionne dans le variable framework depuis la
    10.7), valeurs d'alias différentes par stage lors de la promotion ;
  - **nom de profil stable** et contenu du fichier de profil différent par
    environnement (URL, realm, vaultPath) — recommandé : le profil est déployé
    avec le package par la CI, l'alias ne porte alors plus rien de variable.
- Industrialisation : les policies se posent par l'API admin REST
  (`/rest/apigateway/policyActions`, `/policies`) — même pattern que le
  provisioning `labctl` de ce PoC.

## Côté Vault

- Un secret par backend : `secret/data/apigw/backends/<backend>` (KV v2),
  champs libres (`username`/`password`, `client_id`/`client_secret`…) mappés
  par `secrets.map` du profil.
- AppRole dédié à la gateway, policy en lecture seule sur
  `secret/data/apigw/backends/*`, par environnement.
- Rotation : mettre à jour le secret dans Vault suffit — cache secrets ≤ 5 min
  + invalidation sur 401 ; aucune reconfiguration gateway.
- TLS : le certificat de Vault doit être dans le truststore de l'IS
  (`pub.client:http` utilise la configuration JSSE de l'IS).

## Limites connues / TODO

- `response.tokenPath` : chemin pointé simple, pas de tableaux ni JSONPath.
- L'invalidation sur 401 ne **rejoue pas** l'appel courant (le stage Response
  de 10.15 ne permet pas de re-router) : le consommateur peut voir un 401
  isolé après une rotation, l'appel suivant repart. Le `refreshSkewPercent`
  à 80 % rend le cas rare.
- Cache par nœud JVM (pas Terracotta) : en cluster, au pire un jeton par
  profil et par nœud — acceptable, documenté.
- `pub.cache` n'est volontairement pas utilisé : pas de TTL par entrée en
  10.15 (TTL au niveau cache dans IS Administrator), un
  `ConcurrentHashMap` + skew est plus précis et sans licence Terracotta.
- Migration 11.1+/12.1 : remplacer `VaultClient` par les built-ins
  `pub.vault:*` (intégration Vault native **côté IS** ; rien ne change côté
  API Gateway, qui n'a toujours pas d'acquisition de jeton outbound native).
  Attention : la bascule passman→Vault native est irréversible et l'IS ne
  démarre plus si le Vault primaire est injoignable.

## Test local (PoC)

Le profil `keycloak-ropc.example.json` pointe vers le Keycloak du PoC
(`realm stoa-lab`, cf. `identity/keycloak/realm-stoa-lab.json` et
`docker-compose.wm.yml`) : créer un user de service dans le realm, écrire le
secret dans le Vault du lab, déployer le package sur le conteneur webMethods
et câbler les 3 policies sur une API de test.
