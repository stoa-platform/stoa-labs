#!/usr/bin/env bash
# test-backend-key.sh — preuve X/X de la CLÉ BACKEND PAR CONSOMMATEUR stockée
# sur l'application (identifier `token`), valeur lue dans Vault.
#
# LE MODÈLE (variante client, écart assumé vs ADR-078 §5b) : la clé n'est pas
# connue de l'application cliente ; la gateway sert de table de routage et une
# custom policy attachée à l'API lit l'identifier `token` puis l'injecte vers
# l'amont. Le rôle ne fait QUE poser l'entrée.
#
# HORS LIGNE : mock webMethods du dépôt (binaire Go, qui applique la vraie
# énumération des clés d'identifier) + faux Vault minimal. Ni gateway, ni Vault
# réel, ni secret — les clés sont jetables et générées ici.
#
#   ./scripts/test-backend-key.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/bkkey.XXXXXX)"
GW_PORT="${MOCK_PORT:-18557}"
VA_PORT="${VAULT_PORT:-18200}"
MOCK_PID=""; VAULT_PID=""
cleanup(){ [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
           [ -n "$VAULT_PID" ] && kill "$VAULT_PID" 2>/dev/null
           rm -rf "$TMP"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

command -v ansible-playbook >/dev/null || { echo "ansible-playbook absent"; exit 2; }
command -v go >/dev/null || { echo "go absent (nécessaire pour bâtir le mock)"; exit 2; }
command -v python3 >/dev/null || { echo "python3 absent (faux Vault)"; exit 2; }

KEY1="bk-$(openssl rand -hex 8)"
KEY2="bk-$(openssl rand -hex 8)"

# ── faux Vault : KV v2 en lecture seule, piloté par un fichier JSON ───────────
# 404 sur tout chemin inconnu — c'est exactement ce que fait un Vault dont
# l'entrée n'existe pas, et le rôle apim_common l'accepte (fallback PoC pour les
# creds d'admin). Seule l'entrée backend-key est servie.
cat > "$TMP/fakevault.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
STORE = json.load(open(os.environ["STORE"]))
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        entry = STORE.get(self.path)
        body = json.dumps({"data": {"data": entry}}).encode() if entry is not None \
               else json.dumps({"errors": []}).encode()
        self.send_response(200 if entry is not None else 404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

KVPATH="/v1/secret/data/stoa/deploy/banking-demo/apps/probe/dev/backend-key"
seedvault(){ printf '%s' "$1" > "$TMP/store.json"; }
startvault(){
  [ -n "$VAULT_PID" ] && kill "$VAULT_PID" 2>/dev/null
  STORE="$TMP/store.json" python3 "$TMP/fakevault.py" "$VA_PORT" >/dev/null 2>&1 &
  VAULT_PID=$!
  for _ in $(seq 1 40); do curl -s "http://127.0.0.1:$VA_PORT/v1/nope" >/dev/null 2>&1 && return; sleep 0.1; done
}

echo "== mock webMethods + faux Vault =="
(cd "$REPO/mocks/webmethods" && go build -o "$TMP/wm-mock" .) || { echo "build du mock échoué"; exit 2; }
LISTEN_ADDR=":$GW_PORT" "$TMP/wm-mock" >"$TMP/mock.log" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$GW_PORT/health" >/dev/null 2>&1 && break; sleep 0.2; done
curl -sf "http://127.0.0.1:$GW_PORT/health" >/dev/null 2>&1 \
  || { echo "mock injoignable"; sed -n '1,20p' "$TMP/mock.log"; exit 2; }
GW="http://127.0.0.1:$GW_PORT/rest/apigateway"
VAULT="http://127.0.0.1:$VA_PORT"
curl -sf -u Administrator:manage -X POST "$GW/apis" -H 'Content-Type: application/json' \
  -d '{"apiName":"probe","apiVersion":"1.0.0","type":"REST","apiDefinition":{"openapi":"3.0.0"}}' >/dev/null \
  || { echo "création de l'API de sonde échouée"; exit 2; }
echo "  gateway :$GW_PORT — vault :$VA_PORT — API 'probe' v1.0.0 publiée"

mkmanifest(){ # $1=sortie $2=app $3=ref $4=enforce $5=inject $6=cert_ref
cat > "$1" <<EOF
apim_ss_app:
  name: "$2"
  api: "probe"
  api_version: "1.0.0"
  description: "sonde clé backend"
  contact_emails: []
  team: ""
  enforce: $4
  ip_allowlist: ["10.0.0.1"]
  public_cert_ref: "$6"
  backend: { header: "apikey", value_template: "\${backend_apikey}", inject: $5 }
  backend_key_ref: "$3"
EOF
}

probe(){ # $1=manifeste $2=clé attendue ; extras en $3...
  local m="$1" exp="$2"; shift 2
  OUT="$(cd "$REPO" && VAULT_ADDR="$VAULT" VAULT_TOKEN=fake ansible-playbook -i localhost, \
        ansible/test-backend-key.yml \
        -e "apim_ss_manifest=$m" -e "apim_ss_api_base=$GW" \
        -e apim_ss_require_team=false -e "probe_expected_key=$exp" "$@" 2>&1)"
  RC=$?
}

SUB="deploy/banking-demo/apps/probe/dev/backend-key"

echo
echo "== 1. clé lue dans Vault et posée en identifier \`token\` =="
seedvault "{\"$KVPATH\": {\"api_key\": \"$KEY1\"}}"; startvault
mkmanifest "$TMP/m-ok.yml" "probe-bk" "$SUB" "[]" "false" ""
probe "$TMP/m-ok.yml" "$KEY1"
[ $RC -eq 0 ] && ok "apply vert" || ko "échec inattendu (rc=$RC)"
grep -q "BACKEND_KEY_OK" <<<"$OUT" && ok "lecture Vault tracée (sans la valeur)" || ko "lecture non tracée"
grep -q "token_match=True" <<<"$OUT" && ok "la valeur POSÉE est celle de Vault" || ko "valeur absente ou différente"
grep -q "token_entries=1" <<<"$OUT" \
  && ok "exactement UNE entrée token (la policy sélectionne par type)" || ko "0 ou plusieurs entrées token"

echo
echo "== 2. cert/IP ne sont pas écrasés par la pose de la clé =="
grep -qE "id_keys=\['ipAddressRange', 'token'\]" <<<"$OUT" \
  && ok "ipAddressRange préservé à côté de token" || ko "dimensions voisines perdues"

echo
echo "== 3. FAIL-CLOSED : entrée Vault ABSENTE =="
seedvault '{}'; startvault
probe "$TMP/m-ok.yml" "$KEY1"
[ $RC -ne 0 ] && ok "refus (rien posé)" || ko "a convergé sans clé"
grep -q "BACKEND_KEY_MISSING" <<<"$OUT" && ok "BACKEND_KEY_MISSING" || ko "code d'erreur absent"

echo
echo "== 4. FAIL-CLOSED : champ présent mais VIDE =="
seedvault "{\"$KVPATH\": {\"api_key\": \"\"}}"; startvault
probe "$TMP/m-ok.yml" "$KEY1"
[ $RC -ne 0 ] && grep -q "BACKEND_KEY_MISSING" <<<"$OUT" \
  && ok "valeur vide refusée (pas de convergé trompeur)" || ko "clé vide acceptée"

echo
echo "== 5. FAIL-CLOSED : \`token\` opposé dans enforce =="
seedvault "{\"$KVPATH\": {\"api_key\": \"$KEY1\"}}"; startvault
mkmanifest "$TMP/m-enf.yml" "probe-bk-enf" "$SUB" '["token"]' "false" ""
probe "$TMP/m-enf.yml" "$KEY1"
[ $RC -ne 0 ] && ok "refus (la clé backend ne devient pas une identité entrante)" || ko "token opposable accepté"
grep -q "BACKEND_KEY_ENFORCED" <<<"$OUT" && ok "BACKEND_KEY_ENFORCED" || ko "code d'erreur absent"

echo
echo "== 6. knob : backend.inject=false ⇒ AUCUNE action customHttpHeaders =="
grep -q "BACKEND_INJECT_OFF" <<<"$OUT" || true   # (cas 5 a échoué avant)
probe "$TMP/m-ok.yml" "$KEY1"
grep -q "BACKEND_INJECT_OFF" <<<"$OUT" && ok "désactivation annoncée" || ko "knob muet"
ACTIONS=$(curl -sf -u Administrator:manage "$GW/policyActions" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for a in d.get("policyAction",[]) if a.get("templateKey")=="customHttpHeaders"))' 2>/dev/null || echo "?")
[ "$ACTIONS" = "0" ] && ok "0 action customHttpHeaders sur la gateway" || ko "action posée malgré inject=false (n=$ACTIONS)"

echo
echo "== 7. NON-RÉGRESSION : inject par défaut (absent) ⇒ comportement actuel =="
cat > "$TMP/m-default.yml" <<EOF
apim_ss_app:
  name: "probe-bk-default"
  api: "probe"
  api_version: "1.0.0"
  description: "sonde"
  contact_emails: []
  team: ""
  enforce: []
  ip_allowlist: ["10.0.0.2"]
  public_cert_ref: ""
  backend: { header: "apikey", value_template: "\${backend_apikey}" }
  backend_key_ref: "$SUB"
EOF
probe "$TMP/m-default.yml" "$KEY1"
[ $RC -eq 0 ] && ok "apply vert sans le knob" || ko "régression sans le knob (rc=$RC)"
ACTIONS=$(curl -sf -u Administrator:manage "$GW/policyActions" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for a in d.get("policyAction",[]) if a.get("templateKey")=="customHttpHeaders"))' 2>/dev/null || echo "?")
[ "$ACTIONS" != "0" ] && ok "l'injection est bien posée par défaut (n=$ACTIONS)" || ko "injection perdue par défaut"

echo
echo "== 8. ROTATION (replace) : une nouvelle valeur REMPLACE l'ancienne =="
seedvault "{\"$KVPATH\": {\"api_key\": \"$KEY2\"}}"; startvault
probe "$TMP/m-ok.yml" "$KEY2"
[ $RC -eq 0 ] && grep -q "token_match=True" <<<"$OUT" \
  && ok "nouvelle clé posée" || ko "rotation non appliquée (rc=$RC)"
grep -q "token_entries=1" <<<"$OUT" \
  && ok "toujours UNE entrée (pas d'accumulation)" || ko "l'ancienne valeur traîne"

echo
echo "== 9. IDEMPOTENCE : rejouer le même manifeste =="
probe "$TMP/m-ok.yml" "$KEY2"
[ $RC -eq 0 ] && grep -q "token_entries=1" <<<"$OUT" \
  && ok "re-run convergé, pas de doublon" || ko "non idempotent (rc=$RC)"

echo
echo "== 10. NOM de l'entrée : le LIBELLÉ DU TYPE, pas un nom d'application =="
# C'est ce que l'UI AFFICHE. La convention du produit est d'y mettre le libellé
# du type (swagger officiel de l'Application Management Service :
# {"name":"Token","key":"token"}, {"name":"Username","key":"httpBasicAuth"}) ;
# un nom d'application s'y lit comme une clé CUSTOM. La sonde imprimait déjà
# token_name mais AUCUN cas ne l'assertait — le nom pouvait donc changer sans
# qu'une ligne rougisse.
probe "$TMP/m-ok.yml" "$KEY2"
grep -q "token_name='Token'" <<<"$OUT" \
  && ok "défaut = 'Token'" || ko "nom par défaut inattendu (attendu 'Token')"

echo
echo "== 11. le knob de nom est pris en compte, et NE DUPLIQUE PAS l'entrée =="
# Le point qui compte : le merge se fait par DIMENSION (`key`), pas par nom.
# Renommer doit REMPLACER la ligne existante. Si un renommage créait une seconde
# entrée `token`, la sélection par type deviendrait ambiguë — exactement ce que
# le modèle interdit.
cat > "$TMP/m-name.yml" <<EOF
apim_ss_app:
  name: "probe-bk"
  api: "probe"
  api_version: "1.0.0"
  description: "sonde nom d'identifier"
  contact_emails: []
  team: ""
  enforce: []
  ip_allowlist: ["10.0.0.1"]
  public_cert_ref: ""
  backend: { header: "apikey", value_template: "\${backend_apikey}", inject: false }
  backend_key_ref: "$SUB"
  backend_key_identifier_name: "Jeton porteur"
EOF
probe "$TMP/m-name.yml" "$KEY2"
[ $RC -eq 0 ] && ok "apply vert" || ko "échec avec un nom surchargé (rc=$RC)"
grep -q "token_name='Jeton porteur'" <<<"$OUT" \
  && ok "surcharge appliquée" || ko "knob ignoré"
grep -q "token_entries=1" <<<"$OUT" \
  && ok "toujours UNE entrée après renommage (remplacement, pas ajout)" \
  || ko "le renommage a créé une entrée en double — sélection par type ambiguë"
grep -q "token_match=True" <<<"$OUT" \
  && ok "la valeur survit au renommage" || ko "valeur perdue au renommage"

# On remet le nom par défaut pour les cas suivants (verify compare l'état posé).
probe "$TMP/m-ok.yml" "$KEY2"

echo
echo "== 12. VERIFY : la valeur posée est confirmée contre Vault =="
probe "$TMP/m-ok.yml" "$KEY2" -e probe_verify=true
[ $RC -eq 0 ] && ok "verify vert" || ko "verify échoue sur un état pourtant correct (rc=$RC)"
grep -q "BACKEND_KEY_CONFIRMED" <<<"$OUT" && ok "BACKEND_KEY_CONFIRMED" || ko "verdict absent"

echo
echo "== 13. VERIFY : ROUGE si la gateway et Vault divergent =="
# Cas réel : quelqu'un a roté la clé dans Vault SANS réappliquer. La gateway
# porte l'ancienne, donc la custom policy injecterait une clé périmée vers
# l'amont. On change Vault puis on lance le verify SEUL (probe_converge=false) —
# sinon l'apply corrigerait la divergence avant qu'on puisse la constater.
seedvault "{\"$KVPATH\": {\"api_key\": \"$KEY1\"}}"; startvault
probe "$TMP/m-ok.yml" "$KEY1" -e probe_verify=true -e probe_converge=false
[ $RC -ne 0 ] && ok "verify ROUGE sur la divergence" || ko "verify vert alors que la clé live est périmée"
grep -q "BACKEND_KEY_UNCONFIRMED" <<<"$OUT" && ok "BACKEND_KEY_UNCONFIRMED" || ko "verdict absent"

echo
echo "== 14. la clé n'apparaît JAMAIS dans la sortie =="
grep -q "$KEY2" <<<"$OUT" && ko "la clé fuite dans le log !" || ok "aucune fuite de la clé"

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || { echo "--- dernière sortie ansible ---"; echo "$OUT"; exit 1; }
