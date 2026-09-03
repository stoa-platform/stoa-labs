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
# A7 : l'identité de forge (login du token nominatif, askpass par fichier).
# shellcheck source=scripts/lib/forge-identity.sh
. "scripts/lib/forge-identity.sh" || { echo "ERREUR: scripts/lib/forge-identity.sh introuvable ou illisible" >&2; exit 1; }
# A1 : lecture / contrat figé / fusion d'un palier du manifeste (même base
# de résolution que env-chain.sh : le cwd d'appel, avant tout cd).
. "scripts/lib/app-manifest.sh" || { echo "ERREUR: scripts/lib/app-manifest.sh introuvable ou illisible" >&2; exit 1; }

# Un champ OBLIGATOIRE vide se refuse en SE NOMMANT, comme tous les autres refus
# de la chaîne — jamais par le `${VAR:?}` de bash, qui rend « <script>: line N:
# REQ_APP: REQ_APP requis » : un numéro de ligne de shell et une variable INTERNE,
# là où le demandeur a rempli un formulaire dont le champ porte un autre nom
# (mesuré en lab le 2026-09-03, app-request #47 : demande à APP vide).
# Une valeur BLANCHE n'est pas une valeur : Jenkins rend '' pour un champ omis,
# jamais null, et un espace seul passerait `-n` pour mourir plus loin sur la
# garde de caractères, qui parle d'un contenu que le demandeur n'a pas saisi.
requis(){ case "${2//[[:space:]]/}" in "") echo "REFUS: CHAMP_REQUIS : $1 est vide — obligatoire ($3). Rien n'a été tenté." >&2; exit 2;; esac; }
REQ_APP="${REQ_APP:-}"; requis REQ_APP "$REQ_APP" "formulaire app-request : champ « APP », le nom de l'application demandée"
REQ_ENV="${REQ_ENV:-}"; requis REQ_ENV "$REQ_ENV" "formulaire app-request : champ « REQ_ENV », le palier visé"
REQ_API="${REQ_API:-}"; requis REQ_API "$REQ_API" "formulaire app-request : champ « API », l'API consommée (nom@version)"
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
# Pas de tenant par défaut : cette valeur entre dans `auth.vault_sub` du manifeste,
# qui est COMMITÉ — un défaut de lab s'écrirait dans le dépôt du client.
TENANT="${TENANT:-}"

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
  echo "REFUS: CHAMP_REQUIS : REQ_CLIENT_ID est vide alors que REQ_MODE=idp — obligatoire dans ce mode (formulaire app-request : champ « CLIENT_ID », la claim azp qui identifie l'app). Rien n'a été tenté." >&2; exit 2
fi
GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN requis}"
# ── A7 — LES TOKENS, par FICHIER, et le token humain RETIRÉ de l'environnement ──
# FORGE_TOKEN (formulaire, canal natif Jenkins) ou FORGE_TOKEN_FILE : l'identité
# de forge du demandeur. Copié dans un fichier 0600 puis `unset` AVANT tout
# processus enfant (python, git, le plan enchaîné) : aucun d'eux ne doit le voir.
# Le token de service (GITEA_TOKEN) reste celui des lectures et du plan.
umask 077
TOKENS_DIR="$(mktemp -d /tmp/provreq-tok.XXXXXX)"
trap 'rm -rf "$TOKENS_DIR"' EXIT
FORGE_TF=""
if [ -n "${FORGE_TOKEN_FILE:-}" ] && [ -s "${FORGE_TOKEN_FILE}" ]; then
  FORGE_TF="$TOKENS_DIR/forge"; tr -d '\r\n' < "$FORGE_TOKEN_FILE" > "$FORGE_TF"
elif [ -n "${FORGE_TOKEN:-}" ]; then
  FORGE_TF="$TOKENS_DIR/forge"; printf '%s' "$FORGE_TOKEN" > "$FORGE_TF"
fi
unset FORGE_TOKEN FORGE_TOKEN_FILE
CI_TF="$TOKENS_DIR/ci"; printf '%s' "$GITEA_TOKEN" > "$CI_TF"
GITEA_SERVICE_LOGINS="${GITEA_SERVICE_LOGINS:-ci}"
REQ_CHANGE_REF="${REQ_CHANGE_REF:-}"
REQ_PV_REF="${REQ_PV_REF:-}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
GIT_BASE="${GIT_BASE:-main}"
# Aucun repli vers le lab : un client dont le pipeline ne transmet pas la variable
# doit le lire ici, pas découvrir plus tard que la chaîne a visé « gitea:3000 ».
GIT_HOST="${GIT_HOST:?GIT_HOST requis (base de la forge, ex. https://forge.client) — aucun repli}"
GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"   # l'adresse HUMAINE, si elle diffère de celle vue par le CI
# Disposition du dépôt (2026-09-03) : MANIFEST_DIR est RELATIF au livrable, le
# préfixe du monorepo vit dans GIT_SUBDIR — contrat déjà écrit par
# provision-apply-reconcile.sh, ici généralisé. Un chemin vu de la racine du
# clone se compose « ${SUB_PFX}${MANIFEST_DIR}/… ».
# shellcheck source=scripts/lib/repo-layout.sh
. "scripts/lib/repo-layout.sh" || { echo "ERREUR: scripts/lib/repo-layout.sh introuvable ou illisible" >&2; exit 1; }
repo_layout_init || exit 2
MANIFEST_DIR="${MANIFEST_DIR:-clients/provisioned/applications}"

# Garde-fous d'entrée : noms sûrs (pas d'injection dans un path/branche/YAML).
# REQ_CLIENT_ID est optionnel (internal) → validé seulement s'il est fourni.
for v in REQ_APP REQ_ENV REQ_API REQ_CLIENT_ID; do
  val="${!v}"
  [ -n "$val" ] || continue
  case "$val" in
    *[!A-Za-z0-9._-]*) echo "REFUS: $v='$val' contient un caractère non autorisé ([A-Za-z0-9._-])" >&2; exit 2;;
  esac
done
# A7 (D5) : la liste est la chaîne ENTIÈRE, terminus compris — le terminus n'est
# plus exclu par structure, il est gardé par ses portes (refs, quatre yeux, ITSM,
# voie déclarée, credential, déployeur). La chaîne est VALIDÉE avant d'être lue
# (A4 D0) ; `fail()` n'est défini que plus bas : garde en echo/exit inline.
env_chain_validate 2>/dev/null || { echo "REFUS: CHAINE_INVALIDE : environments.yaml ne passe pas env_chain_validate" >&2; exit 2; }
CHAIN="$(env_chain)" || { echo "REFUS: CHAINE_ILLISIBLE : env_chain" >&2; exit 2; }
case " $CHAIN " in
  *" $REQ_ENV "*) : ;;
  *) echo "REFUS: ENV_INVALIDE : '$REQ_ENV' hors de la chaîne ($CHAIN)" >&2; exit 2;;
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

# ── A7 (D4) — LES RÉFÉRENCES À LA DEMANDE : la classe de la porte A4, mot pour mot ──
# change_ref / pv_ref deviennent un segment d'URL ITSM (porte A4 §2) : classe
# ^[A-Za-z0-9][A-Za-z0-9._-]*$, jamais `.`, `..` ni un segment commençant par `.`.
# Si la porte du palier les exige (requireChangeRef|itsmCheck, requirePVRef) et
# qu'ils manquent : GATE_REFS_REQUIRED au plus tôt — aucune PR ouverte (motif A6).
ref_ok(){ [ -z "$1" ] && return 0; printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' && ! printf '%s' "$1" | grep -Eq '(^|/)\.'; }
ref_ok "$REQ_CHANGE_REF" || fail "REF_INVALIDE : change_ref '$REQ_CHANGE_REF' hors de ^[A-Za-z0-9][A-Za-z0-9._-]*\$ (il deviendrait un segment d'URL ITSM)"
ref_ok "$REQ_PV_REF"     || fail "REF_INVALIDE : pv_ref '$REQ_PV_REF' hors de ^[A-Za-z0-9][A-Za-z0-9._-]*\$"
GATE="$(env_chain_gate "$REQ_ENV")" || fail "CHAINE_INVALIDE : porte de '$REQ_ENV' illisible"
NEED_CHANGE="${GATE#GATE=}"; NEED_CHANGE="${NEED_CHANGE%%|*}"
NEED_PV="${GATE#GATE=*|}";   NEED_PV="${NEED_PV%%|*}"
[ "$NEED_CHANGE" != 1 ] || [ -n "$REQ_CHANGE_REF" ] \
  || fail "GATE_REFS_REQUIRED : la porte vers '$REQ_ENV' exige change_ref à la demande (requireChangeRef ou itsmCheck) — aucune PR ouverte"
[ "$NEED_PV" != 1 ] || [ -n "$REQ_PV_REF" ] \
  || fail "GATE_REFS_REQUIRED : la porte vers '$REQ_ENV' exige pv_ref à la demande (requirePVRef) — aucune PR ouverte"
FOUREYES="$(env_chain_gate_four_eyes "$REQ_ENV")" || fail "CHAINE_INVALIDE : fourEyes de '$REQ_ENV' illisible"
FOUREYES="${FOUREYES#FOUREYES=}"

# ── A7 (D3) — L'IDENTITÉ DE FORGE : le porteur du token nominatif EST l'auteur ──
# Sans token humain, il n'y a pas d'humain : le job n'a qu'un token de service,
# aucun appel n'est fait, l'identité vaut `(service)`. Avec : GET /user (scope
# read:user) — un refus nommé (rc 2 : token invalide, scope insuffisant, login
# hors classe) ou une ERREUR (rc 1 : réseau). Sous fourEyes, une demande sans
# humain est refusée ICI, au plus tôt : la porte A4 la refuserait REQUESTER_UNKNOWN
# au dispatch, après avoir réveillé un mergeur pour rien.
API="${GIT_HOST}/api/v1"
FORGE_LOGIN="(service)"
if [ -n "$FORGE_TF" ]; then
  FORGE_LOGIN="$(forge_login "$API" "$FORGE_TF")" || { rc=$?; [ "$rc" = 2 ] && exit 2; exit 1; }
  forge_is_service "$FORGE_LOGIN" "$GITEA_SERVICE_LOGINS" && FORGE_LOGIN="(service)"
fi
if [ "$FOUREYES" = 1 ] && [ "$FORGE_LOGIN" = "(service)" ]; then
  fail "REQUESTER_UNKNOWN : la porte vers '$REQ_ENV' exige les quatre yeux ; une PR ouverte par un compte de service (${GITEA_SERVICE_LOGINS}) serait refusée REQUESTER_UNKNOWN à l'apply — fournir FORGE_TOKEN (formulaire : votre token de forge, scopes read:user + write:repository) ; voie machine : décision client n°3 — aucune PR ouverte"
fi
# Le login du pousseur : l'humain, ou `ci` (le compte de service de ce lab) — il
# n'entre que dans l'askpass et le trailer, jamais dans une URL.
PUSH_LOGIN="$FORGE_LOGIN"; [ "$PUSH_LOGIN" = "(service)" ] && PUSH_LOGIN=ci
PUSH_TF="${FORGE_TF:-$CI_TF}"

BRANCH="provision/${REQ_APP}-${REQ_ENV}"
REL_PATH="${SUB_PFX}${MANIFEST_DIR}/${REQ_APP}.ansible.yml"
WORK="$(mktemp -d /tmp/provreq.XXXXXX)"
# Chemin du script résolu AVANT tout `cd` : ce script se déplace dans le clone
# ($WORK/repo) pour rendre le manifeste, et un `dirname "$0"` relatif n'y
# résout plus. Piège déjà documenté dans provision-plan.sh — et reproduit ici
# malgré ça, parce que la garde du test ne couvrait que l'autre fichier.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
trap 'rm -rf "$WORK" "$TOKENS_DIR"' EXIT
# A7 : AUCUNE URL ne porte de credential. Le push s'authentifie par GIT_ASKPASS
# (login du pousseur + token lu dans le fichier) — jamais en argv, jamais dans un
# message d'erreur, jamais dans l'environnement d'un enfant.
# Le schéma de GIT_HOST est CONSERVÉ (2026-09-03) : « http:// » était forcé en
# tête après avoir retiré le seul préfixe http://, ce qui produisait littéralement
# « http://https://forge.client/... » sur une forge en TLS — et l'erreur de push
# étant filtrée des deux jetons, le message n'en disait rien. Forme reprise mot
# pour mot de provision-plan.sh (même dépôt, bug déjà nommé là-bas).
case "$GIT_HOST" in http://*|https://*|file://*) GIT_BASE_URL="${GIT_HOST%/}";; *) GIT_BASE_URL="http://${GIT_HOST%/}";; esac
PUSH_URL="${GIT_BASE_URL}/${GIT_REPO}.git"
GIT_ASKPASS="$(forge_askpass "$TOKENS_DIR" "$PUSH_LOGIN" "$PUSH_TF")" || { echo "ERREUR: askpass" >&2; exit 1; }
export GIT_ASKPASS GIT_TERMINAL_PROMPT=0

echo "[1/4] clone ${GIT_REPO} (base ${GIT_BASE})"
CLONE_URL="${GIT_BASE_URL}/${GIT_REPO}.git"
# A6 : les deux URL git sont surchargeables (épreuves hors ligne sur un dépôt nu en file://) — défauts = inchangés.
CLONE_URL="${GIT_CLONE_URL:-$CLONE_URL}"; PUSH_URL="${GIT_PUSH_URL:-$PUSH_URL}"
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
git config user.email "${CI_COMMIT_EMAIL:-ci@bc.example}"; git config user.name "${CI_COMMIT_NAME:-provisioning (service ci)}"

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
CERT_DIR="${SUB_PFX}$(dirname "$MANIFEST_DIR")/certs"
CERT_FILE="${CERT_DIR}/${REQ_APP}-${REQ_ENV}.crt"
CERT_REL="${CERT_FILE#"$SUB_PFX"}"
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
  # TENANT n'a plus de valeur par défaut (2026-09-03) : elle s'écrivait dans le
  # manifeste COMMITÉ. Sans équipe déclarée, le chemin de coffre serait « deploy//apps/… ».
  [ -n "$TENANT" ] || fail "TENANT_INDETERMINE : mode internal sans equipe — le chemin de coffre du client ne peut pas etre derive (fournir TEAM, ou TENANT au job)"
  PER_ENV_AUTH="auth: { vault_sub: \"deploy/${TENANT}/apps/${REQ_APP}/${REQ_ENV}/oauth-client\" }"
else
  PER_ENV_AUTH="auth: { claim: { value: \"${REQ_CLIENT_ID}\" } }"
fi
PER_ENV_ITEMS=""
[ -n "$IP_ITEMS" ] && PER_ENV_ITEMS="${PER_ENV_ITEMS:+$PER_ENV_ITEMS, }ip_allowlist: [${IP_ITEMS}]"
[ -n "$REQ_CERT_PEM" ] && PER_ENV_ITEMS="${PER_ENV_ITEMS:+$PER_ENV_ITEMS, }public_cert_ref: \"${CERT_REL}\", cert_rotation: \"${REQ_CERT_ROTATION:-replace}\""
[ -n "$REQ_BACKEND_KEY_REF" ] && PER_ENV_ITEMS="${PER_ENV_ITEMS:+$PER_ENV_ITEMS, }backend_key_ref: \"${REQ_BACKEND_KEY_REF}\""
[ -n "$REQ_BACKEND_KEY_FIELD" ] && PER_ENV_ITEMS="${PER_ENV_ITEMS:+$PER_ENV_ITEMS, }backend_key_field: \"${REQ_BACKEND_KEY_FIELD}\""
# A7 (D4) : les références de la porte, PAR PALIER, seulement si fournies (octet
# pour octet sinon) — la forme quotée que la porte A4 relit (safe_load) et que le
# repli (A6) remplace.
[ -n "$REQ_CHANGE_REF" ] && PER_ENV_ITEMS="${PER_ENV_ITEMS:+$PER_ENV_ITEMS, }change_ref: \"${REQ_CHANGE_REF}\""
[ -n "$REQ_PV_REF" ] && PER_ENV_ITEMS="${PER_ENV_ITEMS:+$PER_ENV_ITEMS, }pv_ref: \"${REQ_PV_REF}\""
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
# ── A6 (D1bis) — une demande ne réécrit JAMAIS une PR de repli ouverte ────────
# La branche provision/<app>-<env> est poussée en force plus bas : si une PR de
# REPLI y est ouverte (auteur = compte de service, tête portant le trailer
# Repli-Vers: — relu par git sur FETCH_HEAD, jamais dans le corps éditable de la
# PR), la réécrire ferait merger une demande sous un titre « repli ». Refus,
# rien poussé. La tête relue devient le BAIL du push (--force-with-lease).
REMOTE_TIP=""
if git fetch -q --depth 1 "$CLONE_URL" "refs/heads/${BRANCH}" 2>/dev/null; then REMOTE_TIP=$(git rev-parse FETCH_HEAD 2>/dev/null || true); fi
# ── A7 (hypothèse 10) — LA PR OUVERTE DE LA BRANCHE, relue AVANT le push ──────
# Une PR ouverte n'appartient qu'à son auteur : la réutiliser (EXIST) sous une
# autre identité ferait signer par un tiers un contenu poussé par un autre (le
# force-push réécrirait la branche sous le nom d'autrui). La forge est relue
# avec le token de SERVICE (par fichier), paginée, head.ref exact, même dépôt ;
# illisible ⇒ fail-closed (une PR ouverte pourrait exister). Ordre : d'abord
# REPLI_EN_COURS (A6 — désormais quel que soit l'auteur : A7 rend les PR de
# repli humaines), puis PR_D_AUTRUI.
OPEN_BY=$(API="$API" GIT_REPO="$GIT_REPO" CI_TOKEN_FILE="$CI_TF" BRANCH="$BRANCH" python3 - <<'PY2'
import os, json, urllib.request
api, repo, br = os.environ["API"], os.environ["GIT_REPO"], os.environ["BRANCH"]
tok = open(os.environ["CI_TOKEN_FILE"]).read().strip()
page = 1
while True:
    r = urllib.request.Request(f"{api}/repos/{repo}/pulls?state=open&limit=50&page={page}", headers={"Authorization": "token " + tok})
    with urllib.request.urlopen(r, timeout=30) as resp: prs = json.load(resp)
    if not isinstance(prs, list) or not prs: break
    for pr in prs:
        h = pr.get("head") or {}
        if h.get("ref") == br and (h.get("repo") or {}).get("full_name") == repo:
            print("%s %s" % (pr.get("number"), (pr.get("user") or {}).get("login", ""))); raise SystemExit
    page += 1
print("")
PY2
) || fail "FORGE_ILLISIBLE : la forge n'a pas pu être relue — une PR ouverte pourrait exister sur ${BRANCH}, rien n'est poussé"
OPEN_NUM="${OPEN_BY%% *}"; OPEN_LOGIN="${OPEN_BY#* }"
if [ -n "$REMOTE_TIP" ] && git log -1 --format=%B "$REMOTE_TIP" 2>/dev/null | grep -q '^Repli-Vers: '; then
  # Le trailer EST la preuve ; la forge ne fait que nommer la PR (A6 D1bis).
  [ -z "$OPEN_NUM" ] || fail "REPLI_EN_COURS : la PR #${OPEN_NUM} (${OPEN_LOGIN:-auteur inconnu}) est un repli ouvert sur ${BRANCH} — la merger ou la fermer avant une nouvelle demande"
fi
if [ -n "$OPEN_NUM" ]; then
  MINE=0
  if [ "$FORGE_LOGIN" = "(service)" ]; then forge_is_service "$OPEN_LOGIN" "$GITEA_SERVICE_LOGINS" && MINE=1
  else [ "$OPEN_LOGIN" = "$FORGE_LOGIN" ] && MINE=1; fi
  [ "$MINE" = 1 ] || fail "PR_D_AUTRUI : la PR #${OPEN_NUM} ouverte sur ${BRANCH} appartient à '${OPEN_LOGIN}' — la fermer, ou la merger si le palier l'admet, avant de redemander sous une autre identité ; rien n'est poussé"
fi
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
  # A7 : le trailer Demande-Par nomme le pousseur (informatif — l'autorité est
  # l'auteur de la PR relu sur la forge par la porte A4).
  git commit -q -m "provision(${REQ_ENV}): application ${REQ_APP} (demande ${REQ_CALLER})" -m "Demande-Par: ${PUSH_LOGIN}"
  echo "[3/4] push ${BRANCH}"
  # Branche machine-owned (provision/*) : push explicite forcé, sûr ici (le flux
  # est le seul écrivain). 2>err pour ne jamais laisser un token fuiter au log —
  # l'erreur est filtrée des DEUX tokens (celui qui a poussé, celui du service).
  if ! git push -q "--force-with-lease=refs/heads/${BRANCH}:${REMOTE_TIP}" "$PUSH_URL" "HEAD:refs/heads/${BRANCH}" 2>"$WORK/pusherr"; then
    echo "ERREUR push (détail masqué — token)" >&2
    grep -v -F -- "$(cat "$PUSH_TF")" "$WORK/pusherr" | grep -v -F -- "$GITEA_TOKEN" >&2 || true; exit 1
  fi
fi

echo "[4/5] ouverture de la Pull Request ${BRANCH} → ${GIT_BASE}"
# Interaction PR en PYTHON3 (portable — le conteneur Jenkins n'a pas jq) : liste
# idempotente (filtre côté client sur head.ref), création sinon. Le token n'est
# PAS en argv (passé par env GITEA_TOKEN) ; aucun secret imprimé.
PR_OUT=$(REQ_APP="$REQ_APP" REQ_ENV="$REQ_ENV" REQ_API="$REQ_API" REQ_API_VER="$REQ_API_VER" \
  REQ_CLIENT_ID="$REQ_CLIENT_ID" REQ_CALLER="$REQ_CALLER" MODE="$MODE" BRANCH="$BRANCH" GIT_BASE="$GIT_BASE" \
  API="$API" GIT_REPO="$GIT_REPO" CI_TOKEN_FILE="$CI_TF" PR_TOKEN_FILE="$PUSH_TF" PUSH_LOGIN="$PUSH_LOGIN" \
  REQ_CHANGE_REF="$REQ_CHANGE_REF" REQ_PV_REF="$REQ_PV_REF" \
  REQ_TEAM="$REQ_TEAM" TEAM_INHERITED="$TEAM_INHERITED" REQ_IP_ALLOWLIST="$IP_JOINED" REQ_CERT_ROTATION="${REQ_CERT_ROTATION:-}" \
  REQ_CERT_PRESENT="$([ -n "$REQ_CERT_PEM" ] && echo 1 || echo 0)" CERT_REL="$CERT_REL" \
  REQ_BACKEND_KEY_REF="$REQ_BACKEND_KEY_REF" MAN_EXISTS="$MAN_EXISTS" MAN_ENVS="$MAN_ENVS" \
  python3 - <<'PY'
import os, json, urllib.request, urllib.error, sys
api, repo = os.environ["API"], os.environ["GIT_REPO"]
# A7 : les lectures sous le token de SERVICE, le POST /pulls sous celui du
# POUSSEUR (l'humain quand il y en a un) — l'auteur de la PR est son identité.
ci_tok = open(os.environ["CI_TOKEN_FILE"]).read().strip()
pr_tok = open(os.environ["PR_TOKEN_FILE"]).read().strip()
branch, base = os.environ["BRANCH"], os.environ["GIT_BASE"]
def req(method, url, data=None, tok=ci_tok):
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
# A7 : l'identite de forge qui a ouvert la PR — c'est elle que la porte a quatre
# yeux (A4) confronte au mergeur ; un compte de service ne nomme personne.
who = os.environ.get("PUSH_LOGIN", "ci")
if who != "ci":
    extra.append("- ouverte par : %s (identite de forge — c'est elle que la porte a quatre yeux confronte au mergeur)" % who)
else:
    extra.append("- ouverte par : compte de service (une porte a quatre yeux refusera REQUESTER_UNKNOWN)")
if os.environ.get("REQ_CHANGE_REF"):
    extra.append("- change_ref : %s" % os.environ["REQ_CHANGE_REF"])
if os.environ.get("REQ_PV_REF"):
    extra.append("- pv_ref : %s" % os.environ["REQ_PV_REF"])
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
             {"title": title, "head": branch, "base": base, "body": bodytxt}, tok=pr_tok)
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
PR_URL="${GIT_WEB_HOST}/${GIT_REPO}/pulls/${PR_NUM}"
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
  # A7 : le plan tourne sous GITEA_TOKEN (service) — le token humain a été retiré
  # de l'environnement en tête de script ; PROVISION_PLAN_BIN = stub des épreuves.
  if PR_BRANCH="$BRANCH" PR_NUMBER="$PR_NUM" \
     bash "${PROVISION_PLAN_BIN:-$SELF_DIR/provision-plan.sh}"; then
    echo "  PLAN_INLINE=ok"
  else
    echo "  PLAN_INLINE=fail — la PR est ouverte et commentée, la demande reste valide" >&2
  fi
else
  echo "[5/5] plan enchaîné DÉSACTIVÉ (PROVISION_PLAN_INLINE=false) — le webhook s'en charge"
fi

echo "OK: demande ${REQ_APP}/${REQ_ENV} → manifeste + MR${PROVISION_PLAN_INLINE:+ + plan}"
