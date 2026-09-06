#!/usr/bin/env python3
"""spike-p0-posture.py — les QUATRE spikes du jalon P0 du GOAL « posture par
exposition » (GOAL-posture-par-exposition-2026-09-04.md, § P0), joués contre la
wM 10.15 RÉELLE avec des actifs JETABLES (spikep0-*), nettoyés en sortie.

  A — le ciblage d'une global policy PAR TAG mord-il ?
  B — quelle liste garde vraiment le port en deny-by-default ?
  C — quelle est la forme RÉELLE d'un port HTTPS, et se rejoue-t-elle ?
  D — le tag survit-il à la promotion par archive (ADR-079) et à un update ?

  GW_ADMIN=http://localhost:5555/rest/apigateway GW_DATA=http://localhost:5555/gateway \
  IS_ADMIN=http://localhost:5555/WmRoot WM_CONTAINER=poc-webmethods-real \
  WM_USER=Administrator WM_PASS=manage python3 scripts/spike-p0-posture.py [A|B|C|D|all]

Sortie : lignes ✅/❌ + un bloc VERDICTS ; code retour = nombre de ❌.
Ce script est une PREUVE de spike, PAS un livrable : il mesure, il ne pose rien
de durable. Aucun actif préexistant n'est modifié — sauf lecture.

RÈGLE DE SÉCURITÉ TENUE ICI : on ne bascule JAMAIS le mode d'accès d'un port par
lequel on est connecté (5555). Les spikes B et C n'opèrent que sur des listeners
JETABLES créés puis supprimés par ce script.
"""
import base64, json, os, subprocess, sys, time, uuid, urllib.error, urllib.request

GW   = os.environ.get("GW_ADMIN", "http://localhost:5555/rest/apigateway")
DP   = os.environ.get("GW_DATA",  "http://localhost:5555/gateway")
ISA  = os.environ.get("IS_ADMIN", "http://localhost:5555/WmRoot")
CTR  = os.environ.get("WM_CONTAINER", "poc-webmethods-real")
USER = os.environ.get("WM_USER", "Administrator")
PASS = os.environ.get("WM_PASS", "manage")
AUTH = base64.b64encode(f"{USER}:{PASS}".encode()).decode()

TAG      = "spikep0-vh"
API_TAGD = "spikep0-tagged"     # porte le tag
API_PLN  = "spikep0-plain"      # n'en porte pas
PORT_S   = 5599                 # listener HTTPS jetable (spike C)
PORT_P   = 5598                 # listener HTTP  jetable (spike B)

OK = KO = 0
VERDICTS = []

def ok(m):
    global OK; OK += 1; print(f"  ✅ {m}")
def ko(m):
    global KO; KO += 1; print(f"  ❌ {m}")
def check(label, cond, detail=""):
    (ok if cond else ko)(label + (f" — {detail}" if detail and not cond else ""))
    return bool(cond)
def say(m):  print(f"\n== {m} ==")
def mes(label, v): print(f"  📏 {label}: {v}")
def verdict(spike, texte):
    VERDICTS.append((spike, texte)); print(f"  ⚖️  {spike} : {texte}")

# ─────────────────────────────── transport ────────────────────────────────────

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
        except Exception: return e.code, {"raw": txt[:400]}
    except Exception as e:
        return 0, {"raw": str(e)[:200]}

def isadm(method, path, form=None):
    """Formulaire WmRoot (form-urlencoded, basic-auth, sans CSRF sur le trial)."""
    import urllib.parse
    data = urllib.parse.urlencode(form).encode() if form else None
    req = urllib.request.Request(ISA + path, data=data, method=method)
    req.add_header("Authorization", "Basic " + AUTH)
    if data is not None: req.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urllib.request.urlopen(req, timeout=60) as r: return r.status, r.read().decode()
    except urllib.error.HTTPError as e: return e.code, e.read().decode()[:400]
    except Exception as e: return 0, str(e)[:200]

def form_entries(listener_key):
    """Entrées de l'allow-list telles que les rend le formulaire WmRoot."""
    import re
    c, html = isadm("GET", f"/security-ports-editaccess.dsp?port={urllib.parse.quote(listener_key)}&listenerType=Regular")
    return re.findall(r'writeTD\("[a-z]*rowdata-l"\);</script>([^<]+)</TD>', html)

import urllib.parse  # noqa: E402  (utilisé par form_entries)

def multipart(path, fields, filename, content, fctype):
    b = "----spikep0" + uuid.uuid4().hex
    parts = "".join(f"--{b}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n" for k, v in fields.items())
    body = (parts.encode()
            + f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{filename}\"\r\nContent-Type: {fctype}\r\n\r\n".encode()
            + content.encode() + f"\r\n--{b}--\r\n".encode())
    return adm("POST", path, raw=body, ctype=f"multipart/form-data; boundary={b}")

def hit(name, host=None, timeout=10):
    """Appel plan de données. host=None -> DP ; sinon depuis DANS le conteneur."""
    if host is None:
        try:
            with urllib.request.urlopen(f"{DP}/{name}/1.0.0/ping", timeout=timeout) as r: return r.status
        except urllib.error.HTTPError as e: return e.code
        except Exception: return 0
    out = ctr_curl([f"{host}/gateway/{name}/1.0.0/ping"], auth=False, timeout=timeout)
    return int(out.strip() or 0)

def ctr_curl(args, auth=True, timeout=10, body=False):
    """curl DANS le conteneur wM. Basic auth par config sur STDIN, jamais en argv
    (standard du repo — cf. scripts/repair-wm-dangling-policyaction.sh)."""
    cmd = ["docker", "exec", "-i", CTR, "curl", "-sk", "-m", str(timeout)]
    cmd += [] if body else ["-o", "/dev/null", "-w", "%{http_code}"]
    if auth: cmd += ["-K", "-"]
    cmd += args
    inp = f'user = "{USER}:{PASS}"\n' if auth else ""
    return subprocess.run(cmd, input=inp, capture_output=True, text=True).stdout

def invoke(service, host, timeout=10):
    """Appel d'un service IS /invoke depuis DANS le conteneur."""
    return int(ctr_curl([f"{host}/invoke/{service}"], timeout=timeout).strip() or 0)

def wait_gateway(seconds=600):
    """Le lab recycle wM (~20 min de keepalive) : on attend une reprise."""
    for i in range(seconds // 10):
        if adm("GET", "/apis")[0] == 200: return True
        time.sleep(10)
    return adm("GET", "/apis")[0] == 200

def wait_data_plane(name, seconds=150):
    """Le plan de données SERT-il l'API fraîchement activée ?

    Une reprise du conteneur rend `/apis` 200 bien AVANT que le dispatch ne
    serve les APIs neuves (404 « Service not found ») et bien avant que
    `POST /policies` ne cesse de rendre 500. Sans cette porte, toute la suite
    rougit pour une raison qui n'est pas celle qu'on mesure.
    """
    for _ in range(seconds // 3):
        if hit(name) == 200: return True
        time.sleep(3)
    return hit(name) == 200

# ─────────────────────────────── actifs jetables ──────────────────────────────

CREATED = {"apis": [], "policies": [], "actions": [], "ports": [], "files": []}

def create_api(name, tags=None):
    tagblock = ""
    if tags:
        tagblock = "tags:\n" + "".join(f"  - name: {t}\n    description: spike P0\n" for t in tags)
    spec = ("openapi: 3.0.0\n"
            f"info: {{ title: {name}, version: 1.0.0 }}\n"
            f"{tagblock}"
            "servers: [ { url: \"http://poc-token-echo:8080\" } ]\n"
            "paths:\n  /ping:\n    get:\n      operationId: ping\n"
            "      responses: { '200': { description: ok } }\n")
    c, r = multipart("/apis", {"type": "openapi", "apiName": name, "apiVersion": "1.0.0"},
                     "c.yaml", spec, "application/x-yaml")
    aid = (r.get("apiResponse") or {}).get("api", {}).get("id")
    if aid:
        CREATED["apis"].append(aid); adm("PUT", f"/apis/{aid}/activate")
    return aid, c, r

def api_record(aid):
    _, r = adm("GET", f"/apis/{aid}")
    return (r.get("apiResponse") or {}).get("api", {})

def api_tags(aid):
    a = api_record(aid)
    return a.get("apiTags"), [t.get("name") for t in (a.get("apiDefinition", {}).get("tags") or [])]

def mk_iam_action(label):
    act = {"policyAction": {"names": [{"value": f"spikep0 {label}", "locale": "en"}],
           "templateKey": "evaluatePolicy",
           "parameters": [{"templateKey": "logicalConnector", "values": ["AND"]},
                          {"templateKey": "allowAnonymous", "values": ["false"]},
                          {"templateKey": "IdentificationRule", "parameters": [
                              {"templateKey": "applicationLookup", "values": ["strict"]},
                              {"templateKey": "identificationType", "values": ["apiKey"]}]}],
           "active": True}}
    _, r = adm("POST", "/policyActions", act)
    aid = (r.get("policyAction") or {}).get("id")
    if aid: CREATED["actions"].append(aid)
    return aid

METH_COND = {"filterType": "HTTP_METHOD", "logicalConnector": "AND",
             "attributes": [{"attributeName": m, "value": "true"}
                            for m in ("GET", "POST", "PUT", "DELETE", "PATCH", "HEAD")]}
def api_cond(attr, op, val):
    return {"filterType": "API", "logicalConnector": "AND",
            "attributes": [{"attributeName": attr, "operation": op, "value": val}]}

SYS_ACTION = "GlobalLogInvocationPolicyAction"

def mk_log_action():
    """Copie JETABLE de l'action de log du produit.

    ⚠ INCIDENT MESURÉ LE 2026-09-04 : supprimer une policy SUPPRIME EN CASCADE
    les policyActions qu'elle référence — y compris une action SYSTÈME partagée.
    Une global policy de test qui référence `GlobalLogInvocationPolicyAction`
    emporte donc, à sa suppression, l'action de la policy système « Transaction
    logging » ; toute activation d'API tombe alors en NPE (action fantôme, cf.
    scripts/repair-wm-dangling-policyaction.sh) et seul un redémarrage la
    reconstitue. On ne référence donc JAMAIS l'action du produit : on en pose
    une copie à nous, que la cascade peut emporter sans dommage.
    """
    c, r = adm("GET", f"/policyActions/{SYS_ACTION}")
    src = (r.get("policyAction") or r)
    if c != 200 or not src.get("templateKey"): return None
    cp = json.loads(json.dumps(src)); cp.pop("id", None)
    cp["names"] = [{"value": "spikep0 log", "locale": "en"}]
    _, rr = adm("POST", "/policyActions", {"policyAction": cp})
    aid = (rr.get("policyAction") or {}).get("id")
    if aid: CREATED["actions"].append(aid)
    return aid

def log_enf(action_id):
    return [{"enforcements": [{"enforcementObjectId": action_id, "order": "0"}], "stageKey": "LMT"}]

def mk_global(label, conds, enforcements, activate=True):
    body = {"policy": {"names": [{"value": f"spikep0-{label}", "locale": "en"}],
            "policyScope": "GLOBAL", "global": True, "systemPolicy": False,
            "scope": {"applicableAPITypes": ["REST", "SOAP", "ODATA"],
                      "logicalConnector": "AND", "scopeConditions": conds},
            "policyEnforcements": enforcements}}
    c, r = adm("POST", "/policies", body)
    pid = (r.get("policy") or {}).get("id")
    if pid:
        CREATED["policies"].append(pid)
        if activate: adm("PUT", f"/policies/{pid}/activate")
    return pid, c, r

def applies_to(pid, aid):
    return pid in (adm("GET", f"/apis/{aid}/globalPolicies")[1].get("globalPolicies") or [])

def inverse_probe(pid):
    r = adm("GET", f"/policies/{pid}/apis?active=true")[1]
    return [a.get("api", a).get("apiName") for a in (r.get("apiResponse") or [])]

def cleanup():
    say("ménage (actifs jetables)")
    for pid in CREATED["policies"]:
        adm("PUT", f"/policies/{pid}/deactivate")
        # On VIDE les enforcements avant de supprimer : la suppression d'une
        # policy cascade sur ses actions, et on ne veut cette cascade sur RIEN
        # d'autre que nos propres copies (cf. mk_log_action).
        _, r = adm("GET", f"/policies/{pid}")
        pol = r.get("policy") or r
        if pol.get("id"):
            pol["policyEnforcements"] = []
            adm("PUT", f"/policies/{pid}", {"policy": pol})
        adm("DELETE", f"/policies/{pid}")
    for aid in CREATED["actions"]:
        if aid and aid != SYS_ACTION: adm("DELETE", f"/policyActions/{aid}")
    for aid in CREATED["apis"]:
        adm("PUT", f"/apis/{aid}/deactivate"); adm("DELETE", f"/apis/{aid}")
    for key in CREATED["ports"]:
        adm("PUT", "/ports/disable", {"listenerKey": key}); adm("DELETE", f"/ports/{key}")
    for f in CREATED["files"]:
        try: os.remove(f)
        except OSError: pass
    print(f"  nettoyé : {len(CREATED['apis'])} APIs, {len(CREATED['policies'])} policies, "
          f"{len(CREATED['actions'])} actions, {len(CREATED['ports'])} ports")

# ═══════════════════════════════ SPIKE A ══════════════════════════════════════

def spike_a():
    say("SPIKE A — le ciblage d'une global policy par TAG mord-il ?")

    # A0 — où un tag peut-il seulement s'écrire ?
    tagd, c, _ = create_api(API_TAGD, tags=[TAG])
    pln,  _, _ = create_api(API_PLN)
    check("deux APIs jetables créées et activées", bool(tagd and pln), f"{tagd} / {pln}")
    if not check("PORTE — le plan de données SERT les deux APIs neuves",
                 wait_data_plane(API_TAGD) and wait_data_plane(API_PLN),
                 "dispatch pas prêt (reprise du conteneur ?) — rien de ce qui suit ne serait mesuré"):
        return tagd, pln
    at, dt = api_tags(tagd)
    check("A0 le tag de la SPEC atterrit dans apiDefinition.tags", dt == [TAG], f"{dt}")
    check("A0 apiTags reste VIDE malgré une spec taguée", at in (None, []), f"apiTags={at}")

    rec = api_record(tagd); rec2 = json.loads(json.dumps(rec)); rec2["apiTags"] = [TAG]
    cw, _ = adm("PUT", f"/apis/{tagd}?overwriteTags=true", rec2)
    at2, _ = api_tags(tagd)
    check("A0 PUT apiTags rend 200 mais N'ÉCRIT RIEN (no-op menteur)",
          cw == 200 and at2 in (None, []), f"HTTP {cw}, apiTags={at2}")
    mes("apiTags après quatre variantes de PUT", at2)

    # A1 — le mécanisme global et la sonde fonctionnent-ils ? (témoin positif)
    # Enforcement = copie JETABLE de l'action de log (jamais celle du produit).
    logact = mk_log_action()
    if not check("A1 copie jetable de l'action de log posée", bool(logact)): return tagd, pln
    LOG_ENF = log_enf(logact)
    pid_all, c, _ = mk_global("A1-methodes-seules", [METH_COND], LOG_ENF)
    check("A1 global policy créée + activée", bool(pid_all), f"HTTP {c}")
    time.sleep(4)
    t_all, p_all = applies_to(pid_all, tagd), applies_to(pid_all, pln)
    check("A1 TÉMOIN — un scope HTTP_METHOD seul frappe les DEUX APIs", t_all and p_all,
          f"taguée={t_all} sans-tag={p_all}")

    # A2 — filterType=API SEUL ne sélectionne rien
    pid_name_only, _, _ = mk_global("A2-nom-seul", [api_cond("API_NAME", "EQUALS", API_TAGD)], LOG_ENF)
    time.sleep(4)
    check("A2 un scope filterType=API SEUL ne sélectionne AUCUNE API",
          not applies_to(pid_name_only, tagd), "il a sélectionné l'API taguée")

    # A3 — combiné à HTTP_METHOD, le ciblage par NOM mord et discrimine
    pid_name, _, _ = mk_global("A3-methodes+nom", [METH_COND, api_cond("API_NAME", "EQUALS", API_TAGD)], LOG_ENF)
    time.sleep(4)
    t_n, p_n = applies_to(pid_name, tagd), applies_to(pid_name, pln)
    check("A3 HTTP_METHOD + API_NAME frappe la bonne API SEULEMENT", t_n and not p_n,
          f"taguée={t_n} sans-tag={p_n}")
    check("A3 sonde inverse concordante", inverse_probe(pid_name) == [API_TAGD], f"{inverse_probe(pid_name)}")

    # A4 — le même montage, par TAG : ne mord sur rien
    pid_tag, _, _ = mk_global("A4-methodes+tag", [METH_COND, api_cond("API_TAG", "EQUALS", TAG)], LOG_ENF)
    time.sleep(4)
    t_t, p_t = applies_to(pid_tag, tagd), applies_to(pid_tag, pln)
    check("A4 HTTP_METHOD + API_TAG ne frappe RIEN, tag présent compris", not t_t and not p_t,
          f"taguée={t_t} sans-tag={p_t}")
    check("A4 sonde inverse vide", inverse_probe(pid_tag) == [], f"{inverse_probe(pid_tag)}")

    # A5 — le ciblage par NOM mord-il jusqu'au PLAN DE DONNÉES ? (rayon = notre API)
    base_t, base_p = hit(API_TAGD), hit(API_PLN)
    check("A5 base de référence : les deux APIs répondent 200", base_t == 200 and base_p == 200,
          f"{base_t}/{base_p}")
    act = mk_iam_action("A5")
    pid_dp, _, _ = mk_global("A5-plan-de-donnees", [METH_COND, api_cond("API_NAME", "EQUALS", API_TAGD)],
                             [{"enforcements": [{"enforcementObjectId": act, "order": "0"}], "stageKey": "IAM"}])
    got_t = got_p = None
    for _ in range(6):
        time.sleep(3); got_t, got_p = hit(API_TAGD), hit(API_PLN)
        if got_t != 200: break
    mes("plan de données sous global policy par NOM", f"taguée={got_t} sans-tag={got_p}")
    dp_name_bites = check("A5 la policy globale par NOM REFUSE la ciblée et laisse passer l'autre",
                          got_t in (401, 403) and got_p == 200, f"taguée={got_t} sans-tag={got_p}")

    # A6 — CONTRE-ÉPREUVE : on retire le ciblage, l'appel doit repasser
    if dp_name_bites:
        adm("PUT", f"/policies/{pid_dp}/deactivate")
        back = None
        for _ in range(6):
            time.sleep(3); back = hit(API_TAGD)
            if back == 200: break
        check("A6 CONTRE-ÉPREUVE : policy désactivée → l'appel repasse en 200", back == 200, f"{back}")

    if dp_name_bites and not t_t:
        verdict("A", "ciblage par TAG RÉFUTÉ ; ciblage par NOM PROUVÉ jusqu'au plan de données, "
                     "à condition d'être combiné à une condition HTTP_METHOD")
    else:
        verdict("A", "résultat non concluant — voir les ❌ ci-dessus")
    return tagd, pln

# ═══════════════════════════════ SPIKE B ══════════════════════════════════════

def spike_b(pln):
    say("SPIKE B — quelle liste garde vraiment le port en deny ?")
    _, r = adm("GET", "/ports")
    src = [l for l in r.get("listeners", []) if l.get("port") == 5555]
    if not check("listener HTTP primaire :5555 lisible (gabarit)", bool(src)): return
    body = json.loads(json.dumps(src[0]))
    for k in ("uniqueID", "key", "listenerKey", "primary", "targets", "curDelay"): body.pop(k, None)
    body.update({"port": PORT_P, "portAlias": "spikep0Plain",
                 "portDescription": "spike P0 — port HTTP jetable", "enabled": "false"})
    c, _ = adm("POST", "/ports", body)
    KEY = f"HTTPListener@{PORT_P}"
    if check(f"B0 listener HTTP jetable :{PORT_P} créé", c in (200, 201), f"HTTP {c}"):
        CREATED["ports"].append(KEY)
    ce, _ = adm("PUT", "/ports/enable", {"listenerKey": KEY})
    check("B0 listener activé", ce == 200, f"HTTP {ce}")
    time.sleep(2)
    host = f"http://localhost:{PORT_P}"

    base_dp, base_svc = hit(API_PLN, host), invoke("wm.server:ping", host)
    check("B1 en mode ALLOW : plan de données 200 ET service IS 200",
          base_dp == 200 and base_svc == 200, f"dp={base_dp} svc={base_svc}")

    cd, _ = adm("POST", f"/ports/{KEY}/accessMode", {"accessMode": "deny"})
    mode = adm("GET", f"/ports/{KEY}/accessMode")[1]
    check("B2 POST accessMode=deny bascule RÉELLEMENT le mode (mutation)",
          cd == 200 and mode.get("accessMode") == "deny", f"HTTP {cd}, mode={mode.get('accessMode')}")
    mes("liste auto-peuplée au passage en deny", f"{len(mode.get('services') or [])} services IS")
    check("B2 la liste par défaut ne contient QUE des services IS (folder:service)",
          all(":" in s and not s.startswith("gateway") for s in (mode.get("services") or [])),
          f"{(mode.get('services') or [])[:3]}")

    deny_dp = hit(API_PLN, host)
    deny_ok = invoke("wm.server:ping", host)          # listé
    deny_no = invoke("pub.date:getCurrentDate", host)  # NON listé
    check("B3 l'ACL du port EST vivante : service listé 200, service non listé 403",
          deny_ok == 200 and deny_no == 403, f"listé={deny_ok} non-listé={deny_no}")
    dp_unguarded = check("B3 MAIS le plan de données /gateway PASSE malgré le deny",
                         deny_dp == 200, f"dp={deny_dp}")

    # B4 — les deux surfaces pilotent-elles la MÊME liste ?
    cp, _ = adm("PUT", f"/ports/{KEY}/accessMode", {"services": ["pub.date:getCurrentDate"]})
    after = adm("GET", f"/ports/{KEY}/accessMode")[1].get("services") or []
    check("B4 PUT accessMode REMPLACE la liste en bloc (aucune opération additive)",
          after == ["pub.date:getCurrentDate"], f"{len(after)} entrées restantes")
    check("B4 le formulaire WmRoot voit la liste écrite par REST",
          form_entries(KEY) == ["pub.date:getCurrentDate"], f"{form_entries(KEY)}")
    cf, _ = isadm("POST", "/security-ports-editaccess.dsp",
                  {"Action": "addNode", "port": KEY, "listenerType": "Regular",
                   "services": "wm.server:ping", "submit": "Save Additions"})
    rest_after = adm("GET", f"/ports/{KEY}/accessMode")[1].get("services") or []
    check("B4 addNode par le FORMULAIRE est ADDITIF et relu par REST",
          cf == 200 and sorted(rest_after) == ["pub.date:getCurrentDate", "wm.server:ping"],
          f"HTTP {cf}, REST voit {rest_after}")
    check("B5 l'ACL suit la nouvelle liste (mutation) : ping re-listé 200",
          invoke("wm.server:ping", host) == 200)

    if dp_unguarded:
        verdict("B", "les deux surfaces pilotent LA MÊME liste (REST en bloc, formulaire additif) — "
                     "mais cette liste ne garde QUE /invoke : le plan de données /gateway N'EST PAS gardé "
                     "par le mode d'accès du port. La prémisse de P6 tombe.")
    else:
        verdict("B", "résultat non concluant — voir les ❌ ci-dessus")

# ═══════════════════════════════ SPIKE C ══════════════════════════════════════

def spike_c():
    say("SPIKE C — la forme réelle d'un port HTTPS, et son rejeu")
    _, r = adm("GET", "/ports")
    src = [l for l in r.get("listeners", []) if l.get("port") == 5543]
    if not check("C0 listener HTTPS :5543 présent (échantillon)", bool(src)): return
    rec = src[0]
    contrat = {"accessMode", "clientAuth", "ssl", "jsseEnabledProtocols", "jsseDisabledProtocols",
               "listenerType", "protocol", "portAlias", "port"}
    hors = sorted(set(rec) - contrat)
    mes("champs du listener réel ABSENTS de la définition Port du contrat", hors)
    check("C0 le contrat publié SOUS-DÉCRIT le port (keyStore/trustStore absents du contrat)",
          "keyStore" in rec and "trustStore" in rec, f"{sorted(rec)}")
    check("C0 le port HTTPS porte son keystore par ALIAS, pas par chemin",
          isinstance(rec.get("keyStore"), str) and rec.get("keyStore"), f"{rec.get('keyStore')}")

    body = json.loads(json.dumps(rec))
    for k in ("uniqueID", "key", "listenerKey", "primary", "targets", "curDelay"): body.pop(k, None)
    body.update({"port": PORT_S, "portAlias": "spikep0Secure",
                 "portDescription": "spike P0 — port HTTPS jetable", "enabled": "false"})
    c, resp = adm("POST", "/ports", body)
    KEY = f"HTTPSListener@{PORT_S}"
    created = check("C1 la forme relue se REJOUE en création (POST /ports)", c in (200, 201), f"HTTP {c}")
    if created: CREATED["ports"].append(KEY)
    mes("quirk de réponse : le champ 'port' du POST renvoie la clé", resp.get("port"))
    ce, _ = adm("PUT", "/ports/enable", {"listenerKey": KEY})
    time.sleep(2)
    _, r2 = adm("GET", "/ports")
    new = [l for l in r2.get("listeners", []) if l.get("listenerKey") == KEY]
    check("C1 le listener créé est relu, activé, avec le bon keystore",
          bool(new) and new[0].get("enabled") == "true" and new[0].get("keyStore") == rec.get("keyStore"),
          f"{new[0] if new else 'absent'}")

    # C2 — servi ? refusé ? par qui ?
    code = hit(API_PLN, f"https://localhost:{PORT_S}")
    out = ctr_curl([f"https://localhost:{PORT_S}/gateway/{API_PLN}/1.0.0/ping"], auth=False, body=True)
    served = "Transport protocol not supported" in out
    check("C2 l'API EST bien servie sur le nouveau listener HTTPS (le dispatch la reconnaît)",
          served, f"HTTP {code} — {out[:120]}")
    check("C2 …mais REFUSÉE par son propre entryProtocolPolicy=http, pas par le port",
          served and code == 500, f"HTTP {code}")
    verdict("C", "forme réelle relevée et REJOUÉE : un port HTTPS se crée par POST /ports en recopiant "
                 "le record relu (keyStore/trustStore par alias). Le contrat publié sous-décrit l'objet. "
                 "Et l'ajout d'un listener HTTPS ne change RIEN au protocole accepté : c'est "
                 "entryProtocolPolicy, par API, qui tranche.")

# ═══════════════════════════════ SPIKE D ══════════════════════════════════════

def spike_d(tagd):
    say("SPIKE D — le tag survit-il à la promotion par archive, et à un update ?")
    at, dt = api_tags(tagd)
    if not check("D0 l'API de départ porte bien son tag", dt == [TAG], f"{dt}"):
        return
    arch = f"/tmp/spikep0-{uuid.uuid4().hex[:8]}.zip"; CREATED["files"].append(arch)
    req = urllib.request.Request(f"{GW}/archive?apis={tagd}")
    req.add_header("Authorization", "Basic " + AUTH)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            open(arch, "wb").write(r.read())
        got = os.path.getsize(arch)
    except Exception as e:
        ko(f"D1 GET /archive a échoué — {e}"); return
    check("D1 archive exportée", got > 0, f"{got} octets")

    # Le tag est-il seulement DANS les octets de l'archive ?
    import io, zipfile
    def carries_tag(blob, depth=0):
        """L'archive wM est un zip DE zips : on descend d'un niveau."""
        try: z = zipfile.ZipFile(io.BytesIO(blob))
        except Exception:
            return TAG.encode() in blob
        for n in z.namelist():
            try: sub = z.read(n)
            except Exception: continue
            if TAG.encode() in sub: return True
            if depth < 2 and n.lower().endswith(".zip") and carries_tag(sub, depth + 1): return True
        return False
    inside = carries_tag(open(arch, "rb").read())
    check("D1 le tag est PRÉSENT dans les octets de l'archive", inside,
          "absent de l'archive : il ne pourrait survivre à aucune promotion")

    # Round-trip : réimport overwrite sur la même instance
    b = "----spikep0" + uuid.uuid4().hex
    payload = (f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.zip\"\r\n"
               f"Content-Type: application/zip\r\n\r\n").encode() + open(arch, "rb").read() + f"\r\n--{b}--\r\n".encode()
    c, r = adm("POST", "/archive?overwrite=apis", raw=payload, ctype=f"multipart/form-data; boundary={b}")
    check("D2 réimport de l'archive (overwrite=apis)", c in (200, 201), f"HTTP {c} {str(r)[:160]}")
    time.sleep(3)
    at2, dt2 = api_tags(tagd)
    check("D2 le tag SURVIT à l'aller-retour d'archive", dt2 == [TAG], f"{dt2}")
    check("D2 le GUID est ISO après réimport", bool(api_record(tagd).get("id")), "GUID perdu")

    # D3 — un update de définition SANS tag efface-t-il le tag ?
    rec = api_record(tagd); rec2 = json.loads(json.dumps(rec))
    rec2["apiDefinition"].pop("tags", None)
    cu, _ = adm("PUT", f"/apis/{tagd}", rec2)
    time.sleep(2)
    _, dt3 = api_tags(tagd)
    wiped = (dt3 == [] or dt3 is None)
    check("D3 un PUT de définition SANS tags EFFACE le tag (piège de re-pose)", wiped,
          f"HTTP {cu}, tags après update = {dt3}")
    # remise en état pour rester cohérent
    rec3 = api_record(tagd); rec3["apiDefinition"]["tags"] = [{"name": TAG, "description": "spike P0"}]
    adm("PUT", f"/apis/{tagd}", rec3)
    time.sleep(1)
    _, dt4 = api_tags(tagd)
    check("D3 …et un PUT AVEC tags le repose", dt4 == [TAG], f"{dt4}")
    cot, _ = adm("PUT", f"/apis/{tagd}?overwriteTags=false", rec2)
    time.sleep(1)
    _, dt5 = api_tags(tagd)
    mes("overwriteTags=false protège-t-il le tag ?", f"tags = {dt5}")

    verdict("D", f"le tag vit dans apiDefinition.tags ; il {'SURVIT' if dt2 == [TAG] else 'NE SURVIT PAS'} "
                 f"à l'archive, et un PUT de définition sans tags l'{'EFFACE' if wiped else 'épargne'} "
                 f"⇒ re-pose et relecture obligatoires après CHAQUE mise à jour.")

# ═══════════════════════════════ main ═════════════════════════════════════════

if __name__ == "__main__":
    which = (sys.argv[1] if len(sys.argv) > 1 else "all").upper()
    say(f"P0 — spikes de posture, cible {GW} (sélection : {which})")
    if not wait_gateway():
        print("gateway injoignable — abandon"); sys.exit(99)
    try:
        tagd = pln = None
        if which in ("A", "ALL"): tagd, pln = spike_a()
        if which in ("B", "C", "D", "ALL") and tagd is None:
            tagd, _, _ = create_api(API_TAGD, tags=[TAG]); pln, _, _ = create_api(API_PLN)
            check("PORTE — le plan de données SERT les APIs neuves",
                  wait_data_plane(API_PLN), "dispatch pas prêt (reprise du conteneur ?)")
        if which in ("C", "ALL"): spike_c()
        if which in ("B", "ALL"): spike_b(pln)
        if which in ("D", "ALL"): spike_d(tagd)
    finally:
        cleanup()
    # Garde d'intégrité : ce spike ne doit RIEN laisser de cassé derrière lui.
    say("intégrité de la gateway après le spike")
    _, acts = adm("GET", "/policyActions")
    have = {a["id"] for a in (acts.get("policyAction") or [])}
    check("l'action SYSTÈME de log est intacte", SYS_ACTION in have,
          "supprimée en cascade — activate NPE : redémarrer la gateway pour la reconstituer")
    _, pols = adm("GET", "/policies")
    dangling = [(" ".join(x.get("value", "") for x in p.get("names", [])), e.get("enforcementObjectId"))
                for p in pols.get("policy", [])
                for st in (p.get("policyEnforcements") or [])
                for e in (st.get("enforcements") or [])
                if e.get("enforcementObjectId") not in have]
    check("aucune policy ne référence d'action fantôme", not dangling, f"{dangling}")

    say("VERDICTS")
    for s, t in VERDICTS: print(f"  {s} — {t}")
    print(f"\nRÉSULTAT : {OK} ✅ / {KO} ❌")
    sys.exit(KO)
