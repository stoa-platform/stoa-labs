"""Tests de l'assemblage de la page HTML autoportante (`carto/render/page.py`).

Ce module remplace, dans `render/index.html`, un unique marqueur HTML par
deux blocs `<script type="application/json">` portant `carto.json` et
`history.json` : c'est ce qui rend la page publiée dans le dépôt git dédié
lisible en `file://`, sans plus aucun `fetch`.

Le piège gardé ici en priorité : une valeur du document (un nom d'API ou de
consommateur, saisi à la main côté client) peut porter la séquence
`</script`, qui refermerait le bloc en plein milieu si elle n'était pas
échappée — et transformerait le reste du JSON en HTML interprété.
"""
import json
import unittest

from carto.render import page


def gabarit(corps="<!--CARTO_DATA-->"):
    return f"<!doctype html><body>{corps}</body>"


class TestAssemblage(unittest.TestCase):
    def test_remplace_le_marqueur_par_deux_blocs_script_json(self):
        html = page.assembler(gabarit(), {"a": 1}, [{"date": "2026-07-30"}])
        self.assertIn('<script type="application/json" id="carto-data">', html)
        self.assertIn('<script type="application/json" id="carto-history">', html)
        self.assertNotIn(page.MARQUEUR, html)

    def test_les_deux_documents_se_relisent_identiques(self):
        carto = {"apis": [{"id": "a1", "name": "orders"}], "n": 3.5}
        history = [{"date": "2026-07-01", "apis": 1}, {"date": "2026-07-02", "apis": 2}]
        html = page.assembler(gabarit(), carto, history)

        debut = html.index('id="carto-data">') + len('id="carto-data">')
        fin = html.index("</script>", debut)
        self.assertEqual(json.loads(html[debut:fin]), carto)

        debut = html.index('id="carto-history">') + len('id="carto-history">')
        fin = html.index("</script>", debut)
        self.assertEqual(json.loads(html[debut:fin]), history)

    def test_un_historique_absent_est_embarque_comme_liste_vide(self):
        # Cas normal du tout premier passage (carto/render/__main__.py) : pas
        # d'exception, une liste vide embarquee.
        html = page.assembler(gabarit(), {"a": 1}, None)
        debut = html.index('id="carto-history">') + len('id="carto-history">')
        fin = html.index("</script>", debut)
        self.assertEqual(json.loads(html[debut:fin]), [])

    def test_le_marqueur_absent_est_un_refus_franc(self):
        with self.assertRaises(page.GabaritInvalide):
            page.assembler(gabarit(corps="rien ici"), {"a": 1}, [])

    def test_le_marqueur_duplique_est_un_refus_franc(self):
        with self.assertRaises(page.GabaritInvalide):
            page.assembler(gabarit(corps="<!--CARTO_DATA--><!--CARTO_DATA-->"),
                            {"a": 1}, [])

    def test_le_reste_du_gabarit_n_est_pas_touche(self):
        html = page.assembler("<title>t</title><!--CARTO_DATA--><p>fin</p>",
                              {"a": 1}, [])
        self.assertTrue(html.startswith("<title>t</title>"))
        self.assertTrue(html.endswith("<p>fin</p>"))


class TestEchappementDuPiegeScript(unittest.TestCase):
    """LE piège classique de l'injection JSON dans du HTML : une donnée qui
    porte `</script` refermerait le bloc en plein milieu."""

    def test_une_sequence_fermant_le_script_est_neutralisee(self):
        carto = {"apis": [{"id": "a1", "name": "</script><script>alert(1)</script>"}]}
        html = page.assembler(gabarit(), carto, [])
        self.assertNotIn("</script><script>alert", html)
        # Un seul bloc data, un seul bloc history : la sequence n'en a pas
        # cree un troisieme en coupant le premier en deux.
        self.assertEqual(html.count("<script"), 2)

    def test_la_donnee_echappee_se_relit_identique_a_l_originale(self):
        # L'echappement doit etre un aller-retour parfait : ce n'est pas
        # seulement "ne casse pas le HTML", c'est aussi "ne perd rien".
        carto = {"nom": "</script><img src=x onerror=alert(1)>", "note": "<!--x-->"}
        html = page.assembler(gabarit(), carto, [])
        debut = html.index('id="carto-data">') + len('id="carto-data">')
        fin = html.index("</script>", debut)
        self.assertEqual(json.loads(html[debut:fin]), carto)

    def test_une_sequence_ouvrant_un_commentaire_html_est_aussi_neutralisee(self):
        # <!-- a l'interieur d'un <script> fait basculer le parseur HTML dans
        # un etat special (donnees de script echappees) : la meme parade
        # (echapper CHAQUE '<') la neutralise egalement.
        carto = {"nom": "<!-- puis </script> plus loin"}
        html = page.assembler(gabarit(), carto, [])
        debut = html.index('id="carto-data">') + len('id="carto-data">')
        fin = html.index("</script>", debut)
        self.assertEqual(json.loads(html[debut:fin]), carto)
        self.assertNotIn("<!--", html[debut:fin])

    def test_aucun_caractere_inferieur_ne_subsiste_en_clair_dans_le_json_injecte(self):
        # Assertion la plus large et la plus robuste aux evolutions du texte :
        # peu importe la sequence exacte, '<' est TOUJOURS echappe.
        carto = {"x": "a<b<c<<<d", "liste": ["<", "<<", "<!--", "</script>"]}
        html = page.assembler(gabarit(), carto, [])
        debut = html.index('id="carto-data">') + len('id="carto-data">')
        fin = html.index("</script>", debut)
        bloc = html[debut:fin]
        self.assertNotIn("<", bloc)
        self.assertEqual(json.loads(bloc), carto)


if __name__ == "__main__":
    unittest.main()
