import json, pathlib, tempfile, unittest
from unittest import mock

import carto.collect.publish as publish_mod
from carto.collect.model import SCHEMA_VERSION
from carto.collect.publish import publish, RefusedPublication

GOOD = {"schemaVersion": SCHEMA_VERSION, "generatedAt": "2026-07-30T00:00:00Z",
        "window": {"requestedDays": 90, "coveredDays": 90, "oldestEvent": None},
        "unidentifiedCallShare": 0.0,
        "unidentifiedCallShareByWindow": {"d7": None, "d30": None, "d90": None},
        "apis": [{"id": "a1", "name": "orders", "ghost": False}],
        "consumers": [{"id": "c1", "name": "crm", "ghost": False}],
        "edges": [{"apiId": "a1", "consumerId": "c1", "declared": True,
                   "calls": {"d7": 0, "d30": 0, "d90": 0},
                   "errors": {"d7": 0, "d30": 0, "d90": 0},
                   "lastCall": None, "errorRate": 0.0}]}
HIST = [{"date": "2026-07-30", "apis": 1, "consumersRegistered": 1,
         "consumersActive": 0, "calls": 0}]

class TestPublication(unittest.TestCase):
    def test_ecrit_les_deux_fichiers(self):
        with tempfile.TemporaryDirectory() as d:
            publish(d, GOOD, HIST)
            self.assertTrue((pathlib.Path(d) / "carto.json").exists())
            self.assertTrue((pathlib.Path(d) / "history.json").exists())

    def test_refuse_un_document_invalide(self):
        bad = dict(GOOD, apis=[])
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(RefusedPublication):
                publish(d, bad, HIST)

    def test_une_publication_refusee_laisse_la_carto_precedente_intacte(self):
        # regle D8 : ne jamais ecraser une bonne carto par une mauvaise
        with tempfile.TemporaryDirectory() as d:
            publish(d, GOOD, HIST)
            before = (pathlib.Path(d) / "carto.json").read_text()
            with self.assertRaises(RefusedPublication):
                publish(d, dict(GOOD, apis=[]), HIST)
            self.assertEqual((pathlib.Path(d) / "carto.json").read_text(), before)

    def test_ne_laisse_aucun_fichier_temporaire(self):
        with tempfile.TemporaryDirectory() as d:
            publish(d, GOOD, HIST)
            self.assertEqual(sorted(p.name for p in pathlib.Path(d).iterdir()),
                             ["carto.json", "history.json"])

    def test_le_json_ecrit_est_relisible(self):
        with tempfile.TemporaryDirectory() as d:
            publish(d, GOOD, HIST)
            self.assertEqual(json.loads((pathlib.Path(d) / "carto.json").read_text())["schemaVersion"],
                             SCHEMA_VERSION)

    def test_echec_d_ecriture_du_second_fichier_ne_laisse_aucun_tmp(self):
        # Le premier temporaire (carto.json.tmp) s'ecrit sans probleme, le
        # second (history.json.tmp) echoue : rien ne doit trainer, ni tmp
        # ni fichier final, puisque aucune bascule n'a encore eu lieu.
        original = publish_mod._write_tmp

        def flaky(path, payload):
            if path.name == "history.json":
                raise OSError("panne simulee d'ecriture")
            return original(path, payload)

        with tempfile.TemporaryDirectory() as d:
            with mock.patch.object(publish_mod, "_write_tmp", side_effect=flaky):
                with self.assertRaises(OSError):
                    publish(d, GOOD, HIST)
            self.assertEqual(list(pathlib.Path(d).iterdir()), [])

    def test_echec_pendant_l_ecriture_ne_laisse_pas_de_residu(self):
        # Un echec au milieu de l'ecriture elle-meme (pas seulement entre
        # deux etapes) ne doit pas laisser de temporaire orphelin.
        with tempfile.TemporaryDirectory() as d:
            path = pathlib.Path(d) / "carto.json"
            with mock.patch.object(pathlib.Path, "write_text",
                                   side_effect=OSError("panne simulee d'ecriture")):
                with self.assertRaises(OSError):
                    publish_mod._write_tmp(path, GOOD)
            self.assertEqual(list(pathlib.Path(d).iterdir()), [])
