#!/usr/bin/env bash
# test-selfservice-palier-a3.sh — porte HORS LIGNE d'A3 (GOAL cd-applications) :
# le credential du seul palier.
#
#   A. la GARDE (scripts/selfservice-palier-gate.sh) contre un STUB Vault
#      (lookup-self, capabilities-self, KV — pilotés par ctl.json, journal HTTP)
#      et un CANARI qui tient la place de la gateway : chaque scénario joue le
#      geste minimal de l'Apply — `gate && curl canari` — et relit le journal
#      du canari. Refus nommés, sortie PALIER_OUT, secrets, mutations.
#   B. le CÂBLAGE de ci/Jenkinsfile.selfservice (vue code, ordre par lignes,
#      mutation d'ordre) — T3.
#   C. le poseur des comptes gateway par palier, --print hors ligne — T4.
#   D. le poseur LDAP : read-back conditionné au deployerGroup — T5.
#   E. vault_token_ttl (ci/lib/vault-login.sh) contre le stub — T2.
#
# ── CE QUE LE CANARI PROUVE ─────────────────────────────────────────────────
# « Aucune requête n'a atteint la gateway » est une assertion d'ABSENCE, vraie
# aussi quand le témoin est mort : le canari est TOUCHÉ au démarrage (auto-test)
# et son journal relu — sans ce contrôle positif, la suite refuse de courir.
#
# Discipline héritée des suites A2/G4 : toute sortie réseau est CAPTURÉE dans un
# fichier avant grep (jamais un pipe sous pipefail) ; mutations = copie, `cmp`
# anti-no-op, `bash -n`, puis le scénario visé PASSE sur le mutant et l'ORIGINAL
# refuse toujours.
# `A && ok || bad` (SC2015) est l'idiome des scripts de preuve du repo.
# shellcheck disable=SC2015
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"

PASS=0; FAIL=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d)"; umask 077
SPID=""; CPID=""
cleanup(){ [ -n "$SPID" ] && kill "$SPID" 2>/dev/null; [ -n "$CPID" ] && kill "$CPID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

GATE="scripts/selfservice-palier-gate.sh"

# ── le stub Vault ────────────────────────────────────────────────────────────
STUB_CTL="$TMP/ctl.json"; STUB_LOG="$TMP/http.log"; : > "$STUB_LOG"
cat > "$TMP/stub.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
CTL = sys.argv[1]; LOG = sys.argv[2]
def ctl():
    try:
        with open(CTL) as f: return json.load(f)
    except Exception: return {}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def _journal(self, method, body):
        with open(LOG, "a") as f:
            f.write(json.dumps({"m": method, "p": self.path, "tok": self.headers.get("X-Vault-Token", ""),
                                "ns": self.headers.get("X-Vault-Namespace", ""), "body": body}) + "\n")
    def do_GET(self):
        self._journal("GET", ""); c = ctl(); p = self.path
        if p == "/v1/auth/token/lookup-self":
            lk = c.get("lookup", {}); code = lk.get("code", 200)
            if code != 200: self._send(code, {"errors": ["stub lookup"]}); return
            self._send(200, {"data": {"policies": lk.get("policies", []), "identity_policies": lk.get("identity_policies"), "ttl": lk.get("ttl", 300)}}); return
        kv = c.get("kv", {}); code = kv.get(p[len("/v1/"):], 404)
        if code == 200: self._send(200, {"data": {"data": {"username": "u", "password": "SECRET-BODY-DO-NOT-STORE"}}})
        else: self._send(code, {"errors": ["stub kv %s" % code]})
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0") or 0); body = self.rfile.read(n).decode() if n else ""
        self._journal("POST", body); c = ctl()
        if self.path == "/v1/sys/capabilities-self":
            cs = c.get("caps", {}); code = cs.get("code", 200)
            if code != 200: self._send(code, {"errors": ["permission denied"]}); return
            try: paths = json.loads(body).get("paths", [])
            except Exception: paths = []
            out = {p: cs.get("paths", {}).get(p, ["deny"]) for p in paths}
            resp = dict(out); resp["data"] = out; self._send(200, resp); return
        self._send(404, {"errors": ["stub: route inconnue " + self.path]})
srv = ThreadingHTTPServer(("127.0.0.1", 0), H); print(srv.server_address[1], flush=True); srv.serve_forever()
PY
python3 "$TMP/stub.py" "$STUB_CTL" "$STUB_LOG" > "$TMP/stub.port" 2>"$TMP/stub.err" &
SPID=$!
for _ in $(seq 1 60); do [ -s "$TMP/stub.port" ] && break; sleep 0.1; done
PORT="$(head -n1 "$TMP/stub.port" 2>/dev/null)"
case "$PORT" in ''|*[!0-9]*) echo "!! stub Vault non démarré : $(cat "$TMP/stub.err")"; exit 2;; esac
VA="http://127.0.0.1:$PORT"

# ── le canari (la gateway) ───────────────────────────────────────────────────
CANARY_PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
python3 -m http.server "$CANARY_PORT" --bind 127.0.0.1 >"$TMP/canary.log" 2>&1 &
CPID=$!
for _ in $(seq 1 30); do curl -s -m 2 -o /dev/null "http://127.0.0.1:$CANARY_PORT/canary-selftest" && break; sleep 0.3; done
grep -q 'canary-selftest' "$TMP/canary.log" || { echo "!! le canari ne journalise pas — le silence des épreuves serait vacant"; exit 2; }
canary_hits(){ grep -c "apply-app-$1" "$TMP/canary.log"; }

# ── helpers ──────────────────────────────────────────────────────────────────
set_ctl(){ printf '%s\n' "$1" > "$STUB_CTL"; : > "$STUB_LOG"; }
jcount(){ grep -c -- "$1" "$STUB_LOG"; }
# les chemins du DERNIER POST capabilities-self, un par ligne
jcaps_paths(){ python3 -c 'import json,sys
last=None
for l in open(sys.argv[1]):
    d=json.loads(l)
    if d["m"]=="POST" and d["p"]=="/v1/sys/capabilities-self": last=d
if last:
    for p in json.loads(last["body"]).get("paths",[]): print(p)' "$STUB_LOG"; }
printf 'stub-token-abc' > "$TMP/tok"
cat > "$TMP/chain.yaml" <<'EOF'
environments: [dev, rec, int, homol, prod]
gates: []
EOF
MAN="$TMP/man.yml"
man_idp(){ # <fichier> <team|''>
  { printf -- '---\napim_ss_app:\n  name: "appa"\n  api: "demo-selfservice"\n  api_version: "1.0.0"\n'
    [ -n "$2" ] && printf '  team: "%s"\n' "$2"
    printf '  auth:\n    mode: "idp"\n    claim: { name: "azp" }\n  per_env:\n    rec: { auth: { claim: { value: "appa-rec" } } }\n    int: { auth: { claim: { value: "appa-int" } } }\n'; } > "$1"
}
man_internal(){ # <fichier> <vault_sub racine> <vault_sub rec>
  printf -- '---\napim_ss_app:\n  name: "appa"\n  api: "demo-selfservice"\n  api_version: "1.0.0"\n  team: "banking-demo"\n  auth:\n    mode: "internal"\n    vault_sub: "%s"\n  per_env:\n    rec: { auth: { vault_sub: "%s" } }\n' "$2" "$3" > "$1"
}
man_idp "$MAN" banking-demo
OUTF="$TMP/out.env"
# run_gate <env> [VAR=val | UNSET:VAR …]  → stdout dans $TMP/g.out, rc dans $TMP/g.rc
run_gate(){
  local e="$1"; shift
  local -a DEFS=(ENVIRONMENT="$e" ADMIN_VIA=direct VAULT_ADDR="$VA" VAULT_TOKEN_FILE="$TMP/tok" PALIER_OUT="$OUTF"
                 MANIFEST="$MAN" APIM_KV_PREFIX=stoa APIM_API_BASE=http://gw.test:5555/rest/apigateway
                 STOA_ENV_CHAIN_FILE="$TMP/chain.yaml")
  local -a ENVV=() UNS=()
  local a d skip
  for a in "$@"; do case "$a" in UNSET:*) UNS+=(-u "${a#UNSET:}");; esac; done
  # un défaut dont la clé est UNSET: n'est PAS reposé (sinon `env -u X X=v` la remettrait)
  for d in "${DEFS[@]}"; do
    skip=0; for a in "$@"; do [ "$a" = "UNSET:${d%%=*}" ] && skip=1; done
    [ "$skip" -eq 0 ] && ENVV+=("$d")
  done
  for a in "$@"; do case "$a" in UNSET:*) ;; *) ENVV+=("$a");; esac; done
  rm -f "$OUTF"
  env ${UNS[@]+"${UNS[@]}"} "${ENVV[@]}" bash "${GATE_BIN:-$GATE}" > "$TMP/g.out" 2>&1; echo $? > "$TMP/g.rc"
}
grc(){ cat "$TMP/g.rc"; }
gout(){ cat "$TMP/g.out"; }
out_val(){ sed -n "s/^$1=//p" "$OUTF" 2>/dev/null; }
refus(){ # <tag> — la sortie porte "REFUS: <tag> :" et rc=1
  [ "$(grc)" = 1 ] && grep -q "^REFUS: $1 :" "$TMP/g.out"
}
geste(){ # <env> [vars…] : gate, puis le canari si la gate a ouvert
  run_gate "$@"
  [ "$(grc)" = 0 ] && curl -s -m 5 -o /dev/null "http://127.0.0.1:$CANARY_PORT/apply-app-$1"
  return 0
}
CTL_OK='{"lookup":{"policies":["deploy-banking-demo","apply-rec","default"]},
 "caps":{"paths":{"secret/data/stoa/envs/rec/wm-admin":["read"],"secret/data/stoa/envs/prod/wm-admin":["read"]}},
 "kv":{"secret/data/stoa/envs/rec/wm-admin":200,"secret/data/stoa/envs/int/wm-admin":403,"secret/data/stoa/envs/prod/wm-admin":403}}'

echo "═══ 0. Préconditions ═══"
[ -f "$GATE" ] && ok "0.1 $GATE existe" || bad "0.1 $GATE absent"
bash -n "$GATE" 2>/dev/null && ok "0.2 $GATE parse" || bad "0.2 $GATE ne parse pas"
ok "0.3 stub Vault sur $VA, canari VIVANT sur 127.0.0.1:$CANARY_PORT (auto-test journalisé)"

echo
echo "═══ A. la garde contre le stub Vault ═══"
echo "── A.1 nominal direct rec ──"
set_ctl "$CTL_OK"; geste rec
[ "$(grc)" = 0 ] && ok "A.1 rc 0" || bad "A.1 rc $(grc) : $(gout | tail -3 | tr '\n' ' ')"
[ "$(out_val PALIER_ENV)" = rec ] && [ "$(out_val PALIER_VIA)" = direct ] && ok "A.1a PALIER_ENV=rec PALIER_VIA=direct" || bad "A.1a env/via : $(out_val PALIER_ENV)/$(out_val PALIER_VIA)"
[ "$(out_val APIM_API_BASE)" = "http://gw.test:5555/rest/apigateway" ] && ok "A.1b APIM_API_BASE = la base directe" || bad "A.1b base : $(out_val APIM_API_BASE)"
[ "$(out_val APIM_AUTH_MODE)" = basic ] && ok "A.1c APIM_AUTH_MODE=basic" || bad "A.1c auth mode : $(out_val APIM_AUTH_MODE)"
[ "$(out_val APIM_WM_CREDS_SUB)" = envs/rec/wm-admin ] && [ "$(out_val APIM_OAUTH_SUB)" = envs/rec/admin-oauth ] && ok "A.1d subs = envs/rec/wm-admin + envs/rec/admin-oauth" || bad "A.1d subs : $(out_val APIM_WM_CREDS_SUB) / $(out_val APIM_OAUTH_SUB)"
[ "$(out_val PALIER_TEAM)" = banking-demo ] && ok "A.1e PALIER_TEAM=banking-demo (manifeste, ∈ token)" || bad "A.1e team : $(out_val PALIER_TEAM)"
[ "$(out_val PALIER_TICKET)" = secret/data/stoa/envs/rec/wm-admin ] && ok "A.1f PALIER_TICKET=secret/data/stoa/envs/rec/wm-admin" || bad "A.1f ticket : $(out_val PALIER_TICKET)"
grep -q '^palier ouvert : envs/rec/wm-admin' "$TMP/g.out" && grep -q '^PALIER_CREDS=envs/rec/wm-admin$' "$TMP/g.out" && grep -q '^PALIER_TEAM=banking-demo$' "$TMP/g.out" \
  && ok "A.1g stdout : « palier ouvert : envs/rec/wm-admin », PALIER_CREDS=, PALIER_TEAM= (les marqueurs de la preuve live)" || bad "A.1g marqueurs stdout absents : $(gout | tr '\n' '|')"
[ "$(canary_hits rec)" = 1 ] && ok "A.1h canari : EXACTEMENT un hit (la gate a ouvert, le geste a touché la gateway)" || bad "A.1h canari : $(canary_hits rec) hit(s)"
[ "$(jcount '"p": "/v1/auth/token/lookup-self"')" = 1 ] && [ "$(jcount '"p": "/v1/sys/capabilities-self"')" = 1 ] && [ "$(jcount '"m": "GET", "p": "/v1/secret/data/stoa/envs/rec/wm-admin"')" = 1 ] \
  && ok "A.1i journal : 1 lookup-self, 1 capabilities-self, 1 GET du ticket — rien d'autre ($(grep -c . "$STUB_LOG") appels)" || bad "A.1i journal inattendu : $(cat "$STUB_LOG")"
[ "$(jcaps_paths | wc -l | tr -d ' ')" = 1 ] && [ "$(jcaps_paths)" = secret/data/stoa/envs/rec/wm-admin ] && ok "A.1j capabilities-self sonde UN chemin (le ticket) en mode idp" || bad "A.1j chemins sondés : $(jcaps_paths | tr '\n' ' ')"
[ "$(grep -c . "$STUB_LOG")" -ge 3 ] && [ "$(grep -c '"tok": "stub-token-abc"' "$STUB_LOG")" = "$(grep -c . "$STUB_LOG")" ] && ok "A.1k le token arrive par l'EN-TÊTE sur chaque appel (contenu du fichier), jamais ailleurs" || bad "A.1k un appel sans le token en en-tête"
grep -rl 'SECRET-BODY-DO-NOT-STORE' "$TMP" 2>/dev/null | grep -v 'http.log\|stub.py' | grep -q . \
  && bad "A.1l le CORPS du ticket (le credential d'admin) a été écrit quelque part : $(grep -rl 'SECRET-BODY-DO-NOT-STORE' "$TMP" | grep -v 'http.log\|stub.py' | tr '\n' ' ')" \
  || ok "A.1l le corps du ticket n'a atterri dans aucun fichier"
grep -q 'SECRET-BODY-DO-NOT-STORE' "$TMP/g.out" && bad "A.1m le corps du ticket est sur stdout" || ok "A.1m aucun secret sur stdout"

echo "── A.2/A.3/A.4 la base par palier ──"
run_gate rec "APIM_API_BASE=http://gw-__ENV__.test/rest/apigateway"
[ "$(grc)" = 0 ] && [ "$(out_val APIM_API_BASE)" = "http://gw-rec.test/rest/apigateway" ] && ok "A.2 __ENV__ substitué dans la base directe" || bad "A.2 base : $(out_val APIM_API_BASE) (rc $(grc))"
set_ctl "$CTL_OK"; run_gate rec ADMIN_VIA=proxy-oauth2
[ "$(grc)" = 0 ] && [ "$(out_val APIM_API_BASE)" = "http://webmethods-real:5555/gateway/wm-admin-rec/1.0/rest/apigateway" ] && [ "$(out_val APIM_AUTH_MODE)" = oauth2 ] && [ "$(out_val PALIER_VIA)" = proxy-oauth2 ] \
  && ok "A.3 proxy-oauth2 : base composée wm-admin-rec (= APIM_API_BASE_TPL de team-promote), oauth2" || bad "A.3 proxy : $(out_val APIM_API_BASE) $(out_val APIM_AUTH_MODE) (rc $(grc))"
[ "$(jcount '"m": "GET", "p": "/v1/secret/data/stoa/envs/rec/wm-admin"')" = 1 ] && [ "$(out_val APIM_OAUTH_SUB)" = envs/rec/admin-oauth ] && ok "A.3b en proxy, le ticket reste wm-admin (parité §7.b) et le rôle relira envs/rec/admin-oauth" || bad "A.3b ticket/oauth sub en proxy"
run_gate rec ADMIN_VIA=proxy-oauth2 "APIM_PROXY_BASE=https://apim-__ENV__.corp/admin"
[ "$(grc)" = 0 ] && [ "$(out_val APIM_API_BASE)" = "https://apim-rec.corp/admin" ] && ok "A.4 APIM_PROXY_BASE (override complet) substitué" || bad "A.4 override : $(out_val APIM_API_BASE)"

echo "── A.5 préfixe vide, mount client ──"
set_ctl '{"lookup":{"policies":["deploy-banking-demo","default"]},"caps":{"paths":{"secret_DEV/data/APIM-rec-ADMIN":["read"]}},"kv":{"secret_DEV/data/APIM-rec-ADMIN":200}}'
run_gate rec APIM_KV_MOUNT=secret_DEV APIM_KV_PREFIX= APIM_WM_CREDS_SUB_TPL=APIM-__ENV__-ADMIN APIM_OAUTH_SUB_TPL=APIM-__ENV__-OAUTH
[ "$(grc)" = 0 ] && [ "$(out_val PALIER_TICKET)" = secret_DEV/data/APIM-rec-ADMIN ] && ok "A.5 préfixe vide + mount client ⇒ ticket secret_DEV/data/APIM-rec-ADMIN (segments vides élidés, comme le rôle)" || bad "A.5 ticket : $(out_val PALIER_TICKET) (rc $(grc))"
run_gate rec APIM_KV_MOUNT=secret_DEV UNSET:APIM_KV_PREFIX APIM_WM_CREDS_SUB_TPL=APIM-__ENV__-ADMIN APIM_OAUTH_SUB_TPL=APIM-__ENV__-OAUTH
[ "$(grc)" = 0 ] && [ "$(out_val PALIER_TICKET)" = secret_DEV/data/APIM-rec-ADMIN ] && ok "A.5b APIM_KV_PREFIX ABSENT de l'env ⇒ même chemin (défaut VIDE, jamais stoa — Jenkins n'exporte pas une variable vide)" || bad "A.5b défaut de préfixe : $(out_val PALIER_TICKET) (rc $(grc))"

echo "── A.6 namespace ──"
set_ctl "$CTL_OK"; run_gate rec VAULT_NAMESPACE=ns1
[ "$(grc)" = 0 ] && [ "$(grep -c '"ns": "ns1"' "$STUB_LOG")" = "$(grep -c . "$STUB_LOG")" ] && ok "A.6 X-Vault-Namespace sur chaque appel" || bad "A.6 namespace absent d'un appel"

echo "── A.7–A.12 l'équipe, décidée par le token ──"
man_idp "$TMP/man-pt.yml" payments-team
run_gate rec APIM_TEAM=banking-demo "MANIFEST=$TMP/man-pt.yml"
[ "$(grc)" = 0 ] && [ "$(out_val PALIER_TEAM)" = banking-demo ] && ok "A.7 APIM_TEAM prime sur le manifeste, et ∈ token ⇒ banking-demo" || bad "A.7 rc $(grc) team $(out_val PALIER_TEAM)"
run_gate rec APIM_TEAM=payments-team
refus TEAM_NON_PORTEE && ok "A.7b APIM_TEAM hors des tenants du token ⇒ TEAM_NON_PORTEE" || bad "A.7b rc $(grc) : $(gout | tail -1)"
run_gate rec "MANIFEST=$TMP/man-pt.yml"
refus TEAM_NON_PORTEE && ok "A.8 manifeste team: payments-team, token deploy-banking-demo ⇒ TEAM_NON_PORTEE (le manifeste ne choisit pas)" || bad "A.8 rc $(grc) : $(gout | tail -1)"
[ ! -f "$OUTF" ] && ok "A.8b aucun PALIER_OUT sur refus" || bad "A.8b PALIER_OUT écrit malgré le refus"
man_idp "$TMP/man-noteam.yml" ""
run_gate rec "MANIFEST=$TMP/man-noteam.yml"
[ "$(grc)" = 0 ] && [ "$(out_val PALIER_TEAM)" = banking-demo ] && ok "A.9 manifeste sans team ⇒ l'unique deploy-* du token (banking-demo)" || bad "A.9 rc $(grc) team $(out_val PALIER_TEAM)"
set_ctl '{"lookup":{"policies":["deploy-banking-demo","deploy-payments-team","default"]},"caps":{"paths":{"secret/data/stoa/envs/rec/wm-admin":["read"]}},"kv":{"secret/data/stoa/envs/rec/wm-admin":200}}'
run_gate rec "MANIFEST=$TMP/man-noteam.yml"
refus TEAM_AMBIGUE && ok "A.10 deux tenants sur le token, aucun nom ⇒ TEAM_AMBIGUE" || bad "A.10 rc $(grc) : $(gout | tail -1)"
run_gate rec "MANIFEST=$TMP/man-pt.yml"
[ "$(grc)" = 0 ] && [ "$(out_val PALIER_TEAM)" = payments-team ] && ok "A.10b deux tenants + manifeste payments-team (∈ token) ⇒ payments-team" || bad "A.10b rc $(grc) team $(out_val PALIER_TEAM)"
set_ctl '{"lookup":{"policies":["default","apply-rec"]},"caps":{"paths":{"secret/data/stoa/envs/rec/wm-admin":["read"]}},"kv":{"secret/data/stoa/envs/rec/wm-admin":200}}'
run_gate rec "MANIFEST=$TMP/man-noteam.yml"
refus TEAM_INDETERMINEE && ok "A.11 aucune deploy-* et aucun nom ⇒ TEAM_INDETERMINEE" || bad "A.11 rc $(grc) : $(gout | tail -1)"
set_ctl '{"lookup":{"code":403},"caps":{"paths":{}},"kv":{}}'
run_gate rec
refus IDENTITE_INVERIFIABLE && [ "$(jcount capabilities-self)" = 0 ] && [ "$(jcount '"m": "GET", "p": "/v1/secret')" = 0 ] \
  && ok "A.12 lookup-self 403 ⇒ IDENTITE_INVERIFIABLE, ni capabilities ni lecture KV ensuite" || bad "A.12 rc $(grc) : $(gout | tail -1) ; journal $(cat "$STUB_LOG" | tr '\n' ' ')"

echo "── A.13–A.15 les capacités ──"
set_ctl '{"lookup":{"policies":["deploy-banking-demo","default"]},"caps":{"paths":{"secret/data/stoa/envs/rec/wm-admin":["create","read","update"]}},"kv":{"secret/data/stoa/envs/rec/wm-admin":200}}'
geste rec
refus TICKET_INSCRIPTIBLE && [ "$(jcount '"m": "GET", "p": "/v1/secret')" = 0 ] && [ "$(canary_hits rec)" = 1 ] \
  && ok "A.13 ticket inscriptible (create/update) ⇒ TICKET_INSCRIPTIBLE, aucun GET du ticket, canari inchangé" || bad "A.13 rc $(grc) : $(gout | tail -1)"
set_ctl '{"lookup":{"policies":["deploy-banking-demo","default"]},"caps":{"paths":{"secret/data/stoa/envs/rec/wm-admin":["read","delete"]}},"kv":{"secret/data/stoa/envs/rec/wm-admin":200}}'
run_gate rec
refus TICKET_INSCRIPTIBLE && ok "A.13b ticket effaçable (delete) ⇒ TICKET_INSCRIPTIBLE" || bad "A.13b rc $(grc) : $(gout | tail -1)"
man_internal "$TMP/man-int.yml" deploy/banking-demo/apps/appa/dev/oauth-client deploy/banking-demo/apps/appa/rec/oauth-client
set_ctl '{"lookup":{"policies":["deploy-banking-demo","default"]},"caps":{"paths":{"secret/data/stoa/envs/rec/wm-admin":["read"],"secret/data/stoa/deploy/banking-demo/apps/appa/rec/oauth-client":["create","read","update"]}},"kv":{"secret/data/stoa/envs/rec/wm-admin":200}}'
run_gate rec "MANIFEST=$TMP/man-int.yml"
[ "$(grc)" = 0 ] && ok "A.14 mode internal, écriture possible sur le vault_sub de rec ⇒ rc 0" || bad "A.14 rc $(grc) : $(gout | tail -1)"
jcaps_paths > "$TMP/caps.paths"
grep -qx 'secret/data/stoa/deploy/banking-demo/apps/appa/rec/oauth-client' "$TMP/caps.paths" && ! grep -q '/dev/oauth-client' "$TMP/caps.paths" \
  && ok "A.14a le chemin sondé est le vault_sub du PALIER (per_env.rec fusionné), pas celui de la racine" || bad "A.14a chemins sondés : $(tr '\n' ' ' < "$TMP/caps.paths")"
[ "$(wc -l < "$TMP/caps.paths" | tr -d ' ')" = 2 ] && ok "A.14b en mode internal, DEUX chemins sondés (ticket + vault_sub) en UN appel" || bad "A.14b $(wc -l < "$TMP/caps.paths") chemin(s)"
set_ctl '{"lookup":{"policies":["deploy-banking-demo","default"]},"caps":{"paths":{"secret/data/stoa/envs/rec/wm-admin":["read"],"secret/data/stoa/deploy/banking-demo/apps/appa/rec/oauth-client":["read"]}},"kv":{"secret/data/stoa/envs/rec/wm-admin":200}}'
geste rec "MANIFEST=$TMP/man-int.yml"
refus TENANT_NON_PORTE && [ "$(jcount '"m": "GET", "p": "/v1/secret')" = 0 ] && [ "$(canary_hits rec)" = 1 ] \
  && ok "A.14c mode internal sans create/update sur le vault_sub ⇒ TENANT_NON_PORTE, aucun GET, canari inchangé" || bad "A.14c rc $(grc) : $(gout | tail -1)"
set_ctl '{"lookup":{"policies":["deploy-banking-demo","default"]},"caps":{"code":403},"kv":{"secret/data/stoa/envs/rec/wm-admin":200}}'
run_gate rec
refus CAPACITES_INVERIFIABLES && grep -q 'default' "$TMP/g.out" && ok "A.15 capabilities-self 403 ⇒ CAPACITES_INVERIFIABLES (le message nomme la policy default)" || bad "A.15 rc $(grc) : $(gout | tail -1)"

echo "── A.16 PALIER_FERME ──"
set_ctl "$CTL_OK"
man_idp "$MAN" banking-demo
geste int
refus PALIER_FERME && grep -q 'HTTP 403' "$TMP/g.out" && grep -q 'envs/int/wm-admin' "$TMP/g.out" && ok "A.16 token de rec, palier int ⇒ PALIER_FERME (HTTP 403, envs/int/wm-admin nommé)" || bad "A.16 rc $(grc) : $(gout | tail -1)"
[ "$(canary_hits int)" = 0 ] && ok "A.16a canari MUET : aucune requête gateway sans le credential du palier" || bad "A.16a le canari a vu passer une requête"
[ ! -f "$OUTF" ] && ok "A.16b aucun PALIER_OUT" || bad "A.16b PALIER_OUT écrit"
set_ctl '{"lookup":{"policies":["deploy-banking-demo","default"]},"caps":{"paths":{"secret/data/stoa/envs/rec/wm-admin":["read"]}},"kv":{"secret/data/stoa/envs/rec/wm-admin":404}}'
geste rec; refus PALIER_FERME && grep -q 'HTTP 404' "$TMP/g.out" && [ "$(canary_hits rec)" = 1 ] && ok "A.16c 404 ⇒ PALIER_FERME, canari inchangé" || bad "A.16c rc $(grc) : $(gout | tail -1)"
set_ctl '{"lookup":{"policies":["deploy-banking-demo","default"]},"caps":{"paths":{"secret/data/stoa/envs/rec/wm-admin":["read"]}},"kv":{"secret/data/stoa/envs/rec/wm-admin":500}}'
geste rec; refus PALIER_FERME && grep -q 'HTTP 500' "$TMP/g.out" && [ "$(canary_hits rec)" = 1 ] && ok "A.16d 500 ⇒ PALIER_FERME, canari inchangé" || bad "A.16d rc $(grc) : $(gout | tail -1)"
geste rec "VAULT_ADDR=http://127.0.0.1:1"
[ "$(grc)" = 1 ] && grep -Eq '^REFUS: (IDENTITE_INVERIFIABLE|PALIER_FERME) :' "$TMP/g.out" && [ "$(canary_hits rec)" = 1 ] && ok "A.16e Vault muet ⇒ refus nommé fermé, canari inchangé" || bad "A.16e rc $(grc) : $(gout | tail -1)"

echo "── A.17 le terminus, par position ──"
set_ctl "$CTL_OK"
run_gate prod
refus TERMINUS_SANS_VOIE && [ "$(grep -c . "$STUB_LOG")" = 0 ] && ok "A.17 prod sans APIM_TERMINUS_BASE ⇒ TERMINUS_SANS_VOIE, AUCUN appel Vault" || bad "A.17 rc $(grc) : $(gout | tail -1) ; journal $(grep -c . "$STUB_LOG")"
run_gate prod ADMIN_VIA=proxy-oauth2 "APIM_TERMINUS_BASE=http://prod-gw/rest/apigateway"
refus PALIER_FERME && ok "A.17b terminus déclaré, ticket 403 ⇒ PALIER_FERME (le credential décide)" || bad "A.17b rc $(grc) : $(gout | tail -1)"
set_ctl '{"lookup":{"policies":["deploy-banking-demo","operator-deploy","default"]},"caps":{"paths":{"secret/data/stoa/envs/prod/wm-admin":["read"]}},"kv":{"secret/data/stoa/envs/prod/wm-admin":200}}'
run_gate prod ADMIN_VIA=proxy-oauth2 "APIM_TERMINUS_BASE=http://prod-gw/rest/apigateway"
[ "$(grc)" = 0 ] && [ "$(out_val PALIER_VIA)" = direct ] && [ "$(out_val APIM_AUTH_MODE)" = basic ] && [ "$(out_val APIM_API_BASE)" = "http://prod-gw/rest/apigateway" ] \
  && ok "A.17c terminus ouvert par le credential ⇒ via FORCÉE direct malgré ADMIN_VIA=proxy-oauth2, base = APIM_TERMINUS_BASE" || bad "A.17c rc $(grc) via $(out_val PALIER_VIA) base $(out_val APIM_API_BASE)"

echo "── A.18–A.23 la forme, avant tout réseau ──"
set_ctl "$CTL_OK"
run_gate ""; refus ENV_INVALIDE && [ "$(grep -c . "$STUB_LOG")" = 0 ] && ok "A.18 ENVIRONMENT vide ⇒ ENV_INVALIDE, aucun appel" || bad "A.18 rc $(grc) : $(gout | tail -1)"
run_gate preprod; refus ENV_INVALIDE && [ "$(grep -c . "$STUB_LOG")" = 0 ] && ok "A.18b palier hors chaîne ⇒ ENV_INVALIDE" || bad "A.18b rc $(grc) : $(gout | tail -1)"
run_gate 'rec;rm'; refus ENV_INVALIDE && [ "$(grep -c . "$STUB_LOG")" = 0 ] && ok "A.18c palier hors forme ⇒ ENV_INVALIDE" || bad "A.18c rc $(grc) : $(gout | tail -1)"
run_gate rec ADMIN_VIA=ssh; refus VIA_INCONNU && [ "$(grep -c . "$STUB_LOG")" = 0 ] && ok "A.19 ADMIN_VIA=ssh ⇒ VIA_INCONNU" || bad "A.19 rc $(grc) : $(gout | tail -1)"
run_gate rec APIM_WM_CREDS_SUB_TPL=deploy/banking-demo/wm-admin; refus CREDS_SUB_SANS_PALIER && [ "$(grep -c . "$STUB_LOG")" = 0 ] && ok "A.20 gabarit wm-admin sans __ENV__ ⇒ CREDS_SUB_SANS_PALIER" || bad "A.20 rc $(grc) : $(gout | tail -1)"
run_gate rec APIM_OAUTH_SUB_TPL=gateways/webmethods/admin-oauth; refus CREDS_SUB_SANS_PALIER && ok "A.20b gabarit admin-oauth sans __ENV__ ⇒ CREDS_SUB_SANS_PALIER" || bad "A.20b rc $(grc) : $(gout | tail -1)"
run_gate rec APIM_API_BASE=gw.test/rest; refus APIM_BASE_INVALIDE && ok "A.21 base sans schéma ⇒ APIM_BASE_INVALIDE" || bad "A.21 rc $(grc) : $(gout | tail -1)"
run_gate rec "MANIFEST=$TMP/absent.yml"; refus MANIFESTE_ILLISIBLE && ok "A.22 manifeste absent ⇒ MANIFESTE_ILLISIBLE" || bad "A.22 rc $(grc) : $(gout | tail -1)"
printf 'apim_ss_app: [\n' > "$TMP/broken.yml"; run_gate rec "MANIFEST=$TMP/broken.yml"; refus MANIFESTE_ILLISIBLE && ok "A.22b YAML cassé ⇒ MANIFESTE_ILLISIBLE" || bad "A.22b rc $(grc) : $(gout | tail -1)"
printf 'apim_ss_app:\n  api: x\n' > "$TMP/noname.yml"; run_gate rec "MANIFEST=$TMP/noname.yml"; refus MANIFESTE_ILLISIBLE && ok "A.22c sans name ⇒ MANIFESTE_ILLISIBLE" || bad "A.22c rc $(grc) : $(gout | tail -1)"
printf 'apim_ss_app:\n  name: appa\n  team: "banking-demo\\nX=1"\n' > "$TMP/nl.yml"; run_gate rec "MANIFEST=$TMP/nl.yml"; refus MANIFESTE_ILLISIBLE && ok "A.22d team avec saut de ligne ⇒ MANIFESTE_ILLISIBLE" || bad "A.22d rc $(grc) : $(gout | tail -1)"
: > "$TMP/tok-empty"; run_gate rec "VAULT_TOKEN_FILE=$TMP/tok-empty"; refus VAULT_TOKEN_ILLISIBLE && ok "A.23 token vide ⇒ VAULT_TOKEN_ILLISIBLE" || bad "A.23 rc $(grc) : $(gout | tail -1)"
run_gate rec UNSET:VAULT_TOKEN_FILE; refus CABLAGE_INCOMPLET && ok "A.23b VAULT_TOKEN_FILE absent ⇒ CABLAGE_INCOMPLET" || bad "A.23b rc $(grc) : $(gout | tail -1)"
run_gate rec UNSET:PALIER_OUT; refus CABLAGE_INCOMPLET && ok "A.23c PALIER_OUT absent ⇒ CABLAGE_INCOMPLET" || bad "A.23c rc $(grc) : $(gout | tail -1)"
printf 'PALIER_TEAM=faux\n' > "$OUTF"
env ENVIRONMENT=int ADMIN_VIA=direct VAULT_ADDR="$VA" VAULT_TOKEN_FILE="$TMP/tok" PALIER_OUT="$OUTF" MANIFEST="$MAN" APIM_KV_PREFIX=stoa STOA_ENV_CHAIN_FILE="$TMP/chain.yaml" bash "$GATE" > "$TMP/g.out" 2>&1; echo $? > "$TMP/g.rc"
refus PALIER_FERME && [ ! -f "$OUTF" ] && ok "A.24 un PALIER_OUT périmé est RETIRÉ avant le verdict (aucun fichier après un refus)" || bad "A.24 rc $(grc), fichier $( [ -f "$OUTF" ] && echo présent || echo absent )"

echo "── A.25 concordance avec la rétention posée (G4) ──"
bash scripts/setup-vault-paliers.sh --print > "$TMP/svp.print" 2>&1
grep -q 'path "secret/data/stoa/envs/rec/wm-admin" { capabilities = \["read"\] }' "$TMP/svp.print" \
  && ok "A.25 le ticket par défaut (secret/data/stoa/envs/rec/wm-admin) est EXACTEMENT le chemin read de la policy apply-rec émise par setup-vault-paliers.sh" \
  || bad "A.25 la policy apply-rec émise ne porte pas ce chemin : $(grep 'envs/rec' "$TMP/svp.print" | head -2 | tr '\n' ' ')"

echo "── A.26 vue code du script ──"
sed -E 's@^[[:space:]]*#.*$@@' "$GATE" > "$TMP/gate.code"
grep -q 'X-Vault-Token' "$TMP/gate.code" && ! grep -q -- '-H "X-Vault-Token\|-H '"'"'X-Vault-Token' "$TMP/gate.code" \
  && ok "A.26 X-Vault-Token n'apparaît que dans l'écriture du fichier d'en-tête, jamais en argument -H" || bad "A.26 un -H X-Vault-Token en argv"
grep -q -- '-o /dev/null -w .%{http_code}. "\${VAULT_ADDR}/v1/\${TICKET_PATH}"' "$TMP/gate.code" \
  && ok "A.26b le GET du ticket écrit son corps sur /dev/null" || bad "A.26b le GET du ticket ne jette pas son corps"
[ -s "$TMP/gate.code" ] && ! grep -qw 'eval' "$TMP/gate.code" && ok "A.26c aucun eval (vue code non vide)" || bad "A.26c eval présent, ou vue code vide"
grep -q 'set +x' "$TMP/gate.code" && ok "A.26d set +x (jamais de trace)" || bad "A.26d set +x absent"

echo "── A.27 mutations ──"
mutant(){ # <sed-expr> <nom> → $TMP/<nom>.sh ; rc 0 si le mutant diffère et parse
  sed -E "$1" "$GATE" > "$TMP/$2.sh"
  if cmp -s "$GATE" "$TMP/$2.sh"; then bad "A.27 mutation $2 NO-OP (l'ancre a bougé)"; return 1; fi
  bash -n "$TMP/$2.sh" 2>/dev/null || { bad "A.27 mutant $2 ne parse pas"; return 1; }
  return 0
}
# le mutant s'exécute depuis le dossier scripts/ pour retrouver lib/env-chain.sh
mkdir -p "$TMP/mut/scripts/lib"; cp scripts/lib/env-chain.sh "$TMP/mut/scripts/lib/"
run_mut(){ local m="$1"; shift; cp "$TMP/$m.sh" "$TMP/mut/scripts/gate.sh"; GATE_BIN="$TMP/mut/scripts/gate.sh" run_gate "$@"; }
set_ctl "$CTL_OK"
if mutant 's@^\[ "\$TC" = 200 \] \|\| refus PALIER_FERME.*$@: # ticket retiré@' m_ticket; then
  run_mut m_ticket int; [ "$(grc)" = 0 ] && ok "A.27i ticket retiré ⇒ le palier int PASSE sur le mutant (le détecteur A.16 verrait rouge)" || bad "A.27i le mutant refuse encore : $(gout | tail -1)"
  run_gate int; refus PALIER_FERME && ok "A.27i' l'original refuse toujours PALIER_FERME" || bad "A.27i' l'original a dérivé"
fi
if mutant 's@refus CREDS_SUB_SANS_PALIER "APIM_WM_CREDS_SUB_TPL@: "@' m_envtpl; then
  set_ctl '{"lookup":{"policies":["deploy-banking-demo","default"]},"caps":{"paths":{"secret/data/stoa/deploy/banking-demo/wm-admin":["read"]}},"kv":{"secret/data/stoa/deploy/banking-demo/wm-admin":200}}'
  run_mut m_envtpl rec APIM_WM_CREDS_SUB_TPL=deploy/banking-demo/wm-admin; [ "$(grc)" = 0 ] && ok "A.27ii contrôle __ENV__ retiré ⇒ le gabarit trans-paliers PASSE sur le mutant" || bad "A.27ii le mutant refuse encore : $(gout | tail -1)"
  run_gate rec APIM_WM_CREDS_SUB_TPL=deploy/banking-demo/wm-admin; refus CREDS_SUB_SANS_PALIER && ok "A.27ii' l'original refuse toujours" || bad "A.27ii' l'original a dérivé"
fi
if mutant 's@if t \& \{"create", "update", "delete", "patch"\}: print\("TICKET_INSCRIPTIBLE"\); raise SystemExit@pass@' m_inscr; then
  set_ctl '{"lookup":{"policies":["deploy-banking-demo","default"]},"caps":{"paths":{"secret/data/stoa/envs/rec/wm-admin":["create","read","update"]}},"kv":{"secret/data/stoa/envs/rec/wm-admin":200}}'
  run_mut m_inscr rec; [ "$(grc)" = 0 ] && ok "A.27iii contrôle d'inscriptibilité retiré ⇒ le ticket auto-fabriqué PASSE sur le mutant" || bad "A.27iii le mutant refuse encore : $(gout | tail -1)"
  run_gate rec; refus TICKET_INSCRIPTIBLE && ok "A.27iii' l'original refuse toujours" || bad "A.27iii' l'original a dérivé"
fi
if mutant 's@^printf .%s\\n. "\$S" \| grep -qx -- "\$TEAM" \\$@true \\@' m_team; then
  set_ctl "$CTL_OK"
  run_mut m_team rec "MANIFEST=$TMP/man-pt.yml"; [ "$(grc)" = 0 ] && ok "A.27iv TEAM ∈ S retiré ⇒ le manifeste d'une autre équipe PASSE sur le mutant" || bad "A.27iv le mutant refuse encore : $(gout | tail -1)"
  run_gate rec "MANIFEST=$TMP/man-pt.yml"; refus TEAM_NON_PORTEE && ok "A.27iv' l'original refuse toujours" || bad "A.27iv' l'original a dérivé"
fi
if mutant 's@if v and not \(set\(caps.get\(v\) or \[\]\) \& \{"create", "update"\}\): print\("TENANT_NON_PORTE"\); raise SystemExit@pass@' m_vsub; then
  set_ctl '{"lookup":{"policies":["deploy-banking-demo","default"]},"caps":{"paths":{"secret/data/stoa/envs/rec/wm-admin":["read"],"secret/data/stoa/deploy/banking-demo/apps/appa/rec/oauth-client":["read"]}},"kv":{"secret/data/stoa/envs/rec/wm-admin":200}}'
  run_mut m_vsub rec "MANIFEST=$TMP/man-int.yml"; [ "$(grc)" = 0 ] && ok "A.27v sonde vault_sub retirée ⇒ le tenant non porté PASSE sur le mutant" || bad "A.27v le mutant refuse encore : $(gout | tail -1)"
  run_gate rec "MANIFEST=$TMP/man-int.yml"; refus TENANT_NON_PORTE && ok "A.27v' l'original refuse toujours" || bad "A.27v' l'original a dérivé"
fi
if mutant 's@^if \[ "\$ENVIRONMENT" = "\$TERMINUS" \]; then$@if false; then@' m_term; then
  set_ctl '{"lookup":{"policies":["deploy-banking-demo","operator-deploy","default"]},"caps":{"paths":{"secret/data/stoa/envs/prod/wm-admin":["read"]}},"kv":{"secret/data/stoa/envs/prod/wm-admin":200}}'
  run_mut m_term prod ADMIN_VIA=proxy-oauth2 "APIM_TERMINUS_BASE=http://prod-gw/rest/apigateway"
  [ "$(grc)" = 0 ] && [ "$(out_val PALIER_VIA)" = proxy-oauth2 ] && ok "A.27vi position du terminus retirée ⇒ le terminus compose une base PROXY sur le mutant (l'original force direct)" || bad "A.27vi mutant : rc $(grc) via $(out_val PALIER_VIA)"
fi

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
