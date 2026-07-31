"""page.py — assemble la page HTML autoportante (carto/render/index.html).

Fonction PURE, comme markdown.render_pages : gabarit + carto.json +
history.json -> texte HTML complet. Aucune I/O ici — elle vit dans
`carto/render/__main__.py`, qui lit le gabarit et écrit le résultat.

─────────────────────────────────────────────────────────────────────────────
POURQUOI CE FICHIER EXISTE
─────────────────────────────────────────────────────────────────────────────
`carto/render/index.html` allait chercher ses données par deux `fetch()` :
correct quand un vrai serveur web sert le répertoire, MUET quand la page est
publiée dans un dépôt git et téléchargée seule — la forge affiche l'HTML comme
du code source, et un navigateur interdit `fetch()` en `file://` même quand
les fichiers sont côte à côte. Ce module embarque les DEUX documents dans le
document HTML lui-même : plus aucun `fetch`, un seul fichier qui s'ouvre en
double-cliquant.

Le gabarit ne porte qu'un marqueur HTML, `<!--CARTO_DATA-->`, remplacé ici par
deux blocs `<script type="application/json">`. Les DEUX voies de déploiement
passent par cette fonction, jamais par une copie brute du gabarit : le rôle
Ansible (`carto-collect.sh.j2`) appelle `python3 -m carto.render` avant
d'installer `index.html` dans `carto_web_root`, exactement comme pour le dépôt
git dédié plus bas dans la même enveloppe. Le gabarit committé dans le dépôt de
code, lui, n'est jamais servi tel quel — s'il l'était par erreur, `boot()`
(dans `index.html`) le dit au lieu de rester muet (voir `lireJSONEmbarque`).

─────────────────────────────────────────────────────────────────────────────
LE PIÈGE DE L'ÉCHAPPEMENT
─────────────────────────────────────────────────────────────────────────────
Un navigateur repère la fin d'un élément <script> à la première séquence
LITTÉRALE « </script », quelle que soit la syntaxe portée dedans (JS, JSON, ou
autre texte) : une valeur du document qui contiendrait cette sous-chaîne
refermerait le bloc en plein milieu, et tout ce qui suit deviendrait du HTML
interprété au lieu d'un JSON qui attend son parseur. Un nom d'API ou de
consommateur, saisi à la main côté client, peut parfaitement la porter.

Parade : chaque `<` du JSON est remplacé par son échappement Unicode
`\\u003c` avant l'injection. Un parseur JSON relit `\\u003c` exactement comme
`<` (aller-retour parfait, testé dans `carto/tests/test_page.py`), et aucune
séquence `</script` ni `<!--` ne peut plus jamais apparaître en clair dans le
texte du document — quel que soit le contenu des données collectées.
"""
import json

MARQUEUR = "<!--CARTO_DATA-->"


class GabaritInvalide(Exception):
    """Le gabarit ne porte pas le marqueur attendu, ou le porte plusieurs fois.

    Signale que `render/index.html` a changé de forme sans que ce module ait
    suivi — mieux vaut un refus franc qu'une page à moitié assemblée."""


def _json_pour_script(valeur):
    """JSON sûr à injecter tel quel dans un `<script>`.

    Voir la docstring du module pour l'échappement et pourquoi il est
    nécessaire : sans lui, une donnée arbitraire pourrait refermer le bloc.
    """
    return json.dumps(valeur, ensure_ascii=False).replace("<", "\\u003c")


def assembler(gabarit, carto, history):
    """Remplace le marqueur du gabarit par les deux documents embarqués.

    `gabarit` est le TEXTE de `render/index.html` (l'I/O de lecture est
    déléguée à l'appelant, `render/__main__.py`). Fonction pure : deux appels
    sur les mêmes entrées rendent un texte identique octet pour octet.
    """
    occurrences = gabarit.count(MARQUEUR)
    if occurrences != 1:
        raise GabaritInvalide(
            f"{MARQUEUR} attendu exactement une fois dans le gabarit, "
            f"{occurrences} trouvée(s) — render/index.html a-t-il changé de "
            "forme sans que carto/render/page.py ait suivi ?")
    bloc = (f'<script type="application/json" id="carto-data">'
            f'{_json_pour_script(carto)}</script>\n'
            f'<script type="application/json" id="carto-history">'
            f'{_json_pour_script(history or [])}</script>')
    return gabarit.replace(MARQUEUR, bloc)
