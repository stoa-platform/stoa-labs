---
title: "A1 — Le manifeste d'application devient multi-palier : une demande n'écrit que sa clé"
type: design
status: "LIVRÉ 2026-09-02 — amendée après critique adverse de la spec (15 points confirmés) et revue adverse du code (18 points), tous traités ; preuve scripts/test-app-request-a1.sh 71/71"
date: 2026-09-02
lié: [GOAL-cd-applications-2026-09-02, adr-078-livrable-self-service-app-wm1015, adr-081-ou-vit-la-decision-humaine, SPIKE-2026-09-02-cd-applications-convergence-et-souscription]
---

# A1 — Le manifeste devient multi-palier

## Porte (reprise du GOAL, non négociable)

- demande `dev` puis demande `rec` ⇒ le manifeste porte **deux** clés `per_env`, avec des `vault_sub` / `client_id` distincts ;
- contre-épreuve 1 : la demande `rec` ne modifie **aucun octet** hors de `per_env.rec` (diff vide ailleurs) ;
- contre-épreuve 2 : une demande `rec` avec une autre `api` ⇒ `CONTRAT_DIVERGENT`, **aucune branche créée** (distante).

Contrainte mesurée (spike S1-T4) : `PUT …/apis` remplace la liste des souscriptions. « Une application = une API » est figé ici parce que c'est ce qui empêche une convergence de désinscrire en silence (paire brûlée, irréversible en 10.15).

## État courant (relevé)

`scripts/provision-request.sh` **réécrit** `clients/provisioned/applications/<app>.ansible.yml` en entier à chaque demande, depuis un heredoc par mode (`idp` / `internal`). L'identité par palier n'existe qu'en mode `internal` (`per_env.<env>.auth.vault_sub`) ; en mode `idp` la claim `azp` (le `client_id`) est **à la racine** (`auth.claim: { name, value }`), donc trans-palier de fait. Le certificat est un fichier **par application** (`certs/<app>.crt`), pas par palier. La `description` nomme le palier de la demande. Le rôle Ansible `apim_selfservice_app`, lui, sait déjà tout fusionner : manifeste effectif = racine ⊕(récursif) `per_env[apim_ss_env]`, fail-closed `ENV_UNDEFINED` si l'env n'est pas déclaré, et `consumer-auth.yml:61` documente que **poser `claim.value` sous `per_env` suffit**.

Ce qui manque est donc entièrement dans le script de demande : (1) la forme du manifeste, (2) la fusion au lieu de la réécriture, (3) le contrat figé.

## Décisions

### D1 — Forme du manifeste (nouveau contrat machine, les deux modes)

```yaml
---
# <app>.ansible.yml — GÉNÉRÉ par une demande de provisioning (maillon 1).
# Appelant : <caller> (azp). Ne PAS éditer à la main : re-générer via la demande.
# Mode IDP : le client OAuth2 existe côté IdP ; Git porte la CLAIM qui identifie l'app.
# MULTI-PALIER (A1) : la racine est FIGÉE à la première demande ; chaque demande
# n'écrit que sa clé per_env.<env> (identité par palier : claim, IP, cert, clé backend).
apim_ss_app:
  name: "<app>"
  api: "<api>"
  api_version: "<ver>"
  description: "Provisioned via <caller> (idp)"
  contact_emails: []
  team: "<team>"                      # seulement si fournie
  enforce: []
  auth:
    mode: "idp"
    server_alias: "KeycloakStoaLab"
    audience: "<aud>"
    claim: { name: "azp" }            # le NOM seul ; la VALEUR est par palier
  per_env:
    dev: { auth: { claim: { value: "<client_id-dev>" } }, ip_allowlist: [...], public_cert_ref: "...", cert_rotation: "...", backend_key_ref: "...", backend_key_field: "..." }
    rec: { auth: { claim: { value: "<client_id-rec>" } } }
```

Mode `internal` : racine inchangée (pas de `server_alias`, pas de `claim`), `per_env.<env>: { auth: { vault_sub: "deploy/<tenant>/apps/<app>/<env>/oauth-client" }, … }` — déjà la forme actuelle.

- **Trans-paliers, figés à la première demande** : `name`, `api`, `api_version`, `auth.audience`, `auth.mode`, `team` (la liste du GOAL, ni plus ni moins). `contact_emails`, `enforce`, `server_alias`, `description` et l'en-tête sont posés à la création et **jamais retouchés** (une demande ultérieure ne les lit ni ne les compare).
- **Par palier** (une seule ligne YAML flow, `    <env>: { … }`) : `auth.claim.value` (idp) ou `auth.vault_sub` (internal), puis `ip_allowlist`, `public_cert_ref`, `cert_rotation`, `backend_key_ref`, `backend_key_field` — chacun seulement si fourni, même rendu inline qu'aujourd'hui (les golden « mono-IP » restent vrais au caractère près).
- `cert_rotation` **descend** dans `per_env` : c'est une propriété de la rotation d'un certificat, qui est par palier ; le rôle le lit après fusion (`apim_ss_app.cert_rotation`, `tasks/main.yml:222`), donc la surcharge par palier est prise sans changement du rôle.
- La `description` cesse de nommer le palier (`Provisioned via <caller> (<mode>)`) : figée à la création, elle mentirait dès le deuxième palier.
- **Certificat par palier** : `clients/provisioned/certs/<app>-<env>.crt` (au lieu de `<app>.crt`). Sans cela, une demande `rec` avec son propre certificat **écraserait** celui de `dev` — le contraire de « n'écrit que sa clé ».

### D2 — Fusion TEXTUELLE, jamais une re-sérialisation YAML

Le manifeste existant (lu sur `GIT_BASE`, après le clone) n'est **jamais** rechargé puis ré-émis par PyYAML : un `yaml.dump` perd les commentaires, l'ordre, les guillemets et le style flow — la contre-épreuve « aucun octet hors de `per_env.<env>` » serait violée par construction. La fusion opère sur les lignes :

1. localiser la tête du bloc par regex ancrée : `^  per_env:\s*(#.*)?$` (nue ou commentée) ou `^  per_env:\s*\{\s*\}\s*(#.*)?$` (`per_env: {}` en flow vide, que le rôle accepte — convertie en bloc) ; un `per_env: { dev: … }` flow **non vide** sur une ligne est refusé nommément (`MANIFESTE_INVALIDE … forme non fusionnable`) — jamais une clé dupliquée en silence, PyYAML gardant la dernière sans rien dire ; le bloc = les lignes suivantes indentées d'au moins 4 espaces ;
2. si une ligne matche `^    <env>:(\s|$)` dans le bloc → **remplacée** en place (re-demande sur le même palier : IP ajoutée, cert tourné) — jamais un match par sous-chaîne (un commentaire `    # rec: …` ne matche pas) ; un palier écrit en style block (`    dev:` + enfants à 6 espaces) est remplacé puis refusé par l'étape 5 (sous-lignes orphelines ⇒ le YAML ne se relit plus), fichier intact ;
3. sinon → **insérée** en fin de bloc ;
4. si le bloc `per_env` est absent → créé **en fin du mapping `apim_ss_app`** (avant la première clé racine suivante), pas en fin de fichier. Ce cas n'arrive pas pour un manifeste rendu par ce script (D1 : `per_env` est toujours présent) ; il est gardé pour un manifeste édité à la main.
5. **Auto-vérification fail-closed** : le fichier fusionné est rechargé et `apim_ss_app.per_env[<env>]` doit être égal au mapping demandé ; sinon `MANIFESTE_INVALIDE`, rien n'est écrit. Écriture atomique (temporaire + `os.replace`).
6. **Chargeur sans typage implicite** (`yaml.BaseLoader`) partout : mesuré, `safe_load` relit `api_version: 1.10` non quoté comme `1.1` et produisait une divergence mensongère.

Le fichier n'est réécrit **en entier** (heredoc, comme aujourd'hui) que s'il **n'existe pas** sur `GIT_BASE` : première demande = création.

### D3 — Contrat figé : lecture, comparaison, refus nommé

Avant tout `git checkout -B` (donc avant toute branche, locale ou distante), si le manifeste existe :

- lecture par PyYAML (présent : Jenkins python 3.13 + PyYAML 6.0.2, poste 3.11 + 6.0.3) ;
- comparaison champ à champ avec la demande : `name` (comparé explicitement à `REQ_APP` — un fichier dont `name:` diffère du nom de fichier fusionnerait sous une AUTRE application), `api`, `api_version`, `auth.audience`, `auth.mode`, `team` ;
- **toute** divergence est listée (pas seulement la première) : `REFUS: CONTRAT_DIVERGENT : api : manifeste='accounts-read' demande='payments' ; …` — exit 2 ;
- le `mode` dérive de `REQ_CALLER` (table caller→mode) : un appelant `cli2-*` qui redemande une app `idp` diverge → refus. C'est voulu : changer de mode d'authentification est une nouvelle application. **Limite mesurée à la critique** : sur la voie machine, `REQ_CALLER` est aujourd'hui `$.caller` du **body** (`provisioning-request.job.xml:17`), pas une identité injectée par la gateway depuis `azp` — le « anti-spoof » du commentaire historique du script n'est pas tenu ; c'est l'objet de la step d'APIsation (mémoire `apisation-declencheur-gateway`). A1 filtre `REQ_CALLER` (`CALLER_INVALID`, classe `[A-Za-z0-9._:@-]`) parce qu'il est interpolé dans l'en-tête et la description du manifeste.
- **Bornes à la lecture** : tout ce que la lib rend (et que le script peut hériter) est vérifié contre la même classe que les gardes d'entrée — `api`/`api_version` `[A-Za-z0-9._-]`, `audience` `[A-Za-z0-9._:/-]`, `mode` `idp|internal`, `team` `^[a-z0-9][a-z0-9-]{1,30}$`, clés `per_env` `[A-Za-z0-9_-]` — sinon `MANIFESTE_INVALIDE`. Mesuré : une `team: ".*"` posée à la main était héritée sans la garde de format (qui ne voit que la valeur fournie) puis interpolée comme regex dans la garde providers. La garde providers passe à `grep -Fxq` (chaîne fixe, ligne entière).
- **Identité du palier obligatoire dans sa clé** : `idp` ⇒ chaque `per_env.<e>.auth.claim.value` non vide ; `internal` ⇒ chaque `per_env.<e>.auth.vault_sub` non vide — sinon `MANIFESTE_INVALIDE` (sans claim.value, le rôle poserait une stratégie `clientId = nom de l'app` avant son propre fail-closed, `consumer-auth.yml:352` puis `:461`).
- **Ordre des refus** (propriété du refus nommé, pas détail d'implémentation) : clone → lecture (`MANIFESTE_*`) → héritage (D4) → contrat (`CONTRAT_DIVERGENT`) → garde providers sur la team **effective** (`PROVIDERS_MISSING` / `TEAM_NOT_DECLARED`) → `git checkout -B`.

### D4 — Héritage des défauts de la demande (pas des champs de la demande)

Trois entrées ont un **défaut** dérivé quand elles sont absentes (`REQ_API_VER` → `1.0.0`, `REQ_AUDIENCE` → `REQ_API`, `REQ_TEAM` → tenant `banking-demo`). Sur un manifeste existant, un défaut dérivé « à froid » produirait des divergences mensongères (dev demandé en `2.0.0`, rec sans version ⇒ `1.0.0` ≠ `2.0.0`). Règle : **absent ⇒ hérité du manifeste** (ou le défaut d'aujourd'hui si le manifeste n'existe pas) ; **fourni ⇒ comparé** (D3). La voie humaine (`Jenkinsfile.app-request`) fournit toujours `REQ_API_VER` explicitement (choix `api@version`), donc elle n'hérite jamais — cohérent : ce qu'un humain a saisi est comparé.

Pour `team` héritée : la garde `TEAM_NOT_DECLARED` (présence dans `providers.<env>.yml` **du palier demandé**) s'applique à la valeur héritée comme à une valeur fournie, et `TENANT` suit la team héritée (le `vault_sub` interne du palier tombe sous le tenant de la team, jamais sous le défaut). La garde de format hors ligne (`TEAM_NAME_INVALID`) ne voit que la valeur fournie ; la valeur héritée est bornée par la lib à la lecture (D3). **Prérequis nommé** : `providers.<env>.yml` doit exister sur `GIT_BASE` pour chaque palier hors-prod où une application avec `team` est demandée — dans le lab seul `providers.dev.yml` existe (self-service dev-only, GOAL du 2026-08-26), donc toute demande avec team hors dev meurt `PROVIDERS_MISSING`, fail-closed ; « fichier absent = OK » n'est pas une option. Le corps de PR nomme la team héritée (« heritee du manifeste, figee a la premiere demande »).

### D5 — Manifeste hérité de l'ancienne forme : refus, pas migration devinée

Un manifeste `idp` portant `auth.claim.value` à la racine (forme d'avant A1, ex. `paiements-sepa.ansible.yml`) est refusé : `MANIFESTE_LEGACY : claim.value à la racine (forme mono-palier d'avant A1) — migrer la valeur sous per_env.<palier>.auth.claim.value`. On ne devine pas le palier d'une valeur (`paiements-sepa-dev` *ressemble* à dev — ce n'est pas une preuve). Le seul manifeste réel du dépôt (`paiements-sepa`) est **migré à la main dans le même commit** — et le geste n'est complet qu'une fois ce commit **poussé sur `gitea` `ci/stoa-labs` main**, la lignée que lit le CI du lab (mémoire `trois-depots-ci-gitea`) : tant que ce push n'est pas fait, une demande `paiements-sepa` sur le lab est refusée `MANIFESTE_LEGACY`.

### D6 — Idempotence et re-demande

- même demande rejouée **avant merge** : la branche `provision/<app>-<env>` est recréée depuis `GIT_BASE` à chaque demande, donc sans geste particulier un rejeu produirait un nouveau commit (même arbre, autre date) et un push forcé — un `synchronized` et un plan de plus pour rien. A1 fetche la branche distante (`git fetch --depth 1`, lecture anonyme comme le clone) et compare son arbre à l'index rendu (`git diff --cached --quiet FETCH_HEAD -- .`) : identique ⇒ ni commit ni push, PR réutilisée (même SHA, épreuve C.4). Limite : « base immobile » — si `GIT_BASE` a bougé entre-temps, l'arbre diffère et la branche est re-poussée sur la nouvelle base (correct) ;
- même demande rejouée **après merge** (la base porte déjà `per_env.<env>`, tête éventuellement supprimée) : l'index est identique à la base ⇒ sortie 0 « déjà mergée sur <base> — aucune PR à ouvrir », **sans** `POST /pulls` (mesuré : sur une tête supprimée après merge, Gitea rend 404 ⇒ rc 1) ;
- re-demande sur un palier déjà déclaré avec d'autres valeurs (IP, cert) ⇒ la ligne est remplacée, commit + push forcé sur `provision/<app>-<env>` (branche machine-owned, comportement existant).

### D7 — Corps de PR

Une ligne de plus, visible du valideur : `- manifeste : première demande (créé)` ou `- manifeste : per_env.<env> fusionné — paliers déjà déclarés : dev, rec`. Aucune autre modification du corps.

### D8 — Où vit le code

- `scripts/lib/app-manifest.sh` — bibliothèque bash (compatible bash 3.2 / macOS, comme les tests) exposant trois fonctions, chacune un `python3 - <<'PY'` :
  - `app_manifest_read <fichier>` → imprime `MAN_API=…`, `MAN_API_VER=…`, `MAN_AUDIENCE=…`, `MAN_MODE=…`, `MAN_TEAM=…`, `MAN_ENVS=…` (valeurs bornées, D3) ; rc 2 + `MANIFESTE_LEGACY` / `MANIFESTE_INVALIDE` (la lib `return`, jamais `exit` : elle est sourcée) ;
  - `app_manifest_check_contract <fichier> <name> <api> <api_version> <audience> <mode> <team>` → rc 0, ou rc 2 + `CONTRAT_DIVERGENT : …` (toutes les divergences) ;
  - `app_manifest_merge_env <fichier> <env> '<mapping YAML flow, accolades incluses>'` → réécrit le fichier en place (D2, écriture atomique), rc 2 + `MANIFESTE_INVALIDE` sur auto-vérification échouée. Le mapping passe par l'environnement, pas par argv.
- `scripts/provision-request.sh` — appelle la lib après le clone ; heredocs conservés pour la création (forme D1) ; la ligne `per_env` est rendue par UNE variable commune aux deux modes.
- Rien ne change dans le rôle, l'engine Python, les jobs Jenkins, le formulaire.

### D9 — Preuve

`scripts/test-app-request-a1.sh`, sur le patron des suites v2/v3 :

- **Section A (hors ligne, lib seule)** : fusion sur fichiers locaux — insertion, remplacement, bloc absent, octets hors ligne intacts (diff), auto-vérification (mapping cassé ⇒ `MANIFESTE_INVALIDE`) ; contrat — divergence unique, divergences multiples toutes listées, `team` absente vs présente, legacy refusé ; lecture — envs déclarés, valeurs héritables.
- **Section B (hors ligne, script)** : compilation `bash -n` + shellcheck de la lib, source de la lib, et les gardes neuves qui sortent AVANT le clone (`AUDIENCE_INVALID`, `API_VERSION_INVALID`, `CALLER_INVALID`, avec la contre-épreuve `jenkins-form:oscar@bank.example` accepté). Le refus `CONTRAT_DIVERGENT` est prouvé en C ; il serait prouvable hors ligne avec le stub smart-HTTP (`git http-backend`) déjà présent dans le dépôt — non fait ici, la suite C le couvre par builds réels contre Gitea.
- **Section C (contre le Gitea réel du lab, `poc-gitea:13000`)** — branche de base **jetable** `p3a1-base-<ts>` créée depuis `main` par l'API, passée en `GIT_BASE` à chaque appel, pour ne jamais polluer `main` :
  1. demande `dev` (idp) ⇒ PR, manifeste forme D1 ;
  2. « merge simulé » : **tous les fichiers de la PR dev** (manifeste + éventuel `certs/<app>-dev.crt`, et pour C.9 une fixture `ansible/providers.rec.yml`) sont **posés sur la base** par l'API `contents` (pas de merge de PR : l'événement `closed|merged` déclencherait `provision-apply` sur le Jenkins du lab, qui resterait en attente d'`input`) ;
  3. demande `rec` ⇒ le manifeste de `provision/<app>-rec` porte `per_env.dev` **et** `per_env.rec`, `client_id` distincts ; **diff** base→rec = exactement une ligne ajoutée (`    rec: …`) — la porte et la contre-épreuve 1 ;
  4. demande `rec` rejouée ⇒ même SHA de branche (idempotence) ; puis, la base portant `per_env.rec` et la tête supprimée, rejeu ⇒ exit 0 « déjà mergée », aucune PR, aucune branche ;
  5. demande sur un palier **encore non demandé** (`int`) avec `REQ_API` différente ⇒ exit 2, `CONTRAT_DIVERGENT`, `GET /branches/provision/<app>-int` → 404 (contre-épreuve 2) ; `REQ_API_VER` absente ⇒ héritée (pas de divergence) ; `REQ_API_VER` fournie différente ⇒ divergence ; appelant `cli2-*` ⇒ divergence sur `mode` ;
  6. même parcours en mode `internal` ⇒ `vault_sub` distincts (`…/dev/…`, `…/rec/…`) ;
  7. certificats : `dev` avec cert A puis `rec` avec cert B ⇒ deux fichiers `<app>-dev.crt`, `<app>-rec.crt`, celui de dev intact ;
  8. legacy : manifeste ancienne forme posé sur la base par l'API ⇒ demande `rec` refusée `MANIFESTE_LEGACY`, aucune branche ;
  9. team : `dev` avec team, fixture `providers.rec.yml` sur la base, `rec` sans team ⇒ héritée, garde passée, ligne posée, PR nommant la team héritée ; team fournie différente ⇒ `CONTRAT_DIVERGENT` ; `int` sans team ⇒ héritée puis `PROVIDERS_MISSING`, aucune branche ; mode `internal` + team héritée ⇒ `vault_sub` sous le tenant de la team.
  Nettoyage : **mesuré (Gitea 1.22.6, `CloseBranchPulls`)**, supprimer la base ou une tête **ferme** les PR qui la visent — `closed` avec `merged=false`, filtré par `provision-apply` (`closed|true`). La suite ne laisse donc aucune PR ouverte (contrairement à v2/v3, qui visent `main`).
- **Golden files** : `scripts/testdata/app-request-v2/golden-*.ansible.yml` sont **régénérés** (geste explicite prévu par l'en-tête de la section C de v2 : le contrat machine change intentionnellement — claim par palier, description sans palier, en-tête A1). Les suites v2 et v3 doivent rester vertes avec ces goldens ; v2 est mise à jour pour le chemin de certificat par palier ; v2 et v3 reçoivent une **précondition nommée** (l'app golden ne doit pas exister sur `main`, sinon le script fusionnerait au lieu de créer et le diff mentirait sur la cause).

## Ce que A1 ne fait pas

- ne touche pas à l'apply (A2 : SHA mergé), au credential (A3), à l'axe déployeur (A4), à la porte API (A5), au rollback (A6), au terminus (A7) ;
- ne convertit aucun `job.xml` (A0) — seule la **chaîne d'aide** du paramètre certificat de `ci/jenkins/app-request.job.xml` est corrigée (`<app>-<env>.crt`, à re-poser via `scripts/setup-team-onboard-jobs.sh`) ; ne modifie ni `Jenkinsfile.app-request` ni le rôle ni l'engine ;
- ne refuse pas un `client_id` identique sur deux paliers (décision client n°1 : identité trans-palier possible, le mécanisme la supporte) ;
- ne migre automatiquement aucun manifeste ancien (D5).
