"""publish.py — ecriture atomique et validee (spec D8).

Regle unique de ce module : NE JAMAIS ECRASER UNE BONNE CARTO PAR UNE MAUVAISE.
Une montee de version du Gateway qui casse un champ doit laisser en place la
derniere carto valide, pas publier du vide qui aura l'air frais.

Sequence : valider -> ecrire les deux temporaires -> enchainer les deux
os.replace (chacun atomique sur POSIX). Aucun temporaire ne doit survivre a
un echec, a quelque etape que ce soit.
"""
import json
import os
import pathlib

from .model import validate_carto, validate_history


class RefusedPublication(Exception):
    """La collecte est degradee : on garde la publication precedente."""


def _write_tmp(path, payload):
    """Ecrit `payload` dans un fichier temporaire a cote de `path`.

    Ne bascule rien : le renommage se fait ailleurs, une fois les DEUX
    temporaires ecrits (voir publish). En cas d'echec d'ecriture, le
    temporaire est nettoye et l'exception se propage telle quelle : on
    nettoie, on ne masque jamais une erreur.
    """
    tmp = path.with_suffix(path.suffix + ".tmp")
    try:
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=1), encoding="utf-8")
    except Exception:
        tmp.unlink(missing_ok=True)
        raise
    return tmp


def publish(dest_dir, carto, history):
    """Valide, ecrit puis bascule atomiquement carto.json et history.json.

    Sequence : valider -> ecrire les DEUX temporaires -> enchainer les DEUX
    os.replace. Aucun fichier temporaire ne doit subsister, ni en cas de
    succes ni en cas d'echec (a n'importe quelle etape).
    """
    errs = validate_carto(carto) + validate_history(history)
    if errs:
        raise RefusedPublication(
            "publication refusee, la carto precedente est conservee :\n  - "
            + "\n  - ".join(errs))
    dest = pathlib.Path(dest_dir)
    dest.mkdir(parents=True, exist_ok=True)

    carto_path = dest / "carto.json"
    history_path = dest / "history.json"

    # Les deux temporaires sont ecrits avant tout renommage : si le second
    # echoue, le premier est nettoye et rien n'a encore ete bascule, donc les
    # fichiers finaux precedents restent strictement intacts.
    carto_tmp = _write_tmp(carto_path, carto)
    try:
        history_tmp = _write_tmp(history_path, history)
    except Exception:
        carto_tmp.unlink(missing_ok=True)
        raise

    # Les deux bascules s'enchainent sans I/O entre elles : c'est la fenetre
    # de defaillance la plus etroite que POSIX permette sans remplacer un
    # repertoire entier (voir revue : on resserre, on ne construit pas une
    # transaction).
    try:
        os.replace(carto_tmp, carto_path)
        os.replace(history_tmp, history_path)
    except Exception:
        for tmp in (carto_tmp, history_tmp):
            tmp.unlink(missing_ok=True)
        raise
