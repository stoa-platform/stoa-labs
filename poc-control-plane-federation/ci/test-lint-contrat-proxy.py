#!/usr/bin/env python3
"""Banc d'essai de lint-contrat-proxy.py — rejoue les experiences manuelles.

Le linter d'allow-list (lint-contrat-proxy.py) a deja laisse passer une SERIE
de faux negatifs — un compte fige ici vieillirait mal, le lot 1 bis en a ferme
plus d'une dizaine : base sans espaces, base filtree par un Jinja, get_url,
command:/shell:, anti-diagonale sur un appel correle, methode Jinja a
guillemets doubles, inventaire vide ou ampute, doublon de cle au contrat, URL
montee en set_fact, shell sans curl, uri free-form, raw:/script:, verdict
multipart controle sur une seule paire. Chacun a ete trouve par une experience
manuelle (muter un fichier du depot, relancer, regarder, restaurer a la main)
que personne n'avait enregistree. Ce banc les rejoue toutes, pour de bon, a
chaque run — un cas par faux negatif ferme, et le compte fait foi, pas ce
paragraphe.

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
        # 1) Contrat : l'anti-diagonale. Le contrat REEL declare la diagonale
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

        # 2) BASELINE, avant toute mutation de role. Permuter post/put sur
        # /policyActions dans TOUT le contrat abime aussi des appels a methode
        # FIXE (apim_selfservice_app/tasks/main.yml, apim_publish_api/tasks/
        # inbound.yml appellent POST /policyActions) : `code == 1` et
        # « NON DECLARE » sont donc satisfaits par ces degats collateraux, sans
        # rien devoir au produit croise. Deux affaiblissements successifs de ce
        # cas dans ce lot sont partis de la. La discrimination est desormais
        # portee par TROIS choses mesurees contre cette baseline, aucune
        # incidente : la signature « PUT/POST » (methodes jointes d'un appel
        # correle — aucun appel du depot n'en produit, `grep -rn 'method:.*{{'
        # ansible/roles` ne rend rien depuis la scission), le NOM de la tache
        # correlee, et le DELTA de comptage.
        _, out_base = fx.executer()
        n_base = _n_manquants(out_base)
        assert "PUT/POST" not in out_base, (
            f"un appel a methodes PUT/POST existe deja dans l'arbre de roles "
            f"reel : la signature de ce cas n'est plus discriminante, le "
            f"revoir\n{out_base}")

        # 3) Role : remplacer les deux taches a methode fixe (post-scission)
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

        code, out = fx.executer()
        assert code == 1, f"code {code}, attendu 1\n{out}"
        assert "NON DECLARE" in out, f"section des appels manquants absente\n{out}"
        # Signature de l'appel correle : ses DEUX methodes, jointes par le
        # linter. Un appel a methode fixe ne peut pas la produire — c'est elle,
        # et non la simple presence du nom de fichier, qui prouve que c'est bien
        # le produit croise qui a mordu (un renommage de backend.yml ne peut
        # plus vider ce cas de sa substance).
        assert "PUT/POST" in out, (
            f"l'appel correle (methodes PUT et POST portees par le meme Jinja) "
            f"n'apparait pas parmi les appels signales : seuls les degats "
            f"collateraux de la permutation ont ete constates\n{out}")
        assert "Backend : converger l'action" in out and ROLE_INNOCENT in out, (
            f"l'appel policyActions correle (methode+chemin par le meme Jinja, "
            f"{ROLE_INNOCENT}) n'est pas nomme dans la sortie\n{out}")
        # Delta de comptage contre la baseline : la mutation de role retire
        # DEUX appels a methode fixe (tous deux signales dans la baseline, la
        # permutation les ayant prives de leur declaration) et en ajoute UN
        # seul, correle. Tout autre delta signifie que la mutation a deplace
        # autre chose que ce que ce cas pretend exercer.
        assert _n_manquants(out) == n_base - 1, (
            f"delta de {_n_manquants(out) - n_base} appel(s) signale(s) contre "
            f"la baseline (attendu -1 : deux appels a methode fixe remplaces "
            f"par un seul appel correle)\n--- baseline ---\n{out_base}\n"
            f"--- apres mutation du role ---\n{out}")
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


# Les six cas suivants (17 a 22) couvrent la tache 5 (lot 1 bis) — diagnostic
# et robustesse. Chacun construit lui-meme l'etat qu'il teste, sur une copie
# jetable : aucun ne depend d'un total fige de l'arbre reel au-dela d'un
# plancher verifie dynamiquement (piege deja paye dans ce lot — cf. cas 11).


@cas("17 — role entier absent (repertoire supprime) mais planchers de fichiers "
     "franchis quand meme : MIN_APPELS doit mordre la ou MIN_FICHIERS_ROLES ne "
     "mord pas")
def cas_17():
    fx = Fixture()
    try:
        # apim_promote_api : un role ENTIER, choisi parce que sa disparition
        # laisse >= 20 fichiers (le plancher de fichiers reste MUET) tout en
        # retirant assez d'appels pour que le plancher d'appels, s'il est
        # calibre pour mordre, le fasse. Verifie dynamiquement ci-dessous —
        # pas suppose.
        role_absent = "apim_promote_api"
        cible = os.path.join(fx.roles, role_absent)
        assert os.path.isdir(cible), (
            f"role {role_absent} introuvable dans la copie jetable — ce cas "
            "doit etre revu")
        shutil.rmtree(cible)

        fichiers_restants = 0
        for _, _, noms in os.walk(fx.roles):
            for n in noms:
                if n.endswith((".yml", ".yaml")):
                    fichiers_restants += 1
        assert fichiers_restants >= 20, (
            f"il ne reste que {fichiers_restants} fichier(s) apres suppression de "
            f"{role_absent} : MIN_FICHIERS_ROLES (20) se declencherait avant "
            "MIN_APPELS, ce que ce cas ne veut PAS exercer — choisir un autre role")

        code, out = fx.executer()
        assert code == 2, (
            f"code {code}, attendu 2 — un role entier a disparu sans faire "
            f"chuter le nombre de fichiers sous le plancher\n{out}")
        assert "fichier(s) YAML parcouru" not in out, (
            f"c'est le plancher de FICHIERS qui a mordu, pas celui des APPELS — "
            f"ce cas doit prouver l'inverse (MIN_APPELS non decoratif)\n{out}")
        assert "appel(s) releve" in out, (
            f"le plancher MIN_APPELS ne s'est pas declenche alors qu'un role "
            f"entier a disparu — il resterait donc purement decoratif\n{out}")
    finally:
        fx.nettoyer()


@cas("18 — fichier YAML illisible ET inventaire ampute simultanement : la "
     "cause (fichier non parsable) s'imprime AVANT le symptome (code 2)")
def cas_18():
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
            "ce cas doit etre revu avant qu'il ait un sens")
        # Ampute l'inventaire (comme cas 9) ET rend illisible un fichier
        # CONSERVE : les deux causes cohabitent, pour verifier que la seconde
        # (YAML non parsable) n'est pas avalee par le retour anticipe de la
        # premiere (inventaire anormal, code 2).
        a_corrompre = fichiers[0]
        for p in fichiers[19:]:
            os.remove(p)
        with open(a_corrompre, "a", encoding="utf-8") as f:
            f.write("\n- this: [is, not, valid: yaml\n")

        code, out = fx.executer()
        assert code == 2, f"code {code}, attendu 2\n{out}"
        assert "YAML non parsable" in out, (
            f"la cause (fichier YAML non parsable) doit s'imprimer, pas "
            f"disparaitre derriere le symptome INVENTAIRE ANORMAL\n{out}")
        assert os.path.relpath(a_corrompre, fx.roles) in out, (
            f"le fichier fautif n'est pas nomme\n{out}")
        assert out.index("YAML non parsable") < out.index("INVENTAIRE ANORMAL"), (
            f"la cause (YAML non parsable) doit s'imprimer AVANT le symptome "
            f"(INVENTAIRE ANORMAL), pas apres\n{out}")
    finally:
        fx.nettoyer()


@cas("19 — tache uri en forme compacte (sans name:) : le nom ne retombe plus "
     "sur un '?' opaque")
def cas_19():
    fx = Fixture()
    try:
        taches = fx.charger_role(ROLE_INNOCENT)
        taches.append({
            # Pas de cle "name" : forme compacte, 15 appels sur 96 dans le
            # depot reel l'utilisent deja.
            "ansible.builtin.uri": {
                "url": "{{ apim_ss_api_base }}/nouveau-endpoint-forme-compacte",
            },
        })
        fx.ecrire_role(ROLE_INNOCENT, taches)
        code, out = fx.executer()
        assert code == 1, f"code {code}, attendu 1\n{out}"
        assert "NON DECLARE" in out, f"section des appels manquants absente\n{out}"
        assert "nouveau-endpoint-forme-compacte" in out and ROLE_INNOCENT in out, (
            f"l'appel en forme compacte n'est pas signale\n{out}")
        assert f"{ROLE_INNOCENT} — ?" not in out, (
            f"le nom de la tache est retombe sur '?' — impossible a retrouver "
            f"dans {ROLE_INNOCENT} quand le linter rougit\n{out}")
    finally:
        fx.nettoyer()


@cas("20 — doublon de cle top-level 'paths' au contrat : refuse (code 2), "
     "jamais un ecrasement silencieux")
def cas_20():
    fx = Fixture()
    try:
        # yaml.safe_dump ne peut pas ecrire un doublon (les cles d'un dict
        # Python sont uniques) : le doublon est ecrit en texte brut, en
        # AJOUTANT une seconde cle racine "paths" a la fin du fichier — ce
        # qui, sous un chargeur nu, ecraserait TOUTE la premiere declaration
        # (21 chemins, 35 operations) au profit du seul chemin factice
        # ci-dessous.
        with open(fx.contrat, "a", encoding="utf-8") as f:
            f.write(textwrap.dedent("""
                paths:
                  /rest/apigateway/mutation-banc-doublon:
                    get:
                      summary: doublon de cle top-level 'paths' — banc
                      responses:
                        "200":
                          $ref: "#/components/responses/proxied"
                """))
        code, out = fx.executer()
        assert code == 2, (
            f"code {code}, attendu 2 (contrat illisible : cle 'paths' dupliquee)\n{out}")
        assert "dupliqu" in out.lower(), (
            f"le doublon de cle n'est pas signale dans la sortie\n{out}")
    finally:
        fx.nettoyer()


@cas("21 — methode Jinja a guillemets doubles ({{ \"PUT\" if x else \"POST\" }}) : "
     "methodes reconnues (pas vides), l'appel non declare est signale")
def cas_21():
    fx = Fixture()
    try:
        taches = fx.charger_role(ROLE_INNOCENT)
        taches.append({
            "name": "Mutation banc : methode Jinja a guillemets doubles",
            "ansible.builtin.uri": {
                "url": "{{ apim_ss_api_base }}/nouveau-endpoint-guillemets-doubles",
                "method": '{{ "PUT" if bk_hdr_id else "POST" }}',
            },
        })
        fx.ecrire_role(ROLE_INNOCENT, taches)
        code, out = fx.executer()
        assert code == 1, (
            f"code {code}, attendu 1 (methodes PUT/POST reconnues, chemin non "
            f"declare) — methodes probablement retombees a une liste vide\n{out}")
        assert "NON DECLARE" in out, f"section des appels manquants absente\n{out}"
        assert "nouveau-endpoint-guillemets-doubles" in out and ROLE_INNOCENT in out, (
            f"l'appel a methode Jinja a guillemets doubles n'est pas signale\n{out}")
    finally:
        fx.nettoyer()


@cas("22 — module PyYAML absent (environnement casse) : code 2, jamais 1, "
     "jamais un traceback brut")
def cas_22():
    fx = Fixture()
    leurre = tempfile.mkdtemp(prefix="lint-contrat-proxy-bench-pyyaml-absent-")
    try:
        with open(os.path.join(leurre, "yaml.py"), "w", encoding="utf-8") as f:
            f.write('raise ImportError("PyYAML absent (simule par le banc)")\n')
        env = dict(os.environ)
        env["PYTHONPATH"] = leurre + os.pathsep + env.get("PYTHONPATH", "")
        env["STOA_LINT_CONTRAT"] = fx.contrat
        env["STOA_LINT_ROLES"] = fx.roles
        r = subprocess.run([sys.executable, LINTER], env=env,
                            capture_output=True, text=True)
        assert r.returncode == 2, (
            f"code {r.returncode}, attendu 2 — un module absent est un "
            f"environnement casse, PAS une violation de politique (1)\n"
            f"{r.stdout}{r.stderr}")
        assert "Traceback" not in r.stderr, (
            f"traceback brut expose a la place d'un diagnostic propre\n{r.stderr}")
    finally:
        fx.nettoyer()
        shutil.rmtree(leurre, ignore_errors=True)


# Les quatre cas suivants (23 a 26) couvrent les formes d'appel que le dispatch
# de `taches_appels()` laissait tomber dans son `else:` — recursion muette, donc
# VERT sur un DELETE sans declaration ni derogation. Ils sont ecrits AVANT le
# correctif du linter et constates ROUGES contre lui (revue finale, lot 1 bis).
# Chacun pose son appel dans un role, sans toucher au contrat : c'est bien
# l'inventaire des appels — pas la couverture du contrat — qui est en cause.


@cas("23 — URL montee en set_fact puis consommee ailleurs (forme IDIOMATIQUE de "
     "ce depot) : le site de DEFINITION du fait est signale, jamais ignore")
def cas_23():
    fx = Fixture()
    try:
        taches = fx.charger_role(ROLE_INNOCENT)
        taches.append({
            "name": "Mutation banc : URL de suppression montee en fait",
            "ansible.builtin.set_fact": {
                "mutation_del_url":
                    "{{ apim_ss_api_base }}/strategies/{{ mutation_id }}",
            },
        })
        taches.append({
            # Site d'USAGE : l'URL n'y mentionne plus la base, rien ne peut y
            # etre rattache au contrat. C'est la definition qui doit parler.
            "name": "Mutation banc : DELETE via le fait monte plus haut",
            "ansible.builtin.uri": {
                "url": "{{ mutation_del_url }}",
                "method": "DELETE",
            },
        })
        fx.ecrire_role(ROLE_INNOCENT, taches)
        code, out = fx.executer()
        assert code == 1, (
            f"code {code}, attendu 1 — un DELETE monte par set_fact passe au "
            f"vert : ni le site de definition ni le site d'usage ne parle\n{out}")
        assert "SUSPECT" in out, f"aucun suspect signale\n{out}"
        assert "mutation_del_url" in out and ROLE_INNOCENT in out, (
            f"le set_fact qui monte l'URL sur la base n'est pas signale\n{out}")
    finally:
        fx.nettoyer()


@cas("24 — shell: sans curl (wget) sur la base : la porte command:/shell: ne "
     "doit pas dependre du nom de l'outil HTTP")
def cas_24():
    fx = Fixture()
    try:
        taches = fx.charger_role(ROLE_INNOCENT)
        taches.append({
            "name": "Mutation banc : suppression par un autre client HTTP",
            "ansible.builtin.shell":
                "wget --method=DELETE {{ apim_ss_api_base }}/strategies/"
                "{{ mutation_id }}",
        })
        fx.ecrire_role(ROLE_INNOCENT, taches)
        code, out = fx.executer()
        assert code == 1, (
            f"code {code}, attendu 1 — un shell: qui attaque la base sans "
            f"ecrire 'curl' passe au vert\n{out}")
        assert "SUSPECT" in out, f"aucun suspect signale\n{out}"
        assert "wget" in out and ROLE_INNOCENT in out, (
            f"la tache shell: avec wget sur la base n'est pas signalee\n{out}")
    finally:
        fx.nettoyer()


@cas("25 — uri: en forme free-form (valeur SCALAIRE, pas un dict) : "
     "`uri: url=... method=DELETE` ne doit pas glisser hors du dispatch")
def cas_25():
    fx = Fixture()
    try:
        taches = fx.charger_role(ROLE_INNOCENT)
        taches.append({
            "name": "Mutation banc : uri free-form",
            "ansible.builtin.uri":
                "url={{ apim_ss_api_base }}/strategies/{{ mutation_id }} "
                "method=DELETE",
        })
        fx.ecrire_role(ROLE_INNOCENT, taches)
        code, out = fx.executer()
        assert code == 1, (
            f"code {code}, attendu 1 — un uri: free-form (valeur scalaire) "
            f"echappe au dispatch, qui n'accepte que la forme dict\n{out}")
        assert "SUSPECT" in out, f"aucun suspect signale\n{out}"
        assert "ansible.builtin.uri" in out and "strategies" in out and (
            ROLE_INNOCENT in out), (
            f"l'appel uri: free-form n'est pas signale\n{out}")
    finally:
        fx.nettoyer()


@cas("26 — ansible.builtin.raw: et script: sur la base : deux modules "
     "d'execution que le dispatch ne connait pas du tout")
def cas_26():
    fx = Fixture()
    try:
        taches = fx.charger_role(ROLE_INNOCENT)
        taches.append({
            "name": "Mutation banc : raw sur la base",
            "ansible.builtin.raw":
                "curl -X DELETE {{ apim_ss_api_base }}/strategies/"
                "{{ mutation_id }}",
        })
        taches.append({
            "name": "Mutation banc : script sur la base",
            "ansible.builtin.script":
                "supprimer-strategie.sh {{ apim_ss_api_base }}/strategies/"
                "{{ mutation_id }}",
        })
        fx.ecrire_role(ROLE_INNOCENT, taches)
        code, out = fx.executer()
        assert code == 1, (
            f"code {code}, attendu 1 — raw:/script: sur la base passent au "
            f"vert\n{out}")
        assert "SUSPECT" in out, f"aucun suspect signale\n{out}"
        assert "ansible.builtin.raw" in out, (
            f"la tache raw: sur la base n'est pas signalee\n{out}")
        assert "ansible.builtin.script" in out, (
            f"la tache script: sur la base n'est pas signalee\n{out}")
    finally:
        fx.nettoyer()


# Les deux cas suivants (27, 28) couvrent le verdict `multipart` — une des
# quatre sections de verdict du linter, resolution de `$ref` vers
# `components/requestBodies` comprise, qu'AUCUN cas n'exercait jusqu'ici (le
# mot n'apparaissait pas une fois dans ce banc). Trois appels reels sont en
# `body_format: form-multipart` et le contrat porte `passthroughJsonOrMultipart`
# sur trois operations : la section n'etait pourtant garantie par rien.


@cas("27 — POST /archive repointe sur un requestBody JSON SEUL alors que "
     "l'appel reel est en form-multipart : code 1, section multipart")
def cas_27():
    fx = Fixture()
    try:
        doc = fx.charger_contrat()
        # Le $ref reste un $ref (la resolution vers components/requestBodies
        # fait partie de ce qui est exerce ici) : seule sa CIBLE change, de
        # passthroughJsonOrMultipart vers passthrough (application/json seul).
        doc["paths"]["/rest/apigateway/archive"]["post"]["requestBody"] = {
            "$ref": "#/components/requestBodies/passthrough"}
        fx.ecrire_contrat(doc)
        code, out = fx.executer()
        assert code == 1, (
            f"code {code}, attendu 1 — l'import d'archive (form-multipart) "
            f"passe au vert contre un requestBody JSON seul\n{out}")
        assert "form-multipart sans requestBody multipart declare" in out, (
            f"la section de verdict multipart ne s'est pas declenchee\n{out}")
        assert "/rest/apigateway/archive" in out and (
            "apim_promote_api/tasks/import.yml" in out), (
            f"l'appelant reel de POST /archive n'est pas signale\n{out}")
    finally:
        fx.nettoyer()


@cas("28 — appel multipart a DEUX methodes declarees dont UNE SEULE porte "
     "multipart/form-data : les deux paires sont controlees, pas la premiere seule")
def cas_28():
    fx = Fixture()
    try:
        # PUT /apis/{id} declare deja passthroughJsonOrMultipart au contrat
        # reel. On lui ajoute un POST sur le MEME chemin, en JSON seul : un
        # appel dont la methode est un conditionnel Jinja (PUT ou POST) a donc
        # DEUX paires declarees, dont une seule accepte le multipart.
        doc = fx.charger_contrat()
        doc["paths"]["/rest/apigateway/apis/{id}"]["post"] = {
            "summary": "mutation banc — meme chemin, requestBody JSON seul",
            "requestBody": {"$ref": "#/components/requestBodies/passthrough"},
            "responses": {"200": {"$ref": "#/components/responses/proxied"}},
        }
        fx.ecrire_contrat(doc)

        taches = fx.charger_role(ROLE_INNOCENT)
        taches.append({
            "name": "Mutation banc : multipart a methode conditionnelle, UNE forme",
            "ansible.builtin.uri": {
                # UNE seule forme de chemin (le Jinja est un segment entier) :
                # ce qui varie est la METHODE, dont l'ordre de lecture est
                # deterministe (liste, pas un set) — le cas est donc stable,
                # la ou faire varier la FORME dependrait de l'ordre d'iteration
                # d'un set Python, aleatoire d'un processus a l'autre.
                "url": "{{ apim_ss_api_base }}/apis/{{ mutation_id }}",
                "method": "{{ 'PUT' if mutation_id else 'POST' }}",
                "body_format": "form-multipart",
                "body": {"file": {"filename": "x.zip",
                                   "mime_type": "application/zip"}},
            },
        })
        fx.ecrire_role(ROLE_INNOCENT, taches)

        code, out = fx.executer()
        assert code == 1, (
            f"code {code}, attendu 1 — le multipart n'est controle que sur la "
            f"PREMIERE paire declaree, la seconde (POST, JSON seul) passe\n{out}")
        assert "form-multipart sans requestBody multipart declare" in out, (
            f"la section de verdict multipart ne s'est pas declenchee\n{out}")
        assert "POST" in out and "/rest/apigateway/apis/{id}" in out and (
            ROLE_INNOCENT in out), (
            f"la paire (POST, /apis/{{id}}) — declaree mais SANS multipart — "
            f"n'est pas signalee\n{out}")
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
