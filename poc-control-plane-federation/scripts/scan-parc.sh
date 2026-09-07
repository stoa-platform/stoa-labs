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

# ── LES DONNÉES DU PARC COMPOSENT DES CHEMINS DE FICHIER ────────────────────
# Les deux revues précédentes ont cherché l'attaquant du côté de SCAN_OUT.
# Il vient du PARC SCANNÉ : `apiName`, `apiVersion`, l'`id` d'une API et
# l'`id` d'une application sont des chaînes rendues par la gateway, et
# toutes les quatre composent un chemin ici. Mesuré sur ce script AVANT
# correctif, chaque fois avec rc=0 et « inventaire écrit » — donc EN SILENCE :
#
#   apiName='../../PRECIEUX'  ⇒ rm de $SCAN_OUT/contrats/../../PRECIEUX-1.0.0.openapi.yaml
#   apiVersion=$'1.0.0\n../../VICTIME\n' ⇒ le `print` rend TROIS lignes, `read -r`
#       les consomme une par une, la deuxième est `../../VICTIME` NUE : la
#       contrainte de suffixe .openapi.yaml tombe, un fichier arbitraire est effacé
#   application.id='../../…/tmp/x' ⇒ `curl -o "$WORK/appdet/<id>.json"` ÉCRASE un
#       fichier arbitraire HORS de SCAN_OUT — le TROISIÈME côté : le répertoire de
#       TRAVAIL de l'outil, que personne n'avait regardé
#
# `segment_ok` est le prédicat unique : un segment de chemin, jamais `.`,
# jamais `..`, jamais un `/`, jamais un espace ni un caractère de contrôle.
segment_ok(){ case "$1" in ''|.|..|*/*) return 1;; *[!A-Za-z0-9._-]*) return 1;; esac; return 0; }

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
# NUL-délimité, jamais `for AID in $(…)` : le découpage par IFS coupait un id
# porteur d'espace en DEUX identifiants, chacun composant son propre chemin.
while IFS= read -r -d '' AID; do
  segment_ok "$AID" || refus "IDENTIFIANT_HORS_SEGMENT : l'application rendue par la gateway porte l'id '${AID}', qui n'est pas un segment de chemin. Il composerait le chemin d'un fichier de travail : mesuré, un id en '../..' fait ÉCRASER par curl un fichier arbitraire HORS de SCAN_OUT."
  C="$(wm_get "/applications/${AID}" "$WORK/appdet/${AID}.json")"
  [ "$C" = 200 ] || refus "GET_APPLICATION : ${AID} -> HTTP ${C}"
done < <(python3 -c 'import json,sys
for a in (json.load(open(sys.argv[1])).get("applications") or []): sys.stdout.write(str(a.get("id") or "") + "\0")' "$WORK/apps.json")
estate_applications "$WORK/apps.json" "$WORK/appdet" "$WORK/apps-rendu.json" || refus "ESTATE_APPLICATIONS"

# ── gouvernance : le registre CENTRAL tranche, le scan ne déclare rien ───────
# (ADR-076/092, task-7-brief.md, rulings-a-porter.md R2). Sans ce gate, une
# lignée OK mais absente du registre passerait pour publiable — l'apply la
# refuserait CLASSIFICATION_UNGOVERNED, mais le scan aurait déjà déclaré OK.
[ -n "${GOVERNANCE_PATH:-}" ] || refus "GOUVERNANCE_REQUISE : poser GOVERNANCE_PATH (le registre central de classification). Sans lui, le scan déclarerait OK des lignées que l'apply refuse CLASSIFICATION_UNGOVERNED."
[ -r "$GOVERNANCE_PATH" ] || refus "GOUVERNANCE_ILLISIBLE : ${GOVERNANCE_PATH}"
estate_gouvernance "$GOVERNANCE_PATH" "$WORK/lignees.json" "$WORK/lignees-gouv.json" \
  || refus "GOUVERNANCE_PARSE : ${GOVERNANCE_PATH} illisible"
mv "$WORK/lignees-gouv.json" "$WORK/lignees.json"

# ── providers.<env>.yml : un dépôt déclaré par deux équipes ──────────────────
# shellcheck source=scripts/lib/repo-layout.sh
. "$REPO/scripts/lib/repo-layout.sh" || refus "LIB_ABSENTE : repo-layout.sh"
repo_layout_init                     || refus "GIT_SUBDIR_INVALIDE : repo-layout.sh"
[ -n "${GC_PLATFORM_DIR:-}" ] || refus "PLATEFORME_REQUISE : poser GC_PLATFORM_DIR (racine du depot plateforme deja present)"
PROV="${GC_PLATFORM_DIR}/${SUB_PFX}ansible/providers.${ENVIRONMENT}.yml"
[ -r "$PROV" ] || refus "PROVIDERS_MISSING : ${PROV} illisible"
estate_repo_ambigu "$PROV" "$WORK/ambigu.json" || refus "PROVIDERS_PARSE : ${PROV}"

# ── sonde /archive : MESURÉE une fois, jamais en dépendance ──────────────────
# Le contrat du proxy declare le GET mais type sa reponse application/json, et
# aucun export n'a jamais ete joue a travers le proxy. On mesure, on rapporte,
# on n'en depend pas. L'archive porte PassmanData/ et Alias/ : elle ne survit pas.
# NON_MESURE, PAS KO : sans lignée OK, FIRST_GUID est vide et la sonde n'est
# JAMAIS invoquée — écrire « KO » ferait passer une absence de mesure pour un
# échec mesuré. Le champ dit ce qui s'est produit, pas ce qu'on espérait.
ARCHIVE_ZIP=NON_MESURE
FIRST_GUID="$(python3 -c 'import json,sys
for l in json.load(open(sys.argv[1]))["lignees"]:
    if l["verdict"]=="OK" and l["versions"]: print(l["versions"][0]["guid"]); break' "$WORK/lignees.json")"
if [ -n "$FIRST_GUID" ]; then
  segment_ok "$FIRST_GUID" || refus "IDENTIFIANT_HORS_SEGMENT : l'API rendue par la gateway porte l'id '${FIRST_GUID}', qui n'est pas un segment de chemin."
  ARCHIVE_ZIP=KO
  C="$(wm_get "/archive?apis=${FIRST_GUID}" "$WORK/probe.zip")"
  if [ "$C" = 200 ] && [ "$(head -c 4 "$WORK/probe.zip" | od -An -tx1 | tr -d ' \n')" = "504b0304" ]; then
    ARCHIVE_ZIP=OK
  fi
  rm -f "$WORK/probe.zip"
fi

# contrats : apiDefinition de GET /apis/{id}, pour les LIGNÉES OK SEULEMENT.
# Reconstruit à chaque scan : un ancien contrat d'une lignée qui n'est plus OK
# ne doit pas survivre (sinon un verdict dégradé laisse un vert périmé sur disque).
#
# NE JAMAIS `rm -rf` UN RÉPERTOIRE FOURNI PAR L'APPELANT. SCAN_OUT n'est
# validé que non-vide (l.18) : mesuré (fix round 1, constat 1) qu'un
# SCAN_OUT=. avec un fichier personnel dans contrats/ était DÉTRUIT EN
# SILENCE par le `rm -rf` précédent.
#
# CORRECTIF (revue Task 6) : le commentaire d'alors affirmait « on ne
# supprime QUE ce que CE script écrit lui-même » — FAUX. Le motif de
# suppression était `rm -f *.openapi.yaml`, un NOM DE FICHIER, pas une
# preuve de provenance : un fichier personnel nommé notes-perso.openapi.yaml
# PASSE la garde CONTRATS_DIR_ETRANGER ci-dessous (qui ne flaire que le
# suffixe) puis était détruit en silence (mesuré). La PROVENANCE, elle, est
# ce que l'outil vient de RECALCULER : les (nom, version) de chaque lignée
# de $WORK/lignees.json À CE PASSAGE (post-gouvernance), quel que soit leur
# verdict — cet ensemble est fermé et connu, et c'est le seul que ce script
# ait le droit d'effacer avant de le réécrire (les lignées non-OK n'y seront
# de toute façon pas réécrites par la boucle ci-dessous, ce qui nettoie bien
# le contrat périmé d'une lignée dégradée). Un nom absent de cet ensemble —
# notes-perso, ou tout autre fichier étranger nommé comme un contrat — n'est
# JAMAIS touché, quel que soit son suffixe.
mkdir -p "$SCAN_OUT/contrats"
ETRANGER="$(find "$SCAN_OUT/contrats" -mindepth 1 -maxdepth 1 ! -name '*.openapi.yaml' | head -1)"
[ -z "$ETRANGER" ] || refus "CONTRATS_DIR_ETRANGER : ${SCAN_OUT}/contrats contient '${ETRANGER}', qui n'est pas un contrat produit par ce scan (*.openapi.yaml) — rien n'est supprimé, rien n'est écrit. Vider ce répertoire soi-même si son contenu est bien celui d'un scan précédent."
#
# CORRECTIF (vague finale) : la provenance ne suffisait pas — les regexps
# gardaient le VERDICT, jamais le CHEMIN. Cette boucle compose un chemin pour
# TOUTES les lignées, y compris celles dont le nom est précisément ce que la
# regexp vient de refuser : `apiName='../../PRECIEUX'` sortait bien
# NOM_HORS_REGEXP *et* faisait effacer ../../PRECIEUX-1.0.0.openapi.yaml.
# L'outil nommait la faute ET la commettait.
#
# LE CHOIX. Refuser le scan sur un nom hors classe serait le mauvais geste :
# la spec (§5.4) exige qu'AUCUNE des huit situations n'interrompe le run —
# l'outil existe précisément pour inventorier un parc mal nommé. On ÉCARTE
# donc la lignée de l'ensemble à effacer, et on le DIT. Rien n'est perdu :
# l'ensemble des fichiers que ce script peut ÉCRIRE est exactement celui des
# lignées OK, et une lignée OK a forcément passé les deux regexps. Un nom qui
# n'est pas un segment ne peut donc désigner AUCUN contrat écrit par ce
# scan — ne pas l'effacer n'oublie rien, et effacer serait une évasion.
#
# NUL-DÉLIMITÉ, et le nom de fichier ENTIER testé d'un bloc : c'est le seul
# découpage qui ne peut pas transformer UNE valeur en DEUX. Un `read -r` par
# ligne rendait `../../VICTIME` sur sa propre ligne, débarrassée du suffixe
# .openapi.yaml qui était la seule contrainte restante.
while IFS= read -r -d '' NOMFIC; do
  if ! segment_ok "$NOMFIC"; then
    echo "  CONTRAT_NOM_HORS_SEGMENT (ignoré, rien n'est effacé) : '${NOMFIC}'" >&2
    continue
  fi
  rm -f "$SCAN_OUT/contrats/${NOMFIC}"
done < <(python3 -c 'import json,sys
for l in json.load(open(sys.argv[1]))["lignees"]:
    for v in l["versions"]:
        sys.stdout.write("%s-%s.openapi.yaml\0" % (l["nom"], v["version"]))' "$WORK/lignees.json")
# NE PAS piper vers `while read` : sur bash 3.2 sans `lastpipe`, le corps du
# `while` tournerait dans un SOUS-SHELL — le `exit 1` de `refus` n'y tuerait
# que le sous-shell, et le scan continuerait, silencieux, jusqu'à un vert
# menteur (mesuré : le script survit et sort 0). D'où la substitution de
# process `< <(...)`, qui garde le `while` dans le shell courant.
while IFS= read -r -d '' NOM && IFS= read -r -d '' VER && IFS= read -r -d '' GUID; do
  # ICI un refus EST le bon geste, contrairement à la boucle de suppression :
  # cette boucle ne traite que des lignées OK, elle refuse déjà sur un HTTP
  # non-200 et sur une apiDefinition absente (CONTRAT_ABSENT). Un nom, une
  # version ou un GUID hors segment sur une lignée déclarée OK n'est pas une
  # situation du parc : c'est une garde amont qui a cédé.
  if ! segment_ok "$NOM" || ! segment_ok "$VER" || ! segment_ok "$GUID"; then
    refus "CONTRAT_NOM_HORS_SEGMENT : la lignée OK '${NOM}'@'${VER}' (guid '${GUID}') ne compose pas un segment de chemin — rien n'est écrit."
  fi
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
        for v in l["versions"]:
            sys.stdout.write("%s\0%s\0%s\0" % (l["nom"], v["version"], v["guid"]))' "$WORK/lignees.json")

mkdir -p "$SCAN_OUT"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# UNE seule expurgation, celle de la lib (wm_redact_url) : le `sed` vivait ICI
# et NULLE PART ailleurs — d'où un message de refus qui, lui, sortait la base
# BRUTE sur stderr. Le fichier était propre, le log ne l'était pas.
BASE_RED="$(wm_redact_url "$APIM_BASE")"
python3 - "$WORK/lignees.json" "$SCAN_OUT/estate.${ENVIRONMENT}.json" "$WORK/apps-rendu.json" \
  "$SCAN_OUT/contrats" "$SCAN_OUT/rapport.md" "$WORK/ambigu.json" <<PY || refus "ECRITURE : ${SCAN_OUT}/estate.${ENVIRONMENT}.json"
import hashlib, json, os, sys
lig = json.load(open(sys.argv[1]))
apps = json.load(open(sys.argv[3])).get("applications") or []
contrats_dir = sys.argv[4]
ambigu = json.load(open(sys.argv[6])).get("refus") or []

# geste proposé par verdict de refus — relayé dans rapport.md, cf. task-6-brief.md
GESTES = {
    "API_NON_APPROPRIEE": "GW=<gateway> GW_PASS=<mot de passe admin> ./scripts/assign-api-team.sh --team <équipe> <api>",
    "LIGNEE_PARTIELLEMENT_ETRANGERE": "assigner les versions sœurs listées, puis rescanner",
    "API_MULTI_EQUIPES": "arbitrer l'appartenance, puis rescanner",
    "NOM_HORS_REGEXP": "renommer = NOUVELLE publication, pas une migration",
    "VERSION_HORS_REGEXP": "renommer = NOUVELLE publication, pas une migration",
    "CONTRAT_NON_EXTRACTIBLE_API_INACTIVE": "activer au palier, puis rescanner",
    "APP_PROPRIETE_INDIVIDUELLE": "POST /assets/owner avec l'UUID de l'accessProfile",
    "CLASSIFICATION_UNGOVERNED": "declarer (owner, api) dans le registre de gouvernance (GOVERNANCE_PATH), puis rescanner",
    "REPO_AMBIGU": "corriger providers.<env>.yml — aucune equipe ne peut etre choisie sans arbitraire",
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
                 # preflight : le CODE RÉELLEMENT OBSERVÉ, ou DESACTIVE quand
                 # la sonde n'a pas tourné. C'était "OK" EN LITTÉRAL — un
                 # champ de provenance qui affirmait une mesure jamais faite,
                 # y compris sous APIM_PREFLIGHT=off.
                 "sondes": {"preflight": "${WM_PREFLIGHT_CODE}", "apis": 200, "applications": 200,
                            "archive_zip": "${ARCHIVE_ZIP}"}},
  "comptes": {"apis": ${N_APIS}, "applications": ${N_APPS},
              "lignees": len(lig["lignees"]), "troncature": "OK"},
  "lignees": lig["lignees"],
  "applications": apps,
  "refus": [ {"objet": l["nom"], "code": l["verdict"]}
             for l in lig["lignees"] if l["verdict"] != "OK" ] + ambigu,
}
json.dump(doc, open(sys.argv[2], "w"), ensure_ascii=False, indent=2, sort_keys=True)

# rapport.md — une section par refus rencontré (lignées, providers ET
# applications), avec le geste proposé et les objets concernés. Dérivé de
# doc["refus"] (pas re-dérivé de lig["lignees"]) pour que CLASSIFICATION_UNGOVERNED
# et REPO_AMBIGU y apparaissent aussi, sans dupliquer la logique. Rien à
# écrire n'est pas une erreur : un parc entièrement conforme produit un
# rapport qui le dit.
refus_lignees = {}
for r in doc["refus"]:
    refus_lignees.setdefault(r["code"], []).append(r["objet"])
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
