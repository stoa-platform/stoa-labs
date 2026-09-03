#!/usr/bin/env python3
"""apply-selfservice-application.py — APPLY ENGINE self-service (ADR-078).

Crée/converge une Application consommatrice sur webMethods API Gateway 10.15 à
partir d'un manifeste de demande, avec :
  - plan ENTRANT opposé : certificat client (identifier httpsCertificate DANS
    l'asset application) + plage IP (identifier ipAddressRange), tous deux
    ENFORCÉS par une règle d'identification IAM (applicationLookup=strict) —
    ferme le fail-open « identifier écrit mais non opposé » ;
  - plan SORTANT : injection de la clé backend par customHttpHeaders (P-callout),
    la valeur ${backend_apikey} étant résolue au runtime par le package IS
    TokenProvider depuis Vault (clé jamais sur la gateway, jamais chez le
    consommateur). Ce script POSE le câblage ; la résolution Vault est faite par
    le TokenProvider (déploiement IS = résidu manuel, cf. DELIVERY-PROCESS.md).

PROTOTYPE : cible = fold-in dans `labctl apply-consumer` (Go). Shapes REST
épinglées live sur la 10.15 (mémoire wm-1015-rest-shapes, spikes 2026-07-14/15).

Config (env) :
  WM_ADMIN_URL   base admin REST (défaut http://localhost:5555/rest/apigateway ;
                 dans Jenkins : http://webmethods-real:5555/rest/apigateway)
  WM_USER/WM_PASS  compte de service gateway (en CI : lus depuis Vault)
Usage : apply-selfservice-application.py <manifest.json> [--verify-ip]
  Le manifeste porte `api_version` (OBLIGATOIRE depuis A5, 2026-09-03) : la
  résolution est nom + version + isActive, refus nommés AVANT tout POST
  (API_NOT_PROMOTED / API_VERSION_MISMATCH / API_AMBIGUE / API_INACTIVE).
"""
import json, urllib.request, base64, sys, os, re, time

WM   = os.environ.get("WM_ADMIN_URL", "http://localhost:5555/rest/apigateway").rstrip("/")
USER = os.environ.get("WM_USER", "Administrator")
PASS = os.environ.get("WM_PASS", "manage")
AUTH = "Basic " + base64.b64encode(f"{USER}:{PASS}".encode()).decode()

def call(method, url, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Accept", "application/json"); req.add_header("Authorization", AUTH)
    if body is not None: req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read().decode()
            try: return r.status, json.loads(raw)
            except: return r.status, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try: return e.code, json.loads(raw)
        except: return e.code, raw

def deep(o, k):
    if isinstance(o, dict):
        for kk, v in o.items():
            if kk == k: return v
            x = deep(v, k)
            if x is not None: return x
    elif isinstance(o, list):
        for v in o:
            x = deep(v, k)
            if x is not None: return x
    return None

def unwrap_app(r):
    return r.get("applications", [r])[0] if isinstance(r, dict) and "applications" in r else r

def find_action_id(name):
    """id d'une policyAction par son nom d'affichage, ou None (idempotence)."""
    _, r = call("GET", f"{WM}/policyActions")
    for p in (r.get("policyAction", []) if isinstance(r, dict) else []):
        if (p.get("names") or [{}])[0].get("value", "") == name:
            return p.get("id")
    return None

def ensure_action(name, action_body):
    """POST si absent, PUT si présent (converge en place). Renvoie l'id."""
    aid = find_action_id(name)
    action = action_body["policyAction"]
    action["names"] = [{"value": name, "locale": "en"}]
    if aid:
        action["id"] = aid
        call("PUT", f"{WM}/policyActions/{aid}", action_body)
        return aid
    c, r = call("POST", f"{WM}/policyActions", action_body)
    return (r.get("policyAction") or {}).get("id") or (r.get("id") if isinstance(r, dict) else None)

def cert_der_body(pem):
    m = re.search(r"-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----", pem, re.S)
    if not m: raise SystemExit("publicCertRef: aucun bloc CERTIFICATE PEM")
    if "PRIVATE KEY" in pem.upper(): raise SystemExit("publicCertRef porte une clé privée : refusé")
    return "".join(m.group(1).split())

PASS_N, TOTAL_N = 0, 0
def check(label, ok):
    global PASS_N, TOTAL_N
    ok = bool(ok); TOTAL_N += 1; PASS_N += 1 if ok else 0
    print(f"   [{'✓' if ok else '✗'}] {label}")
    return ok

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    if not args: raise SystemExit("usage: apply-selfservice-application.py <manifest.json> [--verify-ip]")
    m = json.load(open(args[0]))
    name       = m["name"]
    api_name   = m["api"]
    ip_allow   = m.get("ipAllowlist", [])
    cert_ref   = m.get("publicCertRef")
    backend    = m.get("backend", {})
    hdr_name   = backend.get("header", "apikey")
    hdr_value  = backend.get("valueTemplate", "${backend_apikey}")   # résolu par le TokenProvider(Vault)

    print(f"=== apply self-service application '{name}' → API '{api_name}' ({WM})")

    # A5 — LA PORTE : l'API est-elle AU PALIER (ce nom, cette version, ACTIVE) ?
    # Même prédicat, mêmes tags que le rôle Ansible (la chaîne) — AVANT tout
    # POST : une souscription posée puis retirée brûle la paire (spike S1-T3).
    def refus(tag, msg):
        print(f"REFUS: {tag} : {msg}"); sys.exit(1)
    api_ver = str(m.get("api_version") or "")
    if not api_ver: refus("CABLAGE_INCOMPLET", "api_version absent du manifeste — la résolution par nom seul n'est plus admise (A5)")
    _, r = call("GET", f"{WM}/apis")
    apis = [e.get("api", {}) for e in (r.get("apiResponse", []) if isinstance(r, dict) else [])]
    by_name = [a for a in apis if a.get("apiName") == api_name]
    match = [a for a in by_name if str(a.get("apiVersion")) == api_ver]
    if not by_name: refus("API_NOT_PROMOTED", f"l'API '{api_name}' n'est pas sur {WM} (aucune version publiée) — la promouvoir d'abord ; rien n'a été écrit")
    if not match: refus("API_VERSION_MISMATCH", f"l'API '{api_name}' est présente en version(s) {', '.join(str(a.get('apiVersion')) for a in by_name)}, pas en '{api_ver}' ; rien n'a été écrit")
    if len(match) > 1: refus("API_AMBIGUE", f"{len(match)} entrées '{api_name}' v{api_ver} — résolution impossible sans choisir ; rien n'a été écrit")
    if match[0].get("isActive") is not True: refus("API_INACTIVE", f"l'API '{api_name}' v{api_ver} est INACTIVE (isActive={match[0].get('isActive')!r}, id={match[0].get('id')}) — une souscription à une API inactive est une souscription à rien ; rien n'a été écrit")
    api_id = match[0].get("id")
    check(f"API '{api_name}' v{api_ver} active résolue (id={api_id})", api_id)

    # 1) application (idempotent par nom)
    _, r = call("GET", f"{WM}/applications")
    app_id = next((a["id"] for a in r.get("applications", []) if a.get("name") == name), None)
    if not app_id:
        c, r = call("POST", f"{WM}/applications",
                    {"name": name, "description": m.get("description", "self-service (ADR-078)"),
                     "contactEmails": m.get("contactEmails", [])})
        app_id = unwrap_app(r).get("id")
    check(f"application '{name}' (id={app_id})", bool(app_id))
    call("PUT", f"{WM}/applications/{app_id}/apis", {"apiIDs": [api_id]})

    # 2) identifiers ENTRANTS : certificat (asset) + IP
    _, r = call("GET", f"{WM}/applications/{app_id}")
    a = unwrap_app(r)
    ids = [i for i in (a.get("identifiers") or []) if i.get("key") not in ("httpsCertificate", "ipAddressRange")]
    id_types = []
    if cert_ref:
        pem = cert_ref if "BEGIN CERT" in cert_ref else open(cert_ref).read()
        ids.append({"key": "httpsCertificate", "name": "client-cert", "value": [cert_der_body(pem)]})
        id_types.append("httpsCertificate")
    if ip_allow:
        ids.append({"key": "ipAddressRange", "name": "ip-allowlist", "value": ip_allow})
        id_types.append("ipAddressRange")
    a["identifiers"] = ids
    call("PUT", f"{WM}/applications/{app_id}", a)
    _, r = call("GET", f"{WM}/applications/{app_id}")
    keys = {i.get("key") for i in (unwrap_app(r).get("identifiers") or [])}
    if cert_ref: check("certificat client = identifier httpsCertificate DANS L'ASSET (read-back)", "httpsCertificate" in keys)
    if ip_allow: check("plage IP = identifier ipAddressRange dans l'asset (read-back)", "ipAddressRange" in keys)

    # --- idempotence CLÉE SUR LA POLICY : on réutilise l'action déjà attachée au
    #     stage (pas le nom — robuste aux doublons). wM impose UNE seule action
    #     customHttpHeaders par API (409 sinon), d'où le PUT-en-place.
    _, r = call("GET", f"{WM}/apis/{api_id}")
    pol_id = deep(r, "policies")[0]
    _, r = call("GET", f"{WM}/policies/{pol_id}")
    pol = r.get("policy", r)
    def attached_id_in_stage(stage_key, template_key):
        for s in pol.get("policyEnforcements", []):
            if s.get("stageKey") != stage_key: continue
            for e in s.get("enforcements", []):
                eid = e.get("enforcementObjectId")
                _, ar = call("GET", f"{WM}/policyActions/{eid}")
                act = ar.get("policyAction", ar)
                if act.get("templateKey") == template_key: return eid
        return None

    # 3) règle IAM (plan entrant) : AND des identifiers présents, applicationLookup=strict
    rules = [{"templateKey": "IdentificationRule", "parameters": [
                {"templateKey": "applicationLookup",  "values": ["strict"]},
                {"templateKey": "identificationType", "values": [t]}]} for t in id_types]
    iam = {"policyAction": {"names": [{"value": f"identify ({api_name})", "locale": "en"}],
        "templateKey": "evaluatePolicy",
        "parameters": [{"templateKey": "logicalConnector", "values": ["AND"]},
                       {"templateKey": "allowAnonymous", "values": ["false"]}, *rules],
        "active": True}}
    iam_id = attached_id_in_stage("IAM", "evaluatePolicy")
    if iam_id:
        iam["policyAction"]["id"] = iam_id; call("PUT", f"{WM}/policyActions/{iam_id}", iam)
    else:
        _, rr = call("POST", f"{WM}/policyActions", iam); iam_id = (rr.get("policyAction") or {}).get("id") or rr.get("id")
    check(f"règle IAM AND({'+'.join(id_types)}) strict (converge)", bool(iam_id))

    # 4) plan SORTANT : customHttpHeaders injecte la clé backend (P-callout)
    hdr = {"policyAction": {"names": [{"value": f"inject-backend-key ({api_name})", "locale": "en"}],
        "templateKey": "customHttpHeaders",
        "parameters": [{"templateKey": "header", "parameters": [
            {"templateKey": "headerKey", "values": [hdr_name]},
            {"templateKey": "headerValue", "values": [hdr_value]}]}],
        "active": True}}
    hdr_id = attached_id_in_stage("routing", "customHttpHeaders")
    if hdr_id:
        hdr["policyAction"]["id"] = hdr_id; call("PUT", f"{WM}/policyActions/{hdr_id}", hdr)
    else:
        _, rr = call("POST", f"{WM}/policyActions", hdr); hdr_id = (rr.get("policyAction") or {}).get("id") or rr.get("id")
    check(f"injection clé backend customHttpHeaders '{hdr_name}={hdr_value}' (P-callout)", bool(hdr_id))

    # 5) attache IAM (stage en tête) + customHttpHeaders (routing, dédupliqué)
    stages = [s for s in (pol.get("policyEnforcements") or []) if s.get("stageKey") != "IAM"]
    for s in stages:
        if s.get("stageKey") == "routing":
            others = [e for e in (s.get("enforcements") or []) if e.get("enforcementObjectId") != hdr_id]
            s["enforcements"] = others + [{"enforcementObjectId": hdr_id, "order": None}]
    stages.insert(0, {"stageKey": "IAM", "enforcements": [{"enforcementObjectId": iam_id, "order": None}]})
    pol["policyEnforcements"] = stages
    c, resp = call("PUT", f"{WM}/policies/{pol_id}", {"policy": pol})
    if not check("policy convergée (IAM strict + injection backend attachés)", c == 200):
        print(f"       (PUT /policies → {c}: {str(resp)[:300]})")

    # 6) PREUVE optionnelle : la branche IP est réellement OPPOSÉE (fail-open fermé).
    #    NB : un AND(cert,IP) ne se teste PAS en clair — le certificat n'étant pas
    #    présenté sur HTTP, la branche cert échoue toujours (401). On isole donc la
    #    branche IP (rule IP-only le temps du test), puis on RESTAURE le AND(cert,IP).
    #    Le handshake mTLS complet exige le listener HTTPS client-auth (étape suivante).
    if "--verify-ip" in flags and ip_allow:
        gw = WM.replace("/rest/apigateway", "") + f"/gateway/{api_name}/1.0.0/accounts"
        def hit():
            try:
                with urllib.request.urlopen(gw, timeout=15) as x: return x.status
            except urllib.error.HTTPError as e: return e.code
        def put_iam(types):
            rr = [{"templateKey": "IdentificationRule", "parameters": [
                     {"templateKey": "applicationLookup", "values": ["strict"]},
                     {"templateKey": "identificationType", "values": [t]}]} for t in types]
            body = {"policyAction": {"id": iam_id, "names": [{"value": f"identify ({api_name})", "locale": "en"}],
                "templateKey": "evaluatePolicy",
                "parameters": [{"templateKey": "logicalConnector", "values": ["AND"]},
                               {"templateKey": "allowAnonymous", "values": ["false"]}, *rr], "active": True}}
            call("PUT", f"{WM}/policyActions/{iam_id}", body)
        put_iam(["ipAddressRange"]); time.sleep(2)              # isole la branche IP
        c_in = hit()
        _, r = call("GET", f"{WM}/applications/{app_id}"); a = unwrap_app(r)
        saved = next((i["value"] for i in a["identifiers"] if i["key"] == "ipAddressRange"), None)
        for i in a["identifiers"]:
            if i["key"] == "ipAddressRange": i["value"] = ["10.0.0.1-10.0.0.5"]
        call("PUT", f"{WM}/applications/{app_id}", a); time.sleep(2)
        c_out = hit()
        for i in a["identifiers"]:
            if i["key"] == "ipAddressRange": i["value"] = saved   # restaure l'IP
        call("PUT", f"{WM}/applications/{app_id}", a)
        put_iam(id_types)                                        # restaure le AND(cert,IP)
        check(f"IP autorisée → {c_in} (200 attendu)", c_in == 200)
        check(f"IP hors plage → {c_out} (403 attendu : FAIL-OPEN FERMÉ)", c_out == 403)
        print("   (i) AND(cert,IP) restauré ; handshake mTLS complet = listener HTTPS client-auth, étape suivante.")

    print(f"\nRÉSULTAT : {PASS_N}/{TOTAL_N} PASS")
    print("plan entrant (cert+IP) OPPOSÉ ; plan sortant (clé backend) câblé — "
          "résolution Vault par le TokenProvider IS (résidu manuel).")
    sys.exit(0 if PASS_N == TOTAL_N else 1)

if __name__ == "__main__":
    main()
