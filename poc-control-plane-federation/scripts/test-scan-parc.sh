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
            return self._send(200, {"applications": [{"id": "app-1", "name": "app-front"}]})
        if "/applications/" in p:
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
B64="$(printf '%s:%s' adm s3cr3t | base64 | tr -d '\n')"
PSFILE="$TMP/ps.snap"
APIM_BASE="$BASE" APIM_AUTH_MODE=basic WM_USER=adm WM_PASSWORD=s3cr3t \
  bash -c '. "'"$LIBC"'" && wm_admin_init && wm_get "/apis?slow=1" "'"$TMP"'/probe.out" >/dev/null' &
BGPID=$!
sleep 0.3
ps -Aww > "$PSFILE" 2>/dev/null
wait "$BGPID" 2>/dev/null
OUT="$(grep -c "$B64" "$PSFILE" 2>/dev/null || true)"
[ "${OUT:-1}" = "0" ] && ok "aucun secret dans l'argv d'aucun process (sonde ps -Aww)" \
  || ko "le secret apparaît dans un argv (${OUT} occurrence(s))"

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
cat > "$TMP/gov-default/registre.yaml" <<'YML'
apis:
  - owner: toto
    api: comptes
    classification: M
    exposure: internal
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

scan SCAN_PARC_ATTENDU=99:1 >"$TMP/s2.out" 2>"$TMP/s2.err"
grep -q '^REFUS: PARC_POSSIBLEMENT_TRONQUE' "$TMP/s2.err" \
  && ok "contre-compte faux (99 attendues, 10 rendues) ⇒ PARC_POSSIBLEMENT_TRONQUE" \
  || ko "compte divergent accepté : $(tail -2 "$TMP/s2.err")"

# le jeu d'essai porte DIX entrées d'API (APIS ci-dessus) et UNE application
# (endpoint /applications du faux wM) — compté à la main, cf. rulings-a-porter.md R1.
scan SCAN_PARC_ATTENDU=10:1 >"$TMP/s3.out" 2>"$TMP/s3.err"
[ -f "$TMP/out/estate.dev.json" ] \
  && ok "contre-compte juste ⇒ l'inventaire est écrit" || ko "rien écrit : $(tail -3 "$TMP/s3.err")"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get("schema")==1 and d["provenance"]["env"]=="dev" else 1)' "$TMP/out/estate.dev.json" \
  && ok "estate.dev.json porte schema:1 et sa provenance" || ko "en-tête d'inventaire incorrect"
# les CINQ canaris de identifiers (token/openIdClaims/httpsCertificate/clé
# inconnue — tous masqués — PLUS ipAddressRange, qui elle DOIT apparaître :
# ce n'est pas un secret) et le canari accessTokens (jamais lu nulle part).
grep -qE 'CANARI-(TOKEN|CLAIMS|CERT|CLE-INCONNUE|ACCESSTOKENS)-NE-DOIT' "$TMP/out/estate.dev.json" \
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
scan SCAN_PARC_ATTENDU=10:1 >"$TMP/s4pre.out" 2>"$TMP/s4pre.err"
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
rm -rf "$TMP/out"; scan SCAN_PARC_ATTENDU=10:1 >/dev/null 2>&1
python3 -c '
import json,sys
a=json.load(open(sys.argv[1]))["applications"][0]
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
scan SCAN_PARC_ATTENDU=10:1 >"$TMP/s5.out" 2>"$TMP/s5.err"
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
scan SCAN_PARC_ATTENDU=10:1 GC_PLATFORM_DIR="$TMP/plat" GOVERNANCE_PATH="$TMP/gov/registre.yaml" \
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

[ ! -f "$TMP/out/contrats/comptes-1.0.0.openapi.yaml" ] \
  && ok "une lignée OK mais NON GOUVERNÉE ne produit PAS de contrat (R2)" \
  || ko "un contrat a été produit pour comptes, pourtant hors registre"

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
scan SCAN_PARC_ATTENDU=10:1 >"$TMP/s6a.out" 2>"$TMP/s6a.err"
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
scan SCAN_PARC_ATTENDU=10:1 >"$TMP/s6b.out" 2>"$TMP/s6b.err"
rm -f "$TMP/archive-real-zip.flag"
python3 -c '
import json,sys
v=json.load(open(sys.argv[1]))["provenance"]["sondes"]["archive_zip"]
assert v=="OK", v' "$TMP/out/estate.dev.json" \
  && ok "200 AVEC l'octet magique PK\\x03\\x04 ⇒ archive_zip=OK" \
  || ko "archive_zip reste KO malgré un vrai zip — la sonde ne mesure rien"

echo "== 6b. GOVERNANCE_PATH et GC_PLATFORM_DIR : aucun défaut ne devine =="
rm -rf "$TMP/out"
scan SCAN_PARC_ATTENDU=10:1 GOVERNANCE_PATH= >"$TMP/s6c.out" 2>"$TMP/s6c.err"
grep -q '^REFUS: GOUVERNANCE_REQUISE' "$TMP/s6c.err" \
  && ok "GOVERNANCE_PATH absent ⇒ GOUVERNANCE_REQUISE (aucun défaut, aucun optimisme)" \
  || ko "le scan a tourné sans registre : $(tail -3 "$TMP/s6c.err")"
[ ! -f "$TMP/out/estate.dev.json" ] \
  && ok "aucun inventaire écrit sur le chemin GOUVERNANCE_REQUISE" \
  || ko "un estate.dev.json a été écrit malgré GOUVERNANCE_REQUISE"

rm -rf "$TMP/out"
scan SCAN_PARC_ATTENDU=10:1 GC_PLATFORM_DIR= >"$TMP/s6d.out" 2>"$TMP/s6d.err"
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
scan SCAN_PARC_ATTENDU=10:1 >"$TMP/s6e.out" 2>"$TMP/s6e.err"
grep -q 'CANARI-CONTRAT-ETRANGER-NE-DOIT-PAS-DISPARAITRE' "$TMP/out/contrats/notes-perso.openapi.yaml" 2>/dev/null \
  && ok "un *.openapi.yaml ÉTRANGER (nommé comme un contrat, jamais écrit par ce scan) survit intact" \
  || ko "DESTRUCTION : le fichier étranger *.openapi.yaml a disparu ou a été altéré"
[ -f "$TMP/out/contrats/comptes-1.0.0.openapi.yaml" ] \
  && ok "le VRAI contrat de la lignée OK est bien (ré)écrit à côté du fichier étranger" \
  || ko "le contrat légitime n'a pas été produit malgré le fichier étranger"

printf '\n%d ✅  %d ❌\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
