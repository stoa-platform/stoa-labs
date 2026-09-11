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
#
# Directives shellcheck de CE HARNAIS (porte de l'étape 2 de lint-ci) :
#   SC2015 — `cond && ok "…" || ko "…"` est l'idiome des harnais du dépôt :
#            ok() finit par printf, rc 0, donc ko ne court jamais après un ok.
#   SC2143 — `[ -z "$(calls | grep …)" ]` lit l'ABSENCE d'appel dans le journal
#            du faux Jenkins : c'est ce journal qui est le sujet de l'assertion.
# shellcheck disable=SC2015,SC2143
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

# L3 (2026-09-10) : le poseur substitue __GIT_BASE__ dans les XML, et il exige
# donc une branche — knob, ou HEAD d'un dépôt joignable, ou refus nommé. Les
# quatorze sections ci-dessous mesurent le dialogue avec JENKINS, pas la
# branche : on leur pose le knob une fois pour toutes (aucun réseau : la lib ne
# consulte alors aucune HEAD). La branche elle-même est éprouvée en §15, contre
# un dépôt nu, SANS knob — c'est là qu'est le discriminant.
export GIT_BASE=master

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
BUILD_CODE = int(os.environ.get("BUILD_CODE", "201"))   # reponse a POST /job/<j>/build (A0)
BODYDIR = os.environ.get("BODYDIR", "")                 # L3 : on GARDE le XML recu, pour le relire
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
        m = re.match(r"^/job/([^/]+)/api/json", self.path)
        if m:
            present = m.group(1) in EXISTING
            log(f"GET exists {m.group(1)} -> {200 if present else 404}")
            # nextBuildNumber : le poseur le relève AVANT de lancer l'amorcage,
            # pour savoir QUEL build attendre (L6).
            return self._send(200 if present else 404, json.dumps({"nextBuildNumber": 7}).encode())
        m = re.match(r"^/job/([^/]+)/7/api/json", self.path)
        if m:   # L6 : le build d'amorcage. BUILD_RESULT vide = ENCORE EN COURS.
            log(f"GET build {m.group(1)} 7")
            return self._send(200, json.dumps({"result": os.environ.get("BUILD_RESULT", "SUCCESS") or None}).encode())
        m = re.match(r"^/job/([^/]+)/config\.xml$", self.path)
        if m:   # L6 : la RELECTURE d'apres l'amorcage. RELU_XML = ce qu'on sert.
            log(f"GET config {m.group(1)}")
            p = os.environ.get("RELU_XML", "")
            body = open(p, "rb").read() if p else b"<flow-definition><properties/></flow-definition>"
            # __JOB__ → le nom du job : un seul gabarit sert les deux jobs, dont
            # les tokens attendus diffèrent (stoa-provision-plan / -apply).
            return self._send(200, body.replace(b"__JOB__", m.group(1).encode()))
        self._send(404)
    def do_POST(self):
        if not self._authok(): return self._send(401)
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n) if n else b""
        if re.match(r"^/job/[^/]+/config\.xml$", self.path):
            # Le VRAI Jenkins parse le corps en ISO-8859-1 quand le charset n'est
            # pas declare, et rend 500 des le premier caractere accentue. On
            # reproduit ce refus : sinon le test validerait un script qui echoue
            # en production sur des descriptions francaises.
            ct = (self.headers.get("Content-Type") or "").lower()
            if "charset=utf-8" not in ct:
                log("POST update NO-CHARSET " + self.path); return self._send(500)
            log("POST update " + self.path)
            if BODYDIR:
                open(os.path.join(BODYDIR, re.match(r"^/job/([^/]+)/", self.path).group(1) + ".posted.xml"), "wb").write(body)
            return self._send(UPDATE_CODE)
        if re.match(r"^/job/[^/]+/doDelete$", self.path):
            log("POST DELETE " + self.path); return self._send(200)
        mb = re.match(r"^/job/([^/]+)/build$", self.path)
        if mb:
            # A0 : build d'AMORCAGE. 201 = accepte (job sans parametre) ;
            # 400 = le vrai Jenkins refuse POST /build sur un job PARAMETRE (mesure).
            log("POST build " + mb.group(1)); return self._send(BUILD_CODE)
        if self.path.startswith("/createItem"):
            log("POST create " + self.path)
            if BODYDIR:
                open(os.path.join(BODYDIR, re.search(r"name=([^&]+)", self.path).group(1) + ".posted.xml"), "wb").write(body)
            return self._send(200)
        self._send(404)
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

start(){ # $1=jobs existants (csv) $2=code MAJ $3=auth(0/1) $4=code crumb $5=CF requis(0/1)
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  : > "$TMP/calls.log"
  CALLLOG="$TMP/calls.log" EXISTING_JOBS="$1" UPDATE_CODE="$2" NEED_AUTH="${3:-0}" BODYDIR="${BODYDIR:-}" \
  CRUMB_CODE="${4:-200}" NEED_CF="${5:-0}" BUILD_CODE="${BUILD_CODE:-201}" \
  BUILD_RESULT="${BUILD_RESULT-SUCCESS}" RELU_XML="${RELU_XML:-}" \
    python3 "$TMP/fakejenkins.py" "$PORT" >/dev/null 2>&1 &
  PID=$!
  for _ in $(seq 1 40); do curl -s "http://127.0.0.1:$PORT/x" >/dev/null 2>&1 && return; sleep 0.1; done
}
calls(){ cat "$TMP/calls.log" 2>/dev/null; }
JU="http://127.0.0.1:$PORT"
# relu <n GenericTrigger> <n GitLabPushTrigger> <n DisableConcurrentBuilds> <token> → chemin
# du config.xml que le faux Jenkins servira APRÈS l'amorçage. C'est le seul
# levier de la §16 : 1/0/1 = nominal gwt, 0/1/1 = nominal gitlab, 2/0/1 =
# doublon (fait 10), 0/0/0 = job muet.
# ⚠ JAMAIS `for i in $(seq 1 "$n")` pour répéter n fois quand n peut valoir 0 :
# le seq de BSD/macOS rend « 1 0 » (DEUX valeurs) là où celui de GNU n'en rend
# aucune — mesuré le 2026-09-11, la ligne « 0 GitLabPushTrigger » en écrivait
# deux et la §16 accusait le poseur de compter faux.
rep(){ local n="$1"; shift; local i=0; while [ "$i" -lt "$n" ]; do printf '%s\n' "$*"; i=$((i+1)); done; }
relu(){
  # Le nom du fichier porte AUSSI le token : sinon un appel d'une section écrase
  # le gabarit servi à une autre (mesuré le 2026-09-11 — §14 posait le token de
  # provision-plan dans le fichier que §15 servait à provision-apply, et la
  # relecture refusait à juste titre un token qui n'était pas le sien).
  local f slug
  slug=$(printf '%s' "$4" | tr -c 'A-Za-z0-9_-' '_')
  f="$TMP/relu-$1-$2-$3-$slug.xml"
  { echo '<flow-definition><properties>'
    rep "$3" '<org.jenkinsci.plugins.workflow.job.properties.DisableConcurrentBuildsJobProperty/>'
    if [ "$1$2" != 00 ]; then
      echo '<org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty><triggers>'
      rep "$1" "<org.jenkinsci.plugins.gwt.GenericTrigger><token>$4</token></org.jenkinsci.plugins.gwt.GenericTrigger>"
      rep "$2" '<com.dabsquared.gitlabjenkins.GitLabPushTrigger><secretToken>x</secretToken></com.dabsquared.gitlabjenkins.GitLabPushTrigger>'
      echo '</triggers></org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>'
    fi
    echo '</properties></flow-definition>'; } > "$f"
  printf '%s' "$f"
}
# Depuis L6 le poseur amorce et RELIT par défaut : chaque section de cette suite
# traverse donc la relecture. On sert un config.xml NOMINAL par défaut (1 trigger
# de la classe gwt au nom du job, 1 option) ; §16 le surcharge pour éprouver les
# refus. Sans ce défaut, les quatorze sections d'avant L6 rougiraient sur une
# relecture qu'elles ne mesurent pas.
RELU_XML="$(relu 1 0 1 'stoa-__JOB__')"; export RELU_XML

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
grep -q 'Portail : service token' <<<"$OUT" && ok "présence annoncée" || ko "silencieux"

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
# shellcheck disable=SC2016  # `\$JOB` est le MOTIF cherché DANS le script livré, jamais une expansion
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
echo "== 14. BOOTSTRAP_JOBS (A0) : le build d'amorçage suit la pose — et seulement elle =="
# app-request pose son formulaire depuis son Jenkinsfile ; re-poser son XML
# EFFACE les paramètres (mesuré 2026-09-02). Le poseur doit donc amorcer d'un
# build les jobs qu'on lui nomme, APRÈS une pose réussie, jamais en dry-run,
# jamais sans demande — et dire si Jenkins refuse (400 = déjà paramétré).
RELU_XML="$(relu 1 0 1 stoa-provision-plan)" start "provision-apply,provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" BOOTSTRAP_JOBS=provision-plan bash "$S" 2>&1); RC=$?
[ $RC -eq 0 ] && ok "succès avec BOOTSTRAP_JOBS" || ko "échec (rc=$RC) : $OUT"
[ "$(calls | grep -c 'POST build provision-plan')" = "1" ] && ok "UN build d'amorçage demandé pour le job nommé" || ko "amorçage absent ou répété : $(calls | grep -c 'POST build')"
calls | grep -q 'POST build provision-apply' && ko "amorçage sur un job NON nommé" || ok "aucun amorçage sur le job non nommé"
L_POSE=$(calls | grep -n 'POST update /job/provision-plan' | cut -d: -f1); L_BOOT=$(calls | grep -n 'POST build provision-plan' | cut -d: -f1)
[ -n "$L_POSE" ] && [ -n "$L_BOOT" ] && [ "$L_POSE" -lt "$L_BOOT" ] && ok "l'amorçage vient APRÈS la pose (appels $L_POSE puis $L_BOOT)" || ko "ordre pose/amorçage cassé (pose=$L_POSE boot=$L_BOOT)"
{ grep -q "amorçage #7 : SUCCESS" <<<"$OUT" && grep -q 'relecture : 1 trigger' <<<"$OUT"; } \
  && ok "annoncé dans la sortie, et pas seulement « déclenché » : l'amorçage est ATTENDU puis RELU (L6)" \
  || ko "amorçage muet ou non relu : $(grep -E 'amorçage|relecture' <<<"$OUT" | tr '\n' ' ')"
RELU_XML="$(relu 1 0 1 stoa-provision-plan)" start "provision-apply,provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" bash "$S" 2>&1); RC=$?
[ "$(calls | grep -c 'POST build')" = 2 ] \
  && ok "sans BOOTSTRAP_JOBS : les DEUX jobs posés sont amorcés (défaut L6 — un job posé sans amorçage est un job MUET : ses propriétés ne sont posées que par son premier build)" \
  || ko "défaut BOOTSTRAP_JOBS : $(calls | grep -c 'POST build') build(s) demandé(s), attendu 2"
start "provision-apply,provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" BOOTSTRAP_JOBS=none bash "$S" 2>&1); RC=$?
calls | grep -q 'POST build' && ko "BOOTSTRAP_JOBS=none a tout de même amorcé" \
  || ok "BOOTSTRAP_JOBS=none : aucun build demandé (le MOT, parce qu'une valeur VIDE n'atteint pas le shell depuis Jenkins)"
RELU_XML="$(relu 1 0 1 stoa-provision-plan)" start "provision-apply,provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" DRY_RUN=true BOOTSTRAP_JOBS=provision-plan bash "$S" 2>&1); RC=$?
calls | grep -q 'POST build' && ko "DRY_RUN a amorcé un build !" || ok "DRY_RUN : aucun build demandé"
grep -q "serait AMORCÉ" <<<"$OUT" && ok "DRY_RUN annonce l'amorçage qui serait fait" || ko "DRY_RUN muet sur l'amorçage"
start "provision-plan" 500
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-plan BOOTSTRAP_JOBS=provision-plan bash "$S" 2>&1); RC=$?
calls | grep -q 'POST build' && ko "amorçage tenté alors que la POSE a échoué" || ok "pose refusée ⇒ amorçage NON tenté (et dit)"
grep -q "amorçage NON tenté" <<<"$OUT" && ok "le refus d'amorçage est nommé" || ko "refus d'amorçage muet"
BUILD_CODE=400 RELU_XML="$(relu 1 0 1 stoa-provision-plan)" start "provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-plan BOOTSTRAP_JOBS=provision-plan bash "$S" 2>&1); RC=$?
[ $RC -ne 0 ] && grep -q "DÉJÀ paramétré" <<<"$OUT" && ok "Jenkins répond 400 ⇒ échec du run, nommé « déjà paramétré » (jamais silencieux)" || ko "400 sur l'amorçage avalé (rc=$RC)"

echo
echo "== 15. la BRANCHE du <scm> : substituée à la pose, DÉCOUVERTE quand aucun knob ne la nomme =="
# Les treize job.xml portent `__GIT_BASE__` et ne nomment plus aucune branche.
# DISCRIMINANT : un dépôt nu dont la HEAD est `develop`, AUCUN GIT_BASE dans
# l'environnement du poseur. Un poseur qui devinerait poserait « main » et cette
# section rougirait ; il doit poser ce que le dépôt annonce.
BODYDIR="$TMP/bodies"; mkdir -p "$BODYDIR"
NU="$TMP/forge/depot.git"; W="$TMP/forge/w"; mkdir -p "$TMP/forge"
git init -q --bare "$NU" && git -C "$NU" symbolic-ref HEAD refs/heads/develop
git init -q "$W" && git -C "$W" checkout -q -b develop && : > "$W/x" && git -C "$W" add x \
  && git -C "$W" -c user.email=t@t -c user.name=t commit -qm x \
  && git -C "$W" remote add origin "$NU" && git -C "$W" push -q origin develop
start "provision-apply" 200
OUT=$(cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" JENKINS_UI="$JU" JOBS=provision-apply \
      GIT_HOST="$TMP/forge" GIT_REPO=depot bash "$S" 2>&1); RC=$?
POSTE="$BODYDIR/provision-apply.posted.xml"
[ $RC -eq 0 ] && ok "pose SANS GIT_BASE : la HEAD du dépôt suffit" || ko "pose sans knob en échec (rc=$RC) : $(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')"
grep -qF '<name>*/develop</name>' "$POSTE" 2>/dev/null \
  && ok "le XML POSTÉ vise */develop — la branche vient de la HEAD annoncée, pas d'un littéral" \
  || ko "le XML posté ne vise pas */develop : $(grep -o '<name>[^<]*</name>' "$POSTE" 2>/dev/null | head -2 | tr '\n' ' ')"
grep -qF '__GIT_BASE__' "$POSTE" 2>/dev/null \
  && ko "le placeholder __GIT_BASE__ survit dans le XML POSTÉ — Jenkins chercherait une branche de ce nom" \
  || ok "aucun __GIT_BASE__ dans le XML posté (substitution fail-closed)"
if sed 's#__GIT_BASE__#develop#g' "$REPO/ci/jenkins/provision-apply.job.xml" | cmp -s - "$POSTE"; then
  ok "et le XML posté est la SOURCE, à cette seule substitution près (octet pour octet)"
else
  ko "le XML posté diffère de la source substituée — la mise en scène touche autre chose que la branche"
fi
# … le knob explicite gagne sur la HEAD.
rm -f "$POSTE"; start "provision-apply" 200
OUT=$(cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" JENKINS_UI="$JU" JOBS=provision-apply \
      GIT_HOST="$TMP/forge" GIT_REPO=depot GIT_BASE=master bash "$S" 2>&1); RC=$?
[ $RC -eq 0 ] && grep -qF '<name>*/master</name>' "$POSTE" 2>/dev/null \
  && ok "GIT_BASE=master (knob explicite) GAGNE sur la HEAD develop du dépôt" \
  || ko "le knob ne gagne pas : rc=$RC, $(grep -o '<name>[^<]*</name>' "$POSTE" 2>/dev/null | head -2 | tr '\n' ' ')"
# … et sans rien pour décider, RIEN n'est envoyé.
rm -f "$POSTE"; start "provision-apply" 200
# … et sans rien pour décider, RIEN n'est envoyé — et le refus NOMME les knobs
# que CET exploitant a sous la main. La lib, elle, parlerait de « l'argument de
# git_base_init » et de GIT_CLONE_URL : deux choses qui n'existent pas pour
# quelqu'un qui pose des jobs depuis son poste (revue 4c).
OUT=$(cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" JENKINS_UI="$JU" JOBS=provision-apply bash "$S" 2>&1); RC=$?
[ $RC -ne 0 ] && grep -q 'BRANCHE_PAR_DEFAUT_INDECIDABLE' <<<"$OUT" \
  && ok "ni knob ni dépôt à interroger ⇒ refus BRANCHE_PAR_DEFAUT_INDECIDABLE (jamais un « main » de repli)" \
  || ko "sans branche décidable : rc=$RC — $(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')"
MANQUE=""
for K in GIT_BASE GIT_HOST GIT_REPO; do grep -q "$K" <<<"$OUT" || MANQUE="$MANQUE $K"; done
[ -z "$MANQUE" ] \
  && ok "le refus NOMME les trois knobs à poser (GIT_BASE, GIT_HOST, GIT_REPO) — pas GIT_CLONE_URL, que l'exploitant n'a pas" \
  || ko "knobs absents du refus :$MANQUE — $(printf '%s' "$OUT" | tail -1)"
grep -q 'GIT_CLONE_URL' <<<"$OUT" \
  && ko "le refus parle encore de GIT_CLONE_URL — une variable que ce poseur n'expose pas" \
  || ok "et il ne renvoie pas vers une variable interne à la lib"
[ -z "$(calls | grep -E 'POST')" ] && [ ! -f "$POSTE" ] \
  && ok "et AUCUNE écriture n'est partie vers Jenkins" || ko "des écritures ont eu lieu malgré le refus"
unset BODYDIR

echo
echo "======================================================================"
echo "== 16. l'amorçage est ATTENDU puis RELU (L6) : un trigger de la classe de WEBHOOK_KIND et une option, sinon AMORCAGE_INCOMPLET =="
# MESURÉ (scripts/spike-webhook-kind-m2m4.sh, 2026-09-11) : un XML posé sans
# propriété laisse le job MUET jusqu'à la fin de son premier build — le webhook
# rend 404, et le POST /project/<job> du GitLab Plugin rend 200 EN SILENCE. Le
# poseur ne peut donc pas rendre la main sur un « build lancé » : il attend, il
# relit, et il nomme ce qui manque.
RELU_XML="$(relu 1 0 1 stoa-provision-plan)" start "provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-plan bash "$S" 2>&1); RC=$?
[ $RC -eq 0 ] && grep -q "amorçage #7 : SUCCESS" <<<"$OUT" && grep -q "1 trigger GenericTrigger (stoa-provision-plan)" <<<"$OUT" \
  && ok "gwt nominal : build #7 ATTENDU, config.xml RELU, 1 GenericTrigger + 1 DisableConcurrentBuilds ⇒ succès nommé" \
  || ko "gwt nominal : rc=$RC — $(grep -E 'amorçage|relecture|AMORCAGE' <<<"$OUT" | tr '\n' ' ')"
L_B=$(calls | grep -n 'POST build provision-plan' | head -1 | cut -d: -f1); L_R=$(calls | grep -n 'GET config provision-plan' | head -1 | cut -d: -f1)
[ -n "$L_B" ] && [ -n "$L_R" ] && [ "$L_B" -lt "$L_R" ] \
  && ok "la relecture (appel $L_R) vient APRÈS l'amorçage (appel $L_B)" || ko "ordre amorçage/relecture cassé (build=$L_B config=$L_R)"
RELU_XML="$(relu 0 1 1 x)" start "provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-plan WEBHOOK_KIND=gitlab bash "$S" 2>&1); RC=$?
[ $RC -eq 0 ] && grep -q "1 trigger GitLabPushTrigger" <<<"$OUT" \
  && ok "gitlab nominal : la CLASSE attendue suit WEBHOOK_KIND (GitLabPushTrigger), et l'URL du webhook GitLab est annoncée" \
  || ko "gitlab nominal : rc=$RC — $(grep -E 'relecture|AMORCAGE' <<<"$OUT" | tr '\n' ' ')"
RELU_XML="$(relu 1 0 1 stoa-provision-plan)" start "provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-plan WEBHOOK_KIND=gitlab bash "$S" 2>&1); RC=$?
[ $RC -ne 0 ] && grep -q "AMORCAGE_INCOMPLET" <<<"$OUT" \
  && ok "knob gitlab mais GenericTrigger relu ⇒ AMORCAGE_INCOMPLET (la globale et le job ne disent pas la même chose)" \
  || ko "classe divergente avalée (rc=$RC)"
RELU_XML="$(relu 0 0 0 x)" start "provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-plan bash "$S" 2>&1); RC=$?
[ $RC -ne 0 ] && grep -q "AMORCAGE_INCOMPLET" <<<"$OUT" \
  && ok "aucune propriété après l'amorçage ⇒ AMORCAGE_INCOMPLET (le job serait MUET, et le webhook rendrait 404 sans le dire)" \
  || ko "job muet avalé (rc=$RC)"
RELU_XML="$(relu 2 0 1 stoa-provision-plan)" start "provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-plan bash "$S" 2>&1); RC=$?
[ $RC -ne 0 ] && grep -q "AMORCAGE_INCOMPLET" <<<"$OUT" \
  && ok "DEUX triggers relus ⇒ AMORCAGE_INCOMPLET (le doublon du fait 10 : un XML porteur aurait survécu à la pose)" \
  || ko "doublon avalé (rc=$RC)"
BUILD_RESULT="" RELU_XML="$(relu 1 0 1 stoa-provision-plan)" start "provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-plan BOOTSTRAP_WAIT=4 bash "$S" 2>&1); RC=$?
[ $RC -ne 0 ] && grep -q "ENCORE EN COURS après 4 s" <<<"$OUT" \
  && ok "build d'amorçage jamais fini ⇒ échec BORNÉ par BOOTSTRAP_WAIT, nommé, et qui dit de NE PAS re-poser" \
  || ko "attente non bornée ou muette (rc=$RC)"
BUILD_RESULT=FAILURE RELU_XML="$(relu 1 0 1 stoa-provision-plan)" start "provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-plan bash "$S" 2>&1); RC=$?
[ $RC -ne 0 ] && grep -q "amorçage #7 : FAILURE" <<<"$OUT" && grep -q "AMORCAGE_INCOMPLET" <<<"$OUT" \
  && ok "amorçage FAILURE (WEBHOOK_KIND_INVALIDE côté Jenkinsfile, par exemple) ⇒ AMORCAGE_INCOMPLET, même si la relecture est bonne" \
  || ko "FAILURE d'amorçage avalé (rc=$RC)"
start "provision-plan" 200
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS=provision-plan BOOTSTRAP_AWAIT_JOBS=none bash "$S" 2>&1); RC=$?
[ $RC -eq 0 ] && ! calls | grep -q 'GET config' && grep -q "non attendu" <<<"$OUT" \
  && ok "BOOTSTRAP_AWAIT_JOBS=none : amorçage déclenché, ni attendu ni relu (le geste d'A0, conservé et DIT)" \
  || ko "await=none : rc=$RC relectures=$(calls | grep -c 'GET config')"

echo
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
