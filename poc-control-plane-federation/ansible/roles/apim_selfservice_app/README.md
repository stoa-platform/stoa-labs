# rôle `apim_selfservice_app` — self-service de création d'application (ADR-078), 100 % Ansible

Crée/converge une **application consommatrice** sur webMethods API Gateway 10.15
et **OPPOSE** son identité entrante (plage IP, + certificat) par une règle
d'identification IAM `AND(strict)` — ce qui **ferme le fail-open** « identifier
écrit mais inerte ». Orchestration ET mutation gateway en Ansible pur (module
`uri`, aucune collection tierce).

## Pourquoi Ansible et pas le binaire Go

Chez ce client, le code **co-développé avec une IA** n'est pas (encore) autorisé
sous forme de **binaire compilé** ; un **playbook Ansible** que l'ops relit et
s'approprie passe sans souci. On inverse donc la doctrine `DELIVERY-PROCESS`
(« Ansible orchestre, labctl mute ») : **ici Ansible fait les deux**. La logique
d'idempotence, les shapes REST et le **read-back fail-closed** sont la SPEC
VÉRIFIÉE côté Go (`labctl/internal/adapter/webmethods`, mémoire projet
`wm-1015-rest-shapes`) — le binaire reste au repo, parqué, réactivable plus tard.

## Ce qui est prouvé live (10.15 réelle)

**Plan ENTRANT** (`tasks/main.yml`) :
- App + identifier `ipAddressRange` + règle IAM `AND(ipAddressRange)` posés,
  **idempotents** (re-run = no-op ; find par **empreinte de règles** — la gateway
  force le nom « Identify & Authorize », donc jamais de match par nom).
- **Fail-open fermé** : IP hors plage → **403**, IP autorisée → **200**.

**Plan SORTANT** (`tasks/backend.yml`, P-callout) :
- Request Transformation `customHttpHeaders` posée au stage routing (idempotence
  clé sur l'action déjà attachée → **une seule** par API, pas de 409). Prouvé
  live : le backend (token-echo) **reçoit le header injecté**.

**Cloisonnement de l'application** (`tasks/team.yml`, E3 geste 1) :
- `POST /assets/team {assetType:"Application"}` posé **par la chaîne de création**,
  puis **relu** : `TEAM_CONFIRMED` exige la team demandée présente ET `Default`
  partie. Prouvé live le 2026-07-31 (`teams=['Administrators','banking-demo']`),
  idempotent au re-run.
- **La relecture n'est pas décorative** : sans `assetType`, le même POST rend
  **200** avec un corps `{}` et **ne change rien** (mesuré : teams inchangées).
  Seule la relecture distingue « assigné » de « accepté puis ignoré ».
- **Fail-closed par défaut** : pas d'équipe résolue ⇒ `TEAM_UNDEFINED`, refus de
  déployer. Une application laissée en `Default` est visible **et supprimable**
  par toutes les équipes ; assignée, elle est cloisonnée **nativement** (autre
  équipe : `GET`/`DELETE` → 401, absente de la liste). La protection existe donc
  dans le produit, mais elle est facultative — d'où son ancrage ici.
- **D'où vient l'équipe** : `-e apim_ss_team=<team>` (posée par le pipeline, qui
  la dérive du chemin KV du compte de service — donc du seul périmètre où le
  token nominatif a le droit d'écrire) **l'emporte** sur `team:` du manifeste.
  L'appelant écrit le manifeste : il ne doit pas choisir sous quelle équipe son
  application est cloisonnée quand la chaîne, elle, le sait.
- **Opt-out** : `-e apim_ss_require_team=false` — pour un lab **sans** feature
  Teams uniquement. Le rôle affiche alors `TEAM_SKIPPED` en clair.

**Garde du register** (`tasks/api-visibility.yml`, E3 geste 2 — chemin GitOps) :
- La gateway laisse une équipe **associer une API qu'elle ne peut même pas lire**
  (`GET /apis/{id}` → 401 mais `PUT /applications/{id}/apis` → 200, association
  réelle). C'est la seule des trois gardes du design que le produit n'assure pas.
- **L'oracle du design n'est pas disponible à la chaîne.** Il supposait d'appeler
  `GET /apis/{id}` *avec les creds de l'équipe*. Or la chaîne ne peut pas tourner
  sous l'identité de l'équipe : un utilisateur d'équipe se voit **refuser**
  `POST /assets/team` (**401**, « not authorized to perform: POST on the resource:
  assets » — mesuré 2026-07-31). Assigner une team est une opération d'**admin**,
  et pour l'admin `GET /apis` n'est pas scopé : sa visibilité ne prouve rien.
- **Oracle retenu** : l'admin lit l'assignation de l'API — `GET /apis/{id}` →
  `apiResponse.teams[]` (**niveau `apiResponse`** ; `api.teams` est vide, piège
  relevé dès F4). Règle : l'équipe demandeuse doit y figurer, **ou** l'API doit
  être en `Default` (visible de toutes). Équivalence **mesurée**, pas supposée :
  une identité `insurance-demo` voyait exactement les APIs en `Default`.
- Prouvé live (identité admin, comme la chaîne réelle) : `insurance-demo` →
  `accounts-read` (team `banking-demo`) **refusé** `API_NOT_VISIBLE_TO_TEAM`, et
  **rien n'est créé** (la garde est en §1b, avant l'application) ;
  `insurance-demo` → `accounts-read-ans` (`Default`) **autorisé** ;
  `banking-demo` → `accounts-read` **autorisé**.
- ⚠ **Ce que la garde NE couvre pas** : le chemin **direct**. Une équipe qui
  atteindrait `/rest/apigateway` par le proxy OAuth2 (E2) pose toujours
  l'association elle-même. Ce chemin reste à couvrir par le service IS de
  préprocessing (GOAL § E3) — il ne se ferme pas en Ansible.

`verify` **fail-closed** : `TEAM_CONFIRMED` (application cloisonnée sur son
équipe) + `REGISTER_ALLOWED` (l'API demandée est consommable par l'équipe) +
`ENFORCEMENT_CONFIRMED` (le stage IAM oppose l'action AND) +
`OUTBOUND_CONFIRMED` (customHttpHeaders au routing) + preuve data-plane 200.

## Usage

```bash
# converge (défauts dans defaults/main.yml ; surcharger apim_ss_app par -e / group_vars)
ansible-playbook -i inventory.ini ansible/selfservice-app.yml \
  -e '{"apim_ss_app":{"name":"svc-toto","api":"accounts-read","api_version":"1.0.0","ip_allowlist":["10.60.30.1-10.60.30.30"],"enforce":["ipAddressRange"]}}'

# preuve fail-closed rejouable (critère d'acceptation)
ansible-playbook -i inventory.ini ansible/selfservice-app-verify.yml -e @vars.yml
```

## Endpoint, environnement, authentification (variabilisés)

Les tâches ne portent **que la ressource** (`/applications`, `/apis`, `/policies`,
`/policyActions`) — la base est une variable.

| Var | Rôle | Défaut (PoC direct) |
|---|---|---|
| `apim_ss_api_base` | base de l'API d'admin, **préfixe inclus** ; chez le client = le **proxy** qui mappe `rest/apigateway` | `http://localhost:5555/rest/apigateway` |
| `apim_ss_data_base` | base data-plane (verify live) | `http://localhost:5555/gateway` |
| `apim_ss_env` | env ciblé via header (proxy on-premise **multi-env**) ; vide = pas de header | `""` |
| `apim_ss_env_header` | nom du header d'env | `X-Environment` |
| `apim_ss_auth_mode` | `basic` (direct) \| `oauth2` (proxy) | `basic` |
| `apim_ss_oauth_token_url` / `_client_id` / `_client_secret` / `_scope` | OAuth2 client_credentials — de préférence depuis **Vault** (`gateways/webmethods/admin-oauth`) | `""` |
| `apim_ss_ca_path` | **CA privé** (bundle PEM) : couvre gateway + IdP OAuth2 + Vault (concaténer si CA différentes). Vide = trust store système | `""` |

**Auth à Vault (env, précédence statique > Kubernetes > user/mot de passe > AppRole)** — le play lit les creds gateway ; il n'exige **aucune** entité nominative (accès système, ADR-074) :

| Env | Rôle |
|-----|------|
| `VAULT_TOKEN_FILE` > `VAULT_TOKEN` | token statique (ex. token IHM) — prioritaire |
| `VAULT_K8S_ROLE` (+ `VAULT_K8S_JWT_PATH`) | **★ auth Kubernetes** (`auth/kubernetes/login`) — le pod agent s'authentifie avec **son** ServiceAccount token, **zéro secret stocké** (reco HashiCorp sur K8s). Fait DANS le conteneur agent → identité du pod agent, pas du contrôleur (piège du plugin Jenkins). `VAULT_K8S_JWT_PATH` surcharge le chemin du SA token (défaut `/var/run/secrets/kubernetes.io/serviceaccount/token`) |
| `VAULT_USER` + (`VAULT_USER_PASS_FILE` > `VAULT_USER_PASSWORD`) | **login user/mot de passe par build** (`POST /v1/<mount>/login/<user>`) — token court, rien de stocké. Le mount vient de `VAULT_USER_AUTH_MOUNT` : `auth/ldap` chez le client (AD ; ou `auth/ad`, `auth/ldap-corp`…), `auth/userpass` en lab — **même requête REST, seul le mount change**. La policy se mappe au **groupe d'annuaire** (`auth/ldap/groups/<grp>` → `deploy-<tenant>`). `VAULT_LDAP_USER`/`VAULT_LDAP_PASS[_FILE]` restent acceptés (alias historique) |
| `VAULT_ROLE_ID` + (`VAULT_SECRET_ID_FILE` > `VAULT_SECRET_ID`) | AppRole (fallback) — ignoré si `VAULT_K8S_ROLE` ou `VAULT_USER` est posé. Sécuriser le SecretID par **response-wrapping** (`VAULT_SECRET_ID_FILE` = SecretID déballé au run) |
| `VAULT_NAMESPACE` | **Vault Enterprise** : posé en `X-Vault-Namespace` sur *tous* les appels (login, lectures KV). Vide = Vault OSS / namespace racine |

> **Sous Jenkins, ces logins ne servent pas** : `ci/lib/vault-login.sh` fait le login
> **nominatif** une seule fois et exporte `VAULT_TOKEN_FILE`, que le rôle consomme en
> tête de précédence — les tâches de login ci-dessus sont alors *skippées* (visible
> dans le log du build). Une seule implémentation d'auth à auditer. Ces logins
> couvrent les exécutions **hors** Jenkins (ops en local, agent K8s sans wrapper).
>
> ⚠ **Un login user/mot de passe REFUSÉ ne doit pas être rejoué en boucle** : la
> politique de lockout de l'annuaire verrouille le compte nominatif après N échecs.
> Le rôle échoue donc *une fois*, avec un diagnostic qui ne contient aucun secret.

**Mode `oauth2` (proxy client)** : le rôle fait le **get token** (`client_credentials`)
et passe `Authorization: Bearer …` + `X-Environment: <env>` sur chaque appel — un
seul endpoint proxifié attaque tous les envs. Aucune auth basic. Prouvé : token
Keycloak récupéré, headers `Accept + X-Environment + Authorization`.

Exemple client (via Vault) :

```bash
ansible-playbook -i inv.ini ansible/selfservice-app.yml \
  -e apim_ss_auth_mode=oauth2 -e apim_ss_env=rec \
  -e apim_ss_api_base=https://apim-admin.banque.internal/proxy \
  -e @app.yml     # VAULT_ADDR posé -> token_url/client_id/secret lus dans Vault
```

Creds (basic OU oauth2) lus dans **Vault** (rôle partagé
`apim_common/tasks/secrets.yml`), fallback PoC total sans `VAULT_ADDR`.

## Multi-environnement (`per_env`) — prouvé live

Sur chaque env, l'**IP source, le certificat client et la clé backend diffèrent**,
alors que l'identité de l'app (`name`/`api`/`enforce`/nom du header) est INVARIANTE.
Le manifeste porte donc l'invariant à la racine et les valeurs qui changent sous
`per_env: { dev: {...}, rec: {...}, int: {...}, prod: {...} }`. Le rôle
(`tasks/resolve-env.yml`) calcule le **manifeste effectif = racine ⊕ per_env[env]**
(fusion récursive) selon `apim_ss_env`. Le proxy d'admin, lui, reste un endpoint
unique : c'est le header `X-Environment` (piloté par le même `apim_ss_env`) qui
route — pas une base différente.

- **FAIL-CLOSED** : `per_env` déclaré ⇒ `apim_ss_env` doit être fourni ET présent
  dans la liste, sinon **refus** (`ENV_UNDEFINED`) — on ne matérialise jamais une
  identité (IP/cert) non définie pour l'env ciblé. Prouvé : `apim_ss_env=dev` pose
  l'IP dev, `=prod` bascule l'identifier vers la plage prod, `=staging`/vide → refus.
- **Chargement du manifeste** : passer un **CHEMIN** via `-e apim_ss_manifest=<fichier>`
  (le rôle fait `include_vars`), **jamais `-e @fichier`** : un extra-var (précédence
  22) masquerait le `set_fact` de fusion (19) et la surcharge `per_env` serait
  silencieusement perdue. `apim_ss_env` reste, lui, un extra-var (l'ops choisit l'env).
  Chemin repo-relatif résolu depuis `playbook_dir/..`, ou absolu. Le dossier ainsi
  résolu est mémorisé (`apim_ss_manifest_dir`) et sert de **seconde base** à
  `public_cert_ref` (cf. tableau ci-dessous).

```bash
ansible-playbook -i inv.ini ansible/selfservice-app.yml \
  -e apim_ss_manifest=clients/acme/applications/svc-toto.yml -e apim_ss_env=prod
```

## Le manifeste `apim_ss_app`

| Champ | Rôle |
|---|---|
| `name`, `api`, `api_version` | application + API cible (publiée d'abord) — INVARIANT |
| `team` | équipe qui **cloisonne** l'application. **Repli** : `-e apim_ss_team` (posé par le pipeline) l'emporte. Aucune des deux ⇒ refus de déployer (`apim_ss_require_team`, défaut `true`) — INVARIANT |
| `enforce` | dimensions à OPPOSER, sous-ensemble de `["httpsCertificate","ipAddressRange"]` — **vide = identifiers inertes, à éviter** — INVARIANT |
| `backend` | header + template de clé backend (plan sortant, cf. limites) — INVARIANT (la valeur, elle, est résolue par env via le TokenProvider ← Vault de l'env) |
| `per_env.<env>.ip_allowlist` | IPs / plages `A-B` — **PAS de CIDR** (la gateway le drop en silence) ; une IP nue est normalisée en `X-X` (match exact + visible UI) — **PAR ENV** |
| `per_env.<env>.public_cert_ref` | chemin d'un PEM **public** (clé privée refusée). **Absolu** = pris tel quel. **Relatif** = cherché d'abord depuis la **racine du dépôt** (comme `apim_ss_manifest`), puis **à côté du manifeste** — donc poser le `.crt` dans le même dossier que la définition de l'application et écrire le nom de fichier nu fonctionne. Introuvable dans les deux = échec (`CERT_NOT_FOUND`, qui **affiche les deux chemins essayés**) ; présent dans les deux avec des contenus **différents** = échec (`CERT_PATH_AMBIGUOUS`, on ne choisit jamais une identité en silence). Preuve hors ligne : `scripts/test-cert-path-resolution.sh` (13/13) — **PAR ENV** |

| `auth` | bloc OAuth2 **opt-in** (absent ⇒ aucune stratégie posée). `mode: idp` = le client vit sur l'IdP, `claim {name,value}` l'identifie, **`audience` obligatoire** (= celle de l'API). `mode: internal` = la gateway est l'AS (`local`) et **`audience` est OPTIONNELLE** : l'AS local n'en exige pas, et ce runtime n'oppose de toute façon pas `aud` (`EVIDENCE.md` §Preuve 5 bis). Vide ⇒ la clé est **omise** du corps et de l'entrée Vault, jamais envoyée à `""`. Preuve hors ligne : `scripts/test-auth-audience.sh` (13/13) |

## Limites / résidus (assumés, ADR-078)

- **Certificat** : posé en identifier REST, en **base64** (le champ JSON `value`
  de l'identifier) — **c'est la voie normale, pas un pis-aller**. L'UI de la
  gateway fait **exactement la même chose** : elle lit le `.cer` binaire en JS et
  l'envoie en `base64(DER)` dans le même PUT JSON. Trace réseau + comparaison des
  octets stockés (spike 2026-07-17, ADR-078 écart n°5) : **même sha256** par les
  deux voies ⇒ il n'existe **aucun** « upload binaire », et donc aucun
  contournement UI d'un bug de hash. Le REST refuse le binaire brut et l'hex (400)
  et n'accepte que `base64(DER)` ou le PEM complet, stockés verbatim.
  `AND(cert,IP)` ne se teste pas en clair (cert non présenté → 401) : il exige le
  listener HTTPS client-auth.
  - **Extraction robuste (fail-closed)** : le rôle isole le **premier** bloc
    `-----BEGIN/END CERTIFICATE-----` (équivalent du `pem.Decode()` de la spec Go),
    PAS un simple strip global. Mesuré live (spike 2026-07-17) : le strip global
    **corrompait en silence** un PEM **en chaîne** (leaf + intermédiaire →
    corps concaténés) et un PEM **à en-tête texte** (`Bag Attributes`, `subject=` :
    exports Windows/Java → lettres de l'en-tête gardées dans le base64). La gateway
    stocke verbatim ⇒ identité **morte** (401 au handshake) sous un « convergé »
    trompeur. Corrigé + fail-closed : un fichier sans bloc CERTIFICATE, ou un corps
    base64 mal formé (longueur non multiple de 4), est **refusé** (`CERT_INVALID`),
    plus jamais posé corrompu. Prouvé : `chain.pem`/`bagattr.pem` → même `sha256`
    que le leaf ; `garbage.pem` → refus.
  - **Préservation d'un cert posé hors manifeste** : le re-run ne remplace QUE les
    dimensions **déclarées par le manifeste** (`ss_managed_keys`). Un
    `httpsCertificate` posé par l'UI (donc `public_cert_ref` vide) est **conservé**
    au re-run au lieu d'être effacé — prouvé live. (Idem `azp`/`openIdClaims`.)
- **Plan SORTANT (clé backend, P-callout)** : `tasks/backend.yml` POSE le câblage
  (`customHttpHeaders headerValue=${backend_apikey}`). La **valeur** est résolue au
  runtime par le package IS **TokenProvider ← Vault** (déploiement Designer = résidu
  manuel) ; pour un test hors TokenProvider, mettre `backend.value_template` à un
  littéral (prouvé : atterrit au backend). Le callout transport qui alimente
  `${backend_apikey}` n'est PAS posé par ce rôle (dépend du package IS).
- **CIDR** : rejeté fail-closed (à convertir en range via `ansible.utils.ipaddr`
  en évolution).
- **🔴 `enforce` est une propriété de l'API, PAS de l'application.** La règle
  d'identification est attachée au **stage IAM de la policy SERVICE de l'API**, et
  cette policy est **unique par API** : deux applications qui consomment la MÊME
  API avec des `enforce` DIFFÉRENTS sont mutuellement exclusives. Mesuré le
  2026-07-31 sur la gateway du cluster, avec les deux manifestes `_example` qui
  ciblent tous deux `accounts-read` : après apply de `demo-consumer-cert`
  (`httpsCertificate`), l'action `AND(ipAddressRange)` de
  `demo-consumer-accounts-read` n'est plus seulement détachée — elle a **disparu
  de `GET /policyActions`** ; l'apply inverse la recrée et fait disparaître celle
  du certificat. Le dernier apply gagne, et l'autre consommateur perd son
  identification. **Ce n'est pas silencieux** : le `verify` de l'application
  perdante passe au rouge (`ENFORCEMENT_UNCONFIRMED`) — c'est la chaîne
  fail-closed qui joue son rôle. Mais tant que ce point n'est pas tranché, **ne
  pas déployer deux applications d'`enforce` différents sur une même API**.
