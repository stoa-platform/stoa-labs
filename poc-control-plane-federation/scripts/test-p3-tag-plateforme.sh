#!/usr/bin/env bash
# test-p3-tag-plateforme.sh — la matrice de preuve du jalon P3 (ADR-093) :
# LE TAG EST POSÉ PAR LA PLATEFORME, JAMAIS PAR LE DEMANDEUR.
#
# Ce qui doit être vrai à la fin de ce jalon, et que ce fichier mesure :
#   l'API porte sur la gateway le tag de la posture GOUVERNÉE ; un contrat qui
#   embarque son propre tag de posture le PERD ; les tags métier du producteur
#   SURVIVENT ; et une mise à jour de définition — qui EFFACE le tag, mesuré —
#   ne laisse pas l'API sans tag à la fin du rôle.
#
#   A. l'AUTORITÉ (`labctl posture`) — le tag est DÉRIVÉ du bouquet et suit le
#      REGISTRE, pas la déclaration. Hors ligne.
#   B. le RÔLE hors ligne — la garde du mode non arbitré (TAG_NON_ARBITRE) :
#      sans gouvernance, la plateforme ne pose RIEN et le dit.
#   C. LE BOUT EN BOUT sur la wM 10.15 RÉELLE — la porte du jalon, ses trois
#      contre-épreuves, et la POSITION des deux passes (mesurée dans le journal,
#      pas relue dans le fichier).
#   D. les MUTATIONS — ce harnais SAIT rougir : quatre sabotages des coutures
#      neuves, chacun restauré à l'octet près (cmp).
#
# Hors ligne pour A, B et la partie hors ligne de D. Les sections C et D-live
# exigent la gateway RÉELLE (poc-webmethods-real, :5555) ; elles se sautent
# proprement — et le disent — si elle est absente. Jamais un vert silencieux.
#
#   ./scripts/test-p3-tag-plateforme.sh
#   WM_ADMIN=http://localhost:5555/rest/apigateway ./scripts/test-p3-tag-plateforme.sh
set -u
set -o pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
TMP="$(mktemp -d /tmp/p3tag.XXXXXX)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
skip(){ printf '  ⏭  %s\n' "$*"; }

# shellcheck source=scripts/lib/posture-authority.sh
. "$REPO/scripts/lib/posture-authority.sh"
resolve_posture_authority "$TMP/labctl" \
  || { echo "ABANDON : aucun labctl — l'autorité qui DÉRIVE le tag est le sujet de ce test, pas une dépendance optionnelle." >&2; exit 2; }

WM_ADMIN="${WM_ADMIN:-http://localhost:5555/rest/apigateway}"
WM_USER="${WM_USER:-Administrator}"
WM_PASS="${WM_PASS:-manage}"
TEAM="${P3_TEAM:-banking-demo}"
TAGFILE="ansible/roles/apim_publish_api/tasks/tag.yml"
MAINFILE="ansible/roles/apim_publish_api/tasks/main.yml"

REG="$TMP/classifications.yaml"
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════
echo "═══ A — l'AUTORITÉ : le tag est DÉRIVÉ, et il suit le registre ═══"
cat > "$REG" <<'YML'
apiVersion: governance.stoa.io/v1
kind: ClassificationRegistry
classifications:
  - {owner: banking-demo, tenant: banking-demo, api: comptes-lecture, classification: VH, exposure: external}
  - {owner: banking-demo, tenant: banking-demo, api: taux-lecture,    classification: M,  exposure: internet}
YML

posture_json(){  # <projet> <api> <classification> <exposure>
  LABCTL_CLASSIFICATION_SOURCE='' LABCTL_PROJECT='' "$LABCTL_BIN" posture \
    --project "$1" --api "$2" --declared-classification "$3" --declared-exposure "$4" \
    --classification-source "$REG" -o json 2>&1
}
jget(){ python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1],""))' "$1"; }

OUT=$(posture_json banking-demo comptes-lecture VH external)
T=$(printf '%s' "$OUT" | jget tag); P=$(printf '%s' "$OUT" | jget tag_prefix); B=$(printf '%s' "$OUT" | jget bundle)
[ "$T" = "${P}${B}" ] && ok "le tag est le bouquet NOMMÉ dans l'espace de noms annoncé ($T)" \
                      || ko "tag='$T' n'est pas préfixe+bouquet ('$P' + '$B')"
[ "$T" = "posture:vh-external" ] && ok "cellule vh-external -> $T" || ko "attendu posture:vh-external, obtenu '$T'"

# LE POINT DU JALON vu de l'autorité : la sur-déclaration est corrigée, et le
# tag suit la valeur RETENUE. Sans quoi la gateway porterait l'étiquette de ce
# que le demandeur a écrit, pas de ce que la gouvernance a décidé.
OUT=$(posture_json banking-demo taux-lecture VH internet)
T=$(printf '%s' "$OUT" | jget tag)
[ "$T" = "posture:m-internet" ] && ok "sur-déclaration VH : le tag reste celui du REGISTRE ($T)" \
                               || ko "le tag suit la DÉCLARATION : '$T' au lieu de posture:m-internet"

# Un refus de gouvernance ne doit produire AUCUN tag : pas de tag « par défaut »
# qui laisserait croire l'API gouvernée.
OUT=$(posture_json banking-demo comptes-lecture M external); RC=$?
if [ "$RC" -ne 0 ] && ! printf '%s' "$OUT" | grep -q '"tag"'; then
  ok "downgrade refusé : aucune valeur de tag n'est rendue"
else
  ko "un downgrade a produit une sortie exploitable comme tag (rc=$RC)"
fi

# ═══════════════════════════════════════════════════════════════════════════
echo "═══ B — le RÔLE hors ligne : sans gouvernance, la plateforme ne pose RIEN ═══"
if command -v ansible-playbook >/dev/null 2>&1; then
  OUT=$(ansible-playbook -i ansible/inventory.lab.ini ansible/test-tag-guards.yml 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'TAG_NON_ARBITRE'; then
    ok "sans posture arbitrée : aucun tag posé, et le journal le DIT (TAG_NON_ARBITRE)"
  else
    ko "mode non arbitré : rc=$RC, TAG_NON_ARBITRE absent du journal"
  fi
  # Le NOM de la tâche d'écriture contient « PUT /apis » et Ansible affiche le
  # nom des tâches SAUTÉES : un grep du journal sur ce motif serait donc vert
  # quoi qu'il arrive (piège payé ici même). Ce qui distingue « sautée » de
  # « jouée », c'est le récapitulatif — l'id d'API du play est bidon, la
  # moindre écriture réellement tentée y laisserait un changed ou un failed.
  if printf '%s' "$OUT" | grep -qE 'changed=0 +unreachable=0 +failed=0'; then
    ok "aucune écriture tentée sans gouvernance (récapitulatif : changed=0 failed=0)"
  else
    ko "une écriture a été tentée alors qu'aucune posture n'était arbitrée"
  fi
else
  skip "ansible-playbook absent — section B non jouée"
fi

# ═══════════════════════════════════════════════════════════════════════════
echo "═══ C — LE BOUT EN BOUT sur la wM 10.15 RÉELLE ═══"
wm(){ curl -s -m 30 -u "$WM_USER:$WM_PASS" -H 'Accept: application/json' "$@"; }
wait_gateway(){  # le lab recycle wM (~20 min) : une reprise n'est pas une panne
  local i c
  for i in $(seq 1 40); do
    c=$(curl -s -o /dev/null -m 8 -w '%{http_code}' -u "$WM_USER:$WM_PASS" "$WM_ADMIN/apis")
    [ "$c" = "200" ] && return 0
    sleep 10
  done
  return 1
}

LIVE=1
command -v ansible-playbook >/dev/null 2>&1 || LIVE=0
if [ "$LIVE" = "1" ] && ! wait_gateway; then LIVE=0; fi
if [ "$LIVE" != "1" ]; then
  skip "gateway réelle injoignable sur $WM_ADMIN (ou ansible absent) — sections C et D-live NON jouées"
else

API="p3tag-$(date +%s)"
W="$TMP/live"; mkdir -p "$W"

# Le contrat du PRODUCTEUR : un tag MÉTIER (référencé par son opération, comme
# apis/accounts-read.openapi.yaml) et un tag de posture FORGÉ qui le déclare
# plus anodin qu'il n'est. C'est toute la contre-épreuve du jalon, dans un
# fichier que le producteur maîtrise entièrement.
cat > "$W/contract.yaml" <<YML
openapi: 3.0.3
info: { title: $API, version: 1.0.0 }
tags:
  - name: comptes
    description: regroupement METIER du producteur
  - name: posture:m-internal
    description: TAG DE POSTURE FORGE par le producteur
servers: [ { url: "http://poc-token-echo:8080" } ]
paths:
  /ping:
    get:
      operationId: ping
      tags: [comptes]
      responses: { '200': { description: ok } }
YML
cat > "$W/manifest.yml" <<YML
---
apim_api:
  name: "$API"
  version: "1.0.0"
  contract: "$W/contract.yaml"
  team: ""
  classification: "VH"
  exposure: "external"
YML
# CELLULE PUBLIABLE, et c'est une contrainte de P7 (ADR-097) : depuis que le
# rôle vérifie la COUVERTURE du bouquet, une cellule `VH` est REFUSÉE à la
# publication (`mtls` n'est déclinable par aucune API sur ce produit — mesure
# P5) et une cellule `internet` aussi (`threat-protection` n'est portable par
# aucune policy — mesure P4). Ce harnais publiait en `VH/external` ; il publie
# désormais en `H/external`, ce qui ne change RIEN à ce qu'il prouve — la
# plateforme pose le tag et écrase celui que le contrat avait forgé — et le
# rend cohérent avec ce que la chaîne accepte réellement de déployer.
cat > "$W/registry.yaml" <<YML
apiVersion: governance.stoa.io/v1
kind: ClassificationRegistry
classifications:
  - {owner: $TEAM, tenant: $TEAM, api: $API, classification: H,  exposure: external}
YML
# banking-demo SANS approbateurs : approvers.yml sort en APPROVERS_EMPTY.
# CONTOURNEMENT ASSUMÉ ET NOMMÉ d'un défaut PRÉEXISTANT, hors P3 et mesuré le
# 2026-09-05 sur le produit réel : le PUT ENVELOPPÉ de approvers.yml y rend 400
# (« Both content stream and apiDefinition are empty ») et `owner` y est en
# LECTURE SEULE — la tâche avait été prouvée contre le MOCK (:8090), pas contre
# la 10.15. C'est la décision client n°2 du GOAL, pas un correctif de ce jalon.
cat > "$W/providers.yml" <<YML
---
providers:
  - team: $TEAM
    description: "harnais P3"
    repo: $TEAM/harness
    approvers: []
YML

api_tags(){  # les tags RELUS sur la gateway, un par ligne
  wm "$WM_ADMIN/apis/$1" | python3 -c '
import json,sys
a=json.load(sys.stdin)["apiResponse"]["api"]
for t in (a.get("apiDefinition") or {}).get("tags") or []: print(t.get("name",""))'
}
api_id(){
  wm "$WM_ADMIN/apis" | python3 -c '
import json,sys
for e in json.load(sys.stdin)["apiResponse"]:
    if e["api"]["apiName"]==sys.argv[1]: print(e["api"]["id"]); break' "$1"
}
drop_api(){
  local i; i=$(api_id "$1"); [ -n "$i" ] || return 0
  curl -s -o /dev/null -m 30 -u "$WM_USER:$WM_PASS" -X PUT "$WM_ADMIN/apis/$i/deactivate"
  curl -s -o /dev/null -m 30 -u "$WM_USER:$WM_PASS" -X DELETE "$WM_ADMIN/apis/$i"
}
publish(){  # publish <fichier-journal> ; rend le rc du playbook
  ansible-playbook -i ansible/inventory.lab.ini ansible/publish-api.yml \
    -e "apim_ss_manifest=$W/manifest.yml" -e "apim_ss_team=$TEAM" \
    -e "apim_pub_classification_source=$W/registry.yaml" \
    -e "apim_pub_labctl_bin=$LABCTL_BIN" \
    -e "apim_pub_providers_file=$W/providers.yml" > "$1" 2>&1
}
trap 'drop_api "$API" >/dev/null 2>&1; cleanup' EXIT

drop_api "$API"
publish "$W/run1.log"; RC=$?
if [ "$RC" -eq 0 ]; then ok "publication complète (rc=0)"; else ko "publication en échec (rc=$RC) — $(grep -m1 -A2 '^fatal' "$W/run1.log" | tr '\n' ' ')"; fi

AID=$(api_id "$API")
if [ -z "$AID" ]; then
  ko "l'API n'existe pas sur la gateway — le reste de la section C est sans objet"
else
  TAGS=$(api_tags "$AID")
  printf '%s\n' "$TAGS" | grep -qx 'posture:h-external' \
    && ok "LA PORTE : l'API porte le tag de la posture GOUVERNÉE (posture:h-external)" \
    || ko "tag de posture absent — relu : $(printf '%s' "$TAGS" | tr '\n' ' ')"
  printf '%s\n' "$TAGS" | grep -qx 'posture:m-internal' \
    && ko "CONTRE-ÉPREUVE ÉCHOUÉE : le tag FORGÉ par le contrat a survécu" \
    || ok "contre-épreuve : le tag de posture FORGÉ par le contrat a été écrasé"
  [ "$(printf '%s\n' "$TAGS" | grep -c '^posture:')" = "1" ] \
    && ok "un SEUL tag dans l'espace de noms de la plateforme" \
    || ko "plusieurs tags réservés coexistent : $(printf '%s' "$TAGS" | tr '\n' ' ')"
  printf '%s\n' "$TAGS" | grep -qx 'comptes' \
    && ok "le tag MÉTIER du producteur est préservé (opération OpenAPI non orpheline)" \
    || ko "le tag métier 'comptes' a été détruit — régression fonctionnelle"

  # La POSITION des deux passes, mesurée dans le JOURNAL et non relue dans le
  # fichier : la pose précède l'activation (une API non tagable n'est jamais
  # mise en service) et la relecture est le DERNIER mot du rôle.
  L_POSE=$(grep -n 'TAG_CONFIRMED (pose)'             "$W/run1.log" | head -1 | cut -d: -f1)
  L_ACT=$(grep -n  'Activate : PUT /activate'          "$W/run1.log" | head -1 | cut -d: -f1)
  L_FIN=$(grep -n  'TAG_CONFIRMED (relecture finale)'  "$W/run1.log" | head -1 | cut -d: -f1)
  L_TEAM=$(grep -n 'TEAM_CONFIRMED'                    "$W/run1.log" | head -1 | cut -d: -f1)
  { [ -n "$L_POSE" ] && [ -n "$L_ACT" ] && [ "$L_POSE" -lt "$L_ACT" ]; } \
    && ok "la POSE précède l'activation (rien n'est mis en service sans son tag)" \
    || ko "la pose n'est pas antérieure à l'activation (pose=$L_POSE activate=$L_ACT)"
  { [ -n "$L_FIN" ] && [ -n "$L_TEAM" ] && [ "$L_FIN" -gt "$L_TEAM" ]; } \
    && ok "la RELECTURE FINALE est postérieure aux dernières écritures du rôle" \
    || ko "la relecture finale n'est pas le dernier mot (finale=$L_FIN team=$L_TEAM)"

  # IDEMPOTENCE : un second passage ne doit pas réécrire.
  publish "$W/run2.log"; RC=$?
  [ "$RC" -eq 0 ] && ok "second passage idempotent (rc=0)" || ko "second passage rc=$RC"
  [ "$(api_tags "$AID" | sort | tr '\n' ' ')" = "$(printf 'comptes\nposture:h-external\n' | sort | tr '\n' ' ')" ] \
    && ok "les tags sont inchangés après le second passage" \
    || ko "les tags ont dérivé au second passage : $(api_tags "$AID" | tr '\n' ' ')"

  # CONTRE-ÉPREUVE MESURÉE PAR P0 : un ré-import de définition EFFACE le tag et
  # RÉTABLIT celui du contrat. Le rôle doit en sortir avec le bon tag — c'est la
  # raison d'être de la seconde passe.
  sed -i.bak 's/^  team: ""/  team: ""\n  update: true/' "$W/manifest.yml" && rm -f "$W/manifest.yml.bak"
  publish "$W/run3.log"; RC=$?
  [ "$RC" -eq 0 ] && ok "mise à jour du contrat : publication complète (rc=0)" \
                  || ko "mise à jour en échec (rc=$RC) — $(grep -m1 -A2 '^fatal' "$W/run3.log" | tr '\n' ' ')"
  TAGS=$(api_tags "$AID")
  printf '%s\n' "$TAGS" | grep -qx 'posture:h-external' \
    && ok "CONTRE-ÉPREUVE : le tag SURVIT à un ré-import de définition" \
    || ko "le ré-import a laissé l'API sans son tag : $(printf '%s' "$TAGS" | tr '\n' ' ')"
  printf '%s\n' "$TAGS" | grep -qx 'posture:m-internal' \
    && ko "le tag forgé est revenu par le ré-import et a survécu" \
    || ok "le tag forgé revenu par le ré-import a de nouveau été écrasé"
  grep -q 'TAG_CONFIRMED (relecture finale)' "$W/run3.log" \
    && ok "la relecture finale a bien été jouée sur le chemin de mise à jour" \
    || ko "aucune relecture finale sur le chemin de mise à jour"
fi

# ═══════════════════════════════════════════════════════════════════════════
echo "═══ D — les MUTATIONS : ce harnais sait-il rougir ? ═══"
# Chaque sabotage vise une COUTURE NEUVE de P3 et se juge sur un COMPORTEMENT
# (une publication réelle), jamais sur un grep de la ligne qu'on vient de
# retirer — ce serait circulaire. Le témoin est exigé VERT avant le sabotage.
# Le sabotage est décrit en PYTHON, pas en sed : les coutures visées sont des
# expressions Jinja pleines de guillemets, d'accolades et de tildes, et une
# expression sed les ré-échappe jusqu'à ne plus mordre — une mutation muette
# est pire qu'une mutation absente (elle affiche un vert). Le python reçoit le
# texte dans `s` et doit le rendre MODIFIÉ ; `cmp` le vérifie ensuite.
mutate(){  # mutate <label> <fichier> <python: transforme s> <témoin (0 = VERT)>
  local label="$1" file="$2" snippet="$3" fn="$4" bak
  bak="$TMP/$(basename "$file").orig"
  cp "$file" "$bak"
  if ! "$fn" >/dev/null 2>&1; then
    ko "MUTATION « $label » NON JOUÉE : le témoin n'est pas vert AVANT le sabotage"
    return
  fi
  MUT_FILE="$file" MUT_SNIPPET="$snippet" python3 - <<'PYEOF'
import os
p = os.environ["MUT_FILE"]
s = open(p, encoding="utf8").read()
exec(os.environ["MUT_SNIPPET"])          # noqa: S102 — harnais de mutation local
open(p, "w", encoding="utf8").write(s)
PYEOF
  if cmp -s "$file" "$bak"; then
    ko "MUTATION « $label » : le sabotage n'a rien changé au fichier"
  elif "$fn" >/dev/null 2>&1; then
    ko "MUTATION « $label » NON DÉTECTÉE : le harnais reste vert sans la couture"
  else
    ok "mutation « $label » détectée"
  fi
  cp "$bak" "$file"
  cmp -s "$file" "$bak" || ko "restauration de $file imparfaite"
}

# Témoin : une publication complète dont l'état FINAL est exactement conforme —
# le bon tag, seul dans son espace de noms, et le tag métier intact.
witness_live(){
  drop_api "$API" >/dev/null 2>&1
  publish "$W/mut.log" || return 1
  local aid; aid=$(api_id "$API"); [ -n "$aid" ] || return 1
  local t; t=$(api_tags "$aid")
  printf '%s\n' "$t" | grep -qx 'posture:h-external' || return 1
  [ "$(printf '%s\n' "$t" | grep -c '^posture:')" = "1" ] || return 1
  printf '%s\n' "$t" | grep -qx 'comptes' || return 1
  return 0
}

# Le manifeste porte encore update:true depuis la contre-épreuve — on le remet
# à l'état nominal pour que les mutations mesurent bien la POSE.
sed -i.bak '/^  update: true$/d' "$W/manifest.yml" && rm -f "$W/manifest.yml.bak"

# 1. La plateforme cesse de reprendre son espace de noms : le tag de posture
#    FORGÉ par le contrat survivrait À CÔTÉ du vrai — deux postures sur l'objet,
#    et rien ne dit laquelle fait foi.
mutate "le rôle ne retire plus les tags réservés du producteur" "$TAGFILE" \
  "s = s.replace(\"| rejectattr('name', 'match', '^' ~ (pub_posture.tag_prefix | regex_escape)) | list }}\", '| list }}', 1)" \
  witness_live

# 2. La pose écrase la LISTE ENTIÈRE : le tag de posture serait juste, et le
#    regroupement documentaire du producteur détruit au passage.
mutate "la pose écrase aussi les tags métier du producteur" "$TAGFILE" \
  "s = s.replace('pub_tag_desired: \"{{ pub_tag_kept + [pub_tag_desired_one] }}\"', 'pub_tag_desired: \"{{ [pub_tag_desired_one] }}\"', 1)" \
  witness_live

# 3. LE CŒUR DU JALON : le rôle REPREND le tag du demandeur au lieu de poser
#    celui de l'autorité. C'est exactement le comportement que P3 interdit, et
#    il doit être visible sur l'objet, pas seulement dans une intention.
mutate "le rôle reprend le tag écrit par le producteur" "$TAGFILE" \
  "s = s.replace('name: \"{{ pub_posture.tag }}\"', 'name: \"{{ (pub_tag_current | selectattr(\'name\', \'match\', \'^\' ~ (pub_posture.tag_prefix | regex_escape)) | map(attribute=\'name\') | list | first) | default(pub_posture.tag) }}\"', 1)" \
  witness_live

# 4. LA RELECTURE FINALE. Un sabotage nu ne prouverait RIEN ici, et il faut le
#    dire : sur le chemin de mise à jour, c'est la POSE qui répare déjà, et
#    aucun écrivain actuel du rôle n'efface le tag APRÈS elle. Retirer la
#    seconde passe laisserait donc le harnais vert — un vert vacant, du type que
#    P1 a trouvé en mesurant la couverture.
#
#    Ce que la seconde passe garde, c'est l'état FINAL contre une écriture
#    POSTÉRIEURE à la pose. On INJECTE donc cette écriture — une réécriture de
#    définition qui rétablit le tag du contrat, exactement le mécanisme mesuré
#    au spike D de P0 — et on mesure le rôle DEUX FOIS face à elle :
#      (a) avec la relecture finale : le rôle RE-CONVERGE — il repose le tag et
#          le relit, et l'API finit conforme (mesuré : la seconde passe RÉPARE,
#          elle ne se contente pas de constater ; c'est mieux qu'un refus, qui
#          laisserait l'objet dans l'état où l'effacement l'a mis) ;
#      (b) sans elle : le rôle passe VERT en laissant une API qui porte le tag
#          du producteur. C'est la différence que fait la couture.
ERASER='    - name: "INJECTION (harnais P3) : relire avant effacement"
      ansible.builtin.uri:
        url: "{{ apim_ss_api_base }}/apis/{{ apim_api_id }}"
      register: mut_erase_get
      changed_when: false
    - name: "INJECTION (harnais P3) : une écriture POSTÉRIEURE rétablit le tag du contrat"
      ansible.builtin.uri:
        url: "{{ apim_ss_api_base }}/apis/{{ apim_api_id }}"
        method: PUT
        body: >-
          {{ mut_erase_get.json.apiResponse.api | combine({"apiDefinition":
             mut_erase_get.json.apiResponse.api.apiDefinition
             | combine({"tags": [{"name": "posture:m-internal", "description": "effacement simule"}]})}) }}
        status_code: [200, 201]
'
MAIN_BAK="$TMP/main.yml.orig"; cp "$MAINFILE" "$MAIN_BAK"
MUT_MAIN="$MAINFILE" MUT_ERASER="$ERASER" python3 - <<'PYEOF'
import os
p = os.environ["MUT_MAIN"]
s = open(p, encoding="utf8").read()
anchor = '    # ===== 5. Tag de posture — RELECTURE'
s = s.replace(anchor, os.environ["MUT_ERASER"] + "\n" + anchor, 1)
open(p, "w", encoding="utf8").write(s)
PYEOF
if cmp -s "$MAINFILE" "$MAIN_BAK"; then
  ko "INJECTION non appliquée — l'épreuve de la relecture finale n'a pas été jouée"
else
  drop_api "$API" >/dev/null 2>&1
  publish "$W/mut4a.log"; RC=$?
  AID2=$(api_id "$API")
  if [ "$RC" -eq 0 ] && [ -n "$AID2" ] && api_tags "$AID2" | grep -qx 'posture:h-external' \
     && grep -q 'TAG_CONFIRMED (relecture finale)' "$W/mut4a.log"; then
    ok "effacement POSTÉRIEUR à la pose : la relecture finale RE-CONVERGE et le prouve"
  else
    ko "un effacement postérieur à la pose n'a pas été rattrapé (rc=$RC, tags=$(api_tags "$AID2" | tr '\n' ' '))"
  fi

  # (b) la même injection, mais sans la seconde passe : le rôle doit alors
  #     passer vert EN LAISSANT le tag du producteur — c'est la démonstration
  #     que la couture porte quelque chose.
  MUT_MAIN="$MAINFILE" python3 - <<'PYEOF'
import os
p = os.environ["MUT_MAIN"]
s = open(p, encoding="utf8").read()
needle = '      ansible.builtin.import_tasks: tag.yml'
i = s.rindex(needle)
s = s[:i] + '      ansible.builtin.debug: { msg: "relecture finale retiree (mutation)" }' + s[i+len(needle):]
open(p, "w", encoding="utf8").write(s)
PYEOF
  drop_api "$API" >/dev/null 2>&1
  publish "$W/mut4b.log"; RC=$?
  AID2=$(api_id "$API")
  if [ "$RC" -eq 0 ] && [ -n "$AID2" ] && api_tags "$AID2" | grep -qx 'posture:m-internal'; then
    ok "sans la relecture finale : le rôle passe VERT en laissant le tag du PRODUCTEUR"
  else
    ko "mutation « relecture finale retirée » non concluante (rc=$RC, tags=$(api_tags "$AID2" | tr '\n' ' '))"
  fi
fi
cp "$MAIN_BAK" "$MAINFILE"
cmp -s "$MAINFILE" "$MAIN_BAK" || ko "restauration de $MAINFILE imparfaite"
drop_api "$API" >/dev/null 2>&1
fi

# ═══════════════════════════════════════════════════════════════════════════
echo
printf '  %s ✅ / %s ❌\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
