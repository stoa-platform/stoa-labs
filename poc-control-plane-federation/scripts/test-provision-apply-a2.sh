#!/usr/bin/env bash
# test-provision-apply-a2.sh — preuve X/X HORS LIGNE du jalon A2 (GOAL
# cd-applications) : la référence de déploiement d'une application est le SHA
# mergé, jamais le dernier `master`.
#
#   A. la lib : `app_manifest_digest_env` (digest canonique du bloc per_env.<env>)
#   B. la réconciliation Gitea de provision-apply (scripts/provision-apply-reconcile.sh)
#      contre un STUB Gitea local : le payload ne fait pas foi, refus nommés,
#      aucun appel réseau avant la forme, commentaire de refus posé
#   C. le rapport de PR (provision-apply-comment.sh) : SHA + digest + refus,
#      et corps INCHANGÉ pour les appelants d'avant A2
#   D. MUTATIONS : retirer une comparaison de la réconciliation ⇒ l'épreuve
#      correspondante rougit (motif G3 « toute assertion se règle par mutation »)
#   E. STOA_DEBUG=1 (plan L2) : la réconciliation DIT chaque décision sur stderr
#      (rédigée par ci/lib/dbg.sh), le produit et les refus ne bougent pas — un
#      seul refus change de FORME, celui du fetch (E.4e/f : masqué avant coupe,
#      UNE ligne) —, aucun token ni mot de passe d'URL n'y passe, ni dans une
#      ligne de debug ni dans un refus ; chaque absence doublée d'une présence
#
# Ni Jenkins, ni Gitea, ni gateway : tout est local. La preuve par BUILDS réels
# (porte + contre-épreuve du GOAL) vit dans test-provision-apply-a2-live.sh.
#
#   ./scripts/test-provision-apply-a2.sh
# `A && ok || ko` (SC2015) est l'idiome des scripts de preuve du repo (même
# directive en tête de test-provision-apply-a4.sh) : `ok` est un printf et un
# compteur, il n'échoue pas — le `ko` ne peut pas courir derrière un `ok`.
# shellcheck disable=SC2015
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
EXPECTED_CHECKS=226   # 148 (A-D) + 78 (E)

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
# Historique de master : c0 (sans manifeste) → c1 (appa : dev+rec v1, LE merge)
# → [c2 : per_env.rec change (supplante)] ou [c2b : per_env.dev change (voisin)]
# Une branche `side` (hors master) porte un commit qui n'est pas un ancêtre.
ORIGIN="$TMP/origin.git"; WORK="$TMP/work"
git init -q --bare "$ORIGIN" && git -C "$ORIGIN" symbolic-ref HEAD refs/heads/master
git init -q "$WORK" && git -C "$WORK" checkout -q -b master
gitc(){ git -C "$WORK" -c user.name=t -c user.email=t@t "$@"; }
mkdir -p "$WORK/clients/provisioned/applications" "$WORK/clients/provisioned/certs"
printf 'init\n' > "$WORK/README"; gitc add -A; gitc commit -qm c0; C0=$(gitc rev-parse HEAD)
write_idp "$WORK/clients/provisioned/applications/appa.ansible.yml" appa '    dev: { auth: { claim: { value: "appa-dev" } }, ip_allowlist: ["10.0.0.1"] }
    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.1"] }'
gitc add -A; gitc commit -qm "c1: provision(rec) appa"; C1=$(gitc rev-parse HEAD)
write_idp "$WORK/clients/provisioned/applications/appd.ansible.yml" appd '    dev: { auth: { claim: { value: "appd-dev" } } }'
gitc add -A; gitc commit -qm "c1b: appd dev seul"; C1B=$(gitc rev-parse HEAD)
gitc remote add origin "$ORIGIN"; gitc push -q origin master
gitc checkout -q -b side; printf 'side\n' > "$WORK/SIDE"; gitc add -A; gitc commit -qm side; CSIDE=$(gitc rev-parse HEAD); gitc push -q origin side; gitc checkout -q master
D_C1=$(gitc show "$C1:clients/provisioned/applications/appa.ansible.yml" > "$TMP/c1.yml" && app_manifest_digest_env "$TMP/c1.yml" rec 2>/dev/null)
[ -n "$D_C1" ] && ok "B.0c dépôt de fixture prêt : c0=$(printf '%s' "$C0" | cut -c1-7) c1=$(printf '%s' "$C1" | cut -c1-7) (digest rec $(printf '%s' "$D_C1" | cut -c1-19)…) side=$(printf '%s' "$CSIDE" | cut -c1-7)" || ko "B.0c fixture git illisible"
# master avance sur `origin` sans toucher le clone : le script DOIT fetcher.
advance_main(){ # $1=fichier manifeste appa (contenu complet) $2=message
  local w2="$TMP/w2"; rm -rf "$w2"; git clone -q "$ORIGIN" "$w2"
  cp "$1" "$w2/clients/provisioned/applications/appa.ansible.yml"
  git -C "$w2" -c user.name=t -c user.email=t@t add -A; git -C "$w2" -c user.name=t -c user.email=t@t commit -qm "$2"
  git -C "$w2" push -q origin master; git -C "$w2" rev-parse HEAD
}
reset_main(){ git -C "$WORK" push -q -f origin "$1:master"; }

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
                "base": {"ref": pr.get("base_ref", "master")},
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

echo "-- B.1 nominal : Gitea concorde, master = le merge ⇒ sortie, identités = GITEA, pas le payload --"
set_pr true "$C1" provision/appa-rec master alice ci
: > "$STUB_LOG"
run_rec "$TMP/b1.out" "$TMP/b1.log"; RC=$?
if [ "$RC" -eq 0 ] && [ -s "$TMP/b1.out" ]; then ok "B.1 rc 0 + fichier de sortie écrit"; else ko "B.1 rc=$RC : $(tail -4 "$TMP/b1.log" | tr '\n' ' ')"; fi
grep -qx 'GITEA_MERGED_BY=alice' "$TMP/b1.out" && ok "B.1a GITEA_MERGED_BY=alice (Gitea) alors que le payload disait oscar" || ko "B.1a mergeur : $(grep GITEA_MERGED_BY "$TMP/b1.out")"
grep -qx 'GITEA_REQUESTER=ci' "$TMP/b1.out" && ok "B.1b GITEA_REQUESTER=ci (Gitea) alors que le payload disait eve" || ko "B.1b demandeur : $(grep GITEA_REQUESTER "$TMP/b1.out")"
grep -qx 'APP_NAME=appa' "$TMP/b1.out" && grep -qx 'ENV_NAME=rec' "$TMP/b1.out" && ok "B.1c APP_NAME=appa ENV_NAME=rec" || ko "B.1c app/env : $(grep -E 'APP_NAME|ENV_NAME' "$TMP/b1.out" | tr '\n' ' ')"
grep -qx 'MANIFEST=clients/provisioned/applications/appa.ansible.yml' "$TMP/b1.out" && ok "B.1d MANIFEST=clients/provisioned/applications/appa.ansible.yml" || ko "B.1d manifeste : $(grep MANIFEST "$TMP/b1.out")"
grep -qx "MERGED_DIGEST=$D_C1" "$TMP/b1.out" && ok "B.1e MERGED_DIGEST = digest du manifeste effectif rec au SHA mergé (recalculé ici sur git show)" || ko "B.1e MERGED_DIGEST : $(grep MERGED_DIGEST "$TMP/b1.out")"
# /files est PAGINÉ par forge-api (jusqu'à une page vide, ce stub ignore `page`) :
# au moins un appel — le contrôle positif garde son sens, pas son compte exact.
[ "$(pulls_calls)" = 1 ] && [ "$(files_calls)" -ge 1 ] && ok "B.1f exactement UN GET /pulls/42 et au moins UN GET /pulls/42/files (contrôle positif)" || ko "B.1f $(pulls_calls) /pulls, $(files_calls) /files"
[ "$(comments_n)" = 0 ] && ok "B.1g aucun commentaire posé sur un succès (c'est l'apply qui rapportera)" || ko "B.1g $(comments_n) commentaire(s) inattendu(s)"
grep -q 'RECONCILE_OK' "$TMP/b1.log" && ok "B.1h RECONCILE_OK loggué" || ko "B.1h RECONCILE_OK absent du log"
grep -q "$STUB_TOKEN" "$TMP/b1.log" && ko "B.1i le token FUITE dans la sortie" || ok "B.1i aucune fuite du token dans la sortie"
grep -qx 'GITEA_HEAD_REF=provision/appa-rec' "$TMP/facts" && ok "B.1j fichier de FAITS : GITEA_HEAD_REF relu sur la forge" || ko "B.1j faits absents : $(cat "$TMP/facts" 2>/dev/null)"

echo "-- B.2 PR NON mergée côté Gitea (payload prétend merged:true) --"
set_pr false "$C1" provision/appa-rec master NULL ci
run_rec "$TMP/b2.out" "$TMP/b2.log"; RC=$?
refus_attendu "B.2" "PR non mergée" PAYLOAD_PERIME "$TMP/b2.log" "$RC" "$TMP/b2.out" oui
last_comment | grep -q "CE webhook n'a rien appliqué" && ok "B.2‴ le corps dit « CE webhook n'a rien appliqué » (pas « PAS déployée » : un apply antérieur peut exister)" || ko "B.2‴ corps du refus inattendu"
grep -qx 'GITEA_HEAD_REF=provision/appa-rec' "$TMP/facts" && ok "B.2⁗ faits écrits MÊME sur refus (le post{always} saura que c'est une PR provision/*)" || ko "B.2⁗ faits absents sur refus"

echo "-- B.3 SHA divergent (la PR est mergée, mais pas à ce SHA) --"
set_pr true "$SHA_AUTRE" provision/appa-rec master alice ci
run_rec "$TMP/b3.out" "$TMP/b3.log"; RC=$?
refus_attendu "B.3" "merge_commit_sha ≠ MERGE_SHA" PAYLOAD_PERIME "$TMP/b3.log" "$RC" "$TMP/b3.out" oui

echo "-- B.4 head.ref divergent : PR_NUMBER d'une PR ÉTRANGÈRE (onboard/*) ⇒ refus SANS commentaire --"
set_pr true "$C1" onboard/team-dev master alice ci
run_rec "$TMP/b4.out" "$TMP/b4.log"; RC=$?
refus_attendu "B.4" "head.ref ≠ PR_BRANCH (PR étrangère)" PAYLOAD_PERIME "$TMP/b4.log" "$RC" "$TMP/b4.out" non
grep -qx 'GITEA_HEAD_REF=onboard/team-dev' "$TMP/facts" && ok "B.4‴ faits : GITEA_HEAD_REF=onboard/team-dev (le post{always} ne posera pas de statut)" || ko "B.4‴ faits : $(cat "$TMP/facts" 2>/dev/null)"
set_pr true "$C1" provision/autre-rec master alice ci
run_rec "$TMP/b4b.out" "$TMP/b4b.log"; RC=$?
refus_attendu "B.4b" "head.ref ≠ PR_BRANCH (autre demande provision/*)" PAYLOAD_PERIME "$TMP/b4b.log" "$RC" "$TMP/b4b.out" oui

echo "-- B.5 base.ref ≠ master (mergée dans une base jetable : pas une décision sur master) --"
set_pr true "$C1" provision/appa-rec p3a1-base-1 alice ci
run_rec "$TMP/b5.out" "$TMP/b5.log"; RC=$?
refus_attendu "B.5" "base.ref ≠ master" PAYLOAD_PERIME "$TMP/b5.log" "$RC" "$TMP/b5.out" oui

echo "-- B.6 merged_by absent côté Gitea --"
set_pr true "$C1" provision/appa-rec master NULL ci
run_rec "$TMP/b6.out" "$TMP/b6.log"; RC=$?
refus_attendu "B.6" "Gitea ne nomme aucun mergeur" MERGER_UNKNOWN "$TMP/b6.log" "$RC" "$TMP/b6.out" oui

echo "-- B.7 login forgé (saut de ligne dans merged_by) ⇒ refus, sans commentaire --"
set_pr true "$C1" provision/appa-rec master 'alice\nGITEA_REQUESTER=alice' ci
run_rec "$TMP/b7.out" "$TMP/b7.log"; RC=$?
refus_attendu "B.7" "saut de ligne dans une identité" GITEA_RECONCILE_ECHEC "$TMP/b7.log" "$RC" "$TMP/b7.out" non

echo "-- B.8 Gitea en panne / illisible / hors schéma / token refusé ⇒ GITEA_RECONCILE_ECHEC, jamais de commentaire --"
set_pr true "$C1" provision/appa-rec master alice ci 500
run_rec "$TMP/b8a.out" "$TMP/b8a.log"; RC=$?
refus_attendu "B.8a" "HTTP 500" GITEA_RECONCILE_ECHEC "$TMP/b8a.log" "$RC" "$TMP/b8a.out" non
set_pr true "$C1" provision/appa-rec master alice ci 200 '{"merged": tru'
run_rec "$TMP/b8b.out" "$TMP/b8b.log"; RC=$?
refus_attendu "B.8b" "JSON illisible" GITEA_RECONCILE_ECHEC "$TMP/b8b.log" "$RC" "$TMP/b8b.out" non
set_pr true "$C1" provision/appa-rec master alice ci 200 '[]'
run_rec "$TMP/b8c.out" "$TMP/b8c.log"; RC=$?
refus_attendu "B.8c" "JSON 200 mais pas un objet PR" GITEA_RECONCILE_ECHEC "$TMP/b8c.log" "$RC" "$TMP/b8c.out" non
set_pr true "$C1" provision/appa-rec master alice ci 200 '{"message": "token is required"}'
run_rec "$TMP/b8e.out" "$TMP/b8e.log"; RC=$?
refus_attendu "B.8e" "objet 200 sans les champs d'une PR (portail interposé)" GITEA_RECONCILE_ECHEC "$TMP/b8e.log" "$RC" "$TMP/b8e.out" non
# L'adaptateur normalise (forge-api) : « absent » et « vide » se confondent, le
# schéma se dit donc par les champs qu'une PR ne rend jamais vides (number, head.ref, base.ref).
grep -q "sans les champs d'une PR (absents ou étrangers : number head.ref base.ref" "$TMP/b8e.log" && ok "B.8e‴ le refus nomme les champs manquants (schéma), pas une divergence PAYLOAD_PERIME" || ko "B.8e‴ diagnostic : $(grep REFUS "$TMP/b8e.log")"
set_pr true "$C1" provision/appa-rec master alice ci
run_rec "$TMP/b8d.out" "$TMP/b8d.log" GITEA_TOKEN=mauvais; RC=$?
# la cause de forge-api dit « → HTTP 401 » (un blanc) ; l'ancien python disait « HTTP401 »
if [ "$RC" -ne 0 ] && grep -q 'REFUS: GITEA_RECONCILE_ECHEC' "$TMP/b8d.log" && grep -qE 'HTTP ?401' "$TMP/b8d.log"; then
  ok "B.8d token refusé (401) ⇒ GITEA_RECONCILE_ECHEC (pas de repli silencieux sur le payload)"
else ko "B.8d 401 : rc=$RC $(tail -2 "$TMP/b8d.log" | tr '\n' ' ')"; fi
[ ! -e "$TMP/b8d.out" ] && [ "$(comments_n)" = 0 ] && ok "B.8d′ aucun fichier de sortie, aucun commentaire" || ko "B.8d′ sortie ou commentaire présents"

echo "-- B.9 FORME : refus AVANT tout appel réseau, sans commentaire, valeur jamais recopiée telle quelle --"
set_pr true "$C1" provision/appa-rec master alice ci
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
git -C "$WORK" checkout -q master 2>/dev/null
write_idp "$WORK/clients/provisioned/applications/credit-scoring.ansible.yml" credit-scoring '    rec: { auth: { claim: { value: "cs-rec" } } }'
gitc add -A; gitc commit -qm "cs"; CCS=$(gitc rev-parse HEAD); gitc push -q origin master
set_pr true "$CCS" provision/credit-scoring-rec master alice ci
set_files "poc-control-plane-federation/clients/provisioned/applications/credit-scoring.ansible.yml"
run_rec "$TMP/b10.out" "$TMP/b10.log" PR_BRANCH=provision/credit-scoring-rec MERGE_SHA="$CCS"; RC=$?
[ "$RC" -eq 0 ] && grep -qx 'APP_NAME=credit-scoring' "$TMP/b10.out" && grep -qx 'ENV_NAME=rec' "$TMP/b10.out" \
  && ok "B.10 provision/credit-scoring-rec ⇒ APP_NAME=credit-scoring ENV_NAME=rec" || ko "B.10 rc=$RC : $(tail -3 "$TMP/b10.log" | tr '\n' ' ')"
reset_main "$C1B"

echo "-- B.11 PÉRIMÈTRE : la PR touche autre chose que son manifeste / son certificat --"
set_pr true "$C1" provision/appa-rec master alice ci
set_files "$FMAN" "poc-control-plane-federation/ansible/roles/apim_selfservice_app/tasks/main.yml"
run_rec "$TMP/b11.out" "$TMP/b11.log"; RC=$?
refus_attendu "B.11" "la PR touche ansible/roles/…" PR_HORS_PERIMETRE "$TMP/b11.log" "$RC" "$TMP/b11.out" oui
grep -q 'apim_selfservice_app/tasks/main.yml' "$TMP/b11.log" && ok "B.11‴ le fichier hors périmètre est NOMMÉ dans le journal" || ko "B.11‴ fichier hors périmètre non nommé"
set_pr true "$C1" provision/appa-rec master alice ci
set_files
run_rec "$TMP/b11b.out" "$TMP/b11b.log"; RC=$?
refus_attendu "B.11b" "PR sans aucun fichier" PR_HORS_PERIMETRE "$TMP/b11b.log" "$RC" "$TMP/b11b.out" oui
set_pr true "$C1" provision/appa-rec master alice ci
set_files "$FMAN" "$FCERT"
run_rec "$TMP/b11c.out" "$TMP/b11c.log"; RC=$?
[ "$RC" -eq 0 ] && ok "B.11c manifeste + certificat du palier (appa-rec.crt) ⇒ dans le périmètre, rc 0" || ko "B.11c rc=$RC : $(tail -2 "$TMP/b11c.log" | tr '\n' ' ')"
set_pr true "$C1" provision/appa-rec master alice ci
set_files "$FMAN" "poc-control-plane-federation/clients/provisioned/certs/appa-dev.crt"
run_rec "$TMP/b11d.out" "$TMP/b11d.log"; RC=$?
refus_attendu "B.11d" "certificat d'un AUTRE palier (appa-dev.crt)" PR_HORS_PERIMETRE "$TMP/b11d.log" "$RC" "$TMP/b11d.out" oui
python3 - "$STUB_CTL" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c.pop("files", None); c["files_code"] = 500; json.dump(c, open(sys.argv[1], "w"))
PY
run_rec "$TMP/b11e.out" "$TMP/b11e.log"; RC=$?
refus_attendu "B.11e" "/files en erreur (500)" GITEA_RECONCILE_ECHEC "$TMP/b11e.log" "$RC" "$TMP/b11e.out" oui

echo "-- B.12 POSTÉRIORITÉ : master porte un état plus récent de CE palier ⇒ PALIER_SUPPLANTE --"
set_pr true "$C1" provision/appa-rec master alice ci
write_idp "$TMP/c2.yml" appa '    dev: { auth: { claim: { value: "appa-dev" } }, ip_allowlist: ["10.0.0.1"] }
    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.2"] }'
C2=$(advance_main "$TMP/c2.yml" "c2: rec supplante (10.42.0.2)")
run_rec "$TMP/b12.out" "$TMP/b12.log"; RC=$?
refus_attendu "B.12" "master (c2) a changé per_env.rec après le merge (c1)" PALIER_SUPPLANTE "$TMP/b12.log" "$RC" "$TMP/b12.out" oui
grep -q 'rejeu' "$TMP/b12.log" && ok "B.12‴ le refus nomme la cause probable (rejeu d'un webhook ancien) et la voie (nouvelle demande / repli A6)" || ko "B.12‴ message du refus : $(grep REFUS "$TMP/b12.log")"
grep -q "$(git -C "$WORK" rev-parse origin/master)" "$TMP/b12.log" 2>/dev/null; true
# contrôle : un autre palier a bougé sur master ⇒ CE palier n'est pas supplanté
reset_main "$C1B"
set_pr true "$C1" provision/appa-rec master alice ci
write_idp "$TMP/c2b.yml" appa '    dev: { auth: { claim: { value: "appa-dev" } }, ip_allowlist: ["10.0.0.9"] }
    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.1"] }'
C2B=$(advance_main "$TMP/c2b.yml" "c2b: dev bouge, rec identique")
run_rec "$TMP/b12b.out" "$TMP/b12b.log"; RC=$?
[ "$RC" -eq 0 ] && grep -qx "MERGED_DIGEST=$D_C1" "$TMP/b12b.out" \
  && ok "B.12b contrôle : seul per_env.dev a bougé sur master (c2b) ⇒ rec n'est PAS supplanté, rc 0 (granularité = le palier)" \
  || ko "B.12b rc=$RC : $(tail -2 "$TMP/b12b.log" | tr '\n' ' ')"
# et une re-sérialisation de master sans changement de fond ne supplante pas non plus
reset_main "$C1B"
set_pr true "$C1" provision/appa-rec master alice ci
write_idp "$TMP/c2c.yml" appa '    dev: {auth: {claim: {value: "appa-dev"}}, ip_allowlist: ["10.0.0.1"]}
    rec: {ip_allowlist: ["10.42.0.1"], auth: {claim: {value: "appa-rec"}}}'
C2C=$(advance_main "$TMP/c2c.yml" "c2c: reformatage sans changement de fond")
run_rec "$TMP/b12c.out" "$TMP/b12c.log"; RC=$?
[ "$RC" -eq 0 ] && ok "B.12c contrôle : master reformaté (ordre des clés) mais même fond ⇒ pas supplanté, rc 0" || ko "B.12c rc=$RC : $(tail -2 "$TMP/b12c.log" | tr '\n' ' ')"
reset_main "$C1B"
# manifeste retiré de master ⇒ rien à projeter
set_pr true "$C1" provision/appa-rec master alice ci
W3="$TMP/w3"; rm -rf "$W3"; git clone -q "$ORIGIN" "$W3"; git -C "$W3" rm -q clients/provisioned/applications/appa.ansible.yml
git -C "$W3" -c user.name=t -c user.email=t@t commit -qm "retrait appa"; git -C "$W3" push -q origin master
run_rec "$TMP/b12d.out" "$TMP/b12d.log"; RC=$?
refus_attendu "B.12d" "manifeste retiré de master depuis le merge" MANIFESTE_ABSENT "$TMP/b12d.log" "$RC" "$TMP/b12d.out" oui
reset_main "$C1B"

echo "-- B.13 GIT : SHA hors master, manifeste absent au SHA, palier absent au SHA --"
set_pr true "$CSIDE" provision/appa-rec master alice ci
run_rec "$TMP/b13.out" "$TMP/b13.log" MERGE_SHA="$CSIDE"; RC=$?
refus_attendu "B.13" "SHA d'une branche jamais fusionnée" MERGE_SHA_NON_ANCETRE "$TMP/b13.log" "$RC" "$TMP/b13.out" oui
set_pr true "$C0" provision/appa-rec master alice ci
run_rec "$TMP/b13b.out" "$TMP/b13b.log" MERGE_SHA="$C0"; RC=$?
refus_attendu "B.13b" "manifeste absent de l'arbre au SHA mergé (c0)" MANIFESTE_ABSENT "$TMP/b13b.log" "$RC" "$TMP/b13b.out" oui
set_pr true "$C1B" provision/appd-rec master alice ci
set_files "poc-control-plane-federation/clients/provisioned/applications/appd.ansible.yml"
run_rec "$TMP/b13c.out" "$TMP/b13c.log" PR_BRANCH=provision/appd-rec MERGE_SHA="$C1B"; RC=$?
refus_attendu "B.13c" "le manifeste au SHA mergé ne déclare pas le palier rec (appd : dev seul)" PALIER_ABSENT "$TMP/b13c.log" "$RC" "$TMP/b13c.out" oui
# le clone n'avait PAS c2/c2b/c2c localement : c'est le fetch du script qui les a vus
git -C "$WORK" log --oneline master | grep -q 'c2:' && ko "B.13d le clone local a été avancé par le harnais (le script n'a pas eu à fetcher)" \
  || ok "B.13d master du clone local inchangé : les états c2/c2b/c2c n'étaient visibles que par « git fetch origin master » — le script fetche bien"

echo "-- B.14 un refus ne PATCHe jamais le tableau de bord d'un apply réel (marqueurs distincts) --"
set_pr true "$SHA_AUTRE" provision/appa-rec master alice ci
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
# dans un faux `scripts/` (lib et rapport liés) pour que ses chemins résolvent —
# et un faux `ci/` à côté : le script source $SELF_DIR/../ci/lib/dbg.sh (L2), un
# chemin que le faux arbre doit porter, sinon chaque mutant mourrait avant sa ligne.
MUTD="$TMP/mut/scripts"; mkdir -p "$MUTD"; ln -s "$REPO/scripts/lib" "$MUTD/lib"; ln -s "$COMMENT" "$MUTD/provision-apply-comment.sh"; ln -s "$REPO/ci" "$TMP/mut/ci"
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
# Les motifs visent les comparaisons BASH de la réconciliation (une par ligne,
# depuis le routage sur forge-api : `[ … ] || WHY="$WHY <champ>=…"`).
if mutate 'WHY merge_commit_sha=' "$MUTD/mut1.sh"; then
  set_pr true "$SHA_AUTRE" provision/appa-rec master alice ci
  mut_run "$MUTD/mut1.sh" "$TMP/mut1.log"; RC=$?
  [ "$RC" -eq 0 ] && ok "D.1 sans la comparaison du SHA, le scénario B.3 PASSE (rc 0) — B.3 tient donc à cette ligne" || ko "D.1 le mutant refuse encore (rc=$RC) : $(tail -1 "$TMP/mut1.log")"
else ko "D.1 mutation impossible (motif introuvable)"; fi
if mutate 'WHY base\.ref=' "$MUTD/mut2.sh"; then
  set_pr true "$C1" provision/appa-rec p3a1-base-1 alice ci
  mut_run "$MUTD/mut2.sh" "$TMP/mut2.log"; RC=$?
  [ "$RC" -eq 0 ] && ok "D.2 sans la comparaison de base.ref, le scénario B.5 PASSE — B.5 tient à cette ligne" || ko "D.2 le mutant refuse encore (rc=$RC) : $(tail -1 "$TMP/mut2.log")"
else ko "D.2 mutation impossible"; fi
if mutate 'WHY merged=' "$MUTD/mut3.sh"; then
  set_pr false "$C1" provision/appa-rec master alice ci
  mut_run "$MUTD/mut3.sh" "$TMP/mut3.log"; RC=$?
  [ "$RC" -eq 0 ] && ok "D.3 sans le test merged, le scénario B.2 PASSE — B.2 tient à cette ligne" || ko "D.3 le mutant refuse encore (rc=$RC) : $(tail -1 "$TMP/mut3.log")"
else ko "D.3 mutation impossible"; fi
if mutate 'WHY head\.ref=' "$MUTD/mut4.sh"; then
  set_pr true "$C1" provision/autre-rec master alice ci
  mut_run "$MUTD/mut4.sh" "$TMP/mut4.log"; RC=$?
  [ "$RC" -eq 0 ] && ok "D.4 sans la comparaison de head.ref, le scénario B.4b PASSE — B.4b tient à cette ligne" || ko "D.4 le mutant refuse encore (rc=$RC) : $(tail -1 "$TMP/mut4.log")"
else ko "D.4 mutation impossible"; fi
if mutate 'FILES_VERDICT="FILES_HORS' "$MUTD/mut5.sh"; then
  set_pr true "$C1" provision/appa-rec master alice ci
  set_files "$FMAN" "poc-control-plane-federation/ansible/roles/x/tasks/main.yml"
  mut_run "$MUTD/mut5.sh" "$TMP/mut5.log"; RC=$?
  [ "$RC" -eq 0 ] && ok "D.5 sans le test de périmètre, le scénario B.11 PASSE — B.11 tient à cette ligne" || ko "D.5 le mutant refuse encore (rc=$RC) : $(tail -1 "$TMP/mut5.log")"
  python3 - "$STUB_CTL" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c.pop("files", None); json.dump(c, open(sys.argv[1], "w"))
PY
else ko "D.5 mutation impossible"; fi
# la comparaison de digest tient sur DEUX lignes (test + fail) : on retire le test ET son fail.
sed '/^\[ "\$MERGED_DIGEST" = "\$BASE_DIGEST" \] \\$/,/rejouer une demande, ou le repli A6"$/d' "$RECONCILE" > "$MUTD/mut6.sh"; chmod +x "$MUTD/mut6.sh"
if ! cmp -s "$RECONCILE" "$MUTD/mut6.sh"; then
  set_pr true "$C1" provision/appa-rec master alice ci
  C2=$(advance_main "$TMP/c2.yml" "c2: rec supplante (mutation)")
  mut_run "$MUTD/mut6.sh" "$TMP/mut6.log"; RC=$?
  [ "$RC" -eq 0 ] && ok "D.6 sans la comparaison des digests mergé/base, le scénario B.12 PASSE — B.12 tient à cette ligne" || ko "D.6 le mutant refuse encore (rc=$RC) : $(tail -1 "$TMP/mut6.log")"
  reset_main "$C1B"
else ko "D.6 mutation impossible"; fi
# Et l'original, rejoué sur le dernier scénario, refuse toujours (le stub n'a pas dérivé).
set_pr true "$SHA_AUTRE" provision/appa-rec master alice ci
run_rec "$TMP/d7.out" "$TMP/d7.log"; RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUS: PAYLOAD_PERIME' "$TMP/d7.log" && ok "D.7 contrôle : l'ORIGINAL refuse toujours PAYLOAD_PERIME sur ce scénario" || ko "D.7 l'original accepte (rc=$RC) — le stub a dérivé"

echo
echo "═══ Section E — STOA_DEBUG=1 : la réconciliation parle, sans fuite (plan L2) ═══"
# Gabarit D1/D2/D3 (test-vault-user-login.sh) : chaque ABSENCE (« le token n'y
# est pas ») est DOUBLÉE d'une PRÉSENCE (« la ligne attendue y est ») — sinon un
# script muet passerait toute absence (vert vacant). Les deux flux sont SÉPARÉS :
# c'est la seule façon de prouver qu'aucune ligne de debug ne descend sur stdout,
# le PRODUIT que le pipeline relit (RECONCILE_OK) — un log fusionné ne le
# distingue pas. Le préfixe attendu est le NOM DU SCRIPT ($0) : pas de DBG_NAME,
# c'est ce qu'on veut lire dans un log Jenkins.
# run_dbg <script> <sortie> <stdout> <stderr> [VAR=val…] — run_rec, flux séparés
run_dbg(){
  local script="$1" out="$2" so="$3" se="$4"; shift 4
  rm -f "$out" "$TMP/facts"
  env -i PATH="$PATH" HOME="$HOME" GITEA_TOKEN="$STUB_TOKEN" GIT_HOST="$GH" GIT_REPO=ci/stoa-labs GIT_WORKTREE="$WORK" \
    PR_BRANCH="provision/appa-rec" PR_NUMBER=42 MERGE_SHA="$C1" PR_MERGED_BY=oscar PR_REQUESTER=eve \
    RECONCILE_OUT="$out" RECONCILE_FACTS="$TMP/facts" "$@" bash "$script" >"$so" 2>"$se"
}
# dbgp_re <script> — le préfixe ERE des lignes de debug de CE script : dbg.sh
# signe par ${0##*/} (dbg.sh:308, pas de DBG_NAME), donc une COPIE jouée sous
# un autre nom (mutant mut9.sh, §E.7c) parle sous SON nom, jamais sous celui
# de l'original — appris au rouge (relecture L2-B3 tour 2 : le préfixe de
# l'original cherché sur le stderr d'un mutant ⇒ ligne vide, ko sans message).
# Les sept épreuves qui lisent DBGP_RE sur l'original (E.1p, E.1ab, E.3a,
# E.4a/b/d, E.5b) sont celles qui gardent cette dérivation.
dbgp_re(){ printf '^\\[dbg %s\\] ' "$(printf '%s' "${1##*/}" | sed 's/\./\\./g')"; }
DBGP='[dbg provision-apply-reconcile.sh] '
DBGP_RE="$(dbgp_re "$RECONCILE")"
# ligne_exacte <n> <fichier> <ligne sans préfixe> — la ligne « [dbg <script>] <ligne> », ENTIÈRE (grep -xF)
ligne_exacte(){ grep -qxF -- "${DBGP}$3" "$2" && ok "$1 stderr porte « ] $3 »" || ko "$1 stderr sans « ] $3 » ($(grep -c '\[dbg' "$2") ligne(s) [dbg)"; }
# ligne_motif <n> <fichier> <ERE> <libellé>
ligne_motif(){ grep -qE -- "$3" "$2" && ok "$1 stderr porte « $4 »" || ko "$1 stderr sans « $4 » ($(grep -c '\[dbg' "$2") ligne(s) [dbg)"; }
# precede <fichier> <ERE A> <ERE B> — la première occurrence de A précède la première de B
precede(){ local a b; a=$(grep -nE -m1 -- "$2" "$1" | cut -d: -f1); b=$(grep -nE -m1 -- "$3" "$1" | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; }
# fuite <n> <mot> <libellé> <fichier…> — ABSENCE d'un secret dans TOUS les fichiers donnés (stdout et stderr)
fuite(){ local n="$1" mot="$2" label="$3"; shift 3; grep -qF -- "$mot" "$@" && ko "$n $label FUITE : $(grep -hF -- "$mot" "$@" | head -1 | cut -c1-160)" || ok "$n $label absent de stdout ET de stderr"; }

echo "-- E.1 nominal (scénario B.1) sous STOA_DEBUG=1 : même produit, stdout pur, stderr dit chaque décision, jamais le token --"
set_pr true "$C1" provision/appa-rec master alice ci
run_dbg "$RECONCILE" "$TMP/e1.out" "$TMP/e1.so" "$TMP/e1.se" STOA_DEBUG=1; RC=$?
[ "$RC" -eq 0 ] && cmp -s "$TMP/b1.out" "$TMP/e1.out" \
  && ok "E.1 rc 0 et RECONCILE_OUT identique à B.1 octet pour octet (le debug ne change pas le produit)" \
  || ko "E.1 rc=$RC : $(cmp "$TMP/b1.out" "$TMP/e1.out" 2>&1 | head -1) $(grep -E 'REFUS|ERREUR' "$TMP/e1.se" | head -1 | cut -c1-160)"
[ "$(wc -l < "$TMP/e1.so" | tr -d ' ')" = 1 ] && grep -q '^RECONCILE_OK : ci/stoa-labs#42 mergée' "$TMP/e1.so" \
  && ok "E.1a stdout = exactement UNE ligne, RECONCILE_OK (rien d'autre n'y est descendu)" \
  || ko "E.1a stdout : $(wc -l < "$TMP/e1.so" | tr -d ' ') ligne(s) : $(head -3 "$TMP/e1.so" | cut -c1-100 | tr '\n' '|')"
grep -q '\[dbg' "$TMP/e1.so" && ko "E.1b une ligne « [dbg » sur STDOUT (elle deviendrait une valeur pour le pipeline)" || ok "E.1b aucune ligne « [dbg » sur stdout"
# RECONCILE_FACTS (relu par le post{always} du pipeline) sous debug : une seule
# ligne, la bonne, aucune « [dbg » — copié AVANT le run suivant, qui l'écrase
# (run_dbg le retire) ; E.6b le compare à celui d'un run sans debug.
cp "$TMP/facts" "$TMP/e1.facts" 2>/dev/null
[ "$(wc -l < "$TMP/e1.facts" 2>/dev/null | tr -d ' ')" = 1 ] && grep -qx 'GITEA_HEAD_REF=provision/appa-rec' "$TMP/e1.facts" \
  && ok "E.1ac RECONCILE_FACTS sous debug = exactement « GITEA_HEAD_REF=provision/appa-rec » (une ligne, rien d'autre n'y est descendu)" \
  || ko "E.1ac faits sous debug : $(tr '\n' '|' < "$TMP/e1.facts" 2>/dev/null | cut -c1-160)"
ligne_exacte E.1c "$TMP/e1.se" 'FORGE_KIND=gitea'
ligne_exacte E.1d "$TMP/e1.se" 'GIT_BASE=master'
ligne_exacte E.1e "$TMP/e1.se" 'GIT_BASE_ORIGINE=decouverte'
# GIT_SUBDIR est ABSENT sous env -i : repo_layout_init reprend son défaut — c'est
# ce que la ligne doit dire (E.1ab dit le VIDE quand le knob est posé à « . »).
ligne_exacte E.1f "$TMP/e1.se" 'SUB_PFX=poc-control-plane-federation/'
ligne_exacte E.1g "$TMP/e1.se" 'MANIFEST_DIR=clients/provisioned/applications'
ligne_exacte E.1h "$TMP/e1.se" "GIT_WORKTREE=$WORK"
ligne_exacte E.1i "$TMP/e1.se" 'APP_NAME=appa'
ligne_exacte E.1j "$TMP/e1.se" 'ENV_NAME=rec'
ligne_exacte E.1k "$TMP/e1.se" 'MANIFEST=clients/provisioned/applications/appa.ansible.yml'
ligne_exacte E.1l "$TMP/e1.se" "FORGE_MANIFEST=$FMAN"
ligne_exacte E.1m "$TMP/e1.se" "FORGE_CERT=$FCERT"
ligne_exacte E.1n "$TMP/e1.se" "GIT_CLONE_URL=$ORIGIN"
ligne_motif E.1o "$TMP/e1.se" '^\[dbg forge-api\.py\] GET [^ ]*/pulls/42 -> HTTP 200 \([0-9]+ octets\)$' '[dbg forge-api.py] GET …/pulls/42 -> HTTP 200 (n octets) — forge.err RELAYÉ sur succès, sinon perdu'
ligne_motif E.1p "$TMP/e1.se" "${DBGP_RE}PR #42 relue : state=[^ ]* head=provision/appa-rec base=master merged=1 merge_sha=$C1 merged_by=alice\$" '] PR #42 relue : state=… head=provision/appa-rec base=master merged=1 merge_sha=<c1> merged_by=alice (UNE ligne, ce que la forge a rendu)'
ligne_motif E.1q "$TMP/e1.se" '^\[dbg forge-api\.py\] GET [^ ]*/pulls/42/files[^ ]* -> HTTP 200 \([0-9]+ octets\)$' '[dbg forge-api.py] GET …/pulls/42/files -> HTTP 200 — files.err RELAYÉ sur succès'
ligne_exacte E.1r "$TMP/e1.se" 'FILES_VERDICT=FILES_OK'
ligne_exacte E.1s "$TMP/e1.se" 'git fetch origin master -> rc 0'
ligne_exacte E.1t "$TMP/e1.se" "git merge-base --is-ancestor $C1 origin/master -> rc 0"
ligne_exacte E.1u "$TMP/e1.se" "git show $C1:./clients/provisioned/applications/appa.ansible.yml -> rc 0"
ligne_exacte E.1v "$TMP/e1.se" 'git show origin/master:./clients/provisioned/applications/appa.ansible.yml -> rc 0'
ligne_exacte E.1w "$TMP/e1.se" "MERGED_DIGEST=$D_C1"
ligne_exacte E.1x "$TMP/e1.se" "BASE_DIGEST=$D_C1"
ligne_exacte E.1y "$TMP/e1.se" 'REPLI_DE=<vide>'
fuite E.1z "$STUB_TOKEN" "le token du stub ($STUB_TOKEN)" "$TMP/e1.so" "$TMP/e1.se"
# Le VIDE se dit : GIT_SUBDIR=. (« le livrable est la racine ») chez un client
# dont la forge range le livrable sous un préfixe ⇒ PR_HORS_PERIMETRE — et le
# log dit « SUB_PFX=<vide> » et le chemin vu de la forge SANS préfixe, AVANT le
# refus : c'est le diagnostic que le refus seul ne donne pas.
set_pr true "$C1" provision/appa-rec master alice ci
run_dbg "$RECONCILE" "$TMP/e1s.out" "$TMP/e1s.so" "$TMP/e1s.se" STOA_DEBUG=1 GIT_SUBDIR=.; RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUS: PR_HORS_PERIMETRE' "$TMP/e1s.se" && [ ! -e "$TMP/e1s.out" ] \
  && ok "E.1aa GIT_SUBDIR=. contre un stub qui préfixe ⇒ PR_HORS_PERIMETRE (rc=$RC), refus inchangé, aucune sortie" \
  || ko "E.1aa rc=$RC : $(grep REFUS "$TMP/e1s.se" | head -1 | cut -c1-160)"
precede "$TMP/e1s.se" "${DBGP_RE}SUB_PFX=<vide>\$" 'REFUS: PR_HORS_PERIMETRE' && grep -qxF -- "${DBGP}FORGE_MANIFEST=clients/provisioned/applications/appa.ansible.yml" "$TMP/e1s.se" \
  && ok "E.1ab « ] SUB_PFX=<vide> » et « ] FORGE_MANIFEST=clients/… » (sans préfixe) PRÉCÈDENT le refus : le vide se DIT, c'est le diagnostic" \
  || ko "E.1ab : $(grep -E 'SUB_PFX|FORGE_MANIFEST' "$TMP/e1s.se" | tr '\n' ' ' | cut -c1-200)"

echo "-- E.2 forge en panne (500) et token refusé (401) sous STOA_DEBUG=1 : la ligne HTTP PRÉCÈDE le refus, jamais un token --"
set_pr true "$C1" provision/appa-rec master alice ci 500
run_dbg "$RECONCILE" "$TMP/e2.out" "$TMP/e2.so" "$TMP/e2.se" STOA_DEBUG=1; RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUS: GITEA_RECONCILE_ECHEC' "$TMP/e2.se" && ok "E.2 stub 500 ⇒ GITEA_RECONCILE_ECHEC (rc=$RC), refus inchangé" || ko "E.2 rc=$RC : $(tail -2 "$TMP/e2.se" | tr '\n' ' ' | cut -c1-200)"
precede "$TMP/e2.se" '^\[dbg forge-api\.py\] GET [^ ]*/pulls/42 -> HTTP 500 ' 'REFUS: GITEA_RECONCILE_ECHEC' \
  && ok "E.2a « [dbg forge-api.py] GET …/pulls/42 -> HTTP 500 » PRÉCÈDE « REFUS: GITEA_RECONCILE_ECHEC » (ordre vérifié : le statut d'abord, le verdict ensuite)" \
  || ko "E.2a ordre ou absence : $(grep -nE 'HTTP 500|REFUS' "$TMP/e2.se" | head -3 | tr '\n' ' ' | cut -c1-200)"
[ ! -e "$TMP/e2.out" ] && [ "$(wc -l < "$TMP/e2.so" | tr -d ' ')" = 0 ] && ok "E.2b aucun fichier de sortie, stdout VIDE (le refus ne change pas pour le pipeline)" || ko "E.2b sortie écrite ou stdout non vide : $(head -1 "$TMP/e2.so")"
fuite E.2c "$STUB_TOKEN" "le token du stub" "$TMP/e2.so" "$TMP/e2.se"
set_pr true "$C1" provision/appa-rec master alice ci
run_dbg "$RECONCILE" "$TMP/e2d.out" "$TMP/e2d.so" "$TMP/e2d.se" STOA_DEBUG=1 GITEA_TOKEN=mauvais-jeton; RC=$?
[ "$RC" -ne 0 ] && precede "$TMP/e2d.se" '^\[dbg forge-api\.py\] GET [^ ]*/pulls/42 -> HTTP 401 ' 'REFUS: GITEA_RECONCILE_ECHEC' \
  && ok "E.2d token refusé ⇒ « -> HTTP 401 » PRÉCÈDE « REFUS: GITEA_RECONCILE_ECHEC » (rc=$RC)" \
  || ko "E.2d rc=$RC : $(grep -nE 'HTTP 401|REFUS' "$TMP/e2d.se" | head -3 | tr '\n' ' ' | cut -c1-200)"
fuite E.2e 'mauvais-jeton' "le token REFUSÉ (un secret refusé reste un secret)" "$TMP/e2d.so" "$TMP/e2d.se"

echo "-- E.3 SHA hors master sous STOA_DEBUG=1 : le VRAI rc de git précède MERGE_SHA_NON_ANCETRE --"
set_pr true "$CSIDE" provision/appa-rec master alice ci
run_dbg "$RECONCILE" "$TMP/e3.out" "$TMP/e3.so" "$TMP/e3.se" STOA_DEBUG=1 MERGE_SHA="$CSIDE"; RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUS: MERGE_SHA_NON_ANCETRE' "$TMP/e3.se" && [ ! -e "$TMP/e3.out" ] && ok "E.3 refus MERGE_SHA_NON_ANCETRE inchangé (rc=$RC), aucune sortie" || ko "E.3 rc=$RC : $(grep REFUS "$TMP/e3.se" | head -1 | cut -c1-160)"
precede "$TMP/e3.se" "${DBGP_RE}git merge-base --is-ancestor $CSIDE origin/master -> rc 1\$" 'REFUS: MERGE_SHA_NON_ANCETRE' \
  && ok "E.3a « ] git merge-base --is-ancestor <side> origin/master -> rc 1 » PRÉCÈDE le refus — la décision, avec le rc de git" \
  || ko "E.3a : $(grep -nE 'merge-base|REFUS' "$TMP/e3.se" | head -3 | tr '\n' ' ' | cut -c1-200)"
ligne_exacte E.3b "$TMP/e3.se" 'git fetch origin master -> rc 0'
[ "$(wc -l < "$TMP/e3.so" | tr -d ' ')" = 0 ] && ok "E.3c stdout VIDE sur un refus, debug allumé (rien n'y descend)" || ko "E.3c stdout : $(head -2 "$TMP/e3.so" | tr '\n' '|')"
# Les DEUX `git show` du §4 ont chacun leur rc 128 devant le refus — sans ces
# scénarios, « -> rc 0 » écrit en dur passait E.1u/E.1v (mutant M-B de la
# relecture L2-B3 tour 2 ; E.7e le rejoue et rougit ici). Les refus
# MANIFESTE_ABSENT sont ceux de B.13b et B.12d, joués là SANS debug.
set_pr true "$C0" provision/appa-rec master alice ci
run_dbg "$RECONCILE" "$TMP/e3d.out" "$TMP/e3d.so" "$TMP/e3d.se" STOA_DEBUG=1 MERGE_SHA="$C0"; RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUS: MANIFESTE_ABSENT' "$TMP/e3d.se" && [ ! -e "$TMP/e3d.out" ] && [ "$(wc -l < "$TMP/e3d.so" | tr -d ' ')" = 0 ] \
  && ok "E.3d manifeste absent au SHA mergé (c0) sous debug ⇒ MANIFESTE_ABSENT inchangé (rc=$RC), aucune sortie, stdout vide" \
  || ko "E.3d rc=$RC : $(grep REFUS "$TMP/e3d.se" | head -1 | cut -c1-160)"
precede "$TMP/e3d.se" "${DBGP_RE}git show $C0:\./clients/provisioned/applications/appa\.ansible\.yml -> rc 128\$" 'REFUS: MANIFESTE_ABSENT' \
  && ok "E.3e « ] git show <c0>:./clients/…/appa.ansible.yml -> rc 128 » PRÉCÈDE le refus — le VRAI rc du premier show (le manifeste manque au SHA mergé)" \
  || ko "E.3e : $(grep -nE 'git show|REFUS' "$TMP/e3d.se" | head -3 | tr '\n' ' ' | cut -c1-200)"
ligne_exacte E.3f "$TMP/e3d.se" "git merge-base --is-ancestor $C0 origin/master -> rc 0"
# …et le SECOND show : le manifeste retiré de master DEPUIS le merge (B.12d) —
# même tag de refus, c'est la ligne qui dit LEQUEL des deux show a échoué.
W3E="$TMP/w3e"; rm -rf "$W3E"; git clone -q "$ORIGIN" "$W3E"; git -C "$W3E" rm -q clients/provisioned/applications/appa.ansible.yml
git -C "$W3E" -c user.name=t -c user.email=t@t commit -qm "retrait appa"; git -C "$W3E" push -q origin master
set_pr true "$C1" provision/appa-rec master alice ci
run_dbg "$RECONCILE" "$TMP/e3g.out" "$TMP/e3g.so" "$TMP/e3g.se" STOA_DEBUG=1; RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUS: MANIFESTE_ABSENT' "$TMP/e3g.se" && [ ! -e "$TMP/e3g.out" ] \
  && ok "E.3g manifeste retiré de master depuis le merge, sous debug ⇒ MANIFESTE_ABSENT inchangé (rc=$RC), aucune sortie" \
  || ko "E.3g rc=$RC : $(grep REFUS "$TMP/e3g.se" | head -1 | cut -c1-160)"
precede "$TMP/e3g.se" "${DBGP_RE}git show origin/master:\./clients/provisioned/applications/appa\.ansible\.yml -> rc 128\$" 'REFUS: MANIFESTE_ABSENT' \
  && ok "E.3h « ] git show origin/master:./clients/…/appa.ansible.yml -> rc 128 » PRÉCÈDE le refus — le VRAI rc du second show" \
  || ko "E.3h : $(grep -nE 'git show|REFUS' "$TMP/e3g.se" | head -3 | tr '\n' ' ' | cut -c1-200)"
ligne_exacte E.3i "$TMP/e3g.se" "git show $C1:./clients/provisioned/applications/appa.ansible.yml -> rc 0"
reset_main "$C1B"

echo "-- E.4 ÉCHEC GIT sous STOA_DEBUG=1 : origine à user:mdp@ injoignable ⇒ « git fetch … -> rc 128 » + « git: … », l'hôte reste, jamais le mot de passe --"
# Un clone dont l'origine porte user:mdp@ vers un port fermé (rien n'écoute sur
# 127.0.0.1:1). GIT_CLONE_URL=$ORIGIN : la base se découvre sur le nu, la forge
# concorde, c'est le fetch du §4 qui échoue. Le mot de passe n'est connu d'AUCUNE
# variable : seule la FORME ://…@ de redact peut le masquer. L'ABSENCE se
# cherche sur un FRAGMENT (MDP_FRAG, sa tête) et non sur le mot entier : une
# coupe qui tombe dans le mot en laisse un morceau qu'un grep du littéral
# entier ne verrait pas — c'est ainsi que le refus d'E.4d FUYAIT avant le
# tour 3 (mesuré : « S3cret-xxxx », 11 octets ; §E.4e le garde désormais).
# Le mot de passe est LONG (512 octets) : c'est le DISCRIMINANT de l'ordre
# masque→coupe du helper git_err_une_ligne (relecture L2-B3). Mesuré, git
# 2.42.0 sous GIT_TRACE=1 : l'URL nue est recopiée 3 fois ; le premier mot de
# passe commence à l'octet 189 et, long de 512, court jusqu'à 701 — la coupe à
# 400 tombe DEDANS (URL aux offsets 180/796/1419 ; ≈ 2100 octets en tout :
# 2101 quand git parle français, 2089 en anglais — seule la ligne « fatal »
# finale varie, les offsets ne bougent pas). Un helper
# qui couperait AVANT de masquer laisserait « S3cret-xxx… » orphelin de son
# « @ », que la forme ://…@ du dbg externe ne rattrape plus : E.4d rougit (le
# mutant E.7c le joue). Avec 16 octets (URL à 180/300/427, ≈ 600 octets), la coupe ne
# tombait dans AUCUNE occurrence et le dbg externe remasquait la ligne entière :
# original et mutant étaient indiscernables — un vert vacant sur la propriété
# que le libellé annonçait.
WBAD="$TMP/wbad"; rm -rf "$WBAD"; git clone -q "$ORIGIN" "$WBAD"
MDP_URL="S3cret-$(head -c 505 /dev/zero | tr '\0' x)"; MDP_FRAG="${MDP_URL%%-*}"
git -C "$WBAD" remote set-url origin "http://u:${MDP_URL}@127.0.0.1:1/x.git"
set_pr true "$C1" provision/appa-rec master alice ci
run_dbg "$RECONCILE" "$TMP/e4.out" "$TMP/e4.so" "$TMP/e4.se" STOA_DEBUG=1 GIT_WORKTREE="$WBAD" GIT_CLONE_URL="$ORIGIN"; RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUS: GITEA_RECONCILE_ECHEC : git fetch origin master en échec' "$TMP/e4.se" && [ ! -e "$TMP/e4.out" ] \
  && ok "E.4 fetch en échec ⇒ GITEA_RECONCILE_ECHEC « git fetch origin master en échec » (rc=$RC), refus inchangé" \
  || ko "E.4 rc=$RC : $(grep REFUS "$TMP/e4.se" | head -1 | cut -c1-160)"
precede "$TMP/e4.se" "${DBGP_RE}git fetch origin master -> rc 128\$" 'REFUS: GITEA_RECONCILE_ECHEC' \
  && ok "E.4a « ] git fetch origin master -> rc 128 » PRÉCÈDE le refus (le vrai rc de git)" \
  || ko "E.4a : $(grep -nE 'git fetch|REFUS' "$TMP/e4.se" | head -3 | tr '\n' ' ' | cut -c1-200)"
ligne_motif E.4b "$TMP/e4.se" "${DBGP_RE}  git: .*127\.0\.0\.1" "] git: … 127.0.0.1 … (le stderr de git relayé ; l'hôte RESTE : c'est lui qu'on diagnostique)"
fuite E.4c "$MDP_FRAG" "le mot de passe de l'URL d'origine (même un fragment)" "$TMP/e4.so" "$TMP/e4.se"
# Sous GIT_TRACE=1 — LE knob de debug de git, qu'un client pose à côté de
# STOA_DEBUG — git recopie l'URL NUE dans son stderr (mesuré : 3 fois, ≈ 2100
# octets avec ce mot de passe, git 2.42 — 2101 en français, 2089 en anglais,
# seule la ligne « fatal » varie). La ligne « git: » est masquée EN
# ENTIER avant d'être coupée : elle porte l'URL avec « <secret masqué>@ »,
# jamais un morceau du mot de passe — et comme la coupe à 400 tombe dans le
# premier mot de passe (octets 189..701), seul l'ordre masque→coupe tient
# cette épreuve : E.7c joue l'ordre inverse sur copie et la fait rougir.
# E.4d ne regarde QUE la ligne de debug ; E.4e/E.4f regardent le REFUS du même
# run. Jusqu'au tour 3 (L2-B3), ce refus relayait fetch.err BRUT (`head -c
# 200`, sans masque — d'avant L2) et portait, lui, un MORCEAU du mot de passe
# (« S3cret-xxxx » : la coupe à 200 tombe 11 octets dans le mot, mesuré sur
# la ligne de CONTINUATION du refus — le bloc brut gardait ses retours-ligne).
# Fermé par la même mesure que git-base.sh §J.4e : le refus passe par
# git_err_une_ligne (masqué EN ENTIER, une ligne, coupé à 200) ; le mutant
# §E.7f restaure le brut sur copie et fait rougir E.4e.
run_dbg "$RECONCILE" "$TMP/e4t.out" "$TMP/e4t.so" "$TMP/e4t.se" STOA_DEBUG=1 GIT_WORKTREE="$WBAD" GIT_CLONE_URL="$ORIGIN" GIT_TRACE=1; RC=$?
grep -E "${DBGP_RE}  git: " "$TMP/e4t.se" > "$TMP/e4t.gitline"
[ "$RC" -ne 0 ] && [ -s "$TMP/e4t.gitline" ] && grep -qF -- '<secret masqué>@127.0.0.1:1/x.git' "$TMP/e4t.gitline" && ! grep -qF -- "$MDP_FRAG" "$TMP/e4t.gitline" \
  && ok "E.4d sous GIT_TRACE=1 la ligne « ] git: … » porte « ://<secret masqué>@127.0.0.1:1/x.git » et JAMAIS un fragment du mot de passe (masquée en entier AVANT la coupe : la coupe à 400 tombe dans le mot, E.7c prouve que l'ordre inverse fuit)" \
  || ko "E.4d rc=$RC : $(cut -c1-200 "$TMP/e4t.gitline" | head -1)"
# E.4e — ABSENCE dans TOUT stderr (et stdout), le refus compris. Rougissait
# avant le tour 3 (le fragment sur la ligne de continuation du refus) ; son
# mutant est §E.7f (le brut restauré dans le refus, sur copie).
fuite E.4e "$MDP_FRAG" "le mot de passe de l'URL (fragment), dans le REFUS aussi — pas seulement dans la ligne de debug" "$TMP/e4t.so" "$TMP/e4t.se"
# E.4f — PRÉSENCE, contrepartie d'E.4e (sinon un refus muet passerait) : le
# refus relaie encore le stderr de git (la première ligne de trace y est — ni
# vide, ni « <rédaction indisponible> ») et tient sur UNE ligne : hors des
# lignes « [dbg » et de la ligne « REFUS: », stderr est VIDE (avant le tour 3 :
# une ligne de continuation, celle qui portait le fragment).
grep -E '^REFUS: GITEA_RECONCILE_ECHEC : git fetch origin master en échec dans .* : .*trace: built-in: git fetch' "$TMP/e4t.se" > "$TMP/e4t.refus"
[ "$(wc -l < "$TMP/e4t.refus" | tr -d ' ')" = 1 ] && [ "$(grep -cvE '^(\[dbg |REFUS: )' "$TMP/e4t.se")" = 0 ] \
  && ok "E.4f le REFUS relaie la trace de git (« trace: built-in: git fetch »), masquée, sur UNE ligne : hors « [dbg » et « REFUS: », stderr est vide" \
  || ko "E.4f refus : $(wc -l < "$TMP/e4t.refus" | tr -d ' ') ligne(s) ; hors [dbg/REFUS : $(grep -cvE '^(\[dbg |REFUS: )' "$TMP/e4t.se") ligne(s) : « $(grep -vE '^(\[dbg |REFUS: )' "$TMP/e4t.se" | head -1 | cut -c1-120) »"

echo "-- E.5 l'URL d'origine porte user:mdp@ et GIT_CLONE_URL n'est pas posé : la ligne la dit MASQUÉE (forme), l'hôte reste --"
set_pr true "$C1" provision/appa-rec master alice ci
run_dbg "$RECONCILE" "$TMP/e5.out" "$TMP/e5.so" "$TMP/e5.se" STOA_DEBUG=1 GIT_WORKTREE="$WBAD"; RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUS: BRANCHE_PAR_DEFAUT_INCONNUE' "$TMP/e5.se" && grep -q 'REFUS: GITEA_RECONCILE_ECHEC : branche par défaut du dépôt inconnue' "$TMP/e5.se" && [ ! -e "$TMP/e5.out" ] \
  && ok "E.5 ls-remote sur l'origine injoignable ⇒ BRANCHE_PAR_DEFAUT_INCONNUE puis GITEA_RECONCILE_ECHEC (rc=$RC), refus inchangés" \
  || ko "E.5 rc=$RC : $(grep REFUS "$TMP/e5.se" | head -2 | tr '\n' ' ' | cut -c1-200)"
ligne_exacte E.5a "$TMP/e5.se" 'GIT_CLONE_URL=http://<secret masqué>@127.0.0.1:1/x.git'
ligne_motif E.5b "$TMP/e5.se" "${DBGP_RE}git ls-remote --symref http://<[^>]*>@127\.0\.0\.1:1/x\.git HEAD -> rc 128 " '] git ls-remote --symref http://<…>@127.0.0.1:1/x.git HEAD -> rc 128 (git-base.sh, même préfixe : une seule voix)'
fuite E.5c "$MDP_FRAG" "le mot de passe de l'URL, même un fragment (connu d'AUCUNE variable : seule la forme le masque)" "$TMP/e5.so" "$TMP/e5.se"
[ "$(wc -l < "$TMP/e5.so" | tr -d ' ')" = 0 ] && ok "E.5d stdout VIDE sur ce refus aussi (comme E.2b/E.3c)" || ko "E.5d stdout : $(head -2 "$TMP/e5.so" | tr '\n' '|')"

echo "-- E.6 SILENCE : STOA_DEBUG=0 ⇒ zéro ligne [dbg, même produit ; les sections B (sans STOA_DEBUG) n'en portaient aucune --"
set_pr true "$C1" provision/appa-rec master alice ci
run_dbg "$RECONCILE" "$TMP/e6.out" "$TMP/e6.so" "$TMP/e6.se" STOA_DEBUG=0; RC=$?
[ "$RC" -eq 0 ] && cmp -s "$TMP/b1.out" "$TMP/e6.out" && [ "$(cat "$TMP/e6.so" "$TMP/e6.se" | grep -c '\[dbg')" = 0 ] \
  && ok "E.6 STOA_DEBUG=0 ⇒ rc 0, RECONCILE_OUT identique à B.1, ZÉRO ligne « [dbg » (python et shell muets ensemble)" \
  || ko "E.6 rc=$RC lignes [dbg=$(cat "$TMP/e6.so" "$TMP/e6.se" | grep -c '\[dbg')"
[ "$(grep -c '\[dbg' "$TMP/b1.log")" = 0 ] && [ "$(grep -c '\[dbg' "$TMP/b13.log")" = 0 ] \
  && ok "E.6a non-régression : B.1 (succès) et B.13 (refus), joués SANS STOA_DEBUG, ne portent aucune ligne « [dbg »" \
  || ko "E.6a une section sans STOA_DEBUG porte du debug : b1=$(grep -c '\[dbg' "$TMP/b1.log") b13=$(grep -c '\[dbg' "$TMP/b13.log")"
[ -s "$TMP/e1.facts" ] && cmp -s "$TMP/e1.facts" "$TMP/facts" \
  && ok "E.6b RECONCILE_FACTS identique octet pour octet entre STOA_DEBUG=1 (E.1) et STOA_DEBUG=0 (le debug ne touche pas les faits)" \
  || ko "E.6b faits divergents : $(cmp "$TMP/e1.facts" "$TMP/facts" 2>&1 | head -1)"

echo "-- E.7 MUTATIONS sur COPIE (faux scripts/ de la section D) : le relais retiré ⇒ E.1o rougit ; dbg_kv → echo ⇒ E.1a rougit ; coupe AVANT masque ⇒ E.4d rougit ; relais files.err retiré ⇒ E.1q rougit ; « rc 0 » en dur sur les git show ⇒ E.3e rougit ; fetch.err BRUT restauré dans le refus ⇒ E.4e rougit --"
# shellcheck disable=SC2016  # motif sed : le « $TMP » visé est celui du SCRIPT, à ne pas expandre ici
if mutate '^\[ -s "\$TMP\/forge\.err" \] && cat "\$TMP\/forge\.err" >&2$' "$MUTD/mut7.sh"; then
  set_pr true "$C1" provision/appa-rec master alice ci
  run_dbg "$MUTD/mut7.sh" "$TMP/mut7.out" "$TMP/mut7.so" "$TMP/mut7.se" STOA_DEBUG=1; RC=$?
  [ "$RC" -eq 0 ] && ! grep -qE '^\[dbg forge-api\.py\] GET [^ ]*/pulls/42 -> HTTP 200 ' "$TMP/mut7.se" && grep -qE '^\[dbg forge-api\.py\] GET [^ ]*/pulls/42/files' "$TMP/mut7.se" \
    && ok "E.7a sans le relais de forge.err : rc 0 mais « GET …/pulls/42 -> HTTP 200 » a DISPARU (celle de /files, relayée ailleurs, reste) — E.1o tient à cette ligne" \
    || ko "E.7a le mutant parle encore (rc=$RC) : $(grep -c 'pulls/42 -> HTTP 200' "$TMP/mut7.se") ligne(s) pr_get"
else ko "E.7a mutation impossible (motif introuvable) — mutant no-op"; fi
# shellcheck disable=SC2016  # idem : « $MANIFEST » est celui du script muté, le mutant l'écrit sur stdout
sed 's/^dbg_kv MANIFEST "\$MANIFEST"$/echo "MANIFEST=$MANIFEST"/' "$RECONCILE" > "$MUTD/mut8.sh"; chmod +x "$MUTD/mut8.sh"
if ! cmp -s "$RECONCILE" "$MUTD/mut8.sh"; then
  set_pr true "$C1" provision/appa-rec master alice ci
  run_dbg "$MUTD/mut8.sh" "$TMP/mut8.out" "$TMP/mut8.so" "$TMP/mut8.se" STOA_DEBUG=1; RC=$?
  [ "$RC" -eq 0 ] && [ "$(wc -l < "$TMP/mut8.so" | tr -d ' ')" = 2 ] && grep -q '^MANIFEST=' "$TMP/mut8.so" \
    && ok "E.7b dbg_kv MANIFEST → echo (stdout) : rc 0 mais stdout porte DEUX lignes (MANIFEST=… puis RECONCILE_OK) — E.1a tient à ce que le debug reste sur stderr" \
    || ko "E.7b stdout du mutant : $(wc -l < "$TMP/mut8.so" | tr -d ' ') ligne(s) (rc=$RC)"
else ko "E.7b mutation impossible (motif introuvable) — mutant no-op"; fi
# E.7c — l'ORDRE du helper git_err_une_ligne : la même fonction, coupe à 400
# PUIS masque (le mutant §J.6d de git-base ; la forme que la première grammaire
# §3 écrivait). Insérée juste APRÈS l'originale (sed `r`) : la dernière
# définition gagne. Même fixture qu'E.4d (wbad, mot de passe de 512 octets,
# GIT_TRACE=1) : la coupe tranche dans le premier mot de passe, l'orphelin sans
# « @ » n'a plus de forme — ni le redact du helper ni celui de dbg ne le voient,
# le fragment PASSE dans la ligne « git: ». Le refus, lui, ne bouge pas.
# La copie s'appelle mut9.sh : dbg.sh la signe « [dbg mut9.sh] » — le préfixe
# cherché est le SIEN (dbgp_re), pas celui de l'original (c'était le ko du
# tour 2 : mut9.gitline vide sous le préfixe de l'original, 200/201).
# Même signature que l'originale (`$2` = la coupe, 400 par défaut ; depuis le
# tour 3 le refus du fetch l'appelle à 200) : le mutant ne change que l'ORDRE.
cat > "$MUTD/mut9.fn" <<'FN'
git_err_une_ligne(){ local m; m="$(head -c "${2:-400}" "$1" | tr '\n' ' ')"; printf '%s' "$m" | redact; }
FN
sed "/^git_err_une_ligne(){ /r $MUTD/mut9.fn" "$RECONCILE" > "$MUTD/mut9.sh"; chmod +x "$MUTD/mut9.sh"
if ! cmp -s "$RECONCILE" "$MUTD/mut9.sh"; then
  set_pr true "$C1" provision/appa-rec master alice ci
  run_dbg "$MUTD/mut9.sh" "$TMP/mut9.out" "$TMP/mut9.so" "$TMP/mut9.se" STOA_DEBUG=1 GIT_WORKTREE="$WBAD" GIT_CLONE_URL="$ORIGIN" GIT_TRACE=1; RC=$?
  grep -E "$(dbgp_re "$MUTD/mut9.sh")  git: " "$TMP/mut9.se" > "$TMP/mut9.gitline"
  [ "$RC" -ne 0 ] && grep -q 'REFUS: GITEA_RECONCILE_ECHEC : git fetch origin master en échec' "$TMP/mut9.se" && [ -s "$TMP/mut9.gitline" ] \
    && grep -qF -- "$MDP_FRAG" "$TMP/mut9.gitline" && ! grep -qF -- '<secret masqué>@127.0.0.1:1/x.git' "$TMP/mut9.gitline" \
    && ok "E.7c coupe à 400 PUIS masque (ordre inversé, sur copie) : même refus (rc=$RC) mais la ligne « [dbg mut9.sh]   git: … » porte le FRAGMENT « $MDP_FRAG » et plus aucun « <secret masqué>@ » — E.4d tient à l'ordre masque→coupe, pas au redact de dbg" \
    || ko "E.7c le mutant ne fuit pas (rc=$RC) : ligne git: « $(cut -c1-160 "$TMP/mut9.gitline" | head -1) » ; préfixes vus sur stderr : $(grep -o '^\[dbg [^]]*\]' "$TMP/mut9.se" | sort -u | tr '\n' ' ')"
else ko "E.7c mutation impossible (motif introuvable) — mutant no-op"; fi
# E.7d — le relais de files.err (l'autre relais, grammaire §5) : sans lui les
# lignes « GET …/files?page=n -> HTTP 200 » disparaissent, celle de pr_get
# (relayée par forge.err) reste — E.1q tient à cette ligne.
# shellcheck disable=SC2016  # motif sed : le « $TMP » visé est celui du SCRIPT, à ne pas expandre ici
if mutate '^\[ -s "\$TMP\/files\.err" \] && cat "\$TMP\/files\.err" >&2$' "$MUTD/mut10.sh"; then
  set_pr true "$C1" provision/appa-rec master alice ci
  run_dbg "$MUTD/mut10.sh" "$TMP/mut10.out" "$TMP/mut10.so" "$TMP/mut10.se" STOA_DEBUG=1; RC=$?
  [ "$RC" -eq 0 ] && ! grep -qE '^\[dbg forge-api\.py\] GET [^ ]*/pulls/42/files' "$TMP/mut10.se" && grep -qE '^\[dbg forge-api\.py\] GET [^ ]*/pulls/42 -> HTTP 200 ' "$TMP/mut10.se" \
    && ok "E.7d sans le relais de files.err : rc 0 mais « GET …/pulls/42/files -> HTTP 200 » a DISPARU (celle de pr_get, relayée ailleurs, reste) — E.1q tient à cette ligne" \
    || ko "E.7d le mutant parle encore (rc=$RC) : $(grep -c 'pulls/42/files' "$TMP/mut10.se") ligne(s) /files"
else ko "E.7d mutation impossible (motif introuvable) — mutant no-op"; fi
# E.7e — les quatre lignes « git show … -> rc N » avec « rc 0 » écrit EN DUR (le
# mutant M-B de la relecture tour 2, qui passait E.1u/E.1v) : sur le scénario
# d'E.3d (manifeste absent au SHA mergé) le refus est le même, mais la ligne
# MENT (« rc 0 ») et « rc 128 » n'y est plus — E.3e tient à la VALEUR du rc.
# shellcheck disable=SC2016  # motif sed : « ${RC_GIT} » est celui du script muté
sed 's/^\([[:space:]]*dbg "git show .*\) -> rc \${RC_GIT}"$/\1 -> rc 0"/' "$RECONCILE" > "$MUTD/mut11.sh"; chmod +x "$MUTD/mut11.sh"
if ! cmp -s "$RECONCILE" "$MUTD/mut11.sh"; then
  set_pr true "$C0" provision/appa-rec master alice ci
  run_dbg "$MUTD/mut11.sh" "$TMP/mut11.out" "$TMP/mut11.so" "$TMP/mut11.se" STOA_DEBUG=1 MERGE_SHA="$C0"; RC=$?
  [ "$RC" -ne 0 ] && grep -q 'REFUS: MANIFESTE_ABSENT' "$TMP/mut11.se" \
    && grep -qE "$(dbgp_re "$MUTD/mut11.sh")git show $C0:\./clients/provisioned/applications/appa\.ansible\.yml -> rc 0\$" "$TMP/mut11.se" \
    && ! grep -qF -- "git show $C0:./clients/provisioned/applications/appa.ansible.yml -> rc 128" "$TMP/mut11.se" \
    && ok "E.7e « rc 0 » en dur sur les git show : même refus MANIFESTE_ABSENT (rc=$RC) mais la ligne « [dbg mut11.sh] git show <c0>:… » dit « -> rc 0 » et « -> rc 128 » a disparu — E.3e tient à la valeur du rc" \
    || ko "E.7e (rc=$RC) : $(grep -E 'git show|REFUS' "$TMP/mut11.se" | head -3 | tr '\n' ' ' | cut -c1-200)"
else ko "E.7e mutation impossible (motif introuvable) — mutant no-op"; fi
# E.7f — le REFUS du fetch avec fetch.err BRUT restauré (`head -c 200` sans
# masque : la forme d'avant le tour 3, la dette Minor 6 des relectures). Même
# fixture qu'E.4d/E.4e (wbad, 512 octets, GIT_TRACE=1) : même refus, la ligne
# « git: » du mutant reste masquée (ce n'est PAS elle qui fuit), mais le
# fragment du mot de passe est sur stderr HORS des lignes [dbg — dans le bloc
# du refus. E.4e tient à la ligne du refus, pas au helper ni au redact de dbg.
# shellcheck disable=SC2016  # motif sed : « $TMP » est celui du script muté, à ne pas expandre ici
sed 's/\$(git_err_une_ligne "\$TMP\/fetch\.err" 200)/$(head -c 200 "$TMP\/fetch.err")/' "$RECONCILE" > "$MUTD/mut12.sh"; chmod +x "$MUTD/mut12.sh"
if ! cmp -s "$RECONCILE" "$MUTD/mut12.sh"; then
  set_pr true "$C1" provision/appa-rec master alice ci
  run_dbg "$MUTD/mut12.sh" "$TMP/mut12.out" "$TMP/mut12.so" "$TMP/mut12.se" STOA_DEBUG=1 GIT_WORKTREE="$WBAD" GIT_CLONE_URL="$ORIGIN" GIT_TRACE=1; RC=$?
  [ "$RC" -ne 0 ] && grep -q 'REFUS: GITEA_RECONCILE_ECHEC : git fetch origin master en échec' "$TMP/mut12.se" \
    && grep -E "$(dbgp_re "$MUTD/mut12.sh")  git: " "$TMP/mut12.se" | grep -qF -- '<secret masqué>@127.0.0.1:1/x.git' \
    && grep -v '^\[dbg ' "$TMP/mut12.se" | grep -qF -- "$MDP_FRAG" \
    && ok "E.7f fetch.err BRUT restauré dans le refus (sur copie) : même refus (rc=$RC), la ligne « [dbg mut12.sh]   git: » reste masquée, mais le REFUS porte le fragment « $MDP_FRAG » — E.4e tient à la ligne du refus, pas au helper" \
    || ko "E.7f (rc=$RC) : fragment hors [dbg : $(grep -v '^\[dbg ' "$TMP/mut12.se" | grep -cF -- "$MDP_FRAG") ; ligne git: masquée : $(grep -E "$(dbgp_re "$MUTD/mut12.sh")  git: " "$TMP/mut12.se" | grep -cF -- '<secret masqué>@')"
else ko "E.7f mutation impossible (motif introuvable) — mutant no-op"; fi

echo "-- E.8 le bloc 4bis (REPLI) sous STOA_DEBUG=1 : REPLI_DE non vide, les deux « git show » du repli et leur rc, même produit — et leur rc 128 devant REPLI_PERIME --"
# Un merge --no-ff dont le commit de branche porte le trailer « Repli-De: <sha> »
# (forme d'app-rollback-request.sh, test-app-rollback-a6.sh §A.9). Aucune
# section de cette suite n'exerçait le bloc 4bis, même sans debug : E.1y ne
# prouvait que le VIDE. Trois merges, chacun sur une copie fraîche de l'origine
# (master = c1b) : nominal (Repli-De = c1, dont l'état rec est celui de c1b, le
# parent 1 du merge) ; Repli-De = c0 (la référence ne porte pas le manifeste :
# 4e show, rc 128) ; master ayant RETIRÉ le manifeste avant le merge (le parent
# 1 ne le porte plus : 3e show, rc 128). L'origine est remise à c1b après chacun.
W4="$TMP/w4"
gw4(){ git -C "$W4" -c user.name=t -c user.email=t@t "$@"; }
# repli_merge <sha du trailer> <lignes per_env du manifeste sur la branche> [retrait] — rend le SHA du merge
repli_merge(){
  rm -rf "$W4"; git clone -q "$ORIGIN" "$W4" || return 1
  if [ "${3:-}" = retrait ]; then gw4 rm -q clients/provisioned/applications/appa.ansible.yml && gw4 commit -qm "retrait appa (avant le repli)" || return 1; fi
  gw4 checkout -q -b provision/appa-rec || return 1
  write_idp "$W4/clients/provisioned/applications/appa.ansible.yml" appa "$2"
  gw4 add -A && gw4 commit -qm "$(printf 'provision(rec): repli de appa\n\nRepli-De: %s (PR #40)\n' "$1")" || return 1
  gw4 checkout -q master && gw4 merge -q --no-ff -m "Merge pull request 'provision(rec): appa — repli' (#42) from provision/appa-rec into master" provision/appa-rec || return 1
  gw4 push -q origin master && gw4 rev-parse HEAD
}
PE_C1='    dev: { auth: { claim: { value: "appa-dev" } }, ip_allowlist: ["10.0.0.1"] }
    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.1"] }'
PE_REPLI='    dev: { auth: { claim: { value: "appa-dev" } }, ip_allowlist: ["10.0.0.1"] }
    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.7"] }'
CREPLI=$(repli_merge "$C1" "$PE_REPLI")
set_pr true "$CREPLI" provision/appa-rec master alice ci
run_rec "$TMP/e8.out" "$TMP/e8.log" MERGE_SHA="$CREPLI"; RC=$?
cp "$TMP/facts" "$TMP/e8.facts" 2>/dev/null
[ "$RC" -eq 0 ] && [ -s "$TMP/e8.out" ] && grep -q "^REPLI_OK : la PR est un repli (Repli-De $C1)" "$TMP/e8.log" && grep -q '^RECONCILE_OK' "$TMP/e8.log" \
  && ok "E.8 SANS debug : la PR de repli passe (rc 0), REPLI_OK puis RECONCILE_OK — le bloc 4bis est exercé (aucune section ne le faisait)" \
  || ko "E.8 rc=$RC : $(grep -E 'REFUS|REPLI|RECONCILE' "$TMP/e8.log" | head -2 | tr '\n' ' ' | cut -c1-200)"
run_dbg "$RECONCILE" "$TMP/e8d.out" "$TMP/e8d.so" "$TMP/e8d.se" STOA_DEBUG=1 MERGE_SHA="$CREPLI"; RC=$?
[ "$RC" -eq 0 ] && cmp -s "$TMP/e8.out" "$TMP/e8d.out" && cmp -s "$TMP/e8.facts" "$TMP/facts" \
  && ok "E.8a sous debug : rc 0, RECONCILE_OUT et RECONCILE_FACTS identiques octet pour octet au run sans debug" \
  || ko "E.8a rc=$RC : $(cmp "$TMP/e8.out" "$TMP/e8d.out" 2>&1 | head -1) $(grep -E 'REFUS|ERREUR' "$TMP/e8d.se" | head -1 | cut -c1-160)"
[ "$(wc -l < "$TMP/e8d.so" | tr -d ' ')" = 2 ] && sed -n 1p "$TMP/e8d.so" | grep -q "^REPLI_OK : la PR est un repli (Repli-De $C1)" && sed -n 2p "$TMP/e8d.so" | grep -q "^RECONCILE_OK : ci/stoa-labs#42 mergée ($CREPLI)" && ! grep -q '\[dbg' "$TMP/e8d.so" \
  && ok "E.8b stdout = exactement DEUX lignes, REPLI_OK puis RECONCILE_OK, aucune « [dbg » (le produit du repli n'est pas pollué)" \
  || ko "E.8b stdout : $(wc -l < "$TMP/e8d.so" | tr -d ' ') ligne(s) : $(head -3 "$TMP/e8d.so" | cut -c1-80 | tr '\n' '|')"
ligne_exacte E.8c "$TMP/e8d.se" "REPLI_DE=$C1"
ligne_exacte E.8d "$TMP/e8d.se" "git show $C1B:./clients/provisioned/applications/appa.ansible.yml -> rc 0"
ligne_exacte E.8e "$TMP/e8d.se" "git show $C1:./clients/provisioned/applications/appa.ansible.yml -> rc 0"
fuite E.8f "$STUB_TOKEN" "le token du stub" "$TMP/e8d.so" "$TMP/e8d.se"
reset_main "$C1B"
# Repli-De = c0 : la référence ne porte pas le manifeste ⇒ le 4e show dit rc 128 AVANT REPLI_PERIME.
CREPLI0=$(repli_merge "$C0" "$PE_REPLI")
set_pr true "$CREPLI0" provision/appa-rec master alice ci
run_dbg "$RECONCILE" "$TMP/e8g.out" "$TMP/e8g.so" "$TMP/e8g.se" STOA_DEBUG=1 MERGE_SHA="$CREPLI0"; RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUS: REPLI_PERIME : la référence Repli-De' "$TMP/e8g.se" && [ ! -e "$TMP/e8g.out" ] \
  && precede "$TMP/e8g.se" "${DBGP_RE}git show $C0:\./clients/provisioned/applications/appa\.ansible\.yml -> rc 128\$" 'REFUS: REPLI_PERIME' \
  && ok "E.8g Repli-De = c0 (sans manifeste) ⇒ « ] git show <c0>:… -> rc 128 » PRÉCÈDE « REFUS: REPLI_PERIME » (rc=$RC), aucune sortie — le rc du 4e show" \
  || ko "E.8g rc=$RC : $(grep -nE 'git show|REFUS' "$TMP/e8g.se" | head -4 | tr '\n' ' ' | cut -c1-240)"
# …et le mutant « rc 0 en dur » (mut11, §E.7e) sur CE scénario : même refus, la ligne ment.
run_dbg "$MUTD/mut11.sh" "$TMP/mut11g.out" "$TMP/mut11g.so" "$TMP/mut11g.se" STOA_DEBUG=1 MERGE_SHA="$CREPLI0"; RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUS: REPLI_PERIME : la référence Repli-De' "$TMP/mut11g.se" \
  && grep -qE "$(dbgp_re "$MUTD/mut11.sh")git show $C0:\./clients/provisioned/applications/appa\.ansible\.yml -> rc 0\$" "$TMP/mut11g.se" \
  && ! grep -qF -- "git show $C0:./clients/provisioned/applications/appa.ansible.yml -> rc 128" "$TMP/mut11g.se" \
  && ok "E.8i mutant « rc 0 » en dur sur ce scénario : même REPLI_PERIME (rc=$RC) mais « git show <c0>:… -> rc 0 » et plus de « rc 128 » — E.8g tient à la valeur du rc du 4e show" \
  || ko "E.8i (rc=$RC) : $(grep -E 'git show|REFUS' "$TMP/mut11g.se" | head -3 | tr '\n' ' ' | cut -c1-200)"
reset_main "$C1B"
# master a RETIRÉ le manifeste avant le merge : le parent 1 ne le porte plus ⇒ le 3e show dit rc 128 AVANT REPLI_PERIME.
CREPLIR=$(repli_merge "$C1" "$PE_C1" retrait); P1R=$(gw4 rev-parse "${CREPLIR}^1")
set_pr true "$CREPLIR" provision/appa-rec master alice ci
run_dbg "$RECONCILE" "$TMP/e8h.out" "$TMP/e8h.so" "$TMP/e8h.se" STOA_DEBUG=1 MERGE_SHA="$CREPLIR"; RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUS: REPLI_PERIME : clients/provisioned/applications/appa.ansible.yml absent de master juste avant le merge' "$TMP/e8h.se" && [ ! -e "$TMP/e8h.out" ] \
  && precede "$TMP/e8h.se" "${DBGP_RE}git show $P1R:\./clients/provisioned/applications/appa\.ansible\.yml -> rc 128\$" 'REFUS: REPLI_PERIME' \
  && ok "E.8h manifeste retiré de master avant le merge ⇒ « ] git show <parent 1>:… -> rc 128 » PRÉCÈDE « REFUS: REPLI_PERIME » (rc=$RC) — le rc du 3e show" \
  || ko "E.8h rc=$RC : $(grep -nE 'git show|REFUS' "$TMP/e8h.se" | head -4 | tr '\n' ' ' | cut -c1-240)"
# …et le même mutant sur le 3e show : même refus, la ligne du parent 1 ment.
run_dbg "$MUTD/mut11.sh" "$TMP/mut11h.out" "$TMP/mut11h.so" "$TMP/mut11h.se" STOA_DEBUG=1 MERGE_SHA="$CREPLIR"; RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUS: REPLI_PERIME : clients/provisioned/applications/appa.ansible.yml absent de master juste avant le merge' "$TMP/mut11h.se" \
  && grep -qE "$(dbgp_re "$MUTD/mut11.sh")git show $P1R:\./clients/provisioned/applications/appa\.ansible\.yml -> rc 0\$" "$TMP/mut11h.se" \
  && ! grep -qF -- "git show $P1R:./clients/provisioned/applications/appa.ansible.yml -> rc 128" "$TMP/mut11h.se" \
  && ok "E.8j mutant « rc 0 » en dur sur ce scénario : même REPLI_PERIME (rc=$RC) mais « git show <parent 1>:… -> rc 0 » et plus de « rc 128 » — E.8h tient à la valeur du rc du 3e show" \
  || ko "E.8j (rc=$RC) : $(grep -E 'git show|REFUS' "$TMP/mut11h.se" | head -3 | tr '\n' ' ' | cut -c1-200)"
reset_main "$C1B"

echo
echo "═══════════════════════════════════════════════════"
TOTAL=$((PASS+FAIL))
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$TOTAL"
if [ "$EXPECTED_CHECKS" -gt 0 ] && [ "$TOTAL" -ne "$EXPECTED_CHECKS" ]; then
  printf '❌ %d contrôles exécutés, %d attendus — une section a été sautée ou ajoutée sans mettre EXPECTED_CHECKS à jour\n' "$TOTAL" "$EXPECTED_CHECKS"
  exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
