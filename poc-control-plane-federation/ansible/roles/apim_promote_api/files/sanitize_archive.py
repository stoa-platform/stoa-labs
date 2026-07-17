#!/usr/bin/env python3
"""Sanitize d'une archive d'export API Gateway 10.15 (ADR-079).

L'export `GET /archive?apis=` d'une API routée ${alias} EMBARQUE (prouvé au
spike 2026-07-17) :
  - Alias/Alias.<id>       : la VALEUR d'alias de l'env source (endPointURI,
                             creds masquées) -> importée ailleurs, elle CLOBBE
                             la valeur locale de l'env cible ;
  - PassmanData/…          : le secret du credential alias, chiffré avec la clé
                             Passman de l'instance -> du matériel secret dans un
                             artefact versionné, rédhibitoire ;
  - ExportReport.json      : rapport du POST d'origine, inutile à l'import
                             (le set minimal prouvé = APIGatewayAssets.acdl + API/).

Ce script rend l'archive PORTABLE ET SANS SECRET :
  1. whitelist du contenu : API/** + APIGatewayAssets.acdl, tout le reste est jeté ;
  2. purge de l'ACDL (le MANIFESTE de l'import : un asset déclaré dans l'acdl
     mais absent/en conflit fait échouer sa branche de dépendances — prouvé) :
     suppression des <asset name="Alias.*"> / autres types hors whitelist et de
     leurs <dependsOn> ;
  3. fail-closed isActive : refuse une archive dont l'API est isActive:false
     (une telle archive DÉSACTIVE l'API active à l'import — 404 durable, prouvé).

Enfin (option --routing-alias <name>), il RE-POINTE le Straight-Through-Routing
sur `${<name>}/${sys:resource_path}` : l'env d'authoring publie avec un backend
littéral (les `servers:` de l'OpenAPI), mais l'ARTEFACT livré route toujours
par alias — la valeur est posée alias-first par le déployeur de chaque env
(sans ça, l'archive est clouée au backend de l'env source — prouvé).

Usage : sanitize_archive.py <archive.zip> [--routing-alias <name>]
Sortie : JSON {kept, stripped, routing, apis:[{id, name, version, isActive}]}.
"""
import json
import os
import re
import shutil
import sys
import tempfile
import zipfile

KEEP_TYPES = {"API", "Policy", "PolicyAction"}


def rewrite_routing(work: str, alias_name: str):
    """Re-pointe chaque action straightThroughRouting sur ${alias}."""
    want = "${%s}/${sys:resource_path}" % alias_name
    hits = []
    for root, _dirs, files in os.walk(os.path.join(work, "API")):
        for fn in files:
            if not fn.startswith("PolicyAction."):
                continue
            p = os.path.join(root, fn)
            rec = json.load(open(p, encoding="utf-8"))
            if rec.get("templateKey") != "straightThroughRouting":
                continue
            for param in rec.get("parameters", []):
                if param.get("templateKey") == "endpointUri" and param.get("values") != [want]:
                    param["values"] = [want]
                    json.dump(rec, open(p, "w", encoding="utf-8"), indent=2)
                    hits.append(fn)
    return {"alias": alias_name, "rewritten": hits}


def main(path: str, routing_alias: str = "") -> int:
    if not os.path.isfile(path):
        print(json.dumps({"error": f"archive absente: {path}"}))
        return 2
    work = tempfile.mkdtemp(prefix="sanitize079.")
    try:
        with zipfile.ZipFile(path) as z:
            z.extractall(work)

        kept, stripped = [], []
        # 1. whitelist fichiers
        for root, _dirs, files in os.walk(work):
            for fn in files:
                p = os.path.join(root, fn)
                rel = os.path.relpath(p, work)
                top = rel.split(os.sep, 1)[0]
                if rel == "APIGatewayAssets.acdl" or top == "API":
                    kept.append(rel)
                else:
                    stripped.append(rel)
                    os.remove(p)

        # 2. purge acdl : ne garder que les assets des types whitelist
        acdl = os.path.join(work, "APIGatewayAssets.acdl")
        if not os.path.isfile(acdl):
            print(json.dumps({"error": "APIGatewayAssets.acdl absent — pas une archive API Gateway"}))
            return 2
        s = open(acdl, encoding="utf-8").read()
        for m in set(re.findall(r'<asset name="([A-Za-z]+)\.', s)):
            if m not in KEEP_TYPES:
                s = re.sub(
                    r'\s*<asset name="' + re.escape(m) + r'\.[^"]*".*?</asset>', "", s, flags=re.S
                )
                s = re.sub(r'\s*<asset name="' + re.escape(m) + r'\.[^"]*"[^>]*/>', "", s)
                s = re.sub(
                    r"\s*<dependsOn>APIGateway:" + re.escape(m) + r"\.[^<]*</dependsOn>", "", s
                )
                stripped.append(f"acdl:{m}.*")
        open(acdl, "w", encoding="utf-8").write(s)

        # 2b. routing -> ${alias} (l'artefact livré est TOUJOURS alias-routé)
        routing = rewrite_routing(work, routing_alias) if routing_alias else {}

        # 3. fail-closed isActive + inventaire des GUID (l'id-map de l'archive)
        apis = []
        api_dir = os.path.join(work, "API")
        if os.path.isdir(api_dir):
            for entry in sorted(os.listdir(api_dir)):
                rec_path = os.path.join(api_dir, entry, entry)
                if not os.path.isfile(rec_path):
                    continue
                rec = json.load(open(rec_path, encoding="utf-8"))
                apis.append(
                    {
                        "id": rec.get("id"),
                        "name": rec.get("apiName"),
                        "version": rec.get("apiVersion"),
                        "isActive": rec.get("isActive"),
                    }
                )
        if not apis:
            print(json.dumps({"error": "aucun asset API dans l'archive"}))
            return 2
        inactive = [a for a in apis if not a["isActive"]]
        if inactive:
            print(
                json.dumps(
                    {
                        "error": "ARCHIVE_INACTIVE : isActive:false — l'import DÉSACTIVERAIT l'API "
                        "(piège prouvé, ADR-079). Ré-exporter depuis l'état actif.",
                        "apis": apis,
                    }
                )
            )
            return 3

        # re-zip en place (entrées à la racine, comme l'export produit)
        tmp_zip = path + ".sanitized"
        with zipfile.ZipFile(tmp_zip, "w", zipfile.ZIP_DEFLATED) as z:
            z.write(acdl, "APIGatewayAssets.acdl")
            for root, _dirs, files in os.walk(api_dir):
                for fn in files:
                    p = os.path.join(root, fn)
                    z.write(p, os.path.relpath(p, work))
        shutil.move(tmp_zip, path)
        print(json.dumps({"kept": kept, "stripped": stripped, "routing": routing, "apis": apis}))
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    alias = ""
    if "--routing-alias" in sys.argv:
        alias = sys.argv[sys.argv.index("--routing-alias") + 1]
    sys.exit(main(sys.argv[1], alias))
