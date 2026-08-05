#!/usr/bin/env bash
# test-app-request-v2.sh — preuve X/X de la Task 4 (P3) : app-request v2
# (listes déroulantes + identité entrante) — scripts/provision-request.sh +
# ci/jenkins/app-request.job.xml.
#
# DEUX TERRAINS :
#   - Section A (gardes) et B (câblage placeholders) : HORS LIGNE — ni Gitea
#     ni Jenkins réels (bare repos locaux + faux Jenkins python, motif de
#     test-generate-choices.sh).
#   - Sections C/D/E (non-régression, nominal enrichi, garde REQ_TEAM) :
#     contre le VRAI Gitea du lab (poc-gitea, port 13000) — provision-request.sh
#     clone en http:// forcé, un bare repo local ne suffit pas ici. Objets
#     JETABLES (préfixe p3t4-<timestamp>), nettoyés en fin de run (branches
#     supprimées ; les PR restent, Gitea ne permet pas de les supprimer —
#     inoffensif, même motif que test-team-onboarding-chain.sh).
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

  OLD_SCRIPT="$TMP/provision-request.OLD.sh"
  git -C "$REPO" show HEAD:poc-control-plane-federation/scripts/provision-request.sh > "$OLD_SCRIPT" 2>/dev/null \
    || git -C "$REPO/.." show HEAD:poc-control-plane-federation/scripts/provision-request.sh > "$OLD_SCRIPT" 2>/dev/null
  chmod +x "$OLD_SCRIPT"

  echo "── C. non-régression (diff textuel vide, méthode palier 2 T6) ──"
  # NOTE : provision-request.sh clone TOUJOURS main à neuf (--depth 1) puis
  # force-push un commit UNIQUE sur la branche provision/* — chaque run
  # remplace donc l'historique de la branche (comportement PRÉEXISTANT, hors
  # périmètre Task 4). Le SHA du commit differe donc à chaque run même à
  # contenu identique (parent/horodatage) : la preuve porte sur le CONTENU du
  # manifeste rendu (capturé entre les deux runs), pas sur le SHA.
  nonreg_case(){
    local label="$1" app="$2" caller="$3"; shift 3
    local branch="provision/${app}-dev"
    CLEAN_BRANCHES+=("$branch")
    local out1 rc1
    out1=$(env GITEA_TOKEN="$GITEA_TOKEN" GIT_HOST="$GH" REQ_APP="$app" REQ_ENV=dev REQ_API=accounts-read \
      REQ_API_VER=1.0.0 REQ_CALLER="$caller" PROVISION_PLAN_INLINE=false "$@" bash "$OLD_SCRIPT" 2>&1)
    rc1=$?
    if [ "$rc1" -ne 0 ]; then ko "$label : run OLD en échec — $(printf '%s' "$out1" | tail -3)"; return; fi
    local mani1; mani1=$(raw_manifest "$branch" "$app")
    [ -n "$mani1" ] || { ko "$label : manifeste introuvable après le run OLD"; return; }
    local out2 rc2
    out2=$(env GITEA_TOKEN="$GITEA_TOKEN" GIT_HOST="$GH" REQ_APP="$app" REQ_ENV=dev REQ_API=accounts-read \
      REQ_API_VER=1.0.0 REQ_CALLER="$caller" PROVISION_PLAN_INLINE=false "$@" bash "$S" 2>&1)
    rc2=$?
    if [ "$rc2" -ne 0 ]; then ko "$label : run NEW en échec — $(printf '%s' "$out2" | tail -3)"; return; fi
    local mani2; mani2=$(raw_manifest "$branch" "$app")
    if [ "$mani1" = "$mani2" ]; then
      ok "$label : manifeste octet pour octet identique (OLD vs NEW, absent des REQ_* Task 4)"
    else
      ko "$label : le manifeste a changé — RÉGRESSION du rendu (absent des REQ_* Task 4)"
      diff <(printf '%s' "$mani1") <(printf '%s' "$mani2")
    fi
  }
  nonreg_case "mode idp (voie OIG)"      "p3t4nridp$TS" "oig-provisioner"  REQ_CLIENT_ID="probe-client-$TS"
  nonreg_case "mode internal (voie CLI2)" "p3t4nrint$TS" "cli2-provisioner"

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
    printf '%s' "$MANI" | grep -q 'enforce: \["ipAddressRange", "httpsCertificate"\]' || { ko "nominal : enforce incomplet"; CHECK=0; }
    printf '%s' "$MANI" | grep -q 'cert_rotation: "overlap"'                       || { ko "nominal : cert_rotation absent/faux"; CHECK=0; }
    printf '%s' "$MANI" | grep -q 'ip_allowlist: \["10.77.5.1-10.77.5.9"\]'        || { ko "nominal : ip_allowlist absent"; CHECK=0; }
    printf '%s' "$MANI" | grep -q "public_cert_ref: \"clients/provisioned/certs/${APP}.crt\"" || { ko "nominal : public_cert_ref absent/faux"; CHECK=0; }
    [ "$CHECK" = 1 ] && ok "nominal enrichi : manifeste porte team/enforce/cert_rotation/ip_allowlist/public_cert_ref"

    CERTFILE=$(raw_cert "$BR" "$APP")
    if [ "$CERTFILE" = "$CERT_PEM_CONTENT" ]; then
      ok "nominal enrichi : clients/provisioned/certs/${APP}.crt versionné, contenu identique au PEM soumis"
    else
      ko "nominal enrichi : fichier .crt absent ou contenu différent"
    fi

    BODY=$(pr_body "$BR")
    if printf '%s' "$BODY" | grep -q "banking-demo" && printf '%s' "$BODY" | grep -q "10.77.5.1-10.77.5.9"; then
      ok "nominal enrichi : la PR mentionne team/IP pour le valideur"
    else
      ko "nominal enrichi : la PR ne mentionne pas les champs d'identité entrante"
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
