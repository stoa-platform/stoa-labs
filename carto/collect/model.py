"""model.py — contrat de donnees de la carto et sa validation.

Aucune I/O. Le validateur est ecrit a la main (stdlib seule) : le depot
n'embarque aucune dependance Python, et le job doit tourner sur un serveur
client sans installation.

Role central (spec D8) : ce validateur est la garde qui empeche une collecte
degradee d'ecraser une bonne carto. Il doit donc refuser le vide, pas seulement
le mal forme.

Regle de perimetre : le validateur garantit TOUT ce que le rendu consomme.
Un champ lu par index.html et non valide ici (`errorRate` affiche en `%`,
`lastCall` affiche comme date, `ghost` qui porte un signal) produit un
`NaN %` ou un signal vide presentes comme des mesures — exactement le
mensonge que ce produit combat.
"""
import re

# Version 2 (2026-07-30) : ajout de DEUX champs OBLIGATOIRES au contrat —
# `ghost` sur chaque noeud (apis[], consumers[]) et `unidentifiedCallShare` a
# la racine. Un document de version 1 ne les porte pas ; lu par la page neuve,
# il degraderait en SILENCE (bloc des objets disparus vide alors qu'il existe
# des fantomes, annuaire qui les reintegre car `!c.ghost` vaut vrai sur
# `undefined`, part non identifiee affichee « inconnue » en gris, sans alerte).
# Ajouter un champ obligatoire au contrat, c'est incrementer ce numero : c'est
# la seule chose qui permette au rendu de refuser au lieu de deviner.
#
# Version 3 (2026-08-07) : deux champs OBLIGATOIRES de plus —
# `unidentifiedCallShareByWindow` a la racine et `errors` par fenetre sur
# chaque arete. Un document de version 2 ne les porte pas ; lu par une porte
# de publication neuve, il ferait taire cette porte au lieu de la faire
# echouer. Les deux existent pour la meme raison, mesuree le 2026-08-07 :
# le ratio calcule sur la SEULE fenetre d90 et sur TOUS les appels condamnait
# la publication 90 jours pour un pic ancien de trafic rejete.
SCHEMA_VERSION = 3
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_WINDOWS = ("d7", "d30", "d90")


def _need(errors, cond, msg):
    if not cond:
        errors.append(msg)


def _is_number(v):
    # bool est un int en Python : True passerait pour un taux valide.
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _is_optional_str(v):
    return v is None or (isinstance(v, str) and bool(v))


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
        # Conserve au contrat (plutot que retire) : c'est la mesure BRUTE
        # derriere `coveredDays`, la seule qui permette de distinguer, en
        # diagnostic, un index tout juste cree d'un index purge.
        _need(e, "oldestEvent" in w and _is_optional_str(w.get("oldestEvent")),
              "window.oldestEvent : horodatage ISO ou null attendu")

    # Part du trafic non imputable a un consommateur identifie (terrain V5 :
    # cas majoritaire attendu). Le bandeau du rendu s'en sert pour alerter :
    # un champ absent ou aberrant rendrait cette alerte muette.
    part = doc.get("unidentifiedCallShare")
    _need(e, _is_number(part) and 0.0 <= part <= 1.0,
          "unidentifiedCallShare : nombre entre 0 et 1 attendu, "
          f"{part!r} recu")

    # Le meme chiffre, fenetre par fenetre — c'est LUI que lit la porte de
    # publication (`build.gating_share`). `null` y signifie « aucun trafic
    # servi sur cette fenetre, rien a imputer », ce qui n'est pas 0.0
    # (« tout est identifie ») : les confondre rendrait un vert obtenu par
    # absence de mesure indiscernable d'un vert merite.
    par_fenetre = doc.get("unidentifiedCallShareByWindow")
    if not isinstance(par_fenetre, dict):
        e.append("unidentifiedCallShareByWindow : objet attendu")
    else:
        for w_nom in _WINDOWS:
            if w_nom not in par_fenetre:
                e.append(f"unidentifiedCallShareByWindow.{w_nom} : fenetre manquante")
                continue
            v = par_fenetre[w_nom]
            _need(e, v is None or (_is_number(v) and 0.0 <= v <= 1.0),
                  f"unidentifiedCallShareByWindow.{w_nom} : nombre entre 0 et 1 "
                  f"ou null attendu, {v!r} recu")

    apis, cons, edges = doc.get("apis"), doc.get("consumers"), doc.get("edges")
    _need(e, isinstance(apis, list) and len(apis) > 0,
          "apis : liste non vide attendue (une carto sans API est une collecte ratee)")
    _need(e, isinstance(cons, list), "consumers : liste attendue")
    _need(e, isinstance(edges, list), "edges : liste attendue")
    if e:
        return e

    # `ghost` : signal porte par la donnee, pas par le libelle. Le rendu,
    # history.py et l'annuaire s'appuient dessus — il doit etre garanti sur
    # CHAQUE noeud, sinon un `undefined` viderait le signal sans un mot.
    for i, a in enumerate(apis):
        _need(e, isinstance(a.get("id"), str) and a.get("id"), f"apis[{i}].id : identifiant manquant")
        _need(e, isinstance(a.get("name"), str) and a.get("name"), f"apis[{i}].name : nom manquant")
        _need(e, isinstance(a.get("ghost"), bool), f"apis[{i}].ghost : booleen attendu")
    for i, c in enumerate(cons):
        _need(e, isinstance(c.get("id"), str) and c.get("id"), f"consumers[{i}].id : identifiant manquant")
        _need(e, isinstance(c.get("name"), str) and c.get("name"), f"consumers[{i}].name : nom manquant")
        _need(e, isinstance(c.get("ghost"), bool), f"consumers[{i}].ghost : booleen attendu")

    api_ids = {a.get("id") for a in apis}
    con_ids = {c.get("id") for c in cons}
    for i, ed in enumerate(edges):
        _need(e, ed.get("apiId") in api_ids, f"edges[{i}] : apiId inconnu {ed.get('apiId')!r}")
        _need(e, ed.get("consumerId") in con_ids, f"edges[{i}] : consumerId inconnu {ed.get('consumerId')!r}")
        _need(e, isinstance(ed.get("declared"), bool), f"edges[{i}].declared : booleen attendu")
        # Consommes tels quels par le rendu : `(errorRate * 100).toFixed(1)`
        # afficherait `NaN %` comme si c'etait une mesure, et le filtre des
        # taux anormaux se taierait.
        rate = ed.get("errorRate")
        _need(e, _is_number(rate) and 0.0 <= rate <= 1.0,
              f"edges[{i}].errorRate : nombre entre 0 et 1 attendu, {rate!r} recu")
        _need(e, "lastCall" in ed and _is_optional_str(ed.get("lastCall")),
              f"edges[{i}].lastCall : horodatage ISO ou null attendu")
        calls = ed.get("calls")
        if not isinstance(calls, dict):
            e.append(f"edges[{i}].calls : objet attendu")
            continue
        for k in _WINDOWS:
            _need(e, isinstance(calls.get(k), int) and not isinstance(calls.get(k), bool),
                  f"edges[{i}].calls.{k} : entier attendu")

        # Les erreurs par fenetre : ce sont elles qui rendent le trafic SERVI
        # (appels moins erreurs), donc le ratio publie, RECALCULABLE par le
        # lecteur du document. Un compte superieur aux appels donnerait un
        # trafic servi negatif — un ratio faux sans rien casser d'autre.
        errors = ed.get("errors")
        if not isinstance(errors, dict):
            e.append(f"edges[{i}].errors : objet attendu")
            continue
        for k in _WINDOWS:
            n = errors.get(k)
            if not (isinstance(n, int) and not isinstance(n, bool) and n >= 0):
                e.append(f"edges[{i}].errors.{k} : entier positif attendu")
            elif isinstance(calls.get(k), int) and n > calls[k]:
                e.append(f"edges[{i}].errors.{k} : {n} erreurs pour {calls[k]} "
                         "appels — le trafic servi serait negatif")
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
