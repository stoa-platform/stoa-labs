import unittest
from carto.collect.model import SCHEMA_VERSION, validate_carto, validate_history

def doc(**over):
    d = {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": "2026-07-30T02:11:00Z",
        "window": {"requestedDays": 90, "coveredDays": 34,
                   "oldestEvent": "2026-06-26T00:00:00Z"},
        "unidentifiedCallShare": 0.0,
        "unidentifiedCallShareByWindow": {"d7": 0.0, "d30": None, "d90": 0.0},
        "apis": [{"id": "a1", "name": "orders", "version": "1.0",
                  "owner": "team-x", "active": True, "createdAt": None,
                  "ghost": False}],
        "consumers": [{"id": "c1", "name": "crm", "owner": "team-y",
                       "contact": "crm@ex.invalid", "createdAt": None,
                       "ghost": False}],
        "edges": [{"apiId": "a1", "consumerId": "c1", "declared": True,
                   "calls": {"d7": 1, "d30": 2, "d90": 3},
                   "errors": {"d7": 0, "d30": 0, "d90": 0},
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

class TestChampsConsommesParLeRendu(unittest.TestCase):
    """I3 — le validateur garantit TOUT ce que le rendu consomme.

    `(e.errorRate * 100).toFixed(1)` affiche `NaN %` comme si c'etait une
    mesure, et le filtre des taux anormaux se tait, si le champ manque.
    """

    def test_refuse_un_errorrate_manquant(self):
        d = doc()
        del d["edges"][0]["errorRate"]
        self.assertTrue(any("errorRate" in e for e in validate_carto(d)))

    def test_refuse_un_errorrate_non_numerique(self):
        d = doc()
        d["edges"][0]["errorRate"] = "0.1"
        self.assertTrue(any("errorRate" in e for e in validate_carto(d)))

    def test_refuse_un_errorrate_hors_de_zero_un(self):
        d = doc()
        d["edges"][0]["errorRate"] = 12.0
        self.assertTrue(any("errorRate" in e for e in validate_carto(d)))

    def test_refuse_un_lastcall_manquant(self):
        d = doc()
        del d["edges"][0]["lastCall"]
        self.assertTrue(any("lastCall" in e for e in validate_carto(d)))

    def test_accepte_un_lastcall_nul_mais_pas_un_lastcall_numerique(self):
        d = doc()
        d["edges"][0]["lastCall"] = None
        self.assertEqual(validate_carto(d), [])
        d["edges"][0]["lastCall"] = 1785431849637
        self.assertTrue(any("lastCall" in e for e in validate_carto(d)))

    def test_refuse_un_ghost_manquant_sur_une_api(self):
        d = doc()
        del d["apis"][0]["ghost"]
        self.assertTrue(any("ghost" in e for e in validate_carto(d)))

    def test_refuse_un_ghost_manquant_sur_un_consommateur(self):
        d = doc()
        del d["consumers"][0]["ghost"]
        self.assertTrue(any("ghost" in e for e in validate_carto(d)))

    def test_refuse_une_part_de_trafic_non_identifie_absente(self):
        d = doc()
        del d["unidentifiedCallShare"]
        self.assertTrue(any("unidentifiedCallShare" in e for e in validate_carto(d)))

    def test_refuse_une_part_de_trafic_non_identifie_aberrante(self):
        self.assertTrue(any("unidentifiedCallShare" in e
                            for e in validate_carto(doc(unidentifiedCallShare=1.4))))

    def test_un_booleen_ne_passe_pas_pour_un_taux(self):
        # bool est un int en Python : True glisserait sans ce garde-fou
        self.assertTrue(any("unidentifiedCallShare" in e
                            for e in validate_carto(doc(unidentifiedCallShare=True))))

    def test_refuse_une_part_par_fenetre_absente(self):
        # c'est ELLE que lit la porte de publication (build.gating_share) :
        # absente, la porte n'aurait plus rien a lire et se tairait.
        d = doc()
        del d["unidentifiedCallShareByWindow"]
        self.assertTrue(any("unidentifiedCallShareByWindow" in e
                            for e in validate_carto(d)))

    def test_refuse_une_fenetre_manquante_dans_la_part_par_fenetre(self):
        self.assertTrue(any("unidentifiedCallShareByWindow" in e
                            for e in validate_carto(
                                doc(unidentifiedCallShareByWindow={"d7": 0.0, "d90": 0.0}))))

    def test_accepte_null_pour_une_fenetre_sans_trafic_servi(self):
        # null = « rien a imputer », distinct de 0.0 = « tout est identifie ».
        self.assertEqual(validate_carto(doc(
            unidentifiedCallShareByWindow={"d7": None, "d30": None, "d90": None})), [])

    def test_refuse_une_part_par_fenetre_aberrante(self):
        self.assertTrue(any("unidentifiedCallShareByWindow" in e
                            for e in validate_carto(
                                doc(unidentifiedCallShareByWindow={"d7": 1.4, "d30": 0.0, "d90": 0.0}))))

    def test_refuse_des_erreurs_absentes_sur_une_arete(self):
        # sans elles, le trafic servi n'est pas recalculable depuis le document
        d = doc()
        del d["edges"][0]["errors"]
        self.assertTrue(any("errors" in e for e in validate_carto(d)))

    def test_refuse_des_erreurs_superieures_aux_appels(self):
        # un trafic servi negatif fausserait le ratio sans rien casser d'autre
        d = doc()
        d["edges"][0]["errors"] = {"d7": 5, "d30": 0, "d90": 0}
        self.assertTrue(any("errors" in e for e in validate_carto(d)))

    def test_refuse_un_oldestevent_manquant(self):
        d = doc()
        del d["window"]["oldestEvent"]
        self.assertTrue(any("oldestEvent" in e for e in validate_carto(d)))

    def test_accepte_un_oldestevent_nul_index_vide(self):
        d = doc()
        d["window"]["oldestEvent"] = None
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
