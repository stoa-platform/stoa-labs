#!/bin/bash
# E1 / D6 §3 — le bitmask d'accessProfile gouverne-t-il la CRÉATION d'API ?
#
# §2 a montré que retirer UN bit ne change rien : les neuf bits testables
# laissent POST /apis à 201. Deux lectures possibles, et une seule est vraie :
#   (H1) le privilège est un OU de plusieurs bits — en retirer un ne suffit pas ;
#   (H2) le bitmask ne gouverne PAS la création d'API du tout.
# On tranche en retirant BEAUCOUP de bits d'un coup, jusqu'au bitmask vide (celui
# que porte le profil `Default`). Si POST /apis reste 201 avec un bitmask vide,
# c'est H2, et D6 est impossible par les privilèges.
#
# ⚠ DEUX PIÈGES DÉJÀ PAYÉS, encodés ici :
#   - le corps JSON passe par un FICHIER : dans une config curl (-K) une valeur
#     non quotée s'arrête au premier ESPACE, et le corps part tronqué.
#   - le bitmask relu peut être PLUS COURT que celui écrit : les zéros de fin
#     sont tronqués au stockage (mesuré position 20). Toute comparaison se fait
#     donc sur la valeur COMPLÉTÉE à droite, jamais sur l'égalité brute.
set -eu
umask 077
. /root/f4-teams.env
ADMPW="${WM_ADMIN_PW:-}"
[ -n "$ADMPW" ] || { echo "!! WM_ADMIN_PW absent"; exit 1; }

KX="k3s kubectl -n ci exec -i deploy/jenkins --"
B="http://wm-apigateway-admin.wm.svc:5555/rest/apigateway"
PU="svc-e1-probe3"; PG="e1-probe3-devs"; PP="e1-probe3-profile"
PPW="$(openssl rand -hex 12)"

adm() { printf 'Administrator:%s' "$ADMPW"; }
req() {
  if [ -n "${4:-}" ]; then printf '%s' "$4" | $KX sh -c 'umask 077; cat > /tmp/e1-body.json'; fi
  {
    printf 'url = "%s%s"\n' "$B" "$3"
    printf 'user = "%s"\n' "$1"
    printf 'request = "%s"\n' "$2"
    printf 'header = "Accept: application/json"\n'
    if [ -n "${4:-}" ]; then
      printf 'header = "Content-Type: application/json"\n'
      printf 'data = @/tmp/e1-body.json\n'
    fi
    printf 'silent\n'
    printf 'write-out = "\\n__CODE__%%{http_code}"\n'
  } | $KX curl -K - 2>/dev/null
}
code_of() { printf '%s' "$1" | sed -n 's/.*__CODE__\([0-9]*\)$/\1/p'; }
body_of() { printf '%s' "$1" | sed 's/__CODE__[0-9]*$//'; }
pick() { C="$1" K="$2" V="$3" R="$4" python3 -c '
import json,sys,os
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
for it in (d.get(os.environ["C"]) or []):
    if it.get(os.environ["K"])==os.environ["V"]: print(it.get(os.environ["R"]) or ""); break' 2>/dev/null || true; }
uid_of() { body_of "$(req "$(adm)" GET /users)"          | pick users          loginId "$1" id; }
gid_of() { body_of "$(req "$(adm)" GET /groups)"         | pick groups         name    "$1" id; }
pid_of() { body_of "$(req "$(adm)" GET /accessProfiles)" | pick accessProfiles name    "$1" id; }
ppriv()  { body_of "$(req "$(adm)" GET /accessProfiles)" | pick accessProfiles name    "$1" privilege; }

wait_health() { i=0; while [ "$i" -lt 60 ]; do
  hc=$($KX curl -s -o /dev/null -m 5 -w '%{http_code}' "$B/health" 2>/dev/null || true)
  [ "$hc" = "200" ] && return 0; i=$((i+1)); sleep 10; done; return 1; }

try_create() {   # try_create <user:pass> <nom> -> code, supprime si créée
  N="$2"
  $KX sh -c "umask 077; cat > /tmp/$N.yaml" <<YAML
openapi: "3.0.0"
info: { title: "$N", version: "1.0.0" }
servers: [ { url: "http://backend-dev.wm.svc.cluster.local:8080" } ]
paths:
  /ping:
    get:
      responses: { "200": { description: ok } }
YAML
  out=$( {
    printf 'url = "%s/apis"\n' "$B"; printf 'user = "%s"\n' "$1"
    printf 'request = "POST"\nheader = "Accept: application/json"\n'
    printf 'form = "file=@/tmp/%s.yaml;type=application/x-yaml"\n' "$N"
    printf 'form = "type=openapi"\nform = "apiName=%s"\nform = "apiVersion=1.0.0"\n' "$N"
    printf 'silent\nwrite-out = "\\n__CODE__%%{http_code}"\n'
  } | $KX curl -K - 2>/dev/null )
  c=$(code_of "$out")
  case "$c" in 200|201)
    aid=$(body_of "$(req "$(adm)" GET /apis)" | N2="$N" python3 -c '
import json,sys,os
for it in json.load(sys.stdin).get("apiResponse") or []:
    a=it.get("api",it)
    if a.get("apiName")==os.environ["N2"]: print(a["id"]); break' 2>/dev/null || true)
    [ -n "$aid" ] && { req "$(adm)" PUT "/apis/$aid/deactivate" >/dev/null 2>&1 || true
                       req "$(adm)" DELETE "/apis/$aid" >/dev/null 2>&1 || true; } ;;
  esac
  $KX rm -f "/tmp/$N.yaml" 2>/dev/null || true
  printf '%s' "$c"
}

cleanup() {
  echo; echo "=== NETTOYAGE ==="
  for f in "$(pid_of "$PP"):accessProfiles" "$(gid_of "$PG"):groups" "$(uid_of "$PU"):users"; do
    id="${f%%:*}"; col="${f##*:}"; [ -n "$id" ] || continue
    echo "  DELETE /$col/$id -> $(code_of "$(req "$(adm)" DELETE "/$col/$id")")"
  done
}
trap cleanup EXIT

echo "=== E1 / D6 §3 — le bitmask gouverne-t-il la création d'API ? $(date -u +%FT%TZ) ==="
wait_health || { echo "!! gateway injoignable"; exit 1; }
REF=$(ppriv API-Gateway-Providers)
echo "référence : $REF"

UID_=$(uid_of "$PU")
[ -n "$UID_" ] || { echo "  POST /users -> $(code_of "$(req "$(adm)" POST /users "{\"loginId\":\"$PU\",\"firstName\":\"svc\",\"lastName\":\"probe3\",\"password\":\"$PPW\",\"active\":true,\"type\":\"local\"}")")"; UID_=$(uid_of "$PU"); }
GID=$(gid_of "$PG")
[ -n "$GID" ] || { echo "  POST /groups -> $(code_of "$(req "$(adm)" POST /groups "{\"name\":\"$PG\",\"description\":\"probe3\",\"type\":\"local\"}")")"; GID=$(gid_of "$PG"); }
echo "  PUT /groups membre -> $(code_of "$(req "$(adm)" PUT "/groups/$GID" "{\"id\":\"$GID\",\"name\":\"$PG\",\"description\":\"probe3\",\"type\":\"local\",\"userIds\":[\"$UID_\"]}")")"
PID=$(pid_of "$PP")
[ -n "$PID" ] || { echo "  POST /accessProfiles -> $(code_of "$(req "$(adm)" POST /accessProfiles "{\"name\":\"$PP\",\"description\":\"probe3\",\"privilege\":\"$REF\",\"groupIds\":[\"$GID\"]}")")"; PID=$(pid_of "$PP"); }
[ -n "$PID" ] || { echo "!! profil non créé"; exit 1; }

PROBE="$PU:$PPW"
echo
echo "  bitmask posé                        | relu                  | GET /apis | POST /apis"
n=0
for CAND in "$REF" "111100000000000000000" "000000101101100000001" "100000000000000000000" "000000000000000000001" "0"; do
  n=$((n+1))
  r=$(req "$(adm)" PUT "/accessProfiles/$PID" "{\"id\":\"$PID\",\"name\":\"$PP\",\"description\":\"probe3\",\"privilege\":\"$CAND\",\"groupIds\":[\"$GID\"]}")
  AFTER=$(ppriv "$PP")
  G=$(code_of "$(req "$PROBE" GET /apis)")
  P=$(try_create "$PROBE" "e1d6c$n")
  printf '  %-35s | %-21s | %9s | %s\n' "$CAND" "${AFTER:-(vide)}" "$G" "$P"
done

req "$(adm)" PUT "/accessProfiles/$PID" "{\"id\":\"$PID\",\"name\":\"$PP\",\"description\":\"probe3\",\"privilege\":\"$REF\",\"groupIds\":[\"$GID\"]}" >/dev/null 2>&1 || true
echo
echo "=== FIN ==="
