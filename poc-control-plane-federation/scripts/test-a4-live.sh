#!/usr/bin/env bash
# test-a4-live.sh — la PORTE et les CONTRE-ÉPREUVES d'A4 (GOAL cd-applications :
# les portes de la chaîne et l'axe déployeur au dispatch de provision-apply), par
# BUILDS RÉELS sur le lab : Gitea + Jenkins + Vault + annuaire LDAP + itsm-mock +
# la 10.15 réelle. Spec : docs/superpowers/specs/2026-09-02-a4-portes-de-la-chaine-au-dispatch-design.md (D7).
#
#   1. rec par alice (PR ouverte ET mergée par alice) ⇒ la porte ADMET
#      (selfApproval) : PORTE_OK(pre), pause, PORTE_OK(dispatch), « auto-approbation
#      admise », SUCCESS, application <app> claim <app>-rec, PR ✅ « porte du palier ».
#   2. int par ci (la voie livrée : provision-request.sh ouvre la PR sous ci),
#      mergée par alice ⇒ FAILURE SANS PAUSE `REQUESTER_UNKNOWN` — la limite des
#      voies livrées est MESURÉE, plus un silence.
#   3. int par alice, mergée par alice ⇒ FAILURE SANS PAUSE `FOUR_EYES_VIOLATION`.
#   4. int par carol (un autre humain — ce que « même équipe » ne vérifie PAS),
#      mergée par alice ⇒ pause ⇒ alice ⇒ aval FAILURE `DEPLOYER_GROUP_REQUIRED`
#      (aucun ticket, aucun préflight, aucun play, token révoqué), PR ❌ nommée.
#   5. alice ∈ apim-apply-int (LDAP, restauré par trap) ⇒ la CHAÎNE ENTIÈRE d'un
#      palier déclaré : pause ⇒ aval SUCCESS « déclaration déployeur : 'alice'
#      porte 'apply-int' » < ticket < préflight < converge < verify, PR ✅
#      « porteur attendu apim-apply-int → apply-int » ; l'application porte
#      désormais la claim <app>-int (mono-gateway : int ÉCRASE rec — mesuré).
#      Alice retirée ⇒ build direct de l'aval ⇒ FAILURE `DEPLOYER_GROUP_REQUIRED`.
#   6. homol par carol ⇒ FAILURE SANS PAUSE `GATE_REFS_REQUIRED` (pv_ref).
#   7. prod (manifeste ⊕ per_env.prod par la lib, poussé par l'API sous carol) :
#      CHG-0002 draft ⇒ `ITSM_NOT_APPROVED` ; CHG-0001 approved ⇒ « itsm : change
#      approved » PUIS `TERMINUS_SANS_VOIE` — ITSM au terminus, avant la voie,
#      personne réveillé.
#
# ── COMMENT UN HUMAIN OUVRE UNE PR « EXACTE » ────────────────────────────────
# provision-request.sh (token ci, manifeste SANS team) pousse la branche et ouvre
# sa PR ; la suite FERME cette PR sans la merger et l'humain en ouvre une autre
# sur LA MÊME BRANCHE avec SON token (user.login = l'humain, contenu = ce que la
# chaîne écrit — aucun CONTRAT_DIVERGENT au rejeu). Seul le terminus, que
# provision-request.sh refuse par structure, est produit par la lib.
#
# ── FAIL-CLOSED, JAMAIS DE SKIP MUET ────────────────────────────────────────
# Prérequis manquant ⇒ exit 1 `LAB_ABSENT : …` ou `PREREQUIS : …`.
#
# ── CE QUE CE SCRIPT ÉCRIT DANS LE LAB, ET CE QU'IL REMET ────────────────────
# Lab PARTAGÉ : PR provision/* jetables MERGÉES (main reçoit et perd un
# manifeste jetable), UNE application jetable sur la gateway réelle (supprimée),
# alice ajoutée puis RETIRÉE de cn=apim-apply-int (MUTATED posé AVANT la
# mutation, trap), comptes Gitea alice/carol créés s'ils manquent (conservés,
# comme A2/A3), tokens jetables. Ne draine que SES pauses.
#
# Entrées (env) — OBLIGATOIRES, sans défaut vers un système en service :
#   JENKINS_UI GITEA_URL GW_ADMIN WM_USER WM_PASS
#   LAB_ALICE_PASS  (ou lu dans ./.env.lab-users s'il existe)
#   VAULT_TOKEN     (root de lab ; ou lu dans le conteneur poc-vault)
# Optionnelles : GITEA_TOKEN_FILE GITEA_CONTAINER GIT_REPO EXPECT_ADMIN_VIA
#   REQ_API REQ_API_VER VAULT_ADDR_LAB VAULT_CONTAINER LDAP_CONTAINER
#   LDAP_ADMIN_PASSWORD JENKINS_CONTAINER ITSM_URL_LOCAL
#
#   JENKINS_UI=http://localhost:18080 GITEA_URL=http://localhost:13000 \
#   GW_ADMIN=http://localhost:5555/rest/apigateway WM_USER=Administrator WM_PASS=manage \
#     bash scripts/test-a4-live.sh
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
LDAP_CONTAINER="${LDAP_CONTAINER:-poc-openldap}"
BASE_DN="${LDAP_BASE_DN:-dc=corp,dc=example}"
BIND_DN="${LDAP_BIND_DN:-cn=admin,$BASE_DN}"
BIND_PW="${LDAP_ADMIN_PASSWORD:-admin-lab-2026}"
JENKINS_CONTAINER="${JENKINS_CONTAINER:-poc-jenkins}"
ITSM_URL_LOCAL="${ITSM_URL_LOCAL:-http://localhost:8788}"
EXPECT_ADMIN_VIA="${EXPECT_ADMIN_VIA:-direct}"
REQ_API="${REQ_API:-demo-selfservice}"
REQ_API_VER="${REQ_API_VER:-1.0.0}"
TENANT="${A4_TENANT:-banking-demo}"
MAN_DIR="poc-control-plane-federation/clients/provisioned/applications"
SUBDIR="poc-control-plane-federation"

TS="$(date +%s)"
TMP="$(mktemp -d)"; umask 077
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
die(){ printf '\n%s\n' "$*" >&2; exit 1; }

APP="a4p$TS"
CI_TOKEN=""
MUTATED=0            # posé à 1 AVANT la mutation LDAP (le trap restaure sans condition alors)
APP_ID=""
PRS=""               # numéros de PR ouverts par la suite (fermés en fin)
API="$GITEA_URL/api/v1"
VHDR="$TMP/vhdr"; printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN" > "$VHDR"
vcurl(){ curl -s -m 20 -H @"$VHDR" "$@"; }

# ── helpers Gitea (token en EN-TÊTE via fichier, jamais en argv) ─────────────
gapi(){ curl -s -H @"$TMP/ci.hdr" -H 'Content-Type: application/json' "$@"; }
aapi(){ curl -s -H @"$TMP/alice.hdr" -H 'Content-Type: application/json' "$@"; }
capi(){ curl -s -H @"$TMP/carol.hdr" -H 'Content-Type: application/json' "$@"; }
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
  tok=$(docker exec -u git "$GITEA_CONTAINER" gitea admin user generate-access-token --username "$u" --token-name "a4-live-$u-$TS" --scopes write:repository,write:issue 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
  [ -n "$tok" ] || die "PREREQUIS : token Gitea de $u non minté"
  printf 'Authorization: token %s\n' "$tok" > "$hdr"; chmod 600 "$hdr"
}
# request_branch <env> <ip> → "<PR de ci> <branche>" (la demande de la CHAÎNE, sous ci, manifeste sans team)
request_branch(){
  local e="$1" ip="$2" out rc pr
  out=$(GITEA_TOKEN="$CI_TOKEN" GIT_HOST="$GITEA_URL" GIT_WEB_HOST="$GITEA_URL" GIT_REPO="$GIT_REPO" PROVISION_PLAN_INLINE=false \
        REQ_APP="$APP" REQ_ENV="$e" REQ_API="$REQ_API" REQ_API_VER="$REQ_API_VER" REQ_CALLER=oig-provisioner \
        REQ_CLIENT_ID="${APP}-${e}" REQ_IP_ALLOWLIST="$ip" bash scripts/provision-request.sh 2>&1); rc=$?
  pr=$(printf '%s' "$out" | grep -oE 'PR_URL=[^ ]*/pulls/[0-9]+' | grep -oE '[0-9]+$' | tail -1)
  [ "$rc" -eq 0 ] && [ -n "$pr" ] || die "PREREQUIS : demande $e en échec (rc=$rc) : $(printf '%s' "$out" | tail -4 | tr '\n' ' ')"
  printf '%s provision/%s-%s' "$pr" "$APP" "$e"
}
# reopen_as <hdr> <login> <pr-ci> <branche> → numéro de la PR de l'humain (la PR de ci est FERMÉE, jamais mergée)
reopen_as(){
  local hdr="$1" who="$2" prci="$3" br="$4" hc n
  hc=$(close_pr "$prci"); [ "$hc" = 201 ] || [ "$hc" = 200 ] || die "PREREQUIS : fermeture de la PR #$prci de ci refusée (HTTP $hc)"
  n=$(curl -s -H @"$hdr" -H 'Content-Type: application/json' -X POST -d "{\"head\":\"$br\",\"base\":\"main\",\"title\":\"provision($who): ${br#provision/}\"}" "$API/repos/$GIT_REPO/pulls" | jq_ "print(d.get('number',''))")
  [ -n "$n" ] || die "PREREQUIS : PR de $who sur $br non ouverte"
  [ "$(pr_field "$n" "['user']['login']")" = "$who" ] || die "PREREQUIS : la PR #$n n'a pas $who pour auteur"
  PRS="$PRS $n"; printf '%s' "$n"
}
# merge_as_alice <pr> → MERGE_SHA
merge_as_alice(){
  local pr="$1" dl m hc
  dl=$(( $(date +%s) + 45 )); m=false
  while [ "$(date +%s)" -lt "$dl" ]; do m=$(pr_field "$pr" ".get('mergeable')"); [ "$m" = True ] && break; sleep 1; done
  [ "$m" = True ] || die "PREREQUIS : PR #$pr non mergeable"
  # Gitea répond 405 « Please try again later » tant que son contrôle de merge
  # n'est pas fini — `mergeable: true` ne le garantit pas (mesuré, passage 3) :
  # rejeu jusqu'à 12 fois, 5 s d'écart.
  local try=0
  while :; do
    hc=$(aapi -X POST -d '{"Do":"merge"}' -o "$TMP/merge.out" -w '%{http_code}' "$API/repos/$GIT_REPO/pulls/$pr/merge")
    [ "$hc" = 200 ] && break
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
jstage(){ # <job> <build> <fragment du nom de stage> → statut du stage (wfapi/describe)
  curl -s "$JENKINS_UI/job/$1/$2/wfapi/describe" | F="$3" jq_ "import os
print(next((s.get('status','') for s in d.get('stages',[]) if os.environ['F'] in s.get('name','')), ''))" 2>/dev/null || true; }
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
form_file(){ # <fichier> puis paires clé=valeur sur STDIN → urlencodé (urlencode EXIGE des tuples — piège A3)
  python3 -c 'import os,sys,urllib.parse
pairs=[tuple(l.split("=",1)) for l in sys.stdin.read().splitlines() if "=" in l]
fd=os.open(sys.argv[1], os.O_WRONLY|os.O_CREAT|os.O_TRUNC, 0o600)
with os.fdopen(fd,"w") as f: f.write(urllib.parse.urlencode(pairs))' "$1"
  [ -s "$1" ] && grep -q 'VAULT_USER=alice' "$1" || die "HARNAIS : formulaire de build non écrit ($1)"
}
# run_apply <pr> <merge_sha> <attendu : PAUSE|NOPAUSE> → N_PA (le build amont) ; console amont dans $TMP/pa.<N>.console
N_PA=""; S_NUM=""
wait_amont(){ # <N_PA> <PAUSE|NOPAUSE>
  local n="$1" st
  if [ "$2" = PAUSE ]; then
    st=$(wait_until 300 provision-apply "$n" PAUSED_PENDING_INPUT) || die "PREREQUIS : provision-apply #$n n'atteint pas la pause ($st) — $(jconsole provision-apply "$n" | grep -E 'REFUS|error' | tail -2 | tr '\n' ' ')"
  else
    st=$(wait_until 300 provision-apply "$n" FINISHED)
    jconsole provision-apply "$n" > "$TMP/pa.$n.console"
  fi
}
# finish_amont <N_PA> : pose RES (résultat de l'amont) et S_NUM (build aval) en
# GLOBALES — jamais appelée en $( ) : une variable posée dans un sous-shell meurt
# avec lui (mesuré au passage 2 : S_NUM vide, 1.7/4.6 vacants).
RES=""
finish_amont(){
  local n="$1"
  wait_until 1800 provision-apply "$n" FINISHED >/dev/null
  jconsole provision-apply "$n" > "$TMP/pa.$n.console"
  S_NUM=$(grep -oE "aval selfservice-app-deploy #[0-9]+" "$TMP/pa.$n.console" | grep -oE '[0-9]+$' | head -1)
  [ -n "$S_NUM" ] && jconsole selfservice-app-deploy "$S_NUM" > "$TMP/ss.$S_NUM.console"
  RES=$(jresult provision-apply "$n")
}
console_order(){ # <fichier console> <motif1> <motif2> … → OK si chaque motif apparaît, dans l'ordre
  local f="$1" prev=0 l; shift
  for m in "$@"; do l=$(grep -n -F -- "$m" "$f" | head -1 | cut -d: -f1); [ -n "$l" ] && [ "$l" -gt "$prev" ] || return 1; prev=$l; done
  return 0
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
gw_app_ip(){ printf '%s' "$1" | python3 -c "import json,sys
a=json.load(sys.stdin)
for i in a.get('identifiers') or []:
    if i.get('key')=='ipAddressRange': print(','.join(i.get('value') or [])); break" 2>/dev/null; }
gw_app_claims(){ printf '%s' "$1" | python3 -c "import json,sys
a=json.load(sys.stdin)
for i in a.get('identifiers') or []:
    if i.get('key')=='openIdClaims': print(','.join(i.get('value') or [])); break" 2>/dev/null; }
gw_state(){ local j; j=$(gw_app "$APP"); printf '%s|%s' "$(gw_app_claims "$j")" "$(gw_app_ip "$j")"; }
# ── helpers LDAP (motif test-deployer-gate-live.sh : bind par fichier, jamais argv) ──
ldap_run(){ # <ldapadd|ldapmodify|ldapsearch> [args…] < LDIF — verbatim test-deployer-gate-live.sh (sh POSIX du conteneur : shift 2, jamais ${@:3})
  local tool="$1"; shift
  LDAP_BIND_PW="$BIND_PW" docker exec -i -e LDAP_BIND_PW "$LDAP_CONTAINER" \
    sh -c 'umask 077; f=/tmp/.ldap-bind.$$
           printf %s "$LDAP_BIND_PW" > "$f"
           t="$1"; d="$2"; shift 2
           "$t" -x -D "$d" -y "$f" "$@"; rc=$?
           rm -f "$f"; exit $rc' sh "$tool" "$BIND_DN" "$@"
}
# CAPTURÉ dans un fichier avant grep : sous pipefail, `… | grep -q` ferme le tube
# au premier match, docker exec meurt en SIGPIPE et le pipeline rend FAUX alors
# qu'alice EST membre — mesuré au passage 2 (le trap l'a laissée dans le groupe).
alice_in_int(){ ldap_run ldapsearch -LLL -o ldif-wrap=no -b "cn=apim-apply-int,ou=Groups,$BASE_DN" -s base member > "$TMP/ldap.members" 2>/dev/null; grep -q "uid=alice,ou=People" "$TMP/ldap.members"; }
ldap_alice_int(){ # add|delete
  # `--` OBLIGATOIRE : le terminateur LDIF est un `-`, qu'un printf mangerait comme option (piège G2).
  printf 'dn: cn=apim-apply-int,ou=Groups,%s\nchangetype: modify\n%s: member\nmember: uid=alice,ou=People,%s\n%s\n\n' "$BASE_DN" "$1" "$BASE_DN" '-' \
    | ldap_run ldapmodify >/dev/null 2>&1
}
restore_ldap(){
  [ "$MUTATED" -eq 1 ] || return 0
  if alice_in_int; then ldap_alice_int delete; fi
  if alice_in_int; then echo "  ⚠ alice est ENCORE dans apim-apply-int — retirer à la main" >&2; return 1; fi
  MUTATED=0; return 0
}
cleanup(){
  echo; echo "── nettoyage ──"
  restore_ldap && echo "  annuaire : alice hors d'apim-apply-int (restauré)" || echo "  ⚠ annuaire NON restauré"
  if [ -n "$CI_TOKEN" ]; then
    for n in $PRS; do close_pr "$n" >/dev/null 2>&1; done
    for e in rec int homol prod; do gapi -X DELETE -o /dev/null "$API/repos/$GIT_REPO/branches/provision/${APP}-${e}" 2>/dev/null; done
    SHA_F=$(gapi "$API/repos/$GIT_REPO/contents/$MAN_DIR/${APP}.ansible.yml?ref=main" | jq_ "print(d.get('sha',''))" 2>/dev/null || true)
    if [ -n "$SHA_F" ]; then
      gapi -X DELETE -d "{\"branch\":\"main\",\"sha\":\"$SHA_F\",\"message\":\"test(a4-live): retrait du manifeste jetable ${APP} (porte A4 jouée)\"}" -o /dev/null "$API/repos/$GIT_REPO/contents/$MAN_DIR/${APP}.ansible.yml" \
        && echo "  manifeste jetable ${APP} retiré de main"
    fi
  fi
  APPJ=$(gw_app "$APP" 2>/dev/null || true); APP_ID=$(printf '%s' "$APPJ" | jq_ "print(d.get('id',''))" 2>/dev/null || true)
  if [ -n "$APP_ID" ]; then
    HC=$(gw -X DELETE -o /dev/null -w '%{http_code}' "$GW_ADMIN/applications/$APP_ID"); echo "  application jetable ${APP} supprimée de la gateway (HTTP $HC, best-effort)"
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

echo "═══ 0. Préconditions (fail-closed) ═══"
curl -sf -o /dev/null "$JENKINS_UI/api/json" || die "LAB_ABSENT : Jenkins injoignable ($JENKINS_UI)"
curl -sf -o /dev/null "$GITEA_URL/api/v1/version" || die "LAB_ABSENT : Gitea injoignable ($GITEA_URL)"
HC=$(gw -o /dev/null -w '%{http_code}' "$GW_ADMIN/applications"); [ "$HC" = 200 ] || die "LAB_ABSENT : gateway injoignable ou refus ($GW_ADMIN/applications -> $HC)"
[ "$(vcurl -o /dev/null -w '%{http_code}' "$VAULT_ADDR_LAB/v1/sys/policies/acl?list=true")" = 200 ] || die "LAB_ABSENT : le VAULT_TOKEN ne liste pas les policies (root de lab attendu)"
docker ps --format '{{.Names}}' | grep -qx "$LDAP_CONTAINER" || die "LAB_ABSENT : conteneur d'annuaire $LDAP_CONTAINER absent"
ldap_run ldapsearch -LLL -b "$BASE_DN" -s base dn >/dev/null 2>&1 || die "LAB_ABSENT : annuaire injoignable ou bind refusé (LDAP_ADMIN_PASSWORD ?)"
ok "0.1 Jenkins, Gitea, la gateway, Vault et l'annuaire répondent"
if [ -n "${GITEA_TOKEN_FILE:-}" ] && [ -r "$GITEA_TOKEN_FILE" ]; then CI_TOKEN="$(cat "$GITEA_TOKEN_FILE")"
elif docker inspect "$GITEA_CONTAINER" >/dev/null 2>&1; then
  CI_TOKEN=$(docker exec -u git "$GITEA_CONTAINER" gitea admin user generate-access-token --username ci --token-name "a4-live-ci-$TS" --scopes write:repository,write:issue,write:user,read:user,write:admin 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
fi
[ -n "$CI_TOKEN" ] || die "LAB_ABSENT : aucun token Gitea ci"
printf 'Authorization: token %s\n' "$CI_TOKEN" > "$TMP/ci.hdr"
gapi -o /dev/null -w '%{http_code}' "$API/repos/$GIT_REPO" | grep -q '^200$' || die "LAB_ABSENT : $GIT_REPO illisible"
ok "0.2 token ci opérationnel"
curl -sf "$JENKINS_UI/job/provision-apply/config.xml" | grep -q 'ci/Jenkinsfile.provision-apply' || die "PREREQUIS : provision-apply n'est pas from SCM"
for f in scripts/provision-apply-gate.sh scripts/selfservice-palier-gate.sh; do
  gapi -o /dev/null -w '%{http_code}' "$API/repos/$GIT_REPO/raw/main/$SUBDIR/$f" | grep -q '^200$' || die "PREREQUIS : $f absent de gitea main — git push gitea HEAD:main"
done
raw_at main "$SUBDIR/ci/Jenkinsfile.provision-apply" | grep -q 'GATE_STAGE=dispatch' || die "PREREQUIS : Jenkinsfile.provision-apply sur gitea main n'est pas la version A4"
raw_at main "$SUBDIR/scripts/selfservice-palier-gate.sh" | grep -q 'DEPLOYER_GROUP_REQUIRED' || die "PREREQUIS : la garde A3 sur gitea main n'a pas la §2bis"
ok "0.3 les portes A4 sont sur gitea main (amont from SCM, aval extrait de origin/main)"
raw_at main "$SUBDIR/clients/_example/environments.yaml" > "$TMP/chain.yaml"; [ "$(raw_hc)" = 200 ] || die "PREREQUIS : environments.yaml illisible sur gitea main"
# shellcheck source=scripts/lib/env-chain.sh
. scripts/lib/env-chain.sh
( STOA_ENV_CHAIN_FILE="$TMP/chain.yaml" env_chain_validate ) 2>"$TMP/val.err" || die "PREREQUIS : la chaîne de gitea main est INVALIDE : $(cat "$TMP/val.err")"
[ "$(STOA_ENV_CHAIN_FILE="$TMP/chain.yaml" env_chain_gate_four_eyes rec)" = FOUREYES=0 ] || die "PREREQUIS : la porte rec exige les quatre yeux (le scénario 1 attend selfApproval)"
[ "$(STOA_ENV_CHAIN_FILE="$TMP/chain.yaml" env_chain_gate_four_eyes int)" = FOUREYES=1 ] || die "PREREQUIS : la porte int n'exige pas les quatre yeux"
[ "$(STOA_ENV_CHAIN_FILE="$TMP/chain.yaml" env_chain_gate_deployer_group int)" = apim-apply-int ] || die "PREREQUIS : la porte int ne déclare pas apim-apply-int"
[ "$(STOA_ENV_CHAIN_FILE="$TMP/chain.yaml" env_chain_gate homol)" = "GATE=0|1|release-team" ] || die "PREREQUIS : la porte homol n'exige pas pv_ref"
TERM="$(STOA_ENV_CHAIN_FILE="$TMP/chain.yaml" env_chain_terminus)"
[ "$(STOA_ENV_CHAIN_FILE="$TMP/chain.yaml" env_chain_gate_itsm_check "$TERM")" = ITSMCHECK=1 ] || die "PREREQUIS : le terminus $TERM ne déclare pas itsmCheck"
ok "0.4 chaîne de gitea main valide : rec selfApproval, int fourEyes+apim-apply-int, homol pv_ref, terminus $TERM itsmCheck"
JAR="$TMP/jar.sc"; CR=$(jcrumb "$JAR") || die "LAB_ABSENT : crumb Jenkins"
gscript(){ curl -s -b "$JAR" -H "$CR" -X POST --data-urlencode "script=import jenkins.model.Jenkins; import hudson.slaves.EnvironmentVariablesNodeProperty; def p=Jenkins.instance.globalNodeProperties.get(EnvironmentVariablesNodeProperty); println(p==null ? \"\" : (p.envVars.get(\"$1\") ?: \"\"))" "$JENKINS_UI/scriptText" | tr -d '\r\n'; }
[ "$(gscript APPLY_ADMIN_VIA)" = "$EXPECT_ADMIN_VIA" ] && ok "0.5 APPLY_ADMIN_VIA global = $EXPECT_ADMIN_VIA" || die "PREREQUIS : APPLY_ADMIN_VIA global ≠ $EXPECT_ADMIN_VIA"
for G in APIM_TERMINUS_BASE STOA_ENV_CHAIN_FILE; do V=$(gscript "$G"); [ -z "$V" ] && ok "0.5b aucune globale $G (le terminus reste sans voie / la chaîne n'est pas redirigée)" || die "PREREQUIS : globale $G posée ($V)"; done
RUNNING=$(curl -s "$JENKINS_UI/job/provision-apply/api/json?tree=builds%5Bnumber,building%5D" | python3 -c 'import json,sys
d=json.load(sys.stdin); print(" ".join(str(b["number"]) for b in d.get("builds",[]) if b.get("building")))')
[ -z "$RUNNING" ] && ok "0.6 aucun build provision-apply en cours" || die "PREREQUIS : builds provision-apply en cours ($RUNNING)"
gw "$GW_ADMIN/apis" | A="$REQ_API" V="$REQ_API_VER" python3 -c "import json,os,sys
d=json.load(sys.stdin)
ok=any((i.get('api',i).get('apiName')==os.environ['A'] and i.get('api',i).get('apiVersion')==os.environ['V'] and i.get('api',i).get('isActive') is True) for i in d.get('apiResponse',[]))
sys.exit(0 if ok else 1)" && ok "0.7 API $REQ_API@$REQ_API_VER active" || die "PREREQUIS : $REQ_API@$REQ_API_VER absente/inactive"
ensure_human alice "$TMP/alice.hdr"; ensure_human carol "$TMP/carol.hdr"
ok "0.8 alice et carol : comptes Gitea humains, collaboratrices write, tokens jetables"
# alice : Vault par LDAP — elle NE porte PAS apply-int, et n'est pas dans le groupe
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
case " $APOL " in *" apply-int "*) die "PREREQUIS : alice porte DÉJÀ apply-int ($APOL) — le scénario 4 ne mesurerait rien";; esac
alice_in_int && die "PREREQUIS : alice est membre d'apim-apply-int dans l'annuaire — la retirer (setup-deployer-groups.sh)"
ok "0.9 alice (LDAP) : $APOL — sans apply-int, hors d'apim-apply-int"
vcurl "$VAULT_ADDR_LAB/v1/secret/data/stoa/envs/int/wm-admin" | python3 -c 'import json,os,sys
d=json.load(sys.stdin)["data"]["data"]
e=lambda s: s.replace("\\","\\\\").replace("\"","\\\"")
fd=os.open(sys.argv[1], os.O_WRONLY|os.O_CREAT|os.O_TRUNC, 0o600)
with os.fdopen(fd,"w") as f: f.write("user = \"%s:%s\"\n" % (e(d["username"]), e(d["password"])))' "$TMP/int.cfg" 2>/dev/null
HC=$(curl -s -K "$TMP/int.cfg" -H 'Accept: application/json' -o /dev/null -w '%{http_code}' "$GW_ADMIN/applications"); rm -f "$TMP/int.cfg"
[ "$HC" = 200 ] && ok "0.10 envs/int/wm-admin s'authentifie sur la gateway (200)" || die "PREREQUIS : envs/int/wm-admin refusé par la gateway ($HC) — jouer scripts/setup-wm-palier-admins.sh"
docker exec "$JENKINS_CONTAINER" curl -s -m 5 http://itsm-mock:8788/changes/CHG-0001 2>/dev/null | grep -q '"approved"' && docker exec "$JENKINS_CONTAINER" curl -s -m 5 http://itsm-mock:8788/changes/CHG-0002 2>/dev/null | grep -q '"draft"' \
  && ok "0.11 itsm-mock vu DEPUIS Jenkins : CHG-0001 approved, CHG-0002 draft" || die "PREREQUIS : itsm-mock injoignable depuis $JENKINS_CONTAINER ou seed inattendu"
POSED=$(curl -sf "$JENKINS_UI/job/selfservice-app-deploy/api/json?tree=property%5BparameterDefinitions%5Bname,choices%5D%5D" | python3 -c 'import json,sys
d=json.load(sys.stdin)
for pr in d.get("property",[]):
  for p in (pr.get("parameterDefinitions") or []):
    if p.get("name")=="ENVIRONMENT": print(" ".join(p.get("choices") or []))')
NONPROD=$(STOA_ENV_CHAIN_FILE="$TMP/chain.yaml" env_chain_nonprod)
[ "$POSED" = "$NONPROD" ] && ok "0.12 la liste POSÉE sur selfservice-app-deploy [$POSED] == env_chain_nonprod de gitea main (deux portes, une source — au repos)" || ko "0.12 liste posée [$POSED] ≠ chaîne [$NONPROD]"
POSED2=$(curl -sf "$JENKINS_UI/job/app-request/api/json?tree=property%5BparameterDefinitions%5Bname,choices%5D%5D" | python3 -c 'import json,sys
d=json.load(sys.stdin)
for pr in d.get("property",[]):
  for p in (pr.get("parameterDefinitions") or []):
    if p.get("name")=="REQ_ENV": print(" ".join(p.get("choices") or []))')
[ "$POSED2" = "$NONPROD" ] && ok "0.12b la liste POSÉE sur app-request [$POSED2] == la chaîne" || ko "0.12b liste app-request [$POSED2] ≠ chaîne [$NONPROD]"
[ -z "$(gw_app "$APP")" ] && ok "0.13 aucune application homonyme ($APP)" || die "PREREQUIS : application $APP déjà présente"

echo
echo "═══ 1. PORTE fourEyes — la porte ADMET (rec, PR ouverte ET mergée par alice) ═══"
read -r PRCI BR <<< "$(request_branch rec 10.42.0.1)"
PR1=$(reopen_as "$TMP/alice.hdr" alice "$PRCI" "$BR"); ok "1.1 branche $BR par la chaîne (PR de ci #$PRCI fermée), PR #$PR1 ouverte par alice"
N_PA=$(jnext provision-apply); MS1=$(merge_as_alice "$PR1")
ok "1.2 PR #$PR1 mergée par alice — MERGE_SHA=$MS1"
wait_amont "$N_PA" PAUSE; ok "1.3 provision-apply #$N_PA en PAUSE (la porte rec admet l'auto-approbation)"
jconsole provision-apply "$N_PA" > "$TMP/pa.pre.console"
grep -q '^PORTE_OK(pre) : palier rec — fourEyes=non' "$TMP/pa.pre.console" && ok "1.3b console : PORTE_OK(pre) : palier rec — fourEyes=non" || ko "1.3b PORTE_OK(pre) absent : $(grep -E 'PORTE_OK|REFUS' "$TMP/pa.pre.console" | head -2 | tr '\n' ' ')"
grep -q "^chaîne : " "$TMP/pa.pre.console" && ok "1.3c console : « chaîne : <chemin du clone> » (source épinglée, auditable)" || ko "1.3c chemin de chaîne absent"
answer_pause "$N_PA"; ok "1.4 pause #$N_PA répondue par alice"
finish_amont "$N_PA"
[ "$RES" = SUCCESS ] && ok "1.5 provision-apply #$N_PA : SUCCESS" || ko "1.5 provision-apply #$N_PA : $RES — $(grep -E 'REFUS|SHA_NON|error' "$TMP/pa.$N_PA.console" | tail -3 | tr '\n' ' ')"
grep -q '^PORTE_OK(dispatch) : palier rec' "$TMP/pa.$N_PA.console" && ok "1.6 console : PORTE_OK(dispatch) — la porte relue AU GESTE" || ko "1.6 PORTE_OK(dispatch) absent"
grep -q 'auto-approbation admise par la porte' "$TMP/pa.$N_PA.console" && ok "1.6b la garde post-pause : « auto-approbation admise par la porte » (drapeau venu de la porte)" || ko "1.6b drapeau non transmis"
console_order "$TMP/pa.$N_PA.console" 'PORTE_OK(pre)' 'Input requested' 'PORTE_OK(dispatch)' 'MERGE_IDENTITY_OK' && ok "1.6c ORDRE : PORTE_OK(pre) < pause < PORTE_OK(dispatch) < garde d'identité" || ko "1.6c ordre inattendu dans la console amont"
[ -n "$S_NUM" ] && [ "$(jresult selfservice-app-deploy "$S_NUM")" = SUCCESS ] && ok "1.7 aval #$S_NUM : SUCCESS" || ko "1.7 aval : $S_NUM $(jresult selfservice-app-deploy "${S_NUM:-0}")"
grep -q '^palier ouvert : envs/rec/wm-admin' "$TMP/ss.$S_NUM.console" && ! grep -q 'déclaration déployeur' "$TMP/ss.$S_NUM.console" && ok "1.7b aval : ticket rec, AUCUNE déclaration déployeur (rec n'en déclare pas)" || ko "1.7b aval : $(grep -E 'palier ouvert|déclaration' "$TMP/ss.$S_NUM.console" | tr '\n' ' ')"
ST=$(gw_state); [ "$ST" = "${APP}-rec|10.42.0.1-10.42.0.1" ] && ok "1.8 gateway : application $APP, claim ${APP}-rec, IP 10.42.0.1" || ko "1.8 gateway : $ST"
CM=$(pr_comments "$PR1")
printf '%s' "$CM" | grep -q 'Apply nominatif RÉUSSI' && printf '%s' "$CM" | grep -q 'porte du palier `rec`' && printf '%s' "$CM" | grep -q 'quatre yeux : non' \
  && ok "1.9 PR #$PR1 : ✅ + « porte du palier \`rec\` (relue au dispatch) : quatre yeux : non … »" || ko "1.9 commentaire : $(printf '%s' "$CM" | grep -i 'porte du palier' | head -1)"

echo
echo "═══ 2. PORTE fourEyes — la voie LIVRÉE refuse fermé (int par ci, mergée par alice ⇒ REQUESTER_UNKNOWN) ═══"
read -r PR2 BR <<< "$(request_branch int 10.42.0.3)"; PRS="$PRS $PR2"
[ "$(pr_field "$PR2" "['user']['login']")" = ci ] && ok "2.1 PR #$PR2 ouverte par ci (la voie livrée), branche $BR" || ko "2.1 auteur : $(pr_field "$PR2" "['user']['login']")"
N_PA=$(jnext provision-apply); MS2=$(merge_as_alice "$PR2"); ok "2.2 mergée par alice — $MS2"
wait_amont "$N_PA" NOPAUSE
[ "$(jresult provision-apply "$N_PA")" = FAILURE ] && grep -q '^REFUS: REQUESTER_UNKNOWN' "$TMP/pa.$N_PA.console" && ok "2.3 provision-apply #$N_PA : FAILURE REQUESTER_UNKNOWN (une PR de compte de service ne nomme aucun demandeur)" || ko "2.3 #$N_PA : $(jresult provision-apply "$N_PA") — $(grep -E 'REFUS|PORTE' "$TMP/pa.$N_PA.console" | head -2 | tr '\n' ' ')"
ST_A=$(jstage provision-apply "$N_PA" 'Appliquer')
[ "$(jstage provision-apply "$N_PA" 'Réconciliation')" = FAILED ] && { [ "$ST_A" = NOT_EXECUTED ] || [ "$ST_A" = FAILED ]; } && ! grep -q 'Input requested' "$TMP/pa.$N_PA.console" \
  && ok "2.4 SANS PAUSE : stage Réconciliation FAILED, stage Appliquer $ST_A (sauté), aucun « Input requested »" || ko "2.4 stages : rec=$(jstage provision-apply "$N_PA" 'Réconciliation') apply=$ST_A"
CM=$(pr_comments "$PR2"); printf '%s' "$CM" | grep -q 'REQUESTER_UNKNOWN' && printf '%s' "$CM" | grep -q 'porte du palier' && ok "2.5 PR #$PR2 : refus commenté (REQUESTER_UNKNOWN, la phrase de la porte)" || ko "2.5 commentaire : $(printf '%s' "$CM" | tail -c 300)"
ST=$(gw_state); [ "$ST" = "${APP}-rec|10.42.0.1-10.42.0.1" ] && ok "2.6 gateway inchangée (claim ${APP}-rec, IP .1)" || ko "2.6 gateway : $ST"

echo
echo "═══ 3. PORTE fourEyes — la porte REFUSE (int par alice, mergée par alice ⇒ FOUR_EYES_VIOLATION) ═══"
read -r PRCI BR <<< "$(request_branch int 10.42.0.4)"
PR3=$(reopen_as "$TMP/alice.hdr" alice "$PRCI" "$BR"); ok "3.1 PR #$PR3 ouverte par alice"
N_PA=$(jnext provision-apply); MS3=$(merge_as_alice "$PR3"); ok "3.2 mergée par alice — $MS3"
wait_amont "$N_PA" NOPAUSE
[ "$(jresult provision-apply "$N_PA")" = FAILURE ] && grep -q '^REFUS: FOUR_EYES_VIOLATION' "$TMP/pa.$N_PA.console" && ok "3.3 provision-apply #$N_PA : FAILURE FOUR_EYES_VIOLATION — « le demandeur qui approuve sa propre demande rec→int »" || ko "3.3 #$N_PA : $(jresult provision-apply "$N_PA") — $(grep -E 'REFUS|PORTE' "$TMP/pa.$N_PA.console" | head -2 | tr '\n' ' ')"
ST_A=$(jstage provision-apply "$N_PA" 'Appliquer')
{ [ "$ST_A" = NOT_EXECUTED ] || [ "$ST_A" = FAILED ]; } && ! grep -q 'Input requested' "$TMP/pa.$N_PA.console" && ok "3.4 SANS PAUSE (personne réveillé ; stage Appliquer $ST_A)" || ko "3.4 une pause a existé (stage Appliquer $ST_A)"
CM=$(pr_comments "$PR3"); printf '%s' "$CM" | grep -q 'FOUR_EYES_VIOLATION' && ok "3.5 PR #$PR3 : refus commenté FOUR_EYES_VIOLATION" || ko "3.5 commentaire : $(printf '%s' "$CM" | tail -c 200)"
ST=$(gw_state); [ "$ST" = "${APP}-rec|10.42.0.1-10.42.0.1" ] && ok "3.6 gateway inchangée" || ko "3.6 gateway : $ST"

echo
echo "═══ 4. PORTE deployerGroup — int par carol, mergée par alice ⇒ pause ⇒ aval DEPLOYER_GROUP_REQUIRED, rien écrit ═══"
read -r PRCI BR <<< "$(request_branch int 10.42.0.5)"
PR4=$(reopen_as "$TMP/carol.hdr" carol "$PRCI" "$BR"); ok "4.1 PR #$PR4 ouverte par carol (un autre humain — « même équipe » n'est PAS vérifié : mesuré)"
N_PA=$(jnext provision-apply); MS4=$(merge_as_alice "$PR4"); ok "4.2 mergée par alice — $MS4"
wait_amont "$N_PA" PAUSE; ok "4.3 provision-apply #$N_PA en PAUSE (quatre yeux OK : carol ≠ alice)"
answer_pause "$N_PA"; finish_amont "$N_PA"
grep -q 'PORTE_OK(dispatch) : palier int — fourEyes=oui approverGroup=int-team (attendu — NON vérifié' "$TMP/pa.$N_PA.console" && grep -q 'deployerGroup=apim-apply-int→apply-int' "$TMP/pa.$N_PA.console" \
  && ok "4.4 console amont : PORTE_OK(dispatch) int — fourEyes=oui, approverGroup=int-team NON vérifié, deployerGroup=apim-apply-int→apply-int" || ko "4.4 PORTE_OK(dispatch) : $(grep 'PORTE_OK(dispatch)' "$TMP/pa.$N_PA.console")"
[ "$RES" = FAILURE ] && ok "4.5 provision-apply #$N_PA : FAILURE (l'aval a refusé)" || ko "4.5 #$N_PA : $RES"
[ -n "$S_NUM" ] && grep -q '^REFUS: DEPLOYER_GROUP_REQUIRED' "$TMP/ss.$S_NUM.console" && grep -q "apim-apply-int" "$TMP/ss.$S_NUM.console" && grep -q "'alice'" "$TMP/ss.$S_NUM.console" \
  && ok "4.6 aval #$S_NUM : REFUS: DEPLOYER_GROUP_REQUIRED nommant apim-apply-int / apply-int / alice" || ko "4.6 aval : $(grep -E 'REFUS|error' "$TMP/ss.${S_NUM:-0}.console" 2>/dev/null | head -2 | tr '\n' ' ')"
! grep -q '^palier ouvert' "$TMP/ss.$S_NUM.console" && ! grep -q 'préflight de joignabilité' "$TMP/ss.$S_NUM.console" && ! grep -q 'PLAY \[Self-service application' "$TMP/ss.$S_NUM.console" \
  && ok "4.7 aval : AUCUN ticket, AUCUN préflight, AUCUN play — rien écrit" || ko "4.7 l'aval est allé plus loin que la déclaration"
grep -q 'token Vault révoqué — mort PROUVÉE' "$TMP/ss.$S_NUM.console" && ok "4.8 token nominatif révoqué, mort prouvée (trap)" || ko "4.8 révocation absente"
grep -q 'refus de la garde du palier relayé à l.amont : DEPLOYER_GROUP_REQUIRED' "$TMP/ss.$S_NUM.console" && ok "4.9 aval : le tag est relayé (post{always}, fait 11)" || ko "4.9 relais absent de la console aval"
CM=$(pr_comments "$PR4"); printf '%s' "$CM" | grep -q 'Refus `DEPLOYER_GROUP_REQUIRED`' && printf '%s' "$CM" | grep -q 'porteur attendu `apim-apply-int`' \
  && ok "4.10 PR #$PR4 : ❌ Refus \`DEPLOYER_GROUP_REQUIRED\` + « porteur attendu \`apim-apply-int\` → \`apply-int\` »" || ko "4.10 commentaire : $(printf '%s' "$CM" | grep -iE 'refus|porteur' | head -2 | tr '\n' ' ')"
ST=$(gw_state); [ "$ST" = "${APP}-rec|10.42.0.1-10.42.0.1" ] && ok "4.11 gateway inchangée (claim ${APP}-rec, IP .1) — « refus nommé au dispatch, rien écrit »" || ko "4.11 gateway : $ST"

echo
echo "═══ 5. CONTRE-ÉPREUVE — le grant SUIT l'annuaire : alice ∈ apim-apply-int ⇒ la chaîne ENTIÈRE d'un palier déclaré ═══"
MUTATED=1
ldap_alice_int add; alice_in_int && ok "5.1 alice ajoutée à cn=apim-apply-int (annuaire — restauré par le trap)" || die "PREREQUIS : ajout LDAP d'alice à apim-apply-int en échec"
read -r PRCI BR <<< "$(request_branch int 10.42.0.6)"
PR5=$(reopen_as "$TMP/carol.hdr" carol "$PRCI" "$BR"); N_PA=$(jnext provision-apply); MS5=$(merge_as_alice "$PR5"); ok "5.2 PR #$PR5 (carol) mergée par alice — $MS5"
wait_amont "$N_PA" PAUSE; answer_pause "$N_PA"; finish_amont "$N_PA"
[ "$RES" = SUCCESS ] && ok "5.3 provision-apply #$N_PA : SUCCESS — la chaîne entière d'un palier à deployerGroup" || ko "5.3 #$N_PA : $RES — $(grep -E 'REFUS|SHA_NON|error' "$TMP/pa.$N_PA.console" | tail -2 | tr '\n' ' ')"
[ -n "$S_NUM" ] && [ "$(jresult selfservice-app-deploy "$S_NUM")" = SUCCESS ] && ok "5.4 aval #$S_NUM : SUCCESS" || ko "5.4 aval : $(jresult selfservice-app-deploy "${S_NUM:-0}")"
grep -q "^déclaration déployeur : 'alice' porte 'apply-int' (groupe 'apim-apply-int')$" "$TMP/ss.$S_NUM.console" && ok "5.5 aval : « déclaration déployeur : 'alice' porte 'apply-int' (groupe 'apim-apply-int') »" || ko "5.5 déclaration absente : $(grep 'déclaration' "$TMP/ss.$S_NUM.console")"
console_order "$TMP/ss.$S_NUM.console" 'déclaration déployeur' 'palier ouvert : envs/int/wm-admin' 'préflight de joignabilité :' 'PLAY [Self-service application — converge' 'PLAY [Self-service application — verify' \
  && ok "5.6 ORDRE aval : déclaration < ticket int < préflight < converge < verify" || ko "5.6 ordre aval inattendu"
[ "$(grep -c 'failed=0' "$TMP/ss.$S_NUM.console")" -ge 2 ] && ok "5.6b converge + verify : failed=0 ×2" || ko "5.6b failed=0 : $(grep -c 'failed=0' "$TMP/ss.$S_NUM.console")"
ST=$(gw_state); [ "$ST" = "${APP}-int|10.42.0.6-10.42.0.6" ] && ok "5.7 gateway : l'application $APP porte désormais claim ${APP}-int, IP .6 — l'état rec est ÉCRASÉ (mono-gateway : un objet par nom, mesuré)" || ko "5.7 gateway : $ST"
CM=$(pr_comments "$PR5"); printf '%s' "$CM" | grep -q 'Apply nominatif RÉUSSI' && printf '%s' "$CM" | grep -q 'porteur attendu `apim-apply-int` → `apply-int` (vérifié au dispatch sur le token)' \
  && ok "5.8 PR #$PR5 : ✅ + « porteur attendu \`apim-apply-int\` → \`apply-int\` (vérifié au dispatch sur le token) »" || ko "5.8 commentaire : $(printf '%s' "$CM" | grep -i 'porteur' | head -1)"
ldap_alice_int delete; ! alice_in_int && ok "5.9 alice RETIRÉE d'apim-apply-int" || die "PREREQUIS : retrait LDAP d'alice en échec"
MUTATED=0
printf 'MANIFEST=clients/provisioned/applications/%s.ansible.yml\nENVIRONMENT=int\nADMIN_VIA=%s\nMERGE_SHA=%s\nDEBUG=false\nVAULT_USER=alice\nVAULT_USER_PASSWORD=%s\nUSER_VAULT_JWT=\n' "$APP" "$EXPECT_ADMIN_VIA" "$MS5" "$LAB_ALICE_PASS" | form_file "$TMP/form.int"
N_D=$(jbuild selfservice-app-deploy "$TMP/form.int"); rm -f "$TMP/form.int"
[ -n "$N_D" ] && ok "5.10 build direct selfservice-app-deploy #$N_D (int, MERGE_SHA de #$PR5, alice hors du groupe)" || die "BUILD_EN_FILE : aucun build résolu"
wait_until 900 selfservice-app-deploy "$N_D" FINISHED >/dev/null; jconsole selfservice-app-deploy "$N_D" > "$TMP/ss.$N_D.console"
[ "$(jresult selfservice-app-deploy "$N_D")" = FAILURE ] && grep -q '^REFUS: DEPLOYER_GROUP_REQUIRED' "$TMP/ss.$N_D.console" && ok "5.11 #$N_D : FAILURE DEPLOYER_GROUP_REQUIRED — le retrait est visible au geste suivant (login frais)" || ko "5.11 #$N_D : $(jresult selfservice-app-deploy "$N_D") — $(grep -E 'REFUS|error' "$TMP/ss.$N_D.console" | head -2 | tr '\n' ' ')"
! grep -q '^palier ouvert' "$TMP/ss.$N_D.console" && ! grep -q 'PLAY \[Self-service application' "$TMP/ss.$N_D.console" && ok "5.12 aucun ticket, aucun play" || ko "5.12 l'aval est allé plus loin"
ST=$(gw_state); [ "$ST" = "${APP}-int|10.42.0.6-10.42.0.6" ] && ok "5.13 gateway inchangée (int .6)" || ko "5.13 gateway : $ST"

echo
echo "═══ 6. La porte lit plus que le déployeur — homol par carol ⇒ GATE_REFS_REQUIRED (pv_ref) ═══"
read -r PRCI BR <<< "$(request_branch homol 10.42.0.7)"
PR6=$(reopen_as "$TMP/carol.hdr" carol "$PRCI" "$BR"); N_PA=$(jnext provision-apply); MS6=$(merge_as_alice "$PR6"); ok "6.1 PR #$PR6 (carol, homol) mergée par alice — $MS6"
wait_amont "$N_PA" NOPAUSE
[ "$(jresult provision-apply "$N_PA")" = FAILURE ] && grep -q '^REFUS: GATE_REFS_REQUIRED' "$TMP/pa.$N_PA.console" && grep -q 'pv_ref' "$TMP/pa.$N_PA.console" && ! grep -q 'Input requested' "$TMP/pa.$N_PA.console" \
  && ok "6.2 provision-apply #$N_PA : FAILURE GATE_REFS_REQUIRED (pv_ref), sans pause" || ko "6.2 #$N_PA : $(jresult provision-apply "$N_PA") — $(grep -E 'REFUS|PORTE' "$TMP/pa.$N_PA.console" | head -2 | tr '\n' ' ')"
CM=$(pr_comments "$PR6"); printf '%s' "$CM" | grep -q 'GATE_REFS_REQUIRED' && ok "6.3 PR #$PR6 : refus commenté GATE_REFS_REQUIRED" || ko "6.3 commentaire : $(printf '%s' "$CM" | tail -c 200)"
ST=$(gw_state); [ "$ST" = "${APP}-int|10.42.0.6-10.42.0.6" ] && ok "6.4 gateway inchangée" || ko "6.4 gateway : $ST"

echo
echo "═══ 7. ITSM au terminus, AVANT la voie — prod par carol : CHG-0002 draft ⇒ ITSM_NOT_APPROVED ; CHG-0001 approved ⇒ TERMINUS_SANS_VOIE ═══"
# shellcheck source=scripts/lib/app-manifest.sh
. scripts/lib/app-manifest.sh
prod_pr(){ # <change_ref> <branche existante 0|1> → numéro de PR de carol (manifeste de main ⊕ per_env.prod par la lib)
  local cr="$1" existing="$2" m="$TMP/man.prod.yml" sha b64 body n
  raw_at main "$MAN_DIR/${APP}.ansible.yml" > "$m"; [ "$(raw_hc)" = 200 ] || die "PREREQUIS : manifeste illisible sur main"
  app_manifest_merge_env "$m" "$TERM" "{ auth: { claim: { value: \"${APP}-${TERM}\" } }, change_ref: \"$cr\", pv_ref: \"PV-A4\" }" || die "PREREQUIS : fusion per_env.$TERM par la lib en échec"
  b64=$(base64 < "$m" | tr -d '\n')
  if [ "$existing" = 0 ]; then
    sha=$(gapi "$API/repos/$GIT_REPO/contents/$MAN_DIR/${APP}.ansible.yml?ref=main" | jq_ "print(d['sha'])")
    body="{\"branch\":\"main\",\"new_branch\":\"provision/${APP}-${TERM}\",\"sha\":\"$sha\",\"content\":\"$b64\",\"message\":\"provision(${TERM}): ${APP} (${cr})\"}"
  else
    sha=$(gapi "$API/repos/$GIT_REPO/contents/$MAN_DIR/${APP}.ansible.yml?ref=provision/${APP}-${TERM}" | jq_ "print(d['sha'])")
    body="{\"branch\":\"provision/${APP}-${TERM}\",\"sha\":\"$sha\",\"content\":\"$b64\",\"message\":\"provision(${TERM}): ${APP} (${cr})\"}"
  fi
  hc=$(capi -X PUT -d "$body" -o "$TMP/put.out" -w '%{http_code}' "$API/repos/$GIT_REPO/contents/$MAN_DIR/${APP}.ansible.yml")
  [ "$hc" = 200 ] || [ "$hc" = 201 ] || die "PREREQUIS : commit prod par carol refusé (HTTP $hc) : $(head -c 200 "$TMP/put.out")"
  n=$(capi -X POST -d "{\"head\":\"provision/${APP}-${TERM}\",\"base\":\"main\",\"title\":\"provision(carol): ${APP}-${TERM} ${cr}\"}" "$API/repos/$GIT_REPO/pulls" | jq_ "print(d.get('number',''))")
  [ -n "$n" ] || die "PREREQUIS : PR prod de carol non ouverte"; PRS="$PRS $n"; printf '%s' "$n"
}
PR7=$(prod_pr CHG-0002 0); N_PA=$(jnext provision-apply); MS7=$(merge_as_alice "$PR7"); ok "7.1 PR #$PR7 (carol, $TERM, change_ref CHG-0002 draft) mergée par alice — $MS7"
wait_amont "$N_PA" NOPAUSE
[ "$(jresult provision-apply "$N_PA")" = FAILURE ] && grep -q '^REFUS: ITSM_NOT_APPROVED' "$TMP/pa.$N_PA.console" && grep -q "'draft'" "$TMP/pa.$N_PA.console" && ! grep -q 'Input requested' "$TMP/pa.$N_PA.console" \
  && ok "7.2 provision-apply #$N_PA : FAILURE ITSM_NOT_APPROVED (CHG-0002 est draft), sans pause" || ko "7.2 #$N_PA : $(jresult provision-apply "$N_PA") — $(grep -E 'REFUS|PORTE|itsm' "$TMP/pa.$N_PA.console" | head -2 | tr '\n' ' ')"
CM=$(pr_comments "$PR7"); printf '%s' "$CM" | grep -q 'ITSM_NOT_APPROVED' && ok "7.3 PR #$PR7 : refus commenté ITSM_NOT_APPROVED" || ko "7.3 commentaire : $(printf '%s' "$CM" | tail -c 200)"
PR8=$(prod_pr CHG-0001 1); N_PA=$(jnext provision-apply); MS8=$(merge_as_alice "$PR8"); ok "7.4 PR #$PR8 (carol, $TERM, change_ref CHG-0001 approved) mergée par alice — $MS8"
wait_amont "$N_PA" NOPAUSE
grep -q "^itsm : change 'CHG-0001' approved" "$TMP/pa.$N_PA.console" && ok "7.5 console : « itsm : change 'CHG-0001' approved au moment du dispatch » — l'ITSM est re-vérifié AU TERMINUS" || ko "7.5 ligne itsm absente : $(grep -E 'itsm|REFUS' "$TMP/pa.$N_PA.console" | head -2 | tr '\n' ' ')"
[ "$(jresult provision-apply "$N_PA")" = FAILURE ] && grep -q '^REFUS: TERMINUS_SANS_VOIE' "$TMP/pa.$N_PA.console" && ! grep -q 'Input requested' "$TMP/pa.$N_PA.console" \
  && ok "7.6 puis FAILURE TERMINUS_SANS_VOIE, sans pause — personne réveillé, aucun mot de passe consommé, aucun token minté" || ko "7.6 #$N_PA : $(jresult provision-apply "$N_PA") — $(grep -E 'REFUS|Input' "$TMP/pa.$N_PA.console" | head -2 | tr '\n' ' ')"
console_order "$TMP/pa.$N_PA.console" "itsm : change 'CHG-0001' approved" 'REFUS: TERMINUS_SANS_VOIE' && ok "7.6b ORDRE : ITSM approved AVANT le refus de voie" || ko "7.6b ordre itsm/terminus inattendu"
CM=$(pr_comments "$PR8"); printf '%s' "$CM" | grep -q 'TERMINUS_SANS_VOIE' && ok "7.7 PR #$PR8 : refus commenté TERMINUS_SANS_VOIE" || ko "7.7 commentaire : $(printf '%s' "$CM" | tail -c 200)"
ST=$(gw_state); [ "$ST" = "${APP}-int|10.42.0.6-10.42.0.6" ] && ok "7.8 gateway inchangée (aucune claim -$TERM)" || ko "7.8 gateway : $ST"

echo
echo "═══════════════════════════════════════════════════"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
