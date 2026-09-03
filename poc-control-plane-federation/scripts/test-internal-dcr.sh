#!/usr/bin/env bash
# test-internal-dcr.sh — preuve X/X : en mode `internal`, c'est la GATEWAY qui
# émet le client OAuth2 (client_id + client_secret), pas le manifeste ni l'ops.
#
# CE QU'ON CORRIGE. Le rôle envoyait `clientId: <nom de l'application>` — le
# chemin « ce client existe déjà », celui d'un IdP externe. La gateway acceptait,
# la stratégie paraissait saine… mais l'AS local n'avait créé AUCUN client : pas
# de secret, donc aucun client_credentials possible. Le rôle réclamait alors le
# secret en extra-var, c'est-à-dire qu'il faisait porter à l'ops un credential que
# la gateway est censée émettre. La forme correcte est `dcrConfig` SANS clientId
# (« Generate credentials » de l'UI) — swagger officiel du produit,
# apigatewayservices/APIGatewayApplication.json.
#
# HORS LIGNE : mock webMethods (binaire Go du dépôt) + faux Vault KV v2
# lecture/écriture. Aucune gateway, aucun Vault, aucun secret réel.
#
#   ./scripts/test-internal-dcr.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/intdcr.XXXXXX)"
GW_PORT="${MOCK_PORT:-18557}"
MASK_PORT="${MASK_MOCK_PORT:-18558}"
VA_PORT="${VAULT_PORT:-18559}"
MOCK_PID=""; MASK_PID=""; VAULT_PID=""
cleanup(){ for p in $MOCK_PID $MASK_PID $VAULT_PID; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

command -v ansible-playbook >/dev/null || { echo "ansible-playbook absent"; exit 2; }
command -v go >/dev/null || { echo "go absent (nécessaire pour bâtir le mock)"; exit 2; }
command -v python3 >/dev/null || { echo "python3 absent (faux Vault)"; exit 2; }

# ── faux Vault : KV v2 LECTURE + ÉCRITURE, état en mémoire ───────────────────
# Le mode internal ÉCRIT (POST .../data/<sub>) puis, sur un build qui masque le
# secret en relecture, RELIT ce qu'il a écrit. Les deux verbes sont donc
# nécessaires pour mesurer l'idempotence réelle. 404 sur chemin inconnu = ce que
# fait un Vault dont l'entrée n'existe pas.
cat > "$TMP/fakevault.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
STORE = {}
class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if self.path == "/__dump":
            return self._send(200, STORE)
        entry = STORE.get(self.path)
        if entry is None:
            return self._send(404, {"errors": []})
        self._send(200, {"data": {"data": entry}})
    def do_POST(self):
        if self.path == "/__reset":
            STORE.clear()
            return self._send(200, {})
        n = int(self.headers.get("Content-Length") or 0)
        payload = json.loads(self.rfile.read(n) or b"{}")
        STORE[self.path] = payload.get("data", {})
        self._send(200, {"data": {"version": 1}})
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

echo "== mock webMethods (x2 : nominal + secret masqué) + faux Vault =="
(cd "$REPO/mocks/webmethods" && go build -o "$TMP/wm-mock" .) || { echo "build du mock échoué"; exit 2; }
LISTEN_ADDR=":$GW_PORT" "$TMP/wm-mock" >"$TMP/mock.log" 2>&1 &
MOCK_PID=$!
# Le second rejoue le build PESSIMISTE : le secret n'est lisible QUE dans la
# réponse de création (MaskableEntity). C'est le cas que le repli Vault doit
# absorber sans jamais réécrire "***".
WM_MASK_STRATEGY_CREDENTIAL=1 LISTEN_ADDR=":$MASK_PORT" "$TMP/wm-mock" >"$TMP/mock-mask.log" 2>&1 &
MASK_PID=$!
python3 "$TMP/fakevault.py" "$VA_PORT" >/dev/null 2>&1 &
VAULT_PID=$!
for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$GW_PORT/health" >/dev/null 2>&1 && break; sleep 0.2; done
curl -sf "http://127.0.0.1:$GW_PORT/health" >/dev/null 2>&1 || { echo "mock injoignable"; sed -n '1,20p' "$TMP/mock.log"; exit 2; }
curl -sf "http://127.0.0.1:$MASK_PORT/health" >/dev/null 2>&1 || { echo "mock masqué injoignable"; exit 2; }
for _ in $(seq 1 40); do curl -s "http://127.0.0.1:$VA_PORT/v1/nope" >/dev/null 2>&1 && break; sleep 0.1; done

GW="http://127.0.0.1:$GW_PORT/rest/apigateway"
GWM="http://127.0.0.1:$MASK_PORT/rest/apigateway"
VAULT="http://127.0.0.1:$VA_PORT"
# A5 (2026-09-03) : le mock crée l'API INACTIVE et le rôle refuse API_INACTIVE
# avant toute écriture — chaque sonde ACTIVE son API après l'avoir publiée.
publish_probe(){ # <base admin> → publie ET active 'probe' 1.0.0 (rc≠0 si l'un des deux échoue)
  local id
  id=$(curl -sf -u Administrator:manage -X POST "$1/apis" -H 'Content-Type: application/json' -H 'Accept: application/json' \
    -d '{"apiName":"probe","apiVersion":"1.0.0","type":"REST","apiDefinition":{"openapi":"3.0.0"}}' \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["apiResponse"]["api"]["id"])') || return 1
  curl -sf -u Administrator:manage -X PUT -o /dev/null "$1/apis/$id/activate"
}
for base in "$GW" "$GWM"; do
  publish_probe "$base" || { echo "création/activation de l'API de sonde échouée ($base)"; exit 2; }
done
echo "  gateway :$GW_PORT — gateway masquée :$MASK_PORT — vault :$VA_PORT"

SUB="deploy/banking-demo/apps/probe/dev/oauth-client"
KVPATH="/v1/secret/data/stoa/$SUB"

mkmanifest(){ # $1=sortie $2=app $3=mode $4=client_type $5=grants(JSON) $6=scopes(JSON)
cat > "$1" <<EOF
apim_ss_app:
  name: "$2"
  api: "probe"
  api_version: "1.0.0"
  description: "sonde DCR"
  contact_emails: []
  team: ""
  enforce: []
  ip_allowlist: []
  public_cert_ref: ""
  backend: { header: "", value_template: "" }
  auth:
    mode: "$3"
    server_alias: "local"
    audience: ""
    claim: { name: "azp", value: "probe-consumer" }
    vault_sub: "$SUB"
    client_type: "$4"
    grant_types: $5
    scopes: $6
EOF
}

probe(){ # $1=manifeste $2=base gateway ; extras en $3...
  local m="$1" base="$2"; shift 2
  OUT="$(cd "$REPO" && VAULT_ADDR="$VAULT" VAULT_TOKEN=fake ansible-playbook -i localhost, \
        ansible/test-internal-dcr.yml \
        -e "apim_ss_manifest=$m" -e "apim_ss_api_base=$base" \
        -e apim_ss_require_team=false "$@" 2>&1)"
  RC=$?
}

echo
echo "== 1. internal : la stratégie porte un dcrConfig (et PAS un clientId posé) =="
mkmanifest "$TMP/m-int.yml" "probe-dcr" "internal" "CONFIDENTIAL" '["client_credentials"]' '["$sys:default"]'
probe "$TMP/m-int.yml" "$GW"
[ $RC -eq 0 ] && ok "apply vert" || { ko "apply en échec (rc=$RC)"; echo "$OUT" | tail -30; }
grep -q "dcr_present=True" <<<"$OUT" && ok "dcrConfig stocké sur la stratégie" || ko "aucun dcrConfig — le client n'est pas généré"
grep -q "client_id_is_app_name=False" <<<"$OUT" \
  && ok "le client_id N'EST PAS le nom de l'app (il vient de la gateway)" \
  || ko "client_id = nom de l'app : c'est encore le chemin « client existant »"

echo
echo "== 2. le client émis est CONFIDENTIEL, en client_credentials, avec le scope =="
grep -q "client_type='CONFIDENTIAL'" <<<"$OUT" && ok "clientType=CONFIDENTIAL" || ko "type de client inattendu"
grep -q "reg_type='confidential'" <<<"$OUT" && ok "client relu confidentiel (clientRegistration)" || ko "clientRegistration non confidentiel"
grep -q "grants='client_credentials'" <<<"$OUT" && ok "grant client_credentials" || ko "grant types inattendus"
grep -q "cc_allowed=True" <<<"$OUT" && ok "clientCredentialsAllowed activé côté client émis" || ko "le client émis n'autorise pas client_credentials"
grep -q "scopes='.sys:default'" <<<"$OUT" && ok "scope de l'AS local associé au client" || ko "scope perdu"

echo
echo "== 3. un SECRET a été émis, et c'est LUI qui part dans Vault =="
grep -q "secret_present=True" <<<"$OUT" && ok "secret émis par la gateway" || ko "aucun secret émis"
grep -q "INTERNAL_CLIENT_WRITTEN" <<<"$OUT" && ok "écriture Vault annoncée" || ko "écriture Vault non tracée"
VJSON="$(curl -s "$VAULT$KVPATH")"
CID_V="$(python3 -c "import json,sys; print(json.load(sys.stdin)['data']['data'].get('client_id',''))" <<<"$VJSON")"
SEC_V="$(python3 -c "import json,sys; print(json.load(sys.stdin)['data']['data'].get('client_secret',''))" <<<"$VJSON")"
GW_SEC="$(curl -s -u Administrator:manage "$GW/strategies" | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    if s.get('name','').startswith('OAUTH2-probe-dcr'):
        print(s.get('clientRegistration',{}).get('clientSecret','')); break")"
[ -n "$SEC_V" ] && [ "$SEC_V" = "$GW_SEC" ] \
  && ok "Vault porte EXACTEMENT le secret émis par la gateway" || ko "secret Vault absent ou différent de celui de la gateway"
grep -q "captured_client_id='$CID_V'" <<<"$OUT" && ok "client_id capturé = client_id stocké" || ko "client_id incohérent entre gateway et Vault"
python3 -c "
import json,sys
d=json.loads(sys.argv[1])['data']['data']
sys.exit(0 if d.get('grant_types')=='client_credentials' and d.get('client_type')=='CONFIDENTIAL' and d.get('scopes')=='\$sys:default' else 1)" "$VJSON" \
  && ok "l'entrée Vault documente grant/type/scope (le consommateur rejoue sans deviner)" \
  || ko "métadonnées de rejeu absentes de l'entrée Vault"

echo
echo "== 3bis. le secret vient de la LISTE, PAS de la réponse de création (masquée) =="
# Mesuré live 10.15 (2026-08-03) : POST /strategies et GET /strategies/{id}
# rendent 32 astérisques ; SEUL GET /strategies rend le secret en clair. Lire la
# réponse de création — ce que la doc 11.0 laisse croire — écrirait des
# astérisques dans Vault sous un apply vert.
POSTED="$(curl -s -u Administrator:manage -H 'Content-Type: application/json' \
  -X POST "$GW/strategies" -d '{"name":"SONDE-MASQUE","type":"OAUTH2","authServerAlias":"local",
   "dcrConfig":{"clientType":"CONFIDENTIAL","allowedGrantTypes":["client_credentials"],"clientName":"SONDE-MASQUE"}}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['strategy']['clientRegistration']['clientSecret'])")"
[[ "$POSTED" =~ ^\*+$ ]] \
  && ok "la réponse de création masque bien le secret (contrat live rejoué)" \
  || ko "le mock ne rejoue pas le masquage de création — le piège n'est plus testé"
[[ "$SEC_V" =~ ^\*+$ ]] \
  && ko "Vault contient des ASTÉRISQUES : le rôle lit la mauvaise surface" \
  || ok "Vault contient un vrai secret (capture par la liste)"

echo
echo "== 4. IDEMPOTENCE : re-apply ne RE-GÉNÈRE pas le client (pas de rotation subie) =="
CID1="$CID_V"; SEC1="$SEC_V"
probe "$TMP/m-int.yml" "$GW"
[ $RC -eq 0 ] && ok "2e apply vert" || { ko "2e apply en échec (rc=$RC)"; echo "$OUT" | tail -30; }
grep -q "DCR_CONVERGED" <<<"$OUT" && ok "dcrConfig déjà conforme : AUCUN PUT" || ko "PUT rejoué alors que rien ne change"
VJSON2="$(curl -s "$VAULT$KVPATH")"
CID2="$(python3 -c "import json,sys; print(json.load(sys.stdin)['data']['data'].get('client_id',''))" <<<"$VJSON2")"
SEC2="$(python3 -c "import json,sys; print(json.load(sys.stdin)['data']['data'].get('client_secret',''))" <<<"$VJSON2")"
[ "$CID1" = "$CID2" ] && [ "$SEC1" = "$SEC2" ] \
  && ok "client_id ET secret INCHANGÉS (le consommateur en vol n'est pas cassé)" \
  || ko "le credential a changé sur un simple re-apply"

echo
echo "== 5. build qui MASQUE le secret en relecture : re-apply vert, rien n'est réécrit =="
mkmanifest "$TMP/m-mask.yml" "probe-mask" "internal" "CONFIDENTIAL" '["client_credentials"]' '[]'
probe "$TMP/m-mask.yml" "$GWM"
[ $RC -eq 0 ] && ok "1er apply vert (secret capturé malgré le masquage)" || ko "1er apply en échec (rc=$RC)"
MSUB_PATH="/v1/secret/data/stoa/$SUB"
SEC_M1="$(curl -s "$VAULT$MSUB_PATH" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['data'].get('client_secret',''))")"
probe "$TMP/m-mask.yml" "$GWM"
[ $RC -eq 0 ] && ok "2e apply vert malgré le secret masqué" || { ko "2e apply bloqué (rc=$RC)"; echo "$OUT" | tail -25; }
grep -q "INTERNAL_CLIENT_KEPT" <<<"$OUT" && ok "aucune réécriture (repli Vault assumé et annoncé)" || ko "réécriture ou repli non tracé"
SEC_M2="$(curl -s "$VAULT$MSUB_PATH" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['data'].get('client_secret',''))")"
[ "$SEC_M1" = "$SEC_M2" ] && [ "$SEC_M2" != "***" ] \
  && ok "Vault garde le VRAI secret (jamais la chaîne masquée)" || ko "Vault pollué par un secret masqué"

echo
echo "== 6. FAIL-CLOSED : secret non relisible ET rien dans Vault -> refus =="
curl -s -X POST "$VAULT/__reset" >/dev/null
probe "$TMP/m-mask.yml" "$GWM"
[ $RC -ne 0 ] && ok "refus (on ne déclare pas convergé un client sans secret)" || ko "apply vert sans aucun secret exploitable"
grep -q "INTERNAL_CLIENT_SECRET_MANQUANT" <<<"$OUT" && ok "INTERNAL_CLIENT_SECRET_MANQUANT" || ko "code d'erreur absent"

echo
echo "== 7. FAIL-CLOSED : client PUBLIC + client_credentials -> refus =="
mkmanifest "$TMP/m-pub.yml" "probe-pub" "internal" "PUBLIC" '["client_credentials"]' '[]'
probe "$TMP/m-pub.yml" "$GW"
[ $RC -ne 0 ] && ok "refusé (un client public n'a pas de secret à présenter)" || ko "client public accepté en client_credentials"
grep -q "CLIENT_PUBLIC_AVEC_CLIENT_CREDENTIALS" <<<"$OUT" && ok "code d'erreur explicite" || ko "code d'erreur absent"

echo
echo "== 8. FAIL-CLOSED : grant hors énumération du produit -> refus AVANT la gateway =="
mkmanifest "$TMP/m-grant.yml" "probe-grant" "internal" "CONFIDENTIAL" '["device_code"]' '[]'
probe "$TMP/m-grant.yml" "$GW"
[ $RC -ne 0 ] && ok "refusé" || ko "grant inconnu accepté"
grep -q "GRANT_TYPES_INVALIDES" <<<"$OUT" && ok "GRANT_TYPES_INVALIDES" || ko "code d'erreur absent"

echo
echo "== 9. SCOPE : manifeste vide -> celui que l'AS LOCAL publie par défaut =="
# Décision client : il y a un scope par défaut sur l'AS local, c'est celui-là
# qu'il faut. Le manifeste n'a donc rien à déclarer — et rien à inventer.
mkmanifest "$TMP/m-defscope.yml" "probe-defscope" "internal" "CONFIDENTIAL" '["client_credentials"]' '[]'
probe "$TMP/m-defscope.yml" "$GW"
[ $RC -eq 0 ] && ok "apply vert sans scope déclaré" || { ko "échec (rc=$RC)"; echo "$OUT" | tail -25; }
grep -q "SCOPE_PAR_DEFAUT" <<<"$OUT" && ok "scope résolu depuis l'AS (et annoncé)" || ko "résolution non tracée"
grep -q "scopes='.sys:default'" <<<"$OUT" \
  && ok "le client porte le scope par défaut de l'AS" || ko "client sans scope alors que l'AS en publie un"

echo
echo "== 10. SCOPE : un scope déclaré INCONNU de l'AS -> refus (pas de client mort-né) =="
mkmanifest "$TMP/m-badscope.yml" "probe-badscope" "internal" "CONFIDENTIAL" '["client_credentials"]' '["scope-qui-nexiste-pas"]'
probe "$TMP/m-badscope.yml" "$GW"
[ $RC -ne 0 ] && ok "refusé avant toute création" || ko "scope inexistant accepté (refus reporté au runtime)"
grep -q "SCOPE_INCONNU" <<<"$OUT" && ok "SCOPE_INCONNU" || ko "code d'erreur absent"

echo
echo "== 11. SCOPE : AS publiant plusieurs scopes sans défaut évident -> refus =="
# Mock relancé avec deux scopes anonymes : le rôle ne doit PAS en choisir un.
AMB_PORT=$((MASK_PORT+10))
WM_LOCAL_SCOPES="lecture,ecriture" LISTEN_ADDR=":$AMB_PORT" "$TMP/wm-mock" >"$TMP/mock-amb.log" 2>&1 &
AMB_PID=$!
for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$AMB_PORT/health" >/dev/null 2>&1 && break; sleep 0.2; done
publish_probe "http://127.0.0.1:$AMB_PORT/rest/apigateway" || { echo "création/activation de l'API de sonde échouée (amb)"; exit 2; }
mkmanifest "$TMP/m-amb.yml" "probe-amb" "internal" "CONFIDENTIAL" '["client_credentials"]' '[]'
probe "$TMP/m-amb.yml" "http://127.0.0.1:$AMB_PORT/rest/apigateway"
[ $RC -ne 0 ] && ok "refusé (on ne choisit pas les droits du client en silence)" || ko "un scope a été choisi arbitrairement"
grep -q "SCOPE_AMBIGU" <<<"$OUT" && ok "SCOPE_AMBIGU, avec la liste publiée" || ko "code d'erreur absent"
kill "$AMB_PID" 2>/dev/null

echo
echo "== 12. SCOPE : déclaré en SCALAIRE (et non en liste) -> même sens qu'une liste =="
# Régression vécue chez le client : `scopes: ScopeASLocal` au lieu de
# `scopes: ["ScopeASLocal"]` livrait une CHAÎNE là où l'aval attend une liste.
# `difference` itérant les CARACTÈRES d'une chaîne, le fail-closed refusait un
# scope BEL ET BIEN publié par l'AS, en affichant les lettres de son nom. L'AS
# est ici volontairement multi-scopes : sans manifeste honoré, on tomberait sur
# SCOPE_AMBIGU — le test prouve donc que c'est bien le scalaire qui a tranché.
SCA_PORT=$((MASK_PORT+11))
WM_LOCAL_SCOPES="lecture,ecriture" LISTEN_ADDR=":$SCA_PORT" "$TMP/wm-mock" >"$TMP/mock-sca.log" 2>&1 &
SCA_PID=$!
for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$SCA_PORT/health" >/dev/null 2>&1 && break; sleep 0.2; done
publish_probe "http://127.0.0.1:$SCA_PORT/rest/apigateway" || { echo "création/activation de l'API de sonde échouée (scalar)"; exit 2; }
mkmanifest "$TMP/m-scalar.yml" "probe-scalar" "internal" "CONFIDENTIAL" 'client_credentials' 'lecture'
probe "$TMP/m-scalar.yml" "http://127.0.0.1:$SCA_PORT/rest/apigateway"
[ $RC -eq 0 ] && ok "apply vert (scalaire = liste à un élément)" || { ko "scalaire refusé (rc=$RC)"; echo "$OUT" | tail -25; }
grep -q "SCOPE_INCONNU" <<<"$OUT" && ko "SCOPE_INCONNU sur un scope pourtant publié" || ok "aucun refus mensonger"
grep -q "scopes='lecture'" <<<"$OUT" && ok "le client porte le scope déclaré" || ko "scope scalaire perdu"
grep -q "GRANT_TYPES_INVALIDES" <<<"$OUT" && ko "grant scalaire refusé à tort" || ok "grant_types scalaire normalisé lui aussi"

# Même scalaire, mais injecté par le CI en EXTRA-VAR. Les extra-vars (précédence
# 22) écrasent le set_fact de resolve-env.yml (19) : la normalisation d'amont est
# alors court-circuitée, et seule celle du point de consommation tient. Ce cas
# échoue si l'on retire le `flatten` de consumer-auth.yml, même correctif d'amont
# en place — c'est ce que vit un Jenkinsfile qui passe `-e apim_ss_auth_scopes=`.
mkmanifest "$TMP/m-extravar.yml" "probe-extravar" "internal" "CONFIDENTIAL" '["client_credentials"]' '[]'
probe "$TMP/m-extravar.yml" "http://127.0.0.1:$SCA_PORT/rest/apigateway" -e apim_ss_auth_scopes=lecture
[ $RC -eq 0 ] && ok "apply vert (scalaire en extra-var CI)" || { ko "extra-var scalaire refusé (rc=$RC)"; echo "$OUT" | tail -25; }
grep -q "SCOPE_INCONNU" <<<"$OUT" && ko "SCOPE_INCONNU sur un scope pourtant publié (extra-var)" || ok "aucun refus mensonger (extra-var)"
grep -q "scopes='lecture'" <<<"$OUT" && ok "le client porte le scope passé par le CI" || ko "scope extra-var perdu"
kill "$SCA_PID" 2>/dev/null

echo
echo "== 13. NON-RÉGRESSION idp : clientId = la claim, AUCUN dcrConfig =="
mkmanifest "$TMP/m-idp.yml" "probe-idp" "idp" "CONFIDENTIAL" '["client_credentials"]' '[]'
# En idp l'audience est OBLIGATOIRE (garde conservée, cf. test-auth-audience.sh).
sed -i.bak 's/audience: ""/audience: "probe-api"/' "$TMP/m-idp.yml"
probe "$TMP/m-idp.yml" "$GW"
[ $RC -eq 0 ] && ok "apply idp vert" || { ko "régression sur le chemin idp (rc=$RC)"; echo "$OUT" | tail -25; }
grep -q "dcr_present=False" <<<"$OUT" && ok "aucun dcrConfig en idp (le client vit sur l'IdP)" || ko "dcrConfig envoyé en idp"
grep -q "client_id='probe-consumer'" <<<"$OUT" && ok "clientId = la claim du manifeste" || ko "claim perdue"

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || { echo "--- dernière sortie ansible ---"; echo "$OUT"; exit 1; }
