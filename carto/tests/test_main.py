"""Bout en bout sur fixtures, et C1 : la fenetre longue n'est plus decorative.

Defaut corrige (revue de branche 2026-07-30) : `--days 30` produisait un
document portant `window.requestedDays: 30` alors que `calls.d90` couvrait
90 jours — le document mentait sur ce qu'il decrivait. L'option a ete
RETIREE : la fenetre longue est une constante assumee, la profondeur qui
compte est celle qu'on mesure (`window.coveredDays`).
"""
import contextlib
import io
import json
import pathlib
import tempfile
import unittest

from unittest import mock

import carto.collect.__main__ as main_mod
from carto.collect.__main__ import (WINDOWS, REQUESTED_DAYS, main,
                                    windows_par_duree_croissante)
from carto.collect.model import validate_carto, validate_history

FIX = str(pathlib.Path(__file__).parent / "fixtures")


def run(args):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = main(args)
    return code, out.getvalue()


class TestFenetreNonDecorative(unittest.TestCase):
    def test_l_option_days_n_existe_plus(self):
        # elle ne pilotait que l'etiquette : mieux vaut un refus franc qu'un
        # reglage qui ne regle rien.
        err = io.StringIO()
        with contextlib.redirect_stderr(err), tempfile.TemporaryDirectory() as d:
            with self.assertRaises(SystemExit) as ctx:
                main(["--out", d, "--dry-run", "--from-fixtures", FIX, "--days", "30"])
        self.assertEqual(ctx.exception.code, 2)
        self.assertIn("--days", err.getvalue())

    def test_la_fenetre_demandee_du_document_est_celle_des_agregations(self):
        with tempfile.TemporaryDirectory() as d:
            code, _ = run(["--out", d, "--from-fixtures", FIX])
            doc = json.loads((pathlib.Path(d) / "carto.json").read_text())
        self.assertEqual(code, 0)
        self.assertEqual(doc["window"]["requestedDays"], REQUESTED_DAYS)
        self.assertEqual(REQUESTED_DAYS, WINDOWS["d90"])

    def test_la_profondeur_affichee_reste_celle_qui_est_mesuree(self):
        # la fixture d'index vient d'etre alimentee : 0 jour couvert, et le
        # document le dit au lieu d'annoncer 90.
        with tempfile.TemporaryDirectory() as d:
            _, out = run(["--out", d, "--dry-run", "--from-fixtures", FIX])
        self.assertIn("fenetre_couverte=0j", out)


class TestOrdreDesFenetres(unittest.TestCase):
    """L'ordre des trois requetes est PORTEUR, il ne doit plus dependre de
    l'ordre d'insertion de `WINDOWS` : un tri du dictionnaire ferait lever
    `InconsistentWindows` sur une collecte saine (voir la docstring de
    `windows_par_duree_croissante`)."""

    def test_les_fenetres_partent_de_la_plus_courte_a_la_plus_longue(self):
        self.assertEqual([d for _, d in windows_par_duree_croissante()],
                         [7, 30, 90])

    def test_remanier_le_dictionnaire_ne_change_plus_l_ordre_des_requetes(self):
        # la mutation « anodine » qui cassait tout : reordonner WINDOWS.
        a_l_envers = {"d90": 90, "d30": 30, "d7": 7}
        with mock.patch.object(main_mod, "WINDOWS", a_l_envers):
            self.assertEqual([n for n, _ in windows_par_duree_croissante()],
                             ["d7", "d30", "d90"])


class TestBoutEnBout(unittest.TestCase):
    def test_la_chaine_produit_deux_fichiers_valides(self):
        with tempfile.TemporaryDirectory() as d:
            code, out = run(["--out", d, "--from-fixtures", FIX])
            carto = json.loads((pathlib.Path(d) / "carto.json").read_text())
            hist = json.loads((pathlib.Path(d) / "history.json").read_text())
        self.assertEqual(code, 0)
        self.assertEqual(validate_carto(carto), [])
        self.assertEqual(validate_history(hist), [])
        self.assertIn("publie dans", out)

    def test_le_dry_run_ne_publie_rien(self):
        with tempfile.TemporaryDirectory() as d:
            code, out = run(["--out", d, "--dry-run", "--from-fixtures", FIX])
            self.assertEqual(list(pathlib.Path(d).iterdir()), [])
        self.assertEqual(code, 0)
        self.assertIn("dry-run", out)

    def test_les_compteurs_annoncent_la_part_de_trafic_non_identifie(self):
        # la ligne de compteurs est ce que lit la verification Ansible :
        # elle doit porter les trois signaux d'une collecte degradee.
        _, out = run(["--out", tempfile.mkdtemp(), "--dry-run", "--from-fixtures", FIX])
        for champ in ("apis=", "aretes=", "fenetre_couverte=", "trafic_non_identifie="):
            self.assertIn(champ, out)


if __name__ == "__main__":
    unittest.main()
