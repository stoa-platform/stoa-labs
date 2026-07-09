#!/usr/bin/env bash
# test-user-vault-jwt.sh — preuve chaîne A (ADR-077) : l'IDENTITÉ UTILISATEUR
# va jusqu'à Vault, sans mot de passe stocké côté chaîne CI, et le job CI n'a
# AUCUN credential propre.
#
#   alice (humaine, Dex/Oracle) ─auth_code─▶ Keycloak ─exchange RFC 8693─▶
#   JWT court aud=vault + tenant ─webhook─▶ Jenkins stoa-user-deploy ─auth/jwt─▶
#   token Vault NOMINATIF scoped à SON tenant ─▶ lecture secret ─▶ revoke PROUVÉ.
#
# E2E CI : build SUCCESS, identité humaine dans le log, revoke vérifié
# (lookup-self 403), AUCUN jeton dans le log ; webhook sans jeton → build ROUGE.
# Contre-épreuves : token non échangé refusé (bound_audiences+azp), subject
# token de service non adressé refusé par KC, rôle realm insuffisant refusé
# par Vault (bound_claims), CROSS-TENANT refusé (policy templatée), audit
# Vault nominatif — y compris les refus — scopé à CE run.
#
# Prérequis : poc-keycloak (26.2+), poc-vault, poc-jenkins, poc-dex up ;
#   ./scripts/setup-user-vault-jwt.sh et ./scripts/setup-user-deploy-job.sh joués ;
#   users fédérés seedés (console-light/scripts/setup-identity.sh).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

KC="${KC_BASE:-http://localhost:8480}/realms/${REALM:-stoa-lab}"
VADDR="${VAULT_ADDR:-http://localhost:8200}"
JENKINS="${JENKINS:-http://localhost:18080}"
XCID="vault-exchange"; XSEC="vault-exchange-secret-poc"

PASS=0; FAIL=0
ok(){  printf '  \033[32m✓ %s\033[0m\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  \033[31m✗ %s\033[0m\n' "$1"; FAIL=$((FAIL+1)); }
jget(){ python3 -c "import sys,json;d=json.load(sys.stdin);print(d$1)" 2>/dev/null; }
claims(){ python3 -c "
import sys,base64,json
p=sys.stdin.read().strip().split('.')[1]; p+='='*(-len(p)%4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(p))))" 2>/dev/null; }
ERRLOG=$(mktemp); trap 'rm -f "$ERRLOG"' EXIT

# Offset de l'audit AVANT le run : CE4/CE4bis ne regardent que les lignes de CE run.
AUD0=$(docker exec poc-vault sh -c 'wc -l < /tmp/vault-audit.log 2>/dev/null || echo 0' | tr -d ' ')

exchange(){ # exchange SUBJECT_TOKEN -> stdout access_token ('' si refus)
  curl -s -X POST "$KC/protocol/openid-connect/token" \
    -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
    -d client_id="$XCID" -d client_secret="$XSEC" \
    -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
    -d audience=vault --data-urlencode "subject_token=$1" |
    jget '.get("access_token","")'
}
vlogin(){ # vlogin JWT -> stdout réponse JSON complète (JWT en corps, pas argv)
  printf '{"role":"user-deploy","jwt":"%s"}' "$1" |
    curl -s -X POST "$VADDR/v1/auth/jwt/login" --data-binary @-
}

echo "═══ 1. Chaîne nominale : alice → exchange → Vault (token nominatif, tenant-scopé) ═══"
TOK=$(DEX_USER="alice@bc.example" ./scripts/get-oracle-token.sh --quiet 2>"$ERRLOG")
[ -n "$TOK" ] && ok "login humain alice via Dex/broker (auth_code)" \
  || { bad "login alice KO"; sed 's/^/    /' "$ERRLOG" >&2; exit 1; }

C=$(printf '%s' "$TOK" | claims)
AUDC=$(printf '%s' "$C" | jget '["aud"]')
grep -q vault-exchange <<<"$AUDC" \
  && ok "subject token ADRESSÉ à l'échangeur (aud contient vault-exchange)" \
  || bad "aud du subject token: $AUDC"

EXJWT=$(exchange "$TOK")
[ -n "$EXJWT" ] && ok "token exchange standard (RFC 8693) accepté" || bad "exchange refusé"
EC=$(printf '%s' "$EXJWT" | claims)
[ "$(printf '%s' "$EC" | jget '["aud"]')" = "vault" ] \
  && ok "JWT échangé : aud=vault (inutilisable ailleurs)" || bad "aud=$(printf '%s' "$EC" | jget '["aud"]')"
[ "$(printf '%s' "$EC" | jget '["preferred_username"]')" = "alice@bc.example" ] \
  && ok "JWT échangé : sub/preferred_username = alice@bc.example (l'HUMAINE, pas un service account)" \
  || bad "preferred_username=$(printf '%s' "$EC" | jget '["preferred_username"]')"
[ "$(printf '%s' "$EC" | jget '["azp"]')" = "vault-exchange" ] \
  && ok "JWT échangé : azp=vault-exchange (la délégation est TRACÉE)" || bad "azp inattendu"
[ "$(printf '%s' "$EC" | jget '["tenant"]')" = "banking-demo" ] \
  && ok "JWT échangé : tenant=banking-demo (la ségrégation voyage avec l'identité)" \
  || bad "tenant=$(printf '%s' "$EC" | jget '["tenant"]')"

L=$(vlogin "$EXJWT")
VT=$(printf '%s' "$L" | jget '["auth"]["client_token"]')
[ -n "$VT" ] && ok "Vault auth/jwt/login accepté" || bad "login Vault refusé: $(printf '%s' "$L" | jget '["errors"]')"
[ "$(printf '%s' "$L" | jget '["auth"]["metadata"]["username"]')" = "alice@bc.example" ] \
  && ok "token Vault NOMINATIF (metadata.username=alice@bc.example)" || bad "entité non nominative"
grep -q user-deploy <<<"$(printf '%s' "$L" | jget '["auth"]["token_policies"]')" \
  && ok "policy user-deploy (templatée par tenant) attachée" || bad "policies: $(printf '%s' "$L" | jget '["auth"]["token_policies"]')"

HTTP=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Vault-Token: $VT" "$VADDR/v1/secret/data/stoa/deploy/banking-demo/demo")
[ "$HTTP" = 200 ] && ok "lecture du périmètre deploy de SON tenant → 200" || bad "read deploy/banking-demo → $HTTP"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Vault-Token: $VT" "$VADDR/v1/secret/data/stoa/deploy/payments-team/demo")
[ "$HTTP" = 403 ] && ok "CROSS-TENANT (deploy/payments-team) → 403 (ségrégation par tenant ENFORCÉE)" || bad "read cross-tenant → $HTTP (403 attendu)"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Vault-Token: $VT" "$VADDR/v1/secret/data/stoa/ci")
[ "$HTTP" = 403 ] && ok "hors périmètre deploy (secret/stoa/ci) → 403 (l'utilisateur ne devient PAS root)" || bad "read ci → $HTTP (403 attendu)"
curl -s -o /dev/null -X POST -H "X-Vault-Token: $VT" "$VADDR/v1/auth/token/revoke-self"

echo "═══ 2. E2E : webhook → job Jenkins sans credential propre ═══"
EXJWT2=$(exchange "$TOK")
N=$(curl -s "$JENKINS/job/stoa-user-deploy/api/json" | jget '["nextBuildNumber"]')
WH=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$JENKINS/generic-webhook-trigger/invoke?token=stoa-user-deploy" \
  -H 'Content-Type: application/json' -d "{\"vault_jwt\":\"$EXJWT2\",\"hint\":\"test-user-vault-jwt\"}")
[ "$WH" = 200 ] && ok "webhook déclenché (HTTP 200)" || bad "webhook → $WH"
R=""
for i in $(seq 1 30); do
  R=$(curl -s "$JENKINS/job/stoa-user-deploy/$N/api/json" 2>/dev/null | jget '.get("result") or ""')
  [ -n "$R" ] && break; sleep 3
done
[ "$R" = "SUCCESS" ] && ok "build Jenkins #$N SUCCESS" || bad "build #$N: ${R:-jamais terminé}"
LOG=$(curl -s "$JENKINS/job/stoa-user-deploy/$N/consoleText")
grep -q "identite=alice@bc.example" <<<"$LOG" \
  && ok "le log du job atteste l'identité HUMAINE (alice@bc.example), déléguée via vault-exchange" \
  || bad "identité absente du log"
grep -q "VERIFIE mort (lookup-self 403)" <<<"$LOG" \
  && ok "token Vault révoqué et PROUVÉ mort en fin de build (lookup-self 403)" || bad "revoke non prouvé"
grep -q "eyJ" <<<"$LOG" \
  && bad "FUITE : un JWT apparaît dans le log Jenkins" \
  || ok "aucun jeton dans le log Jenkins (printContributedVariables=false + set +x)"

# webhook SANS vault_jwt → build ROUGE (jamais de vert qui n'a rien fait)
N2=$(curl -s "$JENKINS/job/stoa-user-deploy/api/json" | jget '["nextBuildNumber"]')
curl -s -o /dev/null -X POST "$JENKINS/generic-webhook-trigger/invoke?token=stoa-user-deploy" \
  -H 'Content-Type: application/json' -d '{"hint":"payload invalide, sans vault_jwt"}'
R2=""
for i in $(seq 1 30); do
  R2=$(curl -s "$JENKINS/job/stoa-user-deploy/$N2/api/json" 2>/dev/null | jget '.get("result") or ""')
  [ -n "$R2" ] && break; sleep 3
done
[ "$R2" = "FAILURE" ] \
  && ok "webhook SANS vault_jwt → build #$N2 FAILURE (payload invalide ≠ no-op vert)" \
  || bad "webhook sans jeton → build #$N2: ${R2:-jamais terminé} (FAILURE attendu)"

echo "═══ 3. Contre-épreuves (le refus est aussi une preuve) ═══"
# CE1 — token utilisateur BRUT (non échangé, aud≠vault, azp≠vault-exchange) : Vault refuse.
L=$(vlogin "$TOK")
[ -z "$(printf '%s' "$L" | jget '["auth"]["client_token"]')" ] \
  && ok "CE1: token console NON échangé → Vault refuse (bound_audiences + bound azp)" \
  || bad "CE1: Vault a accepté un token non échangé !"

# CE2 — subject token de SERVICE (client_credentials poc-gateways, humain absent,
# non adressé à vault-exchange) : Keycloak doit refuser l'exchange.
SVC=$(curl -s -X POST "$KC/protocol/openid-connect/token" \
  -d grant_type=client_credentials -d client_id=poc-gateways -d client_secret=poc-gateways-secret | jget '["access_token"]')
if [ -n "$SVC" ]; then
  EXS=$(exchange "$SVC")
  [ -z "$EXS" ] \
    && ok "CE2: subject token non adressé à vault-exchange → KC refuse l'exchange" \
    || bad "CE2: KC a échangé un token de service non adressé !"
else
  bad "CE2: client_credentials poc-gateways KO (précondition non remplie — contre-épreuve non probante)"
fi

# CE3 — carol (viewer : rôle HORS bound_claims) : l'exchange passe, Vault refuse.
TOKC=$(DEX_USER="carol@bc.example" ./scripts/get-oracle-token.sh --quiet 2>"$ERRLOG")
EXC=""
[ -n "$TOKC" ] && EXC=$(exchange "$TOKC")
if [ -n "$EXC" ]; then
  L=$(vlogin "$EXC")
  [ -z "$(printf '%s' "$L" | jget '["auth"]["client_token"]')" ] \
    && ok "CE3: carol (viewer, pas de rôle déploiement) → Vault refuse (bound_claims realm_access.roles)" \
    || bad "CE3: Vault a accepté carol !"
else
  bad "CE3: token/exchange carol KO (précondition non remplie)"; sed 's/^/    /' "$ERRLOG" >&2
fi

# CE4 — l'audit Vault est NOMINATIF, sur les lignes de CE run uniquement.
# NB: pas de `docker exec | grep -q` — SIGPIPE 141 sous pipefail dès que la
# sortie dépasse le buffer de pipe. Variable + here-string.
AUDLOG=$(docker exec poc-vault sh -c "tail -n +$((AUD0+1)) /tmp/vault-audit.log 2>/dev/null" | grep 'auth/jwt/login' || true)
grep -q '"display_name":"jwt-alice@bc.example"' <<<"$AUDLOG" \
  && ok "CE4: audit Vault nominatif pour CE run (display_name=jwt-alice@bc.example)" \
  || bad "CE4: audit non nominatif ou absent sur ce run"
# CE4bis — les REFUS de CE run aussi sont audités (CE1 + carol).
grep -q '"error":' <<<"$AUDLOG" \
  && ok "CE4bis: les refus de login de CE run sont audités (trace des tentatives)" \
  || bad "CE4bis: aucun refus audité sur ce run"

echo
echo "=== RESULT: $PASS passed, $FAIL failed ==="
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
