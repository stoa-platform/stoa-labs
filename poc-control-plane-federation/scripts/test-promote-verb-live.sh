#!/usr/bin/env bash
# test-promote-verb-live.sh — LA porte du GOAL G5 : le verbe « promotion par
# archive » (ADR-079) prouvé LIVE, contre la vraie gateway webMethods 10.15, par
# CHACUN des deux moteurs — le rôle Ansible `apim_promote_api` (le livrable
# client) et `labctl promote` (le moteur du lab).
#
# CE QUI EST PROUVÉ, ET POURQUOI ÇA NE SE PROUVE PAS HORS LIGNE. Les suites
# existantes (test-archive-promotion.sh, les tests Go de l'adaptateur) prouvent
# la MÉCANIQUE de l'archive et les REFUS. Ce qu'aucune d'elles ne prouve, c'est
# que le VERBE — tel que le CI l'invoque, manifeste + digest + pin — produise
# sur une gateway réelle les deux propriétés que l'ADR-079 promet :
#   1. GUID ISO : l'API importée porte le GUID épinglé au manifeste, y compris
#      sur un palier VIERGE (souscriptions, scope-mappings et teams des autres
#      paliers référencent ce GUID — s'il dérive, la promotion ment) ;
#   2. ZÉRO COUPURE : l'import écrase une API ACTIVE en place, sous charge, sans
#      qu'aucune requête consommateur ne tombe.
# Et surtout : par les DEUX moteurs, avec les MÊMES assertions. Un moteur qui
# verdirait seul ne serait pas une porte, ce serait une préférence.
#
# TERRAIN : le lab VIVANT. Assets JETABLES préfixés `g5live-`, purgés au setup
# (rejouabilité) ET par un trap de sortie inconditionnel. Aucun asset existant
# n'est touché ; aucun mock d'environnement, aucun Gitea/Vault/Jenkins.
#
#   ./scripts/test-promote-verb-live.sh
#   GW_ADMIN=http://localhost:5555/rest/apigateway \
#   GW_DATA=http://localhost:5555/gateway \
#   WM_USER=Administrator WM_PASS=manage ./scripts/test-promote-verb-live.sh
#
# ⚠ Le conteneur de la gateway du lab est recyclé par un keepalive après ~20 min
# d'inactivité. Le script attend le retour de /apis avant chaque phase (wait_gw)
# plutôt que d'échouer sur un 000 de recyclage — un rouge doit vouloir dire « le
# verbe est cassé », jamais « le conteneur redémarrait ».
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
GW="${GW_ADMIN:-http://localhost:5555/rest/apigateway}"
DP="${GW_DATA:-http://localhost:5555/gateway}"
WM_USER="${WM_USER:-Administrator}"
WM_PASS="${WM_PASS:-manage}"
AUTH="$WM_USER:$WM_PASS"
# adminUrl de labctl : SANS le suffixe /rest/apigateway (l'adaptateur l'ajoute
# lui-même, webmethods.go:48) alors que apim_ss_api_base l'INCLUT (contrat du
# rôle, apim_common/defaults/main.yml). Le piège est le même qu'en §8 de
# team-promote.sh : le laisser produirait /rest/apigateway/rest/apigateway/*.
ADMIN_ROOT="${GW%/}"; ADMIN_ROOT="${ADMIN_ROOT%/rest/apigateway}"
# Le backend per-env : joignable depuis la GATEWAY (réseau compose), pas depuis
# le harnais — le harnais ne parle jamais qu'à la gateway.
BACKEND_URL="${BACKEND_URL:-http://poc-token-echo:8080/backend/dev}"

WORK="$(mktemp -d /tmp/g5live.XXXXXX)"
PASS=0; FAIL=0
ENGINES="${ENGINES:-ansible labctl}"
# Les assets vivants, à purger quoi qu'il arrive (le trap relit la gateway : il
# ne dépend d'aucune variable posée en cours de route, donc un échec précoce
# nettoie autant qu'un run complet).
ASSET_APIS=""; ASSET_ALIASES=""

say()  { printf '\n== %s ==\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko()   { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else ko "$3 (attendu '$2', obtenu '$1')"; fi; }
adm()  { curl -sS -u "$AUTH" -H "Accept: application/json" "$@"; }

# ── outillage gateway ────────────────────────────────────────────────────────
api_id()   { adm "$GW/apis" | jq -r --arg n "$1" --arg v "$2" \
               '[.apiResponse[].api | select(.apiName==$n and .apiVersion==$v) | .id][0] // empty'; }
api_field(){ adm "$GW/apis/$1" | jq -r --arg f "$2" '.apiResponse.api[$f] // empty'; }
alias_id() { adm "$GW/alias" | jq -r --arg n "$1" '[(.alias // [])[] | select(.name==$n) | .id][0] // empty'; }
alias_uri(){ adm "$GW/alias" | jq -r --arg n "$1" '[(.alias // [])[] | select(.name==$n) | .endPointURI][0] // empty'; }
dp_path()  { curl -sS -m 8 "$DP/$1/1.0.0/ping" | jq -r '.path // empty'; }

# Le keepalive recycle le conteneur : attendre le retour de la surface d'admin
# AVANT de conclure. Compte les occurrences pour le rapport.
GW_RECYCLES=0
wait_gw() {
  local i=0
  while [ "$i" -lt 60 ]; do
    [ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 -u "$AUTH" "$GW/apis")" = "200" ] && {
      [ "$i" -gt 0 ] && { GW_RECYCLES=$((GW_RECYCLES+1)); printf '  ⏳ gateway revenue après %ds (recyclage keepalive)\n' "$((i*3))"; }
      return 0
    }
    i=$((i+1)); sleep 3
  done
  return 1
}

# purge_asset <api-name> <alias-name> — l'ordre compte : une API ACTIVE refuse
# le DELETE, et un alias encore lié par une API vivante n'a pas à disparaître
# avant elle.
purge_asset() {
  local aname="$1" alname="$2" id
  id="$(api_id "$aname" "1.0.0")"
  if [ -n "$id" ]; then
    adm -X PUT "$GW/apis/$id/deactivate" -o /dev/null
    adm -X DELETE "$GW/apis/$id" -o /dev/null
  fi
  id="$(alias_id "$alname")"
  [ -n "$id" ] && adm -X DELETE "$GW/alias/$id" -o /dev/null
  return 0
}

cleanup() {
  say "cleanup (assets jetables g5live-*)"
  for E in $ENGINES; do purge_asset "g5live-$E-api" "g5live-$E-backend"; done
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── préflight ────────────────────────────────────────────────────────────────
say "préflight : gateway, outils, moteurs"
wait_gw || { ko "la gateway d'admin ne répond pas sur $GW"; exit 1; }
ok "gateway d'admin joignable ($GW)"
for T in jq zip unzip python3 ansible-playbook go; do
  command -v "$T" >/dev/null 2>&1 || { ko "outil requis absent : $T"; exit 1; }
done
( cd "$REPO/labctl" && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$WORK/labctl" . ) \
  || { ko "build de labctl"; exit 1; }
ok "labctl construit ($WORK/labctl)"

# ── le contrat OpenAPI jetable, commun aux deux moteurs ──────────────────────
# Le `servers:` est LITTÉRAL : l'authoring publie avec le backend en dur, et
# c'est l'EXPORT du moteur (sanitize --routing-alias) qui re-pointe le routing
# sur ${alias}. Poser le ${alias} à la main ici volerait au moteur la moitié du
# verbe qu'on prétend mesurer.
cat > "$WORK/contract.yaml" <<'EOF'
openapi: 3.0.0
info: { title: g5live, version: 1.0.0 }
servers: [ { url: "http://poc-token-echo:8080" } ]
paths: { /ping: { get: { operationId: ping, responses: { '200': { description: ok } } } } }
EOF

# ── setup d'un moteur : API ACTIVE routée sur le backend littéral ────────────
setup_engine() {
  local E="$1" API="g5live-$1-api" ALS="g5live-$1-backend" id
  purge_asset "$API" "$ALS"          # rejouabilité : un run précédent ne dicte rien
  id=$(adm -H "Content-Type: application/json" -X POST "$GW/alias" \
        -d "{\"name\":\"$ALS\",\"type\":\"endpoint\",\"endPointURI\":\"$BACKEND_URL\"}" \
        | jq -r '.id // .alias.id // empty')
  [ -n "$id" ] || { ko "[$E] création de l'alias $ALS"; return 1; }
  id=$(adm -F "file=@$WORK/contract.yaml;type=application/x-yaml" -F type=openapi \
        -F "apiName=$API" -F apiVersion=1.0.0 "$GW/apis" \
        | jq -r '.apiResponse.api.id // empty')
  [ -n "$id" ] || { ko "[$E] création de l'API $API"; return 1; }
  adm -X PUT "$GW/apis/$id/activate" -o /dev/null
  printf '%s' "$id" > "$WORK/$E.setup-guid"     # fichier, jamais un pipe
  return 0
}

# ── les deux invocations du verbe, et elles seules ───────────────────────────
# Tout ce qui précède un appel à ces fonctions est de l'EXPLOITATION (curl
# d'admin) ; ici, et seulement ici, c'est le MOTEUR qui agit.
engine_export() {
  local E="$1"
  case "$E" in
    ansible)
      ansible-playbook -i "$REPO/ansible/inventory.lab.ini" "$REPO/ansible/promote-api.yml" \
        -e apim_promote_action=export \
        -e apim_promote_manifest="$WORK/$E.promote.yml" \
        -e apim_ss_archive_pin="$WORK/$E.zip" \
        -e apim_ss_env=rec \
        -e apim_ss_api_base="$GW" -e apim_ss_data_base="$DP" \
        -e apim_ss_wm_user="$WM_USER" -e apim_ss_wm_password="$WM_PASS" \
        -e apim_ss_vault_addr=""
      ;;
    labctl)
      "$WORK/labctl" promote --manifest "$WORK/$E.promote.yml" --env rec \
        --action export --archive "$WORK/$E.zip" -f "$WORK/$E.targets.yaml"
      ;;
  esac
}

engine_import() {
  local E="$1"
  case "$E" in
    ansible)
      ansible-playbook -i "$REPO/ansible/inventory.lab.ini" "$REPO/ansible/promote-api.yml" \
        -e apim_promote_action=import \
        -e apim_promote_manifest="$WORK/$E.promote.yml" \
        -e apim_ss_archive_pin="$WORK/$E.zip" \
        -e apim_ss_archive_sha256="$(cat "$WORK/$E.sha256")" \
        -e apim_ss_env=rec -e apim_ss_authoring_env=dev \
        -e apim_ss_api_base="$GW" -e apim_ss_data_base="$DP" \
        -e apim_ss_wm_user="$WM_USER" -e apim_ss_wm_password="$WM_PASS" \
        -e apim_ss_vault_addr=""
      ;;
    labctl)
      # ⚠ le digest N'EST PAS un drapeau de labctl (cf. le rapport) : côté Go,
      # les octets sont gardés par l'ArchiveTaintCheck + le GUID iso ; le digest
      # est vérifié par le CI (scripts/lib/deploy-pin.sh) et par le rôle.
      "$WORK/labctl" promote --manifest "$WORK/$E.promote.yml" --env rec \
        --action import --archive "$WORK/$E.zip" -f "$WORK/$E.targets.yaml"
      ;;
  esac
}

# ═════════════════════════════════════════════════════════════════════════════
# LA BOUCLE : mêmes assertions, un moteur après l'autre
# ═════════════════════════════════════════════════════════════════════════════
for E in $ENGINES; do
  API="g5live-$E-api"; ALS="g5live-$E-backend"
  say "MOTEUR « $E » — setup jetable ($API v1.0.0, alias $ALS)"
  wait_gw || { ko "[$E] gateway indisponible avant le setup"; continue; }
  setup_engine "$E" || continue
  SETUP_GUID="$(cat "$WORK/$E.setup-guid")"
  ok "[$E] API ACTIVE $API ($SETUP_GUID) + alias $ALS -> $BACKEND_URL"
  check "$(dp_path "$API")" "/ping" "[$E] S1 data-plane servi AVANT toute promotion (backend littéral)"

  # ── le manifeste jetable — la MÊME forme pour les deux moteurs ─────────────
  # `archive:` est ABSENT : le chemin de l'artefact arrive par le pin
  # (apim_ss_archive_pin) ou par --archive, jamais du manifeste — c'est ce que
  # le CI fait (ce qui part au moteur est ce que le store a vérifié).
  # `per_env.rec` porte l'URL du backend : la seule valeur qui change d'un
  # palier à l'autre, et celle qui ne voyage JAMAIS dans l'archive.
  cat > "$WORK/$E.promote.yml" <<EOF
---
apim_promote:
  name: "$API"
  version: "1.0.0"
  guid: ""
  overwrite: "apis,policies,policyactions"
  backend_alias:
    name: "$ALS"
  per_env:
    rec:
      backend_alias:
        url: "$BACKEND_URL"
EOF
  # Les cibles de labctl : la forme VALIDÉE en §8 de team-promote.sh (le
  # chargeur exige contract + une cible nommée/typée avec adminUrl et EXACTEMENT
  # un mode d'auth) — ici Basic, l'auth directe du PoC.
  cat > "$WORK/$E.targets.yaml" <<EOF
apiVersion: labctl.stoa.io/v1
kind: FederationTarget
name: $API
contract: $WORK/contract.yaml
targets:
  - name: wm-rec
    type: webmethods
    adminUrl: $ADMIN_ROOT
    gatewayUrl: $ADMIN_ROOT
    credentials:
      username: $WM_USER
      password: $WM_PASS
EOF

  # ── PHASE 1 : EXPORT PAR LE MOTEUR ────────────────────────────────────────
  say "[$E] phase 1 — EXPORT par le moteur"
  wait_gw || ko "[$E] gateway indisponible avant l'export"
  engine_export "$E" >"$WORK/$E.export.log" 2>&1; RC=$?
  [ "$RC" -eq 0 ] && ok "[$E] E1 le moteur rend 0 à l'export" \
                  || ko "[$E] E1 export rc=$RC — $(tail -3 "$WORK/$E.export.log" | tr '\n' ' ')"
  grep -q "EXPORT_CONFIRMED" "$WORK/$E.export.log" \
    && ok "[$E] E2 le moteur prononce EXPORT_CONFIRMED" \
    || ko "[$E] E2 EXPORT_CONFIRMED absent du log du moteur"
  [ -s "$WORK/$E.zip" ] && ok "[$E] E3 l'artefact existe et n'est pas vide" \
                        || ko "[$E] E3 $WORK/$E.zip absent ou vide"
  # L'archive est-elle PORTABLE ? Les deux moteurs promettent la même chose :
  # ni valeur d'alias d'un autre palier, ni secret chiffré.
  if unzip -l "$WORK/$E.zip" 2>/dev/null | grep -qE 'Alias/|PassmanData/'; then
    ko "[$E] E4 l'artefact embarque Alias/ ou PassmanData/ (non portable, ARCHIVE_TAINTED)"
  else
    ok "[$E] E4 artefact sain (ni Alias/ ni PassmanData/)"
  fi
  # Le digest de l'ARTEFACT — celui que le marqueur épingle et que le rôle
  # re-vérifie. Fichier, pas pipe.
  shasum -a 256 "$WORK/$E.zip" 2>/dev/null | awk '{print $1}' > "$WORK/$E.sha256" \
    || sha256sum "$WORK/$E.zip" | awk '{print $1}' > "$WORK/$E.sha256"
  SHA="$(cat "$WORK/$E.sha256")"
  if [ "${#SHA}" -eq 64 ] && [ -z "$(printf '%s' "$SHA" | tr -d '0-9a-f')" ]; then
    ok "[$E] E5 digest sha256 sur 64 hex ($SHA)"
  else
    ko "[$E] E5 digest illisible ('$SHA')"
  fi
  # Le GUID que l'artefact PORTE — relu dans le zip, pas déduit du setup.
  ARCH_GUID="$(unzip -l "$WORK/$E.zip" 2>/dev/null \
    | sed -n 's|.*API/API\.\([0-9a-f-]\{36\}\)/API\..*|\1|p' | head -1)"
  printf '%s' "$ARCH_GUID" > "$WORK/$E.guid"
  check "$ARCH_GUID" "$SETUP_GUID" "[$E] E6 le GUID porté par l'artefact est celui de la gateway source"

  # ÉPINGLAGE de l'id-map dans le manifeste — le geste que l'ADR-079 demande de
  # committer. Sans lui, l'import du moteur refuse (IMPORT_REFUSED / guid requis).
  [ -n "$ARCH_GUID" ] || { ko "[$E] GUID introuvable dans l'artefact — phases suivantes impossibles"; continue; }
  sed -i.bak "s|guid: \"\"|guid: \"$ARCH_GUID\"|" "$WORK/$E.promote.yml" && rm -f "$WORK/$E.promote.yml.bak"
  grep -q "guid: \"$ARCH_GUID\"" "$WORK/$E.promote.yml" \
    && ok "[$E] E7 id-map épinglé au manifeste (guid=$ARCH_GUID)" \
    || { ko "[$E] E7 épinglage du guid raté"; continue; }

  # ── PHASE 2 : ZÉRO COUPURE — l'import par le moteur, SOUS CHARGE ──────────
  # Motif T4 d'ADR-079 : l'API est ACTIVE et sert du trafic ; le moteur écrase
  # en place. Aucune désactivation, donc aucune requête perdue.
  say "[$E] phase 2 — ZÉRO COUPURE : import par le moteur pendant 4 voies de charge"
  wait_gw || ko "[$E] gateway indisponible avant l'import sous charge"
  LOG="$WORK/$E.load.log"; : > "$LOG"; END=$(( $(date +%s) + 25 ))
  for _ in 1 2 3 4; do
    ( while [ "$(date +%s)" -lt "$END" ]; do
        printf '%s\n' "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$DP/$API/1.0.0/ping")" >> "$LOG"
      done ) &
  done
  perl -e 'select(undef,undef,undef,3)'          # la charge s'établit d'abord
  engine_import "$E" >"$WORK/$E.import1.log" 2>&1; RC=$?
  wait
  [ "$RC" -eq 0 ] && ok "[$E] Z1 le moteur rend 0 à l'import overwrite" \
                  || ko "[$E] Z1 import rc=$RC — $(tail -3 "$WORK/$E.import1.log" | tr '\n' ' ')"
  grep -qE "PROMOTE_CONFIRMED" "$WORK/$E.import1.log" \
    && ok "[$E] Z2 le moteur prononce PROMOTE_CONFIRMED" \
    || ko "[$E] Z2 PROMOTE_CONFIRMED absent du log du moteur"
  TOT=$(wc -l < "$LOG" | tr -d ' '); BAD=$(grep -cv '^200$' "$LOG" || true)
  if [ "$TOT" -gt 50 ] && [ "$BAD" -eq 0 ]; then
    ok "[$E] Z3 ZÉRO COUPURE : $TOT/$TOT requêtes 200 pendant l'import par le moteur"
  else
    ko "[$E] Z3 coupure détectée ($BAD non-200 / $TOT ; il en faut plus de 50) — $(sort "$LOG" | uniq -c | tr '\n' ' ')"
  fi
  check "$(api_field "$ARCH_GUID" id)" "$ARCH_GUID" "[$E] Z4 GUID INCHANGÉ après l'overwrite"
  check "$(api_field "$ARCH_GUID" isActive)" "true"  "[$E] Z5 l'API est restée ACTIVE (jamais désactivée)"
  # L'artefact route par ${alias} : c'est l'export du moteur qui l'a re-pointé,
  # et l'alias-first de l'import qui a posé la valeur du palier.
  check "$(dp_path "$API")" "/backend/dev/ping" "[$E] Z6 le data-plane route désormais par \${$ALS} (routing ré-écrit PAR LE MOTEUR)"

  # ── PHASE 3 : PALIER VIERGE — GUID ISO ────────────────────────────────────
  # Motif T9 d'ADR-079, poussé d'un cran : on retire l'API *et* son alias, comme
  # un palier qui n'a jamais rien reçu. C'est l'alias-first du moteur qui doit
  # recréer la valeur locale, puis l'import poser l'API — au MÊME GUID.
  # Les gestes de retrait sont de l'EXPLOITATION (curl d'admin), volontairement
  # PAS le moteur : sinon on prouverait que le moteur sait défaire ce qu'il
  # fait, pas qu'il sait arriver sur du vierge.
  say "[$E] phase 3 — PALIER VIERGE : retrait direct, puis import par le moteur"
  wait_gw || ko "[$E] gateway indisponible avant le retrait"
  adm -X PUT "$GW/apis/$ARCH_GUID/deactivate" -o /dev/null
  DC=$(adm -o /dev/null -w '%{http_code}' -X DELETE "$GW/apis/$ARCH_GUID")
  check "$DC" "204" "[$E] V1 retrait direct de l'API (le palier redevient vierge)"
  AID="$(alias_id "$ALS")"
  [ -n "$AID" ] && adm -X DELETE "$GW/alias/$AID" -o /dev/null
  check "$(alias_id "$ALS")" "" "[$E] V2 l'alias du palier a disparu lui aussi (rien de local ne subsiste)"
  check "$(api_id "$API" 1.0.0)" "" "[$E] V3 plus aucune trace de l'API au catalogue"

  wait_gw || ko "[$E] gateway indisponible avant l'import sur palier vierge"
  engine_import "$E" >"$WORK/$E.import2.log" 2>&1; RC=$?
  [ "$RC" -eq 0 ] && ok "[$E] V4 le moteur rend 0 sur un palier vierge" \
                  || ko "[$E] V4 import vierge rc=$RC — $(tail -3 "$WORK/$E.import2.log" | tr '\n' ' ')"
  check "$(alias_uri "$ALS")" "$BACKEND_URL" "[$E] V5 alias-first : le MOTEUR a recréé la valeur locale du palier"
  # LA propriété du GOAL : l'id relu SUR LA GATEWAY est le guid de l'artefact.
  check "$(api_field "$ARCH_GUID" id)"        "$ARCH_GUID" "[$E] V6 GUID ISO sur palier vierge (l'id relu EST le guid épinglé)"
  check "$(api_field "$ARCH_GUID" apiName)"   "$API"       "[$E] V7 c'est bien la bonne API derrière ce GUID"
  check "$(api_field "$ARCH_GUID" isActive)"  "true"       "[$E] V8 elle arrive ACTIVE (piège isActive tenu)"
  check "$(dp_path "$API")" "/backend/dev/ping" "[$E] V9 le data-plane du palier vierge sert par \${$ALS}"
done

# ═════════════════════════════════════════════════════════════════════════════
# CONTRE-ÉPREUVE : la garde UPDATE_FORBIDDEN, hors env d'authoring
# ═════════════════════════════════════════════════════════════════════════════
# POURQUOI PAR LE RÔLE, ET PAS PAR labctl. Côté Go, la garde existe
# (inboundauth.go:935) et son interrupteur `allowDeactivate` est désormais
# projetable depuis un fichier de cibles — il ne l'était pas : `ToConfig()`
# n'émettait jamais la clé, si bien qu'un targets déclarant
# `allowDeactivate: false` ne fermait rien (fail-open corrigé par le lot).
# Mais elle reste hors de portée d'une épreuve LIVE : `setAPIActive(false)`
# n'est appelé que par les deux replis de mise à jour stricte
# (inboundauth.go:909, routing.go:537), c'est-à-dire quand la gateway REFUSE un
# PUT sur une API active — un accident qu'on ne provoque pas sur commande, et
# que le verbe `promote` ne traverse jamais (il ne désactive rien, c'est tout
# son propos). La voie qui s'exerce telle quelle est donc le rôle
# apim_publish_api, dont la garde (main.yml:122) refuse le cycle
# deactivate→PUT→activate hors env d'authoring. Le versant Go — comportement de
# la garde ET projection de son interrupteur — est couvert par ses tests,
# rejoués ci-dessous.
say "contre-épreuve — UPDATE_FORBIDDEN : mettre à jour en place hors authoring est refusé"
# Le témoin est l'asset du PREMIER moteur de la liste, pas un nom en dur : un
# run partiel (ENGINES=labctl pour bisecter) verrait sinon U0 rougir pour une
# raison étrangère à la garde qu'on mesure.
CE_API="g5live-$(printf '%s' "$ENGINES" | awk '{print $1}')-api"
CE_ID="$(api_id "$CE_API" 1.0.0)"
if [ -z "$CE_ID" ]; then
  ko "U0 l'API témoin $CE_API n'existe plus — contre-épreuve impossible"
else
  cat > "$WORK/ce.publish.yml" <<EOF
---
apim_api:
  name: "$CE_API"
  version: "1.0.0"
  contract: "$WORK/contract.yaml"
  team: ""
  update: true
  inbound: {}
EOF
  # apim_pub_require_team / apim_ss_teams_feature : on neutralise le
  # CLOISONNEMENT, pas la garde qu'on mesure. Sans ça le play refuserait en
  # amont (TEAM_UNDEFINED) et le vert dirait « une garde a parlé », pas
  # « CELLE-CI a parlé ».
  ansible-playbook -i "$REPO/ansible/inventory.lab.ini" "$REPO/ansible/publish-api.yml" \
    -e apim_ss_manifest="$WORK/ce.publish.yml" \
    -e apim_ss_env=rec \
    -e apim_pub_require_team=false -e apim_ss_teams_feature=off \
    -e apim_ss_api_base="$GW" -e apim_ss_data_base="$DP" \
    -e apim_ss_wm_user="$WM_USER" -e apim_ss_wm_password="$WM_PASS" \
    -e apim_ss_vault_addr="" >"$WORK/ce.log" 2>&1; RC=$?
  [ "$RC" -ne 0 ] && grep -q "UPDATE_FORBIDDEN" "$WORK/ce.log" \
    && ok "U1 update en place sur 'rec' → UPDATE_FORBIDDEN (le rôle renvoie vers la promotion par archive)" \
    || ko "U1 attendu UPDATE_FORBIDDEN, rc=$RC — $(tail -3 "$WORK/ce.log" | tr '\n' ' ')"
  # La garde ne vaut que si elle n'a RIEN cassé en refusant : l'API doit être
  # restée active, c'est-à-dire que le data-plane n'a pas été coupé.
  check "$(api_field "$CE_ID" isActive)" "true" "U2 l'API est restée ACTIVE malgré le refus (aucune coupure)"
  check "$(dp_path "$CE_API")" "/backend/dev/ping" "U3 le data-plane sert toujours après le refus"
fi
# Le versant Go de la même garde, là où il est atteignable. Les DEUX paquets :
# `webmethods` porte le comportement de la garde, `targets` la projection de son
# interrupteur — c'est la couture entre les deux qui abritait le fail-open.
( cd "$REPO/labctl" && GOPROXY=off GOFLAGS=-mod=vendor \
    go test ./internal/adapter/webmethods/ ./internal/targets/ -count=1 ) >"$WORK/gotest.log" 2>&1 \
  && ok "U4 côté labctl : garde UPDATE_FORBIDDEN + projection d'allowDeactivate vertes (webmethods + targets)" \
  || ko "U4 go test en échec — $(tail -5 "$WORK/gotest.log" | tr '\n' ' ')"

# ── bilan ────────────────────────────────────────────────────────────────────
say "BILAN"
[ "$GW_RECYCLES" -gt 0 ] && printf '  ⏳ recyclages de la gateway absorbés : %d\n' "$GW_RECYCLES"
printf '  moteurs éprouvés : %s\n' "$ENGINES"
printf '  PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
