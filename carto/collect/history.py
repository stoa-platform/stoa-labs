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
    - apis : nombre d'APIs ENREGISTRÉES dans l'inventaire
    - consumersRegistered : nombre de consommateurs ENREGISTRÉS
    - consumersActive : nombre de consommateurs enregistrés ayant appelé au
      moins une API (d90 > 0)
    - calls : total des appels sur la fenêtre d90, fantômes COMPRIS

    Les nœuds `ghost` (identifiant vu dans le trafic mais absent de
    l'inventaire : objet supprimé, ou appelant non identifié) sont exclus des
    trois comptages d'objets : un objet inconnu n'est pas un objet enregistré,
    et la courbe d'évolution hériterait sinon d'un gonflement permanent. Ils
    restent comptés dans `calls`, qui mesure du TRAFIC, lequel a bien eu lieu.
    """
    apis = [a for a in carto["apis"] if not a.get("ghost")]
    consumers = [c for c in carto["consumers"] if not c.get("ghost")]
    registered = {c["id"] for c in consumers}
    active = {e["consumerId"] for e in carto["edges"]
              if e["calls"]["d90"] > 0 and e["consumerId"] in registered}
    return {
        "date": carto["generatedAt"][:10],
        "apis": len(apis),
        "consumersRegistered": len(consumers),
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
