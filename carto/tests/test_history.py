import unittest
from carto.collect.history import counters, append_history

def carto(edges, apis=None, consumers=None):
    return {"generatedAt": "2026-07-30T02:11:00Z",
            "apis": apis if apis is not None
                    else [{"id": "a1", "ghost": False}, {"id": "a2", "ghost": False}],
            "consumers": consumers if consumers is not None
                    else [{"id": "c1", "ghost": False}, {"id": "c2", "ghost": False},
                          {"id": "c3", "ghost": False}],
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

class TestFantomes(unittest.TestCase):
    """I5 — un objet inconnu n'est pas un objet enregistré.

    Compter les fantômes dans `consumersRegistered` gonfle l'annuaire ET la
    courbe d'évolution, durablement : avec un `applicationId` non renseigné
    (terrain V5), un seul nœud fantôme suffit à fausser la série.
    """

    def test_un_appelant_non_identifie_n_est_pas_un_consommateur_enregistre(self):
        c = counters(carto([e("a1", "Unknown", 48)],
                           consumers=[{"id": "c1", "ghost": False},
                                      {"id": "Unknown", "ghost": True}]))
        self.assertEqual(c["consumersRegistered"], 1)

    def test_un_appelant_non_identifie_n_est_pas_compte_comme_actif(self):
        c = counters(carto([e("a1", "Unknown", 48)],
                           consumers=[{"id": "c1", "ghost": False},
                                      {"id": "Unknown", "ghost": True}]))
        self.assertEqual(c["consumersActive"], 0)

    def test_une_api_disparue_n_est_pas_une_api_de_l_inventaire(self):
        c = counters(carto([e("zz", "c1", 3)],
                           apis=[{"id": "a1", "ghost": False}, {"id": "zz", "ghost": True}]))
        self.assertEqual(c["apis"], 1)

    def test_le_trafic_des_fantomes_reste_compte_dans_les_appels(self):
        # `calls` mesure du TRAFIC, lequel a bien eu lieu : l'exclure
        # reviendrait a effacer 100 % des appels dans le cas du terrain V5.
        c = counters(carto([e("a1", "Unknown", 48)],
                           consumers=[{"id": "c1", "ghost": False},
                                      {"id": "Unknown", "ghost": True}]))
        self.assertEqual(c["calls"], 48)


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
