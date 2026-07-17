# rôle `apim_publish_api` — publication d'API (PRODUCTEUR, ADR-076/075), 100 % Ansible

Publie un contrat OpenAPI sur webMethods API Gateway 10.15 : **import multipart →
activate → scoping équipe → policies inbound** (validation JWT/OAuth2 au stage IAM).
Pendant du rôle **consommateur** `apim_selfservice_app` (même conventions : base
variabilisée, auth basic|oauth2, header `X-Environment`, Vault, fail-closed).
Orchestration ET mutation en Ansible pur ; le moteur Go labctl reste la spec parquée.

## Ce qui est prouvé live (10.15 réelle)

- **Import multipart** `POST /apis` (`file` + `type=openapi` + `apiName` + `apiVersion`) —
  le JSON from-scratch est cassé sur 10.15, le multipart est le chemin fiable.
- **Activate** (`PUT /apis/{id}/activate`) + read-back fail-closed `isActive=true`.
- **Inbound JWT** (`mode: jwt`) : alias auth-server (`POST /alias` body NU,
  `localIntrospectionConfig{issuer, jwksuri}`) + règle IAM `open/jwtClaims`. Prouvé :
  data-plane **sans token → 401**, **token valide → passe l'IAM** (502 = backend non branché).
- **Inbound OAuth2 COMPLET** (`mode: oauth2`) : alias + **strategy OAUTH2**
  (`POST /strategies`, alias+clientId+audience) + **scope mapping** (`POST /scopes`,
  `requiredAuthScopes[alias+scope]` + `apiScopes[apiId]`) + règle IAM
  `strict/oAuth2Token`. Prouvé : strategy + scope posés, **sans token → 401**.
  (`OAUTH2_CONFIRMED` au verify.)
- **Idempotent** (import/alias/IAM réutilisés par empreinte ; re-run sans 409).
- `verify` : `PUBLISH_CONFIRMED` + `INBOUND_CONFIRMED`.

## Usage

```bash
ansible-playbook -i inv.ini ansible/publish-api.yml -e @api.yml
ansible-playbook -i inv.ini ansible/publish-api-verify.yml -e @api.yml
```

## Le manifeste `apim_api`

| Champ | Rôle |
|---|---|
| `name`, `version` | identité de l'API |
| `contract` | **chemin** du contrat OpenAPI (yaml/json) — absolu ou relatif au playbook |
| `team` | nom d'accessProfile d'équipe (isolation ADR-076) — **optionnel** |
| `inbound` | `{issuer, jwks_uri, alias_name, mode}` — `mode: jwt` (signature) \| `oauth2` (strict). `jwks_uri` joignable **DEPUIS la gateway** (nom interne, pas localhost). Vide = API ouverte. |

Infra (base, env, auth, Vault) : mêmes vars `apim_ss_*` que le rôle consommateur —
un pipeline combiné (publier l'API PUIS créer le consommateur) les pose une fois.

## Multi-environnement (`per_env`) — prouvé live

L'identité de l'API (`name`/`version`/`contract`) est INVARIANTE ; ce qui CHANGE
par env c'est l'**inbound** — l'issuer/JWKS de l'IdP (et audience/client_id en
OAuth2) ne sont pas les mêmes en dev/rec/int/prod. On met donc l'inbound variable
sous `per_env: { dev: {inbound: {...}}, ... }` (`alias_name`/`mode` restent racine).
Le rôle (`tasks/resolve-env.yml`, pendant du consommateur) fusionne **racine ⊕
per_env[apim_ss_env]** selon l'env choisi. **FAIL-CLOSED** : `per_env` déclaré ⇒
`apim_ss_env` fourni ET connu, sinon refus (`ENV_UNDEFINED`) — sinon l'API validerait
les jetons du **mauvais émetteur** (pire qu'un refus). Prouvé : `apim_ss_env=dev`
matérialise l'issuer `…/stoa-lab` sur l'alias, `=staging` → refus.

Charger le manifeste par **CHEMIN** (`-e apim_ss_manifest=<fichier>` → `include_vars`),
**jamais `-e @fichier`** (extra-var : masquerait la fusion). `apim_ss_env` reste extra-var.

## Mise à jour d'une API existante (`apim_api.update`) — prouvé live

Par défaut le rôle est **create-only** : si l'API (même `name`+`version`) existe
déjà, le contrat n'est **pas** ré-importé (pas de re-déploiement surprise ; bumper
`version` reste l'alternative). Mettre **`update: true`** dans le manifeste pour
pousser un contrat modifié sur une API existante : le rôle fait **deactivate → PUT
`/apis/{id}` (multipart) → activate**. La désactivation est nécessaire car le PUT
d'update est **refusé (400) sur une API active** (prouvé live) — d'où une **brève
coupure du data-plane** le temps de l'update. `activate`/`inbound` reconvergent après.

> Piège Jinja épinglé : tester `apim_api['update']` et **non** `apim_api.update` —
> l'accès par attribut `.update` résout la **méthode `update()` du dict** (collision),
> jamais la clé du manifeste (le bloc serait alors toujours skippé, en silence).

## Port en Deny-by-Default : allow-list (IS-admin, opt-in) — prouvé live

Chez le client, le **port data-plane est en Deny-by-Default** : chaque API publiée
doit être **ajoutée à l'allow-list du port**. C'est l'**Access Mode du listener
Integration Server** (`Security > Ports > Access Mode`) — une surface DIFFÉRENTE de
l'API d'admin apigateway (le REST `/ports` ne l'expose pas), pilotée par le form
WmRoot `security-ports-editaccess.dsp`. `tasks/port-access.yml` (opt-in
`apim_ss_port_manage=true`, importé après l'activate) fait **read → add idempotent
→ read-back fail-closed** (`PORT_ALLOWLIST_CONFIRMED`). Prouvé live (10.15) :
add depuis vide, skip idempotent au re-run, retrait, sans CSRF token.

Pour la **création d'environnement** (autoriser plusieurs services d'un coup) :
play standalone `ansible/is-port-access.yml` (`-e apim_ss_port_allow_entries=[…]`).

| Var | Rôle | Défaut |
|---|---|---|
| `apim_ss_port_manage` | active l'étape (là où le port est Deny-by-Default) | `false` |
| `apim_ss_isadmin_base` | surface IS-admin WmRoot (client : proxifié ou direct) | `http://localhost:5555/WmRoot` |
| `apim_ss_port_alias` | listener concerné | `HTTPListener@5555` |
| `apim_ss_port_allow_entry` | entrée à autoriser = **référence de service IS `folder:service`** de l'API | `""` |

**À valider / caveats :**
- **`folder:service` uniquement** : le port **REJETTE les URLs data-plane** (`/gateway/…`
  testé, silencieusement droppé) — l'allow-list est par SERVICE IS. Le **mapping
  API → service** dépend du dispatch gateway du client (d'où `apim_ss_port_allow_entry`
  paramétrable). À confirmer sur l'IS du client quel service sert le data-plane.
- **Le mode n'est JAMAIS flippé** par le rôle (risque de **lockout** du data-plane) :
  le passage en Deny-by-Default est fait à la **création de l'env** côté client ; le
  rôle ne fait qu'AJOUTER l'entrée.
- **CSRF** : sur ce trial le guard IS-admin est OFF (le POST passe sans token). Si le
  client a le **CSRF guard activé** sur l'admin IS, le form POST exigera un token
  (à récupérer par cookie/page) — extension à prévoir.

## Limites / à valider

- **Team scoping** (`team.yml`) : **NON testé live** (le lab n'a pas d'accessProfile
  d'équipe ; Teams doit être activé). Shape best-effort du spike — à valider client.
- **Enforcement `aud` de l'OAuth2** : sur le **trial** l'introspection remote est
  inerte → l'`aud` reste fail-OPEN (signature + azp + scope enforced, 3/4 barrières,
  cf. finding ADR-075). Sur un build non-trial l'aud est enforcé sans changement.
- **Backend** : l'import prend les `servers[]` du contrat ; le backend par alias
  (`${alias}` env-switchable, ADR-075) est une extension (`routing.yml` à venir).
