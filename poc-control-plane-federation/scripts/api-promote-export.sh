#!/usr/bin/env bash
# api-promote-export.sh — moteur du formulaire « exporter l'archive d'une API »
# (jalon G5, verbe archive). Pendant EXPORT de resolve_deploy_pin/apim_promote_api
# (import) : ce script joue le rôle apim_promote_api en action=export contre la
# gateway D'AUTHORING, pousse l'archive produite au registre Gitea (dépôt
# d'artefacts, PAS Git — scripts/lib/archive-store.sh, ADR-079 C3), et imprime
# le sha256/guid que le demandeur recopie ENSUITE dans :
#   - apis/<api>.promote.yml (guid, par PR sur le dépôt d'équipe) ;
#   - le formulaire api-promote-request (ARCHIVE_SHA256, sortie EXPORT_CONFIRMED).
#
# CE SCRIPT N'ÉCRIT AUCUN MARQUEUR ET NE PUBLIE RIEN SUR LA GATEWAY : il lit
# l'API déjà publiée en authoring, en tire une archive PORTABLE (sanitisée par
# le rôle) et la dépose au registre. Le lien « approuvé == déployé » n'est tenu
# nulle part ici — c'est deploy-pin.sh (DEPLOY_PIN_SHA256 vs les octets promus)
# qui le tient, en aval, au moment de l'import.
#
# Entrées (env — mappées depuis les paramètres du job) :
#   TEAM, API_NAME                        (requis, classe [a-z0-9-])
#   FORGE_SECRET                           (requis — lecture providers.yml + clone)
#   VAULT_ADDR, VAULT_TOKEN_FILE          (requis — CE script ne les lit jamais
#                                          lui-même, mais `ansible-playbook` les
#                                          HÉRITE en sous-processus : le rôle
#                                          apim_promote_api importe
#                                          apim_common/tasks/secrets.yml
#                                          INCONDITIONNELLEMENT (main.yml), qui
#                                          lit VAULT_ADDR/VAULT_TOKEN_FILE pour
#                                          aller chercher le user/password admin
#                                          dans Vault et les pose en
#                                          module_defaults (apim_ss_uri_defaults,
#                                          consommé par TOUS les appels `uri` de
#                                          export.yml — /apis, /apis/<guid>,
#                                          /archive?apis=<guid>). Sans identité
#                                          nominative valide ici, l'export
#                                          n'authentifie PAS contre la gateway :
#                                          ce ne sont donc PAS de simples jetons
#                                          de preuve, ce SONT les creds
#                                          réellement utilisées par le moteur.
#                                          [corrigé — une version antérieure de
#                                          ce commentaire affirmait le contraire]
#   APIM_API_BASE                         (requis, PAS de défaut ICI — la cible
#                                          se dit, elle ne se devine pas ; le
#                                          Jenkinsfile, lui, en pose un)
#   GIT_HOST, GIT_REPO                    (optionnels — défauts du dépôt plateforme)
set -uo pipefail
set +x   # jamais de trace : le token ne doit pas fuiter
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=scripts/lib/deploy-pin.sh
. scripts/lib/deploy-pin.sh || { echo "ERREUR: scripts/lib/deploy-pin.sh introuvable ou illisible" >&2; exit 1; }
# shellcheck source=scripts/lib/archive-store.sh
. scripts/lib/archive-store.sh || { echo "ERREUR: scripts/lib/archive-store.sh introuvable ou illisible" >&2; exit 1; }
# shellcheck source=scripts/lib/promote-manifest.sh
. scripts/lib/promote-manifest.sh || { echo "ERREUR: scripts/lib/promote-manifest.sh introuvable ou illisible" >&2; exit 1; }
# shellcheck source=scripts/lib/forge-identity.sh
. scripts/lib/forge-identity.sh || { echo "ERREUR: scripts/lib/forge-identity.sh introuvable ou illisible" >&2; exit 1; }
# Disposition du dépôt : le préfixe du livrable est un KNOB (GIT_SUBDIR ->
# SUB_PFX), jamais le préfixe du lab en dur — ici il est un SEGMENT D'URL.
# shellcheck source=scripts/lib/repo-layout.sh
. scripts/lib/repo-layout.sh || { echo "ERREUR: scripts/lib/repo-layout.sh introuvable ou illisible" >&2; exit 1; }
repo_layout_init || exit 2
# LA branche par défaut du dépôt d'ÉQUIPE, une autorité (L3, 2026-09-10) : ce
# script ne lit QUE ce dépôt-là (le providers de la plateforme passe par l'API
# raw, sans ref). C'est donc `git_base_of` — la HEAD de CE dépôt — et non le
# knob global, qui ne vaut que pour la plateforme.
# shellcheck source=scripts/lib/git-base.sh
. scripts/lib/git-base.sh || { echo "ERREUR: scripts/lib/git-base.sh introuvable ou illisible" >&2; exit 1; }

fail() { printf 'ERREUR: %s\n' "$*" >&2; exit 1; }

AUTHORING_ENV="$DEPLOY_PIN_AUTHORING_ENV"

TEAM="${TEAM:?TEAM requis}"
API_NAME="${API_NAME:?API_NAME requis}"

# ── Garde 0 : LES CLASSES, AVANT TOUT RÉSEAU ─────────────────────────────────
# Même forme NÉGATIVE que api-promote-request.sh:60-62 (et non
# `[a-z0-9][a-z0-9-]*`, qui accepte n'importe quoi après le second caractère —
# piège déjà documenté dans ce dépôt). TEAM et API_NAME finissent tous les deux
# en segment de CHEMIN/URL (providers.<env>.yml, apis/<api>.promote.yml, l'URL
# du registre via archive_store_push) : une évasion de chemin ou une injection
# shell y serait une conséquence directe, pas une coquetterie de validation.
# archive-store.sh valide sa PROPRE classe ([a-z0-9-], _as_ident_ok) mais
# seulement au moment du push — APRÈS le clone et l'export Ansible, donc APRÈS
# tout réseau. Ces deux gardes-ci ferment la classe AVANT le premier octet
# envoyé où que ce soit.
case "$TEAM" in
  ""|-*|*[!a-z0-9-]*) fail "TEAM_INVALIDE : '$TEAM' — attendu des minuscules, chiffres et tirets, sans tiret initial" ;;
esac
case "$API_NAME" in
  ""|-*|*[!a-z0-9-]*) fail "API_NAME_INVALIDE : '$API_NAME' — attendu des minuscules, chiffres et tirets, sans tiret initial" ;;
esac

# Le secret de la forge porte un nom NEUTRE (2026-09-04) : un gestionnaire
# d'identite rend un jeton OU un couple, et les deux occupent la meme place.
FORGE_SECRET="${FORGE_SECRET:-${GITEA_TOKEN:-}}"
[ -n "$FORGE_SECRET" ] || { echo "REFUS: SECRET_FORGE_REQUIS : ni FORGE_SECRET ni son alias GITEA_TOKEN — le secret de la forge (jeton, ou mot de passe d'un couple avec FORGE_USER)" >&2; exit 2; }
VAULT_ADDR="${VAULT_ADDR:?VAULT_ADDR requis}"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:?VAULT_TOKEN_FILE requis (jamais le token en env/argv)}"
APIM_API_BASE="${APIM_API_BASE:?APIM_API_BASE requis — pas de défaut : dire sa cible est volontaire}"
GIT_HOST="${GIT_HOST:-http://gitea:3000}"
GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"   # défaut : même hôte, sauf reverse-proxy dédié à l'affichage
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"   # dépôt PLATEFORME — porte providers.<env>.yml

# L5 phase 2 (2026-09-12) — LA FORGE SE PARLE PAR UNE SEULE AUTORITÉ : le
# visage (FORGE_KIND=gitea|gitlab), la base d'API, l'en-tête d'auth et la garde
# de réponse vivent dans scripts/lib/forge-api.sh (+ .py) — ce script ne
# compose plus /api/v1 ni « Authorization: token » lui-même (mêmes verbes que
# team-request.sh/api-request.sh/api-promote-request.sh). Sourcé APRÈS la
# garde du secret (§haut) et APRÈS GIT_HOST/GIT_REPO/GIT_WEB_HOST ci-dessus :
# forge_api_init ne fait AUCUN appel réseau, mais REFUSE si GIT_HOST ou
# GIT_REPO est vide — GIT_REPO ici est le dépôt PLATEFORME (défaut posé juste
# au-dessus) ; l'appel visant le dépôt de l'ÉQUIPE se préfixe lui-même
# GIT_REPO="$REPO_FULL" plus bas (§PR d'épinglage) — l'autorité n'a pas besoin
# de le savoir à l'init, seulement qu'UN dépôt est nommé.
_APE_FORGE="$(dirname "${BASH_SOURCE[0]}")/lib/forge-api.sh"
[ -f "$_APE_FORGE" ] || _APE_FORGE="scripts/lib/forge-api.sh"
# shellcheck source=scripts/lib/forge-api.sh
. "$_APE_FORGE" || { echo "ERREUR: $_APE_FORGE introuvable ou illisible" >&2; exit 1; }
forge_api_init || exit 2

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; umask 077

# ── team -> repo, lu sur la FORGE (jamais le worktree local) ────────────────
# `/raw/<chemin>` SANS ref : la forge sert la branche par défaut du dépôt
# plateforme — celle qu'elle déclare, quel que soit son nom.
# REPRIS À L'IDENTIQUE de api-promote-request.sh : le préfixe de
# sous-répertoire dans le chemin reste un KNOB, jamais un littéral — et le
# piège qu'était `curl -s` (rc 0 sur un 404) est fermé À LA SOURCE par la garde
# de réponse de forge-api.py (rc 2 et rien sur stdout dès que le HTTP n'est pas
# 2xx).
PROV_REL="${SUB_PFX}ansible/providers.${AUTHORING_ENV}.yml"
forge raw "$PROV_REL" > "$TMP/providers.yml" \
  || fail "LECTURE_PROVIDERS : ${PROV_REL} illisible sur la branche par défaut de ${GIT_REPO} (cause ci-dessus ; chemin RELATIF à la racine du dépôt, préfixe GIT_SUBDIR='${GIT_SUBDIR:-}')"
REPO_FULL=$(TEAM="$TEAM" PROV="$TMP/providers.yml" python3 - <<'PY'
import os, sys, yaml
d = yaml.safe_load(open(os.environ["PROV"])) or {}
e = next((p for p in (d.get("providers") or []) if p.get("team") == os.environ["TEAM"]), None)
if e is None:
    sys.exit("TEAM_NOT_FOUND")
print("REPO=" + (e.get("repo") or ""))
PY
) || fail "REPO_NON_DECLARE : équipe '$TEAM' absente de providers.${AUTHORING_ENV}.yml"
case "$REPO_FULL" in REPO=*) REPO_FULL="${REPO_FULL#REPO=}";; *) fail "PARSE_PROVIDERS : sortie inattendue";; esac
[ -n "$REPO_FULL" ] || fail "REPO_NON_DECLARE : équipe '$TEAM' sans dépôt dans providers.${AUTHORING_ENV}.yml"

# ── clone AUTHENTIFIÉ du dépôt d'équipe (motif gclone de team-publish.sh:110-116) ──
# Un dépôt d'équipe privé casserait un clone anonyme. `--depth 1 -b <base>` :
# l'export lit apis/<api>.promote.yml TEL QU'IL EST SUR la branche de base du
# dépôt d'équipe — découverte, jamais devinée. Aucune branche à créer, aucun SHA
# tiers à atteindre (contrairement à api-promote-request.sh, qui pousse une
# branche, ou à team-publish.sh, qui checkoute un SHA de merge).
# L'ENVELOPPE ELLE-MÊME VIT DANS LA LIB (git_base_avec_basic) depuis la revue du
# sous-lot 4b : elle était recopiée mot pour mot dans trois scripts. Le SECRET
# n'est pas passé en argv — c'est le NOM de la variable qui l'est ; argv est
# lisible par `ps -Aww`. Le LOGIN, lui, vient de l'autorité unique
# `git_base_basic_login` (2026-09-11) : il valait « x » EN DUR ici, ce qui est
# une authentification MORTE sur GitLab et Bitbucket — l'entête de la lib le
# documentait déjà, et la règle vivait en neuf exemplaires qui décidaient
# chacun pour soi.
gclone(){ git_base_avec_basic "$(git_base_basic_login)" FORGE_SECRET git clone -q "$@"; }
# LA DÉCOUVERTE SOUS LA MÊME ENVELOPPE QUE LE CLONE : la lib n'embarque aucun
# secret, elle hérite de l'environnement. Anonyme, son `git ls-remote`
# échouerait sur le dépôt d'équipe PRIVÉ d'un client — l'export refuserait pour
# une raison sans rapport.
gbase(){ git_base_avec_basic "$(git_base_basic_login)" FORGE_SECRET "$@"; }
gbase git_base_of "${GIT_HOST}/${REPO_FULL}.git" >/dev/null \
  || fail "CLONE_ECHEC : branche par défaut de ${REPO_FULL} indéterminable (cause ci-dessus) — rien n'est exporté"
TEAM_BASE="$GIT_BASE_OF"
gclone --depth 1 -b "$TEAM_BASE" "${GIT_HOST}/${REPO_FULL}.git" "$TMP/team" \
  || fail "CLONE_ECHEC : ${REPO_FULL}@${TEAM_BASE}"

PROMOTE_REL="apis/${API_NAME}.promote.yml"
# La version d'AUTHORING (publish.yml sur la branche de base) est la vérité de
# ce qui se publie en dev — le manifeste de promotion la SUIT, il ne la précède pas.
PUB_VERSION=$(publish_manifest_version "$TMP/team" "$API_NAME") \
  || fail "PUBLISH_MANIFEST_ABSENT : apis/${API_NAME}.publish.yml absent ou illisible sur ${REPO_FULL}@${TEAM_BASE} — publier l'API d'abord (formulaire api-request)"
MANIFEST_RENDU=0
if [ ! -f "$TMP/team/$PROMOTE_REL" ]; then
  # Spec promotion-sans-recopie (2026-08-28) : le manifeste absent n'est plus
  # un refus, c'est le CAS NOMINAL du premier export — on le REND (gabarit),
  # et la PR d'épinglage ci-dessous le portera, guid et sha déjà remplis.
  render_promote_manifest "$TMP/team" "$API_NAME" gateways/templates/promote.yml.tmpl \
    || fail "RENDU_ECHEC : gabarit gateways/templates/promote.yml.tmpl -> ${PROMOTE_REL}"
  MANIFEST_RENDU=1
  echo "manifeste absent de ${TEAM_BASE} — RENDU depuis le gabarit (name=${API_NAME}, version=${PUB_VERSION})"
else
  # Manifeste présent mais version en retard sur l'authoring (new-version
  # publiée depuis) : réaligner AVANT l'export — sinon le play ci-dessous
  # résout l'API par le COUPLE name+version du manifeste, donc exporterait
  # l'ancienne version, et la reprise manuelle reviendrait à chaque montée de version.
  M_VERSION=$(python3 -c "import sys,yaml; print((yaml.safe_load(open(sys.argv[1])) or {}).get('apim_promote',{}).get('version',''))" "$TMP/team/$PROMOTE_REL" 2>/dev/null || printf '')
  if [ -n "$M_VERSION" ] && [ "$M_VERSION" != "$PUB_VERSION" ]; then
    # Réutilise pin_promote_manifest (guid/sha déjà portés, INCHANGÉS) pour ne
    # toucher QUE version:/archive: — même relecture fail-closed que
    # l'épinglage final, sur la COPIE DE TRAVAIL que le play va lire.
    M_GUID=$(python3 -c "import sys,yaml; print((yaml.safe_load(open(sys.argv[1])) or {}).get('apim_promote',{}).get('guid',''))" "$TMP/team/$PROMOTE_REL" 2>/dev/null || printf '')
    M_SHA=$(manifest_pinned_digest "$TMP/team/$PROMOTE_REL") \
      || fail "MANIFESTE_ILLISIBLE : ${PROMOTE_REL} — relecture du sha épinglé en échec avant réalignement de version"
    pin_promote_manifest "$TMP/team/$PROMOTE_REL" "$M_GUID" "$M_SHA" "$PUB_VERSION" \
      || fail "REALIGNEMENT_EXPORT_ECHEC : version du manifeste (${M_VERSION}) non réalignée sur l'authoring (${PUB_VERSION}) avant l'export"
    echo "version du manifeste (${M_VERSION}) en retard sur l'authoring (${PUB_VERSION}) — réalignée AVANT l'export (la PR d'épinglage la portera aussi)"
  fi
fi

# ── LE MOTEUR : export via le rôle apim_promote_api (action=export) ─────────
# apim_ss_archive_pin sert ICI de DESTINATION (le rôle y écrit l'archive) —
# c'est le MÊME extra-var que Task 4 branche pour l'import, où il sert de
# SOURCE. D'où l'invocation identique en forme, opposée en sens.
ARCHIVE_OUT="$TMP/export.zip"
( ansible-playbook -i ansible/inventory.lab.ini ansible/promote-api.yml \
    -e stoa_debug="$(dbg_bool)" \
    -e apim_promote_action=export \
    -e apim_promote_manifest="$TMP/team/apis/${API_NAME}.promote.yml" \
    -e apim_ss_archive_pin="$ARCHIVE_OUT" \
    -e apim_ss_env="$DEPLOY_PIN_AUTHORING_ENV" \
    -e apim_ss_authoring_env="$DEPLOY_PIN_AUTHORING_ENV" \
    -e apim_ss_api_base="$APIM_API_BASE" \
) >"$TMP/export.log" 2>&1 || { tail -30 "$TMP/export.log" >&2; fail "EXPORT_ECHEC : voir le log"; }

[ -s "$ARCHIVE_OUT" ] || fail "EXPORT_UNCONFIRMED : ${ARCHIVE_OUT} absente ou vide après le play — rien à pousser au registre"

# ── digest + guid, capturés en FICHIER (jamais un pipe sur la sortie du play) ─
# `ansible-playbook | grep` ferait dépendre le code de sortie de grep, pas du
# play (piège pipefail déjà documenté dans ce dépôt) — le log est donc déjà en
# fichier ($TMP/export.log) et on le relit ici, à froid.
SHA=$(shasum -a 256 "$ARCHIVE_OUT" | cut -d' ' -f1)
[ "${#SHA}" -eq 64 ] || fail "EXPORT_UNCONFIRMED : sha256 de ${ARCHIVE_OUT} incalculable"

# ⚠ NE PAS grep 'guid=[0-9a-f-]*' SUR TOUT LE LOG — SECOND ÉMETTEUR MESURÉ EN
# RÉEL (mock local, ansible-playbook réel, pas une lecture de code à froid).
# roles/apim_promote_api/tasks/resolve-env.yml:56-62 imprime un DEBUG
# INCONDITIONNEL (pas gaté par stoa_debug, tourne à CHAQUE appel du rôle,
# export COMME import) qui porte LUI AUSSI le littéral 'guid=' :
#   guid={{ apim_promote.guid | default('(à épingler)') }}
# Tant que le manifeste ne pin pas encore de guid (le cas NOMINAL du premier
# export, `guid: ""` dans le manifeste comme dans clients/_example/apis/
# accounts-read.promote.yml), `default()` SANS son second argument booléen ne
# remplace que l'UNDEFINED, jamais une chaîne vide déjà présente — la ligne
# réellement observée est donc `guid=, backend_alias=…` (rien du tout entre
# `=` et la virgule), et non le texte `(à épingler)` qu'on pourrait attendre
# à la lecture seule du template. Dans les DEUX cas (chaîne vide OU parenthèse
# du texte de repli, si la clé est un jour absente plutôt que vide), le
# caractère qui suit `guid=` est hors de la classe [0-9a-f-] :
# `grep -o 'guid=[0-9a-f-]*'` y capture donc 'guid=' SEUL (le '*' autorise
# zéro caractère), un match VIDE qui se glisserait comme un guid si on s'y
# fiait. Un `tail -1` sur TOUT le log ne "marchait" que parce que ce debug de
# resolve-env.yml s'exécute AVANT le succès d'export.yml (main.yml importe
# resolve-env.yml PUIS export.yml, dans cet ordre) — un ORDRE D'IMPRESSION
# IMPLICITE, jamais garanti par une interface, pas une preuve. On ancre donc
# l'extraction sur la ligne EXPORT_CONFIRMED elle-même (le success_msg de
# l'assert final d'export.yml — seul émetteur qui garantit un guid RÉELLEMENT
# résolu, relu et vérifié contre le catalogue) et on exige une forme plausible
# avant de le rendre : un UUID wM fait 36 caractères [0-9a-f-] (mesuré :
# mocks/webmethods/store.go:guidForKind — 8-4-4-4-12, et confirmé par un run
# réel du play contre ce mock, cf. l'addendum du rapport de cette tâche).
CONFIRM_LINE=$(grep 'EXPORT_CONFIRMED' "$TMP/export.log" | tail -1)
[ -n "$CONFIRM_LINE" ] \
  || fail "EXPORT_UNCONFIRMED : aucune ligne EXPORT_CONFIRMED dans le log d'export — le rôle n'a pas confirmé l'export"
GUID=$(printf '%s\n' "$CONFIRM_LINE" | grep -o 'guid=[0-9a-f-]*' | tail -1)
GUID="${GUID#guid=}"
case "$GUID" in
  ""|*[!0-9a-f-]*) fail "EXPORT_UNCONFIRMED : guid absent ou de forme invalide ('${GUID}') sur la ligne EXPORT_CONFIRMED" ;;
esac
[ "${#GUID}" -eq 36 ] \
  || fail "EXPORT_UNCONFIRMED : guid '${GUID}' fait ${#GUID} caractères — un identifiant wM complet en fait 36 (forme UUID)"

# ── LE REGISTRE : pousser l'archive (idempotence PAR LE CONTENU, cf. la lib) ──
# TOCTOU bénin sonde-GET/PUT documenté par Task 2 (archive-store.sh) : aucune
# action requise ici, seulement ne jamais paralléliser les push.
PUSH_OUT="$TMP/push.out"; PUSH_ERR="$TMP/push.err"
archive_store_push "$ARCHIVE_OUT" "$TEAM" "$API_NAME" >"$PUSH_OUT" 2>"$PUSH_ERR" \
  || { cat "$PUSH_ERR" >&2; fail "EXPORT_STORE_ECHEC : $(tail -1 "$PUSH_ERR")"; }
PUSH_LINE=$(tail -1 "$PUSH_OUT")
case "$PUSH_LINE" in
  ARCHIVE_STORE_PUSHED\ sha256=*\ url=*) ;;
  *) fail "EXPORT_STORE_INATTENDU : sortie de archive_store_push non reconnue ('${PUSH_LINE}')" ;;
esac
PUSHED_SHA="${PUSH_LINE#*sha256=}"; PUSHED_SHA="${PUSHED_SHA%% url=*}"
URL="${PUSH_LINE#*url=}"
[ "$PUSHED_SHA" = "$SHA" ] \
  || fail "EXPORT_STORE_INCOHERENT : le registre rend sha256=${PUSHED_SHA}, le calcul local rend ${SHA}"

# ── ÉPINGLAGE (spec promotion-sans-recopie) : guid + sha + version, par PR ──
# Le fichier de travail est celui que l'export vient de JOUER ($TMP/team) —
# épingler autre chose serait épingler ce qu'on n'a pas exporté.
pin_promote_manifest "$TMP/team/$PROMOTE_REL" "$GUID" "$SHA" "$PUB_VERSION" \
  || fail "PIN_ECHEC : épinglage de ${PROMOTE_REL}"

printf 'EXPORT_CONFIRMED_SUMMARY guid=%s sha256=%s package=%s\n' "$GUID" "$SHA" "$URL"

if git -C "$TMP/team" diff --quiet -- "$PROMOTE_REL" && [ "$MANIFEST_RENDU" = 0 ]; then
  # la branche de base porte déjà exactement ces valeurs : ré-export au contenu identique
  # (registre idempotent par le contenu) — aucune PR à ouvrir, et on le DIT.
  echo "PIN_DEJA_A_JOUR : ${PROMOTE_REL} sur ${TEAM_BASE} porte déjà guid/sha/version — pas de PR"
  echo "geste suivant : formulaire api-promote-request (ARCHIVE_SHA256 facultatif — lu sur ${TEAM_BASE})"
else
  PIN_BRANCH="chore/promote-manifest-${API_NAME}"
  git -C "$TMP/team" checkout -q -B "$PIN_BRANCH"
  git -C "$TMP/team" add "$PROMOTE_REL"
  git -C "$TMP/team" -c user.name=ci -c user.email=ci@stoa.lab \
    commit -qm "promo(${API_NAME}): épingle guid/sha256/version ${PUB_VERSION} (export $(printf '%.12s' "$SHA"))" \
    || fail "PIN_COMMIT_VIDE : rien à committer alors qu'un diff était attendu"
  # push FORCÉ délibéré : la branche d'épinglage n'a qu'UN commit de tête et
  # appartient à l'export — un ré-export la REMPLACE (la PR ouverte suit),
  # jamais d'empilement (piège G5 « ré-export ⇒ PR neuve » fermé ici).
  # Le LOGIN vient de l'autorité unique (2026-09-12) : « x » était composé EN DUR
  # ici, et un geste PARFAITEMENT authentifié retombait donc en 401 sur GitLab —
  # invisible à la porte H bis.2, qui mesure l'enveloppe du geste et non l'origine
  # du login (d'où H bis.4).
  AUTH_B64=$(printf '%s:%s' "$(git_base_basic_login)" "$FORGE_SECRET" | base64 | tr -d '\n')
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
    GIT_CONFIG_VALUE_0="Authorization: Basic ${AUTH_B64}" \
    git -C "$TMP/team" push -q -f "${GIT_HOST}/${REPO_FULL}.git" "$PIN_BRANCH" \
    || fail "PIN_PUSH_ECHEC : push de ${PIN_BRANCH} sur ${REPO_FULL}"
  unset AUTH_B64
  # Le rejeu est NOMINAL (le push -f vient de remplacer la branche d'épinglage) :
  # on RETROUVE la PR ouverte de cette tête avant d'en ouvrir une — plus de 409 à lire.
  if ! GIT_REPO="$REPO_FULL" forge_kv PIN pr_find_open "$PIN_BRANCH"; then
    fail "PIN_PR_ECHEC : relecture des PR ouvertes de ${REPO_FULL} (cause ci-dessus)"
  fi
  if [ -n "${PIN_NUMBER:-}" ]; then
    PIN_PR="$PIN_NUMBER"; echo "PR d'épinglage déjà ouverte : #${PIN_PR} (mise à jour par le push)"
  else
    {
      printf "Épinglage du manifeste de promotion (formulaire api-promote-export).\n\n"
      printf -- "- API : %s v%s\n- guid (id-map, ADR-079) : %s\n- archive_sha256 (registre, adressé par le contenu) : %s\n\n" "$API_NAME" "$PUB_VERSION" "$GUID" "$SHA"
      printf "Merger cette PR épingle CE guid et CES octets pour la promotion. Geste suivant : formulaire api-promote-request — ARCHIVE_SHA256 peut rester vide, il sera lu ici, sur %s (ADR-081 : la décision est le merge).\n" "$TEAM_BASE"
    } > "$TMP/pin-body.md"
    GIT_REPO="$REPO_FULL" forge_kv PIN pr_open "$PIN_BRANCH" "$TEAM_BASE" "promo(${API_NAME}): épinglage guid/sha v${PUB_VERSION}" "$TMP/pin-body.md" \
      || fail "PIN_PR_ECHEC : ouverture de la PR d'épinglage sur ${REPO_FULL} (cause ci-dessus)"
    PIN_PR="$PIN_NUMBER"
  fi
  echo "PR d'épinglage : $(forge_web_url "$PIN_URL")"
  echo "geste suivant : MERGER cette PR, puis formulaire api-promote-request (ARCHIVE_SHA256 facultatif — lu sur ${TEAM_BASE})"
fi
