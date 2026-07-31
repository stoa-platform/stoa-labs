#!/usr/bin/env bash
# setup-carto-job.sh — (re)crée le job Jenkins `carto` : collecte quotidienne de
# la carto des APIs et des consommateurs, puis archivage du résultat.
#
# Le job est un PIPELINE FROM SCM : il checkoute le dépôt qui porte le paquet
# `carto/` et exécute `poc-control-plane-federation/ci/Jenkinsfile.carto`.
# Même mécanique que ses voisins (setup-selfservice-job.sh,
# setup-provision-request-job.sh) : crumb CSRF → createItem / config.xml,
# idempotent, puis déclenchement d'un build et attente de son résultat.
#
# ─────────────────────────────────────────────────────────────────────────────
# PRÉREQUIS — GESTE EXPLOITANT, À FAIRE AVANT LE PREMIER BUILD
# ─────────────────────────────────────────────────────────────────────────────
# Ce job s'authentifie auprès de l'API Gateway par un CREDENTIAL JENKINS, et
# non par Vault : le client n'autorise pas l'authentification Vault par
# identité de pod, et un job éprouvé sur un chemin qu'il n'exécutera jamais ne
# prouverait rien. L'arbitrage (ce qu'on perd, ce qui l'atténue) est écrit en
# tête de ci/Jenkinsfile.carto.
#
# Le credential est posé par l'équipe d'exploitation :
#
#   Où          : Manage Jenkins → Credentials → System →
#                 Global credentials (unrestricted) → Add Credentials
#   Kind        : « Username with password »
#   Scope       : Global
#   ID          : carto-wm-gateway   (surchargeable : variable CREDS_ID de ce
#                 script, et paramètre CARTO_CREDENTIALS_ID du job)
#   Username    : le compte technique LECTURE SEULE de l'API d'administration
#                 de l'API Gateway (droit de faire GET /apis et
#                 GET /applications, rien d'autre)
#   Password    : le mot de passe de ce compte
#   Description : « Carto API — compte technique lecture seule de l'API Gateway »
#
# Ce script NE POSE PAS ce credential et ne doit pas le faire : aucun mot de
# passe ne transite par ce dépôt, qui est public. Il se contente de vérifier
# qu'il est là, et de refuser de déclencher un build s'il manque.
#
# Rotation (dette d'exploitation assumée du choix « identifiants dans
# Jenkins ») : quand le mot de passe du compte change côté gateway, il faut le
# mettre à jour dans ce credential, sinon les builds planifiés tombent en 401
# dès la nuit suivante. Le build le dit alors explicitement, avec le geste.
set -uo pipefail
cd "$(dirname "$0")/.."

JENKINS="${JENKINS:-http://localhost:18080}"
JOB="${JOB:-carto}"
JOB_XML="${JOB_XML:-ci/jenkins/carto.job.xml}"
CREDS_ID="${CREDS_ID:-carto-wm-gateway}"
# Coordonnées SCM : celles du fichier XML par défaut ; surchargeables ici sans
# éditer le XML (le dépôt de référence n'est pas le même selon le lab).
GIT_URL="${GIT_URL:-}"
BRANCH="${BRANCH:-}"
SCRIPT_PATH="${SCRIPT_PATH:-}"
# Le build attend la gateway jusqu'à 8 min (recyclage licence d'essai) : on lui
# laisse de la marge avant de déclarer l'attente perdue.
WAIT_S="${WAIT_S:-1200}"
# TRIGGER=0 : pose la config sans déclencher (utile pour un rejeu de nuit).
TRIGGER="${TRIGGER:-1}"

say()  { printf '\033[1;36m[carto-job]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[carto-job]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[carto-job]\033[0m %s\n' "$*"; exit 1; }

[ -f "$JOB_XML" ] || fail "définition de job absente : $JOB_XML"

XML="$(mktemp)"; CK="$(mktemp)"; trap 'rm -f "$XML" "$CK"' EXIT
cp "$JOB_XML" "$XML"
# Substitutions optionnelles — sed sur les seules balises concernées, pour ne
# pas réécrire un XML entier à la main dans deux endroits.
[ -n "$GIT_URL" ]     && sed -i.bak "s#<url>[^<]*</url>#<url>${GIT_URL}</url>#" "$XML"
[ -n "$BRANCH" ]      && sed -i.bak "s#<name>\*/[^<]*</name>#<name>*/${BRANCH}</name>#" "$XML"
[ -n "$SCRIPT_PATH" ] && sed -i.bak "s#<scriptPath>[^<]*</scriptPath>#<scriptPath>${SCRIPT_PATH}</scriptPath>#" "$XML"
rm -f "$XML.bak"

# --- crumb CSRF (motif des scripts voisins) ----------------------------------
CJ=$(curl -sf -c "$CK" "$JENKINS/crumbIssuer/api/json") || fail "crumbIssuer KO ($JENKINS joignable ?)"
F=$(printf '%s' "$CJ" | python3 -c 'import sys,json;print(json.load(sys.stdin)["crumbRequestField"])')
C=$(printf '%s' "$CJ" | python3 -c 'import sys,json;print(json.load(sys.stdin)["crumb"])')
# charset=utf-8 OBLIGATOIRE : sinon config.xml relit le corps en ISO-8859-1 → 500.
CT='Content-Type: application/xml; charset=utf-8'

# --- création / mise à jour du job (idempotent) ------------------------------
if curl -sf -b "$CK" "$JENKINS/job/$JOB/api/json" >/dev/null 2>&1; then
  say "job $JOB existe — configuration mise à jour"
  HC=$(curl -s -b "$CK" -X POST "$JENKINS/job/$JOB/config.xml" -H "$F: $C" \
    -H "$CT" --data-binary @"$XML" -o /dev/null -w '%{http_code}')
else
  say "création du job $JOB (Pipeline from SCM → ci/Jenkinsfile.carto)"
  HC=$(curl -s -b "$CK" -X POST "$JENKINS/createItem?name=$JOB" -H "$F: $C" \
    -H "$CT" --data-binary @"$XML" -o /dev/null -w '%{http_code}')
fi
[ "$HC" = 200 ] || fail "POST de la définition de job KO (HTTP $HC)"
say "définition posée — déclenchement planifié quotidien (voir le champ TimerTrigger)"

# --- le credential exploitant est-il là ? ------------------------------------
# On le vérifie ICI plutôt que de laisser le build le découvrir : un échec de
# build pour un prérequis non posé coûte 3 minutes d'attente d'agent et se lit
# moins bien qu'une phrase.
if curl -sf -b "$CK" "$JENKINS/credentials/store/system/domain/_/credential/$CREDS_ID/api/json" >/dev/null 2>&1; then
  say "credential « $CREDS_ID » présent dans Jenkins"
else
  warn "credential « $CREDS_ID » ABSENT de Jenkins."
  warn "  Geste exploitant : Manage Jenkins → Credentials → System → Global"
  warn "  credentials → Add Credentials ; Kind « Username with password », Scope"
  warn "  Global, ID « $CREDS_ID », Username = compte technique LECTURE SEULE de"
  warn "  l'API d'administration de l'API Gateway, Password = son mot de passe."
  warn "  La définition du job est posée ; le build échouera tant que le"
  warn "  credential n'est pas là — en le disant, avec ce même geste."
  [ "$TRIGGER" = 1 ] && fail "déclenchement refusé : prérequis non posé (relancer ce script après)"
  exit 0
fi

[ "$TRIGGER" = 1 ] || { say "TRIGGER=0 — aucun build déclenché"; exit 0; }

# --- déclenchement + attente du résultat -------------------------------------
N=$(curl -sf "$JENKINS/job/$JOB/api/json" | python3 -c 'import sys,json;print(json.load(sys.stdin)["nextBuildNumber"])')
say "déclenchement du build #$N"
# Job paramétré → buildWithParameters (POST /build renvoie 400).
HC=$(curl -s -b "$CK" -X POST "$JENKINS/job/$JOB/buildWithParameters" -H "$F: $C" -o /dev/null -w '%{http_code}')
[ "$HC" = 201 ] || fail "déclenchement KO (HTTP $HC)"

R=""
DEADLINE=$(( $(date +%s) + WAIT_S ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  R=$(curl -sf "$JENKINS/job/$JOB/$N/api/json" 2>/dev/null |
    python3 -c 'import sys,json;b=json.load(sys.stdin);print(b.get("result") or "")' 2>/dev/null || true)
  [ -n "$R" ] && break
  sleep 5
done

CONSOLE="$JENKINS/job/$JOB/$N/console"
case "$R" in
  SUCCESS)
    say "build #$N : SUCCESS"
    curl -sf "$JENKINS/job/$JOB/$N/api/json" |
      python3 -c 'import sys,json;a=json.load(sys.stdin).get("artifacts",[]);print("  artefacts archivés : " + (", ".join(x["relativePath"] for x in a) or "AUCUN"))'
    say "carto : $JENKINS/job/$JOB/$N/artifact/carto-out/"
    ;;
  "")
    fail "build #$N : aucun résultat après ${WAIT_S}s — $CONSOLE"
    ;;
  *)
    # Un échec n'est pas forcément un défaut du job : gateway en cours de
    # recyclage, credential refusé, ou collecte réellement dégradée. Le journal
    # du build nomme lequel des trois, avec le geste correspondant.
    fail "build #$N : $R — lire $CONSOLE (la cause exacte et le geste y sont écrits)"
    ;;
esac
