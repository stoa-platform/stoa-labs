"""Le trafic observe, lu par l'API PUBLIQUE de la gateway (refonte 2026-07-31).

Une gateway de laboratoire est simulee ici (`FausseGateway`) plutot que
moquee appel par appel : le collecteur enchaine des dizaines de requetes dont
le SENS depend des bornes de date (recherche dichotomique de la profondeur
couverte, residu calcule par soustraction). Une pile de valeurs de retour
figees ne dirait rien de ce qui compte — que les comptages se recoupent.

Le simulateur reproduit les comportements REELLEMENT mesures, y compris les
desagreables :
  - `_count` sans resultat renvoie une CHAINE, pas une liste vide ;
  - `_search` sans resultat renvoie bien une liste vide ;
  - les filtres de nom sont des expressions regulieres ancrees, insensibles a
    la casse ;
  - `_search` ne rend RIEN des qu'on lui passe `status`.
Les fixtures `transactional-events.json` verrouillent ces formes contre du
reel : si le simulateur derivait, les tests de lecture le diraient.
"""
import datetime as dt
import json
import pathlib
import re
import unittest

from carto.collect import build
from carto.collect.analytics import (COUNT_PATH, SEARCH_PATH, MATCH_ALL,
                                     MARGE_DE_FRAICHEUR, STATUS_PARAM,
                                     UNIDENTIFIED_CONSUMER_ID,
                                     DATE_FORMAT, FilterIgnored, GatewayError,
                                     InconsistentCounts, UnusableConsumerName,
                                     collect, consumers_by_name, covered_window,
                                     escape_regex, last_call, observed_rows,
                                     oldest_event, parse_count, parse_search,
                                     to_iso, window_params)

FIX = pathlib.Path(__file__).parent / "fixtures"
UTC = dt.timezone.utc
BRUT = json.loads((FIX / "transactional-events.json").read_text())

MAINTENANT = dt.datetime(2026, 7, 31, 12, 0, 0, tzinfo=UTC)
FENETRES = [("d7", 7), ("d30", 30), ("d90", 90)]


def ms(moment):
    return int(moment.timestamp() * 1000)


def il_y_a(**delta):
    return MAINTENANT - dt.timedelta(**delta)


class FausseGateway:
    """Un magasin d'evenements minimal derriere les deux routes publiques."""

    def __init__(self, evenements, statut_ignore=False, biais=None):
        self.evenements = evenements
        self.statut_ignore = statut_ignore   # simule la disparition du filtre
        self.biais = biais or {}             # force un comptage contradictoire
        self.requetes = []

    # --- l'interface injectee dans analytics ------------------------------
    def __call__(self, path, params):
        self.requetes.append((path, dict(params)))
        retenus = self._filtrer(params)
        if path == COUNT_PATH:
            return self._compter(params, retenus)
        if path == SEARCH_PATH:
            return self._chercher(params, retenus)
        raise AssertionError(f"chemin inattendu : {path}")

    # --- comportements mesures --------------------------------------------
    def _filtrer(self, params):
        debut = dt.datetime.strptime(params["fromDate"], DATE_FORMAT).replace(tzinfo=UTC)
        fin = dt.datetime.strptime(params["toDate"], DATE_FORMAT).replace(tzinfo=UTC)
        out = []
        for e in self.evenements:
            moment = dt.datetime.fromtimestamp(e["creationDate"] / 1000, UTC)
            if not debut <= moment <= fin:
                continue
            if not self._matche(params.get("apiId"), e["apiId"]):
                continue
            if not self._matche(params.get("apiName"), e["apiName"]):
                continue
            if not self._matche(params.get("applicationName"), e["applicationName"]):
                continue
            if not self.statut_ignore and not self._matche(params.get(STATUS_PARAM), e["status"]):
                continue
            out.append(e)
        return out

    @staticmethod
    def _matche(motif, valeur):
        # filtre absent = pas de contrainte ; sinon regex ANCREE, insensible
        # a la casse (mesure : `carto-probe` ne matche pas `carto-probe-api`).
        return motif is None or bool(re.fullmatch(motif, valeur, re.IGNORECASE))

    def _compter(self, params, retenus):
        par_api = {}
        for e in retenus:
            par_api[e["apiId"]] = par_api.get(e["apiId"], 0) + 1
        # `biais` ne fausse QUE le total par API (celui qui porte `apiId`) :
        # c'est la contradiction qu'on veut simuler, un total inferieur a la
        # somme de ses applications.
        if "apiId" in params and STATUS_PARAM not in params:
            for api_id, ecart in self.biais.items():
                if api_id in par_api:
                    par_api[api_id] += ecart
        if not par_api:
            # PIEGE MESURE : une CHAINE, pas une liste vide.
            return {"count": " No records found."}
        return {"count": [{"apiId": k, "apiName": "peu-importe", "apiVersion": "1.0.0",
                           "count": v} for k, v in par_api.items()]}

    def _chercher(self, params, retenus):
        if STATUS_PARAM in params:
            # mesure : `_search` ne rend rien des qu'on lui passe `status`.
            return {"transaction": []}
        retenus = sorted(retenus, key=lambda e: e["creationDate"], reverse=True)
        depart = int(params.get("from", 0))
        taille = int(params.get("size", 10))
        return {"transaction": retenus[depart:depart + taille]}


def evenement(api, app, moment, statut="SUCCESS"):
    return {"apiId": api, "apiName": "api-" + api, "applicationName": app,
            "creationDate": ms(moment), "status": statut}


APIS = [{"id": "api-paie", "name": "paie"}, {"id": "api-rh", "name": "rh"}]
CONSOS = [{"id": "c-portail", "name": "portail"}, {"id": "c-batch", "name": "batch"}]


def labo():
    """Un jeu d'evenements qui couvre les cas produits : un consommateur
    identifie, un consommateur a faible volume, du trafic anonyme, une erreur,
    et du trafic hors de la fenetre courte."""
    ev = []
    ev += [evenement("api-paie", "portail", il_y_a(days=2, hours=h)) for h in range(5)]
    ev += [evenement("api-paie", "batch", il_y_a(days=40))]
    ev += [evenement("api-paie", "Unknown", il_y_a(days=1)) for _ in range(3)]
    ev += [evenement("api-paie", "portail", il_y_a(days=3), statut="FAILURE")]
    ev += [evenement("api-rh", "Unknown", il_y_a(days=80))]
    return ev


class TestLectureDesReponses(unittest.TestCase):
    def test_l_absence_de_resultat_de_count_est_une_chaine_pas_une_liste(self):
        # LE piege de cette API : `for row in reponse["count"]` itererait sur
        # les caracteres de " No records found." et fabriquerait du trafic.
        self.assertEqual(parse_count(BRUT["compte_sans_resultat"]), {})

    def test_le_libelle_de_l_absence_n_est_pas_ce_qui_est_teste(self):
        # un libelle traduit ou reformule a une montee de version ne doit pas
        # transformer un « rien » en donnees : c'est le TYPE qui decide.
        self.assertEqual(parse_count({"count": "Aucun enregistrement"}), {})

    def test_lit_un_comptage_reel_groupe_par_api(self):
        lu = parse_count(BRUT["compte_par_api"])
        self.assertEqual(lu["f12b0b1f-797c-4881-a1b2-511e290af69e"], 757)
        self.assertEqual(lu["5ed95567-62e7-4a4e-a2da-441f0b276098"], 48)

    def test_une_reponse_d_erreur_echoue_bruyamment(self):
        with self.assertRaises(GatewayError):
            parse_count(BRUT["requete_refusee"])

    def test_une_charge_utile_inattendue_echoue_bruyamment(self):
        with self.assertRaises(GatewayError):
            parse_count({"count": [{"apiId": "a", "count": "quarante-huit"}]})

    def test_l_absence_de_resultat_de_search_est_bien_une_liste_vide(self):
        # forme DIFFERENTE de _count : ne pas unifier les deux lectures.
        self.assertEqual(parse_search(BRUT["recherche_sans_resultat"]), [])

    def test_lit_un_evenement_reel(self):
        e = parse_search(BRUT["dernier_appel"])[0]
        self.assertEqual(e["apiId"], "5ed95567-62e7-4a4e-a2da-441f0b276098")
        self.assertIsInstance(e["creationDate"], int)

    def test_la_date_de_creation_est_en_millisecondes(self):
        e = parse_search(BRUT["dernier_appel"])[0]
        self.assertEqual(to_iso(e["creationDate"]), "2026-07-30T17:35:13.325Z")


class TestFiltres(unittest.TestCase):
    def test_les_metacaracteres_d_un_nom_sont_neutralises(self):
        # sans cela `paie.v2` matcherait `paieXv2` : une carto fausse.
        motif = escape_regex("paie.v2")
        self.assertIsNone(re.fullmatch(motif, "paieXv2"))
        self.assertIsNotNone(re.fullmatch(motif, "paie.v2"))

    def test_un_nom_reduit_a_un_metacaractere_reste_interrogeable(self):
        self.assertIsNotNone(re.fullmatch(escape_regex("a+"), "a+"))

    def test_toutes_les_fenetres_partagent_la_meme_borne_haute(self):
        # c'est ce qui rend d7 ⊆ d30 ⊆ d90 vrai PAR CONSTRUCTION : un appel
        # arrive pendant la collecte n'est vu par aucune des requetes.
        hautes = {window_params(MAINTENANT, j)["toDate"] for j in (7, 30, 90)}
        self.assertEqual(len(hautes), 1)

    def test_la_borne_haute_recule_de_la_marge_de_fraicheur(self):
        attendu = (MAINTENANT - MARGE_DE_FRAICHEUR).strftime(DATE_FORMAT)
        self.assertEqual(window_params(MAINTENANT, 7)["toDate"], attendu)


class TestNomsDeConsommateurs(unittest.TestCase):
    """La dimension consommateur passe par le NOM : `applicationId` ne matche
    pas la valeur `Unknown` reellement ecrite par la gateway (mesure)."""

    def test_associe_chaque_nom_a_son_identifiant(self):
        self.assertEqual(consumers_by_name(CONSOS)["portail"], "c-portail")

    def test_refuse_deux_applications_de_meme_nom_a_la_casse_pres(self):
        # le filtre est insensible a la casse : leur trafic serait double.
        with self.assertRaises(UnusableConsumerName):
            consumers_by_name([{"id": "a", "name": "Paie"}, {"id": "b", "name": "paie"}])

    def test_refuse_une_application_sans_nom(self):
        with self.assertRaises(UnusableConsumerName):
            consumers_by_name([{"id": "a", "name": None}])

    def test_refuse_une_application_nommee_comme_l_appelant_inconnu(self):
        # elle absorberait tout le trafic anonyme et la carto affirmerait
        # qu'elle en est l'auteur.
        with self.assertRaises(UnusableConsumerName):
            consumers_by_name([{"id": "a", "name": UNIDENTIFIED_CONSUMER_ID}])


class TestDernierAppel(unittest.TestCase):
    def test_une_seule_page_de_taille_un_suffit(self):
        gw = FausseGateway(labo())
        gw.requetes.clear()
        quand = last_call(gw, "api-paie", "portail", MAINTENANT, 90)
        self.assertEqual(len(gw.requetes), 1)
        self.assertEqual(gw.requetes[0][1]["size"], 1)
        # l'ordre est decroissant (mesure) : la premiere ligne est la plus
        # recente, donc le dernier appel.
        self.assertEqual(quand, to_iso(ms(il_y_a(days=2, hours=0))))

    def test_une_arete_sans_trafic_ne_donne_pas_de_date_inventee(self):
        self.assertIsNone(last_call(FausseGateway(labo()), "api-rh", "portail",
                                    MAINTENANT, 90))


class TestProfondeurCouverte(unittest.TestCase):
    """L'agregation `min` d'Elasticsearch disparait : la profondeur est
    desormais etablie par recherche dichotomique sur l'API publique. C'est la
    garantie centrale du produit — on n'affiche jamais une profondeur qu'on
    n'a pas, sinon on conclut « cette API n'a plus de consommateur » a propos
    d'une API appelee hors fenetre."""

    def test_retrouve_l_evenement_le_plus_ancien_a_la_seconde(self):
        plus_vieux = il_y_a(days=80)
        trouve = oldest_event(FausseGateway(labo()), MAINTENANT, 90)
        self.assertEqual(trouve, to_iso(ms(plus_vieux)))

    def test_le_cout_de_la_dichotomie_ne_depend_pas_du_volume(self):
        peu = FausseGateway(labo())
        beaucoup = FausseGateway(labo() + [
            evenement("api-paie", "portail", il_y_a(days=1, seconds=i))
            for i in range(4000)])
        oldest_event(peu, MAINTENANT, 90)
        oldest_event(beaucoup, MAINTENANT, 90)
        self.assertEqual(len(peu.requetes), len(beaucoup.requetes))

    def test_aucun_evenement_ne_donne_pas_une_profondeur_inventee(self):
        self.assertIsNone(oldest_event(FausseGateway([]), MAINTENANT, 90))

    def test_la_fenetre_couverte_est_plafonnee_par_la_retention(self):
        w = covered_window("2026-06-26T00:00:00Z", 90, dt.datetime(2026, 7, 30, tzinfo=UTC))
        self.assertEqual(w["requestedDays"], 90)
        self.assertEqual(w["coveredDays"], 34)

    def test_la_fenetre_couverte_ne_depasse_jamais_la_demande(self):
        w = covered_window("2020-01-01T00:00:00Z", 90, dt.datetime(2026, 7, 30, tzinfo=UTC))
        self.assertEqual(w["coveredDays"], 90)

    def test_sans_evenement_la_couverture_est_nulle_et_le_dit(self):
        w = covered_window(None, 90, MAINTENANT)
        self.assertEqual(w["coveredDays"], 0)
        self.assertIsNone(w["oldestEvent"])

    def test_les_millisecondes_de_l_horodatage_ne_font_pas_echouer(self):
        w = covered_window("2026-07-30T17:26:17.212Z", 90,
                           dt.datetime(2026, 7, 30, 18, 0, 0, tzinfo=UTC))
        self.assertEqual(w["coveredDays"], 0)
        self.assertEqual(w["oldestEvent"], "2026-07-30T17:26:17.212Z")


class TestAretesObservees(unittest.TestCase):
    def test_attribue_le_trafic_aux_consommateurs_identifies(self):
        lignes = observed_rows(FausseGateway(labo()), APIS, CONSOS,
                               MAINTENANT, 90, succes=True, dernier_appel=True)
        par_clef = {(l["apiId"], l["consumerId"]): l for l in lignes}
        self.assertEqual(par_clef[("api-paie", "c-portail")]["calls"], 6)
        self.assertEqual(par_clef[("api-paie", "c-batch")]["calls"], 1)

    def test_le_trafic_non_attribue_est_un_residu_calcule(self):
        # total de l'API moins la somme de ses applications : aucun evenement
        # enumere pour l'obtenir.
        lignes = observed_rows(FausseGateway(labo()), APIS, CONSOS,
                               MAINTENANT, 90, succes=True, dernier_appel=True)
        residu = [l for l in lignes if l["consumerId"] == UNIDENTIFIED_CONSUMER_ID]
        self.assertEqual({l["apiId"]: l["calls"] for l in residu},
                         {"api-paie": 3, "api-rh": 1})

    def test_le_residu_ne_porte_pas_de_date_de_dernier_appel_inventee(self):
        lignes = observed_rows(FausseGateway(labo()), APIS, CONSOS,
                               MAINTENANT, 90, succes=True, dernier_appel=True)
        for l in lignes:
            if l["consumerId"] == UNIDENTIFIED_CONSUMER_ID:
                self.assertIsNone(l["lastCall"])

    def test_les_erreurs_se_deduisent_du_comptage_en_succes(self):
        lignes = observed_rows(FausseGateway(labo()), APIS, CONSOS,
                               MAINTENANT, 90, succes=True, dernier_appel=True)
        par_clef = {(l["apiId"], l["consumerId"]): l for l in lignes}
        self.assertEqual(par_clef[("api-paie", "c-portail")]["errors"], 1)
        self.assertEqual(par_clef[("api-paie", "c-batch")]["errors"], 0)

    def test_la_fenetre_courte_n_achete_pas_la_date_du_dernier_appel(self):
        # `lastCall` est un `_search` par arete et ne sert qu'a la fenetre
        # longue, la seule que build.py en lit : le payer trois fois serait
        # du gaspillage sans usage. Les succes, eux, sont desormais achetes
        # sur les trois fenetres (test suivant).
        gw = FausseGateway(labo())
        observed_rows(gw, APIS, CONSOS, MAINTENANT, 7,
                      succes=True, dernier_appel=False)
        self.assertFalse([r for r in gw.requetes if r[0] == SEARCH_PATH])

    def test_les_succes_sont_comptes_sur_la_fenetre_courte_aussi(self):
        # sans eux, `errors` vaudrait 0 en d7 et d30 par CONSTRUCTION : le
        # trafic servi de ces fenetres serait surestime du nombre d'appels
        # rejetes, et le ratio non identifie de la porte serait faux — en
        # silence, ce qui est le pire des deux.
        lignes = observed_rows(FausseGateway(labo()), APIS, CONSOS,
                               MAINTENANT, 7, succes=True, dernier_appel=False)
        par_clef = {(l["apiId"], l["consumerId"]): l for l in lignes}
        self.assertEqual(par_clef[("api-paie", "c-portail")]["errors"], 1)

    def test_une_gateway_qui_se_contredit_echoue_bruyamment(self):
        # un total d'API inferieur a la somme de ses applications rendrait un
        # residu negatif : on refuse de publier plutot que de le rogner a zero.
        gw = FausseGateway(labo(), biais={"api-paie": -5})
        with self.assertRaises(InconsistentCounts):
            observed_rows(gw, APIS, CONSOS, MAINTENANT, 90, succes=True, dernier_appel=True)


class TestCollecteComplete(unittest.TestCase):
    def test_les_trois_fenetres_sont_emboitees(self):
        observe, _ = collect(FausseGateway(labo()), APIS, CONSOS, FENETRES, 90, MAINTENANT)
        volume = {w: {(l["apiId"], l["consumerId"]): l["calls"] for l in lignes}
                  for w, lignes in observe.items()}
        for clef in volume["d90"]:
            self.assertLessEqual(volume["d7"].get(clef, 0), volume["d30"].get(clef, 0))
            self.assertLessEqual(volume["d30"].get(clef, 0), volume["d90"].get(clef, 0))

    def test_la_fenetre_courte_voit_moins_loin_que_la_longue(self):
        observe, _ = collect(FausseGateway(labo()), APIS, CONSOS, FENETRES, 90, MAINTENANT)
        d7 = {(l["apiId"], l["consumerId"]) for l in observe["d7"] if l["calls"]}
        self.assertNotIn(("api-paie", "c-batch"), d7)   # appel a 40 jours
        self.assertIn(("api-paie", "c-portail"), d7)

    def test_chaque_fenetre_porte_ses_propres_erreurs(self):
        # `labo()` place une FAILURE a 3 jours : elle doit apparaitre dans les
        # trois fenetres, pas seulement dans la longue.
        observe, _ = collect(FausseGateway(labo()), APIS, CONSOS, FENETRES, 90, MAINTENANT)
        for nom in ("d7", "d30", "d90"):
            erreurs = {(l["apiId"], l["consumerId"]): l["errors"] for l in observe[nom]}
            self.assertEqual(erreurs[("api-paie", "c-portail")], 1,
                             f"erreur perdue sur la fenetre {nom}")

    def test_le_cout_ajoute_par_les_succes_reste_borne_par_la_configuration(self):
        # V7 : la propriete qui rend ce job tenable chez un client, c'est que
        # son cout ne depend QUE du nombre d'APIs et d'applications. Acheter
        # les succes sur les trois fenetres ajoute 2 x (apis + apps) requetes
        # — et pas une de plus par appel encaisse.
        gw = FausseGateway(labo())
        collect(gw, APIS, CONSOS, FENETRES, 90, MAINTENANT)
        avec_statut = [r for r in gw.requetes
                       if r[0] == COUNT_PATH and STATUS_PARAM in r[1]]
        # 3 fenetres x (2 APIs + 2 applications), plus la sonde du filtre.
        self.assertEqual(len(avec_statut), 3 * (len(APIS) + len(CONSOS)) + 1)

    def test_la_profondeur_couverte_est_mesuree_et_non_annoncee(self):
        _, fenetre = collect(FausseGateway(labo()), APIS, CONSOS, FENETRES, 90, MAINTENANT)
        self.assertEqual(fenetre["requestedDays"], 90)
        self.assertEqual(fenetre["coveredDays"], 80)

    def test_le_cout_de_la_collecte_ne_depend_pas_du_volume_de_trafic(self):
        # c'est LA raison de ne faire que des comptages : viable au labo comme
        # chez un client a des millions d'appels.
        peu = FausseGateway(labo())
        beaucoup = FausseGateway(labo() + [
            evenement("api-paie", "portail", il_y_a(days=1, seconds=i))
            for i in range(5000)])
        collect(peu, APIS, CONSOS, FENETRES, 90, MAINTENANT)
        collect(beaucoup, APIS, CONSOS, FENETRES, 90, MAINTENANT)
        self.assertEqual(len(peu.requetes), len(beaucoup.requetes))

    def test_aucune_requete_ne_rapatrie_de_page_d_evenements(self):
        gw = FausseGateway(labo())
        collect(gw, APIS, CONSOS, FENETRES, 90, MAINTENANT)
        for path, params in gw.requetes:
            if path == SEARCH_PATH:
                self.assertEqual(int(params["size"]), 1)

    def test_la_disparition_du_filtre_de_statut_echoue_bruyamment(self):
        # `status` n'est pas documente et un parametre inconnu est ignore EN
        # SILENCE par cette gateway : sans la sonde, le taux d'erreur de
        # toutes les aretes tomberait a zero sans un mot.
        gw = FausseGateway(labo(), statut_ignore=True)
        with self.assertRaises(FilterIgnored):
            collect(gw, APIS, CONSOS, FENETRES, 90, MAINTENANT)


class TestJointureAvecLeContrat(unittest.TestCase):
    """Ce que le residu vaut une fois porte au document publie."""

    def test_le_residu_alimente_la_part_de_trafic_non_identifie(self):
        observe, fenetre = collect(FausseGateway(labo()), APIS, CONSOS,
                                   FENETRES, 90, MAINTENANT)
        doc = build.build_carto(
            [dict(a, version=None, owner=None, active=True, createdAt=None) for a in APIS],
            [dict(c, owner=None, contact=None, createdAt=None) for c in CONSOS],
            {("api-paie", "c-portail")}, observe, fenetre, "2026-07-31T12:00:00Z")
        # Denominateur : le trafic SERVI (appels moins erreurs). Un appel
        # rejete n'a aucun consommateur a perdre — cf. la docstring de
        # `build._unidentified_share`.
        def servi(e):
            return e["calls"]["d90"] - e["errors"]["d90"]

        total = sum(servi(e) for e in doc["edges"])
        anonyme = sum(servi(e) for e in doc["edges"]
                      if e["consumerId"] == UNIDENTIFIED_CONSUMER_ID)
        self.assertEqual(doc["unidentifiedCallShare"], round(anonyme / total, 4))
        self.assertEqual(sum(e["calls"]["d90"] for e in doc["edges"]
                             if e["consumerId"] == UNIDENTIFIED_CONSUMER_ID), 4)

    def test_le_consommateur_inconnu_devient_un_noeud_fantome(self):
        observe, fenetre = collect(FausseGateway(labo()), APIS, CONSOS,
                                   FENETRES, 90, MAINTENANT)
        doc = build.build_carto(
            [dict(a, version=None, owner=None, active=True, createdAt=None) for a in APIS],
            [dict(c, owner=None, contact=None, createdAt=None) for c in CONSOS],
            set(), observe, fenetre, "2026-07-31T12:00:00Z")
        fantomes = [c for c in doc["consumers"] if c["ghost"]]
        self.assertEqual([c["id"] for c in fantomes], [UNIDENTIFIED_CONSUMER_ID])


class TestFixtureDeCollecte(unittest.TestCase):
    def test_la_fixture_rejouee_porte_l_avertissement_de_substitution(self):
        # la substitution des identifiants d'application reste necessaire :
        # la gateway de mesure n'identifie toujours aucun appelant (TERRAIN V5).
        fixture = json.loads((FIX / "observed.json").read_text())
        self.assertIn("ce_qui_est_substitue", fixture["_meta"])
        substitues = [l for l in fixture["observed"]["d90"] if "_substitue" in l]
        self.assertEqual(len(substitues), 2)

    def test_la_fixture_rejouee_conserve_un_residu_non_attribue(self):
        fixture = json.loads((FIX / "observed.json").read_text())
        residu = [l for l in fixture["observed"]["d90"]
                  if l["consumerId"] == UNIDENTIFIED_CONSUMER_ID]
        self.assertTrue(residu)
        self.assertIsNone(residu[0]["lastCall"])


if __name__ == "__main__":
    unittest.main()
