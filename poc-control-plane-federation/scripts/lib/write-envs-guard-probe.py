#!/usr/bin/env python3
"""Sonde de GARDE sur le vault.yml du role apim_team_onboard (jalon G4, epreuve ⑦ter).

Meme motif que import-guard-probe.py, et pour la meme raison : un grep dit qu'un
assert EXISTE, jamais qu'il est au bon ENDROIT. Un `assert` sur
`apim_onb_write_envs` place APRES la tache qui pose la policy ne protege plus
rien — la policy est deja partie chez Vault quand le refus tombe. Les deux
formes sont indiscernables au grep ; on lit donc les indices de taches.

Sortie : W=<that de l'assert>\x1f<tache policy trouvee ? 0|1>\x1f<l'assert precede ? 0|1>

Le separateur est \x1f (unit separator), PAS '|' : le champ `that:` porte
lui-meme des filtres Jinja (`| default([]) | length > 0`) — un separateur '|'
collisionnerait avec le contenu qu'il est cense delimiter.
"""
import os
import sys

import yaml

doc = yaml.safe_load(open(os.environ["VY"])) or []

tasks = []


def walk(items):
    for t in items or []:
        if isinstance(t, dict):
            tasks.append(t)
            walk(t.get("block"))


walk(doc)

# L'assert qui borne la liste des paliers d'ecriture.
i_assert, that_assert = -1, ""
for i, t in enumerate(tasks):
    a = t.get("ansible.builtin.assert") or {}
    if "apim_onb_write_envs" in str(a.get("that") or ""):
        i_assert, that_assert = i, str(a.get("that"))
        break

# La tache qui POSE la policy : un uri dont le body porte le champ `policy`.
# Reperee par sa STRUCTURE, jamais par son nom (un nom est cosmetique, cf. le
# commentaire de vault.yml sur la correction inter-taches).
i_policy = -1
for i, t in enumerate(tasks):
    u = t.get("ansible.builtin.uri") or {}
    if isinstance(u.get("body"), dict) and "policy" in u["body"]:
        i_policy = i
        break

has_policy = "1" if i_policy >= 0 else "0"
before = "1" if (i_assert >= 0 and i_policy >= 0 and i_assert < i_policy) else "0"

sys.stdout.write("W=%s\x1f%s\x1f%s\n" % (that_assert, has_policy, before))
