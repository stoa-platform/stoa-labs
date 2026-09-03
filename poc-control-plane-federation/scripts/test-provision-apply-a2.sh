#!/usr/bin/env bash
# test-provision-apply-a2.sh — preuve X/X HORS LIGNE du jalon A2 (GOAL
# cd-applications) : la référence de déploiement d'une application est le SHA
# mergé, jamais le dernier `main`.
#
#   A. la lib : `app_manifest_digest_env` (digest canonique du bloc per_env.<env>)
#   B. la réconciliation Gitea de provision-apply (scripts/provision-apply-reconcile.sh)
#      contre un STUB Gitea local : le payload ne fait pas foi, refus nommés,
#      aucun appel réseau avant la forme, commentaire de refus posé
#   C. le rapport de PR (provision-apply-comment.sh) : SHA + digest + refus,
#      et corps INCHANGÉ pour les appelants d'avant A2
#   D. MUTATIONS : retirer une comparaison de la réconciliation ⇒ l'épreuve
#      correspondante rougit (motif G3 « toute assertion se règle par mutation »)
#
# Ni Jenkins, ni Gitea, ni gateway : tout est local. La preuve par BUILDS réels
# (porte + contre-épreuve du GOAL) vit dans test-provision-apply-a2-live.sh.
#
#   ./scripts/test-provision-apply-a2.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
LIB="$REPO/scripts/lib/app-manifest.sh"
RECONCILE="$REPO/scripts/provision-apply-reconcile.sh"
COMMENT="$REPO/scripts/provision-apply-comment.sh"
TMP="$(mktemp -d /tmp/pa-a2.XXXXXX)"
STUB_PID=""
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
cleanup(){ if [ -n "$STUB_PID" ]; then { kill "$STUB_PID"; wait "$STUB_PID"; } 2>/dev/null; fi; rm -rf "$TMP"; }
trap cleanup EXIT

# Total ATTENDU, écrit en dur (motif test-team-apply-wiring.sh) : une section
# sautée en silence ferait baisser PASS+FAIL sans jamais rougir — ce nombre, si.
EXPECTED_CHECKS=148

command -v python3 >/dev/null || { echo "python3 absent"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "PyYAML absent"; exit 2; }

# ── fixtures : manifestes forme A1 ──────────────────────────────────────────
write_idp(){ # $1=fichier $2=app $3=lignes per_env (indentées 4) — "" = bloc vide
  cat > "$1" <<YAML
---
# $2.ansible.yml — GÉNÉRÉ par une demande de provisioning (maillon 1).
apim_ss_app:
  name: "$2"
  api: "accounts-read"
  api_version: "1.0.0"
  description: "Provisioned via oig-provisioner (idp)"
  contact_emails: []
  enforce: []
  auth:
    mode: "idp"
    server_alias: "KeycloakStoaLab"
    audience: "accounts-read"
    claim: { name: "azp" }
  per_env:
${3}
YAML
}
write_internal(){ # $1=fichier $2=app $3=lignes per_env
  cat > "$1" <<YAML
---
apim_ss_app:
  name: "$2"
  api: "accounts-read"
  api_version: "1.0.0"
  description: "Provisioned via cli2-provisioner (internal)"
  contact_emails: []
  enforce: []
  auth:
    mode: "internal"
    audience: "accounts-read"
  per_env:
${3}
YAML
}

echo "═══ Section A — la lib : app_manifest_digest_env (HORS LIGNE) ═══"
# shellcheck source=scripts/lib/app-manifest.sh
. "$LIB" || { echo "lib introuvable"; exit 2; }
type app_manifest_digest_env >/dev/null 2>&1 \
  && ok "A.0 la fonction app_manifest_digest_env existe" \
  || ko "A.0 app_manifest_digest_env absente de la lib"

write_idp "$TMP/a1.yml" appa '    dev: { auth: { claim: { value: "appa-dev" } }, ip_allowlist: ["10.0.0.1"] }
    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.1"] }'
D_REC=$(app_manifest_digest_env "$TMP/a1.yml" rec 2>"$TMP/a1.err"); RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$D_REC" | grep -qE '^sha256:[0-9a-f]{64}$'; then
  ok "A.1 digest de per_env.rec = sha256:<64 hex> (rc 0)"
else
  ko "A.1 digest rec : rc=$RC out='$D_REC' err=$(cat "$TMP/a1.err")"
fi
D_DEV=$(app_manifest_digest_env "$TMP/a1.yml" dev 2>/dev/null)
[ -n "$D_DEV" ] && [ "$D_DEV" != "$D_REC" ] \
  && ok "A.2 deux paliers ⇒ deux digests distincts (dev ≠ rec)" \
  || ko "A.2 digest dev == digest rec ($D_DEV)"

# Contrôle POSITIF de l'algorithme documenté (D4) : JSON canonique du mapping
# relu par BaseLoader, sort_keys, séparateurs compacts, UTF-8 — recalculé ICI
# sans la lib. Sans ce contrôle, un digest « stable » pourrait être n'importe
# quoi de stable (le nom du fichier, une constante).
EXPECT=$(python3 - "$TMP/a1.yml" <<'PY'
import sys, json, hashlib, yaml
d = yaml.load(open(sys.argv[1], encoding="utf-8"), Loader=yaml.BaseLoader)
app = d["apim_ss_app"]
def combine(b, o):
    r = dict(b)
    for k, v in o.items():
        r[k] = combine(r[k], v) if isinstance(v, dict) and isinstance(r.get(k), dict) else v
    return r
eff = combine({k: v for k, v in app.items() if k != "per_env"}, app["per_env"]["rec"])
print("sha256:" + hashlib.sha256(json.dumps(eff, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")).hexdigest())
PY
)
[ "$D_REC" = "$EXPECT" ] \
  && ok "A.3 le digest EST le SHA-256 du JSON canonique du manifeste EFFECTIF (racine ⊕ per_env.rec, recalculé indépendamment)" \
  || ko "A.3 algorithme divergent : lib=$D_REC attendu=$EXPECT"
# La fusion est celle du rôle (combine recursive=True) : la claim du palier
# REMPLACE au niveau de la feuille et s'ajoute au `name` de la racine.
EXPECT_CLAIM=$(python3 - "$TMP/a1.yml" <<'PY'
import sys, json, hashlib, yaml
d = yaml.load(open(sys.argv[1], encoding="utf-8"), Loader=yaml.BaseLoader)
app = d["apim_ss_app"]
eff = {k: v for k, v in app.items() if k != "per_env"}
eff = dict(eff); eff["auth"] = dict(eff["auth"]); eff["auth"]["claim"] = {"name": "azp", "value": "appa-rec"}; eff["ip_allowlist"] = ["10.42.0.1"]
print("sha256:" + hashlib.sha256(json.dumps(eff, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")).hexdigest())
PY
)
[ "$D_REC" = "$EXPECT_CLAIM" ] \
  && ok "A.3b la fusion est récursive : auth.claim = { name: azp (racine), value: appa-rec (palier) }" \
  || ko "A.3b fusion non récursive (claim.name perdu ou palier non appliqué)"

# Stabilité au re-sérialisage : ordre des clés, guillemets, espaces différents,
# même identité de palier ⇒ même digest (le digest répond « qu'est-ce qui tourne »).
write_idp "$TMP/a4.yml" appa '    dev: { auth: { claim: { value: "appa-dev" } }, ip_allowlist: ["10.0.0.1"] }
    rec: {ip_allowlist: [ '"'"'10.42.0.1'"'"' ],  auth: {claim: {value: '"'"'appa-rec'"'"'}}}'
D_REC4=$(app_manifest_digest_env "$TMP/a4.yml" rec 2>/dev/null)
[ -n "$D_REC4" ] && [ "$D_REC4" = "$D_REC" ] \
  && ok "A.4 stable au re-sérialisage (ordre des clés, guillemets, espaces) — même digest" \
  || ko "A.4 le digest change avec la forme et pas le fond : $D_REC4 ≠ $D_REC"

# Sensibilité : une valeur change ⇒ le digest change (c'est la porte A2 :
# HEAD porte 10.42.0.2, le SHA mergé 10.42.0.1 — deux digests).
write_idp "$TMP/a5.yml" appa '    dev: { auth: { claim: { value: "appa-dev" } }, ip_allowlist: ["10.0.0.1"] }
    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.2"] }'
D_REC5=$(app_manifest_digest_env "$TMP/a5.yml" rec 2>/dev/null)
[ -n "$D_REC5" ] && [ "$D_REC5" != "$D_REC" ] \
  && ok "A.5 une IP change (10.42.0.1 → 10.42.0.2) ⇒ digest différent" \
  || ko "A.5 digest identique malgré une valeur changée"
# …et un changement HORS du palier ne le change pas (la racine est couverte par le SHA, pas par le digest — D4).
write_idp "$TMP/a5b.yml" appa '    dev: { auth: { claim: { value: "appa-dev" } }, ip_allowlist: ["10.0.0.9"] }
    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.1"] }'
D_REC5B=$(app_manifest_digest_env "$TMP/a5b.yml" rec 2>/dev/null)
[ -n "$D_REC5B" ] && [ "$D_REC5B" = "$D_REC" ] \
  && ok "A.5b un changement dans per_env.dev ne change pas le digest de rec (un autre palier n'y entre pas)" \
  || ko "A.5b le digest de rec dépend d'un autre palier"
# …mais un changement de la RACINE (ce qui tourne aussi) le change : `enforce`,
# `description`, `audience` ne sont pas comparés par le contrat A1 — le digest
# les couvre (critique de la spec, 2026-09-02).
sed 's/  enforce: \[\]/  enforce: ["rate-limit"]/' "$TMP/a1.yml" > "$TMP/a5c.yml"
D_REC5C=$(app_manifest_digest_env "$TMP/a5c.yml" rec 2>/dev/null)
[ -n "$D_REC5C" ] && [ "$D_REC5C" != "$D_REC" ] \
  && ok "A.5c un changement de la racine (enforce) change le digest de rec (le manifeste EFFECTIF est couvert)" \
  || ko "A.5c le digest ignore la racine : $D_REC5C"

# Refus nommés.
OUT=$(app_manifest_digest_env "$TMP/a1.yml" int 2>&1); RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'PALIER_ABSENT' \
  && ok "A.6 palier non déclaré (int) ⇒ rc 2 + PALIER_ABSENT" \
  || ko "A.6 palier absent : rc=$RC — $OUT"
printf '%s' "$OUT" | grep -q 'dev, rec' \
  && ok "A.6b le refus nomme les paliers déclarés (dev, rec)" \
  || ko "A.6b le refus ne dit pas quels paliers existent : $OUT"
write_idp "$TMP/a7.yml" appa ''
OUT=$(app_manifest_digest_env "$TMP/a7.yml" rec 2>&1); RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'PALIER_ABSENT' \
  && ok "A.7 per_env vide ⇒ PALIER_ABSENT" \
  || ko "A.7 per_env vide : rc=$RC — $OUT"
OUT=$(app_manifest_digest_env "$TMP/a1.yml" 'rec;rm' 2>&1); RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'PALIER_INVALIDE' \
  && ok "A.8 clé de palier hors classe ⇒ PALIER_INVALIDE (avant toute lecture)" \
  || ko "A.8 palier hors classe : rc=$RC — $OUT"
OUT=$(app_manifest_digest_env "$TMP/absent.yml" rec 2>&1); RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'MANIFESTE_INVALIDE' \
  && ok "A.9 fichier absent ⇒ MANIFESTE_INVALIDE" \
  || ko "A.9 fichier absent : rc=$RC — $OUT"
# Forme d'avant A1 : la lecture refuse déjà (MANIFESTE_LEGACY) — le digest ne
# doit pas la contourner (il passerait par un chemin de lecture différent).
cat > "$TMP/a10.yml" <<'YAML'
---
apim_ss_app:
  name: "old"
  api: "accounts-read"
  api_version: "1.0.0"
  auth:
    mode: "idp"
    audience: "accounts-read"
    claim: { name: "azp", value: "old-dev" }
  per_env:
    dev: { ip_allowlist: ["10.0.0.1"] }
YAML
OUT=$(app_manifest_digest_env "$TMP/a10.yml" dev 2>&1); RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'MANIFESTE_LEGACY' \
  && ok "A.10 manifeste d'avant A1 ⇒ MANIFESTE_LEGACY (même lecture que le reste de la lib)" \
  || ko "A.10 legacy : rc=$RC — $OUT"
write_internal "$TMP/a11.yml" appi '    dev: { auth: { vault_sub: "deploy/banking-demo/apps/appi/dev/oauth-client" } }
    rec: { auth: { vault_sub: "deploy/banking-demo/apps/appi/rec/oauth-client" }, ip_allowlist: ["10.42.0.1"] }'
D_I=$(app_manifest_digest_env "$TMP/a11.yml" rec 2>"$TMP/a11.err"); RC=$?
[ "$RC" -eq 0 ] && printf '%s' "$D_I" | grep -qE '^sha256:[0-9a-f]{64}$' \
  && ok "A.11 mode internal : digest rendu (rc 0)" \
  || ko "A.11 internal : rc=$RC err=$(cat "$TMP/a11.err")"
# Le digest ne doit rien écrire sur stdout d'autre que lui-même (l'appelant le
# capture dans une variable, puis dans un fichier lu par Jenkins).
[ "$(printf '%s' "$D_REC" | wc -l | tr -d ' ')" = 0 ] && [ "${#D_REC}" = 71 ] \
  && ok "A.12 sortie = exactement une ligne 'sha256:<hex>' (71 caractères), rien d'autre" \
  || ko "A.12 sortie polluée : ${#D_REC} caractères"

echo
echo "═══ Section B — la réconciliation (provision-apply-reconcile.sh) : stub Gitea + dépôt git local ═══"
[ -f "$RECONCILE" ] && bash -n "$RECONCILE" 2>/dev/null \
  && ok "B.0 provision-apply-reconcile.sh présent et parsable" \
  || ko "B.0 provision-apply-reconcile.sh absent ou non parsable"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "$RECONCILE" >"$TMP/sc.log" 2>&1 \
    && ok "B.0b shellcheck propre" || ko "B.0b shellcheck : $(head -5 "$TMP/sc.log")"
else
  ko "B.0b shellcheck absent (brew install shellcheck) — la porte ne se saute pas en silence"
fi

# ── le dépôt git : un `origin` nu + un clone (là où le script fait fetch/show) ──
# Historique de main : c0 (sans manifeste) → c1 (appa : dev+rec v1, LE merge)
# → [c2 : per_env.rec change (supplante)] ou [c2b : per_env.dev change (voisin)]
# Une branche `side` (hors main) porte un commit qui n'est pas un ancêtre.
ORIGIN="$TMP/origin.git"; WORK="$TMP/work"
git init -q --bare "$ORIGIN" && git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$WORK" && git -C "$WORK" checkout -q -b main
gitc(){ git -C "$WORK" -c user.name=t -c user.email=t@t "$@"; }
mkdir -p "$WORK/clients/provisioned/applications" "$WORK/clients/provisioned/certs"
printf 'init\n' > "$WORK/README"; gitc add -A; gitc commit -qm c0; C0=$(gitc rev-parse HEAD)
write_idp "$WORK/clients/provisioned/applications/appa.ansible.yml" appa '    dev: { auth: { claim: { value: "appa-dev" } }, ip_allowlist: ["10.0.0.1"] }
    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.1"] }'
gitc add -A; gitc commit -qm "c1: provision(rec) appa"; C1=$(gitc rev-parse HEAD)
write_idp "$WORK/clients/provisioned/applications/appd.ansible.yml" appd '    dev: { auth: { claim: { value: "appd-dev" } } }'
gitc add -A; gitc commit -qm "c1b: appd dev seul"; C1B=$(gitc rev-parse HEAD)
gitc remote add origin "$ORIGIN"; gitc push -q origin main
gitc checkout -q -b side; printf 'side\n' > "$WORK/SIDE"; gitc add -A; gitc commit -qm side; CSIDE=$(gitc rev-parse HEAD); gitc push -q origin side; gitc checkout -q main
D_C1=$(gitc show "$C1:clients/provisioned/applications/appa.ansible.yml" > "$TMP/c1.yml" && app_manifest_digest_env "$TMP/c1.yml" rec 2>/dev/null)
[ -n "$D_C1" ] && ok "B.0c dépôt de fixture prêt : c0=$(printf '%s' "$C0" | cut -c1-7) c1=$(printf '%s' "$C1" | cut -c1-7) (digest rec $(printf '%s' "$D_C1" | cut -c1-19)…) side=$(printf '%s' "$CSIDE" | cut -c1-7)" || ko "B.0c fixture git illisible"
# main avance sur `origin` sans toucher le clone : le script DOIT fetcher.
advance_main(){ # $1=fichier manifeste appa (contenu complet) $2=message
  local w2="$TMP/w2"; rm -rf "$w2"; git clone -q "$ORIGIN" "$w2"
  cp "$1" "$w2/clients/provisioned/applications/appa.ansible.yml"
  git -C "$w2" -c user.name=t -c user.email=t@t add -A; git -C "$w2" -c user.name=t -c user.email=t@t commit -qm "$2"
  git -C "$w2" push -q origin main; git -C "$w2" rev-parse HEAD
}
reset_main(){ git -C "$WORK" push -q -f origin "$1:main"; }

# ── le stub Gitea : /pulls/<n> et /pulls/<n>/files pilotés par ctl.json, commentaires capturés, journal HTTP ──
STUB_CTL="$TMP/ctl.json"; STUB_LOG="$TMP/http.log"; STUB_COMMENTS="$TMP/comments.json"
: > "$STUB_LOG"; printf '[]' > "$STUB_COMMENTS"
cat > "$TMP/stub.py" <<'PY'
import json, os, re, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
CTL, LOG, STORE = os.environ["STUB_CTL"], os.environ["STUB_LOG"], os.environ["STUB_COMMENTS"]
TOKEN = os.environ["STUB_TOKEN"]
def ctl():
    try: return json.load(open(CTL))
    except Exception: return {}
def load():
    try: return json.load(open(STORE))
    except Exception: return []
def save(c): json.dump(c, open(STORE, "w"))
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)): body = json.dumps(body)
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""
    def _route(self, method):
        path = self.path.split("?")[0]
        with open(LOG, "a") as f: f.write("%s %s\n" % (method, path))
        if self.headers.get("Authorization") != "token " + TOKEN:
            return self._send(401, {"message": "unauthorized"})
        c = ctl()
        m = re.match(r"^/api/v1/repos/[^/]+/[^/]+/pulls/([0-9]+)/files$", path)
        if m and method == "GET":
            files = c.get("files")
            if files is None:
                files = ["poc-control-plane-federation/clients/provisioned/applications/appa.ansible.yml"]
            return self._send(int(c.get("files_code", 200)), [{"filename": f} for f in files])
        m = re.match(r"^/api/v1/repos/[^/]+/[^/]+/pulls/([0-9]+)$", path)
        if m and method == "GET":
            code = int(c.get("code", 200))
            if "raw" in c:
                return self._send(code, c["raw"])
            pr = c.get("pr") or {}
            return self._send(code, {
                "number": int(m.group(1)),
                "merged": pr.get("merged", True),
                "merge_commit_sha": pr.get("merge_commit_sha", ""),
                "head": {"ref": pr.get("head_ref", "")},
                "base": {"ref": pr.get("base_ref", "main")},
                "merged_by": ({"login": pr["merged_by"]} if pr.get("merged_by") is not None else None),
                "user": {"login": pr.get("user", "")},
            })
        if re.match(r"^/api/v1/repos/[^/]+/[^/]+/issues/[0-9]+/comments$", path):
            if method == "GET": return self._send(200, load())
            body = json.loads(self._body().decode("utf-8", "replace") or "{}")
            cs = load(); new = {"id": len(cs) + 1, "body": body.get("body", "")}; cs.append(new); save(cs)
            return self._send(201, new)
        m = re.match(r"^/api/v1/repos/[^/]+/[^/]+/issues/comments/([0-9]+)$", path)
        if m and method == "PATCH":
            body = json.loads(self._body().decode("utf-8", "replace") or "{}")
            cid = int(m.group(1)); cs = load()
            for e in cs:
                if e["id"] == cid: e["body"] = body.get("body", "")
            save(cs); return self._send(200, {"id": cid})
        self._send(404, {"message": "stub: route inconnue " + path})
    def do_GET(self):   self._route("GET")
    def do_POST(self):  self._route("POST")
    def do_PATCH(self): self._route("PATCH")
    def log_message(self, *a): pass
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
print(srv.server_port); sys.stdout.flush()
srv.serve_forever()
PY
STUB_TOKEN="tok-a2"
STUB_CTL="$STUB_CTL" STUB_LOG="$STUB_LOG" STUB_COMMENTS="$STUB_COMMENTS" STUB_TOKEN="$STUB_TOKEN" \
  python3 "$TMP/stub.py" >"$TMP/stub.port" 2>"$TMP/stub.err" &
STUB_PID=$!
for _ in $(seq 1 60); do [ -s "$TMP/stub.port" ] && break; sleep 0.1; done
PORT="$(head -n1 "$TMP/stub.port" 2>/dev/null)"
case "$PORT" in ''|*[!0-9]*) echo "!! stub HTTP non démarré : $(cat "$TMP/stub.err")"; exit 2;; esac
GH="http://127.0.0.1:$PORT"

SHA_AUTRE="2222222222222222222222222222222222222222"
FMAN="poc-control-plane-federation/clients/provisioned/applications/appa.ansible.yml"
FCERT="poc-control-plane-federation/clients/provisioned/certs/appa-rec.crt"
# set_pr <merged:true|false|null> <sha> <head_ref> <base_ref> <merged_by|NULL> <user> [code] [raw]
set_pr(){
  python3 - "$STUB_CTL" "$@" <<'PY'
import json, sys
ctl_path, merged, sha, head, base, mb, user = sys.argv[1:8]
code = int(sys.argv[8]) if len(sys.argv) > 8 else 200
c = {"code": code, "pr": {"merged": {"true": True, "false": False, "null": None}[merged],
     "merge_commit_sha": sha, "head_ref": head, "base_ref": base,
     "merged_by": (None if mb == "NULL" else mb.replace("\\n", "\n")), "user": user}}
if len(sys.argv) > 9: c["raw"] = sys.argv[9]
json.dump(c, open(ctl_path, "w"))
PY
  printf '[]' > "$STUB_COMMENTS"
}
set_files(){ # $@ = fichiers (aucun argument = liste VIDE)
  python3 - "$STUB_CTL" "$@" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c["files"] = sys.argv[2:]; json.dump(c, open(sys.argv[1], "w"))
PY
}
# run_rec <sortie> <log-out> [VAR=val …] — tourne le script sous test ; rc dans $?
run_rec(){
  local out="$1" log="$2"; shift 2
  rm -f "$out" "$TMP/facts"
  env -i PATH="$PATH" HOME="$HOME" GITEA_TOKEN="$STUB_TOKEN" GIT_HOST="$GH" GIT_REPO=ci/stoa-labs GIT_WORKTREE="$WORK" \
    PR_BRANCH="provision/appa-rec" PR_NUMBER=42 MERGE_SHA="$C1" PR_MERGED_BY=oscar PR_REQUESTER=eve \
    RECONCILE_OUT="$out" RECONCILE_FACTS="$TMP/facts" "$@" bash "$RECONCILE" >"$log" 2>&1
}
pulls_calls(){ grep -c ' /api/v1/repos/ci/stoa-labs/pulls/42$' "$STUB_LOG" || true; }
files_calls(){ grep -c ' /api/v1/repos/ci/stoa-labs/pulls/42/files$' "$STUB_LOG" || true; }
comments_n(){ python3 -c "import json;print(len(json.load(open('$STUB_COMMENTS'))))"; }
last_comment(){ python3 -c "import json;c=json.load(open('$STUB_COMMENTS'));print(c[-1]['body'] if c else '')"; }
first_comment(){ python3 -c "import json;c=json.load(open('$STUB_COMMENTS'));print(c[0]['body'] if c else '')"; }
# refus_attendu <n> <libellé> <TAG> <log> <rc> <sortie> <commente:oui|non>
refus_attendu(){
  local n="$1" label="$2" tag="$3" log="$4" rc="$5" out="$6" cm="$7"
  if [ "$rc" -ne 0 ] && grep -q "REFUS: $tag" "$log"; then ok "$n $label — refus $tag (rc=$rc)"; else ko "$n $label — refus $tag attendu, rc=$rc : $(tail -3 "$log" | tr '\n' ' ')"; fi
  [ ! -e "$out" ] && ok "${n}′ aucun fichier de sortie écrit (le pipeline n'a rien à charger)" || ko "${n}′ fichier de sortie écrit malgré le refus"
  case "$cm" in
    oui) if [ "$(comments_n)" = 1 ] && last_comment | grep -q "$tag" && last_comment | grep -q '<!-- provision-apply-refus -->'; then ok "${n}″ refus COMMENTÉ sur la PR sous le marqueur provision-apply-refus (tag $tag)"; else ko "${n}″ commentaire de refus absent, sans le tag ou sous le mauvais marqueur ($(comments_n) commentaire(s))"; fi ;;
    non) [ "$(comments_n)" = 0 ] && ok "${n}″ AUCUN commentaire (la forge n'a pas confirmé une PR provision/*)" || ko "${n}″ un commentaire est parti alors que la forge n'a rien confirmé : $(last_comment | head -2 | tr '\n' ' ')" ;;
  esac
}

echo "-- B.1 nominal : Gitea concorde, main = le merge ⇒ sortie, identités = GITEA, pas le payload --"
set_pr true "$C1" provision/appa-rec main alice ci
: > "$STUB_LOG"
run_rec "$TMP/b1.out" "$TMP/b1.log"; RC=$?
if [ "$RC" -eq 0 ] && [ -s "$TMP/b1.out" ]; then ok "B.1 rc 0 + fichier de sortie écrit"; else ko "B.1 rc=$RC : $(tail -4 "$TMP/b1.log" | tr '\n' ' ')"; fi
grep -qx 'GITEA_MERGED_BY=alice' "$TMP/b1.out" && ok "B.1a GITEA_MERGED_BY=alice (Gitea) alors que le payload disait oscar" || ko "B.1a mergeur : $(grep GITEA_MERGED_BY "$TMP/b1.out")"
grep -qx 'GITEA_REQUESTER=ci' "$TMP/b1.out" && ok "B.1b GITEA_REQUESTER=ci (Gitea) alors que le payload disait eve" || ko "B.1b demandeur : $(grep GITEA_REQUESTER "$TMP/b1.out")"
grep -qx 'APP_NAME=appa' "$TMP/b1.out" && grep -qx 'ENV_NAME=rec' "$TMP/b1.out" && ok "B.1c APP_NAME=appa ENV_NAME=rec" || ko "B.1c app/env : $(grep -E 'APP_NAME|ENV_NAME' "$TMP/b1.out" | tr '\n' ' ')"
grep -qx 'MANIFEST=clients/provisioned/applications/appa.ansible.yml' "$TMP/b1.out" && ok "B.1d MANIFEST=clients/provisioned/applications/appa.ansible.yml" || ko "B.1d manifeste : $(grep MANIFEST "$TMP/b1.out")"
grep -qx "MERGED_DIGEST=$D_C1" "$TMP/b1.out" && ok "B.1e MERGED_DIGEST = digest du manifeste effectif rec au SHA mergé (recalculé ici sur git show)" || ko "B.1e MERGED_DIGEST : $(grep MERGED_DIGEST "$TMP/b1.out")"
[ "$(pulls_calls)" = 1 ] && [ "$(files_calls)" = 1 ] && ok "B.1f exactement UN GET /pulls/42 et UN GET /pulls/42/files (contrôle positif)" || ko "B.1f $(pulls_calls) /pulls, $(files_calls) /files"
[ "$(comments_n)" = 0 ] && ok "B.1g aucun commentaire posé sur un succès (c'est l'apply qui rapportera)" || ko "B.1g $(comments_n) commentaire(s) inattendu(s)"
grep -q 'RECONCILE_OK' "$TMP/b1.log" && ok "B.1h RECONCILE_OK loggué" || ko "B.1h RECONCILE_OK absent du log"
grep -q "$STUB_TOKEN" "$TMP/b1.log" && ko "B.1i le token FUITE dans la sortie" || ok "B.1i aucune fuite du token dans la sortie"
grep -qx 'GITEA_HEAD_REF=provision/appa-rec' "$TMP/facts" && ok "B.1j fichier de FAITS : GITEA_HEAD_REF relu sur la forge" || ko "B.1j faits absents : $(cat "$TMP/facts" 2>/dev/null)"

echo "-- B.2 PR NON mergée côté Gitea (payload prétend merged:true) --"
set_pr false "$C1" provision/appa-rec main NULL ci
run_rec "$TMP/b2.out" "$TMP/b2.log"; RC=$?
refus_attendu "B.2" "PR non mergée" PAYLOAD_PERIME "$TMP/b2.log" "$RC" "$TMP/b2.out" oui
last_comment | grep -q "CE webhook n'a rien appliqué" && ok "B.2‴ le corps dit « CE webhook n'a rien appliqué » (pas « PAS déployée » : un apply antérieur peut exister)" || ko "B.2‴ corps du refus inattendu"
grep -qx 'GITEA_HEAD_REF=provision/appa-rec' "$TMP/facts" && ok "B.2⁗ faits écrits MÊME sur refus (le post{always} saura que c'est une PR provision/*)" || ko "B.2⁗ faits absents sur refus"

echo "-- B.3 SHA divergent (la PR est mergée, mais pas à ce SHA) --"
set_pr true "$SHA_AUTRE" provision/appa-rec main alice ci
run_rec "$TMP/b3.out" "$TMP/b3.log"; RC=$?
refus_attendu "B.3" "merge_commit_sha ≠ MERGE_SHA" PAYLOAD_PERIME "$TMP/b3.log" "$RC" "$TMP/b3.out" oui

echo "-- B.4 head.ref divergent : PR_NUMBER d'une PR ÉTRANGÈRE (onboard/*) ⇒ refus SANS commentaire --"
set_pr true "$C1" onboard/team-dev main alice ci
run_rec "$TMP/b4.out" "$TMP/b4.log"; RC=$?
refus_attendu "B.4" "head.ref ≠ PR_BRANCH (PR étrangère)" PAYLOAD_PERIME "$TMP/b4.log" "$RC" "$TMP/b4.out" non
grep -qx 'GITEA_HEAD_REF=onboard/team-dev' "$TMP/facts" && ok "B.4‴ faits : GITEA_HEAD_REF=onboard/team-dev (le post{always} ne posera pas de statut)" || ko "B.4‴ faits : $(cat "$TMP/facts" 2>/dev/null)"
set_pr true "$C1" provision/autre-rec main alice ci
run_rec "$TMP/b4b.out" "$TMP/b4b.log"; RC=$?
refus_attendu "B.4b" "head.ref ≠ PR_BRANCH (autre demande provision/*)" PAYLOAD_PERIME "$TMP/b4b.log" "$RC" "$TMP/b4b.out" oui

echo "-- B.5 base.ref ≠ main (mergée dans une base jetable : pas une décision sur main) --"
set_pr true "$C1" provision/appa-rec p3a1-base-1 alice ci
run_rec "$TMP/b5.out" "$TMP/b5.log"; RC=$?
refus_attendu "B.5" "base.ref ≠ main" PAYLOAD_PERIME "$TMP/b5.log" "$RC" "$TMP/b5.out" oui

echo "-- B.6 merged_by absent côté Gitea --"
set_pr true "$C1" provision/appa-rec main NULL ci
run_rec "$TMP/b6.out" "$TMP/b6.log"; RC=$?
refus_attendu "B.6" "Gitea ne nomme aucun mergeur" MERGER_UNKNOWN "$TMP/b6.log" "$RC" "$TMP/b6.out" oui

echo "-- B.7 login forgé (saut de ligne dans merged_by) ⇒ refus, sans commentaire --"
set_pr true "$C1" provision/appa-rec main 'alice\nGITEA_REQUESTER=alice' ci
run_rec "$TMP/b7.out" "$TMP/b7.log"; RC=$?
refus_attendu "B.7" "saut de ligne dans une identité" GITEA_RECONCILE_ECHEC "$TMP/b7.log" "$RC" "$TMP/b7.out" non

echo "-- B.8 Gitea en panne / illisible / hors schéma / token refusé ⇒ GITEA_RECONCILE_ECHEC, jamais de commentaire --"
set_pr true "$C1" provision/appa-rec main alice ci 500
run_rec "$TMP/b8a.out" "$TMP/b8a.log"; RC=$?
refus_attendu "B.8a" "HTTP 500" GITEA_RECONCILE_ECHEC "$TMP/b8a.log" "$RC" "$TMP/b8a.out" non
set_pr true "$C1" provision/appa-rec main alice ci 200 '{"merged": tru'
run_rec "$TMP/b8b.out" "$TMP/b8b.log"; RC=$?
refus_attendu "B.8b" "JSON illisible" GITEA_RECONCILE_ECHEC "$TMP/b8b.log" "$RC" "$TMP/b8b.out" non
set_pr true "$C1" provision/appa-rec main alice ci 200 '[]'
run_rec "$TMP/b8c.out" "$TMP/b8c.log"; RC=$?
refus_attendu "B.8c" "JSON 200 mais pas un objet PR" GITEA_RECONCILE_ECHEC "$TMP/b8c.log" "$RC" "$TMP/b8c.out" non
set_pr true "$C1" provision/appa-rec main alice ci 200 '{"message": "token is required"}'
run_rec "$TMP/b8e.out" "$TMP/b8e.log"; RC=$?
refus_attendu "B.8e" "objet 200 sans les champs d'une PR (portail interposé)" GITEA_RECONCILE_ECHEC "$TMP/b8e.log" "$RC" "$TMP/b8e.out" non
grep -q 'sans le champ merged' "$TMP/b8e.log" && ok "B.8e‴ le refus nomme le champ manquant (schéma), pas une divergence PAYLOAD_PERIME" || ko "B.8e‴ diagnostic : $(grep REFUS "$TMP/b8e.log")"
set_pr true "$C1" provision/appa-rec main alice ci
run_rec "$TMP/b8d.out" "$TMP/b8d.log" GITEA_TOKEN=mauvais; RC=$?
if [ "$RC" -ne 0 ] && grep -q 'REFUS: GITEA_RECONCILE_ECHEC' "$TMP/b8d.log" && grep -q 'HTTP401' "$TMP/b8d.log"; then
  ok "B.8d token refusé (401) ⇒ GITEA_RECONCILE_ECHEC (pas de repli silencieux sur le payload)"
else ko "B.8d 401 : rc=$RC $(tail -2 "$TMP/b8d.log" | tr '\n' ' ')"; fi
[ ! -e "$TMP/b8d.out" ] && [ "$(comments_n)" = 0 ] && ok "B.8d′ aucun fichier de sortie, aucun commentaire" || ko "B.8d′ sortie ou commentaire présents"

echo "-- B.9 FORME : refus AVANT tout appel réseau, sans commentaire, valeur jamais recopiée telle quelle --"
set_pr true "$C1" provision/appa-rec main alice ci
: > "$STUB_LOG"
run_rec "$TMP/b9a.out" "$TMP/b9a.log" PR_NUMBER=12a; RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUS: PR_NUMBER_INVALIDE' "$TMP/b9a.log" && ok "B.9a PR_NUMBER=12a ⇒ PR_NUMBER_INVALIDE" || ko "B.9a rc=$RC $(tail -1 "$TMP/b9a.log")"
run_rec "$TMP/b9b.out" "$TMP/b9b.log" MERGE_SHA=; RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUS: MERGE_SHA_INVALIDE' "$TMP/b9b.log" && ok "B.9b MERGE_SHA vide ⇒ MERGE_SHA_INVALIDE (un webhook sans SHA ne nomme aucune référence)" || ko "B.9b rc=$RC $(tail -1 "$TMP/b9b.log")"
run_rec "$TMP/b9c.out" "$TMP/b9c.log" MERGE_SHA='[x](http://evil)'; RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUS: MERGE_SHA_INVALIDE' "$TMP/b9c.log" && ok "B.9c MERGE_SHA markdown-actif ⇒ MERGE_SHA_INVALIDE" || ko "B.9c rc=$RC $(tail -1 "$TMP/b9c.log")"
grep -q 'valeur : ' "$TMP/b9c.log" && ! grep -q '\[x\](http://evil)' "$TMP/b9c.log" \
  && ok "B.9c′ la valeur refusée n'apparaît dans le JOURNAL qu'échappée (printf %q), jamais brute" || ko "B.9c′ valeur brute dans le journal : $(grep valeur "$TMP/b9c.log")"
run_rec "$TMP/b9d.out" "$TMP/b9d.log" PR_BRANCH=onboard/team-dev; RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUS: BRANCH_FORMAT_INVALIDE' "$TMP/b9d.log" && ok "B.9d branche onboard/* ⇒ BRANCH_FORMAT_INVALIDE (le script reste fail-closed ; c'est le pipeline qui filtre par when)" || ko "B.9d rc=$RC $(tail -1 "$TMP/b9d.log")"
run_rec "$TMP/b9e.out" "$TMP/b9e.log" PR_BRANCH=provision/appa; RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUS: BRANCH_FORMAT_INVALIDE' "$TMP/b9e.log" && ok "B.9e provision/<app> sans -<env> ⇒ BRANCH_FORMAT_INVALIDE" || ko "B.9e rc=$RC $(tail -1 "$TMP/b9e.log")"
run_rec "$TMP/b9f.out" "$TMP/b9f.log" PR_BRANCH='provision/../etc-rec'; RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUS: BRANCH_FORMAT_INVALIDE' "$TMP/b9f.log" && ok "B.9f nom d'app hors classe (../etc) ⇒ BRANCH_FORMAT_INVALIDE (le chemin du manifeste ne sort pas du dossier)" || ko "B.9f rc=$RC $(tail -1 "$TMP/b9f.log")"
run_rec "$TMP/b9g.out" "$TMP/b9g.log" PR_BRANCH='provision/appa-Rec1'; RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUS: BRANCH_FORMAT_INVALIDE' "$TMP/b9g.log" && ok "B.9g palier hors classe (Rec1) ⇒ BRANCH_FORMAT_INVALIDE" || ko "B.9g rc=$RC $(tail -1 "$TMP/b9g.log")"
[ "$(pulls_calls)" = 0 ] && [ "$(files_calls)" = 0 ] && ok "B.9h AUCUN appel /pulls/ ni /files pour ces sept refus de forme (journal du stub)" || ko "B.9h $(pulls_calls) /pulls, $(files_calls) /files malgré des refus de forme"
[ "$(comments_n)" = 0 ] && ok "B.9i AUCUN commentaire pour les refus de forme (un PR_NUMBER forgé ne fait pas publier le compte de service)" || ko "B.9i $(comments_n) commentaire(s) sur refus de forme"
for f in b9a b9b b9c b9d b9e b9f b9g; do [ -e "$TMP/$f.out" ] && ko "B.9j fichier de sortie écrit pour $f"; done; ok "B.9j aucun fichier de sortie pour les refus de forme (contrôle par boucle)"

echo "-- B.10 découpage au DERNIER tiret : app à tirets --"
git -C "$WORK" checkout -q main 2>/dev/null
write_idp "$WORK/clients/provisioned/applications/credit-scoring.ansible.yml" credit-scoring '    rec: { auth: { claim: { value: "cs-rec" } } }'
gitc add -A; gitc commit -qm "cs"; CCS=$(gitc rev-parse HEAD); gitc push -q origin main
set_pr true "$CCS" provision/credit-scoring-rec main alice ci
set_files "poc-control-plane-federation/clients/provisioned/applications/credit-scoring.ansible.yml"
run_rec "$TMP/b10.out" "$TMP/b10.log" PR_BRANCH=provision/credit-scoring-rec MERGE_SHA="$CCS"; RC=$?
[ "$RC" -eq 0 ] && grep -qx 'APP_NAME=credit-scoring' "$TMP/b10.out" && grep -qx 'ENV_NAME=rec' "$TMP/b10.out" \
  && ok "B.10 provision/credit-scoring-rec ⇒ APP_NAME=credit-scoring ENV_NAME=rec" || ko "B.10 rc=$RC : $(tail -3 "$TMP/b10.log" | tr '\n' ' ')"
reset_main "$C1B"

echo "-- B.11 PÉRIMÈTRE : la PR touche autre chose que son manifeste / son certificat --"
set_pr true "$C1" provision/appa-rec main alice ci
set_files "$FMAN" "poc-control-plane-federation/ansible/roles/apim_selfservice_app/tasks/main.yml"
run_rec "$TMP/b11.out" "$TMP/b11.log"; RC=$?
refus_attendu "B.11" "la PR touche ansible/roles/…" PR_HORS_PERIMETRE "$TMP/b11.log" "$RC" "$TMP/b11.out" oui
grep -q 'apim_selfservice_app/tasks/main.yml' "$TMP/b11.log" && ok "B.11‴ le fichier hors périmètre est NOMMÉ dans le journal" || ko "B.11‴ fichier hors périmètre non nommé"
set_pr true "$C1" provision/appa-rec main alice ci
set_files
run_rec "$TMP/b11b.out" "$TMP/b11b.log"; RC=$?
refus_attendu "B.11b" "PR sans aucun fichier" PR_HORS_PERIMETRE "$TMP/b11b.log" "$RC" "$TMP/b11b.out" oui
set_pr true "$C1" provision/appa-rec main alice ci
set_files "$FMAN" "$FCERT"
run_rec "$TMP/b11c.out" "$TMP/b11c.log"; RC=$?
[ "$RC" -eq 0 ] && ok "B.11c manifeste + certificat du palier (appa-rec.crt) ⇒ dans le périmètre, rc 0" || ko "B.11c rc=$RC : $(tail -2 "$TMP/b11c.log" | tr '\n' ' ')"
set_pr true "$C1" provision/appa-rec main alice ci
set_files "$FMAN" "poc-control-plane-federation/clients/provisioned/certs/appa-dev.crt"
run_rec "$TMP/b11d.out" "$TMP/b11d.log"; RC=$?
refus_attendu "B.11d" "certificat d'un AUTRE palier (appa-dev.crt)" PR_HORS_PERIMETRE "$TMP/b11d.log" "$RC" "$TMP/b11d.out" oui
python3 - "$STUB_CTL" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c.pop("files", None); c["files_code"] = 500; json.dump(c, open(sys.argv[1], "w"))
PY
run_rec "$TMP/b11e.out" "$TMP/b11e.log"; RC=$?
refus_attendu "B.11e" "/files en erreur (500)" GITEA_RECONCILE_ECHEC "$TMP/b11e.log" "$RC" "$TMP/b11e.out" oui

echo "-- B.12 POSTÉRIORITÉ : main porte un état plus récent de CE palier ⇒ PALIER_SUPPLANTE --"
set_pr true "$C1" provision/appa-rec main alice ci
write_idp "$TMP/c2.yml" appa '    dev: { auth: { claim: { value: "appa-dev" } }, ip_allowlist: ["10.0.0.1"] }
    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.2"] }'
C2=$(advance_main "$TMP/c2.yml" "c2: rec supplante (10.42.0.2)")
run_rec "$TMP/b12.out" "$TMP/b12.log"; RC=$?
refus_attendu "B.12" "main (c2) a changé per_env.rec après le merge (c1)" PALIER_SUPPLANTE "$TMP/b12.log" "$RC" "$TMP/b12.out" oui
grep -q 'rejeu' "$TMP/b12.log" && ok "B.12‴ le refus nomme la cause probable (rejeu d'un webhook ancien) et la voie (nouvelle demande / repli A6)" || ko "B.12‴ message du refus : $(grep REFUS "$TMP/b12.log")"
grep -q "$(git -C "$WORK" rev-parse origin/main)" "$TMP/b12.log" 2>/dev/null; true
# contrôle : un autre palier a bougé sur main ⇒ CE palier n'est pas supplanté
reset_main "$C1B"
set_pr true "$C1" provision/appa-rec main alice ci
write_idp "$TMP/c2b.yml" appa '    dev: { auth: { claim: { value: "appa-dev" } }, ip_allowlist: ["10.0.0.9"] }
    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.1"] }'
C2B=$(advance_main "$TMP/c2b.yml" "c2b: dev bouge, rec identique")
run_rec "$TMP/b12b.out" "$TMP/b12b.log"; RC=$?
[ "$RC" -eq 0 ] && grep -qx "MERGED_DIGEST=$D_C1" "$TMP/b12b.out" \
  && ok "B.12b contrôle : seul per_env.dev a bougé sur main (c2b) ⇒ rec n'est PAS supplanté, rc 0 (granularité = le palier)" \
  || ko "B.12b rc=$RC : $(tail -2 "$TMP/b12b.log" | tr '\n' ' ')"
# et une re-sérialisation de main sans changement de fond ne supplante pas non plus
reset_main "$C1B"
set_pr true "$C1" provision/appa-rec main alice ci
write_idp "$TMP/c2c.yml" appa '    dev: {auth: {claim: {value: "appa-dev"}}, ip_allowlist: ["10.0.0.1"]}
    rec: {ip_allowlist: ["10.42.0.1"], auth: {claim: {value: "appa-rec"}}}'
C2C=$(advance_main "$TMP/c2c.yml" "c2c: reformatage sans changement de fond")
run_rec "$TMP/b12c.out" "$TMP/b12c.log"; RC=$?
[ "$RC" -eq 0 ] && ok "B.12c contrôle : main reformaté (ordre des clés) mais même fond ⇒ pas supplanté, rc 0" || ko "B.12c rc=$RC : $(tail -2 "$TMP/b12c.log" | tr '\n' ' ')"
reset_main "$C1B"
# manifeste retiré de main ⇒ rien à projeter
set_pr true "$C1" provision/appa-rec main alice ci
W3="$TMP/w3"; rm -rf "$W3"; git clone -q "$ORIGIN" "$W3"; git -C "$W3" rm -q clients/provisioned/applications/appa.ansible.yml
git -C "$W3" -c user.name=t -c user.email=t@t commit -qm "retrait appa"; git -C "$W3" push -q origin main
run_rec "$TMP/b12d.out" "$TMP/b12d.log"; RC=$?
refus_attendu "B.12d" "manifeste retiré de main depuis le merge" MANIFESTE_ABSENT "$TMP/b12d.log" "$RC" "$TMP/b12d.out" oui
reset_main "$C1B"

echo "-- B.13 GIT : SHA hors main, manifeste absent au SHA, palier absent au SHA --"
set_pr true "$CSIDE" provision/appa-rec main alice ci
run_rec "$TMP/b13.out" "$TMP/b13.log" MERGE_SHA="$CSIDE"; RC=$?
refus_attendu "B.13" "SHA d'une branche jamais fusionnée" MERGE_SHA_NON_ANCETRE "$TMP/b13.log" "$RC" "$TMP/b13.out" oui
set_pr true "$C0" provision/appa-rec main alice ci
run_rec "$TMP/b13b.out" "$TMP/b13b.log" MERGE_SHA="$C0"; RC=$?
refus_attendu "B.13b" "manifeste absent de l'arbre au SHA mergé (c0)" MANIFESTE_ABSENT "$TMP/b13b.log" "$RC" "$TMP/b13b.out" oui
set_pr true "$C1B" provision/appd-rec main alice ci
set_files "poc-control-plane-federation/clients/provisioned/applications/appd.ansible.yml"
run_rec "$TMP/b13c.out" "$TMP/b13c.log" PR_BRANCH=provision/appd-rec MERGE_SHA="$C1B"; RC=$?
refus_attendu "B.13c" "le manifeste au SHA mergé ne déclare pas le palier rec (appd : dev seul)" PALIER_ABSENT "$TMP/b13c.log" "$RC" "$TMP/b13c.out" oui
# le clone n'avait PAS c2/c2b/c2c localement : c'est le fetch du script qui les a vus
git -C "$WORK" log --oneline main | grep -q 'c2:' && ko "B.13d le clone local a été avancé par le harnais (le script n'a pas eu à fetcher)" \
  || ok "B.13d main du clone local inchangé : les états c2/c2b/c2c n'étaient visibles que par « git fetch origin main » — le script fetche bien"

echo "-- B.14 un refus ne PATCHe jamais le tableau de bord d'un apply réel (marqueurs distincts) --"
set_pr true "$SHA_AUTRE" provision/appa-rec main alice ci
python3 - "$STUB_COMMENTS" <<'PY'
import json, sys
json.dump([{"id": 1, "body": "<!-- provision-apply -->\n✅ **Apply nominatif RÉUSSI**\n- référence appliquée (SHA de merge) : `aaaa`"}], open(sys.argv[1], "w"))
PY
run_rec "$TMP/b14.out" "$TMP/b14.log"; RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUS: PAYLOAD_PERIME' "$TMP/b14.log" && ok "B.14 webhook forgé (SHA divergent) sur une PR déjà appliquée ⇒ PAYLOAD_PERIME" || ko "B.14 rc=$RC"
[ "$(comments_n)" = 2 ] && first_comment | grep -q 'Apply nominatif RÉUSSI' && first_comment | grep -q '`aaaa`' \
  && ok "B.14b le ✅ existant (marqueur provision-apply) est INTACT : le refus est un commentaire DISTINCT (2 commentaires)" \
  || ko "B.14b le tableau de bord a été altéré : $(comments_n) commentaire(s), premier = $(first_comment | head -2 | tr '\n' ' ')"
last_comment | grep -q '<!-- provision-apply-refus -->' && ok "B.14c le refus porte le marqueur provision-apply-refus" || ko "B.14c marqueur du refus : $(last_comment | head -1)"

echo
echo "═══ Section C — le rapport de PR (provision-apply-comment.sh) : référence, digest, refus, assainissement ═══"
run_cmt(){ # $1=log ; reste = VAR=val
  local log="$1"; shift
  printf '[]' > "$STUB_COMMENTS"
  env -i PATH="$PATH" HOME="$HOME" GITEA_TOKEN="$STUB_TOKEN" GIT_HOST="$GH" GIT_REPO=ci/stoa-labs PR_NUMBER=42 \
    "$@" bash "$COMMENT" >"$log" 2>&1
}
run_cmt "$TMP/c1.log" APPLY_RESULT=SUCCESS APP_NAME=appa ENV_NAME=rec VALIDATOR=alice; RC=$?
B=$(last_comment)
[ "$RC" -eq 0 ] && printf '%s' "$B" | grep -q 'Apply nominatif RÉUSSI' && printf '%s' "$B" | grep -q 'alice' \
  && ok "C.1 appelant d'AVANT A2 (sans SHA/digest) : corps d'aujourd'hui, verdict + identité" || ko "C.1 rc=$RC : $B"
printf '%s' "$B" | grep -q 'référence appliquée' && ko "C.1b une ligne de référence apparaît sans APPLIED_SHA" || ok "C.1b aucune ligne de référence quand APPLIED_SHA est absent (rétro-compatible)"
printf '%s' "$B" | grep -q '<!-- provision-apply -->' && ok "C.1c marqueur du RÉSULTAT : provision-apply" || ko "C.1c marqueur absent"
run_cmt "$TMP/c2.log" APPLY_RESULT=SUCCESS APP_NAME=appa ENV_NAME=rec VALIDATOR=alice \
  APPLIED_SHA="$C1" APPLIED_DIGEST="$D_REC" GIT_WEB_HOST=http://localhost:13000; RC=$?
B=$(last_comment)
printf '%s' "$B" | grep -q "référence appliquée (SHA de merge) : \`$C1\`" && ok "C.2 la ligne « référence appliquée » porte le SHA" || ko "C.2 SHA absent : $B"
printf '%s' "$B" | grep -q "http://localhost:13000/ci/stoa-labs/commit/$C1" && ok "C.2b lien humain-cliquable vers le commit (GIT_WEB_HOST)" || ko "C.2b lien absent"
printf '%s' "$B" | grep -q "digest du manifeste effectif \`per_env.rec\` à ce SHA : \`$D_REC\`" && ok "C.2c la ligne digest nomme le palier et porte le digest" || ko "C.2c digest absent : $B"
printf '%s' "$B" | grep -q 'résultat, référence' && ok "C.2d la phrase finale dit que la PR porte la référence" || ko "C.2d phrase finale inchangée"
run_cmt "$TMP/c3.log" APPLY_RESULT=REFUSED REFUSAL=PAYLOAD_PERIME REFUSAL_DETAIL='merged=False' APP_NAME=appa ENV_NAME=rec; RC=$?
B=$(last_comment)
[ "$RC" -eq 0 ] && ok "C.3 REFUSED sans VALIDATOR accepté (refus avant la pause : aucune identité consommée)" || ko "C.3 rc=$RC : $(cat "$TMP/c3.log")"
printf '%s' "$B" | grep -q 'Apply REFUSÉ avant la pause\*\* — `PAYLOAD_PERIME`' && ok "C.3b en-tête « REFUSÉ avant la pause — PAYLOAD_PERIME »" || ko "C.3b en-tête : $(printf '%s' "$B" | head -2)"
printf '%s' "$B" | grep -q "CE webhook n'a rien appliqué" && printf '%s' "$B" | grep -q 'merged=False' && ok "C.3c « CE webhook n'a rien appliqué » + détail Gitea (licite) en code span" || ko "C.3c conséquence/détail absents"
printf '%s' "$B" | grep -q "n'est PAS déployée" && ko "C.3d un refus avant la pause prétend « PAS déployée » (faux si un apply antérieur existe)" || ok "C.3d un refus avant la pause ne prétend rien sur l'état déployé"
printf '%s' "$B" | grep -q 'aucune consommée' && ok "C.3e dit qu'aucune identité n'a été consommée" || ko "C.3e ligne identité absente"
printf '%s' "$B" | grep -q '<!-- provision-apply-refus -->' && ok "C.3f marqueur des REFUS : provision-apply-refus (jamais celui du résultat)" || ko "C.3f marqueur : $(printf '%s' "$B" | head -1)"
run_cmt "$TMP/c4.log" APPLY_RESULT=FAILURE REFUSAL=SHA_NON_CONFIRME APP_NAME=appa ENV_NAME=rec VALIDATOR=alice APPLIED_SHA="$SHA_AUTRE" EXPECTED_SHA="$C1"; RC=$?
B=$(last_comment)
printf '%s' "$B" | grep -q 'EN ÉCHEC\*\* — `SHA_NON_CONFIRME`' && ok "C.4 FAILURE + SHA_NON_CONFIRME : tag dans l'en-tête" || ko "C.4 : $(printf '%s' "$B" | head -3)"
printf '%s' "$B" | grep -q "L'aval a projeté \`$SHA_AUTRE\`, PAS la référence demandée \`$C1\`" && ok "C.4b dit la vérité : l'aval a projeté X, pas la référence Y (état gateway à vérifier, repli A6)" || ko "C.4b phrase SHA_NON_CONFIRME : $(printf '%s' "$B" | tail -2)"
printf '%s' "$B" | grep -q "n'est PAS déployée" && ko "C.4c SHA_NON_CONFIRME prétend « PAS déployée » alors que l'aval a écrit" || ok "C.4c ne prétend pas « PAS déployée » (l'aval a écrit à un autre SHA)"
printf '%s' "$B" | grep -q "référence DEMANDÉE (SHA de merge de la PR) : \`$C1\`" && ok "C.4d la référence demandée est écrite à côté de celle projetée" || ko "C.4d référence demandée absente"
run_cmt "$TMP/c5.log" APPLY_RESULT=SUCCESS APP_NAME=appa ENV_NAME=rec; RC=$?
[ "$RC" -ne 0 ] && ok "C.5 SUCCESS sans VALIDATOR ⇒ refus (un apply réel sans identité nommée n'est pas rapportable)" || ko "C.5 accepté sans identité"
run_cmt "$TMP/c6.log" APPLY_RESULT=REFUSED REFUSAL='PAYLOAD_PERIME' REFUSAL_DETAIL=$'ligne1 [cliquez](http://evil) *gras* `code`\nligne2 <img src=x>' APP_NAME='appa' ENV_NAME=rec; RC=$?
B=$(last_comment)
printf '%s' "$B" | grep -q '](http://' && ko "C.6 lien markdown injecté dans le commentaire" || ok "C.6 assainissement : aucun lien markdown actif ne survit dans le détail"
printf '%s' "$B" | grep -q '<img' && ko "C.6b balise HTML injectée" || ok "C.6b aucune balise HTML dans le détail"
[ "$(printf '%s' "$B" | grep -c 'ligne2')" = 1 ] && printf '%s' "$B" | grep -q 'ligne1 cliquez http://evil gras code ligne2' \
  && ok "C.6c sauts de ligne supprimés, syntaxe neutralisée, détail sur UNE ligne en code span" || ko "C.6c détail : $(printf '%s' "$B" | grep ligne1)"
run_cmt "$TMP/c7.log" APPLY_RESULT=REFUSED REFUSAL='pas un tag' APP_NAME=appa ENV_NAME=rec; RC=$?
last_comment | grep -q 'REFUSÉ avant la pause\*\*$' && ok "C.7 un REFUSAL hors classe [A-Z0-9_] est ignoré (pas d'injection par le tag)" || ko "C.7 tag hors classe recopié : $(last_comment | head -1)"
run_cmt "$TMP/c8.log" APPLY_RESULT=SUCCESS APP_NAME=appa ENV_NAME=rec VALIDATOR=alice APPLIED_SHA='deadbeef' APPLIED_DIGEST='sha256:zz'; RC=$?
last_comment | grep -q 'référence appliquée' && ko "C.8 un SHA hors forme est recopié" || ok "C.8 SHA et digest hors forme sont IGNORÉS (jamais recopiés)"

echo
echo "═══ Section D — MUTATIONS : chaque comparaison de la réconciliation porte une épreuve ═══"
# On retire UNE comparaison dans une copie du script et on rejoue le scénario
# qui la vise : le mutant doit ACCEPTER (rc 0) là où l'original refuse — preuve
# que l'épreuve B.x tient à cette ligne et pas à un hasard du stub. La copie vit
# dans un faux `scripts/` (lib et rapport liés) pour que ses chemins résolvent.
MUTD="$TMP/mut/scripts"; mkdir -p "$MUTD"; ln -s "$REPO/scripts/lib" "$MUTD/lib"; ln -s "$COMMENT" "$MUTD/provision-apply-comment.sh"
mutate(){ # $1=motif sed à supprimer $2=copie
  sed "/$1/d" "$RECONCILE" > "$2"; chmod +x "$2"
  ! cmp -s "$RECONCILE" "$2"
}
mut_run(){ # $1=copie $2=log [VAR=val…] ; scénario posé par set_pr avant
  local m="$1" log="$2"; shift 2
  env -i PATH="$PATH" HOME="$HOME" GITEA_TOKEN="$STUB_TOKEN" GIT_HOST="$GH" GIT_REPO=ci/stoa-labs GIT_WORKTREE="$WORK" \
    PR_BRANCH="provision/appa-rec" PR_NUMBER=42 MERGE_SHA="$C1" RECONCILE_OUT="$TMP/mut.out" "$@" bash "$m" >"$log" 2>&1
}
python3 - "$STUB_CTL" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c.pop("files", None); c.pop("files_code", None); json.dump(c, open(sys.argv[1], "w"))
PY
if mutate 'merge_commit_sha") != os.environ' "$MUTD/mut1.sh"; then
  set_pr true "$SHA_AUTRE" provision/appa-rec main alice ci
  mut_run "$MUTD/mut1.sh" "$TMP/mut1.log"; RC=$?
  [ "$RC" -eq 0 ] && ok "D.1 sans la comparaison du SHA, le scénario B.3 PASSE (rc 0) — B.3 tient donc à cette ligne" || ko "D.1 le mutant refuse encore (rc=$RC) : $(tail -1 "$TMP/mut1.log")"
else ko "D.1 mutation impossible (motif introuvable)"; fi
if mutate 'base"\].get("ref") != "main"' "$MUTD/mut2.sh"; then
  set_pr true "$C1" provision/appa-rec p3a1-base-1 alice ci
  mut_run "$MUTD/mut2.sh" "$TMP/mut2.log"; RC=$?
  [ "$RC" -eq 0 ] && ok "D.2 sans la comparaison de base.ref, le scénario B.5 PASSE — B.5 tient à cette ligne" || ko "D.2 le mutant refuse encore (rc=$RC) : $(tail -1 "$TMP/mut2.log")"
else ko "D.2 mutation impossible"; fi
if mutate 'get("merged") is not True' "$MUTD/mut3.sh"; then
  set_pr false "$C1" provision/appa-rec main alice ci
  mut_run "$MUTD/mut3.sh" "$TMP/mut3.log"; RC=$?
  [ "$RC" -eq 0 ] && ok "D.3 sans le test merged, le scénario B.2 PASSE — B.2 tient à cette ligne" || ko "D.3 le mutant refuse encore (rc=$RC) : $(tail -1 "$TMP/mut3.log")"
else ko "D.3 mutation impossible"; fi
if mutate 'if head_ref != os.environ\["PR_BRANCH"\]' "$MUTD/mut4.sh"; then
  set_pr true "$C1" provision/autre-rec main alice ci
  mut_run "$MUTD/mut4.sh" "$TMP/mut4.log"; RC=$?
  [ "$RC" -eq 0 ] && ok "D.4 sans la comparaison de head.ref, le scénario B.4b PASSE — B.4b tient à cette ligne" || ko "D.4 le mutant refuse encore (rc=$RC) : $(tail -1 "$TMP/mut4.log")"
else ko "D.4 mutation impossible"; fi
if mutate 'elif extra:' "$MUTD/mut5.sh"; then
  set_pr true "$C1" provision/appa-rec main alice ci
  set_files "$FMAN" "poc-control-plane-federation/ansible/roles/x/tasks/main.yml"
  mut_run "$MUTD/mut5.sh" "$TMP/mut5.log"; RC=$?
  [ "$RC" -eq 0 ] && ok "D.5 sans le test de périmètre, le scénario B.11 PASSE — B.11 tient à cette ligne" || ko "D.5 le mutant refuse encore (rc=$RC) : $(tail -1 "$TMP/mut5.log")"
  python3 - "$STUB_CTL" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c.pop("files", None); json.dump(c, open(sys.argv[1], "w"))
PY
else ko "D.5 mutation impossible"; fi
# la comparaison de digest tient sur DEUX lignes (test + fail) : on retire le test ET son fail.
sed '/^\[ "\$MERGED_DIGEST" = "\$MAIN_DIGEST" \] \\$/,/rejouer une demande, ou le repli A6"$/d' "$RECONCILE" > "$MUTD/mut6.sh"; chmod +x "$MUTD/mut6.sh"
if ! cmp -s "$RECONCILE" "$MUTD/mut6.sh"; then
  set_pr true "$C1" provision/appa-rec main alice ci
  C2=$(advance_main "$TMP/c2.yml" "c2: rec supplante (mutation)")
  mut_run "$MUTD/mut6.sh" "$TMP/mut6.log"; RC=$?
  [ "$RC" -eq 0 ] && ok "D.6 sans la comparaison des digests mergé/main, le scénario B.12 PASSE — B.12 tient à cette ligne" || ko "D.6 le mutant refuse encore (rc=$RC) : $(tail -1 "$TMP/mut6.log")"
  reset_main "$C1B"
else ko "D.6 mutation impossible"; fi
# Et l'original, rejoué sur le dernier scénario, refuse toujours (le stub n'a pas dérivé).
set_pr true "$SHA_AUTRE" provision/appa-rec main alice ci
run_rec "$TMP/d7.out" "$TMP/d7.log"; RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUS: PAYLOAD_PERIME' "$TMP/d7.log" && ok "D.7 contrôle : l'ORIGINAL refuse toujours PAYLOAD_PERIME sur ce scénario" || ko "D.7 l'original accepte (rc=$RC) — le stub a dérivé"

echo
echo "═══════════════════════════════════════════════════"
TOTAL=$((PASS+FAIL))
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$TOTAL"
if [ "$EXPECTED_CHECKS" -gt 0 ] && [ "$TOTAL" -ne "$EXPECTED_CHECKS" ]; then
  printf '❌ %d contrôles exécutés, %d attendus — une section a été sautée ou ajoutée sans mettre EXPECTED_CHECKS à jour\n' "$TOTAL" "$EXPECTED_CHECKS"
  exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
