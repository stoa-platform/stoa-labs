#!/usr/bin/env bash
# shellcheck disable=SC2015  # idiome des harnais du dépôt : `cond && ok "…" || ko "…"` — ok() finit par printf, rc 0, ko ne court jamais après un ok
# test-forge-api.sh — L'ADAPTATEUR DE FORGE, PROUVÉ SUR DEUX VISAGES, HORS LIGNE.
#
# CE QU'ELLE PROUVE. scripts/lib/forge-api.py rend les MÊMES lignes CLÉ=VALEUR
# qu'il parle à Gitea (/api/v1, pulls, number, login, open, head.ref) ou à
# GitLab (/api/v4, merge_requests, iid, username, opened, source_branch). Le
# mock ci-dessous a DEUX VISAGES et rend les formes RÉELLES — dont le 302 vers
# /users/sign_in que GitLab renvoie sur /api/v1 (mesuré sur gitlab.com le
# 2026-09-09 : c'est la panne du client).
#
# POURQUOI DES MUTATIONS SUR LE MOCK. Un adaptateur « tolérant » qui lirait
# `number` OU `iid`, `login` OU `username` passerait ces épreuves sans lire la
# forme GitLab. Les mutations renomment un champ du visage gitlab (iid→number,
# username→login, source_branch→head_ref, web_url→html_url) ou une ROUTE
# (merge_requests/iid/notes→/comments) : l'adaptateur DOIT alors rougir. S'il
# reste vert, il ne lit pas GitLab — il devine.
#
# LE DISCRIMINANT. FORGE_KIND=gitea contre le visage gitlab ⇒ la cause nomme
# « 302 » et « /users/sign_in » ; FORGE_KIND=gitlab contre le visage gitea ⇒
# « 404 ». Un knob décoratif ne produirait pas ces deux refus DIFFÉRENTS.
#
# LE MODE DEBUG (section P, plan L2). Sous STOA_DEBUG=1, chaque requête HTTP se
# dit sur stderr (« [dbg forge-api.py] GET url -> HTTP 200 (N octets) », N
# MESURÉ par le mock — jamais un [0-9]+ vacant), l'init dit ce qu'il a décidé,
# stdout reste IDENTIQUE octet à octet, et le secret n'y passe jamais — ni par
# littéral (un chemin demandé qui le porte), ni par forme (un userinfo d'URL),
# ni sous sa FORME D'URL (P.7c-P.7f : un secret qui porte « + », « : » ou un
# espace entre dans l'URL en %2B/%3A/%20 par quote, ou en « + » par
# urlencode — mesuré L2-A1 tour 1 : la ligne de CHAQUE requête et la cause
# d'un refus le montraient en clair). Chaque épreuve d'absence est DOUBLÉE
# d'une présence (gabarit D1/D2/D3 de test-vault-user-login.sh) : une lib
# muette ne passe pas. Les mutants P.8 (une ligne de debug sans _mask) et P.8b
# (un registre de secrets sans les formes d'URL), sur COPIE, prouvent que P.7
# et P.7c discriminent.
#
# Hors ligne intégralement. La preuve VIVANTE (GitLab CE et Gitea du lab) est
# scripts/test-forge-api-live.sh, mêmes assertions.
#
#   bash scripts/test-forge-api.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
# ARDOISE PROPRE : un poste qui exporte STOA_DEBUG=1 ferait parler TOUTES les
# épreuves (et `cause` citerait des lignes de debug) ; la section P pose la
# valeur elle-même, cas par cas.
unset STOA_DEBUG
LIB="$REPO/scripts/lib/forge-api.sh"
PY="$REPO/scripts/lib/forge-api.py"
TMP="$(mktemp -d /tmp/forgeapi.XXXXXX)"
PIDS=""
cleanup(){ for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

[ -f "$LIB" ] && [ -f "$PY" ] || { echo "!! bibliothèque absente"; echo "RÉSULTAT : 0/1"; exit 1; }
python3 -m py_compile "$PY" && shellcheck -x "$LIB" >/dev/null 2>&1 && ok "0. forge-api.py compile, forge-api.sh shellcheck propre" || ko "0. compilation / shellcheck"
# shellcheck source=scripts/lib/forge-api.sh
. "$LIB"

# ── LE MOCK À DEUX VISAGES ───────────────────────────────────────────────────
CTL="$TMP/ctl.json"; LOG="$TMP/http.log"; POSTED="$TMP/posted.jsonl"; SIZES="$TMP/sizes.log"
cat > "$TMP/mock.py" <<'PY'
import json, os, re, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote
KIND, CTL, LOG, POSTED = os.environ["MOCK_KIND"], os.environ["MOCK_CTL"], os.environ["MOCK_LOG"], os.environ["MOCK_POSTED"]
SIZES = os.environ["MOCK_SIZES"]  # « METHODE chemin octets » par réponse : le mock connaît son corps (section P)
USERS = {"t-svc": "svc-bot", "t-alice": "alice",
         "t-s+vc": "svc-plus", "t-sp vc": "svc-espace"}  # secrets NON URL-safe (P.7c-P.7e) : acceptés, pour que la ligne soit celle d'un 200
HTML = b"<!DOCTYPE html>\n<html><head><title>Sign in \xc2\xb7 GitLab</title></head><body>GitLab</body></html>\n"
def ctl():
    try: return json.load(open(CTL))
    except Exception: return {}
def mut(name):  # une mutation renomme UN champ du visage gitlab
    return ctl().get("mutation") == name
PREP = CTL + ".prep"  # compteur des lectures de MR sous « preparing »
def prep_get():
    try: return int(open(PREP).read() or 0)
    except Exception: return 0
def prep_bump():
    n = prep_get() + 1; open(PREP, "w").write(str(n)); return n
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, *a): pass
    def raw(self, code, ctype, body, extra=()):
        with open(SIZES, "a") as f: f.write("%s %s %d\n" % (self.command, urlparse(self.path).path, len(body)))
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body)))
        for k, v in extra: self.send_header(k, v)
        self.end_headers(); self.wfile.write(body)
    def js(self, code, obj): self.raw(code, "application/json", json.dumps(obj).encode())
    def body(self):
        n = int(self.headers.get("Content-Length") or 0); return json.loads(self.rfile.read(n).decode() or "{}") if n else {}
    # ── rendu d'une PR interne sous le visage ──
    def pr_gitea(self, p):
        return {"number": p["n"], "state": "closed" if p.get("merged") else p["state"], "merged": bool(p.get("merged")),
                "merge_commit_sha": p.get("merge_sha"), "merged_by": ({"login": p["merged_by"]} if p.get("merged_by") else None),
                "head": {"ref": p["head"], "sha": p["sha"], "repo": {"full_name": p.get("head_repo", "ci/stoa-labs")}},
                "base": {"ref": p["base"]}, "user": {"login": p["author"]}, "html_url": "http://mock/pulls/%d" % p["n"]}
    def pr_gitlab(self, p):
        st = "merged" if p.get("merged") else ("opened" if p["state"] == "open" else "closed")
        d = {"iid": p["n"], "id": 1000 + p["n"], "state": st, "sha": p["sha"], "source_branch": p["head"], "target_branch": p["base"],
             "source_project_id": 7 if p.get("head_repo", "ci/stoa-labs") == "ci/stoa-labs" else 99, "target_project_id": 7,
             "merge_commit_sha": p.get("merge_sha"), "merge_user": ({"username": p["merged_by"]} if p.get("merged_by") else None),
             "author": {"username": p["author"]}, "web_url": "http://mock/-/merge_requests/%d" % p["n"],
             "prepared_at": "2026-09-09T00:00:00.000Z", "detailed_merge_status": "mergeable"}
        if mut("iid_as_number"): d["number"] = d.pop("iid")
        if mut("username_as_login"): d["author"] = {"login": p["author"]}
        if mut("source_branch_as_head_ref"): d["head_ref"] = d.pop("source_branch")
        if mut("web_url_as_html_url"): d["html_url"] = d.pop("web_url")
        return d
    def route(self, method):
        u = urlparse(self.path); q = parse_qs(u.query); path = u.path; c = ctl()
        with open(LOG, "a") as f: f.write("%s %s %s\n" % (method, path, "|".join("%s=%s" % (k, self.headers.get(k)) for k in ("Authorization", "PRIVATE-TOKEN") if self.headers.get(k))))
        bm = c.get("body_mode")
        # ── visage GITLAB ──
        if KIND == "gitlab":
            if path.startswith("/api/v1/"): return self.raw(302, "text/html", b"", [("Location", "/users/sign_in")])
            if path == "/users/sign_in": return self.raw(200, "text/html; charset=utf-8", HTML)
            tok = self.headers.get("PRIVATE-TOKEN") or ""
            auth = self.headers.get("Authorization") or ""
            if not tok and auth.startswith("Bearer "): tok = auth[7:]
            if path == "/api/v4/version":
                return self.js(200, {"version": "17.11.0"}) if tok in USERS else self.js(401, {"message": "401 Unauthorized"})
            if tok not in USERS: return self.js(401, {"message": "401 Unauthorized"})
            if path == "/api/v4/user":
                d = {"id": 1, "username": USERS[tok], "name": USERS[tok]}
                if mut("username_as_login"): d = {"id": 1, "login": USERS[tok]}
                return self.js(200, d)
            m = re.match(r"^/api/v4/projects/([^/]+)/(.*)$", path)
            if not m: return self.js(404, {"message": "404 Not Found"})
            proj, rest = unquote(m.group(1)), m.group(2)
            if proj != "ci/stoa-labs": return self.js(404, {"message": "404 Project Not Found"})
            prs = c.get("prs", [])
            if rest == "merge_requests" and method == "GET":
                if bm == "empty": return self.raw(200, "application/json", b"")
                if bm == "html": return self.raw(200, "text/html", HTML)
                if bm == "object": return self.js(200, {"message": "not a list"})
                if bm == "echo_auth": return self.raw(200, "text/html", b"<pre>" + (self.headers.get("PRIVATE-TOKEN") or "").encode() + b"</pre>")
                st = (q.get("state") or [None])[0]; sb = (q.get("source_branch") or [None])[0]
                page = int((q.get("page") or ["1"])[0]); per = int((q.get("per_page") or ["20"])[0])
                if bm == "endless":  # une page PLEINE et neuve à chaque appel : la liste ne finit jamais
                    return self.js(200, [self.pr_gitlab({"n": page * 1000 + i, "state": "merged", "merged": True, "head": sb or "x", "base": "main", "sha": "d" * 40, "author": "alice", "merge_sha": "e" * 40}) for i in range(per)])
                items = [self.pr_gitlab(p) for p in prs
                         if (st is None or (st == "opened" and p["state"] == "open" and not p.get("merged")) or (st == "merged" and p.get("merged")))
                         and (sb is None or p["head"] == sb)]
                return self.js(200, items[(page-1)*per: page*per])
            if rest == "merge_requests" and method == "POST":
                b = self.body(); open(POSTED, "a").write(json.dumps({"kind": "gitlab", "headers": dict(self.headers), "body": b}) + "\n")
                p = {"n": 900, "state": "open", "head": b.get("source_branch"), "base": b.get("target_branch"), "sha": "c" * 40, "author": USERS[tok]}
                return self.js(201, self.pr_gitlab(p))
            mm = re.match(r"^merge_requests/(\d+)(/.*)?$", rest)
            if mm:
                n = int(mm.group(1)); sub = mm.group(2) or ""
                p = next((x for x in prs if x["n"] == n), None)
                if p is None: return self.js(404, {"message": "404 Not found"})
                # preparing: K — les K premières lectures de la MR la disent EN PRÉPARATION
                # (prepared_at nul, comme le vrai GitLab pendant ~4 s) et /diffs rend [] tant
                # que ces K lectures n'ont pas eu lieu.
                k = int(c.get("preparing") or 0)
                if sub == "":
                    d = self.pr_gitlab(p)
                    if k and prep_bump() <= k: d["prepared_at"] = None; d["detailed_merge_status"] = "preparing"
                    return self.js(200, d)
                if sub == "/diffs":
                    if k and prep_get() <= k: return self.js(200, [])
                    page = int((q.get("page") or ["1"])[0]); return self.js(200, [{"new_path": f, "old_path": f} for f in p.get("files", [])] if page == 1 else [])
                # mutation notes_as_comments : le fil vit sous /comments, /notes n'existe plus —
                # un adaptateur qui lirait « issues/N/comments » partout passerait ici.
                if mut("notes_as_comments") and sub.startswith("/notes"): return self.js(404, {"message": "404 Not Found"})
                if (sub == "/notes" or (mut("notes_as_comments") and sub == "/comments")) and method == "GET":
                    page = int((q.get("page") or ["1"])[0]); return self.js(200, [{"id": i + 1, "body": t} for i, t in enumerate(c.get("notes", []))] if page == 1 else [])
                if sub == "/notes" and method == "POST":
                    b = self.body(); open(POSTED, "a").write(json.dumps({"kind": "gitlab", "note": b}) + "\n"); return self.js(201, {"id": 77, "body": b.get("body")})
                mn = re.match(r"^/notes/(\d+)$", sub)
                if mn and method == "PUT":
                    b = self.body(); open(POSTED, "a").write(json.dumps({"kind": "gitlab", "note_put": int(mn.group(1)), "body": b}) + "\n"); return self.js(200, {"id": int(mn.group(1))})
            mr = re.match(r"^repository/files/([^/]+)/raw$", rest)
            if mr:
                pth = unquote(mr.group(1)); files = c.get("raw", {})
                return self.raw(200, "text/plain", files[pth].encode()) if pth in files else self.js(404, {"message": "404 File Not Found"})
            return self.js(404, {"message": "404 Not Found"})
        # ── visage GITEA ──
        if path.startswith("/api/v4/"): return self.js(404, {"message": "Not Found", "errors": [], "url": "http://mock/api/swagger"})
        auth = self.headers.get("Authorization") or ""
        tok = auth[6:] if auth.startswith("token ") else ""
        if path == "/api/v1/version": return self.js(200, {"version": "1.22.6"})
        if tok not in USERS: return self.js(401, {"message": "token does not exist"})
        if path == "/api/v1/user": return self.js(200, {"id": 1, "login": USERS[tok]})
        m = re.match(r"^/api/v1/repos/([^/]+/[^/]+)/(.*)$", path)
        if not m: return self.js(404, {"message": "route inconnue " + path})
        proj, rest = m.group(1), m.group(2)
        if proj != "ci/stoa-labs": return self.js(404, {"message": "The target couldn't be found."})
        prs = c.get("prs", [])
        if rest == "pulls" and method == "GET":
            if bm == "empty": return self.raw(200, "application/json", b"")
            st = (q.get("state") or ["open"])[0]; page = int((q.get("page") or ["1"])[0]); limit = int((q.get("limit") or ["50"])[0])
            items = [self.pr_gitea(p) for p in prs if (st == "open" and p["state"] == "open" and not p.get("merged")) or (st == "closed" and (p["state"] == "closed" or p.get("merged"))) or st == "all"]
            return self.js(200, items[(page-1)*limit: page*limit])
        if rest == "pulls" and method == "POST":
            b = self.body(); open(POSTED, "a").write(json.dumps({"kind": "gitea", "headers": dict(self.headers), "body": b}) + "\n")
            p = {"n": 900, "state": "open", "head": b.get("head"), "base": b.get("base"), "sha": "c" * 40, "author": USERS[tok]}
            return self.js(201, self.pr_gitea(p))
        mp = re.match(r"^pulls/(\d+)(/.*)?$", rest)
        if mp:
            n = int(mp.group(1)); sub = mp.group(2) or ""; p = next((x for x in prs if x["n"] == n), None)
            if p is None: return self.js(404, {"message": "Not Found"})
            if sub == "": return self.js(200, self.pr_gitea(p))
            if sub == "/files":
                page = int((q.get("page") or ["1"])[0]); return self.js(200, [{"filename": f} for f in p.get("files", [])] if page == 1 else [])
        mi = re.match(r"^issues/(\d+)/comments$", rest)
        if mi and method == "GET":
            page = int((q.get("page") or ["1"])[0]); return self.js(200, [{"id": i + 1, "body": t} for i, t in enumerate(c.get("notes", []))] if page == 1 else [])
        if mi and method == "POST":
            b = self.body(); open(POSTED, "a").write(json.dumps({"kind": "gitea", "note": b}) + "\n"); return self.js(201, {"id": 77, "body": b.get("body")})
        mc = re.match(r"^issues/comments/(\d+)$", rest)
        if mc and method == "PATCH":
            b = self.body(); open(POSTED, "a").write(json.dumps({"kind": "gitea", "note_patch": int(mc.group(1)), "body": b}) + "\n"); return self.js(200, {"id": int(mc.group(1))})
        mr = re.match(r"^raw/(.+)$", rest)
        if mr:
            pth = unquote(mr.group(1)); files = c.get("raw", {})
            return self.raw(200, "text/plain", files[pth].encode()) if pth in files else self.js(404, {"message": "Not Found"})
        return self.js(404, {"message": "route inconnue " + path})
    def do_GET(self): self.route("GET")
    def do_POST(self): self.route("POST")
    def do_PUT(self): self.route("PUT")
    def do_PATCH(self): self.route("PATCH")
srv = ThreadingHTTPServer(("127.0.0.1", 0), H); print(srv.server_address[1], flush=True); srv.serve_forever()
PY
start_mock(){ # <kind> → imprime l'URL
  local port
  MOCK_KIND="$1" MOCK_CTL="$CTL" MOCK_LOG="$LOG" MOCK_POSTED="$POSTED" MOCK_SIZES="$SIZES" python3 "$TMP/mock.py" > "$TMP/port.$1" 2>"$TMP/err.$1" &
  PIDS="$PIDS $!"
  for _ in $(seq 1 60); do [ -s "$TMP/port.$1" ] && break; sleep 0.1; done
  port="$(head -n1 "$TMP/port.$1")"; case "$port" in ''|*[!0-9]*) echo "!! mock $1 non démarré : $(cat "$TMP/err.$1")"; exit 2;; esac
  printf 'http://127.0.0.1:%s' "$port"
}
GITEA="$(start_mock gitea)"; GITLAB="$(start_mock gitlab)"
set_ctl(){ printf '%s' "$1" > "$CTL"; : > "$LOG"; : > "$POSTED"; : > "$SIZES"; rm -f "$CTL.prep"; }
PRS='{"prs":[
 {"n":41,"state":"open","head":"provision/appa-rec","base":"main","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","author":"alice","files":["poc/clients/appa.ansible.yml","poc/clients/certs/appa-rec.crt"]},
 {"n":42,"state":"open","head":"provision/fork-dev","base":"main","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","author":"mallory","head_repo":"mallory/stoa-labs"},
 {"n":43,"state":"closed","merged":true,"merge_sha":"dddddddddddddddddddddddddddddddddddddddd","merged_by":"carol","head":"provision/appa-dev","base":"main","sha":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","author":"alice"}],
 "notes":["bonjour","<!-- plan:appa-rec -->\nancien verdict"],
 "raw":{"poc/ansible/providers.dev.yml":"providers:\n  - team: fbi\n"}}'
set_ctl "$PRS"

# f <kind> <host> <verbe…> → stdout dans $TMP/out, stderr dans $TMP/err, rc dans $TMP/rc
f(){
  local k="$1" h="$2"; shift 2
  ( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" FORGE_KIND="$k" GIT_HOST="$h" GIT_REPO=ci/stoa-labs FORGE_SECRET=t-svc bash -c '. scripts/lib/forge-api.sh && forge_api_init && forge "$@"' _ "$@" ) > "$TMP/out" 2> "$TMP/err"
  echo $? > "$TMP/rc"
}
rc(){ cat "$TMP/rc"; }
val(){ sed -n "s/^$1=//p" "$TMP/out" | head -1; }
cause(){ head -c 200 "$TMP/err" | tr '\n' ' '; }
# nom du champ / de l'en-tête selon le visage, pour les libellés
nom(){ case "$K" in gitlab) printf '%s' "$1";; *) printf '%s' "$2";; esac; }

for K in gitea gitlab; do
  case "$K" in gitea) H="$GITEA";; *) H="$GITLAB";; esac
  echo "═══ visage $K ═══"
  f "$K" "$H" probe
  [ "$(rc)" = 0 ] && [ "$(val KIND_DETECTED)" = "$K" ] && ok "$K A.1 probe (sans secret) détecte le visage : $(val KIND_DETECTED)" || ko "$K A.1 rc $(rc) : $(cat "$TMP/out") $(cause)"
  f "$K" "$H" whoami
  [ "$(rc)" = 0 ] && [ "$(val LOGIN)" = svc-bot ] && ok "$K B.1 whoami ⇒ LOGIN=svc-bot ($(nom username login) lu)" || ko "$K B.1 rc $(rc) : $(cause)"
  f "$K" "$H" pr_find_open provision/appa-rec
  [ "$(rc)" = 0 ] && [ "$(val NUMBER)" = 41 ] && [ "$(val LOGIN)" = alice ] && ok "$K C.1 pr_find_open ⇒ NUMBER=41 LOGIN=alice" || ko "$K C.1 rc $(rc) : $(cat "$TMP/out") $(cause)"
  f "$K" "$H" pr_find_open provision/fork-dev
  [ "$(rc)" = 0 ] && [ -z "$(val NUMBER)" ] && ok "$K C.2 une PR venue d'un FORK n'est pas « la nôtre » ⇒ NUMBER vide" || ko "$K C.2 rc $(rc) NUMBER=$(val NUMBER)"
  f "$K" "$H" pr_find_open provision/inexistante
  [ "$(rc)" = 0 ] && [ -z "$(val NUMBER)" ] && ok "$K C.3 aucune PR ⇒ NUMBER vide, rc 0 (ce n'est pas une panne)" || ko "$K C.3 rc $(rc)"
  f "$K" "$H" pr_get 41
  SHA_A="$(printf 'a%.0s' $(seq 40))"
  [ "$(rc)" = 0 ] && [ "$(val STATE)" = open ] && [ "$(val HEAD_REF)" = provision/appa-rec ] && [ "$(val HEAD_SHA)" = "$SHA_A" ] && [ "$(val BASE_REF)" = main ] && [ "$(val SAME_REPO)" = 1 ] && [ "$(val MERGED)" = 0 ] \
    && ok "$K D.1 pr_get 41 ⇒ STATE=open HEAD_REF/HEAD_SHA/BASE_REF SAME_REPO=1 MERGED=0" || ko "$K D.1 rc $(rc) : $(tr '\n' ' ' < "$TMP/out") $(cause)"
  f "$K" "$H" pr_get 42
  [ "$(rc)" = 0 ] && [ "$(val SAME_REPO)" = 0 ] && ok "$K D.2 pr_get 42 (fork) ⇒ SAME_REPO=0" || ko "$K D.2 rc $(rc) SAME_REPO=$(val SAME_REPO)"
  f "$K" "$H" pr_get 43
  SHA_D="$(printf 'd%.0s' $(seq 40))"
  [ "$(rc)" = 0 ] && [ "$(val STATE)" = merged ] && [ "$(val MERGED)" = 1 ] && [ "$(val MERGE_SHA)" = "$SHA_D" ] && [ "$(val MERGED_BY)" = carol ] \
    && ok "$K D.3 pr_get 43 (mergée) ⇒ STATE=merged MERGE_SHA MERGED_BY=carol" || ko "$K D.3 rc $(rc) : $(tr '\n' ' ' < "$TMP/out")"
  f "$K" "$H" pr_get 999
  [ "$(rc)" = 2 ] && grep -q '404' "$TMP/err" && [ ! -s "$TMP/out" ] && ok "$K D.4 PR inconnue ⇒ rc 2, cause « 404 », rien sur stdout" || ko "$K D.4 rc $(rc) : $(cause)"
  : > "$LOG"; f "$K" "$H" pr_get '41/../x'
  [ "$(rc)" = 2 ] && ! grep -q 'GET' "$LOG" && ok "$K D.5 numéro non numérique ⇒ refus SANS appel réseau" || ko "$K D.5 rc $(rc) appels=$(wc -l < "$LOG")"
  printf 'corps de la PR\n' > "$TMP/body.txt"
  f "$K" "$H" pr_open provision/appa-int main "provision(int): appa" "$TMP/body.txt"
  if [ "$K" = gitlab ]; then champ_ok=$(python3 -c 'import json,sys;b=json.loads(open(sys.argv[1]).readlines()[-1])["body"];print("1" if b.get("source_branch")=="provision/appa-int" and b.get("target_branch")=="main" and "head" not in b else "0")' "$POSTED")
  else champ_ok=$(python3 -c 'import json,sys;b=json.loads(open(sys.argv[1]).readlines()[-1])["body"];print("1" if b.get("head")=="provision/appa-int" and b.get("base")=="main" and "source_branch" not in b else "0")' "$POSTED"); fi
  [ "$(rc)" = 0 ] && [ "$(val NUMBER)" = 900 ] && [ -n "$(val URL)" ] && [ "$champ_ok" = 1 ] && ok "$K E.1 pr_open ⇒ NUMBER=900 URL, corps POSTÉ dans les champs DE CE visage" || ko "$K E.1 rc $(rc) champs=$champ_ok : $(cause)"
  # Les noms d'en-tête HTTP sont insensibles à la casse (RFC 7230) : urllib
  # envoie « Private-token », GitLab lit HTTP_PRIVATE_TOKEN — comparer en minuscules.
  hdr_ok=$(python3 -c 'import json,sys;h={k.lower():v for k,v in json.loads(open(sys.argv[1]).readlines()[-1])["headers"].items()};k=sys.argv[2];print("1" if (k=="gitlab" and h.get("private-token")=="t-svc" and "authorization" not in h) or (k=="gitea" and h.get("authorization")=="token t-svc") else "0")' "$POSTED" "$K")
  [ "$hdr_ok" = 1 ] && ok "$K E.2 l'en-tête d'auth est celui DE CE visage ($(nom PRIVATE-TOKEN 'Authorization: token'))" || ko "$K E.2 en-tête inattendu"
  f "$K" "$H" pr_files 41
  [ "$(rc)" = 0 ] && [ "$(wc -l < "$TMP/out" | tr -d ' ')" = 2 ] && grep -q 'certs/appa-rec.crt' "$TMP/out" && ok "$K F.1 pr_files 41 ⇒ 2 chemins ($(nom new_path filename))" || ko "$K F.1 rc $(rc) : $(tr '\n' ' ' < "$TMP/out")"
  # pr_list_merged : la LIGNÉE d'une branche (A6) — une ligne par PR mergée de
  # cette tête, dans le vocabulaire normalisé ; la PR OUVERTE (#41) n'en est pas.
  f "$K" "$H" pr_list_merged provision/appa-dev
  [ "$(rc)" = 0 ] && [ "$(wc -l < "$TMP/out" | tr -d ' ')" = 1 ] && grep -q "^NUMBER=43 MERGE_SHA=$(printf 'd%.0s' $(seq 40)) BASE_REF=main SAME_REPO=1 HEAD_REPO=" "$TMP/out" \
    && ok "$K F.2 pr_list_merged provision/appa-dev ⇒ UNE ligne « NUMBER=43 MERGE_SHA= BASE_REF=main SAME_REPO=1 HEAD_REPO= » ($(nom 'state=merged&source_branch' 'state=closed, filtré ici'))" || ko "$K F.2 rc $(rc) : $(tr '\n' ' ' < "$TMP/out") $(cause)"
  f "$K" "$H" pr_list_merged provision/appa-rec
  [ "$(rc)" = 0 ] && [ ! -s "$TMP/out" ] && ok "$K F.3 pr_list_merged sur une tête dont la seule PR est OUVERTE ⇒ rien, rc 0 (une lignée vide n'est pas une panne)" || ko "$K F.3 rc $(rc) : $(tr '\n' ' ' < "$TMP/out") $(cause)"
  printf 'nouveau verdict\n' > "$TMP/note.txt"
  set_ctl "$PRS"; f "$K" "$H" comment_upsert 41 '<!-- plan:appa-rec -->' "$TMP/note.txt"
  upd=$(python3 -c 'import json,sys;l=[json.loads(x) for x in open(sys.argv[1])];print("1" if any(("note_put" in x or "note_patch" in x) for x in l) and not any("note" in x for x in l) else "0")' "$POSTED")
  [ "$(rc)" = 0 ] && [ "$(val ACTION)" = updated ] && [ "$(val ID)" = 2 ] && [ "$upd" = 1 ] && ok "$K G.1 comment_upsert, marqueur présent ⇒ ACTION=updated ID=2 par $(nom PUT PATCH), aucun POST" || ko "$K G.1 rc $(rc) ACTION=$(val ACTION) ID=$(val ID) upd=$upd"
  set_ctl "$PRS"; f "$K" "$H" comment_upsert 41 '<!-- apply:appa-rec -->' "$TMP/note.txt"
  [ "$(rc)" = 0 ] && [ "$(val ACTION)" = created ] && [ "$(val ID)" = 77 ] && ok "$K G.2 marqueur absent ⇒ ACTION=created ID=77 (POST)" || ko "$K G.2 rc $(rc) ACTION=$(val ACTION)"
  # comment_find : la même pagination que comment_upsert, en LECTURE seule — c'est
  # ce que COMMENT_ONLY_IF_EXISTS demande (rafraîchir un statut, jamais en créer).
  set_ctl "$PRS"; f "$K" "$H" comment_find 41 '<!-- plan:appa-rec -->'
  [ "$(rc)" = 0 ] && [ "$(val ID)" = 2 ] && ! grep -qE '^(POST|PUT|PATCH)' "$LOG" && ok "$K G.3 comment_find, marqueur présent ⇒ ID=2, sans aucune écriture (ni POST, ni $(nom PUT PATCH))" || ko "$K G.3 rc $(rc) ID=$(val ID) écritures=$(grep -cE '^(POST|PUT|PATCH)' "$LOG") : $(cause)"
  set_ctl "$PRS"; f "$K" "$H" comment_find 41 '<!-- apply:appa-rec -->'
  [ "$(rc)" = 0 ] && grep -qx 'ID=' "$TMP/out" && ! grep -qE '^(POST|PUT|PATCH)' "$LOG" && ok "$K G.4 marqueur absent ⇒ ID= vide, rc 0 (« aucun commentaire » n'est pas une panne), rien d'écrit" || ko "$K G.4 rc $(rc) : $(tr '\n' ' ' < "$TMP/out") $(cause)"
  f "$K" "$H" raw poc/ansible/providers.dev.yml main
  [ "$(rc)" = 0 ] && grep -q 'team: fbi' "$TMP/out" && ok "$K H.1 raw ⇒ le contenu, brut ($(nom 'repository/files/<enc>/raw?ref=' 'raw/<chemin>'))" || ko "$K H.1 rc $(rc) : $(cause)"
  f "$K" "$H" raw poc/ansible/providers.rec.yml main
  [ "$(rc)" = 2 ] && grep -q '404' "$TMP/err" && ok "$K H.2 raw absent ⇒ rc 2, cause « 404 »" || ko "$K H.2 rc $(rc)"
  ( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" FORGE_KIND="$K" GIT_HOST="$H" GIT_REPO=ci/stoa-labs FORGE_SECRET=mauvais bash -c '. scripts/lib/forge-api.sh && forge_api_init && forge whoami' ) > "$TMP/out" 2> "$TMP/err"; echo $? > "$TMP/rc"
  [ "$(rc)" = 2 ] && grep -q '401' "$TMP/err" && grep -q 'REFUSE le secret' "$TMP/err" && ok "$K I.1 secret refusé ⇒ cause « 401 … REFUSE le secret »" || ko "$K I.1 rc $(rc) : $(cause)"
done
set_ctl "$PRS"

echo "═══ J. le DISCRIMINANT : le visage n'est pas décoratif ═══"
f gitea "$GITLAB" pr_find_open provision/appa-rec
[ "$(rc)" = 2 ] && grep -q '302' "$TMP/err" && grep -q '/users/sign_in' "$TMP/err" && grep -qi 'redirige' "$TMP/err" && ! grep -q 'Traceback' "$TMP/err" \
  && ok "J.1 FORGE_KIND=gitea contre un GitLab ⇒ « la forge REDIRIGE vers /users/sign_in … 302 » — la ligne que le client doit lire" || ko "J.1 rc $(rc) : $(cause)"
f gitlab "$GITEA" pr_find_open provision/appa-rec
[ "$(rc)" = 2 ] && grep -q '404' "$TMP/err" && ok "J.2 FORGE_KIND=gitlab contre un Gitea ⇒ « 404 » sur /api/v4 (refus DIFFÉRENT : le knob décide)" || ko "J.2 rc $(rc) : $(cause)"
f gitlab "$GITLAB" probe; f gitea "$GITLAB" probe
[ "$(val KIND_DETECTED)" = gitlab ] && ok "J.3 probe sous le MAUVAIS knob dit quand même le vrai visage (gitlab) : le remède est dans la cause" || ko "J.3 $(val KIND_DETECTED)"

echo "═══ K. la garde : ce que le client a vu, nommé ═══"
set_ctl '{"body_mode":"empty"}'; f gitlab "$GITLAB" pr_find_open x
[ "$(rc)" = 2 ] && grep -q 'corps VIDE' "$TMP/err" && grep -q 'HTTP 200' "$TMP/err" && grep -q '0 octet' "$TMP/err" && ok "K.1 corps vide ⇒ « corps VIDE — GET … → HTTP 200 …, 0 octet(s) »" || ko "K.1 rc $(rc) : $(cause)"
set_ctl '{"body_mode":"html"}'; f gitlab "$GITLAB" pr_find_open x
[ "$(rc)" = 2 ] && grep -q 'NON JSON' "$TMP/err" && grep -q 'text/html' "$TMP/err" && grep -q 'DOCTYPE' "$TMP/err" && ok "K.2 page HTML ⇒ « NON JSON … text/html … début : '<!DOCTYPE' »" || ko "K.2 rc $(rc) : $(cause)"
set_ctl '{"body_mode":"object"}'; f gitlab "$GITLAB" pr_find_open x
[ "$(rc)" = 2 ] && grep -q 'LISTE' "$TMP/err" && ok "K.3 objet là où une liste est attendue ⇒ refus (jamais « aucune PR »)" || ko "K.3 rc $(rc) : $(cause)"
set_ctl '{"body_mode":"echo_auth"}'; f gitlab "$GITLAB" pr_find_open x
[ "$(rc)" = 2 ] && grep -q '<secret masqué>' "$TMP/err" && ! grep -q 't-svc' "$TMP/err" && ok "K.4 un corps qui recopie l'en-tête ⇒ « <secret masqué> », jamais le secret" || ko "K.4 rc $(rc) fuite=$(grep -c t-svc "$TMP/err")"
set_ctl "$PRS"
f gitlab "http://127.0.0.1:1" whoami
[ "$(rc)" = 2 ] && grep -q 'injoignable' "$TMP/err" && ok "K.5 port fermé ⇒ « forge injoignable », pas une trace" || ko "K.5 rc $(rc) : $(cause)"
( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitlab GIT_HOST="$GITLAB/" GIT_REPO=ci/stoa-labs FORGE_SECRET=t-svc bash -c '. scripts/lib/forge-api.sh && forge_api_init && forge whoami' ) > "$TMP/out" 2> "$TMP/err"; echo $? > "$TMP/rc"
[ "$(rc)" = 0 ] && [ "$(val LOGIN)" = svc-bot ] && ! grep -q '//api' "$LOG" && ok "K.6 GIT_HOST avec slash final ⇒ base composée sans « // » (13 des 14 anciennes compositions ne le faisaient pas)" || ko "K.6 rc $(rc) : $(grep api "$LOG" | head -1)"
( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitlab GIT_HOST="http://127.0.0.1:1" FORGE_API_BASE="$GITLAB/api/v4" GIT_REPO=ci/stoa-labs FORGE_SECRET=t-svc bash -c '. scripts/lib/forge-api.sh && forge_api_init && forge whoami' ) > "$TMP/out" 2> "$TMP/err"; echo $? > "$TMP/rc"
[ "$(rc)" = 0 ] && [ "$(val LOGIN)" = svc-bot ] && ok "K.7 FORGE_API_BASE l'emporte (reverse-proxy qui déplace /api) : GIT_HOST mort, API vivante" || ko "K.7 rc $(rc) : $(cause)"

echo "═══ L. le secret ne passe jamais par argv, et forge_kv lit sans eval ═══"
# shellcheck disable=SC2016  # motifs cherchés DANS la lib, jamais des expansions
grep -q 'python3 "$_FORGE_API_PY" "$@"' "$LIB" && ! grep -qE 'python3.*\$FORGE_SECRET' "$LIB" && ok "L.1 forge() passe le secret par l'ENV, jamais dans l'argv de python3" || ko "L.1"
printf 't-svc' > "$TMP/secretfile"
# shellcheck disable=SC2016  # le bash enfant expanse $PR_*, à dessein
( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitlab GIT_HOST="$GITLAB" GIT_REPO=ci/stoa-labs FORGE_SECRET_FILE="$TMP/secretfile" bash -c '. scripts/lib/forge-api.sh && forge_api_init && forge_kv PR pr_get 41 && printf "%s|%s|%s\n" "$PR_NUMBER" "$PR_HEAD_REF" "$PR_LOGIN"' ) > "$TMP/out" 2> "$TMP/err"; echo $? > "$TMP/rc"
[ "$(rc)" = 0 ] && [ "$(cat "$TMP/out")" = "41|provision/appa-rec|alice" ] && ok "L.2 FORGE_SECRET_FILE + forge_kv ⇒ PR_NUMBER/PR_HEAD_REF/PR_LOGIN posés sans eval" || ko "L.2 rc $(rc) : $(cat "$TMP/out") $(cause)"

echo "═══ M. mutations du visage gitlab : l'adaptateur lit les VRAIS noms, il ne devine pas ═══"
mute(){ # <mutation> <verbe…> : sous cette mutation, le verbe DOIT échouer ou rendre vide
  local m="$1"; shift
  set_ctl "$(python3 -c 'import json,sys;d=json.loads(sys.argv[1]);d["mutation"]=sys.argv[2];print(json.dumps(d))' "$PRS" "$m")"
  f gitlab "$GITLAB" "$@"
}
mute iid_as_number pr_get 41
{ [ "$(rc)" != 0 ] || [ -z "$(val NUMBER)" ]; } && ok "M1 iid→number ⇒ pr_get ne rend plus NUMBER (l'adaptateur lit iid, pas number)" || ko "M1 le mutant passe : NUMBER=$(val NUMBER)"
mute username_as_login whoami
[ "$(rc)" = 2 ] && ok "M2 username→login ⇒ whoami refuse (il lit username)" || ko "M2 le mutant passe : $(val LOGIN)"
mute source_branch_as_head_ref pr_find_open provision/appa-rec
{ [ "$(rc)" != 0 ] || [ -z "$(val NUMBER)" ]; } && ok "M3 source_branch→head_ref ⇒ pr_find_open ne trouve plus la PR" || ko "M3 le mutant passe : NUMBER=$(val NUMBER)"
mute source_branch_as_head_ref pr_list_merged provision/appa-dev
{ [ "$(rc)" != 0 ] || [ ! -s "$TMP/out" ]; } && ok "M3b source_branch→head_ref ⇒ pr_list_merged ne rend plus #43 (le filtre est rejoué sur source_branch, la forge n'est pas crue sur parole)" || ko "M3b le mutant passe : $(head -1 "$TMP/out")"
mute web_url_as_html_url pr_get 41
[ "$(rc)" = 0 ] && [ -z "$(val URL)" ] && ok "M4 web_url→html_url ⇒ URL vide (il lit web_url)" || ko "M4 le mutant passe : URL=$(val URL)"
mute notes_as_comments comment_find 41 '<!-- plan:appa-rec -->'
[ "$(rc)" = 2 ] && grep -q '404' "$TMP/err" && ok "M5 notes→comments ⇒ comment_find refuse (404 : il lit merge_requests/iid/notes, jamais « comments » sur GitLab)" || ko "M5 le mutant passe : rc $(rc) ID=$(val ID)"
set_ctl "$PRS"

echo "═══ N. sous set -x, rien ne fuit ; les knobs atteignent python sans export ; la 41e page refuse ═══"
# La lib et son python, copiés ENSEMBLE (la lib localise le python à côté d'elle) :
# c'est cette copie que les mutants de N altèrent, jamais l'original.
mkdir -p "$TMP/lib"; cp "$LIB" "$TMP/lib/forge-api.sh"; cp "$PY" "$TMP/lib/forge-api.py"
# trace <lib> [STOA_DEBUG] : whoami sous `bash -x`, secret t-svc, trace sur stderr ⇒ $TMP/trace
# (STOA_DEBUG vide = muet, pour les deux autorités ; P.9 le pose à 1)
# shellcheck disable=SC2016  # le bash enfant reçoit $1, à dessein
trace(){
  ( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" STOA_DEBUG="${2:-}" FORGE_KIND=gitlab GIT_HOST="$GITLAB" GIT_REPO=ci/stoa-labs FORGE_SECRET=t-svc \
      bash -x -c '. "$1" && forge_api_init && forge whoami' _ "$1" ) > "$TMP/out" 2> "$TMP/trace"; echo $? > "$TMP/rc"
}
trace "$TMP/lib/forge-api.sh"
[ "$(rc)" = 0 ] && [ "$(val LOGIN)" = svc-bot ] && grep -q '^+ python3 ' "$TMP/trace" && [ "$(grep -c 't-svc' "$TMP/trace")" = 0 ] \
  && ok "N.1 sous \`bash -x\`, whoami rend le login et la trace (qui montre bien \`+ python3 …\`) ne porte JAMAIS le secret" \
  || ko "N.1 rc $(rc) LOGIN=$(val LOGIN) occurrences=$(grep -c 't-svc' "$TMP/trace") : $(grep 't-svc' "$TMP/trace" | head -1 | cut -c1-120)"
# Mutant : le préfixe d'antan `FORGE_SECRET=… python3` réintroduit ⇒ la trace le montre.
# shellcheck disable=SC2016  # motifs cherchés DANS la lib, jamais des expansions
sed 's|^  python3 "\$_FORGE_API_PY" "\$@" 3<<_FORGE_EOF$|  FORGE_SECRET="${FORGE_SECRET:-${GITEA_TOKEN:-}}" python3 "$_FORGE_API_PY" "$@" 3<<_FORGE_EOF|' "$TMP/lib/forge-api.sh" > "$TMP/lib/mut.sh"
# shellcheck disable=SC2016
grep -q 'FORGE_SECRET="${FORGE_SECRET' "$TMP/lib/mut.sh" || ko "N.2 mutant non appliqué (ancre absente)"
trace "$TMP/lib/mut.sh"
[ "$(grep -c 't-svc' "$TMP/trace")" -ge 1 ] && ok "N.2 mutant (préfixe FORGE_SECRET=… python3) ⇒ le secret apparaît dans la trace : N.1 discrimine" || ko "N.2 le mutant passe : 0 occurrence"
# Les knobs posés SANS export (provision-plan.sh les pose ainsi) atteignent python.
# shellcheck disable=SC2016  # le bash enfant pose ses variables lui-même, à dessein
( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" FORGE_SECRET=t-svc bash -c 'FORGE_KIND=gitlab; GIT_HOST="$1"; GIT_REPO=ci/stoa-labs; . scripts/lib/forge-api.sh && forge_api_init && forge whoami' _ "$GITLAB" ) > "$TMP/out" 2> "$TMP/err"; echo $? > "$TMP/rc"
[ "$(rc)" = 0 ] && [ "$(val LOGIN)" = svc-bot ] && ok "N.3 GIT_HOST/GIT_REPO/FORGE_KIND posés sans export ⇒ whoami répond (forge() les passe explicitement)" || ko "N.3 rc $(rc) : $(cause)"
# Un verbe à DEUX appels (comment_upsert : relecture du fil puis POST) avec le secret
# SEULEMENT sur le descripteur 3 (variable de shell non exportée, rien dans l'env) :
# le fd 3 doit être lu une fois et gardé — fermé, son numéro serait repris par le
# corps de note ou la socket (mesuré sur GitLab réel : TypeError dans le décodeur).
printf 'verdict fd3\n' > "$TMP/note3.txt"
# shellcheck disable=SC2016  # le bash enfant pose FORGE_SECRET lui-même, sans export, à dessein
( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitlab GIT_HOST="$GITLAB" GIT_REPO=ci/stoa-labs bash -c 'FORGE_SECRET=t-svc; . scripts/lib/forge-api.sh && forge_api_init && forge comment_upsert 41 "<!-- fd3:appa-rec -->" "$1"' _ "$TMP/note3.txt" ) > "$TMP/out" 2> "$TMP/err"; echo $? > "$TMP/rc"
[ "$(rc)" = 0 ] && [ "$(val ACTION)" = created ] && [ -n "$(val ID)" ] && ! grep -q Traceback "$TMP/err" \
  && ok "N.5 comment_upsert (deux appels) avec le secret SEULEMENT sur le fd 3 ⇒ created, aucune trace (fd 3 lu une fois, jamais fermé)" || ko "N.5 rc $(rc) ACTION=$(val ACTION) : $(cause)"
# La 41e page : une liste qui ne se termine jamais est REFUSÉE, pas tronquée en silence.
# Mutant du python : PAGES_MAX=2 et un mock qui rend une page pleine à chaque appel.
sed 's/^PAGES_MAX = 40$/PAGES_MAX = 2/' "$TMP/lib/forge-api.py" > "$TMP/lib/forge-api.py.mut" && mv "$TMP/lib/forge-api.py.mut" "$TMP/lib/forge-api.py"
set_ctl '{"body_mode":"endless"}'
# shellcheck disable=SC2016  # le bash enfant reçoit $1, à dessein
( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitlab GIT_HOST="$GITLAB" GIT_REPO=ci/stoa-labs FORGE_SECRET=t-svc bash -c '. "$1" && forge_api_init && forge pr_list_merged provision/appa-dev' _ "$TMP/lib/forge-api.sh" ) > "$TMP/out" 2> "$TMP/err"; echo $? > "$TMP/rc"
[ "$(rc)" = 2 ] && grep -q 'TRONQUÉE' "$TMP/err" && grep -q 'plus de 2 pages' "$TMP/err" && [ ! -s "$TMP/out" ] \
  && ok "N.4 au-delà de PAGES_MAX, pr_list_merged REFUSE (« pagination TRONQUÉE … plus de 2 pages »), rien sur stdout" || ko "N.4 rc $(rc) : $(cause)"
set_ctl "$PRS"

echo "═══ O. GitLab prépare le diff d'une MR en ASYNCHRONE : pr_files attend prepared_at, borné ═══"
prep(){ set_ctl "$(python3 -c 'import json,sys;d=json.loads(sys.argv[1]);d["preparing"]=int(sys.argv[2]);print(json.dumps(d))' "$PRS" "$1")"; }
prep 2; f gitlab "$GITLAB" pr_files 41
[ "$(rc)" = 0 ] && grep -qx 'poc/clients/appa.ansible.yml' "$TMP/out" && [ "$(grep -c 'merge_requests/41 ' "$LOG")" -ge 3 ] \
  && ok "O.1 MR « preparing » aux 2 premières lectures ⇒ pr_files ATTEND (3 lectures de la MR) puis rend les fichiers — jamais [] pris pour vrai" \
  || ko "O.1 rc $(rc) lectures=$(grep -c 'merge_requests/41 ' "$LOG") : $(tr '\n' ' ' < "$TMP/out" | cut -c1-80) $(cause)"
prep 999
# shellcheck disable=SC2016  # le bash enfant reçoit $1, à dessein
( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitlab GIT_HOST="$GITLAB" GIT_REPO=ci/stoa-labs FORGE_SECRET=t-svc FORGE_PREPARE_WAIT=2 bash -c '. scripts/lib/forge-api.sh && forge_api_init && forge pr_files 41' ) > "$TMP/out" 2> "$TMP/err"; echo $? > "$TMP/rc"
[ "$(rc)" = 2 ] && grep -q 'PRÉPARATION' "$TMP/err" && grep -q 'preparing' "$TMP/err" && [ ! -s "$TMP/out" ] \
  && ok "O.2 MR jamais prête, FORGE_PREPARE_WAIT=2 ⇒ rc 2 « encore en PRÉPARATION après 2 s », rien sur stdout" || ko "O.2 rc $(rc) : $(cause)"
# Mutant : l'attente retirée ⇒ la liste vide passe pour vraie (O.1 rougirait).
mkdir -p "$TMP/lib3"; cp "$LIB" "$TMP/lib3/forge-api.sh"; sed 's/^        _gitlab_wait_prepared(n)$/        pass  # mutant : sans attente/' "$PY" > "$TMP/lib3/forge-api.py"
grep -q 'mutant : sans attente' "$TMP/lib3/forge-api.py" || ko "O.3 mutant non appliqué (ancre absente)"
prep 2
# shellcheck disable=SC2016  # le bash enfant reçoit $1, à dessein
( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitlab GIT_HOST="$GITLAB" GIT_REPO=ci/stoa-labs FORGE_SECRET=t-svc bash -c '. "$1" && forge_api_init && forge pr_files 41' _ "$TMP/lib3/forge-api.sh" ) > "$TMP/out" 2> "$TMP/err"; echo $? > "$TMP/rc"
[ "$(rc)" = 0 ] && [ ! -s "$TMP/out" ] && ok "O.3 mutant sans attente ⇒ rc 0 et AUCUN fichier (la panne que O.1 attrape : « aucun fichier » à tort)" || ko "O.3 le mutant passe : rc $(rc) $(tr '\n' ' ' < "$TMP/out" | cut -c1-80)"
set_ctl "$PRS"

echo "═══ P. STOA_DEBUG=1 : chaque appel se dit, stdout inchangé, jamais le secret ═══"
# fd <STOA_DEBUG> <kind> <host> <verbe…> — f() sous STOA_DEBUG=<valeur> ; « - » =
# variable ABSENTE (pas vide : c'est l'état d'un job dont le pont DEBUG⇒STOA_DEBUG
# n'a rien exporté, DEBUG étant faux). Le bash enfant pose la variable LUI-MÊME :
# sous `env -i`, un mot vide passerait pour le nom de la commande.
# shellcheck disable=SC2016  # le bash enfant reçoit $1 (la valeur) puis le verbe, à dessein
fd(){
  local d="$1" k="$2" h="$3"; shift 3
  ( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" FORGE_KIND="$k" GIT_HOST="$h" GIT_REPO=ci/stoa-labs FORGE_SECRET=t-svc \
      bash -c 'case "$1" in -) ;; *) export STOA_DEBUG="$1";; esac; shift; . scripts/lib/forge-api.sh && forge_api_init && forge "$@"' _ "$d" "$@" ) > "$TMP/out" 2> "$TMP/err"
  echo $? > "$TMP/rc"
}
# taille <chemin> — les octets de la DERNIÈRE réponse du mock sur ce chemin : c'est
# le mock qui dit N (il connaît son corps), jamais un « [0-9]+ » vacant.
taille(){ awk -v p="$1" '$2==p{n=$3} END{print n+0}' "$SIZES"; }
DBGPY='^\[dbg forge-api\.py\] '
# P.1/P.2 : la ligne EXACTE, stdout identique octet à octet, zéro secret.
for K in gitea gitlab; do
  case "$K" in gitea) H="$GITEA"; NP=P.1;; *) H="$GITLAB"; NP=P.2;; esac
  set_ctl "$PRS"
  f "$K" "$H" whoami; cp "$TMP/out" "$TMP/out.sans"
  : > "$SIZES"; fd 1 "$K" "$H" whoami
  n="$(taille "/api/$(nom v4 v1)/user")"
  attendu="[dbg forge-api.py] GET $H/api/$(nom v4 v1)/user -> HTTP 200 ($n octets)"
  [ "$(rc)" = 0 ] && [ "$n" -gt 0 ] && grep -qxF -- "$attendu" "$TMP/err" && cmp -s "$TMP/out" "$TMP/out.sans" && [ -s "$TMP/out.sans" ] && [ "$(grep -c 't-svc' "$TMP/err")" = 0 ] \
    && ok "$NP ($K) whoami sous STOA_DEBUG=1 ⇒ stderr porte EXACTEMENT « $attendu » (N mesuré par le mock), stdout identique au même appel sans debug, zéro t-svc" \
    || ko "$NP ($K) rc $(rc) N=$n attendu « $attendu » — stderr : $(cause)"
done
# P.3 : l'init seul dit ce qu'il a décidé — et FORGE_API_BASE vide se lit « <vide> ».
( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" STOA_DEBUG=1 FORGE_KIND=gitlab GIT_HOST="$GITLAB" GIT_REPO=ci/stoa-labs FORGE_SECRET=t-svc bash -c '. scripts/lib/forge-api.sh && forge_api_init' ) > "$TMP/out" 2> "$TMP/err"; echo $? > "$TMP/rc"
[ "$(rc)" = 0 ] && grep -q '\] FORGE_KIND=gitlab$' "$TMP/err" && grep -q '\] FORGE_API_AUTH=private-token$' "$TMP/err" && grep -q '\] FORGE_API_BASE=<vide>$' "$TMP/err" \
  && grep -q "\] GIT_HOST=$GITLAB\$" "$TMP/err" && grep -q '\] GIT_REPO=ci/stoa-labs$' "$TMP/err" && [ ! -s "$TMP/out" ] \
  && ok "P.3 forge_api_init seul sous STOA_DEBUG=1 (gitlab) ⇒ « ] FORGE_KIND=gitlab », « ] FORGE_API_AUTH=private-token », « ] FORGE_API_BASE=<vide> » (+ GIT_HOST, GIT_REPO) sur stderr ; stdout vide ; rc 0" \
  || ko "P.3 rc $(rc) stdout=$(wc -c < "$TMP/out" | tr -d ' ') : $(cause)"
# P.4 : le refus — la ligne HTTP PRÉCÈDE la cause (c'est ce qu'un log se lit de haut en bas).
( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" STOA_DEBUG=1 FORGE_KIND=gitlab GIT_HOST="$GITLAB" GIT_REPO=ci/stoa-labs FORGE_SECRET=mauvais bash -c '. scripts/lib/forge-api.sh && forge_api_init && forge whoami' ) > "$TMP/out" 2> "$TMP/err"; echo $? > "$TMP/rc"
l_http="$(awk '/-> HTTP 401/{print NR; exit}' "$TMP/err")"; l_cause="$(awk '/REFUSE le secret/{print NR; exit}' "$TMP/err")"
[ "$(rc)" = 2 ] && [ -n "$l_http" ] && [ -n "$l_cause" ] && [ "$l_http" -lt "$l_cause" ] && [ ! -s "$TMP/out" ] \
  && ok "P.4 token inconnu ⇒ « -> HTTP 401 » (ligne $l_http) PRÉCÈDE la cause « la forge REFUSE » (ligne $l_cause) ; rc 2 ; stdout vide" \
  || ko "P.4 rc $(rc) ligne HTTP=${l_http:-absente} ligne cause=${l_cause:-absente} : $(cause)"
# P.5 : le discriminant de J sous debug — le 302 se dit ET la cause reste.
fd 1 gitea "$GITLAB" pr_find_open provision/appa-rec
[ "$(rc)" = 2 ] && grep -q -- '-> HTTP 302' "$TMP/err" && grep -q '/users/sign_in' "$TMP/err" && grep -qi 'redirige' "$TMP/err" \
  && ok "P.5 FORGE_KIND=gitea contre le mock gitlab sous STOA_DEBUG=1 ⇒ « -> HTTP 302 » présent ET la cause qui nomme /users/sign_in toujours là" \
  || ko "P.5 rc $(rc) : $(cause)"
# P.6 : l'accord avec dbg_on de dbg.sh, valeur par valeur — les DEUX autorités se
# taisent ensemble (0 ligne « [dbg ») ou parlent ensemble (python ET shell).
for v in - 0 false FALSE off no; do
  case "$v" in -) etiq='STOA_DEBUG absent';; *) etiq="STOA_DEBUG=$v";; esac
  fd "$v" gitlab "$GITLAB" whoami
  [ "$(rc)" = 0 ] && [ "$(val LOGIN)" = svc-bot ] && [ "$(grep -c '\[dbg' "$TMP/err")" = 0 ] \
    && ok "P.6 $etiq ⇒ ZÉRO ligne « [dbg » (python et shell muets), whoami répond quand même" \
    || ko "P.6 $etiq : rc $(rc) lignes=$(grep -c '\[dbg' "$TMP/err") : $(cause)"
done
for v in 1 true yes on; do
  fd "$v" gitlab "$GITLAB" whoami
  [ "$(rc)" = 0 ] && grep -qE "${DBGPY}GET .* -> HTTP 200 \([0-9]+ octets\)$" "$TMP/err" && grep -q '\] FORGE_KIND=gitlab$' "$TMP/err" \
    && ok "P.6 STOA_DEBUG=$v ⇒ la ligne « [dbg forge-api.py] GET … -> HTTP 200 » est là, et « ] FORGE_KIND= » aussi (accord avec dbg_on de dbg.sh)" \
    || ko "P.6 STOA_DEBUG=$v : rc $(rc) : $(cause)"
done
# … et la variable posée SANS export (ni dbg_init) : le shell la voit, python
# doit la voir aussi — forge() la passe explicitement, comme GIT_HOST en N.3.
# shellcheck disable=SC2016  # le bash enfant pose STOA_DEBUG lui-même, sans export, à dessein
( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitlab GIT_HOST="$GITLAB" GIT_REPO=ci/stoa-labs FORGE_SECRET=t-svc bash -c 'STOA_DEBUG=1; . scripts/lib/forge-api.sh && forge_api_init && forge whoami' ) > "$TMP/out" 2> "$TMP/err"; echo $? > "$TMP/rc"
[ "$(rc)" = 0 ] && grep -qE "${DBGPY}GET .* -> HTTP 200 " "$TMP/err" && grep -q '\] FORGE_KIND=gitlab$' "$TMP/err" \
  && ok "P.6 STOA_DEBUG=1 posé SANS export ⇒ python parle comme le shell (forge() le passe explicitement, jamais un shell bavard devant un python muet)" \
  || ko "P.6 sans export : rc $(rc) dbg-python=$(grep -c '\[dbg forge-api.py\]' "$TMP/err") : $(cause)"
# P.7 : le secret DANS l'URL — un chemin demandé est un argument de l'appelant, il
# entre dans l'URL ; la ligne de debug le masque par LITTÉRAL. Le mock sert le
# fichier : la ligne est celle d'un succès (200, N octets), pas d'un refus.
set_ctl "$(python3 -c 'import json,sys;d=json.loads(sys.argv[1]);d["raw"]["t-svc.txt"]="contenu servi\n";print(json.dumps(d))' "$PRS")"
for K in gitea gitlab; do
  case "$K" in gitea) H="$GITEA";; *) H="$GITLAB";; esac
  fd 1 "$K" "$H" raw t-svc.txt master
  [ "$(rc)" = 0 ] && grep -qE "${DBGPY}GET .*<secret masqué>.* -> HTTP 200 \([0-9]+ octets\)$" "$TMP/err" && [ "$(grep -c 't-svc' "$TMP/err")" = 0 ] && grep -q 'contenu servi' "$TMP/out" \
    && ok "P.7 ($K) forge raw t-svc.txt sous STOA_DEBUG=1 ⇒ la ligne de debug montre « <secret masqué> » et jamais t-svc ; « -> HTTP 200 » présent (contrôle positif), le contenu sur stdout" \
    || ko "P.7 ($K) rc $(rc) fuite=$(grep -c 't-svc' "$TMP/err") : $(cause)"
done
# fds <secret> <kind> <host> <verbe…> — fd 1 sous un AUTRE secret que t-svc
# (P.7c-P.7f : un secret qui n'est pas URL-safe, ou deux secrets dans l'env).
# shellcheck disable=SC2016  # le bash enfant reçoit le verbe et ses arguments, à dessein
fds(){
  local s="$1" k="$2" h="$3"; shift 3
  ( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" STOA_DEBUG=1 FORGE_KIND="$k" GIT_HOST="$h" GIT_REPO=ci/stoa-labs FORGE_SECRET="$s" \
      bash -c '. scripts/lib/forge-api.sh && forge_api_init && forge "$@"' _ "$@" ) > "$TMP/out" 2> "$TMP/err"
  echo $? > "$TMP/rc"
}
# P.7c : le secret sous sa FORME D'URL. Un secret qui porte « + » entre dans le
# chemin GitLab par quote (t-s%2Bvc) et dans la query des deux visages par
# urlencode (?ref=t-s%2Bvc) : le littéral brut n'y est plus, seule sa forme
# encodée y est — dbg.sh masque quote(x) et quote_plus(x) de chaque littéral,
# _mask doit faire de même (mesuré L2-A1 tour 1 : « /files/t-s%2Bvc/raw?ref=
# t-s%2Bvc -> HTTP 200 » en clair, sur CHAQUE requête). Chemin ET ref dans le
# même appel : la ligne doit finir par « ref=<secret masqué> -> HTTP 200 ».
# (t-svc.txt reste servi : P.8 le redemande sur la copie mutée et attend un 200.)
set_ctl "$(python3 -c 'import json,sys;d=json.loads(sys.argv[1]);d["raw"]["t-svc.txt"]="contenu servi\n";d["raw"]["t-s+vc"]="contenu plus\n";d["raw"]["t-sp vc"]="contenu espace\n";d["raw"]["t-svc-long"]="contenu long\n";print(json.dumps(d))' "$PRS")"
for K in gitea gitlab; do
  case "$K" in gitea) H="$GITEA";; *) H="$GITLAB";; esac
  fds 't-s+vc' "$K" "$H" raw 't-s+vc' 't-s+vc'
  [ "$(rc)" = 0 ] && grep -qE "${DBGPY}GET .*<secret masqué>.*ref=<secret masqué> -> HTTP 200 \([0-9]+ octets\)$" "$TMP/err" \
    && [ "$(grep -cF -- 't-s+vc' "$TMP/err")" = 0 ] && [ "$(grep -c 't-s%2Bvc' "$TMP/err")" = 0 ] && grep -q 'contenu plus' "$TMP/out" \
    && ok "P.7c ($K) secret « t-s+vc » en chemin ET en ref ⇒ la ligne de debug finit par « ref=<secret masqué> -> HTTP 200 (N octets) », jamais t-s+vc ni t-s%2Bvc ; le contenu sur stdout" \
    || ko "P.7c ($K) rc $(rc) brut=$(grep -cF -- 't-s+vc' "$TMP/err") encodé=$(grep -c 't-s%2Bvc' "$TMP/err") : $(grep '\[dbg forge-api.py\]' "$TMP/err" | head -1 | cut -c1-160)"
done
# P.7d : l'espace, le seul caractère qui SÉPARE les deux formes — %20 par quote
# (le chemin GitLab), « + » par urlencode (la query, les deux visages). Pour
# « + » (P.7c) les deux formes coïncident : sans l'espace, retirer l'une des
# deux serait invisible. GitLab reçoit le secret en chemin ET en ref ; Gitea en
# ref seulement (son chemin n'est pas encodé : un espace y est une InvalidURL).
for K in gitea gitlab; do
  case "$K" in gitea) H="$GITEA"; chemin=poc/ansible/providers.dev.yml; motif='ref=<secret masqué>'; attendu='team: fbi';;
                 *) H="$GITLAB"; chemin='t-sp vc'; motif='/files/<secret masqué>/raw\?ref=<secret masqué>'; attendu='contenu espace';; esac
  fds 't-sp vc' "$K" "$H" raw "$chemin" 't-sp vc'
  [ "$(rc)" = 0 ] && grep -qE "${DBGPY}GET .*${motif} -> HTTP 200 \([0-9]+ octets\)$" "$TMP/err" \
    && [ "$(grep -c 't-sp' "$TMP/err")" = 0 ] && grep -q "$attendu" "$TMP/out" \
    && ok "P.7d ($K) secret « t-sp vc » $(nom 'en chemin (%20) ET en ref (+)' 'en ref (+)') ⇒ « $(nom '/files/<secret masqué>/raw?ref=<secret masqué>' 'ref=<secret masqué>') -> HTTP 200 » ; ni t-sp vc, ni t-sp+vc, ni t-sp%20vc sur stderr" \
    || ko "P.7d ($K) rc $(rc) occurrences=$(grep -c 't-sp' "$TMP/err") : $(grep '\[dbg forge-api.py\]' "$TMP/err" | head -1 | cut -c1-160)"
done
# P.7e : la CAUSE porte la même URL (u = _mask(url)) : port fermé ⇒ « forge
# injoignable : GET url » (K.5) — la forme encodée ne doit pas y être non plus,
# ni dans la ligne « -> ERREUR » qui la précède.
fds 't-s+vc' gitlab "http://127.0.0.1:1" raw 't-s+vc' 't-s+vc'
[ "$(rc)" = 2 ] && grep -qE "${DBGPY}GET .*ref=<secret masqué> -> ERREUR [A-Za-z]+$" "$TMP/err" && grep -q 'injoignable' "$TMP/err" \
  && [ "$(grep -cF -- 't-s+vc' "$TMP/err")" = 0 ] && [ "$(grep -c 't-s%2Bvc' "$TMP/err")" = 0 ] \
  && ok "P.7e port fermé, secret « t-s+vc » en chemin et ref ⇒ « -> ERREUR » ET la cause « injoignable » sont là, ni t-s+vc ni t-s%2Bvc dans tout stderr" \
  || ko "P.7e rc $(rc) brut=$(grep -cF -- 't-s+vc' "$TMP/err") encodé=$(grep -c 't-s%2Bvc' "$TMP/err") : $(cause)"
# P.7f : le plus long d'abord. Deux secrets dans l'env dont l'un est un préfixe
# de l'autre (FORGE_SECRET=t-svc en usage, GITEA_TOKEN=t-svc-long encore porté) :
# masquer le court en premier trouerait le long (« <secret masqué>-long ») —
# dbg.sh trie ses littéraux du plus long au plus court pour cette raison.
# shellcheck disable=SC2016  # le bash enfant reçoit $1, à dessein
( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" STOA_DEBUG=1 FORGE_KIND=gitea GIT_HOST="$GITEA" GIT_REPO=ci/stoa-labs FORGE_SECRET=t-svc GITEA_TOKEN=t-svc-long \
    bash -c '. scripts/lib/forge-api.sh && forge_api_init && forge raw t-svc-long master' ) > "$TMP/out" 2> "$TMP/err"; echo $? > "$TMP/rc"
[ "$(rc)" = 0 ] && grep -qE "${DBGPY}GET .*/raw/<secret masqué>\?ref=master -> HTTP 200 \([0-9]+ octets\)$" "$TMP/err" \
  && [ "$(grep -c 'long' "$TMP/err")" = 0 ] && [ "$(grep -c 't-svc' "$TMP/err")" = 0 ] && grep -q 'contenu long' "$TMP/out" \
  && ok "P.7f FORGE_SECRET=t-svc et GITEA_TOKEN=t-svc-long ⇒ « /raw/<secret masqué>?ref=master -> HTTP 200 » : le long est masqué EN ENTIER, jamais « <secret masqué>-long »" \
  || ko "P.7f rc $(rc) fragment=$(grep -c 'long' "$TMP/err") : $(grep '\[dbg forge-api.py\]' "$TMP/err" | head -1 | cut -c1-160)"
# P.8 : mutant sur COPIE (lib + py ensemble, comme en N) : _dbg écrit `texte` sans _mask ⇒ P.7 rougit.
mkdir -p "$TMP/libP"; cp "$LIB" "$TMP/libP/forge-api.sh"
sed 's/"\[dbg forge-api.py\] " + _mask(texte)/"[dbg forge-api.py] " + texte/' "$PY" > "$TMP/libP/forge-api.py"
grep -q '"\[dbg forge-api.py\] " + texte + ' "$TMP/libP/forge-api.py" || ko "P.8 mutant non appliqué (ancre absente)"
# shellcheck disable=SC2016  # le bash enfant reçoit $1, à dessein
( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" STOA_DEBUG=1 FORGE_KIND=gitea GIT_HOST="$GITEA" GIT_REPO=ci/stoa-labs FORGE_SECRET=t-svc bash -c '. "$1" && forge_api_init && forge raw t-svc.txt master' _ "$TMP/libP/forge-api.sh" ) > "$TMP/out" 2> "$TMP/err"; echo $? > "$TMP/rc"
grep -qE "${DBGPY}GET .*t-svc.* -> HTTP 200 " "$TMP/err" \
  && ok "P.8 mutant (_dbg sans _mask, sur copie) ⇒ t-svc apparaît dans la ligne de debug : P.7 discrimine" \
  || ko "P.8 le mutant passe : fuite=$(grep -c 't-svc' "$TMP/err") : $(cause)"
# P.8b : mutant sur COPIE : le registre des secrets sans leurs formes d'URL
# (« formes = (t,) ») ⇒ P.7c rougit : t-s%2Bvc apparaît dans la ligne de debug.
sed 's/^        formes = (t, urllib\.parse\.quote(t, safe=""), urllib\.parse\.quote_plus(t, safe=""))$/        formes = (t,)/' "$PY" > "$TMP/libP/forge-api.py"
grep -q '^        formes = (t,)$' "$TMP/libP/forge-api.py" || ko "P.8b mutant non appliqué (ancre absente)"
# shellcheck disable=SC2016  # le bash enfant reçoit $1, à dessein
( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" STOA_DEBUG=1 FORGE_KIND=gitlab GIT_HOST="$GITLAB" GIT_REPO=ci/stoa-labs FORGE_SECRET='t-s+vc' bash -c '. "$1" && forge_api_init && forge raw t-s+vc t-s+vc' _ "$TMP/libP/forge-api.sh" ) > "$TMP/out" 2> "$TMP/err"; echo $? > "$TMP/rc"
grep -qE "${DBGPY}GET .*t-s%2Bvc.* -> HTTP 200 " "$TMP/err" \
  && ok "P.8b mutant (registre sans les formes d'URL, sur copie) ⇒ t-s%2Bvc apparaît dans la ligne de debug : P.7c discrimine" \
  || ko "P.8b le mutant passe : encodé=$(grep -c 't-s%2Bvc' "$TMP/err") : $(cause)"
set_ctl "$PRS"
# P.9 : sous `bash -x` ET STOA_DEBUG=1 — le -x du `sh -xe` de Jenkins — rien ne fuit, et le debug parle.
trace "$LIB" 1
[ "$(rc)" = 0 ] && [ "$(val LOGIN)" = svc-bot ] && [ "$(grep -c 't-svc' "$TMP/trace")" = 0 ] && grep -qE "${DBGPY}GET .* -> HTTP 200 " "$TMP/trace" && grep -q '\] FORGE_KIND=gitlab$' "$TMP/trace" \
  && ok "P.9 sous \`bash -x\` avec STOA_DEBUG=1 : 0 occurrence de t-svc dans la trace, ET la trace porte « [dbg forge-api.py] GET … -> HTTP 200 » et « ] FORGE_KIND=gitlab »" \
  || ko "P.9 rc $(rc) occurrences=$(grep -c 't-svc' "$TMP/trace") dbg=$(grep -c '\[dbg forge-api.py\]' "$TMP/trace") : $(grep 't-svc' "$TMP/trace" | head -1 | cut -c1-120)"
# P.10 : un GIT_HOST qui porte user:mdp — le secret n'est connu d'AUCUN littéral,
# seule la FORME « ://…@ » le rattrape (urllib prend « svc:t-secret-url@127.0.0.1 »
# pour un nom d'hôte, mesuré 3.11 : la ligne est « -> ERREUR URLError » — c'est
# elle, et la cause « injoignable », qui doivent être masquées).
fd 1 gitlab "http://svc:t-secret-url@${GITLAB#http://}" whoami
[ "$(grep -c 't-secret-url' "$TMP/err")" = 0 ] && [ "$(grep -c 't-secret-url' "$TMP/out")" = 0 ] \
  && grep -qE "${DBGPY}GET http://<secret masqué>@127\.0\.0\.1:[0-9]+/api/v4/user -> (HTTP [0-9]+ \([0-9]+ octets\)|ERREUR [A-Za-z]+)$" "$TMP/err" && grep -q '\] GIT_HOST=http://<secret masqué>@' "$TMP/err" \
  && ok "P.10 GIT_HOST portant un userinfo ⇒ ni stderr ni stdout ne portent t-secret-url ; « $(grep -oE -- '-> (HTTP|ERREUR) [A-Za-z0-9]+' "$TMP/err" | head -1) » présent (contrôle positif), l'hôte reste lisible ; l'init le dit masqué aussi" \
  || ko "P.10 rc $(rc) fuite=$(grep -c 't-secret-url' "$TMP/err") : $(cause)"
# P.10b : le mot de passe de l'userinfo EST le secret connu (t-svc) : le littéral
# passe d'abord et laisse « svc:<secret masqué>@ » ; la forme doit reprendre
# l'userinfo EN ENTIER (le masque est un atome, même arbitrage que dbg.sh F.1-F.4)
# — sinon le login d'un couple user:mdp finit dans un log archivé. Discriminant :
# une forme « ://[^/@\s]+@ » qui s'arrête au blanc du masque laisse « svc: ».
fd 1 gitlab "http://svc:t-svc@${GITLAB#http://}" whoami
[ "$(grep -c 't-svc' "$TMP/err")" = 0 ] && ! grep -q 'svc:<secret' "$TMP/err" \
  && grep -qE "${DBGPY}GET http://<secret masqué>@127\.0\.0\.1:[0-9]+/api/v4/user -> (HTTP|ERREUR) " "$TMP/err" && grep -q '\] GIT_HOST=http://<secret masqué>@' "$TMP/err" \
  && ok "P.10b userinfo dont le mot de passe est le secret connu ⇒ « ://<secret masqué>@ » en entier (jamais « svc:<secret masqué>@ ») — python et shell rendent la MÊME ligne" \
  || ko "P.10b fuite=$(grep -c 't-svc' "$TMP/err") login=$(grep -c 'svc:<secret' "$TMP/err") : $(cause)"
set_ctl "$PRS"

echo
echo "═══════════════════════════════════════════════════"
printf 'RÉSULTAT : %d/%d\n' "$PASS" $((PASS + FAIL))
[ "$FAIL" -eq 0 ] || exit 1
