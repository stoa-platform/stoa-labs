#!/usr/bin/env bash
# Phase 3 — configure all 3 gateways to validate Keycloak (Oracle-federated)
# Bearer JWTs at the data-plane. Run AFTER the batched restart:
#
#   docker compose -f docker-compose.poc.yml up -d --build --force-recreate \
#       wso2am apisix webmethods-mock
#
# (WSO2 restart loads the Keycloak Key Manager into its runtime; APISIX picks up
#  the openid-connect plugin; the mock enables JWT validation via JWT_ISSUER.)
#
# Issuer model: tokens carry iss=http://keycloak:8080/realms/stoa-lab (obtained
# with `Host: keycloak:8080`), and every gateway validates against keycloak:8080
# over the compose network — one consistent issuer, no Keycloak restart needed.
set -uo pipefail
cd "$(dirname "$0")/.."
WSO2=https://localhost:9443
KC_WK=http://keycloak:8080/realms/stoa-lab/.well-known/openid-configuration
KC_ISS=http://keycloak:8080/realms/stoa-lab
ADMIN_KEY=poc-apisix-admin-key

get() { awk -v sec="[$1]" -v k="$2" '$0==sec{f=1;next} f&&/^\[/{exit} f{p=index($0,"="); if(p){key=substr($0,1,p-1); gsub(/ /,"",key); if(key==k){v=substr($0,p+1); sub(/^ +/,"",v); print v; exit}}}' labctl-credentials.txt; }
[[ -f labctl-credentials.txt ]] || { echo "run ./scripts/demo.sh first (need labctl-credentials.txt)"; exit 1; }
KC_CID=$(get keycloak clientId); KC_SEC=$(get keycloak clientSecret)

wso2_token() { # scope...
  local reg cid csec
  reg=$(curl -sk -X POST "$WSO2/client-registration/v0.17/register" -H "Authorization: Basic $(printf 'admin:admin'|base64)" -H "Content-Type: application/json" -d '{"callbackUrl":"https://localhost","clientName":"setup_identity","owner":"admin","grantType":"password","saasApp":true}')
  cid=$(echo "$reg"|python3 -c "import sys,json;print(json.load(sys.stdin)['clientId'])"); csec=$(echo "$reg"|python3 -c "import sys,json;print(json.load(sys.stdin)['clientSecret'])")
  curl -sk -X POST "$WSO2/oauth2/token" -H "Authorization: Basic $(printf '%s:%s' "$cid" "$csec"|base64)" -d "grant_type=password&username=admin&password=admin&scope=$*" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))"
}

echo "═══ 1/3  WSO2: register the Keycloak Key Manager (idempotent) ═══"
ATOK=$(wso2_token "apim:admin apim:keymanagers_manage")
existing=$(curl -sk "$WSO2/api/am/admin/v4/key-managers" -H "Authorization: Bearer $ATOK" | python3 -c "import sys,json;print(next((k['id'] for k in json.load(sys.stdin).get('list',[]) if k['name']=='Keycloak'),''))")
if [[ -n "$existing" ]]; then
  echo "  Keycloak KM already registered ($existing) — keeping it (do NOT re-create:"
  echo "  WSO2 loads KMs into its runtime holder at STARTUP, so a re-registered KM"
  echo "  needs a 'docker restart poc-wso2am' before map-keys works)."
else
  # Use the dedicated WSO2 'KeyCloak' connector (NOT 'default'=WSO2-IS, which NPEs
  # on a null keyManagerServiceUrl). Endpoints pinned to the internal keycloak:8080
  # (reachable from WSO2); issuer = localhost:8480 to match the token's iss.
  curl -sk -X POST "$WSO2/api/am/admin/v4/key-managers/discover" -H "Authorization: Bearer $ATOK" -F "url=$KC_WK" -F "type=KeyCloak" -o /tmp/km_disc.json
  python3 - <<'PY'
import json
KC="http://keycloak:8080/realms/stoa-lab"
d=json.load(open('/tmp/km_disc.json')); v=d.get('value',d); v.pop('id',None)
v.update({'name':'Keycloak','displayName':'Keycloak (stoa-lab)','type':'KeyCloak','enabled':True,
 'issuer':'http://localhost:8480/realms/stoa-lab',
 'wellKnownEndpoint':KC+'/.well-known/openid-configuration',
 'tokenEndpoint':KC+'/protocol/openid-connect/token',
 'introspectionEndpoint':KC+'/protocol/openid-connect/token/introspect',
 'revokeEndpoint':KC+'/protocol/openid-connect/revoke',
 'userInfoEndpoint':KC+'/protocol/openid-connect/userinfo',
 'authorizeEndpoint':KC+'/protocol/openid-connect/auth',
 'clientRegistrationEndpoint':KC+'/clients-registrations/openid-connect',
 'scopeManagementEndpoint':KC+'/clients-registrations/openid-connect',
 'certificates':{'type':'JWKS','value':KC+'/protocol/openid-connect/certs'},
 'enableSelfValidationJWT':True,'enableMapOAuthConsumerApps':True,'enableOAuthAppCreation':False,
 'enableTokenGeneration':False,'consumerKeyClaim':'azp','scopesClaim':'scope','tokenType':'DIRECT',
 'tokenValidation':[{'id':1,'type':'JWT','value':{},'enable':True}],
 'additionalProperties':{'client_id':'poc-gateways','client_secret':'poc-gateways-secret','self_validate_jwt':True}})
json.dump(v,open('/tmp/km2.json','w'))
PY
  code=$(curl -sk -X POST "$WSO2/api/am/admin/v4/key-managers" -H "Authorization: Bearer $ATOK" -H "Content-Type: application/json" -d @/tmp/km2.json -o /dev/null -w '%{http_code}')
  echo "  register Keycloak KM (type=KeyCloak) -> HTTP $code"
  echo "  ⚠ NEXT: 'docker restart poc-wso2am' (wait ~3min) so the KM loads into the"
  echo "    runtime, THEN re-run this script — map-keys below will then succeed."
fi

echo "═══ 2/3  WSO2: map the Keycloak client onto the subscribed app ═══"
DTOK=$(wso2_token "apim:subscribe apim:app_manage")
APPID=$(curl -sk "$WSO2/api/am/devportal/v3/applications?query=accounts-read-consumer" -H "Authorization: Bearer $DTOK" | python3 -c "import sys,json;l=json.load(sys.stdin).get('list',[]);print(l[0]['applicationId'] if l else '')")
map_ok=0
for attempt in 1 2 3; do
  code=$(curl -sk -X POST "$WSO2/api/am/devportal/v3/applications/$APPID/map-keys" -H "Authorization: Bearer $DTOK" -H "Content-Type: application/json" \
    -d "{\"consumerKey\":\"$KC_CID\",\"consumerSecret\":\"$KC_SEC\",\"keyType\":\"PRODUCTION\",\"keyManager\":\"Keycloak\"}" -o /tmp/mk.json -w '%{http_code}')
  echo "  map-keys (Keycloak KM) attempt $attempt -> HTTP $code"
  [[ "$code" == "200" || "$code" == "409" ]] && { map_ok=1; break; }
  sleep 4
done
if [[ "$map_ok" == "0" ]]; then
  echo "  ✗ map-keys failed (HTTP 500 = the KM is in the DB but NOT in WSO2's runtime"
  echo "    holder). Fix: 'docker restart poc-wso2am', wait ~3min for healthy, then"
  echo "    re-run THIS script (it now keeps the existing KM and just maps)."
fi

echo "═══ 3/3  APISIX: switch the data-plane routes to openid-connect (bearer JWKS) ═══"
for rid in accounts-read-0 accounts-read-1; do
  cur=$(curl -s -H "X-API-KEY: $ADMIN_KEY" "http://localhost:9180/apisix/admin/routes/$rid" 2>/dev/null)
  [[ -z "$cur" ]] && { echo "  $rid: not found (run ./scripts/demo.sh first)"; continue; }
  body=$(echo "$cur" | python3 -c "
import sys,json
v=json.load(sys.stdin)['value']
pl=v.get('plugins',{})
for k in ('key-auth','jwt-auth'): pl.pop(k,None)   # drop consumer auth
pl['openid-connect']={'discovery':'$KC_WK','bearer_only':True,'use_jwks':True,
  'token_signing_alg_values_expected':'RS256','ssl_verify':False,
  'client_id':'apisix-gateway','client_secret':'unused','realm':'stoa-lab',
  'set_userinfo_header':False,'set_id_token_header':False}
out={k:v[k] for k in ('uri','methods','service_id','plugins','labels','status') if k in v}
out['plugins']=pl
print(json.dumps(out))
")
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "X-API-KEY: $ADMIN_KEY" -X PUT "http://localhost:9180/apisix/admin/routes/$rid" -d "$body")
  echo "  $rid -> openid-connect (HTTP $code)"
done

echo ""
echo "✓ Phase 3 setup complete. Now prove it: ./scripts/phase3-identity-demo.sh"
