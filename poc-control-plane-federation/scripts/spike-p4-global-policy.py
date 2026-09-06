#!/usr/bin/env python3
"""spike-p4-global-policy.py — les spikes du jalon P4 du GOAL « posture par
exposition » (§ P4 « Les policies communes portées par la global policy »),
joués contre la wM 10.15 RÉELLE avec des actifs JETABLES (spikep4-*), nettoyés.

P0 a REFUTÉ le ciblage par tag et PROUVÉ le ciblage par nom (combiné à une
condition HTTP_METHOD). Ce spike mesure ce qu'il reste à savoir AVANT d'écrire
la moindre ligne du jalon :

  S1 — une SEULE condition `API` portant PLUSIEURS attributs `API_NAME` en OR
       sélectionne-t-elle plusieurs APIs ? (décide : une policy par BOUQUET,
       ou une policy par API)
  S2 — l'appartenance se modifie-t-elle À CHAUD par `PUT /policies/{id}` sur une
       policy ACTIVE, et la modification est-elle PERSISTÉE puis EFFECTIVE ?
       (le pipeline n'a que GET+PUT dans l'allow-list ADR-075)
  S3 — `throttle` (stage LMT) : forme réelle, dépendance `evaluatePolicy`
       déclarée par le template, et morsure au plan de données (429)
  S4 — `threatProtection` : le stage EXISTE (relevé dans stages.json) — une
       global policy qui le porte mord-elle ? C'est l'écart #1 d'ADR-091
  S5 — `entryProtocolPolicy` en GLOBAL : conflit avec l'action `transport` que
       porte DÉJÀ la Default Policy de chaque API ?
  S6 — CONTRE-ÉPREUVE : retirer l'API du scope ⇒ l'appel repasse
  S7 — les deux questions de CONCEPTION : une condition API VIDE sélectionne-t-elle
       tout (sûreté du play d'amorçage) ? et la sonde d'appartenance répond-elle
       sur une API INACTIVE (l'ordre des tâches du rôle) ?

  GW_ADMIN=http://localhost:5555/rest/apigateway GW_DATA=http://localhost:5555/gateway \
  WM_CONTAINER=poc-webmethods-real WM_USER=Administrator WM_PASS=manage \
  python3 scripts/spike-p4-global-policy.py [S1|S2|S3|S4|S5|S6|S7|all]

Sortie : lignes ✅/❌ + un bloc VERDICTS ; code retour = nombre de ❌.
PREUVE de spike, PAS un livrable : il mesure, il ne pose rien de durable.

RÈGLES DE SÉCURITÉ TENUES ICI, toutes héritées d'un incident MESURÉ au P0 :
  * on ne référence JAMAIS une policyAction du PRODUIT dans une policy jetable
    (sa suppression cascade sur l'action, action SYSTÈME comprise — toute
    activation d'API tombe alors en NPE jusqu'au redémarrage) ;
  * on VIDE les policyEnforcements avant toute suppression de policy ;
  * on ne touche à AUCUN actif préexistant, sauf en lecture.
"""
import base64, json, os, subprocess, sys, time, uuid, urllib.error, urllib.request

GW   = os.environ.get("GW_ADMIN", "http://localhost:5555/rest/apigateway")
DP   = os.environ.get("GW_DATA",  "http://localhost:5555/gateway")
CTR  = os.environ.get("WM_CONTAINER", "poc-webmethods-real")
USER = os.environ.get("WM_USER", "Administrator")
PASS = os.environ.get("WM_PASS", "manage")
AUTH = base64.b64encode(f"{USER}:{PASS}".encode()).decode()

A_ONE = "spikep4-alpha"    # membre du bouquet 1
A_TWO = "spikep4-beta"     # membre du bouquet 1 (prouve la LISTE)
A_OUT = "spikep4-gamma"    # hors bouquet — la contre-épreuve permanente
A_TLS = "spikep4-delta"    # API DÉDIÉE à S5 : une API déjà sous quota rendrait
                           # 429 et ferait passer S5 au vert pour la mauvaise
                           # raison (vert vacant mesuré au 1er passage)

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

def multipart(path, fields, filename, content, fctype):
    b = "----spikep4" + uuid.uuid4().hex
    parts = "".join(f"--{b}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n" for k, v in fields.items())
    body = (parts.encode()
            + f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{filename}\"\r\nContent-Type: {fctype}\r\n\r\n".encode()
            + content.encode() + f"\r\n--{b}--\r\n".encode())
    return adm("POST", path, raw=body, ctype=f"multipart/form-data; boundary={b}")

def hit(name, timeout=10):
    try:
        with urllib.request.urlopen(f"{DP}/{name}/1.0.0/ping", timeout=timeout) as r: return r.status
    except urllib.error.HTTPError as e: return e.code
    except Exception: return 0

def hit_post(name, payload, timeout=10):
    req = urllib.request.Request(f"{DP}/{name}/1.0.0/echo", data=payload.encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r: return r.status
    except urllib.error.HTTPError as e: return e.code
    except Exception: return 0

def wait_gateway(seconds=900):
    """Le lab recycle wM (~23 min de keepalive) : on attend une reprise."""
    for _ in range(seconds // 10):
        if adm("GET", "/apis")[0] == 200: return True
        time.sleep(10)
    return adm("GET", "/apis")[0] == 200

def wait_data_plane(name, seconds=180):
    for _ in range(seconds // 3):
        if hit(name) == 200: return True
        time.sleep(3)
    return hit(name) == 200

# ─────────────────────────────── actifs jetables ──────────────────────────────

CREATED = {"apis": [], "policies": [], "actions": []}

SPEC = """openapi: 3.0.0
info: {{ title: {n}, version: 1.0.0 }}
servers: [ {{ url: "http://poc-token-echo:8080" }} ]
paths:
  /ping:
    get:
      operationId: ping
      responses: {{ '200': {{ description: ok }} }}
  /echo:
    post:
      operationId: echo
      requestBody:
        content:
          application/json:
            schema: {{ type: object }}
      responses: {{ '200': {{ description: ok }} }}
"""

def create_api(name):
    c, r = multipart("/apis", {"type": "openapi", "apiName": name, "apiVersion": "1.0.0"},
                     "c.yaml", SPEC.format(n=name), "application/x-yaml")
    aid = (r.get("apiResponse") or {}).get("api", {}).get("id")
    if aid:
        CREATED["apis"].append(aid); adm("PUT", f"/apis/{aid}/activate")
    return aid

METH_COND = {"filterType": "HTTP_METHOD", "logicalConnector": "AND",
             "attributes": [{"attributeName": m, "value": "true"}
                            for m in ("GET", "POST", "PUT", "DELETE", "PATCH", "HEAD")]}

def names_cond(names, connector="OR"):
    """UNE condition API portant N attributs API_NAME — le point de S1."""
    return {"filterType": "API", "logicalConnector": connector,
            "attributes": [{"attributeName": "API_NAME", "operation": "EQUALS", "value": n}
                           for n in names]}

def mk_action(body):
    c, r = adm("POST", "/policyActions", {"policyAction": body})
    aid = (r.get("policyAction") or {}).get("id")
    if aid: CREATED["actions"].append(aid)
    return aid, c, r

def mk_global(label, conds, enforcements, activate=True):
    body = {"policy": {"names": [{"value": f"spikep4-{label}", "locale": "en"}],
            "policyScope": "GLOBAL", "global": True, "systemPolicy": False,
            "scope": {"applicableAPITypes": ["REST", "SOAP", "ODATA"],
                      "logicalConnector": "AND", "scopeConditions": conds},
            "policyEnforcements": enforcements}}
    c, r = adm("POST", "/policies", body)
    pid = (r.get("policy") or {}).get("id")
    ac = None
    if pid:
        CREATED["policies"].append(pid)
        if activate: ac = adm("PUT", f"/policies/{pid}/activate")
    return pid, c, r, ac

def applies_to(pid, aid):
    return pid in (adm("GET", f"/apis/{aid}/globalPolicies")[1].get("globalPolicies") or [])

def cleanup():
    say("ménage (actifs jetables)")
    for pid in CREATED["policies"]:
        adm("PUT", f"/policies/{pid}/deactivate")
        _, r = adm("GET", f"/policies/{pid}")
        pol = r.get("policy") or r
        if pol.get("id"):
            pol["policyEnforcements"] = []
            adm("PUT", f"/policies/{pid}", {"policy": pol})
        adm("DELETE", f"/policies/{pid}")
    for aid in CREATED["actions"]:
        adm("DELETE", f"/policyActions/{aid}")
    for aid in CREATED["apis"]:
        adm("PUT", f"/apis/{aid}/deactivate"); adm("DELETE", f"/apis/{aid}")
    print(f"  nettoyé : {len(CREATED['apis'])} APIs, {len(CREATED['policies'])} policies, "
          f"{len(CREATED['actions'])} actions")

# Copie JETABLE de l'action de log du produit. On NE référence JAMAIS
# `GlobalLogInvocationPolicyAction` : la suppression d'une policy cascade sur
# ses actions, action SYSTÈME comprise (incident mesuré au P0).
LOG_BODY = {"names": [{"value": "spikep4 log", "locale": "en"}],
            "templateKey": "logInvocation",
            "parameters": [
                {"templateKey": "storeRequestPayload", "values": ["false"]},
                {"templateKey": "storeResponsePayload", "values": ["false"]},
                {"templateKey": "storeAsZip", "values": ["false"]},
                {"templateKey": "logGenerationFrequency", "values": ["Always"]},
                {"templateKey": "destination",
                 "parameters": [{"templateKey": "destinationType", "values": ["GATEWAY"]}]}],
            "active": True}

def stage(stage_key, action_id):
    return [{"enforcements": [{"enforcementObjectId": action_id, "order": "0"}], "stageKey": stage_key}]

# ═══════════════════════════════ SOCLE ════════════════════════════════════════

def socle():
    say("SOCLE — quatre APIs jetables, servies par le plan de données")
    ids = {}
    for n in (A_ONE, A_TWO, A_OUT, A_TLS):
        ids[n] = create_api(n)
    if not check("quatre APIs jetables créées et activées", all(ids.values()), f"{ids}"):
        return None
    served = all(wait_data_plane(n) for n in (A_ONE, A_TWO, A_OUT, A_TLS))
    if not check("PORTE — le plan de données SERT les quatre APIs neuves", served,
                 "dispatch pas prêt (reprise du conteneur ?) — rien de ce qui suit ne serait mesuré"):
        return None
    return ids

# ═══════════════════════════════ SPIKE S1 ═════════════════════════════════════

def spike_s1(ids):
    say("S1 — UNE condition API, PLUSIEURS noms : une policy par BOUQUET ?")
    lid, c, r = mk_action(LOG_BODY)
    if not check("copie jetable de l'action de log posée", bool(lid), f"HTTP {c} {str(r)[:160]}"):
        return None
    enf = stage("LMT", lid)

    # Le point du spike : une SEULE condition API portant DEUX attributs
    # API_NAME, connectés en OR. Si elle ne sélectionne qu'un nom (ou aucun),
    # le jalon retombe sur « une global policy PAR API » — c'est-à-dire le
    # fan-out sous un autre nom, et l'objet unique par bouquet est mort.
    pid, c, r, ac = mk_global("S1-liste-de-noms", [METH_COND, names_cond([A_ONE, A_TWO], "OR")], enf)
    check("global policy « liste de noms » créée + activée", bool(pid), f"HTTP {c} {str(r)[:200]}")
    if not pid: return None
    time.sleep(5)
    a1, a2, ao = applies_to(pid, ids[A_ONE]), applies_to(pid, ids[A_TWO]), applies_to(pid, ids[A_OUT])
    mes("sélection (alpha, beta, gamma)", f"{a1}, {a2}, {ao}")
    multi = check("S1 une condition API à N attributs OR sélectionne LES DEUX APIs nommées",
                  a1 and a2, f"alpha={a1} beta={a2}")
    check("S1 CONTRE-ÉPREUVE — l'API hors liste n'est PAS sélectionnée", not ao, f"gamma={ao}")

    # Contrôle négatif : le même montage en AND. Deux noms EQUALS ne peuvent pas
    # être vrais en même temps — s'il sélectionne quand même, c'est que le
    # connecteur est ignoré et que le OR ci-dessus ne prouvait rien.
    pid_and, _, _, _ = mk_global("S1-liste-AND", [METH_COND, names_cond([A_ONE, A_TWO], "AND")], enf)
    time.sleep(5)
    b1 = applies_to(pid_and, ids[A_ONE]) if pid_and else True
    check("S1 TÉMOIN — le même montage en AND ne sélectionne RIEN (le connecteur est LU)",
          not b1, f"alpha={b1} sous un AND de deux noms EQUALS")

    verdict("S1", "une global policy par BOUQUET est possible (liste de noms en OR)" if multi
                  else "RÉFUTÉ : la liste de noms ne mord pas — repli sur une policy PAR API")
    return pid if multi else None

# ═══════════════════════════════ SPIKE S2 ═════════════════════════════════════

def spike_s2(ids, pid):
    say("S2 — l'appartenance se modifie-t-elle À CHAUD, par le seul GET+PUT de l'allow-list ?")
    if not pid:
        check("S2 sauté (S1 n'a pas rendu de policy)", False, "prérequis absent"); return
    c, r = adm("GET", f"/policies/{pid}")
    pol = r.get("policy") or {}
    before_enf = json.dumps(pol.get("policyEnforcements"), sort_keys=True)
    conds = pol.get("scope", {}).get("scopeConditions", [])
    api_conds = [x for x in conds if x.get("filterType") == "API"]
    if not check("S2 la policy relue porte bien sa condition API", bool(api_conds), f"{conds}"):
        return
    # JOINDRE : on ajoute gamma à la liste, on ne touche à rien d'autre.
    api_conds[0]["attributes"].append({"attributeName": "API_NAME", "operation": "EQUALS", "value": A_OUT})
    cw, rw = adm("PUT", f"/policies/{pid}", {"policy": pol})
    check("S2 PUT /policies/{id} accepté sur une policy ACTIVE", cw == 200, f"HTTP {cw} {str(rw)[:200]}")

    # Le piège maison : un 200 ne vaut RIEN sur cette gateway (PUT /apis à 200
    # sans écrire, mesuré au P0). Seule la relecture distingue « écrit » de
    # « accepté puis ignoré ».
    _, r2 = adm("GET", f"/policies/{pid}")
    pol2 = r2.get("policy") or {}
    names2 = [a.get("value") for cnd in pol2.get("scope", {}).get("scopeConditions", [])
              if cnd.get("filterType") == "API" for a in cnd.get("attributes", [])]
    mes("noms relus dans le scope", names2)
    check("S2 READ-BACK — le nom ajouté est RÉELLEMENT persisté", A_OUT in names2, f"{names2}")
    check("S2 les policyEnforcements sont INCHANGÉS par un PUT de scope",
          json.dumps(pol2.get("policyEnforcements"), sort_keys=True) == before_enf,
          "le PUT a modifié le contenu de la policy, pas seulement son appartenance")

    got = False
    for _ in range(8):
        time.sleep(3)
        got = applies_to(pid, ids[A_OUT])
        if got: break
    check("S2 EFFECTIF — la gateway sélectionne l'API ajoutée, sans désactiver/réactiver", got)

    # RETRAIT : la moitié qui manque à toute chaîne qui change de bouquet.
    _, r3 = adm("GET", f"/policies/{pid}")
    pol3 = r3.get("policy") or {}
    for cnd in pol3.get("scope", {}).get("scopeConditions", []):
        if cnd.get("filterType") == "API":
            cnd["attributes"] = [a for a in cnd["attributes"] if a.get("value") != A_OUT]
    adm("PUT", f"/policies/{pid}", {"policy": pol3})
    gone = True
    for _ in range(8):
        time.sleep(3)
        gone = not applies_to(pid, ids[A_OUT])
        if gone: break
    check("S2 le RETRAIT du nom libère l'API (l'appartenance est réversible à chaud)", gone)
    verdict("S2", "l'appartenance est pilotable par GET+PUT seuls, à chaud, dans les deux sens")

# ═══════════════════════════════ SPIKE S3 ═════════════════════════════════════

def throttle_body(label, limit):
    return {"names": [{"value": f"spikep4 throttle {label}", "locale": "en"}],
            "templateKey": "throttle",
            "parameters": [
                {"templateKey": "throttleRule", "parameters": [
                    {"templateKey": "throttleRuleName", "values": ["requestCount"]},
                    {"templateKey": "monitorRuleOperator", "values": ["GT"]},
                    {"templateKey": "value", "values": [str(limit)]}]},
                {"templateKey": "consumerIds", "values": ["AllConsumers"]},
                {"templateKey": "alertInterval", "values": ["1"]},
                {"templateKey": "alertIntervalUnit", "values": ["minutes"]},
                {"templateKey": "alertFrequency", "values": ["always"]},
                {"templateKey": "alertMessage", "values": [f"spikep4 {label} : quota depasse"]},
                {"templateKey": "destination",
                 "parameters": [{"templateKey": "destinationType", "values": ["GATEWAY"]}]}],
            "active": True}

def spike_s3(ids):
    say("S3 — `throttle` (LMT) : forme réelle, dépendance déclarée, et morsure au plan de données")
    tid, c, r = mk_action(throttle_body("q2", 2))
    check("S3 action `throttle` créée (templateKey relevé dans stages.json, absent du contrat publié)",
          bool(tid), f"HTTP {c} {str(r)[:300]}")
    if not tid:
        verdict("S3", "RÉFUTÉ : l'action de quota n'est pas créable sous cette forme"); return
    mes("forme acceptée", "throttleRule{throttleRuleName,monitorRuleOperator,value} + consumerIds + alertInterval/Unit/Frequency/Message + destination{destinationType}")

    # Le template déclare `dependentActions: ["evaluatePolicy"]`. Une policy qui
    # porte le quota SANS action d'identification est-elle refusée ? La réponse
    # décide si le bouquet COMMUN peut vivre seul dans son objet.
    pid, c, r, ac = mk_global("S3-quota-seul", [METH_COND, names_cond([A_ONE])], stage("LMT", tid))
    created = check("S3 policy de quota créée", bool(pid), f"HTTP {c} {str(r)[:300]}")
    if pid:
        acode = ac[0] if ac else 0
        mes("activation de la policy de quota (dépendance evaluatePolicy déclarée)", f"HTTP {acode} {str(ac[1])[:200] if ac else ''}")
        check("S3 la policy de quota s'ACTIVE malgré la dépendance `evaluatePolicy` du template",
              acode == 200, f"HTTP {acode}")
    if not created: return

    time.sleep(6)
    seq, hit_429 = [], 0
    for _ in range(6):
        s = hit(A_ONE); seq.append(s)
        if s == 429: hit_429 += 1
        time.sleep(0.4)
    mes("plan de données sous quota (limite GT 2 / minute)", seq)
    bites = check("S3 le quota MORD au plan de données (429 après la limite)", hit_429 > 0, f"{seq}")
    check("S3 CONTRE-ÉPREUVE — l'API hors scope n'est pas limitée", hit(A_OUT) == 200)
    verdict("S3", "le quota est portable par une global policy et mord au plan de données" if bites
                  else "le quota se pose mais NE MORD PAS — à ne pas promettre")
    return pid

# ═══════════════════════════════ SPIKE S4 ═════════════════════════════════════

def spike_s4(ids):
    say("S4 — `threatProtection` : le stage EXISTE dans stages.json — est-il portable par une policy ?")
    # Trois filtres différents, deux portées différentes : si le refus est le
    # même partout, ce n'est pas la forme d'UN payload qui est en cause.
    variants = [
        ("MsgSizeLimitFilter", [{"templateKey": "isMessageSizeEnabled", "values": ["true"]},
                                {"templateKey": "maximumMessageSize", "values": ["1"]}]),
        ("jsonThreatProtectionFilter", [
            {"templateKey": "isJSONThreatProtectionEnabled", "values": ["true"]},
            {"templateKey": "maxStringLength", "values": ["100"]},
            {"templateKey": "maxObjectEntryCount", "values": ["10"]},
            {"templateKey": "maxArrayElementCount", "values": ["10"]},
            {"templateKey": "maxObjectEntryNameLength", "values": ["50"]},
            {"templateKey": "maxContainerDepth", "values": ["5"]},
            {"templateKey": "applicableContentTypes", "values": ["application/json"]}]),
    ]
    made, refused = 0, 0
    for tk, params in variants:
        aid, c, r = mk_action({"names": [{"value": f"spikep4 {tk}", "locale": "en"}],
                               "templateKey": tk, "parameters": params, "active": True})
        if check(f"S4 action `{tk}` créée (le filtre EXISTE côté produit)", bool(aid), f"HTTP {c} {str(r)[:200]}"):
            made += 1
        if not aid:
            continue
        for label, conds in (("scopée par nom", [METH_COND, names_cond([A_TWO])]),
                             ("sans condition (toutes les APIs)", [])):
            pid, pc, pr, _ = mk_global(f"S4-{tk}-{len(conds)}", conds,
                                       stage("threatProtection", aid), activate=False)
            if pid:
                check(f"S4 policy `threatProtection` {label} — ACCEPTÉE (le stage est portable)", True)
            else:
                refused += 1
                mes(f"refus ({tk}, {label})", f"HTTP {pc} {str(pr)[:120]}")

    portable = made > 0 and refused == 0
    check("S4 le stage `threatProtection` est REFUSÉ par /policies, quelle que soit la forme",
          made > 0 and refused == 4, f"{refused}/4 refus pour {made}/2 actions créées")

    # Si le stage n'est pas portable, où vit donc le contrôle ? Réponse mesurée :
    # une surface d'ADMINISTRATION, gateway-wide — donc pas déclinable par bouquet.
    c, r = adm("GET", "/administration/threatprotection")
    check("S4 la surface de threat-protection existe, mais elle est d'ADMINISTRATION (gateway-wide)",
          c == 200, f"HTTP {c}")
    mes("GET /administration/threatprotection", str(r)[:160])
    # Le piège maison, revérifié : cette surface avale les sous-chemins inconnus,
    # donc un 200 n'y prouve l'existence de rien.
    c2, r2 = adm("GET", "/administration/threatprotection/ceci-nexiste-pas")
    check("S4 PIÈGE — un sous-chemin INEXISTANT rend le MÊME 200 (aucun 200 ne vaut preuve ici)",
          c2 == 200 and str(r2) == str(r), f"HTTP {c2} {str(r2)[:80]}")

    verdict("S4", "threat-protection N'EST PAS portable par une global policy (stage refusé) ; "
                  "sa seule surface est gateway-wide ⇒ écart #1 d'ADR-091 PRÉCISÉ, pas levé"
                  if not portable else
                  "threat-protection est portable par une global policy — écart #1 levé")

# ═══════════════════════════════ SPIKE S5 ═════════════════════════════════════

def spike_s5(ids):
    say("S5 — `entryProtocolPolicy` en GLOBAL : conflit avec le stage transport de la Default Policy ?")
    # API DÉDIÉE. Au premier passage, S5 tournait sur l'API que S3 venait de
    # mettre sous quota : le 429 du quota était lu comme le refus du protocole,
    # et le spike passait au vert pour la mauvaise raison.
    body = {"names": [{"value": "spikep4 https-only", "locale": "en"}],
            "templateKey": "entryProtocolPolicy",
            "parameters": [{"templateKey": "protocol", "values": ["https"]}],
            "active": True}
    eid, c, r = mk_action(body)
    if not check("S5 action `entryProtocolPolicy` (https) créée", bool(eid), f"HTTP {c} {str(r)[:200]}"):
        return
    base = hit(A_TLS)
    if not check("S5 base de référence — l'API dédiée répond 200 EN CLAIR avant toute policy",
                 base == 200, f"HTTP {base} (une API déjà refusée ne prouverait rien)"):
        return
    pid, c, r, ac = mk_global("S5-https", [METH_COND, names_cond([A_TLS])], stage("transport", eid))
    acode = ac[0] if ac else 0
    mes("création / activation", f"HTTP {c} / {acode}")
    activated = check("S5 la global policy `transport` s'active malgré l'action transport de la Default Policy",
                      bool(pid) and acode == 200, f"HTTP {c}/{acode} {str(ac[1])[:200] if ac else ''}")
    if not pid:
        verdict("S5", "https-only n'est PAS portable en global policy — il reste PAR API (levier de P5)")
        return
    if not activated:
        verdict("S5", "conflit à l'activation — https-only reste PAR API (levier de P5)")
        return
    got = 200
    for _ in range(10):
        time.sleep(3); got = hit(A_TLS)
        if got != 200: break
    mes("appel EN CLAIR sur l'API ciblée", got)
    bites = check("S5 l'appel en clair est REFUSÉ sur l'API ciblée", got not in (0, 200), f"HTTP {got}")
    check("S5 CONTRE-ÉPREUVE — l'API hors scope répond toujours en clair", hit(A_OUT) == 200)
    if bites:
        adm("PUT", f"/policies/{pid}/deactivate")
        back = 0
        for _ in range(10):
            time.sleep(3); back = hit(A_TLS)
            if back == 200: break
        check("S5 CONTRE-ÉPREUVE 2 — policy retirée, l'appel en clair repasse", back == 200, f"HTTP {back}")
    verdict("S5", "https-only EST portable par une global policy (mesuré sur une API dédiée)" if bites
                  else "la policy s'active mais ne mord pas — https-only reste PAR API")

# ═══════════════════════════════ SPIKE S6 ═════════════════════════════════════

def spike_s6(ids, pid_quota):
    say("S6 — CONTRE-ÉPREUVE du jalon : retirer le ciblage, l'appel repasse")
    if not pid_quota:
        check("S6 sauté (pas de policy de quota)", False, "prérequis absent"); return
    adm("PUT", f"/policies/{pid_quota}/deactivate")
    # La fenêtre du quota est d'UNE minute (plus petite unité offerte par le
    # produit) : un compteur déjà saturé continue de refuser jusqu'à ce qu'elle
    # roule. Attendre 30 s ferait rougir la contre-épreuve pour une raison qui
    # n'est pas la sienne.
    back = 0
    for _ in range(45):
        time.sleep(3); back = hit(A_ONE)
        if back == 200: break
    check("S6 policy de quota désactivée → l'appel repasse en 200", back == 200, f"HTTP {back}")
    verdict("S6", "le ciblage est bien la cause du refus (contre-épreuve tenue)" if back == 200
                  else "l'appel NE repasse PAS — le refus n'est pas imputable au seul ciblage")

# ═══════════════════════════════ SPIKE S7 ═════════════════════════════════════

def spike_s7(ids):
    say("S7 — les deux questions de CONCEPTION : la liste vide, et l'API inactive")
    lid, c, _ = mk_action(dict(LOG_BODY, names=[{"value": "spikep4 log s7", "locale": "en"}]))
    if not check("S7 action de log jetable posée", bool(lid), f"HTTP {c}"):
        return
    enf = stage("LMT", lid)

    # Q1 — LA QUESTION DE SÛRETÉ DU JOUR 0. Une policy de bouquet naît AVANT
    # d'avoir le moindre membre. Si une condition API SANS attribut sélectionne
    # TOUTES les APIs, créer les dix policies de la table de vérité frapperait
    # d'un coup toute la gateway — quota compris. On mesure le danger, puis le
    # remède : une SENTINELLE, nom qu'aucune API ne porte.
    pid_e, ce, re_, _ = mk_global("S7-liste-vide",
                                  [METH_COND, {"filterType": "API", "logicalConnector": "OR",
                                               "attributes": []}], enf)
    empty_bites = None
    if pid_e:
        time.sleep(5)
        sel = [n for n in (A_ONE, A_TWO, A_OUT) if applies_to(pid_e, ids[n])]
        empty_bites = bool(sel)
        mes("condition API SANS attribut : APIs sélectionnées", sel or "aucune")
        check("S7 Q1 — MESURÉ : une condition API VIDE ne borne RIEN, elle frappe TOUTES les APIs",
              empty_bites, "elle n'a rien sélectionné — la sentinelle serait alors superflue")
        adm("PUT", f"/policies/{pid_e}/deactivate")
    else:
        check("S7 Q1 — une condition API VIDE est REFUSÉE à la création (aussi sûr)", True,
              f"HTTP {ce} {str(re_)[:120]}")

    # LE REMÈDE, prouvé et non supposé : une condition dont l'unique attribut est
    # un nom qu'aucune API ne porte. C'est ce que le play d'amorçage posera, et
    # ce que le rôle laissera en place quand il retire le dernier membre.
    pid_s, cs, rs, _ = mk_global("S7-sentinelle", [METH_COND, names_cond(["__posture_aucune_api__"])], enf)
    if pid_s:
        time.sleep(5)
        sels = [n for n in (A_ONE, A_TWO, A_OUT) if applies_to(pid_s, ids[n])]
        check("S7 Q1 — REMÈDE : une SENTINELLE (nom qu'aucune API ne porte) ne sélectionne RIEN",
              not sels, f"elle sélectionne {sels}")
        adm("PUT", f"/policies/{pid_s}/deactivate")
    else:
        check("S7 Q1 — la policy sentinelle se crée", False, f"HTTP {cs} {str(rs)[:160]}")

    # Q2 — L'ORDRE DU RÔLE. Le tag se pose AVANT l'activation (P3) : une API
    # qu'on ne sait pas étiqueter n'est jamais mise en service. On veut la même
    # règle pour l'appartenance — mais elle n'est tenable que si la sonde
    # d'appartenance répond sur une API INACTIVE.
    aid = ids[A_OUT]
    adm("PUT", f"/apis/{aid}/deactivate")
    time.sleep(3)
    _, rec = adm("GET", f"/apis/{aid}")
    inactive = (rec.get("apiResponse") or {}).get("api", {}).get("isActive") in (False, "false")
    check("S7 Q2 — l'API témoin est bien DÉSACTIVÉE", inactive, f"isActive={((rec.get('apiResponse') or {}).get('api', {})).get('isActive')}")
    pid_i, ci, ri, aci = mk_global("S7-inactive", [METH_COND, names_cond([A_OUT])], enf)
    seen = False
    if pid_i:
        for _ in range(8):
            time.sleep(3)
            seen = applies_to(pid_i, aid)
            if seen: break
    check("S7 Q2 — la sonde d'appartenance RÉPOND sur une API INACTIVE", seen,
          "elle ne répond pas : l'appartenance ne peut se vérifier qu'APRÈS activation")
    adm("PUT", f"/apis/{aid}/activate")
    for _ in range(20):
        if hit(A_OUT) == 200: break
        time.sleep(3)
    verdict("S7", ("⚠ une condition API VIDE frappe TOUTES les APIs — le jour 0 DOIT poser une "
                   "sentinelle, et le rôle ne doit jamais vider la liste"
                   if empty_bites else "une condition API vide est inerte")
                  + " ; l'appartenance " + ("se vérifie AVANT activation (le rôle joint puis active)"
                                            if seen else "ne se vérifie qu'APRÈS activation"))

# ═══════════════════════════════ MAIN ═════════════════════════════════════════

def main():
    which = (sys.argv[1] if len(sys.argv) > 1 else "all").upper()
    if not wait_gateway():
        print("ABANDON : la gateway d'administration ne répond pas."); return 1
    ids = socle()
    if not ids:
        cleanup(); print(f"\nRésultat : {OK} ✅ / {KO} ❌"); return KO or 1
    try:
        pid_s1 = spike_s1(ids)                      if which in ("ALL", "S1", "S2") else None
        if which in ("ALL", "S2"): spike_s2(ids, pid_s1)
        pid_q = spike_s3(ids)                       if which in ("ALL", "S3", "S6") else None
        if which in ("ALL", "S4"): spike_s4(ids)
        if which in ("ALL", "S5"): spike_s5(ids)
        if which in ("ALL", "S6"): spike_s6(ids, pid_q)
        if which in ("ALL", "S7"): spike_s7(ids)
    finally:
        cleanup()
    print("\n══════════════ VERDICTS ══════════════")
    for s, t in VERDICTS: print(f"  {s} : {t}")
    print(f"\nRésultat : {OK} ✅ / {KO} ❌")
    return KO

if __name__ == "__main__":
    sys.exit(main())
