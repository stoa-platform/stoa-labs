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

# estate_applications <liste JSON> <répertoire des détails> <sortie JSON>
#
# AUCUNE VALEUR D'IDENTIFIANT NE TRAVERSE, PAR DÉFAUT-DENY. Le vocabulaire réel
# des identifiers sur la 10.15 est {httpsCertificate, ipAddressRange,
# openIdClaims, token} (mesuré, docs/superpowers/specs/2026-09-03-a6-repli-par
# -pr-design.md point 9 — exactement `ss_ids_now` du rôle apim_selfservice_app,
# main.yml:370-379). Fix round 1 (constat 2) : une PREMIÈRE version de cette
# fonction masquait une liste {apiKey, oauth2Token, jwt, certificate,
# sslCertificate} qui ne correspond à AUCUN de ces noms — décorative sur le
# produit réel, un `token` inconnu de la liste serait tombé dans le `else` et
# sa VALEUR aurait été écrite en clair dans l'inventaire. D'où l'inversion :
# GARDE_VALEUR est une ALLOWLIST de ce qui n'est PAS un secret — seule
# `ipAddressRange` en fait partie (une plage d'IP identifie un réseau, pas un
# secret). Tout type absent de cette liste est masqué, y compris un type
# qu'aucun rôle du dépôt n'a jamais prévu : un identifiant inconnu ne doit
# JAMAIS fuir par défaut.
#
# `accessTokens` (et son `apiAccessKey_credentials.apiAccessKey`, où vit la
# VRAIE clé d'API — pas dans `identifiers`, une deuxième erreur du même
# brief) N'EST NI LU NI ÉCRIT ICI : le mot `accessTokens` n'apparaît nulle
# part dans cette fonction. Une clé d'API n'a de toute façon rien à faire
# dans Git : le manifeste porte le CHEMIN Vault, jamais la valeur.
estate_applications(){
  local src="$1" det="$2" out="$3"
  python3 - "$src" "$det" "$out" <<'PY'
import json, os, sys
GARDE_VALEUR = {"ipAddressRange"}  # tout le reste est masqué, PAR DÉFAUT
liste = json.load(open(sys.argv[1])) or {}
out = []
for a in (liste.get("applications") or []):
    det_p = os.path.join(sys.argv[2], a["id"] + ".json")
    det = (json.load(open(det_p)).get("applications") or [{}])[0] if os.path.exists(det_p) else a
    ownert = det.get("ownerType") or ""
    ids = []
    for i in (det.get("identifiers") or []):
        k = i.get("key") or ""
        if k in GARDE_VALEUR:
            v = i.get("value")
            ids.append({"type": k, "valeurs": v if isinstance(v, list) else [v]})
        else:
            ids.append({"type": k, "valeur":
                        "CLE_MASQUEE_PROPRIETAIRE_UTILISATEUR" if ownert == "user" else "NON_TRANSPORTEE"})
    out.append({
        "nom": det.get("name") or a.get("name") or "", "id": det.get("id") or a.get("id") or "",
        "ownerType": ownert, "owner": det.get("owner") or "",
        "souscriptions": sorted(det.get("consumingAPIs") or []),
        "identifiants": sorted(ids, key=lambda x: x["type"]),
        "verdict": "APP_PROPRIETE_INDIVIDUELLE" if ownert == "user" else "OK",
    })
json.dump({"applications": sorted(out, key=lambda x: x["nom"])},
          open(sys.argv[3], "w"), ensure_ascii=False, indent=2, sort_keys=True)
PY
}

# estate_gouvernance <registre yaml> <lignees.json> <sortie json>
#
# LA POSTURE EST CENTRALE ET OWNER-KEYÉE (ADR-076/092). Le scan ne la DÉCLARE
# jamais — il constate seulement si la ligne (owner, api) existe au registre.
# Une lignée absente est refusée à l'apply (CLASSIFICATION_UNGOVERNED) : la
# rendre OK ici produirait un dépôt mort-né.
estate_gouvernance(){
  python3 - "$1" "$2" "$3" <<'GOUV'
import json, sys, yaml
reg = yaml.safe_load(open(sys.argv[1])) or {}
gouv = {(str(e.get("owner") or ""), str(e.get("api") or "")): e
        for e in (reg.get("apis") or [])}
d = json.load(open(sys.argv[2]))
for l in d["lignees"]:
    if l["verdict"] != "OK":
        continue                      # un verdict plus grave a déjà tranché
    e = gouv.get((l["equipe"] or "", l["nom"]))
    if e is None:
        l["verdict"] = "CLASSIFICATION_UNGOVERNED"
    else:
        l["classification"] = e.get("classification")
        l["exposure"] = e.get("exposure")
json.dump(d, open(sys.argv[3], "w"), ensure_ascii=False, indent=2, sort_keys=True)
GOUV
}

# estate_repo_ambigu <providers.<env>.yml> <sortie json>
#
# Même discipline que team-publish.sh:244 : deux équipes déclarant le MÊME
# dépôt est un conflit qui ne se tranche pas tout seul. On NOMME, on ne
# choisit pas. Le filtre `len(set(ts)) > 1` EST la règle : un dépôt à une
# seule équipe n'est PAS ambigu, et doit rester absent de la sortie (cf. le
# canari grp/apis-legit de scripts/test-scan-parc.sh, section 6 — sans un
# dépôt à équipe unique dans le jeu d'essai, une mutation qui retire ce
# filtre ne rougirait rien).
estate_repo_ambigu(){
  python3 - "$1" "$2" <<'AMBI'
import json, sys, yaml, collections
d = yaml.safe_load(open(sys.argv[1])) or {}
par_repo = collections.defaultdict(list)
for p in (d.get("providers") or []):
    r = (p.get("repo") or "").strip()
    t = (p.get("team") or "").strip()
    if r and t:
        par_repo[r].append(t)
out = [{"objet": r, "code": "REPO_AMBIGU",
        "detail": "declare par " + ", ".join(sorted(set(ts))),
        "geste": "corriger providers.<env>.yml — aucune equipe ne peut etre choisie sans arbitraire"}
       for r, ts in sorted(par_repo.items()) if len(set(ts)) > 1]
json.dump({"refus": out}, open(sys.argv[2], "w"), ensure_ascii=False, indent=2, sort_keys=True)
AMBI
}
