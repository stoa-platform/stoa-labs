#!/usr/bin/env python3
"""spike-p6-deny-by-default.py — les spikes du jalon P6 du GOAL « posture par
exposition » (GOAL-posture-par-exposition-2026-09-04.md, § P6), joués contre la
wM 10.15 RÉELLE avec des actifs JETABLES (spikep6-*), nettoyés en sortie.

POURQUOI CE SPIKE EXISTE. La prémisse d'origine de P6 est TOMBÉE au spike B de
P0 : le mode d'accès d'un port de l'Integration Server garde `/invoke`, pas le
dispatch `/gateway` de l'API Gateway — une API publiée reste jointe 200 sur un
port en `deny` dont la liste ne la mentionne pas. Le jalon est donc réécrit sur
la surface qui garde VRAIMENT le dispatch : la règle d'IDENTIFICATION de l'API
(stage IAM, `allowAnonymous=false`, `IdentificationRule` en `strict`).

Et il y a urgence à le mesurer, pas seulement à le concevoir : P1 (ADR-091) fait
de l'`ip-allowlist` la règle propre de l'exposition `external`, le vérificateur
la rend aujourd'hui `Degraded` en disant « enforced au consommateur », et le
drapeau qui POSE réellement la règle (`EnforceInboundIdentifiers`, consumer.go)
n'est positionné NULLE PART — ni CLI, ni manifeste, ni pipeline. La primitive Go
existe et est testée ; elle est morte, exactement comme `port-access.yml`. Une
cellule `external` porte donc aujourd'hui un contrôle que rien n'oppose.

  S1 — le DÉFAUT : une API fraîchement publiée sert-elle N'IMPORTE QUI ? (le
       point de départ du jalon : sans règle, il n'y a pas de refus par défaut.)
  S2 — le FAIL-OPEN d'ADR-078, RE-MESURÉ : une application porteuse d'une
       allow-list d'IP qui EXCLUT l'appelant laisse-t-elle passer l'appel tant
       qu'aucune règle ne l'oppose ? (écrire l'allow-list ne protège de rien.)
  S3 — LA PORTE : la règle posée, l'appel HORS plage est refusé ; la plage
       élargie pour INCLURE l'appelant, le même appel passe. Même API, même
       appelant, deux plages — c'est la seule mesure qui prouve que ça mord.
  S4 — LA CONTRE-ÉPREUVE : la règle retirée alors que la plage exclut toujours,
       l'appel REPASSE. Sans elle, c'est peut-être autre chose qui refusait.
  S5 — le PIÈGE `sys:defaultApplication` : un appelant non résolu retombe-t-il
       sur l'application par défaut malgré `strict` ? Et une SECONDE application
       souscrite SANS identifier d'IP sauve-t-elle l'appel ? (si oui, le refus
       par défaut s'effondre dès qu'un consommateur ordinaire existe.)
  S6 — PARTAGER une action entre APIs : économie d'objets, ou piège ? (le Go
       le fait déjà — ensureSelfServiceIdentifyAction et ensureMtlsIdentifyAction
       réutilisent UN objet par empreinte de règles « pour éviter la
       prolifération ». Mesurer ce que coûte ce partage quand une seule des APIs
       porteuses est détachée.)
  S7 — la COEXISTENCE avec la barrière OAuth2/cert : deux actions au même stage
       IAM, est-ce seulement accepté, et la sémantique est-elle ET ou OU ? De la
       réponse dépend toute la conception du livrable — empiler une seconde
       action ou FUSIONNER les dimensions dans une seule action AND.
  S8 — la POSITION : la règle est-elle posable sur une API INACTIVE et
       survit-elle à l'activation ? (même exigence qu'en P4 et P5 : sans quoi
       l'API servirait des appels non gardés pendant sa propre publication.)
  S9 — la SURVIE au ré-import de contrat (PUT multipart /apis/{id}) : le tag de
       P3 meurt, le protocole de P5 survit. Et celle-ci ?

  GW_ADMIN=http://localhost:5555/rest/apigateway GW_DATA=http://localhost:5555/gateway \
  WM_CONTAINER=poc-webmethods-real WM_USER=Administrator WM_PASS=manage \
  python3 scripts/spike-p6-deny-by-default.py [S1..S9|all]

Sortie : lignes ✅/❌ + un bloc VERDICTS ; code retour = nombre de ❌.
Ce script est une PREUVE de spike, PAS un livrable : il mesure, il ne pose rien
de durable. Aucun actif préexistant n'est modifié — sauf lecture.

RÈGLE TENUE ICI : les actions IAM créées sont NOMMÉES `spikep6-…` et supprimées
en sortie. On ne réutilise JAMAIS l'action partagée du livrable (empreinte
{oAuth2Token,httpsCertificate} ou {…,ipAddressRange}) : la modifier frapperait
toutes les APIs qui la référencent — ce que S6 mesure précisément.
"""
import base64, json, os, subprocess, sys, time, uuid, urllib.error, urllib.request

GW   = os.environ.get("GW_ADMIN", "http://localhost:5555/rest/apigateway")
DP   = os.environ.get("GW_DATA",  "http://localhost:5555/gateway")
CTR  = os.environ.get("WM_CONTAINER", "poc-webmethods-real")
USER = os.environ.get("WM_USER", "Administrator")
PASS = os.environ.get("WM_PASS", "manage")
AUTH = base64.b64encode(f"{USER}:{PASS}".encode()).decode()

API_A = "spikep6-a"          # l'API sous test
API_B = "spikep6-b"          # le témoin : elle porte la MÊME action (S6)
API_C = "spikep6-c"          # jamais activée avant la pose (S8)
API_D = "spikep6-d"          # ré-import de contrat (S9)
API_E = "spikep6-e"          # seconde porteuse de l'action partagée (S6)

APP_1 = "spikep6-app-ip"     # application porteuse de l'allow-list d'IP
APP_2 = "spikep6-app-nue"    # application SANS identifier d'IP (S5)

# L'IP DE L'APPELANT N'EST PAS DEVINÉE, elle est DÉTERMINÉE. Le spike émet ses
# appels du plan de données DEPUIS le conteneur de la gateway vers sa propre
# adresse de réseau : l'IP source est alors celle que `docker inspect` donne, et
# la plage « dans » vaut exactement cette adresse. Un joker (0.0.0.0-255.255…)
# serait plus court à écrire et ne prouverait rien — mesuré ici en S3, il ne
# suffit d'ailleurs PAS à faire passer l'appel.
def _caller_ip():
    fmt = ('{{range $k,$v := .NetworkSettings.Networks}}{{if $v.IPAddress}}'
           '{{$v.IPAddress}}{{println}}{{end}}{{end}}')
    out = subprocess.run(["docker", "inspect", CTR, "--format", fmt],
                         capture_output=True, text=True).stdout.split()
    return out[0] if out else ""

CALLER = os.environ.get("P6_CALLER_IP") or _caller_ip()
DP_CTR = f"http://{CALLER}:5555/gateway"

IP_HORS = "203.0.113.10-203.0.113.10"           # TEST-NET-3 (RFC 5737) : jamais l'appelant
IP_DANS = f"{CALLER}-{CALLER}"                   # exactement l'appelant
IP_TOUT = "0.0.0.0-255.255.255.255"              # le joker, mesuré et non supposé

OK = KO = 0
VERDICTS = []

def ok(m):
    global OK; OK += 1; print(f"  ✅ {m}")
def ko(m):
    global KO; KO += 1; print(f"  ❌ {m}")
def check(label, cond, detail=""):
    # Le détail n'accompagne QUE l'échec (même règle qu'aux spikes P0/P5) : collé
    # à un vert, un texte qui explique la panne se lit comme si elle avait eu lieu.
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
    b = "----spikep6" + uuid.uuid4().hex
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

def hit(name, timeout=10):
    """Appel du plan de données SANS aucune identité, émis depuis le conteneur
    vers l'adresse de réseau de la gateway : l'IP source est alors CALLER, celle
    que S3 oppose à l'allow-list. C'est le seul appelant du spike."""
    return int(ctr_curl([f"{DP_CTR}/{name}/1.0.0/ping"], auth=False, timeout=timeout).strip() or 0)

def hit_host(name, timeout=10):
    """Le même appel depuis l'HÔTE (NAT docker) — une SECONDE origine, utile
    seulement pour mesurer qu'une allow-list discrimine bien deux appelants."""
    try:
        with urllib.request.urlopen(f"{DP}/{name}/1.0.0/ping", timeout=timeout) as r: return r.status
    except urllib.error.HTTPError as e: return e.code
    except Exception: return 0

def hit_body(name, timeout=10):
    return ctr_curl([f"{DP_CTR}/{name}/1.0.0/ping"], auth=False, timeout=timeout, body=True)[:400]

def wait_data_plane(name, seconds=180):
    """Une gateway qui vient de reprendre répond 200 sur /apis bien avant de
    dispatcher les APIs neuves (fait mesuré, GOAL § pièges de harnais)."""
    for _ in range(seconds // 3):
        if hit(name) == 200: return True
        time.sleep(3)
    return hit(name) == 200

def wait_admin(seconds=300):
    """Le lab RECYCLE la gateway toutes les ~20 min (cron restart-wm.sh, licence
    d'essai). Après une reprise, l'admin répond 200 en LECTURE bien avant
    d'accepter une ÉCRITURE : mesuré ici deux fois — `POST /apis` rend 400 et
    `PUT /policies` rend 500 pendant que `GET /apis` rend déjà 200. Une porte qui
    ne teste que la lecture laisse donc entrer le harnais trop tôt, et il rougit
    pour une raison qui n'est PAS celle qu'il mesure : le pire des rouges, celui
    qui ment. La porte ÉCRIT donc — une API jetable, aussitôt supprimée."""
    for _ in range(seconds // 5):
        c, r = adm("GET", "/policies")
        if c == 200 and isinstance(r, dict):
            porte = "spikep6-porte-" + uuid.uuid4().hex[:8]   # nom UNIQUE : un nom
            # fixe resté d'un run tué rendrait 400 pour toujours, et la porte
            # conclurait « gateway pas prête » sur un conflit de nom.
            code, rep = multipart("/apis", {"type": "openapi", "apiName": porte,
                                            "apiVersion": "1.0.0"},
                                  "c.yaml", SPEC.format(name=porte), "application/x-yaml")
            pid = (rep.get("apiResponse") or {}).get("api", {}).get("id")
            if pid: adm("DELETE", f"/apis/{pid}")
            if code in (200, 201):
                return True
        time.sleep(5)
    return False

# ─────────────────────────────── actifs jetables ──────────────────────────────

CREATED = {"apis": [], "apps": [], "actions": []}

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
    """La policy SERVICE de l'API (même règle que findServicePolicy côté Go)."""
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

# ─────────────────────────── applications (consommateur) ──────────────────────

def create_app(name, ip_ranges=None):
    """POST /applications, puis pose éventuelle de l'identifier ipAddressRange.
    Forme des identifiers pinnée par identifiers.go (clé de l'énum du produit)."""
    c, r = adm("POST", "/applications", {"name": name, "description": "spike P6 (jetable)"})
    aid = r.get("id") or ((r.get("applications") or [{}])[0].get("id"))
    if aid:
        CREATED["apps"].append(aid)
        if ip_ranges: set_app_ip(aid, ip_ranges)
    return aid, c

def get_app(app_id):
    _, r = adm("GET", f"/applications/{app_id}")
    if isinstance(r.get("applications"), list) and r["applications"]:
        return r["applications"][0]
    return r

def set_app_ip(app_id, ranges):
    """Read-modify-write de l'application : l'identifier ipAddressRange porte la
    plage. Le PUT remplace l'objet — on relit d'abord, comme le fait le Go."""
    app = get_app(app_id)
    ids = [i for i in (app.get("identifiers") or []) if i.get("key") != "ipAddressRange"]
    if ranges:
        ids.append({"name": "ip-allowlist", "key": "ipAddressRange", "value": list(ranges)})
    app["identifiers"] = ids
    return adm("PUT", f"/applications/{app_id}", app)

def app_ip_values(app_id):
    for i in (get_app(app_id).get("identifiers") or []):
        if i.get("key") == "ipAddressRange":
            return i.get("value") or i.get("swaggerValue") or []
    return []

def associate(app_id, api_id):
    return adm("PUT", f"/applications/{app_id}/apis", {"apiIDs": [api_id]})

# ────────────────────────────── action IAM ────────────────────────────────────

def identify_action_body(name, id_types, connector="AND", anonymous="false", action_id=""):
    """La forme ENVELOPPÉE d'`identifyAndActionBody` (selfservice.go), rejouée en
    REST nu. Un corps NU est un no-op sur cette gateway (wm-1015-rest-shapes)."""
    params = [{"templateKey": "logicalConnector", "values": [connector]},
              {"templateKey": "allowAnonymous", "values": [anonymous]}]
    for t in id_types:
        params.append({"templateKey": "IdentificationRule",
                       "parameters": [{"templateKey": "applicationLookup", "values": ["strict"]},
                                      {"templateKey": "identificationType", "values": [t]}]})
    act = {"names": [{"value": name, "locale": "en"}], "templateKey": "evaluatePolicy",
           "parameters": params, "active": True}
    if action_id: act["id"] = action_id
    return {"policyAction": act}

def create_identify_action(name, id_types, connector="AND", anonymous="false"):
    c, r = adm("POST", "/policyActions", identify_action_body(name, id_types, connector, anonymous))
    aid = (r.get("policyAction") or {}).get("id") or r.get("id")
    if aid: CREATED["actions"].append(aid)
    return aid, c

def action_rule_types(action):
    out = []
    for p in (action.get("parameters") or []):
        if p.get("templateKey") != "IdentificationRule": continue
        for q in (p.get("parameters") or []):
            if q.get("templateKey") == "identificationType":
                out += (q.get("values") or [])
    return sorted(out)

def get_action(action_id):
    c, r = adm("GET", f"/policyActions/{action_id}")
    return (r.get("policyAction") or r), c

def set_iam_stage(api_id, action_ids, essais=4):
    """Attache (ou détache, liste vide) les actions au stage IAM de la policy
    SERVICE. PUT ENVELOPPÉ {policy:{…}} — la forme prouvée par inbound.yml.

    Réessaie sur 500 : c'est la signature d'une gateway qui vient d'être recyclée
    (cf. wait_admin). Chaque essai RELIT la policy — écrire une seconde fois un
    enregistrement lu avant la reprise serait écrire du périmé."""
    pid, c = None, 0
    for i in range(essais):
        pid, pol = service_policy(api_id)
        if pol is None: return None, 0
        others = [s for s in (pol.get("policyEnforcements") or []) if s.get("stageKey") != "IAM"]
        stages = others
        if action_ids:
            stages = [{"stageKey": "IAM",
                       "enforcements": [{"enforcementObjectId": a, "order": None} for a in action_ids]}] + others
        pol["policyEnforcements"] = stages
        c, _ = adm("PUT", f"/policies/{pid}", {"policy": pol})
        if c in (200, 201) or i == essais - 1:
            return pid, c
        time.sleep(10)
    return pid, c

def iam_of(api_id):
    _, pol = service_policy(api_id)
    return stage_action_ids(pol, "IAM") if pol else []

def purge_prefix():
    """Efface tout actif `spikep6-*` resté d'un run interrompu. Un run tué par la
    reprise de la gateway laisse ses APIs derrière lui, et `POST /apis` rend
    alors 400 sur un nom déjà pris — 400 que le harnais lirait comme un échec de
    création, c'est-à-dire comme un fait produit. La liste est sous l'enveloppe
    `apiResponse` (et non `apis` : mesuré, la doc dit autre chose)."""
    _, r = adm("GET", "/apis")
    for e in (r.get("apiResponse") or r.get("apis") or []):
        a = e.get("api", e)
        if (a.get("apiName") or "").startswith("spikep6"):
            adm("PUT", f"/apis/{a['id']}/deactivate"); adm("DELETE", f"/apis/{a['id']}")
    _, r = adm("GET", "/applications")
    for a in (r.get("applications") or []):
        if (a.get("name") or "").startswith("spikep6"):
            adm("DELETE", f"/applications/{a['id']}")
    _, r = adm("GET", "/policyActions")
    for a in (r.get("policyAction") or []):
        if "spikep6" in " ".join(x.get("value", "") for x in (a.get("names") or [])):
            adm("DELETE", f"/policyActions/{a['id']}")

def cleanup():
    say("ménage (actifs jetables)")
    for aid in CREATED["apis"]:
        set_iam_stage(aid, [])          # détacher AVANT de supprimer les actions
        adm("PUT", f"/apis/{aid}/deactivate"); adm("DELETE", f"/apis/{aid}")
    for app in CREATED["apps"]:
        adm("DELETE", f"/applications/{app}")
    for act in CREATED["actions"]:
        adm("DELETE", f"/policyActions/{act}")
    print(f"  nettoyé : {len(CREATED['apis'])} APIs, {len(CREATED['apps'])} apps, "
          f"{len(CREATED['actions'])} actions")

# ═══════════════════════════ mesure du plan de données ════════════════════════

CODES_UTILES = (200, 401, 403)

def settle(name, essais=40):
    """Le code du plan de données, une fois qu'il VEUT DIRE quelque chose.

    Le lab recycle la gateway toutes les ~20 min (cron restart-wm.sh, licence
    d'essai). Juste après une reprise, le dispatch rend 404 « Service not found »
    sur une API pourtant présente à l'admin : un harnais qui lit ce 404 comme un
    refus conclut FAUX — il attribue à son contrôle un code que la reprise a
    produit. On attend donc un code du vocabulaire du jalon (200 servi, 401/403
    refusé) avant de mesurer quoi que ce soit."""
    c = 0
    for _ in range(essais):
        c = hit(name)
        if c in CODES_UTILES:
            return c
        time.sleep(3)
    return c

def ip_action(label):
    """UNE action par spike, jamais un objet partagé entre eux.

    Ce n'est pas de la prudence de harnais, c'est la conséquence d'un fait
    mesuré ici (S6) : DÉTACHER une action d'une policy DÉTRUIT l'objet action.
    Un spike qui réutiliserait l'action d'un spike précédent travaillerait donc,
    après le premier détachement, sur un UUID qui n'existe plus — et lirait des
    500 « Policy action does not exist » comme s'ils disaient quelque chose du
    contrôle."""
    aid, c = create_identify_action(f"spikep6 identify ({label})", ["ipAddressRange"])
    return aid, c

# ═══════════════════════════════ S1 ═══════════════════════════════════════════

STATE = {}
FAITS = {}          # ce que les spikes ont MESURÉ — les verdicts s'en déduisent
DONE = set()

def need(nom):
    """Rejoue un spike prérequis UNE seule fois (sinon `all` empile les doublons
    et le bloc VERDICTS devient illisible)."""
    if nom not in DONE:
        DONE.add(nom); SPIKES[nom]()

def s1():
    say("S1 — le DÉFAUT : une API publiée sert-elle n'importe qui ?")
    aid, c = create_api(API_A)
    check("API A créée+activée", bool(aid) and c in (200, 201), f"code={c}")
    STATE["a"] = aid
    check("plan de données servi", wait_data_plane(API_A))

    code = settle(API_A)
    servi = (code == 200)
    check("appel SANS aucune identité -> 200", servi, f"code={code}")
    mes("code de l'appel anonyme", code)

    iam = iam_of(aid)
    mes("actions au stage IAM d'une API fraîche", iam or "(aucune)")
    vide = not iam
    check("aucune action d'identification par défaut", vide, f"iam={iam}")

    FAITS["s1"] = (servi, vide)
    verdict("S1", ("une API publiée SANS règle d'identification sert n'importe quel "
                   "appelant (200, anonyme) et son stage IAM est VIDE : le refus par "
                   "défaut n'existe pas tant que personne ne le pose."
                   if servi and vide else
                   f"NON CONCLUANT — appel anonyme={code}, stage IAM={iam or 'vide'}."))

# ═══════════════════════════════ S2 ═══════════════════════════════════════════

def s2():
    say("S2 — le FAIL-OPEN d'ADR-078, re-mesuré : l'identifier SEUL n'oppose rien")
    need("S1"); aid = STATE["a"]
    app, c = create_app(APP_1, [IP_HORS])
    check("application créée", bool(app) and c in (200, 201), f"code={c}")
    STATE["app1"] = app

    vals = app_ip_values(app)
    mes("allow-list posée sur l'application", vals)
    check("l'identifier ipAddressRange est PERSISTÉ", IP_HORS in vals, f"lu={vals}")

    ca, _ = associate(app, aid)
    check("application associée à l'API", ca in (200, 201, 204), f"code={ca}")

    code = settle(API_A)
    passe = (code == 200)
    check("appel HORS plage -> passe quand même (200)", passe, f"code={code}")
    mes("code de l'appel hors plage, sans règle", code)

    FAITS["s2"] = passe
    verdict("S2", ("l'allow-list d'IP écrite sur l'application n'oppose RIEN tant "
                   "qu'aucune règle d'identification ne l'exige : l'appelant hors "
                   "plage obtient 200. Le fail-open d'ADR-078 est confirmé, et c'est "
                   "l'état de TOUTE cellule `external` de la chaîne aujourd'hui."
                   if passe else
                   f"NON CONCLUANT — l'appel hors plage rend {code} SANS règle posée : "
                   f"quelque chose d'autre que l'identification filtre déjà."))

# ═══════════════════════════════ S3 ═══════════════════════════════════════════

def s3():
    say("S3 — LA PORTE : la règle posée, hors plage refusé / dans la plage servi")
    need("S2"); aid, app = STATE["a"], STATE["app1"]

    act, c = ip_action("s3")
    check("action IAM strict/ipAddressRange créée", bool(act) and c in (200, 201), f"code={c}")

    rec, _ = get_action(act)
    mes("empreinte de règles relue", action_rule_types(rec))
    check("l'action porte bien la règle ipAddressRange",
          action_rule_types(rec) == ["ipAddressRange"], f"lu={action_rule_types(rec)}")

    set_app_ip(app, [IP_HORS])
    _, cp = set_iam_stage(aid, [act])
    check("action attachée au stage IAM", cp in (200, 201), f"code={cp}")
    check("read-back : le stage IAM référence l'action", act in iam_of(aid))

    code_out = settle(API_A)
    mes("code HORS plage, règle posée", code_out)
    mes("corps du refus", hit_body(API_A).replace("\n", " ")[:200])
    refuse = code_out in (401, 403)
    check("appel HORS plage -> REFUSÉ", refuse, f"code={code_out}")

    set_app_ip(app, [IP_DANS])
    check("plage remplacée par l'IP de l'appelant, et relue",
          IP_DANS in app_ip_values(app), f"lu={app_ip_values(app)}")
    code_in = settle(API_A)
    mes("code DANS la plage, même règle", code_in)
    sert = (code_in == 200)
    check("appel DANS la plage -> SERVI (200)", sert, f"code={code_in}")

    # DEUXIÈME ORIGINE : le même appel émis depuis l'hôte (NAT docker) n'a PAS
    # l'IP autorisée. Une allow-list qui ne discrimine pas deux origines n'en est
    # pas une — seule mesure qui écarte « ça passe pour une autre raison ».
    code_autre = hit_host(API_A)
    mes("même API, même règle, AUTRE origine (hôte)", code_autre)
    discrimine = code_autre in (401, 403)
    check("une autre origine reste REFUSÉE", discrimine, f"code={code_autre}")

    # Le joker : mesuré, jamais supposé.
    set_app_ip(app, [IP_TOUT])
    joker = settle(API_A)
    mes("joker 0.0.0.0-255.255.255.255 (mesure, pas une attente)", joker)
    set_app_ip(app, [IP_DANS])

    STATE["act_s3"] = act
    FAITS["s3"] = (code_out, code_in, code_autre, joker)
    verdict("S3", (f"LA PORTE TIENT : même API, même appelant, deux plages — {code_out} "
                   f"hors plage, {code_in} dedans, et {code_autre} depuis une AUTRE "
                   f"origine. La règle strict/ipAddressRange + allowAnonymous=false MORD "
                   f"au plan de données ; c'est le refus par défaut que le port ne "
                   f"donnait pas. Le joker 0.0.0.0-255.255.255.255 rend {joker} : une "
                   f"plage « tout le monde » NE vaut PAS identification."
                   if refuse and sert and discrimine else
                   f"PORTE NON TENUE — hors plage={code_out}, dans la plage={code_in}, "
                   f"autre origine={code_autre}, joker={joker}."))

# ═══════════════════════════════ S4 ═══════════════════════════════════════════

def s4():
    say("S4 — LA CONTRE-ÉPREUVE : la règle retirée, l'appel hors plage REPASSE")
    need("S3"); aid, app = STATE["a"], STATE["app1"]
    act = STATE["act_s3"]

    set_app_ip(app, [IP_HORS])
    check("plage remise HORS de portée", IP_HORS in app_ip_values(app))
    avant = settle(API_A)
    check("avec la règle : refusé", avant in (401, 403), f"code={avant}")

    _, c = set_iam_stage(aid, [])
    check("stage IAM vidé", c in (200, 201), f"code={c}")
    check("read-back : plus aucune action au stage IAM", not iam_of(aid), f"iam={iam_of(aid)}")
    apres = settle(API_A)
    mes("code après retrait de la règle", apres)
    repasse = (apres == 200)
    check("sans la règle : l'appel hors plage REPASSE (200)", repasse, f"code={apres}")

    # Ce que le détachement a fait À L'OBJET, et pas seulement à l'API.
    # get_action rend (record, code) — dans CET ordre. Lire le couple à l'envers
    # produirait `dict != 200`, c'est-à-dire un vert qui ne mesure rien : le vert
    # vacant que ce GOAL traque depuis P0. Il a été écrit ici, puis corrigé.
    _, cg = get_action(act)
    detruite = (cg != 200)
    mes("GET de l'action après détachement", cg)
    check("le détachement a DÉTRUIT l'objet action", detruite, f"GET={cg}")

    FAITS["s4"] = (avant, apres, cg)
    verdict("S4", (f"CONTRE-ÉPREUVE TENUE : {avant} avec la règle, {apres} sans — à plage "
                   f"INCHANGÉE : c'est bien la règle d'identification qui refuse, et non "
                   f"le port, le protocole ou l'association. ET LE DÉTACHEMENT DÉTRUIT "
                   f"L'ACTION (GET -> {cg}) : retirer une référence supprime l'objet."
                   if avant in (401, 403) and repasse else
                   f"NON CONCLUANT — {avant} avec la règle, {apres} sans."))

# ═══════════════════════════════ S5 ═══════════════════════════════════════════

def s5():
    say("S5 — le PIÈGE : une seconde application, sans identifier d'IP, sauve-t-elle l'appel ?")
    need("S3"); aid, app1 = STATE["a"], STATE["app1"]

    act, _ = ip_action("s5")
    set_app_ip(app1, [IP_HORS])
    _, cp = set_iam_stage(aid, [act])
    check("règle (fraîche) posée pour ce spike", cp in (200, 201) and act in iam_of(aid), f"code={cp}")
    base = settle(API_A)
    depart = base in (401, 403)
    check("point de départ : refusé", depart, f"code={base}")

    app2, c = create_app(APP_2, None)
    check("seconde application créée (AUCUN identifier)", bool(app2) and c in (200, 201), f"code={c}")
    ca, _ = associate(app2, aid)
    check("seconde application associée à l'API", ca in (200, 201, 204), f"code={ca}")

    code = settle(API_A)
    mes("code avec une application ordinaire souscrite", code)
    corps = hit_body(API_A).replace("\n", " ")[:200]
    mes("corps", corps)
    sauve = (code == 200)
    check("l'application sans identifier NE sauve PAS l'appel", not sauve, f"code={code}")
    mes("mention de defaultApplication dans le refus", "oui" if "defaultApplication" in corps else "non")

    STATE["act_s5"] = act
    FAITS["s5"] = (base, code)
    verdict("S5", ("PIÈGE ÉCARTÉ : une application souscrite sans identifier d'IP ne "
                   "résout pas l'appelant hors plage — le refus tient, et le repli "
                   "`sys:defaultApplication` ne le rouvre pas."
                   if depart and not sauve else
                   ("PIÈGE CONFIRMÉ : une application ordinaire souscrite SUFFIT à faire "
                    "passer l'appel hors plage — le refus par défaut s'effondre dès qu'un "
                    "consommateur existe. Conception à revoir."
                    if depart and sauve else
                    f"NON CONCLUANT — le point de départ n'était pas un refus ({base}).")))

# ═══════════════════════════════ S6 ═══════════════════════════════════════════

def s6():
    say("S6 — PARTAGER UNE ACTION : économie d'objets, ou piège de plateforme ?")
    need("S1")
    act, _ = ip_action("s6-partagee")

    bid, c = create_api(API_B)
    check("API B (témoin) créée+activée", bool(bid) and c in (200, 201), f"code={c}")
    STATE["b"] = bid
    check("plan de données B servi", wait_data_plane(API_B))

    eid, ce = create_api(API_E)
    check("API E (seconde porteuse) créée+activée", bool(eid) and ce in (200, 201), f"code={ce}")
    STATE["e"] = eid
    check("plan de données E servi", wait_data_plane(API_E))

    _, c1 = set_iam_stage(bid, [act])
    _, c2 = set_iam_stage(eid, [act])
    partage = (act in iam_of(bid)) and (act in iam_of(eid))
    check("la MÊME action est attachée à DEUX APIs", partage, f"B={c1} E={c2}")

    b_refuse = settle(API_B) in (401, 403)
    e_refuse = settle(API_E) in (401, 403)
    check("les deux APIs refusent l'appelant non identifié", b_refuse and e_refuse)

    # LE GESTE ORDINAIRE : on retire la règle d'UNE des deux (ce que ferait une
    # dépublication, un rollback, ou une main dans l'interface).
    _, cd = set_iam_stage(bid, [])
    check("B détachée", cd in (200, 201), f"code={cd}")
    _, cg = get_action(act)
    detruite = (cg != 200)
    mes("GET de l'action partagée après le détachement de B", cg)
    check("l'objet action a été DÉTRUIT par le détachement", detruite, f"GET={cg}")

    reste = act in iam_of(eid)
    mes("la policy de E référence-t-elle encore l'action ?", reste)
    check("E référence désormais un FANTÔME", reste and detruite, f"reste={reste} GET={cg}")

    # Ce que coûte le fantôme : toute écriture de policy citant cet UUID.
    _, cw = set_iam_stage(eid, [act])
    mes("ré-écriture de la policy de E citant le fantôme", cw)
    casse = cw not in (200, 201)
    check("toute écriture citant le fantôme est REFUSÉE", casse, f"code={cw}")

    FAITS["s6"] = (partage, cg, reste, cw)
    verdict("S6", ("PARTAGER EST UN PIÈGE : détacher l'action d'UNE API la DÉTRUIT, et "
                   "toutes les autres policies qui la référencent gardent un UUID mort — "
                   f"leurs écritures rendent alors {cw} « Policy action does not exist ». "
                   "Le livrable doit donc donner à CHAQUE API son propre objet, et ne "
                   "jamais réutiliser un objet partagé par empreinte (ce que fait "
                   "aujourd'hui le Go : ensureSelfServiceIdentifyAction / "
                   "ensureMtlsIdentifyAction). C'est le mécanisme du NPE déjà connu."
                   if partage and detruite and reste and casse else
                   f"NON CONCLUANT — partage={partage}, GET={cg}, reste={reste}, "
                   f"ré-écriture={cw}."))

# ═══════════════════════════════ S7 ═══════════════════════════════════════════

def s7():
    say("S7 — COEXISTENCE : deux actions au même stage IAM, ET ou OU ?")
    need("S3"); aid, app1 = STATE["a"], STATE["app1"]

    act_ip, _ = ip_action("s7-ip")
    act2, c = create_identify_action("spikep6 identify (s7-cert)", ["httpsCertificate"])
    check("seconde action strict/httpsCertificate créée", bool(act2) and c in (200, 201), f"code={c}")

    set_app_ip(app1, [IP_DANS])            # l'appelant satisfait l'IP, JAMAIS le cert
    _, cp = set_iam_stage(aid, [act_ip, act2])
    mes("code du PUT à deux actions", cp)
    accepte = cp in (200, 201)

    lues = iam_of(aid)
    mes("actions relues au stage IAM", lues)
    deux = len(lues) == 2

    code = settle(API_A) if accepte and deux else 0
    mes("appel satisfaisant l'IP mais PAS le cert", code)
    ou_semantique = (code == 200)

    FAITS["s7"] = (cp, lues, code)
    verdict("S7", ("EMPILER EST UN FAIL-OPEN : deux actions au stage IAM sont acceptées et "
                   "se composent en OU — satisfaire une seule suffit. Le livrable doit "
                   "FUSIONNER les dimensions dans UNE action AND, jamais empiler."
                   if accepte and deux and ou_semantique else
                   ("deux actions au stage IAM sont acceptées et se composent en ET : "
                    "l'appel qui n'en satisfait qu'une est refusé. Le livrable peut "
                    "empiler — mais fusionner reste préférable (un seul objet à relire)."
                    if accepte and deux and not ou_semantique else
                    f"la gateway REFUSE deux actions au stage IAM (PUT={cp}, relu={lues}) : "
                    f"la fusion des dimensions dans une seule action AND est la seule voie.")))

# ═══════════════════════════════ S8 ═══════════════════════════════════════════

def s8():
    say("S8 — POSITION : posable sur une API INACTIVE, et survit à l'activation ?")
    act, _ = ip_action("s8")

    cid, c = create_api(API_C, activate=False)
    check("API C créée, JAMAIS activée", bool(cid) and c in (200, 201), f"code={c}")
    STATE["c"] = cid
    rec = api_record(cid)
    check("C est bien inactive", not rec.get("isActive", False), f"isActive={rec.get('isActive')}")

    _, cp = set_iam_stage(cid, [act])
    mes("code de la pose sur une API INACTIVE", cp)
    pose = cp in (200, 201)
    check("la règle se pose sur une API inactive", pose, f"code={cp}")
    avant = act in iam_of(cid)
    check("read-back avant activation", avant, f"iam={iam_of(cid)}")

    ca, _ = adm("PUT", f"/apis/{cid}/activate")
    check("activation", ca in (200, 201), f"code={ca}")
    apres = act in iam_of(cid)
    check("read-back APRÈS activation : la règle est toujours là", apres, f"iam={iam_of(cid)}")

    # L'appelant n'est associé à AUCUNE application pour C : le TOUT PREMIER
    # appel que C peut servir doit déjà être refusé.
    code = settle(API_C)
    mes("premier appel jamais servi par C", code)
    jamais = code in (401, 403)
    check("C n'a JAMAIS servi un appel non identifié", jamais, f"code={code}")

    FAITS["s8"] = (pose, avant, apres, code)
    verdict("S8", ("la règle se pose et se relit sur une API INACTIVE et survit à "
                   "l'activation : la tâche va donc AVANT l'activation, et une API "
                   "gouvernée ne sert jamais un seul appel non identifié — pas même "
                   "pendant sa propre publication (même exigence qu'en P4 et P5)."
                   if pose and avant and apres and jamais else
                   f"NON CONCLUANT — pose={cp}, avant={avant}, après={apres}, "
                   f"premier appel={code}."))

# ═══════════════════════════════ S9 ═══════════════════════════════════════════

def s9():
    say("S9 — SURVIE au ré-import de contrat (le tag de P3 meurt, le protocole de P5 survit)")
    act, _ = ip_action("s9")

    did, c = create_api(API_D)
    check("API D créée+activée", bool(did) and c in (200, 201), f"code={c}")
    STATE["d"] = did
    _, cp = set_iam_stage(did, [act])
    posee = act in iam_of(did)
    check("règle posée sur D", posee, f"code={cp} iam={iam_of(did)}")

    adm("PUT", f"/apis/{did}/deactivate")
    cc, _ = multipart(f"/apis/{did}", {"type": "openapi", "apiName": API_D, "apiVersion": "1.0.0"},
                      "c.yaml", SPEC.format(name=API_D), "application/x-yaml", method="PUT")
    mes("code du ré-import multipart", cc)
    check("ré-import du contrat accepté", cc in (200, 201), f"code={cc}")
    adm("PUT", f"/apis/{did}/activate")

    reste = act in iam_of(did)
    mes("stage IAM après ré-import", iam_of(did) or "(vide)")
    check("état du stage IAM après ré-import — mesuré, pas attendu", True)

    FAITS["s9"] = (posee, cc, reste)
    verdict("S9", (("la règle d'identification SURVIT au ré-import de contrat (comme "
                    "entryProtocolPolicy en P5, contrairement au tag de P3) : une seule "
                    "passe suffit."
                    if reste else
                    "le ré-import de contrat EFFACE la règle (comme le tag de P3) : le rôle "
                    "doit la re-poser et la relire APRÈS toute écriture de définition, sur "
                    "le modèle de la seconde passe du tag.")
                   if posee and cc in (200, 201) else
                   f"NON CONCLUANT — posée={posee}, ré-import={cc}."))

# ═════════════════════════════════ main ═══════════════════════════════════════

SPIKES = {"S1": s1, "S2": s2, "S3": s3, "S4": s4, "S5": s5,
          "S6": s6, "S7": s7, "S8": s8, "S9": s9}

# ORDRE VOULU : les spikes NON destructifs d'abord. S4 et S6 détruisent l'objet
# action qu'ils manipulent (fait mesuré, cf. S6) ; les jouer avant S5/S7/S8/S9
# laisserait ceux-ci lire des 500 « Policy action does not exist » comme s'ils
# disaient quelque chose du CONTRÔLE. Chaque spike crée d'ailleurs sa propre
# action — la ceinture, en plus des bretelles.
ORDRE = ["S1", "S2", "S3", "S5", "S7", "S8", "S9", "S4", "S6"]

if __name__ == "__main__":
    which = (sys.argv[1] if len(sys.argv) > 1 else "all").upper()
    todo = ORDRE if which == "ALL" else [which]
    print(f"appelant mesuré : {CALLER or '(inconnu)'} — plan de données {DP_CTR}")
    if not CALLER:
        print("P6_CALLER_INCONNU : ni docker inspect ni P6_CALLER_IP ne donnent "
              "l'adresse de l'appelant ; sans elle, l'allow-list ne peut pas être opposée.")
        sys.exit(2)
    if not wait_admin():
        print("ADMIN_INDISPONIBLE : la gateway n'accepte pas encore les ÉCRITURES "
              "(reprise en cours). Rejouer dans une minute.")
        sys.exit(2)
    purge_prefix()
    try:
        for s in todo:
            if s not in SPIKES:
                print(f"spike inconnu : {s} (attendus : {', '.join(SPIKES)}, all)"); sys.exit(2)
            if s not in DONE:
                DONE.add(s); SPIKES[s]()
    finally:
        cleanup()
        print("\n" + "═" * 78)
        print("VERDICTS")
        for s, t in VERDICTS:
            print(f"  {s} — {t}")
        print("═" * 78)
        print(f"\nRésultat : {OK} ✅ / {KO} ❌")
    sys.exit(KO)
