#!/usr/bin/env bash
# team-publish.sh — l'APPLY de publication d'API, APRÈS la décision humaine
# (le merge). Miroir de team-apply.sh (palier 2), pour le dépôt de l'ÉQUIPE au
# lieu du dépôt plateforme.
#
#   merge PR api/<name>-<version> (dépôt d'ÉQUIPE) → webhook → job team-publish
#   (pause nominative + garde d'identité + finally D'ENTRÉE, cf. le job XML) →
#   CE script :
#     1. VALIDATION DE FORME de tout ce qui vient du webhook (owner/repo, SHA
#        hex, branche, PR_NUMBER) — AVANT tout argv git/curl.
#     2. RÉCONCILIATION AVEC GITEA : le webhook n'a pas de secret vérifié en
#        aval — on redemande l'état RÉEL de la PR à Gitea (authentifié) et on
#        refuse toute divergence (merged/merge_commit_sha/head.ref/base.ref).
#     3. AUTORITÉ PAR TOPOLOGIE : le webhook dit QUEL DÉPÔT a mergé
#        (repository.full_name) — jamais quelle équipe. Une "team" dans le
#        payload serait une AFFIRMATION du dépôt de l'équipe lui-même (il
#        pourrait mentir sur son propre nom). L'équipe est dérivée en CROISANT
#        ce dépôt avec providers.<env>.yml — dépôt PLATEFORME, lu FRAIS sur
#        main — la SEULE source qui dit VRAIMENT « ce dépôt appartient à
#        cette équipe ». REPO_NON_DECLARE si aucune équipe ne le revendique.
#     4. ANTI-TOCTOU : le manifeste (apis/<name>.publish.yml) est lu dans le
#        dépôt de l'ÉQUIPE AU SHA DU MERGE (clone AUTHENTIFIÉ, pas anonyme —
#        un dépôt d'équipe PRIVÉ casserait sinon) — jamais dans le payload,
#        jamais sur la branche courante d'un clone tardif. Le contenu N'EST
#        PAS borné par la liste blanche des CLÉS (manifest-guard.yml, côté
#        rôle), qui ne protège que la FORME, jamais le fond (RCE fermée, cf.
#        §5) : `contract` est vérifié en LISTE BLANCHE EXACTE (le gabarit
#        posé par api-request.sh PORTE lui-même un Jinja légitime dans ce
#        champ — un scan Jinja nu l'aurait refusé) ; MANIFEST_UNSAFE scanne
#        tout le RESTE du manifeste (inbound.*, team, …) pour tout {{/{%.
#     5. rôle apim_publish_api (palier 3, create-or-version idempotent) —
#        avec apim_ss_contract_pin qui ÉPINGLE le contract au chemin déjà
#        vérifié (§4), jamais celui que le manifeste prétend porter.
#     6. statut RÉEL sur la PR du dépôt d'ÉQUIPE — succès comme échec.
#        après succès : re-pose app-request ET api-request (Interfaces du
#        brief) — la nouvelle version doit apparaître dans les listes
#        déroulantes sans attendre une relance manuelle.
#
# I2 (dette du palier 2, À NE PAS REPRODUIRE ICI) : team-apply.sh/
# team-request.sh ne vérifient jamais le code de retour de leur propre POST de
# commentaire — un build vert peut y laisser la PR muette (ADR-081 corollaire
# 1 violé en silence). `comment()` ci-dessous délègue à
# scripts/lib/gitea-pr-comment.sh (infrastructure PARTAGÉE, déjà établie par
# provision-apply-comment.sh) plutôt que de refaire son propre POST : son code
# de retour EST vérifié (NOMME un échec, bruyant, sur stderr, sans faire
# échouer le script — la décision (le merge) reste actée même si le RAPPORT
# échoue), et le commentaire est IDEMPOTENT PAR MARQUEUR
# (`<!-- team-publish -->`) — un re-run sur la même PR (retry après panne
# transitoire, rejeu manuel du webhook) MET À JOUR le commentaire existant au
# lieu d'en empiler un second, et un succès qui suit un échec REMPLACE la
# trace de l'échec au lieu de la laisser trainer à côté d'un ✅ contradictoire.
#
# Invocation attendue (miroir de team-apply.sh) :
#   dir(env.GIT_SUBDIR) { sh 'bash scripts/team-publish.sh' }
# — donc $0 = "scripts/team-publish.sh" et le `cd "$(dirname "$0")/.."`
# ci-dessous NE BOUGE PAS le cwd ("scripts/.." s'annule).
set -uo pipefail
set +x   # jamais de trace : le token ne doit pas fuiter
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=lib/deploy-pin.sh
# `set -e` n'est pas actif dans ce script : sans ce garde-fou explicite, un
# fichier manquant laisserait bash CONTINUER, et l'échec se présenterait bien
# plus bas comme « resolve_deploy_pin: command not found » puis PIN_NON_RESOLU
# — un fail-closed par accident, avec un message qui accuse la résolution au
# lieu du fichier absent.
. scripts/lib/deploy-pin.sh || { echo "ERREUR: scripts/lib/deploy-pin.sh introuvable ou illisible" >&2; exit 1; }

WEBHOOK_REPO="${WEBHOOK_REPO:?WEBHOOK_REPO requis (repository.full_name du webhook)}"
PR_BRANCH="${PR_BRANCH:?PR_BRANCH requis}"
PR_NUMBER="${PR_NUMBER:?PR_NUMBER requis}"
MERGE_SHA="${MERGE_SHA:?MERGE_SHA requis (merge_commit_sha du webhook)}"
GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN requis}"
VAULT_ADDR="${VAULT_ADDR:?VAULT_ADDR requis}"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:?VAULT_TOKEN_FILE requis (jamais le token en env/argv)}"
APIM_API_BASE="${APIM_API_BASE:?APIM_API_BASE requis — pas de défaut : dire sa cible est volontaire}"
GIT_HOST="${GIT_HOST:-http://gitea:3000}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"        # dépôt PLATEFORME — porte providers.<env>.yml
GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"
# G4 (ADR-082) : ENVN est SCELLÉ sur l'env d'authoring — affectation sèche
# depuis la constante de lib, jamais "${ENVN:-dev}" : les variables d'un job
# Jenkins atterrissent dans l'environnement du process (fait mesuré, même
# raison que deploy-pin.sh:29-37). La publication est un geste d'AUTHORING
# par conception (ADR-079) ; au-delà, c'est la promotion (marqueurs G3,
# verbe archive G5) — et son autorité est la rétention de credential, pas
# une variable.
ENVN="$DEPLOY_PIN_AUTHORING_ENV"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; umask 077

# Marqueur d'idempotence : STABLE par PR (pas par run), pour qu'un re-run sur
# la MÊME PR mette à jour plutôt que d'empiler — cf. scripts/lib/gitea-pr-comment.sh.
TEAM_PUBLISH_MARKER='<!-- team-publish -->'
comment(){
  local repo="$1" body="$2" bodyfile
  bodyfile="$TMP/comment-body"
  printf '%s\n' "$body" > "$bodyfile"
  GIT_REPO="$repo" GITEA_TOKEN="$GITEA_TOKEN" PR_NUMBER="$PR_NUMBER" GIT_HOST="$GIT_HOST" \
  COMMENT_MARKER="$TEAM_PUBLISH_MARKER" COMMENT_BODY_FILE="$bodyfile" \
    bash scripts/lib/gitea-pr-comment.sh \
    || echo "AVERTISSEMENT: échec de publication du commentaire sur ${repo}#${PR_NUMBER} — la décision (merge) reste actée, seul le RAPPORT a échoué" >&2
}
fail(){ comment "$WEBHOOK_REPO" "❌ team-publish : $*"; echo "ERREUR: $*" >&2; exit 1; }

# Clone AUTHENTIFIÉ (GITEA_TOKEN, header injecté via variables d'ENVIRONNEMENT
# GIT_CONFIG_COUNT/KEY/VALUE — jamais l'URL, jamais argv ; motif déjà établi
# pour les push de ce dépôt, réutilisé ici pour les clones). Un clone ANONYME
# casserait sur un dépôt PRIVÉ — le dépôt plateforme ET le dépôt d'équipe le
# sont chez un client réel ; ce lab les a en lecture publique, ce qui
# masquait le trou (les deux clones fonctionnaient "par accident").
gclone(){
  local auth_b64
  auth_b64=$(printf 'x:%s' "$GITEA_TOKEN" | base64 | tr -d '\n')
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
    GIT_CONFIG_VALUE_0="Authorization: Basic ${auth_b64}" \
    git clone -q "$@"
}

# ── 0. VALIDATION DE FORME — AVANT tout argv git/curl ────────────────────────
# WEBHOOK_REPO et MERGE_SHA viennent d'un WEBHOOK (un tiers) et sont
# interpolés tels quels dans des URLs git/curl et des arguments de commande
# juste en dessous. Un refus de FORME, D'ABORD (leçon \Z du palier 1 : le
# refus de classe précède la garde de fond, jamais l'inverse), ferme la
# classe de trou "valeur de webhook mal formée qui atteint argv/une URL sans
# avoir été regardée" — indépendamment de ce que la garde de topologie ou
# d'atteignabilité, plus bas, décideraient de cette même valeur si elle était
# bien formée.
case "$WEBHOOK_REPO" in *[!A-Za-z0-9_./-]*) fail "WEBHOOK_REPO_INVALIDE : '${WEBHOOK_REPO}' — caractère hors classe [A-Za-z0-9_./-]";; esac
printf '%s' "$WEBHOOK_REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
  || fail "WEBHOOK_REPO_INVALIDE : '${WEBHOOK_REPO}' — attendu owner/repo"

case "$MERGE_SHA" in *[!0-9a-f]*) fail "MERGE_SHA_INVALIDE : '${MERGE_SHA}' — caractère hors classe hexadécimale";; esac
printf '%s' "$MERGE_SHA" | grep -Eq '^[0-9a-f]{40}$' \
  || fail "MERGE_SHA_INVALIDE : '${MERGE_SHA}' — attendu 40 caractères hexadécimaux (SHA-1 git)"

# Manqué au round précédent (revue) : PR_NUMBER sert de segment d'URL API
# Gitea (réconciliation ci-dessous, commentaires) — même discipline.
case "$PR_NUMBER" in *[!0-9]*) fail "PR_NUMBER_INVALIDE : '${PR_NUMBER}' — caractère hors classe numérique";; esac
printf '%s' "$PR_NUMBER" | grep -Eq '^[1-9][0-9]*$' \
  || fail "PR_NUMBER_INVALIDE : '${PR_NUMBER}' — attendu un entier positif"

# ── 1. branche gardée à api/*, sinon rien à faire ────────────────────────────
case "$PR_BRANCH" in api/*) ;; *) echo "hors api/* — rien à publier"; exit 0;; esac
REST="${PR_BRANCH#api/}"
API_VERSION="${REST##*-}"
API_NAME="${REST%-*}"
[ -n "$API_NAME" ] && [ -n "$API_VERSION" ] && [ "$API_NAME" != "$REST" ] \
  || fail "BRANCH_FORMAT_INVALIDE : '${PR_BRANCH}' — attendu api/<name>-<version>"

# Régime ancré (même classe et même ordre que TEAM dans team-apply.sh/
# resolve.yml, et que api-request.sh pour ces mêmes deux champs) : le refus
# de CLASSE d'abord (le `case`, contre \n et tout caractère hors alphabet),
# PUIS la forme complète ancrée. API_NAME devient un segment de CHEMIN
# (apis/<name>.publish.yml, plus bas) : un nom hors classe y serait une
# évasion de chemin, pas une coquetterie de validation.
case "$API_NAME" in *[!a-z0-9-]*) fail "API_NAME_INVALIDE : '${API_NAME}' (branche '${PR_BRANCH}') — attendu ^[a-z0-9][a-z0-9-]{1,30}\$";; esac
printf '%s' "$API_NAME" | grep -Eq '^[a-z0-9][a-z0-9-]{1,30}$' \
  || fail "API_NAME_INVALIDE : '${API_NAME}' (branche '${PR_BRANCH}') — attendu ^[a-z0-9][a-z0-9-]{1,30}\$"
case "$API_VERSION" in *[!0-9.]*) fail "API_VERSION_INVALIDE : '${API_VERSION}' (branche '${PR_BRANCH}') — attendu X.Y ou X.Y.Z";; esac
printf '%s' "$API_VERSION" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
  || fail "API_VERSION_INVALIDE : '${API_VERSION}' (branche '${PR_BRANCH}') — attendu X.Y ou X.Y.Z"

# ── 2. RÉCONCILIATION AVEC GITEA — le payload n'est pas la vérité ────────────
# Le webhook n'a ni secret HMAC vérifié en aval (limite du plugin Generic
# Webhook Trigger avec ce montage — cf. rapport) ni garantie de fraîcheur : un
# tir manuel avec le token GWT partagé peut prétendre N'IMPORTE QUEL
# merge_commit_sha/branche pour ce PR_NUMBER. La garde d'atteignabilité
# (§4, plus bas) confirme que MERGE_SHA est UN ancêtre de main — pas
# forcément CELUI de CETTE PR. On redemande donc l'état à GITEA LUI-MÊME
# (authentifié par GITEA_TOKEN, donc pas falsifiable par le contenu d'un
# payload) : la PR est-elle RÉELLEMENT fusionnée, avec CE SHA, CETTE branche,
# sur main ? Un payload rejoué (SHA périmé, branche différente, PR pas encore
# mergée) ne peut pas fabriquer une réponse Gitea qui concorde.
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
print("OK" if ok else "MISMATCH")
PY
) || fail "GITEA_RECONCILE_ECHEC : lecture de ${WEBHOOK_REPO}#${PR_NUMBER} sur Gitea en échec"
case "$PR_STATE" in
  OK) ;;
  ERR=*) fail "GITEA_RECONCILE_ECHEC : appel Gitea en échec (${PR_STATE#ERR=}) pour ${WEBHOOK_REPO}#${PR_NUMBER}" ;;
  MISMATCH) fail "PAYLOAD_PERIME : ${WEBHOOK_REPO}#${PR_NUMBER} sur Gitea (merged/merge_commit_sha/head.ref/base.ref) ne correspond pas au webhook — le payload ne fait pas foi, refus" ;;
  *) fail "GITEA_RECONCILE_ECHEC : réponse inattendue de la réconciliation ('${PR_STATE}')" ;;
esac
echo "réconciliation Gitea OK : ${WEBHOOK_REPO}#${PR_NUMBER} merged, ${PR_BRANCH}->main"

# ── 3. AUTORITÉ PAR TOPOLOGIE : quelle équipe déclare CE dépôt ? ─────────────
# providers.<env>.yml est le dépôt PLATEFORME (GIT_REPO), lu FRAIS sur main —
# jamais au MERGE_SHA (qui est celui du dépôt d'ÉQUIPE, un repo DIFFÉRENT, cf.
# §4). Même discipline fail-closed que team-apply.sh REPO_FULL : un marqueur
# EXPLICITE (TEAM=) distingue « aucune équipe » (marqueur présent, valeur
# vide) de « extraction cassée » (marqueur absent) — jamais confondus.
gclone --depth 1 -b main "${GIT_HOST}/${GIT_REPO}.git" "$TMP/platform" \
  || fail "clone ${GIT_REPO}@main (résolution dépôt -> équipe)"
PROV="$TMP/platform/poc-control-plane-federation/ansible/providers.${ENVN}.yml"
[ -f "$PROV" ] || fail "PROVIDERS_MISSING : ansible/providers.${ENVN}.yml absent sur main"

# FAIL-CLOSED supplémentaire (REPO_AMBIGU) : si CE dépôt est déclaré par PLUS
# D'UNE équipe (erreur d'opérateur — copier-coller de providers.<env>.yml),
# prendre la première rencontrée serait deviner laquelle publie réellement.
# Même discipline que VERSION_BASE_AMBIGUE (roles/apim_publish_api/tasks/
# version.yml) : ne jamais choisir arbitrairement entre plusieurs candidats
# également plausibles.
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
) || fail "PARSE_PROVIDERS : lecture de providers.${ENVN}.yml pour ${WEBHOOK_REPO}"
case "$TEAM" in
  AMBIGU=*) fail "REPO_AMBIGU : ${WEBHOOK_REPO} est déclaré par plusieurs équipes dans providers.${ENVN}.yml (${TEAM#AMBIGU=}) — corriger providers.${ENVN}.yml avant de publier, aucune équipe ne peut être choisie sans arbitraire" ;;
  TEAM=)    fail "REPO_NON_DECLARE : ${WEBHOOK_REPO} n'appartient à aucune équipe de providers.${ENVN}.yml — refus" ;;
  TEAM=*)   TEAM="${TEAM#TEAM=}" ;;
  *)        fail "PARSE_PROVIDERS : sortie inattendue de l'extraction équipe pour ${WEBHOOK_REPO} (ni échec ni marqueur TEAM=/AMBIGU=)" ;;
esac
echo "topologie : dépôt ${WEBHOOK_REPO} -> équipe '${TEAM}' (providers.${ENVN}.yml)"

# ── 4. ANTI-TOCTOU : manifeste lu dans le dépôt d'ÉQUIPE AU SHA DU MERGE ─────
# Clone COMPLET (pas --depth 1) : le SHA de merge doit être atteignable par un
# checkout, une profondeur tronquée pourrait ne pas le contenir.
gclone "${GIT_HOST}/${WEBHOOK_REPO}.git" "$TMP/team" \
  || fail "clone ${WEBHOOK_REPO} (dépôt de l'équipe)"
git -C "$TMP/team" checkout -q "$MERGE_SHA" \
  || fail "checkout du SHA de merge ${MERGE_SHA} sur ${WEBHOOK_REPO}"

# GARDE D'ATTEIGNABILITÉ : un `git checkout $MERGE_SHA` réussi prouve
# seulement que l'OBJET existe quelque part dans le clone (un `git clone` SANS
# --depth 1 récupère TOUTES les branches) — jamais qu'il est réellement fusionné
# sur main. Un SHA valide mais vivant sur une branche non protégée (ou jamais
# mergée) passerait le checkout ET dériverait ensuite name/version depuis LA
# BRANCHE (webhook) plutôt que depuis un état VRAIMENT revu — exactement le
# point aveugle qu'une revue de ce dépôt traque partout ailleurs (cf.
# TEAM_NOT_IN_MERGED_STATE de team-apply.sh, même intention, garde différente
# car team-apply.sh checkoute directement SUR origin/main, jamais un SHA tiers).
git -C "$TMP/team" merge-base --is-ancestor "$MERGE_SHA" origin/main \
  || fail "MERGE_SHA_NON_ANCETRE : ${MERGE_SHA} n'est pas un ancêtre de ${WEBHOOK_REPO}@main — le SHA du webhook ne correspond pas à un commit réellement fusionné sur la branche protégée, refus de publier depuis un état non revu"

PUB_REL="apis/${API_NAME}.publish.yml"
PUB_PATH="$TMP/team/${PUB_REL}"
[ -f "$PUB_PATH" ] \
  || fail "PUBLISH_MANIFEST_MISSING : ${PUB_REL} absent de ${WEBHOOK_REPO} au SHA mergé ${MERGE_SHA}"

# CONTRAT_ABSENT : api-request.sh pose TOUJOURS le manifeste ET son contrat
# ENSEMBLE (même commit). Une PR qui aurait retiré/renommé le contrat à la
# main romprait la publication BEAUCOUP plus loin (à l'intérieur du rôle
# Ansible, sur un lookup('file', …) dont le message ne dit pas "le contrat
# manque au SHA mergé") — vérifié ICI, tôt, avec un diagnostic qui nomme la
# cause plutôt que sa conséquence.
SPEC_REL="apis/${API_NAME}.openapi.yaml"
SPEC_PATH="$TMP/team/${SPEC_REL}"
[ -f "$SPEC_PATH" ] \
  || fail "CONTRAT_ABSENT : ${SPEC_REL} absent de ${WEBHOOK_REPO} au SHA mergé ${MERGE_SHA} — le manifeste existe mais son contrat OpenAPI non ; api-request.sh les pose toujours ensemble"

# Cohérence branche <-> manifeste (même classe que le §1 de team-apply.sh :
# une extraction non gardée entre deux appels gardés est le point aveugle de
# cette base de code). Une divergence — édition manuelle de la PR/branche
# après coup, gabarit mal rendu — ne doit JAMAIS publier une identité
# différente de celle que la branche annonce.
MANIFEST_NV=$(PUB_PATH="$PUB_PATH" python3 - <<'PY'
import os, yaml
d = yaml.safe_load(open(os.environ["PUB_PATH"])) or {}
a = d.get("apim_api") or {}
print("NV=" + str(a.get("name") or "") + "@" + str(a.get("version") or ""))
PY
) || fail "PARSE_MANIFEST : lecture de ${PUB_REL}"
case "$MANIFEST_NV" in
  "NV=${API_NAME}@${API_VERSION}") ;;
  NV=*) fail "BRANCH_MANIFEST_MISMATCH : la branche annonce '${API_NAME}@${API_VERSION}' mais ${PUB_REL} porte '${MANIFEST_NV#NV=}'" ;;
  *)    fail "PARSE_MANIFEST : sortie inattendue de la lecture de ${PUB_REL}" ;;
esac

# [CRITICAL, panel] contract : LISTE BLANCHE EXACTE, pas un simple scan Jinja
# — le gabarit LÉGITIME lui-même (gateways/templates/publish.yml.tmpl, posé
# par api-request.sh) PORTE un Jinja dans ce champ :
#   contract: "{{ (pub_manifest_path | dirname) }}/<name>.openapi.yaml"
# réévalué PARESSEUSEMENT par le rôle au premier lookup('file',
# apim_api.contract) — un grep Jinja nu sur tout le fichier (première version
# de ce correctif, corrigée ici) aurait donc refusé TOUTE publication
# légitime, gabarit compris. Un seul contenu de `contract` est légitime : ce
# gabarit EXACT, paramétré par API_NAME (connu de la branche, jamais du
# manifeste). TOUT AUTRE contenu — un payload `{{ lookup('pipe','…') }}`
# (RCE) COMME un chemin absolu qui s'évaderait de l'arbre mergé — est un
# manifeste qui MENT sur son propre contrat : REFUSÉ explicitement ici, AVANT
# tout apply — pas seulement neutralisé en silence par le pin (§5, plus bas),
# qui reste une SECONDE fermeture, défense en profondeur : même un bug ICI ne
# rouvrirait pas la RCE, le pin gagne quoi qu'il arrive.
EXPECTED_CONTRACT="{{ (pub_manifest_path | dirname) }}/${API_NAME}.openapi.yaml"
MANIFEST_CONTRACT=$(PUB_PATH="$PUB_PATH" python3 - <<'PY'
import os, yaml
d = yaml.safe_load(open(os.environ["PUB_PATH"])) or {}
a = d.get("apim_api") or {}
print("CONTRACT=" + str(a.get("contract") or ""))
PY
) || fail "PARSE_MANIFEST : lecture du champ contract de ${PUB_REL}"
case "$MANIFEST_CONTRACT" in
  "CONTRACT=${EXPECTED_CONTRACT}") ;;
  CONTRACT=*) fail "MANIFEST_CONTRACT_INVALIDE : ${PUB_REL} porte contract='${MANIFEST_CONTRACT#CONTRACT=}', attendu EXACTEMENT '${EXPECTED_CONTRACT}' (le gabarit posé par api-request.sh) — refus AVANT tout apply, que la divergence soit un Jinja injecté ou un chemin qui s'évaderait de l'arbre mergé" ;;
  *) fail "PARSE_MANIFEST : sortie inattendue de la lecture du champ contract de ${PUB_REL}" ;;
esac

# [CRITICAL, panel] MANIFEST_UNSAFE — défense en profondeur SUR LE RESTE du
# manifeste (inbound.*, team, …) : contract vient d'être validé en LISTE
# BLANCHE ci-dessus, donc EXCLU de ce scan (sinon le gabarit légitime — qui
# PORTE un Jinja dans ce seul champ — échouerait toujours ici). Le manifeste
# est chargé par `include_vars` (précédence 18) dans le rôle Ansible, qui
# re-template PARESSEUSEMENT toute chaîne portant elle-même {{ }} / {% %} —
# aucun mécanisme équivalent au pin de contract ne neutralise un Jinja
# injecté AILLEURS dans le manifeste.
MANIFEST_REST_UNSAFE=$(PUB_PATH="$PUB_PATH" python3 - <<'PY'
import os, yaml
d = yaml.safe_load(open(os.environ["PUB_PATH"])) or {}
a = d.get("apim_api")
if isinstance(a, dict):
    a = dict(a)
    a.pop("contract", None)
    d = dict(d)
    d["apim_api"] = a
dumped = yaml.safe_dump(d, default_flow_style=False, allow_unicode=True)
print("UNSAFE" if ("{{" in dumped or "{%" in dumped) else "CLEAN")
PY
) || fail "PARSE_MANIFEST : scan Jinja de ${PUB_REL} (hors contract)"
[ "$MANIFEST_REST_UNSAFE" = "CLEAN" ] \
  || fail "MANIFEST_UNSAFE : ${PUB_REL} contient une expression Jinja ({{ ou {%) en dehors du champ contract (déjà validé en liste blanche ci-dessus) — un manifeste d'équipe ne doit jamais porter de gabarit ailleurs, seulement des valeurs littérales"

# ── 5bis. RÉSOLUTION DE LA RÉFÉRENCE DE DÉPLOIEMENT (jalon G3) ───────────────
# En env d'AUTHORING (dev), le résolveur matérialise HEAD : le comportement est
# celui d'avant, à l'octet près. Il est branché ICI, sur le chemin vivant, pour
# deux raisons : (1) un résolveur que personne n'appelle est du code mort qui
# pourrit en silence — c'est le reproche fait à `labctl promote` (GOAL G8) ;
# (2) le jour où G4 ouvre les paliers supérieurs, ce chemin PINNE déjà, sans
# nouvelle plomberie à écrire sous pression.
# Le clone est DÉJÀ positionné au SHA du merge (§4) — le résolveur lit donc
# l'état revu, pas une branche courante.
# G4 (D9) : le refus PRÉCIS du résolveur (PIN_ABSENT, ARCHIVE_ABSENT, …)
# part sur stderr (_dp_fail, deploy-pin.sh) — un lecteur de PR ne voit pas le
# log Jenkins. On capture stderr en FICHIER (jamais un pipe : pipefail + le
# résolveur sort 1) et le dernier jeton nommé rejoint le commentaire. C'est
# LA surface de diagnostic de l'équipe le jour où la chaîne s'exerce.
# Ligne D'APPEL laissée intacte (test-deploy-pin.sh ⑳ ancre
# ^resolve_deploy_pin "\$TMP/team" en tête de ligne) : le branchement en
# `|| { … }` porte la capture sans déplacer l'appel derrière un `if !`.
resolve_deploy_pin "$TMP/team" "$API_NAME" "$ENVN" "$TMP/resolved" 2>"$TMP/pin.err" || {
  cat "$TMP/pin.err" >&2   # le log de build garde TOUT le détail
  REFUS="$(grep -o 'deploy-pin: [A-Z_]*' "$TMP/pin.err" | tail -1)"
  fail "PIN_NON_RESOLU : la référence de déploiement de ${API_NAME} en ${ENVN} n'a pas pu être résolue (${REFUS:-refus non nommé — voir le log du build})"
}

# ── 5. publication (rôle du palier 3, idempotent create-or-version) ─────────
# apim_ss_contract_pin (extra-var, précédence 22) ÉPINGLE le contract au
# chemin RÉSOLU (DEPLOY_PIN_CONTRACT) — en dev, le résolveur matérialise
# exactement SPEC_PATH (§4, CONTRAT_ABSENT) ; hors dev, il matérialise le pin
# — jamais ce que le manifeste prétend porter (cf. le scan MANIFEST_UNSAFE
# ci-dessus, défense en profondeur sur le RESTE du manifeste ; ceci est la
# fermeture PRIMAIRE pour contract spécifiquement). $PUB_PATH et $SPEC_PATH
# restent utilisés PLUS HAUT par les gardes (cohérence branche↔manifeste,
# liste blanche du champ contract) : elles valident l'état mergé sur le
# clone ; ce qui part au moteur est ce que le résolveur en a fait.
( ansible-playbook -i ansible/inventory.lab.ini ansible/publish-api.yml \
    -e apim_ss_manifest="$DEPLOY_PIN_PUBLISH" -e apim_ss_team="$TEAM" \
    -e apim_ss_api_base="$APIM_API_BASE" -e apim_ss_env="$ENVN" \
    -e apim_ss_contract_pin="$DEPLOY_PIN_CONTRACT" \
) >"$TMP/pub.log" 2>&1
PUB_RC=$?

# ── 6. le statut RÉEL sur la PR du dépôt d'ÉQUIPE — succès comme échec ───────
if [ "$PUB_RC" -eq 0 ]; then
  SUMMARY=$(grep -oE '"msg": "(MANIFEST_KEYS_OK|TEAM_REQUESTED|ENV_OK|VERSION_[A-Z_]+)[^"]*"' "$TMP/pub.log" \
    | sed 's/^"msg": "//; s/"$//' | tail -3 | tr '\n' ' ; ')

  # ── re-pose app-request ET api-request (revue : la liste API_BASE d'api-
  # request restait périmée après chaque publication, bloquant le cycle
  # create->new-version sur API_BASE_STALE tant qu'un humain ne relançait pas
  # la pose à la main — même JOBS que team-apply.sh) — best-effort BRUYANT :
  # à ce point la publication est DÉJÀ FAITE (PUB_RC=0, rôle idempotent
  # convergé) ; un échec de re-pose ne l'annule pas et n'appelle jamais
  # fail() ; il est seulement NOMMÉ dans le commentaire ✅, même discipline
  # que le §re-pose de team-apply.sh (marqueur CHOICES_SKIPPED_REPOS, cf.
  # generate-choices.sh).
  # DÉFAUT IN-CLUSTER (fix mesuré) : team-publish.sh tourne comme process
  # ENFANT du job Jenkins — "localhost" y désigne le CONTENEUR du job, pas
  # l'hôte. `http://localhost:18080` (le défaut hérité de Task 3, valable
  # seulement depuis le HOST) rendait la re-pose systématiquement injoignable
  # (curl "000") une fois JOUÉ EN JOB — jamais vu en test depuis un poste,
  # toujours vu en job réel. `jenkins:8080` est l'alias réseau in-cluster déjà
  # utilisé pour webmethods-mock/gitea (même convention). Un poste hors du
  # réseau compose surcharge JENKINS_UI explicitement (comme APIM_API_BASE).
  REFRESH_NOTE=""
  # AUCUN ENVN passé au délégué, et c'est délibéré : depuis G4 il SCELLE
  # lui-même son env sur la même constante d'authoring. Le lui repasser serait
  # du câblage mort qui suggère qu'il obéit à son appelant.
  # A0 (2026-09-02) : app-request n'a plus de marqueur — sa re-pose est une
  # copie tel quel suivie d'un build d'AMORÇAGE (BOOTSTRAP_JOBS, délégué) :
  # c'est ce build qui recalcule ses listes ; api-request garde la substitution.
  if JENKINS_UI="${JENKINS_UI:-http://jenkins:8080}" JOBS="app-request api-request" \
     bash scripts/setup-team-onboard-jobs.sh >"$TMP/refresh.log" 2>&1
  then
    SKIPPED=$(grep -oE 'CHOICES_SKIPPED_REPOS=[0-9]+' "$TMP/refresh.log" | tail -1 | cut -d= -f2)
    if [ -n "$SKIPPED" ] && [ "$SKIPPED" -gt 0 ]; then
      REFRESH_NOTE=" (app-request/api-request rafraîchis ; ⚠ ${SKIPPED} dépôt(s) d'équipe déclarés mais absents, sautés)"
      echo "AVERTISSEMENT: app-request/api-request rafraîchis mais ${SKIPPED} dépôt(s) d'équipe déclarés absents/sautés :" >&2
      tail -20 "$TMP/refresh.log" >&2
    else
      REFRESH_NOTE=" (app-request/api-request rafraîchis)"
      echo "app-request/api-request rafraîchis (nouvelle version visible dans les listes)"
    fi
  else
    REFRESH_NOTE=" ⚠ app-request/api-request non rafraîchis — relancer setup-team-onboard-jobs.sh"
    echo "AVERTISSEMENT: re-pose app-request/api-request en échec — la publication, elle, EST faite :" >&2
    tail -20 "$TMP/refresh.log" >&2
  fi

  comment "$WEBHOOK_REPO" "✅ team-publish ${TEAM}/${API_NAME}@${API_VERSION} ([PR #${PR_NUMBER}](${GIT_WEB_HOST}/${WEBHOOK_REPO}/pulls/${PR_NUMBER})) — ${SUMMARY:-VERSION_CREATED}${REFRESH_NOTE}"
else
  # Hiérarchie fatal > msg > tail-3 (leçon du palier 2, cf. team-apply.sh §4 /
  # api-request.sh §5) : le dernier tag OK vu AVANT un échec réel situé
  # ailleurs dans la chaîne ne doit jamais passer pour le résumé.
  SUMMARY=$(grep -A6 'fatal:\|FAILED!' "$TMP/pub.log" | grep -oE '"msg":.*' | tail -1 | cut -c1-300)
  [ -n "$SUMMARY" ] || SUMMARY=$(tail -3 "$TMP/pub.log" | tr '\n' ' ')
  # UN SEUL commentaire d'échec (via fail(), pas comment()+fail()) : team-apply.sh
  # poste deux commentaires ❌ sur ce chemin (un détaillé, un générique via
  # fail()) — ÉCART délibéré ici, déclaré au rapport : ADR-081 exige au moins
  # un commentaire, pas au plus un ; un seul, complet, reste plus lisible.
  fail "publication ${TEAM}/${API_NAME}@${API_VERSION} en échec : ${SUMMARY:-voir le build}. Re-run possible : le rôle est idempotent."
fi
echo "team-publish OK — ${TEAM}/${API_NAME}@${API_VERSION}"
