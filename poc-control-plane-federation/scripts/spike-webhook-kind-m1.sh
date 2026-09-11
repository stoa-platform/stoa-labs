#!/usr/bin/env bash
# scripts/spike-webhook-kind-m1.sh — M1 (spec 2026-09-11 §9.1) : sur un Jenkins
# SANS le plugin qui porte le symbole d'un déclencheur,
#   (a) un `triggers { gitlab(...) }` DÉCLARATIF meurt au PARSE ;
#   (b) le même symbole dans un `properties()` SCRIPTÉ sous `if (false)` ne meurt
#       PAS (le symbole est résolu à l'invocation, pas à la compilation) ;
#   (c) sous `if (true)` il meurt à l'INVOCATION, nommément.
# C'est (b) qui rend possible le récepteur à deux visages : un site sans le
# plugin de l'AUTRE visage n'exécute jamais sa branche, donc ne le résout jamais.
#
# JETABLE : trois jobs `spike-m1-*`, supprimés à la fin (même en cas d'échec).
# Aucun job de la chaîne n'est touché. Lecture/écriture sur le Jenkins du LAB.
#
#   JENKINS_UI=http://localhost:18080 bash scripts/spike-webhook-kind-m1.sh
#
# PRÉREQUIS : le plugin nommé par SYMBOLE_PLUGIN doit être ABSENT (le script le
# vérifie et REFUSE sinon — mesurer l'inverse ne prouverait rien).
# Directives shellcheck : SC2329 cleanup est invoquée par `trap`, SC2034 le `i`
# des boucles d'attente n'est qu'un compteur, SC2015 `A && say … || say …` est
# ici un si-alors-sinon valide (say finit par printf, rc 0).
# shellcheck disable=SC2329,SC2034,SC2015
set -uo pipefail
J="${JENKINS_UI:-http://localhost:18080}"
SYMBOLE="${SYMBOLE:-gitlab}"                       # le symbole à éprouver
SYMBOLE_ARGS="${SYMBOLE_ARGS:-triggerOnPush: false}"
SYMBOLE_PLUGIN="${SYMBOLE_PLUGIN:-gitlab-plugin}"  # le plugin qui le porte
TMP="$(mktemp -d /tmp/spkm1.XXXXXX)"
JOBS="spike-m1-a spike-m1-b spike-m1-c"
CK="$TMP/ck"
cleanup(){ for n in $JOBS; do jpost "$J/job/$n/doDelete" -o /dev/null >/dev/null 2>&1; done; rm -rf "$TMP"; }
say(){ printf '%s\n' "$*"; }

# curl -g : sans lui, les [] d'un `tree=` sont pris pour un glob d'URL (rc 3).
jget(){ curl -sg --max-time 20 "$@"; }
jcrumb(){ jget -f -c "$CK" "$J/crumbIssuer/api/json" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["crumbRequestField"]+": "+d["crumb"])'; }
CR="$(jcrumb)" || { say "!! crumbIssuer illisible sur $J (portail ? instance éteinte ?)"; rm -rf "$TMP"; exit 2; }
jpost(){ curl -sg --max-time 60 -b "$CK" -H "$CR" -X POST "$@"; }
jresult(){ jget "$J/job/$1/$2/api/json?tree=result,building" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("result") or ("BUILDING" if d.get("building") else ""))' 2>/dev/null || true; }
jconsole(){ jget "$J/job/$1/$2/consoleText"; }

trap cleanup EXIT INT TERM

# ── 0. le plugin doit être ABSENT : sinon la mesure est vide ─────────────────
# L'affectation précède la commande : `python3 -c … P=x` passerait P=x en ARGV.
PRESENT=$(jget "$J/pluginManager/api/json?tree=plugins[shortName]" |
  P="$SYMBOLE_PLUGIN" python3 -c 'import sys,json,os;print("oui" if os.environ["P"] in {x["shortName"] for x in json.load(sys.stdin)["plugins"]} else "non")' 2>/dev/null || echo "?")
[ "$PRESENT" = non ] || { say "!! REFUS: le plugin '$SYMBOLE_PLUGIN' est présent (ou indéterminé : '$PRESENT') — M1 exige son ABSENCE. Éprouver un autre symbole (SYMBOLE=… SYMBOLE_PLUGIN=…)."; exit 2; }
say "0. '$SYMBOLE_PLUGIN' est ABSENT de $J — le symbole '$SYMBOLE' n'est porté par rien (l'état du client)"

spike_job(){ # <nom> <groovy inline>
  local n="$1" g="$2" hc
  python3 - "$n" "$g" > "$TMP/$n.xml" <<'PY'
import sys, xml.sax.saxutils as X
n, g = sys.argv[1], sys.argv[2]
print(f"""<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job"><description>spike M1 {n} (jetable)</description><keepDependencies>false</keepDependencies><properties/>
<definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps"><script>{X.escape(g)}</script><sandbox>true</sandbox></definition>
<disabled>false</disabled></flow-definition>""")
PY
  jpost "$J/job/$n/doDelete" -o /dev/null >/dev/null 2>&1
  hc=$(jpost "$J/createItem?name=$n" -H 'Content-Type: application/xml; charset=utf-8' \
       --data-binary @"$TMP/$n.xml" -o /dev/null -w '%{http_code}')
  [ "$hc" = 200 ] || { say "!! createItem $n : HTTP $hc"; exit 1; }
}
run_and_wait(){ # <nom> → résultat du build #1
  local n="$1" i r
  jpost "$J/job/$n/build" -o /dev/null
  for i in $(seq 1 60); do
    r=$(jresult "$n" 1); [ -n "$r" ] && [ "$r" != BUILDING ] && { echo "$r"; return; }
    sleep 2
  done
  echo TIMEOUT
}

spike_job spike-m1-a "pipeline { agent none; triggers { $SYMBOLE($SYMBOLE_ARGS) }; stages { stage('x') { steps { echo 'ok-a' } } } }"
spike_job spike-m1-b "pipeline { agent none; stages { stage('x') { steps { script { if (false) { properties([pipelineTriggers([$SYMBOLE($SYMBOLE_ARGS)])]) }; echo 'ok-b' } } } } }"
spike_job spike-m1-c "pipeline { agent none; stages { stage('x') { steps { script { if (true) { properties([pipelineTriggers([$SYMBOLE($SYMBOLE_ARGS)])]) }; echo 'ok-c' } } } } }"

RC=0
for n in $JOBS; do
  R=$(run_and_wait "$n"); jconsole "$n" 1 > "$TMP/$n.console"
  case "$n" in
    *-a) if [ "$R" = FAILURE ] && grep -q 'Invalid trigger type' "$TMP/$n.console"; then
           say "M1(a) CONFIRMÉ : \`triggers { $SYMBOLE(...) }\` déclaratif ⇒ $R AU PARSE — « $(grep -m1 -o 'Invalid trigger type.*' "$TMP/$n.console" | cut -c1-70) »"
         else say "M1(a) INATTENDU : $R — $(grep -m1 -iE 'invalid|error|exception' "$TMP/$n.console" | cut -c1-100)"; RC=1; fi ;;
    *-b) if [ "$R" = SUCCESS ] && grep -q 'ok-b' "$TMP/$n.console"; then
           say "M1(b) CONFIRMÉ : le MÊME symbole sous \`if (false)\` en scripté ⇒ $R (jamais résolu)"
         else say "M1(b) INATTENDU : $R — $(grep -m1 -iE 'no such|invalid|error|exception' "$TMP/$n.console" | cut -c1-100)"; RC=1; fi ;;
    *-c) if [ "$R" = FAILURE ] && grep -qi 'No such DSL method' "$TMP/$n.console"; then
           say "M1(c) CONFIRMÉ : sous \`if (true)\` ⇒ $R À L'INVOCATION — « $(grep -m1 -io "No such DSL method '[^']*'" "$TMP/$n.console") »"
         else say "M1(c) INATTENDU : $R — $(grep -m1 -iE 'no such|invalid|error|exception' "$TMP/$n.console" | cut -c1-100)"; RC=1; fi ;;
  esac
done
say "consoles conservées le temps du run : $TMP (supprimé à la sortie)"
[ "$RC" = 0 ] && say "RÉSULTAT M1 : 3/3 — le visage absent doit être SCRIPTÉ et sous \`if\`" \
             || say "RÉSULTAT M1 : ÉCHEC — la spec §4.1 doit être corrigée avant tout code"
exit "$RC"
