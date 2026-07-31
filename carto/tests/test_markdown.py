"""Tests du rendu Markdown publie dans le depot git dedie.

Ce que ces tests gardent en priorite : LE DETERMINISME. Ces pages n'existent
que pour que leur `git diff` quotidien soit lisible ; un rendu qui reordonne
ses lignes d'un jour a l'autre produit un remaniement illisible, plus personne
ne lit les diffs, et toute la demarche tombe. Le determinisme n'est donc pas
une elegance d'implementation ici, c'est la fonction du produit.
"""
import contextlib
import io
import json
import pathlib
import re
import unittest

from carto.collect.model import SCHEMA_VERSION
from carto.render import markdown as md

RENDER_HTML = pathlib.Path(__file__).resolve().parents[1] / "render" / "index.html"


def carto(**surcharges):
    """Un document minimal mais COMPLET : deux APIs, des fantomes, un muet."""
    doc = {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": "2026-07-31T02:11:04.881210Z",
        "window": {"requestedDays": 90, "coveredDays": 34,
                   "oldestEvent": "2026-06-27T17:17:29.637Z"},
        "unidentifiedCallShare": 0.1,
        "apis": [
            {"id": "a-paie", "name": "paie", "version": "1.0.0", "owner": "RH",
             "active": True, "createdAt": None, "ghost": False},
            {"id": "a-compta", "name": "compta", "version": "2.0.0", "owner": None,
             "active": True, "createdAt": None, "ghost": False},
            {"id": "a-morte", "name": "(inconnu) a-morte", "version": None,
             "owner": None, "active": False, "createdAt": None, "ghost": True},
        ],
        "consumers": [
            {"id": "c-portail", "name": "portail", "owner": "Web",
             "contact": "web@exemple.invalid", "createdAt": "2026-05-04T09:00:00Z",
             "ghost": False},
            {"id": "c-batch", "name": "batch", "owner": "Prod",
             "contact": "prod@exemple.invalid", "createdAt": "2026-06-01T09:00:00Z",
             "ghost": False},
            {"id": "c-muet", "name": "muet", "owner": "Prod",
             "contact": "prod@exemple.invalid", "createdAt": "2026-06-08T09:00:00Z",
             "ghost": False},
            {"id": "Unknown", "name": "(inconnu) Unknown", "owner": None,
             "contact": None, "createdAt": None, "ghost": True},
        ],
        "edges": [
            edge("a-paie", "c-portail", 10, declared=True,
                 last="2026-07-30T18:00:00.123Z"),
            edge("a-paie", "c-batch", 500, declared=False,
                 last="2026-07-30T19:00:00.456Z"),
            edge("a-paie", "c-muet", 0, declared=True),
            edge("a-compta", "c-portail", 300, declared=True, erreurs=0.20,
                 last="2026-07-31T01:00:00.789Z"),
            edge("a-morte", "Unknown", 40, declared=False),
        ],
    }
    doc.update(surcharges)
    return doc


def edge(api, conso, d90, declared=True, erreurs=0.0, last=None):
    return {"apiId": api, "consumerId": conso, "declared": declared,
            "calls": {"d7": d90 // 10, "d30": d90 // 2, "d90": d90},
            "lastCall": last, "errorRate": erreurs}


HISTORY = [
    {"date": "2026-07-20", "apis": 1, "consumersRegistered": 2,
     "consumersActive": 1, "calls": 100},
    {"date": "2026-07-24", "apis": 2, "consumersRegistered": 2,
     "consumersActive": 2, "calls": 700},   # meme semaine ISO que le 20
    {"date": "2026-07-30", "apis": 2, "consumersRegistered": 3,
     "consumersActive": 2, "calls": 800},
    {"date": "2026-07-31", "apis": 2, "consumersRegistered": 3,
     "consumersActive": 2, "calls": 850},
]


def sans_insecables(texte):
    """Le rendu met des espaces INSECABLES dans les nombres et devant « % » :
    les assertions comparent du texte lisible, pas des codes de caractere."""
    return texte.replace(" ", " ")


def table_hebdo(page_evolution):
    """La table MESUREE seule : la serie retro-calculee vit sous son propre
    titre, et confondre les deux ferait passer ce test pour la mauvaise raison."""
    return page_evolution.split("## Série rétro-calculée")[0]


def lignes_du_tableau(page):
    """Les lignes de donnees d'un tableau Markdown (ni en-tete ni separateur)."""
    return [l for l in page.splitlines()
            if l.startswith("|") and not set(l) <= set("|-: ")
            and not l.startswith("| API |") and not l.startswith("| Mesure |")
            and not l.startswith("| Consommateur |") and not l.startswith("| Semaine |")
            and not l.startswith("| Statut |")]


class TestDeterminisme(unittest.TestCase):
    """La propriete qui fait vivre ou mourir la publication."""

    def test_deux_rendus_des_memes_donnees_sont_identiques_octet_pour_octet(self):
        a = md.render_pages(carto(), HISTORY)
        b = md.render_pages(carto(), HISTORY)
        self.assertEqual(list(a), list(b))
        for nom in a:
            self.assertEqual(a[nom].encode("utf-8"), b[nom].encode("utf-8"), nom)

    def test_un_changement_de_volume_ne_reordonne_aucune_ligne(self):
        """LE test central. Les volumes changent tous les jours ; si l'ordre en
        dependait, chaque diff serait un remaniement complet."""
        avant = md.render_pages(carto(), HISTORY)
        gros = carto()
        # Le plus petit consommateur devient de tres loin le plus gros.
        for e in gros["edges"]:
            if (e["apiId"], e["consumerId"]) == ("a-paie", "c-portail"):
                e["calls"] = {"d7": 99999, "d30": 99999, "d90": 99999}
        apres = md.render_pages(gros, HISTORY)

        def couples(page):
            return [tuple(c.strip() for c in l.split("|")[1:4])
                    for l in lignes_du_tableau(page)]

        self.assertEqual(couples(avant["apis.md"]), couples(apres["apis.md"]))
        self.assertEqual(couples(avant["consommateurs.md"]),
                         couples(apres["consommateurs.md"]))
        # ... et pourtant le volume, lui, a bien change : le test ne passerait
        # pas trivialement sur deux rendus identiques.
        self.assertNotEqual(avant["apis.md"], apres["apis.md"])

    def test_l_ordre_d_arrivee_des_objets_ne_change_pas_le_rendu(self):
        """La gateway ne garantit l'ordre d'aucune de ses reponses."""
        droit = md.render_pages(carto(), HISTORY)
        melange = carto()
        melange["apis"].reverse()
        melange["consumers"].reverse()
        melange["edges"].reverse()
        self.assertEqual(md.render_pages(melange, HISTORY), droit)

    def test_aucune_page_ne_porte_d_horodatage_plus_fin_que_le_jour(self):
        """Une seconde qui bouge est du bruit de diff quotidien."""
        for nom, page in md.render_pages(carto(), HISTORY).items():
            self.assertIsNone(re.search(r"\d{2}:\d{2}:\d{2}", page),
                              f"{nom} porte une heure")
            self.assertNotIn("T02:", page)

    def test_le_message_de_commit_est_lui_aussi_deterministe(self):
        self.assertEqual(md.commit_message(carto(), HISTORY),
                         md.commit_message(carto(), HISTORY))

    def test_le_tri_ne_depend_pas_de_la_locale_de_la_machine(self):
        """Un agent de CI et un serveur client n'ont pas la meme locale ; si
        l'ordre en dependait, le premier passage sur l'autre machine
        reordonnerait tout le fichier pour rien."""
        doc = carto()
        for c, nom in zip(doc["consumers"], ["Zebre", "eleve", "École", "Aaa"]):
            c["name"] = nom
        pages = md.render_pages(doc, HISTORY)
        noms = [l.split("|")[1].strip() for l in lignes_du_tableau(pages["consommateurs.md"])]
        self.assertEqual(noms, sorted(noms, key=str.casefold))


class TestEnTeteDeFraicheur(unittest.TestCase):
    """Une page Markdown perimee dans git a l'air d'une page fraiche."""

    def test_chaque_page_porte_la_date_de_collecte_dans_ses_premieres_lignes(self):
        for nom, page in md.render_pages(carto(), HISTORY).items():
            tete = "\n".join(page.splitlines()[:6])
            self.assertIn("2026-07-31", tete, nom)

    def test_la_fenetre_reellement_couverte_est_en_tete(self):
        tete = "\n".join(md.render_pages(carto(), HISTORY)["README.md"].splitlines()[:6])
        self.assertIn("Fenêtre réellement couverte : 34 jours",
                      sans_insecables(tete))

    def test_la_page_dit_elle_meme_comment_reperer_une_donnee_vieille(self):
        page = md.render_pages(carto(), HISTORY)["README.md"]
        self.assertIn("périmée", page)
        self.assertIn("ni celle d'aujourd'hui ni celle d'hier", page)

    def test_la_part_non_identifiee_alerte_au_dela_du_seuil(self):
        doc = carto(unidentifiedCallShare=0.94)
        page = md.render_pages(doc, HISTORY)["README.md"]
        self.assertIn("n'est PAS fiable", page)
        self.assertIn("94,0", page)

    def test_la_part_non_identifiee_n_alerte_pas_en_deca_du_seuil(self):
        page = md.render_pages(carto(unidentifiedCallShare=0.1), HISTORY)["README.md"]
        self.assertNotIn("n'est PAS fiable", page)

    def test_le_seuil_est_celui_de_la_page_html(self):
        """Deux rendus du meme document ne doivent pas s'alarmer a des moments
        differents : le seuil est un reglage du PRODUIT, pas de chaque rendu."""
        html = RENDER_HTML.read_text(encoding="utf-8")
        m = re.search(r"const SEUIL_NON_IDENTIFIE = ([0-9.]+);", html)
        self.assertIsNotNone(m, "le seuil a change de forme dans index.html")
        self.assertEqual(float(m.group(1)), md.SEUIL_NON_IDENTIFIE)


class TestAnnuaire(unittest.TestCase):
    def test_les_consommateurs_sans_aucun_appel_sont_dans_l_annuaire(self):
        """C'est la page des campagnes de communication : ce sont EUX qu'il
        faut prevenir avant de deprecier une API."""
        page = md.render_pages(carto(), HISTORY)["consommateurs.md"]
        self.assertIn("| muet |", page)

    def test_un_appelant_hors_inventaire_est_exclu_de_l_annuaire(self):
        page = md.render_pages(carto(), HISTORY)["consommateurs.md"]
        self.assertNotIn("| (inconnu) Unknown |", page)

    def test_les_contacts_sont_collables_dedoublonnes_et_tries(self):
        page = md.render_pages(carto(), HISTORY)["consommateurs.md"]
        bloc = page.split("```")[1].strip()
        self.assertEqual(bloc, "prod@exemple.invalid; web@exemple.invalid")

    def test_sans_aucun_contact_la_page_le_dit_au_lieu_de_montrer_un_bloc_vide(self):
        doc = carto()
        for c in doc["consumers"]:
            c["contact"] = None
        page = md.render_pages(doc, HISTORY)["consommateurs.md"]
        self.assertIn("Aucun contact renseigné", page)
        self.assertNotIn("```", page)


class TestTableALaDoubleEntree(unittest.TestCase):
    def test_une_ligne_par_lien_avec_son_statut(self):
        page = md.render_pages(carto(), HISTORY)["apis.md"]
        lignes = [l for l in lignes_du_tableau(page) if l.count("|") == 10]
        self.assertEqual(len(lignes), 5)
        self.assertIn("| actif |", page)
        self.assertIn("| déclaré, inactif |", page)
        self.assertIn("| non déclaré |", page)

    def test_les_trois_fenetres_de_volume_sont_presentes(self):
        page = md.render_pages(carto(), HISTORY)["apis.md"]
        self.assertIn("| 7 j | 30 j | 90 j |", page)

    def test_la_page_avoue_que_la_fenetre_couverte_est_plus_courte(self):
        page = md.render_pages(carto(), HISTORY)["apis.md"]
        self.assertIn("la fenêtre réellement couverte est de 34 jours", page)

    def test_un_nom_qui_contient_une_barre_ne_casse_pas_le_tableau(self):
        doc = carto()
        doc["apis"][0]["name"] = "paie|v2"
        page = md.render_pages(doc, HISTORY)["apis.md"]
        self.assertIn("paie\\|v2", page)
        for ligne in lignes_du_tableau(page):
            self.assertNotIn("| paie|v2 |", ligne)


class TestSignaux(unittest.TestCase):
    def test_les_cinq_signaux_sont_rendus_avec_leur_phrase_d_aide(self):
        page = md.render_pages(carto(), HISTORY)["README.md"]
        for titre in ("APIs sans aucun appel", "Consommateurs déclarés inactifs",
                      "Trafic sans autorisation déclarée",
                      "Objets disparus encore appelés", "Taux d'erreur anormal"):
            self.assertIn(titre, page)
        self.assertIn("Candidates à la décommission", page)
        self.assertIn("à relancer, pas à supprimer", page)

    def test_un_signal_vide_se_dit_au_lieu_de_disparaitre(self):
        """Un bloc absent se lit « pas mesuré » ; un bloc vide se lit « rien a
        signaler ». Ce n'est pas la meme information."""
        doc = carto()
        doc["edges"] = [e for e in doc["edges"] if e["errorRate"] <= 0.05]
        page = md.render_pages(doc, HISTORY)["README.md"]
        self.assertIn("Taux d'erreur anormal (0)", page)
        self.assertIn("Rien à signaler.", page)

    def test_le_signal_des_fantomes_s_appuie_sur_le_champ_ghost(self):
        """Sur le contrat de donnees, jamais sur le prefixe « (inconnu) » du
        nom : renommer une etiquette ne doit pas vider un signal en silence."""
        doc = carto()
        for o in doc["apis"] + doc["consumers"]:
            if o.get("ghost"):
                o["name"] = "un-nom-tout-a-fait-ordinaire"
        page = md.render_pages(doc, HISTORY)["README.md"]
        self.assertIn("Objets disparus encore appelés (2)", page)


class TestEvolution(unittest.TestCase):
    def test_une_semaine_se_resume_par_sa_derniere_valeur_jamais_par_une_somme(self):
        page = table_hebdo(md.render_pages(carto(), HISTORY)["evolution.md"])
        semaines = [l for l in lignes_du_tableau(page) if l.startswith("| 2026-S")]
        # 20 et 24 juillet sont dans la meme semaine ISO : une seule ligne, et
        # c'est la valeur du 24 (700), pas la somme (800).
        self.assertEqual(len(semaines), 2)
        self.assertIn("700", semaines[0])
        self.assertNotIn("800", semaines[0])

    def test_l_ordre_est_chronologique_croissant(self):
        """Une semaine de plus = une ligne AJOUTEE en fin de table, donc un
        diff d'une ligne. En ordre decroissant, tout le tableau se decale."""
        page = table_hebdo(md.render_pages(carto(), HISTORY)["evolution.md"])
        semaines = [l.split("|")[1].strip() for l in lignes_du_tableau(page)
                    if l.startswith("| 2026-S")]
        self.assertEqual(semaines, sorted(semaines))

    def test_la_reserve_sur_la_serie_retro_calculee_est_ecrite(self):
        page = md.render_pages(carto(), HISTORY)["evolution.md"]
        self.assertIn("courbe de survivants", page.replace("**", ""))
        self.assertIn("sous-estime le passé", page.replace("**", ""))
        self.assertIn("aucune", page)

    def test_aucune_serie_retro_pour_les_apis(self):
        """La gateway ne date pas ses APIs : ne pas fabriquer de substitut."""
        page = md.render_pages(carto(), HISTORY)["evolution.md"]
        self.assertIn("Historique des APIs non reconstituable", page)

    def test_l_absence_de_graphe_mermaid_est_assumee_et_expliquee(self):
        page = md.render_pages(carto(), HISTORY)["evolution.md"]
        self.assertNotIn("```mermaid\n", page)
        self.assertIn("forge du client n'a pas été vérifiée", page.replace("**", ""))

    def test_un_journal_vide_ne_casse_rien(self):
        pages = md.render_pages(carto(), [])
        self.assertIn("Aucun historique pour l'instant", pages["evolution.md"])
        self.assertIn("Aucune collecte précédente", pages["README.md"])


class TestMessageDeCommit(unittest.TestCase):
    def test_le_sujet_resume_ce_qui_a_change(self):
        msg = md.commit_message(carto(), HISTORY)
        sujet = msg.splitlines()[0]
        self.assertIn("2026-07-31", sujet)
        self.assertIn("APIs", sujet)
        self.assertIn("consommateurs", sujet)
        self.assertNotIn("mise à jour", msg.lower())

    def test_les_ecarts_sont_calcules_contre_la_collecte_PRECEDENTE(self):
        """Pas contre le point du jour : le rendu du jour serait compare a
        lui-meme et tous les ecarts vaudraient zero."""
        sujet = md.commit_message(carto(), HISTORY).splitlines()[0]
        # dernier point : 800 appels le 2026-07-30 ; carto du jour : 850.
        self.assertIn("2026-07-30", md.commit_message(carto(), HISTORY))
        self.assertIn("(+", sujet)

    def test_sans_historique_le_message_le_dit(self):
        msg = md.commit_message(carto(), [])
        self.assertIn("Première collecte publiée", msg)

    def test_le_corps_porte_la_qualite_de_la_collecte_et_les_signaux(self):
        msg = md.commit_message(carto(unidentifiedCallShare=0.94), HISTORY)
        self.assertIn("Fenêtre réellement couverte", msg)
        self.assertIn("NON fiable", msg)
        self.assertIn("Signaux :", msg)


class TestRefusDeVersion(unittest.TestCase):
    def test_un_document_d_une_autre_version_n_est_pas_rendu(self):
        """Meme refus que la page HTML — et ici la page fausse serait COMMITEE,
        donc durable."""
        with self.assertRaises(md.VersionNonSupportee):
            md.render_pages(carto(schemaVersion=SCHEMA_VERSION + 1), HISTORY)

    def test_le_refus_dit_quoi_faire(self):
        try:
            md.render_pages(carto(schemaVersion=1), HISTORY)
        except md.VersionNonSupportee as err:
            self.assertIn("redeployer", str(err).lower())
        else:
            self.fail("aucun refus")


class TestContrat(unittest.TestCase):
    def test_les_pages_produites_sont_exactement_celles_annoncees(self):
        self.assertEqual(tuple(md.render_pages(carto(), HISTORY)), md.PAGES)

    def test_le_readme_renvoie_vers_toutes_les_autres_pages_et_les_donnees(self):
        page = md.render_pages(carto(), HISTORY)["README.md"]
        for cible in md.PAGES[1:] + md.FICHIERS_DONNEES:
            self.assertIn(f"({cible})", page, cible)

    def test_le_module_de_rendu_ne_fait_aucune_io(self):
        """Fonction pure : c'est ce qui rend le determinisme testable, et ce qui
        garantit qu'aucun appel a git ne se glisse dans le rendu."""
        source = (pathlib.Path(md.__file__)).read_text(encoding="utf-8")
        for interdit in ("import os", "import subprocess", "open(", "pathlib",
                         "datetime.now", "utcnow"):
            self.assertNotIn(interdit, source, interdit)

    def test_les_pages_se_terminent_par_une_seule_fin_de_ligne(self):
        """Un fichier sans saut final, ou avec plusieurs, produit un diff
        parasite au premier outil qui le normalise."""
        for nom, page in md.render_pages(carto(), HISTORY).items():
            self.assertTrue(page.endswith("\n"), nom)
            self.assertFalse(page.endswith("\n\n"), nom)

    def test_les_compteurs_excluent_les_objets_hors_inventaire(self):
        """Meme definition que carto/collect/history.py : un objet inconnu
        n'est pas un objet enregistre."""
        c = md.compteurs(carto())
        self.assertEqual(c["apis"], 2)
        self.assertEqual(c["consumersRegistered"], 3)
        self.assertEqual(c["consumersActive"], 2)
        self.assertEqual(c["calls"], 850)      # le trafic des fantomes compte


class TestCliRendu(unittest.TestCase):
    """La seule I/O du rendu Markdown vit dans `carto/render/__main__.py`."""

    def test_ecrit_les_pages_les_donnees_et_le_rendu_autonome(self):
        import tempfile
        from carto.render.__main__ import main
        with tempfile.TemporaryDirectory() as d:
            src, out = pathlib.Path(d) / "src", pathlib.Path(d) / "out"
            src.mkdir()
            (src / "carto.json").write_text(json.dumps(carto()), encoding="utf-8")
            (src / "history.json").write_text(json.dumps(HISTORY), encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                code = main(["--source", str(src), "--out", str(out), "--message"])
            self.assertEqual(code, 0)
            for nom in md.PAGES + md.FICHIERS_DONNEES:
                self.assertTrue((out / nom).exists(), nom)
            self.assertTrue((out / ".message").read_text(encoding="utf-8").startswith("carto "))

            # Le fichier publie doit etre AUTOPORTANT : plus aucun fetch, les
            # deux documents embarques et relisibles tels quels (pas les
            # marqueurs bruts du gabarit committe).
            html = (out / "index.html").read_text(encoding="utf-8")
            self.assertNotIn("fetch(", html)
            self.assertNotIn("<!--CARTO_DATA-->", html)
            debut = html.index('id="carto-data">') + len('id="carto-data">')
            fin = html.index("</script>", debut)
            self.assertEqual(json.loads(html[debut:fin])["apis"][0]["name"], "paie")
            debut = html.index('id="carto-history">') + len('id="carto-history">')
            fin = html.index("</script>", debut)
            self.assertEqual(len(json.loads(html[debut:fin])), len(HISTORY))

    def test_le_rendu_autonome_refuse_un_gabarit_dont_le_marqueur_a_disparu(self):
        """Meme famille de refus que la version de schema : mieux vaut un
        echec franc a la publication qu'une page assemblee au hasard si
        `render/index.html` change de forme sans que ce module ait suivi."""
        import tempfile
        from carto.render import __main__ as render_main
        from carto.render.page import GabaritInvalide
        with tempfile.TemporaryDirectory() as d:
            src, out = pathlib.Path(d) / "src", pathlib.Path(d) / "out"
            src.mkdir()
            (src / "carto.json").write_text(json.dumps(carto()), encoding="utf-8")
            faux_gabarit = pathlib.Path(d) / "faux.html"
            faux_gabarit.write_text("<html>sans marqueur</html>", encoding="utf-8")
            ancien = render_main.RENDU_HTML
            render_main.RENDU_HTML = faux_gabarit
            try:
                with self.assertRaises(GabaritInvalide):
                    with contextlib.redirect_stdout(io.StringIO()):
                        render_main.main(["--source", str(src), "--out", str(out)])
            finally:
                render_main.RENDU_HTML = ancien

    def test_un_journal_absent_est_le_cas_normal_du_premier_passage(self):
        import tempfile
        from carto.render.__main__ import main
        with tempfile.TemporaryDirectory() as d:
            src, out = pathlib.Path(d) / "src", pathlib.Path(d) / "out"
            src.mkdir()
            (src / "carto.json").write_text(json.dumps(carto()), encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                code = main(["--source", str(src), "--out", str(out)])
            self.assertEqual(code, 0)
            self.assertIn("Aucun historique", (out / "evolution.md").read_text(encoding="utf-8"))
