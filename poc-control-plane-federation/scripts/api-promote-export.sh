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

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; umask 077
forge_auth_write "$FORGE_SECRET" "$TMP/ghdr" || exit 2
gapi() { curl -sS -H @"$TMP/ghdr" -H 'Content-Type: application/json' "$@"; }

# ── team -> repo, lu sur GITEA MAIN (jamais le worktree local) ───────────────
# REPRIS À L'IDENTIQUE de api-promote-request.sh:141-175 (mêmes deux pièges
# mesurés : le préfixe de sous-répertoire dans le chemin, et `curl -s` qui rend
# 0 sur un 404 — d'où --fail-with-body).
gapi --fail-with-body --max-time 20 \
  "${GIT_HOST}/api/v1/repos/${GIT_REPO}/raw/poc-control-plane-federation/ansible/providers.${AUTHORING_ENV}.yml" \
  > "$TMP/providers.yml" \
  || fail "LECTURE_PROVIDERS : poc-control-plane-federation/ansible/providers.${AUTHORING_ENV}.yml illisible sur ${GIT_REPO}@main (HTTP non-2xx, hote injoignable ou token refuse)"
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
# Un dépôt d'équipe privé casserait un clone anonyme. --depth 1 -b main :
# l'export lit apis/<api>.promote.yml TEL QU'IL EST SUR main, aucune branche à
# créer ni de SHA tiers à atteindre (contrairement à api-promote-request.sh, qui
# pousse une branche, ou team-publish.sh, qui checkoute un SHA de merge).
gclone(){
  local auth_b64
  auth_b64=$(printf 'x:%s' "$FORGE_SECRET" | base64 | tr -d '\n')
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
    GIT_CONFIG_VALUE_0="Authorization: Basic ${auth_b64}" \
    git clone -q "$@"
}
gclone --depth 1 -b main "${GIT_HOST}/${REPO_FULL}.git" "$TMP/team" \
  || fail "CLONE_ECHEC : ${REPO_FULL}"

PROMOTE_REL="apis/${API_NAME}.promote.yml"
# La version d'AUTHORING (publish.yml sur main) est la vérité de ce qui se
# publie en dev — le manifeste de promotion la SUIT, il ne la précède pas.
PUB_VERSION=$(publish_manifest_version "$TMP/team" "$API_NAME") \
  || fail "PUBLISH_MANIFEST_ABSENT : apis/${API_NAME}.publish.yml absent ou illisible sur ${REPO_FULL}@main — publier l'API d'abord (formulaire api-request)"
MANIFEST_RENDU=0
if [ ! -f "$TMP/team/$PROMOTE_REL" ]; then
  # Spec promotion-sans-recopie (2026-08-28) : le manifeste absent n'est plus
  # un refus, c'est le CAS NOMINAL du premier export — on le REND (gabarit),
  # et la PR d'épinglage ci-dessous le portera, guid et sha déjà remplis.
  render_promote_manifest "$TMP/team" "$API_NAME" gateways/templates/promote.yml.tmpl \
    || fail "RENDU_ECHEC : gabarit gateways/templates/promote.yml.tmpl -> ${PROMOTE_REL}"
  MANIFEST_RENDU=1
  echo "manifeste absent de main — RENDU depuis le gabarit (name=${API_NAME}, version=${PUB_VERSION})"
else
  # Manifeste présent mais version en retard sur l'authoring (new-version
  # publiée depuis) : réaligner AVANT l'export — sinon le play ci-dessous
  # résout l'API par le COUPLE name+version du manifeste, donc exporterait
  # l'ancienne version, et la main reviendrait à chaque montée de version.
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
  # main porte déjà exactement ces valeurs : ré-export au contenu identique
  # (registre idempotent par le contenu) — aucune PR à ouvrir, et on le DIT.
  echo "PIN_DEJA_A_JOUR : ${PROMOTE_REL} sur main porte déjà guid/sha/version — pas de PR"
  echo "geste suivant : formulaire api-promote-request (ARCHIVE_SHA256 facultatif — lu sur main)"
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
  AUTH_B64=$(printf 'x:%s' "$FORGE_SECRET" | base64 | tr -d '\n')
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
    GIT_CONFIG_VALUE_0="Authorization: Basic ${AUTH_B64}" \
    git -C "$TMP/team" push -q -f "${GIT_HOST}/${REPO_FULL}.git" "$PIN_BRANCH" \
    || fail "PIN_PUSH_ECHEC : push de ${PIN_BRANCH} sur ${REPO_FULL}"
  unset AUTH_B64
  PIN_PR=$(API="${GIT_HOST}/api/v1" REPO_FULL="$REPO_FULL" FORGE_SECRET="$FORGE_SECRET" \
    BRANCH="$PIN_BRANCH" API_NAME="$API_NAME" GUID="$GUID" SHA="$SHA" VER="$PUB_VERSION" \
    python3 - <<'PY'
import json, os, urllib.error, urllib.request
api, repo, tok = os.environ["API"], os.environ["REPO_FULL"], os.environ["FORGE_SECRET"]
head = os.environ["BRANCH"]
hdrs = {"Authorization": f"token {tok}", "Content-Type": "application/json"}
body = (
    "Épinglage du manifeste de promotion (formulaire api-promote-export).\n\n"
    f"- API : {os.environ['API_NAME']} v{os.environ['VER']}\n"
    f"- guid (id-map, ADR-079) : {os.environ['GUID']}\n"
    f"- archive_sha256 (registre, adressé par le contenu) : {os.environ['SHA']}\n\n"
    "Merger cette PR épingle CE guid et CES octets pour la promotion. "
    "Geste suivant : formulaire api-promote-request — ARCHIVE_SHA256 peut "
    "rester vide, il sera lu ici, sur main (ADR-081 : la décision est le merge)."
)
req = urllib.request.Request(f"{api}/repos/{repo}/pulls", method="POST",
    data=json.dumps({"base": "main", "head": head,
        "title": f"promo({os.environ['API_NAME']}): épinglage guid/sha v{os.environ['VER']}",
        "body": body}).encode(), headers=hdrs)
try:
    print(json.load(urllib.request.urlopen(req))["number"])
except urllib.error.HTTPError as e:
    if e.code != 409:
        raise
    # PR déjà ouverte pour cette branche : le push -f vient de la mettre à
    # jour — on retrouve son numéro au lieu d'échouer.
    with urllib.request.urlopen(urllib.request.Request(
            f"{api}/repos/{repo}/pulls?state=open", headers=hdrs)) as r:
        prs = json.load(r)
    n = next((p["number"] for p in prs if p["head"]["ref"] == head), None)
    if n is None:
        raise SystemExit("PR 409 mais introuvable parmi les PRs ouvertes")
    print(n)
PY
) || fail "PIN_PR_ECHEC : ouverture/retrouvaille de la PR d'épinglage"
  echo "PR d'épinglage : ${GIT_WEB_HOST}/${REPO_FULL}/pulls/${PIN_PR}"
  echo "geste suivant : MERGER cette PR, puis formulaire api-promote-request (ARCHIVE_SHA256 facultatif — lu sur main)"
fi
