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

    Même esprit que `analytics.CollectError` : mieux vaut ne rien publier
    qu'une carto mensongère.
    """


def _index_observed(observed_by_window):
    """(apiId, consumerId) -> {"calls": {...}, "errors": {...}, "lastCall": ...}

    Les erreurs sont indexées PAR FENÊTRE depuis le 2026-08-07 (elles ne
    l'étaient que sur d90) : `_unidentified_share` en a besoin sur chacune
    des trois pour ne compter que le trafic servi. `lastCall`, lui, reste
    lu de la seule fenêtre longue — c'est un `_search`, pas un comptage,
    et le payer trois fois n'apprendrait rien de plus.
    """
    idx = {}
    for window, rows in observed_by_window.items():
        for r in rows:
            key = (r["apiId"], r["consumerId"])
            slot = idx.setdefault(key, {"calls": dict(_ZERO),
                                        "errors": dict(_ZERO), "lastCall": None})
            slot["calls"][window] = r.get("calls", 0)
            slot["errors"][window] = r.get("errors", 0)
            if window == "d90":
                slot["lastCall"] = r.get("lastCall")
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


def _check_windows(api_id, con_id, calls, quoi="fenetres"):
    """d7 ⊆ d30 ⊆ d90 : invariant énoncé par analytics.py, dont TOUT dépend ici.

    `lastCall` n'est lu QUE dans la fenêtre longue. Si l'invariant est violé
    (rollover d'index entre les trois requêtes, purge concurrente), on
    produirait sans un mot une arête `d7=980, d90=0` affichée « déclaré,
    inactif », `errorRate 0.0`, `lastCall null` — une carto fausse qui a
    l'air valide. On refuse de publier.

    Appliqué aux appels ET aux erreurs : depuis que le trafic servi
    (appels − erreurs) porte le ratio non identifié, des erreurs non
    emboîtées produiraient un trafic servi négatif sur une fenêtre.

    Corollaire : ce contrôle n'est tenable que parce que les trois requêtes
    partent de la plus courte fenêtre à la plus longue — sinon un appel arrivé
    entre deux requêtes suffirait à faire échouer une collecte saine. Cet ordre
    est explicite dans `__main__.windows_par_duree_croissante()`, qui en porte
    le raisonnement complet. Ne pas le défaire.
    """
    if calls["d7"] <= calls["d30"] <= calls["d90"]:
        return
    raise InconsistentWindows(
        f"{quoi} incoherentes pour ({api_id}, {con_id}) : "
        f"d7={calls['d7']} d30={calls['d30']} d90={calls['d90']} — "
        "l'invariant d7 <= d30 <= d90 est viole (rollover ou purge d'index "
        "entre les trois requetes ?), resultat non publiable")


def _unidentified_share(edges, ghost_consumer_ids, window):
    """Part du trafic SERVI de `window` imputée à un appelant NON IDENTIFIÉ.

    Ce chiffre existe parce qu'un appelant non identifié agrège tout le trafic
    sur un nœud fantôme et fait basculer chaque consommateur réel en « déclaré,
    inactif » : sans lui au contrat de données, rien ne l'annoncerait.

    NE PAS LE LIRE comme « le cas majoritaire attendu ». Cette docstring
    affirmait, sur la foi de TERRAIN V5, que `applicationId` valait `Unknown`
    sur 100 % du trafic authentifié. **Réfuté par la mesure du 2026-08-06** :
    un appel avec `x-Gateway-APIKey`, sur une gateway SANS aucun stage IAM,
    ressort avec son `applicationName` et son `applicationId` renseignés.
    L'identification est native ; une part élevée signale un vrai problème de
    plateforme, pas une fatalité (cf. l'encadré en tête de TERRAIN V5).

    DEUX RÈGLES, toutes deux posées le 2026-08-07 sur mesure de terrain.

    1. Le calcul est fait sur CHAQUE fenêtre, plus sur d90 seule. Sur d90
       seule, un pic d'appels non identifiés pèse 90 jours après que sa cause
       a été corrigée : le 2026-07-30, 803 événements de débris d'une campagne
       d'investigation tenaient le ratio à 99,3 % — donc la publication
       bloquée — alors que les jours récents étaient identifiés à 2/2. Le
       chiffre d90 reste publié (on ne veut pas qu'un trou d'identification
       disparaisse du radar en une semaine) mais il ne décide plus seul :
       `gating_share` lit la fenêtre la plus courte qui porte du trafic.

    2. Seul le trafic SERVI (appels − erreurs) entre dans le calcul. Un appel
       REJETÉ n'a aucun consommateur à perdre : il n'a jamais été le trafic de
       personne. Le compter mélangerait « on ne sait pas qui appelle » et
       « quelqu'un s'est fait refuser » — et suffirait, chez un client, à
       rendre la carto rouge en permanence sur du simple bruit de scan de
       credentials. Ce second signal a déjà sa place : `errorRate` par arête,
       qui reste calculé sur TOUS les appels.

    `None` quand la fenêtre ne porte aucun trafic servi : il n'y a alors rien
    à imputer, et le dire par 0.0 (« tout est identifié ») serait un vert
    obtenu par absence de mesure. C'est `coveredDays` et `gating_share` qui
    portent ce diagnostic-là.
    """
    def servi(e):
        return e["calls"][window] - e["errors"][window]

    total = sum(servi(e) for e in edges)
    if not total:
        return None
    inconnus = sum(servi(e) for e in edges
                   if e["consumerId"] in ghost_consumer_ids)
    return round(inconnus / total, 4)


def gating_share(doc):
    """(fenêtre, part) que doit lire une PORTE de publication — ou (None, None).

    La plus COURTE fenêtre qui porte du trafic servi : c'est la seule qui
    réponde à « la collecte est-elle fiable MAINTENANT », par opposition à
    « l'a-t-elle été sur les 90 derniers jours ».

    Le repli sur les fenêtres plus longues n'est pas cosmétique : sans lui,
    une carto entièrement périmée (aucun appel depuis des semaines, mais un
    passé non identifié) passerait au vert par d7 vide — un trou de mesure lu
    comme un succès. Avec lui, elle reste jugée sur ce qu'elle a de plus
    récent, quelle qu'en soit l'ancienneté.
    """
    par_fenetre = doc.get("unidentifiedCallShareByWindow") or {}
    for nom in ("d7", "d30", "d90"):
        if par_fenetre.get(nom) is not None:
            return nom, par_fenetre[nom]
    return None, None


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
        errors = dict(seen["errors"]) if seen else dict(_ZERO)
        _check_windows(api_id, con_id, calls)
        _check_windows(api_id, con_id, errors, quoi="erreurs")
        total = calls["d90"]
        edges.append({
            "apiId": api_id,
            "consumerId": con_id,
            "declared": key in declared,
            "calls": calls,
            # Par fenêtre, pour que le ratio publié reste RECALCULABLE par son
            # lecteur : sans elles, il faudrait le croire sur parole.
            "errors": errors,
            "lastCall": seen["lastCall"] if seen else None,
            "errorRate": round(errors["d90"] / total, 4) if total else 0.0,
        })

    par_fenetre = {w: _unidentified_share(edges, ghost_consumers, w)
                   for w in ("d7", "d30", "d90")}
    part_d90 = par_fenetre["d90"]

    return {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": generated_at,
        "window": window,
        # À la racine, pas dans `window` : ce n'est pas une propriété de la
        # profondeur temporelle mais de la QUALITÉ de l'imputation du trafic.
        #
        # Le champ scalaire garde son sens historique — la fenêtre longue —
        # et reste TOUJOURS un nombre : c'est ce que lisent le bandeau du
        # rendu et les pages Markdown. Le détail par fenêtre, lui, distingue
        # « rien à imputer » (null) de « tout est identifié » (0.0), et c'est
        # LUI que doit lire une porte de publication, via `gating_share`.
        # `None` (rien à imputer) est donc ramené à 0.0 sur le SEUL champ
        # scalaire, qui est déclaré obligatoirement numérique au contrat. La
        # nuance n'est pas perdue : elle vit dans le détail par fenêtre.
        "unidentifiedCallShare": part_d90 if part_d90 is not None else 0.0,
        "unidentifiedCallShareByWindow": par_fenetre,
        "apis": sorted(apis, key=lambda a: (a["name"] or "").lower()),
        "consumers": sorted(consumers, key=lambda c: (c["name"] or "").lower()),
        "edges": edges,
    }
