"""Rendus de la carto.

Deux rendus coexistent, pour deux besoins qui ne se remplacent pas :

- `index.html` — la vue interactive autonome (tri, filtre, fiches, graphe).
  Elle demande un serveur web, ne serait-ce qu'un `python3 -m http.server`.
- `markdown.py` — les pages Markdown publiees dans un depot git dedie.
  Elles ne demandent RIEN : la forge les rend, et le `git diff` d'un jour a
  l'autre devient le rapport de changement de la plateforme.

Le second existe parce que, chez le client, il n'y a pas de serveur web — il y
a git. Voir `carto/render/markdown.py` pour la contrainte qui gouverne tout ce
rendu-la : un diff qui est du bruit detruit l'interet de la demarche.
"""
