#!/usr/bin/env python3
"""Le contrat d'allow-list du proxy d'admin couvre-t-il ce que les roles appellent ?

Hors contrat -> 404 (ADR-075). Un appel non declare ne casse donc QU'EN mode
proxy-oauth2, jamais en direct : le defaut est invisible tant qu'on teste en
direct. Ce linter le rend opposable sans gateway.

Il verifie DEUX sens, pas un seul :
  - usage ⊆ contrat : tout appel des roles est declare (sinon 404 a la bascule) ;
  - contrat ⊆ politique : AUCUN `delete:` au contrat, sans aucune exception
    (invariant phare d'ADR-075). Une cle de DEROGATIONS couvre un appel de
    role qui contourne le proxy (acces direct, hors chaine CI) — jamais une
    declaration au contrat : les deux sens ne se recouvrent pas.
Ne verifier que le premier sens laissait passer un `delete:` ajoute au contrat
sans appelant — c'est-a-dire exactement la regression que l'invariant interdit.

Sans argument : verifie. `--liste` : imprime l'inventaire des appels.
"""
import os
import re
import sys

# Importe APRES capture de l'echec eventuel : un `import yaml` nu, en tete de
# module, laisse l'interpreteur mourir sur un traceback si PyYAML est absent
# (environnement casse) — exit code 1, EXACTEMENT le meme code qu'une
# violation de politique constatee. Un module absent, c'est « je ne peux rien
# conclure », pas « j'ai verifie et c'est en violation » : code 2, distinct,
# et un diagnostic lisible plutot qu'un traceback brut.
try:
    import yaml
except ImportError as _erreur_import:
    print(f"✗ ENVIRONNEMENT CASSE — module Python requis introuvable : {_erreur_import}")
    print("    Ce linter depend de PyYAML (pip install pyyaml). Sans lui, aucune")
    print("    verification n'est possible — ce n'est PAS une violation de politique.")
    sys.exit(2)

RACINE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Chemins surchargeables : sans cela le linter n'est testable que contre le vrai
# depot, ce qui a oblige chaque revue a muter des fichiers suivis puis a les
# restaurer a la main. Les defauts restent le depot reel.
CONTRAT = os.environ.get("STOA_LINT_CONTRAT") or os.path.join(
    RACINE, "gateways/webmethods/admin-proxy/wm-admin-proxy.openapi.yaml")
ROLES = os.environ.get("STOA_LINT_ROLES") or os.path.join(RACINE, "ansible/roles")
PREFIXE = "/rest/apigateway"
BASE_VAR = "apim_ss_api_base"
# Reconnaissance NORMALISEE de la base : tolere les variations d'espacement
# autour du nom de variable ET un filtre Jinja optionnel ({{ x | default(y) }}).
# Racine du bug corrige ici : une comparaison LITTERALE
# (`url.startswith("{{ apim_ss_api_base }}")`) ne reconnaissait que CETTE
# graphie exacte. `{{apim_ss_api_base}}` (sans espaces, Jinja parfaitement
# valide) ou `{{ apim_ss_api_base | default(x) }}` ne matchaient pas — et
# l'appel disparaissait en silence : jamais ajoute a l'inventaire, jamais
# signale, le linter restait vert. Ancree en debut de chaine : le PREFIXE de
# l'URL doit etre la base (eventuellement filtree), pas une occurrence
# quelconque plus loin dans la chaine.
BASE_RE = re.compile(r"^\{\{\s*" + re.escape(BASE_VAR) + r"\s*(\|[^}]*)?\s*\}\}")
# Planchers d'inventaire. `os.walk` sur un repertoire absent ne leve RIEN : le
# linter concluait « les 0 appels sont couverts », code 0 — un vert sur du vide.
# Ces planchers sont GROSSIERS a dessein : ils ne figent pas un compte (31
# fichiers / 96 appels a ce jour, et ca monte quand des roles arrivent), ils
# distinguent « inventaire parcouru » de « inventaire absent ou ampute »
# (checkout partiel, ansible/ non monte, repertoire renomme).
MIN_FICHIERS_ROLES = 20
# Recalibre (mesure sur le depot reel) : a 60, ce plancher etait INATTEIGNABLE.
# Retirer un role entier (apim_promote_api, 8 fichiers / 24 appels, ou
# apim_publish_api, 7 fichiers / 29 appels) laisse >= 20 fichiers — le plancher
# de FICHIERS reste muet — mais ne fait chuter le total qu'a 72 ou 67 appels :
# un ancien plancher a 60 ne mordait JAMAIS sur ces pertes-la, seul le hasard
# de l'ordre de parcours (os.walk n'a pas d'ordre garanti) aurait pu le faire
# mordre ailleurs. Un garde-fou qui ne peut pas se declencher est decoratif —
# 80 encadre les deux pertes mesurees (72, 67) tout en restant sous le total
# reel (96), avec la meme marge grossiere que le plancher de fichiers.
MIN_APPELS = 80
yaml_errors = []

# Derogations ASSUMEES : appels que le contrat n'autorisera JAMAIS. Chaque entree
# porte son motif — une derogation sans motif est un oubli deguise — ET le
# fichier de role qui la porte : une derogation vaut pour l'appelant NOMME au
# motif, pas pour tout appelant futur du meme couple methode/chemin.
#
# Le chemin de la cle est ANCRE SUR ROLES (pas RACINE) : c'est la meme
# convention que le champ "ou" pose par taches_uri(). Ancrer sur RACINE cassait
# des que ROLES etait surcharge hors de RACINE/ansible/roles — le chemin
# devenait un "../../../.." absurde et la derogation ne matchait plus jamais
# (mesure en preparant ce plan).
DEROGATIONS = {
    ("DELETE", "/rest/apigateway/strategies/{id}",
     "apim_selfservice_app/tasks/rotate-strategy.yml"):
        "ADR-075 interdit tout DELETE via le proxy. La rotation d'identifiants "
        "(apim_selfservice_app/tasks/rotate-strategy.yml) reste un geste "
        "d'exploitation en acces direct, hors chaine CI.",
}


class _ChargeurContratSansDoublons(yaml.SafeLoader):
    """SafeLoader qui REFUSE toute cle dupliquee dans un mapping, au lieu de
    laisser silencieusement la derniere ecraser la precedente — comportement
    par defaut d'un `yaml.safe_load` nu. Reserve au CONTRAT : un doublon de
    cle top-level (ex. deux blocs `paths:`) y fait disparaitre des chemins
    declares SANS UN MOT, dans le sens usage ⊆ contrat — direction fail-closed
    deja voulue ailleurs dans ce fichier, mais ici totalement MUETTE. Reproduit
    accidentellement pendant une revue du lot 1."""

    def construct_mapping(self, node, deep=False):
        vues = set()
        for cle_node, _ in node.value:
            cle = self.construct_object(cle_node, deep=deep)
            if cle in vues:
                raise yaml.constructor.ConstructorError(
                    None, None,
                    f"cle dupliquee dans un mapping du contrat : {cle!r} — la "
                    "premiere declaration serait ecrasee en silence",
                    node.start_mark)
            vues.add(cle)
        return super().construct_mapping(node, deep=deep)


def operations_declarees():
    with open(CONTRAT, encoding="utf-8") as f:
        doc = yaml.load(f, Loader=_ChargeurContratSansDoublons)
    ops = set()
    for chemin, corps in (doc.get("paths") or {}).items():
        for verbe in corps:
            if verbe.lower() in ("get", "put", "post", "delete", "patch"):
                ops.add((verbe.upper(), chemin))
    return ops, doc


def deletes_au_contrat(declarees):
    """Contrat ⊆ politique : ADR-075 n'admet AUCUN DELETE via le proxy.

    Le rollback est un re-apply depuis Git, jamais une suppression. AUCUNE
    exception : une cle de DEROGATIONS couvre un appel de role qui contourne
    le proxy (acces direct, hors chaine CI), pas une declaration au contrat.
    Les deux sens sont distincts — tolerer ici le couple (methode, chemin)
    d'une derogation reviendrait a laisser un `delete:` ajoute au contrat
    sous ce chemin passer au vert, ce que le motif de la derogation exclut
    explicitement.
    """
    return sorted((m, c) for (m, c) in declarees if m == "DELETE")


def base_reconnue(url):
    """Position de fin de la base normalisee dans `url`, ou None si `url` ne
    commence pas par une ecriture reconnue de la base (espacement libre,
    filtre Jinja optionnel). None ne signifie PAS "pas d'appel a la base" —
    voir `_voir_url` : une URL qui MENTIONNE la base sans etre reconnue ici
    est un suspect, jamais une absence silencieuse."""
    m = BASE_RE.match(url)
    return m.end() if m else None


def variantes(url):
    """Normalise une URL de tache (dont la base est deja reconnue par
    `base_reconnue`) en un ou plusieurs chemins de contrat.

    - la query string ne fait pas partie du chemin OpenAPI ;
    - `{{ x }}` colle a un segment => segment OPTIONNEL (Jinja conditionnel :
      `/policyActions{{ ('/' ~ id) if id else '' }}` rend les DEUX formes).
    """
    chemin = url[base_reconnue(url):].split("?", 1)[0]
    colle = re.search(r"[^/]\{\{", chemin)
    if colle:
        # Cas collé : le "/" est à l'intérieur du Jinja
        # Remplacer Jinja par "/{id}" pour avoir la bonne forme (not "{id}")
        formes = {re.sub(r"\{\{.*?\}\}", "/{id}", chemin, flags=re.S)}
        # Ajouter aussi la forme sans identifiant
        formes.add(re.sub(r"\{\{.*?\}\}", "", chemin, flags=re.S))
    else:
        # Cas normal : Jinja entre deux segments
        formes = {re.sub(r"\{\{.*?\}\}", "{id}", chemin, flags=re.S)}
    return {PREFIXE + f.rstrip("/") if f != "/" else PREFIXE for f in formes}


MODULES_URI = ("ansible.builtin.uri", "uri")
MODULES_GET_URL = ("ansible.builtin.get_url", "get_url")
MODULES_COMMANDE = ("ansible.builtin.command", "command",
                     "ansible.builtin.shell", "shell")


def _texte_commande(val):
    """Aplatit la valeur d'une tache command:/shell: en texte cherchable,
    quelle que soit son ecriture (chaine brute, dict cmd:/argv:, liste)."""
    if isinstance(val, str):
        return val
    if isinstance(val, list):
        return " ".join(str(x) for x in val)
    if isinstance(val, dict):
        morceaux = []
        for cle in ("cmd", "argv", "_raw_params"):
            v = val.get(cle)
            if isinstance(v, list):
                morceaux.append(" ".join(str(x) for x in v))
            elif v is not None:
                morceaux.append(str(v))
        return " ".join(morceaux)
    return ""


# Guillemets simples OU doubles : `{{ "PUT" if x else "POST" }}` est du Jinja
# aussi valide que `{{ 'PUT' if x else 'POST' }}`. Une regex ancree sur un SEUL
# type de guillemet laissait passer l'autre : methodes=[] (liste vide), puis
# `all(couverte(m, f) for m in [] for f in formes)` — un all() sur un produit
# vide est VRAI, donc "couverte" sans avoir rien verifie. Pas fail-closed :
# un FAUX VERT muet. Desormais les deux graphies sont reconnues, ET si aucune
# des deux ne matche (autre forme non anticipee), l'appel part en suspect
# plutot que de retomber sur cette liste vide silencieusement "couvrante".
_METHODE_JINJA_RE = re.compile(r"""(['"])(\w+)\1""")


def _voir_url(url, ou, nom, methode_brute, multipart, sortie, suspects):
    """Traite une URL candidate (uri: ou get_url:) : reconnue -> ajoutee a
    `sortie` pour verification contre le contrat ; MENTIONNE la base sans
    etre reconnue -> `suspects`, jamais ignoree en silence (point 2 du
    brief : le linter ne doit jamais preferer le silence au doute)."""
    if base_reconnue(url) is not None:
        brut = str(methode_brute)
        if "{{" in brut:
            methodes = [m.upper() for _, m in _METHODE_JINJA_RE.findall(brut)]
            if not methodes:
                suspects.append((ou, nom,
                    f"methode Jinja illisible (ni guillemets simples ni doubles) : "
                    f"{brut!r}"))
                return
        else:
            methodes = [brut.upper()]
        sortie.append({
            "methodes": methodes,
            "url": url,
            "multipart": multipart,
            "ou": ou,
            "nom": nom,
        })
    elif BASE_VAR in url:
        suspects.append((ou, nom,
                          f"URL mentionnant {BASE_VAR} sans forme reconnue : {url!r}"))


def taches_appels(noeud, fichier, sortie, suspects):
    """Descend recursivement : les taches vivent sous des block/rescue/always.

    Trois surfaces d'appel a la base d'admin, toutes couvertes desormais :
      - uri:/ansible.builtin.uri — verifiee contre le contrat quand reconnue ;
      - get_url:/ansible.builtin.get_url — idem, methode GET implicite (ce
        module n'a pas de parametre `method`) ;
      - command:/shell: dont le texte contient `curl` ET la base — surface
        non structuree, jamais rattachee a un chemin de contrat : TOUJOURS
        signalee en suspect. En extraire un chemin depuis une chaine shell
        libre serait une heuristique fausse un jour, en silence — fail-closed.
    """
    if isinstance(noeud, list):
        for n in noeud:
            taches_appels(n, fichier, sortie, suspects)
    elif isinstance(noeud, dict):
        ou = f"{os.path.relpath(fichier, ROLES)}"
        # `name:` absente -> forme compacte (15 appels sur 96 dans le depot
        # reel). Un repli sur "?" nu est illisible : gener precisement quand
        # le linter rougit et qu'il faut retrouver la tache dans le fichier.
        # Le repli embarque l'URL (ou le texte de commande) — greppable dans
        # `ou` — plutot qu'un symbole opaque.
        nom_declare = noeud.get("name")
        for cle, val in noeud.items():
            if cle in MODULES_URI and isinstance(val, dict):
                url = val.get("url", "")
                if isinstance(url, str):
                    nom = nom_declare or f"(sans name: ; uri {url})"
                    _voir_url(url, ou, nom, val.get("method", "GET"),
                              val.get("body_format") == "form-multipart",
                              sortie, suspects)
            elif cle in MODULES_GET_URL and isinstance(val, dict):
                url = val.get("url", "")
                if isinstance(url, str):
                    nom = nom_declare or f"(sans name: ; get_url {url})"
                    _voir_url(url, ou, nom, "GET", False, sortie, suspects)
            elif cle in MODULES_COMMANDE:
                texte = _texte_commande(val)
                if "curl" in texte and BASE_VAR in texte:
                    nom = nom_declare or "(sans name: ; command/shell avec curl)"
                    suspects.append((ou, nom,
                        "command:/shell: contenant curl et " + BASE_VAR))
            else:
                taches_appels(val, fichier, sortie, suspects)


def appels():
    global yaml_errors
    trouves, suspects, fichiers_vus = [], [], 0
    for dossier, _, fichiers in os.walk(ROLES):
        for f in fichiers:
            if not f.endswith((".yml", ".yaml")):
                continue
            fichiers_vus += 1
            p = os.path.join(dossier, f)
            try:
                doc = yaml.safe_load(open(p, encoding="utf-8"))
            except yaml.YAMLError as e:
                yaml_errors.append((os.path.relpath(p, ROLES), str(e)))
                continue
            taches_appels(doc, p, trouves, suspects)
    return trouves, suspects, fichiers_vus


def inventaire_suspect(trouves, fichiers_vus):
    """Un inventaire vide ou ampute doit ECHOUER BRUYAMMENT, pas rendre un vert.

    Sans ce garde, `ROLES` pointant sur un repertoire absent donnait
    « ✓ les 0 appels des roles sont couverts », code 0 : le linter affirmait
    couvrir ce qu'il n'avait meme pas regarde.
    """
    if not os.path.isdir(ROLES):
        return f"repertoire de roles INTROUVABLE : {ROLES}"
    if fichiers_vus < MIN_FICHIERS_ROLES:
        return (f"{fichiers_vus} fichier(s) YAML parcouru(s) sous {ROLES} — "
                f"plancher attendu : {MIN_FICHIERS_ROLES}")
    if len(trouves) < MIN_APPELS:
        return (f"{len(trouves)} appel(s) releve(s) dans les roles — "
                f"plancher attendu : {MIN_APPELS}")
    return None


def main():
    global yaml_errors
    try:
        declarees, doc = operations_declarees()
    except OSError as e:
        print(f"✗ CONTRAT INTROUVABLE — {CONTRAT} n'a pas pu etre ouvert :")
        print(f"    {e}")
        print("    Checkout partiel, ou STOA_LINT_CONTRAT errone ? Aucune verification")
        print("    possible — ce n'est PAS une violation de politique : code 2.")
        return 2
    except yaml.YAMLError as e:
        print(f"✗ CONTRAT ILLISIBLE — {CONTRAT} n'a pas pu etre charge :")
        print(f"    {e}")
        print("    YAML invalide, ou cle dupliquee (un chemin declare pourrait avoir")
        print("    ete ecrase en silence). Aucune verification possible : code 2.")
        return 2
    trouves, suspects, fichiers_vus = appels()

    # La cause AVANT le symptome : un fichier YAML de roles illisible peut a
    # la fois ecarter des appels (yaml_errors) ET faire chuter l'inventaire
    # sous les planchers ci-dessous (anomalie -> code 2, retour immediat).
    # Imprimer yaml_errors seulement plus loin dans le rapport (comme avant)
    # laissait ce retour anticipe avaler la cause : l'utilisateur recevait
    # « inventaire anormal » sans jamais voir QUEL fichier etait en cause.
    if yaml_errors:
        print(f"✗ {len(yaml_errors)} fichier(s) YAML non parsable :")
        for p, e in sorted(yaml_errors):
            print(f"    {p}\n           {e}")

    anomalie = inventaire_suspect(trouves, fichiers_vus)
    if anomalie:
        print("✗ INVENTAIRE ANORMAL — ce linter n'a rien verifie et ne peut RIEN conclure :")
        print(f"    {anomalie}")
        print("    Checkout partiel, ansible/ non monte, ou repertoire renomme ?")
        print("    Un vert sur un inventaire vide serait un faux garde-fou : code 2.")
        return 2

    if "--liste" in sys.argv:
        for a in sorted(trouves, key=lambda x: (x["url"], x["methodes"])):
            mp = " [multipart]" if a["multipart"] else ""
            print(f'{"/".join(a["methodes"]):6} {a["url"]}{mp}\n       {a["ou"]} — {a["nom"]}')
        for ou, nom, motif in sorted(set(suspects)):
            print(f'SUSPECT {ou} — {nom}\n       {motif}')
        return 0

    manquants, sans_multipart = [], []
    for a in trouves:
        formes = variantes(a["url"])
        couverte = lambda m, f: (m, f) in declarees or (m, f, a["ou"]) in DEROGATIONS
        # Produit croise complet, INCONDITIONNEL : toutes les paires (methode,
        # forme) de l'appel doivent etre declarees (ou derogees). Necessaire
        # quand methode ET chemin d'un meme appel sont pilotes par le meme
        # conditionnel Jinja (ex. apim_selfservice_app/tasks/backend.yml avant
        # sa scission en deux taches a methode fixe, tache 3 lot 1 bis) : le
        # linter ne peut pas savoir, depuis le YAML, quelle branche du
        # conditionnel methode va avec quelle branche du conditionnel chemin —
        # les deux gabarits sont evalues independamment ici. Sans ce produit
        # croise, la double couverture DES DEUX SENS (chaque forme couverte
        # par au moins une methode, chaque methode par au moins une forme)
        # est satisfaite par l'ANTI-DIAGONALE : declarer (PUT,/policyActions)
        # et (POST,/policyActions/{id}) la satisfait alors que les DEUX
        # branches reelles de l'appel (POST sans id, PUT avec id) tombent en
        # 404. Fail-closed : exiger le produit croisé (batir un appariement
        # suppose serait une heuristique fausse un jour, en silence).
        #
        # Aucune condition sur le nombre de methodes/formes : quand un seul
        # axe varie (ou aucun), le produit croisé se reduit deja exactement
        # a l'ancienne double couverture (avec un seul element d'un cote, les
        # deux quantificateurs existentiels d'origine degenerent en un seul
        # quantificateur universel sur l'autre cote) — un branchement dessus
        # n'aurait change aucun verdict, seulement ajoute un chemin mort.
        couverture_ok = all(couverte(m, f) for m in a["methodes"] for f in formes)
        if not couverture_ok:
            manquants.append(("/".join(a["methodes"]), sorted(formes)[0], a["ou"], a["nom"]))
            continue
        if a["multipart"]:
            declare = next(((f, m) for f in formes for m in a["methodes"] if (m, f) in declarees), None)
            if declare is None:
                continue  # couvert uniquement par une derogation : rien a verifier au contrat
            forme, meth = declare
            op = doc["paths"][forme][meth.lower()]
            rb = op.get("requestBody", {})
            ref = rb.get("$ref", "")
            if ref.startswith("#/"):
                cible = doc
                for seg in ref[2:].split("/"):
                    cible = cible.get(seg, {})
                rb = cible
            if "multipart/form-data" not in (rb.get("content") or {}):
                sans_multipart.append((meth, forme, a["ou"], a["nom"]))

    ko = 0
    if DEROGATIONS:
        print(f"ℹ {len(DEROGATIONS)} derogation(s) assumee(s) :")
        for (m, c, ou), motif in sorted(DEROGATIONS.items()):
            print(f"    {m:6} {c}\n           {ou}\n           {motif}")
    if yaml_errors:
        # Deja imprime plus haut (la cause, avant le symptome eventuel) :
        # ici, seul l'effet sur le code de sortie reste a acter.
        ko = 1
    deletes = deletes_au_contrat(declarees)
    if deletes:
        ko = 1
        print(f"✗ {len(deletes)} DELETE DECLARE(S) AU CONTRAT — ADR-075 n'en admet aucun :")
        for m, c in deletes:
            print(f"    {m:6} {c}\n           le rollback est un re-apply depuis Git, jamais une "
                  f"suppression : retirer du contrat, ou l'assumer en derogation motivee.")
    if manquants:
        ko = 1
        print(f"✗ {len(manquants)} appel(s) NON DECLARE(S) — 404 a travers le proxy :")
        for m, c, ou, nom in sorted(set(manquants)):
            print(f"    {m:6} {c}\n           {ou} — {nom}")
    if sans_multipart:
        ko = 1
        print(f"✗ {len(sans_multipart)} appel(s) en form-multipart sans requestBody multipart declare :")
        for m, c, ou, nom in sorted(set(sans_multipart)):
            print(f"    {m:6} {c}\n           {ou} — {nom}")
    if suspects:
        ko = 1
        print(f"✗ {len(suspects)} appel(s) SUSPECT(S) — mention de {BASE_VAR} jamais ignoree "
              f"(le linter ne prefere jamais le silence au doute) :")
        for ou, nom, motif in sorted(set(suspects)):
            print(f"    {ou} — {nom}\n           {motif}")
    if not ko:
        print(f"✓ les {len(trouves)} appels des roles ({fichiers_vus} fichiers parcourus) sont "
              f"couverts par le contrat ({len(declarees)} operations declarees, aucun DELETE)")
    return ko


if __name__ == "__main__":
    sys.exit(main())
