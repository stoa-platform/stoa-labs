"""La conversion Markdown -> format de stockage Confluence.

DEUX FAMILLES DE TESTS, ET LA PREMIERE COMPTE PLUS QUE LA SECONDE.

La seconde est ordinaire : chaque construction Markdown, prise isolement, se
traduit-elle correctement. Elle attrape les regressions de detail.

La premiere est le garde-fou du fichier converti : on convertit LES QUATRE
PAGES REELLES, produites par `markdown.py` a partir du meme document de test
que `test_markdown.py`, et on verifie qu'AUCUNE syntaxe Markdown n'a survecu.

Pourquoi ce test-la porte la valeur : `confluence.py` ne traduit qu'un
sous-ensemble ferme, celui que `markdown.py` emet aujourd'hui. Le jour ou
quelqu'un ajoutera une liste numerotee, une image ou un tableau imbrique dans
les pages, la conversion ne saura pas la traduire — et Confluence affichera la
syntaxe en clair, sans erreur, sans alerte, sans build rouge. Une page qui
affiche `**gras**` au milieu d'un paragraphe est exactement le genre de defaut
que personne ne signale et que tout le monde voit.

C'est donc ici que ca doit casser, pas chez le lecteur.
"""

import re
import unittest
import xml.etree.ElementTree as ET

from carto.render import confluence as cf
from carto.render import markdown as md

from . import test_markdown as tm


# Le storage format emprunte deux espaces de noms que le document ne declare
# pas lui-meme (Confluence les fournit). On les declare pour pouvoir parser.
_ENVELOPPE = '<root xmlns:ac="urn:test:ac" xmlns:ri="urn:test:ri">%s</root>'


def pages_reelles(prefixe=cf.PREFIXE_PAR_DEFAUT):
    """Les quatre pages du produit, converties. La vraie matiere."""
    return cf.rendre_pages(md.render_pages(tm.carto(), tm.HISTORY), prefixe)


class TestPagesReelles(unittest.TestCase):
    """Le garde-fou. Voir l'en-tete du fichier."""

    def test_les_quatre_pages_sont_du_xhtml_bien_forme(self):
        # Confluence refuse un corps mal forme par un 400 dont le message ne
        # designe pas la ligne fautive. Le detecter ici coute une ligne.
        for titre, storage in pages_reelles().items():
            with self.subTest(page=titre):
                try:
                    ET.fromstring(_ENVELOPPE % storage)
                except ET.ParseError as e:
                    self.fail("page « %s » mal formee : %s" % (titre, e))

    def test_aucune_syntaxe_markdown_ne_survit_a_la_conversion(self):
        """LE test du fichier. Une construction non traduite s'affiche en clair.

        Les accents graves sont cherches hors des elements `<code>` : un code
        en ligne PEUT legitimement contenir des accents graves — `evolution.md`
        affiche ``` ```mermaid ``` — et les compter serait un faux positif.
        """
        motifs = [
            (r"\*", "asterisque (gras ou italique non traduit)"),
            (r"\[[^\]]+\]\(", "lien non traduit"),
            (r"^#{1,6} ", "titre non traduit"),
            (r"^\|", "tableau non traduit"),
            (r"^- ", "liste non traduite"),
            (r"^&gt;", "citation non traduite"),
        ]
        for titre, storage in pages_reelles().items():
            hors_code = re.sub(r"<code>.*?</code>", "", storage, flags=re.S)
            hors_code = re.sub(r"<!\[CDATA\[.*?\]\]>", "", hors_code, flags=re.S)
            for motif, quoi in motifs + [(r"`", "accent grave hors code")]:
                with self.subTest(page=titre, syntaxe=quoi):
                    trouve = re.search(motif, hors_code, re.M)
                    self.assertIsNone(
                        trouve,
                        "%s dans « %s » — la conversion a laisse du Markdown "
                        "en clair, autour de : %r"
                        % (quoi, titre, hors_code[max(0, (trouve.start() if trouve else 0) - 60):
                                                 (trouve.end() if trouve else 0) + 60]))

    def test_la_conversion_est_deterministe(self):
        # Meme exigence que le rendu Markdown, et pour la meme raison : une
        # sortie qui bouge sans cause ferait une version Confluence par nuit,
        # dont le diff serait vide.
        self.assertEqual(pages_reelles(), pages_reelles())

    def test_les_quatre_pages_sont_produites(self):
        self.assertEqual(len(pages_reelles()), 4)


class TestTitres(unittest.TestCase):
    """Le titre est la CLE d'idempotence : la page est retrouvee par lui."""

    def test_les_titres_sont_uniques_dans_l_espace(self):
        # Contrainte Confluence. Deux pages de meme titre, c'est soit un refus,
        # soit — pire — une publication qui ecrase la page d'autrui.
        titres = list(cf.titres().values())
        self.assertEqual(len(titres), len(set(titres)))

    def test_le_prefixe_porte_sur_les_quatre_titres(self):
        for titre in cf.titres("ZZZ").values():
            self.assertTrue(titre.startswith("ZZZ"), titre)

    def test_un_prefixe_different_reecrit_aussi_les_liens_internes(self):
        """L'invariant qui rend le prefixe utilisable, et non decoratif.

        Deux cartos dans un meme espace (`Carto API` et `Carto API (REC)`) ne
        cohabitent que si les liens de CHACUNE pointent vers SES pages. Un
        prefixe qui ne changerait que les titres produirait deux jeux de pages
        dont tous les liens ramenent au premier — le genre de defaut qu'on ne
        voit qu'en cliquant.
        """
        storage = pages_reelles("ZZZ")["ZZZ"]
        self.assertIn('ri:content-title="ZZZ — Consommateurs"', storage)
        self.assertNotIn(cf.PREFIXE_PAR_DEFAUT, storage)

    def test_le_titre_h1_est_retire_du_corps(self):
        # Confluence affiche deja le titre au-dessus du corps.
        for storage in pages_reelles().values():
            self.assertNotIn("<h1>", storage)

    def test_la_racine_porte_le_prefixe_nu(self):
        self.assertEqual(cf.titres("ZZZ")[cf.RACINE], "ZZZ")


class TestFichiersDonnees(unittest.TestCase):

    def test_la_liste_est_la_meme_que_celle_du_rendu_markdown(self):
        """`confluence.FICHIERS_DONNEES` est une COPIE assumee de celle du
        rendu Markdown (voir le commentaire qui l'accompagne). Ce test est le
        prix de cette copie : si l'une bouge, l'autre doit bouger."""
        self.assertEqual(cf.FICHIERS_DONNEES, md.FICHIERS_DONNEES)


class TestConversion(unittest.TestCase):
    """Chaque construction, isolee."""

    def conv(self, markdown, prefixe=cf.PREFIXE_PAR_DEFAUT):
        return cf.convertir(markdown, cf.titres(prefixe))

    # --- en ligne ---------------------------------------------------------

    def test_gras(self):
        self.assertEqual(self.conv("un **mot** gras"),
                         "<p>un <strong>mot</strong> gras</p>")

    def test_italique_en_ligne(self):
        self.assertEqual(self.conv("existant *aujourd'hui*, donc"),
                         "<p>existant <em>aujourd'hui</em>, donc</p>")

    def test_une_ligne_entierement_en_gras_n_est_pas_de_l_italique(self):
        """Le garde `startswith('**')` du rendu de bloc.

        Sans lui, `**Cette date...**` — la phrase la plus importante du bandeau
        de fraicheur — satisferait aussi le motif de l'italique de ligne
        entiere et s'afficherait en maigre penche au lieu de gras.
        """
        self.assertEqual(self.conv("**tout en gras**"),
                         "<p><strong>tout en gras</strong></p>")

    def test_italique_de_ligne_entiere(self):
        self.assertEqual(self.conv("*sous-titre explicatif.*"),
                         "<p><em>sous-titre explicatif.</em></p>")

    def test_code_en_ligne(self):
        self.assertEqual(self.conv("le fichier `carto.json` porte"),
                         "<p>le fichier <code>carto.json</code> porte</p>")

    def test_un_code_a_un_accent_peut_contenir_trois_accents(self):
        """Le cas mesure d'`evolution.md`, et la regle CommonMark qui va avec.

        Un motif naif fermerait le code sur le premier accent grave venu, et
        laisserait ``` ``mermaid ` ``` en clair au milieu de la page.
        """
        self.assertEqual(self.conv("un bloc ` ```mermaid ` non rendu"),
                         "<p>un bloc <code>```mermaid</code> non rendu</p>")

    def test_le_contenu_d_un_code_n_est_pas_remis_en_forme(self):
        self.assertEqual(self.conv("`**pas du gras**`"),
                         "<p><code>**pas du gras**</code></p>")

    def test_echappement_des_caracteres_qui_cassent_le_xhtml(self):
        self.assertEqual(self.conv("a & b < c > d"),
                         "<p>a &amp; b &lt; c &gt; d</p>")

    def test_les_accents_et_l_espace_insecable_ne_sont_pas_echappes(self):
        # Les transformer en entites rendrait la sortie illisible sans rien
        # apporter : le storage format est de l'UTF-8.
        self.assertEqual(self.conv("Évolution %"), "<p>Évolution %</p>")

    # --- liens ------------------------------------------------------------

    def test_un_lien_vers_une_autre_page_devient_un_lien_de_page(self):
        # `<a href="apis.md">` serait un lien mort : Confluence designe une
        # page par son TITRE.
        self.assertEqual(
            self.conv("voir [apis.md](apis.md)"),
            '<p>voir <ac:link><ri:page ri:content-title="Carto API — Qui '
            'consomme quoi" /><ac:link-body>apis.md</ac:link-body></ac:link></p>')

    def test_un_lien_vers_un_fichier_de_donnees_devient_un_lien_de_piece_jointe(self):
        # Avec la page porteuse DESIGNEE : les fichiers ne sont attaches qu'a
        # la racine, un lien nu depuis une page fille serait mort.
        storage = self.conv("voir [`carto.json`](carto.json)")
        self.assertIn('<ri:attachment ri:filename="carto.json">', storage)
        self.assertIn('<ri:page ri:content-title="Carto API" /></ri:attachment>',
                      storage)
        self.assertIn("<code>carto.json</code>", storage)

    def test_un_lien_externe_reste_un_lien_html(self):
        self.assertEqual(self.conv("voir [le site](https://exemple.invalid/a)"),
                         '<p>voir <a href="https://exemple.invalid/a">le site</a></p>')

    def test_le_libelle_d_un_lien_garde_sa_mise_en_forme(self):
        # `[**apis.md**](apis.md)` et ``[`carto.json`](carto.json)`` : c'est ce
        # qui impose de traiter les liens AVANT le code en ligne.
        self.assertIn("<strong>apis.md</strong>",
                      self.conv("[**apis.md**](apis.md)"))

    # --- blocs ------------------------------------------------------------

    def test_titres(self):
        self.assertEqual(self.conv("## Compteurs"), "<h2>Compteurs</h2>")
        self.assertEqual(self.conv("### Signaux"), "<h3>Signaux</h3>")

    def test_liste_a_puces(self):
        self.assertEqual(self.conv("- un\n- deux"),
                         "<ul><li>un</li><li>deux</li></ul>")

    def test_bloc_de_code_cloture(self):
        self.assertEqual(
            self.conv("```\na@b.invalid; c@d.invalid\n```"),
            '<ac:structured-macro ac:name="code" ac:schema-version="1">'
            '<ac:plain-text-body><![CDATA[a@b.invalid; c@d.invalid]]>'
            '</ac:plain-text-body></ac:structured-macro>')

    def test_une_citation_devient_une_macro_info(self):
        """Le bandeau de fraicheur ne doit PAS etre discret.

        Une `<blockquote>` se rend chez Confluence en un mince filet gris. Le
        bandeau porte la seule phrase qui distingue une page vivante d'une page
        perimee : le rendre invisible annulerait la protection.
        """
        storage = self.conv("> ### Titre\n> - un point")
        self.assertIn('<ac:structured-macro ac:name="info"', storage)
        self.assertIn("<h3>Titre</h3>", storage)
        self.assertIn("<ul><li>un point</li></ul>", storage)

    def test_le_bandeau_de_fraicheur_reel_est_une_macro_info(self):
        for titre, storage in pages_reelles().items():
            with self.subTest(page=titre):
                self.assertTrue(
                    storage.startswith('<ac:structured-macro ac:name="info"'),
                    "la page « %s » ne commence pas par le bandeau" % titre)

    def test_tableau_avec_entete_et_corps(self):
        self.assertEqual(
            self.conv("| A | B |\n|---|---|\n| 1 | 2 |"),
            "<table><tbody><tr><th>A</th><th>B</th></tr>"
            "<tr><td>1</td><td>2</td></tr></tbody></table>")

    def test_l_alignement_a_droite_des_nombres_est_conserve(self):
        """Pas cosmetique : c'est ce qui rend une colonne de volumes
        comparable d'une ligne a l'autre. `markdown.py` aligne a droite toutes
        les colonnes de nombres."""
        storage = self.conv("| Mesure | Valeur |\n|---|---:|\n| APIs | 2 |")
        self.assertIn('<th style="text-align: right;">Valeur</th>', storage)
        self.assertIn('<td style="text-align: right;">2</td>', storage)
        self.assertIn("<th>Mesure</th>", storage)

    def test_les_cellules_sont_mises_en_forme(self):
        storage = self.conv("| A |\n|---|\n| `code` |")
        self.assertIn("<td><code>code</code></td>", storage)

    def test_les_lignes_vides_ne_produisent_rien(self):
        self.assertEqual(self.conv("\n\nun\n\n\ndeux\n\n"), "<p>un</p><p>deux</p>")


if __name__ == "__main__":
    unittest.main()
