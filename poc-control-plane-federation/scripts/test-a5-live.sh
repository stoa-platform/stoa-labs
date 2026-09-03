#!/usr/bin/env bash
# test-a5-live.sh — la PORTE et les CONTRE-ÉPREUVES d'A5 (GOAL cd-applications :
# l'ordre app/API — refus fermé si l'API n'est pas au palier), par BUILDS RÉELS
# sur le lab : Gitea + Jenkins + Vault + annuaire + la 10.15 réelle.
# Spec : docs/superpowers/specs/2026-09-03-a5-ordre-app-api-design.md (D6).
#
#   1. CONTRE-ÉPREUVE — demo-selfservice DÉSACTIVÉE (trap de réactivation) :
#      demande rec a5p<ts> (ci) mergée par alice ⇒ pause ⇒ alice ⇒ aval FAILURE
#      `REFUS: API_INACTIVE` — ticket < préflight < converge < REFUS, aucune tâche
#      d'écriture atteinte, aucun verify, application ABSENTE de la gateway, le
#      post{always} relaie tag + phrase, PR ❌ API_INACTIVE + « L'ordre app/API ».
#   2. PORTE — réactivation (le MÊME objet, même GUID) puis REJEU du même webhook
#      ⇒ pause ⇒ alice ⇒ SUCCESS ; converge « API_AT_PALIER … id=GUID_REF »,
#      verify API_AT_PALIER_CONFIRMED + SUBSCRIPTION_CONFIRMED (id=GUID_REF),
#      gateway : consumingAPIs ∋ GUID_REF, claim <app>-rec ; PR ✅.
#   3. API JAMAIS promue (nom a5nope<ts>) ⇒ `API_NOT_PROMOTED`, rien écrit, la PR
#      nomme promote/a5nope<ts>-rec.
#   4. version ABSENTE (demo-selfservice 9.9.9) ⇒ `API_VERSION_MISMATCH` citant
#      1.0.0, rien écrit, PR ❌.
#
# Sur ce lab MONO-GATEWAY, « promouvoir vers rec » n'est pas jouable (dev/rec/int
# = la même 10.15) : la porte est prouvée sur les trois situations que la gateway
# du palier peut présenter, et le « rejeu après promotion » est le rejeu après
# RÉACTIVATION du même objet — GUID identique relu (spec, hypothèse 6).
#
# ── FAIL-CLOSED, JAMAIS DE SKIP MUET ────────────────────────────────────────
# Prérequis manquant ⇒ exit 1 `LAB_ABSENT : …` ou `PREREQUIS : …`.
#
# ── CE QUE CE SCRIPT ÉCRIT DANS LE LAB, ET CE QU'IL REMET ────────────────────
# Lab PARTAGÉ : demo-selfservice DÉSACTIVÉE puis RÉACTIVÉE (trap inconditionnel,
# isActive relu) ; trois PR provision/* jetables MERGÉES (main reçoit et perd
# trois manifestes jetables) ; UNE application jetable sur la gateway réelle
# (supprimée) ; token ci jetable ; ne draine que SES pauses.
#
# Entrées (env) — OBLIGATOIRES, sans défaut vers un système en service :
#   JENKINS_UI GITEA_URL GW_ADMIN WM_USER WM_PASS
#   LAB_ALICE_PASS  (ou lu dans ./.env.lab-users s'il existe)
#   VAULT_TOKEN     (root de lab ; ou lu dans le conteneur poc-vault)
# Optionnelles : GITEA_TOKEN_FILE GITEA_CONTAINER GIT_REPO EXPECT_ADMIN_VIA
#   REQ_API REQ_API_VER VAULT_ADDR_LAB VAULT_CONTAINER
#
#   JENKINS_UI=http://localhost:18080 GITEA_URL=http://localhost:13000 \
#   GW_ADMIN=http://localhost:5555/rest/apigateway WM_USER=Administrator WM_PASS=manage \
#     bash scripts/test-a5-live.sh
# `A && ok || ko` (SC2015) est l'idiome des scripts de preuve du repo ; les
# accents graves des motifs grep sont ceux du markdown des commentaires de PR (SC2016).
# shellcheck disable=SC2015,SC2016
set -uo pipefail
set +x
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

if [ -z "${LAB_ALICE_PASS:-}" ] && [ -r ./.env.lab-users ]; then
  # shellcheck disable=SC1091
  set -a; . ./.env.lab-users; set +a
fi
JENKINS_UI="${JENKINS_UI:?JENKINS_UI requis (ex. http://localhost:18080)}"
GITEA_URL="${GITEA_URL:?GITEA_URL requis (ex. http://localhost:13000)}"
GW_ADMIN="${GW_ADMIN:?GW_ADMIN requis (ex. http://localhost:5555/rest/apigateway)}"
WM_USER="${WM_USER:?WM_USER requis}"
WM_PASS="${WM_PASS:?WM_PASS requis}"
LAB_ALICE_PASS="${LAB_ALICE_PASS:?LAB_ALICE_PASS requis (ou ./.env.lab-users)}"
VAULT_ADDR_LAB="${VAULT_ADDR_LAB:-http://localhost:8200}"
VAULT_CONTAINER="${VAULT_CONTAINER:-poc-vault}"
if [ -z "${VAULT_TOKEN:-}" ] && docker inspect "$VAULT_CONTAINER" >/dev/null 2>&1; then
  VAULT_TOKEN="$(docker exec "$VAULT_CONTAINER" printenv VAULT_DEV_ROOT_TOKEN_ID 2>/dev/null || true)"
fi
VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN requis (root de lab, ou conteneur $VAULT_CONTAINER)}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
GITEA_CONTAINER="${GITEA_CONTAINER:-poc-gitea}"
EXPECT_ADMIN_VIA="${EXPECT_ADMIN_VIA:-direct}"
REQ_API="${REQ_API:-demo-selfservice}"
REQ_API_VER="${REQ_API_VER:-1.0.0}"
TENANT="${A5_TENANT:-banking-demo}"
MAN_DIR="poc-control-plane-federation/clients/provisioned/applications"
SUBDIR="poc-control-plane-federation"

TS="$(date +%s)"
TMP="$(mktemp -d)"; umask 077
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
die(){ printf '\n%s\n' "$*" >&2; exit 1; }

APP1="a5p$TS"; APP3="a5n$TS"; APP4="a5v$TS"; NOPE="a5nope$TS"
CI_TOKEN=""
PRS=""               # numéros de PR ouverts par la suite (fermés en fin)
GUID_REF=""; DEACTIVATED=0   # DEACTIVATED posé à 1 AVANT la désactivation (le trap réactive sans condition alors)
API="$GITEA_URL/api/v1"
VHDR="$TMP/vhdr"; printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN" > "$VHDR"
vcurl(){ curl -s -m 20 -H @"$VHDR" "$@"; }

# ── helpers Gitea (token en EN-TÊTE via fichier, jamais en argv) ─────────────
gapi(){ curl -s -H @"$TMP/ci.hdr" -H 'Content-Type: application/json' "$@"; }
aapi(){ curl -s -H @"$TMP/alice.hdr" -H 'Content-Type: application/json' "$@"; }
jq_(){ python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
$1"; }
raw_at(){ gapi -o "$TMP/raw.out" -w '%{http_code}' "$API/repos/$GIT_REPO/raw/$1/$2" > "$TMP/raw.hc"; cat "$TMP/raw.out"; }
raw_hc(){ cat "$TMP/raw.hc" 2>/dev/null; }
pr_field(){ gapi "$API/repos/$GIT_REPO/pulls/$1" | jq_ "print(d$2)"; }
pr_comments(){ gapi "$API/repos/$GIT_REPO/issues/$1/comments" | jq_ "print('\n=====\n'.join(c.get('body','') for c in d))"; }
close_pr(){ gapi -X PATCH -d '{"state":"closed"}' -o /dev/null -w '%{http_code}' "$API/repos/$GIT_REPO/pulls/$1"; }
# ensure_human <login> <hdr-file> : compte Gitea humain + collaborateur write + token jetable
ensure_human(){
  local u="$1" hdr="$2" hc pw tok
  hc=$(gapi -o /dev/null -w '%{http_code}' "$API/users/$u")
  if [ "$hc" != 200 ]; then
    pw=$(python3 -c "import secrets,string;print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(24)))")
    docker exec -u git "$GITEA_CONTAINER" gitea admin user create --username "$u" --password "$pw" --email "$u@stoa.lab" --must-change-password=false >/dev/null 2>&1 || die "PREREQUIS : création du compte Gitea $u"
    unset pw
  fi
  hc=$(gapi -o /dev/null -w '%{http_code}' "$API/repos/$GIT_REPO/collaborators/$u")
  [ "$hc" = 204 ] || gapi -X PUT -d '{"permission":"write"}' -o /dev/null "$API/repos/$GIT_REPO/collaborators/$u"
  tok=$(docker exec -u git "$GITEA_CONTAINER" gitea admin user generate-access-token --username "$u" --token-name "a5-live-$u-$TS" --scopes write:repository,write:issue 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
  [ -n "$tok" ] || die "PREREQUIS : token Gitea de $u non minté"
  printf 'Authorization: token %s\n' "$tok" > "$hdr"; chmod 600 "$hdr"
}
# request_branch <app> <env> <api> <ver> <ip> → "<PR de ci> <branche>" (la demande de la CHAÎNE, sous ci, manifeste sans team)
# ⚠ appelé dans un $( ) : un `die` ici ne tue que le sous-shell — l'appelant re-vérifie.
request_branch(){
  local app="$1" e="$2" api="$3" ver="$4" ip="$5" out rc pr
  out=$(GITEA_TOKEN="$CI_TOKEN" GIT_HOST="$GITEA_URL" GIT_WEB_HOST="$GITEA_URL" GIT_REPO="$GIT_REPO" PROVISION_PLAN_INLINE=false \
        REQ_APP="$app" REQ_ENV="$e" REQ_API="$api" REQ_API_VER="$ver" REQ_CALLER=oig-provisioner \
        REQ_CLIENT_ID="${app}-${e}" REQ_IP_ALLOWLIST="$ip" bash scripts/provision-request.sh 2>&1); rc=$?
  pr=$(printf '%s' "$out" | grep -oE 'PR_URL=[^ ]*/pulls/[0-9]+' | grep -oE '[0-9]+$' | tail -1)
  [ "$rc" -eq 0 ] && [ -n "$pr" ] || die "PREREQUIS : demande $app/$e en échec (rc=$rc) : $(printf '%s' "$out" | tail -4 | tr '\n' ' ')"
  printf '%s provision/%s-%s' "$pr" "$app" "$e"
}
# merge_as_alice <pr> → MERGE_SHA
merge_as_alice(){
  local pr="$1" dl m hc
  dl=$(( $(date +%s) + 45 )); m=false
  while [ "$(date +%s)" -lt "$dl" ]; do m=$(pr_field "$pr" ".get('mergeable')"); [ "$m" = True ] && break; sleep 1; done
  [ "$m" = True ] || die "PREREQUIS : PR #$pr non mergeable"
  # Gitea répond 405 « Please try again later » tant que son contrôle de merge
  # n'est pas fini — `mergeable: true` ne le garantit pas (mesuré A4, passage 3) :
  # rejeu jusqu'à 12 fois, 5 s d'écart ; un 405 peut ÊTRE un merge effectué.
  local try=0
  while :; do
    hc=$(aapi -X POST -d '{"Do":"merge"}' -o "$TMP/merge.out" -w '%{http_code}' "$API/repos/$GIT_REPO/pulls/$pr/merge")
    [ "$hc" = 200 ] && break
    [ "$(pr_field "$pr" ".get('merged')")" = True ] && break
    try=$((try+1)); [ "$hc" = 405 ] && [ "$try" -lt 12 ] && { sleep 5; continue; }
    die "PREREQUIS : merge par alice refusé (HTTP $hc, essai $try) : $(head -c 200 "$TMP/merge.out")"
  done
  [ "$(pr_field "$pr" "['merged_by']['login']")" = alice ] || die "PREREQUIS : merged_by ≠ alice sur #$pr"
  pr_field "$pr" "['merge_commit_sha']"
}
# ── helpers Jenkins ──────────────────────────────────────────────────────────
jcrumb(){ curl -sf -c "$1" "$JENKINS_UI/crumbIssuer/api/json" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["crumbRequestField"]+": "+d["crumb"])'; }
jstatus(){ curl -s "$JENKINS_UI/job/$1/$2/wfapi/describe" | jq_ "print(d.get('status',''))" 2>/dev/null || true; }
jresult(){ curl -s "$JENKINS_UI/job/$1/$2/api/json?tree=result,building" | jq_ "print(d.get('result') or ('BUILDING' if d.get('building') else ''))" 2>/dev/null || true; }
jnext(){ curl -sf "$JENKINS_UI/job/$1/api/json?tree=nextBuildNumber" | jq_ "print(d['nextBuildNumber'])"; }
jconsole(){ curl -s "$JENKINS_UI/job/$1/$2/consoleText"; }
jinput_id(){ curl -s "$JENKINS_UI/job/$1/$2/wfapi/pendingInputActions" | jq_ "print(d[0]['id'] if d else '')" 2>/dev/null || true; }
wait_until(){ # <secondes> <job> <build> <état attendu | FINISHED>
  local deadline=$(( $(date +%s) + $1 )) st
  while [ "$(date +%s)" -lt "$deadline" ]; do
    st=$(jstatus "$2" "$3")
    case "$4:$st" in
      "FINISHED:SUCCESS"|"FINISHED:FAILED"|"FINISHED:ABORTED"|"FINISHED:UNSTABLE") printf '%s' "$st"; return 0 ;;
      "$4:$4") printf '%s' "$st"; return 0 ;;
      "PAUSED_PENDING_INPUT:SUCCESS"|"PAUSED_PENDING_INPUT:FAILED"|"PAUSED_PENDING_INPUT:ABORTED") printf '%s' "$st"; return 1 ;;
    esac
    sleep 3
  done
  printf '%s' "$(jstatus "$2" "$3")"; return 1
}
# answer_pause <build> : répond V_USER=alice / V_PASS (mot de passe par fichier, jamais argv)
answer_pause(){
  local n="$1" iid jar cr hc
  iid=$(jinput_id provision-apply "$n"); [ -n "$iid" ] || die "PREREQUIS : aucune pause sur provision-apply #$n"
  jar="$TMP/jar.in.$n"; cr=$(jcrumb "$jar") || die "LAB_ABSENT : crumb"
  LAB_ALICE_PASS="$LAB_ALICE_PASS" python3 - > "$TMP/input.json" <<'PY'
import json, os
print(json.dumps({"parameter": [{"name": "V_USER", "value": "alice"}, {"name": "V_PASS", "value": os.environ["LAB_ALICE_PASS"]}]}))
PY
  hc=$(curl -s -b "$jar" -H "$cr" -X POST --data-urlencode json@"$TMP/input.json" "$JENKINS_UI/job/provision-apply/$n/wfapi/inputSubmit?inputId=$iid" -o /dev/null -w '%{http_code}')
  rm -f "$TMP/input.json"
  [ "$hc" = 200 ] || [ "$hc" = 302 ] || die "PREREQUIS : réponse à la pause refusée (HTTP $hc)"
}
# wait_built <job> <build> : wfapi dit FINISHED AVANT que api/json ne dise
# building=false (post{} en cours : console partielle, commentaire pas encore
# posé — mesuré A4). On attend les deux.
wait_built(){ local dl=$(( $(date +%s) + 240 )) r; while [ "$(date +%s)" -lt "$dl" ]; do r=$(jresult "$1" "$2"); [ -n "$r" ] && [ "$r" != BUILDING ] && return 0; sleep 3; done; return 1; }
N_PA=""; S_NUM=""; RES=""; PR_N=""; BR_N=""; MS_N=""
wait_amont(){ # <N_PA> <PAUSE|NOPAUSE>
  local n="$1" st
  if [ "$2" = PAUSE ]; then
    st=$(wait_until 300 provision-apply "$n" PAUSED_PENDING_INPUT) || die "PREREQUIS : provision-apply #$n n'atteint pas la pause ($st) — $(jconsole provision-apply "$n" | grep -E 'REFUS|error' | tail -2 | tr '\n' ' ')"
  else
    st=$(wait_until 300 provision-apply "$n" FINISHED)
    wait_built provision-apply "$n" || echo "  (avertissement : #$n encore building après le FINISHED de wfapi)"
    sleep 3
    jconsole provision-apply "$n" > "$TMP/pa.$n.console"
  fi
}
# finish_amont <N_PA> : pose RES et S_NUM en GLOBALES — jamais dans un $( ).
finish_amont(){
  local n="$1"
  wait_until 1800 provision-apply "$n" FINISHED >/dev/null
  wait_built provision-apply "$n" || echo "  (avertissement : #$n encore building après le FINISHED de wfapi)"
  sleep 3
  jconsole provision-apply "$n" > "$TMP/pa.$n.console"
  S_NUM=$(grep -oE "aval selfservice-app-deploy #[0-9]+" "$TMP/pa.$n.console" | grep -oE '[0-9]+$' | head -1)
  [ -n "$S_NUM" ] && { wait_built selfservice-app-deploy "$S_NUM" || true; jconsole selfservice-app-deploy "$S_NUM" > "$TMP/ss.$S_NUM.console"; }
  RES=$(jresult provision-apply "$n")
}
console_order(){ # <fichier console> <motif1> <motif2> … → OK si chaque motif apparaît, dans l'ordre
  local f="$1" prev=0 l; shift
  for m in "$@"; do l=$(grep -n -F -- "$m" "$f" | head -1 | cut -d: -f1); [ -n "$l" ] && [ "$l" -gt "$prev" ] || return 1; prev=$l; done
  return 0
}
# fire_webhook <payload> → numéro de build (résolu depuis l'item de file GWT, jamais « le dernier build ») ; code HTTP dans $TMP/wh.hc
fire_webhook(){
  curl -s -X POST -H 'Content-Type: application/json' --data-binary @"$1" "$JENKINS_UI/generic-webhook-trigger/invoke?token=stoa-provision-apply" -o "$TMP/wh.out" -w '%{http_code}' > "$TMP/wh.hc"
  local qid n dl
  qid=$(jq_ "print((d.get('jobs') or {}).get('provision-apply', {}).get('id', ''))" < "$TMP/wh.out" 2>/dev/null || true)
  [ -n "$qid" ] || { echo ""; return; }
  dl=$(( $(date +%s) + 120 ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    n=$(curl -s "$JENKINS_UI/queue/item/$qid/api/json" | jq_ "print((d.get('executable') or {}).get('number', ''))" 2>/dev/null || true)
    [ -n "$n" ] && { echo "$n"; return; }
    sleep 2
  done
  echo ""
}
# replay_pr <pr> <branche> <merge_sha> → N_PA : le rejeu du webhook de fusion (le payload que Gitea envoie)
replay_pr(){
  python3 - "$2" "$1" "$3" > "$TMP/replay.json" <<'PY'
import json, sys
print(json.dumps({"action": "closed", "pull_request": {"head": {"ref": sys.argv[1]}, "number": int(sys.argv[2]), "merged": True,
  "merged_by": {"login": "alice"}, "user": {"login": "ci"}, "merge_commit_sha": sys.argv[3]}}))
PY
  N_PA=$(fire_webhook "$TMP/replay.json"); [ -n "$N_PA" ] || die "BUILD_EN_FILE : le rejeu du webhook n'a pas produit de build (HTTP $(cat "$TMP/wh.hc" 2>/dev/null))"
}
# chain_rec <app> <api> <ver> <ip> : demande rec sous ci → merge alice → pause → alice → fin ; pose PR_N BR_N MS_N N_PA RES S_NUM
chain_rec(){
  local app="$1" api="$2" ver="$3" ip="$4"
  read -r PR_N BR_N <<< "$(request_branch "$app" rec "$api" "$ver" "$ip")"
  [ -n "$PR_N" ] && [ -n "$BR_N" ] || die "PREREQUIS : demande $app/rec sans PR (voir ci-dessus)"
  PRS="$PRS $PR_N"
  N_PA=$(jnext provision-apply); MS_N=$(merge_as_alice "$PR_N")
  wait_amont "$N_PA" PAUSE; answer_pause "$N_PA"; finish_amont "$N_PA"
}
# ── helpers gateway (Basic via fichier -K, jamais en argv) ───────────────────
cfg(){ U="$2" P="$3" python3 -c 'import os,sys
e=lambda s: s.replace("\\","\\\\").replace("\"","\\\"")
fd=os.open(sys.argv[1], os.O_WRONLY|os.O_CREAT|os.O_TRUNC, 0o600)
with os.fdopen(fd,"w") as f: f.write("user = \"%s:%s\"\n" % (e(os.environ["U"]), e(os.environ["P"])))' "$1"; }
cfg "$TMP/wm.cfg" "$WM_USER" "$WM_PASS"
gw(){ curl -s -m 20 -K "$TMP/wm.cfg" -H 'Accept: application/json' -H 'Content-Type: application/json' "$@"; }
gw_app(){ # <nom> → JSON de l'application, ou vide ; attend le retour de la gateway (recyclage keepalive)
  local hc dl; dl=$(( $(date +%s) + 240 ))
  while :; do
    hc=$(gw -o "$TMP/gw.apps" -w '%{http_code}' "$GW_ADMIN/applications" || true)
    [ "$hc" = 200 ] && break
    [ "$(date +%s)" -lt "$dl" ] || die "LAB_GATEWAY_ILLISIBLE : GET $GW_ADMIN/applications -> HTTP $hc"
    sleep 10
  done
  N="$1" python3 -c "import json,os
for a in json.load(open('$TMP/gw.apps')).get('applications',[]):
    if a.get('name')==os.environ['N']: print(json.dumps(a)); break"; }
gw_app_claims(){ printf '%s' "$1" | python3 -c "import json,sys
a=json.load(sys.stdin)
for i in a.get('identifiers') or []:
    if i.get('key')=='openIdClaims': print(','.join(i.get('value') or [])); break" 2>/dev/null; }
api_id_of(){ # <nom> <version> → id, ou vide
  gw "$GW_ADMIN/apis" > "$TMP/gw.apis"; A="$1" V="$2" python3 -c "import json,os
d=json.load(open('$TMP/gw.apis'))
for i in d.get('apiResponse',[]):
    a=i.get('api',i)
    if a.get('apiName')==os.environ['A'] and a.get('apiVersion')==os.environ['V']: print(a.get('id')); break" 2>/dev/null; }
api_active(){ gw "$GW_ADMIN/apis/$1" | jq_ "print(d['apiResponse']['api'].get('isActive'))" 2>/dev/null; }
api_switch(){ # <id> <activate|deactivate> : attend la gateway (keepalive), puis RELIT isActive
  local dl=$(( $(date +%s) + 240 )) hc
  while :; do
    hc=$(gw -X PUT -o /dev/null -w '%{http_code}' "$GW_ADMIN/apis/$1/$2" || true)
    [ "$hc" = 200 ] && break
    [ "$(date +%s)" -lt "$dl" ] || return 1
    sleep 10
  done
  sleep 2
  case "$2:$(api_active "$1")" in activate:True|deactivate:False) return 0;; *) return 1;; esac
}
reactivate(){
  [ "$DEACTIVATED" -eq 1 ] || return 0
  if api_switch "$GUID_REF" activate; then DEACTIVATED=0; echo "  API $REQ_API réactivée (isActive=True relu)"
  else echo "  ⚠ API $REQ_API NON réactivée — PUT $GW_ADMIN/apis/$GUID_REF/activate à la main" >&2; fi
}
jabort_own_pauses(){ # abandonne les pauses provision-apply dont le nom porte l'une de NOS applications (jamais celles des autres)
  local jar="$TMP/jar.abort" cr n iid
  cr=$(jcrumb "$jar") || return 0
  for n in $(curl -s "$JENKINS_UI/job/provision-apply/api/json?tree=builds%5Bnumber,building,displayName%5D" | APPS="$APP1 $APP3 $APP4" python3 -c 'import json,os,sys
d=json.load(sys.stdin); apps=os.environ["APPS"].split()
print(" ".join(str(b["number"]) for b in d.get("builds",[]) if b.get("building") and any(a in (b.get("displayName") or "") for a in apps)))' 2>/dev/null); do
    iid=$(jinput_id provision-apply "$n"); [ -n "$iid" ] && curl -s -b "$jar" -H "$cr" -X POST "$JENKINS_UI/job/provision-apply/$n/input/$iid/abort" -o /dev/null && echo "  pause orpheline provision-apply #$n abandonnée"
  done
}
cleanup(){
  echo; echo "── nettoyage ──"
  reactivate
  jabort_own_pauses
  if [ -n "$CI_TOKEN" ]; then
    for n in $PRS; do close_pr "$n" >/dev/null 2>&1; done
    for a in "$APP1" "$APP3" "$APP4"; do
      gapi -X DELETE -o /dev/null "$API/repos/$GIT_REPO/branches/provision/${a}-rec" 2>/dev/null
      SHA_F=$(gapi "$API/repos/$GIT_REPO/contents/$MAN_DIR/${a}.ansible.yml?ref=main" | jq_ "print(d.get('sha',''))" 2>/dev/null || true)
      if [ -n "$SHA_F" ]; then
        gapi -X DELETE -d "{\"branch\":\"main\",\"sha\":\"$SHA_F\",\"message\":\"test(a5-live): retrait du manifeste jetable ${a} (porte A5 jouée)\"}" -o /dev/null "$API/repos/$GIT_REPO/contents/$MAN_DIR/${a}.ansible.yml" \
          && echo "  manifeste jetable ${a} retiré de main"
      fi
    done
  fi
  for a in "$APP1" "$APP3" "$APP4"; do
    APPJ=$(gw_app "$a" 2>/dev/null || true); ID=$(printf '%s' "$APPJ" | jq_ "print(d.get('id',''))" 2>/dev/null || true)
    if [ -n "$ID" ]; then
      HC=$(gw -X DELETE -o /dev/null -w '%{http_code}' "$GW_ADMIN/applications/$ID"); echo "  application jetable ${a} supprimée de la gateway (HTTP $HC, best-effort)"
    fi
  done
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

echo "═══ 0. Préconditions (fail-closed) ═══"
curl -sf -o /dev/null "$JENKINS_UI/api/json" || die "LAB_ABSENT : Jenkins injoignable ($JENKINS_UI)"
curl -sf -o /dev/null "$GITEA_URL/api/v1/version" || die "LAB_ABSENT : Gitea injoignable ($GITEA_URL)"
HC=$(gw -o /dev/null -w '%{http_code}' "$GW_ADMIN/applications"); [ "$HC" = 200 ] || die "LAB_ABSENT : gateway injoignable ou refus ($GW_ADMIN/applications -> $HC)"
[ "$(vcurl -o /dev/null -w '%{http_code}' "$VAULT_ADDR_LAB/v1/sys/policies/acl?list=true")" = 200 ] || die "LAB_ABSENT : le VAULT_TOKEN ne liste pas les policies (root de lab attendu)"
ok "0.1 Jenkins, Gitea, la gateway et Vault répondent"
if [ -n "${GITEA_TOKEN_FILE:-}" ] && [ -r "$GITEA_TOKEN_FILE" ]; then CI_TOKEN="$(cat "$GITEA_TOKEN_FILE")"
elif docker inspect "$GITEA_CONTAINER" >/dev/null 2>&1; then
  CI_TOKEN=$(docker exec -u git "$GITEA_CONTAINER" gitea admin user generate-access-token --username ci --token-name "a5-live-ci-$TS" --scopes write:repository,write:issue,write:user,read:user,write:admin 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
fi
[ -n "$CI_TOKEN" ] || die "LAB_ABSENT : aucun token Gitea ci"
printf 'Authorization: token %s\n' "$CI_TOKEN" > "$TMP/ci.hdr"
gapi -o /dev/null -w '%{http_code}' "$API/repos/$GIT_REPO" | grep -q '^200$' || die "LAB_ABSENT : $GIT_REPO illisible"
ok "0.2 token ci opérationnel"
curl -sf "$JENKINS_UI/job/provision-apply/config.xml" | grep -q 'ci/Jenkinsfile.provision-apply' || die "PREREQUIS : provision-apply n'est pas from SCM"
for f in scripts/provision-apply-gate.sh scripts/selfservice-palier-gate.sh ansible/roles/apim_common/tasks/refus.yml; do
  gapi -o /dev/null -w '%{http_code}' "$API/repos/$GIT_REPO/raw/main/$SUBDIR/$f" | grep -q '^200$' || die "PREREQUIS : $f absent de gitea main — git push gitea HEAD:main"
done
raw_at main "$SUBDIR/ansible/roles/apim_selfservice_app/tasks/main.yml" | grep -q 'API_INACTIVE' || die "PREREQUIS : le rôle sur gitea main n'a pas la porte A5"
raw_at main "$SUBDIR/ansible/roles/apim_selfservice_app/tasks/verify.yml" | grep -q 'SUBSCRIPTION_CONFIRMED' || die "PREREQUIS : verify sur gitea main n'a pas la relecture A5"
raw_at main "$SUBDIR/ci/Jenkinsfile.selfservice" | grep -q 'apim_ss_refus_detail_out' || die "PREREQUIS : Jenkinsfile.selfservice sur gitea main n'est pas la version A5"
raw_at main "$SUBDIR/ci/Jenkinsfile.provision-apply" | grep -q 'APPLIED_REFUSAL_DETAIL' || die "PREREQUIS : Jenkinsfile.provision-apply sur gitea main n'est pas la version A5"
raw_at main "$SUBDIR/scripts/selfservice-palier-gate.sh" | grep -q 'REFUS_DETAIL_OUT' || die "PREREQUIS : la garde A3 sur gitea main n'a pas REFUS_DETAIL_OUT"
ok "0.3 A5 est sur gitea main (rôle, verify, lib de refus, garde, deux Jenkinsfile)"
raw_at main "$SUBDIR/clients/_example/environments.yaml" > "$TMP/chain.yaml"; [ "$(raw_hc)" = 200 ] || die "PREREQUIS : environments.yaml illisible sur gitea main"
# shellcheck source=scripts/lib/env-chain.sh
. scripts/lib/env-chain.sh
( STOA_ENV_CHAIN_FILE="$TMP/chain.yaml" env_chain_validate ) 2>"$TMP/val.err" || die "PREREQUIS : la chaîne de gitea main est INVALIDE : $(cat "$TMP/val.err")"
[ "$(STOA_ENV_CHAIN_FILE="$TMP/chain.yaml" env_chain_gate_four_eyes rec)" = FOUREYES=0 ] || die "PREREQUIS : la porte rec exige les quatre yeux (les scénarios attendent selfApproval)"
[ -z "$(STOA_ENV_CHAIN_FILE="$TMP/chain.yaml" env_chain_gate_deployer_group rec)" ] || die "PREREQUIS : la porte rec déclare un deployerGroup"
ok "0.4 chaîne de gitea main valide : rec selfApproval, sans déclaration déployeur"
JAR="$TMP/jar.sc"; CR=$(jcrumb "$JAR") || die "LAB_ABSENT : crumb Jenkins"
gscript(){ curl -s -b "$JAR" -H "$CR" -X POST --data-urlencode "script=import jenkins.model.Jenkins; import hudson.slaves.EnvironmentVariablesNodeProperty; def p=Jenkins.instance.globalNodeProperties.get(EnvironmentVariablesNodeProperty); println(p==null ? \"\" : (p.envVars.get(\"$1\") ?: \"\"))" "$JENKINS_UI/scriptText" | tr -d '\r\n'; }
[ "$(gscript APPLY_ADMIN_VIA)" = "$EXPECT_ADMIN_VIA" ] && ok "0.5 APPLY_ADMIN_VIA global = $EXPECT_ADMIN_VIA" || die "PREREQUIS : APPLY_ADMIN_VIA global ≠ $EXPECT_ADMIN_VIA"
RUNNING=$(curl -s "$JENKINS_UI/job/provision-apply/api/json?tree=builds%5Bnumber,building%5D" | python3 -c 'import json,sys
d=json.load(sys.stdin); print(" ".join(str(b["number"]) for b in d.get("builds",[]) if b.get("building")))')
[ -z "$RUNNING" ] && ok "0.6 aucun build provision-apply en cours" || die "PREREQUIS : builds provision-apply en cours ($RUNNING)"
GUID_REF=$(api_id_of "$REQ_API" "$REQ_API_VER")
[ -n "$GUID_REF" ] && [ "$(api_active "$GUID_REF")" = True ] && ok "0.7 API $REQ_API@$REQ_API_VER active — GUID_REF=$GUID_REF" || die "PREREQUIS : $REQ_API@$REQ_API_VER absente/inactive"
[ -z "$(api_id_of "$NOPE" 1.0.0)" ] && ok "0.7b aucune API $NOPE (le nom absent du scénario 3)" || die "PREREQUIS : $NOPE existe"
[ -z "$(api_id_of "$REQ_API" 9.9.9)" ] && ok "0.7c aucune $REQ_API@9.9.9 (la version absente du scénario 4)" || die "PREREQUIS : $REQ_API@9.9.9 existe"
for a in "$APP1" "$APP3" "$APP4"; do [ -z "$(gw_app "$a")" ] || die "PREREQUIS : application $a déjà présente"; done; ok "0.8 aucune application homonyme"
ensure_human alice "$TMP/alice.hdr"; ok "0.9 alice : compte Gitea humain, collaboratrice write, token jetable"
P="$LAB_ALICE_PASS" python3 -c 'import json,os,sys;open(sys.argv[1],"w").write(json.dumps({"password":os.environ["P"]}))' "$TMP/alogin.json"; chmod 600 "$TMP/alogin.json"
ALT=$(curl -s -m 20 -X POST -H 'Content-Type: application/json' --data-binary @"$TMP/alogin.json" "$VAULT_ADDR_LAB/v1/auth/ldap/login/alice" | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["auth"]["client_token"])
except Exception: print("")')
rm -f "$TMP/alogin.json"
[ -n "$ALT" ] || die "PREREQUIS : login LDAP d'alice refusé (mot de passe de lab périmé ? lockout Vault ?)"
printf 'X-Vault-Token: %s\n' "$ALT" > "$TMP/ahdr"
APOL=$(curl -s -m 20 -H @"$TMP/ahdr" "$VAULT_ADDR_LAB/v1/auth/token/lookup-self" | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];print(" ".join(sorted(set((d.get("policies") or [])+(d.get("identity_policies") or [])))))')
curl -s -m 20 -H @"$TMP/ahdr" -X POST "$VAULT_ADDR_LAB/v1/auth/token/revoke-self" -o /dev/null; rm -f "$TMP/ahdr"
case " $APOL " in *" deploy-$TENANT "*" apply-rec "*|*" apply-rec "*" deploy-$TENANT "*) ;; *) die "PREREQUIS : le token LDAP d'alice ne porte pas deploy-$TENANT + apply-rec ($APOL)";; esac
ok "0.10 alice (LDAP) : $APOL"
N_INACTIVE=$(python3 -c "import json
d=json.load(open('$TMP/gw.apis')); print(sum(1 for i in d.get('apiResponse',[]) if i.get('api',i).get('isActive') is False))" 2>/dev/null || echo '?')
echo "  (mesure : $N_INACTIVE API(s) inactive(s) sur la gateway au départ ; gateway démarrée $(docker inspect poc-webmethods-real --format '{{.State.StartedAt}}' 2>/dev/null || echo '?'))"

echo
echo "═══ 1. CONTRE-ÉPREUVE — API présente mais INACTIVE en rec ⇒ API_INACTIVE, rien écrit ═══"
DEACTIVATED=1
api_switch "$GUID_REF" deactivate && ok "1.0 $REQ_API désactivée (isActive=False relu) — trap de réactivation armé" || die "PREREQUIS : désactivation de $REQ_API refusée"
chain_rec "$APP1" "$REQ_API" "$REQ_API_VER" 10.42.0.1; PR1="$PR_N"; BR1="$BR_N"; MS1="$MS_N"
[ "$RES" = FAILURE ] && ok "1.1 provision-apply #$N_PA : FAILURE (l'aval a refusé)" || ko "1.1 provision-apply #$N_PA : $RES"
[ -n "$S_NUM" ] && grep -qF 'REFUS: API_INACTIVE' "$TMP/ss.$S_NUM.console" && grep -q "isActive=False" "$TMP/ss.$S_NUM.console" && grep -q "id=$GUID_REF" "$TMP/ss.$S_NUM.console" \
  && ok "1.2 aval #$S_NUM : REFUS: API_INACTIVE (isActive=False, id=$GUID_REF cité)" || ko "1.2 aval ${S_NUM:-?} : $(grep -E 'REFUS|fatal' "$TMP/ss.${S_NUM:-0}.console" 2>/dev/null | head -2 | tr '\n' ' ' | cut -c1-300)"
console_order "$TMP/ss.$S_NUM.console" 'palier ouvert : envs/rec/wm-admin' 'préflight de joignabilité :' 'PLAY [Self-service application — converge' 'REFUS: API_INACTIVE' \
  && ok "1.3 ORDRE aval : ticket < préflight < converge < REFUS (la porte est DANS le rôle, après le credential du palier)" || ko "1.3 ordre aval inattendu"
! grep -q 'App : créer si absente' "$TMP/ss.$S_NUM.console" && ! grep -q 'PLAY \[Self-service application — verify' "$TMP/ss.$S_NUM.console" \
  && ok "1.4 aucune tâche d'écriture atteinte, aucun verify" || ko "1.4 le rôle est allé plus loin que la porte"
[ -z "$(gw_app "$APP1")" ] && ok "1.5 gateway : $APP1 ABSENTE — rien écrit" || ko "1.5 gateway : $APP1 existe"
grep -qF "relayé à l'amont : API_INACTIVE — " "$TMP/ss.$S_NUM.console" && ok "1.6 post{always} de l'aval : tag ET phrase relayés" || ko "1.6 relais : $(grep -F 'relayé' "$TMP/ss.$S_NUM.console" | head -1 | cut -c1-200)"
grep -q "verdict amont : FAILURE (API_INACTIVE)" "$TMP/pa.$N_PA.console" && ok "1.6b amont : verdict FAILURE (API_INACTIVE) — le tag a traversé buildVariables" || ko "1.6b amont : $(grep 'verdict amont' "$TMP/pa.$N_PA.console" | head -1 | cut -c1-200)"
CM=$(pr_comments "$PR1")
printf '%s' "$CM" | grep -q 'API_INACTIVE' && printf '%s' "$CM" | grep -q "$REQ_API" && printf '%s' "$CM" | grep -q "L'ordre app/API" && printf '%s' "$CM" | grep -q "aval selfservice-app-deploy #$S_NUM" \
  && ok "1.7 PR #$PR1 : ❌ API_INACTIVE, la phrase nomme $REQ_API, paragraphe « L'ordre app/API », aval #$S_NUM cité" || ko "1.7 commentaire : $(printf '%s' "$CM" | grep -i 'refus' | head -2 | tr '\n' ' ' | cut -c1-300)"

echo
echo "═══ 2. PORTE — « promotion » (réactivation, même GUID) puis REJEU du même webhook ⇒ créée, souscrite au MÊME GUID ═══"
api_switch "$GUID_REF" activate && DEACTIVATED=0 && ok "2.0 $REQ_API réactivée (isActive=True relu) — même objet, même GUID $GUID_REF" || die "PREREQUIS : réactivation de $REQ_API refusée"
replay_pr "$PR1" "$BR1" "$MS1"
wait_amont "$N_PA" PAUSE; answer_pause "$N_PA"; finish_amont "$N_PA"
[ "$RES" = SUCCESS ] && [ -n "$S_NUM" ] && [ "$(jresult selfservice-app-deploy "$S_NUM")" = SUCCESS ] && ok "2.1 rejeu : provision-apply #$N_PA SUCCESS, aval #$S_NUM SUCCESS" || ko "2.1 amont $RES / aval ${S_NUM:-?} $(jresult selfservice-app-deploy "${S_NUM:-0}") — $(grep -E 'REFUS|SHA_NON|fatal' "$TMP/pa.$N_PA.console" "$TMP/ss.${S_NUM:-0}.console" 2>/dev/null | head -2 | tr '\n' ' ' | cut -c1-300)"
grep -q "API_AT_PALIER : '$REQ_API' v$REQ_API_VER active au palier 'rec' (id=$GUID_REF)" "$TMP/ss.$S_NUM.console" && ok "2.2 converge : API_AT_PALIER avec GUID_REF" || ko "2.2 marqueur API_AT_PALIER absent"
grep -q "API_AT_PALIER_CONFIRMED" "$TMP/ss.$S_NUM.console" && grep -q "SUBSCRIPTION_CONFIRMED.*id=$GUID_REF" "$TMP/ss.$S_NUM.console" \
  && ok "2.3 verify : API_AT_PALIER_CONFIRMED + SUBSCRIPTION_CONFIRMED au GUID $GUID_REF" || ko "2.3 verify : $(grep -E 'CONFIRMED|REFUS' "$TMP/ss.$S_NUM.console" | tr '\n' ' ' | cut -c1-300)"
APPJ=$(gw_app "$APP1")
printf '%s' "$APPJ" | grep -q "$GUID_REF" && [ "$(gw_app_claims "$APPJ")" = "${APP1}-rec" ] \
  && ok "2.4 gateway : $APP1 présente, consumingAPIs ∋ $GUID_REF (le GUID promu, le même), claim ${APP1}-rec" || ko "2.4 gateway : $(printf '%s' "$APPJ" | cut -c1-200)"
CM=$(pr_comments "$PR1"); printf '%s' "$CM" | grep -q 'Apply nominatif RÉUSSI' && ok "2.5 PR #$PR1 : ✅ (le rejeu a remplacé le refus)" || ko "2.5 commentaire : $(printf '%s' "$CM" | tail -c 200)"

echo
echo "═══ 3. API JAMAIS promue (nom absent) ⇒ API_NOT_PROMOTED, la PR nomme promote/<api>-rec ═══"
chain_rec "$APP3" "$NOPE" 1.0.0 10.42.0.3; PR3="$PR_N"
[ "$RES" = FAILURE ] && [ -n "$S_NUM" ] && grep -qF 'REFUS: API_NOT_PROMOTED' "$TMP/ss.$S_NUM.console" && ok "3.1 aval #$S_NUM : REFUS: API_NOT_PROMOTED" || ko "3.1 $RES : $(grep -E 'REFUS|fatal' "$TMP/ss.${S_NUM:-0}.console" 2>/dev/null | head -2 | tr '\n' ' ' | cut -c1-300)"
[ -z "$(gw_app "$APP3")" ] && ok "3.2 gateway : $APP3 absente — rien écrit" || ko "3.2 $APP3 existe"
CM=$(pr_comments "$PR3"); printf '%s' "$CM" | grep -q 'API_NOT_PROMOTED' && printf '%s' "$CM" | grep -q "promote/$NOPE-rec" && ok "3.3 PR #$PR3 : ❌ API_NOT_PROMOTED nommant promote/$NOPE-rec" || ko "3.3 : $(printf '%s' "$CM" | grep -i refus | head -1 | cut -c1-300)"

echo
echo "═══ 4. version ABSENTE ($REQ_API 9.9.9) ⇒ API_VERSION_MISMATCH citant $REQ_API_VER ═══"
chain_rec "$APP4" "$REQ_API" 9.9.9 10.42.0.4; PR4="$PR_N"
[ "$RES" = FAILURE ] && [ -n "$S_NUM" ] && grep -qF 'REFUS: API_VERSION_MISMATCH' "$TMP/ss.$S_NUM.console" && grep -q "version(s) .*$REQ_API_VER" "$TMP/ss.$S_NUM.console" \
  && ok "4.1 aval #$S_NUM : REFUS: API_VERSION_MISMATCH citant $REQ_API_VER" || ko "4.1 $RES : $(grep -E 'REFUS|fatal' "$TMP/ss.${S_NUM:-0}.console" 2>/dev/null | head -2 | tr '\n' ' ' | cut -c1-300)"
[ -z "$(gw_app "$APP4")" ] && ok "4.2 gateway : $APP4 absente — rien écrit" || ko "4.2 $APP4 existe"
CM=$(pr_comments "$PR4"); printf '%s' "$CM" | grep -q 'API_VERSION_MISMATCH' && ok "4.3 PR #$PR4 : ❌ API_VERSION_MISMATCH" || ko "4.3 : $(printf '%s' "$CM" | tail -c 200)"

echo
echo "═══════════════════════════════════════════════════"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
