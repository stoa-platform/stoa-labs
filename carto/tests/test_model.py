import unittest
from carto.collect.model import SCHEMA_VERSION, validate_carto, validate_history

def doc(**over):
    d = {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": "2026-07-30T02:11:00Z",
        "window": {"requestedDays": 90, "coveredDays": 34,
                   "oldestEvent": "2026-06-26T00:00:00Z"},
        "apis": [{"id": "a1", "name": "orders", "version": "1.0",
                  "owner": "team-x", "active": True, "createdAt": None}],
        "consumers": [{"id": "c1", "name": "crm", "owner": "team-y",
                       "contact": "crm@ex.invalid", "createdAt": None}],
        "edges": [{"apiId": "a1", "consumerId": "c1", "declared": True,
                   "calls": {"d7": 1, "d30": 2, "d90": 3},
                   "lastCall": "2026-07-29T18:02:00Z", "errorRate": 0.0}],
    }
    d.update(over)
    return d

class TestValidateCarto(unittest.TestCase):
    def test_document_complet_est_valide(self):
        self.assertEqual(validate_carto(doc()), [])

    def test_refuse_une_liste_apis_vide(self):
        # garde-fou D8 : une carto vide ne doit jamais écraser une bonne carto
        errs = validate_carto(doc(apis=[]))
        self.assertTrue(any("apis" in e for e in errs), errs)

    def test_refuse_une_arete_vers_une_api_inconnue(self):
        d = doc()
        d["edges"][0]["apiId"] = "fantome"
        errs = validate_carto(d)
        self.assertTrue(any("apiId" in e for e in errs), errs)

    def test_refuse_une_arete_vers_un_consommateur_inconnu(self):
        d = doc()
        d["edges"][0]["consumerId"] = "fantome"
        errs = validate_carto(d)
        self.assertTrue(any("consumerId" in e for e in errs), errs)

    def test_refuse_une_mauvaise_version_de_schema(self):
        errs = validate_carto(doc(schemaVersion=99))
        self.assertTrue(any("schemaVersion" in e for e in errs), errs)

    def test_refuse_un_compteur_manquant(self):
        d = doc()
        del d["edges"][0]["calls"]["d30"]
        errs = validate_carto(d)
        self.assertTrue(any("d30" in e for e in errs), errs)

    def test_accepte_une_arete_declaree_sans_trafic(self):
        # le consommateur onboardé qui n'a pas encore appelé : cas central
        d = doc()
        d["edges"][0].update(calls={"d7": 0, "d30": 0, "d90": 0},
                             lastCall=None, errorRate=0.0)
        self.assertEqual(validate_carto(d), [])

class TestValidateHistory(unittest.TestCase):
    def test_ligne_complete_est_valide(self):
        rows = [{"date": "2026-07-30", "apis": 128, "consumersRegistered": 96,
                 "consumersActive": 71, "calls": 18402113}]
        self.assertEqual(validate_history(rows), [])

    def test_refuse_une_date_mal_formee(self):
        rows = [{"date": "30/07/2026", "apis": 1, "consumersRegistered": 1,
                 "consumersActive": 1, "calls": 0}]
        self.assertTrue(validate_history(rows))
