#!/bin/bash
# F5 T7 — archive FROIDE des données webMethods Docker de worker-3.
# Exécuté SUR worker-3, en root, conteneurs DÉJÀ ARRÊTÉS.
#
# C'est l'UNIQUE filet : l'exploitant a choisi `stop` ET `rm` dans la même
# passe, donc le recouvrement « docker start » n'existera plus. Rien n'est
# retiré avant que la relecture sur worker-2 soit verte.
#
# Ce script ne TRANSFÈRE RIEN. Il fabrique l'archive et son empreinte sur
# place ; l'acheminement se fait par le POSTE DE CONTRÔLE (plan F5, T7 Step
# 3bis). Raison : la joignabilité TCP/22 w3→w2 est mesurée, mais
# l'AUTHENTIFICATION (clé de worker-3 autorisée sur worker-2) ne l'est pas — et
# F2 achemine déjà ses archives via le poste (« transfert WAN via le poste de
# contrôle », roles/cluster_backup/defaults/main.yml). On ne crée pas une
# relation de confiance SSH nouvelle entre deux nœuds pour une archive unique.
#
# FAITS MESURÉS le 2026-07-30 (découverte validée en lecture seule avant d'écrire
# ce script) :
#   - `wm-dev-apigateway` n'a AUCUN volume : il est sans état, tout vit dans ES
#     (cohérent avec la note F3 « gateway sans volume »). Il est quand même
#     inspecté ici : si une version future lui en donnait un, il serait pris.
#   - `wm-dev-elasticsearch` porte un seul volume nommé,
#     `webmethods-dev_es-dev-data` → /var/lib/docker/volumes/.../_data, 108 Mo.
#     Cohérent avec les 100,1 Mo mesurés côté ES (`_cat/allocation`).
#
#   scp docs/superpowers/plans/2026-07-30-f5-cold-archive.sh worker-3:/tmp/f5-arch.sh
#   ssh worker-3 'sudo bash /tmp/f5-arch.sh'
set -euo pipefail
umask 077

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="/var/tmp/wm-dev-worker3-${STAMP}.tar.gz"
CONTAINERS="wm-dev-elasticsearch wm-dev-apigateway"

# Refuser si un conteneur tourne encore : une archive « froide » prise à chaud
# serait un mensonge dans le nom du fichier.
if docker ps --filter "name=wm-dev-" --format '{{.Names}}' | grep -q .; then
  echo "REFUS : des conteneurs wm-dev-* tournent encore. Les arrêter d'abord." >&2
  docker ps --filter "name=wm-dev-" --format '  encore actif : {{.Names}}' >&2
  exit 1
fi

# Les volumes portent l'état : on archive les sources de montage plutôt que
# d'entrer dans les conteneurs (arrêtés, donc aucun `exec` possible).
# shellcheck disable=SC2086
VOLS="$(docker inspect $CONTAINERS \
  --format '{{range .Mounts}}{{.Source}}{{println}}{{end}}' | sort -u | sed '/^$/d')"

if [ -z "$VOLS" ]; then
  echo "REFUS : aucun volume trouvé sur $CONTAINERS." >&2
  echo "Ne pas retirer les conteneurs à l'aveugle — comprendre d'abord." >&2
  exit 1
fi

echo "volumes à archiver :"
echo "$VOLS" | sed 's/^/  /'
echo "taille :"
# shellcheck disable=SC2086
du -sh $VOLS 2>/dev/null | sed 's/^/  /' || true

# shellcheck disable=SC2086
tar -czf "$OUT" $VOLS
sha256sum "$OUT" | tee "${OUT}.sha256"
ls -lh "$OUT" | sed 's/^/  /'

# Relecture LOCALE avant même le transfert : une archive illisible ne doit pas
# voyager pour être découverte illisible à l'arrivée.
ENTRIES="$(tar -tzf "$OUT" | wc -l)"
echo "  entrées dans l'archive : $ENTRIES"
[ "$ENTRIES" -gt 0 ] || { echo "REFUS : archive vide." >&2; exit 1; }

# `grep -c` et NON `grep -q` : avec `set -o pipefail`, un `grep -q` sort dès la
# première correspondance, ferme le tube, `tar` reçoit SIGPIPE et sort non-zéro,
# et le pipeline entier est réputé en échec. Résultat pervers : plus l'archive
# est valide, plus vite grep trouve, et plus sûrement le contrôle échoue.
# Constaté sur la vraie archive (1995 entrées, `indices/` bien présent, refus).
# `grep -c` lit tout le flux, donc `tar` se termine normalement — comme le
# `wc -l` ci-dessus, qui pour cette raison n'avait jamais échoué.
IDX="$(tar -tzf "$OUT" | grep -ci "/indices/" || true)"
echo "  chemins d'index Elasticsearch : $IDX"
[ "${IDX:-0}" -gt 0 ] || {
  echo "REFUS : aucun chemin d'index Elasticsearch dans l'archive — ce n'est" >&2
  echo "pas la donnée qu'on croit sauvegarder." >&2
  exit 1
}

echo "ARCHIVE-PRETE $OUT"
