"""Tests de normalisation de l'inventaire (Tache 2).

Les fixtures apis.json / applications.json ont ete capturees en T0 sur une
gateway webMethods 10.15 reelle (voir carto/TERRAIN.md) : les structures
testees ici (enveloppe api/teams imbriquee, consumingAPIs en chaines brutes,
format de date non-ISO) sont mesurees, pas supposees.
"""
import json
import pathlib
import unittest

from carto.collect.gateway import normalize_apis, normalize_consumers, declared_edges

FIX = pathlib.Path(__file__).parent / "fixtures"


def load(name):
    return json.loads((FIX / name).read_text())


class TestNormalisation(unittest.TestCase):
    def test_chaque_api_a_un_id_et_un_nom(self):
        apis = normalize_apis(load("apis.json"))
        self.assertTrue(apis, "la fixture ne doit pas etre vide")
        for a in apis:
            self.assertTrue(a["id"], a)
            self.assertTrue(a["name"], a)
            self.assertIn("active", a)
            self.assertIn("createdAt", a)

    def test_chaque_consommateur_a_un_id_et_un_nom(self):
        cons = normalize_consumers(load("applications.json"))
        self.assertTrue(cons)
        for c in cons:
            self.assertTrue(c["id"], c)
            self.assertTrue(c["name"], c)
            self.assertIn("contact", c)

    def test_les_identifiants_sont_uniques(self):
        apis = normalize_apis(load("apis.json"))
        ids = [a["id"] for a in apis]
        self.assertEqual(len(ids), len(set(ids)))

    def test_les_aretes_declarees_referencent_des_objets_connus(self):
        apis = {a["id"] for a in normalize_apis(load("apis.json"))}
        cons = {c["id"] for c in normalize_consumers(load("applications.json"))}
        for api_id, con_id in declared_edges(load("applications.json")):
            self.assertIn(con_id, cons)
            # une autorisation peut pointer une API supprimee : on l'accepte ici,
            # build.py fabriquera un noeud "(inconnu)" plutot que de la perdre
            self.assertIsInstance(api_id, str)

    def test_normalisation_tolere_un_champ_absent(self):
        # cle racine reelle mesuree en T0 : "apiResponse", enveloppe {"api": {...}}
        apis = normalize_apis({"apiResponse": [{"api": {"id": "x", "apiName": "y"}}]})
        self.assertEqual(apis[0]["id"], "x")
        self.assertIsNone(apis[0]["createdAt"])

    def test_deballage_de_l_enveloppe_api(self):
        """apiResponse[] est une enveloppe {api, responseStatus, teams} : il
        faut deballer l'objet 'api' pour retrouver les champs utiles, et le
        proprietaire vient de 'teams' (frere de 'api'), pas de l'objet api."""
        apis = normalize_apis(load("apis.json"))
        by_name = {a["name"]: a for a in apis}

        accounts = by_name["accounts-read"]
        self.assertEqual(accounts["id"], "f12b0b1f-797c-4881-a1b2-511e290af69e")
        self.assertEqual(accounts["version"], "1.0.0")
        self.assertTrue(accounts["active"])
        # equipe SYSTEM (Administrators) ignoree, banking-demo (USER) retenue
        self.assertEqual(accounts["owner"], "banking-demo")

        probe = by_name["carto-probe-api"]
        # seules des equipes SYSTEM : aucun proprietaire metier exploitable
        self.assertIsNone(probe["owner"])

        # mesure en T0 : aucun champ de date de creation dans la liste /apis
        self.assertIsNone(accounts["createdAt"])
        self.assertIsNone(probe["createdAt"])

    def test_normalisation_de_la_date_de_creation_en_iso8601(self):
        """created arrive au format 'AAAA-MM-JJ HH:MM:SS GMT' (mesure en T0) ;
        createdAt doit etre normalise en ISO 8601 UTC pour ne pas cohabiter
        avec generatedAt (deja ISO) dans le meme document."""
        cons = normalize_consumers(load("applications.json"))
        by_id = {c["id"]: c for c in cons}
        idle = by_id["b168b889-f8e5-4ab2-bd11-bdf351942e8a"]
        self.assertEqual(idle["createdAt"], "2026-07-30T16:59:37Z")

    def test_date_absente_ou_format_inattendu_donne_none(self):
        cons = normalize_consumers({"applications": [
            {"id": "a", "name": "sans-date"},
            {"id": "b", "name": "date-bizarre", "created": "pas une date"},
        ]})
        by_id = {c["id"]: c for c in cons}
        self.assertIsNone(by_id["a"]["createdAt"])
        self.assertIsNone(by_id["b"]["createdAt"])

    def test_declared_edges_avec_consumingAPIs_vide_et_partagee(self):
        """Trois applications declarent la meme API (dont carto-probe-app-idle,
        sans aucun trafic — cas central du produit) ; une quatrieme a
        consumingAPIs vide. Les deux cas doivent etre tolerees."""
        edges = declared_edges(load("applications.json"))
        api_id = "5ed95567-62e7-4a4e-a2da-441f0b276098"
        consumers_declarant = {con for (a, con) in edges if a == api_id}
        self.assertEqual(consumers_declarant, {
            "4c329b2e-bcf7-45dc-996d-d5d9dfb538e0",  # carto-probe-app-active
            "f06fa084-3745-4e6d-afac-98246b3c2757",  # carto-probe-app-low
            "b168b889-f8e5-4ab2-bd11-bdf351942e8a",  # carto-probe-app-idle
        })
        # f3-proof-2026-07-29 a consumingAPIs == [] : aucune arete produite pour elle
        vide_ids = {con for (_, con) in edges if con == "03e668ed-2925-4189-99bb-2d199d587dd9"}
        self.assertEqual(vide_ids, set())


if __name__ == "__main__":
    unittest.main()
