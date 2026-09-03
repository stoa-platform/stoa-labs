#!/usr/bin/env bash
# app-request-choices.sh — LES LISTES DU FORMULAIRE app-request, dérivées du
# dépôt À CHAQUE BUILD (jalon A0, GOAL cd-applications 2026-09-02).
#
# POURQUOI CE SCRIPT EXISTE. Jusqu'à A0, les trois listes déroulantes du
# formulaire (palier, équipe, API) vivaient dans ci/jenkins/app-request.job.xml :
# le palier EN DUR, l'équipe et l'API sous des marqueurs <!--CHOICES:*-->
# substitués par setup-team-onboard-jobs.sh AU MOMENT DE LA POSE. Le formulaire
# est désormais POSÉ PAR LE JENKINSFILE (`properties([parameters([…])])`,
# ci/Jenkinsfile.app-request) : il lui faut les valeurs, calculées dans le
# build, depuis le dépôt. C'est ce script — et rien d'autre dans le Groovy.
#
#   ENVS   = env_chain (scripts/lib/env-chain.sh — la chaîne ENTIÈRE, A7) — la MÊME source que
#            provision-request.sh, qui refuse ENV_INVALIDE hors de cette liste ;
#            le terminus est exclu par STRUCTURE (G4/D6), pas par son nom.
#   TEAMS  = generate_choices_teams_raw  (scripts/lib/generate-choices.sh) —
#            providers.<env>.yml relu sur GITEA MAIN, jamais le worktree.
#   APIS   = generate_choices_apis_raw — APIs publiées (dépôt plateforme +
#            dépôts d'équipe déclarés), même tolérance « dépôt déclaré mais
#            absent » et même marqueur CHOICES_SKIPPED_REPOS=<n> sur stderr.
#   <env>  = l'env d'AUTHORING, scellé (DEPLOY_PIN_AUTHORING_ENV, ADR-082) —
#            exactement ce que fait setup-team-onboard-jobs.sh.
#
# FAIL-CLOSED, NON NÉGOCIABLE : chaîne illisible, Gitea injoignable,
# providers.<env>.yml absent/cassé/vide, aucune API, une valeur avec un espace
# ⇒ rc 1, message nommé sur stderr, et le fichier de sortie N'EST PAS ÉCRIT —
# jamais un formulaire aux choix vides, jamais silencieux. Le Jenkinsfile
# double ce refus (FORMULAIRE_VIDE) et ne pose rien : les définitions du build
# précédent restent en place.
#
# LES LISTES SONT DE L'ERGONOMIE, PAS DE L'AUTORITÉ : un choix périmé meurt
# fermé dans provision-request.sh (ENV_INVALIDE, TEAM_NOT_DECLARED, REQ_API
# requis / API_FORMAT_INVALIDE). Limite écrite d'avance : le formulaire montre
# les listes du build PRÉCÉDENT (un build d'amorçage à la pose).
#
# Entrées (env) :
#   CHOICES_OUT   (req) fichier de sortie — trois lignes `ENVS=…`, `TEAMS=…`,
#                 `APIS=…`, valeurs séparées par UN espace (les gardes amont
#                 garantissent des noms sans espace : [a-z0-9-] côté équipe,
#                 [A-Za-z0-9._-]@version côté API, palier alphanumérique).
#   GIT_HOST / GIT_REPO / GITEA_TOKEN : cf. generate-choices.sh (token requis).
#   STOA_ENV_CHAIN_FILE : surcharge de la source de la chaîne (tests).
#
#   CHOICES_OUT=/tmp/choices.env GITEA_TOKEN=… bash scripts/app-request-choices.sh
set -uo pipefail
set +x
cd "$(dirname "$0")/.." || exit 1

CHOICES_OUT="${CHOICES_OUT:?CHOICES_OUT requis (fichier de sortie des listes)}"
refus(){ echo "REFUS: $*" >&2; exit 1; }
# JAMAIS un fichier PÉRIMÉ : le workspace Jenkins survit d'un build à l'autre ;
# un refus ci-dessous ne doit pas laisser le Jenkinsfile relire les listes du
# build précédent comme si elles étaient d'aujourd'hui.
rm -f "$CHOICES_OUT"

# shellcheck source=scripts/lib/env-chain.sh
. scripts/lib/env-chain.sh        || refus "LIB_ABSENTE : scripts/lib/env-chain.sh"
# shellcheck source=scripts/lib/deploy-pin.sh
. scripts/lib/deploy-pin.sh       || refus "LIB_ABSENTE : scripts/lib/deploy-pin.sh"
# shellcheck source=scripts/lib/generate-choices.sh
. scripts/lib/generate-choices.sh || refus "LIB_ABSENTE : scripts/lib/generate-choices.sh"

ENVN="${DEPLOY_PIN_AUTHORING_ENV:?DEPLOY_PIN_AUTHORING_ENV non posé par deploy-pin.sh}"

# A4 (D0) : la chaîne est VALIDÉE avant d'être dérivée — une porte `to: itn`
# ou une clé mal orthographiée ne pose pas un formulaire sur une politique
# fausse (fail-closed : les listes précédentes restent en place).
[ -r "$(_env_chain_file)" ] || refus "CHAINE_ILLISIBLE : source illisible $(_env_chain_file)"
env_chain_validate 2>"${CHOICES_OUT}.validate.err" \
  || { refus "CHAINE_INVALIDE : $(tail -1 "${CHOICES_OUT}.validate.err" 2>/dev/null) (source $(_env_chain_file))"; }
rm -f "${CHOICES_OUT}.validate.err"
# A7 : la chaîne ENTIÈRE, terminus compris — le terminus n'est plus exclu par
# structure, il est gardé par ses portes (refs, quatre yeux, ITSM, voie, credential).
ENVS="$(env_chain)" || refus "CHAINE_ILLISIBLE : env_chain (source $(_env_chain_file))"
[ -n "$ENVS" ] || refus "CHAINE_VIDE : chaîne vide"

# Sous-shell : le ${GITEA_TOKEN:?} de la lib n'abat que lui, le message reste le nôtre.
TEAMS_RAW="$(generate_choices_teams_raw "$ENVN")" || refus "EQUIPES_INDISPONIBLES : providers.${ENVN}.yml sur Gitea main (voir ci-dessus)"
APIS_RAW="$(generate_choices_apis_raw "$ENVN")"   || refus "APIS_INDISPONIBLES : APIs publiées (voir ci-dessus)"

# Une valeur par ligne → une ligne, séparateur espace ; doublons exacts écartés,
# ordre de déclaration préservé (équipes) / tri de la lib (APIs).
join_sp(){ awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/ $//'; }
TEAMS="$(printf '%s\n' "$TEAMS_RAW" | join_sp)"
APIS="$(printf '%s\n' "$APIS_RAW" | join_sp)"
[ -n "$TEAMS" ] || refus "EQUIPES_VIDES : liste vide après filtrage"
[ -n "$APIS" ]  || refus "APIS_VIDES : liste vide après filtrage"

# Défense en profondeur : une valeur portant un espace casserait le découpage
# côté Jenkinsfile (tokenize(' ')) — elle est impossible par les gardes amont,
# on le VÉRIFIE quand même.
for v in $ENVS $TEAMS $APIS; do
  case "$v" in *[!A-Za-z0-9._@-]*) refus "VALEUR_INVALIDE : '$v' hors de [A-Za-z0-9._@-]";; esac
done

# Écriture ATOMIQUE, seulement ici : aucun refus ci-dessus n'a laissé de fichier.
TMPF="$(mktemp "${CHOICES_OUT}.XXXXXX")" || refus "MKTEMP : $CHOICES_OUT"
if ! printf 'ENVS=%s\nTEAMS=%s\nAPIS=%s\n' "$ENVS" "$TEAMS" "$APIS" > "$TMPF" || ! mv "$TMPF" "$CHOICES_OUT"; then
  rm -f "$TMPF"; refus "ECRITURE : $CHOICES_OUT"
fi
echo "formulaire app-request (env d'authoring ${ENVN}) : paliers [${ENVS}] ; équipes [${TEAMS}] ; APIs [${APIS}]"
