#!/usr/bin/env bash
# scripts/setup-wm-palier-admins.sh — LAB : les comptes d'ADMIN PAR PALIER sur la
# gateway réelle (ADR-075 les supposait pour le credential sortant des proxies
# wm-admin-<env> ; le re-seed du 2026-09-02 a rejoué Vault, pas la gateway —
# mesuré : envs/<e>/wm-admin ⇒ 401 sur les quatre paliers hors-prod).
#
# Pour chaque palier NON terminal (env_chain_nonprod — jamais un nom en dur, le
# terminus est exclu par STRUCTURE : le lab n'a pas de compte réel pour
# wm-mock-prod, et A7 n'est pas A3) :
#   1. lit envs/<e>/wm-admin dans Vault (token exploitant, en-tête par fichier) ;
#   2. crée l'utilisateur s'il est absent (POST /users, type local, actif — la
#      forme d'apim_team_onboard/tasks/gateway.yml) ;
#   3. le pose membre du groupe d'admin par READ-MODIFY-WRITE en UUID (un
#      loginId dans userIds ⇒ 200 et membre absent, piège mesuré par
#      l'onboarding ; motif fix-svc-admin-group.sh) et RELIT ;
#   4. PROUVE le login (GET /applications avec les creds de Vault ⇒ 200) ; sinon
#      utilisateur présent au mot de passe divergent ⇒ PUT /users/<id> avec le
#      mot de passe de Vault (sondé 2026-09-02 : accepté), re-prouvé.
# Idempotent : rejouer ne change rien. Un compte hors de tout groupe d'admin
# reçoit 401 même avec le bon mot de passe (autorisation, pas authentification) :
# c'est pourquoi le groupe précède la preuve de login.
#
# Aucun secret imprimé, ni en argv (curl -K fichier 0600 pour la gateway,
# -H @fichier pour Vault), ni dans l'env d'un process enfant.
#
#   bash scripts/setup-wm-palier-admins.sh --print       # hors ligne, aucun réseau
#   VAULT_TOKEN=… GW_ADMIN=http://localhost:5555/rest/apigateway \
#     WM_USER=Administrator WM_PASS=… bash scripts/setup-wm-palier-admins.sh
# `A && ok || bad` (SC2015) est l'idiome des poseurs et scripts de preuve du repo.
# shellcheck disable=SC2015
set -uo pipefail
_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/env-chain.sh"; [ -f "$_LIB" ] || _LIB="scripts/lib/env-chain.sh"
# shellcheck source=scripts/lib/env-chain.sh
. "$_LIB"
VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
APIM_KV_MOUNT="${APIM_KV_MOUNT:-secret}"; APIM_KV_PREFIX="${APIM_KV_PREFIX:-stoa}"
ADMIN_GROUP="${ADMIN_GROUP:-API-Gateway-Administrators}"
ENVS="$(env_chain_nonprod)" || { echo "CHAINE_ILLISIBLE : env_chain_nonprod a échoué" >&2; exit 1; }
[ -n "$ENVS" ] || { echo "CHAINE_VIDE : aucun palier non terminal" >&2; exit 1; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad(){ FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

if [ "${1:-pose}" = --print ]; then
  echo "# comptes d'admin par palier — hors-prod ($ENVS), terminus exclu par structure :"
  for e in $ENVS; do
    printf '#   %s : loginId lu dans %s/%s/envs/%s/wm-admin, membre de %s, login prouvé (GET /applications -> 200)\n' \
      "$e" "$APIM_KV_MOUNT" "$APIM_KV_PREFIX" "$e" "$ADMIN_GROUP"
  done
  echo "# Aucun secret n'est imprimé ; la pose exige VAULT_TOKEN, GW_ADMIN, WM_USER, WM_PASS."
  exit 0
fi
[ "${1:-pose}" = pose ] || { echo "usage: $0 [--print]" >&2; exit 2; }

VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN requis (token exploitant Vault)}"
GW_ADMIN="${GW_ADMIN:?GW_ADMIN requis (ex. http://localhost:5555/rest/apigateway)}"
WM_USER="${WM_USER:?WM_USER requis}"; WM_PASS="${WM_PASS:?WM_PASS requis}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; umask 077
printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN" > "$TMP/vhdr"

# curl_cfg <fichier> <user> <pass> — fichier de config curl (-K) ; `"` et `\`
# échappés comme curl l'exige. Le mot de passe passe par l'ENV de python, jamais
# par son argv.
curl_cfg(){
  U="$2" P="$3" python3 -c 'import os,sys
e=lambda s: s.replace("\\","\\\\").replace("\"","\\\"")
fd=os.open(sys.argv[1], os.O_WRONLY|os.O_CREAT|os.O_TRUNC, 0o600)
with os.fdopen(fd,"w") as f: f.write("user = \"%s:%s\"\n" % (e(os.environ["U"]), e(os.environ["P"])))' "$1"
}
curl_cfg "$TMP/adm.cfg" "$WM_USER" "$WM_PASS"
adm(){ curl -s -K "$TMP/adm.cfg" -H 'Accept: application/json' -H 'Content-Type: application/json' "$@"; }
kv_path(){ local p="$APIM_KV_MOUNT/data"; [ -n "$APIM_KV_PREFIX" ] && p="$p/$APIM_KV_PREFIX"; printf '%s/%s' "$p" "$1"; }
uid_of(){ adm "$GW_ADMIN/users" | U="$1" python3 -c 'import json,os,sys
print(next((u["id"] for u in json.load(sys.stdin).get("users",[]) if u.get("loginId")==os.environ["U"]),""))'; }
# user_body <fichier -K> <loginId> <palier> [<json existant>] — le corps JSON du
# user, mot de passe lu DANS le fichier -K (jamais en variable exportée).
user_body(){
  CFG="$1" U="$2" E="$3" EXISTING="${4:-}" python3 -c 'import json,os
line=open(os.environ["CFG"]).read().strip()
val=line.split("=",1)[1].strip()[1:-1]
pw=val.replace("\\\"","\"").replace("\\\\","\\").split(":",1)[1]
ex=os.environ["EXISTING"]
if ex:
    d=json.loads(ex); u=(d.get("users") or [d])[0] if isinstance(d,dict) else d
    u["password"]=pw; print(json.dumps(u))
else:
    print(json.dumps({"loginId":os.environ["U"],"firstName":"wm-admin","lastName":os.environ["E"],"password":pw,"active":True,"type":"local"}))'
}

echo "gateway $GW_ADMIN — comptes d'admin par palier ($ENVS), groupe $ADMIN_GROUP"
for e in $ENVS; do
  echo "── palier $e ──"
  HC="$(curl -s -H @"$TMP/vhdr" -o "$TMP/kv.$e" -w '%{http_code}' "$VAULT_ADDR/v1/$(kv_path "envs/$e/wm-admin")")"
  [ "$HC" = 200 ] || { bad "[$e] envs/$e/wm-admin illisible dans Vault (HTTP $HC) — jouer scripts/setup-vault-envs.sh"; continue; }
  U="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["data"]["data"].get("username",""))' "$TMP/kv.$e")"
  P="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["data"]["data"].get("password",""))' "$TMP/kv.$e")"
  rm -f "$TMP/kv.$e"
  [ -n "$U" ] && [ -n "$P" ] || { bad "[$e] username/password absents du secret"; continue; }
  curl_cfg "$TMP/u.$e.cfg" "$U" "$P"; P=""
  ID="$(uid_of "$U")"
  if [ -z "$ID" ]; then
    HC="$(user_body "$TMP/u.$e.cfg" "$U" "$e" | adm -X POST --data-binary @- -o /dev/null -w '%{http_code}' "$GW_ADMIN/users")"
    case "$HC" in
      200|201) ID="$(uid_of "$U")"; [ -n "$ID" ] && ok "[$e] user $U créé ($ID)" || bad "[$e] user $U créé mais introuvable à la relecture" ;;
      *) bad "[$e] POST /users -> HTTP $HC"; continue ;;
    esac
  else
    ok "[$e] user $U présent ($ID)"
  fi
  [ -n "$ID" ] || continue
  # groupe d'admin : read-modify-write en UUID, puis relecture
  adm "$GW_ADMIN/groups" | G="$ADMIN_GROUP" I="$ID" python3 -c 'import json,os,sys
g=next((g for g in json.load(sys.stdin).get("groups",[]) if g.get("name")==os.environ["G"]),None)
if g is None: sys.exit(1)
ids=list(g.get("userIds") or [])
if os.environ["I"] not in ids: ids.append(os.environ["I"])
g["userIds"]=ids; print(json.dumps(g))' > "$TMP/g.$e.json" || { bad "[$e] groupe $ADMIN_GROUP introuvable sur la gateway"; continue; }
  HC="$(adm -X PUT --data-binary @"$TMP/g.$e.json" -o /dev/null -w '%{http_code}' "$GW_ADMIN/groups/$ADMIN_GROUP")"
  if adm "$GW_ADMIN/groups" | G="$ADMIN_GROUP" I="$ID" python3 -c 'import json,os,sys
g=next((g for g in json.load(sys.stdin).get("groups",[]) if g.get("name")==os.environ["G"]),{})
sys.exit(0 if os.environ["I"] in (g.get("userIds") or []) else 1)'; then
    ok "[$e] $U ∈ $ADMIN_GROUP (relu ; PUT HTTP $HC)"
  else
    bad "[$e] $U ABSENT de $ADMIN_GROUP après PUT (HTTP $HC)"; continue
  fi
  probe(){ curl -s -K "$TMP/u.$e.cfg" -H 'Accept: application/json' -o /dev/null -w '%{http_code}' "$GW_ADMIN/applications"; }
  if [ "$(probe)" != 200 ]; then
    EXISTING="$(adm "$GW_ADMIN/users/$ID")"
    HC="$(user_body "$TMP/u.$e.cfg" "$U" "$e" "$EXISTING" | adm -X PUT --data-binary @- -o /dev/null -w '%{http_code}' "$GW_ADMIN/users/$ID")"
    echo "  mot de passe de $U réaligné sur Vault (PUT /users/$ID -> HTTP $HC)"
  fi
  PC="$(probe)"
  [ "$PC" = 200 ] && ok "[$e] login de $U PROUVÉ (GET /applications -> 200)" || bad "[$e] login de $U refusé après pose (GET /applications -> $PC)"
  rm -f "$TMP/u.$e.cfg"
done
printf '\n%d PASS / %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
