#!/usr/bin/env python3
"""Sonde d'ORDRE sur export.yml (jalon G3, epreuve ⑭).

Un grep ne peut pas repondre a la seule question qui compte ici : le digest
est-il pris APRES la sanitisation ? Un digest des octets bruts pinnerait des
octets que personne ne deploie, et la sous-chaine cherchee serait pourtant la.
On parse donc le fichier et on rend les INDICES REELS des taches, plus le
cablage des variables, pour que le shell puisse comparer.

Sortie : E=<i_sanitize>|<i_stat>|<i_confirmed>|<chemin stat>|<source exp_sha256>|<garde 64 ? 0|1>
Un indice a -1 signale une tache introuvable.
"""
import os
import sys

import yaml

doc = yaml.safe_load(open(os.environ["EXP"])) or []

tasks = []


def walk(items):
    """Les taches reelles vivent dans le `.block` de la tache-enveloppe."""
    for t in items or []:
        if isinstance(t, dict):
            tasks.append(t)
            walk(t.get("block"))


walk(doc)
names = [str(t.get("name") or "") for t in tasks]


def idx(fragment):
    for i, n in enumerate(names):
        if fragment in n:
            return i
    return -1


stat_path, sha_fact, guard = "", "", "0"
for t in tasks:
    n = str(t.get("name") or "")
    if "sha256 de l" in n:
        stat_path = str((t.get("ansible.builtin.stat") or {}).get("path") or "")
    if "moriser le digest" in n:  # « mémoriser », sans l'accent pour la robustesse
        sha_fact = str((t.get("ansible.builtin.set_fact") or {}).get("exp_sha256") or "")
    if "digest calculable" in n:
        that = (t.get("ansible.builtin.assert") or {}).get("that") or []
        # `that:` peut etre une chaine scalaire (cas de ce fichier) ou une
        # liste de conditions ; iterer une chaine iterait ses CARACTERES un
        # par un, et aucun caractere seul ne contient jamais la sous-chaine
        # "64" -> faux negatif systematique sur une garde pourtant presente.
        if isinstance(that, str):
            that = [that]
        guard = "1" if any("64" in str(x) for x in that) else "0"

print("E=%d|%d|%d|%s|%s|%s" % (
    idx("sanitize de l"), idx("sha256 de l"), idx("archive saine"),
    stat_path, sha_fact, guard))
