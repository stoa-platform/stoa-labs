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


class InconsistentWindows(Exception):
    """Les trois fenêtres se contredisent : le résultat serait FAUX, pas partiel.

    Même esprit que `analytics.TruncatedAggregation` : mieux vaut ne rien
    publier qu'une carto mensongère.
    """


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


# `ghost: True` est le SIGNAL, pas l'étiquette. Le rendu, le journal
# d'évolution et l'annuaire s'appuient sur ce booléen du contrat de données,
# jamais sur le préfixe "(inconnu)" du nom, qui n'est que cosmétique :
# renommer l'étiquette ne doit pas pouvoir vider un signal en silence.
def _ghost_api(api_id):
    return {"id": api_id, "name": f"(inconnu) {api_id}", "version": None,
            "owner": None, "active": False, "createdAt": None, "ghost": True}


def _ghost_consumer(con_id):
    return {"id": con_id, "name": f"(inconnu) {con_id}", "owner": None,
            "contact": None, "createdAt": None, "ghost": True}


def _check_windows(api_id, con_id, calls):
    """d7 ⊆ d30 ⊆ d90 : invariant énoncé par analytics.py, dont TOUT dépend ici.

    `lastCall` et le compte d'erreurs ne sont lus QUE dans la fenêtre longue.
    Si l'invariant est violé (rollover d'index entre les trois requêtes, purge
    concurrente), on produirait sans un mot une arête `d7=980, d90=0` affichée
    « déclaré, inactif », `errorRate 0.0`, `lastCall null` — une carto fausse
    qui a l'air valide. On refuse de publier.
    """
    if calls["d7"] <= calls["d30"] <= calls["d90"]:
        return
    raise InconsistentWindows(
        f"fenetres incoherentes pour ({api_id}, {con_id}) : "
        f"d7={calls['d7']} d30={calls['d30']} d90={calls['d90']} — "
        "l'invariant d7 <= d30 <= d90 est viole (rollover ou purge d'index "
        "entre les trois requetes ?), resultat non publiable")


def _unidentified_share(edges, ghost_consumer_ids):
    """Part des appels de la fenêtre longue imputés à un appelant NON IDENTIFIÉ.

    Terrain mesuré (carto/TERRAIN.md, V5) : `applicationId` vaut `Unknown` sur
    100 % du trafic authentifié de la gateway de mesure. Ce cas est le cas
    MAJORITAIRE attendu, pas un résidu : sans ce chiffre porté au contrat de
    données, tout le trafic s'agrège sur un nœud fantôme, chaque consommateur
    réel bascule en « déclaré, inactif » — et rien ne l'annonce.

    0.0 quand il n'y a aucun appel du tout : il n'y a alors rien à imputer,
    et c'est `coveredDays` qui porte ce diagnostic-là.
    """
    total = sum(e["calls"]["d90"] for e in edges)
    if not total:
        return 0.0
    inconnus = sum(e["calls"]["d90"] for e in edges
                   if e["consumerId"] in ghost_consumer_ids)
    return round(inconnus / total, 4)


def build_carto(apis, consumers, declared, observed_by_window, window, generated_at):
    # `ghost` est posé ici pour TOUS les nœuds : un champ du contrat de
    # données ne doit jamais être seulement parfois présent.
    apis = [dict(a, ghost=False) for a in apis]
    consumers = [dict(c, ghost=False) for c in consumers]
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

    ghost_consumers = {c["id"] for c in consumers if c["ghost"]}

    edges = []
    for key in sorted(set(observed) | set(declared)):
        api_id, con_id = key
        seen = observed.get(key)
        calls = dict(seen["calls"]) if seen else dict(_ZERO)
        _check_windows(api_id, con_id, calls)
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
        # À la racine, pas dans `window` : ce n'est pas une propriété de la
        # profondeur temporelle mais de la QUALITÉ de l'imputation du trafic.
        "unidentifiedCallShare": _unidentified_share(edges, ghost_consumers),
        "apis": sorted(apis, key=lambda a: (a["name"] or "").lower()),
        "consumers": sorted(consumers, key=lambda c: (c["name"] or "").lower()),
        "edges": edges,
    }
