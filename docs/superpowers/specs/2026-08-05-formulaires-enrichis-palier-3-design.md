---
title: "Palier 3 — formulaires enrichis : listes vivantes, identité entrante, et la porte du producteur (spécification)"
type: spec
status: "Cadré le 2026-08-05 (trois questions tranchées : listes figées à la pose rafraîchies par les événements ; app v2 = identité entrante seulement ; API = PR sur le dépôt d'équipe) + amendement nouvelle-version. À valider avant plan. Deux points à MESURER avant d'écrire (§5)."
date: 2026-08-05
lié: [2026-08-04-formulaires-jenkins-palier-2-design, adr-076-gitops-api-lifecycle-repo-per-project, adr-078-livrable-self-service-app-wm1015, adr-081-ou-vit-la-decision-humaine, HANDOFF-2026-08-05-FORMULAIRES-JENKINS-PALIER-2]
---

# Palier 3 — formulaires enrichis (spécification)

## En une phrase

Les formulaires du palier 2 deviennent utilisables par un humain qui ne connaît
pas la plomberie — teams et APIs en listes, identité entrante complète (IPs,
certificat) — et le producteur obtient enfin sa porte : un formulaire API qui
ouvre une PR sur le dépôt d'équipe créé à l'onboarding, y compris pour une
nouvelle version d'API existante.

---

## 1. Terrain — mesuré le 2026-08-05

- **Le Jenkins du lab n'a NI Active Choices NI extended-choice** (61 plugins
  relevés par l'API). Un `ChoiceParameterDefinition` est figé à la pose du job.
- **`provision-request.sh` rend un manifeste minimal** : ni `ip_allowlist`, ni
  `public_cert_ref`, ni `cert_rotation` ; et `TENANT=banking-demo` **en dur** —
  le formulaire ne demande même pas l'équipe.
- **Le manifeste producteur (`*.publish.yml`) référence un FICHIER OpenAPI**
  dans le dépôt (`contract:` = chemin) — un formulaire API transporte la spec,
  pas des champs.
- **`POST /apis/{id}/versions` existe** (mock : corps `{newApiVersion}`,
  duplication de la base) mais **le rôle publish ne l'exploite pas**, et
  `retainApplications` (le transport des souscriptions) n'est modélisé nulle
  part.
- Les dépôts d'équipe créés par `team-apply` (palier 2) sont des coquilles :
  squelette `apis/`+`applications/`, aucun webhook — le flux producteur E1
  passe aujourd'hui par un push direct et des jobs par équipe câblés à la main.

## 2. Décisions de cadrage (utilisateur, 2026-08-05)

| Décision | Retenu |
|---|---|
| Listes déroulantes | **Figées à la pose, rafraîchies par les ÉVÉNEMENTS** — zéro plugin. `team-apply` re-pose les formulaires après un onboarding ; la chaîne publish re-pose après une API. La liste ne peut être périmée que si l'événement qui l'aurait rafraîchie a échoué — et il est bruyant |
| Champs app v2 | **Identité entrante seulement** : IPs, certificat, rotation. Auth avancée / backend / description : non exposés, défauts du manifeste |
| Flux producteur | **PR sur le dépôt de l'ÉQUIPE** (ADR-076 : source de vérité producteur), spec collée en zone de texte ; le webhook publish est câblé par team-apply à l'onboarding |
| Nouvelle version | Supportée au formulaire (base en liste + nouveau numéro) et à l'apply par `POST /apis/{id}/versions` (duplication produit), extension ADDITIVE du rôle |

## 3. Les listes — génération et fraîcheur

Le générateur vit dans `setup-team-onboard-jobs.sh` : à la pose d'un job à
listes, il lit les sources de vérité et génère les `<choices>` du XML avant le
POST à Jenkins.

| Liste | Source de vérité | Lecture |
|---|---|---|
| Teams | `providers.<env>.yml` sur **gitea main** (les jobs vivent du Gitea, pas du worktree) | parse YAML au HEAD |
| APIs (`nom@version`) | les manifestes `*.publish.yml` des dépôts d'équipe + `clients/` | balayage GIT — pas la gateway : Git est la source de vérité, et la gateway trial est recyclée |

Rafraîchissement événementiel : `team-apply` (onboarding réussi) re-pose
`app-request` + `api-request` ; `team-publish` (API appliquée) re-pose
`app-request`. Chaque événement qui change la vérité rafraîchit les listes qui
en dépendent — pas de démon, pas de cron.

Gardes : le script de pose ÉCHOUE si une source est illisible (fail-closed,
jamais un job posé avec une liste vide silencieuse) ; la description de chaque
champ-liste dit la limite (« liste au dernier onboarding ; si votre équipe
manque, l'onboarding n'est pas terminé »).

## 4. `app-request` v2

| Champ | Forme | Note |
|---|---|---|
| `TEAM` | liste | remplace le `TENANT=banking-demo` en dur du script |
| `API` | liste `nom@version` | remplace texte libre + API_VER |
| `APP`, `MODE`, `CLIENT_ID` | inchangés | |
| `IP_ALLOWLIST` | texte CSV | single ou plage `A-B` — JAMAIS de CIDR (drop silencieux gateway, dit dans la description) |
| `CERT_PEM` | zone de texte multiligne | PEM public collé |
| `CERT_ROTATION` | choix `replace`/`overlap` | défaut `replace` |

**Le certificat devient un fichier** : `public_cert_ref` est un chemin — le
script écrit le PEM collé dans `clients/provisioned/certs/<app>.pem`, commité
dans la MÊME PR que le manifeste qui le référence. Le certificat est diffé et
revu comme le reste, l'historique Git porte les rotations, et les gardes du
rôle (bloc CERTIFICATE, premier bloc, expiration) s'appliquent sans
modification.

**Gardes réparties comme au palier 2** — à l'entrée du script (refus avant
tout geste Git) : CIDR refusé, `PRIVATE KEY` refusé (on ne commite jamais une
clé privée, même collée par accident), bloc `CERTIFICATE` présent, format des
IPs. À l'apply : le rôle, inchangé.

**Contrat additif** : `REQ_TEAM`, `REQ_IP_ALLOWLIST`, `REQ_CERT_PEM`,
`REQ_CERT_ROTATION` optionnels dans `provision-request.sh` — absents =
comportement actuel octet pour octet. La non-régression de la voie machine
OIG/CLI2 reste la preuve n°1.

## 5. Le flux producteur — `api-request` et `team-publish`

### Le formulaire

| Champ | Forme |
|---|---|
| `ACTION` | choix `créer` / `nouvelle version` |
| `TEAM` | liste |
| `API_NAME` / `API_VERSION` | texte (regex) / défaut `1.0.0` — mode créer |
| `API_BASE` | liste `nom@version` — mode nouvelle version (la base à dupliquer) |
| `NEW_VERSION` | texte — mode nouvelle version |
| `OPENAPI_SPEC` | zone de texte (la spec collée — un bump s'accompagne presque toujours d'une nouvelle spec) |
| `INBOUND_MODE` | choix `jwt`/`oauth2` (défaut `jwt`) |

`api-request.sh` (miroir de `team-request.sh`) : gardes d'entrée (nom, spec
qui parse YAML/JSON ET porte une clé `openapi`/`swagger`) → résolution
`team → repo` depuis providers sur gitea main → clone du dépôt d'équipe →
écrit `apis/<name>.openapi.yaml` + `apis/<name>.publish.yml` (gabarit maison :
`alias_name` et `per_env` issuers/jwks sont PLATEFORME, l'équipe ne saisit pas
la plomberie IdP) → branche `api/<name>-<version>` → PR sur le dépôt d'équipe
→ plan hors ligne (manifest-guard + syntax-check de `apim_publish_api`)
commenté. La décision reste le merge.

### L'aval : UN job générique `team-publish`

Webhook `pull_request` sur les dépôts d'équipe → GWT `closed|merged` + garde
de branche `api/*` — troisième espace de noms, les trois chaînes s'ignorent
par construction. Miroir exact de `team-apply` : pause nominative, garde
d'identité (`assert-merge-identity.sh`), rôle `apim_publish_api`, statut sur
la PR.

**Le point d'autorité** : la team n'est PAS lue dans le payload — elle est
dérivée du DÉPÔT qui a déclenché (Gitea dit lequel, ça ne se forge pas),
croisée contre le mapping `repo → team` de providers. Dépôt non déclaré =
refus. L'inverse exact du défaut E1 (« l'équipe écrit son propre TEAM ») :
l'identité vient de la topologie, validée par le fichier revu.

### Nouvelle version — extension ADDITIVE du rôle

À l'apply, si l'API existe sur la gateway sous un autre numéro :
`POST /apis/{id}/versions {newApiVersion}` (duplication produit — policies et
associations portées), puis mise à jour de la spec par le chemin re-import
existant. Sinon : import initial, comme aujourd'hui. Fail-closed sur
l'ambigu : plusieurs versions candidates comme base → refus explicite.

**DEUX POINTS À MESURER AVANT D'ÉCRIRE** (jamais supposer) :
1. la forme exacte de `retainApplications` sur la VRAIE 10.15 — le mock ne le
   modélise pas, et le transport des souscriptions est tout l'intérêt de la
   ressource vs un import nu ;
2. le piège connu du lab : le *subscribe multi-version* wM a déjà mordu (bug
   labctl tracké). Contre-épreuve exigée : une app souscrite à v1.0 l'est
   encore — ou pas, selon le flag mesuré — après création de la v2.0, relu
   depuis la gateway.

### Les deux extensions qui ferment les boucles

1. `team-apply`, à l'onboarding : enregistre le webhook `pull_request` du
   nouveau dépôt d'équipe vers `team-publish` (idempotent) — le squelette
   ADR-076 devient un dépôt VIVANT.
2. `team-publish`, après un apply réussi : re-pose `app-request` (liste d'APIs
   fraîche).

## 6. Preuves — l'esprit du palier 2, appliqué d'office

Non-régression d'abord : chaînes `onboard/*` et `provision/*` intouchées,
matrice du palier 2 rejouée verte, voie machine OIG/CLI2 octet pour octet.
Puis la matrice du palier : refus avant trace (chaque garde d'entrée, ls-remote
avant/après) ; PR+plan sur le dépôt d'équipe ; dépôt non déclaré refusé ;
merge → publish réel contre le mock ; nouvelle version dupliquée avec la
contre-épreuve souscriptions ; re-pose des listes constatée après chaque
événement ; harnais qui sait rougir ; sondage `ps` AVEC contrôle positif
(leçon du palier 2 : un vert qui n'a pas vu de trafic est un vert vacant).

Leçons câblées d'office : aucun secret en argv (header-file, GIT_CONFIG_*,
heredoc+env) ; `${VAR:?}` sans littéral ; extractions entre appels gardées
(la classe du palier) ; noms de tâches Ansible sans facts runtime (ansible
2.19) ; cibles réseau explicites, jamais 5555.

## 7. Hors périmètre

Auth avancée / backend / description au formulaire app (décision §2) ; le
remplacement de la voie machine (coexistence, comme au palier 2) ; les
environnements rec/int/prod (gardés `ENV_NOT_OPEN`) ; la surface d'approbation
runtime (toujours son spec dédié à venir) ; l'installation d'Active Choices.

## 8. Décisions actées

| Décision | Pourquoi |
|---|---|
| Listes figées + rafraîchissement événementiel | Zéro plugin ; la péremption n'est possible que si l'événement rafraîchisseur a échoué — bruyamment |
| Le certificat est un FICHIER commité dans la PR | Diffé, revu, historisé ; le rôle le consomme sans modification |
| `PRIVATE KEY` refusé à l'entrée | On ne commite jamais une clé privée, même par accident de collage |
| PR producteur sur le dépôt d'ÉQUIPE | ADR-076 ; le dépôt créé à l'onboarding devient vivant |
| UN team-publish générique, team dérivée du dépôt déclencheur | L'identité vient de la topologie (non forgeable), validée par providers — l'inverse du défaut E1 |
| Nouvelle version par `/apis/{id}/versions` | La duplication produit porte policies et associations ; un import nu les perdrait |
| retainApplications et multi-version : MESURER d'abord | Le mock ne les modélise pas, et le piège multi-version a déjà mordu ce lab |
| Contrats additifs partout | La non-régression des chaînes prouvées prime sur la nouveauté |
