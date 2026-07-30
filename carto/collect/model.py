"""model.py — contrat de donnees de la carto et sa validation.

Aucune I/O. Le validateur est ecrit a la main (stdlib seule) : le depot
n'embarque aucune dependance Python, et le job doit tourner sur un serveur
client sans installation.

Role central (spec D8) : ce validateur est la garde qui empeche une collecte
degradee d'ecraser une bonne carto. Il doit donc refuser le vide, pas seulement
le mal forme.
"""
import re

SCHEMA_VERSION = 1
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_WINDOWS = ("d7", "d30", "d90")


def _need(errors, cond, msg):
    if not cond:
        errors.append(msg)


def validate_carto(doc):
    """Retourne la liste des erreurs. Liste vide == document publiable."""
    e = []
    if not isinstance(doc, dict):
        return ["racine : objet attendu"]

    _need(e, doc.get("schemaVersion") == SCHEMA_VERSION,
          f"schemaVersion : {SCHEMA_VERSION} attendu, {doc.get('schemaVersion')!r} recu")
    _need(e, isinstance(doc.get("generatedAt"), str) and doc.get("generatedAt"),
          "generatedAt : horodatage ISO attendu")

    w = doc.get("window")
    if not isinstance(w, dict):
        e.append("window : objet attendu")
    else:
        _need(e, isinstance(w.get("requestedDays"), int), "window.requestedDays : entier attendu")
        _need(e, isinstance(w.get("coveredDays"), int), "window.coveredDays : entier attendu")

    apis, cons, edges = doc.get("apis"), doc.get("consumers"), doc.get("edges")
    _need(e, isinstance(apis, list) and len(apis) > 0,
          "apis : liste non vide attendue (une carto sans API est une collecte ratee)")
    _need(e, isinstance(cons, list), "consumers : liste attendue")
    _need(e, isinstance(edges, list), "edges : liste attendue")
    if e:
        return e

    for i, a in enumerate(apis):
        _need(e, isinstance(a.get("id"), str) and a.get("id"), f"apis[{i}].id : identifiant manquant")
        _need(e, isinstance(a.get("name"), str) and a.get("name"), f"apis[{i}].name : nom manquant")
    for i, c in enumerate(cons):
        _need(e, isinstance(c.get("id"), str) and c.get("id"), f"consumers[{i}].id : identifiant manquant")
        _need(e, isinstance(c.get("name"), str) and c.get("name"), f"consumers[{i}].name : nom manquant")

    api_ids = {a.get("id") for a in apis}
    con_ids = {c.get("id") for c in cons}
    for i, ed in enumerate(edges):
        _need(e, ed.get("apiId") in api_ids, f"edges[{i}] : apiId inconnu {ed.get('apiId')!r}")
        _need(e, ed.get("consumerId") in con_ids, f"edges[{i}] : consumerId inconnu {ed.get('consumerId')!r}")
        _need(e, isinstance(ed.get("declared"), bool), f"edges[{i}].declared : booleen attendu")
        calls = ed.get("calls")
        if not isinstance(calls, dict):
            e.append(f"edges[{i}].calls : objet attendu")
            continue
        for k in _WINDOWS:
            _need(e, isinstance(calls.get(k), int), f"edges[{i}].calls.{k} : entier attendu")
    return e


def validate_history(rows):
    """Retourne la liste des erreurs sur le journal d'evolution."""
    e = []
    if not isinstance(rows, list):
        return ["history : liste attendue"]
    for i, r in enumerate(rows):
        if not isinstance(r, dict):
            e.append(f"history[{i}] : objet attendu")
            continue
        _need(e, isinstance(r.get("date"), str) and _DATE.match(r.get("date") or ""),
              f"history[{i}].date : format AAAA-MM-JJ attendu")
        for k in ("apis", "consumersRegistered", "consumersActive", "calls"):
            _need(e, isinstance(r.get(k), int), f"history[{i}].{k} : entier attendu")
    return e
