#!/usr/bin/env bash
# setup-team-onboard-jobs.sh — pose (crée/met à jour EN PLACE) les jobs Jenkins
# du palier 2 « onboarding équipe » depuis leur XML du dépôt.
#
# DÉLÉGUÉ à setup-provision-jobs.sh, qui porte le mécanisme (crumb CSRF,
# charset=utf-8 obligatoire — sans lui une mise à jour sur une description
# accentuée rend HTTP 500 alors qu'une création passe, cf. son en-tête —,
# update en place / create si absent, repli delete+create seulement sur
# ALLOW_RECREATE=true explicite). Même motif que setup-provision-request-job.sh
# pour son propre job : on n'écrit pas une seconde copie qui divergerait.
#
# JOBS liste les jobs du palier posés par CE script, un nom par mot. Le XML de
# chacun est dérivé du nom (convention de setup-provision-jobs.sh) :
#   team-request → ci/jenkins/team-request.job.xml
# Les Tasks 5 et 7 y ajoutent team-apply et app-request en une ligne chacune.
#
# Usage :
#   JENKINS_UI=https://jenkins.labs.gostoa.dev \
#   JENKINS_USER=<login> JENKINS_TOKEN=<api-token> \
#     ./scripts/setup-team-onboard-jobs.sh
#
#   DRY_RUN=true / ALLOW_RECREATE=true : transmis tels quels au délégué.
set -uo pipefail
cd "$(dirname "$0")/.."

JENKINS_UI="${JENKINS_UI:-http://localhost:18080}"
JOBS="${JOBS:-team-request}"

ok(){ printf '  \033[32m✅\033[0m %s\n' "$*"; }
ko(){ printf '  \033[31m❌\033[0m %s\n' "$*"; exit 1; }

echo "Jobs du palier onboarding équipe à poser : $JOBS"
JENKINS_UI="$JENKINS_UI" JOBS="$JOBS" bash "$(cd "$(dirname "$0")" && pwd)/setup-provision-jobs.sh" \
  && ok "jobs du palier alignés sur le dépôt ($JOBS)" \
  || ko "pose des jobs du palier en échec"
