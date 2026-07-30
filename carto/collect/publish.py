"""publish.py — ecriture atomique et validee (spec D8).

Regle unique de ce module : NE JAMAIS ECRASER UNE BONNE CARTO PAR UNE MAUVAISE.
Une montee de version du Gateway qui casse un champ doit laisser en place la
derniere carto valide, pas publier du vide qui aura l'air frais.

Sequence : valider -> ecrire un temporaire -> os.replace (atomique sur POSIX).
"""
import json
import os
import pathlib

from .model import validate_carto, validate_history


class RefusedPublication(Exception):
    """La collecte est degradee : on garde la publication precedente."""


def _write_atomic(path, payload):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, path)


def publish(dest_dir, carto, history):
    errs = validate_carto(carto) + validate_history(history)
    if errs:
        raise RefusedPublication(
            "publication refusee, la carto precedente est conservee :\n  - "
            + "\n  - ".join(errs))
    dest = pathlib.Path(dest_dir)
    dest.mkdir(parents=True, exist_ok=True)
    _write_atomic(dest / "carto.json", carto)
    _write_atomic(dest / "history.json", history)
