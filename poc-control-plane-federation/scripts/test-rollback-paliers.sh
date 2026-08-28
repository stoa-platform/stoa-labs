#!/usr/bin/env bash
# test-rollback-paliers.sh — G6 (ADR-085) : le repli, composant du déploiement,
# exercé LIVE sur homol avec la chaîne 5 paliers du gabarit. Porte du GOAL :
# retour au SHA N-1, smoke vert (catalogue du palier à la version N-1 via SON
# proxy admin), trace Git de l'acte (commit rolled_back + evidence + trailers).
# Contre-épreuves : rollback sans change_ref sur un palier qui l'exige (prod)
# => 400 GATE_REFS_REQUIRED ; double rollback => 409 ; 1er état => 409.
#
# Périmètre dit : le deployerGroup (G2) n'est PAS déclaré sur la chaîne scratch —
# l'axe « qui porte l'apply » a sa propre porte live (test-deployer-gate-live.sh,
# 21/21) et le preflight d'apply-uac est LE MÊME site de code pour l'aller et le
# re-apply du rollback. Ici on prouve le REPLI, pas le porteur.
#
# Prereqs :
#   docker compose -f docker-compose.poc.yml -f docker-compose.wm.yml \
#     -f docker-compose.envs.yml up -d
#   scripts/setup-vault.sh && scripts/setup-vault-envs.sh && scripts/setup-vault-approle.sh
#   scripts/setup-ci-applier.sh && scripts/setup-ci-horsprod.sh   (scope deploy:homol, G1)
#   scripts/setup-wm-admin-proxy.sh                               (proxies wm-admin-{int,homol}, G5)
#   console-light/scripts/setup-identity.sh                       (alice/bob + rôles governance)
#
# SC2015 (`A && ok … || bad …`) est l'IDIOME des harnais de preuve de ce dépôt,
# et il est SÛR ici : `ok`/`bad` se terminent par un `printf` réussi, donc le
# `|| bad` ne peut jamais suivre un `ok` exécuté. Désactivé au fichier plutôt
# que quatorze fois à la ligne.
# shellcheck disable=SC2015
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

KC="${KC_BASE:-http://localhost:8480}"
ITSM="${ITSM_URL:-http://localhost:8788}"
GPORT="${GOV_PORT:-8792}"; GOV="http://localhost:${GPORT}"
TENANT=banking-demo; SLUG=accounts-read
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
say() { printf '\n════════ %s ════════\n' "$*"; }

# gov METHOD PATH TOKEN [JSON] — à appeler SANS substitution de commande
# ($(gov …) confinerait CODE au sous-shell) : le body est dans /tmp/trp.json,
# le code HTTP dans $CODE.
gov() {
  local m="$1" p="$2" t="$3" d="${4:-}"
  if [ -n "$d" ]; then
    CODE=$(curl -s -o /tmp/trp.json -w '%{http_code}' -X "$m" -H "Authorization: Bearer $t" \
      -H 'Content-Type: application/json' -d "$d" "$GOV/api/v1$p")
  else
    CODE=$(curl -s -o /tmp/trp.json -w '%{http_code}' -X "$m" -H "Authorization: Bearer $t" "$GOV/api/v1$p")
  fi
  cat /tmp/trp.json
}
pid() { python3 -c "import sys,json
try:
    d = json.load(sys.stdin)
    print((d.get('promotion') or {}).get('id') or d.get('id') or '')
except Exception:
    print('')"; }
jget() { python3 -c "import sys,json
d=json.load(open('/tmp/trp.json'))
cur=d
for k in sys.argv[1:]:
    cur=(cur or {}).get(k)
print(cur if cur is not None else '')" "$@"; }

say "0. Build air-gapped + repo governance jetable (chaîne 5 paliers) + governance-api"
BD="$(mktemp -d)"; LABCTL="$BD/labctl"; GAPI="$BD/governance-api"
( cd labctl && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$LABCTL" . \
  && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$GAPI" ./cmd/governance-api ) || { echo build failed; exit 1; }

REPO="$(mktemp -d)/gov"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main; git -C "$REPO" config commit.gpgsign false
mkf() { mkdir -p "$(dirname "$REPO/$1")"; cat > "$REPO/$1"; }
# La chaîne du GABARIT (5 paliers) — sans deployerGroup (périmètre, cf. header).
mkf environments.yaml <<'Y'
environments: [dev, rec, int, homol, prod]
gates:
  - to: rec
    selfApproval: true
  - to: int
    approverGroup: int-team
    fourEyes: true
  - to: homol
    approverGroup: release-team
    fourEyes: true
    requirePVRef: true
  - to: prod
    approverGroup: release-team
    fourEyes: true
    requireChangeRef: true
    requirePVRef: true
    itsmCheck: true
Y
mkf "tenants/$TENANT/apis/$SLUG/api.yaml" <<'Y'
name: accounts-read
version: 1.0.0
tenant_id: banking-demo
status: published
endpoints: [{path: /accounts, methods: [GET], backend_url: http://microcks:8080/rest/Accounts+Read+API/1.0.0}]
Y
printf 'version: 1.0.0\nenabled: true\npromoted_by: alice\n' > "$REPO/tenants/$TENANT/apis/$SLUG/deploy.dev.yaml"
printf 'version: 1.0.0\nenabled: true\npromoted_by: alice\n' > "$REPO/tenants/$TENANT/apis/$SLUG/deploy.rec.yaml"
git -C "$REPO" add -A
git -C "$REPO" -c user.name="Alice Banking" -c user.email=alice@bank.example commit -q -m "feat(banking): accounts-read + deploy dev/rec (chaîne 5 paliers)"

GOVERNANCE_REPO="$REPO" KC_BASE="$KC" KC_REALM=stoa-lab ITSM_URL="$ITSM" LISTEN=":${GPORT}" \
  "$GAPI" >/tmp/trp_gapi.log 2>&1 &
SRV=$!
# Le trap restaure INCONDITIONNELLEMENT CHG-0001=approved : l'ITSM mock est
# PARTAGÉ avec les autres flux du lab — un crash ne doit pas le laisser cassé.
trap 'curl -s -X PUT "$ITSM/changes/CHG-0001/status" -H "Content-Type: application/json" -d "{\"status\":\"approved\"}" >/dev/null 2>&1; kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; rm -f /tmp/stoa-wm-admin-token' EXIT
for _ in $(seq 1 50); do curl -s -o /dev/null "$GOV/healthz" && break; sleep 0.2; done

say "0b. Identités — groupes int-team + release-team (bob membre des deux) + mappers"
ATOK=$(curl -s -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d client_id=admin-cli -d grant_type=password -d "username=${KC_ADMIN_USER:-admin}" -d "password=${KC_ADMIN_PASS:-admin}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
API="$KC/admin/realms/stoa-lab"; AH=(-H "Authorization: Bearer $ATOK")
ensure_group_with_bob() { # ensure_group_with_bob <name>
  local G="$1" GID BID
  GID=$(curl -s "${AH[@]}" "$API/groups?search=$G" | python3 -c "import sys,json
g=[x for x in json.load(sys.stdin) if x.get('name')=='$G'];print(g[0]['id'] if g else '')")
  if [ -z "$GID" ]; then
    curl -s "${AH[@]}" -H 'Content-Type: application/json' -X POST "$API/groups" -d "{\"name\":\"$G\"}" >/dev/null
    GID=$(curl -s "${AH[@]}" "$API/groups?search=$G" | python3 -c "import sys,json
g=[x for x in json.load(sys.stdin) if x.get('name')=='$G'];print(g[0]['id'] if g else '')")
  fi
  BID=$(curl -s "${AH[@]}" "$API/users?username=bob@bc.example&exact=true" | python3 -c 'import sys,json;u=json.load(sys.stdin);print(u[0]["id"] if u else "")')
  [ -n "$BID" ] && [ -n "$GID" ] && curl -s "${AH[@]}" -X PUT "$API/users/$BID/groups/$GID" -o /dev/null
  echo "  $G=$GID bob=$BID"
}
ensure_group_with_bob int-team
ensure_group_with_bob release-team
# Mappers stoa-portal tenant+groups : posés idempotents par demo-multienv ;
# on les (re)pose ici pareil pour que le script soit autoporteur.
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
fi

# Secrets des clients CI : ABSENTS du dépôt par construction (.env.example les
# laisse vides — dépôt public). Quand l'opérateur ne les exporte pas, on les
# RELIT du client Keycloak DÉJÀ POSÉ (via l'ATOK admin ci-dessus) : le harnais
# reste autoporteur sans qu'un secret n'entre jamais dans Git, et setup-ci-*.sh
# reste appelé — donc idempotent, avec LA valeur en place (aucune dérive).
# Client absent ⇒ échec propre au préambule : c'est un prereq, pas un test.
kc_client_secret() { # kc_client_secret <clientId>
  local C="$1" CID
  CID=$(curl -s "${AH[@]}" "$API/clients?clientId=$C" | python3 -c 'import sys,json;j=json.load(sys.stdin);print(j[0]["id"] if j else "")')
  [ -n "$CID" ] || return 1
  curl -s "${AH[@]}" "$API/clients/$CID/client-secret" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("value",""))'
}
: "${CI_HORSPROD_SECRET:=$(kc_client_secret ci-horsprod)}"
: "${CI_APPLIER_SECRET:=$(kc_client_secret ci-applier)}"
export CI_HORSPROD_SECRET CI_APPLIER_SECRET
[ -n "$CI_HORSPROD_SECRET" ] && [ -n "$CI_APPLIER_SECRET" ] \
  || { echo "✗ secrets ci-horsprod/ci-applier introuvables (exportez CI_HORSPROD_SECRET/CI_APPLIER_SECRET, ou jouez scripts/setup-ci-horsprod.sh + scripts/setup-ci-applier.sh)"; exit 1; }

mint_user() { DEX_USER="$1@bc.example" CLIENT_ID=stoa-portal bash scripts/get-oracle-token.sh --quiet 2>/dev/null; }
TOK_ALICE="$(mint_user alice)"; TOK_BOB="$(mint_user bob)"
[ -n "$TOK_ALICE" ] && [ -n "$TOK_BOB" ] || { echo "✗ tokens alice/bob introuvables (setup-identity.sh ? Dex ?)"; exit 1; }
( umask 077; bash scripts/setup-ci-horsprod.sh --mint > /tmp/stoa-wm-admin-token ) || { echo "✗ mint ci-horsprod"; exit 1; }
CPTOKFILE="$BD/cptok"; ( umask 077; bash scripts/setup-ci-applier.sh --mint > "$CPTOKFILE" )

applyenv() { LABCTL_TOKEN_FILE="$CPTOKFILE" ITSM_URL="$ITSM" "$LABCTL" apply-uac \
  --repo "$REPO" --env "$1" --tenant "$TENANT" -f "envs/$1/targets.yaml"; }
promote() { # promote <from> <to> <extra-json-fields> — request alice + approve bob
  gov POST "/tenants/$TENANT/promotions" "$TOK_ALICE" \
    "{\"slug\":\"$SLUG\",\"from\":\"$1\",\"to\":\"$2\",\"message\":\"hop $1->$2\"$3}" >/dev/null
  PRID="$(pid < /tmp/trp.json)"
  [ -n "$PRID" ] || { bad "request $1->$2 KO (HTTP $CODE): $(cat /tmp/trp.json)"; return 1; }
  gov POST "/tenants/$TENANT/promotions/$PRID/approve" "$TOK_BOB" '{}' >/dev/null
  [ "$CODE" = 200 ] || { bad "approve $1->$2 KO (HTTP $CODE): $(cat /tmp/trp.json)"; return 1; }
}

say "① la chaîne monte jusqu'à homol — v1.0.0 (l'état N-1 de la preuve)"
promote rec int '' && ok "① rec→int demandée alice, approuvée bob (int-team, 4-yeux)"
applyenv int >/dev/null 2>&1 && ok "① int convergé (wm-admin-int)" || bad "① apply int KO"
promote int homol ',"pv_ref":"PV-2026-101"' && ok "① int→homol (pv_ref exigé à la demande) approuvée bob (release-team)"
applyenv homol >/dev/null 2>&1 && ok "① homol convergé v1.0.0 (wm-admin-homol)" || bad "① apply homol KO"
DEPLOY_PATH="tenants/$TENANT/apis/$SLUG/deploy.homol.yaml"
N1RAW="$(git -C "$REPO" show "main:$DEPLOY_PATH")"
N1SHA="$(git -C "$REPO" log -1 --format=%H -- "$DEPLOY_PATH")"
echo "$N1RAW" | grep -q 'commit:' && ok "① l'état N-1 porte son pin (commit: présent)" || bad "① deploy.homol.yaml N-1 sans pin"

say "② v1.0.1 atteint homol (l'état N que le repli va quitter)"
python3 - "$REPO/tenants/$TENANT/apis/$SLUG/api.yaml" <<'EOF'
import sys,re
p=sys.argv[1]; s=open(p).read()
open(p,'w').write(re.sub(r'version:\s*1\.0\.0','version: 1.0.1',s,count=1))
EOF
printf 'version: 1.0.1\nenabled: true\npromoted_by: alice\n' > "$REPO/tenants/$TENANT/apis/$SLUG/deploy.int.yaml"
git -C "$REPO" -c user.name="Alice Banking" -c user.email=alice@bank.example \
  commit -qam "feat(banking): accounts-read v1.0.1 jusqu'en int (chaîne rejouée)"
promote int homol ',"pv_ref":"PV-2026-102"' && ok "② v1.0.1 promue en homol (2e état de deploy.homol.yaml)"
V2ID="$PRID"
applyenv homol >/tmp/trp-apply-v101.log 2>&1 && ok "② v1.0.1 appliquée en homol" \
  || { bad "② apply v1.0.1 KO"; tail -5 /tmp/trp-apply-v101.log | sed 's/^/    /'; }

say "③ PORTE G6 — rollback homol : SHA N-1, verbatim, trace Git, smoke"
# homol n'exige AUCUNE ref au rollback (pv-only ; D3 adr-085) — reason suffit.
gov POST "/tenants/$TENANT/promotions/$V2ID/rollback" "$TOK_BOB" \
  '{"reason":"KO recette homol v1.0.1"}' >/dev/null
if [ "$CODE" = 200 ]; then
  ok "③ rollback homol accepté (200, reason seule — pv_ref non exigé au repli)"
  RESTCOMMIT="$(jget restored commit)"; RESTVER="$(jget restored version)"; RESTENV="$(jget restored environment)"
  [ "$RESTENV" = homol ] && [ "$RESTVER" = "1.0.0" ] && ok "③ restored = homol@1.0.0" \
    || bad "③ restored inattendu: env=$RESTENV ver=$RESTVER"
  NOWRAW="$(git -C "$REPO" show "main:$DEPLOY_PATH")"
  [ "$NOWRAW" = "$N1RAW" ] && ok "③ deploy.homol.yaml == contenu au SHA N-1 ($(printf %.7s "$N1SHA")) VERBATIM, pin compris" \
    || bad "③ contenu restauré ≠ N-1"
  PINN1="$(printf '%s\n' "$N1RAW" | sed -n 's/^commit: *//p')"
  [ -n "$PINN1" ] && [ "$RESTCOMMIT" = "$PINN1" ] && ok "③ le pin restauré est CELUI du N-1 ($PINN1)" \
    || bad "③ pin restauré ($RESTCOMMIT) ≠ pin N-1 ($PINN1)"
  MSG="$(git -C "$REPO" log -1 --format=%B)"
  if echo "$MSG" | grep -q "rollback $SLUG (homol)" && echo "$MSG" | grep -q "Evidence:"; then
    ok "③ trace Git de l'acte : commit 'rollback $SLUG (homol)' + trailer Evidence"
  else bad "③ commit de rollback sans sujet/trailers attendus: $MSG"; fi
  EVP="$(jget evidence)"
  git -C "$REPO" show "main:$EVP" >/dev/null 2>&1 && ok "③ evidence pack commité ($EVP)" || bad "③ evidence absent ($EVP)"
  # Pas de GET /promotions/{id} sur governance-api (seule la LISTE existe,
  # server.go:71) : on relit la liste du tenant et on filtre par id.
  gov GET "/tenants/$TENANT/promotions" "$TOK_BOB" >/dev/null
  ST=$(python3 -c "import json,sys;ps=json.load(open('/tmp/trp.json'));m=[p for p in ps if p.get('id')==sys.argv[1]];print(m[0]['status'] if m else '')" "$V2ID")
  [ "$ST" = rolled_back ] && ok "③ promotion marquée rolled_back" || bad "③ statut: $ST"
else bad "③ rollback homol KO (HTTP $CODE): $(cat /tmp/trp.json)"; fi
# Le re-apply du repli est LE geste qui porte l'état N-1 jusqu'à la gateway :
# son log n'est jamais muet (c'est un apply de v1.0.0 PAR-DESSUS v1.0.1 — le
# chemin où un moteur naïf régresse).
applyenv homol >/tmp/trp-apply-rollback.log 2>&1 && ok "③ homol re-convergé sur l'état Git reverté" \
  || { bad "③ re-apply homol KO"; tail -8 /tmp/trp-apply-rollback.log | sed 's/^/    /'; }
"$LABCTL" get apis -f envs/homol/targets.yaml -o json > /tmp/trp-catalog.json 2>/dev/null
# SMOKE = PRÉSENCE de la version N-1 dans le catalogue du palier. Un résidu
# 1.0.1 y reste par CONSTRUCTION (le repli ne DÉ-publie jamais : aucun DELETE
# dans apply-uac, ADR-079) — ce qu'on prouve, c'est que l'état N-1 est SERVI.
python3 - /tmp/trp-catalog.json <<'PY' && ok "③ SMOKE : catalogue homol (via wm-admin-homol) porte accounts-read@1.0.0" || bad "③ SMOKE KO : accounts-read@1.0.0 absent du catalogue homol"
import json, sys
d = json.load(open(sys.argv[1]))
apis = [a for t in d.get("targets", []) for a in (t.get("apis") or [])]
sys.exit(0 if any(a.get("name") == "accounts-read" and a.get("version") == "1.0.0" for a in apis) else 1)
PY

say "④ CONTRE-ÉPREUVES — les refus, par leur nom"
# a. double rollback => 409 NOT_APPROVED (rolled_back n'est plus annulable)
gov POST "/tenants/$TENANT/promotions/$V2ID/rollback" "$TOK_BOB" '{"reason":"encore"}' >/dev/null
[ "$CODE" = 409 ] && ok "④a double rollback → 409 $(jget error code)" || bad "④a double rollback → HTTP $CODE (attendu 409)"
# b. LA contre-épreuve du GOAL : palier à change_ref (prod) — sans lui, refus nommé.
curl -s -X PUT "$ITSM/changes/CHG-0001/status" -H 'Content-Type: application/json' -d '{"status":"approved"}' >/dev/null
promote homol prod ',"change_ref":"CHG-0001","pv_ref":"PV-2026-103"' && ok "④b homol→prod approuvée (régime complet : change+PV+ITSM+4-yeux)"
PRODID="$PRID"
gov POST "/tenants/$TENANT/promotions/$PRODID/rollback" "$TOK_BOB" '{"reason":"test refus"}' >/dev/null
B="$(cat /tmp/trp.json)"
if [ "$CODE" = 400 ] && echo "$B" | grep -q GATE_REFS_REQUIRED; then
  ok "④b rollback prod SANS change_ref → 400 GATE_REFS_REQUIRED (contre-épreuve GOAL)"
else bad "④b rollback sans change_ref → HTTP $CODE (attendu 400 GATE_REFS_REQUIRED): $B"; fi
# c. …et la garde des refs est bien ANTÉRIEURE à l'historique : avec le
# change_ref, le MÊME rollback tombe sur 409 NO_PREVIOUS_STATE (1er état prod).
gov POST "/tenants/$TENANT/promotions/$PRODID/rollback" "$TOK_BOB" \
  '{"reason":"test premier état","change_ref":"CHG-0003"}' >/dev/null
B="$(cat /tmp/trp.json)"
if [ "$CODE" = 409 ] && echo "$B" | grep -q NO_PREVIOUS_STATE; then
  ok "④c avec change_ref → 409 NO_PREVIOUS_STATE (fail at the earliest prouvé : refs AVANT historique)"
else bad "④c rollback 1er état → HTTP $CODE (attendu 409 NO_PREVIOUS_STATE): $B"; fi

say "⑤ Remise à l'identique du lab (mocks int+homol touchés → restart, catalogues re-vérifiés)"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^poc-wm-mock-homol$'; then
  docker restart poc-wm-mock-int poc-wm-mock-homol >/dev/null 2>&1
  sleep 2
  for E in int homol; do
    "$LABCTL" get apis -f "envs/$E/targets.yaml" -o json > /tmp/trp-clean.json 2>/dev/null
    # `ok:true` EXIGÉ avec le compte : sans lui, une gateway injoignable (proxy
    # 404 après un recyclage keepalive du wM réel) rend un catalogue VIDE et
    # cette assertion virerait au vert sans rien avoir mesuré.
    N=$(python3 -c 'import json,sys
d=json.load(open("/tmp/trp-clean.json"))
if not d.get("ok"): sys.exit("injoignable")
print(sum(len(t.get("apis") or []) for t in d.get("targets",[])))' 2>/dev/null || echo '?')
    [ "$N" = 0 ] && ok "⑤ catalogue $E relu joignable et remis à n=0" || bad "⑤ catalogue $E: n=$N (attendu 0 ; '?' = gateway injoignable)"
  done
else echo "  (mocks absents — remise à l'identique SKIP)"; fi

say "RÉCAP"
echo "  $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ] && echo "✓ G6 : le repli est un composant du déploiement — homol rollbacké au SHA N-1, tracé, smoké ; les refus portent leur nom." \
  || { echo "✗ preuve incomplète — voir les FAIL."; exit 1; }
