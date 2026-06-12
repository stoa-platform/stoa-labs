#!/usr/bin/env bash
# wm-keepalive.sh — la licence du webMethods trial (softwareag/apigateway-trial:10.15)
# expire ~25 min puis l'Integration Server s'auto-éteint. Ce script recycle
# poc-webmethods-real PROACTIVEMENT avant l'expiry (uptime >= 23 min), ou le relance
# s'il est déjà unhealthy. La config (APIs/policies/strategy/scope/application/alias)
# vit dans l'ES EXTERNE (poc-wm-es, volume) -> un restart ne perd RIEN.
#
# Repris de l'ancien stoa (deploy/vps/webmethods/README.md "Trial keepalive" :
#   `*/25 * * * * /usr/local/bin/webmethods-keepalive.sh`). Ici on vérifie toutes les
#   5 min et on synchronise sur l'uptime RÉEL du conteneur (pas l'horloge murale),
#   ce qui garantit qu'on recycle toujours avant l'expiry quel que soit le déphasage.
#
# Install (cron utilisateur) :
#   */5 * * * * /Users/torpedo/hlfh-repos/stoa-labs/poc-control-plane-federation/scripts/wm-keepalive.sh
# Pause (ex. pendant un provisioning long) :  touch /tmp/wm-keepalive.pause
# Reprise :                                    rm -f /tmp/wm-keepalive.pause
# Journal :                                    /tmp/wm-keepalive.log
set -uo pipefail

DOCKER="${WM_DOCKER:-/opt/homebrew/bin/docker}"
C="${WM_CONTAINER:-poc-webmethods-real}"
LOG="${WM_KEEPALIVE_LOG:-/tmp/wm-keepalive.log}"
MAX_MIN="${WM_MAX_MIN:-23}"          # recycle dès que l'uptime atteint ce seuil (avant l'expiry ~25 min)
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

if [ -f /tmp/wm-keepalive.pause ]; then echo "$(ts) paused (flag présent)" >>"$LOG"; exit 0; fi

exists=$("$DOCKER" ps -a --filter "name=^/${C}$" --format '{{.Names}}' 2>/dev/null || true)
if [ -z "$exists" ]; then echo "$(ts) conteneur $C absent, skip" >>"$LOG"; exit 0; fi

health=$("$DOCKER" inspect "$C" --format '{{.State.Health.Status}}' 2>/dev/null || echo unknown)
st=$("$DOCKER" inspect "$C" --format '{{.State.StartedAt}}' 2>/dev/null || echo ''); st="${st%.*}"
epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$st" +%s 2>/dev/null || echo 0)
up_min=$(( ( $(date +%s) - epoch ) / 60 ))

# Ne pas perturber un conteneur en plein boot.
if [ "$health" = "starting" ]; then echo "$(ts) boot en cours (up=${up_min}m), skip" >>"$LOG"; exit 0; fi

if [ "$health" = "unhealthy" ] || [ "$up_min" -ge "$MAX_MIN" ]; then
  echo "$(ts) RECYCLE (health=$health up=${up_min}m)" >>"$LOG"
  "$DOCKER" restart "$C" >>"$LOG" 2>&1 && echo "$(ts) restart OK" >>"$LOG" || echo "$(ts) restart ÉCHEC" >>"$LOG"
else
  echo "$(ts) ok (health=$health up=${up_min}m)" >>"$LOG"
fi
