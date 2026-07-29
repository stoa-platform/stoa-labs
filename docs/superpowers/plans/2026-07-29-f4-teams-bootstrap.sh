#!/bin/bash
# F4 T1 — bootstrap des 2 teams de démonstration sur la gateway cluster.
# Shapes CONSTATÉS live le 2026-07-29 (spike T1, gateway 10.15.0.0.95, ns wm) —
# TOUS appris en se cognant aux échecs silencieux du produit :
#   - activation Teams : PUT /configurations/extended {"enableTeamWork":"true"}
#     (configId réel = "extended", PAS "extendedSettings") ; porté par ES,
#     survit au cycle trial */20 (mesuré).
#   - user  : POST /users {loginId, firstName, lastName, password, active,
#     type:"local"} → l'objet créé reçoit un id UUID (≠ loginId).
#   - group : POST /groups {name, description, type:"local"} → id UUID.
#     ⚠ userIds attend des UUID DE USERS ; les loginIds sont IGNORÉS EN
#     SILENCE (200, liste vide). PUT /groups/{UUID} avec les UUID.
#   - team = accessProfile : POST /accessProfiles {name, description,
#     privilege:"<bitmask>", groupIds:[<UUID de groupe>]}.
#     privilege est un BITMASK (copié de API-Gateway-Providers) ; groupIds
#     par nom = référence morte silencieuse pour les groupes custom.
#   - accès à l'admin REST : les users doivent AUSSI être membres du groupe
#     système API-Gateway-Providers (sinon 403 sur GET /apis).
#   - assignation : POST /assets/team {assetIds, assetType:"API", newTeams:
#     [<UUID accessProfile>]} — SANS assetType : 200 no-op silencieux ;
#     avec : message explicite + relecture teams[] (niveau apiResponse).
# Idempotent : tout se rejoue (create-or-update). Exécuté sur worker-1 (root).
# Mots de passe : /root/f4-teams.env (0600), jamais affichés.
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

# 0. Teams ON (idempotent)
$K curl -s -u "$A" -H "$H" -H "$J" -X PUT -d '{"enableTeamWork":"true"}' \
  "$B/configurations/extended" -o /dev/null -w "enableTeamWork: %{http_code}\n"

uid_of() { $K curl -s -u "$A" -H "$H" "$B/users" | python3 -c "
import json,sys
for u in json.load(sys.stdin)['users']:
    if u['loginId']=='$1': print(u['id'])"; }
gid_of() { $K curl -s -u "$A" -H "$H" "$B/groups" | python3 -c "
import json,sys
for g in json.load(sys.stdin)['groups']:
    if g['name']=='$1': print(g['id'])"; }
tid_of() { $K curl -s -u "$A" -H "$H" "$B/accessProfiles" | python3 -c "
import json,sys
for p in json.load(sys.stdin)['accessProfiles']:
    if p['name']=='$1': print(p['id'])"; }

for T in banking-demo insurance-demo; do
  U="svc-$T"; G="$T-devs"; V="P_${T//-/_}"
  grep -q "^$V=" "$ENV" || echo "$V=$(openssl rand -hex 12)" >> "$ENV"
  P=$(grep "^$V=" "$ENV" | cut -d= -f2)
  # user
  UID_=$(uid_of "$U")
  if [ -z "$UID_" ]; then
    $K curl -s -u "$A" -H "$H" -H "$J" -X POST \
      -d "{\"loginId\":\"$U\",\"firstName\":\"svc\",\"lastName\":\"$T\",\"password\":\"$P\",\"active\":true,\"type\":\"local\"}" \
      "$B/users" -o /dev/null -w "user $U: %{http_code}\n"
    UID_=$(uid_of "$U")
  fi
  # groupe (créé nu puis membre posé par PUT — les UUID seulement)
  GID=$(gid_of "$G")
  if [ -z "$GID" ]; then
    $K curl -s -u "$A" -H "$H" -H "$J" -X POST \
      -d "{\"name\":\"$G\",\"description\":\"devs $T (F4)\",\"type\":\"local\"}" \
      "$B/groups" -o /dev/null -w "group $G: %{http_code}\n"
    GID=$(gid_of "$G")
  fi
  $K curl -s -u "$A" -H "$H" -H "$J" -X PUT \
    -d "{\"id\":\"$GID\",\"name\":\"$G\",\"description\":\"devs $T (F4)\",\"type\":\"local\",\"userIds\":[\"$UID_\"]}" \
    "$B/groups/$GID" -o /dev/null -w "membres $G: %{http_code}\n"
  # team (accessProfile), groupIds en UUID
  TID=$(tid_of "$T")
  if [ -z "$TID" ]; then
    $K curl -s -u "$A" -H "$H" -H "$J" -X POST \
      -d "{\"name\":\"$T\",\"description\":\"team $T (F4)\",\"privilege\":\"$PRIV\",\"groupIds\":[\"$GID\"]}" \
      "$B/accessProfiles" -o /dev/null -w "accessProfile $T: %{http_code}\n"
  else
    $K curl -s -u "$A" -H "$H" -H "$J" -X PUT \
      -d "{\"id\":\"$TID\",\"name\":\"$T\",\"description\":\"team $T (F4)\",\"privilege\":\"$PRIV\",\"groupIds\":[\"$GID\"]}" \
      "$B/accessProfiles/$TID" -o /dev/null -w "accessProfile $T (maj): %{http_code}\n"
  fi
done

# accès admin REST : les 2 users membres du groupe système API-Gateway-Providers
UB=$(uid_of svc-banking-demo); UI=$(uid_of svc-insurance-demo)
$K curl -s -u "$A" -H "$H" -H "$J" -X PUT \
  -d "{\"id\":\"API-Gateway-Providers\",\"name\":\"API-Gateway-Providers\",\"description\":\"Users added to this group can perform similar API Gateway Providers tasks.\",\"type\":\"local\",\"systemDefined\":true,\"userIds\":[\"$UB\",\"$UI\"]}" \
  "$B/groups/API-Gateway-Providers" -o /dev/null -w "API-Gateway-Providers: %{http_code}\n"

echo "== etat final =="
$K curl -s -u "$A" -H "$H" "$B/accessProfiles" | python3 -c 'import json,sys
for p in json.load(sys.stdin)["accessProfiles"]: print(p["name"], "->", p["id"], p.get("groupIds"))'
$K curl -s -u "$A" -H "$H" "$B/groups" | python3 -c 'import json,sys
for g in json.load(sys.stdin)["groups"]: print(g["name"], "->", g["userIds"])'
