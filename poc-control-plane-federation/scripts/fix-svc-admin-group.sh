#!/usr/bin/env bash
# fix-svc-admin-group.sh — ajoute les comptes de service tenant-scopés
# (svc-banking-demo, svc-payments-team) au groupe API-Gateway-Administrators.
#
# POURQUOI C'EST LE DESIGN, PAS UNE COMMODITÉ (team.yml, en-tête, mesuré
# 2026-07-31) : l'assignation de team (POST /assets/team) est une opération
# d'ADMIN — un utilisateur d'équipe se la voit refuser (« not authorized to
# perform: POST on the resource: assets »). La chaîne self-service tourne donc
# sous un compte de service ADMIN, tenant-scopé côté Vault : la ségrégation par
# tenant est portée par la policy Vault (qui ne donne à alice que
# deploy/banking-demo/*), PAS par les droits gateway du compte de service.
# Re-mesuré 2026-08-05 : build Jenkins #24 rouge exactement sur ce 401.
#
# Pièges (spike F4, wm-1015-teams-scoping) : userIds en UUID (les noms rendent
# 200 et sont IGNORÉS) ; le groupe système s'adresse par son NOM ; un 200 ne
# prouve rien — d'où la relecture fail-closed en sortie.
set -euo pipefail

# pipe_q — `grep -q` sous `set -o pipefail` INVERSE son verdict : il sort à la
# première correspondance, ferme le tuyau, l'écrivain prend un SIGPIPE et rend
# 141, donc le pipeline est non nul PRÉCISÉMENT quand le motif est présent. Le
# piège dépend de la taille du flux, donc il dort. `grep -c` a le MÊME statut de
# sortie (0 si ≥1 ligne, 1 sinon) et lit TOUTE son entrée : aucun SIGPIPE.
# shellcheck disable=SC2329  # MESURÉ : shellcheck 0.11.0 ne voit pas l'invocation
# en PIPELINE de cette fonction dans ces fichiers (0 signalement à HEAD, donc le
# défaut vient bien d'ici), alors qu'il l'accepte sur un script minimal. On perd
# ce signal — et on le REMPLACE : ci/lint-pipe-grepq.sh exige que tout fichier qui
# DÉFINIT pipe_q l'INVOQUE, ce que SC2329 prétend vérifier et fait ici à tort.
pipe_q() { grep -c "$@" >/dev/null; }
GW="${GW_ADMIN:-http://localhost:5555/rest/apigateway}"
AUTH="${WM_USER:-Administrator}:${WM_PASS:-manage}"
adm(){ curl -sS -u "$AUTH" -H "Accept: application/json" "$@"; }

uid(){ adm "$GW/users" | jq -r --arg l "$1" '.users[] | select(.loginId==$l) | .id'; }
U1="$(uid svc-banking-demo)";  [ -n "$U1" ] || { echo "svc-banking-demo absent"; exit 1; }
U2="$(uid svc-payments-team)"; [ -n "$U2" ] || { echo "svc-payments-team absent"; exit 1; }

# membres actuels préservés (write du record complet, pas d'écrasement)
CUR=$(adm "$GW/groups" | jq -r '.groups[] | select(.name=="API-Gateway-Administrators")')
jq -n --argjson g "$CUR" --arg u1 "$U1" --arg u2 "$U2" \
  '$g | .userIds = ((.userIds // []) + [$u1,$u2] | unique)' > /tmp/g-admin.json

RC=$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -H 'Content-Type: application/json' \
  -X PUT -d @/tmp/g-admin.json "$GW/groups/API-Gateway-Administrators")
echo "PUT groupe admin: HTTP $RC"

# porte de preuve : relecture — les deux UUID doivent être membres
AFTER=$(adm "$GW/groups" | jq -r '.groups[] | select(.name=="API-Gateway-Administrators") | .userIds[]')
echo "$AFTER" | pipe_q "$U1" && echo "  ✅ svc-banking-demo ∈ API-Gateway-Administrators" || { echo "  ❌ svc-banking-demo ABSENT (200 sans effet ?)"; exit 1; }
echo "$AFTER" | pipe_q "$U2" && echo "  ✅ svc-payments-team ∈ API-Gateway-Administrators" || { echo "  ❌ svc-payments-team ABSENT"; exit 1; }
rm -f /tmp/g-admin.json