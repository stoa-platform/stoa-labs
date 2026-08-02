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
import re
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


@cas("10 — delete: ajoute au contrat SOUS le chemin deja deroge : code 1, "
     "jamais « aucun DELETE »")
def cas_10():
    fx = Fixture()
    try:
        doc = fx.charger_contrat()
        doc["paths"]["/rest/apigateway/strategies/{id}"]["delete"] = {
            "summary": "mutation banc — DELETE non autorise, meme chemin que la derogation",
            "responses": {"200": {"$ref": "#/components/responses/proxied"}},
        }
        fx.ecrire_contrat(doc)
        code, out = fx.executer()
        assert code == 1, f"code {code}, attendu 1\n{out}"
        assert "DELETE DECLARE" in out, (
            f"le garde contrat ⊆ politique ne s'est pas declenche\n{out}")
        assert "strategies/{id}" in out, f"le chemin fautif n'est pas signale\n{out}"
        # La derogation couvre un APPEL de role qui contourne le proxy, jamais
        # une DECLARATION au contrat : les deux sens sont distincts, et le
        # bilan ne doit jamais affirmer « aucun DELETE » quand un DELETE est
        # declare au contrat.
        assert "aucun DELETE" not in out, (
            f"le bilan affirme a tort « aucun DELETE » alors qu'un DELETE est "
            f"declare au contrat sous le chemin deroge\n{out}")
    finally:
        fx.nettoyer()


# La tache UNIQUE telle qu'elle existait AVANT sa scission en deux taches a
# methode fixe (tache 3, lot 1 bis, commit bc2a3a4) — reconstruite ici depuis
# `git show 06594a5:.../backend.yml`, le dernier commit ou ce fichier la
# portait encore. Depuis la scission, plus aucun appel du depot ne correle
# methode et chemin sur le meme conditionnel Jinja (`grep -rn 'method:.*{{'
# ansible/roles` ne rend plus rien) : pour exercer la branche produit-croisé
# du linter, ce cas doit reintroduire cette forme dans la copie jetable du
# role, pas seulement museler le contrat.
_TACHE_CORRELEE_PRE_SCISSION = {
    "name": "Backend : converger l'action (PUT si déjà attachée, POST sinon)",
    "ansible.builtin.uri": {
        "url": "{{ apim_ss_api_base }}/policyActions{{ ('/' ~ bk_hdr_id) if "
               "(bk_hdr_id | length > 0) else '' }}",
        "method": "{{ 'PUT' if (bk_hdr_id | length > 0) else 'POST' }}",
        "body": "{{ {'policyAction': (bk_action.policyAction | "
                "combine({'id': bk_hdr_id}))} if (bk_hdr_id | length > 0) "
                "else bk_action }}",
        "status_code": [200, 201],
    },
    "register": "bk_hdr_put",
}
_FACT_CORRELEE_PRE_SCISSION = {
    "ansible.builtin.set_fact": {
        "bk_hdr_id": "{{ bk_hdr_id if (bk_hdr_id | length > 0) else "
                     "(bk_hdr_put.json.policyAction.id | default(bk_hdr_put.json.id)) }}",
    }
}


@cas("11 — anti-diagonale sur un appel correle methode+chemin (role restaure "
     "tel qu'avant la scission de backend.yml) : le linter d'avant durcissement "
     "laisse passer, le linter actuel l'attrape")
def cas_11():
    fx = Fixture()
    try:
        # 1) Role : remplacer les deux taches a methode fixe (post-scission)
        # par la tache unique correlee (pre-scission) — sans cette mutation,
        # ce cas ne testerait plus rien de different du cas 3, puisque
        # backend.yml ne contient plus aucun appel correle depuis la scission.
        taches = fx.charger_role(ROLE_INNOCENT)
        idx_put = next(i for i, t in enumerate(taches)
                        if t.get("name", "").startswith("Backend : mettre à jour l'action"))
        idx_post = next(i for i, t in enumerate(taches)
                         if t.get("name", "").startswith("Backend : créer l'action"))
        idx_fact = idx_post + 1
        assert idx_fact < len(taches) and "bk_hdr_id" in taches[idx_fact].get(
            "ansible.builtin.set_fact", {}), (
            "structure de backend.yml inattendue — le set_fact bk_hdr_id ne "
            "suit plus immediatement la tache POST : ce cas doit etre revu")
        taches[idx_put:idx_fact + 1] = [_TACHE_CORRELEE_PRE_SCISSION, _FACT_CORRELEE_PRE_SCISSION]
        fx.ecrire_role(ROLE_INNOCENT, taches)

        # 2) Contrat : l'anti-diagonale. Le contrat REEL declare la diagonale
        # correcte : POST /policyActions et PUT /policyActions/{id}. On la
        # remplace ici par PUT /policyActions et POST /policyActions/{id}.
        # L'ancienne double couverture (chaque forme couverte par au moins
        # une methode, chaque methode par au moins une forme) est satisfaite
        # par les DEUX declarations — alors que les deux branches reelles de
        # l'appel correle (POST sans id, PUT avec id) tombent en 404 :
        # aucune des deux n'est celle declaree.
        doc = fx.charger_contrat()
        post = doc["paths"]["/rest/apigateway/policyActions"].pop("post")
        put = doc["paths"]["/rest/apigateway/policyActions/{id}"].pop("put")
        doc["paths"]["/rest/apigateway/policyActions"]["put"] = put
        doc["paths"]["/rest/apigateway/policyActions/{id}"]["post"] = post
        fx.ecrire_contrat(doc)

        code, out = fx.executer()
        assert code == 1, f"code {code}, attendu 1\n{out}"
        assert "NON DECLARE" in out, f"section des appels manquants absente\n{out}"
        assert "policyActions" in out and ROLE_INNOCENT in out, (
            f"l'appel policyActions (methode+chemin conditionnels par le meme "
            f"Jinja, {ROLE_INNOCENT}) n'est pas signale\n{out}")
    finally:
        fx.nettoyer()


def _n_manquants(out):
    m = re.search(r"(\d+) appel\(s\) NON DECLARE", out)
    return int(m.group(1)) if m else 0


@cas("12 — appel a UNE methode et UNE forme (aucun Jinja conditionnel) : la "
     "couverture se reduit exactement a « cette paire est declaree »")
def cas_12():
    fx = Fixture()
    try:
        # apim_selfservice_app/tasks/team.yml : url sans aucun Jinja conditionnel
        # (juste la base {{ apim_ss_api_base }}), methode par defaut GET (pas de
        # champ `method:`) : len(methodes) == 1 et len(formes) == 1. Le produit
        # croisé (tache 3, desormais inconditionnel — cf. lint-contrat-proxy.py)
        # s'y reduit deja exactement a la simple paire : seule (GET,
        # /accessProfiles) doit etre exigee, ni plus ni moins.
        #
        # Baseline avant mutation, PAS un total absolu code en dur : au moment
        # d'ecrire ce cas, le depot reel est vert (n_base == 0), mais comparer
        # a la baseline plutot qu'a une constante isole ce que CE cas mute de
        # tout etat du depot hors de son champ — y compris un rouge futur sans
        # rapport avec accessProfiles, que ce cas n'a pas a connaitre.
        _, out_base = fx.executer()
        n_base = _n_manquants(out_base)

        doc = fx.charger_contrat()
        del doc["paths"]["/rest/apigateway/accessProfiles"]["get"]
        fx.ecrire_contrat(doc)
        code, out = fx.executer()
        assert code == 1, f"code {code}, attendu 1\n{out}"
        assert "NON DECLARE" in out, f"section des appels manquants absente\n{out}"
        assert "apim_selfservice_app/tasks/team.yml" in out and "accessProfiles" in out, (
            f"l'appel GET /accessProfiles (team.yml) n'est pas signale\n{out}")
        # Retirer UNE SEULE paire (methode, forme) non conditionnelle ne doit
        # signaler QUE ses appelants reels (deux fichiers team.yml appellent
        # GET /accessProfiles, chacun a une methode et une forme) — rien de
        # plus au-dela de la baseline : la reduction reste locale.
        assert _n_manquants(out) == n_base + 2, (
            f"{_n_manquants(out) - n_base} appel(s) nouvellement signale(s) par "
            f"rapport a la baseline (attendu 2 : les deux appelants reels de "
            f"GET /accessProfiles)\n--- baseline ---\n{out_base}\n--- apres mutation ---\n{out}")
    finally:
        fx.nettoyer()


@cas("13 — appel a la base SANS ESPACES ({{apim_ss_api_base}}) : reconnu apres "
     "normalisation, code 1 (chemin non declare)")
def cas_13():
    fx = Fixture()
    try:
        taches = fx.charger_role(ROLE_INNOCENT)
        taches.append({
            "name": "Mutation banc : base sans espaces Jinja",
            "ansible.builtin.uri": {
                "url": "{{apim_ss_api_base}}/nouveau-endpoint-sans-espaces",
            },
        })
        fx.ecrire_role(ROLE_INNOCENT, taches)
        code, out = fx.executer()
        assert code == 1, f"code {code}, attendu 1\n{out}"
        assert "NON DECLARE" in out, f"section des appels manquants absente\n{out}"
        assert "nouveau-endpoint-sans-espaces" in out and ROLE_INNOCENT in out, (
            f"l'appel sans espaces autour de apim_ss_api_base n'est pas signale\n{out}")
    finally:
        fx.nettoyer()


@cas("14 — appel a la base AVEC FILTRE JINJA ({{ apim_ss_api_base | default(...) }}) : "
     "reconnu apres normalisation, code 1 (chemin non declare)")
def cas_14():
    fx = Fixture()
    try:
        taches = fx.charger_role(ROLE_INNOCENT)
        taches.append({
            "name": "Mutation banc : base avec filtre Jinja default()",
            "ansible.builtin.uri": {
                "url": "{{ apim_ss_api_base | default('http://localhost:5555/rest/apigateway') }}"
                       "/nouveau-endpoint-filtre",
            },
        })
        fx.ecrire_role(ROLE_INNOCENT, taches)
        code, out = fx.executer()
        assert code == 1, f"code {code}, attendu 1\n{out}"
        assert "NON DECLARE" in out, f"section des appels manquants absente\n{out}"
        assert "nouveau-endpoint-filtre" in out and ROLE_INNOCENT in out, (
            f"l'appel avec filtre Jinja sur apim_ss_api_base n'est pas signale\n{out}")
    finally:
        fx.nettoyer()


@cas("15 — ansible.builtin.get_url sur la base (surface aujourd'hui invisible, "
     "meme avec un Jinja parfaitement bien forme) : code 1")
def cas_15():
    fx = Fixture()
    try:
        taches = fx.charger_role(ROLE_INNOCENT)
        taches.append({
            "name": "Mutation banc : get_url sur la base",
            "ansible.builtin.get_url": {
                "url": "{{ apim_ss_api_base }}/nouveau-fichier-get-url",
                "dest": "/tmp/mutation-banc-get-url",
            },
        })
        fx.ecrire_role(ROLE_INNOCENT, taches)
        code, out = fx.executer()
        assert code == 1, f"code {code}, attendu 1\n{out}"
        assert "NON DECLARE" in out, f"section des appels manquants absente\n{out}"
        assert "nouveau-fichier-get-url" in out and ROLE_INNOCENT in out, (
            f"l'appel get_url sur la base n'est pas signale\n{out}")
    finally:
        fx.nettoyer()


@cas("16 — ansible.builtin.command avec curl sur la base (surface aujourd'hui "
     "invisible) : code 1")
def cas_16():
    fx = Fixture()
    try:
        taches = fx.charger_role(ROLE_INNOCENT)
        taches.append({
            "name": "Mutation banc : curl direct sur la base via command",
            "ansible.builtin.command":
                "curl -sf -X POST {{ apim_ss_api_base }}/nouveau-endpoint-curl",
        })
        fx.ecrire_role(ROLE_INNOCENT, taches)
        code, out = fx.executer()
        assert code == 1, f"code {code}, attendu 1\n{out}"
        assert "SUSPECT" in out, (
            f"le garde command:/shell: contenant curl ne s'est pas declenche\n{out}")
        assert ROLE_INNOCENT in out and "curl" in out, (
            f"la tache command: avec curl sur la base n'est pas signalee\n{out}")
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
