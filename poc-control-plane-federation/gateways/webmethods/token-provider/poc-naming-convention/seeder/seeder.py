"""Seeder du banc token-provider webMethods.

Genere un trafic regulier sur l'API credspoc pour que le pattern
(Invoke IS -> Custom Extension conditionnelle -> Custom HTTP Header -> store)
soit exerce en continu et observable cote gateway (events de transaction ->
StoaTraceBridge -> Tempo/OpenSearch) sans intervention sur l'IS.

Sondes :
- nominal (chaque cycle) : verifie HTTP 200 ET que le backend echo a bien recu
  un Authorization "Bearer ..." ; logge le token observe pour suivre les
  rotations de cache (un changement de token = re-fetch apres TTL).
- erreur-volontaire (1 cycle sur ERROR_PROBE_EVERY) : appelle une ressource
  inexistante pour produire un event d'erreur cote gateway et verifier que la
  chaine de debug remonte aussi les KO.

Logs en JSON-lines sur stdout -> `docker logs poc-wm-token-seeder`.
"""

import itertools
import json
import os
import time
import urllib.error
import urllib.request

GW = os.environ.get("GATEWAY_URL", "http://poc-webmethods-real:5555")
API = os.environ.get("API_PATH", "/gateway/credspoc/1.0/ping")
BAD = os.environ.get("ERROR_PROBE_PATH", "/gateway/credspoc/1.0/fail")
INTERVAL = int(os.environ.get("INTERVAL_SECONDS", "60"))
ERROR_EVERY = int(os.environ.get("ERROR_PROBE_EVERY", "5"))  # 0 = sonde erreur desactivee


def log(**fields):
    fields["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    print(json.dumps(fields, ensure_ascii=False), flush=True)


def call(path, timeout=15):
    req = urllib.request.Request(GW + path, headers={"X-Seeder": "wm-token-seeder"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return -1, f"{type(e).__name__}: {e}"


last_token = None
log(probe="demarrage", gateway=GW, api=API, interval_s=INTERVAL, error_probe_every=ERROR_EVERY)

for cycle in itertools.count(1):
    status, body = call(API)
    ok, token = False, None
    if status == 200:
        try:
            authz = json.loads(body).get("received_headers", {}).get("Authorization", "")
            if authz.startswith("Bearer ") and len(authz) > len("Bearer "):
                ok, token = True, authz[len("Bearer "):]
        except (json.JSONDecodeError, AttributeError):
            pass
    entry = {"probe": "nominal", "cycle": cycle, "status": status, "ok": ok}
    if token:
        entry["token"] = token
        entry["token_rotated"] = token != last_token
        last_token = token
    else:
        entry["detail"] = body[:300]
    log(**entry)

    if ERROR_EVERY and cycle % ERROR_EVERY == 0:
        st, detail = call(BAD)
        log(probe="erreur-volontaire", cycle=cycle, status=st,
            ok=st >= 400, detail=detail[:200])

    time.sleep(INTERVAL)
