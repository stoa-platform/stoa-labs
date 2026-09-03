#!/usr/bin/env bash
# test-a7-live.sh — la PORTE et les CONTRE-ÉPREUVES d'A7 (GOAL cd-applications :
# le terminus et le parcours complet), par BUILDS RÉELS sur le lab : Gitea +
# Jenkins + Vault + annuaire LDAP + itsm-mock + la 10.15 réelle (dev/rec/int/homol,
# mono-gateway) + wm-mock-prod (le terminus, gateway séparée).
# Spec : docs/superpowers/specs/2026-09-03-a7-terminus-et-parcours-design.md (D8).
#   0. préconditions (annuaire, tickets, terminus équipé, mock fidèle, ITSM, providers,
#      globales, formulaires amorcés) ; APIM_TERMINUS_BASE posée (restaurée en tête de trap)
#   1. dev  (alice demande, alice merge, alice porte)   ⇒ SUCCESS, lecture par l'objet
#   2. rec  (alice / alice / alice)                     ⇒ claim mutée, GUID/clé stables
#   3. int  (alice / bob / bob — équipe de Git, tenants du porteur journalisés)
#      + contre-épreuve inline : le formulaire sans FORGE_TOKEN ⇒ REQUESTER_UNKNOWN
#   4. homol (alice / carol / carol) — GATE_REFS_REQUIRED sans pv_ref, puis SUCCESS
#   5. prod  (alice / oscar / oscar) : ITSM_NOT_APPROVED, PAYLOAD_PERIME, API_NOT_PROMOTED
#      (rien écrit), promotion de l'API par archive (même GUID), API_INACTIVE au terminus,
#      rejeu ⇒ SUCCESS sur le terminus
#   6. la porte, lue : cinq paliers dans Git, cinq client_id, G_API 2/2 gateways,
#      G_APP/clé stables, clé jamais transportée, rien dans Vault
#   7. le formulaire : rec sous alice avec refs ; int sans token ; homol sans PV ; TOKEN_ALTERE
#   8. le repli au terminus par le même formulaire ⇒ ETAT_IDENTIQUE
#
# ── FAIL-CLOSED, JAMAIS DE SKIP MUET ── prérequis manquant ⇒ `LAB_ABSENT`/`PREREQUIS`.
# ── CE QUE CE SCRIPT ÉCRIT DANS LE LAB, ET CE QU'IL REMET ── six PR provision/* jetables
# mergées (main reçoit et perd un manifeste jetable), une application jetable sur la 10.15
# ET sur le terminus (supprimées), l'API promue au terminus (LAISSÉE : c'est l'état nominal
# après A7), la globale APIM_TERMINUS_BASE (posée, RESTAURÉE en premier dans le trap ;
# KEEP_TERMINUS=1 la laisse), tokens Gitea jetables (révoqués), ne draine que SES pauses.
#
# Entrées (env) — OBLIGATOIRES, sans défaut vers un système en service :
#   JENKINS_UI GITEA_URL GW_ADMIN WM_USER WM_PASS
#   LAB_ALICE_PASS LAB_CAROL_PASS LAB_OSCAR_PASS (ou ./.env.lab-users) ; bob = lib lab-vault-users
#   VAULT_TOKEN (root de lab ; ou lu dans le conteneur poc-vault)
# Optionnelles : TERMINUS_ADMIN TERMINUS_WM_USER/PASS (défaut : l'env du conteneur du mock)
#   TERMINUS_CURL GITEA_TOKEN_FILE GITEA_CONTAINER JENKINS_CONTAINER LDAP_* VAULT_ADDR_LAB
#   REQ_API REQ_API_VER KEEP_TERMINUS ITSM_URL_LOCAL
#
#   set -a; . ./.env.lab-users; set +a
#   JENKINS_UI=http://localhost:18080 GITEA_URL=http://localhost:13000 \
#   GW_ADMIN=http://localhost:5555/rest/apigateway WM_USER=Administrator WM_PASS=manage \
#     bash scripts/test-a7-live.sh
# `A && ok || ko` (SC2015), les accents graves du markdown des PR (SC2016) et
# TERMINUS_CURL éclaté en mots (SC2086) sont l'idiome des scripts de preuve du repo.
# shellcheck disable=SC2015,SC2016,SC2034,SC2086
set -uo pipefail
set +x
# ── copie-exec : ne JAMAIS être coupé par une édition du script en cours (A6 passage 1) ──
if [ -z "${A7_COPY:-}" ]; then
  _C="$(mktemp -d /tmp/a7live.XXXXXX)"; cp "$0" "$_C/run.sh"; A7_COPY="$_C" exec bash "$_C/run.sh" "$@"
fi
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
[ -f "$REPO/scripts/provision-request.sh" ] || REPO="$(pwd)"
cd "$REPO" || exit 1

if [ -z "${LAB_ALICE_PASS:-}" ] && [ -r ./.env.lab-users ]; then
  # shellcheck disable=SC1091
  set -a; . ./.env.lab-users; set +a
fi
# shellcheck source=scripts/lib/lab-vault-users.sh
. scripts/lib/lab-vault-users.sh 2>/dev/null || true
JENKINS_UI="${JENKINS_UI:?JENKINS_UI requis (ex. http://localhost:18080)}"
GITEA_URL="${GITEA_URL:?GITEA_URL requis (ex. http://localhost:13000)}"
GW_ADMIN="${GW_ADMIN:?GW_ADMIN requis (ex. http://localhost:5555/rest/apigateway)}"
WM_USER="${WM_USER:?WM_USER requis}"; WM_PASS="${WM_PASS:?WM_PASS requis}"
LAB_ALICE_PASS="${LAB_ALICE_PASS:?LAB_ALICE_PASS requis (ou ./.env.lab-users)}"
LAB_CAROL_PASS="${LAB_CAROL_PASS:?LAB_CAROL_PASS requis (ou ./.env.lab-users)}"
LAB_OSCAR_PASS="${LAB_OSCAR_PASS:?LAB_OSCAR_PASS requis (ou ./.env.lab-users)}"
LAB_BOB_PASS="${LAB_BOB_PASS_METACHARS:?LAB_BOB_PASS_METACHARS absent (scripts/lib/lab-vault-users.sh)}"
VAULT_ADDR_LAB="${VAULT_ADDR_LAB:-http://localhost:8200}"
VAULT_CONTAINER="${VAULT_CONTAINER:-poc-vault}"
if [ -z "${VAULT_TOKEN:-}" ] && docker inspect "$VAULT_CONTAINER" >/dev/null 2>&1; then
  VAULT_TOKEN="$(docker exec "$VAULT_CONTAINER" printenv VAULT_DEV_ROOT_TOKEN_ID 2>/dev/null || true)"
fi
VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN requis (root de lab, ou conteneur $VAULT_CONTAINER)}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
GITEA_CONTAINER="${GITEA_CONTAINER:-poc-gitea}"
JENKINS_CONTAINER="${JENKINS_CONTAINER:-poc-jenkins}"
MOCK_CONTAINER="${MOCK_CONTAINER:-poc-wm-mock-prod}"
LDAP_CONTAINER="${LDAP_CONTAINER:-poc-openldap}"
BASE_DN="${LDAP_BASE_DN:-dc=corp,dc=example}"; BIND_DN="${LDAP_BIND_DN:-cn=admin,$BASE_DN}"
BIND_PW="${LDAP_ADMIN_PASSWORD:-$(docker exec "$LDAP_CONTAINER" printenv LDAP_ADMIN_PASSWORD 2>/dev/null || echo admin-lab-2026)}"
ITSM_URL_LOCAL="${ITSM_URL_LOCAL:-http://localhost:8788}"
TERMINUS_ADMIN="${TERMINUS_ADMIN:-http://wm-mock-prod:8080/rest/apigateway}"
TERMINUS_CURL="${TERMINUS_CURL:-docker exec -i $JENKINS_CONTAINER curl}"
TERMINUS_WM_USER="${TERMINUS_WM_USER:-$(docker inspect "$MOCK_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^ADMIN_USER=//p')}"
TERMINUS_WM_PASS="${TERMINUS_WM_PASS:-$(docker inspect "$MOCK_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^ADMIN_PASSWORD=//p')}"
[ -n "$TERMINUS_WM_USER" ] && [ -n "$TERMINUS_WM_PASS" ] || { echo "LAB_ABSENT : TERMINUS_WM_USER/PASS introuvables (conteneur $MOCK_CONTAINER ?)" >&2; exit 1; }
REQ_API="${REQ_API:-demo-selfservice}"; REQ_API_VER="${REQ_API_VER:-1.0.0}"
TEAM="${A7_TEAM:-banking-demo}"
SUBDIR="poc-control-plane-federation"; MAN_DIR="$SUBDIR/clients/provisioned/applications"; CERT_DIR="$SUBDIR/clients/provisioned/certs"
KEEP_TERMINUS="${KEEP_TERMINUS:-0}"

TS="$(date +%s)"; TMP="$(mktemp -d)"; umask 077
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
die(){ printf '\n%s\n' "$*" >&2; exit 1; }
APP="a7p$TS"; APPF="a7f$TS"
CI_TOKEN=""; PRS=""; TOKEN_NAMES=""; GLOBAL_BEFORE=""; GLOBAL_SET=0
G_API=""; G_APP=""; G_APP_T=""; KEY1=""; KEY_RAW=""
API="$GITEA_URL/api/v1"
VHDR="$TMP/vhdr"; printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN" > "$VHDR"
vcurl(){ curl -s -m 20 -H @"$VHDR" "$@"; }
jq_(){ python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
$1"; }

# ── Gitea : ci (admin) + humains, tokens par en-tête fichier, jamais argv ────
gapi(){ curl -s -H @"$TMP/ci.hdr" -H 'Content-Type: application/json' "$@"; }
hapi(){ local who="$1"; shift; curl -s -H @"$TMP/$who.hdr" -H 'Content-Type: application/json' "$@"; }
raw_at(){ gapi -o "$TMP/raw.out" -w '%{http_code}' "$API/repos/$GIT_REPO/raw/$1/$2" > "$TMP/raw.hc"; cat "$TMP/raw.out"; }
raw_hc(){ cat "$TMP/raw.hc" 2>/dev/null; }
pr_field(){ gapi "$API/repos/$GIT_REPO/pulls/$1" | jq_ "print(d$2)"; }
pr_body(){ gapi "$API/repos/$GIT_REPO/pulls/$1" | jq_ "print(d.get('body',''))"; }
pr_comments(){ gapi "$API/repos/$GIT_REPO/issues/$1/comments" | jq_ "print('\n=====\n'.join(c.get('body','') for c in d))"; }
close_pr(){ gapi -X PATCH -d '{"state":"closed"}' -o /dev/null -w '%{http_code}' "$API/repos/$GIT_REPO/pulls/$1"; }
prs_on_branch(){ gapi "$API/repos/$GIT_REPO/pulls?state=all&limit=50" | B="$1" jq_ "import os
print(sum(1 for p in d if (p.get('head') or {}).get('ref')==os.environ['B']))" 2>/dev/null; }
branch_sha(){ gapi "$API/repos/$GIT_REPO/branches/$1" | jq_ "print((d.get('commit') or {}).get('id',''))" 2>/dev/null; }
# ensure_human <login> : compte humain, collaborateur write, token read:user+write:repository (fichiers .hdr et .tok)
ensure_human(){
  local u="$1" hc pw tok name
  name="a7-live-$u-$TS"
  hc=$(gapi -o /dev/null -w '%{http_code}' "$API/users/$u")
  if [ "$hc" != 200 ]; then
    pw=$(python3 -c "import secrets,string;print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(24)))")
    docker exec -u git "$GITEA_CONTAINER" gitea admin user create --username "$u" --password "$pw" --email "$u@stoa.lab" --must-change-password=false >/dev/null 2>&1 || die "PREREQUIS : création du compte Gitea $u"
    unset pw
  fi
  hc=$(gapi -o /dev/null -w '%{http_code}' "$API/repos/$GIT_REPO/collaborators/$u")
  [ "$hc" = 204 ] || gapi -X PUT -d '{"permission":"write"}' -o /dev/null "$API/repos/$GIT_REPO/collaborators/$u"
  tok=$(docker exec -u git "$GITEA_CONTAINER" gitea admin user generate-access-token --username "$u" --token-name "$name" --scopes read:user,write:repository 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
  [ -n "$tok" ] || die "PREREQUIS : token Gitea de $u non minté"
  printf 'Authorization: token %s\n' "$tok" > "$TMP/$u.hdr"; printf '%s' "$tok" > "$TMP/$u.tok"; chmod 600 "$TMP/$u.hdr" "$TMP/$u.tok"
  TOKEN_NAMES="$TOKEN_NAMES $u:$name"
  [ "$(hapi "$u" "$API/user" | jq_ "print(d.get('login',''))")" = "$u" ] || die "PREREQUIS : GET /user sous le token de $u ne rend pas $u (scope read:user ?)"
}
# ── Jenkins ──────────────────────────────────────────────────────────────────
jcrumb(){ curl -sf -c "$1" "$JENKINS_UI/crumbIssuer/api/json" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["crumbRequestField"]+": "+d["crumb"])'; }
jstatus(){ curl -s "$JENKINS_UI/job/$1/$2/wfapi/describe" | jq_ "print(d.get('status',''))" 2>/dev/null || true; }
jresult(){ curl -s "$JENKINS_UI/job/$1/$2/api/json?tree=result,building" | jq_ "print(d.get('result') or ('BUILDING' if d.get('building') else ''))" 2>/dev/null || true; }
jnext(){ curl -sf "$JENKINS_UI/job/$1/api/json?tree=nextBuildNumber" | jq_ "print(d['nextBuildNumber'])"; }
jconsole(){ curl -s "$JENKINS_UI/job/$1/$2/consoleText"; }
jname(){ curl -s "$JENKINS_UI/job/$1/$2/api/json?tree=displayName" | jq_ "print(d.get('displayName',''))" 2>/dev/null || true; }
jparam(){ curl -sg "$JENKINS_UI/job/$1/$2/api/json?tree=actions[parameters[name,value]]" | P="$3" jq_ "import os
for a in d.get('actions',[]):
    for p in a.get('parameters',[]) or []:
        if p.get('name')==os.environ['P']: print(p.get('value',''))" 2>/dev/null | head -1; }
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
wait_built(){ local dl=$(( $(date +%s) + 240 )) r; while [ "$(date +%s)" -lt "$dl" ]; do r=$(jresult "$1" "$2"); [ -n "$r" ] && [ "$r" != BUILDING ] && return 0; sleep 3; done; return 1; }
answer_pause(){ # <build> <login> <mot de passe> : V_USER/V_PASS (par fichier, jamais argv)
  local n="$1" iid jar cr hc
  iid=$(jinput_id provision-apply "$n"); [ -n "$iid" ] || die "PREREQUIS : aucune pause sur provision-apply #$n"
  jar="$TMP/jar.in.$n"; cr=$(jcrumb "$jar") || die "LAB_ABSENT : crumb"
  U="$2" P="$3" python3 - > "$TMP/input.json" <<'PY'
import json, os
print(json.dumps({"parameter": [{"name": "V_USER", "value": os.environ["U"]}, {"name": "V_PASS", "value": os.environ["P"]}]}))
PY
  hc=$(curl -s -b "$jar" -H "$cr" -X POST --data-urlencode json@"$TMP/input.json" "$JENKINS_UI/job/provision-apply/$n/wfapi/inputSubmit?inputId=$iid" -o /dev/null -w '%{http_code}')
  rm -f "$TMP/input.json"
  [ "$hc" = 200 ] || [ "$hc" = 302 ] || die "PREREQUIS : réponse à la pause refusée (HTTP $hc)"
}
N_PA=""; S_NUM=""; RES=""
wait_amont(){ # <N_PA> <PAUSE|NOPAUSE>
  local n="$1" st
  if [ "$2" = PAUSE ]; then
    st=$(wait_until 420 provision-apply "$n" PAUSED_PENDING_INPUT) || die "PREREQUIS : provision-apply #$n n'atteint pas la pause ($st) — $(jconsole provision-apply "$n" | grep -E 'REFUS|error' | tail -2 | tr '\n' ' ')"
  else
    st=$(wait_until 420 provision-apply "$n" FINISHED)
    wait_built provision-apply "$n" || echo "  (avertissement : #$n encore building après le FINISHED de wfapi)"
    sleep 3; jconsole provision-apply "$n" > "$TMP/pa.$n.console"
  fi
}
finish_amont(){ # <N_PA> : pose RES et S_NUM (globales — jamais dans un $( ))
  local n="$1"
  wait_until 1800 provision-apply "$n" FINISHED >/dev/null
  wait_built provision-apply "$n" || echo "  (avertissement : #$n encore building après le FINISHED de wfapi)"
  sleep 3; jconsole provision-apply "$n" > "$TMP/pa.$n.console"
  S_NUM=$(grep -oE "aval selfservice-app-deploy #[0-9]+" "$TMP/pa.$n.console" | grep -oE '[0-9]+$' | head -1)
  [ -n "$S_NUM" ] && { wait_built selfservice-app-deploy "$S_NUM" || true; jconsole selfservice-app-deploy "$S_NUM" > "$TMP/ss.$S_NUM.console"; }
  RES=$(jresult provision-apply "$n")
}
console_order(){ local f="$1" prev=0 l; shift; for m in "$@"; do l=$(grep -n -F -- "$m" "$f" | head -1 | cut -d: -f1); [ -n "$l" ] && [ "$l" -gt "$prev" ] || return 1; prev=$l; done; return 0; }
fire_webhook(){ # <payload> → numéro de build (résolu depuis l'item de file GWT) ; code HTTP dans $TMP/wh.hc
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
replay_pr(){ # <pr> <branche> <merge_sha> <merged_by> <user> → N_PA
  python3 - "$2" "$1" "$3" "$4" "$5" > "$TMP/replay.json" <<'PY'
import json, sys
print(json.dumps({"action": "closed", "pull_request": {"head": {"ref": sys.argv[1]}, "number": int(sys.argv[2]), "merged": True,
  "merged_by": {"login": sys.argv[4]}, "user": {"login": sys.argv[5]}, "merge_commit_sha": sys.argv[3]}}))
PY
  N_PA=$(fire_webhook "$TMP/replay.json"); [ -n "$N_PA" ] || die "BUILD_EN_FILE : le rejeu du webhook n'a pas produit de build (HTTP $(cat "$TMP/wh.hc" 2>/dev/null))"
}
gscript_get(){ local jar="$TMP/jar.sc" cr; cr=$(jcrumb "$jar") || die "LAB_ABSENT : crumb Jenkins"; curl -s -b "$jar" -H "$cr" -X POST --data-urlencode "script=import jenkins.model.Jenkins; import hudson.slaves.EnvironmentVariablesNodeProperty; def p=Jenkins.instance.globalNodeProperties.get(EnvironmentVariablesNodeProperty); println(p==null ? \"\" : (p.envVars.get(\"$1\") ?: \"\"))" "$JENKINS_UI/scriptText" | tr -d '\r\n'; }
gscript_set(){ local jar="$TMP/jar.sc" cr; cr=$(jcrumb "$jar") || die "LAB_ABSENT : crumb Jenkins"; curl -s -o /dev/null -b "$jar" -H "$cr" -X POST --data-urlencode "script=import jenkins.model.Jenkins; import hudson.slaves.EnvironmentVariablesNodeProperty; def j=Jenkins.instance; def p=j.globalNodeProperties.get(EnvironmentVariablesNodeProperty); if (p==null) { p=new EnvironmentVariablesNodeProperty(); j.globalNodeProperties.add(p) }; p.envVars.put(\"$1\", \"$2\"); j.save()" "$JENKINS_UI/scriptText"; }
gscript_unset(){ local jar="$TMP/jar.sc" cr; cr=$(jcrumb "$jar") || return 0; curl -s -o /dev/null -b "$jar" -H "$cr" -X POST --data-urlencode "script=import jenkins.model.Jenkins; import hudson.slaves.EnvironmentVariablesNodeProperty; def j=Jenkins.instance; def p=j.globalNodeProperties.get(EnvironmentVariablesNodeProperty); if (p!=null) { p.envVars.remove(\"$1\"); j.save() }" "$JENKINS_UI/scriptText"; }
jbuild(){ # <job> <fichier de formulaire urlencodé> → numéro de build
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
form_file(){ # <fichier> puis paires clé=valeur sur STDIN → urlencodé (urlencode EXIGE des tuples)
  python3 -c 'import os,sys,urllib.parse
pairs=[tuple(l.split("=",1)) for l in sys.stdin.read().splitlines() if "=" in l]
fd=os.open(sys.argv[1], os.O_WRONLY|os.O_CREAT|os.O_TRUNC, 0o600)
with os.fdopen(fd,"w") as f: f.write(urllib.parse.urlencode(pairs))' "$1"
  [ -s "$1" ] || die "HARNAIS : formulaire de build non écrit ($1)"
}
FB_NUM=""; FB_RES=""
form_build(){ # <job> <fichier formulaire> → FB_NUM FB_RES, console dans $TMP/fb.<job>.<n>.console
  FB_NUM=$(jbuild "$1" "$2"); [ -n "$FB_NUM" ] || die "BUILD_EN_FILE : $1 n'a pas produit de build"
  wait_until 900 "$1" "$FB_NUM" FINISHED >/dev/null; wait_built "$1" "$FB_NUM" || true; sleep 2
  jconsole "$1" "$FB_NUM" > "$TMP/fb.$1.$FB_NUM.console"; FB_RES=$(jresult "$1" "$FB_NUM")
}
jabort_own_pauses(){
  local jar="$TMP/jar.abort" cr n iid
  cr=$(jcrumb "$jar") || return 0
  for n in $(curl -sg "$JENKINS_UI/job/provision-apply/api/json?tree=builds[number,building,displayName]" | APP="$APP" python3 -c 'import json,os,sys
d=json.load(sys.stdin); print(" ".join(str(b["number"]) for b in d.get("builds",[]) if b.get("building") and os.environ["APP"] in (b.get("displayName") or "")))' 2>/dev/null); do
    iid=$(jinput_id provision-apply "$n"); [ -n "$iid" ] && curl -s -b "$jar" -H "$cr" -X POST "$JENKINS_UI/job/provision-apply/$n/input/$iid/abort" -o /dev/null && echo "  pause orpheline provision-apply #$n abandonnée"
  done
}
# ── la 10.15 (Basic par fichier -K) ──────────────────────────────────────────
cfg(){ U="$2" P="$3" python3 -c 'import os,sys
e=lambda s: s.replace("\\","\\\\").replace("\"","\\\"")
fd=os.open(sys.argv[1], os.O_WRONLY|os.O_CREAT|os.O_TRUNC, 0o600)
with os.fdopen(fd,"w") as f: f.write("user = \"%s:%s\"\n" % (e(os.environ["U"]), e(os.environ["P"])))' "$1"; }
cfg "$TMP/wm.cfg" "$WM_USER" "$WM_PASS"
gw(){ curl -s -m 20 -K "$TMP/wm.cfg" -H 'Accept: application/json' -H 'Content-Type: application/json' "$@"; }
gw_wait(){ local hc dl; dl=$(( $(date +%s) + 300 )); while :; do hc=$(gw -o /dev/null -w '%{http_code}' "$GW_ADMIN/applications" || true); [ "$hc" = 200 ] && return 0; [ "$(date +%s)" -lt "$dl" ] || die "LAB_GATEWAY_ILLISIBLE : GET $GW_ADMIN/applications -> HTTP $hc"; sleep 10; done; }
gw_app_id(){ gw_wait; gw "$GW_ADMIN/applications" | N="$1" jq_ "import os
for a in d.get('applications',[]):
    if a.get('name')==os.environ['N']: print(a.get('id','')); break"; }
gw_app_obj(){ # <id> → GUID= KEY= IDS= SUBS= CLAIM= IP= TEAMS= KEYLEN=
  gw "$GW_ADMIN/applications/$1" | python3 -c '
import json,sys,hashlib
d=json.load(sys.stdin); a=(d.get("applications") or [d])[0]
key=((a.get("accessTokens") or {}).get("apiAccessKey_credentials") or {}).get("apiAccessKey") or ""
ids=sorted((i.get("key",""), i.get("name",""), sorted(i.get("value") or [])) for i in (a.get("identifiers") or []) if i.get("key") in ("httpsCertificate","ipAddressRange","openIdClaims","token"))
claim=",".join(sorted(next(((i.get("value") or []) for i in (a.get("identifiers") or []) if i.get("key")=="openIdClaims"), [])))
ip=",".join(sorted(next(((i.get("value") or []) for i in (a.get("identifiers") or []) if i.get("key")=="ipAddressRange"), [])))
print("GUID=%s" % a.get("id")); print("KEY=%s" % hashlib.sha256(key.encode()).hexdigest()); print("KEYLEN=%d" % len(key))
print("IDS=%s" % hashlib.sha256(json.dumps(ids, sort_keys=True).encode()).hexdigest())
print("SUBS=%s" % ",".join(sorted(a.get("consumingAPIs") or []))); print("CLAIM=%s" % claim); print("IP=%s" % ip)
print("TEAMS=%s" % ",".join(sorted(t.get("name","") for t in (a.get("teams") or []) if isinstance(t, dict))))'; }
gw_key_raw(){ gw "$GW_ADMIN/applications/$1" | python3 -c 'import json,sys
d=json.load(sys.stdin); a=(d.get("applications") or [d])[0]
print(((a.get("accessTokens") or {}).get("apiAccessKey_credentials") or {}).get("apiAccessKey") or "")'; }
obj_field(){ printf '%s\n' "$1" | sed -n "s/^$2=//p"; }
api_switch(){ # <id> <activate|deactivate> sur la 10.15
  local dl=$(( $(date +%s) + 240 )) hc
  while :; do hc=$(gw -X PUT -o /dev/null -w '%{http_code}' "$GW_ADMIN/apis/$1/$2" || true); [ "$hc" = 200 ] && break; [ "$(date +%s)" -lt "$dl" ] || return 1; sleep 10; done
}
# ── le terminus (config Basic sur STDIN, curl éventuellement dans un autre conteneur) ──
tesc(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
tcall(){ # <method> <chemin> [corps JSON|@fichier-dans-le-conteneur] → $TMP/t.body $TMP/t.code (creds du terminus)
  local m="$1" p="$2" body="${3:-}"
  if [ -z "$body" ]; then
    printf 'user = "%s:%s"\n' "$(tesc "$TERMINUS_WM_USER")" "$(tesc "$TERMINUS_WM_PASS")" | $TERMINUS_CURL -s -m 30 -K - -X "$m" -H 'Accept: application/json' -w '\n%{http_code}' "${TERMINUS_ADMIN}${p}" > "$TMP/t.raw" 2>/dev/null
  elif [ "${body#@}" != "$body" ]; then
    printf 'user = "%s:%s"\n' "$(tesc "$TERMINUS_WM_USER")" "$(tesc "$TERMINUS_WM_PASS")" | $TERMINUS_CURL -s -m 60 -K - -X "$m" -F "file=$body" -F "overwrite=apis" -w '\n%{http_code}' "${TERMINUS_ADMIN}${p}" > "$TMP/t.raw" 2>/dev/null
  else
    printf 'user = "%s:%s"\n' "$(tesc "$TERMINUS_WM_USER")" "$(tesc "$TERMINUS_WM_PASS")" | $TERMINUS_CURL -s -m 30 -K - -X "$m" -H 'Content-Type: application/json' -H 'Accept: application/json' --data-binary "$body" -w '\n%{http_code}' "${TERMINUS_ADMIN}${p}" > "$TMP/t.raw" 2>/dev/null
  fi
  sed '$d' "$TMP/t.raw" > "$TMP/t.body"; tail -1 "$TMP/t.raw" | tr -d '\r\n' > "$TMP/t.code"
}
tcode(){ cat "$TMP/t.code" 2>/dev/null; }
t_api(){ # <nom> <version> → "id isActive" ou vide
  tcall GET /apis; N="$1" V="$2" jq_ "import os
for a in d.get('apiResponse',[]):
    x=a.get('api',a)
    if x.get('apiName')==os.environ['N'] and str(x.get('apiVersion'))==os.environ['V']: print(x.get('id',''), x.get('isActive')); break" < "$TMP/t.body" 2>/dev/null; }
t_app_id(){ tcall GET /applications; N="$1" jq_ "import os
for a in d.get('applications',[]):
    if a.get('name')==os.environ['N']: print(a.get('id','')); break" < "$TMP/t.body" 2>/dev/null; }
t_app_count(){ tcall GET /applications; jq_ "print(len(d.get('applications',[])))" < "$TMP/t.body" 2>/dev/null; }
t_app_obj(){ # <id> → GUID= SUBS= CLAIM= TEAMS= HASKEY=
  tcall GET "/applications/$1"; python3 -c '
import json,sys
d=json.load(open(sys.argv[1])); a=(d.get("applications") or [d])[0]
claim=",".join(sorted(next(((i.get("value") or []) for i in (a.get("identifiers") or []) if i.get("key")=="openIdClaims"), [])))
key=((a.get("accessTokens") or {}).get("apiAccessKey_credentials") or {}).get("apiAccessKey") or ""
print("GUID=%s" % a.get("id")); print("SUBS=%s" % ",".join(sorted(a.get("consumingAPIs") or []))); print("CLAIM=%s" % claim)
print("TEAMS=%s" % ",".join(sorted(t.get("name","") for t in (a.get("teams") or []) if isinstance(t, dict)))); print("HASKEY=%s" % ("1" if key else "0"))' "$TMP/t.body"; }
# ── LDAP (bind par fichier) ──────────────────────────────────────────────────
ldap_run(){ local tool="$1"; shift
  LDAP_BIND_PW="$BIND_PW" docker exec -i -e LDAP_BIND_PW "$LDAP_CONTAINER" sh -c 'umask 077; f=/tmp/.ldap-bind.$$
    printf %s "$LDAP_BIND_PW" > "$f"; t="$1"; d="$2"; shift 2; "$t" -x -D "$d" -y "$f" "$@"; rc=$?; rm -f "$f"; exit $rc' sh "$tool" "$BIND_DN" "$@"; }
in_group(){ ldap_run ldapsearch -LLL -o ldif-wrap=no -b "cn=$2,ou=Groups,$BASE_DN" -s base member > "$TMP/ldap.members" 2>/dev/null; grep -q "uid=$1,ou=People" "$TMP/ldap.members"; }
vault_ldap_policies(){ # <login> <mot de passe> → policies (une par ligne)
  P="$2" python3 -c 'import json,os,sys;sys.stdout.write(json.dumps({"password":os.environ["P"]}))' > "$TMP/login.json"
  curl -s -m 20 -X POST --data-binary @"$TMP/login.json" "$VAULT_ADDR_LAB/v1/auth/ldap/login/$1" | jq_ "print('\n'.join((d.get('auth') or {}).get('policies') or []))" 2>/dev/null; rm -f "$TMP/login.json"; }
# ── la demande sous identité de forge (le script, avec le token de l'humain) ──
request_as(){ # <login> <env> <ip> [change_ref] [pv_ref] → numéro de PR (stdout) ; sortie dans $TMP/req.<env>.out
  local who="$1" e="$2" ip="$3" cr="${4:-}" pv="${5:-}" rc pr
  GITEA_TOKEN="$CI_TOKEN" FORGE_TOKEN_FILE="$TMP/$who.tok" GIT_HOST="$GITEA_URL" GIT_WEB_HOST="$GITEA_URL" GIT_REPO="$GIT_REPO" PROVISION_PLAN_INLINE=false \
        STOA_ENV_CHAIN_FILE="$REPO/clients/_example/environments.yaml" \
        REQ_APP="$APP" REQ_ENV="$e" REQ_API="$REQ_API" REQ_API_VER="$REQ_API_VER" REQ_CALLER="jenkins-form:$who" REQ_TEAM="$TEAM" \
        REQ_CLIENT_ID="${APP}-${e}" REQ_IP_ALLOWLIST="$ip" REQ_CHANGE_REF="$cr" REQ_PV_REF="$pv" bash scripts/provision-request.sh > "$TMP/req.$e.out" 2>&1; rc=$?
  cat "$TMP/req.$e.out" >> "$TMP/req.all.out"
  pr=$(grep -oE 'PR_URL=[^ ]*/pulls/[0-9]+' "$TMP/req.$e.out" | grep -oE '[0-9]+$' | tail -1)
  echo "$rc" > "$TMP/req.rc"; printf '%s' "$pr"
}
merge_as(){ # <login> <pr> → MERGE_SHA
  local who="$1" pr="$2" dl m hc try=0
  dl=$(( $(date +%s) + 60 )); m=false
  while [ "$(date +%s)" -lt "$dl" ]; do m=$(pr_field "$pr" ".get('mergeable')"); [ "$m" = True ] && break; sleep 2; done
  [ "$m" = True ] || die "PREREQUIS : PR #$pr non mergeable"
  while :; do
    hc=$(hapi "$who" -X POST -d '{"Do":"merge"}' -o "$TMP/merge.out" -w '%{http_code}' "$API/repos/$GIT_REPO/pulls/$pr/merge")
    [ "$hc" = 200 ] && break
    [ "$(pr_field "$pr" ".get('merged')")" = True ] && break
    try=$((try+1)); [ "$hc" = 405 ] && [ "$try" -lt 12 ] && { sleep 5; continue; }
    die "PREREQUIS : merge par $who refusé (HTTP $hc, essai $try) : $(head -c 200 "$TMP/merge.out")"
  done
  [ "$(pr_field "$pr" "['merged_by']['login']")" = "$who" ] || die "PREREQUIS : merged_by ≠ $who sur #$pr"
  pr_field "$pr" "['merge_commit_sha']"
}
pass_of(){ case "$1" in alice) printf '%s' "$LAB_ALICE_PASS";; bob) printf '%s' "$LAB_BOB_PASS";; carol) printf '%s' "$LAB_CAROL_PASS";; oscar) printf '%s' "$LAB_OSCAR_PASS";; esac; }
retry_on_gateway_reset(){ # <pr> <branche> <merge_sha> <porteur> : la 10.15 recyclée EN PLEIN play n'est pas un verdict — rejeu du webhook, une fois, annoncé
  [ "$RES" != SUCCESS ] && [ -n "$S_NUM" ] || return 0
  grep -qE 'Connection reset by peer|Connection failure|Connection refused' "$TMP/ss.$S_NUM.console" 2>/dev/null || return 0
  grep -qE 'REFUS: [A-Z_]+ :' "$TMP/ss.$S_NUM.console" 2>/dev/null && return 0
  echo "  (incident lab : gateway recyclée pendant l'aval #$S_NUM — rejeu du webhook de la PR #$1 par $4, motif A2)"
  replay_pr "$1" "$2" "$3" "$4" alice; wait_amont "$N_PA" PAUSE; answer_pause "$N_PA" "$4" "$(pass_of "$4")"; finish_amont "$N_PA"
}
PR_N=""; MS_N=""
palier(){ # <env> <ip> <mergeur/porteur> [change_ref] [pv_ref] : demande alice → PR d'alice → merge → pause → réponse → fin (+ rejeu keepalive)
  local e="$1" ip="$2" who="$3" cr="${4:-}" pv="${5:-}"
  PR_N=$(request_as alice "$e" "$ip" "$cr" "$pv"); [ "$(cat "$TMP/req.rc")" = 0 ] && [ -n "$PR_N" ] || die "PREREQUIS : demande $APP/$e en échec : $(grep -E 'REFUS|ERREUR' "$TMP/req.$e.out" | head -2 | tr '\n' ' ')"
  PRS="$PRS $PR_N"
  N_PA=$(jnext provision-apply); MS_N=$(merge_as "$who" "$PR_N")
  wait_amont "$N_PA" PAUSE; answer_pause "$N_PA" "$who" "$(pass_of "$who")"; finish_amont "$N_PA"
  retry_on_gateway_reset "$PR_N" "provision/$APP-$e" "$MS_N" "$who"
}
read_step(){ # <env> <ip> <n°> : la 10.15 par l'OBJET — claim mutée, IP du palier, G_APP/KEY/SUBS stables
  local e="$1" ip="$2" n="$3" o
  o=$(gw_app_obj "$G_APP")
  [ "$(obj_field "$o" GUID)" = "$G_APP" ] && [ "$(obj_field "$o" KEY)" = "$KEY1" ] && ok "$n.a même GUID d'application ($G_APP), même clé (empreinte)" || ko "$n.a GUID/clé : $(obj_field "$o" GUID) / $(obj_field "$o" KEY | cut -c1-12)"
  case "$(obj_field "$o" CLAIM)" in *"${APP}-${e}"*) ok "$n.b claim = ${APP}-${e} (mutation lue : le palier $e a écrit)";; *) ko "$n.b claim : $(obj_field "$o" CLAIM)";; esac
  [ "$(obj_field "$o" IP)" = "${ip}-${ip}" ] && ok "$n.c IP ${ip} (distincte par palier)" || ko "$n.c IP : $(obj_field "$o" IP)"
  case ",$(obj_field "$o" SUBS)," in *",$G_API,"*) ok "$n.d souscrite à G_API $G_API";; *) ko "$n.d SUBS : $(obj_field "$o" SUBS)";; esac
  case ",$(obj_field "$o" TEAMS)," in *",$TEAM,"*) case ",$(obj_field "$o" TEAMS)," in *",Default,"*) ko "$n.e Default encore présente";; *) ok "$n.e teams ∋ $TEAM ∌ Default";; esac;; *) ko "$n.e teams : $(obj_field "$o" TEAMS)";; esac
}
pr_dashboard(){ # <pr> <n°> <demandeur> <mergeur> <porteur> : ✅ + trois identités
  pr_comments "$1" > "$TMP/c.$1"
  grep -q 'Apply nominatif RÉUSSI' "$TMP/c.$1" && grep -qF -- "- identités : demandée par \`$3\` · mergée par \`$4\` · portée par \`$5\`" "$TMP/c.$1" \
    && ok "$2 PR #$1 : ✅ Apply nominatif RÉUSSI, identités demandée par $3 · mergée par $4 · portée par $5" || ko "$2 PR #$1 : $(grep -E 'Apply|identités' "$TMP/c.$1" | head -2 | tr '\n' ' ')"
}

# ── nettoyage : la globale D'ABORD, puis le reste ─────────────────────────────
restore_global(){
  [ "$GLOBAL_SET" = 1 ] || return 0
  if [ "$KEEP_TERMINUS" = 1 ]; then echo "  (KEEP_TERMINUS=1 : APIM_TERMINUS_BASE reste posée)"; return 0; fi
  if [ -n "$GLOBAL_BEFORE" ]; then gscript_set APIM_TERMINUS_BASE "$GLOBAL_BEFORE"; else gscript_unset APIM_TERMINUS_BASE; fi
  [ "$(gscript_get APIM_TERMINUS_BASE)" = "$GLOBAL_BEFORE" ] && { GLOBAL_SET=0; echo "  APIM_TERMINUS_BASE restaurée ('${GLOBAL_BEFORE:-vide}')"; } || echo "  ⚠ APIM_TERMINUS_BASE NON restaurée — à retirer à la main (script console)" >&2
}
cleanup(){
  echo; echo "── nettoyage ──"
  restore_global
  jabort_own_pauses
  if [ -n "$CI_TOKEN" ]; then
    for n in $PRS; do close_pr "$n" >/dev/null 2>&1; done
    for e in dev rec int homol prod; do gapi -X DELETE -o /dev/null "$API/repos/$GIT_REPO/branches/provision/${APP}-${e}" 2>/dev/null; done
    gapi -X DELETE -o /dev/null "$API/repos/$GIT_REPO/branches/provision/${APPF}-rec" 2>/dev/null
    f="$MAN_DIR/${APP}.ansible.yml"
    SHA_F=$(gapi "$API/repos/$GIT_REPO/contents/$f?ref=main" | jq_ "print(d.get('sha',''))" 2>/dev/null || true)
    [ -n "$SHA_F" ] && gapi -X DELETE -d "{\"branch\":\"main\",\"sha\":\"$SHA_F\",\"message\":\"test(a7-live): retrait de ${f##*/} (porte A7 jouée)\"}" -o /dev/null "$API/repos/$GIT_REPO/contents/$f" && echo "  ${f##*/} retiré de main"
    for t in $TOKEN_NAMES; do docker exec -u git "$GITEA_CONTAINER" gitea admin user delete-access-token --username "${t%%:*}" "${t#*:}" >/dev/null 2>&1 || true; done
  fi
  ID=$(gw_app_id "$APP" 2>/dev/null || true); [ -n "$ID" ] && { HC=$(gw -X DELETE -o /dev/null -w '%{http_code}' "$GW_ADMIN/applications/$ID"); echo "  application jetable ${APP} supprimée de la 10.15 (HTTP $HC)"; }
  TID=$(t_app_id "$APP" 2>/dev/null || true); [ -n "$TID" ] && { tcall DELETE "/applications/$TID"; echo "  application jetable ${APP} supprimée du terminus (HTTP $(tcode))"; }
  rm -rf "$TMP" "${A7_COPY:-}"
}
trap cleanup EXIT INT TERM

echo "═══ 0. Préconditions ═══"
curl -sf -o /dev/null "$JENKINS_UI/api/json" || die "LAB_ABSENT : Jenkins $JENKINS_UI"
curl -sf -o /dev/null "$GITEA_URL/api/v1/version" || die "LAB_ABSENT : Gitea $GITEA_URL"
docker inspect "$GITEA_CONTAINER" >/dev/null 2>&1 || die "LAB_ABSENT : conteneur $GITEA_CONTAINER"
if [ -n "${GITEA_TOKEN_FILE:-}" ] && [ -r "$GITEA_TOKEN_FILE" ]; then CI_TOKEN="$(tr -d '\r\n' < "$GITEA_TOKEN_FILE")"
else CI_TOKEN=$(docker exec -u git "$GITEA_CONTAINER" gitea admin user generate-access-token --username ci --token-name "a7-live-ci-$TS" --scopes read:user,write:repository,write:issue,read:organization 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1); TOKEN_NAMES="$TOKEN_NAMES ci:a7-live-ci-$TS"; fi
[ -n "$CI_TOKEN" ] || die "PREREQUIS : token ci indisponible"
printf 'Authorization: token %s\n' "$CI_TOKEN" > "$TMP/ci.hdr"; chmod 600 "$TMP/ci.hdr"
[ "$(gapi "$API/user" | jq_ "print(d.get('login',''))")" = ci ] && ok "0.1 forge : token ci valide" || die "PREREQUIS : token ci refusé"
raw_at main "$SUBDIR/clients/_example/environments.yaml" > "$TMP/chain.yaml"; [ "$(raw_hc)" = 200 ] || die "PREREQUIS : environments.yaml illisible sur gitea main"
cmp -s "$TMP/chain.yaml" clients/_example/environments.yaml && ok "0.2 la chaîne de gitea main == le gabarit local (le CI lit gitea)" || die "PREREQUIS : environments.yaml de gitea main ≠ local — pousser d'abord (git push gitea HEAD:main)"
# shellcheck source=scripts/lib/env-chain.sh
. scripts/lib/env-chain.sh
TERM="$(STOA_ENV_CHAIN_FILE="$TMP/chain.yaml" env_chain_terminus)"; [ "$TERM" = prod ] || die "PREREQUIS : terminus ≠ prod ($TERM)"
[ "$(STOA_ENV_CHAIN_FILE="$TMP/chain.yaml" env_chain_gate_deployer_group prod)" = apim-operator-prod ] && [ "$(STOA_ENV_CHAIN_FILE="$TMP/chain.yaml" env_chain_gate_deployer_group int)" = apim-apply-int ] && [ "$(STOA_ENV_CHAIN_FILE="$TMP/chain.yaml" env_chain_gate_deployer_group homol)" = apim-apply-homol ] \
  && ok "0.3 portes : int→apim-apply-int, homol→apim-apply-homol, prod→apim-operator-prod (+ itsmCheck)" || die "PREREQUIS : déclarations de déployeur inattendues"
for e in rec int homol prod; do raw_at main "$SUBDIR/ansible/providers.$e.yml" > "$TMP/prov.$e"; [ "$(raw_hc)" = 200 ] && grep -q "team: $TEAM" "$TMP/prov.$e" || die "PREREQUIS : providers.$e.yml absent de gitea main ou sans $TEAM (pousser A7)"; done
ok "0.4 providers.{rec,int,homol,prod}.yml sur gitea main déclarent $TEAM (onboarding par palier)"
ldap_run ldapsearch -LLL -b "$BASE_DN" -s base dn >/dev/null 2>&1 || die "LAB_ABSENT : annuaire injoignable ou bind refusé"
in_group bob apim-apply-int && in_group carol apim-apply-homol && in_group oscar apim-operator-prod && ok "0.5 LDAP : bob ∈ apim-apply-int, carol ∈ apim-apply-homol, oscar ∈ apim-operator-prod" || die "PREREQUIS : groupes LDAP (setup-vault-ldap.sh / setup-deployer-groups.sh)"
for u in alice:deploy-banking-demo bob:apply-int carol:apply-homol oscar:operator-deploy; do
  P=$(vault_ldap_policies "${u%%:*}" "$(pass_of "${u%%:*}")"); printf '%s\n' "$P" | grep -qx -- "${u#*:}" || die "PREREQUIS : login LDAP→Vault de ${u%%:*} sans la policy ${u#*:} (policies : $(printf '%s' "$P" | tr '\n' ' '))"
done
ok "0.6 Vault (mount ldap) : alice deploy-banking-demo, bob apply-int, carol apply-homol, oscar operator-deploy"
printf '%s\n' "$(vault_ldap_policies bob "$LAB_BOB_PASS")" | grep -qx deploy-banking-demo && die "PREREQUIS : bob porte deploy-banking-demo — il ne serait plus le déployeur NON-tenant de la preuve" || ok "0.6b bob ne porte PAS deploy-banking-demo (déployeur non-tenant : c'est la propriété que D2 mesure)"
RU=$(vcurl "$VAULT_ADDR_LAB/v1/secret/data/stoa/envs/prod/wm-admin" | jq_ "print(d['data']['data'].get('username',''))" 2>/dev/null)
[ "$RU" = "$TERMINUS_WM_USER" ] && ok "0.7 ticket envs/prod/wm-admin = l'admin du terminus ($TERMINUS_WM_USER)" || die "PREREQUIS : envs/prod/wm-admin porte '$RU' — jouer setup-terminus-apps.sh"
tcall GET /applications; [ "$(tcode)" = 200 ] && ok "0.8 terminus joignable et login prouvé (GET /applications ⇒ 200)" || die "PREREQUIS : terminus $TERMINUS_ADMIN ⇒ HTTP $(tcode)"
SAVE_P="$TERMINUS_WM_PASS"; TERMINUS_WM_PASS="faux-$RANDOM"; tcall GET /applications; TERMINUS_WM_PASS="$SAVE_P"
[ "$(tcode)" = 401 ] && ok "0.8b un mot de passe faux ⇒ 401 sur le terminus" || die "PREREQUIS : le terminus accepte un mot de passe faux (HTTP $(tcode))"
tcall GET /configurations/extended; grep -q '"enableTeamWork": *"true"' "$TMP/t.body" && ok "0.9 terminus : feature Teams active" || die "PREREQUIS : teamWork inactif sur le terminus (setup-terminus-apps.sh)"
tcall GET /accessProfiles; PID_T=$(N="$TEAM" jq_ "import os
for p in d.get('accessProfiles',[]):
    if p.get('name')==os.environ['N']: print(p.get('id','')); break" < "$TMP/t.body"); [ -n "$PID_T" ] && ok "0.9b terminus : accessProfile $TEAM ($PID_T)" || die "PREREQUIS : accessProfile $TEAM absent du terminus"
tcall GET /alias; grep -q '"name": *"KeycloakStoaLab"' "$TMP/t.body" && ok "0.9c terminus : alias auth-server KeycloakStoaLab" || die "PREREQUIS : alias KeycloakStoaLab absent du terminus"
# le mock est REBÂTI : POST /assets/team écrit teams[] sur une application (sonde jetable)
tcall POST /applications '{"name":"a7-sonde-'"$TS"'"}'; SID=$(jq_ "print(d.get('id',''))" < "$TMP/t.body")
[ -n "$SID" ] || die "PREREQUIS : le terminus ne crée pas d'application (HTTP $(tcode))"
tcall POST /assets/team "{\"assetIds\":[\"$SID\"],\"assetType\":\"Application\",\"newTeams\":[\"$PID_T\"]}"
SO=$(t_app_obj "$SID"); tcall DELETE "/applications/$SID"
case ",$(obj_field "$SO" TEAMS)," in *",$TEAM,"*) ok "0.10 mock rebâti : POST /assets/team Application écrit teams[] (sonde supprimée)";; *) die "PREREQUIS : le mock du terminus ignore assets/team pour les applications (image non rebâtie ?) — teams=$(obj_field "$SO" TEAMS)";; esac
gw_wait; gw "$GW_ADMIN/apis" > "$TMP/apis.json"
G_API=$(A="$REQ_API" V="$REQ_API_VER" jq_ "import os
for i in d.get('apiResponse',[]):
    x=i.get('api',i)
    if x.get('apiName')==os.environ['A'] and x.get('apiVersion')==os.environ['V'] and x.get('isActive') is True: print(x.get('id','')); break" < "$TMP/apis.json")
[ -n "$G_API" ] && ok "0.11 10.15 : $REQ_API@$REQ_API_VER active — G_API=$G_API" || die "PREREQUIS : $REQ_API@$REQ_API_VER absente/inactive sur la 10.15"
TA=$(t_api "$REQ_API" "$REQ_API_VER")
if [ -n "$TA" ]; then
  # une API ACTIVE ne se supprime pas (409, comme le produit) : désactiver d'abord
  tcall PUT "/apis/${TA%% *}/deactivate"
  tcall DELETE "/apis/${TA%% *}"; [ "$(tcode)" = 200 ] || [ "$(tcode)" = 204 ] || die "PREREQUIS : impossible de retirer $REQ_API du terminus (HTTP $(tcode)) — la contre-épreuve A5 en dépend"
fi
[ -z "$(t_api "$REQ_API" "$REQ_API_VER")" ] && ok "0.12 terminus : $REQ_API ABSENTE (la contre-épreuve « l'API n'est qu'en homol » est possible)" || die "PREREQUIS : $REQ_API encore présente sur le terminus"
RES_10=$(gw "$GW_ADMIN/applications" | jq_ "print(' '.join(a.get('name','') for a in d.get('applications',[]) if a.get('name','').startswith('a7p')))")
[ -z "$RES_10" ] && ok "0.13 aucune application résiduelle a7p* sur la 10.15" || die "PREREQUIS : résidus sur la 10.15 : $RES_10"
tcall GET /applications; RES_T=$(jq_ "print(' '.join(a.get('name','') for a in d.get('applications',[]) if a.get('name','').startswith('a7p')))" < "$TMP/t.body")
[ -z "$RES_T" ] && ok "0.13b aucune application résiduelle a7p* sur le terminus" || die "PREREQUIS : résidus sur le terminus : $RES_T"
T_COUNT0=$(t_app_count)
curl -s -m 5 "$ITSM_URL_LOCAL/changes/CHG-0001" | grep -q '"approved"' && curl -s -m 5 "$ITSM_URL_LOCAL/changes/CHG-0002" | grep -q '"draft"' && ok "0.14 ITSM : CHG-0001 approved, CHG-0002 draft" || die "PREREQUIS : itsm-mock (CHG-0001 approved / CHG-0002 draft)"
[ -z "$(gscript_get GITEA_SERVICE_LOGINS)" ] && ok "0.15 aucune globale GITEA_SERVICE_LOGINS" || die "PREREQUIS : globale GITEA_SERVICE_LOGINS posée"
[ "$(gscript_get APPLY_ADMIN_VIA)" = direct ] && ok "0.15b APPLY_ADMIN_VIA global = direct" || die "PREREQUIS : APPLY_ADMIN_VIA global ≠ direct"
GLOBAL_BEFORE="$(gscript_get APIM_TERMINUS_BASE)"
[ -z "$GLOBAL_BEFORE" ] && ok "0.16 APIM_TERMINUS_BASE vide avant (le terminus est fermé au repos — A4/A6 l'assertent)" || echo "  (APIM_TERMINUS_BASE déjà posée : '$GLOBAL_BEFORE' — restaurée en fin)"
gscript_set APIM_TERMINUS_BASE "$TERMINUS_ADMIN"; GLOBAL_SET=1
[ "$(gscript_get APIM_TERMINUS_BASE)" = "$TERMINUS_ADMIN" ] && ok "0.16b APIM_TERMINUS_BASE posée = $TERMINUS_ADMIN (le geste de DÉCLARATION — restaurée en tête de trap)" || die "PREREQUIS : pose de la globale"
RUNNING=$(curl -sg "$JENKINS_UI/job/provision-apply/api/json?tree=builds[number,building]" | jq_ "print(' '.join(str(b['number']) for b in d.get('builds',[]) if b.get('building')))")
[ -z "$RUNNING" ] && ok "0.17 aucun build provision-apply en cours" || die "PREREQUIS : builds provision-apply en cours ($RUNNING)"
PD=$(curl -sg "$JENKINS_UI/job/app-request/api/json?tree=property[parameterDefinitions[name,type,choices]]" | python3 -c 'import json,sys
d=json.load(sys.stdin); out={}
for p in d.get("property",[]):
    for q in p.get("parameterDefinitions",[]) or []: out[q["name"]]=(q["type"], q.get("choices"))
print("FT=%s CR=%s PV=%s ENV=%s API=%s" % (out.get("FORGE_TOKEN",("",))[0], out.get("CHANGE_REF",("",))[0], out.get("PV_REF",("",))[0], out.get("REQ_ENV",("",[]))[1], (out.get("API",("",[]))[1] or [""])[0]))')
case "$PD" in *"FT=PasswordParameterDefinition CR=StringParameterDefinition PV=StringParameterDefinition"*) ok "0.18 app-request : FORGE_TOKEN (password), CHANGE_REF, PV_REF posés";; *) die "HYPOTHESE_AMORCAGE : formulaire app-request non amorcé ($PD) — un build d'amorçage après le push";; esac
case "$PD" in *"'prod'"*) ok "0.18b app-request : REQ_ENV liste le terminus";; *) die "PREREQUIS : REQ_ENV sans prod ($PD)";; esac
FORM_API=$(printf '%s' "$PD" | sed -n 's/.*API=//p'); [ -n "$FORM_API" ] || die "PREREQUIS : aucune API dans la liste du formulaire"
curl -sg "$JENKINS_UI/job/app-rollback/api/json?tree=property[parameterDefinitions[name,type]]" | grep -q '"name":"FORGE_TOKEN","type":"PasswordParameterDefinition"' && ok "0.18c app-rollback : FORGE_TOKEN (password) posé" || die "HYPOTHESE_AMORCAGE : app-rollback non amorcé"
curl -sg "$JENKINS_UI/job/selfservice-app-deploy/api/json?tree=property[parameterDefinitions[name,choices]]" | grep -q '"prod"' && ok "0.18d selfservice-app-deploy : ENVIRONMENT liste le terminus (build job: valide les choice — mesuré)" || die "HYPOTHESE_5 : la liste de l'aval ne porte pas le terminus — le dispatch de prod mourrait après la pause (amorcer l'aval)"
for u in alice bob carol oscar; do ensure_human "$u"; done; ok "0.19 alice/bob/carol/oscar : humains de forge, collaborateurs, tokens read:user+write:repository (GET /user ⇒ chacun)"
UP=$(gw "$GW_ADMIN/health" | jq_ "print((d.get('status') or {}).get('uptime','') if isinstance(d.get('status'),dict) else d.get('status',''))" 2>/dev/null || true); echo "  (10.15 : health $UP — keepalive ~20 min : un aval coupé en plein play est rejoué, annoncé)"
: > "$TMP/req.all.out"

echo "═══ 1. dev — alice demande (PR sous SON identité), alice merge, alice porte ═══"
palier dev 10.42.0.11 alice
[ "$(pr_field "$PR_N" "['user']['login']")" = alice ] && ok "1.1 PR #$PR_N ouverte SOUS alice (user.login), mergée par alice — $MS_N" || ko "1.1 auteur : $(pr_field "$PR_N" "['user']['login']")"
pr_body "$PR_N" | grep -q 'ouverte par : alice (identite de forge' && ok "1.2 corps : « ouverte par : alice (identite de forge …) »" || ko "1.2 corps sans identité de forge"
[ "$RES" = SUCCESS ] && ok "1.3 provision-apply #$N_PA SUCCESS (aval #$S_NUM)" || ko "1.3 provision-apply #$N_PA = $RES : $(grep -E 'REFUS' "$TMP/pa.$N_PA.console" "$TMP/ss.${S_NUM:-0}.console" 2>/dev/null | head -2 | tr '\n' ' ')"
console_order "$TMP/pa.$N_PA.console" 'RECONCILE_OK' 'PORTE_OK(pre)' 'Input requested' 'PORTE_OK(dispatch)' && ok "1.4 amont : RECONCILE_OK < PORTE_OK(pre) < pause < PORTE_OK(dispatch)" || ko "1.4 ordre de l'amont"
grep -q 'décidée par le token' "$TMP/ss.$S_NUM.console" && ! grep -q 'celle du manifeste mergé' "$TMP/ss.$S_NUM.console" && ok "1.5 aval dev : équipe décidée par le token (palier autonome — contrôle positif)" || ko "1.5 aval dev : $(grep -E 'équipe|décidée' "$TMP/ss.$S_NUM.console" | head -2 | tr '\n' ' ')"
G_APP=$(gw_app_id "$APP"); [ -n "$G_APP" ] || die "PREREQUIS : application $APP absente de la 10.15 après dev"
O1=$(gw_app_obj "$G_APP"); KEY1=$(obj_field "$O1" KEY); KEY_RAW=$(gw_key_raw "$G_APP")
[ "${#KEY_RAW}" -ge 32 ] && ok "1.6 la clé de l'application est NON VIDE (${#KEY_RAW} caractères — jamais imprimée)" || die "PREREQUIS : la 10.15 ne rend pas d'apiAccessKey sur l'objet (${#KEY_RAW}) — « clé jamais transportée » serait vacant"
read_step dev 10.42.0.11 1.7
pr_dashboard "$PR_N" 1.8 alice alice alice
PR_DEV="$PR_N"

echo "═══ 2. rec — alice / alice / alice (selfApproval) ═══"
palier rec 10.42.0.12 alice
[ "$RES" = SUCCESS ] && ok "2.1 provision-apply #$N_PA SUCCESS (aval #$S_NUM), PR #$PR_N sous alice" || ko "2.1 #$N_PA = $RES : $(grep -E 'REFUS' "$TMP/pa.$N_PA.console" "$TMP/ss.${S_NUM:-0}.console" 2>/dev/null | head -2 | tr '\n' ' ')"
read_step rec 10.42.0.12 2.2
pr_dashboard "$PR_N" 2.3 alice alice alice

echo "═══ 3. int — alice demande, bob merge, bob porte (déployeur NON-tenant : l'équipe vient de Git) ═══"
palier int 10.42.0.13 bob
[ "$RES" = SUCCESS ] && ok "3.1 provision-apply #$N_PA SUCCESS (aval #$S_NUM) — PR #$PR_N d'alice mergée par bob" || ko "3.1 #$N_PA = $RES : $(grep -E 'REFUS' "$TMP/pa.$N_PA.console" "$TMP/ss.${S_NUM:-0}.console" 2>/dev/null | head -2 | tr '\n' ' ')"
grep -q "PORTE_OK(dispatch)" "$TMP/pa.$N_PA.console" && grep -q "mergeur 'bob' ≠ demandeur 'alice'" "$TMP/pa.$N_PA.console" && ok "3.2 quatre yeux : mergeur bob ≠ demandeur alice (relus sur la forge)" || ko "3.2 quatre yeux : $(grep -E 'porte\(|quatre' "$TMP/pa.$N_PA.console" | head -2 | tr '\n' ' ')"
console_order "$TMP/ss.$S_NUM.console" "déclaration déployeur : 'bob' porte 'apply-int' (groupe 'apim-apply-int')" "équipe : '$TEAM' — celle du manifeste mergé (la porte vers int nomme le déployeur 'apim-apply-int') ; tenants du porteur : payments-team" "palier ouvert : envs/int/wm-admin" \
  && ok "3.3 aval : déclaration prouvée < équipe de Git (tenants du porteur : payments-team) < ticket int" || ko "3.3 aval : $(grep -E 'déclaration|équipe|palier ouvert' "$TMP/ss.$S_NUM.console" | head -3 | tr '\n' ' ')"
read_step int 10.42.0.13 3.4
pr_dashboard "$PR_N" 3.5 alice bob bob
# contre-épreuve inline : le FORMULAIRE sans FORGE_TOKEN ⇒ REQUESTER_UNKNOWN à la demande, rien poussé
NPR=$(prs_on_branch "provision/$APP-int"); BS=$(branch_sha "provision/$APP-int")
printf 'APP=%s\nREQ_ENV=int\nTEAM=%s\nAPI=%s\nMODE=idp\nCLIENT_ID=%s-int\nIP_ALLOWLIST=10.42.0.99\n' "$APP" "$TEAM" "$FORM_API" "$APP" | form_file "$TMP/f3.form"
form_build app-request "$TMP/f3.form"
[ "$FB_RES" = FAILURE ] && grep -q 'REFUS: REQUESTER_UNKNOWN' "$TMP/fb.app-request.$FB_NUM.console" && ! grep -q '\[1/4\]' "$TMP/fb.app-request.$FB_NUM.console" && [ "$(prs_on_branch "provision/$APP-int")" = "$NPR" ] && [ "$(branch_sha "provision/$APP-int")" = "$BS" ] \
  && ok "3.6 formulaire app-request #$FB_NUM sans FORGE_TOKEN vers int ⇒ FAILURE REQUESTER_UNKNOWN avant tout clone, PR et branche inchangées" || ko "3.6 app-request #$FB_NUM = $FB_RES : $(grep -E 'REFUS|ERROR' "$TMP/fb.app-request.$FB_NUM.console" | head -2 | tr '\n' ' ')"

echo "═══ 4. homol — GATE_REFS_REQUIRED sans pv_ref ; puis alice / carol / carol ═══"
NPR=$(prs_on_branch "provision/$APP-homol")
PRX=$(request_as alice homol 10.42.0.14); [ "$(cat "$TMP/req.rc")" = 2 ] && grep -q 'REFUS: GATE_REFS_REQUIRED' "$TMP/req.homol.out" && grep -q 'pv_ref' "$TMP/req.homol.out" && ! grep -q '\[1/4\]' "$TMP/req.homol.out" && [ "$(prs_on_branch "provision/$APP-homol")" = "$NPR" ] \
  && ok "4.1 demande homol sans pv_ref ⇒ GATE_REFS_REQUIRED (pv_ref) avant tout clone, aucune PR" || ko "4.1 rc $(cat "$TMP/req.rc") : $(grep -E 'REFUS|ERREUR' "$TMP/req.homol.out" | head -1)"
palier homol 10.42.0.14 carol "" PV-A7
[ "$RES" = SUCCESS ] && ok "4.2 provision-apply #$N_PA SUCCESS (aval #$S_NUM) — PR #$PR_N d'alice (pv_ref PV-A7) mergée par carol, portée par carol" || ko "4.2 #$N_PA = $RES : $(grep -E 'REFUS' "$TMP/pa.$N_PA.console" "$TMP/ss.${S_NUM:-0}.console" 2>/dev/null | head -2 | tr '\n' ' ')"
grep -q "déclaration déployeur : 'carol' porte 'apply-homol'" "$TMP/ss.$S_NUM.console" && grep -q "tenants du porteur : aucun" "$TMP/ss.$S_NUM.console" && ok "4.3 aval : carol porte apply-homol, tenants du porteur : aucun, équipe de Git" || ko "4.3 aval : $(grep -E 'déclaration|équipe' "$TMP/ss.$S_NUM.console" | head -2 | tr '\n' ' ')"
read_step homol 10.42.0.14 4.4
pr_dashboard "$PR_N" 4.5 alice carol carol
LAST_LINE_HOMOL=$(raw_at main "$MAN_DIR/$APP.ansible.yml" | grep -E '^    homol: ')
grep -q 'pv_ref: "PV-A7"' <<<"$LAST_LINE_HOMOL" && ok "4.6 main : per_env.homol porte pv_ref PV-A7" || ko "4.6 ligne homol : $LAST_LINE_HOMOL"

echo "═══ 5. prod — la porte du GOAL : ITSM, PAYLOAD_PERIME, API_NOT_PROMOTED, promotion par archive, API_INACTIVE au terminus, SUCCESS ═══"
# (a) CHG-0002 draft ⇒ ITSM_NOT_APPROVED sans pause
PR5A=$(request_as alice prod 10.42.0.15 CHG-0002 PV-A7); [ "$(cat "$TMP/req.rc")" = 0 ] && [ -n "$PR5A" ] || die "PREREQUIS : demande prod (CHG-0002) en échec : $(grep -E 'REFUS|ERREUR' "$TMP/req.prod.out" | head -1)"
PRS="$PRS $PR5A"; N_PA=$(jnext provision-apply); MS5A=$(merge_as oscar "$PR5A"); wait_amont "$N_PA" NOPAUSE
[ "$(jresult provision-apply "$N_PA")" = FAILURE ] && grep -q 'REFUS: ITSM_NOT_APPROVED' "$TMP/pa.$N_PA.console" && ! grep -q 'Input requested' "$TMP/pa.$N_PA.console" \
  && ok "5.1 PR #$PR5A (change_ref CHG-0002 draft) mergée par oscar ⇒ provision-apply #$N_PA FAILURE ITSM_NOT_APPROVED sans pause (le #26 de G7)" || ko "5.1 #$N_PA : $(jresult provision-apply "$N_PA") — $(grep -E 'REFUS|PORTE' "$TMP/pa.$N_PA.console" | head -2 | tr '\n' ' ')"
# (b) PAYLOAD_PERIME : une seconde PR prod (CHG-0001) OUVERTE, webhook forgé merged:true
PR5=$(request_as alice prod 10.42.0.15 CHG-0001 PV-A7); [ "$(cat "$TMP/req.rc")" = 0 ] && [ -n "$PR5" ] || die "PREREQUIS : demande prod (CHG-0001) en échec : $(grep -E 'REFUS|ERREUR' "$TMP/req.prod.out" | head -1)"
PRS="$PRS $PR5"; BR5="provision/$APP-prod"
MAIN_NOW=$(gapi "$API/repos/$GIT_REPO/branches/main" | jq_ "print(d['commit']['id'])")
N_SS_BEFORE=$(jnext selfservice-app-deploy)
python3 - "$BR5" "$PR5" "$MAIN_NOW" > "$TMP/forged.json" <<'PY'
import json, sys
print(json.dumps({"action": "closed", "pull_request": {"head": {"ref": sys.argv[1]}, "number": int(sys.argv[2]), "merged": True,
  "merged_by": {"login": "oscar"}, "user": {"login": "alice"}, "merge_commit_sha": sys.argv[3]}}))
PY
N_PA=$(fire_webhook "$TMP/forged.json"); [ -n "$N_PA" ] || die "BUILD_EN_FILE : le tir forgé n'a pas produit de build (HTTP $(cat "$TMP/wh.hc"))"
ST=$(wait_until 300 provision-apply "$N_PA" FINISHED); wait_built provision-apply "$N_PA" || true; sleep 3; jconsole provision-apply "$N_PA" > "$TMP/pa.$N_PA.console"
[ "$ST" != PAUSED_PENDING_INPUT ] && [ "$(jresult provision-apply "$N_PA")" = FAILURE ] && grep -q 'REFUS: PAYLOAD_PERIME' "$TMP/pa.$N_PA.console" && ! grep -q 'MERGE_IDENTITY_OK' "$TMP/pa.$N_PA.console" && ! grep -q 'aval selfservice-app-deploy #' "$TMP/pa.$N_PA.console" && [ "$(jnext selfservice-app-deploy)" = "$N_SS_BEFORE" ] \
  && ok "5.2 webhook FORGÉ (merged:true, SHA réel de main) sur la PR #$PR5 OUVERTE ⇒ #$N_PA FAILURE PAYLOAD_PERIME sans pause, aucun aval lancé (le #25 de G7)" || ko "5.2 #$N_PA : $ST / $(jresult provision-apply "$N_PA") — $(grep -E 'REFUS' "$TMP/pa.$N_PA.console" | head -1)"
[ "$(jname provision-apply "$N_PA")" = "apply $APP/prod (PR #$PR5)" ] && [ "$(t_app_count)" = "$T_COUNT0" ] && ok "5.2b build nommé « apply $APP/prod (PR #$PR5) », terminus : compte d'applications inchangé ($T_COUNT0)" || ko "5.2b nom '$(jname provision-apply "$N_PA")' / terminus $(t_app_count) ≠ $T_COUNT0"
pr_comments "$PR5" > "$TMP/c5.forged"; grep -q 'REFUSÉ avant la pause' "$TMP/c5.forged" && grep -q 'PAYLOAD_PERIME' "$TMP/c5.forged" && ok "5.2c PR #$PR5 : « Apply REFUSÉ avant la pause — PAYLOAD_PERIME » commenté" || ko "5.2c commentaire : $(grep -E 'Apply' "$TMP/c5.forged" | head -1)"
# (c) merge oscar ⇒ ITSM approved, plus de TERMINUS_SANS_VOIE, pause, oscar ⇒ aval API_NOT_PROMOTED (terminus vide), rien écrit
N_PA=$(jnext provision-apply); MS5=$(merge_as oscar "$PR5"); wait_amont "$N_PA" PAUSE
console_order "$TMP/pa.$N_PA.console" 'RECONCILE_OK' "itsm : change 'CHG-0001' approved" 'PORTE_OK(pre)' 2>/dev/null || jconsole provision-apply "$N_PA" > "$TMP/pa.$N_PA.console"
console_order "$TMP/pa.$N_PA.console" 'RECONCILE_OK' "itsm : change 'CHG-0001' approved" 'PORTE_OK(pre)' 'Input requested' && ! grep -q 'TERMINUS_SANS_VOIE' "$TMP/pa.$N_PA.console" \
  && ok "5.3 PR #$PR5 mergée par oscar ⇒ #$N_PA : RECONCILE_OK < ITSM approved < PORTE_OK(pre) < pause — plus de TERMINUS_SANS_VOIE (la voie est déclarée)" || ko "5.3 amont : $(grep -E 'REFUS|PORTE|itsm' "$TMP/pa.$N_PA.console" | head -3 | tr '\n' ' ')"
answer_pause "$N_PA" oscar "$LAB_OSCAR_PASS"; finish_amont "$N_PA"
[ "$RES" = FAILURE ] && [ -n "$S_NUM" ] && grep -q 'REFUS: API_NOT_PROMOTED' "$TMP/ss.$S_NUM.console" && grep -q "$TERMINUS_ADMIN" "$TMP/ss.$S_NUM.console" \
  && ok "5.4 oscar répond ⇒ aval #$S_NUM FAILURE REFUS: API_NOT_PROMOTED citant la base du TERMINUS ($TERMINUS_ADMIN) — « une application dont l'API n'est qu'en homol ne peut pas atteindre prod »" || ko "5.4 aval #${S_NUM:-?} : $RES — $(grep -E 'REFUS|PALIER_BASE' "$TMP/ss.${S_NUM:-0}.console" 2>/dev/null | head -2 | tr '\n' ' ')"
console_order "$TMP/ss.$S_NUM.console" "déclaration déployeur : 'oscar' porte 'operator-deploy'" "équipe : '$TEAM' — celle du manifeste mergé (la porte vers prod nomme le déployeur 'apim-operator-prod') ; tenants du porteur : aucun" "palier ouvert : envs/prod/wm-admin" "PALIER_BASE=$TERMINUS_ADMIN" "PALIER_VIA=direct" "préflight de joignabilité : $TERMINUS_ADMIN/health" \
  && ok "5.5 garde du terminus : oscar porte operator-deploy (prouvé) < équipe de Git (tenants : aucun) < ticket envs/prod/wm-admin < voie directe sur le terminus < préflight" || ko "5.5 garde : $(grep -E 'équipe|déclaration|PALIER_VIA|PALIER_BASE|palier ouvert|préflight' "$TMP/ss.$S_NUM.console" | head -6 | tr '\n' ' ')"
gw "$GW_ADMIN/apis" | A="$G_API" jq_ "import os
print('ACTIVE' if any((i.get('api',i).get('id')==os.environ['A'] and i.get('api',i).get('isActive') is True) for i in d.get('apiResponse',[])) else 'NON')" | grep -q ACTIVE && [ "$(t_app_count)" = "$T_COUNT0" ] && [ -z "$(t_app_id "$APP")" ] \
  && ok "5.6 à cet instant : G_API active sur la 10.15, ABSENTE du terminus — rien écrit sur le terminus (compte $T_COUNT0, pas de $APP)" || ko "5.6 terminus : $(t_app_count) applications, $APP=$(t_app_id "$APP")"
pr_comments "$PR5" > "$TMP/c5"; grep -q 'API_NOT_PROMOTED' "$TMP/c5" && grep -q "L'ordre app/API" "$TMP/c5" && grep -q "promote/${REQ_API}-prod" "$TMP/c5" && ok "5.7 PR #$PR5 : ❌ API_NOT_PROMOTED, « L'ordre app/API », remède promote/${REQ_API}-prod nommé" || ko "5.7 commentaires : $(grep -E 'API_NOT|ordre|promote' "$TMP/c5" | head -2 | tr '\n' ' ')"
# (d) le geste PRODUCTEUR : promouvoir l'API au terminus par ARCHIVE (export 10.15 → import terminus, même GUID)
curl -s -m 60 -K "$TMP/wm.cfg" -H 'Accept: application/zip' -o "$TMP/export.zip" -w '%{http_code}' "$GW_ADMIN/archive?apis=$G_API" > "$TMP/export.hc"; [ "$(cat "$TMP/export.hc")" = 200 ] && [ -s "$TMP/export.zip" ] && python3 -c 'import sys,zipfile;zipfile.ZipFile(sys.argv[1]).testzip()' "$TMP/export.zip" 2>/dev/null || die "PREREQUIS : export de $G_API depuis la 10.15 (HTTP $(cat "$TMP/export.hc"), $(file -b "$TMP/export.zip" 2>/dev/null | cut -c1-60))"
# umask 077 rend l'export 0600 : docker cp conserve le mode et le curl du conteneur (jenkins) ne
# pourrait pas l'ouvrir (curl 26, aucune requête) — l'archive est publique (aucun secret) : 0644.
chmod 644 "$TMP/export.zip"
docker cp "$TMP/export.zip" "$JENKINS_CONTAINER:/tmp/a7-export-$TS.zip" >/dev/null 2>&1 || die "PREREQUIS : docker cp vers $JENKINS_CONTAINER"
tcall POST /archive "@/tmp/a7-export-$TS.zip"; docker exec -u root "$JENKINS_CONTAINER" rm -f "/tmp/a7-export-$TS.zip" 2>/dev/null || docker exec "$JENKINS_CONTAINER" rm -f "/tmp/a7-export-$TS.zip" 2>/dev/null
TA=$(t_api "$REQ_API" "$REQ_API_VER")
[ "$(tcode)" = 200 ] && [ "${TA%% *}" = "$G_API" ] && [ "${TA#* }" = True ] && ok "5.8 geste producteur : archive 10.15 → terminus (HTTP 200) ⇒ l'API porte le MÊME GUID $G_API sur le terminus, isActive True (le verbe ADR-079, sens réel→mock)" || die "PREREQUIS : import au terminus (HTTP $(tcode) : $(head -c 300 "$TMP/t.body" | tr '\n' ' ')) — terminus : '$TA' (attendu $G_API True ; jamais un activate silencieux)"
# (d') API_INACTIVE au terminus : la porte lit isActive DU TERMINUS
tcall PUT "/apis/$G_API/deactivate"; [ "$(tcode)" = 200 ] || die "PREREQUIS : désactivation de $G_API sur le terminus (HTTP $(tcode))"
replay_pr "$PR5" "$BR5" "$MS5" oscar alice; wait_amont "$N_PA" PAUSE; answer_pause "$N_PA" oscar "$LAB_OSCAR_PASS"; finish_amont "$N_PA"
[ "$RES" = FAILURE ] && grep -q 'REFUS: API_INACTIVE' "$TMP/ss.$S_NUM.console" && grep -q "id=$G_API" "$TMP/ss.$S_NUM.console" && [ -z "$(t_app_id "$APP")" ] \
  && ok "5.9 API désactivée SUR LE TERMINUS ⇒ rejeu ⇒ aval #$S_NUM API_INACTIVE citant id=$G_API (la porte lit isActive du terminus, pas de la 10.15), rien écrit" || ko "5.9 aval #${S_NUM:-?} : $RES — $(grep -E 'REFUS' "$TMP/ss.${S_NUM:-0}.console" 2>/dev/null | head -1)"
tcall PUT "/apis/$G_API/activate"; [ "$(tcode)" = 200 ] && [ "$(t_api "$REQ_API" "$REQ_API_VER")" = "$G_API True" ] || die "PREREQUIS : réactivation de $G_API sur le terminus"
# (e) rejeu du webhook ⇒ pause ⇒ oscar ⇒ SUCCESS sur le terminus
replay_pr "$PR5" "$BR5" "$MS5" oscar alice; wait_amont "$N_PA" PAUSE
console_order "$TMP/pa.$N_PA.console" 'RECONCILE_OK' "itsm : change 'CHG-0001' approved" 'PORTE_OK(pre)' 'Input requested' 2>/dev/null || jconsole provision-apply "$N_PA" > "$TMP/pa.$N_PA.console"
grep -q "$MS5" "$TMP/pa.$N_PA.console" && console_order "$TMP/pa.$N_PA.console" 'RECONCILE_OK' "itsm : change 'CHG-0001' approved" 'PORTE_OK(pre)' 'Input requested' && ok "5.10 rejeu #$N_PA : même MERGE_SHA ($MS5), ITSM re-vérifié, PORTE_OK(pre), pause" || ko "5.10 rejeu : $(grep -E 'REFUS|PORTE|itsm' "$TMP/pa.$N_PA.console" | head -2 | tr '\n' ' ')"
answer_pause "$N_PA" oscar "$LAB_OSCAR_PASS"; finish_amont "$N_PA"
[ "$RES" = SUCCESS ] && console_order "$TMP/ss.$S_NUM.console" "API_AT_PALIER" "TEAM_CONFIRMED" "SUBSCRIPTION_CONFIRMED (id=$G_API)" \
  && ok "5.11 aval #$S_NUM SUCCESS : API_AT_PALIER < TEAM_CONFIRMED < SUBSCRIPTION_CONFIRMED (id=$G_API) — l'application est au terminus" || ko "5.11 aval #${S_NUM:-?} : $RES — $(grep -E 'REFUS|CONFIRMED' "$TMP/ss.${S_NUM:-0}.console" 2>/dev/null | head -3 | tr '\n' ' ')"
G_APP_T=$(t_app_id "$APP"); [ -n "$G_APP_T" ] || die "PREREQUIS : $APP absente du terminus après SUCCESS"
OT=$(t_app_obj "$G_APP_T")
[ "$G_APP_T" != "$G_APP" ] && case ",$(obj_field "$OT" SUBS)," in *",$G_API,"*) ok "5.12 terminus : application $G_APP_T (≠ $G_APP : deux gateways, deux objets), souscrite à G_API $G_API";; *) ko "5.12 SUBS terminus : $(obj_field "$OT" SUBS)";; esac
case "$(obj_field "$OT" CLAIM)" in *"${APP}-prod"*) ok "5.13 terminus : claim ${APP}-prod";; *) ko "5.13 claim terminus : $(obj_field "$OT" CLAIM)";; esac
case ",$(obj_field "$OT" TEAMS)," in *",$TEAM,"*) case ",$(obj_field "$OT" TEAMS)," in *",Default,"*) ko "5.14 Default encore présente au terminus";; *) ok "5.14 terminus : teams ∋ $TEAM ∌ Default";; esac;; *) ko "5.14 teams terminus : $(obj_field "$OT" TEAMS)";; esac
[ "$(obj_field "$OT" HASKEY)" = 0 ] && ok "5.15 terminus : aucune apiAccessKey mintée par le mock (limite écrite : ce lab prouve « la clé de la 10.15 n'est jamais transportée », pas « une clé par gateway »)" || ok "5.15 terminus : une clé est présente (le mock en mint désormais une)"
pr_dashboard "$PR5" 5.16 alice oscar oscar
PR_PROD="$PR5"

echo "═══ 6. La porte, lue : cinq paliers dans Git, cinq client_id, G_API 2/2, G_APP/clé stables, clé jamais transportée ═══"
raw_at main "$MAN_DIR/$APP.ansible.yml" > "$TMP/man.main.yml"
ENVS_MAIN=$(python3 -c 'import yaml,sys;d=yaml.safe_load(open(sys.argv[1]));pe=d["apim_ss_app"]["per_env"];print(" ".join(pe.keys()))' "$TMP/man.main.yml" 2>/dev/null)
CIDS=$(python3 -c 'import yaml,sys;d=yaml.safe_load(open(sys.argv[1]));pe=d["apim_ss_app"]["per_env"];print(len(set(v["auth"]["claim"]["value"] for v in pe.values())))' "$TMP/man.main.yml" 2>/dev/null)
[ "$ENVS_MAIN" = "dev rec int homol prod" ] && [ "$CIDS" = 5 ] && ok "6.1 main : per_env = dev rec int homol prod, cinq client_id distincts" || ko "6.1 main : per_env=[$ENVS_MAIN] client_id distincts=$CIDS"
O6=$(gw_app_obj "$G_APP"); [ "$(obj_field "$O6" GUID)" = "$G_APP" ] && [ "$(obj_field "$O6" KEY)" = "$KEY1" ] && case "$(obj_field "$O6" CLAIM)" in *"${APP}-homol"*) ok "6.2 10.15 : G_APP et clé stables sur les quatre applies, claim = ${APP}-homol (mono-gateway : le dernier palier non terminal)";; *) ko "6.2 claim 10.15 : $(obj_field "$O6" CLAIM)";; esac || ko "6.2 GUID/clé 10.15 ont bougé"
[ "$(t_api "$REQ_API" "$REQ_API_VER")" = "$G_API True" ] && ok "6.3 G_API $G_API identique sur les DEUX gateways (10.15 et terminus) — « GUID identique » par le verbe archive" || ko "6.3 terminus : $(t_api "$REQ_API" "$REQ_API_VER")"
# la clé de la 10.15, JAMAIS transportée : 0 occurrence dans les corps de PR, tous les commentaires, toutes les consoles
: > "$TMP/haystack"
for n in $PRS; do pr_body "$n" >> "$TMP/haystack"; pr_comments "$n" >> "$TMP/haystack"; done
cat "$TMP"/pa.*.console "$TMP"/ss.*.console "$TMP"/fb.*.console "$TMP/req.all.out" >> "$TMP/haystack" 2>/dev/null
[ "${#KEY_RAW}" -ge 32 ] && [ "$(grep -c -F -- "$KEY_RAW" "$TMP/haystack")" = 0 ] && ok "6.4 clé jamais transportée : 0 occurrence de la clé (${#KEY_RAW} car.) dans $(printf '%s' "$PRS" | wc -w | tr -d ' ') PR (corps + commentaires), les consoles amont/aval/formulaires et les sorties de demande" || ko "6.4 la clé apparaît $(grep -c -F -- "$KEY_RAW" "$TMP/haystack") fois"
LK=$(vcurl -X LIST "$VAULT_ADDR_LAB/v1/secret/metadata/stoa/deploy/$TEAM/apps" | jq_ "print(' '.join((d.get('data') or {}).get('keys') or []))" 2>/dev/null || true)
case " $LK " in *" $APP/"*|*" $APP "*) ko "6.5 Vault : une entrée sous deploy/$TEAM/apps/$APP (mode idp : aucun secret attendu)";; *) ok "6.5 Vault : rien sous deploy/$TEAM/apps pour $APP (mode idp — entrées voisines : ${LK:-aucune})";; esac

echo "═══ 7. Le formulaire app-request : rec sous alice avec refs ; int sans token ; homol sans PV ; TOKEN_ALTERE ═══"
printf 'APP=%s\nREQ_ENV=rec\nTEAM=%s\nAPI=%s\nMODE=idp\nCLIENT_ID=%s-rec\nIP_ALLOWLIST=10.42.0.21\nFORGE_TOKEN=%s\nCHANGE_REF=CHG-0001\nPV_REF=PV-A7\n' "$APPF" "$TEAM" "$FORM_API" "$APPF" "$(cat "$TMP/alice.tok")" | form_file "$TMP/f7a.form"
form_build app-request "$TMP/f7a.form"
PRF=$(grep -oE 'PR_URL=[^ ]*/pulls/[0-9]+' "$TMP/fb.app-request.$FB_NUM.console" | grep -oE '[0-9]+$' | tail -1); [ -n "$PRF" ] && PRS="$PRS $PRF"
[ "$FB_RES" = SUCCESS ] && [ -n "$PRF" ] && [ "$(pr_field "$PRF" "['user']['login']")" = alice ] && raw_at "provision/$APPF-rec" "$MAN_DIR/$APPF.ansible.yml" | grep -E '^    rec: ' | grep -q 'change_ref: "CHG-0001", pv_ref: "PV-A7"' \
  && ok "7.1 app-request #$FB_NUM (rec, FORGE_TOKEN d'alice, CHANGE_REF, PV_REF) ⇒ SUCCESS, PR #$PRF SOUS alice, ligne rec avec les deux refs" || ko "7.1 app-request #$FB_NUM = $FB_RES PR=${PRF:-aucune} : $(grep -E 'REFUS|ERROR' "$TMP/fb.app-request.$FB_NUM.console" | head -2 | tr '\n' ' ')"
! grep -q "$(cat "$TMP/alice.tok")" "$TMP/fb.app-request.$FB_NUM.console" && ok "7.1b la console du build ne porte pas le token" || ko "7.1b le token apparaît dans la console"
[ -n "$PRF" ] && { pr_comments "$PRF" | grep -q 'provision-plan' && ok "7.1c PR #$PRF : plan enchaîné commenté (sous le compte de service)" || ko "7.1c plan absent"; close_pr "$PRF" >/dev/null; }
printf 'APP=%s\nREQ_ENV=homol\nTEAM=%s\nAPI=%s\nMODE=idp\nCLIENT_ID=%s-homol\nFORGE_TOKEN=%s\n' "$APPF" "$TEAM" "$FORM_API" "$APPF" "$(cat "$TMP/alice.tok")" | form_file "$TMP/f7c.form"
form_build app-request "$TMP/f7c.form"
[ "$FB_RES" = FAILURE ] && grep -q 'REFUS: GATE_REFS_REQUIRED' "$TMP/fb.app-request.$FB_NUM.console" && ! grep -q '\[1/4\]' "$TMP/fb.app-request.$FB_NUM.console" && ok "7.2 app-request #$FB_NUM (homol, token, sans PV_REF) ⇒ FAILURE GATE_REFS_REQUIRED avant tout clone" || ko "7.2 #$FB_NUM = $FB_RES : $(grep -E 'REFUS|ERROR' "$TMP/fb.app-request.$FB_NUM.console" | head -1)"
printf 'APP=%s\nREQ_ENV=rec\nTEAM=%s\nAPI=%s\nMODE=idp\nCLIENT_ID=%s-rec\nFORGE_TOKEN=${JENKINS_HOME}x\n' "$APPF" "$TEAM" "$FORM_API" "$APPF" | form_file "$TMP/f7d.form"
form_build app-request "$TMP/f7d.form"
[ "$FB_RES" = FAILURE ] && grep -q 'TOKEN_ALTERE' "$TMP/fb.app-request.$FB_NUM.console" && ! grep -q 'provision-request.sh' "$TMP/fb.app-request.$FB_NUM.console" && ok "7.3 app-request #$FB_NUM avec FORGE_TOKEN='\${JENKINS_HOME}x' ⇒ FAILURE TOKEN_ALTERE, rien tenté" || ko "7.3 #$FB_NUM = $FB_RES : $(grep -E 'REFUS|ERROR' "$TMP/fb.app-request.$FB_NUM.console" | head -1)"

echo "═══ 8. Le repli au terminus par le même formulaire ⇒ ETAT_IDENTIQUE (N et N-1 ne diffèrent que par change_ref) ═══"
NPR=$(prs_on_branch "provision/$APP-prod")
printf 'APP=%s\nENV=prod\nREASON=preuve A7 : repli au terminus\nCHANGE_REF=CHG-0001\nFORGE_TOKEN=%s\n' "$APP" "$(cat "$TMP/alice.tok")" | form_file "$TMP/f8.form"
form_build app-rollback "$TMP/f8.form"
[ "$FB_RES" = FAILURE ] && grep -q 'REFUS: ETAT_IDENTIQUE' "$TMP/fb.app-rollback.$FB_NUM.console" && grep -q '^ETAPE lignee' "$TMP/fb.app-rollback.$FB_NUM.console" && ! grep -q '^ETAPE pr$' "$TMP/fb.app-rollback.$FB_NUM.console" && [ "$(prs_on_branch "provision/$APP-prod")" = "$NPR" ] \
  && ok "8.1 app-rollback #$FB_NUM (prod, CHG-0001, token d'alice) ⇒ FAILURE ETAT_IDENTIQUE après ETAPE lignee — le terminus reçoit ses replis et refuse juste, aucune PR" || ko "8.1 app-rollback #$FB_NUM = $FB_RES : $(grep -E 'REFUS|ETAPE' "$TMP/fb.app-rollback.$FB_NUM.console" | tail -2 | tr '\n' ' ')"

echo
echo "═══════════════════════════════════════════════════"
printf 'RÉSULTAT : %d/%d — G_API=%s G_APP=%s G_APP_T=%s PR=%s\n' "$PASS" $((PASS + FAIL)) "$G_API" "$G_APP" "$G_APP_T" "$(printf '%s' "$PRS" | sed 's/^ //')"
[ "$FAIL" -eq 0 ] || exit 1
