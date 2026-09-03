#!/usr/bin/env bash
# test-selfservice-api-gate-a5.sh — porte HORS LIGNE d'A5 (GOAL cd-applications) :
# l'ordre app/API — refus fermé si l'API n'est pas au palier.
#
#   A. le RÔLE apim_selfservice_app contre un STUB gateway (liste /apis pilotée
#      par ctl.json, JOURNAL méthode+chemin, toute écriture ⇒ 500 = canari) :
#      quatre refus nommés AVANT la première écriture, fichiers tag/détail,
#      chemin nominal (API_AT_PALIER puis POST /applications), mutations M1..M3.
#   B. VERIFY contre le MOCK webMethods du dépôt (binaire Go, shapes fidèles) :
#      API_AT_PALIER_CONFIRMED + SUBSCRIPTION_CONFIRMED, puis les deux refus.
#   C. le CÂBLAGE (vue code) : Jenkinsfile.selfservice, provision-apply, garde A3, rôle.
#   D. le RAPPORT de PR (provision-apply-comment.sh contre un faux Gitea).
#   E. le PROTOTYPE Python contre le stub : mêmes tags, exit 1 avant tout POST.
#
# Discipline A3 : toute sortie capturée dans un fichier avant grep ; mutations =
# copie, `cmp` anti-no-op, le scénario visé PASSE sur le mutant ET l'original
# refuse toujours ; le total des contrôles est asserté en dur.
# `A && ok || bad` (SC2015) est l'idiome des scripts de preuve du repo.
# shellcheck disable=SC2015
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; umask 077
PIDS=""
cleanup(){ for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
bad(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
command -v ansible-playbook >/dev/null || { echo "ansible-playbook absent"; exit 2; }
command -v python3 >/dev/null || { echo "python3 absent"; exit 2; }

# ── le stub gateway ─────────────────────────────────────────────────────────
STUB_CTL="$TMP/ctl.json"; STUB_LOG="$TMP/http.log"; : > "$STUB_LOG"
cat > "$TMP/stub.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
CTL, LOG = sys.argv[1], sys.argv[2]
def ctl():
    try: return json.load(open(CTL))
    except Exception: return {}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def _j(self, m):
        with open(LOG, "a") as f: f.write(m + " " + self.path.split("?")[0] + "\n")
    def do_GET(self):
        self._j("GET"); c = ctl(); p = self.path.split("?")[0]
        if p.endswith("/configurations/extended"): return self._send(200, {"enableTeamWork": "true"})
        if p.endswith("/apis"):
            return self._send(200, {"apiResponse": [{"api": a, "responseStatus": "SUCCESS", "teams": [{"id": "Default", "name": "Default", "source": "SYSTEM"}]} for a in c.get("apis", [])]})
        if "/apis/" in p:
            aid = p.rsplit("/", 1)[1]
            for a in c.get("apis", []):
                if a.get("id") == aid: return self._send(200, {"apiResponse": {"api": a, "teams": [{"id": "Default", "name": "Default", "source": "SYSTEM"}]}})
            return self._send(404, {"error": "no api"})
        if p.endswith("/applications"): return self._send(200, {"applications": c.get("applications", [])})
        if p.endswith("/policyActions"): return self._send(200, {"policyAction": []})
        return self._send(404, {"error": "stub: route inconnue " + p})
    def _write(self, m):
        n = int(self.headers.get("Content-Length", "0") or 0)
        if n: self.rfile.read(n)
        self._j(m); self._send(500, {"error": "stub: le canari a été touché (écriture refusée)"})
    def do_POST(self): self._write("POST")
    def do_PUT(self): self._write("PUT")
    def do_DELETE(self): self._write("DELETE")
srv = ThreadingHTTPServer(("127.0.0.1", 0), H); print(srv.server_address[1], flush=True); srv.serve_forever()
PY
python3 "$TMP/stub.py" "$STUB_CTL" "$STUB_LOG" > "$TMP/stub.port" 2>"$TMP/stub.err" &
PIDS="$PIDS $!"
for _ in $(seq 1 60); do [ -s "$TMP/stub.port" ] && break; sleep 0.1; done
PORT="$(head -n1 "$TMP/stub.port" 2>/dev/null)"
case "$PORT" in ''|*[!0-9]*) echo "!! stub non démarré : $(cat "$TMP/stub.err")"; exit 2;; esac
GW="http://127.0.0.1:$PORT/rest/apigateway"
# auto-test du canari : une écriture est journalisée ET refusée
curl -s -o /dev/null -X POST "$GW/canari-selftest"; grep -q '^POST .*/canari-selftest$' "$STUB_LOG" || { echo "!! le stub ne journalise pas les écritures — le silence des épreuves serait vacant"; exit 2; }

# ── fixtures ────────────────────────────────────────────────────────────────
ID_A="aaaaaaaa-0000-4000-8000-000000000001"; ID_B="bbbbbbbb-0000-4000-8000-000000000002"; ID_C="cccccccc-0000-4000-8000-000000000003"
api(){ printf '{"id":"%s","apiName":"%s","apiVersion":"%s"%s}' "$1" "$2" "$3" "${4:-}"; }
CTL_ABSENT='{"apis":[]}'
CTL_OTHER_VERSION="{\"apis\":[$(api "$ID_A" demo-selfservice 1.0.0 ',"isActive":true')]}"        # demandée : 2.0.0
CTL_INACTIVE="{\"apis\":[$(api "$ID_A" demo-selfservice 1.0.0 ',"isActive":false')]}"
CTL_NO_FIELD="{\"apis\":[$(api "$ID_A" demo-selfservice 1.0.0 '')]}"
CTL_STRING="{\"apis\":[$(api "$ID_A" demo-selfservice 1.0.0 ',"isActive":"true"')]}"
CTL_DUP="{\"apis\":[$(api "$ID_A" demo-selfservice 1.0.0 ',"isActive":true'),$(api "$ID_B" demo-selfservice 1.0.0 ',"isActive":true')]}"
CTL_ACTIVE="{\"apis\":[$(api "$ID_A" demo-selfservice 1.0.0 ',"isActive":true'),$(api "$ID_C" demo-selfservice 1.0.1 ',"isActive":false')]}"   # la fixture accounts-read du lab
man(){ # <fichier> <api_version>
  printf -- '---\napim_ss_app:\n  name: "a5app"\n  api: "demo-selfservice"\n  api_version: "%s"\n  description: "porte A5"\n  contact_emails: []\n  enforce: []\n  per_env:\n    rec: { ip_allowlist: ["10.42.0.1"] }\n' "$1" > "$2"
}
man 1.0.0 "$TMP/man.yml"; man 2.0.0 "$TMP/man-2.yml"
ANS_DIR="$REPO"   # un mutant pointe ailleurs
run_role(){ # <ctl json> [-e … | MAN=<fichier>] → rc $TMP/r.rc, console $TMP/r.out, journal $STUB_LOG
  printf '%s\n' "$1" > "$STUB_CTL"; : > "$STUB_LOG"; shift
  local m="$TMP/man.yml" a; local -a X=()
  for a in "$@"; do case "$a" in MAN=*) m="${a#MAN=}";; *) X+=("$a");; esac; done
  rm -f "$TMP/refus" "$TMP/refus.detail"
  ( cd "$ANS_DIR" && env -u VAULT_ADDR -u VAULT_TOKEN -u VAULT_TOKEN_FILE ANSIBLE_FORCE_COLOR=0 ANSIBLE_NOCOLOR=1 \
      ansible-playbook -i ansible/inventory.lab.ini ansible/selfservice-app.yml \
      -e "apim_ss_api_base=$GW" -e "apim_ss_manifest=$m" -e apim_ss_env=rec -e apim_ss_team=banking-demo \
      -e "apim_ss_refus_out=$TMP/refus" -e "apim_ss_refus_detail_out=$TMP/refus.detail" ${X[@]+"${X[@]}"} ) > "$TMP/r.out" 2>&1
  echo $? > "$TMP/r.rc"
}
rrc(){ cat "$TMP/r.rc"; }
writes(){ grep -cE '^(POST|PUT|DELETE) ' "$STUB_LOG"; }
refus(){ [ "$(rrc)" != 0 ] && grep -qF "REFUS: $1 :" "$TMP/r.out"; }
tail_out(){ grep -E 'REFUS|fatal|FAILED' "$TMP/r.out" | tail -2 | tr '\n' ' ' | cut -c1-300; }

echo "══ A. le rôle contre le stub : la porte AVANT la première écriture ══"
run_role "$CTL_ABSENT"
refus API_NOT_PROMOTED && [ "$(writes)" = 0 ] && ok "A.1 nom absent ⇒ rc≠0, REFUS: API_NOT_PROMOTED, AUCUNE écriture" || bad "A.1 rc $(rrc) writes=$(writes) : $(tail_out)"
[ "$(cat "$TMP/refus" 2>/dev/null)" = API_NOT_PROMOTED ] && ok "A.1b le tag est écrit dans apim_ss_refus_out" || bad "A.1b tag : '$(cat "$TMP/refus" 2>/dev/null)'"
[ "$(wc -l < "$TMP/refus.detail" 2>/dev/null | tr -d ' ')" = 1 ] && grep -q "promote/demo-selfservice-rec" "$TMP/refus.detail" && grep -q "rien n'a" "$TMP/refus.detail" \
  && ok "A.1c le détail (une ligne) nomme la promotion manquante promote/demo-selfservice-rec" || bad "A.1c détail : $(cat "$TMP/refus.detail" 2>/dev/null)"
! grep -qE "^GET .*/apis/$ID_A" "$STUB_LOG" && ok "A.1d le refus précède la garde de visibilité (aucun GET /apis/{id})" || bad "A.1d visibilité relue avant le refus"
run_role "$CTL_OTHER_VERSION" "MAN=$TMP/man-2.yml"
refus API_VERSION_MISMATCH && [ "$(writes)" = 0 ] && grep -q "1.0.0" "$TMP/refus.detail" && grep -q "'2.0.0'" "$TMP/refus.detail" \
  && ok "A.2 nom présent en 1.0.0, demandée 2.0.0 ⇒ API_VERSION_MISMATCH citant 1.0.0, aucune écriture" || bad "A.2 rc $(rrc) writes=$(writes) : $(tail_out) / $(cat "$TMP/refus.detail" 2>/dev/null)"
run_role "$CTL_INACTIVE"
refus API_INACTIVE && [ "$(writes)" = 0 ] && grep -q "isActive=False" "$TMP/refus.detail" && grep -q "$ID_A" "$TMP/refus.detail" \
  && ok "A.3 isActive:false ⇒ API_INACTIVE (valeur vue + id dans le détail), aucune écriture" || bad "A.3 rc $(rrc) writes=$(writes) : $(tail_out) / $(cat "$TMP/refus.detail" 2>/dev/null)"
run_role "$CTL_NO_FIELD"
refus API_INACTIVE && [ "$(writes)" = 0 ] && grep -q "isActive=absent" "$TMP/refus.detail" && ok "A.4 isActive ABSENT ⇒ API_INACTIVE (ne pas savoir n'est pas une raison de passer)" || bad "A.4 rc $(rrc) : $(tail_out) / $(cat "$TMP/refus.detail" 2>/dev/null)"
run_role "$CTL_STRING"
refus API_INACTIVE && [ "$(writes)" = 0 ] && ok "A.5 isActive:\"true\" (chaîne) ⇒ API_INACTIVE (booléen strict)" || bad "A.5 rc $(rrc) : $(tail_out)"
run_role "$CTL_DUP"
refus API_AMBIGUE && [ "$(writes)" = 0 ] && grep -q "^2 " "$TMP/refus.detail" && ok "A.6 deux entrées nom+version ⇒ API_AMBIGUE (fail-closed, jamais first)" || bad "A.6 rc $(rrc) : $(tail_out) / $(cat "$TMP/refus.detail" 2>/dev/null)"
run_role "$CTL_ACTIVE"
grep -q "API_AT_PALIER : 'demo-selfservice' v1.0.0 active au palier 'rec' (id=$ID_A)" "$TMP/r.out" && ok "A.7 active (1.0.1 inactive à côté) ⇒ API_AT_PALIER avec l'id de 1.0.0" || bad "A.7 marqueur absent : $(grep -c API_AT_PALIER "$TMP/r.out") — $(tail_out)"
[ "$(writes)" = 1 ] && grep -q "^POST .*/applications$" "$STUB_LOG" && ok "A.7b la porte laisse passer : la PREMIÈRE écriture (POST /applications) part et touche le canari" || bad "A.7b writes=$(writes) : $(grep -E '^(POST|PUT|DELETE)' "$STUB_LOG" | tr '\n' ' ')"
L_GATE=$(grep -n "API_AT_PALIER :" "$TMP/r.out" | head -1 | cut -d: -f1); L_POST=$(grep -n "App : créer si absente" "$TMP/r.out" | head -1 | cut -d: -f1)
[ -n "$L_GATE" ] && [ -n "$L_POST" ] && [ "$L_GATE" -lt "$L_POST" ] && ok "A.7c ORDRE console : API_AT_PALIER ($L_GATE) < « App : créer » ($L_POST)" || bad "A.7c ordre : porte=$L_GATE post=$L_POST"
grep -qE "^GET .*/apis/$ID_A$" "$STUB_LOG" && ok "A.7d la garde de visibilité a relu l'id résolu (GET /apis/{id}) — la porte lui fournit ss_api_id" || bad "A.7d GET /apis/{id} absent du journal"
[ ! -e "$TMP/refus" ] && [ ! -e "$TMP/refus.detail" ] && ok "A.7e chemin nominal : aucun fichier de refus" || bad "A.7e fichiers de refus présents sur le nominal"
run_role "$CTL_INACTIVE" -e apim_ss_refus_out= -e apim_ss_refus_detail_out=
refus API_INACTIVE && [ ! -e "$TMP/refus" ] && [ ! -e "$TMP/refus.detail" ] && ok "A.8 apply manuel (sans apim_ss_refus_*) : même REFUS:, aucun fichier" || bad "A.8 rc $(rrc) fichiers=$(ls "$TMP"/refus* 2>/dev/null | tr '\n' ' ')"
run_role "$CTL_INACTIVE"
[ "$(stat -f '%Lp' "$TMP/refus" 2>/dev/null || stat -c '%a' "$TMP/refus")" = 600 ] && ok "A.9 fichier de tag en 0600" || bad "A.9 mode : $(stat -f '%Lp' "$TMP/refus" 2>/dev/null || stat -c '%a' "$TMP/refus")"

# ── mutations : copie de l'arbre ansible, cmp anti-no-op, run depuis la copie ──
MAIN="$REPO/ansible/roles/apim_selfservice_app/tasks/main.yml"; REFUS="$REPO/ansible/roles/apim_common/tasks/refus.yml"
mutant(){ # <nom> <fichier relatif à ansible/> <sed -E expr> → $TMP/<nom>/ansible
  rm -rf "$TMP/$1"; mkdir -p "$TMP/$1"; cp -R "$REPO/ansible" "$TMP/$1/ansible"
  sed -E "$3" "$REPO/ansible/$2" > "$TMP/$1/ansible/$2"
  ! cmp -s "$REPO/ansible/$2" "$TMP/$1/ansible/$2" || { bad "mutation $1 = no-op (l'ancre a bougé)"; return 1; }
}
run_mut(){ local d="$1"; shift; ANS_DIR="$TMP/$d" run_role "$@"; }
if mutant m_active roles/apim_selfservice_app/tasks/main.yml 's/is sameas true/is not none/'; then
  run_mut m_active "$CTL_INACTIVE"
  [ "$(writes)" -ge 1 ] && grep -q "^POST .*/applications$" "$STUB_LOG" && ok "A.M1 isActive ignoré ⇒ l'inactive ATTEINT POST /applications sur le mutant" || bad "A.M1 le mutant refuse encore : $(tail_out)"
  run_role "$CTL_INACTIVE"; refus API_INACTIVE && [ "$(writes)" = 0 ] && ok "A.M1' l'original refuse toujours API_INACTIVE sans écriture" || bad "A.M1' l'original a dérivé"
fi
# A.M2 mutation d'ORDRE : le bloc de la porte (marqueurs) déplacé APRÈS « App : fail-closed — un id … » — l'ordre se mesure au JOURNAL (une écriture avant le refus).
# Le bloc déplacé = la porte ET la garde de visibilité §1b (qui consomme
# ss_api_id) : sans elle, le mutant mourrait sur une variable indéfinie AVANT
# d'écrire — un mutant qui ne peut pas écrire ne prouve rien (mesuré, T1).
awk '/^    # ── A5 porte : début/ { on=1 } /^    # ===== 2\. Application/ { on=0 } on' "$MAIN" > "$TMP/blk-a5"
rm -rf "$TMP/m_order"; mkdir -p "$TMP/m_order"; cp -R "$REPO/ansible" "$TMP/m_order/ansible"
awk '/^    # ── A5 porte : début/ { skip=1 } /^    # ===== 2\. Application/ { skip=0 } skip { next } { print } /^    - name: "App : fail-closed — un id d.application est obligatoire pour la suite"/ { getline; print; getline; print; getline; print; while ((getline l < B) > 0) print l; close(B) }' B="$TMP/blk-a5" "$MAIN" > "$TMP/m_order/ansible/roles/apim_selfservice_app/tasks/main.yml"
if [ -s "$TMP/blk-a5" ] && ! cmp -s "$MAIN" "$TMP/m_order/ansible/roles/apim_selfservice_app/tasks/main.yml" && python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$TMP/m_order/ansible/roles/apim_selfservice_app/tasks/main.yml" 2>/dev/null; then
  run_mut m_order "$CTL_ABSENT"
  [ "$(writes)" -ge 1 ] && ok "A.M2 porte déplacée après la création ⇒ une ÉCRITURE part avant le refus sur le mutant (le journal la voit)" || bad "A.M2 le mutant n'écrit pas : $(tail_out)"
  run_role "$CTL_ABSENT"; refus API_NOT_PROMOTED && [ "$(writes)" = 0 ] && ok "A.M2' l'original refuse toujours avant toute écriture" || bad "A.M2' l'original a dérivé"
else
  bad "A.M2 mutant d'ordre non construit (marqueurs A5 absents ou YAML invalide)"
fi
if mutant m_tag roles/apim_common/tasks/refus.yml '/^- name: "Refus : écrire le tag/,/^$/d'; then
  run_mut m_tag "$CTL_ABSENT"
  refus API_NOT_PROMOTED && [ ! -e "$TMP/refus" ] && ok "A.M3 refus.yml sans l'écriture du tag ⇒ le refus tombe mais RIEN n'atteint la PR sur le mutant" || bad "A.M3 mutant : rc $(rrc) tag=$(cat "$TMP/refus" 2>/dev/null)"
  run_role "$CTL_ABSENT"; [ "$(cat "$TMP/refus" 2>/dev/null)" = API_NOT_PROMOTED ] && ok "A.M3' l'original écrit le tag" || bad "A.M3' l'original a dérivé"
fi

echo
echo "══ B. verify contre le MOCK webMethods (shapes fidèles) ══"
if command -v go >/dev/null && (cd "$REPO/mocks/webmethods" && go build -o "$TMP/wm-mock" . 2>"$TMP/mock.build"); then
  MPORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
  LISTEN_ADDR=":$MPORT" "$TMP/wm-mock" > "$TMP/mock.log" 2>&1 &
  PIDS="$PIDS $!"
  for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$MPORT/health" >/dev/null 2>&1 && break; sleep 0.2; done
  MGW="http://127.0.0.1:$MPORT/rest/apigateway"
  madm(){ curl -s -u Administrator:manage -H 'Accept: application/json' -H 'Content-Type: application/json' "$@"; }
  mk_api(){ madm -X POST "$MGW/apis" -d "{\"apiName\":\"$1\",\"apiVersion\":\"$2\",\"type\":\"REST\",\"apiDefinition\":{\"openapi\":\"3.0.0\"}}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["apiResponse"]["api"]["id"])'; }
  API1=$(mk_api demo-selfservice 1.0.0); madm -X PUT -o /dev/null "$MGW/apis/$API1/activate"
  [ -n "$API1" ] && ok "B.0 mock : demo-selfservice 1.0.0 publiée et activée ($API1)" || bad "B.0 mock : API non créée ($(head -c 200 "$TMP/mock.log"))"
  run_mock(){ # <playbook> → $TMP/r.rc, $TMP/r.out
    rm -f "$TMP/refus" "$TMP/refus.detail"
    ( cd "$REPO" && env -u VAULT_ADDR -u VAULT_TOKEN -u VAULT_TOKEN_FILE ANSIBLE_FORCE_COLOR=0 ANSIBLE_NOCOLOR=1 \
        ansible-playbook -i ansible/inventory.lab.ini "ansible/$1" -e "apim_ss_api_base=$MGW" -e "apim_ss_manifest=$TMP/man.yml" \
        -e apim_ss_env=rec -e apim_ss_team=banking-demo -e apim_ss_require_team=false \
        -e "apim_ss_refus_out=$TMP/refus" -e "apim_ss_refus_detail_out=$TMP/refus.detail" ) > "$TMP/r.out" 2>&1; echo $? > "$TMP/r.rc"
  }
  run_mock selfservice-app.yml
  [ "$(rrc)" = 0 ] && grep -q "API_AT_PALIER : 'demo-selfservice' v1.0.0 active" "$TMP/r.out" && ok "B.1 converge sur le mock : rc 0, API_AT_PALIER" || bad "B.1 rc $(rrc) : $(tail_out)"
  run_mock selfservice-app-verify.yml
  [ "$(rrc)" = 0 ] && grep -q "API_AT_PALIER_CONFIRMED" "$TMP/r.out" && grep -q "SUBSCRIPTION_CONFIRMED" "$TMP/r.out" && grep -q "id=$API1" "$TMP/r.out" \
    && ok "B.2 verify : API_AT_PALIER_CONFIRMED + SUBSCRIPTION_CONFIRMED (souscrite au GUID $API1)" || bad "B.2 rc $(rrc) : $(grep -E 'CONFIRMED|REFUS' "$TMP/r.out" | tr '\n' ' ' | cut -c1-300)"
  madm -X PUT -o /dev/null "$MGW/apis/$API1/deactivate"
  run_mock selfservice-app-verify.yml
  refus API_AT_PALIER_UNCONFIRMED && [ "$(cat "$TMP/refus")" = API_AT_PALIER_UNCONFIRMED ] && ok "B.3 API désactivée après l'apply ⇒ verify refuse API_AT_PALIER_UNCONFIRMED (tag relayé)" || bad "B.3 rc $(rrc) : $(tail_out)"
  run_mock selfservice-app.yml
  refus API_INACTIVE && ok "B.4 le mock est fidèle : converge sur l'inactive ⇒ API_INACTIVE (isActive booléen du mock)" || bad "B.4 rc $(rrc) : $(tail_out)"
  madm -X PUT -o /dev/null "$MGW/apis/$API1/activate"
  API2=$(mk_api autre-api 1.0.0); madm -X PUT -o /dev/null "$MGW/apis/$API2/activate"
  APPID=$(madm "$MGW/applications" | python3 -c 'import sys,json;print(next(a["id"] for a in json.load(sys.stdin)["applications"] if a["name"]=="a5app"))')
  madm -X PUT -o /dev/null "$MGW/applications/$APPID/apis" -d "{\"apiIDs\":[\"$API2\"]}"
  run_mock selfservice-app-verify.yml
  refus SUBSCRIPTION_UNCONFIRMED && grep -q "$API2" "$TMP/refus.detail" && ok "B.5 souscription remplacée par une autre API ⇒ SUBSCRIPTION_UNCONFIRMED (consumingAPIs cité)" || bad "B.5 rc $(rrc) : $(tail_out) / $(cat "$TMP/refus.detail" 2>/dev/null)"
else
  bad "B.0 mock Go non bâti (go absent ou build en échec : $(head -c 200 "$TMP/mock.build" 2>/dev/null))"
  for _ in 1 2 3 4 5; do bad "B.x section sautée"; done
fi

echo
echo "══ C. le câblage (vue code) ══"
JFS="$REPO/ci/Jenkinsfile.selfservice"; JFA="$REPO/ci/Jenkinsfile.provision-apply"; GATE="$REPO/scripts/selfservice-palier-gate.sh"
sed -E 's@^[[:space:]]*(//|#).*$@@' "$JFS" > "$TMP/jfs.code"; sed -E 's@^[[:space:]]*//.*$@@' "$JFA" > "$TMP/jfa.code"
[ "$(grep -c -- '-e apim_ss_refus_out="\$WORKSPACE/.a3-refus" -e apim_ss_refus_detail_out="\$WORKSPACE/.a3-refus-detail"' "$TMP/jfs.code")" = 2 ] && ok "C.1 les DEUX plays (converge, verify) reçoivent apim_ss_refus_out + apim_ss_refus_detail_out" || bad "C.1 lignes -e apim_ss_refus_* : $(grep -c 'apim_ss_refus_out' "$TMP/jfs.code")"
grep 'selfservice-palier-gate.sh' "$TMP/jfs.code" | grep -q 'REFUS_DETAIL_OUT="\$WORKSPACE/.a3-refus-detail"' && ok "C.2 la garde A3 reçoit REFUS_DETAIL_OUT sur sa ligne d'appel" || bad "C.2 REFUS_DETAIL_OUT absent de la ligne de la garde"
[ "$(grep -c 'rm -f "\$WORKSPACE/.a3-refus" "\$WORKSPACE/.a3-refus-detail"' "$TMP/jfs.code")" -ge 2 ] && ok "C.3 deux purges ABSOLUES du tag ET du détail" || bad "C.3 purges : $(grep -c 'a3-refus-detail' "$TMP/jfs.code")"
grep -q 'env.APPLIED_REFUSAL_DETAIL = (env.APPLIED_REFUSAL && d ==~ /\[^\\r\\n\]{1,300}/) ? d : ' "$TMP/jfs.code" && ok "C.4 post{always} relit le détail sous [^\\r\\n]{1,300} et seulement avec un tag" || bad "C.4 relais du détail absent ou sans classe"
grep -q "vars.APPLIED_REFUSAL_DETAIL" "$TMP/jfa.code" && grep -q 'env.APPLIED_REFUSAL_DETAIL = (env.APPLIED_REFUSAL && ad ==~ /\[^\\r\\n\]{1,300}/) ? ad : ' "$TMP/jfa.code" && grep -q 'env.REFUSAL_DETAIL = env.APPLIED_REFUSAL_DETAIL ? "aval ${env.APPLY_BUILD} : ${env.APPLIED_REFUSAL_DETAIL}"' "$TMP/jfa.code" \
  && ok "C.5 provision-apply relit APPLIED_REFUSAL_DETAIL sous classe et compose « aval #n : <détail> »" || bad "C.5 composition du détail absente"
L_G=$(grep -n 'selfservice-palier-gate.sh" || exit 1' "$TMP/jfs.code" | head -1 | cut -d: -f1); L_P=$(grep -n 'préflight de joignabilité :' "$JFS" | head -1 | cut -d: -f1); L_C=$(grep -n 'ansible/selfservice-app.yml \\' "$TMP/jfs.code" | head -1 | cut -d: -f1); L_V=$(grep -n 'ansible/selfservice-app-verify.yml \\' "$TMP/jfs.code" | head -1 | cut -d: -f1)
[ -n "$L_G" ] && [ -n "$L_P" ] && [ -n "$L_C" ] && [ -n "$L_V" ] && [ "$L_G" -lt "$L_P" ] && [ "$L_P" -lt "$L_C" ] && [ "$L_C" -lt "$L_V" ] && ok "C.6 ORDRE inchangé : garde ($L_G) < préflight ($L_P) < converge ($L_C) < verify ($L_V)" || bad "C.6 ordre : garde=$L_G préflight=$L_P converge=$L_C verify=$L_V"
L_A5=$(grep -n '^    # ── A5 porte : début' "$MAIN" | cut -d: -f1); L_CR=$(grep -n 'App : créer si absente' "$MAIN" | head -1 | cut -d: -f1); L_VIS=$(grep -n 'import_tasks: api-visibility.yml' "$MAIN" | head -1 | cut -d: -f1)
[ -n "$L_A5" ] && [ "$L_A5" -lt "$L_VIS" ] && [ "$L_VIS" -lt "$L_CR" ] && ok "C.7 rôle : porte A5 ($L_A5) < visibilité ($L_VIS) < création ($L_CR)" || bad "C.7 rôle : a5=$L_A5 vis=$L_VIS create=$L_CR"
grep -q 'tasks_from: refus.yml' "$MAIN" && grep -q 'tasks_from: refus.yml' "$REPO/ansible/roles/apim_selfservice_app/tasks/verify.yml" && ok "C.8 main.yml ET verify.yml passent par refus.yml" || bad "C.8 refus.yml non consommé"
sed -E 's@^[[:space:]]*#.*$@@' "$GATE" > "$TMP/gate.code"
L_RD=$(grep -n '^REFUS_DETAIL_OUT="\${REFUS_DETAIL_OUT:-}"' "$TMP/gate.code" | cut -d: -f1); L_RF=$(grep -n '^refus()' "$TMP/gate.code" | cut -d: -f1)
[ -n "$L_RD" ] && [ -n "$L_RF" ] && [ "$L_RD" -lt "$L_RF" ] && grep -q 'rm -f "\$REFUS_DETAIL_OUT"' "$TMP/gate.code" && ok "C.9 garde A3 : REFUS_DETAIL_OUT lu AVANT refus(), purgé en tête" || bad "C.9 garde : lu=$L_RD refus=$L_RF"

# ── faux Gitea (verbatim test-pr-comment.sh) ────────────────────────────────
cat > "$TMP/fakegitea.py" <<'PY'
import json, re, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
STORE = os.environ["STORE"]          # fichier JSON : liste de commentaires
TOKEN = os.environ.get("EXPECT_TOKEN", "tok-ok")
def load():
    try: return json.load(open(STORE))
    except Exception: return []
def save(c): json.dump(c, open(STORE, "w"))
class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _auth(self):
        # Le token doit arriver en EN-TÊTE. S'il était en argv ou en query, il
        # finirait dans une liste de processus ou un log d'accès.
        return self.headers.get("Authorization") == "token " + TOKEN
    def do_GET(self):
        if not self._auth(): return self._send(401, {"message": "unauthorized"})
        # A0 dettes : la lib PAGINE (?limit=50&page=N) — le faux honore les deux
        # paramètres, comme le vrai Gitea (limit max 50 par défaut).
        path, _, qs = self.path.partition("?")
        if re.match(r"^/api/v1/repos/.+/issues/\d+/comments$", path):
            q = dict(kv.split("=", 1) for kv in qs.split("&") if "=" in kv)
            # PLAFOND serveur (api.MAX_RESPONSE_ITEMS chez Gitea) : `limit` est
            # ECRETE, une page pleine peut donc etre plus courte que demande.
            cap = int(os.environ.get("PAGE_CAP", "50"))
            lim, page = min(int(q.get("limit", 50)), cap), int(q.get("page", 1))
            allc = load()
            return self._send(200, allc[(page - 1) * lim: page * lim])
        self._send(404, {"message": "not found"})
    def do_POST(self):
        if not self._auth(): return self._send(401, {"message": "unauthorized"})
        n = int(self.headers.get("Content-Length", 0)); body = json.loads(self.rfile.read(n) or "{}")
        c = load(); new = {"id": len(c) + 1, "body": body.get("body", "")}
        c.append(new); save(c); return self._send(201, new)
    def do_PATCH(self):
        if not self._auth(): return self._send(401, {"message": "unauthorized"})
        m = re.match(r"^/api/v1/repos/.+/issues/comments/(\d+)$", self.path)
        if not m: return self._send(404, {"message": "not found"})
        n = int(self.headers.get("Content-Length", 0)); body = json.loads(self.rfile.read(n) or "{}")
        cid = int(m.group(1)); c = load()
        for e in c:
            if e["id"] == cid: e["body"] = body.get("body", "")
        save(c); return self._send(200, {"id": cid})
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

echo
echo "══ D. le rapport de PR ══"
GPORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
printf '[]' > "$TMP/comments.json"
STORE="$TMP/comments.json" EXPECT_TOKEN=tok-ok python3 "$TMP/fakegitea.py" "$GPORT" >/dev/null 2>&1 &
PIDS="$PIDS $!"; for _ in $(seq 1 40); do curl -s -o /dev/null "http://127.0.0.1:$GPORT/" 2>/dev/null && break; sleep 0.1; done
GH="http://127.0.0.1:$GPORT"
bodies(){ python3 -c 'import json,sys;print("\n".join(c["body"] for c in json.load(open(sys.argv[1]))))' "$TMP/comments.json"; }
report(){ # <REFUSAL> <REFUSAL_DETAIL> → $TMP/d.out
  printf '[]' > "$TMP/comments.json"
  ( cd "$REPO" && PR_NUMBER=7 APPLY_RESULT=FAILURE APP_NAME=a5app ENV_NAME=rec VALIDATOR=alice REFUSAL="$1" REFUSAL_DETAIL="$2" \
      GIT_REPO=ci/stoa-labs GITEA_TOKEN=tok-ok GIT_HOST="$GH" bash scripts/provision-apply-comment.sh ) > "$TMP/d.out" 2>&1; echo $? > "$TMP/d.rc"
}
report API_NOT_PROMOTED "l'API 'demo-selfservice' n'est pas au palier 'rec' — promouvoir l'API vers rec (PR promote/demo-selfservice-rec, G5) puis rejouer l'apply ; rien n'a été écrit"
bodies > "$TMP/d.body"
[ "$(cat "$TMP/d.rc")" = 0 ] && grep -q 'API_NOT_PROMOTED' "$TMP/d.body" && grep -q "L'ordre app/API" "$TMP/d.body" && grep -q 'promote/<api>-rec' "$TMP/d.body" && grep -q 'promote/demo-selfservice-rec' "$TMP/d.body" && grep -q 'rejouer ce webhook' "$TMP/d.body" \
  && ok "D.1 API_NOT_PROMOTED : tag, détail (promote/demo-selfservice-rec), paragraphe « L'ordre app/API » avec le remède" || bad "D.1 rc $(cat "$TMP/d.rc") : $(tr '\n' ' ' < "$TMP/d.body" | cut -c1-400)"
report PALIER_FERME "lecture de envs/int/wm-admin refusée (HTTP 403)"
bodies > "$TMP/d.body"
grep -q 'PALIER_FERME' "$TMP/d.body" && grep -q 'envs/int/wm-admin' "$TMP/d.body" && ! grep -q "L'ordre app/API" "$TMP/d.body" && ok "D.2 PALIER_FERME : la phrase de la garde sur la PR, PAS le paragraphe A5" || bad "D.2 : $(tr '\n' ' ' < "$TMP/d.body" | cut -c1-300)"
report SUBSCRIPTION_UNCONFIRMED "consumingAPIs=['x']"
bodies > "$TMP/d.body"
grep -q "la convergence a eu lieu" "$TMP/d.body" && ! grep -q "rien n'a été écrit sur la gateway, cette PR" "$TMP/d.body" && ok "D.3 SUBSCRIPTION_UNCONFIRMED : variante « la convergence a eu lieu » (jamais « rien n'a été écrit »)" || bad "D.3 : $(tr '\n' ' ' < "$TMP/d.body" | cut -c1-300)"
report API_INACTIVE "$(printf 'x [lien](http://e) `code` *gras*\nseconde ligne')"
bodies > "$TMP/d.body"
grep -q 'API_INACTIVE' "$TMP/d.body" && ! grep -q '\[lien\]' "$TMP/d.body" && ! grep -q '\*gras\*' "$TMP/d.body" && [ "$(grep -c 'seconde ligne' "$TMP/d.body")" = 1 ] && ok "D.4 détail hostile nettoyé (markdown inerte, une ligne)" || bad "D.4 : $(tr '\n' ' ' < "$TMP/d.body" | cut -c1-300)"

echo
echo "══ E. le prototype Python (spec du fold-in) contre le stub ══"
ENG="$REPO/scripts/apply-selfservice-application.py"
run_eng(){ # <ctl> <manifest json> → $TMP/e.rc $TMP/e.out
  printf '%s\n' "$1" > "$STUB_CTL"; : > "$STUB_LOG"; printf '%s' "$2" > "$TMP/e.json"
  ( WM_ADMIN_URL="$GW" WM_USER=Administrator WM_PASS=manage python3 "$ENG" "$TMP/e.json" ) > "$TMP/e.out" 2>&1; echo $? > "$TMP/e.rc"
}
run_eng "$CTL_ABSENT" '{"name":"a5app","api":"demo-selfservice","api_version":"1.0.0"}'
[ "$(cat "$TMP/e.rc")" = 1 ] && grep -q '^REFUS: API_NOT_PROMOTED' "$TMP/e.out" && [ "$(writes)" = 0 ] && ok "E.1 prototype : nom absent ⇒ rc 1, REFUS: API_NOT_PROMOTED, aucune écriture" || bad "E.1 rc $(cat "$TMP/e.rc") writes=$(writes) : $(tail -1 "$TMP/e.out")"
run_eng "$CTL_INACTIVE" '{"name":"a5app","api":"demo-selfservice","api_version":"1.0.0"}'
[ "$(cat "$TMP/e.rc")" = 1 ] && grep -q '^REFUS: API_INACTIVE' "$TMP/e.out" && [ "$(writes)" = 0 ] && ok "E.2 prototype : inactive ⇒ REFUS: API_INACTIVE, aucune écriture (la dette du spike est fermée)" || bad "E.2 rc $(cat "$TMP/e.rc") writes=$(writes) : $(tail -1 "$TMP/e.out")"
run_eng "$CTL_OTHER_VERSION" '{"name":"a5app","api":"demo-selfservice","api_version":"2.0.0"}'
[ "$(cat "$TMP/e.rc")" = 1 ] && grep -q '^REFUS: API_VERSION_MISMATCH' "$TMP/e.out" && grep -q '1.0.0' "$TMP/e.out" && ok "E.3 prototype : version absente ⇒ API_VERSION_MISMATCH citant 1.0.0" || bad "E.3 : $(tail -1 "$TMP/e.out")"
run_eng "$CTL_ACTIVE" '{"name":"a5app","api":"demo-selfservice","api_version":"1.0.0"}'
grep -q "^POST .*/applications$" "$STUB_LOG" && ok "E.4 prototype : active ⇒ la porte laisse passer (POST /applications atteint le canari)" || bad "E.4 aucun POST : $(tail -2 "$TMP/e.out" | tr '\n' ' ')"
run_eng "$CTL_ACTIVE" '{"name":"a5app","api":"demo-selfservice"}'
[ "$(cat "$TMP/e.rc")" != 0 ] && grep -q 'CABLAGE_INCOMPLET' "$TMP/e.out" && [ "$(writes)" = 0 ] && ok "E.5 prototype : api_version absent ⇒ CABLAGE_INCOMPLET (la résolution par nom seul n'est plus admise)" || bad "E.5 rc $(cat "$TMP/e.rc") : $(tail -1 "$TMP/e.out")"
SPIKE="$REPO/scripts/spike-cd-applications.py"
grep -q "API_INACTIVE" "$SPIKE" && ! grep -q 'compare apiName SEUL' "$SPIKE" && ok "E.6 le spike attend désormais le refus (S2-T3 réaligné : il reste rejouable et dit l'état vrai)" || bad "E.6 spike non réaligné"

EXPECTED_CHECKS=48
TOTAL=$((PASS+FAIL))
[ "$TOTAL" -eq "$((EXPECTED_CHECKS-1))" ] \
  && ok "$((TOTAL+1)) contrôles exécutés = $EXPECTED_CHECKS attendus (aucune section sautée)" \
  || bad "$((TOTAL+1)) contrôles exécutés, $EXPECTED_CHECKS attendus — une section a été sautée ou ajoutée sans mettre EXPECTED_CHECKS à jour"
echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
