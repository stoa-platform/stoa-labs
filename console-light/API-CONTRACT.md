# Console Light — Contrat d'API du BFF gouvernance (v1)

> Document de référence pour les agents BFF (Go) et UI (React). Toute divergence = bug.
> Cadrage parent : `CADRAGE.md`. Principes : le principe hors-data-plane (la console n'exécute jamais labctl en prod — elle écrit des commits), CRV-1..6 (action validée = commit), zéro secret statique.

## 0. Topologie & ports

| Composant | Où | Port |
|---|---|---|
| UI (Vite dev) | host | `http://localhost:5173` |
| BFF `governance-api` | host (binaire Go) | `http://localhost:8787` |
| Keycloak | docker `poc-keycloak` | `http://localhost:8480` (issuer épinglé) |
| Dex (mock Oracle) | docker `poc-dex` | `http://localhost:5556` |
| Repo de gouvernance | host | `console-light/var/governance-repo` (git local, non-bare) |
| Gateways (optionnel) | docker | APISIX admin :9180, webMethods :8090 |

Le BFF sert aussi l'UI buildée (`ui/dist`) sur `/` en mode prod, mais en dev l'UI tourne sous Vite avec proxy `/api` → `:8787`.

## 1. Authentification

- UI : OIDC Authorization Code + PKCE via `react-oidc-context`/`oidc-client-ts`.
  - authority : `http://localhost:8480/realms/stoa-lab`
  - client_id : `console-light` (public, PKCE S256, redirect `http://localhost:5173/*`)
  - Le login passe par le broker `oracle` (Dex) — bouton « Se connecter via Oracle IdP » (paramètre `kc_idp_hint=oracle`).
- BFF : chaque requête `/api/*` porte `Authorization: Bearer <access_token>`.
  - Validation **stdlib-only** : RS256 via JWKS (`http://localhost:8480/realms/stoa-lab/protocol/openid-connect/certs`, cache 5 min), `iss == http://localhost:8480/realms/stoa-lab`, `exp`.
  - Claims extraits : `preferred_username`, `email`, `name`, `realm_access.roles[]`, `tenant` (attribut user mappé).
- Aucune session côté BFF, aucun cookie, aucun secret statique.

## 2. RBAC (miroir de la carrière, appliqué CÔTÉ BFF — l'UI ne fait que masquer)

Permissions `resource:verb` par rôle realm :

| Permission | cpi-admin | tenant-admin | devops | viewer |
|---|---|---|---|---|
| apis:read | ✓ | ✓ | ✓ | ✓ |
| apis:update | ✓ | ✓ | — | — |
| apis:publish (dev) | ✓ | ✓ | — | — |
| promotions:read | ✓ | ✓ | ✓ | ✓ |
| promotions:request | ✓ | ✓ | — | — |
| promotions:approve | ✓ | — | ✓ | — |
| subscriptions:read | ✓ | ✓ | ✓ | ✓ |
| subscriptions:approve | ✓ | ✓ | — | — |
| audit:read | ✓ | ✓ | ✓ | ✓ |
| audit:export | ✓ | ✓ | — | — |
| tenants:read | ✓ | ✓ | ✓ | ✓ |
| targets:read | ✓ | ✓ | ✓ | ✓ |
| users:read | ✓ | — | — | — |
| users:manage | ✓ | — | — | — |

- **Scope tenant** : `tenant-admin`/`devops`/`viewer` ne voient QUE leur tenant (claim `tenant`). `cpi-admin` voit tout et peut passer `?tenant=` sur les listes.
- **4-yeux (server-side)** : `POST .../promotions/{id}/approve` → 403 si `to == "production"` ET `requested_by == acteur`. Code erreur `SELF_APPROVAL_BLOCKED`.
- **Tout 403 est audité** : append `evidence/denials/denials.jsonl` + commit bot `deny({tenant}): {action} by {user}` (asynchrone, non bloquant).

## 3. Modèle Git (source de vérité)

Repo : `GOVERNANCE_REPO` (env, défaut `../var/governance-repo` relatif au binaire — passer un chemin absolu).

```
tenants/{tenant}/tenant.yaml
tenants/{tenant}/apis/{slug}/api.yaml          # contrat UAC v1 (schéma §5)
tenants/{tenant}/apis/{slug}/deploy.{env}.yaml # desired state par env: {version, enabled, promoted_by, message}
subscriptions/{tenant}/{id}.yaml               # {id, api, consumer, requested_by, status, reason?}
evidence/{tenant}/{slug}/{action}-{NNN}.json   # evidence pack (+ .md jumeau)
evidence/denials/denials.jsonl
```

**Règles d'écriture (invariants `api-creation-gitops-rewrite.md`) :**
1. Le BFF n'écrit JAMAIS depuis le payload : il écrit le fichier, commite, **relit depuis Git**, et répond avec le contenu relu.
2. Toute écriture = `git commit` avec **author = acteur** (`{Name} <{email}>`), committer = `governance-bot <bot@stoa.local>`, **signature SSH** (`commit -S`, clé du repo configurée par le seed).
3. Message : `gov({tenant}): {action} {resource}` + corps avec trailers :
   `Action: publish|draft|promote-request|promote-approve|promote-reject|sub-approve|sub-reject|role-change|deny`
   `Resource: {tenant}/{slug ou id}`, `Actor: {username}`, `Roles: {csv}`, `Evidence: {path|—}`.
4. **Publication dev** = commit direct sur `main` (mode direct CRV, assumé pour dev).
5. **Promotion staging/production** = branche `stoa/promote/{tenant}/{slug}/{id}` contenant : maj `deploy.{env}.yaml` + fichier `promotions/{tenant}/{id}.yaml` (id, slug, from, to, requested_by, message, status: pending). **Approve = merge --no-ff signé sur main** (+ evidence dans le commit de merge). **Reject = commit sur main** d'un marqueur `promotions/{tenant}/{id}.yaml` (status: rejected, reason) + suppression de branche.
6. Statut d'une promotion = position dans Git : branche ouverte → `pending` ; mergée (fichier sur main avec status approved écrit au merge) → `approved` ; marqueur rejected sur main → `rejected`. PAS d'état hors Git.
7. Concurrence : un mutex global d'écriture dans le BFF (une écriture Git à la fois) suffit pour la démo.

**Audit** = `git log` de main + branches `stoa/promote/*`, format machine :
`%H|%h|%an|%ae|%aI|%G?|%s` + trailers du corps. `signed = (%G? == G|goodsig pour SSH)` — configurer `gpg.ssh.allowedSignersFile` (fait par le seed) pour que `%G?` rende `G`.

## 4. Endpoints REST (`/api/v1`, JSON, erreurs `{error: {code, message}}`)

| Méthode & chemin | Permission | Réponse (forme) |
|---|---|---|
| `GET /me` | (authentifié) | `{username, name, email, roles[], permissions[], tenant}` |
| `GET /tenants` | tenants:read | `[{id, name, displayName, tier, status, apis_count}]` (scopé) |
| `GET /tenants/{t}/contracts` | apis:read | `[{slug, name, version, status, classification, endpoints_count, updated_at, last_commit{sha7, author, date}}]` |
| `GET /tenants/{t}/contracts/{slug}` | apis:read | `{contract: <UAC>, versions: [{sha, sha7, author, date, message, signed}], deployments: {dev,staging,production: {version, enabled, promoted_by}|null}}` |
| `POST /tenants/{t}/contracts/{slug}/validate` | apis:read | `{valid, errors: [{path, message}]}` (schéma §5 + règle destructive) |
| `PUT /tenants/{t}/contracts/{slug}` | apis:update | corps `{contract, message?}` → valide (mode draft) → commit → `{contract, commit: {sha, sha7, signed, message}}` |
| `POST /tenants/{t}/contracts/{slug}/publish` | apis:publish | corps `{message}` → valide (mode published : ≥1 endpoint) → status=published + deploy.dev → commit + evidence → `{commit, evidence}` |
| `GET /tenants/{t}/promotions?status=` | promotions:read | `[{id, slug, from, to, requested_by, message, status, created_at, branch, approved_by?, reason?}]` |
| `POST /tenants/{t}/promotions` | promotions:request | corps `{slug, from, to, message}` (message obligatoire ≤1000c, chaînes valides dev→staging, staging→production) → `{promotion}` |
| `GET /tenants/{t}/promotions/{id}/diff` | promotions:read | `{diff: "<unified diff texte>", files: [{path, additions, deletions}]}` |
| `POST /tenants/{t}/promotions/{id}/approve` | promotions:approve | corps `{message?}` → 4-yeux → merge signé → `{promotion, merge_commit: {sha, sha7, signed}, evidence, user_deploy: "dispatched"\|"not_configured"}` (champ additif ADR-077 : dispatch ASYNCHRONE du token exchange de l'approbateur vers le job Jenkins `stoa-user-deploy` ; l'UI peut l'ignorer) |
| `POST /tenants/{t}/promotions/{id}/reject` | promotions:approve | corps `{reason}` (obligatoire) → `{promotion}` |
| `GET /subscriptions?tenant=&status=` | subscriptions:read | `[{id, tenant, api, consumer, requested_by, status, created_at, reason?}]` |
| `POST /subscriptions/{id}/approve` | subscriptions:approve | → commit + evidence → `{subscription, commit}` |
| `POST /subscriptions/{id}/reject` | subscriptions:approve | corps `{reason}` obligatoire → `{subscription, commit}` |
| `GET /audit?tenant=&limit=100&action=` | audit:read | `[{sha, sha7, author, email, date, action, resource, actor, roles, message, signed, evidence}]` |
| `GET /audit/export?format=csv\|json` | audit:export | fichier (Content-Disposition) |
| `GET /targets` | targets:read | `[{name, type, adminUrl, gatewayUrl, health: up\|down\|unknown, latency_ms?}]` (ping HTTP timeout 2s, jamais bloquant) |
| `GET /users` | users:read | `[{id, username, email, roles[], tenant?, federated: bool}]` (Keycloak Admin API) |
| `PUT /users/{id}/roles` | users:manage | corps `{roles[]}` → maj Keycloak + commit d'audit `role-change` → `{user}` |
| `GET /roles` | (authentifié) | `[{name, description, permissions[], user_count}]` (défs statiques §2 + comptes KC) |
| `GET /dashboard` | (authentifié) | `{pending_promotions, pending_subscriptions, contracts, tenants, last_commits: [audit×5]}` |
| `GET /schema/uac` | (authentifié) | le JSON Schema UAC v1 (pour ajv côté UI) |

Accès Keycloak Admin du BFF : password grant `admin-cli` sur realm `master` (`KC_ADMIN_USER`/`KC_ADMIN_PASSWORD`, défaut admin/admin — PoC uniquement), même mécanique que `labctl/internal/keycloak`.

## 5. Validation UAC

- Schéma : copie locale `console-light/schema/uac_contract_v1_schema.json` (source : carrière cp-api). Le BFF l'embarque (`go:embed`) ; l'UI le récupère via `GET /schema/uac` et valide en live avec ajv.
- Règle sémantique (les DEUX côtés) : tout endpoint avec `llm.side_effects == "destructive"` DOIT avoir `llm.requires_human_approval == true` → sinon erreur `DESTRUCTIVE_REQUIRES_APPROVAL` sur `endpoints[i].llm.requires_human_approval`.
- Mode draft : schéma seul. Mode published : schéma + `≥1 endpoint` + règle sémantique.
- Le BFF valide en stdlib (champs requis, enums, patterns principaux — pas un validateur JSON Schema complet : couvrir required/enum/pattern name/semver/classification/status/methods/side_effects). L'UI fait la validation riche avec ajv. Le BFF reste l'autorité (revalide tout avant commit).

## 6. Evidence pack

Généré par le BFF pour publish / promote-approve / promote-reject / sub-approve / sub-reject, DANS le même commit :
```json
{
  "action": "promote-approve",
  "actor": {"username": "bob", "name": "Bob …", "email": "bob@bc.example", "roles": ["devops"]},
  "tenant": "banking-demo", "resource": "payments-initiation",
  "request": {"from": "staging", "to": "production", "promotion_id": "…", "message": "…"},
  "checks": {"schema_valid": true, "four_eyes": {"requested_by": "alice", "approved_by": "bob", "distinct": true}},
  "result": {"merge_commit": "…", "signed": true},
  "negative": "self-approval by alice was rejected at 403 (see denials.jsonl)"
}
```
+ rendu `.md` jumeau (squelette EVIDENCE.md : thèse → action → résultat → contrôles → limites). Chemin retourné dans les réponses et lié depuis l'écran Audit.

## 7. Démarrage & env

BFF : `go run ./cmd/governance-api` dans `poc-control-plane-federation/labctl/` (même module Go — peut importer `internal/*`).
Env : `GOVERNANCE_REPO` (abs), `LISTEN=:8787`, `KC_BASE=http://localhost:8480`, `KC_REALM=stoa-lab`, `KC_ADMIN_USER/PASSWORD`, `TARGETS_FILE` (optionnel, pour /targets), `UI_DIST` (optionnel).
CORS : autoriser `http://localhost:5173` (dev) sur `/api/*`.

## 8. Conventions UI

- Libellés **en français** (la démo est en français) ; le code (identifiants, types) en anglais.
- Données via TanStack Query, clients par ressource derrière une façade `apiService` (pattern carrière), `fetch` natif + header Bearer depuis le contexte auth.
- Aucune permission calculée côté UI ne fait autorité — l'UI masque (boutons absents, pas grisés, sauf indication contraire du quarry), le BFF refuse.
- data-testid sur chaque action de démo : `login-oracle`, `contract-card-{slug}`, `editor-save`, `editor-publish`, `commit-sha`, `promotion-approve-{id}`, `promotion-new`, `audit-row`, `audit-export`, etc.
