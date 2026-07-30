import unittest
from carto.collect.history import counters, append_history

def carto(edges):
    return {"generatedAt": "2026-07-30T02:11:00Z",
            "apis": [{"id": "a1"}, {"id": "a2"}],
            "consumers": [{"id": "c1"}, {"id": "c2"}, {"id": "c3"}],
            "edges": edges}

def e(api, con, d90):
    return {"apiId": api, "consumerId": con, "declared": True,
            "calls": {"d7": 0, "d30": 0, "d90": d90}, "lastCall": None, "errorRate": 0.0}

class TestCompteurs(unittest.TestCase):
    def test_compte_tous_les_consommateurs_enregistres(self):
        c = counters(carto([e("a1", "c1", 5)]))
        self.assertEqual(c["consumersRegistered"], 3)

    def test_ne_compte_actifs_que_ceux_qui_ont_appele(self):
        c = counters(carto([e("a1", "c1", 5), e("a1", "c2", 0)]))
        self.assertEqual(c["consumersActive"], 1)

    def test_somme_les_appels_de_la_fenetre(self):
        c = counters(carto([e("a1", "c1", 5), e("a2", "c2", 7)]))
        self.assertEqual(c["calls"], 12)

    def test_la_date_est_celle_de_la_collecte_sans_heure(self):
        self.assertEqual(counters(carto([]))["date"], "2026-07-30")

class TestAppend(unittest.TestCase):
    def test_ajoute_une_ligne(self):
        rows = append_history([], {"date": "2026-07-30", "apis": 1,
                                   "consumersRegistered": 1, "consumersActive": 1, "calls": 0})
        self.assertEqual(len(rows), 1)

    def test_rejouer_le_meme_jour_remplace_au_lieu_de_dupliquer(self):
        # un job relance apres echec ne doit pas creer deux points le meme jour
        base = [{"date": "2026-07-30", "apis": 1, "consumersRegistered": 1,
                 "consumersActive": 1, "calls": 0}]
        rows = append_history(base, {"date": "2026-07-30", "apis": 9,
                                     "consumersRegistered": 9, "consumersActive": 9, "calls": 9})
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["apis"], 9)

    def test_les_lignes_restent_triees_par_date(self):
        rows = append_history([{"date": "2026-07-30", "apis": 1, "consumersRegistered": 1,
                                "consumersActive": 1, "calls": 0}],
                              {"date": "2026-07-29", "apis": 2, "consumersRegistered": 2,
                               "consumersActive": 2, "calls": 0})
        self.assertEqual([r["date"] for r in rows], ["2026-07-29", "2026-07-30"])
