#!/usr/bin/env bash
# test-app-request-a7.sh — A7 (GOAL cd-applications) : LA DEMANDE SOUS IDENTITÉ DE
# FORGE, les références à la demande, la chaîne entière — HORS LIGNE, fixture d'A6 :
# un dépôt nu servi en file://, un stub de forge à JOURNAL (GET /user décidé par le
# token, /pulls?state=open piloté par ctl.json, POST /pulls ⇒ 201 avec l'en-tête
# Authorization journalisé), un shim git qui journalise argv ET l'environnement
# (le token humain ne doit atteindre aucun processus enfant), cinq mutations.
# Spec : docs/superpowers/specs/2026-09-03-a7-terminus-et-parcours-design.md (D7).
#
#   E0  la lib seule (login, 401/403/réseau/classe)
#   E1  rec + refs sous ci : la ligne per_env porte change_ref/pv_ref, rien d'autre ne bouge
#   E2  homol sans pv_ref ⇒ GATE_REFS_REQUIRED avant tout clone ; avec ⇒ REQUESTER_UNKNOWN
#   E3  int sans humain ⇒ REQUESTER_UNKNOWN sans appel ; token d'un compte de service ⇒ idem
#   E4  int + token d'alice ⇒ PR ouverte SOUS alice, trailer, token jamais en argv/env
#   E5  rejeu sous alice ⇒ EXIST ; rejeu sous ci ⇒ REQUESTER_UNKNOWN
#   E6  PR ouverte d'autrui ⇒ PR_D_AUTRUI ; repli ouvert ⇒ REPLI_EN_COURS ; forge muette ⇒ FORGE_ILLISIBLE
#   E7  prod sous ci sans refs ⇒ GATE_REFS_REQUIRED ; E8 zeta ⇒ ENV_INVALIDE ; refs hors classe ⇒ REF_INVALIDE
#   E10 le token n'apparaît jamais dans la sortie d'un push en échec
#   M   mutations : chaque garde neuve attrape ce qu'elle prétend attraper
# `A && ok || ko` (SC2015) et les `$…` en quotes simples (SC2016) sont l'idiome des suites du repo.
# shellcheck disable=SC2015,SC2016
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
S="$REPO/scripts/provision-request.sh"
LIB="$REPO/scripts/lib/forge-identity.sh"
TMP="$(mktemp -d /tmp/apprq7.XXXXXX)"
PASS=0; FAIL=0; PIDS=""
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
cleanup(){ for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM
# shellcheck source=scripts/lib/app-manifest.sh
. "$REPO/scripts/lib/app-manifest.sh" || { echo "!! lib app-manifest absente"; exit 2; }

# ── le stub de forge ─────────────────────────────────────────────────────────
STUB_CTL="$TMP/ctl.json"; STUB_LOG="$TMP/http.log"; STUB_POSTED="$TMP/posted.jsonl"; : > "$STUB_LOG"; : > "$STUB_POSTED"
cat > "$TMP/stub.py" <<'PY'
import json, os, re, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
CTL, LOG, POSTED = os.environ["STUB_CTL"], os.environ["STUB_LOG"], os.environ["STUB_POSTED"]
TOKENS = {"t-ci": "ci", "t-alice": "alice", "t-svc": "svc-bot", "t-noscope": None}
def ctl():
    try: return json.load(open(CTL))
    except Exception: return {}
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, *a): pass
    def _send(self, code, body):
        b = json.dumps(body).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def _route(self, method):
        u = urlparse(self.path); q = parse_qs(u.query); path = u.path
        auth = self.headers.get("Authorization", ""); tok = auth[len("token "):] if auth.startswith("token ") else ""
        alias = tok if tok in TOKENS else "?"
        with open(LOG, "a") as f: f.write("%s %s %s\n" % (method, path, alias))
        c = ctl()
        if c.get("down"): return self._send(500, {"message": "boom"})
        if tok not in TOKENS: return self._send(401, {"message": "token does not exist"})
        if path == "/api/v1/user":
            if TOKENS[tok] is None: return self._send(403, {"message": "token does not have at least one of required scope(s): [read:user]"})
            return self._send(200, {"login": c.get("login_override") or TOKENS[tok], "id": 7})
        m = re.match(r"^/api/v1/repos/[^/]+/[^/]+/pulls$", path)
        if m and method == "GET":
            state = (q.get("state") or ["open"])[0]; page = int((q.get("page") or ["1"])[0]); limit = int((q.get("limit") or ["50"])[0])
            items = c.get(state, [])
            return self._send(200, items[(page-1)*limit: page*limit])
        if m and method == "POST":
            n = int(self.headers.get("Content-Length") or 0); body = self.rfile.read(n) if n else b"{}"
            with open(POSTED, "a") as f: f.write(json.dumps({"auth": auth, "body": json.loads(body.decode() or "{}")}) + "\n")
            return self._send(201, {"number": 900, "html_url": "http://stub/pulls/900"})
        mc = re.match(r"^/api/v1/repos/[^/]+/[^/]+/issues/([0-9]+)/comments$", path)
        if mc: return self._send(200, [] if method == "GET" else {"id": 1})
        return self._send(404, {"message": "stub: route inconnue " + path})
    def do_GET(self): self._route("GET")
    def do_POST(self): self._route("POST")
    def do_PATCH(self): self._route("PATCH")
srv = ThreadingHTTPServer(("127.0.0.1", 0), H); print(srv.server_address[1], flush=True); srv.serve_forever()
PY
STUB_CTL="$STUB_CTL" STUB_LOG="$STUB_LOG" STUB_POSTED="$STUB_POSTED" python3 "$TMP/stub.py" > "$TMP/stub.port" 2>"$TMP/stub.err" &
PIDS="$PIDS $!"
for _ in $(seq 1 60); do [ -s "$TMP/stub.port" ] && break; sleep 0.1; done
PORT="$(head -n1 "$TMP/stub.port" 2>/dev/null)"; case "$PORT" in ''|*[!0-9]*) echo "!! stub non démarré : $(cat "$TMP/stub.err")"; exit 2;; esac
GH="http://127.0.0.1:$PORT"; API="$GH/api/v1"

# ── le shim git : journalise argv ET l'env des tokens ; peut faire échouer un push en « fuyant » le token ──
SHIM="$TMP/shim"; mkdir -p "$SHIM"; SHIM_LOG="$TMP/git.log"; : > "$SHIM_LOG"
REAL_GIT="$(command -v git)"
cat > "$SHIM/git" <<SH
#!/usr/bin/env bash
printf 'ARGV %s\n' "\$*" >> "$SHIM_LOG"
printf 'ENV FORGE_TOKEN=%s PUSH_TOKEN=%s FORGE_TOKEN_FILE=%s\n' "\${FORGE_TOKEN:-}" "\${PUSH_TOKEN:-}" "\${FORGE_TOKEN_FILE:-}" >> "$SHIM_LOG"
if [ -n "\${SHIM_PUSH_FAIL:-}" ] && [ "\${1:-}" = push ]; then
  # le mode de panne réel : git imprime l'URL ; ici on simule pire — le secret que rend l'askpass
  echo "fatal: unable to access (simulé) — askpass a rendu \$(sh "\${GIT_ASKPASS:-/bin/false}" Password 2>/dev/null)" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
SH
chmod 700 "$SHIM/git"

# ── la fixture git : nu + clone de construction (layout du dépôt plateforme) ──
ORIGIN="$TMP/origin.git"; W="$TMP/w"; SUB="poc-control-plane-federation"
git init -q --bare "$ORIGIN" && git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$W" && git -C "$W" checkout -q -b main
gw(){ git -C "$W" -c user.name=t -c user.email=t@t "$@"; }
MAN="$SUB/clients/provisioned/applications/appa.ansible.yml"
mkdir -p "$W/$SUB/ansible" "$W/$SUB/clients/provisioned/applications" "$W/$SUB/clients/_example"
for e in dev rec int homol prod; do printf 'providers:\n  - team: banking-demo\n    repo: ""\n    approvers: []\n' > "$W/$SUB/ansible/providers.$e.yml"; done
cp "$REPO/clients/_example/environments.yaml" "$TMP/chain.yaml"
cp "$TMP/chain.yaml" "$W/$SUB/clients/_example/environments.yaml"
printf 'init\n' > "$W/README"; gw add -A; gw commit -qm c0 >/dev/null
gw remote add origin "$ORIGIN"; gw push -q origin main
MAIN0=$(gw rev-parse main)
# plan enchaîné : un stub qui journalise SON environnement (le token humain ne doit pas y être)
PLAN_STUB="$TMP/plan-stub.sh"; PLAN_ENV="$TMP/plan.env"
printf '#!/usr/bin/env bash\nprintf "FORGE_TOKEN=%%s\\nGITEA_TOKEN=%%s\\nPUSH_TOKEN=%%s\\n" "${FORGE_TOKEN:-}" "${GITEA_TOKEN:-}" "${PUSH_TOKEN:-}" > "%s"\n' "$PLAN_ENV" > "$PLAN_STUB"; chmod 700 "$PLAN_STUB"

set_ctl(){ printf '%s' "$1" > "$STUB_CTL"; : > "$STUB_LOG"; : > "$STUB_POSTED"; : > "$SHIM_LOG"; rm -f "$PLAN_ENV"; }
reset_origin(){ git -C "$W" push -q -f origin "$MAIN0:main"; for b in dev rec int homol prod; do git -C "$ORIGIN" update-ref -d "refs/heads/provision/appa-$b" 2>/dev/null || true; done; }
merge_branch(){ # <env> : « le merge humain » de provision/appa-<env> dans main, dans le nu
  gw fetch -q origin && gw checkout -q main && gw reset -q --hard origin/main \
    && gw merge -q --no-ff -m "Merge pull request 'provision($1): appa' from provision/appa-$1 into main" "origin/provision/appa-$1" \
    && gw push -q origin main
}
# req <env> [VAR=val…] : le script sous test ; sortie $TMP/req.out, rc $TMP/req.rc
req(){
  local e="$1"; shift
  ( cd "$REPO" && env -i PATH="$SHIM:$PATH" HOME="$HOME" GITEA_TOKEN=t-ci GIT_HOST="$GH" GIT_WEB_HOST="$GH" GIT_REPO=ci/stoa-labs GIT_BASE=main \
      GIT_CLONE_URL="file://$ORIGIN" GIT_PUSH_URL="file://$ORIGIN" STOA_ENV_CHAIN_FILE="$TMP/chain.yaml" PROVISION_PLAN_INLINE=false \
      REQ_APP=appa REQ_ENV="$e" REQ_API=demo-selfservice REQ_API_VER=1.0.0 REQ_CLIENT_ID="appa-$e" REQ_CALLER=jenkins-form:x REQ_TEAM=banking-demo \
      "$@" bash "$S" ) > "$TMP/req.out" 2>&1
  echo $? > "$TMP/req.rc"
}
rrc(){ cat "$TMP/req.rc"; }
refus(){ [ "$(rrc)" = 2 ] && grep -qF "REFUS: $1" "$TMP/req.out"; }
posts(){ grep -c '^POST /api/v1/repos/ci/stoa-labs/pulls ' "$STUB_LOG" || true; }
users(){ grep -c '^GET /api/v1/user ' "$STUB_LOG" || true; }
post_auth(){ tail -1 "$STUB_POSTED" 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("auth",""))
except Exception: print("")'; }
post_body(){ tail -1 "$STUB_POSTED" 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["body"].get("body",""))
except Exception: print("")'; }
clones(){ grep -c '^ARGV clone' "$SHIM_LOG" || true; }
tip(){ git -C "$ORIGIN" rev-parse -q --verify "refs/heads/provision/appa-$1" 2>/dev/null || printf 'absente'; }
line_at(){ git -C "$ORIGIN" show "provision/appa-$1:$MAN" 2>/dev/null | grep -E "^    $1: "; }
trailer_at(){ git -C "$ORIGIN" log -1 --format=%B "provision/appa-$1" 2>/dev/null | sed -n 's/^Demande-Par: //p'; }
pr_open(){ # <n> <login> <env> → json d'une PR ouverte
  printf '{"number":%s,"state":"open","merged":false,"head":{"ref":"provision/appa-%s","sha":"deadbeef","repo":{"full_name":"ci/stoa-labs"}},"base":{"ref":"main"},"user":{"login":"%s"}}' "$1" "$3" "$2"
}

echo "═══ E0. la lib seule ═══"
bash -n "$LIB" && shellcheck -x "$LIB" >/dev/null 2>&1 && ok "E0.1 forge-identity.sh compile, shellcheck propre" || ko "E0.1 lib : bash -n / shellcheck"
# shellcheck source=scripts/lib/forge-identity.sh
. "$LIB"
set_ctl '{}'
printf 't-alice' > "$TMP/tok"; L=$(forge_login "$API" "$TMP/tok" 2>"$TMP/e0.err"); RC=$?
[ "$RC" = 0 ] && [ "$L" = alice ] && ok "E0.2 token d'alice ⇒ login alice (GET /user)" || ko "E0.2 rc=$RC login='$L' $(cat "$TMP/e0.err")"
printf 't-noscope' > "$TMP/tok"; forge_login "$API" "$TMP/tok" >/dev/null 2>"$TMP/e0.err"; RC=$?
[ "$RC" = 2 ] && grep -q 'REFUS: FORGE_SCOPE_INSUFFISANT' "$TMP/e0.err" && grep -q 'read:user' "$TMP/e0.err" && ok "E0.3 403 ⇒ rc 2 FORGE_SCOPE_INSUFFISANT nommant read:user" || ko "E0.3 rc=$RC : $(cat "$TMP/e0.err")"
printf 't-inconnu' > "$TMP/tok"; forge_login "$API" "$TMP/tok" >/dev/null 2>"$TMP/e0.err"; RC=$?
[ "$RC" = 2 ] && grep -q 'REFUS: FORGE_TOKEN_INVALIDE' "$TMP/e0.err" && ok "E0.4 401 ⇒ rc 2 FORGE_TOKEN_INVALIDE" || ko "E0.4 rc=$RC : $(cat "$TMP/e0.err")"
set_ctl '{"down":true}'; printf 't-alice' > "$TMP/tok"; forge_login "$API" "$TMP/tok" >/dev/null 2>"$TMP/e0.err"; RC=$?
[ "$RC" = 1 ] && grep -q '^ERREUR:' "$TMP/e0.err" && ok "E0.5 forge en erreur ⇒ rc 1 ERREUR (jamais un refus)" || ko "E0.5 rc=$RC : $(cat "$TMP/e0.err")"
set_ctl '{"login_override":"x/y"}'; forge_login "$API" "$TMP/tok" >/dev/null 2>"$TMP/e0.err"; RC=$?
[ "$RC" = 2 ] && grep -q 'REFUS: FORGE_LOGIN_INVALIDE' "$TMP/e0.err" && ok "E0.6 login hors classe ⇒ rc 2 FORGE_LOGIN_INVALIDE" || ko "E0.6 rc=$RC : $(cat "$TMP/e0.err")"
forge_is_service ci "ci svc-bot" && ! forge_is_service alice "ci svc-bot" && ok "E0.7 forge_is_service : ci oui, alice non" || ko "E0.7 forge_is_service"
A=$(forge_askpass "$TMP" alice "$TMP/tok"); [ "$(sh "$A" 'Username for x')" = alice ] && [ "$(sh "$A" 'Password for x')" = t-alice ] && [ "$(stat -f %Lp "$A" 2>/dev/null || stat -c %a "$A")" = 700 ] && ok "E0.8 askpass : login pour Username, token du fichier sinon, 0700" || ko "E0.8 askpass"

echo "═══ E1. rec + refs sous ci : la ligne per_env porte change_ref/pv_ref, rien d'autre ne bouge ═══"
set_ctl '{"open":[]}'; reset_origin
req dev
[ "$(rrc)" = 0 ] && [ "$(posts)" = 1 ] && [ "$(users)" = 0 ] && ok "E1a dev sous ci ⇒ PR postée, aucun GET /user (pas de token humain, pas de quatre yeux)" || ko "E1a rc $(rrc) posts=$(posts) users=$(users) : $(grep -E 'REFUS|ERREUR' "$TMP/req.out" | head -2 | tr '\n' ' ')"
merge_branch dev || ko "E1a' fixture : merge de dev"
git -C "$ORIGIN" show "main:$MAN" > "$TMP/man.dev.yml" 2>/dev/null
set_ctl '{"open":[]}'
req rec REQ_CHANGE_REF=CHG-0001 REQ_PV_REF=PV-A7
[ "$(rrc)" = 0 ] && ok "E1.1 rec + refs sous ci ⇒ rc 0" || ko "E1.1 rc $(rrc) : $(grep -E 'REFUS|ERREUR' "$TMP/req.out" | head -2 | tr '\n' ' ')"
[ "$(line_at rec)" = '    rec: { auth: { claim: { value: "appa-rec" } }, change_ref: "CHG-0001", pv_ref: "PV-A7" }' ] && ok "E1.2 ligne rec : claim, puis change_ref, puis pv_ref (quotés)" || ko "E1.2 ligne : $(line_at rec)"
git -C "$ORIGIN" show "provision/appa-rec:$MAN" > "$TMP/man.rec.yml" 2>/dev/null
[ "$(diff "$TMP/man.dev.yml" "$TMP/man.rec.yml" | grep -c '^[<>]')" = 1 ] && ok "E1.3 diff dev→rec = UNE ligne ajoutée (aucun autre octet)" || ko "E1.3 diff : $(diff "$TMP/man.dev.yml" "$TMP/man.rec.yml" | head -4 | tr '\n' ' ')"
post_body | grep -q 'ouverte par : compte de service' && post_body | grep -q -- '- change_ref : CHG-0001' && post_body | grep -q -- '- pv_ref : PV-A7' && ok "E1.4 corps de PR : « ouverte par : compte de service », change_ref, pv_ref" || ko "E1.4 corps : $(post_body | grep -E 'ouverte|change_ref|pv_ref' | tr '\n' ' ')"
[ "$(trailer_at rec)" = ci ] && ok "E1.5 trailer Demande-Par: ci sur la tête de branche" || ko "E1.5 trailer : '$(trailer_at rec)'"
set_ctl '{"open":[]}'; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec
req rec
[ "$(rrc)" = 0 ] && [ "$(line_at rec)" = '    rec: { auth: { claim: { value: "appa-rec" } } }' ] && ok "E1b rec sans refs ⇒ ligne octet pour octet celle d'avant A7" || ko "E1b rc $(rrc) ligne : $(line_at rec)"

echo "═══ E2. homol : GATE_REFS_REQUIRED avant tout clone ; puis REQUESTER_UNKNOWN ═══"
set_ctl '{"open":[]}'
req homol
refus GATE_REFS_REQUIRED && grep -q 'pv_ref' "$TMP/req.out" && [ "$(clones)" = 0 ] && ! grep -q '\[1/4\]' "$TMP/req.out" && ok "E2.1 homol sans pv_ref ⇒ GATE_REFS_REQUIRED (pv_ref nommé), aucun clone" || ko "E2.1 rc $(rrc) clones=$(clones) : $(tail -1 "$TMP/req.out")"
req homol REQ_PV_REF=PV-A7
refus REQUESTER_UNKNOWN && [ "$(clones)" = 0 ] && [ "$(users)" = 0 ] && ok "E2.2 homol + pv_ref sous ci ⇒ REQUESTER_UNKNOWN sans appel ni clone" || ko "E2.2 rc $(rrc) : $(tail -1 "$TMP/req.out")"

echo "═══ E3. int sans humain ═══"
req int
refus REQUESTER_UNKNOWN && [ "$(users)" = 0 ] && [ "$(clones)" = 0 ] && grep -q 'FORGE_TOKEN' "$TMP/req.out" && ok "E3.1 int sans token ⇒ REQUESTER_UNKNOWN, aucun GET /user, aucun clone, remède FORGE_TOKEN nommé" || ko "E3.1 rc $(rrc) users=$(users) : $(tail -1 "$TMP/req.out")"
req int FORGE_TOKEN=t-svc "GITEA_SERVICE_LOGINS=ci svc-bot"
refus REQUESTER_UNKNOWN && [ "$(users)" = 1 ] && [ "$(clones)" = 0 ] && ok "E3.2 token d'un compte de service listé (svc-bot) ⇒ GET /user puis REQUESTER_UNKNOWN (deux portes, une source)" || ko "E3.2 rc $(rrc) users=$(users) : $(tail -1 "$TMP/req.out")"
req int FORGE_TOKEN=t-noscope
refus FORGE_SCOPE_INSUFFISANT && [ "$(clones)" = 0 ] && ok "E3.3 token sans read:user ⇒ FORGE_SCOPE_INSUFFISANT à la demande" || ko "E3.3 rc $(rrc) : $(tail -1 "$TMP/req.out")"

echo "═══ E4. int + token d'alice : la PR est ouverte SOUS alice ═══"
set_ctl '{"open":[]}'
req int FORGE_TOKEN=t-alice PROVISION_PLAN_INLINE=true "PROVISION_PLAN_BIN=$PLAN_STUB"
[ "$(rrc)" = 0 ] && [ "$(posts)" = 1 ] && ok "E4.1 rc 0, une PR postée" || ko "E4.1 rc $(rrc) posts=$(posts) : $(grep -E 'REFUS|ERREUR' "$TMP/req.out" | head -2 | tr '\n' ' ')"
[ "$(post_auth)" = "token t-alice" ] && ok "E4.2 POST /pulls sous le token d'ALICE (l'auteur est l'humain)" || ko "E4.2 Authorization du POST : '$(post_auth)'"
post_body | grep -q 'ouverte par : alice (identite de forge' && ok "E4.3 corps : « ouverte par : alice (identite de forge …) »" || ko "E4.3 corps : $(post_body | grep -E 'ouverte' | tr '\n' ' ')"
[ "$(trailer_at int)" = alice ] && ok "E4.4 trailer Demande-Par: alice" || ko "E4.4 trailer : '$(trailer_at int)'"
! grep -q 't-alice' "$SHIM_LOG" && ok "E4.5 le token n'apparaît dans AUCUN argv git" || ko "E4.5 token en argv : $(grep -n 't-alice' "$SHIM_LOG" | head -1)"
! grep -qE 'ENV FORGE_TOKEN=[^ ]+' "$SHIM_LOG" && ! grep -qE 'PUSH_TOKEN=[^ ]+ ' "$SHIM_LOG" && ok "E4.6 aucun processus git n'hérite FORGE_TOKEN/PUSH_TOKEN (unset avant tout enfant)" || ko "E4.6 env hérité : $(grep -E 'ENV ' "$SHIM_LOG" | grep -vE 'FORGE_TOKEN= PUSH_TOKEN= ' | head -1)"
[ -f "$PLAN_ENV" ] && grep -qx 'FORGE_TOKEN=' "$PLAN_ENV" && grep -qx 'GITEA_TOKEN=t-ci' "$PLAN_ENV" && ok "E4.7 le plan enchaîné voit GITEA_TOKEN (ci) et PAS le token humain" || ko "E4.7 env du plan : $(cat "$PLAN_ENV" 2>/dev/null | tr '\n' ' ')"
! grep -q 't-alice' "$TMP/req.out" && ok "E4.8 la sortie du script ne porte pas le token" || ko "E4.8 token dans la sortie"
set_ctl '{"open":[]}'; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-int
printf 't-alice' > "$TMP/tokfile"; req int "FORGE_TOKEN_FILE=$TMP/tokfile"
[ "$(rrc)" = 0 ] && [ "$(post_auth)" = "token t-alice" ] && [ "$(trailer_at int)" = alice ] && ok "E4b FORGE_TOKEN_FILE ⇒ même identité (alice)" || ko "E4b rc $(rrc) auth='$(post_auth)'"

echo "═══ E5. le rejeu : sous alice ⇒ EXIST ; sous ci ⇒ REQUESTER_UNKNOWN ═══"
set_ctl "{\"open\":[$(pr_open 77 alice int)]}"
req int FORGE_TOKEN=t-alice
[ "$(rrc)" = 0 ] && grep -q 'PR déjà ouverte: #77' "$TMP/req.out" && [ "$(posts)" = 0 ] && [ "$(tip int)" = "$(tip int)" ] && ok "E5.1 rejeu sous alice (PR #77 d'alice ouverte, même contenu) ⇒ EXIST #77, aucun POST" || ko "E5.1 rc $(rrc) posts=$(posts) : $(grep -E 'PR |REFUS' "$TMP/req.out" | head -2 | tr '\n' ' ')"
T5=$(tip int); req int
refus REQUESTER_UNKNOWN && [ "$(tip int)" = "$T5" ] && ok "E5.2 rejeu sous ci ⇒ REQUESTER_UNKNOWN, tête distante inchangée" || ko "E5.2 rc $(rrc) : $(tail -1 "$TMP/req.out")"

echo "═══ E6. une PR ouverte n'appartient qu'à son auteur ═══"
set_ctl "{\"open\":[$(pr_open 78 ci rec)]}"; T6=$(tip rec)
req rec FORGE_TOKEN=t-alice
refus PR_D_AUTRUI && grep -q '#78' "$TMP/req.out" && grep -q "'ci'" "$TMP/req.out" && [ "$(tip rec)" = "$T6" ] && [ "$(posts)" = 0 ] && ok "E6.1 PR #78 de ci ouverte, demande d'alice ⇒ PR_D_AUTRUI (#78, ci), tête inchangée, aucun POST" || ko "E6.1 rc $(rrc) : $(tail -1 "$TMP/req.out")"
set_ctl "{\"open\":[$(pr_open 79 alice rec)]}"
req rec
refus PR_D_AUTRUI && grep -q "'alice'" "$TMP/req.out" && [ "$(tip rec)" = "$T6" ] && ok "E6.2 PR #79 d'alice ouverte, demande sous ci ⇒ PR_D_AUTRUI" || ko "E6.2 rc $(rrc) : $(tail -1 "$TMP/req.out")"
set_ctl "{\"open\":[$(pr_open 78 ci rec)]}"
req rec
[ "$(rrc)" = 0 ] && grep -q 'PR déjà ouverte: #78' "$TMP/req.out" && ok "E6.3 PR #78 de ci ouverte, demande sous ci ⇒ la sienne : EXIST #78" || ko "E6.3 rc $(rrc) : $(grep -E 'PR |REFUS' "$TMP/req.out" | head -2 | tr '\n' ' ')"
# repli ouvert (tête portant Repli-Vers:) + PR d'alice ⇒ REPLI_EN_COURS (quel que soit l'auteur)
gw fetch -q origin && gw checkout -q -B provision/appa-rec origin/main && gw commit -q --allow-empty -m "provision(rec): repli" -m "Repli-Vers: 0000000 (PR #1)" && gw push -q -f origin provision/appa-rec
set_ctl "{\"open\":[$(pr_open 80 alice rec)]}"; T6b=$(tip rec)
req rec FORGE_TOKEN=t-alice
refus REPLI_EN_COURS && [ "$(tip rec)" = "$T6b" ] && ok "E6.4 PR de repli ouverte par un HUMAIN ⇒ REPLI_EN_COURS (A6 étendu : l'auteur n'exonère plus)" || ko "E6.4 rc $(rrc) : $(tail -1 "$TMP/req.out")"
git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec; gw checkout -q main
set_ctl '{"down":true}'
req rec
[ "$(rrc)" = 2 ] && grep -qE 'REFUS: (FORGE_ILLISIBLE|REPLI_EN_COURS)' "$TMP/req.out" && [ "$(tip rec)" = absente ] && ok "E6.5 forge muette ⇒ refus fermé avant le push (une PR ouverte pourrait exister)" || ko "E6.5 rc $(rrc) tip=$(tip rec) : $(tail -1 "$TMP/req.out")"

echo "═══ E7/E8. la chaîne entière ; les refs hors classe ═══"
set_ctl '{"open":[]}'
req prod
refus GATE_REFS_REQUIRED && [ "$(clones)" = 0 ] && ok "E7 prod sous ci sans refs ⇒ GATE_REFS_REQUIRED (le terminus est admis, la porte décide)" || ko "E7 rc $(rrc) : $(tail -1 "$TMP/req.out")"
req zeta
refus ENV_INVALIDE && ok "E8.1 zeta ⇒ ENV_INVALIDE" || ko "E8.1 rc $(rrc) : $(tail -1 "$TMP/req.out")"
for bad in '../x' '.hidden' 'a b' 'CHG-1/../x'; do
  req rec "REQ_CHANGE_REF=$bad"
  refus REF_INVALIDE && [ "$(users)" = 0 ] && [ "$(clones)" = 0 ] && ok "E8.2 change_ref '$bad' ⇒ REF_INVALIDE avant tout réseau" || ko "E8.2 '$bad' rc $(rrc) users=$(users) clones=$(clones) : $(tail -1 "$TMP/req.out")"
done
req rec 'REQ_PV_REF=..'
refus REF_INVALIDE && ok "E8.3 pv_ref '..' ⇒ REF_INVALIDE" || ko "E8.3 rc $(rrc) : $(tail -1 "$TMP/req.out")"

echo "═══ E10. un push en échec ne fuit pas le token ═══"
set_ctl '{"open":[]}'; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null
req rec FORGE_TOKEN=t-alice SHIM_PUSH_FAIL=1
[ "$(rrc)" = 1 ] && grep -q 'ERREUR push' "$TMP/req.out" && ! grep -q 't-alice' "$TMP/req.out" && ok "E10 push en échec ⇒ rc 1, détail masqué, le token humain n'apparaît pas" || ko "E10 rc $(rrc) : $(grep -n 't-alice' "$TMP/req.out" | head -1)"

echo "═══ M. mutations : chaque garde neuve attrape ce qu'elle prétend attraper ═══"
MUT="$TMP/mut"; mkdir -p "$MUT"
mutant(){ # <nom> <sed-expr> → $MUT/<nom>.sh, ou vide si no-op / ne compile pas
  sed -E "$2" "$S" > "$MUT/$1.sh"
  if cmp -s "$S" "$MUT/$1.sh" || ! bash -n "$MUT/$1.sh" 2>/dev/null; then echo ""; else echo "$MUT/$1.sh"; fi
}
reqm(){ local m="$1"; shift; local e="$1"; shift; S="$m" req "$e" "$@"; }
M1=$(mutant m1 's#^(\. "scripts/lib/forge-identity\.sh".*)$#\1\nforge_is_service(){ return 1; }#')
if [ -n "$M1" ]; then set_ctl '{"open":[]}'; reqm "$M1" int FORGE_TOKEN=t-svc "GITEA_SERVICE_LOGINS=ci svc-bot"; refus REQUESTER_UNKNOWN && ko "M1 le mutant (forge_is_service ⇒ jamais service) refuse encore" || ok "M1 forge_is_service neutralisée ⇒ svc-bot passe pour humain (E3.2 rougit)"; else ko "M1 mutant no-op/incompilable"; fi
M2=$(mutant m2 's#PR_TOKEN_FILE="\$PUSH_TF"#PR_TOKEN_FILE="$CI_TF"#')
if [ -n "$M2" ]; then set_ctl '{"open":[]}'; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-int 2>/dev/null; reqm "$M2" int FORGE_TOKEN=t-alice; [ "$(post_auth)" = "token t-ci" ] && ok "M2 POST /pulls forcé sur le token ci ⇒ l'auteur redevient ci (E4.2 rougit)" || ko "M2 auth='$(post_auth)' rc $(rrc)"; else ko "M2 mutant no-op/incompilable"; fi
M3=$(mutant m3 's#^    extra\.append\("- ouverte par .*$#    pass#')
if [ -n "$M3" ]; then set_ctl '{"open":[]}'; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-int 2>/dev/null; reqm "$M3" int FORGE_TOKEN=t-alice; [ "$(rrc)" = 0 ] && ! post_body | grep -q 'ouverte par' && ok "M3 ligne « ouverte par » retirée ⇒ corps sans identité (E4.3 rougit)" || ko "M3 rc $(rrc)"; else ko "M3 mutant no-op/incompilable"; fi
M4=$(mutant m4 '/^unset FORGE_TOKEN FORGE_TOKEN_FILE$/d')
if [ -n "$M4" ]; then set_ctl '{"open":[]}'; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-int 2>/dev/null; reqm "$M4" int FORGE_TOKEN=t-alice; grep -qE 'ENV FORGE_TOKEN=t-alice' "$SHIM_LOG" && ok "M4 unset retiré ⇒ git hérite le token (E4.6 rougit)" || ko "M4 rc $(rrc) : $(grep -c 'ENV FORGE_TOKEN=t-alice' "$SHIM_LOG") héritages"; else ko "M4 mutant no-op/incompilable"; fi
M5=$(mutant m5 '/PR_D_AUTRUI : la PR/d')
if [ -n "$M5" ]; then set_ctl "{\"open\":[$(pr_open 78 ci rec)]}"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null; reqm "$M5" rec FORGE_TOKEN=t-alice; [ "$(rrc)" = 0 ] && ok "M5 PR_D_AUTRUI retiré ⇒ alice réécrit la PR de ci (E6.1 rougit)" || ko "M5 rc $(rrc) : $(tail -1 "$TMP/req.out")"; else ko "M5 mutant no-op/incompilable"; fi
M6=$(mutant m6 's#grep -v -F -- "\$\(cat "\$PUSH_TF"\)" "\$WORK/pusherr" \| grep -v -F -- "\$GITEA_TOKEN"#cat "$WORK/pusherr"#')
if [ -n "$M6" ]; then set_ctl '{"open":[]}'; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null; reqm "$M6" rec FORGE_TOKEN=t-alice SHIM_PUSH_FAIL=1; [ "$(rrc)" = 1 ] && grep -q 't-alice' "$TMP/req.out" && ok "M6 filtre du push retiré ⇒ le token humain fuit dans la sortie (E10 rougit)" || ko "M6 rc $(rrc) : le mutant ne fuit pas"; else ko "M6 mutant no-op/incompilable"; fi

echo
echo "═══════════════════════════════════════════════════"
printf 'RÉSULTAT : %d/%d\n' "$PASS" $((PASS + FAIL))
[ "$FAIL" -eq 0 ] || exit 1
