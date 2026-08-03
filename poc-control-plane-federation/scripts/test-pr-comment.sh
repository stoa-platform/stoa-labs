#!/usr/bin/env bash
# test-pr-comment.sh — preuve X/X du commentaire de PR partagé (ADR-081) :
# l'upsert par marqueur (lib/gitea-pr-comment.sh), le rapport d'apply
# (provision-apply-comment.sh), et le CÂBLAGE des deux corollaires.
#
# HORS LIGNE : faux Gitea en python, ni forge ni Jenkins ni gateway.
#
# CE QUE CE TEST DÉFEND. L'idempotence du commentaire n'est pas cosmétique : le
# plan tourne DEUX fois par demande depuis la fusion (enchaîné + webhook
# `opened`), et la PR d'un valideur ne doit pas se remplir de verdicts empilés
# dont il ne saurait plus lequel est courant.
#
#   ./scripts/test-pr-comment.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/prcmt.XXXXXX)"
PORT="${GITEA_PORT:-18300}"
GITEA_PID=""
cleanup(){ [ -n "$GITEA_PID" ] && kill "$GITEA_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

command -v python3 >/dev/null || { echo "python3 absent"; exit 2; }

# ── faux Gitea : juste assez de l'API issues/comments ────────────────────────
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
        if re.match(r"^/api/v1/repos/.+/issues/\d+/comments$", self.path):
            return self._send(200, load())
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

startgitea(){ # $1 = token attendu
  [ -n "$GITEA_PID" ] && kill "$GITEA_PID" 2>/dev/null
  printf '[]' > "$TMP/comments.json"
  STORE="$TMP/comments.json" EXPECT_TOKEN="$1" python3 "$TMP/fakegitea.py" "$PORT" >/dev/null 2>&1 &
  GITEA_PID=$!
  for _ in $(seq 1 40); do curl -s "http://127.0.0.1:$PORT/x" >/dev/null 2>&1 && return; sleep 0.1; done
}
count(){ python3 -c "import json;print(len(json.load(open('$TMP/comments.json'))))"; }
bodies(){ python3 -c "import json;print('\n---\n'.join(c['body'] for c in json.load(open('$TMP/comments.json'))))"; }

LIB="$REPO/scripts/lib/gitea-pr-comment.sh"
GH="http://127.0.0.1:$PORT"

echo "== 1. premier appel : le commentaire est CRÉÉ =="
startgitea tok-ok
printf 'corps initial\n' > "$TMP/b1.md"
OUT=$(GIT_REPO=ci/stoa-labs GITEA_TOKEN=tok-ok PR_NUMBER=7 GIT_HOST="$GH" \
      COMMENT_MARKER='<!-- provision-plan -->' COMMENT_BODY_FILE="$TMP/b1.md" bash "$LIB" 2>&1); RC=$?
[ $RC -eq 0 ] && grep -q "COMMENT_CREATED" <<<"$OUT" && ok "créé" || ko "création échouée (rc=$RC) : $OUT"
[ "$(count)" = "1" ] && ok "1 commentaire" || ko "$(count) commentaires"

echo
echo "== 2. rejoué avec le MÊME marqueur : mis à jour, pas empilé =="
printf 'corps mis a jour\n' > "$TMP/b2.md"
OUT=$(GIT_REPO=ci/stoa-labs GITEA_TOKEN=tok-ok PR_NUMBER=7 GIT_HOST="$GH" \
      COMMENT_MARKER='<!-- provision-plan -->' COMMENT_BODY_FILE="$TMP/b2.md" bash "$LIB" 2>&1); RC=$?
[ $RC -eq 0 ] && grep -q "COMMENT_UPDATED" <<<"$OUT" && ok "mis à jour" || ko "PATCH non effectué : $OUT"
[ "$(count)" = "1" ] && ok "toujours 1 commentaire (pas de doublon)" || ko "$(count) commentaires — empilement"
bodies | grep -q "corps mis a jour" && ok "corps réellement remplacé" || ko "ancien corps conservé"

echo
echo "== 3. marqueur DIFFÉRENT : plan et apply cohabitent =="
printf 'resultat apply\n' > "$TMP/b3.md"
OUT=$(GIT_REPO=ci/stoa-labs GITEA_TOKEN=tok-ok PR_NUMBER=7 GIT_HOST="$GH" \
      COMMENT_MARKER='<!-- provision-apply -->' COMMENT_BODY_FILE="$TMP/b3.md" bash "$LIB" 2>&1); RC=$?
[ $RC -eq 0 ] && grep -q "COMMENT_CREATED" <<<"$OUT" && ok "second commentaire créé" || ko "cohabitation cassée : $OUT"
[ "$(count)" = "2" ] && ok "2 commentaires (plan + apply)" || ko "$(count) commentaires"

echo
echo "== 4. FAIL-CLOSED : forge qui refuse le token =="
startgitea autre-token
OUT=$(GIT_REPO=ci/stoa-labs GITEA_TOKEN=tok-ok PR_NUMBER=7 GIT_HOST="$GH" \
      COMMENT_MARKER='<!-- provision-plan -->' COMMENT_BODY_FILE="$TMP/b1.md" bash "$LIB" 2>&1); RC=$?
[ $RC -ne 0 ] && ok "échec signalé (pas de succès silencieux)" || ko "succès rapporté alors que la forge refuse"
grep -q "COMMENT_FAILED" <<<"$OUT" && ok "COMMENT_FAILED" || ko "diagnostic absent"
grep -q "tok-ok" <<<"$OUT" && ko "le token FUITE dans la sortie d'erreur" || ok "aucune fuite du token"

echo
echo "== 5. rapport d'apply RÉUSSI : identité nominative visible =="
startgitea tok-ok
OUT=$(PR_NUMBER=7 APPLY_RESULT=SUCCESS APP_NAME=credit-scoring ENV_NAME=dev VALIDATOR=alice \
      BUILD_URL=http://jenkins/job/42/ GIT_REPO=ci/stoa-labs GITEA_TOKEN=tok-ok GIT_HOST="$GH" \
      bash "$REPO/scripts/provision-apply-comment.sh" 2>&1); RC=$?
[ $RC -eq 0 ] && ok "commentaire posté" || ko "échec (rc=$RC) : $OUT"
B=$(bodies)
grep -q "Apply nominatif RÉUSSI" <<<"$B" && ok "verdict de succès" || ko "verdict absent"
grep -q "alice" <<<"$B" && ok "identité du valideur présente (c'est ce que l'auditeur cherche)" || ko "identité absente"
grep -q "credit-scoring" <<<"$B" && grep -q "dev" <<<"$B" && ok "application et env cités" || ko "contexte absent"
grep -q "provision-apply" <<<"$B" && ok "marqueur présent (rejouable sans doublon)" || ko "marqueur absent"

echo
echo "== 6. rapport d'apply EN ÉCHEC : dit que RIEN n'est déployé =="
startgitea tok-ok
OUT=$(PR_NUMBER=7 APPLY_RESULT=FAILURE APP_NAME=credit-scoring ENV_NAME=prod VALIDATOR=bob \
      GIT_REPO=ci/stoa-labs GITEA_TOKEN=tok-ok GIT_HOST="$GH" \
      bash "$REPO/scripts/provision-apply-comment.sh" 2>&1); RC=$?
[ $RC -eq 0 ] && ok "commentaire posté malgré l'échec de l'apply" || ko "pas de rapport sur échec"
bodies | grep -q "EN ÉCHEC" && ok "verdict d'échec" || ko "échec non signalé"
bodies | grep -q "n'est PAS déployée" && ok "conséquence explicite (pas seulement un ❌)" || ko "conséquence implicite"

echo
echo "== 7. CÂBLAGE corollaire 1 : la demande enchaîne le plan =="
grep -q 'provision-plan.sh' "$REPO/scripts/provision-request.sh" \
  && ok "provision-request.sh appelle provision-plan.sh" || ko "fusion absente"
grep -q 'PR_BRANCH="\$BRANCH" PR_NUMBER="\$PR_NUM"' "$REPO/scripts/provision-request.sh" \
  && ok "PR_BRANCH/PR_NUMBER transmis" || ko "paramètres non transmis"

echo
echo "== 8. CÂBLAGE corollaire 2 : le job rapporte, succès COMME échec =="
JOB="$REPO/ci/jenkins/provision-apply.job.xml"
python3 -c "import xml.etree.ElementTree as T; T.parse('$JOB')" 2>/dev/null \
  && ok "XML bien formé" || ko "XML cassé"
grep -q 'provision-apply-comment.sh' "$JOB" && ok "script appelé" || ko "rapport non câblé"
grep -q 'finally' "$JOB" && ok "dans un finally (rapporte aussi sur échec)" || ko "pas de finally — un échec ne serait pas rapporté"
grep -q 'provision-apply-comment.sh || true' "$JOB" \
  && ok "|| true : une forge en panne ne rougit pas un apply vert" || ko "le rapport peut faire échouer un apply réussi"
grep -q "error(" "$JOB" && ok "l'échec réel est réaffirmé hors du finally" || ko "un apply en échec finirait vert"

echo
echo "== 9. les scripts sont syntaxiquement valides =="
for s in scripts/lib/gitea-pr-comment.sh scripts/provision-apply-comment.sh scripts/provision-request.sh scripts/provision-plan.sh; do
  bash -n "$REPO/$s" 2>/dev/null && ok "$(basename "$s")" || ko "$(basename "$s") — syntaxe"
done

echo
echo "== 10. provision-plan.sh résout son chemin AVANT de changer de dossier =="
# Piège rencontré en écrivant ce lot : le script se déplace dans le clone de la
# PR ($WORK/repo) avant de commenter. Un `dirname "$0"` évalué APRÈS ce `cd` ne
# résout plus — l'appel à la lib partagée échouerait à l'exécution, jamais à la
# lecture. On verrouille donc l'ORDRE, statiquement.
P="$REPO/scripts/provision-plan.sh"
L_SELF=$(grep -n '^SELF_DIR=' "$P" | head -1 | cut -d: -f1)
L_CD=$(grep -n '^cd "\$WORK' "$P" | head -1 | cut -d: -f1)
if [ -n "$L_SELF" ] && [ -n "$L_CD" ] && [ "$L_SELF" -lt "$L_CD" ]; then
  ok "SELF_DIR ligne $L_SELF, cd ligne $L_CD"
else
  ko "SELF_DIR résolu après le cd (ou absent) : self=$L_SELF cd=$L_CD"
fi
grep -q 'bash "\$SELF_DIR/lib/gitea-pr-comment.sh"' "$P" \
  && ok "la lib est appelée par chemin absolu" || ko "appel relatif — cassera après le cd"

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
