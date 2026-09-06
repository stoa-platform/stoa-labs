#!/usr/bin/env bash
# scripts/lib/wm-dataplane.sh — appeler le PLAN DE DONNÉES d'une API webMethods
# depuis un harnais, quel que soit le protocole qu'elle accepte.
#
# POURQUOI CETTE LIB EXISTE (jalon P5, ADR-095). Depuis P5, une API dont la
# posture est gouvernée refuse l'appel en clair : son `entryProtocolPolicy` vaut
# `https`, et le port en clair lui répond HTTP 500 « Transport protocol not
# supported ». Les harnais qui mesuraient le plan de données en HTTP — celui de
# P4 mesure un quota par rafale — cessaient donc de mesurer ce qu'ils croyaient
# mesurer : ils lisaient le refus de PROTOCOLE là où ils attendaient un 429 ou
# un 200. C'est le vert (et le rouge) vacant que ce GOAL traque depuis P0, et la
# réponse est de mesurer sur le canal que l'API accepte réellement.
#
# LE DÉTOUR PAR LE CONTENEUR N'EST PAS UN CONFORT. Le listener HTTPS du lab
# (:5543) n'est PAS publié sur l'hôte ; seul :5555 l'est. Un appel HTTPS depuis
# la machine de développement ne peut donc pas aboutir, et `docker exec … curl`
# est le seul chemin. Chez un client, `WM_DP_TLS_BASE` pointera un endpoint
# joignable et `WM_DP_CONTAINER` restera vide.
#
# AUCUNE ADRESSE PAR DÉFAUT ICI, et ce n'est pas un oubli. Cette lib est du code
# partagé : y écrire `http://localhost:5555` en défaut ferait qu'un appelant mal
# configuré mesurerait SILENCIEUSEMENT une autre gateway que la sienne — et sur
# un plan de données, « silencieusement » veut dire « en concluant faux ». Les
# deux bases sont donc REQUISES, et l'appelant qui les oublie est refusé en le
# lisant (porte ci/lint-config-knobs.sh : pas de défaut de SITE dans du code
# livrable ; les harnais `scripts/test-*.sh`, eux, portent légitimement les
# valeurs du lab).
#
# Réglages :
#   WM_DATA          base du plan de données en CLAIR — REQUISE
#   WM_DP_TLS_BASE   base du plan de données en TLS   — REQUISE
#   WM_DP_CONTAINER  conteneur d'où émettre l'appel TLS ; vide = depuis l'hôte
#
#   WM_DATA=… WM_DP_TLS_BASE=… . scripts/lib/wm-dataplane.sh
#   dp_code https "$API" 1.0.0 /ping     # -> 200
#   dp_code clair  "$API" 1.0.0 /ping    # -> 500 (API https-only)
#   dp_body clair  "$API" 1.0.0 /ping    # -> le corps du refus

WM_DATA="${WM_DATA:-}"
WM_DP_TLS_BASE="${WM_DP_TLS_BASE:-}"
WM_DP_CONTAINER="${WM_DP_CONTAINER:-}"

# _dp_base <clair|https> — la base à joindre, ou un refus NOMMÉ sur stderr.
_dp_base() {
  case "$1" in
    https) [ -n "$WM_DP_TLS_BASE" ] || { echo "DATAPLANE_TLS_NON_CONFIGURE : WM_DP_TLS_BASE requise pour un appel TLS." >&2; return 1; }
           printf '%s' "$WM_DP_TLS_BASE" ;;
    *)     [ -n "$WM_DATA" ] || { echo "DATAPLANE_CLAIR_NON_CONFIGURE : WM_DATA requise pour un appel en clair." >&2; return 1; }
           printf '%s' "$WM_DATA" ;;
  esac
}

# _dp_curl <base> <chemin> <mode>   mode = code | body
# En TLS via un conteneur : `docker exec`. Sinon : curl local. `-k` seulement
# sur le canal TLS (certificat auto-signé du lab) — jamais imposé ailleurs.
_dp_curl() {
  local base="$1" path="$2" mode="$3" out=()
  case "$mode" in
    code) out=(-o /dev/null -w '%{http_code}') ;;
    body) out=(-s) ;;
  esac
  if [ "${base#https}" != "$base" ] && [ -n "$WM_DP_CONTAINER" ]; then
    docker exec -i "$WM_DP_CONTAINER" curl -sk -m 10 "${out[@]}" "${base}${path}" 2>/dev/null
  else
    curl -sk -m 10 "${out[@]}" "${base}${path}" 2>/dev/null
  fi
}

# dp_code <clair|https> <api> <version> <chemin>  -> le code HTTP, "000" si muet
dp_code() {
  local base; base="$(_dp_base "$1")" || { printf '000'; return 1; }
  local c; c="$(_dp_curl "$base" "/$2/$3$4" code)"
  printf '%s' "${c:-000}"
}

# dp_body <clair|https> <api> <version> <chemin>  -> le corps de la réponse
dp_body() {
  local base; base="$(_dp_base "$1")" || return 1
  _dp_curl "$base" "/$2/$3$4" body
}

# dp_wait <clair|https> <api> <version> <chemin> [essais]
# Attend que le plan de données SERVE l'API. Une gateway qui vient de reprendre
# répond 200 sur /apis bien avant de dispatcher les APIs neuves : sans cette
# porte, un harnais rougit pour une raison qui n'est pas celle qu'il mesure.
dp_wait() {
  local n="${5:-40}"
  local _i
  for _i in $(seq 1 "$n"); do
    [ "$(dp_code "$1" "$2" "$3" "$4")" = "200" ] && return 0
    sleep 3
  done
  return 1
}

# dp_tls_reachable — le canal TLS est-il utilisable dans cet environnement ?
# Un harnais s'en sert pour SAUTER en le disant plutôt que de conclure faux.
dp_tls_reachable() {
  [ -z "$WM_DP_CONTAINER" ] || docker inspect "$WM_DP_CONTAINER" >/dev/null 2>&1
}
