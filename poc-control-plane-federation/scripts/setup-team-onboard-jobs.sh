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
#   team-request  → ci/jenkins/team-request.job.xml
#   app-request   → ci/jenkins/app-request.job.xml
#   team-apply    → ci/jenkins/team-apply.job.xml
#   api-request   → ci/jenkins/api-request.job.xml (Task 5, palier 3 — la porte
#                   du PRODUCTEUR, pendant app-request côté consommateur)
#   team-publish  → ci/jenkins/team-publish.job.xml (Task 7, palier 3 — l'APPLY
#                   post-merge d'api-request ; JOB UNIQUE partagé par TOUS les
#                   dépôts d'équipe, l'équipe autorisée étant dérivée du dépôt
#                   déclencheur par topologie — pas de placeholder ici)
#   api-promote-export → ci/jenkins/api-promote-export.job.xml (Task 5, jalon
#                   G5 — le chemin d'EXPORT : joue apim_promote_api en
#                   action=export contre la gateway d'authoring, pousse
#                   l'archive au registre Gitea, imprime guid/sha256/package.
#                   Sans marqueur CHOICES (ni TEAMS ni APIS) : copié tel quel,
#                   comme team-request/team-apply. ⚠ api-promote-request
#                   (jalon G3, le formulaire DE PROMOTION lui-même) n'a PAS de
#                   job.xml et n'est posé par AUCUN script de ce dépôt — dette
#                   distincte, non comblée ici (cf. l'en-tête du job.xml
#                   d'api-promote-export pour le détail de ce qui a été
#                   vérifié).
#   team-promote  → ci/jenkins/team-promote.job.xml (Task 7, jalon G5 — l'APPLY
#                   post-merge d'une PR promote/<api>-<env> : JOB UNIQUE
#                   partagé par TOUS les dépôts d'équipe, MÊME token webhook
#                   que team-publish (D1 — le plugin generic-webhook-trigger
#                   déclenche tous les jobs enregistrés sur un token donné,
#                   aucun geste sur les dépôts d'équipe). Sans marqueur
#                   CHOICES : copié tel quel, comme team-publish.
#
# ── LISTES DYNAMIQUES (Task 3, palier 3) ─────────────────────────────────────
# Les XML de jobs à listes déroulantes portent des PLACEHOLDERS
# <!--CHOICES:TEAMS--> / <!--CHOICES:APIS-->. Avant de poser un job, CE script
# les remplace par les fragments <string>…</string> RÉELLEMENT trouvés sur
# Gitea main (scripts/lib/generate-choices.sh) — jamais depuis ce worktree.
#
# NO-OP GARANTI pour un job SANS placeholder : la substitution n'est tentée
# QUE sur les XML qui contiennent au moins un des deux marqueurs (recherche
# statique, avant tout réseau) — team-request/team-apply en ressortent donc
# une copie strictement identique, jamais touchés par sed, jamais dépendants
# de Gitea. app-request.job.xml (Task 4) et api-request.job.xml (Task 5) sont
# les deux consommateurs réels des marqueurs — le premier pour TEAMS+APIS
# (côté consommateur), le second pour TEAMS+APIS aussi (côté producteur,
# API_BASE en mode nouvelle-version).
#
# FAIL-CLOSED : si au moins un job POSÉ CE RUN porte un placeholder, la
# génération correspondante (Gitea injoignable, providers.<env>.yml absent/
# cassé, liste finale vide) fait échouer TOUT le run — AUCUN POST n'est
# envoyé à Jenkins. Jamais un formulaire aux choix vides, jamais silencieux.
#
# TOLÉRANCE "job absent" : un nom cité dans JOBS dont le XML n'existe pas
# encore dans le dépôt (ex. un futur job de palier 3 pas encore livré) est
# signalé puis IGNORÉ — pas un échec. C'est ce qui a permis à team-apply.sh de
# demander la re-pose de "app-request api-request" avant même que ce dernier
# n'existe (Task 3/4) ; les deux XML sont désormais livrés (Task 4/5), donc ce
# chemin n'a plus de cas réel dans JOBS par défaut — il reste la protection
# pour tout futur job cité avant sa propre livraison.
#
# Usage :
#   JENKINS_UI=https://jenkins.labs.gostoa.dev \
#   JENKINS_USER=<login> JENKINS_TOKEN=<api-token> \
#     ./scripts/setup-team-onboard-jobs.sh
#
#   DRY_RUN=true / ALLOW_RECREATE=true : transmis tels quels au délégué.
#   (ENVN n'est PLUS une entrée : G4/ADR-082 le SCELLE sur l'env d'authoring,
#    voir plus bas. Il ne désigne que l'env dont les listes sont dérivées,
#    providers.<env>.yml.)
#   GITEA_TOKEN / GIT_HOST / GIT_REPO : requis SEULEMENT si un job posé ce run
#     porte un placeholder (cf. scripts/lib/generate-choices.sh).
set -uo pipefail
set +x
cd "$(dirname "$0")/.."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Auto-localisation par BASH_SOURCE quand le fichier vit dans son arbre ; repli
# sur le cwd (fixé par le `cd` ci-dessus) pour les invocations où le dirname ne
# contient pas lib/ — même motif que setup-vault-paliers.sh:26-38.
_STO_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/deploy-pin.sh"
[ -f "$_STO_LIB" ] || _STO_LIB="scripts/lib/deploy-pin.sh"
# `set -e` n'est pas actif ici : sans garde explicite, un fichier manquant
# laisserait bash continuer jusqu'à un « unbound variable » sur la constante.
# shellcheck source=scripts/lib/deploy-pin.sh
. "$_STO_LIB" || { echo "ERREUR: $_STO_LIB introuvable ou illisible" >&2; exit 1; }

JENKINS_UI="${JENKINS_UI:-http://localhost:18080}"
JOBS="${JOBS:-team-request app-request team-apply api-request team-publish api-promote-export team-promote}"
# G4 (ADR-082) : ENVN est SCELLÉ sur l'env d'authoring — affectation sèche
# depuis la constante de lib, jamais "${ENVN:-dev}" : les variables d'un job
# Jenkins atterrissent dans l'environnement du process (fait mesuré, même
# raison que deploy-pin.sh:29-37). Les listes que ce poseur dérive sont celles
# du palier d'AUTHORING (ADR-079) ; au-delà, c'est la promotion (marqueurs G3,
# verbe archive G5) — et son autorité est la rétention de credential, pas une
# variable.
ENVN="$DEPLOY_PIN_AUTHORING_ENV"

ok(){   printf '  \033[32m✅\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m⚠️\033[0m  %s\n' "$*"; }
ko(){   printf '  \033[31m❌\033[0m %s\n' "$*"; exit 1; }

# ── 0. tolérance "job absent" — AVANT tout le reste ──────────────────────────
# Un job non encore livré (ci/jenkins/<nom>.job.xml absent) ne doit jamais
# faire échouer la pose des jobs PRÉSENTS dans le même appel : c'est ce dont
# team-apply.sh a besoin pour demander "app-request api-request" alors
# qu'api-request n'existe pas encore (Task 5).
PRESENT=""
for J in $JOBS; do
  if [ -f "ci/jenkins/${J}.job.xml" ]; then
    PRESENT="${PRESENT:+$PRESENT }$J"
  else
    warn "job '$J' absent du dépôt (ci/jenkins/${J}.job.xml) — ignoré (pas encore livré)"
  fi
done
if [ -z "$PRESENT" ]; then
  ok "aucun job présent parmi [$JOBS] — rien à poser"
  exit 0
fi
JOBS="$PRESENT"

# ── 1. les listes dynamiques sont-elles nécessaires CE RUN ? ────────────────
# Recherche STATIQUE (aucun réseau) : seule la présence d'un placeholder dans
# un XML effectivement posé ce run engage generate-choices.sh — les jobs
# sans liste n'ont donc jamais besoin de GITEA_TOKEN/Gitea joignable.
NEED_TEAMS=false; NEED_APIS=false
for J in $JOBS; do
  grep -q '<!--CHOICES:TEAMS-->' "ci/jenkins/${J}.job.xml" && NEED_TEAMS=true
  grep -q '<!--CHOICES:APIS-->'  "ci/jenkins/${J}.job.xml" && NEED_APIS=true
done

STAGE=$(mktemp -d) || ko "impossible de créer le dossier de mise en scène"
trap 'rm -rf "$STAGE"' EXIT

TEAMS_FRAG="$STAGE/teams.frag"; : > "$TEAMS_FRAG"
APIS_FRAG="$STAGE/apis.frag";   : > "$APIS_FRAG"

if [ "$NEED_TEAMS" = true ] || [ "$NEED_APIS" = true ]; then
  # shellcheck source=lib/generate-choices.sh
  . "$SCRIPT_DIR/lib/generate-choices.sh"
fi

if [ "$NEED_TEAMS" = true ]; then
  # Passage par command substitution (motif du dépôt, cf. team-apply.sh
  # REPO_FULL=$(...) || fail) : le ${GITEA_TOKEN:?...} de la lib, s'il
  # déclenche, n'abat QUE ce sous-shell — le run reste maître de son message
  # et de son code de sortie, jamais un abandon brut de bash.
  OUT=$(generate_choices_teams "$ENVN") \
    || ko "génération de la liste des équipes (env=${ENVN}) en échec — AUCUN POST envoyé à Jenkins"
  printf '%s\n' "$OUT" > "$TEAMS_FRAG"
  ok "liste des équipes générée ($(grep -c '<string>' "$TEAMS_FRAG") équipe(s), depuis Gitea main)"
fi

if [ "$NEED_APIS" = true ]; then
  OUT=$(generate_choices_apis "$ENVN") \
    || ko "génération de la liste des APIs (env=${ENVN}) en échec — AUCUN POST envoyé à Jenkins"
  printf '%s\n' "$OUT" > "$APIS_FRAG"
  ok "liste des APIs générée ($(grep -c '<string>' "$APIS_FRAG") API(s), depuis Gitea main)"
fi

# ── 2. rendu des XML dans le dossier de mise en scène ────────────────────────
# Un job SANS aucun des deux marqueurs est copié TEL QUEL — jamais passé à
# sed — garantie d'identité octet pour octet (team-request, team-apply).
for J in $JOBS; do
  SRC="ci/jenkins/${J}.job.xml"
  DST="$STAGE/${J}.job.xml"
  cp "$SRC" "$DST"
  if grep -Eq '<!--CHOICES:(TEAMS|APIS)-->' "$DST"; then
    # sed PORTABLE double-forme BSD/GNU (leçon du palier 2 : `-i ''` seul est
    # macOS/BSD-only, un `-i` nu seul est GNU-only — on tente le premier,
    # silencieusement, et on retombe sur le second s'il échoue). `r fichier`
    # insère le CONTENU du fragment après la ligne qui matche, `d` retire le
    # marqueur — combo portable pour une substitution MULTI-LIGNES, que la
    # forme `s///` ne fait pas proprement en BRE cross-plateforme.
    sed -i '' \
      -e "/<!--CHOICES:TEAMS-->/r ${TEAMS_FRAG}" -e "/<!--CHOICES:TEAMS-->/d" \
      -e "/<!--CHOICES:APIS-->/r ${APIS_FRAG}"   -e "/<!--CHOICES:APIS-->/d" \
      "$DST" 2>/dev/null \
    || sed -i \
      -e "/<!--CHOICES:TEAMS-->/r ${TEAMS_FRAG}" -e "/<!--CHOICES:TEAMS-->/d" \
      -e "/<!--CHOICES:APIS-->/r ${APIS_FRAG}"   -e "/<!--CHOICES:APIS-->/d" \
      "$DST"
    ok "$J : placeholder(s) substitué(s)"
  fi
done

# ── 3. délégation — JOBS_SRC_DIR pointe sur le dossier de mise en scène ─────
# setup-provision-jobs.sh porte le mécanisme réseau (crumb, auth, charset,
# update-en-place/create) : on ne le duplique pas ici, on lui donne juste une
# SOURCE différente pour les XML déjà rendus (ÉCART déclaré, cf. son en-tête).
echo "Jobs du palier onboarding équipe à poser : $JOBS"
JENKINS_UI="$JENKINS_UI" JOBS="$JOBS" JOBS_SRC_DIR="$STAGE" \
  bash "$SCRIPT_DIR/setup-provision-jobs.sh" \
  && ok "jobs du palier alignés sur le dépôt ($JOBS)" \
  || ko "pose des jobs du palier en échec"
