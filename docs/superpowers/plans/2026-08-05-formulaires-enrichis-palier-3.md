# Palier 3 — formulaires enrichis : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Listes vivantes (teams, APIs) dans les formulaires, identité entrante complète (IPs, certificat) sur app-request, et la porte du producteur — api-request → PR sur le dépôt d'équipe → team-publish au merge, nouvelle version comprise.

**Architecture:** Le générateur de listes vit dans le script de pose (choices générées depuis les sources de vérité GIT au moment du POST à Jenkins), et les événements qui changent la vérité re-posent les formulaires. Le flux producteur est le miroir exact du flux onboarding (`api/*` troisième espace de noms de branches ; team-publish miroir de team-apply), l'autorité venant de la topologie (le dépôt qui déclenche) croisée avec `providers.<env>.yml`. Tout est additif aux chaînes prouvées.

**Tech Stack:** bash portable, jobs Jenkins (CpsFlowDefinition + GWT), API Gitea (urllib), Ansible (rôles existants + extension `apim_publish_api`), Go stdlib (mock).

**Spec :** `docs/superpowers/specs/2026-08-05-formulaires-enrichis-palier-3-design.md`
**Base :** branche `feat/onboarding-equipe-palier-1`, tête `e4b234b`.

## Global Constraints

- **Aucun secret en argv** — la classe corrigée 4× au palier 2 : header-file (`vhdr`), `GIT_CONFIG_COUNT/KEY/VALUE_0` pour git, heredoc+`os.environ` pour python, `grep -Ff fichier` — JAMAIS `cmd "$SECRET"`. Vérifiable `ps -Aww` avec CONTRÔLE POSITIF (un sondage qui n'a pas vu de trafic est un vert vacant → FAIL).
- **Aucun littéral `*PASS*`/`*SECRET*`/`*TOKEN*=`** dans un `.sh` — `${VAR:?}` toujours, la garde du dépôt scanne (clé = fichier,VARIABLE).
- **Le port 5555 est la VRAIE gateway du lab, EN SERVICE** — les mesures de la Task 1 l'utilisent en LECTURE et sur des objets JETABLES uniquement (protocole F4 : créer/mesurer/supprimer, jamais toucher les APIs qui servent) ; tout le reste passe par les mocks.
- **Extractions gardées** : tout parse/extraction entre deux appels vérifiés porte son `|| fail` ET distingue « vide légitime » de « parse cassé » (marqueur explicite) — la classe Critical du palier 2.
- **ansible-core 2.19** (conteneur Jenkins) : aucun `name:` de tâche/bloc référençant un fact `set_fact` — variables d'entrée seulement.
- **Ne JAMAIS modifier les chaînes prouvées** autrement qu'additivement ; la non-régression (diff-vide octet pour octet des voies machine, matrice palier 2 rejouée) prime sur la nouveauté.
- **Contre-épreuve pour chaque garde** (rouge d'abord), **harnais qui sait rougir**, **échecs nommés greppables**, **`sed -i` portable** (double forme BSD/GNU), commentaires POURQUOI.
- Racine : chemins relatifs à `poc-control-plane-federation/`.

---

## Structure des fichiers

| Fichier | Responsabilité |
|---|---|
| `scripts/spike-api-versions-1015.sh` | **créé** (Task 1) — mesures versions/retainApplications sur la vraie 10.15, jetable-propre |
| `mocks/webmethods/admin.go` + `admin_versions_test.go` | **modifié/créé** (Task 2) — multipart POST /apis + retainApplications selon mesures |
| `scripts/lib/generate-choices.sh` | **créé** (Task 3) — génération des `<choices>` depuis les sources Git, fail-closed |
| `scripts/setup-team-onboard-jobs.sh` | **modifié** (Task 3) — substitution des placeholders à la pose |
| `ci/jenkins/app-request.job.xml` | **modifié** (Task 4) — listes + identité entrante |
| `scripts/provision-request.sh` | **modifié** (Task 4) — REQ_TEAM/IPs/CERT→fichier/rotation, additif |
| `gateways/templates/publish.yml.tmpl` | **créé** (Task 5) — gabarit publish, plomberie IdP plateforme |
| `scripts/api-request.sh` + `ci/jenkins/api-request.job.xml` | **créés** (Task 5) — la porte producteur |
| `ansible/roles/apim_publish_api/tasks/version.yml` (+ main.yml) | **créés/modifié** (Task 6) — create-or-version |
| `scripts/team-publish.sh` + `ci/jenkins/team-publish.job.xml` + `scripts/test-team-publish-wiring.sh` | **créés** (Task 7) — l'aval producteur |
| `scripts/team-apply.sh` | **modifié** (Task 7) — webhook du dépôt d'équipe + re-pose des formulaires |
| `scripts/test-producer-chain.sh` | **créé** (Task 8) — la matrice du palier |

---

### Task 1: MESURER — versions et souscriptions sur la vraie 10.15

Rien ne s'écrit dans le rôle avant ces mesures. Le mock dit que `/versions` duplique ; il ne dit ni la forme de `retainApplications`, ni ce que deviennent les souscriptions — et le piège multi-version a déjà mordu ce lab (bug labctl tracké).

**Files:**
- Create: `scripts/spike-api-versions-1015.sh`

**Interfaces:**
- Consumes: la vraie gateway (`localhost:5555`, `Administrator:manage` — lecture + objets JETABLES uniquement, protocole F4 : suffixe `-p3spike`, teardown en trap).
- Produces: des FAITS consignés dans le rapport de tâche ET dans le spec (§5, statut mis à jour) : forme exacte du corps de `POST /apis/{id}/versions` (retainApplications ? nom ? booléen/chaîne ?), ce qui est copié (policies ? associations ? scopes ?), et le comportement des souscriptions d'une app entre v1 et v2.

- [ ] **Step 1: Écrire le spike**

```bash
#!/usr/bin/env bash
# spike-api-versions-1015.sh — MESURE (jamais suppose) le comportement de
# POST /apis/{id}/versions sur la vraie 10.15 du lab.
#
# Protocole F4 : tout objet créé porte le suffixe -p3spike et meurt dans le
# trap EXIT. Les APIs qui servent du trafic ne sont JAMAIS touchées.
#
# Questions auxquelles ce script répond par des mesures :
#   M1. Quel corps accepte /versions ? {newApiVersion} seul ? retainApplications
#       existe-t-il (nom exact, type) ? → tenter les deux formes, lire les codes.
#   M2. La nouvelle version porte-t-elle les policies de la base ? (GET les deux,
#       comparer policies[])
#   M3. Une app souscrite à la v1 est-elle souscrite à la v2 après duplication —
#       avec et sans le flag si M1 le révèle ? (le piège multi-version du lab)
set -uo pipefail
WM="${WM_GATEWAY_URL:?WM_GATEWAY_URL requis — dire sa cible est volontaire}"
A="${WM_ADMIN_CREDS:?WM_ADMIN_CREDS requis (user:pass)}"
# … création API jetable (POST /apis JSON — le dialecte accepté, cf. mock),
#   app jetable souscrite à v1, puis :
#   - POST /apis/$ID/versions '{"newApiVersion":"2.0"}'          → code + corps
#   - si 4xx : retenter avec {"newApiVersion":"2.0","retainApplications":true}
#     puis les variantes plausibles (retainApplications en chaîne, apiVersion…)
#   - GET des deux versions : diff des policies[], des applications associées
#   - GET /applications/$APP : quelles apiIDs après duplication ?
# teardown : DELETE app, DELETE les deux versions, re-GET 404.
```

Complète avec les appels réels (motif curl+python3 des spikes existants, header
Basic). Chaque mesure imprime `M<n>: <fait observé>` — le rapport est la sortie.

- [ ] **Step 2: Exécuter contre la vraie gateway, consigner**

```bash
WM_GATEWAY_URL=http://localhost:5555 WM_ADMIN_CREDS='Administrator:manage' \
  bash scripts/spike-api-versions-1015.sh | tee /tmp/p3-spike.out
```

Teardown vérifié (re-GET 404 sur tout ce qui a été créé). Puis mets à jour le
spec §5 : remplace « À MESURER » par les faits, datés.

- [ ] **Step 3: Commit (script + spec à jour)**

```bash
git add scripts/spike-api-versions-1015.sh docs/superpowers/specs/2026-08-05-formulaires-enrichis-palier-3-design.md
git commit -m "spike(p3): versions/retainApplications mesurés sur la vraie 10.15

Le mock dit que /versions duplique ; il ne disait ni la forme du flag ni le
sort des souscriptions — et le piège multi-version a déjà mordu ce lab."
```

---

### Task 2: Mock — multipart POST /apis + sémantique versions mesurée

Deux gaps connus bloquent les preuves hors ligne du producteur : le rôle publish envoie du **multipart** que le mock refuse (400, consigné depuis le palier 2), et `createVersionAPI` ne modélise pas ce que la Task 1 a mesuré.

**Files:**
- Modify: `mocks/webmethods/admin.go` (createAPI : accepter multipart ; createVersionAPI : aligner sur les mesures)
- Create: `mocks/webmethods/admin_versions_test.go`

**Interfaces:**
- Consumes: les faits de la Task 1 (verbatim — le mock reproduit le produit MESURÉ, pas une idée du produit).
- Produces: `POST /rest/apigateway/apis` accepte `multipart/form-data` (champs `apiDefinition` fichier + `apiName`/`apiVersion`/`type` — relève la forme EXACTE que `apim_publish_api` envoie : `grep -n 'multipart\|body_format\|src=' ansible/roles/apim_publish_api/tasks/main.yml`) ; `createVersionAPI` copie ce que le produit copie et applique le flag mesuré.

- [ ] **Step 1: Relever la forme multipart réelle envoyée par le rôle** (commande ci-dessus — le mock doit accepter CE que le rôle envoie, pas un multipart théorique).
- [ ] **Step 2: Tests d'abord** — `admin_versions_test.go` : (a) POST multipart → 201 + API relue ; (b) POST /versions avec le corps mesuré → la duplication copie exactement ce que M2 a établi ; (c) souscriptions : comportement M3 reproduit, AVEC contre-témoin (le test qui échouerait si le mock était inerte).
- [ ] **Step 3: Implémenter, `go test ./...` sans régression** (36+ tests existants).
- [ ] **Step 4: Contre-épreuve d'intégration** : le VRAI rôle `apim_publish_api` joué contre le mock (`go run .`, port libre, jamais 5555) → l'import multipart passe désormais (c'était 400). C'est la preuve que le gap est fermé pour la Task 7.
- [ ] **Step 5: Commit** — `test(mock): multipart /apis + sémantique /versions mesurée — les preuves producteur deviennent possibles hors ligne`.

---

### Task 3: Le générateur de listes + la re-pose événementielle

**Files:**
- Create: `scripts/lib/generate-choices.sh`
- Modify: `scripts/setup-team-onboard-jobs.sh`

**Interfaces:**
- Consumes: `providers.<env>.yml` lu sur **gitea main** (`git ls-remote`+`git archive` ou clone shallow — pas le worktree) ; les `apis/*.publish.yml` des dépôts d'équipe déclarés + `clients/`.
- Produces: `generate_choices_teams()` et `generate_choices_apis()` → fragments XML `<string>…</string>` ; les XML des jobs portent des placeholders `<!--CHOICES:TEAMS-->` / `<!--CHOICES:APIS-->` substitués à la pose (sed portable double-forme) ; `setup-team-onboard-jobs.sh` échoue si une source est illisible OU si une liste est vide (fail-closed : jamais un formulaire aux choix vides silencieux).

- [ ] **Step 1: Écrire la lib** — lecture gitea main (URL/token par env, `${:?}`), parse YAML par python3-heredoc (jamais de secret en argv), sortie = fragments XML échappés (`&`/`<` — un nom d'équipe ne peut pas casser le XML : la regex du palier 1 l'empêche déjà, mais échappe quand même, défense en profondeur).
- [ ] **Step 2: Contre-épreuves** : providers à 2 équipes → 2 `<string>` ; fichier illisible → `ko` AVANT tout POST Jenkins ; liste vide → `ko` ; nom hostile simulé → échappé.
- [ ] **Step 3: Brancher dans la pose** — substitution des placeholders au moment du POST config.xml ; la pose des jobs SANS listes (team-request, team-apply) est inchangée octet pour octet.
- [ ] **Step 4: La re-pose événementielle** — dans `team-apply.sh`, après le succès de l'onboarding : appel de la pose pour `app-request`+`api-request` (listes fraîches). Best-effort BRUYANT : un échec de re-pose n'annule pas l'onboarding (il est fait) mais est nommé dans le commentaire PR (`⚠ listes non rafraîchies — relancer setup-team-onboard-jobs.sh`).
- [ ] **Step 5: Commit.**

---

### Task 4: app-request v2 — listes + identité entrante

**Files:**
- Modify: `ci/jenkins/app-request.job.xml`, `scripts/provision-request.sh`

**Interfaces:**
- Consumes: placeholders de la Task 3.
- Produces: champs `TEAM`(liste), `API`(liste `nom@version` → split côté job en REQ_API/REQ_API_VER), `IP_ALLOWLIST`, `CERT_PEM`(textarea), `CERT_ROTATION`(choix) ; `provision-request.sh` accepte `REQ_TEAM`, `REQ_IP_ALLOWLIST`, `REQ_CERT_PEM`, `REQ_CERT_ROTATION` — **tous optionnels, absents = comportement actuel octet pour octet**.

- [ ] **Step 1: Gardes d'entrée dans le script** (AVANT tout geste Git, échecs nommés) :

```bash
# CIDR : la gateway le drop EN SILENCE — refuser ici, bruyamment.
case "$REQ_IP_ALLOWLIST" in */*) fail "IP_CIDR_REFUSE : CIDR non supporté (drop silencieux gateway) — single ou plage A-B";; esac
# On ne commite JAMAIS une clé privée — même collée par accident.
case "$REQ_CERT_PEM" in *"PRIVATE KEY"*) fail "CERT_PRIVATE_KEY_REFUSE";; esac
[ -n "$REQ_CERT_PEM" ] && { printf '%s' "$REQ_CERT_PEM" | grep -q -- '-----BEGIN CERTIFICATE-----' || fail "CERT_SANS_BLOC : PEM public X.509 attendu"; }
case "${REQ_CERT_ROTATION:-replace}" in replace|overlap) ;; *) fail "CERT_ROTATION_INVALIDE : replace|overlap";; esac
# REQ_TEAM : déclaré dans providers (même garde que team-request) — sinon TENANT
# reste le défaut actuel (voie machine intacte).
```

- [ ] **Step 2: Le certificat devient un fichier dans la PR** — écrit à `clients/provisioned/certs/${REQ_APP}.pem` dans le clone, `public_cert_ref` du manifeste pointe dessus (chemin RELATIF au dépôt, relève comment le rôle résout `public_cert_ref` — palier 1, `cert-der.yml` — et donne le chemin sous la forme qu'il attend). Manifeste : blocs `ip_allowlist`/`public_cert_ref`/`cert_rotation` rendus SEULEMENT si fournis.
- [ ] **Step 3: Le job XML** — placeholders listes, split `nom@version`, textarea (`hudson.model.TextParameterDefinition` pour le PEM — multiligne, PAS StringParameter), descriptions COMPLÈTES (tout ce qui sera refusé y est annoncé : CIDR, clé privée, formats).
- [ ] **Step 4: NON-RÉGRESSION D'ABORD** — les deux voies machine (`REQ_CALLER=oig-provisioner` / `cli2-provisioner`, sans aucun REQ_ nouveau) → manifeste octet pour octet identique à avant (diff vide, méthode du palier 2 T6). C'est la preuve n°1.
- [ ] **Step 5: Nominal enrichi** — formulaire complet (scratch Gitea) → la PR porte manifeste + `.pem`, le plan existant la commente ; contre-épreuves des 4 gardes (rouge, ls-remote intact).
- [ ] **Step 6: Repose du job, vérif API, commit.**

---

### Task 5: api-request — la porte du producteur

**Files:**
- Create: `gateways/templates/publish.yml.tmpl`, `scripts/api-request.sh`, `ci/jenkins/api-request.job.xml`
- Modify: `scripts/setup-team-onboard-jobs.sh` (JOBS += api-request)

**Interfaces:**
- Consumes: providers (team→repo) sur gitea main ; le gabarit ; les gardes hors ligne de `apim_publish_api` (manifest-guard + syntax-check) comme PLAN.
- Produces: PR `api/<name>-<version>` sur le DÉPÔT D'ÉQUIPE portant `apis/<name>.openapi.yaml` + `apis/<name>.publish.yml`, plan commenté. Champs : `ACTION`(créer/nouvelle version), `TEAM`(liste), `API_NAME`/`API_VERSION`, `API_BASE`(liste, mode version), `NEW_VERSION`, `OPENAPI_SPEC`(textarea), `INBOUND_MODE`(jwt/oauth2).

- [ ] **Step 1: Le gabarit** — reprend la forme de `clients/_example/apis/accounts-read.publish.yml` : `name`/`version`/`contract` substitués ; `inbound.alias_name`, `mode`, `per_env.{dev,rec,int,prod}.inbound.{issuer,jwks_uri}` = les valeurs PLATEFORME du lab (relevées de l'exemple). L'équipe ne saisit JAMAIS la plomberie IdP — commentaire du gabarit le dit.
- [ ] **Step 2: Le script** (miroir de team-request.sh — reprends sa structure, ses motifs de gardes, son commentaire-plan) :
  - gardes : `API_NAME` regex `^[a-z0-9][a-z0-9-]{1,30}$` (même classe), version `^[0-9]+\.[0-9]+(\.[0-9]+)?$`, spec parse (python3-heredoc : `yaml.safe_load` OU `json.loads`) ET clé `openapi`/`swagger` présente → `SPEC_INVALIDE` sinon ; mode version : `API_BASE` requis, `NEW_VERSION` ≠ version de base, cohérence nom ;
  - team→repo depuis providers gitea main (repo vide `""` → `REPO_MANQUANT : onboarder d'abord un dépôt pour cette équipe`) ;
  - clone du dépôt d'ÉQUIPE, écrit spec+manifeste, branche `api/…`, push (GIT_CONFIG_*, jamais URL-token), PR, plan hors ligne (`ansible-playbook ansible/test-publish-guards.yml -e pub_manifest_path=… ` — relève l'appel exact des gardes publish) commenté avec la hiérarchie fatal>msg>tail-3 (la leçon, appliquée d'entrée cette fois).
- [ ] **Step 3: Le job XML** — motif team-request, placeholders listes (TEAM, API_BASE), textarea pour la spec.
- [ ] **Step 4: Contre-épreuves** — chaque garde rouge sans trace (ls-remote sur le dépôt d'équipe) ; nominal → PR réelle sur un dépôt d'équipe scratch (onboardé pour l'occasion via la chaîne du palier 2 — c'est aussi une preuve de non-régression), plan ✅ ; mode nouvelle-version → manifeste version bumpée + spec neuve dans la PR.
- [ ] **Step 5: Pose, vérif API, commit.**

---

### Task 6: Le rôle publish apprend la nouvelle version

**Files:**
- Create: `ansible/roles/apim_publish_api/tasks/version.yml`
- Modify: `ansible/roles/apim_publish_api/tasks/main.yml` (branchement create-or-version, additif)

**Interfaces:**
- Consumes: les FAITS de la Task 1 (forme du corps, sémantique du flag, sort des souscriptions) ; le mock de la Task 2.
- Produces: à l'apply, si `apim_api.name` existe sur la gateway sous une AUTRE version → duplication par `POST /apis/{id}/versions` (corps mesuré), puis le chemin re-import existant met la spec à jour ; sinon → import initial inchangé. Fail-closed : plusieurs versions existantes candidates → `VERSION_BASE_AMBIGUE` avec la liste, jamais de devinette. Échecs nommés : `VERSION_CREATE_FAILED`, etc.

- [ ] **Step 1: Relever le point d'insertion** (`grep -n 'import\|POST /apis\|multipart' ansible/roles/apim_publish_api/tasks/main.yml`) et les noms de faits du rôle (pub_*).
- [ ] **Step 2: Écrire version.yml** — read-modify-write avec relecture-assert après la duplication (la version nouvelle EXISTE, relue — un 201 ne prouve rien, discipline du palier 1) + l'assert des souscriptions selon M3 (transportées ou non — le rôle EXIGE le comportement mesuré, pour détecter un changement de comportement produit à la prochaine montée de version).
- [ ] **Step 3: Contre-épreuves contre le mock T2** — création v2 depuis v1 : policies conformes à M2, souscriptions conformes à M3 (contre-témoin : app souscrite relue AVANT/APRÈS) ; base ambiguë (3 versions posées) → refus ; noms de tâches SANS facts runtime (2.19 !) ; non-régression : publish initial inchangé (test-publish-guards + un import complet contre le mock désormais multipart).
- [ ] **Step 4: Commit.**

---

### Task 7: team-publish + les extensions de team-apply

**Files:**
- Create: `scripts/team-publish.sh`, `ci/jenkins/team-publish.job.xml`, `scripts/test-team-publish-wiring.sh`
- Modify: `scripts/team-apply.sh` (webhook du dépôt d'équipe + re-pose), `scripts/setup-team-onboard-jobs.sh` (JOBS += team-publish)

**Interfaces:**
- Consumes: tout ce qui précède ; les motifs de team-apply (pause nominative UN bloc sh, `VAULT_USER_AUTH_MOUNT` exporté AVANT le source — la leçon du palier 2, câblée d'entrée ; garde d'identité ; anti-TOCTOU checkout au MERGE_SHA du dépôt d'équipe).
- Produces: webhook `pull_request` des dépôts d'équipe → GWT `closed|merged` + garde `api/*` ; team dérivée du `repository.full_name` du payload CROISÉE avec providers (`REPO_NON_DECLARE` → refus) ; apply par `apim_publish_api` (env vars gateway explicites, `${:?}`) ; statut sur la PR (succès ET échec — et le refus de garde commente AUSSI : le `finally` de provision-apply repris D'ENTRÉE, pas oublié comme au palier 2) ; après succès : re-pose `app-request` (liste APIs fraîche).

- [ ] **Step 1: team-publish.sh** — miroir de team-apply.sh (anti-TOCTOU sur le dépôt d'ÉQUIPE : le manifeste lu au MERGE_SHA), dérivation d'autorité :

```bash
REPO_FULL="${WEBHOOK_REPO:?}"           # $.repository.full_name du payload — Gitea dit qui a déclenché
TEAM=$(python3 - … <<'PY'               # providers: quelle team déclare CE repo ?
… print soit "TEAM=<x>" soit "TEAM="    # marqueur explicite, extraction GARDÉE (la classe du palier 2)
PY
) || fail "PARSE_PROVIDERS"
case "$TEAM" in TEAM=) fail "REPO_NON_DECLARE : $REPO_FULL n'appartient à aucune équipe de providers — refus";; esac
```

- [ ] **Step 2: Le job XML** — copie team-apply.job.xml (GWT + MERGE_SHA + REPO full_name mappé, pause, garde, UN bloc sh, mount exporté avant le source, APIM_API_BASE explicite) **PLUS le `finally` qui commente la PR sur tout échec** — y compris un refus de garde (la dette I3 du palier 2, réglée ici pour la nouvelle chaîne au lieu d'être reproduite).
- [ ] **Step 3: Wiring-test** — motif test-team-apply-wiring AVEC greps ANCRÉS d'entrée (`^ *export VAR=` — le filet vacant du palier 2 ne se reproduit pas) : GWT mappe repo+MERGE_SHA, filtre, garde `api/`, mount+base exportés, finally présent, garde d'identité avant l'apply.
- [ ] **Step 4: team-apply.sh, deux extensions** — (a) après création du dépôt : enregistrer le webhook `pull_request` → team-publish (API Gitea, idempotent : hook existant même URL → sauté et dit) ; (b) après onboarding réussi : re-pose des formulaires (Task 3 Step 4). Contre-épreuves : re-run → webhook non dupliqué ; échec d'enregistrement → ❌ nommé sur la PR (pas silencieux).
- [ ] **Step 5: E2E contre les mocks + Gitea réel** — équipe scratch onboardée (chaîne palier 2 = non-régression vivante) → son dépôt reçoit le webhook → api-request → PR → merge → team-publish (webhook réel) → pause → identité oscar → publish contre le mock multipart → ✅ sur la PR → app-request re-posé avec la nouvelle API en liste. LA boucle complète du palier.
- [ ] **Step 6: Commit(s).**

---

### Task 8: La matrice du palier — `test-producer-chain.sh`

**Files:**
- Create: `scripts/test-producer-chain.sh`

**Interfaces:**
- Consumes: tout ; conventions maison (PASS/FAIL, trap teardown AVANT tout mint, exit ≠0).
- Produces: la preuve rejouable. Entrées toutes `${:?}` (GITEA_URL/TOKEN, VAULT_ADDR/TOKEN via fichier, WM_GATEWAY_URL=mock, JENKINS_UI).

| # | Preuve |
|---|---|
| 0 | **Non-régression** : matrice palier 2 rejouée verte + voies machine diff-vide |
| 1 | Gardes api-request : chaque refus SANS trace (ls-remote dépôt d'équipe avant/après) |
| 2 | Nominal créer : PR sur le dépôt d'équipe, spec+manifeste, plan ✅ avec hiérarchie de diagnostic |
| 3 | `REPO_NON_DECLARE` : un dépôt hors providers qui déclenche team-publish → refus, PR commentée |
| 4 | Câblage : test-team-publish-wiring (greps ancrés) + garde d'identité rouge/verte |
| 5 | Merge réel → team-publish E2E (pause répondue API, oscar) → API sur le mock, ✅ PR |
| 6 | Nouvelle version : v2 dupliquée, policies conformes M2, **souscriptions conformes M3 relues** (le piège multi-version, en preuve rejouable) |
| 7 | Re-pose des listes : après 5, app-request porte la nouvelle API ; après un onboarding scratch, les formulaires portent la nouvelle team |
| 8 | `ps -Aww` continu avec CONTRÔLE POSITIF (trafic git vu > 0) — zéro secret, chemins d'erreur compris |
| 9 | Teardown symétrique 404-exact + le harnais SAIT ROUGIR (garde cassée → FAIL → restaurée) |

- [ ] **Step 1: Écrire** (structure de test-team-onboarding-chain.sh, ses leçons intégrées : verdicts de repli → bad(), `= 404` exact, trap avant mint, sed portable, en-tête VRAI).
- [ ] **Step 2: Run complet** → attendu 10 PASS ; contre-épreuve du harnais.
- [ ] **Step 3: Commit.**

---

## Auto-relecture

**Couverture du spec.** §3 → Task 3. §4 → Task 4. §5 formulaire+script → Task 5 ; team-publish+autorité → Task 7 ; nouvelle version → Tasks 1 (mesures), 2 (mock), 6 (rôle) ; extensions → Task 7. §6 preuves → Task 8 (+ non-régressions dans chaque tâche). §2 décisions → toutes tracées. Hors périmètre §7 → rien de planifié, conforme.

**Ordre et dépendances.** 1→2 (le mock reproduit le mesuré) ; 2→6,7 (les preuves publish exigent le multipart) ; 3→4,5 (les listes) ; 6→7 (team-publish applique le rôle étendu) ; 8 en dernier. Tasks 1-2 et 3 sont indépendantes (parallélisables si le contrôleur le veut — JAMAIS deux implémenteurs sur le même fichier).

**Leçons du palier 2 câblées dans le texte même des tâches** (pas en préambule seulement) : finally-commentaire d'entrée (T7), greps ancrés d'entrée (T7), hiérarchie de diagnostic d'entrée (T5), extraction gardée avec marqueur (T7 Step 1), mount avant le source (T7), contrôle positif du ps (T8), mesures avant écriture (T1 entière).

**Inconnues assumées → mesures** : la forme multipart réelle du rôle (T2 S1), le point d'insertion du rôle et la résolution de `public_cert_ref` (T4 S2, T6 S1), l'appel exact des gardes publish (T5 S2), et TOUTE la Task 1.
