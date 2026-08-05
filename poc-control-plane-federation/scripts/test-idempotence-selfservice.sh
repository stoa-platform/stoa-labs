#!/usr/bin/env bash
# test-idempotence-selfservice.sh — preuve X/X que le rôle apim_selfservice_app
# CONVERGE au lieu de RÉÉCRIRE : un second apply sur une application déjà
# conforme ne doit toucher NI la gateway NI le compteur `changed`.
#
# POURQUOI CE TEST EXISTE (mesuré le 2026-08-05, avant correctif) : le rôle
# émettait quatre écritures INCONDITIONNELLES à chaque exécution — POST
# /assets/team, PUT /applications/{id}/apis, PUT /applications/{id} et PUT
# /policyActions/{id}. Sur une application déjà convergée, trois runs
# consécutifs donnaient trois `lastupdated` différents ET trois UUID
# d'identifier différents : la valeur était identique, mais l'objet d'identité
# était détruit puis recréé à chaque déploiement. Le PLAY RECAP, lui, affichait
# `changed=0` — `ansible.builtin.uri` ne fait aucune détection de changement,
# il rapporte `ok` qu'il ait écrit ou non. Le compteur d'idempotence du
# pipeline était donc structurellement vert : il ne pouvait PAS voir le défaut.
#
# CE QUI REND CE TEST DISCRIMINANT — et c'est le point, pas le nombre de cas :
#   - il ne se contente pas d'exiger `changed=0` sur le re-run (le code buggé
#     le donnait déjà) : il exige AUSSI `changed>0` sur le run qui crée. Un
#     `changed` toujours nul échoue donc en T2, un `changed` toujours vrai en T5 ;
#   - il ne se contente pas d'exiger une gateway immobile (un rôle qui n'écrit
#     JAMAIS rien y arriverait) : T9 modifie le manifeste et exige que
#     l'écriture reparte. Immobilité ET convergence, sinon la garde ne garde rien.
#
# Assets JETABLES (idem-test-app sur demo-selfservice), nettoyés en sortie.
#   GW_ADMIN=... WM_USER=... WM_PASS=... TEAM=... ./scripts/test-idempotence-selfservice.sh
set -uo pipefail
TMP="$(mktemp -d /tmp/idem.XXXXXX)"
GW="${GW_ADMIN:-http://localhost:5555/rest/apigateway}"
AUTH="${WM_USER:-Administrator}:${WM_PASS:-manage}"
TEAM="${TEAM:-Administrators}"
APP="idem-test-app"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

adm(){ curl -sS -u "$AUTH" -H "Accept: application/json" "$@"; }
appid(){ adm "$GW/applications" | jq -r --arg n "$APP" '.applications[] | select(.name==$n) | .id'; }
cleanup(){
  local id; id="$(appid)"
  [ -n "$id" ] && adm -X DELETE "$GW/applications/$id" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# ── manifeste jetable ────────────────────────────────────────────────────────
mkmanifest(){ # $1 = IP de l'allowlist
cat > "$TMP/manifest.yml" <<EOF
apim_ss_app:
  name: "$APP"
  api: "demo-selfservice"
  api_version: "1.0.0"
  description: "test idempotence (jetable)"
  contact_emails: []
  ip_allowlist: ["$1"]
  public_cert_ref: ""
  backend: { header: "apikey", value_template: "\${backend_apikey}" }
  enforce: ["ipAddressRange"]
EOF
}

# Exécute le rôle exactement comme le fait ci/Jenkinsfile.selfservice (étape 2),
# et rend le nombre de tâches `changed` du PLAY RECAP (ou 'ERR' si le play rate).
run_role(){ # $1 = label du log
  local log="$TMP/$1.log"
  (cd "$REPO" && ansible-playbook -i ansible/inventory.lab.ini ansible/selfservice-app.yml \
     -e apim_ss_manifest="$TMP/manifest.yml" \
     -e apim_ss_team="$TEAM" > "$log" 2>&1)
  if grep -qE 'failed=[1-9]|unreachable=[1-9]' "$log"; then
    printf 'ERR'; return
  fi
  sed -n 's/.*changed=\([0-9]*\).*/\1/p' "$log" | tail -1
}

# État observable côté GATEWAY (la seule source de vérité qui compte ici).
state(){ # imprime "<lastupdated>|<ids des identifiers triés>|<teams triées>"
  local id; id="$(appid)"
  [ -z "$id" ] && { printf 'ABSENT'; return; }
  adm "$GW/applications/$id" | jq -r '
    (.applications // [.]) | .[0]
    | [ .lastupdated,
        ([.identifiers[]? | .id] | sort | join(",")),
        ([.teams[]? | .name] | sort | join(",")) ] | join("|")'
}

echo "== préparation : application jetable '$APP' (supprimée si elle traîne) =="
cleanup_id="$(appid)"; [ -n "$cleanup_id" ] && adm -X DELETE "$GW/applications/$cleanup_id" >/dev/null
mkmanifest "10.99.0.1"

echo "== RUN 1 — création + convergence initiale =="
C1="$(run_role run1)"
S1="$(state)"
[ "$C1" != "ERR" ] && ok "T1 run 1 : play vert" || ko "T1 run 1 : play ROUGE (cf. $TMP/run1.log)"
[ "$C1" != "ERR" ] && [ "${C1:-0}" -gt 0 ] 2>/dev/null \
  && ok "T2 run 1 : changed=$C1 (>0 — la création est SIGNALÉE)" \
  || ko "T2 run 1 : changed=${C1} — une création qui ne se signale pas rend le recap inutile"
[ "$S1" != "ABSENT" ] && ok "T3 run 1 : application créée sur la gateway" || ko "T3 run 1 : application ABSENTE"
echo "     état après run 1 : $S1"

echo "== RUN 2 — MÊME manifeste : doit être un NO-OP strict =="
C2="$(run_role run2)"
S2="$(state)"
[ "$C2" != "ERR" ] && ok "T4 run 2 : play vert" || ko "T4 run 2 : play ROUGE (cf. $TMP/run2.log)"
[ "$C2" = "0" ] && ok "T5 run 2 : changed=0" || ko "T5 run 2 : changed=$C2 — le rôle réécrit une cible déjà conforme"
[ "$S2" = "$S1" ] && ok "T6 run 2 : gateway INCHANGÉE" \
  || ko "T6 run 2 : gateway MODIFIÉE
       avant : $S1
       après : $S2"
echo "     état après run 2 : $S2"

echo "== RUN 3 — troisième passage : la dérive ne doit pas être différée =="
C3="$(run_role run3)"
S3="$(state)"
[ "$C3" = "0" ] && ok "T7 run 3 : changed=0" || ko "T7 run 3 : changed=$C3"
[ "$S3" = "$S1" ] && ok "T8 run 3 : gateway toujours INCHANGÉE" \
  || ko "T8 run 3 : gateway MODIFIÉE
       run 1 : $S1
       run 3 : $S3"

echo "== RUN 4 — manifeste MODIFIÉ : l'écriture doit REPARTIR (anti no-op universel) =="
mkmanifest "10.99.0.2"
C4="$(run_role run4)"
S4="$(state)"
[ "$C4" != "ERR" ] && [ "${C4:-0}" -gt 0 ] 2>/dev/null \
  && ok "T9 run 4 : changed=$C4 (>0 — la modification est appliquée ET signalée)" \
  || ko "T9 run 4 : changed=${C4} — un rôle qui n'écrit plus jamais n'est pas idempotent, il est mort"
NEWIP="$(adm "$GW/applications/$(appid)" | jq -r '(.applications // [.]) | .[0].identifiers[]? | select(.key=="ipAddressRange") | .value[0]')"
[ "$NEWIP" = "10.99.0.2-10.99.0.2" ] \
  && ok "T10 run 4 : allowlist convergée -> $NEWIP" \
  || ko "T10 run 4 : allowlist=$NEWIP (attendu 10.99.0.2-10.99.0.2)"

echo
echo "== $PASS/$((PASS+FAIL)) =="
[ "$FAIL" -eq 0 ] || { echo "  logs : $TMP (conservés en cas d'échec)"; trap 'adm -X DELETE "$GW/applications/$(appid)" >/dev/null 2>&1' EXIT; exit 1; }
