#!/usr/bin/env bash
# test-app-request-v2.sh — preuve X/X de la Task 4 (P3) : app-request v2
# (listes déroulantes + identité entrante) — scripts/provision-request.sh +
# ci/jenkins/app-request.job.xml + ci/Jenkinsfile.app-request (le pipeline, sorti
# du XML lors de la conversion en Jenkinsfile déclaratif : le XML ne porte plus
# que la coquille « Pipeline from SCM » et les paramètres à marqueurs).
#
# DEUX TERRAINS :
#   - Section A (gardes) et B (câblage placeholders) : HORS LIGNE — ni Gitea
#     ni Jenkins réels (bare repos locaux + faux Jenkins python, motif de
#     test-generate-choices.sh).
#   - Sections C/D/E (non-régression, nominal enrichi, garde REQ_TEAM) :
#     contre le VRAI Gitea du lab (poc-gitea, port 13000) — provision-request.sh
#     clone en http:// forcé, un bare repo local ne suffit pas ici. Objets
#     JETABLES (préfixe p3t4-<timestamp>, sauf C qui utilise les apps FIXES
#     des golden files — cf. plus bas), nettoyés en fin de run (branches
#     supprimées ; les PR restent, Gitea ne permet pas de les supprimer —
#     inoffensif, même motif que test-team-onboarding-chain.sh).
#
#   Section C compare contre des FIXTURES COMMITTÉES
#   (scripts/testdata/app-request-v2/golden-*.ansible.yml, rendues UNE FOIS
#   par le script d'avant Task 4) — jamais contre `git show HEAD:...`, dont la
#   valeur probante s'éteint dès que ce commit devient HEAD (fix round 1).
#
#   GITEA_TOKEN_FILE=<fichier 0600> ./scripts/test-app-request-v2.sh
#   (défaut : mint un token jetable via `docker exec -u git poc-gitea ...`
#   si GITEA_TOKEN_FILE est absent ET que le conteneur poc-gitea existe.)
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
S="$REPO/scripts/provision-request.sh"
TS="$(date +%s)"
TMP="$(mktemp -d /tmp/apprq2.XXXXXX)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

CLEAN_BRANCHES=()
FAKE_PID=""
cleanup(){
  [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null
  if [ -n "${GITEA_TOKEN:-}" ] && [ ${#CLEAN_BRANCHES[@]} -gt 0 ]; then
    for b in "${CLEAN_BRANCHES[@]}"; do
      curl -s -o /dev/null -X DELETE -H "Authorization: token $GITEA_TOKEN" \
        "http://localhost:13000/api/v1/repos/ci/stoa-labs/branches/${b}" 2>/dev/null || true
    done
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "═══ Section A — gardes d'entrée (HORS LIGNE, AVANT tout geste Git) ═══"
# GIT_HOST volontairement injoignable : la preuve qu'AUCUNE garde ci-dessous
# ne touche le réseau est que le script échoue AVANT d'imprimer "[1/4]"
# (premier message qui suit le clone).
run_guard(){
  # $1=label $2=expected_tag ; le reste = env KEY=VALUE...
  local label="$1" tag="$2"; shift 2
  local out rc
  out=$(env -i PATH="$PATH" GITEA_TOKEN=dummy GIT_HOST="http://127.0.0.1:1" \
        REQ_APP="probe" REQ_ENV="dev" REQ_API="accounts-read" REQ_CLIENT_ID="probe" \
        REQ_CALLER="oig-provisioner" "$@" bash "$S" 2>&1)
  rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "$tag"; then
    if printf '%s' "$out" | grep -q '\[1/4\]'; then
      ko "$label : refusé mais APRÈS le clone (réseau touché) — pas 'AVANT tout geste Git'"
    else
      ok "$label : refusé ($tag), AVANT tout appel réseau"
    fi
  else
    ko "$label : attendu exit=2 + '$tag', obtenu rc=$rc out=$(printf '%s' "$out" | tail -1)"
  fi
}
run_guard "IP CIDR refusé"        "IP_CIDR_REFUSE"        REQ_IP_ALLOWLIST="10.0.0.0/24"
run_guard "IP caractère invalide" "IP_ALLOWLIST_INVALID"  REQ_IP_ALLOWLIST='10.0.0.1;evil'
run_guard "cert = clé privée"     "CERT_PRIVATE_KEY_REFUSE" REQ_CERT_PEM=$'-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----'
run_guard "cert sans bloc"        "CERT_SANS_BLOC"         REQ_CERT_PEM='pas un certificat'
run_guard "rotation invalide"     "CERT_ROTATION_INVALIDE" REQ_CERT_PEM=$'-----BEGIN CERTIFICATE-----\nx\n-----END CERTIFICATE-----' REQ_CERT_ROTATION='detruire'
run_guard "team format invalide"  "TEAM_NAME_INVALID"      REQ_TEAM='Not Valid!'

# Contre-épreuve VERTE symétrique : ces mêmes gardes ne se déclenchent pas sur
# une valeur légitime (à distinguer d'un simple "grep absent" qui passerait
# aussi si le script plantait ailleurs) — vérifiée en section C/D (réseau réel).
echo
echo "═══ Section B — câblage des placeholders app-request.job.xml (HORS LIGNE) ═══"
# Bare repos locaux = "Gitea" (clone accepte un chemin fichier) ; faux Jenkins
# = même serveur minimal que test-generate-choices.sh, étendu pour enregistrer
# le corps POSTé (nécessaire pour vérifier que TEAM/API sont bien substitués
# dans CE job précis, premier consommateur réel du mécanisme Task 3).
PLAT="$TMP/platform.git"; git init -q --bare "$PLAT"
WPLAT="$TMP/wplat"; git clone -q "$PLAT" "$WPLAT"
mkdir -p "$WPLAT/poc-control-plane-federation/ansible" "$WPLAT/poc-control-plane-federation/clients/teamx/apis"
cat > "$WPLAT/poc-control-plane-federation/ansible/providers.dev.yml" <<'YML'
providers:
  - team: teamx
    repo: ""
    approvers: []
YML
cat > "$WPLAT/poc-control-plane-federation/clients/teamx/apis/foo.publish.yml" <<'YML'
apim_api:
  name: foo
  version: 2.0.0
YML
git -C "$WPLAT" add -A
git -C "$WPLAT" -c user.email=t@t -c user.name=t commit -qm seed
git -C "$WPLAT" push -q origin HEAD:main

cat > "$TMP/fakejenkins.py" <<'PY'
import os, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
BODYDIR = os.environ["BODYDIR"]
class H(BaseHTTPRequestHandler):
    def _send(self, code, body=b"{}"):
        self.send_response(code); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path.startswith("/crumbIssuer"):
            return self._send(200, b'{"crumbRequestField":"Jenkins-Crumb","crumb":"abc"}')
        return self._send(404)  # tout job "absent" -> toujours createItem
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n) if n else b""
        if self.path.startswith("/createItem"):
            name = re.search(r"name=([^&]+)", self.path).group(1)
            with open(os.path.join(BODYDIR, name + ".posted.xml"), "wb") as f:
                f.write(body)
            return self._send(200)
        self._send(404)
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
BODYDIR="$TMP/posted"; mkdir -p "$BODYDIR"
PORT="${FAKE_JENKINS_PORT:-18420}"
BODYDIR="$BODYDIR" python3 "$TMP/fakejenkins.py" "$PORT" >/dev/null 2>&1 &
FAKE_PID=$!
for _ in $(seq 1 40); do curl -s "http://127.0.0.1:$PORT/x" >/dev/null 2>&1 && break; sleep 0.1; done

# Jeu de jobs réduit à app-request seul (team-request/team-apply hors sujet
# ici) ; le job XML lu est celui RÉELLEMENT livré par cette tâche
# (ci/jenkins/app-request.job.xml du dépôt, pas une copie).
OUT=$(cd "$REPO" && JENKINS_UI="http://127.0.0.1:$PORT" JOBS="app-request" ENVN=dev \
  GIT_HOST="$TMP" GIT_REPO="platform" GITEA_TOKEN="dummy" \
  ./scripts/setup-team-onboard-jobs.sh 2>&1)
RC=$?
if [ "$RC" -ne 0 ]; then
  ko "câblage placeholders : setup-team-onboard-jobs.sh a échoué — $(printf '%s' "$OUT" | tail -5)"
else
  POSTED="$TMP/posted/app-request.posted.xml"
  if [ -f "$POSTED" ] && grep -q '<string>teamx</string>' "$POSTED" && grep -q '<string>foo@2.0.0</string>' "$POSTED"; then
    ok "câblage placeholders : app-request posté avec TEAM=teamx et API=foo@2.0.0"
  else
    ko "câblage placeholders : fragments attendus absents du XML posté"
  fi
  if ! grep -q 'CHOICES:TEAMS\|CHOICES:APIS' "$POSTED" 2>/dev/null; then
    ok "câblage placeholders : aucun marqueur résiduel dans le XML posté"
  else
    ko "câblage placeholders : marqueur résiduel non substitué"
  fi
  # Fix round 1 (revue, Important, static) : le refus loud API_FORMAT_INVALIDE
  # (fix 4) doit rester CÂBLÉ — PAS de fallback silencieux '1.0.0' pour une
  # valeur non vide sans '@'.
  # Vérification STATIQUE (pas d'exécution Groovy réelle — aucun `groovy` CLI
  # dans ce lab, et le faux Jenkins ci-dessus n'exécute aucun pipeline, motif
  # déjà accepté pour le reste de la logique Groovy de ce job dans ce test).
  #
  # RE-POINTÉ (2026-08-06, conversion en Jenkinsfile déclaratif) : le pipeline
  # ne vit PLUS en Groovy inline dans ci/jenkins/app-request.job.xml — il est
  # dans ci/Jenkinsfile.app-request, et le XML posté n'est plus qu'une coquille
  # « Pipeline from SCM » qui POINTE dessus. Le garde-fou est donc cherché dans
  # le Jenkinsfile ; et comme un garde-fou vivant dans un fichier que le job ne
  # charge pas serait un vert vacant, LES DEUX BOUTS de la chaîne sont vérifiés
  # (le garde-fou d'un côté, le pointeur SCM de l'autre).
  JF_APP="$REPO/ci/Jenkinsfile.app-request"
  if grep -q 'API_FORMAT_INVALIDE' "$JF_APP" 2>/dev/null; then
    ok "câblage placeholders : le garde-fou API_FORMAT_INVALIDE (fix 4) est bien dans ci/Jenkinsfile.app-request"
  else
    ko "câblage placeholders : API_FORMAT_INVALIDE absent de ci/Jenkinsfile.app-request"
  fi
  if grep -qF '<scriptPath>poc-control-plane-federation/ci/Jenkinsfile.app-request</scriptPath>' "$POSTED" 2>/dev/null \
     && grep -q 'CpsScmFlowDefinition' "$POSTED" 2>/dev/null \
     && ! grep -q '<script>' "$POSTED" 2>/dev/null; then
    ok "câblage placeholders : le job posé est un Pipeline from SCM pointant sur ci/Jenkinsfile.app-request (aucun Groovy inline résiduel)"
  else
    ko "câblage placeholders : le XML posté ne charge pas ci/Jenkinsfile.app-request (ou porte encore du Groovy inline) — le garde-fou ci-dessus ne serait jamais exécuté"
  fi

  # Fix round 2 (revue, casse nouvelle du round 1) : le sed double-forme ne
  # supprime QUE la ligne du marqueur — un choix de secours posé sur une
  # ligne SÉPARÉE (round 1) survivait donc à une substitution PROPRE
  # (choices -> ['', 'foo@2.0.0'], choix par défaut VIDE sur un champ requis
  # — reproduit live par le revieweur). Remède : secours + marqueur sur la
  # MÊME ligne (round 2). Preuve dans LES DEUX SENS :
  #   (a) job POSÉ (substitué) : le choix de secours a disparu AVEC le
  #       marqueur — premier (et seul, ici) choix = le vrai nom@version.
  api_choices(){ # $1 = fichier XML -> une valeur de <string> par ligne, pour le
                 # ChoiceParameterDefinition nommé API (jamais TEAM/REQ_ENV/...)
    python3 -c "
import xml.etree.ElementTree as ET, sys
root = ET.parse(sys.argv[1]).getroot()
for pd in root.iter('hudson.model.ChoiceParameterDefinition'):
    name = pd.findtext('name')
    if name != 'API':
        continue
    for s in pd.iter('string'):
        print(s.text if s.text is not None else '')
" "$1" 2>/dev/null
  }
  API_CHOICES_POSTED=$(api_choices "$POSTED")
  if [ "$(printf '%s\n' "$API_CHOICES_POSTED" | grep -c '^$')" -eq 0 ] \
     && [ "$(printf '%s\n' "$API_CHOICES_POSTED" | head -1)" = "foo@2.0.0" ]; then
    ok "câblage placeholders : job POSÉ — aucun choix vide résiduel, premier choix = foo@2.0.0"
  else
    ko "câblage placeholders : job POSÉ — choix API inattendus : [$(printf '%s,' "$API_CHOICES_POSTED")]"
  fi
  #   (b) XML SOURCE du dépôt, BRUT (jamais substitué — ex. job posé sans
  #       passer par setup-team-onboard-jobs.sh) : EXACTEMENT un choix vide,
  #       jamais zéro (sinon menu inutilisable, round 1) ni deux (round 2).
  API_CHOICES_RAW=$(api_choices "$REPO/ci/jenkins/app-request.job.xml")
  N_EMPTY=$(printf '%s\n' "$API_CHOICES_RAW" | grep -c '^$')
  N_TOTAL=$(printf '%s\n' "$API_CHOICES_RAW" | grep -c '.*')
  if [ "$N_EMPTY" -eq 1 ] && [ "$N_TOTAL" -eq 1 ]; then
    ok "câblage placeholders : XML source BRUT — exactement UN choix vide (jamais choices=[])"
  else
    ko "câblage placeholders : XML source BRUT — attendu 1 choix vide et rien d'autre, obtenu $N_TOTAL choix ($N_EMPTY vide(s))"
  fi
fi

echo
echo "═══ Sections C/D/E — contre le Gitea RÉEL du lab (poc-gitea:13000) ═══"
GITEA_TOKEN=""
if [ -n "${GITEA_TOKEN_FILE:-}" ] && [ -r "$GITEA_TOKEN_FILE" ]; then
  GITEA_TOKEN="$(cat "$GITEA_TOKEN_FILE")"
elif docker inspect poc-gitea >/dev/null 2>&1; then
  GITEA_TOKEN=$(docker exec -u git poc-gitea gitea admin user generate-access-token \
    --username ci --token-name "p3t4-test-$TS" \
    --scopes write:repository,write:issue 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
fi
if [ -z "$GITEA_TOKEN" ] || ! curl -s -o /dev/null -w '' "http://localhost:13000" 2>/dev/null; then
  echo "  (sections C/D/E sautées — Gitea du lab (poc-gitea:13000) ou token indisponible)"
else
  GH="http://localhost:13000"
  branch_sha(){ curl -s -H "Authorization: token $GITEA_TOKEN" "$GH/api/v1/repos/ci/stoa-labs/branches/$1" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('commit',{}).get('id',''))" 2>/dev/null; }
  raw_manifest(){ curl -s -H "Authorization: token $GITEA_TOKEN" "$GH/api/v1/repos/ci/stoa-labs/raw/${1}/poc-control-plane-federation/clients/provisioned/applications/${2}.ansible.yml"; }
  raw_cert(){ curl -s -H "Authorization: token $GITEA_TOKEN" "$GH/api/v1/repos/ci/stoa-labs/raw/${1}/poc-control-plane-federation/clients/provisioned/certs/${2}.crt"; }
  pr_body(){ curl -s -H "Authorization: token $GITEA_TOKEN" "$GH/api/v1/repos/ci/stoa-labs/pulls?state=all&limit=50" \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
for pr in d:
    if pr.get('head',{}).get('ref')=='$1':
        print(pr.get('body',''))
        break
" 2>/dev/null; }

  echo "── C. non-régression (golden files, méthode palier 2 T6) ──"
  # Fix round 1 (revue, Important) : la preuve C comparait AVANT/APRÈS en
  # extrayant le script PRÉ-Task-4 via `git show HEAD:...` — valeur probante
  # ÉTEINTE dès que ce commit devient HEAD (HEAD compare alors le script à
  # lui-même, toujours vert). Remède : GOLDEN FILES committés, pour des entrées
  # machine FIXES (REQ_APP=p3t4golden-idp/p3t4golden-int, REQ_ENV=dev,
  # REQ_API=accounts-read v1.0.0, REQ_CALLER=oig-provisioner/cli2-provisioner,
  # sans aucun REQ_* Task 4). La preuve compare le manifeste produit PAR LE
  # SCRIPT COURANT à ces fixtures — un octet qui bouge dans le rendu machine
  # (absent des REQ_* Task 4) fait rougir la preuve, peu importe l'état de HEAD.
  #
  # PROVENANCE : rendus une première fois avec le script d'AVANT Task 4 (commit
  # b39aee1) ; RÉGÉNÉRÉS le 2026-09-02 pour le jalon A1 (GOAL cd-applications),
  # qui change le CONTRAT MACHINE intentionnellement : claim `{ name }` à la
  # racine et sa VALEUR sous per_env.<env> (mode idp), description sans palier,
  # deux lignes d'en-tête « MULTI-PALIER (A1) » — forme D1 de la spec
  # docs/superpowers/specs/2026-09-02-a1-manifeste-multi-palier-design.md.
  #
  # QUAND RÉGÉNÉRER LÉGITIMEMENT : uniquement si le CONTRAT MACHINE lui-même
  # change intentionnellement (ex. nouveau champ ajouté au template idp/
  # internal, hors périmètre Task 4/REQ_* additifs) — jamais pour faire
  # passer une régression au vert. Régénération :
  #   GITEA_TOKEN=... GIT_HOST=http://localhost:13000 GIT_BASE=<base jetable> \
  #     REQ_APP=p3t4golden-idp REQ_ENV=dev REQ_API=accounts-read REQ_API_VER=1.0.0 \
  #     REQ_CALLER=oig-provisioner REQ_CLIENT_ID=golden-client-id \
  #     PROVISION_PLAN_INLINE=false bash scripts/provision-request.sh
  #   (idem p3t4golden-int avec REQ_CALLER=cli2-provisioner, sans REQ_CLIENT_ID ;
  #   puis récupérer le manifeste rendu via l'API Gitea raw et l'écrire dans
  #   scripts/testdata/app-request-v2/golden-*.ansible.yml) — geste EXPLICITE,
  #   jamais automatisé par ce test. PRÉCONDITION : l'app golden n'existe pas
  #   sur la base (sinon le script FUSIONNE au lieu de créer — cf. nonreg_case).
  GOLDEN_DIR="$REPO/scripts/testdata/app-request-v2"
  GIT_BASE_GOLDEN="main"
  nonreg_case(){
    local label="$1" app="$2" caller="$3" golden="$4"; shift 4
    local branch="provision/${app}-dev"
    CLEAN_BRANCHES+=("$branch")
    # A1 (2026-09-02) : le rendu compare un manifeste CRÉÉ ; si l'app golden
    # existait sur main, le script FUSIONNERAIT (per_env seule) et le diff
    # mentirait sur la cause. Précondition nommée plutôt que rouge opaque.
    # (par code HTTP : le raw d'un fichier absent rend un corps JSON non vide)
    if [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: token $GITEA_TOKEN" \
          "$GH/api/v1/repos/ci/stoa-labs/raw/${GIT_BASE_GOLDEN}/poc-control-plane-federation/clients/provisioned/applications/${app}.ansible.yml")" = 200 ]; then
      ko "$label : le manifeste $app existe déjà sur ${GIT_BASE_GOLDEN} — le golden compare une CRÉATION, pas une fusion (retirer le fichier de main)"; return
    fi
    [ -f "$GOLDEN_DIR/$golden" ] || { ko "$label : golden '$golden' absent de $GOLDEN_DIR"; return; }
    local out rc
    out=$(env GITEA_TOKEN="$GITEA_TOKEN" GIT_HOST="$GH" REQ_APP="$app" REQ_ENV=dev REQ_API=accounts-read \
      REQ_API_VER=1.0.0 REQ_CALLER="$caller" PROVISION_PLAN_INLINE=false "$@" bash "$S" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then ko "$label : run en échec — $(printf '%s' "$out" | tail -3)"; return; fi
    local mani; mani=$(raw_manifest "$branch" "$app")
    [ -n "$mani" ] || { ko "$label : manifeste introuvable après le run"; return; }
    if diff -q "$GOLDEN_DIR/$golden" <(printf '%s\n' "$mani") >/dev/null; then
      ok "$label : manifeste identique au golden $golden (script courant, entrées machine sans REQ_* Task 4)"
    else
      ko "$label : le manifeste diverge du golden — RÉGRESSION du rendu machine"
      diff "$GOLDEN_DIR/$golden" <(printf '%s\n' "$mani")
    fi
  }
  # Apps FIXES (pas $TS) : elles doivent matcher les noms EMBARQUÉS dans les
  # golden files (name:, commentaire d'en-tête, description) — cf. en-tête de
  # cette section pour la commande de régénération.
  nonreg_case "mode idp (voie OIG)"       "p3t4golden-idp" "oig-provisioner"  "golden-idp.ansible.yml"      REQ_CLIENT_ID="golden-client-id"
  nonreg_case "mode internal (voie CLI2)" "p3t4golden-int" "cli2-provisioner" "golden-internal.ansible.yml"

  echo "── D. nominal enrichi (formulaire complet) ──"
  APP="p3t4nom$TS"; BR="provision/${APP}-dev"; CLEAN_BRANCHES+=("$BR")
  CERT_PEM_CONTENT="$(cat "$REPO/clients/_example/applications/demo-client.crt")"
  OUTD=$(GITEA_TOKEN="$GITEA_TOKEN" GIT_HOST="$GH" REQ_APP="$APP" REQ_ENV=dev REQ_API=accounts-read \
    REQ_API_VER=1.0.0 REQ_CALLER=oig-provisioner REQ_CLIENT_ID="probe-nom-$TS" \
    REQ_TEAM=banking-demo REQ_IP_ALLOWLIST="10.77.5.1-10.77.5.9" \
    REQ_CERT_PEM="$CERT_PEM_CONTENT" REQ_CERT_ROTATION=overlap \
    PROVISION_PLAN_INLINE=false bash "$S" 2>&1)
  RCD=$?
  if [ "$RCD" -ne 0 ]; then
    ko "nominal enrichi : run en échec — $(printf '%s' "$OUTD" | tail -5)"
  else
    MANI=$(raw_manifest "$BR" "$APP")
    CHECK=1
    printf '%s' "$MANI" | grep -q 'team: "banking-demo"'                          || { ko "nominal : team absent du manifeste"; CHECK=0; }
    # Fix round 1 (revue, Critical) : enforce reste [] MÊME avec IP+cert fournis
    # — dériver enforce arme un piège cross-consommateur (README §enforce),
    # la décision d'opposer revient au MERGE, pas au formulaire. Contre-épreuve
    # DIRECTE : enforce=[] est le signal attendu ICI, pas une régression.
    printf '%s' "$MANI" | grep -q '  enforce: \[\]'                               || { ko "nominal : enforce n'est plus []  — dérivation réintroduite (régression du fix round 1)"; CHECK=0; }
    printf '%s' "$MANI" | grep -q 'cert_rotation: "overlap"'                       || { ko "nominal : cert_rotation absent/faux"; CHECK=0; }
    printf '%s' "$MANI" | grep -q 'ip_allowlist: \["10.77.5.1-10.77.5.9"\]'        || { ko "nominal : ip_allowlist absent"; CHECK=0; }
    printf '%s' "$MANI" | grep -q "public_cert_ref: \"clients/provisioned/certs/${APP}-dev.crt\"" || { ko "nominal : public_cert_ref absent/faux"; CHECK=0; }
    [ "$CHECK" = 1 ] && ok "nominal enrichi : manifeste porte team/cert_rotation/ip_allowlist/public_cert_ref, enforce=[] intouché"

    CERTFILE=$(raw_cert "$BR" "${APP}-dev")
    if [ "$CERTFILE" = "$CERT_PEM_CONTENT" ]; then
      ok "nominal enrichi : clients/provisioned/certs/${APP}-dev.crt versionné, contenu identique au PEM soumis"
    else
      ko "nominal enrichi : fichier .crt absent ou contenu différent"
    fi

    BODY=$(pr_body "$BR")
    if printf '%s' "$BODY" | grep -q "banking-demo" && printf '%s' "$BODY" | grep -q "10.77.5.1-10.77.5.9"; then
      ok "nominal enrichi : la PR mentionne team/IP pour le valideur"
    else
      ko "nominal enrichi : la PR ne mentionne pas les champs d'identité entrante"
    fi
    # Fix round 1 : l'avertissement des DEUX pièges doit être visible dans le
    # corps de la PR dès qu'IP ou cert est fourni (ici les deux le sont).
    if printf '%s' "$BODY" | grep -qi "enforce" && printf '%s' "$BODY" | grep -qi "merge"; then
      ok "nominal enrichi : la PR porte l'avertissement enforce (identifiers posés, non opposés, décision au merge)"
    else
      ko "nominal enrichi : l'avertissement enforce est absent du corps de la PR"
    fi
  fi

  echo "── E. garde REQ_TEAM (déclarée vs non déclarée) ──"
  BADAPP="p3t4bad$TS"; BADBR="provision/${BADAPP}-dev"
  OUTE=$(GITEA_TOKEN="$GITEA_TOKEN" GIT_HOST="$GH" REQ_APP="$BADAPP" REQ_ENV=dev REQ_API=accounts-read \
    REQ_CALLER=oig-provisioner REQ_CLIENT_ID="probe-bad-$TS" REQ_TEAM="not-onboarded-team" \
    PROVISION_PLAN_INLINE=false bash "$S" 2>&1)
  RCE=$?
  BADSHA=$(branch_sha "$BADBR")
  if [ "$RCE" -eq 2 ] && printf '%s' "$OUTE" | grep -q "TEAM_NOT_DECLARED" && [ -z "$BADSHA" ]; then
    ok "garde REQ_TEAM : équipe non déclarée refusée (TEAM_NOT_DECLARED), branche jamais créée sur Gitea"
  else
    ko "garde REQ_TEAM : attendu refus + branche absente — rc=$RCE sha='$BADSHA'"
  fi
  # (le chemin "déclarée" est déjà couvert par la section D : banking-demo y passe)
fi

echo
echo "═══ ${PASS} OK / ${FAIL} KO ═══"
[ "$FAIL" -eq 0 ]
