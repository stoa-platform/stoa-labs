"""Collecteur de la carto. LECTURE SEULE sur la production.

Config (env) :
  WM_ADMIN_URL   base admin REST du Gateway
  WM_USER/WM_PASS  compte technique LECTURE SEULE
  WM_ES_URL      base de l'API Data Store
  WM_ES_INDEX    index des evenements transactionnels

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
import urllib.request

from . import analytics, build, gateway, history, publish

WINDOWS = {"d7": 7, "d30": 30, "d90": 90}


def _es_search(base, index, body):
    # POST sur /_search : verbe impose par l'API de recherche Elasticsearch,
    # meme si l'operation est une lecture. Ne pas transformer en GET.
    req = urllib.request.Request(f"{base.rstrip('/')}/{index}/_search",
                                 data=json.dumps(body).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read().decode())


def _from_fixtures(d):
    d = pathlib.Path(d)
    raw = json.loads((d / "aggregation-d90.json").read_text())
    return (json.loads((d / "apis.json").read_text()),
            json.loads((d / "applications.json").read_text()),
            {w: raw for w in WINDOWS},
            json.loads((d / "oldest-event.json").read_text()))


def _from_gateway(env):
    gw = gateway.Gateway(env["WM_ADMIN_URL"], env["WM_USER"], env["WM_PASS"])
    observed = {w: _es_search(env["WM_ES_URL"], env["WM_ES_INDEX"],
                             analytics.aggregation_query(days))
                for w, days in WINDOWS.items()}
    oldest = _es_search(env["WM_ES_URL"], env["WM_ES_INDEX"], analytics.oldest_query())
    return gw.apis(), gw.applications(), observed, oldest


def main(argv=None):
    p = argparse.ArgumentParser(description="Collecte de la carto API / consommateurs")
    p.add_argument("--out", required=True, help="repertoire de publication")
    p.add_argument("--dry-run", action="store_true", help="ne publie rien, rapporte les compteurs")
    p.add_argument("--from-fixtures", help="lit des fixtures au lieu de la production")
    p.add_argument("--days", type=int, default=90, help="fenetre demandee (defaut 90)")
    args = p.parse_args(argv)

    if args.from_fixtures:
        raw_apis, raw_apps, raw_obs, raw_oldest = _from_fixtures(args.from_fixtures)
    else:
        need = ("WM_ADMIN_URL", "WM_USER", "WM_PASS", "WM_ES_URL", "WM_ES_INDEX")
        missing = [k for k in need if not os.environ.get(k)]
        if missing:
            print("variables d'environnement manquantes : " + ", ".join(missing), file=sys.stderr)
            return 2
        raw_apis, raw_apps, raw_obs, raw_oldest = _from_gateway(os.environ)

    now = dt.datetime.now(dt.timezone.utc)
    doc = build.build_carto(
        gateway.normalize_apis(raw_apis),
        gateway.normalize_consumers(raw_apps),
        gateway.declared_edges(raw_apps),
        {w: analytics.parse_aggregation(raw) for w, raw in raw_obs.items()},
        analytics.covered_window(raw_oldest, args.days, now),
        now.isoformat().replace("+00:00", "Z"),
    )
    row = history.counters(doc)

    print(f"apis={row['apis']} consommateurs={row['consumersRegistered']} "
          f"actifs={row['consumersActive']} aretes={len(doc['edges'])} "
          f"fenetre_couverte={doc['window']['coveredDays']}j")

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
