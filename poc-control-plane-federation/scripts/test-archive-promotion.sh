#!/usr/bin/env bash
# test-archive-promotion.sh — preuve X/X du modèle ADR-079 (import d'archive
# 0-coupure, GUID iso, alias per-env hors archive) sur une gateway wM 10.15.
#
# Rejoue les faits prouvés au spike 2026-07-17 avec des assets JETABLES
# (spike079t-*), nettoyés en sortie (trap). Aucune API existante n'est touchée.
#
#   GW_ADMIN=http://localhost:5555/rest/apigateway \
#   GW_DATA=http://localhost:5555/gateway \
#   WM_USER=Administrator WM_PASS=manage ./scripts/test-archive-promotion.sh
set -u
GW="${GW_ADMIN:-http://localhost:5555/rest/apigateway}"
DP="${GW_DATA:-http://localhost:5555/gateway}"
AUTH="${WM_USER:-Administrator}:${WM_PASS:-manage}"
WORK="$(mktemp -d /tmp/test079.XXXXXX)"
PASS=0; FAIL=0
API=spike079t-api; ALIAS=spike079t-backend
API_ID=""; ALIAS_ID=""; APP_ID=""; L2_ID=""

say()  { printf '\n== %s ==\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko()   { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else ko "$3 (attendu '$2', obtenu '$1')"; fi; }
adm()  { curl -sS -u "$AUTH" -H "Accept: application/json" "$@"; }

cleanup() {
  say "cleanup (assets jetables)"
  [ -n "$APP_ID" ] && adm -X DELETE "$GW/applications/$APP_ID" -o /dev/null
  for ID in "$API_ID" "$L2_ID"; do
    [ -n "$ID" ] || continue
    adm -X PUT "$GW/apis/$ID/deactivate" -o /dev/null
    adm -X DELETE "$GW/apis/$ID" -o /dev/null
  done
  [ -n "$ALIAS_ID" ] && adm -X DELETE "$GW/alias/$ALIAS_ID" -o /dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------- purge de l'ACDL (le manifeste de l'import) -----------------------
# POURQUOI. Ce harnais re-zippe des archives à la main, et ne réempaquette que
# `APIGatewayAssets.acdl` + `API/`. Or l'ACDL est le MANIFESTE de l'import : un
# asset qu'il DÉCLARE mais que le zip ne PORTE PAS fait échouer toute sa branche
# de dépendances. Tant que `enableTeamWork` était éteint, l'export ne contenait
# rien d'autre et le raccourci passait ; depuis qu'il est allumé, l'export
# embarque `AccessProfile/`, `AccessControlList/` et une entrée `Team`, et
# l'import répond « Unable to find AccessProfile.Administrators Asset
# AccessProfile while importing the ACDL file » sur CHAQUE ligne.
#
# La purge ci-dessous est la MÊME que celle des deux moteurs — étape 2 de
# roles/apim_promote_api/files/sanitize_archive.py et
# labctl/internal/adapter/webmethods/archive.go:157-164 — donc le harnais cesse
# d'être plus fragile que ce qu'il éprouve. Whitelist {API, Policy,
# PolicyAction}, et les `<dependsOn>` qui pointent ailleurs disparaissent avec.
# AUCUNE assertion ne change : le harnais compte toujours 22 épreuves.
#
# Idempotente : la rejouer sur un ACDL déjà purgé ne fait rien. Les trois sites
# de re-zip l'appellent, bien que deux d'entre eux héritent d'une archive déjà
# purgée — un futur changement de leur source ne doit pas rouvrir le trou en
# silence.
cat > "$WORK/purge_acdl.py" <<'PYEOF'
import re, sys
KEEP = {"API", "Policy", "PolicyAction"}
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
for t in set(re.findall(r'<asset name="([A-Za-z]+)\.', s)):
    if t in KEEP:
        continue
    s = re.sub(r'\s*<asset name="' + re.escape(t) + r'\.[^"]*".*?</asset>', "", s, flags=re.S)
    s = re.sub(r'\s*<asset name="' + re.escape(t) + r'\.[^"]*"[^>]*/>', "", s)
    s = re.sub(r"\s*<dependsOn>APIGateway:" + re.escape(t) + r"\.[^<]*</dependsOn>", "", s)
open(path, "w", encoding="utf-8").write(s)
PYEOF
purge_acdl() { python3 "$WORK/purge_acdl.py" "$1/APIGatewayAssets.acdl"; }

# ---------- setup : API jetable routée ${alias}, alias-first -----------------
say "setup : alias-first + API jetable + routing \${$ALIAS}"
ALIAS_ID=$(adm -H "Content-Type: application/json" -X POST "$GW/alias" \
  -d "{\"name\":\"$ALIAS\",\"type\":\"endpoint\",\"endPointURI\":\"http://poc-token-echo:8080/backend/dev\"}" \
  | jq -r '.id // .alias.id // empty')
[ -n "$ALIAS_ID" ] && ok "alias créé ($ALIAS_ID)" || { ko "création alias"; exit 1; }

cat > "$WORK/c.yaml" <<EOF
openapi: 3.0.0
info: { title: $API, version: 1.0.0 }
servers: [ { url: "http://poc-token-echo:8080" } ]
paths: { /ping: { get: { operationId: ping, responses: { '200': { description: ok } } } } }
EOF
API_ID=$(adm -F "file=@$WORK/c.yaml;type=application/x-yaml" -F type=openapi \
  -F "apiName=$API" -F apiVersion=1.0.0 "$GW/apis" | jq -r '.apiResponse.api.id // empty')
[ -n "$API_ID" ] && ok "API créée ($API_ID)" || { ko "création API"; exit 1; }
adm -X PUT "$GW/apis/$API_ID/activate" -o /dev/null

# re-pointer le routing sur ${alias} VIA L'ARCHIVE (0-coupure, pas de PUT admin)
adm "$GW/archive?apis=$API_ID" -o "$WORK/a0.zip"
mkdir -p "$WORK/a0" && unzip -qo "$WORK/a0.zip" -d "$WORK/a0"
RPA=$(grep -rl straightThroughRouting "$WORK/a0/API"); [ -n "$RPA" ] || { ko "routing action introuvable"; exit 1; }
jq --arg u "\${$ALIAS}/\${sys:resource_path}" \
  '(.parameters[] | select(.templateKey=="endpointUri") | .values) = [$u]' "$RPA" > "$RPA.n" && mv "$RPA.n" "$RPA"
purge_acdl "$WORK/a0"
( cd "$WORK/a0" && zip -qrX ../a1.zip APIGatewayAssets.acdl API )
R=$(adm -F "file=@$WORK/a1.zip;type=application/zip" "$GW/archive?overwrite=apis,policies,policyactions" \
  | jq -r '[.ArchiveResult[]|to_entries[]|select(.value.status!="Success")]|length')
check "$R" "0" "T1 archive patchée \${alias} importée (tout Success, API active jamais désactivée)"
P=$(curl -sS -m 8 "$DP/$API/1.0.0/ping" | jq -r '.path // empty')
check "$P" "/backend/dev/ping" "T2 routing via \${alias} effectif au data-plane"

# ---------- T3 : GUID préservé + refus sans overwrite ------------------------
say "T3 : same-ID sans overwrite -> Asset already exists (jamais de doublon)"
R=$(adm -F "file=@$WORK/a1.zip;type=application/zip" "$GW/archive" \
  | jq -r '[.ArchiveResult[]|to_entries[]|select(.value.status=="Failed")]|length')
[ "$R" -gt 0 ] && ok "refus sans overwrite" || ko "refus sans overwrite"
N=$(adm "$GW/apis" | jq "[.apiResponse[]|select(.api.id==\"$API_ID\")]|length")
check "$N" "1" "T3 aucune duplication (1 seule occurrence du GUID)"

# ---------- T4 : 0-coupure sous charge ---------------------------------------
say "T4 : 0-coupure — charge 4 voies pendant l'overwrite"
LOG="$WORK/load.log"; : > "$LOG"; END=$(( $(date +%s) + 12 ))
for _ in 1 2 3 4; do
  ( while [ "$(date +%s)" -lt "$END" ]; do
      printf '%s\n' "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$DP/$API/1.0.0/ping")" >> "$LOG"
    done ) &
done
perl -e 'select(undef,undef,undef,3)'
adm -F "file=@$WORK/a1.zip;type=application/zip" "$GW/archive?overwrite=apis,policies,policyactions" -o /dev/null
wait
TOT=$(wc -l < "$LOG" | tr -d ' '); BAD=$(grep -cv '^200$' "$LOG" || true)
[ "$TOT" -gt 50 ] && [ "$BAD" -eq 0 ] && ok "T4 $TOT/$TOT requêtes 200 pendant l'overwrite" \
  || ko "T4 coupure détectée ($BAD non-200 / $TOT)"

# ---------- T5 : piège isActive ----------------------------------------------
say "T5 : une archive isActive:false DÉSACTIVE l'API (piège) — puis réparation"
mkdir -p "$WORK/inact" && unzip -qo "$WORK/a1.zip" -d "$WORK/inact"
APIREC="$WORK/inact/API/API.$API_ID/API.$API_ID"
python3 - "$APIREC" <<'EOF'
import json,sys
r=json.load(open(sys.argv[1])); r["isActive"]=False; json.dump(r,open(sys.argv[1],"w"))
EOF
purge_acdl "$WORK/inact"
( cd "$WORK/inact" && zip -qrX ../inact.zip APIGatewayAssets.acdl API )
adm -F "file=@$WORK/inact.zip;type=application/zip" "$GW/archive?overwrite=apis,policies,policyactions" -o /dev/null
A=$(adm "$GW/apis/$API_ID" | jq -r '.apiResponse.api.isActive')
check "$A" "false" "T5 l'import isActive:false a bien désactivé (piège confirmé)"
adm -F "file=@$WORK/a1.zip;type=application/zip" "$GW/archive?overwrite=apis,policies,policyactions" -o /dev/null
A=$(adm "$GW/apis/$API_ID" | jq -r '.apiResponse.api.isActive')
check "$A" "true" "T5 ré-import isActive:true = réparation 0-coupure"

# ---------- T6 : flip d'alias à chaud + non-clobber --------------------------
say "T6 : per-env — flip d'alias à chaud, re-import sans clobber"
REC=$(adm "$GW/alias/$ALIAS_ID")
printf '%s' "$REC" | jq '(.alias // .) | .endPointURI="http://poc-token-echo:8080/backend/prod"' \
  | adm -H "Content-Type: application/json" -X PUT "$GW/alias/$ALIAS_ID" -d @- -o /dev/null
P=$(curl -sS -m 8 "$DP/$API/1.0.0/ping" | jq -r '.path // empty')
check "$P" "/backend/prod/ping" "T6 flip de valeur pris en compte PAR REQUÊTE (sans toucher l'API)"
adm -F "file=@$WORK/a1.zip;type=application/zip" "$GW/archive?overwrite=apis,policies,policyactions" -o /dev/null
V=$(adm "$GW/alias/$ALIAS_ID" | jq -r '(.alias // .).endPointURI')
check "$V" "http://poc-token-echo:8080/backend/prod" "T6 valeur d'alias LOCALE préservée au re-import"

# ---------- T7 : l'export embarque l'Alias -> scoped overwrite le skippe -----
say "T7 : export d'une API routée \${alias} — l'Alias embarqué est skippé (pas clobbé)"
adm "$GW/archive?apis=$API_ID" -o "$WORK/a2.zip"
unzip -l "$WORK/a2.zip" | grep -q "Alias/" && ok "T7 l'export EMBARQUE l'Alias (fait)" \
  || ko "T7 Alias absent de l'export (inattendu)"
ROWS=$(adm -F "file=@$WORK/a2.zip;type=application/zip" "$GW/archive?overwrite=apis,policies,policyactions")
AS=$(printf '%s' "$ROWS" | jq -r '[.ArchiveResult[]|to_entries[]|select(.key=="Alias")][0].value.overwritten')
check "$AS" "false" "T7 Alias skippé par l'overwrite scoped"
V=$(adm "$GW/alias/$ALIAS_ID" | jq -r '(.alias // .).endPointURI')
check "$V" "http://poc-token-echo:8080/backend/prod" "T7 valeur locale intacte (pas de clobber)"

# ---------- T8 : souscription d'application intacte --------------------------
say "T8 : application + souscription survivent à l'overwrite"
APP_ID=$(adm -H "Content-Type: application/json" -X POST "$GW/applications" \
  -d '{"name":"spike079t-app","version":"1.0"}' | jq -r '.id // empty')
adm -H "Content-Type: application/json" -X PUT "$GW/applications/$APP_ID/apis" \
  -d "{\"apiIDs\":[\"$API_ID\"]}" -o /dev/null
adm -F "file=@$WORK/a1.zip;type=application/zip" "$GW/archive?overwrite=apis,policies,policyactions" -o /dev/null
R=$(adm "$GW/applications/$APP_ID/apis" | jq -r ".apiIDs | index(\"$API_ID\") != null")
check "$R" "true" "T8 souscription (app->API par GUID) intacte après overwrite"

# ---------- T9 : env vierge — GUID iso + arrive active -----------------------
say "T9 : env vierge simulé — delete complet puis import fresh"
# une app SOUSCRITE bloque le delete de l'API : la retirer d'abord (ordre réel
# d'un teardown d'env), sinon le delete échoue en silence et T9 ment.
adm -X DELETE "$GW/applications/$APP_ID" -o /dev/null; APP_ID=""
adm -X PUT "$GW/apis/$API_ID/deactivate" -o /dev/null
DC=$(adm -o /dev/null -w '%{http_code}' -X DELETE "$GW/apis/$API_ID")
check "$DC" "204" "T9 delete de l'API (env vierge) effectif"
R=$(adm -F "file=@$WORK/a1.zip;type=application/zip" "$GW/archive" \
  | jq -r '[.ArchiveResult[]|to_entries[]|select(.value.status!="Success")]|length')
check "$R" "0" "T9 import fresh tout Success"
G=$(adm "$GW/apis/$API_ID" | jq -r '.apiResponse.api.id // empty')
check "$G" "$API_ID" "T9 GUID ISO (identique à l'archive) sur env vierge"
A=$(adm "$GW/apis/$API_ID" | jq -r '.apiResponse.api.isActive')
check "$A" "true" "T9 arrive ACTIVE (archive isActive:true)"

# ---------- T10 : L2 — archive synthétisée à GUID choisis --------------------
say "T10 : L2 — archive 100% synthétisée (GUID authored, sans ExportReport)"
L2_ID=$(python3 - "$WORK" "$API_ID" <<'EOF'
import json,os,re,shutil,subprocess,sys,uuid,zipfile
work,api_id=sys.argv[1],sys.argv[2]
src=os.path.join(work,"l2src"); shutil.rmtree(src,ignore_errors=True); os.makedirs(src)
with zipfile.ZipFile(os.path.join(work,"a1.zip")) as z: z.extractall(src)
ids={api_id:str(uuid.uuid4())}
for r,_,fs in os.walk(os.path.join(src,"API")):
    for f in fs:
        m=re.match(r'^[A-Za-z]+\.([0-9a-f-]{36})$',f)
        if m and m.group(1) not in ids: ids[m.group(1)]=str(uuid.uuid4())
def sub(s):
    for o,n in ids.items(): s=s.replace(o,n)
    return s.replace("spike079t-api","spike079t-l2")
dst=os.path.join(work,"l2dst"); shutil.rmtree(dst,ignore_errors=True); os.makedirs(dst)
open(os.path.join(dst,"APIGatewayAssets.acdl"),"w").write(sub(open(os.path.join(src,"APIGatewayAssets.acdl")).read()))
for r,_,fs in os.walk(os.path.join(src,"API")):
    for f in fs:
        p=os.path.join(r,f); rel=sub(os.path.relpath(p,src)); op=os.path.join(dst,rel)
        os.makedirs(os.path.dirname(op),exist_ok=True); open(op,"w").write(sub(open(p).read()))
subprocess.run([sys.executable,os.path.join(work,"purge_acdl.py"),os.path.join(dst,"APIGatewayAssets.acdl")],check=True)
os.chdir(dst); subprocess.run(["zip","-qrX",os.path.join(work,"l2.zip"),"APIGatewayAssets.acdl","API"],check=True)
print(ids[api_id])
EOF
)
R=$(adm -F "file=@$WORK/l2.zip;type=application/zip" "$GW/archive" \
  | jq -r '[.ArchiveResult[]|to_entries[]|select(.value.status!="Success")]|length')
check "$R" "0" "T10 import de la synthèse tout Success"
G=$(adm "$GW/apis/$L2_ID" | jq -r '.apiResponse.api.id // empty')
check "$G" "$L2_ID" "T10 le GUID AUTHORED est celui de la gateway (id-map maîtrisé)"
P=$(curl -sS -m 8 "$DP/spike079t-l2/1.0.0/ping" | jq -r '.path // empty')
check "$P" "/backend/prod/ping" "T10 la synthèse route via \${alias} au data-plane"

# ---------- bilan ------------------------------------------------------------
say "BILAN"
printf '  PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
