#!/usr/bin/env bash
# test-generate-choices.sh — preuve X/X du générateur de listes (Task 3,
# palier 3) : scripts/lib/generate-choices.sh + la substitution des
# placeholders <!--CHOICES:TEAMS-->/<!--CHOICES:APIS--> dans
# setup-team-onboard-jobs.sh. TOUT EN LOCAL — ni Gitea, ni Jenkins réels :
#   - "Gitea" = des dépôts bare git LOCAUX (clone accepte un chemin fichier
#     comme n'importe quelle URL http, la lib ne sait pas la différence) ;
#   - "Jenkins" = le même faux serveur HTTP minimal que
#     test-setup-provision-jobs.sh, étendu pour ENREGISTRER le corps de
#     chaque POST config.xml (nécessaire à la preuve 5 : octet pour octet).
#
#   ./scripts/test-generate-choices.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO/scripts/lib/generate-choices.sh"
SETUP="$REPO/scripts/setup-team-onboard-jobs.sh"
TMP="$(mktemp -d /tmp/gencho.XXXXXX)"
PORT="${FAKE_JENKINS_PORT:-18410}"
PID=""
cleanup(){ [ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$TMP" "$REPO/ci/jenkins/p3t3-disposable.job.xml"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# ── faux Jenkins : accepte tout, ENREGISTRE le corps de chaque config.xml ────
cat > "$TMP/fakejenkins.py" <<'PY'
import os, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
LOG = os.environ["CALLLOG"]
BODYDIR = os.environ["BODYDIR"]
def log(line):
    with open(LOG, "a") as f: f.write(line + "\n")
class H(BaseHTTPRequestHandler):
    def _send(self, code, body=b"{}"):
        self.send_response(code); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path.startswith("/crumbIssuer"):
            log("GET crumb")
            return self._send(200, b'{"crumbRequestField":"Jenkins-Crumb","crumb":"abc"}')
        m = re.match(r"^/job/([^/]+)/api/json$", self.path)
        if m:
            log(f"GET exists {m.group(1)} -> 404")
            return self._send(404)  # tout est "absent" -> toujours createItem
        self._send(404)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n) if n else b""
        if self.path.startswith("/createItem"):
            name = re.search(r"name=([^&]+)", self.path).group(1)
            with open(os.path.join(BODYDIR, name + ".posted.xml"), "wb") as f:
                f.write(body)
            log("POST create " + self.path)
            return self._send(200)
        self._send(404)
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
BODYDIR="$TMP/posted"; mkdir -p "$BODYDIR"
CALLLOG="$TMP/calls.log" BODYDIR="$BODYDIR" python3 "$TMP/fakejenkins.py" "$PORT" >/dev/null 2>&1 &
PID=$!
for _ in $(seq 1 40); do curl -s "http://127.0.0.1:$PORT/x" >/dev/null 2>&1 && break; sleep 0.1; done
JU="http://127.0.0.1:$PORT"

# ── "Gitea" local : bare repos servis comme des chemins fichier ─────────────
mk_platform_repo(){ # $1=racine bare $2=providers.dev.yml content $3=clients apis publish.yml content (ou vide)
  local barecdir="$1" src="$TMP/src-platform-$$_$RANDOM"
  mkdir -p "$src/poc-control-plane-federation/ansible" "$src/poc-control-plane-federation/clients/_example/apis"
  printf '%s' "$2" > "$src/poc-control-plane-federation/ansible/providers.dev.yml"
  if [ -n "${3:-}" ]; then printf '%s' "$3" > "$src/poc-control-plane-federation/clients/_example/apis/accounts-read.publish.yml"; fi
  ( cd "$src" && git init -q -b main && git -c user.name=t -c user.email=t@t add -A \
    && git -c user.name=t -c user.email=t commit -qm init >/dev/null )
  mkdir -p "$(dirname "$barecdir")"
  git clone -q --bare "$src" "$barecdir" >/dev/null
}
mk_team_repo(){ # $1=racine bare (ex. $GH/banking-demo/accounts-api.git) $2=apis/*.publish.yml content
  local barecdir="$1" src="$TMP/src-team-$$_$RANDOM"
  mkdir -p "$src/apis"
  printf '%s' "$2" > "$src/apis/payouts.publish.yml"
  ( cd "$src" && git init -q -b main && git -c user.name=t -c user.email=t@t add -A \
    && git -c user.name=t -c user.email=t commit -qm init >/dev/null )
  mkdir -p "$(dirname "$barecdir")"
  git clone -q --bare "$src" "$barecdir" >/dev/null
}

TWO_TEAMS='providers:
  - team: banking-demo
    description: "d1"
    repo: ""
    approvers: []
  - team: payments-team
    description: "d2"
    repo: ""
    approvers: []
'
ONE_API='apim_api:
  name: "accounts-read-ans"
  version: "1.0.0"
'
# 1 équipe avec repo DÉCLARÉ (banking-demo/accounts-api) — présent ou absent
# selon le mock utilisé par le test 10 ci-dessous.
ONE_TEAM_ONE_REPO='providers:
  - team: banking-demo
    description: "d1"
    repo: banking-demo/accounts-api
    approvers: []
'
PAYOUTS_API='apim_api:
  name: "payouts"
  version: "2.0.0"
'

echo "== 1. generate_choices_teams : 2 équipes déclarées -> 2 <string> =="
GH="$TMP/gitea1"; mk_platform_repo "$GH/ci/stoa-labs.git" "$TWO_TEAMS" ""
OUT=$(GIT_HOST="$GH" GIT_REPO=ci/stoa-labs GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_teams dev") ; RC=$?
[ "$RC" -eq 0 ] && ok "succès" || ko "échec (rc=$RC)"
[ "$(printf '%s\n' "$OUT" | grep -c '<string>')" = "2" ] && ok "2 fragments <string>" || ko "nombre de fragments inattendu : $OUT"
printf '%s\n' "$OUT" | grep -q '<string>banking-demo</string>' && ok "banking-demo présent" || ko "banking-demo absent"
printf '%s\n' "$OUT" | grep -q '<string>payments-team</string>' && ok "payments-team présent" || ko "payments-team absent"

echo
echo "== 2. gitea injoignable -> échec AVANT tout POST (au niveau pose complète) =="
cp "$REPO/ci/jenkins/team-request.job.xml" "$TMP/disposable-src.xml"
{ echo "<?xml version='1.1' encoding='UTF-8'?>"
  echo '<flow-definition plugin="workflow-job"><description>jetable T3</description>'
  echo '<properties><hudson.model.ParametersDefinitionProperty><parameterDefinitions>'
  echo '<hudson.model.ChoiceParameterDefinition><name>TEAM</name><choices class="java.util.Arrays$ArrayList"><a class="string-array">'
  echo '<!--CHOICES:TEAMS-->'
  echo '</a></choices></hudson.model.ChoiceParameterDefinition>'
  echo '<hudson.model.ChoiceParameterDefinition><name>API</name><choices class="java.util.Arrays$ArrayList"><a class="string-array">'
  echo '<!--CHOICES:APIS-->'
  echo '</a></choices></hudson.model.ChoiceParameterDefinition>'
  echo '</parameterDefinitions></hudson.model.ParametersDefinitionProperty></properties>'
  echo '<definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps"><script>node { echo 42 }</script><sandbox>true</sandbox></definition>'
  echo '<triggers/><disabled>false</disabled></flow-definition>'
} > "$REPO/ci/jenkins/p3t3-disposable.job.xml"
python3 -c "import xml.etree.ElementTree as T; T.parse('$REPO/ci/jenkins/p3t3-disposable.job.xml')" \
  && ok "XML jetable bien formé" || ko "XML jetable cassé"

: > "$TMP/calls.log"
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS="p3t3-disposable" GIT_HOST="/nonexistent/nope" GIT_REPO=ci/stoa-labs GITEA_TOKEN=dummy ENVN=dev \
  bash "$SETUP" 2>&1); RC=$?
[ "$RC" -ne 0 ] && ok "refusé (rc=$RC)" || ko "aurait dû échouer : $OUT"
grep -q "GITEA_UNREACHABLE" <<<"$OUT" && ok "cause explicite (GITEA_UNREACHABLE)" || ko "cause absente : $OUT"
[ -z "$(grep 'POST create' "$TMP/calls.log" 2>/dev/null)" ] && ok "AUCUN POST envoyé à Jenkins" || ko "un POST a quand même eu lieu"

echo
echo "== 3. providers vide -> échec =="
GH3="$TMP/gitea3"; mk_platform_repo "$GH3/ci/stoa-labs.git" 'providers: []' ""
OUT=$(GIT_HOST="$GH3" GIT_REPO=ci/stoa-labs GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_teams dev" 2>&1) ; RC=$?
[ "$RC" -ne 0 ] && ok "refusé (rc=$RC)" || ko "aurait dû échouer"
grep -q "PROVIDERS_EMPTY" <<<"$OUT" && ok "cause explicite (PROVIDERS_EMPTY)" || ko "cause absente : $OUT"

echo
echo "== 4. nom hostile (a&b<c) injecté DIRECTEMENT dans l'échappement -> XML valide =="
ESC=$(bash -c ". '$LIB'; _gc_escape 'a&b<c'")
[ "$ESC" = 'a&amp;b&lt;c' ] && ok "échappement correct : $ESC" || ko "échappement incorrect : $ESC"
printf '<string>%s</string>' "$ESC" > "$TMP/frag.xml"
python3 -c "import xml.etree.ElementTree as T; T.parse('$TMP/frag.xml')" \
  && ok "le fragment produit est du XML bien formé" || ko "fragment XML cassé"

echo
echo "== 5. jobs SANS placeholder -> pose octet pour octet identique =="
: > "$TMP/calls.log"; rm -rf "$BODYDIR"/*
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS="team-request team-apply" bash "$SETUP" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "pose réussie (aucun placeholder -> aucun besoin de Gitea/token)" || ko "échec (rc=$RC) : $OUT"
if diff -q "$REPO/ci/jenkins/team-request.job.xml" "$BODYDIR/team-request.posted.xml" >/dev/null 2>&1; then
  ok "team-request.job.xml : identique octet pour octet"
else
  ko "team-request.job.xml : DIVERGENCE (voir diff)"
  diff "$REPO/ci/jenkins/team-request.job.xml" "$BODYDIR/team-request.posted.xml" | head -5
fi
if diff -q "$REPO/ci/jenkins/team-apply.job.xml" "$BODYDIR/team-apply.posted.xml" >/dev/null 2>&1; then
  ok "team-apply.job.xml : identique octet pour octet"
else
  ko "team-apply.job.xml : DIVERGENCE (voir diff)"
  diff "$REPO/ci/jenkins/team-apply.job.xml" "$BODYDIR/team-apply.posted.xml" | head -5
fi

echo
echo "== 6. job ABSENT du dépôt dans JOBS -> toléré, pas un échec =="
: > "$TMP/calls.log"; rm -rf "$BODYDIR"/*
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS="team-request api-request-inexistant-t3" bash "$SETUP" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "succès malgré l'absence" || ko "échec (rc=$RC) : $OUT"
grep -q "ignoré (pas encore livré)" <<<"$OUT" && ok "l'absence est signalée" || ko "absence non signalée : $OUT"
[ -f "$BODYDIR/team-request.posted.xml" ] && ok "le job PRÉSENT (team-request) a quand même été posé" || ko "team-request non posé"

echo
echo "== 7. job AVEC placeholders -> substitution réelle, contenu attendu dans le POST =="
GH7="$TMP/gitea7"; mk_platform_repo "$GH7/ci/stoa-labs.git" "$TWO_TEAMS" "$ONE_API"
: > "$TMP/calls.log"; rm -rf "$BODYDIR"/*
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS="p3t3-disposable" GIT_HOST="$GH7" GIT_REPO=ci/stoa-labs GITEA_TOKEN=dummy ENVN=dev \
  bash "$SETUP" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "pose réussie" || ko "échec (rc=$RC) : $OUT"
POSTED="$BODYDIR/p3t3-disposable.posted.xml"
[ -f "$POSTED" ] && ok "un POST a bien eu lieu" || ko "aucun POST reçu"
python3 -c "import xml.etree.ElementTree as T; T.parse('$POSTED')" \
  && ok "le XML posté reste bien formé après substitution" || ko "XML posté cassé"
grep -q '<!--CHOICES:TEAMS-->' "$POSTED" && ko "placeholder TEAMS encore présent dans le XML posté" || ok "placeholder TEAMS remplacé"
grep -q '<!--CHOICES:APIS-->'  "$POSTED" && ko "placeholder APIS encore présent dans le XML posté"  || ok "placeholder APIS remplacé"
grep -q '<string>banking-demo</string>' "$POSTED" && ok "banking-demo dans le XML posté" || ko "banking-demo absent du POST"
grep -q '<string>payments-team</string>' "$POSTED" && ok "payments-team dans le XML posté" || ko "payments-team absent du POST"
grep -q '<string>accounts-read-ans@1.0.0</string>' "$POSTED" && ok "accounts-read-ans@1.0.0 dans le XML posté" || ko "API absente du POST"

echo
echo "== 8. re-pose événementielle (team-apply.sh) — câblage best-effort BRUYANT =="
TA="$REPO/scripts/team-apply.sh"
bash -n "$TA" 2>/dev/null && ok "team-apply.sh : syntaxe valide" || ko "team-apply.sh non parsable"
L_ONBRC=$(grep -n '\[ "\$ONB_RC" -eq 0 \]' "$TA" | head -1 | cut -d: -f1)
L_REFRESH=$(grep -n 'setup-team-onboard-jobs\.sh' "$TA" | head -1 | cut -d: -f1)
L_FAIL_ONB=$(grep -n 'fail "onboarding' "$TA" | head -1 | cut -d: -f1)
if [ -n "$L_ONBRC" ] && [ -n "$L_REFRESH" ] && [ "$L_REFRESH" -gt "$L_ONBRC" ]; then
  ok "la re-pose est appelée APRÈS le succès de l'onboarding (ligne $L_REFRESH > $L_ONBRC)"
else
  ko "ordre inattendu : ONB_RC=$L_ONBRC refresh=$L_REFRESH"
fi
grep -q 'listes non rafraîchies — relancer setup-team-onboard-jobs.sh' "$TA" \
  && ok "le texte d'avertissement exact est présent" || ko "texte d'avertissement absent/différent"
# La ligne d'échec de la re-pose ne doit JAMAIS appeler fail() — sinon un
# échec de re-pose ferait passer un onboarding RÉUSSI pour un échec.
REFRESH_BLOCK=$(sed -n "/REFRESH_NOTE=\"\"/,/^  comment \"✅/p" "$TA")
if grep -q '^\s*fail ' <<<"$REFRESH_BLOCK"; then
  ko "le bloc de re-pose appelle fail() — un échec de re-pose annulerait l'onboarding"
else
  ok "le bloc de re-pose n'appelle jamais fail() — non fatal, comme prévu"
fi
grep -q 'REFRESH_NOTE' <<<"$(grep 'comment "✅ team-apply' "$TA")" \
  && ok "REFRESH_NOTE est bien inséré dans le commentaire ✅ (jamais un commentaire séparé silencieux)" \
  || ko "REFRESH_NOTE absent de la ligne de commentaire ✅"

echo
echo "== 9. re-pose : preuve dynamique du SIGNAL d'échec dont team-apply.sh dépend =="
# On ne rejoue pas team-apply.sh en entier ici (Vault + Gitea réels + rôle
# Ansible : hors périmètre offline de ce harnais, couvert par le chemin FORT
# de test-team-onboarding-chain.sh en environnement de lab). On prouve la
# BRIQUE dont il dépend : setup-team-onboard-jobs.sh échoue proprement
# (rc≠0) quand JENKINS_UI est injoignable, et réussit (rc=0) sinon — exactement
# les deux branches du `if ... ; then ... else REFRESH_NOTE=... ; fi` ajouté.
OUT=$(cd "$REPO" && JENKINS_UI="http://127.0.0.1:1" JOBS="app-request api-request" ENVN=dev bash "$SETUP" 2>&1); RC=$?
[ "$RC" -ne 0 ] && ok "JENKINS_UI injoignable -> rc≠0 (déclenche REFRESH_NOTE côté team-apply.sh)" || ko "aurait dû échouer"
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS="app-request api-request" ENVN=dev bash "$SETUP" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "Jenkins joignable, api-request absent toléré -> rc=0 (branche succès)" || ko "échec inattendu (rc=$RC) : $OUT"
grep -q "api-request" <<<"$OUT" && grep -q "ignoré" <<<"$OUT" && ok "api-request signalé absent, pas fatal" || ko "signal d'absence manquant"

echo
echo "== 10. re-pose : le SIGNAL 'dépôt d'équipe toléré/sauté' survit au succès (revue round 1) =="
# CONSTAT DE REVUE (round 1) : une re-pose peut RÉUSSIR (rc=0) tout en ayant
# toléré un dépôt d'équipe déclaré-absent (generate_choices_apis, réserve 3
# du rapport) — sans grep DÉDIÉ à ce cas, ce signal ne sortait jamais du
# process sur le chemin de succès (seule la branche ÉCHEC de team-apply.sh
# faisait un `tail`). Reproduit ici le MÊME pipeline que team-apply.sh :
# capture combinée stdout+stderr dans un log, puis le MÊME grep -oE — sans
# rejouer team-apply.sh en entier (Vault/Gitea/Ansible réels, hors périmètre
# offline), même discipline que la preuve 9 juste au-dessus.
TA_GREP(){ grep -oE 'CHOICES_SKIPPED_REPOS=[0-9]+' "$1" | tail -1 | cut -d= -f2; }

echo "-- 10a. dépôt d'équipe DÉCLARÉ mais ABSENT du mock -> marqueur=1, re-pose VERTE, note ⚠ portée --"
GH10A="$TMP/gitea10a"; mk_platform_repo "$GH10A/ci/stoa-labs.git" "$ONE_TEAM_ONE_REPO" "$ONE_API"
# banking-demo/accounts-api.git n'est PAS créé sous $GH10A -> clone en échec, toléré (pas un ko).
: > "$TMP/calls.log"; rm -rf "$BODYDIR"/*
JENKINS_UI="$JU" JOBS="p3t3-disposable" GIT_HOST="$GH10A" GIT_REPO=ci/stoa-labs GITEA_TOKEN=dummy ENVN=dev \
  bash "$SETUP" >"$TMP/refresh10a.log" 2>&1
RC=$?
[ "$RC" -eq 0 ] && ok "re-pose réussie malgré le dépôt d'équipe absent (toléré)" || ko "n'aurait pas dû échouer (rc=$RC)"
SKIPPED_A=$(TA_GREP "$TMP/refresh10a.log")
[ "$SKIPPED_A" = "1" ] && ok "marqueur CHOICES_SKIPPED_REPOS=1 présent dans le log de re-pose (succès)" \
  || ko "marqueur attendu=1, obtenu='$SKIPPED_A' — voir $TMP/refresh10a.log"
# Même construction que team-apply.sh (REFRESH_NOTE) — preuve que le grep
# ci-dessus est bien EXPLOITABLE pour bâtir la note du commentaire PR.
NOTE_A=""
if [ -n "$SKIPPED_A" ] && [ "$SKIPPED_A" -gt 0 ]; then
  NOTE_A=" (listes rafraîchies ; ⚠ ${SKIPPED_A} dépôt(s) d'équipe déclarés mais absents, sautés)"
fi
[ "$NOTE_A" = " (listes rafraîchies ; ⚠ 1 dépôt(s) d'équipe déclarés mais absents, sautés)" ] \
  && ok "la note construite porte le signal : '$NOTE_A'" || ko "note inattendue : '$NOTE_A'"

echo "-- 10b. contre-témoin : le même dépôt d'équipe, RÉELLEMENT présent -> marqueur=0, note propre --"
GH10B="$TMP/gitea10b"; mk_platform_repo "$GH10B/ci/stoa-labs.git" "$ONE_TEAM_ONE_REPO" "$ONE_API"
mk_team_repo "$GH10B/banking-demo/accounts-api.git" "$PAYOUTS_API"
: > "$TMP/calls.log"; rm -rf "$BODYDIR"/*
JENKINS_UI="$JU" JOBS="p3t3-disposable" GIT_HOST="$GH10B" GIT_REPO=ci/stoa-labs GITEA_TOKEN=dummy ENVN=dev \
  bash "$SETUP" >"$TMP/refresh10b.log" 2>&1
RC=$?
[ "$RC" -eq 0 ] && ok "re-pose réussie, dépôt d'équipe présent" || ko "échec inattendu (rc=$RC)"
SKIPPED_B=$(TA_GREP "$TMP/refresh10b.log")
[ "$SKIPPED_B" = "0" ] && ok "marqueur CHOICES_SKIPPED_REPOS=0 (contre-témoin : rien sauté)" \
  || ko "marqueur attendu=0, obtenu='$SKIPPED_B' — voir $TMP/refresh10b.log"
NOTE_B=""
if [ -n "$SKIPPED_B" ] && [ "$SKIPPED_B" -gt 0 ]; then
  NOTE_B=" (listes rafraîchies ; ⚠ ${SKIPPED_B} dépôt(s) d'équipe déclarés mais absents, sautés)"
fi
[ -z "$NOTE_B" ] && ok "note propre, aucun ⚠ (contre-témoin)" || ko "note inattendue : '$NOTE_B'"
grep -q '<string>payouts@2.0.0</string>' "$BODYDIR/p3t3-disposable.posted.xml" \
  && ok "l'API du dépôt d'équipe désormais présent (payouts@2.0.0) est bien dans le XML posté" \
  || ko "API du dépôt d'équipe absente du POST"

echo
echo "== 11. bash -n sur les fichiers touchés =="
for f in "$LIB" "$SETUP" "$REPO/scripts/team-apply.sh" "$REPO/scripts/setup-provision-jobs.sh"; do
  bash -n "$f" 2>/dev/null && ok "syntaxe valide : $(basename "$f")" || ko "syntaxe cassée : $(basename "$f")"
done

echo
echo "== 12. garde de secrets (fichiers TOUCHÉS par cette tâche uniquement) =="
# `gitleaks detect -s scripts/` sur le dépôt ENTIER a des trouvailles
# PRÉEXISTANTES sans rapport avec cette tâche (ex. Administrator:manage dans
# scripts/test-backend-key.sh — un identifiant de lab déjà présent avant
# cette branche). Le scope pertinent ICI est : les fichiers que cette tâche a
# créés ou modifiés, pas l'historique du dépôt.
if command -v gitleaks >/dev/null 2>&1; then
  GL_SCOPE="$TMP/gitleaks-scope"; mkdir -p "$GL_SCOPE"
  cp "$LIB" "$SETUP" "$REPO/scripts/team-apply.sh" "$REPO/scripts/setup-provision-jobs.sh" "$0" "$GL_SCOPE/"
  RC_GL=0
  gitleaks detect --no-git -s "$GL_SCOPE" --exit-code 1 >"$TMP/gitleaks.out" 2>&1 || RC_GL=$?
  [ "$RC_GL" -eq 0 ] && ok "gitleaks (fichiers touchés) : rc=0" \
    || { ko "gitleaks (fichiers touchés) : rc=$RC_GL"; cat "$TMP/gitleaks.out"; }
else
  echo "  (gitleaks absent de PATH — étape sautée)"
fi

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
