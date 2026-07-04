#!/usr/bin/env bash
# demo-multienv.sh — la chaîne d'environnements COMPLÈTE (ADR-075), live,
# narratif + contre-épreuves : dev → rec automatiques sur push provider,
# rec → int par promotion approuvée par l'équipe int, int → prod gated
# change ITSM + PV + 4-yeux, rollback = revert Git + re-apply. Et la preuve
# inverse : tout ce qui DOIT échouer échoue (ITSM draft 409, self-approval 403,
# Jenkins ne résout pas wm-mock-dev, token sans scope refusé, AppRole CI ne lit
# pas les creds admin des envs → 403 Vault).
#
# Prereqs :
#   docker compose -f docker-compose.poc.yml -f docker-compose.wm.yml \
#     -f docker-compose.envs.yml up -d   (socle + wM réel ponté + mocks + itsm)
#   scripts/setup-vault.sh && scripts/setup-vault-envs.sh && scripts/setup-vault-approle.sh
#   scripts/setup-ci-applier.sh && scripts/setup-ci-horsprod.sh
#   scripts/setup-wm-admin-proxy.sh        (pose + prouve les 3 proxies)
#   console-light/scripts/setup-identity.sh (alice/bob/dave + rôles governance)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

KC="${KC_BASE:-http://localhost:8480}"
ITSM="${ITSM_URL:-http://localhost:8788}"
VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
WM="${WM_GATEWAY_URL:-http://localhost:5555}"
GPORT="${GOV_PORT:-8791}"; GOV="http://localhost:${GPORT}"
TENANT=banking-demo; SLUG=accounts-read
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
say() { printf '\n════════ %s ════════\n' "$*"; }

# gov METHOD PATH TOKEN [JSON] — à appeler SANS substitution de commande
# ($(gov …) confinerait CODE au sous-shell, set -u casserait) : le body est
# dans /tmp/dm.json, le code HTTP dans $CODE, et B est posé par l'appelant.
gov() {
  local m="$1" p="$2" t="$3" d="${4:-}"
  if [ -n "$d" ]; then
    CODE=$(curl -s -o /tmp/dm.json -w '%{http_code}' -X "$m" -H "Authorization: Bearer $t" \
      -H 'Content-Type: application/json' -d "$d" "$GOV/api/v1$p")
  else
    CODE=$(curl -s -o /tmp/dm.json -w '%{http_code}' -X "$m" -H "Authorization: Bearer $t" "$GOV/api/v1$p")
  fi
  cat /tmp/dm.json
}
# pid — extrait l'id de la promotion ({"promotion":{...}}, contract §3 rule 1)
pid() { python3 -c "import sys,json
try:
    d = json.load(sys.stdin)
    print((d.get('promotion') or {}).get('id') or d.get('id') or '')
except Exception:
    print('')"; }

say "0. Build (air-gapped) + repo governance jetable + governance-api (+ITSM)"
BD="$(mktemp -d)"; LABCTL="$BD/labctl"; GAPI="$BD/governance-api"
( cd labctl && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$LABCTL" . \
  && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$GAPI" ./cmd/governance-api ) || { echo build failed; exit 1; }
chmod +x "$LABCTL" "$GAPI"

REPO="$(mktemp -d)/gov"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main; git -C "$REPO" config commit.gpgsign false
mkf() { mkdir -p "$(dirname "$REPO/$1")"; cat > "$REPO/$1"; }
# Chaîne d'environnements + gates (ADR-075) — lue par governance-api ET apply-uac.
mkf environments.yaml <<'Y'
environments: [dev, rec, int, prod]
gates:
  - to: int
    approverGroup: int-team         # rec→int : approuvé par l'équipe int
  - to: prod
    fourEyes: true                  # int→prod : 4-yeux (self-approval -> 403)
    requireChangeRef: true          # change ITSM obligatoire
    requirePVRef: true              # preuve de validation obligatoire
    itsmCheck: true                 # change vérifié approved auprès de l'ITSM
Y
mkf tenants/$TENANT/apis/$SLUG/api.yaml <<'Y'
name: accounts-read
version: 1.0.0
tenant_id: banking-demo
status: published
endpoints: [{path: /accounts, methods: [GET], backend_url: http://microcks:8080/rest/Accounts+Read+API/1.0.0}]
Y
# « push provider » : dev+rec suivent le fil de l'eau (deploy mergés), PAS int/prod.
printf 'version: 1.0.0\nenabled: true\npromoted_by: alice\n' > "$REPO/tenants/$TENANT/apis/$SLUG/deploy.dev.yaml"
printf 'version: 1.0.0\nenabled: true\npromoted_by: alice\n' > "$REPO/tenants/$TENANT/apis/$SLUG/deploy.rec.yaml"
git -C "$REPO" add -A
git -C "$REPO" -c user.name="Alice Banking" -c user.email=alice@bank.example commit -q -m "feat(banking): accounts-read + deploy dev/rec"

GOVERNANCE_REPO="$REPO" KC_BASE="$KC" KC_REALM=stoa-lab ITSM_URL="$ITSM" LISTEN=":${GPORT}" \
  "$GAPI" >/tmp/dm_gapi.log 2>&1 &
SRV=$!
# Le trap restaure INCONDITIONNELLEMENT CHG-0001=approved : la contre-épreuve ③b
# révoque ce change dans l'ITSM LIVE partagé — un crash dans la fenêtre ne doit
# pas laisser le mock cassé pour les autres flux (governance-api :8787, Jenkins).
trap 'curl -s -X PUT "$ITSM/changes/CHG-0001/status" -H "Content-Type: application/json" -d "{\"status\":\"approved\"}" >/dev/null 2>&1; kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; rm -f /tmp/stoa-wm-admin-token' EXIT
for _ in $(seq 1 50); do curl -s -o /dev/null "$GOV/healthz" && break; sleep 0.2; done

say "0b. Identités — alice (request), bob (devops + groupe int-team), dave (cpi-admin)"
# Groupe int-team + bob membre + mapper groups (idempotent — le gate
# approverGroup lit le claim `groups` du token approbateur).
ATOK=$(curl -s -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d client_id=admin-cli -d grant_type=password -d "username=${KC_ADMIN_USER:-admin}" -d "password=${KC_ADMIN_PASS:-admin}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
API="$KC/admin/realms/stoa-lab"; AH=(-H "Authorization: Bearer $ATOK")
GID=$(curl -s "${AH[@]}" "$API/groups?search=int-team" | python3 -c 'import sys,json
g=[x for x in json.load(sys.stdin) if x.get("name")=="int-team"];print(g[0]["id"] if g else "")')
if [ -z "$GID" ]; then
  curl -s "${AH[@]}" -H 'Content-Type: application/json' -X POST "$API/groups" -d '{"name":"int-team"}' >/dev/null
  GID=$(curl -s "${AH[@]}" "$API/groups?search=int-team" | python3 -c 'import sys,json
g=[x for x in json.load(sys.stdin) if x.get("name")=="int-team"];print(g[0]["id"] if g else "")')
fi
BID=$(curl -s "${AH[@]}" "$API/users?username=bob@bc.example&exact=true" | python3 -c 'import sys,json;u=json.load(sys.stdin);print(u[0]["id"] if u else "")')
[ -n "$BID" ] && curl -s "${AH[@]}" -X PUT "$API/users/$BID/groups/$GID" -o /dev/null
echo "  int-team=$GID bob=$BID (bob membre — son token portera groups:[int-team])"

# Protocol mappers du client stoa-portal (idempotents) : governance-api lit les
# claims `tenant` (attribut user posé par setup-identity.sh — sans mapper il ne
# sort JAMAIS du user store) et `groups` (le gate approverGroup rec→int).
PCID=$(curl -s "${AH[@]}" "$API/clients?clientId=stoa-portal" | python3 -c 'import sys,json;c=json.load(sys.stdin);print(c[0]["id"] if c else "")')
if [ -n "$PCID" ]; then
  HAVE=$(curl -s "${AH[@]}" "$API/clients/$PCID/protocol-mappers/models" | python3 -c 'import sys,json
print(" ".join(m["name"] for m in json.load(sys.stdin)))')
  echo "$HAVE" | grep -q 'demo-tenant-attr' || curl -s "${AH[@]}" -H 'Content-Type: application/json' \
    -X POST "$API/clients/$PCID/protocol-mappers/models" -d '{
      "name":"demo-tenant-attr","protocol":"openid-connect",
      "protocolMapper":"oidc-usermodel-attribute-mapper",
      "config":{"user.attribute":"tenant","claim.name":"tenant","jsonType.label":"String",
                "access.token.claim":"true","id.token.claim":"true"}}' -o /dev/null
  echo "$HAVE" | grep -q 'demo-groups' || curl -s "${AH[@]}" -H 'Content-Type: application/json' \
    -X POST "$API/clients/$PCID/protocol-mappers/models" -d '{
      "name":"demo-groups","protocol":"openid-connect",
      "protocolMapper":"oidc-group-membership-mapper",
      "config":{"claim.name":"groups","full.path":"false",
                "access.token.claim":"true","id.token.claim":"true"}}' -o /dev/null
  echo "  mappers stoa-portal: tenant + groups OK"
fi

mint_user() { DEX_USER="$1@bc.example" CLIENT_ID=stoa-portal bash scripts/get-oracle-token.sh --quiet 2>/dev/null; }
TOK_ALICE="$(mint_user alice)"; TOK_BOB="$(mint_user bob)"; TOK_DAVE="$(mint_user dave)"
[ -n "$TOK_ALICE" ] && [ -n "$TOK_BOB" ] && [ -n "$TOK_DAVE" ] \
  || { echo "✗ tokens utilisateurs introuvables (console-light/scripts/setup-identity.sh joué ? Dex up ?)"; exit 1; }
# Bearer présenté aux proxies admin (bearerTokenFile des manifests envs/).
( umask 077; bash scripts/setup-ci-horsprod.sh --mint > /tmp/stoa-wm-admin-token ) \
  || { echo "✗ mint ci-horsprod"; exit 1; }
# Médiation apply (ADR-072) : compte de service cp-applier.
CPTOKFILE="$BD/cptok"; ( umask 077; bash scripts/setup-ci-applier.sh --mint > "$CPTOKFILE" )

applyenv() { # applyenv <env> — converge l'env depuis le repo governance jetable.
  # ITSM_URL arme le re-check LIVE du gate au dispatch (A6) : pour un env gated
  # itsmCheck (prod), apply-uac refuse fail-closed si le change du deploy.{env}.yaml
  # n'est plus approved à cet instant. DISPATCH_ITSM permet aux contre-épreuves de
  # forcer un ITSM injoignable sans toucher l'instance partagée.
  LABCTL_TOKEN_FILE="$CPTOKFILE" ITSM_URL="${DISPATCH_ITSM:-$ITSM}" "$LABCTL" apply-uac \
    --repo "$REPO" --env "$1" --tenant "$TENANT" -f "envs/$1/targets.yaml"
}

say "① push provider → convergence AUTOMATIQUE dev + rec (gate GIT)"
echo "  (lab : apply direct — le câblage push Gitea → webhook → Jenkins hors-prod"
echo "   est celui de ci/README.md ; le pipeline exécute EXACTEMENT cette boucle)"
applyenv dev && ok "① dev convergé (via proxy wm-admin-dev)" || bad "① apply dev KO"
applyenv rec && ok "① rec convergé (via proxy wm-admin-rec)" || bad "① apply rec KO"
OUT="$(applyenv int 2>&1)"; echo "$OUT" | sed 's/^/    /'
if echo "$OUT" | grep -qi "skip\|no enabled deploy"; then
  ok "① int SKIPPÉ (pas de deploy.int.yaml mergé — narration, pas d'erreur)"
else bad "① int aurait dû être skippé (gate Git)"; fi

say "② promotion rec → int (référence approuvée par l'équipe int) → merge → convergence"
gov POST "/tenants/$TENANT/promotions" "$TOK_ALICE" \
  "{\"slug\":\"$SLUG\",\"from\":\"rec\",\"to\":\"int\",\"message\":\"rec validée, demande int\"}" >/dev/null
B="$(cat /tmp/dm.json)"
PRID="$(echo "$B" | pid)"
[ -n "$PRID" ] && ok "② promotion demandée par alice ($PRID)" || { bad "② request KO (HTTP $CODE): $B"; PRID=pr_missing; }
gov POST "/tenants/$TENANT/promotions/$PRID/approve" "$TOK_BOB" '{}' >/dev/null
B="$(cat /tmp/dm.json)"
[ "$CODE" = 200 ] && ok "② approuvée par bob (int-team) → merge deploy.int.yaml" || bad "② approve KO (HTTP $CODE): $B"
applyenv int && ok "② int convergé (via proxy wm-admin-int)" || bad "② apply int KO"

say "③ promotion int → prod (change ITSM CHG-0001 approuvé + pv_ref + 4-yeux) → job prod"
gov POST "/tenants/$TENANT/promotions" "$TOK_ALICE" \
  "{\"slug\":\"$SLUG\",\"from\":\"int\",\"to\":\"prod\",\"message\":\"GO prod\",\"change_ref\":\"CHG-0001\",\"pv_ref\":\"PV-2026-042\"}" >/dev/null
B="$(cat /tmp/dm.json)"
PRODID="$(echo "$B" | pid)"
[ -n "$PRODID" ] && ok "③ promotion prod demandée ($PRODID, change CHG-0001, PV-2026-042)" || { bad "③ request prod KO (HTTP $CODE): $B"; PRODID=pr_missing; }
gov POST "/tenants/$TENANT/promotions/$PRODID/approve" "$TOK_BOB" '{}' >/dev/null
B="$(cat /tmp/dm.json)"
[ "$CODE" = 200 ] && ok "③ approuvée par bob ≠ alice (4-yeux) — ITSM vérifié approved" || bad "③ approve prod KO (HTTP $CODE): $B"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^poc-jenkins$'; then
  echo "  → en réel : job ci/Jenkinsfile.prod (Build with Parameters, PROMOTION_ID=$PRODID)"
  echo "    qui REJOUE ce gate depuis Git + labctl dispatch-gate avant tout dispatch."
fi

# ③b CONTRE-ÉPREUVE TOCTOU (A6) — le change est révoqué ENTRE l'approbation/merge
# et le dispatch : le re-check LIVE au dispatch doit REJOUER le 409, AUCUN apply.
say "③b anti-TOCTOU — CHG-0001 révoqué APRÈS l'approbation, AVANT le dispatch"
curl -s -X PUT "$ITSM/changes/CHG-0001/status" -H 'Content-Type: application/json' \
  -d '{"status":"cancelled"}' >/dev/null
OUT="$(applyenv prod 2>&1)"; RC=$?
echo "$OUT" | grep -i itsm | sed 's/^/    /'
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q 'ITSM_NOT_APPROVED'; then
  ok "③b change révoqué au dispatch → apply prod BLOQUÉ (409 ITSM_NOT_APPROVED rejoué)"
else bad "③b apply prod aurait dû être bloqué au dispatch (rc=$RC)"; fi
# Sabotage-test du fail-closed : ITSM injoignable au dispatch → refus 503 (pas un pass muet)
OUT="$(DISPATCH_ITSM=http://127.0.0.1:1 applyenv prod 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q 'ITSM_UNAVAILABLE'; then
  ok "③b ITSM injoignable au dispatch → 503 ITSM_UNAVAILABLE (fail-closed, pas de pass muet)"
else bad "③b ITSM injoignable aurait dû refuser 503 (rc=$RC)"; fi
# Ré-approbation → le dispatch repasse (preuve que le gate n'est pas juste 'toujours non').
curl -s -X PUT "$ITSM/changes/CHG-0001/status" -H 'Content-Type: application/json' \
  -d '{"status":"approved"}' >/dev/null
applyenv prod && ok "③ prod convergé après ré-approbation (admin DIRECT wM réel + commit pinné)" || bad "③ apply prod KO"
C=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$WM/gateway/accounts-read/1.0.0/accounts")
[ "$C" = 401 ] && ok "③ smoke prod : data-plane sans token → 401 (barrière active)" || bad "③ smoke prod → $C (attendu 401)"

say "④ rollback prod = revert Git ordonné + re-apply idempotent (jamais de DELETE)"
# Préambule fail-closed : rollbacker le PREMIER déploiement prod n'a pas de
# sens (rien à restaurer) — le 409 NO_PREVIOUS_STATE est la bonne réponse.
gov POST "/tenants/$TENANT/promotions/$PRODID/rollback" "$TOK_BOB" \
  '{"reason":"test premier état","change_ref":"CHG-0003"}' >/dev/null
B="$(cat /tmp/dm.json)"
[ "$CODE" = 409 ] && ok "④ rollback du 1er déploiement → 409 NO_PREVIOUS_STATE (fail-closed)" \
  || bad "④ rollback 1er état → HTTP $CODE (attendu 409): $B"
# v1.0.1 atteint int par la même chaîne (raccourci lab : commit direct du
# contrat + marker int — en réel ce sont les hops ①② rejoués), puis MEP prod.
python3 - "$REPO/tenants/$TENANT/apis/$SLUG/api.yaml" <<'EOF'
import sys,re
p=sys.argv[1]; s=open(p).read()
open(p,'w').write(re.sub(r'version:\s*1\.0\.0','version: 1.0.1',s,count=1))
EOF
printf 'version: 1.0.1\nenabled: true\npromoted_by: alice\n' > "$REPO/tenants/$TENANT/apis/$SLUG/deploy.int.yaml"
git -C "$REPO" -c user.name="Alice Banking" -c user.email=alice@bank.example \
  commit -qam "feat(banking): accounts-read v1.0.1 jusqu'en int (chaîne rejouée)"
gov POST "/tenants/$TENANT/promotions" "$TOK_ALICE" \
  "{\"slug\":\"$SLUG\",\"from\":\"int\",\"to\":\"prod\",\"message\":\"MEP v1.0.1\",\"change_ref\":\"CHG-0001\",\"pv_ref\":\"PV-2026-043\"}" >/dev/null
B="$(cat /tmp/dm.json)"; V2ID="$(echo "$B" | pid)"
gov POST "/tenants/$TENANT/promotions/${V2ID:-pr_missing}/approve" "$TOK_BOB" '{}' >/dev/null
B="$(cat /tmp/dm.json)"
[ "$CODE" = 200 ] && ok "④ v1.0.1 promue en prod ($V2ID — 2e état du deploy.prod.yaml)" || bad "④ MEP v1.0.1 KO (HTTP $CODE): $B"
# PAS de >/dev/null muet : c'est CET apply (v1.0.1 par-dessus v1.0.0) qui a
# révélé le fallback versioning wM (POST /apis/{id}/versions) — le masquer
# avait laissé passer le bug au premier 19/19.
applyenv prod >/tmp/dm-apply-v101.log 2>&1 && ok "④ v1.0.1 appliquée en prod (versioning wM natif)" \
  || { bad "④ apply v1.0.1 KO"; tail -5 /tmp/dm-apply-v101.log | sed 's/^/    /'; }
# Le rollback : restaure deploy.prod.yaml N-1 (v1.0.0, AVEC son pin), marker
# rolled_back + evidence motivée — l'exploit ne fait QUE ça + re-apply.
gov POST "/tenants/$TENANT/promotions/$V2ID/rollback" "$TOK_BOB" \
  '{"reason":"KO applicatif post-MEP v1.0.1","change_ref":"CHG-0003"}' >/dev/null
B="$(cat /tmp/dm.json)"
if [ "$CODE" = 200 ] || [ "$CODE" = 201 ]; then
  RV="$(python3 -c "import yaml,sys;print(yaml.safe_load(open('$REPO/tenants/$TENANT/apis/$SLUG/deploy.prod.yaml'))['version'])" 2>/dev/null \
     || grep -o 'version: *[0-9.]*' "$REPO/tenants/$TENANT/apis/$SLUG/deploy.prod.yaml" | head -1)"
  echo "$RV" | grep -q '1\.0\.0' && ok "④ rollback accepté → deploy.prod.yaml restauré v1.0.0 (revert commité, audité)" \
    || bad "④ rollback accepté mais version restaurée inattendue: $RV"
else bad "④ rollback KO (HTTP $CODE): $B"; fi
applyenv prod && ok "④ prod re-convergée sur l'état Git reverté" || bad "④ re-apply prod KO"

say "CONTRE-ÉPREUVES — tout ce qui doit échouer échoue (fail-closed)"
# 1. change ITSM en draft (CHG-0002, seed itsm-mock) → approve 409 ITSM_NOT_APPROVED
gov POST "/tenants/$TENANT/promotions" "$TOK_ALICE" \
  "{\"slug\":\"$SLUG\",\"from\":\"int\",\"to\":\"prod\",\"message\":\"draft\",\"change_ref\":\"CHG-0002\",\"pv_ref\":\"PV-x\"}" >/dev/null
B="$(cat /tmp/dm.json)"
DRID="$(echo "$B" | pid)"
gov POST "/tenants/$TENANT/promotions/${DRID:-pr_missing}/approve" "$TOK_BOB" '{}' >/dev/null
B="$(cat /tmp/dm.json)"
[ "$CODE" = 409 ] && ok "ITSM draft (CHG-0002) → 409 ITSM_NOT_APPROVED" || bad "ITSM draft → HTTP $CODE (attendu 409): $B"
# 2. self-approval prod (dave demande ET approuve) → 403 SELF_APPROVAL_BLOCKED
gov POST "/tenants/$TENANT/promotions" "$TOK_DAVE" \
  "{\"slug\":\"$SLUG\",\"from\":\"int\",\"to\":\"prod\",\"message\":\"self\",\"change_ref\":\"CHG-0001\",\"pv_ref\":\"PV-y\"}" >/dev/null
B="$(cat /tmp/dm.json)"
SAID="$(echo "$B" | pid)"
gov POST "/tenants/$TENANT/promotions/${SAID:-pr_missing}/approve" "$TOK_DAVE" '{}' >/dev/null
B="$(cat /tmp/dm.json)"
[ "$CODE" = 403 ] && ok "self-approval prod → 403 SELF_APPROVAL_BLOCKED" || bad "self-approval → HTTP $CODE (attendu 403): $B"
# 3. Jenkins ne résout JAMAIS un mock d'env bas (réseau nonprod interne)
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^poc-jenkins$'; then
  if docker exec poc-jenkins getent hosts wm-mock-dev >/dev/null 2>&1; then
    bad "poc-jenkins résout wm-mock-dev (le cloisonnement réseau ne tient pas)"
  else
    ok "poc-jenkins → wm-mock-dev : échec réseau (seul le wM réel ponte nonprod)"
  fi
else echo "  (poc-jenkins absent — contre-épreuve réseau SKIP)"; fi
# 4. token sans scope deploy:{env} → refus par le proxy
C=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Authorization: Bearer $TOK_ALICE" \
  "$WM/gateway/wm-admin-dev/1.0/rest/apigateway/health")
[ "$C" != 200 ] && ok "token alice (sans deploy:dev) sur wm-admin-dev → $C (refus)" || bad "token sans scope → 200 (barrière scope KO)"
# 5. l'AppRole CI (ci-pipeline) ne lit PAS les creds admin des envs → 403 Vault
IFS=$'\t' read -r RID SID < <(bash scripts/setup-vault-approle.sh --mint ci-pipeline 2>/dev/null) || true
if [ -n "${RID:-}" ] && [ -n "${SID:-}" ]; then
  CITOK=$(curl -s -X POST "$VAULT_ADDR/v1/auth/approle/login" -d "{\"role_id\":\"$RID\",\"secret_id\":\"$SID\"}" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("auth",{}).get("client_token",""))')
  C=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Vault-Token: $CITOK" \
    "$VAULT_ADDR/v1/secret/data/stoa/envs/dev/wm-admin")
  [ "$C" = 403 ] && ok "AppRole ci-pipeline lit envs/dev/wm-admin → 403 (policy étanche)" \
    || bad "AppRole ci-pipeline → HTTP $C (attendu 403)"
else echo "  (mint ci-pipeline KO — contre-épreuve Vault SKIP)"; fi

say "RÉCAP"
echo "  $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ] && echo "✓ multi-env ADR-075 prouvé : promotion = merge gated, env = rebuild-from-Git, prod = 4-yeux+ITSM+PV, rollback = revert+re-apply." \
  || { echo "✗ démo incomplète — voir les FAIL."; exit 1; }
