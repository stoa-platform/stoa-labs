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
PORT=""
PID=""; PID2=""
cleanup(){ # le `wait` absorbe la notification « Terminated: 15 » du contrôle de
  # tâches, qui s'imprimait APRÈS la ligne RÉSULTAT et polluait le verdict lu en
  # `| tail -20`.
  [ -n "$PID" ]  && { kill "$PID"  2>/dev/null; wait "$PID"  2>/dev/null; }
  [ -n "$PID2" ] && { kill "$PID2" 2>/dev/null; wait "$PID2" 2>/dev/null; }
  rm -rf "$TMP" "$REPO/ci/jenkins/p3t3-disposable.job.xml"; return 0; }
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
        # A0 : le build d'AMORCAGE d'un job qui pose son formulaire depuis son
        # Jenkinsfile (app-request) — trace <job>.build, 201 comme le vrai Jenkins.
        mb = re.match(r"^/job/([^/]+)/build$", self.path)
        if mb:
            open(os.path.join(BODYDIR, mb.group(1) + ".build"), "w").close()
            log("POST build " + mb.group(1))
            return self._send(201)
        if self.path.startswith("/createItem"):
            name = re.search(r"name=([^&]+)", self.path).group(1)
            with open(os.path.join(BODYDIR, name + ".posted.xml"), "wb") as f:
                f.write(body)
            log("POST create " + self.path)
            return self._send(200)
        self._send(404)
    def log_message(self, *a): pass
# H4 (2026-09-07) : le serveur ANNONCE le port qu'il a RÉELLEMENT obtenu. Le
# harnais attend CETTE ligne — pas un `curl` qui répond « oui » depuis le
# serveur d'un autre run. Port 0 ⇒ c'est l'OS qui choisit (deux runs
# concurrents ne se disputent plus un port fixe).
srv = HTTPServer(("127.0.0.1", int(sys.argv[1])), H)
print("LISTENING %d" % srv.server_address[1], flush=True)
srv.serve_forever()
PY
BODYDIR="$TMP/posted"; mkdir -p "$BODYDIR"

# ── H4 : UN ÉCHEC DE BIND DOIT ÊTRE DÉTECTABLE (2026-09-07) ──────────────────
# MESURÉ sur le harnais d'avant : le serveur était lancé sur le port FIXE 18410
# en « >/dev/null 2>&1 & ». Un bind refusé (« OSError: [Errno 48] Address
# already in use », traceback complet) partait donc dans /dev/null, le processus
# mourait — et la boucle « curl … && break » réussissait quand même, CONTRE LE
# SERVEUR DÉJÀ EN PLACE D'UN AUTRE RUN. La suite mesurait alors le harnais du
# voisin : corps de POST écrits par un autre process, log d'appels partagé.
# Trois gestes : la sortie du serveur va dans un LOG ; le serveur annonce son
# port et c'est cette ligne qu'on attend ; le port est choisi par l'OS tant que
# FAKE_JENKINS_PORT n'impose rien.
FJ_PID=""; FJ_PORT=""
start_fake_jenkins(){ # $1=port demandé (0 = l'OS choisit) $2=log ; pose FJ_PID/FJ_PORT, rc≠0 si le bind échoue
  local want="$1" log="$2" pid
  FJ_PID=""; FJ_PORT=""; : > "$log"
  CALLLOG="$TMP/calls.log" BODYDIR="$BODYDIR" python3 "$TMP/fakejenkins.py" "$want" >"$log" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do
    FJ_PORT=$(sed -n 's/^LISTENING \([0-9][0-9]*\)$/\1/p' "$log" | head -1)
    if [ -n "$FJ_PORT" ]; then FJ_PID="$pid"; return 0; fi
    kill -0 "$pid" 2>/dev/null || break        # mort sans annoncer : bind refusé
    sleep 0.1
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null   # jamais de `wait` sur un vivant
  FJ_PORT=""
  return 1
}
if start_fake_jenkins "${FAKE_JENKINS_PORT:-0}" "$TMP/fakejenkins.log"; then
  PID="$FJ_PID"; PORT="$FJ_PORT"
else
  printf '  ❌ FAUX_JENKINS_INDISPONIBLE : le faux serveur n'"'"'a pas pu écouter (port demandé « %s ») — la suite entière serait vide de sens. Cause :\n' "${FAKE_JENKINS_PORT:-0}"
  sed -n '$p' "$TMP/fakejenkins.log" | sed 's/^/    /'
  exit 1
fi
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
grep -q "GIT_UNREACHABLE" <<<"$OUT" && ok "cause explicite (GIT_UNREACHABLE)" || ko "cause absente : $OUT"

# 2026-09-04 (deploiement client) : un gestionnaire d'identite ne rend pas
# toujours un JETON — Jenkins rend souvent un COUPLE (usernamePassword). Pour
# git, les deux valent : le clone ne fait qu'un Basic. Le refus reclamait un
# jeton que le client n'aura jamais, et ne nommait pas l'alternative.
OUTS=$(env -u GITEA_TOKEN -u FORGE_SECRET bash -c ". '$LIB'; generate_choices_teams_raw dev" 2>&1); RCS=$?
[ "$RCS" -ne 0 ] && grep -q 'SECRET_FORGE_REQUIS' <<<"$OUTS" && grep -q 'FORGE_SECRET' <<<"$OUTS" && grep -q 'FORGE_USER' <<<"$OUTS" \
  && ok "sans secret : SECRET_FORGE_REQUIS nomme FORGE_SECRET, son alias et FORGE_USER (le couple est une voie, pas un contournement)" \
  || ko "refus de secret : rc=$RCS — $(head -1 <<<"$OUTS")"
# le COUPLE ouvre le meme canal que le jeton : meme depot de fixture, secret par
# mot de passe et utilisateur nomme — ce que fait un withCredentials Jenkins.
OUTS=$(env -u GITEA_TOKEN FORGE_SECRET=motdepasse FORGE_USER=jdupont GIT_HOST="$GH" GIT_REPO=ci/stoa-labs \
  bash -c ". '$LIB'; generate_choices_teams_raw dev" 2>&1); RCS=$?
[ "$RCS" -eq 0 ] && [ "$(grep -c . <<<"$OUTS")" -ge 1 ] \
  && ok "un COUPLE (FORGE_SECRET + FORGE_USER) lit les listes comme un jeton" \
  || ko "couple refuse : rc=$RCS — $(head -1 <<<"$OUTS")"

# 2026-09-03 (déploiement client) : le refus doit porter la CAUSE de git, pas
# seulement le tag — avant, `2>/dev/null` avalait tout et un hôte injoignable,
# un jeton refusé et une branche `main` absente rendaient le même refus muet.
grep -qE "en échec — .+" <<<"$OUT" && ok "le refus cite la sortie de git (diagnostic possible chez un client)" || ko "refus sans cause : $OUT"
# et il ne relaie JAMAIS des identifiants glissés dans GIT_HOST (mesuré : la
# première version fuyait par le message lui-même, pas par la sortie de git).
# 2026-09-07 (quater) : ce cas ne va plus jusqu'au clone — depuis I1 il REFUSE,
# et un refus qui ne cite rien ne peut rien laisser fuir. Les deux moitiés sont
# donc mesurées séparément : le refus (sans knob), puis l'expurgation (avec).
OUTC=$(cd "$REPO" && GIT_HOST="http://u:MOTDEPASSE-CANARI@127.0.0.1:1/x" GIT_REPO=org/depot GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_teams_raw dev" 2>&1)
! grep -q "MOTDEPASSE-CANARI" <<<"$OUTC" && grep -q "^GIT_HOST_PORTE_IDENTIFIANTS : " <<<"$OUTC" \
  && ok "GIT_HOST porteur d'identifiants ⇒ REFUS nommé, et le refus ne cite pas le secret (il ne cite pas non plus l'hôte)" \
  || ko "fuite d'identifiants dans le refus : $(sed -E 's/MOTDEPASSE-CANARI/<FUITE>/g' <<<"$OUTC" | head -1)"
OUTCT=$(cd "$REPO" && GIT_HOST_USERINFO_TOLERE=1 GIT_HOST="http://u:MOTDEPASSE-CANARI@127.0.0.1:1/x" GIT_REPO=org/depot GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_teams_raw dev" 2>&1)
! grep -q "MOTDEPASSE-CANARI" <<<"$OUTCT" && grep -q "identifiants masqués" <<<"$OUTCT" \
  && ok "sous GIT_HOST_USERINFO_TOLERE=1, le run va jusqu'au clone et les identifiants sont expurgés des DEUX canaux (message et sortie de git)" \
  || ko "fuite d'identifiants sous le knob : $(sed -E 's/MOTDEPASSE-CANARI/<FUITE>/g' <<<"$OUTCT" | head -1)"
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
echo "== 5. jobs SANS placeholder CHOICES -> posés tels quels, à la BRANCHE près =="
# L3 (2026-09-10) : les XML ne nomment plus de branche, ils portent
# __GIT_BASE__ que le délégué substitue. « Octet pour octet » se dit donc
# désormais « la source, à cette seule substitution près » — et le knob
# GIT_BASE=master (zéro réseau) tient lieu de branche pour ce faux Jenkins.
: > "$TMP/calls.log"; rm -rf "$BODYDIR"/*
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS="team-request team-apply" GIT_BASE=master bash "$SETUP" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "pose réussie (aucun placeholder CHOICES -> aucun besoin de Gitea/token)" || ko "échec (rc=$RC) : $OUT"
for J in team-request team-apply; do
  sed 's#__GIT_BASE__#master#g' "$REPO/ci/jenkins/$J.job.xml" > "$TMP/$J.attendu.xml"
  if diff -q "$TMP/$J.attendu.xml" "$BODYDIR/$J.posted.xml" >/dev/null 2>&1; then
    ok "$J.job.xml : la source, à la substitution de branche près (octet pour octet)"
  else
    ko "$J.job.xml : DIVERGENCE (voir diff)"
    diff "$TMP/$J.attendu.xml" "$BODYDIR/$J.posted.xml" | head -5
  fi
  grep -qF '__GIT_BASE__' "$BODYDIR/$J.posted.xml" \
    && ko "$J.job.xml : le placeholder survit dans le XML POSTÉ" \
    || ok "$J.job.xml : aucun __GIT_BASE__ dans le XML posté"
done

echo
echo "== 6. job ABSENT du dépôt dans JOBS -> toléré, pas un échec =="
: > "$TMP/calls.log"; rm -rf "$BODYDIR"/*
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS="team-request api-request-inexistant-t3" GIT_BASE=master bash "$SETUP" 2>&1); RC=$?
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
#
# ÉCART (Task 5, palier 3) : à l'écriture de la Task 3, api-request.job.xml
# n'existait pas encore — ce test-ci vérifiait donc la tolérance "job absent"
# sur l'appel EXACT de team-apply.sh (JOBS="app-request api-request"). La
# Task 5 a livré ce XML (avec placeholders CHOICES:TEAMS/APIS, comme
# app-request) : l'assertion "api-request absent, toléré" est donc devenue
# fausse par construction — mise à jour pour prouver la RÉALITÉ actuelle
# (les DEUX jobs existent et sont posés, substitution réelle comprise) sans
# perdre la couverture d'origine (rc≠0 si Jenkins injoignable, rc=0 sinon).
# La tolérance "job absent" elle-même reste couverte par le test 6 ci-dessus,
# avec un nom qui ne pourra jamais exister (api-request-inexistant-t3).
GH9="$TMP/gitea9"; mk_platform_repo "$GH9/ci/stoa-labs.git" "$TWO_TEAMS" "$ONE_API"
: > "$TMP/calls.log"; rm -rf "$BODYDIR"/*
OUT=$(cd "$REPO" && JENKINS_UI="http://127.0.0.1:1" JOBS="app-request api-request" ENVN=dev \
  GIT_HOST="$GH9" GIT_REPO=ci/stoa-labs GITEA_TOKEN=dummy bash "$SETUP" 2>&1); RC=$?
[ "$RC" -ne 0 ] && ok "JENKINS_UI injoignable -> rc≠0 (déclenche REFRESH_NOTE côté team-apply.sh)" || ko "aurait dû échouer"
: > "$TMP/calls.log"; rm -rf "$BODYDIR"/*
OUT=$(cd "$REPO" && JENKINS_UI="$JU" JOBS="app-request api-request" ENVN=dev \
  GIT_HOST="$GH9" GIT_REPO=ci/stoa-labs GITEA_TOKEN=dummy bash "$SETUP" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "Jenkins joignable, app-request+api-request posés -> rc=0 (branche succès)" || ko "échec inattendu (rc=$RC) : $OUT"
if [ -f "$BODYDIR/app-request.posted.xml" ] && [ -f "$BODYDIR/api-request.posted.xml" ]; then
  ok "les DEUX jobs de l'appel exact de team-apply.sh ont bien été posés"
else
  ko "un des deux jobs n'a pas été posé (app-request:$( [ -f "$BODYDIR/app-request.posted.xml" ] && echo oui || echo non ), api-request:$( [ -f "$BODYDIR/api-request.posted.xml" ] && echo oui || echo non ))"
fi
if grep -q '<string>banking-demo</string>' "$BODYDIR/api-request.posted.xml" 2>/dev/null \
   && ! grep -q '<!--CHOICES:TEAMS-->\|<!--CHOICES:APIS-->' "$BODYDIR/api-request.posted.xml" 2>/dev/null; then
  ok "api-request.job.xml : substitution réelle (banking-demo présent, aucun marqueur résiduel)"
else
  ko "api-request.job.xml : substitution absente ou incomplète"
fi

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
echo "== 12. le dépôt plateforme DÉJÀ dans le workspace (GC_PLATFORM_DIR) : aucun réseau =="
# Un job « pipeline from SCM » sur le dépôt plateforme a DÉJÀ ce dépôt dans le
# workspace de l'agent (lightweight=false). Le re-cloner par le réseau, c'est
# exiger d'un client un hôte joignable, un jeton, une branche `main` et une
# traversée de proxy pour lire un fichier qu'il a sous la main — et c'est là que
# ça casse en premier (déploiement client, 2026-09-03 : EQUIPES_INDISPONIBLES).
WSP="$TMP/ws-platform"; mkdir -p "$WSP/poc-control-plane-federation/ansible"
printf '%s' "$TWO_TEAMS" > "$WSP/poc-control-plane-federation/ansible/providers.dev.yml"
OUT=$(GC_PLATFORM_DIR="$WSP" GIT_HOST="/nonexistent/nope" GIT_REPO=ci/stoa-labs \
  bash -c ". '$LIB'; generate_choices_teams_raw dev" 2>&1); RC=$?
[ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c .)" = 2 ] && ok "GC_PLATFORM_DIR ⇒ 2 équipes lues SANS clone, SANS GITEA_TOKEN, hôte injoignable" || ko "rc=$RC out=$(tr '\n' ' ' <<<"$OUT")"
# Fail-closed : un répertoire fourni mais qui ne porte pas le dépôt ne retombe
# JAMAIS sur un clone (ici l'hôte est VALIDE — un repli réussirait et masquerait
# la méprise de configuration).
GHK="$TMP/gitea-knob"; mk_platform_repo "$GHK/ci/stoa-labs.git" "$TWO_TEAMS" ""
OUT=$(GC_PLATFORM_DIR="$TMP/vide-$$" GIT_HOST="$GHK" GIT_REPO=ci/stoa-labs GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_teams_raw dev" 2>&1); RC=$?
[ "$RC" -ne 0 ] && grep -q 'GC_PLATFORM_DIR' <<<"$OUT" && ok "GC_PLATFORM_DIR invalide ⇒ refus nommant le knob, AUCUN repli sur le clone (fail-closed)" || ko "rc=$RC (repli silencieux ?) : $(tr '\n' ' ' <<<"$OUT")"

echo
echo "== 13. la branche de base : DÉCOUVERTE, ou knob — jamais « main » en dur =="
# dépôt dont la SEULE branche est `develop` (aucune `main`) — le cas d'un client
GHD="$TMP/gitea-develop"; SRCD="$TMP/src-develop"
mkdir -p "$SRCD/poc-control-plane-federation/ansible" "$GHD/ci"
printf '%s' "$TWO_TEAMS" > "$SRCD/poc-control-plane-federation/ansible/providers.dev.yml"
( cd "$SRCD" && git init -q -b develop && git -c user.name=t -c user.email=t@t add -A \
  && git -c user.name=t -c user.email=t@t commit -qm init ) >/dev/null 2>&1
git clone -q --bare "$SRCD" "$GHD/ci/stoa-labs.git" >/dev/null 2>&1
# SANS KNOB (L3, 2026-09-10) : la HEAD du dépôt dit `develop`, la lib la
# DÉCOUVRE et les listes sortent. C'est le renversement du lot L3 — avant, ce
# même appel échouait en citant une branche « main » que ce client n'a jamais eue.
OUT=$(GIT_HOST="$GHD" GIT_REPO=ci/stoa-labs GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_teams_raw dev" 2>&1); RC=$?
[ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c .)" = 2 ] && ! grep -q 'main' <<<"$OUT" \
  && ok "aucun knob, HEAD=develop ⇒ la branche est DÉCOUVERTE et les listes sortent (« main » n'est plus deviné)" \
  || ko "rc=$RC : $(tr '\n' ' ' <<<"$OUT")"
# et un dépôt qui n'annonce RIEN (inexistant) est un refus NOMMÉ, pas un « main »
OUT=$(GIT_HOST="$GHD" GIT_REPO=ci/inexistant GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_teams_raw dev" 2>&1); RC=$?
[ "$RC" -ne 0 ] && grep -q 'GIT_UNREACHABLE' <<<"$OUT" && grep -q 'BRANCHE_PAR_DEFAUT_INCONNUE' <<<"$OUT" && ! grep -qw 'main' <<<"$OUT" \
  && ok "dépôt qui n'annonce aucune HEAD ⇒ GIT_UNREACHABLE + BRANCHE_PAR_DEFAUT_INCONNUE, et pas un clone « -b main » à l'aveugle" \
  || ko "rc=$RC : $(tr '\n' ' ' <<<"$OUT")"
OUT=$(GIT_BASE=develop GIT_HOST="$GHD" GIT_REPO=ci/stoa-labs GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_teams_raw dev" 2>&1); RC=$?
[ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c .)" = 2 ] && ok "GIT_BASE=develop ⇒ les listes sortent (le knob d'ADR-075 atteint ENFIN ce clone)" || ko "GIT_BASE ignoré : rc=$RC $(tr '\n' ' ' <<<"$OUT")"

echo
echo "== 14. l'utilisateur du Basic est un knob (GIT_USER), plus « x » en dur =="
SHIMD="$TMP/shim"; mkdir -p "$SHIMD"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$GIT_CONFIG_VALUE_0" > "%s/hdr.txt"\nexit 128\n' "$TMP" > "$SHIMD/git"; chmod 700 "$SHIMD/git"
PATH="$SHIMD:$PATH" GIT_USER=sof_svc GIT_HOST="https://scm.example/" GIT_REPO=org/depot GITEA_TOKEN=JETON \
  bash -c ". '$LIB'; generate_choices_teams_raw dev" >/dev/null 2>&1
HDR=$(sed -E 's/^Authorization: Basic //' "$TMP/hdr.txt" 2>/dev/null | base64 -d 2>/dev/null)
[ "$HDR" = "sof_svc:JETON" ] && ok "GIT_USER=sof_svc ⇒ en-tête Basic « sof_svc:JETON » (un SCM qui refuse l'utilisateur « x » passe)" || ko "en-tête construit : '${HDR:-vide}'"
PATH="$SHIMD:$PATH" GIT_HOST="https://scm.example/" GIT_REPO=org/depot GITEA_TOKEN=JETON \
  bash -c ". '$LIB'; generate_choices_teams_raw dev" >/dev/null 2>&1
HDR=$(sed -E 's/^Authorization: Basic //' "$TMP/hdr.txt" 2>/dev/null | base64 -d 2>/dev/null)
[ "$HDR" = "x:JETON" ] && ok "sans GIT_USER ⇒ « x:JETON », comportement d'avant octet pour octet" || ko "défaut altéré : '${HDR:-vide}'"

echo
echo "== 15. AUTO-DIAGNOSTIC (incident client 2026-09-07) : le SEUL log Jenkins dit quel dépôt, quelle branche, quelle cause, quel chemin =="
# LA SIGNATURE EXACTE DU BUILD ROUGE, rejouée : dépôt plateforme DÉJÀ dans le
# workspace (GC_PLATFORM_DIR, ce que pose ci/Jenkinsfile.app-request), deux
# dépôts d'équipe DÉCLARÉS et injoignables, aucun clients/. Avant le correctif,
# tout le log tenait en trois lignes sans une seule valeur exploitable :
#   (avertissement) dépôt d'équipe ibafraud/accounts-api illisible sur main — ignoré pour cette liste
#   (avertissement) dépôt d'équipe fbi/accounts-api illisible sur main — ignoré pour cette liste
#   APIS_EMPTY : aucune API publiée trouvée (clients/ + dépôts d'équipe déclarés)
# Le préfixe du livrable est NON DÉFAUT ici (GIT_SUBDIR=livrable) : la
# disposition du client (« apim-control-plane-federation ») n'était couverte par
# AUCUNE épreuve de cette suite, alors que c'est elle qui compose le chemin balayé.
mk_ws(){ # $1=racine workspace $2=préfixe livrable ('' = racine) $3=providers.dev.yml $4=1 -> créer clients/ VIDE
  local d="$1"
  [ -n "$2" ] && d="$1/$2"
  mkdir -p "$d/ansible"
  printf '%s' "$3" > "$d/ansible/providers.dev.yml"
  [ "${4:-0}" = "1" ] && mkdir -p "$d/clients"
  return 0
}
mk_team_repo_sans_api(){ # $1=racine bare — dépôt d'équipe RÉEL mais sans apis/*.publish.yml
  local barecdir="$1" src="$TMP/src-noapi-$$_$RANDOM"
  mkdir -p "$src"; printf 'rien ici\n' > "$src/README.md"
  ( cd "$src" && git init -q -b main && git -c user.name=t -c user.email=t@t add -A \
    && git -c user.name=t -c user.email=t commit -qm init >/dev/null )
  mkdir -p "$(dirname "$barecdir")"
  git clone -q --bare "$src" "$barecdir" >/dev/null
}
TWO_REPOS_ABSENTS='providers:
  - team: ibafraud
    repo: ibafraud/accounts-api
    approvers: []
  - team: fbi
    repo: fbi/accounts-api
    approvers: []
'
ONE_REPO_PRESENT='providers:
  - team: banking-demo
    repo: banking-demo/accounts-api
    approvers: []
'

echo "-- 15a. deux dépôts d'équipe illisibles + clients/ ABSENT (le build de la BdF) --"
WS15="$TMP/ws-bdf"; mk_ws "$WS15" "livrable" "$TWO_REPOS_ABSENTS" 0
GH15="$TMP/gitea15"; mkdir -p "$GH15"        # forge VIDE : aucun dépôt d'équipe n'y existe
GC_PLATFORM_DIR="$WS15" GIT_SUBDIR=livrable GIT_HOST="$GH15" GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >"$TMP/d15a.out" 2>"$TMP/d15a.err"; RC=$?
E15A="$TMP/d15a.err"; RC15A=$RC   # le rc RÉEL, relu par la § 17 (8/9) — elle y passait le littéral 1
[ "$RC" -ne 0 ] && ok "liste vide ⇒ rc≠0 (fail-closed inchangé)" || ko "aurait dû échouer (rc=$RC)"
[ ! -s "$TMP/d15a.out" ] && ok "stdout RIGOUREUSEMENT vide sur le chemin d'échec (aucun diagnostic ne pollue le fragment)" \
  || ko "stdout pollué : $(head -3 "$TMP/d15a.out" | tr '\n' ' ')"
[ "$(grep -c '(avertissement)' "$E15A")" = "2" ] && ok "un avertissement par dépôt d'équipe sauté (2)" || ko "avertissements : $(grep -c '(avertissement)' "$E15A")"
# L3 (2026-09-10) : la branche n'est plus nommée quand AUCUNE n'a été demandée —
# ces deux dépôts n'existent pas, ils n'ont annoncé aucune HEAD, et « sur main »
# nommait ici une branche que git n'avait jamais réclamée.
grep -qF "dépôt d'équipe ibafraud/accounts-api illisible ($GH15/ibafraud/accounts-api.git)" "$E15A" \
  && ok "l'avertissement cite l'URL COMPOSÉE — exactement ce que git a tenté (hôte + repo + .git)" \
  || ko "URL absente de l'avertissement : $(grep -m1 'ibafraud' "$E15A")"
grep -qF "dépôt d'équipe fbi/accounts-api illisible ($GH15/fbi/accounts-api.git)" "$E15A" \
  && ok "idem pour le second dépôt (chaque dépôt a SA cause, pas seulement le dernier)" \
  || ko "URL absente pour fbi : $(grep -m1 'fbi' "$E15A")"
grep -c 'BRANCHE_PAR_DEFAUT_INCONNUE' "$E15A" | grep -qx 2 \
  && ok "et la cause NOMMÉE est la bonne : le dépôt n'annonce pas sa branche par défaut (jamais « main » deviné)" \
  || ko "cause de branche absente : $(grep -m1 'ibafraud' "$E15A")"
CAUSES=$(grep -c "ignoré pour cette liste — .\{10,\}" "$E15A")
[ "$CAUSES" = "2" ] && ! grep -q 'aucune sortie de git' "$E15A" \
  && ok "les DEUX avertissements portent la CAUSE de git (_GC_CLONE_ERR relayé, plus jeté)" \
  || ko "cause de git absente ($CAUSES/2) : $(grep -m1 'avertissement' "$E15A")"
grep -q '^CHOICES_SKIPPED_REPOS=2$' "$E15A" \
  && ok "marqueur CHOICES_SKIPPED_REPOS=2 émis SUR LE CHEMIN D'ÉCHEC (il vivait après le return 1), seul sur sa ligne" \
  || ko "marqueur absent/altéré sur le chemin d'échec : $(grep -m1 'CHOICES_SKIPPED' "$E15A")"
grep -q '^APIS_EMPTY : ' "$E15A" && ok "l'identifiant de refus APIS_EMPTY reste EN TÊTE (grep en place intact)" || ko "APIS_EMPTY déplacé/renommé"
A15=$(grep -m1 '^APIS_EMPTY : ' "$E15A")
grep -qF "Balayé livrable/clients" <<<"$A15" && ok "APIS_EMPTY nomme le CHEMIN BALAYÉ, préfixé par GIT_SUBDIR (livrable/clients) — la question du client" || ko "chemin balayé absent : $A15"
grep -qF "répertoire ABSENT" <<<"$A15" && ok "APIS_EMPTY dit que ce répertoire est ABSENT (indistinguable d'un clients/ vide jusqu'ici)" || ko "état du répertoire absent du refus : $A15"
grep -qF "motif '*/apis/*.publish.yml'" <<<"$A15" && ok "APIS_EMPTY donne le MOTIF find (un fichier hors d'un segment apis/ est invisible)" || ko "motif absent : $A15"
grep -qF "livrable/ansible/providers.dev.yml" <<<"$A15" && ok "APIS_EMPTY rappelle le fichier providers réellement lu" || ko "providers absent du refus : $A15"
grep -qF "2 dépôt(s) d'équipe déclaré(s), 0 cloné(s), 2 illisible(s) (" <<<"$A15" \
  && ! grep -q 'illisible(s) sur' <<<"$A15" \
  && ok "APIS_EMPTY compte déclarés/clonés/sautés, et SANS knob ne nomme aucune branche d'ensemble (chaque dépôt a la sienne)" || ko "comptes absents : $A15"
grep -qF "REMÈDE : poser livrable/clients/<projet>/apis/<nom>.publish.yml" <<<"$A15" \
  && ok "APIS_EMPTY dit OÙ poser un fichier — l'opérateur agit sans lire le code" || ko "remède absent : $A15"

echo "-- 15b. contre-témoin : clients/ PRÉSENT (vide) et un dépôt d'équipe RÉELLEMENT cloné, mais sans publish.yml --"
WS15B="$TMP/ws-clients-vide"; mk_ws "$WS15B" "poc-control-plane-federation" "$ONE_REPO_PRESENT" 1
GH15B="$TMP/gitea15b"; mk_team_repo_sans_api "$GH15B/banking-demo/accounts-api.git"
GC_PLATFORM_DIR="$WS15B" GIT_HOST="$GH15B" GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >"$TMP/d15b.out" 2>"$TMP/d15b.err"; RC=$?
B15=$(grep -m1 '^APIS_EMPTY : ' "$TMP/d15b.err")
[ "$RC" -ne 0 ] && ok "clients/ présent mais vide ⇒ toujours fail-closed" || ko "aurait dû échouer (rc=$RC)"
grep -qF "répertoire présent" <<<"$B15" && ok "le refus DISTINGUE « présent » d'« ABSENT » (mutation de 15a : le même texte y disait ABSENT)" || ko "état non distingué : $B15"
grep -qF "1 dépôt(s) d'équipe déclaré(s), 1 cloné(s), 0 illisible(s)" <<<"$B15" \
  && ok "comptes justes quand le clone RÉUSSIT (1 déclaré, 1 cloné, 0 sauté) — le refus ne calomnie pas la forge" || ko "comptes faux : $B15"
grep -q '^CHOICES_SKIPPED_REPOS=0$' "$TMP/d15b.err" && ok "marqueur=0 sur le chemin d'échec (rien n'a été sauté : le problème est le CONTENU)" || ko "marqueur inattendu : $(grep -m1 'CHOICES_SKIPPED' "$TMP/d15b.err")"
grep -q '(avertissement)' "$TMP/d15b.err" && ko "avertissement émis alors qu'aucun dépôt n'a été sauté" || ok "aucun avertissement (contre-témoin propre)"

echo "-- 15c. la branche affichée est la branche DEMANDÉE (GIT_BASE), plus « main » en dur --"
GC_PLATFORM_DIR="$WS15" GIT_SUBDIR=livrable GIT_BASE=develop GIT_HOST="$GH15" GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >/dev/null 2>"$TMP/d15c.err"
grep -qF "illisible sur develop (" "$TMP/d15c.err" && ! grep -q "illisible sur main" "$TMP/d15c.err" \
  && ok "GIT_BASE=develop ⇒ « illisible sur develop » (le littéral « main » mentait à tout client dont la base est master/develop)" \
  || ko "branche non relayée : $(grep -m1 'avertissement' "$TMP/d15c.err")"
grep -qF "illisible(s) sur develop" "$TMP/d15c.err" && ok "APIS_EMPTY relaie la même branche que les avertissements" || ko "branche absente d'APIS_EMPTY : $(grep -m1 '^APIS_EMPTY' "$TMP/d15c.err")"

echo "-- 15d. canari : AUCUN identifiant ne fuit par les nouveaux messages --"
# 2026-09-07 — CETTE ÉPREUVE ÉTAIT UN VERT VACANT. Son canari,
# « MOTDEPASSE-CANARI », ne contenait ni « / » ni « @ » : exactement les deux
# seuls caractères sur lesquels la classe [^/@[:space:]]* de _gc_redact
# s'arrêtait. Elle ne pouvait donc pas rougir sur le défaut réel. Elle comptait
# de surcroît un MARQUEUR (« identifiants masqués » ≥ 3) au lieu de mesurer
# l'ABSENCE du secret : un message perdu l'aurait faite rougir, un secret fui
# ne l'aurait pas fait rougir. Deux canaris désormais, chacun portant l'un des
# deux caractères, et l'assertion porte sur l'ABSENCE — stdout ET stderr.
# Mesuré sur le worktree d'avant : 3 occurrences EN CLAIR (canari « / ») et
# 3 occurrences de la QUEUE « NARI-AROBASE » (canari « @ »).
#
# 2026-09-07 (quater) — CES CANARIS MESURENT LE FILET, PLUS LA GARANTIE. Depuis
# I1, un GIT_HOST porteur d'identifiants est REFUSÉ avant tout accès réseau :
# ces trois messages n'existeraient plus du tout, et l'épreuve ne mesurerait
# rien. On pose donc GIT_HOST_USERINFO_TOLERE=1 — c'est EXACTEMENT le cas où
# l'expurgation redevient la seule protection, donc le seul cas où elle mérite
# encore d'être mesurée. Le refus lui-même est gardé en § 25.
# Et deux canaris de plus, portant les caractères de la passe 4 : l'ESPACE et
# le SAUT DE LIGNE. Mesuré sur le worktree d'avant, avec le knob : 3 occurrences
# EN CLAIR pour l'espace, 3 de la tête « u:CAN » pour le saut de ligne — la
# règle 3, littérale, était jouée APRÈS des règles par motif qui détruisaient
# le littéral qu'elle cherchait.
for CAS in "slash:CANARI-SLASH/DEUX:CANARI-SLASH" "arobase:C@NARI-AROBASE:NARI-AROBASE" \
           "espace:CANARI ESPACE:CANARI" "tabulation:CANARI	TABULATION:CANARI" \
           "saut-de-ligne:CANARI
NOUVELLE-LIGNE:CANARI"; do
  NOM="${CAS%%:*}"; RESTE="${CAS#*:}"; SECRET="${RESTE%%:*}"; TRACE="${RESTE#*:}"
  GIT_HOST_USERINFO_TOLERE=1 GC_PLATFORM_DIR="$WS15" GIT_SUBDIR=livrable GIT_HOST="http://u:${SECRET}@127.0.0.1:1/x" GITEA_TOKEN=dummy \
    bash -c ". '$LIB'; generate_choices_apis_raw dev" >"$TMP/d15d-$NOM.out" 2>"$TMP/d15d-$NOM.err"
  if grep -qF "$TRACE" "$TMP/d15d-$NOM.err" "$TMP/d15d-$NOM.out"; then
    ko "FUITE (canari « $NOM ») : $(grep -cF "$TRACE" "$TMP/d15d-$NOM.err") occurrence(s) de « $TRACE » sur stderr"
  else
    ok "canari « $NOM » : le secret n'apparaît NI sur stderr NI sur stdout (l'ancienne regex s'arrêtait sur ce caractère)"
  fi
done
# et l'absence vient d'une EXPURGATION, pas d'un message évanoui : chacun des
# trois messages du chemin d'équipe la porte.
[ "$(grep -c '(avertissement).*identifiants masqués' "$TMP/d15d-slash.err")" = "2" ] \
  && ok "les DEUX avertissements portent « <identifiants masqués> » (le message existe, il est expurgé)" \
  || ko "expurgation partielle des avertissements : $(grep -c '(avertissement).*identifiants masqués' "$TMP/d15d-slash.err")/2"
grep -q '^APIS_EMPTY .*identifiants masqués' "$TMP/d15d-slash.err" \
  && ok "APIS_EMPTY aussi (c'est le 3e point d'émission de GIT_HOST ouvert par le correctif)" \
  || ko "APIS_EMPTY sans expurgation : $(grep -m1 '^APIS_EMPTY' "$TMP/d15d-slash.err")"

echo "-- 15e. GIT_UNREACHABLE : la source est nommée AVEC un séparateur, et expurgée --"
GC_PLATFORM_DIR="$TMP/ws-sans-depot-$$" GIT_HOST="$GH15" GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >"$TMP/d15e.out" 2>"$TMP/d15e.err"; RC=$?
[ "$RC" -ne 0 ] && [ ! -s "$TMP/d15e.out" ] && ok "knob invalide ⇒ rc≠0, stdout vide (aucun repli sur un clone)" || ko "rc=$RC, stdout=$(head -1 "$TMP/d15e.out")"
grep -qF "(répertoire fourni $TMP/ws-sans-depot-$$)" "$TMP/d15e.err" \
  && ok "GIT_UNREACHABLE nomme le répertoire fourni AVEC l'espace (le texte était collé au chemin : « répertoire fourni/home/… »)" \
  || ko "libellé collé ou chemin absent : $(grep -m1 'GIT_UNREACHABLE' "$TMP/d15e.err")"


echo
echo "== 16. REVUE ADVERSARIALE (2026-09-07) : les neuf défauts du correctif d'auto-diagnostic =="
# Chacune de ces épreuves a été écrite APRÈS avoir MESURÉ le défaut sur le
# worktree, et chacune ROUGIT quand on remet le code d'avant (mutation jouée).

mk_team_repo_casse(){ # $1=racine bare — dépôt d'équipe RÉEL portant un publish.yml illisible
  local barecdir="$1" src="$TMP/src-casse-$$_$RANDOM"
  mkdir -p "$src/apis"; printf 'apim_api:\n  name: [\n' > "$src/apis/casse.publish.yml"
  ( cd "$src" && git init -q -b main && git -c user.name=t -c user.email=t@t add -A \
    && git -c user.name=t -c user.email=t commit -qm init >/dev/null )
  mkdir -p "$(dirname "$barecdir")"
  git clone -q --bare "$src" "$barecdir" >/dev/null
}

echo "-- 16b. D1(b) : la méprise est NOMMÉE, une seule fois — et depuis I1 elle REFUSE --"
# 2026-09-07 (quater) : L'ARBITRAGE A CHANGÉ, et cette épreuve gardait le
# contraire. Elle affirmait « AVERTISSEMENT et non refus : une configuration qui
# marche aujourd'hui doit continuer de marcher » — c'était la prémisse même qui
# a laissé vivre QUATRE fuites successives sous une suite verte. La voici
# retournée : par défaut, un GIT_HOST porteur d'identifiants REFUSE ; le knob
# GIT_HOST_USERINFO_TOLERE=1 rend l'ancien comportement, bruyamment.
N_AV=$(grep -c '^GIT_HOST_PORTE_IDENTIFIANTS_TOLERE : ' "$TMP/d15d-slash.err")
[ "$N_AV" = "1" ] && ok "sous le knob, GIT_HOST_PORTE_IDENTIFIANTS_TOLERE émis UNE fois, identifiant en tête de ligne" || ko "avertissement toléré émis $N_AV fois (attendu 1)"
grep -q 'FORGE_USER' "$TMP/d15d-slash.err" && grep -q 'FORGE_SECRET' "$TMP/d15d-slash.err" \
  && ok "l'avertissement nomme la voie à prendre (FORGE_USER + FORGE_SECRET)" || ko "l'avertissement ne nomme pas la voie de remplacement"
# SOURCE PARFAITEMENT VALIDE + GIT_HOST porteur d'identifiants : c'est le cas
# qui SORTAIT UNE LISTE en rc 0 pendant que le secret fuyait. Il refuse.
WS16="$TMP/ws-userinfo"; mk_ws "$WS16" "livrable" "$TWO_TEAMS" 1
mkdir -p "$WS16/livrable/clients/projet/apis"
printf 'apim_api:\n  name: "accounts-read"\n  version: "1.0.0"\n' > "$WS16/livrable/clients/projet/apis/accounts-read.publish.yml"
OUT16=$(GC_PLATFORM_DIR="$WS16" GIT_SUBDIR=livrable GIT_HOST="http://u:s3cr3t@forge.example" GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" 2>"$TMP/d16b.err"); RC=$?
[ "$RC" -ne 0 ] && [ -z "$OUT16" ] && grep -q '^GIT_HOST_PORTE_IDENTIFIANTS : ' "$TMP/d16b.err" \
  && ok "REFUS et non avertissement : rc≠0, stdout VIDE, refus nommé en tête de ligne — la source était pourtant valide (c'est le cas qui rendait rc 0 en laissant fuir)" \
  || ko "le refus I1 n'a pas eu lieu : rc=$RC out='$OUT16' — $(head -c 60 "$TMP/d16b.err")"
# LA PORTE DE SORTIE, sur EXACTEMENT la même configuration : le run continue.
OUT16T=$(GIT_HOST_USERINFO_TOLERE=1 GC_PLATFORM_DIR="$WS16" GIT_SUBDIR=livrable GIT_HOST="http://u:s3cr3t@forge.example" GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" 2>"$TMP/d16bt.err"); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT16T" = "accounts-read@1.0.0" ] && grep -q '^GIT_HOST_PORTE_IDENTIFIANTS_TOLERE : ' "$TMP/d16bt.err" \
  && ! grep -q '^GIT_HOST_PORTE_IDENTIFIANTS : ' "$TMP/d16bt.err" \
  && ok "GIT_HOST_USERINFO_TOLERE=1 sur la MÊME config : rc 0, la liste sort, et l'avertissement TOLERE remplace le refus" \
  || ko "la porte de sortie ne rend pas la main : rc=$RC out='$OUT16T'"
grep -qE '^GIT_HOST_PORTE_IDENTIFIANTS(_TOLERE)? : ' "$E15A" && ko "refus/avertissement émis pour un GIT_HOST SANS identifiants (faux positif)" \
  || ok "contre-témoin : ni refus ni avertissement quand GIT_HOST ne porte pas d'« @ » (15a)"

echo "-- 16c. D2 : la mesure morte est retirée (elle ne pouvait valoir que 0) --"
# APIS_EMPTY n'est atteint que si la liste est VIDE : un publish.yml retenu
# l'aurait remplie, un publish.yml illisible sort en PUBLISH_YML_PARSE. Le
# compte « → N fichier(s) » valait donc 0 par construction — mutation jouée sur
# le worktree d'avant : forcer N=42 laissait la suite à 82/82, et le refus
# servait « → 42 fichier(s) » sans que rien ne rougisse.
grep -qF "motif '*/apis/*.publish.yml' → aucun fichier retenu" <<<"$A15" \
  && ok "APIS_EMPTY dit « aucun fichier retenu » — un fait, pas un nombre que personne ne peut démentir" || ko "formulation attendue absente : $A15"
grep -qE "motif '\*/apis/\*\.publish\.yml' → [0-9]+ fichier" <<<"$A15" \
  && ko "APIS_EMPTY porte encore un COMPTE de fichiers (mesure morte : elle ne peut valoir que 0)" \
  || ok "aucun compte de fichiers dans APIS_EMPTY (la mutation à 42 n'a plus où s'écrire)"
# Même règle pour le volet « dépôts d'équipe » : sans déclaration, aucune
# branche et aucun hôte n'ont été mis en jeu — les nommer serait affirmer un
# geste qui n'a pas eu lieu.
WS16C="$TMP/ws-zero-repo"; mk_ws "$WS16C" "livrable" "$TWO_TEAMS" 0
GC_PLATFORM_DIR="$WS16C" GIT_SUBDIR=livrable GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >/dev/null 2>"$TMP/d16c.err"
C16=$(grep -m1 '^APIS_EMPTY : ' "$TMP/d16c.err")
grep -qF "aucun dépôt d'équipe déclaré" <<<"$C16" && ! grep -qF "illisible(s) sur" <<<"$C16" \
  && ok "aucun dépôt déclaré ⇒ « aucun dépôt d'équipe déclaré », sans citer une branche ni une forge jamais approchées" \
  || ko "le refus cite une forge/branche non mises en jeu : $C16"

echo "-- 16d. D3 (G2, 2026-09-07 bis) : AUCUNE position n'est promise — garde COMPORTEMENTALE --"
# CETTE ÉPREUVE ÉTAIT À MOITIÉ UN VERT VACANT. Sa seconde assertion était un
# `grep -qiE 'marqueur … en FIN de sortie' "$LIB"` : elle contrôlait l'ABSENCE
# d'une PHRASE dans la source, pas le COMPORTEMENT. Elle ne pouvait donc pas
# rougir contre le défaut qu'elle prétendait interdire (un marqueur redevenu
# dernier), ni contre celui que le correctif a introduit à sa place : le contrat
# affirmait ensuite, SANS RÉSERVE, « la DERNIÈRE ligne est le refus » — faux sur
# les deux chemins PUBLISH_YML_PARSE, où _gc_collect_publish_yml écrit le refus
# AVANT que la fonction n'émette le marqueur.
# L'en-tête porte désormais une TABLE de positions MESURÉES ; ces trois
# assertions la gardent, en observant stderr et non le texte du commentaire.
# Le SECOND chemin, produit ICI (16i le rejouera pour son propre compte) : un
# publish.yml corrompu dans le clients/ de la plateforme ⇒ PUBLISH_YML_PARSE.
WS16D="$TMP/ws-16d"; mk_ws "$WS16D" "livrable" "$TWO_TEAMS" 1
mkdir -p "$WS16D/livrable/clients/projet/apis"
printf 'apim_api:\n  name: [\n' > "$WS16D/livrable/clients/projet/apis/casse.publish.yml"
E16D="$TMP/d16d.err"
GC_PLATFORM_DIR="$WS16D" GIT_SUBDIR=livrable GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >/dev/null 2>"$E16D"; RC16D=$?
[ "$(tail -1 "$E15A" | cut -c1-11)" = "APIS_EMPTY " ] \
  && [ -z "$(tail -1 "$E15A" | grep '^CHOICES_SKIPPED_REPOS=')" ] \
  && ok "table, ligne 1 — chemin APIS_EMPTY : la dernière ligne est le REFUS ; un « tail -1 | grep ^CHOICES_SKIPPED_REPOS= » ne trouve RIEN" \
  || ko "chemin APIS_EMPTY : dernière ligne inattendue — $(tail -1 "$E15A" | cut -c1-40)"
[ -n "$(tail -1 "$E16D" | grep '^CHOICES_SKIPPED_REPOS=')" ] \
  && [ -z "$(tail -1 "$E16D" | grep -E '^(PUBLISH_YML_PARSE|APIS_EMPTY) : ')" ] \
  && ok "table, ligne 2 — chemin PUBLISH_YML_PARSE : la dernière ligne est le MARQUEUR ; un « tail -1 » y chercherait le refus en vain (la position s'inverse d'un chemin à l'autre : elle n'est PAS un contrat)" \
  || ko "chemin PUBLISH_YML_PARSE : dernière ligne inattendue — $(tail -1 "$E16D" | cut -c1-40)"
# CE QUI EST PROMIS, et la seule lecture correcte : le grep ANCRÉ, dans les deux
# sens, sur les DEUX chemins. C'est cette assertion qui rougit si quelqu'un
# recolle le marqueur à un autre message (il perdrait son ancre ^).
D3_OK=1
for F in "$E15A" "$E16D"; do
  grep -q '^CHOICES_SKIPPED_REPOS=[0-9][0-9]*$' "$F" || D3_OK=0
  grep -qE '^(PUBLISH_YML_PARSE|APIS_EMPTY) : ' "$F" || D3_OK=0
done
[ "$D3_OK" = 1 ] \
  && ok "sur les DEUX chemins, les greps ANCRÉS prescrits par l'en-tête trouvent l'un ET l'autre (^CHOICES_SKIPPED_REPOS= seul sur sa ligne, refus en tête de ligne) — c'est ce qui remplace la promesse de position" \
  || ko "un grep ancré échoue sur l'un des deux chemins (marqueur recollé à un autre message ?)"

echo "-- 16e. D4 : _GC_CLONE_ERR est posée sur TOUTE sortie en échec de _gc_clone --"
# Sans secret, _gc_clone rendait 1 SANS poser la globale : le premier
# consommateur par dépôt — le nouvel avertissement — servait alors
# « aucune sortie de git » alors que la cause est un secret manquant (mesuré).
env -u GITEA_TOKEN -u FORGE_SECRET GC_PLATFORM_DIR="$WS15" GIT_SUBDIR=livrable GIT_HOST="http://forge.example" \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >/dev/null 2>"$TMP/d16e.err"
[ "$(grep -c 'ignoré pour cette liste — SECRET_FORGE_REQUIS' "$TMP/d16e.err")" = "2" ] \
  && ok "les DEUX avertissements portent la VRAIE cause (SECRET_FORGE_REQUIS), pas un silence" \
  || ko "cause du secret manquant absente : $(grep -m1 'avertissement' "$TMP/d16e.err")"
grep -q 'aucune sortie de git' "$TMP/d16e.err" \
  && ko "un avertissement dit encore « aucune sortie de git » alors qu'aucun clone n'a été tenté" \
  || ok "plus aucun « aucune sortie de git » sur ce chemin : la globale est posée avant le return"

echo "-- 16f. D5 : quand GC_PLATFORM_DIR décide, le refus ne nomme NI dépôt NI branche --"
# Mesuré : « PROVIDERS_MISSING : … absent du dépôt plateforme ci/stoa-labs@master
# (répertoire fourni …) » — or aucun dépôt et aucune branche n'ont été consultés,
# et chez le client « ci/stoa-labs » n'existe pas.
GC_PLATFORM_DIR="$WS15" GIT_SUBDIR=livrable GIT_BASE=master GIT_REPO=ci/inexistant GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw rec" >/dev/null 2>"$TMP/d16f.err"
F16=$(grep -m1 '^PROVIDERS_MISSING : ' "$TMP/d16f.err")
! grep -qF 'ci/inexistant' <<<"$F16" && ! grep -qF '@master' <<<"$F16" \
  && ok "PROVIDERS_MISSING ne nomme ni GIT_REPO ni la branche : ni l'un ni l'autre n'a été consulté" \
  || ko "le refus nomme un dépôt/une branche jamais consultés : $F16"
grep -qF "répertoire fourni $WS15" <<<"$F16" && ok "PROVIDERS_MISSING nomme le RÉPERTOIRE réellement lu" || ko "répertoire absent du refus : $F16"
GC_PLATFORM_DIR="$TMP/ws-absent-$$" GIT_SUBDIR=livrable GIT_BASE=master GIT_REPO=ci/inexistant GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >/dev/null 2>"$TMP/d16f2.err"
F16B=$(grep -m1 '^GIT_UNREACHABLE : ' "$TMP/d16f2.err")
! grep -qF 'ci/inexistant' <<<"$F16B" && ! grep -qF '@master' <<<"$F16B" \
  && ok "GIT_UNREACHABLE, même règle : le knob décide, le message nomme le répertoire" || ko "GIT_UNREACHABLE nomme un dépôt/branche fictifs : $F16B"

echo "-- 16g. D6 : sur le chemin de CLONE, APIS_EMPTY nomme ENFIN le dépôt cloné --"
# C'est le mode de setup-team-onboard-jobs.sh — donc de la re-pose déclenchée
# par team-apply.sh et team-publish.sh. La question littérale du client était
# « quel dépôt est cloné » ; ses deux refus frères le nommaient, pas celui-ci.
GHP="$TMP/gitea16g"; SRCP="$TMP/src-16g"
mkdir -p "$SRCP/livrable/ansible"
printf '%s' "$TWO_REPOS_ABSENTS" > "$SRCP/livrable/ansible/providers.dev.yml"
( cd "$SRCP" && git init -q -b main && git -c user.name=t -c user.email=t@t add -A \
  && git -c user.name=t -c user.email=t@t commit -qm init ) >/dev/null 2>&1
mkdir -p "$GHP/org"; git clone -q --bare "$SRCP" "$GHP/org/plateforme.git" >/dev/null 2>&1
GIT_SUBDIR=livrable GIT_HOST="$GHP" GIT_REPO=org/plateforme GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >/dev/null 2>"$TMP/d16g.err"
G16=$(grep -m1 '^APIS_EMPTY : ' "$TMP/d16g.err")
grep -qF "dépôt plateforme org/plateforme@main" <<<"$G16" \
  && ok "APIS_EMPTY nomme GIT_REPO@branche quand le dépôt a été CLONÉ (0 occurrence avant)" || ko "dépôt cloné toujours anonyme : $G16"

echo "-- 16h. D7 : un clients/ SYMBOLIQUE est réellement balayé (find -L) --"
# « présent » se mesurait par [ -d ] (qui SUIT les liens) et le balayage par
# find en -P (qui ne les suit PAS en dernier composant) : un clients/ symbolique
# portant un publish.yml VALIDE rendait « répertoire présent … → 0 fichier ».
WS16H="$TMP/ws-lien"; mkdir -p "$WS16H/livrable/ansible" "$TMP/clients-reel/projet/apis"
printf '%s' "$TWO_TEAMS" > "$WS16H/livrable/ansible/providers.dev.yml"
printf 'apim_api:\n  name: "accounts-read"\n  version: "1.0.0"\n' > "$TMP/clients-reel/projet/apis/accounts-read.publish.yml"
ln -s "$TMP/clients-reel" "$WS16H/livrable/clients"
OUT16H=$(GC_PLATFORM_DIR="$WS16H" GIT_SUBDIR=livrable GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" 2>"$TMP/d16h.err"); RC=$?
[ "$RC" -eq 0 ] && ok "clients/ symbolique ⇒ rc 0 (le refus APIS_EMPTY était FAUX)" || ko "rc=$RC — $(grep -m1 'APIS_EMPTY' "$TMP/d16h.err")"
[ "$OUT16H" = "accounts-read@1.0.0" ] && ok "l'API cachée derrière le lien est bien servie (find -L)" || ko "liste servie : '$OUT16H'"

echo "-- 16i. D9 : le marqueur sort AUSSI sur les chemins PUBLISH_YML_PARSE --"
# Le commentaire promettait « Marqueur TOUJOURS émis » : vrai pour APIS_EMPTY,
# FAUX pour les deux PUBLISH_YML_PARSE — or ce sont des chemins où des dépôts
# ont pu être sautés AVANT que la corruption ne soit trouvée.
WS16I="$TMP/ws-casse"; mk_ws "$WS16I" "livrable" "$TWO_REPOS_ABSENTS" 0
GH16I="$TMP/gitea16i"; mk_team_repo_casse "$GH16I/fbi/accounts-api.git"   # ibafraud/* reste ABSENT ⇒ sauté
GC_PLATFORM_DIR="$WS16I" GIT_SUBDIR=livrable GIT_HOST="$GH16I" GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >"$TMP/d16i.out" 2>"$TMP/d16i.err"; RC=$?
[ "$RC" -ne 0 ] && [ ! -s "$TMP/d16i.out" ] && grep -q '^PUBLISH_YML_PARSE : ' "$TMP/d16i.err" \
  && ok "un publish.yml corrompu dans un dépôt d'équipe ⇒ PUBLISH_YML_PARSE, fail-closed, stdout vide (inchangé)" \
  || ko "rc=$RC / stdout / refus inattendus : $(head -1 "$TMP/d16i.err")"
grep -q '^CHOICES_SKIPPED_REPOS=1$' "$TMP/d16i.err" \
  && ok "le dépôt sauté AVANT la corruption est tout de même COMPTÉ (marqueur=1 sur le chemin PUBLISH_YML_PARSE)" \
  || ko "marqueur absent/faux sur ce chemin : $(grep -m1 'CHOICES_SKIPPED' "$TMP/d16i.err")"
# second chemin : la collecte du clients/ de la PLATEFORME, avant toute boucle.
WS16J="$TMP/ws-casse-plateforme"; mk_ws "$WS16J" "livrable" "$TWO_TEAMS" 1
mkdir -p "$WS16J/livrable/clients/projet/apis"; printf 'apim_api:\n  name: [\n' > "$WS16J/livrable/clients/projet/apis/casse.publish.yml"
GC_PLATFORM_DIR="$WS16J" GIT_SUBDIR=livrable GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >/dev/null 2>"$TMP/d16j.err"
grep -q '^PUBLISH_YML_PARSE : ' "$TMP/d16j.err" && grep -q '^CHOICES_SKIPPED_REPOS=0$' "$TMP/d16j.err" \
  && ok "clients/ de la plateforme corrompu ⇒ refus ET marqueur=0 (« rien n'a été sauté » se distingue de « marqueur absent »)" \
  || ko "marqueur absent sur la collecte plateforme : $(grep -m1 'CHOICES_SKIPPED' "$TMP/d16j.err")"

echo
echo "== 17. G1 : « le marqueur est émis sur TOUS les chemins d'échec » — les NEUF, un par un =="
# CE QUE LA REVUE A MESURÉ. L'en-tête affirmait « émis sur TOUS les chemins
# d'échec de generate_choices_apis_raw ». Trois `echo` RECOPIÉS le portaient sur
# trois chemins (APIS_EMPTY + les deux PUBLISH_YML_PARSE) ; les quatre autres
# — MKTEMP, GIT_UNREACHABLE, PROVIDERS_MISSING, PROVIDERS_PARSE — sortaient
# MUETS (mesuré : 0 occurrence). Une promesse plus forte que la précédente, et
# fausse. Le code n'a plus qu'UN point d'émission (_gc_emit_marker) ; cette
# épreuve balaie les huit sorties. Elle rougit si une seule perd son marqueur.
#
# 2026-09-07 (ter) — ET IL Y EN AVAIT HUIT. Cette section en balayait SEPT, et
# la phrase absolue de l'en-tête restait donc fausse : la garde d'argument
# (`local envn="${1:?env requis}"`) était une HUITIÈME sortie, muette. MESURÉ
# sur le worktree d'avant : rc=127, 0 marqueur, message préfixé par
# « fichier: ligne N: » (donc pas un refus en tête de ligne) — et le shell
# APPELANT abattu au passage, si bien qu'un `|| return 1` n'était jamais
# atteint. Une énumération est la seule preuve d'une phrase absolue : elle vaut
# ce que vaut son exhaustivité, et personne ne l'avait recomptée.
#
# 2026-09-07 (quater) — ET IL Y EN A NEUF. La porte GIT_HOST (I1, § 25) est une
# sortie de plus, et le compte est redevenu faux d'un cran POUR LA DEUXIÈME FOIS
# de suite. Un compte écrit en toutes lettres est un maillon qu'aucune assertion
# ne garde : ce qui le garde, c'est cette énumération — à condition qu'elle soit
# tenue à jour EN MÊME TEMPS que la sortie ajoutée.
# DEUX VERTS VACANTS FERMÉS ICI, aussi (I5a) : les chemins 1/9 et 6/9 passaient
# le LITTÉRAL « 1 » comme rc OBSERVÉ à chemin_marque. Le rc n'était donc gardé
# par RIEN sur ces deux lignes — un chemin devenu rc 0 les aurait laissées
# vertes. Le 1/9 avait de surcroît une raison réelle (le `bash -c` finit par un
# `echo`, son rc est celui de l'`echo`, pas celui de la fonction) : la fonction
# relaie désormais SON rc par un `exit`. Le 6/9 et le 8/9 relisent le rc CAPTURÉ
# de la course qui a produit leur stderr (RC16D, RC15A).
#
# POURQUOI ÇA COMPTE : team-apply.sh:407 et team-publish.sh:470 lisent ce
# marqueur dans le log d'une re-pose. « Marqueur absent » doit avoir UNE seule
# lecture — generate_choices_apis_raw n'a pas tourné — et non « elle a tourné et
# elle est morte tôt ». Sur les quatre chemins précoces le compte vaut 0, et
# c'est un FAIT : rien n'a été sauté, parce que rien n'a été tenté.
chemin_marque(){ # $1=libellé  $2=tag de refus attendu  $3=fichier stderr  $4=rc observé
  local lib="$1" tag="$2" err="$3" rc="$4" pb=""
  [ "$rc" -ne 0 ] || pb="${pb} rc=0(attendu≠0)"
  grep -q "^${tag} : " "$err" || pb="${pb} refus-${tag}-absent"
  grep -q '^CHOICES_SKIPPED_REPOS=[0-9][0-9]*$' "$err" || pb="${pb} MARQUEUR-ABSENT"
  [ -z "$pb" ] \
    && ok "chemin ${lib} ⇒ ${tag} ET le marqueur (ancré, seul sur sa ligne)" \
    || ko "chemin ${lib} :${pb} — $(head -1 "$err" | cut -c1-70)"
}

# 1/9 — ENV_REQUIS : la garde d'argument, AVANT tout contact avec la forge.
# Trois choses à la fois, et chacune manquait : un refus NOMMÉ en tête de ligne,
# le marqueur, et un appelant qui SURVIT (un `${VAR:?}` fait sortir un shell non
# interactif — le `; echo VIVANT` ci-dessous ne s'exécutait pas).
# Le `exit $RCF` relaie le rc de la FONCTION : sans lui, le rc du `bash -c` est
# celui de l'`echo` final (0), et c'est pour cela que cette ligne passait le
# littéral 1 — un vert vacant, qui ne gardait plus rien du tout.
bash -c ". '$LIB'; generate_choices_apis_raw; RCF=\$?; echo APPELANT-VIVANT; exit \$RCF" \
  >"$TMP/d17-0.out" 2>"$TMP/d17-0.err"; RC=$?
chemin_marque "1/9 ENV_REQUIS" ENV_REQUIS "$TMP/d17-0.err" "$RC"
grep -q '^APPELANT-VIVANT$' "$TMP/d17-0.out" \
  && ok "1/9 ENV_REQUIS : l'appelant SURVIT au refus (rc=$RC) — un « \${1:?} » l'abattait, et son « || return 1 » n'était jamais atteint" \
  || ko "1/9 ENV_REQUIS : le shell appelant a été abattu (stdout='$(head -1 "$TMP/d17-0.out")', rc=$RC)"
# Contre-témoin d'entrée : la MÊME garde sur teams_raw refuse aussi, en nommant
# SA fonction — et SANS marqueur, sinon le contre-témoin de fin de section
# (« teams_raw n'émet JAMAIS le marqueur ») cesserait de discriminer.
bash -c ". '$LIB'; generate_choices_teams_raw; echo APPELANT-VIVANT" \
  >"$TMP/d17-0t.out" 2>"$TMP/d17-0t.err"; RC=$?
grep -q '^ENV_REQUIS : generate_choices_teams_raw ' "$TMP/d17-0t.err" \
  && grep -q '^APPELANT-VIVANT$' "$TMP/d17-0t.out" \
  && ! grep -q '^CHOICES_SKIPPED_REPOS=' "$TMP/d17-0t.err" \
  && ok "1/9 bis — teams_raw : même refus nommé (et il nomme SA fonction), appelant vivant, AUCUN marqueur" \
  || ko "1/9 bis — teams_raw : refus/vivacité/marqueur inattendus (rc=$RC) : $(head -1 "$TMP/d17-0t.err" | cut -c1-70)"

# 2/9 — MKTEMP : le tout premier geste de la fonction. Shim de PATH (même idiome
# que le shim `git` du test 14) : `mktemp -d` sans template ignore TMPDIR sur
# BSD, casser TMPDIR ne suffit donc pas (mesuré).
SHIM17="$TMP/shim17"; mkdir -p "$SHIM17"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SHIM17/mktemp"; chmod 700 "$SHIM17/mktemp"
PATH="$SHIM17:$PATH" GC_PLATFORM_DIR="$WS15" GIT_SUBDIR=livrable GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >"$TMP/d17-1.out" 2>"$TMP/d17-1.err"; RC=$?
chemin_marque "2/9 MKTEMP" MKTEMP "$TMP/d17-1.err" "$RC"

# 3/9 — GIT_UNREACHABLE (knob posé sur un répertoire qui ne porte pas le dépôt).
GC_PLATFORM_DIR="$TMP/ws-17-absent" GIT_SUBDIR=livrable GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >/dev/null 2>"$TMP/d17-2.err"; RC=$?
chemin_marque "3/9 GIT_UNREACHABLE" GIT_UNREACHABLE "$TMP/d17-2.err" "$RC"

# 4/9 — PROVIDERS_MISSING (le dépôt est là, le fichier de l'env demandé non).
WS17C="$TMP/ws-17-noprov"; mkdir -p "$WS17C/livrable/ansible"
GC_PLATFORM_DIR="$WS17C" GIT_SUBDIR=livrable GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >/dev/null 2>"$TMP/d17-3.err"; RC=$?
chemin_marque "4/9 PROVIDERS_MISSING" PROVIDERS_MISSING "$TMP/d17-3.err" "$RC"

# 5/9 — PROVIDERS_PARSE (YAML cassé : source corrompue, pas une tolérance).
WS17D="$TMP/ws-17-badprov"; mkdir -p "$WS17D/livrable/ansible"
printf 'providers: [\n' > "$WS17D/livrable/ansible/providers.dev.yml"
GC_PLATFORM_DIR="$WS17D" GIT_SUBDIR=livrable GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >/dev/null 2>"$TMP/d17-4.err"; RC=$?
chemin_marque "5/9 PROVIDERS_PARSE" PROVIDERS_PARSE "$TMP/d17-4.err" "$RC"

# 6/9 — PUBLISH_YML_PARSE, collecte du clients/ de la PLATEFORME (déjà produit
# en 16d : on relit le MÊME stderr, aucune raison de rejouer le cas).
chemin_marque "6/9 PUBLISH_YML_PARSE (clients/ plateforme)" PUBLISH_YML_PARSE "$E16D" "$RC16D"

# 7/9 — PUBLISH_YML_PARSE, corps de boucle des dépôts d'équipe.
WS17F="$TMP/ws-17-boucle"; mk_ws "$WS17F" "livrable" "$TWO_REPOS_ABSENTS" 0
GH17F="$TMP/gitea17f"; mk_team_repo_casse "$GH17F/fbi/accounts-api.git"
GC_PLATFORM_DIR="$WS17F" GIT_SUBDIR=livrable GIT_HOST="$GH17F" GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >/dev/null 2>"$TMP/d17-6.err"; RC=$?
chemin_marque "7/9 PUBLISH_YML_PARSE (dépôt d'équipe)" PUBLISH_YML_PARSE "$TMP/d17-6.err" "$RC"

# 8/9 — APIS_EMPTY (déjà produit en 15a : même stderr, E15A).
chemin_marque "8/9 APIS_EMPTY" APIS_EMPTY "$E15A" "$RC15A"

# 9/9 — GIT_HOST_PORTE_IDENTIFIANTS : la porte I1, la sortie la PLUS précoce de
# toutes (avant le mktemp). C'est la NEUVIÈME, et elle serait muette si le
# marqueur n'y était pas émis : un consommateur qui lit CHOICES_SKIPPED_REPOS
# dans un log de re-pose (team-apply.sh:407, team-publish.sh:470) lirait
# « fonction jamais appelée » là où elle a été appelée et a refusé.
GC_PLATFORM_DIR="$WS15" GIT_SUBDIR=livrable GIT_HOST='http://u:s3cr3t@forge.example' GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >"$TMP/d17-8.out" 2>"$TMP/d17-8.err"; RC=$?
chemin_marque "9/9 GIT_HOST_PORTE_IDENTIFIANTS" GIT_HOST_PORTE_IDENTIFIANTS "$TMP/d17-8.err" "$RC"
grep -q '^CHOICES_SKIPPED_REPOS=0$' "$TMP/d17-8.err" && [ ! -s "$TMP/d17-8.out" ] \
  && ok "9/9 : le marqueur vaut 0 (rien n'a été sauté parce que rien n'a été tenté) et stdout est vide" \
  || ko "9/9 : marqueur/stdout inattendus — $(grep -m1 'CHOICES_SKIPPED' "$TMP/d17-8.err")"
# Contre-témoin d'entrée, comme pour ENV_REQUIS : la MÊME porte sur teams_raw
# refuse aussi — et SANS marqueur (c'est l'entrée TEAMS).
GC_PLATFORM_DIR="$WS15" GIT_SUBDIR=livrable GIT_HOST='http://u:s3cr3t@forge.example' GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_teams_raw dev" >"$TMP/d17-8t.out" 2>"$TMP/d17-8t.err"; RC=$?
[ "$RC" -ne 0 ] && [ ! -s "$TMP/d17-8t.out" ] \
  && grep -q '^GIT_HOST_PORTE_IDENTIFIANTS : ' "$TMP/d17-8t.err" \
  && ! grep -q '^CHOICES_SKIPPED_REPOS=' "$TMP/d17-8t.err" \
  && ok "9/9 bis — teams_raw : la porte GIT_HOST refuse là aussi (rc≠0, stdout vide), AUCUN marqueur" \
  || ko "9/9 bis — teams_raw : refus/marqueur inattendus (rc=$RC) : $(head -1 "$TMP/d17-8t.err" | cut -c1-70)"

# CONTRE-TÉMOIN, et c'est lui qui donne son sens à « marqueur absent » :
# generate_choices_teams_raw n'émet JAMAIS ce marqueur, sur aucun chemin.
# Sans cette assertion, un correctif « émettre partout » pourrait l'arroser
# partout, et l'absence ne dirait plus rien.
GC_PLATFORM_DIR="$TMP/ws-17-absent" GIT_SUBDIR=livrable GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_teams_raw dev" >/dev/null 2>"$TMP/d17-t.err"
grep -q '^CHOICES_SKIPPED_REPOS=' "$TMP/d17-t.err" \
  && ko "generate_choices_teams_raw émet le marqueur : « absent » ne distingue plus l'entrée APIS de l'entrée TEAMS" \
  || ok "contre-témoin : generate_choices_teams_raw n'émet JAMAIS le marqueur — c'est ce qui rend « marqueur absent ⇒ apis pas appelée » lisible"

echo
echo "== 18. G3 : « réparer les dépôts d'équipe avertis ci-dessus » n'est dit QUE s'il y en a =="
# DÉFAUT INTRODUIT PAR LE CORRECTIF LUI-MÊME : la clause finale d'APIS_EMPTY
# était émise INCONDITIONNELLEMENT — donc aussi quand zéro dépôt était déclaré,
# et quand tous avaient été clonés. Le refus envoyait alors l'opérateur réparer
# des dépôts dont AUCUN message ne parlait : exactement la classe de défaut que
# ce fichier prétend abolir. Trois cas, dont deux où la clause doit disparaître.
CLAUSE="réparer les"
# 18a — skipped>0 (15a : 2 déclarés, 0 clonés) : la clause est DUE, et elle CITE
# le compte, pour que « ci-dessus » soit vérifiable ligne à ligne.
grep -qF "ou ${CLAUSE} 2 dépôt(s) d'équipe avertis ci-dessus" <<<"$A15" \
  && ok "18a skipped=2 ⇒ la clause est là ET cite le compte (2) — « ci-dessus » se vérifie contre les 2 avertissements" \
  || ko "18a clause absente ou sans compte : $A15"
# 18b — aucun dépôt déclaré (16c) : aucun avertissement n'a pu être émis.
grep -qF "$CLAUSE" <<<"$C16" \
  && ko "18b aucun dépôt déclaré, et le refus renvoie tout de même à des dépôts « avertis ci-dessus » (aucun ne l'a été) : $C16" \
  || ok "18b aucun dépôt déclaré ⇒ le REMÈDE s'arrête à « poser un publish.yml » (plus de renvoi mensonger)"
# 18c — dépôts déclarés mais TOUS clonés (15b : 1 déclaré, 1 cloné, 0 sauté) :
# le cas que `declares > 0` seul n'aurait pas su distinguer.
grep -qF "$CLAUSE" <<<"$B15" \
  && ko "18c tous les dépôts clonés, et le refus renvoie à des dépôts « avertis ci-dessus » (zéro avertissement émis) : $B15" \
  || ok "18c 1 déclaré / 1 cloné / 0 sauté ⇒ aucun renvoi (la condition est skipped, pas declares)"

echo
echo "== 19. G5 (résidu de D1) : la forme SANS SCHÉMA — scp-like git@forge:chemin =="
# MESURÉ : _gc_redact ET l'avertissement GIT_HOST_PORTE_IDENTIFIANTS étaient
# TOUS DEUX ancrés sur « :// ». Un GIT_HOST scp-like — la forme que servent la
# plupart des forges d'entreprise — échappait donc AUX DEUX : ni expurgé, ni
# signalé. Les canaris ci-dessous portent un secret dans cette forme.
echo "-- 19a. expurgation : le secret d'un GIT_HOST scp-like ne sort NI sur stderr NI sur stdout --"
# Le knob est posé DÉLIBÉRÉMENT : depuis I1 cette forme REFUSE, et sans le knob
# il n'y aurait aucun message à expurger (le refus est gardé en 19b et § 25).
# C'est ici le FILET qu'on mesure — le seul cas où il est encore la protection.
SCP_SECRET='CANARI-SCP-SANS-SCHEMA'
GIT_HOST_USERINFO_TOLERE=1 GC_PLATFORM_DIR="$WS15" GIT_SUBDIR=livrable GIT_HOST="git:${SCP_SECRET}@forge.bdf.fr:scm" GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >"$TMP/d19a.out" 2>"$TMP/d19a.err"
if grep -qF "$SCP_SECRET" "$TMP/d19a.err" "$TMP/d19a.out"; then
  ko "FUITE scp-like : $(grep -cF "$SCP_SECRET" "$TMP/d19a.err") occurrence(s) du secret sur stderr (la règle ancrée sur « :// » ne voyait pas cette forme)"
else
  ok "GIT_HOST scp-like porteur d'un secret (knob posé) : rien n'en sort, ni stderr ni stdout"
fi
grep -q 'identifiants masqués' "$TMP/d19a.err" \
  && ok "l'absence vient d'une EXPURGATION, pas d'un message évanoui (« <identifiants masqués> » présent)" \
  || ko "aucun marqueur d'expurgation : les messages ont disparu au lieu d'être masqués"
echo "-- 19b. la méprise est NOMMÉE dans cette forme aussi — et sans knob elle REFUSE --"
[ "$(grep -c '^GIT_HOST_PORTE_IDENTIFIANTS_TOLERE : ' "$TMP/d19a.err")" = "1" ] \
  && ok "GIT_HOST_PORTE_IDENTIFIANTS_TOLERE émis UNE fois pour un GIT_HOST scp-like (le motif d'origine, « *://*@* », ne le voyait pas du tout)" \
  || ko "avertissement toléré émis $(grep -c '^GIT_HOST_PORTE_IDENTIFIANTS_TOLERE : ' "$TMP/d19a.err") fois pour la forme scp-like (attendu 1)"
GC_PLATFORM_DIR="$WS15" GIT_SUBDIR=livrable GIT_HOST="git:${SCP_SECRET}@forge.bdf.fr:scm" GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >"$TMP/d19b.out" 2>"$TMP/d19b.err"; RC=$?
[ "$RC" -ne 0 ] && [ ! -s "$TMP/d19b.out" ] && grep -q '^GIT_HOST_PORTE_IDENTIFIANTS : ' "$TMP/d19b.err" \
  && ! grep -qF "$SCP_SECRET" "$TMP/d19b.err" "$TMP/d19b.out" && ! grep -qF 'forge.bdf.fr' "$TMP/d19b.err" \
  && ok "sans knob, la MÊME forme scp-like REFUSE : rc≠0, stdout vide, et le refus ne cite NI le secret NI l'hôte" \
  || ko "refus scp-like absent ou bavard : rc=$RC — $(head -c 70 "$TMP/d19b.err")"
echo "-- 19c. la LIMITE retenue : un « / » avant le « @ » ⇒ c'est un CHEMIN, on n'y touche pas --"
# Sur-expurger serait l'autre façon de casser le diagnostic : les messages de
# cette lib sont faits de CHEMINS (workspace d'agent, GC_PLATFORM_DIR), et un
# répertoire Jenkins s'appelle couramment « ws@2 ».
R_PATH=$(bash -c ". '$LIB'; _gc_redact '/home/jenkins/workspace/job@2/clients'")
R_URL=$(bash -c ". '$LIB'; _gc_redact 'http://gitea:3000/ci/stoa-labs.git'")
R_SCP=$(bash -c ". '$LIB'; _gc_redact 'git@forge.bdf.fr:scm/eq/x.git'")
R_HTTP=$(bash -c ". '$LIB'; _gc_redact 'http://u:s3cr3t@forge/x'")
[ "$R_PATH" = "/home/jenkins/workspace/job@2/clients" ] && [ "$R_URL" = "http://gitea:3000/ci/stoa-labs.git" ] \
  && ok "aucune sur-expurgation : un chemin à « @ » (job@2) et une URL sans userinfo sortent INTACTS" \
  || ko "sur-expurgation : chemin='$R_PATH' url='$R_URL'"
[ "$R_SCP" = "<identifiants masqués>@forge.bdf.fr:scm/eq/x.git" ] && [ "$R_HTTP" = "http://<identifiants masqués>@forge/x" ] \
  && ok "les DEUX formes sont masquées, et l'ordre des règles ne se remord pas (une seule balise « <identifiants masqués> » par jeton)" \
  || ko "expurgation incorrecte : scp='$R_SCP' http='$R_HTTP'"
# contre-témoin d'avertissement : un GIT_HOST de chemin local (celui des harnais
# et d'un client qui sert un dépôt de fichiers) ne doit RIEN déclencher.
GC_PLATFORM_DIR="$WS15" GIT_SUBDIR=livrable GIT_HOST="$TMP/forge@local/depots" GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >/dev/null 2>"$TMP/d19c.err"
grep -qE '^GIT_HOST_PORTE_IDENTIFIANTS(_TOLERE)? : ' "$TMP/d19c.err" \
  && ko "faux positif : un GIT_HOST qui est un CHEMIN portant « @ » est accusé de porter des identifiants — les harnais de ce dépôt clonent depuis des chemins locaux, un refus trop large les casserait TOUS" \
  || ok "contre-témoin : un GIT_HOST chemin (…/forge@local/…) ne déclenche ni refus ni avertissement — même frontière que _gc_redact"
echo "-- 19d. _gc_redact est désormais IDEMPOTENTE, et la conséquence reste gardée --"
# MESURÉ en écrivant 19c (passe 3) : _gc_redact N'ÉTAIT PAS idempotente — son
# texte de remplacement porte une espace et un « @ », et une seconde application
# remordait dessus (« http://<identifiants <identifiants masqués>@hote »).
# C'était une limite assumée ; la passe 4 la ferme (le marqueur est converti en
# sentinelle avant les règles par motif). L'assertion directe d'abord, la
# conséquence observable ensuite.
for HID in 'http://u:s3cr3t@hote' 'git:CAN/ARI@forge.bdf.fr:scm' 'http://u:CANARI ESPACE@forge.bdf.fr/x'; do
  IDEM=$(GIT_HOST="$HID" bash -c ". '$LIB'; A=\$(_gc_redact \"\$GIT_HOST\"); B=\$(_gc_redact \"\$A\"); [ \"\$A\" = \"\$B\" ] && echo OUI || printf 'NON[%s]!=[%s]' \"\$A\" \"\$B\"")
  [ "$IDEM" = "OUI" ] \
    && ok "idempotence sur « ${HID%%:*}… » : _gc_redact(_gc_redact X) = _gc_redact X" \
    || ko "NON idempotente sur « $HID » : $IDEM"
done
# ET LA CONSÉQUENCE OBSERVABLE, qui vaut indépendamment de l'assertion
# ci-dessus : AUCUN message produit par cette suite ne doit porter un marqueur
# doublé. L'épreuve rougit si quelqu'un ajoute une expurgation en cascade dont
# les sentinelles ne protègent pas le résultat.
D19=$(cat "$TMP"/*.err 2>/dev/null | grep -c '<identifiants <identifiants')
[ "$D19" = "0" ] \
  && ok "aucun des stderr produits par cette suite ne porte de marqueur doublé (l'expurgation n'est appliquée qu'UNE fois sur chaque valeur)" \
  || ko "expurgation en cascade : ${D19} message(s) portent « <identifiants <identifiants » — $(grep -h -m1 -o '<identifiants <identifiants[^ ]* [^ ]*' "$TMP"/*.err | head -1)"

echo
echo "== 20. G6 : _gc_platform_ref garde AUSSI la branche « teams » (elle n'était appelée que par « apis ») =="
# Le helper est déclaré « utilisé par GIT_UNREACHABLE et PROVIDERS_MISSING dans
# les DEUX fonctions », mais toutes les épreuves de D5/D6 n'appelaient que
# l'entrée `apis` : remettre l'ancien texte dans la branche `teams` ne rougissait
# RIEN. Les trois assertions ci-dessous appellent generate_choices_teams_raw.
GC_PLATFORM_DIR="$TMP/ws-20-absent" GIT_SUBDIR=livrable GIT_BASE=master GIT_REPO=ci/inexistant GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_teams_raw dev" >/dev/null 2>"$TMP/d20a.err"
T20A=$(grep -m1 '^GIT_UNREACHABLE : ' "$TMP/d20a.err")
! grep -qF 'ci/inexistant' <<<"$T20A" && ! grep -qF '@master' <<<"$T20A" && grep -qF "répertoire fourni $TMP/ws-20-absent" <<<"$T20A" \
  && ok "teams / GIT_UNREACHABLE : le knob décide ⇒ ni GIT_REPO ni la branche ne sont nommés, le RÉPERTOIRE l'est" \
  || ko "teams / GIT_UNREACHABLE nomme un dépôt ou une branche jamais consultés : $T20A"
GC_PLATFORM_DIR="$WS15" GIT_SUBDIR=livrable GIT_BASE=master GIT_REPO=ci/inexistant GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_teams_raw rec" >/dev/null 2>"$TMP/d20b.err"
T20B=$(grep -m1 '^PROVIDERS_MISSING : ' "$TMP/d20b.err")
! grep -qF 'ci/inexistant' <<<"$T20B" && ! grep -qF '@master' <<<"$T20B" && grep -qF "répertoire fourni $WS15" <<<"$T20B" \
  && ok "teams / PROVIDERS_MISSING : même règle, même helper — le refus nomme le répertoire réellement lu" \
  || ko "teams / PROVIDERS_MISSING nomme un dépôt/branche fictifs : $T20B"
# Contre-témoin sur le chemin de CLONE : là, le dépôt EST la question — il doit
# être nommé, avec sa branche (c'est l'autre moitié du helper).
GIT_SUBDIR=livrable GIT_HOST="$TMP/gitea-20-vide" GIT_REPO=org/plateforme GIT_BASE=develop GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_teams_raw dev" >/dev/null 2>"$TMP/d20c.err"
grep -qF "dépôt plateforme org/plateforme@develop" "$TMP/d20c.err" \
  && ok "teams / chemin de CLONE : le refus nomme GIT_REPO@branche (la question du client : « quel dépôt est cloné »)" \
  || ko "teams / clone : dépôt anonyme — $(grep -m1 '^GIT_UNREACHABLE' "$TMP/d20c.err" | cut -c1-100)"

echo
echo "== 21. G4 (résidu de D8) : le préfixe du livrable n'est écrit en dur dans AUCUN des deux Jenkinsfile =="
# D8 avait été fermé dans ci/Jenkinsfile.app-request (deux `sh` composés depuis
# $GIT_SUBDIR) et NOMMÉ là — mais ci/Jenkinsfile.app-rollback portait le MÊME
# littéral DEUX FOIS, alors que son bloc environment{} déclare le même knob.
# Chez un client dont le livrable n'a pas le nom du lab, le stage Formulaire
# mourait en FORMULAIRE_VIDE et le repli était impossible.
# Vue CODE : commentaires `//` et `#` blanchis — les en-têtes de ce dépôt CITENT
# le préfixe en prose, un grep nu rougirait sur un commentaire.
jf_code(){ sed -E 's@^[[:space:]]*(//|#).*$@@' "$1"; }
for JF in app-request app-rollback; do
  F="$REPO/ci/Jenkinsfile.$JF"
  jf_code "$F" > "$TMP/jf-$JF.code"
  N=$(grep -c 'poc-control-plane-federation' "$TMP/jf-$JF.code")
  if [ "$N" = 1 ] && grep -q "GIT_SUBDIR .*= \"\${env.GIT_SUBDIR ?: 'poc-control-plane-federation'}\"" "$TMP/jf-$JF.code"; then
    ok "Jenkinsfile.$JF : le préfixe du livrable n'apparaît QU'UNE fois dans le code — le défaut du knob GIT_SUBDIR (aucun chemin en dur)"
  else
    ko "Jenkinsfile.$JF : préfixe du lab écrit en dur — $N occurrence(s) dans la vue CODE (attendu 1, le défaut du knob)"
  fi
done
# Le ko COMPTE ce qu'il reproche : le nombre d'épinglages COMPOSÉS, sur le
# nombre total d'épinglages. Une première version affichait le total (2) en
# regard d'« attendu 2 » — un message qui dément son propre verdict.
N_COMP=$(grep -c 'STOA_ENV_CHAIN_FILE="\$WORKSPACE/\$GIT_SUBDIR/clients/_example/environments.yaml"' "$TMP/jf-app-rollback.code")
N_TOT=$(grep -c 'STOA_ENV_CHAIN_FILE=' "$TMP/jf-app-rollback.code")
[ "$N_COMP" = 2 ] && [ "$N_TOT" = 2 ] \
  && ok "Jenkinsfile.app-rollback : les DEUX sh (Formulaire, demande) épinglent la chaîne ET la composent depuis \$GIT_SUBDIR (2/2)" \
  || ko "Jenkinsfile.app-rollback : ${N_COMP} épinglage(s) composé(s) depuis \$GIT_SUBDIR sur ${N_TOT} épinglage(s) au total (attendu 2/2)"

echo
echo "== 22. H1 : BATTERIE de GIT_HOST hostiles — le REFUS d'abord, le filet ensuite =="
# CE QUE LA REVUE A MESURÉ, passe après passe, et c'est la LEÇON de cette
# section : QUATRE correctifs d'expurgation, QUATRE fuites neuves, et la suite
# VERTE à chaque fois, parce que le canari du jeu d'essai évitait le caractère
# qui cassait la règle en vigueur :
#   passe 1 : « / » et « @ » après « :// »   (classe [^/@[:space:]]*)
#   passe 2 : la forme scp-like, sans schéma (règles ancrées sur « :// »)
#   passe 3 : GIT_HOST='git:CANARI/AVEC-SLASH@forge.bdf.fr:scm' ⇒ EN CLAIR ×2,
#             AUCUN avertissement, et la suite restait à 129/129 (frontière
#             recopiée en deux langues : classe sed d'un côté, glob de l'autre)
#   passe 4 : GIT_HOST='http://u:CANARI AVEC ESPACE@forge.bdf.fr/x' ⇒ EN CLAIR
#             ×3 sur un run, idem avec une TABULATION et un SAUT DE LIGNE (les
#             règles PAR MOTIF, jouées AVANT la règle littérale, détruisaient le
#             littéral que celle-ci cherchait ensuite)
#   passe 5 : GIT_HOST='http://svc:4821/Xk9pQ@forge-inexistant-zz.invalid/x'
#             ⇒ rc 0, la liste sort, « Xk9pQ » EN CLAIR ×2, ni refus ni
#             avertissement : l'autorité « svc:4821 » RESSEMBLAIT à un hôte et
#             la règle de la passe 5 en concluait « le « @ » est dans le
#             CHEMIN » ; le bouclier ajouté au même moment soustrayait de plus
#             cette valeur aux règles par motif.
# LA PASSE 6 NE CHERCHE PAS LE SIXIÈME CARACTÈRE ET NE RAFFINE PLUS LA
# FRONTIÈRE : elle la SUPPRIME. Un « @ » dans GIT_HOST ⇒ REFUS, sauf un
# GIT_HOST qui COMMENCE par « / », « ./ », « ../ » ou « ~ ». La batterie mesure
# DEUX runs par cas — SANS le knob (le défaut : refus, et un refus qui ne cite
# NI le secret NI l'hôte) puis AVEC le knob (le filet : l'expurgation, seule
# protection restante).
# Chaque canari porte DÉLIBÉRÉMENT le caractère qui casse la règle qu'il
# prétend garder : « / », « @ », « : », l'espace, la tabulation, le saut de
# ligne, et l'autorité qui RESSEMBLE à un hôte.
# TROIS CLASSES, et la troisième est le correctif de la PASSE 7 :
#   IDENTITE — refusée sans knob, expurgée sous knob.
#   LIBRE    — aucun « @ » : ni refus, ni expurgation (cas 18, le contre-témoin
#              sans lequel « masqué ⇔ un « @ » » serait vrai par construction).
#   CHEMIN   — un « @ » MAIS une des quatre formes exemptées : JAMAIS refusée
#              (les harnais de ce dépôt clonent depuis /tmp), TOUJOURS expurgée.
#              CETTE CLASSE N'EXISTAIT PAS, et c'était le treizième vert vacant :
#              aucun canari ne mettait un SECRET dans un GIT_HOST de forme
#              CHEMIN, si bien que la suite faisait de la fuite un contrat
#              (192/192 avec le secret en clair sur 3 lignes de stderr par run).
#              Les cas 19a-19d le ferment, un par forme exemptée.
# LES CAS 20, 22 ET 23 SONT LA CONSÉQUENCE ASSUMÉE de la règle unique : des URL
# dont le « @ » est dans le CHEMIN, refusées comme les autres. Leur colonne
# « texte lisible » est VIDE — sous le knob leur autorité est masquée avec le
# reste, et c'est le prix accepté pour n'avoir plus aucune frontière à deviner.
# ET LES CANARIS SE MESURENT PAR MORCEAUX, PAS EN BLOC (mutation jouée, et
# elle a rougi CETTE colonne avant de rougir le code). En remettant l'ordre
# d'avant dans _gc_redact, les cas à ESPACE de cette batterie restaient VERTS
# alors que le secret fuyait : la règle par motif ne coupe pas le secret en
# deux, elle en laisse la TÊTE en clair et masque la QUEUE — un `grep -F` sur
# le secret ENTIER ne trouve donc plus rien. C'est le même piège que celui qui
# a laissé vivre quatre fuites, un cran plus haut : un canari qui ne cherche
# que la forme intacte ne prouve rien. Chaque cas déclare donc la LISTE des
# fragments qui, isolément, signent la fuite — tête ET queue.
# nom|GIT_HOST (échappements %b)|fragments interdits (virgules)|classe|texte qui doit rester lisible
H1_CAS=(
  "01 schéma, secret nu|http://u:CANARIA-NU@forge.bdf.fr/x|CANARIA|IDENTITE|forge.bdf.fr"
  "02 schéma, secret à /|http://u:CANARIB/SLASH@forge.bdf.fr/x|CANARIB,SLASH|IDENTITE|forge.bdf.fr"
  "03 schéma, secret à @|http://u:CANARIC@AROBASE@forge.bdf.fr/x|CANARIC,AROBASE|IDENTITE|forge.bdf.fr"
  "04 schéma, secret à / @ :|http://u:CANARID/A@N:COMBI@forge.bdf.fr/x|CANARID,COMBI|IDENTITE|forge.bdf.fr"
  "05 scp-like, secret nu|git:CANARIE-NU@forge.bdf.fr:scm|CANARIE|IDENTITE|forge.bdf.fr:scm"
  "06 scp-like, secret à /|git:CANARIF/SLASH@forge.bdf.fr:scm|CANARIF,SLASH|IDENTITE|forge.bdf.fr:scm"
  "07 scp-like, secret à @|git:CANARIG@AROBASE@forge.bdf.fr:scm|CANARIG,AROBASE|IDENTITE|forge.bdf.fr:scm"
  "08 scp-like, secret à / @ :|git:CANARIH/A@N:COMBI@forge.bdf.fr:scm|CANARIH,COMBI|IDENTITE|forge.bdf.fr:scm"
  "09 scp-like avec port|git:CANARII/SLASH@forge.bdf.fr:2222/scm|CANARII,SLASH|IDENTITE|forge.bdf.fr:2222"
  "10 ssh:// avec port|ssh://git:CANARIJ/SLASH@forge.bdf.fr:2222/scm|CANARIJ,SLASH|IDENTITE|forge.bdf.fr:2222"
  "11 schéma, secret à ESPACE|http://u:CANARIK ESPACE@forge.bdf.fr/x|CANARIK,ESPACE|IDENTITE|forge.bdf.fr"
  "12 schéma, secret à TABULATION|http://u:CANARIL\tTABUL@forge.bdf.fr/x|CANARIL,TABUL|IDENTITE|forge.bdf.fr"
  "13 schéma, secret à SAUT DE LIGNE|http://u:CANARIM\nNLIGNE@forge.bdf.fr/x|CANARIM,NLIGNE|IDENTITE|forge.bdf.fr"
  "14 scp-like, secret à ESPACE|git:CANARIN ESPACE@forge.bdf.fr:scm|CANARIN,ESPACE|IDENTITE|forge.bdf.fr:scm"
  "15 scp-like, secret à / ET ESPACE|git:CANARIO/SLASH ESPACE@forge.bdf.fr:scm|CANARIO,SLASH,ESPACE|IDENTITE|forge.bdf.fr:scm"
  "16 schéma, secret à / ET SAUT DE LIGNE|http://u:CANARIP/SLASH\nNLIGNE@forge.bdf.fr/x|CANARIP,SLASH,NLIGNE|IDENTITE|forge.bdf.fr"
  "17 schéma, secret à ESPACE FINALE|http://u:CANARIQ-FIN @forge.bdf.fr/x|CANARIQ|IDENTITE|forge.bdf.fr"
  "18 TÉMOIN hôte légitime|http://gitea:3000||LIBRE|http://gitea:3000"
  "19 TÉMOIN chemin à @, sans secret|$TMP/forge@local/depots||CHEMIN|local/depots"
  "19a CHEMIN « / » PORTANT UN SECRET|$TMP/u:SECTETEA/QUEUEA@hote-a-zz.invalid|SECTETEA,QUEUEA|CHEMIN|hote-a-zz.invalid"
  "19b CHEMIN « ./ » PORTANT UN SECRET|./u:SECTETEB/QUEUEB@hote-b-zz.invalid|SECTETEB,QUEUEB|CHEMIN|hote-b-zz.invalid"
  "19c CHEMIN « ../ » PORTANT UN SECRET|../u:SECTETEC/QUEUEC@hote-c-zz.invalid|SECTETEC,QUEUEC|CHEMIN|hote-c-zz.invalid"
  "19d CHEMIN « ~ » PORTANT UN SECRET|~u:SECTETED/QUEUED@hote-d-zz.invalid:scm|SECTETED,QUEUED|CHEMIN|hote-d-zz.invalid"
  "20 URL légitime, @ dans le CHEMIN|http://forge.bdf.fr/gitea@v1||IDENTITE|"
  "21 TÉMOIN scp sans secret|git@forge.bdf.fr:scm||IDENTITE|forge.bdf.fr:scm"
  "22 AUTORITÉ QUI RESSEMBLE À UN HÔTE (la fuite de la passe 5)|http://svc:4821/Xk9pQ@forge-inexistant-zz.invalid/x|Xk9pQ,4821|IDENTITE|forge-inexistant-zz.invalid"
  "23 URL légitime, autorité à PORT, @ dans le CHEMIN|https://forge-port-zz.invalid:8443/a@b||IDENTITE|"
)
for CAS in "${H1_CAS[@]}"; do
  IFS='|' read -r H1_NOM H1_HOST_E H1_FRAGS H1_CLS H1_LIS <<<"$CAS"
  H1_HOST=$(printf '%b' "$H1_HOST_E")
  IDX="${H1_NOM%% *}"
  H1E="$TMP/d22-$IDX.err"; H1O="$TMP/d22-$IDX.out"
  H1TE="$TMP/d22t-$IDX.err"; H1TO="$TMP/d22t-$IDX.out"
  # (a) LE DÉFAUT — aucun knob.
  GC_PLATFORM_DIR="$WS15" GIT_SUBDIR=livrable GIT_HOST="$H1_HOST" GITEA_TOKEN=dummy \
    bash -c ". '$LIB'; generate_choices_apis_raw dev" >"$H1O" 2>"$H1E"; RC22=$?
  # (b) LA PORTE DE SORTIE — le filet est alors la seule protection.
  GIT_HOST_USERINFO_TOLERE=1 GC_PLATFORM_DIR="$WS15" GIT_SUBDIR=livrable GIT_HOST="$H1_HOST" GITEA_TOKEN=dummy \
    bash -c ". '$LIB'; generate_choices_apis_raw dev" >"$H1TO" 2>"$H1TE"
  H1_PB=""; H1_SUF=""
  N_REF=$(grep -c '^GIT_HOST_PORTE_IDENTIFIANTS : ' "$H1E")
  N_TOL=$(grep -c '^GIT_HOST_PORTE_IDENTIFIANTS_TOLERE : ' "$H1TE")
  if [ "$H1_CLS" = "IDENTITE" ]; then
    [ "$RC22" -ne 0 ]   || H1_PB="${H1_PB} rc=0(le refus n'a pas eu lieu)"
    [ ! -s "$H1O" ]     || H1_PB="${H1_PB} stdout-non-vide"
    [ "$N_REF" = "1" ]  || H1_PB="${H1_PB} refus=${N_REF}(attendu 1)"
    [ "$N_TOL" = "1" ]  || H1_PB="${H1_PB} avert-toléré=${N_TOL}(attendu 1)"
    # LE REFUS NE CITE RIEN : ni le secret, ni l'hôte. C'est ce qui ferme la
    # CLASSE — il n'y a plus de message à expurger, donc plus de motif à rater.
    IFS=',' read -r -a H1_TR <<<"$H1_FRAGS"
    for FRG in "${H1_TR[@]:-}"; do
      [ -n "$FRG" ] || continue
      grep -qF "$FRG" "$H1E" "$H1O" && H1_PB="${H1_PB} FUITE-DANS-LE-REFUS(« $FRG »)"
    done
    # La colonne « texte lisible » est VIDE pour les cas 20/23 : sous le knob
    # leur autorité est masquée avec le reste (sur-expurgation assumée). Un
    # `grep -qF ""` matcherait TOUT — laissé sans condition, il ferait une
    # assertion vraie par construction, donc un vert vacant de plus.
    if [ -n "$H1_LIS" ]; then
      grep -qF "$H1_LIS" "$H1E" && H1_PB="${H1_PB} LE-REFUS-CITE-L-HÔTE(« $H1_LIS »)"
    fi
    # LE FILET, sous le knob : zéro fuite — fragment par fragment, tête ET queue —
    # ET l'hôte reste lisible (sur-expurger jusqu'à rendre l'hôte illisible est
    # l'autre façon de casser le diagnostic).
    if [ -n "$H1_FRAGS" ]; then
      for FRG in "${H1_TR[@]:-}"; do
        [ -n "$FRG" ] || continue
        N=$(( $(grep -cF "$FRG" "$H1TE") + $(grep -cF "$FRG" "$H1TO") ))
        [ "$N" = "0" ] || H1_PB="${H1_PB} FUITE-SOUS-KNOB(${N}× « $FRG »)"
      done
      grep -q 'identifiants masqués' "$H1TE" || H1_PB="${H1_PB} message-évanoui-au-lieu-d-être-expurgé"
    fi
    if [ -n "$H1_LIS" ]; then
      grep -qF "$H1_LIS" "$H1TE" || H1_PB="${H1_PB} HÔTE-ILLISIBLE-SOUS-KNOB(« $H1_LIS » absent : sur-expurgation)"
      H1_SUF="et hôte « $H1_LIS » lisible"
    else
      H1_SUF="et RIEN de l'autorité ne subsiste (sur-expurgation ASSUMÉE : le « @ » est dans le CHEMIN)"
    fi
    [ -z "$H1_PB" ] \
      && ok "cas $H1_NOM : REFUS sans knob (rc≠0, stdout vide, ni secret ni hôte cités) ; sous knob, 0 fuite ${H1_SUF}" \
      || ko "cas $H1_NOM :${H1_PB}"
  elif [ "$H1_CLS" = "CHEMIN" ]; then
    # LE CAS DUR DE LA PASSE 7, ET LE TREIZIÈME VERT VACANT QU'IL FERME.
    # Un GIT_HOST de forme CHEMIN est EXEMPTÉ DU REFUS (non-régression : tous
    # les harnais de ce dépôt clonent depuis /tmp) — il n'est PAS exempté de
    # l'EXPURGATION. Aucun canari de cette batterie ne mettait un SECRET dans un
    # GIT_HOST de forme chemin : la suite faisait donc de la fuite un contrat
    # (192/192 pendant que le secret sortait en clair 2× par run, knob éteint).
    # DEUX exigences, et il faut les DEUX — l'une sans l'autre est un demi-vert :
    #   (1) ni refus ni avertissement, dans les DEUX runs (l'exception tient) ;
    #   (2) zéro fuite, fragment par fragment (tête ET queue), dans les DEUX
    #       runs ET sur les DEUX flux — le run SANS knob compris, puisque c'est
    #       LUI qui fuyait : ces formes ne sont jamais refusées, donc le knob
    #       n'a rien à voir avec elles.
    [ "$N_REF" = "0" ]  || H1_PB="${H1_PB} REFUS-À-TORT(${N_REF}) — un harnais qui clone depuis /tmp casserait"
    [ "$N_TOL" = "0" ]  || H1_PB="${H1_PB} AVERTISSEMENT-À-TORT(${N_TOL})"
    IFS=',' read -r -a H1_TR <<<"$H1_FRAGS"
    for FRG in "${H1_TR[@]:-}"; do
      [ -n "$FRG" ] || continue
      N=$(( $(grep -cF "$FRG" "$H1E") + $(grep -cF "$FRG" "$H1O") ))
      NT=$(( $(grep -cF "$FRG" "$H1TE") + $(grep -cF "$FRG" "$H1TO") ))
      [ "$N" = "0" ]  || H1_PB="${H1_PB} FUITE-SANS-KNOB(${N}× « $FRG »)"
      [ "$NT" = "0" ] || H1_PB="${H1_PB} FUITE-SOUS-KNOB(${NT}× « $FRG »)"
    done
    # L'EXPURGATION A BIEN EU LIEU (et le message n'a pas simplement disparu) —
    # sinon « zéro fuite » serait vrai d'un fichier vide, vert vacant de plus.
    grep -q 'identifiants masqués' "$H1E" || H1_PB="${H1_PB} AUCUNE-EXPURGATION(le préfixe du chemin n'est pas masqué : la garde de _gc_redact consulte de nouveau le VERDICT)"
    # ET LE DIAGNOSTIC SURVIT : ce qui SUIT le dernier « @ » reste lisible.
    grep -qF "$H1_LIS" "$H1E" || H1_PB="${H1_PB} DIAGNOSTIC-PERDU(« $H1_LIS » absent : sur-expurgation)"
    [ -z "$H1_PB" ] \
      && ok "cas $H1_NOM : jamais refusé (l'exception de chemin tient), MAIS expurgé quand même — 0 fuite avec ET sans knob, et « $H1_LIS » reste lisible" \
      || ko "cas $H1_NOM :${H1_PB}"
  else
    [ "$N_REF" = "0" ]  || H1_PB="${H1_PB} REFUS-À-TORT(${N_REF})"
    [ "$N_TOL" = "0" ]  || H1_PB="${H1_PB} AVERTISSEMENT-À-TORT(${N_TOL})"
    grep -qF "$H1_LIS" "$H1E" || H1_PB="${H1_PB} HÔTE-ILLISIBLE(« $H1_LIS » absent : sur-expurgation)"
    [ -z "$H1_PB" ] \
      && ok "cas $H1_NOM : ni refus ni avertissement (ce n'est pas une identité), et « $H1_LIS » reste lisible" \
      || ko "cas $H1_NOM :${H1_PB}"
  fi
done
# LE VERDICT N'EXISTE QU'EN UN SEUL EXEMPLAIRE — ET L'EXPURGATION NE LE SUIT
# PLUS (passe 7). Deux lecteurs partagent le VERDICT : le REFUS et
# l'AVERTISSEMENT toléré. « refusé sans knob » ⇔ « signalé avec knob » reste la
# preuve qu'il n'est pas recopié (c'est sa divergence qui, passe 3, a coûté un
# secret sur un build vert).
# EN REVANCHE, LE TROISIÈME MEMBRE DE CETTE ÉQUIVALENCE EST RETIRÉ, ET C'EST LE
# CORRECTIF LUI-MÊME : l'expurgation ne suit plus le verdict mais la SEULE
# présence d'un « @ » dans GIT_HOST. C'est précisément parce qu'on lui demandait
# de suivre le verdict qu'un GIT_HOST de forme chemin sortait en clair. La
# nouvelle invariance, mesurée sur tous les cas : masqué ⇔ GIT_HOST porte un
# « @ ». (Le cas 18, seul sans « @ », est le contre-témoin sans lequel
# l'assertion serait vraie par construction.)
H1_DIV=0; H1_MDIV=0; H1_AVECAT=0
for CAS in "${H1_CAS[@]}"; do
  IFS='|' read -r H1_NOM H1_HOST_E H1_FRAGS H1_CLS H1_LIS <<<"$CAS"
  H1_HOST=$(printf '%b' "$H1_HOST_E")
  IDX="${H1_NOM%% *}"
  R=$(grep -c '^GIT_HOST_PORTE_IDENTIFIANTS : ' "$TMP/d22-$IDX.err")
  A=$(grep -c '^GIT_HOST_PORTE_IDENTIFIANTS_TOLERE : ' "$TMP/d22t-$IDX.err")
  M=$(grep -c 'identifiants masqués' "$TMP/d22t-$IDX.err")
  [ "$R" = "$A" ] || H1_DIV=$((H1_DIV+1))
  case "$H1_HOST" in
    *@*) H1_AVECAT=$((H1_AVECAT+1)); [ "$M" -gt 0 ] || H1_MDIV=$((H1_MDIV+1)) ;;
    *)   [ "$M" = "0" ]  || H1_MDIV=$((H1_MDIV+1)) ;;
  esac
done
[ "$H1_DIV" = "0" ] \
  && ok "refus et avertissement ne DIVERGENT sur aucun cas — le VERDICT n'est plus écrit deux fois (c'est la divergence qui coûtait le secret, passe 3)" \
  || ko "${H1_DIV} cas où le refus agit sans l'avertissement : le verdict est de nouveau recopié"
[ "$H1_MDIV" = "0" ] && [ "$H1_AVECAT" -gt 0 ] \
  && ok "l'expurgation NE SUIT PLUS LE VERDICT mais la seule présence d'un « @ » : masqué sur les $H1_AVECAT cas qui en portent un, jamais sur celui qui n'en porte pas (c'est le correctif de la passe 7)" \
  || ko "${H1_MDIV} cas où l'expurgation suit autre chose que la présence d'un « @ » (sur $H1_AVECAT cas à « @ ») : la garde de _gc_redact consulte de nouveau une notion de FORME"
# et le témoin qui garde l'AUTRE côté de l'arbitrage — RÉÉCRIT PAR LA PASSE 7,
# car il gardait EXACTEMENT la fuite. Il exigeait que le chemin du cas 19 sorte
# ENTIER ; or « sortir entier » est ce que faisait aussi un chemin PORTANT UN
# SECRET. Ce qui doit rester lisible, c'est le DIAGNOSTIC — ce qui SUIT le
# dernier « @ » —, pas le préfixe. C'est le prix du correctif, et il est ici.
PB19=""
grep -qF "local/depots/ibafraud/accounts-api.git" "$TMP/d22-19.err" || PB19="${PB19} suffixe-perdu"
grep -qF "$TMP/forge@local" "$TMP/d22-19.err" && PB19="${PB19} préfixe-NON-masqué(la fuite de la passe 6)"
[ -z "$PB19" ] \
  && ok "arbitrage de la passe 7 : un CHEMIN portant « @ » n'est pas REFUSÉ (les harnais clonent depuis /tmp) mais son préfixe EST masqué ; le diagnostic garde « local/depots/ibafraud/accounts-api.git »" \
  || ko "cas 19 :${PB19} — $(grep -m1 '(avertissement)' "$TMP/d22-19.err")"
# LE BOUCLIER DE LA PASSE 5 EST RETIRÉ, ET C'EST MESURÉ ICI. Il soustrayait aux
# règles par MOTIF toute valeur de GIT_HOST que la frontière déclarait « pas une
# identité » — pour qu'un hôte légitime reste lisible. MESURÉ contre la passe 5 :
# il désarmait la règle 2 sur la valeur de GIT_HOST Y COMPRIS QUAND CETTE VALEUR
# ÉTAIT LE SECRET. L'assertion est donc RETOURNÉE : plus rien ne protège une
# valeur de GIT_HOST de l'expurgation.
R_BOUCLIER=$(GIT_HOST='http://svc:4821/Xk9pQ@forge-inexistant-zz.invalid/x' \
  bash -c ". '$LIB'; _gc_redact \"\$GIT_HOST\"")
case "$R_BOUCLIER" in
  *Xk9pQ*) ko "le bouclier vit encore : _gc_redact rend la valeur de GIT_HOST intacte — '$R_BOUCLIER'" ;;
  *) ok "bouclier retiré : la valeur de GIT_HOST n'est plus soustraite à l'expurgation — « $R_BOUCLIER »" ;;
esac
# ET LA CONTREPARTIE, qui est l'arbitrage lui-même : l'URL légitime dont le
# chemin porte un « @ » n'a plus besoin d'être lisible, PARCE QU'ELLE EST
# REFUSÉE — donc jamais imprimée. C'est ce que garde le cas 20 de la batterie
# ci-dessus. Ce qui doit rester lisible, ce sont les CHEMINS (cas 19).

echo "-- 22bis. L'EXCEPTION VAUT POUR LE VERDICT, JAMAIS POUR L'EXPURGATION — PROUVÉ PAR MUTATION --"
# CE QUE CETTE SECTION DISAIT AVANT, ET POURQUOI C'ÉTAIT LE TREIZIÈME VERT
# VACANT : elle mesurait le MÊME canari ('~u:SEC/RETQUIRESTE@…') et EXIGEAIT
# qu'il fuie (« LIMITE NOMMÉE : le secret sort en clair »). La suite faisait donc
# de la fuite un CONTRAT : 192/192 pendant qu'un secret sortait 2× par run, rc 0,
# knob éteint, sans refus ni avertissement. Le canari était bon, la conclusion
# était l'inverse de la bonne.
# LA CAUSE ÉTAIT STRUCTURELLE, pas un motif trop étroit : _gc_redact s'ouvrait
# sur _gc_host_userinfo — LE VERDICT — qui rend « pas une identité » pour les
# quatre formes de chemin ; les règles 3 et 3bis étaient donc SAUTÉES. Depuis la
# passe 7, _gc_redact appelle _gc_host_ui_extract — L'EXTRACTION, sans exception.
# CE QUE CETTE SECTION MESURE MAINTENANT, en deux temps :
#   (1) sur la lib RÉELLE : les quatre formes exemptées, secret compris, ne sont
#       NI refusées NI fuitées (le détail fragment par fragment est en § 22,
#       cas 19a-19d ; ici on garde l'invariant d'un coup d'œil) ;
#   (2) PAR MUTATION : une COPIE de la lib où la garde de _gc_redact consulte de
#       nouveau le VERDICT. Si les canaris ne rougissent PAS sur cette copie,
#       c'est qu'ils ne mesurent rien — et le vert du (1) serait vacant à son
#       tour. C'est le contrôle qui a manqué six fois.
MUTD="$TMP/mut22"; mkdir -p "$MUTD"
# Les voisines que la lib source par « ${BASH_SOURCE[0]%/*}/… » doivent être là :
# sans git-base.sh (L3, 2026-09-10) la copie mutée refuse LIB_ABSENTE et
# n'émet plus rien — les quatre canaris deviendraient INERTES par accident.
cp "$REPO/scripts/lib/repo-layout.sh" "$MUTD/repo-layout.sh"
cp "$REPO/scripts/lib/git-base.sh" "$MUTD/git-base.sh"
LIBMUT="$MUTD/generate-choices.sh"
# LA MUTATION, exacte : la garde de _gc_redact redevient le VERDICT (l'état
# d'avant la passe 7, mot pour mot).
sed 's/if _gc_host_ui_extract && \[ -n "\$_GC_HOST_UI" \]; then/if _gc_host_userinfo \&\& _gc_host_ui_extract \&\& [ -n "$_GC_HOST_UI" ]; then/' \
  "$LIB" >"$LIBMUT"
cmp -s "$LIB" "$LIBMUT" \
  && ko "22bis la MUTATION n'a rien changé au fichier : la garde de _gc_redact n'a plus la forme attendue — cette section ne prouve plus rien, la réécrire AVANT de croire le vert du (1)" \
  || ok "22bis la mutation est effective (la garde de _gc_redact rappelle le VERDICT) — le contrôle qui suit n'est pas vacant"
# nom | GIT_HOST | fragments tête,queue
M22_CAS=(
  "«/»  |$TMP/u:SECTETEA/QUEUEA@hote-a-zz.invalid|SECTETEA,QUEUEA"
  "«./» |./u:SECTETEB/QUEUEB@hote-b-zz.invalid|SECTETEB,QUEUEB"
  "«../»|../u:SECTETEC/QUEUEC@hote-c-zz.invalid|SECTETEC,QUEUEC"
  "«~»  |~u:SECTETED/QUEUED@hote-d-zz.invalid:scm|SECTETED,QUEUED"
)
M22_VRAI=0; M22_MUTE=0; M22_REF=0; M22_DET=""
for MC in "${M22_CAS[@]}"; do
  IFS='|' read -r M_NOM M_HOST M_FRAGS <<<"$MC"
  for M_LIB in "$LIB" "$LIBMUT"; do
    M_OUT=$(GC_PLATFORM_DIR="$WS15" GIT_SUBDIR=livrable GIT_HOST="$M_HOST" GITEA_TOKEN=dummy \
      bash -c ". '$M_LIB'; generate_choices_apis_raw dev" 2>&1 >/dev/null)
    IFS=',' read -r -a M_TR <<<"$M_FRAGS"
    M_N=0
    for FRG in "${M_TR[@]}"; do M_N=$(( M_N + $(grep -cF "$FRG" <<<"$M_OUT") )); done
    if [ "$M_LIB" = "$LIB" ]; then
      [ "$M_N" = "0" ] && M22_VRAI=$((M22_VRAI+1)) || M22_DET="${M22_DET} ${M_NOM}:fuite-sur-la-lib-réelle(${M_N})"
      [ "$(grep -c '^GIT_HOST_PORTE_IDENTIFIANTS : ' <<<"$M_OUT")" = "0" ] \
        && M22_REF=$((M22_REF+1)) || M22_DET="${M22_DET} ${M_NOM}:REFUSÉ-à-tort"
    else
      [ "$M_N" -gt 0 ] && M22_MUTE=$((M22_MUTE+1)) || M22_DET="${M22_DET} ${M_NOM}:canari-INERTE(la mutation ne le fait pas rougir)"
    fi
  done
done
[ "$M22_REF" = "4" ] \
  && ok "22bis NON-RÉGRESSION : les quatre formes exemptées (« / », « ./ », « ../ », « ~ ») restent NON REFUSÉES même en portant un secret — les harnais de ce dépôt clonent depuis /tmp" \
  || ko "22bis une forme de chemin est désormais refusée :${M22_DET} — les harnais casseraient"
[ "$M22_VRAI" = "4" ] \
  && ok "22bis les quatre formes exemptées sont EXPURGÉES malgré l'exception : 0 fuite, tête ET queue, sans knob (c'était la sixième fuite)" \
  || ko "22bis fuite sur la lib réelle :${M22_DET}"
[ "$M22_MUTE" = "4" ] \
  && ok "22bis MUTATION : recoupler l'expurgation au VERDICT fait rougir les QUATRE canaris — ils mesurent bien la fuite, ce vert n'est pas vacant" \
  || ko "22bis ${M22_MUTE}/4 canaris seulement rougissent sous mutation :${M22_DET}"

echo
echo "== 23. H3 : ce que l'en-tête dit du SECRET est ce que le code fait =="
# L'en-tête a affirmé pendant trois passes « FORGE_SECRET requis (${:?}) ».
# DEUX faits le démentaient, et personne ne les avait mesurés. C'est la PHRASE
# qui était fausse, pas le code : elle a été corrigée, ces épreuves la gardent.
# (a) la garde n'est PAS un « ${:?} » : refus nommé en tête, appelant vivant.
OUT23=$(env -u GITEA_TOKEN -u FORGE_SECRET GIT_HOST="$GH" GIT_REPO=ci/stoa-labs \
  bash -c ". '$LIB'; generate_choices_teams_raw dev; echo APPELANT-VIVANT" 2>"$TMP/d23a.err")
grep -q '^SECRET_FORGE_REQUIS : ' "$TMP/d23a.err" && grep -q '^APPELANT-VIVANT$' <<<"$OUT23" \
  && ok "23a le secret manquant rend un refus NOMMÉ en tête de ligne et l'appelant SURVIT — pas le « \${:?} » que l'en-tête annonçait (qui aurait abattu le shell)" \
  || ko "23a refus/vivacité inattendus : $(head -1 "$TMP/d23a.err" | cut -c1-70)"
# (b) « requis » était faux tout court : sur le chemin GC_PLATFORM_DIR, sans
# aucun dépôt d'équipe déclaré, AUCUN secret n'est lu et la liste sort.
WS23="$TMP/ws-23"; mk_ws "$WS23" "livrable" "$TWO_TEAMS" 1
mkdir -p "$WS23/livrable/clients/projet/apis"
printf 'apim_api:\n  name: "accounts-read"\n  version: "1.0.0"\n' > "$WS23/livrable/clients/projet/apis/a.publish.yml"
OUT23B=$(env -u GITEA_TOKEN -u FORGE_SECRET GC_PLATFORM_DIR="$WS23" GIT_SUBDIR=livrable \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" 2>"$TMP/d23b.err"); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT23B" = "accounts-read@1.0.0" ] && ! grep -q 'SECRET_FORGE_REQUIS' "$TMP/d23b.err" \
  && ok "23b AUCUN secret posé, GC_PLATFORM_DIR + zéro dépôt d'équipe ⇒ rc 0 et la liste sort : le secret est requis SUR LE CHEMIN DE CLONE, pas « requis » tout court" \
  || ko "23b rc=$RC out='$OUT23B' — $(grep -m1 'SECRET' "$TMP/d23b.err" | cut -c1-70)"
# (c) contre-témoin, sinon (b) se lirait « le secret ne sert jamais » : un dépôt
# d'équipe DÉCLARÉ est cloné, et là le secret manquant devient la cause servie.
grep -q "ignoré pour cette liste — SECRET_FORGE_REQUIS" "$TMP/d16e.err" \
  && ok "23c contre-témoin : dès qu'un dépôt d'équipe est DÉCLARÉ, le secret manquant redevient la cause citée (16e) — les deux moitiés de la phrase corrigée sont vraies" \
  || ko "23c le contre-témoin de 16e ne porte plus SECRET_FORGE_REQUIS"

echo
echo "== 24. H4 : un échec de bind du faux Jenkins est DÉTECTABLE (il était avalé) =="
# MESURÉ : deux serveurs sur le même port fixe ⇒ le second meurt sur
# « OSError: [Errno 48] Address already in use », le traceback part dans
# /dev/null, et la boucle « curl … && break » répond OUI — depuis le serveur du
# PREMIER run. La suite mesurait alors le harnais d'un voisin (mêmes corps de
# POST, même log d'appels) sans qu'aucune assertion ne puisse s'en apercevoir.
if start_fake_jenkins "$PORT" "$TMP/fakejenkins-bis.log"; then
  PID2="$FJ_PID"
  ko "24a un SECOND serveur a « réussi » sur le port $PORT déjà pris : l'échec de bind est encore avalé (le harnais parlerait au serveur d'un autre run)"
else
  ok "24a second serveur sur le port $PORT (déjà pris) ⇒ échec DÉTECTÉ (rc≠0), plus de vert emprunté au serveur d'un autre run"
fi
grep -qE 'Address already in use|Errno 48' "$TMP/fakejenkins-bis.log" \
  && ok "24b la CAUSE du bind refusé est CONSERVÉE (elle partait dans /dev/null : « >/dev/null 2>&1 & »)" \
  || ko "24b log du bind refusé sans cause : $(tail -2 "$TMP/fakejenkins-bis.log" | tr '\n' ' ' | cut -c1-90)"
# contre-témoin : le serveur de CETTE suite, lui, a annoncé le port qu'il a
# réellement obtenu — c'est cette ligne qu'on attend, plus un curl anonyme.
[ -n "$PORT" ] && grep -q "^LISTENING $PORT\$" "$TMP/fakejenkins.log" \
  && ok "24c contre-témoin : le serveur de la suite a ANNONCÉ son port ($PORT) ; le harnais attend cette ligne, qu'aucun serveur voisin ne peut écrire dans NOTRE log" \
  || ko "24c le serveur de la suite n'a pas annoncé son port (PORT='$PORT')"

echo
echo "== 25. LA RÈGLE UNIQUE : un « @ » dans GIT_HOST ⇒ REFUS, et rien à deviner =="
# LA LEÇON DE CINQ PASSES, écrite en épreuves. Poursuivre les caractères d'un
# secret dans une chaîne libre est indécidable en pratique ; DÉCIDER si un « @ »
# sépare une identité ou appartient à un chemin ne l'est pas davantage. Les
# passes 1 à 4 ont chacune ajouté un caractère à la chasse ; la passe 5 a ajouté
# une EXCEPTION (« sauf si l'autorité ressemble à un hôte ») et c'est
# l'exception qui a laissé fuir. La passe 6 supprime la frontière au lieu de la
# raffiner : un « @ » ⇒ REFUS, sauf un GIT_HOST qui COMMENCE par « / », « ./ »,
# « ../ » ou « ~ ».

echo "-- 25a. LA RÈGLE, forme par forme : un « @ » ⇒ REFUS ; le CHEMIN, lu au 1er caractère --"
# ⚠ NON-RÉGRESSION CRITIQUE : les harnais de ce dépôt clonent depuis des CHEMINS
# LOCAUX (faux dépôts bare sous /tmp). Un refus trop large les casserait TOUS —
# d'où les témoins « ok » de forme chemin. Le côté fail-closed est mesuré par les
# formes qui portent le caractère de chaque passe précédente, ET par les trois
# formes que la passe 5 classait « ok » : une URL dont le « @ » est dans le
# chemin, avec ou sans port, et l'autorité qui ressemble à un hôte.
# LES FORMES ABSURDES SONT LÀ EXPRÈS (« /@ », « @ », « .cache/x@y ») : une règle
# qui tient en une ligne se garde en énumérant ses bords, pas en les évitant.
F25=0
while IFS='|' read -r H25 ATT25; do
  [ -n "$H25" ] || continue
  H25=$(printf '%b' "$H25")
  R25=$(GIT_HOST="$H25" bash -c ". '$LIB'; _gc_host_userinfo && echo REFUS || echo ok")
  [ "$R25" = "$ATT25" ] || { F25=$((F25+1)); printf '     ↳ %s -> %s (attendu %s)\n' "$H25" "$R25" "$ATT25"; }
done <<'T25'
http://gitea:3000|ok
http://gitea:3000/ci/stoa-labs.git|ok
https://forge.example.com:8443/ci/a.git|ok
/tmp/gencho.XXXX/gitea15|ok
/home/jenkins/workspace/job@2/clients|ok
./forge@local|ok
../forge@local|ok
~/forge@local|ok
~depots/forge@local|ok
/@|ok
~u:SEC/RET@hote:scm|ok
http://u:pass@hote/x|REFUS
http://u:P@ssw0rd-Bq@hote|REFUS
http://u:CANARI/AVEC-SLASH@hote|REFUS
http://u:CANARI ESPACE@hote|REFUS
http://u:CANARI\tTAB@hote|REFUS
http://u:CANARI\nNL@hote|REFUS
git@forge.bdf.fr:scm|REFUS
git:CANARI/AVEC-SLASH@forge.bdf.fr:scm|REFUS
git:C/A@N:ARI@forge.bdf.fr:scm|REFUS
git:CAN/ARI@forge.bdf.fr:2222/scm|REFUS
ssh://git:CAN/ARI-J@forge.bdf.fr:2222/scm|REFUS
@forge|REFUS
http://@forge|REFUS
@|REFUS
http://forge.bdf.fr/gitea@v1|REFUS
https://forge.example.com:8443/a/b@c|REFUS
http://forge.bdf.fr:8443/depot@v1|REFUS
http://svc:4821/Xk9pQ@forge-inexistant-zz.invalid/x|REFUS
.cache/forge@local|REFUS
T25
[ "$F25" = "0" ] \
  && ok "30 formes classées comme annoncé : 11 « pas une identité » — les CHEMINS, et EUX SEULS, reconnus au PREMIER caractère — et 19 refusées, dont les caractères des passes 1 à 4 ET les trois formes que la passe 5 laissait passer" \
  || ko "$F25 forme(s) mal classée(s) par la règle (détail ci-dessus)"
# LE CONTRE-TÉMOIN DE LA RÈGLE : « .cache/forge@local » commence par un point
# mais PAS par « ./ » — il est refusé. Sans lui, on ne saurait pas si
# l'exception lit les quatre préfixes ou « tout ce qui ressemble à un chemin »,
# et « ressembler à » est précisément ce que la passe 5 a payé.

echo "-- 25b. le refus tombe AVANT tout appel réseau (shim git : jamais invoqué) --"
# « avant tout appel réseau » est une PROMESSE, donc elle s'énumère : un shim
# `git` en tête de PATH qui laisse une trace à chaque invocation. Sans
# GC_PLATFORM_DIR, ce run clonerait le dépôt plateforme — c'est le premier geste
# réseau de la chaîne.
SHIM25="$TMP/shim25"; mkdir -p "$SHIM25"
printf '#!/usr/bin/env bash\ntouch "%s/git-invoque"\nexit 1\n' "$TMP" > "$SHIM25/git"; chmod 700 "$SHIM25/git"
rm -f "$TMP/git-invoque"
PATH="$SHIM25:$PATH" GIT_SUBDIR=livrable GIT_HOST='http://u:s3cr3t@forge.example' GIT_REPO=ci/stoa-labs GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >"$TMP/d25b.out" 2>"$TMP/d25b.err"; RC=$?
[ "$RC" -ne 0 ] && [ ! -f "$TMP/git-invoque" ] && [ ! -s "$TMP/d25b.out" ] \
  && ok "refus rendu SANS que git soit invoqué une seule fois (aucun accès réseau, stdout vide)" \
  || ko "git a été invoqué avant le refus (trace=$([ -f "$TMP/git-invoque" ] && echo oui || echo non), rc=$RC)"
# CONTRE-TÉMOIN, sinon 25b se lirait « le shim ne marche pas » : le MÊME run,
# GIT_HOST sans identifiants, invoque bien git.
rm -f "$TMP/git-invoque"
PATH="$SHIM25:$PATH" GIT_SUBDIR=livrable GIT_HOST='http://forge.example' GIT_REPO=ci/stoa-labs GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >/dev/null 2>"$TMP/d25b2.err"
[ -f "$TMP/git-invoque" ] \
  && ok "contre-témoin : sur un GIT_HOST propre, le MÊME shim EST invoqué — 25b mesure bien le refus, pas un shim inerte" \
  || ko "le shim git n'est jamais invoqué, même sans identifiants : 25b ne prouve rien"

echo "-- 25c. le refus explique le remède, et ne cite JAMAIS la valeur --"
R25C=$(grep -m1 '^GIT_HOST_PORTE_IDENTIFIANTS : ' "$TMP/d25b.err")
PB25=""
grep -qF 'FORGE_USER' <<<"$R25C" || PB25="${PB25} FORGE_USER-absent"
grep -qF 'FORGE_SECRET' <<<"$R25C" || PB25="${PB25} FORGE_SECRET-absent"
grep -qF 'GIT_HOST_USERINFO_TOLERE' <<<"$R25C" || PB25="${PB25} porte-de-sortie-non-nommée"
# LE CAS ASSUMÉ DOIT ÊTRE NOMMÉ, AVEC SON REMÈDE. C'est la contrepartie de la
# règle unique : un opérateur dont l'URL est parfaitement légitime et dont seul
# le CHEMIN porte un « @ » rencontre ce refus. S'il n'y lit que « identifiants »,
# il cherchera un secret qui n'existe pas.
grep -qF 'RÈGLE UNIQUE' <<<"$R25C" || PB25="${PB25} la-règle-n-est-pas-énoncée"
grep -qF "CHEMIN QUI PORTE LE" <<<"$R25C" || PB25="${PB25} cas-URL-légitime-non-nommé"
grep -qF 'chemin sans' <<<"$R25C" || PB25="${PB25} remède-du-cas-légitime-absent"
grep -qF 's3cr3t' <<<"$R25C" && PB25="${PB25} LE-REFUS-CITE-LE-SECRET"
grep -qF 'forge.example' <<<"$R25C" && PB25="${PB25} LE-REFUS-CITE-L-HÔTE"
[ -z "$PB25" ] \
  && ok "le refus nomme le remède (FORGE_USER + FORGE_SECRET) ET la porte de sortie, sans citer ni le secret ni l'hôte" \
  || ko "refus incomplet ou bavard :${PB25}"

echo "-- 25d. le knob n'a AUCUN défaut : seul « 1 » tolère, tout le reste refuse --"
# « Aucun défaut » est une phrase absolue : elle s'énumère. Un `${VAR:-1}` ou un
# test laxiste (non vide ⇒ toléré) la rendrait fausse en silence.
F25D=0
for V in "" "0" "true" "oui" "yes" "2" "01" " 1" "1 "; do
  RCV=$(GIT_HOST_USERINFO_TOLERE="$V" GC_PLATFORM_DIR="$WS15" GIT_SUBDIR=livrable \
        GIT_HOST='http://u:s3cr3t@forge.example' GITEA_TOKEN=dummy \
        bash -c ". '$LIB'; generate_choices_apis_raw dev" >/dev/null 2>"$TMP/d25d.err"; echo $?)
  if [ "$RCV" -eq 0 ] || ! grep -q '^GIT_HOST_PORTE_IDENTIFIANTS : ' "$TMP/d25d.err"; then
    F25D=$((F25D+1)); printf '     ↳ GIT_HOST_USERINFO_TOLERE=[%s] a TOLÉRÉ (rc=%s)\n' "$V" "$RCV"
  fi
done
[ "$F25D" = "0" ] \
  && ok "les 9 valeurs autres que « 1 » (dont vide, « 0 », « true », « 01 », « 1 » entouré d'espaces) REFUSENT — le knob n'a aucun défaut et aucune tolérance de saisie" \
  || ko "$F25D valeur(s) ont toléré sans valoir « 1 » (détail ci-dessus)"
# et l'avertissement toléré DIT ce sur quoi la protection repose alors.
A25=$(grep -m1 '^GIT_HOST_PORTE_IDENTIFIANTS_TOLERE : ' "$TMP/d16bt.err")
grep -qi 'expurgation' <<<"$A25" && grep -qi 'filet' <<<"$A25" && grep -qi 'garantie' <<<"$A25" \
  && ok "l'avertissement toléré nomme le prix : la protection ne repose plus que sur l'EXPURGATION, « un filet et non une garantie »" \
  || ko "l'avertissement toléré ne dit pas sur quoi repose la protection : $A25"

echo "-- 25e. I5(b) : les wrappers XML n'abattent plus le shell appelant sous set -u --"
# MESURÉ sur le worktree d'avant : `generate_choices_apis` portait un « $1 » NU.
# Sous `set -u` — que les quatre appelants réels utilisent — l'absence d'argument
# faisait sortir le shell APPELANT sur « $1: unbound variable », AVANT que la
# garde ENV_REQUIS de la variante _raw (et son marqueur) n'aient pu sortir.
# C'est le défaut H2, une couche au-dessus, et il était encore ouvert.
for FN in generate_choices_teams generate_choices_apis; do
  bash -c "set -u; . '$LIB'; $FN; RCF=\$?; echo APPELANT-VIVANT; exit \$RCF" \
    >"$TMP/d25e-$FN.out" 2>"$TMP/d25e-$FN.err"; RC=$?
  PB=""
  grep -q '^APPELANT-VIVANT$' "$TMP/d25e-$FN.out" || PB="${PB} APPELANT-ABATTU"
  [ "$RC" -ne 0 ] || PB="${PB} rc=0"
  grep -q "^ENV_REQUIS : ${FN}_raw " "$TMP/d25e-$FN.err" || PB="${PB} refus-ENV_REQUIS-absent"
  grep -q 'unbound variable' "$TMP/d25e-$FN.err" && PB="${PB} unbound-variable"
  [ -z "$PB" ] \
    && ok "$FN sans argument sous set -u : refus NOMMÉ par la variante _raw, rc≠0, et l'appelant SURVIT" \
    || ko "$FN sous set -u :${PB} — $(head -1 "$TMP/d25e-$FN.err" | cut -c1-70)"
done
# et le marqueur suit la même règle qu'ailleurs : APIS l'émet, TEAMS jamais.
grep -q '^CHOICES_SKIPPED_REPOS=0$' "$TMP/d25e-generate_choices_apis.err" \
  && ! grep -q '^CHOICES_SKIPPED_REPOS=' "$TMP/d25e-generate_choices_teams.err" \
  && ok "le wrapper APIS relaie le marqueur du chemin ENV_REQUIS, le wrapper TEAMS n'en émet aucun (même contrat qu'en § 17)" \
  || ko "marqueur incohérent depuis les wrappers XML"

echo "-- 25f. le transport qui TRONQUE le secret : la règle 3bis, et la limite qui reste --"
# CE CANARI ÉTAIT UN VERT VACANT, ET C'EST MESURÉ. Il valait
# GIT_HOST='ssh://git:MOT/LONGSEGMENT@forge.bdf.fr:2222/scm' et cherchait
# « LONGSEGMENT ». Or ssh coupe l'autorité au PREMIER « / » : il ne réémet que
# « git:MOT ». « LONGSEGMENT » n'apparaissait donc JAMAIS dans la sortie, règle
# 3bis armée ou non — le canari évitait le cas dur qu'il prétendait garder.
# MUTATION JOUÉE (seuil de la règle 3bis porté de 4 à 9999, donc règle
# DÉSARMÉE) : l'ancien canari restait VERT — 0 occurrence ; celui d'en dessous,
# qui place le segment long dans la TÊTE réellement réémise, rougit — 2
# occurrences. Le canari contient désormais EXACTEMENT le cas couvert.
# TROIS assertions, parce que trois choses distinctes doivent tenir : que le
# transport tronque VRAIMENT (sinon rien n'est mesuré), que le segment réémis
# est masqué (la GARANTIE), et que le segment court, lui, sort (la LIMITE).
GIT_HOST_USERINFO_TOLERE=1 GC_PLATFORM_DIR="$WS15" GIT_SUBDIR=livrable \
  GIT_HOST='ssh://git:LONGSEGMENT/Zq7@forge.bdf.fr:2222/scm' GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >"$TMP/d25g.out" 2>"$TMP/d25g.err"
N25G=$(( $(grep -cF 'LONGSEGMENT' "$TMP/d25g.err") + $(grep -cF 'LONGSEGMENT' "$TMP/d25g.out") ))
grep -qF 'Could not resolve hostname git:' "$TMP/d25g.err" \
  && ok "25f le transport TRONQUE bien (ssh coupe l'autorité au premier « / ») — sans ce fait, l'assertion suivante ne mesurerait rien : c'est ce qui manquait au canari d'avant" \
  || ko "25f le transport n'a pas tronqué : le canari ne place plus le segment dans la partie réémise, l'épreuve suivante redevient vacante — $(grep -m1 'avertissement' "$TMP/d25g.err" | cut -c1-140)"
[ "$N25G" = "0" ] && grep -qF 'forge.bdf.fr:2222' "$TMP/d25g.err" \
  && ok "25f GARANTIE : le segment de mot de passe RÉELLEMENT réémis par le transport tronquant est masqué (règle 3bis), et l'hôte reste lisible" \
  || ko "25f fuite par troncature : ${N25G} occurrence(s) de « LONGSEGMENT » — $(grep -m1 'LONGSEGMENT' "$TMP/d25g.err" | cut -c1-140)"
# LA LIMITE, mesurée et NON masquée : un segment de MOINS de 4 caractères réémis
# par le transport n'est PAS masqué (seuil délibéré — masquer « dev », « api »
# ou « git » partout rendrait le diagnostic illisible). On la mesure sur le cas
# SYMÉTRIQUE : le segment court, cette fois, dans la tête réémise.
GIT_HOST_USERINFO_TOLERE=1 GC_PLATFORM_DIR="$WS15" GIT_SUBDIR=livrable \
  GIT_HOST='ssh://git:Zq7/LONGSEGMENT@forge.bdf.fr:2222/scm' GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >"$TMP/d25h.out" 2>"$TMP/d25h.err"
N25H=$(( $(grep -cF 'Zq7' "$TMP/d25h.err") + $(grep -cF 'Zq7' "$TMP/d25h.out") ))
[ "$N25H" -gt 0 ] \
  && ok "25f LIMITE : un segment de 3 caractères réémis par le transport sort en clair ($N25H fois) — c'est le seuil de la règle 3bis, et l'en-tête de la lib l'écrit noir sur blanc" \
  || ko "25f le seuil a changé : plus aucune fuite du segment court. Ce n'est pas forcément un défaut — mais l'en-tête de la lib annonce cette limite, corriger les deux dans le même commit."
# contre-témoin : sur le MÊME secret, la forme http ne tronque pas — c'est la
# règle 3 (entière) qui opère, et elle opère aussi.
GIT_HOST_USERINFO_TOLERE=1 GC_PLATFORM_DIR="$WS15" GIT_SUBDIR=livrable \
  GIT_HOST='http://git:MOT/LONGSEGMENT@forge.bdf.fr/x' GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_apis_raw dev" >/dev/null 2>"$TMP/d25g2.err"
grep -qF 'LONGSEGMENT' "$TMP/d25g2.err" \
  && ko "fuite sur la forme http du même secret : $(grep -m1 'LONGSEGMENT' "$TMP/d25g2.err" | cut -c1-140)" \
  || ok "contre-témoin : le MÊME secret en http (aucune troncature) ne sort pas non plus"

echo "-- 25g. la porte ne casse AUCUN harnais : la pose complète depuis un chemin local reste verte --"
# La garde d'ensemble : si le refus était trop large, c'est ICI que tout
# tomberait — GIT_HOST est un chemin de fichier dans toute cette suite.
OUT25=$(GIT_HOST="$GH" GIT_REPO=ci/stoa-labs GITEA_TOKEN=dummy \
  bash -c ". '$LIB'; generate_choices_teams dev" 2>"$TMP/d25f.err"); RC=$?
[ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT25" | grep -c '<string>')" = "2" ] \
  && ! grep -qE '^GIT_HOST_PORTE_IDENTIFIANTS(_TOLERE)? : ' "$TMP/d25f.err" \
  && ok "GIT_HOST = chemin local (la forme de TOUS les harnais de ce dépôt) : 2 fragments, rc 0, ni refus ni avertissement" \
  || ko "la porte casse le harnais : rc=$RC out='$OUT25'"
echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
