"""Rend les pages Markdown de la carto dans un repertoire prêt a publier.

    python3 -m carto.render --source <sortie du collecteur> --out <repertoire>

Le repertoire de sortie recoit exactement ce qui sera publie dans le depot
dedie : les quatre pages Markdown, les deux documents JSON, et `index.html`
— celui-ci AUTOPORTANT (voir `carto/render/page.py`) : les deux documents
JSON y sont embarques, aucun `fetch`, un seul fichier qui s'ouvre en
double-cliquant meme publie seul dans un depot git.
Un seul repertoire, un seul contenu a comparer — le script de publication
(`carto/scripts/publier-markdown.sh`) n'a plus qu'a faire du git.

Ce module fait de l'I/O de FICHIERS et rien d'autre : aucune commande git,
aucune connaissance du depot dedie ni de ses identifiants. Les rendus
eux-memes (`carto/render/markdown.py`, `carto/render/page.py`) n'ont meme pas
d'I/O du tout, ce qui rend leur determinisme testable octet pour octet.
"""
import argparse
import json
import pathlib
import shutil
import sys

from . import markdown, page

RENDU_HTML = pathlib.Path(__file__).resolve().parent / "index.html"


def _lire(chemin, defaut=None):
    p = pathlib.Path(chemin)
    if not p.exists():
        if defaut is None:
            raise SystemExit(f"fichier introuvable : {p}")
        return defaut
    return json.loads(p.read_text(encoding="utf-8"))


def main(argv=None):
    p = argparse.ArgumentParser(description="Rendu Markdown de la carto")
    p.add_argument("--source", required=True,
                   help="repertoire contenant carto.json et history.json")
    p.add_argument("--out", required=True,
                   help="repertoire a publier (cree si absent)")
    p.add_argument("--message", action="store_true",
                   help="ecrit aussi le message de commit dans <out>/.message")
    args = p.parse_args(argv)

    src = pathlib.Path(args.source)
    carto = _lire(src / "carto.json")
    # Un journal absent est le cas NORMAL du premier passage : les pages se
    # rendent sans lui, la table d'evolution le dit elle-meme.
    history = _lire(src / "history.json", defaut=[])

    pages = markdown.render_pages(carto, history)

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for nom, texte in pages.items():
        (out / nom).write_text(texte, encoding="utf-8")
    # Les documents JSON sont recopies TELS QUELS, en plus d'etre embarques
    # dans index.html juste apres : ce sont les donnees lisibles par une
    # machine, et leur propre `git diff` reste exact quel que soit ce qui
    # change dans la mise en forme des pages. Publier ce sous-ensemble en
    # double avec la page ne casse pas la continuite de l'historique : la
    # source de verite de history.json reste le web root local du
    # collecteur (`carto/collect/publish.py`), jamais cette copie-ci.
    for nom in ("carto.json", "history.json"):
        if (src / nom).exists():
            shutil.copyfile(src / nom, out / nom)
    # La vue interactive est desormais AUTOPORTANTE (render/page.py) : ses
    # donnees sont embarquees dans le fichier lui-meme, plus aucun fetch. Elle
    # s'ouvre en double-cliquant, y compris publiee seule dans un depot git.
    gabarit = RENDU_HTML.read_text(encoding="utf-8")
    (out / "index.html").write_text(page.assembler(gabarit, carto, history),
                                    encoding="utf-8")

    if args.message:
        (out / ".message").write_text(markdown.commit_message(carto, history),
                                      encoding="utf-8")

    print("pages rendues dans %s : %s" % (out, ", ".join(markdown.PAGES)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
