#!/usr/bin/env bash
# setup-provision-jobs.sh — (re)pousse la CONFIGURATION des jobs de provisioning
# `provision-apply` et `provision-plan` sur une instance Jenkins.
#
# POURQUOI CE SCRIPT EXISTE. Ces deux jobs portent leur script Groovy EN LIGNE
# dans leur XML (CpsFlowDefinition). Contrairement à leurs voisins, qui ne font
# que checkouter le dépôt et lancer un `.sh`, une modification de leur logique
# n'atteint PAS l'instance par un simple `git push` : leur configuration doit
# être repoussée. Jusqu'ici aucun script ne le faisait — ils avaient été créés à
# la main, et l'écart entre le dépôt et l'instance était invisible.
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
#   DRY_RUN=true    n'envoie AUCUNE écriture — affiche ce qui serait fait.
#   JOBS="provision-apply"   restreint aux jobs nommés (défaut : les deux).
#   ALLOW_RECREATE=true      autorise delete+create si la mise à jour échoue.
#
# Les identifiants ne transitent JAMAIS par le dépôt ni par argv : uniquement
# par l'environnement, et `set +x` empêche leur écho.
set -uo pipefail
set +x
cd "$(dirname "$0")/.."

JENKINS_UI="${JENKINS_UI:-http://localhost:18080}"
JENKINS_USER="${JENKINS_USER:-}"
JENKINS_TOKEN="${JENKINS_TOKEN:-}"
DRY_RUN="${DRY_RUN:-false}"
ALLOW_RECREATE="${ALLOW_RECREATE:-false}"
JOBS="${JOBS:-provision-apply provision-plan}"

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

jcurl(){
  {
    [ -n "$JENKINS_USER" ] && printf 'user = "%s:%s"\n' "$JENKINS_USER" "$JENKINS_TOKEN"
    if [ -n "$CF_ACCESS_CLIENT_ID" ]; then
      printf 'header = "CF-Access-Client-Id: %s"\n' "$CF_ACCESS_CLIENT_ID"
      printf 'header = "CF-Access-Client-Secret: %s"\n' "$CF_ACCESS_CLIENT_SECRET"
    fi
  } | curl -K - "$@"
}

if [ -n "$JENKINS_USER" ]; then
  echo "Authentification Jenkins : ${JENKINS_USER} (token masqué, hors argv)"
else
  echo "Authentification Jenkins : AUCUNE (instance ouverte présumée)"
fi
if [ -n "$CF_ACCESS_CLIENT_ID" ]; then
  echo "Portail : service token Cloudflare Access fourni (secret masqué, hors argv)"
else
  echo "Portail : aucun service token — échouera si l'instance est derrière un portail"
fi

echo "Cible : $JENKINS_UI"
[ "$DRY_RUN" = "true" ] && echo "MODE DRY-RUN : aucune écriture ne sera envoyée."

# ── 0. les XML sont-ils valides ? ────────────────────────────────────────────
# Avant tout appel réseau : pousser un XML cassé remplacerait une config qui
# marche par une qui ne se charge pas.
for J in $JOBS; do
  X="ci/jenkins/${J}.job.xml"
  [ -f "$X" ] || ko "XML introuvable : $X"
  python3 -c "import xml.etree.ElementTree as T; T.parse('$X')" 2>/dev/null \
    || ko "XML mal formé : $X (rien n'a été envoyé)"
done
ok "XML des jobs bien formés"

# ── 1. crumb CSRF ────────────────────────────────────────────────────────────
CK=$(mktemp); CB=$(mktemp); trap 'rm -f "$CK" "$CB"' EXIT
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
    ko "fournir CF_ACCESS_CLIENT_ID et CF_ACCESS_CLIENT_SECRET (service token), ou passer par WARP/session navigateur" ;;
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
  X="ci/jenkins/${J}.job.xml"
  echo
  echo "== $J =="

  EXISTS=$(jcurl -s -b "$CK" -o /dev/null -w '%{http_code}' "$JENKINS_UI/job/$J/api/json")
  if [ "$DRY_RUN" = "true" ]; then
    case "$EXISTS" in
      200) ok "existe → serait MIS À JOUR en place depuis $X (historique conservé)";;
      404) ok "absent → serait CRÉÉ depuis $X";;
      *)   warn "état indéterminé (HTTP $EXISTS) — vérifier les droits";;
    esac
    continue
  fi

  # LE `charset=utf-8` N'EST PAS DÉCORATIF. Sans lui, Jenkins parse le corps en
  # ISO-8859-1 et casse sur le SECOND octet du premier caractère accentué :
  # « An invalid XML character (Unicode: 0x89) », rendu au client en HTTP 500
  # « Failed to persist config.xml » — un message qui ne dit rien de la cause.
  # Nos descriptions de jobs sont en français : le premier « FUSIONNÉE » suffit.
  # Mesuré le 2026-08-04 : même la config RELUE de Jenkins, renvoyée telle
  # quelle, échouait — ce qui a permis d'écarter le contenu et de désigner
  # l'en-tête.
  if [ "$EXISTS" = "200" ]; then
    HC=$(jcurl -s -b "$CK" -X POST "$JENKINS_UI/job/$J/config.xml" \
         -H "$F: $C" -H "Content-Type: application/xml; charset=utf-8" \
         --data-binary @"$X" -o /dev/null -w '%{http_code}')
    if [ "$HC" = "200" ]; then
      ok "configuration mise à jour en place (HTTP $HC) — historique conservé"
    elif [ "$ALLOW_RECREATE" = "true" ]; then
      warn "mise à jour refusée (HTTP $HC) — repli delete+create DEMANDÉ, l'historique sera PERDU"
      jcurl -s -b "$CK" -X POST "$JENKINS_UI/job/$J/doDelete" -H "$F: $C" -o /dev/null
      HC=$(jcurl -s -b "$CK" -X POST "$JENKINS_UI/createItem?name=$J" \
           -H "$F: $C" -H "Content-Type: application/xml; charset=utf-8" --data-binary @"$X" -o /dev/null -w '%{http_code}')
      [ "$HC" = "200" ] && ok "job recréé (HTTP $HC)" || { warn "recréation échouée (HTTP $HC)"; RC=1; }
    else
      warn "mise à jour refusée (HTTP $HC). Le job est INCHANGÉ."
      warn "  Relancer avec ALLOW_RECREATE=true pour delete+create — DÉTRUIT l'historique de builds."
      RC=1
    fi
  elif [ "$EXISTS" = "404" ]; then
    HC=$(jcurl -s -b "$CK" -X POST "$JENKINS_UI/createItem?name=$J" \
         -H "$F: $C" -H "Content-Type: application/xml; charset=utf-8" --data-binary @"$X" -o /dev/null -w '%{http_code}')
    [ "$HC" = "200" ] && ok "job créé (HTTP $HC)" || { warn "création échouée (HTTP $HC)"; RC=1; }
  else
    warn "état du job indéterminé (HTTP $EXISTS) — ni mis à jour ni créé"
    RC=1
  fi
done

echo
if [ "$RC" = "0" ]; then
  echo "OK — les jobs demandés sont alignés sur le dépôt."
  echo "Rappel : ces jobs CLONENT ci/stoa-labs sur Gitea. Les scripts qu'ils"
  echo "appellent doivent y être poussés (git push gitea main), sans quoi la"
  echo "config à jour exécuterait du code périmé."
else
  echo "TERMINÉ AVEC DES ÉCARTS — voir ci-dessus." >&2
fi
exit "$RC"
