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
#   REQ_ENV        (req) palier non terminal de la chaîne (env_chain_nonprod,
#                  dev/rec/int/homol aujourd'hui) — pilote le nom de branche + la cible
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
#
# Task 4 (P3) — identité entrante, TOUS OPTIONNELS. Absents = comportement
# octet pour octet identique à avant (preuve de non-régression, cf. Step 4 du
# brief) : chaque bloc de manifeste qu'ils pilotent n'est rendu QUE si fourni.
#   REQ_TEAM           équipe propriétaire (cloisonnement) — DOIT être déclarée
#                      dans providers.<env>.yml (même garde que team-request.sh) ;
#                      pilote aussi TENANT (déploiement Vault, mode internal).
#   REQ_IP_ALLOWLIST   UNE OU PLUSIEURS IP / plages A-B (v3) — séparées par des
#                      retours-ligne ou des virgules. Jamais de CIDR (la gateway
#                      le drop en silence, cf. README du rôle
#                      apim_selfservice_app). Chaque entrée est validée
#                      SÉPARÉMENT ; les doublons exacts sont écartés, l'ordre de
#                      saisie est préservé.
#   REQ_CERT_PEM       certificat public X.509 (PEM) — jamais de clé privée.
#                      Écrit en fichier .crt versionné dans la PR (jamais .pem
#                      — cf. le .gitignore racine du dépôt, "Secrets / env"),
#                      référencé par public_cert_ref (jamais la valeur en
#                      clair dans le YAML).
#   REQ_CERT_ROTATION  replace (défaut) | overlap — cf. rôle, sans objet si
#                      REQ_CERT_PEM est vide.
#
# v3 — CLÉ BACKEND (identifier `token`), TOUS OPTIONNELS. Attention au sens :
# ce `token` n'est PAS une identité ENTRANTE, c'est une clé SORTANTE app→backend.
# Le rôle REFUSE `token` dans `enforce` (BACKEND_KEY_ENFORCED) — d'où le fait que
# ces champs ne déclenchent PAS l'avertissement enforce du corps de PR.
#   REQ_BACKEND_KEY_REF    sous-chemin KV v2 de la clé (ex.
#                          deploy/<tenant>/apps/<app>/<env>/backend-key). Git ne
#                          porte JAMAIS la valeur : elle est lue à l'apply.
#                          L'entrée doit exister dans Vault AVANT l'apply — sinon
#                          BACKEND_KEY_MISSING et rien n'est posé (fail-closed du
#                          rôle).
#   REQ_BACKEND_KEY_FIELD  champ à lire DANS l'entrée KV ; vide = défaut du rôle
#                          (`api_key`). PIÈGE MESURÉ : une entrée dont la clé
#                          s'appelle `api-key` (avec un TIRET) est lue vide →
#                          BACKEND_KEY_MISSING alors que l'entrée existe.
#
# A1 (GOAL-cd-applications-2026-09-02) — LE MANIFESTE EST MULTI-PALIER. Ce
# script ne RÉÉCRIT plus le fichier : une demande `<app>` en `<env>` FUSIONNE sa
# clé `per_env.<env>` dans le manifeste lu sur GIT_BASE (ou le crée s'il
# n'existe pas) et ne touche à rien d'autre — pas un octet hors de cette ligne.
# L'identité d'une application est PAR PALIER (client_id `<app>-<env>`, cert,
# IP, clé backend), donc en mode idp la VALEUR de la claim vit sous
# `per_env.<env>.auth.claim.value` (le rôle la fusionne, consumer-auth.yml:61) ;
# la racine ne garde que `claim: { name: "azp" }`. Les champs TRANS-PALIERS
# (name, api, api_version, audience, mode, team) sont FIGÉS à la première
# demande : une demande qui les changerait est refusée (CONTRAT_DIVERGENT) —
# changer d'API consommée est une NOUVELLE application, pas une promotion
# (spike S1-T4 : `PUT …/apis` remplace la liste ; « une application = une API »
# est ce qui empêche une convergence de désinscrire en silence). Héritage :
# REQ_API_VER / REQ_AUDIENCE / REQ_TEAM ABSENTS sont hérités du manifeste
# existant (fournis = comparés). Un manifeste d'AVANT A1 (claim.value à la
# racine) est refusé (MANIFESTE_LEGACY), jamais migré par devinette. La
# substance vit dans scripts/lib/app-manifest.sh ; preuve :
# scripts/test-app-request-a1.sh.
set -uo pipefail
set +x   # jamais de trace : le token ne doit pas fuiter

# G4 (D6) : la liste d'environnements valides suit LA chaîne, jamais une liste
# en dur. Aucun `cd` n'a encore eu lieu ici (le clone/cd n'arrive qu'au [1/4],
# bien plus bas) : la source relative résout depuis le cwd d'appel, qui est
# `poc-control-plane-federation` (le job fait `dir('poc-control-plane-federation')`
# avant `bash scripts/provision-request.sh` — ci/Jenkinsfile.app-request,
# ci/jenkins/provisioning-request.job.xml).
. "scripts/lib/env-chain.sh" || { echo "ERREUR: scripts/lib/env-chain.sh introuvable ou illisible" >&2; exit 1; }
# A1 : lecture / contrat figé / fusion d'un palier du manifeste (même base
# de résolution que env-chain.sh : le cwd d'appel, avant tout cd).
. "scripts/lib/app-manifest.sh" || { echo "ERREUR: scripts/lib/app-manifest.sh introuvable ou illisible" >&2; exit 1; }

REQ_APP="${REQ_APP:?REQ_APP requis}"
REQ_ENV="${REQ_ENV:?REQ_ENV requis}"
REQ_API="${REQ_API:?REQ_API requis}"
# A1 : les défauts de version/audience ne valent que pour une PREMIÈRE demande ;
# sur un manifeste existant, absent = HÉRITÉ (résolu après le clone, [1/4]).
# On garde donc la saisie BRUTE à part — c'est elle qui décide « fourni » (donc
# comparé au contrat figé) ou « absent » (donc hérité).
REQ_API_VER_IN="${REQ_API_VER:-}"
REQ_AUDIENCE_IN="${REQ_AUDIENCE:-}"
REQ_API_VER="${REQ_API_VER_IN:-1.0.0}"
REQ_AUDIENCE="${REQ_AUDIENCE_IN:-$REQ_API}"
REQ_CALLER="${REQ_CALLER:-unknown}"
REQ_CLIENT_ID="${REQ_CLIENT_ID:-}"
REQ_TEAM="${REQ_TEAM:-}"
REQ_IP_ALLOWLIST="${REQ_IP_ALLOWLIST:-}"
REQ_CERT_PEM="${REQ_CERT_PEM:-}"
REQ_CERT_ROTATION="${REQ_CERT_ROTATION:-}"
REQ_BACKEND_KEY_REF="${REQ_BACKEND_KEY_REF:-}"
REQ_BACKEND_KEY_FIELD="${REQ_BACKEND_KEY_FIELD:-}"
TENANT="${TENANT:-banking-demo}"

# MODE = propriété de l'APPELANT, jamais du body (anti-spoof) : OIG provisionne
# (NB mesuré 2026-09-02 : sur la voie machine, REQ_CALLER est aujourd'hui `$.caller`
# du body — la gateway ne l'injecte pas encore depuis `azp` ; l'anti-spoof réel
# est la « step d'APIsation », cf. GOAL cd-applications / apisation-declencheur.)
# des apps mode IDP (client OAuth2 externe déjà sur l'IdP → Git porte la claim) ;
# CLI2 provisionne des apps mode INTERNAL (la gateway wM EST l'AS local, elle
# génère le client → le pipeline l'écrit dans Vault par env). La correspondance
# caller→mode est une table (surchargeable), PAS un champ de la requête.
#   REQ_MODE explicite (test, ou porte humaine — futur formulaire Jenkins qui
#   trace son appelant dans REQ_CALLER=jenkins-form:<userId>, hors table
#   caller→mode) > table par caller > défaut idp. Une valeur ni vide ni
#   idp|internal est un typo de la porte humaine : REFUS plutôt que dérivation
#   silencieuse (fail-closed — sinon un REQ_MODE mal orthographié retomberait
#   sur la dérivation par caller sans que personne ne le remarque).
case "${REQ_MODE:-}" in
  ""|idp|internal) ;;
  *) echo "REFUS: REQ_MODE='${REQ_MODE}' invalide (attendu idp|internal, ou vide)" >&2; exit 2;;
esac
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
# G4 (D6) : la liste suit la CHAÎNE, terminus exclu par structure (l'écriture
# d'app au terminus meurt en 403 depuis D3 — le formulaire ne ment plus).
# `fail()` n'est défini que plus bas : garde en echo/exit inline, comme le
# reste des gardes de ce bloc avant cette ligne.
CHAIN_NONPROD="$(env_chain_nonprod)" || { echo "REFUS: CHAINE_ILLISIBLE : env_chain_nonprod" >&2; exit 2; }
case " $CHAIN_NONPROD " in
  *" $REQ_ENV "*) : ;;
  *) echo "REFUS: ENV_INVALIDE : '$REQ_ENV' hors de la chaîne hors-terminus ($CHAIN_NONPROD)" >&2; exit 2;;
esac

# ── Task 4 (P3) — identité entrante : gardes AVANT tout geste Git ────────────
# Reprises verbatim du brief (tags d'échec inclus) : chaque garde est un no-op
# tant que le champ correspondant est vide (absent = comportement actuel).
fail(){ echo "REFUS: $*" >&2; exit 2; }

# ── A1 — champs FIGÉS interpolés dans une chaîne YAML entre guillemets ───────
# REQ_AUDIENCE n'était validée nulle part (elle héritait de REQ_API par défaut,
# validée, mais une valeur FOURNIE passait telle quelle dans `audience: "…"`) ;
# REQ_API_VER non plus. Désormais figées et COMPARÉES au contrat, elles doivent
# être sûres : l'audience admet `:` et `/` (une audience peut être une URI),
# jamais un guillemet, un antislash ni un retour-ligne.
if [ -n "$REQ_AUDIENCE_IN" ]; then
  case "$REQ_AUDIENCE_IN" in
    *[!A-Za-z0-9._:/-]*) fail "AUDIENCE_INVALID : '$REQ_AUDIENCE_IN' — caractères autorisés [A-Za-z0-9._:/-] uniquement";;
  esac
fi
if [ -n "$REQ_API_VER_IN" ]; then
  case "$REQ_API_VER_IN" in
    *[!A-Za-z0-9._-]*) fail "API_VERSION_INVALID : '$REQ_API_VER_IN' — caractères autorisés [A-Za-z0-9._-] uniquement";;
  esac
fi
# REQ_CALLER est interpolé dans l'en-tête ET la description du manifeste ; il
# vient du BODY du webhook (`$.caller`, provisioning-request.job.xml) ou du
# formulaire (`jenkins-form:<uid>`). Un retour-ligne ou un guillemet y
# injecterait des clés racine dans le YAML — que A1 figerait ensuite comme
# contrat. Classe : identifiants, `:` (jenkins-form:uid), `@` (uid mail).
case "$REQ_CALLER" in
  *[!A-Za-z0-9._:@-]*) fail "CALLER_INVALID : '$REQ_CALLER' — caractères autorisés [A-Za-z0-9._:@-] uniquement";;
esac

# ── v3 — IP ALLOWLIST MULTI-VALEURS ─────────────────────────────────────────
# Le rôle accepte une LISTE depuis toujours (defaults/main.yml : ip_allowlist:
# [] — ex. ["192.168.65.1", "10.0.0.1-10.0.0.5"]) ; seul ce script l'emballait
# en valeur unique. Le manque était donc ici et dans le formulaire, jamais dans
# le rôle.
#
# L'ORDRE DES GARDES S'INVERSE, et c'est le point structurant : jusqu'ici la
# classe de caractères s'appliquait à la saisie ENTIÈRE, ce qui interdisait
# mécaniquement tout séparateur (un retour-ligne comme une virgule est hors de
# [0-9A-Za-z.-]). On DÉCOUPE d'abord, on valide ENTRÉE PAR ENTRÉE ensuite. Les
# deux tags d'échec sont conservés à l'identique (ils sont opposés par les
# tests existants), mais leur message NOMME désormais l'entrée fautive : sur
# cinq lignes collées, « '10.0.0.1;rm' » est actionnable, « la saisie est
# invalide » ne l'est pas.
#
# La virgule est tolérée en plus du retour-ligne : un opérateur qui colle
# « a, b » depuis un ticket ne doit pas être puni pour ça.
IP_LIST=()
if [ -n "$REQ_IP_ALLOWLIST" ]; then
  while IFS= read -r _entry; do
    # trim des deux côtés (une zone de texte apporte des espaces parasites)
    _entry="${_entry#"${_entry%%[![:space:]]*}"}"
    _entry="${_entry%"${_entry##*[![:space:]]}"}"
    [ -n "$_entry" ] || continue   # ligne vide = séparateur, pas une erreur
    # CIDR : la gateway le drop EN SILENCE — refuser ici, bruyamment.
    case "$_entry" in
      */*) fail "IP_CIDR_REFUSE : '$_entry' — CIDR non supporté (drop silencieux gateway) — single ou plage A-B";;
    esac
    # Durcissement au-delà du brief : chaque entrée est interpolée telle quelle
    # dans un YAML (ip_allowlist: ["..."]) — un caractère hors [0-9A-Za-z.-]
    # (guillemet, point-virgule...) casserait ou détournerait le manifeste. Même
    # classe de garde que team-request.sh pour DESCRIPTION/REPO (refus, pas
    # échappement).
    case "$_entry" in
      *[!0-9A-Za-z.-]*) fail "IP_ALLOWLIST_INVALID : '$_entry' — caractères autorisés [0-9A-Za-z.-] uniquement";;
    esac
    # Dédoublonnage EXACT, ordre de saisie préservé : deux fois la même
    # dimension sur la gateway n'a aucun sens. `${a[@]+"${a[@]}"}` — et non
    # `"${a[@]}"` — parce que `set -u` fait échouer l'expansion d'un tableau
    # VIDE sur bash 3.2 (celui de macOS, où tourne la suite de tests).
    _dup=0
    for _seen in ${IP_LIST[@]+"${IP_LIST[@]}"}; do
      [ "$_seen" = "$_entry" ] && { _dup=1; break; }
    done
    [ "$_dup" = 1 ] || IP_LIST+=("$_entry")
  done <<< "$(printf '%s' "$REQ_IP_ALLOWLIST" | tr ',' '\n')"
fi

# ── v3 — CLÉ BACKEND : chemin Vault, JAMAIS la valeur ───────────────────────
# Le `/` est AUTORISÉ ici, contrairement à l'IP ci-dessus : c'est un sous-chemin
# KV, pas une plage. Les deux gardes restent donc SÉPARÉES — factoriser le refus
# CIDR avec celle-ci rendrait tout chemin Vault impossible.
if [ -n "$REQ_BACKEND_KEY_REF" ]; then
  case "$REQ_BACKEND_KEY_REF" in
    *[!A-Za-z0-9._/-]*) fail "BACKEND_KEY_REF_INVALID : '$REQ_BACKEND_KEY_REF' — caractères autorisés [A-Za-z0-9._/-] uniquement";;
    /*)                 fail "BACKEND_KEY_REF_INVALID : '$REQ_BACKEND_KEY_REF' — chemin ABSOLU refusé (sous-chemin KV relatif attendu)";;
    */)                 fail "BACKEND_KEY_REF_INVALID : '$REQ_BACKEND_KEY_REF' — se termine par '/' (chemin incomplet)";;
    *//*)               fail "BACKEND_KEY_REF_INVALID : '$REQ_BACKEND_KEY_REF' — '//' refusé (segment vide)";;
    *..*)               fail "BACKEND_KEY_REF_INVALID : '$REQ_BACKEND_KEY_REF' — traversée '..' refusée";;
  esac
fi
# Un champ sans son chemin est INERTE : le demandeur croit avoir configuré
# quelque chose et rien n'est lu. Refus loud plutôt que silence.
if [ -n "$REQ_BACKEND_KEY_FIELD" ]; then
  [ -n "$REQ_BACKEND_KEY_REF" ] || fail "BACKEND_KEY_FIELD_ORPHAN : backend_key_field='$REQ_BACKEND_KEY_FIELD' fourni SANS backend_key_ref — champ inerte, rien ne serait lu"
  case "$REQ_BACKEND_KEY_FIELD" in
    *[!A-Za-z0-9._-]*) fail "BACKEND_KEY_FIELD_INVALID : '$REQ_BACKEND_KEY_FIELD' — caractères autorisés [A-Za-z0-9._-] uniquement";;
  esac
fi
# On ne commite JAMAIS une clé privée — même collée par accident.
case "$REQ_CERT_PEM" in *"PRIVATE KEY"*) fail "CERT_PRIVATE_KEY_REFUSE";; esac
[ -n "$REQ_CERT_PEM" ] && { printf '%s' "$REQ_CERT_PEM" | grep -q -- '-----BEGIN CERTIFICATE-----' || fail "CERT_SANS_BLOC : PEM public X.509 attendu"; }
case "${REQ_CERT_ROTATION:-replace}" in replace|overlap) ;; *) fail "CERT_ROTATION_INVALIDE : replace|overlap";; esac

# REQ_TEAM : format identique à team-request.sh (^[a-z0-9][a-z0-9-]{1,30}$).
# L'appartenance (déclarée dans providers.<env>.yml) ne peut être vérifiée
# qu'après le clone (Step 2, il faut lire le fichier du dépôt) ; absent =
# hérité du manifeste s'il en porte une (A1), sinon TENANT reste "banking-demo"
# (défaut actuel, voie machine intacte).
if [ -n "$REQ_TEAM" ]; then
  case "$REQ_TEAM" in *[!a-z0-9-]*) fail "TEAM_NAME_INVALID : '$REQ_TEAM' — ^[a-z0-9][a-z0-9-]{1,30}\$ requis";; esac
  printf '%s' "$REQ_TEAM" | grep -Eq '^[a-z0-9][a-z0-9-]{1,30}$' \
    || fail "TEAM_NAME_INVALID : '$REQ_TEAM' — ^[a-z0-9][a-z0-9-]{1,30}\$ requis"
fi

BRANCH="provision/${REQ_APP}-${REQ_ENV}"
REL_PATH="${MANIFEST_DIR}/${REQ_APP}.ansible.yml"
WORK="$(mktemp -d /tmp/provreq.XXXXXX)"
# Chemin du script résolu AVANT tout `cd` : ce script se déplace dans le clone
# ($WORK/repo) pour rendre le manifeste, et un `dirname "$0"` relatif n'y
# résout plus. Piège déjà documenté dans provision-plan.sh — et reproduit ici
# malgré ça, parce que la garde du test ne couvrait que l'autre fichier.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
trap 'rm -rf "$WORK"' EXIT
# URL avec token EN MÉMOIRE seulement (jamais écrite dans le clone ni loggée).
PUSH_URL="http://ci:${GITEA_TOKEN}@${GIT_HOST#http://}/${GIT_REPO}.git"
API="${GIT_HOST}/api/v1"

echo "[1/4] clone ${GIT_REPO} (base ${GIT_BASE})"
CLONE_URL="http://${GIT_HOST#http://}/${GIT_REPO}.git"
# ÉCHEC NET SI LE CLONE RATE. Ce script n'a pas `set -e` (délibérément : les
# `[ -n "$X" ] && …` du rendu retournent faux sans être des erreurs). Sans la
# garde ci-dessous, un clone en échec laissait $WORK/repo INEXISTANT, le `cd`
# échouait… et le script CONTINUAIT dans le répertoire courant : il rendait le
# manifeste, faisait `git add`/`git commit` et POLLUAIT LE DÉPÔT DE TRAVAIL de
# l'appelant. Reproduit le 2026-08-07 par les contre-épreuves vertes hors ligne
# de test-app-request-v3.sh — les premières à franchir les gardes d'entrée sans
# réseau (six commits parasites dans le dépôt plateforme). La suite v2 ne
# pouvait pas le voir : toutes ses épreuves hors ligne sont des REFUS, qui
# sortent avant le clone.
if ! git clone -q --depth 1 -b "$GIT_BASE" "$CLONE_URL" "$WORK/repo" 2>/dev/null \
   && ! git clone -q --depth 1 "$CLONE_URL" "$WORK/repo"; then
  echo "ERREUR: clone impossible — ${GIT_REPO} injoignable sur ${GIT_HOST} (rien n'a été écrit)" >&2
  exit 1
fi
cd "$WORK/repo" || { echo "ERREUR: clone absent après succès annoncé — abandon avant toute écriture" >&2; exit 1; }
git config user.email "ci@bc.example"; git config user.name "provisioning (service ci)"

# ── A1 — le manifeste EXISTE-T-IL déjà sur GIT_BASE ? ───────────────────────
# Si oui : ses champs trans-paliers font CONTRAT. Absents de la demande,
# version / audience / team sont HÉRITÉS (un défaut dérivé à froid — `1.0.0`
# face à un manifeste en `2.0.0` — produirait une divergence mensongère) ;
# fournis, ils sont COMPARÉS. Tout ceci AVANT `git checkout -B` : un refus ne
# laisse ni branche locale ni distante — seul $WORK est jeté par le trap EXIT.
# La lib ÉCRIT son refus (REFUS: CONTRAT_DIVERGENT / MANIFESTE_LEGACY /
# MANIFESTE_INVALIDE) et rend 2 ; ce script tourne sans `set -e`, d'où le
# `|| exit 2` explicite sur chaque appel.
MAN_EXISTS=0; MAN_ENVS=""; TEAM_INHERITED=0
if [ -f "$REL_PATH" ]; then
  MAN_EXISTS=1
  MAN_OUT="$(app_manifest_read "$REL_PATH")" || exit 2
  MAN_API_VER=""; MAN_AUDIENCE=""; MAN_TEAM=""
  while IFS= read -r _l; do
    case "$_l" in
      MAN_API_VER=*)  MAN_API_VER="${_l#MAN_API_VER=}";;
      MAN_AUDIENCE=*) MAN_AUDIENCE="${_l#MAN_AUDIENCE=}";;
      MAN_TEAM=*)     MAN_TEAM="${_l#MAN_TEAM=}";;
      MAN_ENVS=*)     MAN_ENVS="${_l#MAN_ENVS=}";;
    esac
  done <<< "$MAN_OUT"
  # Héritage EXACT : la valeur du manifeste, même vide — un défaut « à froid »
  # (1.0.0, REQ_API) face à une valeur vide produirait une divergence mensongère.
  # (api/api_version ne peuvent pas être vides : bornés par la lib à la lecture.)
  [ -n "$REQ_API_VER_IN" ]  || REQ_API_VER="$MAN_API_VER"
  [ -n "$REQ_AUDIENCE_IN" ] || REQ_AUDIENCE="$MAN_AUDIENCE"
  TEAM_INHERITED=0
  if [ -z "$REQ_TEAM" ] && [ -n "$MAN_TEAM" ]; then
    REQ_TEAM="$MAN_TEAM"; TEAM_INHERITED=1
    echo "  team héritée du manifeste : ${REQ_TEAM} (figée à la première demande)"
  fi
  echo "  manifeste existant sur ${GIT_BASE} — paliers déclarés : ${MAN_ENVS:-(aucun)}"
  app_manifest_check_contract "$REL_PATH" "$REQ_APP" "$REQ_API" "$REQ_API_VER" "$REQ_AUDIENCE" "$MODE" "$REQ_TEAM" || exit 2
fi

# REQ_TEAM (suite) : l'appartenance ne se vérifie qu'ici — MAIS avant tout
# geste Git qui compte (aucune branche créée, aucun push tenté). Un échec ici
# laisse le dépôt distant intact (ls-remote inchangé), seul $WORK est jeté par
# le trap EXIT. S'applique à la team HÉRITÉE comme à une team fournie : le
# palier VISÉ doit la déclarer (providers.<env>.yml de CE palier).
if [ -n "$REQ_TEAM" ]; then
  PROV_FILE="poc-control-plane-federation/ansible/providers.${REQ_ENV}.yml"
  [ -f "$PROV_FILE" ] || fail "PROVIDERS_MISSING : ansible/providers.${REQ_ENV}.yml absent sur ${GIT_BASE}"
  # Chaîne FIXE, ligne ENTIÈRE (-Fx) : la team (fournie ou héritée) n'est
  # jamais interprétée comme regex — une valeur `.*` ou `(a|b)` ne matche rien.
  grep -Fxq -- "  - team: ${REQ_TEAM}" "$PROV_FILE" \
    || fail "TEAM_NOT_DECLARED : '${REQ_TEAM}' absent de providers.${REQ_ENV}.yml"
  TENANT="$REQ_TEAM"
fi

git checkout -q -B "$BRANCH"

if [ "$MAN_EXISTS" = 1 ]; then
  echo "[2/4] fusion de per_env.${REQ_ENV} dans ${REL_PATH} (mode ${MODE})"
else
  echo "[2/4] rendu du manifeste ${REL_PATH} (mode ${MODE}, première demande)"
fi
mkdir -p "$(dirname "$REL_PATH")"

# ── Task 4 (P3) — le certificat devient un fichier VERSIONNÉ dans la PR ─────
# Chemin dérivé de MANIFEST_DIR (sibling "certs" de "applications", même
# convention que les manifestes _example) : CERT_REL est la valeur posée dans
# public_cert_ref — RELATIVE À LA RACINE DU DÉPÔT (poc-control-plane-federation/),
# comme le fait déjà chaque manifeste _example (base 1 de cert-der.yml, cf.
# son en-tête) — CERT_FILE est le chemin DANS LE CLONE (racine = GIT_REPO,
# même construction que REL_PATH/MANIFEST_DIR qui portent déjà le préfixe
# poc-control-plane-federation/).
#
# ÉCART MESURÉ vs brief (qui donnait "<app>.pem" verbatim) : le .gitignore
# RACINE du dépôt ci/stoa-labs (pas celui de poc-control-plane-federation/)
# porte "*.pem" ET "*.key" sous "Secrets / env" — `git add` sur un .pem y est
# silencieusement IGNORÉ (mesuré : "The following paths are ignored...", rc
# non nul mais `set -uo pipefail` sans -e laisse le script continuer, PR
# ouverte SANS le fichier). Les manifestes _example du dépôt utilisent déjà
# `.crt` pour leurs certificats PUBLICS (demo-client.crt) — précisément pour
# ne jamais heurter cette règle. On suit cette convention DÉJÀ établie plutôt
# que de forcer `git add -f` (qui court-circuiterait sans le dire une garde
# d'hygiène "jamais de secret" que ce dépôt public applique délibérément) :
# extension .crt, jamais .pem, pour un certificat destiné à être versionné.
# A1 : le certificat est une identité PAR PALIER (per_env.<env>.public_cert_ref)
# — le fichier l'est donc aussi (`<app>-<env>.crt`) : une demande `rec` avec
# son propre certificat n'écrase jamais celui de `dev`.
CERT_DIR="$(dirname "$MANIFEST_DIR")/certs"
CERT_FILE="${CERT_DIR}/${REQ_APP}-${REQ_ENV}.crt"
CERT_REL="${CERT_FILE#poc-control-plane-federation/}"
if [ -n "$REQ_CERT_PEM" ]; then
  mkdir -p "$CERT_DIR"
  printf '%s\n' "$REQ_CERT_PEM" > "$CERT_FILE"
  chmod 0644 "$CERT_FILE"   # certificat PUBLIC (ADR-071) — pas un secret, versionné en clair
fi

# Blocs optionnels du manifeste — chacun un no-op (chaîne vide) tant que le
# champ correspondant est absent, pour une garantie octet pour octet (Step 4).
#
# `enforce` RESTE INTOUCHÉ ("[]", comportement pré-Task 4) — fix round 1
# (revue) : une première version le dérivait automatiquement
# (ipAddressRange/httpsCertificate) selon les champs fournis. Le README du
# rôle apim_selfservice_app (§enforce, mesuré en direct le 2026-07-31) est
# explicite : enforce est une propriété de l'API, PAS de l'application — deux
# applications consommant la MÊME API avec des enforce DIFFÉRENTS sont
# mutuellement exclusives (dernier apply gagne, l'action IAM de l'autre est
# SUPPRIMÉE), et le rôle n'a AUCUN garde-fou cross-consommateur pour ce cas
# (« tant que ce point n'est pas tranché », dixit le README). Dériver enforce
# depuis un formulaire self-service armait donc, pour tout demandeur qui
# remplit IP ou certificat, un piège documenté mais jamais tranché au niveau
# plateforme. La décision d'opposer réellement ipAddressRange/httpsCertificate
# est une décision AU NIVEAU DE L'API, qui doit se prendre AU MERGE (ADR-081 :
# la PR est la pièce d'audit) — pas être devinée par le formulaire. Les
# identifiers (ip_allowlist/public_cert_ref/cert_rotation) restent posés comme
# DONNÉES ; le corps de la PR porte l'avertissement (cf. plus bas,
# `enforce_warning` dans le bloc Python d'ouverture de PR).
TEAM_LINE=""
[ -n "$REQ_TEAM" ] && TEAM_LINE=$'  team: "'"${REQ_TEAM}"$'"\n'

# v3 — la liste validée est rendue en items YAML inline. NON-RÉGRESSION OCTET
# POUR OCTET : une entrée unique rend EXACTEMENT ip_allowlist: ["10.0.0.1"],
# comme la version mono-valeur (mêmes guillemets, même espacement), et une
# saisie vide ne produit AUCUN item — c'est ce que les golden files de la
# Section C de test-app-request-v2.sh opposent.
IP_ITEMS=""
for _e in ${IP_LIST[@]+"${IP_LIST[@]}"}; do
  IP_ITEMS="${IP_ITEMS:+$IP_ITEMS, }\"${_e}\""
done
# Forme aplatie pour le corps de PR (le manifeste, lui, prend IP_ITEMS).
IP_JOINED=""
for _e in ${IP_LIST[@]+"${IP_LIST[@]}"}; do
  IP_JOINED="${IP_JOINED:+$IP_JOINED, }${_e}"
done

# ── A1 — LA ligne du palier, commune aux deux modes ─────────────────────────
# Tout ce qui identifie l'application SUR CE PALIER tient sur UNE ligne YAML
# flow `    <env>: { … }` : c'est l'unité que la fusion remplace ou insère, et
# ce que la contre-épreuve « aucun octet hors de per_env.<env> » mesure.
#   idp      : la VALEUR de la claim (client_id du palier) — le rôle la fusionne
#              sous la racine `claim: { name }` (consumer-auth.yml:61) ;
#   internal : la gateway wM EST l'AS local, elle génère le client — le pipeline
#              l'écrit dans Vault PAR ENV au chemin conventionnel apps/<app>/<env>.
# Puis, seulement si fournis : ip_allowlist, public_cert_ref + cert_rotation
# (la rotation est une propriété du certificat, donc du palier — le rôle la lit
# APRÈS fusion, tasks/main.yml:222), backend_key_ref, backend_key_field (le
# principe de resolve-env.yml : IP, certificat et clé backend DIFFÈRENT par
# environnement, seule l'identité de l'app est invariante).
if [ "$MODE" = "internal" ]; then
  PER_ENV_AUTH="auth: { vault_sub: \"deploy/${TENANT}/apps/${REQ_APP}/${REQ_ENV}/oauth-client\" }"
else
  PER_ENV_AUTH="auth: { claim: { value: \"${REQ_CLIENT_ID}\" } }"
fi
PER_ENV_ITEMS=""
[ -n "$IP_ITEMS" ] && PER_ENV_ITEMS="${PER_ENV_ITEMS:+$PER_ENV_ITEMS, }ip_allowlist: [${IP_ITEMS}]"
[ -n "$REQ_CERT_PEM" ] && PER_ENV_ITEMS="${PER_ENV_ITEMS:+$PER_ENV_ITEMS, }public_cert_ref: \"${CERT_REL}\", cert_rotation: \"${REQ_CERT_ROTATION:-replace}\""
[ -n "$REQ_BACKEND_KEY_REF" ] && PER_ENV_ITEMS="${PER_ENV_ITEMS:+$PER_ENV_ITEMS, }backend_key_ref: \"${REQ_BACKEND_KEY_REF}\""
[ -n "$REQ_BACKEND_KEY_FIELD" ] && PER_ENV_ITEMS="${PER_ENV_ITEMS:+$PER_ENV_ITEMS, }backend_key_field: \"${REQ_BACKEND_KEY_FIELD}\""
PER_ENV_INLINE="{ ${PER_ENV_AUTH}${PER_ENV_ITEMS:+, $PER_ENV_ITEMS} }"

if [ "$MAN_EXISTS" = 1 ]; then
  # FUSION : seule la ligne `    <env>: …` bouge (remplacée si le palier était
  # déjà déclaré — re-demande —, insérée sinon). Refus = rien n'est écrit.
  app_manifest_merge_env "$REL_PATH" "$REQ_ENV" "$PER_ENV_INLINE" || exit 2
elif [ "$MODE" = "internal" ]; then
  # CLI2 : la gateway wM EST l'AS local ('local'), elle génère le client — le
  # pipeline l'écrit dans Vault PAR ENV (tenant+app+env-scopé). Pas de claim, pas
  # de secret dans Git ; vault_sub généré au chemin conventionnel apps/<app>/<env>.
  cat > "$REL_PATH" <<YAML
---
# ${REQ_APP}.ansible.yml — GÉNÉRÉ par une demande de provisioning (maillon 1).
# Appelant : ${REQ_CALLER} (azp). Ne PAS éditer à la main : re-générer via la demande.
# Mode INTERNAL : la gateway wM est l'authorization server ; elle génère le client
# (client_id/secret), le pipeline le STOCKE dans Vault par env — jamais dans Git.
# MULTI-PALIER (A1) : la racine est FIGÉE à la première demande ; chaque demande
# n'écrit que sa clé per_env.<env> (identité par palier : client, IP, cert, clé backend).
apim_ss_app:
  name: "${REQ_APP}"
  api: "${REQ_API}"
  api_version: "${REQ_API_VER}"
  description: "Provisioned via ${REQ_CALLER} (internal)"
  contact_emails: []
${TEAM_LINE}  enforce: []
  auth:
    mode: "internal"
    audience: "${REQ_AUDIENCE}"
  per_env:
    ${REQ_ENV}: ${PER_ENV_INLINE}
YAML
else
  # OIG : le client OAuth2 existe DÉJÀ côté IdP ; Git porte la CLAIM (azp) qui
  # identifie l'application sur la gateway — son NOM à la racine (trans-palier),
  # sa VALEUR par palier. Aucun secret (il vit sur l'IdP).
  cat > "$REL_PATH" <<YAML
---
# ${REQ_APP}.ansible.yml — GÉNÉRÉ par une demande de provisioning (maillon 1).
# Appelant : ${REQ_CALLER} (azp). Ne PAS éditer à la main : re-générer via la demande.
# Mode IDP : le client OAuth2 existe côté IdP ; Git porte la CLAIM qui identifie l'app.
# MULTI-PALIER (A1) : la racine est FIGÉE à la première demande ; chaque demande
# n'écrit que sa clé per_env.<env> (identité par palier : claim, IP, cert, clé backend).
apim_ss_app:
  name: "${REQ_APP}"
  api: "${REQ_API}"
  api_version: "${REQ_API_VER}"
  description: "Provisioned via ${REQ_CALLER} (idp)"
  contact_emails: []
${TEAM_LINE}  enforce: []
  auth:
    mode: "idp"
    server_alias: "KeycloakStoaLab"
    audience: "${REQ_AUDIENCE}"
    claim: { name: "azp" }
  per_env:
    ${REQ_ENV}: ${PER_ENV_INLINE}
YAML
fi
# Le manifeste CRÉÉ est relu par la même lecture que celle qui gouverne la
# fusion : ce que ce script rend doit être exactement ce qu'il saura relire
# (bornes, identité du palier, aucune clé racine parasite). Refus = rien n'est
# committé — un heredoc n'est pas une preuve.
app_manifest_read "$REL_PATH" >/dev/null || exit 2

if git diff --quiet -- "$REL_PATH" 2>/dev/null && git ls-files --error-unmatch "$REL_PATH" >/dev/null 2>&1; then
  echo "  (manifeste inchangé — demande idempotente)"
fi
git add "$REL_PATH"
[ -n "$REQ_CERT_PEM" ] && git add "$CERT_FILE"
# A1 — REJEU : la branche `provision/<app>-<env>` est recréée depuis GIT_BASE à
# chaque demande ; sans ce test, une demande rejouée à l'identique produisait
# un NOUVEAU commit (même arbre, autre date) et un push forcé — donc un
# événement `synchronized` et un plan de plus pour rien. Si la branche distante
# existe et porte déjà EXACTEMENT cet arbre, on ne commite ni ne pousse : la
# PR est réutilisée telle quelle. Lecture anonyme (comme le clone) ; branche
# absente = premier passage, on continue.
REMOTE_UP_TO_DATE=0
if git fetch -q --depth 1 "$CLONE_URL" "refs/heads/${BRANCH}" 2>/dev/null \
   && git diff --cached --quiet FETCH_HEAD -- . 2>/dev/null; then
  REMOTE_UP_TO_DATE=1
fi
if git diff --cached --quiet; then
  # L'index est IDENTIQUE à GIT_BASE : la demande est déjà mergée (per_env.<env>
  # présent sur la base). Il n'y a ni commit ni PR à ouvrir — et surtout pas de
  # POST /pulls sur une branche de tête qui n'existe plus (404 mesuré à la
  # critique : « supprimer la branche après merge » est un réglage courant).
  echo "[3/4] aucun changement : ${REQ_APP}/${REQ_ENV} est déjà sur ${GIT_BASE} (per_env.${REQ_ENV} présent) — aucune PR à ouvrir"
  echo "OK: demande ${REQ_APP}/${REQ_ENV} déjà mergée sur ${GIT_BASE}"
  exit 0
elif [ "$REMOTE_UP_TO_DATE" = 1 ]; then
  echo "[3/4] aucun changement à committer (branche ${BRANCH} déjà à jour — demande rejouée)"
else
  git commit -q -m "provision(${REQ_ENV}): application ${REQ_APP} (demande ${REQ_CALLER})"
  echo "[3/4] push ${BRANCH}"
  # Branche machine-owned (provision/*) : push explicite forcé, sûr ici (le flux
  # est le seul écrivain). 2>err pour ne jamais laisser le token fuiter au log.
  if ! git push -q --force "$PUSH_URL" "HEAD:refs/heads/${BRANCH}" 2>"$WORK/pusherr"; then
    echo "ERREUR push (détail masqué — token)" >&2; grep -v "$GITEA_TOKEN" "$WORK/pusherr" >&2 || true; exit 1
  fi
fi

echo "[4/5] ouverture de la Pull Request ${BRANCH} → ${GIT_BASE}"
# Interaction PR en PYTHON3 (portable — le conteneur Jenkins n'a pas jq) : liste
# idempotente (filtre côté client sur head.ref), création sinon. Le token n'est
# PAS en argv (passé par env GITEA_TOKEN) ; aucun secret imprimé.
PR_OUT=$(REQ_APP="$REQ_APP" REQ_ENV="$REQ_ENV" REQ_API="$REQ_API" REQ_API_VER="$REQ_API_VER" \
  REQ_CLIENT_ID="$REQ_CLIENT_ID" REQ_CALLER="$REQ_CALLER" MODE="$MODE" BRANCH="$BRANCH" GIT_BASE="$GIT_BASE" \
  API="$API" GIT_REPO="$GIT_REPO" GITEA_TOKEN="$GITEA_TOKEN" \
  REQ_TEAM="$REQ_TEAM" TEAM_INHERITED="$TEAM_INHERITED" REQ_IP_ALLOWLIST="$IP_JOINED" REQ_CERT_ROTATION="${REQ_CERT_ROTATION:-}" \
  REQ_CERT_PRESENT="$([ -n "$REQ_CERT_PEM" ] && echo 1 || echo 0)" CERT_REL="$CERT_REL" \
  REQ_BACKEND_KEY_REF="$REQ_BACKEND_KEY_REF" MAN_EXISTS="$MAN_EXISTS" MAN_ENVS="$MAN_ENVS" \
  python3 - <<'PY'
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
# Task 4 (P3) — identite entrante optionnelle : visible au valideur SEULEMENT
# si fournie (les champs absents ne produisent aucune ligne, symetrique au
# manifeste). Jamais le PEM en clair ici (deja dans le fichier de la PR).
extra = []
if os.environ.get("REQ_TEAM"):
    inh = " (heritee du manifeste, figee a la premiere demande)" if os.environ.get("TEAM_INHERITED") == "1" else ""
    extra.append(f"- equipe (cloisonnement) : {os.environ['REQ_TEAM']}{inh}")
if os.environ.get("REQ_IP_ALLOWLIST"):
    extra.append(f"- IP allowlist : {os.environ['REQ_IP_ALLOWLIST']}")
if os.environ.get("REQ_CERT_PRESENT") == "1":
    extra.append(f"- certificat public : {os.environ['CERT_REL']} "
                  f"(rotation : {os.environ.get('REQ_CERT_ROTATION') or 'replace'})")
# v3 — cle backend : ligne A PART, et surtout PAS dans enforce_warning
# ci-dessous. Ce n'est pas cosmetique : cet avertissement parle des identites
# ENTRANTES opposables (ipAddressRange/httpsCertificate) et previent que enforce
# reste []. La cle backend est SORTANTE (app->backend) et le role INTERDIT
# `token` dans enforce (BACKEND_KEY_ENFORCED) : l'y faire tomber dirait au
# valideur l'exact contraire du vrai.
if os.environ.get("REQ_BACKEND_KEY_REF"):
    extra.append(f"- cle backend (sortante, identifier token) : "
                 f"{os.environ['REQ_BACKEND_KEY_REF']} (valeur JAMAIS en Git, "
                 f"lue dans Vault a l'apply)")
# A1 — le valideur voit si la PR CRÉE le manifeste ou n'y FUSIONNE qu'un
# palier, et lesquels étaient déjà déclarés (le manifeste est la liste des
# paliers d'une application).
if os.environ.get("MAN_EXISTS") == "1":
    envs = ", ".join(os.environ.get("MAN_ENVS", "").split()) or "(aucun)"
    extra.append(f"- manifeste : per_env.{os.environ['REQ_ENV']} fusionné — paliers déjà déclarés : {envs}")
else:
    extra.append("- manifeste : première demande (créé)")
extra_txt = ("\n" + "\n".join(extra)) if extra else ""
# Fix round 1 (revue) — AVERTISSEMENT DES DEUX PIEGES, visible pour
# l'approbateur, seulement si une dimension d'identite entrante est fournie
# (IP ou certificat) : enforce n'est PLUS derive automatiquement (cf. le
# commentaire plus haut, pres du bloc "Blocs optionnels du manifeste"). La
# decision d'opposer reellement ces identifiers reste au MERGE, jamais au
# formulaire.
enforce_warning = ""
if os.environ.get("REQ_IP_ALLOWLIST") or os.environ.get("REQ_CERT_PRESENT") == "1":
    enforce_warning = (
        "\n\n:warning: IDENTITE ENTRANTE POSEE, ENFORCE NON MODIFIE : les "
        "identifiers ci-dessus sont poses comme donnees mais PAS opposes a "
        "l'execution (enforce reste [] par defaut) ; activer ipAddressRange/"
        "httpsCertificate est une decision AU NIVEAU DE L'API, pas de cette "
        "application (risque cross-consommateur documente, README "
        "apim_selfservice_app Sec enforce : deux applications de la MEME API "
        "avec des enforce differents sont mutuellement exclusives, dernier "
        "apply gagne) — a trancher explicitement au merge, pas silencieusement "
        "ici.")
bodytxt = ("Demande de provisioning application.\n\n"
    f"- application : {os.environ['REQ_APP']}\n- environnement : {os.environ['REQ_ENV']}\n"
    f"- mode : {mode}\n- API consommee : {os.environ['REQ_API']} v{os.environ['REQ_API_VER']}\n"
    f"{ident}\n- demandeur (azp) : {os.environ['REQ_CALLER']}{extra_txt}{enforce_warning}\n\n"
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

# ── PLAN ENCHAÎNÉ (ADR-081, corollaire 1) ────────────────────────────────────
# Le demandeur avait TROIS endroits à regarder : son build, la PR dans la forge,
# puis un autre build pour le plan. On enchaîne donc le plan ICI : un seul build
# lui donne la PR ET son verdict.
#
# C'est un APPEL du script existant, pas une réécriture : provision-plan.sh est
# déjà paramétré par PR_BRANCH/PR_NUMBER et déjà idempotent (upsert par
# marqueur), donc rejouable sans empiler de commentaires.
#
# LE WEBHOOK `opened` EST CONSERVÉ, et le double passage est DÉLIBÉRÉ. Le
# supprimer laisserait sans plan toute PR ouverte à la main sous provision/* —
# le valideur mergerait alors sans verdict. Le commentaire étant un upsert, le
# second passage met à jour le premier au lieu de le doubler ; le coût est un
# build, le bénéfice est qu'aucun chemin d'ouverture n'échappe au plan.
#
# NE FAIT PAS ÉCHOUER LA DEMANDE. Un plan rouge est une information à porter au
# valideur, pas une raison d'annuler une PR déjà ouverte et poussée : le
# manifeste existe, la PR aussi, et c'est précisément ce qu'il faut corriger
# puis repousser. Le verdict est repris dans la sortie ci-dessous.
if [ "${PROVISION_PLAN_INLINE:-true}" = "true" ]; then
  echo "[5/5] plan enchaîné sur la PR #${PR_NUM}"
  if PR_BRANCH="$BRANCH" PR_NUMBER="$PR_NUM" \
     bash "$SELF_DIR/provision-plan.sh"; then
    echo "  PLAN_INLINE=ok"
  else
    echo "  PLAN_INLINE=fail — la PR est ouverte et commentée, la demande reste valide" >&2
  fi
else
  echo "[5/5] plan enchaîné DÉSACTIVÉ (PROVISION_PLAN_INLINE=false) — le webhook s'en charge"
fi

echo "OK: demande ${REQ_APP}/${REQ_ENV} → manifeste + MR${PROVISION_PLAN_INLINE:+ + plan}"
