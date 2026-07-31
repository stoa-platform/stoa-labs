"""Test de non-régression : `--source` relatif au job Jenkins, pas au script.

Défaut réel constaté au build Jenkins #8 (2026-07-30) : le script clone le
dépôt de publication dans un répertoire temporaire puis y `cd`. Si `--source`
avait été reçu relatif (le job Jenkins passe `--source carto-pages`, relatif
à SON propre espace de travail), il cessait de désigner quoi que ce soit
après ce changement de répertoire. Le script échouait alors sur « fichier
attendu absent de la source », un message trompeur qui oriente vers « le
rendu n'a pas tourné » alors que le rendu avait parfaitement tourné — seul
le chemin ne suivait plus le script dans son propre répertoire de travail.

Ce test rejoue exactement cette forme d'appel : un `--source` relatif, un
répertoire courant différent du répertoire du script et du dépôt cloné, et
vérifie que la publication aboutit malgré tout.
"""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "publier-markdown.sh"

PAGES = ("README.md", "consommateurs.md", "apis.md", "evolution.md")
DONNEES = ("carto.json", "history.json", "index.html")


class TestSourceRelative(unittest.TestCase):
    """Le script doit fonctionner que `--source` soit absolu ou relatif."""

    @classmethod
    def setUpClass(cls):
        if not shutil.which("git"):
            raise unittest.SkipTest("git absent : test de publication sauté")
        if not shutil.which("bash"):
            raise unittest.SkipTest("bash absent : test de publication sauté")

    def _preparer_bac_a_sable(self, racine):
        """Un dépôt « dédié » nu (comme chez le client), et un répertoire
        source rendu, tous deux sous `racine`."""
        origine = racine / "origine.git"
        subprocess.run(["git", "init", "--quiet", "--bare", str(origine)],
                        check=True)

        espace_travail = racine / "espace-de-travail-jenkins"
        source = espace_travail / "carto-pages"
        source.mkdir(parents=True)
        for f in PAGES:
            (source / f).write_text(f"# {f}\ncontenu de démonstration\n",
                                     encoding="utf-8")
        (source / "carto.json").write_text('{"schemaVersion": 1}\n', encoding="utf-8")
        (source / "history.json").write_text("[]\n", encoding="utf-8")
        (source / "index.html").write_text("<html></html>\n", encoding="utf-8")
        return origine, espace_travail

    def _executer(self, cwd, home, repo_url, *args):
        env = {
            "PATH": __import__("os").environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(home),
            "CARTO_PAGES_REPO_URL": repo_url,
            "CARTO_PAGES_USER": "svc-carto",
            "CARTO_PAGES_TOKEN": "jeton-de-test-sans-valeur",
        }
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            cwd=str(cwd), env=env, capture_output=True, text=True, timeout=60,
        )

    def test_source_relative_depuis_un_autre_repertoire_courant_aboutit(self):
        with tempfile.TemporaryDirectory() as d:
            racine = pathlib.Path(d)
            origine, espace_travail = self._preparer_bac_a_sable(racine)
            home = racine / "home"
            home.mkdir()

            r = self._executer(
                espace_travail, home, f"file://{origine}",
                "--source", "carto-pages",  # RELATIF, comme le job Jenkins
            )

            self.assertEqual(
                r.returncode, 0,
                f"la publication a échoué avec un --source relatif :\n"
                f"stdout:\n{r.stdout}\nstderr:\n{r.stderr}",
            )
            self.assertIn("publié sur", r.stdout)

            # Le contenu est effectivement arrivé dans le dépôt dédié : on le
            # vérifie en le reclonant, pas en supposant que le code de retour
            # suffit.
            verif = racine / "verification"
            subprocess.run(
                ["git", "clone", "--quiet", str(origine), str(verif)],
                check=True, env={"HOME": str(home),
                                  "PATH": __import__("os").environ.get("PATH", "/usr/bin:/bin")},
            )
            for f in PAGES + DONNEES:
                self.assertTrue((verif / f).exists(), f"{f} absent du dépôt publié")

    def test_meme_scenario_avec_environ_os_environ_reste_isole(self):
        # Régression secondaire : l'environnement CARTO_PAGES_REPO_URL doit
        # être fourni par le job (jamais deviné) ; son absence doit échouer
        # AVANT toute tentative de clone, avec les trois variables nommées.
        with tempfile.TemporaryDirectory() as d:
            racine = pathlib.Path(d)
            _, espace_travail = self._preparer_bac_a_sable(racine)
            home = racine / "home"
            home.mkdir()

            env = {
                "PATH": __import__("os").environ.get("PATH", "/usr/bin:/bin"),
                "HOME": str(home),
            }
            r = subprocess.run(
                ["bash", str(SCRIPT), "--source", "carto-pages"],
                cwd=str(espace_travail), env=env, capture_output=True, text=True,
                timeout=60,
            )
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("CARTO_PAGES_REPO_URL", r.stderr)
            self.assertIn("CARTO_PAGES_USER", r.stderr)
            self.assertIn("CARTO_PAGES_TOKEN", r.stderr)


if __name__ == "__main__":
    unittest.main()
