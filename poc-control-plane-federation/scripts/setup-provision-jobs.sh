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

# Authentification : optionnelle (lab ouvert), indispensable sur une instance
# réelle.
#
# LE TOKEN NE PASSE PAS PAR argv. Un `curl -u user:token` le rend visible à tout
# le monde sur la machine (`ps auxww`) le temps de l'appel — sur un agent Jenkins
# partagé, ce n'est pas théorique. On le passe donc par l'ENTRÉE STANDARD via
# `curl -K -`, qui lit sa configuration sans jamais l'exposer.
#
# (Un tableau `AUTH=()` développé en `"${AUTH[@]}"` était le premier réflexe : il
# échoue sous `set -u` en bash 3.2 — celui de macOS — quand le tableau est vide,
# et le script rendait « Jenkins injoignable » sur une instance parfaitement
# joignable. Mesuré le 2026-08-03.)
jcurl(){
  if [ -n "$JENKINS_USER" ]; then
    printf 'user = "%s:%s"\n' "$JENKINS_USER" "$JENKINS_TOKEN" | curl -K - "$@"
  else
    curl "$@"
  fi
}
if [ -n "$JENKINS_USER" ]; then
  echo "Authentification : ${JENKINS_USER} (token masqué, hors argv)"
else
  echo "Authentification : AUCUNE (instance ouverte présumée)"
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
CK=$(mktemp); trap 'rm -f "$CK"' EXIT
CJ=$(jcurl -sf -c "$CK" "$JENKINS_UI/crumbIssuer/api/json") \
  || ko "Jenkins injoignable ou identifiants refusés ($JENKINS_UI)"
F=$(printf '%s' "$CJ" | python3 -c 'import sys,json;print(json.load(sys.stdin)["crumbRequestField"])') \
  || ko "réponse crumbIssuer inattendue"
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

  if [ "$EXISTS" = "200" ]; then
    HC=$(jcurl -s -b "$CK" -X POST "$JENKINS_UI/job/$J/config.xml" \
         -H "$F: $C" -H "Content-Type: application/xml" \
         --data-binary @"$X" -o /dev/null -w '%{http_code}')
    if [ "$HC" = "200" ]; then
      ok "configuration mise à jour en place (HTTP $HC) — historique conservé"
    elif [ "$ALLOW_RECREATE" = "true" ]; then
      warn "mise à jour refusée (HTTP $HC) — repli delete+create DEMANDÉ, l'historique sera PERDU"
      jcurl -s -b "$CK" -X POST "$JENKINS_UI/job/$J/doDelete" -H "$F: $C" -o /dev/null
      HC=$(jcurl -s -b "$CK" -X POST "$JENKINS_UI/createItem?name=$J" \
           -H "$F: $C" -H "Content-Type: application/xml" --data-binary @"$X" -o /dev/null -w '%{http_code}')
      [ "$HC" = "200" ] && ok "job recréé (HTTP $HC)" || { warn "recréation échouée (HTTP $HC)"; RC=1; }
    else
      warn "mise à jour refusée (HTTP $HC). Le job est INCHANGÉ."
      warn "  Relancer avec ALLOW_RECREATE=true pour delete+create — DÉTRUIT l'historique de builds."
      RC=1
    fi
  elif [ "$EXISTS" = "404" ]; then
    HC=$(jcurl -s -b "$CK" -X POST "$JENKINS_UI/createItem?name=$J" \
         -H "$F: $C" -H "Content-Type: application/xml" --data-binary @"$X" -o /dev/null -w '%{http_code}')
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
