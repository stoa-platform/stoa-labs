---
title: "ADR-077 — Identité UTILISATEUR de bout en bout jusqu'à Vault : token exchange standard (RFC 8693) Keycloak → auth JWT Vault, zéro credential stocké côté CI"
sidebar_label: "ADR-077 : identité utilisateur → Vault (token exchange)"
status: "Proposé — réponse à une contrainte IT client (« un utilisateur se connecte au Vault, pas une application »)"
maturite_technique: "✅ Livré & prouvé — chaîne complète alice → exchange → Vault → job Jenkins, ségrégation PAR TENANT enforcée (scripts/test-user-vault-jwt.sh 24/24 live 2026-07-05 après durcissement post-review adversariale) ; nécessite Keycloak ≥ 26.2 (bump 26.1.4 → 26.3.4 effectué)"
date: 2026-07-05
adr_number: 77
visibility: private
note: "Privé (stoa-labs). S'appuie sur ADR-074 (secrets Vault), ADR-075 (chaîne multi-env), ADR-076 (GitOps lifecycle). Contexte client bancaire — ne pas porter dans stoa-docs (public)."
---

# ADR-077 — Identité utilisateur de bout en bout jusqu'à Vault (token exchange)

**Statut :** Proposé — réponse d'architecture à une contrainte IT client.
**Maturité technique :** ✅ Livré & prouvé (2026-07-05) — `scripts/test-user-vault-jwt.sh` **24/24 live** (après durcissement issu d'une review adversariale), dont contre-épreuves : token non échangé refusé (`bound_audiences` + `azp`), subject token non adressé refusé par Keycloak, rôle realm insuffisant refusé par Vault, **cross-tenant refusé** (policy templatée), webhook sans jeton → build rouge, audit nominatif scopé au run — refus compris.
**Contexte client (anonymisé) :** banque — l'équipe IT **exige que ce soit un utilisateur (humain) qui se connecte au Vault, et non une application** (AppRole/service account refusés), tout en voulant des jobs Jenkins non interactifs. Contrainte prise au pied de la lettre et satisfaite *sans* stocker le moindre mot de passe.
**Lié à :** [[adr-074-vault-secrets]], [[adr-075-wm-admin-proxy-multienv]], [[adr-076-gitops-api-lifecycle-repo-per-project]].

> ⚠️ **Confidentialité.** Modèle d'authentification secrets d'une banque. Vit dans `stoa-labs` (privé), **pas** dans `stoa-docs`.

---

## Décision (test « archi 40 ans / 30 secondes »)

> L'identité qui s'authentifie auprès de Vault est **l'utilisateur humain**, propagée depuis sa session Keycloak par **token exchange standard (RFC 8693)** : le token console (adressé `aud=vault-exchange`) est échangé par un client confidentiel contre un **JWT court (5 min) `aud=vault`, `sub=utilisateur`, `tenant=<son tenant>`, `azp=vault-exchange`** ; le job CI le présente à `auth/jwt/login` et obtient un **token Vault nominatif ET tenant-scopé** (entité = l'utilisateur, TTL 10 min, policy **templatée par tenant** — un tenant-admin de `banking-demo` ne lit pas `payments-team`), révoqué en fin de build **avec preuve de mort** (`lookup-self` → 403). **Zéro credential côté chaîne CI** : pas de mot de passe dans Jenkins, pas d'AppRole, pas de token longue durée — le job CI ne détient *aucun* credential propre.
> **Test** : *peut-on déployer sans qu'un humain identifié ait déclenché, et un secret réutilisable **permettant à lui seul de déployer** traîne-t-il quelque part (Jenkins, Git, disque) ?* Si l'une des réponses n'est pas « non, mécaniquement », la contrainte IT n'est pas satisfaite — elle est contournée.

---

## Contexte et problème

La contrainte « utilisateur, pas application » est un anti-pattern si on l'implémente naïvement (mot de passe personnel posé dans le credentials store Jenkins : rotation AD qui casse les builds, départ du collaborateur, non-répudiation floue, et violation probable de la PSSI du client elle-même). Les réponses classiques :

1. **Compte de service annuaire (LDAP)** — requalification habituelle de la contrainte ; refusée ici (l'IT veut un humain).
2. **Token Vault périodique créé par l'utilisateur** (login interactif une fois, token orphelin `period=72h` stocké dans Jenkins, renouvelé par les jobs) — plan B honnête : nominatif au sens de l'audit, survit à la rotation AD, mais un secret longue durée vit dans Jenkins et la révocation au départ est procédurale.
3. **Identité portée par le push Git** (GitLab CI `id_tokens` : claims `user_login`/`user_email` du déclencheur, validés par Vault `jwt`) — équivalent « au push », mais l'émetteur de confiance est le serveur Git, pas la session OAuth de l'utilisateur ; non retenu ici (Gitea du PoC n'émet pas d'ID tokens CI ; à réévaluer selon le Git du client).
4. **★ Chaîne A (retenue)** : session utilisateur → **token exchange** → JWT court `aud=vault` → webhook CI → `auth/jwt/login` → token Vault **nominatif**. C'est *littéralement* un utilisateur qui se connecte au Vault — en mieux audité (la délégation `azp=vault-exchange` est tracée), et **zéro secret stocké**.

Conséquence assumée de la chaîne A : **pas d'action humaine = pas de déploiement** (un re-run après expiration du JWT exige un re-déclenchement). Dans le modèle de gouvernance du PoC (4-yeux, gate ITSM — ADR-075/076), c'est une *propriété*, pas un défaut. Les jobs planifiés/automatiques, eux, resteront sur une identité non-humaine (ADR-074) : la contrainte IT ne peut pas les couvrir.

## Décision retenue

### 1. Keycloak (26.3.4 — le token exchange standard est GA depuis 26.2)

Déclaré dans `identity/keycloak/realm-stoa-lab.json` (survit aux recreate — le realm est éphémère `start-dev --import-realm`) :

| Objet | Rôle |
|---|---|
| client `vault-exchange` (confidentiel, `standard.token.exchange.enabled=true`, aucun flow, aucun service account) | l'échangeur : seul habilité à convertir un token utilisateur en JWT `aud=vault` |
| mapper `tenant-attribute` sur `vault-exchange` | le JWT échangé porte le claim **`tenant`** de l'utilisateur — la ségrégation voyage avec l'identité (alimente la policy Vault templatée) |
| client `vault` (client-ressource, aucun flow) | cible d'audience de l'exchange |
| mapper `vault-exchange-audience` sur `console-light` **et** `stoa-portal` | **adresse** le token utilisateur à l'échangeur (`aud` ∋ `vault-exchange`) — l'exchange standard refuse un subject token non adressé au client demandeur |

Dynamique (dans `scripts/setup-user-vault-jwt.sh`, car **déclarer `clientScopes` dans le realm JSON supprimerait la création des scopes built-in à l'import**) : client scope `vault-aud` (audience mapper → `vault`) attaché en scope par défaut de `vault-exchange` — sans lui, KC répond `Requested audience not available: vault`.

L'exchange (celui que fera la governance-api au clic « déployer », avec le Bearer de l'approbateur qu'elle détient déjà) :

```
POST /realms/stoa-lab/protocol/openid-connect/token
  grant_type=urn:ietf:params:oauth:grant-type:token-exchange
  client_id=vault-exchange  client_secret=***
  subject_token=<token console de l'utilisateur>
  subject_token_type=urn:ietf:params:oauth:token-type:access_token
  audience=vault
→ JWT 300 s : iss=http://localhost:8480/realms/stoa-lab, sub=<user>,
  preferred_username=alice@bc.example, aud=vault, azp=vault-exchange, realm_access.roles=[…]
```

### 2. Vault (`scripts/setup-user-vault-jwt.sh`, idempotent)

- auth method **`jwt`**, config **split-horizon** (même modèle que les gateways) : `jwks_url=http://keycloak:8080/…/certs` (fetch réseau compose), `bound_issuer=http://localhost:8480/realms/stoa-lab` (issuer épinglé des tokens) ;
- rôle `user-deploy` : `bound_audiences=vault` **et `bound_claims azp=vault-exchange`** (défense en profondeur : Vault re-verrouille que le jeton vient de l'échangeur, indépendamment de la config des scopes Keycloak), **`user_claim=preferred_username`** (l'entité Vault EST l'utilisateur), `claim_mappings` (`username`, `exchanged_by=azp`, **`tenant`** → metadata de l'alias — la délégation ET le tenant apparaissent dans l'audit), **`bound_claims /realm_access/roles ∩ {tenant-admin, devops, cpi-admin} ≠ ∅`** (sémantique Vault *any-of* : au moins un de ces rôles ; un `viewer` est refusé), `token_ttl=600` ;
- policy `user-deploy` **templatée par tenant** : READ `secret/stoa/deploy/{{identity.entity.aliases.<accessor jwt>.metadata.tenant}}/*` uniquement — **ségrégation par tenant enforcée** (alice/`banking-demo` → `deploy/payments-team` = 403) et l'utilisateur ne devient pas root. Conséquence assumée : un utilisateur **sans** attribut `tenant` (dave/cpi-admin = tous tenants) est refusé au login (`claim_mappings` exige le claim) — la chaîne A est un canal de déploiement *tenant-scopé*, l'admin plateforme passe par sa propre policy (delta prod) ;
- **audit device file** : chaque login (succès **et** refus) est journalisé `display_name=jwt-alice@bc.example` + metadata — la traçabilité nominative que l'IT exige.

### 3. Jenkins (`scripts/setup-user-deploy-job.sh`, idempotent)

Job `stoa-user-deploy` : **aucun credential** (ni AppRole ni secret Jenkins — contraste assumé avec le pipeline ADR-074/075). Trigger `generic-webhook-trigger` (token `stoa-user-deploy`), JWT reçu dans le payload (`vault_jwt`), `printContributedVariables=false` + `printPostContent=false` + `set +x` (jamais de jeton dans les logs) ; le JWT part en **corps** de requête et le token Vault en **header-file** (`curl -H @fichier`) — jamais en argv (`ps`/`cmdline`), standard ADR-074. Le build : `auth/jwt/login` → lecture du secret de déploiement **du tenant** → `revoke-self` **vérifié** (204) + **preuve de mort** (`lookup-self` → 403 sinon build rouge). Un webhook **sans** `vault_jwt` = build **FAILURE** (payload invalide) ; seul un build *manuel* sans payload est le no-op d'amorçage du trigger (distinction par `getBuildCauses(GenericCause)`).

## Preuves live (2026-07-05) — `scripts/test-user-vault-jwt.sh` : 24/24

- **Chaîne nominale (13)** : login humain alice (Dex/broker auth_code) → subject token adressé → exchange accepté → claims du JWT (`aud=vault`, `preferred_username=alice@bc.example`, `azp=vault-exchange`, **`tenant=banking-demo`**) → login Vault → token **nominatif** + policy templatée → lecture périmètre de SON tenant 200 / **cross-tenant 403** / hors-périmètre `secret/stoa/ci` **403**.
- **E2E CI (6)** : webhook → build Jenkins SUCCESS → le log atteste `identite=alice@bc.example tenant=banking-demo` → token révoqué **et prouvé mort** (`lookup-self` 403) → **aucun jeton dans le log** → webhook **sans** `vault_jwt` = build **FAILURE** (jamais de vert qui n'a rien fait).
- **Contre-épreuves (5)** : CE1 token non échangé → Vault refuse (`bound_audiences` + `azp`) ; CE2 subject token de service non adressé (`client_credentials poc-gateways`) → **KC refuse l'exchange** (précondition gardée : un mint raté = FAIL, pas un vert à vide) ; CE3 carol (viewer) → **Vault refuse** (`bound_claims`) ; CE4 audit nominatif **scopé aux lignes de ce run** ; CE4bis **les refus de ce run aussi sont audités**.

## Limites & deltas prod

1. **Keycloak ≥ 26.2 requis** (exchange standard V2). En deçà : feature preview `token-exchange` dépréciée — pousser le bump plutôt que la preview chez le client.
2. ~~Wiring console → Jenkins non branché~~ **LIVRÉ (2026-07-05, durci post-review)** : au `promote-approve`, **immédiatement après le merge** (les gates 4-yeux/ITSM/pin sont passés ; un échec de relecture ne perd pas l'effet), la governance-api échange le Bearer de **l'approbateur** et déclenche `stoa-user-deploy` avec le JWT (`labctl/cmd/governance-api/userdeploy.go`, opt-in par `USER_DEPLOY_WEBHOOK_URL` + `VAULT_EXCHANGE_SECRET[_FILE]` — fichier illisible = **fail-fast au boot**, jamais de désactivation silencieuse ; dispatch asynchrone — un effet, jamais un gate ; **arrêt gracieux** : SIGTERM vide les dispatches en vol). Hygiène de log : URL du webhook **redactée** (le token generic-webhook-trigger vit dans la query — ni au boot ni dans les `url.Error`). Réponse d'approve : champ additif `user_deploy: dispatched|not_configured` (documenté dans API-CONTRACT.md). Preuves : **7 tests unitaires** (contrat d'exchange, refus → pas de webhook, hook d'approve, refus 4-yeux → zéro dispatch, exchange KO → approve reste 200, flux inchangé sans wiring, opt-in env — suite verte sous `-race`) + **live `scripts/test-console-user-deploy.sh` 12/12** — bob approuve dans la Console et c'est SON identité (pas celle du demandeur) que Vault voit, build corrélé à LA promotion (hint), zéro jeton dans les logs BFF/Jenkins (JWT **et** token GWT).
3. **Transport du JWT** : PoC en HTTP compose interne ; en prod TLS partout, et le webhook Jenkins doit être authentifié (le token GWT du PoC est faible).
4. **Re-run** : JWT 5 min → un replay de build exige un re-déclenchement humain (propriété de gouvernance, à documenter chez le client pour éviter la découverte en incident).
5. **Jobs sans humain** (schedulés, reconcile) : restent sur AppRole (ADR-074) — à faire acter par l'IT comme périmètre distinct.
6. **Vault dev-mode** : root token statique, pas de HA — inchangé vs ADR-074 (PoC).
7. **Le lien approbation → exchange est organisationnel, pas cryptographique** : seul le détenteur du secret `vault-exchange` (la governance-api, qui n'échange qu'après un `approve` 4-yeux) peut convertir un token utilisateur — mais rien dans le JWT ne référence LE changement approuvé. Delta prod : claim `change_id` injecté à l'exchange + `bound_claims`, ou response-wrapping du jeton par la governance-api.
8. **Secret du client `vault-exchange` en clair dans le realm JSON** (Git) — même statut PoC-jetable que les autres secrets du realm ; il ne permet **pas** à lui seul de déployer (CE2 : il faut aussi un subject token utilisateur adressé). En prod : secret dans Vault + rotation, comme les autres clients confidentiels.
9. **`user_claim=preferred_username`** (lisible en démo : `display_name=jwt-alice@bc.example`) est un identifiant réattribuable ; en prod avec annuaire persistant, utiliser **`sub`** (immuable) comme clé d'entité et garder `preferred_username` en metadata d'audit.

## Restauration après recreate de `poc-keycloak` (runbook — COMPLET, validé le 2026-07-05)

Le realm est éphémère (`start-dev --import-realm`) ; l'import ne restaure QUE le statique (`realm-stoa-lab.json`). Séquence complète — les étapes 4-6 ont été découvertes par la passe de non-régression (A7 était retombé à 6/7 et `phase3` ne mintait plus) :

1. `./scripts/setup-identity.sh` — prérequis WSO2 KM + Review Profile off + APISIX.
2. **1 login par user fédéré** : `DEX_USER=<u>@bc.example ./scripts/get-oracle-token.sh --quiet` (alice, bob, carol, dave — les users brokerés n'existent qu'après leur premier login).
3. `bash ../console-light/scripts/setup-identity.sh` — rôles + attribut `tenant`. **Pièges** : usernames = `<user>@bc.example` (pas les prénoms nus) ; le script active désormais **`unmanagedAttributePolicy=ENABLED`** d'abord — sans ça (défaut KC ≥ 24 : DISABLED), le PUT de l'attribut `tenant` est **ignoré en silence** (rôles OK, tenant absent → 403 `FORBIDDEN accès refusé au tenant` à l'approve).
4. **Bloc identité de `demo-multienv.sh`** (idempotent, en tête de script) : groupe `int-team` + bob membre + mappers `demo-tenant-attr`/`demo-groups` sur **stoa-portal** — sans le mapper, l'attribut `tenant` ne sort jamais du user store.
5. Clients CI : `./scripts/setup-onboarding-rbac.sh` + `./scripts/setup-ci-applier.sh` + `./scripts/setup-ci-horsprod.sh`.
6. **Client runtime `accounts-read-consumer`** (créé à l'origine par `labctl subscribe`) : le recréer avec le **même secret** que `labctl-credentials.txt` (client confidentiel, serviceAccounts+standardFlow, mapper `accounts-read-audience` `included.custom.audience=accounts-read`, client scope par défaut `accounts.read`) — sinon `phase3-identity-demo.sh` meurt en `401 invalid_client` avant toute gateway. (Alternative : re-jouer la souscription `demo.sh`, qui régénère le fichier de credentials.)
7. `./scripts/setup-user-vault-jwt.sh` (scope `vault-aud` + Vault jwt).

Vérité : `./scripts/test-user-vault-jwt.sh` (21/21 lors de la passe de non-régression post-restauration ; **24/24 après le durcissement post-review — référence actuelle**) + `bash ../console-light/scripts/prove-a7-four-eyes.sh` (7/7) + `./scripts/test-console-user-deploy.sh` (wiring console) — re-validés le 2026-07-05.
