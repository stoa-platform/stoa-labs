#!/bin/bash
# E1 / D6 — QUEL privilège porte la création d'API, et où le retirer ?
#
# CE QUI EST MESURÉ, ET POURQUOI DANS CET ORDRE.
#
# Le design de D6 dit « retirer le privilège d'écriture sur les APIs à
# l'accessProfile d'ÉQUIPE ». Mais un utilisateur d'équipe est membre de DEUX
# profils : celui de son équipe ET le groupe système `API-Gateway-Providers`,
# dont l'appartenance est OBLIGATOIRE pour parler à l'admin REST (sinon 403 —
# constat du spike Teams F4). Si les privilèges s'UNIONNENT, retirer un bit au
# profil d'équipe ne retire rien du tout : le système le regrantit.
#
# Donc §1 tranche l'origine du privilège AVANT tout bit-flip. §2 ne cherche le
# bit que si §1 dit que le profil d'équipe compte.
#
# Les privilèges sont OPAQUES en REST (mesuré le 2026-07-31 :
# /accessProfiles/privileges, /privileges, /permissions,
# /accessProfiles/permissions -> 404 les quatre). D'où la recherche par
# BIT-FLIP mesuré, sur un profil JETABLE — jamais sur banking-demo ni
# insurance-demo, qui restent en lecture seule ici.
#
# RÈGLES TENUES : Service d'administration (réplique unique) — à travers
# `wm-apigateway` un 401 ne distingue pas un refus d'un cache froid ; aucun
# secret en argv (curl -K -) ni dans ce dépôt (public) ; tout objet créé est
# supprimé en sortie (trap).
set -eu
umask 077

. /root/f4-teams.env
ADMPW="${WM_ADMIN_PW:-}"
[ -n "$ADMPW" ] || { echo "!! WM_ADMIN_PW absent de /root/f4-teams.env"; exit 1; }

KX="k3s kubectl -n ci exec -i deploy/jenkins --"
B="http://wm-apigateway-admin.wm.svc:5555/rest/apigateway"
PU="svc-e1-probe"                 # utilisateur jetable
PG="e1-probe-devs"                # groupe jetable
PP="e1-probe-profile"             # accessProfile jetable
PPW="$(openssl rand -hex 12)"     # jamais affiché
T0=/root/e1-d6-t0.txt             # relevé restaurable

adm() { printf 'Administrator:%s' "$ADMPW"; }

# req <user:pass> <method> <path> [json] -> corps puis "__CODE__<http>"
#
# ⚠ LE CORPS PASSE PAR UN FICHIER, PAS PAR `data = <json>`. Dans une
# configuration curl (-K), une valeur NON QUOTÉE s'arrête au PREMIER ESPACE —
# pas en fin de ligne. Un JSON contenant une espace (une description, par
# exemple) est donc TRONQUÉ silencieusement côté client, et la gateway rend un
# 400 `JsonEOFException: was expecting closing quote` qui désigne la mauvaise
# cause : on croit à un mauvais shape alors que la requête n'est jamais partie
# entière. Mesuré le 2026-08-02 sur POST /groups. `data = @fichier` supprime la
# classe d'erreur au lieu de l'éviter au cas par cas.
req() {
  if [ -n "${4:-}" ]; then
    printf '%s' "$4" | $KX sh -c 'umask 077; cat > /tmp/e1-body.json'
  fi
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

wait_health() {
  i=0
  while [ "$i" -lt 60 ]; do
    hc=$($KX curl -s -o /dev/null -m 5 -w '%{http_code}' "$B/health" 2>/dev/null || true)
    [ "$hc" = "200" ] && return 0
    i=$((i+1)); sleep 10
  done
  echo "!! gateway injoignable" >&2; return 1
}

pick() {   # pick <collection> <clé-nom> <valeur> <clé-à-rendre>  (sur stdin)
  C="$1" K="$2" V="$3" R="$4" python3 -c '
import json,sys,os
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
items=d.get(os.environ["C"]) or []
if isinstance(items,dict): items=[items]
for it in items:
    if it.get(os.environ["K"])==os.environ["V"]:
        print(it.get(os.environ["R"]) or ""); break
' 2>/dev/null || true
}

uid_of() { body_of "$(req "$(adm)" GET /users)"          | pick users          loginId "$1" id; }
gid_of() { body_of "$(req "$(adm)" GET /groups)"         | pick groups         name    "$1" id; }
pid_of() { body_of "$(req "$(adm)" GET /accessProfiles)" | pick accessProfiles name    "$1" id; }
ppriv()  { body_of "$(req "$(adm)" GET /accessProfiles)" | pick accessProfiles name    "$1" privilege; }

apis_seen() {   # ce que <user:pass> voit du catalogue
  body_of "$(req "$1" GET /apis)" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("(illisible)"); raise SystemExit
print(sorted(x for x in ((it.get("api",it) or {}).get("apiName") for it in (d.get("apiResponse") or [])) if x))' 2>/dev/null || true
}

try_create() {   # try_create <user:pass> <nom> -> code HTTP, et supprime si créée
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
    printf 'url = "%s/apis"\n' "$B"
    printf 'user = "%s"\n' "$1"
    printf 'request = "POST"\n'
    printf 'header = "Accept: application/json"\n'
    printf 'form = "file=@/tmp/%s.yaml;type=application/x-yaml"\n' "$N"
    printf 'form = "type=openapi"\n'
    printf 'form = "apiName=%s"\n' "$N"
    printf 'form = "apiVersion=1.0.0"\n'
    printf 'silent\n'
    printf 'write-out = "\\n__CODE__%%{http_code}"\n'
  } | $KX curl -K - 2>/dev/null )
  c=$(code_of "$out")
  # si créée, la retirer aussitôt (désactiver AVANT de supprimer)
  if [ "$c" = "200" ] || [ "$c" = "201" ]; then
    aid=$(body_of "$(req "$(adm)" GET /apis)" | N2="$N" python3 -c '
import json,sys,os
for it in json.load(sys.stdin).get("apiResponse") or []:
    a=it.get("api",it)
    if a.get("apiName")==os.environ["N2"]: print(a["id"]); break' 2>/dev/null || true)
    if [ -n "$aid" ]; then
      req "$(adm)" PUT "/apis/$aid/deactivate" >/dev/null 2>&1 || true
      req "$(adm)" DELETE "/apis/$aid"          >/dev/null 2>&1 || true
    fi
  fi
  $KX rm -f "/tmp/$N.yaml" 2>/dev/null || true
  printf '%s' "$c"
}

cleanup() {
  echo
  echo "=== NETTOYAGE (les objets jetables) ==="
  for f in "$(pid_of "$PP"):accessProfiles" "$(gid_of "$PG"):groups" "$(uid_of "$PU"):users"; do
    id="${f%%:*}"; col="${f##*:}"
    [ -n "$id" ] || continue
    r=$(req "$(adm)" DELETE "/$col/$id"); echo "  DELETE /$col/$id -> $(code_of "$r")"
  done
}
trap cleanup EXIT

echo "=== E1 / D6 — origine du privilège de création d'API — $(date -u +%FT%TZ) ==="
wait_health

# ---------- relevé restaurable ----------------------------------------------
{ echo "# T0 D6 $(date -u +%FT%TZ) — nom id privilege"
  body_of "$(req "$(adm)" GET /accessProfiles)" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for p in (d.get("accessProfiles") or []):
    print(p.get("name"), p.get("id"), p.get("privilege"))'
} > "$T0"
chmod 600 "$T0"
echo "relevé restaurable : $T0 ($(grep -c . "$T0") lignes)"
REF=$(ppriv API-Gateway-Providers)
echo "bitmask de référence (API-Gateway-Providers) : $REF"

# ---------- création des objets jetables ------------------------------------
UID_=$(uid_of "$PU")
if [ -z "$UID_" ]; then
  r=$(req "$(adm)" POST /users "{\"loginId\":\"$PU\",\"firstName\":\"svc\",\"lastName\":\"e1probe\",\"password\":\"$PPW\",\"active\":true,\"type\":\"local\"}")
  echo "  POST /users $PU -> $(code_of "$r")"
  UID_=$(uid_of "$PU")
else
  # mot de passe inconnu d'un reliquat : le remettre à la valeur du run
  r=$(req "$(adm)" PUT "/users/$UID_" "{\"id\":\"$UID_\",\"loginId\":\"$PU\",\"firstName\":\"svc\",\"lastName\":\"e1probe\",\"password\":\"$PPW\",\"active\":true,\"type\":\"local\"}")
  echo "  (reliquat) PUT /users/$PU -> $(code_of "$r")"
fi
[ -n "$UID_" ] || { echo "!! user non créé"; exit 1; }

GID=$(gid_of "$PG")
if [ -z "$GID" ]; then
  r=$(req "$(adm)" POST /groups "{\"name\":\"$PG\",\"description\":\"probe D6\",\"type\":\"local\"}")
  echo "  POST /groups $PG -> $(code_of "$r")"
  GID=$(gid_of "$PG")
fi
[ -n "$GID" ] || { echo "!! groupe non créé"; exit 1; }
# userIds attend des UUID — les loginId sont ignorés EN SILENCE (200, liste vide)
r=$(req "$(adm)" PUT "/groups/$GID" "{\"id\":\"$GID\",\"name\":\"$PG\",\"description\":\"probe D6\",\"type\":\"local\",\"userIds\":[\"$UID_\"]}")
echo "  PUT /groups/$PG (membre) -> $(code_of "$r")"

PID=$(pid_of "$PP")
if [ -z "$PID" ]; then
  r=$(req "$(adm)" POST /accessProfiles "{\"name\":\"$PP\",\"description\":\"probe D6\",\"privilege\":\"$REF\",\"groupIds\":[\"$GID\"]}")
  echo "  POST /accessProfiles $PP -> $(code_of "$r")"
  PID=$(pid_of "$PP")
fi
[ -n "$PID" ] || { echo "!! accessProfile non créé"; exit 1; }
echo "  profil jetable : $PP id=$PID privilege=$(ppriv "$PP")"

PROBE="$PU:$PPW"

echo
echo "--- §1 : D'OÙ vient le privilège ? (le profil d'équipe, ou le groupe système ?) ---"
echo "  a) membre du SEUL groupe jetable (profil jetable, PAS de API-Gateway-Providers)"
echo "     GET  /apis : $(code_of "$(req "$PROBE" GET /apis)")   catalogue=$(apis_seen "$PROBE")"
echo "     POST /apis : $(try_create "$PROBE" e1d6-a)"

SYSG=$(gid_of API-Gateway-Providers)
if [ -n "$SYSG" ]; then
  cur=$(body_of "$(req "$(adm)" GET "/groups/$SYSG")")
  echo "  b) ajout au groupe système API-Gateway-Providers"
  members=$(printf '%s' "$cur" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("[]"); raise SystemExit
g=(d.get("groups") or [d])[0] if isinstance(d.get("groups"),list) else d
print(json.dumps(g.get("userIds") or []))' 2>/dev/null || echo "[]")
  newm=$(MEM="$members" U="$UID_" python3 -c '
import json,os
m=json.loads(os.environ["MEM"])
u=os.environ["U"]
if u not in m: m.append(u)
print(json.dumps(m))')
  r=$(req "$(adm)" PUT "/groups/$SYSG" "{\"id\":\"$SYSG\",\"name\":\"API-Gateway-Providers\",\"userIds\":$newm}")
  echo "     PUT groupe système -> $(code_of "$r")"
  echo "     GET  /apis : $(code_of "$(req "$PROBE" GET /apis)")   catalogue=$(apis_seen "$PROBE")"
  echo "     POST /apis : $(try_create "$PROBE" e1d6-b)"
else
  echo "  b) groupe système API-Gateway-Providers introuvable — §1b sauté"
fi

echo
echo "--- §2 : QUEL bit ? (bit-flip sur le profil JETABLE uniquement) ---"
echo "  position | privilege                | GET /apis | POST /apis"
i=0
LEN=${#REF}
while [ "$i" -lt "$LEN" ]; do
  case "$(printf '%s' "$REF" | cut -c$((i+1)))" in
    1) ;;
    *) i=$((i+1)); continue ;;
  esac
  # ⚠ les affectations d'environnement passent AVANT la commande. Écrire
  # `python3 -c '…' REF="$REF"` les passe en ARGUMENTS de python : os.environ
  # lève alors une KeyError, et un `|| true` l'avale — la boucle tourne à vide
  # en silence. Constaté au premier run : zéro ligne, aucune erreur.
  FLIP=$(POS="$i" REF="$REF" python3 -c '
import os
b=list(os.environ["REF"]); b[int(os.environ["POS"])]="0"; print("".join(b))')
  [ -n "$FLIP" ] || { echo "  !! flip vide en position $i"; i=$((i+1)); continue; }
  r=$(req "$(adm)" PUT "/accessProfiles/$PID" "{\"id\":\"$PID\",\"name\":\"$PP\",\"description\":\"probe D6\",\"privilege\":\"$FLIP\",\"groupIds\":[\"$GID\"]}")
  # relecture OBLIGATOIRE : un 200 ne prouve pas l'écriture (leçon /assets/team)
  AFTER=$(ppriv "$PP")
  if [ "$AFTER" != "$FLIP" ]; then
    printf '  %8s | ÉCRITURE NON PRISE (PUT %s, relu %s)\n' "$i" "$(code_of "$r")" "$AFTER"
    i=$((i+1)); continue
  fi
  G=$(code_of "$(req "$PROBE" GET /apis)")
  P=$(try_create "$PROBE" "e1d6-p$i")
  printf '  %8s | %s | %9s | %s\n' "$i" "$FLIP" "$G" "$P"
  i=$((i+1))
done

# profil jetable remis à la référence avant suppression (hygiène)
req "$(adm)" PUT "/accessProfiles/$PID" "{\"id\":\"$PID\",\"name\":\"$PP\",\"description\":\"probe D6\",\"privilege\":\"$REF\",\"groupIds\":[\"$GID\"]}" >/dev/null 2>&1 || true

echo
echo "=== FIN ==="
