#!/usr/bin/env bash
# test-app-request-a1.sh — preuve X/X du jalon A1 (GOAL-cd-applications-2026-09-02) :
#   le manifeste d'application devient MULTI-PALIER — une demande n'écrit que
#   sa clé `per_env.<env>`, les champs trans-paliers sont FIGÉS à la première
#   demande (CONTRAT_DIVERGENT sinon), et aucun octet hors de cette clé ne bouge.
#
# Fichiers couverts : scripts/lib/app-manifest.sh (la substance : lecture,
# contrat, fusion textuelle) et scripts/provision-request.sh (le branchement).
#
# TROIS TERRAINS, sur le patron de test-app-request-v2/v3.sh :
#   - Section A : la LIB seule, HORS LIGNE, sur des fichiers locaux — la fusion
#     ligne à ligne, le contrat figé, le refus des formes anciennes.
#   - Section B : HORS LIGNE — compilation (bash -n, shellcheck) et gardes du
#     script qui sortent AVANT le clone.
#   - Section C : contre le VRAI Gitea du lab (poc-gitea, port 13000) — le
#     parcours dev → (merge simulé) → rec, les contre-épreuves de la porte A1,
#     sur une branche de BASE JETABLE (jamais `main`). Objets jetables préfixés
#     p3a1 (base `p3a1-base-<ts>`, apps `p3a1<cas><ts>`), branches nettoyées en
#     fin de run. MESURÉ (Gitea 1.22.6,
#     CloseBranchPulls) : supprimer la base ou une tête FERME les PR qui la
#     visent — l'événement `closed` porte merged=false et ne déclenche donc
#     PAS provision-apply (filtre `closed|true`). Cette suite ne laisse aucune
#     PR ouverte, contrairement aux suites v2/v3 (qui visent `main`).
#
#   GITEA_TOKEN_FILE=<fichier 0600> ./scripts/test-app-request-a1.sh
#   (défaut : mint un token jetable via `docker exec -u git poc-gitea ...`
#   si GITEA_TOKEN_FILE est absent ET que le conteneur poc-gitea existe.)
#   A1_OFFLINE=1 ./scripts/test-app-request-a1.sh   — sections A et B seules.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# Le script sous test source ses libs RELATIVEMENT au cwd (`. scripts/lib/…`,
# comme le job Jenkins qui fait dir('poc-control-plane-federation')) : la suite
# se place donc à la racine du dépôt, d'où qu'elle soit lancée.
cd "$REPO" || exit 1
S="$REPO/scripts/provision-request.sh"
LIB="$REPO/scripts/lib/app-manifest.sh"
TS="$(date +%s)"
TMP="$(mktemp -d /tmp/apprqa1.XXXXXX)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
# `diff a b | grep …` sous pipefail rend le rc de diff (1 dès que les fichiers
# diffèrent) — le grep aurait beau matcher, la condition serait fausse.
dif(){ diff "$1" "$2" || true; }

CLEAN_BRANCHES=()
GITEA_TOKEN=""
GH="http://localhost:13000"
cleanup(){
  if [ -n "${GITEA_TOKEN:-}" ] && [ ${#CLEAN_BRANCHES[@]} -gt 0 ]; then
    for b in "${CLEAN_BRANCHES[@]}"; do
      curl -s -o /dev/null -X DELETE -H "Authorization: token $GITEA_TOKEN" \
        "$GH/api/v1/repos/ci/stoa-labs/branches/${b}" 2>/dev/null || true
    done
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# ── fixtures locales (forme D1 de la spec) ──────────────────────────────────
write_idp(){ # $1=fichier $2=app $3=per_env lines (déjà indentées 4) — "" = bloc sans ligne
  cat > "$1" <<YAML
---
# $2.ansible.yml — GÉNÉRÉ par une demande de provisioning (maillon 1).
# Appelant : oig-provisioner (azp). Ne PAS éditer à la main : re-générer via la demande.
# Mode IDP : le client OAuth2 existe côté IdP ; Git porte la CLAIM qui identifie l'app.
apim_ss_app:
  name: "$2"
  api: "accounts-read"
  api_version: "1.0.0"
  description: "Provisioned via oig-provisioner (idp)"
  contact_emails: []
  enforce: []
  auth:
    mode: "idp"
    server_alias: "KeycloakStoaLab"
    audience: "accounts-read"
    claim: { name: "azp" }
  per_env:
${3}
YAML
}

echo "═══ Section A — la bibliothèque seule (HORS LIGNE, fichiers locaux) ═══"
if [ ! -r "$LIB" ]; then
  ko "lib absente : $LIB"
else
  # shellcheck source=scripts/lib/app-manifest.sh
  . "$LIB"

  # ── A.1 lecture ──
  F="$TMP/read.yml"; write_idp "$F" "appa" '    dev: { auth: { claim: { value: "appa-dev" } } }'
  OUT=$(app_manifest_read "$F" 2>"$TMP/err"); RC=$?
  if [ "$RC" -eq 0 ] \
     && printf '%s\n' "$OUT" | grep -qx 'MAN_API=accounts-read' \
     && printf '%s\n' "$OUT" | grep -qx 'MAN_API_VER=1.0.0' \
     && printf '%s\n' "$OUT" | grep -qx 'MAN_AUDIENCE=accounts-read' \
     && printf '%s\n' "$OUT" | grep -qx 'MAN_MODE=idp' \
     && printf '%s\n' "$OUT" | grep -qx 'MAN_TEAM=' \
     && printf '%s\n' "$OUT" | grep -qx 'MAN_ENVS=dev'; then
    ok "A.1 lecture : api/api_version/audience/mode/team(vide)/envs rendus en KEY=VALUE"
  else
    ko "A.1 lecture : rc=$RC out=$(printf '%s' "$OUT" | tr '\n' ' ') err=$(cat "$TMP/err")"
  fi

  # A.1b team + deux paliers, dans l'ORDRE du fichier
  F="$TMP/read2.yml"; write_idp "$F" "appb" $'    rec: { auth: { claim: { value: "b-rec" } } }\n    dev: { auth: { claim: { value: "b-dev" } } }'
  sed -i.bak 's/^  enforce: \[\]$/  team: "payments-team"\n  enforce: []/' "$F" 2>/dev/null || {
    python3 - "$F" <<'PY'
import sys; p=sys.argv[1]; t=open(p).read().replace('  enforce: []\n','  team: "payments-team"\n  enforce: []\n'); open(p,'w').write(t)
PY
  }
  OUT=$(app_manifest_read "$F" 2>/dev/null); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qx 'MAN_TEAM=payments-team' \
     && printf '%s\n' "$OUT" | grep -qx 'MAN_ENVS=rec dev'; then
    ok "A.1b lecture : team lue, paliers déclarés dans l'ordre du fichier (rec dev)"
  else
    ko "A.1b lecture : rc=$RC out=$(printf '%s' "$OUT" | tr '\n' ' ')"
  fi

  # ── A.2 forme ancienne (claim.value à la racine) refusée ──
  F="$TMP/legacy.yml"
  cat > "$F" <<'YAML'
---
apim_ss_app:
  name: "old"
  api: "accounts-read"
  api_version: "1.0.0"
  description: "Provisioned via oig-provisioner — demande dev (idp)"
  contact_emails: []
  enforce: []
  auth:
    mode: "idp"
    server_alias: "KeycloakStoaLab"
    audience: "accounts-read"
    claim: { name: "azp", value: "old-dev" }
YAML
  ERR=$(app_manifest_read "$F" 2>&1 >/dev/null); RC=$?
  if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'MANIFESTE_LEGACY' && printf '%s' "$ERR" | grep -q 'per_env'; then
    ok "A.2 forme ancienne (claim.value racine, sans per_env) : MANIFESTE_LEGACY, message nommant la migration"
  else
    ko "A.2 forme ancienne : rc=$RC err=$ERR"
  fi

  # ── A.3 fichier illisible / sans apim_ss_app ──
  printf 'pas: du: yaml: [\n' > "$TMP/bad1.yml"
  ERR=$(app_manifest_read "$TMP/bad1.yml" 2>&1 >/dev/null); RC=$?
  [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'MANIFESTE_INVALIDE' \
    && ok "A.3a YAML cassé : MANIFESTE_INVALIDE (rc 2)" || ko "A.3a YAML cassé : rc=$RC err=$ERR"
  printf -- '---\nautre_cle:\n  name: x\n' > "$TMP/bad2.yml"
  ERR=$(app_manifest_read "$TMP/bad2.yml" 2>&1 >/dev/null); RC=$?
  [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'MANIFESTE_INVALIDE' \
    && ok "A.3b sans apim_ss_app : MANIFESTE_INVALIDE (rc 2)" || ko "A.3b sans apim_ss_app : rc=$RC err=$ERR"

  # ── A.4 contrat identique ──
  F="$TMP/ctr.yml"; write_idp "$F" "appc" '    dev: { auth: { claim: { value: "c-dev" } } }'
  ERR=$(app_manifest_check_contract "$F" appc accounts-read 1.0.0 accounts-read idp "" 2>&1); RC=$?
  [ "$RC" -eq 0 ] && ok "A.4 contrat identique (name/api/version/audience/mode/team) : accepté" \
    || ko "A.4 contrat identique refusé : rc=$RC $ERR"

  # ── A.4b scalaire NON quoté édité à la main : relu tel qu'écrit, jamais typé ──
  # (critique de spec, mesuré : `api_version: 1.10` sans guillemets se relisait
  # `1.1` avec safe_load ⇒ CONTRAT_DIVERGENT mensonger sur une demande exacte)
  F="$TMP/unq.yml"; write_idp "$F" "appd" '    dev: { auth: { claim: { value: "d-dev" } } }'
  sed -i.bak 's/^  api_version: "1.0.0"$/  api_version: 1.10/' "$F"; rm -f "$F.bak"
  grep -qx '  api_version: 1.10' "$F" || ko "A.4b (prérequis) la version non quotée n'a pas été posée"
  OUT=$(app_manifest_read "$F" 2>/dev/null)
  ERR=$(app_manifest_check_contract "$F" appd accounts-read 1.10 accounts-read idp "" 2>&1); RC=$?
  [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qx 'MAN_API_VER=1.10' \
    && ok "A.4b api_version: 1.10 NON quoté ⇒ lu '1.10' (pas 1.1), contrat 1.10 accepté (aucun typage implicite)" \
    || ko "A.4b scalaire non quoté : rc=$RC lu=$(printf '%s' "$OUT" | grep MAN_API_VER) err=$ERR"

  # ── A.5 une divergence : api ──
  ERR=$(app_manifest_check_contract "$F" appc payments 1.0.0 accounts-read idp "" 2>&1); RC=$?
  if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'CONTRAT_DIVERGENT' \
     && printf '%s' "$ERR" | grep -q "api : manifeste='accounts-read' demande='payments'"; then
    ok "A.5 api différente : CONTRAT_DIVERGENT nommant le champ et les deux valeurs"
  else
    ko "A.5 api différente : rc=$RC err=$ERR"
  fi

  # ── A.6 trois divergences, TOUTES listées ──
  ERR=$(app_manifest_check_contract "$F" appc payments 2.0.0 accounts-read internal "" 2>&1); RC=$?
  if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q "api : " && printf '%s' "$ERR" | grep -q "api_version : " \
     && printf '%s' "$ERR" | grep -q "mode : manifeste='idp' demande='internal'"; then
    ok "A.6 trois divergences (api, api_version, mode) : les TROIS sont nommées dans le même refus"
  else
    ko "A.6 divergences multiples : rc=$RC err=$ERR"
  fi

  # ── A.7 team : absente des deux côtés = ok ; présente vs absente = divergent ──
  ERR=$(app_manifest_check_contract "$TMP/read2.yml" appb accounts-read 1.0.0 accounts-read idp payments-team 2>&1); RC=$?
  [ "$RC" -eq 0 ] && ok "A.7a team identique (payments-team) : accepté" || ko "A.7a team identique refusé : $ERR"
  ERR=$(app_manifest_check_contract "$TMP/read2.yml" appb accounts-read 1.0.0 accounts-read idp "" 2>&1); RC=$?
  [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q "team : manifeste='payments-team' demande=''" \
    && ok "A.7b team figée vs demande sans team : CONTRAT_DIVERGENT (l'héritage est l'affaire du script, pas de la lib)" \
    || ko "A.7b team figée vs vide : rc=$RC err=$ERR"
  ERR=$(app_manifest_check_contract "$TMP/ctr.yml" appc accounts-read 1.0.0 accounts-read idp other-team 2>&1); RC=$?
  [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q "team : manifeste='' demande='other-team'" \
    && ok "A.7c manifeste sans team vs demande avec team : CONTRAT_DIVERGENT" \
    || ko "A.7c sans team vs team : rc=$RC err=$ERR"
  ERR=$(app_manifest_check_contract "$TMP/ctr.yml" autre-nom accounts-read 1.0.0 accounts-read idp "" 2>&1); RC=$?
  [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q "name : manifeste='appc' demande='autre-nom'" \
    && ok "A.7d name divergent (fichier réutilisé pour une autre app) : CONTRAT_DIVERGENT" \
    || ko "A.7d name divergent : rc=$RC err=$ERR"

  # ── A.8 fusion : INSERTION d'un palier = exactement une ligne ajoutée ──
  F="$TMP/m1.yml"; write_idp "$F" "appm" '    dev: { auth: { claim: { value: "m-dev" } }, ip_allowlist: ["10.0.0.1"] }'
  cp "$F" "$TMP/m1.base"
  ERR=$(app_manifest_merge_env "$F" rec '{ auth: { claim: { value: "m-rec" } } }' 2>&1); RC=$?
  ADDED=$(diff "$TMP/m1.base" "$F" | grep -c '^>'); REMOVED=$(diff "$TMP/m1.base" "$F" | grep -c '^<')
  if [ "$RC" -eq 0 ] && [ "$ADDED" = 1 ] && [ "$REMOVED" = 0 ] \
     && dif "$TMP/m1.base" "$F" | grep -qF '>     rec: { auth: { claim: { value: "m-rec" } } }'; then
    ok "A.8 insertion rec : diff = UNE ligne ajoutée (\`    rec: {…}\`), zéro ligne retirée — aucun octet hors per_env.rec"
  else
    ko "A.8 insertion rec : rc=$RC added=$ADDED removed=$REMOVED err=$ERR"; diff "$TMP/m1.base" "$F"
  fi
  # la ligne dev est INTACTE, octet pour octet
  grep -qxF '    dev: { auth: { claim: { value: "m-dev" } }, ip_allowlist: ["10.0.0.1"] }' "$F" \
    && ok "A.8b la ligne per_env.dev est intacte au caractère près" || ko "A.8b la ligne dev a bougé : $(grep '    dev:' "$F")"
  # le fichier reste du YAML dont per_env porte les DEUX clés
  python3 - "$F" <<'PY' && ok "A.8c YAML rechargé : per_env = {dev, rec}, claim.value distinctes" || ko "A.8c YAML rechargé faux"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))["apim_ss_app"]["per_env"]
assert list(d) == ["dev", "rec"], list(d)
assert d["dev"]["auth"]["claim"]["value"] == "m-dev" and d["rec"]["auth"]["claim"]["value"] == "m-rec"
PY

  # ── A.9 fusion : REMPLACEMENT en place (re-demande sur un palier déclaré) ──
  cp "$F" "$TMP/m2.base"
  ERR=$(app_manifest_merge_env "$F" dev '{ auth: { claim: { value: "m-dev" } }, ip_allowlist: ["10.0.0.1", "10.0.0.2"] }' 2>&1); RC=$?
  ADDED=$(diff "$TMP/m2.base" "$F" | grep -c '^>'); REMOVED=$(diff "$TMP/m2.base" "$F" | grep -c '^<')
  if [ "$RC" -eq 0 ] && [ "$ADDED" = 1 ] && [ "$REMOVED" = 1 ] \
     && sed -n '/^  per_env:/,$p' "$F" | sed -n 2p | grep -q '^    dev: ' \
     && sed -n '/^  per_env:/,$p' "$F" | sed -n 3p | grep -q '^    rec: '; then
    ok "A.9 remplacement dev : UNE ligne changée, ordre des paliers préservé (dev puis rec)"
  else
    ko "A.9 remplacement dev : rc=$RC added=$ADDED removed=$REMOVED err=$ERR"; diff "$TMP/m2.base" "$F"
  fi

  # ── A.10 fusion idempotente ──
  cp "$F" "$TMP/m3.base"
  app_manifest_merge_env "$F" dev '{ auth: { claim: { value: "m-dev" } }, ip_allowlist: ["10.0.0.1", "10.0.0.2"] }' 2>/dev/null
  cmp -s "$TMP/m3.base" "$F" && ok "A.10 même fusion rejouée : fichier identique (idempotence)" \
    || ko "A.10 la fusion rejouée a modifié le fichier"

  # ── A.11 clé préfixe d'une autre (dev vs dev2) : match EXACT ──
  F="$TMP/m4.yml"; write_idp "$F" "appp" '    dev2: { auth: { claim: { value: "p-dev2" } } }'
  cp "$F" "$TMP/m4.base"
  app_manifest_merge_env "$F" dev '{ auth: { claim: { value: "p-dev" } } }' 2>/dev/null; RC=$?
  if [ "$RC" -eq 0 ] && grep -qxF '    dev2: { auth: { claim: { value: "p-dev2" } } }' "$F" \
     && grep -qxF '    dev: { auth: { claim: { value: "p-dev" } } }' "$F" \
     && [ "$(diff "$TMP/m4.base" "$F" | grep -c '^<')" = 0 ]; then
    ok "A.11 env 'dev' avec 'dev2' déjà déclaré : insertion, dev2 intact (match exact de la clé)"
  else
    ko "A.11 collision de préfixe dev/dev2 : rc=$RC"; cat "$F"
  fi

  # ── A.12 bloc per_env ABSENT : créé en fin de fichier, YAML valide ──
  F="$TMP/m5.yml"; write_idp "$F" "appq" ''
  sed -i.bak '/^  per_env:$/d' "$F"; rm -f "$F.bak"
  # write_idp laisse une ligne vide à la place des items : on l'ôte aussi
  python3 - "$F" <<'PY'
import sys; p=sys.argv[1]; t=open(p).read().rstrip('\n')+'\n'; open(p,'w').write(t)
PY
  ! grep -q '^  per_env:' "$F" || ko "A.12 (prérequis) le bloc per_env aurait dû être absent"
  app_manifest_merge_env "$F" dev '{ auth: { claim: { value: "q-dev" } } }' 2>"$TMP/err"; RC=$?
  if [ "$RC" -eq 0 ] && python3 -c "
import sys, yaml
d = yaml.safe_load(open('$F'))['apim_ss_app']
assert d['per_env'] == {'dev': {'auth': {'claim': {'value': 'q-dev'}}}}, d.get('per_env')
" 2>/dev/null; then
    ok "A.12 bloc per_env absent : créé (\`  per_env:\` + la ligne), YAML rechargé correct"
  else
    ko "A.12 bloc absent : rc=$RC err=$(cat "$TMP/err")"; cat "$F"
  fi

  # ── A.13 fichier sans newline final : fusion valide, newline final rétabli ──
  F="$TMP/m6.yml"; write_idp "$F" "appr" '    dev: { auth: { claim: { value: "r-dev" } } }'
  printf '%s' "$(cat "$F")" > "$F"   # retire le \n final
  [ "$(tail -c1 "$F" | od -An -c | tr -d ' ')" != '\n' ] || ko "A.13 (prérequis) le fichier aurait dû finir sans newline"
  app_manifest_merge_env "$F" rec '{ auth: { claim: { value: "r-rec" } } }' 2>/dev/null; RC=$?
  if [ "$RC" -eq 0 ] && [ "$(tail -c1 "$F" | od -An -c | tr -d ' ')" = '\n' ] \
     && grep -qxF '    rec: { auth: { claim: { value: "r-rec" } } }' "$F" \
     && grep -qxF '    dev: { auth: { claim: { value: "r-dev" } } }' "$F"; then
    ok "A.13 fichier sans newline final : rec insérée sur SA ligne, newline final rétabli"
  else
    ko "A.13 sans newline final : rc=$RC"; cat -A "$F" | tail -3
  fi

  # ── A.14 auto-vérification fail-closed : mapping demandé illisible ⇒ rien n'est écrit ──
  F="$TMP/m7.yml"; write_idp "$F" "apps" '    dev: { auth: { claim: { value: "s-dev" } } }'
  cp "$F" "$TMP/m7.base"
  ERR=$(app_manifest_merge_env "$F" rec '[ pas, un, mapping ]' 2>&1); RC=$?
  [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'MANIFESTE_INVALIDE' && cmp -s "$TMP/m7.base" "$F" \
    && ok "A.14a contenu inline qui n'est pas un mapping : MANIFESTE_INVALIDE, fichier INTACT" \
    || ko "A.14a inline non-mapping : rc=$RC err=$ERR (fichier modifié : $(cmp -s "$TMP/m7.base" "$F" && echo non || echo OUI))"
  ERR=$(app_manifest_merge_env "$F" rec '{ auth: { claim: { value: "x" } ' 2>&1); RC=$?
  [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'MANIFESTE_INVALIDE' && cmp -s "$TMP/m7.base" "$F" \
    && ok "A.14b mapping inline mal fermé : MANIFESTE_INVALIDE, fichier INTACT" \
    || ko "A.14b inline cassé : rc=$RC err=$ERR"

  # ── A.15 palier écrit en style BLOCK (main humaine) : refus, fichier intact ──
  F="$TMP/m8.yml"; write_idp "$F" "appt" $'    dev:\n      auth:\n        claim:\n          value: "t-dev"'
  cp "$F" "$TMP/m8.base"
  ERR=$(app_manifest_merge_env "$F" dev '{ auth: { claim: { value: "t-dev2" } } }' 2>&1); RC=$?
  [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'MANIFESTE_INVALIDE' && cmp -s "$TMP/m8.base" "$F" \
    && ok "A.15 palier en style block (édité à la main) : MANIFESTE_INVALIDE plutôt qu'un YAML faux, fichier INTACT" \
    || ko "A.15 style block : rc=$RC err=$ERR (fichier modifié : $(cmp -s "$TMP/m8.base" "$F" && echo non || echo OUI))"

  # ── A.16 clé d'env hors classe sûre : refus (la lib ne fait pas confiance à l'appelant) ──
  F="$TMP/m9.yml"; write_idp "$F" "appu" '    dev: { auth: { claim: { value: "u-dev" } } }'
  cp "$F" "$TMP/m9.base"
  ERR=$(app_manifest_merge_env "$F" 'rec: x' '{ a: 1 }' 2>&1); RC=$?
  [ "$RC" -eq 2 ] && cmp -s "$TMP/m9.base" "$F" \
    && ok "A.16 env 'rec: x' (caractères hors [A-Za-z0-9._-], la classe de REQ_ENV) : refus, fichier INTACT" \
    || ko "A.16 env invalide : rc=$RC err=$ERR"

  # ── A.17 lecture après fusion : MAN_ENVS reflète les deux paliers ──
  OUT=$(app_manifest_read "$TMP/m1.yml" 2>/dev/null)
  printf '%s\n' "$OUT" | grep -qx 'MAN_ENVS=dev rec' \
    && ok "A.17 lecture après fusion : MAN_ENVS='dev rec'" || ko "A.17 MAN_ENVS après fusion : $(printf '%s' "$OUT" | grep MAN_ENVS)"

  # ── A.18 mode internal : vault_sub par palier (forme existante), fusion identique ──
  F="$TMP/m10.yml"
  cat > "$F" <<'YAML'
---
# appv.ansible.yml — GÉNÉRÉ par une demande de provisioning (maillon 1).
apim_ss_app:
  name: "appv"
  api: "accounts-read"
  api_version: "1.0.0"
  description: "Provisioned via cli2-provisioner (internal)"
  contact_emails: []
  enforce: []
  auth:
    mode: "internal"
    audience: "accounts-read"
  per_env:
    dev: { auth: { vault_sub: "deploy/banking-demo/apps/appv/dev/oauth-client" } }
YAML
  cp "$F" "$TMP/m10.base"
  app_manifest_merge_env "$F" rec '{ auth: { vault_sub: "deploy/banking-demo/apps/appv/rec/oauth-client" } }' 2>/dev/null; RC=$?
  OUT=$(app_manifest_read "$F" 2>/dev/null)
  if [ "$RC" -eq 0 ] && [ "$(diff "$TMP/m10.base" "$F" | grep -c '^>')" = 1 ] \
     && printf '%s\n' "$OUT" | grep -qx 'MAN_MODE=internal' && printf '%s\n' "$OUT" | grep -qx 'MAN_ENVS=dev rec'; then
    ok "A.18 mode internal : rec insérée (vault_sub …/rec/…), dev intact, lecture mode=internal envs='dev rec'"
  else
    ko "A.18 mode internal : rc=$RC"; diff "$TMP/m10.base" "$F"
  fi

  # ── A.19 BORNES sur les valeurs lues (héritées ensuite SANS la garde d'entrée du script) ──
  # (critique, reproduit : `team: ".*"` héritée puis interpolée en regex dans la
  # garde providers ⇒ TEAM_NOT_DECLARED contournée)
  F="$TMP/b1.yml"; write_idp "$F" "appw" '    dev: { auth: { claim: { value: "w-dev" } } }'
  python3 - "$F" <<'PY'
import sys; p=sys.argv[1]; t=open(p).read().replace('  enforce: []\n','  team: ".*"\n  enforce: []\n'); open(p,'w').write(t)
PY
  ERR=$(app_manifest_read "$F" 2>&1 >/dev/null); RC=$?
  [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'MANIFESTE_INVALIDE' && printf '%s' "$ERR" | grep -q "team=" \
    && ok "A.19a team: \".*\" (hors ^[a-z0-9][a-z0-9-]{1,30}\$) : MANIFESTE_INVALIDE — jamais héritée, jamais interpolée" \
    || ko "A.19a team hors format : rc=$RC err=$ERR"
  F="$TMP/b2.yml"; write_idp "$F" "appx" '    dev: { auth: { claim: { value: "x-dev" } } }'
  sed -i.bak 's/^  api_version: "1.0.0"$/  api_version: "1.0;x"/' "$F"; rm -f "$F.bak"
  ERR=$(app_manifest_read "$F" 2>&1 >/dev/null); RC=$?
  [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'MANIFESTE_INVALIDE' \
    && ok "A.19b api_version hors classe [A-Za-z0-9._-] : MANIFESTE_INVALIDE" || ko "A.19b api_version hors classe : rc=$RC err=$ERR"
  F="$TMP/b3.yml"; write_idp "$F" "appy" '    dev: { auth: { claim: { value: "y-dev" } } }'
  sed -i.bak 's/^    mode: "idp"$/    mode: "autre"/' "$F"; rm -f "$F.bak"
  ERR=$(app_manifest_read "$F" 2>&1 >/dev/null); RC=$?
  [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'MANIFESTE_INVALIDE' \
    && ok "A.19c mode hors idp|internal : MANIFESTE_INVALIDE" || ko "A.19c mode invalide : rc=$RC err=$ERR"

  # ── A.20 l'identité du palier est OBLIGATOIRE dans sa clé ──
  # (critique : sans claim.value, le rôle pose une stratégie clientId=<nom d'app>
  # AVANT son propre fail-closed — consumer-auth.yml:352 puis :461)
  F="$TMP/b4.yml"; write_idp "$F" "appz" $'    dev: { auth: { claim: { value: "z-dev" } } }\n    rec: { ip_allowlist: ["10.0.0.1"] }'
  ERR=$(app_manifest_read "$F" 2>&1 >/dev/null); RC=$?
  [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'per_env.rec.auth.claim.value' \
    && ok "A.20a idp : per_env.rec sans auth.claim.value ⇒ MANIFESTE_INVALIDE nommant la clé" \
    || ko "A.20a per_env sans claim.value : rc=$RC err=$ERR"
  cp "$TMP/m10.base" "$TMP/b5.yml"
  python3 - "$TMP/b5.yml" <<'PY'
import sys; p=sys.argv[1]; t=open(p).read().replace('    dev: { auth: { vault_sub: "deploy/banking-demo/apps/appv/dev/oauth-client" } }','    dev: { ip_allowlist: ["10.0.0.1"] }'); open(p,'w').write(t)
PY
  ERR=$(app_manifest_read "$TMP/b5.yml" 2>&1 >/dev/null); RC=$?
  [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'per_env.dev.auth.vault_sub' \
    && ok "A.20b internal : per_env.dev sans auth.vault_sub ⇒ MANIFESTE_INVALIDE nommant la clé" \
    || ko "A.20b internal sans vault_sub : rc=$RC err=$ERR"

  # ── A.21 formes de la tête per_env : `{}` en flow, commentaire, flow non vide ──
  F="$TMP/b6.yml"; write_idp "$F" "appaa" ''
  python3 - "$F" <<'PY'
import sys; p=sys.argv[1]; t=open(p).read().replace('  per_env:\n\n','  per_env: {}\n'); open(p,'w').write(t)
PY
  grep -qx '  per_env: {}' "$F" || ko "A.21 (prérequis) per_env: {} non posé"
  app_manifest_merge_env "$F" dev '{ auth: { claim: { value: "aa-dev" } } }' 2>"$TMP/err"; RC=$?
  if [ "$RC" -eq 0 ] && [ "$(grep -c '^  per_env' "$F")" = 1 ] && grep -qx '  per_env:' "$F" \
     && grep -qxF '    dev: { auth: { claim: { value: "aa-dev" } } }' "$F"; then
    ok "A.21a \`per_env: {}\` (flow vide) : converti en bloc, UNE seule clé per_env, ligne dev posée"
  else
    ko "A.21a per_env: {} : rc=$RC err=$(cat "$TMP/err")"; grep -n per_env "$F"
  fi
  F="$TMP/b7.yml"; write_idp "$F" "appab" '    dev: { auth: { claim: { value: "ab-dev" } } }'
  sed -i.bak 's/^  per_env:$/  per_env:   # un palier par ligne/' "$F"; rm -f "$F.bak"
  app_manifest_merge_env "$F" rec '{ auth: { claim: { value: "ab-rec" } } }' 2>"$TMP/err"; RC=$?
  [ "$RC" -eq 0 ] && grep -qxF '    rec: { auth: { claim: { value: "ab-rec" } } }' "$F" && grep -q '^  per_env:   # un palier par ligne$' "$F" \
    && ok "A.21b tête \`  per_env:   # commentaire\` reconnue, commentaire conservé, rec insérée" \
    || ko "A.21b tête commentée : rc=$RC err=$(cat "$TMP/err")"
  F="$TMP/b8.yml"; write_idp "$F" "appac" ''
  python3 - "$F" <<'PY'
import sys; p=sys.argv[1]; t=open(p).read().replace('  per_env:\n\n','  per_env: { dev: { auth: { claim: { value: "ac-dev" } } } }\n'); open(p,'w').write(t)
PY
  cp "$F" "$TMP/b8.base"
  ERR=$(app_manifest_merge_env "$F" rec '{ auth: { claim: { value: "ac-rec" } } }' 2>&1); RC=$?
  [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'MANIFESTE_INVALIDE' && printf '%s' "$ERR" | grep -q 'flow non vide' && cmp -s "$TMP/b8.base" "$F" \
    && ok "A.21c \`per_env: { dev: … }\` (flow non vide, une ligne) : refus NOMMÉ, jamais une clé dupliquée, fichier intact" \
    || ko "A.21c per_env flow non vide : rc=$RC err=$ERR"

  # ── A.22 bloc absent + clé racine APRÈS apim_ss_app : créé en fin du mapping, pas en fin de fichier ──
  F="$TMP/b9.yml"; write_idp "$F" "appad" ''
  python3 - "$F" <<'PY'
import sys; p=sys.argv[1]; t=open(p).read().replace('  per_env:\n\n','autre_racine:\n  x: 1\n'); open(p,'w').write(t)
PY
  app_manifest_merge_env "$F" dev '{ auth: { claim: { value: "ad-dev" } } }' 2>"$TMP/err"; RC=$?
  if [ "$RC" -eq 0 ] && python3 -c "
import sys, yaml
d = yaml.load(open('$F'), Loader=yaml.BaseLoader)
assert d['apim_ss_app']['per_env'] == {'dev': {'auth': {'claim': {'value': 'ad-dev'}}}}, d['apim_ss_app'].get('per_env')
assert d['autre_racine'] == {'x': '1'}, d.get('autre_racine')
" 2>/dev/null && sed -n '/^  per_env:/,+1p' "$F" | sed -n 2p | grep -q '^    dev: ' && grep -n '^autre_racine:' "$F" | grep -q "^$(( $(grep -n '^    dev: ' "$F" | cut -d: -f1) + 1 )):"; then
    ok "A.22 bloc absent avec une clé racine après apim_ss_app : per_env inséré EN FIN DU MAPPING apim_ss_app (avant autre_racine)"
  else
    ko "A.22 insertion en fin de mapping : rc=$RC err=$(cat "$TMP/err")"; cat "$F"
  fi

  # ── A.23 une ligne de palier ne surcharge JAMAIS un champ trans-palier ──
  # (revue, prouvé : le rôle fusionne per_env[env] récursivement — une ligne
  # `rec: { api: "autre", team: "x" }` changeait api/team effectifs sur rec
  # alors que le contrat, lu à la racine, disait « identique »)
  F="$TMP/c1.yml"; write_idp "$F" "appae" '    dev: { auth: { claim: { value: "ae-dev" } } }'
  cp "$F" "$TMP/c1.base"
  ERR=$(app_manifest_merge_env "$F" rec '{ auth: { claim: { value: "ae-rec" } }, api: "payments-initiation", team: "autre-team" }' 2>&1); RC=$?
  [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'trans-palier' && printf '%s' "$ERR" | grep -q 'api, team' && cmp -s "$TMP/c1.base" "$F" \
    && ok "A.23a fusion : mapping portant api/team ⇒ MANIFESTE_INVALIDE nommant les champs, fichier INTACT" \
    || ko "A.23a surcharge par la fusion : rc=$RC err=$ERR"
  ERR=$(app_manifest_merge_env "$F" rec '{ auth: { claim: { value: "ae-rec" }, audience: "autre" } }' 2>&1); RC=$?
  [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'auth.audience' \
    && ok "A.23b fusion : auth.audience dans la ligne de palier ⇒ MANIFESTE_INVALIDE" || ko "A.23b auth.audience par palier : rc=$RC err=$ERR"
  F="$TMP/c2.yml"; write_idp "$F" "appaf" $'    dev: { auth: { claim: { value: "af-dev" } } }\n    rec: { auth: { claim: { value: "af-rec" } }, api_version: "9.9.9" }'
  ERR=$(app_manifest_read "$F" 2>&1 >/dev/null); RC=$?
  [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'per_env.rec surcharge' \
    && ok "A.23c lecture : per_env.rec portant api_version (édité à la main) ⇒ MANIFESTE_INVALIDE — le contrat ne peut pas être contourné par un palier" \
    || ko "A.23c lecture d'une surcharge par palier : rc=$RC err=$ERR"

  # ── A.24 clés de palier CITÉES ou DUPLIQUÉES : jamais un doublon avalé ──
  F="$TMP/c3.yml"; write_idp "$F" "appag" '    "dev": { auth: { claim: { value: "ag-dev" } } }'
  app_manifest_merge_env "$F" dev '{ auth: { claim: { value: "ag-dev2" } } }' 2>"$TMP/err"; RC=$?
  [ "$RC" -eq 0 ] && [ "$(grep -c '^    .*dev.*:' "$F")" = 1 ] && grep -qxF '    dev: { auth: { claim: { value: "ag-dev2" } } }' "$F" \
    && ok "A.24a clé citée \`\"dev\":\` reconnue : REMPLACÉE (une seule ligne dev), pas doublée" \
    || ko "A.24a clé citée : rc=$RC err=$(cat "$TMP/err")"; grep -n 'dev' "$F" | tail -2 >/dev/null
  F="$TMP/c4.yml"; write_idp "$F" "appah" $'    dev: { auth: { claim: { value: "ah-1" } } }\n    dev: { auth: { claim: { value: "ah-2" } } }'
  cp "$F" "$TMP/c4.base"
  ERR=$(app_manifest_merge_env "$F" rec '{ auth: { claim: { value: "ah-rec" } } }' 2>&1); RC=$?
  [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'dupliquée' && cmp -s "$TMP/c4.base" "$F" \
    && ok "A.24b bloc portant DEUX lignes dev (édité à la main) : refus nommé même pour insérer rec, fichier INTACT" \
    || ko "A.24b clé dupliquée : rc=$RC err=$ERR"
fi

echo "═══ Section B — compilation et gardes hors ligne du script ═══"
bash -n "$S" && ok "B.1 provision-request.sh compile (bash -n)" || ko "B.1 provision-request.sh ne compile pas"
[ -r "$LIB" ] && { bash -n "$LIB" && ok "B.2 lib app-manifest.sh compile (bash -n)" || ko "B.2 lib ne compile pas"; }
if command -v shellcheck >/dev/null 2>&1 && [ -r "$LIB" ]; then
  shellcheck -x "$LIB" >/dev/null 2>&1 && ok "B.3 shellcheck de la lib : propre" || { ko "B.3 shellcheck de la lib"; shellcheck -x "$LIB" | head -20; }
fi
grep -q 'app-manifest.sh' "$S" && ok "B.4 le script source la lib app-manifest.sh" || ko "B.4 le script ne source pas la lib"
# La garde CONTRAT_DIVERGENT exige le manifeste sur GIT_BASE, donc le clone :
# hors ligne on ne peut prouver que « rien n'a changé AVANT le clone » — les
# refus d'entrée existants sortent toujours avant [1/4] (patron v2/v3).
OUT=$(env -i PATH="$PATH" GITEA_TOKEN=dummy GIT_HOST="http://127.0.0.1:1" REQ_APP=probe REQ_ENV=dev \
      REQ_API=accounts-read REQ_CLIENT_ID=probe REQ_CALLER=oig-provisioner REQ_AUDIENCE='bad"aud' bash "$S" 2>&1); RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'AUDIENCE_INVALID' && ! printf '%s' "$OUT" | grep -q '\[1/4\]' \
  && ok "B.5 REQ_AUDIENCE avec guillemet : AUDIENCE_INVALID, AVANT tout appel réseau (le champ est figé et interpolé en YAML)" \
  || ko "B.5 audience invalide : rc=$RC out=$(printf '%s' "$OUT" | tail -1)"
OUT=$(env -i PATH="$PATH" GITEA_TOKEN=dummy GIT_HOST="http://127.0.0.1:1" REQ_APP=probe REQ_ENV=dev \
      REQ_API=accounts-read REQ_CLIENT_ID=probe REQ_CALLER=oig-provisioner REQ_API_VER='1.0;x' bash "$S" 2>&1); RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'API_VERSION_INVALID' && ! printf '%s' "$OUT" | grep -q '\[1/4\]' \
  && ok "B.6 REQ_API_VER hors classe : API_VERSION_INVALID, AVANT tout appel réseau" \
  || ko "B.6 version invalide : rc=$RC out=$(printf '%s' "$OUT" | tail -1)"

OUT=$(env -i PATH="$PATH" GITEA_TOKEN=dummy GIT_HOST="http://127.0.0.1:1" REQ_APP=probe REQ_ENV=dev \
      REQ_API=accounts-read REQ_CLIENT_ID=probe REQ_CALLER=$'oig"\n  api: evil' bash "$S" 2>&1); RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'CALLER_INVALID' && ! printf '%s' "$OUT" | grep -q '\[1/4\]' \
  && ok "B.7 REQ_CALLER avec guillemet + retour-ligne (injection de clé racine via l'en-tête/description) : CALLER_INVALID, AVANT tout appel réseau" \
  || ko "B.7 caller invalide : rc=$RC out=$(printf '%s' "$OUT" | tail -1)"
OUT=$(env -i PATH="$PATH" GITEA_TOKEN=dummy GIT_HOST="http://127.0.0.1:1" REQ_APP=probe REQ_ENV=dev \
      REQ_API=accounts-read REQ_CLIENT_ID=probe REQ_CALLER='jenkins-form:oscar@bank.example' bash "$S" 2>&1); RC=$?
printf '%s' "$OUT" | grep -q 'CALLER_INVALID' && ko "B.7b REQ_CALLER=jenkins-form:oscar@bank.example (voie humaine) refusé à tort" \
  || ok "B.7b REQ_CALLER=jenkins-form:oscar@bank.example accepté (':' et '@' admis — la voie humaine reste servie)"

echo "═══ Section C — contre le Gitea RÉEL du lab (poc-gitea:13000), base JETABLE ═══"
# A1_OFFLINE=1 : ne jamais toucher au lab (lint-ci, poste sans docker, TDD sur
# la lib) — sinon le token est minté via docker et la section tourne.
if [ "${A1_OFFLINE:-0}" = 1 ]; then
  echo "  (section C sautée — A1_OFFLINE=1)"
elif [ -n "${GITEA_TOKEN_FILE:-}" ] && [ -r "$GITEA_TOKEN_FILE" ]; then
  GITEA_TOKEN="$(cat "$GITEA_TOKEN_FILE")"
elif docker inspect poc-gitea >/dev/null 2>&1; then
  GITEA_TOKEN=$(docker exec -u git poc-gitea gitea admin user generate-access-token \
    --username ci --token-name "p3a1-test-$TS" \
    --scopes write:repository,write:issue 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
fi
if [ -z "$GITEA_TOKEN" ] || ! curl -s -o /dev/null "$GH" 2>/dev/null; then
  echo "  (section C sautée — Gitea du lab (poc-gitea:13000) ou token indisponible)"
else
  API="$GH/api/v1/repos/ci/stoa-labs"
  auth=(-H "Authorization: token $GITEA_TOKEN")
  MAN_DIR="poc-control-plane-federation/clients/provisioned/applications"
  CERT_DIR="poc-control-plane-federation/clients/provisioned/certs"
  raw(){ curl -s "${auth[@]}" "$API/raw/${1}/${2}"; }                       # $1=ref $2=path
  raw_manifest(){ raw "$1" "$MAN_DIR/${2}.ansible.yml"; }
  branch_sha(){ curl -s "${auth[@]}" "$API/branches/${1}" | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["commit"]["id"])
except Exception: print("")'; }
  branch_exists(){ [ "$(curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" "$API/branches/${1}")" = 200 ]; }
  # « merge simulé » : pose le contenu d'un fichier d'une branche sur la base
  # via l'API contents (pas de merge de PR : l'événement closed|merged
  # déclencherait provision-apply sur le Jenkins du lab, en attente d'input).
  put_file(){ # $1=branche cible $2=path $3=fichier local contenu $4=message
    # token par l'ENVIRONNEMENT, jamais en argv (lisible par `ps` sinon) —
    # même règle que provision-request.sh.
    GITEA_TOKEN="$GITEA_TOKEN" python3 - "$API" "$1" "$2" "$3" "$4" <<'PY'
import sys, os, json, base64, urllib.request, urllib.error
api, branch, path, local, msg = sys.argv[1:6]
tok = os.environ["GITEA_TOKEN"]
content = base64.b64encode(open(local, "rb").read()).decode()
hdr = {"Authorization": "token " + tok, "Content-Type": "application/json"}
def req(method, url, data=None):
    r = urllib.request.Request(url, data=(json.dumps(data).encode() if data is not None else None), method=method, headers=hdr)
    with urllib.request.urlopen(r) as resp: return json.loads(resp.read() or "null")
sha = None
try:
    sha = req("GET", f"{api}/contents/{path}?ref={branch}").get("sha")
except urllib.error.HTTPError as e:
    if e.code != 404: raise
body = {"branch": branch, "content": content, "message": msg}
if sha: body["sha"] = sha
req("PUT" if sha else "POST", f"{api}/contents/{path}", body)
print("OK")
PY
  }
  # Le corps de PR se lit PAR NUMÉRO (imprimé par le script : PR_URL=…/pulls/N)
  # — la liste `pulls?state=all&limit=50` n'est pas ordonnée de façon fiable
  # sur un dépôt qui porte des centaines de PR jetables (mesuré : C.1b flaky).
  pr_num(){ printf '%s' "$1" | grep -oE 'PR_URL=[^ ]*/pulls/[0-9]+' | grep -oE '[0-9]+$' | tail -1; }
  pr_body(){ curl -s "${auth[@]}" "$API/pulls/$(pr_num "$1")" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("body",""))
except Exception: print("")' 2>/dev/null; }

  BASE="p3a1-base-$TS"; CLEAN_BRANCHES+=("$BASE")
  RC=$(curl -s -o "$TMP/mkbase" -w '%{http_code}' -X POST "${auth[@]}" -H 'Content-Type: application/json' \
       -d "{\"new_branch_name\":\"$BASE\",\"old_branch_name\":\"main\"}" "$API/branches")
  if [ "$RC" != 201 ]; then
    ko "C.0 création de la base jetable $BASE depuis main : HTTP $RC $(head -c 200 "$TMP/mkbase")"
  else
    ok "C.0 base jetable $BASE créée depuis main (aucune écriture sur main pendant cette suite)"
    COMMON=(GITEA_TOKEN="$GITEA_TOKEN" GIT_HOST="$GH" GIT_BASE="$BASE" PROVISION_PLAN_INLINE=false)
    # A7 : une chaîne SANS porte pour les demandes int de C.5 — sous le gabarit réel,
    # int exige les quatre yeux et la demande sous ci refuse REQUESTER_UNKNOWN avant
    # le clone ; C.5 mesure le CONTRAT (après le clone), pas la porte.
    printf 'environments: [dev, rec, int, homol, prod]\ngates: []\n' > "$TMP/chain-libre.yaml"
    LIBRE=("STOA_ENV_CHAIN_FILE=$TMP/chain-libre.yaml")

    # ── C.1 demande dev (idp) ──
    APP="p3a1idp$TS"; BD="provision/${APP}-dev"; BR="provision/${APP}-rec"; CLEAN_BRANCHES+=("$BD" "$BR")
    OUT=$(env "${COMMON[@]}" REQ_APP="$APP" REQ_ENV=dev REQ_API=accounts-read REQ_API_VER=2.0.0 \
          REQ_CALLER=oig-provisioner REQ_CLIENT_ID="${APP}-dev" REQ_IP_ALLOWLIST="10.0.0.1" bash "$S" 2>&1); RC=$?
    MD=$(raw_manifest "$BD" "$APP")
    if [ "$RC" -eq 0 ] && printf '%s' "$MD" | grep -qxF '    claim: { name: "azp" }' \
       && printf '%s' "$MD" | grep -qxF "    dev: { auth: { claim: { value: \"${APP}-dev\" } }, ip_allowlist: [\"10.0.0.1\"] }" \
       && ! printf '%s' "$MD" | grep -q 'demande dev'; then
      ok "C.1 demande dev (idp) : manifeste créé forme A1 — claim { name } à la racine, valeur sous per_env.dev, description sans palier"
    else
      ko "C.1 demande dev : rc=$RC — $(printf '%s' "$OUT" | tail -3)"; printf '%s\n' "$MD"
    fi
    printf '%s' "$(pr_body "$OUT")" | grep -q 'manifeste : première demande' \
      && ok "C.1b corps de PR #$(pr_num "$OUT") : « première demande (créé) »" || ko "C.1b corps de PR sans la ligne manifeste : $(pr_body "$OUT" | grep -i manifeste)"

    # ── C.2 merge simulé : le manifeste dev est posé sur la base ──
    printf '%s\n' "$MD" > "$TMP/dev.yml"
    put_file "$BASE" "$MAN_DIR/${APP}.ansible.yml" "$TMP/dev.yml" "merge simulé : provision(dev) $APP" >/dev/null \
      && ok "C.2 merge simulé : manifeste dev posé sur $BASE" || ko "C.2 merge simulé impossible"

    # ── C.3 demande rec ⇒ deux clés per_env, client_id distincts, diff = UNE ligne ──
    OUT=$(env "${COMMON[@]}" REQ_APP="$APP" REQ_ENV=rec REQ_API=accounts-read \
          REQ_CALLER=oig-provisioner REQ_CLIENT_ID="${APP}-rec" bash "$S" 2>&1); RC=$?
    MR=$(raw_manifest "$BR" "$APP")
    printf '%s\n' "$MR" > "$TMP/rec.yml"
    ADDED=$(diff "$TMP/dev.yml" "$TMP/rec.yml" | grep -c '^>'); REMOVED=$(diff "$TMP/dev.yml" "$TMP/rec.yml" | grep -c '^<')
    if [ "$RC" -eq 0 ] && [ "$ADDED" = 1 ] && [ "$REMOVED" = 0 ] \
       && dif "$TMP/dev.yml" "$TMP/rec.yml" | grep -qxF ">     rec: { auth: { claim: { value: \"${APP}-rec\" } } }"; then
      ok "C.3 PORTE A1 : demande rec ⇒ per_env.dev ET per_env.rec, client_id distincts (${APP}-dev / ${APP}-rec)"
      ok "C.3b CONTRE-ÉPREUVE 1 : diff base→rec = exactement UNE ligne ajoutée — aucun octet hors per_env.rec"
    else
      ko "C.3 demande rec : rc=$RC added=$ADDED removed=$REMOVED — $(printf '%s' "$OUT" | tail -3)"; diff "$TMP/dev.yml" "$TMP/rec.yml"
    fi
    grep -qx 'api_version: "2.0.0"' <(printf '%s\n' "$MR" | sed 's/^  //') \
      && ok "C.3c REQ_API_VER absente sur rec ⇒ héritée du manifeste (2.0.0), pas de divergence mensongère" \
      || ko "C.3c api_version après rec : $(printf '%s' "$MR" | grep api_version)"
    PRB=$(pr_body "$OUT")
    printf '%s' "$PRB" | grep -q 'per_env.rec fusionné' && printf '%s' "$PRB" | grep -q 'paliers déjà déclarés : dev' \
      && ok "C.3d corps de PR rec #$(pr_num "$OUT") : « per_env.rec fusionné — paliers déjà déclarés : dev »" \
      || ko "C.3d corps de PR rec : $(printf '%s' "$PRB" | grep -i manifeste)"

    # ── C.4 idempotence : rec rejouée ⇒ même SHA de branche ──
    SHA1=$(branch_sha "$BR")
    OUT=$(env "${COMMON[@]}" REQ_APP="$APP" REQ_ENV=rec REQ_API=accounts-read \
          REQ_CALLER=oig-provisioner REQ_CLIENT_ID="${APP}-rec" bash "$S" 2>&1); RC=$?
    SHA2=$(branch_sha "$BR")
    [ "$RC" -eq 0 ] && [ -n "$SHA1" ] && [ "$SHA1" = "$SHA2" ] && printf '%s' "$OUT" | grep -q 'aucun changement' \
      && ok "C.4 demande rec rejouée : « aucun changement », même SHA ($SHA1)" \
      || ko "C.4 idempotence rec : rc=$RC sha1=$SHA1 sha2=$SHA2"

    # ── C.4b rejeu APRÈS merge : la base porte déjà per_env.rec ⇒ rien à ouvrir, exit 0 ──
    # (critique : un POST /pulls sur une tête supprimée après merge rendait 404 ⇒ rc 1)
    APP2="p3a1mrg$TS"; B2D="provision/${APP2}-dev"; B2R="provision/${APP2}-rec"; CLEAN_BRANCHES+=("$B2D" "$B2R")
    OUT=$(env "${COMMON[@]}" REQ_APP="$APP2" REQ_ENV=dev REQ_API=accounts-read REQ_CALLER=oig-provisioner REQ_CLIENT_ID="${APP2}-dev" bash "$S" 2>&1)
    raw_manifest "$B2D" "$APP2" > "$TMP/m2dev.yml"
    put_file "$BASE" "$MAN_DIR/${APP2}.ansible.yml" "$TMP/m2dev.yml" "merge simulé : provision(dev) $APP2" >/dev/null
    OUT=$(env "${COMMON[@]}" REQ_APP="$APP2" REQ_ENV=rec REQ_API=accounts-read REQ_CALLER=oig-provisioner REQ_CLIENT_ID="${APP2}-rec" bash "$S" 2>&1)
    raw_manifest "$B2R" "$APP2" > "$TMP/m2rec.yml"
    put_file "$BASE" "$MAN_DIR/${APP2}.ansible.yml" "$TMP/m2rec.yml" "merge simulé : provision(rec) $APP2" >/dev/null
    curl -s -o /dev/null -X DELETE "${auth[@]}" "$API/branches/${B2R}"   # « supprimer la branche après merge »
    OUT=$(env "${COMMON[@]}" REQ_APP="$APP2" REQ_ENV=rec REQ_API=accounts-read REQ_CALLER=oig-provisioner REQ_CLIENT_ID="${APP2}-rec" bash "$S" 2>&1); RC=$?
    [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "déjà mergée sur $BASE" && ! printf '%s' "$OUT" | grep -q '\[4/4\]' && ! branch_exists "$B2R" \
      && ok "C.4b rejeu APRÈS merge (base porte per_env.rec, tête supprimée) : exit 0 « déjà mergée », aucune PR ouverte, aucune branche recréée" \
      || ko "C.4b rejeu après merge : rc=$RC branche=$(branch_exists "$B2R" && echo EXISTE || echo absente) — $(printf '%s' "$OUT" | tail -3)"

    # ── C.5 CONTRE-ÉPREUVE 2 : autre api ⇒ CONTRAT_DIVERGENT, aucune branche ──
    BI="provision/${APP}-int"; CLEAN_BRANCHES+=("$BI")
    OUT=$(env "${COMMON[@]}" "${LIBRE[@]}" REQ_APP="$APP" REQ_ENV=int REQ_API=payments-initiation \
          REQ_CALLER=oig-provisioner REQ_CLIENT_ID="${APP}-int" bash "$S" 2>&1); RC=$?
    if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'CONTRAT_DIVERGENT' \
       && printf '%s' "$OUT" | grep -q "api : manifeste='accounts-read' demande='payments-initiation'" \
       && ! branch_exists "$BI"; then
      ok "C.5 CONTRE-ÉPREUVE 2 : demande int avec une autre api ⇒ CONTRAT_DIVERGENT (rc 2), branche $BI JAMAIS créée"
    else
      ko "C.5 api divergente : rc=$RC branche=$(branch_exists "$BI" && echo EXISTE || echo absente) — $(printf '%s' "$OUT" | tail -2)"
    fi
    OUT=$(env "${COMMON[@]}" "${LIBRE[@]}" REQ_APP="$APP" REQ_ENV=int REQ_API=accounts-read REQ_API_VER=1.0.0 \
          REQ_CALLER=oig-provisioner REQ_CLIENT_ID="${APP}-int" bash "$S" 2>&1); RC=$?
    [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "api_version : manifeste='2.0.0' demande='1.0.0'" && ! branch_exists "$BI" \
      && ok "C.5b version FOURNIE différente (1.0.0 vs 2.0.0) : CONTRAT_DIVERGENT, aucune branche" \
      || ko "C.5b version divergente : rc=$RC — $(printf '%s' "$OUT" | tail -2)"
    OUT=$(env "${COMMON[@]}" "${LIBRE[@]}" REQ_APP="$APP" REQ_ENV=int REQ_API=accounts-read \
          REQ_CALLER=cli2-provisioner bash "$S" 2>&1); RC=$?
    [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "mode : manifeste='idp' demande='internal'" && ! branch_exists "$BI" \
      && ok "C.5c appelant cli2 (mode internal) sur une app idp : CONTRAT_DIVERGENT sur le mode (anti-spoof conservé)" \
      || ko "C.5c mode divergent : rc=$RC — $(printf '%s' "$OUT" | tail -2)"

    # ── C.6 mode internal : vault_sub distincts par palier ──
    APPI="p3a1int$TS"; BID="provision/${APPI}-dev"; BIR="provision/${APPI}-rec"; CLEAN_BRANCHES+=("$BID" "$BIR")
    OUT=$(env "${COMMON[@]}" REQ_APP="$APPI" REQ_ENV=dev REQ_API=accounts-read REQ_CALLER=cli2-provisioner bash "$S" 2>&1); RC=$?
    MID=$(raw_manifest "$BID" "$APPI"); printf '%s\n' "$MID" > "$TMP/idev.yml"
    put_file "$BASE" "$MAN_DIR/${APPI}.ansible.yml" "$TMP/idev.yml" "merge simulé : provision(dev) $APPI" >/dev/null
    OUT2=$(env "${COMMON[@]}" REQ_APP="$APPI" REQ_ENV=rec REQ_API=accounts-read REQ_CALLER=cli2-provisioner bash "$S" 2>&1); RC2=$?
    MIR=$(raw_manifest "$BIR" "$APPI")
    if [ "$RC" -eq 0 ] && [ "$RC2" -eq 0 ] \
       && printf '%s' "$MIR" | grep -qxF "    dev: { auth: { vault_sub: \"deploy/banking-demo/apps/${APPI}/dev/oauth-client\" } }" \
       && printf '%s' "$MIR" | grep -qxF "    rec: { auth: { vault_sub: \"deploy/banking-demo/apps/${APPI}/rec/oauth-client\" } }"; then
      ok "C.6 mode internal : dev puis rec ⇒ vault_sub distincts (…/dev/… et …/rec/…)"
    else
      ko "C.6 mode internal : rc=$RC/$RC2 — $(printf '%s' "$OUT2" | tail -2)"; printf '%s\n' "$MIR"
    fi

    # ── C.7 certificat PAR PALIER : rec n'écrase pas le .crt de dev ──
    APPC="p3a1crt$TS"; BCD="provision/${APPC}-dev"; BCR="provision/${APPC}-rec"; CLEAN_BRANCHES+=("$BCD" "$BCR")
    PEM_A="$(cat "$REPO/clients/_example/applications/demo-client.crt")"
    PEM_B="$(printf -- '-----BEGIN CERTIFICATE-----\nMIIBcertB%s\n-----END CERTIFICATE-----\n' "$TS")"
    OUT=$(env "${COMMON[@]}" REQ_APP="$APPC" REQ_ENV=dev REQ_API=accounts-read REQ_CALLER=oig-provisioner \
          REQ_CLIENT_ID="${APPC}-dev" REQ_CERT_PEM="$PEM_A" REQ_CERT_ROTATION=overlap bash "$S" 2>&1); RC=$?
    MCD=$(raw_manifest "$BCD" "$APPC"); printf '%s\n' "$MCD" > "$TMP/cdev.yml"
    raw "$BCD" "$CERT_DIR/${APPC}-dev.crt" > "$TMP/cdev.crt"
    put_file "$BASE" "$MAN_DIR/${APPC}.ansible.yml" "$TMP/cdev.yml" "merge simulé : provision(dev) $APPC" >/dev/null
    put_file "$BASE" "$CERT_DIR/${APPC}-dev.crt" "$TMP/cdev.crt" "merge simulé : cert dev $APPC" >/dev/null
    OUT2=$(env "${COMMON[@]}" REQ_APP="$APPC" REQ_ENV=rec REQ_API=accounts-read REQ_CALLER=oig-provisioner \
          REQ_CLIENT_ID="${APPC}-rec" REQ_CERT_PEM="$PEM_B" bash "$S" 2>&1); RC2=$?
    MCR=$(raw_manifest "$BCR" "$APPC")
    if [ "$RC" -eq 0 ] && [ "$RC2" -eq 0 ] \
       && printf '%s' "$MCD" | grep -q "    dev: { auth: { claim: { value: \"${APPC}-dev\" } }, public_cert_ref: \"clients/provisioned/certs/${APPC}-dev.crt\", cert_rotation: \"overlap\" }" \
       && printf '%s' "$MCR" | grep -q "    rec: { auth: { claim: { value: \"${APPC}-rec\" } }, public_cert_ref: \"clients/provisioned/certs/${APPC}-rec.crt\", cert_rotation: \"replace\" }" \
       && [ "$(raw "$BCR" "$CERT_DIR/${APPC}-dev.crt")" = "$(cat "$TMP/cdev.crt")" ] \
       && [ "$(raw "$BCR" "$CERT_DIR/${APPC}-rec.crt")" = "$(printf '%s' "$PEM_B")" ] \
       && ! printf '%s' "$MCR" | grep -q '^  cert_rotation:'; then
      ok "C.7 certificat par palier : ${APPC}-dev.crt intact sur la branche rec, ${APPC}-rec.crt ajouté, cert_rotation sous per_env (overlap/replace)"
    else
      ko "C.7 certificat par palier : rc=$RC/$RC2 — $(printf '%s' "$OUT2" | tail -2)"; printf '%s\n' "$MCR" | tail -4
    fi

    # ── C.8 forme ancienne sur la base ⇒ MANIFESTE_LEGACY, aucune branche ──
    APPL="p3a1old$TS"; BLR="provision/${APPL}-rec"; CLEAN_BRANCHES+=("$BLR")
    cat > "$TMP/old.yml" <<YAML
---
apim_ss_app:
  name: "$APPL"
  api: "accounts-read"
  api_version: "1.0.0"
  description: "Provisioned via oig-provisioner — demande dev (idp)"
  contact_emails: []
  enforce: []
  auth:
    mode: "idp"
    server_alias: "KeycloakStoaLab"
    audience: "accounts-read"
    claim: { name: "azp", value: "${APPL}-dev" }
YAML
    put_file "$BASE" "$MAN_DIR/${APPL}.ansible.yml" "$TMP/old.yml" "forme ancienne (avant A1) $APPL" >/dev/null
    OUT=$(env "${COMMON[@]}" REQ_APP="$APPL" REQ_ENV=rec REQ_API=accounts-read REQ_CALLER=oig-provisioner \
          REQ_CLIENT_ID="${APPL}-rec" bash "$S" 2>&1); RC=$?
    [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'MANIFESTE_LEGACY' && ! branch_exists "$BLR" \
      && ok "C.8 manifeste d'avant A1 (claim.value racine) : MANIFESTE_LEGACY (rc 2), aucune branche — pas de migration devinée" \
      || ko "C.8 forme ancienne : rc=$RC branche=$(branch_exists "$BLR" && echo EXISTE || echo absente) — $(printf '%s' "$OUT" | tail -2)"

    # ── C.8b audience ABSENTE du manifeste (posé à la main) ⇒ héritée telle quelle, jamais redérivée ──
    # (revue : `${MAN_AUDIENCE:-$REQ_API}` fabriquait `accounts-read` face à '' ⇒ divergence mensongère)
    APPA="p3a1aud$TS"; BAR="provision/${APPA}-rec"; CLEAN_BRANCHES+=("$BAR")
    sed -e "s/^  name: \".*\"$/  name: \"$APPA\"/" -e '/^    audience:/d' -e 's/^    claim: { name: "azp", value: ".*" }$/    claim: { name: "azp" }/' "$TMP/old.yml" > "$TMP/noaud.yml"
    printf '  per_env:\n    dev: { auth: { claim: { value: "%s-dev" } } }\n' "$APPA" >> "$TMP/noaud.yml"
    put_file "$BASE" "$MAN_DIR/${APPA}.ansible.yml" "$TMP/noaud.yml" "manifeste sans audience $APPA" >/dev/null
    OUT=$(env "${COMMON[@]}" REQ_APP="$APPA" REQ_ENV=rec REQ_API=accounts-read REQ_CALLER=oig-provisioner REQ_CLIENT_ID="${APPA}-rec" bash "$S" 2>&1); RC=$?
    [ "$RC" -eq 0 ] && raw_manifest "$BAR" "$APPA" | grep -q "    rec: " && ! raw_manifest "$BAR" "$APPA" | grep -q '^    audience:' \
      && ok "C.8b manifeste SANS audience + demande rec sans REQ_AUDIENCE ⇒ héritée vide, contrat accepté, ligne rec posée (aucune audience fabriquée)" \
      || ko "C.8b audience absente héritée : rc=$RC — $(printf '%s' "$OUT" | grep -E 'REFUS|ERREUR' | tail -1)"

    # ── C.9 team FIGÉE : héritée si absente (garde providers du palier VISÉ), divergente si autre ──
    # Le lab ne déclare des teams que dans providers.dev.yml (self-service
    # dev-only, GOAL du 2026-08-26). Pour prouver l'héritage SANS toucher au
    # dépôt, la base jetable reçoit un providers.rec.yml déclarant la team ;
    # providers.int.yml reste absent — c'est la contre-épreuve C.9c.
    APPT="p3a1team$TS"; BTD="provision/${APPT}-dev"; BTR="provision/${APPT}-rec"; BTI="provision/${APPT}-int"
    CLEAN_BRANCHES+=("$BTD" "$BTR" "$BTI")
    TEAM="payments-team"
    if ! grep -q "^  - team: ${TEAM}\$" "$REPO/ansible/providers.dev.yml"; then
      echo "  (C.9 sautée — ${TEAM} absente de providers.dev.yml)"
    else
      printf -- '---\n# fixture A1 (jetable) : la team existe aussi au palier rec\nproviders:\n  - team: %s\n    description: "fixture test-app-request-a1"\n    repo: ""\n    approvers: []\n' "$TEAM" > "$TMP/providers.rec.yml"
      put_file "$BASE" "poc-control-plane-federation/ansible/providers.rec.yml" "$TMP/providers.rec.yml" "fixture A1 : providers.rec.yml" >/dev/null \
        || ko "C.9 (prérequis) providers.rec.yml non posé sur la base"
      OUT=$(env "${COMMON[@]}" REQ_APP="$APPT" REQ_ENV=dev REQ_API=accounts-read REQ_CALLER=oig-provisioner \
            REQ_CLIENT_ID="${APPT}-dev" REQ_TEAM="$TEAM" bash "$S" 2>&1); RC=$?
      MTD=$(raw_manifest "$BTD" "$APPT"); printf '%s\n' "$MTD" > "$TMP/tdev.yml"
      put_file "$BASE" "$MAN_DIR/${APPT}.ansible.yml" "$TMP/tdev.yml" "merge simulé : provision(dev) $APPT" >/dev/null
      OUT2=$(env "${COMMON[@]}" REQ_APP="$APPT" REQ_ENV=rec REQ_API=accounts-read REQ_CALLER=oig-provisioner \
             REQ_CLIENT_ID="${APPT}-rec" bash "$S" 2>&1); RC2=$?
      MTR=$(raw_manifest "$BTR" "$APPT")
      if [ "$RC" -eq 0 ] && [ "$RC2" -eq 0 ] && printf '%s' "$MTR" | grep -qxF "  team: \"$TEAM\"" \
         && printf '%s' "$MTR" | grep -q "    rec: " && printf '%s' "$OUT2" | grep -q "team héritée du manifeste : $TEAM"; then
        ok "C.9a team absente de la demande rec ⇒ héritée ($TEAM), garde providers.rec.yml (base) passée, ligne rec posée"
      else
        ko "C.9a team héritée : rc=$RC/$RC2 — $(printf '%s' "$OUT2" | tail -2)"
      fi
      OUT3=$(env "${COMMON[@]}" REQ_APP="$APPT" REQ_ENV=rec REQ_API=accounts-read REQ_CALLER=oig-provisioner \
             REQ_CLIENT_ID="${APPT}-rec" REQ_TEAM="autre-team" bash "$S" 2>&1); RC3=$?
      [ "$RC3" -eq 2 ] && printf '%s' "$OUT3" | grep -q "CONTRAT_DIVERGENT" && printf '%s' "$OUT3" | grep -q "team : manifeste='$TEAM' demande='autre-team'" \
        && ok "C.9b team FOURNIE différente ⇒ CONTRAT_DIVERGENT (le contrat prime sur TEAM_NOT_DECLARED)" \
        || ko "C.9b team divergente : rc=$RC3 — $(printf '%s' "$OUT3" | tail -2)"
      APPTI="p3a1teami$TS"; BTID="provision/${APPTI}-dev"; BTIR="provision/${APPTI}-rec"; CLEAN_BRANCHES+=("$BTID" "$BTIR")
      OUT5=$(env "${COMMON[@]}" REQ_APP="$APPTI" REQ_ENV=dev REQ_API=accounts-read REQ_CALLER=cli2-provisioner REQ_TEAM="$TEAM" bash "$S" 2>&1); RC5=$?
      raw_manifest "$BTID" "$APPTI" > "$TMP/tidev.yml"
      put_file "$BASE" "$MAN_DIR/${APPTI}.ansible.yml" "$TMP/tidev.yml" "merge simulé : provision(dev) $APPTI" >/dev/null
      OUT6=$(env "${COMMON[@]}" REQ_APP="$APPTI" REQ_ENV=rec REQ_API=accounts-read REQ_CALLER=cli2-provisioner bash "$S" 2>&1); RC6=$?
      MTIR=$(raw_manifest "$BTIR" "$APPTI")
      [ "$RC5" -eq 0 ] && [ "$RC6" -eq 0 ] \
        && printf '%s' "$MTIR" | grep -qxF "    rec: { auth: { vault_sub: \"deploy/${TEAM}/apps/${APPTI}/rec/oauth-client\" } }" \
        && ok "C.9d internal + team héritée : le TENANT du vault_sub rec suit la team (deploy/${TEAM}/…), pas le défaut banking-demo" \
        || ko "C.9d tenant hérité : rc=$RC5/$RC6 — $(printf '%s' "$MTIR" | grep '    rec:')"
      PRB=$(pr_body "$OUT2")
      printf '%s' "$PRB" | grep -q "equipe (cloisonnement) : $TEAM (heritee du manifeste" \
        && ok "C.9e corps de PR rec : la team héritée est NOMMÉE au valideur (« heritee du manifeste »)" \
        || ko "C.9e corps de PR rec sans mention de la team héritée : $(printf '%s' "$PRB" | grep -i equipe)"
      OUT4=$(env "${COMMON[@]}" "${LIBRE[@]}" REQ_APP="$APPT" REQ_ENV=int REQ_API=accounts-read REQ_CALLER=oig-provisioner \
             REQ_CLIENT_ID="${APPT}-int" bash "$S" 2>&1); RC4=$?
      # A7 : providers.int.yml existe désormais (banking-demo seule) ⇒ la team héritée
      # payments-team y est ABSENTE : TEAM_NOT_DECLARED ; sur une base d'avant A7 : PROVIDERS_MISSING.
      [ "$RC4" -eq 2 ] && printf '%s' "$OUT4" | grep -q "team héritée du manifeste : $TEAM" \
        && printf '%s' "$OUT4" | grep -qE "PROVIDERS_MISSING|TEAM_NOT_DECLARED" && ! branch_exists "$BTI" \
        && ok "C.9c team héritée (payments-team) sur int ⇒ la garde du palier VISÉ s'applique (TEAM_NOT_DECLARED — providers.int.yml ne la déclare pas ; PROVIDERS_MISSING sur une base d'avant A7), aucune branche" \
        || ko "C.9c garde du palier visé sur team héritée : rc=$RC4 branche=$(branch_exists "$BTI" && echo EXISTE || echo absente) — $(printf '%s' "$OUT4" | tail -2)"
    fi
  fi
fi

echo
echo "═══════════════════════════════════════════════════"
printf 'RÉSULTAT : %d/%d\n' "$PASS" $((PASS + FAIL))
[ "$FAIL" -eq 0 ] || exit 1
