#!/usr/bin/env bash
# wm-loadcheck.sh — mesure le surcoût de la policy Log Invocation (ADR-073).
#
# Compare p50/p95 de latence data-plane AVEC puis SANS la global policy
# « Transaction logging » (désactivée le temps de la 2e salve, puis RESTAURÉE).
# Curl séquentiel, zéro dépendance : ordre de grandeur PoC, pas un bench —
# sur la cible, rejouer avec un injecteur réel (k6/vegeta) et la volumétrie
# bancaire. ⚠️ ne pas lancer pendant la fenêtre de recycle keepalive (~23 min).
#
#   N=200 ./scripts/wm-loadcheck.sh
set -uo pipefail
cd "$(dirname "$0")/.."

WM="${WM_DATAPLANE_URL:-http://localhost:5555}"
ADMIN_AUTH="${WM_ADMIN_AUTH:-Administrator:manage}"
KC="${KC_TOKEN_URL:-http://localhost:8480/realms/stoa-lab/protocol/openid-connect/token}"
N="${N:-200}"

get_cred() { awk -v sec="[keycloak]" -v k="$1" '$0==sec{f=1;next} f&&/^\[/{exit} f{p=index($0,"="); if(p){key=substr($0,1,p-1); gsub(/ /,"",key); if(key==k){v=substr($0,p+1); sub(/^ +/,"",v); print v; exit}}}' labctl-credentials.txt; }

policy() { # policy activate|deactivate
  curl -sf -u "$ADMIN_AUTH" -X PUT \
    "$WM/rest/apigateway/policies/GlobalLogInvocationPolicy/$1" \
    -H 'Accept: application/json' >/dev/null
}

salvo() { # salvo LIBELLÉ -> imprime p50/p95/err et renvoie "p50 p95"
  local label="$1" times=() errs=0 code t
  for _ in $(seq 1 "$N"); do
    IFS=' ' read -r code t < <(curl -s -o /dev/null -w '%{http_code} %{time_total}' \
      -H "Authorization: Bearer $TOK" "$WM/gateway/accounts-read/1.0.0/accounts")
    [[ "$code" == "200" ]] && times+=("$t") || errs=$((errs+1))
  done
  printf '%s\n' "${times[@]}" | sort -n | awk -v label="$label" -v n="${#times[@]}" -v errs="$errs" '
    { a[NR] = $1 }
    END {
      if (n == 0) { printf "  %-22s AUCUN 200 (%d erreurs)\n", label, errs; exit 1 }
      p50 = a[int(n*0.50)+ (n*0.50==int(n*0.50)?0:1)]; p95 = a[int(n*0.95)+ (n*0.95==int(n*0.95)?0:1)]
      printf "  %-22s n=%d  p50=%.1fms  p95=%.1fms  err=%d\n", label, n, p50*1000, p95*1000, errs
    }'
}

TOK=$(curl -s -d grant_type=client_credentials -d client_id="$(get_cred clientId)" \
  -d client_secret="$(get_cred clientSecret)" "$KC" | jq -r '.access_token // empty')
[[ -z "$TOK" ]] && { echo "✗ pas de token Keycloak"; exit 1; }

# Restaure la policy quoi qu'il arrive (Ctrl-C compris) — l'état nominal du
# PoC est ACTIVE (le pont en dépend).
trap 'policy activate || true' EXIT

echo "═══ Salve 1/2 : Log Invocation ACTIVE ($N appels)"
salvo "avec Log Invocation"

echo "═══ Salve 2/2 : Log Invocation DÉSACTIVÉE ($N appels)"
policy deactivate
sleep 3   # propagation de la (dé)activation
salvo "sans Log Invocation"

policy activate
trap - EXIT
echo "✓ policy « Transaction logging » réactivée (état nominal du pont)."
echo "  Lecture : delta p95 = coût de la policy par transaction sur CE poc"
echo "  (trial émulé amd64→arm64 : ordre de grandeur seulement)."
