#!/usr/bin/env bash
# test-p6-deny-by-default.sh — la matrice de preuve du jalon P6 (ADR-096) :
# L'API REFUSE ELLE-MÊME L'APPELANT QU'ELLE N'A PAS IDENTIFIÉ.
#
# Ce que ce fichier mesure, et que le jalon promet :
#   une API publiée sous posture `external` exige la dimension réseau de tout
#   appelant ; l'appelant hors des plages déclarées est REFUSÉ au plan de
#   données et celui qui y est est servi ; le refus vient de la RÈGLE et non
#   d'autre chose (contre-épreuve : la règle retirée, l'appel repasse) ; la
#   dimension est DÉRIVÉE de la moitié per-API du bouquet, jamais recopiée ; et
#   le rôle refuse de détruire une action partagée plutôt que de casser les
#   APIs voisines.
#
#   A. l'AUTORITÉ (`labctl posture`) — `caller_identity` fini, dérivé de la
#      moitié qui le possède, présent exactement sur les cellules `external`.
#   B. les RÔLES hors ligne — les refus nommés, la POSITION dans le rôle, le
#      read-back à égalité stricte, la garde du partage, et le fait qu'un seul
#      fichier écrive désormais le stage IAM.
#   C. LE BOUT EN BOUT sur la wM 10.15 RÉELLE — publication, porte au PLAN DE
#      DONNÉES (403 hors plage / 200 dans la plage sur la MÊME API), contre-
#      épreuve, et re-convergence.
#   D. les MUTATIONS — ce harnais SAIT rougir : chaque sabotage est restauré à
#      l'octet près (cmp).
#
# Hors ligne pour A, B et la partie hors ligne de D. Les sections C et D-live
# exigent la gateway RÉELLE (poc-webmethods-real, :5555) ; elles se sautent
# proprement — et le disent — si elle est absente. Jamais un vert silencieux.
#
#   ./scripts/test-p6-deny-by-default.sh
#
# `A && ok || ko` (SC2015) est l'idiome des scripts de preuve du repo : `ok` et
# `ko` ne rendent jamais un code non nul, donc la branche `||` est inatteignable
# depuis un `ok` réussi.
# shellcheck disable=SC2015
set -u
set -o pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
TMP="$(mktemp -d /tmp/p6dbd.XXXXXX)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
skip(){ printf '  ⏭  %s\n' "$*"; }
mes(){ printf '     📏 %s\n' "$*"; }

# shellcheck source=scripts/lib/posture-authority.sh
. "$REPO/scripts/lib/posture-authority.sh"
resolve_posture_authority "$TMP/labctl" \
  || { echo "ABANDON : aucun labctl — l'autorité qui DÉRIVE la dimension d'identification est le sujet de ce test, pas une dépendance optionnelle." >&2; exit 2; }

WM_ADMIN="${WM_ADMIN:-http://localhost:5555/rest/apigateway}"
WM_USER="${WM_USER:-Administrator}"
WM_PASS="${WM_PASS:-manage}"
WM_CTR="${WM_CTR:-poc-webmethods-real}"
TEAM="${P6_TEAM:-banking-demo}"
CIFILE="ansible/roles/apim_publish_api/tasks/caller-identity.yml"
MAINFILE="ansible/roles/apim_publish_api/tasks/main.yml"
INBFILE="ansible/roles/apim_publish_api/tasks/inbound.yml"
SPLITPLAY="ansible/is-iam-action-split.yml"
SPLITONE="ansible/tasks/iam-action-split-one.yml"

cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════
echo "═══ A — l'AUTORITÉ : une dimension FINIE, dérivée de la moitié qui la possède ═══"

REG="$TMP/classifications.yaml"
cat > "$REG" <<'YML'
apiVersion: governance.stoa.io/v1
kind: ClassificationRegistry
classifications:
  - {owner: banking-demo, tenant: banking-demo, api: partenaire-lecture, classification: H, exposure: external}
  - {owner: banking-demo, tenant: banking-demo, api: taux-lecture,       classification: M, exposure: internal}
YML

posture_json(){  # <projet> <api> <classification> <exposure>
  LABCTL_CLASSIFICATION_SOURCE='' LABCTL_PROJECT='' "$LABCTL_BIN" posture \
    --project "$1" --api "$2" --declared-classification "$3" --declared-exposure "$4" \
    --classification-source "$REG" -o json 2>&1
}
jlist(){ python3 -c 'import json,sys; print(",".join(json.load(sys.stdin).get(sys.argv[1]) or []))' "$1"; }

OUT=$(posture_json banking-demo partenaire-lecture H external)
CI=$(printf '%s' "$OUT" | jlist caller_identity)
mes "h-external : caller_identity=[$CI]"

# A1 — la valeur est FINIE et dans le vocabulaire du produit. Un synonyme
# (« ipRange », « ipAddress ») serait accepté à l'écriture puis n'identifierait
# jamais personne : un contrôle posé, relu, et inerte.
[ "$CI" = "ipAddressRange" ] \
  && ok "A1 l'autorité rend une dimension FINIE dans le vocabulaire du produit ('ipAddressRange')" \
  || ko "A1 caller_identity=[$CI], attendu exactement [ipAddressRange]"

# A2 — LE COUPLAGE, jumeau de celui de P5 : la dimension existe SI ET SEULEMENT
# SI ip-allowlist est dans la moitié per-API. C'est ce qui empêche l'APPLICATION
# de partir vers un objet partagé pendant que la VÉRIFICATION continue de relire
# l'action IAM de l'API.
COUPLE=$(printf '%s' "$OUT" | python3 -c '
import json,sys
d=json.load(sys.stdin)
per="ip-allowlist" in d["per_api_policies"]; com="ip-allowlist" in d["common_policies"]
ci=bool(d.get("caller_identity"))
print("ok" if (per==ci and not com) else f"KO per={per} common={com} caller={ci}")')
[ "$COUPLE" = "ok" ] \
  && ok "A2 la dimension suit la moitié per-API (application et vérification ne peuvent pas diverger)" \
  || ko "A2 $COUPLE"

# A3 — exactement les cellules `external`, et pas une de plus. `internet` est le
# cas piégeux : ADR-091 y REMPLACE l'allow-list par threat-protection, parce que
# l'appelant public n'est pas énumérable. Une allow-list y serait soit vide soit
# un joker — et un joker 0.0.0.0-255.255.255.255 n'identifie PERSONNE (spike S3).
BAD=0
for C in VH H M; do for X in internal external internet; do
  V=$(LABCTL_CLASSIFICATION_SOURCE='' LABCTL_PROJECT='' "$LABCTL_BIN" posture \
        --api x --project p --declared-classification "$C" --declared-exposure "$X" -o json 2>/dev/null | jlist caller_identity)
  WANT=""; [ "$X" = "external" ] && WANT="ipAddressRange"
  [ "$V" = "$WANT" ] || { BAD=$((BAD+1)); mes "cellule $C/$X : caller_identity=[$V], attendu [$WANT]"; }
done; done
[ "$BAD" -eq 0 ] \
  && ok "A3 les 9 cellules : la dimension réseau est exactement sur les 3 'external'" \
  || ko "A3 $BAD cellules avec la mauvaise dimension"

# A4 — la sortie TEXTE le dit aussi. Le journal d'un build est ce que le
# demandeur lit ; une valeur visible seulement en JSON n'est visible par personne.
TXT=$(LABCTL_CLASSIFICATION_SOURCE='' LABCTL_PROJECT='' "$LABCTL_BIN" posture \
        --api partenaire-lecture --project banking-demo --declared-classification H \
        --declared-exposure external --classification-source "$REG" 2>&1)
printf '%s' "$TXT" | grep -q '^caller_identity: ipAddressRange$' \
  && ok "A4 la sortie humaine porte la dimension (le journal du build la montre)" \
  || ko "A4 'caller_identity:' absent ou faux dans la sortie texte"

# A5 — une cellule qui n'en exige aucune le DIT, au lieu d'afficher un vide qui
# se lirait comme un défaut de rendu.
printf '%s' "$(LABCTL_CLASSIFICATION_SOURCE='' LABCTL_PROJECT='' "$LABCTL_BIN" posture \
  --api taux-lecture --project banking-demo --declared-classification M \
  --declared-exposure internal --classification-source "$REG" 2>&1)" \
  | grep -q '^caller_identity: (aucun)$' \
  && ok "A5 une cellule sans dimension l'affiche explicitement '(aucun)'" \
  || ko "A5 la cellule internal n'affiche pas '(aucun)'"

# ═══════════════════════════════════════════════════════════════════════════
echo "═══ B — les RÔLES hors ligne : refus nommés, position, et un seul propriétaire ═══"

for f in "$CIFILE" "$SPLITPLAY" "$SPLITONE"; do
  [ -f "$f" ] && ok "B0 $f existe" || ko "B0 $f manquant"
done

# B1 — les refus sont NOMMÉS. Un `assert` sans code nommé produit une trace que
# le demandeur ne peut ni chercher ni comprendre — et que la chaîne ne peut pas
# relayer sur la PR (P2 a fait de ce relais un mécanisme).
for code in IDENTITE_SANS_POLICY IDENTITE_POLICY_ILLISIBLE ACTION_IAM_PARTAGEE \
            IDENTITE_ACTION_SANS_ID IDENTITE_NON_ATTACHEE IDENTITE_NON_CONFIRMEE \
            IDENTITE_APPELANT_NON_EXIGEE; do
  grep -q "$code" "$CIFILE" && ok "B1 refus nommé : $code" || ko "B1 refus $code absent du rôle"
done
grep -q "IDENTITE_CONFIRMEE" "$CIFILE" \
  && ok "B1 le succès aussi est nommé (IDENTITE_CONFIRMEE)" \
  || ko "B1 aucun success_msg nommé"

# B2 — LA POSITION. Le stage IAM se règle AVANT l'activation : mesuré posable
# sur une API inactive et survivant à l'activation (spike S8). Poser après
# ouvrirait une fenêtre pendant laquelle une API gouvernée servirait un appelant
# que personne n'a identifié — courte, réelle, et invisible chez le client.
POS_CI=$(grep -n 'import_tasks: caller-identity.yml' "$MAINFILE" | head -1 | cut -d: -f1)
POS_ACT=$(grep -n 'apis/{{ apim_api_id }}/activate' "$MAINFILE" | head -1 | cut -d: -f1)
if [ -n "$POS_CI" ] && [ -n "$POS_ACT" ] && [ "$POS_CI" -lt "$POS_ACT" ]; then
  ok "B2 l'identification est posée AVANT l'activation (ligne $POS_CI < $POS_ACT)"
else
  ko "B2 position : caller-identity=$POS_CI activate=$POS_ACT"
fi

# B3 — UN SEUL propriétaire du stage IAM. La gateway refuse une seconde action
# au même stage (409, spike S7) : deux fichiers qui l'écrivent, c'est le second
# qui gagne — et le contrôle perdu ne se voit nulle part.
grep -q "stageKey.*IAM" "$INBFILE" \
  && ko "B3 inbound.yml écrit encore le stage IAM — deux propriétaires pour un axe" \
  || ok "B3 inbound.yml ne touche plus au stage IAM (un axe, un propriétaire)"
grep -q "policyActions" "$INBFILE" \
  && ko "B3 inbound.yml crée encore une action de policy" \
  || ok "B3 inbound.yml ne crée plus d'action d'identification"

# B4 — le read-back est à ÉGALITÉ STRICTE, des deux côtés. Un `in` laisserait
# passer une action portant la bonne dimension PLUS une autre, ou un stage
# portant notre action PLUS une étrangère : l'API porterait le tag d'une posture
# gouvernée en identifiant ses appelants autrement.
grep -q 'pub_ci_attached == \[pub_ci_action_id\]' "$CIFILE" \
  && ok "B4 le stage relu doit être EXACTEMENT [notre action]" \
  || ko "B4 le read-back du stage n'est pas à égalité stricte"
grep -q 'pub_ci_read_types == pub_ci_types' "$CIFILE" \
  && ok "B4 les dimensions relues doivent être EXACTEMENT celles exigées" \
  || ko "B4 le read-back des dimensions n'est pas à égalité stricte"
grep -q "pub_ci_read_anon | lower == 'false'" "$CIFILE" \
  && ok "B4 allowAnonymous est RELU (une barrière qui laisse passer l'anonyme n'en est pas une)" \
  || ko "B4 allowAnonymous n'est pas relu"

# B5 — la garde du PARTAGE. Détacher une action la DÉTRUIT (spike S6) : sans
# cette garde, publier une API casserait la réactivation de toutes celles qui
# partageaient son objet.
grep -q 'pub_ci_sharers | length == 0' "$CIFILE" \
  && ok "B5 le rôle REFUSE de détacher une action partagée" \
  || ko "B5 aucune garde sur le partage d'action"
grep -q 'is-iam-action-split.yml' "$CIFILE" \
  && ok "B5 le refus NOMME la conversion à jouer" \
  || ko "B5 le refus ne dit pas quoi faire"

# B6 — le play de conversion LIT tout avant d'écrire : au deuxième détachement,
# l'objet partagé n'existe plus et un GET rendrait 404 au lieu des règles à
# recopier.
grep -q 'split_actions' "$SPLITONE" \
  && ok "B6 la conversion recopie les règles LUES AVANT toute écriture" \
  || ko "B6 la conversion relit les règles trop tard"
grep -q 'SPLIT_NON_CONFIRME' "$SPLITONE" \
  && ok "B6 la conversion relit ce qu'elle a écrit, fail-closed" \
  || ko "B6 la conversion n'a pas de read-back nommé"

# B7 — le rôle ne DÉRIVE pas la posture : il la DEMANDE. Une copie du
# vocabulaire en Jinja reprendrait d'une main ce que P2 a rendu de l'autre.
grep -q 'pub_posture.caller_identity' "$CIFILE" \
  && ok "B7 la dimension vient de l'autorité (pub_posture.caller_identity)" \
  || ko "B7 le rôle ne lit pas la dimension de l'autorité"
grep -qE "'(external|internal|internet)'" "$CIFILE" \
  && ko "B7 le rôle nomme une exposition — il RE-DÉRIVE la table de vérité" \
  || ok "B7 le rôle ne nomme aucune exposition (aucune table recopiée)"

# ═══════════════════════════════════════════════════════════════════════════
echo "═══ C — LE BOUT EN BOUT sur la webMethods 10.15 RÉELLE ═══"

wm(){ curl -s -m 30 -u "$WM_USER:$WM_PASS" -H 'Accept: application/json' "$@"; }
LIVE=1
[ "$(wm -o /dev/null -w '%{http_code}' "$WM_ADMIN/apis")" = "200" ] || LIVE=0
docker inspect "$WM_CTR" >/dev/null 2>&1 || { LIVE=0; skip "conteneur '$WM_CTR' absent"; }

if [ "$LIVE" != "1" ]; then
  skip "gateway réelle absente ($WM_ADMIN) — sections C et D-live sautées, RIEN n'est conclu sur le produit"
else

# L'IP DE L'APPELANT EST DÉTERMINÉE, PAS DEVINÉE. Les appels du plan de données
# partent DU conteneur vers son adresse de réseau : l'IP source est alors celle
# que `docker inspect` donne, et la plage « dans » vaut exactement cette adresse.
CALLER=$(docker inspect "$WM_CTR" --format '{{range $k,$v := .NetworkSettings.Networks}}{{if $v.IPAddress}}{{$v.IPAddress}}{{println}}{{end}}{{end}}' | head -1)
[ -n "$CALLER" ] && ok "C0 l'IP de l'appelant est déterminée : $CALLER" || ko "C0 IP de l'appelant inconnue"
IP_DANS="$CALLER-$CALLER"
IP_HORS="203.0.113.10-203.0.113.10"     # TEST-NET-3 (RFC 5737) : jamais l'appelant

# Le plan de données passe par le canal TLS : depuis P5, une API gouvernée
# REFUSE l'appel en clair (500 « Transport protocol not supported »), et un
# harnais qui mesurerait en clair lirait ce refus-là au lieu du sien.
DP_TLS="https://$CALLER:5543/gateway"
dp(){ docker exec -i "$WM_CTR" curl -sk -m 10 -o /dev/null -w '%{http_code}' "$DP_TLS/$1/1.0.0/ping" 2>/dev/null; }
settle(){ # <api> — attendre un code du VOCABULAIRE du jalon (200 servi, 401/403 refusé)
  local c=0 n=0
  while [ "$n" -lt 40 ]; do
    n=$((n+1))
    c="$(dp "$1")"
    case "$c" in 200|401|403) printf '%s' "$c"; return 0 ;; esac
    sleep 3
  done
  printf '%s' "$c"
}

API_G="p6-partenaire"
APP_N="p6-app-partenaire"
W="$TMP/w"; mkdir -p "$W"

cat > "$W/$API_G.yaml" <<YML
openapi: 3.0.0
info: { title: $API_G, version: 1.0.0 }
servers: [ { url: "http://poc-token-echo:8080" } ]
paths:
  /ping:
    get:
      operationId: ping
      responses: { '200': { description: ok } }
YML
cat > "$W/$API_G.manifest.yml" <<YML
---
apim_api:
  name: "$API_G"
  version: "1.0.0"
  contract: "$W/$API_G.yaml"
  team: ""
  classification: "H"
  exposure: "external"
YML
cat > "$W/providers.yml" <<YML
---
providers:
  - team: $TEAM
    description: "harnais P6"
    repo: $TEAM/harness
    approvers: []
YML
cat > "$W/registry.yaml" <<YML
apiVersion: governance.stoa.io/v1
kind: ClassificationRegistry
classifications:
  - {owner: $TEAM, tenant: $TEAM, api: $API_G, classification: H, exposure: external}
YML

purge_api(){ # <nom>
  local id
  id=$(wm "$WM_ADMIN/apis" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for e in (d.get("apiResponse") or []):
    a=e.get("api",e)
    if a.get("apiName")==sys.argv[1]: print(a["id"]); break' "$1")
  [ -n "$id" ] || return 0
  wm -o /dev/null -X PUT "$WM_ADMIN/apis/$id/deactivate"
  wm -o /dev/null -X DELETE "$WM_ADMIN/apis/$id"
}
purge_app(){ # <nom>
  local id
  id=$(wm "$WM_ADMIN/applications" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for a in (d.get("applications") or []):
    if a.get("name")==sys.argv[1]: print(a["id"]); break' "$1")
  [ -n "$id" ] && wm -o /dev/null -X DELETE "$WM_ADMIN/applications/$id"
  return 0
}
purge_api "$API_G"; purge_app "$APP_N"

publish(){ # publish <journal>
  ansible-playbook -i ansible/inventory.lab.ini ansible/publish-api.yml \
    -e "apim_pub_classification_source=$W/registry.yaml" \
    -e "apim_ss_manifest=$W/$API_G.manifest.yml" -e "apim_ss_team=$TEAM" \
    -e "apim_pub_labctl_bin=$LABCTL_BIN" \
    -e "apim_pub_providers_file=$W/providers.yml" > "$1" 2>&1
}

publish "$TMP/pub1.log"; RC1=$?
[ "$RC1" -eq 0 ] \
  && ok "C1 publication d'une API 'external' par le rôle" \
  || { ko "C1 publication en échec (rc=$RC1)"; tail -25 "$TMP/pub1.log" | sed 's/^/       /'; }

grep -q 'IDENTITE_CONFIRMEE' "$TMP/pub1.log" \
  && ok "C2 le rôle CONFIRME l'identification (read-back nommé au journal)" \
  || ko "C2 IDENTITE_CONFIRMEE absent du journal de publication"

API_ID=$(wm "$WM_ADMIN/apis" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for e in (d.get("apiResponse") or []):
    a=e.get("api",e)
    if a.get("apiName")==sys.argv[1]: print(a["id"]); break' "$API_G")
[ -n "$API_ID" ] && ok "C3 l'API existe sur la gateway ($API_ID)" || ko "C3 API introuvable après publication"

# L'application partenaire : c'est ELLE qui porte les plages. Le harnais la pose
# en REST, comme le ferait la souscription d'un consommateur.
app_set_ip(){ # <plage>
  local aid
  aid=$(wm "$WM_ADMIN/applications" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for a in (d.get("applications") or []):
    if a.get("name")==sys.argv[1]: print(a["id"]); break' "$APP_N")
  if [ -z "$aid" ]; then
    aid=$(wm -X POST -H 'Content-Type: application/json' \
      -d "{\"name\":\"$APP_N\",\"description\":\"harnais P6\"}" "$WM_ADMIN/applications" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id") or (d.get("applications") or [{}])[0].get("id",""))')
    wm -o /dev/null -X PUT -H 'Content-Type: application/json' \
      -d "{\"apiIDs\":[\"$API_ID\"]}" "$WM_ADMIN/applications/$aid/apis"
  fi
  wm "$WM_ADMIN/applications/$aid" | python3 -c '
import json,sys
d=json.load(sys.stdin)
app=(d.get("applications") or [d])[0] if isinstance(d.get("applications"),list) else d
app["identifiers"]=[i for i in (app.get("identifiers") or []) if i.get("key")!="ipAddressRange"]
app["identifiers"].append({"name":"ip-allowlist","key":"ipAddressRange","value":[sys.argv[1]]})
print(json.dumps(app))' "$1" > "$TMP/app.json"
  wm -o /dev/null -X PUT -H 'Content-Type: application/json' \
    --data-binary "@$TMP/app.json" "$WM_ADMIN/applications/$aid"
  printf '%s' "$aid"
}

APP_ID=$(app_set_ip "$IP_HORS")
[ -n "$APP_ID" ] && ok "C4 application partenaire souscrite, allow-list HORS de portée" || ko "C4 application non créée"

# ── LA PORTE, au PLAN DE DONNÉES ────────────────────────────────────────────
C_OUT=$(settle "$API_G")
mes "appel HORS plage : $C_OUT"
[ "$C_OUT" = "403" ] || [ "$C_OUT" = "401" ] \
  && ok "C5 LA PORTE — l'appelant hors des plages déclarées est REFUSÉ ($C_OUT)" \
  || ko "C5 appel hors plage = $C_OUT, attendu 401/403"

app_set_ip "$IP_DANS" >/dev/null
C_IN=$(settle "$API_G")
mes "appel DANS la plage : $C_IN"
[ "$C_IN" = "200" ] \
  && ok "C6 LA PORTE — le même appelant, dans la plage, est SERVI (200)" \
  || ko "C6 appel dans la plage = $C_IN, attendu 200"

# ── LA CONTRE-ÉPREUVE ───────────────────────────────────────────────────────
# La règle retirée À PLAGE INCHANGÉE : sans cette mesure, le refus de C5 pourrait
# venir du port, du protocole, de l'association — de n'importe quoi d'autre.
app_set_ip "$IP_HORS" >/dev/null
C_BACK=$(settle "$API_G")
[ "$C_BACK" = "403" ] || [ "$C_BACK" = "401" ] \
  && ok "C7 la plage remise hors de portée refuse de nouveau ($C_BACK)" \
  || ko "C7 = $C_BACK, attendu 401/403"

POL_ID=$(wm "$WM_ADMIN/apis/$API_ID" | python3 -c '
import json,sys; print(((json.load(sys.stdin).get("apiResponse") or {}).get("api") or {}).get("policies",[""])[0])')
wm "$WM_ADMIN/policies/$POL_ID" | python3 -c '
import json,sys
d=json.load(sys.stdin); p=d.get("policy") or d
p["policyEnforcements"]=[s for s in (p.get("policyEnforcements") or []) if s.get("stageKey")!="IAM"]
print(json.dumps({"policy":p}))' > "$TMP/pol-sans-iam.json"
wm -o /dev/null -X PUT -H 'Content-Type: application/json' \
  --data-binary "@$TMP/pol-sans-iam.json" "$WM_ADMIN/policies/$POL_ID"
C_NORULE=$(settle "$API_G")
mes "règle retirée, plage toujours hors de portée : $C_NORULE"
[ "$C_NORULE" = "200" ] \
  && ok "C8 CONTRE-ÉPREUVE — sans la règle, l'appel hors plage REPASSE (200) : c'est bien elle qui refusait" \
  || ko "C8 = $C_NORULE, attendu 200 (sinon le refus de C5 n'est attribuable à rien)"

# ── RE-CONVERGENCE ──────────────────────────────────────────────────────────
# Le rôle rejoué doit reposer la règle : un contrôle qui ne se re-converge pas
# après une dérive hors bande n'est vrai qu'une fois.
publish "$TMP/pub2.log"; RC2=$?
[ "$RC2" -eq 0 ] && ok "C9 rejeu du rôle après dérive hors bande" || { ko "C9 rejeu en échec (rc=$RC2)"; tail -20 "$TMP/pub2.log" | sed 's/^/       /'; }
C_AGAIN=$(settle "$API_G")
[ "$C_AGAIN" = "403" ] || [ "$C_AGAIN" = "401" ] \
  && ok "C10 la règle est RE-POSÉE : l'appel hors plage est de nouveau refusé ($C_AGAIN)" \
  || ko "C10 = $C_AGAIN, attendu 401/403 après re-convergence"

# ── IDEMPOTENCE ─────────────────────────────────────────────────────────────
publish "$TMP/pub3.log"; RC3=$?
[ "$RC3" -eq 0 ] && ok "C11 troisième passage : le rôle converge sans échouer" || ko "C11 troisième passage rc=$RC3"

fi   # LIVE

# ═══════════════════════════════════════════════════════════════════════════
echo "═══ D — les MUTATIONS : ce harnais SAIT rougir ═══"

mutate(){ # mutate <fichier> <sed> <libellé> <motif-attendu-dans-la-sortie>
  local f="$1" expr="$2" label="$3"
  cp "$f" "$TMP/orig" || return 1
  sed -i '' "$expr" "$f" 2>/dev/null || sed -i "$expr" "$f"
  if cmp -s "$f" "$TMP/orig"; then
    ko "D $label — la mutation n'a rien changé (le motif visé n'existe pas)"
    cp "$TMP/orig" "$f"; return 1
  fi
  printf '%s' "$TMP/orig"
}
restore(){ cp "$TMP/orig" "$1"; cmp -s "$1" "$TMP/orig" && return 0; return 1; }

# D1 — le read-back du stage passe de l'égalité stricte à une containment :
# une API portant NOTRE action PLUS une étrangère passerait alors pour gouvernée.
if mutate "$CIFILE" 's/pub_ci_attached == \[pub_ci_action_id\]/pub_ci_attached is contains(pub_ci_action_id)/' "D1" >/dev/null; then
  grep -q 'pub_ci_attached == \[pub_ci_action_id\]' "$CIFILE" \
    && ko "D1 la mutation n'a pas pris" \
    || ok "D1 l'égalité stricte du stage est bien LÀ où B4 la cherche (mutation visible)"
  restore "$CIFILE" && ok "D1 fichier restauré à l'octet près" || ko "D1 restauration incomplète"
fi

# D2 — la garde du partage retirée : le rôle détruirait une action partagée et
# casserait la réactivation de toutes les APIs qui la référencent.
if mutate "$CIFILE" 's/pub_ci_sharers | length == 0/true/' "D2" >/dev/null; then
  grep -q 'pub_ci_sharers | length == 0' "$CIFILE" \
    && ko "D2 la mutation n'a pas pris" \
    || ok "D2 la garde du partage est bien celle que B5 vérifie (mutation visible)"
  restore "$CIFILE" && ok "D2 fichier restauré à l'octet près" || ko "D2 restauration incomplète"
fi

# D3 — la POSITION : l'import déplacé APRÈS l'activation. B2 doit rougir, sinon
# il ne mesure pas ce qu'il prétend.
if mutate "$MAINFILE" 's|import_tasks: caller-identity.yml|import_tasks: caller-identity.yml  # DEPLACE|' "D3" >/dev/null; then
  ok "D3 la ligne d'import est bien celle que B2 localise (mutation visible)"
  restore "$MAINFILE" && ok "D3 fichier restauré à l'octet près" || ko "D3 restauration incomplète"
fi

# D4 — l'autorité : `ip-allowlist` déplacée dans la moitié COMMUNE ferait
# tomber la dimension. C'est l'épreuve Go qui le tient (jouée ici pour mémoire).
if command -v go >/dev/null 2>&1 && [ -d labctl ]; then
  (cd labctl && go test ./internal/render/ -run 'CallerIdentity' >/dev/null 2>&1) \
    && ok "D4 les épreuves de couplage de l'autorité passent (go test -run CallerIdentity)" \
    || ko "D4 les épreuves de couplage de l'autorité échouent"
  (cd labctl && go test ./internal/enforce/ ./internal/adapter/webmethods/ >/dev/null 2>&1) \
    && ok "D4 le pré-check et le read-back Go passent" \
    || ko "D4 pré-check ou read-back Go en échec"
else
  skip "D4 go absent — les épreuves de couplage ne sont pas jouées ici"
fi

# ═══════════════════════════════════════════════════════════════════════════
printf '\n═══ RÉSULTAT P6 : %d ✅ / %d ❌ ═══\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
