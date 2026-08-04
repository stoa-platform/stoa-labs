# Palier 2 — formulaires Jenkins : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Donner au moteur du palier 1 ses deux portes d'entrée humaines — un formulaire « onboarder une équipe » (PR + plan, dépôt créé au merge) et un formulaire « créer une application » (même aval que OIG/CLI2) — sans déplacer le point de décision, qui reste le merge.

**Architecture:** Miroir de la chaîne de provisioning prouvée, sous l'espace de noms de branche `onboard/*` (les chaînes s'ignorent par construction : `provision-plan.sh:44` et le job apply ignorent tout ce qui n'est pas `provision/*`). Un script par responsabilité (`team-request.sh`, `team-apply.sh`), un job XML par porte, les gardes et motifs existants réutilisés tels quels (`assert-merge-identity.sh`, pause nominative, commentaire PR, header-file pour les tokens).

**Tech Stack:** bash portable, jobs Jenkins pipeline (CpsFlowDefinition inline + GWT), API Gitea (urllib python3, motif de `provision-request.sh`), Ansible (rôle `apim_team_onboard` du palier 1), Vault KV v2.

**Spec :** `docs/superpowers/specs/2026-08-04-formulaires-jenkins-palier-2-design.md`
**Base :** branche `feat/onboarding-equipe-palier-1` (le rôle, `providers.dev.yml` et les gardes y vivent).

## Global Constraints

- **Aucun littéral de secret dans un `.sh`** — la garde `scripts/check-no-plaintext-secrets.sh` scanne (clé = fichier, VARIABLE) ; toujours `${VAR:?message}`, jamais `${VAR:-littéral}` pour une variable `*PASS*`/`*SECRET*`/`*TOKEN*`.
- **Aucun token en argv** — ni de `ansible-playbook` (`VAULT_TOKEN_FILE`, lu par `apim_common/tasks/secrets.yml:40`), ni de `curl` (motif header-file : `curl -H @"$fichier"`). Vérifiable par sondage `ps -ww`.
- **Le port 5555 est la VRAIE gateway du lab, en service.** Aucune valeur par défaut réseau ne pointe dessus ; toute cible gateway est explicite et requise (`${VAR:?}`).
- **Ne JAMAIS modifier la chaîne `provision/*` existante**, à une exception près, additive : `REQ_MODE`/`REQ_CLIENT_ID` optionnels dans `provision-request.sh` (Task 6).
- **Échecs nommés et greppables** : `TEAM_NAME_INVALID`, `TEAM_ALREADY_DECLARED`, `TEAM_NOT_IN_MERGED_STATE`, `ENV_NOT_OPEN`, `YAML_UNSAFE_INPUT` — même style que le rôle.
- **Contre-épreuve pour chaque garde** : la voir rougir avant de la croire. Un garde-fou jamais vu échouer n'est pas un garde-fou (leçon centrale du palier 1).
- **Idempotence véridique** : un `changed=0`/« déjà présent » ne prouve rien sans le premier passage qui a réellement créé.
- Commentaires : le POURQUOI, pas le QUOI. Style des scripts voisins (`ok()`/`bad()`, `set +x` quand un token est en jeu).

---

## Structure des fichiers

| Fichier | Responsabilité |
|---|---|
| `ansible/team-plan.yml` | **créé** — le « plan » : gardes hors ligne du rôle (resolve seul), zéro mutation |
| `scripts/team-request.sh` | **créé** — moteur du formulaire 1 : gardes d'entrée, édition providers, branche+PR, plan commenté |
| `ci/jenkins/team-request.job.xml` | **créé** — le formulaire 1 (job paramétré) |
| `scripts/setup-team-onboard-prereqs.sh` | **créé** — prérequis §8 du spec : policy Vault `team-onboarder`, token org-admin Gitea dans Vault |
| `scripts/team-apply.sh` | **créé** — moteur post-merge : anti-TOCTOU, dépôt depuis squelette, onboarding, commentaire |
| `ci/jenkins/team-apply.job.xml` | **créé** — webhook + pause nominative + garde d'identité |
| `scripts/provision-request.sh` | **modifié** — `REQ_MODE` explicite, `REQ_CLIENT_ID` optionnel en internal (additif) |
| `ci/jenkins/app-request.job.xml` | **créé** — le formulaire 2 |
| `scripts/setup-team-onboard-jobs.sh` | **créé** — pose les 3 jobs (motif de `setup-provision-request-job.sh`) |
| `scripts/test-team-onboarding-chain.sh` | **créé** — la matrice de preuve à 9 points |

---

### Task 1: `team-plan.yml` + `team-request.sh` — le moteur du formulaire équipe

**Files:**
- Create: `ansible/team-plan.yml`
- Create: `scripts/team-request.sh`

**Interfaces:**
- Consumes: rôle `apim_team_onboard/tasks/resolve.yml` (palier 1 — gardes `TEAM_NAME_INVALID`, `TENANT_ROOT_UNSAFE`, fait `onb`, debug des dérivations) ; motifs de `scripts/provision-request.sh` (PUSH_URL en mémoire, PR via urllib, `set +x`).
- Produces: `scripts/team-request.sh`, piloté par env : `TEAM` (req), `DESCRIPTION`, `APPROVERS` (CSV, vide accepté), `REPO` (défaut `<TEAM>/apis`), `REQ_ENV` (défaut `dev`, seul ouvert), `GITEA_TOKEN` (req), `GIT_REPO` (défaut `ci/stoa-labs`), `GIT_HOST` (défaut `http://gitea:3000`), `GIT_WEB_HOST` (lien humain, même convention que `provision-plan.sh`). Branche produite : `onboard/<TEAM>-<REQ_ENV>`. Sortie : PR ouverte + commentaire plan ✅/❌.

- [ ] **Step 1: Écrire `ansible/team-plan.yml`**

```yaml
---
# team-plan.yml — le « PLAN » du formulaire d'onboarding (ADR-081, corollaire 1).
#
# Zéro mutation, zéro réseau : on ne joue QUE resolve.yml du rôle — c'est-à-dire
# les gardes mêmes qui protégeront l'apply (TEAM_NAME_INVALID, TEAM_NOT_DECLARED,
# TENANT_ROOT_UNSAFE) plus les quatre dérivations, montrées au valideur AVANT le
# merge. Un plan qui rejouerait d'autres règles que celles de l'apply mentirait :
# ici le plan EST un sous-ensemble de l'apply, par construction.
- name: "PLAN onboarding d'équipe — gardes hors ligne, zéro mutation"
  hosts: webmethods
  gather_facts: false
  tasks:
    - name: "FAIL-CLOSED — une équipe cible est obligatoire"
      ansible.builtin.assert:
        that: "apim_onb_team | default('') | length > 0"
        fail_msg: "Passer -e apim_onb_team=<equipe>."

    - name: "Gardes du rôle (resolve seul : nom, déclaration, gabarit KV, dérivations)"
      ansible.builtin.import_role:
        name: apim_team_onboard
        tasks_from: resolve.yml
```

- [ ] **Step 2: Vérifier que le plan échoue et réussit pour les bonnes raisons**

```bash
cd poc-control-plane-federation
# rouge attendu (équipe non déclarée) :
ansible-playbook -i ansible/inventory.lab.ini ansible/team-plan.yml \
  -e apim_onb_team=nexiste-pas 2>&1 | grep -c TEAM_NOT_DECLARED   # attendu : ≥1
# vert attendu :
ansible-playbook -i ansible/inventory.lab.ini ansible/team-plan.yml \
  -e apim_onb_team=banking-demo | grep -c 'equipe=banking-demo'    # attendu : 1
```

La ligne `equipe=… user=… groupe=… kv=… policy=…` du debug de `resolve.yml` est
ce que le script postera en commentaire — pas de double source des dérivations.

- [ ] **Step 3: Écrire `scripts/team-request.sh`**

```bash
#!/usr/bin/env bash
# team-request.sh — moteur du formulaire « onboarder une équipe » (palier 2).
#
#   formulaire Jenkins → CE script :
#     1. gardes d'entrée (AVANT tout geste Git — un refus ne laisse rien derrière)
#     2. clone du dépôt plateforme, AJOUT de l'entrée dans providers.<env>.yml
#     3. branche onboard/<team>-<env>, commit (identité de service ci), push, PR
#     4. PLAN : ansible/team-plan.yml contre le fichier MODIFIÉ → commentaire ✅/❌
#
# La décision reste le MERGE (ADR-081) : ce script n'applique rien, ne crée
# aucun dépôt, ne touche ni Vault ni la gateway. Le privilège de création vit
# dans le seul job post-merge (team-apply).
#
# Entrées (env — mappées depuis les paramètres du job) :
#   TEAM         (req) nom d'équipe — regex du rôle, refus TEAM_NAME_INVALID
#   DESCRIPTION        libre (sans " ni retour ligne — YAML_UNSAFE_INPUT sinon)
#   APPROVERS          matricules CSV ; VIDE ACCEPTÉ (cas payments-team)
#   REPO               full-name org/nom (défaut <TEAM>/apis)
#   REQ_ENV            dev|rec|int|prod — seul dev est OUVERT au palier 2
#   GITEA_TOKEN  (req) token du service ci (write:repository, write:issue)
#   GIT_REPO           défaut ci/stoa-labs   GIT_HOST  défaut http://gitea:3000
#   GIT_WEB_HOST       URL Gitea vue par l'HUMAIN (liens des commentaires)
set -uo pipefail
set +x   # jamais de trace : le token ne doit pas fuiter
cd "$(dirname "$0")/.." || exit 1

TEAM="${TEAM:?TEAM requis}"
GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN requis}"
DESCRIPTION="${DESCRIPTION:-}"
APPROVERS="${APPROVERS:-}"
REPO="${REPO:-${TEAM}/apis}"
REQ_ENV="${REQ_ENV:-dev}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
GIT_HOST="${GIT_HOST:-http://gitea:3000}"
GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"

fail(){ echo "ERREUR: $*" >&2; exit 1; }

# ── 1. gardes d'entrée — AVANT tout geste Git ────────────────────────────────
# Regex du rôle, avec la leçon \Z du palier 1 : bash/grep matchent par LIGNE,
# donc un TEAM porteur d'un \n interne passerait un grep naïf. On refuse
# d'abord tout caractère hors classe (dont \n), PUIS la forme.
case "$TEAM" in *[!a-z0-9-]*) fail "TEAM_NAME_INVALID : '$TEAM' — ^[a-z0-9][a-z0-9-]{1,30}\$ requis";; esac
printf '%s' "$TEAM" | grep -Eq '^[a-z0-9][a-z0-9-]{1,30}$' \
  || fail "TEAM_NAME_INVALID : '$TEAM' — ^[a-z0-9][a-z0-9-]{1,30}\$ requis"

# Palier 2 : seul dev est ouvert. Les autres envs sont listés au formulaire
# mais GARDÉS ici — le message dit pourquoi, pas juste « non ».
[ "$REQ_ENV" = "dev" ] || fail "ENV_NOT_OPEN : '$REQ_ENV' — seul dev est ouvert au palier 2 (rec/int/prod : gouvernance à cadrer)"

# Ces valeurs sont INJECTÉES dans un YAML : un " ou un retour ligne dans la
# description casserait ou détournerait le fichier — même classe d'attaque que
# l'évasion de chemin du rôle. Refus, pas échappement (KISS + auditables).
case "$DESCRIPTION" in *'"'*|*$'\n'*) fail "YAML_UNSAFE_INPUT : description sans \" ni retour ligne";; esac
case "$REPO" in
  */*) printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
         || fail "YAML_UNSAFE_INPUT : REPO '$REPO' — forme org/nom requise";;
  *) fail "YAML_UNSAFE_INPUT : REPO '$REPO' — forme org/nom requise";;
esac
APPROVERS_YAML=""
if [ -n "$APPROVERS" ]; then
  IFS=',' read -ra _APPR <<< "$APPROVERS"
  for a in "${_APPR[@]}"; do
    a="$(printf '%s' "$a" | tr -d '[:space:]')"
    [ -z "$a" ] && continue
    printf '%s' "$a" | grep -Eq '^[A-Za-z0-9_-]+$' \
      || fail "YAML_UNSAFE_INPUT : approbateur '$a' — [A-Za-z0-9_-] uniquement"
    APPROVERS_YAML="${APPROVERS_YAML:+$APPROVERS_YAML, }\"$a\""
  done
fi

# ── 2. clone + édition de providers.<env>.yml ────────────────────────────────
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
BRANCH="onboard/${TEAM}-${REQ_ENV}"
echo "[1/4] clone ${GIT_REPO}"
git clone -q --depth 1 -b main "${GIT_HOST}/${GIT_REPO}.git" "$WORK/repo" || fail "clone ${GIT_REPO}"
PROV="$WORK/repo/poc-control-plane-federation/ansible/providers.${REQ_ENV}.yml"
[ -f "$PROV" ] || fail "providers.${REQ_ENV}.yml absent du dépôt plateforme"

# Jamais d'écrasement silencieux : une équipe déjà déclarée est un refus,
# pas une mise à jour — la mise à jour d'une équipe passe par une PR manuelle.
grep -Eq "^  - team: ${TEAM}\$" "$PROV" && fail "TEAM_ALREADY_DECLARED : ${TEAM} est déjà dans providers.${REQ_ENV}.yml"

echo "[2/4] entrée ${TEAM} dans providers.${REQ_ENV}.yml"
cat >> "$PROV" <<EOF

  # Ajout par formulaire Jenkins team-request (palier 2) — la PR est l'acte
  # d'autorisation (ADR-081) ; le dépôt et les objets naissent au merge.
  - team: ${TEAM}
    description: "${DESCRIPTION}"
    repo: ${REPO}
    approvers: [${APPROVERS_YAML}]
EOF

# ── 3. branche, commit, push, PR ─────────────────────────────────────────────
echo "[3/4] branche ${BRANCH} + PR"
PUSH_URL="http://ci:${GITEA_TOKEN}@${GIT_HOST#http://}/${GIT_REPO}.git"
git -C "$WORK/repo" checkout -q -b "$BRANCH"
git -C "$WORK/repo" -c user.name=ci -c user.email=ci@stoa.lab \
  commit -qam "onboard(${TEAM}): demande d'onboarding ${REQ_ENV} (formulaire)"
git -C "$WORK/repo" push -q "$PUSH_URL" "$BRANCH" 2>"$WORK/pusherr" \
  || { echo "ERREUR push (détail masqué — token)" >&2; grep -v "$GITEA_TOKEN" "$WORK/pusherr" >&2 || true; exit 1; }

PR_NUMBER=$(API="${GIT_HOST}/api/v1" GIT_REPO="$GIT_REPO" GITEA_TOKEN="$GITEA_TOKEN" \
  BRANCH="$BRANCH" TEAM="$TEAM" REQ_ENV="$REQ_ENV" python3 - <<'PY'
import json, os, urllib.request
api, repo, tok = os.environ["API"], os.environ["GIT_REPO"], os.environ["GITEA_TOKEN"]
body = {"base": "main", "head": os.environ["BRANCH"],
        "title": f"onboard: équipe {os.environ['TEAM']} ({os.environ['REQ_ENV']})"}
req = urllib.request.Request(f"{api}/repos/{repo}/pulls", method="POST",
    data=json.dumps(body).encode(),
    headers={"Authorization": f"token {tok}", "Content-Type": "application/json"})
print(json.load(urllib.request.urlopen(req))["number"])
PY
) || fail "ouverture de la PR"
echo "PR #${PR_NUMBER} ouverte : ${GIT_WEB_HOST}/${GIT_REPO}/pulls/${PR_NUMBER}"

# ── 4. PLAN contre le fichier MODIFIÉ + commentaire ──────────────────────────
# Le plan tourne dans le CLONE (la branche), pas dans le checkout du job : ce
# que le valideur lira est calculé sur ce qui sera mergé, rien d'autre.
echo "[4/4] plan (gardes hors ligne du rôle)"
PLAN_LOG="$WORK/plan.log"
( cd "$WORK/repo/poc-control-plane-federation" \
  && ansible-playbook -i ansible/inventory.lab.ini ansible/team-plan.yml \
       -e "apim_onb_team=${TEAM}" -e "apim_onb_providers_file=providers.${REQ_ENV}.yml" \
) >"$PLAN_LOG" 2>&1
PLAN_RC=$?
DERIVED=$(grep -oE 'equipe=[^"]*' "$PLAN_LOG" | head -1)
if [ "$PLAN_RC" -eq 0 ]; then
  VERDICT="✅ PLAN OK — ${DERIVED:-dérivations non capturées}"
else
  VERDICT="❌ PLAN EN ÉCHEC — NE PAS MERGER : $(grep -oE '(TEAM_[A-Z_]+|TENANT_ROOT_UNSAFE)' "$PLAN_LOG" | sort -u | tr '\n' ' ')"
fi
BODY="${VERDICT}

Au merge, team-apply : crée le dépôt \`${REPO}\` (squelette ADR-076) puis pose
user/groupe/team gateway + KV/policy Vault (rôle apim_team_onboard, idempotent)."
API="${GIT_HOST}/api/v1" GIT_REPO="$GIT_REPO" GITEA_TOKEN="$GITEA_TOKEN" \
  PR="$PR_NUMBER" BODY="$BODY" python3 - <<'PY'
import json, os, urllib.request
api, repo, tok = os.environ["API"], os.environ["GIT_REPO"], os.environ["GITEA_TOKEN"]
req = urllib.request.Request(f"{api}/repos/{repo}/issues/{os.environ['PR']}/comments",
    method="POST", data=json.dumps({"body": os.environ["BODY"]}).encode(),
    headers={"Authorization": f"token {tok}", "Content-Type": "application/json"})
urllib.request.urlopen(req)
PY
echo "plan ${VERDICT%% *} commenté sur la PR #${PR_NUMBER}"
[ "$PLAN_RC" -eq 0 ]
```

Note d'implémentation : `resolve.yml` charge `apim_onb_providers_file` en relatif
au dossier `ansible/` — vérifie-le en lançant depuis le clone (c'est déjà la
convention des tests du palier 1) ; si le chemin ne résout pas, c'est le lancement
qui est au mauvais endroit, pas le rôle qu'il faut modifier.

- [ ] **Step 4: Contre-épreuves des gardes, une par une**

Contre le **vrai Gitea du lab** (le service tourne — relève l'URL hôte, le dépôt
`ci/stoa-labs` existe). Token : minte-le comme `setup-provision-request-job.sh:29`
(`docker exec … gitea admin user generate-access-token --username ci …`), exporte-le,
ne l'écris nulle part.

```bash
export GITEA_TOKEN=…  GIT_HOST=http://localhost:13000  GIT_WEB_HOST=http://localhost:13000
# 1. nom invalide → aucun geste Git (vérifié par listing des branches AVANT/APRÈS)
TEAM='../evil' bash scripts/team-request.sh ; echo "rc=$? (attendu 1, TEAM_NAME_INVALID)"
TEAM=$'probe\nx' bash scripts/team-request.sh ; echo "rc=$? (attendu 1 — le \n interne est refusé)"
# 2. équipe déjà déclarée → TEAM_ALREADY_DECLARED, aucune PR nouvelle
TEAM=banking-demo bash scripts/team-request.sh ; echo "rc=$? (attendu 1)"
# 3. description YAML-hostile → refus
TEAM=probe-p2 DESCRIPTION='x" , repo: pwned' bash scripts/team-request.sh ; echo "rc=$?"
# 4. env non ouvert → ENV_NOT_OPEN
TEAM=probe-p2 REQ_ENV=prod bash scripts/team-request.sh ; echo "rc=$?"
# 5. nominal → PR ouverte + plan ✅ commenté (vérifier via l'API, puis NETTOYER :
#    fermer la PR, supprimer la branche onboard/probe-p2-dev)
TEAM=probe-p2 DESCRIPTION="equipe sonde palier 2" APPROVERS="X1,Y2" bash scripts/team-request.sh
```

Chaque refus doit être vérifié **sans trace** : `git ls-remote` avant/après sur
`onboard/*` — un refus qui a déjà poussé une branche est un échec de la garde.

- [ ] **Step 5: La garde de secrets ne signale pas le nouveau fichier**

```bash
bash scripts/check-no-plaintext-secrets.sh ; echo "rc=$? (attendu 0)"
```

- [ ] **Step 6: Commit**

```bash
git add poc-control-plane-federation/ansible/team-plan.yml poc-control-plane-federation/scripts/team-request.sh
git commit -m "feat(onboard): moteur du formulaire équipe — PR + plan, zéro mutation

Le plan EST resolve.yml du rôle : les gardes montrées au valideur sont celles
qui protégeront l'apply, par construction. Refus avant tout geste Git ; les
entrées injectées dans le YAML sont refusées, pas échappées."
```

---

### Task 2: `team-request.job.xml` — le formulaire 1

**Files:**
- Create: `ci/jenkins/team-request.job.xml`
- Create: `scripts/setup-team-onboard-jobs.sh`

**Interfaces:**
- Consumes: `scripts/team-request.sh` (Task 1, contrat env ci-dessus) ; credential Jenkins `gitea-provision-token` (existant — mêmes scopes suffisants : write:repository + write:issue).
- Produces: job `team-request` (paramétré, pas de webhook) ; `scripts/setup-team-onboard-jobs.sh` qui pose les jobs du palier (les Tasks 5 et 7 y ajouteront les leurs).

- [ ] **Step 1: Relever le mécanisme de pose de job existant**

```bash
grep -n 'createItem\|config.xml\|job/' scripts/setup-provision-jobs.sh | head -10
```

`setup-provision-request-job.sh` lui délègue la pose « en place » — reprends
**son** mécanisme exact (create si absent, update sinon), ne réinvente pas.

- [ ] **Step 2: Écrire `ci/jenkins/team-request.job.xml`**

Squelette — paramètres au motif de `carto.job.xml`, pipeline au motif de
`provisioning-request.job.xml` (sans GWT : la porte est humaine) :

```xml
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>Formulaire : onboarder une équipe → PR onboard/* + plan commenté. La décision reste le MERGE (ADR-081) ; le dépôt et les objets naissent au merge (job team-apply).</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
        <hudson.model.StringParameterDefinition>
          <name>TEAM</name>
          <description>Nom d'équipe — minuscules/chiffres/tirets (^[a-z0-9][a-z0-9-]{1,30}$). Devient : svc-&lt;team&gt;, &lt;team&gt;-devs, deploy/&lt;team&gt;/wm-admin, deploy-&lt;team&gt;.</description>
          <defaultValue></defaultValue>
        </hudson.model.StringParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>DESCRIPTION</name>
          <description>Description de l'équipe (sans guillemets doubles).</description>
          <defaultValue></defaultValue>
        </hudson.model.StringParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>APPROVERS</name>
          <description>Matricules des approbateurs, séparés par des virgules. VIDE ACCEPTÉ : la projection owner ne fera rien tant que la liste n'est pas établie.</description>
          <defaultValue></defaultValue>
        </hudson.model.StringParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>REPO</name>
          <description>Dépôt Git de l'équipe (org/nom). Vide = &lt;team&gt;/apis. Créé AU MERGE depuis le squelette ADR-076.</description>
          <defaultValue></defaultValue>
        </hudson.model.StringParameterDefinition>
        <hudson.model.ChoiceParameterDefinition>
          <name>REQ_ENV</name>
          <description>Environnement. Seul dev est ouvert au palier 2 — les autres sont refusés avec ENV_NOT_OPEN.</description>
          <choices class="java.util.Arrays$ArrayList"><a class="string-array"><string>dev</string><string>rec</string><string>int</string><string>prod</string></a></choices>
        </hudson.model.ChoiceParameterDefinition>
      </parameterDefinitions>
    </hudson.model.ParametersDefinitionProperty>
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">
    <script>
node {
  stage('checkout') { git url: 'http://gitea:3000/ci/stoa-labs.git', branch: 'main' }
  stage('team-request') {
    withCredentials([string(credentialsId: 'gitea-provision-token', variable: 'GITEA_TOKEN')]) {
      // Les paramètres passent par l'ENVIRONNEMENT, jamais interpolés dans la
      // chaîne sh : saisie humaine = donnée d'un tiers (même règle que
      // provision-apply). REPO vide → défaut calculé par le script.
      withEnv(["TEAM=${params.TEAM}", "DESCRIPTION=${params.DESCRIPTION}",
               "APPROVERS=${params.APPROVERS}", "REPO=${params.REPO ?: ''}",
               "REQ_ENV=${params.REQ_ENV}"]) {
        dir('poc-control-plane-federation') {
          sh 'set +x; if [ -z "$REPO" ]; then unset REPO; fi; bash scripts/team-request.sh'
        }
      }
    }
  }
}
    </script>
    <sandbox>true</sandbox>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
```

⚠️ L'interpolation Groovy `${params.X}` dans `withEnv` est le motif **existant**
du dépôt (provision-apply fait pareil avec le payload webhook) — la protection
réelle est côté script (gardes d'entrée + chaîne sh en quotes simples).

- [ ] **Step 3: Écrire `scripts/setup-team-onboard-jobs.sh`**

Reprend le mécanisme relevé au Step 1 (crumb, create-or-update). Pose `team-request`
depuis `ci/jenkins/team-request.job.xml`. Sortie `ok()/ko()` du style maison.
Prévois une boucle sur une liste de couples `job:xml` — les Tasks 5 et 7 y
ajouteront `team-apply` et `app-request` en une ligne chacune.

- [ ] **Step 4: Prouver le câblage sans cliquer**

Motif `test-provision-apply-wiring.sh` : on prouve le XML et la pose, pas la
saisie manuelle.

```bash
bash scripts/setup-team-onboard-jobs.sh          # pose le job sur le Jenkins du lab
# le job existe et porte les 5 paramètres :
curl -s "$JENKINS_UI/job/team-request/api/json?tree=property[parameterDefinitions[name]]" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(sorted(p['name'] for pr in d['property'] if 'parameterDefinitions' in pr for p in pr['parameterDefinitions']))"
# attendu : ['APPROVERS','DESCRIPTION','REPO','REQ_ENV','TEAM']
# déclenchement API (même chemin que le bouton) — nom invalide → build rouge :
# relever le motif de déclenchement buildWithParameters + crumb dans les scripts existants.
```

- [ ] **Step 5: Commit**

```bash
git add poc-control-plane-federation/ci/jenkins/team-request.job.xml poc-control-plane-federation/scripts/setup-team-onboard-jobs.sh
git commit -m "feat(onboard): formulaire team-request — la saisie est humaine, la décision reste le merge"
```

---

### Task 3: prérequis — policy Vault `team-onboarder` + token org-admin Gitea

**Files:**
- Create: `scripts/setup-team-onboard-prereqs.sh`

**Interfaces:**
- Consumes: Vault du lab (`http://localhost:8200`), conteneur Gitea (`docker exec`), motif header-file de `setup-vault-userpass.sh:74-75` (`vcurl`).
- Produces: policy Vault `team-onboarder` ; entrée KV `secret/stoa/ci/gitea-org-admin` (`{token}`) ; policy attachée à un user configurable (`ONBOARD_OPERATOR`, défaut `oscar`). Chemins consommés par la Task 4.

- [ ] **Step 1: Relever avant d'écrire**

```bash
# le user admin réel de Gitea (NE PAS supposer) :
docker exec -u git poc-gitea gitea admin user list | head -5
# le mécanisme d'attache de policy à un user userpass (motif existant) :
grep -n 'token_policies\|users/' scripts/setup-vault-userpass.sh | head -6
```

- [ ] **Step 2: Écrire `scripts/setup-team-onboard-prereqs.sh`**

```bash
#!/usr/bin/env bash
# setup-team-onboard-prereqs.sh — les deux prérequis bloquants du palier 2 (§8) :
#   1. policy Vault `team-onboarder` : ce que l'APPLY d'onboarding a le droit
#      d'écrire — les policies deploy-<team> et les entrées KV wm-admin des
#      tenants, RIEN d'autre. Toutes les preuves du palier 1 tournaient au token
#      root : cette policy est ce qui rend l'apply livrable.
#   2. token org-admin Gitea (création d'orgs/dépôts), STOCKÉ DANS VAULT sous
#      secret/stoa/ci/gitea-org-admin — jamais dans les credentials Jenkins :
#      seul le porteur de team-onboarder le lit, donc seul l'apply post-merge.
#   3. attache team-onboarder à l'opérateur nominatif (ONBOARD_OPERATOR).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
VAULT_ADDR="${VAULT_ADDR:?VAULT_ADDR requis}"
VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN requis (amorçage, droits admin)}"
GITEA_CONTAINER="${GITEA_CONTAINER:-poc-gitea}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:?relever via: docker exec -u git $GITEA_CONTAINER gitea admin user list}"
ONBOARD_OPERATOR="${ONBOARD_OPERATOR:-oscar}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; umask 077
printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN" > "$TMP/hdr"
vcurl(){ curl -s -H @"$TMP/hdr" "$@"; }
ok(){ printf '  \033[32m✅\033[0m %s\n' "$*"; }
ko(){ printf '  \033[31m❌\033[0m %s\n' "$*"; exit 1; }

echo "1. policy team-onboarder"
python3 - > "$TMP/pol.json" <<'PY'
import json
hcl = (
    "# Perimetre de l'APPLY d'onboarding d'equipe (palier 2).\n"
    "# Ecrit les policies deploy-<team> et les entrees KV wm-admin des tenants\n"
    "# — et lit le token org-admin Gitea. RIEN d'autre : pas gateways/*, pas ci/*\n"
    "# au-dela de l'entree nommee.\n"
    'path "sys/policies/acl/deploy-*"                  { capabilities = ["create", "update", "read"] }\n'
    'path "secret/data/stoa/deploy/+/wm-admin"         { capabilities = ["create", "update", "read"] }\n'
    'path "secret/metadata/stoa/deploy/*"              { capabilities = ["read", "list"] }\n'
    'path "secret/data/stoa/ci/gitea-org-admin"        { capabilities = ["read"] }\n'
)
json.dump({"policy": hcl}, __import__("sys").stdout)
PY
RC=$(vcurl -X PUT "$VAULT_ADDR/v1/sys/policies/acl/team-onboarder" --data-binary @"$TMP/pol.json" -o "$TMP/err" -w '%{http_code}')
{ [ "$RC" = 200 ] || [ "$RC" = 204 ]; } && ok "policy team-onboarder" || ko "policy (HTTP $RC): $(cat "$TMP/err")"

echo "2. token org-admin Gitea → Vault"
GTOK=$(docker exec -u git "$GITEA_CONTAINER" gitea admin user generate-access-token \
  --username "$GITEA_ADMIN_USER" --token-name "team-onboard-$(date +%s)" \
  --scopes write:organization,write:repository 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
[ -n "$GTOK" ] || ko "génération token Gitea (user $GITEA_ADMIN_USER)"
printf '{"data":{"token":"%s"}}' "$GTOK" > "$TMP/kv.json"
RC=$(vcurl -X POST "$VAULT_ADDR/v1/secret/data/stoa/ci/gitea-org-admin" --data-binary @"$TMP/kv.json" -o "$TMP/err" -w '%{http_code}')
{ [ "$RC" = 200 ] || [ "$RC" = 204 ]; } && ok "token stocké (secret/stoa/ci/gitea-org-admin)" || ko "KV (HTTP $RC)"

echo "3. attache à l'opérateur $ONBOARD_OPERATOR"
# relever le motif exact d'attache (Step 1) — l'esprit : AJOUTER team-onboarder
# aux token_policies existantes du user, jamais les remplacer.
```

Complète le bloc 3 avec le motif relevé (lecture des policies actuelles du user
userpass, ajout de `team-onboarder`, POST). **Ne remplace jamais la liste** —
écraser `deploy-banking-demo` d'oscar casserait la chaîne applicative.

- [ ] **Step 3: Contre-épreuve par capacités réelles (motif du palier 1)**

```bash
# token éphémère portant SEULEMENT team-onboarder :
# - PEUT écrire sys/policies/acl/deploy-probe-p2 et secret/data/stoa/deploy/probe-p2/wm-admin
# - PEUT lire secret/data/stoa/ci/gitea-org-admin
# - NE PEUT PAS lire secret/data/stoa/gateways/webmethods (403)
# - NE PEUT PAS écrire sys/policies/acl/team-onboarder elle-même (403)
# via sys/capabilities-self ou tentatives réelles + nettoyage — comme la preuve 3 du palier 1.
```

Les quatre lignes doivent être **mesurées** (200/403 réels), pas relues dans le HCL.

- [ ] **Step 4: Garde de secrets + commit**

```bash
bash scripts/check-no-plaintext-secrets.sh   # rc=0 attendu
git add poc-control-plane-federation/scripts/setup-team-onboard-prereqs.sh
git commit -m "feat(onboard): prérequis palier 2 — policy team-onboarder + token org-admin dans Vault

L'apply d'onboarding cesse de dépendre du token root : son périmètre est nommé,
borné, et prouvé par capacités réelles. Le token Gitea org-admin n'existe que
dans Vault — seul le porteur de team-onboarder le lit."
```

---

### Task 4: `team-apply.sh` — le moteur post-merge

**Files:**
- Create: `scripts/team-apply.sh`

**Interfaces:**
- Consumes: `providers.<env>.yml` mergé (lu au SHA du merge — anti-TOCTOU) ; token org-admin via Vault (`secret/stoa/ci/gitea-org-admin`, Task 3) ; `ansible/onboard-team.yml` (palier 1) ; `VAULT_TOKEN_FILE` (posé par le job, Task 5) ; squelette `clients/_example/`.
- Produces: `scripts/team-apply.sh`, piloté par env : `PR_BRANCH` (req, `onboard/<team>-<env>`), `PR_NUMBER` (req), `MERGE_SHA` (req), `GITEA_TOKEN` (req — commentaire), `VAULT_ADDR` (req), `VAULT_TOKEN_FILE` (req), `APIM_API_BASE` (req — **pas de défaut** : 5555 est la vraie gateway), `GIT_HOST`, `GIT_REPO`, `GIT_WEB_HOST`.

- [ ] **Step 1: Écrire `scripts/team-apply.sh`**

```bash
#!/usr/bin/env bash
# team-apply.sh — l'APPLY d'onboarding, APRÈS la décision humaine (le merge).
#
#   merge PR onboard/* → webhook → job team-apply (pause nominative + garde
#   d'identité, cf. le job XML) → CE script :
#     1. ANTI-TOCTOU : checkout de main AU SHA DU MERGE ; l'équipe est lue dans
#        providers.<env>.yml TEL QUE MERGÉ — jamais dans le payload du webhook.
#     2. dépôt Gitea depuis le squelette ADR-076 (token org-admin lu dans Vault,
#        header-file). IDEMPOTENT : dépôt existant → sauté, dit dans le commentaire.
#        repo: "" dans providers → étape sautée (cas payments-team), PAS un échec.
#     3. ansible/onboard-team.yml (rôle idempotent du palier 1).
#     4. commentaire PR : le statut RÉEL, succès comme échec (ADR-081 coroll. 2).
set -uo pipefail
set +x
cd "$(dirname "$0")/.." || exit 1

PR_BRANCH="${PR_BRANCH:?PR_BRANCH requis}"
PR_NUMBER="${PR_NUMBER:?PR_NUMBER requis}"
MERGE_SHA="${MERGE_SHA:?MERGE_SHA requis (merge_commit_sha du webhook)}"
GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN requis}"
VAULT_ADDR="${VAULT_ADDR:?VAULT_ADDR requis}"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:?VAULT_TOKEN_FILE requis (jamais le token en env/argv)}"
APIM_API_BASE="${APIM_API_BASE:?APIM_API_BASE requis — pas de défaut : dire sa cible est volontaire}"
GIT_HOST="${GIT_HOST:-http://gitea:3000}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; umask 077
fail(){ comment "❌ team-apply : $*"; echo "ERREUR: $*" >&2; exit 1; }
comment(){ API="${GIT_HOST}/api/v1" GIT_REPO="$GIT_REPO" GITEA_TOKEN="$GITEA_TOKEN" \
  PR="$PR_NUMBER" BODY="$1" python3 - <<'PY'
import json, os, urllib.request
api, repo, tok = os.environ["API"], os.environ["GIT_REPO"], os.environ["GITEA_TOKEN"]
req = urllib.request.Request(f"{api}/repos/{repo}/issues/{os.environ['PR']}/comments",
    method="POST", data=json.dumps({"body": os.environ["BODY"]}).encode(),
    headers={"Authorization": f"token {tok}", "Content-Type": "application/json"})
urllib.request.urlopen(req)
PY
}

# ── 1. équipe et env depuis la branche ; anti-TOCTOU sur le contenu ──────────
case "$PR_BRANCH" in onboard/*) ;; *) echo "hors onboard/* — rien à faire"; exit 0;; esac
REST="${PR_BRANCH#onboard/}"; ENVN="${REST##*-}"; TEAM="${REST%-*}"
[ "$ENVN" = dev ] || fail "ENV_NOT_OPEN : $ENVN"

git fetch -q origin main && git checkout -q "$MERGE_SHA" \
  || fail "checkout du SHA de merge $MERGE_SHA"
PROV="poc-control-plane-federation/ansible/providers.${ENVN}.yml"
grep -Eq "^  - team: ${TEAM}\$" "$PROV" \
  || fail "TEAM_NOT_IN_MERGED_STATE : ${TEAM} absente de ${PROV} au SHA mergé — le payload ne fait pas foi"
REPO_FULL=$(TEAM="$TEAM" PROV="$PROV" python3 - <<'PY'
import os, yaml
d = yaml.safe_load(open(os.environ["PROV"]))
e = next(p for p in d["providers"] if p["team"] == os.environ["TEAM"])
print(e.get("repo") or "")
PY
)

# ── 2. dépôt Gitea (idempotent ; token org-admin lu dans Vault) ──────────────
REPO_NOTE="dépôt : (repo vide dans providers — étape sautée)"
if [ -n "$REPO_FULL" ]; then
  curl -s -H @"$VAULT_TOKEN_FILE" "$VAULT_ADDR/v1/secret/data/stoa/ci/gitea-org-admin" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['data']['token'])" > "$TMP/gt" \
    || fail "lecture du token org-admin dans Vault (policy team-onboarder ?)"
  printf 'Authorization: token %s\n' "$(cat "$TMP/gt")" > "$TMP/ghdr"
  ORG="${REPO_FULL%%/*}"; RNAME="${REPO_FULL##*/}"
  gapi(){ curl -s -H @"$TMP/ghdr" -H 'Content-Type: application/json' "$@"; }
  # org : create-or-skip
  RC=$(gapi -o /dev/null -w '%{http_code}' "${GIT_HOST}/api/v1/orgs/${ORG}")
  if [ "$RC" != 200 ]; then
    RC=$(gapi -X POST -d "{\"username\":\"${ORG}\"}" -o "$TMP/err" -w '%{http_code}' "${GIT_HOST}/api/v1/orgs")
    { [ "$RC" = 201 ] || [ "$RC" = 200 ]; } || fail "création org ${ORG} (HTTP $RC)"
  fi
  # repo : create-or-skip, puis squelette si créé
  RC=$(gapi -o /dev/null -w '%{http_code}' "${GIT_HOST}/api/v1/repos/${REPO_FULL}")
  if [ "$RC" = 200 ]; then
    REPO_NOTE="dépôt ${REPO_FULL} : déjà existant, étape sautée (idempotence)"
  else
    RC=$(gapi -X POST -d "{\"name\":\"${RNAME}\",\"auto_init\":false}" -o "$TMP/err" -w '%{http_code}' "${GIT_HOST}/api/v1/orgs/${ORG}/repos")
    [ "$RC" = 201 ] || fail "création dépôt ${REPO_FULL} (HTTP $RC)"
    SK="$TMP/skel"; mkdir -p "$SK"
    cp -R poc-control-plane-federation/clients/_example/. "$SK/"
    printf '# %s\n\nDépôt d équipe (squelette ADR-076 : apis/, applications/).\nCréé par team-apply au merge de la PR #%s.\n' "$REPO_FULL" "$PR_NUMBER" > "$SK/README.md"
    git -C "$SK" init -q -b main && git -C "$SK" add -A \
      && git -C "$SK" -c user.name=ci -c user.email=ci@stoa.lab commit -qm "squelette ADR-076 (team-apply, PR #${PR_NUMBER})"
    git -C "$SK" push -q "http://x:$(cat "$TMP/gt")@${GIT_HOST#http://}/${REPO_FULL}.git" main 2>"$TMP/pe" \
      || { grep -v "$(cat "$TMP/gt")" "$TMP/pe" >&2 || true; fail "push du squelette"; }
    REPO_NOTE="dépôt ${REPO_FULL} : créé depuis le squelette ADR-076"
  fi
fi

# ── 3. onboarding (rôle du palier 1, idempotent) ─────────────────────────────
( cd poc-control-plane-federation \
  && ansible-playbook -i ansible/inventory.lab.ini ansible/onboard-team.yml \
       -e "apim_onb_team=${TEAM}" -e "apim_onb_providers_file=providers.${ENVN}.yml" \
       -e "apim_ss_api_base=${APIM_API_BASE}" \
) >"$TMP/onb.log" 2>&1
ONB_RC=$?
SUMMARY=$(grep -oE '(ONBOARD_OK|VERIFY_[A-Z_]+|TEAM_[A-Z_]+|TENANT_ROOT_UNSAFE|KV_[A-Z_]+)[^"]*' "$TMP/onb.log" | tail -3 | tr '\n' ' ')

# ── 4. le statut RÉEL sur la PR — succès comme échec ─────────────────────────
if [ "$ONB_RC" -eq 0 ]; then
  comment "✅ team-apply ${TEAM}/${ENVN} — ${REPO_NOTE} ; onboarding : ${SUMMARY:-ONBOARD_OK}"
else
  comment "❌ team-apply ${TEAM}/${ENVN} — ${REPO_NOTE} ; onboarding EN ÉCHEC : ${SUMMARY:-voir le build}. Re-run possible : tout est idempotent."
  fail "onboarding (voir log du build)"
fi
echo "team-apply OK — ${REPO_NOTE}"
```

Note : `fail()` commente PUIS sort — un échec n'est jamais silencieux depuis la
PR. Le `comment` d'échec part **avant** l'`exit 1` (c'est pour ça que `fail`
appelle `comment` en premier).

- [ ] **Step 2: Contre-épreuves, une garde à la fois**

Contre le vrai Gitea (org jetable `probe-p2`), le vrai Vault (token éphémère
portant `team-onboarder` **seule** — c'est aussi la preuve que la policy de la
Task 3 suffit), le mock gateway (`go run .`, relève le port ; **jamais 5555**) :

```bash
# 1. branche hors onboard/* → exit 0, aucun appel (vérifier : aucun commentaire posté)
# 2. TEAM_NOT_IN_MERGED_STATE : MERGE_SHA d'un commit où l'équipe n'est PAS dans
#    providers → rouge, commentaire ❌ posté
# 3. nominal : org+dépôt créés, squelette poussé, ONBOARD_OK, commentaire ✅
# 4. RE-RUN identique → « déjà existant, étape sautée » + rôle changed=0 → converge
# 5. repo: "" (éditer une entrée jetable) → étape dépôt sautée, onboarding joué quand même
# 6. échec du rôle (couper le mock) → commentaire ❌ AVANT l'exit 1
# nettoyage : org/dépôt/policy/KV jetables supprimés, PR fermée
```

- [ ] **Step 3: Garde de secrets + sondage argv**

```bash
bash scripts/check-no-plaintext-secrets.sh          # rc=0
# pendant un run : ps -ww en boucle — ni token Vault ni token Gitea en argv
```

- [ ] **Step 4: Commit**

```bash
git add poc-control-plane-federation/scripts/team-apply.sh
git commit -m "feat(onboard): team-apply — anti-TOCTOU, dépôt au merge, statut réel sur la PR

Le job lit main au SHA du merge, jamais le payload : ce qui a été décidé dans
Git est ce qui est appliqué. Échec = commentaire ❌ puis exit 1 — jamais
silencieux depuis la PR."
```

---

### Task 5: `team-apply.job.xml` — webhook, pause nominative, garde d'identité

**Files:**
- Create: `ci/jenkins/team-apply.job.xml`
- Modify: `scripts/setup-team-onboard-jobs.sh` (ajouter le couple `team-apply:xml`)

**Interfaces:**
- Consumes: `scripts/team-apply.sh` (Task 4) ; `scripts/lib/assert-merge-identity.sh` (`--merged-by --requester --vault-user`) ; le mécanisme de login Vault voie A existant (relever `ci/lib/vault-login.sh` — il écrit le token dans un fichier, jamais en argv).
- Produces: job `team-apply`, GWT filtré `closed|merged`, garde `onboard/*`.

- [ ] **Step 1: Relever le contrat de `ci/lib/vault-login.sh`**

```bash
sed -n '1,40p' ci/lib/vault-login.sh
```

Note les variables d'entrée exactes (user/mot de passe par env) et OÙ il écrit
le fichier token — c'est ce chemin que tu exporteras en `VAULT_TOKEN_FILE`.

- [ ] **Step 2: Écrire `ci/jenkins/team-apply.job.xml`**

Copie la structure de `provision-apply.job.xml` (GWT : mêmes `genericVariables`
**plus** `MERGE_SHA` ← `$.pull_request.merge_commit_sha` ; même
`regexpFilterText`/`regexpFilterExpression` `^closed\|true$`). Le script pipeline,
adapté :

```groovy
def ref = env.PR_BRANCH ?: ''
if (!ref.startsWith('onboard/')) { echo "branche '${ref}' hors onboard/* — rien a appliquer"; return }
def rest = ref.substring('onboard/'.length())
def envName = rest.substring(rest.lastIndexOf('-') + 1)
def teamName = rest.substring(0, rest.lastIndexOf('-'))
currentBuild.displayName = "onboard ${teamName}/${envName} (PR #${env.PR_NUMBER})"

// DEMANDE EN ATTENTE : la decision est deja prise (le merge) — la pause ne
// re-decide pas, elle fournit l'identite NOMINATIVE qui portera l'apply
// (policy team-onboarder, posee par setup-team-onboard-prereqs.sh).
def creds = input(id: 'onboard',
  message: "Onboarder l'equipe ${teamName} en ${envName} ? Fournissez VOTRE identite Vault.",
  parameters: [string(name: 'VAULT_USER', defaultValue: ''),
               password(name: 'VAULT_USER_PASSWORD', defaultValue: '')])

node {
  stage('garde identite du valideur') {
    git url: 'http://gitea:3000/ci/stoa-labs.git', branch: 'main'
    withEnv(["G_MERGED_BY=${env.PR_MERGED_BY ?: ''}",
             "G_REQUESTER=${env.PR_REQUESTER ?: ''}",
             "G_VAULT_USER=${creds.VAULT_USER ?: ''}"]) {
      dir('poc-control-plane-federation') {
        sh 'set +x; sh scripts/lib/assert-merge-identity.sh --merged-by "$G_MERGED_BY" --requester "$G_REQUESTER" --vault-user "$G_VAULT_USER"'
      }
    }
  }
  stage('team-apply') {
    withCredentials([string(credentialsId: 'gitea-provision-token', variable: 'GITEA_TOKEN')]) {
      withEnv(["V_USER=${creds.VAULT_USER}",
               "PR_BRANCH=${env.PR_BRANCH}", "PR_NUMBER=${env.PR_NUMBER}",
               "MERGE_SHA=${env.MERGE_SHA ?: ''}"]) {
        dir('poc-control-plane-federation') {
          // vault-login ecrit le token dans un FICHIER (relevé au Step 1) ;
          // le mot de passe passe par l'env de CE sh, jamais par argv.
          sh 'set +x; VAULT_USER="$V_USER" VAULT_USER_PASSWORD="'"'"'A_REMPLACER_PAR_LE_MOTIF_RELEVE'"'"'" true' // ← remplace par l'appel réel relevé
          sh 'set +x; export VAULT_TOKEN_FILE=…; export APIM_API_BASE=…; bash scripts/team-apply.sh'
        }
      }
    }
  }
}
```

⚠️ Les deux lignes `sh` de la fin sont un **gabarit à compléter avec le motif
relevé au Step 1** — le plan refuse d'inventer le contrat de `vault-login.sh`.
Deux exigences non négociables : le mot de passe transite par `withEnv`/env du
`sh` (comme `provision-apply` le fait pour `VAULT_USER_PASSWORD` via le
paramètre de build délégué), et `APIM_API_BASE` est posé **explicitement** dans
le job (valeur in-cluster de la gateway — relève le nom de service dans
`docker-compose.wm.yml`, ne devine pas).

- [ ] **Step 3: Preuve de câblage (motif `test-provision-apply-wiring.sh`)**

Assertions sur le XML posé : le GWT mappe `MERGE_SHA` ; le filtre est
`^closed\|true$` ; le script contient la garde `onboard/`, l'appel à
`assert-merge-identity.sh`, et `team-apply.sh`. Puis garde d'identité appelée
directement : `--merged-by ci --vault-user oscar` → `MERGER_MISMATCH` (rouge),
`--merged-by oscar --requester ci --vault-user oscar` → vert.

- [ ] **Step 4: Commit**

```bash
git add poc-control-plane-federation/ci/jenkins/team-apply.job.xml poc-control-plane-federation/scripts/setup-team-onboard-jobs.sh
git commit -m "feat(onboard): job team-apply — pause nominative et garde d'identite, miroir de provision-apply"
```

---

### Task 6: `REQ_MODE`/`REQ_CLIENT_ID` optionnels — l'exception additive à la chaîne existante

**Files:**
- Modify: `scripts/provision-request.sh` (localiser par grep, ne pas se fier aux numéros)

**Interfaces:**
- Consumes: la dérivation actuelle mode=f(REQ_CALLER) — à relever.
- Produces: `REQ_MODE` (`idp`|`internal`), prioritaire quand présent, dérivation existante en repli ; `REQ_CLIENT_ID` optionnel quand mode=internal, requis quand mode=idp (`CLIENT_ID_REQUIRED` sinon).

- [ ] **Step 1: Relever la dérivation et l'usage réel de REQ_CLIENT_ID**

```bash
grep -n 'REQ_CALLER\|REQ_CLIENT_ID\|idp\|internal' scripts/provision-request.sh
```

Regarde ce que le manifeste rendu FAIT de `clientId` en mode internal : s'il
n'y apparaît pas, le rendre optionnel est sûr ; s'il y apparaît, décide avec la
valeur vide réelle (et documente).

- [ ] **Step 2: Modifier — additif, repli intact**

```bash
# À l'endroit relevé (esprit, à adapter à la forme réelle) :
REQ_MODE="${REQ_MODE:-}"
case "$REQ_MODE" in ""|idp|internal) ;; *) fail "REQ_MODE '$REQ_MODE' — idp|internal";; esac
# mode effectif : REQ_MODE explicite (porte humaine) > dérivation caller (porte machine)
MODE="${REQ_MODE:-$MODE_DERIVE_EXISTANT}"
# clientId : requis en idp seulement
[ "$MODE" = idp ] && [ -z "${REQ_CLIENT_ID:-}" ] && fail "CLIENT_ID_REQUIRED : mode idp sans REQ_CLIENT_ID"
```

- [ ] **Step 3: Contre-épreuves**

```bash
# voie machine INCHANGÉE : REQ_CALLER=oig-provisioner sans REQ_MODE → mode idp (comme avant)
# REQ_MODE=internal sans REQ_CLIENT_ID → passe (manifeste rendu, vérifié)
# REQ_MODE=idp sans REQ_CLIENT_ID → CLIENT_ID_REQUIRED
# REQ_MODE=bogus → refus
```

La première est la plus importante : c'est la **non-régression de la chaîne
machine** — rejoue le test existant de la chaîne provisioning s'il y en a un
(`grep -rln provision-request scripts/test-* ci/`).

- [ ] **Step 4: Commit**

```bash
git add poc-control-plane-federation/scripts/provision-request.sh
git commit -m "feat(provisioning): REQ_MODE explicite pour la porte humaine, derivation caller en repli"
```

---

### Task 7: `app-request.job.xml` — le formulaire application

**Files:**
- Create: `ci/jenkins/app-request.job.xml`
- Modify: `scripts/setup-team-onboard-jobs.sh` (ajouter le couple)

**Interfaces:**
- Consumes: `provision-request.sh` (contrat env + Task 6) ; credential `gitea-provision-token`.
- Produces: job `app-request` paramétré (`APP`, `REQ_ENV` choix, `API`, `API_VER`, `CLIENT_ID`, `MODE` choix) ; `REQ_CALLER=jenkins-form:<userId>`.

- [ ] **Step 1: Écrire le job**

Paramètres au motif de la Task 2 (String + Choice pour `REQ_ENV` et `MODE`).
Pipeline :

```groovy
node {
  stage('checkout') { git url: 'http://gitea:3000/ci/stoa-labs.git', branch: 'main' }
  stage('app-request') {
    // Traçabilité : l'identité Jenkins du demandeur remplace oig-/cli2-provisioner.
    // getBuildCauses est approuvé en sandbox ; anonymous si non authentifié.
    def cause = currentBuild.getBuildCauses('hudson.model.Cause$UserIdCause')
    def uid = (cause && cause[0].userId) ? cause[0].userId : 'anonymous'
    withCredentials([string(credentialsId: 'gitea-provision-token', variable: 'GITEA_TOKEN')]) {
      withEnv(["REQ_APP=${params.APP}", "REQ_ENV=${params.REQ_ENV}",
               "REQ_API=${params.API}", "REQ_API_VER=${params.API_VER ?: '1.0.0'}",
               "REQ_CLIENT_ID=${params.CLIENT_ID ?: ''}", "REQ_MODE=${params.MODE}",
               "REQ_CALLER=jenkins-form:${uid}"]) {
        dir('poc-control-plane-federation') { sh 'set +x; bash scripts/provision-request.sh' }
      }
    }
  }
}
```

Si `getBuildCauses` bute sur la sandbox du Jenkins du lab, relève le motif
utilisé ailleurs dans le dépôt ou approuve la signature — ne contourne pas en
désactivant la sandbox.

- [ ] **Step 2: Preuve**

```bash
bash scripts/setup-team-onboard-jobs.sh
# déclenchement par API avec paramètres → une PR provision/<app>-dev apparaît,
# portant le manifeste — LE MÊME aval que la voie OIG (plan existant compris).
# Vérifier le commit/manifeste : caller=jenkins-form:<uid>. Puis fermer la PR,
# supprimer la branche.
```

- [ ] **Step 3: Commit**

```bash
git add poc-control-plane-federation/ci/jenkins/app-request.job.xml poc-control-plane-federation/scripts/setup-team-onboard-jobs.sh
git commit -m "feat(provisioning): formulaire app-request — deux portes, un seul aval"
```

---

### Task 8: `test-team-onboarding-chain.sh` — la matrice à 9 points

**Files:**
- Create: `scripts/test-team-onboarding-chain.sh`

**Interfaces:**
- Consumes: tout ce qui précède ; conventions maison (`PASS`/`FAIL`, `ok()`/`bad()`, exit non nul, cf. `scripts/test-onboard-team.sh` du palier 1).
- Produces: la preuve rejouable du palier 2 (§7 du spec).

- [ ] **Step 1: Écrire le script**

Entrées obligatoires, aucune par défaut vers un système en service :
`GITEA_URL` (`:?`), `GITEA_TOKEN` (`:?`), `VAULT_ADDR` (`:?`), `VAULT_TOKEN`
(`:?`, via fichier header en interne), `WM_GATEWAY_URL` (`:?` — le mock, jamais
5555), `JENKINS_UI` (`:?`). Équipe jetable `probe-p2`, org jetable, teardown en
`trap EXIT`.

Les 9 preuves, chacune un bloc `ok()`/`bad()` :

| # | Mécanisme |
|---|---|
| 1 | `TEAM='../evil'` puis `TEAM=$'a\nb'` sur `team-request.sh` → rc≠0 ET `git ls-remote` avant/après identique sur `onboard/*` |
| 2 | `TEAM=banking-demo` → rc≠0 avec `TEAM_ALREADY_DECLARED`, aucune PR nouvelle (compte via l'API) |
| 3 | `TEAM=probe-p2` nominal → PR ouverte, commentaire contenant `PLAN OK` ET les 4 dérivations (`svc-probe-p2`) |
| 4 | câblage : XML de `team-apply` porte filtre+garde+`MERGE_SHA` (grep) ; `assert-merge-identity.sh --merged-by ci --requester x --vault-user oscar` → `MERGER_MISMATCH` |
| 5 | merge réel de la PR via l'API (compte humain de test), puis `team-apply.sh` avec l'env du webhook simulé → org+dépôt créés (API 200), `ONBOARD_OK`, commentaire ✅ |
| 6 | re-run de `team-apply.sh` à l'identique → « déjà existant », rôle `changed=0` ; **la preuve exige aussi que le run 5 ait réellement créé** (l'API répondait 404 avant) |
| 7 | `provision-request.sh` avec `REQ_MODE=internal REQ_CALLER=jenkins-form:probe` → PR `provision/*` ouverte (l'aval existant la prend en charge) ; fermeture derrière |
| 8 | sondage `ps -ww` en continu pendant 5-7 : aucun token en argv |
| 9 | teardown : org, dépôt, PR, branche, policy `deploy-probe-p2`, KV, objets gateway du mock — puis relecture : rien d'orphelin |

- [ ] **Step 2: Le script doit savoir rougir**

Casse une garde (par ex. renomme temporairement `TEAM_ALREADY_DECLARED` dans
`team-request.sh`) → la preuve 2 doit passer FAIL et le script sortir ≠0.
Restaure. Un harnais de preuve jamais vu rouge est le défaut n°1 de ce dépôt.

- [ ] **Step 3: Run complet + garde de secrets**

```bash
GITEA_URL=… GITEA_TOKEN=… VAULT_ADDR=… VAULT_TOKEN=… WM_GATEWAY_URL=… JENKINS_UI=… \
  bash scripts/test-team-onboarding-chain.sh    # attendu : 9 PASS / 0 FAIL, exit 0
bash scripts/check-no-plaintext-secrets.sh       # rc=0
```

- [ ] **Step 4: Commit**

```bash
git add poc-control-plane-federation/scripts/test-team-onboarding-chain.sh
git commit -m "test(onboard): matrice palier 2 — 9 preuves sur equipe jetable

La preuve 6 (re-run convergent) est la douve de ce palier : elle distingue
« le job a tourné » de « le job converge » — et elle exige que le premier
passage ait réellement créé, sinon elle ne prouverait rien."
```

---

## Auto-relecture

**Couverture du spec.** §3 → Tasks 1-2. §4 → Tasks 6-7. §5 → Tasks 4-5. §6 →
gardes réparties dans 1, 4 et 5, chacune contre-éprouvée. §7 → Task 8 (les 9
points, mêmes numéros). §8 prérequis → Task 3. Hors périmètre du spec (rec/int/
prod, notification custom, surface d'approbation runtime) → gardé `ENV_NOT_OPEN`,
rien de planifié — conforme.

**Cohérence des noms.** `TEAM/DESCRIPTION/APPROVERS/REPO/REQ_ENV` (Task 1 ↔ 2 ↔ 8) ;
`PR_BRANCH/PR_NUMBER/MERGE_SHA/GITEA_TOKEN/VAULT_ADDR/VAULT_TOKEN_FILE/APIM_API_BASE`
(Task 4 ↔ 5 ↔ 8) ; `REQ_MODE/REQ_CLIENT_ID/REQ_CALLER` (Task 6 ↔ 7 ↔ 8) ;
`secret/stoa/ci/gitea-org-admin` et `team-onboarder` (Task 3 ↔ 4) ;
`onboard/<team>-<env>` partout.

**Inconnues assumées, traitées comme des mesures et non des suppositions** —
chaque tâche concernée porte son étape « relever avant d'écrire » :
1. le mécanisme create-or-update des jobs (`setup-provision-jobs.sh`) — Task 2 ;
2. le user admin Gitea réel et le motif d'attache de policy userpass — Task 3 ;
3. le contrat exact de `ci/lib/vault-login.sh` et le nom de service in-cluster
   de la gateway — Task 5 (le gabarit du job XML est explicitement à compléter) ;
4. la ligne de dérivation mode=f(caller) et l'usage réel de `clientId` en mode
   internal — Task 6 ;
5. la signature `getBuildCauses` dans la sandbox du lab — Task 7.

**Leçons du palier 1 câblées dans le plan** : `\Z`/le `\n` interne (Task 1),
header-file partout, `${VAR:?}` sans littéral, cibles sans défaut, preuve
d'idempotence exigeant le passage créateur (Tasks 4 et 8), contre-épreuve de
chaque garde, le harnais qui doit savoir rougir (Task 8 Step 2).
