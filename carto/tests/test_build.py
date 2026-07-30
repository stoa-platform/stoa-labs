import unittest
from carto.collect.build import build_carto
from carto.collect.model import SCHEMA_VERSION, validate_carto

APIS = [{"id": "a1", "name": "orders", "version": "1", "owner": "t",
         "active": True, "createdAt": None}]
CONS = [{"id": "c1", "name": "crm", "owner": "t", "contact": None, "createdAt": None},
        {"id": "c2", "name": "erp", "owner": "t", "contact": None, "createdAt": None}]
WIN = {"requestedDays": 90, "coveredDays": 90, "oldestEvent": "2026-05-01T00:00:00Z"}

def obs(rows):
    return {"d7": [], "d30": [], "d90": rows}

def edge(doc, api_id, con_id):
    return next(e for e in doc["edges"] if e["apiId"] == api_id and e["consumerId"] == con_id)

class TestMatriceDeclareObserve(unittest.TestCase):
    def test_declare_et_observe_donne_un_consommateur_actif(self):
        d = build_carto(APIS, CONS, {("a1", "c1")},
                        obs([{"apiId": "a1", "consumerId": "c1", "calls": 10,
                              "lastCall": "2026-07-29T00:00:00Z", "errors": 1}]),
                        WIN, "2026-07-30T00:00:00Z")
        e = edge(d, "a1", "c1")
        self.assertTrue(e["declared"])
        self.assertEqual(e["calls"]["d90"], 10)
        self.assertAlmostEqual(e["errorRate"], 0.1)

    def test_declare_sans_trafic_reste_visible(self):
        # le consommateur onboarde qui n'a pas encore appele : c'est LUI
        # qu'il faut prevenir lors d'une depreciation. Il ne doit jamais
        # disparaitre de la carto.
        d = build_carto(APIS, CONS, {("a1", "c2")}, obs([]), WIN, "2026-07-30T00:00:00Z")
        e = edge(d, "a1", "c2")
        self.assertTrue(e["declared"])
        self.assertEqual(e["calls"], {"d7": 0, "d30": 0, "d90": 0})
        self.assertIsNone(e["lastCall"])

    def test_observe_sans_declaration_est_conserve_et_marque(self):
        d = build_carto(APIS, CONS, set(),
                        obs([{"apiId": "a1", "consumerId": "c1", "calls": 5,
                              "lastCall": "2026-07-29T00:00:00Z", "errors": 0}]),
                        WIN, "2026-07-30T00:00:00Z")
        self.assertFalse(edge(d, "a1", "c1")["declared"])

class TestObjetsDisparus(unittest.TestCase):
    def test_du_trafic_vers_une_api_supprimee_fabrique_un_noeud_inconnu(self):
        # ne pas perdre l'information : du trafic vers un objet disparu est
        # un signal, pas un dechet
        d = build_carto(APIS, CONS, set(),
                        obs([{"apiId": "zz", "consumerId": "c1", "calls": 3,
                              "lastCall": "2026-07-29T00:00:00Z", "errors": 0}]),
                        WIN, "2026-07-30T00:00:00Z")
        ghost = next(a for a in d["apis"] if a["id"] == "zz")
        self.assertFalse(ghost["active"])
        self.assertIn("inconnu", ghost["name"])
        self.assertEqual(validate_carto(d), [])

class TestFenetres(unittest.TestCase):
    def test_les_trois_fenetres_sont_reportees(self):
        d = build_carto(APIS, CONS, set(),
                        {"d7": [{"apiId": "a1", "consumerId": "c1", "calls": 1,
                                 "lastCall": "x", "errors": 0}],
                         "d30": [{"apiId": "a1", "consumerId": "c1", "calls": 4,
                                  "lastCall": "x", "errors": 0}],
                         "d90": [{"apiId": "a1", "consumerId": "c1", "calls": 9,
                                  "lastCall": "2026-07-29T00:00:00Z", "errors": 0}]},
                        WIN, "2026-07-30T00:00:00Z")
        self.assertEqual(edge(d, "a1", "c1")["calls"], {"d7": 1, "d30": 4, "d90": 9})

class TestDocument(unittest.TestCase):
    def test_le_document_produit_est_valide(self):
        d = build_carto(APIS, CONS, {("a1", "c1")}, obs([]), WIN, "2026-07-30T00:00:00Z")
        self.assertEqual(validate_carto(d), [])
        self.assertEqual(d["schemaVersion"], SCHEMA_VERSION)

    def test_tous_les_consommateurs_enregistres_sont_presents(self):
        # meme celui qui n'a ni declaration ni trafic : la carto est aussi
        # l'annuaire complet (besoin de communication du client)
        d = build_carto(APIS, CONS, set(), obs([]), WIN, "2026-07-30T00:00:00Z")
        self.assertEqual({c["id"] for c in d["consumers"]}, {"c1", "c2"})
