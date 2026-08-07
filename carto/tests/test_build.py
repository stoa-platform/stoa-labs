import unittest
from carto.collect.build import build_carto, gating_share, InconsistentWindows
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

    def test_le_signal_fantome_est_un_champ_pas_une_etiquette(self):
        # le rendu, history.py et l'annuaire s'appuient sur `ghost`. Renommer
        # l'etiquette "(inconnu)" ne doit pas pouvoir vider le signal.
        d = build_carto(APIS, CONS, set(),
                        obs([{"apiId": "zz", "consumerId": "xx", "calls": 3,
                              "lastCall": "2026-07-29T00:00:00Z", "errors": 0}]),
                        WIN, "2026-07-30T00:00:00Z")
        self.assertTrue(next(a for a in d["apis"] if a["id"] == "zz")["ghost"])
        self.assertTrue(next(c for c in d["consumers"] if c["id"] == "xx")["ghost"])

    def test_tous_les_noeuds_de_l_inventaire_portent_ghost_false(self):
        # un champ du contrat n'est jamais "parfois present" : un `undefined`
        # cote rendu se comporterait comme un false silencieux.
        d = build_carto(APIS, CONS, set(), obs([]), WIN, "2026-07-30T00:00:00Z")
        self.assertEqual([a["ghost"] for a in d["apis"]], [False])
        self.assertEqual([c["ghost"] for c in d["consumers"]], [False, False])


class TestTraficNonIdentifie(unittest.TestCase):
    """C2 — terrain V5 : applicationId = "Unknown" sur 100 % du trafic.

    Sans ce chiffre porte au contrat, tout le trafic s'agrege sur un noeud
    fantome, chaque consommateur reel bascule en « declare, inactif », et
    rien ne l'annonce.
    """

    def test_tout_le_trafic_sur_un_appelant_inconnu_donne_une_part_de_1(self):
        d = build_carto(APIS, CONS, {("a1", "c1")},
                        obs([{"apiId": "a1", "consumerId": "Unknown", "calls": 48,
                              "lastCall": "2026-07-29T00:00:00Z", "errors": 0}]),
                        WIN, "2026-07-30T00:00:00Z")
        self.assertEqual(d["unidentifiedCallShare"], 1.0)

    def test_la_part_est_calculee_sur_la_fenetre_longue(self):
        d = build_carto(APIS, CONS, set(),
                        obs([{"apiId": "a1", "consumerId": "Unknown", "calls": 30,
                              "lastCall": "x", "errors": 0},
                             {"apiId": "a1", "consumerId": "c1", "calls": 70,
                              "lastCall": "x", "errors": 0}]),
                        WIN, "2026-07-30T00:00:00Z")
        self.assertEqual(d["unidentifiedCallShare"], 0.3)

    def test_un_trafic_entierement_identifie_donne_zero(self):
        d = build_carto(APIS, CONS, set(),
                        obs([{"apiId": "a1", "consumerId": "c1", "calls": 12,
                              "lastCall": "x", "errors": 0}]),
                        WIN, "2026-07-30T00:00:00Z")
        self.assertEqual(d["unidentifiedCallShare"], 0.0)

    def test_aucun_appel_du_tout_ne_produit_pas_de_division_par_zero(self):
        d = build_carto(APIS, CONS, {("a1", "c1")}, obs([]), WIN, "2026-07-30T00:00:00Z")
        self.assertEqual(d["unidentifiedCallShare"], 0.0)

    def test_la_part_est_au_contrat_et_validee(self):
        d = build_carto(APIS, CONS, set(),
                        obs([{"apiId": "a1", "consumerId": "Unknown", "calls": 5,
                              "lastCall": "x", "errors": 0}]),
                        WIN, "2026-07-30T00:00:00Z")
        self.assertEqual(validate_carto(d), [])


class TestPartNonIdentifieeParFenetre(unittest.TestCase):
    """La part non identifiee, mesuree sur CHAQUE fenetre et non sur d90 seule.

    Mesure du 2026-08-07 sur le labo : 803 evenements non identifies du
    2026-07-30 (debris d'une campagne d'investigation) maintenaient le ratio
    d90 a 99,3 % — donc le job Jenkins au rouge — alors que les jours RECENTS
    etaient identifies a 2/2. Un ratio d90 seul ne sait pas distinguer un
    heritage d'un etat courant : il condamne la publication 90 jours apres la
    correction de la cause.
    """

    def rows(self, *triplets):
        return [{"apiId": "a1", "consumerId": c, "calls": n, "lastCall": "x",
                 "errors": err} for c, n, err in triplets]

    def test_la_part_est_calculee_pour_les_trois_fenetres(self):
        d = build_carto(APIS, CONS, set(),
                        {"d7": self.rows(("Unknown", 1, 0), ("c1", 9, 0)),
                         "d30": self.rows(("Unknown", 5, 0), ("c1", 15, 0)),
                         "d90": self.rows(("Unknown", 180, 0), ("c1", 20, 0))},
                        WIN, "2026-07-30T00:00:00Z")
        self.assertEqual(d["unidentifiedCallShareByWindow"],
                         {"d7": 0.1, "d30": 0.25, "d90": 0.9})

    def test_un_heritage_ancien_ne_condamne_plus_la_fenetre_courte(self):
        # LE cas mesure : d90 pourri par un pic ancien, d7 propre.
        d = build_carto(APIS, CONS, set(),
                        {"d7": self.rows(("c1", 2, 0)),
                         "d30": self.rows(("c1", 6, 0)),
                         "d90": self.rows(("Unknown", 803, 0), ("c1", 6, 0))},
                        WIN, "2026-07-30T00:00:00Z")
        self.assertEqual(d["unidentifiedCallShareByWindow"]["d7"], 0.0)
        self.assertEqual(gating_share(d), ("d7", 0.0))

    def test_une_fenetre_sans_trafic_vaut_null_et_pas_zero(self):
        # 0.0 dirait « tout est identifie » ; il n'y a rien a imputer du tout.
        # Confondre les deux, c'est un vert obtenu par absence de mesure.
        d = build_carto(APIS, CONS, set(),
                        {"d7": [], "d30": [],
                         "d90": self.rows(("Unknown", 50, 0))},
                        WIN, "2026-07-30T00:00:00Z")
        self.assertIsNone(d["unidentifiedCallShareByWindow"]["d7"])
        self.assertIsNone(d["unidentifiedCallShareByWindow"]["d30"])
        self.assertEqual(d["unidentifiedCallShareByWindow"]["d90"], 1.0)

    def test_la_porte_lit_la_plus_courte_fenetre_qui_porte_du_trafic(self):
        # sans ce repli, une carto entierement perimee passerait au vert par
        # d7 vide : le trou de mesure serait lu comme un succes.
        d = build_carto(APIS, CONS, set(),
                        {"d7": [],
                         "d30": self.rows(("Unknown", 8, 0), ("c1", 2, 0)),
                         "d90": self.rows(("Unknown", 8, 0), ("c1", 2, 0))},
                        WIN, "2026-07-30T00:00:00Z")
        self.assertEqual(gating_share(d), ("d30", 0.8))

    def test_sans_aucun_trafic_la_porte_ne_designe_aucune_fenetre(self):
        d = build_carto(APIS, CONS, {("a1", "c1")}, obs([]), WIN,
                        "2026-07-30T00:00:00Z")
        self.assertEqual(gating_share(d), (None, None))


class TestSeulLeTraficServiEstImputable(unittest.TestCase):
    """Un appel REJETE n'a aucun consommateur a perdre.

    Mesure du 2026-08-07 : 6 des 9 evenements non identifies restants etaient
    des 401/403 — dont les controles negatifs anti-spoof emis volontairement.
    Les compter au denominateur de « qui consomme quoi » melange deux signaux :
    « on ne sait pas qui appelle » et « quelqu'un s'est fait refuser ». Chez un
    client, du bruit de scan de credentials sur un endpoint public suffirait
    alors a rendre la carto rouge en permanence, sans qu'aucun consommateur
    reel ne manque. Le second signal a deja sa place : `errorRate` par arete.
    """

    def rows(self, *triplets):
        return [{"apiId": "a1", "consumerId": c, "calls": n, "lastCall": "x",
                 "errors": err} for c, n, err in triplets]

    def win(self, rows):
        return {"d7": rows, "d30": rows, "d90": rows}

    def test_un_trafic_inconnu_entierement_rejete_ne_compte_pas(self):
        d = build_carto(APIS, CONS, set(),
                        self.win(self.rows(("Unknown", 10, 10), ("c1", 10, 0))),
                        WIN, "2026-07-30T00:00:00Z")
        self.assertEqual(d["unidentifiedCallShare"], 0.0)

    def test_les_rejets_d_un_consommateur_identifie_ne_comptent_pas_non_plus(self):
        # la regle porte sur le trafic SERVI, pas sur l'identite de l'appelant :
        # l'appliquer d'un seul cote fabriquerait un ratio flatteur.
        d = build_carto(APIS, CONS, set(),
                        self.win(self.rows(("Unknown", 10, 0), ("c1", 10, 10))),
                        WIN, "2026-07-30T00:00:00Z")
        self.assertEqual(d["unidentifiedCallShare"], 1.0)

    def test_une_fenetre_ou_tout_est_rejete_n_a_rien_a_imputer(self):
        d = build_carto(APIS, CONS, set(),
                        self.win(self.rows(("Unknown", 10, 10), ("c1", 4, 4))),
                        WIN, "2026-07-30T00:00:00Z")
        self.assertIsNone(d["unidentifiedCallShareByWindow"]["d90"])
        self.assertEqual(gating_share(d), (None, None))

    def test_le_taux_d_erreur_de_l_arete_reste_calcule_sur_tous_les_appels(self):
        # ce que la regle ci-dessus retire du ratio ne doit disparaitre nulle
        # part : le trafic rejete reste porte, ailleurs, par son taux d'erreur.
        d = build_carto(APIS, CONS, set(),
                        self.win(self.rows(("c1", 10, 4))),
                        WIN, "2026-07-30T00:00:00Z")
        self.assertEqual(edge(d, "a1", "c1")["errorRate"], 0.4)

    def test_les_erreurs_sont_portees_par_fenetre_au_contrat(self):
        # sans elles au document, le ratio publie n'est pas recalculable par
        # son lecteur — il faudrait le croire sur parole.
        d = build_carto(APIS, CONS, set(),
                        {"d7": self.rows(("c1", 2, 1)),
                         "d30": self.rows(("c1", 5, 2)),
                         "d90": self.rows(("c1", 9, 3))},
                        WIN, "2026-07-30T00:00:00Z")
        self.assertEqual(edge(d, "a1", "c1")["errors"],
                         {"d7": 1, "d30": 2, "d90": 3})

    def test_des_erreurs_non_emboitees_font_echouer(self):
        with self.assertRaises(InconsistentWindows):
            build_carto(APIS, CONS, set(),
                        {"d7": self.rows(("c1", 9, 5)),
                         "d30": self.rows(("c1", 9, 1)),
                         "d90": self.rows(("c1", 9, 1))},
                        WIN, "2026-07-30T00:00:00Z")

    def test_le_document_reste_valide(self):
        d = build_carto(APIS, CONS, set(),
                        self.win(self.rows(("Unknown", 7, 2), ("c1", 3, 0))),
                        WIN, "2026-07-30T00:00:00Z")
        self.assertEqual(validate_carto(d), [])


class TestInvariantDesFenetres(unittest.TestCase):
    """I4 — d7 ⊆ d30 ⊆ d90. `lastCall` et les erreurs ne sont lus que dans la
    fenetre longue : viole, l'invariant produit une arete `d7=980, d90=0`
    affichee « declare, inactif », sans la moindre alerte."""

    def test_une_fenetre_courte_plus_grande_que_la_longue_fait_echouer(self):
        with self.assertRaises(InconsistentWindows) as ctx:
            build_carto(APIS, CONS, set(),
                        {"d7": [{"apiId": "a1", "consumerId": "c1", "calls": 980,
                                 "lastCall": "x", "errors": 0}],
                         "d30": [], "d90": []},
                        WIN, "2026-07-30T00:00:00Z")
        self.assertIn("d7=980", str(ctx.exception))

    def test_d30_superieure_a_d90_fait_echouer(self):
        with self.assertRaises(InconsistentWindows):
            build_carto(APIS, CONS, set(),
                        {"d7": [], "d90": [{"apiId": "a1", "consumerId": "c1",
                                            "calls": 2, "lastCall": "x", "errors": 0}],
                         "d30": [{"apiId": "a1", "consumerId": "c1", "calls": 9,
                                  "lastCall": "x", "errors": 0}]},
                        WIN, "2026-07-30T00:00:00Z")

    def test_l_egalite_stricte_des_trois_fenetres_reste_valide(self):
        rows = [{"apiId": "a1", "consumerId": "c1", "calls": 4,
                 "lastCall": "2026-07-29T00:00:00Z", "errors": 0}]
        d = build_carto(APIS, CONS, set(), {"d7": rows, "d30": rows, "d90": rows},
                        WIN, "2026-07-30T00:00:00Z")
        self.assertEqual(edge(d, "a1", "c1")["calls"], {"d7": 4, "d30": 4, "d90": 4})

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
