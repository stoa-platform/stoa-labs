"""analytics.py — le trafic reellement observe, par agregation.

Principe (spec D3) : UNE agregation cote serveur, aucun evenement unitaire
rapatrie. C'est ce qui rend le job quasi gratuit pour la production et
independant du volume de trafic.

Terms imbriques plutot que multi_terms : portable jusqu'a Elasticsearch 6.

Piege traite ici : un bucket `terms` tronque ne produit pas une carto
incomplete mais une carto FAUSSE — des consommateurs reels y apparaitraient
comme inexistants, et une API vivante comme morte. On echoue donc bruyamment
plutot que de publier ca.

Invariant dont depend carto/collect/build.py : les trois fenetres (d7, d30,
d90) sont produites par la MEME requete, seule la duree change (`now-Nd`).
Ainsi toute paire (api, consommateur) presente dans d7 ou d30 est forcement
presente dans d90 — ne jamais ajouter de filtre supplementaire propre a une
seule fenetre, cela casserait cette garantie.

Cet invariant n'est pas seulement documente : build.py le VERIFIE arete par
arete et refuse de publier s'il est viole (build.InconsistentWindows). Un
rollover d'index ou une purge concurrente entre les trois requetes peut le
rompre sans que ce module y soit pour rien.
"""
import datetime as dt

# constantes mesurees en T0 (carto/TERRAIN.md)
ES_API_FIELD = "apiId"
ES_APP_FIELD = "applicationId"
ES_TIME_FIELD = "creationDate"
ES_STATUS_FIELD = "responseCode"

BUCKET_SIZE = 5000


class TruncatedAggregation(Exception):
    """Les buckets ont ete tronques : le resultat serait faux, pas partiel."""


def aggregation_query(days):
    """Requete d'agregation du trafic sur les `days` derniers jours.

    Structure volontairement identique quelle que soit la fenetre demandee
    (seul `now-{days}d` varie) : c'est ce qui garantit l'invariant dont
    depend build.py (voir docstring du module).
    """
    return {
        "size": 0,
        "query": {"range": {ES_TIME_FIELD: {"gte": f"now-{days}d"}}},
        "aggs": {"api": {
            "terms": {"field": ES_API_FIELD, "size": BUCKET_SIZE},
            "aggs": {"consumer": {
                "terms": {"field": ES_APP_FIELD, "size": BUCKET_SIZE},
                "aggs": {
                    "last": {"max": {"field": ES_TIME_FIELD}},
                    "errors": {"filter": {"range": {ES_STATUS_FIELD: {"gte": 400}}}},
                }}}}},
    }


def oldest_query():
    """Requete du plus vieil evenement de l'index, pour mesurer la
    profondeur reellement couverte (voir covered_window)."""
    return {"size": 0, "aggs": {"oldest": {"min": {"field": ES_TIME_FIELD}}}}


def parse_aggregation(raw):
    """Aplati l'agregation imbriquee api->consumer en lignes plates.

    Echoue bruyamment (TruncatedAggregation) si `sum_other_doc_count > 0`
    a l'un ou l'autre niveau : une agregation tronquee ne donne pas une
    carto incomplete mais une carto FAUSSE (consommateurs reels absents,
    APIs vivantes vues comme mortes) — pire que ne rien publier.
    """
    api_agg = (raw.get("aggregations") or {}).get("api") or {}
    truncated = []
    if api_agg.get("sum_other_doc_count", 0) > 0:
        truncated.append(f"apis (+{api_agg['sum_other_doc_count']} hors buckets)")

    rows = []
    for b in api_agg.get("buckets", []):
        con_agg = b.get("consumer") or {}
        if con_agg.get("sum_other_doc_count", 0) > 0:
            truncated.append(f"consommateurs de {b.get('key')!r}")
        for cb in con_agg.get("buckets", []):
            rows.append({
                "apiId": b.get("key"),
                "consumerId": cb.get("key"),
                "calls": cb.get("doc_count", 0),
                "lastCall": (cb.get("last") or {}).get("value_as_string"),
                "errors": (cb.get("errors") or {}).get("doc_count", 0),
            })

    if truncated:
        raise TruncatedAggregation(
            "agregation tronquee, resultat non publiable : "
            + " ; ".join(truncated)
            + f" — augmenter BUCKET_SIZE (actuellement {BUCKET_SIZE})")
    return rows


def covered_window(raw_oldest, requested_days, now):
    """La profondeur REELLEMENT disponible, jamais celle qu'on a demandee.

    `now` est injecte (pas dt.datetime.now()) pour rester testable et
    deterministe. Les horodatages ES portent des millisecondes
    (ex. "2026-07-30T17:26:17.212Z") : `datetime.fromisoformat` les
    analyse sans probleme une fois le suffixe `Z` normalise en `+00:00`.
    """
    oldest_agg = (raw_oldest.get("aggregations") or {}).get("oldest") or {}
    oldest = oldest_agg.get("value_as_string")
    if not oldest:
        return {"requestedDays": requested_days, "coveredDays": 0, "oldestEvent": None}
    parsed = dt.datetime.fromisoformat(oldest.replace("Z", "+00:00"))
    covered = max(0, min(requested_days, (now - parsed).days))
    return {"requestedDays": requested_days, "coveredDays": covered, "oldestEvent": oldest}
