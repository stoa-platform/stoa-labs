#!/usr/bin/env bash
# test-publish-version.sh — preuve X/X de la Task 6 (P3) : le rôle
# apim_publish_api apprend la NOUVELLE VERSION (create-or-version).
#
# TERRAIN : 100 % HORS LIGNE, contre le mock webMethods de la Task 2
# (mocks/webmethods, qui reproduit fidèlement les faits mesurés le 2026-08-05
# sur la vraie 10.15 : corps {newApiVersion}, retainApplications sensible à la
# casse et silencieux quand mal casé, policies clonées, mint depuis la
# DERNIÈRE version seulement). Aucun appel à la gateway réelle, aucun secret.
#
#   PORT : jamais 5555 (la vraie gateway du lab). Un port LIBRE est demandé au
#   noyau à chaque run (surchargeable par MOCK_PORT) ; le script REFUSE de
#   démarrer si ce port répond déjà — leçon du rapport T2 (un mock d'une manche
#   précédente resté vivant avait produit un diagnostic faux).
#
# Chaque section repart d'un mock VIERGE (store en mémoire) : les cas sont
# hermétiques, l'ordre n'a pas d'importance, et une section qui échoue ne
# contamine pas la suivante.
#
#   ./scripts/test-publish-version.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# Port LIBRE demandé au noyau plutôt qu'un numéro en dur : le scratchpad est
# partagé entre agents et un 18790 figé a déjà provoqué des collisions. Tout le
# reste (logs compris) vit dans $TMP, unique par run (mktemp).
MOCK_PORT="${MOCK_PORT:-$(python3 -c "import socket
s=socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1]); s.close()")}"
BASE="http://localhost:${MOCK_PORT}/rest/apigateway"
DP="http://localhost:${MOCK_PORT}/gateway"
TMP="$(mktemp -d "/tmp/p3t6-$$-XXXXXX")"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

MOCK_PID=""
cleanup(){
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

API_NAME="p3t6-api"
# Le commit d'AVANT ce lot (base du palier) — sert de témoin de non-régression.
BASE_COMMIT="${BASE_COMMIT:-1cc0351}"
# Tête du round 1 : sert de témoin AVANT pour les défauts trouvés en revue
# (crash-consistance, capture cross-lignée) — le repro doit être VU rouge.
ROUND1_COMMIT="${ROUND1_COMMIT:-bd65c43}"
# Tête du round 1 fix : témoin AVANT des défauts que CE round ferme.
ROUND1V2_COMMIT="${ROUND1V2_COMMIT:-f5d64f8}"
# Tête d'avant la revue FINALE : témoin AVANT de la capture exact-match.
ROUND2_COMMIT="${ROUND2_COMMIT:-7b0d636}"
# Équipe au nom de laquelle la chaîne publie (posée par le JOB en production,
# `-e apim_ss_team` — jamais par le manifeste, cf. team-name.yml).
TEAM="payments-team"
# La surface d'admin du mock exige la même auth basic que la 10.15 (défauts du
# rôle : Administrator/manage) — sans elle, TOUTE lecture d'état rend
# {"error":"Unauthorized"} et les témoins seraient vides sans le dire.
adm(){ curl -s -m 10 -u Administrator:manage -H 'Accept: application/json' "$@"; }

# ── outillage ────────────────────────────────────────────────────────────────
mock_stop(){
  if [ -n "$MOCK_PID" ]; then kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; MOCK_PID=""; fi
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -o /dev/null -m 1 "http://localhost:${MOCK_PORT}/health" || return 0
    sleep 0.3
  done
}
mock_start(){
  LISTEN_ADDR=":${MOCK_PORT}" "$TMP/wmmock" >"$TMP/mock.log" 2>&1 &
  MOCK_PID=$!
  for _ in $(seq 1 40); do
    if curl -s -o /dev/null -m 1 "http://localhost:${MOCK_PORT}/health"; then
      # Un /health qui répond ne prouve pas que c'est NOTRE mock : un rescapé
      # d'une manche précédente tiendrait le port et le nôtre serait mort sur
      # « address already in use ». Le run entier parlerait alors à un store
      # inconnu — exactement le faux diagnostic du rapport T2.
      kill -0 "$MOCK_PID" 2>/dev/null && return 0
      echo "ERREUR: /health répond sur :${MOCK_PORT} mais notre mock est MORT — $(tail -3 "$TMP/mock.log")" >&2
      exit 1
    fi
    sleep 0.25
  done
  echo "ERREUR: le mock n'a pas démarré sur :${MOCK_PORT} — $(tail -3 "$TMP/mock.log")" >&2
  exit 1
}
# Le store du mock est en mémoire : un mock frais est vierge de TOUT, y compris
# de la feature Teams et des accessProfiles. Les re-semer fait partie du
# « mock vierge », sinon le cloisonnement d'équipe — désormais sur le chemin
# critique de la nouvelle version — ne pourrait pas être exercé.
seed_teams(){
  adm -o /dev/null -H 'Content-Type: application/json' -X PUT \
    "$BASE/configurations/extended" -d '{"enableTeamWork":"true"}'
  for t in payments-team other-team; do
    adm -o /dev/null -H 'Content-Type: application/json' -X POST \
      "$BASE/accessProfiles" -d "{\"name\":\"$t\"}"
  done
}
fresh_mock(){ mock_stop; mock_start; seed_teams; }

# run_role <dossier-ansible> <manifeste> [extra ansible-playbook args...]
run_role(){
  local adir="$1" manifest="$2"; shift 2
  ansible-playbook -i "$adir/inventory.lab.ini" "$adir/publish-api.yml" \
    -e apim_ss_api_base="$BASE" \
    -e apim_ss_team="$TEAM" \
    -e apim_ss_manifest="$manifest" \
    "$@" 2>&1
}

# manifest <fichier> <version> <contrat>
manifest(){
  cat >"$1" <<EOF
---
apim_api:
  name: "${API_NAME}"
  version: "$2"
  contract: "$3"
  team: ""
  update: false
  inbound: {}
EOF
}

api_id(){  # api_id <version>
  adm "$BASE/apis" | python3 -c "
import sys,json
for it in (json.load(sys.stdin).get('apiResponse') or []):
    a=it.get('api') or {}
    if a.get('apiName')=='${API_NAME}' and a.get('apiVersion')=='$1': print(a['id']); break
"
}
api_count(){ adm "$BASE/apis" | python3 -c "
import sys,json; print(len([1 for it in (json.load(sys.stdin).get('apiResponse') or []) if (it.get('api') or {}).get('apiName')=='${API_NAME}']))"; }
api_field(){  # api_field <id> <champ>
  adm "$BASE/apis/$1" | python3 -c "
import sys,json; print(json.dumps(((json.load(sys.stdin).get('apiResponse') or {}).get('api') or {}).get('$2')))"
}
app_subs(){  # app_subs <appId> — la liste TRIÉE des ids souscrits
  adm "$BASE/applications/$1" | python3 -c "
import sys,json
a=(json.load(sys.stdin).get('applications') or [{}])[0]
print(' '.join(sorted(a.get('consumingAPIs') or [])))"
}
http_code(){ curl -s -o /dev/null -w '%{http_code}' -m 10 "$@"; }

# ── contrats et manifestes (générés, jamais commités) ────────────────────────
cat >"$TMP/v1.openapi.yaml" <<'EOF'
openapi: 3.0.3
info:
  title: P3T6 API
  version: 1.0.0
servers:
  - url: http://backend.invalid:9999/p3t6
paths:
  /accounts:
    get:
      operationId: listAccounts
EOF
# Le contrat de la NOUVELLE version ajoute /v2only : c'est lui qui prouvera,
# par le data-plane, que la spec du MANIFESTE a bien atterri sur la version
# minée (la duplication, elle, ne copie que la définition de la BASE).
cat >"$TMP/v2.openapi.yaml" <<'EOF'
openapi: 3.0.3
info:
  title: P3T6 API
  version: 2.0
servers:
  - url: http://backend.invalid:9999/p3t6
paths:
  /accounts:
    get:
      operationId: listAccounts
  /v2only:
    get:
      operationId: v2Only
EOF
manifest "$TMP/v1.yml"  "1.0.0" "$TMP/v1.openapi.yaml"
manifest "$TMP/v2.yml"  "2.0"   "$TMP/v2.openapi.yaml"
manifest "$TMP/v4.yml"  "4.0"   "$TMP/v2.openapi.yaml"

# ── prérequis : port libre + binaire du mock ────────────────────────────────
if curl -s -o /dev/null -m 1 "http://localhost:${MOCK_PORT}/health"; then
  echo "ERREUR: quelque chose écoute déjà sur :${MOCK_PORT} (mock d'une manche précédente ?)." >&2
  echo "        lsof -ti tcp:${MOCK_PORT} | xargs kill — puis relancer." >&2
  exit 1
fi
( cd "$REPO/mocks/webmethods" && go build -o "$TMP/wmmock" . ) \
  || { echo "ERREUR: build du mock" >&2; exit 1; }

# prep_v1_with_subscriber : mock vierge + v1 publiée + une app souscrite à v1.
# ÉCRIT DANS DES GLOBALES (APPID, V1) — jamais sur stdout : un appel en
# substitution de commande tournerait dans un SOUS-SHELL, et le MOCK_PID du
# mock démarré là y resterait. Le parent ne pourrait plus le tuer, l'orphelin
# garderait le port, et tout le reste du run parlerait à un store fantôme
# (constaté au premier essai de ce script ; même famille de piège que le bug
# de substitution du spike T1).
APPID=""; V1=""
prep_v1_with_subscriber(){
  fresh_mock
  run_role "$REPO/ansible" "$TMP/v1.yml" >"$TMP/prep.log" 2>&1
  V1=$(api_id "1.0.0")
  [ -n "$V1" ] || { echo "ERREUR: préparation — v1 non publiée : $(tail -5 "$TMP/prep.log")" >&2; exit 1; }
  local resp
  resp=$(adm -H 'Content-Type: application/json' -X POST "$BASE/applications" -d '{"name":"p3t6-consumer"}')
  APPID=$(printf '%s' "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
  [ -n "$APPID" ] || { echo "ERREUR: préparation — app non créée : $resp" >&2; exit 1; }
  adm -o /dev/null -H 'Content-Type: application/json' -X PUT \
      "$BASE/applications/$APPID/apis" -d "{\"apiIDs\":[\"$V1\"]}"
}

# inject <fichier-relatif> <sed-expr> — copie ansible/ dans un dossier jetable
# et y applique UNE mutation, dans la globale INJ_DIR. Le dépôt n'est JAMAIS
# modifié : pas de risque qu'une injection survive à un script interrompu.
# Une expression sed qui ne change RIEN est une erreur FATALE : une injection
# qui rate rendrait le run vert sans avoir rien éprouvé.
INJ_DIR=""
inject(){
  local rel="$1" expr="$2"
  INJ_DIR="$TMP/inj.$RANDOM.$RANDOM"
  cp -R "$REPO/ansible" "$INJ_DIR"
  sed -i.bak "$expr" "$INJ_DIR/$rel" && rm -f "$INJ_DIR/$rel.bak"
  if diff -q "$REPO/ansible/$rel" "$INJ_DIR/$rel" >/dev/null; then
    echo "ERREUR: injection SANS EFFET sur $rel ($expr) — la contre-épreuve serait vide." >&2
    exit 1
  fi
}

echo "═══ Section A — non-régression : le publish initial est inchangé ═══"

# A1/A2 : MÊME séquence, MÊME état. Les ids du mock sont déterministes
# (wm-<kind>-NNNN, compteur par famille) : deux runs identiques sur deux mocks
# vierges rendent des états STRICTEMENT égaux. Comparer l'état complet (liste
# + record unitaire + policyActions) après le rôle d'AVANT (BASE_COMMIT) et
# celui d'APRÈS vaut mieux qu'un décompte de tâches : c'est l'effet sur la
# gateway qui doit être identique, pas la forme du play.
dump_state(){ adm "$BASE/apis"; adm "$BASE/apis/$(api_id 1.0.0)"; adm "$BASE/policyActions"; }

BASE_ANSIBLE="$TMP/ansible-base"
git -C "$REPO" archive "$BASE_COMMIT" ansible | tar -x -C "$TMP" -f - 2>/dev/null
[ -f "$TMP/ansible/publish-api.yml" ] && mv "$TMP/ansible" "$BASE_ANSIBLE"

if [ -f "$BASE_ANSIBLE/publish-api.yml" ]; then
  fresh_mock
  run_role "$BASE_ANSIBLE" "$TMP/v1.yml" >"$TMP/a-base.log" 2>&1
  RC_BASE=$?
  dump_state >"$TMP/state-base.json"
  fresh_mock
  run_role "$REPO/ansible" "$TMP/v1.yml" >"$TMP/a-head.log" 2>&1
  RC_HEAD=$?
  dump_state >"$TMP/state-head.json"
  [ "$RC_BASE" -eq 0 ] && [ "$RC_HEAD" -eq 0 ] \
    && ok "A1 publish initial : vert avec le rôle d'AVANT ($BASE_COMMIT) ET celui d'APRÈS" \
    || ko "A1 publish initial : rc base=$RC_BASE head=$RC_HEAD (attendu 0/0) — $(tail -3 "$TMP/a-head.log")"
  if diff -q "$TMP/state-base.json" "$TMP/state-head.json" >/dev/null; then
    ok "A2 état gateway après import initial : STRICTEMENT identique (ids compris)"
  else
    ko "A2 état gateway différent : $(diff "$TMP/state-base.json" "$TMP/state-head.json" | head -5)"
  fi
else
  ko "A1 rôle d'AVANT ($BASE_COMMIT) non extractible — comparaison impossible"
  ko "A2 idem"
fi

# A3 : sur un nom inconnu, le branchement ne fait AUCUN appel — le bloc est
# skippé. On sonde une tâche INTERNE au bloc : Ansible n'imprime jamais de
# bannière TASK pour un `block:` lui-même, seulement pour ses tâches.
if awk '/une seule base candidate/{f=1;next} f&&NF{print;exit}' \
     "$TMP/a-head.log" | grep -q '^skipping'; then
  ok "A3 nom inconnu : le bloc create-or-version est SKIPPÉ (zéro appel supplémentaire)"
else
  ko "A3 le bloc create-or-version n'est pas skippé sur un import initial"
fi

# A4 : les gardes hors ligne du producteur restent vertes.
if ansible-playbook -i "$REPO/ansible/inventory.lab.ini" "$REPO/ansible/test-publish-guards.yml" \
     -e apim_ss_manifest="$TMP/v1.yml" -e apim_ss_team="$TEAM" >"$TMP/a4.log" 2>&1; then
  ok "A4 test-publish-guards.yml (manifest-guard + team-name + approvers) : vert"
else
  ko "A4 test-publish-guards.yml a rougi : $(grep -m1 '"msg"' "$TMP/a4.log")"
fi

echo "═══ Section B — nominal : v2 minée depuis v1, avec ses abonnés ═══"
prep_v1_with_subscriber
SUBS_BEFORE="$(app_subs "$APPID")"
[ "$SUBS_BEFORE" = "$V1" ] \
  && ok "B1 témoin AVANT : l'app est souscrite à v1 et à elle seule" \
  || ko "B1 témoin AVANT inattendu : '$SUBS_BEFORE' (attendu '$V1')"

run_role "$REPO/ansible" "$TMP/v2.yml" >"$TMP/b.log" 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "B2 apply de la nouvelle version : vert" \
                || ko "B2 apply v2 : rc=$RC — $(grep -m1 -o '"msg": "[^"]*"' "$TMP/b.log")"

for tag in VERSION_BASE_OK VERSION_CREATED VERSION_CLONE_OK VERSION_SUBS_RETAINED; do
  grep -q "$tag" "$TMP/b.log" && ok "B3 $tag prononcé par le rôle" \
                              || ko "B3 $tag ABSENT du run"
done

V2="$(api_id 2.0)"
[ -n "$V2" ] && [ "$V2" != "$V1" ] \
  && ok "B4 la v2 existe, id distinct de la base" \
  || ko "B4 v2 introuvable ou id confondu avec la base"

[ "$(api_field "$V2" isActive)" = "true" ] \
  && ok "B5 la v2 est ACTIVE (le rôle a joué activate après le mint)" \
  || ko "B5 la v2 n'est pas active"

POL1="$(api_field "$V1" policies)"; POL2="$(api_field "$V2" policies)"
[ -n "$POL2" ] && [ "$POL2" != "null" ] && [ "$POL1" != "$POL2" ] \
  && ok "B6 M2 : policies CLONÉES (v1=$POL1 vs v2=$POL2)" \
  || ko "B6 M2 : policies non clonées (v1=$POL1 v2=$POL2)"

SUBS_AFTER="$(app_subs "$APPID")"
if [ "$SUBS_AFTER" = "$(printf '%s\n%s\n' "$V1" "$V2" | sort | tr '\n' ' ' | sed 's/ $//')" ]; then
  ok "B7 M3 : l'app voit MAINTENANT v1 ET v2 (souscription transportée, base conservée)"
else
  ko "B7 M3 : souscriptions après = '$SUBS_AFTER' (attendu v1+v2)"
fi

C_V2NEW=$(http_code "$DP/${API_NAME}/2.0/v2only")
C_V1NEW=$(http_code "$DP/${API_NAME}/1.0.0/v2only")
[ "$C_V2NEW" != "404" ] \
  && ok "B8 la spec du MANIFESTE a atterri sur la v2 (/v2only servi, HTTP $C_V2NEW)" \
  || ko "B8 /v2only absent de la v2 — le re-import de la spec n'a pas eu lieu"
[ "$C_V1NEW" = "404" ] \
  && ok "B9 la BASE n'a pas bougé (/v2only toujours hors contrat en v1)" \
  || ko "B9 /v2only servi par la v1 (HTTP $C_V1NEW) — la base a été modifiée"

BEFORE_N="$(api_count)"
run_role "$REPO/ansible" "$TMP/v2.yml" >"$TMP/b10.log" 2>&1; RC=$?
[ "$RC" -eq 0 ] && [ "$(api_count)" = "$BEFORE_N" ] \
  && ok "B10 re-apply du MÊME manifeste : vert et sans re-mint ($BEFORE_N versions)" \
  || ko "B10 re-apply : rc=$RC, versions $BEFORE_N → $(api_count)"

echo "═══ Section C — fail-closed : base ambiguë ═══"
fresh_mock
run_role "$REPO/ansible" "$TMP/v1.yml" >"$TMP/c-prep.log" 2>&1
# Deux mints à la main : la gateway n'autorise que depuis la DERNIÈRE version,
# on enchaîne donc 1.0.0 → 2.0 → 3.0.
ID="$(api_id 1.0.0)"
adm -o /dev/null -H 'Content-Type: application/json' -X POST "$BASE/apis/$ID/versions" -d '{"newApiVersion":"2.0"}'
ID="$(api_id 2.0)"
adm -o /dev/null -H 'Content-Type: application/json' -X POST "$BASE/apis/$ID/versions" -d '{"newApiVersion":"3.0"}'
N_BEFORE="$(api_count)"
[ "$N_BEFORE" -eq 3 ] && ok "C1 trois versions posées (1.0.0, 2.0, 3.0)" \
                      || ko "C1 préparation : $N_BEFORE versions au lieu de 3"

run_role "$REPO/ansible" "$TMP/v4.yml" >"$TMP/c.log" 2>&1; RC=$?
[ "$RC" -ne 0 ] && grep -q "VERSION_BASE_AMBIGUE" "$TMP/c.log" \
  && ok "C2 refus explicite VERSION_BASE_AMBIGUE (rc=$RC), jamais de devinette" \
  || ko "C2 attendu un refus VERSION_BASE_AMBIGUE, rc=$RC"
if grep -q "VERSION_BASE_AMBIGUE" "$TMP/c.log" \
   && grep -q "1.0.0 -> id" "$TMP/c.log" && grep -q "3.0 -> id" "$TMP/c.log"; then
  ok "C3 le refus LISTE les candidats (version -> id), diagnostic actionnable"
else
  ko "C3 le refus ne liste pas les candidats"
fi
[ "$(api_count)" = "$N_BEFORE" ] \
  && ok "C4 refus SANS TRACE : aucune version créée ($N_BEFORE inchangé)" \
  || ko "C4 le refus a laissé une trace : $N_BEFORE → $(api_count)"

echo "═══ Section D — chaque garde sait ROUGIR (injections jetables) ═══"

# D1 — LE piège mesuré : casse fautive du flag. La gateway répond 201 quand
# même ; seule la relecture des souscriptions le détecte.
prep_v1_with_subscriber
inject "roles/apim_publish_api/tasks/version.yml" \
     's/retainApplications: true/RetainApplications: true/'
run_role "$INJ_DIR" "$TMP/v2.yml" >"$TMP/d1.log" 2>&1; RC=$?
[ "$RC" -ne 0 ] && grep -q "VERSION_SUBS_NOT_RETAINED" "$TMP/d1.log" \
  && ok "D1 casse fautive (RetainApplications) → VERSION_SUBS_NOT_RETAINED" \
  || ko "D1 la casse fautive est passée inaperçue (rc=$RC) — LE piège M3 n'est pas gardé"
# … et le contre-témoin qui montre POURQUOI l'assert est porteur : la gateway a
# bel et bien MINÉ la version (elle est là, relue) — elle a juste laissé les
# abonnés derrière, sans le moindre code d'erreur.
V2BAD="$(api_id 2.0)"
if [ -n "$V2BAD" ] && ! app_subs "$APPID" | grep -q "$V2BAD"; then
  ok "D1b … la v2 EXISTE pourtant sur la gateway, sans ses abonnés : l'échec est SILENCIEUX côté produit"
else
  ko "D1b contre-témoin manquant : v2='$V2BAD', souscriptions='$(app_subs "$APPID")'"
fi

# D2 — la duplication elle-même refusée.
prep_v1_with_subscriber
inject "roles/apim_publish_api/tasks/version.yml" \
     's|/apis/{{ pub_ver_base_id }}/versions|/apis/wm-api-inexistante/versions|'
run_role "$INJ_DIR" "$TMP/v2.yml" >"$TMP/d2.log" 2>&1; RC=$?
[ "$RC" -ne 0 ] && grep -q "VERSION_CREATE_FAILED" "$TMP/d2.log" \
  && ok "D2 duplication refusée par la gateway → VERSION_CREATE_FAILED (échec NOMMÉ)" \
  || ko "D2 attendu VERSION_CREATE_FAILED, rc=$RC"

# D3 — la relecture ne retrouve pas la version : un 201 ne prouve rien.
prep_v1_with_subscriber
inject "roles/apim_publish_api/tasks/version.yml" \
     "s/selectattr('apiVersion', 'equalto', apim_api.version)/selectattr('apiVersion', 'equalto', 'jamais-minee')/"
run_role "$INJ_DIR" "$TMP/v2.yml" >"$TMP/d3.log" 2>&1; RC=$?
[ "$RC" -ne 0 ] && grep -q "VERSION_UNCONFIRMED" "$TMP/d3.log" \
  && ok "D3 relecture infructueuse → VERSION_UNCONFIRMED" \
  || ko "D3 attendu VERSION_UNCONFIRMED, rc=$RC"

# D4 — policies partagées avec la base (relecture pointée sur la base).
prep_v1_with_subscriber
inject "roles/apim_publish_api/tasks/version.yml" \
     's|url: "{{ apim_ss_api_base }}/apis/{{ pub_ver_new_ids . first }}"|url: "{{ apim_ss_api_base }}/apis/{{ pub_ver_base_id }}"|'
run_role "$INJ_DIR" "$TMP/v2.yml" >"$TMP/d4.log" 2>&1; RC=$?
[ "$RC" -ne 0 ] && grep -q "VERSION_CLONE_UNEXPECTED" "$TMP/d4.log" \
  && ok "D4 policies non disjointes de la base → VERSION_CLONE_UNEXPECTED" \
  || ko "D4 attendu VERSION_CLONE_UNEXPECTED, rc=$RC"

# D5 — la forme qui porte les souscriptions a disparu : le témoin serait vide
# PAR ACCIDENT, l'assert M3 vert sans rien prouver.
prep_v1_with_subscriber
inject "roles/apim_publish_api/tasks/version.yml" \
     "s/rejectattr('consumingAPIs', 'defined')/rejectattr('consumingAPIsZZZ', 'defined')/"
run_role "$INJ_DIR" "$TMP/v2.yml" >"$TMP/d5.log" 2>&1; RC=$?
[ "$RC" -ne 0 ] && grep -q "VERSION_SUBS_SHAPE_UNKNOWN" "$TMP/d5.log" \
  && ok "D5 clé consumingAPIs absente → VERSION_SUBS_SHAPE_UNKNOWN (pas de vert vacant)" \
  || ko "D5 attendu VERSION_SUBS_SHAPE_UNKNOWN, rc=$RC"

# D6 — le drapeau d'exemption ADR-079 est FORGÉ en extra-var (précédence 22 >
# set_fact 20). La moitié non forgeable — l'état relu sur la gateway — doit
# tenir : l'API v1 est ACTIVE, donc la désactiver couperait du trafic.
fresh_mock
run_role "$REPO/ansible" "$TMP/v1.yml" >"$TMP/d6-prep.log" 2>&1
run_role "$REPO/ansible" "$TMP/v1.yml" -e apim_ss_env=int -e pub_version_minted=true >"$TMP/d6.log" 2>&1; RC=$?
[ "$RC" -ne 0 ] && grep -q "VERSION_MINTED_ACTIVE" "$TMP/d6.log" \
  && ok "D6 drapeau minted FORGÉ sur une API active → VERSION_MINTED_ACTIVE (état > variable)" \
  || ko "D6 le drapeau forgé a ouvert l'exemption ADR-079 (rc=$RC)"

# D7 — la garde historique n'a pas été élargie : update:true hors env
# d'authoring, sans mint, refuse toujours.
manifest "$TMP/v1u.yml" "1.0.0" "$TMP/v1.openapi.yaml"
sed -i.bak 's/update: false/update: true/' "$TMP/v1u.yml" && rm -f "$TMP/v1u.yml.bak"
run_role "$REPO/ansible" "$TMP/v1u.yml" -e apim_ss_env=int >"$TMP/d7.log" 2>&1; RC=$?
[ "$RC" -ne 0 ] && grep -q "UPDATE_FORBIDDEN" "$TMP/d7.log" \
  && ok "D7 update:true hors authoring (sans mint) → UPDATE_FORBIDDEN, garde intacte" \
  || ko "D7 UPDATE_FORBIDDEN ne se déclenche plus (rc=$RC) — le trou a été élargi"

echo "═══ Section E — l'exemption ADR-079 sert à quelque chose ═══"
# Contrôle POSITIF de D7 : la nouvelle version, elle, doit rester possible hors
# env d'authoring — c'est précisément la voie 0-coupure de l'ADR-079.
prep_v1_with_subscriber
run_role "$REPO/ansible" "$TMP/v2.yml" -e apim_ss_env=int >"$TMP/e.log" 2>&1; RC=$?
[ "$RC" -eq 0 ] && [ -n "$(api_id 2.0)" ] \
  && ok "E1 mint + re-import sur env=int (hors authoring) : vert, la v2 existe" \
  || ko "E1 la nouvelle version est refusée hors env d'authoring (rc=$RC)"
grep -q "UPDATE_FORBIDDEN" "$TMP/e.log" \
  && ko "E2 UPDATE_FORBIDDEN prononcé alors qu'aucune désactivation n'était en jeu" \
  || ok "E2 aucune désactivation en jeu : la v2 naît inactive, rien n'est coupé"

echo
echo "═══ Section F — mint INTERROMPU : jamais activer le clone en silence ═══"
# Le repro exact de la revue : le mint (POST /versions) réussit, le run meurt
# AVANT le re-import de la spec. `pub_version_minted` est un fait de RUN : il
# meurt avec le processus. Au run suivant, name+version est trouvé.
half_born_v2(){   # mock frais + v1 publiée + app souscrite + v2 minée À LA MAIN
  prep_v1_with_subscriber
  adm -o /dev/null -H 'Content-Type: application/json' -X POST \
    "$BASE/apis/$V1/versions" -d '{"newApiVersion":"2.0","retainApplications":true}'
}

# F0 — le défaut EXISTE avec le rôle du round 1 : témoin AVANT, sans lequel la
# garde d'après ne prouverait rien (une garde qui ne ferme aucun trou réel).
ROUND1_ANSIBLE="$TMP/ansible-round1"
git -C "$REPO" archive "$ROUND1_COMMIT" ansible | tar -x -C "$TMP" -f - 2>/dev/null
[ -f "$TMP/ansible/publish-api.yml" ] && mv "$TMP/ansible" "$ROUND1_ANSIBLE"
if [ -f "$ROUND1_ANSIBLE/publish-api.yml" ]; then
  half_born_v2
  run_role "$ROUND1_ANSIBLE" "$TMP/v2.yml" >"$TMP/f0.log" 2>&1; RC=$?
  C_V2=$(http_code "$DP/${API_NAME}/2.0/v2only")
  if [ "$RC" -eq 0 ] && [ "$(api_field "$(api_id 2.0)" isActive)" = "true" ] && [ "$C_V2" = "404" ]; then
    ok "F0 témoin AVANT ($ROUND1_COMMIT) : la v2 est ACTIVÉE (rc=0) en servant la spec de la BASE — /v2only 404"
  else
    ko "F0 le défaut ne se reproduit pas avec $ROUND1_COMMIT (rc=$RC, /v2only=$C_V2) — la garde F1 ne prouverait rien"
  fi
else
  ko "F0 rôle du round 1 ($ROUND1_COMMIT) non extractible — témoin AVANT impossible"
fi

# F1 — avec la garde : refus nommé, et SURTOUT rien n'est activé.
half_born_v2
run_role "$REPO/ansible" "$TMP/v2.yml" >"$TMP/f1.log" 2>&1; RC=$?
[ "$RC" -ne 0 ] && grep -q "VERSION_INCOMPLETE" "$TMP/f1.log" \
  && ok "F1 mint interrompu → VERSION_INCOMPLETE (refus nommé)" \
  || ko "F1 attendu VERSION_INCOMPLETE, rc=$RC"
[ "$(api_field "$(api_id 2.0)" isActive)" = "false" ] \
  && ok "F2 la v2 à moitié née reste INACTIVE — le clone n'est JAMAIS servi" \
  || ko "F2 la v2 a été activée malgré le refus"

# F3/F4 — la reprise explicite finit le travail : spec du manifeste, puis activation.
run_role "$REPO/ansible" "$TMP/v2.yml" -e apim_pub_resume_version=true >"$TMP/f3.log" 2>&1; RC=$?
[ "$RC" -eq 0 ] && grep -q "VERSION_RESUME" "$TMP/f3.log" \
  && ok "F3 reprise explicite (apim_pub_resume_version=true) : vert, VERSION_RESUME prononcé" \
  || ko "F3 la reprise a échoué (rc=$RC)"
C_V2=$(http_code "$DP/${API_NAME}/2.0/v2only"); C_V1=$(http_code "$DP/${API_NAME}/1.0.0/v2only")
[ "$C_V2" != "404" ] && [ "$C_V1" = "404" ] \
  && ok "F4 après reprise, la v2 sert la spec du MANIFESTE (/v2only $C_V2) et la base non ($C_V1)" \
  || ko "F4 spec non reprise : v2=$C_V2 v1=$C_V1"

# F5 — import initial interrompu AVANT l'activate (lignée MONO-version). Ce cas
# a CHANGÉ avec la garde d'appartenance 0c, et c'est VOULU : l'API laissée
# derrière vit en `Default`, donc elle n'appartient à AUCUNE équipe — c'est
# l'état exact des APIs plateforme, `provisioning` comprise. La réclamer
# automatiquement serait la capture même que 0c interdit. Le refus est nommé et
# dit le geste (un administrateur assigne l'équipe).
fresh_mock
import_v1_by_hand(){
  adm -o /dev/null -X POST "$BASE/apis" \
    -F "file=@$TMP/v1.openapi.yaml;type=application/x-yaml" -F "type=openapi" \
    -F "apiName=${API_NAME}" -F "apiVersion=1.0.0"
}
import_v1_by_hand
run_role "$REPO/ansible" "$TMP/v1.yml" >"$TMP/f5.log" 2>&1; RC=$?
[ "$RC" -ne 0 ] && grep -q "API_OWNER_MISMATCH" "$TMP/f5.log" \
  && ok "F5 import interrompu laissé en Default + équipe posée → API_OWNER_MISMATCH (une API sans équipe ne se réclame pas)" \
  || ko "F5 attendu API_OWNER_MISMATCH, rc=$RC"

# F5b — le MÊME état, mais par un appelant HISTORIQUE (aucune équipe demandeuse,
# feature Teams éteinte) : la garde ne fire pas, la reprise se fait, et la
# tolérance est VISIBLE. C'est la non-régression des appelants d'avant.
adm -o /dev/null -H 'Content-Type: application/json' -X PUT \
  "$BASE/configurations/extended" -d '{"enableTeamWork":"false"}'
# Appel SANS -e apim_ss_team (donc sans équipe demandeuse) : c'est la forme des
# appelants d'avant l'onboarding par équipe (apply-uac, clients/_example).
ansible-playbook -i "$REPO/ansible/inventory.lab.ini" "$REPO/ansible/publish-api.yml" \
  -e apim_ss_api_base="$BASE" -e apim_pub_require_team=false \
  -e apim_ss_manifest="$TMP/v1.yml" >"$TMP/f5b.log" 2>&1; RC=$?
[ "$RC" -eq 0 ] && [ "$(api_field "$(api_id 1.0.0)" isActive)" = "true" ] \
  && ok "F5b appelant historique (sans équipe, Teams éteinte) : repris et activé — non-régression" \
  || ko "F5b la garde casse un appelant historique (rc=$RC)"
grep -q "VERSION_FOREIGN_UNCHECKED" "$TMP/f5b.log" \
  && ok "F5c … et la tolérance est VISIBLE (VERSION_FOREIGN_UNCHECKED)" \
  || ko "F5c aucun avertissement nommé : la capture non gardée resterait invisible"

echo "═══ Section G — la lignée d'une AUTRE équipe est intouchable ═══"
# G0 — témoin AVANT : avec le rôle du round 1, un manifeste portant le nom
# d'autrui MINE dans sa lignée et lui prend ses abonnés.
if [ -f "$ROUND1_ANSIBLE/publish-api.yml" ]; then
  TEAM="other-team"; prep_v1_with_subscriber
  V1_OTHER="$V1"; APP_OTHER="$APPID"
  TEAM="payments-team"
  run_role "$ROUND1_ANSIBLE" "$TMP/v2.yml" >"$TMP/g0.log" 2>&1; RC=$?
  V2X="$(api_id 2.0)"
  if [ "$RC" -eq 0 ] && [ -n "$V2X" ] && app_subs "$APP_OTHER" | grep -q "$V2X"; then
    ok "G0 témoin AVANT ($ROUND1_COMMIT) : version minée dans la lignée d'other-team, ses abonnés TRANSPORTÉS"
  else
    ko "G0 la capture ne se reproduit pas avec $ROUND1_COMMIT (rc=$RC) — la garde G1 ne prouverait rien"
  fi
else
  ko "G0 rôle du round 1 non extractible — témoin AVANT impossible"
fi

# G1 — avec la garde : refus, et aucune trace.
TEAM="other-team"; prep_v1_with_subscriber
APP_OTHER="$APPID"; N_BEFORE="$(api_count)"
TEAM="payments-team"
run_role "$REPO/ansible" "$TMP/v2.yml" >"$TMP/g1.log" 2>&1; RC=$?
[ "$RC" -ne 0 ] && grep -q "VERSION_BASE_FOREIGN" "$TMP/g1.log" \
  && ok "G1 lignée d'autrui → VERSION_BASE_FOREIGN (refus nommé)" \
  || ko "G1 attendu VERSION_BASE_FOREIGN, rc=$RC"
[ "$(api_count)" = "$N_BEFORE" ] && [ -z "$(api_id 2.0)" ] \
  && ok "G2 refus SANS TRACE : aucune version minée dans la lignée d'autrui" \
  || ko "G2 une version a été créée malgré le refus"
[ "$(app_subs "$APP_OTHER")" = "$V1" ] \
  && ok "G3 les abonnés d'other-team n'ont pas bougé" \
  || ko "G3 souscriptions d'other-team altérées : $(app_subs "$APP_OTHER")"

# G4 — contre-témoin VERT : sa PROPRE lignée passe (sans quoi G1 pourrait
# n'être qu'un refus systématique).
TEAM="payments-team"; prep_v1_with_subscriber
run_role "$REPO/ansible" "$TMP/v2.yml" >"$TMP/g4.log" 2>&1; RC=$?
[ "$RC" -eq 0 ] && grep -q "VERSION_BASE_OWNED" "$TMP/g4.log" && [ -n "$(api_id 2.0)" ] \
  && ok "G4 sa propre lignée : VERSION_BASE_OWNED, la v2 est minée" \
  || ko "G4 la garde refuse aussi sa propre lignée (rc=$RC)"

# G5 — feature Teams éteinte = ne pas savoir : refus (ne pas savoir n'autorise pas).
fresh_mock
run_role "$REPO/ansible" "$TMP/v1.yml" >"$TMP/g5-prep.log" 2>&1
adm -o /dev/null -H 'Content-Type: application/json' -X PUT \
  "$BASE/configurations/extended" -d '{"enableTeamWork":"false"}'
run_role "$REPO/ansible" "$TMP/v2.yml" >"$TMP/g5.log" 2>&1; RC=$?
[ "$RC" -ne 0 ] \
  && ok "G5 feature Teams éteinte : refus (appartenance non confirmable)" \
  || ko "G5 la version est passée alors que l'appartenance était inconnaissable"

echo "═══ Section H — le témoin de souscription ne crie pas au loup ═══"
# Contre-témoin NATUREL du fix mock : une application JAMAIS associée porte
# quand même la clé consumingAPIs. Sans le fix, la garde ∀ de forme
# (VERSION_SUBS_SHAPE_UNKNOWN) refuserait ce cas parfaitement légitime.
TEAM="payments-team"; fresh_mock
run_role "$REPO/ansible" "$TMP/v1.yml" >"$TMP/h-prep.log" 2>&1
adm -o /dev/null -H 'Content-Type: application/json' -X POST "$BASE/applications" \
  -d '{"name":"p3t6-jamais-associee"}'
run_role "$REPO/ansible" "$TMP/v2.yml" >"$TMP/h.log" 2>&1; RC=$?
[ "$RC" -eq 0 ] && grep -q "VERSION_SUBS_VACANT" "$TMP/h.log" \
  && ok "H1 application jamais associée : le mint passe et le témoin se déclare VACANT" \
  || ko "H1 le mint a été refusé (rc=$RC) ou le témoin vide est passé pour une preuve"

echo "═══ Section I — la REPRISE n'est pas une porte de service ═══"
# Défaut né du round 1 : la garde d'appartenance vivait dans le bloc du mint
# (apim_api_id VIDE) ; la reprise s'exécute quand apim_api_id est TROUVÉ par le
# matching name+version GLOBAL — elle ne la traversait donc jamais.

# I0 — témoin AVANT (rôle du round 1, f5d64f8) : reprendre la demi-version
# d'une AUTRE équipe pousse SA spec et l'active, en vert.
R1_ANSIBLE="$TMP/ansible-r1v2"
git -C "$REPO" archive "$ROUND1V2_COMMIT" ansible | tar -x -C "$TMP" -f - 2>/dev/null
[ -f "$TMP/ansible/publish-api.yml" ] && mv "$TMP/ansible" "$R1_ANSIBLE"
if [ -f "$R1_ANSIBLE/publish-api.yml" ]; then
  TEAM="other-team"; half_born_v2
  TEAM="payments-team"
  run_role "$R1_ANSIBLE" "$TMP/v2.yml" -e apim_pub_resume_version=true >"$TMP/i0.log" 2>&1; RC=$?
  C_V2=$(http_code "$DP/${API_NAME}/2.0/v2only")
  if [ "$RC" -eq 0 ] && [ "$C_V2" != "404" ]; then
    ok "I0 témoin AVANT ($ROUND1V2_COMMIT) : reprise sur la demi-version d'other-team → MA spec servie (HTTP $C_V2)"
  else
    ko "I0 le contournement ne se reproduit pas avec $ROUND1V2_COMMIT (rc=$RC, /v2only=$C_V2)"
  fi
else
  ko "I0 rôle du round 1 v2 non extractible — témoin AVANT impossible"
fi

# I1 — avec la garde : refus, rien poussé, rien activé (état RELU).
TEAM="other-team"; half_born_v2
V2_HALF="$(api_id 2.0)"
TEAM="payments-team"
run_role "$REPO/ansible" "$TMP/v2.yml" -e apim_pub_resume_version=true >"$TMP/i1.log" 2>&1; RC=$?
[ "$RC" -ne 0 ] && grep -q "VERSION_RESUME_FOREIGN" "$TMP/i1.log" \
  && ok "I1 reprise sur la lignée d'autrui → VERSION_RESUME_FOREIGN" \
  || ko "I1 attendu VERSION_RESUME_FOREIGN, rc=$RC"
[ "$(api_field "$V2_HALF" isActive)" = "false" ] \
  && ok "I2 rien n'a été ACTIVÉ sur la demi-version d'autrui" \
  || ko "I2 la demi-version d'autrui a été activée"
# « Rien poussé » n'est PAS observable sur un record inactif : le data-plane du
# mock répond 503 (pas encore actif) AVANT même de regarder le contrat, donc un
# 404 ne prouverait rien ici. On active donc la demi-version À LA MAIN, après le
# refus, uniquement pour LIRE ce qu'elle sert — le rôle, lui, ne l'a pas activée
# (I2 vient de le prouver sur l'état, avant cette manipulation).
adm -o /dev/null -X PUT "$BASE/apis/$V2_HALF/activate"
[ "$(http_code "$DP/${API_NAME}/2.0/v2only")" = "404" ] \
  && ok "I3 rien n'a été POUSSÉ : leur version sert toujours le contrat cloné, pas ma spec" \
  || ko "I3 ma spec a été poussée sur la version d'autrui"

# I4 — contre-témoin VERT : reprendre SA propre demi-version marche toujours.
TEAM="payments-team"; half_born_v2
run_role "$REPO/ansible" "$TMP/v2.yml" -e apim_pub_resume_version=true >"$TMP/i4.log" 2>&1; RC=$?
[ "$RC" -eq 0 ] && grep -q "VERSION_RESUME_OWNED" "$TMP/i4.log" \
  && [ "$(http_code "$DP/${API_NAME}/2.0/v2only")" != "404" ] \
  && ok "I4 reprise sur SA demi-version : VERSION_RESUME_OWNED, spec du manifeste servie" \
  || ko "I4 la garde bloque aussi la reprise légitime (rc=$RC)"

echo "═══ Section J — un profil SYSTÈME n'est pas une équipe ═══"
# `Administrators` est porté par TOUTE API : passé en équipe demandeuse, il
# obtenait un VERSION_BASE_OWNED affirmatif sur n'importe quelle lignée.
if [ -f "$R1_ANSIBLE/publish-api.yml" ]; then
  TEAM="other-team"; prep_v1_with_subscriber
  APP_OTHER="$APPID"
  TEAM="Administrators"
  run_role "$R1_ANSIBLE" "$TMP/v2.yml" >"$TMP/j0.log" 2>&1; RC=$?
  V2X="$(api_id 2.0)"
  if [ "$RC" -eq 0 ] && [ -n "$V2X" ] && app_subs "$APP_OTHER" | grep -q "$V2X"; then
    ok "J0 témoin AVANT ($ROUND1V2_COMMIT) : TEAM=Administrators mine dans la lignée d'other-team, abonnés transportés"
  else
    ko "J0 l'ouverture par profil système ne se reproduit pas (rc=$RC)"
  fi
else
  ko "J0 rôle du round 1 v2 non extractible"
fi

TEAM="other-team"; prep_v1_with_subscriber
N_BEFORE="$(api_count)"
TEAM="Administrators"
run_role "$REPO/ansible" "$TMP/v2.yml" >"$TMP/j1.log" 2>&1; RC=$?
[ "$RC" -ne 0 ] && grep -q "TEAM_IS_SYSTEM_PROFILE" "$TMP/j1.log" \
  && ok "J1 TEAM=Administrators → TEAM_IS_SYSTEM_PROFILE (refus nommé)" \
  || ko "J1 attendu TEAM_IS_SYSTEM_PROFILE, rc=$RC"
[ "$(api_count)" = "$N_BEFORE" ] \
  && ok "J2 refus SANS TRACE (profil système)" \
  || ko "J2 une version a été créée malgré le refus"

# J3 — la garde couvre AUSSI le chemin reprise (même politique des deux côtés).
TEAM="other-team"; half_born_v2
TEAM="Administrators"
run_role "$REPO/ansible" "$TMP/v2.yml" -e apim_pub_resume_version=true >"$TMP/j3.log" 2>&1; RC=$?
[ "$RC" -ne 0 ] && grep -q "TEAM_IS_SYSTEM_PROFILE" "$TMP/j3.log" \
  && ok "J3 profil système refusé AUSSI sur le chemin reprise" \
  || ko "J3 le chemin reprise accepte un profil système (rc=$RC)"

# J4 — tolérance VISIBLE : knob levé ⇒ avertissement nommé dans le log.
TEAM="payments-team"; prep_v1_with_subscriber
run_role "$REPO/ansible" "$TMP/v2.yml" -e apim_pub_version_require_team_match=false >"$TMP/j4.log" 2>&1; RC=$?
[ "$RC" -eq 0 ] && grep -q "VERSION_FOREIGN_UNCHECKED" "$TMP/j4.log" \
  && ok "J4 garde levée : VERSION_FOREIGN_UNCHECKED prononcé (la tolérance est VISIBLE)" \
  || ko "J4 garde levée sans avertissement nommé (rc=$RC)"
TEAM="payments-team"

echo "═══ Section K — capture d'une API PLATEFORME sur le chemin EXACT name+version ═══"
# Le trou d'assemblage de la revue finale : mono-version + id trouvé ⇒ ni mint
# ni reprise ⇒ toutes les gardes sautaient, puis owner/équipe/activation étaient
# réécrits. Reproduit avec une API « plateforme » dans l'état MESURÉ sur la
# gateway du lab : ACTIVE et en `Default` (aucune équipe réelle).
PLATFORM_API="p3t6-provisioning"
seed_platform_api(){        # API plateforme active, en Default, hors de tout dépôt d'équipe
  fresh_mock
  adm -o /dev/null -X POST "$BASE/apis" \
    -F "file=@$TMP/v1.openapi.yaml;type=application/x-yaml" -F "type=openapi" \
    -F "apiName=${PLATFORM_API}" -F "apiVersion=1.0"
  PLAT_ID=$(adm "$BASE/apis" | python3 -c "
import sys,json
for it in (json.load(sys.stdin).get('apiResponse') or []):
    a=it.get('api') or {}
    if a.get('apiName')=='${PLATFORM_API}': print(a['id']); break
")
  adm -o /dev/null -X PUT "$BASE/apis/$PLAT_ID/activate"
  cat >"$TMP/plat.yml" <<EOF
---
apim_api:
  name: "${PLATFORM_API}"
  version: "1.0"
  contract: "$TMP/v2.openapi.yaml"
  team: ""
  update: false
  inbound: {}
EOF
}
plat_teams(){ adm "$BASE/apis/$PLAT_ID" | python3 -c "
import sys,json
print(' '.join(sorted(t.get('name','') for t in ((json.load(sys.stdin).get('apiResponse') or {}).get('teams') or []))))"; }

# K0 — témoin AVANT : avec le rôle du round 2 (7b0d636), l'équipe CAPTURE.
K0_ANSIBLE="$TMP/ansible-r2"
git -C "$REPO" archive "$ROUND2_COMMIT" ansible | tar -x -C "$TMP" -f - 2>/dev/null
[ -f "$TMP/ansible/publish-api.yml" ] && mv "$TMP/ansible" "$K0_ANSIBLE"
if [ -f "$K0_ANSIBLE/publish-api.yml" ]; then
  seed_platform_api
  TEAM="payments-team"
  run_role "$K0_ANSIBLE" "$TMP/plat.yml" >"$TMP/k0.log" 2>&1; RC=$?
  if [ "$RC" -eq 0 ] && plat_teams | grep -q "payments-team"; then
    ok "K0 témoin AVANT ($ROUND2_COMMIT) : payments-team CAPTURE l'API plateforme (teams=$(plat_teams))"
  else
    ko "K0 la capture ne se reproduit pas avec $ROUND2_COMMIT (rc=$RC, teams=$(plat_teams))"
  fi
else
  ko "K0 rôle du round 2 non extractible — témoin AVANT impossible"
fi

# K1 — avec la garde : refus AVANT tout geste d'écriture.
seed_platform_api
TEAM="payments-team"
run_role "$REPO/ansible" "$TMP/plat.yml" >"$TMP/k1.log" 2>&1; RC=$?
[ "$RC" -ne 0 ] && grep -q "API_OWNER_MISMATCH" "$TMP/k1.log" \
  && ok "K1 capture d'une API plateforme → API_OWNER_MISMATCH (refus nommé)" \
  || ko "K1 attendu API_OWNER_MISMATCH, rc=$RC"
[ "$(plat_teams)" = "Administrators Default" ] \
  && ok "K2 l'équipe de l'API plateforme n'a PAS bougé (teams=$(plat_teams))" \
  || ko "K2 l'équipe de l'API plateforme a été réécrite : $(plat_teams)"
[ "$(api_field "$PLAT_ID" owner)" = "null" ] \
  && ok "K3 owner de l'API plateforme intact (approvers.yml n'a pas tourné)" \
  || ko "K3 owner réécrit : $(api_field "$PLAT_ID" owner)"

# K4 — profil système sur ce chemin aussi.
seed_platform_api
TEAM="Administrators"
run_role "$REPO/ansible" "$TMP/plat.yml" >"$TMP/k4.log" 2>&1; RC=$?
[ "$RC" -ne 0 ] && grep -q "TEAM_IS_SYSTEM_PROFILE" "$TMP/k4.log" \
  && ok "K4 TEAM=Administrators sur le chemin exact-match → TEAM_IS_SYSTEM_PROFILE" \
  || ko "K4 le chemin exact-match accepte un profil système (rc=$RC)"

# K5 — contre-témoin VERT : l'équipe PROPRIÉTAIRE ré-applique SON API.
seed_platform_api
UUID=$(adm "$BASE/accessProfiles" | python3 -c "
import sys,json
d=json.load(sys.stdin); ps=d.get('accessProfiles') or d.get('accessProfile') or []
print([p['id'] for p in ps if p.get('name')=='payments-team'][0])")
adm -o /dev/null -H 'Content-Type: application/json' -X POST "$BASE/assets/team" \
  -d "{\"assetIds\":[\"$PLAT_ID\"],\"assetType\":\"API\",\"newTeams\":[\"$UUID\"]}"
TEAM="payments-team"
run_role "$REPO/ansible" "$TMP/plat.yml" >"$TMP/k5.log" 2>&1; RC=$?
[ "$RC" -eq 0 ] && grep -q "API_OWNER_OK" "$TMP/k5.log" \
  && ok "K5 l'équipe PROPRIÉTAIRE ré-applique SON API : API_OWNER_OK, rien de bloqué" \
  || ko "K5 la garde bloque le propriétaire légitime (rc=$RC)"
TEAM="payments-team"

echo "═══════════════════════════════════════════"
printf '  RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || printf '  %d ÉCHEC(S)\n' "$FAIL"
echo "═══════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
