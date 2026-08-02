#!/bin/bash
# E1 — MESURE : que refuse RÉELLEMENT wM 10.15 sur la publication d'une API,
# identité par identité ? Le GOAL attend un 400 « User cannot assign the
# specified team to API » (spike #1, 2026-07-09, lab Docker) ; la mesure E3 du
# 2026-07-31 sur CETTE gateway dit qu'un utilisateur d'équipe est refusé 401 sur
# la ressource `assets` tout court. Les deux ne peuvent pas être vrais ici.
#
# RÈGLES TENUES :
#  - toutes les requêtes visent le Service d'ADMINISTRATION (réplique unique) :
#    à travers `wm-apigateway` un 401 peut être un cache froid, pas un refus.
#  - aucun mot de passe en argv (curl -K - : config sur stdin), aucun affiché.
#  - API jetable dédiée ; `accounts-read` (qui sert le public) n'est JAMAIS touchée.
#  - chaque refus est opposé à un TÉMOIN bien formé : sans lui, un échec ne
#    distingue pas « refusé » de « ma requête est mauvaise » (leçon du 2026-07-31).
set -eu
umask 077

# Mots de passe : fichier root-only du noeud, JAMAIS dans ce depot (public) ni en
# argv. Attendu : P_banking_demo, P_insurance_demo (poses au bootstrap F4) et
# WM_ADMIN_PW (identite d'administration de la gateway).
. /root/f4-teams.env
ADMPW="${WM_ADMIN_PW:-}"
[ -n "$ADMPW" ] || { echo "!! WM_ADMIN_PW absent de /root/f4-teams.env — l'y ajouter (fichier 0600, root)"; exit 1; }

KX="k3s kubectl -n ci exec -i deploy/jenkins --"
B="http://wm-apigateway-admin.wm.svc:5555/rest/apigateway"
PROBE_A="e1-probe-owned"                  # créée par l'admin, assignée à banking-demo
PROBE_B="e1-probe-byteam"                 # tentative de création par un membre d'équipe
VER="1.0.0"

id_pw() {
  case "$1" in
    admin)     printf 'Administrator:%s' "$ADMPW" ;;
    banking)   printf 'svc-banking-demo:%s' "$P_banking_demo" ;;
    insurance) printf 'svc-insurance-demo:%s' "$P_insurance_demo" ;;
    *) echo "identite inconnue: $1" >&2; return 1 ;;
  esac
}

# req <ident> <method> <path> [json-compact]  -> corps puis "__CODE__<http>"
req() {
  who="$1"; m="$2"; p="$3"; body="${4:-}"
  {
    printf 'url = "%s%s"\n' "$B" "$p"
    printf 'user = "%s"\n' "$(id_pw "$who")"
    printf 'request = "%s"\n' "$m"
    printf 'header = "Accept: application/json"\n'
    if [ -n "$body" ]; then
      printf 'header = "Content-Type: application/json"\n'
      printf 'data = %s\n' "$body"
    fi
    printf 'silent\n'
    printf 'write-out = "\\n__CODE__%%{http_code}"\n'
  } | $KX curl -K - 2>/dev/null
}

code_of() { printf '%s' "$1" | sed -n 's/.*__CODE__\([0-9]*\)$/\1/p'; }
body_of() { printf '%s' "$1" | sed 's/__CODE__[0-9]*$//'; }

# msg <corps> : le message d'erreur wM, tronqué (il porte la vraie cause)
msg() {
  printf '%s' "$1" | python3 -c '
import json,sys
raw=sys.stdin.read().strip()
try:
    d=json.loads(raw)
except Exception:
    print(raw[:160].replace("\n"," ")); raise SystemExit
for k in ("message","errorMessage","error","description"):
    if isinstance(d,dict) and d.get(k):
        print(str(d[k])[:200]); raise SystemExit
print(json.dumps(d)[:200])
' 2>/dev/null || true
}

wait_health() {
  i=0
  while [ "$i" -lt 60 ]; do
    hc=$($KX curl -s -o /dev/null -m 5 -w '%{http_code}' "$B/health" 2>/dev/null || true)
    [ "$hc" = "200" ] && return 0
    i=$((i+1)); sleep 5
  done
  echo "!! gateway injoignable apres 5 min" >&2; return 1
}

# id d'une API par nom+version, lu par l'admin
api_id() {
  r=$(req admin GET "/apis")
  body_of "$r" | API_N="$1" API_V="$2" python3 -c '
import json,sys,os
d=json.load(sys.stdin); items=d.get("apiResponse") or []
if isinstance(items,dict): items=[items]
for it in items:
    a=it.get("api",it)
    if a.get("apiName")==os.environ["API_N"] and a.get("apiVersion")==os.environ["API_V"]:
        print(a["id"]); break
' 2>/dev/null || true
}

# teams relues d'une API, par l'admin (niveau apiResponse — api.teams est vide)
api_teams() {
  r=$(req admin GET "/apis/$1")
  body_of "$r" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("(illisible)"); raise SystemExit
t=(d.get("apiResponse") or {}).get("teams") or []
print([x.get("name") for x in t])
' 2>/dev/null || true
}

team_uuid() {
  r=$(req admin GET "/accessProfiles")
  body_of "$r" | TN="$1" python3 -c '
import json,sys,os
d=json.load(sys.stdin)
profs=d.get("accessProfiles") or d.get("accessProfile") or []
if isinstance(profs,dict): profs=[profs]
for p in profs:
    if p.get("name")==os.environ["TN"]: print(p["id"]); break
' 2>/dev/null || true
}

# import multipart d'une API minimale, sous l'identité <ident>
import_api() {
  who="$1"; name="$2"
  $KX sh -c "umask 077; cat > /tmp/$name.yaml" <<YAML
openapi: "3.0.0"
info: { title: "$name", version: "$VER" }
servers: [ { url: "http://backend-dev.wm.svc.cluster.local:8080" } ]
paths:
  /ping:
    get:
      responses: { "200": { description: ok } }
YAML
  {
    printf 'url = "%s/apis"\n' "$B"
    printf 'user = "%s"\n' "$(id_pw "$who")"
    printf 'request = "POST"\n'
    printf 'header = "Accept: application/json"\n'
    printf 'form = "file=@/tmp/%s.yaml;type=application/x-yaml"\n' "$name"
    printf 'form = "type=openapi"\n'
    printf 'form = "apiName=%s"\n' "$name"
    printf 'form = "apiVersion=%s"\n' "$VER"
    printf 'silent\n'
    printf 'write-out = "\\n__CODE__%%{http_code}"\n'
  } | $KX curl -K - 2>/dev/null
}

assign() {   # assign <ident> <apiId> <teamUuid>
  req "$1" POST "/assets/team" "{\"assetIds\":[\"$2\"],\"assetType\":\"API\",\"newTeams\":[\"$3\"]}"
}

drop_api() {
  [ -n "${1:-}" ] || return 0
  req admin PUT "/apis/$1/deactivate" >/dev/null 2>&1 || true   # desactiver avant de supprimer
  r=$(req admin DELETE "/apis/$1"); echo "    cleanup DELETE /apis/$1 -> $(code_of "$r")"
}

IDA=""; IDB=""
cleanup() { echo; echo "=== NETTOYAGE ==="; drop_api "$IDA"; drop_api "$IDB"; $KX sh -c "rm -f /tmp/$PROBE_A.yaml /tmp/$PROBE_B.yaml" 2>/dev/null || true; }
trap cleanup EXIT

echo "=== E1 / matrice de refus — $(date -u +%FT%TZ) — Service d'administration (replique unique) ==="
wait_health
TB=$(team_uuid banking-demo);   [ -n "$TB" ] || { echo "!! accessProfile banking-demo introuvable"; exit 1; }
TI=$(team_uuid insurance-demo); [ -n "$TI" ] || { echo "!! accessProfile insurance-demo introuvable"; exit 1; }
echo "teams resolues : banking-demo + insurance-demo (UUID ok)"

echo
echo "--- M0 : preparation (Administrator) ---"
IDA=$(api_id "$PROBE_A" "$VER")
if [ -z "$IDA" ]; then
  r=$(import_api admin "$PROBE_A"); echo "  POST /apis ($PROBE_A, admin) -> $(code_of "$r")"
  IDA=$(api_id "$PROBE_A" "$VER")
fi
[ -n "$IDA" ] || { echo "!! import KO"; exit 1; }
echo "  teams a la creation                 : $(api_teams "$IDA")"
r=$(assign admin "$IDA" "$TB"); echo "  admin assigne -> banking-demo       : $(code_of "$r")"
echo "  teams relues                        : $(api_teams "$IDA")"

echo
echo "--- M1 : ce que le produit oppose a un MEMBRE d'equipe (svc-banking-demo, proprietaire) ---"
r=$(req banking GET "/apis/$IDA"); c=$(code_of "$r")
echo "  TEMOIN  GET /apis/{id} (sa propre API)          : $c"
r=$(assign banking "$IDA" "$TB"); c=$(code_of "$r")
echo "  POST /assets/team -> SA PROPRE team             : $c   $(msg "$(body_of "$r")")"
r=$(assign banking "$IDA" "$TI"); c=$(code_of "$r")
echo "  POST /assets/team -> team d'une AUTRE equipe    : $c   $(msg "$(body_of "$r")")"
echo "  teams relues (admin)                            : $(api_teams "$IDA")"

echo
echo "--- M2 : ce que le produit oppose a une equipe TIERCE (svc-insurance-demo) ---"
r=$(req insurance GET "/apis/$IDA"); c=$(code_of "$r")
echo "  GET /apis/{id} (API de banking-demo)            : $c   $(msg "$(body_of "$r")")"
r=$(assign insurance "$IDA" "$TI"); c=$(code_of "$r")
echo "  POST /assets/team -> se l'attribuer              : $c   $(msg "$(body_of "$r")")"
echo "  teams relues (admin)                            : $(api_teams "$IDA")"

echo
echo "--- M3 : ce que le produit oppose a l'ADMIN — l'identite QUE LA CHAINE PORTE ---"
r=$(assign admin "$IDA" "$TI"); c=$(code_of "$r")
echo "  admin assigne l'API de banking -> insurance     : $c   $(msg "$(body_of "$r")")"
echo "  teams relues                                    : $(api_teams "$IDA")"
r=$(assign admin "$IDA" "$TB"); echo "  (remise en etat -> banking-demo)                : $(code_of "$r") / $(api_teams "$IDA")"

echo
echo "--- M4 : un MEMBRE d'equipe peut-il publier une API tout court ? ---"
r=$(import_api banking "$PROBE_B"); c=$(code_of "$r")
echo "  POST /apis multipart (svc-banking-demo)         : $c   $(msg "$(body_of "$r")")"
IDB=$(api_id "$PROBE_B" "$VER")
if [ -n "$IDB" ]; then
  echo "  teams de l'API creee par l'equipe               : $(api_teams "$IDB")"
  r=$(req insurance GET "/apis/$IDB"); echo "  une equipe TIERCE la voit-elle ?                : $(code_of "$r")"
else
  echo "  (aucune API creee — le membre d'equipe ne publie pas)"
fi

echo
echo "=== FIN DE MATRICE ==="
