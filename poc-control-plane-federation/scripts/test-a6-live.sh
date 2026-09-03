#!/usr/bin/env bash
# test-a6-live.sh — la PORTE et les CONTRE-ÉPREUVES d'A6 (GOAL cd-applications :
# le repli d'une application est une PR), par BUILDS RÉELS sur le lab :
# Gitea + Jenkins + Vault + annuaire + la 10.15 réelle.
# Spec : docs/superpowers/specs/2026-09-03-a6-repli-par-pr-design.md (D5).
#   1. État N-1 : demande rec IP 10.42.0.1 + cert C1 ⇒ SUCCESS ; GUID/clé/identifiers lus sur l'OBJET.
#   2. AUCUN_ETAT_PRECEDENT par build app-rollback : rien poussé, aucune PR.
#   3. État N : IP 10.42.0.2 + C2 ⇒ SUCCESS ; même GUID, même clé, identifiers ≠ (anti-vacant).
#   4. LA PORTE : app-rollback ⇒ PR de repli (marqueur, #N, #N-1, digest recalculé par la lib,
#      trailers) → merge alice → REPLI_OK/PORTE_OK/pause/PORTE_OK → aval SUCCESS ;
#      gateway PAR LECTURE : même GUID, même clé, identifiers == état N-1, IP .1, cert C1 ;
#      Git : main == ligne de #N-1 ; PR : ✅ + digest == celui annoncé.
#   5. Le repli du repli restaure N (REPLI_DU_REPLI nommé).
#   6. Contre-épreuve A5 en repli : API désactivée ⇒ aval FAILURE API_INACTIVE, rien écrit ;
#      réactivation + REJEU du webhook de la PR de repli ⇒ SUCCESS (motif A2).
#      (Proxy mono-gateway, comme A5 : API_NOT_PROMOTED est prouvé par A5 #80 sur la même porte.)
#   7. Terminus : sans change_ref ⇒ GATE_REFS_REQUIRED avant tout clone ; avec ⇒ PALIER_ABSENT
#      après le clone (la paire prouve l'ordre, motif G6).
#
# ── FAIL-CLOSED, JAMAIS DE SKIP MUET ────────────────────────────────────────
# Prérequis manquant ⇒ exit 1 `LAB_ABSENT : …` ou `PREREQUIS : …`.
# ── CE QUE CE SCRIPT ÉCRIT DANS LE LAB, ET CE QU'IL REMET ────────────────────
# Lab PARTAGÉ : demo-selfservice DÉSACTIVÉE puis RÉACTIVÉE (trap) ; cinq PR
# provision/* jetables MERGÉES (main reçoit et perd un manifeste et un cert
# jetables) ; UNE application jetable sur la gateway réelle (supprimée) ;
# token ci jetable ; ne draine que SES pauses.
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
#     bash scripts/test-a6-live.sh
# `A && ok || ko` (SC2015) est l'idiome des scripts de preuve du repo ; les
# accents graves des motifs grep sont ceux du markdown des commentaires de PR (SC2016).
# shellcheck disable=SC2015,SC2016,SC2034
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
  tok=$(docker exec -u git "$GITEA_CONTAINER" gitea admin user generate-access-token --username "$u" --token-name "a6-live-$u-$TS" --scopes write:repository,write:issue 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
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

# ══════════════════════════════════════════════════════════════════════════════
# A6 — helpers propres à cette suite
# ══════════════════════════════════════════════════════════════════════════════
# shellcheck source=scripts/lib/app-manifest.sh
. "$REPO/scripts/lib/app-manifest.sh" || die "LIB_ABSENTE : scripts/lib/app-manifest.sh"
# shellcheck source=scripts/lib/env-chain.sh
. "$REPO/scripts/lib/env-chain.sh" || die "LIB_ABSENTE : scripts/lib/env-chain.sh"
CERT_DIR="$SUBDIR/clients/provisioned/certs"
APP="a6p$TS"; APP1="$APP"; APP3=""; APP4=""
# request_branch_cert <app> <env> <api> <ver> <ip> <fichier PEM> → "<PR de ci> <branche>" (demande + cert du palier)
request_branch_cert(){
  local app="$1" e="$2" api="$3" ver="$4" ip="$5" pem="$6" out rc pr
  out=$(GITEA_TOKEN="$CI_TOKEN" GIT_HOST="$GITEA_URL" GIT_WEB_HOST="$GITEA_URL" GIT_REPO="$GIT_REPO" PROVISION_PLAN_INLINE=false \
        REQ_APP="$app" REQ_ENV="$e" REQ_API="$api" REQ_API_VER="$ver" REQ_CALLER=oig-provisioner \
        REQ_CLIENT_ID="${app}-${e}" REQ_IP_ALLOWLIST="$ip" REQ_CERT_PEM="$(cat "$pem")" bash scripts/provision-request.sh 2>&1); rc=$?
  pr=$(printf '%s' "$out" | grep -oE 'PR_URL=[^ ]*/pulls/[0-9]+' | grep -oE '[0-9]+$' | tail -1)
  [ "$rc" -eq 0 ] && [ -n "$pr" ] || die "PREREQUIS : demande $app/$e en échec (rc=$rc) : $(printf '%s' "$out" | tail -4 | tr '\n' ' ')"
  printf '%s provision/%s-%s' "$pr" "$app" "$e"
}
# chain_rec_cert <ip> <pem> : demande rec (ci) avec cert → merge alice → pause → alice → fin ; pose PR_N BR_N MS_N N_PA RES S_NUM
chain_rec_cert(){
  read -r PR_N BR_N <<< "$(request_branch_cert "$APP" rec "$REQ_API" "$REQ_API_VER" "$1" "$2")"
  [ -n "$PR_N" ] && [ -n "$BR_N" ] || die "PREREQUIS : demande $APP/rec sans PR (voir ci-dessus)"
  PRS="$PRS $PR_N"
  N_PA=$(jnext provision-apply); MS_N=$(merge_as_alice "$PR_N")
  wait_amont "$N_PA" PAUSE; answer_pause "$N_PA"; finish_amont "$N_PA"
}
# merge_pause_apply <pr> : merge alice → pause → alice → fin (pour une PR déjà ouverte : la PR de repli) ; pose MS_N N_PA RES S_NUM
merge_pause_apply(){
  N_PA=$(jnext provision-apply); MS_N=$(merge_as_alice "$1")
  wait_amont "$N_PA" PAUSE; answer_pause "$N_PA"; finish_amont "$N_PA"
}
# ── lectures gateway par l'OBJET (jamais la liste), clé jamais imprimée ──────
gw_app_id(){ gw_app "$1" | jq_ "print(d.get('id',''))" 2>/dev/null; }
gw_app_obj(){ # <id> → GUID= KEY= IDS= SUBS= SUSP=
  gw "$GW_ADMIN/applications/$1" | python3 -c '
import json,sys,hashlib
d=json.load(sys.stdin); a=(d.get("applications") or [d])[0]
key=((a.get("accessTokens") or {}).get("apiAccessKey_credentials") or {}).get("apiAccessKey") or ""
ids=sorted((i.get("key",""), i.get("name",""), sorted(i.get("value") or [])) for i in (a.get("identifiers") or []) if i.get("key") in ("httpsCertificate","ipAddressRange","openIdClaims","token"))
print("GUID=%s" % a.get("id")); print("KEY=%s" % hashlib.sha256(key.encode()).hexdigest())
print("IDS=%s" % hashlib.sha256(json.dumps(ids, sort_keys=True).encode()).hexdigest())
print("SUBS=%s" % ",".join(sorted(a.get("consumingAPIs") or []))); print("SUSP=%s" % a.get("isSuspended"))'; }
obj_field(){ printf '%s\n' "$1" | sed -n "s/^$2=//p"; }
gw_app_ip_of(){ gw "$GW_ADMIN/applications/$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); a=(d.get("applications") or [d])[0]; print(",".join(sorted(next((i.get("value") or []) for i in a.get("identifiers",[]) if i.get("key")=="ipAddressRange"))))' 2>/dev/null; }
gw_app_cert_of(){ gw "$GW_ADMIN/applications/$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); a=(d.get("applications") or [d])[0]; i=next((i for i in a.get("identifiers",[]) if i.get("key")=="httpsCertificate"),{}); print(i.get("name",""), ",".join(sorted(i.get("value") or [])))' 2>/dev/null; }
der_of(){ awk '/BEGIN CERT/{f=1;next}/END CERT/{f=0}f' "$1" | tr -d '\n'; }
# ── le build paramétré du job app-rollback (jbuild/form_file d'A4) ───────────
jbuild(){ # <job> <fichier de formulaire urlencodé> → numéro de build (résolu depuis l'item de file)
  local jar="$TMP/jar.b.$RANDOM" cr qid n dl
  cr=$(jcrumb "$jar") || { echo ""; return; }
  curl -s -b "$jar" -H "$cr" -X POST -D "$TMP/b.hdr" -o /dev/null --data-binary @"$2" -H 'Content-Type: application/x-www-form-urlencoded' "$JENKINS_UI/job/$1/buildWithParameters"
  qid=$(grep -i '^Location:' "$TMP/b.hdr" | grep -oE 'queue/item/[0-9]+' | grep -oE '[0-9]+$' | head -1)
  [ -n "$qid" ] || { echo ""; return; }
  dl=$(( $(date +%s) + 180 ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    n=$(curl -s "$JENKINS_UI/queue/item/$qid/api/json" | jq_ "print((d.get('executable') or {}).get('number', ''))" 2>/dev/null || true)
    [ -n "$n" ] && { echo "$n"; return; }
    sleep 2
  done
  echo ""
}
form_file_any(){ # <fichier> puis paires clé=valeur sur STDIN → urlencodé (urlencode EXIGE des tuples — piège A3)
  python3 -c 'import os,sys,urllib.parse
pairs=[tuple(l.split("=",1)) for l in sys.stdin.read().splitlines() if "=" in l]
fd=os.open(sys.argv[1], os.O_WRONLY|os.O_CREAT|os.O_TRUNC, 0o600)
with os.fdopen(fd,"w") as f: f.write(urllib.parse.urlencode(pairs))' "$1"
  [ -s "$1" ] || die "HARNAIS : formulaire de build non écrit ($1)"
}
RB_NUM=""; RB_RES=""; RB_PR=""
rollback_build(){ # <app> <env> <motif> [change_ref] : pose RB_NUM RB_RES RB_PR (et la console dans $TMP/rb.<n>.console)
  printf 'APP=%s\nENV=%s\nREASON=%s\nCHANGE_REF=%s\n' "$1" "$2" "$3" "${4:-}" | form_file_any "$TMP/rb.form"
  RB_NUM=$(jbuild app-rollback "$TMP/rb.form"); [ -n "$RB_NUM" ] || die "BUILD_EN_FILE : app-rollback n'a pas produit de build"
  wait_until 600 app-rollback "$RB_NUM" FINISHED >/dev/null; wait_built app-rollback "$RB_NUM" || true; sleep 2
  jconsole app-rollback "$RB_NUM" > "$TMP/rb.$RB_NUM.console"
  RB_RES=$(jresult app-rollback "$RB_NUM")
  RB_PR=$(grep -oE '^PR_URL=.*/pulls/[0-9]+' "$TMP/rb.$RB_NUM.console" | grep -oE '[0-9]+$' | head -1)
  [ -n "$RB_PR" ] && PRS="$PRS $RB_PR"
}
rec_line_at(){ raw_at "$1" "$MAN_DIR/$APP.ansible.yml" | grep -E '^    rec: '; }
digest_at(){ raw_at "$1" "$MAN_DIR/$APP.ansible.yml" > "$TMP/dg.$$.yml"; app_manifest_digest_env "$TMP/dg.$$.yml" rec 2>/dev/null; }
branch_sha(){ gapi "$API/repos/$GIT_REPO/branches/provision/$APP-rec" | jq_ "print((d.get('commit') or {}).get('id',''))" 2>/dev/null; }
prs_on_branch(){ gapi "$API/repos/$GIT_REPO/pulls?state=all&limit=50" | B="provision/$APP-rec" jq_ "import os
print(sum(1 for p in d if (p.get('head') or {}).get('ref')==os.environ['B']))" 2>/dev/null; }

cleanup(){
  echo; echo "── nettoyage ──"
  reactivate
  jabort_own_pauses
  if [ -n "$CI_TOKEN" ]; then
    for n in $PRS; do close_pr "$n" >/dev/null 2>&1; done
    gapi -X DELETE -o /dev/null "$API/repos/$GIT_REPO/branches/provision/${APP}-rec" 2>/dev/null
    for f in "$MAN_DIR/${APP}.ansible.yml" "$CERT_DIR/${APP}-rec.crt"; do
      SHA_F=$(gapi "$API/repos/$GIT_REPO/contents/$f?ref=main" | jq_ "print(d.get('sha',''))" 2>/dev/null || true)
      if [ -n "$SHA_F" ]; then
        gapi -X DELETE -d "{\"branch\":\"main\",\"sha\":\"$SHA_F\",\"message\":\"test(a6-live): retrait de ${f##*/} (porte A6 jouée)\"}" -o /dev/null "$API/repos/$GIT_REPO/contents/$f" \
          && echo "  ${f##*/} retiré de main"
      fi
    done
  fi
  ID=$(gw_app_id "$APP" 2>/dev/null || true)
  if [ -n "$ID" ]; then HC=$(gw -X DELETE -o /dev/null -w '%{http_code}' "$GW_ADMIN/applications/$ID"); echo "  application jetable ${APP} supprimée de la gateway (HTTP $HC, best-effort)"; fi
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

echo "═══ 0. Préconditions (fail-closed) ═══"
curl -sf -o /dev/null "$JENKINS_UI/api/json" || die "LAB_ABSENT : Jenkins injoignable ($JENKINS_UI)"
curl -sf -o /dev/null "$GITEA_URL/api/v1/version" || die "LAB_ABSENT : Gitea injoignable ($GITEA_URL)"
HC=$(gw -o /dev/null -w '%{http_code}' "$GW_ADMIN/applications"); [ "$HC" = 200 ] || die "LAB_ABSENT : gateway injoignable ou refus ($GW_ADMIN/applications -> $HC)"
ok "0.1 Jenkins, Gitea et la gateway répondent"
if [ -n "${GITEA_TOKEN_FILE:-}" ] && [ -r "$GITEA_TOKEN_FILE" ]; then CI_TOKEN="$(cat "$GITEA_TOKEN_FILE")"
elif docker inspect "$GITEA_CONTAINER" >/dev/null 2>&1; then
  CI_TOKEN=$(docker exec -u git "$GITEA_CONTAINER" gitea admin user generate-access-token --username ci --token-name "a6-live-ci-$TS" --scopes write:repository,write:issue,write:user,read:user,write:admin 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
fi
[ -n "$CI_TOKEN" ] || die "LAB_ABSENT : aucun token Gitea ci"
printf 'Authorization: token %s\n' "$CI_TOKEN" > "$TMP/ci.hdr"
gapi -o /dev/null -w '%{http_code}' "$API/repos/$GIT_REPO" | grep -q '^200$' || die "LAB_ABSENT : $GIT_REPO illisible"
ok "0.2 token ci opérationnel"
for f in scripts/app-rollback-request.sh ci/Jenkinsfile.app-rollback ci/jenkins/app-rollback.job.xml; do
  raw_at main "$SUBDIR/$f" > /dev/null; [ "$(raw_hc)" = 200 ] || die "PREREQUIS : $f absent de gitea main (HTTP $(raw_hc)) — git push gitea HEAD:main"
done
raw_at main "$SUBDIR/scripts/provision-request.sh" | grep -q 'REPLI_EN_COURS' || die "PREREQUIS : provision-request.sh sur gitea main ne porte pas REPLI_EN_COURS"
raw_at main "$SUBDIR/scripts/provision-apply-reconcile.sh" | grep -q 'REPLI_PERIME' || die "PREREQUIS : provision-apply-reconcile.sh sur gitea main ne porte pas REPLI_PERIME"
ok "0.3 gitea main porte A6 (script, Jenkinsfile, coquille, gardes de fenêtre)"
curl -sf "$JENKINS_UI/job/app-rollback/config.xml" > "$TMP/rb.xml" || die "PREREQUIS : job app-rollback absent — JOBS=app-rollback BOOTSTRAP_JOBS=app-rollback scripts/setup-provision-jobs.sh"
grep -q 'ci/Jenkinsfile.app-rollback' "$TMP/rb.xml" || die "PREREQUIS : app-rollback n'est pas from SCM"
PARAMS=$(curl -s "$JENKINS_UI/job/app-rollback/api/json?tree=property%5BparameterDefinitions%5Bname%5D%5D" | jq_ "print(' '.join(p['name'] for pr in d.get('property',[]) for p in pr.get('parameterDefinitions',[])))")
[ "$PARAMS" = "APP ENV REASON CHANGE_REF" ] || die "PREREQUIS : formulaire app-rollback non posé (paramètres : '$PARAMS') — amorcer le job"
raw_at main "$SUBDIR/clients/_example/environments.yaml" > "$TMP/chain.yaml"; [ "$(raw_hc)" = 200 ] || die "PREREQUIS : chaîne illisible sur gitea main"
CHAIN_ALL=$(STOA_ENV_CHAIN_FILE="$TMP/chain.yaml" env_chain); TERM=$(STOA_ENV_CHAIN_FILE="$TMP/chain.yaml" env_chain_terminus)
ENVS_FORM=$(curl -s "$JENKINS_UI/job/app-rollback/api/json?tree=property%5BparameterDefinitions%5Bname,choices%5D%5D" | jq_ "print(' '.join(next((p.get('choices') or []) for pr in d.get('property',[]) for p in pr.get('parameterDefinitions',[]) if p.get('name')=='ENV')))")
[ "$ENVS_FORM" = "$CHAIN_ALL" ] && ok "0.4 job app-rollback posé, formulaire APP ENV REASON CHANGE_REF, ENV == chaîne entière ($CHAIN_ALL)" || ko "0.4 formulaire ENV='$ENVS_FORM' ≠ chaîne '$CHAIN_ALL'"
case "$(STOA_ENV_CHAIN_FILE="$TMP/chain.yaml" env_chain_gate "$TERM")" in GATE=1\|*) ok "0.5 la porte du terminus ($TERM) exige change_ref (requireChangeRef/itsmCheck)";; *) die "PREREQUIS : la porte du terminus n'exige pas change_ref — §7 rougirait pour une mauvaise raison";; esac
case "$(STOA_ENV_CHAIN_FILE="$TMP/chain.yaml" env_chain_gate rec)" in GATE=0\|*) ok "0.6 rec n'exige pas de change_ref";; *) die "PREREQUIS : rec exige change_ref";; esac
ensure_human alice "$TMP/alice.hdr"; ok "0.7 alice : compte Gitea humain, collaboratrice write, token jetable"
GUID_REF=$(api_id_of "$REQ_API" "$REQ_API_VER"); [ -n "$GUID_REF" ] || die "PREREQUIS : $REQ_API $REQ_API_VER absente de la gateway"
[ "$(api_active "$GUID_REF")" = True ] && ok "0.8 $REQ_API $REQ_API_VER active (id=$GUID_REF)" || die "PREREQUIS : $REQ_API inactive"
[ -z "$(gw_app_id "$APP")" ] && ok "0.9 aucune application $APP résiduelle" || die "PREREQUIS : $APP déjà sur la gateway"
openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -days 365 -subj "/CN=$APP-C1" -out "$TMP/c1.crt" 2>/dev/null || die "PREREQUIS : openssl"
openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -days 400 -subj "/CN=$APP-C2" -out "$TMP/c2.crt" 2>/dev/null || die "PREREQUIS : openssl"
DER1=$(der_of "$TMP/c1.crt"); DER2=$(der_of "$TMP/c2.crt"); [ -n "$DER1" ] && [ "$DER1" != "$DER2" ] && ok "0.10 deux certificats jetables C1 (365 j) / C2 (400 j)" || die "PREREQUIS : certs"
GIT_TREE="$(git rev-parse --short HEAD)"; echo "  (arbre local : $GIT_TREE ; l'aval joue l'arbre de gitea main au SHA mergé)"

echo "═══ 1. État N-1 : demande rec IP 10.42.0.1 + C1 ⇒ SUCCESS ; lectures de référence ═══"
chain_rec_cert 10.42.0.1 "$TMP/c1.crt"; PR1="$PR_N"; MS1="$MS_N"; N_PA1="$N_PA"
[ "$RES" = SUCCESS ] && ok "1.1 provision-apply #$N_PA1 → aval #$S_NUM SUCCESS (PR #$PR1, merge $MS1)" || die "PREREQUIS : l'état N-1 n'a pas été projeté ($RES) — $(grep -E 'REFUS' "$TMP/pa.$N_PA1.console" "$TMP/ss.${S_NUM:-0}.console" 2>/dev/null | head -2 | tr '\n' ' ')"
APP_ID=$(gw_app_id "$APP"); [ -n "$APP_ID" ] || die "PREREQUIS : $APP absente de la gateway après SUCCESS"
O1=$(gw_app_obj "$APP_ID"); GUID1=$(obj_field "$O1" GUID); KEY1=$(obj_field "$O1" KEY); IDS1=$(obj_field "$O1" IDS); SUBS1=$(obj_field "$O1" SUBS)
[ "$GUID1" = "$APP_ID" ] && [ -n "$KEY1" ] && case ",$SUBS1," in *",$GUID_REF,"*) true;; *) false;; esac && ok "1.2 objet lu : GUID=$GUID1, clé empreintée (jamais imprimée), souscrite à $GUID_REF" || ko "1.2 objet : GUID=$GUID1 SUBS=$SUBS1"
[ "$(gw_app_ip_of "$APP_ID")" = "10.42.0.1-10.42.0.1" ] && ok "1.3 IP 10.42.0.1-10.42.0.1 (forme normalisée, égalité stricte)" || ko "1.3 IP : $(gw_app_ip_of "$APP_ID")"
C=$(gw_app_cert_of "$APP_ID"); case "$C" in "$APP-exp-"[0-9]*" $DER1") ok "1.4 cert C1 posé (name ${C%% *}, value == DER C1)";; *) ko "1.4 cert : ${C:0:60}…";; esac
LINE1=$(rec_line_at "$MS1"); D1=$(digest_at "$MS1"); [ -n "$LINE1" ] && [ -n "$D1" ] && ok "1.5 ligne rec et digest de #$PR1 capturés ($D1)" || ko "1.5 ligne/digest de #$PR1"

echo "═══ 2. AUCUN_ETAT_PRECEDENT par build : un seul état mergé ⇒ refus nommé, rien poussé ═══"
BS0=$(branch_sha); NP0=$(prs_on_branch)
rollback_build "$APP" rec "incident reseau a6"
[ "$RB_RES" = FAILURE ] && grep -q '^REFUS: AUCUN_ETAT_PRECEDENT' "$TMP/rb.$RB_NUM.console" && grep -q '^ETAPE lignee' "$TMP/rb.$RB_NUM.console" && ! grep -q '^ETAPE pr$' "$TMP/rb.$RB_NUM.console" \
  && ok "2.1 app-rollback #$RB_NUM FAILURE AUCUN_ETAT_PRECEDENT (après ETAPE lignee, jamais ETAPE pr)" || ko "2.1 #$RB_NUM $RB_RES : $(grep -E 'REFUS|ETAPE' "$TMP/rb.$RB_NUM.console" | tail -2 | tr '\n' ' ')"
[ "$(branch_sha)" = "$BS0" ] && [ "$(prs_on_branch)" = "$NP0" ] && [ -z "$RB_PR" ] && ok "2.2 branche distante et nombre de PR inchangés (rien poussé, aucune PR)" || ko "2.2 branche $(branch_sha) vs $BS0, PR $(prs_on_branch) vs $NP0"
grep -q 'suspension' "$TMP/rb.$RB_NUM.console" && ok "2.3 le remède nommé est la suspension (règle 2), pas un repli" || ko "2.3 remède"

echo "═══ 3. État N : demande rec IP 10.42.0.2 + C2 ⇒ SUCCESS ; même GUID, même clé, identifiers changés ═══"
chain_rec_cert 10.42.0.2 "$TMP/c2.crt"; PR2="$PR_N"; MS2="$MS_N"; N_PA2="$N_PA"
[ "$RES" = SUCCESS ] && ok "3.1 provision-apply #$N_PA2 → aval #$S_NUM SUCCESS (PR #$PR2, merge $MS2)" || die "PREREQUIS : l'état N n'a pas été projeté ($RES)"
O2=$(gw_app_obj "$APP_ID"); IDS2=$(obj_field "$O2" IDS)
[ "$(obj_field "$O2" GUID)" = "$GUID1" ] && [ "$(obj_field "$O2" KEY)" = "$KEY1" ] && [ "$(obj_field "$O2" SUBS)" = "$SUBS1" ] && ok "3.2 deux applies successifs ⇒ même GUID, même clé, mêmes souscriptions (première moitié de la porte)" || ko "3.2 GUID/KEY/SUBS ont bougé"
[ "$IDS2" != "$IDS1" ] && [ "$(gw_app_ip_of "$APP_ID")" = "10.42.0.2-10.42.0.2" ] && ok "3.3 identifiers changés (anti-vacant) : IP 10.42.0.2-10.42.0.2" || ko "3.3 IDS identiques ou IP : $(gw_app_ip_of "$APP_ID")"
C=$(gw_app_cert_of "$APP_ID"); case "$C" in *" $DER2") ok "3.4 cert C2 posé";; *) ko "3.4 cert : ${C:0:60}…";; esac
LINE2=$(rec_line_at "$MS2"); [ "$LINE2" != "$LINE1" ] && ok "3.5 ligne rec de #$PR2 ≠ ligne de #$PR1" || ko "3.5 lignes identiques"

echo "═══ 4. LA PORTE — repli rec : PR de repli, merge, pause, apply ⇒ gateway = état N-1 par LECTURE ═══"
rollback_build "$APP" rec "retour arriere a6 vers N-1"
[ "$RB_RES" = SUCCESS ] && [ -n "$RB_PR" ] && ok "4.1 app-rollback #$RB_NUM SUCCESS → PR de repli #$RB_PR" || die "PORTE : app-rollback #$RB_NUM $RB_RES sans PR : $(grep -E 'REFUS|ERREUR' "$TMP/rb.$RB_NUM.console" | tail -2 | tr '\n' ' ')"
R1="$RB_PR"
grep -q "^REPLI_DE=$MS2 REPLI_VERS=$MS1 REPLI_DIGEST=$D1" "$TMP/rb.$RB_NUM.console" && ok "4.2 console : REPLI_DE=#$PR2 REPLI_VERS=#$PR1, digest annoncé == digest(#$PR1) recalculé par la lib" || ko "4.2 REPLI_* : $(grep '^REPLI_DE=' "$TMP/rb.$RB_NUM.console")"
grep -q '^Repli-Par: jenkins-form:anonymous' <(git -C "$TMP" --no-pager log -0 2>/dev/null; gapi "$API/repos/$GIT_REPO/git/commits/$(branch_sha)" | jq_ "print((d.get('commit') or {}).get('message',''))") && ok "4.3 trailer Repli-Par: jenkins-form:anonymous (déclenchement anonyme du harnais)" || ko "4.3 trailer Repli-Par : $(gapi "$API/repos/$GIT_REPO/git/commits/$(branch_sha)" | jq_ "print((d.get('commit') or {}).get('message',''))" | grep Repli-Par)"
BODY=$(pr_field "$R1" ".get('body','')")
printf '%s' "$BODY" | grep -q "app-rollback: de $MS2 vers $MS1" && printf '%s' "$BODY" | grep -q "#$PR1" && printf '%s' "$BODY" | grep -q "#$PR2" && printf '%s' "$BODY" | grep -q "$D1" && printf '%s' "$BODY" | grep -q 'cert : restauré' \
  && ok "4.4 corps de la PR : marqueur de→vers, #N, #N-1, digest, « cert : restauré »" || ko "4.4 corps : $(printf '%s' "$BODY" | head -c 200)"
[ "$(rec_line_at "$(branch_sha)")" = "$LINE1" ] && [ "$(raw_at "$(branch_sha)" "$CERT_DIR/$APP-rec.crt" | der_of /dev/stdin)" = "$DER1" ] && ok "4.5 la branche de repli porte la ligne rec de #$PR1 et le cert C1 à l'octet" || ko "4.5 branche : $(rec_line_at "$(branch_sha)" | head -c 120)"
merge_pause_apply "$R1"; MSR1="$MS_N"; N_PAR1="$N_PA"; S_R1="$S_NUM"
[ "$RES" = SUCCESS ] && ok "4.6 merge par alice → provision-apply #$N_PAR1 → pause → alice → aval #$S_R1 SUCCESS" || die "PORTE : apply du repli $RES — $(grep -E 'REFUS' "$TMP/pa.$N_PAR1.console" "$TMP/ss.${S_R1:-0}.console" 2>/dev/null | head -2 | tr '\n' ' ')"
grep -q '^RECONCILE_OK' "$TMP/pa.$N_PAR1.console" && grep -q '^REPLI_OK' "$TMP/pa.$N_PAR1.console" && console_order "$TMP/pa.$N_PAR1.console" 'REPLI_OK' 'PORTE_OK' 'Input requested' 'PORTE_OK' \
  && ok "4.7 amont : REPLI_OK (main immobile) < porte pré-pause < pause < porte au dispatch" || ko "4.7 amont : $(grep -E 'REPLI|RECONCILE|PORTE' "$TMP/pa.$N_PAR1.console" | head -3 | tr '\n' ' ')"
console_order "$TMP/ss.$S_R1.console" "API_AT_PALIER : '$REQ_API'" 'SUBSCRIPTION_CONFIRMED' && grep -q "SUBSCRIPTION_CONFIRMED : '$APP' souscrite à '$REQ_API' v$REQ_API_VER (id=$GUID_REF)" "$TMP/ss.$S_R1.console" && grep -q 'CERT_NAME_CONFIRMED' "$TMP/ss.$S_R1.console" && ! grep -q 'IDENTIFIERS_CONVERGED' "$TMP/ss.$S_R1.console" \
  && ok "4.8 aval : API_AT_PALIER < identifiers mis à jour (pas CONVERGED) < verify SUBSCRIPTION_CONFIRMED au même GUID + CERT_NAME_CONFIRMED" || ko "4.8 aval : $(grep -E 'API_AT|SUBSCRIPTION|CERT_NAME|IDENTIFIERS' "$TMP/ss.$S_R1.console" | head -4 | tr '\n' ' ')"
O3=$(gw_app_obj "$APP_ID")
[ "$(obj_field "$O3" GUID)" = "$GUID1" ] && [ "$(obj_field "$O3" KEY)" = "$KEY1" ] && [ "$(obj_field "$O3" SUBS)" = "$SUBS1" ] && [ "$(obj_field "$O3" IDS)" = "$IDS1" ] && [ "$(obj_field "$O3" SUSP)" = False ] \
  && ok "4.9 GATEWAY PAR LECTURE : même GUID, même clé, mêmes souscriptions, identifiers == état N-1, non suspendue" || ko "4.9 objet après repli : IDS==IDS1 ? $([ "$(obj_field "$O3" IDS)" = "$IDS1" ] && echo oui || echo non)"
[ "$(gw_app_ip_of "$APP_ID")" = "10.42.0.1-10.42.0.1" ] && ok "4.10 IP 10.42.0.1-10.42.0.1 (l'état N-1)" || ko "4.10 IP : $(gw_app_ip_of "$APP_ID")"
C=$(gw_app_cert_of "$APP_ID"); case "$C" in *" $DER1") ok "4.11 cert C1 (l'état N-1)";; *) ko "4.11 cert : ${C:0:60}…";; esac
[ "$(rec_line_at main)" = "$LINE1" ] && [ "$(raw_at main "$CERT_DIR/$APP-rec.crt" | der_of /dev/stdin)" = "$DER1" ] && ok "4.12 GIT : main porte la ligne rec de #$PR1 et le cert C1 à l'octet" || ko "4.12 main : $(rec_line_at main | head -c 100)"
pr_comments "$R1" > "$TMP/r1.comments"
grep -q 'Apply nominatif RÉUSSI' "$TMP/r1.comments" && grep -q "$D1" "$TMP/r1.comments" && grep -q "$MSR1" "$TMP/r1.comments" && ok "4.13 PR #$R1 : ✅ Apply nominatif RÉUSSI, référence appliquée $MSR1, digest == celui annoncé par la PR de repli" || ko "4.13 commentaires : $(grep -E 'Apply|digest' "$TMP/r1.comments" | head -2 | tr '\n' ' ')"

echo "═══ 5. Le repli du repli restaure N (profondeur 1, nommé REPLI_DU_REPLI) ═══"
rollback_build "$APP" rec "repli du repli a6"
[ "$RB_RES" = SUCCESS ] && [ -n "$RB_PR" ] && grep -q '^REPLI_DU_REPLI : restaure' "$TMP/rb.$RB_NUM.console" && grep -q "^REPLI_DE=$MSR1 REPLI_VERS=$MS2 " "$TMP/rb.$RB_NUM.console" \
  && ok "5.1 app-rollback #$RB_NUM → PR #$RB_PR, REPLI_DU_REPLI, restaure #$PR2 (N), remplace le repli #$R1" || die "PORTE : repli du repli #$RB_NUM $RB_RES : $(grep -E 'REFUS|REPLI' "$TMP/rb.$RB_NUM.console" | tail -2 | tr '\n' ' ')"
R2="$RB_PR"; pr_field "$R2" ".get('body','')" | grep -q 'REPLI_DU_REPLI' && ok "5.2 le corps de la PR #$R2 le dit" || ko "5.2 corps sans REPLI_DU_REPLI"
merge_pause_apply "$R2"; S_R2="$S_NUM"
[ "$RES" = SUCCESS ] && ok "5.3 apply du repli du repli SUCCESS (aval #$S_R2)" || die "PORTE : $RES"
O4=$(gw_app_obj "$APP_ID")
[ "$(obj_field "$O4" GUID)" = "$GUID1" ] && [ "$(obj_field "$O4" KEY)" = "$KEY1" ] && [ "$(obj_field "$O4" IDS)" = "$IDS2" ] && [ "$(gw_app_ip_of "$APP_ID")" = "10.42.0.2-10.42.0.2" ] \
  && ok "5.4 gateway = état N (IP .2, identifiers == état 3), même GUID, même clé" || ko "5.4 objet : IP $(gw_app_ip_of "$APP_ID")"
C=$(gw_app_cert_of "$APP_ID"); case "$C" in *" $DER2") ok "5.5 cert C2 (l'état N)";; *) ko "5.5 cert : ${C:0:60}…";; esac

echo "═══ 6. Contre-épreuve A5 en repli : $REQ_API DÉSACTIVÉE ⇒ le repli est refusé AVANT toute écriture (proxy mono-gateway : API_INACTIVE ; API_NOT_PROMOTED prouvé par A5 #80 sur la même porte) ═══"
DEACTIVATED=1; api_switch "$GUID_REF" deactivate && ok "6.1 $REQ_API désactivée (isActive=False relu, trap de réactivation armé)" || die "PREREQUIS : désactivation de $REQ_API"
rollback_build "$APP" rec "repli sous api inactive a6"
[ "$RB_RES" = SUCCESS ] && [ -n "$RB_PR" ] && ok "6.2 app-rollback #$RB_NUM → PR #$RB_PR (restaure le repli #$R1 : IP .1, C1)" || die "PORTE : #$RB_NUM $RB_RES"
R3="$RB_PR"; merge_pause_apply "$R3"; S_R3="$S_NUM"; MSR3="$MS_N"
[ "$RES" = FAILURE ] && grep -q '^REFUS: API_INACTIVE' "$TMP/ss.$S_R3.console" && ! grep -q 'PLAY \[Self-service application — verify' "$TMP/ss.$S_R3.console" \
  && ok "6.3 aval #$S_R3 FAILURE REFUS: API_INACTIVE, aucun verify (A5 tient en repli)" || ko "6.3 aval #$S_R3 $RES : $(grep -E 'REFUS' "$TMP/ss.${S_R3:-0}.console" | head -1)"
[ "$(gw_app_ip_of "$APP_ID")" = "10.42.0.2-10.42.0.2" ] && [ "$(obj_field "$(gw_app_obj "$APP_ID")" IDS)" = "$IDS2" ] && ok "6.4 rien n'a été écrit : la gateway est toujours à l'état N (IP .2)" || ko "6.4 la gateway a bougé : $(gw_app_ip_of "$APP_ID")"
pr_comments "$R3" > "$TMP/r3.comments"; grep -q 'API_INACTIVE' "$TMP/r3.comments" && grep -q "L'ordre app/API" "$TMP/r3.comments" && grep -q "aval selfservice-app-deploy #$S_R3" "$TMP/r3.comments" && ok "6.5 PR #$R3 ❌ API_INACTIVE + « L'ordre app/API », ancrée sur l'aval #$S_R3" || ko "6.5 commentaires : $(grep -E 'REFUS|ordre' "$TMP/r3.comments" | head -2 | tr '\n' ' ')"
reactivate; [ "$DEACTIVATED" = 0 ] || die "PREREQUIS : réactivation"
replay_pr "$R3" "provision/$APP-rec" "$MSR3"; wait_amont "$N_PA" PAUSE; answer_pause "$N_PA"; finish_amont "$N_PA"
[ "$RES" = SUCCESS ] && [ "$(gw_app_ip_of "$APP_ID")" = "10.42.0.1-10.42.0.1" ] && [ "$(obj_field "$(gw_app_obj "$APP_ID")" KEY)" = "$KEY1" ] && ok "6.6 après réactivation, le REJEU du webhook de la PR de repli #$R3 (motif A2) projette l'état : IP .1, même clé" || ko "6.6 rejeu : $RES, IP $(gw_app_ip_of "$APP_ID")"

echo "═══ 7. Contre-épreuve terminus ($TERM) : sans change_ref ⇒ GATE_REFS_REQUIRED avant tout clone ; avec ⇒ PALIER_ABSENT après le clone ═══"
rollback_build "$APP" "$TERM" "repli terminus a6"
[ "$RB_RES" = FAILURE ] && grep -q '^REFUS: GATE_REFS_REQUIRED' "$TMP/rb.$RB_NUM.console" && ! grep -q '^ETAPE clone' "$TMP/rb.$RB_NUM.console" && [ -z "$RB_PR" ] \
  && ok "7.1 #$RB_NUM FAILURE GATE_REFS_REQUIRED, aucun ETAPE clone, aucune PR" || ko "7.1 #$RB_NUM $RB_RES : $(grep -E 'REFUS|ETAPE' "$TMP/rb.$RB_NUM.console" | tail -3 | tr '\n' ' ')"
rollback_build "$APP" "$TERM" "repli terminus a6" CHG-0001
[ "$RB_RES" = FAILURE ] && grep -q '^REFUS: PALIER_ABSENT' "$TMP/rb.$RB_NUM.console" && console_order "$TMP/rb.$RB_NUM.console" 'ETAPE porte' 'ETAPE clone' 'REFUS: PALIER_ABSENT' \
  && ok "7.2 #$RB_NUM avec CHG-0001 : porte < clone < PALIER_ABSENT (la paire prouve l'ordre, motif G6)" || ko "7.2 #$RB_NUM $RB_RES : $(grep -E 'REFUS|ETAPE' "$TMP/rb.$RB_NUM.console" | tail -3 | tr '\n' ' ')"

echo
echo "═══════════════════════════════════════════════════"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
