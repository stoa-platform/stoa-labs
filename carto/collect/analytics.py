"""analytics.py — le trafic reellement observe, par l'API PUBLIQUE de la gateway.

Refonte du 2026-07-31 : ce module interrogeait l'Elasticsearch interne de la
gateway (`WM_ES_URL` / `WM_ES_INDEX`). Il passe desormais par le CONTRAT de la
gateway, `GET /transactionalEvents/_count` et `_search`. Deux dependances
disparaissent, aucune n'est ajoutee.

Pourquoi : l'Elasticsearch est le MAGASIN INTERNE de la gateway, pas son
contrat. On l'a paye trois fois (nom d'index piegeux, noms de champs a
deviner, syntaxe `${...}` ambigue), et surtout une NetworkPolicy du cluster
n'autorise cet Elasticsearch que depuis les pods de la gateway : un agent de
CI ne l'atteindra jamais, ni au labo ni chez un client.

Principe de collecte (spec D3, conserve) : QUE DES COMPTAGES. Aucun evenement
unitaire n'est rapatrie pour mesurer un volume. Le cout est borne par la
CONFIGURATION (nombre d'APIs, nombre d'applications), jamais par le volume de
trafic :

    3 x (nb_apis + nb_applications)      volumes des trois fenetres
  +     (nb_apis + nb_applications)      volumes en succes (fenetre longue)
  +     nb_aretes_observees              date du dernier appel (`_search` size=1)
  +     ~26                              profondeur reellement couverte
  +     1                                sonde du parametre `status`

Trois pieges mesures sur la vraie gateway, traites explicitement ici :

1. Quand rien ne correspond, `_count` ne renvoie PAS une liste vide mais une
   CHAINE : `{"count":" No records found."}`. Un `for row in reponse["count"]`
   itererait sur les caracteres de cette chaine et fabriquerait des lignes de
   trafic a partir de lettres. `parse_count` teste le type, pas le texte.
2. Les parametres `apiName` / `applicationName` sont interpretes comme des
   EXPRESSIONS REGULIERES ancrees (mesure : `carto-probe` ne matche pas
   `carto-probe-api`, `carto.*` si). Un nom d'application porteur d'un
   metacaractere matcherait autre chose que lui-meme : `escape_regex` est
   obligatoire sur toute valeur qui doit valoir pour elle-meme.
3. `applicationId` ne matche PAS la valeur `Unknown` reellement ecrite par la
   gateway (le point d'entree met la valeur en minuscules avant d'interroger un
   champ `keyword` strict), alors que `applicationName` la matche. La dimension
   consommateur passe donc par le NOM, jamais par l'identifiant.

Invariant dont depend build.py — d7 ⊆ d30 ⊆ d90 — desormais vrai PAR
CONSTRUCTION et non plus par discipline d'ordonnancement : toutes les requetes
d'une meme collecte partagent la MEME borne haute figee (`toDate`), reculee de
`MARGE_DE_FRAICHEUR`. Un appel qui arrive pendant la sequence n'est vu par
AUCUNE des requetes, au lieu d'etre vu par celles envoyees apres lui. C'est
aussi ce qui rend le residu (trafic non attribue) non negatif par construction.
build.py verifie quand meme l'invariant arete par arete : cette garantie-la ne
doit pas dependre d'un seul module.
"""
import datetime as dt

# --- constantes mesurees le 2026-07-31 (carto/TERRAIN.md) -----------------
COUNT_PATH = "/transactionalEvents/_count"
SEARCH_PATH = "/transactionalEvents/_search"

# Format de date accepte par les deux routes (mesure ; le Swagger n'annonce
# que `YYYY-MM-DD`, la seconde est acceptee et utile).
DATE_FORMAT = "%Y-%m-%d %H:%M:%S"

# Expression reguliere qui matche tout : sert a poser un filtre quand on n'en
# veut aucun. La gateway REFUSE une requete qui ne porte que des dates
# (`Insufficient parameters`), et `*` seul n'est pas une regex valide.
MATCH_ALL = ".*"

# `status` n'est PAS documente dans le Swagger de la gateway, mais il filtre
# reellement (mesure). C'est la seule facon bornee d'obtenir un taux d'erreur :
# `_count` ne sait pas compter les echecs autrement. Un parametre inconnu est
# ignore EN SILENCE par ce point d'entree (mesure : `zzzbogus=...` ne change
# rien au resultat) — donc si ce parametre disparaissait a une montee de
# version, les succes vaudraient le total et le taux d'erreur serait
# silencieusement nul partout. D'ou la sonde `_sonde_du_filtre_statut`.
STATUS_PARAM = "status"
STATUS_OK = "SUCCESS"
STATUS_SENTINELLE = "carto-sonde-statut-qui-n-existe-pas"

# Valeur reellement ecrite par la gateway quand elle n'identifie pas
# l'appelant (TERRAIN V5 : 100 % du trafic sur la gateway de mesure).
# Sert d'identifiant du consommateur fantome qui porte le trafic residuel.
UNIDENTIFIED_CONSUMER_ID = "Unknown"

# Borne haute reculee de 60 s. Le magasin d'evenements de la gateway n'est pas
# immediatement coherent (rafraichissement differe). En excluant la derniere
# minute, toutes les requetes d'une collecte voient EXACTEMENT le meme jeu
# d'evenements : c'est ce qui rend les soustractions (residu, erreurs) exactes
# au lieu d'approximativement justes.
MARGE_DE_FRAICHEUR = dt.timedelta(seconds=60)

# Metacaracteres de la syntaxe d'expression reguliere du magasin d'evenements.
_METACARACTERES = '.?+*|{}[]()"\\#@&<>~'

# Profondeur de la recherche dichotomique de l'evenement le plus ancien :
# on s'arrete quand l'encadrement fait moins d'une seconde.
_PRECISION_DICHOTOMIE = dt.timedelta(seconds=1)
# --------------------------------------------------------------------------


class CollectError(Exception):
    """Racine des refus de ce module. Meme esprit que build.InconsistentWindows :
    mieux vaut ne rien publier qu'une carto mensongere."""


class GatewayError(CollectError):
    """La gateway a repondu une erreur, ou une forme qu'on ne sait pas lire."""


class FilterIgnored(CollectError):
    """Le parametre `status` n'est plus honore : le taux d'erreur serait faux."""


class UnusableConsumerName(CollectError):
    """Un nom d'application rend la dimension consommateur non fiable."""


class InconsistentCounts(CollectError):
    """Les comptages se contredisent : le residu serait negatif."""


# --- outillage pur --------------------------------------------------------

def escape_regex(valeur):
    """Rend une valeur litterale dans un parametre interprete comme regex.

    Sans cela, une application nommee `paie.v2` matcherait aussi `paieXv2`, et
    une application nommee `a+` ne matcherait rien du tout — dans les deux cas
    une carto fausse, pas une carto incomplete.
    """
    return "".join("\\" + c if c in _METACARACTERES else c for c in str(valeur))


def format_date(moment):
    return moment.strftime(DATE_FORMAT)


def window_params(now, days):
    """Bornes d'une fenetre. La borne haute est FIGEE et commune a toute la
    collecte (voir MARGE_DE_FRAICHEUR et la docstring du module)."""
    fin = now - MARGE_DE_FRAICHEUR
    return {"fromDate": format_date(fin - dt.timedelta(days=days)),
            "toDate": format_date(fin)}


def _refuser_si_erreur(raw):
    if not isinstance(raw, dict):
        raise GatewayError(f"reponse inattendue de la gateway : {type(raw).__name__}")
    if "errorDetails" in raw:
        raise GatewayError(f"la gateway a refuse la requete :{raw['errorDetails']}")


def parse_count(raw):
    """Reponse de `_count` -> {apiId: nombre d'appels}.

    PIEGE MAJEUR MESURE : quand rien ne correspond, `count` vaut la CHAINE
    `" No records found."` et non une liste vide. Un appelant qui itererait
    dessus fabriquerait une ligne de trafic par caractere. On teste donc le
    TYPE de la charge utile, jamais son texte : un libelle traduit ou
    reformule a une montee de version ne doit pas transformer un « rien » en
    donnees.
    """
    _refuser_si_erreur(raw)
    charge = raw.get("count")
    if charge is None or isinstance(charge, str):
        return {}
    if not isinstance(charge, list):
        raise GatewayError(f"_count : liste ou chaine attendue, {type(charge).__name__} recu")
    out = {}
    for ligne in charge:
        if not isinstance(ligne, dict):
            raise GatewayError(f"_count : objet attendu dans `count`, {ligne!r} recu")
        api_id, n = ligne.get("apiId"), ligne.get("count")
        if not isinstance(api_id, str) or not api_id:
            raise GatewayError(f"_count : apiId manquant dans {ligne!r}")
        if not isinstance(n, int) or isinstance(n, bool):
            raise GatewayError(f"_count : compteur entier attendu dans {ligne!r}")
        out[api_id] = out.get(api_id, 0) + n
    return out


def parse_search(raw):
    """Reponse de `_search` -> liste d'evenements.

    Forme differente de `_count` (mesure) : l'absence de resultat donne bien
    une liste vide, `{"transaction": []}`. Ne pas unifier les deux lectures
    « pour faire propre » : ce sont deux formes reellement differentes.
    """
    _refuser_si_erreur(raw)
    evenements = raw.get("transaction")
    if evenements is None:
        return []
    if not isinstance(evenements, list):
        raise GatewayError(
            f"_search : liste attendue dans `transaction`, {type(evenements).__name__} recu")
    return evenements


def to_iso(millis):
    """`creationDate` est un entier en MILLISECONDES depuis l'epoque (mesure),
    pas une chaine ISO comme le donnait l'agregation Elasticsearch."""
    if not isinstance(millis, (int, float)) or isinstance(millis, bool):
        return None
    moment = dt.datetime.fromtimestamp(millis / 1000.0, dt.timezone.utc)
    return moment.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def consumers_by_name(consumers):
    """{nom d'application -> identifiant}, la dimension consommateur passant
    par le NOM (piege 3 de la docstring du module).

    Trois refus francs plutot qu'une carto fausse :
      - nom vide : l'application ne peut pas etre interrogee, son trafic
        basculerait en silence dans le residu « non identifie » ;
      - doublon de nom : le filtre est INSENSIBLE A LA CASSE (mesure), donc
        `Paie` et `paie` repondent le meme comptage, qui serait compte deux
        fois ;
      - nom reserve `Unknown` : c'est la valeur que la gateway ecrit quand
        elle n'identifie pas l'appelant. Une application qui porterait ce nom
        absorberait tout le trafic anonyme et la carto affirmerait qu'elle en
        est l'auteur.
    """
    par_nom = {}
    for c in consumers:
        nom = c.get("name")
        if not isinstance(nom, str) or not nom.strip():
            raise UnusableConsumerName(
                f"application {c.get('id')!r} sans nom : la gateway ne s'interroge "
                "que par nom d'application, son trafic serait compte comme non identifie")
        clef = nom.strip().lower()
        if clef == UNIDENTIFIED_CONSUMER_ID.lower():
            raise UnusableConsumerName(
                f"application nommee {nom!r} : c'est la valeur que la gateway ecrit "
                "quand elle n'identifie PAS l'appelant — impossible de distinguer "
                "son trafic du trafic anonyme, resultat non publiable")
        if clef in par_nom:
            raise UnusableConsumerName(
                f"deux applications portent le nom {nom!r} (le filtre de la gateway "
                "est insensible a la casse) : leur trafic serait compte deux fois")
        par_nom[clef] = (nom, c.get("id"))
    return {nom: ident for nom, ident in par_nom.values()}


def covered_window(oldest_iso, requested_days, now):
    """La profondeur REELLEMENT disponible, jamais celle qu'on a demandee.

    `now` est injecte (pas `dt.datetime.now()`) pour rester testable et
    deterministe. `oldest_iso` vient de `oldest_event()`, qui l'etablit par
    l'API publique de la gateway et non plus par une agregation `min` sur
    l'Elasticsearch interne.
    """
    if not oldest_iso:
        return {"requestedDays": requested_days, "coveredDays": 0, "oldestEvent": None}
    parsed = dt.datetime.fromisoformat(oldest_iso.replace("Z", "+00:00"))
    covered = max(0, min(requested_days, (now - parsed).days))
    return {"requestedDays": requested_days, "coveredDays": covered,
            "oldestEvent": oldest_iso}


# --- collecte (I/O injectee) ----------------------------------------------
# `fetch(path, params) -> dict` est injecte : ce module ne connait ni urllib,
# ni les identifiants. carto/collect/gateway.py fournit l'implementation
# reelle, les tests une fausse gateway.

def _compter(fetch, params, now, days, extra=None):
    p = dict(params)
    p.update(window_params(now, days))
    if extra:
        p.update(extra)
    return parse_count(fetch(COUNT_PATH, p))


def _sonde_du_filtre_statut(fetch, now, days):
    """Le parametre `status` n'est pas documente. Un parametre inconnu est
    ignore en silence par la gateway (mesure) : sans cette sonde, sa
    disparition a une montee de version afficherait `errorRate 0.0` partout,
    sur toutes les aretes, sans une ligne de journal.

    On demande un statut qui ne peut exister. S'il revient du trafic, le
    filtre n'est plus honore et le taux d'erreur serait invente.
    """
    trouve = _compter(fetch, {"apiName": MATCH_ALL}, now, days,
                      {STATUS_PARAM: escape_regex(STATUS_SENTINELLE)})
    if trouve:
        raise FilterIgnored(
            f"le parametre `{STATUS_PARAM}` n'est plus honore par la gateway "
            f"(un statut inexistant a renvoye du trafic : {trouve!r}) — le taux "
            "d'erreur de chaque arete serait nul par construction, resultat non "
            "publiable")


def last_call(fetch, api_id, consumer_name, now, days):
    """Date du dernier appel d'une arete, en UNE requete.

    `_search` rend les evenements du plus recent au plus ancien (mesure,
    verifiee sur une page complete). Une page de taille 1 suffit donc, et le
    cout reste borne par le nombre d'aretes observees — pas par le volume de
    trafic. C'est le seul endroit ou ce module lit un evenement unitaire.
    """
    p = {"apiId": escape_regex(api_id),
         "applicationName": escape_regex(consumer_name), "from": 0, "size": 1}
    p.update(window_params(now, days))
    evenements = parse_search(fetch(SEARCH_PATH, p))
    if not evenements:
        return None
    return to_iso(evenements[0].get("creationDate"))


def oldest_event(fetch, now, requested_days):
    """Le plus vieil evenement disponible, par RECHERCHE DICHOTOMIQUE.

    C'est le remplacement de l'agregation `min` qui disparait avec l'acces
    Elasticsearch. La garantie qu'elle porte est centrale : on n'affiche jamais
    une profondeur qu'on n'a pas, sinon on conclut « cette API n'a plus de
    consommateur » a propos d'une API appelee hors fenetre.

    Methode : la borne basse est figee a `now - requested_days`, on cherche la
    plus petite borne HAUTE qui contienne encore un evenement. La fonction
    « il existe un evenement dans [debut, T] » est croissante en T, donc
    dichotomisable. ~26 requetes de comptage, INDEPENDANT du volume de trafic
    et sans pagination profonde (mesure : au-dela de ~10 000, `from` est
    refuse — « using [from] is not allowed in a scroll context »).

    Retourne None si la fenetre demandee ne contient aucun evenement : la
    profondeur vaut alors 0, ce qui est la verite, pas un bug.
    """
    fin = now - MARGE_DE_FRAICHEUR
    debut = fin - dt.timedelta(days=requested_days)

    def existe(borne_haute):
        return bool(parse_count(fetch(COUNT_PATH, {
            "apiName": MATCH_ALL, "fromDate": format_date(debut),
            "toDate": format_date(borne_haute)})))

    if not existe(fin):
        return None

    bas, haut = debut, fin           # existe(haut) vrai, existe(bas) suppose faux
    while haut - bas > _PRECISION_DICHOTOMIE:
        milieu = bas + (haut - bas) / 2
        if existe(milieu):
            haut = milieu
        else:
            bas = milieu

    # `haut` encadre l'evenement le plus ancien a la seconde pres. On lit sa
    # date exacte dans cette tranche d'une seconde : elle contient peu
    # d'evenements, donc `from = n - 1` (le dernier de l'ordre decroissant,
    # c'est-a-dire le plus ancien) reste tres loin de la limite de pagination.
    tranche = {"apiName": MATCH_ALL, "fromDate": format_date(bas),
               "toDate": format_date(haut)}
    n = sum(parse_count(fetch(COUNT_PATH, dict(tranche))).values())
    if n:
        page = dict(tranche, **{"from": n - 1, "size": 1})
        evenements = parse_search(fetch(SEARCH_PATH, page))
        if evenements:
            exact = to_iso(evenements[0].get("creationDate"))
            if exact:
                return exact
    # Repli assume : on n'a pas pu lire l'evenement lui-meme, mais on sait
    # qu'il est anterieur a `haut` a la seconde pres. Annoncer `haut` ne
    # SURESTIME jamais la profondeur couverte.
    return to_iso(haut.timestamp() * 1000)


def observed_rows(fetch, apis, consumers, now, days, details):
    """Les aretes observees sur une fenetre, par comptages uniquement.

    Strategie (le coeur de la refonte) :
      1. un comptage par APPLICATION — la reponse de `_count` est deja
         REGROUPEE PAR API (mesure), donc une seule requete par application
         donne toutes ses aretes, y compris celles qui ne sont PAS declarees.
         C'est ce qui preserve la case « ecart de gouvernance » de build.py,
         qu'un comptage limite aux couples declares aurait perdue ;
      2. un comptage par API pour le volume total ;
      3. le trafic non attribue d'une API = son total moins la somme de ses
         applications. C'est un RESIDU CALCULE : aucun evenement enumere.

    Ce residu est porte par une arete vers le consommateur fantome `Unknown`,
    ce qui alimente `unidentifiedCallShare` sans champ supplementaire :
    build.py compte deja comme non identifie tout trafic dont le consommateur
    n'est pas a l'inventaire.

    `details` (fenetre longue seulement) ajoute le nombre d'appels en succes,
    d'ou se deduit le nombre d'erreurs. Les comptages en succes sont demandes
    AVANT les totaux : meme si la borne haute figee rend deja la soustraction
    exacte, l'ordre garde le residu et le nombre d'erreurs non negatifs si
    cette garantie venait a se relacher.
    """
    par_nom = consumers_by_name(consumers)

    # 1. les applications d'abord (le residu reste positif, voir docstring)
    appels = {}   # nom -> {apiId: appels}
    succes = {}   # nom -> {apiId: succes}
    for nom in par_nom:
        filtre = {"applicationName": escape_regex(nom)}
        if details:
            succes[nom] = _compter(fetch, filtre, now, days,
                                   {STATUS_PARAM: STATUS_OK})
        appels[nom] = _compter(fetch, filtre, now, days)

    # 2. le total de chaque API
    totaux, totaux_ok = {}, {}
    for api in apis:
        api_id = api["id"]
        filtre = {"apiId": escape_regex(api_id)}
        if details:
            totaux_ok[api_id] = _compter(fetch, filtre, now, days,
                                         {STATUS_PARAM: STATUS_OK}).get(api_id, 0)
        totaux[api_id] = _compter(fetch, filtre, now, days).get(api_id, 0)

    # 3. les aretes, puis le residu
    lignes = []
    attribue = {api_id: 0 for api_id in totaux}
    attribue_ok = {api_id: 0 for api_id in totaux}
    for nom, con_id in par_nom.items():
        for api_id, n in appels[nom].items():
            if not n:
                continue
            ligne = {"apiId": api_id, "consumerId": con_id, "calls": n,
                     "lastCall": None, "errors": 0}
            if details:
                ok = succes[nom].get(api_id, 0)
                ligne["errors"] = _ecart(n, ok, api_id, con_id, "succes")
                ligne["lastCall"] = last_call(fetch, api_id, nom, now, days)
            lignes.append(ligne)
            if api_id in attribue:
                attribue[api_id] += n
                if details:
                    attribue_ok[api_id] += succes[nom].get(api_id, 0)

    for api_id, total in totaux.items():
        residu = _ecart(total, attribue[api_id], api_id,
                        UNIDENTIFIED_CONSUMER_ID, "attribue")
        if not residu:
            continue
        # `lastCall` reste nul : aucun filtre de la gateway ne sait dire
        # « tout sauf ces applications-la ». Le contrat accepte un dernier
        # appel nul — l'inventer serait pire que l'ignorer.
        erreurs = 0
        if details:
            residu_ok = _ecart(totaux_ok[api_id], attribue_ok[api_id], api_id,
                               UNIDENTIFIED_CONSUMER_ID, "attribue en succes")
            erreurs = _ecart(residu, residu_ok, api_id,
                             UNIDENTIFIED_CONSUMER_ID, "succes")
        lignes.append({"apiId": api_id, "consumerId": UNIDENTIFIED_CONSUMER_ID,
                       "calls": residu, "lastCall": None, "errors": erreurs})
    return lignes


def _ecart(total, partie, api_id, con_id, quoi):
    if partie > total:
        raise InconsistentCounts(
            f"comptages contradictoires pour ({api_id}, {con_id}) : {quoi}={partie} "
            f"> total={total} — la gateway s'est contredite entre deux requetes "
            "d'une meme collecte, resultat non publiable")
    return total - partie


def collect(fetch, apis, consumers, windows, requested_days, now):
    """Toute la collecte du trafic. Retourne (observe_par_fenetre, fenetre).

    `windows` est la liste (nom, jours) TRIEE DE LA PLUS COURTE A LA PLUS
    LONGUE. Cet ordre n'est plus ce qui garantit d7 ⊆ d30 ⊆ d90 — la borne
    haute figee s'en charge — mais il reste la lecture la plus economique en
    cas d'interruption : on a alors la fenetre courte, la plus utile.

    Les details (succes, donc erreurs, et date du dernier appel) ne sont lus
    que sur la fenetre LONGUE, la seule dont build.py les lit.
    """
    longue = max(jours for _, jours in windows)

    # La sonde passe EN PREMIER : inutile de calculer des taux d'erreur qu'on
    # s'apprete a refuser. Sur un tenant sans aucun trafic elle passe a vide,
    # ce qui est sans consequence — il n'y a alors aucun taux a fausser.
    _sonde_du_filtre_statut(fetch, now, longue)

    observe = {}
    for nom, jours in windows:
        observe[nom] = observed_rows(fetch, apis, consumers, now, jours,
                                     details=(jours == longue))
    return observe, covered_window(oldest_event(fetch, now, requested_days),
                                   requested_days, now)
