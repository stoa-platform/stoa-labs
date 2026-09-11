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
#   E9  les champs obligatoires ⇒ CHAMP_REQUIS, nommant LE CHAMP du formulaire
#   E10 le token n'apparaît jamais dans la sortie d'un push en échec
#   E11 la branche de base est DÉCOUVERTE (master), jamais devinée
#   E12 STOA_DEBUG=1 : la chaîne parle (disposition, identité, HTTP, gestes git),
#       sans fuite — chaque absence doublée d'une présence (L2, plan 2026-09-09)
#   M   mutations : chaque garde neuve attrape ce qu'elle prétend attraper
#       (M6 redact du push, M9 DBG_SECRET_FILES, M10 une ligne de debug sur stdout,
#       M11 l'ordre « masque puis coupe » de dbg_git_err — le secret à cheval sur l'octet 400,
#       M12/M13 un rc de fetch/clone écrit en dur, M14 « existe=oui » écrit en dur,
#       M15 le relais du whoami de forge_login rendu conditionnel — sur COPIE de la lib)
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
    # L1 (2026-09-09) : jusqu'ici _send ne rendait QUE du JSON typé. Le client
    # GitLab recevait un 302 vers /users/sign_in puis une page HTML — une forme
    # que ce stub ne savait pas produire, donc E6.5 etait un vert vacant.
    def _raw(self, code, ctype, body, extra=()):
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body)))
        for k, v in extra: self.send_header(k, v)
        self.end_headers(); self.wfile.write(body)
    def _route(self, method):
        u = urlparse(self.path); q = parse_qs(u.query); path = u.path
        auth = self.headers.get("Authorization", ""); tok = auth[len("token "):] if auth.startswith("token ") else ""
        alias = tok if tok in TOKENS else "?"
        with open(LOG, "a") as f: f.write("%s %s %s\n" % (method, path, alias))
        c = ctl()
        if c.get("down"): return self._send(500, {"message": "boom"})
        HTML = b"<!DOCTYPE html>\n<html><head><title>Sign in \xc2\xb7 GitLab</title></head><body>GitLab</body></html>\n"
        if path == "/users/sign_in": return self._raw(200, "text/html; charset=utf-8", HTML)
        bm = c.get("body_mode")
        if bm and path.endswith("/pulls") and method == "GET":
            if bm == "empty":     return self._raw(200, "application/json", b"")
            if bm == "html":      return self._raw(200, "text/html; charset=utf-8", HTML)
            if bm == "object":    return self._send(200, {"message": "not a list"})
            if bm == "redirect":  return self._raw(302, "text/html", b"", [("Location", "/users/sign_in")])
            if bm == "echo_auth": return self._raw(200, "text/html", b"<html><pre>" + auth.encode() + b"</pre></html>")
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
  s="\$(sh "\${GIT_ASKPASS:-/bin/false}" Password 2>/dev/null)"
  pre="fatal: unable to access (simulé) — askpass a rendu "; l="\$pre\$s"
  # SHIM_PUSH_SECRET_AT=N : le secret est recopié UNE SECONDE FOIS, en commençant
  # à l'OCTET N de la ligne (0-indexé), derrière un rembourrage de « x ». C'est le
  # DISCRIMINANT de l'ordre « masque puis coupe » de dbg_git_err (E12.3e/f, M11) :
  # N dans ]400-len(secret), 400[ met le secret À CHEVAL sur la coupe à 400 octets
  # — un helper qui coupe AVANT de masquer en laisse un morceau que redact ne
  # reconnaît plus. Un rembourrage qui pousserait le secret ENTIÈREMENT après
  # l'octet 400 ne discriminerait rien : les deux ordres rendent le même
  # rembourrage (mesuré : 390 « x » avant « askpass a rendu » ⇒ secret à l'octet
  # 445). Octets, pas caractères : « é » et « — » du préfixe en font 2 et 3
  # (wc -c) ; le secret du harnais est ASCII (\${#s} suffit).
  if [ -n "\${SHIM_PUSH_SECRET_AT:-}" ]; then
    mid=" askpass a rendu "
    n=\$(( \$(printf '%s' "\$pre\$mid" | wc -c) + \${#s} + 1 ))
    l="\$l \$(printf '%*s' "\$((SHIM_PUSH_SECRET_AT - n))" '' | tr ' ' x)\$mid\$s"
  fi
  echo "\$l" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
SH
chmod 700 "$SHIM/git"

# ── la fixture git : nu + clone de construction (layout du dépôt plateforme) ──
ORIGIN="$TMP/origin.git"; W="$TMP/w"; SUB="poc-control-plane-federation"
git init -q --bare "$ORIGIN" && git -C "$ORIGIN" symbolic-ref HEAD refs/heads/master
git init -q "$W" && git -C "$W" checkout -q -b master
gw(){ git -C "$W" -c user.name=t -c user.email=t@t "$@"; }
MAN="$SUB/clients/provisioned/applications/appa.ansible.yml"
mkdir -p "$W/$SUB/ansible" "$W/$SUB/clients/provisioned/applications" "$W/$SUB/clients/_example"
for e in dev rec int homol prod; do printf 'providers:\n  - team: banking-demo\n    repo: ""\n    approvers: []\n' > "$W/$SUB/ansible/providers.$e.yml"; done
cp "$REPO/clients/_example/environments.yaml" "$TMP/chain.yaml"
cp "$TMP/chain.yaml" "$W/$SUB/clients/_example/environments.yaml"
printf 'init\n' > "$W/README"; gw add -A; gw commit -qm c0 >/dev/null
gw remote add origin "$ORIGIN"; gw push -q origin master
BASE0=$(gw rev-parse master)
# plan enchaîné : un stub qui journalise SON environnement (le token humain ne doit pas y être)
PLAN_STUB="$TMP/plan-stub.sh"; PLAN_ENV="$TMP/plan.env"
printf '#!/usr/bin/env bash\nprintf "FORGE_TOKEN=%%s\\nGITEA_TOKEN=%%s\\nPUSH_TOKEN=%%s\\n" "${FORGE_TOKEN:-}" "${GITEA_TOKEN:-}" "${PUSH_TOKEN:-}" > "%s"\n' "$PLAN_ENV" > "$PLAN_STUB"; chmod 700 "$PLAN_STUB"

set_ctl(){ printf '%s' "$1" > "$STUB_CTL"; : > "$STUB_LOG"; : > "$STUB_POSTED"; : > "$SHIM_LOG"; rm -f "$PLAN_ENV"; }
reset_origin(){ git -C "$W" push -q -f origin "$BASE0:master"; for b in dev rec int homol prod; do git -C "$ORIGIN" update-ref -d "refs/heads/provision/appa-$b" 2>/dev/null || true; done; }
merge_branch(){ # <env> : « le merge humain » de provision/appa-<env> dans master, dans le nu
  gw fetch -q origin && gw checkout -q master && gw reset -q --hard origin/master \
    && gw merge -q --no-ff -m "Merge pull request 'provision($1): appa' from provision/appa-$1 into master" "origin/provision/appa-$1" \
    && gw push -q origin master
}
# _req_run <env> [VAR=val…] : le script sous test, dans un environnement VIERGE
# (env -i : aucune variable du poste — ni GIT_BASE, ni STOA_DEBUG — n'y entre
# sans être nommée ici). Les deux flux vont où l'appelant les envoie.
_req_run(){
  local e="$1"; shift
  ( cd "$REPO" && env -i PATH="$SHIM:$PATH" HOME="$HOME" GITEA_TOKEN=t-ci GIT_HOST="$GH" GIT_WEB_HOST="$GH" GIT_REPO=ci/stoa-labs \
      GIT_CLONE_URL="file://$ORIGIN" GIT_PUSH_URL="file://$ORIGIN" STOA_ENV_CHAIN_FILE="$TMP/chain.yaml" PROVISION_PLAN_INLINE=false \
      REQ_APP=appa REQ_ENV="$e" REQ_API=demo-selfservice REQ_API_VER=1.0.0 REQ_CLIENT_ID="appa-$e" REQ_CALLER=jenkins-form:x REQ_TEAM=banking-demo \
      "$@" bash "$S" )
}
# req <env> [VAR=val…] : sortie FUSIONNÉE dans $TMP/req.out (l'ordre des lignes
# entre stdout et stderr est celui de l'exécution), rc $TMP/req.rc. req.err est
# vidé : un run fusionné ne laisse pas traîner le stderr d'un run séparé.
req(){ : > "$TMP/req.err"; _req_run "$@" > "$TMP/req.out" 2>&1; echo $? > "$TMP/req.rc"; }
# req2 <env> [VAR=val…] : les deux flux SÉPARÉS — stdout dans req.out, stderr
# dans req.err. C'est la seule façon de prouver que le PRODUIT (stdout) ne
# porte aucune ligne de debug (E12).
req2(){ _req_run "$@" > "$TMP/req.out" 2>"$TMP/req.err"; echo $? > "$TMP/req.rc"; }
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
# La BASE que la PR postée vise. Les deux visages de forge-api.sh la nomment
# autrement (Gitea « base », GitLab « target_branch ») ; ici le stub est Gitea,
# les deux clés sont lues pour que l'épreuve ne dépende pas du visage.
post_base(){ tail -1 "$STUB_POSTED" 2>/dev/null | python3 -c 'import json,sys
try:
    b = json.load(sys.stdin)["body"]; print(b.get("base") or b.get("target_branch") or "")
except Exception: print("")'; }
clones(){ grep -c '^ARGV clone' "$SHIM_LOG" || true; }
tip(){ git -C "$ORIGIN" rev-parse -q --verify "refs/heads/provision/appa-$1" 2>/dev/null || printf 'absente'; }
line_at(){ git -C "$ORIGIN" show "provision/appa-$1:$MAN" 2>/dev/null | grep -E "^    $1: "; }
trailer_at(){ git -C "$ORIGIN" log -1 --format=%B "provision/appa-$1" 2>/dev/null | sed -n 's/^Demande-Par: //p'; }
pr_open(){ # <n> <login> <env> → json d'une PR ouverte
  printf '{"number":%s,"state":"open","merged":false,"head":{"ref":"provision/appa-%s","sha":"deadbeef","repo":{"full_name":"ci/stoa-labs"}},"base":{"ref":"master"},"user":{"login":"%s"}}' "$1" "$3" "$2"
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


# ── E0.10 à E0.16 — DEUX MODES D'IDENTITE (déploiement client 2026-09-04) ────
# Le gestionnaire d'identité d'un client ne rend pas toujours un jeton : Jenkins
# rend souvent un COUPLE (usernamePassword). « Authorization: token » n'a alors
# aucun sens pour la forge en face, et le refus accusait le jeton de l'humain.
FT="$TMP/fi"; mkdir -p "$FT"; printf 'secret-canari' > "$FT/s"
# chaque appel part d'un environnement PROPRE : ces modes se lisent dans l'env,
# une variable qui survit d'une épreuve à l'autre rendrait un vert menteur.
# <VAR=v>… -- <fonction> <args…>  (env exigeant : les assignations d'abord)
fi_run(){
  local -a A=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do A+=("$1"); shift; done
  shift
  env -u FORGE_API_AUTH -u FORGE_USER "${A[@]}" bash -c '. "$0"; "$@"' "$LIB" "$@"
}
fi_hdr(){ fi_run "$@" -- forge_auth_header "$FT/s" "$FT/h" 2>"$FT/e"; }

fi_hdr FORGE_API_AUTH=token && grep -qx 'Authorization: token secret-canari' "$FT/h" \
  && ok "E0.10 mode token (défaut Gitea) : en-tête inchangé" || ko "E0.10 $(head -1 "$FT/h" 2>/dev/null)"
fi_hdr FORGE_API_AUTH=private-token && grep -qx 'PRIVATE-TOKEN: secret-canari' "$FT/h" \
  && ok "E0.11 mode private-token (GitLab) : en-tête PRIVATE-TOKEN" || ko "E0.11 $(head -1 "$FT/h" 2>/dev/null)"
fi_hdr FORGE_API_AUTH=basic FORGE_USER=jdupont \
  && [ "$(cut -d' ' -f3 "$FT/h" | base64 -d 2>/dev/null)" = "jdupont:secret-canari" ] \
  && ok "E0.12 mode basic (couple d'un gestionnaire d'identité) : Basic <user:secret>" || ko "E0.12 $(head -1 "$FT/e" 2>/dev/null)"
fi_hdr FORGE_API_AUTH=basic; RCB=$?
[ "$RCB" = 2 ] && grep -q 'FORGE_USER_REQUIS' "$FT/e" && ok "E0.13 basic sans utilisateur ⇒ FORGE_USER_REQUIS (rc 2), aucun en-tête" || ko "E0.13 rc=$RCB"
fi_hdr FORGE_API_AUTH=oauth; RCB=$?
[ "$RCB" = 2 ] && grep -q 'FORGE_API_AUTH_INCONNU' "$FT/e" && ok "E0.14 mode inconnu ⇒ FORGE_API_AUTH_INCONNU (fail-closed)" || ko "E0.14 rc=$RCB"
LG=$(fi_run FORGE_USER=jdupont -- forge_login "http://forge.invalid/api/v1" "$FT/s" 2>/dev/null)
[ "$LG" = jdupont ] && ok "E0.15 FORGE_USER posé ⇒ le login est CONNU, aucun appel à la forge (hôte injoignable, rc 0)" || ko "E0.15 login='$LG'"
LG=$(fi_run FORGE_USER="jean dupont" -- forge_login "http://forge.invalid/api/v1" "$FT/s" 2>&1)
printf '%s' "$LG" | grep -q FORGE_LOGIN_INVALIDE && ok "E0.16 FORGE_USER hors charset ⇒ FORGE_LOGIN_INVALIDE (même contrôle que le login de la forge)" || ko "E0.16 $LG"

echo "═══ E1. rec + refs sous ci : la ligne per_env porte change_ref/pv_ref, rien d'autre ne bouge ═══"
set_ctl '{"open":[]}'; reset_origin
req dev
[ "$(rrc)" = 0 ] && [ "$(posts)" = 1 ] && [ "$(users)" = 0 ] && ok "E1a dev sous ci ⇒ PR postée, aucun GET /user (pas de token humain, pas de quatre yeux)" || ko "E1a rc $(rrc) posts=$(posts) users=$(users) : $(grep -E 'REFUS|ERREUR' "$TMP/req.out" | head -2 | tr '\n' ' ')"
merge_branch dev || ko "E1a' fixture : merge de dev"
git -C "$ORIGIN" show "master:$MAN" > "$TMP/man.dev.yml" 2>/dev/null
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
refus GATE_REFS_REQUIRED && grep -q 'pv_ref' "$TMP/req.out" && [ "$(clones)" = 0 ] && ! grep -q '\[1/5\]' "$TMP/req.out" && ok "E2.1 homol sans pv_ref ⇒ GATE_REFS_REQUIRED (pv_ref nommé), aucun clone" || ko "E2.1 rc $(rrc) clones=$(clones) : $(tail -1 "$TMP/req.out")"
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
gw fetch -q origin && gw checkout -q -B provision/appa-rec origin/master && gw commit -q --allow-empty -m "provision(rec): repli" -m "Repli-Vers: 0000000 (PR #1)" && gw push -q -f origin provision/appa-rec
set_ctl "{\"open\":[$(pr_open 80 alice rec)]}"; T6b=$(tip rec)
req rec FORGE_TOKEN=t-alice
refus REPLI_EN_COURS && [ "$(tip rec)" = "$T6b" ] && ok "E6.4 PR de repli ouverte par un HUMAIN ⇒ REPLI_EN_COURS (A6 étendu : l'auteur n'exonère plus)" || ko "E6.4 rc $(rrc) : $(tail -1 "$TMP/req.out")"
git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec; gw checkout -q master
set_ctl '{"down":true}'
req rec
[ "$(rrc)" = 2 ] && grep -qE 'REFUS: (FORGE_ILLISIBLE|REPLI_EN_COURS)' "$TMP/req.out" && [ "$(tip rec)" = absente ] && ok "E6.5 forge muette ⇒ refus fermé avant le push (une PR ouverte pourrait exister)" || ko "E6.5 rc $(rrc) tip=$(tip rec) : $(tail -1 "$TMP/req.out")"
# L1 (2026-09-09) — CE QUE LE CLIENT A VU : un corps vide, une trace Python de
# quinze lignes, et un refus qui ne disait ni le statut ni l'URL. Quatre formes
# de reponse qu'une forge, un reverse-proxy ou un portail SSO rendent pour de
# vrai, et que le stub ne savait pas produire.
sans_trace(){ ! grep -q 'Traceback' "$TMP/req.out"; }
set_ctl '{"body_mode":"empty"}'; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null
req rec
refus FORGE_ILLISIBLE && sans_trace && grep -q 'HTTP 200' "$TMP/req.out" && grep -q '0 octet' "$TMP/req.out" && [ "$(tip rec)" = absente ] \
  && ok "E6.6 corps VIDE (200) ⇒ FORGE_ILLISIBLE qui dit « HTTP 200, 0 octet », sans trace Python, rien de poussé" \
  || ko "E6.6 rc $(rrc) tip=$(tip rec) : $(grep -E 'REFUS|Traceback|Error' "$TMP/req.out" | head -2 | tr '\n' ' ')"
# gitlab.com repond a /api/v1/... par 302 vers /users/sign_in : c'est la panne
# du client, et c'est la LIGNE qu'il doit lire.
set_ctl '{"body_mode":"redirect"}'; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null
req rec
refus FORGE_ILLISIBLE && sans_trace && grep -q '302' "$TMP/req.out" && grep -q '/users/sign_in' "$TMP/req.out" && [ "$(tip rec)" = absente ] \
  && ok "E6.7 302 vers /users/sign_in ⇒ le refus NOMME la redirection (« cette forge ne parle pas /api/v1 »), jamais suivie" \
  || ko "E6.7 rc $(rrc) tip=$(tip rec) : $(grep -E 'REFUS|Traceback' "$TMP/req.out" | head -2 | tr '\n' ' ')"
# LE FAIL-OPEN : un objet JSON au lieu d'une liste faisait conclure « aucune PR
# ouverte » puis POUSSER EN FORCE par-dessus la PR d'autrui.
set_ctl '{"body_mode":"object"}'; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null
req rec
refus FORGE_ILLISIBLE && sans_trace && grep -qi 'objet' "$TMP/req.out" && [ "$(tip rec)" = absente ] && ! grep -q '^ARGV push' "$SHIM_LOG" \
  && ok "E6.8 objet JSON au lieu d'une liste ⇒ REFUS nommé, aucun push (avant : rc 0 et push en force)" \
  || ko "E6.8 rc $(rrc) tip=$(tip rec) push=$(grep -c '^ARGV push' "$SHIM_LOG") : $(grep -E 'REFUS' "$TMP/req.out" | head -1)"
# L'EXTRAIT DU CORPS EST EXPURGE : une page d'erreur qui recopie l'en-tete
# Authorization ne doit jamais faire fuiter le jeton dans un log Jenkins.
set_ctl '{"body_mode":"echo_auth"}'; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null
req rec
refus FORGE_ILLISIBLE && grep -q '<secret masqué>' "$TMP/req.out" && ! grep -q 't-ci' "$TMP/req.out" \
  && ok "E6.9 le corps cite dans le refus est EXPURGE du jeton (« <secret masqué> », jamais t-ci)" \
  || ko "E6.9 rc $(rrc) fuite=$(grep -c 't-ci' "$TMP/req.out") masque=$(grep -c '<secret masqué>' "$TMP/req.out")"

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

echo "═══ E9. les champs OBLIGATOIRES se refusent EN SE NOMMANT (CHAMP_REQUIS) ═══"
# Mesuré en lab le 2026-09-03 (app-request #47) : une demande à APP vide mourait
# sur `provision-request.sh: line 105: REQ_APP: REQ_APP requis` — un numéro de
# ligne de shell et un nom de VARIABLE, alors que le demandeur a rempli un
# formulaire dont le champ s'appelle « APP ». Le refus doit se nommer comme
# tous les autres et désigner LE CHAMP.
set_ctl '{"open":[]}'; reset_origin
req dev REQ_APP=
refus CHAMP_REQUIS && grep -q 'champ « APP »' "$TMP/req.out" && [ "$(clones)" = 0 ] && [ "$(users)" = 0 ] && ok "E9.1 REQ_APP vide ⇒ CHAMP_REQUIS nommant le champ « APP », aucun clone ni appel forge" || ko "E9.1 rc $(rrc) clones=$(clones) users=$(users) : $(tail -1 "$TMP/req.out")"
! grep -qE 'provision-request\.sh: line [0-9]+' "$TMP/req.out" && ok "E9.2 plus AUCUN message brut « <script>: line N: REQ_X: … » (le refus ne parle plus shell)" || ko "E9.2 message brut : $(grep -E 'line [0-9]+' "$TMP/req.out" | head -1)"
req dev REQ_API=
refus CHAMP_REQUIS && grep -q 'champ « API »' "$TMP/req.out" && ok "E9.3 REQ_API vide ⇒ CHAMP_REQUIS nommant le champ « API »" || ko "E9.3 rc $(rrc) : $(tail -1 "$TMP/req.out")"
req ""
refus CHAMP_REQUIS && grep -q 'champ « REQ_ENV »' "$TMP/req.out" && ok "E9.4 REQ_ENV vide ⇒ CHAMP_REQUIS (et non ENV_INVALIDE sur une chaîne vide)" || ko "E9.4 rc $(rrc) : $(tail -1 "$TMP/req.out")"
req dev REQ_MODE=idp REQ_CLIENT_ID=
refus CHAMP_REQUIS && grep -q 'champ « CLIENT_ID »' "$TMP/req.out" && grep -q 'idp' "$TMP/req.out" && [ "$(clones)" = 0 ] && ok "E9.5 mode idp sans REQ_CLIENT_ID ⇒ CHAMP_REQUIS nommant le champ ET le mode, avant tout clone" || ko "E9.5 rc $(rrc) clones=$(clones) : $(tail -1 "$TMP/req.out")"
req dev "REQ_APP=   "
refus CHAMP_REQUIS && ok "E9.6 REQ_APP fait d'espaces ⇒ CHAMP_REQUIS (une valeur blanche n'est pas une valeur)" || ko "E9.6 rc $(rrc) : $(tail -1 "$TMP/req.out")"

echo "═══ E10. un push en échec ne fuit pas le token ═══"
set_ctl '{"open":[]}'; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null
req rec FORGE_TOKEN=t-alice SHIM_PUSH_FAIL=1
[ "$(rrc)" = 1 ] && grep -q 'ERREUR push' "$TMP/req.out" && ! grep -q 't-alice' "$TMP/req.out" && ok "E10 push en échec ⇒ rc 1, détail masqué, le token humain n'apparaît pas" || ko "E10 rc $(rrc) : $(grep -n 't-alice' "$TMP/req.out" | head -1)"
# L2 : la PRÉSENCE qui double l'absence — le détail du push n'est plus JETÉ
# (l'ancien `grep -v` supprimait la ligne entière), il est RÉDIGÉ : la ligne
# reste lisible, seul le secret en part. Sans cette assertion, un script muet
# passerait E10.
grep -q '^fatal: unable to access (simulé) — askpass a rendu <secret masqué>$' "$TMP/req.out" && ok "E10b le détail du push est PRÉSENT, le secret remplacé par « <secret masqué> » (rédigé, pas jeté)" || ko "E10b détail absent ou non masqué : $(grep -n 'askpass' "$TMP/req.out" | head -1)"

echo "═══ E11. la branche de base : DÉCOUVERTE, jamais « main » deviné (L3, ADR à venir) ═══"
# La fixture de CETTE suite a pour HEAD `master` (bare : symbolic-ref HEAD
# refs/heads/master) et AUCUN GIT_BASE n'entre dans l'environnement de `req` :
# c'est ce qui rend les deux épreuves ci-dessous DISCRIMINANTES. Un
# provision-request.sh qui devine « main » demande `clone -b main`, tombe sur le
# repli sans `-b` — donc reste VERT sur tout le reste de la suite — et ouvre la
# PR vers une base qui n'existe pas chez le client. Ce sont donc l'argv du clone
# et la base POSTÉE qui statuent, jamais le seul code de retour.
set_ctl '{"open":[]}'; reset_origin
req dev
CLONES_B="$(grep '^ARGV clone' "$SHIM_LOG" | tr '\n' ' ')"
{ [ "$(rrc)" = 0 ] && [ "$(post_base)" = master ] \
  && printf '%s' "$CLONES_B" | grep -q -- '-b master' \
  && ! printf '%s' "$CLONES_B" | grep -q -- '-b main'; } \
  && ok "E11.1 HEAD du dépôt = master, aucun GIT_BASE ⇒ clone « -b master » et PR ouverte vers master (rien n'a deviné « main »)" \
  || ko "E11.1 rc $(rrc) base postée '$(post_base)' clone: ${CLONES_B}"
# LE KNOB GAGNE, et il gagne SANS consulter la HEAD (git-base.sh §1) : `develop`
# existe ici, le clone doit la viser telle quelle alors que la HEAD dit master.
git -C "$W" push -q origin "master:develop"
set_ctl '{"open":[]}'; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-int 2>/dev/null
req int FORGE_TOKEN=t-alice GIT_BASE=develop
CLONES_D="$(grep '^ARGV clone' "$SHIM_LOG" | tr '\n' ' ')"
{ [ "$(rrc)" = 0 ] && [ "$(post_base)" = develop ] \
  && printf '%s' "$CLONES_D" | grep -q -- '-b develop' \
  && ! printf '%s' "$CLONES_D" | grep -q -- '-b master'; } \
  && ok "E11.2 GIT_BASE=develop (knob explicite) sur un dépôt dont la HEAD est master ⇒ le clone vise develop, la PR aussi" \
  || ko "E11.2 rc $(rrc) base postée '$(post_base)' clone: ${CLONES_D}"
git -C "$ORIGIN" update-ref -d refs/heads/develop 2>/dev/null || true
git -C "$W" branch -q -D develop 2>/dev/null || true
reset_origin
# UN KNOB QUI NOMME UNE BRANCHE INEXISTANTE EST UN REFUS, plus un repli silencieux.
# `develop` vient d'être supprimée. Jusqu'au 2026-09-10, provision-request.sh
# écrivait « clone -b "$GIT_BASE" … || clone … » : le `-b` échouait, le repli
# clonait la HEAD, et la PR partait quand même vers une base qui n'existe pas.
# Le repli est retiré ; le refus NOMME la branche demandée, pas « main ».
set_ctl '{"open":[]}'; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-int 2>/dev/null || true
req int FORGE_TOKEN=t-alice GIT_BASE=develop
{ [ "$(rrc)" = 2 ] && grep -q 'REFUS: BRANCHE_DE_BASE_INTROUVABLE' "$TMP/req.out" \
  && grep -q "develop n'existe pas" "$TMP/req.out" && ! grep -qw 'main' "$TMP/req.out" \
  && [ "$(posts)" = 0 ] && [ "$(tip int)" = absente ]; } \
  && ok "E11.3 GIT_BASE=develop absente du dépôt ⇒ REFUS: BRANCHE_DE_BASE_INTROUVABLE nommant develop, aucune PR, aucune branche poussée" \
  || ko "E11.3 rc $(rrc) posts=$(posts) tip=$(tip int) : $(tail -1 "$TMP/req.out")"
reset_origin

echo "═══ E12. STOA_DEBUG=1 : la chaîne parle, sans fuite (L2, plan 2026-09-09) ═══"
# Gabarit D1/D2/D3 de test-vault-user-login.sh : chaque ABSENCE (« le token n'y
# est pas ») est DOUBLÉE d'une PRÉSENCE (« la ligne attendue y est ») — une lib
# muette passerait toute absence (vert vacant). Deux tokens dans ce harnais :
# t-ci (service, dans l'environnement : redact le connaît par FORGE_SECRET) et
# t-alice (humain, RETIRÉ de l'environnement par A7 : redact ne le connaît que
# par son fichier, via DBG_SECRET_FILES — M9 retire cette ligne). Le préfixe
# des lignes du script est son nom ($0) : « [dbg provision-request.sh] » ; les
# lignes HTTP viennent de forge-api.py, qui écrit lui-même « [dbg forge-api.py] ».
OUT="$TMP/req.out"; ERR="$TMP/req.err"
P='^\[dbg provision-request\.sh\] '
pres(){ grep -qE -- "$2" "$ERR" && ok "$1 $3" || ko "$1 ABSENTE de stderr : /$2/"; }
# Les FORMES d'un secret (brut, JSON \uXXXX et utf-8, « \/ », %XX, « + », et
# ses morceaux ≥ 4 caractères) — calculées par python, jamais par la lib sous
# test (sinon la preuve tournerait en rond) : le helper de test-dbg-redaction.sh.
formes(){ S="$1" python3 -c '
import json, os, re
from urllib.parse import quote, quote_plus
v = os.environ["S"]; out = set()
for x in [v] + [s for s in re.split(r"[/\s]+", v) if len(s) >= 4]:
    j = json.dumps(x)[1:-1]
    for f in (x, j, j.replace("/", "\\/"), json.dumps(x, ensure_ascii=False)[1:-1], quote(x, safe=""), quote_plus(x, safe="")):
        out.add(f)
print("\n".join(sorted(out)))'; }
# toutes_absentes <secret> — aucune forme d'aucun morceau, ni sur stdout ni sur stderr du dernier run
toutes_absentes(){ local f; while IFS= read -r f; do ! grep -qF -- "$f" "$OUT" "$ERR" || return 1; done < <(formes "$1"); }
# avant <regex A> <regex B> — dans la sortie FUSIONNÉE, la première ligne qui
# matche A PRÉCÈDE la première qui matche B (un log se lit de haut en bas : le
# statut HTTP d'abord, le refus ensuite).
avant(){ local a b; a=$(grep -nE -- "$1" "$OUT" | head -1 | cut -d: -f1); b=$(grep -nE -- "$2" "$OUT" | head -1 | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; }
reset_int(){ set_ctl '{"open":[]}'; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-int 2>/dev/null || true; }
# ── E12.1 le nominal (E4 sous STOA_DEBUG=1), flux SÉPARÉS ────────────────────
reset_int
req2 int FORGE_TOKEN=t-alice STOA_DEBUG=1
cp "$OUT" "$TMP/e12.stdout"
[ "$(rrc)" = 0 ] && grep -q '^PR_URL=http://stub/pulls/900$' "$OUT" && [ "$(posts)" = 1 ] && [ "$(post_auth)" = "token t-alice" ] \
  && ok "E12.1a nominal sous STOA_DEBUG=1 : rc 0, PR_URL= sur stdout, une PR postée sous alice — le produit d'E4" \
  || ko "E12.1a rc $(rrc) posts=$(posts) auth='$(post_auth)' : $(grep -hE 'REFUS|ERREUR' "$OUT" "$ERR" | head -2 | tr '\n' ' ')"
# LE PRODUIT : stdout ne porte QUE le contrat — « [n/5] … », une ligne de détail
# indentée de deux espaces, « PR_URL= », « OK: » — jamais une ligne de debug :
# ni « [dbg », ni un CLÉ=VALEUR nu. M10 remplace un dbg_kv par un echo : c'est
# la seconde moitié de cette assertion qui le voit, « pas de [dbg » seule ne le
# verrait pas (le brief l'appelle une assertion vacante).
! grep -q '\[dbg' "$OUT" && ! grep -qvE '^(\[[1-5]/5\] |  |PR_URL=|OK: )' "$OUT" \
  && ok "E12.1b stdout = le contrat seul ([n/5], détails indentés, PR_URL=, OK:) — aucune ligne de debug, ni [dbg ni CLÉ=VALEUR" \
  || ko "E12.1b stdout pollué : $(grep -vE '^(\[[1-5]/5\] |  |PR_URL=|OK: )' "$OUT" | head -2 | tr '\n' ' ')"
# LES PRÉSENCES, une à une. D'abord ce que les AUTORITÉS disent (le script ne le redit pas) …
pres E12.1c "${P}FORGE_KIND=gitea\$" "] FORGE_KIND=gitea (forge_api_init)"
pres E12.1d "${P}GIT_BASE=master\$" "] GIT_BASE=master (git_base_init — la HEAD de la fixture)"
pres E12.1e "${P}GIT_BASE_ORIGINE=decouverte\$" "] GIT_BASE_ORIGINE=decouverte (aucun GIT_BASE dans l'environnement de req)"
# … puis ce que CE script décide : la disposition (SUB_PFX est le préfixe du
# monorepo du lab — NON VIDE, et il se lit), l'identité, les gestes git.
pres E12.1f "${P}MODE=idp\$" "] MODE=idp (dérivé du caller jenkins-form:x)"
pres E12.1g "${P}SUB_PFX=poc-control-plane-federation/\$" "] SUB_PFX=poc-control-plane-federation/ (GIT_SUBDIR par défaut : préfixe non vide, terminé par /)"
pres E12.1h "${P}REL_PATH=poc-control-plane-federation/clients/provisioned/applications/appa\\.ansible\\.yml\$" "] REL_PATH=<SUB_PFX><MANIFEST_DIR>/appa.ansible.yml"
pres E12.1i "${P}PROV_FILE=poc-control-plane-federation/ansible/providers\\.int\\.yml existe=oui\$" "] PROV_FILE=<SUB_PFX>ansible/providers.int.yml existe=oui"
pres E12.1j "${P}FORGE_LOGIN=alice\$" "] FORGE_LOGIN=alice (forge_login)"
pres E12.1k "${P}PUSH_LOGIN=alice\$" "] PUSH_LOGIN=alice"
pres E12.1l "${P}BRANCH=provision/appa-int\$" "] BRANCH=provision/appa-int"
pres E12.1m "${P}CLONE_URL=file://" "] CLONE_URL=file://… (l'URL composée : c'est elle qu'on diagnostique)"
# Le whoami de forge_login (scripts/lib/forge-identity.sh) : jusqu'au 2026-09-11
# (L2-B5) la lib capturait le stderr du verbe et ne le relayait que sur rc ≠ 0 —
# sur SUCCÈS la ligne HTTP était lue, effacée, perdue (mesure L2-B1 : journal du
# stub users=1, 0 ligne « /user » sur stderr). Relayée succès compris désormais ;
# M15 rend le relais à nouveau conditionnel (rc ≠ 0 seulement). Le motif écrit
# « /[^ ]+/user » : un visage GitLab dirait /api/v4/user, la présence ne dépend
# pas du préfixe d'API.
pres "E12.1n'" '^\[dbg forge-api\.py\] GET http://127\.0\.0\.1:[0-9]+/[^ ]+/user -> HTTP 200 \([0-9]+ octets\)$' "[dbg forge-api.py] GET …/user -> HTTP 200 (forge_login : le whoami, relayé succès compris)"
pres E12.1n '^\[dbg forge-api\.py\] GET http://127\.0\.0\.1:[0-9]+/api/v1/repos/ci/stoa-labs/pulls\?[^ ]* -> HTTP 200 \([0-9]+ octets\)$' "[dbg forge-api.py] GET …/pulls?… -> HTTP 200 (pr_find_open)"
pres E12.1o '^\[dbg forge-api\.py\] POST http://127\.0\.0\.1:[0-9]+/api/v1/repos/ci/stoa-labs/pulls -> HTTP 201 \([0-9]+ octets\)$' "[dbg forge-api.py] POST …/pulls -> HTTP 201 (pr_open)"
pres E12.1p "${P}git clone --depth 1 -b master file://[^ ]+ -> rc 0\$" "] git clone --depth 1 -b master <url> -> rc 0"
pres E12.1q "${P}REMOTE_TIP=<vide>\$" "] REMOTE_TIP=<vide> (premier passage : pas de branche distante — le vide se DIT)"
pres E12.1r "${P}git diff --cached --quiet -> rc 1\$" "] git diff --cached --quiet -> rc 1 (l'index diffère de la base : il y a quelque chose à committer)"
pres E12.1s "${P}git push --force-with-lease=refs/heads/provision/appa-int: file://[^ ]+ HEAD:refs/heads/provision/appa-int -> rc 0\$" "] git push --force-with-lease=… <url> HEAD:… -> rc 0"
pres E12.1t "${P}PR_NUM=900\$" "] PR_NUM=900 (créée)"
# LES ABSENCES : aucune forme d'aucun des deux tokens, aucun en-tête d'auth en clair.
toutes_absentes t-alice && toutes_absentes t-ci \
  && ok "E12.1u AUCUNE forme de t-alice (humain) ni de t-ci (service) — ni sur stdout ni sur stderr" \
  || ko "E12.1u fuite : $(grep -nE 't-alice|t-ci' "$OUT" "$ERR" | head -1)"
! grep -q 'Authorization: token' "$OUT" "$ERR" && ok "E12.1v aucun en-tête « Authorization: token » en clair" || ko "E12.1v $(grep -n 'Authorization: token' "$OUT" "$ERR" | head -1)"
# LE VRAI rc HORS du succès (relecture L2-B1, n°3) : « -> rc 0 » n'était prouvé
# que là où git réussit — un « -> rc 0 » écrit en dur à la place de « $rc »
# traversait la suite (sondes S3/S6 de la revue : 6/6 verts). Sur ce même
# premier passage, les DEUX fetch de la branche (le bail, puis le rejeu) rendent
# réellement 128 : la branche distante n'existe pas encore — c'est le diagnostic
# « premier passage » que L2 voulait lisible, jadis jeté à /dev/null. La ligne
# « git: » épingle « fatal » et la REF, jamais la langue : sous env -i, git parle
# la langue du poste (ici « impossible de trouver la référence distante » ; un
# CI Linux dirait « couldn't find remote ref »). M12 écrit « rc 0 » en dur.
[ "$(grep -cE "${P}git fetch --depth 1 file://[^ ]+ refs/heads/provision/appa-int -> rc 128\$" "$ERR")" = 2 ] && ! grep -qE "${P}git fetch .* -> rc 0\$" "$ERR" \
  && ok "E12.1w les DEUX fetch de la branche (bail, puis rejeu) disent « -> rc 128 » — le VRAI rc du premier passage, aucun « git fetch … -> rc 0 »" \
  || ko "E12.1w fetch : $(grep -nE "${P}git fetch " "$ERR" | tr '\n' ' ')"
pres E12.1x "${P}  git: .*fatal.*refs/heads/provision/appa-int" "]   git: fatal … refs/heads/provision/appa-int (le stderr du fetch, jadis jeté à /dev/null — la ref nommée, quelle que soit la langue de git)"
# ── E12.2 l'échec de forge : la ligne HTTP PRÉCÈDE le refus, sans token ──────
set_ctl '{"down":true}'; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
req rec STOA_DEBUG=1
[ "$(rrc)" = 2 ] && avant '^\[dbg forge-api\.py\] GET [^ ]+/pulls\?[^ ]* -> HTTP 500 ' '^REFUS: FORGE_ILLISIBLE' && toutes_absentes t-ci \
  && ok "E12.2a forge en panne (500) : « GET …/pulls?… -> HTTP 500 » PRÉCÈDE « REFUS: FORGE_ILLISIBLE » ; jamais t-ci" \
  || ko "E12.2a rc $(rrc) : $(grep -nE 'HTTP 500|REFUS' "$OUT" | head -2 | tr '\n' ' ')"
set_ctl '{"body_mode":"redirect"}'; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
req rec STOA_DEBUG=1
[ "$(rrc)" = 2 ] && avant '^\[dbg forge-api\.py\] GET [^ ]+/pulls\?[^ ]* -> HTTP 302 ' '^REFUS: FORGE_ILLISIBLE' && toutes_absentes t-ci \
  && ok "E12.2b 302 vers /users/sign_in : « -> HTTP 302 » PRÉCÈDE le refus (la ligne que le client GitLab devait lire) ; jamais t-ci" \
  || ko "E12.2b rc $(rrc) : $(grep -nE 'HTTP 302|REFUS' "$OUT" | head -2 | tr '\n' ' ')"
set_ctl '{"open":[]}'
req int FORGE_TOKEN=t-inconnu STOA_DEBUG=1
[ "$(rrc)" = 2 ] && avant '^\[dbg forge-api\.py\] GET [^ ]+/user -> HTTP 401 ' '^REFUS: FORGE_TOKEN_INVALIDE' && toutes_absentes t-inconnu && toutes_absentes t-ci \
  && ok "E12.2c token refusé (401) : « GET …/user -> HTTP 401 » PRÉCÈDE « REFUS: FORGE_TOKEN_INVALIDE » ; ni t-inconnu ni t-ci" \
  || ko "E12.2c rc $(rrc) : $(grep -nE 'HTTP 401|REFUS' "$OUT" | head -2 | tr '\n' ' ')"
# ── E12.3 l'échec de push : E10 en mode debug — le shim recopie le secret de l'askpass ──
set_ctl '{"open":[]}'; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
req2 rec FORGE_TOKEN=t-alice SHIM_PUSH_FAIL=1 STOA_DEBUG=1
[ "$(rrc)" = 1 ] && grep -q '^ERREUR push (détail masqué — token)$' "$ERR" && grep -q '^fatal: unable to access (simulé) — askpass a rendu <secret masqué>$' "$ERR" \
  && ok "E12.3a push refusé sous STOA_DEBUG=1 : rc 1, « ERREUR push » et son détail MASQUÉ — l'erreur d'origine, inchangée" \
  || ko "E12.3a rc $(rrc) : $(grep -nE 'ERREUR|fatal' "$ERR" | head -2 | tr '\n' ' ')"
pres E12.3b "${P}git push --force-with-lease=refs/heads/provision/appa-rec: file://[^ ]+ HEAD:refs/heads/provision/appa-rec -> rc 128\$" "] git push … -> rc 128 (le VRAI rc du shim, pas celui d'un « ! »)"
pres E12.3c "${P}  git: fatal: unable to access \\(simulé\\) — askpass a rendu <secret masqué>" "]   git: … askpass a rendu <secret masqué> (le stderr du push, rédigé par le FICHIER du token humain)"
toutes_absentes t-alice && toutes_absentes t-ci \
  && ok "E12.3d JAMAIS t-alice ni t-ci, sous aucune forme — ni dans le refus, ni dans une ligne de debug" \
  || ko "E12.3d fuite : $(grep -nE 't-alice|t-ci' "$OUT" "$ERR" | head -1)"
# ── E12.3e/f l'ORDRE de dbg_git_err : masqué EN ENTIER, PUIS coupé à 400 octets ──
# Le DISCRIMINANT (grammaire §3, CORRECTION revues B1/B3 : « l'ORDRE doit avoir
# son ÉPREUVE ») : le secret du harnais (t-alice, 7 octets) ne chevauche jamais
# la coupe de lui-même, et dbg remasque derrière — sans discriminant, un helper
# qui couperait AVANT de masquer traverse E12.3a-d en vert (mesuré : relecture
# L2-B1, sonde S1, 4/4 verts sur le mutant). Le shim recopie donc le secret une
# seconde fois à partir de l'octet 395 de sa ligne : à cheval sur 400 (ligne
# brute de 402 octets). Masque puis coupe ⇒ la ligne « git: » porte le premier
# masque entier, puis le rembourrage, et s'arrête à 400 octets AVANT la seconde
# occurrence (déjà masquée). Coupe puis masque ⇒ « askpass a rendu t-ali »,
# cinq octets du token humain que ni redact ni dbg ne reconnaissent — c'est M11.
SECRET_AT=395; FRAG="t-alice"; FRAG="${FRAG:0:$((400 - SECRET_AT))}"   # le morceau que laisserait la coupe : « t-ali »
set_ctl '{"open":[]}'; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
req2 rec FORGE_TOKEN=t-alice SHIM_PUSH_FAIL=1 "SHIM_PUSH_SECRET_AT=$SECRET_AT" STOA_DEBUG=1
# git_line : la charge de la ligne « git: » du push, sans le préfixe « [dbg <script>] »
# (agnostique du NOM : M11 la relit sur une copie nommée m11.sh) ; git_octets : sa taille en OCTETS.
git_line(){ grep -m1 -E '^\[dbg [^]]*\]   git: fatal: unable to access' "$ERR" | sed -E 's/^\[dbg [^]]*\]   git: //' | tr -d '\n'; }
git_octets(){ echo $(( $(git_line | wc -c) )); }
[ "$(rrc)" = 1 ] && grep -qE "${P}  git: fatal: unable to access \\(simulé\\) — askpass a rendu <secret masqué> x+" "$ERR" && [ "$(git_octets)" -eq 400 ] \
  && grep -qE '^fatal: unable to access \(simulé\) — askpass a rendu <secret masqué> x+ askpass a rendu <secret masqué>$' "$ERR" \
  && ok "E12.3e stderr de push de 402 octets, secret à cheval sur l'octet 400 : la ligne « git: » porte « <secret masqué> » puis le rembourrage et fait EXACTEMENT 400 octets (masquée en entier, PUIS coupée) ; le détail du refus, non coupé, masque les DEUX occurrences" \
  || ko "E12.3e rc $(rrc) octets=$(git_octets) : …$(git_line | tail -c 40) / $(grep -c 'askpass a rendu <secret masqué>' "$ERR") ligne(s) masquée(s)"
! grep -oE 'askpass a rendu [^ ]*' "$OUT" "$ERR" | grep -vqE 'askpass a rendu (<secret|$)' && ! grep -qF -- "$FRAG" "$OUT" "$ERR" && toutes_absentes t-alice && toutes_absentes t-ci \
  && ok "E12.3f après « askpass a rendu », rien d'autre que le masque (entier, ou coupé par les 400 octets) : ni « $FRAG » ni aucune forme de t-alice / t-ci — aucun MORCEAU du secret n'a survécu à la coupe" \
  || ko "E12.3f morceau du secret : $(grep -noE 'askpass a rendu [^ ]*' "$OUT" "$ERR" | grep -vE '<secret' | head -1)"
# ── E12.4 le silence : STOA_DEBUG=0 ⇒ zéro [dbg, produit OCTET POUR OCTET celui d'E12.1 ──
reset_int
req2 int FORGE_TOKEN=t-alice STOA_DEBUG=0
[ "$(rrc)" = 0 ] && ! grep -q '\[dbg' "$OUT" "$ERR" && cmp -s "$OUT" "$TMP/e12.stdout" \
  && ok "E12.4 STOA_DEBUG=0 : zéro ligne [dbg (stdout ET stderr), et stdout identique octet pour octet à celui d'E12.1 — le mode debug n'ajoute rien au produit" \
  || ko "E12.4 rc $(rrc) dbg=$(grep -c '\[dbg' "$OUT" "$ERR" | tr '\n' ' ') diff: $(diff "$OUT" "$TMP/e12.stdout" | head -2 | tr '\n' ' ')"
# ── E12.5 l'ordre : la base est DITE avant d'être utilisée ; la ligne du contrat est toujours là ──
reset_int
req int FORGE_TOKEN=t-alice STOA_DEBUG=1
avant "${P}GIT_BASE=master\$" '^\[1/5\] clone ci/stoa-labs \(base master\)$' \
  && ok "E12.5 « ] GIT_BASE=master » PRÉCÈDE « [1/5] clone ci/stoa-labs (base master) » — et cette ligne du contrat est toujours là" \
  || ko "E12.5 ordre : $(grep -nE 'GIT_BASE=master|\[1/5\]' "$OUT" | head -2 | tr '\n' ' ')"
reset_int
# ── E12.6 le clone RATÉ sous debug : le rc du clone n'est plus prouvé qu'à 0 ──
# E11.3 sous STOA_DEBUG=1 : GIT_BASE=develop, branche absente. La ligne
# « git clone … -> rc 128 » (le VRAI rc de git — M13 écrit 0) PRÉCÈDE le refus,
# et la ligne « git: » nomme la branche que git n'a pas trouvée (« fatal » et
# « develop », jamais la langue de git). Le refus est celui d'E11.3, inchangé.
reset_int
req int FORGE_TOKEN=t-alice GIT_BASE=develop STOA_DEBUG=1
[ "$(rrc)" = 2 ] && avant "${P}git clone --depth 1 -b develop file://[^ ]+ -> rc 128\$" '^REFUS: BRANCHE_DE_BASE_INTROUVABLE : develop' \
  && ok "E12.6a GIT_BASE=develop absente sous STOA_DEBUG=1 : « git clone --depth 1 -b develop <url> -> rc 128 » PRÉCÈDE « REFUS: BRANCHE_DE_BASE_INTROUVABLE » (rc 2 — le refus d'E11.3, inchangé)" \
  || ko "E12.6a rc $(rrc) : $(grep -nE 'git clone|REFUS' "$OUT" | head -2 | tr '\n' ' ')"
grep -qE "${P}  git: .*fatal.*develop" "$OUT" && avant "${P}  git: " '^REFUS: BRANCHE_DE_BASE_INTROUVABLE' && toutes_absentes t-alice && toutes_absentes t-ci \
  && ok "E12.6b la ligne « git: » du clone nomme la branche introuvable (fatal … develop) AVANT le refus ; jamais t-alice ni t-ci" \
  || ko "E12.6b : $(grep -nE '  git: |REFUS' "$OUT" | head -2 | tr '\n' ' ')"
# ── E12.7 PROVIDERS_MISSING sous debug : « existe=non » se DIT, avant le refus ──
# Le cas du client (2026-09-08) : un dépôt rangé AUTREMENT — GIT_SUBDIR=. (le
# livrable EST la racine). SUB_PFX est vide et se DIT « <vide> » (grammaire §2 :
# c'est le diagnostic), le fichier des providers est cherché SANS préfixe,
# absent, et « PROV_FILE=… existe=non » PRÉCÈDE le refus qui nomme le MÊME
# chemin. Jusqu'ici « existe=non » n'était exercé nulle part (relecture L2-B1
# n°4 : un « existe=oui » écrit en dur restait invisible — M14 l'écrit).
reset_int
req int FORGE_TOKEN=t-alice GIT_SUBDIR=. STOA_DEBUG=1
[ "$(rrc)" = 2 ] && grep -qE "${P}SUB_PFX=<vide>\$" "$OUT" && grep -qE "${P}REL_PATH=clients/provisioned/applications/appa\\.ansible\\.yml\$" "$OUT" \
  && ok "E12.7a GIT_SUBDIR=. sous STOA_DEBUG=1 : « ] SUB_PFX=<vide> » (le vide se DIT) et REL_PATH sans préfixe" \
  || ko "E12.7a rc $(rrc) : $(grep -nE 'SUB_PFX|REL_PATH' "$OUT" | head -2 | tr '\n' ' ')"
avant "${P}PROV_FILE=ansible/providers\\.int\\.yml existe=non\$" '^REFUS: PROVIDERS_MISSING : ansible/providers\.int\.yml absent' && toutes_absentes t-alice && toutes_absentes t-ci \
  && ok "E12.7b « ] PROV_FILE=ansible/providers.int.yml existe=non » PRÉCÈDE « REFUS: PROVIDERS_MISSING » qui nomme le MÊME chemin ; jamais t-alice ni t-ci" \
  || ko "E12.7b : $(grep -nE 'PROV_FILE|PROVIDERS_MISSING' "$OUT" | head -2 | tr '\n' ' ')"
reset_int

echo "═══ M. mutations : chaque garde neuve attrape ce qu'elle prétend attraper ═══"
MUT="$TMP/mut"; mkdir -p "$MUT"
mutant(){ # <nom> <sed-expr> → $MUT/<nom>.sh, ou vide si no-op / ne compile pas
  sed -E "$2" "$S" > "$MUT/$1.sh"
  if cmp -s "$S" "$MUT/$1.sh" || ! bash -n "$MUT/$1.sh" 2>/dev/null; then echo ""; else echo "$MUT/$1.sh"; fi
}
reqm(){ local m="$1"; shift; local e="$1"; shift; S="$m" req "$e" "$@"; }
reqm2(){ local m="$1"; shift; S="$m" req2 "$@"; }   # flux séparés (les mutants du mode debug lisent stdout SEUL)
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
# M6 (re-ciblé L2) : le détail du push passe par `redact "$PUSH_TF" < pusherr`
# (le chemin du fichier en argument, jamais le secret en argv) ; le mutant le
# remplace par un `cat` nu — l'ancien `grep -v` n'existe plus, un mutant qui le
# viserait serait un no-op (compté ko).
M6=$(mutant m6 's#redact "\$PUSH_TF" < "\$WORK/pusherr" >&2#cat "$WORK/pusherr" >\&2#')
if [ -n "$M6" ]; then set_ctl '{"open":[]}'; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null; reqm "$M6" rec FORGE_TOKEN=t-alice SHIM_PUSH_FAIL=1; [ "$(rrc)" = 1 ] && grep -q 't-alice' "$TMP/req.out" && ok "M6 redact du push remplacé par cat ⇒ le token humain fuit dans la sortie (E10 rougit)" || ko "M6 rc $(rrc) : le mutant ne fuit pas"; else ko "M6 mutant no-op/incompilable"; fi
M7=$(mutant m7 's#^requis\(\)\{.*#requis(){ :; }#')
if [ -n "$M7" ]; then set_ctl '{"open":[]}'; reset_origin; reqm "$M7" dev REQ_APP=; { [ "$(rrc)" = 2 ] && grep -q 'REFUS: CHAMP_REQUIS' "$TMP/req.out"; } && ko "M7 requis() neutralisée refuse encore" || ok "M7 requis() neutralisée ⇒ REQ_APP vide n'est plus nommé (E9.1 rougit)"; reset_origin; else ko "M7 mutant no-op/incompilable"; fi

# M8 : LE REPLI DU CLONE REVIENT (« … || git clone --depth 1 "$CLONE_URL" »), tel
# qu'il était avant le 2026-09-10. C'est LE fail-open que E11.1/E11.3 mesurent :
# le `-b <base>` échoue, le repli clone la HEAD en silence, et la demande
# continue vers une base que le clone n'a pas utilisée.
# (re-ciblé L2 : le clone n'est plus dans un `if !` — son VRAI rc est capturé
# pour la ligne de debug — ; le mutant remet le repli sur la même ligne, et le
# rc capturé devient celui du repli : 0.)
M8=$(mutant m8 's#^git clone -q --depth 1 -b "\$GIT_BASE" "\$CLONE_URL" "\$WORK/repo" 2>"\$WORK/clone\.err"; rc=\$\?$#git clone -q --depth 1 -b "$GIT_BASE" "$CLONE_URL" "$WORK/repo" 2>"$WORK/clone.err" || git clone -q --depth 1 "$CLONE_URL" "$WORK/repo"; rc=$?#')
if [ -n "$M8" ]; then
  set_ctl '{"open":[]}'; reset_origin; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-int 2>/dev/null || true
  reqm "$M8" int FORGE_TOKEN=t-alice GIT_BASE=develop
  { [ "$(rrc)" = 0 ] || ! grep -q 'REFUS: BRANCHE_DE_BASE_INTROUVABLE' "$TMP/req.out"; } \
    && ok "M8 repli du clone rétabli ⇒ un GIT_BASE inexistant repasse en SILENCE (E11.3 rougit : le refus tient à ce retrait)" \
    || ko "M8 le mutant refuse encore : rc $(rrc) — $(tail -1 "$TMP/req.out")"
  reset_origin
else ko "M8 mutant no-op/incompilable"; fi

# M9 : la ligne PORTEUSE du mode debug. Le token humain a été retiré de
# l'environnement (A7) : redact ne le connaît que par DBG_SECRET_FILES. Sans
# cette ligne, le stderr du push raté — où le shim recopie le secret de
# l'askpass — sort EN CLAIR dans la ligne de debug « git: … ». Le refus, lui,
# reste masqué (redact reçoit le fichier en argument) : la fuite est DANS une
# ligne [dbg, et nulle part ailleurs — c'est ce que l'assertion cible.
M9=$(mutant m9 '/^DBG_SECRET_FILES=/d')
if [ -n "$M9" ]; then
  set_ctl '{"open":[]}'; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null
  reqm2 "$M9" rec FORGE_TOKEN=t-alice SHIM_PUSH_FAIL=1 STOA_DEBUG=1
  grep '^\[dbg' "$ERR" | grep -q 't-alice' \
    && ok "M9 DBG_SECRET_FILES retirée ⇒ le token HUMAIN fuit dans la ligne de debug du push raté (E12.3d rougit : redact ne le connaît que par son fichier)" \
    || ko "M9 rc $(rrc) : le mutant ne fuit pas dans une ligne [dbg — $(grep -c 't-alice' "$ERR") occurrence(s) de t-alice sur stderr, toutes hors [dbg"
else ko "M9 mutant no-op/incompilable"; fi
# M10 : une ligne de debug qui se tromperait de flux. `dbg_kv REL_PATH` devient
# un `echo` (stdout) : PR_URL= y est toujours, le contrat « seul » ne suffirait
# pas — c'est l'assertion « stdout = le contrat seul » (E12.1b) qui doit rougir.
M10=$(mutant m10 's#^dbg_kv REL_PATH "\$REL_PATH"$#echo "REL_PATH=$REL_PATH"#')
if [ -n "$M10" ]; then
  reset_int
  reqm2 "$M10" int FORGE_TOKEN=t-alice STOA_DEBUG=1
  [ "$(rrc)" = 0 ] && grep -q '^PR_URL=' "$OUT" && grep -q '^REL_PATH=' "$OUT" \
    && ok "M10 dbg_kv REL_PATH ⇒ echo : stdout porte « REL_PATH=… » à côté de PR_URL= (E12.1b rougit — « pas de [dbg » seul ne le verrait pas)" \
    || ko "M10 rc $(rrc) : stdout sans REL_PATH= ($(grep -c . "$OUT") lignes)"
  reset_int
else ko "M10 mutant no-op/incompilable"; fi
# M11 : l'ORDRE de dbg_git_err — COUPER puis masquer (la première rédaction de la
# grammaire §3, corrigée par les revues B1/B3). Sur le stderr d'E12.3e (le secret
# à cheval sur l'octet 400), la coupe laisse « t-ali », que ni redact ni le dbg
# qui remasque derrière ne reconnaissent : cinq octets du token humain dans la
# ligne « git: ». La longueur le trahit aussi : 400 octets coupés PUIS remasqués
# (le masque fait 9 octets de plus que t-alice) en font 409, la forme livrée 400.
M11=$(mutant m11 's#^(    m=")\$\(redact < "\$1" [|] tr#\1$(head -c 400 < "$1" | tr#')
if [ -n "$M11" ]; then
  set_ctl '{"open":[]}'; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null
  reqm2 "$M11" rec FORGE_TOKEN=t-alice SHIM_PUSH_FAIL=1 "SHIM_PUSH_SECRET_AT=$SECRET_AT" STOA_DEBUG=1
  grep '^\[dbg' "$ERR" | grep -qF -- "askpass a rendu $FRAG" \
    && ok "M11 dbg_git_err coupe PUIS masque ⇒ « askpass a rendu $FRAG » : cinq octets du token humain fuient dans la ligne « git: », qui fait $(git_octets) octets au lieu de 400 (E12.3e ET E12.3f rougissent)" \
    || ko "M11 rc $(rrc) : le mutant ne laisse pas de morceau — …$(git_line | tail -c 40)"
else ko "M11 mutant no-op/incompilable"; fi
# M12/M13 : le rc DIT n'est pas le rc REÇU — « -> rc 0 » écrit en dur à la place
# de « -> rc $rc ». La décision qui suit lit $rc, pas la ligne : le refus reste,
# la ligne MENT. Sans E12.1w (fetch) et E12.6a (clone), ces mutants traversaient
# la suite en vert (relecture L2-B1, sondes S3/S6 : 6/6).
M12=$(mutant m12 's#^dbg "git fetch --depth 1 \$CLONE_URL refs/heads/\$\{BRANCH\} -> rc \$rc"$#dbg "git fetch --depth 1 $CLONE_URL refs/heads/${BRANCH} -> rc 0"#')
if [ -n "$M12" ]; then
  reset_int
  reqm2 "$M12" int FORGE_TOKEN=t-alice STOA_DEBUG=1
  [ "$(rrc)" = 0 ] && ! grep -qE '^\[dbg [^]]*\] git fetch .* -> rc 128$' "$ERR" && grep -qE '^\[dbg [^]]*\] git fetch .* -> rc 0$' "$ERR" \
    && ok "M12 « git fetch … -> rc 0 » en dur ⇒ le premier passage dit rc 0 là où git a rendu 128 (E12.1w rougit) — le produit, lui, est intact (rc 0)" \
    || ko "M12 rc $(rrc) : $(grep -nE 'git fetch ' "$ERR" | head -2 | tr '\n' ' ')"
  reset_int
else ko "M12 mutant no-op/incompilable"; fi
M13=$(mutant m13 's#^dbg "git clone --depth 1 -b \$GIT_BASE \$CLONE_URL -> rc \$rc"$#dbg "git clone --depth 1 -b $GIT_BASE $CLONE_URL -> rc 0"#')
if [ -n "$M13" ]; then
  reset_int
  reqm "$M13" int FORGE_TOKEN=t-alice GIT_BASE=develop STOA_DEBUG=1
  [ "$(rrc)" = 2 ] && grep -q 'REFUS: BRANCHE_DE_BASE_INTROUVABLE' "$OUT" && grep -qE '^\[dbg [^]]*\] git clone --depth 1 -b develop .* -> rc 0$' "$OUT" \
    && ok "M13 « git clone … -> rc 0 » en dur ⇒ la ligne dit rc 0 alors que REFUS: BRANCHE_DE_BASE_INTROUVABLE suit (E12.6a rougit)" \
    || ko "M13 rc $(rrc) : $(grep -nE 'git clone|REFUS' "$OUT" | head -2 | tr '\n' ' ')"
  reset_int
else ko "M13 mutant no-op/incompilable"; fi
# M14 : « existe=oui » écrit en dur — la ligne PROV_FILE ment sur le fichier que
# le refus, une ligne plus bas, dit absent. Sans E12.7b, invisible (sonde S4).
M14=$(mutant m14 's#^  _ex=non; \[ ! -f "\$PROV_FILE" \] \|\| _ex=oui$#  _ex=oui#')
if [ -n "$M14" ]; then
  reset_int
  reqm "$M14" int FORGE_TOKEN=t-alice GIT_SUBDIR=. STOA_DEBUG=1
  [ "$(rrc)" = 2 ] && grep -q 'REFUS: PROVIDERS_MISSING' "$OUT" && grep -qE '^\[dbg [^]]*\] PROV_FILE=ansible/providers\.int\.yml existe=oui$' "$OUT" \
    && ok "M14 « existe=oui » en dur ⇒ PROV_FILE dit « existe=oui » une ligne avant PROVIDERS_MISSING (E12.7b rougit)" \
    || ko "M14 rc $(rrc) : $(grep -nE 'PROV_FILE|PROVIDERS' "$OUT" | head -2 | tr '\n' ' ')"
  reset_int
else ko "M14 mutant no-op/incompilable"; fi
# M15 : le relais de forge_login (scripts/lib/forge-identity.sh) REVIENT à ce
# qu'il était avant L2-B5 — la cause relayée sur rc ≠ 0 SEULEMENT. Sur succès, la
# ligne « [dbg forge-api.py] GET …/user -> HTTP 200 » que python écrit est lue,
# effacée, perdue : c'est E12.1n' qui rougit. Mutation sur COPIE de la lib, jamais
# l'arbre ; mutant() lit $S — pointé sur la lib le temps de l'appel. La copie
# vit dans un arbre miniature (scripts/lib + ci en liens) : la lib charge sa
# voisine forge-api.sh par SON répertoire, et forge-api.sh cherche forge-api.py
# et ../../ci/lib/dbg.sh à côté d'elle — une copie SEULE serait une lib amputée
# (motif de test-archive-store ⑩). Appelée SEULE comme E0.2 (fi_run, LIB pointée
# sur la copie), sous STOA_DEBUG=1 : le login est rendu, la ligne HTTP non. Cette
# ABSENCE est doublée d'une PRÉSENCE sur le même appel — l'ÉTALON, la lib de
# l'arbre : sans lui, un fi_run qui ne ferait pas parler python (STOA_DEBUG non
# transmis, stub muet) rendrait le mutant vert pour rien.
M15=$(S="$LIB" mutant m15 's#^  \[ -z "\$cause" \] \|\| printf#  [ "$rc" -eq 0 ] || [ -z "$cause" ] || printf#')
if [ -n "$M15" ]; then
  M15T="$MUT/tree"; mkdir -p "$M15T/scripts/lib"; ln -s "$REPO/ci" "$M15T/ci"
  ln -s "$REPO/scripts/lib/forge-api.sh" "$REPO/scripts/lib/forge-api.py" "$M15T/scripts/lib/"
  cp "$M15" "$M15T/scripts/lib/forge-identity.sh"
  m15_user(){ grep -qE '^\[dbg forge-api\.py\] GET [^ ]+/user -> HTTP 200 \([0-9]+ octets\)$' "$1"; }
  set_ctl '{}'; printf 't-alice' > "$TMP/tok"
  L0=$(fi_run STOA_DEBUG=1 -- forge_login "$API" "$TMP/tok" 2>"$TMP/m15.ref"); RC0=$?
  L=$(LIB="$M15T/scripts/lib/forge-identity.sh" fi_run STOA_DEBUG=1 -- forge_login "$API" "$TMP/tok" 2>"$TMP/m15.err"); RC=$?
  [ "$RC0" = 0 ] && [ "$L0" = alice ] && m15_user "$TMP/m15.ref" \
    && [ "$RC" = 0 ] && [ "$L" = alice ] && [ "$(users)" = 2 ] && ! m15_user "$TMP/m15.err" \
    && ok "M15 relais de forge_login rendu conditionnel (rc ≠ 0 seulement) ⇒ même appel, même stub (deux whoami au journal) : l'étalon porte « GET …/user -> HTTP 200 », le mutant rend alice mais la ligne n'atteint plus stderr (E12.1n' rougit)" \
    || ko "M15 étalon rc=$RC0 login='$L0' ligne=$(m15_user "$TMP/m15.ref" && echo oui || echo non) ; mutant rc=$RC login='$L' users=$(users) : $(head -c 300 "$TMP/m15.err" | tr '\n' ' ')"
else ko "M15 mutant no-op/incompilable"; fi

echo
echo "═══════════════════════════════════════════════════"
printf 'RÉSULTAT : %d/%d\n' "$PASS" $((PASS + FAIL))
[ "$FAIL" -eq 0 ] || exit 1
