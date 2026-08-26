#!/usr/bin/env bash
# setup-release-team.sh — pose le groupe Keycloak `release-team` du realm
# stoa-lab et y met ses membres (jalon G1, chaîne à 5 paliers).
#
# POURQUOI CE GROUPE : `approverGroup` des portes `homol` et `prod`
# (clients/_example/environments.yaml) est comparé à la claim `groups` du jeton
# Keycloak VÉRIFIÉ. Sans le groupe, la porte ne matche jamais : le saut devient
# impossible à approuver — fail-closed, mais pour la mauvaise raison.
#
# ⚠ NE PAS CONFONDRE avec `apim-operator-<env>`, qui est un groupe LDAP mappé
# sur une policy Vault (setup-vault-ldap.sh) et gouverne l'accès aux SECRETS.
# Deux axes distincts, deux annuaires distincts.
#
# Idempotent : le groupe est créé s'il manque (409 = déjà là, non fatal), et
# l'ajout d'un membre est un PUT (rejouable sans effet de bord).
#
# Usage :  bash scripts/setup-release-team.sh
# Prérequis : poc-keycloak up, ../.stoa-labs.env lisible (admin du realm master).
set -uo pipefail

ENVF="${ENVF:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.stoa-labs.env}"
KC="${KC:-http://localhost:8480}"
REALM="${REALM:-stoa-lab}"
GROUP="${GROUP:-release-team}"
# Les membres du lab : carol et dave portent l'équipe qui approuve homol ET
# prod. alice est la DEMANDEUSE (elle ne doit surtout pas y être : les quatre
# yeux de la porte prod la refuseraient de toute façon, mais l'intention doit
# être lisible dans l'annuaire, pas seulement dans la porte).
MEMBERS="${MEMBERS:-carol@bc.example dave@bc.example}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

[ -r "$ENVF" ] || { echo "ENVF illisible : $ENVF"; exit 1; }
KA=$(grep -oE 'export KEYCLOAK_ADMIN=.*' "$ENVF" | sed 's/.*=//' | tr -d "\"'")
KP=$(grep -oE 'export KEYCLOAK_ADMIN_PASSWORD=.*' "$ENVF" | sed 's/.*=//' | tr -d "\"'")

# Le mot de passe admin ne transite ni par argv ni par le log (--data via stdin).
T=$(printf 'client_id=admin-cli&grant_type=password&username=%s&password=%s' "$KA" "$KP" \
    | curl -s -X POST "$KC/realms/master/protocol/openid-connect/token" --data-binary @- \
    | python3 -c "import json,sys
try: print(json.load(sys.stdin)['access_token'])
except Exception: pass")
[ -n "$T" ] || { echo "login admin Keycloak KO"; exit 1; }
A=(-s -H "Authorization: Bearer $T" -H "Content-Type: application/json")
R="$KC/admin/realms/$REALM"

echo "① groupe $GROUP"
RC=$(curl "${A[@]}" -o /dev/null -w '%{http_code}' -X POST "$R/groups" -d "{\"name\":\"$GROUP\"}")
case "$RC" in
  201|409) ok "groupe $GROUP présent (HTTP $RC — 409 = déjà là)" ;;
  *)       bad "création du groupe $GROUP KO (HTTP $RC)" ;;
esac

GID=$(curl "${A[@]}" "$R/groups" | python3 -c "import json,sys
g=[x['id'] for x in json.load(sys.stdin) if x['name']=='$GROUP']
print(g[0] if g else '')")
[ -n "$GID" ] || { bad "groupe $GROUP introuvable après création — arrêt"; printf '\n%d PASS / %d FAIL\n' "$PASS" "$FAIL"; exit 1; }

echo "② membres"
for U in $MEMBERS; do
  UID_=$(curl "${A[@]}" "$R/users?username=$U&exact=true" | python3 -c "import json,sys
d=json.load(sys.stdin); print(d[0]['id'] if d else '')")
  if [ -z "$UID_" ]; then bad "$U introuvable dans le realm $REALM"; continue; fi
  RC=$(curl "${A[@]}" -o /dev/null -w '%{http_code}' -X PUT "$R/users/$UID_/groups/$GID")
  case "$RC" in 204) ok "$U -> $GROUP" ;; *) bad "$U -> $GROUP KO (HTTP $RC)" ;; esac
done

# READ-BACK fail-closed : on ne croit pas les codes de retour, on relit.
echo "③ relecture (read-back)"
GOT=$(curl "${A[@]}" "$R/groups/$GID/members" | python3 -c "import json,sys
print(' '.join(sorted(u['username'] for u in json.load(sys.stdin))))")
echo "   membres lus : ${GOT:-<aucun>}"
for U in $MEMBERS; do
  case " $GOT " in *" $U "*) ok "read-back : $U est bien membre" ;;
                   *) bad "read-back : $U ABSENT du groupe" ;; esac
done
# Contre-épreuve d'intention : la demandeuse ne doit PAS être dans l'équipe qui
# approuve. Un annuaire qui la contient rend la porte trompeuse.
case " $GOT " in *" alice@bc.example "*) bad "alice (demandeuse) est membre de $GROUP — à retirer" ;;
                 *) ok "alice (demandeuse) n'est PAS dans $GROUP" ;; esac

printf '\n%d PASS / %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
