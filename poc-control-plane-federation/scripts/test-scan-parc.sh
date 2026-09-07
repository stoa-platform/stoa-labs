#!/usr/bin/env bash
# test-scan-parc.sh — preuve X/X du scan de parc. TOUT EN LOCAL : le « wM » est
# un faux serveur HTTP python qui sert les ENVELOPPES réelles de la 10.15.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/scanparc.XXXXXX)"
PORT="${FAKE_WM_PORT:-18620}"
PID=""
cleanup(){ [ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# ── faux wM 10.15 : enveloppes RÉELLES (teams au niveau de l'entrée, pas dans api) ──
cat > "$TMP/fakewm.py" <<'PY'
import json, os
from http.server import BaseHTTPRequestHandler, HTTPServer
APIS = [
  # (id, name, version, isActive, teams)
  ("g-pai-100", "paiements", "1.0.0", True,  ["toto", "Administrators"]),
  ("g-pai-101", "paiements", "1.0.1", True,  ["Default", "Administrators"]),   # lignée mixte
  ("g-vir-100", "virements", "1.0.0", True,  ["toto", "titi"]),                # multi-équipes
  ("g-leg-100", "legacy_API", "1.0.0", True, ["toto"]),                        # nom hors regex
  ("g-off-100", "offline-api", "1.0.0", False, ["toto"]),                      # inactive
  ("g-orp-100", "orpheline", "1.0.0", True,  ["Default", "Administrators"]),   # non appropriée
  ("g-cpt-100", "comptes", "1.0.0", True,  ["toto", "Administrators"]),        # lignée PROPRE (R1)
  ("g-vie-100", "vieille-api", "v1", True, ["toto", "Administrators"]),        # version hors regex
  ("g-gel-100", "gel-fonds", "1.0.0", True,  ["toto", "Administrators"]),      # v1 réelle, active
  ("g-gel-110", "gel-fonds", "1.1.0", False, ["Default", "Administrators"]),   # v2 étrangère ET inactive — priorité
]
def env(a):
    i, n, v, act, teams = a
    return {"api": {"id": i, "apiName": n, "apiVersion": v, "isActive": act},
            "responseStatus": "SUCCESS",
            "teams": [{"id": "u-"+t, "name": t} for t in teams]}
# vocabulaire RÉEL des identifiers (mesuré, cf. estate.sh:estate_applications) :
# {httpsCertificate, ipAddressRange, openIdClaims, token}. Le canari
# CANARI-CLE-INCONNUE prouve le défaut-deny : un type que PERSONNE n'a prévu
# doit être masqué comme les autres, jamais transporté.
IDENTIFIERS = [
    {"key": "token", "name": "app-front", "value": ["CANARI-TOKEN-NE-DOIT-PAS-FUIR"]},
    {"key": "openIdClaims", "name": "app-front", "value": ["CANARI-CLAIMS-NE-DOIT-PAS-FUIR"]},
    {"key": "httpsCertificate", "name": "app-front-exp-20270101", "value": ["CANARI-CERT-NE-DOIT-PAS-FUIR"]},
    {"key": "ipAddressRange", "name": "app-front", "value": ["10.42.0.1-10.42.0.1"]},
    {"key": "coupon-fidelite", "name": "app-front", "value": ["CANARI-CLE-INCONNUE-NE-DOIT-PAS-FUIR"]},
]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj=None):
        b = json.dumps(obj if obj is not None else {}).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        auth = self.headers.get("Authorization")
        p = self.path.split("?")[0]
        if not auth:
            return self._send(401, {"error": "no token"})     # la preuve de vie du proxy
        if auth == "Basic SANS-GROUPE":
            return self._send(401, {"error": "User is not a member of any administrator group"})
        if p.endswith("/archive"):
            # le contrat du proxy DECLARE le GET mais type sa reponse
            # application/json (cf. scan-parc.sh) : par defaut on rend un 200
            # qui n'est PAS un zip, pour prouver que la sonde verifie l'octet
            # magique et ne se contente pas d'un code 200. Bascule pilotee
            # par fichier pour rendre un VRAI zip (octets PK\x03\x04) quand
            # le test le demande explicitement.
            flagzip = os.environ.get("ARCHIVE_REAL_ZIP_FLAG", "")
            if flagzip and os.path.exists(flagzip):
                body = b"PK\x03\x04" + b"\x00" * 16
                self.send_response(200)
                self.send_header("Content-Type", "application/zip")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            return self._send(200, {"not": "a zip — application/json comme declare"})
        if p.endswith("/apis"):
            if "slow=1" in self.path:
                import time; time.sleep(1)   # sonde 1a : un appel VOLONTAIREMENT lent
            return self._send(200, {"apiResponse": [env(a) for a in APIS]})
        if "/apis/" in p:
            gid = p.rsplit("/", 1)[1]
            for a in APIS:
                if a[0] == gid:
                    e = env(a)
                    # bascule pilotée par fichier (constat 3, fix round 1) : une
                    # lignée OK dont l'apiDefinition disparaît côté gateway doit
                    # faire refuser CONTRAT_ABSENT — sans redémarrer le serveur.
                    flag = os.environ.get("FAIL_APIDEF_FLAG", "")
                    if flag and os.path.exists(flag) and gid == os.environ.get("FAIL_APIDEF_GUID", ""):
                        e["api"]["apiDefinition"] = None
                    else:
                        e["api"]["apiDefinition"] = {
                            "openapi": "3.0.1", "info": {"title": a[1], "version": a[2]},
                            "paths": {"/x": {"get": {"responses": {"200": {"description": "OK"}}}}}}
                    return self._send(200, {"apiResponse": e})
            return self._send(404)
        if p.endswith("/applications"):
            return self._send(200, {"applications": [
                {"id": "app-1", "name": "app-front"},
                {"id": "app-2", "name": "app-perso"},
                {"id": "app-3", "name": "app-nue"}]})
        if p.endswith("/applications/app-1"):
            return self._send(200, {"applications": [{
                "id": "app-1", "name": "app-front", "owner": "toto", "ownerType": "team",
                "teams": [{"name": "toto"}],
                "consumingAPIs": ["g-pai-100"],
                "identifiers": IDENTIFIERS,
                # NE DOIT JAMAIS ÊTRE LU : la vraie clé d'API vit ici sur la
                # 10.15 réelle, pas dans `identifiers` (cf. estate.sh). Présent
                # dans la fixture pour PROUVER que rien ne le recopie.
                "accessTokens": {"apiAccessKey_credentials": {
                    "apiAccessKey": "CANARI-ACCESSTOKENS-NE-DOIT-JAMAIS-FUIR"}}}]})
        if p.endswith("/applications/app-2"):
            # SITUATION n°7 DE LA SPEC (§5.4), codée et SANS jeu d'essai
            # jusqu'ici : toute la branche ownerType=user était MORTE. Le
            # relecteur l'a mesuré — supprimer le verdict
            # APP_PROPRIETE_INDIVIDUELLE *ou* le masque
            # CLE_MASQUEE_PROPRIETAIRE_UTILISATEUR laissait la suite à 51/51.
            return self._send(200, {"applications": [{
                "id": "app-2", "name": "app-perso", "owner": "oscar", "ownerType": "user",
                "consumingAPIs": ["g-pai-100"],
                "identifiers": [{"key": "token", "name": "app-perso",
                                 "value": ["CANARI-TOKEN-USER-NE-DOIT-PAS-FUIR"]}]}]})
        if p.endswith("/applications/app-3"):
            # ENVELOPPE ABSENTE — l'objet est rendu NU, sans la clé
            # `applications`. La spec (§5.3) prévient que « les enveloppes
            # sont incohérentes » : c'est un cas NOMINAL du produit, pas un
            # accident. Le repli `or [{}]` d'estate.sh rendait alors
            # ownerType="" et identifiants=[] ⇒ verdict "OK" : une
            # application en propriété INDIVIDUELLE déclarée CONFORME.
            self.send_response(200)
            b = json.dumps({"id": "app-3", "name": "app-nue", "owner": "oscar",
                            "ownerType": "user",
                            "identifiers": [{"key": "token", "name": "app-nue",
                                             "value": ["CANARI-TOKEN-NU-NE-DOIT-PAS-FUIR"]}]}).encode()
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b))); self.end_headers()
            self.wfile.write(b)
            return
        if "/applications/" in p:
            return self._send(404)
        return self._send(404)
HTTPServer(("127.0.0.1", int(os.environ["PORT"])), H).serve_forever()
PY
PORT="$PORT" FAIL_APIDEF_FLAG="$TMP/fail-apidef.flag" FAIL_APIDEF_GUID="g-cpt-100" \
ARCHIVE_REAL_ZIP_FLAG="$TMP/archive-real-zip.flag" \
  python3 "$TMP/fakewm.py" & PID=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/apis" && break; sleep 0.1
done
BASE="http://127.0.0.1:$PORT"

echo "== 1. wm-admin-curl : auth, préflight, diagnostic =="
LIBC="$REPO/scripts/lib/wm-admin-curl.sh"

# 1a. aucun secret en argv (ni en clair, ni encodé) : on sonde ps PENDANT un
# appel réellement lent (wm_admin_init PUIS un wm_get contre /apis?slow=1,
# qui bloque 1s côté faux wM — ainsi curl reste en vie, argv visible, le
# temps de la capture). On cherche la valeur ENCODÉE de l'en-tête Basic,
# pas le mot de passe en clair : un `Authorization: Basic …` est du base64,
# le mot de passe brut n'y apparaît jamais tel quel — chercher "s3cr3t"
# littéral ne prouverait rien (vérifié : curl -u SCRUBBE lui-même la valeur
# de son propre argv depuis plusieurs versions, sur macOS ET sur Linux —
# une fuite par `-u` n'est donc plus observable par ps du tout ; en
# revanche un `-H "Authorization: …"` en clair dans l'argv, lui, n'est
# JAMAIS scrubbé — c'est ce vecteur qu'on prouve ici).
# La capture ps se fait dans un process dont l'argv NE PORTE PAS le motif
# recherché : `ps -Aww | grep "$motif"` se matcherait LUI-MÊME (le motif
# apparaît dans l'argv du grep qui le cherche) et rougirait TOUJOURS,
# secret ou pas — on écrit donc le relevé dans un fichier, et on grep ce
# fichier depuis le script appelant, jamais depuis le process sondé.
#
# TROIS CANARIS DISTINCTS, un par règle gardée : ARGV ici, REFUS en 1g,
# FICHIER en 6a-bis. Ils ne peuvent pas être le même mot : `scan()` passe ses
# variables par l'ARGV d'`env`, si bien qu'un canari partagé ferait rougir
# CETTE sonde ps dès que deux exécutions du harnais se chevauchent (mesuré) —
# un faux positif qui ressemblerait exactement à la fuite qu'on traque.
#
# CORRECTIF (vague finale). Cette épreuve gardait UN vecteur sur DEUX. Le
# fichier affirmait « LE SECRET NE PASSE JAMAIS PAR ARGV » ; mesuré : pendant
# que le canari Basic base64 comptait 0 occurrence, le mot de passe porté par
# l'USERINFO DE L'URL (`https://svc-scan:<mdp>@apim…`, la forme d'une base
# d'admin de site) en comptait 2 — l'URL passait en argv de curl. La base
# porte donc DÉSORMAIS un userinfo, et les DEUX canaris sont comptés.
# Un canari doit contenir exactement le caractère qui casse la règle qu'il garde.
B64="$(printf '%s:%s' adm s3cr3t | base64 | tr -d '\n')"
MDPURL=M0tDeP4sseDeLARGV
PSFILE="$TMP/ps.snap"
APIM_BASE="http://svc-scan:${MDPURL}@127.0.0.1:$PORT" APIM_AUTH_MODE=basic WM_USER=adm WM_PASSWORD=s3cr3t \
  bash -c '. "'"$LIBC"'" && wm_admin_init && wm_get "/apis?slow=1" "'"$TMP"'/probe.out" >/dev/null' &
BGPID=$!
sleep 0.3
ps -Aww > "$PSFILE" 2>/dev/null
wait "$BGPID" 2>/dev/null
OUT="$(grep -c "$B64" "$PSFILE" 2>/dev/null || true)"
[ "${OUT:-1}" = "0" ] && ok "aucun secret d'en-tête dans l'argv d'aucun process (sonde ps -Aww)" \
  || ko "le secret d'en-tête apparaît dans un argv (${OUT} occurrence(s))"
OUTU="$(grep -c "$MDPURL" "$PSFILE" 2>/dev/null || true)"
[ "${OUTU:-1}" = "0" ] && ok "l'USERINFO DE L'URL non plus n'apparaît dans aucun argv (curl -K, pas l'URL en clair)" \
  || ko "le mot de passe d'URL apparaît dans un argv (${OUTU} occurrence(s)) :: $(grep "$MDPURL" "$PSFILE" | head -3 | cut -c1-200)"
# et l'appel a bien abouti : `curl -K` ne doit pas être un silence qui passe
# pour une réussite (le corps rendu par le faux wM porte apiResponse).
grep -q 'apiResponse' "$TMP/probe.out" 2>/dev/null \
  && ok "l'appel via curl -K a réellement atteint la gateway (corps apiResponse reçu)" \
  || ko "curl -K n'a rien rapporté — l'URL du fichier de configuration n'a pas été suivie"

# 1b. le fichier d'en-tête est 0600
M="$(APIM_BASE="$BASE" APIM_AUTH_MODE=basic WM_USER=adm WM_PASSWORD=s3cr3t \
  bash -c '. "'"$LIBC"'" && wm_admin_init && stat -f "%Lp" "$WM_HDR" 2>/dev/null || stat -c "%a" "$WM_HDR"')"
[ "$M" = "600" ] && ok "le fichier d'en-tête est en 0600" || ko "mode du fichier d'en-tête : '$M'"

# 1c. préflight : 401 SANS jeton est une preuve de vie
APIM_BASE="$BASE" bash -c '. "'"$LIBC"'" && wm_preflight' >/dev/null 2>"$TMP/pf.err" \
  && ok "préflight : 401 sans jeton accepté comme preuve de vie (200 401)" \
  || ko "préflight refusé alors que le faux wM rend 401 : $(cat "$TMP/pf.err")"

# 1d. le préflight ne vise PAS /health (WM_PREFLIGHT_URL n'est posée QUE par
# wm_preflight — il faut donc l'appeler avant de la lire, sinon elle est vide)
APIM_BASE="$BASE" bash -c '. "'"$LIBC"'" && wm_preflight >/dev/null 2>&1; printf "%s\n" "$WM_PREFLIGHT_URL"' 2>/dev/null \
  | grep -q '/apis$' && ok "la sonde par défaut est <BASE>/apis, jamais /health" \
  || ko "la sonde par défaut n'est pas <BASE>/apis"

# 1e. APIM_PREFLIGHT=off désactive
APIM_BASE="http://127.0.0.1:1" APIM_PREFLIGHT=OFF bash -c '. "'"$LIBC"'" && wm_preflight' >/dev/null 2>&1 \
  && ok "APIM_PREFLIGHT=OFF désactive (comparaison insensible à la casse)" \
  || ko "APIM_PREFLIGHT=OFF n'a pas désactivé le préflight"

# 1g. le REFUS lui-même ne fuit pas (spec §9.5 : « base d'admin dans un
# message : expurgée »). Mesuré avant correctif :
#   REFUS: GATEWAY_INJOIGNABLE : sonde https://svc-scan:M0tDeP4sse@…/apis -> HTTP 000000
# sur stderr — donc dans le log de build, donc archivé. L'expurgation
# EXISTAIT, écrite, mais uniquement du côté du FICHIER (scan-parc.sh) :
# l'asymétrie était le défaut. Elle est maintenant UNE fonction partagée.
APIM_BASE="https://svc-scan:M0tDeP4sseDuREFUS@127.0.0.1:1/rest/apigateway" \
  bash -c '. "'"$LIBC"'" && wm_preflight' >/dev/null 2>"$TMP/pf3.err"
grep -q 'M0tDeP4sseDuREFUS' "$TMP/pf3.err" \
  && ko "FUITE : le refus GATEWAY_INJOIGNABLE porte l'userinfo de la base sur stderr" \
  || ok "le refus GATEWAY_INJOIGNABLE ne porte plus l'userinfo (message expurgé)"
grep -q '<identifiants masqués>' "$TMP/pf3.err" \
  && ok "le refus montre bien l'URL sondée, userinfo remplacé par <identifiants masqués>" \
  || ko "le refus n'affiche plus l'URL sondée du tout : $(cat "$TMP/pf3.err")"
# le code annoncé est celui que curl a rendu, UNE fois. `curl -w %{http_code}`
# imprime DÉJÀ 000 en cas d'échec de connexion ; le `|| echo 000` d'alors en
# concaténait un second et le message annonçait « HTTP 000000 ».
grep -q 'HTTP 000 (attendus' "$TMP/pf3.err" \
  && ok "le refus annonce HTTP 000, pas le HTTP 000000 d'un code concaténé deux fois" \
  || ko "code HTTP mal formé dans le refus : $(cat "$TMP/pf3.err")"

# 1f. les deux causes d'un 401 sont distinguées
printf '{"error":"User is not a member of any administrator group"}' > "$TMP/401.json"
bash -c '. "'"$LIBC"'" && wm_diag_401 "'"$TMP"'/401.json"' 2>&1 | grep -qi "droits de lecture" \
  && ok "401 d'AUTORISATION : le diagnostic demande les droits de lecture, pas un mot de passe" \
  || ko "le diagnostic ne distingue pas les deux causes d'un 401"

echo "== 2. estate.sh : normalisation, lignée, verdicts =="
LIBE="$REPO/scripts/lib/estate.sh"
curl -s -H "Authorization: Basic ok" "$BASE/apis" > "$TMP/apis.json"
bash -c '. "'"$LIBE"'" && estate_from_apis "'"$TMP"'/apis.json" "'"$TMP"'/lignees.json"' 2>"$TMP/e.err"
verdict(){ python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for l in d["lignees"]:
    if l["nom"]==sys.argv[2]: print(l["verdict"]); break
else: print("ABSENTE")' "$TMP/lignees.json" "$1"; }

[ "$(verdict paiements)" = "LIGNEE_PARTIELLEMENT_ETRANGERE" ] \
  && ok "lignée mixte (v1.0.1 en Default) ⇒ LIGNEE_PARTIELLEMENT_ETRANGERE, pas OK sur v1.0.0" \
  || ko "paiements : verdict '$(verdict paiements)'"
[ "$(verdict virements)" = "API_MULTI_EQUIPES" ] \
  && ok "deux équipes RÉELLES ⇒ API_MULTI_EQUIPES (l'outil refuse de trancher)" \
  || ko "virements : verdict '$(verdict virements)'"
[ "$(verdict legacy_API)" = "NOM_HORS_REGEXP" ] \
  && ok "nom hors ^[a-z0-9][a-z0-9-]{1,30}$ ⇒ NOM_HORS_REGEXP" || ko "legacy_API : '$(verdict legacy_API)'"
[ "$(verdict offline-api)" = "CONTRAT_NON_EXTRACTIBLE_API_INACTIVE" ] \
  && ok "isActive false ⇒ CONTRAT_NON_EXTRACTIBLE_API_INACTIVE" || ko "offline-api : '$(verdict offline-api)'"
[ "$(verdict orpheline)" = "API_NON_APPROPRIEE" ] \
  && ok "teams ⊆ profils système ⇒ API_NON_APPROPRIEE" || ko "orpheline : '$(verdict orpheline)'"

# fix round 1 — constat 1 : VERSION_HORS_REGEXP n'avait AUCUNE couverture (le
# relecteur a supprimé toute la branche RE_VER, la suite restait 15/0). "v1" ne
# matche pas ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ; nom et équipe valides par ailleurs —
# seul le défaut de version est en cause, aucun autre verdict ne peut matcher avant.
[ "$(verdict vieille-api)" = "VERSION_HORS_REGEXP" ] \
  && ok "version 'v1' hors ^[0-9]+\\.[0-9]+(\\.[0-9]+)?$ ⇒ VERSION_HORS_REGEXP" \
  || ko "vieille-api : verdict '$(verdict vieille-api)'"

# fix round 1 — constat 2 : rien ne gardait l'ordre de gravité (le relecteur a
# interverti LIGNEE_PARTIELLEMENT_ETRANGERE et CONTRAT_NON_EXTRACTIBLE_API_INACTIVE,
# la suite restait 15/0). gel-fonds combine les DEUX fautes sur sa v1.1.0 : équipe
# Default+Administrators (donc ÉTRANGÈRE — aucune équipe réelle sur cette version)
# ET isActive=false (donc aussi INACTIVE). Le verdict attendu est
# LIGNEE_PARTIELLEMENT_ETRANGERE : cette faute est plus grave, elle prime.
[ "$(verdict gel-fonds)" = "LIGNEE_PARTIELLEMENT_ETRANGERE" ] \
  && ok "v1.1.0 étrangère ET inactive ⇒ LIGNEE_PARTIELLEMENT_ETRANGERE prime sur CONTRAT_NON_EXTRACTIBLE_API_INACTIVE" \
  || ko "gel-fonds : verdict '$(verdict gel-fonds)'"

# LA REGEXP EST LA GARDE DE SEGMENT DE CHEMIN (spec §5.4 n°5) — et en Python
# `re.match(r"…$", "comptes\n")` RÉUSSIT : `$` matche aussi juste avant un
# saut de ligne final. Un nom porteur d'un saut de ligne sortait donc VALIDE,
# alors que `print` le rend sur DEUX lignes et que `read -r` en fait DEUX
# valeurs. `fullmatch` est ce qui rend la classe vraie sur la chaîne entière.
python3 - "$TMP/apis.json" <<'PYNOM' > "$TMP/nomretour.json"
import json,sys
d=json.load(open(sys.argv[1]))
for r in d["apiResponse"]:
    if r["api"]["apiName"] == "comptes": r["api"]["apiName"] = "comptes\n"
json.dump(d,open(sys.stdout.fileno(),"w"))
PYNOM
bash -c '. "'"$LIBE"'" && estate_from_apis "'"$TMP"'/nomretour.json" "'"$TMP"'/l6.json"' 2>/dev/null
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
l=next(x for x in d["lignees"] if x["nom"].startswith("comptes"))
assert l["nom"]=="comptes\n", repr(l["nom"])
assert l["verdict"]=="NOM_HORS_REGEXP", l["verdict"]
' "$TMP/l6.json" \
  && ok "nom porteur d'un saut de ligne FINAL ⇒ NOM_HORS_REGEXP (fullmatch : le \$ ne le tolère plus)" \
  || ko "un nom porteur d'un saut de ligne final est accepté — la classe n'est pas un segment de chemin"

python3 - "$TMP/apis.json" <<'PYVER' > "$TMP/verretour.json"
import json,sys
d=json.load(open(sys.argv[1]))
for r in d["apiResponse"]:
    if r["api"]["apiName"] == "comptes": r["api"]["apiVersion"] = "1.0.0\n"
json.dump(d,open(sys.stdout.fileno(),"w"))
PYVER
bash -c '. "'"$LIBE"'" && estate_from_apis "'"$TMP"'/verretour.json" "'"$TMP"'/l7.json"' 2>/dev/null
[ "$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for l in d["lignees"]:
    if l["nom"]=="comptes": print(l["verdict"]); break
else: print("ABSENTE")' "$TMP/l7.json")" = "VERSION_HORS_REGEXP" ] \
  && ok "version porteuse d'un saut de ligne FINAL ⇒ VERSION_HORS_REGEXP (même défaut de \$, même correctif)" \
  || ko "une version porteuse d'un saut de ligne final est acceptée"

# les teams se lisent au niveau de l'ENTRÉE, jamais dans api (api.teams est null en 10.15)
python3 - "$TMP/apis.json" <<'PY' > "$TMP/nullteams.json"
import json,sys
d=json.load(open(sys.argv[1]))
for r in d["apiResponse"]: r["api"]["teams"]=None
json.dump(d,open(sys.stdout.fileno(),"w"))
PY
bash -c '. "'"$LIBE"'" && estate_from_apis "'"$TMP"'/nullteams.json" "'"$TMP"'/l2.json"' 2>/dev/null
python3 -c '
import json,sys
a=json.load(open(sys.argv[1]))["lignees"]; b=json.load(open(sys.argv[2]))["lignees"]
sys.exit(0 if a==b else 1)' "$TMP/lignees.json" "$TMP/l2.json" \
  && ok "api.teams=null ne change RIEN : les teams sont lues au niveau de l'entrée apiResponse" \
  || ko "la lib lit api.teams — elle sera aveugle sur la 10.15 réelle"

# api.teams=null est un vert VACANT pour la priorité de lecture (api.teams n'y est
# jamais VRAI-mais-faux, donc M1 du brief — inverser l'ordre de la ligne `or` — ne
# rougissait RIEN : api.get("teams") vaut toujours None dans le jeu d'essai, donc
# le repli sur r.get("teams") se déclenchait quel que soit l'ordre. Ici, api.teams
# porte une valeur VRAIE mais TROMPEUSE (une équipe système seule) alors que
# l'entrée porte la vraie équipe ; seule la lecture au niveau ENTRÉE en priorité
# retombe sur OK/toto.
python3 - "$TMP/apis.json" <<'PY' > "$TMP/apiteamsbogus.json"
import json,sys
d=json.load(open(sys.argv[1]))
for r in d["apiResponse"]:
    if r["api"]["apiName"] == "comptes":
        r["api"]["teams"] = [{"id": "u-Administrators", "name": "Administrators"}]
json.dump(d,open(sys.stdout.fileno(),"w"))
PY
bash -c '. "'"$LIBE"'" && estate_from_apis "'"$TMP"'/apiteamsbogus.json" "'"$TMP"'/l4.json"' 2>/dev/null
[ "$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for l in d["lignees"]:
    if l["nom"]=="comptes": print(l["verdict"]); break
else: print("ABSENTE")' "$TMP/l4.json")" = "OK" ] \
  && ok "api.teams TROMPEUR (équipe système seule) ignoré : comptes reste OK/toto via l'entrée" \
  || ko "la lib a suivi api.teams au lieu de l'entrée apiResponse — priorité de lecture inversée"

# isActive="true" (chaîne) est absent du jeu d'essai (toujours un booléen JSON
# réel) : M3 du brief — bool(api.get("isActive")) au lieu de `is True` — ne
# rougissait RIEN non plus, bool(True)==True comme (True is True). Ici la
# valeur est la CHAÎNE "true" : le booléen JSON strict l'exige inactive.
python3 - "$TMP/apis.json" <<'PY' > "$TMP/isactivestring.json"
import json,sys
d=json.load(open(sys.argv[1]))
for r in d["apiResponse"]:
    if r["api"]["apiName"] == "comptes":
        r["api"]["isActive"] = "true"
json.dump(d,open(sys.stdout.fileno(),"w"))
PY
bash -c '. "'"$LIBE"'" && estate_from_apis "'"$TMP"'/isactivestring.json" "'"$TMP"'/l5.json"' 2>/dev/null
[ "$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for l in d["lignees"]:
    if l["nom"]=="comptes": print(l["verdict"]); break
else: print("ABSENTE")' "$TMP/l5.json")" = "CONTRAT_NON_EXTRACTIBLE_API_INACTIVE" ] \
  && ok "isActive=\"true\" (chaîne) ⇒ inactif quand même (booléen JSON strict)" \
  || ko "la lib accepte la chaîne \"true\" comme active — booléen non strict"

# déterminisme : deux rendus identiques octet pour octet
bash -c '. "'"$LIBE"'" && estate_from_apis "'"$TMP"'/apis.json" "'"$TMP"'/l3.json"' 2>/dev/null
cmp -s "$TMP/lignees.json" "$TMP/l3.json" \
  && ok "rendu DÉTERMINISTE (cmp -s) — diff devient l'outil de suivi du parc" \
  || ko "deux rendus du même parc diffèrent"

echo "== 3. garde de troncature : SCAN_PARC_ATTENDU =="
SCAN="$REPO/scripts/scan-parc.sh"
# gouvernance/providers PAR DÉFAUT pour les sections 3 à 5 (Task 7 rend les
# deux OBLIGATOIRES, sans défaut dans scan-parc.sh — cf. GOVERNANCE_REQUISE /
# PLATEFORME_REQUISE) : ce registre par défaut déclare `comptes`, la SEULE
# lignée OK de tout le jeu d'essai, pour que les assertions déjà vertes des
# sections 3 à 5 (contrat comptes, sha256, etc.) restent inchangées SANS
# toucher à leur texte. providers.dev.yml par défaut n'a qu'UN dépôt à UNE
# équipe (aucune ambiguïté), pour ne rien ajouter aux refus des sections
# précédentes. La section 6 (gouvernance) SURCHARGE ces deux knobs.
mkdir -p "$TMP/gov-default" "$TMP/plat-default/ansible"
# classification=VH / exposure=internet (fix round 2, revue Task 7) : PAS
# M/internal — ce couple-là est précisément ce qu'un code faux écrirait « au
# hasard », coïncidant par accident avec une implémentation qui ignorerait le
# registre. VH+internet ne ressemble à aucun défaut plausible dans la
# taxonomie du dépôt (VH/H/M × internal/external/internet).
cat > "$TMP/gov-default/registre.yaml" <<'YML'
apis:
  - owner: toto
    api: comptes
    classification: VH
    exposure: internet
YML
cat > "$TMP/plat-default/ansible/providers.dev.yml" <<'YML'
providers:
  - team: toto
    repo: grp/apis-comptes
YML
scan(){ env ENVIRONMENT=dev ADMIN_VIA=direct APIM_TERMINUS=prod APIM_API_BASE="$BASE" \
  APIM_AUTH_MODE=basic WM_USER=adm WM_PASSWORD=s3cr3t SCAN_OUT="$TMP/out" \
  GOVERNANCE_PATH="$TMP/gov-default/registre.yaml" GC_PLATFORM_DIR="$TMP/plat-default" GIT_SUBDIR=. \
  "$@" bash "$SCAN"; }

rm -rf "$TMP/out"; mkdir -p "$TMP/out"
scan >"$TMP/s1.out" 2>"$TMP/s1.err"
grep -q '^REFUS: SCAN_PARC_ATTENDU_REQUIS' "$TMP/s1.err" \
  && ok "SCAN_PARC_ATTENDU absent ⇒ refus nommé (aucun défaut deviné)" \
  || ko "le scan a tourné sans contre-compte : $(tail -2 "$TMP/s1.err")"
[ ! -f "$TMP/out/estate.dev.json" ] && ok "aucun inventaire écrit sur le chemin de refus" \
  || ko "un estate.dev.json a été écrit malgré le refus"

scan SCAN_PARC_ATTENDU=99:3 >"$TMP/s2.out" 2>"$TMP/s2.err"
grep -q '^REFUS: PARC_POSSIBLEMENT_TRONQUE' "$TMP/s2.err" \
  && ok "contre-compte faux (99 attendues, 10 rendues) ⇒ PARC_POSSIBLEMENT_TRONQUE" \
  || ko "compte divergent accepté : $(tail -2 "$TMP/s2.err")"

# le jeu d'essai porte DIX entrées d'API (APIS ci-dessus) et TROIS applications
# (endpoint /applications du faux wM : app-front en équipe, app-perso en
# propriété individuelle, app-nue rendue SANS enveloppe) — compté à la main,
# cf. rulings-a-porter.md R1.
scan SCAN_PARC_ATTENDU=10:3 >"$TMP/s3.out" 2>"$TMP/s3.err"
[ -f "$TMP/out/estate.dev.json" ] \
  && ok "contre-compte juste ⇒ l'inventaire est écrit" || ko "rien écrit : $(tail -3 "$TMP/s3.err")"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get("schema")==1 and d["provenance"]["env"]=="dev" else 1)' "$TMP/out/estate.dev.json" \
  && ok "estate.dev.json porte schema:1 et sa provenance" || ko "en-tête d'inventaire incorrect"

# fix round 1 (revue Task 7) — dixième vert vacant du chantier : la branche
# `else` d'estate_gouvernance (recopie classification/exposure du registre
# vers la lignée gouvernée) tournait à CHAQUE scan de ce fichier (comptes est
# gouvernée dans la fixture par défaut, section 3) sans qu'AUCUNE assertion
# ne lise ce qu'elle produit. Mutation du relecteur : remplacer les deux
# valeurs par "BOGUS" dans estate_gouvernance laissait la suite
# intégralement verte. classification/exposure SONT la posture que la chaîne
# aval oppose — une valeur fausse recopiée en silence produirait un dépôt
# qui déclare une posture qu'il n'a pas.
#
# fix round 2 (re-revue) : PRÉSENCE ET VALEUR ne suffisent pas à prouver la
# PROVENANCE — une assertion qui écrit "M"/"internal" en dur serait satisfaite
# aussi bien par le code correct QUE par une mutation qui code ces deux
# valeurs en dur dans estate_gouvernance (essai B du re-relecteur, suite
# restée 51/0). L'assertion lit donc DÉSORMAIS le registre lui-même
# ($TMP/gov-default/registre.yaml) et compare l'inventaire À CES valeurs —
# jamais des littéraux recopiés ici. Un code qui ignore le registre (ou qui
# code une valeur en dur) diverge dès que la fixture change, il ne peut plus
# coïncider par accident.
python3 -c '
import json,sys,yaml
reg = yaml.safe_load(open(sys.argv[2]))
attendu = next(e for e in (reg.get("apis") or []) if e.get("api")=="comptes")
d=json.load(open(sys.argv[1]))
for l in d["lignees"]:
    if l["nom"]=="comptes":
        assert l["classification"]==attendu["classification"], (l.get("classification"), attendu["classification"])
        assert l["exposure"]==attendu["exposure"], (l.get("exposure"), attendu["exposure"])
        break
else:
    sys.exit("comptes absente de l'\''inventaire")
' "$TMP/out/estate.dev.json" "$TMP/gov-default/registre.yaml" \
  && ok "comptes gouvernée porte EXACTEMENT classification/exposure du registre (dérivées, pas en dur)" \
  || ko "classification/exposure divergent du registre — présence/valeur ne suffit pas, la provenance a manqué"
# les CINQ canaris de identifiers (token/openIdClaims/httpsCertificate/clé
# inconnue — tous masqués — PLUS ipAddressRange, qui elle DOIT apparaître :
# ce n'est pas un secret) et le canari accessTokens (jamais lu nulle part).
grep -qE 'CANARI-(TOKEN|CLAIMS|CERT|CLE-INCONNUE|ACCESSTOKENS|TOKEN-USER|TOKEN-NU)-NE-DOIT' "$TMP/out/estate.dev.json" \
  && ko "FUITE : la valeur d'un identifiant (ou accessTokens) est dans l'inventaire" \
  || ok "aucune valeur d'identifiant masqué dans l'inventaire (défaut-deny)"
grep -q '10.42.0.1-10.42.0.1' "$TMP/out/estate.dev.json" \
  && ok "ipAddressRange, seule valeur non masquée, EST dans l'inventaire (ce n'est pas un secret)" \
  || ko "ipAddressRange a disparu — le défaut-deny masque trop"
grep -q 'accessTokens' "$TMP/out/estate.dev.json" \
  && ko "FUITE DE STRUCTURE : le mot accessTokens apparaît dans l'inventaire — il ne doit JAMAIS être lu" \
  || ok "accessTokens n'apparaît nulle part dans l'inventaire (jamais lu)"

echo "== 4. applications, contrats, rapport =="
# un fichier ÉTRANGER (pas produit par le scan) dans contrats/ : refus nommé,
# fichier INTACT, rien écrit. Preuve directe du constat 1 (fix round 1) —
# SCAN_OUT n'est validé QUE non-vide ; un SCAN_OUT=. avec un fichier
# personnel dans contrats/ était détruit en silence par l'ancien `rm -rf`.
rm -rf "$TMP/out"; mkdir -p "$TMP/out/contrats"
echo "des notes personnelles, pas un contrat" > "$TMP/out/contrats/mon-fichier-perso.txt"
scan SCAN_PARC_ATTENDU=10:3 >"$TMP/s4pre.out" 2>"$TMP/s4pre.err"
grep -q '^REFUS: CONTRATS_DIR_ETRANGER' "$TMP/s4pre.err" \
  && ok "un fichier étranger dans contrats/ ⇒ refus nommé" \
  || ko "aucun refus CONTRATS_DIR_ETRANGER : $(tail -3 "$TMP/s4pre.err")"
[ -f "$TMP/out/contrats/mon-fichier-perso.txt" ] \
  && ok "le fichier étranger est INTACT (rien détruit)" \
  || ko "DESTRUCTION : le fichier étranger a disparu"
[ ! -f "$TMP/out/estate.dev.json" ] \
  && ok "aucun inventaire écrit à cause du fichier étranger" \
  || ko "un estate.dev.json a été écrit malgré le refus"

# comptes, pas paiements : cf. rulings-a-porter.md R1. paiements est
# LIGNEE_PARTIELLEMENT_ETRANGERE (v1.0.1 en Default) — elle ne produit AUCUN
# contrat, c'est correct ; comptes est la seule lignée OK du jeu d'essai.
rm -rf "$TMP/out"; scan SCAN_PARC_ATTENDU=10:3 >/dev/null 2>&1
python3 -c '
import json,sys
# PAR NOM, jamais par position : le jeu d'\''essai porte trois applications
# désormais, et un index nu se serait tu en désignant la mauvaise.
a=next(x for x in json.load(open(sys.argv[1]))["applications"] if x["nom"]=="app-front")
ids={i["type"]: i for i in a["identifiants"]}
assert a["ownerType"]=="team" and a["owner"]=="toto", a
# vocabulaire RÉEL : token/openIdClaims/httpsCertificate masqués (allowlist
# GARDE_VALEUR = {ipAddressRange} seule) ; une clé JAMAIS PRÉVUE par aucun
# rôle du dépôt (coupon-fidelite) doit AUSSI être masquée — cest la preuve du
# défaut-deny (constat 2, fix round 1) : sans ce cas, une inversion de garde
# ne rougirait rien.
for k in ("token", "openIdClaims", "httpsCertificate", "coupon-fidelite"):
    assert ids[k]["valeur"]=="NON_TRANSPORTEE", (k, ids[k])
assert ids["ipAddressRange"]["valeurs"]==["10.42.0.1-10.42.0.1"], ids
assert "accessTokens" not in a, "accessTokens recopié dans l'\''application rendue"
' "$TMP/out/estate.dev.json" \
  && ok "application : owner/ownerType lus, tout masqué SAUF ipAddressRange, clé inconnue masquée aussi (défaut-deny)" \
  || ko "forme de l'application incorrecte"

# ── ownerType=user : la situation n°7 de la spec §5.4, codée SANS jeu d'essai
# jusqu'à cette vague. Mesuré par le relecteur : supprimer le verdict
# APP_PROPRIETE_INDIVIDUELLE (estate.sh) *ou* le masque
# CLE_MASQUEE_PROPRIETAIRE_UTILISATEUR laissait la suite intégralement verte.
# Les deux constantes ont maintenant chacune leur épreuve.
python3 -c '
import json,sys
a=next(x for x in json.load(open(sys.argv[1]))["applications"] if x["nom"]=="app-perso")
assert a["ownerType"]=="user", a
assert a["verdict"]=="APP_PROPRIETE_INDIVIDUELLE", a
' "$TMP/out/estate.dev.json" \
  && ok "application ownerType=user ⇒ verdict APP_PROPRIETE_INDIVIDUELLE (situation n°7, §5.4)" \
  || ko "une application en propriété individuelle ne porte pas son verdict"
python3 -c '
import json,sys
a=next(x for x in json.load(open(sys.argv[1]))["applications"] if x["nom"]=="app-perso")
ids={i["type"]: i for i in a["identifiants"]}
assert ids["token"]["valeur"]=="CLE_MASQUEE_PROPRIETAIRE_UTILISATEUR", ids
' "$TMP/out/estate.dev.json" \
  && ok "le masque d'un identifiant d'app ownerType=user est CLE_MASQUEE_PROPRIETAIRE_UTILISATEUR, pas NON_TRANSPORTEE" \
  || ko "le masque propre au propriétaire utilisateur n'est pas employé"

# ── S3 : enveloppe ABSENTE (§5.3, « les enveloppes sont incohérentes »). Le
# repli `or [{}]` d'estate.sh rendait alors ownerType="" et identifiants=[] :
# l'application ressortait {"verdict":"OK"} — DÉCLARÉE CONFORME alors qu'elle
# est en propriété individuelle. Le dépôt écrit huit fois la forme correcte
# (`| default([json]) | first`) ; la lib neuve divergeait vers un fail-open.
python3 -c '
import json,sys
a=next(x for x in json.load(open(sys.argv[1]))["applications"] if x["nom"]=="app-nue")
assert a["ownerType"]=="user", a          # lu MALGRÉ l'\''enveloppe absente
assert a["verdict"]=="APP_PROPRIETE_INDIVIDUELLE", a
ids={i["type"]: i for i in a["identifiants"]}
assert ids["token"]["valeur"]=="CLE_MASQUEE_PROPRIETAIRE_UTILISATEUR", ids
' "$TMP/out/estate.dev.json" \
  && ok "détail rendu SANS enveloppe : ownerType/identifiants lus quand même (repli sur l'objet, pas sur {})" \
  || ko "FAIL-OPEN : une app ownerType=user rendue sans enveloppe ressort conforme"

# le rapport nomme aussi les refus d'APPLICATION, avec leur geste
grep -q 'APP_PROPRIETE_INDIVIDUELLE' "$TMP/out/rapport.md" \
  && grep -q 'POST /assets/owner' "$TMP/out/rapport.md" \
  && ok "rapport.md nomme le refus d'application ET son geste (POST /assets/owner)" \
  || ko "rapport.md ne relaie pas les refus d'application"

[ -f "$TMP/out/contrats/comptes-1.0.0.openapi.yaml" ] \
  && ok "contrat extrait d'apiDefinition pour une lignée OK" || ko "contrat manquant"
[ ! -f "$TMP/out/contrats/offline-api-1.0.0.openapi.yaml" ] \
  && ok "aucun contrat pour une API INACTIVE (verdict non-OK ⇒ rien n'est produit)" \
  || ko "un contrat a été extrait pour une API inactive"
python3 -c '
import hashlib,json,sys
d=json.load(open(sys.argv[1]))
vu=False
for l in d["lignees"]:
    if l["nom"]!="comptes": continue
    for v in l["versions"]:
        c=v.get("contrat")
        # PAS un "if c:" — un contrat tu (bloc absent, silencieusement) doit
        # rougir ici, pas passer inaperçu (vert vacant mesuré : le brief le
        # laissait passer, cf. rulings-a-porter.md R13).
        assert c, "bloc contrat absent pour comptes@%s" % v["version"]
        h=hashlib.sha256(open(sys.argv[2]+"/"+c["fichier"].split("/")[-1],"rb").read()).hexdigest()
        assert h==c["sha256"], (h,c)
        vu=True
assert vu, "lignée comptes absente de l'\''inventaire"
' "$TMP/out/estate.dev.json" "$TMP/out/contrats" 2>/dev/null \
  && ok "sha256 du contrat vérifiable depuis l'inventaire" || ko "sha256 absent ou faux"

grep -q 'API_MULTI_EQUIPES' "$TMP/out/rapport.md" && grep -q 'assign-api-team.sh' "$TMP/out/rapport.md" \
  && ok "rapport.md nomme les refus ET le geste proposé" || ko "rapport.md incomplet"

echo "== 5. fail-closed : CONTRAT_ABSENT (apiDefinition disparue) ne laisse rien =="
# comptes est la seule lignée OK : sa forcer apiDefinition à disparaître côté
# gateway doit faire refuser CONTRAT_ABSENT, SANS ÉCRIRE d'estate.dev.json.
# C'est la preuve directe de la classe de bug du sous-shell (fix round 1,
# constat 3) : `python3 ... | while read` avale le `exit 1` de `refus()`
# sur bash 3.2 (pas de lastpipe) — le mutant ci-dessous le remet en place.
rm -rf "$TMP/out"
: > "$TMP/fail-apidef.flag"
scan SCAN_PARC_ATTENDU=10:3 >"$TMP/s5.out" 2>"$TMP/s5.err"
RC5=$?
rm -f "$TMP/fail-apidef.flag"
[ "$RC5" -ne 0 ] && ok "CONTRAT_ABSENT ⇒ le scan sort en échec (rc=${RC5})" \
  || ko "le scan a réussi malgré une apiDefinition absente (rc=0)"
grep -q '^REFUS: CONTRAT_ABSENT' "$TMP/s5.err" \
  && ok "le refus CONTRAT_ABSENT est nommé sur stderr" \
  || ko "aucun refus CONTRAT_ABSENT : $(tail -3 "$TMP/s5.err")"
[ ! -f "$TMP/out/estate.dev.json" ] \
  && ok "aucun estate.dev.json écrit malgré le refus survenu en cours de boucle" \
  || ko "un estate.dev.json a été écrit malgré CONTRAT_ABSENT (fail-open)"

echo "== 6. gouvernance, providers, sonde archive =="
# R2 (rulings-a-porter.md) : le brief visait `virements` pour prouver qu'une
# lignée non gouvernée ne produit pas de contrat — mais virements est déjà
# refusée API_MULTI_EQUIPES : l'assertion serait verte MÊME SANS la porte de
# gouvernance (vert vacant). Le registre ci-dessous ne déclare donc QUE
# `paiements` (déjà refusée par ailleurs elle aussi) — jamais `comptes`,
# l'UNIQUE lignée OK du jeu d'essai (cf. section 3, registre par défaut) :
# c'est SA bascule OK → CLASSIFICATION_UNGOVERNED qui prouve la porte.
mkdir -p "$TMP/gov" "$TMP/plat/ansible"
cat > "$TMP/gov/registre.yaml" <<'YML'
apis:
  - owner: toto
    api: paiements
    classification: M
    exposure: internal
YML
# deux équipes déclarant le MÊME dépôt (grp/apis-toto) — PLUS un dépôt à
# équipe UNIQUE (grp/apis-legit, R13) : sans ce second dépôt, la mutation M3
# du brief (retirer le filtre `len(set(ts)) > 1` dans estate_repo_ambigu) ne
# rougirait RIEN — un jeu d'essai qui ne contient QUE des dépôts ambigus ne
# peut pas distinguer « le filtre écarte les dépôts non-ambigus » de
# « le filtre n'existe pas ». grp/apis-legit doit rester ABSENTE des refus.
cat > "$TMP/plat/ansible/providers.dev.yml" <<'YML'
providers:
  - team: toto
    repo: grp/apis-toto
  - team: titi
    repo: grp/apis-toto
  - team: toto
    repo: grp/apis-legit
YML
rm -rf "$TMP/out"
scan SCAN_PARC_ATTENDU=10:3 GC_PLATFORM_DIR="$TMP/plat" GOVERNANCE_PATH="$TMP/gov/registre.yaml" \
     >"$TMP/s6.out" 2>"$TMP/s6.err"

python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
codes={r["code"] for r in d["refus"]}
assert "CLASSIFICATION_UNGOVERNED" in codes, codes
assert "REPO_AMBIGU" in codes, codes
' "$TMP/out/estate.dev.json" \
  && ok "CLASSIFICATION_UNGOVERNED et REPO_AMBIGU sont inscrits aux refus" \
  || ko "verdicts manquants dans estate.dev.json"

python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for l in d["lignees"]:
    if l["nom"]=="comptes":
        assert l["verdict"]=="CLASSIFICATION_UNGOVERNED", l["verdict"]
        break
else:
    sys.exit("comptes absente de l'\''inventaire")
' "$TMP/out/estate.dev.json" \
  && ok "comptes (OK hors gouvernance) bascule CLASSIFICATION_UNGOVERNED — absente du registre (R2)" \
  || ko "comptes n'a pas basculé CLASSIFICATION_UNGOVERNED"

# moitié négative (fix round 1) : une lignée NON gouvernée ne porte NI
# classification NI exposure — la branche `if e is None` d'estate_gouvernance
# ne les écrit jamais, elle ne fait basculer que le verdict.
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for l in d["lignees"]:
    if l["nom"]=="comptes":
        assert "classification" not in l, l
        assert "exposure" not in l, l
        break
else:
    sys.exit("comptes absente de l'\''inventaire")
' "$TMP/out/estate.dev.json" \
  && ok "comptes NON gouvernée ne porte NI classification NI exposure" \
  || ko "classification/exposure présentes sur une lignée non gouvernée"

[ ! -f "$TMP/out/contrats/comptes-1.0.0.openapi.yaml" ] \
  && ok "une lignée OK mais NON GOUVERNÉE ne produit PAS de contrat (R2)" \
  || ko "un contrat a été produit pour comptes, pourtant hors registre"

# V4 — un champ de provenance ne doit pas MENTIR. Dans ce scan-ci, comptes est
# CLASSIFICATION_UNGOVERNED : AUCUNE lignée n'est OK, FIRST_GUID est vide, la
# sonde /archive n'est JAMAIS invoquée. Le champ valait pourtant "KO" — la
# valeur initiale jamais changée, une absence de mesure présentée comme un
# échec mesuré. Il vaut désormais NON_MESURE.
python3 -c '
import json,sys
v=json.load(open(sys.argv[1]))["provenance"]["sondes"]["archive_zip"]
assert v=="NON_MESURE", v' "$TMP/out/estate.dev.json" \
  && ok "sonde /archive JAMAIS invoquée (aucune lignée OK) ⇒ archive_zip=NON_MESURE, pas KO" \
  || ko "archive_zip présente une absence de mesure comme un échec mesuré"

# REPO_AMBIGU discrimine réellement le filtre len(set(ts))>1 (mutation M3
# corrigée, cf. task-7-report.md) : SEUL grp/apis-toto (2 équipes) est
# rapporté, jamais grp/apis-legit (1 équipe).
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
r=[x for x in d["refus"] if x["code"]=="REPO_AMBIGU"]
objets=sorted(x["objet"] for x in r)
assert objets==["grp/apis-toto"], objets
detail=next(x["detail"] for x in r if x["objet"]=="grp/apis-toto")
assert "titi" in detail and "toto" in detail, detail
' "$TMP/out/estate.dev.json" \
  && ok "REPO_AMBIGU cible SEULEMENT grp/apis-toto (2 équipes), jamais grp/apis-legit (1 équipe)" \
  || ko "REPO_AMBIGU sur-désigne ou sous-désigne les dépôts déclarés"

# La sonde archive n'a de sens QUE s'il existe au moins une lignée OK pour
# lui fournir un GUID (cf. FIRST_GUID, scan-parc.sh) — or dans le scan R2
# ci-dessus, comptes est CLASSIFICATION_UNGOVERNED : PLUS AUCUNE lignée n'y
# est OK, la sonde n'y est donc JAMAIS invoquée, et lire archive_zip depuis
# "$TMP/out/estate.dev.json" (le résultat du scan R2) y verrait un "KO" qui
# ne mesure RIEN — juste la valeur initiale jamais changée (vert vacant : une
# mutation qui casserait la sonde ne rougirait rien depuis CE fichier-là).
# D'où un scan SÉPARÉ, avec la gouvernance PAR DÉFAUT (comptes reste OK,
# cf. section 3) pour que FIRST_GUID soit non-vide et la sonde réellement
# exercée.
rm -rf "$TMP/out"
scan SCAN_PARC_ATTENDU=10:3 >"$TMP/s6a.out" 2>"$TMP/s6a.err"
python3 -c '
import json,sys
v=json.load(open(sys.argv[1]))["provenance"]["sondes"]["archive_zip"]
assert v in ("OK","KO"), v' "$TMP/out/estate.dev.json" \
  && ok "provenance.sondes.archive_zip porte une MESURE (OK|KO), pas NON_MESURE en dur" \
  || ko "archive_zip n'est pas mesuré"

# la mesure discrimine réellement (R13) : un 200 SANS l'octet magique zip
# (le faux wM rend du JSON sur /archive par défaut) doit rester KO — un
# simple code 200 ne suffit pas à prouver un export. Lu du MÊME scan
# ci-dessus (comptes OK ⇒ FIRST_GUID non-vide ⇒ la sonde a réellement tourné).
python3 -c '
import json,sys
v=json.load(open(sys.argv[1]))["provenance"]["sondes"]["archive_zip"]
assert v=="KO", v' "$TMP/out/estate.dev.json" \
  && ok "200 sans octet magique PK (JSON) ⇒ archive_zip=KO, pas un vert de complaisance" \
  || ko "archive_zip=OK sur un corps qui n'est PAS un zip"

# et l'inverse : un VRAI octet magique zip (PK\x03\x04) ⇒ OK — sans ce
# second cas, une sonde qui rendrait KO EN DUR passerait l'assertion
# précédente sans jamais avoir rien mesuré (R13).
: > "$TMP/archive-real-zip.flag"
rm -rf "$TMP/out"
scan SCAN_PARC_ATTENDU=10:3 >"$TMP/s6b.out" 2>"$TMP/s6b.err"
rm -f "$TMP/archive-real-zip.flag"
python3 -c '
import json,sys
v=json.load(open(sys.argv[1]))["provenance"]["sondes"]["archive_zip"]
assert v=="OK", v' "$TMP/out/estate.dev.json" \
  && ok "200 AVEC l'octet magique PK\\x03\\x04 ⇒ archive_zip=OK" \
  || ko "archive_zip reste KO malgré un vrai zip — la sonde ne mesure rien"

echo "== 6a-bis. provenance : les champs disent ce qui a été MESURÉ =="
# `preflight` était le littéral "OK". Il mentait deux fois : il annonçait une
# réussite sans jamais dire QUEL code avait été observé, et il l'annonçait
# AUSSI quand APIM_PREFLIGHT=off, c'est-à-dire quand la sonde n'avait pas
# tourné du tout. Le faux wM rend 401 sans jeton (la preuve de vie du proxy) :
# c'est CE code que la provenance doit porter.
rm -rf "$TMP/out"
scan SCAN_PARC_ATTENDU=10:3 >"$TMP/s6pf.out" 2>"$TMP/s6pf.err"
python3 -c '
import json,sys
v=json.load(open(sys.argv[1]))["provenance"]["sondes"]["preflight"]
assert v=="401", v' "$TMP/out/estate.dev.json" \
  && ok "provenance.sondes.preflight porte le CODE RÉELLEMENT OBSERVÉ (401 sans jeton), pas un \"OK\" en dur" \
  || ko "preflight n'est pas le code observé : $(python3 -c '''import json,sys;print(json.load(open(sys.argv[1]))["provenance"]["sondes"]["preflight"])''' "$TMP/out/estate.dev.json" 2>/dev/null)"

rm -rf "$TMP/out"
scan SCAN_PARC_ATTENDU=10:3 APIM_PREFLIGHT=off >"$TMP/s6pg.out" 2>"$TMP/s6pg.err"
python3 -c '
import json,sys
v=json.load(open(sys.argv[1]))["provenance"]["sondes"]["preflight"]
assert v=="DESACTIVE", v' "$TMP/out/estate.dev.json" \
  && ok "APIM_PREFLIGHT=off ⇒ preflight=DESACTIVE (la sonde n'a pas tourné, le champ le dit)" \
  || ko "preflight annonce une mesure alors que la sonde était désactivée"

# S2(a), côté FICHIER : l'expurgation de provenance.base est la MÊME fonction
# que celle du message de refus (wm_redact_url). Sans cette épreuve, seul le
# message était gardé et le fichier ne l'était par rien.
rm -rf "$TMP/out"
scan SCAN_PARC_ATTENDU=10:3 APIM_API_BASE="http://svc-scan:M0tDeP4sseDuFICHIER@127.0.0.1:$PORT" \
  >"$TMP/s6ph.out" 2>"$TMP/s6ph.err"
grep -q 'M0tDeP4sseDuFICHIER' "$TMP/out/estate.dev.json" \
  && ko "FUITE : provenance.base porte l'userinfo de la base d'admin dans l'inventaire" \
  || ok "provenance.base est expurgée dans l'inventaire (même fonction que le message)"
python3 -c '
import json,sys
b=json.load(open(sys.argv[1]))["provenance"]["base"]
assert "<identifiants masqués>" in b, b' "$TMP/out/estate.dev.json" \
  && ok "provenance.base montre bien la base, userinfo remplacé par <identifiants masqués>" \
  || ko "provenance.base n'affiche plus la base du tout"

echo "== 6b. GOVERNANCE_PATH et GC_PLATFORM_DIR : aucun défaut ne devine =="
rm -rf "$TMP/out"
scan SCAN_PARC_ATTENDU=10:3 GOVERNANCE_PATH= >"$TMP/s6c.out" 2>"$TMP/s6c.err"
grep -q '^REFUS: GOUVERNANCE_REQUISE' "$TMP/s6c.err" \
  && ok "GOVERNANCE_PATH absent ⇒ GOUVERNANCE_REQUISE (aucun défaut, aucun optimisme)" \
  || ko "le scan a tourné sans registre : $(tail -3 "$TMP/s6c.err")"
[ ! -f "$TMP/out/estate.dev.json" ] \
  && ok "aucun inventaire écrit sur le chemin GOUVERNANCE_REQUISE" \
  || ko "un estate.dev.json a été écrit malgré GOUVERNANCE_REQUISE"

rm -rf "$TMP/out"
scan SCAN_PARC_ATTENDU=10:3 GC_PLATFORM_DIR= >"$TMP/s6d.out" 2>"$TMP/s6d.err"
grep -q '^REFUS: PLATEFORME_REQUISE' "$TMP/s6d.err" \
  && ok "GC_PLATFORM_DIR absent ⇒ PLATEFORME_REQUISE (aucun défaut, aucun optimisme)" \
  || ko "le scan a tourné sans dépôt plateforme : $(tail -3 "$TMP/s6d.err")"
[ ! -f "$TMP/out/estate.dev.json" ] \
  && ok "aucun inventaire écrit sur le chemin PLATEFORME_REQUISE" \
  || ko "un estate.dev.json a été écrit malgré PLATEFORME_REQUISE"

echo "== 6c. contrats/ : suppression par PROVENANCE, jamais par motif de nom (correctif Task 6) =="
# AVANT ce correctif, le commentaire de scan-parc.sh affirmait « on ne
# supprime QUE ce que CE script écrit lui-même » — mais le motif de
# suppression était un NOM DE FICHIER (*.openapi.yaml), pas une preuve de
# provenance. Un fichier PERSONNEL nommé comme un contrat passe la garde
# CONTRATS_DIR_ETRANGER (qui ne flaire que le SUFFIXE) puis était détruit en
# silence par le `rm -f *.openapi.yaml` qui suivait (mesuré, revue Task 6).
rm -rf "$TMP/out"; mkdir -p "$TMP/out/contrats"
printf 'CANARI-CONTRAT-ETRANGER-NE-DOIT-PAS-DISPARAITRE\n' > "$TMP/out/contrats/notes-perso.openapi.yaml"
scan SCAN_PARC_ATTENDU=10:3 >"$TMP/s6e.out" 2>"$TMP/s6e.err"
grep -q 'CANARI-CONTRAT-ETRANGER-NE-DOIT-PAS-DISPARAITRE' "$TMP/out/contrats/notes-perso.openapi.yaml" 2>/dev/null \
  && ok "un *.openapi.yaml ÉTRANGER (nommé comme un contrat, jamais écrit par ce scan) survit intact" \
  || ko "DESTRUCTION : le fichier étranger *.openapi.yaml a disparu ou a été altéré"
[ -f "$TMP/out/contrats/comptes-1.0.0.openapi.yaml" ] \
  && ok "le VRAI contrat de la lignée OK est bien (ré)écrit à côté du fichier étranger" \
  || ko "le contrat légitime n'a pas été produit malgré le fichier étranger"

echo "== 7. LE PARC EST UN ATTAQUANT : les données de la gateway composent des chemins =="
# Les deux revues précédentes ont cherché l'attaquant du côté de SCAN_OUT.
# Il vient d'AILLEURS : apiName, apiVersion et les identifiants rendus par la
# gateway composent tous un chemin de fichier. Mesuré sur le script AVANT
# correctif, chaque fois avec rc=0 et « inventaire écrit » — donc en silence.
# Un faux wM SÉPARÉ sert ici le parc hostile, pour ne rien changer aux comptes
# du jeu d'essai des sections 1 à 6.
cat > "$TMP/fakewm-hostile.py" <<'PYH'
import json, os
from http.server import BaseHTTPRequestHandler, HTTPServer
NOM, VER, APPID = os.environ["EVIL_NAME"], os.environ["EVIL_VER"], os.environ["EVIL_APPID"]
def env():
    return {"api": {"id": "g-evil-1", "apiName": NOM, "apiVersion": VER, "isActive": True},
            "responseStatus": "SUCCESS", "teams": [{"id": "u-toto", "name": "toto"}]}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj=None):
        b = json.dumps(obj if obj is not None else {}).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        p = self.path.split("?")[0]
        if not self.headers.get("Authorization"): return self._send(401, {"e": "no token"})
        if p.endswith("/apis"): return self._send(200, {"apiResponse": [env()]})
        if "/apis/" in p:
            e = env(); e["api"]["apiDefinition"] = {"openapi": "3.0.1"}
            return self._send(200, {"apiResponse": e})
        if p.endswith("/applications"): return self._send(200, {"applications": [{"id": APPID, "name": "app-x"}]})
        if "/applications/" in p:
            return self._send(200, {"applications": [{"id": APPID, "name": "app-x",
                                                      "owner": "toto", "ownerType": "team", "identifiers": []}]})
        return self._send(404)
HTTPServer(("127.0.0.1", int(os.environ["PORT2"])), H).serve_forever()
PYH
mkdir -p "$TMP/evil/gov" "$TMP/evil/plat/ansible"
printf 'apis: []\n'      > "$TMP/evil/gov/registre.yaml"
printf 'providers: []\n' > "$TMP/evil/plat/ansible/providers.dev.yml"
PORT2="${FAKE_WM_HOSTILE_PORT:-$((PORT + 1))}"

# scan_hostile <nom> <version> <id d'application> — relance un faux wM avec CE
# parc-là, puis scanne. Sortie : $TMP/evil/out, journal $TMP/evil/scan.err.
scan_hostile(){
  EVIL_NAME="$1" EVIL_VER="$2" EVIL_APPID="$3" PORT2="$PORT2" python3 "$TMP/fakewm-hostile.py" & HPID=$!
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT2/apis" && break; sleep 0.1; done
  rm -rf "$TMP/evil/out"; mkdir -p "$TMP/evil/out/contrats"
  printf 'CANARI-PRECIEUX-NE-DOIT-PAS-DISPARAITRE\n' > "$TMP/evil/PRECIEUX-1.0.0.openapi.yaml"
  printf 'CANARI-VICTIME-NE-DOIT-PAS-DISPARAITRE\n'  > "$TMP/evil/VICTIME"
  printf 'CANARI-APPID-NE-DOIT-PAS-ETRE-ECRASE\n'    > "$TMP/evil/CIBLE-APPID.json"
  env ENVIRONMENT=dev ADMIN_VIA=direct APIM_TERMINUS=prod APIM_API_BASE="http://127.0.0.1:$PORT2" \
      APIM_AUTH_MODE=basic WM_USER=adm WM_PASSWORD=s3cr3t SCAN_OUT="$TMP/evil/out" \
      GOVERNANCE_PATH="$TMP/evil/gov/registre.yaml" GC_PLATFORM_DIR="$TMP/evil/plat" GIT_SUBDIR=. \
      SCAN_PARC_ATTENDU=1:1 bash "$SCAN" >"$TMP/evil/scan.out" 2>"$TMP/evil/scan.err"
  EVILRC=$?
  kill "$HPID" 2>/dev/null; wait "$HPID" 2>/dev/null
}

# 7a. apiName = '../../PRECIEUX' — le contrat visé est HORS de SCAN_OUT.
# Mesuré avant correctif : $SCAN_OUT/contrats/../../PRECIEUX-1.0.0.openapi.yaml
# SUPPRIMÉ, scan rc=0, « inventaire écrit », aucun refus. Le verdict de la
# lignée était pourtant NOM_HORS_REGEXP : l'outil NOMMAIT la faute ET la
# COMMETTAIT. La regexp gardait le verdict, jamais le chemin.
scan_hostile '../../PRECIEUX' '1.0.0' 'app-x'
grep -q 'CANARI-PRECIEUX-NE-DOIT-PAS-DISPARAITRE' "$TMP/evil/PRECIEUX-1.0.0.openapi.yaml" 2>/dev/null \
  && ok "apiName='../../PRECIEUX' : le fichier visé HORS de SCAN_OUT survit intact" \
  || ko "DESTRUCTION : un apiName en '../..' a fait effacer un fichier hors de SCAN_OUT"
# et le run n'est PAS interrompu (spec §5.4 : aucune des huit situations
# n'interrompt le scan) — l'outil existe pour inventorier un parc mal nommé.
[ "$EVILRC" = 0 ] && [ -f "$TMP/evil/out/estate.dev.json" ] \
  && ok "le scan n'est PAS interrompu par un nom hors classe (§5.4) : rc=0, inventaire écrit" \
  || ko "le scan a été interrompu par un nom hors classe (rc=${EVILRC})"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert [l["verdict"] for l in d["lignees"]]==["NOM_HORS_REGEXP"], d["lignees"]
' "$TMP/evil/out/estate.dev.json" \
  && ok "la lignée hostile est NOMMÉE NOM_HORS_REGEXP dans l'inventaire (nommer sans commettre)" \
  || ko "la lignée hostile n'est pas rapportée"
grep -q 'CONTRAT_NOM_HORS_SEGMENT' "$TMP/evil/scan.err" \
  && ok "l'écart est DIT sur stderr (CONTRAT_NOM_HORS_SEGMENT), il n'est pas passé sous silence" \
  || ko "le nom écarté de la suppression ne laisse aucune trace : $(tail -3 "$TMP/evil/scan.err")"

# 7b. apiVersion = $'1.0.0\n../../VICTIME\n' — le `print` rend TROIS lignes,
# `read -r` les consomme une par une, la deuxième est '../../VICTIME' NUE :
# la contrainte de suffixe .openapi.yaml, seule garde restante, TOMBE.
# Mesuré avant correctif : fichier arbitraire supprimé, rc=0.
# $'…' et NON "$(printf …)" : la substitution de commande MANGE le saut de
# ligne FINAL, et c'est précisément lui qui détache '../../VICTIME' du suffixe
# '.openapi.yaml'. Avec le suffixe recollé, l'épreuve restait verte même sur
# le code d'AVANT correctif (mesuré : mutation M1b, 76/0) — un canari qui ne
# porte pas exactement le caractère qui casse la règle ne garde rien.
scan_hostile 'precieuse' $'1.0.0\n../../VICTIME\n' 'app-x'
grep -q 'CANARI-VICTIME-NE-DOIT-PAS-DISPARAITRE' "$TMP/evil/VICTIME" 2>/dev/null \
  && ok "apiVersion multiligne : le fichier NU visé (sans suffixe .openapi.yaml) survit intact" \
  || ko "DESTRUCTION : une version multiligne a fait effacer un fichier arbitraire"
[ "$EVILRC" = 0 ] && [ -f "$TMP/evil/out/estate.dev.json" ] \
  && ok "le scan n'est PAS interrompu par une version hors classe (§5.4) : rc=0, inventaire écrit" \
  || ko "le scan a été interrompu par une version hors classe (rc=${EVILRC})"

# 7c. LE TROISIÈME CÔTÉ. Ni SCAN_OUT, ni la boucle de suppression : le
# répertoire de TRAVAIL de l'outil. `curl -o "$WORK/appdet/<id>.json"` compose
# son chemin avec l'`id` d'application rendu par la gateway. Mesuré avant
# correctif : un id en '../..' fait ÉCRASER un fichier arbitraire HORS de
# SCAN_OUT — et le scan sort rc=0 en annonçant « inventaire écrit ».
# Les '../' en excès se replient sur '/' : la cible est atteinte quelle que
# soit la profondeur de $WORK (mktemp -d n'honore pas TMPDIR sur BSD).
scan_hostile 'precieuse' '1.0.0' "../../../../../../../../../../../..${TMP}/evil/CIBLE-APPID"
grep -q 'CANARI-APPID-NE-DOIT-PAS-ETRE-ECRASE' "$TMP/evil/CIBLE-APPID.json" 2>/dev/null \
  && ok "application.id en '../..' : le fichier visé HORS de SCAN_OUT n'est pas écrasé" \
  || ko "ÉCRASEMENT : un id d'application a fait écrire curl hors de SCAN_OUT :: $(head -c 120 "$TMP/evil/CIBLE-APPID.json")"
grep -q '^REFUS: IDENTIFIANT_HORS_SEGMENT' "$TMP/evil/scan.err" \
  && ok "un id d'application hors segment ⇒ refus nommé IDENTIFIANT_HORS_SEGMENT" \
  || ko "aucun refus sur un id d'application hors segment : $(tail -3 "$TMP/evil/scan.err")"
[ ! -f "$TMP/evil/out/estate.dev.json" ] \
  && ok "aucun inventaire écrit sur le chemin IDENTIFIANT_HORS_SEGMENT (fail-closed)" \
  || ko "un estate.dev.json a été écrit malgré IDENTIFIANT_HORS_SEGMENT"

printf '\n%d ✅  %d ❌\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
