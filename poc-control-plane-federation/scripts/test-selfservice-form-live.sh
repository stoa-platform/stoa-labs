#!/usr/bin/env bash
# test-selfservice-form-live.sh — la dette 2 d'A0 par BUILDS RÉELS : le job
# selfservice-app-deploy est RE-POSÉ par scripts/setup-selfservice-job.sh (XML
# sans paramètre + amorçage + relecture), puis sa configuration est relue et un
# PLAN par webhook est joué. Fait 6 vérifié sur le job RÉEL, sur deux builds :
# UNE propriété de paramètres, trigger stoa-selfservice-plan et
# disableConcurrentBuilds préservés, ENVIRONMENT == env_chain_nonprod (calculé
# depuis gitea main, la source du build). Le harnais A2 (test-provision-apply-
# a2-live.sh) reste la preuve de l'apply par build job: sous properties().
#
# Le build d'amorçage traverse le préflight gateway (jusqu'à 300 s pendant un
# recyclage) : la suite pose /tmp/wm-keepalive.pause le temps de la pose.
#
#   JENKINS_UI=http://localhost:18080 GITEA_URL=http://localhost:13000 bash scripts/test-selfservice-form-live.sh
set -uo pipefail
set +x
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO" || exit 1
JENKINS_UI="${JENKINS_UI:?JENKINS_UI requis}"; GITEA_URL="${GITEA_URL:?GITEA_URL requis}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"; PFX="poc-control-plane-federation"; JOB=selfservice-app-deploy
TMP="$(mktemp -d /tmp/ssf-live.XXXXXX)"; PAUSED=0
cleanup(){ [ "$PAUSED" = 1 ] && rm -f /tmp/wm-keepalive.pause; rm -rf "$TMP"; }; trap cleanup EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
die(){ printf '\n%s\n' "$*" >&2; exit 1; }
jq_(){ python3 -c "import sys,json; d=json.load(sys.stdin); $1"; }
cfg(){ curl -s "$JENKINS_UI/job/$JOB/config.xml" | python3 -c '
import sys, xml.etree.ElementTree as T
r = T.fromstring(sys.stdin.read())
env = [" ".join(s.text or "" for s in p.iter("string")) for p in r.iter() if p.tag.endswith("ChoiceParameterDefinition") and p.findtext("name") == "ENVIRONMENT"]
print("NPROP=%d" % sum(1 for e in r.iter() if e.tag.endswith("ParametersDefinitionProperty")))
print("PARAMS=%s" % " ".join(p.findtext("name") for p in r.iter() if p.tag.endswith("ParameterDefinition")))
print("ENV=%s" % (env[0] if env else ""))
print("TOKEN=%s" % ",".join(t.findtext("token") or "" for t in r.iter() if t.tag.endswith("GenericTrigger")))
print("DISABLE=%d" % sum(1 for e in r.iter() if e.tag.endswith("DisableConcurrentBuildsJobProperty")))'; }
jresult(){ curl -sg "$JENKINS_UI/job/$JOB/$1/api/json?tree=result,building" 2>/dev/null | jq_ 'print("building" if d.get("building") else (d.get("result") or ""))' 2>/dev/null || true; }
wait_build(){ local i r; for i in $(seq 1 "$(( $2 / 3 ))"); do r=$(jresult "$1"); [ -n "$r" ] && [ "$r" != "building" ] && { printf '%s' "$r"; return 0; }; sleep 3; done; printf '%s' "$(jresult "$1")"; return 1; }

echo "== 0. préflights =="
curl -sf "$JENKINS_UI/crumbIssuer/api/json" >/dev/null || die "LAB_ABSENT : Jenkins"
curl -s "$GITEA_URL/api/v1/repos/$GIT_REPO/raw/main/$PFX/ci/Jenkinsfile.selfservice" | grep -q 'properties(\[parameters(\[' || die "PREREQUIS : Jenkinsfile.selfservice sur gitea main sans properties() — git push gitea HEAD:main"
CHAIN_MAIN=$(curl -s "$GITEA_URL/api/v1/repos/$GIT_REPO/raw/main/$PFX/clients/_example/environments.yaml" | python3 -c "import sys,yaml; e=(yaml.safe_load(sys.stdin) or {}).get('environments') or []; print(' '.join(e[:-1]))")
[ -n "$CHAIN_MAIN" ] || die "PREREQUIS : chaîne illisible sur gitea main"
ok "lab joignable, Jenkinsfile.selfservice A0 sur gitea main, chaîne hors terminus (gitea main) = [$CHAIN_MAIN]"
cfg > "$TMP/before"; ok "état AVANT re-pose : $(tr '\n' ' ' < "$TMP/before")"

echo
echo "== 1. RE-POSE par setup-selfservice-job.sh (XML sans paramètre + amorçage + relecture) =="
touch /tmp/wm-keepalive.pause; PAUSED=1
N_BOOT=$(curl -sfg "$JENKINS_UI/job/$JOB/api/json?tree=nextBuildNumber" | jq_ 'print(d["nextBuildNumber"])')
if JENKINS="$JENKINS_UI" bash scripts/setup-selfservice-job.sh > "$TMP/pose.log" 2>&1; then
  ok "setup-selfservice-job.sh : rc 0 — $(grep -E 'relecture|amorçage #' "$TMP/pose.log" | tr '\n' ' ' | cut -c1-200)"
else
  ko "setup-selfservice-job.sh en échec : $(tail -4 "$TMP/pose.log" | tr '\n' ' ')"
fi
grep -q 'XML_PARAMS=no' "$TMP/pose.log" && ok "mode XML_PARAMS=no (auto : Jenkinsfile.selfservice), amorçage par POST /build" || ko "mode XML_PARAMS inattendu"
[ "$(jresult "$N_BOOT")" = SUCCESS ] && ok "build d'amorçage #$N_BOOT : SUCCESS (PLAN-only, formulaire posé)" || ko "amorçage #$N_BOOT : $(jresult "$N_BOOT")"
cfg > "$TMP/after1"
grep -qx 'NPROP=1' "$TMP/after1" && ok "config relue : UNE propriété de paramètres (fait 6 sur le job réel)" || ko "config : $(grep NPROP "$TMP/after1")"
grep -qx 'PARAMS=MANIFEST MERGE_SHA ENVIRONMENT ADMIN_VIA DEBUG VAULT_USER VAULT_USER_PASSWORD USER_VAULT_JWT' "$TMP/after1" && ok "les 8 paramètres, dans l'ordre du Jenkinsfile" || ko "paramètres : $(grep PARAMS "$TMP/after1")"
grep -qx "ENV=$CHAIN_MAIN" "$TMP/after1" && ok "ENVIRONMENT == env_chain_nonprod de gitea main [$CHAIN_MAIN] — plus aucune liste en dur" || ko "ENVIRONMENT : $(grep ENV= "$TMP/after1") ≠ [$CHAIN_MAIN]"
grep -qx 'TOKEN=stoa-selfservice-plan' "$TMP/after1" && grep -qx 'DISABLE=1' "$TMP/after1" && ok "trigger stoa-selfservice-plan et disableConcurrentBuilds PRÉSERVÉS (déclaratifs + properties() scripté)" || ko "trigger/option : $(grep -E 'TOKEN|DISABLE' "$TMP/after1" | tr '\n' ' ')"
rm -f /tmp/wm-keepalive.pause; PAUSED=0

echo
echo "== 2. PLAN par webhook (deuxième build) : formulaire intact, trigger vivant =="
N_WH=$(curl -sfg "$JENKINS_UI/job/$JOB/api/json?tree=nextBuildNumber" | jq_ 'print(d["nextBuildNumber"])')
HC=$(curl -s -X POST -H 'Content-Type: application/json' -d '{"manifest":"clients/_example/applications/demo-consumer.ansible.yml"}' "$JENKINS_UI/generic-webhook-trigger/invoke?token=stoa-selfservice-plan" -o "$TMP/wh.out" -w '%{http_code}')
[ "$HC" = 200 ] && grep -q '"triggered":true' "$TMP/wh.out" && ok "webhook PLAN accepté (HTTP 200, triggered)" || ko "webhook PLAN : HTTP $HC $(head -c 200 "$TMP/wh.out")"
R=$(wait_build "$N_WH" 420); [ "$R" = SUCCESS ] && ok "build PLAN par webhook #$N_WH : SUCCESS" || ko "build PLAN #$N_WH : ${R:-jamais terminé}"
curl -s "$JENKINS_UI/job/$JOB/$N_WH/consoleText" | grep -q 'formulaire posé : paliers' && ok "console : le stage Formulaire a reposé le formulaire (listes du clone)" || ko "console sans stage Formulaire"
curl -s "$JENKINS_UI/job/$JOB/$N_WH/consoleText" | grep -q "PLAN : manifeste clients/_example/applications/demo-consumer.ansible.yml" && ok "MANIFEST du webhook bien lu par le PLAN (withEnv([params…]) : params.MANIFEST porte la valeur GWT)" || ko "MANIFEST du webhook non lu par le PLAN"
cfg > "$TMP/after2"; cmp -s "$TMP/after1" "$TMP/after2" && ok "config IDENTIQUE après le deuxième build (une propriété, trigger, option, 8 paramètres)" || ko "config a changé entre les deux builds : $(diff "$TMP/after1" "$TMP/after2" | tr '\n' ' ')"

echo; echo "======================================================================"; printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
