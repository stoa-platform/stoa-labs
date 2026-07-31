"""Rendus de la carto.

Deux rendus coexistent, pour deux besoins qui ne se remplacent pas :

- `index.html` — la vue interactive (tri, filtre, fiches, graphe),
  AUTOPORTANTE : `carto.render` (voir `page.py`) embarque les deux documents
  dans le fichier, plus aucun `fetch`, un seul fichier qui s'ouvre en
  double-cliquant. Necessaire pour la publication dans le depot git dedie —
  une forge affiche l'HTML comme du code source, et un navigateur interdit
  `fetch()` en `file://`, meme quand les fichiers sont cote a cote — et donc
  utilisee aussi pour le deploiement local (le role Ansible rend le gabarit
  avant de l'installer dans `carto_web_root`, il ne le copie plus tel quel).
- `markdown.py` — les pages Markdown publiees dans le meme depot dedie.
  Elles ne demandent RIEN non plus : la forge les rend, et le `git diff`
  d'un jour a l'autre devient le rapport de changement de la plateforme.

Le second existe parce que, chez le client, il n'y a pas de serveur web — il y
a git. Voir `carto/render/markdown.py` pour la contrainte qui gouverne tout ce
rendu-la : un diff qui est du bruit detruit l'interet de la demarche. Voir
`carto/render/page.py` pour l'assemblage de la page autoportante et le piege
d'echappement qu'il faut y traiter.
"""
