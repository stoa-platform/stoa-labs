"""history.py — le journal d'évolution de la plateforme (spec D6).

Une ligne compacte par passage, quelques centaines d'octets. L'agrégation
hebdomadaire est faite à l'AFFICHAGE, pas ici : history.json garde la vérité
brute quotidienne, le rendu la lisse.

Toutes les grandeurs sont des STOCKS mesurés à une date (y compris `calls`,
qui est le total sur la fenêtre glissante à cette date). Conséquence pour le
rendu : une semaine se résume par sa DERNIÈRE valeur, jamais par une somme.
"""


def counters(carto):
    """Extrait les compteurs du document carto.

    Retourne un dictionnaire avec les clés :
    - date : date de la collecte (YYYYMMDD)
    - apis : nombre d'APIs dans le graphe
    - consumersRegistered : nombre total de consommateurs enregistrés
    - consumersActive : nombre de consommateurs ayant appelé au moins une API (d90 > 0)
    - calls : total des appels sur la fenêtre d90
    """
    active = {e["consumerId"] for e in carto["edges"] if e["calls"]["d90"] > 0}
    return {
        "date": carto["generatedAt"][:10],
        "apis": len(carto["apis"]),
        "consumersRegistered": len(carto["consumers"]),
        "consumersActive": len(active),
        "calls": sum(e["calls"]["d90"] for e in carto["edges"]),
    }


def append_history(rows, row):
    """Ajoute ou remplace un point du journal.

    Idempotent sur la date : si un point existe déjà pour cette date, le remplace
    au lieu de le dupliquer. Cela permet à un job relancé après échec le même jour
    de corriger son point au lieu d'en créer un second.

    Les lignes du résultat sont toujours triées par date croissante.
    """
    kept = [r for r in rows if r.get("date") != row["date"]]
    kept.append(row)
    return sorted(kept, key=lambda r: r["date"])
