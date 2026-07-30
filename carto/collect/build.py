"""build.py — jointure du déclaré et de l'observé (spec D2).

Le cœur du produit tient dans cette matrice :

                    | trafic observé      | aucun trafic
  déclaré / autorisé| consommateur actif  | onboardé ou en sommeil -> À PRÉVENIR
  non déclaré       | écart de gouvernance| -

Les deux cases non triviales sont invisibles pour l'une ou l'autre source prise
seule. C'est pourquoi les arêtes sont l'UNION des deux, jamais l'intersection.

Aucune I/O. Fonction pure : entrées normalisées -> document carto.json.
"""
from .model import SCHEMA_VERSION

_ZERO = {"d7": 0, "d30": 0, "d90": 0}


def _index_observed(observed_by_window):
    """(apiId, consumerId) -> {"calls": {...}, "lastCall": ..., "errors": n}"""
    idx = {}
    for window, rows in observed_by_window.items():
        for r in rows:
            key = (r["apiId"], r["consumerId"])
            slot = idx.setdefault(key, {"calls": dict(_ZERO), "lastCall": None, "errors": 0})
            slot["calls"][window] = r.get("calls", 0)
            if window == "d90":
                slot["lastCall"] = r.get("lastCall")
                slot["errors"] = r.get("errors", 0)
    return idx


def _ghost_api(api_id):
    return {"id": api_id, "name": f"(inconnu) {api_id}", "version": None,
            "owner": None, "active": False, "createdAt": None}


def _ghost_consumer(con_id):
    return {"id": con_id, "name": f"(inconnu) {con_id}", "owner": None,
            "contact": None, "createdAt": None}


def build_carto(apis, consumers, declared, observed_by_window, window, generated_at):
    apis = list(apis)
    consumers = list(consumers)
    observed = _index_observed(observed_by_window)

    api_ids = {a["id"] for a in apis}
    con_ids = {c["id"] for c in consumers}

    # Du trafic ou une autorisation vers un objet supprimé est un SIGNAL.
    # On fabrique un nœud "(inconnu)" plutôt que de jeter l'arête.
    for api_id, con_id in set(observed) | set(declared):
        if api_id not in api_ids:
            apis.append(_ghost_api(api_id))
            api_ids.add(api_id)
        if con_id not in con_ids:
            consumers.append(_ghost_consumer(con_id))
            con_ids.add(con_id)

    edges = []
    for key in sorted(set(observed) | set(declared)):
        api_id, con_id = key
        seen = observed.get(key)
        calls = dict(seen["calls"]) if seen else dict(_ZERO)
        errors = seen["errors"] if seen else 0
        total = calls["d90"]
        edges.append({
            "apiId": api_id,
            "consumerId": con_id,
            "declared": key in declared,
            "calls": calls,
            "lastCall": seen["lastCall"] if seen else None,
            "errorRate": round(errors / total, 4) if total else 0.0,
        })

    return {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": generated_at,
        "window": window,
        "apis": sorted(apis, key=lambda a: (a["name"] or "").lower()),
        "consumers": sorted(consumers, key=lambda c: (c["name"] or "").lower()),
        "edges": edges,
    }
