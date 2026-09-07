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
]
def env(a):
    i, n, v, act, teams = a
    return {"api": {"id": i, "apiName": n, "apiVersion": v, "isActive": act},
            "responseStatus": "SUCCESS",
            "teams": [{"id": "u-"+t, "name": t} for t in teams]}
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
        if p.endswith("/apis"):
            if "slow=1" in self.path:
                import time; time.sleep(1)   # sonde 1a : un appel VOLONTAIREMENT lent
            return self._send(200, {"apiResponse": [env(a) for a in APIS]})
        if "/apis/" in p:
            gid = p.rsplit("/", 1)[1]
            for a in APIS:
                if a[0] == gid:
                    e = env(a); e["api"]["apiDefinition"] = {
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
                "identifiers": [{"key": "apiKey", "value": "SECRET-QUI-NE-DOIT-PAS-FUIR"},
                                {"key": "ip", "value": ["10.0.0.0/8"]}]}]})
        return self._send(404)
HTTPServer(("127.0.0.1", int(os.environ["PORT"])), H).serve_forever()
PY
PORT="$PORT" python3 "$TMP/fakewm.py" & PID=$!
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

printf '\n%d ✅  %d ❌\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
