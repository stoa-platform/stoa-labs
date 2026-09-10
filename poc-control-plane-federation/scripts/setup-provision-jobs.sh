#!/usr/bin/env bash
# setup-provision-jobs.sh — (re)pousse la CONFIGURATION d'un ou plusieurs jobs
# Jenkins depuis leur XML du dépôt (ci/jenkins/<nom>.job.xml).
#
# Par défaut : `provision-apply` et `provision-plan`. La variable JOBS le rend
# GÉNÉRIQUE — setup-provision-request-job.sh l'appelle ainsi pour son propre job
# plutôt que de réécrire la même logique.
#
# POURQUOI CE SCRIPT EXISTE. Depuis A0 (2026-09-02), PLUS AUCUN job de cette
# chaîne ne porte de Groovy dans son XML : `provision-apply` (A2),
# `provision-plan` et `provisioning-request` (A0) sont des COQUILLES « Pipeline
# from SCM » (ci/Jenkinsfile.<job>) — leur logique suit le push sur la branche
# de base de la forge (`git push gitea HEAD`).
# Mais la coquille — pointeur SCM + miroir du bloc <triggers>, qui GAGNE sur le
# Jenkinsfile — se (re)pose toujours par ce script : une fois à la conversion,
# puis à chaque changement de clé du webhook.
#
# ─────────────────────────────────────────────────────────────────────────────
# BOOTSTRAP_JOBS : LE BUILD D'AMORÇAGE, POUR LES JOBS QUI POSENT LEUR FORMULAIRE
# ─────────────────────────────────────────────────────────────────────────────
# `app-request` (A0) pose ses onze paramètres DEPUIS SON JENKINSFILE
# (`properties([parameters([…])])`, listes dérivées du dépôt à chaque build).
# MESURÉ le 2026-09-02 : re-poser son XML (POST config.xml) EFFACE ces
# paramètres. Un build d'amorçage doit donc suivre CHAQUE pose, sinon le job
# n'a plus de formulaire jusqu'au premier clic « Build ». Les jobs nommés dans
# BOOTSTRAP_JOBS reçoivent, après une pose RÉUSSIE, un `POST /job/<nom>/build`
# (201 attendu — sans paramètre, c'est précisément ce qu'un job fraîchement
# posé accepte ; 400 signifierait « déjà paramétré », donc une pose qui n'a pas
# eu lieu : avertissement ET échec du run, jamais silencieux). Le build n'est
# PAS attendu (fire-and-forget) : le formulaire existe dès sa fin.
# setup-team-onboard-jobs.sh le demande pour app-request ; un appelant direct
# doit le demander explicitement.
#
# ─────────────────────────────────────────────────────────────────────────────
# CE SCRIPT MET À JOUR EN PLACE, IL NE SUPPRIME PAS
# ─────────────────────────────────────────────────────────────────────────────
# Son voisin setup-provision-request-job.sh fait delete+create, « déterministe »
# sur un lab jetable. Sur une instance réelle, supprimer un job détruit son
# HISTORIQUE DE BUILDS — donc, pour ces jobs-là, la trace des apply nominatifs
# déjà réalisés. On tente donc d'abord `POST /job/<nom>/config.xml`, qui met à
# jour en conservant l'historique ; la création n'a lieu que si le job est
# ABSENT. Le delete+create reste possible mais doit être demandé
# EXPLICITEMENT (ALLOW_RECREATE=true) : une action irréversible ne doit pas être
# un repli silencieux.
#
# Usage :
#   JENKINS_UI=https://jenkins.labs.gostoa.dev \
#   JENKINS_USER=<login> JENKINS_TOKEN=<api-token> \
#     ./scripts/setup-provision-jobs.sh
#
#   GIT_BASE, ou GIT_HOST + GIT_REPO : REQUIS (L3, 2026-09-10). Les XML des
#                   jobs portent __GIT_BASE__ au lieu d'un nom de branche ; ce
#                   script le substitue. GIT_BASE nomme la branche ; à défaut,
#                   GIT_HOST + GIT_REPO composent l'URL du dépôt plateforme
#                   (vue DEPUIS CE POSTE) dont la HEAD est alors interrogée.
#                   Ni l'un ni l'autre : refus BRANCHE_PAR_DEFAUT_INDECIDABLE,
#                   aucun job posé.
#   DRY_RUN=true    n'envoie AUCUNE écriture — affiche ce qui serait fait.
#   JOBS="provision-apply"   restreint aux jobs nommés (défaut : les deux).
#   ALLOW_RECREATE=true      autorise delete+create si la mise à jour échoue.
#   BOOTSTRAP_JOBS="app-request"  jobs à AMORCER d'un build après leur pose
#                            (cf. ci-dessus) ; défaut : aucun.
#
# Les identifiants ne transitent JAMAIS par le dépôt ni par argv : uniquement
# par l'environnement, et `set +x` empêche leur écho.
set -uo pipefail
set +x
cd "$(dirname "$0")/.." || { echo "REFUS: racine du depot introuvable" >&2; exit 2; }

JENKINS_UI="${JENKINS_UI:-http://localhost:18080}"
JENKINS_USER="${JENKINS_USER:-}"
JENKINS_TOKEN="${JENKINS_TOKEN:-}"
DRY_RUN="${DRY_RUN:-false}"
ALLOW_RECREATE="${ALLOW_RECREATE:-false}"
JOBS="${JOBS:-provision-apply provision-plan}"
BOOTSTRAP_JOBS="${BOOTSTRAP_JOBS:-}"
# ÉCART Task 3 (palier 3, déclaré) : JOBS_SRC_DIR permet à un appelant de
# poser des XML PRÉ-RENDUS (setup-team-onboard-jobs.sh y substitue les
# placeholders <!--CHOICES:*--> avant l'appel, dans un dossier de mise en
# scène jetable) sans dupliquer ici la logique crumb/auth/POST — le motif que
# ce fichier revendique déjà pour lui-même (cf. en-tête). Additif et
# rétrocompatible : par défaut, comportement identique à avant (ci/jenkins).
JOBS_SRC_DIR="${JOBS_SRC_DIR:-ci/jenkins}"

# Disposition du dépôt (2026-09-03) : le <scriptPath> des coquilles porte le
# préfixe du livrable. Plutôt que d'obliger un client à éditer treize XML à la
# main, le POSEUR le compose — la coquille reste la source de vérité pour tout
# le reste. La mise en scène ne touche QUE ce que le poseur doit composer : le
# préfixe, et depuis L3 la branche (__GIT_BASE__). Le XML posté est donc la
# source à ces substitutions près, et à rien d'autre (épreuve a0-wiring, qui le
# compare octet pour octet à la source ainsi substituée).
# shellcheck source=scripts/lib/repo-layout.sh
. "$(dirname "$0")/lib/repo-layout.sh" || { echo "ERREUR: lib/repo-layout.sh introuvable" >&2; exit 1; }
repo_layout_init || exit 2
# shellcheck source=scripts/lib/git-base.sh
. "$(dirname "$0")/lib/git-base.sh" || { echo "ERREUR: lib/git-base.sh introuvable" >&2; exit 1; }

# ── LA BRANCHE DU <scm> (L3, 2026-09-10) ─────────────────────────────────────
# Les XML des jobs ne NOMMENT plus de branche : ils portent `__GIT_BASE__`, que
# ce poseur substitue à la pose. Le littéral « main » qui s'y trouvait faisait
# checkouter au job une branche INEXISTANTE chez un client dont la branche par
# défaut est `master` — et cela se produit AVANT que le moindre script de la
# chaîne ne démarre : rien, en aval, ne pouvait le rattraper ni le nommer.
# La branche vient donc de l'autorité : knob GIT_BASE, sinon la HEAD annoncée
# par le dépôt plateforme, sinon un REFUS nommé. Aucun défaut de site.
# L'URL est celle du dépôt plateforme vue DEPUIS CE POSTE (GIT_HOST/GIT_REPO) :
# celle qu'écrit le XML est vue depuis l'agent Jenkins (réseau docker) et n'est
# pas joignable d'ici. Ni l'une ni l'autre n'est devinée — les deux sont des
# knobs, et leur absence est un refus que la lib formule elle-même.
#
# LE REFUS EST À NOUS, PAS À LA LIB (revue 4c). Passer une URL VIDE à
# git_base_init donne un refus juste mais inutilisable ici : il parle de
# « l'argument de git_base_init » et de GIT_CLONE_URL, deux choses qu'un
# exploitant qui pose des jobs depuis son poste n'a pas sous la main. Ce sont
# GIT_BASE, ou GIT_HOST **et** GIT_REPO, qu'il doit poser — alors c'est ce
# script, qui connaît SES knobs, qui le dit, AVANT d'appeler la lib.
GIT_HOST="${GIT_HOST:-}"
GIT_REPO="${GIT_REPO:-}"
if { [ -z "${GIT_BASE:-}" ] || [ "${GIT_BASE:-}" = auto ]; } \
   && { [ -z "$GIT_HOST" ] || [ -z "$GIT_REPO" ]; }; then
  echo "REFUS: BRANCHE_PAR_DEFAUT_INDECIDABLE : les XML des jobs portent __GIT_BASE__ et rien ici ne dit par quoi le remplacer — poser GIT_BASE (la branche, explicitement), ou GIT_HOST et GIT_REPO pour que la HEAD du dépôt plateforme soit découverte. Aucun job n'a été posé." >&2
  exit 2
fi
PLATEFORME_URL=""
[ -n "$GIT_HOST" ] && [ -n "$GIT_REPO" ] && PLATEFORME_URL="${GIT_HOST%/}/${GIT_REPO}.git"
git_base_init "$PLATEFORME_URL" || exit 2

STAGE_DIR=""   # créé à la demande, seulement si une substitution est nécessaire

# stage_xml <job> <xml source> → chemin du XML À POSTER (source, ou copie ajustée)
# DEUX substitutions indépendantes : la BRANCHE (__GIT_BASE__, par l'autorité,
# fail-closed) et le PRÉFIXE du livrable dans <scriptPath>. Une source qui n'a
# besoin d'aucune des deux part telle quelle, octet pour octet.
stage_xml() {
  local j="$1" src="$2" veut="${SUB_PFX}ci/Jenkinsfile.${1}" a base rep="" dst
  a=$(sed -n 's#.*<scriptPath>\([^<]*\)</scriptPath>.*#\1#p' "$src" | head -1)
  # pas de scriptPath (coquille Groovy inline), ou deja le bon : rien a reecrire
  if [ -n "$a" ] && [ "$a" != "$veut" ]; then
    # le nom du Jenkinsfile peut differer du nom du job : on ne remplace QUE le prefixe
    base="${a##*/}"
    case "$a" in */*) rep="${SUB_PFX}ci/${base}" ;; esac
    [ "$rep" = "$a" ] && rep=""
  fi
  if [ -z "$rep" ] && ! grep -qF '__GIT_BASE__' "$src"; then printf '%s' "$src"; return 0; fi
  [ -n "$STAGE_DIR" ] || { STAGE_DIR=$(mktemp -d) || return 1; }
  dst="$STAGE_DIR/${j}.job.xml"
  # La branche d'abord : si le placeholder survit, RIEN n'est mis en scène et le
  # refus est déjà nommé par la lib (XML_PLACEHOLDER_RESTANT).
  git_base_xml_substituer "$src" "$dst" || return 1
  if [ -n "$rep" ]; then
    sed "s#<scriptPath>[^<]*</scriptPath>#<scriptPath>${rep}</scriptPath>#" "$dst" > "${dst}.tmp" \
      && mv "${dst}.tmp" "$dst" || return 1
  fi
  printf '%s' "$dst"
}

ok(){   printf '  ✅ %s\n' "$*"; }
warn(){ printf '  ⚠️  %s\n' "$*"; }
ko(){   printf '  ❌ %s\n' "$*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# DEUX AUTHENTIFICATIONS SUPERPOSÉES, ET C'EST VOULU
# ─────────────────────────────────────────────────────────────────────────────
# 1. Le PORTAIL devant l'instance (Cloudflare Access chez ce client) : il répond
#    302 vers son écran de connexion à toute requête non authentifiée, AVANT que
#    Jenkins ne voie quoi que ce soit. Un token d'API Jenkins seul ne passe donc
#    pas. On s'y authentifie par un SERVICE TOKEN (paire id/secret), le mode
#    prévu pour l'automatisation — l'alternative étant une session navigateur ou
#    WARP, qu'un script ne peut pas porter.
# 2. JENKINS lui-même : login + token d'API.
# Les deux sont indépendants : l'un peut être requis sans l'autre.
#
# RIEN NE PASSE PAR argv. Ni `-u user:token`, ni `-H "CF-Access-Client-Secret:
# ..."` : tout cela est visible dans `ps auxww` le temps de l'appel, et sur une
# machine partagée ce n'est pas théorique. La configuration est construite sur
# l'ENTRÉE STANDARD et lue par `curl -K -`, qui accepte aussi bien `user =` que
# `header =`.
#
# (Un tableau `AUTH=()` développé en `"${AUTH[@]}"` était le premier réflexe : il
# échoue sous `set -u` en bash 3.2 — celui de macOS — quand le tableau est vide,
# et le script rendait « Jenkins injoignable » sur une instance parfaitement
# joignable. Mesuré le 2026-08-03 : le pire diagnostic possible, celui qui envoie
# chercher la panne ailleurs.)
CF_ACCESS_CLIENT_ID="${CF_ACCESS_CLIENT_ID:-}"
CF_ACCESS_CLIENT_SECRET="${CF_ACCESS_CLIENT_SECRET:-}"
# Troisième voie d'accès au portail, à côté du service token : le JWT d'une
# session utilisateur ouverte par `cloudflared access login`. Utile quand aucun
# service token n'est autorisé sur l'application — c'est le cas mesuré le
# 2026-08-04 sur jenkins.labs.gostoa.dev (service_token_status: false).
# Vide + cloudflared présent -> on tente de le récupérer tout seul.
CF_ACCESS_TOKEN="${CF_ACCESS_TOKEN:-}"
if [ -z "$CF_ACCESS_TOKEN" ] && [ -z "$CF_ACCESS_CLIENT_ID" ] && command -v cloudflared >/dev/null 2>&1; then
  case "$JENKINS_UI" in
    https://*) CF_ACCESS_TOKEN=$(cloudflared access token --app "$JENKINS_UI" 2>/dev/null | grep -E '^ey' | head -1) ;;
  esac
fi

jcurl(){
  {
    [ -n "$JENKINS_USER" ] && printf 'user = "%s:%s"\n' "$JENKINS_USER" "$JENKINS_TOKEN"
    if [ -n "$CF_ACCESS_CLIENT_ID" ]; then
      printf 'header = "CF-Access-Client-Id: %s"\n' "$CF_ACCESS_CLIENT_ID"
      printf 'header = "CF-Access-Client-Secret: %s"\n' "$CF_ACCESS_CLIENT_SECRET"
    fi
    [ -n "$CF_ACCESS_TOKEN" ] && printf 'header = "cf-access-token: %s"\n' "$CF_ACCESS_TOKEN"
  } | curl -K - "$@"
}

if [ -n "$JENKINS_USER" ]; then
  echo "Authentification Jenkins : ${JENKINS_USER} (token masqué, hors argv)"
else
  echo "Authentification Jenkins : AUCUNE (instance ouverte présumée)"
fi
if [ -n "$CF_ACCESS_CLIENT_ID" ]; then
  echo "Portail : service token Cloudflare Access (secret masqué, hors argv)"
elif [ -n "$CF_ACCESS_TOKEN" ]; then
  echo "Portail : JWT de session cloudflared (récupéré automatiquement, hors argv)"
else
  echo "Portail : aucun jeton — échouera si l'instance est derrière un portail"
fi

echo "Cible : $JENKINS_UI"
[ "$DRY_RUN" = "true" ] && echo "MODE DRY-RUN : aucune écriture ne sera envoyée."

# ── 0. les XML sont-ils valides ? ────────────────────────────────────────────
# Avant tout appel réseau : pousser un XML cassé remplacerait une config qui
# marche par une qui ne se charge pas.
for J in $JOBS; do
  X="${JOBS_SRC_DIR}/${J}.job.xml"
  [ -f "$X" ] || ko "XML introuvable : $X"
  python3 -c "import xml.etree.ElementTree as T; T.parse('$X')" 2>/dev/null \
    || ko "XML mal formé : $X (rien n'a été envoyé)"
done
ok "XML des jobs bien formés"

# ── 1. crumb CSRF ────────────────────────────────────────────────────────────
CK=$(mktemp); CB=$(mktemp); trap 'rm -f "$CK" "$CB"; [ -n "$STAGE_DIR" ] && rm -rf "$STAGE_DIR"' EXIT
# On lit le CODE plutôt que de se fier à `curl -f` : une redirection 302 vers un
# portail N'EST PAS une erreur HTTP, `-f` la laisse passer, et le script échouait
# ensuite sur un JSON vide avec un message qui n'aidait pas. Chaque cas mérite
# son diagnostic — c'est lui qui dit à l'ops QUOI fournir.
HC=$(jcurl -s -o "$CB" -w '%{http_code}' -c "$CK" "$JENKINS_UI/crumbIssuer/api/json")
case "$HC" in
  200) : ;;
  301|302|303|307|308)
    RU=$(jcurl -s -o /dev/null -w '%{redirect_url}' "$JENKINS_UI/crumbIssuer/api/json")
    echo "  ❌ redirigé (HTTP $HC) vers un portail avant d'atteindre Jenkins." >&2
    case "$RU" in
      *cloudflareaccess.com*) echo "     Portail : Cloudflare Access." >&2 ;;
      *) [ -n "$RU" ] && echo "     Redirection : ${RU%%\?*}" >&2 ;;
    esac
    echo "     Deux voies : (a) ouvrir une session —" >&2
    echo "         cloudflared access login --url $JENKINS_UI" >&2
    echo "       puis relancer : le JWT est repris automatiquement ;" >&2
    echo "     (b) un service token AUTORISÉ sur cette application" >&2
    echo "         (CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET)." >&2
    ko "portail non franchi" ;;
  401|403) ko "identifiants refusés (HTTP $HC) — vérifier JENKINS_USER / JENKINS_TOKEN, et les droits de configuration des jobs" ;;
  000)     ko "Jenkins injoignable ($JENKINS_UI) — réseau, DNS ou TLS" ;;
  *)       ko "réponse inattendue du crumbIssuer (HTTP $HC)" ;;
esac
CJ=$(cat "$CB")
F=$(printf '%s' "$CJ" | python3 -c 'import sys,json;print(json.load(sys.stdin)["crumbRequestField"])' 2>/dev/null) \
  || ko "réponse crumbIssuer illisible (HTTP 200 mais corps non JSON — portail intercalé ?)"
C=$(printf '%s' "$CJ" | python3 -c 'import sys,json;print(json.load(sys.stdin)["crumb"])')
ok "crumb CSRF obtenu"

RC=0
for J in $JOBS; do
  X="${JOBS_SRC_DIR}/${J}.job.xml"
  X="$(stage_xml "$J" "$X")" || ko "mise en scene du XML de $J en echec"
  echo
  echo "== $J =="

  EXISTS=$(jcurl -s -b "$CK" -o /dev/null -w '%{http_code}' "$JENKINS_UI/job/$J/api/json")
  if [ "$DRY_RUN" = "true" ]; then
    case "$EXISTS" in
      200) ok "existe → serait MIS À JOUR en place depuis $X (historique conservé)";;
      404) ok "absent → serait CRÉÉ depuis $X";;
      *)   warn "état indéterminé (HTTP $EXISTS) — vérifier les droits";;
    esac
    case " $BOOTSTRAP_JOBS " in *" $J "*) ok "puis serait AMORCÉ d'un build (POST /job/$J/build)";; esac
    continue
  fi

  # LE `charset=utf-8` N'EST PAS DÉCORATIF. Sans lui, Jenkins parse le corps en
  # ISO-8859-1 et casse sur le SECOND octet du premier caractère accentué :
  # « An invalid XML character (Unicode: 0x89) », rendu au client en HTTP 500
  # « Failed to persist config.xml » — un message qui ne dit rien de la cause.
  # Nos descriptions de jobs sont en français : le premier « FUSIONNÉE » suffit.
  #
  # LE DÉPÔT LE SAVAIT DÉJÀ, et je l'ai réappris à mes dépens : setup-carto-job.sh,
  # setup-selfservice-job.sh et setup-user-deploy-job.sh déclarent tous ce charset,
  # le second nommant même l'erreur (« invalid XML character 0x80 ») et le piège
  # qui va avec — `createItem`, lui, TOLÈRE l'absence de charset, si bien qu'une
  # MISE À JOUR échoue là où une CRÉATION passe. D'où la vérification du code HTTP,
  # ici comme chez eux.
  #
  # (Re-mesuré le 2026-08-04 : même la config RELUE de Jenkins, renvoyée telle
  # quelle, échouait — c'est ce contrôle qui a écarté le contenu et désigné
  # l'en-tête. setup-provision-request-job.sh, lui, contournait ce 500 par un
  # delete+create destructeur : il était le seul à ne pas avoir eu le mémo.)
  POSED=false
  if [ "$EXISTS" = "200" ]; then
    HC=$(jcurl -s -b "$CK" -X POST "$JENKINS_UI/job/$J/config.xml" \
         -H "$F: $C" -H "Content-Type: application/xml; charset=utf-8" \
         --data-binary @"$X" -o /dev/null -w '%{http_code}')
    if [ "$HC" = "200" ]; then
      ok "configuration mise à jour en place (HTTP $HC) — historique conservé"; POSED=true
    elif [ "$ALLOW_RECREATE" = "true" ]; then
      warn "mise à jour refusée (HTTP $HC) — repli delete+create DEMANDÉ, l'historique sera PERDU"
      jcurl -s -b "$CK" -X POST "$JENKINS_UI/job/$J/doDelete" -H "$F: $C" -o /dev/null
      HC=$(jcurl -s -b "$CK" -X POST "$JENKINS_UI/createItem?name=$J" \
           -H "$F: $C" -H "Content-Type: application/xml; charset=utf-8" --data-binary @"$X" -o /dev/null -w '%{http_code}')
      # shellcheck disable=SC2015  # A && B || C est ICI un si-alors-sinon valide : ok/warn/ko rendent toujours 0
      [ "$HC" = "200" ] && { ok "job recréé (HTTP $HC)"; POSED=true; } || { warn "recréation échouée (HTTP $HC)"; RC=1; }
    else
      warn "mise à jour refusée (HTTP $HC). Le job est INCHANGÉ."
      warn "  Relancer avec ALLOW_RECREATE=true pour delete+create — DÉTRUIT l'historique de builds."
      RC=1
    fi
  elif [ "$EXISTS" = "404" ]; then
    HC=$(jcurl -s -b "$CK" -X POST "$JENKINS_UI/createItem?name=$J" \
         -H "$F: $C" -H "Content-Type: application/xml; charset=utf-8" --data-binary @"$X" -o /dev/null -w '%{http_code}')
    # shellcheck disable=SC2015  # A && B || C est ICI un si-alors-sinon valide : ok/warn/ko rendent toujours 0
    [ "$HC" = "200" ] && { ok "job créé (HTTP $HC)"; POSED=true; } || { warn "création échouée (HTTP $HC)"; RC=1; }
  else
    warn "état du job indéterminé (HTTP $EXISTS) — ni mis à jour ni créé"
    RC=1
  fi

  # ── build d'AMORÇAGE, seulement après une pose RÉUSSIE (cf. en-tête) ──────
  case " $BOOTSTRAP_JOBS " in
    *" $J "*)
      if [ "$POSED" = true ]; then
        HC=$(jcurl -s -b "$CK" -X POST "$JENKINS_UI/job/$J/build" -H "$F: $C" -o /dev/null -w '%{http_code}')
        case "$HC" in
          201) ok "build d'amorçage déclenché (HTTP $HC) — le formulaire existe dès sa fin (non attendu ici)";;
          400) warn "amorçage refusé (HTTP 400) : le job est DÉJÀ paramétré — la pose n'a pas remplacé sa configuration ?"; RC=1;;
          *)   warn "amorçage en échec (HTTP $HC) — le job n'a PAS de formulaire tant qu'un build n'a pas tourné (bouton « Build »)"; RC=1;;
        esac
      else
        warn "amorçage NON tenté : la pose de $J a échoué"
      fi;;
  esac
done

echo
if [ "$RC" = "0" ]; then
  echo "OK — les jobs demandés sont alignés sur le dépôt."
  echo "Rappel : ces jobs CLONENT ci/stoa-labs sur Gitea. Les scripts qu'ils"
  echo "appellent doivent y être poussés sur ${GIT_BASE} (git push gitea HEAD),"
  echo "sans quoi la config à jour exécuterait du code périmé."
else
  echo "TERMINÉ AVEC DES ÉCARTS — voir ci-dessus." >&2
fi
exit "$RC"
