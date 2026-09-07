#!/usr/bin/env bash
# scripts/lib/apim-base.sh — LA composition de la base d'admin webMethods.
#
# POURQUOI CETTE LIB (2026-09-07). La composition vivait dans
# selfservice-palier-gate.sh, monolithique (refus() fait exit 1, trap EXIT) :
# inextractible pour un autre appelant. Le scan de parc en a besoin. Même
# réflexe que scripts/lib/vault-kv.sh, créée pour la même raison.
#
# À SOURCER. apim_base_resolve pose APIM_BASE, APIM_EFFECTIVE_VIA, APIM_AUTH_MODE.
#
# ENTRÉES (aucun défaut de SITE — lint-config-knobs.sh les refuse) :
#   ENVIRONMENT         le palier visé
#   APIM_TERMINUS       le nom du terminus (l'appelant le résout ; la lib ne
#                       lit pas la chaîne d'environnements elle-même — elle n'en dépend pas)
#   ADMIN_VIA           direct | proxy-oauth2 — SANS DÉFAUT (VIA_INCONNU sinon)
#   APIM_API_BASE       base directe, gabarit avec __ENV__
#   APIM_TERMINUS_BASE  base directe du terminus
#   APIM_PROXY_BASE     override complet du proxy (gagne sur les 4 morceaux)
#   APIM_PROXY_{HOST,API,VER,PATH}  les quatre morceaux
_ab_refus(){ echo "REFUS: $1 : $2" >&2; return 1; }
_ab_sub_env(){ printf '%s' "$1" | sed "s/__ENV__/${ENVIRONMENT}/g"; }

apim_base_resolve(){
  local envn="${ENVIRONMENT:-}" via="${ADMIN_VIA:-}" term="${APIM_TERMINUS:-}"
  [ -n "$envn" ] || { _ab_refus ENV_REQUIS "ENVIRONMENT n'est pas posé"; return 1; }
  case "$via" in direct|proxy-oauth2) ;; *)
    _ab_refus VIA_INCONNU "'${via}' — attendu direct ou proxy-oauth2 (aucun repli : un ADMIN_VIA vide basculait autrefois du proxy vers le Basic direct, sans un mot)"; return 1;; esac

  if [ -n "$term" ] && [ "$envn" = "$term" ]; then
    [ -n "${APIM_TERMINUS_BASE:-}" ] || {
      _ab_refus TERMINUS_SANS_VOIE "le palier terminus '${envn}' n'a pas d'APIM_TERMINUS_BASE"; return 1; }
    APIM_EFFECTIVE_VIA=direct; APIM_BASE="$(_ab_sub_env "$APIM_TERMINUS_BASE")"
  elif [ "$via" = direct ]; then
    APIM_EFFECTIVE_VIA=direct; APIM_BASE="$(_ab_sub_env "${APIM_API_BASE:-}")"
  else
    APIM_EFFECTIVE_VIA=proxy-oauth2
    if [ -n "${APIM_PROXY_BASE:-}" ]; then
      APIM_BASE="$(_ab_sub_env "$APIM_PROXY_BASE")"
    else
      # Un composant VIDE produit une URL syntaxiquement valide (« …/gateway//1.0/… »)
      # que le contrôle de forme laisserait passer : on les teste UN PAR UN.
      local c
      for c in APIM_PROXY_HOST:"${APIM_PROXY_HOST:-}" APIM_PROXY_API:"${APIM_PROXY_API:-}" \
               APIM_PROXY_VER:"${APIM_PROXY_VER:-}" APIM_PROXY_PATH:"${APIM_PROXY_PATH:-}"; do
        [ -n "${c#*:}" ] || { _ab_refus APIM_BASE_INVALIDE "${c%%:*} est vide — le gabarit d'URL admin ne peut pas être composé (poser la variable, ou fournir APIM_PROXY_BASE)"; return 1; }
      done
      APIM_BASE="$(_ab_sub_env "${APIM_PROXY_HOST}/gateway/${APIM_PROXY_API}/${APIM_PROXY_VER}${APIM_PROXY_PATH}")"
    fi
  fi

  case "$APIM_BASE" in http://*|https://*) ;; *)
    _ab_refus APIM_BASE_INVALIDE "'${APIM_BASE}' — le gabarit d'URL admin doit produire une URL http(s)"; return 1;; esac
  APIM_BASE="${APIM_BASE%/}"
  if [ "$APIM_EFFECTIVE_VIA" = direct ]; then APIM_AUTH_MODE=basic; else APIM_AUTH_MODE=oauth2; fi
  export APIM_BASE APIM_EFFECTIVE_VIA APIM_AUTH_MODE
}
