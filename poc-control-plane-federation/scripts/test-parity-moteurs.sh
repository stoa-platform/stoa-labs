#!/usr/bin/env bash
# test-parity-moteurs.sh — LA porte du GOAL G8 : les deux moteurs du verbe
# archive (`apim_promote_api` côté client, `labctl promote` côté lab), sur le
# MÊME manifeste, produisent un état de gateway IDENTIQUE sur les champs du
# registre — et un moteur volontairement muté fait ROUGIR la parité.
#
# CE QUE G5 NE PROUVAIT PAS. test-promote-verb-live.sh éprouve chaque moteur
# sur des assets SÉPARÉS avec les mêmes assertions : il prouve que chacun
# tient le contrat du verbe, jamais que les deux produisent le même état. Ici,
# UN seul manifeste, UNE seule archive d'import, et le verdict est un DIFF de
# snapshots — pas une liste d'assertions par moteur.
#
# LE REGISTRE. scripts/testdata/parity-ecarts.txt liste les écarts ASSUMÉS
# (chemins d'état exclus du diff, motifs volatils des artefacts), chacun avec
# sa raison mesurée. Un écart inconnu n'est PAS dans le fichier, donc il
# rougit : « un écart documenté est acceptable, un écart inconnu ne l'est
# pas » (GOAL G8) devient une propriété mécanique.
#
#   ./scripts/test-parity-moteurs.sh
#   GW_ADMIN=http://localhost:5555/rest/apigateway GW_DATA=http://localhost:5555/gateway \
#   WM_USER=Administrator WM_PASS=manage VAULT_ADDR=http://localhost:8200 \
#   VAULT_TOKEN=... ./scripts/test-parity-moteurs.sh
#
# ⚠ La gateway du lab est recyclée par un keepalive (~20 min) : wait_gw avant
# chaque phase — un rouge doit vouloir dire « la parité est cassée », jamais
# « le conteneur redémarrait ».
# L'idiome `test && ok || ko` du harnais est voulu : `ok` (printf+compteur) ne
# peut pas échouer, donc le `||` ne double-compte jamais — même régime que
# test-deployer-gate-live.sh.
# shellcheck disable=SC2015
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
GW="${GW_ADMIN:-http://localhost:5555/rest/apigateway}"
DP="${GW_DATA:-http://localhost:5555/gateway}"
WM_USER="${WM_USER:-Administrator}"
WM_PASS="${WM_PASS:-manage}"
AUTH="$WM_USER:$WM_PASS"
# adminUrl de labctl : SANS /rest/apigateway (l'adaptateur l'ajoute) — piège §8
# de team-promote.sh.
ADMIN_ROOT="${GW%/}"; ADMIN_ROOT="${ADMIN_ROOT%/rest/apigateway}"
# Le backend per-env, joignable depuis la GATEWAY (réseau compose).
BACKEND_URL="${BACKEND_URL:-http://poc-token-echo:8080/backend/rec}"
VAULT="${VAULT_ADDR:-http://localhost:8200}"
VTOK="${VAULT_TOKEN:-stoa-root-token}"
REG="$REPO/scripts/testdata/parity-ecarts.txt"

WORK="$(mktemp -d /tmp/g8par.XXXXXX)"
PASS=0; FAIL=0
API=g8par-api; BALS=g8par-backend; CALS=g8par-backend-creds
GALS=g8par-flag; AS=g8par-as; SCOPE_NAME="g8par-api:1.0.0"
PIN_GUID=""

say()  { printf '\n== %s ==\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko()   { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else ko "$3 (attendu '$2', obtenu '$1')"; fi; }
adm()  { curl -sS -u "$AUTH" -H "Accept: application/json" "$@"; }

# ── outillage gateway (motif G5) ─────────────────────────────────────────────
api_id()   { adm "$GW/apis" | jq -r --arg n "$1" --arg v "$2" \
               '[.apiResponse[].api | select(.apiName==$n and .apiVersion==$v) | .id][0] // empty'; }
alias_id() { adm "$GW/alias" | jq -r --arg n "$1" '[(.alias // [])[] | select(.name==$n) | .id][0] // empty'; }
dp_path()  { curl -sS -m 8 "$DP/$API/1.0.0/ping" | jq -r '.path // empty'; }

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

scope_id() { adm "$GW/scopes" | jq -r --arg n "$SCOPE_NAME" '[.scopes[]? | select(.scopeName==$n) | .id][0] // empty'; }

# fresh_window — le trial wM expire ~25 min et le keepalive le recycle à
# 23 min d'uptime (wm-keepalive.sh) : un run lancé tard dans la fenêtre voit
# la gateway mourir EN PLEIN import (mesuré : run du 2026-08-27, rc=2 au
# milieu du play). Si l'uptime dépasse le seuil, on attend le recyclage et on
# repart d'une fenêtre fraîche — motif G7 (saut #21 lancé après cycle frais).
fresh_window() {
  local dk="" c="${WM_CONTAINER:-poc-webmethods-real}" st ep up i
  command -v docker >/dev/null 2>&1 && dk=docker
  [ -z "$dk" ] && [ -x /opt/homebrew/bin/docker ] && dk=/opt/homebrew/bin/docker
  [ -z "$dk" ] && { printf '  ⚠ docker introuvable — fenêtre keepalive non mesurable, on tente\n'; return 0; }
  st="$("$dk" inspect "$c" --format '{{.State.StartedAt}}' 2>/dev/null)" || return 0
  st="${st%.*}"; st="${st%Z}"
  ep="$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$st" +%s 2>/dev/null || date -u -d "$st" +%s 2>/dev/null || echo 0)"
  [ "$ep" = "0" ] && return 0
  up=$(( ( $(date +%s) - ep ) / 60 ))
  if [ "$up" -lt 12 ]; then
    printf '  ⏱ fenêtre keepalive fraîche (uptime %dmin)\n' "$up"
    return 0
  fi
  printf '  ⏱ uptime %dmin ≥ 12 — attente du recyclage keepalive avant de lancer le verbe…\n' "$up"
  i=0
  while [ "$i" -lt 200 ]; do
    sleep 9
    local st2
    st2="$("$dk" inspect "$c" --format '{{.State.StartedAt}}' 2>/dev/null)"; st2="${st2%.*}"; st2="${st2%Z}"
    [ "$st2" != "$st" ] && { printf '  ⏱ gateway recyclée, attente du retour de service…\n'; wait_gw; return 0; }
    i=$((i+1))
  done
  printf '  ⚠ pas de recyclage observé en 30 min — on tente dans la fenêtre courante\n'
  return 0
}

# wipe_target — remet le palier à VIERGE pour l'API du manifeste : API,
# aliases per-env (backend/creds/générique) et scope-mapping. L'AS reste :
# il est env-local, posé par l'init d'env, pas par le moteur.
wipe_target() {
  local id n
  id="$(api_id "$API" 1.0.0)"
  if [ -n "$id" ]; then
    adm -X PUT "$GW/apis/$id/deactivate" -o /dev/null
    adm -X DELETE "$GW/apis/$id" -o /dev/null
  fi
  for n in "$BALS" "$CALS" "$GALS"; do
    id="$(alias_id "$n")"; [ -n "$id" ] && adm -X DELETE "$GW/alias/$id" -o /dev/null
  done
  id="$(scope_id)"; [ -n "$id" ] && adm -X DELETE "$GW/scopes/$id" -o /dev/null
  return 0
}

cleanup() {
  say "cleanup (assets jetables g8par-*)"
  wipe_target
  local id
  id="$(alias_id "$AS")"; [ -n "$id" ] && adm -X DELETE "$GW/alias/$id" -o /dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── préflight ────────────────────────────────────────────────────────────────
say "préflight : gateway, Vault, outils, moteurs"
wait_gw || { ko "la gateway d'admin ne répond pas sur $GW"; exit 1; }
ok "gateway d'admin joignable ($GW)"
fresh_window
for T in jq zip unzip zipinfo python3 ansible-playbook go; do
  command -v "$T" >/dev/null 2>&1 || { ko "outil requis absent : $T"; exit 1; }
done
[ -f "$REG" ] || { ko "registre absent : $REG"; exit 1; }
ok "registre des écarts présent ($REG)"
VH="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$VAULT/v1/sys/health")"
[ "$VH" = "200" ] || { ko "Vault injoignable sur $VAULT (http $VH) — la parité couvre cred_alias, Vault est requis"; exit 1; }
ok "Vault joignable ($VAULT)"
( cd "$REPO/labctl" && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$WORK/labctl" . ) \
  || { ko "build de labctl"; exit 1; }
ok "labctl construit ($WORK/labctl)"

# ── seed Vault : creds backend jetables de l'env rec ─────────────────────────
SEED="$(curl -sS -o /dev/null -w '%{http_code}' -H "X-Vault-Token: $VTOK" -X POST \
  -d '{"data":{"username":"g8par-user","password":"g8par-pass"}}' \
  "$VAULT/v1/secret/data/stoa/envs/rec/backends/g8par")"
{ [ "$SEED" = "200" ] || [ "$SEED" = "204" ]; } \
  && ok "Vault seedé : stoa/envs/rec/backends/g8par (http $SEED)" \
  || { ko "seed Vault refusé (http $SEED)"; exit 1; }

# ── setup : AS env-local + API source ACTIVE routée backend littéral ─────────
say "setup : purge g8par-*, AS env-local, API source active"
wipe_target
ASID="$(alias_id "$AS")"
if [ -z "$ASID" ]; then
  # Shape authServerAlias : celle que labctl projette (inboundauth.go:441) —
  # l'AS n'est référencé par le scope-mapping QUE par nom.
  ASID="$(adm -H "Content-Type: application/json" -X POST "$GW/alias" -d '{
    "name":"'"$AS"'","type":"authServerAlias",
    "localIntrospectionConfig":{"issuer":"https://g8par.invalid","jwksuri":"https://g8par.invalid/jwks"}}' \
    | jq -r '.id // .alias.id // empty')"
fi
[ -n "$ASID" ] && ok "AS env-local présent ($AS, $ASID)" || { ko "création de l'AS $AS"; exit 1; }

# Le contrat : servers LITTÉRAL — c'est l'export du moteur qui re-pointe le
# routing sur ${alias} (lui voler ce geste fausserait la mesure, motif G5).
cat > "$WORK/contract.yaml" <<'EOF'
openapi: 3.0.0
info: { title: g8par, version: 1.0.0 }
servers: [ { url: "http://poc-token-echo:8080" } ]
paths: { /ping: { get: { operationId: ping, responses: { '200': { description: ok } } } } }
EOF

SRC_ID=$(adm -F "file=@$WORK/contract.yaml;type=application/x-yaml" -F type=openapi \
  -F "apiName=$API" -F apiVersion=1.0.0 "$GW/apis" \
  | jq -r '.apiResponse.api.id // empty')
[ -n "$SRC_ID" ] || { ko "création de l'API source $API"; exit 1; }
adm -X PUT "$GW/apis/$SRC_ID/activate" -o /dev/null
ok "API source ACTIVE $API ($SRC_ID)"

# ── LE manifeste partagé — un seul fichier pour les deux moteurs ─────────────
cat > "$WORK/parity.promote.yml" <<EOF
---
apim_promote:
  name: "$API"
  version: "1.0.0"
  guid: ""
  overwrite: "apis,policies,policyactions"
  backend_alias:
    name: "$BALS"
  cred_alias:
    name: "$CALS"
    auth_type: "HTTP_BASIC"
  aliases:
    - name: "$GALS"
      record: { type: "simple", value: "g8par" }
  scope_mapping:
    external_scope: "g8par.read"
    auth_server_alias: "$AS"
  per_env:
    rec:
      backend_alias: { url: "$BACKEND_URL" }
      cred_alias:    { vault_sub: "envs/rec/backends/g8par" }
EOF

cat > "$WORK/targets.yaml" <<EOF
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

# ── les invocations des moteurs, et elles seules ─────────────────────────────
engine_export() { # $1 = ansible|labctl ; $2 = archive de sortie
  case "$1" in
    ansible)
      ansible-playbook -i "$REPO/ansible/inventory.lab.ini" "$REPO/ansible/promote-api.yml" \
        -e apim_promote_action=export \
        -e apim_promote_manifest="$WORK/parity.promote.yml" \
        -e apim_ss_archive_pin="$2" \
        -e apim_ss_env=rec \
        -e apim_ss_api_base="$GW" -e apim_ss_data_base="$DP" \
        -e apim_ss_wm_user="$WM_USER" -e apim_ss_wm_password="$WM_PASS" \
        -e apim_ss_vault_addr=""
      ;;
    labctl)
      "$WORK/labctl" promote --manifest "$WORK/parity.promote.yml" --env rec \
        --action export --archive "$2" -f "$WORK/targets.yaml"
      ;;
  esac
}

engine_import() { # $1 = ansible|labctl|ansible-mut|labctl-mut ; archive = A.zip
  case "$1" in
    ansible|ansible-mut)
      local PB="$REPO/ansible/promote-api.yml"
      [ "$1" = "ansible-mut" ] && PB="$WORK/ansible-mut/promote-api.yml"
      VAULT_ADDR="" VAULT_TOKEN="" ansible-playbook -i "$REPO/ansible/inventory.lab.ini" "$PB" \
        -e apim_promote_action=import \
        -e apim_promote_manifest="$WORK/parity.promote.yml" \
        -e apim_ss_archive_pin="$WORK/A.zip" \
        -e apim_ss_archive_sha256="$(cat "$WORK/A.sha256")" \
        -e apim_ss_env=rec -e apim_ss_authoring_env=dev \
        -e apim_ss_api_base="$GW" -e apim_ss_data_base="$DP" \
        -e apim_ss_wm_user="$WM_USER" -e apim_ss_wm_password="$WM_PASS" \
        -e apim_ss_vault_addr="$VAULT" -e apim_ss_vault_token="$VTOK"
      ;;
    labctl|labctl-mut)
      local BIN="$WORK/labctl"
      [ "$1" = "labctl-mut" ] && BIN="$WORK/labctl-mutbin"
      VAULT_ADDR="$VAULT" VAULT_TOKEN="$VTOK" \
        "$BIN" promote --manifest "$WORK/parity.promote.yml" --env rec \
        --action import --archive "$WORK/A.zip" -f "$WORK/targets.yaml"
      ;;
  esac
}

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 1 — EXPORT PAR LES DEUX MOTEURS : parité d'ARTEFACT
# ═════════════════════════════════════════════════════════════════════════════
say "phase 1 — EXPORT ×2 : même API source, deux sanitizers, artefacts comparés"
wait_gw || ko "gateway indisponible avant l'export"
engine_export ansible "$WORK/A.zip" > "$WORK/export.ansible.log" 2>&1; RCA=$?
engine_export labctl  "$WORK/B.zip" > "$WORK/export.labctl.log"  2>&1; RCB=$?
[ "$RCA" -eq 0 ] && ok "E1 export ansible rc=0" || ko "E1 export ansible rc=$RCA — $(tail -3 "$WORK/export.ansible.log" | tr '\n' ' ')"
[ "$RCB" -eq 0 ] && ok "E2 export labctl rc=0"  || ko "E2 export labctl rc=$RCB — $(tail -3 "$WORK/export.labctl.log" | tr '\n' ' ')"
[ -s "$WORK/A.zip" ] && [ -s "$WORK/B.zip" ] || { ko "E3 artefact manquant"; exit 1; }
ok "E3 deux artefacts produits"

# norm — applique aux entrées TEXTE les motifs `artifact` du registre.
norm() { # $1 = fichier
  local kind pat _reason
  while IFS=$'\t' read -r kind pat _reason; do
    case "$kind" in \#*|"") continue ;; esac
    [ "$kind" = "artifact" ] || continue
    LC_ALL=C sed -E -i.bak "$pat" "$1" && rm -f "$1.bak"
  done < "$REG"
}

zipinfo -1 "$WORK/A.zip" | sort > "$WORK/A.toc"
zipinfo -1 "$WORK/B.zip" | sort > "$WORK/B.toc"
if diff -u "$WORK/A.toc" "$WORK/B.toc" > "$WORK/toc.diff"; then
  ok "E4 même liste d'entrées ($(wc -l < "$WORK/A.toc" | tr -d ' ') entrées)"
else
  ko "E4 listes d'entrées divergentes — $(tr '\n' ' ' < "$WORK/toc.diff")"
fi
ENTRY_DIVERGENT=0
while IFS= read -r entry; do
  case "$entry" in */) continue ;; esac
  unzip -p "$WORK/A.zip" "$entry" > "$WORK/ea" 2>/dev/null
  unzip -p "$WORK/B.zip" "$entry" > "$WORK/eb" 2>/dev/null
  # Les entrées JSON se comparent en DOCUMENTS (clés triées), pas en octets :
  # les deux sanitizers ré-écrivent le routing avec un ordre de clés qui leur
  # est propre (python dict vs Go map, mesuré 2026-08-27) — l'ordre des clés
  # JSON n'est pas un contenu. Tout le reste se compare octet à octet.
  if jq -e . "$WORK/ea" > "$WORK/ea.c" 2>/dev/null && jq -e . "$WORK/eb" > "$WORK/eb.c" 2>/dev/null; then
    jq -S . "$WORK/ea" > "$WORK/ea.c"; mv "$WORK/ea.c" "$WORK/ea"
    jq -S . "$WORK/eb" > "$WORK/eb.c"; mv "$WORK/eb.c" "$WORK/eb"
  fi
  rm -f "$WORK/ea.c" "$WORK/eb.c"
  norm "$WORK/ea"; norm "$WORK/eb"
  if ! cmp -s "$WORK/ea" "$WORK/eb"; then
    ENTRY_DIVERGENT=$((ENTRY_DIVERGENT+1))
    printf '  ↯ ARTIFACT_DIVERGENT: %s\n' "$entry"
    diff <(head -c 2000 "$WORK/ea") <(head -c 2000 "$WORK/eb") | head -10
  fi
done < "$WORK/A.toc"
[ "$ENTRY_DIVERGENT" -eq 0 ] \
  && ok "E5 contenu identique entrée par entrée (sous registre artifact)" \
  || ko "E5 $ENTRY_DIVERGENT entrée(s) divergente(s) hors registre"

# GUID porté par l'artefact d'import (A.zip) — relu du zip, épinglé au manifeste.
PIN_GUID="$(unzip -l "$WORK/A.zip" 2>/dev/null \
  | sed -n 's|.*API/API\.\([0-9a-f-]\{36\}\)/API\..*|\1|p' | head -1)"
check "$PIN_GUID" "$SRC_ID" "E6 le GUID de l'artefact est celui de la gateway source"
[ -n "$PIN_GUID" ] || { ko "GUID introuvable — suite impossible"; exit 1; }
sed -i.bak "s|guid: \"\"|guid: \"$PIN_GUID\"|" "$WORK/parity.promote.yml" && rm -f "$WORK/parity.promote.yml.bak"
grep -q "guid: \"$PIN_GUID\"" "$WORK/parity.promote.yml" \
  && ok "E7 id-map épinglé au manifeste partagé" || { ko "E7 épinglage raté"; exit 1; }
shasum -a 256 "$WORK/A.zip" 2>/dev/null | awk '{print $1}' > "$WORK/A.sha256" \
  || sha256sum "$WORK/A.zip" | awk '{print $1}' > "$WORK/A.sha256"
[ "$(wc -c < "$WORK/A.sha256" | tr -d ' ')" = "65" ] \
  && ok "E8 digest de l'archive d'import pinné ($(cat "$WORK/A.sha256"))" \
  || ko "E8 digest illisible"

# ═════════════════════════════════════════════════════════════════════════════
# LE SNAPSHOT — les champs du registre, mêmes lectures pour A et B
# ═════════════════════════════════════════════════════════════════════════════
# strip_registered — retire des snapshots les chemins `state` du registre.
strip_registered() { # $1 = snapshot json, modifié en place
  local kind p _reason
  while IFS=$'\t' read -r kind p _reason; do
    case "$kind" in \#*|"") continue ;; esac
    [ "$kind" = "state" ] || continue
    jq "del($p)" "$1" > "$1.t" && mv "$1.t" "$1"
  done < "$REG"
}

snapshot() { # $1 = fichier de sortie
  local api actions policies aliases scope dp pol prec act
  api="$(adm "$GW/apis/$PIN_GUID" | jq '.apiResponse.api // empty')"
  if [ -z "$api" ]; then
    # FAIL-CLOSED : un snapshot pris pendant un recyclage serait un état
    # fantôme qui fausserait le diff dans un sens ou l'autre (mesuré :
    # « snapshot A pris ( actions, dp=) » sur gateway morte). On attend le
    # retour et on relit UNE fois ; sinon rouge.
    wait_gw
    api="$(adm "$GW/apis/$PIN_GUID" | jq '.apiResponse.api // empty')"
    [ -z "$api" ] && { ko "SNAPSHOT_UNREADABLE : /apis/$PIN_GUID illisible ($1)"; printf '{}' > "$1"; return 1; }
  fi
  # Le graphe de politiques — shapes MESURÉES 2026-08-27 sur le produit :
  # /policies/{id} → .policy.policyEnforcements[].enforcements[]
  #   .enforcementObjectId ; /policyActions/{id} → .policyAction (templateKey,
  # parameters — dont le routing ${alias}).
  policies='[]'; actions='[]'
  for pol in $(printf '%s' "$api" | jq -r '.policies[]?' | sort); do
    prec="$(adm "$GW/policies/$pol" | jq '.policy')"
    policies="$(printf '%s' "$policies" | jq --argjson p "$prec" '. + [$p]')"
    for act in $(printf '%s' "$prec" \
      | jq -r '[.policyEnforcements[]?.enforcements[]?.enforcementObjectId] | sort | .[]'); do
      actions="$(printf '%s' "$actions" \
        | jq --argjson a "$(adm "$GW/policyActions/$act" | jq '.policyAction')" '. + [$a]')"
    done
  done
  aliases="$(adm "$GW/alias" | jq --arg b "$BALS" --arg c "$CALS" --arg g "$GALS" \
    '[.alias[] | select(.name==$b or .name==$c or .name==$g)] | sort_by(.name)')"
  scope="$(adm "$GW/scopes" | jq --arg n "$SCOPE_NAME" \
    '[.scopes[]? | select(.scopeName==$n)] | first // {}')"
  dp="$(curl -sS -m 8 "$DP/$API/1.0.0/ping" | jq -c '.path // ""')"
  jq -n --argjson api "$api" --argjson policies "$policies" --argjson actions "$actions" \
        --argjson aliases "$aliases" --argjson scope "$scope" --argjson dp "${dp:-\"\"}" \
        '{api:$api, policies:($policies|sort_by(.id)), actions:($actions|sort_by(.id)),
          aliases:$aliases, scope:$scope, dp:$dp}' > "$1"
  strip_registered "$1"
}

# parity_diff — le verdict : chemins feuilles qui divergent, rc≠0 si écart.
parity_diff() { # $1=snapshot A  $2=snapshot B
  jq -n --slurpfile a "$1" --slurpfile b "$2" '
    def leaves: paths(scalars) as $p | {($p|map(tostring)|join(".")): getpath($p)};
    ([$a[0]|leaves] | add // {}) as $A | ([$b[0]|leaves] | add // {}) as $B
    | [ ((($A|keys) + ($B|keys))|unique[]) | select($A[.] != $B[.])
        | {champ:., gauche:$A[.], droite:$B[.]} ]' > "$WORK/parity.diff.json"
  jq -e 'length == 0' "$WORK/parity.diff.json" > /dev/null
}

# ═════════════════════════════════════════════════════════════════════════════
# PHASES 2-3 — IMPORT PAR CHAQUE MOTEUR, à ARCHIVE ÉGALE, palier vierge
# ═════════════════════════════════════════════════════════════════════════════
say "phase 2 — palier VIERGE puis import par le RÔLE (archive A, digest pinné)"
wait_gw || ko "gateway indisponible avant l'import ansible"
wipe_target
engine_import ansible > "$WORK/import.ansible.log" 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "I1 le rôle rend 0 (PROMOTE_CONFIRMED)" \
                || ko "I1 import ansible rc=$RC — $(tail -3 "$WORK/import.ansible.log" | tr '\n' ' ')"
snapshot "$WORK/snap-ansible.json"
ok "I2 snapshot A pris ($(jq -r '.actions|length' "$WORK/snap-ansible.json") actions, dp=$(jq -r '.dp' "$WORK/snap-ansible.json"))"

say "phase 3 — palier remis à VIERGE puis import par LABCTL (même archive A)"
wait_gw || ko "gateway indisponible avant l'import labctl"
wipe_target
engine_import labctl > "$WORK/import.labctl.log" 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "I3 labctl rend 0 (PROMOTE_CONFIRMED)" \
                || ko "I3 import labctl rc=$RC — $(tail -3 "$WORK/import.labctl.log" | tr '\n' ' ')"
snapshot "$WORK/snap-labctl.json"
ok "I4 snapshot B pris ($(jq -r '.actions|length' "$WORK/snap-labctl.json") actions, dp=$(jq -r '.dp' "$WORK/snap-labctl.json"))"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 4 — LA PORTE : un seul état
# ═════════════════════════════════════════════════════════════════════════════
say "phase 4 — PARITÉ : diff des snapshots sous registre"
if parity_diff "$WORK/snap-ansible.json" "$WORK/snap-labctl.json"; then
  ok "P1 les deux moteurs produisent le MÊME état de gateway (champs du registre)"
else
  ko "P1 écart(s) hors registre :"
  jq -r '.[] | "     \(.champ): ansible=\(.gauche) labctl=\(.droite)"' "$WORK/parity.diff.json"
fi
jq -e '.api.id == "'"$PIN_GUID"'" and .api.isActive == true' "$WORK/snap-labctl.json" > /dev/null \
  && ok "P2 l'état commun est bien le GUID épinglé, ACTIF" \
  || ko "P2 l'état final ne porte pas le guid épinglé actif"
check "$(jq -r '.dp' "$WORK/snap-labctl.json")" "/backend/rec/ping" \
  "P3 le data-plane route par \${$BALS} vers le backend de rec (les deux snapshots l'ont déjà comparé)"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 5 — LA PORTE SE REJOUE : verify par les DEUX moteurs, sans écrire
# ═════════════════════════════════════════════════════════════════════════════
say "phase 5 — VERIFY rejouable : --tags verify (rôle) et --action verify (labctl)"
wait_gw || ko "gateway indisponible avant verify"
ansible-playbook -i "$REPO/ansible/inventory.lab.ini" "$REPO/ansible/promote-api-verify.yml" \
  -e apim_promote_manifest="$WORK/parity.promote.yml" -e apim_ss_env=rec \
  -e apim_ss_api_base="$GW" -e apim_ss_data_base="$DP" \
  -e apim_ss_wm_user="$WM_USER" -e apim_ss_wm_password="$WM_PASS" \
  -e apim_ss_vault_addr="" > "$WORK/verify.ansible.log" 2>&1; RC=$?
[ "$RC" -eq 0 ] && grep -q "PROMOTE_CONFIRMED" "$WORK/verify.ansible.log" \
  && ok "V1 rôle : le --tags verify rejoue PROMOTE_CONFIRMED" \
  || ko "V1 verify ansible rc=$RC — $(tail -3 "$WORK/verify.ansible.log" | tr '\n' ' ')"
"$WORK/labctl" promote --manifest "$WORK/parity.promote.yml" --env rec \
  --action verify -f "$WORK/targets.yaml" > "$WORK/verify.labctl.log" 2>&1; RC=$?
[ "$RC" -eq 0 ] && grep -q "PROMOTE_CONFIRMED" "$WORK/verify.labctl.log" \
  && ok "V2 labctl : --action verify rejoue PROMOTE_CONFIRMED" \
  || ko "V2 verify labctl rc=$RC — $(tail -3 "$WORK/verify.labctl.log" | tr '\n' ' ')"
snapshot "$WORK/snap-after-verify.json"
if parity_diff "$WORK/snap-labctl.json" "$WORK/snap-after-verify.json"; then
  ok "V3 verify n'a RIEN écrit (snapshot identique avant/après)"
else
  ko "V3 verify a modifié l'état :"
  jq -r '.[] | "     \(.champ): avant=\(.gauche) après=\(.droite)"' "$WORK/parity.diff.json"
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 6 — CONTRE-ÉPREUVES : un moteur muté DOIT faire rougir la parité
# ═════════════════════════════════════════════════════════════════════════════
# Motif F1 : une parité qui ne rougit jamais ne prouve rien. Deux mutations
# volontaires (le scope-mapping sauté), une par moteur, sur des COPIES — le
# diff doit être non vide ET nommer le champ muté.
fresh_window
say "phase 6a — MUTATION labctl : parité attendue ROUGE"
cp -R "$REPO/labctl" "$WORK/labctl-mut"
MUT_GO='if spec.ScopeMapping.ExternalScope != "" || spec.ScopeMapping.AuthServerAlias != "" {'
if grep -qF "$MUT_GO" "$WORK/labctl-mut/cmd/labctl/promote.go"; then
  ok "M0a ancre de mutation labctl trouvée"
else
  ko "M0a motif de mutation introuvable — promote.go a changé, ré-ancrer la contre-épreuve"
fi
MUT_GO="$MUT_GO" python3 - "$WORK/labctl-mut/cmd/labctl/promote.go" <<'PYEOF'
import os, sys
p = sys.argv[1]; s = open(p).read()
s = s.replace(os.environ["MUT_GO"], 'if false {', 1)
open(p, 'w').write(s)
PYEOF
( cd "$WORK/labctl-mut" && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$WORK/labctl-mutbin" . ) \
  || ko "M0a build du labctl muté"
wait_gw || ko "gateway indisponible avant l'import muté labctl"
wipe_target
engine_import labctl-mut > "$WORK/import.mut-labctl.log" 2>&1 \
  || ko "M1 l'import muté labctl a échoué avant la mesure — $(tail -3 "$WORK/import.mut-labctl.log" | tr '\n' ' ')"
snapshot "$WORK/snap-mut-labctl.json"
if parity_diff "$WORK/snap-ansible.json" "$WORK/snap-mut-labctl.json"; then
  ko "M1 la parité N'A PAS rougi sur un labctl muté (elle ne prouve rien — motif F1)"
else
  if jq -e '[.[] | select(.champ | startswith("scope"))] | length > 0' "$WORK/parity.diff.json" > /dev/null; then
    ok "M1 mutation labctl (scope sauté) → parité ROUGE, champ nommé ($(jq -r 'length' "$WORK/parity.diff.json") écart(s))"
  else
    ko "M1 la parité a rougi, mais sans nommer le scope muté : $(jq -c '.' "$WORK/parity.diff.json" | head -c 300)"
  fi
fi

say "phase 6b — MUTATION rôle : l'autre sens doit rougir aussi"
cp -R "$REPO/ansible" "$WORK/ansible-mut"
IMP="$WORK/ansible-mut/roles/apim_promote_api/tasks/import.yml"
MUT_YML='when: "(apim_promote.scope_mapping | default({})) | length > 0"'
if grep -qF "$MUT_YML" "$IMP"; then
  ok "M0b ancre de mutation rôle trouvée"
else
  ko "M0b motif de mutation rôle introuvable — import.yml a changé, ré-ancrer la contre-épreuve"
fi
MUT_YML="$MUT_YML" python3 - "$IMP" <<'PYEOF'
import os, sys
p = sys.argv[1]; s = open(p).read()
s = s.replace(os.environ["MUT_YML"], 'when: false', 1)
open(p, 'w').write(s)
PYEOF
wait_gw || ko "gateway indisponible avant l'import muté ansible"
wipe_target
engine_import ansible-mut > "$WORK/import.mut-ansible.log" 2>&1 \
  || ko "M2 l'import muté ansible a échoué avant la mesure — $(tail -3 "$WORK/import.mut-ansible.log" | tr '\n' ' ')"
snapshot "$WORK/snap-mut-ansible.json"
if parity_diff "$WORK/snap-mut-ansible.json" "$WORK/snap-labctl.json"; then
  ko "M2 la parité N'A PAS rougi sur un rôle muté"
else
  if jq -e '[.[] | select(.champ | startswith("scope"))] | length > 0' "$WORK/parity.diff.json" > /dev/null; then
    ok "M2 mutation rôle (scope sauté) → parité ROUGE, champ nommé ($(jq -r 'length' "$WORK/parity.diff.json") écart(s))"
  else
    ko "M2 la parité a rougi, mais sans nommer le scope muté : $(jq -c '.' "$WORK/parity.diff.json" | head -c 300)"
  fi
fi

# ── bilan ────────────────────────────────────────────────────────────────────
say "BILAN"
[ "$GW_RECYCLES" -gt 0 ] && printf '  ⏳ recyclages de la gateway absorbés : %d\n' "$GW_RECYCLES"
printf '  PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
