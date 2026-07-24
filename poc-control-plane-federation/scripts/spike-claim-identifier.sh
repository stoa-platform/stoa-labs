#!/usr/bin/env bash
# spike-claim-identifier.sh — La CLAIM d'identification est-elle un PARAMÈTRE,
# et sa rotation peut-elle être SANS COUPURE ? (préalable au provisioning
# self-service piloté par OIG / CLI2 — cf. ADR-078 + mémoire oracle-idp-gateway-sync)
#
# CONTEXTE. Une application wM est reconnue par un identifier
# {key:"openIdClaims", name:<NOM DE LA CLAIM>, value:[<VALEUR>]}. Aujourd'hui le
# nom est `azp` partout ; le rôle Ansible le porte déjà en paramètre
# (apim_ss_auth_claim.name). Mais DEUX choses ne sont pas prouvées :
#   1. la gateway accepte-t-elle un nom de claim ARBITRAIRE (client_id, toto…) ?
#   2. peut-on faire COEXISTER l'ancienne et la nouvelle identité le temps d'une
#      bascule — condition sine qua non d'une migration 0-coupure (ADR-079) ?
# Deux formes de recouvrement sont possibles et testées séparément :
#      (a) DEUX identifiers openIdClaims de NOMS différents (azp + client_id) ;
#      (b) UN identifier openIdClaims portant DEUX VALEURS (rotation de valeur —
#          le cas fréquent : le client de l'IdP change entre envs/rotations).
#
# CE QUE CE SCRIPT PROUVE : le PLAN DE CONTRÔLE (stockage + relecture + rejeu).
# Il ne prouve PAS le matching runtime (un JWT portant la claim est-il bien
# rattaché à l'app ?) — c'est le volet B, cf. « SUITE » en fin de sortie. Volet A
# suffit à TUER le design : si ni (a) ni (b) ne tiennent au stockage, aucune
# bascule sans coupure n'est possible et il faut revoir la stratégie AVANT
# d'écrire le pipeline.
#
# Assets JETABLES (spikeclaim-*), détruits en sortie (trap). Aucune application
# existante n'est lue en écriture ni modifiée.
#
#   GW_ADMIN=http://localhost:5555/rest/apigateway \
#   WM_USER=Administrator WM_PASS=manage ./scripts/spike-claim-identifier.sh
set -u
GW="${GW_ADMIN:-http://localhost:5555/rest/apigateway}"
AUTH="${WM_USER:-Administrator}:${WM_PASS:-manage}"
APP=spikeclaim-app
APP_ID=""
PASS=0; FAIL=0
# Verdicts propagés jusqu'au bloc final (décision GO/NO-GO du volet B).
V_ARBITRARY="?"; V_TWO_NAMES="?"; V_TWO_VALUES="?"; V_ROLE_LOGIC="?"

say()  { printf '\n== %s ==\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko()   { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
info() { printf '  ·  %s\n' "$*"; }
# gap() : ÉCART CONSTATÉ (chaîne de livraison, pas produit). Documenté dans le
# verdict, volontairement HORS du compteur X/X — le spike a fait son travail en
# le révélant ; ce n'est pas une assertion en échec.
gap()  { printf '  ⚠️  ÉCART — %s\n' "$*"; }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else ko "$3 (attendu '$2', obtenu '$1')"; fi; }
adm()  { curl -sS -u "$AUTH" -H "Accept: application/json" "$@"; }

cleanup() {
  say "cleanup (asset jetable)"
  if [ -n "$APP_ID" ]; then
    C=$(adm -o /dev/null -w '%{http_code}' -X DELETE "$GW/applications/$APP_ID")
    info "DELETE application $APP_ID -> HTTP $C"
  fi
}
trap cleanup EXIT

# getApp : le record COMPLET de l'application (enveloppe {applications:[…]} OU plat).
# Le PUT REMPLACE l'objet : on relit, on mute, on renvoie le tout (patron du rôle).
getApp() { adm "$GW/applications/$APP_ID" | jq -c '(.applications[0] // .)'; }

# putIdentifiers <json-array> : relit, remplace le tableau identifiers, PUT.
# Renvoie le code HTTP sur stdout.
putIdentifiers() {
  local ids="$1" rec
  rec=$(getApp | jq -c --argjson ids "$ids" '.identifiers = $ids')
  adm -o /dev/null -w '%{http_code}' -H "Content-Type: application/json" \
      -X PUT "$GW/applications/$APP_ID" -d "$rec"
}

# oidcIds : les identifiers openIdClaims relus, normalisés "<name>=<v1|v2>".
# La gateway renvoie les valeurs tantôt dans .value, tantôt dans .swaggerValue.
oidcIds() {
  getApp | jq -r '[.identifiers[]? | select(.key=="openIdClaims")
                   | .name + "=" + (((.value // .swaggerValue) // []) | sort | join("|"))]
                  | sort | join(" ; ")'
}
oidcCount() { getApp | jq '[.identifiers[]? | select(.key=="openIdClaims")] | length'; }

# ---------------------------------------------------------------- préambule ---
say "préambule : gateway joignable + application jetable"
PING=$(adm -o /dev/null -w '%{http_code}' "$GW/applications")
[ "$PING" = "200" ] || { ko "gateway injoignable sur $GW (HTTP $PING)"; exit 1; }
ok "gateway joignable ($GW)"

# Ne jamais écraser un reliquat d'un run précédent : on réutilise s'il existe.
APP_ID=$(adm "$GW/applications" | jq -r --arg n "$APP" '.applications[]? | select(.name==$n) | .id' | head -1)
if [ -n "$APP_ID" ]; then
  info "reliquat réutilisé ($APP_ID)"
else
  APP_ID=$(adm -H "Content-Type: application/json" -X POST "$GW/applications" \
    -d "{\"name\":\"$APP\",\"description\":\"spike claim identifier (jetable)\",\"contactEmails\":[]}" \
    | jq -r '.id // .application.id // .applications[0].id // empty')
fi
[ -n "$APP_ID" ] || { ko "création de l'application jetable"; exit 1; }
ok "application jetable $APP ($APP_ID)"

# ---- T1 : le NOM de la claim est-il libre, ou la gateway impose-t-elle azp ? --
say "T1 — nom de claim ARBITRAIRE accepté au stockage ?"
C=$(putIdentifiers '[{"key":"openIdClaims","name":"toto","value":["v-toto"]}]')
check "$C" "200" "T1a PUT openIdClaims/toto accepté (HTTP)"
GOT=$(oidcIds)
if [ "$GOT" = "toto=v-toto" ]; then
  ok "T1b relu à l'identique : $GOT"
  V_ARBITRARY="OUI"
else
  ko "T1b relecture inattendue : '$GOT' (attendu 'toto=v-toto')"
  V_ARBITRARY="NON"
fi
info "→ le nom de la claim est bien une DONNÉE, pas une constante produit"

# Un second nom, plus réaliste (celui que l'énoncé client cite) + forme à tirets.
say "T1bis — autres noms de claim (client_id, x-custom-claim)"
for N in client_id x-custom-claim; do
  C=$(putIdentifiers "[{\"key\":\"openIdClaims\",\"name\":\"$N\",\"value\":[\"v-$N\"]}]")
  G=$(oidcIds)
  if [ "$C" = "200" ] && [ "$G" = "$N=v-$N" ]; then ok "T1bis $N accepté et relu"
  else ko "T1bis $N (HTTP $C, relu '$G')"; fi
done

# ---- T2 : LA question décisive — deux NOMS de claim simultanés (recouvrement a)
say "T2 — DEUX identifiers openIdClaims de noms différents coexistent-ils ? [DÉCISIF]"
C=$(putIdentifiers '[{"key":"openIdClaims","name":"azp","value":["v-old"]},
                     {"key":"openIdClaims","name":"client_id","value":["v-new"]}]')
info "PUT deux identifiers -> HTTP $C"
N=$(oidcCount); GOT=$(oidcIds)
info "relu : $N identifier(s) openIdClaims -> $GOT"
if [ "$N" = "2" ]; then
  ok "T2 la gateway STOCKE deux claims de noms différents (recouvrement (a) possible)"
  V_TWO_NAMES="OUI"
else
  ko "T2 la gateway n'en conserve que $N (recouvrement (a) IMPOSSIBLE au stockage)"
  V_TWO_NAMES="NON"
fi

# ---- T3 : deux VALEURS sur une même claim (recouvrement b — rotation de valeur)
say "T3 — UNE claim, DEUX valeurs (rotation de la valeur du client) ?"
C=$(putIdentifiers '[{"key":"openIdClaims","name":"azp","value":["v-old","v-new"]}]')
info "PUT azp=[v-old,v-new] -> HTTP $C"
GOT=$(oidcIds)
if [ "$GOT" = "azp=v-new|v-old" ]; then
  ok "T3 les deux valeurs sont conservées : $GOT (recouvrement (b) possible)"
  V_TWO_VALUES="OUI"
else
  ko "T3 valeurs non conservées : '$GOT' (attendu 'azp=v-new|v-old')"
  V_TWO_VALUES="NON"
fi

# ---- T4 : rejeu — pas de doublon, convergence -------------------------------
say "T4 — rejeu du MÊME record : idempotent, aucun doublon"
BEFORE=$(oidcIds)
putIdentifiers '[{"key":"openIdClaims","name":"azp","value":["v-old","v-new"]}]' >/dev/null
AFTER=$(oidcIds); N=$(oidcCount)
check "$AFTER" "$BEFORE" "T4a état inchangé après rejeu"
check "$N" "1" "T4b toujours un seul identifier (key,name) — pas de duplication"

# ---- T5 : la logique ACTUELLE du rôle Ansible détruit-elle le recouvrement ? --
# Reproduction fidèle de consumer-auth.yml:196 :
#   identifiers = (existants | rejectattr('key','equalto','openIdClaims')) + [nouveau]
# Test de CODE (pas de produit) : même si T2 dit OUI, le rôle n'en laisse qu'un.
say "T5 — logique du rôle (rejectattr openIdClaims) : conserve-t-elle l'ancienne claim ?"
putIdentifiers '[{"key":"openIdClaims","name":"azp","value":["v-old"]},
                 {"key":"ipAddressRange","name":"ip-allowlist","value":["10.0.0.1-10.0.0.1"]}]' >/dev/null
ROLE_RESULT=$(getApp | jq -c '
  [ .identifiers[]? | select(.key != "openIdClaims") ]
  + [ {key:"openIdClaims", name:"client_id", value:["v-new"]} ]')
KEPT=$(printf '%s' "$ROLE_RESULT" | jq '[.[] | select(.key=="openIdClaims")] | length')
SURV=$(printf '%s' "$ROLE_RESULT" | jq -r '[.[] | select(.key!="openIdClaims") | .key] | join(",")')
info "après transformation du rôle : $KEPT claim(s), autres identifiers survivants : ${SURV:-aucun}"
if [ "$KEPT" = "1" ]; then
  gap "T5 le rôle ÉCRASE l'ancienne claim (1 seule survit) — la gateway sait stocker le recouvrement, PAS la chaîne de livraison"
  V_ROLE_LOGIC="ÉCRASE"
else
  ok "T5 le rôle conserve les deux claims"
  V_ROLE_LOGIC="CONSERVE"
fi
[ "$SURV" = "ipAddressRange" ] \
  && ok "T5bis les identifiers NON-openIdClaims (IP/cert) survivent bien à la mutation" \
  || ko "T5bis identifiers non-openIdClaims perdus : '$SURV'"

# ---------------------------------------------------------------- verdict -----
say "VERDICT (plan de contrôle)"
printf '  nom de claim arbitraire accepté ......... %s\n' "$V_ARBITRARY"
printf '  recouvrement (a) 2 NOMS de claim ........ %s\n' "$V_TWO_NAMES"
printf '  recouvrement (b) 2 VALEURS, 1 claim ..... %s\n' "$V_TWO_VALUES"
printf '  logique actuelle du rôle Ansible ........ %s\n' "$V_ROLE_LOGIC"
echo
if [ "$V_TWO_NAMES" = "NON" ] && [ "$V_TWO_VALUES" = "NON" ]; then
  echo "  ⛔ AUCUN recouvrement possible au stockage : une bascule de claim COUPE"
  echo "     le trafic. Ne pas écrire le pipeline avant d'avoir revu la stratégie"
  echo "     (app parallèle ? bascule par archive ADR-079 ? fenêtre de maintenance ?)."
else
  echo "  ▶ SUITE — volet B (opposabilité runtime), à faire avant de conclure :"
  echo "     1. publier une API jetable + stratégie OAUTH2 (alias KeycloakStoaLab)"
  echo "     2. minter un JWT portant la claim custom (mapper KC hardcoded-claim)"
  echo "     3. appeler le data-plane : 200 avec la claim, 403 sans"
  echo "     Le stockage ne prouve PAS le matching — la gateway peut n'évaluer"
  echo "     qu'un seul identifier openIdClaims même si elle en stocke deux."
  if [ "$V_ROLE_LOGIC" = "ÉCRASE" ]; then
    echo "     4. rôle : ajouter claim_rotation: replace|overlap (même patron que"
    echo "        cert_rotation) dans consumer-auth.yml — sinon le produit sait"
    echo "        faire mais la chaîne de livraison, non."
  fi
fi

say "RÉSULTAT : $PASS/$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
