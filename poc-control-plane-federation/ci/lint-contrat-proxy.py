#!/usr/bin/env python3
"""Le contrat d'allow-list du proxy d'admin couvre-t-il ce que les roles appellent ?

Hors contrat -> 404 (ADR-075). Un appel non declare ne casse donc QU'EN mode
proxy-oauth2, jamais en direct : le defaut est invisible tant qu'on teste en
direct. Ce linter le rend opposable sans gateway.

Sans argument : verifie. `--liste` : imprime l'inventaire des appels.
"""
import os
import re
import sys

import yaml

RACINE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTRAT = os.path.join(RACINE, "gateways/webmethods/admin-proxy/wm-admin-proxy.openapi.yaml")
ROLES = os.path.join(RACINE, "ansible/roles")
PREFIXE = "/rest/apigateway"
BASE = "{{ apim_ss_api_base }}"
yaml_errors = []


def operations_declarees():
    doc = yaml.safe_load(open(CONTRAT, encoding="utf-8"))
    ops = set()
    for chemin, corps in (doc.get("paths") or {}).items():
        for verbe in corps:
            if verbe.lower() in ("get", "put", "post", "delete", "patch"):
                ops.add((verbe.upper(), chemin))
    return ops, doc


def variantes(url):
    """Normalise une URL de tache en un ou plusieurs chemins de contrat.

    - la query string ne fait pas partie du chemin OpenAPI ;
    - `{{ x }}` colle a un segment => segment OPTIONNEL (Jinja conditionnel :
      `/policyActions{{ ('/' ~ id) if id else '' }}` rend les DEUX formes).
    """
    chemin = url[len(BASE):].split("?", 1)[0]
    colle = re.search(r"[^/]\{\{", chemin)
    if colle:
        # Cas collé : le "/" est à l'intérieur du Jinja
        # Remplacer Jinja par "/{id}" pour avoir la bonne forme (not "{id}")
        formes = {re.sub(r"\{\{.*?\}\}", "/{id}", chemin, flags=re.S)}
        # Ajouter aussi la forme sans identifiant
        formes.add(re.sub(r"\{\{.*?\}\}", "", chemin, flags=re.S))
    else:
        # Cas normal : Jinja entre deux segments
        formes = {re.sub(r"\{\{.*?\}\}", "{id}", chemin, flags=re.S)}
    return {PREFIXE + f.rstrip("/") if f != "/" else PREFIXE for f in formes}


def taches_uri(noeud, fichier, sortie):
    """Descend recursivement : les taches vivent sous des block/rescue/always."""
    if isinstance(noeud, list):
        for n in noeud:
            taches_uri(n, fichier, sortie)
    elif isinstance(noeud, dict):
        for cle, val in noeud.items():
            if cle in ("ansible.builtin.uri", "uri") and isinstance(val, dict):
                url = val.get("url", "")
                if isinstance(url, str) and url.startswith(BASE):
                    brut = str(val.get("method", "GET"))
                    methodes = ([m.upper() for m in re.findall(r"'(\w+)'", brut)]
                                if "{{" in brut else [brut.upper()])
                    sortie.append({
                        "methodes": methodes,
                        "url": url,
                        "multipart": val.get("body_format") == "form-multipart",
                        "ou": f"{os.path.relpath(fichier, RACINE)}",
                        "nom": noeud.get("name", "?"),
                    })
            else:
                taches_uri(val, fichier, sortie)


def appels():
    global yaml_errors
    trouves = []
    for dossier, _, fichiers in os.walk(ROLES):
        for f in fichiers:
            if not f.endswith((".yml", ".yaml")):
                continue
            p = os.path.join(dossier, f)
            try:
                doc = yaml.safe_load(open(p, encoding="utf-8"))
            except yaml.YAMLError as e:
                yaml_errors.append((os.path.relpath(p, RACINE), str(e)))
                continue
            taches_uri(doc, p, trouves)
    return trouves


def main():
    global yaml_errors
    declarees, doc = operations_declarees()
    trouves = appels()

    if "--liste" in sys.argv:
        for a in sorted(trouves, key=lambda x: (x["url"], x["methodes"])):
            mp = " [multipart]" if a["multipart"] else ""
            print(f'{"/".join(a["methodes"]):6} {a["url"]}{mp}\n       {a["ou"]} — {a["nom"]}')
        return 0

    manquants, sans_multipart = [], []
    for a in trouves:
        formes = variantes(a["url"])
        if not any((m, f) in declarees for f in formes for m in a["methodes"]):
            manquants.append(("/".join(a["methodes"]), sorted(formes)[0], a["ou"], a["nom"]))
            continue
        if a["multipart"]:
            forme, meth = next((f, m) for f in formes for m in a["methodes"] if (m, f) in declarees)
            op = doc["paths"][forme][meth.lower()]
            rb = op.get("requestBody", {})
            ref = rb.get("$ref", "")
            if ref.startswith("#/"):
                cible = doc
                for seg in ref[2:].split("/"):
                    cible = cible.get(seg, {})
                rb = cible
            if "multipart/form-data" not in (rb.get("content") or {}):
                sans_multipart.append((meth, forme, a["ou"], a["nom"]))

    ko = 0
    if yaml_errors:
        ko = 1
        print(f"✗ {len(yaml_errors)} fichier(s) YAML non parsable :")
        for p, e in sorted(yaml_errors):
            print(f"    {p}\n           {e}")
    if manquants:
        ko = 1
        print(f"✗ {len(manquants)} appel(s) NON DECLARE(S) — 404 a travers le proxy :")
        for m, c, ou, nom in sorted(set(manquants)):
            print(f"    {m:6} {c}\n           {ou} — {nom}")
    if sans_multipart:
        ko = 1
        print(f"✗ {len(sans_multipart)} appel(s) en form-multipart sans requestBody multipart declare :")
        for m, c, ou, nom in sorted(set(sans_multipart)):
            print(f"    {m:6} {c}\n           {ou} — {nom}")
    if not ko:
        print(f"✓ les {len(trouves)} appels des roles sont couverts par le contrat "
              f"({len(declarees)} operations declarees)")
    return ko


if __name__ == "__main__":
    sys.exit(main())
