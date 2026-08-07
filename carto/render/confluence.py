"""confluence.py — les pages de la carto au format de stockage Confluence.

Fonction PURE, comme `markdown.py` et `page.py` : du texte en entree, du texte
en sortie. Aucune I/O, aucun reseau, aucune horloge. C'est ce qui permet de
tester la conversion entierement hors ligne, sans instance Confluence — et donc
de la tester VRAIMENT, pas seulement le jour ou un serveur repond.

─────────────────────────────────────────────────────────────────────────────
POURQUOI CONVERTIR LE MARKDOWN, ET NON RENDRE UNE SECONDE FOIS DEPUIS LE MODELE
─────────────────────────────────────────────────────────────────────────────
Il y avait deux facons d'obtenir des pages Confluence :

  (a) un second rendu, `carto.json` -> Confluence, frere de `markdown.py` ;
  (b) une conversion, Markdown -> Confluence, en aval de `markdown.py`.

(a) aurait duplique TOUTE la prose des quatre pages — les titres, les phrases
d'explication, les avertissements de fraicheur, les libelles de colonnes. Deux
copies d'un meme texte divergent au premier correctif : c'est exactement
l'argument que `carto/scripts/publier-markdown.sh` invoque pour n'avoir qu'une
implementation de la logique de commit, et il vaut ici mot pour mot. Une carto
Confluence qui dirait une chose et la carto Git une autre serait pire que pas
de carto Confluence du tout.

(b) garde UN SEUL texte source. Le prix a payer est ce fichier : un
convertisseur Markdown. Ce prix est acceptable pour une raison precise, et
c'est elle qui rend l'exercice honnete plutot que temeraire :

  LE MARKDOWN A CONVERTIR N'EST PAS DU MARKDOWN QUELCONQUE. C'est celui que
  `markdown.py` produit, et lui seul.

Le sous-ensemble reellement emis a ete releve sur les quatre pages rendues, et
il est ferme :

  - titres `#`, `##`, `###`
  - citations `> ` (contenant elles-memes titres, listes et gras)
  - listes a puces `- `, jamais imbriquees, jamais numerotees
  - italique de LIGNE ENTIERE `*...*` (les sous-titres explicatifs)
  - gras `**...**`, code en ligne `` `...` ``
  - liens `[libelle](cible)`
  - un bloc de code cloture ``` (la liste d'adresses de `consommateurs.md`)
  - tableaux, avec alignement a droite des colonnes de nombres

Ni HTML brut, ni entites, ni listes imbriquees, ni listes numerotees, ni filet
horizontal, ni image, ni note de bas de page. Un convertisseur generaliste
serait une bibliotheque ; celui-ci est une table de correspondance.

CE QUE CA IMPLIQUE, ET IL FAUT LE DIRE : si `markdown.py` se met un jour a
emettre une construction absente de cette liste, ce fichier ne la traduira pas.
C'est pourquoi `tests/test_confluence.py` convertit les QUATRE PAGES REELLES et
verifie qu'aucune syntaxe Markdown ne survit dans la sortie : le jour ou une
construction nouvelle apparait, c'est le test qui le dit, pas un lecteur devant
une page qui affiche `**gras**` en clair.

─────────────────────────────────────────────────────────────────────────────
LE FORMAT DE STOCKAGE, ET LES TROIS ENDROITS OU IL N'EST PAS DU XHTML
─────────────────────────────────────────────────────────────────────────────
Confluence stocke ses pages en « storage format » : du XHTML bien forme, plus
quelques elements a lui dans les espaces de noms `ac:` et `ri:`. On en utilise
trois, et chacun apporte quelque chose qu'un `<div>` ne donnerait pas :

  1. la macro `info` pour le bandeau de fraicheur. Une citation `<blockquote>`
     se rend chez Confluence en un mince filet gris qu'on ne voit pas. Or ce
     bandeau porte LA phrase qui distingue une page vivante d'une page perimee
     (cf. l'encadre « LA FRAICHEUR EST UN PIEGE » de `markdown.py`). Le rendre
     discret annulerait la seule protection de la publication.
  2. `<ac:link><ri:page .../></ac:link>` pour les liens entre les quatre pages.
     Un `<a href="consommateurs.md">` serait un lien mort : dans Confluence, une
     page se designe par son TITRE, pas par un nom de fichier.
  3. `<ac:link><ri:attachment .../></ac:link>` pour `carto.json`,
     `history.json` et `index.html`. Ces trois fichiers deviennent des PIECES
     JOINTES de la page racine — c'est ce qui permet a `index.html`, qui est
     autoportant, d'etre telecharge et ouvert d'un double-clic depuis
     Confluence, exactement comme depuis la forge.

Le reste est du XHTML ordinaire.
"""

import re

# Les quatre pages, et leur titre dans l'espace Confluence.
#
# CONTRAINTE CONFLUENCE QUI GOUVERNE CETTE TABLE : un titre de page est UNIQUE
# dans un espace. « Évolution » tout court entrerait en collision avec la
# premiere page de projet venue le jour ou la carto partage un espace avec
# autre chose — et la collision ne se voit pas a l'ecriture : elle se voit
# quand la publication ecrase la page de quelqu'un d'autre, ou echoue en 400.
#
# D'ou le prefixe, applique aux quatre d'un seul geste. Il est PARAMETRABLE
# pour la meme raison qu'il existe : deux cartos (une par environnement, ou une
# par plateforme) doivent pouvoir cohabiter dans un meme espace sans se marcher
# dessus — `--titre-prefixe "Carto API (REC)"` suffit alors.
PREFIXE_PAR_DEFAUT = "Carto API"

# La racine porte le prefixe NU : c'est elle qu'on ouvre, et « Carto API » se
# lit mieux dans une arborescence que « Carto API — Accueil ».
RACINE = "README.md"

_SUFFIXES = {
    "README.md": None,                      # la racine : prefixe seul
    "consommateurs.md": "Consommateurs",
    "apis.md": "Qui consomme quoi",
    "evolution.md": "Évolution",
}

# Fichiers deposes a cote des pages par `carto/render/__main__.py`, et cites
# par le README. Ils deviennent des pieces jointes de la page racine ; tout
# lien vers l'un d'eux est traduit en lien de piece jointe.
#
# Volontairement une COPIE de `markdown.FICHIERS_DONNEES` plutot qu'un import :
# un test garde l'egalite des deux (`test_confluence.py`). L'import creerait
# une dependance de la conversion vers le rendu alors que les deux sont des
# freres, et le test dit la meme chose sans la creer.
FICHIERS_DONNEES = ("carto.json", "history.json", "index.html")


def titres(prefixe=PREFIXE_PAR_DEFAUT):
    """{nom de page Markdown: titre Confluence}. Voir PREFIXE_PAR_DEFAUT."""
    return {nom: (prefixe if suffixe is None else "%s — %s" % (prefixe, suffixe))
            for nom, suffixe in _SUFFIXES.items()}


# --- echappement ----------------------------------------------------------

def _echapper(texte):
    """Texte brut -> XHTML. Les trois seuls caracteres qui cassent le format.

    Ni les accents, ni les fleches, ni les espaces insecables ne sont touches :
    le storage format est de l'UTF-8, et les transformer en entites rendrait la
    sortie illisible en test sans rien apporter.
    """
    return texte.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _attr(texte):
    """Idem, pour une valeur d'ATTRIBUT : le guillemet en plus."""
    return _echapper(texte).replace('"', "&quot;")


# --- niveau ligne ---------------------------------------------------------

_LIEN = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")

# Gras ET italique en UN SEUL motif, l'alternative du gras en premier.
#
# Deux motifs successifs seraient un piege : passer `*...*` apres avoir consomme
# `**...**` marche, mais passer `*...*` AVANT decoupe chaque gras en deux
# italiques vides. Une alternation ordonnee rend l'erreur impossible plutot que
# de compter sur l'ordre des appels.
#
# L'italique en ligne n'est pas hypothetique : `evolution.md` ecrit « les
# consommateurs existant *aujourd'hui* » au milieu d'un paragraphe. C'est la
# SEULE occurrence des quatre pages — et c'est exactement le genre de detail
# qu'une conversion ecrite au jugé laisse passer en clair.
_EMPHASE = re.compile(r"\*\*([^*]+)\*\*|\*([^*]+)\*")

# Code en ligne, a la regle CommonMark : un delimiteur de N accents graves ne
# se ferme que sur une suite d'EXACTEMENT N accents.
#
# Cette subtilite n'est pas academique, elle est MESUREE : `evolution.md`
# contient la phrase « un bloc ` ```mermaid ` non rendu s'affiche en code brut
# illisible » — un code en ligne a UN accent qui CONTIENT une suite de trois.
# Un motif naif `` `([^`]+)` `` ferme sur le premier accent rencontre, rend un
# code vide, et laisse ``` ``mermaid ` ``` en clair au milieu de la page. C'est
# le defaut qu'a attrape la conversion des quatre pages reelles.
_CODE = re.compile(r"(`+)(.+?)(?<!`)\1(?!`)")


def _emphase(texte):
    """Gras et italique + echappement du reste. Dernier etage : plus rien."""
    out, pos = [], 0
    for m in _EMPHASE.finditer(texte):
        out.append(_echapper(texte[pos:m.start()]))
        if m.group(1) is not None:
            out.append("<strong>%s</strong>" % _echapper(m.group(1)))
        else:
            out.append("<em>%s</em>" % _echapper(m.group(2)))
        pos = m.end()
    out.append(_echapper(texte[pos:]))
    return "".join(out)


def _riche(texte):
    """Code en ligne, puis gras. Le contenu d'un `code` est LITTERAL.

    Traiter le code avant le gras est ce qui garantit que `**` a l'interieur
    d'un `code` reste affiche tel quel.
    """
    out, pos = [], 0
    for m in _CODE.finditer(texte):
        out.append(_emphase(texte[pos:m.start()]))
        contenu = m.group(2)
        # Regle CommonMark : une espace de tete ET de queue est retiree. C'est
        # elle qui permet d'ecrire un code commencant par un accent grave — et
        # c'est precisement l'usage de `evolution.md`. Sans ce retrait, le
        # rendu porterait des espaces parasites que la forge, elle, n'affiche
        # pas : les deux publications diraient la meme chose differemment.
        if len(contenu) > 1 and contenu[0] == " " and contenu[-1] == " " \
                and contenu.strip():
            contenu = contenu[1:-1]
        out.append("<code>%s</code>" % _echapper(contenu))
        pos = m.end()
    out.append(_emphase(texte[pos:]))
    return "".join(out)


def _lien(libelle, cible, tit):
    """Un lien Markdown -> la forme Confluence qui correspond a sa CIBLE.

    Trois cibles, trois formes — et c'est la seule partie de la conversion qui
    depend de la destination plutot que de la syntaxe. Le libelle, lui, passe
    par `_riche` : `[**apis.md**](apis.md)` doit rester gras, et
    ``[`carto.json`](carto.json)`` doit rester en chasse fixe.
    """
    corps = _riche(libelle)
    if cible in tit:
        return ('<ac:link><ri:page ri:content-title="%s" />'
                '<ac:link-body>%s</ac:link-body></ac:link>'
                % (_attr(tit[cible]), corps))
    if cible in FICHIERS_DONNEES:
        # `ri:page` IMBRIQUE, et pas un `ri:attachment` nu. Un lien de piece
        # jointe sans page designee vise la piece jointe de LA PAGE COURANTE.
        # Les trois fichiers ne sont attaches qu'a la RACINE (les attacher aux
        # quatre pages recopierait `index.html` quatre fois a chaque collecte),
        # donc un lien nu depuis une page fille serait mort. Aujourd'hui seul
        # le README les cite et la question ne se pose pas — la designer
        # explicitement fait que ca restera vrai si une autre page s'y met.
        return ('<ac:link><ri:attachment ri:filename="%s">'
                '<ri:page ri:content-title="%s" /></ri:attachment>'
                '<ac:link-body>%s</ac:link-body></ac:link>'
                % (_attr(cible), _attr(tit[RACINE]), corps))
    return '<a href="%s">%s</a>' % (_attr(cible), corps)


def _inline(texte, tit):
    """Toute la mise en forme en ligne d'un fragment.

    Les LIENS sont traites en premier, et ce n'est pas un detail : le libelle
    d'un lien peut contenir du code (``[`carto.json`](carto.json)``). Decouper
    sur le code d'abord couperait le lien en deux et le laisserait en clair.
    """
    out, pos = [], 0
    for m in _LIEN.finditer(texte):
        out.append(_riche(texte[pos:m.start()]))
        out.append(_lien(m.group(1), m.group(2), tit))
        pos = m.end()
    out.append(_riche(texte[pos:]))
    return "".join(out)


# --- niveau bloc ----------------------------------------------------------

_TITRE = re.compile(r"(#{1,6}) (.*)")
_ITALIQUE = re.compile(r"\*([^*].*[^*])\*")


def _cellules(ligne):
    """Les cellules d'une ligne de tableau Markdown, sans les barres."""
    return [c.strip() for c in ligne.strip().strip("|").split("|")]


def _tableau(lignes, tit):
    """Un tableau Markdown -> tableau Confluence, ALIGNEMENTS COMPRIS.

    L'alignement n'est pas cosmetique ici : `markdown.py` aligne a droite
    toutes les colonnes de nombres, et c'est ce qui rend une colonne de volumes
    comparable d'une ligne a l'autre. Le perdre a la conversion donnerait un
    tableau techniquement juste et pratiquement illisible.
    """
    rangees = [_cellules(l) for l in lignes]
    entete, spec, corps = rangees[0], rangees[1], rangees[2:]
    droite = [c.endswith(":") for c in spec]

    def cell(balise, contenu, i):
        style = ' style="text-align: right;"' if i < len(droite) and droite[i] else ""
        return "<%s%s>%s</%s>" % (balise, style, _inline(contenu, tit), balise)

    out = ["<table><tbody><tr>"]
    out += [cell("th", c, i) for i, c in enumerate(entete)]
    out.append("</tr>")
    for rangee in corps:
        out.append("<tr>")
        out += [cell("td", c, i) for i, c in enumerate(rangee)]
        out.append("</tr>")
    out.append("</tbody></table>")
    return "".join(out)


def _macro_info(contenu_storage):
    """Le bandeau de fraicheur. Voir le point 1 de l'en-tete du fichier."""
    return ('<ac:structured-macro ac:name="info" ac:schema-version="1">'
            '<ac:rich-text-body>%s</ac:rich-text-body>'
            '</ac:structured-macro>' % contenu_storage)


def _macro_code(texte):
    """Bloc de code cloture. CDATA : le contenu est litteral, pas du XHTML."""
    return ('<ac:structured-macro ac:name="code" ac:schema-version="1">'
            '<ac:plain-text-body><![CDATA[%s]]></ac:plain-text-body>'
            '</ac:structured-macro>' % texte)


def convertir(md, tit):
    """Markdown (sous-ensemble de `markdown.py`) -> format de stockage.

    Deterministe : deux appels sur la meme entree rendent la meme sortie octet
    pour octet, comme le rendu Markdown dont il derive. C'est ce qui permet a
    la publication de ne rien ecrire quand rien n'a bouge.
    """
    lignes = md.splitlines()
    html, i, n = [], 0, len(md.splitlines())

    while i < n:
        ligne = lignes[i]

        if not ligne.strip():
            i += 1
            continue

        # Bloc de code cloture. Teste AVANT tout le reste : son contenu ne doit
        # subir aucune regle de mise en forme.
        if ligne.startswith("```"):
            j, corps = i + 1, []
            while j < n and not lignes[j].startswith("```"):
                corps.append(lignes[j])
                j += 1
            html.append(_macro_code("\n".join(corps)))
            i = j + 1
            continue

        # Citation : on la deshabille et on la RECONVERTIT. C'est ce qui fait
        # que le titre, la liste et le gras qu'elle contient sont traites par
        # les memes regles que partout ailleurs, sans les redire ici.
        if ligne.startswith(">"):
            j, bloc = i, []
            while j < n and lignes[j].startswith(">"):
                bloc.append(lignes[j][2:] if lignes[j].startswith("> ") else "")
                j += 1
            html.append(_macro_info(convertir("\n".join(bloc), tit)))
            i = j
            continue

        if ligne.startswith("|"):
            j = i
            while j < n and lignes[j].startswith("|"):
                j += 1
            html.append(_tableau(lignes[i:j], tit))
            i = j
            continue

        if ligne.startswith("- "):
            j, items = i, []
            while j < n and lignes[j].startswith("- "):
                items.append(lignes[j][2:])
                j += 1
            html.append("<ul>%s</ul>"
                        % "".join("<li>%s</li>" % _inline(x, tit) for x in items))
            i = j
            continue

        m = _TITRE.fullmatch(ligne)
        if m:
            niveau = len(m.group(1))
            html.append("<h%d>%s</h%d>"
                        % (niveau, _inline(m.group(2), tit), niveau))
            i += 1
            continue

        # Italique de ligne entiere — les sous-titres explicatifs des blocs de
        # signaux. Le garde `**` est indispensable : une ligne entierement en
        # GRAS (« Cette date est la seule chose... ») satisfait aussi le motif
        # de l'italique, et serait rendue en italique sans lui.
        m = _ITALIQUE.fullmatch(ligne)
        if m and not ligne.startswith("**"):
            html.append("<p><em>%s</em></p>" % _inline(m.group(1), tit))
            i += 1
            continue

        html.append("<p>%s</p>" % _inline(ligne, tit))
        i += 1

    return "".join(html)


def rendre_pages(pages_markdown, prefixe=PREFIXE_PAR_DEFAUT):
    """{nom Markdown: texte} -> {titre Confluence: format de stockage}.

    LE TITRE H1 EST RETIRE de chaque page. Confluence affiche deja le titre de
    la page au-dessus du corps : le laisser produirait le titre deux fois, une
    fois en gros et une fois en tres gros. C'est le meme arbitrage que l'option
    `--drop-h1` des outils du marche, et il ne vaut que parce que le titre
    Confluence DERIVE du meme endroit (voir `_SUFFIXES`).
    """
    tit = titres(prefixe)
    out = {}
    for nom, texte in pages_markdown.items():
        if nom not in tit:
            continue
        lignes = texte.splitlines()
        if lignes and lignes[0].startswith("# "):
            texte = "\n".join(lignes[1:])
        out[tit[nom]] = convertir(texte, tit)
    return out
