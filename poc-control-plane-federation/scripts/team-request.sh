#!/usr/bin/env bash
# team-request.sh — moteur du formulaire « onboarder une équipe » (palier 2).
#
#   formulaire Jenkins → CE script :
#     1. gardes d'entrée (AVANT tout geste Git — un refus ne laisse rien derrière)
#     2. clone du dépôt plateforme, AJOUT de l'entrée dans providers.<env>.yml
#     3. branche onboard/<team>-<env>, commit (identité de service ci), push, PR
#     4. PLAN : ansible/team-plan.yml contre le fichier MODIFIÉ → commentaire ✅/❌
#
# La décision reste le MERGE (ADR-081) : ce script n'applique rien, ne crée
# aucun dépôt, ne touche ni Vault ni la gateway. Le privilège de création vit
# dans le seul job post-merge (team-apply).
#
# Entrées (env — mappées depuis les paramètres du job) :
#   TEAM         (req) nom d'équipe — regex du rôle, refus TEAM_NAME_INVALID
#   DESCRIPTION        libre (sans " ni \ ni retour ligne — YAML_UNSAFE_INPUT sinon)
#   APPROVERS          matricules CSV ; VIDE ACCEPTÉ (cas payments-team)
#   REPO               full-name org/nom (défaut <TEAM>/apis)
#   (REQ_ENV n'est PLUS une entrée : G4/ADR-082 le SCELLE sur l'env
#    d'authoring — l'axe env a quitté le formulaire, cf. plus bas.)
#   FORGE_SECRET  (req) token du service ci (write:repository, write:issue)
#   GIT_REPO           défaut ci/stoa-labs   GIT_HOST  défaut http://gitea:3000
#   GIT_WEB_HOST       URL Gitea vue par l'HUMAIN (liens des commentaires)
#   DRY_RUN=1          les gardes statuent, puis exit 0 AVANT tout geste
#                      Git/réseau (motif api-promote-request.sh) — la surface
#                      qu'éprouve la porte hors ligne, jamais un laissez-passer
set -uo pipefail
set +x   # jamais de trace : le token ne doit pas fuiter
cd "$(dirname "$0")/.." || exit 1

# Auto-localisation par BASH_SOURCE quand le fichier vit dans son arbre ; repli
# sur le cwd (fixé par le `cd` ci-dessus) pour les invocations où le dirname ne
# contient pas lib/ — même motif que setup-vault-paliers.sh:26-38 et
# api-request.sh:58-66.
_TR_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/deploy-pin.sh"
[ -f "$_TR_LIB" ] || _TR_LIB="scripts/lib/deploy-pin.sh"
# `set -e` n'est pas actif ici : sans garde explicite, un fichier manquant
# laisserait bash continuer jusqu'à un « unbound variable » sur la constante.
# shellcheck source=scripts/lib/deploy-pin.sh
. "$_TR_LIB" || { echo "ERREUR: $_TR_LIB introuvable ou illisible" >&2; exit 1; }
# Disposition du dépôt : le préfixe du livrable est un KNOB (GIT_SUBDIR ->
# SUB_PFX), jamais le préfixe du lab en dur — c'est ce littéral qui a fait
# mourir la chaîne du client le 2026-09-08 sur un fichier POURTANT présent.
_TR_LAYOUT="$(dirname "${BASH_SOURCE[0]}")/lib/repo-layout.sh"
[ -f "$_TR_LAYOUT" ] || _TR_LAYOUT="scripts/lib/repo-layout.sh"
# shellcheck source=scripts/lib/repo-layout.sh
. "$_TR_LAYOUT" || { echo "ERREUR: $_TR_LAYOUT introuvable ou illisible" >&2; exit 1; }
repo_layout_init || exit 2
_TR_PROV="$(dirname "${BASH_SOURCE[0]}")/lib/providers-teams.sh"
[ -f "$_TR_PROV" ] || _TR_PROV="scripts/lib/providers-teams.sh"
# shellcheck source=scripts/lib/providers-teams.sh
. "$_TR_PROV" || { echo "ERREUR: $_TR_PROV introuvable ou illisible" >&2; exit 1; }

TEAM="${TEAM:?TEAM requis}"
# Le secret de la forge porte un nom NEUTRE (2026-09-04) : un gestionnaire
# d'identite rend un jeton OU un couple, et les deux occupent la meme place.
FORGE_SECRET="${FORGE_SECRET:-${GITEA_TOKEN:-}}"
[ -n "$FORGE_SECRET" ] || { echo "REFUS: SECRET_FORGE_REQUIS : ni FORGE_SECRET ni son alias GITEA_TOKEN — le secret de la forge (jeton, ou mot de passe d'un couple avec FORGE_USER)" >&2; exit 2; }
DESCRIPTION="${DESCRIPTION:-}"
APPROVERS="${APPROVERS:-}"
REPO="${REPO:-${TEAM}/apis}"
# G4 (ADR-082, D5) : l'onboarding d'équipe est un geste d'AUTHORING — l'axe env
# a disparu du formulaire (Jenkinsfile ET job.xml). Affectation SÈCHE depuis la
# constante de lib, jamais "${REQ_ENV:-dev}" : les paramètres d'un build Jenkins
# atterrissent dans l'environnement du process (fait mesuré, même raison que
# deploy-pin.sh:29-37), donc un défaut surchargeable rendrait le formulaire
# retiré au-dessus contournable par une simple variable de nœud. La tenancy aux
# paliers supérieurs viendra du chemin de promotion (G5) ou d'un geste opérateur
# D0/D2, jamais d'ici.
REQ_ENV="$DEPLOY_PIN_AUTHORING_ENV"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
GIT_HOST="${GIT_HOST:-http://gitea:3000}"
GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"

fail(){ echo "ERREUR: $*" >&2; exit 1; }

# ── 1. gardes d'entrée — AVANT tout geste Git ────────────────────────────────
# Regex du rôle, avec la leçon \Z du palier 1 : bash/grep matchent par LIGNE,
# donc un TEAM porteur d'un \n interne passerait un grep naïf. On refuse
# d'abord tout caractère hors classe (dont \n), PUIS la forme.
case "$TEAM" in *[!a-z0-9-]*) fail "TEAM_NAME_INVALID : '$TEAM' — ^[a-z0-9][a-z0-9-]{1,30}\$ requis";; esac
printf '%s' "$TEAM" | grep -Eq '^[a-z0-9][a-z0-9-]{1,30}$' \
  || fail "TEAM_NAME_INVALID : '$TEAM' — ^[a-z0-9][a-z0-9-]{1,30}\$ requis"

# (Le refus ENV_NOT_OPEN qui vivait ici a disparu avec l'axe env : il gardait un
# CHOIX du formulaire, et il n'y a plus de choix à refuser — REQ_ENV ne peut
# plus valoir que la constante d'authoring. Le garder aurait été une garde
# structurellement invérifiable : aucune saisie ne peut plus la déclencher.
# L'équivalent côté APPLY, lui, reste NÉCESSAIRE et devient ENV_MISMATCH : la
# branche onboard/<team>-<env> traverse Git, où un suffixe peut être FORGÉ.)

# Ces valeurs sont INJECTÉES dans un YAML : un " ou un retour ligne dans la
# description casserait ou détournerait le fichier — même classe d'attaque que
# l'évasion de chemin du rôle. Refus, pas échappement (KISS + auditables).
#
# Le \ est refusé pour la MÊME raison que le " (revue ronde 1, I1) : injecté
# dans `description: "${DESCRIPTION}"`, un \ final fait lire au parseur YAML
# un \" comme une quote ÉCHAPPÉE — le scalaire ne se ferme plus et avale tout
# le reste du fichier (vérifié : yaml.safe_load casse sur TOUT le fichier,
# pas seulement l'entrée ajoutée). Refuser tout \ plutôt que le seul cas final
# évite d'avoir à raisonner sur d'autres combinaisons d'échappement YAML.
case "$DESCRIPTION" in *'"'*|*$'\n'*|*'\'*) fail "YAML_UNSAFE_INPUT : description sans \" ni \\ ni retour ligne";; esac

# REPO : org/nom, UN SEUL '/'. Chaque segment doit commencer et finir par un
# caractère alphanumérique/underscore (jamais '.' ou '-' en tête/fin), et ne
# jamais contenir '..' — sinon 'REPO=../..' passait la forme org/nom (revue
# ronde 1, I3) alors que team-apply (Task 4) fera confiance à cette valeur
# « déjà validée » pour nommer un dépôt à créer.
case "$REPO" in
  */*/*) fail "YAML_UNSAFE_INPUT : REPO '$REPO' — forme org/nom requise (un seul '/')";;
  */*)
    ORG="${REPO%%/*}"; NAME="${REPO#*/}"
    for SEG in "$ORG" "$NAME"; do
      case "$SEG" in *..*) fail "YAML_UNSAFE_INPUT : REPO '$REPO' — segment '$SEG' contient '..'";; esac
      printf '%s' "$SEG" | grep -Eq '^[A-Za-z0-9_]([A-Za-z0-9_.-]*[A-Za-z0-9_])?$' \
        || fail "YAML_UNSAFE_INPUT : REPO '$REPO' — segment '$SEG' invalide (forme ^[A-Za-z0-9_]([A-Za-z0-9_.-]*[A-Za-z0-9_])?\$)"
    done
    ;;
  *) fail "YAML_UNSAFE_INPUT : REPO '$REPO' — forme org/nom requise";;
esac

# Trim des seuls espaces de BORD (avant/après une virgule) — jamais des
# espaces internes : "A B" doit rester "A B" pour que la classe [A-Za-z0-9_-]
# le refuse ensuite. `tr -d '[:space:]'` FUSIONNAIT "A B" en "AB" (revue
# ronde 1, Minor) — un refus déguisé en échappement, contraire au principe
# affiché plus haut (« refus, pas échappement »).
trim_bord(){ local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

APPROVERS_YAML=""
if [ -n "$APPROVERS" ]; then
  IFS=',' read -ra _APPR <<< "$APPROVERS"
  for a in "${_APPR[@]}"; do
    a="$(trim_bord "$a")"
    [ -z "$a" ] && continue
    printf '%s' "$a" | grep -Eq '^[A-Za-z0-9_-]+$' \
      || fail "YAML_UNSAFE_INPUT : approbateur '$a' — [A-Za-z0-9_-] uniquement (espace interne refusé)"
    APPROVERS_YAML="${APPROVERS_YAML:+$APPROVERS_YAML, }\"$a\""
  done
fi

# Contrat DRY_RUN (motif api-promote-request.sh:131-132) : les gardes ont
# statué, AUCUN geste Git/réseau n'a eu lieu — c'est exactement la surface
# qu'éprouve la porte hors ligne (test-palier-retention.sh ⑱). Placé APRÈS la
# dernière garde de forme et AVANT le premier mktemp/clone : un contrat posé
# plus haut imprimerait GARDES_OK sans avoir rien vérifié.
[ "${DRY_RUN:-0}" = 1 ] && { echo "GARDES_OK : team-request (env d'authoring scellé : ${REQ_ENV})"; exit 0; }

# ── 2. clone + édition de providers.<env>.yml ────────────────────────────────
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
BRANCH="onboard/${TEAM}-${REQ_ENV}"
echo "[1/4] clone ${GIT_REPO}"
git clone -q --depth 1 -b main "${GIT_HOST}/${GIT_REPO}.git" "$WORK/repo" || fail "clone ${GIT_REPO}"
PROV_REL="${SUB_PFX}ansible/providers.${REQ_ENV}.yml"
PROV="$WORK/repo/$PROV_REL"
# Le refus ne disait AUCUN chemin : sur un dépôt client rangé autrement, il
# envoyait chercher un fichier présent. Il nomme désormais ce qui a été lu.
[ -f "$PROV" ] || fail "PROVIDERS_MISSING : ${PROV_REL} absent de ${GIT_REPO}@main (chemin RELATIF à la racine du dépôt, préfixe GIT_SUBDIR='${GIT_SUBDIR}')"

# Jamais d'écrasement silencieux : une équipe déjà déclarée est un refus,
# pas une mise à jour — la mise à jour d'une équipe passe par une PR manuelle.
# Lu en YAML (voir provision-request.sh pour le pourquoi). DEUX gains ici :
# l'ERE qui vivait a cette ligne interpolait $TEAM — une equipe nommee `.*`
# matchait n'importe quelle declaration et refusait toute demande ; et un
# fichier illisible valait « pas encore declaree », donc un doublon ajoute EN
# SILENCE. Les deux sont desormais des refus nommes.
providers_team_declared "$PROV" "$TEAM"
case $? in
  0) fail "TEAM_ALREADY_DECLARED : ${TEAM} est déjà dans ${PROV_REL}" ;;
  1) ;;
  *) fail "PROVIDERS_PARSE : ${PROV_REL} ne se lit pas en YAML (cause ci-dessus) — refus avant toute écriture" ;;
esac

echo "[2/4] entrée ${TEAM} dans providers.${REQ_ENV}.yml"
cat >> "$PROV" <<EOF

  # Ajout par formulaire Jenkins team-request (palier 2) — la PR est l'acte
  # d'autorisation (ADR-081) ; le dépôt et les objets naissent au merge.
  - team: ${TEAM}
    description: "${DESCRIPTION}"
    repo: ${REPO}
    approvers: [${APPROVERS_YAML}]
EOF

# ── 3. branche, commit, push, PR ─────────────────────────────────────────────
echo "[3/4] branche ${BRANCH} + PR"
git -C "$WORK/repo" checkout -q -b "$BRANCH" || fail "création de la branche locale ${BRANCH}"
git -C "$WORK/repo" -c user.name=ci -c user.email=ci@stoa.lab \
  commit -qam "onboard(${TEAM}): demande d'onboarding ${REQ_ENV} (formulaire)" || fail "commit sur ${BRANCH}"
# Fix transverse (constaté par la Task 4, team-apply.sh) : une URL
# http://x:$TOKEN@host/... passée en argv à `git push` est visible EN CLAIR
# dans la table des process (ps -Aww) pendant toute la durée du push, sur le
# process `git` ET son enfant `git-remote-http` — set +x et le grep -v des
# LOGS ne protègent pas ça. On passe donc le credential par un HEADER Basic
# injecté via variables d'ENVIRONNEMENT (GIT_CONFIG_COUNT/KEY_0/VALUE_0 —
# jamais argv, jamais visible par ps -ww), même mécanisme que team-apply.sh
# (repris à l'identique, pas recomposé). L'URL de push redevient nue —
# CONSÉQUENCE (revue finale de branche, Critical) : depuis ce même fix,
# $WORK/pusherr ne peut PLUS contenir le token (il n'a plus jamais transité
# par l'URL), donc le `grep -v "$FORGE_SECRET"` ci-dessous ne filtrait plus
# rien de réel — il ne restait qu'une fuite : le token EN CLAIR dans l'argv
# de CE grep, visible par ps -ww pendant tout le chemin d'échec. Motif de
# team-apply.sh:168 (`cat ... >&2`) repris ici — pusherr ne porte plus de
# secret, rien à masquer.
AUTH_B64=$(printf 'x:%s' "$FORGE_SECRET" | base64 | tr -d '\n')
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
  GIT_CONFIG_VALUE_0="Authorization: Basic ${AUTH_B64}" \
  git -C "$WORK/repo" push -q "${GIT_HOST}/${GIT_REPO}.git" "$BRANCH" 2>"$WORK/pusherr" \
  || { echo "ERREUR: push" >&2; cat "$WORK/pusherr" >&2; exit 1; }
unset AUTH_B64

PR_NUMBER=$(API="${GIT_HOST}/api/v1" GIT_REPO="$GIT_REPO" FORGE_SECRET="$FORGE_SECRET" \
  BRANCH="$BRANCH" TEAM="$TEAM" REQ_ENV="$REQ_ENV" python3 - <<'PY'
import json, os, urllib.request
api, repo, tok = os.environ["API"], os.environ["GIT_REPO"], os.environ["FORGE_SECRET"]
body = {"base": "main", "head": os.environ["BRANCH"],
        "title": f"onboard: équipe {os.environ['TEAM']} ({os.environ['REQ_ENV']})"}
req = urllib.request.Request(f"{api}/repos/{repo}/pulls", method="POST",
    data=json.dumps(body).encode(),
    headers={"Authorization": f"token {tok}", "Content-Type": "application/json"})
print(json.load(urllib.request.urlopen(req))["number"])
PY
) || fail "ouverture de la PR — la branche '${BRANCH}' est déjà poussée sur ${GIT_HOST}/${GIT_REPO} (elle n'a pas de PR) : nettoyer avec 'git push ${GIT_HOST}/${GIT_REPO}.git --delete ${BRANCH}' avant de relancer la demande"
echo "PR #${PR_NUMBER} ouverte : ${GIT_WEB_HOST}/${GIT_REPO}/pulls/${PR_NUMBER}"

# ── 4. PLAN contre le fichier MODIFIÉ + commentaire ──────────────────────────
# Le plan tourne dans le CLONE (la branche), pas dans le checkout du job : ce
# que le valideur lira est calculé sur ce qui sera mergé, rien d'autre.
echo "[4/4] plan (gardes hors ligne du rôle)"
PLAN_LOG="$WORK/plan.log"
# Même idiome que provision-plan.sh : le préfixe vient du knob. En dur, le `cd`
# échoue chez un client, le sous-shell court-circuite le `&&`, et le valideur
# lit « PLAN EN ÉCHEC — NE PAS MERGER » sur une demande parfaitement valide.
( cd "$WORK/repo/${SUB_PFX:-.}" \
  && ansible-playbook -i ansible/inventory.lab.ini ansible/team-plan.yml \
       -e "apim_onb_team=${TEAM}" -e "apim_onb_providers_file=providers.${REQ_ENV}.yml" \
) >"$PLAN_LOG" 2>&1
PLAN_RC=$?
DERIVED=$(grep -oE 'equipe=[^"]*' "$PLAN_LOG" | head -1)
if [ "$PLAN_RC" -eq 0 ]; then
  VERDICT="✅ PLAN OK — ${DERIVED:-dérivations non capturées}"
else
  TAGS=$(grep -oE '(TEAM_[A-Z_]+|TENANT_ROOT_UNSAFE)' "$PLAN_LOG" | sort -u | tr '\n' ' ')
  if [ -n "$TAGS" ]; then
    VERDICT="❌ PLAN EN ÉCHEC — NE PAS MERGER : ${TAGS}"
  else
    # Aucun tag connu extrait (revue ronde 1, I1) : un ❌ sans cause envoie le
    # valideur à la pêche. On poste les dernières lignes d'erreur brutes du
    # plan plutôt qu'une chaîne vide.
    VERDICT="❌ PLAN EN ÉCHEC — NE PAS MERGER : $(tail -3 "$PLAN_LOG" | tr '\n' ' ')"
  fi
fi
BODY="${VERDICT}

Au merge, team-apply : crée le dépôt \`${REPO}\` (squelette ADR-076) puis pose
user/groupe/team gateway + KV/policy Vault (rôle apim_team_onboard, idempotent)."
API="${GIT_HOST}/api/v1" GIT_REPO="$GIT_REPO" FORGE_SECRET="$FORGE_SECRET" \
  PR="$PR_NUMBER" BODY="$BODY" python3 - <<'PY'
import json, os, urllib.request
api, repo, tok = os.environ["API"], os.environ["GIT_REPO"], os.environ["FORGE_SECRET"]
req = urllib.request.Request(f"{api}/repos/{repo}/issues/{os.environ['PR']}/comments",
    method="POST", data=json.dumps({"body": os.environ["BODY"]}).encode(),
    headers={"Authorization": f"token {tok}", "Content-Type": "application/json"})
urllib.request.urlopen(req)
PY
echo "plan ${VERDICT%% *} commenté sur la PR #${PR_NUMBER}"
[ "$PLAN_RC" -eq 0 ]
