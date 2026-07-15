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
- **Inbound JWT** : alias auth-server (`POST /alias` body NU, `localIntrospectionConfig
  {issuer, jwksuri}`) + règle IAM `open/jwtClaims` attachée. Prouvé : data-plane
  **sans token → 401**, **token valide → passe l'IAM** (502 = backend non branché).
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

## Limites / à valider

- **Team scoping** (`team.yml`) : **NON testé live** (le lab n'a pas d'accessProfile
  d'équipe ; Teams doit être activé). Shape best-effort du spike — à valider client.
- **Inbound `oauth2`** : la règle IAM `strict/oAuth2Token` est posée, mais la
  **strategy OAUTH2 + le scope mapping** (le liant audience/scope, cf. `oauth2.go`)
  ne sont pas encore projetés — extension. Le mode `jwt` (signature) est complet.
- **Backend** : l'import prend les `servers[]` du contrat ; le backend par alias
  (`${alias}` env-switchable, ADR-075) est une extension (`routing.yml` à venir).
