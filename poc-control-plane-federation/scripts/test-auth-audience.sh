#!/usr/bin/env bash
# test-auth-audience.sh — preuve X/X : l'audience de la stratégie OAuth2 est
# OBLIGATOIRE en mode idp et OPTIONNELLE en mode internal (AS local).
#
# CE QU'ON CORRIGE. L'assert d'audience n'avait pas de `when:` : il s'appliquait
# aux deux modes, alors qu'en internal l'AS est la gateway elle-même et qu'il n'y
# a aucune audience d'API à recopier. Le rôle bloquait donc l'apply sur une
# valeur sans référent — et sur un champ que ce runtime n'oppose même pas
# (EVIDENCE.md §Preuve 5 bis : JWKS offline ne vérifie jamais `aud`).
#
# HORS LIGNE : joué contre le mock webMethods (binaire Go du dépôt), sans
# gateway, sans Vault (VAULT_ADDR délibérément vidé -> fallback PoC), sans secret.
#
#   ./scripts/test-auth-audience.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/authaud.XXXXXX)"
PORT="${MOCK_PORT:-18555}"
MOCK_PID=""
cleanup(){ [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

command -v ansible-playbook >/dev/null || { echo "ansible-playbook absent"; exit 2; }
command -v go >/dev/null || { echo "go absent (nécessaire pour bâtir le mock)"; exit 2; }

echo "== mock webMethods (surface admin 10.15) =="
(cd "$REPO/mocks/webmethods" && go build -o "$TMP/wm-mock" .) || { echo "build du mock échoué"; exit 2; }
LISTEN_ADDR=":$PORT" "$TMP/wm-mock" >"$TMP/mock.log" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 50); do
  curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 0.2
done
curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 \
  || { echo "mock injoignable sur :$PORT"; sed -n '1,20p' "$TMP/mock.log"; exit 2; }
echo "  mock en écoute sur :$PORT (pid $MOCK_PID)"

BASE="http://127.0.0.1:$PORT/rest/apigateway"

mkmanifest(){ # $1=sortie  $2=name  $3=mode  $4=audience  $5=claim_value(idp)
cat > "$1" <<EOF
apim_ss_app:
  name: "$2"
  api: "probe"
  api_version: "1.0.0"
  description: "sonde audience"
  contact_emails: []
  team: "banking-demo"
  enforce: []
  backend: { header: "", value_template: "" }
  public_cert_ref: ""
  auth:
    mode: "$3"
    server_alias: "local"
    audience: "$4"
    claim: { name: "azp", value: "$5" }
    vault_sub: "deploy/banking-demo/apps/$2/mono/oauth-client"
EOF
}

probe(){ # $1=manifeste ; extra-vars additionnelles en $2...
  local m="$1"; shift
  OUT="$(cd "$REPO" && VAULT_ADDR="" ansible-playbook -i localhost, ansible/test-auth-audience.yml \
        -e "apim_ss_manifest=$m" -e "apim_ss_api_base=$BASE" "$@" 2>&1)"
  RC=$?
}

echo
echo "== 1. internal SANS audience : doit CONVERGER (le correctif) =="
mkmanifest "$TMP/m-int-noaud.yml" "probe-int-noaud" "internal" "" ""
probe "$TMP/m-int-noaud.yml" -e apim_ss_internal_client_id=cid-1 -e apim_ss_internal_client_secret=sec-1
[ $RC -eq 0 ] && ok "apply vert sans audience" || ko "bloqué sans audience (rc=$RC) — correctif absent"
grep -q "AUDIENCE_OMISE" <<<"$OUT" && ok "omission annoncée (jamais silencieuse)" || ko "omission non tracée"

echo
echo "== 2. …et la clé audience est ABSENTE de l'objet stocké (pas envoyée à \"\") =="
grep -q "audience_present=False" <<<"$OUT" \
  && ok "clé absente du corps stocké" || ko "audience posée alors qu'elle est vide"

echo
echo "== 3. internal AVEC audience : la valeur est bien transmise =="
mkmanifest "$TMP/m-int-aud.yml" "probe-int-aud" "internal" "probe-api" ""
probe "$TMP/m-int-aud.yml" -e apim_ss_internal_client_id=cid-2 -e apim_ss_internal_client_secret=sec-2
[ $RC -eq 0 ] && ok "apply vert" || ko "échec inattendu (rc=$RC)"
grep -q "audience_present=True" <<<"$OUT" && grep -q "audience_value='probe-api'" <<<"$OUT" \
  && ok "audience transmise telle quelle" || ko "audience perdue ou altérée"

echo
echo "== 4. NON-RÉGRESSION idp SANS audience : doit être REFUSÉ =="
mkmanifest "$TMP/m-idp-noaud.yml" "probe-idp-noaud" "idp" "" "probe-consumer"
probe "$TMP/m-idp-noaud.yml"
[ $RC -ne 0 ] && ok "refusé (fail-closed conservé)" || ko "idp sans audience accepté — garde perdue"
grep -q "AUDIENCE_MANQUANTE" <<<"$OUT" && ok "AUDIENCE_MANQUANTE" || ko "code d'erreur absent"

echo
echo "== 5. NON-RÉGRESSION idp AVEC audience : inchangé =="
mkmanifest "$TMP/m-idp-aud.yml" "probe-idp-aud" "idp" "probe-api" "probe-consumer"
probe "$TMP/m-idp-aud.yml"
[ $RC -eq 0 ] && grep -q "audience_present=True" <<<"$OUT" \
  && ok "idp complet : stratégie posée avec son audience" || ko "régression sur le chemin idp (rc=$RC)"

echo
echo "== 6. IDEMPOTENCE : rejouer le MÊME manifeste ne doit pas échouer =="
# GET /strategies rend un TABLEAU NU sur 10.15 ; le rôle ne lisait que
# l'enveloppe, donc ne retrouvait JAMAIS la stratégie et re-POSTait un nom déjà
# pris. Mesuré : le 2e apply échouait. Cf. tasks/strategies-list.yml.
probe "$TMP/m-int-aud.yml" -e apim_ss_internal_client_id=cid-2 -e apim_ss_internal_client_secret=sec-2
[ $RC -eq 0 ] && ok "2e apply vert (stratégie retrouvée, pas re-créée)" || ko "2e apply en échec (rc=$RC) — non idempotent"
grep -qE "STRATEGIES_LUES : [1-9]" <<<"$OUT" \
  && ok "la liste lue n'est plus vide" || ko "la gateway porte des stratégies mais le rôle en lit 0"
grep -q "STRATEGIES_LUES.*forme nue" <<<"$OUT" \
  && ok "forme NUE reconnue (celle de la 10.15)" || ko "forme non identifiée"

echo
echo "== 7. CONVERGE : changer l'audience et la voir RÉELLEMENT réappliquée =="
# Le PUT de convergence exige un id non vide : tant que la stratégie n'était
# jamais retrouvée, ce PUT était du CODE MORT et l'audience gardait sa 1re valeur.
mkmanifest "$TMP/m-int-aud2.yml" "probe-int-aud" "internal" "probe-api-v2" ""
probe "$TMP/m-int-aud2.yml" -e apim_ss_internal_client_id=cid-2 -e apim_ss_internal_client_secret=sec-2
[ $RC -eq 0 ] && ok "apply vert" || ko "échec (rc=$RC)"
grep -q "audience_value='probe-api-v2'" <<<"$OUT" \
  && ok "nouvelle audience réappliquée (PUT vivant)" || ko "audience figée à sa 1re valeur — PUT toujours mort"

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || { echo "--- dernière sortie ansible ---"; echo "$OUT"; exit 1; }
