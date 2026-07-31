"""Tests du rendu : le JavaScript qui porte de la verite est execute, pas relu.

Pourquoi ce fichier existe : `carto/render/index.html` porte des fonctions qui
DECIDENT ce que l'exploitant croit — le bandeau qui doit crier quand la donnee
est mauvaise, le statut d'une arete, la regle « une semaine se resume par sa
DERNIERE valeur, jamais par une somme », la serie retro-calculee. Tant qu'elles
n'etaient testees par rien, chaque correction dessus se faisait a l'aveugle.

Methode : on extrait le contenu du `<script>` de la page, on le prefixe d'un
DOM minimal (la page n'est pas chargee dans un navigateur, seules les fonctions
pures et le bandeau sont exerces), on retire l'appel automatique `boot()` — qui
sera invoque EXPLICITEMENT par les tests qui en ont besoin — et on execute le
tout avec `node`, stdlib Python seule, aucune dependance JS. Si `node` est
absent, ces tests sont sautes : ils ne doivent jamais casser la suite Python
sur une machine qui n'a pas de JS.

La page ne fait plus aucun `fetch` : elle lit ses donnees dans deux blocs
`<script type="application/json">` embarques par `carto/render/page.py`
(`TestDonneesEmbarquees` ci-dessous couvre la lecture et sa defense — bloc
absent ou illisible).
"""
import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest

from carto.collect.model import SCHEMA_VERSION

RENDER = pathlib.Path(__file__).resolve().parents[1] / "render" / "index.html"

# DOM minimal : `banner()` ecrit dans un element, les `addEventListener` de
# haut niveau doivent exister, `Date` et `Intl` sont natifs a node.
#
# "banner", "nav" et "view" existent TOUJOURS dans le vrai document (ils sont
# dans le HTML statique) : ils sont donc pre-enregistres. "carto-data" et
# "carto-history", eux, n'existent que si le gabarit a ete RENDU par
# `carto/render/page.py` — un vrai `getElementById` renvoie `null` pour un id
# absent du document, donc ce stub fait pareil : seul un test qui appelle
# explicitement `__el_for(id)` fait "exister" ce bloc-la, avant d'y poser
# `textContent` et d'appeler `lireJSONEmbarque()` ou `boot()`.
PRELUDE = """
const __els = {
  banner: { id:"banner", className:"", innerHTML:"", textContent:"" },
  nav: { innerHTML:"" },
  view: { innerHTML:"" },
};
function __el_for(id) {
  if (!__els[id]) __els[id] = { id, className:"", innerHTML:"", textContent:"" };
  return __els[id];
}
const __el = __els.banner;
const document = {
  getElementById: (id) => __els[id] || null,
  addEventListener: () => {},
  createElement: () => ({ click(){} }),
};
const window = {};
"""


def _script():
    html = RENDER.read_text(encoding="utf-8")
    debut = html.index("<script>") + len("<script>")
    fin = html.index("</script>", debut)
    src = html[debut:fin]
    # `boot()` declenche un fetch : hors sujet ici, et impossible sans reseau.
    assert "\nboot();" in src, "l'amorce boot() a change de forme"
    return src.replace("\nboot();", "\n")


class RenderJsTestCase(unittest.TestCase):
    """Socle : execute un fragment de test dans la portee du script du rendu."""

    @classmethod
    def setUpClass(cls):
        if not shutil.which("node"):
            raise unittest.SkipTest("node absent : tests du rendu sautes")
        cls.src = _script()

    def js(self, fragment):
        """Execute `fragment` apres le script du rendu, retourne sa sortie."""
        with tempfile.NamedTemporaryFile("w", suffix=".mjs", delete=False,
                                         encoding="utf-8") as f:
            f.write(PRELUDE + self.src + "\n" + fragment + "\n")
            chemin = f.name
        try:
            r = subprocess.run(["node", chemin], capture_output=True, text=True,
                               timeout=60)
        finally:
            pathlib.Path(chemin).unlink(missing_ok=True)
        self.assertEqual(r.returncode, 0, f"node a echoue :\n{r.stderr}")
        return r.stdout

    def carto_js(self, **over):
        """Un document carto minimal mais VALIDE au sens du contrat."""
        doc = {
            "schemaVersion": SCHEMA_VERSION,
            "generatedAt": "2026-07-30T02:00:00Z",
            "window": {"requestedDays": 90, "coveredDays": 34,
                       "oldestEvent": "2026-06-26T00:00:00Z"},
            "unidentifiedCallShare": 0.0,
            "apis": [{"id": "a1", "name": "orders", "version": "1",
                      "owner": None, "active": True, "createdAt": None,
                      "ghost": False}],
            "consumers": [{"id": "c1", "name": "crm", "owner": None,
                           "contact": None, "createdAt": None, "ghost": False}],
            "edges": [{"apiId": "a1", "consumerId": "c1", "declared": True,
                       "calls": {"d7": 1, "d30": 2, "d90": 3},
                       "lastCall": "2026-07-29T00:00:00Z", "errorRate": 0.0}],
        }
        doc.update(over)
        return json.dumps(doc)


class TestBandeau(RenderJsTestCase):
    """Le bandeau existe pour crier quand la donnee est mauvaise : il ne doit
    jamais planter, jamais se taire, et jamais rester vert a tort."""

    def bandeau(self, carto_js, maintenant="2026-07-30T06:00:00Z"):
        return self.js(f"""
          S.carto = {carto_js};
          Date.now = () => Date.parse("{maintenant}");
          banner();
          console.log(JSON.stringify({{ cls: __el.className, html: __el.innerHTML }}));
        """)

    def test_une_carto_fraiche_ne_declenche_aucune_alerte(self):
        r = json.loads(self.bandeau(self.carto_js()))
        self.assertEqual(r["cls"], "")
        self.assertIn("34 jours", r["html"])

    def test_une_carto_perimee_passe_en_alerte(self):
        r = json.loads(self.bandeau(self.carto_js(), maintenant="2026-08-05T06:00:00Z"))
        self.assertEqual(r["cls"], "stale")
        self.assertIn("périmées", r["html"])

    def test_une_date_illisible_passe_en_alerte_au_lieu_de_planter(self):
        r = json.loads(self.bandeau(self.carto_js(generatedAt="pas une date")))
        self.assertEqual(r["cls"], "stale")
        self.assertIn("illisible", r["html"])

    def test_un_document_sans_fenetre_le_dit_au_lieu_de_se_taire(self):
        js = json.dumps(json.loads(self.carto_js()) | {"window": None})
        r = json.loads(self.bandeau(js))
        self.assertIn("profondeur inconnue", r["html"])

    def test_un_trafic_majoritairement_non_identifie_passe_en_alerte(self):
        # C2 : le pire mode de defaillance du produit. 87 % du trafic sur un
        # noeud fantome, et sans cette alerte le bandeau resterait vert.
        r = json.loads(self.bandeau(self.carto_js(unidentifiedCallShare=0.87)))
        self.assertEqual(r["cls"], "stale")
        self.assertIn("87.0 %", r["html"])
        self.assertIn("n'est PAS fiable", r["html"])

    def test_une_part_residuelle_est_dite_sans_crier_au_loup(self):
        # une alerte toujours allumee n'alerte plus : sous le seuil, on
        # informe, on n'alarme pas.
        r = json.loads(self.bandeau(self.carto_js(unidentifiedCallShare=0.02)))
        self.assertEqual(r["cls"], "")
        self.assertIn("2.0 %", r["html"])

    def test_le_seuil_d_alerte_est_bien_a_la_moitie_du_trafic(self):
        sous = json.loads(self.bandeau(self.carto_js(unidentifiedCallShare=0.5)))
        au_dessus = json.loads(self.bandeau(self.carto_js(unidentifiedCallShare=0.51)))
        self.assertEqual(sous["cls"], "")
        self.assertEqual(au_dessus["cls"], "stale")

    def test_un_document_sans_le_champ_dit_qu_il_ne_sait_pas(self):
        js = json.dumps({k: v for k, v in json.loads(self.carto_js()).items()
                         if k != "unidentifiedCallShare"})
        r = json.loads(self.bandeau(js))
        self.assertIn("inconnue", r["html"])


class TestVersionDeSchema(RenderJsTestCase):
    def test_la_page_lit_exactement_la_version_que_le_collecteur_produit(self):
        # Les deux constantes doivent bouger ENSEMBLE. Sans ce test, ajouter un
        # champ obligatoire cote Python et oublier index.html (ou l'inverse)
        # ne se voit qu'au deploiement.
        out = self.js("console.log(String(SCHEMA_VERSION));")
        self.assertEqual(int(out.strip()), SCHEMA_VERSION)

    def test_la_page_refuse_le_document_de_la_version_precedente(self):
        # LE scenario du premier deploiement : le role depose index.html et le
        # collecteur ensemble, mais le carto.json publie reste en version 1
        # jusqu'a la prochaine collecte planifiee. Sans refus, cette page
        # degraderait en silence — `ghost` et `unidentifiedCallShare` absents,
        # donc bloc des objets disparus vide, fantomes reintegres a l'annuaire
        # (`!c.ghost` vaut vrai sur `undefined`), part non identifiee en gris.
        self.assertEqual(SCHEMA_VERSION, 2, "ce test decrit la transition 1 -> 2")
        refuse = self.js("""
          console.log(JSON.stringify(versionSupportee({ schemaVersion: 1 })));
        """)
        self.assertEqual(json.loads(refuse), False)

        out = self.js("""
          const txt = refuserVersion({ schemaVersion: 1 });
          console.log(JSON.stringify({ cls: __el.className, txt }));
        """)
        r = json.loads(out)
        self.assertEqual(r["cls"], "stale")
        self.assertIn("version de schéma 1", r["txt"])
        self.assertIn(f"la version {SCHEMA_VERSION}", r["txt"])
        # Un refus qui ne dit pas quoi faire n'est qu'une panne de plus.
        self.assertIn("attendre la prochaine collecte", r["txt"])
        self.assertIn("relancer le collecteur", r["txt"])

    def test_un_document_plus_recent_appelle_le_geste_inverse(self):
        out = self.js("""
          console.log(refuserVersion({ schemaVersion: SCHEMA_VERSION + 1 }));
        """)
        self.assertIn("redéployer index.html", out)
        self.assertNotIn("attendre la prochaine collecte", out)

    def test_un_document_sans_version_lisible_ne_recoit_pas_un_geste_invente(self):
        # ni « plus ancien » ni « plus recent » : on ne sait pas, on le dit.
        out = self.js("console.log(refuserVersion({}));")
        self.assertIn("aucun numéro de version lisible", out)
        self.assertNotIn("attendre la prochaine collecte", out)
        self.assertNotIn("redéployer index.html", out)

    def test_la_page_refuse_une_version_qu_elle_ne_connait_pas(self):
        out = self.js("""
          console.log(JSON.stringify({
            connue: versionSupportee({ schemaVersion: SCHEMA_VERSION }),
            future: versionSupportee({ schemaVersion: SCHEMA_VERSION + 1 }),
            absente: versionSupportee({}),
            vide: versionSupportee(null),
          }));
        """)
        r = json.loads(out)
        self.assertTrue(r["connue"])
        self.assertFalse(r["future"])
        self.assertFalse(r["absente"])
        self.assertFalse(r["vide"])


class TestDonneesEmbarquees(RenderJsTestCase):
    """La page ne fait plus de `fetch` : les donnees vivent dans deux blocs
    `<script type="application/json">` embarques par `carto/render/page.py`.

    Ce que ce test garde : la lecture elle-meme (`lireJSONEmbarque`), ET la
    defense sur les deux facons dont un bloc peut ne pas etre utilisable —
    absent (fichier non produit par `carto.render`) ou illisible (JSON casse,
    fichier tronque) — chacune avec sa PROPRE suite, jamais un ecran muet."""

    def test_un_bloc_present_et_valide_est_lu(self):
        out = self.js(f"""
          __el_for("carto-data").textContent = JSON.stringify({self.carto_js()});
          const r = lireJSONEmbarque("carto-data");
          console.log(JSON.stringify({{ present: r.present, erreur: !!r.erreur,
                                        schemaVersion: r.valeur.schemaVersion }}));
        """)
        r = json.loads(out)
        self.assertTrue(r["present"])
        self.assertFalse(r["erreur"])
        self.assertEqual(r["schemaVersion"], SCHEMA_VERSION)

    def test_un_bloc_absent_est_signale_absent_pas_illisible(self):
        # Aucun `__el_for("carto-data")` n'a ete appele : c'est exactement un
        # fichier qui n'a pas ete produit par `carto.render` (aucun bloc de
        # donnees dans le document).
        out = self.js("""console.log(JSON.stringify(lireJSONEmbarque("carto-data")));""")
        r = json.loads(out)
        self.assertEqual(r, {"present": False})

    def test_un_bloc_present_mais_casse_est_signale_en_erreur(self):
        out = self.js("""
          __el_for("carto-data").textContent = "{ ceci n'est pas du JSON";
          console.log(JSON.stringify(lireJSONEmbarque("carto-data")));
        """)
        r = json.loads(out)
        self.assertEqual(r, {"present": True, "erreur": True})

    def test_boot_charge_les_donnees_embarquees_sans_toucher_au_reseau(self):
        # Pas de `fetch` dans ce harnais node : si boot() en appelait un ici,
        # il echouerait — ce test passe seulement si le chemin embarque est
        # bien pris en premier, sans jamais tenter le reseau.
        out = self.js(f"""
          __el_for("carto-data").textContent = JSON.stringify({self.carto_js()});
          __el_for("carto-history").textContent = "[]";
          await boot();
          console.log(JSON.stringify({{ cls: __el.className, apis: S.carto.apis.length,
                                        history: S.history.length }}));
        """)
        r = json.loads(out)
        self.assertEqual(r["cls"], "")
        self.assertEqual(r["apis"], 1)
        self.assertEqual(r["history"], 0)

    def test_boot_accepte_un_historique_absent_comme_liste_vide(self):
        # Cas normal du tout premier passage : aucun bloc "carto-history".
        out = self.js(f"""
          __el_for("carto-data").textContent = JSON.stringify({self.carto_js()});
          await boot();
          console.log(JSON.stringify({{ cls: __el.className, history: S.history }}));
        """)
        r = json.loads(out)
        self.assertEqual(r["cls"], "")
        self.assertEqual(r["history"], [])

    def test_boot_dit_clairement_quand_le_bloc_embarque_est_illisible(self):
        # Present mais casse : PAS de nouvelle tentative reseau, un message
        # dedie plutot qu'un ecran muet ou une erreur generique de fetch.
        out = self.js("""
          __el_for("carto-data").textContent = "{ json tronque";
          await boot();
          console.log(JSON.stringify({ cls: __el.className, texte: __el.textContent }));
        """)
        r = json.loads(out)
        self.assertEqual(r["cls"], "stale")
        self.assertIn("illisible", r["texte"])
        self.assertIn("JSON invalide", r["texte"])

    def test_boot_dit_clairement_quand_rien_n_est_embarque(self):
        # Aucun bloc du tout (fichier non produit par `carto.render`) : plus
        # aucun fetch de repli n'existe, la page ne doit jamais rester muette.
        out = self.js("""
          await boot();
          console.log(JSON.stringify({ cls: __el.className, texte: __el.textContent }));
        """)
        r = json.loads(out)
        self.assertEqual(r["cls"], "stale")
        self.assertIn("n'embarque aucune donnée", r["texte"])
        self.assertIn("carto.render", r["texte"])

    def test_le_script_de_la_page_ne_contient_plus_aucun_fetch(self):
        # Assertion la plus directe possible sur l'exigence : les deux fetch()
        # ont disparu du script, pas seulement du chemin heureux.
        self.assertNotIn("fetch(", self.src)


class TestStatut(RenderJsTestCase):
    """La matrice declare x observe, telle que l'exploitant la lit."""

    def statut(self, declared, d90):
        return self.js(f"""
          console.log(statut({{ declared: {str(declared).lower()},
                                calls: {{ d7:0, d30:0, d90: {d90} }} }}));
        """)

    def test_du_trafic_sans_declaration_est_un_ecart_de_gouvernance(self):
        self.assertIn("non déclaré", self.statut(False, 120))

    def test_un_declare_sans_trafic_est_inactif_pas_absent(self):
        self.assertIn("déclaré, inactif", self.statut(True, 0))

    def test_un_declare_avec_trafic_est_actif(self):
        self.assertIn("actif", self.statut(True, 7))


class TestEnTetesDeColonnes(RenderJsTestCase):
    """Une colonne « 90 j » qui ne contient que 34 jours de trafic ment."""

    def test_les_colonnes_sont_libellees_depuis_la_profondeur_couverte(self):
        out = self.js(f"""
          S.carto = {self.carto_js()};
          console.log(JSON.stringify([libFenetre(7), libFenetre(30), libFenetre(90)]));
        """)
        self.assertEqual(json.loads(out), ["7 j", "30 j", "34 j"])

    def test_une_couverture_tres_courte_rabote_toutes_les_colonnes(self):
        js = json.dumps(json.loads(self.carto_js()) |
                        {"window": {"requestedDays": 90, "coveredDays": 3,
                                    "oldestEvent": None}})
        out = self.js(f"""
          S.carto = {js};
          console.log(JSON.stringify([libFenetre(7), libFenetre(30), libFenetre(90)]));
        """)
        self.assertEqual(json.loads(out), ["3 j", "3 j", "3 j"])

    def test_sans_profondeur_connue_on_retombe_sur_le_libelle_nominal(self):
        js = json.dumps(json.loads(self.carto_js()) | {"window": {}})
        out = self.js(f"S.carto = {js}; console.log(libFenetre(90));")
        self.assertEqual(out.strip(), "90 j")


class TestVueSignaux(RenderJsTestCase):
    def contexte(self, carto_js):
        return f"S.carto = {carto_js}; S.idx = index(S.carto);"

    def test_un_document_sans_fenetre_ne_fait_pas_echouer_la_vue(self):
        # sans garde, la vue echouait en silence et l'ecran restait sur la
        # vue precedente — l'exploitant croyait lire des signaux.
        js = json.dumps(json.loads(self.carto_js()) | {"window": None})
        out = self.js(self.contexte(js) + """
          const html = viewSignaux();
          console.log(html.includes("profondeur inconnue") ? "DIT" : "MUET");
        """)
        self.assertEqual(out.strip(), "DIT")

    def test_les_fantomes_sont_detectes_par_le_champ_pas_par_l_etiquette(self):
        # I5 : renommer l'etiquette ne doit pas vider le signal.
        #
        # L'assertion porte sur le BLOC « Objets disparus encore appelés », pas
        # sur la presence du nom quelque part dans la page. Version precedente
        # de ce test : elle cherchait le nom dans tout le HTML, et le meme nom
        # apparaissait aussi dans « Trafic sans autorisation déclarée » (l'arete
        # `declared: false` ci-dessous). Le test passait donc grace a l'autre
        # bloc, et remettre la detection par etiquette de nom laissait toute la
        # suite au vert. Un test qui passe pour la mauvaise raison ne garde
        # rien : c'est le compteur du bloc concerne qui est verifie.
        doc = json.loads(self.carto_js())
        doc["consumers"].append({"id": "Unknown", "name": "appelant sans nom",
                                 "owner": None, "contact": None,
                                 "createdAt": None, "ghost": True})
        doc["edges"].append({"apiId": "a1", "consumerId": "Unknown",
                             "declared": False,
                             "calls": {"d7": 5, "d30": 5, "d90": 5},
                             "lastCall": None, "errorRate": 0.0})
        out = self.js(self.contexte(json.dumps(doc)) + """
          const html = viewSignaux();
          const debut = html.indexOf("Objets disparus encore appelés");
          const suite = html.indexOf("<h3", debut + 1);
          const bloc = debut < 0 ? "" : html.slice(debut, suite < 0 ? html.length : suite);
          console.log(JSON.stringify({ bloc }));
        """)
        bloc = json.loads(out)["bloc"]
        self.assertIn("(1)", bloc, f"bloc des objets disparus vide :\n{bloc}")
        self.assertIn("appelant sans nom", bloc)

    def test_l_annuaire_ne_presente_pas_un_inconnu_comme_enregistre(self):
        doc = json.loads(self.carto_js())
        doc["consumers"].append({"id": "Unknown", "name": "appelant sans nom",
                                 "owner": None, "contact": None,
                                 "createdAt": None, "ghost": True})
        out = self.js(self.contexte(json.dumps(doc)) + """
          const html = viewAnnuaire();
          console.log(JSON.stringify({
            liste: html.includes("appelant sans nom"),
            avertit: html.includes("non identifié"),
          }));
        """)
        r = json.loads(out)
        self.assertFalse(r["liste"])
        self.assertTrue(r["avertit"])


class TestEvolutionHebdomadaire(RenderJsTestCase):
    """Toutes les grandeurs du journal sont des STOCKS mesures a une date :
    une semaine se resume par sa DERNIERE valeur, jamais par une somme."""

    def test_deux_jours_de_la_meme_semaine_iso_partagent_une_cle(self):
        out = self.js("""
          console.log(JSON.stringify({
            lundi: weekKey("2026-07-27"),
            dimanche: weekKey("2026-08-02"),
            lundiSuivant: weekKey("2026-08-03"),
          }));
        """)
        r = json.loads(out)
        self.assertEqual(r["lundi"], r["dimanche"])
        self.assertNotEqual(r["lundi"], r["lundiSuivant"])

    def test_une_semaine_se_resume_par_sa_derniere_valeur_jamais_par_une_somme(self):
        out = self.js("""
          const rows = [
            { date:"2026-07-27", apis:10, consumersRegistered:5, consumersActive:2, calls:5 },
            { date:"2026-07-29", apis:11, consumersRegistered:6, consumersActive:3, calls:7 },
            { date:"2026-07-31", apis:12, consumersRegistered:7, consumersActive:4, calls:9 },
          ];
          const w = weekly(rows);
          console.log(JSON.stringify({ points: w.length, calls: w[0].calls, apis: w[0].apis }));
        """)
        r = json.loads(out)
        self.assertEqual(r["points"], 1)
        self.assertEqual(r["calls"], 9)     # la derniere, pas 5+7+9 = 21
        self.assertEqual(r["apis"], 12)

    def test_l_ordre_d_arrivee_des_lignes_ne_change_pas_le_resume(self):
        out = self.js("""
          const rows = [
            { date:"2026-07-31", calls:9 }, { date:"2026-07-27", calls:5 },
            { date:"2026-07-29", calls:7 },
          ];
          console.log(String(weekly(rows)[0].calls));
        """)
        self.assertEqual(out.strip(), "9")

    def test_deux_semaines_donnent_deux_points_ordonnes(self):
        out = self.js("""
          const rows = [{ date:"2026-07-29", calls:1 }, { date:"2026-08-05", calls:2 }];
          console.log(JSON.stringify(weekly(rows).map(r => r.calls)));
        """)
        self.assertEqual(json.loads(out), [1, 2])


class TestSerieRetroCalculee(RenderJsTestCase):
    """Courbe de SURVIVANTS : cumulative, consommateurs seuls, jamais les APIs
    (la gateway ne les date pas — terrain V1)."""

    def test_la_serie_est_cumulative_par_semaine(self):
        doc = json.loads(self.carto_js())
        doc["consumers"] = [
            {"id": "c1", "name": "a", "owner": None, "contact": None,
             "createdAt": "2026-07-01T10:00:00Z", "ghost": False},
            {"id": "c2", "name": "b", "owner": None, "contact": None,
             "createdAt": "2026-07-02T10:00:00Z", "ghost": False},
            {"id": "c3", "name": "c", "owner": None, "contact": None,
             "createdAt": "2026-07-20T10:00:00Z", "ghost": False},
        ]
        doc["edges"] = []
        out = self.js(f"""
          S.carto = {json.dumps(doc)};
          console.log(JSON.stringify(retroSeries().map(r => r.consumersRegistered)));
        """)
        self.assertEqual(json.loads(out), [2, 3])

    def test_un_consommateur_sans_date_n_invente_pas_de_point(self):
        doc = json.loads(self.carto_js())
        doc["edges"] = []
        out = self.js(f"""
          S.carto = {json.dumps(doc)};
          console.log(JSON.stringify(retroSeries()));
        """)
        self.assertEqual(json.loads(out), [])


if __name__ == "__main__":
    unittest.main()
