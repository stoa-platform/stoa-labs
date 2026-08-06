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
| `contract` | **chemin** du contrat OpenAPI (**YAML ou JSON**) — absolu ou relatif au playbook. *NB : un contrat JSON exige le fix `\| string` sur le `lookup('file')` (sinon Ansible le coerce en dict → multipart en repr Python guillemets simples → 400 ; prouvé + corrigé 2026-07-17).* |
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

## Nouvelle version d'une API existante (`tasks/version.yml`) — mesuré le 2026-08-05

**Rien à déclarer** : il suffit de bumper `apim_api.version`. Si le `name` existe
sur la gateway sous une AUTRE version, le rôle ne tente pas un import nu (le
produit refuse un `POST /apis` sur un nom déjà pris) : il **duplique**
(`POST /apis/{id}/versions`) puis pousse la spec du manifeste par le chemin
re-import ci-dessus. Nom inconnu ⇒ import initial, **inchangé**.

Faits MESURÉS sur la 10.15 du lab (spike `scripts/spike-api-versions-1015.sh`,
27/27) que le rôle **exige** à chaque mint, pour détecter un changement de
comportement produit à la prochaine montée de version :

| Fait | Ce que le rôle en fait |
|---|---|
| `retainApplications` est un **booléen à la casse EXACTE** ; absent, `false` ou mal casé ⇒ souscriptions PERDUES en silence (HTTP 201 quand même) | envoyé **explicitement à `true`**, puis relecture AVANT/APRÈS de `GET /applications` → `VERSION_SUBS_NOT_RETAINED` si un abonné a été perdu |
| policies **CLONÉES** (ids nouveaux), record né **inactif** | relu et asserté → `VERSION_CLONE_UNEXPECTED` |
| duplication permise **depuis la DERNIÈRE version seulement**, et `GET /apis` n'expose aucun marqueur de « dernière » (le plus grand numéro n'est PAS la dernière : lignée `accounts-read` du lab, 1.0.0 minée depuis 1.0.1) | **plusieurs versions candidates ⇒ refus `VERSION_BASE_AMBIGUE`** avec la liste, jamais de devinette |

Échecs nommés : `API_OWNER_MISMATCH`, `TEAM_IS_SYSTEM_PROFILE`, `VERSION_BASE_FOREIGN`,
`VERSION_RESUME_FOREIGN`, `VERSION_BASE_AMBIGUE`, `VERSION_CREATE_FAILED`,
`VERSION_UNCONFIRMED`, `VERSION_CLONE_UNEXPECTED`, `VERSION_SUBS_SHAPE_UNKNOWN`,
`VERSION_SUBS_NOT_RETAINED`, `VERSION_MINTED_ACTIVE`, `VERSION_INCOMPLETE`.
Avertissement (non bloquant) : `VERSION_FOREIGN_UNCHECKED`.

### La lignée doit appartenir à l'équipe demandeuse (`VERSION_BASE_FOREIGN`)

Publier une NOUVELLE version sous un nom qui appartient à une AUTRE équipe
n'est pas une publication, c'est une **capture d'actifs** : la version minée
**hérite des teams de sa base** (mesuré le 2026-08-05 — elle atterrit donc dans
le périmètre de la victime, jamais en `Default`) et `retainApplications:true`
lui **transporte ses abonnés**. Avant cette garde, ce cas rendait un 409 franc ;
le chemin nouvelle version le rendait silencieusement possible.

La règle est **∀ et positive** : chaque version de la lignée doit être
**confirmée** appartenir à l'équipe demandeuse (`apim_ss_team`, posée par le
job). Une version en `Default`, une enveloppe sans `teams`, la feature Teams
éteinte ou aucune équipe demandeuse ⇒ **refus** — ne pas savoir n'autorise pas.
Knob de tolérance, lab uniquement : `apim_pub_version_require_team_match=false` ;
il est **bruyant** (`VERSION_FOREIGN_UNCHECKED` à chaque run concerné), parce
qu'une capture non gardée ne doit pas se déduire d'un `skipping:` muet.

**Les DEUX chemins qui écrivent traversent cette confirmation** : le mint
(`VERSION_BASE_FOREIGN`) et la **reprise** (`VERSION_RESUME_FOREIGN`). La
reprise s'exécute quand `name`+`version` est trouvé par le matching **global**
de `main.yml` : sans garde, elle poussait le contrat du demandeur sur la
demi-version d'une autre équipe puis l'activait — ses consommateurs recevaient
la mauvaise spec.

**Un profil SYSTÈME n'est pas une équipe** (`TEAM_IS_SYSTEM_PROFILE`).
`Administrators` est porté par TOUTE API : passé en `apim_ss_team`, il faisait
confirmer l'appartenance de n'importe quelle lignée. La liste est un défaut
nommé du rôle (`apim_pub_system_profiles`), pas une valeur en dur.

### Mint interrompu (`VERSION_INCOMPLETE`) — crash-consistance

Le mint et le push de la spec sont **deux appels**. Entre les deux, la version
existe avec la définition **clonée de sa base**. Si le run meurt là, le run
suivant retrouve `name`+`version` et prendrait le chemin nominal : il
**activerait le clone**, en silence (rc=0, aucun message, le data-plane sert le
contrat de la base). Le rôle **refuse** ce cas — version inactive dans une
lignée multi-versions, sans `update:` — et nomme le geste de reprise :
`-e apim_pub_resume_version=true` (re-import de la spec + relectures, puis
activation ; légal sans désactivation, le record est inactif).

Ne PAS poser ce knob à demeure : une version inactive peut aussi l'avoir été
**volontairement**, et la reprise la remettrait en service. Un import initial
interrompu (lignée **mono-version**, spec correcte) n'est pas concerné : il se
reprend tout seul, comme avant.

**ADR-079** : le re-import qui suit un mint est **exempté** de `UPDATE_FORBIDDEN`
— une version qui vient de naître est inactive et n'a jamais servi de trafic,
donc rien à couper (publier une nouvelle version EST la voie 0-coupure). L'exemption
ne tient pas sur un booléen : l'état est **relu sur la gateway** avant le PUT
(`VERSION_MINTED_ACTIVE` sinon). Preuve rejouable, hors ligne :
`scripts/test-publish-version.sh` (65/65 contre le mock, témoins AVANT inclus).

> **Deux voies de naissance d'une version coexistent, une seule est prouvée.**
> Le moteur Go (`labctl/internal/adapter/webmethods/publish.go`, `latestByName`),
> encore vivant via `scripts/demo-multienv.sh`, choisit la base par le **plus
> grand numéro de version** — or ce n'est **pas** la dernière version (mesuré :
> lignée `accounts-read`, 1.0.0 minée depuis 1.0.1), donc il prendrait le 400
> « Versioning is allowed only from latest version ». Dette marquée, non
> réécrite (hors périmètre) : voir le commentaire au-dessus de `latestByName`.

> **Le chemin `name`+`version` est GARDÉ** (revue finale). La recherche de
> `main.yml:61-67` reste globale — c'est le produit qui n'offre pas de filtre —
> mais l'API trouvée doit désormais appartenir à l'équipe demandeuse
> (`API_OWNER_MISMATCH`), garde évaluée **avant** le moindre geste d'écriture
> (update, activation, approbateurs, scoping d'équipe). Sans elle, une équipe
> onboardée capturait une API PLATEFORME — `provisioning`, mesurée ACTIVE et en
> `Default` — par un simple `ACTION=create` avec le bon nom et la bonne version.
> `Default` ne vaut pas appartenance : une API sans équipe réelle n'est pas
> réclamable par la chaîne, un administrateur doit l'assigner d'abord.

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
