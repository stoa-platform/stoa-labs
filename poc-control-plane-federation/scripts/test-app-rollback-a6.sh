#!/usr/bin/env bash
# test-app-rollback-a6.sh — LA PORTE HORS LIGNE d'A6 (le repli d'une application est une PR).
# Fixture : un dépôt nu servi en file:// (GIT_BASE=master) construit par de vrais
# `git merge --no-ff` dans l'ordre rec#a, rec#b, dev#c, rec#d, dev#e (le dev#e APRÈS
# le dernier rec fait mordre M1) ; un stub Gitea à JOURNAL (pulls paginées, POST /pulls
# ⇒ 201) ; un shim `git` qui journalise chaque verbe et peut déplacer la branche
# distante entre le bail et le push. Toute sortie va dans un fichier avant grep.
# `A && ok || ko` (SC2015) est l'idiome des scripts de preuve du repo.
# shellcheck disable=SC2015,SC2034,SC2016
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; umask 077
PIDS=""
cleanup(){ for p in $PIDS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -rf "$TMP" "$REPO"/scripts/.a6-mut-*.sh; }
trap cleanup EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
command -v python3 >/dev/null || { echo "python3 absent"; exit 2; }
SCRIPT="$REPO/scripts/app-rollback-request.sh"
# shellcheck source=scripts/lib/app-manifest.sh
. "$REPO/scripts/lib/app-manifest.sh" || { echo "lib app-manifest absente"; exit 2; }

# ── la chaîne de test : rec sans porte, int avec requireChangeRef, prod terminus ─
CHAIN="$TMP/chain.yaml"
cat > "$CHAIN" <<'YAML'
environments: [dev, rec, int, prod]
gates:
  - { to: rec, selfApproval: true }
  - { to: int, fourEyes: true, requireChangeRef: true }
  - { to: prod, fourEyes: true, requireChangeRef: true, itsmCheck: true }
YAML
CHAIN_REC_GATED="$TMP/chain-gated.yaml"
sed 's/{ to: rec, selfApproval: true }/{ to: rec, requireChangeRef: true }/' "$CHAIN" > "$CHAIN_REC_GATED"

# ── le stub Gitea : /pulls paginées (closed|open) depuis ctl.json, /pulls/<n>, POST /pulls ⇒ 201, journal ──
STUB_CTL="$TMP/ctl.json"; STUB_LOG="$TMP/http.log"; : > "$STUB_LOG"; STUB_TOKEN="t0k3n-a6"
cat > "$TMP/stub.py" <<'PY'
import json, os, re, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
CTL, LOG, TOKEN = os.environ["STUB_CTL"], os.environ["STUB_LOG"], os.environ["STUB_TOKEN"]
TOKENS = {TOKEN: "ci", "t-alice": "alice", "t-noscope": None}   # A7 : GET /user décidé par le token
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
        with open(LOG, "a") as f: f.write("%s %s%s %s\n" % (method, path, ("?" + u.query) if u.query else "", TOKENS.get(tok, "?") or "noscope"))
        if tok not in TOKENS: return self._send(401, {"message": "unauthorized"})
        c = ctl()
        if c.get("down"): return self._send(500, {"message": "boom"})
        if path == "/api/v1/user":
            if TOKENS[tok] is None: return self._send(403, {"message": "token does not have at least one of required scope(s): [read:user]"})
            return self._send(200, {"login": TOKENS[tok], "id": 7})
        m = re.match(r"^/api/v1/repos/[^/]+/[^/]+/pulls$", path)
        if m and method == "GET":
            state = (q.get("state") or ["open"])[0]; page = int((q.get("page") or ["1"])[0]); limit = int((q.get("limit") or ["50"])[0])
            if c.get("raw_list") is not None: return self._send(200, c["raw_list"])
            items = c.get(state, [])
            return self._send(200, items[(page-1)*limit: page*limit])
        mf = re.match(r"^/api/v1/repos/[^/]+/[^/]+/pulls/([0-9]+)/files$", path)
        if mf and method == "GET":
            return self._send(200, [{"filename": f} for f in c.get("files", ["poc-control-plane-federation/clients/provisioned/applications/appa.ansible.yml", "poc-control-plane-federation/clients/provisioned/certs/appa-rec.crt"])])
        m = re.match(r"^/api/v1/repos/[^/]+/[^/]+/pulls/([0-9]+)$", path)
        if m and method == "GET":
            for pr in c.get("closed", []) + c.get("open", []):
                if str(pr.get("number")) == m.group(1): return self._send(200, pr)
            return self._send(404, {"message": "no pr"})
        if m is None and re.match(r"^/api/v1/repos/[^/]+/[^/]+/pulls$", path) and method == "POST":
            n = int(self.headers.get("Content-Length") or 0); body = self.rfile.read(n) if n else b""
            with open(os.environ["STUB_POSTED"], "ab") as f: f.write(body + b"\n")
            with open(os.environ["STUB_POSTED"] + ".auth", "w") as f: f.write(auth)
            return self._send(201, {"number": 900, "html_url": "http://stub/pulls/900"})
        return self._send(404, {"message": "stub: route inconnue " + path})
    def do_GET(self): self._route("GET")
    def do_POST(self): self._route("POST")
    def do_PATCH(self): self._route("PATCH")
srv = ThreadingHTTPServer(("127.0.0.1", 0), H); print(srv.server_address[1], flush=True); srv.serve_forever()
PY
STUB_POSTED="$TMP/posted.jsonl"; : > "$STUB_POSTED"
STUB_CTL="$STUB_CTL" STUB_LOG="$STUB_LOG" STUB_TOKEN="$STUB_TOKEN" STUB_POSTED="$STUB_POSTED" python3 "$TMP/stub.py" > "$TMP/stub.port" 2>"$TMP/stub.err" &
PIDS="$PIDS $!"
for _ in $(seq 1 60); do [ -s "$TMP/stub.port" ] && break; sleep 0.1; done
PORT="$(head -n1 "$TMP/stub.port" 2>/dev/null)"; case "$PORT" in ''|*[!0-9]*) echo "!! stub non démarré : $(cat "$TMP/stub.err")"; exit 2;; esac
GH="http://127.0.0.1:$PORT"

# ── le shim git : journalise le verbe, peut déplacer la branche distante avant un push ──
SHIM="$TMP/shim"; mkdir -p "$SHIM"; SHIM_LOG="$TMP/git.log"; : > "$SHIM_LOG"
REAL_GIT="$(command -v git)"
cat > "$SHIM/git" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SHIM_LOG"
if [ -n "\${SHIM_MOVE_BRANCH:-}" ] && [ "\${1:-}" = push ] || { [ "\${1:-}" = -C ] && [ "\${3:-}" = push ] && [ -n "\${SHIM_MOVE_BRANCH:-}" ]; }; then
  "$REAL_GIT" -C "\$SHIM_ORIGIN" update-ref "refs/heads/\$SHIM_MOVE_REF" "\$SHIM_MOVE_BRANCH"
fi
# SHIM_PUSH_FAIL=1 (copié du shim de test-app-request-a7.sh, L2) : le push
# échoue rc 128 et son stderr recopie le SECRET que rend l'askpass — le mode de
# panne réel de git imprime l'URL ; ici on simule pire. Le script pousse par
# « git -C <clone> push … » : le verbe est en 3e position.
# SHIM_CLONE_FAIL=1 (tour de correction 1, relecture I-1) : la MÊME panne sur
# le clone (verbe en 1re position : « git clone -q … ») — jusque-là aucun clone
# raté du harnais ne citait un secret, et le refus CLONE_ECHEC pouvait relayer
# clone.err NU sans qu'une épreuve rougisse (mutant R1 de la relecture, 64/64).
# Un clone peut citer un secret : sous GIT_TRACE=1 git recopie l'URL NUE de
# l'origine, userinfo compris (mesuré en L2). F.6c/d et M12/M14 le gardent.
# SHIM_SECRET_AT=N (ex-SHIM_PUSH_SECRET_AT : il vaut pour le verbe qui échoue,
# push OU clone) : le secret est recopié UNE SECONDE FOIS, en commençant à
# l'OCTET N de la ligne (0-indexé), derrière un rembourrage de « x ». C'est le
# DISCRIMINANT de l'ordre « masque puis coupe » : pour dbg_git_err (coupe à
# 400 : F.3e/f, M9) N dans ]400-len(secret), 400[ ; pour le REFUS (coupe à 200 :
# F.3h, F.6d, M13/M14) N dans ]200-len(secret), 200[ — le secret À CHEVAL sur
# la coupe. Un helper qui coupe AVANT de masquer en laisse un morceau que
# redact ne reconnaît plus. Un rembourrage qui pousserait le secret ENTIÈREMENT
# après la coupe ne discriminerait rien : les deux ordres rendent le même
# rembourrage (c'était le vert vacant du refus, relecture I-2 : à 395 le refus
# coupé à 200 finit dans les « x » dans les DEUX ordres). Octets, pas
# caractères : « é » et « — » du préfixe en font 2 et 3 (wc -c) ; le secret du
# harnais est ASCII (\${#s} suffit).
panne=""
if [ -n "\${SHIM_PUSH_FAIL:-}" ] && { [ "\${1:-}" = push ] || { [ "\${1:-}" = -C ] && [ "\${3:-}" = push ]; }; }; then panne=push; fi
if [ -n "\${SHIM_CLONE_FAIL:-}" ] && [ "\${1:-}" = clone ]; then panne=clone; fi
if [ -n "\$panne" ]; then
  s="\$(sh "\${GIT_ASKPASS:-/bin/false}" Password 2>/dev/null)"
  pre="fatal: unable to access (simulé) — askpass a rendu "; l="\$pre\$s"
  if [ -n "\${SHIM_SECRET_AT:-}" ]; then
    mid=" askpass a rendu "
    n=\$(( \$(printf '%s' "\$pre\$mid" | wc -c) + \${#s} + 1 ))
    l="\$l \$(printf '%*s' "\$((SHIM_SECRET_AT - n))" '' | tr ' ' x)\$mid\$s"
  fi
  echo "\$l" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
SH
chmod 700 "$SHIM/git"

# ── la fixture git : nu + clone de construction ──
ORIGIN="$TMP/origin.git"; W="$TMP/w"
git init -q --bare "$ORIGIN" && git -C "$ORIGIN" symbolic-ref HEAD refs/heads/master && git -C "$ORIGIN" config uploadpack.allowFilter true
git init -q "$W" && git -C "$W" checkout -q -b master
gw(){ git -C "$W" -c user.name=t -c user.email=t@t "$@"; }
MAN="clients/provisioned/applications/appa.ansible.yml"; CERT="clients/provisioned/certs/appa-rec.crt"
mkdir -p "$W/clients/provisioned/applications" "$W/clients/provisioned/certs"
printf 'init\n' > "$W/README"; gw add -A; gw commit -qm c0
write_man(){ # <fichier> <ligne dev ou vide> <ligne rec ou vide> — sans \n final ; racine figée identique partout
  { printf -- '---\napim_ss_app:\n  name: "appa"\n  api: "demo-selfservice"\n  api_version: "1.0.0"\n  description: "fixture A6"\n  contact_emails: []\n  enforce: []\n  auth:\n    mode: "idp"\n    server_alias: "KeycloakStoaLab"\n    audience: "demo-selfservice"\n    claim: { name: "azp" }\n  per_env:\n'
    [ -n "$2" ] && printf '%s\n' "$2"; [ -n "$3" ] && printf '%s\n' "$3"; } > "$1"
}
CLOSED="[]"   # les PR mergées, dans l'ordre de merge, telles que la forge les rend
closed_add(){ printf '%s' "$CLOSED" | python3 -c 'import json,sys; l=json.load(sys.stdin); l.append(json.load(open(sys.argv[1]))); print(json.dumps(l))' "$TMP/last.pr"; }
pr_merge(){ # <n> <env> <ligne per_env complète "    env: {…}\n"> [cert content|"-"|"rm"] → merge sha ; alimente CLOSED
  local n="$1" e="$2" line="$3" cert="${4:--}" br="provision/appa-$2" sha
  gw checkout -q -B "$br" master
  case "$e" in
    rec) mkdir -p "$(dirname "$W/$MAN")" "$(dirname "$W/$CERT")"; gw show "master:$MAN" > "$TMP/cur.yml" 2>/dev/null || write_man "$TMP/cur.yml" '    dev: { auth: { claim: { value: "appa-dev" } } }' ''
         cp "$TMP/cur.yml" "$W/$MAN"; app_manifest_merge_env "$W/$MAN" rec "$(printf '%s' "$line" | sed -E 's/^    rec: //')" || { echo "!! fixture : fusion rec #$n" >&2; exit 2; } ;;
    dev) mkdir -p "$(dirname "$W/$MAN")" "$(dirname "$W/$CERT")"; gw show "master:$MAN" > "$W/$MAN" 2>/dev/null || write_man "$W/$MAN" '' ''
         app_manifest_merge_env "$W/$MAN" dev "$(printf '%s' "$line" | sed -E 's/^    dev: //')" || { echo "!! fixture : fusion dev #$n" >&2; exit 2; } ;;
  esac
  case "$cert" in -) ;; rm) gw rm -q "$CERT" 2>/dev/null || true ;; *) printf '%s\n' "$cert" > "$W/$CERT" ;; esac
  gw add -A; gw commit -qm "provision($e): application appa (demande t)" >/dev/null
  gw checkout -q master; gw merge -q --no-ff -m "Merge pull request 'provision($e): appa' (#$n) from $br into master" "$br"
  sha=$(gw rev-parse HEAD)
  N="$n" BR="$br" SHA="$sha" python3 -c 'import json,os
print(json.dumps({"number":int(os.environ["N"]),"merged":True,"state":"closed","merge_commit_sha":os.environ["SHA"],
 "head":{"ref":os.environ["BR"],"sha":"deadbeef","repo":{"full_name":"ci/stoa-labs"}},"base":{"ref":"master"},"user":{"login":"ci"}}))' > "$TMP/last.pr"
  printf '%s' "$sha"
}
# ordre imposé : rec#a(10), rec#b(11), dev#c(12), rec#d(13), dev#e(14)
SHA_A=$(pr_merge 10 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.1"], change_ref: "CHG-0001", pv_ref: "PV-1" }' "CERT-A") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add)
SHA_B=$(pr_merge 11 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.2"], change_ref: "CHG-0001", pv_ref: "PV-1" }' "CERT-B") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add)
SHA_C=$(pr_merge 12 dev '    dev: { auth: { claim: { value: "appa-dev" } }, ip_allowlist: ["10.0.0.9"] }') || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add)
SHA_D=$(pr_merge 13 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.3"], change_ref: "CHG-0002", pv_ref: "PV-1" }' "CERT-D") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add)
SHA_E=$(pr_merge 14 dev '    dev: { auth: { claim: { value: "appa-dev" } }, ip_allowlist: ["10.0.0.10"] }') || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add)
gw remote add origin "$ORIGIN"; gw push -q origin master
MAIN0=$(gw rev-parse master)
LINE_B=$(gw show "$SHA_B:$MAN" | grep -E '^    rec: '); LINE_D=$(gw show "$SHA_D:$MAN" | grep -E '^    rec: ')
gw show "$SHA_B:$MAN" > "$TMP/b.yml"; D_B=$(app_manifest_digest_env "$TMP/b.yml" rec)
[ -n "$SHA_E" ] && [ "$LINE_B" != "$LINE_D" ] && [ -n "$D_B" ] && ok "0.1 fixture : 5 merges (rec#10 rec#11 dev#12 rec#13 dev#14), N=#13 N-1=#11, lignes distinctes" || ko "0.1 fixture illisible"
set_ctl(){ printf '%s' "$1" > "$STUB_CTL"; : > "$STUB_LOG"; : > "$STUB_POSTED"; : > "$SHIM_LOG"; }
ctl_json(){ # [open json list] → ctl avec CLOSED courant
  printf '{"closed":%s,"open":%s}' "$CLOSED" "${1:-[]}"
}
reset_origin(){ git -C "$W" push -q -f origin "$MAIN0:master"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true; }
# run_rb <sortie> [VAR=val …] : le script sous test, flux FUSIONNÉS ; rc dans $TMP/rb.rc.
# run_rb2 <stdout> <stderr> [VAR=val …] : le même, flux SÉPARÉS (section F : le
# produit se lit sur stdout SEUL, les lignes de debug sur stderr SEUL). Un
# VAR=val passé en argument GAGNE sur ceux du harnais (env -i : la dernière
# affectation l'emporte — mesuré) : c'est ainsi que F.4b pose un mauvais token.
_rb_run(){
  ( cd "$REPO" && env -i PATH="$SHIM:$PATH" HOME="$HOME" SHIM_ORIGIN="$ORIGIN" \
      GITEA_TOKEN="$STUB_TOKEN" GIT_HOST="$GH" GIT_REPO=ci/stoa-labs GIT_SUBDIR="" \
      GIT_CLONE_URL="file://$ORIGIN" STOA_ENV_CHAIN_FILE="$CHAIN" PROVISION_PLAN_INLINE=false \
      REQ_APP=appa REQ_ENV=rec REQ_REASON="incident reseau" REQ_CALLER="jenkins-form:alice" ROLLBACK_OUT="$TMP/rb.env" \
      "$@" bash "$SCRIPT" )
}
run_rb(){
  local out="$1"; shift
  rm -f "$TMP/rb.out"
  _rb_run "$@" > "$out" 2>&1
  echo $? > "$TMP/rb.rc"
}
run_rb2(){
  local out="$1" err="$2"; shift 2
  _rb_run "$@" > "$out" 2>"$err"
  echo $? > "$TMP/rb.rc"
}
rrc(){ cat "$TMP/rb.rc"; }
refus(){ [ "$(rrc)" = 2 ] && grep -qF "REFUS: $1 :" "$2"; }
posts(){ grep -c '^POST ' "$STUB_LOG" || true; }
remote_branch(){ git -C "$ORIGIN" rev-parse -q --verify "refs/heads/provision/appa-rec" 2>/dev/null || printf 'absente'; }
etapes(){ grep -E '^ETAPE ' "$1" | sed 's/^ETAPE //' | tr '\n' ' '; }
echo "══ A. nominal : la PR de repli restaure la ligne rec et le cert de N-1 (#11) à l'octet ══"
set_ctl "$(ctl_json)"; reset_origin
run_rb "$TMP/a.out"
[ "$(rrc)" = 0 ] && ok "A.1 rc 0" || ko "A.1 rc $(rrc) : $(grep -E 'REFUS|ERREUR' "$TMP/a.out" | head -2 | tr '\n' ' ')"
[ "$(etapes "$TMP/a.out")" = "forme chaine porte clone master manifeste lignee coherence candidate identique restauration verification pr-en-cours tete-distante commit push pr " ] \
  && ok "A.2 ordre des étapes = la propriété" || ko "A.2 étapes : $(etapes "$TMP/a.out")"
[ "$(posts)" = 1 ] && grep -q '"head": "provision/appa-rec"' "$STUB_POSTED" && ok "A.3 un seul POST /pulls, head = provision/appa-rec" || ko "A.3 posts=$(posts)"
RB=$(remote_branch); [ "$RB" != absente ] && [ "$(git -C "$ORIGIN" show "$RB:$MAN" | grep -E '^    rec: ')" = "$LINE_B" ] && ok "A.4 ligne rec de la branche == ligne de #11 à l'octet" || ko "A.4 ligne : $(git -C "$ORIGIN" show "$RB:$MAN" 2>/dev/null | grep -E '^    rec: ')"
[ "$(git -C "$ORIGIN" show "$RB:$CERT")" = "CERT-B" ] && ok "A.5 cert == CERT-B (N-1) à l'octet" || ko "A.5 cert : $(git -C "$ORIGIN" show "$RB:$CERT" 2>/dev/null)"
[ "$(git -C "$ORIGIN" diff --name-only "$MAIN0" "$RB" | sort | tr '\n' ' ')" = "$MAN $CERT " ] && ok "A.6 diff == {manifeste, cert} exactement" || ko "A.6 diff : $(git -C "$ORIGIN" diff --name-only "$MAIN0" "$RB" | tr '\n' ' ')"
[ "$(git -C "$ORIGIN" diff -U0 "$MAIN0" "$RB" -- "$MAN" | grep -cE '^[-+][^-+]')" = 2 ] && ok "A.7 le diff du manifeste touche UNE ligne (racine et dev à l'octet)" || ko "A.7 diff manifeste : $(git -C "$ORIGIN" diff -U0 "$MAIN0" "$RB" -- "$MAN" | grep -E '^[-+][^-+]' | tr '\n' ' ')"
git -C "$ORIGIN" show "$RB:$MAN" > "$TMP/rb.yml"; [ "$(app_manifest_digest_env "$TMP/rb.yml" rec)" = "$D_B" ] && ok "A.8 digest(branche, rec) == digest(#11, rec) recalculé par la lib" || ko "A.8 digest divergent"
MSG=$(git -C "$ORIGIN" log -1 --format=%B "$RB")
printf '%s' "$MSG" | grep -q "^Repli-De: $SHA_D (PR #13)" && printf '%s' "$MSG" | grep -q "^Repli-Vers: $SHA_B (PR #11)" && printf '%s' "$MSG" | grep -q "^Repli-Par: jenkins-form:alice" && printf '%s' "$MSG" | grep -q "^Repli-Digest: $D_B" \
  && ok "A.9 trailers Repli-De/Vers/Par/Digest" || ko "A.9 message : $(printf '%s' "$MSG" | tr '\n' '|')"
grep -q "<!-- app-rollback: de $SHA_D vers $SHA_B -->" "$STUB_POSTED" && grep -q '#13' "$STUB_POSTED" && grep -q '#11' "$STUB_POSTED" && grep -q "$D_B" "$STUB_POSTED" \
  && ok "A.10 corps de PR : marqueur, #N, #N-1, digest" || ko "A.10 corps : $(head -c 300 "$STUB_POSTED")"
grep -q "^PR_URL=" "$TMP/a.out" && grep -q "^REPLI_DE=$SHA_D REPLI_VERS=$SHA_B REPLI_DIGEST=$D_B" "$TMP/a.out" && ok "A.11 stdout PR_URL + REPLI_*" || ko "A.11 stdout"
grep -q "^PR_NUMBER=900" "$TMP/rb.env" && grep -q "^REPLI_DU_REPLI=0" "$TMP/rb.env" && ok "A.12 ROLLBACK_OUT écrit" || ko "A.12 ROLLBACK_OUT : $(cat "$TMP/rb.env" 2>/dev/null | tr '\n' ' ')"
! grep -q "$STUB_TOKEN" "$SHIM_LOG" && grep -q -- '--force-with-lease=refs/heads/provision/appa-rec:' "$SHIM_LOG" && ok "A.13 push en bail, jamais le token en argv git" || ko "A.13 journal git : $(grep -E 'push|clone' "$SHIM_LOG" | head -3 | tr '\n' ' ')"

echo "══ A'. change_ref : la porte AVANT tout clone/forge ; remplacé, jamais dupliqué ; pv_ref intact ══"
set_ctl "$(ctl_json)"; reset_origin
run_rb "$TMP/ap.out" STOA_ENV_CHAIN_FILE="$CHAIN_REC_GATED"
refus GATE_REFS_REQUIRED "$TMP/ap.out" && [ ! -s "$STUB_LOG" ] && ! grep -q '^clone' "$SHIM_LOG" && ! grep -q '^ETAPE clone' "$TMP/ap.out" \
  && ok "A'.1 rec gaté sans REQ_CHANGE_REF ⇒ GATE_REFS_REQUIRED, journal forge vide, aucun clone" || ko "A'.1 rc $(rrc) forge=$(wc -l < "$STUB_LOG") git=$(grep -c '^clone' "$SHIM_LOG")"
set_ctl "$(ctl_json)"; reset_origin
run_rb "$TMP/ap2.out" STOA_ENV_CHAIN_FILE="$CHAIN_REC_GATED" REQ_CHANGE_REF=CHG-0009
RB=$(remote_branch); L=$(git -C "$ORIGIN" show "$RB:$MAN" 2>/dev/null | grep -E '^    rec: ')
[ "$(rrc)" = 0 ] && [ "$L" = "$(printf '%s' "$LINE_B" | sed 's/change_ref: "CHG-0001"/change_ref: "CHG-0009"/')" ] \
  && ok "A'.2 change_ref remplacé (CHG-0001 → CHG-0009), le reste de la ligne et pv_ref à l'octet" || ko "A'.2 rc $(rrc) ligne : $L"
[ "$(printf '%s' "$L" | grep -o 'change_ref' | wc -l | tr -d ' ')" = 1 ] && ok "A'.3 une seule occurrence de change_ref" || ko "A'.3 occurrences : $(printf '%s' "$L" | grep -o 'change_ref' | wc -l)"
cp "$TMP/b.yml" "$TMP/b9.yml"; app_manifest_merge_env "$TMP/b9.yml" rec "$(printf '%s' "$L" | sed -E 's/^    rec: //')" >/dev/null 2>&1
grep -q "^REPLI_DIGEST=$(app_manifest_digest_env "$TMP/b9.yml" rec)$" "$TMP/rb.env" && ok "A'.4 digest attendu recalculé avec le nouveau change_ref" || ko "A'.4 digest annoncé : $(grep REPLI_DIGEST "$TMP/rb.env")"
# le cas #442/#443 : N-1 et N ne diffèrent que par change_ref
gw checkout -q master; SAVE_CLOSED="$CLOSED"
SHA_F=$(pr_merge 15 rec "$(printf '%s' "$LINE_D" | sed 's/change_ref: "CHG-0002"/change_ref: "CHG-0003"/')" "CERT-D") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add); gw push -q origin master
set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/ap3.out" STOA_ENV_CHAIN_FILE="$CHAIN_REC_GATED" REQ_CHANGE_REF=CHG-0003
refus ETAT_IDENTIQUE "$TMP/ap3.out" && [ "$(posts)" = 0 ] && ok "A'.5 #15 ne diffère de #13 que par change_ref et le repli fournit celui de #15 ⇒ ETAT_IDENTIQUE (pas de commit vide)" || ko "A'.5 rc $(rrc) : $(grep REFUS "$TMP/ap3.out")"
run_rb "$TMP/ap4.out" STOA_ENV_CHAIN_FILE="$CHAIN_REC_GATED" REQ_CHANGE_REF=CHG-0004
[ "$(rrc)" = 0 ] && [ "$(posts)" = 1 ] && ok "A'.6 avec un autre change_ref ⇒ PR ouverte" || ko "A'.6 rc $(rrc) posts=$(posts)"
# ligne N-1 avec change_ref NU
gw push -q -f origin "$MAIN0:master"; CLOSED="$SAVE_CLOSED"
SHA_G=$(pr_merge 16 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.7"], change_ref: CHG-0005 }' "CERT-G") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add)
SHA_H=$(pr_merge 17 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.8"], change_ref: CHG-0006 }' "CERT-H") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add); gw push -q -f origin master
set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/ap5.out" STOA_ENV_CHAIN_FILE="$CHAIN_REC_GATED" REQ_CHANGE_REF=CHG-0009
RB=$(remote_branch); L=$(git -C "$ORIGIN" show "$RB:$MAN" 2>/dev/null | grep -E '^    rec: ')
[ "$(rrc)" = 0 ] && [ "$L" = '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.7"], change_ref: "CHG-0009" }' ] \
  && ok "A'.7 change_ref NU (non quoté) à N-1 ⇒ remplacé, une seule clé" || ko "A'.7 rc $(rrc) ligne : $L"
gw push -q -f origin "$MAIN0:master"; CLOSED="$SAVE_CLOSED"; gw checkout -q master; gw reset -q --hard "$MAIN0"
echo "══ B. refus nommés — rien poussé, aucun POST ══"
b_refus(){ # <n> <libellé> <TAG> <fichier de sortie>
  refus "$3" "$4" && [ "$(posts)" = 0 ] && [ "$(remote_branch)" = absente ] && ok "$1 $2 ⇒ $3, rien poussé" || ko "$1 $2 : rc $(rrc) posts=$(posts) branche=$(remote_branch) $(grep -E 'REFUS|ERREUR' "$4" | head -1)"
}
# AUCUNE_LIGNEE : une app avec manifeste mais aucune PR -rec (appb, ajoutée par commit direct)
reset_origin; gw checkout -q master; gw reset -q --hard "$MAIN0"; write_man "$W/clients/provisioned/applications/appb.ansible.yml" '' '    rec: { auth: { claim: { value: "appb-rec" } } }'; gw add -A; gw commit -qm "appb direct"; gw push -q origin master
set_ctl "$(ctl_json)"; run_rb "$TMP/b1.out" REQ_APP=appb; b_refus B.1 "manifeste sans PR mergée" AUCUNE_LIGNEE "$TMP/b1.out"
gw reset -q --hard "$MAIN0"; gw push -q -f origin master
# AUCUN_ETAT_PRECEDENT : un seul merge (forge ne connaît que #13)
ONE=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; l=json.load(sys.stdin); print(json.dumps([p for p in l if p["number"]==13]))')
set_ctl "{\"closed\":$ONE,\"open\":[]}"; reset_origin; run_rb "$TMP/b2.out"; b_refus B.2 "un seul état mergé" AUCUN_ETAT_PRECEDENT "$TMP/b2.out"
# BIRTH : le manifeste retiré (commit direct) puis recréé par une PR ⇒ les merges d'avant ne comptent pas
gw rm -q "$MAN"; gw commit -qm "retrait du manifeste jetable"; gw push -q origin master
SHA_R=$(pr_merge 20 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.20"] }' "CERT-R") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add); gw push -q origin master
set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/b3.out"; b_refus B.3 "manifeste recréé : la lignée commence à sa naissance courante (#20 seul)" AUCUN_ETAT_PRECEDENT "$TMP/b3.out"
grep -q "^LIGNEE : #20" "$TMP/b3.out" && ok "B.3b la lignée imprimée ne cite pas #13" || ko "B.3b lignée : $(grep '^LIGNEE' "$TMP/b3.out")"
gw reset -q --hard "$MAIN0"; gw push -q -f origin master; CLOSED="$SAVE_CLOSED"
# FORGE_INCOHERENTE : merge_commit_sha de N-1 hors de la première parenté
BAD=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; l=json.load(sys.stdin)
for p in l:
    if p["number"]==11: p["merge_commit_sha"]="0"*40
print(json.dumps(l))')
set_ctl "{\"closed\":$BAD,\"open\":[]}"; reset_origin; run_rb "$TMP/b4.out"; b_refus B.4 "sha de #11 hors de master" FORGE_INCOHERENTE "$TMP/b4.out"
BADN=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; l=json.load(sys.stdin)
for p in l:
    if p["number"]==13: p["merge_commit_sha"]="1"*40
print(json.dumps(l))')
set_ctl "{\"closed\":$BADN,\"open\":[]}"; reset_origin; run_rb "$TMP/b4b.out"; b_refus B.4b "sha de #13 (N) hors de master" FORGE_INCOHERENTE "$TMP/b4b.out"
# merged:false sur #11 ⇒ pas un état ⇒ N-1 = #10
NM=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; l=json.load(sys.stdin)
for p in l:
    if p["number"]==11: p["merged"]=False
print(json.dumps(l))')
set_ctl "{\"closed\":$NM,\"open\":[]}"; reset_origin; run_rb "$TMP/b5.out"
[ "$(rrc)" = 0 ] && grep -q "REPLI_VERS=$SHA_A " "$TMP/b5.out" && ok "B.5 #11 non mergée n'est pas un état : N-1 = #10" || ko "B.5 rc $(rrc) : $(grep REPLI_VERS "$TMP/b5.out")"
# FORGE_ILLISIBLE
set_ctl '{"down":true}'; reset_origin; run_rb "$TMP/b6.out"; b_refus B.6 "forge 500" FORGE_ILLISIBLE "$TMP/b6.out"
set_ctl '{"raw_list":{"not":"a list"}}'; run_rb "$TMP/b6b.out"; b_refus B.6b "réponse non-liste" FORGE_ILLISIBLE "$TMP/b6b.out"
# REFERENCE_DIVERGENTE : commit direct sur master après N modifiant la ligne rec
gw checkout -q master; app_manifest_merge_env "$W/$MAN" rec '{ auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.99"] }' >/dev/null; gw commit -qam "hors flux"; gw push -q origin master
set_ctl "$(ctl_json)"; run_rb "$TMP/b7.out"; b_refus B.7 "master écrit hors PR" REFERENCE_DIVERGENTE "$TMP/b7.out"
gw reset -q --hard "$MAIN0"; gw push -q -f origin master
# RACINE_DIVERGENTE : racine différente entre #11 et #13 (fixture dédiée : description changée par commit direct entre les deux)
# (construite sur une copie : master → reset à SHA_B, commit direct racine, puis re-merge d'un rec#13' et dev#14')
SAVE_MAIN="$MAIN0"
gw reset -q --hard "$SHA_B"; sed -i.bak 's/fixture A6/fixture A6 bis/' "$W/$MAN" && rm -f "$W/$MAN.bak"; gw commit -qam "racine hors flux"
CL_SAVE="$CLOSED"; CLOSED=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; print(json.dumps([p for p in json.load(sys.stdin) if p["number"]<=11]))')
SHA_D2=$(pr_merge 13 rec "$LINE_D" "CERT-D") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add); gw push -q -f origin master
set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/b8.out"; b_refus B.8 "racine différente entre N-1 et N" RACINE_DIVERGENTE "$TMP/b8.out"
gw reset -q --hard "$SAVE_MAIN"; gw push -q -f origin master; CLOSED="$CL_SAVE"
# ETAT_IDENTIQUE par quoting : #13' porte la même ligne que #11 aux guillemets près (digest égal, octets différents)
CLOSED=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; print(json.dumps([p for p in json.load(sys.stdin) if p["number"]<=11]))')
SHA_Q=$(pr_merge 13 rec "$(printf '%s' "$LINE_B" | sed "s/\"appa-rec\"/'appa-rec'/")" "CERT-B") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add); gw push -q -f origin master
set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/b9.out"; b_refus B.9 "N == N-1 au digest près (quoting)" ETAT_IDENTIQUE "$TMP/b9.out"
gw reset -q --hard "$SAVE_MAIN"; gw push -q -f origin master; CLOSED="$CL_SAVE"
open_pr(){ # <login> <repo> [head sha] → json d'une PR ouverte sur la branche (html_url : Gitea la rend toujours ; le script ne compose plus /pulls/N)
  printf '[{"number":77,"state":"open","merged":false,"html_url":"http://stub/pulls/77","head":{"ref":"provision/appa-rec","sha":"%s","repo":{"full_name":"%s"}},"base":{"ref":"master"},"user":{"login":"%s"},"body":"<!-- app-rollback: de %s vers %s -->"}]' "${3:-deadbeef}" "$2" "$1" "$SHA_D" "$SHA_B"
}
# PR_EN_COURS : PR ouverte par alice (marqueur collé) ; par ci mais contenu différent ; EXIST : ci + contenu identique
set_ctl "$(ctl_json "$(open_pr alice ci/stoa-labs)")"; reset_origin; run_rb "$TMP/b10.out"; b_refus B.10 "PR ouverte par alice, marqueur collé" PR_EN_COURS "$TMP/b10.out"
# une branche distante portant un AUTRE contenu (rec#13 = master) ouverte par ci
git -C "$ORIGIN" update-ref refs/heads/provision/appa-rec "$SHA_D"
set_ctl "$(ctl_json "$(open_pr ci ci/stoa-labs "$SHA_D")")"; run_rb "$TMP/b11.out"
refus PR_EN_COURS "$TMP/b11.out" && [ "$(posts)" = 0 ] && [ "$(remote_branch)" = "$SHA_D" ] && ok "B.11 PR de ci au contenu différent ⇒ PR_EN_COURS, branche intacte" || ko "B.11 rc $(rrc) : $(grep REFUS "$TMP/b11.out")"
# EXIST : on fabrique la branche de repli exacte (un premier passage nominal), puis on relance avec une PR ouverte de ci dessus
set_ctl "$(ctl_json)"; reset_origin; run_rb "$TMP/b12a.out"; RB=$(remote_branch)
set_ctl "$(ctl_json "$(open_pr ci ci/stoa-labs "$RB")")"; run_rb "$TMP/b12.out"
[ "$(rrc)" = 0 ] && [ "$(posts)" = 0 ] && ! grep -q -- ' push ' "$SHIM_LOG" && grep -q "^PR_URL=.*/pulls/77" "$TMP/b12.out" && [ "$(remote_branch)" = "$RB" ] \
  && ok "B.12 EXIST strict : PR ouverte par ci au contenu identique ⇒ rc 0, ni push ni POST, PR_URL=#77" || ko "B.12 rc $(rrc) posts=$(posts) push=$(grep -c '^push' "$SHIM_LOG")"
# PR de FORK avec ce head.ref ⇒ ignorée (la PR est ouverte normalement)
set_ctl "$(ctl_json "$(open_pr mallory mallory/stoa-labs)")"; reset_origin; run_rb "$TMP/b13.out"
[ "$(rrc)" = 0 ] && [ "$(posts)" = 1 ] && ok "B.13 une PR de fork ne bloque pas le repli" || ko "B.13 rc $(rrc) posts=$(posts) : $(grep REFUS "$TMP/b13.out")"
# BRANCHE_NON_MERGEE : tête distante non ancêtre de master, sans PR
gw checkout -q -B provision/appa-rec master; printf 'x\n' > "$W/HAND"; gw add -A; gw commit -qm "poussé à la master"; gw push -q -f origin provision/appa-rec; gw checkout -q master
set_ctl "$(ctl_json)"; run_rb "$TMP/b14.out"; refus BRANCHE_NON_MERGEE "$TMP/b14.out" && [ "$(posts)" = 0 ] && ok "B.14 tête distante non mergée sans PR ⇒ BRANCHE_NON_MERGEE" || ko "B.14 rc $(rrc) : $(grep REFUS "$TMP/b14.out")"
gw branch -q -D provision/appa-rec; reset_origin
# tête distante MERGÉE (ancêtre de master) ⇒ réécrite en bail
git -C "$ORIGIN" update-ref refs/heads/provision/appa-rec "$SHA_C"
set_ctl "$(ctl_json)"; run_rb "$TMP/b15.out"; [ "$(rrc)" = 0 ] && grep -q -- "--force-with-lease=refs/heads/provision/appa-rec:$SHA_C " "$SHIM_LOG" && ok "B.15 tête mergée ⇒ bail sur cette tête, push accepté" || ko "B.15 rc $(rrc) : $(grep push "$SHIM_LOG")"
# bail perdu : la branche bouge entre 12bis et 13 (le shim la déplace au moment du push)
set_ctl "$(ctl_json)"; reset_origin
run_rb "$TMP/b16.out" SHIM_MOVE_BRANCH="$SHA_C" SHIM_MOVE_REF=provision/appa-rec
refus PUSH_ECHEC "$TMP/b16.out" && [ "$(posts)" = 0 ] && ok "B.16 bail perdu (la branche a bougé) ⇒ PUSH_ECHEC, aucune PR" || ko "B.16 rc $(rrc) posts=$(posts) : $(grep -E 'REFUS' "$TMP/b16.out")"
# formes
set_ctl "$(ctl_json)"; reset_origin
run_rb "$TMP/b17.out" REQ_APP="App_A"; b_refus B.17 "REQ_APP hors classe" APP_INVALIDE "$TMP/b17.out"
run_rb "$TMP/b18.out" REQ_REASON="$(printf 'ligne1\nligne2')"; b_refus B.18 "motif avec retour-ligne" MOTIF_INVALIDE "$TMP/b18.out"
run_rb "$TMP/b19.out" REQ_REASON="<!-- app-rollback: x -->"; b_refus B.19 "motif avec marqueur HTML" MOTIF_INVALIDE "$TMP/b19.out"
run_rb "$TMP/b20.out" REQ_CHANGE_REF='CHG"1'; b_refus B.20 "change_ref avec guillemet" REF_INVALIDE "$TMP/b20.out"
run_rb "$TMP/b21.out" REQ_CALLER='alice smith'; b_refus B.21 "caller avec espace" CALLER_INVALIDE "$TMP/b21.out"
run_rb "$TMP/b22.out" REQ_ENV=homol; b_refus B.22 "palier hors chaîne" ENV_INVALIDE "$TMP/b22.out"
[ ! -s "$STUB_LOG" ] && ! grep -q '^clone' "$SHIM_LOG" && ok "B.23 les six refus de forme n'ont touché ni la forge ni git" || ko "B.23 forge=$(wc -l < "$STUB_LOG") clone=$(grep -c '^clone' "$SHIM_LOG")"
run_rb "$TMP/b24.out" REQ_APP=nope; b_refus B.24 "manifeste absent" MANIFESTE_ABSENT "$TMP/b24.out"
run_rb "$TMP/b25.out" REQ_ENV=int REQ_CHANGE_REF=CHG-1 FORGE_TOKEN=t-alice; b_refus B.25 "palier non déclaré (int, sous identité humaine — A7)" PALIER_ABSENT "$TMP/b25.out"
run_rb "$TMP/b26.out" REQ_ENV=prod STOA_ENV_CHAIN_FILE="$CHAIN"; refus GATE_REFS_REQUIRED "$TMP/b26.out" && ! grep -q '^ETAPE clone' "$TMP/b26.out" && ok "B.26 terminus sans change_ref ⇒ GATE_REFS_REQUIRED avant le clone" || ko "B.26 : $(grep -E 'REFUS|ETAPE' "$TMP/b26.out" | tr '\n' ' ')"
run_rb "$TMP/b27.out" REQ_ENV=prod REQ_CHANGE_REF=CHG-1 FORGE_TOKEN=t-alice; refus PALIER_ABSENT "$TMP/b27.out" && grep -q '^ETAPE clone' "$TMP/b27.out" && ok "B.27 terminus avec change_ref ⇒ PALIER_ABSENT après le clone (ordre porte < clone < manifeste)" || ko "B.27 : $(grep -E 'REFUS' "$TMP/b27.out")"
# LIGNEE_TRONQUEE : une origine elle-même shallow
SH="$TMP/shallow"; git clone -q --bare --depth 1 "file://$ORIGIN" "$SH" 2>/dev/null || { echo "!! fixture : origine shallow" >&2; exit 2; }
set_ctl "$(ctl_json)"; run_rb "$TMP/b28.out" GIT_CLONE_URL="file://$SH"; b_refus B.28 "origine shallow" LIGNEE_TRONQUEE "$TMP/b28.out"
# cert absent à N-1, présent à N ⇒ git rm dans la PR
CL_SAVE="$CLOSED"; CLOSED=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; print(json.dumps([p for p in json.load(sys.stdin) if p["number"]<=12]))')
gw reset -q --hard "$SHA_C"; git -C "$W" rm -q "$CERT"; gw commit -qm "sans cert"; SHA_NC=$(pr_merge 13 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.5"] }' "-") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add); SHA_WC=$(pr_merge 14 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.6"] }' "CERT-W") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add); gw push -q -f origin master
set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/b29.out"; RB=$(remote_branch)
[ "$(rrc)" = 0 ] && [ "$(git -C "$ORIGIN" diff --name-status "$SHA_WC" "$RB" | sort | tr '\t' ' ' | tr '\n' ' ')" = "D $CERT M $MAN " ] && ok "B.29 cert absent à N-1 et présent à N ⇒ supprimé dans la PR (diff D cert, M manifeste)" || ko "B.29 rc $(rrc) diff : $(git -C "$ORIGIN" diff --name-status "$SHA_WC" "$RB" 2>/dev/null | tr '\n' ' ')"
grep -q 'cert : supprimé' "$STUB_POSTED" && ok "B.29b le corps de PR le dit" || ko "B.29b corps"
gw reset -q --hard "$MAIN0"; gw push -q -f origin master; CLOSED="$CL_SAVE"
# REPLI_DU_REPLI : N (#13') est lui-même un repli (son commit de branche porte Repli-Vers:)
CLOSED=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; print(json.dumps([p for p in json.load(sys.stdin) if p["number"]<=12]))')
gw reset -q --hard "$SHA_C"; gw checkout -q -B provision/appa-rec master; app_manifest_merge_env "$W/$MAN" rec "$(printf '%s' "$LINE_D" | sed -E 's/^    rec: //')" >/dev/null; gw add -A
gw commit -qm "$(printf 'provision(rec): repli de appa vers #10\n\nRepli-De: %s (PR #11)\nRepli-Vers: %s (PR #10)\n' "$SHA_B" "$SHA_A")"; gw checkout -q master; gw merge -q --no-ff -m "Merge pull request 'provision(rec): appa — repli' (#13) from provision/appa-rec into master" provision/appa-rec
SHA_RR=$(gw rev-parse HEAD); CLOSED=$(printf '%s' "$CLOSED" | N=13 SHA="$SHA_RR" python3 -c 'import json,os,sys; l=json.load(sys.stdin); l.append({"number":13,"merged":True,"state":"closed","merge_commit_sha":os.environ["SHA"],"head":{"ref":"provision/appa-rec","sha":"x","repo":{"full_name":"ci/stoa-labs"}},"base":{"ref":"master"},"user":{"login":"ci"}}); print(json.dumps(l))')
gw push -q -f origin master; set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/b30.out"
[ "$(rrc)" = 0 ] && grep -q '^REPLI_DU_REPLI : restaure #11' "$TMP/b30.out" && grep -q 'REPLI_DU_REPLI' "$STUB_POSTED" && grep -q '^REPLI_DU_REPLI=1' "$TMP/rb.env" && ok "B.30 N est un repli ⇒ REPLI_DU_REPLI imprimé, dans le corps, dans ROLLBACK_OUT" || ko "B.30 rc $(rrc) : $(grep -E 'REPLI_DU|REFUS' "$TMP/b30.out")"
gw reset -q --hard "$MAIN0"; gw push -q -f origin master; CLOSED="$CL_SAVE"
# LIGNEE_AMBIGUE : une PR mergée de fork avec ce head.ref
FK=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; l=json.load(sys.stdin)
for p in l:
    if p["number"]==11: p["head"]["repo"]["full_name"]="mallory/stoa-labs"
print(json.dumps(l))')
set_ctl "{\"closed\":$FK,\"open\":[]}"; reset_origin; run_rb "$TMP/b31.out"; b_refus B.31 "PR mergée depuis un fork dans la lignée" LIGNEE_AMBIGUE "$TMP/b31.out"
# LIGNE_AMBIGUE : N-1 porte deux change_ref (écrit à la master, la lib ne l'aurait jamais produit)
CLOSED=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; print(json.dumps([p for p in json.load(sys.stdin) if p["number"]<=10]))')
gw reset -q --hard "$SHA_A"; gw checkout -q -B provision/appa-rec master; python3 - "$W/$MAN" <<'PY'
import sys,re; p=sys.argv[1]; t=open(p).read(); t=re.sub(r'^(    rec: \{.*)change_ref: "CHG-0001"', r'\1change_ref: "CHG-0001", change_ref: "CHG-0002"', t, flags=re.M); open(p,"w").write(t)
PY
gw commit -qam "double clé"; gw checkout -q master; gw merge -q --no-ff -m "Merge pull request 'provision(rec): appa' (#11) from provision/appa-rec into master" provision/appa-rec; SHA_DK=$(gw rev-parse HEAD)
CLOSED=$(printf '%s' "$CLOSED" | SHA="$SHA_DK" python3 -c 'import json,os,sys; l=json.load(sys.stdin); l.append({"number":11,"merged":True,"state":"closed","merge_commit_sha":os.environ["SHA"],"head":{"ref":"provision/appa-rec","sha":"x","repo":{"full_name":"ci/stoa-labs"}},"base":{"ref":"master"},"user":{"login":"ci"}}); print(json.dumps(l))')
SHA_DK2=$(pr_merge 12 rec "$LINE_D" "CERT-D") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add); gw push -q -f origin master; set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/b32.out" STOA_ENV_CHAIN_FILE="$CHAIN_REC_GATED" REQ_CHANGE_REF=CHG-0009; b_refus B.32 "N-1 avec deux change_ref" LIGNE_AMBIGUE "$TMP/b32.out"
gw reset -q --hard "$MAIN0"; gw push -q -f origin master; CLOSED="$CL_SAVE"; gw branch -q -D provision/appa-rec 2>/dev/null || true

# CHAMP_REQUIS : les trois champs obligatoires du formulaire de repli se nomment
# (même défaut mesuré sur app-request #47 : un `${VAR:?}` de bash ne dit ni le
# formulaire ni le champ). Aucun réseau, aucune branche.
set_ctl "$(ctl_json)"; reset_origin
run_rb "$TMP/bcr1.out" REQ_APP=
{ refus CHAMP_REQUIS "$TMP/bcr1.out" && grep -q 'champ « APP »' "$TMP/bcr1.out"; } && ok "B.CR1 REQ_APP vide ⇒ CHAMP_REQUIS nommant le champ « APP »" || ko "B.CR1 rc $(rrc) : $(tail -1 "$TMP/bcr1.out")"
run_rb "$TMP/bcr2.out" REQ_ENV=
{ refus CHAMP_REQUIS "$TMP/bcr2.out" && grep -q 'champ « ENV »' "$TMP/bcr2.out"; } && ok "B.CR2 REQ_ENV vide ⇒ CHAMP_REQUIS nommant le champ « ENV »" || ko "B.CR2 rc $(rrc) : $(tail -1 "$TMP/bcr2.out")"
run_rb "$TMP/bcr3.out" REQ_REASON=
{ refus CHAMP_REQUIS "$TMP/bcr3.out" && grep -q 'champ « REASON »' "$TMP/bcr3.out"; } && ok "B.CR3 REQ_REASON vide ⇒ CHAMP_REQUIS nommant le champ « REASON »" || ko "B.CR3 rc $(rrc) : $(tail -1 "$TMP/bcr3.out")"
! grep -qE 'app-rollback-request\.sh: line [0-9]+' "$TMP/bcr1.out" && ok "B.CR4 plus aucun message brut « <script>: line N: REQ_X: … »" || ko "B.CR4 message brut : $(grep -E 'line [0-9]+' "$TMP/bcr1.out" | head -1)"

echo "══ C. mutations : la suite mord ══"
mutate(){ # <nom> <python transformant stdin→stdout> → chemin du mutant
  local m="$REPO/scripts/.a6-mut-$1.sh"; python3 -c "$2" < "$SCRIPT" > "$m"; chmod 700 "$m"   # à côté du script : il fait cd "$(dirname "$0")/.." et source ses libs
  cmp -s "$m" "$SCRIPT" && { ko "C.$1 mutant identique à l'original (mutation sans effet)"; return 1; }; printf '%s' "$m"
}
run_mut(){ SCRIPT="$1" run_rb "$2" "${@:3}"; }   # NB bash 3.2 : "${@:3}" est valide en bash (pas en sh)
# M1 : lignée par PRÉFIXE (la tête n'est plus exacte : toutes les provision/appa-* comptent —
# depuis le routage sur forge-api, la tête est l'argument de `forge pr_list_merged`, le
# mutant en interroge deux) ⇒ dev#14 devient N ⇒ N-1 = rec#13 = master ⇒ ETAT_IDENTIQUE ⇒ A rougit
M1=$(mutate M1 'import sys; s=sys.stdin.read(); assert "forge pr_list_merged \"$BRANCH\" >" in s; print(s.replace("forge pr_list_merged \"$BRANCH\" >", "{ for _b in provision/appa-rec provision/appa-dev; do forge pr_list_merged \"$_b\"; done; } >"), end="")') && {
  set_ctl "$(ctl_json)"; reset_origin; run_mut "$M1" "$TMP/m1.out"
  [ "$(rrc)" != 0 ] && grep -q 'ETAT_IDENTIQUE\|RESTAURATION_INFIDELE' "$TMP/m1.out" && ok "C.M1 clé de lignée par préfixe ⇒ le nominal rougit (dev#14 pris pour N)" || ko "C.M1 le mutant passe : rc $(rrc)"; }
# M2 : la porte (#3) déplacée APRÈS la lignée ⇒ A'.1 journalise un GET avant GATE_REFS_REQUIRED
# L'ancre du bloc CLONE est son EN-TÊTE DE SECTION, pas « etape clone » : depuis
# L3 (2026-09-10) l'askpass et la découverte de la branche précèdent l'étape à
# l'intérieur du même bloc, et couper sur « etape clone » les laissait du côté
# « porte » — le mutant clonait alors sans branche et mourait CLONE_ECHEC, pas
# GATE_REFS_REQUIRED : la mutation ne mesurait plus l'ordre qu'elle vise.
M2=$(mutate M2 'import sys; s=sys.stdin.read(); a=s.index("etape porte"); b=s.index("# \u2500\u2500 4. CLONE avec historique"); c=s.index("etape coherence"); print(s[:a]+s[b:c]+s[a:b]+s[c:], end="")') && {
  set_ctl "$(ctl_json)"; reset_origin; run_mut "$M2" "$TMP/m2.out" STOA_ENV_CHAIN_FILE="$CHAIN_REC_GATED"
  refus GATE_REFS_REQUIRED "$TMP/m2.out" && [ -s "$STUB_LOG" ] && ok "C.M2 porte après la lignée ⇒ la forge est appelée avant le refus (la suite le voit)" || ko "C.M2 : forge=$(wc -l < "$STUB_LOG")"; }
# M3 : auto-vérification retirée + ligne altérée avant le push ⇒ restauration infidèle poussée
M3=$(mutate M3 'import sys; s=sys.stdin.read(); assert "RESTAURATION_INFIDELE" in s; s=s.replace("[ \"$D_GOT\" = \"$D_EXPECT\" ] || refus RESTAURATION_INFIDELE", "sed -i.bak \"s/10.42.0.2/10.42.0.66/\" \"$R/$MAN_PATH\"; rm -f \"$R/$MAN_PATH.bak\"; git -C \"$R\" add \"$MAN_PATH\"; true"); print(s, end="")') && {
  set_ctl "$(ctl_json)"; reset_origin; run_mut "$M3" "$TMP/m3.out"; RB=$(remote_branch)
  [ "$(rrc)" = 0 ] && [ "$(git -C "$ORIGIN" show "$RB:$MAN" 2>/dev/null | grep -E '^    rec: ')" != "$LINE_B" ] && ok "C.M3 sans auto-vérification une ligne altérée est poussée — A.4 l'attrape" || ko "C.M3 rc $(rrc)"; }
# M4 : remplacement de change_ref retiré ⇒ A'.2 garde CHG-0001
M4=$(mutate M4 'import sys; s=sys.stdin.read(); assert "REQ_CHANGE_REF" in s; print(s.replace("CANDIDATE_REF=\"$REQ_CHANGE_REF\"", "CANDIDATE_REF=\"\""), end="")') && {
  set_ctl "$(ctl_json)"; reset_origin; run_mut "$M4" "$TMP/m4.out" STOA_ENV_CHAIN_FILE="$CHAIN_REC_GATED" REQ_CHANGE_REF=CHG-0009; RB=$(remote_branch)
  [ "$(rrc)" = 0 ] && git -C "$ORIGIN" show "$RB:$MAN" | grep -q 'change_ref: "CHG-0001"' && ok "C.M4 sans remplacement, CHG-0001 reste — A'.2 l'attrape" || ko "C.M4 rc $(rrc)"; }
# M5 : borne BIRTH retirée ⇒ le scénario « manifeste recréé » ouvre une PR vers une vie antérieure
M5=$(mutate M5 'import sys; s=sys.stdin.read(); assert "is-ancestor \"$BIRTH\"" in s; print(s.replace("is-ancestor \"$BIRTH\"", "is-ancestor \"$BIRTH\" \"$BIRTH\" || true; true"), end="")') && {
  gw rm -q "$MAN"; gw commit -qm "retrait"; gw push -q origin master; SHA_R2=$(pr_merge 20 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.20"] }' "CERT-R") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add); gw push -q origin master
  set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
  run_mut "$M5" "$TMP/m5.out"; [ "$(rrc)" = 0 ] && [ "$(posts)" = 1 ] && ok "C.M5 sans la borne BIRTH, une PR vers la vie antérieure (#13) s'ouvre — B.3 l'attrape" || ko "C.M5 rc $(rrc) posts=$(posts) : $(grep -E 'REFUS|LIGNEE' "$TMP/m5.out" | head -2 | tr '\n' ' ')"
  gw reset -q --hard "$MAIN0"; gw push -q -f origin master; CLOSED="$SAVE_CLOSED"; }

echo "══ B'. la garde symétrique : une demande ne réécrit pas une PR de repli ouverte ══"
set_ctl "$(ctl_json)"; reset_origin; run_rb "$TMP/bp0.out"; RB=$(remote_branch)   # une PR de repli « ouverte » : sa branche existe sur le nu
run_req(){ ( cd "$REPO" && env -i PATH="$SHIM:$PATH" HOME="$HOME" GITEA_TOKEN="$STUB_TOKEN" GIT_HOST="$GH" GIT_REPO=ci/stoa-labs GIT_CLONE_URL="file://$ORIGIN" GIT_SUBDIR="" GIT_PUSH_URL="file://$ORIGIN" \
   MANIFEST_DIR=clients/provisioned/applications STOA_ENV_CHAIN_FILE="$CHAIN" PROVISION_PLAN_INLINE=false REQ_APP=appa REQ_ENV=rec REQ_API=demo-selfservice REQ_CLIENT_ID=appa-rec REQ_CALLER=oig-provisioner REQ_IP_ALLOWLIST=10.42.0.44 bash scripts/provision-request.sh ) > "$1" 2>&1; echo $? > "$TMP/req.rc"; }
set_ctl "$(ctl_json "$(open_pr ci ci/stoa-labs "$RB")")"; run_req "$TMP/bp1.out"
[ "$(cat "$TMP/req.rc")" = 2 ] && grep -q 'REFUS: REPLI_EN_COURS' "$TMP/bp1.out" && [ "$(remote_branch)" = "$RB" ] && [ "$(posts)" = 0 ] && ok "B'.1 demande pendant un repli ouvert ⇒ REPLI_EN_COURS, branche intacte" || ko "B'.1 rc $(cat "$TMP/req.rc") branche=$(remote_branch) : $(grep -E 'REFUS|ERREUR' "$TMP/bp1.out" | head -1)"
set_ctl "$(ctl_json "$(open_pr alice ci/stoa-labs "$RB")")"; run_req "$TMP/bp1b.out"
[ "$(cat "$TMP/req.rc")" = 2 ] && grep -q 'REFUS: REPLI_EN_COURS' "$TMP/bp1b.out" && [ "$(remote_branch)" = "$RB" ] && ok "B'.1b PR de repli ouverte par un HUMAIN (alice) ⇒ REPLI_EN_COURS aussi (A7 : l'auteur n'exonère plus)" || ko "B'.1b rc $(cat "$TMP/req.rc") : $(grep -E 'REFUS|ERREUR' "$TMP/bp1b.out" | head -1)"
git -C "$ORIGIN" update-ref refs/heads/provision/appa-rec "$SHA_D"; set_ctl "$(ctl_json "$(open_pr ci ci/stoa-labs "$SHA_D")")"; run_req "$TMP/bp2.out"
[ "$(cat "$TMP/req.rc")" = 0 ] && grep -q 'PR déjà ouverte: #77' "$TMP/bp2.out" && grep -q -- '--force-with-lease=refs/heads/provision/appa-rec:' "$SHIM_LOG" && ok "B'.2 PR ouverte sans trailer ⇒ EXIST comme avant, push en bail" || ko "B'.2 rc $(cat "$TMP/req.rc") : $(grep -E 'PR |EXIST|push|REFUS' "$TMP/bp2.out" | head -3 | tr '\n' ' ') / bail=$(grep -c -- '--force-with-lease' "$SHIM_LOG") / $(grep -E 'push' "$SHIM_LOG" | head -1 | cut -c1-120)"

echo "══ B''. REPLI_PERIME au réconciliateur : un repli ne restaure que l'état d'avant le merge ══"
RECONCILE="$REPO/scripts/provision-apply-reconcile.sh"
reset_origin; W2="$TMP/w2"; rm -rf "$W2"; git clone -q "file://$ORIGIN" "$W2"
gw2(){ git -C "$W2" -c user.name=t -c user.email=t@t "$@"; }
# build_repli <trailer 0|1> [commit direct sur master : "" | "rec" | "cert"] → MERGE_SHA (master de W2 et d'origin avancés)
build_repli(){
  local trailer="$1" direct="${2:-}" msg
  gw2 checkout -q master; gw2 reset -q --hard "$MAIN0"
  case "$direct" in
    rec) app_manifest_merge_env "$W2/$MAN" rec '{ auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.77"] }' >/dev/null; gw2 commit -qam "hors flux rec" ;;
    cert) printf 'CERT-X\n' > "$W2/$CERT"; gw2 commit -qam "hors flux cert" ;;
  esac
  gw2 checkout -q -B provision/appa-rec master
  app_manifest_merge_env "$W2/$MAN" rec "$(printf '%s' "$LINE_B" | sed -E 's/^    rec: //')" >/dev/null; printf 'CERT-B\n' > "$W2/$CERT"; gw2 add -A
  if [ "$trailer" = 1 ]; then msg="$(printf 'provision(rec): repli de appa vers #11\n\nRepli-De: %s (PR #13)\nRepli-Vers: %s (PR #11)\n' "$SHA_D" "$SHA_B")"; else msg="provision(rec): application appa (demande t)"; fi
  gw2 commit -qm "$msg"; gw2 checkout -q master
  gw2 merge -q --no-ff -m "Merge pull request 'provision(rec): appa' (#42) from provision/appa-rec into master" provision/appa-rec
  gw2 push -q -f origin master; gw2 rev-parse HEAD
}
run_rec(){ # <MERGE_SHA> <sortie>
  local ms="$1"
  printf '{"closed":[{"number":42,"merged":true,"state":"closed","merge_commit_sha":"%s","merged_by":{"login":"alice"},"user":{"login":"ci"},"head":{"ref":"provision/appa-rec","sha":"x","repo":{"full_name":"ci/stoa-labs"}},"base":{"ref":"master"}}],"open":[]}' "$ms" > "$STUB_CTL"; : > "$STUB_LOG"
  ( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" GITEA_TOKEN="$STUB_TOKEN" GIT_HOST="$GH" GIT_REPO=ci/stoa-labs GIT_WORKTREE="$W2" \
      PR_BRANCH=provision/appa-rec PR_NUMBER=42 MERGE_SHA="$ms" RECONCILE_OUT="$TMP/rec.env" bash "$RECONCILE" ) > "$2" 2>&1; echo $? > "$TMP/rec.rc"
}
MS=$(build_repli 1); run_rec "$MS" "$TMP/bpp1.out"
[ "$(cat "$TMP/rec.rc")" = 0 ] && grep -q '^REPLI_OK' "$TMP/bpp1.out" && grep -q '^RECONCILE_OK' "$TMP/bpp1.out" && ok "B''.1 PR de repli, master immobile ⇒ REPLI_OK puis RECONCILE_OK" || ko "B''.1 rc $(cat "$TMP/rec.rc") : $(grep -E 'REFUS|REPLI|RECONCILE' "$TMP/bpp1.out" | head -2 | tr '\n' ' ')"
MS=$(build_repli 1 rec); run_rec "$MS" "$TMP/bpp2.out"
[ "$(cat "$TMP/rec.rc")" != 0 ] && grep -q 'REFUS: REPLI_PERIME' "$TMP/bpp2.out" && grep -q 'digest' "$TMP/bpp2.out" && ok "B''.2 master a bougé (ligne rec) entre la demande et le merge ⇒ REPLI_PERIME" || ko "B''.2 rc $(cat "$TMP/rec.rc") : $(grep -E 'REFUS|REPLI|RECONCILE' "$TMP/bpp2.out" | head -2 | tr '\n' ' ')"
MS=$(build_repli 1 cert); run_rec "$MS" "$TMP/bpp3.out"
[ "$(cat "$TMP/rec.rc")" != 0 ] && grep -q 'REFUS: REPLI_PERIME' "$TMP/bpp3.out" && grep -q 'certificat' "$TMP/bpp3.out" && ok "B''.3 seul le cert a bougé ⇒ REPLI_PERIME (blob comparé)" || ko "B''.3 rc $(cat "$TMP/rec.rc") : $(grep -E 'REFUS|REPLI|RECONCILE' "$TMP/bpp3.out" | head -2 | tr '\n' ' ')"
MS=$(build_repli 0 rec); run_rec "$MS" "$TMP/bpp4.out"
[ "$(cat "$TMP/rec.rc")" = 0 ] && ! grep -q 'REPLI' "$TMP/bpp4.out" && grep -q '^RECONCILE_OK' "$TMP/bpp4.out" && ok "B''.4 sans trailer le bloc est inerte (verdict d'avant, master ayant bougé ou non)" || ko "B''.4 rc $(cat "$TMP/rec.rc") : $(grep -E 'REFUS|REPLI|RECONCILE' "$TMP/bpp4.out" | head -2 | tr '\n' ' ')"
N4B=$(grep -c '^# ── 4bis\. A6' "$RECONCILE"); grep -q 'if \[ -n "\$REPLI_DE" \]; then' "$RECONCILE" && [ "$N4B" = 1 ] \
  && [ "$(grep -n '^# ── 4bis\. A6' "$RECONCILE" | cut -d: -f1)" -gt "$(grep -n 'fail PALIER_SUPPLANTE' "$RECONCILE" | tail -1 | cut -d: -f1)" ] \
  && [ "$(grep -n '^# ── 4bis\. A6' "$RECONCILE" | cut -d: -f1)" -lt "$(grep -n '^# ── 5\. SORTIE' "$RECONCILE" | cut -d: -f1)" ] \
  && ok "B''.5 le bloc 4bis est UN bloc conditionnel, entre PALIER_SUPPLANTE et la sortie" || ko "B''.5 structure du bloc 4bis"
reset_origin

echo "══ E11. A7 : le repli sous identité de forge ══"
cp "$REPO/clients/_example/environments.yaml" "$TMP/chain-gab.yaml"
set_ctl "$(ctl_json)"; reset_origin; run_rb "$TMP/e11.out" FORGE_TOKEN=t-alice
[ "$(rrc)" = 0 ] && [ "$(etapes "$TMP/e11.out")" = "forme chaine porte identite clone master manifeste lignee coherence candidate identique restauration verification pr-en-cours tete-distante commit push pr " ] \
  && ok "E11.1 token d'alice ⇒ ETAPE identite entre porte et clone, rc 0" || ko "E11.1 rc $(rrc) étapes : $(etapes "$TMP/e11.out") $(grep -E 'REFUS|ERREUR' "$TMP/e11.out" | head -1)"
L_USER=$(grep -n '^GET /api/v1/user ' "$STUB_LOG" | head -1 | cut -d: -f1); L_PULLS=$(grep -n 'pulls?state=closed' "$STUB_LOG" | head -1 | cut -d: -f1)
[ -n "$L_USER" ] && [ -n "$L_PULLS" ] && [ "$L_USER" -lt "$L_PULLS" ] && grep -q '^GET /api/v1/user alice$' "$STUB_LOG" && ok "E11.2 GET /user (alias alice) AVANT toute lecture de forge" || ko "E11.2 journal : user=$L_USER pulls=$L_PULLS"
[ "$(cat "$STUB_POSTED.auth" 2>/dev/null)" = "token t-alice" ] && grep -q 'ouverte par : alice (identite de forge' "$STUB_POSTED" && ok "E11.3 POST /pulls sous le token d'ALICE, corps « ouverte par : alice »" || ko "E11.3 auth='$(cat "$STUB_POSTED.auth" 2>/dev/null)'"
! grep -q 't-alice' "$SHIM_LOG" && ! grep -q 't-alice' "$TMP/e11.out" && ok "E11.4 le token n'apparaît ni en argv git ni dans la sortie" || ko "E11.4 token visible"
RB11=$(remote_branch)
set_ctl "$(ctl_json "$(open_pr alice ci/stoa-labs "$RB11")")"; run_rb "$TMP/e11b.out" FORGE_TOKEN=t-alice
[ "$(rrc)" = 0 ] && grep -q '^EXIST : la PR #77 (alice)' "$TMP/e11b.out" && [ "$(posts)" = 0 ] && ok "E11.5 EXIST strict étendu : PR d'alice au contenu identique + token d'alice ⇒ EXIST, ni push ni POST" || ko "E11.5 rc $(rrc) : $(grep -E 'EXIST|REFUS' "$TMP/e11b.out" | head -1)"
run_rb "$TMP/e11c.out"
refus PR_EN_COURS "$TMP/e11c.out" && ok "E11.6 la même PR d'alice sans token humain ⇒ PR_EN_COURS (pas la sienne)" || ko "E11.6 rc $(rrc) : $(grep REFUS "$TMP/e11c.out" | head -1)"
set_ctl "$(ctl_json)"; reset_origin; run_rb "$TMP/e11d.out" REQ_ENV=int "STOA_ENV_CHAIN_FILE=$TMP/chain-gab.yaml"
refus REQUESTER_UNKNOWN "$TMP/e11d.out" && ! grep -q '^ETAPE clone' "$TMP/e11d.out" && [ ! -s "$STUB_LOG" ] && ok "E11.7 int (fourEyes) sans token humain ⇒ REQUESTER_UNKNOWN avant ETAPE clone, journal de forge vide" || ko "E11.7 rc $(rrc) étapes : $(etapes "$TMP/e11d.out") forge=$(wc -l < "$STUB_LOG")"
run_rb "$TMP/e11e.out" FORGE_TOKEN=t-noscope
[ "$(rrc)" = 2 ] && grep -q 'REFUS: FORGE_SCOPE_INSUFFISANT' "$TMP/e11e.out" && ! grep -q '^ETAPE clone' "$TMP/e11e.out" && ok "E11.8 token sans read:user ⇒ FORGE_SCOPE_INSUFFISANT avant le clone" || ko "E11.8 rc $(rrc) : $(grep -E 'REFUS|ERREUR' "$TMP/e11e.out" | head -1)"

echo "══ F. STOA_DEBUG=1 : le repli parle, sans fuite (L2, plan 2026-09-09) ══"
# Gabarit D1/D2/D3 de test-vault-user-login.sh (et E12 de test-app-request-a7.sh,
# la suite sœur) : chaque ABSENCE (« le token n'y est pas ») est DOUBLÉE d'une
# PRÉSENCE (« la ligne attendue y est ») — une lib muette passerait toute
# absence (vert vacant). Deux tokens dans ce harnais : $STUB_TOKEN (service,
# dans l'environnement : redact le connaît par FORGE_SECRET) et t-alice (humain,
# RETIRÉ de l'environnement par A7 : redact ne le connaît que par son fichier,
# via DBG_SECRET_FILES — M6 retire cette ligne). Le préfixe des lignes du script
# est son nom ($0) : « [dbg app-rollback-request.sh] » ; les lignes HTTP
# viennent de forge-api.py, qui écrit lui-même « [dbg forge-api.py] ».
OUT="$TMP/f.out"; ERR="$TMP/f.err"
P='^\[dbg app-rollback-request\.sh\] '
rb2(){ run_rb2 "$OUT" "$ERR" "$@"; }                 # flux séparés
rbm(){ : > "$ERR"; run_rb "$OUT" "$@"; }             # flux fusionnés (l'ORDRE se lit là) ; stderr séparé vidé : toutes_absentes lit les deux
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
git -C "$ORIGIN" show "$MAIN0:$MAN" > "$TMP/main0.yml"; D_MAIN0=$(app_manifest_digest_env "$TMP/main0.yml" rec)   # le digest que le script lit sur la base (D_BASE)
# ── F.1 le nominal (A.1 sous STOA_DEBUG=1), flux SÉPARÉS ────────────────────
set_ctl "$(ctl_json)"; reset_origin
rb2 STOA_DEBUG=1
cp "$OUT" "$TMP/f1.stdout"
[ "$(rrc)" = 0 ] && [ "$(etapes "$OUT")" = "$(etapes "$TMP/a.out")" ] && grep -q '^PR_URL=http://stub/pulls/900$' "$OUT" && [ "$(posts)" = 1 ] \
  && ok "F.1a nominal sous STOA_DEBUG=1 : rc 0, les MÊMES ETAPE qu'A.1, PR_URL= sur stdout, une PR postée — le produit d'A" \
  || ko "F.1a rc $(rrc) posts=$(posts) étapes : $(etapes "$OUT") $(grep -hE 'REFUS|ERREUR' "$OUT" "$ERR" | head -2 | tr '\n' ' ')"
# LE PRODUIT : stdout ne porte QUE le contrat — « ETAPE … », « LIGNEE : », les
# lignes de détail indentées, « PR_URL= », « REPLI_DE= », « OK: » — jamais une
# ligne de debug : ni « [dbg », ni un CLÉ=VALEUR nu. M8 remplace un dbg_kv par
# un echo : c'est la seconde moitié de cette assertion qui le voit.
! grep -q '\[dbg' "$OUT" && ! grep -qvE '^(ETAPE |LIGNEE : |REPLI_DU_REPLI : |EXIST : |  |PR_URL=|REPLI_DE=|\[plan\] |OK: )' "$OUT" \
  && ok "F.1b stdout = le contrat seul (ETAPE, LIGNEE, détails indentés, PR_URL=, REPLI_DE=, OK:) — aucune ligne de debug, ni [dbg ni CLÉ=VALEUR" \
  || ko "F.1b stdout pollué : $(grep -vE '^(ETAPE |LIGNEE : |REPLI_DU_REPLI : |EXIST : |  |PR_URL=|REPLI_DE=|\[plan\] |OK: )' "$OUT" | head -2 | tr '\n' ' ')"
# LES PRÉSENCES, une à une. D'abord ce que les AUTORITÉS disent (le script ne le redit pas) …
pres F.1c "${P}FORGE_KIND=gitea\$" "] FORGE_KIND=gitea (forge_api_init)"
pres F.1d "${P}GIT_BASE=master\$" "] GIT_BASE=master (git_base_init — la HEAD de la fixture)"
pres F.1e "${P}GIT_BASE_ORIGINE=decouverte\$" "] GIT_BASE_ORIGINE=decouverte (aucun GIT_BASE dans l'environnement de run_rb)"
# … puis ce que CE script décide : la disposition (GIT_SUBDIR="" dans run_rb :
# SUB_PFX est VIDE et se DIT — c'est le diagnostic), l'identité, les bornes de
# la lignée, chaque geste git avec son VRAI rc.
pres F.1f "${P}SUB_PFX=<vide>\$" "] SUB_PFX=<vide> (GIT_SUBDIR=\"\" : le livrable EST la racine — le vide se DIT)"
pres F.1g "${P}MAN_PATH=clients/provisioned/applications/appa\\.ansible\\.yml\$" "] MAN_PATH=<SUB_PFX>clients/provisioned/applications/appa.ansible.yml"
pres F.1h "${P}CERT_PATH=clients/provisioned/certs/appa-rec\\.crt\$" "] CERT_PATH=<SUB_PFX>clients/provisioned/certs/appa-rec.crt"
pres F.1i "${P}BRANCH=provision/appa-rec\$" "] BRANCH=provision/appa-rec"
pres F.1j "${P}GIT_CLONE_URL=file://" "] GIT_CLONE_URL=file://… (l'URL reçue ou composée : c'est elle qu'on diagnostique)"
pres F.1k "${P}FORGE_LOGIN=\\(service\\)\$" "] FORGE_LOGIN=(service) (sans token humain)"
pres F.1l "${P}PUSH_LOGIN=ci\$" "] PUSH_LOGIN=ci"
pres F.1m "${P}git clone --single-branch --branch master file://[^ ]+ -> rc 0\$" "] git clone --single-branch --branch master <url> -> rc 0"
pres F.1n "${P}D_BASE=${D_MAIN0}\$" "] D_BASE=<digest de master pour rec> (= #13, celui d'A.8)"
pres F.1o "${P}BIRTH=${SHA_A}\$" "] BIRTH=<merge #10> (la naissance du manifeste sur la première parenté)"
pres F.1p '^\[dbg forge-api\.py\] GET http://127\.0\.0\.1:[0-9]+/api/v1/repos/ci/stoa-labs/pulls\?state=closed[^ ]* -> HTTP 200 \([0-9]+ octets\)$' "[dbg forge-api.py] GET …/pulls?state=closed… -> HTTP 200 (pr_list_merged — merged.err RELAYÉ sur succès, sinon perdu)"
pres F.1q "${P}NUM_N=13\$" "] NUM_N=13 (l'état courant)"
pres F.1r "${P}SHA_N=${SHA_D}\$" "] SHA_N=<merge #13>"
pres F.1s "${P}NUM_N1=11\$" "] NUM_N1=11 (l'état à restaurer)"
pres F.1t "${P}SHA_N1=${SHA_B}\$" "] SHA_N1=<merge #11>"
pres F.1u "${P}D_EXPECT=${D_B}\$" "] D_EXPECT=<digest de #11 pour rec> (celui d'A.8)"
pres F.1v '^\[dbg forge-api\.py\] GET http://127\.0\.0\.1:[0-9]+/api/v1/repos/ci/stoa-labs/pulls\?state=open[^ ]* -> HTTP 200 \([0-9]+ octets\)$' "[dbg forge-api.py] GET …/pulls?state=open… -> HTTP 200 (pr_find_open — open.err relayé)"
pres F.1w "${P}O_NUMBER=<vide>\$" "] O_NUMBER=<vide> (aucune PR ouverte sur la branche : le vide se DIT)"
pres F.1x "${P}git ls-remote --heads origin refs/heads/provision/appa-rec -> rc 0\$" "] git ls-remote --heads origin refs/heads/provision/appa-rec -> rc 0 (jadis 2>/dev/null)"
pres F.1y "${P}TIP=<vide>\$" "] TIP=<vide> (pas de tête distante : premier passage, bail vide)"
pres F.1z "${P}git push --force-with-lease=refs/heads/provision/appa-rec: origin HEAD:refs/heads/provision/appa-rec -> rc 0\$" "] git push --force-with-lease=…: origin HEAD:… -> rc 0"
pres F.1aa '^\[dbg forge-api\.py\] POST http://127\.0\.0\.1:[0-9]+/api/v1/repos/ci/stoa-labs/pulls -> HTTP 201 \([0-9]+ octets\)$' "[dbg forge-api.py] POST …/pulls -> HTTP 201 (pr_open — pr.err relayé)"
pres F.1ab "${P}PR_NUM=900\$" "] PR_NUM=900 (créée)"
# LES ABSENCES : aucune forme du token de service, aucun en-tête d'auth en clair.
toutes_absentes "$STUB_TOKEN" && ! grep -q 'Authorization: token' "$OUT" "$ERR" \
  && ok "F.1ac AUCUNE forme de $STUB_TOKEN (service) ni d'en-tête « Authorization: token » — ni sur stdout ni sur stderr" \
  || ko "F.1ac fuite : $(grep -nE "$STUB_TOKEN|Authorization: token" "$OUT" "$ERR" | head -1)"
# ── F.2 sous identité HUMAINE (E11.1 sous STOA_DEBUG=1) ──────────────────────
set_ctl "$(ctl_json)"; reset_origin
rb2 FORGE_TOKEN=t-alice STOA_DEBUG=1
[ "$(rrc)" = 0 ] && grep -q '^ETAPE identite$' "$OUT" && [ "$(cat "$STUB_POSTED.auth" 2>/dev/null)" = "token t-alice" ] \
  && ok "F.2a token d'alice sous STOA_DEBUG=1 : rc 0, ETAPE identite, PR postée sous alice — le produit d'E11.1" \
  || ko "F.2a rc $(rrc) auth='$(cat "$STUB_POSTED.auth" 2>/dev/null)' : $(grep -hE 'REFUS|ERREUR' "$OUT" "$ERR" | head -1)"
pres F.2b "${P}FORGE_LOGIN=alice\$" "] FORGE_LOGIN=alice (forge_login)"
pres F.2c "${P}PUSH_LOGIN=alice\$" "] PUSH_LOGIN=alice (le pousseur est l'humain)"
# LIMITE MESURÉE (hors des fichiers de cette tâche, déjà consignée par a7 E12.1n') :
# la ligne « [dbg forge-api.py] GET …/user -> HTTP 200 » du whoami est ÉCRITE par
# python, mais forge_login (scripts/lib/forge-identity.sh) capture le stderr du
# verbe dans ${tf}.err, l'efface, et ne le relaie que sur rc ≠ 0 : sur SUCCÈS
# elle est PERDUE. Le whoami se prouve donc par le JOURNAL du stub (E11.2 le
# fait aussi) ; le jour où forge-identity.sh relaie, décommenter la présence :
# pres "F.2d'" '^\[dbg forge-api\.py\] GET http://127\.0\.0\.1:[0-9]+/[^ ]+/user -> HTTP 200 \([0-9]+ octets\)$' "[dbg forge-api.py] GET …/user -> HTTP 200 (forge_login : le whoami, relayé succès compris)"
grep -q '^GET /api/v1/user alice$' "$STUB_LOG" && ok "F.2d le whoami a eu lieu sous le token d'alice (journal du stub — la ligne HTTP, forge_login la perd sur succès : limite hors tâche)" || ko "F.2d journal : $(grep '/user' "$STUB_LOG" | head -1)"
toutes_absentes t-alice && toutes_absentes "$STUB_TOKEN" \
  && ok "F.2e AUCUNE forme de t-alice (humain) ni de $STUB_TOKEN (service) — ni sur stdout ni sur stderr" \
  || ko "F.2e fuite : $(grep -nE "t-alice|$STUB_TOKEN" "$OUT" "$ERR" | head -1)"
# F.2f : l'identité est DITE avant le refus qui la juge (E11.7 sous debug) —
# « ] FORGE_LOGIN=(service) » PRÉCÈDE « REFUS: REQUESTER_UNKNOWN », et rien
# d'autre n'a bougé : pas d'ETAPE clone, journal de forge vide.
set_ctl "$(ctl_json)"; reset_origin
rbm REQ_ENV=int "STOA_ENV_CHAIN_FILE=$TMP/chain-gab.yaml" STOA_DEBUG=1
[ "$(rrc)" = 2 ] && avant "${P}FORGE_LOGIN=\\(service\\)\$" '^REFUS: REQUESTER_UNKNOWN' && ! grep -q '^ETAPE clone' "$OUT" && [ ! -s "$STUB_LOG" ] \
  && ok "F.2f int (fourEyes) sans token humain sous STOA_DEBUG=1 : « ] FORGE_LOGIN=(service) » PRÉCÈDE « REFUS: REQUESTER_UNKNOWN » ; pas de clone, forge muette (E11.7)" \
  || ko "F.2f rc $(rrc) : $(grep -nE 'FORGE_LOGIN|REFUS' "$OUT" | head -2 | tr '\n' ' ')"
# ── F.3 le push REFUSÉ (B.16 sous identité humaine) : le shim recopie le secret de l'askpass ──
set_ctl "$(ctl_json)"; reset_origin
rb2 FORGE_TOKEN=t-alice SHIM_PUSH_FAIL=1 STOA_DEBUG=1
[ "$(rrc)" = 2 ] && grep -qE '^REFUS: PUSH_ECHEC : push de provision/appa-rec refusé \(bail perdu ou droits\) : fatal: unable to access \(simulé\) — askpass a rendu <secret masqué> ?$' "$ERR" && [ "$(posts)" = 0 ] \
  && ok "F.3a push refusé sous STOA_DEBUG=1 : rc 2, « REFUS: PUSH_ECHEC : … » et son détail MASQUÉ (redact par le FICHIER du pousseur, plus jamais un grep -v en argv), aucune PR" \
  || ko "F.3a rc $(rrc) posts=$(posts) : $(grep -nE 'REFUS|fatal' "$ERR" | head -2 | tr '\n' ' ')"
pres F.3b "${P}git push --force-with-lease=refs/heads/provision/appa-rec: origin HEAD:refs/heads/provision/appa-rec -> rc 128\$" "] git push … -> rc 128 (le VRAI rc du shim, pas celui d'un « ! »)"
pres F.3c "${P}  git: fatal: unable to access \\(simulé\\) — askpass a rendu <secret masqué> ?\$" "]   git: … askpass a rendu <secret masqué> (le stderr du push, rédigé par le FICHIER du token humain ; l'espace final est le retour-ligne mis à plat)"
toutes_absentes t-alice && toutes_absentes "$STUB_TOKEN" \
  && ok "F.3d JAMAIS t-alice ni $STUB_TOKEN, sous aucune forme — ni dans le refus, ni dans une ligne de debug" \
  || ko "F.3d fuite : $(grep -nE "t-alice|$STUB_TOKEN" "$OUT" "$ERR" | head -1)"
# ── F.3e/f l'ORDRE de dbg_git_err : masqué EN ENTIER, PUIS coupé à 400 octets ──
# Le DISCRIMINANT (grammaire §3, CORRECTION revues B1/B3 : « l'ORDRE doit avoir
# son ÉPREUVE ») : le secret du harnais (t-alice, 7 octets) ne chevauche jamais
# la coupe de lui-même, et dbg remasque derrière — sans discriminant, un helper
# qui couperait AVANT de masquer traverse F.3a-d en vert. Le shim recopie donc
# le secret une seconde fois à partir de l'octet 395 de sa ligne : à cheval sur
# 400 (ligne brute de 402 octets). Masque puis coupe ⇒ la ligne « git: » porte
# le premier masque entier, puis le rembourrage, et s'arrête à 400 octets AVANT
# la seconde occurrence (déjà masquée). Coupe puis masque ⇒ « askpass a rendu
# t-ali », cinq octets du token humain que ni redact ni dbg ne reconnaissent —
# c'est M9. Le REFUS (coupé à 200) est relu ici par PRÉSENCE seulement : à 395,
# il finit dans le rembourrage dans les DEUX ordres (relecture B4, I-2 : le
# mutant coupe-puis-masque R2b survivait) — SON discriminant est F.3h, avec le
# secret à cheval sur SA coupe.
SECRET_AT=395; FRAG="t-alice"; FRAG="${FRAG:0:$((400 - SECRET_AT))}"   # le morceau que laisserait la coupe : « t-ali »
set_ctl "$(ctl_json)"; reset_origin
rb2 FORGE_TOKEN=t-alice SHIM_PUSH_FAIL=1 "SHIM_SECRET_AT=$SECRET_AT" STOA_DEBUG=1
# git_line : la charge de la ligne « git: » du push, sans le préfixe « [dbg <script>] »
# (agnostique du NOM : M9 la relit sur une copie nommée .a6-mut-M9.sh) ; git_octets : sa taille en OCTETS.
git_line(){ grep -m1 -E '^\[dbg [^]]*\]   git: fatal: unable to access' "$ERR" | sed -E 's/^\[dbg [^]]*\]   git: //' | tr -d '\n'; }
git_octets(){ echo $(( $(git_line | wc -c) )); }
[ "$(rrc)" = 2 ] && grep -qE "${P}  git: fatal: unable to access \\(simulé\\) — askpass a rendu <secret masqué> x+" "$ERR" && [ "$(git_octets)" -eq 400 ] \
  && grep -qE '^REFUS: PUSH_ECHEC : .*fatal: unable to access \(simulé\) — askpass a rendu <secret masqué> x+$' "$ERR" \
  && ok "F.3e stderr de push de 402 octets, secret à cheval sur l'octet 400 : la ligne « git: » porte « <secret masqué> » puis le rembourrage et fait EXACTEMENT 400 octets (masquée en entier, PUIS coupée) ; le refus porte le masque puis le rembourrage (présence — son ordre, c'est F.3h)" \
  || ko "F.3e rc $(rrc) octets=$(git_octets) : …$(git_line | tail -c 40) / refus : $(grep -oE 'REFUS: PUSH_ECHEC : .{0,60}' "$ERR" | head -1)"
! grep -oE 'askpass a rendu [^ ]*' "$OUT" "$ERR" | grep -vqE 'askpass a rendu (<secret|$)' && ! grep -qF -- "$FRAG" "$OUT" "$ERR" && toutes_absentes t-alice && toutes_absentes "$STUB_TOKEN" \
  && ok "F.3f après « askpass a rendu », rien d'autre que le masque (entier, ou coupé par les 400 octets) : ni « $FRAG » ni aucune forme de t-alice / $STUB_TOKEN — aucun MORCEAU du secret n'a survécu à la coupe" \
  || ko "F.3f morceau du secret : $(grep -noE 'askpass a rendu [^ ]*' "$OUT" "$ERR" | grep -vE '<secret' | head -1)"
# ── F.3h l'ORDRE du REFUS PUSH_ECHEC : masqué EN ENTIER, PUIS coupé à 200 octets ──
# Le refus sort au log Jenkins MÊME SANS STOA_DEBUG — c'est ce qu'un client
# colle dans un ticket. Même discriminant que F.3e, sur SA coupe : le secret à
# l'octet 195 (ligne brute de 202 octets). Mesuré (sim, tour de correction 1) :
# masque puis coupe ⇒ le détail fait EXACTEMENT 200 octets et finit « x… askpass
# a re » (la coupe tombe dans le texte qui PRÉCÈDE la seconde occurrence, déjà
# masquée) ; coupe puis masque ⇒ « askpass a rendu t-ali », 209 octets (210 avec
# un tr '\n' ' ' — l'espace que R2 laissait derrière le \n de redact, et qui
# seul faisait rougir F.3e : plus jamais le discriminant). C'est M13.
SECRET_AT_REFUS=195; FRAG_REFUS="t-alice"; FRAG_REFUS="${FRAG_REFUS:0:$((200 - SECRET_AT_REFUS))}"   # « t-ali »
# refus_detail <TAG> <préambule regex> : la charge du refus derrière « : » (stderr séparé ou fusionné), sans le retour-ligne — wc -c la compte en OCTETS
refus_detail(){ grep -h -m1 -E "^REFUS: $1 : $2 : " "$ERR" "$OUT" | sed -E "s#^REFUS: $1 : $2 : ##" | tr -d '\n'; }   # délimiteur « # » : le préambule porte un « / » (provision/appa-rec)
refus_octets(){ echo $(( $(refus_detail "$1" "$2" | wc -c) )); }   # comme git_octets : l'arithmétique retire les blancs que wc -c laisse devant
set_ctl "$(ctl_json)"; reset_origin
rb2 FORGE_TOKEN=t-alice SHIM_PUSH_FAIL=1 "SHIM_SECRET_AT=$SECRET_AT_REFUS"
PD='push de provision/appa-rec refusé \(bail perdu ou droits\)'
[ "$(rrc)" = 2 ] && grep -qE "^REFUS: PUSH_ECHEC : ${PD} : fatal: unable to access \\(simulé\\) — askpass a rendu <secret masqué> x+ askpass a re\$" "$ERR" \
  && [ "$(refus_octets PUSH_ECHEC "$PD")" -eq 200 ] && ! grep -qF -- "askpass a rendu $FRAG_REFUS" "$OUT" "$ERR" && toutes_absentes t-alice && toutes_absentes "$STUB_TOKEN" \
  && ok "F.3h SANS debug, secret à cheval sur l'octet 200 : le détail de « REFUS: PUSH_ECHEC » porte « <secret masqué> » puis le rembourrage, fait EXACTEMENT 200 octets et finit « askpass a re » (masqué en entier, PUIS coupé) ; jamais « $FRAG_REFUS »" \
  || ko "F.3h rc $(rrc) octets=$(refus_octets PUSH_ECHEC "$PD") : …$(refus_detail PUSH_ECHEC "$PD" | tail -c 40)"
# ── F.3g l'ORDRE dans le journal : rc et stderr de git PRÉCÈDENT le refus ──────
set_ctl "$(ctl_json)"; reset_origin
rbm FORGE_TOKEN=t-alice SHIM_PUSH_FAIL=1 STOA_DEBUG=1
[ "$(rrc)" = 2 ] && avant "${P}git push .* -> rc 128\$" '^REFUS: PUSH_ECHEC' && avant "${P}  git: " '^REFUS: PUSH_ECHEC' \
  && ok "F.3g « git push … -> rc 128 » puis « git: … » PRÉCÈDENT « REFUS: PUSH_ECHEC » (le log se lit de haut en bas)" \
  || ko "F.3g ordre : $(grep -nE 'git push|  git: |REFUS' "$OUT" | head -3 | tr '\n' ' ')"
# ── F.4 l'échec de forge : la ligne HTTP PRÉCÈDE le refus, sans token ─────────
set_ctl '{"down":true}'; reset_origin
rbm STOA_DEBUG=1
[ "$(rrc)" = 2 ] && avant '^\[dbg forge-api\.py\] GET [^ ]+/pulls\?state=closed[^ ]* -> HTTP 500 ' '^REFUS: FORGE_ILLISIBLE' && toutes_absentes "$STUB_TOKEN" \
  && ok "F.4a forge en panne (500) : « GET …/pulls?state=closed… -> HTTP 500 » PRÉCÈDE « REFUS: FORGE_ILLISIBLE » (B.6) ; jamais $STUB_TOKEN" \
  || ko "F.4a rc $(rrc) : $(grep -nE 'HTTP 500|REFUS' "$OUT" | head -2 | tr '\n' ' ')"
set_ctl "$(ctl_json)"; reset_origin
rbm GITEA_TOKEN=t-inconnu STOA_DEBUG=1
[ "$(rrc)" = 2 ] && avant '^\[dbg forge-api\.py\] GET [^ ]+/pulls\?state=closed[^ ]* -> HTTP 401 ' '^REFUS: FORGE_ILLISIBLE' && toutes_absentes t-inconnu && toutes_absentes "$STUB_TOKEN" \
  && ok "F.4b token de service refusé (401) : « GET …/pulls?… -> HTTP 401 » PRÉCÈDE « REFUS: FORGE_ILLISIBLE » ; ni t-inconnu ni $STUB_TOKEN" \
  || ko "F.4b rc $(rrc) : $(grep -nE 'HTTP 401|REFUS' "$OUT" | head -2 | tr '\n' ' ')"
# ── F.5 le silence : STOA_DEBUG=0 ⇒ zéro [dbg, stderr = la SEULE ligne d'information de git-base.sh, stdout OCTET POUR OCTET celui de F.1 ──
# stderr n'est plus VIDE depuis e2f947b (main) : git-base.sh annonce chaque
# découverte, INCONDITIONNELLEMENT, sur une ligne — « git-base: GIT_BASE=<b>
# découvert — HEAD annoncée par <url> (ls-remote --symref) ». C'est
# l'auditabilité d'une pose, pas le mode debug (F.1e prouve que run_rb
# découvre : GIT_BASE_ORIGINE=decouverte). Ce que F.5 prouve donc : zéro ligne
# [dbg sur les deux flux, et stderr = EXACTEMENT cette ligne, avec l'URL que
# _rb_run donne (file://$ORIGIN) — épinglée en PRÉSENCE : « ! -s » ou une
# exclusion nue laisserait passer un stderr muet comme un stderr bavard.
# Mesuré au rebase L2-R (2026-09-11) : 158/159, stderr = 163 octets = cette
# seule ligne (recomptée par printf | wc -c).
set_ctl "$(ctl_json)"; reset_origin
rb2 STOA_DEBUG=0
LIGNE_GITBASE="git-base: GIT_BASE=master découvert — HEAD annoncée par file://$ORIGIN (ls-remote --symref)"
[ "$(rrc)" = 0 ] && ! grep -q '\[dbg' "$OUT" "$ERR" && [ $(( $(wc -l < "$ERR") )) -eq 1 ] && grep -qxF -- "$LIGNE_GITBASE" "$ERR" && cmp -s "$OUT" "$TMP/f1.stdout" \
  && ok "F.5 STOA_DEBUG=0 : zéro ligne [dbg, stderr = la SEULE ligne « git-base: GIT_BASE=master découvert — HEAD annoncée par file://…/origin.git » (l'auditabilité d'une pose, e2f947b — pas le debug), et stdout identique octet pour octet à celui de F.1 — le mode debug n'ajoute rien au produit" \
  || ko "F.5 rc $(rrc) dbg=$(grep -c '\[dbg' "$OUT" "$ERR" | tr '\n' ' ') stderr=$(( $(wc -l < "$ERR") )) ligne(s) : « $(head -1 "$ERR" | cut -c1-140) » diff: $(diff "$OUT" "$TMP/f1.stdout" | head -2 | tr '\n' ' ')"
# ── F.6 le clone RATÉ sous debug : le rc du clone n'est plus prouvé qu'à 0 ─────
# GIT_BASE=develop (knob explicite : aucun ls-remote, GIT_BASE_ORIGINE=knob),
# branche absente du nu. « git clone … -> rc 128 » (le VRAI rc — M11 écrit 0)
# PRÉCÈDE « REFUS: CLONE_ECHEC », et la ligne « git: » nomme la branche que git
# n'a pas trouvée (« fatal » et « develop », jamais la langue de git : sous
# env -i, git parle la langue du poste). Le refus porte le même détail, masqué
# par redact avant la coupe à 200 — plus jamais un grep -v du token en argv.
set_ctl "$(ctl_json)"; reset_origin
rbm GIT_BASE=develop STOA_DEBUG=1
[ "$(rrc)" = 2 ] && grep -qE "${P}GIT_BASE_ORIGINE=knob\$" "$OUT" && avant "${P}git clone --single-branch --branch develop file://[^ ]+ -> rc 128\$" '^REFUS: CLONE_ECHEC : clone de ci/stoa-labs \(develop\) impossible : ' \
  && ok "F.6a GIT_BASE=develop absente sous STOA_DEBUG=1 : « ] GIT_BASE_ORIGINE=knob », « git clone --single-branch --branch develop <url> -> rc 128 » PRÉCÈDE « REFUS: CLONE_ECHEC » (rc 2, inchangé)" \
  || ko "F.6a rc $(rrc) : $(grep -nE 'git clone|GIT_BASE_ORIGINE|REFUS' "$OUT" | head -3 | tr '\n' ' ')"
grep -qE "${P}  git: .*fatal.*develop" "$OUT" && avant "${P}  git: " '^REFUS: CLONE_ECHEC' && grep -qE '^REFUS: CLONE_ECHEC : .*fatal.*develop' "$OUT" && [ "$(posts)" = 0 ] && toutes_absentes "$STUB_TOKEN" \
  && ok "F.6b la ligne « git: » du clone nomme la branche introuvable (fatal … develop) AVANT le refus, qui la nomme aussi ; aucune forge touchée ; jamais $STUB_TOKEN" \
  || ko "F.6b : $(grep -nE '  git: |REFUS' "$OUT" | head -2 | tr '\n' ' ')"
# ── F.6c/d le clone RATÉ qui CITE un secret (relecture B4, I-1) ────────────────
# F.6a/b ratent le clone sur une branche absente : git n'y cite aucun secret, et
# le refus CLONE_ECHEC pouvait relayer clone.err NU (mutant R1 : redact ⇒ cat,
# 64/64) — un vert vacant sur la propriété §4 du brief. Le shim recopie donc le
# secret de l'askpass dans le stderr du clone (SHIM_CLONE_FAIL=1, la panne de
# F.3 portée au verbe clone), sous identité humaine : t-alice n'est connu de
# redact que par son FICHIER (argument "$PUSH_TF", et DBG_SECRET_FILES). Le
# refus ET la ligne « git: » portent le masque ; le VRAI rc ; aucune forge
# interrogée sur les PR (le whoami, lui, a eu lieu : il précède le clone).
set_ctl "$(ctl_json)"; reset_origin
rbm FORGE_TOKEN=t-alice SHIM_CLONE_FAIL=1 STOA_DEBUG=1
CD='clone de ci/stoa-labs \(master\) impossible'
[ "$(rrc)" = 2 ] && grep -qE "^REFUS: CLONE_ECHEC : ${CD} : fatal: unable to access \\(simulé\\) — askpass a rendu <secret masqué> ?\$" "$OUT" \
  && avant "${P}git clone --single-branch --branch master file://[^ ]+ -> rc 128\$" '^REFUS: CLONE_ECHEC' && avant "${P}  git: fatal: unable to access \\(simulé\\) — askpass a rendu <secret masqué> ?\$" '^REFUS: CLONE_ECHEC' \
  && ! grep -q '/pulls' "$STUB_LOG" && [ "$(posts)" = 0 ] && toutes_absentes t-alice && toutes_absentes "$STUB_TOKEN" \
  && ok "F.6c clone refusé (le shim recopie le secret de l'askpass) sous STOA_DEBUG=1 : « git clone … -> rc 128 » et « git: … <secret masqué> » PRÉCÈDENT « REFUS: CLONE_ECHEC : … <secret masqué> » ; aucune lecture des PR ; jamais t-alice ni $STUB_TOKEN" \
  || ko "F.6c rc $(rrc) : $(grep -nE 'git clone|  git: |REFUS' "$OUT" | head -3 | tr '\n' ' ') pulls=$(grep -c '/pulls' "$STUB_LOG")"
# F.6d : l'ORDRE du refus CLONE_ECHEC (coupe à 200), même discriminant que F.3h —
# le secret à l'octet 195, sans debug : 200 octets, fin « askpass a re », jamais « t-ali » (M14).
set_ctl "$(ctl_json)"; reset_origin
rbm FORGE_TOKEN=t-alice SHIM_CLONE_FAIL=1 "SHIM_SECRET_AT=$SECRET_AT_REFUS"
[ "$(rrc)" = 2 ] && grep -qE "^REFUS: CLONE_ECHEC : ${CD} : fatal: unable to access \\(simulé\\) — askpass a rendu <secret masqué> x+ askpass a re\$" "$OUT" \
  && [ "$(refus_octets CLONE_ECHEC "$CD")" -eq 200 ] && ! grep -qF -- "askpass a rendu $FRAG_REFUS" "$OUT" "$ERR" && toutes_absentes t-alice && toutes_absentes "$STUB_TOKEN" \
  && ok "F.6d SANS debug, secret à cheval sur l'octet 200 : le détail de « REFUS: CLONE_ECHEC » porte « <secret masqué> » puis le rembourrage, fait EXACTEMENT 200 octets et finit « askpass a re » (masqué en entier, PUIS coupé) ; jamais « $FRAG_REFUS »" \
  || ko "F.6d rc $(rrc) octets=$(refus_octets CLONE_ECHEC "$CD") : …$(refus_detail CLONE_ECHEC "$CD" | tail -c 40)"
# ── F.7 la tête distante : TIP dit, fetch et merge-base avec leur VRAI rc ──────
# F.7a : tête MERGÉE (B.15) ⇒ TIP=<sha>, fetch rc 0, merge-base rc 0, bail sur cette tête.
set_ctl "$(ctl_json)"; reset_origin; git -C "$ORIGIN" update-ref refs/heads/provision/appa-rec "$SHA_C"
rb2 STOA_DEBUG=1
[ "$(rrc)" = 0 ] && grep -qE "${P}TIP=${SHA_C}\$" "$ERR" && grep -qE "${P}git fetch origin refs/heads/provision/appa-rec -> rc 0\$" "$ERR" \
  && grep -qE "${P}git merge-base --is-ancestor ${SHA_C} origin/master -> rc 0\$" "$ERR" && grep -qE "${P}git push --force-with-lease=refs/heads/provision/appa-rec:${SHA_C} origin HEAD:refs/heads/provision/appa-rec -> rc 0\$" "$ERR" \
  && ok "F.7a tête mergée sous STOA_DEBUG=1 : « ] TIP=<sha> », « git fetch … -> rc 0 », « git merge-base --is-ancestor <sha> origin/master -> rc 0 », push en bail sur cette tête (B.15)" \
  || ko "F.7a rc $(rrc) : $(grep -nE 'TIP=|git fetch|merge-base|git push' "$ERR" | head -4 | tr '\n' ' ')"
# F.7b : tête NON mergée (B.14) ⇒ « merge-base … -> rc 1 » (le VRAI rc : 1 = pas un ancêtre) PRÉCÈDE BRANCHE_NON_MERGEE.
gw checkout -q -B provision/appa-rec master; printf 'x\n' > "$W/HAND"; gw add -A; gw commit -qm "poussé à la master"; gw push -q -f origin provision/appa-rec; gw checkout -q master
HAND_SHA=$(gw rev-parse provision/appa-rec)
set_ctl "$(ctl_json)"; rbm STOA_DEBUG=1
[ "$(rrc)" = 2 ] && avant "${P}git merge-base --is-ancestor ${HAND_SHA} origin/master -> rc 1\$" '^REFUS: BRANCHE_NON_MERGEE' && [ "$(posts)" = 0 ] && toutes_absentes "$STUB_TOKEN" \
  && ok "F.7b tête non mergée : « git merge-base --is-ancestor <tête> origin/master -> rc 1 » PRÉCÈDE « REFUS: BRANCHE_NON_MERGEE » (B.14) ; jamais $STUB_TOKEN" \
  || ko "F.7b rc $(rrc) : $(grep -nE 'merge-base|REFUS' "$OUT" | head -2 | tr '\n' ' ')"
gw branch -q -D provision/appa-rec; reset_origin
# ── F.8 EXIST (B.12) sous debug : la PR ouverte est DITE, le fetch de sa tête aussi, stdout intact ──
set_ctl "$(ctl_json)"; reset_origin; run_rb "$TMP/f8a.out"; RB=$(remote_branch)
set_ctl "$(ctl_json "$(open_pr ci ci/stoa-labs "$RB")")"; rb2 STOA_DEBUG=1
[ "$(rrc)" = 0 ] && grep -q '^EXIST : la PR #77 (ci)' "$OUT" && ! grep -q '\[dbg' "$OUT" && [ "$(posts)" = 0 ] \
  && grep -qE "${P}O_NUMBER=77\$" "$ERR" && grep -qE "${P}O_LOGIN=ci\$" "$ERR" && grep -qE "${P}git fetch origin refs/heads/provision/appa-rec -> rc 0\$" "$ERR" && toutes_absentes "$STUB_TOKEN" \
  && ok "F.8 EXIST strict sous STOA_DEBUG=1 : « ] O_NUMBER=77 », « ] O_LOGIN=ci », « git fetch … -> rc 0 » (la tête de la PR relue), EXIST sur stdout sans [dbg, ni POST ; jamais $STUB_TOKEN" \
  || ko "F.8 rc $(rrc) posts=$(posts) : $(grep -nE 'O_NUMBER|O_LOGIN|git fetch' "$ERR" | head -3 | tr '\n' ' ') / $(grep -E 'EXIST|REFUS' "$OUT" | head -1)"
reset_origin

echo "══ F'. mutations du mode debug : chaque garde neuve attrape ce qu'elle prétend attraper ══"
run_mut2(){ SCRIPT="$1" run_rb2 "$2" "$3" "${@:4}"; }   # flux séparés (les mutants du mode debug lisent stdout SEUL)
# M6 : la ligne PORTEUSE du mode debug. Le token humain a été retiré de
# l'environnement (A7) : redact ne le connaît que par DBG_SECRET_FILES. Sans
# cette ligne, le stderr du push raté — où le shim recopie le secret de
# l'askpass — sort EN CLAIR dans la ligne de debug « git: … ». Le refus, lui,
# reste masqué (redact reçoit le fichier en argument) : la fuite est DANS une
# ligne [dbg, et nulle part ailleurs — c'est ce que l'assertion cible (F.3d rougit).
M6=$(mutate M6 'import re,sys; s=sys.stdin.read(); assert re.search(r"^DBG_SECRET_FILES=", s, re.M); print(re.sub(r"^DBG_SECRET_FILES=.*\n", "", s, count=1, flags=re.M), end="")') && {
  set_ctl "$(ctl_json)"; reset_origin; run_mut2 "$M6" "$OUT" "$ERR" FORGE_TOKEN=t-alice SHIM_PUSH_FAIL=1 STOA_DEBUG=1
  grep '^\[dbg' "$ERR" | grep -q 't-alice' \
    && ok "F'.M6 DBG_SECRET_FILES retirée ⇒ le token HUMAIN fuit dans la ligne de debug du push raté (F.3d rougit : redact ne le connaît que par son fichier)" \
    || ko "F'.M6 rc $(rrc) : le mutant ne fuit pas dans une ligne [dbg — $(grep -c 't-alice' "$ERR") occurrence(s) de t-alice sur stderr, toutes hors [dbg"; }
# M7 (§4 de la grammaire) : le détail du push passe par `redact "$PUSH_TF" < push.err`
# (le chemin du fichier en argument, jamais le secret en argv) ; le mutant le
# remplace par un `cat` nu — l'ancien `grep -v` n'existe plus, un mutant qui le
# viserait serait un no-op (compté ko par mutate).
M7=$(mutate M7 'import sys; s=sys.stdin.read(); assert "redact \"$PUSH_TF\" < \"$WORK/push.err\"" in s; print(s.replace("redact \"$PUSH_TF\" < \"$WORK/push.err\"", "cat \"$WORK/push.err\""), end="")') && {
  set_ctl "$(ctl_json)"; reset_origin; run_mut2 "$M7" "$OUT" "$ERR" FORGE_TOKEN=t-alice SHIM_PUSH_FAIL=1
  [ "$(rrc)" = 2 ] && grep -E '^REFUS: PUSH_ECHEC' "$ERR" | grep -q 't-alice' \
    && ok "F'.M7 redact du push remplacé par cat ⇒ le refus PUSH_ECHEC porte le token humain (F.3a/F.3d rougissent — et sans STOA_DEBUG : c'est le refus lui-même qui fuit)" \
    || ko "F'.M7 rc $(rrc) : le mutant ne fuit pas dans le refus"; }
# M8 : une ligne de debug qui se tromperait de flux. `dbg_kv MAN_PATH` devient un
# `echo` (stdout) : PR_URL= y est toujours, « pas de [dbg » seul ne le verrait
# pas — c'est l'assertion « stdout = le contrat seul » (F.1b) qui doit rougir.
M8=$(mutate M8 'import sys; s=sys.stdin.read(); assert "dbg_kv MAN_PATH \"$MAN_PATH\"" in s; print(s.replace("dbg_kv MAN_PATH \"$MAN_PATH\"", "echo \"MAN_PATH=$MAN_PATH\""), end="")') && {
  set_ctl "$(ctl_json)"; reset_origin; run_mut2 "$M8" "$OUT" "$ERR" STOA_DEBUG=1
  [ "$(rrc)" = 0 ] && grep -q '^PR_URL=' "$OUT" && grep -q '^MAN_PATH=' "$OUT" \
    && ok "F'.M8 dbg_kv MAN_PATH ⇒ echo : stdout porte « MAN_PATH=… » à côté de PR_URL= (F.1b rougit — « pas de [dbg » seul ne le verrait pas)" \
    || ko "F'.M8 rc $(rrc) : stdout sans MAN_PATH= ($(grep -c . "$OUT") lignes)"; }
# M9 : l'ORDRE de dbg_git_err — COUPER puis masquer (la première rédaction de la
# grammaire §3, corrigée par les revues B1/B3). Sur le stderr de F.3e (le secret
# à cheval sur l'octet 400), la coupe laisse « t-ali », que ni redact ni le dbg
# qui remasque derrière ne reconnaissent : cinq octets du token humain dans la
# ligne « git: ». La longueur le trahit aussi : 400 octets coupés PUIS remasqués
# (le masque fait 9 octets de plus que t-alice) en font 409, la forme livrée 400.
M9=$(mutate M9 'import sys; s=sys.stdin.read(); assert "m=\"$(redact < \"$1\" | tr" in s; print(s.replace("m=\"$(redact < \"$1\" | tr", "m=\"$(head -c 400 < \"$1\" | tr"), end="")') && {
  set_ctl "$(ctl_json)"; reset_origin; run_mut2 "$M9" "$OUT" "$ERR" FORGE_TOKEN=t-alice SHIM_PUSH_FAIL=1 "SHIM_SECRET_AT=$SECRET_AT" STOA_DEBUG=1
  grep '^\[dbg' "$ERR" | grep -qF -- "askpass a rendu $FRAG" \
    && ok "F'.M9 dbg_git_err coupe PUIS masque ⇒ « askpass a rendu $FRAG » : cinq octets du token humain fuient dans la ligne « git: », qui fait $(git_octets) octets au lieu de 400 (F.3e ET F.3f rougissent)" \
    || ko "F'.M9 rc $(rrc) : le mutant ne laisse pas de morceau — …$(git_line | tail -c 40)"; }
# M10 : le RELAIS de merged.err retiré — sur succès, la ligne HTTP de pr_list_merged
# (écrite par forge-api.py dans un stderr capturé) redevient PERDUE : F.1p rougit.
M10=$(mutate M10 'import sys; s=sys.stdin.read(); l="[ -s \"$WORK/merged.err\" ] && cat \"$WORK/merged.err\" >&2\n"; assert l in s; print(s.replace(l, ""), end="")') && {
  set_ctl "$(ctl_json)"; reset_origin; run_mut2 "$M10" "$OUT" "$ERR" STOA_DEBUG=1
  [ "$(rrc)" = 0 ] && ! grep -qE '^\[dbg forge-api\.py\] GET [^ ]+/pulls\?state=closed[^ ]* -> HTTP 200 ' "$ERR" && grep -qE '^\[dbg forge-api\.py\] GET [^ ]+/pulls\?state=open[^ ]* -> HTTP 200 ' "$ERR" \
    && ok "F'.M10 relais de merged.err retiré ⇒ « GET …state=closed… -> HTTP 200 » disparaît (F.1p rougit) alors que celle de state=open reste — le produit, lui, est intact (rc 0)" \
    || ko "F'.M10 rc $(rrc) : $(grep -cE 'state=closed.* -> HTTP 200' "$ERR") ligne(s) closed, $(grep -cE 'state=open.* -> HTTP 200' "$ERR") open"; }
# M11 : le rc DIT n'est pas le rc REÇU — « -> rc 0 » écrit en dur à la place de
# « -> rc $rc » sur le clone. La décision qui suit lit $rc, pas la ligne : le
# refus reste, la ligne MENT. Sans F.6a, ce mutant traverserait la suite en vert.
M11=$(mutate M11 'import sys; s=sys.stdin.read(); l="dbg \"git clone --single-branch --branch $GIT_BASE $GIT_CLONE_URL -> rc $rc\""; assert l in s; print(s.replace(l, l.replace("-> rc $rc", "-> rc 0")), end="")') && {
  set_ctl "$(ctl_json)"; reset_origin; run_mut "$M11" "$OUT" GIT_BASE=develop STOA_DEBUG=1
  [ "$(rrc)" = 2 ] && grep -q 'REFUS: CLONE_ECHEC' "$OUT" && grep -qE '^\[dbg [^]]*\] git clone --single-branch --branch develop .* -> rc 0$' "$OUT" \
    && ok "F'.M11 « git clone … -> rc 0 » en dur ⇒ la ligne dit rc 0 alors que REFUS: CLONE_ECHEC suit (F.6a rougit)" \
    || ko "F'.M11 rc $(rrc) : $(grep -nE 'git clone|REFUS' "$OUT" | head -2 | tr '\n' ' ')"; }
# M12 (relecture B4, I-1) : le jumeau de M7 sur le CLONE — `redact "$PUSH_TF" <
# clone.err` remplacé par un `cat` nu. Avant F.6c, aucun clone raté du harnais
# ne citait un secret : ce mutant traversait la suite en vert (R1, 64/64). Joué
# SANS debug : c'est le refus CLONE_ECHEC lui-même qui fuit le token humain.
M12=$(mutate M12 'import sys; s=sys.stdin.read(); assert "redact \"$PUSH_TF\" < \"$WORK/clone.err\"" in s; print(s.replace("redact \"$PUSH_TF\" < \"$WORK/clone.err\"", "cat \"$WORK/clone.err\""), end="")') && {
  set_ctl "$(ctl_json)"; reset_origin; run_mut2 "$M12" "$OUT" "$ERR" FORGE_TOKEN=t-alice SHIM_CLONE_FAIL=1
  [ "$(rrc)" = 2 ] && grep -E '^REFUS: CLONE_ECHEC' "$ERR" | grep -q 't-alice' \
    && ok "F'.M12 redact du clone remplacé par cat ⇒ le refus CLONE_ECHEC porte le token humain (F.6c rougit — sans STOA_DEBUG : c'est le refus lui-même qui fuit)" \
    || ko "F'.M12 rc $(rrc) : le mutant ne fuit pas dans le refus — $(grep -E '^REFUS' "$ERR" | head -1 | head -c 120)"; }
# M13 (relecture B4, I-2) : l'ORDRE du refus PUSH_ECHEC — COUPER puis masquer,
# sous la forme qui SURVIVAIT à la suite (R2b : `tr -d '\n'`, sans l'espace
# final qui seul faisait rougir F.3e). Sur le stderr de F.3h (secret à cheval
# sur l'octet 200), la coupe laisse « t-ali » que redact ne reconnaît plus :
# cinq octets du token humain DANS LE REFUS, 209 octets au lieu de 200.
M13=$(mutate M13 'import sys; s=sys.stdin.read(); a="$(redact \"$PUSH_TF\" < \"$WORK/push.err\" | head -c 200 | tr \x27\\n\x27 \x27 \x27)"; assert a in s; print(s.replace(a, "$(head -c 200 < \"$WORK/push.err\" | redact \"$PUSH_TF\" | tr -d \x27\\n\x27)"), end="")') && {
  set_ctl "$(ctl_json)"; reset_origin; run_mut2 "$M13" "$OUT" "$ERR" FORGE_TOKEN=t-alice SHIM_PUSH_FAIL=1 "SHIM_SECRET_AT=$SECRET_AT_REFUS"
  [ "$(rrc)" = 2 ] && grep -E '^REFUS: PUSH_ECHEC' "$ERR" | grep -qF -- "askpass a rendu $FRAG_REFUS" \
    && ok "F'.M13 refus PUSH_ECHEC coupé PUIS masqué ⇒ « askpass a rendu $FRAG_REFUS » : cinq octets du token humain dans le REFUS, détail de $(refus_octets PUSH_ECHEC "$PD") octets au lieu de 200 (F.3h rougit)" \
    || ko "F'.M13 rc $(rrc) : le mutant ne laisse pas de morceau — …$(refus_detail PUSH_ECHEC "$PD" | tail -c 40)"; }
# M14 : le même mutant sur le refus CLONE_ECHEC (même forme, ligne du clone) — F.6d rougit.
M14=$(mutate M14 'import sys; s=sys.stdin.read(); a="$(redact \"$PUSH_TF\" < \"$WORK/clone.err\" | head -c 200 | tr \x27\\n\x27 \x27 \x27)"; assert a in s; print(s.replace(a, "$(head -c 200 < \"$WORK/clone.err\" | redact \"$PUSH_TF\" | tr -d \x27\\n\x27)"), end="")') && {
  set_ctl "$(ctl_json)"; reset_origin; run_mut2 "$M14" "$OUT" "$ERR" FORGE_TOKEN=t-alice SHIM_CLONE_FAIL=1 "SHIM_SECRET_AT=$SECRET_AT_REFUS"
  [ "$(rrc)" = 2 ] && grep -E '^REFUS: CLONE_ECHEC' "$ERR" | grep -qF -- "askpass a rendu $FRAG_REFUS" \
    && ok "F'.M14 refus CLONE_ECHEC coupé PUIS masqué ⇒ « askpass a rendu $FRAG_REFUS » dans le REFUS, $(refus_octets CLONE_ECHEC "$CD") octets au lieu de 200 (F.6d rougit)" \
    || ko "F'.M14 rc $(rrc) : le mutant ne laisse pas de morceau — …$(refus_detail CLONE_ECHEC "$CD" | tail -c 40)"; }
reset_origin

echo "══ D. câblage : le formulaire, la coquille, le Makefile, les commentaires D8 ══"
JF="$REPO/ci/Jenkinsfile.app-rollback"; XML="$REPO/ci/jenkins/app-rollback.job.xml"; MK="$REPO/Makefile"
[ -f "$JF" ] && grep -q 'properties(\[parameters(\[' "$JF" && ok "D.1 Jenkinsfile.app-rollback pose son formulaire par properties()" || ko "D.1 Jenkinsfile absent ou sans properties()"
L_G=$(grep -nF 'CHAMP_REQUIS' "$JF" | head -1 | cut -d: -f1); L_S=$(grep -nF 'bash scripts/app-rollback-request.sh' "$JF" | head -1 | cut -d: -f1)
[ -n "$L_G" ] && [ -n "$L_S" ] && [ "$L_G" -lt "$L_S" ] && ok "D.1bis la garde CHAMP_REQUIS (ligne $L_G) précède l'appel du script (ligne $L_S) : le formulaire se refuse AVANT le workspace" || ko "D.1bis garde=$L_G sh=$L_S"
NAMES=$(sed -n '/properties(\[parameters(\[/,/\])\])/p' "$JF" | grep -oE "name: '[A-Z_]+'" | sed "s/name: '//;s/'//" | tr '\n' ' ')
[ "$NAMES" = "APP ENV REASON CHANGE_REF DEBUG FORGE_TOKEN " ] && ok "D.2 exactement six champs : APP ENV REASON CHANGE_REF DEBUG FORGE_TOKEN (A7 + la case DEBUG juste avant l'identité, L4)" || ko "D.2 champs : $NAMES"
grep -q "password(name: 'FORGE_TOKEN'" "$JF" && ! grep -q 'FORGE_TOKEN=${params' "$JF" && grep -q 'TOKEN_ALTERE' "$JF" && grep -q 'TOKEN_GLOBAL_REFUSE' "$JF" && ok "D.2b FORGE_TOKEN est un password, hors de tout withEnv (fait 9), gardes TOKEN_ALTERE / TOKEN_GLOBAL_REFUSE" || ko "D.2b câblage FORGE_TOKEN"
[ "$(grep -n 'FORM_BOOTSTRAP = ' "$JF" | head -1 | cut -d: -f1)" -lt "$(grep -n 'properties(\[parameters' "$JF" | cut -d: -f1)" ] && ok "D.3 FORM_BOOTSTRAP lu AVANT properties()" || ko "D.3 ordre FORM_BOOTSTRAP/properties"
grep -q 'env_chain_validate && env_chain"' "$JF" && ok "D.4 la liste ENV vient de env_chain ENTIÈRE, validée" || ko "D.4 liste ENV"
[ "$(grep -c 'STOA_ENV_CHAIN_FILE="\$WORKSPACE/\$GIT_SUBDIR/clients/_example/environments.yaml"' "$JF")" = 2 ] && ok "D.5 la chaîne est épinglée sur les DEUX lignes sh, et COMPOSÉE depuis \$GIT_SUBDIR (plus de préfixe du lab en dur)" || ko "D.5 épinglages composés : $(grep -c 'STOA_ENV_CHAIN_FILE=' "$JF")"
grep -q 'withCredentials(forgeCreds())' "$JF" && grep -q 'credentialsId: env.GITEA_CREDENTIALS_ID' "$JF" && grep -qF 'set +x; if [ "${DEBUG:-false}" = "true" ]; then export STOA_DEBUG=1; fi; STOA_ENV_CHAIN_FILE=' "$JF" && grep -q 'set +x; if .*; STOA_ENV_CHAIN_FILE=.*bash scripts/app-rollback-request.sh' "$JF" && ok "D.6 le script est appelé sous withCredentials, set +x, PUIS le pont DEBUG (if/fi, L4), chaîne épinglée" || ko "D.6 appel du script"
grep -q 'withEnv(\["REQ_APP=${params.APP}", "REQ_ENV=${params.ENV}", "REQ_REASON=${params.REASON}", "REQ_CHANGE_REF=${params.CHANGE_REF}"\])' "$JF" && ok "D.7 withEnv porte les quatre valeurs (EnvVars.resolve)" || ko "D.7 withEnv"
grep -q 'UserIdCause' "$JF" && grep -q 'jenkins-form:' "$JF" && ok "D.8 identité jenkins-form:<uid> (informative)" || ko "D.8 identité"
! grep -qE '^\s*triggers \{|^\s*parameters \{' "$JF" && ok "D.9 ni triggers{} ni parameters{} déclaratifs" || ko "D.9 triggers/parameters déclaratifs présents"
grep -q 'CpsScmFlowDefinition' "$XML" && grep -q '<scriptPath>poc-control-plane-federation/ci/Jenkinsfile.app-rollback</scriptPath>' "$XML" && grep -q '<properties/>' "$XML" && grep -q '<triggers/>' "$XML" && ! grep -q '<script>' "$XML" \
  && ok "D.10 coquille XML pure : SCM, scriptPath, aucune propriété, aucun trigger, aucun Groovy" || ko "D.10 coquille XML"
# Le compte de la dernière étape est écrit EN DUR ici : c'est ce qui rend
# visible qu'une porte a été ajoutée (ou retirée) au Makefile. 2026-09-07 :
# [17/17] → [18/18], le préflight de joignabilité branché en dernière étape.
# 2026-09-08 : [18/18] → [19/19], la porte de portabilité du préfixe du livrable
# (test-repo-layout-portabilite.sh) insérée en 18e, le préflight repoussé en 19e.
# 2026-09-09 : [19/19] → [20/20], la porte de l'appartenance d'équipe lue en YAML
# (test-providers-teams.sh) insérée en 19e, le préflight repoussé en 20e.
grep -q 'scripts/app-rollback-request.sh scripts/test-app-rollback-a6.sh' "$MK" && grep -q '\[20/20\]' "$MK" && grep -q 'bash scripts/test-app-rollback-a6.sh' "$MK" && ! grep -q '/15\]' "$MK" && ! grep -q '/17\]' "$MK" && ! grep -q '/18\]' "$MK" && ! grep -q '/19\]' "$MK" \
  && ok "D.11 Makefile : shellcheck des scripts A6, [20/20] (A7, valeurs par défaut, portabilité du préfixe, appartenance d'équipe, puis le préflight branchés), la suite câblée" || ko "D.11 Makefile"
! grep -q 'sauf repli (A6)' "$REPO/ci/Jenkinsfile.selfservice" && grep -q 'le repli (A6) est une PR' "$REPO/ci/Jenkinsfile.selfservice" && ok "D.12 Jenkinsfile.selfservice : le levier n'est plus « le repli »" || ko "D.12 commentaire selfservice"
! grep -q 'levier du repli (A6)' "$REPO/ENVIRONNEMENTS.md" && grep -q 'le repli est une PR' "$REPO/ENVIRONNEMENTS.md" && ok "D.13 ENVIRONNEMENTS.md : idem" || ko "D.13 ENVIRONNEMENTS.md"

EXPECTED_CHECKS=159
TOTAL=$((PASS+FAIL))
if [ "$EXPECTED_CHECKS" -gt 0 ] && [ "$TOTAL" -ne "$EXPECTED_CHECKS" ]; then
  printf '❌ %d contrôles exécutés, %d attendus — une section a été sautée ou ajoutée sans mettre EXPECTED_CHECKS à jour\n' "$TOTAL" "$EXPECTED_CHECKS"; FAIL=$((FAIL+1))
fi
echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
