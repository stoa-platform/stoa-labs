#!/usr/bin/env bash
# Capture des réponses réelles du Gateway en fixtures de test. LECTURE SEULE.
# Chemins mesurés à la source (Swagger d'administration livré dans le conteneur,
# packages/WmAPIGateway/resources/apigatewayservices/APIGatewayServiceManagement.json,
# APIGatewayApplication.json et APIGatewayTransactionalEvent.json) — voir
# carto/TERRAIN.md.
#
# Refonte du 2026-07-31 : plus aucun accès à l'Elasticsearch interne. Tout se
# capture par l'API PUBLIQUE de la gateway, avec les MÊMES identifiants que la
# collecte. `WM_ES_URL` et `WM_ES_INDEX` n'existent plus.
#
# Capture les QUATRE fixtures de la suite :
#   apis.json, applications.json      (inventaire)
#   transactional-events.json         (formes BRUTES des deux routes d'événements)
#   observed.json                     (sortie du collecteur : arêtes + fenêtre)
#
# Usage :
#   export WM_ADMIN_URL=... WM_USER=... WM_PASS=...
#   ./capture-fixtures.sh <destdir>
set -euo pipefail
DEST="${1:?destdir requis}"; mkdir -p "$DEST"
: "${WM_ADMIN_URL:?WM_ADMIN_URL requis}" "${WM_USER:?WM_USER requis}" "${WM_PASS:?WM_PASS requis}"

# Racine du dépôt, déduite de l'emplacement de ce script : la capture doit
# pouvoir tourner depuis n'importe quel répertoire courant.
RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Les identifiants passent par l'entrée standard de curl (`--config -`), jamais
# par `-u` : un argument de ligne de commande est lisible par n'importe qui dans
# la table des processus de la machine pendant toute la durée de l'appel.
get() {
  printf 'user = "%s:%s"\n' "$WM_USER" "$WM_PASS" \
    | curl -sS --config - -H 'Accept: application/json' "$WM_ADMIN_URL$1"
}

get /apis         > "$DEST/apis.json"
get /applications > "$DEST/applications.json"

# Formes brutes des deux routes d'événements, et sortie du collecteur. Les deux
# passent par le module lui-même : une capture écrite à la main dériverait du
# code qu'elle est censée verrouiller.
( cd "$RACINE" && python3 - "$DEST" <<'PY'
import base64, datetime as dt, json, os, sys, urllib.error, urllib.parse, urllib.request
from carto.collect import analytics as A, gateway
from carto.collect.__main__ import REQUESTED_DAYS, windows_par_duree_croissante

dest, now = sys.argv[1], dt.datetime.now(dt.timezone.utc)
gw = gateway.Gateway(os.environ["WM_ADMIN_URL"], os.environ["WM_USER"], os.environ["WM_PASS"])
apis = gateway.normalize_apis(gw.apis())
consommateurs = gateway.normalize_consumers(gw.applications())
fenetre = A.window_params(now, REQUESTED_DAYS)

def compte(**p):
    p.update(fenetre); return gw.get(A.COUNT_PATH, p)

def cherche(**p):
    p.update(fenetre); return gw.get(A.SEARCH_PATH, p)

def _refus(params):
    url = os.environ["WM_ADMIN_URL"].rstrip("/") + A.COUNT_PATH + "?" + urllib.parse.urlencode(params)
    jeton = base64.b64encode(f'{os.environ["WM_USER"]}:{os.environ["WM_PASS"]}'.encode()).decode()
    req = urllib.request.Request(url, headers={"Accept": "application/json",
                                               "Authorization": "Basic " + jeton})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as err:
        return json.loads(err.read().decode())

# Un nom d'application qui ne peut correspondre à rien : c'est ainsi qu'on
# capture le PIÈGE MAJEUR de cette API — l'absence de résultat est une CHAÎNE.
introuvable = A.escape_regex("carto-aucune-application-de-ce-nom")
brut = {
    "_meta": "À RÉÉCRIRE À LA MAIN — voir le message de fin de capture.",
    "compte_par_api": compte(apiName=A.MATCH_ALL),
    "compte_par_application": compte(applicationName=A.escape_regex(A.UNIDENTIFIED_CONSUMER_ID)),
    "compte_en_succes": compte(apiName=A.MATCH_ALL, **{A.STATUS_PARAM: A.STATUS_OK}),
    "compte_sans_resultat": compte(applicationName=introuvable),
    "sonde_du_filtre_statut": compte(apiName=A.MATCH_ALL,
                                     **{A.STATUS_PARAM: A.escape_regex(A.STATUS_SENTINELLE)}),
    "dernier_appel": cherche(apiName=A.MATCH_ALL, **{"from": 0, "size": 1}),
    "recherche_sans_resultat": cherche(apiName=introuvable, **{"from": 0, "size": 1}),
    # Un refus de la gateway : elle exige au moins un filtre en plus des dates.
    # Capturé en direct (urllib brut) parce que ce refus arrive avec un code
    # HTTP 400 et que le détail exploitable est dans le CORPS de la réponse.
    "requete_refusee": _refus(dict(fenetre)),
}
with open(os.path.join(dest, "transactional-events.json"), "w") as f:
    json.dump(brut, f, indent=1, ensure_ascii=False)

observe, couverture = A.collect(gw.get, apis, consommateurs,
                                windows_par_duree_croissante(), REQUESTED_DAYS, now)
with open(os.path.join(dest, "observed.json"), "w") as f:
    json.dump({"_meta": "À RÉÉCRIRE À LA MAIN — voir le message de fin de capture.",
               "window": couverture, "observed": observe}, f, indent=1, ensure_ascii=False)
PY
)

cat <<'FIN'
capturé — RELIRE ces fichiers et retirer toute donnée sensible avant de les
copier sur carto/tests/fixtures/.

Deux blocs `_meta` sont à RÉÉCRIRE À LA MAIN, ils sortent volontairement de
cette capture avec un texte de remplacement :

  transactional-events.json  capture brute — le `_meta` dit ce que chaque
                             entrée exerce, en particulier les deux formes
                             d'absence de résultat (une CHAÎNE pour _count,
                             une liste vide pour _search).

  observed.json              N'EST PAS une capture brute utilisable telle
                             quelle : tant que la gateway n'identifie pas
                             l'appelant (carto/TERRAIN.md V5), tout le trafic
                             sort sous le consommateur « Unknown ». Le `_meta`
                             doit distinguer ce qui est mesuré de ce qui est
                             SUBSTITUÉ, et les arêtes substituées porter la
                             clé `_substitue`. Remplacer ce bloc par une
                             capture brute ferait passer pour mesuré ce qui ne
                             l'est pas.

La question ouverte prioritaire (l'identification de l'appelant est-elle
effective chez le client ?) est à re-trancher à chaque capture : si elle l'est
enfin, la substitution devient inutile — et il faut alors le dire, pas la
reconduire par habitude.
FIN
