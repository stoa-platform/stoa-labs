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
#
# Task 4 (P3) — identité entrante, TOUS OPTIONNELS. Absents = comportement
# octet pour octet identique à avant (preuve de non-régression, cf. Step 4 du
# brief) : chaque bloc de manifeste qu'ils pilotent n'est rendu QUE si fourni.
#   REQ_TEAM           équipe propriétaire (cloisonnement) — DOIT être déclarée
#                      dans providers.<env>.yml (même garde que team-request.sh) ;
#                      pilote aussi TENANT (déploiement Vault, mode internal).
#   REQ_IP_ALLOWLIST   une IP ou une plage A-B (jamais de CIDR — la gateway le
#                      drop en silence, cf. README du rôle apim_selfservice_app).
#   REQ_CERT_PEM       certificat public X.509 (PEM) — jamais de clé privée.
#                      Écrit en fichier .crt versionné dans la PR (jamais .pem
#                      — cf. le .gitignore racine du dépôt, "Secrets / env"),
#                      référencé par public_cert_ref (jamais la valeur en
#                      clair dans le YAML).
#   REQ_CERT_ROTATION  replace (défaut) | overlap — cf. rôle, sans objet si
#                      REQ_CERT_PEM est vide.
set -uo pipefail
set +x   # jamais de trace : le token ne doit pas fuiter

REQ_APP="${REQ_APP:?REQ_APP requis}"
REQ_ENV="${REQ_ENV:?REQ_ENV requis}"
REQ_API="${REQ_API:?REQ_API requis}"
REQ_API_VER="${REQ_API_VER:-1.0.0}"
REQ_AUDIENCE="${REQ_AUDIENCE:-$REQ_API}"
REQ_CALLER="${REQ_CALLER:-unknown}"
REQ_CLIENT_ID="${REQ_CLIENT_ID:-}"
REQ_TEAM="${REQ_TEAM:-}"
REQ_IP_ALLOWLIST="${REQ_IP_ALLOWLIST:-}"
REQ_CERT_PEM="${REQ_CERT_PEM:-}"
REQ_CERT_ROTATION="${REQ_CERT_ROTATION:-}"
TENANT="${TENANT:-banking-demo}"

# MODE = propriété de l'APPELANT, jamais du body (anti-spoof) : OIG provisionne
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
case "$REQ_ENV" in dev|rec|int|prod) ;; *) echo "REFUS: REQ_ENV='$REQ_ENV' (attendu dev|rec|int|prod)" >&2; exit 2;; esac

# ── Task 4 (P3) — identité entrante : gardes AVANT tout geste Git ────────────
# Reprises verbatim du brief (tags d'échec inclus) : chaque garde est un no-op
# tant que le champ correspondant est vide (absent = comportement actuel).
fail(){ echo "REFUS: $*" >&2; exit 2; }

# CIDR : la gateway le drop EN SILENCE — refuser ici, bruyamment.
case "$REQ_IP_ALLOWLIST" in */*) fail "IP_CIDR_REFUSE : CIDR non supporté (drop silencieux gateway) — single ou plage A-B";; esac
# Durcissement au-delà du brief : REQ_IP_ALLOWLIST est interpolé tel quel dans
# un YAML (ip_allowlist: ["..."]) — un caractère hors [0-9A-Za-z.-] (guillemet,
# retour ligne...) casserait ou détournerait le manifeste. Même classe de garde
# que team-request.sh pour DESCRIPTION/REPO (refus, pas échappement).
if [ -n "$REQ_IP_ALLOWLIST" ]; then
  case "$REQ_IP_ALLOWLIST" in
    *[!0-9A-Za-z.-]*) fail "IP_ALLOWLIST_INVALID : '$REQ_IP_ALLOWLIST' — caractères autorisés [0-9A-Za-z.-] uniquement";;
  esac
fi
# On ne commite JAMAIS une clé privée — même collée par accident.
case "$REQ_CERT_PEM" in *"PRIVATE KEY"*) fail "CERT_PRIVATE_KEY_REFUSE";; esac
[ -n "$REQ_CERT_PEM" ] && { printf '%s' "$REQ_CERT_PEM" | grep -q -- '-----BEGIN CERTIFICATE-----' || fail "CERT_SANS_BLOC : PEM public X.509 attendu"; }
case "${REQ_CERT_ROTATION:-replace}" in replace|overlap) ;; *) fail "CERT_ROTATION_INVALIDE : replace|overlap";; esac

# REQ_TEAM : format identique à team-request.sh (^[a-z0-9][a-z0-9-]{1,30}$).
# L'appartenance (déclarée dans providers.<env>.yml) ne peut être vérifiée
# qu'après le clone (Step 2, il faut lire le fichier du dépôt) ; absent =
# TENANT reste "banking-demo" (défaut actuel, voie machine intacte).
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
git clone -q --depth 1 -b "$GIT_BASE" "http://${GIT_HOST#http://}/${GIT_REPO}.git" "$WORK/repo" 2>/dev/null \
  || git clone -q --depth 1 "http://${GIT_HOST#http://}/${GIT_REPO}.git" "$WORK/repo"
cd "$WORK/repo"
git config user.email "ci@bc.example"; git config user.name "provisioning (service ci)"

# REQ_TEAM (suite) : l'appartenance ne se vérifie qu'ici — MAIS avant tout
# geste Git qui compte (aucune branche créée, aucun push tenté). Un échec ici
# laisse le dépôt distant intact (ls-remote inchangé), seul $WORK est jeté par
# le trap EXIT.
if [ -n "$REQ_TEAM" ]; then
  PROV_FILE="poc-control-plane-federation/ansible/providers.${REQ_ENV}.yml"
  [ -f "$PROV_FILE" ] || fail "PROVIDERS_MISSING : ansible/providers.${REQ_ENV}.yml absent sur ${GIT_BASE}"
  grep -Eq "^  - team: ${REQ_TEAM}\$" "$PROV_FILE" \
    || fail "TEAM_NOT_DECLARED : '${REQ_TEAM}' absent de providers.${REQ_ENV}.yml"
  TENANT="$REQ_TEAM"
fi

git checkout -q -B "$BRANCH"

echo "[2/4] rendu du manifeste ${REL_PATH} (mode ${MODE})"
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
CERT_DIR="$(dirname "$MANIFEST_DIR")/certs"
CERT_FILE="${CERT_DIR}/${REQ_APP}.crt"
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

CERT_ROTATION_LINE=""
[ -n "$REQ_CERT_PEM" ] && CERT_ROTATION_LINE=$'  cert_rotation: "'"${REQ_CERT_ROTATION:-replace}"$'"\n'

PER_ENV_ITEMS=""
[ -n "$REQ_IP_ALLOWLIST" ] && PER_ENV_ITEMS="${PER_ENV_ITEMS:+$PER_ENV_ITEMS, }ip_allowlist: [\"${REQ_IP_ALLOWLIST}\"]"
[ -n "$REQ_CERT_PEM" ] && PER_ENV_ITEMS="${PER_ENV_ITEMS:+$PER_ENV_ITEMS, }public_cert_ref: \"${CERT_REL}\""

# Mode idp n'a, avant Task 4, AUCUN bloc per_env : IDP_TAIL n'ajoute quoi que
# ce soit qu'à partir d'un \n initial (jamais de ligne vide en trop) — resp.
# jamais de \n final (c'est la propre fin de ligne du heredoc qui le fournit),
# pour rester octet pour octet identique quand REQ_CERT_PEM/REQ_IP_ALLOWLIST
# sont absents (Step 4 du brief : la ligne "claim: {...}" reste alors seule,
# suivie immédiatement du terminateur YAML — EXACTEMENT comme avant Task 4).
IDP_TAIL=""
[ -n "$REQ_CERT_PEM" ] && IDP_TAIL="${IDP_TAIL}"$'\n  cert_rotation: "'"${REQ_CERT_ROTATION:-replace}"$'"'
if [ -n "$PER_ENV_ITEMS" ]; then
  IDP_TAIL="${IDP_TAIL}"$'\n  per_env:\n    '"${REQ_ENV}"$': { '"${PER_ENV_ITEMS}"$' }'
fi
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
${TEAM_LINE}  enforce: []
  auth:
    mode: "internal"
    audience: "${REQ_AUDIENCE}"
${CERT_ROTATION_LINE}  per_env:
    ${REQ_ENV}: { auth: { vault_sub: "deploy/${TENANT}/apps/${REQ_APP}/${REQ_ENV}/oauth-client" }${PER_ENV_ITEMS:+, $PER_ENV_ITEMS} }
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
${TEAM_LINE}  enforce: []
  auth:
    mode: "idp"
    server_alias: "KeycloakStoaLab"
    audience: "${REQ_AUDIENCE}"
    claim: { name: "azp", value: "${REQ_CLIENT_ID}" }${IDP_TAIL}
YAML
fi

if git diff --quiet -- "$REL_PATH" 2>/dev/null && git ls-files --error-unmatch "$REL_PATH" >/dev/null 2>&1; then
  echo "  (manifeste inchangé — demande idempotente)"
fi
git add "$REL_PATH"
[ -n "$REQ_CERT_PEM" ] && git add "$CERT_FILE"
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
  API="$API" GIT_REPO="$GIT_REPO" GITEA_TOKEN="$GITEA_TOKEN" \
  REQ_TEAM="$REQ_TEAM" REQ_IP_ALLOWLIST="$REQ_IP_ALLOWLIST" REQ_CERT_ROTATION="${REQ_CERT_ROTATION:-}" \
  REQ_CERT_PRESENT="$([ -n "$REQ_CERT_PEM" ] && echo 1 || echo 0)" CERT_REL="$CERT_REL" \
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
    extra.append(f"- equipe (cloisonnement) : {os.environ['REQ_TEAM']}")
if os.environ.get("REQ_IP_ALLOWLIST"):
    extra.append(f"- IP allowlist : {os.environ['REQ_IP_ALLOWLIST']}")
if os.environ.get("REQ_CERT_PRESENT") == "1":
    extra.append(f"- certificat public : {os.environ['CERT_REL']} "
                  f"(rotation : {os.environ.get('REQ_CERT_ROTATION') or 'replace'})")
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
