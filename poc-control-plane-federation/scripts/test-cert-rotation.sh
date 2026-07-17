#!/usr/bin/env bash
# test-cert-rotation.sh — preuve X/X du nommage daté des certificats consommateur
# + rotation replace/overlap + purge des expirés (rôle apim_selfservice_app,
# demande client : les scans d'exploitation lisent '-exp-YYYYMMDD' — date GMT
# du NotAfter). Assets JETABLES (spike079c-app sur demo-selfservice), nettoyés.
#   GW_ADMIN=... WM_USER=... WM_PASS=... ./scripts/test-cert-rotation.sh
set -euo pipefail
SPIKE="$(mktemp -d /tmp/certrot.XXXXXX)"
CERTS="$SPIKE/certs"; mkdir -p "$CERTS"
trap 'rm -rf "$SPIKE"' EXIT
GW="${GW_ADMIN:-http://localhost:5555/rest/apigateway}"
AUTH="${WM_USER:-Administrator}:${WM_PASS:-manage}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
adm(){ curl -sS -u "$AUTH" -H "Accept: application/json" "$@"; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

echo "== certs jetables : A (365 j), B (400 j), C (EXPIRÉ) =="
openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -days 365 \
  -subj "/CN=spike079c-A" -out "$CERTS/a.crt" 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -days 400 \
  -subj "/CN=spike079c-B" -out "$CERTS/b.crt" 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null \
  -not_before 20240101000000Z -not_after 20250101000000Z \
  -subj "/CN=spike079c-C-expired" -out "$CERTS/c.crt" 2>/dev/null \
  || { echo "  (⚠ -not_after non supporté : purge non testée)"; : > "$CERTS/c.crt"; }
YMD_A=$(openssl x509 -noout -enddate -in "$CERTS/a.crt" | sed 's/notAfter=//' | tr -s ' ' \
  | awk '{cmd="date -j -u -f \"%b %d %H:%M:%S %Y %Z\" \""$0"\" +%Y%m%d"; cmd | getline d; print d}')
YMD_B=$(openssl x509 -noout -enddate -in "$CERTS/b.crt" | sed 's/notAfter=//' | tr -s ' ' \
  | awk '{cmd="date -j -u -f \"%b %d %H:%M:%S %Y %Z\" \""$0"\" +%Y%m%d"; cmd | getline d; print d}')
echo "  A exp $YMD_A ; B exp $YMD_B"

mkmanifest(){ # $1=cert $2=rotation
cat > "$SPIKE/consumer-test.yml" <<EOF
apim_ss_app:
  name: "spike079c-app"
  api: "demo-selfservice"
  api_version: "1.0.0"
  description: "test rotation cert (jetable)"
  contact_emails: []
  ip_allowlist: []
  public_cert_ref: "$1"
  cert_rotation: "$2"
  backend: { header: "", value_template: "" }
  enforce: []
EOF
}

run_role(){ (cd "$REPO" && ansible-playbook -i ansible/inventory.lab.ini ansible/selfservice-app.yml \
  -e apim_ss_manifest="$SPIKE/consumer-test.yml" 2>&1 | grep -E "CERT_|fatal|failed=[1-9]" | tail -4); }

certid(){ adm "$GW/applications" | jq -r '.applications[] | select(.name=="spike079c-app") | .id'; }
certfield(){ # $1 = jq expr on the httpsCertificate identifier
  adm "$GW/applications/$(certid)" \
    | jq -r '(.applications // [.]) | .[0].identifiers[] | select(.key=="httpsCertificate") | '"$1"; }

echo "== T1 : run REPLACE cert A -> name <app>-exp-$YMD_A =="
mkmanifest "$CERTS/a.crt" replace; run_role
N=$(certfield '.name'); V=$(certfield '.value | length')
[ "$N" = "spike079c-app-exp-$YMD_A" ] && ok "T1 name=$N" || ko "T1 name=$N (attendu spike079c-app-exp-$YMD_A)"
[ "$V" = "1" ] && ok "T1 1 valeur" || ko "T1 $V valeurs"

echo "== T2 : run OVERLAP cert B -> values [A,B], name exp-A+B trié =="
mkmanifest "$CERTS/b.crt" overlap; run_role
N=$(certfield '.name'); V=$(certfield '.value | length')
EXP=$(printf '%s\n%s\n' "$YMD_A" "$YMD_B" | sort | paste -sd+ -)
[ "$N" = "spike079c-app-exp-$EXP" ] && ok "T2 name=$N" || ko "T2 name=$N (attendu spike079c-app-exp-$EXP)"
[ "$V" = "2" ] && ok "T2 2 valeurs (chevauchement)" || ko "T2 $V valeurs"

echo "== T3 : re-run OVERLAP B (double-run) -> idempotent =="
run_role
V=$(certfield '.value | length'); N2=$(certfield '.name')
[ "$V" = "2" ] && [ "$N2" = "$N" ] && ok "T3 idempotent (2 valeurs, même nom)" || ko "T3 valeurs=$V nom=$N2"

if [ -s "$CERTS/c.crt" ]; then
  echo "== T4 : injecter le cert EXPIRÉ C par REST puis run OVERLAP -> purgé =="
  CDER=$(awk '/BEGIN CERT/{f=1;next}/END CERT/{f=0}f' "$CERTS/c.crt" | tr -d '\n')
  APPID=$(certid)
  REC=$(adm "$GW/applications/$APPID" | jq '(.applications // [.]) | .[0]')
  printf '%s' "$REC" | jq --arg der "$CDER" \
    '.identifiers = [(.identifiers[] | if .key=="httpsCertificate" then .value += [$der] else . end)]' \
    | adm -H "Content-Type: application/json" -X PUT "$GW/applications/$APPID" -d @- -o /dev/null
  V=$(certfield '.value | length')
  [ "$V" = "3" ] && ok "T4 cert expiré injecté (3 valeurs)" || ko "T4 injection ($V valeurs)"
  run_role
  V=$(certfield '.value | length'); N3=$(certfield '.name')
  [ "$V" = "2" ] && [ "$N3" = "$N" ] && ok "T4 expiré PURGÉ (retour 2 valeurs, nom $N3)" \
    || ko "T4 purge (valeurs=$V nom=$N3)"
fi

echo "== T5 : verify play -> CERT_NAME_CONFIRMED =="
(cd "$REPO" && ansible-playbook -i ansible/inventory.lab.ini ansible/selfservice-app-verify.yml \
  -e apim_ss_manifest="$SPIKE/consumer-test.yml" 2>&1 | grep -E "CERT_NAME_|failed=" | tail -3)

echo "== cleanup =="
APPID=$(certid); [ -n "$APPID" ] && echo "  app: $(adm -o /dev/null -w '%{http_code}' -X DELETE "$GW/applications/$APPID")"
printf 'BILAN PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]