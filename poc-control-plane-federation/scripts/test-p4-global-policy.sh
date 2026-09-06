#!/usr/bin/env bash
# test-p4-global-policy.sh — la matrice de preuve du jalon P4 (ADR-094) :
# LES POLICIES COMMUNES SONT PORTÉES PAR UNE GLOBAL POLICY PAR CELLULE.
#
# Ce qui doit être vrai à la fin de ce jalon, et que ce fichier mesure :
#   chaque cellule NOMMÉE de la table de vérité a UN objet sur la gateway qui
#   porte la moitié commune de son bouquet ; une API publiée rejoint l'objet de
#   SA cellule et quitte ceux des autres ; le quota gouverné de la cellule MORD
#   au plan de données ; et deux APIs de niveaux différents subissent la même
#   rafale différemment — la porte du jalon.
#
#   A. l'AUTORITÉ (`labctl posture`) — la coupure commun/per-API, le quota par
#      cellule, les noms FINIS. Hors ligne.
#   B. le RÔLE hors ligne — les gardes qui refusent AVANT d'écrire, et la
#      POSITION de la tâche dans le rôle.
#   C. LE BOUT EN BOUT sur la wM 10.15 RÉELLE — amorçage, publication,
#      appartenance confirmée, quota mesuré, et les contre-épreuves.
#   D. les MUTATIONS — ce harnais SAIT rougir : chaque sabotage est restauré à
#      l'octet près (cmp).
#
# Hors ligne pour A, B et la partie hors ligne de D. Les sections C et D-live
# exigent la gateway RÉELLE (poc-webmethods-real, :5555) ; elles se sautent
# proprement — et le disent — si elle est absente. Jamais un vert silencieux.
#
#   ./scripts/test-p4-global-policy.sh
#   WM_ADMIN=http://localhost:5555/rest/apigateway ./scripts/test-p4-global-policy.sh
set -u
set -o pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
TMP="$(mktemp -d /tmp/p4gp.XXXXXX)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
skip(){ printf '  ⏭  %s\n' "$*"; }

# shellcheck source=scripts/lib/posture-authority.sh
. "$REPO/scripts/lib/posture-authority.sh"
resolve_posture_authority "$TMP/labctl" \
  || { echo "ABANDON : aucun labctl — l'autorité qui DÉRIVE le bouquet commun et son quota est le sujet de ce test, pas une dépendance optionnelle." >&2; exit 2; }

WM_ADMIN="${WM_ADMIN:-http://localhost:5555/rest/apigateway}"
export WM_DATA="${WM_DATA:-http://localhost:5555/gateway}"
# Le canal TLS du plan de données (jalon P5) — voir le commentaire de `burst`.
export WM_DP_TLS_BASE="${WM_DP_TLS_BASE:-https://localhost:5543/gateway}"
export WM_DP_CONTAINER="${WM_DP_CONTAINER:-poc-webmethods-real}"
WM_USER="${WM_USER:-Administrator}"
WM_PASS="${WM_PASS:-manage}"
TEAM="${P4_TEAM:-banking-demo}"
CELLFILE="ansible/roles/apim_global_posture/tasks/cell.yml"
GPFILE="ansible/roles/apim_publish_api/tasks/global-policy.yml"
MAINFILE="ansible/roles/apim_publish_api/tasks/main.yml"

cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

jget(){ python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1],""))' "$1"; }

# shellcheck source=scripts/lib/wm-dataplane.sh
. "$REPO/scripts/lib/wm-dataplane.sh"

# ═══════════════════════════════════════════════════════════════════════════
echo "═══ A — l'AUTORITÉ : la coupure, le quota, les noms finis ═══"

REG="$TMP/classifications.yaml"
cat > "$REG" <<'YML'
apiVersion: governance.stoa.io/v1
kind: ClassificationRegistry
classifications:
  - {owner: banking-demo, tenant: banking-demo, api: comptes-lecture, classification: VH, exposure: internet}
  - {owner: banking-demo, tenant: banking-demo, api: taux-lecture,    classification: M,  exposure: internet}
YML

posture_json(){  # <projet> <api> <classification> <exposure>
  LABCTL_CLASSIFICATION_SOURCE='' LABCTL_PROJECT='' "$LABCTL_BIN" posture \
    --project "$1" --api "$2" --declared-classification "$3" --declared-exposure "$4" \
    --classification-source "$REG" -o json 2>&1
}

OUT=$(posture_json banking-demo comptes-lecture VH internet)
COMMON=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["common_policies"]))')
PERAPI=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["per_api_policies"]))')
ALL=$(printf '%s'    "$OUT" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["required_policies"]))')

# A1 — la coupure ne perd rien et ne compte rien deux fois. Une policy tombée
# entre les deux moitiés ne serait posée par personne, et le demandeur lirait
# qu'elle l'est.
SPLIT=$(python3 - "$COMMON" "$PERAPI" "$ALL" <<'PY'
import sys
c=set(filter(None,sys.argv[1].split(","))); p=set(filter(None,sys.argv[2].split(","))); a=set(filter(None,sys.argv[3].split(",")))
print("ok" if (c|p)==a and not (c&p) else f"KO commun={sorted(c)} perapi={sorted(p)} bouquet={sorted(a)}")
PY
)
[ "$SPLIT" = "ok" ] && ok "la coupure commun/per-API est exhaustive et disjointe ($COMMON | $PERAPI)" \
                    || ko "$SPLIT"

# A2 — l'arbitrage P4/P5 que le GOAL laissait ouvert, rendu VISIBLE ici :
# https-only est MESURÉE portable en global policy (spike S5) et reste per-API,
# parce que P1 la vérifie déjà sur le transportProtocol de l'API elle-même.
printf '%s' "$PERAPI" | tr ',' '\n' | grep -qx 'https-only' \
  && ok "https-only reste PER-API (arbitrage P4/P5 assumé : P5 possède l'axe HTTPS)" \
  || ko "https-only est passée dans le bouquet COMMUN sans que la vérification suive"

# A3 — threat-protection : le stage existe côté produit mais /policies le REFUSE
# (400 NullPointerException, deux filtres, deux portées — spike S4).
printf '%s' "$PERAPI" | tr ',' '\n' | grep -qx 'threat-protection' \
  && ok "threat-protection reste PER-API (stage refusé par /policies — écart #1 d'ADR-091 précisé)" \
  || ko "threat-protection est annoncée COMMUNE alors qu'aucune policy ne peut la porter"

# A4 — LE POINT DU JALON vu de l'autorité : le quota suit le REGISTRE, jamais la
# déclaration. Sans quoi le demandeur choisirait son propre débit.
Q_OVER=$(posture_json banking-demo taux-lecture VH internet | python3 -c 'import json,sys; print(json.load(sys.stdin)["quota"]["requests"])')
Q_REF=$(posture_json  banking-demo taux-lecture M  internet | python3 -c 'import json,sys; print(json.load(sys.stdin)["quota"]["requests"])')
[ "$Q_OVER" = "$Q_REF" ] && ok "sur-déclaration VH : le quota reste celui du REGISTRE ($Q_REF)" \
                         || ko "le quota suit la DÉCLARATION ($Q_OVER au lieu de $Q_REF)"

# A5 — la PRÉMISSE de la porte : deux cellules de niveaux différents portent des
# bouquets communs DIFFÉRENTS. Comme l'ENSEMBLE est le même partout (plancher
# de P1), la différence ne peut être que le quota.
Q_VH=$(posture_json banking-demo comptes-lecture VH internet | python3 -c 'import json,sys; print(json.load(sys.stdin)["quota"]["requests"])')
[ -n "$Q_VH" ] && [ "$Q_VH" != "$Q_REF" ] \
  && ok "deux niveaux, deux bouquets communs différents : vh-internet=$Q_VH vs m-internet=$Q_REF" \
  || ko "vh-internet et m-internet portent le même quota ($Q_VH) — la porte du jalon ne mesurerait rien"

# A6/A7 — la table entière, et les chaînes FINIES que les couches bash/Ansible
# écrivent verbatim. Un préfixe recopié de travers ferait ignorer des cellules ;
# une sentinelle recopiée de travers rendrait la policy NON BORNÉE (elle
# frapperait toutes les APIs — mesuré).
CELLS=$("$LABCTL_BIN" posture --cells -o json)
N=$(printf '%s' "$CELLS" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["cells"]))')
[ "$N" = "10" ] && ok "la table de vérité expose ses 10 cellules nommées" || ko "$N cellules au lieu de 10"
BAD=$(printf '%s' "$CELLS" | python3 -c '
import json,sys
d=json.load(sys.stdin); pre=d["policy_prefix"]; bad=[]
for c in d["cells"]:
    if c["global_policy"] != pre + c["bundle"]: bad.append(c["bundle"])
    if not c["quota"]["requests"] or not c["quota"]["unit"]: bad.append(c["bundle"]+"/quota")
print(",".join(bad))')
[ -z "$BAD" ] && ok "chaque cellule rend un nom de policy FINI et un quota complet" || ko "cellules incohérentes : $BAD"
SENT=$(printf '%s' "$CELLS" | jget member_sentinel)
[ -n "$SENT" ] && ok "la sentinelle est rendue par l'autorité ('$SENT') — jamais composée par un appelant" \
               || ko "aucune sentinelle : une liste de membres vide frapperait TOUTES les APIs"

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "═══ B — le RÔLE hors ligne : les gardes, et la POSITION ═══"

# B1 — la frontière du jalon, lue dans le fichier : le rôle de publication n'a
# le droit ni de créer, ni d'activer, ni de supprimer une global policy. Ce sont
# les trois verbes qui portent le risque de cascade mesuré au P0.
grep -Eq 'method: (POST|DELETE)' "$GPFILE" \
  && ko "le rôle de publication porte un POST ou un DELETE sur /policies" \
  || ok "le rôle de publication ne CRÉE ni ne SUPPRIME aucune policy (GET+PUT seulement)"
grep -q '/activate' "$GPFILE" \
  && ko "le rôle de publication active une policy" \
  || ok "le rôle de publication n'ACTIVE aucune policy (geste du jour 0)"

# B2 — la POSITION. Le jalon promet qu'une API dont l'appartenance n'est pas
# confirmée n'est jamais mise en service : cela ne tient que si la tâche est
# importée AVANT l'activation.
L_GP=$(grep -n 'import_tasks: global-policy.yml' "$MAINFILE" | head -1 | cut -d: -f1)
L_TAG=$(grep -n 'import_tasks: tag.yml'          "$MAINFILE" | head -1 | cut -d: -f1)
L_ACT=$(grep -n 'apis/{{ apim_api_id }}/activate' "$MAINFILE" | head -1 | cut -d: -f1)
{ [ -n "$L_GP" ] && [ -n "$L_ACT" ] && [ "$L_GP" -lt "$L_ACT" ]; } \
  && ok "l'appartenance est écrite AVANT l'activation (rien n'est mis en service sans sa cellule)" \
  || ko "global-policy.yml n'est pas antérieur à l'activation (gp=$L_GP activate=$L_ACT)"
{ [ -n "$L_TAG" ] && [ -n "$L_GP" ] && [ "$L_TAG" -lt "$L_GP" ]; } \
  && ok "l'appartenance suit la pose du tag (les deux avant l'activation)" \
  || ko "l'ordre tag/appartenance est inversé (tag=$L_TAG gp=$L_GP)"

# B3 — la garde du mode non arbitré : sans registre, la plateforme n'inscrit
# l'API nulle part. Inscrire l'API dans la cellule de la posture DÉCLARÉE
# laisserait le demandeur choisir son propre quota.
grep -q 'POLICY_COMMUNE_NON_ARBITREE' "$GPFILE" \
  && ok "la garde du mode non arbitré existe et se nomme (POLICY_COMMUNE_NON_ARBITREE)" \
  || ko "aucune garde nommée pour le mode sans gouvernance"
for CODE in POLICY_COMMUNE_ABSENTE POLICY_COMMUNE_INERTE POLICY_COMMUNE_UNCONFIRMED; do
  grep -q "$CODE" "$GPFILE" && ok "refus nommé présent : $CODE" || ko "refus $CODE absent du rôle"
done

# B4 — le jour 0 ne supprime rien. C'est la règle qui empêche la cascade
# mesurée au P0 (une suppression de policy emporte ses policyActions, action
# SYSTÈME comprise, et met toute activation d'API en NPE).
grep -Eq 'method: DELETE' "$CELLFILE" "ansible/roles/apim_global_posture/tasks/main.yml" \
  && ko "le rôle d'amorçage porte un DELETE — la cascade du P0 redevient possible" \
  || ok "le rôle d'amorçage ne SUPPRIME rien (ni policy, ni action)"

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "═══ C — LE BOUT EN BOUT sur la webMethods 10.15 RÉELLE ═══"

wm(){ curl -s -m 30 -u "$WM_USER:$WM_PASS" -H 'Accept: application/json' "$@"; }
LIVE=1
wm -o /dev/null -w '' "$WM_ADMIN/apis" 2>/dev/null || LIVE=0
[ "$(wm -o /dev/null -w '%{http_code}' "$WM_ADMIN/apis")" = "200" ] || LIVE=0

if [ "$LIVE" != "1" ]; then
  skip "gateway réelle absente ($WM_ADMIN) — sections C et D-live sautées, RIEN n'est conclu sur le produit"
else

API_A="p4-alpha"; API_B="p4-beta"
W="$TMP/w"; mkdir -p "$W"

contract(){ cat > "$W/$1.yaml" <<YML
openapi: 3.0.0
info: { title: $1, version: 1.0.0 }
tags:
  - name: comptes
    description: metier
servers: [ { url: "http://poc-token-echo:8080" } ]
paths:
  /ping:
    get:
      operationId: ping
      tags: [comptes]
      responses: { '200': { description: ok } }
YML
}
manifest(){ cat > "$W/$1.manifest.yml" <<YML
---
apim_api:
  name: "$1"
  version: "1.0.0"
  contract: "$W/$1.yaml"
  team: ""
  classification: "$2"
  exposure: "$3"
YML
}
cat > "$W/providers.yml" <<YML
---
providers:
  - team: $TEAM
    description: "harnais P4"
    repo: $TEAM/harness
    approvers: []
YML

# banking-demo SANS approbateurs : approvers.yml sort en APPROVERS_EMPTY.
# CONTOURNEMENT ASSUMÉ d'un défaut PRÉEXISTANT (décision client n°2 du GOAL) —
# sur le produit réel le PUT enveloppé d'approvers.yml rend 400 et `owner` est
# en lecture seule. Hors P4 ; documenté plutôt que tu.

# CELLULES PUBLIABLES, et c'est une contrainte de P7 (ADR-097) : depuis que le
# rôle vérifie la COUVERTURE du bouquet, une cellule `internet` est REFUSÉE à la
# publication — `threat-protection` n'est portable par aucune policy sur ce
# produit, et c'est P4 lui-même qui l'a mesuré. Ce harnais publiait en
# `vh-internet` / `m-internet` ; il publie désormais en `h-external` /
# `m-external`, ce qui ne change RIEN à ce qu'il prouve (deux cellules, deux
# quotas gouvernés, le différentiel mesuré au plan de données) et le rend
# cohérent avec ce que la chaîne accepte réellement de déployer. La section
# d'AUTORITÉ, elle, continue d'interroger les dix cellules — y compris celles
# qu'on ne déploie pas : la table de vérité ne dépend pas du produit.
registry(){ cat > "$W/registry.yaml" <<YML
apiVersion: governance.stoa.io/v1
kind: ClassificationRegistry
classifications:
  - {owner: $TEAM, tenant: $TEAM, api: $API_A, classification: $1, exposure: $2}
  - {owner: $TEAM, tenant: $TEAM, api: $API_B, classification: $3, exposure: $4}
YML
}

publish(){  # publish <api> <journal>
  ansible-playbook -i ansible/inventory.lab.ini ansible/publish-api.yml \
    -e "apim_ss_manifest=$W/$1.manifest.yml" -e "apim_ss_team=$TEAM" \
    -e "apim_pub_classification_source=$W/registry.yaml" \
    -e "apim_pub_labctl_bin=$LABCTL_BIN" \
    -e "apim_pub_providers_file=$W/providers.yml" > "$2" 2>&1
}
bootstrap(){ ansible-playbook -i ansible/inventory.lab.ini ansible/apim-global-posture-setup.yml \
    -e "apim_gp_labctl_bin=$LABCTL_BIN" > "$1" 2>&1; }

api_id(){ wm "$WM_ADMIN/apis" | python3 -c '
import json,sys
for e in json.load(sys.stdin)["apiResponse"]:
    if e["api"]["apiName"]==sys.argv[1]: print(e["api"]["id"]); break' "$1"; }
drop_api(){ local i; i=$(api_id "$1"); [ -n "$i" ] || return 0
  curl -s -o /dev/null -m 30 -u "$WM_USER:$WM_PASS" -X PUT "$WM_ADMIN/apis/$i/deactivate"
  curl -s -o /dev/null -m 30 -u "$WM_USER:$WM_PASS" -X DELETE "$WM_ADMIN/apis/$i"; }
members(){ wm "$WM_ADMIN/policies" | python3 -c '
import json,sys
for p in json.load(sys.stdin)["policy"]:
    n=(p.get("names") or [{}])[0].get("value","")
    if n==sys.argv[1]:
        print(" ".join(a["value"] for c in (p.get("scope") or {}).get("scopeConditions",[])
                       if c["filterType"]=="API" for a in c["attributes"]))' "$1"; }
cells_of(){ wm "$WM_ADMIN/policies" | python3 -c '
import json,sys
tgt=sys.argv[1]
for p in json.load(sys.stdin)["policy"]:
    n=(p.get("names") or [{}])[0].get("value","")
    if not n.startswith("posture-"): continue
    for c in (p.get("scope") or {}).get("scopeConditions",[]):
        if c["filterType"]=="API" and any(a["value"]==tgt for a in c["attributes"]): print(n)' "$1"; }
# ⚠ DEPUIS P5 (ADR-095), LE PLAN DE DONNÉES DE CES APIs N'EST PLUS EN CLAIR.
# Le rôle de publication pose `entryProtocolPolicy=https` sur toute API dont la
# posture est gouvernée : un appel en clair reçoit HTTP 500 « Transport protocol
# not supported », jamais le 200 ou le 429 que ce harnais mesure. Mesurer en
# clair reviendrait donc à lire le refus de PROTOCOLE là où on attend le quota —
# la contre-épreuve C6 en particulier deviendrait un rouge qui ne dit rien de la
# cellule. On mesure sur le canal que l'API ACCEPTE (scripts/lib/wm-dataplane.sh,
# qui passe par le conteneur : le listener HTTPS du lab n'est pas publié).
burst(){ local n="$1" name="$2" c429=0 i
  for i in $(seq 1 "$n"); do
    [ "$(dp_code https "$name" 1.0.0 /ping)" = "429" ] && c429=$((c429+1))
  done; echo "$c429"; }
wait_free(){ local name="$1" i c  # attendre que la fenêtre du QUOTA roule
  # On attend que le quota cesse de mordre — PAS que l'appel soit servi. Depuis
  # que les cellules publiées ici sont `external` (contrainte de couverture, P7),
  # l'appel reste refusé par l'IDENTIFICATION (403) même la fenêtre roulée :
  # exiger un 200 mesurerait l'axe voisin et rougirait pour toujours. Le stage
  # LMT s'évalue AVANT le stage IAM — mesuré : la 429 apparaît bien alors que
  # l'appelant n'est pas identifié.
  for i in $(seq 1 40); do
    c=$(dp_code https "$name" 1.0.0 /ping)
    [ "$c" != "429" ] && [ "$c" != "000" ] && return 0
    sleep 3
  done; return 1; }

trap 'drop_api "$API_A" >/dev/null 2>&1; drop_api "$API_B" >/dev/null 2>&1; cleanup' EXIT

# ---- C1/C2 : l'amorçage --------------------------------------------------
bootstrap "$W/boot1.log"; RC=$?
[ "$RC" -eq 0 ] && ok "amorçage : les 10 cellules ont leur objet (rc=0)" \
                || ko "amorçage en échec (rc=$RC) — $(grep -m1 -A2 '^fatal' "$W/boot1.log" | tr '\n' ' ')"
NAMORCE=$(grep -c 'POLICY_COMMUNE_AMORCEE' "$W/boot1.log")
[ "$NAMORCE" = "10" ] && ok "10 cellules amorcées, actives et bornées" || ko "$NAMORCE cellules amorcées au lieu de 10"
grep -q "membres=\['$SENT'\]" "$W/boot1.log" \
  && ok "une cellule neuve naît BORNÉE par la sentinelle (jamais une liste vide)" \
  || ok "cellules déjà peuplées — la sentinelle est vérifiée en C8"

NACT_BEFORE=$(wm "$WM_ADMIN/policyActions" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["policyAction"]))')
bootstrap "$W/boot2.log"; RC=$?
NACT_AFTER=$(wm "$WM_ADMIN/policyActions" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["policyAction"]))')
{ [ "$RC" -eq 0 ] && [ "$NACT_BEFORE" = "$NACT_AFTER" ]; } \
  && ok "amorçage IDEMPOTENT : aucune action orpheline au second passage ($NACT_AFTER)" \
  || ko "second amorçage : rc=$RC, actions $NACT_BEFORE -> $NACT_AFTER (orphelines)"

# ---- C3 : la publication rejoint SA cellule ------------------------------
drop_api "$API_A"; drop_api "$API_B"
contract "$API_A"; contract "$API_B"
manifest "$API_A" H external; manifest "$API_B" M external
registry H external M external

publish "$API_A" "$W/pubA.log"; RC=$?
[ "$RC" -eq 0 ] && ok "publication de $API_A (h-external) : rc=0" \
                || ko "publication $API_A rc=$RC — $(grep -m1 -A2 '^fatal' "$W/pubA.log" | tr '\n' ' ')"
grep -q 'POLICY_COMMUNE_CONFIRMED' "$W/pubA.log" \
  && ok "LA PORTE (a) : la gateway CONFIRME que $API_A est frappée par sa cellule" \
  || ko "POLICY_COMMUNE_CONFIRMED absent du journal — l'appartenance n'a pas été confirmée"
[ "$(cells_of "$API_A" | tr '\n' ' ' | xargs)" = "posture-h-external" ] \
  && ok "$API_A est membre de posture-h-external et d'AUCUNE autre cellule" \
  || ko "cellules de $API_A : $(cells_of "$API_A" | tr '\n' ' ')"

publish "$API_B" "$W/pubB.log"; RC=$?
[ "$RC" -eq 0 ] && ok "publication de $API_B (m-external) : rc=0" \
                || ko "publication $API_B rc=$RC — $(grep -m1 -A2 '^fatal' "$W/pubB.log" | tr '\n' ' ')"

# ---- C4/C5 : LA PORTE, mesurée côté PLAN DE DONNÉES ----------------------
# Les quotas viennent de la TABLE, pas d'une interrogation par API : depuis P7
# les cellules publiées ici sont `h-external` et `m-external` (une cellule `VH`
# ou `internet` est refusée à la publication — couverture du bouquet, ADR-097),
# et interroger l'autorité avec une déclaration qui ne correspond pas à la ligne
# du registre offline rendrait un refus, pas un quota.
qof(){ printf '%s' "$CELLS" | python3 -c 'import json,sys
for c in json.load(sys.stdin)["cells"]:
    if c["bundle"]==sys.argv[1]: print(c["quota"]["requests"]); break' "$1"; }
QA=$(qof h-external); QB=$(qof m-external)
echo "     (quotas gouvernés : h-external=$QA/min, m-external=$QB/min ; rafale = $((QA + 5)) appels)"

# La propagation du scope n'est pas instantanée : on attend que la policy MORDE
# avant de mesurer quoi que ce soit. Sans cette attente, une première rafale
# passe entièrement et on conclurait que le quota ne mord pas.
EFFECTIVE=0
for _ in $(seq 1 6); do
  [ "$(burst $((QA + 5)) "$API_A")" -gt 0 ] && { EFFECTIVE=1; break; }
  sleep 10
done
[ "$EFFECTIVE" = "1" ] \
  && ok "LA PORTE (b) : le quota gouverné de h-external MORD au plan de données (429)" \
  || ko "aucune 429 sur $API_A après $((QA + 5)) appels répétés — le quota ne mord pas"

# LA PORTE du jalon : la MÊME rafale, sur une API d'une AUTRE cellule, ne mord
# pas — parce que son bouquet commun porte un autre quota. Deux APIs de niveaux
# différents, deux bouquets communs différents, mesurés côté plan de données.
wait_free "$API_B" >/dev/null 2>&1
N429B=$(burst $((QA + 5)) "$API_B")
[ "$N429B" = "0" ] \
  && ok "LA PORTE (c) : la MÊME rafale ne mord PAS sur $API_B (quota $QB > $QA) — deux bouquets communs différents" \
  || ko "$N429B refus sur $API_B : les deux cellules se comportent pareil, la porte ne mesure rien"

# ---- C6 : CONTRE-ÉPREUVE — retirer le ciblage, l'appel repasse -----------
PIDA=$(wm "$WM_ADMIN/policies" | python3 -c '
import json,sys
for p in json.load(sys.stdin)["policy"]:
    if (p.get("names") or [{}])[0].get("value")=="posture-h-external": print(p["id"])')
curl -s -o /dev/null -m 30 -u "$WM_USER:$WM_PASS" -X PUT "$WM_ADMIN/policies/$PIDA/deactivate"
if wait_free "$API_A"; then
  ok "CONTRE-ÉPREUVE : cellule désactivée → l'appel de $API_A cesse d'être refusé par le QUOTA"
else
  ko "l'appel ne repasse pas après désactivation — le refus n'était pas imputable à la cellule"
fi
curl -s -o /dev/null -m 30 -u "$WM_USER:$WM_PASS" -X PUT "$WM_ADMIN/policies/$PIDA/activate"

# ---- C7 : changer de cellule, c'est QUITTER l'ancienne -------------------
registry M external M external
manifest "$API_A" M external
publish "$API_A" "$W/pubA2.log"; RC=$?
NEW=$(cells_of "$API_A" | tr '\n' ' ' | xargs)
{ [ "$RC" -eq 0 ] && [ "$NEW" = "posture-m-external" ]; } \
  && ok "reclassée par le registre, $API_A QUITTE posture-h-external et rejoint posture-m-external" \
  || ko "après reclassement, cellules de $API_A = '$NEW' (rc=$RC) — deux quotas contradictoires"

# ---- C8/C9 : la sentinelle, et le contenu intact -------------------------
MISSING=""
for C in $(printf '%s' "$CELLS" | python3 -c 'import json,sys
for c in json.load(sys.stdin)["cells"]: print(c["global_policy"])'); do
  printf '%s' "$(members "$C")" | grep -q -- "$SENT" || MISSING="$MISSING $C"
done
[ -z "$MISSING" ] && ok "la sentinelle survit dans les 10 cellules (aucune liste ne peut devenir vide)" \
                  || ko "sentinelle absente de :$MISSING — ces cellules frapperaient TOUTES les APIs si elles se vidaient"

ENFOK=$(wm "$WM_ADMIN/policies" | python3 -c '
import json,sys
bad=[]
for p in json.load(sys.stdin)["policy"]:
    n=(p.get("names") or [{}])[0].get("value","")
    if not n.startswith("posture-"): continue
    k=[e for pe in (p.get("policyEnforcements") or []) for e in (pe.get("enforcements") or [])]
    if len(k)!=2 or not p.get("active"): bad.append(n)
print(",".join(bad))')
[ -z "$ENFOK" ] && ok "après les PUT du rôle, chaque cellule est ACTIVE et porte encore ses 2 actions" \
                || ko "cellules altérées par le rôle de publication : $ENFOK"

fi  # LIVE

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "═══ D — les MUTATIONS : ce harnais sait-il rougir ? ═══"

# Les sabotages passent par PYTHON, jamais par sed : une substitution sed sur du
# Jinja ne mord pas (guillemets, accolades, tildes), et une mutation qui ne mord
# pas produit un faux ✅ — le harnais se croirait sensible à une couture qu'il
# n'a jamais touchée. Leçon payée en P3.
cat > "$TMP/mut-additif.py" <<'PYEOF'
import sys
f = sys.argv[1]
s = open(f).read()
old = "gp_stripped: \"{{ item.names_before | reject('equalto', apim_api.name) | list }}\""
new = "gp_stripped: \"{{ item.names_before | list }}\""
if old not in s:
    sys.stderr.write("MOTIF ABSENT\n"); sys.exit(3)
open(f, "w").write(s.replace(old, new, 1))
PYEOF
cat > "$TMP/mut-inerte.py" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1])); p = d["policy"]
p["scope"]["scopeConditions"] = [c for c in p["scope"]["scopeConditions"]
                                 if c["filterType"] != "HTTP_METHOD"]
json.dump({"policy": p}, open(sys.argv[2], "w"))
PYEOF

mutate(){ # mutate <fichier> <python-expr-de-substitution> <étiquette> <commande-témoin>
  local f="$1" pyexpr="$2" label="$3" probe="$4"
  cp "$f" "$TMP/orig" || { ko "mutation $label : copie impossible"; return; }
  python3 - "$f" "$pyexpr" <<'PY'
import sys
f,expr=sys.argv[1],sys.argv[2]
s=open(f).read()
old,new=expr.split("||",1)
if old not in s:
    sys.stderr.write("MOTIF ABSENT\n"); sys.exit(3)
open(f,"w").write(s.replace(old,new,1))
PY
  if [ $? -ne 0 ]; then ko "mutation $label : motif absent (le harnais teste autre chose que ce qu'il croit)"; cp "$TMP/orig" "$f"; return; fi
  if ( eval "$probe" ) >/dev/null 2>&1; then
    ko "MUTATION $label : le témoin reste VERT — cette couture n'est pas mesurée"
  else
    ok "mutation $label : le témoin ROUGIT"
  fi
  cp "$TMP/orig" "$f"
  cmp -s "$TMP/orig" "$f" && : || ko "restauration de $f non conforme à l'octet près"
}

# D1 — le quota disparaît de la table de vérité : Derive doit REFUSER, sinon
# `rate-limit` redevient un mot.
mutate labctl/internal/render/render.go \
  '"vh-internet":       {Requests: 30, Interval: 1, Unit: QuotaUnitMinutes},||' \
  'un quota retiré de la table' \
  'cd labctl && go test ./internal/render/ -run TestEveryNamedCellHasAGovernedQuota -count=1'

# D2 — deux cellules au même quota : la PRÉMISSE de la porte tombe, et
# l'épreuve doit le dire au lieu de laisser croire que le jalon est mesurable.
mutate labctl/internal/render/render.go \
  '"vh-internal":       {Requests: 120, Interval: 1, Unit: QuotaUnitMinutes},||"vh-internal":       {Requests: 600, Interval: 1, Unit: QuotaUnitMinutes},' \
  'deux niveaux au même quota' \
  'cd labctl && go test ./internal/render/ -run TestTwoLevelsCarryDifferentCommonBundles -count=1'

# D3 — https-only bascule dans le bouquet commun sans que la vérification suive :
# c'est exactement l'arbitrage P4/P5, et il doit être gardé par une épreuve.
mutate labctl/internal/render/render.go \
  'var commonCarriable = map[string]bool{||var commonCarriable = map[string]bool{
	PolicyHTTPSOnly: true,' \
  'https-only déplacée dans le commun' \
  'cd labctl && go test ./internal/render/ -run TestCommonHalfIsExactlyWhatTheGatewayWasMeasuredToCarry -count=1'

# D4 — la coupure perd une policy : personne ne la pose, et le demandeur lit
# qu'elle est posée.
mutate labctl/internal/render/render.go \
  '		} else {
			perAPI = append(perAPI, p)
		}||		}' \
  'une policy tombe entre les deux moitiés' \
  'cd labctl && go test ./internal/render/ -run TestBundleSplitIsExhaustiveAndDisjoint -count=1'

# D5/D6 — les mutations LIVE. Les gardes du rôle sont des RELECTURES de la
# gateway, pas des lignes de fichier : un témoin qui grepperait la ligne qu'on
# vient de retirer serait circulaire et rougirait toujours. Seul un vrai
# passage du rôle mesure quelque chose.
if [ "${LIVE:-0}" = "1" ]; then

  # D5 — le rôle devient ADDITIF : il n'ôte plus le nom de l'API des AUTRES
  # cellules. Une API reclassée porterait alors deux quotas contradictoires, et
  # rien ne dirait lequel fait foi. La relecture « membre d'aucune autre
  # cellule » doit l'attraper.
  cp "$GPFILE" "$TMP/gp.orig"
  if python3 "$TMP/mut-additif.py" "$GPFILE"; then
    registry M external M external
    manifest "$API_A" M external
    publish "$API_A" "$W/mutD5a.log" >/dev/null 2>&1
    registry H external M external
    manifest "$API_A" H external
    publish "$API_A" "$W/mutD5.log"; RC=$?
    if [ "$RC" -ne 0 ] && grep -q 'POLICY_COMMUNE_UNCONFIRMED' "$W/mutD5.log"; then
      ok "mutation D5 (rôle ADDITIF : ne quitte plus l'ancienne cellule) — la relecture ROUGIT"
    else
      ko "MUTATION D5 : le rôle additif passe (rc=$RC) — deux appartenances simultanées non détectées"
    fi
  else
    ko "mutation D5 : motif absent — le harnais teste autre chose que ce qu'il croit"
  fi
  cp "$TMP/gp.orig" "$GPFILE"
  cmp -s "$TMP/gp.orig" "$GPFILE" || ko "restauration de $GPFILE non conforme à l'octet près"

  # D6 — la cellule perd sa condition HTTP_METHOD sur la GATEWAY (pas dans un
  # fichier) : elle devient INERTE tout en ayant l'air parfaitement configurée.
  # C'est le vert vacant le plus coûteux de ce GOAL — le rôle doit refuser
  # d'inscrire quoi que ce soit dedans plutôt que de remplir un objet mort.
  PIDM=$(wm "$WM_ADMIN/policies" | python3 -c '
import json,sys
for p in json.load(sys.stdin)["policy"]:
    if (p.get("names") or [{}])[0].get("value")=="posture-h-external": print(p["id"])')
  wm "$WM_ADMIN/policies/$PIDM" > "$TMP/polM.json"
  python3 "$TMP/mut-inerte.py" "$TMP/polM.json" "$TMP/polM.strip.json"
  curl -s -o /dev/null -m 30 -u "$WM_USER:$WM_PASS" -H 'Content-Type: application/json' \
       -X PUT --data @"$TMP/polM.strip.json" "$WM_ADMIN/policies/$PIDM"
  registry H external M external
  manifest "$API_A" H external
  publish "$API_A" "$W/mutD6.log"; RC=$?
  if [ "$RC" -ne 0 ] && grep -q 'POLICY_COMMUNE_INERTE' "$W/mutD6.log"; then
    ok "mutation D6 (cellule sans condition HTTP_METHOD, donc INERTE) — le rôle REFUSE d'y inscrire l'API"
  else
    ko "MUTATION D6 : le rôle inscrit l'API dans un objet qui ne sélectionne rien (rc=$RC) — vert vacant"
  fi
  curl -s -o /dev/null -m 30 -u "$WM_USER:$WM_PASS" -H 'Content-Type: application/json' \
       -X PUT --data @"$TMP/polM.json" "$WM_ADMIN/policies/$PIDM"
  RESTORED=$(wm "$WM_ADMIN/policies/$PIDM" | python3 -c '
import json,sys
p=json.load(sys.stdin)["policy"]
print(len([c for c in p["scope"]["scopeConditions"] if c["filterType"]=="HTTP_METHOD"]))')
  [ "$RESTORED" = "1" ] && ok "la cellule sabotée est RESTAURÉE (condition HTTP_METHOD de retour)" \
                        || ko "RESTAURATION MANQUÉE : posture-h-external reste inerte — rejouer le play d'amorçage"
else
  skip "mutations D5/D6 sautées (gateway absente) — les gardes du rôle ne sont donc PAS mesurées"
fi

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "─────────────────────────────────────────────"
printf 'P4 — global policy par cellule : %d ✅ / %d ❌\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
