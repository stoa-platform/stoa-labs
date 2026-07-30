import json, pathlib, tempfile, unittest
from carto.collect.publish import publish, RefusedPublication

GOOD = {"schemaVersion": 1, "generatedAt": "2026-07-30T00:00:00Z",
        "window": {"requestedDays": 90, "coveredDays": 90, "oldestEvent": None},
        "apis": [{"id": "a1", "name": "orders"}],
        "consumers": [{"id": "c1", "name": "crm"}],
        "edges": [{"apiId": "a1", "consumerId": "c1", "declared": True,
                   "calls": {"d7": 0, "d30": 0, "d90": 0},
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
            self.assertEqual(json.loads((pathlib.Path(d) / "carto.json").read_text())["schemaVersion"], 1)
