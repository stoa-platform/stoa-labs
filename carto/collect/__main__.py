"""Collecteur de la carto. LECTURE SEULE sur la production.

Config (env) :
  WM_ADMIN_URL   base REST du Gateway (admin ET evenements transactionnels)
  WM_USER/WM_PASS  compte technique LECTURE SEULE

Refonte du 2026-07-31 : `WM_ES_URL` et `WM_ES_INDEX` ont disparu. Le trafic se
lit desormais par l'API PUBLIQUE de la gateway (`/transactionalEvents/_count`
et `_search`) et non plus par son Elasticsearch interne, qu'une NetworkPolicy
du cluster n'ouvre qu'aux pods de la gateway — un agent de CI ne l'atteignait
pas, ni au labo ni chez un client. Une seule base d'URL et un seul jeu
d'identifiants suffisent donc a toute la collecte.

Usage :
  python3 -m carto.collect --out /var/www/carto
  python3 -m carto.collect --out /tmp/x --dry-run
  python3 -m carto.collect --out /tmp/x --from-fixtures carto/tests/fixtures
"""
import argparse
import datetime as dt
import json
import os
import pathlib
import sys

from . import analytics, build, gateway, history, publish

# Les trois fenetres sont FIGEES, et il n'existe pas d'option pour les changer.
#
# Decision de revue (2026-07-30) : l'ancienne option `--days` n'alimentait que
# `covered_window()` et laissait les agregations sur 90 jours — un document
# portant `requestedDays: 30` decrivait donc du trafic sur 90 jours. Plutot que
# de rendre la profondeur longue configurable, on la fige :
#   1. `d90` est un NOM du contrat de donnees, lu par le rendu, l'export CSV et
#      surtout `history.json`, qui accumule `calls` d'un passage a l'autre.
#      Une profondeur configurable ferait cohabiter dans la MEME serie des
#      totaux a 30 et a 90 jours sans que rien ne le signale — le defaut que
#      ce produit combat, reintroduit ailleurs.
#   2. La profondeur qui compte n'est pas celle qu'on demande mais celle qu'on
#      a : elle reste MESUREE (`window.coveredDays`, spec D4) et affichee.
WINDOWS = {"d7": 7, "d30": 30, "d90": 90}
REQUESTED_DAYS = WINDOWS["d90"]


def windows_par_duree_croissante():
    """Les fenetres, de la plus courte a la plus longue.

    L'ordre PORTAIT, du temps de l'acces Elasticsearch, la garantie
    d7 ⊆ d30 ⊆ d90 : les trois requetes utilisaient une borne haute relative
    (`now-Nd`) reevaluee a chaque appel, donc un appel arrive PENDANT la
    sequence pouvait tomber dans une fenetre courte sans tomber dans la
    longue, et `build._check_windows` refusait alors de publier une collecte
    parfaitement saine.

    Depuis la refonte du 2026-07-31, toutes les requetes d'une collecte
    partagent la MEME borne haute figee (`analytics.window_params`) : un appel
    arrive en cours de sequence n'est vu par AUCUNE d'elles, et l'invariant
    tient par construction. L'ordre est conserve pour une raison plus modeste
    mais reelle : si la collecte est interrompue (redemarrage de gateway,
    coupure reseau), ce qui a ete obtenu est la fenetre courte, la plus utile
    au diagnostic. Ne pas s'en remettre a l'ordre d'insertion de `WINDOWS` :
    reordonner ce dictionnaire est le genre de nettoyage anodin que personne
    ne relie a un comportement de collecte.
    """
    return sorted(WINDOWS.items(), key=lambda kv: kv[1])


def _from_fixtures(d):
    """Rejoue une collecte hors ligne. Les fixtures sont capturees sur la
    vraie gateway (voir carto/scripts/capture-fixtures.sh)."""
    d = pathlib.Path(d)
    observe = json.loads((d / "observed.json").read_text())
    return (gateway.normalize_apis(json.loads((d / "apis.json").read_text())),
            gateway.normalize_consumers(json.loads((d / "applications.json").read_text())),
            gateway.declared_edges(json.loads((d / "applications.json").read_text())),
            {w: observe["observed"][w] for w in WINDOWS},
            observe["window"])


def _from_gateway(env, now):
    gw = gateway.Gateway(env["WM_ADMIN_URL"], env["WM_USER"], env["WM_PASS"])
    raw_apps = gw.applications()
    apis = gateway.normalize_apis(gw.apis())
    consumers = gateway.normalize_consumers(raw_apps)
    # `gw.get` est la SEULE I/O de la collecte du trafic : analytics ne
    # connait ni urllib ni les identifiants.
    observe, window = analytics.collect(gw.get, apis, consumers,
                                        windows_par_duree_croissante(),
                                        REQUESTED_DAYS, now)
    return apis, consumers, gateway.declared_edges(raw_apps), observe, window


def main(argv=None):
    p = argparse.ArgumentParser(description="Collecte de la carto API / consommateurs")
    p.add_argument("--out", required=True, help="repertoire de publication")
    p.add_argument("--dry-run", action="store_true", help="ne publie rien, rapporte les compteurs")
    p.add_argument("--from-fixtures", help="lit des fixtures au lieu de la production")
    args = p.parse_args(argv)

    now = dt.datetime.now(dt.timezone.utc)
    if args.from_fixtures:
        apis, consumers, declared, observed, window = _from_fixtures(args.from_fixtures)
    else:
        need = ("WM_ADMIN_URL", "WM_USER", "WM_PASS")
        missing = [k for k in need if not os.environ.get(k)]
        if missing:
            print("variables d'environnement manquantes : " + ", ".join(missing), file=sys.stderr)
            return 2
        apis, consumers, declared, observed, window = _from_gateway(os.environ, now)

    doc = build.build_carto(apis, consumers, declared, observed, window,
                            now.isoformat().replace("+00:00", "Z"))
    row = history.counters(doc)

    print(f"apis={row['apis']} consommateurs={row['consumersRegistered']} "
          f"actifs={row['consumersActive']} aretes={len(doc['edges'])} "
          f"fenetre_couverte={doc['window']['coveredDays']}j "
          f"trafic_non_identifie={round(doc['unidentifiedCallShare'] * 100, 1)}%")

    if args.dry_run:
        print("dry-run : rien n'a ete publie")
        return 0

    hist_path = pathlib.Path(args.out) / "history.json"
    rows = json.loads(hist_path.read_text()) if hist_path.exists() else []
    publish.publish(args.out, doc, history.append_history(rows, row))
    print(f"publie dans {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
