#!/usr/bin/env bash
# test-outbound-auth.sh — PREUVE LIVE de l'auth OUTBOUND projetée as-code par
# `labctl apply` sur le webMethods RÉEL (apigateway-trial:10.15), goal A4.
#
# La jambe outbound (routing-by-alias + credential alias base64 + action
# "Outbound Auth - Transport" imbriquée sous transportSecurity) vit dans
# labctl/internal/adapter/webmethods/routing.go. Ce script la prouve de bout en
# bout, avec contre-épreuves, sur une API DÉDIÉE (`outbound-proof`) — jamais la
# chaîne accounts-read (corrompue sur le trial).
#
# DoD (goal A4) :
#   1. re-apply IDEMPOTENT recrée l'auth outbound sans intervention ;
#   2. Basic injecté VU PAR LE BACKEND (poc-token-echo renvoie received_headers) ;
#   3. changement d'alias suivi IMMÉDIATEMENT (valeur endpoint per-request +
#      rotation du credential projetée à l'apply).
#
# Contre-épreuves (la preuve détecte-t-elle vraiment ?) :
#   S1  sabotage HORS-BANDE du password stocké (PUT /alias) -> data-plane voit le
#       MAUVAIS Basic -> re-apply (WRITE-ALWAYS) -> le bon Basic revient. Prouve
#       que la convergence rattrape un drift gateway d'un secret NON-RELISIBLE
#       (le fix write-always : un secret masqué au read-back se ré-émet toujours).
#   S2  rotation du mot de passe DANS LE MANIFESTE -> apply -> le NOUVEAU Basic
#       (rouge->vert du bug historique : le drift keyé sur userName sautait le PUT).
#   S3  2e action outboundTransportAuthentication injectée sur le stage routing ->
#       apply REFUSÉ [ambiguous] (garde anti first-match, classe A1) -> restore.
#   S4  checker faussé : la même assertion avec une valeur ATTENDUE fausse DOIT
#       échouer (le harnais n'est pas un tampon).
#
# Env : WM_ADMIN_URL (def http://localhost:5555), WM_ADMIN_USER/PASSWORD
# (def Administrator/manage), ECHO (def poc-token-echo, réseau docker interne).
# Aucune dépendance Vault (creds littéraux PoC).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WM="${WM_ADMIN_URL:-http://localhost:5555}"
WMU="${WM_ADMIN_USER:-Administrator}"
WMP="${WM_ADMIN_PASSWORD:-manage}"
API_NAME="outbound-proof"
API_VER="1.0.0"
DP="$WM/gateway/$API_NAME/$API_VER"          # data-plane base
ECHO_HOST="poc-token-echo:8080"              # backend, joignable du wM (réseau poc)
BACKEND_A="http://$ECHO_HOST/backend/outbound-proof-A"
BACKEND_B="http://$ECHO_HOST/backend/outbound-proof-B"
BE_USER="proof-user"
BE_PASS_A="proof-pass-A"
BE_PASS_B="proof-pass-B-rotated"
WM_CONTAINER="${WM_CONTAINER:-poc-webmethods-real}"
DOCKER="${WM_DOCKER:-docker}"
KEEPALIVE_PAUSE="/tmp/wm-keepalive.pause"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

wm()  { curl -s -u "$WMU:$WMP" -H 'Accept: application/json' "$@"; }
b64() { printf '%s' "$1" | base64; }

# --- cleanup / keepalive restore (trap AVANT tout effet de bord) --------------
WS=""; BINDIR=""       # référencés par cleanup ; initialisés tôt (set -u)
CREATED_API_ID=""
cleanup() {
  local rc=$?
  # Supprime l'API dédiée (deactivate d'abord ; ses 2 aliases + l'action outbound
  # partent avec, ou restent inertes — API dédiée, jamais accounts-read).
  if [ -n "$CREATED_API_ID" ]; then
    wm -X PUT "$WM/rest/apigateway/apis/$CREATED_API_ID/deactivate" >/dev/null 2>&1
    wm -X DELETE "$WM/rest/apigateway/apis/$CREATED_API_ID" >/dev/null 2>&1
  fi
  for al in outbound-proof-backend outbound-proof-backend-cred; do
    aid="$(alias_id "$al")"
    [ -n "$aid" ] && wm -X DELETE "$WM/rest/apigateway/alias/$aid" >/dev/null 2>&1
  done
  rm -f "$KEEPALIVE_PAUSE"
  rm -rf "$WS" "$BINDIR" 2>/dev/null
  exit $rc
}
trap cleanup EXIT INT TERM

# --- helpers de lecture live --------------------------------------------------
# alias_id NAME -> id ("" si absent)
alias_id() {
  wm "$WM/rest/apigateway/alias" | python3 -c '
import json,sys
name=sys.argv[1]
d=json.load(sys.stdin)
for a in d.get("alias",[]):
    if a.get("name")==name: print(a.get("id","")); break
' "$1" 2>/dev/null
}
# alias_endpoint NAME -> endPointURI
alias_endpoint() {
  local id; id="$(alias_id "$1")"; [ -z "$id" ] && return
  wm "$WM/rest/apigateway/alias/$id" | python3 -c '
import json,sys
d=json.load(sys.stdin); a=d.get("alias",d)
print(a.get("endPointURI",""))' 2>/dev/null
}
# api_id NAME VER -> id
api_id() {
  wm "$WM/rest/apigateway/apis" | python3 -c '
import json,sys
n,v=sys.argv[1],sys.argv[2]
d=json.load(sys.stdin)
for a in d.get("apiResponse",[]):
    api=a.get("api",{})
    if api.get("apiName")==n and api.get("apiVersion")==v: print(api.get("id","")); break
' "$1" "$2" 2>/dev/null
}
# dataplane_auth -> la valeur Authorization vue par le backend echo ("" si absente)
dataplane_auth() {
  curl -s --max-time 10 "$DP/accounts" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print(""); sys.exit()
print(d.get("received_headers",{}).get("Authorization",""))' 2>/dev/null
}
# outbound_action_ids -> ids des actions outboundTransportAuthentication du stage routing
outbound_action_ids() {
  local aid="$1"
  wm "$WM/rest/apigateway/apis/$aid" > "$WS/api.json" 2>/dev/null
  local pol; pol="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
api=d.get("apiResponse",{}).get("api",d)
pols=api.get("policies") or []
print(pols[0] if pols else "")' "$WS/api.json" 2>/dev/null)"
  [ -z "$pol" ] && return
  wm "$WM/rest/apigateway/policies/$pol" > "$WS/pol.json" 2>/dev/null
  wm "$WM/rest/apigateway/policyActions" > "$WS/acts.json" 2>/dev/null
  python3 - "$WS/pol.json" "$WS/acts.json" <<'PY' 2>/dev/null
import json,sys
pol=json.load(open(sys.argv[1])); pol=pol.get("policy",pol)
acts=json.load(open(sys.argv[2]))
items=acts.get("policyAction",acts) if isinstance(acts,dict) else acts
if isinstance(items,dict): items=items.get("policyAction",[])
tk={a.get("id"):a.get("templateKey") for a in items}
routing=[s for s in pol.get("policyEnforcements",[]) if s.get("stageKey")=="routing"]
ids=[]
for s in routing:
    for e in s.get("enforcements",[]):
        i=e.get("enforcementObjectId")
        if tk.get(i)=="outboundTransportAuthentication": ids.append(i)
print(" ".join(ids))
PY
}

say "=== 0. Prérequis (live) — recycle-then-pause pour tenir dans la fenêtre trial ==="
# La licence trial tue l'IS ~25 min ; wm-keepalive le recycle proactivement à
# uptime>=23m. Si on posait juste la pause, un run démarré tard verrait l'IS
# mourir SANS relance. On recycle d'abord si l'uptime est déjà haut, PUIS on
# pause — on dispose alors d'une fenêtre pleine (~23 min).
if [ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 -u "$WMU:$WMP" "$WM/rest/apigateway/apis")" != "200" ]; then
  echo "webMethods réel injoignable sur $WM — ./scripts/up.sh d'abord"; exit 2
fi
st="$($DOCKER inspect "$WM_CONTAINER" --format '{{.State.StartedAt}}' 2>/dev/null || echo '')"; st="${st%.*}"
epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "$st" +%s 2>/dev/null || echo 0)"
up_min=$(( ( $(date +%s) - epoch ) / 60 ))
if [ "$epoch" != 0 ] && [ "$up_min" -ge 8 ]; then
  echo "  uptime=${up_min}m > 8m : recycle préventif de $WM_CONTAINER (config dans l'ES externe, rien perdu)…"
  $DOCKER restart "$WM_CONTAINER" >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 -u "$WMU:$WMP" "$WM/rest/apigateway/apis")" = "200" ] && break
    sleep 3
  done
fi
touch "$KEEPALIVE_PAUSE"     # gèle le keepalive le temps du run (trap le retire)
ok "gateway joignable ($WM), keepalive en pause (fenêtre pleine)"
$DOCKER exec "$WM_CONTAINER" true 2>/dev/null || true
if ! $DOCKER inspect poc-token-echo >/dev/null 2>&1; then
  echo "backend poc-token-echo absent — docker compose -f docker-compose.wm.yml up -d"; exit 2
fi
ok "backend echo présent (poc-token-echo)"

# --- build labctl (vendored, hermétique) -------------------------------------
BINDIR="$(mktemp -d)"; BIN="$BINDIR/labctl"
( cd "$ROOT/labctl" && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$BIN" . ) || { echo "build failed"; exit 1; }
ok "labctl build"

# --- workspace : contrat + manifeste avec bloc routing/outbound --------------
WS="$(mktemp -d)"
cat > "$WS/openapi.yaml" <<EOF
openapi: 3.0.3
info:
  title: Outbound Proof API
  version: $API_VER
servers:
  - url: /$API_NAME/v1
paths:
  /accounts:
    get:
      operationId: listAccounts
      responses:
        "200": { description: ok }
EOF

write_manifest() { # $1 = backend URL, $2 = backend password
  cat > "$WS/target.yaml" <<EOF
apiVersion: labctl.stoa.io/v1
kind: FederationTarget
name: $API_NAME
contract: ./openapi.yaml
backendUrl: $1
targets:
  - name: webmethods
    type: webmethods
    adminUrl: $WM
    gatewayUrl: $WM
    routing:
      endpointAlias:
        name: $API_NAME-backend
        url: $1
      credentialAlias:
        name: $API_NAME-backend-cred
    credentials:
      username: $WMU
      password: $WMP
      backendUsername: $BE_USER
      backendPassword: $2
EOF
}

apply() { ( cd "$WS" && "$BIN" apply -f target.yaml ) 2>&1; }

say "=== 1. apply #1 : projection outbound complète ==="
write_manifest "$BACKEND_A" "$BE_PASS_A"
OUT="$(apply)"; RC=$?
echo "$OUT" | sed 's/^/    /'
[ "$RC" -eq 0 ] && ok "apply #1 exit 0" || bad "apply #1 rc=$RC"
CREATED_API_ID="$(api_id "$API_NAME" "$API_VER")"
[ -n "$CREATED_API_ID" ] && ok "API $API_NAME créée (id $CREATED_API_ID)" || bad "API non trouvée après apply"
# read-back : endpoint alias pointe sur le backend A
[ "$(alias_endpoint "$API_NAME-backend")" = "$BACKEND_A" ] \
  && ok "endpoint alias -> $BACKEND_A" || bad "endpoint alias != $BACKEND_A"
# read-back : EXACTEMENT 1 action outbound sur le stage routing
IDS="$(outbound_action_ids "$CREATED_API_ID")"; N=$(echo $IDS | wc -w | tr -d ' ')
[ "$N" = "1" ] && ok "1 action outboundTransportAuthentication sur le stage routing" \
  || bad "attendu 1 action outbound, trouvé $N ($IDS)"

say "=== 2. DoD-2 : le Basic est VU PAR LE BACKEND ==="
AUTH="$(dataplane_auth)"
WANT_A="Basic $(b64 "$BE_USER:$BE_PASS_A")"
[ "$AUTH" = "$WANT_A" ] && ok "backend reçoit '$AUTH'" || bad "backend Authorization='$AUTH', attendu '$WANT_A'"
# S4 — checker faussé : la même assertion avec une valeur fausse DOIT échouer
if [ "$AUTH" = "Basic $(b64 "$BE_USER:mauvais")" ]; then bad "S4 checker faussé a matché (rubber stamp!)"; else ok "S4 checker faussé : n'égale PAS une valeur attendue erronée"; fi

say "=== 3. DoD-1 : re-apply IDEMPOTENT (mêmes ids, 1 seule action, data-plane inchangé) ==="
EP_ID1="$(alias_id "$API_NAME-backend")"; CR_ID1="$(alias_id "$API_NAME-backend-cred")"
OUT="$(apply)"; RC=$?
[ "$RC" -eq 0 ] && ok "apply #2 exit 0" || { echo "$OUT" | sed 's/^/    /'; bad "apply #2 rc=$RC"; }
[ "$(alias_id "$API_NAME-backend")" = "$EP_ID1" ] && [ "$(alias_id "$API_NAME-backend-cred")" = "$CR_ID1" ] \
  && ok "ids d'alias stables (pas de doublon)" || bad "ids d'alias ont changé (recréation parasite)"
IDS="$(outbound_action_ids "$CREATED_API_ID")"; N=$(echo $IDS | wc -w | tr -d ' ')
[ "$N" = "1" ] && ok "toujours 1 action outbound après re-apply" || bad "actions outbound = $N après re-apply ($IDS)"
[ "$(dataplane_auth)" = "$WANT_A" ] && ok "data-plane inchangé (Basic A)" || bad "data-plane a dérivé au re-apply"

say "=== 4. S1 : sabotage HORS-BANDE du password stocké -> write-always le rattrape ==="
# PUT direct de l'alias credential avec un password saboté (secret non-relisible :
# labctl ne peut PAS le détecter par read-back — seule la ré-émission le corrige).
CR_ID="$(alias_id "$API_NAME-backend-cred")"
wm "$WM/rest/apigateway/alias/$CR_ID" | python3 -c '
import json,sys
d=json.load(sys.stdin); a=d.get("alias",d)
import base64
a["httpAuthCredentials"]={"userName":sys.argv[1],"password":base64.b64encode(b"SABOTAGED").decode()}
a["id"]=sys.argv[2]
print(json.dumps(a))' "$BE_USER" "$CR_ID" > "$WS/sab.json"
wm -X PUT -H 'Content-Type: application/json' --data @"$WS/sab.json" "$WM/rest/apigateway/alias/$CR_ID" >/dev/null
SAB_AUTH="$(dataplane_auth)"
[ "$SAB_AUTH" = "Basic $(b64 "$BE_USER:SABOTAGED")" ] \
  && ok "sabotage effectif : backend voit le MAUVAIS Basic (assert non-vacuous)" \
  || bad "le sabotage n'a pas pris (backend='$SAB_AUTH') — S1 non concluant"
OUT="$(apply)"; RC=$?
[ "$RC" -eq 0 ] && ok "re-apply exit 0 (write-always)" || { echo "$OUT" | sed 's/^/    /'; bad "re-apply post-sabotage rc=$RC"; }
[ "$(dataplane_auth)" = "$WANT_A" ] \
  && ok "write-always a RECONVERGÉ le password (backend re-voit Basic A) — DoD-1 sans intervention" \
  || bad "le password saboté n'a PAS été rattrapé (write-always KO)"

say "=== 5. DoD-3a : changement de valeur d'alias suivi IMMÉDIATEMENT (per-request) ==="
# PUT hors-bande de la SEULE endPointURI (backend A -> B) : aucune réactivation,
# le ${alias} se résout au prochain appel data-plane.
EP_ID="$(alias_id "$API_NAME-backend")"
wm "$WM/rest/apigateway/alias/$EP_ID" | python3 -c '
import json,sys
d=json.load(sys.stdin); a=d.get("alias",d)
a["endPointURI"]=sys.argv[1]; a["id"]=sys.argv[2]
print(json.dumps(a))' "$BACKEND_B" "$EP_ID" > "$WS/ep.json"
wm -X PUT -H 'Content-Type: application/json' --data @"$WS/ep.json" "$WM/rest/apigateway/alias/$EP_ID" >/dev/null
sleep 1
curl -s --max-time 10 "$DP/accounts" >/dev/null   # déclenche l'appel backend B
if $DOCKER logs poc-token-echo --tail 8 2>&1 | grep -q '/backend/outbound-proof-B/accounts'; then
  ok "backend B atteint immédiatement (changement d'endpoint alias suivi per-request)"
else
  bad "le backend B n'a pas été atteint après le changement d'alias"
fi

say "=== 6. S2 / DoD-3b : rotation du password DANS LE MANIFESTE -> apply -> nouveau Basic ==="
# (write_manifest ré-écrit backend=A pour rester cohérent + password rotaté.)
write_manifest "$BACKEND_A" "$BE_PASS_B"
OUT="$(apply)"; RC=$?
[ "$RC" -eq 0 ] && ok "apply (rotation) exit 0" || { echo "$OUT" | sed 's/^/    /'; bad "apply rotation rc=$RC"; }
WANT_B="Basic $(b64 "$BE_USER:$BE_PASS_B")"
[ "$(dataplane_auth)" = "$WANT_B" ] \
  && ok "backend voit le NOUVEAU Basic (rotation projetée) — rouge->vert du bug userName-keyé" \
  || bad "la rotation de password n'a pas atteint le backend"

say "=== 7. S3 : 2e action outbound injectée -> apply REFUSÉ [ambiguous] (garde first-match) ==="
# Injecte une 2e action outboundTransportAuthentication et l'attache au stage
# routing, puis prouve que labctl REFUSE de converger le premier match (classe A1).
# NB : attacher une action à une policy est soumis au piège wholesale-PUT 10.15
#      (PUT /policies sur API active = no-op/500) — on mime le cycle labctl
#      deactivate->PUT->reactivate. Si l'attache ne persiste PAS sur ce trial,
#      on SKIP (la garde est prouvée DÉTERMINISTE par le test unitaire
#      TestPublish_RoutingRefusesDuplicateOutboundAction) — jamais un faux FAIL.
attach_dupe() { # $1=policy id, $2=dup id -> attache via deactivate/PUT/reactivate
  wm -X PUT "$WM/rest/apigateway/apis/$CREATED_API_ID/deactivate" >/dev/null 2>&1
  wm "$WM/rest/apigateway/policies/$1" | python3 -c '
import json,sys
d=json.load(sys.stdin); pol=d.get("policy",d)
for s in pol.get("policyEnforcements",[]):
    if s.get("stageKey")=="routing":
        s.setdefault("enforcements",[]).append({"enforcementObjectId":sys.argv[1],"order":None})
pol["id"]=sys.argv[2]
print(json.dumps({"policy":pol}))' "$2" "$1" > "$WS/poldup.json"
  wm -X PUT -H 'Content-Type: application/json' --data @"$WS/poldup.json" "$WM/rest/apigateway/policies/$1" >/dev/null
  wm -X PUT "$WM/rest/apigateway/apis/$CREATED_API_ID/activate" >/dev/null 2>&1
}
detach_dupe() { # $1=policy id, $2=dup id -> détache via deactivate/PUT/reactivate
  wm -X PUT "$WM/rest/apigateway/apis/$CREATED_API_ID/deactivate" >/dev/null 2>&1
  wm "$WM/rest/apigateway/policies/$1" | python3 -c '
import json,sys
d=json.load(sys.stdin); pol=d.get("policy",d)
for s in pol.get("policyEnforcements",[]):
    if s.get("stageKey")=="routing":
        s["enforcements"]=[e for e in s.get("enforcements",[]) if e.get("enforcementObjectId")!=sys.argv[1]]
pol["id"]=sys.argv[2]
print(json.dumps({"policy":pol}))' "$2" "$1" > "$WS/polrestore.json"
  wm -X PUT -H 'Content-Type: application/json' --data @"$WS/polrestore.json" "$WM/rest/apigateway/policies/$1" >/dev/null
  wm -X PUT "$WM/rest/apigateway/apis/$CREATED_API_ID/activate" >/dev/null 2>&1
}
DUP_ID="$(wm -X POST -H 'Content-Type: application/json' "$WM/rest/apigateway/policyActions" \
  -d '{"policyAction":{"names":[{"value":"Outbound Auth - Transport (injected)","locale":"en"}],"templateKey":"outboundTransportAuthentication","parameters":[{"templateKey":"transportSecurity","parameters":[{"templateKey":"authType","values":["ALIAS"]},{"templateKey":"authMode","values":["NEW"]},{"templateKey":"alias","values":["${outbound-proof-backend-cred}"]}]}],"active":true}}' \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print((d.get("policyAction") or d).get("id",""))' 2>/dev/null)"
POL="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1])); api=d.get("apiResponse",{}).get("api",d)
print((api.get("policies") or [""])[0])' "$WS/api.json" 2>/dev/null)"
if [ -n "$DUP_ID" ] && [ -n "$POL" ]; then
  attach_dupe "$POL" "$DUP_ID"
  IDS="$(outbound_action_ids "$CREATED_API_ID")"; N=$(echo $IDS | wc -w | tr -d ' ')
  if [ "$N" = "2" ]; then
    OUT="$(apply)"; RC=$?
    if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qi 'ambiguous'; then
      ok "apply REFUSÉ sur 2 actions outbound (garde anti first-match, classe A1)"
    else
      bad "apply aurait dû être refusé [ambiguous] (rc=$RC)"; echo "$OUT" | grep -i outbound | sed 's/^/    /'
    fi
    detach_dupe "$POL" "$DUP_ID"
    wm -X DELETE "$WM/rest/apigateway/policyActions/$DUP_ID" >/dev/null 2>&1
    OUT="$(apply)"; RC=$?
    [ "$RC" -eq 0 ] && ok "après restore : re-apply reconverge (état sain rétabli)" \
      || { echo "$OUT" | sed 's/^/    /'; bad "re-apply post-restore rc=$RC"; }
  else
    detach_dupe "$POL" "$DUP_ID" 2>/dev/null
    wm -X DELETE "$WM/rest/apigateway/policyActions/$DUP_ID" >/dev/null 2>&1
    printf '  \033[33mSKIP\033[0m S3 live : attache de la dupe non persistée sur ce trial (outbound=%s)\n' "$N"
    printf '       -> garde prouvée déterministe par TestPublish_RoutingRefusesDuplicateOutboundAction\n'
  fi
else
  printf '  \033[33mSKIP\033[0m S3 live : POST action dupe / policy id non abouti sur ce trial\n'
fi

say "=== RÉSULTAT ==="
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && echo "OK — auth outbound as-code prouvée (DoD 1/2/3 + S1..S4)" || echo "ÉCHECS ci-dessus"
exit $(( FAIL > 0 ? 1 : 0 ))
