#!/usr/bin/env python3
"""Sonde de GARDE sur import.yml (jalon G3, epreuve ⑮).

Un grep ne peut pas repondre a la question qui compte : le refus « digest
obligatoire » est-il conditionne par l'ENVIRONNEMENT, ou par la PRESENCE de la
variable ? La seconde forme est un fail-open — oublier l'extra-var desactive le
controle — et les deux se ressemblent dans un grep. On lit donc les champs
`when:` et `that:` des asserts NOMMES.

Sortie : I=<when du refus digest>\x1f<that de la comparaison>\x1f<garde d'existence ? 0|1>\x1f<elle precede ? 0|1>

Le séparateur est \x1f (unit separator), PAS '|' : `when:` et `that:` portent
eux-mêmes des filtres Jinja (`| default('')`) — un séparateur '|' collisionnerait
avec le contenu qu'il est censé délimiter, et un split naïf côté shell tronquerait
le premier champ au premier filtre rencontré.
"""
import os
import sys

import yaml

doc = yaml.safe_load(open(os.environ["IMP"])) or []

tasks = []


def walk(items):
    for t in items or []:
        if isinstance(t, dict):
            tasks.append(t)
            walk(t.get("block"))


walk(doc)


def find(fragment):
    """La tache dont le fail_msg porte ce fragment, avec son indice."""
    for i, t in enumerate(tasks):
        a = t.get("ansible.builtin.assert") or {}
        if fragment in str(a.get("fail_msg") or ""):
            return i, t, a
    return -1, None, None


i_req, _, a_req = find("ARCHIVE_DIGEST_REQUIRED")
i_cmp, t_cmp, a_cmp = find("ARCHIVE_DIGEST_MISMATCH")
i_abs, _, _ = find("ARCHIVE_ABSENT")

when_req = str((tasks[i_req].get("when") if i_req >= 0 else "") or "")
that_cmp = str((a_cmp.get("that") if a_cmp else "") or "")
has_abs = "1" if i_abs >= 0 else "0"
before = "1" if (i_abs >= 0 and i_cmp >= 0 and i_abs < i_cmp) else "0"

print("I=%s\x1f%s\x1f%s\x1f%s" % (when_req, that_cmp, has_abs, before))
