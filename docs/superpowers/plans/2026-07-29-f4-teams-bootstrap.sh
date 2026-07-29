#!/bin/bash
# F4 T1 — bootstrap des 2 teams de démonstration sur la gateway cluster.
# Shapes CONSTATÉS live le 2026-07-29 (spike T1, gateway 10.15.0.0.95, ns wm) :
#   - user  : POST /users  {loginId, firstName, lastName, password, active, type:"local"}
#             (id du user = loginId dans les réponses)
#   - group : POST /groups {name, description, type:"local", userIds:[<loginId>]}
#   - team  : POST /accessProfiles {name, description, privilege:"<bitmask>", groupIds:[<group>]}
#             privilege est un BITMASK (pas une liste de noms !) — copié de la
#             team système API-Gateway-Providers ("111100101101100000001").
#   - activation Teams : PUT /configurations/extended {"enableTeamWork":"true"}
#             (configId réel = "extended", PAS "extendedSettings")
# Idempotent : chaque POST re-joué rend 4xx "existe" sans casser l'existant.
# Exécuté sur worker-1 (root). Mots de passe : /root/f4-teams.env (0600), jamais affichés.
set -eu
umask 077
K="k3s kubectl -n ci exec deploy/jenkins --"
B=http://wm-apigateway.wm.svc:5555/rest/apigateway
A='Administrator:manage'
H='Accept: application/json'
J='Content-Type: application/json'
PRIV='111100101101100000001'   # bitmask de la team système API-Gateway-Providers
ENV=/root/f4-teams.env
touch "$ENV"; chmod 600 "$ENV"
# Activation Teams (idempotent) — constat live : configId "extended",
# valeur chaîne "true" ; PUT 200, relecture enableTeamWork=true.
$K curl -s -u "$A" -H "$H" -H "$J" -X PUT -d '{"enableTeamWork":"true"}' \
  "$B/configurations/extended" -o /dev/null -w "enableTeamWork: %{http_code}\n"
for T in banking-demo insurance-demo; do
  U="svc-$T"; G="$T-devs"; V="P_${T//-/_}"
  if ! grep -q "^$V=" "$ENV"; then
    echo "$V=$(openssl rand -hex 12)" >> "$ENV"
  fi
  P=$(grep "^$V=" "$ENV" | cut -d= -f2)
  $K curl -s -u "$A" -H "$H" -H "$J" -X POST \
    -d "{\"loginId\":\"$U\",\"firstName\":\"svc\",\"lastName\":\"$T\",\"password\":\"$P\",\"active\":true,\"type\":\"local\"}" \
    "$B/users" -o /dev/null -w "user $U: %{http_code}\n"
  $K curl -s -u "$A" -H "$H" -H "$J" -X POST \
    -d "{\"name\":\"$G\",\"description\":\"devs $T (F4)\",\"type\":\"local\",\"userIds\":[\"$U\"]}" \
    "$B/groups" -o /dev/null -w "group $G: %{http_code}\n"
  $K curl -s -u "$A" -H "$H" -H "$J" -X POST \
    -d "{\"name\":\"$T\",\"description\":\"team $T (F4)\",\"privilege\":\"$PRIV\",\"groupIds\":[\"$G\"]}" \
    "$B/accessProfiles" -o /dev/null -w "accessProfile $T: %{http_code}\n"
done
echo "== relecture accessProfiles (ids) =="
$K curl -s -u "$A" -H "$H" "$B/accessProfiles" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for p in d.get("accessProfiles",[]):
    print(p["name"], "->", p["id"])
' 2>/dev/null || $K curl -s -u "$A" -H "$H" "$B/accessProfiles"
