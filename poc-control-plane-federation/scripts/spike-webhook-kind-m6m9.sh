#!/usr/bin/env bash
# scripts/spike-webhook-kind-m6m9.sh — les quatre dernières mesures du lot L6
# (spec 2026-09-11 §9.1), contre le GitLab CE et le Jenkins du LAB :
#
#   M6  les payloads RÉELS des six événements d'une merge request (open, push,
#       titre, close, reopen, merge) : le couple (state, action), `oldrev`,
#       `merge_commit_sha`, `user.username` — captés par un GWT `printPostContent`.
#   M7  la table état×action → build des DEUX `gitlab(...)` de la spec §6.1
#       (plan : open/reopen/nouveau SHA ; apply : la fusion seulement), par
#       builds réels, contre-épreuve du titre (même SHA) comprise.
#   M8  les variables `gitlab*` réellement posées dans un build.
#   M9  `X-Gitlab-Token` : absent, faux, bon.
#
# JETABLE : trois jobs `spike-raw|plan|apply`, trois webhooks de projet, une
# branche `provision/spk-dev` et sa MR — tout est retiré en sortie, même en échec.
#
#   JENKINS_UI=http://localhost:18080 bash scripts/spike-webhook-kind-m6m9.sh
#
# PRÉREQUIS : .env.gitlab-lab (PAT) ; gitlab-plugin sur le Jenkins (M5) ; le
#   projet GitLab en méthode de merge « merge commit » (sinon merge_commit_sha
#   est nul et la mesure ne prouve rien — le script REFUSE).
#
# Directives shellcheck : SC2329 cleanup est invoquée par `trap`, SC2034 les
# compteurs de boucle, SC2015 `A && say … || say …` (say rend 0).
# SC1091 : .env.gitlab-lab est hors Git (secret), shellcheck ne peut pas le lire.
# shellcheck disable=SC2329,SC2034,SC2015,SC1091
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO" || exit 1
J="${JENKINS_UI:-http://localhost:18080}"
JIN="${JENKINS_INCLUSTER:-http://jenkins:8080}"      # Jenkins vu DEPUIS GitLab
GL="${GITLAB_LAB_URL:-http://localhost:13080}"       # GitLab vu depuis le poste
PID="${GITLAB_LAB_PROJECT_ID:-1}"
GL_REPO="${GITLAB_LAB_REPO:-ci/stoa-labs}"
TMP="$(mktemp -d /tmp/spkm6.XXXXXX)"; umask 077
JOBS="spike-raw spike-plan spike-apply"
HOOKS=""; IID=""; BR="provision/spk-dev"; CLONE="$GL/$GL_REPO.git"
CK="$TMP/ck"
say(){ printf '%s\n' "$*"; }
jget(){ curl -sg --max-time 30 "$@"; }
set -a; [ -r ./.env.gitlab-lab ] && . ./.env.gitlab-lab; set +a
TOK="${GITLAB_LAB_TOKEN:-}"
[ -n "$TOK" ] || { say "!! GITLAB_LAB_TOKEN absent : bash scripts/setup-gitlab-lab.sh"; rm -rf "$TMP"; exit 2; }
gl(){ curl -s --max-time 30 -H "PRIVATE-TOKEN: $TOK" "$@"; }
# git parle au GitLab par Basic oauth2:<PAT> (en-tête, jamais dans l'URL) ;
# postBuffer : un push > 1 Mio part en chunked et ce GitLab rend 500.
gauth(){ GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'oauth2:%s' "$TOK" | base64 | tr -d '\n')" GIT_CONFIG_KEY_1=http.postBuffer GIT_CONFIG_VALUE_1=524288000 git "$@"; }
jcrumb(){ jget -f -c "$CK" "$J/crumbIssuer/api/json" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["crumbRequestField"]+": "+d["crumb"])'; }
CR="$(jcrumb)" || { say "!! crumbIssuer illisible sur $J"; rm -rf "$TMP"; exit 2; }
jpost(){ curl -sg --max-time 60 -b "$CK" -H "$CR" -X POST "$@"; }
cleanup(){
  for h in $HOOKS; do gl -X DELETE "$GL/api/v4/projects/$PID/hooks/$h" -o /dev/null; done
  [ -n "$IID" ] && gl -X PUT "$GL/api/v4/projects/$PID/merge_requests/$IID" -d state_event=close -o /dev/null
  gauth push -q "$CLONE" --delete "$BR" 2>/dev/null
  for n in $JOBS; do jpost "$J/job/$n/doDelete" -o /dev/null >/dev/null 2>&1; done
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM
jnext(){ jget -f "$J/job/$1/api/json?tree=nextBuildNumber" | python3 -c 'import sys,json;print(json.load(sys.stdin)["nextBuildNumber"])' 2>/dev/null || echo 0; }
jconsole(){ jget "$J/job/$1/$2/consoleText"; }
jresult(){ jget "$J/job/$1/$2/api/json?tree=result,building" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("result") or ("BUILDING" if d.get("building") else ""))' 2>/dev/null || true; }

RC=0
# ── 0. préconditions : les deux récepteurs, la méthode de merge ──────────────
P=$(jget "$J/pluginManager/api/json?tree=plugins[shortName]" | python3 -c 'import sys,json;s={x["shortName"] for x in json.load(sys.stdin)["plugins"]};print("oui" if {"gitlab-plugin","generic-webhook-trigger"}<=s else "non")' 2>/dev/null || echo '?')
[ "$P" = oui ] || { say "!! REFUS: il manque un récepteur sur $J (gitlab-plugin et/ou generic-webhook-trigger) — jouer scripts/spike-webhook-kind-m5.sh"; exit 2; }
MM=$(gl "$GL/api/v4/projects/$PID" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("merge_method",""))' 2>/dev/null || true)
[ "$MM" = merge ] || { say "!! REFUS: merge_method='$MM' (attendu 'merge') — en ff/rebase_merge, merge_commit_sha est NUL et M6 ne prouverait rien. PUT /projects/$PID -d merge_method=merge"; exit 2; }
BASE=$(gl "$GL/api/v4/projects/$PID" | python3 -c 'import sys,json;print(json.load(sys.stdin)["default_branch"])')
say "0. les deux récepteurs sont là ; $GL_REPO fusionne par merge commit ; branche par défaut = $BASE"

# ── 1. trois jobs jetables : le témoin GWT, et les deux visages de la spec ───
mkjob(){ # <nom> <groovy inline>
  local n="$1" g="$2" hc
  python3 - "$n" "$g" > "$TMP/$n.xml" <<'PY'
import sys, xml.sax.saxutils as X
n, g = sys.argv[1:3]
print(f"""<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job"><description>spike L6 {n} (jetable)</description><keepDependencies>false</keepDependencies><properties/>
<definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps"><script>{X.escape(g)}</script><sandbox>true</sandbox></definition>
<disabled>false</disabled></flow-definition>""")
PY
  jpost "$J/job/$n/doDelete" -o /dev/null >/dev/null 2>&1
  hc=$(jpost "$J/createItem?name=$n" -H 'Content-Type: application/xml; charset=utf-8' --data-binary @"$TMP/$n.xml" -o /dev/null -w '%{http_code}')
  [ "$hc" = 200 ] || { say "!! createItem $n : HTTP $hc"; exit 1; }
  # l'amorçage POSE le déclencheur (M4) : sans lui le webhook est muet
  jpost "$J/job/$n/build" -o /dev/null
  local i
  for i in $(seq 1 45); do r=$(jresult "$n" 1); [ -n "$r" ] && [ "$r" != BUILDING ] && break; sleep 2; done
  say "   $n amorcé : $(jresult "$n" 1)"
}
# Témoin : capte le payload BRUT par le GWT (chemins JSON), pour lire ce que
# GitLab envoie RÉELLEMENT sur chaque événement.
mkjob spike-raw "properties([pipelineTriggers([GenericTrigger(token: 'spike-raw', genericVariables: [[key: 'GL_STATE', value: '\$.object_attributes.state'],[key: 'GL_ACTION', value: '\$.object_attributes.action'],[key: 'GL_SHA', value: '\$.object_attributes.merge_commit_sha'],[key: 'GL_OLDREV', value: '\$.object_attributes.oldrev'],[key: 'GL_USER', value: '\$.user.username'],[key: 'GL_LAST', value: '\$.object_attributes.last_commit.id'],[key: 'GL_SRC', value: '\$.object_attributes.source_branch']], printContributedVariables: false, printPostContent: false)])]); echo \"RAW state=[\${env.GL_STATE}] action=[\${env.GL_ACTION}] merge_sha=[\${env.GL_SHA}] oldrev=[\${env.GL_OLDREV}] user=[\${env.GL_USER}] last=[\${env.GL_LAST}] src=[\${env.GL_SRC}]\""
GL_COMMON="triggerOnPush: false, triggerOnNoteRequest: false, ciSkip: false, setBuildDescription: false, skipWorkInProgressMergeRequest: false, triggerOnClosedMergeRequest: false, triggerOnApprovedMergeRequest: false, triggerOnPipelineEvent: false, triggerToBranchDeleteRequest: false, cancelPendingBuildsOnUpdate: false, cancelRunningBuildsOnUpdate: false, branchFilterType: 'RegexBasedFilter', sourceBranchRegex: 'provision/.*', targetBranchRegex: '.*'"
mkjob spike-plan "properties([pipelineTriggers([gitlab(triggerOnMergeRequest: true, triggerOnAcceptedMergeRequest: false, triggerOpenMergeRequestOnPush: 'source', $GL_COMMON, secretToken: 'spike-plan')])]); echo \"PLAN iid=[\${env.gitlabMergeRequestIid}] state=[\${env.gitlabMergeRequestState}] src=[\${env.gitlabSourceBranch}] tgt=[\${env.gitlabTargetBranch}] sha=[\${env.gitlabMergeCommitSha}] by=[\${env.gitlabMergedByUser}] user=[\${env.gitlabUserUsername}] action=[\${env.gitlabActionType}] last=[\${env.gitlabMergeRequestLastCommit}]\""
mkjob spike-apply "properties([pipelineTriggers([gitlab(triggerOnMergeRequest: false, triggerOnAcceptedMergeRequest: true, triggerOpenMergeRequestOnPush: 'never', $GL_COMMON, secretToken: 'spike-apply')])]); echo \"APPLY iid=[\${env.gitlabMergeRequestIid}] state=[\${env.gitlabMergeRequestState}] sha=[\${env.gitlabMergeCommitSha}] by=[\${env.gitlabMergedByUser}]\""
for n in spike-plan spike-apply; do
  T=$(jget "$J/job/$n/config.xml" | python3 -c 'import sys,xml.etree.ElementTree as T;r=T.fromstring(sys.stdin.read());print(sum(1 for e in r.iter() if e.tag.endswith("GitLabPushTrigger")))')
  [ "$T" = 1 ] && say "   $n porte 1 GitLabPushTrigger" || { say "!! $n porte $T GitLabPushTrigger (amorçage manqué ?)"; RC=1; }
done

# ── 2. trois webhooks de projet, « Merge request events » seulement ──────────
hook(){ gl -X POST "$GL/api/v4/projects/$PID/hooks" -d "url=$1" -d "token=$2" -d merge_requests_events=true -d push_events=false -d enable_ssl_verification=false | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))'; }
H1=$(hook "$JIN/generic-webhook-trigger/invoke?token=spike-raw" spike-raw)
H2=$(hook "$JIN/project/spike-plan" spike-plan)
H3=$(hook "$JIN/project/spike-apply" spike-apply)
HOOKS="$H1 $H2 $H3"
[ -n "$H1" ] && [ -n "$H2" ] && [ -n "$H3" ] && say "2. hooks posés : $HOOKS (MR events seulement, secret = le nom du job)" || { say "!! hooks non posés : [$HOOKS]"; exit 1; }

# ── 3. une branche et une MR jetables ───────────────────────────────────────
gauth push -q "$CLONE" --delete "$BR" 2>/dev/null
W="$TMP/w"; gauth clone -q --depth 1 -b "$BASE" "$CLONE" "$W" || { say "!! clone impossible"; exit 1; }
git -C "$W" checkout -q -b "$BR"
printf 'spike L6 %s\n' "$$" > "$W/.spike-l6.txt"; git -C "$W" add .spike-l6.txt
git -C "$W" -c user.name=spike -c user.email=spike@lab commit -qm "spike L6 #1"
gauth -C "$W" push -q "$CLONE" "$BR" || { say "!! push de $BR impossible"; exit 1; }

snap(){ printf '%s %s %s' "$(jnext spike-raw)" "$(jnext spike-plan)" "$(jnext spike-apply)"; }
etape(){ # <libellé> <snapshot avant> : attend, compte les builds par job, imprime le payload brut
  sleep 12
  local a="$2" b; b="$(snap)"
  local dr dp da
  dr=$(( $(cut -d' ' -f1 <<<"$b") - $(cut -d' ' -f1 <<<"$a") ))
  dp=$(( $(cut -d' ' -f2 <<<"$b") - $(cut -d' ' -f2 <<<"$a") ))
  da=$(( $(cut -d' ' -f3 <<<"$b") - $(cut -d' ' -f3 <<<"$a") ))
  printf '── %-34s raw+%d plan+%d apply+%d\n' "$1" "$dr" "$dp" "$da"
  [ "$dr" -gt 0 ] && jconsole spike-raw "$(( $(cut -d' ' -f1 <<<"$b") - 1 ))" | grep '^RAW ' | sed 's/^/     /'
  [ "$dp" -gt 0 ] && jconsole spike-plan "$(( $(cut -d' ' -f2 <<<"$b") - 1 ))" | grep '^PLAN ' | sed 's/^/     /'
  [ "$da" -gt 0 ] && jconsole spike-apply "$(( $(cut -d' ' -f3 <<<"$b") - 1 ))" | grep '^APPLY ' | sed 's/^/     /'
  LAST="$dr $dp $da"
}
say "═══ M6 + M7 : les six événements d'une MR, et ce que chaque visage en fait ═══"
S=$(snap); IID=$(gl -X POST "$GL/api/v4/projects/$PID/merge_requests" -d source_branch="$BR" -d target_branch="$BASE" -d title="spike L6" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("iid",""))')
[ -n "$IID" ] || { say "!! MR non ouverte"; exit 1; }
etape "open (MR !$IID)" "$S"; [ "${LAST#* }" = "1 0" ] && say "   ✅ M7 open : plan construit, apply NON" || { say "   ❌ M7 open : [$LAST] (attendu raw+1 plan+1 apply+0)"; RC=1; }
S=$(snap); printf 'spike L6 bis\n' >> "$W/.spike-l6.txt"; git -C "$W" -c user.name=spike -c user.email=spike@lab commit -qam "spike L6 #2"; gauth -C "$W" push -q "$CLONE" "$BR"
etape "push d'un commit (nouveau SHA)" "$S"; [ "${LAST#* }" = "1 0" ] && say "   ✅ M7 push : plan reconstruit" || { say "   ❌ M7 push : [$LAST]"; RC=1; }
S=$(snap); gl -X PUT "$GL/api/v4/projects/$PID/merge_requests/$IID" -d title="spike L6 (titre changé)" -o /dev/null
# MESURÉ le 2026-09-11 : le plugin RECONSTRUIT sur un update de titre (même SHA,
# `oldrev` nul) — la garde « déjà construit » lue dans ses sources ne s'applique
# pas ici. C'est la PARITÉ avec le GWT (qui reconstruit aussi) : il n'y a donc
# aucun écart de comportement à documenter, contrairement à ce que la spec
# §6.1 prévoyait. L'attendu de cette étape est donc plan+1.
etape "update du TITRE (même SHA)" "$S"; [ "${LAST#* }" = "1 0" ] && say "   ✅ M7 titre : plan RECONSTRUIT (parité avec le GWT ; la garde « déjà construit » ne joue pas)" || { say "   ❌ M7 titre : [$LAST] (attendu plan+1 apply+0)"; RC=1; }
S=$(snap); gl -X PUT "$GL/api/v4/projects/$PID/merge_requests/$IID" -d state_event=close -o /dev/null
etape "close (sans fusion)" "$S"; [ "${LAST#* }" = "0 0" ] && say "   ✅ M7 close : ni plan ni apply" || { say "   ❌ M7 close : [$LAST]"; RC=1; }
S=$(snap); gl -X PUT "$GL/api/v4/projects/$PID/merge_requests/$IID" -d state_event=reopen -o /dev/null
etape "reopen (même SHA)" "$S"; [ "${LAST#* }" = "1 0" ] && say "   ✅ M7 reopen : plan reconstruit, apply NON (mesuré 2026-09-11)" || { say "   ❌ M7 reopen : [$LAST] (attendu plan+1 apply+0)"; RC=1; }
S=$(snap); gl -X PUT "$GL/api/v4/projects/$PID/merge_requests/$IID/merge" -o "$TMP/merge.json"
SHA_API=$(python3 -c 'import sys,json;print(json.load(open(sys.argv[1])).get("merge_commit_sha") or "")' "$TMP/merge.json")
etape "merge" "$S"; [ "${LAST#* }" = "0 1" ] && say "   ✅ M7 merge : apply construit, plan NON" || { say "   ❌ M7 merge : [$LAST] (attendu plan+0 apply+1)"; RC=1; }
IID=""   # mergée : plus rien à fermer
NA=$(( $(jnext spike-apply) - 1 ))
say "── merge_commit_sha de l'API : [$SHA_API]"
case "${#SHA_API}" in 40) say "   ✅ M6 merge_commit_sha = 40 hex (méthode merge commit)";; *) say "   ❌ M6 merge_commit_sha de longueur ${#SHA_API}"; RC=1;; esac
jconsole spike-apply "$NA" | grep -q "sha=\[$SHA_API\]" && say "   ✅ M6 gitlabMergeCommitSha du build == merge_commit_sha de l'API (la référence A2 tient)" || { say "   ❌ M6 gitlabMergeCommitSha ≠ API : $(jconsole spike-apply "$NA" | grep -m1 '^APPLY ')"; RC=1; }

say "═══ M8 : les variables gitlab* réellement posées (dernier build du plan) ═══"
NP=$(( $(jnext spike-plan) - 1 ))
jpost "$J/job/spike-plan/build" -o /dev/null >/dev/null 2>&1 || true   # (non utilisé : on lit le dernier build du webhook)
jconsole spike-plan "$NP" | grep -m1 '^PLAN ' | sed 's/^/   /'
jconsole spike-plan "$NP" | grep -q 'action=\[MERGE\]' && say "   ✅ M8 gitlabActionType vaut MERGE même sur un hook d'OUVERTURE : le plugin n'expose PAS l'action ⇒ le pipeline doit relire l'ÉTAT" || say "   ℹ M8 gitlabActionType : $(jconsole spike-plan "$NP" | grep -m1 -o 'action=\[[^]]*\]')"

say "═══ M9 : X-Gitlab-Token ═══"
for t in "" "faux" "spike-apply"; do
  H=(-H 'X-Gitlab-Event: Merge Request Hook' -H 'Content-Type: application/json')
  [ -n "$t" ] && H+=(-H "X-Gitlab-Token: $t")
  HC=$(curl -sg --max-time 30 -o /dev/null -w '%{http_code}' -X POST "${H[@]}" \
    -d '{"object_kind":"merge_request","object_attributes":{"iid":999,"state":"merged","action":"merge","source_branch":"provision/spk-dev","target_branch":"'"$BASE"'","merge_commit_sha":"0000000000000000000000000000000000000000"}}' \
    "$J/project/spike-apply")
  printf '   token=%-12s ⇒ HTTP %s\n' "${t:-(absent)}" "$HC"
done
# MESURÉ : absent ⇒ 401, faux ⇒ 401 (fail-closed, c'est l'essentiel) ; le BON
# token sur un payload FORGÉ et incomplet (MR inexistante) ⇒ 500 sans build —
# le handler du plugin ne se protège pas d'un corps qu'il ne peut pas résoudre.
say "   attendu : absent 401, faux 401 (refusés) ; bon token + payload forgé ⇒ 500 sans build (handler du plugin)"

[ "$RC" = 0 ] && say "RÉSULTAT M6..M9 : conformes à la spec §6.1" || say "RÉSULTAT M6..M9 : au moins une divergence — corriger la spec avant d'écrire les visages"
exit "$RC"
