# Le récepteur de webhooks à deux visages (`WEBHOOK_KIND`) — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `provision-plan`, `provision-apply` et `selfservice-app-deploy` posent leur déclencheur eux-mêmes, selon la globale Jenkins `WEBHOOK_KIND=gwt|gitlab`, pour qu'un client sans le plugin generic-webhook-trigger mais avec le GitLab Plugin déroule la chaîne app-request de bout en bout.

**Architecture:** Plus aucun bloc Declarative `triggers {}` / `options {}` (le symbole est résolu au parse, le job meurt sans le plugin). Le premier stage « Contexte du webhook » (sans agent) exécute `properties([disableConcurrentBuilds(), pipelineTriggers([<visage>])])` selon le knob, refuse toute valeur inconnue avant de poser quoi que ce soit, et pose le fait unifié `PR_BRANCH / PR_NUMBER / MERGE_SHA` depuis un troisième visage (`gitlab*`). Les XML deviennent `<properties/>` ; le poseur attend et relit l'amorçage.

**Tech Stack:** Jenkins Declarative + `properties()` scripté, plugin generic-webhook-trigger 2.4.x, GitLab Plugin ≥ 1.7.13, bash + python3 (harnais, ElementTree), GitLab CE 17.11 du lab, Gitea du lab.

**Spec:** `docs/superpowers/specs/2026-09-11-webhook-kind-deux-visages-design.md`

## Global Constraints

- Périmètre : `ci/Jenkinsfile.provision-plan`, `ci/Jenkinsfile.provision-apply`, `ci/Jenkinsfile.selfservice` et leurs coquilles/poseurs/suites. Les cinq autres Jenkinsfile à `GenericTrigger` **ne sont pas touchés**.
- Knob : `WEBHOOK_KIND` ∈ {`gwt`, `gitlab`}, défaut `gwt`, lu `"${env.WEBHOOK_KIND ?: 'gwt'}"`, OPTIONNELLE dans `setup-jenkins-globals.sh`.
- Refus nommés : `REFUS: WEBHOOK_KIND_INVALIDE` (Jenkinsfile, **avant** `properties()`), `AMORCAGE_INCOMPLET` (poseur).
- Le corps `GenericTrigger(...)` est déplacé **octet pour octet** (quotes simples, `\\|`, maps `[key:, value:]` nues, aucune virgule finale) — le miroir `gwt-mirror.sh` le relit tel quel.
- Exactement **un** `GenericTrigger(` et **un** `gitlab(` en vue code par Jenkinsfile plan/apply ; jamais `GenericTrigger(` dans un `/* */` ni dans une chaîne avant l'appel.
- Interdits déjà gardés par les suites : le mot `input` dans plan (`test-a0-wiring.sh:182`), `try/catch` avant `post {}` (`:185`), un bloc `parameters {}` de niveau pipeline, `sh """`.
- `secretToken` du visage gitlab = le mot du token GWT : `'stoa-provision-plan'`, `'stoa-provision-apply'`.
- Visage gitlab, **figés à false** : `triggerOnPush`, `triggerOnNoteRequest`, `ciSkip`, `setBuildDescription`, `skipWorkInProgressMergeRequest`, `triggerOnClosedMergeRequest`, `triggerOnApprovedMergeRequest`, `triggerOnPipelineEvent`, `triggerToBranchDeleteRequest`, `cancelPendingBuildsOnUpdate`, `cancelRunningBuildsOnUpdate`. Filtre `branchFilterType: 'RegexBasedFilter'`, `sourceBranchRegex: 'provision/.*'`, `targetBranchRegex: '.*'`.
- Commits : `type(scope): description` (commitlint), sur `main`, jamais poussés sans demande ; identité git du dépôt (`provisioning (service ci)`).
- Le lab : Jenkins `http://localhost:18080` (conteneur `poc-jenkins`, sans sécurité, crumb actif), GitLab `http://localhost:13080` depuis le poste / `http://gitlab:80` depuis Jenkins (conteneur `poc-gitlab`, projet `ci/stoa-labs` id 1, PAT dans `.env.gitlab-lab`), Gitea `http://localhost:13000`.
- Jamais éditer un bash qui tourne ; `http.postBuffer 524288000` sur tout push > 1 Mio vers GitLab ; `zsh` ne découpe pas les variables non quotées ⇒ `bash -c`.

---

## Structure des fichiers

| Fichier | Rôle dans ce lot |
|---|---|
| `scripts/spike-webhook-kind-m1.sh` (créer) | M1 : trois jobs jetables sur le Jenkins du lab, AVANT gitlab-plugin |
| `scripts/spike-webhook-kind-m5.sh` (créer) | M5 : installer gitlab-plugin au lab, vérifier GWT intact |
| `scripts/spike-webhook-kind-m2m4.sh` (créer) | M2 (doublon) et M4 (fenêtre d'amorçage) |
| `scripts/spike-webhook-kind-m6m9.sh` (créer) | M6..M9 : payloads réels, table état×action, variables, 401 |
| `adr/adr-098-recepteur-de-webhooks-a-deux-visages.md` (créer) | brouillon dès le spike, finalisé en Task 15 |
| `scripts/lib/gwt-mirror.sh` (modifier `:5-11`, `:97-101`) | entête corrigé ; la ligne `DIVERGENCE trigger xml=absent jenkinsfile=present` porte `token=… vars=N` |
| `scripts/test-a0-wiring.sh` (modifier §2, §3, §7, §8 ; créer §3bis, §8bis) | la porte hors ligne du lot |
| `ci/Jenkinsfile.provision-plan` (modifier `:74-113`, `:117-139`, `:148-178`) | deux visages + troisième visage |
| `ci/Jenkinsfile.provision-apply` (modifier `:70-132`, `:136-177`, `:188-218`) | idem |
| `scripts/test-provision-apply-wiring.sh` (modifier `:47`, `:83-89`, `:110-117`) | suit le XML vide et le `properties()` |
| `scripts/test-provision-apply-a4.sh` (modifier `:485-489`) | le littéral « 152/152 » |
| `scripts/test-team-publish-wiring.sh` (modifier `:139-147`) | §3ter : rc 2 attendu pour plan/apply |
| `ci/jenkins/provision-plan.job.xml`, `ci/jenkins/provision-apply.job.xml` (modifier `<properties>`) | `<properties/>` |
| `ci/Jenkinsfile.selfservice` (modifier `:74-100`, `:182-188`) | hook direct seulement sous `gwt` |
| `scripts/setup-selfservice-job.sh` (modifier `:371-373`) | relecture : trigger attendu selon `WEBHOOK_KIND` |
| `scripts/setup-provision-jobs.sh` (modifier `:19-32`, `:59-76`, `:332-345`) | amorçage attendu et relu ; défaut `BOOTSTRAP_JOBS` |
| `scripts/test-setup-provision-jobs.sh` (modifier faux Jenkins, §14 ; créer §16) | la relecture de l'amorçage contre le faux Jenkins |
| `scripts/setup-jenkins-globals.sh` (modifier entête, `:194-203`, `:216`) | `WEBHOOK_KIND` connu, optionnel, documenté |
| `ci/jenkins/Dockerfile` (modifier `:39`) | `gitlab-plugin` au lab |
| `scripts/test-webhook-kind-gitlab-live.sh` (créer) | la preuve live du visage gitlab |
| `ENVIRONNEMENTS.md` (créer § L6 ; modifier `:177-179`, `:258-261`, `:611-613`, `:1006-1009`) | doc client |
| `docs/superpowers/plans/2026-09-09-forge-agnostique-debug-branche.md` (modifier) | Task 7 (L6) → renvoi vers ce plan |

## Ordre et pourquoi

Tasks 1-3 = le spike (jetable, mesure les faits porteurs, **avant tout code**). Tasks 4-11 = la porte hors ligne en TDD puis le code. Task 12 = `make lint-ci`. Tasks 13-14 = preuves live (gwt puis gitlab). Task 15 = doc, ADR, plan. Si Task 1 (M1) ou Task 3 (M6) contredisent la spec §4, **s'arrêter** et revenir à la spec.

---

### Task 1 (spike M1) : le symbole se résout au parse en Declarative, à l'invocation en scripté

**Files:**
- Create: `scripts/spike-webhook-kind-m1.sh`
- Create: `adr/adr-098-recepteur-de-webhooks-a-deux-visages.md` (brouillon, front matter + § « Ce que le spike a mesuré »)

**Interfaces:**
- Produces: la fonction de pose de job jetable `spike_job <nom> <xml>` et les helpers `jcrumb`/`jpost`/`jresult`/`jconsole` réutilisés par les autres spikes (chaque spike les redéfinit — scripts jetables, pas une lib).

- [ ] **Step 1: Vérifier que gitlab-plugin est ABSENT du Jenkins du lab (précondition de M1)**

Run: `curl -s 'http://localhost:18080/pluginManager/api/json?tree=plugins[shortName,version]' | python3 -c 'import sys,json; d=json.load(sys.stdin); p={x["shortName"]:x["version"] for x in d["plugins"]}; print("gwt", p.get("generic-webhook-trigger")); print("gitlab", p.get("gitlab-plugin"))'`
Expected: `gwt 2.4.3` (ou proche) et `gitlab None`. Si `gitlab` est déjà présent, M1 se joue avec un autre symbole absent (remplacer `gitlab(` par `bitbucketPush(` dans le script) — noter dans l'ADR.

- [ ] **Step 2: Écrire le spike**

```bash
#!/usr/bin/env bash
# scripts/spike-webhook-kind-m1.sh — M1 (spec 2026-09-11 §9.1) : sur un Jenkins
# SANS le plugin qui porte le symbole, (a) un `triggers { gitlab(...) }`
# déclaratif meurt au PARSE ; (b) le même symbole dans un `properties()`
# scripté sous `if (false)` ne meurt PAS ; (c) sous `if (true)` il meurt à
# l'INVOCATION. Jetable : trois jobs spike-m1-*, supprimés à la fin.
set -uo pipefail
J="${JENKINS_UI:-http://localhost:18080}"
TMP="$(mktemp -d /tmp/spkm1.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
CK="$TMP/ck"
jcrumb(){ curl -sf -c "$CK" "$J/crumbIssuer/api/json" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["crumbRequestField"]+": "+d["crumb"])'; }
CR="$(jcrumb)"
jpost(){ curl -s -b "$CK" -H "$CR" -X POST "$@"; }
jresult(){ curl -s "$J/job/$1/$2/api/json?tree=result,building" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("result") or ("BUILDING" if d.get("building") else ""))'; }
jconsole(){ curl -s "$J/job/$1/$2/consoleText"; }
spike_job(){ # <nom> <groovy> — crée (ou remplace) un job Pipeline inline
  local n="$1" g="$2" hc
  python3 - "$n" "$g" > "$TMP/$n.xml" <<'PY'
import sys, xml.sax.saxutils as X
n, g = sys.argv[1], sys.argv[2]
print(f"""<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job"><description>spike M1 {n}</description><keepDependencies>false</keepDependencies><properties/>
<definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps"><script>{X.escape(g)}</script><sandbox>true</sandbox></definition>
<disabled>false</disabled></flow-definition>""")
PY
  jpost "$J/job/$n/doDelete" -o /dev/null >/dev/null 2>&1 || true
  hc=$(jpost "$J/createItem?name=$n" -H 'Content-Type: application/xml; charset=utf-8' --data-binary @"$TMP/$n.xml" -o /dev/null -w '%{http_code}')
  [ "$hc" = 200 ] || { echo "!! createItem $n : HTTP $hc"; exit 1; }
}
run_and_wait(){ # <nom> → résultat
  local n="$1" i r
  jpost "$J/job/$n/build" -o /dev/null -w '' >/dev/null
  for i in $(seq 1 60); do r=$(jresult "$n" 1 2>/dev/null); [ -n "$r" ] && [ "$r" != BUILDING ] && { echo "$r"; return; }; sleep 2; done
  echo TIMEOUT
}
spike_job spike-m1-a "pipeline { agent none; triggers { gitlab(triggerOnPush: false) }; stages { stage('x') { steps { echo 'x' } } } }"
spike_job spike-m1-b "pipeline { agent none; stages { stage('x') { steps { script { if (false) { properties([pipelineTriggers([gitlab(triggerOnPush: false)])]) }; echo 'ok-b' } } } } }"
spike_job spike-m1-c "pipeline { agent none; stages { stage('x') { steps { script { if (true) { properties([pipelineTriggers([gitlab(triggerOnPush: false)])]) }; echo 'ok-c' } } } } }"
for n in spike-m1-a spike-m1-b spike-m1-c; do
  R=$(run_and_wait "$n"); jconsole "$n" 1 > "$TMP/$n.console"
  case "$n" in
    *-a) grep -q 'Invalid trigger type' "$TMP/$n.console" && [ "$R" = FAILURE ] && echo "M1(a) CONFIRMÉ : Declarative meurt au parse ($R, « Invalid trigger type »)" || echo "M1(a) INATTENDU : $R — $(grep -m1 -i 'error\|invalid' "$TMP/$n.console")";;
    *-b) [ "$R" = SUCCESS ] && grep -q 'ok-b' "$TMP/$n.console" && echo "M1(b) CONFIRMÉ : symbole sous if(false) en scripté ⇒ SUCCESS" || echo "M1(b) INATTENDU : $R — $(grep -m1 -i 'error\|no such' "$TMP/$n.console")";;
    *-c) [ "$R" = FAILURE ] && grep -qi 'No such DSL method' "$TMP/$n.console" && echo "M1(c) CONFIRMÉ : symbole invoqué ⇒ FAILURE à l'invocation (« No such DSL method »)" || echo "M1(c) INATTENDU : $R — $(grep -m1 -i 'error\|no such' "$TMP/$n.console")";;
  esac
done
for n in spike-m1-a spike-m1-b spike-m1-c; do jpost "$J/job/$n/doDelete" -o /dev/null; done
echo "jobs jetables supprimés"
```

- [ ] **Step 3: Jouer le spike**

Run: `bash scripts/spike-webhook-kind-m1.sh`
Expected: trois lignes `M1(a) CONFIRMÉ`, `M1(b) CONFIRMÉ`, `M1(c) CONFIRMÉ`. Toute ligne `INATTENDU` = retour à la spec §4.1 avant de continuer (le design repose sur (b)).

- [ ] **Step 4: Ouvrir le brouillon de l'ADR-098 avec la table du spike**

Créer `adr/adr-098-recepteur-de-webhooks-a-deux-visages.md` sur le gabarit d'`adr/adr-097-*.md` (front matter `title`, `sidebar_label: "ADR-098 : le récepteur de webhooks (L6)"`, `status: "BROUILLON — spike en cours (2026-09-11)"`, `date: 2026-09-11`, `adr_number: 98`, `lié:` `[[adr-090-terminus-et-identite-de-forge]]`), un `# ADR-098 — Le récepteur de webhooks à deux visages (L6)`, un `## Contexte` (deux paragraphes : le client sans GWT ; le symbole résolu au parse), puis :

```markdown
## Ce que le spike a mesuré (2026-09-11, Jenkins 2.541.3 du lab)

| # | Mesure | Attendu | Mesuré |
|---|---|---|---|
| M1(a) | `triggers { gitlab(...) }` déclaratif, plugin absent | FAILURE au parse, « Invalid trigger type » | <résultat de la ligne M1(a)> |
| M1(b) | `if (false) { properties([pipelineTriggers([gitlab(...)])]) }` | SUCCESS | <…> |
| M1(c) | `if (true) { … }` | FAILURE « No such DSL method » | <…> |
```
(les lignes M2..M9 s'ajoutent en Tasks 2-3).

- [ ] **Step 5: Commit**

```bash
git add scripts/spike-webhook-kind-m1.sh adr/adr-098-recepteur-de-webhooks-a-deux-visages.md
git commit -m "spike(l6): M1 — le symbole d'un trigger se résout au parse en Declarative, à l'invocation en scripté (mesuré au lab)"
```

---

### Task 2 (spike M5, M2, M4) : installer gitlab-plugin au lab ; doublon ; fenêtre d'amorçage

**Files:**
- Create: `scripts/spike-webhook-kind-m5.sh`
- Create: `scripts/spike-webhook-kind-m2m4.sh`
- Modify: `adr/adr-098-recepteur-de-webhooks-a-deux-visages.md` (lignes M5, M2, M4)

- [ ] **Step 1: Écrire M5**

```bash
#!/usr/bin/env bash
# scripts/spike-webhook-kind-m5.sh — M5 : gitlab-plugin sur le Jenkins du lab
# (conteneur poc-jenkins), GWT intact, restart (le cache de parse Declarative
# meurt avec la JVM : aucune attente de 10 min après un restart).
set -uo pipefail
J="${JENKINS_UI:-http://localhost:18080}"; C="${JENKINS_CONTAINER:-poc-jenkins}"
plugins(){ curl -s "$J/pluginManager/api/json?tree=plugins[shortName,version,active]" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("\n".join(f"{p[\"shortName\"]} {p[\"version\"]} {p[\"active\"]}" for p in d["plugins"]))'; }
plugins > /tmp/spk-m5-before.txt
docker exec "$C" jenkins-plugin-cli --plugins gitlab-plugin -d /var/jenkins_home/plugins || { echo "!! jenkins-plugin-cli KO"; exit 1; }
docker restart "$C" >/dev/null
for _ in $(seq 1 90); do curl -sf "$J/api/json" >/dev/null 2>&1 && break; sleep 2; done
plugins > /tmp/spk-m5-after.txt
grep -q '^gitlab-plugin .* True$' /tmp/spk-m5-after.txt && echo "M5 : gitlab-plugin $(grep '^gitlab-plugin' /tmp/spk-m5-after.txt | cut -d' ' -f2) ACTIF" || { echo "M5 INATTENDU : $(grep gitlab /tmp/spk-m5-after.txt)"; exit 1; }
grep -q '^generic-webhook-trigger .* True$' /tmp/spk-m5-after.txt && echo "M5 : GWT intact ($(grep '^generic-webhook-trigger' /tmp/spk-m5-after.txt | cut -d' ' -f2))" || echo "M5 INATTENDU : GWT absent/inactif"
diff <(grep -v '^gitlab-plugin\|^gitlab-api\|^caffeine-api\|^' /tmp/spk-m5-before.txt | sort) <(grep -v '^gitlab-plugin\|^gitlab-api\|^caffeine-api' /tmp/spk-m5-after.txt | sort) > /tmp/spk-m5-diff.txt && echo "M5 : aucun autre plugin modifié" || { echo "M5 : autres plugins modifiés (dépendances tirées) :"; cat /tmp/spk-m5-diff.txt; }
curl -s "$J/configure" -o /dev/null -w 'M5 : /configure HTTP %{http_code}\n'
```

- [ ] **Step 2: Jouer M5**

Run: `bash scripts/spike-webhook-kind-m5.sh`
Expected: `M5 : gitlab-plugin <version> ACTIF`, `M5 : GWT intact (2.4.3)`. Noter la version (prérequis client ≥ 1.7.13). Relever ensuite `useAuthenticatedEndpoint` : `docker exec poc-jenkins cat /var/jenkins_home/com.dabsquared.gitlabjenkins.connection.GitLabConnectionConfig.xml 2>/dev/null || echo "(pas de fichier : défaut TRUE)"`.

- [ ] **Step 3: Écrire M2 + M4**

```bash
#!/usr/bin/env bash
# scripts/spike-webhook-kind-m2m4.sh — M2 : XML porteur d'un GenericTrigger +
# properties([pipelineTriggers([GenericTrigger identique])]) ⇒ doublon au build 1,
# un seul au build 2 (le XML est PERDU, pas préservé). M4 : XML <properties/>,
# le webhook est MUET (404) avant la fin de l'amorçage, vivant après.
set -uo pipefail
J="${JENKINS_UI:-http://localhost:18080}"
TMP="$(mktemp -d /tmp/spkm2.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
CK="$TMP/ck"; CR="$(curl -sf -c "$CK" "$J/crumbIssuer/api/json" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["crumbRequestField"]+": "+d["crumb"])')"
jpost(){ curl -s -b "$CK" -H "$CR" -X POST "$@"; }
jresult(){ curl -s "$J/job/$1/$2/api/json?tree=result,building" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("result") or ("BUILDING" if d.get("building") else ""))'; }
ntrig(){ curl -s "$J/job/$1/config.xml" | python3 -c 'import sys,xml.etree.ElementTree as T; r=T.fromstring(sys.stdin.read()); print(sum(1 for e in r.iter() if e.tag.endswith("GenericTrigger")), sum(1 for e in r.iter() if e.tag.endswith("PipelineTriggersJobProperty")))'; }
build_wait(){ local n="$1" b="$2" i r; jpost "$J/job/$n/build" -o /dev/null; for i in $(seq 1 60); do r=$(jresult "$n" "$b" 2>/dev/null); [ -n "$r" ] && [ "$r" != BUILDING ] && { echo "$r"; return; }; sleep 2; done; echo TIMEOUT; }
mkjob(){ # <nom> <props-xml> <token>
  local n="$1" props="$2" tok="$3" g
  g="properties([pipelineTriggers([GenericTrigger(token: '$tok', genericVariables: [[key: 'X', value: '\$.x']], printContributedVariables: false, printPostContent: false)])]); echo 'posé'"
  python3 - "$n" "$props" "$g" > "$TMP/$n.xml" <<'PY'
import sys, xml.sax.saxutils as X
n, props, g = sys.argv[1:4]
print(f"""<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job"><description>spike {n}</description><keepDependencies>false</keepDependencies>{props}
<definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps"><script>{X.escape(g)}</script><sandbox>true</sandbox></definition>
<disabled>false</disabled></flow-definition>""")
PY
  jpost "$J/job/$n/doDelete" -o /dev/null >/dev/null 2>&1 || true
  jpost "$J/createItem?name=$n" -H 'Content-Type: application/xml; charset=utf-8' --data-binary @"$TMP/$n.xml" -o /dev/null -w "createItem $n HTTP %{http_code}\n"
}
GWT_XML='<properties><org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty><triggers><org.jenkinsci.plugins.gwt.GenericTrigger plugin="generic-webhook-trigger"><spec></spec><genericVariables><org.jenkinsci.plugins.gwt.GenericVariable><key>X</key><value>$.x</value></org.jenkinsci.plugins.gwt.GenericVariable></genericVariables><printPostContent>false</printPostContent><printContributedVariables>false</printContributedVariables><token>spike-m2</token><silentResponse>false</silentResponse></org.jenkinsci.plugins.gwt.GenericTrigger></triggers></org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty></properties>'
echo "═══ M2 : XML porteur + properties() identique ═══"
mkjob spike-m2 "$GWT_XML" spike-m2
echo "M2 avant tout build : GenericTrigger,PipelineTriggersJobProperty = $(ntrig spike-m2)"
echo "M2 build #1 : $(build_wait spike-m2 1) ; après = $(ntrig spike-m2)   (attendu 2 2 = DOUBLON)"
Q=$(curl -s -X POST -H 'Content-Type: application/json' -d '{"x":"1"}' "$J/generic-webhook-trigger/invoke?token=spike-m2"); echo "M2 invoke entre #1 et #2 : $(printf '%s' "$Q" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("jobs déclenchés :", list((d.get("jobs") or {}).keys()), "| triggerResults :", len(d.get("jobs") or {}))')"
sleep 8
echo "M2 build #2 (par le webhook) : $(jresult spike-m2 2) ; après = $(ntrig spike-m2)   (attendu 1 1 : le XML est PERDU, le Jenkinsfile reste)"
echo "═══ M4 : XML <properties/>, fenêtre d'amorçage ═══"
mkjob spike-m4 "<properties/>" spike-m4
HC=$(curl -s -o "$TMP/m4.out" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"x":"1"}' "$J/generic-webhook-trigger/invoke?token=spike-m4")
echo "M4 invoke AVANT amorçage : HTTP $HC — $(head -c 120 "$TMP/m4.out")   (attendu 404, aucun job)"
HC=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'X-Gitlab-Event: Merge Request Hook' -H 'Content-Type: application/json' -d '{"object_kind":"merge_request"}' "$J/project/spike-m4")
echo "M4 /project/spike-m4 AVANT tout trigger : HTTP $HC   (attendu 200 silencieux, aucun build)"
echo "M4 amorçage #1 : $(build_wait spike-m4 1) ; après = $(ntrig spike-m4)   (attendu 1 1)"
HC=$(curl -s -o "$TMP/m4b.out" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"x":"1"}' "$J/generic-webhook-trigger/invoke?token=spike-m4")
echo "M4 invoke APRÈS amorçage : HTTP $HC — $(python3 -c 'import sys,json; d=json.load(open(sys.argv[1])); print("jobs :", list((d.get("jobs") or {}).keys()))' "$TMP/m4b.out")   (attendu 200, spike-m4)"
for n in spike-m2 spike-m4; do jpost "$J/job/$n/doDelete" -o /dev/null; done; echo "jobs jetables supprimés"
```

- [ ] **Step 4: Jouer M2 + M4**

Run: `bash scripts/spike-webhook-kind-m2m4.sh`
Expected : M2 après #1 = `2 2` (doublon), après #2 = `1 1` ; M4 avant amorçage = HTTP 404 sur `invoke`, 200 sur `/project/`, après = 200 avec `spike-m4` dans `jobs`. Copier les lignes mesurées dans la table de l'ADR (M5, M2, M4). Si M2 rend `1 1` dès #1, la spec §4.1 est fausse sur le doublon — noter et continuer (la voie A reste valide, elle est juste moins nécessaire).

- [ ] **Step 5: Commit**

```bash
git add scripts/spike-webhook-kind-m5.sh scripts/spike-webhook-kind-m2m4.sh adr/adr-098-recepteur-de-webhooks-a-deux-visages.md
git commit -m "spike(l6): M5 gitlab-plugin au lab, M2 doublon XML+properties(), M4 fenêtre d'amorçage (mesurés)"
```

---

### Task 3 (spike M6..M9) : payloads réels GitLab, table état×action, variables, 401

**Files:**
- Create: `scripts/spike-webhook-kind-m6m9.sh`
- Modify: `adr/adr-098-recepteur-de-webhooks-a-deux-visages.md` (lignes M6..M9 + la table état×action mesurée)

- [ ] **Step 1: Vérifier la méthode de merge du projet du lab**

Run: `set -a; . .env.gitlab-lab; set +a; curl -s -H "PRIVATE-TOKEN: $GITLAB_LAB_TOKEN" http://localhost:13080/api/v4/projects/1 | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["path_with_namespace"], d["default_branch"], d["merge_method"])'`
Expected: `ci/stoa-labs <branche> merge`. Si `ff` ou `rebase_merge` : `curl -X PUT -H "PRIVATE-TOKEN: …" -d merge_method=merge http://localhost:13080/api/v4/projects/1`.

- [ ] **Step 2: Écrire M6..M9**

```bash
#!/usr/bin/env bash
# scripts/spike-webhook-kind-m6m9.sh — M6 (payloads réels des 6 événements de MR),
# M7 (table état×action → build, sur les deux gitlab(...) de la spec §6.1),
# M8 (variables gitlab* dans un build), M9 (X-Gitlab-Token). Jetable.
# PRÉREQUIS : M5 joué ; .env.gitlab-lab ; projet ci/stoa-labs en méthode « merge ».
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO" || exit 1
J="${JENKINS_UI:-http://localhost:18080}"; JIN="${JENKINS_INCLUSTER:-http://jenkins:8080}"
GL="${GITLAB_LAB_URL:-http://localhost:13080}"; PID=1
set -a; . ./.env.gitlab-lab; set +a; TOK="$GITLAB_LAB_TOKEN"
TMP="$(mktemp -d /tmp/spkm6.XXXXXX)"; HOOKS=""
CK="$TMP/ck"; CR="$(curl -sf -c "$CK" "$J/crumbIssuer/api/json" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["crumbRequestField"]+": "+d["crumb"])')"
jpost(){ curl -s -b "$CK" -H "$CR" -X POST "$@"; }
gl(){ curl -s -H "PRIVATE-TOKEN: $TOK" "$@"; }
gauth(){ GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'oauth2:%s' "$TOK" | base64 | tr -d '\n')" GIT_CONFIG_KEY_1=http.postBuffer GIT_CONFIG_VALUE_1=524288000 git "$@"; }
jnext(){ curl -sf "$J/job/$1/api/json?tree=nextBuildNumber" | python3 -c 'import sys,json;print(json.load(sys.stdin)["nextBuildNumber"])'; }
jconsole(){ curl -s "$J/job/$1/$2/consoleText"; }
cleanup(){
  for h in $HOOKS; do gl -X DELETE "$GL/api/v4/projects/$PID/hooks/$h" -o /dev/null; done
  [ -n "${IID:-}" ] && gl -X PUT "$GL/api/v4/projects/$PID/merge_requests/$IID" -d state_event=close -o /dev/null
  gauth push -q "$CLONE" --delete "$BR" 2>/dev/null || true
  for n in spike-raw spike-plan spike-apply; do jpost "$J/job/$n/doDelete" -o /dev/null 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT
mkjob(){ # <nom> <groovy>
  local n="$1" g="$2"
  python3 - "$n" "$g" > "$TMP/$n.xml" <<'PY'
import sys, xml.sax.saxutils as X
n, g = sys.argv[1:3]
print(f"""<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job"><description>spike {n}</description><keepDependencies>false</keepDependencies><properties/>
<definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps"><script>{X.escape(g)}</script><sandbox>true</sandbox></definition>
<disabled>false</disabled></flow-definition>""")
PY
  jpost "$J/job/$n/doDelete" -o /dev/null >/dev/null 2>&1 || true
  jpost "$J/createItem?name=$n" -H 'Content-Type: application/xml; charset=utf-8' --data-binary @"$TMP/$n.xml" -o /dev/null -w "createItem $n HTTP %{http_code}\n"
  jpost "$J/job/$n/build" -o /dev/null; sleep 12   # amorçage : pose le trigger
}
# Le récepteur BRUT (GWT, printPostContent) : capte le JSON de chaque événement.
mkjob spike-raw "properties([pipelineTriggers([GenericTrigger(token: 'spike-raw', genericVariables: [[key: 'GL_STATE', value: '\$.object_attributes.state'],[key: 'GL_ACTION', value: '\$.object_attributes.action'],[key: 'GL_SHA', value: '\$.object_attributes.merge_commit_sha'],[key: 'GL_OLDREV', value: '\$.object_attributes.oldrev'],[key: 'GL_USER', value: '\$.user.username'],[key: 'GL_LAST', value: '\$.object_attributes.last_commit.id']], printContributedVariables: true, printPostContent: false)])]); echo \"RAW state=\${env.GL_STATE} action=\${env.GL_ACTION} merge_sha=\${env.GL_SHA} oldrev=\${env.GL_OLDREV} user=\${env.GL_USER} last=\${env.GL_LAST}\""
GL_COMMON="triggerOnPush: false, triggerOnNoteRequest: false, ciSkip: false, setBuildDescription: false, skipWorkInProgressMergeRequest: false, triggerOnClosedMergeRequest: false, triggerOnApprovedMergeRequest: false, triggerOnPipelineEvent: false, triggerToBranchDeleteRequest: false, cancelPendingBuildsOnUpdate: false, cancelRunningBuildsOnUpdate: false, branchFilterType: 'RegexBasedFilter', sourceBranchRegex: 'provision/.*', targetBranchRegex: '.*'"
mkjob spike-plan  "node { properties([pipelineTriggers([gitlab(triggerOnMergeRequest: true, triggerOnAcceptedMergeRequest: false, triggerOpenMergeRequestOnPush: 'source', $GL_COMMON, secretToken: 'spike-plan')])]); sh 'env | grep ^gitlab | sort || true' }"
mkjob spike-apply "properties([pipelineTriggers([gitlab(triggerOnMergeRequest: false, triggerOnAcceptedMergeRequest: true, triggerOpenMergeRequestOnPush: 'never', $GL_COMMON, secretToken: 'spike-apply')])]); echo \"APPLY iid=\${env.gitlabMergeRequestIid} state=\${env.gitlabMergeRequestState} sha=\${env.gitlabMergeCommitSha} by=\${env.gitlabMergedByUser}\""
hook(){ # <url> <token> → id
  gl -X POST "$GL/api/v4/projects/$PID/hooks" -d "url=$1" -d "token=$2" -d merge_requests_events=true -d push_events=false -d enable_ssl_verification=false | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])'
}
H1=$(hook "$JIN/generic-webhook-trigger/invoke?token=spike-raw" spike-raw); H2=$(hook "$JIN/project/spike-plan" spike-plan); H3=$(hook "$JIN/project/spike-apply" spike-apply)
HOOKS="$H1 $H2 $H3"; echo "hooks posés : $HOOKS"
CLONE="$GL/ci/stoa-labs.git"; BASE="$(gauth ls-remote --symref "$CLONE" HEAD | sed -n 's#^ref: refs/heads/\(.*\)\tHEAD$#\1#p')"
BR="provision/spk-dev"; W="$TMP/w"; gauth clone -q --depth 1 -b "$BASE" "$CLONE" "$W"
git -C "$W" checkout -q -b "$BR"; echo "spk $(date +%s)" > "$W/spk.txt"; git -C "$W" add spk.txt; git -C "$W" -c user.name=spk -c user.email=spk@lab commit -qm "spk 1"; gauth -C "$W" push -q "$CLONE" "$BR"
snap(){ echo "$(jnext spike-raw) $(jnext spike-plan) $(jnext spike-apply)"; }
step(){ # <libellé> <avant> — attend 10 s et imprime les builds déclenchés par job
  sleep 10; local a="$2" b; b="$(snap)"
  echo "── $1 : raw +$(( $(cut -d' ' -f1 <<<"$b") - $(cut -d' ' -f1 <<<"$a") )) plan +$(( $(cut -d' ' -f2 <<<"$b") - $(cut -d' ' -f2 <<<"$a") )) apply +$(( $(cut -d' ' -f3 <<<"$b") - $(cut -d' ' -f3 <<<"$a") ))"
  local n=$(( $(cut -d' ' -f1 <<<"$b") - 1 )); jconsole spike-raw "$n" | grep '^RAW ' || true
}
S=$(snap); IID=$(gl -X POST "$GL/api/v4/projects/$PID/merge_requests" -d source_branch="$BR" -d target_branch="$BASE" -d title="spk" | python3 -c 'import sys,json;print(json.load(sys.stdin)["iid"])'); step "open (MR !$IID)" "$S"
S=$(snap); echo "spk 2" >> "$W/spk.txt"; git -C "$W" -c user.name=spk -c user.email=spk@lab commit -qam "spk 2"; gauth -C "$W" push -q "$CLONE" "$BR"; step "push d'un commit (update, nouveau SHA)" "$S"
S=$(snap); gl -X PUT "$GL/api/v4/projects/$PID/merge_requests/$IID" -d title="spk (titre)" -o /dev/null; step "update du TITRE (même SHA)" "$S"
S=$(snap); gl -X PUT "$GL/api/v4/projects/$PID/merge_requests/$IID" -d state_event=close -o /dev/null; step "close (sans merge)" "$S"
S=$(snap); gl -X PUT "$GL/api/v4/projects/$PID/merge_requests/$IID" -d state_event=reopen -o /dev/null; step "reopen (même SHA)" "$S"
S=$(snap); gl -X PUT "$GL/api/v4/projects/$PID/merge_requests/$IID/merge" -o "$TMP/merge.json"; step "merge" "$S"
echo "── M8 variables du build plan (dernier) :"; jconsole spike-plan "$(( $(jnext spike-plan) - 1 ))" | grep '^gitlab' | sed 's/^/   /'
echo "── M8 dernier build apply :"; jconsole spike-apply "$(( $(jnext spike-apply) - 1 ))" | grep '^APPLY ' | sed 's/^/   /'
echo "── merge_commit_sha selon l'API : $(python3 -c 'import sys,json;print(json.load(open(sys.argv[1])).get("merge_commit_sha"))' "$TMP/merge.json")"
echo "── M9 :"; curl -s -o /dev/null -w "   sans X-Gitlab-Token : HTTP %{http_code}\n" -X POST -H 'X-Gitlab-Event: Merge Request Hook' -H 'Content-Type: application/json' -d '{"object_kind":"merge_request","object_attributes":{"iid":1,"state":"opened","action":"open","source_branch":"provision/x","target_branch":"main"}}' "$J/project/spike-plan"
curl -s -o /dev/null -w "   mauvais X-Gitlab-Token : HTTP %{http_code}\n" -X POST -H 'X-Gitlab-Token: nope' -H 'X-Gitlab-Event: Merge Request Hook' -H 'Content-Type: application/json' -d '{"object_kind":"merge_request"}' "$J/project/spike-plan"
IID=""   # mergée : rien à fermer
```

- [ ] **Step 3: Jouer M6..M9**

Run: `bash scripts/spike-webhook-kind-m6m9.sh 2>&1 | tee /tmp/spk-m6m9.log`
Expected (spec §6.1) : open ⇒ raw +1 plan +1 apply +0 ; push ⇒ plan +1 ; titre ⇒ plan +0 ; close ⇒ +0 partout sauf raw ; reopen ⇒ plan +0 (SHA déjà construit) ; merge ⇒ apply +1, `APPLY … sha=<40 hex>` égal au `merge_commit_sha` de l'API ; M8 : `gitlabMergeRequestIid`, `gitlabSourceBranch`, `gitlabMergeRequestState=opened`, `gitlabMergeCommitSha=` (vide sur open) ; M9 : 401 / 401 (ou 403 selon `useAuthenticatedEndpoint`). Chaque ligne `RAW state=… action=…` donne le couple réel de l'événement.

- [ ] **Step 4: Reporter dans l'ADR**

Ajouter les lignes M5..M9 à la table, et une sous-section `### Table état×action mesurée` reprenant les six lignes `── <événement> : raw +n plan +n apply +n` + les couples `RAW state/action`. Si `merge` ne rend pas 40 hex, ou si `titre` construit un plan, corriger la spec §6.1 **avant** la Task 6.

- [ ] **Step 5: Commit**

```bash
git add scripts/spike-webhook-kind-m6m9.sh adr/adr-098-recepteur-de-webhooks-a-deux-visages.md
git commit -m "spike(l6): M6..M9 — payloads réels GitLab CE 17.11, table état×action des deux gitlab(...), variables gitlab*, X-Gitlab-Token (mesurés)"
```

---

### Task 4 : `gwt-mirror.sh` — l'entête dit vrai, et un Jenkinsfile seul est comptable

**Files:**
- Modify: `scripts/lib/gwt-mirror.sh:5-11`, `:97-101`
- Test: `scripts/test-a0-wiring.sh` §7 (`:930`), §8 (a) (`:964-967`)

**Interfaces:**
- Produces: `gwt_mirror_diff <xml> <jf>` rend, quand seul le Jenkinsfile déclare : `DIVERGENCE trigger xml=absent jenkinsfile=present token=<t> vars=<n>` (rc 2). Les autres sorties sont inchangées.

- [ ] **Step 1: Écrire le test qui échoue (a0-wiring §8 (a), ligne `:964-967`)**

Remplacer :
```bash
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q '^DIVERGENCE trigger xml=absent jenkinsfile=present' \
  && ok "XML sans <triggers> ⇒ rc 2 « DIVERGENCE trigger xml=absent » (le webhook serait borgne dès la pose)" \
  || ko "XML sans <triggers> non détecté (rc=$RC : $OUT)"
```
par :
```bash
[ "$RC" -eq 2 ] && [ "$OUT" = "DIVERGENCE trigger xml=absent jenkinsfile=present token=stoa-provision-apply vars=14" ] \
  && ok "XML sans <triggers> ⇒ rc 2 « DIVERGENCE trigger xml=absent jenkinsfile=present token=… vars=14 » (le côté présent est COMPTÉ)" \
  || ko "XML sans <triggers> : sortie inattendue (rc=$RC : $OUT)"
```
et en §7 (`:930`) remplacer `[ "$OUT" = "DIVERGENCE trigger xml=absent jenkinsfile=present" ]` par `[ "$OUT" = "DIVERGENCE trigger xml=absent jenkinsfile=present token=stoa-selfservice-plan vars=1" ]`.

- [ ] **Step 2: Le voir rouge**

Run: `bash scripts/test-a0-wiring.sh 2>&1 | grep -E '❌|RÉSULTAT'`
Expected: 2 ❌ (« sortie inattendue » et le miroir selfservice), `RÉSULTAT : 198/200`.

- [ ] **Step 3: Implémenter**

Dans `scripts/lib/gwt-mirror.sh`, remplacer les lignes 97-101 :
```python
if (xml_side is None) != (jf_side is None):
    print("DIVERGENCE trigger xml=%s jenkinsfile=%s" % (
        'present' if xml_side else 'absent', 'present' if jf_side else 'absent'))
    sys.exit(2)
```
par :
```python
if (xml_side is None) != (jf_side is None):
    # Le côté PRÉSENT est compté (token, nombre de clés) : depuis L6 c'est l'état
    # VOULU des jobs dont le Jenkinsfile pose seul son déclencheur (XML vide), et
    # les suites vérifient ce qu'il déclare sans avoir de XML à lui opposer.
    side = jf_side if jf_side is not None else xml_side
    print("DIVERGENCE trigger xml=%s jenkinsfile=%s token=%s vars=%d" % (
        'present' if xml_side else 'absent', 'present' if jf_side else 'absent',
        side['token'], len(side['vars'])))
    sys.exit(2)
```
Et remplacer l'entête lignes 5-11 par :
```bash
# POURQUOI CETTE LIB EXISTE. Sur un job « Pipeline from SCM », un bloc
# `triggers { GenericTrigger(...) }` déclaratif et le bloc <triggers> du
# config.xml décrivent le MÊME déclencheur — et c'est le XML qui GAGNE :
# Declarative ne remplace que les déclencheurs qu'il a lui-même posés
# (DeclarativeJobPropertyTrackerAction), un déclencheur venu d'un config.xml
# est préservé tel quel (mesuré sur le lab le 2026-08-06). ⚠ Ce n'est PAS
# vrai d'un `properties([pipelineTriggers([...])])` scripté : lui AJOUTE la
# sienne sans dédoublonner (doublon au build 1), puis retire les deux et
# repose la sienne au build 2 — le XML est PERDU (mesuré 2026-09-02, fait 10,
# re-mesuré 2026-09-11, M2). Depuis L6, provision-plan/apply/selfservice posent
# donc SEULS leur déclencheur et leur XML ne porte AUCUNE propriété : pour eux
# la sortie attendue est « DIVERGENCE trigger xml=absent jenkinsfile=present
# token=… vars=N » (rc 2), et c'est le côté Jenkinsfile que les suites lisent.
```
(les lignes suivantes de l'entête, à partir de « Une divergence entre les deux fichiers… », restent).

- [ ] **Step 4: Le voir vert**

Run: `bash scripts/test-a0-wiring.sh 2>&1 | tail -1 && shellcheck -x scripts/lib/gwt-mirror.sh && echo shellcheck-ok`
Expected: `RÉSULTAT : 200/200`, `shellcheck-ok`.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/gwt-mirror.sh scripts/test-a0-wiring.sh
git commit -m "fix(gwt-mirror): l'entête dit ce que properties() fait au XML (doublon puis perte, M2) ; le côté présent d'une divergence est compté (token, vars)"
```

---

### Task 5 : `test-a0-wiring.sh` — la porte du récepteur (§3bis, §8bis), et §2/§3/§8 qui suivent le XML vide — RED

**Files:**
- Modify: `scripts/test-a0-wiring.sh:42` (`EXPECTED_CHECKS`), `:104-106`, `:113-144`, `:156`, `:959-996`
- Create: §3bis (après §3), §8bis (après §8)

**Interfaces:**
- Produces: la fonction `recepteur_check <vue-code> <plan|apply>` (stdout = motifs manquants, rc 1 si un manque) utilisée par §3bis et par les mutations §8bis.

- [ ] **Step 1: Réécrire §2 (`:104-106`) : le miroir rend « xml=absent jenkinsfile=present » = état voulu**

Remplacer :
```bash
mirror_expect provision-apply 14
mirror_expect provision-plan 7
mirror_expect provisioning-request 7
```
par :
```bash
# L6 (2026-09-11) : provision-plan et provision-apply posent SEULS leur
# déclencheur (properties() scripté — un bloc déclaratif meurt au parse sans le
# plugin) et leur XML ne porte AUCUNE propriété (fait 10 : XML porteur +
# properties() = doublon puis perte, M2). L'état voulu est donc « xml=absent
# jenkinsfile=present », et le côté Jenkinsfile est compté.
solo_expect(){ # $1=job $2=nb de clés attendu
  local out rc
  out=$(gwt_mirror_diff "ci/jenkins/$1.job.xml" "ci/Jenkinsfile.$1" 2>&1); rc=$?
  [ "$rc" -eq 2 ] && [ "$out" = "DIVERGENCE trigger xml=absent jenkinsfile=present token=stoa-$1 vars=$2" ] \
    && ok "$1 : le déclencheur n'est QUE dans le Jenkinsfile (token stoa-$1, $2 clés) — XML sans propriété (L6)" \
    || ko "$1 : attendu « xml=absent jenkinsfile=present token=stoa-$1 vars=$2 », lu (rc=$rc) : $(printf '%s' "$out" | tr '\n' ' ')"
  python3 -c "import sys,xml.etree.ElementTree as T; r=T.parse(sys.argv[1]).getroot(); p=r.find('properties'); sys.exit(0 if p is not None and len(list(p))==0 else 1)" "ci/jenkins/$1.job.xml" \
    && ok "$1 : <properties/> VIDE dans le XML (ni trigger, ni DisableConcurrentBuilds — posés par le build)" \
    || ko "$1 : le XML porte encore une propriété (doublon au build 1, perte au build 2)"
}
solo_expect provision-apply 14
solo_expect provision-plan 7
mirror_expect provisioning-request 7
```

- [ ] **Step 2: Réécrire `gwt_filtre` (`:113-124`) pour lire le filtre côté JENKINSFILE**

Remplacer la fonction par :
```bash
gwt_filtre(){ # $1=job $2… CLÉ=VALEUR (les contribuées) → rc 0 si le filtre laisse passer
  local job="$1"; shift
  python3 - "ci/Jenkinsfile.$job" "$@" <<'PY2'
import re, sys
code = ''.join('\n' if ln.lstrip().startswith('//') else ln for ln in open(sys.argv[1], encoding='utf-8'))
m = re.search(r'GenericTrigger\s*\(', code); i, depth = m.end(), 1
while i < len(code) and depth:
    depth += {'(': 1, ')': -1}.get(code[i], 0); i += 1
body = code[m.end():i - 1]
def unq(s): return s.replace("\\\\", "\\").replace("\\'", "'")
def opt(n): return unq(re.search(r"\b%s\s*:\s*'((?:[^'\\]|\\.)*)'" % n, body).group(1))
keys = [unq(k) for k in re.findall(r"\[\s*key\s*:\s*'((?:[^'\\]|\\.)*)'", body)]
kv = dict(a.split('=', 1) for a in sys.argv[2:])
text = opt('regexpFilterText')
for k in sorted(keys, key=len, reverse=True):
    text = text.replace('$' + k, kv.get(k, ''))
sys.exit(0 if re.search(opt('regexpFilterExpression'), text) else 1)
PY2
}
```
et le commentaire au-dessus (« jouée sur le côté qui GAGNE (le XML) ») devient « jouée sur le SEUL côté qui déclare (le Jenkinsfile, L6) ». Les deux boucles d'assertions qui suivent ne changent pas ; leurs libellés « (XML, le côté qui gagne) » deviennent « (Jenkinsfile, le seul côté) ».

- [ ] **Step 3: §3 (`:156`) : `disableConcurrentBuilds()` DANS `properties([`**

Remplacer :
```bash
jfp 'disableConcurrentBuilds()' && ok "options { disableConcurrentBuilds() } — miroir de la propriété du XML" || ko "disableConcurrentBuilds absent (le XML l'a : divergence)"
```
par :
```bash
[ "$(grep -c 'properties(\[disableConcurrentBuilds(), pipelineTriggers(\[' "$TMP/jf-plan.code")" -eq 2 ] && ! grep -qE '^  options \{' "$TMP/jf-plan.code" \
  && ok "disableConcurrentBuilds() posé DANS properties() sous les DEUX visages, aucun options{} déclaratif (fait 10)" || ko "disableConcurrentBuilds : pas dans les deux properties(), ou options{} déclaratif encore là"
```

- [ ] **Step 4: Créer §3bis après §3 (avant `echo "== 4. …"`)**

```bash
echo
echo "== 3bis. le RÉCEPTEUR de webhooks (L6) : posé par properties(), deux visages, refus nommé AVANT, fait unifié APRÈS =="
# recepteur_check <vue code> <plan|apply> : imprime les motifs MANQUANTS, rc 1 si un seul manque.
# Structurel par ORDRE de lignes (code_line) et par COMPTE, jamais par simple présence.
recepteur_check(){
  local c="$1" j="$2" miss="" n l_if l_prop l_gl l_err l_fact l_first
  tr -s ' ' < "$c" > "$c.norm"
  grep -qE '^  (options|triggers) \{' "$c" && miss="$miss declaratif-present"
  grep -qF "WEBHOOK_KIND = \"\${env.WEBHOOK_KIND ?: 'gwt'}\"" "$c.norm" || miss="$miss env-WEBHOOK_KIND"
  l_if=$(code_line "$c" "if (hook == 'gwt') {"); l_gl=$(code_line "$c" "} else if (hook == 'gitlab') {")
  l_err=$(code_line "$c" 'error("REFUS: WEBHOOK_KIND_INVALIDE'); l_fact=$(code_line "$c" 'env.PR_BRANCH = env.PR_BRANCH ?:')
  l_prop=$(code_line "$c" 'properties([disableConcurrentBuilds(), pipelineTriggers([')
  [ -n "$l_if" ] && [ -n "$l_gl" ] && [ -n "$l_err" ] && [ -n "$l_fact" ] && [ -n "$l_prop" ] || miss="$miss ancres($l_if/$l_prop/$l_gl/$l_err/$l_fact)"
  if [ -z "$miss" ]; then
    [ "$l_if" -lt "$l_prop" ] && [ "$l_prop" -lt "$l_gl" ] && [ "$l_gl" -lt "$l_err" ] && [ "$l_err" -lt "$l_fact" ] || miss="$miss ordre(if=$l_if prop=$l_prop gitlab=$l_gl error=$l_err fait=$l_fact)"
  fi
  [ "$(grep -c 'GenericTrigger(' "$c")" -eq 1 ] || miss="$miss GenericTrigger(x$(grep -c 'GenericTrigger(' "$c"))"
  [ "$(grep -c 'gitlab(' "$c")" -eq 1 ] || miss="$miss gitlab(x$(grep -c 'gitlab(' "$c"))"
  [ "$(grep -c 'properties(\[disableConcurrentBuilds(), pipelineTriggers(\[' "$c")" -eq 2 ] || miss="$miss properties-x2"
  for k in "triggerOnPush: false" "triggerOnNoteRequest: false" "ciSkip: false" "setBuildDescription: false" "skipWorkInProgressMergeRequest: false" \
           "triggerOnClosedMergeRequest: false" "triggerOnApprovedMergeRequest: false" "triggerOnPipelineEvent: false" "triggerToBranchDeleteRequest: false" \
           "cancelPendingBuildsOnUpdate: false" "cancelRunningBuildsOnUpdate: false" \
           "branchFilterType: 'RegexBasedFilter'" "sourceBranchRegex: 'provision/.*'" "targetBranchRegex: '.*'" "secretToken: 'stoa-provision-$j'" \
           "env.gitlabSourceBranch" "env.gitlabMergeRequestIid" "env.gitlabMergeRequestState"; do
    grep -qF -- "$k" "$c.norm" || miss="$miss [$k]"
  done
  if [ "$j" = plan ]; then
    for k in "triggerOnMergeRequest: true" "triggerOnAcceptedMergeRequest: false" "triggerOpenMergeRequestOnPush: 'source'" "!= 'opened'"; do grep -qF -- "$k" "$c.norm" || miss="$miss [$k]"; done
  else
    for k in "triggerOnMergeRequest: false" "triggerOnAcceptedMergeRequest: true" "triggerOpenMergeRequestOnPush: 'never'" "env.gitlabMergeCommitSha" "!= 'merged'"; do grep -qF -- "$k" "$c.norm" || miss="$miss [$k]"; done
  fi
  # jamais `GenericTrigger(` dans un /* */ ni une chaîne AVANT l'appel : la première occurrence en vue code EST l'appel
  l_first=$(grep -n 'GenericTrigger(' "$c" | head -1 | cut -d: -f1); n=$(sed -n "${l_first:-0}p" "$c")
  case "$n" in *"pipelineTriggers([GenericTrigger("*) ;; *) miss="$miss premiere-occurrence-hors-appel" ;; esac
  printf '%s' "$miss"; [ -z "$miss" ]
}
for J in plan apply; do
  code_view "ci/Jenkinsfile.provision-$J" > "$TMP/jf-$J.l6"
  MISS=$(recepteur_check "$TMP/jf-$J.l6" "$J") && ok "provision-$J : WEBHOOK_KIND lu (défaut gwt) ; if gwt → properties(GenericTrigger) ; else if gitlab → properties(gitlab(…table §6.1…)) ; else error(WEBHOOK_KIND_INVALIDE) ; le tout AVANT le fait unifié ; un seul GenericTrigger(, un seul gitlab( ; troisième visage gitlab* ; état relu" \
    || ko "provision-$J : récepteur mal câblé —$MISS"
done
```

- [ ] **Step 5: Réécrire §8 (b)(c) (`:969-981`) sur le JENKINSFILE, et créer §8bis**

Remplacer (b) et (c) :
```bash
# (b) token altéré dans le JENKINSFILE ⇒ rc 2 mais le token COMPTÉ diverge (le XML est vide, il n'y a plus de miroir à altérer).
sed "s#token: 'stoa-provision-apply',#token: 'stoa-provision-apply-MUTE',#" ci/Jenkinsfile.provision-apply > "$TMP/jf-token"
OUT=$(gwt_mirror_diff ci/jenkins/provision-apply.job.xml "$TMP/jf-token" 2>&1); RC=$?
[ "$RC" -eq 2 ] && [ "$OUT" = "DIVERGENCE trigger xml=absent jenkinsfile=present token=stoa-provision-apply-MUTE vars=14" ] \
  && ok "token altéré côté Jenkinsfile ⇒ le token COMPTÉ change (solo_expect rougirait)" || ko "token altéré non vu (rc=$RC : $OUT)"
# (c) la VALEUR d'une clé altérée côté JENKINSFILE ⇒ vars toujours 14 : le compte ne voit pas une VALEUR — c'est test-provision-apply-wiring §2 (grep de la ligne exacte) qui la garde.
sed "s#\[key: 'MERGE_SHA',        value: '\$.pull_request.merge_commit_sha'\]#[key: 'MERGE_SHA',        value: '\$.pull_request.head.sha']#" ci/Jenkinsfile.provision-apply > "$TMP/jf-val"
grep -q "head.sha" "$TMP/jf-val" || echo "  (avertissement : mutation (c) non appliquée)"
grep -qF "[key: 'MERGE_SHA', value: '\$.pull_request.merge_commit_sha']" <(tr -s ' ' < "$TMP/jf-val") \
  && ko "mutation (c) invisible au grep exact de la valeur de MERGE_SHA" || ok "valeur de MERGE_SHA altérée (head.sha) ⇒ le grep exact de test-provision-apply-wiring §2 rougit (le compte de clés, lui, ne le voit pas — dit ici)"
```
Puis, après (e), créer :
```bash
echo
echo "== 8bis. contre-épreuve du RÉCEPTEUR, par MUTATION (recepteur_check ROUGIT) =="
mut(){ # <libellé> <job> <sed>
  sed "$3" "ci/Jenkinsfile.provision-$2" > "$TMP/m.jf"; code_view "$TMP/m.jf" > "$TMP/m.l6"
  cmp -s "$TMP/m.jf" "ci/Jenkinsfile.provision-$2" && { ko "$1 : mutation NON appliquée"; return; }
  if recepteur_check "$TMP/m.l6" "$2" >/dev/null; then ko "$1 : mutation invisible"; else ok "$1 ⇒ rouge"; fi
}
mut "apply : triggerOnAcceptedMergeRequest true→false" apply "s/triggerOnAcceptedMergeRequest: true/triggerOnAcceptedMergeRequest: false/"
mut "plan : triggerOnMergeRequest true→false" plan "s/triggerOnMergeRequest: true/triggerOnMergeRequest: false/"
mut "apply : ciSkip false→true (une MR [ci-skip] tuerait l'apply)" apply "s/ciSkip: false/ciSkip: true/"
mut "plan : la branche else error() retirée" plan "/error(\"REFUS: WEBHOOK_KIND_INVALIDE/d"
mut "apply : if (hook == 'gwt') → if (false) (le visage gwt ne serait jamais posé)" apply "s/if (hook == 'gwt') {/if (false) {/"
mut "plan : gitlab( commenté" plan "s#pipelineTriggers(\[gitlab(#pipelineTriggers([/* gitlab( */ cron(#"
mut "apply : secretToken altéré" apply "s/secretToken: 'stoa-provision-apply'/secretToken: 'autre'/"
mut "plan : WEBHOOK_KIND sans défaut gwt" plan "s/WEBHOOK_KIND         = \"\${env.WEBHOOK_KIND ?: 'gwt'}\"/WEBHOOK_KIND         = \"\${env.WEBHOOK_KIND ?: ''}\"/"
mut "apply : le fait unifié AVANT properties()" apply "0,/^          def hook = env.WEBHOOK_KIND/s//          env.PR_BRANCH = env.PR_BRANCH ?: ''\n          def hook = env.WEBHOOK_KIND/"
```

- [ ] **Step 6: Mettre `EXPECTED_CHECKS` à jour et voir ROUGE**

§2 : 3 lignes `mirror_expect` (2 contrôles chacune = 6) deviennent 2 `solo_expect` (2 contrôles chacune = 4) + 1 `mirror_expect` (2) ⇒ 6, inchangé. §3bis : +2. §8bis : +9. Donc `EXPECTED_CHECKS=211`.

Run: `bash scripts/test-a0-wiring.sh 2>&1 | grep -E '❌|RÉSULTAT'`
Expected: rouge sur solo_expect ×4 (XML encore porteur, miroir MIROIR_OK), §3 (properties ×2 absent), §3bis ×2, §8bis (mutations « NON appliquée » ×9 car les motifs n'existent pas encore), `RÉSULTAT : ~194/211`. **Ne rien corriger dans le test** : c'est le rouge attendu avant les Tasks 6-8.

- [ ] **Step 7: Commit (le rouge est délibéré, dit dans le message)**

```bash
git add scripts/test-a0-wiring.sh
git commit -m "test(a0-wiring): porte du récepteur de webhooks L6 (§3bis structurel, §8bis 9 mutations), XML vide attendu (§2), filtre lu côté Jenkinsfile — ROUGE jusqu'aux Jenkinsfile/XML"
```

---

### Task 6 : `ci/Jenkinsfile.provision-plan` — deux visages posés, troisième visage lu

**Files:**
- Modify: `ci/Jenkinsfile.provision-plan:74-113` (retirer `options {}` + `triggers {}`), `:117-139` (`environment`), `:148-178` (stage « Contexte du webhook »)

- [ ] **Step 1: Retirer le bloc déclaratif**

Supprimer les lignes 75 (`options { disableConcurrentBuilds() }   // miroir du XML (un plan à la fois)`) et 77-113 (du commentaire `// ⚠ Ce bloc doit rester le MIROIR EXACT…` jusqu'à la `}` fermante de `triggers {`). À leur place, ce seul commentaire :
```groovy
  // Ni `options {}` ni `triggers {}` déclaratifs (L6, 2026-09-11) : un symbole
  // de déclencheur dans un bloc Declarative est résolu AU PARSE — sans le
  // plugin qui le porte, le job meurt avant son premier stage (« Invalid
  // trigger type », mesuré M1). Le déclencheur ET le verrou de concurrence sont
  // posés par un `properties()` scripté au premier stage, selon WEBHOOK_KIND ;
  // le XML de ce job ne porte AUCUNE propriété (fait 10 : XML porteur +
  // properties() = doublon au build 1, perte au build 2 — mesuré M2).
  // Volontairement PAS de bloc `parameters {}` : PR_BRANCH / PR_NUMBER ne
  // viennent QUE du webhook (un build manuel n'a aucune de ces variables →
  // c'est l'AMORÇAGE : il sort vert sans exécuteur, le déclencheur posé).
```

- [ ] **Step 2: Ajouter le knob dans `environment {}`**

Après la ligne `FORGE_API_BASE       = "${env.FORGE_API_BASE ?: ''}"` insérer :
```groovy
    // Le RÉCEPTEUR de webhooks de ce Jenkins (L6) : gwt (défaut = l'état
    // historique, generic-webhook-trigger, /generic-webhook-trigger/invoke?token=)
    // | gitlab (GitLab Plugin, /project/<job> + X-Gitlab-Token). Toute autre
    // valeur est refusée par nom AVANT de poser quoi que ce soit.
    WEBHOOK_KIND         = "${env.WEBHOOK_KIND ?: 'gwt'}"
```

- [ ] **Step 3: Poser le récepteur au premier stage, puis le troisième visage**

Dans `stage('Contexte du webhook') { steps { script {`, **avant** le commentaire `// ── UN SEUL nom par fait…`, insérer :
```groovy
          // ── LE RÉCEPTEUR (L6) : posé ICI, sans agent, avant tout refus ────
          // Deux visages, un seul posé ; un `if` non pris n'invoque pas le
          // symbole (mesuré M1). `disableConcurrentBuilds()` voyage avec lui :
          // un job re-posé perd ses options déclaratives au premier build
          // (fait 10). Le corps GenericTrigger(...) est relu par
          // scripts/lib/gwt-mirror.sh : quotes simples, maps nues, rien d'autre.
          def hook = env.WEBHOOK_KIND
          if (hook == 'gwt') {
            properties([disableConcurrentBuilds(), pipelineTriggers([GenericTrigger(
              token: 'stoa-provision-plan',
              genericVariables: [
                [key: 'PR_BRANCH',        value: '$.pull_request.head.ref'],
                [key: 'PR_NUMBER',        value: '$.pull_request.number'],
                [key: 'PR_ACTION',        value: '$.action'],
                [key: 'GL_KIND',          value: '$.object_kind'],
                [key: 'GL_IID',           value: '$.object_attributes.iid'],
                [key: 'GL_SOURCE_BRANCH', value: '$.object_attributes.source_branch'],
                [key: 'GL_ACTION',        value: '$.object_attributes.action'],
              ],
              regexpFilterText: '$PR_ACTION|$GL_KIND:$GL_ACTION',
              regexpFilterExpression: '^(opened|reopened|synchronized)\\||merge_request:(open|reopen|update)$',
              printContributedVariables: true,
              printPostContent: false)])])
          } else if (hook == 'gitlab') {
            // GitLab Plugin : open / reopen / nouveau SHA (jamais la fusion —
            // provision-apply l'écoute). Défauts TRUE du plugin figés à false
            // (ciSkip : une MR « [ci-skip] » n'aurait pas de plan ; triggerOnPush :
            // chaque push du dépôt construirait). Le secretToken est une SONNETTE
            // (le mot du token GWT), pas une autorité : la forge est relue.
            properties([disableConcurrentBuilds(), pipelineTriggers([gitlab(
              triggerOnMergeRequest: true, triggerOnAcceptedMergeRequest: false,
              triggerOpenMergeRequestOnPush: 'source',
              triggerOnPush: false, triggerOnNoteRequest: false, ciSkip: false, setBuildDescription: false,
              skipWorkInProgressMergeRequest: false, triggerOnClosedMergeRequest: false, triggerOnApprovedMergeRequest: false,
              triggerOnPipelineEvent: false, triggerToBranchDeleteRequest: false,
              cancelPendingBuildsOnUpdate: false, cancelRunningBuildsOnUpdate: false,
              branchFilterType: 'RegexBasedFilter', sourceBranchRegex: 'provision/.*', targetBranchRegex: '.*',
              secretToken: 'stoa-provision-plan')])])
          } else {
            error("REFUS: WEBHOOK_KIND_INVALIDE : '${hook}' — attendu gwt|gitlab (globale Jenkins WEBHOOK_KIND, setup-jenkins-globals.sh). Aucun déclencheur posé.")
          }
```
Puis remplacer les trois lignes du fait unifié :
```groovy
          env.PR_BRANCH = env.PR_BRANCH ?: (env.GL_SOURCE_BRANCH ?: '')
          env.PR_NUMBER = env.PR_NUMBER ?: (env.GL_IID ?: '')
          env.PR_ACTION = env.PR_ACTION ?: (env.GL_KIND ? "${env.GL_KIND}:${env.GL_ACTION ?: ''}" : '')
```
par :
```groovy
          // Trois visages : Gitea (PR_*), GitLab par GWT (GL_*), GitLab par son
          // plugin (gitlab*, posées par le plugin — il n'expose PAS l'action,
          // seulement l'ÉTAT : gitlabMergeRequestState).
          env.PR_BRANCH = env.PR_BRANCH ?: (env.GL_SOURCE_BRANCH ?: (env.gitlabSourceBranch ?: ''))
          env.PR_NUMBER = env.PR_NUMBER ?: (env.GL_IID ?: (env.gitlabMergeRequestIid ?: ''))
          env.PR_ACTION = env.PR_ACTION ?: (env.GL_KIND ? "${env.GL_KIND}:${env.GL_ACTION ?: ''}" : (env.gitlabMergeRequestState ? "merge_request:${env.gitlabMergeRequestState}" : ''))
          // Visage plugin : l'état est RELU dans le pipeline, pas seulement par
          // les cases du trigger (un état hors enum y devient un joker). Hors
          // `opened`, il n'y a aucune demande à planifier.
          def glState = env.gitlabMergeRequestState ?: ''
          if (glState && glState != 'opened') {
            echo "hook GitLab hors événement : state='${glState}' (attendu opened) — aucune demande à planifier."
            env.PR_BRANCH = ''
          }
```

- [ ] **Step 4: Compiler et jouer la porte**

Run: `ci/lint-jenkinsfiles.sh 2>&1 | tail -2 && bash scripts/test-a0-wiring.sh 2>&1 | grep -E '❌|RÉSULTAT'`
Expected: lint « PORTE VERTE » ; a0-wiring : plus aucun ❌ sur `provision-plan` en §3/§3bis/§8bis-plan ; restent rouges `solo_expect provision-plan` (XML encore porteur — Task 8) et tout ce qui concerne `apply` (Task 7).

- [ ] **Step 5: Commit**

```bash
git add ci/Jenkinsfile.provision-plan
git commit -m "feat(provision-plan): le récepteur de webhooks est posé par properties() selon WEBHOOK_KIND (gwt|gitlab), refus nommé avant, troisième visage gitlab* et état relu (L6)"
```

---

### Task 7 : `ci/Jenkinsfile.provision-apply` — idem, visage « fusion » ; suites `provision-apply-wiring` et `a4`

**Files:**
- Modify: `ci/Jenkinsfile.provision-apply:70-132`, `:136-177`, `:188-218`
- Modify: `scripts/test-provision-apply-wiring.sh:47`, `:83-84`, `:88-89`, `:110-117`
- Modify: `scripts/test-provision-apply-a4.sh:485-489`

- [ ] **Step 1: Écrire d'abord le test (provision-apply-wiring) — RED**

`:83-84` : remplacer
```bash
grep -q 'DisableConcurrentBuildsJobProperty' "$JOB" \
  && ok "un apply à la fois (DisableConcurrentBuilds dans le XML)" || ko "concurrence non interdite dans le XML"
```
par
```bash
python3 -c "import sys,xml.etree.ElementTree as T; p=T.parse(sys.argv[1]).getroot().find('properties'); sys.exit(0 if p is not None and len(list(p))==0 else 1)" "$JOB" \
  && ok "le XML ne porte AUCUNE propriété (<properties/>) : trigger et DisableConcurrentBuilds sont posés par le build (L6, fait 10)" || ko "le XML porte une propriété : doublon au build 1, perte au build 2"
```
`:88-89` : remplacer
```bash
jf "options { disableConcurrentBuilds() }" \
  && ok "disableConcurrentBuilds() dans le Jenkinsfile aussi" || ko "disableConcurrentBuilds absent du Jenkinsfile"
```
par
```bash
[ "$(grep -c 'properties(\[disableConcurrentBuilds(), pipelineTriggers(\[' "$TMP/jf.norm")" -eq 2 ] && ! grep -qE '^  (options|triggers) \{' "$TMP/jf.code" \
  && ok "disableConcurrentBuilds() DANS properties() sous les deux visages ; aucun options{}/triggers{} déclaratif (L6)" || ko "properties(disableConcurrentBuilds, pipelineTriggers) ≠ 2 occurrences, ou bloc déclaratif présent"
```
`:110-117` (de `MIRROR_KO=""` à la ligne `filterExpression identique dans le XML`) : remplacer les 5 contrôles par :
```bash
grep -q '<key>' "$JOB" && ko "le XML porte encore des genericVariables (L6 : le Jenkinsfile est le SEUL à déclarer)" || ok "aucune genericVariable dans le XML : le Jenkinsfile est le seul à déclarer (L6)"
```
Le titre du §2 devient `== 2. le webhook capte les 14 clés (7 Gitea + 7 GitLab), dont MERGE_SHA — dans le Jenkinsfile, seul déclarant (L6) ==`.
`EXPECTED_CHECKS` (`:47`) : 151 − 4 = **147**.

Run: `bash scripts/test-provision-apply-wiring.sh 2>&1 | grep -E '❌|RÉSULTAT'`
Expected: 3 ❌ (`<properties/>`, `properties() ×2`, genericVariables XML), `RÉSULTAT : 144/147`.

- [ ] **Step 2: Modifier le Jenkinsfile**

Supprimer la ligne 71 (`options { disableConcurrentBuilds() }   // un apply à la fois = régime bancaire`) et les lignes 73-132 (du commentaire `// Aucune charge utile n'est de confiance…` jusqu'à la `}` de `triggers {`). À leur place :
```groovy
  // Ni `options {}` ni `triggers {}` déclaratifs (L6, 2026-09-11) : un symbole
  // de déclencheur dans un bloc Declarative est résolu AU PARSE — sans le
  // plugin, le job meurt avant son premier stage (mesuré M1). Déclencheur et
  // verrou « un apply à la fois » sont posés par `properties()` au premier
  // stage, selon WEBHOOK_KIND ; le XML ne porte AUCUNE propriété (fait 10, M2).
  //
  // Aucune charge utile n'est de confiance : les clés du webhook ne servent qu'à
  // NOMMER ce qu'il faut relire sur la forge (PR_NUMBER) et dans l'état mergé
  // (MERGE_SHA). Trois visages : « pull_request » de Gitea (PR_*), « Merge
  // Request Hook » de GitLab par GWT (GL_*), et le GitLab Plugin (gitlab*, qui
  // n'expose pas l'action — l'ÉTAT est relu). Le stage « Contexte du webhook »
  // pose UN SEUL nom par fait (PR_BRANCH, PR_NUMBER, MERGE_SHA).
  // Volontairement PAS de bloc `parameters {}` : ces valeurs ne doivent venir
  // QUE du webhook (un paramètre de build permettrait à quiconque lance le job
  // de nommer lui-même MERGE_SHA ou PR_NUMBER). Un build manuel n'a aucune de
  // ces variables → c'est l'AMORÇAGE : vert, sans exécuteur, déclencheur posé.
```
Dans `environment {}`, après `FORGE_API_BASE        = "${env.FORGE_API_BASE ?: ''}"` :
```groovy
    // Le RÉCEPTEUR de webhooks de ce Jenkins (L6) : gwt (défaut) | gitlab.
    WEBHOOK_KIND          = "${env.WEBHOOK_KIND ?: 'gwt'}"
```
Dans le `script {}` de « Contexte du webhook », avant `// ── UN SEUL nom par fait…` :
```groovy
          // ── LE RÉCEPTEUR (L6) : posé ICI, sans agent, avant tout refus ────
          def hook = env.WEBHOOK_KIND
          if (hook == 'gwt') {
            properties([disableConcurrentBuilds(), pipelineTriggers([GenericTrigger(
              token: 'stoa-provision-apply',
              genericVariables: [
                [key: 'PR_BRANCH',        value: '$.pull_request.head.ref'],
                [key: 'PR_NUMBER',        value: '$.pull_request.number'],
                [key: 'PR_ACTION',        value: '$.action'],
                [key: 'PR_MERGED',        value: '$.pull_request.merged'],
                [key: 'PR_MERGED_BY',     value: '$.pull_request.merged_by.login'],
                [key: 'PR_REQUESTER',     value: '$.pull_request.user.login'],
                [key: 'MERGE_SHA',        value: '$.pull_request.merge_commit_sha'],
                [key: 'GL_KIND',          value: '$.object_kind'],
                [key: 'GL_IID',           value: '$.object_attributes.iid'],
                [key: 'GL_SOURCE_BRANCH', value: '$.object_attributes.source_branch'],
                [key: 'GL_ACTION',        value: '$.object_attributes.action'],
                [key: 'GL_STATE',         value: '$.object_attributes.state'],
                [key: 'GL_USER',          value: '$.user.username'],
                [key: 'GL_MERGE_SHA',     value: '$.object_attributes.merge_commit_sha'],
              ],
              regexpFilterText: '$PR_ACTION|$PR_MERGED|$GL_KIND:$GL_ACTION',
              regexpFilterExpression: '^closed\\|true\\||merge_request:merge$',
              printContributedVariables: true,
              printPostContent: false)])])
          } else if (hook == 'gitlab') {
            // GitLab Plugin : la FUSION seulement (action=merge). `never` ferme la
            // règle « état inconnu × update » du plugin. Défauts TRUE figés à false.
            properties([disableConcurrentBuilds(), pipelineTriggers([gitlab(
              triggerOnMergeRequest: false, triggerOnAcceptedMergeRequest: true,
              triggerOpenMergeRequestOnPush: 'never',
              triggerOnPush: false, triggerOnNoteRequest: false, ciSkip: false, setBuildDescription: false,
              skipWorkInProgressMergeRequest: false, triggerOnClosedMergeRequest: false, triggerOnApprovedMergeRequest: false,
              triggerOnPipelineEvent: false, triggerToBranchDeleteRequest: false,
              cancelPendingBuildsOnUpdate: false, cancelRunningBuildsOnUpdate: false,
              branchFilterType: 'RegexBasedFilter', sourceBranchRegex: 'provision/.*', targetBranchRegex: '.*',
              secretToken: 'stoa-provision-apply')])])
          } else {
            error("REFUS: WEBHOOK_KIND_INVALIDE : '${hook}' — attendu gwt|gitlab (globale Jenkins WEBHOOK_KIND, setup-jenkins-globals.sh). Aucun déclencheur posé.")
          }
```
Et le fait unifié :
```groovy
          env.PR_BRANCH = env.PR_BRANCH ?: (env.GL_SOURCE_BRANCH ?: (env.gitlabSourceBranch ?: ''))
          env.PR_NUMBER = env.PR_NUMBER ?: (env.GL_IID ?: (env.gitlabMergeRequestIid ?: ''))
          // A2 : la référence. Vide en fast-forward/squash (le plugin pose la
          // variable, vide) ⇒ la réconciliation refuse MERGE_SHA_INVALIDE.
          env.MERGE_SHA = env.MERGE_SHA ?: (env.GL_MERGE_SHA ?: (env.gitlabMergeCommitSha ?: ''))
          // Visage plugin : l'état est RELU ; hors `merged`, rien à appliquer.
          def glState = env.gitlabMergeRequestState ?: ''
          if (glState && glState != 'merged') {
            echo "hook GitLab hors événement : state='${glState}' (attendu merged) — aucune demande à appliquer."
            env.PR_BRANCH = ''
          }
```

- [ ] **Step 3: Compiler, jouer les deux suites, ajuster a4**

Run: `ci/lint-jenkinsfiles.sh 2>&1 | tail -1 && bash scripts/test-provision-apply-wiring.sh 2>&1 | tail -1 && bash scripts/test-a0-wiring.sh 2>&1 | grep -E '❌|RÉSULTAT'`
Expected: `RÉSULTAT : 147/147` ; a0-wiring : ne restent rouges que `solo_expect` ×4 (XML, Task 8).
Puis `scripts/test-provision-apply-a4.sh:485-489` : remplacer `152/152` par `147/147` dans le `grep -q` et le libellé, et le commentaire `# 152 depuis L3…` par `# 147 depuis L6 (2026-09-11) : le XML de l'apply ne porte plus de propriété, la suite A2 a perdu les 4 contrôles du miroir XML.`

- [ ] **Step 4: Commit**

```bash
git add ci/Jenkinsfile.provision-apply scripts/test-provision-apply-wiring.sh scripts/test-provision-apply-a4.sh
git commit -m "feat(provision-apply): récepteur posé par properties() selon WEBHOOK_KIND, visage gitlab = fusion seulement, MERGE_SHA depuis gitlabMergeCommitSha, état relu (L6) ; suites A2/A4 suivent"
```

---

### Task 8 : les deux XML deviennent `<properties/>` ; `team-publish-wiring` §3ter

**Files:**
- Modify: `ci/jenkins/provision-plan.job.xml:27-63`, `ci/jenkins/provision-apply.job.xml:27-67`
- Modify: `scripts/test-team-publish-wiring.sh:139-147`

- [ ] **Step 1: Test d'abord — `team-publish-wiring` §3ter**

Remplacer la boucle `for J3 in provision-apply provision-plan provisioning-request; do … done` par :
```bash
  for J3 in provision-apply provision-plan provisioning-request; do
    OUT3=$(gwt_mirror_diff "$REPO/ci/jenkins/$J3.job.xml" "$REPO/ci/Jenkinsfile.$J3" 2>&1); RC3=$?
    case "$J3" in
      provisioning-request)
        [ "$RC3" -eq 0 ] && printf '%s' "$OUT3" | grep -q '^MIROIR_OK' \
          && ok "$J3 : $OUT3" || ko "$J3 : miroir NON exact (rc=$RC3) — $(printf '%s' "$OUT3" | tr '\n' ' ')" ;;
      *)  # L6 : le Jenkinsfile pose SEUL son déclencheur, le XML est vide — état voulu
        [ "$RC3" -eq 2 ] && printf '%s' "$OUT3" | grep -q "^DIVERGENCE trigger xml=absent jenkinsfile=present token=stoa-$J3 vars=" \
          && ok "$J3 : $OUT3 (L6 : XML sans propriété, le Jenkinsfile déclare seul)" || ko "$J3 : attendu xml=absent jenkinsfile=present (rc=$RC3) — $(printf '%s' "$OUT3" | tr '\n' ' ')" ;;
    esac
  done
```
Run: `bash scripts/test-team-publish-wiring.sh 2>&1 | grep -E '❌|RÉSULTAT'`
Expected: 2 ❌ (plan, apply : MIROIR_OK au lieu de rc 2).

- [ ] **Step 2: Vider les propriétés des deux XML**

Dans chaque XML, remplacer tout le bloc de `  <properties>` à `  </properties>` (plan `:27-63`, apply `:27-67`) par :
```xml
  <!-- L6 (2026-09-11) : AUCUNE propriete ici. Le declencheur (selon la globale
       WEBHOOK_KIND) et DisableConcurrentBuilds sont poses par le Jenkinsfile
       (properties() scripte) au premier build - l'AMORCAGE, que le poseur
       attend et relit. Un XML porteur + properties() = doublon au build 1 puis
       PERTE au build 2 (fait 10, mesure M2). -->
  <properties/>
```
Dans l'entête de commentaire du XML (plan `:11-21`, apply : le paragraphe équivalent), remplacer le paragraphe « Le bloc <triggers> ci-dessous DOIT rester le miroir exact … c'est le XML qui fait foi » par : « Ce XML ne porte AUCUNE propriete (L6) : voir <properties/> ci-dessous. scripts/lib/gwt-mirror.sh rend pour ce job « xml=absent jenkinsfile=present », l'etat voulu. »

- [ ] **Step 3: Tout vert**

Run: `bash scripts/test-team-publish-wiring.sh 2>&1 | tail -1 && bash scripts/test-a0-wiring.sh 2>&1 | tail -1 && bash scripts/test-provision-apply-wiring.sh 2>&1 | tail -1`
Expected: trois `RÉSULTAT : N/N` sans ❌ (a0 : 211/211, apply-wiring : 147/147).

- [ ] **Step 4: Commit**

```bash
git add ci/jenkins/provision-plan.job.xml ci/jenkins/provision-apply.job.xml scripts/test-team-publish-wiring.sh
git commit -m "feat(jobs): provision-plan/apply.job.xml sans aucune propriété — le Jenkinsfile pose seul déclencheur et verrou (L6, fait 10) ; §3ter attend xml=absent"
```

---

### Task 9 : `ci/Jenkinsfile.selfservice` — le hook direct seulement sous `gwt` ; poseur selfservice

**Files:**
- Modify: `ci/Jenkinsfile.selfservice:74-100` (environment), `:182-188`
- Modify: `scripts/setup-selfservice-job.sh:371-373`
- Test: `scripts/test-a0-wiring.sh` §7 (`:928`)

- [ ] **Step 1: Test d'abord (§7, ligne `:928`) — RED**

Remplacer :
```bash
jss 'disableConcurrentBuilds(),' && jss "pipelineTriggers([GenericTrigger(token: 'stoa-selfservice-plan'," && ok "properties() pose AUSSI disableConcurrentBuilds et le trigger PLAN (stoa-selfservice-plan) — les trois propriétés en un seul pas (fait 10)" || ko "trigger/option absents de properties()"
```
par :
```bash
jss 'disableConcurrentBuilds(),' && jss "pipelineTriggers(hooks)," && jss "def hooks = (hook == 'gwt') ? [GenericTrigger(token: 'stoa-selfservice-plan'," && jss 'error("REFUS: WEBHOOK_KIND_INVALIDE' && jss "WEBHOOK_KIND      = \"\${env.WEBHOOK_KIND ?: 'gwt'}\"" \
  && ok "properties() pose disableConcurrentBuilds + le trigger PLAN (stoa-selfservice-plan) SOUS gwt SEULEMENT (L6 : sous gitlab, aucun hook direct — le plugin ne lit pas ce JSON), refus nommé sur un knob inconnu" || ko "trigger/option/knob absents de properties() (L6)"
L_HK=$(code_line "$TMP/jsf.code" 'error("REFUS: WEBHOOK_KIND_INVALIDE'); L_PR=$(code_line "$TMP/jsf.code" 'properties([')
[ -n "$L_HK" ] && [ -n "$L_PR" ] && [ "$L_HK" -lt "$L_PR" ] && ok "le refus WEBHOOK_KIND_INVALIDE (ligne $L_HK) précède properties() (ligne $L_PR) : rien n'est posé sur un knob inconnu" || ko "refus du knob absent ou après properties() (hk=$L_HK prop=$L_PR)"
```
`EXPECTED_CHECKS` : 211 + 1 = **212**.
Run: `bash scripts/test-a0-wiring.sh 2>&1 | grep -E '❌|RÉSULTAT'` — Expected: 2 ❌ en §7.

- [ ] **Step 2: Le Jenkinsfile**

Dans `environment {}` (après `GIT_SUBDIR`) :
```groovy
    // Le RÉCEPTEUR de webhooks de ce Jenkins (L6) : sous gwt, ce job garde son
    // hook direct PLAN (gateway wM → GWT, MANIFEST) ; sous gitlab il n'en a
    // aucun (le GitLab Plugin ne lit pas ce JSON) et n'est atteint que par le
    // `build job:` de provision-apply.
    WEBHOOK_KIND      = "${env.WEBHOOK_KIND ?: 'gwt'}"
```
Lignes 182-188 : remplacer
```groovy
          properties([
            disableConcurrentBuilds(),   // un apply à la fois = régime bancaire
            // PLAN par webhook : le GWT contribue MANIFEST (même token que la
            // coquille d'avant A0 ; le XML n'en porte plus — fait 10).
            pipelineTriggers([GenericTrigger(token: 'stoa-selfservice-plan',
              genericVariables: [[key: 'MANIFEST', value: '$.manifest']],
              printContributedVariables: false, printPostContent: false)]),
```
par
```groovy
          def hook = env.WEBHOOK_KIND
          if (hook != 'gwt' && hook != 'gitlab') {
            error("REFUS: WEBHOOK_KIND_INVALIDE : '${hook}' — attendu gwt|gitlab (globale Jenkins WEBHOOK_KIND). Rien n'est posé, le formulaire précédent reste en place.")
          }
          // PLAN par webhook (gwt seulement) : le GWT contribue MANIFEST (même
          // token que la coquille d'avant A0 ; le XML n'en porte plus — fait 10).
          // Le symbole n'est invoqué que si la branche est prise (mesuré M1).
          def hooks = (hook == 'gwt') ? [GenericTrigger(token: 'stoa-selfservice-plan',
              genericVariables: [[key: 'MANIFEST', value: '$.manifest']],
              printContributedVariables: false, printPostContent: false)] : []
          properties([
            disableConcurrentBuilds(),   // un apply à la fois = régime bancaire
            pipelineTriggers(hooks),
```

- [ ] **Step 3: Le poseur selfservice relit selon le knob (`:371-373`)**

Remplacer :
```bash
  [ "$TRIG" = "$TRIGGER_TOKEN" ] && [ "$NDIS" = 1 ] || fail "apres l'amorcage : trigger=[$TRIG] disableConcurrentBuilds=$NDIS — attendu UN trigger $TRIGGER_TOKEN et UNE option, poses par properties() (fait 10)"
  say "relecture : 1 propriete de parametres, trigger $TRIGGER_TOKEN + disableConcurrentBuilds poses par le Jenkinsfile, ENVIRONMENT == env_chain [$GOT]"
```
par :
```bash
  # L6 : sous WEBHOOK_KIND=gitlab le Jenkinsfile ne pose AUCUN hook direct (le
  # GitLab Plugin ne lit pas ce JSON) — l'attendu est alors « aucun trigger ».
  WANT_TRIG="$TRIGGER_TOKEN"; [ "${WEBHOOK_KIND:-gwt}" = gitlab ] && WANT_TRIG=""
  [ "$TRIG" = "$WANT_TRIG" ] && [ "$NDIS" = 1 ] || fail "apres l'amorcage : trigger=[$TRIG] disableConcurrentBuilds=$NDIS — attendu trigger=[$WANT_TRIG] (WEBHOOK_KIND=${WEBHOOK_KIND:-gwt}) et UNE option, poses par properties() (fait 10)"
  say "relecture : 1 propriete de parametres, trigger [$WANT_TRIG] + disableConcurrentBuilds poses par le Jenkinsfile (WEBHOOK_KIND=${WEBHOOK_KIND:-gwt}), ENVIRONMENT == env_chain [$GOT]"
```
et la ligne `say "OK — webhook PLAN : POST …"` (`:380`) devient : `[ -n "$WANT_TRIG" ] && say "OK — webhook PLAN : POST $JENKINS/generic-webhook-trigger/invoke?token=$TRIGGER_TOKEN  body {\"manifest\":\"<chemin>\"}" || say "OK — aucun hook direct (WEBHOOK_KIND=gitlab) : ce job n'est atteint que par build job: depuis provision-apply"`.
⚠ `test-a0-wiring.sh:989` grep `attendu UN trigger $TRIGGER_TOKEN et UNE option` sur le poseur : mettre à jour ce motif en `attendu trigger=[$WANT_TRIG]`.

- [ ] **Step 4: Vert**

Run: `ci/lint-jenkinsfiles.sh 2>&1 | tail -1 && bash scripts/test-a0-wiring.sh 2>&1 | tail -1 && bash scripts/test-selfservice-palier-a3.sh 2>&1 | tail -1`
Expected: `PORTE VERTE`, `RÉSULTAT : 212/212`, a3 vert (elle rejoue a0-wiring et apply-wiring, rc seulement).

- [ ] **Step 5: Commit**

```bash
git add ci/Jenkinsfile.selfservice scripts/setup-selfservice-job.sh scripts/test-a0-wiring.sh
git commit -m "feat(selfservice): le hook direct PLAN n'est posé que sous WEBHOOK_KIND=gwt, refus nommé avant properties() ; le poseur relit selon le knob (L6)"
```

---

### Task 10 : `setup-provision-jobs.sh` — l'amorçage est attendu et relu (fail-closed)

**Files:**
- Modify: `scripts/setup-provision-jobs.sh:19-32` (entête), `:59-76` (knobs), `:332-345` (amorçage)
- Modify: `scripts/test-setup-provision-jobs.sh` (faux Jenkins `:60-75`, `:80-100` ; §14 `:240-268` ; créer §16)

**Interfaces:**
- Produces: knobs `BOOTSTRAP_JOBS` (défaut `provision-apply provision-plan`, `none` = aucun), `BOOTSTRAP_AWAIT_JOBS` (défaut `provision-apply provision-plan` : ceux dont l'amorçage est ATTENDU puis RELU), `BOOTSTRAP_WAIT` (360), `WEBHOOK_KIND` (défaut gwt : classe de trigger attendue à la relecture). Refus `AMORCAGE_INCOMPLET`.

- [ ] **Step 1: Étendre le faux Jenkins (test) — RED**

Dans `fakejenkins.py` (`:60-75`), remplacer le handler `GET /job/<j>/api/json` :
```python
        m = re.match(r"^/job/([^/]+)/api/json$", self.path)
        if m:
            present = m.group(1) in EXISTING
            log(f"GET exists {m.group(1)} -> {200 if present else 404}")
            return self._send(200 if present else 404)
```
par :
```python
        m = re.match(r"^/job/([^/]+)/api/json", self.path)
        if m:
            present = m.group(1) in EXISTING
            log(f"GET exists {m.group(1)} -> {200 if present else 404}")
            return self._send(200 if present else 404, json.dumps({"nextBuildNumber": 7}).encode())
        m = re.match(r"^/job/([^/]+)/7/api/json", self.path)
        if m:   # L6 : le build d'amorcage — BUILD_RESULT vide = encore en cours
            log(f"GET build {m.group(1)} 7"); return self._send(200, json.dumps({"result": os.environ.get("BUILD_RESULT", "SUCCESS") or None}).encode())
        m = re.match(r"^/job/([^/]+)/config\.xml$", self.path)
        if m:   # L6 : la relecture apres l'amorcage — RELU_XML = le config.xml servi
            log(f"GET config {m.group(1)}")
            p = os.environ.get("RELU_XML", "")
            return self._send(200, open(p, "rb").read() if p else b"<flow-definition><properties/></flow-definition>")
```
Dans `start()` (`:93-100`), ajouter `BUILD_RESULT="${BUILD_RESULT-SUCCESS}" RELU_XML="${RELU_XML:-}"` à la ligne d'environnement du serveur. Ajouter après `JU=…` un rendu de trois `config.xml` de relecture :
```bash
relu(){ # <ntrig-gwt> <ntrig-gitlab> <ndis> <token> → fichier
  local f="$TMP/relu-$1$2$3.xml" i
  { echo '<flow-definition><properties>'; for i in $(seq 1 "$3"); do echo '<org.jenkinsci.plugins.workflow.job.properties.DisableConcurrentBuildsJobProperty/>'; done
    if [ "$1$2" != 00 ]; then echo '<org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty><triggers>'
      for i in $(seq 1 "$1"); do echo "<org.jenkinsci.plugins.gwt.GenericTrigger><token>$4</token></org.jenkinsci.plugins.gwt.GenericTrigger>"; done
      for i in $(seq 1 "$2"); do echo '<com.dabsquared.gitlabjenkins.GitLabPushTrigger><secretToken>x</secretToken></com.dabsquared.gitlabjenkins.GitLabPushTrigger>'; done
      echo '</triggers></org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>'; fi
    echo '</properties></flow-definition>'; } > "$f"; echo "$f"
}
```
§14 : remplacer les deux lignes
```bash
start "provision-apply,provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" bash "$S" 2>&1); RC=$?
calls | grep -q 'POST build' && ko "amorçage sans BOOTSTRAP_JOBS" || ok "sans BOOTSTRAP_JOBS : aucun build demandé (défaut inchangé)"
```
par
```bash
RELU_XML="$(relu 1 0 1 stoa-provision-plan)" start "provision-apply,provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" bash "$S" 2>&1); RC=$?
[ "$(calls | grep -c 'POST build')" = 2 ] && ok "sans BOOTSTRAP_JOBS : les DEUX jobs posés sont amorcés (défaut L6 : un job posé sans amorçage est un job MUET)" || ko "défaut BOOTSTRAP_JOBS : $(calls | grep -c 'POST build') build(s)"
start "provision-apply,provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" BOOTSTRAP_JOBS=none bash "$S" 2>&1); RC=$?
calls | grep -q 'POST build' && ko "BOOTSTRAP_JOBS=none a amorcé" || ok "BOOTSTRAP_JOBS=none : aucun build demandé (le mot, parce qu'une valeur vide n'atteint pas le shell)"
```
et dans la première mesure de §14 (`BOOTSTRAP_JOBS=provision-plan`), poser `RELU_XML="$(relu 1 0 1 stoa-provision-plan)"` devant `start`. Créer §16 avant `printf 'RÉSULTAT`:
```bash
echo
echo "== 16. l'amorçage est ATTENDU puis RELU (L6) : un trigger de la classe de WEBHOOK_KIND et une option, sinon AMORCAGE_INCOMPLET =="
RELU_XML="$(relu 1 0 1 stoa-provision-plan)" start "provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-plan bash "$S" 2>&1); RC=$?
[ $RC -eq 0 ] && grep -q "amorçage #7 : SUCCESS" <<<"$OUT" && grep -q "relecture : 1 trigger GenericTrigger (stoa-provision-plan) + 1 DisableConcurrentBuilds" <<<"$OUT" \
  && ok "gwt : build #7 attendu, config.xml relu, 1 GenericTrigger stoa-provision-plan + 1 option ⇒ succès nommé" || ko "gwt nominal : rc=$RC $(grep -E 'amorçage|relecture|AMORCAGE' <<<"$OUT" | tr '\n' ' ')"
L_B=$(calls | grep -n 'POST build provision-plan' | cut -d: -f1); L_R=$(calls | grep -n 'GET config provision-plan' | cut -d: -f1)
[ -n "$L_B" ] && [ -n "$L_R" ] && [ "$L_B" -lt "$L_R" ] && ok "la relecture ($L_R) vient APRÈS l'amorçage ($L_B)" || ko "ordre amorçage/relecture cassé (b=$L_B r=$L_R)"
RELU_XML="$(relu 0 1 1 x)" start "provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-plan WEBHOOK_KIND=gitlab bash "$S" 2>&1); RC=$?
[ $RC -eq 0 ] && grep -q "1 trigger GitLabPushTrigger" <<<"$OUT" && ok "gitlab : la classe attendue suit WEBHOOK_KIND (GitLabPushTrigger)" || ko "gitlab nominal : rc=$RC $(grep -E 'relecture|AMORCAGE' <<<"$OUT" | tr '\n' ' ')"
RELU_XML="$(relu 1 0 1 stoa-provision-plan)" start "provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-plan WEBHOOK_KIND=gitlab bash "$S" 2>&1); RC=$?
[ $RC -ne 0 ] && grep -q "AMORCAGE_INCOMPLET" <<<"$OUT" && ok "gitlab attendu, GenericTrigger relu ⇒ AMORCAGE_INCOMPLET (le knob et le job ne disent pas la même chose)" || ko "classe divergente avalée (rc=$RC)"
RELU_XML="$(relu 0 0 0 x)" start "provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-plan bash "$S" 2>&1); RC=$?
[ $RC -ne 0 ] && grep -q "AMORCAGE_INCOMPLET" <<<"$OUT" && ok "aucune propriété après l'amorçage ⇒ AMORCAGE_INCOMPLET (job muet, dit)" || ko "job muet avalé (rc=$RC)"
RELU_XML="$(relu 2 0 1 stoa-provision-plan)" start "provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-plan bash "$S" 2>&1); RC=$?
[ $RC -ne 0 ] && grep -q "AMORCAGE_INCOMPLET" <<<"$OUT" && ok "DEUX triggers relus ⇒ AMORCAGE_INCOMPLET (doublon, fait 10)" || ko "doublon avalé (rc=$RC)"
BUILD_RESULT="" RELU_XML="$(relu 1 0 1 stoa-provision-plan)" start "provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-plan BOOTSTRAP_WAIT=4 bash "$S" 2>&1); RC=$?
[ $RC -ne 0 ] && grep -q "ENCORE EN COURS après 4 s" <<<"$OUT" && ok "build jamais fini ⇒ échec borné par BOOTSTRAP_WAIT, nommé, sans re-pose" || ko "attente non bornée ou muette (rc=$RC)"
BUILD_RESULT=FAILURE RELU_XML="$(relu 1 0 1 stoa-provision-plan)" start "provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-plan bash "$S" 2>&1); RC=$?
[ $RC -ne 0 ] && grep -q "amorçage #7 : FAILURE" <<<"$OUT" && grep -q "AMORCAGE_INCOMPLET" <<<"$OUT" && ok "amorçage FAILURE (WEBHOOK_KIND_INVALIDE côté Jenkinsfile, par exemple) ⇒ AMORCAGE_INCOMPLET même si la relecture est bonne" || ko "FAILURE d'amorçage avalé (rc=$RC)"
start "provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-plan BOOTSTRAP_AWAIT_JOBS=none bash "$S" 2>&1); RC=$?
[ $RC -eq 0 ] && ! calls | grep -q 'GET config' && grep -q "non attendu" <<<"$OUT" && ok "BOOTSTRAP_AWAIT_JOBS=none : amorçage déclenché, ni attendu ni relu (comportement A0, dit)" || ko "await=none : rc=$RC relecture=$(calls | grep -c 'GET config')"
```
Run: `bash scripts/test-setup-provision-jobs.sh 2>&1 | grep -E '❌|RÉSULTAT'`
Expected: §14 et §16 rouges (9 ❌ environ).

- [ ] **Step 2: Le poseur**

Knobs (`:75-76`) :
```bash
# L6 (2026-09-11) : un job posé sans amorçage est un job MUET (fait 10 : ses
# propriétés — trigger, verrou — ne sont posées que par son premier build).
# Par défaut les deux jobs de l'aval sont donc amorcés ; `none` (le MOT, parce
# qu'une valeur vide n'atteint pas le shell) le débranche.
BOOTSTRAP_JOBS="${BOOTSTRAP_JOBS:-provision-apply provision-plan}"
# Ceux dont l'amorçage est ATTENDU (BOOTSTRAP_WAIT s) puis RELU : exactement UN
# trigger de la classe attendue par WEBHOOK_KIND (GenericTrigger sous gwt,
# GitLabPushTrigger sous gitlab) et UNE DisableConcurrentBuildsJobProperty —
# sinon AMORCAGE_INCOMPLET, rc 1. `none` = fire-and-forget (le geste d'A0).
BOOTSTRAP_AWAIT_JOBS="${BOOTSTRAP_AWAIT_JOBS:-provision-apply provision-plan}"
BOOTSTRAP_WAIT="${BOOTSTRAP_WAIT:-360}"
WEBHOOK_KIND="${WEBHOOK_KIND:-gwt}"
```
Amorçage (`:332-345`) : remplacer le `case " $BOOTSTRAP_JOBS " in *" $J "*) … esac` par :
```bash
  case " $BOOTSTRAP_JOBS " in
    *" $J "*)
      if [ "$POSED" = true ]; then
        NB=$(jcurl -s -b "$CK" "$JENKINS_UI/job/$J/api/json?tree=nextBuildNumber" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("nextBuildNumber",""))' 2>/dev/null || true)
        HC=$(jcurl -s -b "$CK" -X POST "$JENKINS_UI/job/$J/build" -H "$F: $C" -o /dev/null -w '%{http_code}')
        case "$HC" in
          201) case " $BOOTSTRAP_AWAIT_JOBS " in
                 *" $J "*) amorcage_relu "$J" "$NB" || RC=1 ;;
                 *) ok "build d'amorçage déclenché (HTTP $HC) — non attendu (BOOTSTRAP_AWAIT_JOBS ne nomme pas $J)" ;;
               esac ;;
          400) warn "amorçage refusé (HTTP 400) : le job est DÉJÀ paramétré — la pose n'a pas remplacé sa configuration ?"; RC=1;;
          *)   warn "amorçage en échec (HTTP $HC) — le job n'a PAS de formulaire tant qu'un build n'a pas tourné (bouton « Build »)"; RC=1;;
        esac
      else
        warn "amorçage NON tenté : la pose de $J a échoué"
      fi;;
  esac
```
et, avant la boucle `for J in $JOBS` de pose (`:269`), la fonction :
```bash
# amorcage_relu <job> <n° de build> : attend la fin du build (BOOTSTRAP_WAIT),
# puis relit config.xml — fail-closed, jamais de re-pose (elle effacerait ce que
# le build vient de poser). Sortie 0 = « amorçage #N : SUCCESS » + « relecture : … ».
amorcage_relu(){
  local j="$1" n="$2" r="" want i
  [ -n "$n" ] || { warn "AMORCAGE_INCOMPLET : nextBuildNumber illisible pour $j — build lancé, non attendu"; return 1; }
  for i in $(seq 1 "$((BOOTSTRAP_WAIT / 2))"); do
    r=$(jcurl -s -b "$CK" "$JENKINS_UI/job/$j/$n/api/json?tree=result" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("result") or "")' 2>/dev/null || true)
    [ -n "$r" ] && break; sleep 2
  done
  [ -n "$r" ] || { warn "AMORCAGE_INCOMPLET : build d'amorçage #$n de $j ENCORE EN COURS après ${BOOTSTRAP_WAIT} s — NE PAS re-poser : attendre sa fin sur $JENKINS_UI/job/$j/$n/console, puis relire config.xml"; return 1; }
  case "$WEBHOOK_KIND" in gwt) want=GenericTrigger ;; gitlab) want=GitLabPushTrigger ;; *) warn "AMORCAGE_INCOMPLET : WEBHOOK_KIND='$WEBHOOK_KIND' inconnu (gwt|gitlab)"; return 1 ;; esac
  jcurl -s -b "$CK" "$JENKINS_UI/job/$j/config.xml" > "$STAGE_DIR_RELU/$j.relu.xml" || { warn "AMORCAGE_INCOMPLET : config.xml de $j illisible après l'amorçage"; return 1; }
  read -r NT NO NTOK < <(python3 - "$STAGE_DIR_RELU/$j.relu.xml" "$want" <<'PY'
import sys, xml.etree.ElementTree as T
r = T.parse(sys.argv[1]).getroot(); w = sys.argv[2]
trig = [e for e in r.iter() if e.tag.endswith('Trigger') and not e.tag.endswith('PipelineTriggersJobProperty')]
print(sum(1 for e in trig if e.tag.endswith(w)), sum(1 for e in r.iter() if e.tag.endswith('DisableConcurrentBuildsJobProperty')), len(trig))
PY
)
  if [ "$r" != "SUCCESS" ]; then
    warn "amorçage #$n : $r — AMORCAGE_INCOMPLET : voir $JENKINS_UI/job/$j/$n/console (WEBHOOK_KIND_INVALIDE côté Jenkinsfile ? préflight ?) ; relu : $NT $want, $NO DisableConcurrentBuilds — NE PAS re-poser"
    return 1
  fi
  ok "amorçage #$n : SUCCESS"
  if [ "$NT" = 1 ] && [ "$NTOK" = 1 ] && [ "$NO" = 1 ]; then
    if [ "$want" = GenericTrigger ]; then
      local tok; tok=$(python3 -c "import sys,xml.etree.ElementTree as T; r=T.parse(sys.argv[1]).getroot(); print(','.join(t.findtext('token') or '' for t in r.iter() if t.tag.endswith('GenericTrigger')))" "$STAGE_DIR_RELU/$j.relu.xml")
      [ "$tok" = "stoa-$j" ] || { warn "AMORCAGE_INCOMPLET : token relu '$tok' ≠ stoa-$j"; return 1; }
      ok "relecture : 1 trigger GenericTrigger ($tok) + 1 DisableConcurrentBuilds — posés par le build (fait 10)"
    else
      ok "relecture : 1 trigger GitLabPushTrigger + 1 DisableConcurrentBuilds — posés par le build (fait 10) ; webhook GitLab : $JENKINS_UI/project/$j"
    fi
    return 0
  fi
  warn "AMORCAGE_INCOMPLET : relu $NT $want sur $NTOK trigger(s), $NO DisableConcurrentBuilds — attendu 1/1/1 (doublon = fait 10 ; 0 = job muet ; autre classe = WEBHOOK_KIND et Jenkinsfile en désaccord)"
  return 1
}
STAGE_DIR_RELU=$(mktemp -d); trap 'rm -rf "$STAGE_DIR_RELU"' EXIT
```
(si un `trap … EXIT` existe déjà pour `STAGE_DIR`, y ajouter `"$STAGE_DIR_RELU"` plutôt que d'en poser un second). Entête (`:19-32`) : remplacer le paragraphe `BOOTSTRAP_JOBS : LE BUILD D'AMORÇAGE…` par la description des trois knobs ci-dessus et du refus `AMORCAGE_INCOMPLET` ; `:59-61` (usage) : `BOOTSTRAP_JOBS="…" (défaut : provision-apply provision-plan ; none = aucun)`, `BOOTSTRAP_AWAIT_JOBS`, `BOOTSTRAP_WAIT`, `WEBHOOK_KIND`.

- [ ] **Step 3: Vert**

Run: `bash scripts/test-setup-provision-jobs.sh 2>&1 | tail -1 && shellcheck -x scripts/setup-provision-jobs.sh && echo sc-ok && bash scripts/test-a0-wiring.sh 2>&1 | tail -1`
Expected: `RÉSULTAT : N/N` (0 ❌), `sc-ok`, a0 212/212 (son §7 mesure `setup-team-onboard-jobs.sh` → `setup-provision-jobs.sh` avec `BOOTSTRAP_JOBS=app-request` : app-request n'est pas dans `BOOTSTRAP_AWAIT_JOBS`, rien ne change pour lui).

- [ ] **Step 4: Commit**

```bash
git add scripts/setup-provision-jobs.sh scripts/test-setup-provision-jobs.sh
git commit -m "feat(setup-provision-jobs): l'amorçage de provision-plan/apply est attendu et relu — 1 trigger de la classe de WEBHOOK_KIND + 1 verrou, sinon AMORCAGE_INCOMPLET (L6)"
```

---

### Task 11 : `setup-jenkins-globals.sh`, `ci/jenkins/Dockerfile`, `lint-ci`

**Files:**
- Modify: `scripts/setup-jenkins-globals.sh` (entête après le bloc GIT_BASE `:150-165`, `:194-203`, `:216`)
- Modify: `ci/jenkins/Dockerfile:39`

- [ ] **Step 1: Le knob dans le poseur de globales**

Dans l'entête, remplacer le paragraphe `:162-165` (« Les webhooks des jobs provision-plan / provision-apply lisent, eux, les DEUX formes de payload … /generic-webhook-trigger/invoke?token=<token du job>. ») par :
```bash
# LE RÉCEPTEUR DE WEBHOOKS (WEBHOOK_KIND) — L6, 2026-09-11
#   WEBHOOK_KIND            gwt (défaut) | gitlab — le plugin de CE Jenkins qui
#                           reçoit les webhooks de la forge et pose les variables.
#                           gwt = generic-webhook-trigger : côté forge, pointer le
#                           hook sur /generic-webhook-trigger/invoke?token=<token du
#                           job> (les deux payloads, Gitea « pull_request » et
#                           GitLab « Merge request events », sont lus sans knob).
#                           gitlab = GitLab Plugin : côté GitLab, deux webhooks
#                           « Merge request events » SEULEMENT, vers
#                           /project/provision-plan et /project/provision-apply,
#                           champ « Secret Token » = stoa-provision-plan /
#                           stoa-provision-apply (une sonnette, pas une autorité :
#                           la forge est relue) ; plugin ≥ 1.7.13
#                           (gitlabMergeCommitSha). Le Jenkinsfile pose le
#                           déclencheur à son premier build (amorçage) ; toute
#                           autre valeur est refusée par nom AVANT
#                           (WEBHOOK_KIND_INVALIDE). Sous gitlab,
#                           selfservice-app-deploy n'a aucun hook direct.
```
`CONNUES` (`:196`) : `FORGE_KIND FORGE_CRED_KIND FORGE_API_AUTH FORGE_API_BASE FORGE_USER WEBHOOK_KIND`. `OPTIONNELLES` (`:216`) : ajouter `WEBHOOK_KIND` en fin de liste, et dans le commentaire au-dessus : « Le récepteur de webhooks en fait partie depuis L6 : absent, la chaîne pose le GWT (gwt). »

- [ ] **Step 2: Le lab garde les deux récepteurs**

`ci/jenkins/Dockerfile:39` : `RUN jenkins-plugin-cli --plugins "git workflow-aggregator generic-webhook-trigger gitlab-plugin pipeline-stage-view kubernetes"` et, au-dessus, ajouter au commentaire : `# gitlab-plugin (L6) : le second RÉCEPTEUR de webhooks (WEBHOOK_KIND=gitlab), pour que test-webhook-kind-gitlab-live.sh soit rejouable sur un lab reconstruit.`

- [ ] **Step 3: `--help` et lint**

Run: `bash scripts/setup-jenkins-globals.sh --help | grep -A3 'WEBHOOK_KIND' | head -5 && ci/lint-config-knobs.sh 2>&1 | tail -1`
Expected: le paragraphe s'affiche ; lint-config-knobs vert (`gwt` n'est ni URL ni identifiant de site).

- [ ] **Step 4: Commit**

```bash
git add scripts/setup-jenkins-globals.sh ci/jenkins/Dockerfile
git commit -m "feat(globals): WEBHOOK_KIND connu et optionnel (gwt|gitlab), documenté dans --help ; gitlab-plugin dans l'image Jenkins du lab (L6)"
```

---

### Task 12 : `make lint-ci` 20/20

- [ ] **Step 1: Jouer la porte entière**

Run: `make lint-ci 2>&1 | tail -25`
Expected: `[20/20]` atteint, aucun rouge. Si [2/20] (shellcheck) rougit sur `setup-provision-jobs.sh` (SC2015 sur les `&& ok || ko` — voir la directive en tête du fichier) ou sur un spike : corriger ; les spikes ne sont pas dans la liste shellcheck de lint-ci mais restent propres (`shellcheck scripts/spike-webhook-kind-*.sh`).

- [ ] **Step 2: Commit s'il y a eu correction**

```bash
git add -A scripts ci
git commit -m "chore(l6): lint-ci 20/20 après le récepteur à deux visages"
```

---

### Task 13 : preuve live `gwt` (non-régression) — M10, a6-live, a7-live

**Files:** aucun (lab). Résultats dans l'ADR.

- [ ] **Step 1: Pousser sur gitea (le CI du lab lit gitea) et re-poser les deux jobs**

Run: `git push gitea HEAD:main && export GIT_HOST=http://localhost:13000 GIT_REPO=ci/stoa-labs JENKINS_UI=http://localhost:18080 && bash scripts/setup-provision-jobs.sh 2>&1 | tail -12`
Expected: pour chaque job : `job … (HTTP 200)`, `amorçage #N : SUCCESS`, `relecture : 1 trigger GenericTrigger (stoa-provision-<job>) + 1 DisableConcurrentBuilds`, `OK — les jobs demandés sont alignés sur le dépôt.` (M10 nominal). Vérifier à la main : `curl -s http://localhost:18080/job/provision-apply/config.xml | grep -c GenericTrigger` ⇒ `1`.

- [ ] **Step 2: M10 contre-épreuve — knob invalide**

Run (console de script Jenkins, ou `setup-jenkins-globals.sh --from-env` avec `WEBHOOK_KIND=foo`) puis `bash scripts/setup-provision-jobs.sh 2>&1 | grep -E 'amorçage|AMORCAGE'`
Expected: `amorçage #N : FAILURE — AMORCAGE_INCOMPLET …`, console du build : `REFUS: WEBHOOK_KIND_INVALIDE : 'foo'`, et `config.xml` sans aucun trigger (`grep -c Trigger` ⇒ 0). Retirer la globale (ou `WEBHOOK_KIND=gwt`), re-poser : nominal. Noter les deux numéros de build dans l'ADR.

- [ ] **Step 3: a6-live et a7-live inchangés**

Run: `bash scripts/test-a6-live.sh 2>&1 | tail -1 && bash scripts/test-a7-live.sh 2>&1 | tail -1` (prérequis de chaque harnais en tête de fichier : Vault re-seedé, `WM_PASS` par fichier — voir la mémoire « Login user/mot de passe Jenkins→Vault »).
Expected: `RÉSULTAT : 50/50` et `RÉSULTAT : 99/99` (les mêmes verts que le 2026-09-03). Un rouge sur un POST `invoke?token=stoa-provision-apply` (`BUILD_EN_FILE` absent) = amorçage non fini : rejouer après M10.

- [ ] **Step 4: Reporter dans l'ADR et committer**

```bash
git add adr/adr-098-recepteur-de-webhooks-a-deux-visages.md
git commit -m "docs(adr-098): preuves live gwt — M10 (amorçage relu, WEBHOOK_KIND_INVALIDE ⇒ aucun trigger), a6-live 50/50, a7-live 99/99"
```

---

### Task 14 : `scripts/test-webhook-kind-gitlab-live.sh` — la preuve du visage gitlab

**Files:**
- Create: `scripts/test-webhook-kind-gitlab-live.sh`

- [ ] **Step 1: Écrire le harnais**

```bash
#!/usr/bin/env bash
# test-webhook-kind-gitlab-live.sh — la chaîne app-request sous WEBHOOK_KIND=gitlab
# (GitLab Plugin), contre le GitLab CE et le Jenkins du lab. Spec 2026-09-11 §9.3.
#
# PRÉREQUIS : gitlab-plugin sur le Jenkins (spike M5 ou image L6) ; .env.gitlab-lab ;
#   projet ci/stoa-labs en méthode « merge » ; le credential gitea-provision-token
#   du Jenkins porte un PAT GitLab (scopes api, read_user, write_repository) ;
#   Vault du lab re-seedé (la garde A3 lit envs/dev/wm-admin).
# POSE (et RESTAURE en Z) les globales : WEBHOOK_KIND=gitlab FORGE_KIND=gitlab
#   GIT_HOST=http://gitlab:80 GIT_REPO=ci/stoa-labs FORGE_CRED_KIND=secret-text
#   GIT_WEB_HOST=http://localhost:13080 ; re-pose les deux jobs (amorçage relu).
# NETTOIE : hooks, MR, branche ; re-pose sous gwt ; rejoue a0-wiring en local.
#
#   JENKINS_UI=http://localhost:18080 bash scripts/test-webhook-kind-gitlab-live.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO" || exit 1
J="${JENKINS_UI:?JENKINS_UI requis}"; JIN="${JENKINS_INCLUSTER:-http://jenkins:8080}"
GL="${GITLAB_LAB_URL:-http://localhost:13080}"; GLIN="${GITLAB_INCLUSTER:-http://gitlab:80}"; PID="${GITLAB_LAB_PROJECT_ID:-1}"; GL_REPO="${GITLAB_LAB_REPO:-ci/stoa-labs}"
set -a; . ./.env.gitlab-lab; set +a; TOK="${GITLAB_LAB_TOKEN:?.env.gitlab-lab : bash scripts/setup-gitlab-lab.sh}"
TMP="$(mktemp -d /tmp/wkgl.XXXXXX)"; umask 077
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }; ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
gl(){ curl -s -H "PRIVATE-TOKEN: $TOK" "$@"; }
jq_(){ python3 -c "import sys,json; d=json.load(sys.stdin); $1"; }
gauth(){ GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'oauth2:%s' "$TOK" | base64 | tr -d '\n')" GIT_CONFIG_KEY_1=http.postBuffer GIT_CONFIG_VALUE_1=524288000 git "$@"; }
jnext(){ curl -sf "$J/job/$1/api/json?tree=nextBuildNumber" | jq_ "print(d['nextBuildNumber'])"; }
jresult(){ curl -s "$J/job/$1/$2/api/json?tree=result,building" | jq_ "print(d.get('result') or ('BUILDING' if d.get('building') else ''))" 2>/dev/null || true; }
jconsole(){ curl -s "$J/job/$1/$2/consoleText"; }
jname(){ curl -s "$J/job/$1/$2/api/json?tree=displayName" | jq_ "print(d.get('displayName',''))" 2>/dev/null || true; }
wait_build(){ # <job> <n> [secondes] → résultat (ou BUILDING/'' à l'échéance)
  local dl=$(( $(date +%s) + ${3:-300} )) r; while [ "$(date +%s)" -lt "$dl" ]; do r=$(jresult "$1" "$2"); [ -n "$r" ] && [ "$r" != BUILDING ] && { echo "$r"; return; }; sleep 3; done; echo "${r:-}"
}
wait_pause(){ local dl=$(( $(date +%s) + ${3:-300} )); while [ "$(date +%s)" -lt "$dl" ]; do curl -s "$J/job/$1/$2/wfapi/pendingInputActions" | grep -q '"id"' && return 0; [ -n "$(jresult "$1" "$2" | grep -v BUILDING)" ] && return 1; sleep 3; done; return 1; }
globals(){ bash scripts/setup-jenkins-globals.sh --from-env >/dev/null 2>&1; }   # lit les variables exportées
pose(){ GIT_HOST="$1" GIT_REPO="$GL_REPO" WEBHOOK_KIND="$2" bash scripts/setup-provision-jobs.sh > "$TMP/pose.$2.log" 2>&1; }
HOOKS=""; IID=""; BR=""
cleanup(){
  for h in $HOOKS; do gl -X DELETE "$GL/api/v4/projects/$PID/hooks/$h" -o /dev/null; done
  [ -n "$IID" ] && gl -X PUT "$GL/api/v4/projects/$PID/merge_requests/$IID" -d state_event=close -o /dev/null
  [ -n "$BR" ] && gauth push -q "$GL/$GL_REPO.git" --delete "$BR" 2>/dev/null
  export WEBHOOK_KIND=gwt FORGE_KIND=gitea GIT_HOST=http://gitea:3000 GIT_REPO=ci/stoa-labs GIT_WEB_HOST=http://localhost:13000; globals
  pose http://localhost:13000 gwt && grep -q 'GenericTrigger' "$TMP/pose.gwt.log" && echo "Z. jobs re-posés sous gwt (amorçage relu)" || echo "Z. !! re-pose gwt à vérifier : $(tail -3 "$TMP/pose.gwt.log")"
  rm -rf "$TMP"
}
trap cleanup EXIT
echo "═══ 0. les deux récepteurs sont là, le projet fusionne par merge commit ═══"
P=$(curl -s "$J/pluginManager/api/json?tree=plugins[shortName,version]" | jq_ "print(' '.join(p['shortName']+'='+p['version'] for p in d['plugins'] if p['shortName'] in ('gitlab-plugin','generic-webhook-trigger')))")
case "$P" in *gitlab-plugin=*generic-webhook-trigger=*|*generic-webhook-trigger=*gitlab-plugin=*) ok "0.1 plugins : $P";; *) ko "0.1 il manque un récepteur : $P"; echo "RÉSULTAT : $PASS/$((PASS+FAIL))"; exit 1;; esac
[ "$(gl "$GL/api/v4/projects/$PID" | jq_ "print(d['merge_method'])")" = merge ] && ok "0.2 méthode de merge = merge (merge_commit_sha non nul)" || { ko "0.2 méthode de merge ≠ merge : le SHA serait vide"; }
echo "═══ 1. globales gitlab, hooks GitLab, jobs re-posés et amorcés (1 GitLabPushTrigger chacun) ═══"
export WEBHOOK_KIND=gitlab FORGE_KIND=gitea GIT_HOST="$GLIN" GIT_REPO="$GL_REPO" GIT_WEB_HOST="$GL" FORGE_CRED_KIND=secret-text; export FORGE_KIND=gitlab; globals
for h in $(gl "$GL/api/v4/projects/$PID/hooks" | jq_ "print(' '.join(str(x['id']) for x in d if '/project/provision-' in x['url']))"); do gl -X DELETE "$GL/api/v4/projects/$PID/hooks/$h" -o /dev/null; done
H1=$(gl -X POST "$GL/api/v4/projects/$PID/hooks" -d "url=$JIN/project/provision-plan" -d token=stoa-provision-plan -d merge_requests_events=true -d push_events=false | jq_ "print(d['id'])")
H2=$(gl -X POST "$GL/api/v4/projects/$PID/hooks" -d "url=$JIN/project/provision-apply" -d token=stoa-provision-apply -d merge_requests_events=true -d push_events=false | jq_ "print(d['id'])")
HOOKS="$H1 $H2"; [ -n "$H1" ] && [ -n "$H2" ] && ok "1.1 deux webhooks GitLab (MR events seulement, Secret Token = le mot) : $HOOKS" || ko "1.1 hooks non posés"
pose "$GL" gitlab && grep -q '1 trigger GitLabPushTrigger' "$TMP/pose.gitlab.log" && [ "$(grep -c 'amorçage #' "$TMP/pose.gitlab.log")" = 2 ] \
  && ok "1.2 provision-plan/apply re-posés, amorçage relu : 1 GitLabPushTrigger + 1 verrou chacun" || ko "1.2 pose/amorçage : $(grep -E 'AMORCAGE|amorçage|relecture' "$TMP/pose.gitlab.log" | tr '\n' ' ')"
[ "$(curl -s "$J/job/provision-apply/config.xml" | grep -c 'GenericTrigger')" = 0 ] && ok "1.3 aucun GenericTrigger résiduel sur provision-apply" || ko "1.3 GenericTrigger encore présent (doublon de récepteurs)"
echo "═══ 2. la demande ouvre la MR ⇒ build plan par le plugin, commentaire de plan ═══"
SUB="$(basename "$REPO")"; APP="appwk"; ENVN="dev"; BR="provision/${APP}-${ENVN}"; CLONE="$GL/$GL_REPO.git"
gauth push -q "$CLONE" --delete "$BR" 2>/dev/null || true
SVC_LOGIN="$( env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitlab GIT_HOST="$GL" GIT_REPO="$GL_REPO" FORGE_SECRET="$TOK" bash -c '. scripts/lib/forge-api.sh && forge_api_init && forge whoami' 2>/dev/null | sed -n 's/^LOGIN=//p' )"
NP=$(jnext provision-plan)
( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitlab FORGE_API_AUTH=private-token FORGE_SECRET="$TOK" \
    GIT_HOST="$GL" GIT_WEB_HOST="$GL" GIT_REPO="$GL_REPO" GIT_SUBDIR="$SUB" GIT_CLONE_URL="$CLONE" GIT_PUSH_URL="$CLONE" \
    STOA_ENV_CHAIN_FILE="$REPO/clients/_example/environments.yaml" PROVISION_PLAN_INLINE=false \
    REQ_APP="$APP" REQ_ENV="$ENVN" REQ_API=demo-selfservice REQ_API_VER=1.0.0 REQ_CLIENT_ID="${APP}-${ENVN}" \
    REQ_CALLER=jenkins-form:x REQ_TEAM=banking-demo GITEA_SERVICE_LOGINS="$SVC_LOGIN" bash scripts/provision-request.sh ) > "$TMP/req.out" 2>&1
IID="$(grep -oE 'PR (créée|déjà ouverte): #[0-9]+' "$TMP/req.out" | grep -oE '[0-9]+$' | head -1)"
[ -n "$IID" ] && ok "2.1 MR !$IID ouverte par provision-request.sh" || { ko "2.1 pas de MR : $(tail -3 "$TMP/req.out" | tr '\n' ' ')"; echo "RÉSULTAT : $PASS/$((PASS+FAIL))"; exit 1; }
R=$(wait_build provision-plan "$NP" 240); N1=$(jname provision-plan "$NP")
[ "$R" = SUCCESS ] && case "$N1" in "plan $APP/$ENVN (PR #$IID)") ok "2.2 build plan #$NP par le plugin : $R, nommé « $N1 »";; *) ko "2.2 build plan #$NP : $R, nommé « $N1 »";; esac || ko "2.2 build plan #$NP : ${R:-jamais déclenché}"
jconsole provision-plan "$NP" | grep -q 'gitlabMergeRequestIid' && ok "2.3 la console montre les variables gitlab* (troisième visage)" || ko "2.3 variables gitlab* absentes de la console"
sleep 5; gl "$GL/api/v4/projects/$PID/merge_requests/$IID/notes" | jq_ "import sys; sys.exit(0 if any('plan' in (n.get('body') or '').lower() for n in d) else 1)" && ok "2.4 un commentaire de plan est posé sur la MR (comment_upsert, identité de forge)" || ko "2.4 aucun commentaire de plan sur la MR"
echo "═══ 3. titre ⇒ pas de build ; push ⇒ build ═══"
NP=$(jnext provision-plan); gl -X PUT "$GL/api/v4/projects/$PID/merge_requests/$IID" -d title="appwk (titre)" -o /dev/null; sleep 15
[ "$(jnext provision-plan)" = "$NP" ] && ok "3.1 update du titre (même SHA) : aucun build (garde « déjà construit » du plugin — écart GWT assumé)" || ko "3.1 le titre a déclenché un plan"
W="$TMP/w"; gauth clone -q --depth 1 -b "$BR" "$CLONE" "$W" && { echo "# wk $(date +%s)" >> "$W/$SUB/README.md" 2>/dev/null || echo "wk" > "$W/wk.txt"; git -C "$W" add -A; git -C "$W" -c user.name=wk -c user.email=wk@lab commit -qm "wk push"; gauth -C "$W" push -q "$CLONE" "$BR"; }
R=$(wait_build provision-plan "$NP" 240); [ "$R" = SUCCESS ] && ok "3.2 push d'un commit ⇒ build plan #$NP : $R" || ko "3.2 push ⇒ ${R:-aucun build}"
echo "═══ 4. merge ⇒ build apply jusqu'à la pause, MERGE_SHA = merge_commit_sha de l'API ═══"
NA=$(jnext provision-apply); gl -X PUT "$GL/api/v4/projects/$PID/merge_requests/$IID/merge" -o "$TMP/merge.json"
SHA_API=$(jq_ "print(d.get('merge_commit_sha') or '')" < "$TMP/merge.json"); [ "${#SHA_API}" = 40 ] && ok "4.1 mergée, merge_commit_sha=$SHA_API" || ko "4.1 merge : $(head -c 200 "$TMP/merge.json")"
if wait_pause provision-apply "$NA" 300; then ok "4.2 build apply #$NA déclenché par le plugin (action=merge) et EN PAUSE nominative"; else ko "4.2 apply #$NA : $(jresult provision-apply "$NA") — $(jconsole provision-apply "$NA" | grep -m1 'REFUS' )"; fi
jconsole provision-apply "$NA" | grep -q "merge_sha=$SHA_API" && ok "4.3 MERGE_SHA du build == merge_commit_sha de l'API (gitlabMergeCommitSha, A2)" || ko "4.3 MERGE_SHA divergent : $(jconsole provision-apply "$NA" | grep -m1 'merge_sha=')"
jconsole provision-apply "$NA" | grep -q 'RECONCILE' && ok "4.4 la réconciliation a tourné sur la forge (le payload ne fait pas foi)" || ko "4.4 réconciliation absente de la console"
IDI=$(curl -s "$J/job/provision-apply/$NA/wfapi/pendingInputActions" | jq_ "print(d[0]['abortUrl'] if d else '')"); [ -n "$IDI" ] && curl -s -X POST "$J$IDI" -o /dev/null && ok "4.5 pause abandonnée (lab partagé : rien n'est appliqué par ce harnais)" || ko "4.5 pause non soldée"
IID=""   # mergée : rien à fermer en Z
echo "═══ 5. contre-épreuves ═══"
NA=$(jnext provision-apply); BR2="provision/appwk2-dev"; git -C "$W" checkout -qb "$BR2"; echo x > "$W/x.txt"; git -C "$W" add x.txt; git -C "$W" -c user.name=wk -c user.email=wk@lab commit -qm x; gauth -C "$W" push -q "$CLONE" "$BR2"
I2=$(gl -X POST "$GL/api/v4/projects/$PID/merge_requests" -d source_branch="$BR2" -d target_branch="$(gl "$GL/api/v4/projects/$PID" | jq_ "print(d['default_branch'])")" -d title=wk2 | jq_ "print(d['iid'])")
sleep 10; gl -X PUT "$GL/api/v4/projects/$PID/merge_requests/$I2" -d state_event=close -o /dev/null; sleep 15
[ "$(jnext provision-apply)" = "$NA" ] && ok "5.1 close sans merge ⇒ aucun build apply" || ko "5.1 un close a déclenché l'apply"
gauth push -q "$CLONE" --delete "$BR2" 2>/dev/null
HC=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'X-Gitlab-Event: Merge Request Hook' -H 'Content-Type: application/json' -d '{"object_kind":"merge_request","object_attributes":{"iid":1,"state":"merged","action":"merge","source_branch":"provision/x-dev","target_branch":"main"}}' "$J/project/provision-apply")
case "$HC" in 401|403) ok "5.2 POST /project/provision-apply sans X-Gitlab-Token ⇒ HTTP $HC (la sonnette exige le mot)";; *) ko "5.2 sans token ⇒ HTTP $HC";; esac
export WEBHOOK_KIND=gwt; globals; pose "$GL" gwt
grep -q '1 trigger GenericTrigger' "$TMP/pose.gwt.log" && ok "5.3 retour WEBHOOK_KIND=gwt : re-pose + amorçage ⇒ 1 GenericTrigger, 0 GitLabPushTrigger ($(curl -s "$J/job/provision-plan/config.xml" | grep -c GitLabPushTrigger))" || ko "5.3 retour gwt : $(tail -2 "$TMP/pose.gwt.log")"
HC=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'X-Gitlab-Token: stoa-provision-plan' -H 'X-Gitlab-Event: Merge Request Hook' -H 'Content-Type: application/json' -d '{"object_kind":"merge_request"}' "$J/project/provision-plan"); NP=$(jnext provision-plan); sleep 8
[ "$(jnext provision-plan)" = "$NP" ] && ok "5.4 sous gwt, /project/provision-plan est MUET (HTTP $HC, aucun build)" || ko "5.4 /project/ a construit sous gwt"
echo "RÉSULTAT : $PASS/$((PASS+FAIL))"; [ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Jouer**

Run: `JENKINS_UI=http://localhost:18080 bash scripts/test-webhook-kind-gitlab-live.sh 2>&1 | tee /tmp/wk-gitlab-live.log | grep -E '✅|❌|RÉSULTAT'`
Expected: `RÉSULTAT : 17/17` (0.1, 0.2, 1.1-1.3, 2.1-2.4, 3.1-3.2, 4.1-4.5, 5.1-5.4). Pièges à connaître : la réconciliation A2 attend `prepared_at` (`FORGE_PREPARE_WAIT`) ; si 4.2 refuse `PAYLOAD_PERIME`, comparer `merge_sha=` de la console et l'API — c'est M6 qui tranche ; si 2.2 ne se déclenche jamais, relire `GET /api/v4/projects/1/hooks/<id>` (`alert_status`) et `docker logs poc-gitlab | grep project/provision`.

- [ ] **Step 3: Rejouer a0-wiring (rien n'a bougé dans le dépôt) et committer**

```bash
bash scripts/test-a0-wiring.sh | tail -1
git add scripts/test-webhook-kind-gitlab-live.sh
git commit -m "test(l6): test-webhook-kind-gitlab-live.sh — la chaîne app-request par le GitLab Plugin (plan sur open/push, pas sur le titre, apply sur merge avec MERGE_SHA = API, close muet, token exigé, retour gwt) 17/17"
```

---

### Task 15 : doc client, ADR-098 finalisé, plan L6, pousser

**Files:**
- Modify: `ENVIRONNEMENTS.md` (créer `## Le récepteur de webhooks (L6 — 2026-09-11)` avant `## Résiduel` `:1386` ; corriger `:177-179`, `:258-261`, `:611-613`, `:1006-1009`)
- Modify: `adr/adr-098-recepteur-de-webhooks-a-deux-visages.md` (status, décision, preuves)
- Modify: `docs/superpowers/plans/2026-09-09-forge-agnostique-debug-branche.md` (Task 7 (L6) → renvoi)
- Modify: `ci/Jenkinsfile.provision-plan:82-84`, `ci/Jenkinsfile.provision-apply` (entêtes déjà réécrits en Tasks 6-7 — vérifier), `scripts/setup-provision-jobs.sh:14-16`

- [ ] **Step 1: La section ENVIRONNEMENTS.md**

Insérer avant `## Résiduel` :
```markdown
## Le récepteur de webhooks (L6 — 2026-09-11)

Le 2026-09-11, chez le client GitLab, `provision-plan` mourait au parse :
`Invalid trigger type "GenericTrigger"` — le plugin generic-webhook-trigger
**ne peut pas être installé** sur son Jenkins, et un symbole de déclencheur dans
un bloc Declarative `triggers {}` est résolu à la compilation (mesuré M1).
`selfservice-app-deploy` mourait de même, à l'invocation, sur son
`pipelineTriggers([GenericTrigger(...)])`. Ce Jenkins a le **GitLab Plugin**.

**Une seule autorité** : chaque Jenkinsfile de l'aval applicatif pose son
déclencheur ET son verrou de concurrence par un `properties()` scripté au
premier stage, selon la globale `WEBHOOK_KIND`, et refuse par nom toute autre
valeur AVANT de poser quoi que ce soit (`WEBHOOK_KIND_INVALIDE`). Les XML de
`provision-plan` et `provision-apply` ne portent **aucune propriété** : un XML
porteur + `properties()` fait un doublon au build 1 et perd le XML au build 2
(fait 10, re-mesuré M2). Le déclencheur n'existe donc qu'après le premier build
— l'**amorçage** — que `setup-provision-jobs.sh` attend et relit
(`AMORCAGE_INCOMPLET` sinon).

**Knobs** (globales Jenkins, `setup-jenkins-globals.sh --help`) :

| Knob | Valeurs | Défaut | Rôle |
|------|---------|--------|------|
| `WEBHOOK_KIND` | `gwt` \| `gitlab` | `gwt` | le plugin de CE Jenkins qui reçoit les webhooks. `gwt` : `/generic-webhook-trigger/invoke?token=<token du job>`, les deux payloads (Gitea, GitLab) lus sans knob. `gitlab` : `/project/<job>` + « Secret Token » ; `provision-plan` écoute open/reopen/nouveau SHA, `provision-apply` la fusion seulement ; `selfservice-app-deploy` n'a aucun hook direct |
| `BOOTSTRAP_JOBS` / `BOOTSTRAP_AWAIT_JOBS` / `BOOTSTRAP_WAIT` | (poseur `setup-provision-jobs.sh`) | `provision-apply provision-plan` / idem / 360 | amorçage après la pose ; attendu et relu pour les jobs nommés ; `none` = le mot qui débranche |

**Prérequis côté client GitLab** :

- GitLab Plugin **≥ 1.7.13** (`gitlabMergeCommitSha`, la référence A2) ;
- deux webhooks de projet, **« Merge request events » seulement** (jamais push),
  vers `https://<jenkins>/project/provision-plan` et
  `https://<jenkins>/project/provision-apply`, champ **Secret Token** =
  `stoa-provision-plan` / `stoa-provision-apply` — c'est une sonnette, pas une
  autorité (la forge est relue : `FORGE_NON_CONFIRMEE`, `PAYLOAD_PERIME`) ;
  sans token, l'endpoint authentifié du plugin (défaut global) répond 403 ;
- méthode de merge **merge commit** : en fast-forward/squash le plugin pose
  `gitlabMergeCommitSha` **vide** ⇒ `MERGE_SHA_INVALIDE` (mesuré M6) ;
- jobs créés à la main : type **Pipeline**, « Pipeline script from SCM »,
  `Lightweight checkout` **décoché**, aucun trigger coché, puis **Build Now**
  une fois — le build sort vert « hors provision/* » et pose le déclencheur ;
- un changement de titre ne rejoue pas le plan (garde « déjà construit » du
  plugin) ; un push, si. Le commentaire de plan est par SHA : aucune différence.

**La porte** : `test-a0-wiring.sh` §3bis (structurel : ordre refus → `properties()`
→ fait unifié, la table des cases du plugin, un seul `GenericTrigger(` et un seul
`gitlab(`) et §8bis (9 mutations rouges) ; `test-setup-provision-jobs.sh` §16
(amorçage attendu/relu) ; sous `make lint-ci` [11/20]. **Angle mort assumé** :
aucune suite statique ne voit un `if` dont la condition ment (le miroir est
aveugle à la conditionnalité) — seule la preuve live M10 le couvre.

**Au lab** : `test-webhook-kind-gitlab-live.sh` 17/17 (2026-09-11) ; non-régression
gwt a6-live 50/50, a7-live 99/99 ; gitlab-plugin dans `ci/jenkins/Dockerfile`.

**Dettes** : les cinq Jenkinsfile de la chaîne API (`team-*`, `publish-api`,
`provisioning-request`) portent encore un `triggers { GenericTrigger }` déclaratif ;
un vrai secret par site pour le Secret Token (credential + `withCredentials`) ;
trou `state=locked` du plugin (état hors enum = joker) ; `FORGE_CRED_KIND`
optionnel mais refusé si vide.
```
Corrections : `:177-179` — ajouter « (depuis L6, `stoa-provision-plan`/`-apply` aussi : posés par le build) » ; `:258-261` — remplacer « **le XML gagne sur le Jenkinsfile** — un scellement… » par « pour un bloc **déclaratif**, le XML gagne ; pour `provision-plan`/`provision-apply`/`selfservice` (L6), le XML est vide et le Jenkinsfile pose tout au premier build » ; `:611-613` — « (pointeur SCM + miroir du bloc `<triggers>`, qui gagne) » devient « (pointeur SCM, **aucune propriété** depuis L6 : le Jenkinsfile pose le déclencheur) » ; `:1006-1009` — ajouter « Depuis L6, pour plan/apply, le miroir rend « xml=absent jenkinsfile=present token=… vars=N » : c'est l'état voulu, et le côté Jenkinsfile est compté. »

- [ ] **Step 2: L'ADR-098 finalisé**

`status: "Acté et prouvé le 2026-09-11 — spike M1..M9 mesuré au lab ; test-webhook-kind-gitlab-live.sh 17/17 ; non-régression gwt a6-live 50/50, a7-live 99/99, M10 ; make lint-ci 20/20 (a0-wiring 212/212, provision-apply-wiring 147/147, setup-provision-jobs N/N)"`. Sections : `## Décision` (D1..D12 de la spec, en prose courte), `## Refus nommés` (`WEBHOOK_KIND_INVALIDE`, `AMORCAGE_INCOMPLET`), `## Conséquences et limites` (parité `update` imparfaite ; SHA vide en fast-forward ; angle mort du miroir ; trou `locked` ; le secret est un mot ; dettes), `## Preuves` en table `| Preuve | Commande | Résultat |` (M1..M10, gitlab-live, a6/a7-live, lint-ci).

- [ ] **Step 3: Le plan forge-agnostique**

Après `### Task 6 (L4)`, ajouter :
```markdown
### Task 7 (L6) : le récepteur de webhooks à deux visages (`WEBHOOK_KIND`)

Plan complet : `docs/superpowers/plans/2026-09-11-webhook-kind-deux-visages.md`
(spec `docs/superpowers/specs/2026-09-11-webhook-kind-deux-visages-design.md`, ADR-098).
LIVRÉ 2026-09-11.
```
et dans « Structure des fichiers » la ligne `ci/Jenkinsfile.provision-plan|apply|selfservice, ci/jenkins/provision-*.job.xml, scripts/setup-provision-jobs.sh — L6` ; dans « Ordre et pourquoi » : « L6 après L5/L3, indépendant de L2/L4 ». Cocher L1/L5/L3 livrés ; corriger `:124` (`:121,138` → `:194-203,216`).

- [ ] **Step 4: Entêtes restants**

`scripts/setup-provision-jobs.sh:14-16` (« puis à chaque changement de clé du webhook ») : ajouter « Depuis L6 les XML de plan/apply ne portent aucune propriété : re-poser = amorcer, ce script attend et relit. » Vérifier que `ci/Jenkinsfile.provision-plan:82-84` (Task 6) et l'entête de `provision-apply` (Task 7) ne parlent plus du « miroir XML qui gagne » : `grep -n "XML qui gagne\|XML gagne" ci/Jenkinsfile.provision-plan ci/Jenkinsfile.provision-apply` ⇒ vide.

- [ ] **Step 5: lint-ci, commit, push**

Run: `make lint-ci 2>&1 | tail -3`
Expected: `[20/20]` vert.
```bash
git add ENVIRONNEMENTS.md adr/adr-098-recepteur-de-webhooks-a-deux-visages.md docs/superpowers/plans/2026-09-09-forge-agnostique-debug-branche.md scripts/setup-provision-jobs.sh
git commit -m "docs(l6): ENVIRONNEMENTS § Le récepteur de webhooks, ADR-098 acté et prouvé, plan forge-agnostique Task 7 → renvoi"
git push gitea HEAD:main && git push origin HEAD:main
```
(le push suit la règle des trois dépôts : gitea = ce que lit le CI du lab, origin = GitHub ; la copie client est livrée EN BLOC par l'utilisateur après ce vert.)

---

## Auto-relecture du plan (faite le 2026-09-11)

- **Couverture de la spec** : §5 knob → Tasks 6/7/9/11 ; §6 visages + troisième visage → 6/7/9 ; §7 XML/poseur → 8/10 ; §8 porte → 4/5/7/9/10 ; §9.1 spike → 1/2/3 ; §9.2 → 13 ; §9.3 → 14 ; §10 doc/ADR/plan → 1 (brouillon), 15 ; §11 ordre → l'ordre des tasks ; §12 dettes → ADR (Task 15) et doc.
- **Cohérence des noms** : `WEBHOOK_KIND`, `WEBHOOK_KIND_INVALIDE`, `AMORCAGE_INCOMPLET`, `BOOTSTRAP_JOBS`/`BOOTSTRAP_AWAIT_JOBS`/`BOOTSTRAP_WAIT`, `recepteur_check`, `solo_expect`, `amorcage_relu`, la ligne `DIVERGENCE trigger xml=absent jenkinsfile=present token=… vars=N`, `gitlab(` avec les mêmes 18 champs en Tasks 3 (spike), 5 (porte), 6 et 7 (code).
- **Comptes** : a0-wiring 200 → 211 (Task 5) → 212 (Task 9) ; provision-apply-wiring 151 → 147 (Task 7) ; a4 « 152/152 » → « 147/147 » ; setup-provision-jobs : recalculer à la Task 10 (le total n'est pas en dur dans cette suite).
- **Points à trancher pendant l'exécution, pas avant** : si M2 ne rend pas de doublon, la voie A reste valide (Task 8 conserve son sens : un XML vide n'a rien à perdre) ; si M6 rend un `merge_commit_sha` vide en méthode merge, arrêter et revenir à la spec §6.2.
