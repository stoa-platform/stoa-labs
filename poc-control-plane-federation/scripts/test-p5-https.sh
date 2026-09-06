#!/usr/bin/env bash
# test-p5-https.sh — la matrice de preuve du jalon P5 (ADR-095) :
# L'API REFUSE ELLE-MÊME L'APPEL EN CLAIR, ET LE LISTENER EST UN OBJET
# D'ENVIRONNEMENT QUI NE PROTÈGE PERSONNE.
#
# Ce qui doit être vrai à la fin de ce jalon, et que ce fichier mesure :
#   une API publiée sous posture gouvernée répond en HTTPS et REFUSE l'appel en
#   clair ; le refus vient de l'API et non du port (contre-épreuve : le réglage
#   retiré, le clair repasse) ; le protocole posé est DÉRIVÉ de la moitié
#   per-API du bouquet, jamais recopié ; et le play de listener dit lui-même
#   qu'il n'a protégé aucune API.
#
#   A. l'AUTORITÉ (`labctl posture`) — `entry_protocol` fini, dérivé de la
#      moitié qui le possède. Hors ligne.
#   B. les RÔLES hors ligne — les refus nommés, la POSITION dans le rôle, la
#      stricte égalité du read-back, et ce que le rôle de listener n'écrit pas.
#   C. LE BOUT EN BOUT sur la wM 10.15 RÉELLE — publication, porte au plan de
#      données, contre-épreuve, re-convergence, et le play de listener.
#   D. les MUTATIONS — ce harnais SAIT rougir : chaque sabotage est restauré à
#      l'octet près (cmp).
#
# Hors ligne pour A, B et la partie hors ligne de D. Les sections C et D-live
# exigent la gateway RÉELLE (poc-webmethods-real, :5555) ; elles se sautent
# proprement — et le disent — si elle est absente. Jamais un vert silencieux.
#
#   ./scripts/test-p5-https.sh
#   WM_ADMIN=http://localhost:5555/rest/apigateway ./scripts/test-p5-https.sh
#
# `A && ok || ko` (SC2015) est l'idiome des scripts de preuve du repo : ici `ok`
# et `ko` ne rendent jamais un code non nul, donc la branche `||` ne peut pas
# être atteinte depuis un `ok` réussi.
# shellcheck disable=SC2015
set -u
set -o pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
TMP="$(mktemp -d /tmp/p5tls.XXXXXX)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
skip(){ printf '  ⏭  %s\n' "$*"; }
mes(){ printf '     📏 %s\n' "$*"; }

# shellcheck source=scripts/lib/posture-authority.sh
. "$REPO/scripts/lib/posture-authority.sh"
resolve_posture_authority "$TMP/labctl" \
  || { echo "ABANDON : aucun labctl — l'autorité qui DÉRIVE le protocole d'entrée est le sujet de ce test, pas une dépendance optionnelle." >&2; exit 2; }

WM_ADMIN="${WM_ADMIN:-http://localhost:5555/rest/apigateway}"
export WM_DATA="${WM_DATA:-http://localhost:5555/gateway}"
export WM_DP_TLS_BASE="${WM_DP_TLS_BASE:-https://localhost:5543/gateway}"
export WM_DP_CONTAINER="${WM_DP_CONTAINER:-poc-webmethods-real}"
WM_USER="${WM_USER:-Administrator}"
WM_PASS="${WM_PASS:-manage}"
TEAM="${P5_TEAM:-banking-demo}"
EPFILE="ansible/roles/apim_publish_api/tasks/entry-protocol.yml"
MAINFILE="ansible/roles/apim_publish_api/tasks/main.yml"
HLFILE="ansible/roles/apim_https_listener/tasks/main.yml"
HLDEF="ansible/roles/apim_https_listener/defaults/main.yml"

# shellcheck source=scripts/lib/wm-dataplane.sh
. "$REPO/scripts/lib/wm-dataplane.sh"

cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════
echo "═══ A — l'AUTORITÉ : un protocole FINI, dérivé de la moitié qui le possède ═══"

REG="$TMP/classifications.yaml"
cat > "$REG" <<'YML'
apiVersion: governance.stoa.io/v1
kind: ClassificationRegistry
classifications:
  - {owner: banking-demo, tenant: banking-demo, api: comptes-lecture, classification: VH, exposure: internet}
  - {owner: banking-demo, tenant: banking-demo, api: taux-lecture,    classification: M,  exposure: internal}
YML

posture_json(){  # <projet> <api> <classification> <exposure>
  LABCTL_CLASSIFICATION_SOURCE='' LABCTL_PROJECT='' "$LABCTL_BIN" posture \
    --project "$1" --api "$2" --declared-classification "$3" --declared-exposure "$4" \
    --classification-source "$REG" -o json 2>&1
}
jfield(){ python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d[sys.argv[1]]) if isinstance(d.get(sys.argv[1]),(list,dict)) else d.get(sys.argv[1],""))' "$1"; }

OUT=$(posture_json banking-demo comptes-lecture VH internet)
EP=$(printf '%s' "$OUT" | jfield entry_protocol)
PERAPI=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["per_api_policies"]))')
mes "vh-internet : entry_protocol='$EP' per_api=[$PERAPI]"

# A1 — la valeur est FINIE et dans le vocabulaire du produit. Une valeur vide,
# ou une casse différente, serait acceptée par la gateway avec un 200 puis relue
# autrement : la classe de faux vert que ce GOAL paie depuis P0.
[ "$EP" = "https" ] \
  && ok "A1 l'autorité rend un protocole FINI dans le vocabulaire du produit ('https')" \
  || ko "A1 entry_protocol='$EP', attendu exactement 'https'"

# A2 — LE COUPLAGE que P4 a explicitement demandé d'écrire : le protocole existe
# SI ET SEULEMENT SI https-only est dans la moitié per-API. C'est ce qui empêche
# l'APPLICATION de partir vers un objet partagé pendant que la VÉRIFICATION
# continue de relire l'API.
COUPLE=$(printf '%s' "$OUT" | python3 -c '
import json,sys
d=json.load(sys.stdin)
per="https-only" in d["per_api_policies"]; com="https-only" in d["common_policies"]
ep=bool(d["entry_protocol"])
print("ok" if (per==ep and not com) else f"KO per={per} common={com} entry={ep}")')
[ "$COUPLE" = "ok" ] \
  && ok "A2 le protocole suit la moitié per-API (application et vérification ne peuvent pas diverger)" \
  || ko "A2 $COUPLE"

# A3 — toutes les cellules. https-only est un PLANCHER depuis P1 : une cellule
# qui sortirait sans protocole publierait une API joignable en clair tout en
# portant le tag d'une posture gouvernée.
MISS=0
for C in VH H M; do for X in internal external internet; do
  V=$(LABCTL_CLASSIFICATION_SOURCE='' LABCTL_PROJECT='' "$LABCTL_BIN" posture \
        --api x --project p --declared-classification "$C" --declared-exposure "$X" -o json 2>/dev/null | jfield entry_protocol)
  [ "$V" = "https" ] || { MISS=$((MISS+1)); mes "cellule $C/$X : entry_protocol='$V'"; }
done; done
[ "$MISS" -eq 0 ] \
  && ok "A3 les 9 cellules nommées épinglent toutes 'https' (plancher ADR-091)" \
  || ko "A3 $MISS cellules sans protocole d'entrée"

# A4 — la sortie TEXTE le dit aussi. Le journal d'un build est ce que le
# demandeur lit ; une valeur visible seulement en JSON n'est visible par personne.
TXT=$(LABCTL_CLASSIFICATION_SOURCE='' LABCTL_PROJECT='' "$LABCTL_BIN" posture \
        --api comptes-lecture --project banking-demo --declared-classification VH \
        --declared-exposure internet --classification-source "$REG" 2>&1)
printf '%s' "$TXT" | grep -q '^entry_protocol: https$' \
  && ok "A4 la sortie humaine porte le protocole (le journal du build le montre)" \
  || ko "A4 'entry_protocol:' absent de la sortie texte"

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "═══ B — les RÔLES hors ligne : refus nommés, position, stricte égalité ═══"

# B1 — chaque défaillance a son nom. Un refus générique oblige le demandeur à
# lire un journal Ansible ; un refus nommé se relaie jusqu'à la PR.
for CODE in PROTOCOLE_NON_ARBITRE PROTOCOLE_SANS_POLICY PROTOCOLE_STAGE_ABSENT \
            PROTOCOLE_ACTION_ABSENTE PROTOCOLE_PARAM_ABSENT HTTPS_ONLY_UNCONFIRMED \
            HTTPS_ONLY_CONFIRMED; do
  grep -q "$CODE" "$EPFILE" && ok "B1 refus/verdict nommé présent : $CODE" || ko "B1 $CODE absent de $EPFILE"
done

# B2 — LA POSITION. Le jalon promet qu'une API gouvernée ne sert jamais un seul
# appel en clair, pas même pendant sa publication : cela ne tient que si le
# protocole est posé AVANT l'activation. Mesuré posable sur une API inactive
# (spike P5 S8), donc la promesse est tenable — reste à vérifier qu'elle est tenue.
L_EP=$(grep -n 'import_tasks: entry-protocol.yml' "$MAINFILE" | head -1 | cut -d: -f1)
L_GP=$(grep -n 'import_tasks: global-policy.yml'  "$MAINFILE" | head -1 | cut -d: -f1)
L_ACT=$(grep -n 'apis/{{ apim_api_id }}/activate' "$MAINFILE" | head -1 | cut -d: -f1)
{ [ -n "$L_EP" ] && [ -n "$L_ACT" ] && [ "$L_EP" -lt "$L_ACT" ]; } \
  && ok "B2 le protocole est posé AVANT l'activation (jamais un appel en clair, même pendant la publication)" \
  || ko "B2 entry-protocol.yml n'est pas antérieur à l'activation (ep=$L_EP activate=$L_ACT)"
{ [ -n "$L_GP" ] && [ -n "$L_EP" ] && [ "$L_GP" -lt "$L_EP" ]; } \
  && ok "B2 il suit l'appartenance à la cellule (le refus le plus probable tombe en premier)" \
  || ko "B2 ordre appartenance/protocole inversé (gp=$L_GP ep=$L_EP)"

# B3 — LA STRICTE ÉGALITÉ, et c'est le cœur du jalon. Une liste ['http','https']
# CONTIENT la valeur visée et laisse pourtant passer le clair : un `in` au
# read-back produirait un vert parfaitement vacant. Le paramètre est mesuré
# EXCLUSIF (spike P5 S5), donc la seule assertion juste est l'égalité.
grep -q 'pub_ep_now == \[pub_ep_wanted\]' "$EPFILE" \
  && ok "B3 le read-back exige l'ÉGALITÉ stricte, pas l'appartenance" \
  || ko "B3 le read-back n'est pas une égalité stricte — une liste ['http','https'] passerait"

# B4 — le piège 10.15 du corps enveloppé. Un corps NU rend 200 sans persister.
grep -q 'policyAction: "{{ pub_ep_desired }}"' "$EPFILE" \
  && ok "B4 le PUT porte le corps ENVELOPPÉ {\"policyAction\": …}" \
  || ko "B4 le PUT ne porte pas le corps enveloppé — 200 sans persistance"

# B5 — le rôle ÉDITE, il ne crée pas. Mesuré : l'action existe nativement (S1).
# En créer une reviendrait à inventer la forme d'un objet produit.
grep -Eq 'method: (POST|DELETE)' "$EPFILE" \
  && ko "B5 le rôle CRÉE ou SUPPRIME un objet — il ne doit qu'éditer l'action existante" \
  || ok "B5 le rôle n'écrit que par PUT : il édite, ne crée ni ne supprime"

# B6 — aucune recopie de vocabulaire. La valeur vient de l'autorité, pas d'un
# littéral : sinon P1 aurait supprimé quatre recopies pour en laisser naître une
# cinquième, sur l'axe que P4 venait de trancher.
grep -vE '^\s*#' "$EPFILE" | grep -q "values': \['https'\]\|values: \[.https.\]" \
  && ko "B6 le rôle écrit 'https' en dur — le protocole doit venir de labctl posture" \
  || ok "B6 le protocole écrit vient de pub_posture.entry_protocol, jamais d'un littéral"
grep -q 'pub_posture.entry_protocol' "$EPFILE" \
  && ok "B6 …et il vient bien de l'autorité (pub_posture.entry_protocol)" \
  || ko "B6 le rôle ne lit pas pub_posture.entry_protocol"

# B7 — le rôle de LISTENER : ses refus nommés.
for CODE in HTTPS_LISTENER_SANS_GABARIT CLIENT_AUTH_NON_CONVERGEABLE HTTPS_LISTENER_UNCONFIRMED \
            PORT_DE_PILOTAGE PRIMAIRE_UNCONFIRMED PORT_EN_CLAIR_TOUJOURS_OUVERT CLIENT_AUTH_INCONNU; do
  grep -q "$CODE" "$HLFILE" && ok "B7 refus nommé du listener : $CODE" || ko "B7 $CODE absent de $HLFILE"
done

# B8 — le rôle de listener ne TOUCHE aucune API, et ne supprime aucun port.
# C'est ce qui garantit qu'un play d'environnement ne peut pas changer la
# posture d'une API sans passer par la chaîne qui la gouverne.
grep -q '/apis' "$HLFILE" \
  && ko "B8 le rôle de listener touche à /apis — un objet d'environnement ne décide d'aucune API" \
  || ok "B8 le rôle de listener ne touche à AUCUNE API"
grep -q 'method: DELETE' "$HLFILE" \
  && ko "B8 le rôle de listener SUPPRIME un port" \
  || ok "B8 le rôle de listener ne supprime jamais un port"

# B9 — les deux gestes de topologie sont ÉTEINTS par défaut. Ni l'un ni l'autre
# n'est un contrôle : promouvoir ne ferme pas le clair (S6) et ne protège
# aucune API (spike C de P0).
grep -q '^apim_hl_promote_primary: false' "$HLDEF" \
  && ok "B9 la promotion en primaire est éteinte par défaut" \
  || ko "B9 apim_hl_promote_primary n'est pas false par défaut"
grep -q '^apim_hl_close_plaintext_port: 0' "$HLDEF" \
  && ok "B9 la fermeture du clair est éteinte par défaut" \
  || ko "B9 apim_hl_close_plaintext_port n'est pas 0 par défaut"

# B10 — l'honnêteté du play, vérifiée comme le reste. Le dernier mot du rôle
# doit DIRE ce qui reste ouvert en clair et où vit le contrôle. Sans cela un
# play vert laisse croire que le clair est traité.
grep -q 'HTTPS_LISTENER_ETAT' "$HLFILE" && grep -q 'EN CLAIR, TOUJOURS ACTIVÉS' "$HLFILE" \
  && ok "B10 le play énumère les ports en clair restés ouverts (il ne se contente pas d'être vert)" \
  || ko "B10 le play ne rend pas compte de ce qui reste ouvert en clair"

# B11 — la syntaxe. Un rôle qui ne se parse pas ne refuse rien.
if command -v ansible-playbook >/dev/null 2>&1; then
  ansible-playbook --syntax-check -i localhost, ansible/is-https-listener.yml >"$TMP/syn.log" 2>&1 \
    && ok "B11 le play de listener passe le syntax-check" \
    || ko "B11 syntax-check en échec — $(tail -2 "$TMP/syn.log" | tr '\n' ' ')"
else
  skip "B11 ansible-playbook absent — syntax-check sauté"
fi

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "═══ C — LE BOUT EN BOUT sur la webMethods 10.15 RÉELLE ═══"

wm(){ curl -s -m 30 -u "$WM_USER:$WM_PASS" -H 'Accept: application/json' "$@"; }
LIVE=1
[ "$(wm -o /dev/null -w '%{http_code}' "$WM_ADMIN/apis")" = "200" ] || LIVE=0
dp_tls_reachable || { LIVE=0; skip "canal TLS injoignable (conteneur '$WM_DP_CONTAINER' absent)"; }

if [ "$LIVE" != "1" ]; then
  skip "gateway réelle absente ($WM_ADMIN) — sections C et D-live sautées, RIEN n'est conclu sur le produit"
else

API_G="p5-gouvernee"      # posture arbitrée -> https-only
API_T="p5-temoin"         # AUCUN registre   -> posture non arbitrée, reste en clair
W="$TMP/w"; mkdir -p "$W"

contract(){ cat > "$W/$1.yaml" <<YML
openapi: 3.0.0
info: { title: $1, version: 1.0.0 }
servers: [ { url: "http://poc-token-echo:8080" } ]
paths:
  /ping:
    get:
      operationId: ping
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
    description: "harnais P5"
    repo: $TEAM/harness
    approvers: []
YML
cat > "$W/registry.yaml" <<YML
apiVersion: governance.stoa.io/v1
kind: ClassificationRegistry
classifications:
  - {owner: $TEAM, tenant: $TEAM, api: $API_G, classification: M, exposure: internal}
YML

publish(){  # publish <api> <journal> [--sans-registre]
  # Le drapeau du registre est passé en TÊTE, jamais depuis un tableau : sous
  # bash 3.2 (le shell de macOS) l'expansion d'un tableau VIDE avec `set -u` est
  # une erreur « unbound variable » — et le cas vide est justement celui du
  # témoin, la mesure sans laquelle le refus de C2 n'est attribuable à rien.
  local src=""
  [ "${3:-}" = "--sans-registre" ] || src="apim_pub_classification_source=$W/registry.yaml"
  if [ -n "$src" ]; then
    ansible-playbook -i ansible/inventory.lab.ini ansible/publish-api.yml \
      -e "$src" \
      -e "apim_ss_manifest=$W/$1.manifest.yml" -e "apim_ss_team=$TEAM" \
      -e "apim_pub_labctl_bin=$LABCTL_BIN" \
      -e "apim_pub_providers_file=$W/providers.yml" > "$2" 2>&1
  else
    ansible-playbook -i ansible/inventory.lab.ini ansible/publish-api.yml \
      -e "apim_ss_manifest=$W/$1.manifest.yml" -e "apim_ss_team=$TEAM" \
      -e "apim_pub_labctl_bin=$LABCTL_BIN" \
      -e "apim_pub_providers_file=$W/providers.yml" > "$2" 2>&1
  fi
}
api_id(){ wm "$WM_ADMIN/apis" | python3 -c '
import json,sys
for e in json.load(sys.stdin)["apiResponse"]:
    if e["api"]["apiName"]==sys.argv[1]: print(e["api"]["id"]); break' "$1"; }
drop_api(){ local i; i=$(api_id "$1"); [ -n "$i" ] || return 0
  curl -s -o /dev/null -m 30 -u "$WM_USER:$WM_PASS" -X PUT "$WM_ADMIN/apis/$i/deactivate"
  curl -s -o /dev/null -m 30 -u "$WM_USER:$WM_PASS" -X DELETE "$WM_ADMIN/apis/$i"; }

# L'action transport d'une API, et sa valeur — la même résolution que le rôle.
ep_action(){ python3 - "$WM_ADMIN" "$WM_USER" "$WM_PASS" "$(api_id "$1")" <<'PY'
import base64,json,sys,urllib.request,urllib.error
gw,u,p,aid=sys.argv[1:5]
if not aid: print(""); raise SystemExit
auth=base64.b64encode(f"{u}:{p}".encode()).decode()
def get(path):
    r=urllib.request.Request(gw+path); r.add_header("Authorization","Basic "+auth)
    r.add_header("Accept","application/json")
    try:
        with urllib.request.urlopen(r,timeout=30) as x: return json.loads(x.read().decode() or "{}")
    except urllib.error.HTTPError as e: return {}
rec=(get(f"/apis/{aid}").get("apiResponse") or {}).get("api",{})
pols=[get(f"/policies/{i}").get("policy",{}) for i in rec.get("policies") or []]
svc=next((x for x in pols if x.get("policyScope")=="SERVICE"), pols[0] if pols else {})
ids=[e["enforcementObjectId"] for s in svc.get("policyEnforcements") or []
     if s.get("stageKey")=="transport" for e in s.get("enforcements") or []
     if e.get("enforcementObjectId")]
for i in ids:
    a=get(f"/policyActions/{i}").get("policyAction",{})
    if a.get("templateKey")=="entryProtocolPolicy":
        v=next((q.get("values") for q in a.get("parameters") or [] if q.get("templateKey")=="protocol"), [])
        print(f"{i} {','.join(v)}"); break
PY
}
set_ep(){ python3 - "$WM_ADMIN" "$WM_USER" "$WM_PASS" "$1" "$2" <<'PY'
import base64,json,sys,urllib.request,urllib.error
gw,u,p,aid,vals=sys.argv[1:6]
auth=base64.b64encode(f"{u}:{p}".encode()).decode()
def call(m,path,body=None):
    d=json.dumps(body).encode() if body is not None else None
    r=urllib.request.Request(gw+path,data=d,method=m)
    r.add_header("Authorization","Basic "+auth); r.add_header("Accept","application/json")
    if d: r.add_header("Content-Type","application/json")
    try:
        with urllib.request.urlopen(r,timeout=30) as x: return x.status, json.loads(x.read().decode() or "{}")
    except urllib.error.HTTPError as e: return e.code, {}
a=call("GET",f"/policyActions/{aid}")[1].get("policyAction",{})
for q in a.get("parameters") or []:
    if q.get("templateKey")=="protocol": q["values"]=vals.split(",")
print(call("PUT",f"/policyActions/{aid}",{"policyAction":a})[0])
PY
}

trap 'drop_api "$API_G" >/dev/null 2>&1; drop_api "$API_T" >/dev/null 2>&1; cleanup' EXIT

drop_api "$API_G"; drop_api "$API_T"
contract "$API_G"; contract "$API_T"
manifest "$API_G" M internal; manifest "$API_T" M internal

# ---- C1 : la publication pose le protocole -------------------------------
publish "$API_G" "$W/pubG.log"; RC=$?
[ "$RC" -eq 0 ] && ok "C1 publication de $API_G sous posture gouvernée : rc=0" \
                || ko "C1 publication rc=$RC — $(grep -m1 -A2 '^fatal' "$W/pubG.log" | tr '\n' ' ')"
grep -q 'HTTPS_ONLY_CONFIRMED' "$W/pubG.log" \
  && ok "C1 le rôle CONFIRME par relecture que l'API n'accepte plus que https" \
  || ko "C1 HTTPS_ONLY_CONFIRMED absent du journal"
EPV=$(ep_action "$API_G"); mes "action transport de $API_G : $EPV"
[ "${EPV#* }" = "https" ] \
  && ok "C1 la gateway porte protocol=[https] sur l'API (lu hors du rôle)" \
  || ko "C1 protocole relu : '${EPV#* }', attendu 'https'"

# ---- C2 : LA PORTE, au plan de données -----------------------------------
CLEAR=$(dp_code clair "$API_G" 1.0.0 /ping)
BODY=$(dp_body clair "$API_G" 1.0.0 /ping)
mes "appel en CLAIR : HTTP $CLEAR"
[ "$CLEAR" != "200" ] \
  && ok "C2 LA PORTE (a) : l'appel en CLAIR est REFUSÉ (HTTP $CLEAR)" \
  || ko "C2 l'appel en clair PASSE — l'API gouvernée sert en clair"
printf '%s' "$BODY" | grep -q 'Transport protocol not supported' \
  && ok "C2 …et le refus est bien celui du PROTOCOLE (message du produit)" \
  || ko "C2 le refus n'est pas celui du protocole : $(printf '%s' "$BODY" | head -c 120)"

dp_wait https "$API_G" 1.0.0 /ping 20 >/dev/null 2>&1
TLS=$(dp_code https "$API_G" 1.0.0 /ping)
mes "appel en HTTPS : HTTP $TLS"
[ "$TLS" = "200" ] \
  && ok "C2 LA PORTE (b) : la MÊME API répond 200 en HTTPS" \
  || ko "C2 l'appel HTTPS ne passe pas (HTTP $TLS) — l'API ne serait joignable par aucun canal"

# ---- C3 : le TÉMOIN — sans gouvernance, rien n'est imposé ----------------
# Sans lui, une gateway en vrac (tout refuser) se lirait comme un succès.
publish "$API_T" "$W/pubT.log" --sans-registre; RC=$?
[ "$RC" -eq 0 ] && ok "C3 publication du témoin, sans registre central : rc=0" \
                || ko "C3 publication témoin rc=$RC — $(grep -m1 -A2 '^fatal' "$W/pubT.log" | tr '\n' ' ')"
grep -q 'PROTOCOLE_NON_ARBITRE' "$W/pubT.log" \
  && ok "C3 sans gouvernance, la plateforme n'impose AUCUN protocole et le DIT" \
  || ko "C3 PROTOCOLE_NON_ARBITRE absent — le mode sans gouvernance est silencieux"
dp_wait clair "$API_T" 1.0.0 /ping 20 >/dev/null 2>&1
TC=$(dp_code clair "$API_T" 1.0.0 /ping)
mes "témoin en clair : HTTP $TC"
[ "$TC" = "200" ] \
  && ok "C3 TÉMOIN : l'API non gouvernée répond TOUJOURS en clair (ce n'est pas la gateway qui refuse)" \
  || ko "C3 le témoin ne répond pas en clair (HTTP $TC) — le refus de C2 n'est plus attribuable"

# ---- C4 : LA CONTRE-ÉPREUVE ----------------------------------------------
# On retire le réglage À LA MAIN et on mesure que le clair repasse. Sans elle,
# rien ne dit que c'est la policy qui refusait plutôt que le port.
AID=$(printf '%s' "$EPV" | cut -d' ' -f1)
if [ -n "$AID" ]; then
  set_ep "$AID" http >/dev/null
  BACK=0
  for _ in $(seq 1 10); do
    [ "$(dp_code clair "$API_G" 1.0.0 /ping)" = "200" ] && { BACK=1; break; }; sleep 2
  done
  [ "$BACK" = "1" ] \
    && ok "C4 CONTRE-ÉPREUVE : le réglage retiré, l'appel en clair REPASSE — c'était bien la policy" \
    || ko "C4 le clair ne repasse pas après retrait : le refus de C2 venait d'ailleurs"

  # ---- C5 : re-convergence. Le rôle rejoué remet le réglage. --------------
  publish "$API_G" "$W/pubG2.log"; RC=$?
  EPV2=$(ep_action "$API_G")
  { [ "$RC" -eq 0 ] && [ "${EPV2#* }" = "https" ]; } \
    && ok "C5 le rôle rejoué RE-CONVERGE le protocole (une dérive hors bande est rattrapée)" \
    || ko "C5 re-convergence en échec (rc=$RC, protocole='${EPV2#* }')"

  # ---- C6 : l'idempotence n'est pas une écriture de plus -----------------
  publish "$API_G" "$W/pubG3.log" >/dev/null 2>&1
  grep -q 'déjà conforme, aucune écriture' "$W/pubG3.log" \
    && ok "C6 un troisième passage n'écrit RIEN (idempotent, et il le dit)" \
    || ko "C6 le rôle réécrit alors que la valeur est conforme"
else
  ko "C4 action transport introuvable — contre-épreuve impossible"
fi

# ---- C7 : le play de LISTENER --------------------------------------------
listener(){ ansible-playbook -i ansible/inventory.lab.ini ansible/is-https-listener.yml "$@" > "$W/hl.log" 2>&1; }
listener -e apim_hl_port=5543 -e apim_hl_port_alias=DefaultSecure -e apim_hl_client_auth=request; RC=$?
[ "$RC" -eq 0 ] && ok "C7 le play de listener converge sur :5543 (rc=0)" \
                || ko "C7 play de listener rc=$RC — $(grep -m1 -A2 '^fatal' "$W/hl.log" | tr '\n' ' ')"
grep -q 'HTTPS_LISTENER_CONFIRMED' "$W/hl.log" \
  && ok "C7 relecture fail-closed : le port est HTTPS, activé, avec un keystore" \
  || ko "C7 HTTPS_LISTENER_CONFIRMED absent du journal"
grep -q 'EN CLAIR, TOUJOURS ACTIVÉS.*5555' "$W/hl.log" \
  && ok "C7 le play DIT que le clair reste ouvert (il ne laisse pas croire l'inverse)" \
  || ko "C7 le play ne signale pas le port en clair resté ouvert"

# ---- C8 : les deux refus du listener, joués -------------------------------
listener -e apim_hl_port=5543 -e apim_hl_client_auth=require; RC=$?
{ [ "$RC" -ne 0 ] && grep -q 'CLIENT_AUTH_NON_CONVERGEABLE' "$W/hl.log"; } \
  && ok "C8 changer clientAuth sur un port existant est REFUSÉ, en le nommant (mesuré non éditable)" \
  || ko "C8 le play a accepté de changer clientAuth (rc=$RC) — or le PUT rend 200 sans persister"

listener -e apim_hl_port=5543 -e apim_hl_close_plaintext_port=5555; RC=$?
{ [ "$RC" -ne 0 ] && grep -q 'PORT_DE_PILOTAGE' "$W/hl.log"; } \
  && ok "C8 fermer le port de PILOTAGE est refusé (un play qui ne peut plus se relire ne prouve rien)" \
  || ko "C8 le play a tenté de fermer le port par lequel il parle (rc=$RC)"

fi   # LIVE

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "═══ D — les MUTATIONS : ce harnais SAIT rougir ═══"

mutate(){ # mutate <fichier> <sed> <libellé> <commande-qui-doit-rougir>
  local f="$1" expr="$2" label="$3" cmd="$4"
  cp "$f" "$TMP/keep.$$" || { ko "D sauvegarde impossible : $f"; return; }
  sed -i.bak "$expr" "$f" && rm -f "$f.bak"
  if cmp -s "$f" "$TMP/keep.$$"; then
    ko "D mutation SANS EFFET ($label) — l'épreuve ne mesure rien"
  else
    # SOUS-SHELL, et c'est un défaut payé : une commande qui contient `cd`
    # déplaçait le répertoire courant du harnais lui-même, et toutes les
    # mutations SUIVANTES échouaient à sauvegarder leur fichier — en laissant
    # la première mutation en place dans l'arbre de travail. Un harnais de
    # mutation qui ne restaure pas est pire qu'absent.
    if ( eval "$cmd" ) >/dev/null 2>&1; then
      ko "D $label : la mutation passe au VERT — la garde ne tient pas"
    else
      ok "D $label : la mutation vire au ROUGE"
    fi
  fi
  cp "$TMP/keep.$$" "$f"
  cmp -s "$f" "$TMP/keep.$$" && : || ko "D restauration IMPARFAITE de $f"
  rm -f "$TMP/keep.$$"
}

# D1 — la garde que P4 a demandée : déplacer https-only du côté COMMUN doit
# faire tomber l'épreuve de couplage, pas passer inaperçu.
mutate labctl/internal/render/render.go \
  's/^\tPolicyRateLimit: true,$/\tPolicyRateLimit: true,\n\tPolicyHTTPSOnly:  true,/' \
  "https-only déplacée du côté COMMUN (l'arbitrage P4/P5 défait en silence)" \
  "(cd labctl && go test ./internal/render/ -run 'EntryProtocol|CommonHalf' -count=1)"

# D2 — une dérivation qui rend toujours 'https' passerait tous les autres tests,
# puisque toutes les cellules réelles l'exigent. C'est le fail-closed qui doit
# tenir, pas le cas nominal.
mutate labctl/internal/render/render.go \
  's|^\treturn ""$|\treturn EntryProtocolHTTPS|' \
  "EntryProtocolFor rend toujours 'https' (elle cesse de LIRE la moitié per-API)" \
  "(cd labctl && go test ./internal/render/ -run 'EntryProtocolForIsFailClosed' -count=1)"

# D3 — la stricte égalité du read-back. Avec un `in`, une liste ['http','https']
# passerait : l'API porterait le tag d'une posture gouvernée en servant le clair.
mutate "$EPFILE" \
  "s/pub_ep_now == \[pub_ep_wanted\]/pub_ep_wanted in pub_ep_now/" \
  "le read-back accepte l'APPARTENANCE au lieu de l'égalité" \
  "grep -q 'pub_ep_now == \[pub_ep_wanted\]' '$EPFILE'"

# D4 — la POSITION. Poser le protocole après l'activation rouvre la fenêtre où
# une API gouvernée sert en clair.
mutate "$MAINFILE" \
  "s|      ansible.builtin.import_tasks: entry-protocol.yml|      ansible.builtin.import_tasks: version.yml  # muté|" \
  "la tâche de protocole retirée du rôle" \
  "grep -q 'import_tasks: entry-protocol.yml' '$MAINFILE'"

# D5 — l'honnêteté du play de listener. Sans son dernier mot, un vert laisse
# croire que le clair est traité.
mutate "$HLFILE" \
  "s/HTTPS_LISTENER_ETAT/HTTPS_LISTENER_MUET/" \
  "le play de listener cesse de dire ce qui reste ouvert en clair" \
  "grep -q 'HTTPS_LISTENER_ETAT' '$HLFILE'"

# D6 — la promotion allumée par défaut : un geste de topologie non demandé, sur
# un serveur entier.
mutate "$HLDEF" \
  "s/^apim_hl_promote_primary: false/apim_hl_promote_primary: true/" \
  "la promotion en primaire allumée par défaut" \
  "grep -q '^apim_hl_promote_primary: false' '$HLDEF'"

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "═══════════════════════════════════════════════════════════════════════"
printf '  %d ✅ / %d ❌\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
