#!/usr/bin/env python3
"""E1 / D2 — la contre-épreuve : un push publie, un manifeste cross-team rougit.

C'est la seule mesure qui dit si l'AUTORITÉ est au bon endroit. Le job porte
désormais TEAM='banking-demo' dans un script que l'équipe ne peut pas modifier ;
si un manifeste réclamant `team: insurance-demo` fait quand même passer le
build, c'est que la garde raisonne encore sur une donnée que l'équipe écrit.
"""
import base64
import http.cookiejar
import json
import sys
import time
import urllib.error
import urllib.request

GITEA = "http://10.43.60.211:3000"
JENKINS = "http://10.43.103.207:8080"
OWNER, REPO, JOB = "banking-demo", "accounts-api", "publish-accounts"
PATH = "stoa-publish.ansible.yml"

with open("/root/gitea-ci-pass") as fh:
    GAUTH = "Basic " + base64.b64encode(f"ci:{fh.read().strip()}".encode()).decode()

_JAR = http.cookiejar.CookieJar()
_OP = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(_JAR))


def http_(url, method="GET", data=None, headers=None, ctype=None):
    req = urllib.request.Request(url, method=method, data=data)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    if ctype:
        req.add_header("Content-Type", ctype)
    try:
        with _OP.open(req, timeout=60) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def gitea(path, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    return http_(f"{GITEA}/api/v1{path}", method, data,
                 {"Authorization": GAUTH, "Accept": "application/json"},
                 "application/json; charset=utf-8" if data else None)


BASE = """---
# banking-demo/accounts-api — manifeste de publication (rôle apim_publish_api).
# La team est posée par le JOB, qui appartient à la plateforme : ce fichier vit
# dans le dépôt de l'équipe, donc il ne peut pas faire autorité sur son propre
# cloisonnement. Y déclarer une team différente fait ÉCHOUER le build.
apim_api:
  name: "accounts-read"
  version: "1.0.0"
  contract: "{{ lookup('env', 'WORKSPACE') }}/apis/accounts-read.openapi.yaml"
"""
CROSS = BASE.rstrip("\n") + '\n  team: "insurance-demo"\n'


def last_build_number():
    st, b = http_(f"{JENKINS}/job/{JOB}/api/json?tree=builds[number]")
    if st != 200:
        return None
    d = json.loads(b)
    nums = [x["number"] for x in d.get("builds") or []]
    return max(nums) if nums else 0


def put_manifest(content, msg):
    st, b = gitea(f"/repos/{OWNER}/{REPO}/contents/{PATH}")
    sha = json.loads(b)["sha"] if st == 200 else None
    payload = {"content": base64.b64encode(content.encode()).decode(), "message": msg}
    if sha:
        payload["sha"] = sha
        return gitea(f"/repos/{OWNER}/{REPO}/contents/{PATH}", "PUT", payload)
    return gitea(f"/repos/{OWNER}/{REPO}/contents/{PATH}", "POST", payload)


def wait_build(after, timeout=1500):
    """Attend qu'un build > `after` apparaisse ET se termine."""
    t0 = time.time()
    num = None
    while time.time() - t0 < timeout:
        n = last_build_number()
        if n and n > after:
            num = n
            break
        time.sleep(10)
    if not num:
        return None, None, "aucun build déclenché"
    while time.time() - t0 < timeout:
        st, b = http_(f"{JENKINS}/job/{JOB}/{num}/api/json?tree=result,building")
        if st == 200:
            d = json.loads(b)
            if not d.get("building") and d.get("result"):
                return num, d["result"], None
        time.sleep(10)
    return num, None, "build encore en cours au bout du délai"


def log_tail(num, pattern, n=4):
    st, b = http_(f"{JENKINS}/job/{JOB}/{num}/consoleText")
    if st != 200:
        return []
    txt = b.decode("utf-8", "replace")
    return [l.strip()[:220] for l in txt.splitlines() if pattern in l][-n:]


def main():
    print("=== A. push LÉGITIME : le manifeste sans team ===")
    before = last_build_number()
    st, b = put_manifest(BASE, "test(E1): push legitime — la chaine doit publier")
    print(f"   commit -> HTTP {st}, dernier build avant = {before}")
    num, res, err = wait_build(before)
    print(f"   build #{num} -> {res}  {err or ''}")
    for l in log_tail(num, "TEAM_CONFIRMED") + log_tail(num, "PUBLISH_CONFIRMED"):
        print("    ", l)

    print()
    print("=== B. push CROSS-TEAM : le manifeste réclame insurance-demo ===")
    before = last_build_number()
    st, b = put_manifest(CROSS, "test(E1): manifeste cross-team — le build doit rougir")
    print(f"   commit -> HTTP {st}, dernier build avant = {before}")
    num2, res2, err2 = wait_build(before)
    print(f"   build #{num2} -> {res2}  {err2 or ''}")
    for l in log_tail(num2, "TEAM_FORBIDDEN"):
        print("    ", l)

    print()
    print("=== C. remise en état : manifeste légitime ===")
    before = last_build_number()
    st, b = put_manifest(BASE, "chore(E1): retour au manifeste legitime")
    num3, res3, err3 = wait_build(before)
    print(f"   build #{num3} -> {res3}  {err3 or ''}")

    print()
    ok = (res == "SUCCESS" and res2 == "FAILURE" and res3 == "SUCCESS")
    print("=== VERDICT :", "AUTORITÉ AU BON ENDROIT" if ok else "À REGARDER", "===")
    print(f"    légitime={res}  cross-team={res2}  remise={res3}")
    return 0 if ok else 1


sys.exit(main())
