#!/usr/bin/env python3
"""Le contrat d'allow-list du proxy d'admin couvre-t-il ce que les roles appellent ?

Hors contrat -> 404 (ADR-075). Un appel non declare ne casse donc QU'EN mode
proxy-oauth2, jamais en direct : le defaut est invisible tant qu'on teste en
direct. Ce linter le rend opposable sans gateway.

Il verifie DEUX sens, pas un seul :
  - usage ⊆ contrat : tout appel des roles est declare (sinon 404 a la bascule) ;
  - contrat ⊆ politique : AUCUN `delete:` au contrat, sans aucune exception
    (invariant phare d'ADR-075). Une cle de DEROGATIONS couvre un appel de
    role qui contourne le proxy (acces direct, hors chaine CI) — jamais une
    declaration au contrat : les deux sens ne se recouvrent pas.
Ne verifier que le premier sens laissait passer un `delete:` ajoute au contrat
sans appelant — c'est-a-dire exactement la regression que l'invariant interdit.

Sans argument : verifie. `--liste` : imprime l'inventaire des appels.
"""
import os
import re
import sys

import yaml

RACINE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Chemins surchargeables : sans cela le linter n'est testable que contre le vrai
# depot, ce qui a oblige chaque revue a muter des fichiers suivis puis a les
# restaurer a la main. Les defauts restent le depot reel.
CONTRAT = os.environ.get("STOA_LINT_CONTRAT") or os.path.join(
    RACINE, "gateways/webmethods/admin-proxy/wm-admin-proxy.openapi.yaml")
ROLES = os.environ.get("STOA_LINT_ROLES") or os.path.join(RACINE, "ansible/roles")
PREFIXE = "/rest/apigateway"
BASE = "{{ apim_ss_api_base }}"
# Planchers d'inventaire. `os.walk` sur un repertoire absent ne leve RIEN : le
# linter concluait « les 0 appels sont couverts », code 0 — un vert sur du vide.
# Ces planchers sont GROSSIERS a dessein : ils ne figent pas un compte (31
# fichiers / 95 appels a ce jour, et ca monte quand des roles arrivent), ils
# distinguent « inventaire parcouru » de « inventaire absent ou ampute »
# (checkout partiel, ansible/ non monte, repertoire renomme).
MIN_FICHIERS_ROLES = 20
MIN_APPELS = 60
yaml_errors = []

# Derogations ASSUMEES : appels que le contrat n'autorisera JAMAIS. Chaque entree
# porte son motif — une derogation sans motif est un oubli deguise — ET le
# fichier de role qui la porte : une derogation vaut pour l'appelant NOMME au
# motif, pas pour tout appelant futur du meme couple methode/chemin.
#
# Le chemin de la cle est ANCRE SUR ROLES (pas RACINE) : c'est la meme
# convention que le champ "ou" pose par taches_uri(). Ancrer sur RACINE cassait
# des que ROLES etait surcharge hors de RACINE/ansible/roles — le chemin
# devenait un "../../../.." absurde et la derogation ne matchait plus jamais
# (mesure en preparant ce plan).
DEROGATIONS = {
    ("DELETE", "/rest/apigateway/strategies/{id}",
     "apim_selfservice_app/tasks/rotate-strategy.yml"):
        "ADR-075 interdit tout DELETE via le proxy. La rotation d'identifiants "
        "(apim_selfservice_app/tasks/rotate-strategy.yml) reste un geste "
        "d'exploitation en acces direct, hors chaine CI.",
}


def operations_declarees():
    doc = yaml.safe_load(open(CONTRAT, encoding="utf-8"))
    ops = set()
    for chemin, corps in (doc.get("paths") or {}).items():
        for verbe in corps:
            if verbe.lower() in ("get", "put", "post", "delete", "patch"):
                ops.add((verbe.upper(), chemin))
    return ops, doc


def deletes_au_contrat(declarees):
    """Contrat ⊆ politique : ADR-075 n'admet AUCUN DELETE via le proxy.

    Le rollback est un re-apply depuis Git, jamais une suppression. AUCUNE
    exception : une cle de DEROGATIONS couvre un appel de role qui contourne
    le proxy (acces direct, hors chaine CI), pas une declaration au contrat.
    Les deux sens sont distincts — tolerer ici le couple (methode, chemin)
    d'une derogation reviendrait a laisser un `delete:` ajoute au contrat
    sous ce chemin passer au vert, ce que le motif de la derogation exclut
    explicitement.
    """
    return sorted((m, c) for (m, c) in declarees if m == "DELETE")


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
                        "ou": f"{os.path.relpath(fichier, ROLES)}",
                        "nom": noeud.get("name", "?"),
                    })
            else:
                taches_uri(val, fichier, sortie)


def appels():
    global yaml_errors
    trouves, fichiers_vus = [], 0
    for dossier, _, fichiers in os.walk(ROLES):
        for f in fichiers:
            if not f.endswith((".yml", ".yaml")):
                continue
            fichiers_vus += 1
            p = os.path.join(dossier, f)
            try:
                doc = yaml.safe_load(open(p, encoding="utf-8"))
            except yaml.YAMLError as e:
                yaml_errors.append((os.path.relpath(p, ROLES), str(e)))
                continue
            taches_uri(doc, p, trouves)
    return trouves, fichiers_vus


def inventaire_suspect(trouves, fichiers_vus):
    """Un inventaire vide ou ampute doit ECHOUER BRUYAMMENT, pas rendre un vert.

    Sans ce garde, `ROLES` pointant sur un repertoire absent donnait
    « ✓ les 0 appels des roles sont couverts », code 0 : le linter affirmait
    couvrir ce qu'il n'avait meme pas regarde.
    """
    if not os.path.isdir(ROLES):
        return f"repertoire de roles INTROUVABLE : {ROLES}"
    if fichiers_vus < MIN_FICHIERS_ROLES:
        return (f"{fichiers_vus} fichier(s) YAML parcouru(s) sous {ROLES} — "
                f"plancher attendu : {MIN_FICHIERS_ROLES}")
    if len(trouves) < MIN_APPELS:
        return (f"{len(trouves)} appel(s) releve(s) dans les roles — "
                f"plancher attendu : {MIN_APPELS}")
    return None


def main():
    global yaml_errors
    declarees, doc = operations_declarees()
    trouves, fichiers_vus = appels()

    suspect = inventaire_suspect(trouves, fichiers_vus)
    if suspect:
        print("✗ INVENTAIRE ANORMAL — ce linter n'a rien verifie et ne peut RIEN conclure :")
        print(f"    {suspect}")
        print("    Checkout partiel, ansible/ non monte, ou repertoire renomme ?")
        print("    Un vert sur un inventaire vide serait un faux garde-fou : code 2.")
        return 2

    if "--liste" in sys.argv:
        for a in sorted(trouves, key=lambda x: (x["url"], x["methodes"])):
            mp = " [multipart]" if a["multipart"] else ""
            print(f'{"/".join(a["methodes"]):6} {a["url"]}{mp}\n       {a["ou"]} — {a["nom"]}')
        return 0

    manquants, sans_multipart = [], []
    for a in trouves:
        formes = variantes(a["url"])
        couverte = lambda m, f: (m, f) in declarees or (m, f, a["ou"]) in DEROGATIONS
        if len(a["methodes"]) > 1 and len(formes) > 1:
            # Methode ET chemin conditionnels sur le MEME appel (meme conditionnel
            # Jinja, ex. apim_selfservice_app/tasks/backend.yml : `method: "{{ 'PUT'
            # if id else 'POST' }}"` sur `url: .../policyActions{{ ('/' ~ id) if id
            # else '' }}`). La double couverture ci-dessous (chaque forme couverte
            # par au moins une methode, chaque methode par au moins une forme) est
            # satisfaite par l'ANTI-DIAGONALE : declarer (PUT,/policyActions) et
            # (POST,/policyActions/{id}) la satisfait alors que les DEUX branches
            # reelles de l'appel (POST sans id, PUT avec id) tombent en 404.
            # Le linter ne peut pas savoir, depuis le YAML, quelle branche du
            # conditionnel methode va avec quelle branche du conditionnel chemin —
            # les deux gabarits Jinja sont evalues independamment ici. Fail-closed :
            # exiger le produit croisé complet (batir un appariement suppose serait
            # une heuristique fausse un jour, en silence).
            couverture_ok = all(couverte(m, f) for m in a["methodes"] for f in formes)
        else:
            # Un seul axe varie (ou aucun) : la double couverture se reduit deja
            # exactement au produit croisé (verifie : avec un seul element d'un
            # cote, les deux quantificateurs existentiels degenerent en un
            # quantificateur universel sur l'autre cote) — comportement inchange.
            forms_covered = all(any(couverte(m, f) for m in a["methodes"]) for f in formes)
            methods_covered = all(any(couverte(m, f) for f in formes) for m in a["methodes"])
            couverture_ok = forms_covered and methods_covered
        if not couverture_ok:
            manquants.append(("/".join(a["methodes"]), sorted(formes)[0], a["ou"], a["nom"]))
            continue
        if a["multipart"]:
            declare = next(((f, m) for f in formes for m in a["methodes"] if (m, f) in declarees), None)
            if declare is None:
                continue  # couvert uniquement par une derogation : rien a verifier au contrat
            forme, meth = declare
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
    if DEROGATIONS:
        print(f"ℹ {len(DEROGATIONS)} derogation(s) assumee(s) :")
        for (m, c, ou), motif in sorted(DEROGATIONS.items()):
            print(f"    {m:6} {c}\n           {ou}\n           {motif}")
    if yaml_errors:
        ko = 1
        print(f"✗ {len(yaml_errors)} fichier(s) YAML non parsable :")
        for p, e in sorted(yaml_errors):
            print(f"    {p}\n           {e}")
    deletes = deletes_au_contrat(declarees)
    if deletes:
        ko = 1
        print(f"✗ {len(deletes)} DELETE DECLARE(S) AU CONTRAT — ADR-075 n'en admet aucun :")
        for m, c in deletes:
            print(f"    {m:6} {c}\n           le rollback est un re-apply depuis Git, jamais une "
                  f"suppression : retirer du contrat, ou l'assumer en derogation motivee.")
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
        print(f"✓ les {len(trouves)} appels des roles ({fichiers_vus} fichiers parcourus) sont "
              f"couverts par le contrat ({len(declarees)} operations declarees, aucun DELETE)")
    return ko


if __name__ == "__main__":
    sys.exit(main())
