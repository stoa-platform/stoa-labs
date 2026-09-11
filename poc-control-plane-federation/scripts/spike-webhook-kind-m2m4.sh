#!/usr/bin/env bash
# scripts/spike-webhook-kind-m2m4.sh — deux mesures qui décident de la forme du
# lot L6 (spec 2026-09-11 §9.1) :
#
#   M2  un XML porteur d'un GenericTrigger + un Jenkinsfile qui pose le MÊME
#       déclencheur par properties([pipelineTriggers([...])]) ⇒ combien de
#       déclencheurs le job porte-t-il après le build 1 ? après le build 2 ?
#       (attendu : 2 puis 1 — le XML est PERDU, pas préservé ; fait 10 du
#       2026-09-02 mesuré sur selfservice-app-deploy, re-mesuré ici).
#   M4  un XML SANS aucune propriété : le webhook est-il MUET avant la fin du
#       build d'amorçage ? vivant après ? (et le /project/<job> du GitLab
#       Plugin, qui répond 200 en silence à un job sans son déclencheur).
#
# JETABLE : deux jobs `spike-m2`, `spike-m4`, supprimés en sortie.
#
#   JENKINS_UI=http://localhost:18080 bash scripts/spike-webhook-kind-m2m4.sh
#
# Directives shellcheck : SC2329 cleanup est invoquée par `trap`, SC2034 le `i`
# des attentes n'est qu'un compteur.
# shellcheck disable=SC2329,SC2034
set -uo pipefail
J="${JENKINS_UI:-http://localhost:18080}"
TMP="$(mktemp -d /tmp/spkm2.XXXXXX)"
JOBS="spike-m2 spike-m4"
CK="$TMP/ck"
say(){ printf '%s\n' "$*"; }
jget(){ curl -sg --max-time 30 "$@"; }   # -g : les [] d'un tree= ne sont pas un glob
jcrumb(){ jget -f -c "$CK" "$J/crumbIssuer/api/json" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["crumbRequestField"]+": "+d["crumb"])'; }
CR="$(jcrumb)" || { say "!! crumbIssuer illisible sur $J"; rm -rf "$TMP"; exit 2; }
jpost(){ curl -sg --max-time 60 -b "$CK" -H "$CR" -X POST "$@"; }
cleanup(){ for n in $JOBS; do jpost "$J/job/$n/doDelete" -o /dev/null >/dev/null 2>&1; done; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

jresult(){ jget "$J/job/$1/$2/api/json?tree=result,building" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("result") or ("BUILDING" if d.get("building") else ""))' 2>/dev/null || true; }
# ntrig <job> → « <GenericTrigger> <GitLabPushTrigger> <PipelineTriggersJobProperty> <DisableConcurrentBuilds> »
ntrig(){ jget "$J/job/$1/config.xml" | python3 -c '
import sys, xml.etree.ElementTree as T
r = T.fromstring(sys.stdin.read())
c = lambda s: sum(1 for e in r.iter() if e.tag.endswith(s))
print(c("GenericTrigger"), c("GitLabPushTrigger"), c("PipelineTriggersJobProperty"), c("DisableConcurrentBuildsJobProperty"))' 2>/dev/null || echo "? ? ? ?"; }
wait_build(){ # <job> <n> → résultat
  local n r i
  for i in $(seq 1 60); do r=$(jresult "$1" "$2"); [ -n "$r" ] && [ "$r" != BUILDING ] && { echo "$r"; return; }; sleep 2; done
  echo TIMEOUT
}
build_wait(){ jpost "$J/job/$1/build" -o /dev/null; wait_build "$1" "$2"; }
mkjob(){ # <nom> <bloc <properties…>> <token du properties() scripté>
  local n="$1" props="$2" tok="$3" hc g
  g="properties([disableConcurrentBuilds(), pipelineTriggers([GenericTrigger(token: '$tok', genericVariables: [[key: 'X', value: '\$.x']], printContributedVariables: false, printPostContent: false)])]); echo 'properties() posé'"
  python3 - "$n" "$props" "$g" > "$TMP/$n.xml" <<'PY'
import sys, xml.sax.saxutils as X
n, props, g = sys.argv[1:4]
print(f"""<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job"><description>spike {n} (jetable)</description><keepDependencies>false</keepDependencies>{props}
<definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps"><script>{X.escape(g)}</script><sandbox>true</sandbox></definition>
<disabled>false</disabled></flow-definition>""")
PY
  jpost "$J/job/$n/doDelete" -o /dev/null >/dev/null 2>&1
  hc=$(jpost "$J/createItem?name=$n" -H 'Content-Type: application/xml; charset=utf-8' --data-binary @"$TMP/$n.xml" -o /dev/null -w '%{http_code}')
  [ "$hc" = 200 ] || { say "!! createItem $n : HTTP $hc"; exit 1; }
}
# Déclenche par le GWT et dit ce que le plugin a répondu (quels jobs, quel code).
invoke(){ # <token> → « <code> <jobs> »
  local hc
  hc=$(curl -sg --max-time 30 -o "$TMP/inv.out" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"x":"1"}' "$J/generic-webhook-trigger/invoke?token=$1")
  printf '%s %s' "$hc" "$(python3 -c '
import sys,json
try: d=json.load(open(sys.argv[1]))
except Exception: print("(corps illisible)"); raise SystemExit
print(",".join((d.get("jobs") or {}).keys()) or "(aucun job)")' "$TMP/inv.out")"
}

RC=0
GWT_XML='<properties><org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty><triggers><org.jenkinsci.plugins.gwt.GenericTrigger plugin="generic-webhook-trigger"><spec></spec><genericVariables><org.jenkinsci.plugins.gwt.GenericVariable><key>X</key><value>$.x</value></org.jenkinsci.plugins.gwt.GenericVariable></genericVariables><printPostContent>false</printPostContent><printContributedVariables>false</printContributedVariables><token>spike-m2</token><silentResponse>false</silentResponse></org.jenkinsci.plugins.gwt.GenericTrigger></triggers></org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty></properties>'

say "═══ M2 : XML porteur du MÊME déclencheur + properties() scripté ═══"
mkjob spike-m2 "$GWT_XML" spike-m2
say "M2.0 à la pose (aucun build) : GenericTrigger=$(ntrig spike-m2 | cut -d' ' -f1) PipelineTriggersJobProperty=$(ntrig spike-m2 | cut -d' ' -f3)   (le XML seul)"
R1=$(build_wait spike-m2 1); N1=$(ntrig spike-m2)
case "$N1" in
  "2 0 2 1") say "M2.1 build #1 : $R1 ⇒ [$N1] = DOUBLON CONFIRMÉ (2 GenericTrigger, 2 PipelineTriggersJobProperty) — properties() AJOUTE sans dédoublonner" ;;
  "1 0 1 1") say "M2.1 build #1 : $R1 ⇒ [$N1] — PAS de doublon : le step a REMPLACÉ la propriété du XML dès le premier build (la spec §4.1 est à corriger sur ce point)"; RC=2 ;;
  *)         say "M2.1 build #1 : $R1 ⇒ [$N1] INATTENDU (GenericTrigger GitLabPushTrigger PipelineTriggers Disable)"; RC=1 ;;
esac
say "M2.2 invoke entre #1 et #2 : $(invoke spike-m2)   (un doublon ne déclenche qu'un build : allowSeveralTriggersPerBuild=false)"
R2=$(wait_build spike-m2 2); N2=$(ntrig spike-m2)
case "$N2" in
  "1 0 1 1") say "M2.3 build #2 : $R2 ⇒ [$N2] — les DEUX exemplaires retirés, celui du Jenkinsfile reposé : le déclencheur du XML est PERDU (jamais « préservé »)" ;;
  *)         say "M2.3 build #2 : $R2 ⇒ [$N2] INATTENDU"; RC=1 ;;
esac
say "    ⇒ un XML porteur n'est pas une ceinture : c'est un doublon, puis une perte. D'où le XML VIDE du lot L6."

say "═══ M4 : XML sans aucune propriété — la fenêtre d'amorçage ═══"
mkjob spike-m4 "<properties/>" spike-m4
say "M4.0 à la pose : [$(ntrig spike-m4)]   (attendu 0 0 0 0)"
IV=$(invoke spike-m4)
case "$IV" in
  404*) say "M4.1 invoke AVANT l'amorçage : $IV — le webhook est MUET (le token n'est porté par aucun job)" ;;
  *)    say "M4.1 invoke AVANT l'amorçage : $IV INATTENDU (attendu 404)"; RC=1 ;;
esac
HC=$(curl -sg --max-time 30 -o /dev/null -w '%{http_code}' -X POST -H 'X-Gitlab-Event: Merge Request Hook' -H 'Content-Type: application/json' \
  -d '{"object_kind":"merge_request","object_attributes":{"iid":1,"state":"opened","action":"open","source_branch":"provision/x-dev","target_branch":"main"}}' "$J/project/spike-m4")
NB=$(jget "$J/job/spike-m4/api/json?tree=nextBuildNumber" | python3 -c 'import sys,json;print(json.load(sys.stdin)["nextBuildNumber"])')
sleep 6
NB2=$(jget "$J/job/spike-m4/api/json?tree=nextBuildNumber" | python3 -c 'import sys,json;print(json.load(sys.stdin)["nextBuildNumber"])')
if [ "$HC" = 200 ] && [ "$NB" = "$NB2" ]; then say "M4.2 POST /project/spike-m4 sur un job sans GitLabPushTrigger : HTTP $HC et AUCUN build — 200 silencieux (le plugin ne dit pas qu'il n'a rien fait)"
else say "M4.2 POST /project/spike-m4 : HTTP $HC, builds $NB→$NB2 INATTENDU"; RC=1; fi
R=$(build_wait spike-m4 1); N=$(ntrig spike-m4)
case "$N" in
  "1 0 1 1") say "M4.3 amorçage #1 : $R ⇒ [$N] — UN déclencheur, UNE option, posés par le build" ;;
  *)         say "M4.3 amorçage #1 : $R ⇒ [$N] INATTENDU"; RC=1 ;;
esac
IV=$(invoke spike-m4)
case "$IV" in
  200*spike-m4*) say "M4.4 invoke APRÈS l'amorçage : $IV — le webhook est VIVANT" ;;
  *)             say "M4.4 invoke APRÈS l'amorçage : $IV INATTENDU (attendu 200 + spike-m4)"; RC=1 ;;
esac
say "    ⇒ toute pose de XML ouvre une fenêtre MUETTE jusqu'à la fin du premier build : le poseur doit l'attendre et la relire."

case "$RC" in
  0) say "RÉSULTAT M2+M4 : conformes à la spec §4.1" ;;
  2) say "RÉSULTAT M2+M4 : M2 diverge de la spec (pas de doublon) — la voie « XML vide » reste valide, la justification change" ;;
  *) say "RÉSULTAT M2+M4 : ÉCHEC — relire avant d'écrire le code" ;;
esac
exit "$RC"
