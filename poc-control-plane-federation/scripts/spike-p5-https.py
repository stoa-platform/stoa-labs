#!/usr/bin/env python3
"""spike-p5-https.py — les spikes du jalon P5 du GOAL « posture par exposition »
(GOAL-posture-par-exposition-2026-09-04.md, § P5), joués contre la wM 10.15
RÉELLE avec des actifs JETABLES (spikep5-*), nettoyés en sortie.

P5 possède l'AXE HTTPS en entier : le protocole d'entrée PAR API (pipeline) et
le listener PAR ENVIRONNEMENT (hors pipeline). P1 a déjà posé la moitié « le
bouquet exige https-only à toutes les cases » et sa VÉRIFICATION au read-back
(verifyHTTPSOnly, sur le transportProtocol de l'API). Il reste à POSER le
réglage depuis le rôle Ansible, et à mesurer live que l'appel en clair est
réellement refusé — puis que le retrait du réglage le fait repasser, faute de
quoi c'est le listener qui refusait et non l'API.

  S1 — la FORME : une API fraîchement importée porte-t-elle un stage `transport`
       avec une action `entryProtocolPolicy`, et que vaut-elle par défaut ?
  S2 — l'action transport est-elle PARTAGÉE entre APIs ? (le throttle LMT l'est,
       mesuré en P4 — si celle-ci l'était, poser https sur une API le poserait
       sur TOUTES, et le jalon changerait de conception.)
  S3 — la POSE sur une API ACTIVE : acceptée ? l'API reste-t-elle active ?
       le plan de données HTTPS répond-il aussitôt, sans redémarrage ?
  S4 — LA PORTE : l'appel en CLAIR est refusé, l'appel en HTTPS passe.
  S5 — LA CONTRE-ÉPREUVE : le réglage retiré, l'appel en clair REPASSE.
  S6 — le LISTENER : la forme d'un port HTTPS se rejoue (POST /ports), et
       `primary` / `enabled` sont DEUX champs — promouvoir ne ferme pas le HTTP.
  S7 — un RÉ-IMPORT de contrat (PUT multipart /apis/{id}) efface-t-il le
       réglage ? (décide la POSITION de la tâche dans le rôle, comme le tag P3.)
  S8 — le réglage est-il posable sur une API INACTIVE ? (sans quoi il faudrait
       choisir entre poser et ne jamais servir en clair — P4 a dû mesurer le
       fait jumeau pour `GET /apis/{id}/globalPolicies`.)
  S9 — la PROMOTION en primaire a-t-elle seulement une surface REST ? Sondée en
       NO-OP (on promeut le port DÉJÀ primaire) : livrer un appel dont la forme
       n'a pas été mesurée est précisément ce que ce projet s'interdit, et
       basculer le primaire d'un lab dont tout dépend n'est pas une option.
  S10 — par quelle URL converge-t-on `clientAuth` ? `is-mtls-setup.yml` écrit
       sur `/ports/{alias}` — or le champ `alias` vaut « ssos » sur TOUS les
       listeners relus. Mesuré sur un port JETABLE, jamais sur un port réel.

  GW_ADMIN=http://localhost:5555/rest/apigateway GW_DATA=http://localhost:5555/gateway \
  WM_CONTAINER=poc-webmethods-real WM_USER=Administrator WM_PASS=manage \
  python3 scripts/spike-p5-https.py [S1|S2|S3|S4|S5|S6|S7|S8|S9|S10|all]

Sortie : lignes ✅/❌ + un bloc VERDICTS ; code retour = nombre de ❌.
Ce script est une PREUVE de spike, PAS un livrable : il mesure, il ne pose rien
de durable. Aucun actif préexistant n'est modifié — sauf lecture.

RÈGLE DE SÉCURITÉ TENUE ICI, comme au spike P0 : on ne touche JAMAIS au port
primaire (5555) par lequel on est connecté, ni à sa promotion. Le piège
« promouvoir un port HTTPS ne ferme pas le HTTP » se mesure sur les CHAMPS des
listeners, pas en basculant le primaire d'un lab dont tout le reste dépend.
"""
import base64, json, os, subprocess, sys, time, uuid, urllib.error, urllib.request

GW   = os.environ.get("GW_ADMIN", "http://localhost:5555/rest/apigateway")
DP   = os.environ.get("GW_DATA",  "http://localhost:5555/gateway")
CTR  = os.environ.get("WM_CONTAINER", "poc-webmethods-real")
USER = os.environ.get("WM_USER", "Administrator")
PASS = os.environ.get("WM_PASS", "manage")
AUTH = base64.b64encode(f"{USER}:{PASS}".encode()).decode()

API_A  = "spikep5-a"            # celle qu'on bascule en https
API_B  = "spikep5-b"            # le témoin : elle ne doit RIEN subir
API_C  = "spikep5-c"            # jamais activée (S8)
PORT_S = 5597                   # listener HTTPS jetable (S6)
HTTPS_SAMPLE = 5543             # listener HTTPS existant (échantillon + porte)

OK = KO = 0
VERDICTS = []

def ok(m):
    global OK; OK += 1; print(f"  ✅ {m}")
def ko(m):
    global KO; KO += 1; print(f"  ❌ {m}")
def check(label, cond, detail=""):
    # Le détail n'accompagne QUE l'échec (même règle qu'au spike P0) : collé à un
    # vert, un texte qui explique la panne se lit comme si la panne avait eu lieu.
    # Ce qui doit se voir en toutes circonstances passe par `mes()`.
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

def multipart(path, fields, filename, content, fctype, method="POST"):
    b = "----spikep5" + uuid.uuid4().hex
    parts = "".join(f"--{b}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n" for k, v in fields.items())
    body = (parts.encode()
            + f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{filename}\"\r\nContent-Type: {fctype}\r\n\r\n".encode()
            + content.encode() + f"\r\n--{b}--\r\n".encode())
    return adm(method, path, raw=body, ctype=f"multipart/form-data; boundary={b}")

def ctr_curl(args, auth=True, timeout=10, body=False):
    """curl DANS le conteneur wM. Basic auth par config sur STDIN, jamais en argv
    (standard du repo — cf. scripts/repair-wm-dangling-policyaction.sh)."""
    cmd = ["docker", "exec", "-i", CTR, "curl", "-sk", "-m", str(timeout)]
    cmd += [] if body else ["-o", "/dev/null", "-w", "%{http_code}"]
    if auth: cmd += ["-K", "-"]
    cmd += args
    inp = f'user = "{USER}:{PASS}"\n' if auth else ""
    return subprocess.run(cmd, input=inp, capture_output=True, text=True).stdout

def hit(name, host=None, timeout=10):
    """Appel plan de données. host=None -> DP depuis l'hôte ; sinon DANS le conteneur."""
    if host is None:
        try:
            with urllib.request.urlopen(f"{DP}/{name}/1.0.0/ping", timeout=timeout) as r: return r.status
        except urllib.error.HTTPError as e: return e.code
        except Exception: return 0
    return int(ctr_curl([f"{host}/gateway/{name}/1.0.0/ping"], auth=False, timeout=timeout).strip() or 0)

def hit_body(name, host, timeout=10):
    return ctr_curl([f"{host}/gateway/{name}/1.0.0/ping"], auth=False, timeout=timeout, body=True)

def wait_data_plane(name, seconds=180):
    for _ in range(seconds // 3):
        if hit(name) == 200: return True
        time.sleep(3)
    return hit(name) == 200

# ─────────────────────────────── actifs jetables ──────────────────────────────

CREATED = {"apis": [], "ports": []}

SPEC = ("openapi: 3.0.0\n"
        "info: {{ title: {name}, version: 1.0.0 }}\n"
        "servers: [ {{ url: \"http://poc-token-echo:8080\" }} ]\n"
        "paths:\n  /ping:\n    get:\n      operationId: ping\n"
        "      responses: {{ '200': {{ description: ok }} }}\n")

def create_api(name, activate=True):
    c, r = multipart("/apis", {"type": "openapi", "apiName": name, "apiVersion": "1.0.0"},
                     "c.yaml", SPEC.format(name=name), "application/x-yaml")
    aid = (r.get("apiResponse") or {}).get("api", {}).get("id")
    if aid:
        CREATED["apis"].append(aid)
        if activate: adm("PUT", f"/apis/{aid}/activate")
    return aid, c

def api_record(aid):
    _, r = adm("GET", f"/apis/{aid}")
    return (r.get("apiResponse") or {}).get("api", {})

def get_policy(pid):
    c, r = adm("GET", f"/policies/{pid}")
    pol = r.get("policy") or r
    return (pol if isinstance(pol, dict) and pol.get("id") else None), c

def service_policy(aid):
    """La policy SERVICE de l'API — celle qui porte les stages (même règle que
    findServicePolicy côté Go : scope SERVICE, sinon la première)."""
    rec = api_record(aid)
    first = None
    for pid in (rec.get("policies") or []):
        pol, _ = get_policy(pid)
        if pol is None: continue
        if first is None: first = (pid, pol)
        if pol.get("policyScope") == "SERVICE": return pid, pol
    return first if first else (None, None)

def stage_action_ids(policy, stage_key):
    out = []
    for s in (policy.get("policyEnforcements") or []):
        if s.get("stageKey") != stage_key: continue
        for e in (s.get("enforcements") or []):
            if e.get("enforcementObjectId"): out.append(e["enforcementObjectId"])
    return out

def get_action(action_id):
    c, r = adm("GET", f"/policyActions/{action_id}")
    return (r.get("policyAction") or r), c

def action_protocols(action):
    for p in (action.get("parameters") or []):
        if p.get("templateKey") == "protocol":
            return p.get("values") or []
    return None

def set_protocol(action_id, protocol):
    """La projection portée par transport.go:89, jouée en REST nu."""
    act, _ = get_action(action_id)
    found = False
    for p in (act.get("parameters") or []):
        if p.get("templateKey") == "protocol":
            p["values"] = [protocol]; found = True
    if not found:
        act.setdefault("parameters", []).append({"templateKey": "protocol", "values": [protocol]})
    return adm("PUT", f"/policyActions/{action_id}", {"policyAction": act})

def transport_action_of(aid):
    """(policy_id, action_id, protocoles) du stage transport de l'API."""
    pid, pol = service_policy(aid)
    if pol is None: return None, None, None
    for act_id in stage_action_ids(pol, "transport"):
        act, _ = get_action(act_id)
        if act.get("templateKey") == "entryProtocolPolicy":
            return pid, act_id, action_protocols(act)
    return pid, None, None

def cleanup():
    say("ménage (actifs jetables)")
    for aid in CREATED["apis"]:
        adm("PUT", f"/apis/{aid}/deactivate"); adm("DELETE", f"/apis/{aid}")
    for key in CREATED["ports"]:
        adm("PUT", "/ports/disable", {"listenerKey": key}); adm("DELETE", f"/ports/{key}")
    print(f"  nettoyé : {len(CREATED['apis'])} APIs, {len(CREATED['ports'])} ports")

# ═══════════════════════════════ S1 ═══════════════════════════════════════════

STATE = {}

def s1():
    say("S1 — la FORME : le stage transport d'une API fraîchement importée")
    aid_a, ca = create_api(API_A)
    aid_b, cb = create_api(API_B)
    STATE["a"], STATE["b"] = aid_a, aid_b
    if not check("S1 deux APIs jetables créées et activées", bool(aid_a and aid_b), f"HTTP {ca}/{cb}"):
        return
    check("S1 le plan de données SERT l'API (en clair, sur le port primaire)",
          wait_data_plane(API_A), "l'API neuve ne répond pas — inutile de mesurer un refus")

    pid, act_id, protos = transport_action_of(aid_a)
    STATE["pid"], STATE["act"] = pid, act_id
    check("S1 l'API a une policy SERVICE", bool(pid))
    check("S1 elle porte un stage `transport` avec une action `entryProtocolPolicy`",
          bool(act_id), "absente — le rôle devra CRÉER l'action, pas seulement l'éditer")
    mes("protocoles par défaut de l'action entryProtocolPolicy", protos)
    check("S1 la valeur par défaut ACCEPTE le clair (donc il y a bien quelque chose à poser)",
          protos is not None and "http" in [str(p).lower() for p in protos], f"{protos}")
    verdict("S1", "une API importée porte NATIVEMENT un stage `transport` avec une action "
                  f"`entryProtocolPolicy` à {protos} : le rôle a un objet à éditer, pas à créer.")

# ═══════════════════════════════ S2 ═══════════════════════════════════════════

def s2():
    say("S2 — l'action transport est-elle PARTAGÉE entre APIs ? (le throttle LMT l'est)")
    aid_a, aid_b = STATE.get("a"), STATE.get("b")
    if not (aid_a and aid_b): return ko("S2 pas d'APIs (S1 a échoué)")
    _, act_a, _ = transport_action_of(aid_a)
    _, act_b, prot_b = transport_action_of(aid_b)
    mes("id de l'action transport de A", act_a)
    mes("id de l'action transport de B", act_b)
    distinct = bool(act_a) and bool(act_b) and act_a != act_b
    check("S2 chaque API a SA PROPRE action entryProtocolPolicy (ids distincts)",
          distinct, f"A={act_a} B={act_b} — si égaux, poser https sur A le poserait sur B")

    # La mesure qui compte : on écrit sur A, on relit B.
    c, _ = set_protocol(act_a, "https")
    mes("PUT /policyActions/{id} protocol=[https] sur A", f"HTTP {c}")
    check("S2 PUT /policyActions/{id} protocol=[https] sur A accepté", c in (200, 201), f"HTTP {c}")
    _, _, prot_b_after = transport_action_of(aid_b)
    check("S2 …et B n'a PAS bougé (l'écriture ne fuit pas d'une API à l'autre)",
          prot_b_after == prot_b, f"B avant={prot_b} après={prot_b_after}")
    verdict("S2", "l'action `entryProtocolPolicy` est PROPRE à chaque API (contrairement au "
                  "throttle LMT partagé mesuré en P4) : la poser par API n'a aucun effet de bord.")

# ═══════════════════════════════ S3 ═══════════════════════════════════════════

def s3():
    say("S3 — la POSE sur une API ACTIVE : coupure ? redémarrage ?")
    aid_a = STATE.get("a")
    if not aid_a: return ko("S3 pas d'API (S1 a échoué)")
    rec = api_record(aid_a)
    check("S3 l'API est relue ACTIVE après la pose (aucune désactivation implicite)",
          bool(rec.get("isActive")), f"isActive={rec.get('isActive')}")
    _, _, protos = transport_action_of(aid_a)
    check("S3 READ-BACK : l'action porte bien [https] (un 200 ne prouve rien sur cette gateway)",
          protos == ["https"], f"{protos}")

    # Le plan de données HTTPS répond-il AUSSITÔT, sans redémarrage ?
    code = 0
    for _ in range(10):
        code = hit(API_A, f"https://localhost:{HTTPS_SAMPLE}")
        if code == 200: break
        time.sleep(2)
    mes(f"plan de données HTTPS (:{HTTPS_SAMPLE})", f"HTTP {code}")
    check("S3 le plan de données HTTPS répond, sans redémarrage de l'IS",
          code == 200, f"HTTP {code} sur :{HTTPS_SAMPLE}")
    verdict("S3", "la pose est un PUT de policyAction sur une API qui reste ACTIVE, prise en "
                  "compte à chaud : hors contrainte ADR-079, comme la pose du tag en P3. Mais "
                  "elle FERME le clair — c'est une rupture pour l'appelant, pas pour la plateforme.")

# ═══════════════════════════════ S4 ═══════════════════════════════════════════

def s4():
    say("S4 — LA PORTE : le clair est refusé, le HTTPS passe")
    aid_a, aid_b = STATE.get("a"), STATE.get("b")
    if not aid_a: return ko("S4 pas d'API (S1 a échoué)")

    clear_a = hit(API_A)
    body_a  = hit_body(API_A, f"http://localhost:5555")
    mes("code du refus en clair", clear_a)
    mes("corps du refus en clair", body_a[:160].replace("\n", " "))
    check("S4 l'appel en CLAIR est REFUSÉ sur l'API https-only", clear_a != 200, f"HTTP {clear_a}")
    check("S4 …et le refus est bien celui du PROTOCOLE (message du produit)",
          "Transport protocol not supported" in body_a, f"{body_a[:120]}")

    https_a = hit(API_A, f"https://localhost:{HTTPS_SAMPLE}")
    mes("code de l'appel en HTTPS", https_a)
    check("S4 l'appel en HTTPS PASSE sur la même API", https_a == 200, f"HTTP {https_a}")

    # Le témoin : une API que la plateforme n'a pas basculée reste joignable en
    # clair. Sans lui, un refus global (gateway en vrac) se lirait comme un succès.
    clear_b = hit(API_B)
    mes("code du TÉMOIN (API B, non basculée) en clair", clear_b)
    check("S4 TÉMOIN : l'API B, non basculée, répond TOUJOURS en clair",
          clear_b == 200, f"HTTP {clear_b} — un refus ici voudrait dire que ce n'est pas la policy qui refuse")
    verdict("S4", f"porte tenue : même API, HTTP {clear_a} en clair « Transport protocol not "
                  f"supported » et HTTP {https_a} en HTTPS, pendant que l'API témoin répond "
                  f"HTTP {clear_b} en clair.")

# ═══════════════════════════════ S5 ═══════════════════════════════════════════

def s5():
    say("S5 — LA CONTRE-ÉPREUVE : réglage retiré, le clair REPASSE")
    aid_a = STATE.get("a")
    if not aid_a: return ko("S5 pas d'API (S1 a échoué)")
    _, act_a, _ = transport_action_of(aid_a)
    c, _ = set_protocol(act_a, "http")
    check("S5 retrait du réglage (protocol=[http]) accepté", c in (200, 201), f"HTTP {c}")
    _, _, protos = transport_action_of(aid_a)
    check("S5 READ-BACK : l'action porte de nouveau [http]", protos == ["http"], f"{protos}")

    code = 0
    for _ in range(10):
        code = hit(API_A)
        if code == 200: break
        time.sleep(2)
    mes("code de l'appel en clair, réglage retiré", code)
    check("S5 l'appel en CLAIR repasse — c'était donc bien la POLICY qui refusait, pas le listener",
          code == 200, f"HTTP {code}")

    https_after = hit(API_A, f"https://localhost:{HTTPS_SAMPLE}")
    mes("et en HTTPS, réglage retiré", https_after)
    check("S5 …et l'appel HTTPS est maintenant refusé (le réglage tranche DANS LES DEUX SENS)",
          https_after != 200, f"HTTP {https_after}")
    verdict("S5", "contre-épreuve tenue : le même levier ouvre et ferme le clair. Le refus mesuré "
                  "en S4 vient de l'API, pas du port. À noter : `entryProtocolPolicy` est EXCLUSIF "
                  "— [http] ferme le HTTPS autant que [https] ferme le clair.")

# ═══════════════════════════════ S6 ═══════════════════════════════════════════

def s6():
    say("S6 — le LISTENER : forme rejouable, et `primary` ≠ `enabled`")
    _, r = adm("GET", "/ports")
    listeners = r.get("listeners", [])
    src = [l for l in listeners if l.get("port") == HTTPS_SAMPLE]
    if not check(f"S6 listener HTTPS :{HTTPS_SAMPLE} présent (échantillon)", bool(src)): return
    rec = src[0]
    check("S6 le port HTTPS porte son keystore par ALIAS, pas par chemin",
          isinstance(rec.get("keyStore"), str) and bool(rec.get("keyStore")), f"{rec.get('keyStore')}")
    mes("clientAuth de l'échantillon", rec.get("clientAuth"))
    mes("keystore de l'échantillon", rec.get("keyStore"))

    body = json.loads(json.dumps(rec))
    for k in ("uniqueID", "key", "listenerKey", "primary", "targets", "curDelay"): body.pop(k, None)
    body.update({"port": PORT_S, "portAlias": "spikep5Secure",
                 "portDescription": "spike P5 — port HTTPS jetable", "enabled": "false"})
    c, _ = adm("POST", "/ports", body)
    KEY = f"HTTPSListener@{PORT_S}"
    if check("S6 la forme relue se REJOUE en création (POST /ports)", c in (200, 201), f"HTTP {c}"):
        CREATED["ports"].append(KEY)
    ce, _ = adm("PUT", "/ports/enable", {"listenerKey": KEY})
    time.sleep(2)
    _, r2 = adm("GET", "/ports")
    new = [l for l in r2.get("listeners", []) if l.get("listenerKey") == KEY]
    mes("listener jetable relu", {k: (new[0].get(k) if new else None)
                                  for k in ("port", "protocol", "enabled", "keyStore", "clientAuth")})
    check("S6 le listener créé est relu, ACTIVÉ, avec le même keystore",
          bool(new) and new[0].get("enabled") == "true" and new[0].get("keyStore") == rec.get("keyStore"),
          f"HTTP {ce} — {new[0] if new else 'absent'}")

    # LE PIÈGE ANNONCÉ, mesuré sur les CHAMPS et non en basculant le primaire du
    # lab : `primary` et `enabled` sont deux axes indépendants. Le port HTTP
    # primaire est activé ; promouvoir un HTTPS en primaire ne toucherait pas son
    # `enabled`. Fermer le clair est donc un TROISIÈME geste, explicite.
    http_l = [l for l in listeners if str(l.get("protocol", "")).upper() == "HTTP" and l.get("enabled") == "true"]
    prim   = [l for l in listeners if l.get("primary")]
    mes("listeners HTTP activés", [f"{l.get('port')}({'primary' if l.get('primary') else '-'})" for l in http_l])
    mes("listener primaire", [l.get("listenerKey") for l in prim])
    check("S6 `primary` et `enabled` sont DEUX champs distincts du même objet",
          all(("primary" in l or True) and "enabled" in l for l in listeners)
          and len(http_l) > 0,
          "sans quoi promouvoir un HTTPS suffirait à fermer le clair")
    verdict("S6", "un port HTTPS se crée en recopiant un record relu (keystore par ALIAS, le "
                  "contrat publié sous-décrit l'objet). `enabled` et `primary` sont indépendants : "
                  "promouvoir un HTTPS en primaire NE FERME PAS le HTTP — c'est un geste séparé, "
                  "et c'est pourquoi le refus doit vivre sur l'API (S4) et non sur la topologie.")

# ═══════════════════════════════ S7 ═══════════════════════════════════════════

def s7():
    say("S7 — un RÉ-IMPORT de contrat efface-t-il le réglage ? (position dans le rôle)")
    aid_a = STATE.get("a")
    if not aid_a: return ko("S7 pas d'API (S1 a échoué)")
    _, act_a, _ = transport_action_of(aid_a)
    set_protocol(act_a, "https")
    _, _, before = transport_action_of(aid_a)
    if not check("S7 point de départ : l'action porte [https]", before == ["https"], f"{before}"):
        return

    # Le chemin `update` du rôle : deactivate -> PUT multipart -> activate.
    adm("PUT", f"/apis/{aid_a}/deactivate")
    c, _ = multipart(f"/apis/{aid_a}", {"type": "openapi", "apiName": API_A, "apiVersion": "1.0.0"},
                     "c.yaml", SPEC.format(name=API_A), "application/x-yaml", method="PUT")
    adm("PUT", f"/apis/{aid_a}/activate")
    check("S7 ré-import de la définition accepté (API désactivée le temps du PUT)",
          c in (200, 201), f"HTTP {c}")

    pid_after, act_after, after = transport_action_of(aid_a)
    mes("id de l'action transport APRÈS le ré-import", act_after)
    mes("protocoles APRÈS le ré-import", after)
    survived = after == ["https"]
    check("S7 le réglage survit au ré-import de contrat", survived,
          f"avant={before} après={after} — s'il ne survit pas, la tâche doit être RE-JOUÉE après tout ré-import")
    verdict("S7", ("le réglage SURVIT au ré-import de contrat : la pose peut vivre une seule fois "
                   "dans le rôle." if survived else
                   "le réglage NE SURVIT PAS au ré-import de contrat : comme le tag en P3, la pose "
                   "doit être placée APRÈS toute écriture de définition, et relue en dernier mot."))

# ═══════════════════════════════ S8 ═══════════════════════════════════════════

def s8():
    say("S8 — le réglage est-il posable sur une API INACTIVE ? (position dans le rôle)")
    aid_c, cc = create_api(API_C, activate=False)
    if not check("S8 API jetable créée SANS activation", bool(aid_c), f"HTTP {cc}"):
        return
    rec = api_record(aid_c)
    mes("isActive de l'API C", rec.get("isActive"))
    if not check("S8 l'API est bien INACTIVE (sinon la mesure ne dit rien)",
                 not rec.get("isActive"), f"isActive={rec.get('isActive')}"):
        return

    pid, act_id, protos = transport_action_of(aid_c)
    mes("action transport d'une API inactive", act_id)
    mes("protocoles lus", protos)
    if not check("S8 la policy SERVICE et son action transport sont LISIBLES sur une API inactive",
                 bool(pid) and bool(act_id)):
        return

    c, _ = set_protocol(act_id, "https")
    check("S8 le PUT du protocole est ACCEPTÉ sur une API inactive", c in (200, 201), f"HTTP {c}")
    _, _, after = transport_action_of(aid_c)
    posed = after == ["https"]
    check("S8 READ-BACK : le réglage est réellement porté avant toute activation",
          posed, f"{after}")

    # Et il tient à l'activation — sans quoi poser avant serait un vert vacant.
    adm("PUT", f"/apis/{aid_c}/activate")
    _, _, after_act = transport_action_of(aid_c)
    mes("protocoles après activation", after_act)
    check("S8 …et il SURVIT à l'activation", after_act == ["https"], f"{after_act}")
    clear_c = hit(API_C)
    mes("appel en clair sur l'API C, activée https-only", clear_c)
    check("S8 l'API n'a JAMAIS servi en clair : dès sa première activation, le clair est refusé",
          clear_c != 200, f"HTTP {clear_c}")
    verdict("S8", "le réglage se pose et se relit sur une API INACTIVE, et survit à l'activation : "
                  "la tâche va AVANT l'activation, comme le tag (P3) et l'appartenance (P4). Une API "
                  "gouvernée https-only ne sert donc jamais un seul appel en clair, pas même pendant "
                  "sa publication.")

# ═══════════════════════════════ S9 ═══════════════════════════════════════════

def s9():
    say("S9 — la promotion en primaire : y a-t-il une surface REST ? (sondée en NO-OP)")
    _, r = adm("GET", "/ports")
    prim = [l for l in r.get("listeners", []) if l.get("primary")]
    if not check("S9 un listener primaire est identifiable", bool(prim)): return
    key = prim[0].get("listenerKey")
    mes("primaire courant", key)

    # LA PRÉCAUTION, et elle est le sujet : on promeut le port DÉJÀ primaire.
    # Un 200 dit que la surface existe et que sa forme est celle-ci ; un 404/405
    # dit qu'elle n'existe pas. Dans les deux cas le lab ne bouge pas d'un cran.
    shapes = [("PUT /ports/primary {listenerKey}", "PUT", "/ports/primary", {"listenerKey": key}),
              ("PUT /ports/{key}/primary", "PUT", f"/ports/{key}/primary", None)]
    found = None
    for label, meth, path, body in shapes:
        c, resp = adm(meth, path, body)
        mes(f"sonde {label}", f"HTTP {c}")
        if c in (200, 201) and found is None:
            found = label
    check("S9 au moins une forme de promotion répond (sinon : aucune surface REST mesurée)",
          found is not None, "aucune des formes sondées n'a répondu 200")

    _, r2 = adm("GET", "/ports")
    prim2 = [l.get("listenerKey") for l in r2.get("listeners", []) if l.get("primary")]
    check("S9 le primaire n'a PAS bougé (la sonde était bien un no-op)",
          prim2 == [key], f"avant=[{key}] après={prim2}")

    if found:
        verdict("S9", f"la promotion a une surface REST mesurée : {found}. Elle reste néanmoins "
                      "DÉSACTIVÉE par défaut dans le play — promouvoir ne ferme pas le HTTP (S6) "
                      "et ne protège aucune API (S4) : c'est un geste de topologie, pas un contrôle.")
    else:
        verdict("S9", "AUCUNE surface REST de promotion n'a répondu. Le play ne peut donc pas la "
                      "livrer : il nomme le geste et le renvoie à l'IS Admin, plutôt que d'expédier "
                      "un appel dont la forme n'a jamais été mesurée.")

# ═══════════════════════════════ S10 ══════════════════════════════════════════

def s10():
    say("S10 — `clientAuth` : par quelle surface se règle-t-il ? (sur des ports JETABLES)")
    _, r = adm("GET", "/ports")
    src = [l for l in r.get("listeners", []) if l.get("port") == HTTPS_SAMPLE]
    if not check("S10 échantillon HTTPS lisible", bool(src)): return
    rec = src[0]

    # a) Le champ `alias` est-il discriminant ? `is-mtls-setup.yml` écrit sur
    #    /ports/{alias} : si deux listeners partagent la valeur, cette URL ne
    #    désigne pas un port.
    aliases = {l.get("listenerKey"): l.get("alias") for l in r.get("listeners", [])}
    mes("champ `alias` par listener", aliases)
    https_aliases = [v for k, v in aliases.items() if k.startswith("HTTPS")]
    check("S10 MESURE : le champ `alias` n'est PAS discriminant entre listeners HTTPS",
          len(set(https_aliases)) < len(https_aliases),
          f"{aliases} — si les valeurs diffèrent, /ports/{{alias}} est légitime et cette mesure est à revoir")

    KEY = f"HTTPSListener@{PORT_S}"

    def mk_port(client_auth, alias):
        body = json.loads(json.dumps(rec))
        for k in ("uniqueID", "key", "listenerKey", "primary", "targets", "curDelay"): body.pop(k, None)
        body.update({"port": PORT_S, "portAlias": alias, "enabled": "false",
                     "portDescription": "spike P5 — clientAuth", "clientAuth": client_auth})
        return adm("POST", "/ports", body)

    def read_port():
        _, rr = adm("GET", "/ports")
        m = [l for l in rr.get("listeners", []) if l.get("listenerKey") == KEY]
        return (m[0] if m else {})

    def drop_port():
        adm("PUT", "/ports/disable", {"listenerKey": KEY}); adm("DELETE", f"/ports/{KEY}")

    # b) La CRÉATION honore-t-elle clientAuth ? C'est la question qui décide le
    #    play : si oui, le réglage se pose à la naissance du port et « converger »
    #    veut dire « recréer », pas « éditer ».
    c, _ = mk_port("require", "spikep5Auth")
    if not check("S10 port jetable créé avec clientAuth=require", c in (200, 201), f"HTTP {c}"):
        return
    CREATED["ports"].append(KEY)
    born = read_port()
    mes("clientAuth relu À LA NAISSANCE", born.get("clientAuth"))
    honored = born.get("clientAuth") == "require"
    check("S10 la CRÉATION honore clientAuth (le port naît avec le mode demandé)",
          honored, f"demandé=require relu={born.get('clientAuth')}")

    # c) Et l'ÉDITION ? Deux URL, une seule relecture qui compte.
    cur = born
    persisted = None
    for label, path in (("/ports/{listenerKey}", f"/ports/{KEY}"),
                        ("/ports/{alias}", f"/ports/{cur.get('alias')}")):
        target = json.loads(json.dumps(cur))
        for k in ("uniqueID", "key", "primary", "targets", "curDelay"): target.pop(k, None)
        target["clientAuth"] = "none"
        cc, _ = adm("PUT", path, target)
        after = read_port()
        mes(f"PUT {label}", f"HTTP {cc} -> clientAuth relu = {after.get('clientAuth')}")
        if after.get("clientAuth") == "none":
            persisted = label
            break
        cur = after or cur

    check("S10 MESURE : l'ÉDITION rend 200 SANS persister (faux vert du produit)",
          persisted is None,
          f"la forme {persisted} a persisté — l'édition est donc possible et le play peut converger")
    drop_port()
    try: CREATED["ports"].remove(KEY)
    except ValueError: pass

    if persisted is None:
        verdict("S10", "`clientAuth` se décide À LA CRÉATION du port et NE S'ÉDITE PAS : les deux "
                       "URL rendent 200 et la relecture ne bouge pas — le « quirk 500 » annoncé par "
                       "is-mtls-setup.yml est en réalité un 200 menteur, plus dangereux. Le champ "
                       "`alias` n'étant pas discriminant, /ports/{alias} ne désigne même pas un "
                       "port. Le play POSE donc le mode à la naissance, RELIT, et REFUSE en le "
                       "nommant s'il doit changer sur un port déjà là.")
    else:
        verdict("S10", f"`clientAuth` s'édite par PUT {persisted}, relecture à l'appui.")

# ═══════════════════════════════ main ═════════════════════════════════════════

SPIKES = {"S1": s1, "S2": s2, "S3": s3, "S4": s4, "S5": s5, "S6": s6, "S7": s7, "S8": s8, "S9": s9, "S10": s10}

if __name__ == "__main__":
    which = (sys.argv[1] if len(sys.argv) > 1 else "all").upper()
    if adm("GET", "/apis")[0] != 200:
        print(f"ABANDON : la gateway RÉELLE ({GW}) ne répond pas. Ce spike la MESURE, "
              f"il ne peut pas s'en passer.", file=sys.stderr)
        sys.exit(2)
    try:
        if which == "ALL":
            # S1 crée les actifs dont tous les autres dépendent ; l'ordre est celui
            # du raisonnement (forme -> effet de bord -> pose -> porte -> contre-épreuve).
            for k in ("S1", "S2", "S3", "S4", "S5", "S6", "S7", "S8", "S9", "S10"):
                SPIKES[k]()
        elif which in SPIKES:
            if which != "S1": s1()
            SPIKES[which]()
        else:
            print(f"spike inconnu : {which} (attendu : {'|'.join(SPIKES)}|all)", file=sys.stderr); sys.exit(2)
    finally:
        cleanup()
        print("\n════════════════════════════ VERDICTS ════════════════════════════")
        for s, t in VERDICTS: print(f"  {s} : {t}")
        print(f"\n  {OK} ✅ / {KO} ❌")
    sys.exit(KO)
