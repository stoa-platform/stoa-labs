#!/bin/bash
# E1 — le VOLET LECTURE des portes : ce que chaque identité voit du résultat de
# la chaîne. Le volet écriture (publication, refus) est joué par le rôle Ansible
# depuis un pod agent ; ici on relit avec les identités d'équipe, ce qu'Ansible
# ne peut pas faire (il tourne sous l'identité d'administration).
#
# RÈGLES TENUES : Service d'administration (réplique unique) — à travers
# `wm-apigateway` un 401 ne distingue pas un refus d'un cache froid ; aucun
# secret en argv (curl -K - lit sa config sur stdin) ni dans ce dépôt (public) ;
# chaque refus est encadré d'un TÉMOIN, sans quoi il ne se distingue pas d'une
# requête malformée.
set -eu
umask 077

. /root/f4-teams.env          # P_banking_demo, P_insurance_demo, WM_ADMIN_PW
ADMPW="${WM_ADMIN_PW:-}"
[ -n "$ADMPW" ] || { echo "!! WM_ADMIN_PW absent de /root/f4-teams.env"; exit 1; }

KX="k3s kubectl -n ci exec -i deploy/jenkins --"
B="http://wm-apigateway-admin.wm.svc:5555/rest/apigateway"
GATE_API="${GATE_API:-e1-gate-api}"
CROSS_API="${CROSS_API:-e1-cross-api}"

id_pw() {
  case "$1" in
    admin)     printf 'Administrator:%s' "$ADMPW" ;;
    banking)   printf 'svc-banking-demo:%s' "$P_banking_demo" ;;
    insurance) printf 'svc-insurance-demo:%s' "$P_insurance_demo" ;;
  esac
}

# req <ident> <method> <path> -> corps, puis "__CODE__<http>"
req() {
  {
    printf 'url = "%s%s"\n' "$B" "$3"
    printf 'user = "%s"\n' "$(id_pw "$1")"
    printf 'request = "%s"\n' "$2"
    printf 'header = "Accept: application/json"\n'
    printf 'silent\n'
    printf 'write-out = "\\n__CODE__%%{http_code}"\n'
  } | $KX curl -K - 2>/dev/null
}
code_of() { printf '%s' "$1" | sed -n 's/.*__CODE__\([0-9]*\)$/\1/p'; }
body_of() { printf '%s' "$1" | sed 's/__CODE__[0-9]*$//'; }

api_id() {   # api_id <nom> [ident=admin]
  r=$(req "${2:-admin}" GET "/apis")
  body_of "$r" | N="$1" python3 -c '
import json,sys,os
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
for it in d.get("apiResponse") or []:
    a=it.get("api",it)
    if a.get("apiName")==os.environ["N"]: print(a["id"]); break
' 2>/dev/null || true
}

api_names() {  # les APIs vues par <ident>
  r=$(req "$1" GET "/apis")
  body_of "$r" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("(illisible)"); raise SystemExit
print(sorted(x for x in ((it.get("api",it) or {}).get("apiName") for it in (d.get("apiResponse") or [])) if x))
' 2>/dev/null || true
}

echo "=== E1 / portes — volet lecture — $(date -u +%FT%TZ) — Service d'administration ==="
ID=$(api_id "$GATE_API")
[ -n "$ID" ] || { echo "!! $GATE_API introuvable — la chaîne a-t-elle publié ?"; exit 1; }
echo "  $GATE_API id=$ID"

echo
echo "--- P-1 : l'API est cloisonnée sur banking-demo ---"
r=$(req banking GET "/apis/$ID");   echo "  TÉMOIN  svc-banking-demo   GET /apis/{id} : $(code_of "$r")   (attendu 200)"
r=$(req insurance GET "/apis/$ID"); echo "  REFUS   svc-insurance-demo GET /apis/{id} : $(code_of "$r")   (attendu 401)"
echo "  catalogue vu par banking-demo   : $(api_names banking)"
echo "  catalogue vu par insurance-demo : $(api_names insurance)"

echo
echo "--- P-2 : le refus cross-team n'a RIEN laissé derrière lui ---"
CID=$(api_id "$CROSS_API")
if [ -z "$CID" ]; then
  echo "  $CROSS_API ABSENTE du catalogue — le refus n'a rien créé."
else
  echo "  !! $CROSS_API PRÉSENTE (id=$CID) — le refus a laissé une API derrière lui."
fi

echo
echo "=== FIN ==="
