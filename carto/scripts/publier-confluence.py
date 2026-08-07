#!/usr/bin/env python3
"""Publication de la carto dans un espace CONFLUENCE.

Troisieme voie de publication du produit, a cote de l'archive de build et du
depot git dedie (`publier-markdown.sh`). Elle ne remplace NI l'une NI l'autre :
le depot git reste la source de verite et le porteur de l'historique — c'est
son `git diff` qui repond a « qu'est-ce qui a bouge cette semaine ». Confluence
est un MIROIR RENDU, pour la population qui ne va pas dans une forge.

Stdlib seule, comme tout le paquet `carto/` : `urllib` et rien d'autre. Aucune
dependance a installer sur l'agent de CI, aucun binaire tiers.

─────────────────────────────────────────────────────────────────────────────
POURQUOI CE SCRIPT EXISTE PLUTOT QU'UN OUTIL DU MARCHE
─────────────────────────────────────────────────────────────────────────────
`mark`, `md2cf` et leurs equivalents font tres bien ce travail. Ils sont
ecartes pour une raison unique et non negociable : `carto/` est en STDLIB
SEULE, et c'est ce qui lui permet de tourner sur un agent nu, sans `pip`, sans
registre interne, sans revue de dependance. Ajouter un binaire Go ou un paquet
PyPI a la chaine ferait perdre cette propriete pour une conversion dont le
domaine, ici, est ferme et connu (cf. l'en-tete de `carto/render/confluence.py`).

─────────────────────────────────────────────────────────────────────────────
LES DEUX CONFLUENCE, ET POURQUOI LES DEUX SONT SUPPORTES
─────────────────────────────────────────────────────────────────────────────
Confluence existe en deux produits dont les API ne sont pas les memes :

  Cloud (`*.atlassian.net`)  API v2  `/wiki/api/v2/pages`
                             auth    Basic — courriel + jeton d'API
  Data Center (auto-heberge) API v1  `/rest/api/content`
                             auth    Bearer — jeton d'acces personnel (PAT)

Le labo eprouve la chaine sur du Cloud (plan gratuit, immediat) ; la cible
banque est du Data Center. N'implementer que la premiere reviendrait a eprouver
un chemin que le client n'executera jamais — l'erreur que
`ci/Jenkinsfile.carto` refuse explicitement de commettre pour Vault. Les deux
voies sont donc ecrites, et le choix est AUTOMATIQUE d'apres l'URL, avec
`--api` pour forcer.

UNE EXCEPTION A CONNAITRE : les PIECES JOINTES passent par l'API v1 SUR LES
DEUX PRODUITS. L'API v2 du Cloud n'expose pas de televersement ; Atlassian y
renvoie encore vers `/wiki/rest/api/content/{id}/child/attachment`. Ce n'est
pas un oubli de ce script, c'est l'etat du contrat.

─────────────────────────────────────────────────────────────────────────────
GESTE EXPLOITANT — LE COMPTE ET SON JETON (a poser AVANT le premier passage)
─────────────────────────────────────────────────────────────────────────────
Ce script n'ecrit AUCUN identifiant, n'en devine aucun, n'en a aucun en dur. Il
lit des variables d'environnement et s'arrete en les NOMMANT si elles manquent.

  CONFLUENCE_BASE_URL   Cloud : https://<site>.atlassian.net/wiki
                        DC    : https://confluence.interne  (sans /wiki)
  CONFLUENCE_SPACE_KEY  la cle de l'espace (pas son nom, pas son URL)
  CONFLUENCE_USER       Cloud : le COURRIEL du compte. DC : laisser vide.
  CONFLUENCE_TOKEN      le jeton. JAMAIS un mot de passe personnel.

  CONFLUENCE_PARENT_ID     (facultatif) page sous laquelle greffer la carto
  CONFLUENCE_TITLE_PREFIX  (facultatif) prefixe des quatre titres
  CONFLUENCE_CA_FILE       (facultatif) autorites de certification a employer

CONFLUENCE_CA_FILE N'EST PAS UN CONTOURNEMENT, c'est le reglage normal en
entreprise, et il suit la convention deja posee par LABCTL_CA_FILE et
VAULT_CACERT ailleurs dans le produit. Deux situations le rendent necessaire :

  - un Confluence Data Center dont le certificat est signe par l'autorite
    INTERNE de la banque, absente de tout magasin public ;
  - une inspection TLS d'entreprise, qui re-signe tout le trafic sortant.

Ce script ne desactive JAMAIS la verification du certificat, et n'expose aucune
option pour le faire. Publier une carto ne justifie pas d'ouvrir un canal non
authentifie vers un service qui porte des identifiants — et une option
« --insecure » posee « juste pour essayer » est ce qui finit en production.

CE QU'IL FAUT POSER, ET SOUS QUELLE IDENTITE :
  1. Creer un compte de SERVICE (jamais le compte d'une personne : un depart ne
     doit pas arreter la publication).
  2. Lui donner le droit d'ECRITURE sur le SEUL espace de la carto. Aucun droit
     ailleurs, et surtout pas administrateur : ce script cree et met a jour
     quatre pages, il n'a rien d'autre a faire.
  3. Generer son jeton :
       Cloud : https://id.atlassian.com/manage-profile/security/api-tokens
       DC    : Profil -> Personal Access Tokens -> Create token
  4. Poser les variables ci-dessus dans l'ordonnanceur (credential Jenkins,
     jamais un fichier du depot).

─────────────────────────────────────────────────────────────────────────────
IDEMPOTENCE : LA PAGE EST MISE A JOUR, JAMAIS RECREEE
─────────────────────────────────────────────────────────────────────────────
C'est la propriete qui decide si la publication est utilisable. Une page
recreee chaque nuit changerait d'identifiant, donc d'URL : tous les liens
poses par les lecteurs mourraient, et l'historique de versions de Confluence —
qui est le `git log` du pauvre, et le seul interet de publier la meme page
plutot qu'une nouvelle — repartirait de zero.

La page est donc retrouvee PAR SON TITRE dans l'espace, puis mise a jour en
place. Le titre est la cle : c'est pourquoi il est unique et prefixe (voir
`carto/render/confluence.py`).

Confluence exige le numero de version CIBLE, soit courant + 1. Si quelqu'un a
edite la page entre la lecture et l'ecriture, l'API repond 409 et ce script le
DIT — au lieu d'ecraser silencieusement le travail de cette personne. Les pages
portent un bandeau « generees, ne pas editer » ; le 409 est ce qui rend cet
avertissement autre chose qu'un voeu.
"""

import argparse
import base64
import json
import os
import pathlib
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from carto.render import confluence as conv   # noqa: E402

TIMEOUT = 60


class Echec(Exception):
    """Erreur a rapporter a l'exploitant, deja redigee comme un geste."""


# --- transport ------------------------------------------------------------

class Client:
    """Le strict necessaire d'un client Confluence, en urllib.

    Ne journalise JAMAIS l'en-tete d'autorisation, ni le jeton, ni le corps
    d'une reponse d'authentification : un journal de build est lu par plus de
    monde qu'un magasin de secrets.
    """

    def __init__(self, base, user, token, api, ca_file=None):
        self.base = base.rstrip("/")
        self.api = api
        # Un contexte EXPLICITE, jamais le defaut implicite d'urlopen : c'est
        # ce qui permet de designer une autorite d'entreprise sans toucher au
        # magasin de la machine, et de dire clairement, dans le message
        # d'erreur, quel magasin a servi.
        self.ca_file = ca_file
        self.contexte = ssl.create_default_context(cafile=ca_file)
        if user:
            jeton = base64.b64encode(("%s:%s" % (user, token)).encode()).decode()
            self.autorisation = "Basic " + jeton
            self.mode = "Basic (courriel + jeton d'API)"
        else:
            self.autorisation = "Bearer " + token
            self.mode = "Bearer (jeton d'acces personnel)"

    def appel(self, methode, chemin, corps=None, entetes=None, brut=False):
        url = chemin if chemin.startswith("http") else self.base + chemin
        donnees = None
        h = {"Authorization": self.autorisation, "Accept": "application/json"}
        if corps is not None and not brut:
            donnees = json.dumps(corps).encode()
            h["Content-Type"] = "application/json"
        elif brut:
            donnees = corps
        h.update(entetes or {})
        requete = urllib.request.Request(url, data=donnees, headers=h, method=methode)
        try:
            with urllib.request.urlopen(requete, timeout=TIMEOUT,
                                        context=self.contexte) as r:
                charge = r.read()
                return json.loads(charge) if charge else {}
        except urllib.error.HTTPError as e:
            self._traduire(e, methode, url)
        except Exception as e:                                  # noqa: BLE001
            if "CERTIFICATE_VERIFY" in str(e):
                raise Echec(self._aide_tls(url, e)) from e
            raise Echec("%s %s : %s — %s"
                        % (methode, url, type(e).__name__, e)) from e

    def _aide_tls(self, url, e):
        """Un echec de verification TLS -> le geste, et la bonne cause.

        Ce message existe parce que l'erreur brute d'OpenSSL
        (« unable to get local issuer certificate ») est indiscernable entre
        trois causes tres differentes, dont une seule est un probleme de
        machine. La confondre avec les deux autres fait chercher au mauvais
        endroit pendant une demi-heure.
        """
        magasin = self.ca_file or ssl.get_default_verify_paths().cafile \
            or "(aucun fichier — magasin par defaut de Python, ici VIDE)"
        return (
            "TLS : le certificat de %s n'a pas pu etre VERIFIE.\n"
            "  Ce n'est pas un refus de Confluence : la connexion n'a jamais "
            "abouti. Les identifiants ne sont pas en cause.\n"
            "  Magasin d'autorites employe : %s\n\n"
            "  TROIS CAUSES, dans l'ordre de frequence :\n"
            "  1. LA MACHINE. Python n'a pas de magasin configure — frequent "
            "sur macOS avec un Python de python.org, ou `Install "
            "Certificates.command` n'a jamais ete lance. Verifier avec :\n"
            "       python3 -c \"import ssl; "
            "print(ssl.get_default_verify_paths())\"\n"
            "     Si `cafile` vaut None, c'est ca. Reparer avec le magasin de "
            "certifi :\n"
            "       export CONFLUENCE_CA_FILE=\"$(python3 -m certifi)\"\n"
            "  2. UNE AUTORITE INTERNE (Data Center signe par la banque) ou "
            "une INSPECTION TLS d'entreprise. Recuperer le fichier PEM de "
            "l'autorite aupres de l'equipe reseau et le designer :\n"
            "       export CONFLUENCE_CA_FILE=/chemin/vers/autorite.pem\n"
            "  3. UNE INTERCEPTION NON PREVUE. Si personne ne reconnait "
            "l'autorite qui signe, ne pas passer outre : c'est le seul cas ou "
            "cette erreur protege reellement.\n\n"
            "  Erreur brute : %s" % (url, magasin, e))

    def _traduire(self, e, methode, url):
        """Un code HTTP -> un geste. Un 401 nu n'a jamais repare personne."""
        detail = ""
        try:
            detail = e.read().decode("utf-8", "replace")[:600]
        except Exception:                                       # noqa: BLE001
            pass
        if e.code in (401, 403):
            raise Echec(
                "Confluence REFUSE le compte (HTTP %s) sur %s %s.\n"
                "  Les identifiants existent mais sont rejetes. Causes, dans "
                "l'ordre de frequence :\n"
                "    - le jeton a expire ou a ete revoque -> en generer un "
                "nouveau et le reporter dans l'ordonnanceur ;\n"
                "    - CONFLUENCE_USER n'est pas le COURRIEL du compte (Cloud) "
                "ou est renseigne alors que la cible est un Data Center (qui "
                "attend un Bearer sans utilisateur) ;\n"
                "    - le compte n'a pas le droit d'ECRITURE sur l'espace "
                "vise (403) : le lui donner sur ce seul espace.\n"
                "  Mode d'authentification employe : %s\n"
                "  Reponse : %s" % (e.code, methode, url, self.mode, detail))
        if e.code == 404:
            raise Echec(
                "Confluence repond 404 sur %s %s.\n"
                "  Soit l'URL de base est fausse (Cloud : elle DOIT finir par "
                "/wiki), soit l'espace ou la page n'existe pas.\n"
                "  Reponse : %s" % (methode, url, detail))
        if e.code == 409:
            raise Echec(
                "CONFLIT DE VERSION (HTTP 409) sur %s %s.\n"
                "  Quelqu'un a modifie la page entre sa lecture et son "
                "ecriture. RIEN N'A ETE ECRASE — c'est le comportement "
                "voulu.\n"
                "  Ces pages sont generees : l'edition manuelle sera de toute "
                "facon perdue a la collecte suivante. Verifier ce qu'a fait "
                "cette personne, puis relancer ce build.\n"
                "  Reponse : %s" % (methode, url, detail))
        raise Echec("HTTP %s sur %s %s.\n  Reponse : %s"
                    % (e.code, methode, url, detail))

    def get(self, chemin):
        return self.appel("GET", chemin)

    def post(self, chemin, corps):
        return self.appel("POST", chemin, corps)

    def put(self, chemin, corps):
        return self.appel("PUT", chemin, corps)


# --- les deux dialectes ---------------------------------------------------

class ApiV2:
    """Confluence Cloud. `/wiki/api/v2` — l'API que Atlassian fait vivre."""

    nom = "v2 (Cloud)"

    def __init__(self, client, espace):
        self.c = client
        self.espace = espace
        reponse = self.c.get("/api/v2/spaces?keys=%s"
                             % urllib.parse.quote(espace))
        resultats = reponse.get("results") or []
        if not resultats:
            raise Echec(
                "Espace « %s » introuvable.\n"
                "  ATTENTION : c'est la CLE de l'espace qui est attendue, pas "
                "son nom ni son URL. On la lit dans Espace -> Parametres, ou "
                "dans l'URL entre /spaces/ et le nom de la page.\n"
                "  Verifier aussi que le compte de service a le droit de VOIR "
                "cet espace : un espace invisible est indiscernable d'un "
                "espace absent." % espace)
        self.espace_id = resultats[0]["id"]

    def trouver(self, titre):
        reponse = self.c.get("/api/v2/pages?space-id=%s&title=%s&status=current"
                             % (self.espace_id, urllib.parse.quote(titre)))
        for page in reponse.get("results") or []:
            if page.get("title") == titre:
                return {"id": page["id"], "version": page["version"]["number"]}
        return None

    def creer(self, titre, storage, parent):
        corps = {"spaceId": self.espace_id, "status": "current", "title": titre,
                 "body": {"representation": "storage", "value": storage}}
        if parent:
            corps["parentId"] = str(parent)
        return self.c.post("/api/v2/pages", corps)["id"]

    def maj(self, ident, version, titre, storage, message):
        self.c.put("/api/v2/pages/%s" % ident,
                   {"id": str(ident), "status": "current", "title": titre,
                    "body": {"representation": "storage", "value": storage},
                    "version": {"number": version + 1, "message": message}})
        return ident


class ApiV1:
    """Confluence Data Center. `/rest/api/content` — la cible banque."""

    nom = "v1 (Data Center / Server)"

    def __init__(self, client, espace):
        self.c = client
        self.espace = espace

    def trouver(self, titre):
        reponse = self.c.get(
            "/rest/api/content?spaceKey=%s&title=%s&status=current&expand=version"
            % (urllib.parse.quote(self.espace), urllib.parse.quote(titre)))
        for page in reponse.get("results") or []:
            if page.get("title") == titre:
                return {"id": page["id"], "version": page["version"]["number"]}
        return None

    def creer(self, titre, storage, parent):
        corps = {"type": "page", "title": titre, "space": {"key": self.espace},
                 "body": {"storage": {"value": storage,
                                      "representation": "storage"}}}
        if parent:
            corps["ancestors"] = [{"id": str(parent)}]
        return self.c.post("/rest/api/content", corps)["id"]

    def maj(self, ident, version, titre, storage, message):
        self.c.put("/rest/api/content/%s" % ident,
                   {"id": str(ident), "type": "page", "title": titre,
                    "space": {"key": self.espace},
                    "body": {"storage": {"value": storage,
                                         "representation": "storage"}},
                    "version": {"number": version + 1, "message": message}})
        return ident


# --- pieces jointes (API v1 sur les DEUX produits, voir l'en-tete) --------

# Le Cloud sert lui aussi l'API v1, sous /wiki — deja porte par
# CONFLUENCE_BASE_URL. Le chemin est donc le meme sur les deux produits.
PREFIXE_V1 = "/rest/api"


def _corps_multipart(nom, contenu, commentaire):
    """Un corps multipart/form-data, a la main : `urllib` n'en fabrique pas."""
    frontiere = "----carto%s" % uuid.uuid4().hex
    lignes = []

    def champ(entete, valeur):
        lignes.append(("--%s\r\n%s\r\n\r\n" % (frontiere, entete)).encode())
        lignes.append(valeur if isinstance(valeur, bytes) else valeur.encode())
        lignes.append(b"\r\n")

    champ('Content-Disposition: form-data; name="file"; filename="%s"\r\n'
          'Content-Type: application/octet-stream' % nom, contenu)
    champ('Content-Disposition: form-data; name="comment"', commentaire)
    champ('Content-Disposition: form-data; name="minorEdit"', "true")
    lignes.append(("--%s--\r\n" % frontiere).encode())
    return b"".join(lignes), frontiere


def attacher(client, page_id, chemin, commentaire):
    """Attache (ou met a jour) un fichier. Retourne 'cree' ou 'mis a jour'.

    Le branchement est necessaire : POST sur `/child/attachment` CREE, et
    refuse un nom deja pris. Sans la recherche prealable, la publication
    marcherait le premier soir et echouerait tous les suivants — le pire des
    calendriers pour decouvrir un defaut.
    """
    api = PREFIXE_V1
    nom = chemin.name
    contenu = chemin.read_bytes()
    entetes = {"X-Atlassian-Token": "no-check"}

    existant = client.get("%s/content/%s/child/attachment?filename=%s"
                          % (api, page_id, urllib.parse.quote(nom)))
    resultats = existant.get("results") or []

    if resultats:
        corps, frontiere = _corps_multipart(nom, contenu, commentaire)
        entetes["Content-Type"] = "multipart/form-data; boundary=%s" % frontiere
        client.appel("POST", "%s/content/%s/child/attachment/%s/data"
                      % (api, page_id, resultats[0]["id"]),
                      corps=corps, entetes=entetes, brut=True)
        return "mis a jour"

    corps, frontiere = _corps_multipart(nom, contenu, commentaire)
    entetes["Content-Type"] = "multipart/form-data; boundary=%s" % frontiere
    client.appel("POST", "%s/content/%s/child/attachment" % (api, page_id),
                  corps=corps, entetes=entetes, brut=True)
    return "cree"


# --- orchestration --------------------------------------------------------

def _exiger(nom, valeur, aide):
    if not valeur:
        raise Echec("Variable d'environnement %s absente.\n  %s\n"
                    "  Geste exploitant complet en tete de "
                    "carto/scripts/publier-confluence.py." % (nom, aide))
    return valeur


def publier(source, prefixe, api_demandee, dry_run):
    source = pathlib.Path(source)
    if not source.is_dir():
        raise Echec("Repertoire source introuvable : %s\n"
                    "  Il est produit par : python3 -m carto.render "
                    "--source <sortie du collecteur> --out %s" % (source, source))

    pages_md = {}
    for nom in conv._SUFFIXES:
        fichier = source / nom
        if not fichier.exists():
            raise Echec("Page absente du rendu : %s\n"
                        "  Le rendu Markdown est incomplet — relancer "
                        "`python3 -m carto.render`." % fichier)
        pages_md[nom] = fichier.read_text(encoding="utf-8")

    titres = conv.titres(prefixe)
    storages = conv.rendre_pages(pages_md, prefixe)

    message = "carto — publication automatique"
    fichier_message = source / ".message"
    if fichier_message.exists():
        message = fichier_message.read_text(encoding="utf-8").splitlines()[0][:250]

    if dry_run:
        print("MODE --dry-run : aucune requete reseau, aucun identifiant lu.\n")
        for nom in conv._SUFFIXES:
            titre = titres[nom]
            print("=" * 78)
            print("PAGE : %s   (depuis %s)" % (titre, nom))
            print("=" * 78)
            print(storages[titre])
            print()
        print("Message de version : %s" % message)
        return 0

    base = _exiger("CONFLUENCE_BASE_URL", os.environ.get("CONFLUENCE_BASE_URL"),
                   "Cloud : https://<site>.atlassian.net/wiki (le /wiki final "
                   "n'est pas optionnel). DC : https://confluence.interne")
    espace = _exiger("CONFLUENCE_SPACE_KEY", os.environ.get("CONFLUENCE_SPACE_KEY"),
                     "La CLE de l'espace, pas son nom.")
    token = _exiger("CONFLUENCE_TOKEN", os.environ.get("CONFLUENCE_TOKEN"),
                    "Le jeton du compte de service. Jamais un mot de passe.")
    user = os.environ.get("CONFLUENCE_USER") or ""
    parent = os.environ.get("CONFLUENCE_PARENT_ID") or None
    ca_file = os.environ.get("CONFLUENCE_CA_FILE") or None

    # Detection du produit d'apres l'URL, surchargeable. Le Cloud est le seul
    # a servir l'API v2 ; tout le reste est du Data Center.
    if api_demandee == "auto":
        est_cloud = ".atlassian.net" in urllib.parse.urlparse(base).netloc
        api_demandee = "v2" if est_cloud else "v1"

    client = Client(base, user, token, api_demandee, ca_file)
    api = ApiV2(client, espace) if api_demandee == "v2" else ApiV1(client, espace)

    print("Confluence : %s" % base)
    print("  API           : %s" % api.nom)
    print("  authentif.    : %s" % client.mode)
    print("  espace        : %s" % espace)
    if ca_file:
        print("  autorites     : %s" % ca_file)
    print("  prefixe titres: %s" % prefixe)
    print()

    # La RACINE d'abord : les trois autres se greffent dessous, et les liens de
    # pieces jointes la designent. L'ordre n'est pas cosmetique.
    ordre = [conv.RACINE] + [n for n in conv._SUFFIXES if n != conv.RACINE]
    racine_id = None

    for nom in ordre:
        titre = titres[nom]
        storage = storages[titre]
        existante = api.trouver(titre)
        if existante:
            api.maj(existante["id"], existante["version"], titre, storage, message)
            ident, geste = existante["id"], "mise a jour (v%d)" % (existante["version"] + 1)
        else:
            ident = api.creer(titre, storage, racine_id if nom != conv.RACINE else parent)
            geste = "CREEE"
        if nom == conv.RACINE:
            racine_id = ident
        print("  %-14s %-46s %s" % (nom, titre, geste))

    print()
    for nom in conv.FICHIERS_DONNEES:
        chemin = source / nom
        if not chemin.exists():
            print("  piece jointe %-14s ABSENTE du rendu — ignoree" % nom)
            continue
        geste = attacher(client, racine_id, chemin, message)
        print("  piece jointe %-14s %s (%d octets)"
              % (nom, geste, chemin.stat().st_size))

    print()
    print("Carto publiee. Page racine : %s/spaces/%s" % (base, espace))
    print("L'historique de versions de Confluence donne le diff d'un jour a "
          "l'autre ; le depot git reste la source de verite.")
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(
        description="Publie la carto rendue dans un espace Confluence.")
    p.add_argument("--source", required=True,
                   help="repertoire produit par `python3 -m carto.render --out`")
    p.add_argument("--titre-prefixe",
                   default=os.environ.get("CONFLUENCE_TITLE_PREFIX")
                   or conv.PREFIXE_PAR_DEFAUT,
                   help="prefixe des quatre titres de page (defaut : %s)"
                        % conv.PREFIXE_PAR_DEFAUT)
    p.add_argument("--api", choices=("auto", "v1", "v2"), default="auto",
                   help="auto = v2 si *.atlassian.net, v1 sinon")
    p.add_argument("--dry-run", action="store_true",
                   help="affiche le format de stockage et sort. Aucun reseau, "
                        "aucun identifiant lu : utilisable sans Confluence.")
    args = p.parse_args(argv)
    try:
        return publier(args.source, args.titre_prefixe, args.api, args.dry_run)
    except Echec as e:
        print("\n" + "=" * 78, file=sys.stderr)
        print("PUBLICATION CONFLUENCE INTERROMPUE", file=sys.stderr)
        print("=" * 78, file=sys.stderr)
        print(e, file=sys.stderr)
        print("\nLa carto reste publiee dans le depot git et archivee par le "
              "build : Confluence est un miroir, sa panne ne perd rien.",
              file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
