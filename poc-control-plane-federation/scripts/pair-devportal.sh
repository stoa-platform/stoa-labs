#!/usr/bin/env bash
# Appairage Developer Portal 11.1 ← API Gateway (10.15 OU 11.1).
#
#   ./scripts/pair-devportal.sh                       # gateway 10.15 du lab (defaut)
#   GW=http://localhost:15556 GW_SELF=http://poc-wm11-gateway:5555 \
#   DEST_NAME=stoa_wm11 ./scripts/pair-devportal.sh   # gateway 11.1 (overlay wm11)
#
# Enregistre le portal comme DESTINATION dans la gateway, puis (option --publish
# <apiId>) publie une API vers le portal. Idempotent : reutilise la destination.
#
# ─── Sens du flux (etabli empiriquement 2026-07-13, prouve 10.15 ET 11.1) ────
# gateway → portal (PUSH). La gateway s'enregistre aupres du portal, qui la voit
# alors comme un provider `type: GATEWAY` (avec un webhook de rappel), puis la
# gateway pousse ses APIs.
# L'autre sens est REFUTE : POST /portal/rest/v1/providers accepte n'importe quel
# provider sans valider URL ni credentials — simple etiquette, le portal ne tire
# jamais d'API de lui-meme.
#
# ─── LES DEUX PIEGES (ils m'ont coute des heures) ───────────────────────────
#
# 1. `externalPortal` est un OBJET, PAS un booleen.
#    Envoyer `"externalPortal": false` (ce que le nom suggere) fait echouer le
#    service Java sur `[ISS.0086.9249] Missing Parameter: document` — un message
#    totalement trompeur, qui n'a RIEN a voir avec un champ `document` manquant.
#    C'est l'objet ci-dessous qui porte la cible :
#      externalPortal: { type, endpointURL, endpointTenant,
#                        endpointUsername, endpointPassword }
#    `type` vaut "apiportal" : chaine LEGACY interne (heritee du vieux produit
#    API Portal/ARIS). C'est bien le Developer Portal qui est vise — ne pas
#    chercher un type "devportal", il n'existe pas.
#    Les champs gateway* decrivent LA GATEWAY elle-meme (son URL de rappel et
#    ses credentials), pas le portal.
#
# 2. `Accept: application/json` est OBLIGATOIRE sur l'admin REST de la gateway.
#    Sans ce header elle repond du HTML avec un code 200 → tout probe naif donne
#    un faux positif.
#
# Contrainte de nommage : gatewayName n'accepte que [alphanumerique, espace, _].
# Un tiret est refuse ("Field 'Name' should only contain alphanumeric, space and
# underscore characters") — d'ou stoa_lab_1015 et non stoa-lab-1015.
set -euo pipefail

GW="${GW:-http://localhost:5555}"                       # admin REST de la gateway (hote)
GW_SELF="${GW_SELF:-http://poc-webmethods-real:5555}"   # URL de la gateway VUE PAR LE PORTAL (reseau docker)
GW_AUTH="${GW_AUTH:-Administrator:manage}"
PORTAL_URL="${PORTAL_URL:-http://poc-devportal:8080}"   # URL du portal VUE PAR LA GATEWAY
PORTAL_PUB="${PORTAL_PUB:-http://localhost:18101}"      # URL du portal depuis l'hote (verification)
PORTAL_AUTH="${PORTAL_AUTH:-Administrator:manage}"
PORTAL_TENANT="${PORTAL_TENANT:-default}"
DEST_NAME="${DEST_NAME:-stoa_lab_1015}"                 # [a-zA-Z0-9 _] uniquement !

PUBLISH_API="${1:-}"   # optionnel : id d'une API a publier

gw() { curl -sS -m 90 -u "$GW_AUTH" -H "Accept: application/json" -H "Content-Type: application/json" "$@"; }
dp() { curl -sS -m 60 -u "$PORTAL_AUTH" -H "Accept: application/json" "$@"; }
py() { python3 -c "$@"; }

echo "== 1. destination '$DEST_NAME' deja enregistree ?"
DEST_ID="$(gw "$GW/rest/apigateway/portalGateways" | py "
import sys,json
r=json.load(sys.stdin).get('portalGatewayResponse',[])
r=r if isinstance(r,list) else [r]
print(next((g['id'] for g in r if g.get('gatewayName')=='$DEST_NAME'), ''))" 2>/dev/null || true)"

if [ -n "$DEST_ID" ]; then
  echo "   deja la : $DEST_ID (idempotent)"
else
  echo "== 1b. enregistrement (externalPortal = OBJET, cf. piege 1)"
  DEST_ID="$(gw -X POST "$GW/rest/apigateway/portalGateways" -d "{
    \"gatewayName\": \"$DEST_NAME\",
    \"gatewayURL\": \"$GW_SELF\",
    \"gatewayUsername\": \"$(echo "$GW_AUTH" | cut -d: -f1)\",
    \"gatewayPassword\": \"$(echo "$GW_AUTH" | cut -d: -f2)\",
    \"externalPortal\": {
      \"type\": \"apiportal\",
      \"endpointURL\": \"$PORTAL_URL\",
      \"endpointTenant\": \"$PORTAL_TENANT\",
      \"endpointUsername\": \"$(echo "$PORTAL_AUTH" | cut -d: -f1)\",
      \"endpointPassword\": \"$(echo "$PORTAL_AUTH" | cut -d: -f2)\"
    }
  }" | py "
import sys,json
d=json.load(sys.stdin)
r=d.get('portalGatewayResponse')
if not r: sys.exit('ECHEC : '+json.dumps(d)[:300])
print(r['id'])")"
  echo "   cree : $DEST_ID"
fi

echo "== 2. le portal voit-il la gateway comme provider ?"
dp "$PORTAL_PUB/portal/rest/v1/providers" | py "
import sys,json
for p in json.load(sys.stdin).get('result',[]):
    print('   -', p['name'], '| type', p.get('type'), '| url', p.get('providerurl'), '| webhooks', len(p.get('webhooks',[])))"

if [ -n "$PUBLISH_API" ]; then
  echo "== 3. publication de l'API $PUBLISH_API"
  # endpoints ET communities sont OBLIGATOIRES : un `endpoints: []` fait planter
  # le gateway sur un NPE ("endPointsToPublish is null").
  EP="$(gw "$GW/rest/apigateway/apis/$PUBLISH_API/fetchMetadata?portalGatewayId=$DEST_ID" \
        | py "import sys,json;print(json.load(sys.stdin)['apiResponse']['gatewayEndPoints'][0])")"
  COMM="$(gw "$GW/rest/apigateway/portalGateways/communities?portalGatewayId=$DEST_ID&apiId=$PUBLISH_API" \
        | py "import sys,json;print(json.load(sys.stdin)['portalGatewayResponse']['communities']['portalCommunities'][0]['id'])")"
  echo "   endpoint=$EP community=${COMM:0:8}"
  gw -X PUT "$GW/rest/apigateway/apis/$PUBLISH_API/publish?portalGatewayId=$DEST_ID" \
     -d "{\"endpoints\":[\"$EP\"],\"communities\":[\"$COMM\"],\"pubSOAPMethods\":\"REST\"}" \
     | py "import sys,json;d=json.load(sys.stdin);print('   ->', 'OK' if 'apiResponse' in d else json.dumps(d)[:200])"
fi

echo "== 4. APIs presentes dans le portal"
dp "$PORTAL_PUB/portal/rest/v1/apis" | py "
import sys,json
d=json.load(sys.stdin)
print('   count =', d.get('count'))
for a in d.get('result',[]):
    print('   -', a.get('name'), a.get('version'), '| provider', (a.get('providerRef') or '?')[:8])"

echo
echo "Portal : $PORTAL_PUB/portal/   (Administrator/manage)"
