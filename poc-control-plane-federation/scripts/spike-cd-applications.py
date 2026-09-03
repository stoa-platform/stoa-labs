#!/usr/bin/env python3
"""spike-cd-applications.py — les DEUX spikes préalables du GOAL CD des
applications (GOAL-cd-applications-2026-09-02.md, § « PAS tranché »), joués
contre la wM 10.15 RÉELLE avec des assets JETABLES (spikecd-*), nettoyés en
sortie. Aucune API ni application existante n'est touchée.

  S1 — effet EN VOL d'une convergence d'application (PUT /applications/{id},
       PUT policyAction IAM, PUT policy) sur du trafic identifié par cette
       application ; + fenêtre fantôme au RETRAIT de la souscription, et
       latence de propagation au RÉ-ENREGISTREMENT (trou n°3 du GOAL).
  S2 — ce que fait la gateway quand une application souscrit à une API
       ABSENTE (UUID inexistant) ou INACTIVE, et ce que fait le moteur de
       convergence dans ces deux cas (trou n°2 du GOAL, porte A5).

  GW_ADMIN=http://localhost:5555/rest/apigateway GW_DATA=http://localhost:5555/gateway \
  WM_USER=Administrator WM_PASS=manage python3 scripts/spike-cd-applications.py

Sortie : lignes ✅/❌ + un bloc MESURES ; code retour = nombre de ❌.
Ce script est une PREUVE de spike, pas un livrable : il mesure, il ne pose rien.
"""
import base64, json, os, subprocess, sys, threading, time, uuid, urllib.error, urllib.request

GW   = os.environ.get("GW_ADMIN", "http://localhost:5555/rest/apigateway")
DP   = os.environ.get("GW_DATA",  "http://localhost:5555/gateway")
AUTH = base64.b64encode(f"{os.environ.get('WM_USER','Administrator')}:{os.environ.get('WM_PASS','manage')}".encode()).decode()
API, API_INACTIVE, APP = "spikecd-api", "spikecd-inactive", "spikecd-app"
PASS = FAIL = 0
MES = []   # mesures (label, valeur)

def ok(m):  global PASS; PASS += 1; print(f"  ✅ {m}")
def ko(m):  global FAIL; FAIL += 1; print(f"  ❌ {m}")
def check(label, cond, detail=""):
    (ok if cond else ko)(label + (f" — {detail}" if detail and not cond else ""))
    return cond
def say(m): print(f"\n== {m} ==")
def mes(label, v): MES.append((label, v)); print(f"  📏 {label}: {v}")

def adm(method, path, body=None, raw=None, ctype="application/json"):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(GW + path, data=data, method=method)
    req.add_header("Authorization", "Basic " + AUTH); req.add_header("Accept", "application/json")
    if data is not None: req.add_header("Content-Type", ctype)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            txt = r.read().decode(); return r.status, (json.loads(txt) if txt.strip() else {})
    except urllib.error.HTTPError as e:
        txt = e.read().decode()
        try: return e.code, json.loads(txt)
        except Exception: return e.code, {"raw": txt[:300]}

def multipart(path, fields, filename, content, fctype):
    b = "----spikecd" + uuid.uuid4().hex
    parts = []
    for k, v in fields.items():
        parts.append(f"--{b}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n")
    body = "".join(parts).encode() + (f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{filename}\"\r\n"
            f"Content-Type: {fctype}\r\n\r\n").encode() + content.encode() + f"\r\n--{b}--\r\n".encode()
    return adm("POST", path, raw=body, ctype=f"multipart/form-data; boundary={b}")

def hit(api, key=None, timeout=5):
    req = urllib.request.Request(f"{DP}/{api}/1.0.0/ping")
    if key: req.add_header("x-Gateway-APIKey", key)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r: return r.status
    except urllib.error.HTTPError as e: return e.code
    except Exception: return 0

def load(api, key, seconds, threads=4):
    """Trafic parallèle ; renvoie [(t_fin_requete, code)]."""
    log, end = [], time.time() + seconds
    def worker():
        while time.time() < end:
            c = hit(api, key); log.append((time.time(), c))
    ts = [threading.Thread(target=worker) for _ in range(threads)]
    for t in ts: t.start()
    return ts, log

def timed(fn):
    t0 = time.time(); r = fn(); return t0, time.time(), r

def app_get(app_id):
    _, r = adm("GET", f"/applications/{app_id}"); return r.get("applications", [r])[0] if "applications" in r else r
def app_key(app_id):
    return (app_get(app_id).get("accessTokens") or {}).get("apiAccessKey_credentials", {}).get("apiAccessKey")
def app_apis(app_id):
    _, r = adm("GET", f"/applications/{app_id}/apis")
    return [a.get("id") or a.get("api", {}).get("id") for a in (r.get("apis") or r.get("apiResponse") or [])], r

def create_api(name, activate=True):
    spec = (f"openapi: 3.0.0\ninfo: {{ title: {name}, version: 1.0.0 }}\n"
            f"servers: [ {{ url: \"http://poc-token-echo:8080\" }} ]\n"
            f"paths: {{ /ping: {{ get: {{ operationId: ping, responses: {{ '200': {{ description: ok }} }} }} }} }}\n")
    c, r = multipart("/apis", {"type": "openapi", "apiName": name, "apiVersion": "1.0.0"}, "c.yaml", spec, "application/x-yaml")
    aid = (r.get("apiResponse") or {}).get("api", {}).get("id")
    if aid and activate: adm("PUT", f"/apis/{aid}/activate")
    return aid, c, r

def attach_iam(api_id, api_name, id_types):
    """Même forme que apply-selfservice-application.py §3/§5 : IAM AND(types) strict, en tête de policy."""
    _, r = adm("GET", f"/apis/{api_id}"); pol_id = r["apiResponse"]["api"]["policies"][0]
    _, r = adm("GET", f"/policies/{pol_id}"); pol = r.get("policy", r)
    rules = [{"templateKey": "IdentificationRule", "parameters": [
                {"templateKey": "applicationLookup", "values": ["strict"]},
                {"templateKey": "identificationType", "values": [t]}]} for t in id_types]
    iam = {"policyAction": {"names": [{"value": f"identify ({api_name})", "locale": "en"}], "templateKey": "evaluatePolicy",
           "parameters": [{"templateKey": "logicalConnector", "values": ["AND"]},
                          {"templateKey": "allowAnonymous", "values": ["false"]}, *rules], "active": True}}
    iam_id = None
    for s in pol.get("policyEnforcements", []):
        if s.get("stageKey") == "IAM":
            for e in s.get("enforcements", []): iam_id = e.get("enforcementObjectId")
    if iam_id:
        iam["policyAction"]["id"] = iam_id; adm("PUT", f"/policyActions/{iam_id}", iam)
    else:
        _, rr = adm("POST", "/policyActions", iam); iam_id = (rr.get("policyAction") or {}).get("id") or rr.get("id")
    stages = [s for s in (pol.get("policyEnforcements") or []) if s.get("stageKey") != "IAM"]
    stages.insert(0, {"stageKey": "IAM", "enforcements": [{"enforcementObjectId": iam_id, "order": None}]})
    pol["policyEnforcements"] = stages
    c, _ = adm("PUT", f"/policies/{pol_id}", {"policy": pol})
    return iam_id, pol_id, c

CREATED = {"apis": [], "apps": [], "actions": []}
def cleanup():
    say("cleanup (assets jetables)")
    for a in CREATED["apps"]: adm("DELETE", f"/applications/{a}")
    for a in CREATED["apis"]: adm("PUT", f"/apis/{a}/deactivate"); adm("DELETE", f"/apis/{a}")
    _, r = adm("GET", "/policyActions")
    for pa in (r.get("policyAction") or r.get("policyActions") or []):
        n = " ".join(x.get("value", "") for x in (pa.get("names") or []))
        if "spikecd" in n: adm("DELETE", f"/policyActions/{pa['id']}")
    for f in ("/tmp/spikecd-nope.json", "/tmp/spikecd-inactive.json"):
        try: os.remove(f)
        except OSError: pass

def window(log, t0, t1): return [c for (t, c) in log if t0 <= t < t1]
def after(log, t):       return [(tt, c) for (tt, c) in log if tt >= t]

def main():
    # ── SETUP ────────────────────────────────────────────────────────────────
    say("setup : API jetable (active) + application + clé + IAM apiKey strict")
    api_id, c, r = create_api(API)
    if not check(f"API {API} créée+active ({api_id})", bool(api_id), str(r)[:200]): return
    CREATED["apis"].append(api_id)
    c, r = adm("POST", "/applications", {"name": APP, "description": "spike CD applications (jetable)", "contactEmails": []})
    app_id = (r.get("applications") or [r])[0].get("id") if "applications" in r else r.get("id")
    if not check(f"application {APP} créée ({app_id})", bool(app_id), str(r)[:200]): return
    CREATED["apps"].append(app_id)
    c, r = adm("PUT", f"/applications/{app_id}/apis", {"apiIDs": [api_id]})
    check("souscription app→API (PUT /applications/{id}/apis)", c == 200, f"{c} {str(r)[:150]}")
    key = app_key(app_id); check("clé API lue (apiAccessKey)", bool(key))
    iam_id, pol_id, c = attach_iam(api_id, API, ["apiKey"])
    check("IAM AND(apiKey) strict attachée en tête de policy", c == 200 and bool(iam_id), str(c))
    time.sleep(2)
    check("baseline : avec clé → 200", hit(API, key) == 200, str(hit(API, key)))
    check("baseline : sans clé → refus (identification réellement opposée)", hit(API) in (401, 403), str(hit(API)))

    # ── S1-T1 : convergence complète EN VOL ─────────────────────────────────
    say("S1-T1 : trafic 4 voies pendant la convergence (PUT app ×2, PUT IAM, PUT policy)")
    ts, log = load(API, key, 14)
    time.sleep(3)
    a = app_get(app_id); a["description"] = "spike — PUT n°1"; a["identifiers"] = [
        {"key": "ipAddressRange", "name": "ip-allowlist", "value": ["10.0.0.1-10.0.0.9"]}]
    p1 = timed(lambda: adm("PUT", f"/applications/{app_id}", a))
    time.sleep(2)
    a = app_get(app_id); a["description"] = "spike — PUT n°2"; a["identifiers"] = []
    p2 = timed(lambda: adm("PUT", f"/applications/{app_id}", a))
    time.sleep(2)
    p3 = timed(lambda: attach_iam(api_id, API, ["apiKey"]))   # PUT policyAction + PUT policy, contenu identique
    for t in ts: t.join()
    tot = len(log); bad = [c for (_, c) in log if c != 200]
    mes("S1-T1 requêtes totales / non-200", f"{tot} / {len(bad)} {sorted(set(bad)) if bad else ''}")
    for lbl, (t0, t1, r) in (("PUT app n°1", p1), ("PUT app n°2", p2), ("PUT IAM+policy", p3)):
        w = window(log, t0 - 0.2, t1 + 1.0)
        mes(f"  fenêtre {lbl} ({(t1-t0)*1000:.0f} ms admin)", f"{len(w)} req, non-200={[c for c in w if c != 200]}")
    check("S1-T1 zéro non-200 pendant la convergence", tot > 50 and not bad, f"{len(bad)}/{tot}")
    check("S1-T1 PUT app acceptés (200)", p1[2][0] == 200 and p2[2][0] == 200, f"{p1[2][0]}/{p2[2][0]}")
    a = app_get(app_id)
    check("S1-T1 read-back : même GUID d'application, même clé", a.get("id") == app_id and app_key(app_id) == key)
    check("S1-T1 read-back : identifiers = dernier PUT (vides)", not a.get("identifiers"))

    # ── S1-T2/T3 : RÉVOCATION sous trafic — fenêtre fantôme, puis latence de restauration ──
    # Passe 1 (2026-09-02) : `PUT …/apis {"apiIDs": []}` est REFUSÉ (HTTP 500) — pas une
    # primitive de retrait. Passe 2 : DELETE …/apis?apiIDs= rend 204 (pas 200) ; la
    # ré-inscription IMMÉDIATE après rend 500 (errorDetails null) puis 200 après ~2 s.
    # D'où l'ordre ici : suspension D'ABORD (app saine, inscrite), désinscription ENSUITE,
    # ré-inscription à retries chronométrés.
    def suspend(flag):
        a = app_get(app_id); a["isSuspended"] = flag; return adm("PUT", f"/applications/{app_id}", a)
    def unregister(): return adm("DELETE", f"/applications/{app_id}/apis?apiIDs={api_id}")
    def reregister_retry():
        t0 = time.time(); tries = []
        for _ in range(12):
            c, r = adm("PUT", f"/applications/{app_id}/apis", {"apiIDs": [api_id]}); tries.append(c)
            if c == 200: break
            time.sleep(1)
        return c, {"tries": tries, "delay_ms": int((time.time() - t0) * 1000)}

    def revocation(label, revoke, restore, ok_codes, expect_restore=True):
        say(f"S1-T2 [{label}] : révocation sous trafic — 200 fantômes APRÈS la révocation ?")
        check(f"S1-T2 [{label}] préalable : l'app sert (200)", hit(API, key) == 200, str(hit(API, key)))
        ts, log = load(API, key, 10); time.sleep(3)
        t0, t1, (c, r) = timed(revoke)
        for t in ts: t.join()
        aft = after(log, t1); ghosts = [(tt, cc) for (tt, cc) in aft if cc == 200]
        last_ghost = (max(tt for tt, _ in ghosts) - t1) * 1000 if ghosts else 0
        mes(f"S1-T2 [{label}] admin", f"HTTP {c}, {(t1-t0)*1000:.0f} ms")
        mes(f"S1-T2 [{label}] après", f"{len(aft)} req, 200 fantômes={len(ghosts)}, dernier à +{last_ghost:.0f} ms, codes={sorted(set(cc for _, cc in aft))}")
        check(f"S1-T2 [{label}] primitive acceptée ({ok_codes})", c in ok_codes, str(c))
        check(f"S1-T2 [{label}] effective (au moins un refus après)", any(cc != 200 for _, cc in aft))
        check(f"S1-T2 [{label}] aucun 200 fantôme > 1 s", last_ghost <= 1000, f"+{last_ghost:.0f} ms")
        say(f"S1-T3 [{label}] : restauration sous trafic — refus tardifs APRÈS la restauration ?")
        ts, log = load(API, key, 12); time.sleep(3)
        t0, t1, (c, r) = timed(restore)
        for t in ts: t.join()
        aft = after(log, t1); late = [(tt, cc) for (tt, cc) in aft if cc != 200]
        last_late = (max(tt for tt, _ in late) - t1) * 1000 if late else 0
        mes(f"S1-T3 [{label}] admin", f"HTTP {c}, {(t1-t0)*1000:.0f} ms, {json.dumps(r)[:100]}")
        mes(f"S1-T3 [{label}] après", f"{len(aft)} req, refus tardifs={len(late)}, dernier à +{last_late:.0f} ms")
        if expect_restore:
            check(f"S1-T3 [{label}] restauration acceptée (200)", c == 200, str(c))
            check(f"S1-T3 [{label}] effective (au moins un 200 après)", any(cc == 200 for _, cc in aft))
            check(f"S1-T3 [{label}] aucun refus > 1 s après la restauration", last_late <= 1000, f"+{last_late:.0f} ms")
        else:
            # FAIT 10.15 MESURÉ (sondes P3/P3b/P3c/P4, 2026-09-02) : une paire app/API qui a SERVI
            # du trafic puis a été désinscrite ne se ré-inscrit plus (500, errorDetails null,
            # 150 s, ni PUT ni POST ni PUT-remplacement, trafic post-retrait sans effet) ; l'API
            # accepte une NOUVELLE app, l'app une NOUVELLE API ; sans trafic préalable → 200.
            # Une seule fois (S1-T4, ~45 s et ~1300 refus plus tard) la paire s'est ré-inscrite :
            # non déterministe vu de l'opérateur ⇒ la chaîne ne doit JAMAIS désinscrire.
            check(f"S1-T3 [{label}] FAIT : ré-inscription REFUSÉE après trafic (500) — la paire est brûlée", c == 500, str(c))
            mes(f"S1-T3 [{label}] VERDICT", "ré-inscription NON DÉTERMINISTE après désinscription d'une app qui a servi : 500 ici ×12 ; jamais en 150 s sans trafic (P3) ; redevenue possible une fois après ~45 s et ~1300 refus (S1-T4) — à traiter comme IRRÉVERSIBLE par l'opérateur")
        check(f"S1-T3 [{label}] read-back : même GUID, même clé", app_get(app_id).get("id") == app_id and app_key(app_id) == key)

    revocation("suspension isSuspended", lambda: suspend(True), lambda: suspend(False), (200,))
    revocation("désinscription DELETE …/apis", unregister, reregister_retry, (204,), expect_restore=False)

    # ── S1-T4 : sémantique de PUT /applications/{id}/apis — REMPLACE ou AJOUTE ? ──
    say("S1-T4 : PUT …/apis avec une AUTRE API — la première souscription survit-elle ?")
    other_id, c, r = create_api("spikecd-other")
    if check(f"API spikecd-other créée ({other_id})", bool(other_id)):
        CREATED["apis"].append(other_id)
        adm("PUT", f"/applications/{app_id}/apis", {"apiIDs": [api_id]})
        c, r = adm("PUT", f"/applications/{app_id}/apis", {"apiIDs": [other_id]})
        ids, _ = app_apis(app_id)
        mes("S1-T4 après PUT [other] seul", f"HTTP {c}, souscriptions={ids}")
        mes("S1-T4 VERDICT", "PUT REMPLACE la liste (la première souscription est perdue)" if api_id not in ids else "PUT AJOUTE (la première souscription survit)")
        c, _ = adm("PUT", f"/applications/{app_id}/apis", {"apiIDs": [api_id]}); time.sleep(2)
        mes("S1-T4 retour PUT [api du spike] sur la paire brûlée", f"HTTP {c}, souscriptions={app_apis(app_id)[0]}")

    # ── S2-T1 : souscription à une API ABSENTE ───────────────────────────────
    say("S2-T1 : PUT /applications/{id}/apis avec un UUID inexistant")
    fake = str(uuid.uuid4())
    c, r = adm("PUT", f"/applications/{app_id}/apis", {"apiIDs": [fake]})
    mes("S2-T1 réponse", f"HTTP {c} {json.dumps(r)[:200]}")
    ids, raw = app_apis(app_id)
    mes("S2-T1 souscriptions lues après", f"{ids}")
    check("S2-T1 refus REST propre (4xx) OU UUID absent de la relecture (pas de fantôme)", c >= 400 or fake not in ids, f"{c}, fantôme={fake in ids}")
    check("S2-T1 aucune souscription fantôme écrite", fake not in ids)

    # ── S2-T2 : souscription à une API INACTIVE ──────────────────────────────
    say("S2-T2 : API créée NON activée — souscription, trafic, puis activation")
    ina_id, c, r = create_api(API_INACTIVE, activate=False)
    if check(f"API {API_INACTIVE} créée inactive ({ina_id})", bool(ina_id), str(r)[:150]):
        CREATED["apis"].append(ina_id)
        _, r = adm("GET", f"/apis/{ina_id}"); check("S2-T2 isActive=false confirmé", r["apiResponse"]["api"].get("isActive") is False)
        c, r = adm("PUT", f"/applications/{app_id}/apis", {"apiIDs": [ina_id]})
        ids, _ = app_apis(app_id)
        mes("S2-T2 souscription à l'inactive", f"HTTP {c}, présente en relecture={ina_id in ids}")
        attach_iam(ina_id, API_INACTIVE, ["apiKey"]); time.sleep(1)
        h = hit(API_INACTIVE, key); mes("S2-T2 trafic vers l'API inactive (avec clé)", f"HTTP {h}")
        check("S2-T2 une API inactive ne sert rien (≠200)", h != 200, str(h))
        adm("PUT", f"/apis/{ina_id}/activate"); time.sleep(2)
        h = hit(API_INACTIVE, key); mes("S2-T2 trafic après activation", f"HTTP {h}")
        ids, _ = app_apis(app_id)
        check("S2-T2 la souscription posée sur l'inactive survit à l'activation et sert", h == 200 and ina_id in ids, f"{h}, {ina_id in ids}")
        # Les deux verdicts qui comptent pour A5 : la gateway ACCEPTE-t-elle la souscription à une API inactive ?
        mes("S2-T2 VERDICT gateway", "accepte la souscription à une API inactive" if ina_id in ids else "refuse la souscription à une API inactive")

    # ── S2-T3 : le moteur de convergence face aux deux cas ───────────────────
    say("S2-T3 : apply-selfservice-application.py — API absente / API inactive (par nom)")
    eng = os.path.join(os.path.dirname(os.path.abspath(__file__)), "apply-selfservice-application.py")
    env = dict(os.environ, WM_ADMIN_URL=GW, WM_USER=os.environ.get("WM_USER", "Administrator"), WM_PASS=os.environ.get("WM_PASS", "manage"))
    json.dump({"name": APP, "api": "spikecd-nope", "api_version": "1.0.0"}, open("/tmp/spikecd-nope.json", "w"))
    p = subprocess.run([sys.executable, eng, "/tmp/spikecd-nope.json"], env=env, capture_output=True, text=True, timeout=120)
    mes("S2-T3 API absente → rc", f"{p.returncode} | {p.stdout.strip().splitlines()[-1][:120] if p.stdout.strip() else p.stderr[:120]}")
    check("S2-T3 moteur : API absente ⇒ échec fermé (rc≠0)", p.returncode != 0)
    if ina_id:
        adm("PUT", f"/apis/{ina_id}/deactivate"); time.sleep(1)
        json.dump({"name": APP, "api": API_INACTIVE, "api_version": "1.0.0"}, open("/tmp/spikecd-inactive.json", "w"))
        p = subprocess.run([sys.executable, eng, "/tmp/spikecd-inactive.json"], env=env, capture_output=True, text=True, timeout=120)
        mes("S2-T3 API inactive → rc", f"{p.returncode} | {p.stdout.strip().splitlines()[-1][:120] if p.stdout.strip() else p.stderr[:120]}")
        mes("S2-T3 VERDICT moteur", "ACCEPTE une API inactive (rc=0) — RÉGRESSION de la porte A5" if p.returncode == 0 else "refuse une API inactive (porte A5, 2026-09-03)")
        check("S2-T3 moteur : API inactive ⇒ refus fermé API_INACTIVE (porte A5, 2026-09-03)", p.returncode != 0 and "REFUS: API_INACTIVE" in p.stdout)
        # Fait de code, pas de run : depuis A5 la résolution est nom + version + isActive.
        src = open(eng, encoding="utf-8").read()
        check("S2-T3 (lecture) la résolution du moteur compare nom + version + isActive (porte A5)",
              'is not True' in src and "API_VERSION_MISMATCH" in src and "API_NOT_PROMOTED" in src)

    print("\n== MESURES ==")
    for l, v in MES: print(f"  {l}: {v}")
    print(f"\nRésultat : {PASS} ✅ / {FAIL} ❌")

if __name__ == "__main__":
    try: main()
    finally: cleanup()
    sys.exit(FAIL)
