#!/usr/bin/env bash
# test-setup-provision-jobs.sh — preuve X/X de setup-provision-jobs.sh contre un
# FAUX Jenkins. Ni instance réelle, ni identifiants.
#
# CE QUE CE TEST DÉFEND. Ce script s'exécute contre un Jenkins de production. Ses
# deux propriétés dangereuses doivent être verrouillées : il ne doit JAMAIS
# supprimer un job sans qu'on le lui demande (l'historique des apply nominatifs
# est une trace d'audit), et il ne doit JAMAIS envoyer un XML cassé.
#
#   ./scripts/test-setup-provision-jobs.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
S="$REPO/scripts/setup-provision-jobs.sh"
TMP="$(mktemp -d /tmp/setupjobs.XXXXXX)"
PORT="${FAKE_JENKINS_PORT:-18400}"
PID=""
cleanup(){ [ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# ── faux Jenkins : journalise CHAQUE appel dans un fichier ───────────────────
cat > "$TMP/fakejenkins.py" <<'PY'
import json, os, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
LOG = os.environ["CALLLOG"]
EXISTING = set(filter(None, os.environ.get("EXISTING_JOBS", "").split(",")))
UPDATE_CODE = int(os.environ.get("UPDATE_CODE", "200"))
NEED_AUTH = os.environ.get("NEED_AUTH", "") == "1"
CRUMB_CODE = int(os.environ.get("CRUMB_CODE", "200"))   # 302 = portail devant Jenkins
NEED_CF = os.environ.get("NEED_CF", "") == "1"          # exige le service token
def log(line):
    with open(LOG, "a") as f: f.write(line + "\n")
class H(BaseHTTPRequestHandler):
    def _authok(self):
        if NEED_CF and not self.headers.get("CF-Access-Client-Id"): return False
        if not NEED_AUTH: return True
        return (self.headers.get("Authorization") or "").startswith("Basic ")
    def _send(self, code, body=b"{}"):
        self.send_response(code); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if not self._authok(): return self._send(401)
        if self.path.startswith("/crumbIssuer"):
            log("GET crumb")
            if CRUMB_CODE != 200:
                # Un portail redirige AVANT que Jenkins ne voie la requete.
                b = b""
                self.send_response(CRUMB_CODE)
                self.send_header("Location", "https://stoa-platform.cloudflareaccess.com/cdn-cgi/access/login/x")
                self.send_header("Content-Length", "0"); self.end_headers(); return
            return self._send(200, json.dumps({"crumbRequestField": "Jenkins-Crumb", "crumb": "abc"}).encode())
        m = re.match(r"^/job/([^/]+)/api/json$", self.path)
        if m:
            present = m.group(1) in EXISTING
            log(f"GET exists {m.group(1)} -> {200 if present else 404}")
            return self._send(200 if present else 404)
        self._send(404)
    def do_POST(self):
        if not self._authok(): return self._send(401)
        n = int(self.headers.get("Content-Length", 0))
        if n: self.rfile.read(n)
        if re.match(r"^/job/[^/]+/config\.xml$", self.path):
            # Le VRAI Jenkins parse le corps en ISO-8859-1 quand le charset n'est
            # pas declare, et rend 500 des le premier caractere accentue. On
            # reproduit ce refus : sinon le test validerait un script qui echoue
            # en production sur des descriptions francaises.
            ct = (self.headers.get("Content-Type") or "").lower()
            if "charset=utf-8" not in ct:
                log("POST update NO-CHARSET " + self.path); return self._send(500)
            log("POST update " + self.path); return self._send(UPDATE_CODE)
        if re.match(r"^/job/[^/]+/doDelete$", self.path):
            log("POST DELETE " + self.path); return self._send(200)
        if self.path.startswith("/createItem"):
            log("POST create " + self.path); return self._send(200)
        self._send(404)
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

start(){ # $1=jobs existants (csv) $2=code MAJ $3=auth(0/1) $4=code crumb $5=CF requis(0/1)
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  : > "$TMP/calls.log"
  CALLLOG="$TMP/calls.log" EXISTING_JOBS="$1" UPDATE_CODE="$2" NEED_AUTH="${3:-0}" \
  CRUMB_CODE="${4:-200}" NEED_CF="${5:-0}" \
    python3 "$TMP/fakejenkins.py" "$PORT" >/dev/null 2>&1 &
  PID=$!
  for _ in $(seq 1 40); do curl -s "http://127.0.0.1:$PORT/x" >/dev/null 2>&1 && return; sleep 0.1; done
}
calls(){ cat "$TMP/calls.log" 2>/dev/null; }
JU="http://127.0.0.1:$PORT"

echo "== 1. job EXISTANT : mis à jour EN PLACE, jamais supprimé =="
start "provision-apply,provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" bash "$S" 2>&1); RC=$?
[ $RC -eq 0 ] && ok "succès" || ko "échec (rc=$RC) : $OUT"
[ "$(calls | grep -c 'POST update')" = "2" ] && ok "2 mises à jour en place" || ko "mises à jour manquantes"
calls | grep -q 'POST DELETE' && ko "UN JOB A ÉTÉ SUPPRIMÉ — historique d'audit perdu" || ok "aucune suppression"
calls | grep -q 'POST create' && ko "création alors que le job existait" || ok "aucune création superflue"

echo
echo "== 2. job ABSENT : créé =="
start "" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-apply bash "$S" 2>&1); RC=$?
[ $RC -eq 0 ] && ok "succès" || ko "échec (rc=$RC)"
calls | grep -q 'POST create' && ok "createItem appelé" || ko "job non créé"
calls | grep -q 'POST DELETE' && ko "suppression sur un job absent" || ok "aucune suppression"

echo
echo "== 3. mise à jour REFUSÉE : le job reste INCHANGÉ (pas de repli destructeur) =="
start "provision-apply" 500
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-apply bash "$S" 2>&1); RC=$?
[ $RC -ne 0 ] && ok "écart signalé (rc=$RC)" || ko "échec masqué"
calls | grep -q 'POST DELETE' && ko "delete+create SILENCIEUX — irréversible et non demandé" || ok "aucune suppression sans demande"
grep -q "ALLOW_RECREATE=true" <<<"$OUT" && ok "la sortie dit comment forcer, et ce que ça coûte" || ko "aucune issue proposée"

echo
echo "== 4. ALLOW_RECREATE=true : le repli devient possible, et il est ANNONCÉ =="
start "provision-apply" 500
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-apply ALLOW_RECREATE=true bash "$S" 2>&1); RC=$?
calls | grep -q 'POST DELETE' && ok "suppression effectuée (explicitement demandée)" || ko "repli non effectué"
calls | grep -q 'POST create' && ok "job recréé" || ko "recréation absente"
grep -q "historique sera PERDU" <<<"$OUT" && ok "le coût est annoncé avant" || ko "destruction silencieuse"

echo
echo "== 5. DRY_RUN : aucune écriture =="
start "provision-apply,provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" DRY_RUN=true bash "$S" 2>&1); RC=$?
[ $RC -eq 0 ] && ok "succès" || ko "échec (rc=$RC)"
if calls | grep -qE 'POST (update|create|DELETE)'; then ko "DRY_RUN a écrit !"; else ok "aucune écriture"; fi
grep -q "serait MIS À JOUR" <<<"$OUT" && ok "annonce ce qui serait fait" || ko "dry-run muet"

echo
echo "== 6. XML cassé : refusé AVANT tout appel réseau =="
start "provision-apply" 200
cp "$REPO/ci/jenkins/provision-apply.job.xml" "$TMP/backup.xml"
printf '<flow-definition><oops>\n' > "$REPO/ci/jenkins/provision-apply.job.xml"
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-apply bash "$S" 2>&1); RC=$?
cp "$TMP/backup.xml" "$REPO/ci/jenkins/provision-apply.job.xml"
[ $RC -ne 0 ] && ok "refusé" || ko "XML cassé envoyé à Jenkins"
[ -z "$(calls | grep -E 'POST')" ] && ok "aucune écriture tentée" || ko "des écritures ont eu lieu malgré l'XML cassé"
grep -q "rien n'a été envoyé" <<<"$OUT" && ok "le message le dit" || ko "message ambigu"

echo
echo "== 7. identifiants : transmis, et jamais imprimés =="
start "provision-apply" 200 1
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JENKINS_USER=alice JENKINS_TOKEN='s3cr3t-token' JOBS=provision-apply bash "$S" 2>&1); RC=$?
[ $RC -eq 0 ] && ok "authentification acceptée par la cible" || ko "auth non transmise (rc=$RC)"
grep -q 's3cr3t-token' <<<"$OUT" && ko "LE TOKEN FUITE dans la sortie" || ok "aucune fuite du token"
grep -q 'alice' <<<"$OUT" && ok "l'identité utilisée est affichée (traçabilité)" || ko "identité non affichée"

echo
echo "== 8. portail devant Jenkins : diagnostic qui dit QUOI fournir =="
# Le cas réellement rencontré : jenkins.labs.gostoa.dev répond 302 vers
# Cloudflare Access. Sans ce diagnostic, le script échouait plus loin sur un
# JSON vide, avec un message qui envoyait chercher la panne ailleurs.
start "provision-apply" 200 0 302
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-apply bash "$S" 2>&1); RC=$?
[ $RC -ne 0 ] && ok "refusé" || ko "a continué malgré la redirection"
grep -q "portail" <<<"$OUT" && ok "le portail est nommé" || ko "diagnostic générique"
grep -q "CF_ACCESS_CLIENT_ID" <<<"$OUT" && ok "dit quoi fournir" || ko "aucune issue proposée"
[ -z "$(calls | grep -E 'POST')" ] && ok "aucune écriture tentée" || ko "écritures malgré le portail"

echo
echo "== 9. service token Cloudflare : en-têtes transmis, secret jamais imprimé =="
start "provision-apply" 200 0 200 1
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-apply \
      CF_ACCESS_CLIENT_ID='cf-id.access' CF_ACCESS_CLIENT_SECRET='cf-s3cr3t' bash "$S" 2>&1); RC=$?
[ $RC -eq 0 ] && ok "le portail laisse passer" || ko "en-têtes CF non transmis (rc=$RC)"
grep -q 'cf-s3cr3t' <<<"$OUT" && ko "LE SECRET CF FUITE dans la sortie" || ok "aucune fuite du secret CF"
grep -q 'service token Cloudflare Access fourni' <<<"$OUT" && ok "présence annoncée" || ko "silencieux"

echo
echo "== 10. les secrets ne passent PAS par argv (visibles dans ps) =="
# `-u user:token` et `-H "CF-Access-Client-Secret: ..."` seraient visibles de
# tout utilisateur de la machine le temps de l'appel. Tout doit passer par
# `curl -K -` (entrée standard).
CODE=$(grep -vE '^\s*#' "$S")
grep -qE 'curl .*-u "?\$\{?JENKINS' <<<"$CODE" && ko "-u en argv" || ok "aucun -u en argv"
grep -qE '\-H "CF-Access-Client-Secret' <<<"$CODE" && ko "en-tête CF en argv" || ok "aucun en-tête CF en argv"
grep -q 'curl -K -' "$S" && ok "configuration passée par l'entrée standard" || ko "curl -K - absent"

echo
echo "== 11. le charset UTF-8 est déclaré (sinon Jenkins casse sur les accents) =="
start "provision-apply" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-apply bash "$S" 2>&1); RC=$?
[ $RC -eq 0 ] && ok "accepté par une cible exigeant le charset" || ko "charset absent — 500 sur le 1er accent (rc=$RC)"
calls | grep -q 'NO-CHARSET' && ko "un POST est parti sans charset" || ok "aucun POST sans charset"
grep -c 'charset=utf-8' "$S" | grep -qvE '^[01]$' && ok "déclaré sur TOUS les envois de config" || ko "déclaré partiellement"

echo
echo "== 12. setup-provision-request-job.sh ne DÉTRUIT plus son job =="
# Il faisait un delete+create inconditionnel — donc perdait l'historique de
# builds a chaque execution — au motif que « le POST config.xml peut 500 ». Ce
# 500 etait le defaut de charset, pas une fatalite du produit.
R="$REPO/scripts/setup-provision-request-job.sh"
CODE_R=$(grep -vE '^\s*#' "$R")
grep -qE 'job/\$JOB/doDelete' <<<"$CODE_R" \
  && ko "doDelete inconditionnel toujours present" || ok "aucune suppression inconditionnelle du job"
grep -q 'setup-provision-jobs.sh' <<<"$CODE_R" \
  && ok "delegue a la logique partagee" || ko "logique dupliquee ou absente"
bash -n "$R" 2>/dev/null && ok "syntaxe valide" || ko "syntaxe cassee"

echo
echo "== 13. instance injoignable : échec net =="
OUT=$(cd "$REPO" && JENKINS_UI="http://127.0.0.1:1" JOBS=provision-apply bash "$S" 2>&1); RC=$?
[ $RC -ne 0 ] && grep -q "injoignable" <<<"$OUT" && ok "diagnostic explicite" || ko "échec silencieux ou obscur"

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
