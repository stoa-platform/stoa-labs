#!/usr/bin/env bash
# test-p2-posture-producteur.sh — la matrice de preuve du jalon P2 (ADR-092) :
# L'EXPOSITION ENTRE DANS LA CHAÎNE DU PRODUCTEUR.
#
# Ce qui doit être vrai à la fin de ce jalon, et que ce fichier mesure :
#   le formulaire COLLECTE la posture, le manifeste la PORTE, le rôle la LIT,
#   et le REGISTRE CENTRAL GAGNE contre elle — une demande plus faible que la
#   gouvernance est refusée par un code NOMMÉ, relayé jusqu'à la PR.
#
#   A. l'AUTORITÉ (`labctl posture`) — la surface que bash et Ansible appellent
#      réellement, pas la fonction Go (celle-là est couverte par `go test`).
#   B. le FORMULAIRE — les deux listes existent, et le pipeline les route.
#   C. le GABARIT et le MANIFESTE RENDU — la posture y arrive, sans marqueur.
#   D. les GARDES d'api-request.sh — hors ligne, AVANT tout geste Git.
#   E. le RÔLE — arbitrage, refus nommés, et les deux sens de l'axe exposition.
#   F. le CÂBLAGE — qui pose la source, et qui relaie le verdict.
#   G. LE BOUT EN BOUT sur le VRAI Gitea — la porte du jalon et sa contre-épreuve,
#      sur des dépôts SCRATCH (plateforme + équipe + GOUVERNANCE séparée).
#   H. les MUTATIONS — ce harnais SAIT rougir : quatre sabotages ciblés sur les
#      coutures neuves, chacun restauré à l'octet près (cmp).
#
# Hors ligne pour A–F et H. La section G exige le Gitea du lab ; elle se saute
# proprement (et le dit) s'il est absent — jamais un vert silencieux.
#
#   ./scripts/test-p2-posture-producteur.sh
#   GITEA_TOKEN_FILE=<fichier 0600> ./scripts/test-p2-posture-producteur.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
TS="$(date +%s)"
TMP="$(mktemp -d /tmp/p2posture.XXXXXX)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# shellcheck source=scripts/lib/posture-authority.sh
. "$REPO/scripts/lib/posture-authority.sh"
resolve_posture_authority "$TMP/labctl" \
  || { echo "ABANDON : aucun labctl — l'autorité de posture est le sujet de ce test, pas une dépendance optionnelle." >&2; exit 2; }
# Le couple de gouvernance n'a AUCUN défaut dans le code livrable (porte
# ci/lint-config-knobs.sh) : un harnais dit lui-même quel registre il consulte.
export GOVERNANCE_REPO="${GOVERNANCE_REPO:-ci/stoa-platform-ci}" \
       GOVERNANCE_PATH="${GOVERNANCE_PATH:-governance/classifications.yaml}"

REG="$TMP/classifications.yaml"
cat > "$REG" <<'YML'
apiVersion: governance.stoa.io/v1
kind: ClassificationRegistry
classifications:
  - {owner: accounts-team, tenant: banking-demo, api: accounts-read, classification: VH, exposure: external}
  - {owner: payments-team, tenant: payments-team, api: payments-read, classification: H, exposure: internal}
  - {owner: public-team,   tenant: public-demo,  api: rates-read,    classification: M,  exposure: internet}
YML

CLEANUP_URLS=()
cleanup(){
  if [ -n "${GITEA_TOKEN:-}" ] && [ -n "${GTHDR:-}" ] && [ -f "$GTHDR" ]; then
    for u in "${CLEANUP_URLS[@]:-}"; do
      [ -n "$u" ] && curl -s -o /dev/null -X DELETE -H @"$GTHDR" "$u" 2>/dev/null || true
    done
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════
echo "═══ A — l'AUTORITÉ : labctl posture, la surface que la chaîne appelle ═══"
# posture_case <label> <attendu-rc0|CODE> <projet> <api> <classification> <exposure>
posture_case(){
  local label="$1" want="$2"; shift 2
  local out rc
  out=$(LABCTL_CLASSIFICATION_SOURCE='' LABCTL_PROJECT='' "$LABCTL_BIN" posture \
        --project "$1" --api "$2" --declared-classification "$3" --declared-exposure "$4" \
        --classification-source "$REG" 2>&1); rc=$?
  if [ "$want" = "OK" ]; then
    [ "$rc" -eq 0 ] && ok "$label" || ko "$label : attendu rc=0, obtenu rc=$rc — $(printf '%s' "$out" | tail -1)"
  else
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "\[$want\]"; then
      ok "$label : refusé [$want]"
    else
      ko "$label : attendu [$want], obtenu rc=$rc — $(printf '%s' "$out" | tail -1)"
    fi
  fi
  printf '%s' "$out" > "$TMP/last-posture.out"
}

posture_case "demande CONFORME (VH/external)"                 OK accounts-team accounts-read VH external
grep -q 'source=central' "$TMP/last-posture.out" \
  && ok "la réponse annonce sa provenance (source=central)" \
  || ko "la réponse ne dit pas d'où vient la valeur retenue"
grep -q 'bundle=vh-external' "$TMP/last-posture.out" \
  && ok "la cellule NOMMÉE de la table de vérité est rendue (vh-external)" \
  || ko "aucun bouquet nommé dans la réponse"

posture_case "downgrade d'INTÉGRITÉ (VH -> M)"                CLASSIFICATION_SPOOFED accounts-team accounts-read M external
posture_case "downgrade d'EXPOSITION (external -> internal)"  CLASSIFICATION_SPOOFED accounts-team accounts-read VH internal
posture_case "l'autre sens (external -> internet)"            CLASSIFICATION_SPOOFED accounts-team accounts-read VH internet
posture_case "internet gouverné -> external déclaré"          CLASSIFICATION_SPOOFED public-team   rates-read    M  external
posture_case "API non enregistrée"                            CLASSIFICATION_UNGOVERNED accounts-team accounts-secret VH external
posture_case "emprunt de ligne (l'API d'une autre équipe)"    CLASSIFICATION_UNGOVERNED accounts-team payments-read H internal
posture_case "valeur hors vocabulaire (exposure=dmz)"         INTEGRITY_INCONSISTENT payments-team payments-read H dmz

# sur-déclaration : acceptée, corrigée, ET signalée
OUT=$(LABCTL_CLASSIFICATION_SOURCE='' LABCTL_PROJECT='' "$LABCTL_BIN" posture --project payments-team --api payments-read \
      --declared-classification VH --declared-exposure internal --classification-source "$REG" 2>&1)
if printf '%s' "$OUT" | grep -q 'classification=H ' && printf '%s' "$OUT" | grep -q 'declared: classification=VH' \
   && printf '%s' "$OUT" | grep -q 'sur-provisionné'; then
  ok "sur-déclaration : le CENTRAL (H) gagne, la demande (VH) reste visible, l'écart est signalé"
else
  ko "sur-déclaration mal rendue : $OUT"
fi

# la même commande SANS registre : elle répond, et le DIT — c'est ce label qui
# empêche un appelant distrait de croire qu'il a obtenu un avis gouverné.
OUT=$(LABCTL_CLASSIFICATION_SOURCE='' LABCTL_PROJECT='' "$LABCTL_BIN" posture --api x --declared-classification M --declared-exposure internal -o json 2>&1)
printf '%s' "$OUT" | grep -q '"source": "demande"' \
  && ok "sans registre : réponse rendue depuis la DEMANDE, et étiquetée comme telle" \
  || ko "sans registre : la provenance n'est pas annoncée — $OUT"

# registre cassé : refus, jamais un repli sur la déclaration
printf 'classifications: [ {owner: a}\n' > "$TMP/broken.yaml"
OUT=$(LABCTL_CLASSIFICATION_SOURCE='' LABCTL_PROJECT='' "$LABCTL_BIN" posture --project accounts-team --api accounts-read \
      --declared-classification M --declared-exposure internal --classification-source "$TMP/broken.yaml" 2>&1); RC=$?
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'CLASSIFICATION_UNGOVERNED' \
  && ok "registre illisible : refus [CLASSIFICATION_UNGOVERNED], aucun repli sur la demande" \
  || ko "registre illisible : attendu un refus, obtenu rc=$RC — $OUT"

echo
echo "═══ B — le FORMULAIRE collecte la posture ═══"
XML="ci/jenkins/api-request.job.xml"
for P in CLASSIFICATION EXPOSURE; do
  grep -q "<name>$P</name>" "$XML" \
    && ok "paramètre $P présent dans le formulaire" \
    || ko "paramètre $P ABSENT — la demande ne collecte pas la posture"
done
for V in VH H M; do
  grep -q "<string>$V</string>" "$XML" || ko "choix $V absent de CLASSIFICATION"
done
for V in internal external internet; do
  grep -q "<string>$V</string>" "$XML" || ko "choix $V absent de EXPOSURE"
done
ok "les six valeurs des deux axes sont proposées (l'épinglage au moteur est TestProducerFormVocabularyDoesNotDrift)"
grep -q 'CLASSIFICATION=${params.CLASSIFICATION' ci/Jenkinsfile.api-request \
  && grep -q 'EXPOSURE=${params.EXPOSURE' ci/Jenkinsfile.api-request \
  && ok "le pipeline ROUTE les deux valeurs BRUTES au script (withEnv, jamais le canal natif)" \
  || ko "le pipeline ne route pas la posture — le script la verrait vide"

echo
echo "═══ C — le GABARIT et le MANIFESTE RENDU ═══"
TPL="gateways/templates/publish.yml.tmpl"
grep -q '__CLASSIFICATION__' "$TPL" && grep -q '__EXPOSURE__' "$TPL" \
  && ok "le gabarit porte les deux marqueurs de posture" \
  || ko "le gabarit ne porte pas la posture — le manifeste ne pourrait pas la déclarer"
grep -q 's/__CLASSIFICATION__/' scripts/api-request.sh && grep -q 's/__EXPOSURE__/' scripts/api-request.sh \
  && ok "api-request.sh substitue les deux marqueurs" \
  || ko "api-request.sh ne substitue pas la posture — le manifeste porterait '__CLASSIFICATION__'"
grep -q 'GABARIT_NON_SUBSTITUE' scripts/api-request.sh \
  && ok "un marqueur survivant est refusé (GABARIT_NON_SUBSTITUE), jamais committé tel quel" \
  || ko "aucune garde contre un marqueur non substitué"
# rendu réel du gabarit, comme le fait le script
sed -e 's/__API_NAME__/probe/g' -e 's/__API_VERSION__/1.0.0/g' -e 's/__INBOUND_MODE__/jwt/g' \
    -e 's/__CLASSIFICATION__/VH/g' -e 's/__EXPOSURE__/external/g' "$TPL" > "$TMP/rendered.yml"
python3 - "$TMP/rendered.yml" <<'PY' && ok "manifeste rendu : apim_api.classification/exposure lus par un parseur YAML" || ko "le manifeste rendu ne porte pas une posture lisible"
import sys, yaml
d = (yaml.safe_load(open(sys.argv[1])) or {}).get("apim_api") or {}
sys.exit(0 if d.get("classification") == "VH" and d.get("exposure") == "external" else 1)
PY
grep -q '__[A-Z_]*__' "$TMP/rendered.yml" && ko "le rendu laisse un marqueur" || ok "le rendu ne laisse AUCUN marqueur"

echo
echo "═══ D — les GARDES d'api-request.sh (hors ligne, AVANT tout geste Git) ═══"
guard(){ # $1=label $2=tag ; reste = env
  local label="$1" tag="$2"; shift 2
  local out rc
  out=$(env -i PATH="$PATH" GIT_HOST="http://127.0.0.1:1" GITEA_TOKEN=dummy FORGE_KIND=gitea \
        GOVERNANCE_REPO="$GOVERNANCE_REPO" GOVERNANCE_PATH="$GOVERNANCE_PATH" \
        LABCTL_BIN="$LABCTL_BIN" ACTION=create TEAM=probe API_NAME=probe API_VERSION=1.0.0 \
        OPENAPI_SPEC='{"openapi":"3.0.0"}' INBOUND_MODE=jwt \
        CLASSIFICATION=VH EXPOSURE=external "$@" bash scripts/api-request.sh 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "$tag"; then
    if printf '%s' "$out" | grep -q '\[1/5\]'; then
      ko "$label : refusé APRÈS le premier clone — pas 'avant tout geste Git'"
    else ok "$label : refusé ($tag), avant tout appel réseau"; fi
  else
    ko "$label : attendu rc=1 + '$tag', obtenu rc=$rc — $(printf '%s' "$out" | tail -1)"
  fi
}
guard "CLASSIFICATION absente"       "CHAMP_REQUIS : CLASSIFICATION" CLASSIFICATION=''
guard "EXPOSURE absente"             "CHAMP_REQUIS : EXPOSURE"       EXPOSURE=''
guard "classification hors classe"   "POSTURE_INVALIDE"              CLASSIFICATION='V H'
guard "exposition hors classe"       "POSTURE_INVALIDE"              EXPOSURE='ex/ternal'
guard "classification hors vocabulaire" "POSTURE_INVALIDE"           CLASSIFICATION=XL
guard "exposition hors vocabulaire"  "POSTURE_INVALIDE"              EXPOSURE=dmz
guard "autorité absente"             "POSTURE_AUTORITE_ABSENTE"      LABCTL_BIN=/nonexistent/labctl

# La garde d'entrée ne doit PAS consulter le registre : une API pas encore
# enregistrée (le cas normal d'un `create`) doit pouvoir ouvrir sa PR et y LIRE
# pourquoi elle est refusée. Un LABCTL_CLASSIFICATION_SOURCE ambiant ne doit donc
# rien changer à cette étape.
OUT=$(env -i PATH="$PATH" GIT_HOST="http://127.0.0.1:1" GITEA_TOKEN=dummy FORGE_KIND=gitea \
      GOVERNANCE_REPO="$GOVERNANCE_REPO" GOVERNANCE_PATH="$GOVERNANCE_PATH" \
      LABCTL_BIN="$LABCTL_BIN" LABCTL_CLASSIFICATION_SOURCE="$REG" LABCTL_PROJECT=accounts-team \
      ACTION=create TEAM=probe API_NAME=api-neuve API_VERSION=1.0.0 \
      OPENAPI_SPEC='{"openapi":"3.0.0"}' INBOUND_MODE=jwt CLASSIFICATION=VH EXPOSURE=external \
      bash scripts/api-request.sh 2>&1)
printf '%s' "$OUT" | grep -q 'CLASSIFICATION_UNGOVERNED' \
  && ko "la garde d'entrée a consulté le registre ambiant — une API neuve serait refusée AVANT toute PR" \
  || ok "un LABCTL_CLASSIFICATION_SOURCE ambiant ne détourne PAS la garde d'entrée (l'arbitrage reste au plan)"

echo
echo "═══ E — le RÔLE lit la posture, et le registre GAGNE ═══"
mk_manifest(){ # $1=fichier $2=classification $3=exposure $4=nom
  cat > "$1" <<YML
apim_api:
  name: "$4"
  version: "1.0.0"
  contract: "{{ (pub_manifest_path | dirname) }}/$4.openapi.yaml"
  team: ""
  classification: "$2"
  exposure: "$3"
  inbound: {}
YML
}
role_case(){ # $1=label $2=attendu(OK|MOTIF) $3=manifeste $4=team ; reste = extra-vars
  local label="$1" want="$2" mani="$3" team="$4"; shift 4
  local out rc
  out=$(ansible-playbook -i ansible/inventory.lab.ini ansible/test-posture-guards.yml \
        -e apim_ss_manifest="$mani" -e apim_ss_team="$team" \
        -e apim_pub_labctl_bin="$LABCTL_BIN" "$@" 2>&1); rc=$?
  printf '%s' "$out" > "$TMP/last-role.out"
  if [ "$want" = "OK" ]; then
    [ "$rc" -eq 0 ] && ok "$label" || ko "$label : attendu succès, obtenu rc=$rc — $(grep -m1 '"msg"' <<<"$out" | cut -c1-160)"
  else
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "$want"; then ok "$label : refusé ($want)"
    else ko "$label : attendu '$want', obtenu rc=$rc — $(grep -m1 'fatal' -A3 <<<"$out" | tr '\n' ' ' | cut -c1-200)"; fi
  fi
}
SRC="-e apim_pub_classification_source=$REG"
mk_manifest "$TMP/m-ok.yml"      VH external accounts-read
mk_manifest "$TMP/m-down.yml"    M  internal accounts-read
mk_manifest "$TMP/m-expo.yml"    VH internal accounts-read
mk_manifest "$TMP/m-net.yml"     VH internet accounts-read
mk_manifest "$TMP/m-over.yml"    VH internal payments-read
mk_manifest "$TMP/m-nogov.yml"   VH external accounts-secret
mk_manifest "$TMP/m-empty.yml"   ""  ""       accounts-read

role_case "demande conforme -> posture du registre appliquée" OK "$TMP/m-ok.yml" accounts-team $SRC
grep -q 'POSTURE_RETENUE : accounts-read classification=VH exposure=external' "$TMP/last-role.out" \
  && ok "la posture RETENUE est écrite au journal du build, avec sa provenance" \
  || ko "aucune ligne POSTURE_RETENUE lisible dans le journal"
grep -q 'source=central' "$TMP/last-role.out" \
  && ok "le journal dit que la valeur vient du registre, pas de la demande" \
  || ko "la provenance n'apparaît pas au journal"

role_case "downgrade d'intégrité"          "CLASSIFICATION_SPOOFED"  "$TMP/m-down.yml" accounts-team $SRC
role_case "downgrade d'exposition"         "CLASSIFICATION_SPOOFED"  "$TMP/m-expo.yml" accounts-team $SRC
role_case "l'autre sens de l'exposition"   "CLASSIFICATION_SPOOFED"  "$TMP/m-net.yml"  accounts-team $SRC
role_case "API non gouvernée"              "CLASSIFICATION_UNGOVERNED" "$TMP/m-nogov.yml" accounts-team $SRC
role_case "posture non déclarée"           "POSTURE_MANQUANTE"       "$TMP/m-empty.yml" accounts-team $SRC
role_case "registre introuvable"           "REGISTRE_GOUVERNANCE_ABSENT" "$TMP/m-ok.yml" accounts-team -e apim_pub_classification_source="$TMP/pas-de-registre.yaml"
role_case "autorité absente"               "POSTURE_AUTORITE_ABSENTE" "$TMP/m-ok.yml" accounts-team $SRC -e apim_pub_labctl_bin=/nonexistent/labctl

# sur-déclaration : la publication PASSE, la correction est faite et dite
role_case "sur-déclaration (VH demandé, H gouverné)" OK "$TMP/m-over.yml" payments-team $SRC
grep -q 'POSTURE_RETENUE : payments-read classification=H exposure=internal' "$TMP/last-role.out" \
  && ok "le registre (H/internal) écrase la demande (VH/internal) sans la bloquer" \
  || ko "la posture centrale n'a pas remplacé la demande"
grep -q 'sur-provisionné' "$TMP/last-role.out" \
  && ok "l'écart de sur-déclaration est signalé au journal" \
  || ko "la sur-déclaration passe en silence"

# le mode SANS registre existe, et il est BRUYANT (jamais silencieux)
OUT=$(ansible-playbook -i ansible/inventory.lab.ini ansible/test-posture-guards.yml \
      -e apim_ss_manifest="$TMP/m-down.yml" -e apim_ss_team=accounts-team \
      -e apim_pub_labctl_bin="$LABCTL_BIN" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'POSTURE_NON_ARBITREE'; then
  ok "sans registre : le rôle passe, mais ANNONCE que rien n'a été arbitré"
else
  ko "sans registre : attendu un succès bruyant (POSTURE_NON_ARBITREE), obtenu rc=$RC"
fi

echo
echo "═══ F — le CÂBLAGE : qui pose la source, qui relaie le verdict ═══"
grep -q 'import_tasks: posture.yml' ansible/roles/apim_publish_api/tasks/main.yml \
  && ok "le rôle importe posture.yml" || ko "posture.yml n'est jamais importée — code mort"
python3 - <<'PY' && ok "posture.yml est importée AVANT les secrets et AVANT le premier appel gateway" || ko "posture.yml tourne trop tard : un refus laisserait une API derrière lui"
s = open("ansible/roles/apim_publish_api/tasks/main.yml").read()
import sys
sys.exit(0 if s.index("posture.yml") < s.index("secrets.yml") else 1)
PY
grep -q 'apim_pub_classification_source="\$GOV_REGISTRY"' scripts/team-publish.sh \
  && ok "team-publish.sh POSE la source au rôle (la chaîne ne peut pas l'oublier)" \
  || ko "team-publish.sh ne passe pas la source — le rôle publierait sans arbitrage"
grep -q 'GOVERNANCE_REPO' scripts/team-publish.sh && grep -q 'REGISTRE_GOUVERNANCE_INACCESSIBLE' scripts/team-publish.sh \
  && ok "team-publish.sh clone le registre depuis son PROPRE dépôt, fail-closed" \
  || ko "team-publish.sh ne va pas chercher le registre hors du dépôt d'équipe"
grep -q 'POSTURE_RETENUE' scripts/team-publish.sh \
  && ok "team-publish.sh relaie la posture retenue jusqu'au commentaire de PR" \
  || ko "la posture retenue ne remonte pas à la PR"
grep -q 'CLASSIFICATION_SPOOFED' scripts/api-request.sh \
  && ok "api-request.sh nomme le refus de posture dans son verdict de PLAN" \
  || ko "un refus de posture arriverait sur la PR sans être nommé"
grep -q 'POSTURE_RC' scripts/api-request.sh \
  && ok "le verdict du plan tient compte du refus de posture" \
  || ko "le plan pourrait être ✅ avec une posture refusée"
for J in ci/Jenkinsfile.api-request ci/Jenkinsfile.team-publish; do
  grep -q 'GOVERNANCE_REPO' "$J" && ok "$(basename "$J") : le dépôt de gouvernance est un knob de site" \
    || ko "$(basename "$J") : chemin de gouvernance non configurable"
done

echo
echo "═══ G — BOUT EN BOUT sur le VRAI Gitea (porte + contre-épreuve) ═══"
GITEA_TOKEN=""
if [ -n "${GITEA_TOKEN_FILE:-}" ] && [ -r "$GITEA_TOKEN_FILE" ]; then
  GITEA_TOKEN="$(cat "$GITEA_TOKEN_FILE")"
elif docker inspect poc-gitea >/dev/null 2>&1; then
  GITEA_TOKEN=$(docker exec -u git poc-gitea gitea admin user generate-access-token \
    --username ci --token-name "p2posture-$TS" \
    --scopes write:repository,write:issue,write:organization 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
fi
if [ -z "$GITEA_TOKEN" ] || ! curl -s -o /dev/null "http://localhost:13000" 2>/dev/null; then
  echo "  (section G SAUTÉE — Gitea du lab indisponible ; la porte du jalon n'est PAS mesurée ici)"
  SKIPPED_G=1
else
  SKIPPED_G=0
  GH="http://localhost:13000"
  PLATORG="p2plat${TS}"; TEAMORG="p2team${TS}"
  GTHDR="$TMP/gtoken.hdr"; umask 077; printf 'Authorization: token %s\n' "$GITEA_TOKEN" > "$GTHDR"
  gapi(){ curl -s -H @"$GTHDR" -H 'Content-Type: application/json' "$@"; }
  R=(); R+=("$(gapi -X POST -d "{\"username\":\"$PLATORG\"}" -o /dev/null -w '%{http_code}' "$GH/api/v1/orgs")")
  R+=("$(gapi -X POST -d "{\"username\":\"$TEAMORG\"}" -o /dev/null -w '%{http_code}' "$GH/api/v1/orgs")")
  R+=("$(gapi -X POST -d '{"name":"stoa-labs","auto_init":false}' -o /dev/null -w '%{http_code}' "$GH/api/v1/orgs/$PLATORG/repos")")
  R+=("$(gapi -X POST -d '{"name":"governance","auto_init":false}' -o /dev/null -w '%{http_code}' "$GH/api/v1/orgs/$PLATORG/repos")")
  R+=("$(gapi -X POST -d '{"name":"apis","auto_init":false}' -o /dev/null -w '%{http_code}' "$GH/api/v1/orgs/$TEAMORG/repos")")
  CLEANUP_URLS+=("$GH/api/v1/repos/$PLATORG/stoa-labs" "$GH/api/v1/repos/$PLATORG/governance" \
                 "$GH/api/v1/repos/$TEAMORG/apis" "$GH/api/v1/orgs/$PLATORG" "$GH/api/v1/orgs/$TEAMORG")
  if printf '%s\n' "${R[@]}" | grep -qv '^201$'; then
    ko "préparation scratch en échec (HTTP ${R[*]}) — section G avortée"
  else
    WD="$TMP/g"; mkdir -p "$WD/plat/poc-control-plane-federation/ansible" "$WD/team/apis" "$WD/gov/governance"
    cat > "$WD/plat/poc-control-plane-federation/ansible/providers.dev.yml" <<YML
---
providers:
  - team: ${TEAMORG}
    description: "scratch team P2"
    repo: ${TEAMORG}/apis
    approvers: []
YML
    # LE REGISTRE : gouverne 'compte-api' en VH/external. C'est LUI qui décide,
    # et la suite de cette section ne fait que le vérifier.
    cat > "$WD/gov/governance/classifications.yaml" <<YML
apiVersion: governance.stoa.io/v1
kind: ClassificationRegistry
classifications:
  - {owner: ${TEAMORG}, tenant: banking-demo, api: compte-api, classification: VH, exposure: external}
  - {owner: ${TEAMORG}, tenant: banking-demo, api: taux-api,   classification: VH, exposure: external}
YML
    for D in plat team gov; do
      ( cd "$WD/$D" && git init -q -b main && git -c user.name=t -c user.email=t@t add -A 2>/dev/null
        git -c user.name=t -c user.email=t commit -qm init --allow-empty ) >/dev/null 2>&1
    done
    AUTH_B64=$(printf 'x:%s' "$GITEA_TOKEN" | base64 | tr -d '\n')
    for P in "plat:$PLATORG/stoa-labs" "team:$TEAMORG/apis" "gov:$PLATORG/governance"; do
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0="Authorization: Basic ${AUTH_B64}" \
        git -C "$WD/${P%%:*}" push -q "$GH/${P#*:}.git" main
    done
    unset AUTH_B64
    sleep 3   # settle : Gitea indexe l'objet avant l'appel API (motif test-api-request.sh)

    export GIT_HOST="$GH" GIT_REPO="${PLATORG}/stoa-labs" GIT_WEB_HOST="$GH" GITEA_TOKEN="$GITEA_TOKEN" FORGE_KIND=gitea
    export GOVERNANCE_REPO="${PLATORG}/governance" GOVERNANCE_PATH="governance/classifications.yaml"
    export LABCTL_BIN
    SPEC='openapi: "3.0.0"
info: {title: compte-api, version: "1.0.0"}
paths: {}'
    pr_comment(){ gapi "$GH/api/v1/repos/$TEAMORG/apis/issues/$1/comments" | python3 -c 'import json,sys; print(" ".join(c["body"] for c in json.load(sys.stdin)))' 2>/dev/null; }

    echo "── G1. LA PORTE : demande conforme, la valeur retenue est celle du REGISTRE ──"
    OUT=$(ACTION=create TEAM="$TEAMORG" API_NAME=compte-api API_VERSION=1.0.0 \
          OPENAPI_SPEC="$SPEC" INBOUND_MODE=jwt CLASSIFICATION=VH EXPOSURE=external \
          bash scripts/api-request.sh 2>&1); RC=$?
    PR1=$(grep -oE 'PR #[0-9]+ ouverte' <<<"$OUT" | grep -oE '[0-9]+' | head -1)
    if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'posture compte-api .*source=central'; then
      ok "G1 : la posture retenue apparaît dans le JOURNAL DU BUILD, source=central"
    else
      ko "G1 : aucune ligne de posture centrale dans le journal (rc=$RC) — $(tail -2 <<<"$OUT")"
    fi
    MANI=$(gapi "$GH/api/v1/repos/$TEAMORG/apis/raw/api/compte-api-1.0.0/apis/compte-api.publish.yml")
    printf '%s' "$MANI" | grep -q 'classification: "VH"' && printf '%s' "$MANI" | grep -q 'exposure: "external"' \
      && ok "G1 : le manifeste committé PORTE la posture déclarée" \
      || ko "G1 : le manifeste ne porte pas la posture — $(printf '%s' "$MANI" | head -3)"
    C1=$(pr_comment "${PR1:-0}")
    printf '%s' "$C1" | grep -q 'PLAN OK' && printf '%s' "$C1" | grep -q 'bundle=vh-external' \
      && ok "G1 : la PR porte ✅ et la posture retenue (bundle nommé), lisible par le demandeur" \
      || ko "G1 : la PR ne porte pas la posture retenue — $(printf '%s' "$C1" | head -c 200)"

    echo "── G2. LA CONTRE-ÉPREUVE : une demande PLUS FAIBLE que le registre ──"
    OUT=$(ACTION=create TEAM="$TEAMORG" API_NAME=compte-faible API_VERSION=1.0.0 \
          OPENAPI_SPEC="$SPEC" INBOUND_MODE=jwt CLASSIFICATION=M EXPOSURE=internal \
          bash scripts/api-request.sh 2>&1); RC=$?
    PR2=$(grep -oE 'PR #[0-9]+ ouverte' <<<"$OUT" | grep -oE '[0-9]+' | head -1)
    C2=$(pr_comment "${PR2:-0}")
    # 'compte-faible' n'est PAS au registre : le refus attendu est UNGOVERNED —
    # et c'est le bon message, car une API inconnue de la gouvernance ne peut pas
    # davantage être publiée qu'une API déclassée.
    if [ "$RC" -ne 0 ] && printf '%s' "$C2" | grep -q 'CLASSIFICATION_UNGOVERNED'; then
      ok "G2a : API absente du registre -> PR ouverte, ❌ nommé [CLASSIFICATION_UNGOVERNED] SUR LA PR"
    else
      ko "G2a : attendu un refus nommé relayé à la PR (rc=$RC) — $(printf '%s' "$C2" | head -c 200)"
    fi
    # LE downgrade proprement dit : l'API EST gouvernée (VH/external), la demande
    # déclare M/internal. Deux contrôles obligatoires perdus d'un coup.
    OUT=$(ACTION=create TEAM="$TEAMORG" API_NAME=taux-api API_VERSION=1.0.0 \
          OPENAPI_SPEC="$SPEC" INBOUND_MODE=jwt CLASSIFICATION=M EXPOSURE=internal \
          bash scripts/api-request.sh 2>&1); RC=$?
    PR3=$(grep -oE 'PR #[0-9]+ ouverte' <<<"$OUT" | grep -oE '[0-9]+' | head -1)
    C3=$(pr_comment "${PR3:-0}")
    if [ "$RC" -ne 0 ] && printf '%s' "$C3" | grep -q 'CLASSIFICATION_SPOOFED'; then
      ok "G2b : downgrade VH/external -> M/internal REFUSÉ, [CLASSIFICATION_SPOOFED] relayé jusqu'à la PR"
    else
      ko "G2b : le downgrade n'a pas été relayé nommément à la PR (rc=$RC) — $(printf '%s' "$C3" | head -c 200)"
    fi
    printf '%s' "$C3" | grep -q 'NE PAS MERGER' \
      && ok "G2b : le commentaire dit explicitement de ne pas merger" \
      || ko "G2b : le refus n'interdit pas le merge en toutes lettres"
  fi
fi

echo
echo "═══ H — MUTATIONS : ce harnais sait-il rougir ? ═══"
# Chaque sabotage vise une COUTURE NEUVE de P2, et chacun est vérifié par une
# ÉPREUVE DE COMPORTEMENT, jamais par un grep de la ligne qu'on vient de retirer
# (ce serait circulaire : la mutation prouverait sa propre présence, pas qu'elle
# porte quelque chose). Le harnais exige d'abord que l'épreuve soit VERTE avant
# le sabotage — sans quoi son rouge d'après ne dirait rien.
mutate(){ # $1=fichier $2=sed-expr $3=label $4=épreuve (verte AVANT, rouge APRÈS)
  local f="$1" expr="$2" label="$3" cmd="$4"
  if ! eval "$cmd" >/dev/null 2>&1; then
    ko "MUTATION '$label' : l'épreuve témoin est DÉJÀ rouge avant le sabotage — rien ne serait prouvé"
    return
  fi
  cp "$f" "$TMP/mut.orig"
  sed -i '' "$expr" "$f" 2>/dev/null || sed -i "$expr" "$f"
  if cmp -s "$f" "$TMP/mut.orig"; then
    ko "MUTATION '$label' : le sed n'a RIEN changé — l'épreuve qui suit serait vacante"
  elif eval "$cmd" >/dev/null 2>&1; then
    ko "MUTATION '$label' : sabotage NON DÉTECTÉ — l'épreuve correspondante est vacante"
  else
    ok "MUTATION '$label' : détectée (l'épreuve vire au rouge)"
  fi
  cp "$TMP/mut.orig" "$f"
  cmp -s "$f" "$TMP/mut.orig" && ok "  … et le fichier est restauré à l'octet près" \
    || ko "  … RESTAURATION EN ÉCHEC sur $f"
}

PLAY="ansible-playbook -i ansible/inventory.lab.ini ansible/test-posture-guards.yml -e apim_pub_labctl_bin=$LABCTL_BIN"

# Les épreuves-témoins sont des FONCTIONS, pas des chaînes à ré-échapper : une
# commande imbriquée dans un `eval` finit toujours par se casser sur ses propres
# guillemets, et un témoin cassé rend la mutation muette (constaté ici même).
# `set -o pipefail` est actif dans ce fichier, et ces deux témoins observent des
# commandes qui REFUSENT (donc rendent non-zéro). Un `cmd | grep -q` y rendrait
# le code de la commande, pas celui du grep : le témoin serait rouge quoi qu'il
# arrive, et la mutation qui suit ne mesurerait plus rien. D'où la capture en
# variable, puis le grep — piège déjà payé ailleurs dans ce dépôt.
temoin_champ_requis(){
  local out
  out=$(env -i PATH="$PATH" GIT_HOST="http://127.0.0.1:1" GITEA_TOKEN=dummy FORGE_KIND=gitea \
    GOVERNANCE_REPO="$GOVERNANCE_REPO" GOVERNANCE_PATH="$GOVERNANCE_PATH" \
    LABCTL_BIN="$LABCTL_BIN" ACTION=create TEAM=probe API_NAME=probe API_VERSION=1.0.0 \
    OPENAPI_SPEC='{"openapi":"3.0.0"}' INBOUND_MODE=jwt CLASSIFICATION='' EXPOSURE=external \
    bash scripts/api-request.sh 2>&1)
  printf '%s' "$out" | grep -q 'CHAMP_REQUIS : CLASSIFICATION'
}
# La garde POSTURE_MANQUANTE n'est pas le SEUL rempart — labctl refuse aussi une
# classification vide. Ce qu'elle apporte, c'est le NOM : le témoin porte donc
# sur le nom du refus, pas sur le simple fait qu'il y en ait un. Sans quoi la
# mutation serait « non détectée » alors qu'un message vient d'être perdu.
temoin_posture_manquante(){
  local out
  out=$($PLAY -e apim_ss_manifest="$TMP/m-empty.yml" -e apim_ss_team=accounts-team \
        -e apim_pub_classification_source="$REG" 2>&1)
  printf '%s' "$out" | grep -q 'POSTURE_MANQUANTE'
}

# 1. Le rôle n'envoie plus le registre à l'autorité. labctl répondrait alors
#    depuis la DEMANDE, avec rc=0 : un arbitrage parfaitement imaginaire. Ce que
#    la garde `source == central` existe pour attraper.
mutate ansible/roles/apim_publish_api/tasks/posture.yml \
  "/- --classification-source/,+1d" \
  "le registre n'atteint plus l'autorité (la réponse viendrait de la demande)" \
  "$PLAY -e apim_ss_manifest=$TMP/m-over.yml -e apim_ss_team=payments-team -e apim_pub_classification_source=$REG"

# 2. La garde de présence du rôle accepte une posture VIDE : le manifeste
#    n'engagerait plus rien, et il n'y aurait plus rien à reprendre.
mutate ansible/roles/apim_publish_api/tasks/posture.yml \
  "s/| trim) | length > 0/| trim) | length >= 0/g" \
  "une posture non déclarée n'est plus NOMMÉE" \
  "temoin_posture_manquante"

# 3. api-request.sh cesse d'exiger la classification : la demande partirait sans
#    poser de posture, donc sans possibilité d'être reprise.
mutate scripts/api-request.sh \
  '/^\[ -n "\$CLASSIFICATION" \]/d' \
  "le champ CLASSIFICATION n'est plus obligatoire" \
  "temoin_champ_requis"

# 4. Le gabarit perd la classification : le manifeste committé ne la porterait
#    plus, et le rôle refuserait bien plus loin, sur un manifeste que personne
#    n'a écrit à la main.
mutate gateways/templates/publish.yml.tmpl \
  '/^  classification: "__CLASSIFICATION__"/d' \
  "le gabarit ne porte plus la classification" \
  "sed -e 's/__API_NAME__/probe/g' -e 's/__API_VERSION__/1.0.0/g' -e 's/__INBOUND_MODE__/jwt/g' -e 's/__CLASSIFICATION__/VH/g' -e 's/__EXPOSURE__/external/g' gateways/templates/publish.yml.tmpl | python3 -c 'import sys,yaml; d=(yaml.safe_load(sys.stdin) or {}).get(\"apim_api\") or {}; sys.exit(0 if d.get(\"classification\")==\"VH\" and d.get(\"exposure\")==\"external\" else 1)'"

echo
echo "═══ RÉSULTAT : $PASS OK / $FAIL KO ═══"
[ "${SKIPPED_G:-0}" -eq 1 ] && echo "⚠ section G non jouée (Gitea absent) — la PORTE du jalon n'est pas couverte par ce run"
[ "$FAIL" -eq 0 ]
