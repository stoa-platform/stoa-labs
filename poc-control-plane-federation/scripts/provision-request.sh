#!/usr/bin/env bash
# provision-request.sh — MAILLON 1 : une demande d'application (venue de l'appel
# OIG/CLI2 sur l'API provisioning) devient un ARTEFACT GIT + une MERGE REQUEST.
#
#   appel gateway (OIG/CLI2, authentifié+scope)
#     → webhook Jenkins → CE script :
#         1. rend le manifeste apim_ss_app (mode idp) depuis les champs de la demande
#         2. branche provision/<app>-<env>, commit, push sur le repo projet
#         3. ouvre une Pull Request (API Gitea) — le plan self-service se lance dessus
#
# Le pipeline aval (plan sur la MR, apply au merge, promo par env) est déjà couvert
# par ADR-075/076/079 : ce script ne fait QUE la porte d'entrée (demande → Git → MR).
#
# Aucune identité humaine ici (l'appel vient de la gateway) : le commit est signé
# par l'identité de SERVICE `ci` et la MR reste À VALIDER par un humain (4-yeux,
# ADR-078 §2 : un webhook ne porte aucun humain). Le secret Git (token) n'est
# JAMAIS loggé ni commité (URL push construite en mémoire, `set +x`).
#
# Entrées (variables d'env — mappées depuis le body du webhook par le GWT du job) :
#   REQ_APP        (req) nom de l'application demandée
#   REQ_ENV        (req) dev|rec|int|prod — pilote le nom de branche + la cible
#   REQ_CLIENT_ID  (req) le client OAuth2 de l'appelant (= valeur de claim azp)
#   REQ_API        (req) l'API que l'application consomme
#   REQ_API_VER    api version (défaut 1.0.0)
#   REQ_AUDIENCE   audience de la stratégie (défaut = REQ_API)
#   REQ_CALLER     azp de l'appelant (oig-provisioner|cli2-provisioner) — traçabilité
#   GITEA_TOKEN    (req) token de push/PR (scopes write:repository, write:issue)
#   GIT_REPO       full-name du repo projet (défaut ci/stoa-labs)
#   GIT_BASE       branche cible de la MR (défaut main)
#   GIT_HOST       base Gitea vue depuis l'agent (défaut http://gitea:3000)
#   MANIFEST_DIR   dossier des manifestes dans le repo
#                  (défaut poc-control-plane-federation/clients/provisioned/applications)
set -uo pipefail
set +x   # jamais de trace : le token ne doit pas fuiter

REQ_APP="${REQ_APP:?REQ_APP requis}"
REQ_ENV="${REQ_ENV:?REQ_ENV requis}"
REQ_API="${REQ_API:?REQ_API requis}"
REQ_API_VER="${REQ_API_VER:-1.0.0}"
REQ_AUDIENCE="${REQ_AUDIENCE:-$REQ_API}"
REQ_CALLER="${REQ_CALLER:-unknown}"
REQ_CLIENT_ID="${REQ_CLIENT_ID:-}"
TENANT="${TENANT:-banking-demo}"

# MODE = propriété de l'APPELANT, jamais du body (anti-spoof) : OIG provisionne
# des apps mode IDP (client OAuth2 externe déjà sur l'IdP → Git porte la claim) ;
# CLI2 provisionne des apps mode INTERNAL (la gateway wM EST l'AS local, elle
# génère le client → le pipeline l'écrit dans Vault par env). La correspondance
# caller→mode est une table (surchargeable), PAS un champ de la requête.
#   REQ_MODE explicite (test) > table par caller > défaut idp.
case "${REQ_MODE:-}" in
  idp|internal) MODE="$REQ_MODE";;
  *) case "$REQ_CALLER" in
       cli2*|*-internal) MODE="internal";;
       *)                 MODE="idp";;
     esac;;
esac
# En mode idp, la claim (= clientId de l'appelant) EST l'identité → obligatoire.
if [ "$MODE" = "idp" ] && [ -z "$REQ_CLIENT_ID" ]; then
  echo "REFUS: mode idp exige REQ_CLIENT_ID (la claim azp qui identifie l'app)" >&2; exit 2
fi
GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN requis}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
GIT_BASE="${GIT_BASE:-main}"
GIT_HOST="${GIT_HOST:-http://gitea:3000}"
MANIFEST_DIR="${MANIFEST_DIR:-poc-control-plane-federation/clients/provisioned/applications}"

# Garde-fous d'entrée : noms sûrs (pas d'injection dans un path/branche/YAML).
# REQ_CLIENT_ID est optionnel (internal) → validé seulement s'il est fourni.
for v in REQ_APP REQ_ENV REQ_API REQ_CLIENT_ID; do
  val="${!v}"
  [ -n "$val" ] || continue
  case "$val" in
    *[!A-Za-z0-9._-]*) echo "REFUS: $v='$val' contient un caractère non autorisé ([A-Za-z0-9._-])" >&2; exit 2;;
  esac
done
case "$REQ_ENV" in dev|rec|int|prod) ;; *) echo "REFUS: REQ_ENV='$REQ_ENV' (attendu dev|rec|int|prod)" >&2; exit 2;; esac

BRANCH="provision/${REQ_APP}-${REQ_ENV}"
REL_PATH="${MANIFEST_DIR}/${REQ_APP}.ansible.yml"
WORK="$(mktemp -d /tmp/provreq.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
# URL avec token EN MÉMOIRE seulement (jamais écrite dans le clone ni loggée).
PUSH_URL="http://ci:${GITEA_TOKEN}@${GIT_HOST#http://}/${GIT_REPO}.git"
API="${GIT_HOST}/api/v1"

echo "[1/4] clone ${GIT_REPO} (base ${GIT_BASE})"
git clone -q --depth 1 -b "$GIT_BASE" "http://${GIT_HOST#http://}/${GIT_REPO}.git" "$WORK/repo" 2>/dev/null \
  || git clone -q --depth 1 "http://${GIT_HOST#http://}/${GIT_REPO}.git" "$WORK/repo"
cd "$WORK/repo"
git config user.email "ci@bc.example"; git config user.name "provisioning (service ci)"
git checkout -q -B "$BRANCH"

echo "[2/4] rendu du manifeste ${REL_PATH} (mode ${MODE})"
mkdir -p "$(dirname "$REL_PATH")"
if [ "$MODE" = "internal" ]; then
  # CLI2 : la gateway wM EST l'AS local ('local'), elle génère le client — le
  # pipeline l'écrit dans Vault PAR ENV (tenant+app+env-scopé). Pas de claim, pas
  # de secret dans Git ; vault_sub généré au chemin conventionnel apps/<app>/<env>.
  cat > "$REL_PATH" <<YAML
---
# ${REQ_APP}.ansible.yml — GÉNÉRÉ par une demande de provisioning (maillon 1).
# Appelant : ${REQ_CALLER} (azp). Ne PAS éditer à la main : re-générer via la demande.
# Mode INTERNAL : la gateway wM est l'authorization server ; elle génère le client
# (client_id/secret), le pipeline le STOCKE dans Vault par env — jamais dans Git.
apim_ss_app:
  name: "${REQ_APP}"
  api: "${REQ_API}"
  api_version: "${REQ_API_VER}"
  description: "Provisioned via ${REQ_CALLER} — demande ${REQ_ENV} (internal)"
  contact_emails: []
  enforce: []
  auth:
    mode: "internal"
    audience: "${REQ_AUDIENCE}"
  per_env:
    ${REQ_ENV}: { auth: { vault_sub: "deploy/${TENANT}/apps/${REQ_APP}/${REQ_ENV}/oauth-client" } }
YAML
else
  # OIG : le client OAuth2 existe DÉJÀ côté IdP ; Git porte la CLAIM (azp) qui
  # identifie l'application sur la gateway. Aucun secret (il vit sur l'IdP).
  cat > "$REL_PATH" <<YAML
---
# ${REQ_APP}.ansible.yml — GÉNÉRÉ par une demande de provisioning (maillon 1).
# Appelant : ${REQ_CALLER} (azp). Ne PAS éditer à la main : re-générer via la demande.
# Mode IDP : le client OAuth2 existe côté IdP ; Git porte la CLAIM qui identifie l'app.
apim_ss_app:
  name: "${REQ_APP}"
  api: "${REQ_API}"
  api_version: "${REQ_API_VER}"
  description: "Provisioned via ${REQ_CALLER} — demande ${REQ_ENV} (idp)"
  contact_emails: []
  enforce: []
  auth:
    mode: "idp"
    server_alias: "KeycloakStoaLab"
    audience: "${REQ_AUDIENCE}"
    claim: { name: "azp", value: "${REQ_CLIENT_ID}" }
YAML
fi

if git diff --quiet -- "$REL_PATH" 2>/dev/null && git ls-files --error-unmatch "$REL_PATH" >/dev/null 2>&1; then
  echo "  (manifeste inchangé — demande idempotente)"
fi
git add "$REL_PATH"
if git diff --cached --quiet; then
  echo "[3/4] aucun changement à committer (demande déjà à jour)"
else
  git commit -q -m "provision(${REQ_ENV}): application ${REQ_APP} (demande ${REQ_CALLER})"
  echo "[3/4] push ${BRANCH}"
  # Branche machine-owned (provision/*) : push explicite forcé, sûr ici (le flux
  # est le seul écrivain). 2>err pour ne jamais laisser le token fuiter au log.
  if ! git push -q --force "$PUSH_URL" "HEAD:refs/heads/${BRANCH}" 2>"$WORK/pusherr"; then
    echo "ERREUR push (détail masqué — token)" >&2; grep -v "$GITEA_TOKEN" "$WORK/pusherr" >&2 || true; exit 1
  fi
fi

echo "[4/4] ouverture de la Pull Request ${BRANCH} → ${GIT_BASE}"
# Interaction PR en PYTHON3 (portable — le conteneur Jenkins n'a pas jq) : liste
# idempotente (filtre côté client sur head.ref), création sinon. Le token n'est
# PAS en argv (passé par env GITEA_TOKEN) ; aucun secret imprimé.
PR_OUT=$(REQ_APP="$REQ_APP" REQ_ENV="$REQ_ENV" REQ_API="$REQ_API" REQ_API_VER="$REQ_API_VER" \
  REQ_CLIENT_ID="$REQ_CLIENT_ID" REQ_CALLER="$REQ_CALLER" MODE="$MODE" BRANCH="$BRANCH" GIT_BASE="$GIT_BASE" \
  API="$API" GIT_REPO="$GIT_REPO" GITEA_TOKEN="$GITEA_TOKEN" python3 - <<'PY'
import os, json, urllib.request, urllib.error, sys
api, repo, tok = os.environ["API"], os.environ["GIT_REPO"], os.environ["GITEA_TOKEN"]
branch, base = os.environ["BRANCH"], os.environ["GIT_BASE"]
def req(method, url, data=None):
    body = json.dumps(data).encode() if data is not None else None
    r = urllib.request.Request(url, data=body, method=method,
        headers={"Authorization": "token "+tok, "Content-Type": "application/json"})
    with urllib.request.urlopen(r) as resp:
        return json.loads(resp.read() or "null")
# idempotence : PR ouverte existante pour CETTE branche ?
try:
    for pr in req("GET", f"{api}/repos/{repo}/pulls?state=open&limit=50") or []:
        if pr.get("head", {}).get("ref") == branch:
            print("EXIST", pr["number"]); sys.exit(0)
except urllib.error.HTTPError as e:
    print("ERR", e.code, e.read().decode()[:200]); sys.exit(1)
mode = os.environ.get("MODE", "idp")
title = f"provision({os.environ['REQ_ENV']}): {os.environ['REQ_APP']}"
ident = (f"- claim azp : {os.environ['REQ_CLIENT_ID']}" if mode == "idp"
         else "- client OAuth2 : genere par la gateway (mode internal), stocke dans Vault par env")
bodytxt = ("Demande de provisioning application.\n\n"
    f"- application : {os.environ['REQ_APP']}\n- environnement : {os.environ['REQ_ENV']}\n"
    f"- mode : {mode}\n- API consommee : {os.environ['REQ_API']} v{os.environ['REQ_API_VER']}\n"
    f"{ident}\n- demandeur (azp) : {os.environ['REQ_CALLER']}\n\n"
    "Plan self-service a lancer sur cette MR. Validation humaine requise (4-yeux) - "
    "un webhook ne porte aucun humain (ADR-078).")
try:
    pr = req("POST", f"{api}/repos/{repo}/pulls",
             {"title": title, "head": branch, "base": base, "body": bodytxt})
    print("CREATED", pr["number"])
except urllib.error.HTTPError as e:
    print("ERR", e.code, e.read().decode()[:200]); sys.exit(1)
PY
) || { echo "ERREUR: création PR échouée: ${PR_OUT}" >&2; exit 1; }
PR_NUM=$(printf '%s' "$PR_OUT" | awk '{print $2}')
case "$PR_OUT" in
  EXIST*)   echo "  PR déjà ouverte: #${PR_NUM}";;
  CREATED*) echo "  PR créée: #${PR_NUM}";;
  *)        echo "ERREUR: réponse inattendue: ${PR_OUT}" >&2; exit 1;;
esac
PR_URL="${GIT_HOST}/${GIT_REPO}/pulls/${PR_NUM}"
echo "PR_URL=${PR_URL}"
echo "OK: demande ${REQ_APP}/${REQ_ENV} → manifeste + MR"
