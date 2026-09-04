#!/usr/bin/env bash
# api-request.sh — moteur du formulaire « publier une API » (palier 3, la
# porte du PRODUCTEUR — pendant de team-request.sh, palier 2). MODÈLE
# STRUCTUREL repris tel quel : gardes nommées avant tout geste Git, clone,
# branche, push par GIT_CONFIG_COUNT/KEY_0/VALUE_0 (jamais de token en
# URL/argv), PR par heredoc python, plan commenté sur la PR.
#
#   formulaire Jenkins → CE script :
#     1. gardes d'entrée (AVANT tout geste Git — un refus ne laisse rien derrière)
#     2. team -> repo, lu dans providers.<env>.yml sur GITEA MAIN (jamais le
#        worktree local — même discipline que scripts/lib/generate-choices.sh)
#     3. clone du dépôt de l'ÉQUIPE (ADR-076), écrit apis/<name>.publish.yml
#        (gabarit gateways/templates/publish.yml.tmpl) + apis/<name>.openapi.yaml
#     4. branche api/<name>-<version>, commit (identité de service ci), push, PR
#     5. PLAN hors ligne (manifest-guard + team-name via
#        ansible/test-publish-guards.yml, PUIS ansible/publish-api.yml
#        --syntax-check) → commentaire ✅/❌ sur la PR
#
# La décision reste le MERGE (ADR-081) : ce script n'importe rien sur la
# gateway, ne touche ni Vault ni la publication réelle — celle-ci vit dans le
# pipeline post-merge (ci/Jenkinsfile.publish-api / la chaîne team-publish à
# venir).
#
# CE QUE LE MANIFESTE NE PORTE JAMAIS : la plomberie IdP (alias_name, issuer,
# jwks_uri par env) — valeurs PLATEFORME fixées par le gabarit
# gateways/templates/publish.yml.tmpl, jamais saisies au formulaire. Seul
# INBOUND_MODE revient à l'équipe — jwt uniquement pour l'instant (fix
# round 1, revue : oauth2 REFUSÉ, INBOUND_OAUTH2_NON_SUPPORTE — ce
# formulaire ne collecte pas audience/scope/client_id qu'oauth2 exige
# fail-closed à l'apply, cf. le commentaire de la garde plus bas).
#
# Entrées (env — mappées depuis les paramètres du job) :
#   ACTION        (req) create | new-version
#   TEAM          (req) équipe propriétaire — DOIT être déjà déclarée et
#                       porter un dépôt (providers.<env>.yml, repo: non vide)
#   API_NAME      (req) nom de l'API — ^[a-z0-9][a-z0-9-]{1,30}$
#   API_VERSION         version initiale — REQUISE si ACTION=create
#   API_BASE            "nom@version" d'une API existante (liste) — REQUISE
#                       si ACTION=new-version ; le nom doit concorder avec API_NAME
#   NEW_VERSION         nouvelle version — REQUISE si ACTION=new-version,
#                       différente de la version de base
#   OPENAPI_SPEC  (req) contrat OpenAPI/Swagger collé (YAML ou JSON)
#   INBOUND_MODE  (req) jwt uniquement (oauth2 refusé — INBOUND_OAUTH2_NON_SUPPORTE)
#   FORGE_SECRET   (req) token du service ci (write:repository, write:issue)
#   GIT_REPO           dépôt PLATEFORME (défaut ci/stoa-labs) — porte
#                       ansible/providers.<env>.yml ET les gardes hors ligne
#   GIT_HOST            défaut http://gitea:3000
#   GIT_WEB_HOST         URL Gitea vue par l'HUMAIN (liens des commentaires)
#   (ENVN n'est PLUS une entrée : G4/ADR-082 le SCELLE sur l'env d'authoring,
#    voir plus bas. Il ne désigne que l'env dont providers.<env>.yml donne le
#    dépôt d'équipe — sans rapport avec l'env de PUBLICATION, résolu plus tard
#    par per_env au moment de l'apply réel.)
set -uo pipefail
set +x   # jamais de trace : le token ne doit pas fuiter
cd "$(dirname "$0")/.." || exit 1
REPO_ROOT="$(pwd)"

# Auto-localisation par BASH_SOURCE quand le fichier vit dans son arbre ; repli
# sur le cwd (fixé par le `cd` ci-dessus) pour les invocations où le dirname ne
# contient pas lib/ — même motif que setup-vault-paliers.sh:26-38.
_AR_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/deploy-pin.sh"
[ -f "$_AR_LIB" ] || _AR_LIB="scripts/lib/deploy-pin.sh"
# `set -e` n'est pas actif ici : sans garde explicite, un fichier manquant
# laisserait bash continuer jusqu'à un « unbound variable » sur la constante.
# shellcheck source=scripts/lib/deploy-pin.sh
. "$_AR_LIB" || { echo "ERREUR: $_AR_LIB introuvable ou illisible" >&2; exit 1; }

ACTION="${ACTION:?ACTION requis (create|new-version)}"
TEAM="${TEAM:?TEAM requis}"
API_NAME="${API_NAME:?API_NAME requis}"
API_VERSION="${API_VERSION:-}"
API_BASE="${API_BASE:-}"
NEW_VERSION="${NEW_VERSION:-}"
OPENAPI_SPEC="${OPENAPI_SPEC:?OPENAPI_SPEC requis}"
INBOUND_MODE="${INBOUND_MODE:?INBOUND_MODE requis (jwt uniquement — oauth2 refusé)}"
# Le secret de la forge porte un nom NEUTRE (2026-09-04) : un gestionnaire
# d'identite rend un jeton OU un couple, et les deux occupent la meme place.
FORGE_SECRET="${FORGE_SECRET:-${GITEA_TOKEN:-}}"
[ -n "$FORGE_SECRET" ] || { echo "REFUS: SECRET_FORGE_REQUIS : ni FORGE_SECRET ni son alias GITEA_TOKEN — le secret de la forge (jeton, ou mot de passe d'un couple avec FORGE_USER)" >&2; exit 2; }
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
GIT_HOST="${GIT_HOST:-http://gitea:3000}"
GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"
# G4 (ADR-082) : ENVN est SCELLÉ sur l'env d'authoring — affectation sèche
# depuis la constante de lib, jamais "${ENVN:-dev}" : les variables d'un job
# Jenkins atterrissent dans l'environnement du process (fait mesuré, même
# raison que deploy-pin.sh:29-37). Demander une API est un geste d'AUTHORING
# par conception (ADR-079) ; au-delà, c'est la promotion (marqueurs G3, verbe
# archive G5) — et son autorité est la rétention de credential, pas une
# variable.
ENVN="$DEPLOY_PIN_AUTHORING_ENV"

fail(){ echo "ERREUR: $*" >&2; exit 1; }

# ── 1. gardes d'entrée — AVANT tout geste Git ────────────────────────────────
case "$ACTION" in
  create|new-version) ;;
  *) fail "ACTION_INVALIDE : '$ACTION' — attendu create|new-version";;
esac

# Regex du rôle (même classe que TEAM — team-request.sh) : refus de tout
# caractère hors classe D'ABORD (\n compris — bash/grep matchent par LIGNE,
# leçon \Z du palier 1), PUIS la forme.
case "$TEAM" in *[!a-z0-9-]*) fail "TEAM_NAME_INVALID : '$TEAM' — ^[a-z0-9][a-z0-9-]{1,30}\$ requis";; esac
printf '%s' "$TEAM" | grep -Eq '^[a-z0-9][a-z0-9-]{1,30}$' \
  || fail "TEAM_NAME_INVALID : '$TEAM' — ^[a-z0-9][a-z0-9-]{1,30}\$ requis"

case "$API_NAME" in *[!a-z0-9-]*) fail "API_NAME_INVALID : '$API_NAME' — ^[a-z0-9][a-z0-9-]{1,30}\$ requis";; esac
printf '%s' "$API_NAME" | grep -Eq '^[a-z0-9][a-z0-9-]{1,30}$' \
  || fail "API_NAME_INVALID : '$API_NAME' — ^[a-z0-9][a-z0-9-]{1,30}\$ requis"

# oauth2 REFUSÉ ICI, pas une simple valeur non encore branchée (fix round 1,
# revue) : le gabarit ne pose jamais inbound.audience/scope/client_id, que
# roles/apim_publish_api/tasks/inbound.yml:56-63 EXIGE fail-closed en mode
# oauth2 — mais AUCUNE des deux gardes du PLAN (manifest-guard, team-name)
# ne lit `inbound` : une PR oauth2 recevrait donc "✅ PLAN OK" pour un
# manifeste qui cassera à l'apply, la classe exacte du bug `contract:` déjà
# corrigé dans ce fichier. Mesuré : le seul exemple réel d'oauth2 du dépôt
# (gateways/webmethods/provisioning/provisioning.publish.yml) porte audience/
# scope/client_id comme des valeurs PAR API/PAR CONSOMMATEUR (l'audience et
# le client appelant changent avec chaque API) — CONTRAIREMENT à issuer/
# jwks_uri/alias_name qui, eux, sont réellement invariants plateforme. Ces
# trois champs ne peuvent donc PAS être fixés dans le gabarit comme le sont
# issuer/jwks — les figer avec une valeur bidon serait pire qu'un refus (une
# API qui semblerait protégée sans l'être). Ce formulaire ne les collecte pas
# (absents du brief) : oauth2 reste refusé tant qu'ils n'ont pas leur propre
# champ — à trancher par T6/T7 (le job XML retire déjà le choix oauth2).
case "$INBOUND_MODE" in
  jwt) ;;
  oauth2) fail "INBOUND_OAUTH2_NON_SUPPORTE : oauth2 exige inbound.audience/scope/client_id (roles/apim_publish_api/tasks/inbound.yml), non collectés par ce formulaire — seul jwt est supporté pour l'instant (cf. commentaire du script)";;
  *) fail "INBOUND_MODE_INVALIDE : '$INBOUND_MODE' — attendu jwt";;
esac

VERSION_RE='^[0-9]+\.[0-9]+(\.[0-9]+)?$'

if [ "$ACTION" = "create" ]; then
  [ -n "$API_VERSION" ] || fail "API_VERSION_REQUIS : ACTION=create exige API_VERSION"
  printf '%s' "$API_VERSION" | grep -Eq "$VERSION_RE" \
    || fail "API_VERSION_INVALIDE : '$API_VERSION' — attendu X.Y ou X.Y.Z"
  EFFECTIVE_VERSION="$API_VERSION"
  BASE_NAME=""; BASE_VERSION=""
else
  [ -n "$API_BASE" ] || fail "API_BASE_REQUIS : ACTION=new-version exige API_BASE (liste des APIs existantes)"
  case "$API_BASE" in
    *@*) BASE_NAME="${API_BASE%%@*}"; BASE_VERSION="${API_BASE#*@}";;
    *)   fail "API_BASE_FORMAT_INVALIDE : '$API_BASE' — attendu nom@version (liste déroulante générée)";;
  esac
  [ -n "$BASE_NAME" ] && [ -n "$BASE_VERSION" ] \
    || fail "API_BASE_FORMAT_INVALIDE : '$API_BASE' — nom ou version vide"
  # Cohérence nom (brief) : le nom saisi/attendu (API_NAME) DOIT concorder
  # avec le nom porté par le choix de la liste — un API_NAME retapé à la main
  # divergent du choix sélectionné est un signal d'erreur humaine (mauvais
  # copier-coller), refusé plutôt que silencieusement ignoré.
  [ "$API_NAME" = "$BASE_NAME" ] \
    || fail "API_NAME_MISMATCH : API_NAME='$API_NAME' ne concorde pas avec le nom de API_BASE='$API_BASE' (attendu '$BASE_NAME')"
  [ -n "$NEW_VERSION" ] || fail "NEW_VERSION_REQUIS : ACTION=new-version exige NEW_VERSION"
  printf '%s' "$NEW_VERSION" | grep -Eq "$VERSION_RE" \
    || fail "NEW_VERSION_INVALIDE : '$NEW_VERSION' — attendu X.Y ou X.Y.Z"
  [ "$NEW_VERSION" != "$BASE_VERSION" ] \
    || fail "NEW_VERSION_IDENTIQUE : NEW_VERSION='$NEW_VERSION' égale la version de base — rien à publier"
  EFFECTIVE_VERSION="$NEW_VERSION"
fi

# Spec OpenAPI : parseable (YAML ou JSON) ET porte 'openapi' ou 'swagger' au
# top-level. Refus, pas de repli silencieux sur un contrat vide/à moitié
# écrit — même discipline que team-request.sh pour DESCRIPTION/REPO. (Un
# OPENAPI_SPEC vide est déjà refusé plus haut par ${OPENAPI_SPEC:?} — rien à
# revérifier ici.)
SPEC_ERR=$(OPENAPI_SPEC="$OPENAPI_SPEC" python3 - <<'PY' 2>&1
import os, sys, json
raw = os.environ.get("OPENAPI_SPEC", "")
doc = None
try:
    import yaml
    doc = yaml.safe_load(raw)
except Exception:
    try:
        doc = json.loads(raw)
    except Exception as e:
        print(f"parse en echec (ni YAML ni JSON) : {e}")
        sys.exit(1)
if not isinstance(doc, dict) or not (("openapi" in doc) or ("swagger" in doc)):
    print("ni cle 'openapi' ni 'swagger' au top-level")
    sys.exit(1)
PY
) || fail "SPEC_INVALIDE : ${SPEC_ERR:-parse en échec}"

# ── 2. team -> repo, depuis providers.<env>.yml sur GITEA MAIN ──────────────
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
echo "[1/5] clone ${GIT_REPO}@main (lecture team -> repo)"
git clone -q --depth 1 -b main "${GIT_HOST}/${GIT_REPO}.git" "$WORK/platform" \
  || fail "clone ${GIT_REPO}@main (résolution team -> repo)"
PROV="$WORK/platform/poc-control-plane-federation/ansible/providers.${ENVN}.yml"
[ -f "$PROV" ] || fail "PROVIDERS_MISSING : ansible/providers.${ENVN}.yml absent sur main"

REPO_OUT=$(TEAM="$TEAM" PROV="$PROV" python3 - <<'PY'
import os, sys, yaml
d = yaml.safe_load(open(os.environ["PROV"])) or {}
e = next((p for p in (d.get("providers") or []) if p.get("team") == os.environ["TEAM"]), None)
if e is None:
    sys.exit("ABSENT")
print("REPO=" + (e.get("repo") or ""))
PY
)
RC=$?
if [ "$RC" -ne 0 ]; then
  fail "TEAM_NOT_DECLARED : '${TEAM}' absente de providers.${ENVN}.yml (sur main)"
fi
case "$REPO_OUT" in
  REPO=*) REPO_FULL="${REPO_OUT#REPO=}";;
  *) fail "PARSE_PROVIDERS : sortie inattendue de l'extraction repo pour ${TEAM} — ${REPO_OUT}";;
esac
[ -n "$REPO_FULL" ] || fail "REPO_MANQUANT : onboarder d'abord un dépôt pour cette équipe (providers.${ENVN}.yml, champ repo de '${TEAM}' vide)"
echo "  équipe '${TEAM}' -> dépôt ${REPO_FULL}"

# ── 2b. collision cross-team (mode create uniquement) ────────────────────────
# L'apply aval (roles/apim_publish_api/tasks/main.yml:61-67) matche name+version
# GLOBALEMENT sur la gateway, SANS filtre équipe, puis réassigne l'équipe au
# dernier publish (team.yml) — une équipe B peut donc CAPTURER une API
# homonyme d'une équipe A via un simple create fusionné par SES PROPRES
# approbateurs, sans jamais toucher au dépôt de A. `API_ALREADY_EXISTS`
# ci-dessous ne voit que NOTRE dépôt — insuffisant. Le refus se joue ICI,
# AVANT tout clone/écriture sur notre propre dépôt, sur l'UNION que
# scripts/lib/generate-choices.sh calcule déjà pour les listes (dépôt
# plateforme clients/ + TOUS les dépôts d'équipe déclarés, pas seulement le
# nôtre) — reconstruite ici avec le NOM du propriétaire (generate_choices_apis
# ne le porte pas, son contrat est une liste plate name@version).
if [ "$ACTION" = "create" ]; then
  echo "[1b/5] collision cross-team : '${API_NAME}' ailleurs sur la plateforme ?"
  COLLISION_OWNER=""
  # Balayage du dépôt PLATEFORME : `clients/` ET `gateways/`. `gateways/` était
  # l'angle mort — c'est là que vivent les APIs de la plateforme elle-même
  # (gateways/webmethods/provisioning/provisioning.publish.yml), invisibles à
  # cette porte jusqu'à la revue finale : une équipe pouvait demander
  # `API_NAME=provisioning` et, à l'apply, se voir réassigner l'API plateforme.
  # Le refus AUTORITATIF est côté rôle (API_OWNER_MISMATCH, qui lit la gateway
  # VIVE) ; ceci le double au plus tôt, sur ce que Git connaît.
  #
  # Le nom cherché est celui DÉCLARÉ dans le manifeste (`apim_api.name`), pas le
  # nom de fichier : les deux peuvent diverger, et c'est le champ qui décide de
  # l'objet créé sur la gateway.
  PLATFORM_ROOT="$WORK/platform/poc-control-plane-federation"
  for SCAN_DIR in clients gateways; do
    [ -d "$PLATFORM_ROOT/$SCAN_DIR" ] || continue
    [ -n "$COLLISION_OWNER" ] && break
    COLLISION_FILE=$(API_NAME="$API_NAME" ROOT="$PLATFORM_ROOT/$SCAN_DIR" python3 - <<'PY'
import os, sys, yaml
want = os.environ["API_NAME"]
for dirpath, _, files in os.walk(os.environ["ROOT"]):
    for f in files:
        if not f.endswith(".publish.yml"):
            continue
        p = os.path.join(dirpath, f)
        try:
            d = yaml.safe_load(open(p)) or {}
        except Exception:
            continue          # un manifeste illisible n'est pas une collision
        if ((d.get("apim_api") or {}).get("name") or "") == want:
            print(p)
            sys.exit(0)
PY
)
    [ -n "$COLLISION_FILE" ] \
      && COLLISION_OWNER="dépôt plateforme (${COLLISION_FILE#"$PLATFORM_ROOT/"})"
  done
  if [ -z "$COLLISION_OWNER" ]; then
    ALL_PROVIDERS=$(python3 -c "
import yaml
d = yaml.safe_load(open('${PROV}')) or {}
for p in (d.get('providers') or []):
    r = p.get('repo')
    if r:
        print(p.get('team','') + '\t' + r)
" 2>/dev/null)
    while IFS=$'\t' read -r OTHER_TEAM OTHER_REPO; do
      [ -n "$OTHER_REPO" ] || continue
      [ "$OTHER_TEAM" = "$TEAM" ] && continue   # notre propre dépôt : couvert par API_ALREADY_EXISTS plus bas
      OW=$(mktemp -d)
      if git clone -q --depth 1 -b main "${GIT_HOST}/${OTHER_REPO}.git" "$OW" 2>"$OW.err"; then
        [ -f "$OW/apis/${API_NAME}.publish.yml" ] && COLLISION_OWNER="équipe '${OTHER_TEAM}' (${OTHER_REPO})"
      else
        # Un clone qui échoue n'est PAS une absence de collision : c'est une
        # ABSENCE DE RÉPONSE. Le `2>/dev/null` sans `else` d'avant l'avalait, et
        # le balayage rendait « aucune collision » avec la même assurance que
        # s'il avait vraiment regardé. On ne bloque pas la demande là-dessus
        # (le rôle reste autoritatif à l'apply), mais ça se voit.
        echo "⚠ COLLISION_SCAN_INCOMPLET : dépôt '${OTHER_REPO}' (équipe '${OTHER_TEAM}') injoignable — non balayé : $(tail -1 "$OW.err" 2>/dev/null)" >&2
      fi
      rm -rf "$OW" "$OW.err"
      [ -n "$COLLISION_OWNER" ] && break
    done <<<"$ALL_PROVIDERS"
  fi
  [ -z "$COLLISION_OWNER" ] \
    || fail "API_NAME_COLLISION : '${API_NAME}' est déjà publiée par ${COLLISION_OWNER} — choisir un autre nom, ou coordonner avec cette équipe (l'apply aval matche name+version GLOBALEMENT ; il REFUSE désormais de toucher une API qui n'appartient pas à l'équipe demandeuse — API_OWNER_MISMATCH, roles/apim_publish_api/tasks/version.yml — mais un nom déjà pris reste à éviter ici)"
fi

# ── 3. clone du dépôt d'ÉQUIPE, écrit spec + manifeste ───────────────────────
echo "[2/5] clone ${REPO_FULL}@main (dépôt de l'équipe)"
git clone -q --depth 1 -b main "${GIT_HOST}/${REPO_FULL}.git" "$WORK/team" \
  || fail "REPO_INACCESSIBLE : '${REPO_FULL}' déclaré pour '${TEAM}' mais introuvable/inaccessible sur ${GIT_HOST} — l'onboarding (team-apply) a-t-il bien créé le dépôt ?"

PUB_REL="apis/${API_NAME}.publish.yml"
SPEC_REL="apis/${API_NAME}.openapi.yaml"
PUB_PATH="$WORK/team/$PUB_REL"
SPEC_PATH="$WORK/team/$SPEC_REL"

if [ "$ACTION" = "create" ]; then
  [ ! -f "$PUB_PATH" ] \
    || fail "API_ALREADY_EXISTS : '${API_NAME}' existe déjà dans ${REPO_FULL} (${PUB_REL}) — utiliser ACTION=new-version"
else
  [ -f "$PUB_PATH" ] \
    || fail "API_BASE_NOT_FOUND : '${API_NAME}' introuvable dans ${REPO_FULL} (${PUB_REL}) — si ce nom n'appartient à AUCUNE équipe, publier d'abord une version initiale (ACTION=create) ; s'il apparaît dans la liste déroulante, il appartient à une AUTRE équipe (API_NAME_COLLISION vous le dira si vous tentez un create)"
  # Anti-TOCTOU léger : la liste déroulante (API_BASE) peut être en retard sur
  # ce que le dépôt d'équipe porte RÉELLEMENT sur main — un refus explicite
  # vaut mieux qu'une nouvelle version silencieusement basée sur la mauvaise
  # version de départ.
  EXISTING_VERSION=$(python3 -c "
import yaml
d = yaml.safe_load(open('${PUB_PATH}')) or {}
print((d.get('apim_api') or {}).get('version') or '')
" 2>/dev/null)
  [ "$EXISTING_VERSION" = "$BASE_VERSION" ] \
    || fail "API_BASE_STALE : ${REPO_FULL} porte déjà '${API_NAME}' en version '${EXISTING_VERSION:-inconnue}', différente de la version de base sélectionnée '${BASE_VERSION}' — rafraîchir la liste (relancer setup-team-onboard-jobs.sh) avant de soumettre une nouvelle version"
fi

mkdir -p "$(dirname "$PUB_PATH")"
sed -e "s/__API_NAME__/${API_NAME}/g" \
    -e "s/__API_VERSION__/${EFFECTIVE_VERSION}/g" \
    -e "s/__INBOUND_MODE__/${INBOUND_MODE}/g" \
    "${REPO_ROOT}/gateways/templates/publish.yml.tmpl" > "$PUB_PATH" \
  || fail "rendu du gabarit ${PUB_REL}"
printf '%s\n' "$OPENAPI_SPEC" > "$SPEC_PATH"

# ── 4. branche, commit, push, PR ─────────────────────────────────────────────
BRANCH="api/${API_NAME}-${EFFECTIVE_VERSION}"
echo "[3/5] branche ${BRANCH} + PR sur ${REPO_FULL}"
git -C "$WORK/team" checkout -q -b "$BRANCH" || fail "création de la branche locale ${BRANCH}"
git -C "$WORK/team" add "$PUB_REL" "$SPEC_REL"
git -C "$WORK/team" -c user.name=ci -c user.email=ci@stoa.lab \
  commit -qm "api(${API_NAME}): ${ACTION} v${EFFECTIVE_VERSION} (formulaire, équipe ${TEAM})" \
  || fail "commit sur ${BRANCH}"

# Credential par HEADER Basic injecté via GIT_CONFIG_COUNT/KEY_0/VALUE_0
# (jamais argv/URL — visible par ps -Aww sinon, sur le process git ET
# git-remote-http, motif éprouvé de team-request.sh/team-apply.sh, repris à
# l'identique).
AUTH_B64=$(printf 'x:%s' "$FORGE_SECRET" | base64 | tr -d '\n')
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
  GIT_CONFIG_VALUE_0="Authorization: Basic ${AUTH_B64}" \
  git -C "$WORK/team" push -q "${GIT_HOST}/${REPO_FULL}.git" "$BRANCH" 2>"$WORK/pusherr" \
  || { echo "ERREUR: push" >&2; cat "$WORK/pusherr" >&2; exit 1; }
unset AUTH_B64

PR_NUMBER=$(API="${GIT_HOST}/api/v1" REPO_FULL="$REPO_FULL" FORGE_SECRET="$FORGE_SECRET" \
  BRANCH="$BRANCH" API_NAME="$API_NAME" ACTION="$ACTION" EFFECTIVE_VERSION="$EFFECTIVE_VERSION" \
  TEAM="$TEAM" INBOUND_MODE="$INBOUND_MODE" BASE_VERSION="${BASE_VERSION:-}" \
  python3 - <<'PY'
import json, os, urllib.request
api, repo, tok = os.environ["API"], os.environ["REPO_FULL"], os.environ["FORGE_SECRET"]
action = os.environ["ACTION"]
base_line = f"\n- version de base : {os.environ['BASE_VERSION']}" if action == "new-version" and os.environ.get("BASE_VERSION") else ""
body = (
    f"Demande de publication d'API (formulaire api-request).\n\n"
    f"- action : {action}\n- équipe : {os.environ['TEAM']}\n"
    f"- API : {os.environ['API_NAME']} v{os.environ['EFFECTIVE_VERSION']}\n"
    f"- inbound.mode : {os.environ['INBOUND_MODE']}{base_line}\n\n"
    "Plan hors ligne (manifest-guard + team-name + syntax-check) à suivre en "
    "commentaire. Validation humaine requise avant merge (ADR-081) : le "
    "merge n'importe rien lui-même — la publication réelle vit dans le "
    "pipeline post-merge."
)
req_body = {"base": "main", "head": os.environ["BRANCH"],
            "title": f"api({os.environ['TEAM']}): {os.environ['API_NAME']} v{os.environ['EFFECTIVE_VERSION']} ({action})",
            "body": body}
req = urllib.request.Request(f"{api}/repos/{repo}/pulls", method="POST",
    data=json.dumps(req_body).encode(),
    headers={"Authorization": f"token {tok}", "Content-Type": "application/json"})
print(json.load(urllib.request.urlopen(req))["number"])
PY
) || fail "ouverture de la PR — la branche '${BRANCH}' est déjà poussée sur ${GIT_HOST}/${REPO_FULL} (elle n'a pas de PR) : nettoyer avec 'git push ${GIT_HOST}/${REPO_FULL}.git --delete ${BRANCH}' avant de relancer la demande"
echo "PR #${PR_NUMBER} ouverte : ${GIT_WEB_HOST}/${REPO_FULL}/pulls/${PR_NUMBER}"

# ── 5. PLAN — gardes hors ligne de apim_publish_api ──────────────────────────
# Exécuté depuis LE CHECKOUT DE CE SCRIPT (poc-control-plane-federation/,
# déjà préparé par le job Jenkins, stage('checkout') sur ci/stoa-labs@main) —
# PAS un nouveau clone : le code ansible/ est un artefact PLATEFORME, pas une
# donnée que la PR de l'équipe modifie (au contraire de providers.<env>.yml
# ci-dessus, lu FRAIS pour cette raison précise). Même geste que le stage
# Plan de ci/Jenkinsfile.publish-api (workspace déjà checkouté, aucun clone
# supplémentaire) : manifest-guard + team-name (ansible/test-publish-guards.yml,
# invocation relevée de HANDOFF-2026-07-31-E1-PRODUCTEUR.md, apim_ss_manifest
# en CHEMIN ABSOLU — accepté tel quel par manifest-guard.yml) PUIS
# --syntax-check du playbook de publication.
echo "[4/5] plan (gardes hors ligne : manifest-guard + team-name + syntax-check)"
ABS_MANIFEST="$PUB_PATH"
PLAN_LOG="$WORK/plan.log"
{
  echo "=== manifest-guard + team-name (ansible/test-publish-guards.yml) ==="
  ansible-playbook -i ansible/inventory.lab.ini ansible/test-publish-guards.yml \
    -e apim_ss_manifest="$ABS_MANIFEST" -e apim_ss_team="$TEAM"
  echo "GUARD_RC=$?"
  echo "=== syntax-check (ansible/publish-api.yml) ==="
  ansible-playbook -i ansible/inventory.lab.ini ansible/publish-api.yml --syntax-check
  echo "SYNTAX_RC=$?"
} >"$PLAN_LOG" 2>&1
GUARD_RC=$(grep -oE 'GUARD_RC=[0-9]+' "$PLAN_LOG" | tail -1 | cut -d= -f2)
SYNTAX_RC=$(grep -oE 'SYNTAX_RC=[0-9]+' "$PLAN_LOG" | tail -1 | cut -d= -f2)
if [ "${GUARD_RC:-1}" -eq 0 ] && [ "${SYNTAX_RC:-1}" -eq 0 ]; then
  PLAN_RC=0
else
  PLAN_RC=1
fi

# Hiérarchie de diagnostic fatal > msg > tail-3 (leçon du palier 2, appliquée
# d'entrée ici — cf. team-apply.sh §4 — plutôt que la simple extraction de
# TAGS de team-request.sh, qui peut afficher un dernier tag OK antérieur à un
# échec réel situé ailleurs dans la chaîne).
if [ "$PLAN_RC" -eq 0 ]; then
  OKMSG=$(grep -oE '"msg": "(MANIFEST_KEYS_OK|TEAM_REQUESTED)[^"]*"' "$PLAN_LOG" | sed 's/^"msg": "//; s/"$//' | tr '\n' ' ; ')
  VERDICT="✅ PLAN OK — ${OKMSG:-gardes hors ligne + syntax-check passés}"
else
  MSG=$(grep -A6 -E 'fatal:|FAILED!|^ERROR!' "$PLAN_LOG" | grep -oE '"msg":.*|^ERROR!.*' | tail -1 | cut -c1-300)
  [ -n "$MSG" ] || MSG=$(tail -3 "$PLAN_LOG" | tr '\n' ' ')
  VERDICT="❌ PLAN EN ÉCHEC — NE PAS MERGER : ${MSG}"
fi

BODY="${VERDICT}

Au merge, la publication réelle (import OpenAPI + activate + inbound) vit
dans le pipeline post-merge (rôle apim_publish_api) — cette PR ne fait que
poser \`${PUB_REL}\` + \`${SPEC_REL}\`, rien n'est encore publié sur la gateway."

# Dette du palier 2 (constat de revue) : le POST de commentaire n'y vérifiait
# JAMAIS son code de retour — un échec de publication du verdict passait
# inaperçu. Ici : vérifié, et un échec est VISIBLE (avertissement bruyant,
# PAS un exit silencieux) — mais la PR EXISTE déjà et reste valide : la
# non-publication d'UN commentaire n'annule pas une PR déjà ouverte.
COMMENT_ERR=$(API="${GIT_HOST}/api/v1" REPO_FULL="$REPO_FULL" FORGE_SECRET="$FORGE_SECRET" \
  PR="$PR_NUMBER" BODY="$BODY" python3 - <<'PY' 2>&1
import json, os, urllib.request
api, repo, tok = os.environ["API"], os.environ["REPO_FULL"], os.environ["FORGE_SECRET"]
req = urllib.request.Request(f"{api}/repos/{repo}/issues/{os.environ['PR']}/comments",
    method="POST", data=json.dumps({"body": os.environ["BODY"]}).encode(),
    headers={"Authorization": f"token {tok}", "Content-Type": "application/json"})
urllib.request.urlopen(req)
PY
)
COMMENT_RC=$?
if [ "$COMMENT_RC" -ne 0 ]; then
  echo "AVERTISSEMENT: échec de la publication du commentaire PLAN sur la PR #${PR_NUMBER} (${COMMENT_ERR}) — la PR reste ouverte et valide ; verdict local : ${VERDICT}" >&2
else
  echo "[5/5] plan ${VERDICT%% *} commenté sur la PR #${PR_NUMBER}"
fi

[ "$PLAN_RC" -eq 0 ]
