#!/usr/bin/env bash
# team-publish.sh — l'APPLY de publication d'API, APRÈS la décision humaine
# (le merge). Miroir de team-apply.sh (palier 2), pour le dépôt de l'ÉQUIPE au
# lieu du dépôt plateforme.
#
#   merge PR api/<name>-<version> (dépôt d'ÉQUIPE) → webhook → job team-publish
#   (pause nominative + garde d'identité + finally D'ENTRÉE, cf. le job XML) →
#   CE script :
#     1. AUTORITÉ PAR TOPOLOGIE : le webhook dit QUEL DÉPÔT a mergé
#        (repository.full_name) — jamais quelle équipe. Une "team" dans le
#        payload serait une AFFIRMATION du dépôt de l'équipe lui-même (il
#        pourrait mentir sur son propre nom). L'équipe est dérivée en CROISANT
#        ce dépôt avec providers.<env>.yml — dépôt PLATEFORME, lu FRAIS sur
#        main — la SEULE source qui dit VRAIMENT « ce dépôt appartient à
#        cette équipe ». REPO_NON_DECLARE si aucune équipe ne le revendique.
#     2. ANTI-TOCTOU : le manifeste (apis/<name>.publish.yml) est lu dans le
#        dépôt de l'ÉQUIPE AU SHA DU MERGE — jamais dans le payload, jamais
#        sur la branche courante d'un clone tardif.
#     3. rôle apim_publish_api (palier 3, create-or-version idempotent).
#     4. statut RÉEL sur la PR du dépôt d'ÉQUIPE — succès comme échec.
#     5. après succès : re-pose app-request (Interfaces du brief) — la
#        nouvelle version doit apparaître dans les listes déroulantes sans
#        attendre une relance manuelle de setup-team-onboard-jobs.sh.
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
#   dir('poc-control-plane-federation') { sh 'bash scripts/team-publish.sh' }
# — donc $0 = "scripts/team-publish.sh" et le `cd "$(dirname "$0")/.."`
# ci-dessous NE BOUGE PAS le cwd ("scripts/.." s'annule).
set -uo pipefail
set +x   # jamais de trace : le token ne doit pas fuiter
cd "$(dirname "$0")/.." || exit 1

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
# Fixe (pas dérivé de la branche, contrairement à team-apply.sh/onboard-<team>-<env>) :
# api/<name>-<version> ne porte aucun axe d'environnement — le seul palier où
# des équipes sont déclarées à ce jour est dev (cf. team-apply.sh, api-request.sh).
ENVN="${ENVN:-dev}"

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

# ── 1. branche gardée à api/*, sinon rien à faire ────────────────────────────
case "$PR_BRANCH" in api/*) ;; *) echo "hors api/* — rien à publier"; exit 0;; esac
REST="${PR_BRANCH#api/}"
API_VERSION="${REST##*-}"
API_NAME="${REST%-*}"
[ -n "$API_NAME" ] && [ -n "$API_VERSION" ] && [ "$API_NAME" != "$REST" ] \
  || fail "BRANCH_FORMAT_INVALIDE : '${PR_BRANCH}' — attendu api/<name>-<version>"

# ── 2. AUTORITÉ PAR TOPOLOGIE : quelle équipe déclare CE dépôt ? ─────────────
# providers.<env>.yml est le dépôt PLATEFORME (GIT_REPO), lu FRAIS sur main —
# jamais au MERGE_SHA (qui est celui du dépôt d'ÉQUIPE, un repo DIFFÉRENT, cf.
# §3). Même discipline fail-closed que team-apply.sh REPO_FULL : un marqueur
# EXPLICITE (TEAM=) distingue « aucune équipe » (marqueur présent, valeur
# vide) de « extraction cassée » (marqueur absent) — jamais confondus.
git clone -q --depth 1 -b main "${GIT_HOST}/${GIT_REPO}.git" "$TMP/platform" \
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

# ── 3. ANTI-TOCTOU : manifeste lu dans le dépôt d'ÉQUIPE AU SHA DU MERGE ─────
# Clone COMPLET (pas --depth 1) : le SHA de merge doit être atteignable par un
# checkout, une profondeur tronquée pourrait ne pas le contenir.
git clone -q "${GIT_HOST}/${WEBHOOK_REPO}.git" "$TMP/team" \
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

# ── 4. publication (rôle du palier 3, idempotent create-or-version) ─────────
( ansible-playbook -i ansible/inventory.lab.ini ansible/publish-api.yml \
    -e apim_ss_manifest="$PUB_PATH" -e apim_ss_team="$TEAM" \
    -e apim_ss_api_base="$APIM_API_BASE" -e apim_ss_env="$ENVN" \
) >"$TMP/pub.log" 2>&1
PUB_RC=$?

# ── 5. le statut RÉEL sur la PR du dépôt d'ÉQUIPE — succès comme échec ───────
if [ "$PUB_RC" -eq 0 ]; then
  SUMMARY=$(grep -oE '"msg": "(MANIFEST_KEYS_OK|TEAM_REQUESTED|ENV_OK|VERSION_[A-Z_]+)[^"]*"' "$TMP/pub.log" \
    | sed 's/^"msg": "//; s/"$//' | tail -3 | tr '\n' ' ; ')

  # ── re-pose app-request (Interfaces du brief) — best-effort BRUYANT : à ce
  # point la publication est DÉJÀ FAITE (PUB_RC=0, rôle idempotent convergé) ;
  # un échec de re-pose ne l'annule pas et n'appelle jamais fail() ; il est
  # seulement NOMMÉ dans le commentaire ✅, même discipline que le §re-pose de
  # team-apply.sh (marqueur CHOICES_SKIPPED_REPOS, cf. generate-choices.sh).
  # DÉFAUT IN-CLUSTER (fix mesuré) : team-publish.sh tourne comme process
  # ENFANT du job Jenkins — "localhost" y désigne le CONTENEUR du job, pas
  # l'hôte. `http://localhost:18080` (le défaut hérité de Task 3, valable
  # seulement depuis le HOST) rendait la re-pose systématiquement injoignable
  # (curl "000") une fois JOUÉ EN JOB — jamais vu en test depuis un poste,
  # toujours vu en job réel. `jenkins:8080` est l'alias réseau in-cluster déjà
  # utilisé pour webmethods-mock/gitea (même convention). Un poste hors du
  # réseau compose surcharge JENKINS_UI explicitement (comme APIM_API_BASE).
  REFRESH_NOTE=""
  if JENKINS_UI="${JENKINS_UI:-http://jenkins:8080}" JOBS="app-request" \
     ENVN="$ENVN" bash scripts/setup-team-onboard-jobs.sh >"$TMP/refresh.log" 2>&1
  then
    SKIPPED=$(grep -oE 'CHOICES_SKIPPED_REPOS=[0-9]+' "$TMP/refresh.log" | tail -1 | cut -d= -f2)
    if [ -n "$SKIPPED" ] && [ "$SKIPPED" -gt 0 ]; then
      REFRESH_NOTE=" (app-request rafraîchi ; ⚠ ${SKIPPED} dépôt(s) d'équipe déclarés mais absents, sautés)"
      echo "AVERTISSEMENT: app-request rafraîchi mais ${SKIPPED} dépôt(s) d'équipe déclarés absents/sautés :" >&2
      tail -20 "$TMP/refresh.log" >&2
    else
      REFRESH_NOTE=" (app-request rafraîchi)"
      echo "app-request rafraîchi (nouvelle version visible dans les listes)"
    fi
  else
    REFRESH_NOTE=" ⚠ app-request non rafraîchi — relancer setup-team-onboard-jobs.sh"
    echo "AVERTISSEMENT: re-pose app-request en échec — la publication, elle, EST faite :" >&2
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
