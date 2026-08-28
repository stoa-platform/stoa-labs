#!/usr/bin/env bash
# test-promote-sans-recopie.sh — porte de la spec 2026-08-28 : le manifeste de
# promotion se rend, s'épingle et se lit SANS recopie humaine. Épreuves hors
# ligne (lib pure + gabarit + miroirs) ; l'E2E se rend par builds réels.
#
# shellcheck disable=SC2015
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*" >&2; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# shellcheck source=scripts/lib/promote-manifest.sh
. scripts/lib/promote-manifest.sh

# fixture : dépôt d'équipe minimal
mkdir -p "$TMP/team/apis"
cat > "$TMP/team/apis/demo-api.publish.yml" <<'EOF'
apim_api:
  name: "demo-api"
  version: "2.1.0"
  inbound:
    mode: "jwt"
EOF

echo "== 1. rendu nominal depuis publish.yml =="
if render_promote_manifest "$TMP/team" demo-api gateways/templates/promote.yml.tmpl; then
  M="$TMP/team/apis/demo-api.promote.yml"
  grep -q 'name: "demo-api"' "$M" && grep -q 'version: "2.1.0"' "$M" \
    && ok "name/version dérivés du publish.yml" || ko "name/version non dérivés"
  python3 - "$M" <<'PY' && ok "YAML parse (chemin ansible)" || ko "YAML illisible"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d["apim_promote"]["name"] == "demo-api"
assert d["apim_promote"]["guid"] == ""
PY
  # exclut les lignes de commentaire : le gabarit DOCUMENTE ces noms de clé
  # dans son en-tête (AUTHORING LÉGITIME, étape 1) — un grep plein-texte les
  # y trouverait sans qu'aucune clé ne soit réellement posée.
  for cle in backend_alias cred_alias scope_mapping per_env; do
    grep -vE '^\s*#' "$M" | grep -q "$cle" && ko "clé interdite présente : $cle (champ vide ≠ absence, T10)" || :
  done
  ok "aucune clé optionnelle posée vide"
else
  ko "rendu nominal en échec"
fi

echo "== 2. publish.yml absent ⇒ refus nommé =="
mkdir -p "$TMP/vide/apis"
OUT=$(render_promote_manifest "$TMP/vide" fantome gateways/templates/promote.yml.tmpl 2>&1) \
  && ko "rendu accepté sans publish.yml" \
  || { echo "$OUT" | grep -q PUBLISH_MANIFEST_ABSENT && ok "PUBLISH_MANIFEST_ABSENT" || ko "refus sans nom ($OUT)"; }

echo "== 3. épinglage guid+sha : chirurgical, commentaires préservés =="
M="$TMP/team/apis/demo-api.promote.yml"
AVANT_COMMENTAIRES=$(grep -c '^\s*#' "$M")
pin_promote_manifest "$M" "14c2529e-0000-4000-8000-00000000aaaa" \
  "1111111111111111111111111111111111111111111111111111111111111111" \
  && ok "pin rc=0" || ko "pin en échec"
python3 - "$M" <<'PY' && ok "guid+sha relus par yaml" || ko "valeurs épinglées absentes"
import sys, yaml
p = yaml.safe_load(open(sys.argv[1]))["apim_promote"]
assert p["guid"] == "14c2529e-0000-4000-8000-00000000aaaa"
assert p["archive_sha256"] == "1" * 64
PY
[ "$(grep -c '^\s*#' "$M")" -eq "$AVANT_COMMENTAIRES" ] \
  && ok "commentaires préservés" || ko "commentaires perdus (édition non chirurgicale)"

echo "== 4. épinglage idempotent + réalignement de version =="
COPIE=$(cat "$M")
pin_promote_manifest "$M" "14c2529e-0000-4000-8000-00000000aaaa" \
  "1111111111111111111111111111111111111111111111111111111111111111"
[ "$(cat "$M")" = "$COPIE" ] && ok "second pin = aucun diff" || ko "pin non idempotent"
pin_promote_manifest "$M" "14c2529e-0000-4000-8000-00000000aaaa" \
  "2222222222222222222222222222222222222222222222222222222222222222" "2.2.0" \
  && ok "pin versionné rc=0 (relecture interne version+archive passée)" || ko "pin versionné refusé à tort"
grep -q 'version: "2.2.0"' "$M" && grep -q 'demo-api-2.2.0.archive.zip' "$M" \
  && ok "version+archive réalignés" || ko "réalignement version manquant"

echo "== 5. réalignement version+archive : relu par YAML après un pin versionné (pas juste grep) =="
pin_promote_manifest "$M" "14c2529e-0000-4000-8000-00000000aaaa" \
  "3333333333333333333333333333333333333333333333333333333333333333" "2.3.0" \
  && ok "second pin versionné rc=0" || ko "second pin versionné refusé à tort"
python3 - "$M" <<'PY' && ok "version+archive relus par yaml (pas seulement grep)" || ko "version+archive non relus"
import sys, yaml
p = yaml.safe_load(open(sys.argv[1]))["apim_promote"]
assert p["version"] == "2.3.0"
assert p["archive"].endswith("/demo-api-2.3.0.archive.zip")
PY

echo "== 6. archive hors-forme (suffixe pré-release résiduel) ⇒ refus nommé, jamais silencieux =="
# reproduit le piège de la revue : la ligne archive: porte déjà un suffixe que
# le sed de réalignement (classe [0-9][0-9.]* seulement) ne sait pas matcher —
# sans la relecture, version: changerait et archive: resterait périmée SANS
# aucun signal.
HF="$TMP/hors-forme.promote.yml"
cp "$M" "$HF"
python3 - "$HF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace(
    'archive: "{{ playbook_dir }}/../dist/demo-api-2.3.0.archive.zip"',
    'archive: "{{ playbook_dir }}/../dist/demo-api-2.3.0-rc1.archive.zip"')
open(p, "w").write(s)
PY
OUT=$(pin_promote_manifest "$HF" "14c2529e-0000-4000-8000-00000000aaaa" \
  "4444444444444444444444444444444444444444444444444444444444444444" "2.4.0" 2>&1) \
  && ko "pin accepté malgré l'archive hors-forme (silencieux — le bug de la revue)" \
  || { echo "$OUT" | grep -q REALIGNEMENT_NON_APPLIQUE && ok "REALIGNEMENT_NON_APPLIQUE" || ko "refus sans nom ($OUT)"; }

echo "== 7. manifest_pinned_digest : présent / absent / illisible =="
[ "$(manifest_pinned_digest "$M")" = "$(printf '3%.0s' $(seq 64))" ] \
  && ok "digest lu" || ko "digest non lu"
[ -z "$(manifest_pinned_digest "$TMP/team/apis/inexistant.promote.yml")" ] \
  && ok "fichier absent ⇒ chaîne vide, rc=0" || ko "fichier absent mal géré"
printf '{{invalide' > "$TMP/cassé.yml"
manifest_pinned_digest "$TMP/cassé.yml" 2>/dev/null \
  && ko "YAML illisible accepté" || ok "YAML illisible ⇒ rc=1 (MANIFESTE_ILLISIBLE)"

echo "== 8. publish_manifest_version =="
[ "$(publish_manifest_version "$TMP/team" demo-api)" = "2.1.0" ] \
  && ok "version du publish.yml lue" || ko "version non lue"

echo "== 9. labctl tolère la clé épinglée (parse non strict FIGÉ par le test Go) =="
command -v go >/dev/null 2>&1 || { ko "go absent — l'épreuve labctl ne peut pas se rendre (ne PAS sauter en silence)"; }
if command -v go >/dev/null 2>&1; then
  ( cd labctl && go test ./cmd/labctl -run TestPromoteSpecToleratesPinnedSha >/dev/null 2>&1 ) \
    && ok "TestPromoteSpecToleratesPinnedSha PASS" || ko "labctl refuse archive_sha256"
fi

echo; echo "bilan : $PASS ✅  $FAIL ❌"
[ "$FAIL" -eq 0 ]
