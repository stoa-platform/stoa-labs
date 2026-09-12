#!/usr/bin/env bash
# api-request.sh — moteur du formulaire « publier une API » (palier 3, la
# porte du PRODUCTEUR — pendant de team-request.sh, palier 2). MODÈLE
# STRUCTUREL repris tel quel : gardes nommées avant tout geste Git, clone,
# branche, push par GIT_CONFIG_COUNT/KEY_0/VALUE_0 (jamais de token en
# URL/argv), PR par heredoc python, plan commenté sur la PR.
#
#   formulaire Jenkins → CE script :
#     1. gardes d'entrée (AVANT tout geste Git — un refus ne laisse rien derrière)
#     2. team -> repo, lu dans providers.<env>.yml sur la branche de base du
#        dépôt plateforme, telle que la forge la déclare (jamais le
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
#   CLASSIFICATION (req) niveau d'INTÉGRITÉ déclaré (VH|H|M) — P2, une RÉFÉRENCE
#   EXPOSURE      (req) exposition ENTRANTE déclarée (internal|external|internet)
#                       — P2, une RÉFÉRENCE elle aussi : le REGISTRE CENTRAL
#                       gagne, et une déclaration PLUS FAIBLE est refusée
#                       [CLASSIFICATION_SPOOFED], relayée sur la PR
#   FORGE_SECRET   (req) token du service ci (write:repository, write:issue)
#   GIT_REPO           dépôt PLATEFORME (défaut ci/stoa-labs) — porte
#                       ansible/providers.<env>.yml ET les gardes hors ligne
#   GIT_HOST            défaut http://gitea:3000
#   GIT_WEB_HOST         URL Gitea vue par l'HUMAIN (liens des commentaires)
#   GOVERNANCE_REPO (req) dépôt du REGISTRE CENTRAL de classification, propriété
#                       de la gouvernance de la donnée et NON éditable par les
#                       équipes API (en prod : le dépôt `data-governance` du
#                       client). AUCUN défaut — un repli de lab publierait sous
#                       une gouvernance qui n'est pas la vôtre, sans le dire.
#                       Lu FRAIS sur SA branche de base (git_base_of : ce dépôt
#                       peut ne pas avoir la même HEAD que la plateforme),
#                       jamais depuis le worktree — même discipline que
#                       providers.<env>.yml, même raison.
#   GOVERNANCE_PATH (req) chemin du registre DANS ce dépôt
#                       (ex. governance/classifications.yaml) — sans défaut
#   LABCTL_BIN          binaire qui porte l'AUTORITÉ de la table de vérité
#                       (défaut labctl, résolu par PATH) — la comparaison
#                       anti-downgrade n'est PAS réécrite ici (cf. §1b)
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
# Disposition du dépôt : le préfixe du livrable est un KNOB (GIT_SUBDIR ->
# SUB_PFX), jamais le préfixe du lab en dur — c'est ce littéral qui a fait
# mourir la chaîne du client le 2026-09-08 sur un fichier POURTANT présent.
_AR_LAYOUT="$(dirname "${BASH_SOURCE[0]}")/lib/repo-layout.sh"
[ -f "$_AR_LAYOUT" ] || _AR_LAYOUT="scripts/lib/repo-layout.sh"
# shellcheck source=scripts/lib/repo-layout.sh
. "$_AR_LAYOUT" || { echo "ERREUR: $_AR_LAYOUT introuvable ou illisible" >&2; exit 1; }
repo_layout_init || exit 2
# LA branche par défaut des dépôts de la forge, une autorité (L3, 2026-09-10).
# SOURCÉE ici, JOUÉE plus bas : `git_base_init` sur le dépôt PLATEFORME, et
# `git_base_of` sur chacun des autres (gouvernance, équipes) — trois familles de
# dépôts peuvent avoir trois HEAD, un GIT_BASE global n'est vrai que pour la
# plateforme. Les quatre clones de ce script sont ANONYMES : les découvertes le
# sont aussi, sous la même enveloppe (aucune) que le clone qu'elles précèdent.
_AR_BASE="$(dirname "${BASH_SOURCE[0]}")/lib/git-base.sh"
[ -f "$_AR_BASE" ] || _AR_BASE="scripts/lib/git-base.sh"
# shellcheck source=scripts/lib/git-base.sh
. "$_AR_BASE" || { echo "ERREUR: $_AR_BASE introuvable ou illisible" >&2; exit 1; }

ACTION="${ACTION:?ACTION requis (create|new-version)}"
TEAM="${TEAM:?TEAM requis}"
API_NAME="${API_NAME:?API_NAME requis}"
API_VERSION="${API_VERSION:-}"
API_BASE="${API_BASE:-}"
NEW_VERSION="${NEW_VERSION:-}"
OPENAPI_SPEC="${OPENAPI_SPEC:?OPENAPI_SPEC requis}"
INBOUND_MODE="${INBOUND_MODE:?INBOUND_MODE requis (jwt uniquement — oauth2 refusé)}"
# P2 — la POSTURE déclarée. Lue SANS `${VAR:?}` : un champ obligatoire se refuse
# en se nommant (mémoire CHAMP_REQUIS), pas par un « unbound variable » qui ne
# dit ni lequel ni pourquoi. Le refus explicite est dans les gardes ci-dessous.
CLASSIFICATION="${CLASSIFICATION:-}"
EXPOSURE="${EXPOSURE:-}"
# Le secret de la forge porte un nom NEUTRE (2026-09-04) : un gestionnaire
# d'identite rend un jeton OU un couple, et les deux occupent la meme place.
FORGE_SECRET="${FORGE_SECRET:-${GITEA_TOKEN:-}}"
[ -n "$FORGE_SECRET" ] || { echo "REFUS: SECRET_FORGE_REQUIS : ni FORGE_SECRET ni son alias GITEA_TOKEN — le secret de la forge (jeton, ou mot de passe d'un couple avec FORGE_USER)" >&2; exit 2; }
# ── L'ENVELOPPE D'AUTHENTIFICATION DES GESTES GIT (2026-09-11) ───────────────
# Ces gestes étaient NUS : ils marchaient sur le Gitea du lab, qui sert
# `info/refs` en lecture ANONYME (200), et cassaient sur toute forge PRIVÉE —
# 401, puis un refus qui accuse autre chose (mesuré quatre fois d'affilée sur la
# chaîne app-request, cf. ENVIRONNEMENTS.md « La forge privée »). Même motif que
# team-publish.sh / team-promote.sh / api-promote-export.sh, au login près : il
# vient de l'autorité unique `git_base_basic_login` (« x » convient à Gitea,
# JAMAIS à GitLab ni Bitbucket). Le secret ne passe NI en argv NI dans l'URL :
# c'est le NOM de la variable qui voyage (`ps -Aww` lit l'argv de la machine).
gclone(){ git_base_avec_basic "$(git_base_basic_login)" FORGE_SECRET git clone -q "$@"; }
gbase(){ git_base_avec_basic "$(git_base_basic_login)" FORGE_SECRET "$@"; }
ggit(){ git_base_avec_basic "$(git_base_basic_login)" FORGE_SECRET git "$@"; }

GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
GIT_HOST="${GIT_HOST:-http://gitea:3000}"
GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"
# L5 phase 2 (2026-09-12) — LA FORGE SE PARLE PAR UNE SEULE AUTORITÉ : le
# visage (FORGE_KIND=gitea|gitlab), la base d'API, l'en-tête d'auth et la garde
# de réponse vivent dans scripts/lib/forge-api.sh (+ .py) — ce script ne
# compose plus /api/v1 ni « Authorization: token » lui-même (mêmes verbes que
# team-request.sh/provision-request.sh). Sourcé APRÈS la garde du secret
# (FORGE_SECRET, §haut) et APRÈS GIT_HOST/GIT_REPO/GIT_WEB_HOST ci-dessus :
# forge_api_init ne fait AUCUN appel réseau, mais REFUSE si GIT_HOST ou
# GIT_REPO est vide — GIT_REPO ici est le dépôt PLATEFORME (défaut posé juste
# au-dessus) ; chaque appel visant le dépôt de l'ÉQUIPE se préfixe lui-même
# GIT_REPO="$REPO_FULL" (§3, §5b) — l'autorité n'a pas besoin de le savoir à
# l'init, seulement qu'UN dépôt est nommé.
_AR_FORGE="$(dirname "${BASH_SOURCE[0]}")/lib/forge-api.sh"
[ -f "$_AR_FORGE" ] || _AR_FORGE="scripts/lib/forge-api.sh"
# shellcheck source=scripts/lib/forge-api.sh
. "$_AR_FORGE" || { echo "ERREUR: $_AR_FORGE introuvable ou illisible" >&2; exit 1; }
forge_api_init || exit 2
# AUCUN DÉFAUT, et c'est la porte ci/lint-config-knobs.sh qui l'exige : une
# valeur de lab installée en repli n'est jamais signalée chez un client, elle est
# substituée en silence et la panne sort plus loin sous un autre nom. Ces deux-là
# se posent en variables globales du contrôleur (scripts/setup-jenkins-globals.sh)
# et le script REFUSE en se nommant quand elles manquent (§2a).
GOVERNANCE_REPO="${GOVERNANCE_REPO:-}"
GOVERNANCE_PATH="${GOVERNANCE_PATH:-}"
LABCTL_BIN="${LABCTL_BIN:-labctl}"
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

# ── 1b. POSTURE : présence, puis vocabulaire — DEMANDÉ À L'AUTORITÉ ──────────
# (jalon P2, ADR-092.) Deux gardes distinctes, et la seconde ne réécrit RIEN.
#
# PRÉSENCE d'abord : un champ obligatoire se refuse EN SE NOMMANT. Le
# formulaire les pose en listes déroulantes sans valeur vide, mais ce script est
# aussi la voie MACHINE (appel direct, sans Jenkins) — un appelant qui les omet
# doit lire pourquoi, pas un `unbound variable`.
[ -n "$CLASSIFICATION" ] || fail "CHAMP_REQUIS : CLASSIFICATION (niveau d'intégrité déclaré : VH|H|M). La valeur RETENUE sera celle du registre central ; celle-ci en est la référence, et une référence absente ne peut pas être comparée."
[ -n "$EXPOSURE" ]       || fail "CHAMP_REQUIS : EXPOSURE (exposition entrante déclarée : internal|external|internet). Idem — le registre central tranche, cette valeur est ce que la demande engage."
case "$CLASSIFICATION" in *[!A-Za-z]*) fail "POSTURE_INVALIDE : CLASSIFICATION='$CLASSIFICATION' porte un caractère hors [A-Za-z]";; esac
case "$EXPOSURE" in       *[!a-z]*)    fail "POSTURE_INVALIDE : EXPOSURE='$EXPOSURE' porte un caractère hors [a-z]";; esac

# VOCABULAIRE ensuite, et ICI EST LE POINT : aucune liste VH|H|M ni
# internal|external|internet n'est écrite dans ce fichier. P1 a retiré quatre
# recopies de ces énumérations pour faire de `render` (Go) leur seule autorité ;
# en réécrire une cinquième en bash — et, pire, y réécrire la comparaison
# anti-downgrade, sur un axe qui n'est PAS une échelle — rouvrirait exactement
# la dérive silencieuse que ce jalon vient de fermer. Donc on DEMANDE.
#
# Sans registre à cette étape (`--classification-source` absent) : `labctl
# posture` se contente de dériver la posture DÉCLARÉE. Il refuse une valeur hors
# vocabulaire ou une cellule non gouvernée [INTEGRITY_INCONSISTENT] — c'est tout
# ce qu'on lui demande avant d'écrire quoi que ce soit. L'arbitrage contre le
# registre, lui, vient au PLAN (§5b), après l'ouverture de la PR : son refus
# doit être RELAYÉ à la PR, donc il faut qu'une PR existe.
command -v "$LABCTL_BIN" >/dev/null 2>&1 \
  || fail "POSTURE_AUTORITE_ABSENTE : '$LABCTL_BIN' introuvable dans le PATH — la table de vérité exposition × classification (ADR-091) vit dans ce binaire et n'est réécrite nulle part ailleurs. Sans lui, la demande n'est pas vérifiable : refus, plutôt qu'une posture acceptée sans juge."
#
# LABCTL_CLASSIFICATION_SOURCE/LABCTL_PROJECT sont VIDÉS pour cet appel-ci, et
# ce n'est pas cosmétique : `labctl posture` lit ces variables d'environnement
# quand ses drapeaux sont absents. Un nœud Jenkins qui les porterait ferait
# consulter le registre DÈS CETTE GARDE — et une API pas encore enregistrée
# (le cas NORMAL d'un `create`) serait refusée AVANT qu'aucune PR n'existe,
# donc sans que personne ne puisse lire pourquoi à l'endroit prévu.
POSTURE_ERR=$(LABCTL_CLASSIFICATION_SOURCE='' LABCTL_PROJECT='' "$LABCTL_BIN" posture --api "$API_NAME" \
  --declared-classification "$CLASSIFICATION" --declared-exposure "$EXPOSURE" 2>&1) \
  || fail "POSTURE_INVALIDE : classification='$CLASSIFICATION' exposure='$EXPOSURE' — ${POSTURE_ERR}"

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

# ── 2. team -> repo, depuis providers.<env>.yml sur la BRANCHE DE BASE ──────
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# LA BRANCHE DE BASE DU DÉPÔT PLATEFORME, ici : l'URL de clone est composée
# (GIT_HOST + GIT_REPO), et c'est le premier `-b` du script. Knob GIT_BASE >
# HEAD du dépôt > refus nommé (rc 2) — jamais « main » deviné.
PLAT_URL="${GIT_HOST}/${GIT_REPO}.git"
gbase git_base_init "$PLAT_URL" || exit 2
echo "[1/5] clone ${GIT_REPO}@${GIT_BASE} (lecture team -> repo)"
# Le diagnostic d'un `-b` refusé vit dans la lib (git_base_clone_refus) : rc 2
# = branche absente d'un dépôt qui a RÉPONDU, rc 1 = dépôt injoignable, et la
# distinction vient de `ls-remote --exit-code --heads`, jamais du texte de git.
if ! gclone --depth 1 -b "$GIT_BASE" "$PLAT_URL" "$WORK/platform" 2>"$WORK/clone.err"; then
  git_base_clone_refus "$PLAT_URL" "$GIT_BASE" "$WORK/clone.err" "${GIT_REPO} (résolution team -> repo)" || exit $?
fi
PROV_REL="${SUB_PFX}ansible/providers.${ENVN}.yml"
PROV="$WORK/platform/$PROV_REL"
# Le refus NOMME le chemin RÉELLEMENT lu, préfixe compris : un message qui
# désigne un chemin théorique envoie chercher au mauvais endroit.
[ -f "$PROV" ] || fail "PROVIDERS_MISSING : ${PROV_REL} absent sur ${GIT_REPO}@${GIT_BASE} (chemin RELATIF à la racine du dépôt, préfixe GIT_SUBDIR='${GIT_SUBDIR}')"

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
  fail "TEAM_NOT_DECLARED : '${TEAM}' absente de providers.${ENVN}.yml (sur ${GIT_BASE})"
fi
case "$REPO_OUT" in
  REPO=*) REPO_FULL="${REPO_OUT#REPO=}";;
  *) fail "PARSE_PROVIDERS : sortie inattendue de l'extraction repo pour ${TEAM} — ${REPO_OUT}";;
esac
[ -n "$REPO_FULL" ] || fail "REPO_MANQUANT : onboarder d'abord un dépôt pour cette équipe (providers.${ENVN}.yml, champ repo de '${TEAM}' vide)"
echo "  équipe '${TEAM}' -> dépôt ${REPO_FULL}"

# ── 2a. registre CENTRAL, lu FRAIS sur SA branche de base ───────────────────
# (jalon P2.) Cloné ICI, avant toute écriture Git : une source de gouvernance
# injoignable ou absente est une panne d'INFRASTRUCTURE, pas un défaut de la
# demande — elle doit donc refuser AVANT qu'une PR n'existe, et non finir en
# « ❌ PLAN » sur une PR ouverte qui ferait porter le chapeau au demandeur.
# (Un défaut de la DEMANDE, lui — downgrade, API non enregistrée — est arbitré
# au plan §5b, une fois la PR ouverte, parce que son refus doit y être relayé.)
#
# Dépôt SÉPARÉ, et c'est le fond : le registre appartient à la gouvernance de la
# donnée, pas à l'équipe API ni même à la plateforme qui l'exécute. Un registre
# que l'équipe pourrait éditer ne serait qu'une deuxième copie de sa propre
# déclaration — l'invariant d'ancrage déjà prouvé côté labctl
# (scripts/test-classification-central.sh, preuve 6).
[ -n "$GOVERNANCE_REPO" ] || fail "CHAMP_REQUIS : GOVERNANCE_REPO — le dépôt du registre central de classification (chez le client : le dépôt de la gouvernance de la donnée). Aucun défaut n'est posé volontairement : une valeur de lab en repli publierait sous une gouvernance qui n'est pas la vôtre. La poser en variable globale du contrôleur Jenkins (scripts/setup-jenkins-globals.sh)."
[ -n "$GOVERNANCE_PATH" ] || fail "CHAMP_REQUIS : GOVERNANCE_PATH — le chemin du registre DANS ce dépôt (ex. governance/classifications.yaml). Même raison qu'au-dessus."
# SA branche à LUI, pas celle de la plateforme : le dépôt de gouvernance
# appartient à une autre équipe, souvent créé un autre jour, sur une autre
# convention. `git_base_of` la demande AU DÉPÔT et la mémoïse par URL.
GOV_URL="${GIT_HOST}/${GOVERNANCE_REPO}.git"
gbase git_base_of "$GOV_URL" >/dev/null \
  || fail "REGISTRE_GOUVERNANCE_INACCESSIBLE : branche par défaut de '${GOVERNANCE_REPO}' indéterminable sur ${GIT_HOST} (cause ci-dessus) — la posture ne peut pas être arbitrée, et une posture non arbitrée est celle que la demande s'est donnée. Refus."
GOV_BASE="$GIT_BASE_OF"
echo "[1c/5] registre central ${GOVERNANCE_REPO}@${GOV_BASE} (${GOVERNANCE_PATH})"
gclone --depth 1 -b "$GOV_BASE" "$GOV_URL" "$WORK/governance" \
  || fail "REGISTRE_GOUVERNANCE_INACCESSIBLE : '${GOVERNANCE_REPO}' injoignable sur ${GIT_HOST} — la posture ne peut pas être arbitrée, et une posture non arbitrée est celle que la demande s'est donnée. Refus."
REGISTRY="$WORK/governance/${GOVERNANCE_PATH}"
[ -f "$REGISTRY" ] \
  || fail "REGISTRE_GOUVERNANCE_ABSENT : '${GOVERNANCE_PATH}' introuvable dans ${GOVERNANCE_REPO}@${GOV_BASE} — vérifier GOVERNANCE_PATH, ou faire poser le registre par la gouvernance de la donnée"

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
  # FAIL-OPEN si ce préfixe est faux, et c'est ce qui le rend cher : la boucle
  # ci-dessous fait `[ -d … ] || continue` sur ses DEUX itérations, COLLISION_OWNER
  # reste vide, et la moitié plateforme de la porte rend « aucune collision » avec
  # la même assurance que si elle avait regardé — à comparer au clone d'équipe
  # raté qui, lui, CRIE COLLISION_SCAN_INCOMPLET. Le knob est déjà résolu plus
  # haut (repo_layout_init) et déjà utilisé pour providers.<env>.yml.
  # `${SUB_PFX:-.}` : SUB_PFX vide (le livrable EST la racine) rend « . ».
  PLATFORM_ROOT="$WORK/platform/${SUB_PFX:-.}"
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
      # Chaque dépôt d'équipe a SA branche par défaut : la demander au dépôt
      # (git_base_of, mémoïsé) est la seule façon de balayer réellement. Une
      # découverte ratée n'est pas « aucune collision » — c'est le même
      # non-balayage que le clone raté ci-dessous, et il se dit pareil.
      OTHER_URL="${GIT_HOST}/${OTHER_REPO}.git"
      if gbase git_base_of "$OTHER_URL" 2>"$OW.err" >/dev/null \
         && git clone -q --depth 1 -b "$GIT_BASE_OF" "$OTHER_URL" "$OW" 2>"$OW.err"; then
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
# LA BRANCHE DU DÉPÔT D'ÉQUIPE — la sienne, pas celle de la plateforme. C'est
# elle que le clone prend ET que la PR vise plus bas : ouvrir une PR vers une
# base que le clone n'a pas utilisée était exactement le défaut du 2026-09-09.
TEAM_URL="${GIT_HOST}/${REPO_FULL}.git"
gbase git_base_of "$TEAM_URL" >/dev/null \
  || fail "REPO_INACCESSIBLE : '${REPO_FULL}' déclaré pour '${TEAM}' mais sa branche par défaut est indéterminable sur ${GIT_HOST} (cause ci-dessus) — l'onboarding (team-apply) a-t-il bien créé le dépôt ?"
TEAM_BASE="$GIT_BASE_OF"
echo "[2/5] clone ${REPO_FULL}@${TEAM_BASE} (dépôt de l'équipe)"
gclone --depth 1 -b "$TEAM_BASE" "$TEAM_URL" "$WORK/team" \
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
  # ce que le dépôt d'équipe porte RÉELLEMENT sur sa branche de base — un refus explicite
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
    -e "s/__CLASSIFICATION__/${CLASSIFICATION}/g" \
    -e "s/__EXPOSURE__/${EXPOSURE}/g" \
    "${REPO_ROOT}/gateways/templates/publish.yml.tmpl" > "$PUB_PATH" \
  || fail "rendu du gabarit ${PUB_REL}"
# Le gabarit ne doit plus porter AUCUN marqueur : un `__X__` survivant serait
# une posture littérale « __CLASSIFICATION__ » committée puis refusée bien plus
# loin, par un code qui ne désignerait pas la cause. Vérifié plutôt que supposé.
! grep -q '__[A-Z_]*__' "$PUB_PATH" \
  || fail "GABARIT_NON_SUBSTITUE : ${PUB_REL} porte encore $(grep -o '__[A-Z_]*__' "$PUB_PATH" | sort -u | tr '\n' ' ') — le gabarit a gagné un marqueur que ce script ne substitue pas"
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
# Le LOGIN vient de l'autorité unique (2026-09-12) : « x » était composé EN DUR
# ici, et un geste PARFAITEMENT authentifié retombait donc en 401 sur GitLab —
# invisible à la porte H bis.2, qui mesure l'enveloppe du geste et non l'origine
# du login (d'où H bis.4).
AUTH_B64=$(printf '%s:%s' "$(git_base_basic_login)" "$FORGE_SECRET" | base64 | tr -d '\n')
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
  GIT_CONFIG_VALUE_0="Authorization: Basic ${AUTH_B64}" \
  git -C "$WORK/team" push -q "${GIT_HOST}/${REPO_FULL}.git" "$BRANCH" 2>"$WORK/pusherr" \
  || { echo "ERREUR: push" >&2; cat "$WORK/pusherr" >&2; exit 1; }
unset AUTH_B64

# Le corps de la PR est écrit dans un FICHIER (jamais en argv) ; la base est
# TEAM_BASE, la HEAD découverte du dépôt d'équipe — jamais un littéral.
{
  printf "Demande de publication d'API (formulaire api-request).\n\n"
  printf -- "- action : %s\n- équipe : %s\n- API : %s v%s\n- inbound.mode : %s\n" "$ACTION" "$TEAM" "$API_NAME" "$EFFECTIVE_VERSION" "$INBOUND_MODE"
  [ "$ACTION" = new-version ] && [ -n "${BASE_VERSION:-}" ] && printf -- "- version de base : %s\n" "$BASE_VERSION"
  printf -- "- posture DÉCLARÉE : classification=%s exposure=%s — déclaration, pas décision : la posture retenue vient du registre central de gouvernance (commentaire de plan ci-dessous).\n\n" "$CLASSIFICATION" "$EXPOSURE"
  printf "Plan hors ligne (posture centrale + manifest-guard + team-name + syntax-check) à suivre en commentaire. Validation humaine requise avant merge (ADR-081) : le merge n'importe rien lui-même — la publication réelle vit dans le pipeline post-merge.\n"
} > "$WORK/pr-body.md"
if ! GIT_REPO="$REPO_FULL" forge_kv PR pr_open "$BRANCH" "$TEAM_BASE" "api(${TEAM}): ${API_NAME} v${EFFECTIVE_VERSION} (${ACTION})" "$WORK/pr-body.md"; then
  fail "ouverture de la PR (cause ci-dessus) — si la branche '${BRANCH}' est déjà poussée sur ${GIT_HOST}/${REPO_FULL} sans PR, la nettoyer avec 'git push ${GIT_HOST}/${REPO_FULL} --delete ${BRANCH}' puis rejouer"
fi
PR_LINK="$(forge_web_url "$PR_URL")"     # forge_kv PR a posé PR_NUMBER et PR_URL
echo "PR #${PR_NUMBER} ouverte : ${PR_LINK}"

# ── 5. PLAN — gardes hors ligne de apim_publish_api ──────────────────────────
# Exécuté depuis LE CHECKOUT DE CE SCRIPT (poc-control-plane-federation/,
# déjà préparé par le job Jenkins, stage('checkout') sur la branche de base de
# ci/stoa-labs) —
# PAS un nouveau clone : le code ansible/ est un artefact PLATEFORME, pas une
# donnée que la PR de l'équipe modifie (au contraire de providers.<env>.yml
# ci-dessus, lu FRAIS pour cette raison précise). Même geste que le stage
# Plan de ci/Jenkinsfile.publish-api (workspace déjà checkouté, aucun clone
# supplémentaire) : manifest-guard + team-name (ansible/test-publish-guards.yml,
# invocation relevée de HANDOFF-2026-07-31-E1-PRODUCTEUR.md, apim_ss_manifest
# en CHEMIN ABSOLU — accepté tel quel par manifest-guard.yml) PUIS
# --syntax-check du playbook de publication.
echo "[4/5] plan (posture centrale + gardes hors ligne : manifest-guard + team-name + syntax-check)"
ABS_MANIFEST="$PUB_PATH"
PLAN_LOG="$WORK/plan.log"
{
  # ── 5b. POSTURE : le registre CENTRAL contre la déclaration ────────────────
  # (jalon P2, la porte ET la contre-épreuve.) L'identité passée en --project
  # est TEAM, résolue plus haut par la chaîne : c'est la moitié non-éditable de
  # la clé de recherche. Le manifeste, lui, ne la porte pas — s'il la portait,
  # l'équipe pourrait pointer la ligne d'une autre (le trou « emprunt de ligne »
  # déjà fermé côté labctl).
  #
  # Aucun --tenant : le manifeste de publication n'en déclare pas (l'équipe EST
  # son unité de cloisonnement ici). Rien de réclamé, donc rien à falsifier —
  # l'ancre anti-spoof reste le couple (équipe, api). Le tenant gouverné est
  # RENDU par la commande, et paraît dans ce journal.
  echo "=== posture centrale (labctl posture — registre ${GOVERNANCE_REPO}@${GOV_BASE}) ==="
  "$LABCTL_BIN" posture --api "$API_NAME" --project "$TEAM" \
    --declared-classification "$CLASSIFICATION" --declared-exposure "$EXPOSURE" \
    --classification-source "$REGISTRY"
  echo "POSTURE_RC=$?"
  echo "=== manifest-guard + team-name (ansible/test-publish-guards.yml) ==="
  ansible-playbook -i ansible/inventory.lab.ini ansible/test-publish-guards.yml \
    -e apim_ss_manifest="$ABS_MANIFEST" -e apim_ss_team="$TEAM"
  echo "GUARD_RC=$?"
  echo "=== syntax-check (ansible/publish-api.yml) ==="
  ansible-playbook -i ansible/inventory.lab.ini ansible/publish-api.yml --syntax-check
  echo "SYNTAX_RC=$?"
} >"$PLAN_LOG" 2>&1
POSTURE_RC=$(grep -oE 'POSTURE_RC=[0-9]+' "$PLAN_LOG" | tail -1 | cut -d= -f2)
GUARD_RC=$(grep -oE 'GUARD_RC=[0-9]+' "$PLAN_LOG" | tail -1 | cut -d= -f2)
SYNTAX_RC=$(grep -oE 'SYNTAX_RC=[0-9]+' "$PLAN_LOG" | tail -1 | cut -d= -f2)
if [ "${POSTURE_RC:-1}" -eq 0 ] && [ "${GUARD_RC:-1}" -eq 0 ] && [ "${SYNTAX_RC:-1}" -eq 0 ]; then
  PLAN_RC=0
else
  PLAN_RC=1
fi

# La ligne de posture RETENUE, telle quelle, pour le journal du build ET pour le
# commentaire de PR : c'est elle qui montre que la valeur appliquée est celle du
# registre (source=central) et non celle qui a été cochée au formulaire.
POSTURE_LINE=$(grep -E '^posture ' "$PLAN_LOG" | tail -1)
POSTURE_WARN=$(grep -E '^⚠ ' "$PLAN_LOG" | tail -1)
[ -n "$POSTURE_LINE" ] && echo "  $POSTURE_LINE"

# Hiérarchie de diagnostic fatal > msg > tail-3 (leçon du palier 2, appliquée
# d'entrée ici — cf. team-apply.sh §4 — plutôt que la simple extraction de
# TAGS de team-request.sh, qui peut afficher un dernier tag OK antérieur à un
# échec réel situé ailleurs dans la chaîne).
if [ "$PLAN_RC" -eq 0 ]; then
  OKMSG=$(grep -oE '"msg": "(MANIFEST_KEYS_OK|TEAM_REQUESTED)[^"]*"' "$PLAN_LOG" | sed 's/^"msg": "//; s/"$//' | tr '\n' ' ; ')
  VERDICT="✅ PLAN OK — ${OKMSG:-gardes hors ligne + syntax-check passés}"
else
  # La POSTURE d'abord dans la hiérarchie de diagnostic (jalon P2) : son refus
  # est une phrase de labctl sur stderr, sans `fatal:` ni `"msg":` — les deux
  # motifs que la hiérarchie d'origine sait lire. Sans cette branche, un
  # CLASSIFICATION_SPOOFED tombait sur le repli `tail -3` et arrivait sur la PR
  # en morceau de trace, c'est-à-dire nommé par personne. Le code nommé DOIT
  # être ce que le demandeur lit.
  MSG=""
  if [ "${POSTURE_RC:-1}" -ne 0 ]; then
    MSG=$(grep -oE '\[(CLASSIFICATION_SPOOFED|CLASSIFICATION_UNGOVERNED|INTEGRITY_INCONSISTENT)\].*' "$PLAN_LOG" | tail -1 | cut -c1-400)
  fi
  if [ -z "$MSG" ]; then
    MSG=$(grep -A6 -E 'fatal:|FAILED!|^ERROR!' "$PLAN_LOG" | grep -oE '"msg":.*|^ERROR!.*' | tail -1 | cut -c1-300)
  fi
  [ -n "$MSG" ] || MSG=$(tail -3 "$PLAN_LOG" | tr '\n' ' ')
  VERDICT="❌ PLAN EN ÉCHEC — NE PAS MERGER : ${MSG}"
fi

# La posture RETENUE est portée par le commentaire, verdict vert ou rouge : sur
# une PR verte elle montre ce qui sera réellement appliqué (et, si le registre a
# corrigé la demande, que la correction a bien eu lieu) ; sur une PR rouge elle
# est simplement absente, parce qu'aucune posture n'a été retenue.
POSTURE_BLOCK=""
[ -n "$POSTURE_LINE" ] && POSTURE_BLOCK="

Posture retenue (le registre central de gouvernance fait autorité, la demande
n'en est que la référence) :
\`\`\`
${POSTURE_LINE}
\`\`\`${POSTURE_WARN:+
${POSTURE_WARN}}"

BODY="${VERDICT}${POSTURE_BLOCK}

Au merge, la publication réelle (import OpenAPI + activate + inbound) vit
dans le pipeline post-merge (rôle apim_publish_api) — cette PR ne fait que
poser \`${PUB_REL}\` + \`${SPEC_REL}\`, rien n'est encore publié sur la gateway.
La posture y est ré-arbitrée contre le MÊME registre avant le premier appel à
la gateway : ce plan est un avis précoce, pas une autorisation."

# Dette du palier 2 (constat de revue) : le POST de commentaire n'y vérifiait
# JAMAIS son code de retour — un échec de publication du verdict passait
# inaperçu. Ici : vérifié, et un échec est VISIBLE (avertissement bruyant,
# PAS un exit silencieux) — mais la PR EXISTE déjà et reste valide : la
# non-publication d'UN commentaire n'annule pas une PR déjà ouverte.
printf '%s\n' "$BODY" > "$WORK/plan-comment.md"
COMMENT_RC=0
GIT_REPO="$REPO_FULL" forge comment_upsert "$PR_NUMBER" '<!-- api-request -->' "$WORK/plan-comment.md" >/dev/null 2>"$WORK/comment.err" || COMMENT_RC=$?
COMMENT_ERR="$(cat "$WORK/comment.err")"
if [ "$COMMENT_RC" -ne 0 ]; then
  echo "AVERTISSEMENT: échec de la publication du commentaire PLAN sur la PR #${PR_NUMBER} (${COMMENT_ERR}) — la PR reste ouverte et valide ; verdict local : ${VERDICT}" >&2
else
  echo "[5/5] plan ${VERDICT%% *} commenté sur la PR #${PR_NUMBER}"
fi

[ "$PLAN_RC" -eq 0 ]
