#!/usr/bin/env bash
# team-promote.sh — l'APPLY de PROMOTION, après la décision humaine (le merge
# d'une PR promote/<api>-<env>, ADR-081). Jalon G5 (ADR-079 : le verbe des
# paliers > authoring est l'IMPORT D'ARCHIVE, jamais le re-POST).
#
#   merge PR promote/<api>-<env> (dépôt d'ÉQUIPE) → webhook → job team-promote
#   (pause nominative + login Vault, cf. ci/Jenkinsfile.team-promote) → CE
#   script :
#     0. VALIDATION DE FORME de tout ce qui vient du webhook — AVANT tout argv
#        git/curl — et des KNOBS de pipeline (moteur, voie d'admin).
#     1. la branche dit QUOI et OÙ : promote/<api>-<env>, l'env doit être un
#        palier de la chaîne et jamais l'authoring.
#     2. RÉCONCILIATION AVEC GITEA : le payload du webhook n'est pas la vérité —
#        l'état de la PR ET l'identité du MERGEUR sont relus auprès de Gitea,
#        authentifiés (le DEMANDEUR, lui, vient du marqueur mergé, cf. §6bis).
#     3. AUTORITÉ PAR TOPOLOGIE : l'équipe se dérive du dépôt, jamais du payload.
#     4. ANTI-TOCTOU : le dépôt d'équipe est lu AU SHA DU MERGE, et ce SHA doit
#        être un ancêtre de main.
#     5. LE MARQUEUR : digest pré-lu, archive fetchée PAR SON CONTENU au
#        registre, puis résolveur complet (pin, ancêtreté, version, digest).
#     6. LES EXIGENCES DE LA PORTE, RELUES SUR LE MARQUEUR MERGÉ.
#     6bis. LA GARDE D'IDENTITÉ : qui a mergé (Gitea, §2) == qui répond à la
#        pause, et les quatre yeux contre le DEMANDEUR (`promoted_by` du
#        marqueur mergé) si la porte les exige.
#     7a. LA DÉCLARATION : si la porte nomme un groupe déployeur, le token
#        Vault du porteur doit projeter la policy correspondante (G2, ADR-084).
#     7b. LE PALIER EST-IL OUVERT ? — la lecture du secret d'admin du palier EST
#        le ticket d'entrée (rétention G4, ADR-082).
#     8. LE MOTEUR — un SEUL site d'appel, après TOUT le reste.
#     9. le statut RÉEL sur la PR du dépôt d'équipe — succès comme échec.
#
# ⚠ L'ORDRE EST LA PROPRIÉTÉ, PAS UN DÉTAIL DE MISE EN PAGE. TOUTES les portes
# sont mécaniquement ANTÉRIEURES au moteur : un refus, quel qu'il soit, se
# produit AVANT run_engine() — jamais « pendant », jamais « constaté après ».
# C'est ce qui distingue une chaîne gardée d'une chaîne qui journalise ses
# regrets. L'épreuve test-team-promote-wiring l'exige garde par garde (chaque
# refus ⇒ stub moteur JAMAIS invoqué), et c'est pourquoi `run_engine` est une
# fonction appelée UNE SEULE FOIS, tout en bas : deux sites d'appel rouvriraient
# la question à chaque relecture.
#
# Invocation attendue (miroir de team-publish.sh) :
#   dir('poc-control-plane-federation') { sh 'bash scripts/team-promote.sh' }
# — donc $0 = "scripts/team-promote.sh" et le `cd "$(dirname "$0")/.."`
# ci-dessous NE BOUGE PAS le cwd ("scripts/.." s'annule).
set -uo pipefail
set +x   # jamais de trace : ni le token Gitea, ni le token Vault, ni le bearer
cd "$(dirname "$0")/.." || exit 1
# `set -e` n'est pas actif : sans ces garde-fous explicites, un fichier manquant
# laisserait bash CONTINUER et l'échec se présenterait bien plus bas comme
# « resolve_deploy_pin: command not found » — un fail-closed par accident, avec
# un message qui accuse la résolution au lieu du fichier absent.
# shellcheck source=scripts/lib/deploy-pin.sh
. scripts/lib/deploy-pin.sh    || { echo "ERREUR: scripts/lib/deploy-pin.sh introuvable" >&2; exit 1; }
# shellcheck source=scripts/lib/env-chain.sh
. scripts/lib/env-chain.sh     || { echo "ERREUR: scripts/lib/env-chain.sh introuvable" >&2; exit 1; }
# shellcheck source=scripts/lib/archive-store.sh
. scripts/lib/archive-store.sh || { echo "ERREUR: scripts/lib/archive-store.sh introuvable" >&2; exit 1; }

WEBHOOK_REPO="${WEBHOOK_REPO:?WEBHOOK_REPO requis (repository.full_name du webhook)}"
PR_BRANCH="${PR_BRANCH:?PR_BRANCH requis}"
PR_NUMBER="${PR_NUMBER:?PR_NUMBER requis}"
MERGE_SHA="${MERGE_SHA:?MERGE_SHA requis (merge_commit_sha du webhook)}"
GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN requis}"
VAULT_ADDR="${VAULT_ADDR:?VAULT_ADDR requis}"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:?VAULT_TOKEN_FILE requis (jamais le token en env/argv)}"
GIT_HOST="${GIT_HOST:-http://gitea:3000}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"        # dépôt PLATEFORME — porte providers.<env>.yml
GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"
# L'identité PROUVÉE (le login Vault de la pause nominative), posée par le
# Jenkinsfile depuis V_USER. Repli VIDE ici, refus NOMMÉ au §0bis : un `:?` posé
# dans les arguments de la garde d'identité tuerait bash sur place, sans passer
# par fail(), donc sans commenter la PR — la dette I2 que l'en-tête de
# team-publish.sh:39-51 déclare « À NE PAS REPRODUIRE ICI ».
VAULT_IDENTITY_USER="${VAULT_IDENTITY_USER:-}"
PROMOTE_ENGINE="${PROMOTE_ENGINE:-ansible}"     # ansible|labctl — knob de PIPELINE (D6)
ADMIN_VIA="${ADMIN_VIA:-proxy-oauth2}"          # proxy-oauth2|direct (D5)
# Gabarits d'URL admin par palier (__ENV__ substitué) — config client au Jenkinsfile.
APIM_API_BASE_TPL="${APIM_API_BASE_TPL:?APIM_API_BASE_TPL requis (ex: http://webmethods-real:5555/gateway/wm-admin-__ENV__/1.0/rest/apigateway)}"
# Second gabarit, REQUIS SEULEMENT en ADMIN_VIA=direct (attaque directe de la
# gateway, sans le proxy d'admin OAuth2) — vérifié dans le bloc de knobs.
APIM_DIRECT_BASE_TPL="${APIM_DIRECT_BASE_TPL:-}"
# G4 (ADR-082) : l'env d'AUTHORING est SCELLÉ sur la constante de lib —
# affectation sèche, jamais "${ENVN_AUTH:-dev}" : les paramètres d'un job
# Jenkins atterrissent dans l'environnement du process (fait mesuré, même
# raison que deploy-pin.sh:29-37). Il sert ici à DEUX choses : refuser une
# promotion « vers dev » (§1) et sceller l'extra-var du play (§8).
ENVN_AUTH="$DEPLOY_PIN_AUTHORING_ENV"
# Binaire du moteur labctl : le Jenkinsfile le builde dans $WORKSPACE (motif
# ci/Jenkinsfile:35-40). Résolu ICI, pas au site d'appel : sous `set -u`, un
# "$WORKSPACE" absent hors CI ferait mourir le script AU MOMENT DU MOTEUR — donc
# après toutes les gardes, avec un message qui n'a rien à voir.
LABCTL_BIN="${LABCTL_BIN:-${WORKSPACE:-.}/labctl}"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; umask 077

# Marqueur d'idempotence : STABLE par PR (pas par run), pour qu'un re-run sur la
# MÊME PR mette à jour plutôt que d'empiler — cf. scripts/lib/gitea-pr-comment.sh.
TEAM_PROMOTE_MARKER='<!-- team-promote -->'
comment(){
  local repo="$1" body="$2" bodyfile
  bodyfile="$TMP/comment-body"
  printf '%s\n' "$body" > "$bodyfile"
  GIT_REPO="$repo" GITEA_TOKEN="$GITEA_TOKEN" PR_NUMBER="$PR_NUMBER" GIT_HOST="$GIT_HOST" \
  COMMENT_MARKER="$TEAM_PROMOTE_MARKER" COMMENT_BODY_FILE="$bodyfile" \
    bash scripts/lib/gitea-pr-comment.sh \
    || echo "AVERTISSEMENT: échec de publication du commentaire sur ${repo}#${PR_NUMBER} — la décision (merge) reste actée, seul le RAPPORT a échoué" >&2
}
fail(){ comment "$WEBHOOK_REPO" "❌ team-promote : $*"; echo "ERREUR: $*" >&2; exit 1; }

# Clone AUTHENTIFIÉ (GITEA_TOKEN, header injecté via variables d'ENVIRONNEMENT
# GIT_CONFIG_COUNT/KEY/VALUE — jamais l'URL, jamais argv). Un clone ANONYME
# casserait sur un dépôt PRIVÉ — le dépôt plateforme ET le dépôt d'équipe le
# sont chez un client réel.
gclone(){
  local auth_b64
  auth_b64=$(printf 'x:%s' "$GITEA_TOKEN" | base64 | tr -d '\n')
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
    GIT_CONFIG_VALUE_0="Authorization: Basic ${auth_b64}" \
    git clone -q "$@"
}

# ── 0. VALIDATION DE FORME — AVANT tout argv git/curl ────────────────────────
# WEBHOOK_REPO et MERGE_SHA viennent d'un WEBHOOK (un tiers) et sont interpolés
# tels quels dans des URLs git/curl et des arguments de commande juste en
# dessous. Un refus de FORME, D'ABORD : il ferme la classe de trou « valeur de
# webhook mal formée qui atteint argv/une URL sans avoir été regardée » —
# indépendamment de ce que les gardes de topologie ou d'atteignabilité, plus
# bas, décideraient de cette même valeur si elle était bien formée.
case "$WEBHOOK_REPO" in *[!A-Za-z0-9_./-]*) fail "WEBHOOK_REPO_INVALIDE : '${WEBHOOK_REPO}' — caractère hors classe [A-Za-z0-9_./-]";; esac
printf '%s' "$WEBHOOK_REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
  || fail "WEBHOOK_REPO_INVALIDE : '${WEBHOOK_REPO}' — attendu owner/repo"

case "$MERGE_SHA" in *[!0-9a-f]*) fail "MERGE_SHA_INVALIDE : '${MERGE_SHA}' — caractère hors classe hexadécimale";; esac
printf '%s' "$MERGE_SHA" | grep -Eq '^[0-9a-f]{40}$' \
  || fail "MERGE_SHA_INVALIDE : '${MERGE_SHA}' — attendu 40 caractères hexadécimaux (SHA-1 git)"

# PR_NUMBER sert de segment d'URL API Gitea (réconciliation, commentaires).
case "$PR_NUMBER" in *[!0-9]*) fail "PR_NUMBER_INVALIDE : '${PR_NUMBER}' — caractère hors classe numérique";; esac
printf '%s' "$PR_NUMBER" | grep -Eq '^[1-9][0-9]*$' \
  || fail "PR_NUMBER_INVALIDE : '${PR_NUMBER}' — attendu un entier positif"

# ── 0bis. LES KNOBS DE PIPELINE, VALIDÉS AVANT TOUT ──────────────────────────
# `run_engine` a un `*)` qui rend 90 ; il est INATTEIGNABLE, et c'est voulu : un
# knob inconnu doit se dire ICI, en haut, avec les autres refus de forme et
# AVANT le moindre appel réseau — pas au fond d'un `case` où il ressemblerait à
# un code de retour de moteur.
# Le câblage du Jenkinsfile se refuse ICI, avec les autres knobs : une variable
# de pipeline absente est une erreur d'exploitant, elle doit se dire SUR LA PR
# comme n'importe quel refus — jamais par une mort silencieuse du shell.
[ -n "$VAULT_IDENTITY_USER" ] \
  || fail "IDENTITE_ABSENTE : VAULT_IDENTITY_USER n'est pas posée — le job doit l'exporter depuis V_USER (ci/lib/vault-login.sh) ; sans identité prouvée, la garde des quatre yeux ne compare rien"
case "$PROMOTE_ENGINE" in ansible|labctl) ;; *) fail "ENGINE_INCONNU : '$PROMOTE_ENGINE' — attendu 'ansible' ou 'labctl'";; esac
case "$ADMIN_VIA" in proxy-oauth2|direct) ;; *) fail "ADMIN_VIA_INCONNU : '$ADMIN_VIA' — attendu 'proxy-oauth2' ou 'direct'";; esac
if [ "$ADMIN_VIA" = direct ]; then
  [ -n "$APIM_DIRECT_BASE_TPL" ] \
    || fail "APIM_DIRECT_BASE_TPL_ABSENT : ADMIN_VIA=direct attaque la gateway sans le proxy d'admin — son gabarit d'URL doit être déclaré explicitement (dire sa cible est volontaire)"
  # LA COMBINAISON QUI N'EXISTE PAS, ET IL FAUT LE DIRE PLUTÔT QUE DE
  # L'IMPROVISER. En `direct`, l'admin s'authentifie en Basic avec les creds
  # wm-admin du palier. Le rôle Ansible sait le faire SANS jamais matérialiser
  # le secret : il lit Vault lui-même (apim_ss_vault_wm_creds_sub). Le moteur
  # labctl, lui, ne consomme qu'un FICHIER de bearer ou un couple
  # username/password inscrits dans son targets.yaml — donc un mot de passe
  # écrit sur disque par CE script. On refuse la combinaison au lieu d'écrire
  # ce fichier : un refus nommé coûte moins cher qu'un secret matérialisé.
  [ "$PROMOTE_ENGINE" != labctl ] \
    || fail "COMBINAISON_NON_SUPPORTEE : PROMOTE_ENGINE=labctl avec ADMIN_VIA=direct — le moteur labctl ne s'authentifie que par bearer (voie proxy-oauth2) ; en direct, utiliser le moteur ansible, qui lit les creds dans Vault sans les écrire sur disque"
fi

# ── 1. branche gardée à promote/*, sinon rien à faire ────────────────────────
case "$PR_BRANCH" in promote/*) ;; *) echo "hors promote/* — rien à promouvoir"; exit 0;; esac
REST="${PR_BRANCH#promote/}"
TO_ENV="${REST##*-}"; API_NAME="${REST%-*}"
[ -n "$API_NAME" ] && [ -n "$TO_ENV" ] && [ "$API_NAME" != "$REST" ] \
  || fail "BRANCH_FORMAT_INVALIDE : '${PR_BRANCH}' — attendu promote/<api>-<env>"

# Régime ancré (même classe et même ordre que dans team-publish.sh §1) : le
# refus de CLASSE d'abord (le `case`, contre \n et tout caractère hors
# alphabet), PUIS la forme complète ancrée. API_NAME devient un segment de
# CHEMIN (apis/<name>.deploy.<env>.yaml) et un segment d'URL de registre : un
# nom hors classe y serait une évasion de chemin, pas une coquetterie.
case "$API_NAME" in *[!a-z0-9-]*) fail "API_NAME_INVALIDE : '${API_NAME}' (branche '${PR_BRANCH}') — attendu ^[a-z0-9][a-z0-9-]{1,30}\$";; esac
printf '%s' "$API_NAME" | grep -Eq '^[a-z0-9][a-z0-9-]{1,30}$' \
  || fail "API_NAME_INVALIDE : '${API_NAME}' (branche '${PR_BRANCH}') — attendu ^[a-z0-9][a-z0-9-]{1,30}\$"
case "$TO_ENV" in *[!a-z0-9-]*) fail "ENV_INVALIDE : '${TO_ENV}' (branche '${PR_BRANCH}') — attendu des minuscules, chiffres et tirets";; esac
printf '%s' "$TO_ENV" | grep -Eq '^[a-z0-9][a-z0-9-]{0,30}$' \
  || fail "ENV_INVALIDE : '${TO_ENV}' (branche '${PR_BRANCH}') — attendu ^[a-z0-9][a-z0-9-]{0,30}\$"

# TO_ENV : un palier de la CHAÎNE, jamais l'authoring (une promotion va toujours
# vers un palier SUIVANT ; l'authoring suit HEAD et n'a pas de marqueur).
CHAIN="$(env_chain)" || fail "CHAINE_ILLISIBLE : environments.yaml absent, vide ou cassé"
case " $CHAIN " in *" $TO_ENV "*) ;; *) fail "ENV_INVALIDE : '$TO_ENV' hors de la chaîne ($CHAIN)";; esac
[ "$TO_ENV" != "$ENVN_AUTH" ] \
  || fail "ENV_INVALIDE : '$TO_ENV' est l'environnement d'authoring — rien ne s'y promeut (il suit HEAD par conception, ADR-079)"

# ── 1bis. LA VOIE DU TERMINUS — dérivée de la POSITION, jamais du nom ────────
# Aucun proxy wm-admin-<env> n'existe devant le DERNIER palier : l'exclusion
# est STRUCTURELLE (G4 — env_chain_nonprod partout, ci-horsprod sans le
# terminus). La voie y est donc DIRECTE (Basic, creds lus dans Vault par le
# rôle), quelle que soit la valeur du knob ADMIN_VIA — qui ne pilote QUE les
# paliers intermédiaires. Même dessin que ci/Jenkinsfile.rollback (G6) :
# terminus par position, deux voies.
TERMINUS="$(env_chain_terminus)" || fail "CHAINE_ILLISIBLE : terminus indéterminable (environments.yaml)"
if [ "$TO_ENV" = "$TERMINUS" ]; then
  [ -n "$APIM_DIRECT_BASE_TPL" ] \
    || fail "TERMINUS_SANS_VOIE : '$TO_ENV' est le terminus de la chaîne — pas de proxy wm-admin-<env> devant lui (exclusion structurelle G4) ; la voie directe exige APIM_DIRECT_BASE_TPL, et dire sa cible est volontaire"
  [ "$PROMOTE_ENGINE" != labctl ] \
    || fail "COMBINAISON_NON_SUPPORTEE : PROMOTE_ENGINE=labctl vers le terminus '$TO_ENV' — pas de proxy OAuth2 devant le terminus, et le moteur labctl ne s'authentifie que par bearer ; utiliser le moteur ansible (voie directe, creds lus dans Vault par le rôle, jamais écrits sur disque)"
  EFFECTIVE_VIA=direct
else
  EFFECTIVE_VIA="$ADMIN_VIA"
fi

# ── 2. RÉCONCILIATION AVEC GITEA — le payload n'est pas la vérité ────────────
# Le webhook n'a ni secret HMAC vérifié en aval ni garantie de fraîcheur : un
# tir manuel avec le token GWT partagé peut prétendre N'IMPORTE QUEL
# merge_commit_sha/branche pour ce PR_NUMBER. La garde d'atteignabilité (§4)
# confirme que MERGE_SHA est UN ancêtre de main — pas forcément CELUI de CETTE
# PR. On redemande donc l'état à GITEA LUI-MÊME (authentifié par GITEA_TOKEN,
# donc pas falsifiable par le contenu d'un payload).
#
# ⚠ ET ON EN RAMÈNE AUSSI LES DEUX IDENTITÉS. C'est l'écart délibéré avec les
# scripts frères : team-publish.sh, team-apply.sh et provision-apply.job.xml
# passent encore `PR_MERGED_BY`/`PR_REQUESTER` du PAYLOAD à la garde d'identité.
# Or `merged_by.login` dans une charge utile de webhook est une AFFIRMATION, pas
# un credential : un porteur du token GWT peut tirer le webhook sur une PR
# RÉELLEMENT mergée (donc la réconciliation ci-dessous passe) en s'annonçant
# lui-même comme mergeur et en inventant un demandeur — MERGER_MISMATCH et
# FOUR_EYES_VIOLATION passent tous les deux, et les quatre yeux ne sont plus
# qu'un décor. Ici cette classe est fermée : `merged_by.login` et `user.login`
# sont lus dans la MÊME réponse authentifiée, déjà en main.
# POURQUOI ICI ET PAS CHEZ LES FRÈRES : §6bis est la SEULE garde humaine de ce
# jalon, et sa cible est la prod. Le motif hérité reste à corriger ailleurs —
# c'est un périmètre, pas un oubli.
#
# Les deux logins remontent EMPAQUETÉS PAR LIGNES et sont donc, eux aussi,
# forgeables par un saut de ligne (même classe que le §6 et que
# deploy-pin.sh:117-125) : on REFUSE le délimiteur dans la valeur plutôt que
# d'espérer qu'il n'y soit pas.
PR_STATE=$(GIT_HOST="$GIT_HOST" WEBHOOK_REPO="$WEBHOOK_REPO" PR_NUMBER="$PR_NUMBER" \
  GITEA_TOKEN="$GITEA_TOKEN" PR_BRANCH="$PR_BRANCH" MERGE_SHA="$MERGE_SHA" python3 - <<'PY'
import os, json, urllib.request, urllib.error
api = os.environ["GIT_HOST"] + "/api/v1"
repo = os.environ["WEBHOOK_REPO"]
pr = os.environ["PR_NUMBER"]
req = urllib.request.Request(f"{api}/repos/{repo}/pulls/{pr}",
    headers={"Authorization": "token " + os.environ["GITEA_TOKEN"]})
try:
    d = json.load(urllib.request.urlopen(req))
except (urllib.error.URLError, ValueError) as e:
    print("ERR=" + type(e).__name__)
    raise SystemExit
ok = (
    d.get("merged") is True
    and d.get("merge_commit_sha") == os.environ["MERGE_SHA"]
    and (d.get("head") or {}).get("ref") == os.environ["PR_BRANCH"]
    and (d.get("base") or {}).get("ref") == "main"
)
mb = str((d.get("merged_by") or {}).get("login") or "")
rq = str((d.get("user") or {}).get("login") or "")
for name, val in (("merged_by.login", mb), ("user.login", rq)):
    if "\n" in val or "\r" in val:
        print("FORGE=" + name)
        raise SystemExit
print("OK" if ok else "MISMATCH")
print("MB=" + mb)
print("RQ=" + rq)
PY
) || fail "GITEA_RECONCILE_ECHEC : lecture de ${WEBHOOK_REPO}#${PR_NUMBER} sur Gitea en échec"
PR_VERDICT=$(printf '%s\n' "$PR_STATE" | sed -n '1p')
# Les identités RÉCONCILIÉES — ce sont ELLES, et jamais $PR_MERGED_BY /
# $PR_REQUESTER du webhook, qui alimentent la garde d'identité (§6bis).
GITEA_MERGED_BY=$(printf '%s\n' "$PR_STATE" | sed -n 's/^MB=//p')
GITEA_REQUESTER=$(printf '%s\n' "$PR_STATE" | sed -n 's/^RQ=//p')
case "$PR_VERDICT" in
  OK) ;;
  ERR=*) fail "GITEA_RECONCILE_ECHEC : appel Gitea en échec (${PR_VERDICT#ERR=}) pour ${WEBHOOK_REPO}#${PR_NUMBER}" ;;
  FORGE=*) fail "GITEA_RECONCILE_ECHEC : le champ ${PR_VERDICT#FORGE=} de ${WEBHOOK_REPO}#${PR_NUMBER} contient un saut de ligne — une identité ne fabrique pas de champ, refus" ;;
  MISMATCH) fail "PAYLOAD_PERIME : ${WEBHOOK_REPO}#${PR_NUMBER} sur Gitea (merged/merge_commit_sha/head.ref/base.ref) ne correspond pas au webhook — le payload ne fait pas foi, refus" ;;
  *) fail "GITEA_RECONCILE_ECHEC : réponse inattendue de la réconciliation ('${PR_VERDICT}')" ;;
esac
# FAIL-CLOSED, ET REFUSÉ ICI PLUTÔT QU'AU §6bis. La bibliothèque d'identité
# refuse déjà MERGER_UNKNOWN sur un mergeur vide — mais son message accuse le
# CÂBLAGE du webhook (« ajouter le champ aux genericVariables »), alors que la
# cause est ici tout autre : Gitea LUI-MÊME ne nomme aucun mergeur sur cette PR.
# On le dit donc à l'endroit exact où on l'apprend, ce qui refuse en prime AVANT
# les trois clones et le fetch d'archive qui séparent §2 de §6bis — un refus qui
# ne peut pas ne pas arriver n'a aucune raison d'attendre.
[ -n "$GITEA_MERGED_BY" ] \
  || fail "MERGER_UNKNOWN : Gitea ne nomme aucun mergeur sur ${WEBHOOK_REPO}#${PR_NUMBER} (merged_by absent de la réponse) — la garde d'identité ne pourrait RIEN vérifier, refus"
# L'auteur de la PR n'alimente AUCUNE garde (cf. §6bis : le demandeur, c'est
# `promoted_by` du marqueur) — il est journalisé comme diagnostic, et parce que
# le voir valoir `ci` build après build est la façon la plus rapide de
# comprendre pourquoi les quatre yeux ne mordent pas encore.
echo "réconciliation Gitea OK : ${WEBHOOK_REPO}#${PR_NUMBER} merged, ${PR_BRANCH}->main, mergeur '${GITEA_MERGED_BY}', PR ouverte par '${GITEA_REQUESTER}'"

# ── 3. AUTORITÉ PAR TOPOLOGIE : quelle équipe déclare CE dépôt ? ─────────────
# Le webhook dit QUEL DÉPÔT a mergé (repository.full_name) — jamais quelle
# équipe. Une "team" dans le payload serait une AFFIRMATION du dépôt de l'équipe
# lui-même. L'équipe est dérivée en CROISANT ce dépôt avec providers.<env>.yml
# — dépôt PLATEFORME, lu FRAIS sur main. Ici elle sert aussi de segment d'URL au
# registre d'archives (§5) : une équipe devinée y désignerait les octets de
# quelqu'un d'autre.
#
# ⚠ providers.<env>.yml est lu à l'env d'AUTHORING, pas à TO_ENV : la topologie
# « quel dépôt appartient à quelle équipe » ne dépend pas du palier visé (même
# fichier que team-publish.sh §3 ; un providers.prod.yml séparé n'existe pas).
gclone --depth 1 -b main "${GIT_HOST}/${GIT_REPO}.git" "$TMP/platform" \
  || fail "clone ${GIT_REPO}@main (résolution dépôt -> équipe)"
PROV="$TMP/platform/poc-control-plane-federation/ansible/providers.${ENVN_AUTH}.yml"
[ -f "$PROV" ] || fail "PROVIDERS_MISSING : ansible/providers.${ENVN_AUTH}.yml absent sur main"

# FAIL-CLOSED supplémentaire (REPO_AMBIGU) : si CE dépôt est déclaré par PLUS
# D'UNE équipe (copier-coller de providers.<env>.yml), prendre la première
# rencontrée serait deviner laquelle promeut.
TEAM=$(REPO="$WEBHOOK_REPO" PROV="$PROV" python3 - <<'PY'
import os, yaml
d = yaml.safe_load(open(os.environ["PROV"])) or {}
matches = [p for p in (d.get("providers") or []) if (p.get("repo") or "") == os.environ["REPO"]]
if len(matches) > 1:
    print("AMBIGU=" + ",".join(sorted((m.get("team") or "(sans nom)") for m in matches)))
else:
    team = (matches[0].get("team") or "") if matches else ""
    print("TEAM=" + team)
PY
) || fail "PARSE_PROVIDERS : lecture de providers.${ENVN_AUTH}.yml pour ${WEBHOOK_REPO}"
case "$TEAM" in
  AMBIGU=*) fail "REPO_AMBIGU : ${WEBHOOK_REPO} est déclaré par plusieurs équipes dans providers.${ENVN_AUTH}.yml (${TEAM#AMBIGU=}) — corriger providers.${ENVN_AUTH}.yml avant de promouvoir, aucune équipe ne peut être choisie sans arbitraire" ;;
  TEAM=)    fail "REPO_NON_DECLARE : ${WEBHOOK_REPO} n'appartient à aucune équipe de providers.${ENVN_AUTH}.yml — refus" ;;
  TEAM=*)   TEAM="${TEAM#TEAM=}" ;;
  *)        fail "PARSE_PROVIDERS : sortie inattendue de l'extraction équipe pour ${WEBHOOK_REPO} (ni échec ni marqueur TEAM=/AMBIGU=)" ;;
esac
echo "topologie : dépôt ${WEBHOOK_REPO} -> équipe '${TEAM}' (providers.${ENVN_AUTH}.yml)"

# ── 4. ANTI-TOCTOU : le dépôt d'ÉQUIPE lu AU SHA DU MERGE ────────────────────
# Clone COMPLET (pas --depth 1) : le SHA de merge doit être atteignable par un
# checkout, une profondeur tronquée pourrait ne pas le contenir.
gclone "${GIT_HOST}/${WEBHOOK_REPO}.git" "$TMP/team" \
  || fail "clone ${WEBHOOK_REPO} (dépôt de l'équipe)"
git -C "$TMP/team" checkout -q "$MERGE_SHA" \
  || fail "checkout du SHA de merge ${MERGE_SHA} sur ${WEBHOOK_REPO}"

# GARDE D'ATTEIGNABILITÉ : un `git checkout $MERGE_SHA` réussi prouve seulement
# que l'OBJET existe quelque part dans le clone (un `git clone` SANS --depth 1
# récupère TOUTES les branches) — jamais qu'il est réellement fusionné sur main.
git -C "$TMP/team" merge-base --is-ancestor "$MERGE_SHA" origin/main \
  || fail "MERGE_SHA_NON_ANCETRE : ${MERGE_SHA} n'est pas un ancêtre de ${WEBHOOK_REPO}@main — le SHA du webhook ne correspond pas à un commit réellement fusionné sur la branche protégée, refus de promouvoir depuis un état non revu"

# ── 5. LE MARQUEUR : digest pré-lu, archive fetchée, PUIS résolveur complet ──
# L'ordre est contraint par les interfaces : resolve_deploy_pin exige l'archive
# (6e arg) pour vérifier le digest, et le digest attendu vit DANS le marqueur.
# On pré-lit donc UNIQUEMENT archive_sha256 (au SHA mergé, jamais le worktree),
# on fetch par contenu, et le résolveur re-vérifie TOUT (pin, ancêtreté,
# version, digest — une divergence refusera là-bas, pas ici).
MARKER_REL="$(deploy_pin_marker_path "$API_NAME" "$TO_ENV")"
git -C "$TMP/team" show "${MERGE_SHA}:${MARKER_REL}" > "$TMP/marker.yaml" 2>/dev/null \
  || fail "PIN_ABSENT : ${MARKER_REL} absent au SHA mergé — la PR ne portait pas le marqueur"
PRE_SHA=$(DP_FILE="$TMP/marker.yaml" python3 -c 'import os,yaml;d=yaml.safe_load(open(os.environ["DP_FILE"])) or {};print(str(d.get("archive_sha256") or ""))') \
  || fail "PIN_MALFORMED : ${MARKER_REL} illisible"
case "$PRE_SHA" in *[!0-9a-f]*|"") fail "DIGEST_ABSENT : archive_sha256 absent/malformé dans ${MARKER_REL}";; esac
[ "${#PRE_SHA}" -eq 64 ] || fail "DIGEST_ABSENT : archive_sha256 long de ${#PRE_SHA}"

# ⚠ LE JETON DU REFUS SOUS-JACENT PORTE DES CHIFFRES (STORE_HTTP_404). Une
# classe [A-Z_] seule tronquerait « STORE_HTTP_404 » en « STORE_HTTP_ » et le
# lecteur de la PR perdrait précisément l'information qui distingue « jamais
# poussée » (404) de « registre en panne » (5xx).
archive_store_fetch "$TEAM" "$API_NAME" "$PRE_SHA" "$TMP/archive.zip" 2>"$TMP/store.err" \
  || { cat "$TMP/store.err" >&2
       REFUS="$(grep -o 'archive-store: [A-Z_0-9]*' "$TMP/store.err" | tail -1)"
       fail "ARCHIVE_INTROUVABLE : ${REFUS:-voir le log} — l'export a-t-il été poussé au registre ?"; }

# Le refus PRÉCIS du résolveur (PIN_ABSENT, PIN_NON_ANCETRE, PIN_VERSION_MISMATCH,
# ARCHIVE_DIGEST_MISMATCH…) part sur stderr — un lecteur de PR ne voit pas le log
# Jenkins. On capture stderr en FICHIER (jamais un pipe : pipefail + le résolveur
# sort 1) et le dernier jeton nommé rejoint le commentaire.
resolve_deploy_pin "$TMP/team" "$API_NAME" "$TO_ENV" "$TMP/resolved" origin/main "$TMP/archive.zip" \
  2>"$TMP/pin.err" || { cat "$TMP/pin.err" >&2
       REFUS="$(grep -o 'deploy-pin: [A-Z_0-9]*' "$TMP/pin.err" | tail -1)"
       fail "PIN_NON_RESOLU : la référence de déploiement de ${API_NAME} en ${TO_ENV} n'a pas pu être résolue (${REFUS:-refus non nommé — voir le log du build})"; }

# ── 6. LES EXIGENCES DE LA PORTE, RELUES SUR LE MARQUEUR MERGÉ ───────────────
# Le formulaire les a validées À LA DEMANDE ; on les re-vérifie sur ce qui a été
# MERGÉ (anti-TOCTOU : un marqueur édité entre la demande et le merge ne doit
# pas passer parce que le formulaire, lui, était propre).
GATE=$(env_chain_gate "$TO_ENV") || fail "PARSE_GATE : lecture de la porte vers '$TO_ENV'"
case "$GATE" in GATE=*) GATE="${GATE#GATE=}";; *) fail "PARSE_GATE : sortie inattendue";; esac
NEED_CHANGE="${GATE%%|*}"; GATE="${GATE#*|}"; NEED_PV="${GATE%%|*}"
#
# ⚠ LES DEUX VALEURS VOYAGENT EMPAQUETÉES PAR LIGNES, DONC LE SAUT DE LIGNE EST
# UN DÉLIMITEUR — et un délimiteur qu'on laisse passer dans une valeur décale
# les frontières de champ. Mesuré : un marqueur portant
#   change_ref: "CHG-1\nPV=FORGE"
# produisait `CR=CHG-1`, puis `PV=FORGE` (injectée) AVANT le vrai `PV=` vide ;
# `sed -n 's/^PV=//p'` rendait les deux, `[ -n … ]` voyait du texte, et la porte
# homol/prod acceptait une promotion SANS PV. Le fail-open exact que ce §6
# existe pour fermer.
#
# ⚠ ET « REF_INVALIDE le ferme déjà à la demande » NE RÉPOND PAS : cette garde-ci
# n'existe QUE parce que le marqueur peut être édité entre la demande et le
# merge. La valider au formulaire ne dit rien de ce qui a été MERGÉ.
#
# On REFUSE donc le délimiteur dans la valeur plutôt que d'espérer qu'il n'y
# soit pas — la règle que deploy-pin.sh:117-125 applique déjà au '|', et la
# condition que deploy-pin.sh:327-333 invoque pour s'autoriser le découpage par
# ligne (« les deux valeurs sont hexadécimales … une nouvelle ligne ne peut donc
# pas s'y cacher »). Ici les valeurs sont du texte libre : il faut le verrou.
#
# `promoted_by` est lu ICI AUSSI, et c'est LUI le demandeur de la promotion —
# voir la garde d'identité (§6bis) pour ce que ça change et ce que ça ne change
# pas encore.
MK_FIELDS=$(DP_FILE="$TMP/marker.yaml" python3 - 2>"$TMP/mkfields.err" <<'PY'
import os, sys, yaml
d = yaml.safe_load(open(os.environ["DP_FILE"])) or {}
out = []
for key in ("change_ref", "pv_ref", "promoted_by"):
    v = str(d.get(key) or "")
    if "\n" in v or "\r" in v:
        sys.exit("le champ %s contient un saut de ligne (il fabriquerait un champ)" % key)
    out.append(v)
sys.stdout.write("CR=%s\nPV=%s\nPB=%s\n" % (out[0], out[1], out[2]))
PY
) || { cat "$TMP/mkfields.err" >&2
       MKERR="$(tail -1 "$TMP/mkfields.err" 2>/dev/null)"
       fail "PIN_MALFORMED : relecture des références de ${MARKER_REL} — ${MKERR:-YAML illisible}"; }
MK_CHANGE=$(printf '%s\n' "$MK_FIELDS" | sed -n 's/^CR=//p')
MK_PV=$(printf '%s\n' "$MK_FIELDS" | sed -n 's/^PV=//p')
MK_PROMOTED_BY=$(printf '%s\n' "$MK_FIELDS" | sed -n 's/^PB=//p')
[ "$NEED_CHANGE" = 0 ] || [ -n "$MK_CHANGE" ] \
  || fail "GATE_REFS_REQUIRED : la porte vers '$TO_ENV' exige change_ref — absent du marqueur mergé"
[ "$NEED_PV" = 0 ] || [ -n "$MK_PV" ] \
  || fail "GATE_REFS_REQUIRED : la porte vers '$TO_ENV' exige pv_ref — absent du marqueur mergé"

# ── 6bis. LA GARDE D'IDENTITÉ ────────────────────────────────────────────────
# Elle passe AVANT la lecture Vault (§7) et non après : elle ne touche aucun
# secret, donc il n'y a aucune raison de présenter un token au palier avant de
# savoir si la personne qui répond à la pause est bien celle qui a mergé.
# Les quatre yeux sont une décision de PORTE (environments.yaml) : le script ne
# l'invente pas, il la lit — et quand la porte ne les exige pas, il le DIT.
FE=$(env_chain_gate_four_eyes "$TO_ENV") || fail "PARSE_GATE : fourEyes"
case "$FE" in
  FOUREYES=1) AMI_ARGS="";;
  FOUREYES=0) AMI_ARGS="--allow-self-approval";;
  *) fail "PARSE_GATE : sortie inattendue ($FE)";;
esac

# ⚠ LE DEMANDEUR EST `promoted_by` DU MARQUEUR MERGÉ, PAS L'AUTEUR DE LA PR.
# La distinction n'est pas cosmétique : `api-promote-request.sh` ouvre la PR
# avec GITEA_TOKEN, donc son AUTEUR (`user.login`, réconcilié en §2) est le
# COMPTE DE SERVICE du CI, pas l'humain qui a rempli le formulaire. Comparer
# mergeur et auteur de PR reviendrait à comparer un humain à `ci` : la
# comparaison ne serait jamais vraie, et les quatre yeux ne refuseraient
# JAMAIS — une garde verte qui ne garde rien. Le seul champ qui prétend nommer
# le demandeur est `promoted_by`, écrit dans le marqueur au moment de la
# demande, relu ici sur l'état MERGÉ (donc soumis au même anti-TOCTOU que les
# références de porte, et au même refus de saut de ligne).
#
# ⚠ ET IL FAUT DIRE JUSQU'OÙ ÇA VA AUJOURD'HUI, SANS LE MAQUILLER : `promoted_by`
# vaut `ci` tant que le plugin Jenkins `build-user-vars` n'est pas provisionné
# (ci/Jenkinsfile.api-promote-request pose `PROMOTED_BY=${BUILD_USER_ID ?: 'ci'}`
# et rien dans ce dépôt n'installe ce plugin — le gabarit
# clients/_example/apis/accounts-read.deploy.rec.yaml.example le documente
# déjà). Donc : LE CONTRÔLE À QUATRE YEUX RESTE INERTE TANT QUE CE PLUGIN
# MANQUE. Ce n'est pas un défaut de ce fichier et ce n'est pas réparable ici ;
# c'est écrit là pour être LU avant d'être découvert en audit.
# Ce que ce câblage garantit en revanche dès maintenant : aucun FAUX refus. Le
# mergeur est un humain réconcilié auprès de Gitea, donc `merger == "ci"` ne
# peut pas se produire par accident — le jour où `promoted_by` nommera
# quelqu'un, la garde se mettra à mordre sans qu'une ligne change ici.
if [ "$AMI_ARGS" = "" ] && [ -z "$MK_PROMOTED_BY" ]; then
  # Porte à quatre yeux + marqueur sans demandeur : il n'y a rien à comparer,
  # et une chaîne vide passerait pour « différente du mergeur », donc pour un
  # succès. Refus — le fail-open classique des deux vides (même piège que
  # MERGER_UNKNOWN dans la bibliothèque). Sur une porte selfApproval, au
  # contraire, un promoted_by vide ne bloque rien : le bloc quatre yeux est
  # sauté de toute façon, exiger le champ n'y protégerait personne.
  fail "MERGER_UNKNOWN : la porte vers '$TO_ENV' exige les quatre yeux, mais ${MARKER_REL} ne porte aucun promoted_by — impossible de vérifier que le mergeur n'est pas le demandeur, refus"
fi
# ⚠ LES IDENTITÉS NE VIENNENT PAS DU WEBHOOK. $PR_MERGED_BY et $PR_REQUESTER ne
# sont volontairement pas lus dans ce script : ce sont des affirmations d'un
# payload non authentifié, et les faire piloter la garde reviendrait à laisser
# l'attaquant choisir les deux termes de la comparaison. Le mergeur vient de
# Gitea (§2, authentifié) ; le demandeur, du marqueur mergé (§6).
# shellcheck disable=SC2086
sh scripts/lib/assert-merge-identity.sh --merged-by "$GITEA_MERGED_BY" \
  --requester "$MK_PROMOTED_BY" --vault-user "$VAULT_IDENTITY_USER" $AMI_ARGS \
  || fail "IDENTITE_REFUSEE : la garde d'identité a refusé (voir le log)"

# ── 7. LA PORTE DU PALIER : DÉCLARATION (G2) PUIS RÉTENTION (G4) ────────────
# Le token ne transite ni par argv ni par l'environnement : `printf` est un
# BUILTIN et `tr` lit le fichier sur son stdin — la valeur ne touche jamais la
# ligne de commande d'un process exécuté (motif header-file d'archive-store.sh,
# durci d'un cran). `vcurl`/`$TMP/vhdr`, construits ici, servent aux deux
# sous-portes qui suivent : 7.a (déclaration du déployeur) et 7.b (rétention
# du palier).
[ -s "$VAULT_TOKEN_FILE" ] || fail "VAULT_TOKEN_ILLISIBLE : ${VAULT_TOKEN_FILE} vide ou absent"
{ printf 'X-Vault-Token: '; tr -d '\r\n' < "$VAULT_TOKEN_FILE"; printf '\n'; } > "$TMP/vhdr" \
  || fail "VAULT_TOKEN_ILLISIBLE : ${VAULT_TOKEN_FILE}"
vcurl(){ curl -sS -H @"$TMP/vhdr" "$@"; }

# ── 7.a LA DÉCLARATION : QUI DÉPLOIE CE PALIER ? (G2 — ADR-084) ──────────────
# La porte peut nommer un groupe déployeur (annuaire n°2, LDAP→policy Vault —
# jamais la claim KC : ici, la seule identité vérifiée est le token Vault de la
# pause, et V_USER == mergeur est déjà scellé par MERGER_MISMATCH en §6bis).
# Le refus est DÉCLARATIF et NOMMÉ, et précède la rétention (§7.b) : d'abord
# « la chaîne dit QUI », ensuite « ton ticket ouvre-t-il ». Pas de déclaration
# ⇒ AUCUN lookup (rec : autonomie du demandeur, décision client n°1) — la
# rétention §7.b reste inconditionnelle dans tous les cas.
DEPLOYER_GROUP=$(env_chain_gate_deployer_group "$TO_ENV") || fail "PARSE_GATE : deployerGroup"
if [ -n "$DEPLOYER_GROUP" ]; then
  DEPLOYER_POLICY=$(deployer_group_policy "$DEPLOYER_GROUP") \
    || fail "DEPLOYER_GROUP_UNSUPPORTED : '$DEPLOYER_GROUP' est hors des deux familles vérifiables (apim-apply-<x> | apim-operator-<x>) — déclaration invérifiable, refus fail-closed"
  LOOKUP_CODE=$(vcurl -o "$TMP/lookup.json" -w '%{http_code}' --max-time 20 \
    "${VAULT_ADDR}/v1/auth/token/lookup-self") || LOOKUP_CODE=000
  [ "$LOOKUP_CODE" = 200 ] \
    || fail "DEPLOYER_GROUP_UNVERIFIABLE : lookup-self HTTP ${LOOKUP_CODE} — l'identité du porteur est invérifiable, refus fail-closed"
  DEPPOL_VERDICT=$(SRC="$TMP/lookup.json" POL="$DEPLOYER_POLICY" python3 - <<'PY'
import json, os
d = (json.load(open(os.environ["SRC"])) or {}).get("data") or {}
pols = set((d.get("policies") or []) + (d.get("identity_policies") or []))
print("OK" if os.environ["POL"] in pols else "KO")
PY
) || fail "DEPLOYER_GROUP_UNVERIFIABLE : lookup-self illisible"
  [ "$DEPPOL_VERDICT" = OK ] \
    || fail "DEPLOYER_GROUP_REQUIRED : la porte vers '$TO_ENV' déclare le groupe déployeur '$DEPLOYER_GROUP' (policy projetée '$DEPLOYER_POLICY') — le token de l'identité '$VAULT_IDENTITY_USER' ne la porte pas, refus"
  echo "déclaration déployeur : '$VAULT_IDENTITY_USER' porte '$DEPLOYER_POLICY' (groupe '$DEPLOYER_GROUP')"
fi

# ── 7.b LE PALIER EST-IL OUVERT ? (rétention G4 — ADR-082) ──────────────────
# La lecture du secret d'admin du palier EST le ticket d'entrée : palier jamais
# ouvert (policy apply-<env> non accordée / AppRole non minté) => 403 Vault =>
# refus nommé, gateway JAMAIS touchée. C'est le seul contrôle qu'un pipeline
# compromis ne se donne pas à lui-même : toutes les gardes précédentes sont
# in-repo (OWASP CICD-SEC-04), celle-ci est une RÉTENTION DE CREDENTIAL, hors
# de portée de quiconque édite ce dépôt.
#
# ⚠ C'EST LE TICKET QUI COMPTE, PAS LE CONTENU. Sur le chemin proxy-oauth2 rien
# ici ne consomme le secret lu : c'est le rôle Ansible qui relira Vault
# lui-même (apim_ss_vault_oauth_sub). Le geste est donc un CONTRÔLE D'ACCÈS
# converti en porte — exactement le modèle des « environment secrets » GitHub :
# le palier est ouvert parce que l'identité peut lire son secret, pas parce
# qu'un booléen quelque part le dit.
WM_ADMIN_CODE=$(vcurl -o "$TMP/wmadmin.json" -w '%{http_code}' --max-time 20 \
  "${VAULT_ADDR}/v1/secret/data/stoa/envs/${TO_ENV}/wm-admin") || WM_ADMIN_CODE=000
[ "$WM_ADMIN_CODE" = 200 ] \
  || fail "PALIER_FERME : lecture de envs/${TO_ENV}/wm-admin refusée (HTTP ${WM_ADMIN_CODE}) — le palier '$TO_ENV' n'est pas ouvert pour cette identité (ADR-082 : l'ouverture est un geste de credential, pas un edit de code)"
echo "palier ouvert : envs/${TO_ENV}/wm-admin lisible par l'identité du build"

# ── 8. LE MOTEUR — UN SEUL SITE D'APPEL, APRÈS TOUT ─────────────────────────
# La base d'admin du palier. En proxy-oauth2 c'est le proxy d'admin (qui porte
# lui-même l'authentification) ; en direct c'est la gateway. EFFECTIVE_VIA
# (§1bis) : direct FORCÉ pour le terminus, sinon le knob ADMIN_VIA.
if [ "$EFFECTIVE_VIA" = direct ]; then
  APIM_BASE="$(printf '%s' "$APIM_DIRECT_BASE_TPL" | sed "s/__ENV__/${TO_ENV}/g")"
else
  APIM_BASE="$(printf '%s' "$APIM_API_BASE_TPL" | sed "s/__ENV__/${TO_ENV}/g")"
fi
case "$APIM_BASE" in
  http://*|https://*) ;;
  *) fail "APIM_BASE_INVALIDE : '${APIM_BASE}' — le gabarit d'URL admin doit produire une URL http(s)" ;;
esac

# La voie d'admin, en extra-vars. Un TABLEAU, pas une chaîne : sous `set -u` en
# bash 3.2 un tableau VIDE est un piège, mais les deux branches en posent
# toujours deux — et un tableau ne se fait pas redécouper par le shell le jour
# où une valeur portera un caractère inattendu.
if [ "$EFFECTIVE_VIA" = direct ]; then
  ENGINE_AUTH_ARGS=(-e apim_ss_auth_mode=basic -e "apim_ss_vault_wm_creds_sub=envs/${TO_ENV}/wm-admin")
else
  ENGINE_AUTH_ARGS=(-e apim_ss_auth_mode=oauth2 -e "apim_ss_vault_oauth_sub=envs/${TO_ENV}/admin-oauth")
fi

# ── 8bis. chemin labctl : le bearer et la cible, AVANT le moteur ─────────────
# Le moteur labctl ne sait pas parler à Vault pour son admin : il consomme un
# FICHIER de bearer (0600, lu une fois à la construction de l'adaptateur). On le
# frappe donc ici — et un échec de frappe est un refus NOMMÉ qui se produit,
# comme tous les autres, avant run_engine.
if [ "$PROMOTE_ENGINE" = labctl ]; then
  OA_CODE=$(vcurl -o "$TMP/oauth.json" -w '%{http_code}' --max-time 20 \
    "${VAULT_ADDR}/v1/secret/data/stoa/envs/${TO_ENV}/admin-oauth") || OA_CODE=000
  [ "$OA_CODE" = 200 ] \
    || fail "BEARER_ECHEC : lecture de envs/${TO_ENV}/admin-oauth refusée (HTTP ${OA_CODE}) — le moteur labctl s'authentifie par bearer et ne peut pas le frapper"
  # Le SECRET n'est jamais rendu au shell : python l'écrit directement dans un
  # fichier (umask 077), et curl le lira PAR FICHIER. Les autres champs, eux,
  # ne sont pas des secrets.
  OA_FIELDS=$(SRC="$TMP/oauth.json" CS="$TMP/client-secret" python3 - <<'PY'
import json, os, sys
d = (json.load(open(os.environ["SRC"])).get("data") or {}).get("data") or {}
sec = str(d.get("client_secret") or "")
if not sec:
    sys.exit("champ client_secret absent")
# SANS saut de ligne final : curl --data-urlencode name@fichier encode le
# contenu TEL QUEL — un "\n" oublié partirait en %0A dans le secret.
with open(os.environ["CS"], "w") as f:
    f.write(sec)
print("URL=%s\nCID=%s\nSCOPE=%s" % (
    str(d.get("token_url") or ""), str(d.get("client_id") or ""), str(d.get("scope") or "")))
PY
) || fail "BEARER_ECHEC : envs/${TO_ENV}/admin-oauth ne porte pas les champs attendus (token_url, client_id, client_secret, scope)"
  OA_URL=$(printf '%s\n' "$OA_FIELDS" | sed -n 's/^URL=//p')
  OA_CID=$(printf '%s\n' "$OA_FIELDS" | sed -n 's/^CID=//p')
  OA_SCOPE=$(printf '%s\n' "$OA_FIELDS" | sed -n 's/^SCOPE=//p')
  case "$OA_URL" in
    http://*|https://*) ;;
    *) fail "BEARER_ECHEC : token_url absent ou non http(s) dans envs/${TO_ENV}/admin-oauth" ;;
  esac
  [ -n "$OA_CID" ] || fail "BEARER_ECHEC : client_id absent dans envs/${TO_ENV}/admin-oauth"

  # LE SECRET N'EST PAS EN ARGV : `--data-urlencode "client_secret@<fichier>"`
  # fait lire le corps à curl DEPUIS LE FICHIER (le client_id, lui, n'est pas un
  # secret et reste un argument lisible). Un `-d "client_secret=$X"` l'aurait
  # exposé dans /proc/<pid>/cmdline le temps de l'appel.
  TOKEN_ARGS=(--data-urlencode grant_type=client_credentials
              --data-urlencode "client_id=${OA_CID}"
              --data-urlencode "client_secret@${TMP}/client-secret")
  [ -z "$OA_SCOPE" ] || TOKEN_ARGS+=(--data-urlencode "scope=${OA_SCOPE}")
  TOK_CODE=$(curl -sS -o "$TMP/token.json" -w '%{http_code}' --max-time 30 \
    "${TOKEN_ARGS[@]}" "$OA_URL") || TOK_CODE=000
  rm -f "$TMP/client-secret"
  [ "$TOK_CODE" = 200 ] \
    || fail "BEARER_ECHEC : le token endpoint a répondu HTTP ${TOK_CODE} (client_credentials sur ${OA_URL})"
  SRC="$TMP/token.json" OUT="$TMP/bearer" python3 - <<'PY' || fail "BEARER_ECHEC : réponse du token endpoint sans access_token"
import json, os, sys
t = str(json.load(open(os.environ["SRC"])).get("access_token") or "")
if not t:
    sys.exit("access_token absent")
open(os.environ["OUT"], "w").write(t)
PY
  chmod 600 "$TMP/bearer" \
    || fail "BEARER_ECHEC : impossible de restreindre les droits de $TMP/bearer (le driver webMethods refuse un fichier lisible par le groupe)"

  # LA CIBLE. ⚠ adminUrl NE PORTE PAS le suffixe /rest/apigateway : l'adaptateur
  # l'ajoute lui-même (labctl/internal/adapter/webmethods/webmethods.go:48). Le
  # gabarit APIM_API_BASE_TPL, lui, l'inclut (c'est le contrat du rôle Ansible,
  # roles/apim_common/defaults/main.yml). On le retire donc ici, une fois — le
  # laisser produirait des appels sur /rest/apigateway/rest/apigateway/*.
  LABCTL_ADMIN_URL="${APIM_BASE%/}"
  LABCTL_ADMIN_URL="${LABCTL_ADMIN_URL%/rest/apigateway}"
  # Le fichier de cibles est SÉRIALISÉ, pas formaté : même discipline que le
  # marqueur (api-promote-request.sh) — une valeur ne doit pas pouvoir fabriquer
  # une clé YAML. Structure calquée sur envs/rec/targets.cluster.yaml (le
  # chargeur exige contract + au moins une cible nommée/typée avec adminUrl, et
  # EXACTEMENT un mode d'auth — ici bearerTokenFile).
  NAME="$API_NAME" ENVN="$TO_ENV" ADMIN="$LABCTL_ADMIN_URL" \
  CONTRACT="$DEPLOY_PIN_CONTRACT" BEARER="$TMP/bearer" OUT="$TMP/targets.yaml" \
    python3 - <<'PY' || fail "TARGETS_NON_ECRIT : génération de $TMP/targets.yaml en échec"
import os
import yaml

with open(os.environ["OUT"], "w") as f:
    yaml.safe_dump({
        "apiVersion": "labctl.stoa.io/v1",
        "kind": "FederationTarget",
        "name": os.environ["NAME"],
        "contract": os.environ["CONTRACT"],
        "targets": [{
            "name": "wm-" + os.environ["ENVN"],
            "type": "webmethods",
            "adminUrl": os.environ["ADMIN"],
            "gatewayUrl": os.environ["ADMIN"],
            "credentials": {"bearerTokenFile": os.environ["BEARER"]},
        }],
    }, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
PY
  [ -s "$TMP/targets.yaml" ] || fail "TARGETS_NON_ECRIT : $TMP/targets.yaml vide"
fi

# LE SITE D'APPEL, UNIQUE. Tout ce qui précède a déjà refusé ; ici on exécute.
run_engine() {
  case "$PROMOTE_ENGINE" in
    ansible)
      ansible-playbook -i ansible/inventory.lab.ini ansible/promote-api.yml \
        -e apim_promote_action=import \
        -e apim_promote_manifest="$DEPLOY_PIN_PROMOTE" \
        -e apim_ss_archive_pin="$DEPLOY_PIN_ARCHIVE" \
        -e apim_ss_archive_sha256="$DEPLOY_PIN_SHA256" \
        -e apim_ss_env="$TO_ENV" \
        -e apim_ss_authoring_env="$ENVN_AUTH" \
        -e apim_ss_api_base="$APIM_BASE" \
        "${ENGINE_AUTH_ARGS[@]}"
      ;;
    labctl)
      "$LABCTL_BIN" promote --manifest "$DEPLOY_PIN_PROMOTE" --env "$TO_ENV" \
        --action import --archive "$DEPLOY_PIN_ARCHIVE" -f "$TMP/targets.yaml"
      ;;
    *) return 90 ;;   # ENGINE_INCONNU — refusé AVANT par la garde de forme (§0bis)
  esac
}

run_engine >"$TMP/promote.log" 2>&1
PROMO_RC=$?

# ── 9. le statut RÉEL sur la PR du dépôt d'ÉQUIPE — succès comme échec ───────
# Pas de re-pose de formulaires ici : une promotion ne change AUCUNE des listes
# déroulantes (ni les APIs publiées, ni les applications) — le faire serait du
# câblage mort copié de team-publish.sh.
if [ "$PROMO_RC" -eq 0 ]; then
  # Les trois jetons que les DEUX moteurs émettent en clair (rôle :
  # roles/apim_promote_api/tasks/import.yml + verify.yml ; labctl :
  # cmd/labctl/promote.go). Le `\n` littéral vient de l'échappement JSON
  # d'Ansible sur les msg multi-lignes.
  SUMMARY=$(grep -oE '(PROMOTE_CONFIRMED|IMPORT_OK|ARCHIVE_DIGEST_OK)[^"]{0,140}' "$TMP/promote.log" \
    | sed 's/\\n/ /g' | tail -3 | tr '\n' ';')
  # Les deux identités figurent au commentaire : c'est la trace d'audit que le
  # lecteur de la PR doit pouvoir relire sans ouvrir le log Jenkins — et voir
  # « demandée par ci » y est un signal, pas un détail (cf. §6bis).
  comment "$WEBHOOK_REPO" "✅ team-promote ${TEAM}/${API_NAME} → ${TO_ENV} ([PR #${PR_NUMBER}](${GIT_WEB_HOST}/${WEBHOOK_REPO}/pulls/${PR_NUMBER})) — pin \`${DEPLOY_PIN_COMMIT}\`, v${DEPLOY_PIN_VERSION}, sha256 \`${DEPLOY_PIN_SHA256}\` (moteur ${PROMOTE_ENGINE}) — demandée par \`${MK_PROMOTED_BY:-<non nommé>}\`, mergée par \`${GITEA_MERGED_BY}\` — ${SUMMARY:-PROMOTE_CONFIRMED}"
else
  # Hiérarchie fatal > msg > tail-3 (leçon du palier 2, cf. team-apply.sh §4 /
  # team-publish.sh §6) : le dernier tag OK vu AVANT un échec réel situé
  # ailleurs dans la chaîne ne doit jamais passer pour le résumé.
  SUMMARY=$(grep -A6 'fatal:\|FAILED!' "$TMP/promote.log" | grep -oE '"msg":.*' | tail -1 | cut -c1-300)
  [ -n "$SUMMARY" ] || SUMMARY=$(tail -3 "$TMP/promote.log" | tr '\n' ' ')
  # UN SEUL commentaire d'échec (via fail(), pas comment()+fail()).
  fail "promotion ${TEAM}/${API_NAME} → ${TO_ENV} en échec : ${SUMMARY:-voir le build}. Re-run possible : l'import d'archive est idempotent (GUID stable, 0-coupure)."
fi
echo "team-promote OK — ${TEAM}/${API_NAME} en ${TO_ENV} @ ${DEPLOY_PIN_COMMIT}"
