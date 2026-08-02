#!/usr/bin/env python3
"""Banc d'essai de lint-contrat-proxy.py — rejoue les experiences manuelles.

Le linter d'allow-list (lint-contrat-proxy.py) a deja laisse passer TROIS
faux negatifs. Chacun a ete trouve par une experience manuelle (muter un
fichier du depot, relancer, regarder, restaurer a la main) que personne
n'avait enregistree. Ce banc les rejoue toutes, pour de bon, a chaque run.

Regle cardinale : ce banc ne mute JAMAIS un fichier suivi par git. Chaque cas
construit une COPIE JETABLE du contrat et de l'arbre de roles dans un
repertoire temporaire (hors du depot), y applique sa mutation, puis lance le
linter REEL (le script du depot, jamais copie) avec STOA_LINT_CONTRAT et
STOA_LINT_ROLES pointant sur la copie. `git status --porcelain` doit rester
vide pendant et apres une execution de ce banc.

Sans argument : lance tous les cas. Code de sortie 0 si tous passent, 1
sinon — avec le nom de chaque cas en echec imprime.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap

import yaml

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE_REPO = os.path.dirname(ICI)  # poc-control-plane-federation/
LINTER = os.path.join(ICI, "lint-contrat-proxy.py")
CONTRAT_REEL = os.path.join(
    RACINE_REPO, "gateways/webmethods/admin-proxy/wm-admin-proxy.openapi.yaml")
ROLES_REEL = os.path.join(RACINE_REPO, "ansible/roles")

# Role dont on connait le contenu (utilise par plusieurs cas) : le fichier de
# la derogation elle-meme, et un fichier "innocent" du meme role pour poser
# un appel hors motif.
ROLE_DEROGATION = "apim_selfservice_app/tasks/rotate-strategy.yml"
ROLE_INNOCENT = "apim_selfservice_app/tasks/backend.yml"


class Fixture:
    """Copie jetable du contrat + de l'arbre de roles, dans un repertoire
    temporaire hors du depot. Le depot suivi par git n'est jamais ouvert en
    ecriture par cette classe."""

    def __init__(self):
        self.tmp = tempfile.mkdtemp(prefix="lint-contrat-proxy-bench-")
        self.contrat = os.path.join(self.tmp, "wm-admin-proxy.openapi.yaml")
        self.roles = os.path.join(self.tmp, "roles")
        shutil.copyfile(CONTRAT_REEL, self.contrat)
        shutil.copytree(ROLES_REEL, self.roles)

    def charger_contrat(self):
        with open(self.contrat, encoding="utf-8") as f:
            return yaml.safe_load(f)

    def ecrire_contrat(self, doc):
        with open(self.contrat, "w", encoding="utf-8") as f:
            yaml.safe_dump(doc, f, allow_unicode=True, sort_keys=False)

    def chemin_role(self, relatif):
        return os.path.join(self.roles, relatif)

    def charger_role(self, relatif):
        with open(self.chemin_role(relatif), encoding="utf-8") as f:
            return yaml.safe_load(f)

    def ecrire_role(self, relatif, doc):
        with open(self.chemin_role(relatif), "w", encoding="utf-8") as f:
            yaml.safe_dump(doc, f, allow_unicode=True, sort_keys=False)

    def executer(self, contrat=None, roles=None):
        """Lance le linter REEL du depot (jamais une copie) avec les deux
        variables d'environnement pointant sur cette copie jetable."""
        env = dict(os.environ)
        env["STOA_LINT_CONTRAT"] = contrat if contrat is not None else self.contrat
        env["STOA_LINT_ROLES"] = roles if roles is not None else self.roles
        r = subprocess.run([sys.executable, LINTER], env=env,
                            capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr

    def nettoyer(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


def executer_mode_defaut():
    """Lance le linter SANS surcharge : lecture seule du depot reel tel
    quel — c'est le verdict de reference du mode par defaut."""
    env = dict(os.environ)
    env.pop("STOA_LINT_CONTRAT", None)
    env.pop("STOA_LINT_ROLES", None)
    r = subprocess.run([sys.executable, LINTER], env=env,
                        capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


CAS = []


def cas(nom):
    def deco(fn):
        CAS.append((nom, fn))
        return fn
    return deco


@cas("1 — aucune mutation (controle) : code 0, derogation imprimee")
def cas_1():
    fx = Fixture()
    try:
        code, out = fx.executer()
        assert code == 0, f"code {code}, attendu 0\n{out}"
        assert "derogation(s) assumee" in out, f"derogation absente de la sortie\n{out}"
        assert "✓" in out, f"bilan de succes absent\n{out}"
    finally:
        fx.nettoyer()


@cas("2 — surcharge pointant le meme depot : verdict identique au mode defaut")
def cas_2():
    fx = Fixture()
    try:
        code_over, out_over = fx.executer()
        code_def, out_def = executer_mode_defaut()
        assert code_over == code_def, (
            f"code different entre surcharge ({code_over}) et defaut ({code_def})\n"
            f"--- surcharge ---\n{out_over}\n--- defaut ---\n{out_def}")
        assert out_over == out_def, (
            "sortie differente entre mode surcharge (copie jetable) et mode "
            f"defaut (depot reel)\n--- surcharge ---\n{out_over}\n--- defaut ---\n{out_def}")
    finally:
        fx.nettoyer()


@cas("3 — PUT policyActions/{id} retire du contrat : code 1, l'appel signale")
def cas_3():
    fx = Fixture()
    try:
        doc = fx.charger_contrat()
        del doc["paths"]["/rest/apigateway/policyActions/{id}"]["put"]
        fx.ecrire_contrat(doc)
        code, out = fx.executer()
        assert code == 1, f"code {code}, attendu 1\n{out}"
        assert "NON DECLARE" in out, f"section des appels manquants absente\n{out}"
        assert "policyActions" in out, f"l'appel policyActions n'est pas signale\n{out}"
    finally:
        fx.nettoyer()


@cas("4 — PUT strategies/{id} retire (chemin de la derogation) : "
     "code 1, la derogation ne couvre pas PUT")
def cas_4():
    fx = Fixture()
    try:
        doc = fx.charger_contrat()
        del doc["paths"]["/rest/apigateway/strategies/{id}"]["put"]
        fx.ecrire_contrat(doc)
        code, out = fx.executer()
        assert code == 1, f"code {code}, attendu 1\n{out}"
        assert "NON DECLARE" in out, f"section des appels manquants absente\n{out}"
        assert "strategies/{id}" in out and "consumer-auth.yml" in out, (
            f"l'appel PUT strategies/{{id}} (consumer-auth.yml) n'est pas signale\n{out}")
        # La derogation DELETE porte sur le MEME chemin mais un AUTRE verbe :
        # elle doit rester intacte, preuve qu'une derogation ne couvre que
        # son couple exact (methode, chemin, fichier), pas tout le chemin.
        assert "derogation(s) assumee" in out, (
            f"la derogation DELETE a disparu a tort alors que seul PUT a ete retire\n{out}")
    finally:
        fx.nettoyer()


@cas("5 — delete: ajoute sur un chemin quelconque du contrat : code 1")
def cas_5():
    fx = Fixture()
    try:
        doc = fx.charger_contrat()
        doc["paths"]["/rest/apigateway/health"]["delete"] = {
            "summary": "mutation banc — DELETE non autorise",
            "responses": {"200": {"$ref": "#/components/responses/proxied"}},
        }
        fx.ecrire_contrat(doc)
        code, out = fx.executer()
        assert code == 1, f"code {code}, attendu 1\n{out}"
        assert "DELETE DECLARE" in out, (
            f"le garde contrat ⊆ politique ne s'est pas declenche\n{out}")
        assert "/rest/apigateway/health" in out, f"le chemin fautif n'est pas signale\n{out}"
    finally:
        fx.nettoyer()


@cas("6 — DELETE strategies/{id} pose dans un role autre que celui du motif : code 1")
def cas_6():
    fx = Fixture()
    try:
        taches = fx.charger_role(ROLE_INNOCENT)
        taches.append({
            "name": "Mutation banc : DELETE hors motif",
            "ansible.builtin.uri": {
                "url": "{{ apim_ss_api_base }}/strategies/{{ mutation_id }}",
                "method": "DELETE",
            },
        })
        fx.ecrire_role(ROLE_INNOCENT, taches)
        code, out = fx.executer()
        assert code == 1, f"code {code}, attendu 1\n{out}"
        assert "NON DECLARE" in out, f"section des appels manquants absente\n{out}"
        assert ROLE_INNOCENT in out and "strategies/{id}" in out, (
            f"le DELETE hors motif (posé dans {ROLE_INNOCENT}) n'est pas signale\n{out}")
    finally:
        fx.nettoyer()


@cas("7 — fichier YAML de role non parsable : code 1, fichier nomme")
def cas_7():
    fx = Fixture()
    try:
        with open(fx.chemin_role(ROLE_INNOCENT), "a", encoding="utf-8") as f:
            f.write("\n- this: [is, not, valid: yaml\n")
        code, out = fx.executer()
        assert code == 1, f"code {code}, attendu 1\n{out}"
        assert "YAML non parsable" in out, f"le garde YAML ne s'est pas declenche\n{out}"
        assert ROLE_INNOCENT in out, f"le fichier fautif n'est pas nomme\n{out}"
    finally:
        fx.nettoyer()


@cas("8 — ROLES sur un repertoire absent : code 2")
def cas_8():
    fx = Fixture()
    try:
        absent = os.path.join(fx.tmp, "roles-inexistant")
        code, out = fx.executer(roles=absent)
        assert code == 2, f"code {code}, attendu 2\n{out}"
        assert "INTROUVABLE" in out, f"le garde inventaire absent ne s'est pas declenche\n{out}"
    finally:
        fx.nettoyer()


@cas("9 — ROLES sur un arbre ampute a 19 fichiers : code 2")
def cas_9():
    fx = Fixture()
    try:
        fichiers = []
        for dossier, _, noms in os.walk(fx.roles):
            for n in noms:
                if n.endswith((".yml", ".yaml")):
                    fichiers.append(os.path.join(dossier, n))
        fichiers.sort()
        assert len(fichiers) >= 20, (
            f"le depot reel n'a plus que {len(fichiers)} fichier(s) de roles : "
            "le plancher MIN_FICHIERS_ROLES=20 du linter doit etre revu avant "
            "que ce cas ait un sens")
        for p in fichiers[19:]:
            os.remove(p)
        code, out = fx.executer()
        assert code == 2, f"code {code}, attendu 2\n{out}"
        assert "plancher attendu" in out and "19" in out, (
            f"le garde inventaire ampute ne s'est pas declenche\n{out}")
    finally:
        fx.nettoyer()


def main():
    echecs = []
    for nom, fn in CAS:
        try:
            fn()
        except AssertionError as e:
            echecs.append(nom)
            print(f"✗ cas {nom}")
            print(textwrap.indent(str(e), "    "))
        except Exception as e:  # environnement casse : nommer le cas quand meme
            echecs.append(nom)
            print(f"✗ cas {nom} — EXCEPTION {type(e).__name__}: {e}")
        else:
            print(f"✓ cas {nom}")

    print()
    if echecs:
        print(f"✗ {len(echecs)}/{len(CAS)} cas en echec : {', '.join(echecs)}")
        return 1
    print(f"✓ {len(CAS)}/{len(CAS)} cas passent — le banc est vert")
    return 0


if __name__ == "__main__":
    sys.exit(main())
