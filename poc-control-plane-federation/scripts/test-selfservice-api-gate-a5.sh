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

# (sections C..E ajoutées par T3..T5)

EXPECTED_CHECKS=29
TOTAL=$((PASS+FAIL))
[ "$TOTAL" -eq "$((EXPECTED_CHECKS-1))" ] \
  && ok "$((TOTAL+1)) contrôles exécutés = $EXPECTED_CHECKS attendus (aucune section sautée)" \
  || bad "$((TOTAL+1)) contrôles exécutés, $EXPECTED_CHECKS attendus — une section a été sautée ou ajoutée sans mettre EXPECTED_CHECKS à jour"
echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
