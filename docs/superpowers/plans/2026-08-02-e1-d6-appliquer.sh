#!/bin/bash
# E1 / D6 — APPLIQUER le retrait de la création d'API aux accessProfiles
# d'équipe, avec quatre contre-épreuves et ROLLBACK AUTOMATIQUE.
#
# CE QUI A ÉTÉ MESURÉ AVANT D'ÉCRIRE (2026-08-02, profils jetables) :
#   - §1 : le groupe système API-Gateway-Providers n'est PAS NÉCESSAIRE — un user
#     qui n'y est pas crée quand même, dès lors que son profil l'autorise.
#     ⚠ J'en avais conclu qu'il ne gouverne pas : c'était conclure plus que la
#     mesure ne permet. Il n'est pas nécessaire, mais il reste SUFFISANT — voir
#     l'avertissement sur l'union, plus bas ;
#   - la création n'est PAS portée par un bit isolé — les neuf bits testables,
#     retirés un par un, laissent POST /apis à 201 (§2) ;
#   - elle est portée par un OU de bits en positions 0-3 (§3) :
#       bits 0-3 seuls          -> POST 201
#       bit 0 seul              -> POST 201
#       bits 0-5 retirés        -> POST 401   <- la valeur retenue
#       bitmask vide            -> POST 401
#   - `GET /apis` reste 200 dans TOUS les cas, y compris bitmask vide : la
#     lecture n'est pas gouvernée par ce champ.
#
# ⚠ LES ZÉROS DE FIN SONT TRONQUÉS AU STOCKAGE (mesuré : `111100000000000000000`
# relu `1111`). Toute comparaison de bitmask se fait donc sur la valeur
# COMPLÉTÉE À DROITE, jamais sur l'égalité brute — sinon une écriture réussie
# passerait pour un échec.
#
# ROLLBACK : la valeur d'avant est relevée ICI, et réappliquée automatiquement
# si l'une des contre-épreuves de non-régression rougit. Casser une preuve
# acquise (l'isolation en lecture, la gestion d'applications dont E2 dépend)
# pour fermer une brèche de labo serait un mauvais échange.
set -eu
umask 077
. /root/f4-teams.env
ADMPW="${WM_ADMIN_PW:-}"
[ -n "$ADMPW" ] || { echo "!! WM_ADMIN_PW absent"; exit 1; }

KX="k3s kubectl -n ci exec -i deploy/jenkins --"
B="http://wm-apigateway-admin.wm.svc:5555/rest/apigateway"
TARGET="000000101101100000001"       # bits 0-5 retirés — mesuré POST 401 / GET 200
SAVE=/root/e1-d6-rollback.txt
SAVEG=/root/e1-d6-rollback-groupe.txt
SYSG="API-Gateway-Providers"

# ⚠ LES PRIVILÈGES S'UNIONNENT SUR TOUS LES PROFILS DE L'UTILISATEUR.
# Première tentative (2026-08-02 13:49) : le bitmask restreint, POSÉ ET RELU sur
# banking-demo, laissait POST /apis à 201 — alors que le MÊME bitmask sur un
# profil jetable donnait 401. La différence : svc-banking-demo est AUSSI membre
# du groupe système API-Gateway-Providers, dont le profil accorde tout. Restreindre
# le profil d'équipe ne retire donc rien tant que l'appartenance système demeure.
# §1 avait montré que ce groupe n'est pas NÉCESSAIRE ; j'en avais conclu à tort
# qu'il ne gouverne pas. Il n'est pas nécessaire, mais il reste SUFFISANT.

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
prof() { body_of "$(req "$(adm)" GET /accessProfiles)" | N="$1" F="$2" python3 -c '
import json,sys,os
for p in (json.load(sys.stdin).get("accessProfiles") or []):
    if p.get("name")==os.environ["N"]: print(p.get(os.environ["F"]) or ""); break' 2>/dev/null || true; }
# égalité de bitmask TOLÉRANTE aux zéros de fin tronqués
same() { A="$1" C="$2" python3 -c '
import os
a,b=os.environ["A"],os.environ["C"]
n=max(len(a),len(b))
print("oui" if a.ljust(n,"0")==b.ljust(n,"0") else "non")'; }
groups_of() { body_of "$(req "$(adm)" GET /accessProfiles)" | N="$1" python3 -c '
import json,sys,os
for p in (json.load(sys.stdin).get("accessProfiles") or []):
    if p.get("name")==os.environ["N"]: print(json.dumps(p.get("groupIds") or [])); break' 2>/dev/null || echo "[]"; }
apis_seen() { body_of "$(req "$1" GET /apis)" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("(illisible)"); raise SystemExit
print(sorted(x for x in ((it.get("api",it) or {}).get("apiName") for it in (d.get("apiResponse") or [])) if x))' 2>/dev/null || true; }

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

set_priv() {   # set_priv <nom-profil> <bitmask>
  pid=$(prof "$1" id); gids=$(groups_of "$1")
  req "$(adm)" PUT "/accessProfiles/$pid" \
    "{\"id\":\"$pid\",\"name\":\"$1\",\"description\":\"team $1\",\"privilege\":\"$2\",\"groupIds\":$gids}" >/dev/null
  printf '%s' "$(prof "$1" privilege)"
}

echo "=== E1 / D6 — application — $(date -u +%FT%TZ) ==="
wait_health || { echo "!! gateway injoignable"; exit 1; }

# ---------- rollback capturé AVANT d'écrire ---------------------------------
: > "$SAVE"; chmod 600 "$SAVE"
for T in banking-demo insurance-demo; do
  printf '%s %s %s\n' "$T" "$(prof "$T" id)" "$(prof "$T" privilege)" >> "$SAVE"
done
echo "rollback capturé dans $SAVE :"
sed 's/^/  /' "$SAVE"
OLD_B=$(awk '$1=="banking-demo"{print $3}' "$SAVE")
OLD_I=$(awk '$1=="insurance-demo"{print $3}' "$SAVE")

# --- appartenance au groupe système : lecture, retrait, remise ---------------
sysg_id() { body_of "$(req "$(adm)" GET /groups)" | python3 -c '
import json,sys
for g in (json.load(sys.stdin).get("groups") or []):
    if g.get("name")=="API-Gateway-Providers": print(g.get("id")); break' 2>/dev/null || true; }
sysg_members() { body_of "$(req "$(adm)" GET "/groups/$1")" | python3 -c '
import json,sys
d=json.load(sys.stdin)
g=(d.get("groups") or [d])[0] if isinstance(d.get("groups"),list) else d
print(json.dumps(g.get("userIds") or []))' 2>/dev/null || echo "[]"; }
uid_of() { body_of "$(req "$(adm)" GET /users)" | L="$1" python3 -c '
import json,sys,os
for u in (json.load(sys.stdin).get("users") or []):
    if u.get("loginId")==os.environ["L"]: print(u.get("id")); break' 2>/dev/null || true; }
set_members() {   # set_members <gid> <json-liste>
  req "$(adm)" PUT "/groups/$1" "{\"id\":\"$1\",\"name\":\"$SYSG\",\"userIds\":$2}" >/dev/null
  printf '%s' "$(sysg_members "$1")"
}

restore() {
  echo
  echo "  >> ROLLBACK : remise des bitmasks et de l'appartenance système"
  echo "     banking-demo   -> $(set_priv banking-demo "$OLD_B")"
  echo "     insurance-demo -> $(set_priv insurance-demo "$OLD_I")"
  if [ -n "${GID_SYS:-}" ] && [ -s "$SAVEG" ]; then
    echo "     $SYSG membres -> $(set_members "$GID_SYS" "$(cat "$SAVEG")")"
  fi
}

# ---------- T0 : ce que l'équipe peut AVANT ---------------------------------
echo
echo "--- AVANT ---"
echo "  svc-banking-demo   POST /apis          : $(try_create "svc-banking-demo:$P_banking_demo" e1d6ap-avant)"
echo "  svc-banking-demo   GET  /apis          : $(apis_seen "svc-banking-demo:$P_banking_demo")"
echo "  svc-banking-demo   GET  /applications  : $(code_of "$(req "svc-banking-demo:$P_banking_demo" GET /applications)")"

# ---------- appartenance système : relevé + retrait --------------------------
GID_SYS=$(sysg_id)
UB=$(uid_of svc-banking-demo); UI=$(uid_of svc-insurance-demo)
if [ -n "$GID_SYS" ]; then
  sysg_members "$GID_SYS" > "$SAVEG"; chmod 600 "$SAVEG"
  echo "  membres de $SYSG (rollback dans $SAVEG) : $(cat "$SAVEG")"
  NEWM=$(MEM="$(cat "$SAVEG")" A="$UB" C="$UI" python3 -c '
import json,os
m=json.loads(os.environ["MEM"])
out=[u for u in m if u not in (os.environ["A"], os.environ["C"])]
print(json.dumps(out))')
  echo "  retrait des deux comptes d équipe -> $(set_members "$GID_SYS" "$NEWM")"
else
  echo "  !! groupe $SYSG introuvable"
fi

# ---------- application ------------------------------------------------------
echo
echo "--- APPLICATION du bitmask $TARGET ---"
NB=$(set_priv banking-demo "$TARGET");   echo "  banking-demo   relu=$NB  conforme=$(same "$TARGET" "$NB")"
NI=$(set_priv insurance-demo "$TARGET"); echo "  insurance-demo relu=$NI  conforme=$(same "$TARGET" "$NI")"
if [ "$(same "$TARGET" "$NB")" != "oui" ] || [ "$(same "$TARGET" "$NI")" != "oui" ]; then
  echo "  !! écriture non conforme"; restore; exit 1
fi

# ---------- les quatre contre-épreuves --------------------------------------
echo
echo "--- APRÈS : quatre conditions, pas une ---"
C1=$(try_create "svc-banking-demo:$P_banking_demo" e1d6ap-apres)
echo "  1. POST /apis par l'équipe (attendu 401)             : $C1"
C2=$(code_of "$(req "svc-banking-demo:$P_banking_demo" GET /apis)")
SEEN=$(apis_seen "svc-banking-demo:$P_banking_demo")
echo "  2. GET  /apis scopé (attendu 200 + ses APIs)         : $C2  $SEEN"
AID=$(body_of "$(req "$(adm)" GET /apis)" | python3 -c '
import json,sys
for it in json.load(sys.stdin).get("apiResponse") or []:
    a=it.get("api",it)
    if a.get("apiName")=="accounts-read": print(a["id"]); break' 2>/dev/null || true)
C3=$(code_of "$(req "svc-insurance-demo:$P_insurance_demo" GET "/apis/$AID")")
echo "  3. isolation : insurance -> accounts-read (att. 401) : $C3"
C4=$(code_of "$(req "svc-banking-demo:$P_banking_demo" GET /applications)")
echo "  4. GET /applications (E2 en dépend, attendu 200)     : $C4"

OK=1
[ "$C1" = "401" ] || { echo "  !! condition 1 : la brèche n'est PAS fermée"; OK=0; }
case "$SEEN" in *accounts-read*) ;; *) echo "  !! condition 2 : l'équipe ne voit plus ses APIs — P-1 tomberait"; OK=0 ;; esac
[ "$C2" = "200" ] || { echo "  !! condition 2 : GET /apis cassé"; OK=0; }
[ "$C3" = "401" ] || { echo "  !! condition 3 : l'isolation en lecture est cassée"; OK=0; }
[ "$C4" = "200" ] || { echo "  !! condition 4 : la gestion d'applications est cassée (E2)"; OK=0; }

echo
if [ "$OK" = "1" ]; then
  echo "=== D6 APPLIQUÉ — les quatre conditions sont vertes ==="
else
  echo "=== D6 REFUSÉ — au moins une non-régression a rougi ==="
  restore
  echo "  banking-demo   POST /apis après rollback : $(try_create "svc-banking-demo:$P_banking_demo" e1d6ap-rb)"
fi
