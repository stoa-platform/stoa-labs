#!/usr/bin/env bash
# test-app-rollback-a6.sh — LA PORTE HORS LIGNE d'A6 (le repli d'une application est une PR).
# Fixture : un dépôt nu servi en file:// (GIT_BASE=main) construit par de vrais
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
        with open(LOG, "a") as f: f.write("%s %s%s\n" % (method, path, ("?" + u.query) if u.query else ""))
        if self.headers.get("Authorization") != "token " + TOKEN: return self._send(401, {"message": "unauthorized"})
        c = ctl()
        if c.get("down"): return self._send(500, {"message": "boom"})
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
exec "$REAL_GIT" "\$@"
SH
chmod 700 "$SHIM/git"

# ── la fixture git : nu + clone de construction ──
ORIGIN="$TMP/origin.git"; W="$TMP/w"
git init -q --bare "$ORIGIN" && git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main && git -C "$ORIGIN" config uploadpack.allowFilter true
git init -q "$W" && git -C "$W" checkout -q -b main
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
  gw checkout -q -B "$br" main
  case "$e" in
    rec) mkdir -p "$(dirname "$W/$MAN")" "$(dirname "$W/$CERT")"; gw show "main:$MAN" > "$TMP/cur.yml" 2>/dev/null || write_man "$TMP/cur.yml" '    dev: { auth: { claim: { value: "appa-dev" } } }' ''
         cp "$TMP/cur.yml" "$W/$MAN"; app_manifest_merge_env "$W/$MAN" rec "$(printf '%s' "$line" | sed -E 's/^    rec: //')" || { echo "!! fixture : fusion rec #$n" >&2; exit 2; } ;;
    dev) mkdir -p "$(dirname "$W/$MAN")" "$(dirname "$W/$CERT")"; gw show "main:$MAN" > "$W/$MAN" 2>/dev/null || write_man "$W/$MAN" '' ''
         app_manifest_merge_env "$W/$MAN" dev "$(printf '%s' "$line" | sed -E 's/^    dev: //')" || { echo "!! fixture : fusion dev #$n" >&2; exit 2; } ;;
  esac
  case "$cert" in -) ;; rm) gw rm -q "$CERT" 2>/dev/null || true ;; *) printf '%s\n' "$cert" > "$W/$CERT" ;; esac
  gw add -A; gw commit -qm "provision($e): application appa (demande t)" >/dev/null
  gw checkout -q main; gw merge -q --no-ff -m "Merge pull request 'provision($e): appa' (#$n) from $br into main" "$br"
  sha=$(gw rev-parse HEAD)
  N="$n" BR="$br" SHA="$sha" python3 -c 'import json,os
print(json.dumps({"number":int(os.environ["N"]),"merged":True,"state":"closed","merge_commit_sha":os.environ["SHA"],
 "head":{"ref":os.environ["BR"],"sha":"deadbeef","repo":{"full_name":"ci/stoa-labs"}},"base":{"ref":"main"},"user":{"login":"ci"}}))' > "$TMP/last.pr"
  printf '%s' "$sha"
}
# ordre imposé : rec#a(10), rec#b(11), dev#c(12), rec#d(13), dev#e(14)
SHA_A=$(pr_merge 10 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.1"], change_ref: "CHG-0001", pv_ref: "PV-1" }' "CERT-A") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add)
SHA_B=$(pr_merge 11 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.2"], change_ref: "CHG-0001", pv_ref: "PV-1" }' "CERT-B") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add)
SHA_C=$(pr_merge 12 dev '    dev: { auth: { claim: { value: "appa-dev" } }, ip_allowlist: ["10.0.0.9"] }') || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add)
SHA_D=$(pr_merge 13 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.3"], change_ref: "CHG-0002", pv_ref: "PV-1" }' "CERT-D") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add)
SHA_E=$(pr_merge 14 dev '    dev: { auth: { claim: { value: "appa-dev" } }, ip_allowlist: ["10.0.0.10"] }') || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add)
gw remote add origin "$ORIGIN"; gw push -q origin main
MAIN0=$(gw rev-parse main)
LINE_B=$(gw show "$SHA_B:$MAN" | grep -E '^    rec: '); LINE_D=$(gw show "$SHA_D:$MAN" | grep -E '^    rec: ')
gw show "$SHA_B:$MAN" > "$TMP/b.yml"; D_B=$(app_manifest_digest_env "$TMP/b.yml" rec)
[ -n "$SHA_E" ] && [ "$LINE_B" != "$LINE_D" ] && [ -n "$D_B" ] && ok "0.1 fixture : 5 merges (rec#10 rec#11 dev#12 rec#13 dev#14), N=#13 N-1=#11, lignes distinctes" || ko "0.1 fixture illisible"
set_ctl(){ printf '%s' "$1" > "$STUB_CTL"; : > "$STUB_LOG"; : > "$STUB_POSTED"; : > "$SHIM_LOG"; }
ctl_json(){ # [open json list] → ctl avec CLOSED courant
  printf '{"closed":%s,"open":%s}' "$CLOSED" "${1:-[]}"
}
reset_origin(){ git -C "$W" push -q -f origin "$MAIN0:main"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true; }
# run_rb <sortie> [VAR=val …] : le script sous test ; rc dans $TMP/rb.rc
run_rb(){
  local out="$1"; shift
  rm -f "$TMP/rb.out"
  ( cd "$REPO" && env -i PATH="$SHIM:$PATH" HOME="$HOME" SHIM_ORIGIN="$ORIGIN" \
      GITEA_TOKEN="$STUB_TOKEN" GIT_HOST="$GH" GIT_REPO=ci/stoa-labs GIT_BASE=main GIT_SUBDIR="" \
      GIT_CLONE_URL="file://$ORIGIN" STOA_ENV_CHAIN_FILE="$CHAIN" PROVISION_PLAN_INLINE=false \
      REQ_APP=appa REQ_ENV=rec REQ_REASON="incident reseau" REQ_CALLER="jenkins-form:alice" ROLLBACK_OUT="$TMP/rb.env" \
      "$@" bash "$SCRIPT" ) > "$out" 2>&1
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
[ "$(etapes "$TMP/a.out")" = "forme chaine porte clone main manifeste lignee coherence candidate identique restauration verification pr-en-cours tete-distante commit push pr " ] \
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
gw checkout -q main; SAVE_CLOSED="$CLOSED"
SHA_F=$(pr_merge 15 rec "$(printf '%s' "$LINE_D" | sed 's/change_ref: "CHG-0002"/change_ref: "CHG-0003"/')" "CERT-D") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add); gw push -q origin main
set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/ap3.out" STOA_ENV_CHAIN_FILE="$CHAIN_REC_GATED" REQ_CHANGE_REF=CHG-0003
refus ETAT_IDENTIQUE "$TMP/ap3.out" && [ "$(posts)" = 0 ] && ok "A'.5 #15 ne diffère de #13 que par change_ref et le repli fournit celui de #15 ⇒ ETAT_IDENTIQUE (pas de commit vide)" || ko "A'.5 rc $(rrc) : $(grep REFUS "$TMP/ap3.out")"
run_rb "$TMP/ap4.out" STOA_ENV_CHAIN_FILE="$CHAIN_REC_GATED" REQ_CHANGE_REF=CHG-0004
[ "$(rrc)" = 0 ] && [ "$(posts)" = 1 ] && ok "A'.6 avec un autre change_ref ⇒ PR ouverte" || ko "A'.6 rc $(rrc) posts=$(posts)"
# ligne N-1 avec change_ref NU
gw push -q -f origin "$MAIN0:main"; CLOSED="$SAVE_CLOSED"
SHA_G=$(pr_merge 16 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.7"], change_ref: CHG-0005 }' "CERT-G") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add)
SHA_H=$(pr_merge 17 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.8"], change_ref: CHG-0006 }' "CERT-H") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add); gw push -q -f origin main
set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/ap5.out" STOA_ENV_CHAIN_FILE="$CHAIN_REC_GATED" REQ_CHANGE_REF=CHG-0009
RB=$(remote_branch); L=$(git -C "$ORIGIN" show "$RB:$MAN" 2>/dev/null | grep -E '^    rec: ')
[ "$(rrc)" = 0 ] && [ "$L" = '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.7"], change_ref: "CHG-0009" }' ] \
  && ok "A'.7 change_ref NU (non quoté) à N-1 ⇒ remplacé, une seule clé" || ko "A'.7 rc $(rrc) ligne : $L"
gw push -q -f origin "$MAIN0:main"; CLOSED="$SAVE_CLOSED"; gw checkout -q main; gw reset -q --hard "$MAIN0"
echo "══ B. refus nommés — rien poussé, aucun POST ══"
b_refus(){ # <n> <libellé> <TAG> <fichier de sortie>
  refus "$3" "$4" && [ "$(posts)" = 0 ] && [ "$(remote_branch)" = absente ] && ok "$1 $2 ⇒ $3, rien poussé" || ko "$1 $2 : rc $(rrc) posts=$(posts) branche=$(remote_branch) $(grep -E 'REFUS|ERREUR' "$4" | head -1)"
}
# AUCUNE_LIGNEE : une app avec manifeste mais aucune PR -rec (appb, ajoutée par commit direct)
reset_origin; gw checkout -q main; gw reset -q --hard "$MAIN0"; write_man "$W/clients/provisioned/applications/appb.ansible.yml" '' '    rec: { auth: { claim: { value: "appb-rec" } } }'; gw add -A; gw commit -qm "appb direct"; gw push -q origin main
set_ctl "$(ctl_json)"; run_rb "$TMP/b1.out" REQ_APP=appb; b_refus B.1 "manifeste sans PR mergée" AUCUNE_LIGNEE "$TMP/b1.out"
gw reset -q --hard "$MAIN0"; gw push -q -f origin main
# AUCUN_ETAT_PRECEDENT : un seul merge (forge ne connaît que #13)
ONE=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; l=json.load(sys.stdin); print(json.dumps([p for p in l if p["number"]==13]))')
set_ctl "{\"closed\":$ONE,\"open\":[]}"; reset_origin; run_rb "$TMP/b2.out"; b_refus B.2 "un seul état mergé" AUCUN_ETAT_PRECEDENT "$TMP/b2.out"
# BIRTH : le manifeste retiré (commit direct) puis recréé par une PR ⇒ les merges d'avant ne comptent pas
gw rm -q "$MAN"; gw commit -qm "retrait du manifeste jetable"; gw push -q origin main
SHA_R=$(pr_merge 20 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.20"] }' "CERT-R") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add); gw push -q origin main
set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/b3.out"; b_refus B.3 "manifeste recréé : la lignée commence à sa naissance courante (#20 seul)" AUCUN_ETAT_PRECEDENT "$TMP/b3.out"
grep -q "^LIGNEE : #20" "$TMP/b3.out" && ok "B.3b la lignée imprimée ne cite pas #13" || ko "B.3b lignée : $(grep '^LIGNEE' "$TMP/b3.out")"
gw reset -q --hard "$MAIN0"; gw push -q -f origin main; CLOSED="$SAVE_CLOSED"
# FORGE_INCOHERENTE : merge_commit_sha de N-1 hors de la première parenté
BAD=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; l=json.load(sys.stdin)
for p in l:
    if p["number"]==11: p["merge_commit_sha"]="0"*40
print(json.dumps(l))')
set_ctl "{\"closed\":$BAD,\"open\":[]}"; reset_origin; run_rb "$TMP/b4.out"; b_refus B.4 "sha de #11 hors de main" FORGE_INCOHERENTE "$TMP/b4.out"
BADN=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; l=json.load(sys.stdin)
for p in l:
    if p["number"]==13: p["merge_commit_sha"]="1"*40
print(json.dumps(l))')
set_ctl "{\"closed\":$BADN,\"open\":[]}"; reset_origin; run_rb "$TMP/b4b.out"; b_refus B.4b "sha de #13 (N) hors de main" FORGE_INCOHERENTE "$TMP/b4b.out"
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
# REFERENCE_DIVERGENTE : commit direct sur main après N modifiant la ligne rec
gw checkout -q main; app_manifest_merge_env "$W/$MAN" rec '{ auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.99"] }' >/dev/null; gw commit -qam "hors flux"; gw push -q origin main
set_ctl "$(ctl_json)"; run_rb "$TMP/b7.out"; b_refus B.7 "main écrit hors PR" REFERENCE_DIVERGENTE "$TMP/b7.out"
gw reset -q --hard "$MAIN0"; gw push -q -f origin main
# RACINE_DIVERGENTE : racine différente entre #11 et #13 (fixture dédiée : description changée par commit direct entre les deux)
# (construite sur une copie : main → reset à SHA_B, commit direct racine, puis re-merge d'un rec#13' et dev#14')
SAVE_MAIN="$MAIN0"
gw reset -q --hard "$SHA_B"; sed -i.bak 's/fixture A6/fixture A6 bis/' "$W/$MAN" && rm -f "$W/$MAN.bak"; gw commit -qam "racine hors flux"
CL_SAVE="$CLOSED"; CLOSED=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; print(json.dumps([p for p in json.load(sys.stdin) if p["number"]<=11]))')
SHA_D2=$(pr_merge 13 rec "$LINE_D" "CERT-D") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add); gw push -q -f origin main
set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/b8.out"; b_refus B.8 "racine différente entre N-1 et N" RACINE_DIVERGENTE "$TMP/b8.out"
gw reset -q --hard "$SAVE_MAIN"; gw push -q -f origin main; CLOSED="$CL_SAVE"
# ETAT_IDENTIQUE par quoting : #13' porte la même ligne que #11 aux guillemets près (digest égal, octets différents)
CLOSED=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; print(json.dumps([p for p in json.load(sys.stdin) if p["number"]<=11]))')
SHA_Q=$(pr_merge 13 rec "$(printf '%s' "$LINE_B" | sed "s/\"appa-rec\"/'appa-rec'/")" "CERT-B") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add); gw push -q -f origin main
set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/b9.out"; b_refus B.9 "N == N-1 au digest près (quoting)" ETAT_IDENTIQUE "$TMP/b9.out"
gw reset -q --hard "$SAVE_MAIN"; gw push -q -f origin main; CLOSED="$CL_SAVE"
open_pr(){ # <login> <repo> [head sha] → json d'une PR ouverte sur la branche
  printf '[{"number":77,"state":"open","merged":false,"head":{"ref":"provision/appa-rec","sha":"%s","repo":{"full_name":"%s"}},"base":{"ref":"main"},"user":{"login":"%s"},"body":"<!-- app-rollback: de %s vers %s -->"}]' "${3:-deadbeef}" "$2" "$1" "$SHA_D" "$SHA_B"
}
# PR_EN_COURS : PR ouverte par alice (marqueur collé) ; par ci mais contenu différent ; EXIST : ci + contenu identique
set_ctl "$(ctl_json "$(open_pr alice ci/stoa-labs)")"; reset_origin; run_rb "$TMP/b10.out"; b_refus B.10 "PR ouverte par alice, marqueur collé" PR_EN_COURS "$TMP/b10.out"
# une branche distante portant un AUTRE contenu (rec#13 = main) ouverte par ci
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
# BRANCHE_NON_MERGEE : tête distante non ancêtre de main, sans PR
gw checkout -q -B provision/appa-rec main; printf 'x\n' > "$W/HAND"; gw add -A; gw commit -qm "poussé à la main"; gw push -q -f origin provision/appa-rec; gw checkout -q main
set_ctl "$(ctl_json)"; run_rb "$TMP/b14.out"; refus BRANCHE_NON_MERGEE "$TMP/b14.out" && [ "$(posts)" = 0 ] && ok "B.14 tête distante non mergée sans PR ⇒ BRANCHE_NON_MERGEE" || ko "B.14 rc $(rrc) : $(grep REFUS "$TMP/b14.out")"
gw branch -q -D provision/appa-rec; reset_origin
# tête distante MERGÉE (ancêtre de main) ⇒ réécrite en bail
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
run_rb "$TMP/b25.out" REQ_ENV=int REQ_CHANGE_REF=CHG-1; b_refus B.25 "palier non déclaré (int)" PALIER_ABSENT "$TMP/b25.out"
run_rb "$TMP/b26.out" REQ_ENV=prod STOA_ENV_CHAIN_FILE="$CHAIN"; refus GATE_REFS_REQUIRED "$TMP/b26.out" && ! grep -q '^ETAPE clone' "$TMP/b26.out" && ok "B.26 terminus sans change_ref ⇒ GATE_REFS_REQUIRED avant le clone" || ko "B.26 : $(grep -E 'REFUS|ETAPE' "$TMP/b26.out" | tr '\n' ' ')"
run_rb "$TMP/b27.out" REQ_ENV=prod REQ_CHANGE_REF=CHG-1; refus PALIER_ABSENT "$TMP/b27.out" && grep -q '^ETAPE clone' "$TMP/b27.out" && ok "B.27 terminus avec change_ref ⇒ PALIER_ABSENT après le clone (ordre porte < clone < manifeste)" || ko "B.27 : $(grep -E 'REFUS' "$TMP/b27.out")"
# LIGNEE_TRONQUEE : une origine elle-même shallow
SH="$TMP/shallow"; git clone -q --bare --depth 1 "file://$ORIGIN" "$SH" 2>/dev/null || { echo "!! fixture : origine shallow" >&2; exit 2; }
set_ctl "$(ctl_json)"; run_rb "$TMP/b28.out" GIT_CLONE_URL="file://$SH"; b_refus B.28 "origine shallow" LIGNEE_TRONQUEE "$TMP/b28.out"
# cert absent à N-1, présent à N ⇒ git rm dans la PR
CL_SAVE="$CLOSED"; CLOSED=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; print(json.dumps([p for p in json.load(sys.stdin) if p["number"]<=12]))')
gw reset -q --hard "$SHA_C"; git -C "$W" rm -q "$CERT"; gw commit -qm "sans cert"; SHA_NC=$(pr_merge 13 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.5"] }' "-") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add); SHA_WC=$(pr_merge 14 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.6"] }' "CERT-W") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add); gw push -q -f origin main
set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/b29.out"; RB=$(remote_branch)
[ "$(rrc)" = 0 ] && [ "$(git -C "$ORIGIN" diff --name-status "$SHA_WC" "$RB" | sort | tr '\t' ' ' | tr '\n' ' ')" = "D $CERT M $MAN " ] && ok "B.29 cert absent à N-1 et présent à N ⇒ supprimé dans la PR (diff D cert, M manifeste)" || ko "B.29 rc $(rrc) diff : $(git -C "$ORIGIN" diff --name-status "$SHA_WC" "$RB" 2>/dev/null | tr '\n' ' ')"
grep -q 'cert : supprimé' "$STUB_POSTED" && ok "B.29b le corps de PR le dit" || ko "B.29b corps"
gw reset -q --hard "$MAIN0"; gw push -q -f origin main; CLOSED="$CL_SAVE"
# REPLI_DU_REPLI : N (#13') est lui-même un repli (son commit de branche porte Repli-Vers:)
CLOSED=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; print(json.dumps([p for p in json.load(sys.stdin) if p["number"]<=12]))')
gw reset -q --hard "$SHA_C"; gw checkout -q -B provision/appa-rec main; app_manifest_merge_env "$W/$MAN" rec "$(printf '%s' "$LINE_D" | sed -E 's/^    rec: //')" >/dev/null; gw add -A
gw commit -qm "$(printf 'provision(rec): repli de appa vers #10\n\nRepli-De: %s (PR #11)\nRepli-Vers: %s (PR #10)\n' "$SHA_B" "$SHA_A")"; gw checkout -q main; gw merge -q --no-ff -m "Merge pull request 'provision(rec): appa — repli' (#13) from provision/appa-rec into main" provision/appa-rec
SHA_RR=$(gw rev-parse HEAD); CLOSED=$(printf '%s' "$CLOSED" | N=13 SHA="$SHA_RR" python3 -c 'import json,os,sys; l=json.load(sys.stdin); l.append({"number":13,"merged":True,"state":"closed","merge_commit_sha":os.environ["SHA"],"head":{"ref":"provision/appa-rec","sha":"x","repo":{"full_name":"ci/stoa-labs"}},"base":{"ref":"main"},"user":{"login":"ci"}}); print(json.dumps(l))')
gw push -q -f origin main; set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/b30.out"
[ "$(rrc)" = 0 ] && grep -q '^REPLI_DU_REPLI : restaure #11' "$TMP/b30.out" && grep -q 'REPLI_DU_REPLI' "$STUB_POSTED" && grep -q '^REPLI_DU_REPLI=1' "$TMP/rb.env" && ok "B.30 N est un repli ⇒ REPLI_DU_REPLI imprimé, dans le corps, dans ROLLBACK_OUT" || ko "B.30 rc $(rrc) : $(grep -E 'REPLI_DU|REFUS' "$TMP/b30.out")"
gw reset -q --hard "$MAIN0"; gw push -q -f origin main; CLOSED="$CL_SAVE"
# LIGNEE_AMBIGUE : une PR mergée de fork avec ce head.ref
FK=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; l=json.load(sys.stdin)
for p in l:
    if p["number"]==11: p["head"]["repo"]["full_name"]="mallory/stoa-labs"
print(json.dumps(l))')
set_ctl "{\"closed\":$FK,\"open\":[]}"; reset_origin; run_rb "$TMP/b31.out"; b_refus B.31 "PR mergée depuis un fork dans la lignée" LIGNEE_AMBIGUE "$TMP/b31.out"
# LIGNE_AMBIGUE : N-1 porte deux change_ref (écrit à la main, la lib ne l'aurait jamais produit)
CLOSED=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; print(json.dumps([p for p in json.load(sys.stdin) if p["number"]<=10]))')
gw reset -q --hard "$SHA_A"; gw checkout -q -B provision/appa-rec main; python3 - "$W/$MAN" <<'PY'
import sys,re; p=sys.argv[1]; t=open(p).read(); t=re.sub(r'^(    rec: \{.*)change_ref: "CHG-0001"', r'\1change_ref: "CHG-0001", change_ref: "CHG-0002"', t, flags=re.M); open(p,"w").write(t)
PY
gw commit -qam "double clé"; gw checkout -q main; gw merge -q --no-ff -m "Merge pull request 'provision(rec): appa' (#11) from provision/appa-rec into main" provision/appa-rec; SHA_DK=$(gw rev-parse HEAD)
CLOSED=$(printf '%s' "$CLOSED" | SHA="$SHA_DK" python3 -c 'import json,os,sys; l=json.load(sys.stdin); l.append({"number":11,"merged":True,"state":"closed","merge_commit_sha":os.environ["SHA"],"head":{"ref":"provision/appa-rec","sha":"x","repo":{"full_name":"ci/stoa-labs"}},"base":{"ref":"main"},"user":{"login":"ci"}}); print(json.dumps(l))')
SHA_DK2=$(pr_merge 12 rec "$LINE_D" "CERT-D") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add); gw push -q -f origin main; set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/b32.out" STOA_ENV_CHAIN_FILE="$CHAIN_REC_GATED" REQ_CHANGE_REF=CHG-0009; b_refus B.32 "N-1 avec deux change_ref" LIGNE_AMBIGUE "$TMP/b32.out"
gw reset -q --hard "$MAIN0"; gw push -q -f origin main; CLOSED="$CL_SAVE"; gw branch -q -D provision/appa-rec 2>/dev/null || true

echo "══ C. mutations : la suite mord ══"
mutate(){ # <nom> <python transformant stdin→stdout> → chemin du mutant
  local m="$REPO/scripts/.a6-mut-$1.sh"; python3 -c "$2" < "$SCRIPT" > "$m"; chmod 700 "$m"   # à côté du script : il fait cd "$(dirname "$0")/.." et source ses libs
  cmp -s "$m" "$SCRIPT" && { ko "C.$1 mutant identique à l'original (mutation sans effet)"; return 1; }; printf '%s' "$m"
}
run_mut(){ SCRIPT="$1" run_rb "$2" "${@:3}"; }   # NB bash 3.2 : "${@:3}" est valide en bash (pas en sh)
# M1 : filtre head.ref par PRÉFIXE ⇒ dev#14 devient N ⇒ N-1 = rec#13 = main ⇒ ETAT_IDENTIQUE ⇒ A rougit
M1=$(mutate M1 'import sys; s=sys.stdin.read(); assert "head_ref != BRANCH" in s; print(s.replace("head_ref != BRANCH", "not head_ref.startswith(BRANCH.rsplit(\"-\",1)[0] + \"-\")"), end="")') && {
  set_ctl "$(ctl_json)"; reset_origin; run_mut "$M1" "$TMP/m1.out"
  [ "$(rrc)" != 0 ] && grep -q 'ETAT_IDENTIQUE\|RESTAURATION_INFIDELE' "$TMP/m1.out" && ok "C.M1 clé de lignée par préfixe ⇒ le nominal rougit (dev#14 pris pour N)" || ko "C.M1 le mutant passe : rc $(rrc)"; }
# M2 : la porte (#3) déplacée APRÈS la lignée ⇒ A'.1 journalise un GET avant GATE_REFS_REQUIRED
M2=$(mutate M2 'import sys; s=sys.stdin.read(); a=s.index("etape porte"); b=s.index("etape clone"); c=s.index("etape coherence"); print(s[:a]+s[b:c]+s[a:b]+s[c:], end="")') && {
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
  gw rm -q "$MAN"; gw commit -qm "retrait"; gw push -q origin main; SHA_R2=$(pr_merge 20 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.20"] }' "CERT-R") || { echo "!! fixture : pr_merge" >&2; exit 2; }; CLOSED=$(closed_add); gw push -q origin main
  set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
  run_mut "$M5" "$TMP/m5.out"; [ "$(rrc)" = 0 ] && [ "$(posts)" = 1 ] && ok "C.M5 sans la borne BIRTH, une PR vers la vie antérieure (#13) s'ouvre — B.3 l'attrape" || ko "C.M5 rc $(rrc) posts=$(posts) : $(grep -E 'REFUS|LIGNEE' "$TMP/m5.out" | head -2 | tr '\n' ' ')"
  gw reset -q --hard "$MAIN0"; gw push -q -f origin main; CLOSED="$SAVE_CLOSED"; }

echo "══ B'. la garde symétrique : une demande ne réécrit pas une PR de repli ouverte ══"
set_ctl "$(ctl_json)"; reset_origin; run_rb "$TMP/bp0.out"; RB=$(remote_branch)   # une PR de repli « ouverte » : sa branche existe sur le nu
run_req(){ ( cd "$REPO" && env -i PATH="$SHIM:$PATH" HOME="$HOME" GITEA_TOKEN="$STUB_TOKEN" GIT_HOST="$GH" GIT_REPO=ci/stoa-labs GIT_CLONE_URL="file://$ORIGIN" GIT_PUSH_URL="file://$ORIGIN" \
   MANIFEST_DIR=clients/provisioned/applications STOA_ENV_CHAIN_FILE="$CHAIN" PROVISION_PLAN_INLINE=false REQ_APP=appa REQ_ENV=rec REQ_API=demo-selfservice REQ_CLIENT_ID=appa-rec REQ_CALLER=oig-provisioner REQ_IP_ALLOWLIST=10.42.0.44 bash scripts/provision-request.sh ) > "$1" 2>&1; echo $? > "$TMP/req.rc"; }
set_ctl "$(ctl_json "$(open_pr ci ci/stoa-labs "$RB")")"; run_req "$TMP/bp1.out"
[ "$(cat "$TMP/req.rc")" = 2 ] && grep -q 'REFUS: REPLI_EN_COURS' "$TMP/bp1.out" && [ "$(remote_branch)" = "$RB" ] && [ "$(posts)" = 0 ] && ok "B'.1 demande pendant un repli ouvert ⇒ REPLI_EN_COURS, branche intacte" || ko "B'.1 rc $(cat "$TMP/req.rc") branche=$(remote_branch) : $(grep -E 'REFUS|ERREUR' "$TMP/bp1.out" | head -1)"
git -C "$ORIGIN" update-ref refs/heads/provision/appa-rec "$SHA_D"; set_ctl "$(ctl_json "$(open_pr ci ci/stoa-labs "$SHA_D")")"; run_req "$TMP/bp2.out"
[ "$(cat "$TMP/req.rc")" = 0 ] && grep -q 'PR déjà ouverte: #77' "$TMP/bp2.out" && grep -q -- '--force-with-lease=refs/heads/provision/appa-rec:' "$SHIM_LOG" && ok "B'.2 PR ouverte sans trailer ⇒ EXIST comme avant, push en bail" || ko "B'.2 rc $(cat "$TMP/req.rc") : $(grep -E 'PR |EXIST|push|REFUS' "$TMP/bp2.out" | head -3 | tr '\n' ' ') / bail=$(grep -c -- '--force-with-lease' "$SHIM_LOG") / $(grep -E 'push' "$SHIM_LOG" | head -1 | cut -c1-120)"

echo "══ B''. REPLI_PERIME au réconciliateur : un repli ne restaure que l'état d'avant le merge ══"
RECONCILE="$REPO/scripts/provision-apply-reconcile.sh"
reset_origin; W2="$TMP/w2"; rm -rf "$W2"; git clone -q "file://$ORIGIN" "$W2"
gw2(){ git -C "$W2" -c user.name=t -c user.email=t@t "$@"; }
# build_repli <trailer 0|1> [commit direct sur main : "" | "rec" | "cert"] → MERGE_SHA (main de W2 et d'origin avancés)
build_repli(){
  local trailer="$1" direct="${2:-}" msg
  gw2 checkout -q main; gw2 reset -q --hard "$MAIN0"
  case "$direct" in
    rec) app_manifest_merge_env "$W2/$MAN" rec '{ auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.77"] }' >/dev/null; gw2 commit -qam "hors flux rec" ;;
    cert) printf 'CERT-X\n' > "$W2/$CERT"; gw2 commit -qam "hors flux cert" ;;
  esac
  gw2 checkout -q -B provision/appa-rec main
  app_manifest_merge_env "$W2/$MAN" rec "$(printf '%s' "$LINE_B" | sed -E 's/^    rec: //')" >/dev/null; printf 'CERT-B\n' > "$W2/$CERT"; gw2 add -A
  if [ "$trailer" = 1 ]; then msg="$(printf 'provision(rec): repli de appa vers #11\n\nRepli-De: %s (PR #13)\nRepli-Vers: %s (PR #11)\n' "$SHA_D" "$SHA_B")"; else msg="provision(rec): application appa (demande t)"; fi
  gw2 commit -qm "$msg"; gw2 checkout -q main
  gw2 merge -q --no-ff -m "Merge pull request 'provision(rec): appa' (#42) from provision/appa-rec into main" provision/appa-rec
  gw2 push -q -f origin main; gw2 rev-parse HEAD
}
run_rec(){ # <MERGE_SHA> <sortie>
  local ms="$1"
  printf '{"closed":[{"number":42,"merged":true,"state":"closed","merge_commit_sha":"%s","merged_by":{"login":"alice"},"user":{"login":"ci"},"head":{"ref":"provision/appa-rec","sha":"x","repo":{"full_name":"ci/stoa-labs"}},"base":{"ref":"main"}}],"open":[]}' "$ms" > "$STUB_CTL"; : > "$STUB_LOG"
  ( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" GITEA_TOKEN="$STUB_TOKEN" GIT_HOST="$GH" GIT_REPO=ci/stoa-labs GIT_WORKTREE="$W2" \
      PR_BRANCH=provision/appa-rec PR_NUMBER=42 MERGE_SHA="$ms" RECONCILE_OUT="$TMP/rec.env" bash "$RECONCILE" ) > "$2" 2>&1; echo $? > "$TMP/rec.rc"
}
MS=$(build_repli 1); run_rec "$MS" "$TMP/bpp1.out"
[ "$(cat "$TMP/rec.rc")" = 0 ] && grep -q '^REPLI_OK' "$TMP/bpp1.out" && grep -q '^RECONCILE_OK' "$TMP/bpp1.out" && ok "B''.1 PR de repli, main immobile ⇒ REPLI_OK puis RECONCILE_OK" || ko "B''.1 rc $(cat "$TMP/rec.rc") : $(grep -E 'REFUS|REPLI|RECONCILE' "$TMP/bpp1.out" | head -2 | tr '\n' ' ')"
MS=$(build_repli 1 rec); run_rec "$MS" "$TMP/bpp2.out"
[ "$(cat "$TMP/rec.rc")" != 0 ] && grep -q 'REFUS: REPLI_PERIME' "$TMP/bpp2.out" && grep -q 'digest' "$TMP/bpp2.out" && ok "B''.2 main a bougé (ligne rec) entre la demande et le merge ⇒ REPLI_PERIME" || ko "B''.2 rc $(cat "$TMP/rec.rc") : $(grep -E 'REFUS|REPLI|RECONCILE' "$TMP/bpp2.out" | head -2 | tr '\n' ' ')"
MS=$(build_repli 1 cert); run_rec "$MS" "$TMP/bpp3.out"
[ "$(cat "$TMP/rec.rc")" != 0 ] && grep -q 'REFUS: REPLI_PERIME' "$TMP/bpp3.out" && grep -q 'certificat' "$TMP/bpp3.out" && ok "B''.3 seul le cert a bougé ⇒ REPLI_PERIME (blob comparé)" || ko "B''.3 rc $(cat "$TMP/rec.rc") : $(grep -E 'REFUS|REPLI|RECONCILE' "$TMP/bpp3.out" | head -2 | tr '\n' ' ')"
MS=$(build_repli 0 rec); run_rec "$MS" "$TMP/bpp4.out"
[ "$(cat "$TMP/rec.rc")" = 0 ] && ! grep -q 'REPLI' "$TMP/bpp4.out" && grep -q '^RECONCILE_OK' "$TMP/bpp4.out" && ok "B''.4 sans trailer le bloc est inerte (verdict d'avant, main ayant bougé ou non)" || ko "B''.4 rc $(cat "$TMP/rec.rc") : $(grep -E 'REFUS|REPLI|RECONCILE' "$TMP/bpp4.out" | head -2 | tr '\n' ' ')"
N4B=$(grep -c '^# ── 4bis\. A6' "$RECONCILE"); grep -q 'if \[ -n "\$REPLI_DE" \]; then' "$RECONCILE" && [ "$N4B" = 1 ] \
  && [ "$(grep -n '^# ── 4bis\. A6' "$RECONCILE" | cut -d: -f1)" -gt "$(grep -n 'fail PALIER_SUPPLANTE' "$RECONCILE" | tail -1 | cut -d: -f1)" ] \
  && [ "$(grep -n '^# ── 4bis\. A6' "$RECONCILE" | cut -d: -f1)" -lt "$(grep -n '^# ── 5\. SORTIE' "$RECONCILE" | cut -d: -f1)" ] \
  && ok "B''.5 le bloc 4bis est UN bloc conditionnel, entre PALIER_SUPPLANTE et la sortie" || ko "B''.5 structure du bloc 4bis"
reset_origin

EXPECTED_CHECKS=69
TOTAL=$((PASS+FAIL))
if [ "$EXPECTED_CHECKS" -gt 0 ] && [ "$TOTAL" -ne "$EXPECTED_CHECKS" ]; then
  printf '❌ %d contrôles exécutés, %d attendus — une section a été sautée ou ajoutée sans mettre EXPECTED_CHECKS à jour\n' "$TOTAL" "$EXPECTED_CHECKS"; FAIL=$((FAIL+1))
fi
echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
