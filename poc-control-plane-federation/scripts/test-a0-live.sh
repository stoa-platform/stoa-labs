#!/usr/bin/env bash
# test-a0-live.sh — la PORTE et la CONTRE-ÉPREUVE d'A0 (GOAL cd-applications),
# par BUILDS RÉELS sur le lab : Jenkins + Gitea (aucune gateway : la voie
# d'entrée s'arrête à la PR et à son plan).
#
#   POSE : les coquilles from SCM de provision-plan / provisioning-request sont
#     (re)posées, app-request est posé PUIS AMORCÉ ; relecture : les quatre jobs
#     chargent leur pipeline depuis SCM sans un élément <script>, le build
#     d'amorçage est vert et NOMMÉ, le formulaire porte ses onze paramètres avec
#     REQ_ENV == env_chain_nonprod, TEAM == '' + providers.dev.yml, API non vide.
#   PORTE voie MACHINE : webhook stoa-provision-request ⇒ provisioning-request
#     SUCCESS ⇒ PR provision/<app>-dev ouverte ⇒ provision-plan (hook Gitea)
#     SUCCESS ⇒ commentaire « Plan self-service OK » sur la PR — le MÊME résultat
#     qu'avant conversion.
#   PORTE voie HUMAINE : buildWithParameters app-request ⇒ SUCCESS (pas un
#     amorçage) ⇒ PR ⇒ plan commenté ; le formulaire SURVIT au build (fait 1).
#   CONTRE-ÉPREUVE : IP_ALLOWLIST = `RAW>${JENKINS_HOME}<FIN` ⇒ FAILURE, le
#     refus IP_ALLOWLIST_INVALID cite la valeur LITTÉRALE (jamais
#     /var/jenkins_home), aucune branche créée.
#
# ── FAIL-CLOSED, JAMAIS DE SKIP MUET ────────────────────────────────────────
# Prérequis manquant ⇒ exit 1 `LAB_ABSENT : …` ou `PREREQUIS : …`. Les jobs
# from SCM lisent gitea main : les fichiers A0 doivent y être POUSSÉS avant.
#
# ── CE QUE CE SCRIPT ÉCRIT DANS LE LAB, ET CE QU'IL REMET ────────────────────
#   - re-pose 3 jobs (historique conservé) + 1 build d'amorçage ;
#   - ouvre DEUX PR provision/* pour des applications JETABLES a0m<ts>/a0h<ts>
#     (jamais mergées), les FERME et supprime leurs branches en fin de suite ;
#     les commentaires de plan restent sur les PR fermées (inoffensif) ;
#   - un build app-request en échec volontaire (a0r<ts>), sans branche.
#
# Entrées (env) — OBLIGATOIRES, sans défaut vers un système en service :
#   JENKINS_UI      ex. http://localhost:18080 (ouvert, crumb seul)
#   GITEA_URL       ex. http://localhost:13000 (vu du poste)
# Optionnelles : GITEA_TOKEN_FILE (token ci write:repository,write:issue — sinon
#   minté via `docker exec poc-gitea`), GITEA_CONTAINER (poc-gitea), GIT_REPO.
#
#   JENKINS_UI=http://localhost:18080 GITEA_URL=http://localhost:13000 bash scripts/test-a0-live.sh
set -uo pipefail
set +x
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
JENKINS_UI="${JENKINS_UI:?JENKINS_UI requis (ex. http://localhost:18080)}"
GITEA_URL="${GITEA_URL:?GITEA_URL requis (ex. http://localhost:13000)}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
GITEA_CONTAINER="${GITEA_CONTAINER:-poc-gitea}"
PFX="poc-control-plane-federation"

TS="$(date +%s)"
TMP="$(mktemp -d /tmp/a0-live.XXXXXX)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
die(){ printf '\n%s\n' "$*" >&2; exit 1; }
jq_(){ python3 -c "import sys,json; d=json.load(sys.stdin); $1"; }

# ── helpers Jenkins ──────────────────────────────────────────────────────────
jcrumb(){ curl -sf -c "$1" "$JENKINS_UI/crumbIssuer/api/json" | jq_ 'print(d["crumbRequestField"]+": "+d["crumb"])'; }
jnext(){ curl -sfg "$JENKINS_UI/job/$1/api/json?tree=nextBuildNumber" | jq_ 'print(d["nextBuildNumber"])'; }
jresult(){ curl -sg "$JENKINS_UI/job/$1/$2/api/json?tree=result,building" 2>/dev/null | jq_ 'print(d.get("result") or ("building" if d.get("building") else ""))' 2>/dev/null || true; }
jname(){ curl -sg "$JENKINS_UI/job/$1/$2/api/json?tree=displayName" 2>/dev/null | jq_ 'print(d.get("displayName",""))' 2>/dev/null || true; }
wait_build(){ # $1=job $2=n $3=secondes → imprime le résultat final ('' si jamais fini)
  local i r; for i in $(seq 1 "$(( $3 / 3 ))"); do r=$(jresult "$1" "$2"); [ -n "$r" ] && [ "$r" != "building" ] && { printf '%s' "$r"; return 0; }; sleep 3; done; printf '%s' "$(jresult "$1" "$2")"; return 1
}
jparams(){ curl -sg "$JENKINS_UI/job/$1/api/json?tree=property[parameterDefinitions[name,choices]]" | jq_ '
import json as J
out=[(p["name"], p.get("choices")) for pr in d.get("property",[]) for p in pr.get("parameterDefinitions",[])]
print(J.dumps(out))'; }
# ── helpers Gitea ────────────────────────────────────────────────────────────
GITEA_TOKEN=""
if [ -n "${GITEA_TOKEN_FILE:-}" ] && [ -r "$GITEA_TOKEN_FILE" ]; then GITEA_TOKEN="$(cat "$GITEA_TOKEN_FILE")"
elif docker inspect "$GITEA_CONTAINER" >/dev/null 2>&1; then
  GITEA_TOKEN=$(docker exec -u git "$GITEA_CONTAINER" gitea admin user generate-access-token --username ci --token-name "a0-live-$TS" --scopes write:repository,write:issue 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
fi
[ -n "$GITEA_TOKEN" ] || die "LAB_ABSENT : aucun token Gitea (GITEA_TOKEN_FILE ou docker exec $GITEA_CONTAINER)"
gapi(){ curl -s -H "Authorization: token $GITEA_TOKEN" "$@"; }
pr_by_head(){ gapi "$GITEA_URL/api/v1/repos/$GIT_REPO/pulls?state=open&limit=50" | jq_ "
import sys
for p in d:
    if p['head']['ref'] == '$1': print(p['number']); break"; }
pr_comments(){ gapi "$GITEA_URL/api/v1/repos/$GIT_REPO/issues/$1/comments" | jq_ 'print("\n".join(c["body"] for c in d))'; }
close_pr(){ gapi -X PATCH -H 'Content-Type: application/json' -d '{"state":"closed"}' "$GITEA_URL/api/v1/repos/$GIT_REPO/pulls/$1" -o /dev/null -w '%{http_code}'; }
del_branch(){ gapi -X DELETE "$GITEA_URL/api/v1/repos/$GIT_REPO/branches/$1" -o /dev/null -w '%{http_code}'; }
branch_code(){ gapi "$GITEA_URL/api/v1/repos/$GIT_REPO/branches/$1" -o /dev/null -w '%{http_code}'; }
wait_plan(){ # $1=app $2=pr $3=n_min $4=secondes → numéro du build provision-plan « plan <app>/dev (PR #n) », '' sinon
  local i n; for i in $(seq 1 "$(( $4 / 3 ))"); do
    n=$(curl -sg "$JENKINS_UI/job/provision-plan/api/json?tree=builds[number,displayName]{0,15}" | jq_ "
for b in d['builds']:
    if b['number'] >= $3 and b.get('displayName') == 'plan $1/dev (PR #$2)': print(b['number']); break")
    [ -n "$n" ] && { printf '%s' "$n"; return 0; }; sleep 3; done; return 1
}
wait_comment(){ # $1=pr $2=motif $3=secondes
  local i; for i in $(seq 1 "$(( $3 / 3 ))"); do pr_comments "$1" 2>/dev/null | grep -qF -- "$2" && return 0; sleep 3; done; return 1
}

echo "== 0. préflights (fail-closed) =="
JAR="$TMP/jar"; CR=$(jcrumb "$JAR") || die "LAB_ABSENT : Jenkins injoignable ($JENKINS_UI)"
curl -sf "$GITEA_URL/api/v1/version" >/dev/null || die "LAB_ABSENT : Gitea injoignable ($GITEA_URL)"
for F in ci/Jenkinsfile.provision-plan ci/Jenkinsfile.provisioning-request scripts/app-request-choices.sh scripts/lib/gwt-mirror.sh; do
  HC=$(gapi "$GITEA_URL/api/v1/repos/$GIT_REPO/contents/$PFX/$F?ref=main" -o /dev/null -w '%{http_code}')
  [ "$HC" = 200 ] || die "PREREQUIS : $F absent de gitea main (HTTP $HC) — les jobs from SCM lisent gitea : git push gitea HEAD:main"
done
NPX=$(gapi "$GITEA_URL/api/v1/repos/$GIT_REPO/raw/main/$PFX/ci/jenkins/app-request.job.xml" | python3 -c "import sys,xml.etree.ElementTree as T; r=T.fromstring(sys.stdin.read()); print(sum(1 for e in r.iter() if e.tag.endswith('ParameterDefinition')))")
[ "$NPX" = 0 ] || die "PREREQUIS : app-request.job.xml sur gitea main porte encore $NPX paramètre(s) — A0 non poussé"
gapi "$GITEA_URL/api/v1/repos/$GIT_REPO/hooks" | jq_ 'print(any("stoa-provision-plan" in h["config"].get("url","") and h["active"] for h in d))' | grep -q True || die "PREREQUIS : hook Gitea stoa-provision-plan absent/inactif sur $GIT_REPO"
# shellcheck source=scripts/lib/env-chain.sh
. scripts/lib/env-chain.sh || die "PREREQUIS : env-chain.sh"
CHAIN_NONPROD="$(env_chain_nonprod)" || die "PREREQUIS : env_chain_nonprod"
TEAMS_MAIN=$(gapi "$GITEA_URL/api/v1/repos/$GIT_REPO/raw/main/$PFX/ansible/providers.dev.yml" | python3 -c "import sys,yaml; d=yaml.safe_load(sys.stdin) or {}; print(' '.join(p['team'] for p in (d.get('providers') or []) if p.get('team')))")
[ -n "$TEAMS_MAIN" ] || die "PREREQUIS : aucune équipe dans providers.dev.yml sur gitea main"
ok "lab joignable, A0 poussé sur gitea main, hook plan actif, chaîne=[$CHAIN_NONPROD], équipes=[$TEAMS_MAIN]"

echo
echo "== 1. POSE des coquilles + AMORÇAGE d'app-request =="
N_BOOT=$(jnext app-request)
if JENKINS_UI="$JENKINS_UI" JOBS="provision-plan provisioning-request" bash scripts/setup-provision-jobs.sh >"$TMP/pose1.log" 2>&1; then
  ok "provision-plan + provisioning-request (re)posés en place (rc 0)"; else ko "pose provision-plan/provisioning-request en échec : $(tail -3 "$TMP/pose1.log" | tr '\n' ' ')"; fi
if JENKINS_UI="$JENKINS_UI" JOBS="app-request" bash scripts/setup-team-onboard-jobs.sh >"$TMP/pose2.log" 2>&1 && grep -q "build d'amorçage déclenché" "$TMP/pose2.log"; then
  ok "app-request posé (sans token Gitea, sans substitution) et AMORCÉ (build #$N_BOOT demandé)"; else ko "pose/amorçage d'app-request en échec : $(tail -4 "$TMP/pose2.log" | tr '\n' ' ')"; fi
R=$(wait_build app-request "$N_BOOT" 300)
[ "$R" = SUCCESS ] && ok "build d'amorçage app-request #$N_BOOT : SUCCESS" || ko "build d'amorçage #$N_BOOT : ${R:-jamais terminé} — $JENKINS_UI/job/app-request/$N_BOOT/console"
[ "$(jname app-request "$N_BOOT")" = "amorçage du formulaire (aucune demande)" ] && ok "… NOMMÉ « amorçage du formulaire (aucune demande) » (params.size()==0 capturé avant properties)" || ko "displayName inattendu : $(jname app-request "$N_BOOT")"
curl -s "$JENKINS_UI/job/app-request/$N_BOOT/consoleText" > "$TMP/boot.log"
grep -q 'Les stages suivants sont sautés' "$TMP/boot.log" && ! grep -q 'bash scripts/provision-request.sh' "$TMP/boot.log" \
  && ok "… les stages de demande ont été SAUTÉS (aucune PR ouverte par l'amorçage)" || ko "l'amorçage a tenté une demande"
P=$(jparams app-request); printf '%s' "$P" > "$TMP/params.json"
NAMES=$(python3 -c "import json; print(' '.join(n for n,_ in json.load(open('$TMP/params.json'))))")
[ "$NAMES" = "APP REQ_ENV TEAM API CLIENT_ID MODE IP_ALLOWLIST CERT_PEM CERT_ROTATION BACKEND_KEY_REF BACKEND_KEY_FIELD" ] \
  && ok "formulaire posé : les 11 paramètres, dans l'ordre" || ko "paramètres relus : [$NAMES]"
ENVS_POSED=$(python3 -c "import json; print(' '.join(dict(json.load(open('$TMP/params.json')))['REQ_ENV']))")
[ "$ENVS_POSED" = "$CHAIN_NONPROD" ] && ok "REQ_ENV == env_chain_nonprod [$ENVS_POSED] (terminus exclu par structure)" || ko "REQ_ENV posé [$ENVS_POSED] ≠ chaîne [$CHAIN_NONPROD]"
TEAMS_POSED=$(python3 -c "import json; c=dict(json.load(open('$TMP/params.json')))['TEAM']; print('|'.join(c))")
[ "$TEAMS_POSED" = "|$(printf '%s' "$TEAMS_MAIN" | tr ' ' '|')" ] && ok "TEAM == '' + providers.dev.yml de gitea main [$TEAMS_POSED]" || ko "TEAM posé [$TEAMS_POSED] ≠ ''|$(printf '%s' "$TEAMS_MAIN" | tr ' ' '|')"
FIRST_API=$(python3 -c "import json; c=dict(json.load(open('$TMP/params.json')))['API']; print(c[0] if c else '')")
[ -n "$FIRST_API" ] && case "$FIRST_API" in *@*) ok "API non vide, premier choix $FIRST_API (nom@version)";; *) ko "API sans '@' : $FIRST_API";; esac || ko "liste API vide"
FIRST_API_NAME="${FIRST_API%%@*}"; FIRST_API_VER="${FIRST_API#*@}"
BAD=""
for J in provision-apply provision-plan provisioning-request app-request; do
  curl -s "$JENKINS_UI/job/$J/config.xml" > "$TMP/$J.cfg.xml"
  python3 - "$TMP/$J.cfg.xml" <<'PY' || BAD="$BAD $J"
import sys, xml.etree.ElementTree as T
r = T.parse(sys.argv[1]).getroot(); d = r.find('definition')
ok = d is not None and d.get('class') == 'org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition' and r.find('.//script') is None
sys.exit(0 if ok else 1)
PY
done
[ -z "$BAD" ] && ok "les 4 jobs SUR LE LAB chargent leur pipeline depuis SCM, sans un élément <script> (config relue)" || ko "jobs encore inline/divergents :$BAD"

echo
echo "== 2. PORTE voie MACHINE : webhook ⇒ PR ⇒ plan commenté =="
APP_M="a0m$TS"; N_REQ=$(jnext provisioning-request); N_PLAN0=$(jnext provision-plan)
printf '{"app":"%s","env":"dev","clientId":"%s-dev","api":"%s","apiVersion":"%s","audience":"%s","caller":"oig-provisioner"}' "$APP_M" "$APP_M" "$FIRST_API_NAME" "$FIRST_API_VER" "$FIRST_API_NAME" > "$TMP/wh.json"
HC=$(curl -s -X POST -H 'Content-Type: application/json' --data-binary @"$TMP/wh.json" "$JENKINS_UI/generic-webhook-trigger/invoke?token=stoa-provision-request" -o "$TMP/wh.out" -w '%{http_code}')
[ "$HC" = 200 ] && grep -q '"triggered":true' "$TMP/wh.out" && ok "webhook stoa-provision-request accepté (HTTP 200, triggered) — le déclencheur du XML est VIVANT après la pose" || ko "webhook : HTTP $HC — $(head -c 300 "$TMP/wh.out")"
R=$(wait_build provisioning-request "$N_REQ" 300)
[ "$R" = SUCCESS ] && ok "provisioning-request #$N_REQ : SUCCESS (Jenkinsfile from SCM)" || ko "provisioning-request #$N_REQ : ${R:-jamais terminé} — $JENKINS_UI/job/provisioning-request/$N_REQ/console"
[ "$(jname provisioning-request "$N_REQ")" = "demande $APP_M/dev (oig-provisioner)" ] && ok "… nommé « demande $APP_M/dev (oig-provisioner) »" || ko "displayName : $(jname provisioning-request "$N_REQ")"
PR_M=""; for _ in $(seq 1 20); do PR_M=$(pr_by_head "provision/$APP_M-dev"); [ -n "$PR_M" ] && break; sleep 3; done
[ -n "$PR_M" ] && ok "PR provision/$APP_M-dev ouverte (#$PR_M) — même résultat qu'avant conversion" || ko "aucune PR provision/$APP_M-dev"
if [ -n "$PR_M" ]; then
  NP=$(wait_plan "$APP_M" "$PR_M" "$N_PLAN0" 240)
  [ -n "$NP" ] && ok "provision-plan #$NP déclenché par le hook Gitea, nommé « plan $APP_M/dev (PR #$PR_M) »" || ko "aucun build provision-plan nommé pour la PR #$PR_M"
  if [ -n "$NP" ]; then
    R=$(wait_build provision-plan "$NP" 300)
    [ "$R" = SUCCESS ] && ok "provision-plan #$NP : SUCCESS" || ko "provision-plan #$NP : ${R:-jamais terminé} — $JENKINS_UI/job/provision-plan/$NP/console"
  fi
  wait_comment "$PR_M" "Plan self-service OK" 120 && ok "PR #$PR_M commentée « ✅ Plan self-service OK » (marqueur provision-plan)" || ko "PR #$PR_M sans commentaire de plan OK"
fi

echo
echo "== 3. PORTE voie HUMAINE : formulaire ⇒ PR ⇒ plan commenté ; le formulaire survit =="
APP_H="a0h$TS"; N_APP=$(jnext app-request); N_PLAN1=$(jnext provision-plan)
HC=$(curl -s -b "$JAR" -H "$CR" -X POST "$JENKINS_UI/job/app-request/buildWithParameters" \
  --data-urlencode "APP=$APP_H" --data-urlencode "REQ_ENV=dev" --data-urlencode "TEAM=" --data-urlencode "API=$FIRST_API" \
  --data-urlencode "CLIENT_ID=" --data-urlencode "MODE=internal" --data-urlencode "IP_ALLOWLIST=" --data-urlencode "CERT_PEM=" \
  --data-urlencode "CERT_ROTATION=replace" --data-urlencode "BACKEND_KEY_REF=" --data-urlencode "BACKEND_KEY_FIELD=" -o /dev/null -w '%{http_code}')
[ "$HC" = 201 ] && ok "buildWithParameters accepté (HTTP 201) : le formulaire posé par le build EXISTE" || ko "buildWithParameters : HTTP $HC"
R=$(wait_build app-request "$N_APP" 300)
[ "$R" = SUCCESS ] && ok "app-request #$N_APP : SUCCESS" || ko "app-request #$N_APP : ${R:-jamais terminé} — $JENKINS_UI/job/app-request/$N_APP/console"
case "$(jname app-request "$N_APP")" in *amorçage*) ko "le build de demande a été pris pour un amorçage";; *) ok "… ce n'est PAS un amorçage (FORM_BOOTSTRAP=false : les paramètres étaient liés)";; esac
PR_H=""; for _ in $(seq 1 20); do PR_H=$(pr_by_head "provision/$APP_H-dev"); [ -n "$PR_H" ] && break; sleep 3; done
[ -n "$PR_H" ] && ok "PR provision/$APP_H-dev ouverte (#$PR_H)" || ko "aucune PR provision/$APP_H-dev"
if [ -n "$PR_H" ]; then
  NP=$(wait_plan "$APP_H" "$PR_H" "$N_PLAN1" 240)
  [ -n "$NP" ] && R=$(wait_build provision-plan "$NP" 300) && [ "$R" = SUCCESS ] && ok "provision-plan #$NP : SUCCESS pour la PR #$PR_H" || ko "plan de la PR #$PR_H : build ${NP:-introuvable} ${R:-}"
  wait_comment "$PR_H" "Plan self-service OK" 120 && ok "PR #$PR_H commentée « ✅ Plan self-service OK »" || ko "PR #$PR_H sans commentaire de plan OK"
fi
NAMES2=$(jparams app-request | python3 -c "import sys,json; print(' '.join(n for n,_ in json.load(sys.stdin)))")
[ "$NAMES2" = "$NAMES" ] && ok "le formulaire SURVIT au build de demande (11 paramètres toujours posés — fait 1)" || ko "formulaire altéré après le build : [$NAMES2]"

echo
echo "== 4. CONTRE-ÉPREUVE : RAW>\${JENKINS_HOME}<FIN arrive INTACT au script (refusé, littéral cité, aucune branche) =="
APP_R="a0r$TS"; N_RAW=$(jnext app-request)
HC=$(curl -s -b "$JAR" -H "$CR" -X POST "$JENKINS_UI/job/app-request/buildWithParameters" \
  --data-urlencode "APP=$APP_R" --data-urlencode "REQ_ENV=dev" --data-urlencode "API=$FIRST_API" --data-urlencode "MODE=internal" \
  --data-urlencode 'IP_ALLOWLIST=RAW>${JENKINS_HOME}<FIN' --data-urlencode "CERT_ROTATION=replace" -o /dev/null -w '%{http_code}')
[ "$HC" = 201 ] && ok "build #$N_RAW lancé avec IP_ALLOWLIST=RAW>\${JENKINS_HOME}<FIN" || ko "buildWithParameters : HTTP $HC"
R=$(wait_build app-request "$N_RAW" 300)
[ "$R" = FAILURE ] && ok "app-request #$N_RAW : FAILURE (refus fermé)" || ko "app-request #$N_RAW : ${R:-jamais terminé} (attendu FAILURE)"
curl -s "$JENKINS_UI/job/app-request/$N_RAW/consoleText" > "$TMP/raw.log"
grep -q 'IP_ALLOWLIST_INVALID' "$TMP/raw.log" && ok "refus nommé IP_ALLOWLIST_INVALID" || ko "IP_ALLOWLIST_INVALID absent de la console"
grep -qF 'RAW>${JENKINS_HOME}<FIN' "$TMP/raw.log" && ok "la valeur LITTÉRALE RAW>\${JENKINS_HOME}<FIN est citée par le refus : elle est arrivée intacte (withEnv([params…]))" || ko "la valeur littérale n'apparaît pas dans le refus"
grep -qF 'RAW>/var/jenkins_home<FIN' "$TMP/raw.log" && ko "la valeur RÉSOLUE (/var/jenkins_home) est apparue : EnvVars.resolve a frappé" || ok "jamais RAW>/var/jenkins_home<FIN : rien n'a été résolu"
[ "$(branch_code "provision/$APP_R-dev")" = 404 ] && ok "aucune branche provision/$APP_R-dev (refus AVANT tout geste Git)" || ko "une branche provision/$APP_R-dev existe"
[ -z "$(pr_by_head "provision/$APP_R-dev")" ] && ok "aucune PR pour $APP_R" || ko "une PR existe pour $APP_R"

echo
echo "== 5. nettoyage (PR jetables fermées, branches supprimées — rien n'a atteint main) =="
for PR in ${PR_M:-} ${PR_H:-}; do HC=$(close_pr "$PR"); [ "$HC" = 201 ] || [ "$HC" = 200 ] && echo "  PR #$PR fermée (HTTP $HC)" || echo "  ⚠ PR #$PR : fermeture HTTP $HC"; done
for B in "provision/$APP_M-dev" "provision/$APP_H-dev"; do HC=$(del_branch "$B"); echo "  branche $B : suppression HTTP $HC"; done
rm -rf "$TMP"
echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
