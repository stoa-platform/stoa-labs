#!/usr/bin/env bash
# test-app-request-v3.sh — preuve X/X de l'incrément app-request v3 :
#   item 1 — IP allowlist MULTI-VALEURS (le rôle acceptait déjà une liste ;
#            seuls le formulaire et l'emballage du script la réduisaient à une
#            valeur unique) ;
#   item 3 — CLÉ BACKEND (identifier `token`) exposée au formulaire par son
#            CHEMIN Vault, jamais par sa valeur.
#
# Fichiers couverts : scripts/provision-request.sh (la substance),
# ci/jenkins/app-request.job.xml (les paramètres) et ci/Jenkinsfile.app-request
# (le pipeline — 2 lignes de routage, aucune logique).
#
# DEUX TERRAINS, comme test-app-request-v2.sh dont ce script reprend le patron :
#   - Sections A (gardes) et B (câblage) : HORS LIGNE — ni Gitea ni Jenkins
#     réels (bare repos locaux + faux Jenkins python).
#   - Sections C (non-régression) et D (nominal v3) : contre le VRAI Gitea du
#     lab (poc-gitea, port 13000) — provision-request.sh clone en http:// forcé,
#     un bare repo local ne suffit pas. Objets JETABLES (préfixe p3v3-<ts>,
#     sauf C qui réutilise les apps FIXES des golden files), branches nettoyées
#     en fin de run (les PR restent : Gitea ne permet pas de les supprimer —
#     inoffensif, même comportement que la suite existante).
#
#   GITEA_TOKEN_FILE=<fichier 0600> ./scripts/test-app-request-v3.sh
#   (défaut : mint un token jetable via `docker exec -u git poc-gitea ...`
#   si GITEA_TOKEN_FILE est absent ET que le conteneur poc-gitea existe.)
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
S="$REPO/scripts/provision-request.sh"
TS="$(date +%s)"
TMP="$(mktemp -d /tmp/apprq3.XXXXXX)"
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

echo "═══ Section A — gardes d'entrée v3 (HORS LIGNE, AVANT tout geste Git) ═══"
# GIT_HOST volontairement injoignable : la preuve qu'AUCUNE garde ci-dessous ne
# touche le réseau est que le script échoue AVANT d'imprimer "[1/4]" (premier
# message qui suit le clone).
BASE_ENV=(GITEA_TOKEN=dummy GIT_HOST="http://127.0.0.1:1"
          REQ_APP="probe" REQ_ENV="dev" REQ_API="accounts-read"
          REQ_CLIENT_ID="probe" REQ_CALLER="oig-provisioner")

# $1=label $2=tag attendu $3=fragment que le MESSAGE doit citer (l'entrée
# fautive ; "" pour ne pas l'exiger) ; le reste = env KEY=VALUE...
run_guard(){
  local label="$1" tag="$2" cite="$3"; shift 3
  local out rc
  out=$(env -i PATH="$PATH" "${BASE_ENV[@]}" "$@" bash "$S" 2>&1); rc=$?
  if [ "$rc" -ne 2 ] || ! printf '%s' "$out" | grep -q "$tag"; then
    ko "$label : attendu exit=2 + '$tag', obtenu rc=$rc out=$(printf '%s' "$out" | tail -1)"
    return
  fi
  if printf '%s' "$out" | grep -q '\[1/4\]'; then
    ko "$label : refusé mais APRÈS le clone (réseau touché) — pas 'AVANT tout geste Git'"
    return
  fi
  # Le message doit NOMMER l'entrée fautive : sur cinq lignes collées, un refus
  # qui ne dit pas LAQUELLE est inactionnable. C'est le comportement neuf de v3
  # (avant, la garde citait la saisie entière — qui ne pouvait qu'être unique).
  if [ -n "$cite" ] && ! printf '%s' "$out" | grep -qF "$cite"; then
    ko "$label : refusé ($tag) mais le message ne cite pas l'entrée fautive '$cite' — out=$(printf '%s' "$out" | tail -1)"
    return
  fi
  ok "$label : refusé ($tag)${cite:+, message citant '$cite'}, AVANT tout appel réseau"
}

# $1=label ; le reste = env KEY=VALUE... — contre-épreuve VERTE : l'entrée est
# LÉGITIME, donc aucune garde v3 ne doit se déclencher. Le run échoue quand même
# (GIT_HOST injoignable), mais PLUS LOIN : ni exit=2, ni tag de refus. Sans ça,
# une garde trop large (« tout multiligne est invalide ») passerait inaperçue.
#
# ET ON VÉRIFIE QUE LE DÉPÔT DE TRAVAIL RESTE INTACT. Ce n'est pas de la
# paranoïa de test : c'est exactement ce qui a cassé le 2026-08-07. Ces
# contre-épreuves sont les PREMIÈRES à franchir les gardes sans réseau ; le
# clone échouait, `cd "$WORK/repo"` échouait, et le script — qui n'a pas
# `set -e` — CONTINUAIT dans le répertoire courant : add + commit dans le dépôt
# plateforme (six commits parasites). La suite v2 ne pouvait pas le voir, toutes
# ses épreuves hors ligne étant des REFUS qui sortent avant le clone.
run_pass(){
  local label="$1"; shift
  local out rc head_before head_after dirty_before dirty_after
  head_before=$(git -C "$REPO" rev-parse HEAD)
  dirty_before=$(git -C "$REPO" status --porcelain | md5 2>/dev/null || git -C "$REPO" status --porcelain | md5sum)
  out=$(env -i PATH="$PATH" "${BASE_ENV[@]}" "$@" bash "$S" 2>&1); rc=$?
  head_after=$(git -C "$REPO" rev-parse HEAD)
  dirty_after=$(git -C "$REPO" status --porcelain | md5 2>/dev/null || git -C "$REPO" status --porcelain | md5sum)
  if [ "$rc" -eq 2 ] || printf '%s' "$out" | grep -qE 'IP_CIDR_REFUSE|IP_ALLOWLIST_INVALID|BACKEND_KEY_'; then
    ko "$label : refusé À TORT — rc=$rc out=$(printf '%s' "$out" | tail -1)"
  elif [ "$head_before" != "$head_after" ] || [ "$dirty_before" != "$dirty_after" ]; then
    ko "$label : LE DÉPÔT DE TRAVAIL A ÉTÉ MODIFIÉ — clone en échec non fatal, le script a écrit dans le cwd"
  elif [ "$rc" -eq 0 ]; then
    ko "$label : le run a RÉUSSI sans réseau — clone en échec traité comme un succès"
  else
    ok "$label : accepté par les gardes, puis échec NET au clone injoignable (dépôt de travail intact)"
  fi
}

echo "── A1. IP multi-valeurs ──"
run_pass "3 IP valides sur 3 lignes" \
  REQ_IP_ALLOWLIST=$'10.60.30.1-10.60.30.30\n192.168.65.1\n10.0.0.7'
run_pass "séparateur virgule toléré" \
  REQ_IP_ALLOWLIST='10.0.0.1, 10.0.0.2,10.0.0.3'
run_pass "lignes vides et espaces parasites ignorés" \
  REQ_IP_ALLOWLIST=$'\n  10.0.0.1  \n\n\t10.0.0.2\n  \n'
run_pass "saisie vide (comportement d'avant v3)" REQ_IP_ALLOWLIST=''
# La régression que v3 pourrait introduire : valider la saisie ENTIÈRE au lieu
# de chaque entrée laisserait passer un CIDR noyé dans une liste valide.
run_guard "CIDR noyé parmi 3 entrées valides" "IP_CIDR_REFUSE" "10.0.0.0/24" \
  REQ_IP_ALLOWLIST=$'10.60.30.1-10.60.30.30\n10.0.0.0/24\n192.168.65.1'
run_guard "caractère interdit noyé parmi des entrées valides" "IP_ALLOWLIST_INVALID" "10.0.0.1;evil" \
  REQ_IP_ALLOWLIST=$'192.168.65.1\n10.0.0.1;evil'
# Non-régression des deux tags sur une saisie MONO-valeur (contrat v2 intact).
run_guard "CIDR seul (contrat v2)"        "IP_CIDR_REFUSE"       "10.0.0.0/24"  REQ_IP_ALLOWLIST="10.0.0.0/24"
run_guard "caractère invalide seul (v2)"  "IP_ALLOWLIST_INVALID" "10.0.0.1;evil" REQ_IP_ALLOWLIST='10.0.0.1;evil'

echo "── A2. clé backend (chemin Vault) ──"
run_pass "chemin KV nominal" \
  REQ_BACKEND_KEY_REF="deploy/banking-demo/apps/probe/dev/backend-key"
run_pass "chemin KV + champ explicite" \
  REQ_BACKEND_KEY_REF="deploy/banking-demo/apps/probe/dev/backend-key" \
  REQ_BACKEND_KEY_FIELD="api_key"
run_guard "traversée .."        "BACKEND_KEY_REF_INVALID" "../"   REQ_BACKEND_KEY_REF="deploy/../../etc/passwd"
run_guard "chemin absolu"       "BACKEND_KEY_REF_INVALID" "/deploy" REQ_BACKEND_KEY_REF="/deploy/x/dev/backend-key"
run_guard "segment vide //"     "BACKEND_KEY_REF_INVALID" "//"    REQ_BACKEND_KEY_REF="deploy//dev/backend-key"
run_guard "termine par /"       "BACKEND_KEY_REF_INVALID" "deploy/x/" REQ_BACKEND_KEY_REF="deploy/x/"
run_guard "caractère hors classe" "BACKEND_KEY_REF_INVALID" 'deploy/x";evil' REQ_BACKEND_KEY_REF='deploy/x";evil'
# Le champ SANS le chemin est inerte : le demandeur croit avoir configuré
# quelque chose et rien n'est lu. Refus loud plutôt que silence.
run_guard "champ sans chemin (inerte)" "BACKEND_KEY_FIELD_ORPHAN" "api_key" \
  REQ_BACKEND_KEY_FIELD="api_key"
run_guard "champ à caractère interdit" "BACKEND_KEY_FIELD_INVALID" 'api_key";x' \
  REQ_BACKEND_KEY_REF="deploy/x/dev/backend-key" REQ_BACKEND_KEY_FIELD='api_key";x'

echo
echo "═══ Section B — câblage du formulaire (HORS LIGNE) ═══"
XML="$REPO/ci/jenkins/app-request.job.xml"
JF="$REPO/ci/Jenkinsfile.app-request"

# B1 — IP_ALLOWLIST doit être une ZONE MULTILIGNE. Un StringParameterDefinition
# résiduel rendrait tout le reste vacant : l'IHM n'accepterait qu'une ligne.
param_class(){ # $1=fichier $2=nom du paramètre -> nom de la classe Jenkins
  python3 -c "
import xml.etree.ElementTree as ET, sys, re
root = ET.parse(sys.argv[1]).getroot()
for pd in root.iter():
    if not pd.tag.startswith('hudson.model.') or not pd.tag.endswith('ParameterDefinition'):
        continue
    if pd.findtext('name') == sys.argv[2]:
        print(pd.tag); break
" "$1" "$2" 2>/dev/null
}
if [ "$(param_class "$XML" IP_ALLOWLIST)" = "hudson.model.TextParameterDefinition" ]; then
  ok "IP_ALLOWLIST est un TextParameterDefinition (zone multiligne)"
else
  ko "IP_ALLOWLIST n'est pas multiligne — classe=$(param_class "$XML" IP_ALLOWLIST)"
fi
for p in BACKEND_KEY_REF BACKEND_KEY_FIELD; do
  if [ "$(param_class "$XML" "$p")" = "hudson.model.StringParameterDefinition" ]; then
    ok "$p présent dans le XML (StringParameterDefinition)"
  else
    ko "$p absent du XML (ou mauvaise classe : $(param_class "$XML" "$p"))"
  fi
done

# B2 — DOCTRINE : le XML fait autorité sur les PARAMÈTRES, le Jenkinsfile sur le
# PIPELINE. Declarative ne remplace QUE les propriétés qu'il a lui-même posées
# (DeclarativeJobPropertyTrackerAction) : un bloc `parameters {}` dans le
# Jenkinsfile ne gagnerait PAS contre le config.xml — la divergence serait
# SILENCIEUSE. D'où : aucun `parameters` côté Jenkinsfile, mais bien le routage.
if grep -qE '^\s*parameters\s*\{' "$JF"; then
  ko "le Jenkinsfile déclare un bloc parameters{} — divergence silencieuse avec le XML (les listes générées mourraient)"
else
  ok "le Jenkinsfile ne déclare AUCUN bloc parameters{} (le XML reste la source de vérité)"
fi
for v in REQ_BACKEND_KEY_REF REQ_BACKEND_KEY_FIELD REQ_IP_ALLOWLIST; do
  if grep -q "\"$v=" "$JF"; then
    ok "$v routé par le withEnv du Jenkinsfile"
  else
    ko "$v absent du withEnv — le paramètre existerait dans l'IHM sans jamais atteindre le script"
  fi
done
# Aucun découpage Groovy : la valeur multiligne doit traverser TELLE QUELLE.
if grep -qE 'IP_ALLOWLIST[^"]*\.(split|tokenize|readLines)' "$JF"; then
  ko "le Jenkinsfile découpe IP_ALLOWLIST — la substance doit rester dans le script (la voie machine perdrait le multi-IP)"
else
  ok "le Jenkinsfile ne découpe pas IP_ALLOWLIST (substance dans le script, voie machine servie)"
fi

# B3 — les marqueurs de liste doivent SURVIVRE aux modifications du XML : sans
# eux, setup-team-onboard-jobs.sh ne substitue plus rien et les deux déroulantes
# (TEAM, API) meurent. Preuve de bout en bout contre un faux Jenkins.
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
PORT="${FAKE_JENKINS_PORT:-18430}"
BODYDIR="$BODYDIR" python3 "$TMP/fakejenkins.py" "$PORT" >/dev/null 2>&1 &
FAKE_PID=$!
for _ in $(seq 1 40); do curl -s "http://127.0.0.1:$PORT/x" >/dev/null 2>&1 && break; sleep 0.1; done

OUT=$(cd "$REPO" && JENKINS_UI="http://127.0.0.1:$PORT" JOBS="app-request" ENVN=dev \
  GIT_HOST="$TMP" GIT_REPO="platform" GITEA_TOKEN="dummy" \
  ./scripts/setup-team-onboard-jobs.sh 2>&1)
if [ $? -ne 0 ]; then
  ko "pose du job : setup-team-onboard-jobs.sh a échoué — $(printf '%s' "$OUT" | tail -5)"
else
  POSTED="$TMP/posted/app-request.posted.xml"
  if [ -f "$POSTED" ] && grep -q '<string>teamx</string>' "$POSTED" && grep -q '<string>foo@2.0.0</string>' "$POSTED" \
     && ! grep -q 'CHOICES:TEAMS\|CHOICES:APIS' "$POSTED"; then
    ok "les modifications v3 du XML n'ont pas cassé la substitution des listes (TEAM=teamx, API=foo@2.0.0, aucun marqueur résiduel)"
  else
    ko "substitution des listes cassée par les modifications v3 du XML"
  fi
  if [ "$(param_class "$POSTED" IP_ALLOWLIST)" = "hudson.model.TextParameterDefinition" ] \
     && [ "$(param_class "$POSTED" BACKEND_KEY_REF)" = "hudson.model.StringParameterDefinition" ] \
     && [ "$(param_class "$POSTED" BACKEND_KEY_FIELD)" = "hudson.model.StringParameterDefinition" ]; then
    ok "job POSÉ : les trois champs v3 arrivent bien jusqu'à Jenkins"
  else
    ko "job POSÉ : un champ v3 manque dans le XML réellement envoyé à Jenkins"
  fi
  # Un pipeline resté en Groovy inline ne chargerait pas le Jenkinsfile où vit
  # le routage des deux nouvelles variables : le vert de B2 serait vacant.
  if grep -qF '<scriptPath>poc-control-plane-federation/ci/Jenkinsfile.app-request</scriptPath>' "$POSTED" \
     && ! grep -q '<script>' "$POSTED"; then
    ok "job POSÉ : Pipeline from SCM vers ci/Jenkinsfile.app-request, aucun Groovy inline"
  else
    ko "job POSÉ : le pipeline n'est pas chargé depuis ci/Jenkinsfile.app-request — le routage v3 ne serait jamais exécuté"
  fi
fi

echo
echo "═══ Sections C/D — contre le Gitea RÉEL du lab (poc-gitea:13000) ═══"
GITEA_TOKEN=""
if [ -n "${GITEA_TOKEN_FILE:-}" ] && [ -r "$GITEA_TOKEN_FILE" ]; then
  GITEA_TOKEN="$(cat "$GITEA_TOKEN_FILE")"
elif docker inspect poc-gitea >/dev/null 2>&1; then
  GITEA_TOKEN=$(docker exec -u git poc-gitea gitea admin user generate-access-token \
    --username ci --token-name "p3v3-test-$TS" \
    --scopes write:repository,write:issue 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
fi
if [ -z "$GITEA_TOKEN" ] || ! curl -s -o /dev/null "http://localhost:13000" 2>/dev/null; then
  echo "  (sections C/D sautées — Gitea du lab (poc-gitea:13000) ou token indisponible)"
else
  GH="http://localhost:13000"
  raw_manifest(){ curl -s -H "Authorization: token $GITEA_TOKEN" "$GH/api/v1/repos/ci/stoa-labs/raw/${1}/poc-control-plane-federation/clients/provisioned/applications/${2}.ansible.yml"; }
  pr_body(){ curl -s -H "Authorization: token $GITEA_TOKEN" "$GH/api/v1/repos/ci/stoa-labs/pulls?state=all&limit=50" \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
for pr in d:
    if pr.get('head',{}).get('ref')=='$1':
        print(pr.get('body','')); break
" 2>/dev/null; }

  echo "── C. non-régression du rendu (golden files, apps FIXES) ──"
  # Mêmes fixtures que test-app-request-v2.sh, pour des entrées MACHINE sans
  # aucun REQ_* optionnel — RÉGÉNÉRÉES le 2026-09-02 pour le jalon A1 (forme
  # multi-palier : claim { name } racine + valeur sous per_env.dev, description
  # sans palier, en-tête « MULTI-PALIER (A1) »). Elles prouvent que le rendu
  # machine n'a pas bougé d'un octet depuis. Provenance, régénération et
  # précondition : cf. l'en-tête de la section C de v2 — geste EXPLICITE,
  # jamais automatisé ici.
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
    [ -f "$GOLDEN_DIR/$golden" ] || { ko "$label : golden '$golden' absent"; return; }
    local out rc mani
    out=$(env GITEA_TOKEN="$GITEA_TOKEN" GIT_HOST="$GH" REQ_APP="$app" REQ_ENV=dev REQ_API=accounts-read \
      REQ_API_VER=1.0.0 REQ_CALLER="$caller" PROVISION_PLAN_INLINE=false "$@" bash "$S" 2>&1); rc=$?
    [ "$rc" -eq 0 ] || { ko "$label : run en échec — $(printf '%s' "$out" | tail -3)"; return; }
    mani=$(raw_manifest "$branch" "$app")
    [ -n "$mani" ] || { ko "$label : manifeste introuvable après le run"; return; }
    if diff -q "$GOLDEN_DIR/$golden" <(printf '%s\n' "$mani") >/dev/null; then
      ok "$label : manifeste identique au golden $golden (aucune dérive du contrat machine)"
    else
      ko "$label : le manifeste diverge du golden — RÉGRESSION du rendu machine"
      diff "$GOLDEN_DIR/$golden" <(printf '%s\n' "$mani")
    fi
  }
  nonreg_case "mode idp (voie OIG)"       "p3t4golden-idp" "oig-provisioner"  "golden-idp.ansible.yml"      REQ_CLIENT_ID="golden-client-id"
  nonreg_case "mode internal (voie CLI2)" "p3t4golden-int" "cli2-provisioner" "golden-internal.ansible.yml"

  # Le point sensible du multi-IP : UNE entrée doit rendre EXACTEMENT la même
  # chaîne qu'avant v3 — mêmes guillemets, même espacement. Une virgule ou une
  # espace en trop ici, et tous les manifestes déjà en Git divergent au prochain
  # passage.
  MONO="p3v3mono$TS"; MB="provision/${MONO}-dev"; CLEAN_BRANCHES+=("$MB")
  OUTM=$(GITEA_TOKEN="$GITEA_TOKEN" GIT_HOST="$GH" REQ_APP="$MONO" REQ_ENV=dev REQ_API=accounts-read \
    REQ_API_VER=1.0.0 REQ_CALLER=oig-provisioner REQ_CLIENT_ID="probe-mono-$TS" \
    REQ_IP_ALLOWLIST="10.77.5.1-10.77.5.9" PROVISION_PLAN_INLINE=false bash "$S" 2>&1)
  if [ $? -ne 0 ]; then
    ko "mono-IP : run en échec — $(printf '%s' "$OUTM" | tail -3)"
  elif raw_manifest "$MB" "$MONO" | grep -qF 'ip_allowlist: ["10.77.5.1-10.77.5.9"]'; then
    ok "mono-IP : rendu OCTET POUR OCTET identique à la forme mono-valeur d'avant v3"
  else
    ko "mono-IP : la forme a changé — $(raw_manifest "$MB" "$MONO" | grep ip_allowlist)"
  fi

  echo "── D. nominal v3 (IP multiples + clé backend) ──"
  APP="p3v3nom$TS"; BR="provision/${APP}-dev"; CLEAN_BRANCHES+=("$BR")
  KREF="deploy/banking-demo/apps/${APP}/dev/backend-key"
  # Doublon EXACT volontaire (2e et 5e entrée) + désordre d'espaces : on attend
  # 3 entrées, dans l'ORDRE DE SAISIE.
  OUTD=$(GITEA_TOKEN="$GITEA_TOKEN" GIT_HOST="$GH" REQ_APP="$APP" REQ_ENV=dev REQ_API=accounts-read \
    REQ_API_VER=1.0.0 REQ_CALLER=oig-provisioner REQ_CLIENT_ID="probe-nom-$TS" \
    REQ_IP_ALLOWLIST=$'  10.60.30.1-10.60.30.30 \n192.168.65.1\n\n10.0.0.7\n192.168.65.1\n' \
    REQ_BACKEND_KEY_REF="$KREF" REQ_BACKEND_KEY_FIELD="api_key" \
    PROVISION_PLAN_INLINE=false bash "$S" 2>&1)
  if [ $? -ne 0 ]; then
    ko "nominal v3 : run en échec — $(printf '%s' "$OUTD" | tail -5)"
  else
    MANI=$(raw_manifest "$BR" "$APP")
    CHECK=1
    printf '%s' "$MANI" | grep -qF 'ip_allowlist: ["10.60.30.1-10.60.30.30", "192.168.65.1", "10.0.0.7"]' \
      || { ko "nominal v3 : liste IP fausse (dédoublonnage/ordre/format) — $(printf '%s' "$MANI" | grep ip_allowlist)"; CHECK=0; }
    printf '%s' "$MANI" | grep -qF "backend_key_ref: \"$KREF\"" \
      || { ko "nominal v3 : backend_key_ref absent du manifeste"; CHECK=0; }
    printf '%s' "$MANI" | grep -qF 'backend_key_field: "api_key"' \
      || { ko "nominal v3 : backend_key_field absent du manifeste"; CHECK=0; }
    # La VALEUR d'une clé ne doit JAMAIS pouvoir arriver en Git : le formulaire
    # ne prend qu'un chemin, et le manifeste ne porte que ce chemin.
    printf '%s' "$MANI" | grep -q 'backend_key:' \
      && { ko "nominal v3 : le manifeste porte un champ de VALEUR de clé — Git ne doit porter que le chemin"; CHECK=0; }
    printf '%s' "$MANI" | grep -q '  enforce: \[\]' \
      || { ko "nominal v3 : enforce n'est plus [] — dérivation réintroduite"; CHECK=0; }
    [ "$CHECK" = 1 ] && ok "nominal v3 : 3 IP dédoublonnées dans l'ordre + backend_key_ref/field, enforce=[] intouché, aucune valeur de clé en Git"

    BODY=$(pr_body "$BR")
    BCHECK=1
    printf '%s' "$BODY" | grep -qF "10.60.30.1-10.60.30.30, 192.168.65.1, 10.0.0.7" \
      || { ko "PR : les 3 IP ne sont pas listées pour le valideur"; BCHECK=0; }
    printf '%s' "$BODY" | grep -qF "$KREF" \
      || { ko "PR : le chemin de la clé backend n'est pas visible du valideur"; BCHECK=0; }
    printf '%s' "$BODY" | grep -q "identifier token" \
      || { ko "PR : la ligne clé backend ne dit pas qu'il s'agit de l'identifier token"; BCHECK=0; }
    [ "$BCHECK" = 1 ] && ok "PR : corps portant les 3 IP et le chemin de la clé backend (sortante)"
  fi

  # Le piège de sens à ne PAS commettre : l'avertissement enforce parle des
  # identités ENTRANTES opposables. La clé backend est SORTANTE et le rôle
  # INTERDIT `token` dans enforce (BACKEND_KEY_ENFORCED) — l'y faire tomber
  # dirait au valideur l'exact contraire du vrai.
  KONLY="p3v3konly$TS"; KB="provision/${KONLY}-dev"; CLEAN_BRANCHES+=("$KB")
  OUTK=$(GITEA_TOKEN="$GITEA_TOKEN" GIT_HOST="$GH" REQ_APP="$KONLY" REQ_ENV=dev REQ_API=accounts-read \
    REQ_API_VER=1.0.0 REQ_CALLER=oig-provisioner REQ_CLIENT_ID="probe-konly-$TS" \
    REQ_BACKEND_KEY_REF="deploy/banking-demo/apps/${KONLY}/dev/backend-key" \
    PROVISION_PLAN_INLINE=false bash "$S" 2>&1)
  if [ $? -ne 0 ]; then
    ko "clé backend seule : run en échec — $(printf '%s' "$OUTK" | tail -5)"
  else
    KBODY=$(pr_body "$KB")
    if printf '%s' "$KBODY" | grep -q "cle backend" \
       && ! printf '%s' "$KBODY" | grep -q "ENFORCE NON MODIFIE"; then
      ok "clé backend SEULE : ligne présente, et AUCUN avertissement enforce (elle n'est pas une identité entrante)"
    else
      ko "clé backend SEULE : la clé sortante déclenche l'avertissement enforce (contresens) ou la ligne manque"
    fi
  fi
fi

echo
echo "═══════════════════════════════════════════════════"
printf 'RÉSULTAT : %d/%d\n' "$PASS" $((PASS + FAIL))
[ "$FAIL" -eq 0 ] || exit 1
