#!/usr/bin/env bash
# provision-plan.sh — FERMETURE DE BOUCLE : une PR de provisioning ouverte
# déclenche le PLAN self-service sur la branche, et le RÉSULTAT est posté en
# commentaire sur la PR (visible avant la validation humaine).
#
#   PR ouverte (maillon 1) → webhook Gitea → job Jenkins → CE script :
#     1. checkout la branche de la PR
#     2. localise le manifeste ajouté (git diff vs main)
#     3. PLAN lecture seule : manifeste valide (name/api) + ansible --syntax-check
#        (identité de JOB, AUCUNE mutation, AUCUN secret — ADR-078 §2)
#     4. poste le verdict (✅/❌) en commentaire sur la PR (API Gitea)
#
# L'apply reste séparé (build nominatif au merge) : ici on ne fait que DONNER À
# VOIR au valideur que la demande passe le plan. Token jamais loggé (set +x).
#
# Entrées (env — mappées depuis le payload webhook Gitea par le GWT du job) :
#   PR_BRANCH   (req) ref de la branche de la PR (ex. provision/credit-scoring-dev)
#   PR_NUMBER   (req) numéro de la PR (pour le commentaire)
#   GITEA_TOKEN (req) token (scopes write:issue pour commenter)
#   GIT_REPO    full-name (défaut ci/stoa-labs)
#   GIT_BASE    branche cible (défaut main) — base du diff
#   GIT_HOST    base Gitea vue de l'agent (défaut http://gitea:3000)
#   MANIFEST_DIR dossier des manifestes (défaut poc-control-plane-federation/clients/provisioned/applications)
set -uo pipefail
set +x

PR_BRANCH="${PR_BRANCH:?PR_BRANCH requis}"
PR_NUMBER="${PR_NUMBER:?PR_NUMBER requis}"
GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN requis}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
GIT_BASE="${GIT_BASE:-main}"
GIT_HOST="${GIT_HOST:-http://gitea:3000}"
MANIFEST_DIR="${MANIFEST_DIR:-poc-control-plane-federation/clients/provisioned/applications}"
INVENTORY="${INVENTORY:-ansible/inventory.lab.ini}"

case "$PR_BRANCH" in provision/*) ;; *) echo "IGNORE: branche '$PR_BRANCH' hors provision/* — pas une demande" >&2; exit 0;; esac
WORK="$(mktemp -d /tmp/provplan.XXXXXX)"; trap 'rm -rf "$WORK"' EXIT
API="${GIT_HOST}/api/v1"

echo "[1/4] checkout ${PR_BRANCH}"
git clone -q "http://${GIT_HOST#http://}/${GIT_REPO}.git" "$WORK/repo"
cd "$WORK/repo"
git checkout -q "$PR_BRANCH"

echo "[2/4] localisation du manifeste (diff vs ${GIT_BASE})"
MAN=$(git diff --name-only "origin/${GIT_BASE}...HEAD" -- "${MANIFEST_DIR}/*.ansible.yml" 2>/dev/null | head -1)
[ -n "$MAN" ] || MAN=$(git diff --name-only "origin/${GIT_BASE}...HEAD" 2>/dev/null | grep -E "^${MANIFEST_DIR}/.*\.ansible\.yml$" | head -1)
if [ -z "$MAN" ]; then echo "IGNORE: aucun manifeste ajouté sous ${MANIFEST_DIR}" >&2; exit 0; fi
echo "  manifeste : $MAN"
# env = suffixe de la branche provision/<app>-<env>
ENVV="${PR_BRANCH##*-}"; case "$ENVV" in dev|rec|int|prod) ;; *) ENVV="";; esac

echo "[3/4] PLAN (lecture seule) sur $MAN"
PLAN_LOG="$WORK/plan.log"; VERDICT="ok"
{
  echo "== manifeste présent + champs requis =="
  test -f "$MAN" || { echo "manifeste introuvable"; exit 1; }
  grep -qE '^[[:space:]]*name:' "$MAN" && grep -qE '^[[:space:]]*api:' "$MAN" \
    || { echo "manifeste incomplet (name/api requis)"; exit 1; }
  grep -qE '^[[:space:]]*mode:' "$MAN" && echo "  mode: $(grep -oE 'mode: *"[a-z]+"' "$MAN" | head -1)"
  echo "== ansible --syntax-check (aucune mutation) =="
  cd poc-control-plane-federation
  ansible-playbook -i "$INVENTORY" ansible/selfservice-app.yml --syntax-check \
    -e "apim_ss_manifest=$(cd "$WORK/repo" && pwd)/$MAN" ${ENVV:+-e apim_ss_env="$ENVV"}
} >"$PLAN_LOG" 2>&1 || VERDICT="fail"
sed -n '1,40p' "$PLAN_LOG"

echo "[4/4] commentaire sur la PR #${PR_NUMBER} (verdict ${VERDICT})"
# Corps du commentaire construit en python3 (jq absent du conteneur Jenkins).
PR_NUMBER="$PR_NUMBER" GIT_REPO="$GIT_REPO" API="$API" GITEA_TOKEN="$GITEA_TOKEN" GIT_HOST="$GIT_HOST" \
PR_BRANCH="$PR_BRANCH" VERDICT="$VERDICT" MAN="$MAN" PLAN_LOG="$PLAN_LOG" python3 - <<'PY'
import os, json, urllib.request
verdict = os.environ["VERDICT"]
api, repo, tok = os.environ["API"], os.environ["GIT_REPO"], os.environ["GITEA_TOKEN"]
prn = os.environ["PR_NUMBER"]
MARKER = "<!-- provision-plan -->"   # marqueur pour retrouver LE commentaire de plan
head = "✅ **Plan self-service OK**" if verdict == "ok" else "❌ **Plan self-service EN ÉCHEC**"
log = open(os.environ["PLAN_LOG"]).read()[-1500:]
man = os.environ["MAN"]
man_url = f"{os.environ['GIT_HOST']}/{repo}/src/branch/{os.environ['PR_BRANCH']}/{man}"
body = (f"{MARKER}\n{head} — automatique (webhook PR).\n\n"
        f"- manifeste : [`{man}`]({man_url})\n"
        f"- nature : lecture seule (aucune mutation, aucun secret) — ADR-078 §2\n\n"
        "<details><summary>sortie du plan</summary>\n\n```\n" + log + "\n```\n</details>\n\n"
        + ("Prêt pour validation humaine (4-yeux) puis apply nominatif au merge."
           if verdict == "ok" else "**Corriger la demande avant validation.**"))
def call(method, url, data=None):
    r = urllib.request.Request(url, data=(json.dumps(data).encode() if data else None), method=method,
        headers={"Authorization": "token "+tok, "Content-Type": "application/json"})
    with urllib.request.urlopen(r) as resp: return json.loads(resp.read() or "null")
try:
    # commentaire de plan existant (marqueur) ? → PATCH (idempotent) ; sinon POST.
    existing = None
    for c in call("GET", f"{api}/repos/{repo}/issues/{prn}/comments") or []:
        if MARKER in (c.get("body") or ""): existing = c["id"]; break
    if existing:
        call("PATCH", f"{api}/repos/{repo}/issues/comments/{existing}", {"body": body})
        print("  commentaire de plan mis à jour: #" + str(existing))
    else:
        c = call("POST", f"{api}/repos/{repo}/issues/{prn}/comments", {"body": body})
        print("  commentaire de plan posté: #" + str(c["id"]))
except Exception as e:
    print("  ERREUR commentaire:", e); raise SystemExit(1)
PY

[ "$VERDICT" = "ok" ] && echo "OK: plan vert, PR #${PR_NUMBER} commentée" || { echo "PLAN EN ÉCHEC (PR commentée)"; exit 1; }
