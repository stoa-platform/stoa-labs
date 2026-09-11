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
        # A0 dettes : la lib PAGINE (?limit=50&page=N) — le faux honore les deux
        # paramètres, comme le vrai Gitea (limit max 50 par défaut).
        path, _, qs = self.path.partition("?")
        if re.match(r"^/api/v1/repos/.+/issues/\d+/comments$", path):
            q = dict(kv.split("=", 1) for kv in qs.split("&") if "=" in kv)
            # PLAFOND serveur (api.MAX_RESPONSE_ITEMS chez Gitea) : `limit` est
            # ECRETE, une page pleine peut donc etre plus courte que demande.
            cap = int(os.environ.get("PAGE_CAP", "50"))
            lim, page = min(int(q.get("limit", 50)), cap), int(q.get("page", 1))
            allc = load()
            return self._send(200, allc[(page - 1) * lim: page * lim])
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
  STORE="$TMP/comments.json" EXPECT_TOKEN="$1" PAGE_CAP="${PAGE_CAP:-50}" python3 "$TMP/fakegitea.py" "$PORT" >/dev/null 2>&1 &
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
      GITEA_REQUESTER=carol GITEA_MERGED_BY=bob \
      BUILD_URL=http://jenkins/job/42/ GIT_REPO=ci/stoa-labs GITEA_TOKEN=tok-ok GIT_HOST="$GH" \
      bash "$REPO/scripts/provision-apply-comment.sh" 2>&1); RC=$?
[ $RC -eq 0 ] && ok "commentaire posté" || ko "échec (rc=$RC) : $OUT"
B=$(bodies)
grep -q "Apply nominatif RÉUSSI" <<<"$B" && ok "verdict de succès" || ko "verdict absent"
grep -q "alice" <<<"$B" && ok "identité du valideur présente (c'est ce que l'auditeur cherche)" || ko "identité absente"
grep -q "credit-scoring" <<<"$B" && grep -q "dev" <<<"$B" && ok "application et env cités" || ko "contexte absent"
grep -q "provision-apply" <<<"$B" && ok "marqueur présent (rejouable sans doublon)" || ko "marqueur absent"
# A7 : les trois identités (G7 D4 porté aux applications) — demandée / mergée / portée
grep -qF -- '- identités : demandée par `carol` · mergée par `bob` · portée par `alice`' <<<"$B" && ok "A7 : la ligne des trois identités (demandée par carol · mergée par bob · portée par alice)" || ko "A7 : ligne des identités absente ou fausse : $(grep -F 'identités' <<<"$B")"
startgitea tok-ok
OUT=$(PR_NUMBER=7 APPLY_RESULT=REFUSED REFUSAL=PAYLOAD_PERIME APP_NAME=credit-scoring ENV_NAME=dev \
      GITEA_REQUESTER=carol GITEA_MERGED_BY=bob GIT_REPO=ci/stoa-labs GITEA_TOKEN=tok-ok GIT_HOST="$GH" \
      bash "$REPO/scripts/provision-apply-comment.sh" 2>&1); RC=$?
[ $RC -eq 0 ] && ! bodies | grep -qF 'identités :' && bodies | grep -q 'aucune consommée' && ok "A7 : sur REFUSED, aucune ligne d'identités (aucune identité consommée)" || ko "A7 : REFUSED porte une ligne d'identités (rc=$RC)"
startgitea tok-ok
OUT=$(PR_NUMBER=7 APPLY_RESULT=FAILURE APP_NAME=credit-scoring ENV_NAME=dev VALIDATOR=alice \
      GIT_REPO=ci/stoa-labs GITEA_TOKEN=tok-ok GIT_HOST="$GH" bash "$REPO/scripts/provision-apply-comment.sh" 2>&1); RC=$?
bodies | grep -qF -- '- identités : demandée par `(inconnu)` · mergée par `(inconnu)` · portée par `alice`' && ok "A7 : identités absentes de l'env ⇒ (inconnu), jamais une ligne vide" || ko "A7 : (inconnu) attendu : $(bodies | grep -F 'identités')"

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
# A2 : le job provision-apply vit dans ci/Jenkinsfile.provision-apply
# (déclaratif, from SCM) — le XML n'est plus qu'une coquille sans Groovy.
# L'équivalent déclaratif du `try/finally` : le rapport est appelé dans le
# step d'apply avec `propagate: false` (l'amont voit l'échec de l'aval SANS
# lever), puis `error()` réaffirme l'échec ; et un `post { always }` pose le
# statut build dans TOUS les cas (marqueur distinct).
JOB="$REPO/ci/jenkins/provision-apply.job.xml"
JF="$REPO/ci/Jenkinsfile.provision-apply"
python3 -c "import xml.etree.ElementTree as T; T.parse('$JOB')" 2>/dev/null \
  && ok "XML bien formé" || ko "XML cassé"
grep -q '<script>' "$JOB" && ko "le XML porte du Groovy inline (contrainte du GOAL)" || ok "XML sans Groovy (coquille from SCM)"
grep -F 'bash scripts/provision-apply-comment.sh' "$JF" | grep -qv '^\s*//' && ok "script appelé (Jenkinsfile)" || ko "rapport non câblé"
grep -q 'propagate: false' "$JF" && ok "propagate: false (l'échec de l'aval est VU, pas levé — le rapport part aussi sur échec)" || ko "pas de propagate: false — un échec aval sauterait le rapport"
grep -F 'bash scripts/provision-apply-comment.sh' "$JF" | grep -q '|| true' \
  && ok "|| true : une forge en panne ne rougit pas un apply vert" || ko "le rapport peut faire échouer un apply réussi"
grep -q 'error("Apply nominatif en échec' "$JF" && ok "l'échec réel est réaffirmé (error) après le rapport" || ko "un apply en échec finirait vert"
grep -q 'always {' "$JF" && ok "post { always } : statut build dans tous les cas" || ko "pas de post always"

echo
echo "== 9. les scripts sont syntaxiquement valides =="
for s in scripts/lib/gitea-pr-comment.sh scripts/provision-apply-comment.sh scripts/provision-request.sh scripts/provision-plan.sh; do
  bash -n "$REPO/$s" 2>/dev/null && ok "$(basename "$s")" || ko "$(basename "$s") — syntaxe"
done

echo
echo "== 10. TOUT script qui change de dossier résout son chemin AVANT =="
# Piège rencontré deux fois. Ces scripts se déplacent dans un clone jetable, puis
# appellent un voisin par chemin relatif — qui ne résout plus. Ça n'échoue qu'à
# l'EXÉCUTION, jamais à la lecture.
#
# La première version de ce cas ne vérifiait que provision-plan.sh. J'ai
# reproduit le bug dans provision-request.sh le lendemain, et le test est resté
# vert : une garde qui ne couvre qu'un fichier ne protège que ce fichier. Elle
# balaie maintenant TOUS les scripts qui font un `cd` et appellent un voisin.
for f in "$REPO"/scripts/provision-*.sh; do
  b=$(basename "$f")
  # concerné seulement si le script change de dossier ET invoque un autre script
  grep -qE '^\s*cd "\$' "$f" || continue
  # Filtre VOLONTAIREMENT large : « bash …quelque chose.sh ». Le premier jet
  # exigeait une forme de guillemets précise et EXCLUAIT donc exactement la
  # forme buguée — le fichier était SAUTÉ, et la suite restait verte sans le
  # correctif. Un filtre qui ne reconnaît pas le défaut qu'il traque ne garde
  # rien.
  grep -qE 'bash .*\.sh' "$f" || continue
  L_SELF=$(grep -n '^SELF_DIR=' "$f" | head -1 | cut -d: -f1)
  L_CD=$(grep -nE '^\s*cd "\$' "$f" | head -1 | cut -d: -f1)
  if [ -n "$L_SELF" ] && [ -n "$L_CD" ] && [ "$L_SELF" -lt "$L_CD" ]; then
    ok "$b : SELF_DIR (l.$L_SELF) avant cd (l.$L_CD)"
  else
    ko "$b : chemin résolu APRÈS le cd (ou absent) — self=$L_SELF cd=$L_CD"
  fi
  if grep -qE 'bash "\$\(cd "\$\(dirname' "$f"; then
    ko "$b : dirname évalué au moment de l'appel — cassera après le cd"
  else
    ok "$b : appel par chemin absolu mémorisé"
  fi
done

echo
echo "== 11. COMMENT_ONLY_IF_EXISTS=1 (A0 dettes) : met à jour un commentaire présent, n'en CRÉE jamais =="
startgitea tok-ok
printf 'statut vert\n' > "$TMP/b11"
OUT=$(GIT_REPO=ci/stoa-labs GITEA_TOKEN=tok-ok PR_NUMBER=7 GIT_HOST="$GH" COMMENT_MARKER='<!-- provision-plan-build -->' \
      COMMENT_BODY_FILE="$TMP/b11" COMMENT_ONLY_IF_EXISTS=1 bash "$LIB" 2>&1); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "COMMENT_SKIPPED" ] && [ "$(count)" = 0 ] \
  && ok "marqueur absent ⇒ COMMENT_SKIPPED, rc 0, ZÉRO commentaire créé" || ko "ONLY_IF_EXISTS a créé ou échoué (rc=$RC : $OUT, n=$(count))"
printf 'statut rouge perime\n' > "$TMP/b11r"
GIT_REPO=ci/stoa-labs GITEA_TOKEN=tok-ok PR_NUMBER=7 GIT_HOST="$GH" COMMENT_MARKER='<!-- provision-plan-build -->' COMMENT_BODY_FILE="$TMP/b11r" bash "$LIB" >/dev/null 2>&1
OUT=$(GIT_REPO=ci/stoa-labs GITEA_TOKEN=tok-ok PR_NUMBER=7 GIT_HOST="$GH" COMMENT_MARKER='<!-- provision-plan-build -->' \
      COMMENT_BODY_FILE="$TMP/b11" COMMENT_ONLY_IF_EXISTS=1 bash "$LIB" 2>&1); RC=$?
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^COMMENT_UPDATED' && [ "$(count)" = 1 ] && bodies | grep -q 'statut vert' \
  && ok "marqueur présent ⇒ COMMENT_UPDATED (le rouge périmé est effacé), toujours UN seul commentaire" || ko "ONLY_IF_EXISTS n'a pas mis à jour (rc=$RC : $OUT, n=$(count))"

echo
echo "== 12. PAGINATION (A0 dettes) : un marqueur en 55e position sur 60 est TROUVÉ, pas empilé =="
startgitea tok-ok
python3 - "$TMP/comments.json" <<'PY'
import json, sys
cs = [{"id": i, "body": f"bruit {i}"} for i in range(1, 61)]
cs[54]["body"] = "<!-- provision-plan -->\nancien verdict"
json.dump(cs, open(sys.argv[1], "w"))
PY
printf 'nouveau verdict\n' > "$TMP/b12"
OUT=$(GIT_REPO=ci/stoa-labs GITEA_TOKEN=tok-ok PR_NUMBER=7 GIT_HOST="$GH" COMMENT_MARKER='<!-- provision-plan -->' COMMENT_BODY_FILE="$TMP/b12" bash "$LIB" 2>&1); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "COMMENT_UPDATED 55" ] && [ "$(count)" = 60 ] \
  && ok "marqueur au-delà de la première page ⇒ COMMENT_UPDATED 55 (pagination), 60 commentaires, aucun empilement" \
  || ko "pagination cassée (rc=$RC : $OUT, n=$(count)) — le commentaire se serait EMPILÉ"
# Routage forge-agnostique (2026-09-09) : la lib ne fait plus d'appel réseau elle-même,
# elle passe par forge-api.sh (comment_find puis comment_upsert) ; le timeout réseau
# (FORGE_TIMEOUT, 30 s par défaut) vit dans forge-api.py, l'unique autorité.
grep -q 'forge_kv CU comment_upsert' "$LIB" && ! grep -vE '^\s*#' "$LIB" | grep -qE 'urllib|/api/v[14]|Authorization|python3' \
  && grep -q 'FORGE_TIMEOUT' "$REPO/scripts/lib/forge-api.py" && grep -q 'timeout=timeout' "$REPO/scripts/lib/forge-api.py" \
  && ok "forge_kv comment_upsert derrière forge-api.py (FORGE_TIMEOUT 30 s, sans urllib ni /api/v1 dans la lib) : un post{always} ne tient plus l'exécuteur indéfiniment sur une forge muette" \
  || ko "la lib compose encore un appel réseau en ligne, ou forge-api.py n'a plus de timeout"

echo
echo "== 12bis. PLAFOND serveur (revue 2026-09-02) : la forge écrête limit à 20, marqueur en 25e position ⇒ TROUVÉ (arrêt sur page VIDE, jamais sur « page courte ») =="
PAGE_CAP=20 startgitea tok-ok
python3 - "$TMP/comments.json" <<'PY'
import json, sys
cs = [{"id": i, "body": f"bruit {i}"} for i in range(1, 31)]
cs[24]["body"] = "<!-- provision-plan -->\nancien verdict"
json.dump(cs, open(sys.argv[1], "w"))
PY
printf 'nouveau verdict\n' > "$TMP/b12b"
OUT=$(GIT_REPO=ci/stoa-labs GITEA_TOKEN=tok-ok PR_NUMBER=7 GIT_HOST="$GH" COMMENT_MARKER='<!-- provision-plan -->' COMMENT_BODY_FILE="$TMP/b12b" bash "$LIB" 2>&1); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "COMMENT_UPDATED 25" ] && [ "$(count)" = 30 ] \
  && ok "plafond 20, marqueur en 25e ⇒ COMMENT_UPDATED 25, aucun empilement (une page pleine de 20 n'est PAS la dernière)" \
  || ko "plafond serveur : rc=$RC $OUT n=$(count) — le commentaire s'est EMPILÉ (arrêt sur page courte)"
unset PAGE_CAP

echo
echo "== 13. STOA_DEBUG=1 : la lib parle, sans fuite (plan L2) =="
# Gabarit D1/D2/D3 (test-vault-user-login.sh) : chaque ABSENCE (« tok-ok n'y est
# pas ») est DOUBLÉE d'une PRÉSENCE (la ligne attendue y est) — sinon une lib
# muette passerait toute absence. Flux SÉPARÉS : stdout est le PRODUIT
# (COMMENT_CREATED <id>, relu par l'appelant) — une ligne de debug qui y
# descendrait deviendrait une valeur. Le préfixe est le NOM DU SCRIPT ($0) :
# « [dbg gitea-pr-comment.sh] » ; les lignes HTTP portent « [dbg forge-api.py] ».
DBGP='[dbg gitea-pr-comment.sh] '
ligne_exacte(){ grep -qxF -- "${DBGP}$3" "$2" && ok "$1 stderr porte « ] $3 »" || ko "$1 stderr sans « ] $3 » ($(grep -c '\[dbg' "$2") ligne(s) [dbg)"; }
ligne_motif(){ grep -qE -- "$3" "$2" && ok "$1 stderr porte « $4 »" || ko "$1 stderr sans « $4 » ($(grep -c '\[dbg' "$2") ligne(s) [dbg)"; }
precede(){ local a b; a=$(grep -nE -m1 -- "$2" "$1" | cut -d: -f1); b=$(grep -nE -m1 -- "$3" "$1" | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; }
# run13 <stdout> <stderr> [VAR=val…] — la lib, flux séparés ; LIB13 = une copie mutée (13.5)
run13(){ local so="$1" se="$2"; shift 2; env GIT_REPO=ci/stoa-labs GITEA_TOKEN=tok-ok PR_NUMBER=7 GIT_HOST="$GH" COMMENT_MARKER='<!-- provision-plan -->' COMMENT_BODY_FILE="$TMP/b13.md" "$@" bash "${LIB13:-$LIB}" >"$so" 2>"$se"; }
startgitea tok-ok
printf 'corps debug\n' > "$TMP/b13.md"
run13 "$TMP/d13.so" "$TMP/d13.se" STOA_DEBUG=1; RC=$?
[ "$RC" -eq 0 ] && [ "$(cat "$TMP/d13.so")" = "COMMENT_CREATED 1" ] && [ "$(count)" = 1 ] \
  && ok "13.1 création sous STOA_DEBUG=1 ⇒ rc 0, stdout EXACTEMENT « COMMENT_CREATED 1 », un commentaire (le produit ne bouge pas)" \
  || ko "13.1 rc=$RC stdout=« $(tr '\n' '|' < "$TMP/d13.so" | cut -c1-120) » n=$(count)"
ligne_exacte 13.1a "$TMP/d13.se" 'FORGE_KIND=gitea'
ligne_exacte 13.1b "$TMP/d13.se" 'PR_NUMBER=7'
ligne_exacte 13.1c "$TMP/d13.se" 'COMMENT_MARKER=<!-- provision-plan -->'
ligne_exacte 13.1d "$TMP/d13.se" 'COMMENT_ONLY_IF_EXISTS=0'
ligne_motif 13.1e "$TMP/d13.se" '^\[dbg forge-api\.py\] GET [^ ]*/issues/7/comments[^ ]* -> HTTP 200 \([0-9]+ octets\)$' '[dbg forge-api.py] GET …/issues/7/comments… -> HTTP 200 (n octets) — la recherche du marqueur, paginée'
ligne_motif 13.1f "$TMP/d13.se" '^\[dbg forge-api\.py\] POST [^ ]*/issues/7/comments -> HTTP 201 \([0-9]+ octets\)$' '[dbg forge-api.py] POST …/issues/7/comments -> HTTP 201 (n octets)'
ligne_exacte 13.1g "$TMP/d13.se" 'CU_ACTION=created'
ligne_exacte 13.1h "$TMP/d13.se" 'CU_ID=1'
grep -qF 'tok-ok' "$TMP/d13.so" "$TMP/d13.se" && ko "13.1i le token FUITE : $(grep -hF tok-ok "$TMP/d13.so" "$TMP/d13.se" | head -1 | cut -c1-160)" || ok "13.1i tok-ok absent de stdout ET de stderr"

# 13.2 — la forge qui refuse le token (fixture du §4) : le statut PRÉCÈDE le verdict.
startgitea autre-token
run13 "$TMP/d13b.so" "$TMP/d13b.se" STOA_DEBUG=1; RC=$?
[ "$RC" -ne 0 ] && [ ! -s "$TMP/d13b.so" ] && precede "$TMP/d13b.se" '^\[dbg forge-api\.py\] GET [^ ]*/issues/7/comments[^ ]* -> HTTP 401 ' '^COMMENT_FAILED' \
  && ok "13.2 forge qui refuse le token sous STOA_DEBUG=1 ⇒ rc $RC, stdout VIDE, « GET … -> HTTP 401 » PRÉCÈDE « COMMENT_FAILED » (le statut d'abord, le verdict ensuite)" \
  || ko "13.2 rc=$RC : $(grep -nE 'HTTP 401|COMMENT_FAILED' "$TMP/d13b.se" | head -3 | tr '\n' ' ' | cut -c1-200)"
grep -qF 'tok-ok' "$TMP/d13b.so" "$TMP/d13b.se" && ko "13.2a le token FUITE dans le refus : $(grep -hF tok-ok "$TMP/d13b.se" | head -1 | cut -c1-160)" || ok "13.2a tok-ok absent, refus compris (un secret refusé reste un secret)"

# 13.3 — le silence : STOA_DEBUG=0 ⇒ zéro [dbg, même produit.
startgitea tok-ok
run13 "$TMP/d13c.so" "$TMP/d13c.se" STOA_DEBUG=0; RC=$?
[ "$RC" -eq 0 ] && [ "$(cat "$TMP/d13c.so")" = "COMMENT_CREATED 1" ] && [ "$(cat "$TMP/d13c.so" "$TMP/d13c.se" | grep -c '\[dbg')" = 0 ] \
  && ok "13.3 STOA_DEBUG=0 ⇒ rc 0, « COMMENT_CREATED 1 », ZÉRO ligne « [dbg » (shell et python muets ensemble)" \
  || ko "13.3 rc=$RC lignes [dbg=$(cat "$TMP/d13c.so" "$TMP/d13c.se" | grep -c '\[dbg') stdout=« $(head -1 "$TMP/d13c.so") »"

# 13.4 — ONLY_IF_EXISTS sans marqueur : le VIDE se dit (CF_ID=<vide>), c'est pourquoi rien n'est créé.
startgitea tok-ok
run13 "$TMP/d13d.so" "$TMP/d13d.se" STOA_DEBUG=1 COMMENT_ONLY_IF_EXISTS=1; RC=$?
[ "$RC" -eq 0 ] && [ "$(cat "$TMP/d13d.so")" = COMMENT_SKIPPED ] && [ "$(count)" = 0 ] && grep -qxF "${DBGP}COMMENT_ONLY_IF_EXISTS=1" "$TMP/d13d.se" && grep -qxF "${DBGP}CF_ID=<vide>" "$TMP/d13d.se" \
  && ok "13.4 ONLY_IF_EXISTS sans marqueur sous debug ⇒ COMMENT_SKIPPED inchangé, « ] COMMENT_ONLY_IF_EXISTS=1 » et « ] CF_ID=<vide> » (le vide se DIT : c'est la raison du SKIPPED)" \
  || ko "13.4 rc=$RC stdout=« $(head -1 "$TMP/d13d.so") » : $(grep -E 'ONLY_IF_EXISTS|CF_ID' "$TMP/d13d.se" | tr '\n' ' ' | cut -c1-160)"

# 13.5 — MUTATION sur COPIE : dbg_kv CU_ACTION → echo (stdout) ⇒ le produit est
# pollué, 13.1 rougit. La copie vit dans un faux scripts/lib (forge-api liée, ci
# lié) : elle source ses voisines par $(dirname "${BASH_SOURCE[0]}") — tout
# résout sans rien poser dans l'arbre. Un mutant identique est un ko.
MUTL="$TMP/mut/scripts/lib"; mkdir -p "$MUTL"; ln -s "$REPO/scripts/lib/forge-api.sh" "$REPO/scripts/lib/forge-api.py" "$MUTL/"; ln -s "$REPO/ci" "$TMP/mut/ci"
# shellcheck disable=SC2016  # motif sed : « ${CU_ACTION:-} » est celui du script muté, le mutant l'écrit sur stdout
sed 's/^dbg_kv CU_ACTION "\${CU_ACTION:-}"$/echo "CU_ACTION=${CU_ACTION:-}"/' "$LIB" > "$MUTL/gitea-pr-comment.sh"
if ! cmp -s "$LIB" "$MUTL/gitea-pr-comment.sh"; then
  startgitea tok-ok
  LIB13="$MUTL/gitea-pr-comment.sh" run13 "$TMP/d13e.so" "$TMP/d13e.se" STOA_DEBUG=1; RC=$?
  [ "$RC" -eq 0 ] && [ "$(wc -l < "$TMP/d13e.so" | tr -d ' ')" = 2 ] && grep -qx 'CU_ACTION=created' "$TMP/d13e.so" && grep -qx 'COMMENT_CREATED 1' "$TMP/d13e.so" \
    && ok "13.5 dbg_kv CU_ACTION → echo : rc 0 mais stdout porte DEUX lignes (CU_ACTION=created puis COMMENT_CREATED 1) — 13.1 tient à ce que le debug reste sur stderr" \
    || ko "13.5 stdout du mutant : $(wc -l < "$TMP/d13e.so" | tr -d ' ') ligne(s) (rc=$RC)"
else ko "13.5 mutation impossible (motif introuvable) — mutant no-op"; fi

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
