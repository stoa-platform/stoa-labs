#!/usr/bin/env bash
# test-p7-bout-en-bout.sh — la matrice de preuve du jalon P7 (ADR-097) :
# LA POSTURE, DU FORMULAIRE JUSQU'AU PLAN DE DONNÉES, PAR BUILDS RÉELS.
#
# Ce que ce fichier mesure, et que le GOAL promet :
#
#   formulaire Jenkins → PR sur le dépôt d'ÉQUIPE → merge par un SECOND humain
#   → webhook Gitea RÉEL → job team-publish → API publiée sur la webMethods
#   10.15 RÉELLE, dont le TAG, le PROTOCOLE, la CELLULE COMMUNE, l'IDENTITÉ
#   exigée de l'appelant et l'INSCRIPTION AU PORT sont MESURÉS — sur la
#   gateway, puis au plan de données.
#
# Et la contre-épreuve de tout le GOAL : **le manifeste ne décide pas**.
#   - déclarer PLUS FAIBLE que le registre central ⇒ refus NOMMÉ
#     (CLASSIFICATION_SPOOFED), relayé sur la PR, RIEN sur la gateway ;
#   - déclarer PLUS FORT ⇒ publication acceptée, et la posture RÉELLEMENT
#     appliquée est, à l'octet de son empreinte près, celle d'une API déclarée
#     honnêtement sur la même ligne de registre.
#
# ── CE QUE CE JALON A TROUVÉ, ET QUI CHANGE LA FORME ────────────────────────
# La chaîne appliquait QUATRE dimensions du bouquet (tag P3, cellule P4,
# protocole P5, identité P6) et ignorait les autres EN SILENCE : une API
# `M/internal` recevait un tag qui affirme `oauth2` sans que rien ne l'exige
# d'elle. C'est le défaut de P6 (`EnforceInboundIdentifiers`), une couche plus
# haut. D'où `tasks/coverage.yml` : trois issues, jamais le silence — opposée,
# dégradée (l'axe est gardé plus faiblement, on le DIT), ou refusée (l'axe n'est
# gardé par rien). Conséquence directe et assumée : **les cellules `VH` et
# `internet` ne sont plus publiables par cette chaîne** (mtls non déclinable par
# API sur la 10.15 — P5 ; threat-protection non portable par une policy — P4).
#
# ── LES SECTIONS ────────────────────────────────────────────────────────────
#   A. PRÉFLIGHTS — la chaîne SOUS TEST est bien celle qui est SERVIE, et elle
#      vise la VRAIE gateway. Chaque manque est un refus NOMMÉ, jamais un skip.
#   B. TROIS COMBINAISONS d'exposition × classification, par BUILDS RÉELS, et
#      leurs mesures sur la 10.15 puis au plan de données.
#   C. LA CONTRE-ÉPREUVE DU GOAL — se déclarer plus faible / plus fort.
#   D. LES REFUS STRUCTURELS — ce que la chaîne refuse de publier, par build
#      réel pour l'un, hors ligne pour l'autre.
#   E. MUTATIONS — ce harnais SAIT rougir ; chaque sabotage est restauré à
#      l'octet près (cmp).
#
# ── CIBLES, SANS DÉFAUT LÀ OÙ ON ÉCRIT ──────────────────────────────────────
#   GITEA_URL        base HTTP de la forge, vue du HOST (ex. http://localhost:13000)
#   GITEA_TOKEN      token du compte de service `ci` (write:repository,
#                    write:issue, write:organization)
#   JENKINS_UI       base HTTP de Jenkins vue du HOST (ex. http://localhost:18080)
#   LAB_OSCAR_PASS   mot de passe annuaire du SECOND humain (ou ./.env.lab-users)
#   WM_ADMIN         API d'admin de la gateway RÉELLE, vue du HOST
#                    (défaut http://localhost:5555/rest/apigateway, comme P3..P6)
#
# ⚠ CE HARNAIS ÉCRIT DANS LE LAB : il pousse des lignes dans le registre de
# gouvernance, ouvre et fusionne des PR dans le dépôt d'équipe, et crée des APIs
# sur la gateway. Il rend tout à l'état d'entrée dans son teardown, et sa
# preuve finale RELIT cet état.
#
# `A && ok || ko` (SC2015) est l'idiome des scripts de preuve du repo : `ok` et
# `ko` ne rendent jamais un code non nul, donc la branche `||` est inatteignable
# depuis un `ok` réussi.
# shellcheck disable=SC2015
set -u
set -o pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
TMP="$(mktemp -d /tmp/p7e2e.XXXXXX)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
skip(){ printf '  ⏭  %s\n' "$*"; }
mes(){ printf '     📏 %s\n' "$*"; }
die(){ printf '\nPRÉ-VOL: %s\n' "$*" >&2; exit 2; }

# ── identités et cibles ──────────────────────────────────────────────────────
GITEA_URL="${GITEA_URL:?GITEA_URL requis (ex. http://localhost:13000) — aucun defaut, jamais deviner la forge}"
GITEA_TOKEN="${GITEA_TOKEN:-${FORGE_SECRET:-}}"
[ -n "$GITEA_TOKEN" ] || die "GITEA_TOKEN (ou FORGE_SECRET) requis — compte de service de la forge"
JENKINS_UI="${JENKINS_UI:?JENKINS_UI requis (ex. http://localhost:18080) — vue HOST}"
JENKINS_UI="${JENKINS_UI%/}"
WM_ADMIN="${WM_ADMIN:-http://localhost:5555/rest/apigateway}"
WM_USER="${WM_USER:-Administrator}"
WM_PASS="${WM_PASS:-manage}"
export WM_DATA="${WM_DATA:-http://localhost:5555/gateway}"
export WM_DP_CONTAINER="${WM_DP_CONTAINER:-poc-webmethods-real}"
TEAM="${P7_TEAM:-banking-demo}"
MERGER="${P7_MERGER:-oscar}"

if [ -z "${LAB_OSCAR_PASS:-}" ] && [ -r ./.env.lab-users ]; then
  # shellcheck source=/dev/null
  set -a; . ./.env.lab-users; set +a
fi
LAB_OSCAR_PASS="${LAB_OSCAR_PASS:?LAB_OSCAR_PASS requis (ou ./.env.lab-users) — le SECOND humain qui fusionne et repond a la pause}"

# shellcheck source=scripts/lib/posture-authority.sh
. "$REPO/scripts/lib/posture-authority.sh"
resolve_posture_authority "$TMP/labctl" \
  || die "aucun labctl — l'autorité qui DÉRIVE le bouquet est le sujet de ce test, pas une dépendance optionnelle"

RUN="$(date +%s)$((RANDOM % 900 + 100))"
GOV_REPO="ci/governance"; GOV_PATH="governance/classifications.yaml"

umask 077
GHDR="$TMP/ghdr"; printf 'Authorization: token %s\n' "$GITEA_TOKEN" > "$GHDR"; chmod 600 "$GHDR"
gapi(){ curl -s -m 60 -H @"$GHDR" "$@"; }
ghc(){ gapi -o /dev/null -w '%{http_code}' "$@"; }
wm(){ curl -s -m 30 -u "$WM_USER:$WM_PASS" -H 'Accept: application/json' "$@"; }

# ── état d'entrée, restauré au teardown ──────────────────────────────────────
# TOUTES déclarées AVANT le trap : `set -u` casserait le teardown sur la
# première variable non encore posée si la sortie survient tôt (leçon du
# palier 3, cleanup_exit).
CREATED_APIS=""; CREATED_BRANCHES=""; CREATED_APP=""; GOV_BASE_SHA=""
MY_PAUSES=""; TEAM_REPO=""; TLS_PORT=""; LABCTL_BIN="${LABCTL_BIN:-}"

cleanup(){
  local a b id
  # Les pauses de CE run, et elles seules : une pause d'un autre run bloquerait
  # sa propre matrice si on l'abandonnait ici.
  for b in $MY_PAUSES; do
    [ "$(jstatus team-publish "$b" 2>/dev/null)" = PAUSED_PENDING_INPUT ] \
      && abort_pause team-publish "$b" >/dev/null 2>&1
  done
  for a in $CREATED_APIS; do
    id=$(api_id "$a" 2>/dev/null)
    [ -n "$id" ] && { wm -o /dev/null -X PUT "$WM_ADMIN/apis/$id/deactivate"; wm -o /dev/null -X DELETE "$WM_ADMIN/apis/$id"; }
  done
  [ -n "$CREATED_APP" ] && purge_app "$CREATED_APP" >/dev/null 2>&1
  if [ -n "$TEAM_REPO" ]; then
    for b in $CREATED_BRANCHES; do
      gapi -X DELETE "$GITEA_URL/api/v1/repos/$TEAM_REPO/branches/$b" -o /dev/null 2>/dev/null
    done
  fi
  # Le registre de gouvernance revient à son contenu d'ENTRÉE, par un commit de
  # restauration : ce harnais y a écrit comme l'aurait fait une PR gouvernance,
  # il n'a pas à laisser ses lignes derrière lui.
  [ -n "$GOV_BASE_SHA" ] && gov_restore
  rm -rf "$TMP"
}
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════
# OUTILLAGE — Jenkins
# ═══════════════════════════════════════════════════════════════════════════
# Crumb ET cookie du MÊME appel : un crumb obtenu ailleurs que le cookie
# réutilisé fait répondre « Rejected » sans message exploitable (motif du
# palier 2, repayé en A3).
JCK="$TMP/jck"; JF=""; JC=""
jcrumb(){
  local cj; rm -f "$JCK"
  cj=$(curl -sf -m 30 -c "$JCK" "$JENKINS_UI/crumbIssuer/api/json") || return 1
  JF=$(printf '%s' "$cj" | python3 -c 'import sys,json;print(json.load(sys.stdin)["crumbRequestField"])' 2>/dev/null)
  JC=$(printf '%s' "$cj" | python3 -c 'import sys,json;print(json.load(sys.stdin)["crumb"])' 2>/dev/null)
  [ -n "$JF" ] && [ -n "$JC" ]
}

# form_file <fichier> — écrit le corps urlencodé du formulaire depuis les
# variables P7F_* de l'ENVIRONNEMENT. Les valeurs y passent, jamais par un
# séparateur : `OPENAPI_SPEC` est multi-lignes, et tout séparateur textuel
# (retour à la ligne, NUL via printf) finirait par couper une valeur en dix
# paires bancales dont Jenkins ferait dix paramètres vides.
# ⚠ urlencode() EXIGE des TUPLES : une liste de listes lève TypeError, le
# fichier n'est jamais écrit, curl poste un corps VIDE et Jenkins démarre un
# build SANS paramètre (mesuré en A3 : builds « anonymous »). Fail-closed ici.
form_file(){
  python3 -c 'import os,sys,urllib.parse
keys=["ACTION","TEAM","API_NAME","API_VERSION","API_BASE","NEW_VERSION",
      "OPENAPI_SPEC","INBOUND_MODE","CLASSIFICATION","EXPOSURE"]
pairs=[(k, os.environ.get("P7F_"+k,"")) for k in keys]
fd=os.open(sys.argv[1], os.O_WRONLY|os.O_CREAT|os.O_TRUNC, 0o600)
with os.fdopen(fd,"w") as f: f.write(urllib.parse.urlencode(pairs))' "$1"
  [ -s "$1" ] || die "HARNAIS : formulaire de build non écrit ($1)"
  grep -q 'API_NAME=' "$1" || die "HARNAIS : formulaire sans API_NAME ($1)"
}

# jbuild <job> <fichier de formulaire> → numéro de build, résolu par l'ITEM DE
# FILE et jamais « le dernier build » (lab partagé, quiet period).
jbuild(){
  local qid n dl
  jcrumb || { echo ""; return; }
  curl -s -m 60 -b "$JCK" -H "$JF: $JC" -X POST -D "$TMP/b.hdr" -o /dev/null \
    --data-binary @"$2" -H 'Content-Type: application/x-www-form-urlencoded' \
    "$JENKINS_UI/job/$1/buildWithParameters"
  qid=$(grep -i '^Location:' "$TMP/b.hdr" | grep -oE 'queue/item/[0-9]+' | grep -oE '[0-9]+$' | head -1)
  [ -n "$qid" ] || { echo ""; return; }
  dl=$(( $(date +%s) + 240 ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    n=$(curl -s -m 30 "$JENKINS_UI/queue/item/$qid/api/json" \
        | python3 -c 'import json,sys;print((json.load(sys.stdin).get("executable") or {}).get("number",""))' 2>/dev/null)
    [ -n "$n" ] && { echo "$n"; return; }
    sleep 2
  done
  echo ""
}

jstatus(){ curl -s -m 30 "$JENKINS_UI/job/$1/$2/wfapi/describe" 2>/dev/null \
  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("status",""))' 2>/dev/null; }
jresult(){ curl -s -m 30 "$JENKINS_UI/job/$1/$2/api/json?tree=result,building" 2>/dev/null \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("result") or ("BUILDING" if d.get("building") else ""))' 2>/dev/null; }
jlog(){ curl -s -m 60 "$JENKINS_UI/job/$1/$2/consoleText" 2>/dev/null; }

# jwait <job> <n> <secs> — attend un état NON transitoire. wfapi rend une SUITE
# d'états avant la valeur cherchée : vide (en file), NOT_EXECUTED, IN_PROGRESS.
jwait(){
  local st="" dl; dl=$(( $(date +%s) + $3 ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    st=$(jstatus "$1" "$2")
    case "$st" in ""|NOT_EXECUTED|IN_PROGRESS) sleep 3;; *) break;; esac
  done
  printf '%s' "$st"
}
jwait_end(){
  local st="" dl; dl=$(( $(date +%s) + $3 ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    st=$(jstatus "$1" "$2")
    case "$st" in PAUSED_PENDING_INPUT|IN_PROGRESS|"") sleep 3;; *) break;; esac
  done
  printf '%s' "$st"
}
# wfapi dit FINISHED AVANT que api/json ne dise building=false : le bloc post{}
# tourne encore, et c'est LUI qui pose le commentaire de PR (mesuré en A4).
jwait_built(){
  local dl r; dl=$(( $(date +%s) + 300 ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    r=$(jresult "$1" "$2"); [ -n "$r" ] && [ "$r" != BUILDING ] && return 0
    sleep 3
  done
  return 1
}

# answer_pause <job> <n> <user> <passfile> — répond à la pause nominative.
# Les paramètres s'appellent V_USER / V_PASS (ci/Jenkinsfile.team-publish) et
# NON VAULT_USER / VAULT_USER_PASSWORD : le mot de passe doit s'appeler V_PASS
# pour être recopié puis `unset` dans le seul `sh` qui en a besoin.
answer_pause(){
  local job="$1" n="$2" user="$3" pf="$4" iid
  iid=$(curl -s -m 30 "$JENKINS_UI/job/$job/$n/wfapi/pendingInputActions" \
        | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["id"])' 2>/dev/null)
  [ -n "$iid" ] || return 1
  # Le mot de passe passe par l'ENVIRONNEMENT d'un heredoc python, jamais par
  # l'argv d'un `python3 -c` (ADR-074 : rien de secret en argv).
  P7PASS="$(cat "$pf")" P7USER="$user" python3 - > "$TMP/input.json" <<'PY'
import json, os
print(json.dumps({'parameter': [
  {'name': 'V_USER', 'value': os.environ['P7USER']},
  {'name': 'V_PASS', 'value': os.environ['P7PASS']}]}))
PY
  jcrumb || return 1
  curl -s -m 60 -b "$JCK" -H "$JF: $JC" -X POST --data-urlencode json@"$TMP/input.json" \
    -o /dev/null -w '%{http_code}' "$JENKINS_UI/job/$job/$n/wfapi/inputSubmit?inputId=$iid"
  rm -f "$TMP/input.json"
}
abort_pause(){
  local iid; jcrumb || return 1
  iid=$(curl -s -m 30 "$JENKINS_UI/job/$1/$2/wfapi/pendingInputActions" \
        | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["id"])' 2>/dev/null)
  [ -n "$iid" ] || return 1
  curl -s -m 30 -b "$JCK" -H "$JF: $JC" -X POST "$JENKINS_UI/job/$1/$2/input/$iid/abort" -o /dev/null
}

# find_publish_build <jeton> — le build team-publish de CE run, reconnu à un
# jeton propre au run présent dans sa console (jamais « le dernier build » :
# le job est partagé, et deux runs concurrents auraient le même displayName).
find_publish_build(){
  local motif="$1" dl n
  dl=$(( $(date +%s) + 180 ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    for n in $(curl -s -m 30 "$JENKINS_UI/job/team-publish/api/json?tree=builds%5Bnumber%5D" \
               | python3 -c 'import json,sys
for b in json.load(sys.stdin).get("builds",[])[:8]: print(b["number"])' 2>/dev/null); do
      jlog team-publish "$n" | grep -qF -- "$motif" && { echo "$n"; return 0; }
    done
    sleep 4
  done
  echo ""; return 1
}

# ═══════════════════════════════════════════════════════════════════════════
# OUTILLAGE — Gitea
# ═══════════════════════════════════════════════════════════════════════════
settle(){ sleep 3; }   # Gitea indexe l'objet avant l'appel API (motif test-api-request.sh)

# merge_pr <fichier d'en-tête> <repo> <pr> — Gitea calcule `mergeable` de façon
# ASYNCHRONE : tenter le merge avant la fin de ce calcul rend 405, et ce n'est
# PAS un refus de droits. On attend le feu vert.
merge_pr(){
  local hdr="$1" repo="$2" pr="$3" m dl
  dl=$(( $(date +%s) + 40 ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    m=$(curl -s -m 30 -H @"$hdr" "$GITEA_URL/api/v1/repos/$repo/pulls/$pr" \
        | python3 -c 'import json,sys;print(json.load(sys.stdin).get("mergeable") or False)' 2>/dev/null)
    [ "$m" = True ] && break
    sleep 2
  done
  curl -s -m 60 -H @"$hdr" -X POST -H 'Content-Type: application/json' -d '{"Do":"merge"}' \
    -o /dev/null -w '%{http_code}' "$GITEA_URL/api/v1/repos/$repo/pulls/$pr/merge"
}

pr_comment(){  # <repo> <pr> <marqueur> → le corps du commentaire portant ce marqueur
  gapi "$GITEA_URL/api/v1/repos/$1/issues/$2/comments" | python3 -c '
import json,sys
mk=sys.argv[1]; out=""
for c in json.load(sys.stdin):
    if mk in (c.get("body") or ""): out=c["body"]
print(out)' "$3"
}

# ═══════════════════════════════════════════════════════════════════════════
# OUTILLAGE — le registre CENTRAL de gouvernance
# ═══════════════════════════════════════════════════════════════════════════
GOV_AUTH=""
gov_clone(){
  rm -rf "$TMP/gov"
  GOV_AUTH=$(printf 'x:%s' "$GITEA_TOKEN" | base64 | tr -d '\n')
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0="Authorization: Basic ${GOV_AUTH}" \
    git clone -q "$GITEA_URL/$GOV_REPO.git" "$TMP/gov" 2>/dev/null || return 1
  [ -f "$TMP/gov/$GOV_PATH" ] || return 1
  cp "$TMP/gov/$GOV_PATH" "$TMP/gov-baseline.yaml"
  GOV_BASE_SHA=$(git -C "$TMP/gov" rev-parse HEAD)
}
gov_push(){  # <message>
  ( cd "$TMP/gov" && git add -A \
    && git -c user.name=ci -c user.email=ci@stoa.lab -c commit.gpgsign=false commit -q -m "$1" \
    && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0="Authorization: Basic ${GOV_AUTH}" \
       git push -q origin main ) >/dev/null 2>&1
}
# La ligne de gouvernance : c'est elle qui doit PRÉCÉDER la demande (P2).
gov_add(){  # <api> <classification> <exposure>
  printf '  - {owner: %s, tenant: %s, api: %s, classification: %s, exposure: %s}\n' \
    "$TEAM" "$TEAM" "$1" "$2" "$3" >> "$TMP/gov/$GOV_PATH"
  gov_push "gouvernance(P7): classer $1 en $2/$3"
}
gov_restore(){
  [ -d "$TMP/gov" ] || return 0
  cp "$TMP/gov-baseline.yaml" "$TMP/gov/$GOV_PATH" 2>/dev/null || return 0
  gov_push "gouvernance(P7): retirer les lignes du harnais (retour à l'état d'entrée)"
}

# ═══════════════════════════════════════════════════════════════════════════
# OUTILLAGE — la gateway RÉELLE
# ═══════════════════════════════════════════════════════════════════════════
api_id(){ wm "$WM_ADMIN/apis" | python3 -c '
import json,sys
for e in (json.load(sys.stdin).get("apiResponse") or []):
    a=e.get("api",e)
    if a.get("apiName")==sys.argv[1]: print(a["id"]); break' "$1"; }

api_tags(){ wm "$WM_ADMIN/apis/$1" | python3 -c '
import json,sys
a=json.load(sys.stdin)["apiResponse"]["api"]
for t in (a.get("apiDefinition") or {}).get("tags") or []: print(t.get("name",""))'; }

# Les cellules qui SÉLECTIONNENT cette API, telles que la GATEWAY les rend.
# C'est la seule lecture qui prouve que l'objet frappe : la liste des membres,
# elle, ne dit que ce qui a été écrit.
api_cells(){  # <id>
  local sel; sel=$(wm "$WM_ADMIN/apis/$1/globalPolicies" | python3 -c '
import json,sys
print(" ".join(json.load(sys.stdin).get("globalPolicies") or []))' 2>/dev/null)
  [ -n "$sel" ] || return 0
  wm "$WM_ADMIN/policies" | python3 -c '
import json,sys
want=set(sys.argv[1].split())
for p in json.load(sys.stdin)["policy"]:
    if p.get("id") in want:
        n=(p.get("names") or [{}])[0].get("value","")
        if n.startswith("posture-"): print(n)' "$sel"
}

# L'action transport de l'API et sa valeur — la MÊME résolution que le rôle,
# faite hors du rôle (un read-back qui réutiliserait le code écrivain ne
# prouverait que sa propre cohérence).
ep_of(){ python3 - "$WM_ADMIN" "$WM_USER" "$WM_PASS" "$1" <<'PY'
import base64,json,sys,urllib.request,urllib.error
gw,u,p,aid=sys.argv[1:5]
if not aid: print(""); raise SystemExit
auth=base64.b64encode(f"{u}:{p}".encode()).decode()
def get(path):
    r=urllib.request.Request(gw+path); r.add_header("Authorization","Basic "+auth)
    r.add_header("Accept","application/json")
    try:
        with urllib.request.urlopen(r,timeout=30) as x: return json.loads(x.read().decode() or "{}")
    except urllib.error.HTTPError: return {}
rec=(get(f"/apis/{aid}").get("apiResponse") or {}).get("api",{})
pols=[get(f"/policies/{i}").get("policy",{}) for i in rec.get("policies") or []]
svc=next((x for x in pols if x.get("policyScope")=="SERVICE"), pols[0] if pols else {})
ids=[e["enforcementObjectId"] for s in svc.get("policyEnforcements") or []
     if s.get("stageKey")=="transport" for e in s.get("enforcements") or []
     if e.get("enforcementObjectId")]
for i in ids:
    a=get(f"/policyActions/{i}").get("policyAction",{})
    if a.get("templateKey")=="entryProtocolPolicy":
        v=next((q.get("values") for q in a.get("parameters") or [] if q.get("templateKey")=="protocol"), [])
        print(",".join(v)); break
PY
}

# ep_set <id> <valeurs> — bascule l'action transport de l'API hors du rôle.
# Sert UNIQUEMENT au témoin : une API non gouvernée naît `http`-only (mesuré, cf.
# B'2), donc elle ne peut pas servir de témoin sur le canal TLS tant qu'on ne l'y
# a pas autorisée. Le PUT est ENVELOPPÉ (`{"policyAction": …}`) — la forme nue
# n'écrit rien sur cette gateway.
ep_set(){ python3 - "$WM_ADMIN" "$WM_USER" "$WM_PASS" "$1" "$2" <<'EPSET'
import base64,json,sys,urllib.request,urllib.error
gw,u,p,aid,vals=sys.argv[1:6]
auth=base64.b64encode(f"{u}:{p}".encode()).decode()
def call(m,path,body=None):
    data=json.dumps(body).encode() if body is not None else None
    r=urllib.request.Request(gw+path, data=data, method=m)
    r.add_header("Authorization","Basic "+auth); r.add_header("Accept","application/json")
    if data: r.add_header("Content-Type","application/json")
    try:
        with urllib.request.urlopen(r,timeout=30) as x: return x.status, json.loads(x.read().decode() or "{}")
    except urllib.error.HTTPError as e: return e.code, {}
rec=(call("GET",f"/apis/{aid}")[1].get("apiResponse") or {}).get("api",{})
pols=[call("GET",f"/policies/{i}")[1].get("policy",{}) for i in rec.get("policies") or []]
svc=next((x for x in pols if x.get("policyScope")=="SERVICE"), pols[0] if pols else {})
ids=[e["enforcementObjectId"] for st in svc.get("policyEnforcements") or []
     if st.get("stageKey")=="transport" for e in st.get("enforcements") or []]
for i in ids:
    a=call("GET",f"/policyActions/{i}")[1].get("policyAction",{})
    if a.get("templateKey")=="entryProtocolPolicy":
        for q in a.get("parameters") or []:
            if q.get("templateKey")=="protocol": q["values"]=vals.split(",")
        print(call("PUT",f"/policyActions/{i}",{"policyAction":a})[0]); break
EPSET
}

# Les dimensions d'identification EXIGÉES par l'API, relues hors du rôle.
iam_of(){ python3 - "$WM_ADMIN" "$WM_USER" "$WM_PASS" "$1" <<'PY'
import base64,json,sys,urllib.request,urllib.error
gw,u,p,aid=sys.argv[1:5]
if not aid: print(""); raise SystemExit
auth=base64.b64encode(f"{u}:{p}".encode()).decode()
def get(path):
    r=urllib.request.Request(gw+path); r.add_header("Authorization","Basic "+auth)
    r.add_header("Accept","application/json")
    try:
        with urllib.request.urlopen(r,timeout=30) as x: return json.loads(x.read().decode() or "{}")
    except urllib.error.HTTPError: return {}
rec=(get(f"/apis/{aid}").get("apiResponse") or {}).get("api",{})
pols=[get(f"/policies/{i}").get("policy",{}) for i in rec.get("policies") or []]
svc=next((x for x in pols if x.get("policyScope")=="SERVICE"), pols[0] if pols else {})
ids=[e["enforcementObjectId"] for s in svc.get("policyEnforcements") or []
     if s.get("stageKey")=="IAM" for e in s.get("enforcements") or []
     if e.get("enforcementObjectId")]
types=[]; anon=""
for i in ids:
    a=get(f"/policyActions/{i}").get("policyAction",{})
    for q in a.get("parameters") or []:
        if q.get("templateKey")=="allowAnonymous": anon=(q.get("values") or [""])[0]
        if q.get("templateKey")=="IdentificationRule":
            for r2 in q.get("parameters") or []:
                if r2.get("templateKey")=="identificationType": types += (r2.get("values") or [])
print(",".join(sorted(set(types))) + "|anon=" + (anon or "?"))
PY
}

purge_app(){
  local id; id=$(wm "$WM_ADMIN/applications" | python3 -c '
import json,sys
for a in (json.load(sys.stdin).get("applications") or []):
    if a.get("name")==sys.argv[1]: print(a["id"]); break' "$1")
  [ -n "$id" ] && wm -o /dev/null -X DELETE "$WM_ADMIN/applications/$id"
  return 0
}

# L'API attend d'être servie : après une reprise du conteneur, le dispatch rend
# 404 « Service not found » pendant des dizaines de secondes sur une API
# pourtant présente à l'admin. On attend un code du VOCABULAIRE du jalon.
dp_settle(){  # <api> → le code
  local c="000" n=0
  while [ "$n" -lt 40 ]; do
    n=$((n+1)); c=$(dp_code https "$1" 1.0.0 /ping)
    case "$c" in 200|401|403) printf '%s' "$c"; return 0;; esac
    sleep 3
  done
  printf '%s' "$c"
}

# fresh_window — le trial wM expire ~25 min et le keepalive le recycle à ~20 min
# d'uptime. Un build de publication lancé tard dans la fenêtre voit la gateway
# mourir EN PLEIN play, et le harnais rougirait pour une raison qui n'est pas
# celle qu'il mesure.
fresh_window(){
  local c="$WM_DP_CONTAINER" st ep up i st2
  command -v docker >/dev/null 2>&1 || return 0
  st="$(docker inspect "$c" --format '{{.State.StartedAt}}' 2>/dev/null)" || return 0
  st="${st%.*}"; st="${st%Z}"
  ep="$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$st" +%s 2>/dev/null || date -u -d "$st" +%s 2>/dev/null || echo 0)"
  [ "$ep" = "0" ] && return 0
  up=$(( ( $(date +%s) - ep ) / 60 ))
  [ "$up" -lt 15 ] && { mes "fenêtre keepalive fraîche (uptime ${up}min)"; return 0; }
  mes "uptime ${up}min — attente du recyclage keepalive avant de déclencher la publication…"
  i=0
  while [ "$i" -lt 220 ]; do
    sleep 9; i=$((i+1))
    st2="$(docker inspect "$c" --format '{{.State.StartedAt}}' 2>/dev/null)"; st2="${st2%.*}"; st2="${st2%Z}"
    [ "$st2" != "$st" ] && { mes "gateway recyclée, attente du retour de service…"; wait_admin; return 0; }
  done
  return 0
}
wait_admin(){
  local i=0
  while [ "$i" -lt 60 ]; do
    [ "$(wm -o /dev/null -w '%{http_code}' "$WM_ADMIN/apis")" = "200" ] && return 0
    i=$((i+1)); sleep 5
  done
  return 1
}

# ═══════════════════════════════════════════════════════════════════════════
echo "═══ A — PRÉFLIGHTS : la chaîne SOUS TEST est bien celle qui est SERVIE ═══"

# A1. Le dépôt PLATEFORME servi à Jenkins porte EXACTEMENT le code qu'on lit.
# Sans cette égalité, tous les verdicts qui suivent porteraient sur un autre
# code que celui du checkout — c'est le piège que le palier 3 contournait avec
# un dépôt jetable, et que ce jalon a le droit de supprimer puisque le dépôt EST
# servi.
LOCAL_SHA=$(git -C "$REPO" rev-parse HEAD 2>/dev/null)
DIRTY=$(git -C "$REPO" status --porcelain 2>/dev/null | grep -v '^??' | head -1)
SERVED_SHA=$(gapi "$GITEA_URL/api/v1/repos/ci/stoa-labs/branches/main" \
  | python3 -c 'import json,sys;print((json.load(sys.stdin).get("commit") or {}).get("id",""))' 2>/dev/null)
[ -n "$SERVED_SHA" ] || die "ci/stoa-labs@main illisible sur $GITEA_URL — les jobs n'auraient rien à cloner"
[ "$LOCAL_SHA" = "$SERVED_SHA" ] \
  && ok "A1 le dépôt plateforme servi aux jobs EST le checkout courant (${LOCAL_SHA:0:8})" \
  || ko "A1 divergence checkout/servi : local=${LOCAL_SHA:0:8} servi=${SERVED_SHA:0:8} — les builds exécuteraient un AUTRE code"
[ -z "$DIRTY" ] \
  && ok "A1b aucune modification suivie non committée (ce qui est mesuré est ce qui est servi)" \
  || ko "A1b arbre SALE ($DIRTY…) — les builds exécutent le commit, pas le fichier édité"

# A2. L'autorité de posture, SUR L'AGENT. Sans elle la chaîne refuse
# POSTURE_AUTORITE_ABSENTE — un refus juste, qui accuserait le socle.
AGENT_CELLS=$(docker exec "${P7_JENKINS_CTR:-poc-jenkins}" labctl posture --cells -o json 2>/dev/null \
  | python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("cells") or []))' 2>/dev/null)
[ "${AGENT_CELLS:-0}" -ge 9 ] \
  && ok "A2 l'agent Jenkins porte une autorité qui connaît la table de vérité ($AGENT_CELLS cellules)" \
  || ko "A2 le labctl de l'agent ne rend pas la table (POSTURE_AUTORITE_ABSENTE à la première publication)"

# A3. Les variables de SITE. GOVERNANCE_* n'ont AUCUN défaut : absentes, la
# chaîne refuse en se nommant — c'est voulu, mais alors rien ne se publie.
jcrumb || die "crumb Jenkins indisponible ($JENKINS_UI)"
GLOB=$(curl -s -m 30 -b "$JCK" -H "$JF: $JC" -X POST \
  --data-urlencode 'script=import jenkins.model.Jenkins; import hudson.slaves.EnvironmentVariablesNodeProperty
def p = Jenkins.instance.globalNodeProperties.get(EnvironmentVariablesNodeProperty)
if (p != null) { p.envVars.each { k, v -> println(k + "=" + v) } }
null' "$JENKINS_UI/scriptText" 2>/dev/null)
G_REPO=$(printf '%s' "$GLOB" | sed -n 's/^GOVERNANCE_REPO=//p' | head -1)
G_PATH=$(printf '%s' "$GLOB" | sed -n 's/^GOVERNANCE_PATH=//p' | head -1)
G_APIM=$(printf '%s' "$GLOB" | sed -n 's/^APIM_API_BASE=//p' | head -1)
[ "$G_REPO" = "$GOV_REPO" ] && [ "$G_PATH" = "$GOV_PATH" ] \
  && ok "A3 le contrôleur pose la gouvernance ($G_REPO / $G_PATH)" \
  || ko "A3 GOVERNANCE_REPO/PATH du contrôleur : '$G_REPO'/'$G_PATH' — attendu '$GOV_REPO'/'$GOV_PATH'"

# A3b. ÉGALITÉ STRUCTURELLE : le job écrit LÀ où ce harnais relit. Sans elle,
# les mesures de la section B porteraient sur une autre gateway que celle que
# la chaîne a écrite — un vert parfaitement vacant.
GW_HOSTPORT=$(printf '%s' "$G_APIM" | sed -E 's#^https?://##; s#/.*##')
AGENT_SEES=$(docker exec "${P7_JENKINS_CTR:-poc-jenkins}" curl -s -o /dev/null -w '%{http_code}' -m 10 \
  -u "$WM_USER:$WM_PASS" "$G_APIM/apis" 2>/dev/null)
[ "$AGENT_SEES" = "200" ] \
  && ok "A3b l'agent atteint la gateway que le job écrira ($GW_HOSTPORT → 200)" \
  || ko "A3b l'agent n'atteint pas $G_APIM (HTTP ${AGENT_SEES:-000}) — la publication échouerait"
# Les deux vues doivent désigner la MÊME instance : on l'établit par un objet
# témoin créé ici et relu là-bas (la seule vérification possible de l'égalité).
# L'objet témoin est une APPLICATION, et non une API : `POST /apis` en JSON nu
# est cassé sur la 10.15 (fait déjà mesuré par ce projet — la création passe par
# un multipart), et un témoin qui échoue à naître ne prouverait rien.
WITNESS="p7probe-$RUN"
W_ID=$(wm -X POST -H 'Content-Type: application/json' \
  -d "{\"name\":\"$WITNESS\",\"description\":\"temoin P7 d egalite des vues\"}" "$WM_ADMIN/applications" \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("id") or (d.get("applications") or [{}])[0].get("id",""))' 2>/dev/null)
if [ -n "$W_ID" ]; then
  SEEN=$(docker exec "${P7_JENKINS_CTR:-poc-jenkins}" curl -s -m 10 -u "$WM_USER:$WM_PASS" \
        -H 'Accept: application/json' "$G_APIM/applications/$W_ID" 2>/dev/null \
        | python3 -c 'import json,sys
d=json.load(sys.stdin)
a=(d.get("applications") or [d])[0] if isinstance(d.get("applications"),list) else d
print(a.get("name",""))' 2>/dev/null)
  [ "$SEEN" = "$WITNESS" ] \
    && ok "A3c l'agent et ce harnais voient la MÊME gateway (objet témoin relu de l'autre côté)" \
    || ko "A3c objet témoin invisible depuis l'agent — deux gateways différentes, les mesures ne prouveraient rien"
  wm -o /dev/null -X DELETE "$WM_ADMIN/applications/$W_ID"
else
  ko "A3c création de l'objet témoin impossible — égalité des deux vues non établie"
fi

# A4. Les objets d'ENVIRONNEMENT que la posture suppose : les cellules (P4) et
# le listener HTTPS (P5). Ce sont des amorçages, pas le travail du pipeline.
NCELL=$(wm "$WM_ADMIN/policies" | python3 -c '
import json,sys
print(sum(1 for p in json.load(sys.stdin)["policy"]
          if (p.get("names") or [{}])[0].get("value","").startswith("posture-")))' 2>/dev/null)
[ "${NCELL:-0}" -ge 9 ] \
  && ok "A4 les cellules de posture sont amorcées sur la gateway ($NCELL)" \
  || ko "A4 $NCELL cellule(s) posture-* — jouer ansible/apim-global-posture-setup.yml"
# L'enveloppe est `listeners` (relevée sur la 10.15 : ni `ports` ni `port`).
TLS_PORT=$(wm "$WM_ADMIN/ports" | python3 -c '
import json,sys
for p in (json.load(sys.stdin).get("listeners") or []):
    if str(p.get("protocol","")).upper()=="HTTPS" and str(p.get("enabled")).lower()=="true":
        print(p.get("port")); break' 2>/dev/null)
[ -n "$TLS_PORT" ] \
  && { ok "A4b le listener HTTPS d'environnement est en service (:$TLS_PORT)"; \
       export WM_DP_TLS_BASE="${WM_DP_TLS_BASE:-https://localhost:$TLS_PORT/gateway}"; } \
  || ko "A4b aucun listener HTTPS actif — jouer ansible/is-https-listener.yml"
# shellcheck source=scripts/lib/wm-dataplane.sh
. "$REPO/scripts/lib/wm-dataplane.sh"

# A5. Le dépôt d'ÉQUIPE, son webhook, et le SECOND humain.
TEAM_REPO=$(python3 -c '
import sys,yaml
d=yaml.safe_load(open(sys.argv[1])) or {}
e=next((p for p in (d.get("providers") or []) if p.get("team")==sys.argv[2]), None)
print((e or {}).get("repo") or "")' "$REPO/ansible/providers.dev.yml" "$TEAM" 2>/dev/null)
[ -n "$TEAM_REPO" ] \
  && ok "A5 l'équipe '$TEAM' porte un dépôt déclaré ($TEAM_REPO)" \
  || die "équipe '$TEAM' sans dépôt dans providers.dev.yml — rien à publier"
NHOOK=$(gapi "$GITEA_URL/api/v1/repos/$TEAM_REPO/hooks" | python3 -c '
import json,sys
print(sum(1 for h in json.load(sys.stdin) if "stoa-team-publish" in ((h.get("config") or {}).get("url") or "")))' 2>/dev/null)
[ "${NHOOK:-0}" -ge 1 ] \
  && ok "A5b le dépôt d'équipe porte le webhook team-publish" \
  || ko "A5b aucun webhook team-publish sur $TEAM_REPO — le merge ne réveillerait rien"
MPERM=$(gapi "$GITEA_URL/api/v1/repos/$TEAM_REPO/collaborators/$MERGER/permission" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("permission",""))' 2>/dev/null)
case "$MPERM" in write|admin) ok "A5c '$MERGER' peut fusionner ($MPERM) — le second humain existe";;
  *) ko "A5c '$MERGER' n'a pas le droit de fusionner sur $TEAM_REPO (permission='$MPERM')";; esac

# A6. La file de team-publish est LIBRE. Le job porte
# DisableConcurrentBuilds : une pause laissée par un autre run bloquerait le
# nôtre EN FILE, et wfapi rendrait un statut VIDE — un échec qui ne ressemble
# ni à un problème de webhook ni à un problème de job.
BUSY=$(curl -s -m 30 "$JENKINS_UI/job/team-publish/api/json?tree=builds%5Bnumber,building%5D" \
  | python3 -c 'import json,sys
print(" ".join(str(b["number"]) for b in json.load(sys.stdin).get("builds",[]) if b.get("building")))' 2>/dev/null)
[ -z "$BUSY" ] \
  && ok "A6 aucune pause team-publish en cours — la file est libre" \
  || ko "A6 build(s) team-publish en cours : $BUSY (pause d'un AUTRE run — ce harnais n'y touche pas ; la solder puis relancer)"

# A7. Le registre central est joignable ET modifiable par la gouvernance.
gov_clone \
  && ok "A7 le registre central est joignable ($GOV_REPO/$GOV_PATH, HEAD ${GOV_BASE_SHA:0:8})" \
  || die "registre central injoignable ou absent — la posture ne serait arbitrée par personne"

[ "$FAIL" -eq 0 ] || die "préflights en échec ($FAIL) — les mesures qui suivent ne prouveraient rien"

# ═══════════════════════════════════════════════════════════════════════════
# LE PARCOURS COMPLET, EN UNE FONCTION — c'est LUI la porte du jalon
# ═══════════════════════════════════════════════════════════════════════════
# chain <api> <classification déclarée> <exposure déclarée> <attendu: publish|refus>
#   → pose la ligne de gouvernance A ÉTÉ FAITE par l'appelant (gov_add),
#     déclenche le formulaire, ouvre la PR, la fait fusionner par le SECOND
#     humain, répond à la pause, et rend :
#       CHAIN_PR         numéro de PR
#       CHAIN_BUILD      numéro du build team-publish
#       CHAIN_RESULT     verdict du build (SUCCESS/FAILURE/…)
#       CHAIN_COMMENT    le commentaire team-publish laissé sur la PR
CHAIN_PR=""; CHAIN_BUILD=""; CHAIN_RESULT=""; CHAIN_COMMENT=""
chain(){
  local api="$1" cls="$2" exp="$3" spec form n st br pr rc sub
  CHAIN_PR=""; CHAIN_BUILD=""; CHAIN_RESULT=""; CHAIN_COMMENT=""
  spec="openapi: 3.0.0
info: { title: $api, version: 1.0.0 }
servers: [ { url: \"http://poc-token-echo:8080\" } ]
tags: [ { name: metier-p7 } ]
paths:
  /ping:
    get:
      operationId: ping
      tags: [ metier-p7 ]
      responses: { '200': { description: ok } }"
  form="$TMP/form-$api.txt"
  P7F_ACTION=create P7F_TEAM="$TEAM" P7F_API_NAME="$api" P7F_API_VERSION=1.0.0 \
  P7F_API_BASE="" P7F_NEW_VERSION="" P7F_OPENAPI_SPEC="$spec" P7F_INBOUND_MODE=jwt \
  P7F_CLASSIFICATION="$cls" P7F_EXPOSURE="$exp" form_file "$form"

  n=$(jbuild api-request "$form")
  [ -n "$n" ] || { ko "$api : build api-request non démarré (file/quiet period)"; return 1; }
  st=$(jwait_end api-request "$n" 420)
  jwait_built api-request "$n"
  jlog api-request "$n" > "$TMP/req-$api.log"
  pr=$(grep -oE 'PR #[0-9]+ ouverte' "$TMP/req-$api.log" | grep -oE '[0-9]+' | head -1)
  [ -n "$pr" ] || { ko "$api : aucune PR ouverte par le formulaire (build #$n, $st)"; \
                    grep -E 'REFUS|CHAMP_REQUIS|❌' "$TMP/req-$api.log" | head -3 | sed 's/^/       /'; return 1; }
  CHAIN_PR="$pr"; br="api/${api}-1.0.0"
  CREATED_BRANCHES="$CREATED_BRANCHES $br"
  settle

  fresh_window
  rc=$(merge_pr "$TMP/ohdr" "$TEAM_REPO" "$pr")
  [ "$rc" = "200" ] || { ko "$api : merge par $MERGER refusé (HTTP $rc)"; return 1; }

  CHAIN_BUILD=$(find_publish_build "$br")
  [ -n "$CHAIN_BUILD" ] || { ko "$api : aucun build team-publish déclenché par le webhook"; return 1; }
  MY_PAUSES="$MY_PAUSES $CHAIN_BUILD"
  st=$(jwait team-publish "$CHAIN_BUILD" 300)
  if [ "$st" = "PAUSED_PENDING_INPUT" ]; then
    printf '%s' "$LAB_OSCAR_PASS" > "$TMP/mpass"; chmod 600 "$TMP/mpass"
    sub=$(answer_pause team-publish "$CHAIN_BUILD" "$MERGER" "$TMP/mpass")
    rm -f "$TMP/mpass"
    case "$sub" in 200|302) : ;; *) ko "$api : réponse à la pause refusée (HTTP $sub)";; esac
  else
    ko "$api : la pause nominative ne s'est pas ouverte (statut '$st')"
  fi
  jwait_end team-publish "$CHAIN_BUILD" 600 >/dev/null
  jwait_built team-publish "$CHAIN_BUILD"
  sleep 3   # le post{} pose le commentaire APRÈS le FINISHED de wfapi
  CHAIN_RESULT=$(jresult team-publish "$CHAIN_BUILD")
  CHAIN_COMMENT=$(pr_comment "$TEAM_REPO" "$pr" '<!-- team-publish -->')
  jlog team-publish "$CHAIN_BUILD" > "$TMP/pub-$api.log"
  return 0
}

# L'en-tête d'identité du SECOND humain : token Gitea ÉPHÉMÈRE, minté pour CE
# run. C'est bien LUI qui fusionne — la garde d'identité de team-publish
# confronte ensuite ce login à celui du coffre.
OTOK=$(docker exec -u git "${P7_GITEA_CTR:-poc-gitea}" gitea admin user generate-access-token \
  --username "$MERGER" --token-name "p7-$RUN" --scopes write:repository,write:issue 2>/dev/null \
  | grep -oE '[0-9a-f]{40}')
[ -n "$OTOK" ] || die "mint du token Gitea de '$MERGER' impossible"
printf 'Authorization: token %s\n' "$OTOK" > "$TMP/ohdr"; chmod 600 "$TMP/ohdr"; unset OTOK

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "═══ B — TROIS COMBINAISONS, PAR BUILDS RÉELS, ET LEURS MESURES ═══"

API_MI="p7mi-$RUN"    # M  × internal  — déclarée honnêtement
API_ME="p7me-$RUN"    # M  × external  — l'exposition bouge, l'intégrité non
API_HE="p7he-$RUN"    # H  × external  — l'intégrité bouge, l'exposition non
API_OV="p7ov-$RUN"    # M  × internal AU REGISTRE, déclarée VH/internal (C2)

gov_add "$API_MI" M  internal
gov_add "$API_ME" M  external
gov_add "$API_HE" H  external
gov_add "$API_OV" M  internal
ok "B0 la gouvernance PRÉCÈDE la demande : 4 lignes poussées dans $GOV_REPO@main"

# measure <api> <bundle attendu> <dimensions d'identité attendues>
#   → pose les mesures ET rend l'EMPREINTE de posture sur stdout
FINGERPRINT=""
measure(){
  local api="$1" bundle="$2" want_ci="$3" id tags cells ep iam nres
  FINGERPRINT=""
  id=$(api_id "$api")
  [ -n "$id" ] || { ko "$api : API absente de la gateway après publication"; return 1; }
  ok "$api existe sur la gateway ($id)"

  # ── le TAG (P3) : un seul dans l'espace réservé, et les tags métier vivants
  tags=$(api_tags "$id")
  nres=$(printf '%s\n' "$tags" | grep -c '^posture:')
  printf '%s\n' "$tags" | grep -qx "posture:$bundle" \
    && ok "  tag — l'API porte la posture GOUVERNÉE (posture:$bundle)" \
    || ko "  tag — attendu posture:$bundle, relu : $(printf '%s' "$tags" | tr '\n' ' ')"
  [ "$nres" = "1" ] \
    && ok "  tag — un SEUL tag dans l'espace de noms de la plateforme" \
    || ko "  tag — $nres tags réservés coexistent"
  printf '%s\n' "$tags" | grep -qx 'metier-p7' \
    && ok "  tag — le tag MÉTIER du producteur est préservé" \
    || ko "  tag — le tag métier du contrat a été détruit"

  # ── la CELLULE (P4) : ce que la GATEWAY sélectionne, pas ce qu'on a écrit
  cells=$(api_cells "$id" | tr '\n' ' ' | xargs)
  [ "$cells" = "posture-$bundle" ] \
    && ok "  cellule — la gateway SÉLECTIONNE posture-$bundle, et elle SEULE" \
    || ko "  cellule — la gateway sélectionne : '${cells:-(aucune)}'"

  # ── le PROTOCOLE (P5) : sur l'API, pas sur un port
  ep=$(ep_of "$id")
  [ "$ep" = "https" ] \
    && ok "  protocole — l'API porte entryProtocolPolicy=[https]" \
    || ko "  protocole — relu '$ep', attendu 'https'"

  # ── l'IDENTITÉ (P6) : les dimensions exigées, et le refus par défaut
  iam=$(iam_of "$id")
  [ "$iam" = "$want_ci" ] \
    && ok "  identité — dimensions exigées : $iam" \
    || ko "  identité — relu '$iam', attendu '$want_ci'"

  FINGERPRINT="tag=posture:$bundle|cell=$cells|ep=$ep|iam=$iam"
  return 0
}

run_case(){  # <api> <cls déclarée> <exp déclarée> <bundle attendu> <iam attendu>
  local api="$1"
  echo
  echo "── $api : formulaire ${2}/${3} → PR → merge($MERGER) → publication ──"
  chain "$api" "$2" "$3" || return 1
  CREATED_APIS="$CREATED_APIS $api"
  [ "$CHAIN_RESULT" = "SUCCESS" ] \
    && ok "$api : le build team-publish #$CHAIN_BUILD est VERT" \
    || { ko "$api : build team-publish #$CHAIN_BUILD = ${CHAIN_RESULT:-?}"; \
         grep -E '"msg": "[A-Z_]+' "$TMP/pub-$api.log" | tail -3 | sed 's/^/       /'; }
  printf '%s' "$CHAIN_COMMENT" | grep -q '✅ team-publish' \
    && ok "$api : le ✅ de publication est sur la PR #$CHAIN_PR" \
    || ko "$api : aucun ✅ team-publish sur la PR #$CHAIN_PR"
  printf '%s' "$CHAIN_COMMENT" | grep -q "POSTURE_RETENUE.*bundle=$4" \
    && ok "$api : la PR porte la posture RETENUE du registre (bundle=$4)" \
    || ko "$api : POSTURE_RETENUE absente ou d'un autre bouquet sur la PR — le demandeur ne sait pas ce qui a été appliqué"
  printf '%s' "$CHAIN_COMMENT" | grep -q 'POSTURE_COUVERTURE' \
    && ok "$api : la PR dit ce que la chaîne a VRAIMENT opposé du bouquet" \
    || ko "$api : POSTURE_COUVERTURE absente de la PR — la couverture reste tacite"
  measure "$api" "$4" "$5"
}

run_case "$API_MI" M  internal m-internal "jwtClaims|anon=false"
FP_MI="$FINGERPRINT"
run_case "$API_ME" M  external m-external "ipAddressRange,jwtClaims|anon=false"
run_case "$API_HE" H  external h-external "ipAddressRange,jwtClaims|anon=false"

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "═══ B' — LA PORTE AU PLAN DE DONNÉES : ce que l'API oppose, et à qui ═══"

# CE QUE CETTE SECTION MESURE, ET CE QU'ELLE A DÛ CORRIGER. Le premier passage
# attendait qu'une API `external` publiée par la chaîne SERVE (200) un appelant
# dont l'IP est déclarée sur une application souscrite. Elle rend 401 — et la
# mesure qui suit explique pourquoi, sans rien inventer :
#   - la règle d'identification de P6 a le connecteur **AND** : une cellule
#     `external` exige `ipAddressRange` EN PLUS de la dimension du volet inbound,
#     elle ne la remplace pas ;
#   - et la dimension du volet inbound, en mode `jwt`, est `jwtClaims`, qu'AUCUN
#     identifiant d'application ne résout sur ce produit (B'5, mesuré ici avec un
#     jeton réel de l'IdP du lab). L'API est donc fermée à tous.
# La porte de cette section n'est donc pas « l'API sert le bon appelant » : c'est
# **l'API refuse, et le refus lui est ATTRIBUABLE**. Un témoin publié par le rôle
# sans gouvernance et sans volet inbound répond, lui, 200 sur le MÊME listener et
# depuis le MÊME appelant : sans lui, les 401 et 500 ci-dessous ne prouveraient
# rien de plus que l'existence d'un pare-feu quelque part.

CALLER=$(docker inspect "$WM_DP_CONTAINER" \
  --format '{{range $k,$v := .NetworkSettings.Networks}}{{if $v.IPAddress}}{{$v.IPAddress}}{{println}}{{end}}{{end}}' 2>/dev/null | head -1)
[ -n "$CALLER" ] && ok "B'0 l'IP de l'appelant est DÉTERMINÉE, pas devinée : $CALLER" \
                 || ko "B'0 IP de l'appelant inconnue"
export WM_DP_TLS_BASE="https://$CALLER:${TLS_PORT:-5543}/gateway"

# ── LE TÉMOIN : publié par le RÔLE, sans registre (POSTURE_NON_ARBITREE) et
#    sans volet inbound. Ni protocole imposé, ni identification exigée : il doit
#    répondre 200 partout. C'est lui qui rend les refus attribuables.
API_T="p7temoin-$RUN"
TW="$TMP/temoin"; mkdir -p "$TW"
printf 'openapi: 3.0.0\ninfo: { title: %s, version: 1.0.0 }\nservers: [ { url: "http://poc-token-echo:8080" } ]\npaths:\n  /ping:\n    get: { operationId: ping, responses: { "200": { description: ok } } }\n' "$API_T" > "$TW/$API_T.yaml"
printf -- '---\napim_api:\n  name: "%s"\n  version: "1.0.0"\n  contract: "%s/%s.yaml"\n  team: ""\n' "$API_T" "$TW" "$API_T" > "$TW/$API_T.yml"
printf 'providers:\n  - team: %s\n    repo: %s\n    approvers: []\n' "$TEAM" "$TEAM_REPO" > "$TW/providers.yml"
if ansible-playbook -i ansible/inventory.lab.ini ansible/publish-api.yml \
     -e "apim_ss_manifest=$TW/$API_T.yml" -e "apim_ss_team=$TEAM" \
     -e "apim_pub_labctl_bin=$LABCTL_BIN" -e "apim_pub_providers_file=$TW/providers.yml" \
     > "$TMP/temoin.log" 2>&1; then
  CREATED_APIS="$CREATED_APIS $API_T"
  ok "B'1 témoin publié SANS gouvernance (POSTURE_NON_ARBITREE) — ni protocole imposé, ni identité exigée"
else
  ko "B'1 publication du témoin en échec — les refus de cette section ne seront attribuables à rien"
  tail -6 "$TMP/temoin.log" | sed 's/^/       /'
fi
dp_wait clair "$API_T" 1.0.0 /ping 25 >/dev/null 2>&1
ID_T=$(api_id "$API_T")
EP_T=$(ep_of "$ID_T")
T_CLEAR=$(dp_code clair "$API_T" 1.0.0 /ping); T_TLS=$(dp_code https "$API_T" 1.0.0 /ping)
mes "témoin : entryProtocolPolicy=[${EP_T:-(aucune)}] clair=$T_CLEAR https=$T_TLS"
# FAIT PRODUIT MESURÉ ICI, et il complète exactement P5 : une API importée porte
# DÉJÀ une action `entryProtocolPolicy`, et sa valeur par défaut est `http`. Le
# protocole est donc une décision PAR API **dans les deux sens** — la gouvernée
# refuse le clair, la NON gouvernée refuse le TLS — et jamais une propriété du
# port. Un listener n'a jamais servi ni protégé personne tout seul.
[ "$T_CLEAR" = "200" ] \
  && ok "B'2 le témoin non gouverné est SERVI en clair — ce canal ne refuse rien de lui-même" \
  || ko "B'2 témoin en clair = $T_CLEAR (attendu 200) — l'attribution du refus de B'3 est perdue"
{ [ "$EP_T" = "http" ] && [ "$T_TLS" != "200" ]; } \
  && ok "B'2b FAIT — une API importée naît http-only (entryProtocolPolicy=[http]) et REFUSE le TLS ($T_TLS) : le protocole est une décision par API dans les DEUX sens" \
  || ko "B'2b témoin : ep=[$EP_T] https=$T_TLS — le défaut du produit n'est plus celui qui est documenté ici"
# Pour que le témoin serve d'attribution sur le canal TLS, on l'y AUTORISE
# explicitement — geste de harnais, nommé, qui ne touche à aucune identité : le
# témoin reste SANS règle d'identification, ce qui est tout son intérêt.
ep_set "$ID_T" https >/dev/null 2>&1
dp_wait https "$API_T" 1.0.0 /ping 25 >/dev/null 2>&1
T_TLS2=$(dp_code https "$API_T" 1.0.0 /ping)
mes "témoin autorisé en TLS : https=$T_TLS2"
[ "$T_TLS2" = "200" ] \
  && ok "B'2c le témoin, autorisé en TLS et SANS règle d'identification, est SERVI (200) sur le listener d'environnement" \
  || ko "B'2c témoin en TLS = $T_TLS2 (attendu 200) — l'attribution du refus de B'5 est perdue"

# ── LE PROTOCOLE : la MÊME requête, sur le MÊME port que le témoin
C_CLEAR=$(dp_code clair "$API_MI" 1.0.0 /ping)
B_CLEAR=$(dp_body clair "$API_MI" 1.0.0 /ping)
mes "$API_MI en CLAIR : HTTP $C_CLEAR"
[ "$C_CLEAR" != "200" ] \
  && ok "B'3 l'appel en CLAIR d'une API publiée PAR LA CHAÎNE est refusé (HTTP $C_CLEAR) là où le témoin passe" \
  || ko "B'3 l'appel en clair PASSE — l'API gouvernée sert en clair"
printf '%s' "$B_CLEAR" | grep -q 'Transport protocol not supported' \
  && ok "B'4 …et le refus est celui du PROTOCOLE, pas du réseau (message du produit)" \
  || ko "B'4 le refus n'est pas celui du protocole : $(printf '%s' "$B_CLEAR" | head -c 100)"

# ── L'INSCRIPTION AU PORT, dite honnêtement : le listener PORTE l'API et ne la
#    protège pas — le témoin, servi 200 sur ce même listener, en est la preuve.
C_TLS=$(dp_settle "$API_MI")
mes "$API_MI en HTTPS : HTTP $C_TLS"
case "$C_TLS" in 401|403) ok "B'5 inscription au port — la MÊME API est portée par le listener d'environnement (:${TLS_PORT:-5543}) et y REFUSE l'appelant non identifié (HTTP $C_TLS)";;
  200) ko "B'5 l'API gouvernée SERT un appelant non identifié (200) — le refus par défaut de P6 ne mord pas";;
  *) ko "B'5 l'API n'est pas servie par le listener HTTPS (HTTP $C_TLS)";; esac

# ── LE FAIT PRODUIT DU JALON : un JETON RÉEL ne suffit pas. On présente un jeton
#    émis par l'IdP du lab, et une application SOUSCRITE portant un identifiant
#    de claim qui matche ce jeton. Si l'API répondait 200, la dégradation
#    `oauth2` serait bien « un contrôle plus faible » ; elle rend 401, et c'est
#    une information de premier ordre pour le client.
APP_N="p7consumer-$RUN"; CREATED_APP="$APP_N"
app_identify(){  # <json des identifiers> <api-id…>
  local aid ids="" i
  for i in "${@:2}"; do ids="$ids\"$i\","; done; ids="${ids%,}"
  aid=$(wm "$WM_ADMIN/applications" | python3 -c '
import json,sys
for a in (json.load(sys.stdin).get("applications") or []):
    if a.get("name")==sys.argv[1]: print(a["id"]); break' "$APP_N")
  if [ -z "$aid" ]; then
    aid=$(wm -X POST -H 'Content-Type: application/json' \
      -d "{\"name\":\"$APP_N\",\"description\":\"harnais P7\"}" "$WM_ADMIN/applications" \
      | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("id") or (d.get("applications") or [{}])[0].get("id",""))')
  fi
  [ -n "$aid" ] || return 1
  wm -o /dev/null -X PUT -H 'Content-Type: application/json' \
    -d "{\"apiIDs\":[$ids]}" "$WM_ADMIN/applications/$aid/apis"
  wm "$WM_ADMIN/applications/$aid" | python3 -c '
import json,sys
d=json.load(sys.stdin)
app=(d.get("applications") or [d])[0] if isinstance(d.get("applications"),list) else d
app["identifiers"]=json.loads(sys.argv[1])
print(json.dumps(app))' "$1" > "$TMP/app.json"
  wm -o /dev/null -X PUT -H 'Content-Type: application/json' \
    --data-binary @"$TMP/app.json" "$WM_ADMIN/applications/$aid"
  printf '%s' "$aid"
}
ID_MI=$(api_id "$API_MI"); ID_HE=$(api_id "$API_HE")
# Le jeton est celui d'un client de service RÉEL du realm du lab ; son `azp` est
# recopié dans l'identifiant de claim de l'application. Aucun secret en argv :
# le client_secret est lu par l'API d'admin et ne quitte pas ce shell.
KCTOK=""
if KCADM=$(curl -s -m 20 -X POST "${P7_KC:-http://localhost:8480}/realms/master/protocol/openid-connect/token" \
      -d grant_type=password -d client_id=admin-cli \
      -d "username=${KEYCLOAK_ADMIN:-admin}" --data-urlencode "password=${KEYCLOAK_ADMIN_PASSWORD:-admin}" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token") or "")') && [ -n "$KCADM" ]; then
  KCID=$(curl -s -m 20 -H "Authorization: Bearer $KCADM" \
    "${P7_KC:-http://localhost:8480}/admin/realms/${P7_REALM:-stoa-lab}/clients?clientId=${P7_KC_CLIENT:-accounts-read-consumer}" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["id"] if d else "")')
  if [ -n "$KCID" ]; then
    KCSEC=$(curl -s -m 20 -H "Authorization: Bearer $KCADM" \
      "${P7_KC:-http://localhost:8480}/admin/realms/${P7_REALM:-stoa-lab}/clients/$KCID/client-secret" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("value") or "")')
    KCTOK=$(curl -s -m 20 -X POST "${P7_KC:-http://localhost:8480}/realms/${P7_REALM:-stoa-lab}/protocol/openid-connect/token" \
      -d grant_type=client_credentials -d "client_id=${P7_KC_CLIENT:-accounts-read-consumer}" \
      --data-urlencode "client_secret=$KCSEC" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token") or "")')
    unset KCSEC
  fi
fi
if [ -n "$KCTOK" ]; then
  APP_ID=$(app_identify "[{\"name\":\"claims\",\"key\":\"jwtClaims\",\"value\":[\"azp=${P7_KC_CLIENT:-accounts-read-consumer}\"]},{\"name\":\"ip-allowlist\",\"key\":\"ipAddressRange\",\"value\":[\"$CALLER-$CALLER\"]}]" "$ID_MI" "$ID_HE")
  [ -n "$APP_ID" ] \
    && ok "B'6 une application SOUSCRITE porte l'identifiant de claim du jeton ET l'IP de l'appelant" \
    || ko "B'6 application témoin non créée"
  sleep 5
  printf '%s' "$KCTOK" > "$TMP/kc.tok"; chmod 600 "$TMP/kc.tok"
  bearer(){ docker exec -i -e T="$(cat "$TMP/kc.tok")" "$WM_DP_CONTAINER" \
    sh -c "curl -sk -m 10 -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer \$T\" \"https://$CALLER:${TLS_PORT:-5543}/gateway/$1/1.0.0/ping\"" 2>/dev/null; }
  BT_MI=$(bearer "$API_MI"); BT_HE=$(bearer "$API_HE"); BT_T=$(bearer "$API_T")
  mes "avec un JETON RÉEL de l'IdP : $API_MI(internal)=$BT_MI  $API_HE(external)=$BT_HE  témoin=$BT_T"
  [ "$BT_T" = "200" ] \
    && ok "B'7 le témoin reste servi avec le même jeton — le jeton n'est pas le problème" \
    || ko "B'7 le témoin ne répond plus (HTTP $BT_T) — la mesure suivante ne serait attribuable à rien"
  { [ "$BT_MI" != "200" ] && [ "$BT_HE" != "200" ]; } \
    && ok "B'8 LE FAIT : un jeton VALIDE et un identifiant de claim ne suffisent pas ($BT_MI/$BT_HE) — jwtClaims n'est résolu par AUCUN identifiant d'application (l'identité runtime vient de la stratégie OAuth2, que le mode 'jwt' ne configure pas)" \
    || ko "B'8 une API gouvernée a SERVI le jeton ($BT_MI/$BT_HE) : la dégradation oauth2 doit être re-qualifiée"
  rm -f "$TMP/kc.tok"
else
  skip "B'6..B'8 aucun jeton obtenu de l'IdP du lab — le fait produit du jalon n'est pas rejoué ici (voir le handoff)"
fi

# ── LE DIFFÉRENTIEL DE CELLULE, là où il est OBSERVABLE : sur la règle même.
#    Au plan de données il ne l'est pas — les deux cellules refusent, pour la
#    raison ci-dessus — et l'affirmer quand même serait un vert vacant.
IAM_MI=$(iam_of "$ID_MI"); IAM_HE=$(iam_of "$ID_HE")
mes "règles relues : internal=[$IAM_MI] external=[$IAM_HE]"
{ printf '%s' "$IAM_HE" | grep -q 'ipAddressRange' && ! printf '%s' "$IAM_MI" | grep -q 'ipAddressRange'; } \
  && ok "B'9 LE DIFFÉRENTIEL — la cellule 'external' EXIGE la dimension réseau, 'internal' ne l'exige pas : c'est la posture gouvernée qui compose la règle" \
  || ko "B'9 les deux cellules composent la même règle — la posture ne décide de rien"

echo
echo "═══ C — LA CONTRE-ÉPREUVE DU GOAL : le manifeste ne décide pas ═══"

# C1 — DÉCLARER PLUS FORT : accepté, et la posture appliquée est CELLE DU
# REGISTRE. Deux APIs, même ligne de gouvernance (M/internal), deux
# déclarations différentes : les empreintes doivent être IDENTIQUES.
run_case "$API_OV" VH internal m-internal "jwtClaims|anon=false"
FP_OV="$FINGERPRINT"
[ -n "$FP_MI" ] && [ "$FP_MI" = "$FP_OV" ] \
  && ok "C1 LA CONTRE-ÉPREUVE — déclarée VH/internal, l'API reçoit EXACTEMENT la posture de la ligne M/internal ($FP_OV)" \
  || ko "C1 empreintes divergentes : honnête='$FP_MI' sur-déclarée='$FP_OV'"
printf '%s' "$CHAIN_COMMENT" | grep -qE 'sur-provision|déclarait VH' \
  && ok "C1b …et la PR DIT que la demande déclarait autre chose" \
  || ko "C1b la PR ne signale pas l'écart entre la déclaration et la posture retenue"

# C2 — DÉCLARER PLUS FAIBLE : refus NOMMÉ, avant toute écriture. La ligne de
# gouvernance dit H/external ; la demande dit M/internal — moins critique ET
# moins exposée, exactement le geste que le GOAL veut voir échouer.
API_SP="p7sp-$RUN"
gov_add "$API_SP" H external
echo
echo "── $API_SP : registre H/external, formulaire M/internal ──"
chain "$API_SP" M internal
if [ -n "$CHAIN_PR" ]; then
  CB=$(pr_comment "$TEAM_REPO" "$CHAIN_PR" '<!-- api-request -->')
  printf '%s%s' "$CB" "$CHAIN_COMMENT" | grep -q 'CLASSIFICATION_SPOOFED' \
    && ok "C2 LA CONTRE-ÉPREUVE — la déclaration plus faible est refusée, NOMMÉE (CLASSIFICATION_SPOOFED)" \
    || ko "C2 aucun CLASSIFICATION_SPOOFED relayé : $(printf '%s%s' "$CB" "$CHAIN_COMMENT" | tr '\n' ' ' | head -c 160)"
  [ -z "$(api_id "$API_SP")" ] \
    && ok "C2b …et RIEN n'a été créé sur la gateway (le refus précède la première écriture)" \
    || { ko "C2b l'API a été créée MALGRÉ le refus de posture"; CREATED_APIS="$CREATED_APIS $API_SP"; }
else
  ko "C2 la chaîne n'a rien produit — la contre-épreuve n'a pas pu être jouée"
fi

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "═══ D — LES REFUS STRUCTURELS : ce que la chaîne refuse de publier, et pourquoi ═══"

# D1 — par BUILD RÉEL : une cellule dont deux dimensions ne sont opposées par
# RIEN sur ce produit. Le refus doit arriver sur la PR, nommé.
API_NX="p7nx-$RUN"
gov_add "$API_NX" VH internet
echo
echo "── $API_NX : registre VH/internet — mtls et threat-protection non déclinables ──"
chain "$API_NX" VH internet
if [ -n "$CHAIN_PR" ]; then
  printf '%s' "$CHAIN_COMMENT" | grep -q 'POSTURE_NON_DECLINABLE' \
    && ok "D1 la cellule VH/internet est REFUSÉE, nommée, sur la PR (POSTURE_NON_DECLINABLE)" \
    || ko "D1 aucun POSTURE_NON_DECLINABLE sur la PR : $(printf '%s' "$CHAIN_COMMENT" | tr '\n' ' ' | head -c 160)"
  [ -z "$(api_id "$API_NX")" ] \
    && ok "D1b …et RIEN n'a été créé : le refus précède les secrets et le premier appel" \
    || { ko "D1b l'API VH/internet a été créée malgré le refus"; CREATED_APIS="$CREATED_APIS $API_NX"; }
else
  ko "D1 la chaîne n'a rien produit pour VH/internet"
fi

# D2 — hors ligne : la même garde, jouée sans gateway ni Vault, sur les quatre
# cas qui la définissent. C'est ce qui la rend rejouable en revue.
covdir="$TMP/cov"; mkdir -p "$covdir"
cat > "$covdir/registry.yaml" <<YML
apiVersion: governance.stoa.io/v1
kind: ClassificationRegistry
classifications:
  - {owner: $TEAM, tenant: $TEAM, api: cov-ok,   classification: M,  exposure: internal}
  - {owner: $TEAM, tenant: $TEAM, api: cov-mtls, classification: VH, exposure: internal}
  - {owner: $TEAM, tenant: $TEAM, api: cov-tp,   classification: VH, exposure: internet}
YML
printf 'providers:\n  - team: %s\n    repo: %s\n    approvers: []\n' "$TEAM" "$TEAM_REPO" > "$covdir/providers.yml"
covman(){  # <api> <cls> <exp> <avec inbound: 1|0>
  { printf -- '---\napim_api:\n  name: "%s"\n  version: "1.0.0"\n  contract: "%s/x.yaml"\n  team: ""\n  classification: "%s"\n  exposure: "%s"\n' "$1" "$covdir" "$2" "$3"
    [ "$4" = "1" ] && printf '  inbound:\n    alias_name: "BankAuth-demo"\n    mode: "jwt"\n'; } > "$covdir/$1.yml"
  printf 'openapi: 3.0.0\ninfo: { title: x, version: 1.0.0 }\npaths: {}\n' > "$covdir/x.yaml"
}
covrun(){ ansible-playbook -i ansible/inventory.lab.ini ansible/test-coverage-guards.yml \
  -e "apim_ss_manifest=$covdir/$1.yml" -e "apim_ss_team=$TEAM" \
  -e "apim_pub_classification_source=$covdir/registry.yaml" \
  -e "apim_pub_labctl_bin=$LABCTL_BIN" -e "apim_pub_providers_file=$covdir/providers.yml" 2>&1; }
if command -v ansible-playbook >/dev/null 2>&1; then
  covman cov-ok   M  internal 1; OUT=$(covrun cov-ok); RC=$?
  { [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "POSTURE_COUVERTURE.*opposées=\['audit-log', 'https-only', 'rate-limit'\].*dégradées=\['oauth2'\]"; } \
    && ok "D2 hors ligne — M/internal passe, en NOMMANT ce qu'elle oppose et ce qu'elle dégrade" \
    || ko "D2 M/internal : rc=$RC, couverture=$(printf '%s' "$OUT" | grep -oE 'POSTURE_COUVERTURE[^"]{0,110}' | head -1)"
  covman cov-mtls VH internal 1; OUT=$(covrun cov-mtls); RC=$?
  { [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "POSTURE_NON_DECLINABLE.*\['mtls'\]"; } \
    && ok "D2b hors ligne — VH/internal REFUSÉE : mtls n'est déclinable par aucune API sur ce produit" \
    || ko "D2b VH/internal : rc=$RC (attendu un refus nommant mtls)"
  covman cov-ok   M  internal 0; OUT=$(covrun cov-ok); RC=$?
  { [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'POSTURE_AUTHN_ABSENTE'; } \
    && ok "D2c hors ligne — dégrader l'authentification suppose qu'il en reste une (POSTURE_AUTHN_ABSENTE)" \
    || ko "D2c manifeste sans inbound sur une cellule qui exige oauth2 : rc=$RC (attendu un refus)"
else
  skip "D2 ansible-playbook absent — la garde hors ligne n'est pas jouée"
fi

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "═══ E — MUTATIONS : ce harnais SAIT rougir ═══"

COVFILE="ansible/roles/apim_publish_api/tasks/coverage.yml"
DEFFILE="ansible/roles/apim_publish_api/defaults/main.yml"
PUBFILE="scripts/team-publish.sh"
sedi(){ sed -i '' "$1" "$2" 2>/dev/null || sed -i "$1" "$2"; }

# ⚠ `set -o pipefail` + `covrun … | grep -q` sur un play qui REFUSE rend le code
# du PLAY, jamais celui de grep : le témoin serait rouge en permanence, donc
# muet (piège payé en P2 puis en A4). On CAPTURE, puis on greppe.
probe_refuse(){  # <manifeste> <code attendu> → 0 si le refus NOMMÉ est bien là
  local o; o=$(covrun "$1"); printf '%s' "$o" | grep -q "$2"
}
probe_passe(){   # <manifeste> → 0 si la publication est autorisée par la garde
  covrun "$1" >/dev/null 2>&1
}

mutate(){  # <fichier> <sed> <libellé> <fonction témoin> [args…]
  local f="$1" s="$2" lbl="$3"; shift 3
  local before after
  cp "$f" "$TMP/mut.orig"
  # Le témoin doit être VERT AVANT le sabotage, sinon son rouge d'après ne dit
  # rien : il prouverait sa propre panne, pas la garde (leçon de P2).
  "$@" >/dev/null 2>&1; before=$?
  if [ "$before" -ne 0 ]; then
    ko "E($lbl) témoin déjà rouge AVANT le sabotage — mutation non concluante"
    return
  fi
  sedi "$s" "$f"
  "$@" >/dev/null 2>&1; after=$?
  cp "$TMP/mut.orig" "$f"
  cmp -s "$TMP/mut.orig" "$f" || { ko "E($lbl) RESTAURATION IMPARFAITE de $f"; return; }
  [ "$after" -ne 0 ] \
    && ok "E($lbl) le sabotage est ATTRAPÉ, et le fichier est restauré à l'octet près" \
    || ko "E($lbl) sabotage NON détecté — l'assertion correspondante ne mesure rien"
}

if command -v ansible-playbook >/dev/null 2>&1; then
  covman cov-mtls VH internal 1
  covman cov-ok   M  internal 1
  # E1 — `mtls` passe de « refuse » à « degrade » : la cellule VH redeviendrait
  # publiable EN SILENCE. C'est la mutation qui compte le plus, parce que c'est
  # exactement la pente que ce jalon existe pour interdire.
  mutate "$DEFFILE" 's/^    mode: refuse$/    mode: degrade/' "non-déclinable toléré" \
    probe_refuse cov-mtls POSTURE_NON_DECLINABLE
  # E2 — l'ANTI-DÉRIVE : retirer `https-only` de ce que la chaîne déclare savoir
  # opposer doit faire REFUSER (POSTURE_NON_OPPOSEE), jamais publier en silence.
  mutate "$DEFFILE" '/^  https-only:/d' "dimension retirée de la table" \
    probe_passe cov-ok
  # E3 — la garde du refus structurel, neutralisée dans la tâche elle-même.
  mutate "$COVFILE" 's/that: "pub_cov_refused | length == 0"/that: "1 == 1"/' "garde du refus neutralisée" \
    probe_refuse cov-mtls POSTURE_NON_DECLINABLE
else
  skip "E1..E3 ansible-playbook absent"
fi
# E4 — le relais du verdict de couverture jusqu'à la PR.
grep -q 'POSTURE_COUVERTURE' "$PUBFILE" \
  && ok "E4 team-publish.sh relaie la couverture jusqu'au commentaire de PR" \
  || ko "E4 team-publish.sh ne relaie pas POSTURE_COUVERTURE — la PR resterait muette"

# ═══════════════════════════════════════════════════════════════════════════
echo
printf '═══ RÉSULTAT P7 : %d ✅ / %d ❌ ═══\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
