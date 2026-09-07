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

# détail par application : GET /applications/{id}. La liste ne porte pas
# teams/owner/identifiers sur la 10.15 réelle (vrai du mock seulement) — N+1 assumé.
mkdir -p "$WORK/appdet"
for AID in $(python3 -c 'import json,sys; [print(a["id"]) for a in (json.load(open(sys.argv[1])).get("applications") or [])]' "$WORK/apps.json"); do
  C="$(wm_get "/applications/${AID}" "$WORK/appdet/${AID}.json")"
  [ "$C" = 200 ] || refus "GET_APPLICATION : ${AID} -> HTTP ${C}"
done
estate_applications "$WORK/apps.json" "$WORK/appdet" "$WORK/apps-rendu.json" || refus "ESTATE_APPLICATIONS"

# contrats : apiDefinition de GET /apis/{id}, pour les LIGNÉES OK SEULEMENT.
# Reconstruit à chaque scan : un ancien contrat d'une lignée qui n'est plus OK
# ne doit pas survivre (sinon un verdict dégradé laisse un vert périmé sur disque).
rm -rf "$SCAN_OUT/contrats"; mkdir -p "$SCAN_OUT/contrats"
# NE PAS piper vers `while read` : sur bash 3.2 sans `lastpipe`, le corps du
# `while` tournerait dans un SOUS-SHELL — le `exit 1` de `refus` n'y tuerait
# que le sous-shell, et le scan continuerait, silencieux, jusqu'à un vert
# menteur (mesuré : le script survit et sort 0). D'où la substitution de
# process `< <(...)`, qui garde le `while` dans le shell courant.
while read -r NOM VER GUID; do
  C="$(wm_get "/apis/${GUID}" "$WORK/api-${GUID}.json")"
  [ "$C" = 200 ] || refus "GET_API : ${NOM}@${VER} -> HTTP ${C}"
  python3 -c 'import json,sys,yaml
d=json.load(open(sys.argv[1]))["apiResponse"]["api"].get("apiDefinition")
if not d: sys.exit("apiDefinition absente")
yaml.safe_dump(d, open(sys.argv[2],"w"), sort_keys=True, allow_unicode=True)' \
    "$WORK/api-${GUID}.json" "$SCAN_OUT/contrats/${NOM}-${VER}.openapi.yaml" \
    || refus "CONTRAT_ABSENT : ${NOM}@${VER} — apiDefinition vide sur GET /apis/{id}"
done < <(python3 -c 'import json,sys
for l in json.load(open(sys.argv[1]))["lignees"]:
    if l["verdict"]=="OK":
        for v in l["versions"]: print(l["nom"], v["version"], v["guid"])' "$WORK/lignees.json")

mkdir -p "$SCAN_OUT"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BASE_RED="$(printf '%s' "$APIM_BASE" | sed -E 's#://[^[:space:]]*@#://<identifiants masqués>@#g')"
python3 - "$WORK/lignees.json" "$SCAN_OUT/estate.${ENVIRONMENT}.json" "$WORK/apps-rendu.json" \
  "$SCAN_OUT/contrats" "$SCAN_OUT/rapport.md" <<PY || refus "ECRITURE : ${SCAN_OUT}/estate.${ENVIRONMENT}.json"
import hashlib, json, os, sys
lig = json.load(open(sys.argv[1]))
apps = json.load(open(sys.argv[3])).get("applications") or []
contrats_dir = sys.argv[4]

# geste proposé par verdict de refus — relayé dans rapport.md, cf. task-6-brief.md
GESTES = {
    "API_NON_APPROPRIEE": "GW=<gateway> GW_PASS=<mot de passe admin> ./scripts/assign-api-team.sh --team <équipe> <api>",
    "LIGNEE_PARTIELLEMENT_ETRANGERE": "assigner les versions sœurs listées, puis rescanner",
    "API_MULTI_EQUIPES": "arbitrer l'appartenance, puis rescanner",
    "NOM_HORS_REGEXP": "renommer = NOUVELLE publication, pas une migration",
    "VERSION_HORS_REGEXP": "renommer = NOUVELLE publication, pas une migration",
    "CONTRAT_NON_EXTRACTIBLE_API_INACTIVE": "activer au palier, puis rescanner",
    "APP_PROPRIETE_INDIVIDUELLE": "POST /assets/owner avec l'UUID de l'accessProfile",
}

for l in lig["lignees"]:
    if l["verdict"] != "OK":
        continue
    for v in l["versions"]:
        nomfic = "%s-%s.openapi.yaml" % (l["nom"], v["version"])
        chemin = os.path.join(contrats_dir, nomfic)
        if os.path.exists(chemin):
            h = hashlib.sha256(open(chemin, "rb").read()).hexdigest()
            v["contrat"] = {"fichier": "contrats/%s" % nomfic, "sha256": h}

doc = {
  "schema": 1,
  "provenance": {"base": "${BASE_RED}", "env": "${ENVIRONMENT}",
                 "via": "${APIM_EFFECTIVE_VIA}", "scanned_at": "${STAMP}",
                 "sondes": {"preflight": "OK", "apis": 200, "applications": 200,
                            "archive_zip": "NON_MESURE"}},
  "comptes": {"apis": ${N_APIS}, "applications": ${N_APPS},
              "lignees": len(lig["lignees"]), "troncature": "OK"},
  "lignees": lig["lignees"],
  "applications": apps,
  "refus": [ {"objet": l["nom"], "code": l["verdict"]}
             for l in lig["lignees"] if l["verdict"] != "OK" ],
}
json.dump(doc, open(sys.argv[2], "w"), ensure_ascii=False, indent=2, sort_keys=True)

# rapport.md — une section par refus rencontré (lignées ET applications), avec
# le geste proposé et les objets concernés. Rien à écrire n'est pas une erreur :
# un parc entièrement conforme produit un rapport qui le dit.
refus_lignees = {}
for l in lig["lignees"]:
    if l["verdict"] != "OK":
        refus_lignees.setdefault(l["verdict"], []).append(l["nom"])
refus_apps = {}
for a in apps:
    if a.get("verdict", "OK") != "OK":
        refus_apps.setdefault(a["verdict"], []).append(a.get("nom") or a.get("id") or "")

lignes = ["# Rapport de scan — ${ENVIRONMENT} — ${STAMP}", ""]
if not refus_lignees and not refus_apps:
    lignes += ["Aucun refus : le parc scanné est entièrement conforme.", ""]
else:
    lignes += ["## Refus", ""]
    for code in sorted(set(refus_lignees) | set(refus_apps)):
        objets = sorted(refus_lignees.get(code, []) + refus_apps.get(code, []))
        lignes += [
            "### %s" % code,
            "",
            "Geste proposé : %s" % GESTES.get(code, "(geste non répertorié — à documenter)"),
            "",
            "Objets concernés : %s" % ", ".join(objets),
            "",
        ]
open(sys.argv[5], "w").write("\n".join(lignes) + "\n")
PY
echo "inventaire écrit : ${SCAN_OUT}/estate.${ENVIRONMENT}.json (${N_APIS} API(s), ${N_APPS} application(s))"
