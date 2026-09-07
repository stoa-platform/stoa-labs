#!/usr/bin/env bash
# scripts/lib/estate.sh — de GET /apis à des LIGNÉES verdictées.
#
# LA LIGNÉE EST L'UNITÉ, PAS LA VERSION. La garde de publication est ∀ sur la
# lignée du nom (apim_publish_api/tasks/version.yml:272-280) : une lignée dont
# UNE version reste en Default est INPUBLIABLE EN BLOC. Grouper par version
# produirait des verdicts localement vrais et globalement faux.
#
# LES TEAMS SE LISENT AU NIVEAU DE L'ENTRÉE apiResponse, jamais dans `api` :
# `apiResponse.api.teams` est NULL sur la 10.15 réelle (mesuré 2026-08-05,
# mocks/webmethods/store.go:42-48).
estate_from_apis(){
  local src="$1" out="$2"
  python3 - "$src" "$out" <<'PY'
import json, re, sys
SYSTEME = {"Administrators", "Default", "API-Gateway-Providers"}
RE_NOM = re.compile(r"^[a-z0-9][a-z0-9-]{1,30}$")
RE_VER = re.compile(r"^[0-9]+\.[0-9]+(\.[0-9]+)?$")

d = json.load(open(sys.argv[1])) or {}
lignees = {}
for r in (d.get("apiResponse") or []):
    api = r.get("api") or {}
    # frère de `api`, jamais dedans — repli sur api.teams seulement s'il est non-null
    teams = r.get("teams") or api.get("teams") or []
    noms = sorted({(t.get("name") or "") for t in teams if t.get("name")})
    reelles = sorted(set(noms) - SYSTEME)
    e = lignees.setdefault(api.get("apiName") or "", {"versions": [], "equipes": set()})
    e["versions"].append({
        "version": api.get("apiVersion") or "",
        "guid": api.get("id") or "",
        # booléen JSON STRICT : absent, null, "true" (chaîne) ou 1 sont INACTIFS
        "isActive": api.get("isActive") is True,
        "teams": noms,
        "_reelles": reelles,
    })
    e["equipes"].update(reelles)

sortie = []
for nom in sorted(lignees):
    e = lignees[nom]
    versions = sorted(e["versions"], key=lambda v: v["version"])
    equipes = sorted(e["equipes"])
    # L'ORDRE DES VERDICTS EST L'ORDRE DE GRAVITÉ : le premier qui matche gagne.
    if not equipes:
        verdict, equipe = "API_NON_APPROPRIEE", None
    elif len(equipes) > 1:
        verdict, equipe = "API_MULTI_EQUIPES", None
    elif not RE_NOM.match(nom):
        verdict, equipe = "NOM_HORS_REGEXP", equipes[0]
    elif any(not RE_VER.match(v["version"]) for v in versions):
        verdict, equipe = "VERSION_HORS_REGEXP", equipes[0]
    elif any(equipes[0] not in v["_reelles"] for v in versions):
        verdict, equipe = "LIGNEE_PARTIELLEMENT_ETRANGERE", equipes[0]
    elif not all(v["isActive"] for v in versions):
        verdict, equipe = "CONTRAT_NON_EXTRACTIBLE_API_INACTIVE", equipes[0]
    else:
        verdict, equipe = "OK", equipes[0]
    for v in versions:
        v.pop("_reelles", None)
    sortie.append({"nom": nom, "equipe": equipe, "verdict": verdict, "versions": versions})

json.dump({"lignees": sortie}, open(sys.argv[2], "w"),
          ensure_ascii=False, indent=2, sort_keys=True)
PY
}
