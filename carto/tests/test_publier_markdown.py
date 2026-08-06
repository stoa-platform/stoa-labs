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


class BacASable(unittest.TestCase):
    """Socle commun : un dépôt dédié nu, un rendu à publier, un HOME isolé.

    Ne porte aucun test — seulement de quoi en écrire.
    """

    @classmethod
    def setUpClass(cls):
        if not shutil.which("git"):
            raise unittest.SkipTest("git absent : test de publication sauté")
        if not shutil.which("bash"):
            raise unittest.SkipTest("bash absent : test de publication sauté")

    def _preparer_bac_a_sable(self, racine, branche_par_defaut="main"):
        """Un dépôt « dédié » nu (comme chez le client), et un répertoire
        source rendu, tous deux sous `racine`.

        `branche_par_defaut` est réglée EXPLICITEMENT, jamais laissée au
        hasard : sans ça, un `git init --bare` prend la valeur de
        `init.defaultBranch` de la MACHINE qui exécute les tests (`master`
        quand elle n'est pas configurée). Le test devenait alors vert ou rouge
        selon le poste, ce qui est la pire forme de test — il a effectivement
        échoué en local le 2026-08-03 pour cette seule raison, en désignant un
        défaut de publication qui n'existait pas. Ici la branche par défaut du
        dépôt est une DONNÉE DU SCÉNARIO : `main` = la forge est d'accord avec
        `CARTO_PAGES_BRANCH`, `master` = elle ne l'est pas (cas couvert par
        `TestBrancheParDefautDivergente`).
        """
        origine = racine / "origine.git"
        subprocess.run(["git", "init", "--quiet", "--bare", str(origine)],
                        check=True)
        subprocess.run(["git", "-C", str(origine), "symbolic-ref", "HEAD",
                        f"refs/heads/{branche_par_defaut}"], check=True)

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

    def _semer_branche(self, racine, origine, home, branche):
        """Pose un vrai commit sur `branche` dans le dépôt nu — ce que fait une
        forge quand on ouvre un dépôt avec un README."""
        env = {"HOME": str(home),
               "PATH": __import__("os").environ.get("PATH", "/usr/bin:/bin"),
               "GIT_AUTHOR_NAME": "forge", "GIT_AUTHOR_EMAIL": "forge@localhost",
               "GIT_COMMITTER_NAME": "forge", "GIT_COMMITTER_EMAIL": "forge@localhost"}
        semis = racine / f"semis-{branche}"
        subprocess.run(["git", "init", "--quiet", str(semis)], check=True, env=env)
        (semis / "LISEZMOI.md").write_text("dépôt ouvert par la forge\n",
                                           encoding="utf-8")
        for cmd in (["git", "add", "LISEZMOI.md"],
                    ["git", "commit", "--quiet", "-m", "ouverture du dépôt"],
                    ["git", "push", "--quiet", str(origine), f"HEAD:{branche}"]):
            subprocess.run(cmd, cwd=str(semis), check=True, env=env)

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


class TestSourceRelative(BacASable):
    """Le script doit fonctionner que `--source` soit absolu ou relatif."""

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


class TestBrancheParDefautDivergente(BacASable):
    """« Publié, mais invisible » — le piège que le test précédent masquait.

    Le script pousse sur `CARTO_PAGES_BRANCH` (`main` par défaut). Si le dépôt
    dédié présente une AUTRE branche par défaut — dépôt nu créé à la main, ou
    forge réglée sur `master` —, la poussée réussit, le job affiche « publié
    sur main », et pourtant `git clone` du dépôt rend un répertoire VIDE : la
    forge montre un dépôt vide à qui vient lire la carto. Tout est vert, rien
    n'est lisible. C'est exactement le mode de défaillance que ce produit
    combat partout ailleurs, et le seul endroit où il restait possible.

    Ce que ce test exige : la publication aboutit quand même (les données sont
    bien sur la branche demandée — on ne casse pas un job pour un réglage de
    forge), MAIS le job le DIT, en nommant l'écart et les deux gestes qui le
    ferment. Un avertissement, pas un échec.
    """

    def _publier_et_verifier_les_donnees(self, racine, origine, espace_travail, home):
        """Publie, exige la réussite, et prouve que les données sont bien sur
        la branche demandée. Retourne la sortie complète du script."""
        r = self._executer(
            espace_travail, home, f"file://{origine}",
            "--source", "carto-pages",
        )
        self.assertEqual(
            r.returncode, 0,
            f"un réglage de branche par défaut ne doit pas casser la "
            f"publication :\nstdout:\n{r.stdout}\nstderr:\n{r.stderr}",
        )
        self.assertIn("publié sur", r.stdout)

        verif = racine / "verification"
        subprocess.run(
            ["git", "clone", "--quiet", "--branch", "main",
             str(origine), str(verif)],
            check=True, env={"HOME": str(home),
                              "PATH": __import__("os").environ.get("PATH", "/usr/bin:/bin")},
        )
        for f in PAGES + DONNEES:
            self.assertTrue((verif / f).exists(), f"{f} absent de la branche main")
        return r.stdout + r.stderr

    def test_depot_nu_sans_branche_par_defaut_utilisable_est_denonce(self):
        # Cas du dépôt dédié créé nu et jamais initialisé : sa HEAD désigne une
        # branche qui n'existe pas. `git ls-remote --symref` n'annonce alors
        # RIEN, et un clone rend un répertoire vide.
        with tempfile.TemporaryDirectory() as d:
            racine = pathlib.Path(d)
            origine, espace_travail = self._preparer_bac_a_sable(
                racine, branche_par_defaut="master")
            home = racine / "home"
            home.mkdir()

            sortie = self._publier_et_verifier_les_donnees(
                racine, origine, espace_travail, home)

            self.assertIn("AVERTISSEMENT", sortie)
            self.assertIn("vide", sortie,
                          "l'avertissement doit dire CE QUI SE PASSE : un clone vide")
            self.assertIn("symbolic-ref", sortie,
                          "il doit donner le geste exact sur un dépôt nu")

    def test_branche_par_defaut_existante_mais_differente_est_denoncee(self):
        # Cas de la forge : le dépôt dédié a un vrai `master` (créé avec un
        # README à l'ouverture), le job publie sur `main`. Le lecteur qui clone
        # tombe sur `master` et n'y voit aucune carto.
        with tempfile.TemporaryDirectory() as d:
            racine = pathlib.Path(d)
            origine, espace_travail = self._preparer_bac_a_sable(
                racine, branche_par_defaut="master")
            home = racine / "home"
            home.mkdir()
            self._semer_branche(racine, origine, home, "master")

            sortie = self._publier_et_verifier_les_donnees(
                racine, origine, espace_travail, home)

            self.assertIn("AVERTISSEMENT", sortie)
            self.assertIn("master", sortie,
                          "l'avertissement doit nommer la branche par défaut observée")
            self.assertIn("vide", sortie,
                          "l'avertissement doit dire CE QUI SE PASSE : un clone vide")
            self.assertIn("CARTO_PAGES_BRANCH", sortie,
                          "l'avertissement doit nommer le paramètre qui règle la branche")


if __name__ == "__main__":
    unittest.main()
