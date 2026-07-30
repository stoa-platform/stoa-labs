import datetime as dt
import json
import pathlib
import unittest

from carto.collect.analytics import (aggregation_query, oldest_query,
                                     parse_aggregation, covered_window,
                                     TruncatedAggregation)

FIX = pathlib.Path(__file__).parent / "fixtures"
UTC = dt.timezone.utc


def agg(other_api=0, other_con=0):
    return {"aggregations": {"api": {
        "sum_other_doc_count": other_api,
        "buckets": [{"key": "a1", "doc_count": 12, "consumer": {
            "sum_other_doc_count": other_con,
            "buckets": [{"key": "c1", "doc_count": 10,
                         "last": {"value_as_string": "2026-07-29T18:02:00Z"},
                         "errors": {"doc_count": 1}}]}}]}}}


class TestRequetes(unittest.TestCase):
    def test_la_requete_ne_remonte_aucun_evenement_brut(self):
        q = aggregation_query(90)
        self.assertEqual(q["size"], 0)

    def test_la_requete_porte_la_fenetre_demandee(self):
        self.assertIn("now-30d", json.dumps(aggregation_query(30)))

    def test_la_requete_du_plus_vieil_evenement_est_une_agregation_min(self):
        self.assertIn("min", json.dumps(oldest_query()))


class TestParsing(unittest.TestCase):
    def test_extrait_un_couple_api_consommateur(self):
        rows = parse_aggregation(agg())
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["apiId"], "a1")
        self.assertEqual(rows[0]["consumerId"], "c1")
        self.assertEqual(rows[0]["calls"], 10)
        self.assertEqual(rows[0]["errors"], 1)
        self.assertEqual(rows[0]["lastCall"], "2026-07-29T18:02:00Z")

    def test_echoue_bruyamment_si_les_buckets_apis_sont_tronques(self):
        # une agregation tronquee produit une carto FAUSSE et non incomplete :
        # des consommateurs reels y apparaitraient comme inexistants
        with self.assertRaises(TruncatedAggregation):
            parse_aggregation(agg(other_api=7))

    def test_echoue_bruyamment_si_les_buckets_consommateurs_sont_tronques(self):
        with self.assertRaises(TruncatedAggregation):
            parse_aggregation(agg(other_con=3))

    def test_parse_la_fixture_reelle(self):
        rows = parse_aggregation(json.loads((FIX / "aggregation-d90.json").read_text()))
        for r in rows:
            self.assertIsInstance(r["calls"], int)
            self.assertIsInstance(r["apiId"], str)


class TestFenetre(unittest.TestCase):
    def test_la_fenetre_couverte_est_plafonnee_par_la_retention(self):
        raw = {"aggregations": {"oldest": {"value_as_string": "2026-06-26T00:00:00Z"}}}
        w = covered_window(raw, 90, dt.datetime(2026, 7, 30, tzinfo=UTC))
        self.assertEqual(w["requestedDays"], 90)
        self.assertEqual(w["coveredDays"], 34)

    def test_la_fenetre_couverte_ne_depasse_jamais_la_demande(self):
        raw = {"aggregations": {"oldest": {"value_as_string": "2020-01-01T00:00:00Z"}}}
        w = covered_window(raw, 90, dt.datetime(2026, 7, 30, tzinfo=UTC))
        self.assertEqual(w["coveredDays"], 90)

    def test_index_vide_donne_une_couverture_nulle(self):
        raw = {"aggregations": {"oldest": {"value": None}}}
        w = covered_window(raw, 90, dt.datetime(2026, 7, 30, tzinfo=UTC))
        self.assertEqual(w["coveredDays"], 0)
        self.assertIsNone(w["oldestEvent"])

    def test_la_fenetre_couverte_gere_les_horodatages_avec_millisecondes(self):
        # terrain mesure : la fixture reelle porte des millisecondes
        # ("2026-07-30T17:26:17.212Z") ; la fonction doit les analyser
        # sans lever d'exception.
        raw = json.loads((FIX / "oldest-event.json").read_text())
        w = covered_window(raw, 90, dt.datetime(2026, 7, 30, 18, 0, 0, tzinfo=UTC))
        self.assertEqual(w["requestedDays"], 90)
        # index tout juste alimente : 0 jour couvert, ce n'est pas un bug
        self.assertEqual(w["coveredDays"], 0)
        self.assertIsNotNone(w["oldestEvent"])


if __name__ == "__main__":
    unittest.main()
