#!/usr/bin/env bash
# scan-parc.sh — INVENTAIRE, EN LECTURE SEULE, d'un parc webMethods 10.15.
# N'écrit RIEN sur la gateway, rien sur la forge. Produit $SCAN_OUT/estate.<env>.json.
#
# LA GARDE DE TRONCATURE. Rien ne prouve que GET /apis rende le parc complet :
# aucun appelant du dépôt ne pagine, et toutes les mesures live portent sur
# ~10 APIs. Sur une instance de banque, un fournisseur entier peut manquer EN
# SILENCE — et un group-by sur une liste tronquée ment sans rien signaler.
# D'où SCAN_PARC_ATTENDU, EXIGÉ, sans défaut.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
refus(){ echo "REFUS: $*" >&2; exit 1; }

. "$REPO/scripts/lib/apim-base.sh"     || refus "LIB_ABSENTE : scripts/lib/apim-base.sh"
. "$REPO/scripts/lib/wm-admin-curl.sh" || refus "LIB_ABSENTE : scripts/lib/wm-admin-curl.sh"
. "$REPO/scripts/lib/estate.sh"        || refus "LIB_ABSENTE : scripts/lib/estate.sh"

SCAN_OUT="${SCAN_OUT:?SCAN_OUT requis (répertoire de sortie)}"
[ -n "${SCAN_PARC_ATTENDU:-}" ] || refus "SCAN_PARC_ATTENDU_REQUIS : poser SCAN_PARC_ATTENDU=<apis>:<applications>, relevé EN CONSOLE par l'ops. Sans contre-compte, une liste tronquée passerait pour un parc complet."
case "$SCAN_PARC_ATTENDU" in
  [0-9]*:[0-9]*) ;; *) refus "SCAN_PARC_ATTENDU_INVALIDE : '${SCAN_PARC_ATTENDU}' — attendu <entier>:<entier>";;
esac
ATT_APIS="${SCAN_PARC_ATTENDU%%:*}"; ATT_APPS="${SCAN_PARC_ATTENDU##*:}"

apim_base_resolve || exit 1
wm_preflight      || exit 1
wm_admin_init     || exit 1
WORK="$(mktemp -d)"; trap 'wm_admin_cleanup; rm -rf "$WORK"' EXIT

C="$(wm_get /apis "$WORK/apis.json")"
[ "$C" = 200 ] || { [ "$C" = 401 ] && wm_diag_401 "$WORK/apis.json"; refus "GET_APIS : HTTP ${C}"; }
N_APIS="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("apiResponse") or []))' "$WORK/apis.json")"
[ "$N_APIS" = "$ATT_APIS" ] || refus "PARC_POSSIBLEMENT_TRONQUE : ${N_APIS} API(s) rendue(s), ${ATT_APIS} attendue(s). Un inventaire partiel qui a l'air complet est le pire produit possible : vérifier le compte en console, ou la pagination de la gateway."

C="$(wm_get /applications "$WORK/apps.json")"
[ "$C" = 200 ] || refus "GET_APPLICATIONS : HTTP ${C}"
N_APPS="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("applications") or []))' "$WORK/apps.json")"
[ "$N_APPS" = "$ATT_APPS" ] || refus "PARC_POSSIBLEMENT_TRONQUE : ${N_APPS} application(s) rendue(s), ${ATT_APPS} attendue(s)."

estate_from_apis "$WORK/apis.json" "$WORK/lignees.json" || refus "ESTATE_RENDU : lecture de GET /apis"

mkdir -p "$SCAN_OUT"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BASE_RED="$(printf '%s' "$APIM_BASE" | sed -E 's#://[^[:space:]]*@#://<identifiants masqués>@#g')"
python3 - "$WORK/lignees.json" "$SCAN_OUT/estate.${ENVIRONMENT}.json" <<PY || refus "ECRITURE : ${SCAN_OUT}/estate.${ENVIRONMENT}.json"
import json, sys
lig = json.load(open(sys.argv[1]))
doc = {
  "schema": 1,
  "provenance": {"base": "${BASE_RED}", "env": "${ENVIRONMENT}",
                 "via": "${APIM_EFFECTIVE_VIA}", "scanned_at": "${STAMP}",
                 "sondes": {"preflight": "OK", "apis": 200, "applications": 200,
                            "archive_zip": "NON_MESURE"}},
  "comptes": {"apis": ${N_APIS}, "applications": ${N_APPS},
              "lignees": len(lig["lignees"]), "troncature": "OK"},
  "lignees": lig["lignees"],
  "applications": [],
  "refus": [ {"objet": l["nom"], "code": l["verdict"]}
             for l in lig["lignees"] if l["verdict"] != "OK" ],
}
json.dump(doc, open(sys.argv[2], "w"), ensure_ascii=False, indent=2, sort_keys=True)
PY
echo "inventaire écrit : ${SCAN_OUT}/estate.${ENVIRONMENT}.json (${N_APIS} API(s), ${N_APPS} application(s))"
