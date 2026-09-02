---
title: "Plan — A3, le credential du seul palier : l'apply d'application lit envs/<env>/wm-admin avec l'identité qui porte apply-<env>"
type: plan
status: "EN COURS 2026-09-02 — T1..T9, exécution inline (un seul écrivain), TDD, preuve par builds réels en T8"
date: 2026-09-02
spec: docs/superpowers/specs/2026-09-02-a3-credential-du-seul-palier-design.md
---

# A3 — plan d'implémentation

> **Pour un exécutant sans contexte** : lire d'abord la spec (D1..D9) ; chaque tâche nomme son épreuve AVANT son code (TDD) ; la preuve finale est par BUILDS réels sur le lab (T7, T8), les tâches T1..T6 sont vérifiables hors ligne. Exécution **inline** (superpowers:executing-plans), un seul écrivain : le mode de défaillance « narration prématurée » des sous-agents est mesuré et cher (mémoire g2-axe-qui-deploie).

**But :** `selfservice-app-deploy` cesse de lire `deploy/<tenant>/wm-admin` + `X-Environment` ; il lit `envs/<env>/wm-admin` avec l'identité qui porte `apply-<env>` (ticket lu AVANT tout contact gateway, garde chargée depuis la lignée de `main`), l'équipe de cloisonnement est décidée par le token, et la porte du GOAL (matrice 403 sur la voie application, F4-canari) est jouée live.

**Architecture :** un script bash + python (`scripts/selfservice-palier-gate.sh`) qui ne parle qu'à Vault et écrit `PALIER_OUT` ; le Jenkinsfile l'extrait de `origin/main`, l'appelle entre le login et le préflight, relit sa sortie sans `eval` ; un helper additif `vault_token_ttl` ; deux poseurs de lab (`setup-wm-palier-admins.sh` neuf, `setup-deployer-groups.sh` retouché) ; une suite hors ligne (stub Vault + canari + câblage + mutations), l'extension ⑦ de la porte live G4, une suite live par builds réels.

**Stack :** bash 3.2 (poste) / dash (agent Jenkins, `sh '''…'''`), python3 + PyYAML, curl, Vault KV v2 (dev, lab), wM 10.15 REST, Jenkins 2.541 déclaratif from SCM, Gitea 1.22.

**Spec :** `docs/superpowers/specs/2026-09-02-a3-credential-du-seul-palier-design.md`

## Contraintes globales (copiées de la spec)

- Aucun `job.xml` porteur de logique ; le Jenkinsfile ROUTE, le script DÉCIDE (modèle `team-promote`).
- Le script ne touche JAMAIS la gateway ; la garde vient de `origin/main` (`git show`), jamais de l'arbre pinné ; le manifeste reste la donnée de l'arbre pinné.
- Ordre de l'Apply : `MOT_DE_PASSE_ALTERE` → login nominatif → **garde** → **préflight annoncé** (`préflight de joignabilité :`) → `TTL_INSUFFISANT` → converge → verify → annonce A2.
- Refus nommés, rc 1, `REFUS: <TAG> : …` sur stdout, `PALIER_OUT` jamais écrit sur refus : `CABLAGE_INCOMPLET`, `ENV_INVALIDE`, `VIA_INCONNU`, `CREDS_SUB_SANS_PALIER`, `TERMINUS_SANS_VOIE`, `APIM_BASE_INVALIDE`, `MANIFESTE_ILLISIBLE`, `VAULT_TOKEN_ILLISIBLE`, `IDENTITE_INVERIFIABLE`, `TEAM_INDETERMINEE`, `TEAM_AMBIGUE`, `TEAM_NON_PORTEE`, `CAPACITES_INVERIFIABLES`, `TICKET_INSCRIPTIBLE`, `TENANT_NON_PORTE`, `PALIER_FERME`, `SORTIE_INVALIDE` ; côté Jenkinsfile : `GATE_ABSENTE`, `SORTIE_INVALIDE`, `TTL_INSUFFISANT`.
- Secrets : token par fichier d'en-tête (`curl -H @`), jamais argv ; corps du ticket `-o /dev/null` ; aucun secret dans `PALIER_OUT` ni sur stdout.
- Défauts du script : `APIM_KV_MOUNT=secret`, `APIM_KV_PREFIX=""` (miroir de `${APIM_KV_PREFIX:-}`), `APIM_WM_CREDS_SUB_TPL=envs/__ENV__/wm-admin`, `APIM_OAUTH_SUB_TPL=envs/__ENV__/admin-oauth`, `APIM_PROXY_API=wm-admin-__ENV__`, `APIM_TERMINUS_BASE` **sans défaut** ; les deux gabarits de sous-chemin DOIVENT porter `__ENV__`.
- Les listes `withEnv` de `Jenkinsfile.selfservice` sont INCHANGÉES (`test-a0-wiring` 175/175) ; `test-provision-apply-wiring` 141/141 ; `test-palier-retention` (G4) vert ; `make lint-ci` passe à `[12/12]`.
- Valeurs de `PALIER_OUT` : classe `[A-Za-z0-9_./:@+-]`, vérifiée à l'écriture (script) ET à la lecture (shell).
- Marqueurs de console (preuve live) : `palier ouvert :`, `PALIER_CREDS=`, `PALIER_TEAM=`, `préflight de joignabilité :`, `PLAY [Self-service application — converge`, `PLAY [Self-service application — verify`, `REFUS: <TAG>`, `token Vault révoqué — mort PROUVÉE`.
- Lab : identité **alice** (LDAP, `deploy-banking-demo` + `apply-dev` + `apply-rec` après le grant), `APPLY_ADMIN_VIA=direct`, gateway réelle `webmethods-real:5555`, comptes `wm-<e>-admin` reposés par T4.

---

## Carte des fichiers

| Fichier | Rôle | Tâche |
|---|---|---|
| `scripts/selfservice-palier-gate.sh` (créer) | la garde : forme, voie, équipe (token), capacités, ticket, sortie | T1 |
| `scripts/test-selfservice-palier-a3.sh` (créer) | suite hors ligne : A stub Vault + canari + mutations ; B câblage Jenkinsfile + mutation d'ordre ; C poseur gateway `--print` ; D poseur LDAP `--print` ; E `vault_token_ttl` | T1, T2, T3, T4, T5 |
| `ci/lib/vault-login.sh` (modifier, additif) | `vault_token_ttl` | T2 |
| `ci/Jenkinsfile.selfservice` (modifier : `environment{}`, stage Apply) | route : extraction `origin/main`, appel, relecture, préflight annoncé, TTL, extra-vars | T3 |
| `scripts/setup-wm-palier-admins.sh` (créer) | comptes `wm-<e>-admin` sur la gateway, ∈ `API-Gateway-Administrators`, login prouvé | T4 |
| `scripts/setup-deployer-groups.sh` (modifier) | `demandeuse_exclue`, `--print` ligne de plan, avertissement à deux refus | T5 |
| `Makefile` (modifier) | `[12/12]`, shellcheck des nouveaux scripts | T6 |
| `scripts/test-palier-retention-live.sh` (modifier) | section ⑦ « voie application » | T7 |
| `scripts/test-a3-live.sh` (créer) ; `scripts/test-provision-apply-a2-live.sh` (modifier 0.9) | preuve par builds réels ; régression A2 | T8 |
| `ENVIRONNEMENTS.md`, `adr/adr-082-…md`, `GOAL-cd-applications-2026-09-02.md`, spec/plan (statuts), mémoire | docs | T9 |

---

## T1 — `scripts/selfservice-palier-gate.sh` + section A de la suite (stub Vault, canari, mutations)

**Fichiers :** créer `scripts/selfservice-palier-gate.sh` ; créer `scripts/test-selfservice-palier-a3.sh` (sections 0 et A).

**Interface produite :** entrées env (spec D1) ; sortie `PALIER_OUT` = lignes `PALIER_ENV= PALIER_VIA= APIM_API_BASE= APIM_AUTH_MODE= APIM_WM_CREDS_SUB= APIM_OAUTH_SUB= PALIER_TEAM= PALIER_TICKET=` ; stdout `palier ouvert : <wm-sub> lisible par l'identité du build`, `PALIER_CREDS=`, `PALIER_TEAM=`, `PALIER_BASE=`, `PALIER_VIA=` ; rc 0/1 ; `REFUS: <TAG> : …`.

- [ ] **Step 1 : le stub Vault et le canari (plomberie de la suite), puis les épreuves A.0–A.40 écrites AVANT le script.**

Plomberie (motif `test-provision-apply-a2.sh` section B) — `$TMP/stub.py` :

```python
import json, os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
CTL = sys.argv[1]; LOG = sys.argv[2]
def ctl():
    with open(CTL) as f: return json.load(f)
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def _journal(self, method, body):
        with open(LOG, "a") as f:
            f.write(json.dumps({"m": method, "p": self.path, "tok": self.headers.get("X-Vault-Token", ""),
                                "ns": self.headers.get("X-Vault-Namespace", ""), "body": body}) + "\n")
    def do_GET(self):
        self._journal("GET", ""); c = ctl(); p = self.path
        if p == "/v1/auth/token/lookup-self":
            lk = c.get("lookup", {}); code = lk.get("code", 200)
            self._send(code, {"data": {"policies": lk.get("policies", []), "identity_policies": lk.get("identity_policies"), "ttl": lk.get("ttl", 300)}} if code == 200 else {"errors": ["stub"]}); return
        kv = c.get("kv", {}); code = kv.get(p[len("/v1/"):], 404)
        self._send(code, {"data": {"data": {"username": "u", "password": "SECRET-BODY-DO-NOT-STORE"}}} if code == 200 else {"errors": ["stub kv " + str(code)]})
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0") or 0); body = self.rfile.read(n).decode() if n else ""
        self._journal("POST", body); c = ctl()
        if self.path == "/v1/sys/capabilities-self":
            cs = c.get("caps", {}); code = cs.get("code", 200)
            if code != 200: self._send(code, {"errors": ["permission denied"]}); return
            paths = json.loads(body).get("paths", []); out = {p: cs.get("paths", {}).get(p, ["deny"]) for p in paths}
            self._send(200, dict(out, data=out)); return
        self._send(404, {"errors": ["stub: route inconnue " + self.path]})
srv = ThreadingHTTPServer(("127.0.0.1", 0), H); print(srv.server_address[1], flush=True); srv.serve_forever()
```

Le canari = `python3 -m http.server <port> --bind 127.0.0.1` (motif G4 ④, contrôle positif `canary-selftest` obligatoire avant toute épreuve). Le geste = `gate && curl canari/apply-<env>`.

Helpers de la suite : `set_ctl <json>` (écrit `ctl.json`), `run_gate <env> [VAR=val…]` (lance le script avec `VAULT_ADDR=http://127.0.0.1:$PORT VAULT_TOKEN_FILE=$TMP/tok PALIER_OUT=$TMP/out.env MANIFEST=$TMP/man.yml APIM_KV_PREFIX=stoa` par défaut, capture stdout+rc dans des fichiers, jamais un pipe sous pipefail), `geste <env>` (= `run_gate` puis `curl canari` si rc 0), `journal_count <regex>`, `out_val <clé>`, `mutant <sed-expr> <nom>` (copie + `cmp` anti-no-op + `bash -n`). Manifestes : `man_idp <team|vide>` (racine + `per_env: {rec: {...}, int: {...}}`), `man_internal <vault_sub_racine> <vault_sub_rec>`.

Épreuves (chaque `ok`/`ko` compte ; `EXPECTED_CHECKS` posé en fin de tâche) :

- A.0 canari vivant (auto-test journalisé) ; stub vivant (port lu) ; le script existe et `bash -n` passe.
- A.1 nominal `direct` rec, manifeste `team: banking-demo`, lookup `[deploy-banking-demo, apply-rec, default]`, caps `{ticket: [read]}`, kv `secret/data/stoa/envs/rec/wm-admin: 200` ⇒ rc 0 ; `PALIER_OUT` : `PALIER_ENV=rec PALIER_VIA=direct APIM_API_BASE=http://gw.test:5555/rest/apigateway APIM_AUTH_MODE=basic APIM_WM_CREDS_SUB=envs/rec/wm-admin APIM_OAUTH_SUB=envs/rec/admin-oauth PALIER_TEAM=banking-demo PALIER_TICKET=secret/data/stoa/envs/rec/wm-admin` ; stdout porte `palier ouvert : envs/rec/wm-admin`, `PALIER_CREDS=envs/rec/wm-admin`, `PALIER_TEAM=banking-demo` ; canari **1** hit ; journal : 1 lookup, 1 capabilities (1 chemin), 1 GET kv, tous avec `X-Vault-Token` = contenu du fichier, aucun corps de réponse KV dans `$TMP` (grep `SECRET-BODY-DO-NOT-STORE` sur tout `$TMP` hors journal ⇒ absent).
- A.2 `direct` avec `APIM_API_BASE=http://gw-__ENV__.test/rest/apigateway` ⇒ `APIM_API_BASE=http://gw-rec.test/rest/apigateway`.
- A.3 `proxy-oauth2` défauts ⇒ `APIM_API_BASE=http://webmethods-real:5555/gateway/wm-admin-rec/1.0/rest/apigateway`, `APIM_AUTH_MODE=oauth2`, ticket toujours `envs/rec/wm-admin` (journal GET), `APIM_OAUTH_SUB=envs/rec/admin-oauth`.
- A.4 `proxy-oauth2` + `APIM_PROXY_BASE=https://apim-__ENV__.corp/admin` ⇒ `APIM_API_BASE=https://apim-rec.corp/admin`.
- A.5 préfixe vide + mount client : `APIM_KV_MOUNT=secret_DEV APIM_KV_PREFIX= APIM_WM_CREDS_SUB_TPL=APIM-__ENV__-ADMIN APIM_OAUTH_SUB_TPL=APIM-__ENV__-OAUTH` (kv `secret_DEV/data/APIM-rec-ADMIN: 200`, caps idem) ⇒ `PALIER_TICKET=secret_DEV/data/APIM-rec-ADMIN` ; A.5b `APIM_KV_PREFIX` **absent de l'env** (unset) ⇒ même chemin (défaut vide, pas `stoa`).
- A.6 `VAULT_NAMESPACE=ns1` ⇒ journal : en-tête `X-Vault-Namespace: ns1` sur les 3 appels.
- A.7 team : la règle est `TEAM = APIM_TEAM ?: manifeste ?: unique(S)` PUIS `TEAM ∈ S`. `APIM_TEAM=banking-demo` + manifeste `team: payments-team` + lookup `[deploy-banking-demo]` ⇒ **rc 0**, `PALIER_TEAM=banking-demo` (le knob prime sur le manifeste, et il est lui-même borné par le token) ; A.7b `APIM_TEAM=payments-team` (∉ S) ⇒ `TEAM_NON_PORTEE`.
- A.8 manifeste `team: payments-team`, sans `APIM_TEAM`, lookup `[deploy-banking-demo]` ⇒ `TEAM_NON_PORTEE`.
- A.9 manifeste sans `team` (gabarit `demo-consumer`), lookup `[deploy-banking-demo, default]` ⇒ rc 0, `PALIER_TEAM=banking-demo`.
- A.10 manifeste sans `team`, lookup `[deploy-banking-demo, deploy-payments-team]` ⇒ `TEAM_AMBIGUE` ; A.10b idem + manifeste `team: payments-team` ⇒ rc 0 `PALIER_TEAM=payments-team` (nommé ET ∈ S).
- A.11 lookup `[default, apply-rec]` (aucune `deploy-*`) ⇒ `TEAM_INDETERMINEE`.
- A.12 lookup code 403 ⇒ `IDENTITE_INVERIFIABLE` ; aucun capabilities ni GET kv dans le journal.
- A.13 caps ticket `[create, read, update]` ⇒ `TICKET_INSCRIPTIBLE`, aucun GET kv ; A.13b caps ticket `[read, delete]` ⇒ `TICKET_INSCRIPTIBLE`.
- A.14 mode `internal`, `auth.vault_sub` racine `deploy/banking-demo/apps/x/dev/oauth-client` et `per_env.rec.auth.vault_sub` `deploy/banking-demo/apps/x/rec/oauth-client` : caps `{ticket: [read], secret/data/stoa/deploy/banking-demo/apps/x/rec/oauth-client: [create, read, update]}` ⇒ rc 0 et le journal du POST capabilities porte le chemin **rec** (fusion per_env), pas dev ; A.14b caps rec `[read]` ⇒ `TENANT_NON_PORTE` ; A.14c mode `idp` ⇒ le POST capabilities ne porte **qu'un** chemin (le ticket).
- A.15 caps code 403 ⇒ `CAPACITES_INVERIFIABLES` (message cite `default`).
- A.16 `PALIER_FERME` : kv rec 403 ⇒ rc 1, message cite `HTTP 403` et `envs/rec/wm-admin` ; A.16b 404 ; A.16c 500 ; A.16d `VAULT_ADDR=http://127.0.0.1:1` (muet) ⇒ `PALIER_FERME` (HTTP 000) — canari **muet** sur les quatre ; `PALIER_OUT` absent.
- A.17 terminus : `ENVIRONMENT=prod` sans `APIM_TERMINUS_BASE` ⇒ `TERMINUS_SANS_VOIE`, **journal vide** (aucun appel Vault) ; A.17b `APIM_TERMINUS_BASE=http://prod-gw/rest/apigateway ADMIN_VIA=proxy-oauth2`, kv prod 403 ⇒ `PALIER_FERME` et le message/`PALIER_VIA` annoncé = `direct` (via forcée) ; A.17c idem kv prod 200 + caps ⇒ rc 0, `PALIER_VIA=direct`, `APIM_API_BASE=http://prod-gw/rest/apigateway`, `APIM_AUTH_MODE=basic`.
- A.18 `ENVIRONMENT=` vide ⇒ `ENV_INVALIDE` ; `ENVIRONMENT=preprod` (hors chaîne) ⇒ `ENV_INVALIDE` ; `ENVIRONMENT='rec;rm'` ⇒ `ENV_INVALIDE` — journal vide sur les trois.
- A.19 `ADMIN_VIA=ssh` ⇒ `VIA_INCONNU`, journal vide.
- A.20 `APIM_WM_CREDS_SUB_TPL=deploy/banking-demo/wm-admin` ⇒ `CREDS_SUB_SANS_PALIER` ; A.20b `APIM_OAUTH_SUB_TPL=gateways/webmethods/admin-oauth` ⇒ idem — journal vide.
- A.21 `APIM_API_BASE=gw.test/rest` (sans schéma) ⇒ `APIM_BASE_INVALIDE`.
- A.22 `MANIFEST` absent ⇒ `MANIFESTE_ILLISIBLE` ; YAML cassé ⇒ idem ; sans `apim_ss_app.name` ⇒ idem ; `team` avec saut de ligne ⇒ idem.
- A.23 `VAULT_TOKEN_FILE` vide ⇒ `VAULT_TOKEN_ILLISIBLE` ; absent ⇒ `CABLAGE_INCOMPLET` ; `PALIER_OUT` absent ⇒ `CABLAGE_INCOMPLET`.
- A.24 `PALIER_OUT` périmé (contenu `PALIER_TEAM=faux`) puis refus `PALIER_FERME` ⇒ le fichier n'existe **plus**.
- A.25 concordance : `setup-vault-paliers.sh --print` (chaîne du dépôt) émet `path "secret/data/stoa/envs/rec/wm-admin"` == `PALIER_TICKET` de A.1.
- A.26 vue code du script : toute occurrence de `X-Vault-Token` est dans un `printf` vers le fichier d'en-tête ; aucun `-H "X-Vault-Token` ; le GET du ticket porte `-o /dev/null` ; aucun `eval`.
- A.27 mutations (chacune : `cmp` anti-no-op, `bash -n`, puis le scénario visé passe sur le mutant ET l'original refuse toujours) : (i) ticket retiré ⇒ A.16 passe ; (ii) contrôle `__ENV__` retiré ⇒ A.20 passe ; (iii) contrôle d'inscriptibilité retiré ⇒ A.13 passe ; (iv) `TEAM ∈ S` retiré ⇒ A.8 passe ; (v) sonde `vault_sub` retirée ⇒ A.14b passe ; (vi) `EFFECTIVE_VIA` forcé à `ADMIN_VIA` ⇒ A.17c rend `PALIER_VIA=proxy-oauth2` (le terminus compose une base proxy).

- [ ] **Step 2 : lancer la suite ⇒ rouge (script absent : A.0 rouge, tout le reste rouge ou non joué).**

Run : `bash scripts/test-selfservice-palier-a3.sh` — attendu : `RÉSULTAT : x/N` avec x < N, première ligne rouge « script absent ».

- [ ] **Step 3 : écrire le script.**

```bash
#!/usr/bin/env bash
# scripts/selfservice-palier-gate.sh — A3 (GOAL cd-applications) : LA GARDE DU
# PALIER de l'apply d'application. La §7.b + §8 de team-promote.sh portées au
# second objet : le credential du palier décide, jamais un en-tête, jamais un
# credential de tenant.
#
#   login nominatif (ci/lib/vault-login.sh → VAULT_TOKEN_FILE)
#     → CE script : 0 forme · 1 voie (terminus par POSITION) · 2 équipe décidée
#       par le TOKEN · 3 capacités (ticket NON inscriptible ; mode internal :
#       écriture du client) · 4 le TICKET (GET envs/<env>/wm-admin) · 5 sortie
#     → préflight → converge → verify (Jenkinsfile.selfservice)
#
# NE TOUCHE JAMAIS LA GATEWAY. Refus : rc 1, `REFUS: <TAG> : …`, PALIER_OUT
# jamais écrit. Le token part par FICHIER d'en-tête (jamais argv). Le corps du
# ticket EST le credential d'admin : -o /dev/null, jamais lu, jamais écrit.
# Chargé par le Jenkinsfile depuis origin/main (jamais l'arbre pinné) dans un
# répertoire qui conserve l'arborescence : la lib se résout par BASH_SOURCE.
set -uo pipefail
set +x
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/env-chain.sh
. "$SELF_DIR/lib/env-chain.sh" || { echo "REFUS: CABLAGE_INCOMPLET : scripts/lib/env-chain.sh introuvable à côté de la garde"; exit 1; }

refus(){ printf 'REFUS: %s : %s\n' "$1" "$2"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; umask 077

PALIER_OUT="${PALIER_OUT:-}"; [ -n "$PALIER_OUT" ] || refus CABLAGE_INCOMPLET "PALIER_OUT absent (le Jenkinsfile doit nommer le fichier de sortie)"
rm -f "$PALIER_OUT"
VAULT_ADDR="${VAULT_ADDR:-}"; [ -n "$VAULT_ADDR" ] || refus CABLAGE_INCOMPLET "VAULT_ADDR absent"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:-}"; [ -n "$VAULT_TOKEN_FILE" ] || refus CABLAGE_INCOMPLET "VAULT_TOKEN_FILE absent (login nominatif non fait ?)"
MANIFEST="${MANIFEST:-}"; [ -n "$MANIFEST" ] || refus CABLAGE_INCOMPLET "MANIFEST absent"
ENVIRONMENT="${ENVIRONMENT:-}"
ADMIN_VIA="${ADMIN_VIA:-direct}"
APIM_KV_MOUNT="${APIM_KV_MOUNT:-secret}"
APIM_KV_PREFIX="${APIM_KV_PREFIX:-}"          # VIDE par défaut : miroir de ${APIM_KV_PREFIX:-} passé au rôle
APIM_WM_CREDS_SUB_TPL="${APIM_WM_CREDS_SUB_TPL:-envs/__ENV__/wm-admin}"
APIM_OAUTH_SUB_TPL="${APIM_OAUTH_SUB_TPL:-envs/__ENV__/admin-oauth}"
APIM_API_BASE="${APIM_API_BASE:-http://webmethods-real:5555/rest/apigateway}"
APIM_TERMINUS_BASE="${APIM_TERMINUS_BASE:-}"   # SANS défaut : dire la cible du terminus est volontaire (G7)
APIM_PROXY_HOST="${APIM_PROXY_HOST:-http://webmethods-real:5555}"
APIM_PROXY_API="${APIM_PROXY_API:-wm-admin-__ENV__}"
APIM_PROXY_VER="${APIM_PROXY_VER:-1.0}"
APIM_PROXY_PATH="${APIM_PROXY_PATH:-/rest/apigateway}"
APIM_PROXY_BASE="${APIM_PROXY_BASE:-}"
APIM_TEAM="${APIM_TEAM:-}"

# ── 0. FORME, avant tout appel réseau ────────────────────────────────────────
[ -n "$ENVIRONMENT" ] || refus ENV_INVALIDE "ENVIRONMENT vide — un apply vise un palier"
case "$ENVIRONMENT" in *[!a-z0-9]*) refus ENV_INVALIDE "'${ENVIRONMENT}' hors de ^[a-z0-9]+\$";; esac
CHAIN="$(env_chain)" || refus ENV_INVALIDE "chaîne d'environnements illisible"
case " $CHAIN " in *" $ENVIRONMENT "*) ;; *) refus ENV_INVALIDE "'${ENVIRONMENT}' hors de la chaîne ($CHAIN)";; esac
case "$ADMIN_VIA" in direct|proxy-oauth2) ;; *) refus VIA_INCONNU "'${ADMIN_VIA}' — attendu direct ou proxy-oauth2";; esac
case "$APIM_WM_CREDS_SUB_TPL" in *__ENV__*) ;; *) refus CREDS_SUB_SANS_PALIER "APIM_WM_CREDS_SUB_TPL='${APIM_WM_CREDS_SUB_TPL}' ne porte pas __ENV__ — un credential qui ne varie pas par palier ne décide d'aucun palier";; esac
case "$APIM_OAUTH_SUB_TPL"    in *__ENV__*) ;; *) refus CREDS_SUB_SANS_PALIER "APIM_OAUTH_SUB_TPL='${APIM_OAUTH_SUB_TPL}' ne porte pas __ENV__";; esac
sub_env(){ printf '%s' "$1" | sed "s/__ENV__/${ENVIRONMENT}/g"; }
WM_SUB="$(sub_env "$APIM_WM_CREDS_SUB_TPL")"; OAUTH_SUB="$(sub_env "$APIM_OAUTH_SUB_TPL")"
kv_data_path(){ local p="${APIM_KV_MOUNT}/data"; [ -n "$APIM_KV_PREFIX" ] && p="${p}/${APIM_KV_PREFIX}"; printf '%s/%s' "$p" "$1"; }
TICKET_PATH="$(kv_data_path "$WM_SUB")"

# ── 1. LA VOIE, par POSITION ─────────────────────────────────────────────────
TERMINUS="$(env_chain_terminus)" || refus ENV_INVALIDE "terminus indéterminable"
if [ "$ENVIRONMENT" = "$TERMINUS" ]; then
  [ -n "$APIM_TERMINUS_BASE" ] || refus TERMINUS_SANS_VOIE "'${ENVIRONMENT}' est le terminus de la chaîne — pas de proxy wm-admin-<env> devant lui (exclusion structurelle G4) ; la voie directe exige APIM_TERMINUS_BASE, et dire sa cible est volontaire"
  EFFECTIVE_VIA=direct; BASE="$(sub_env "$APIM_TERMINUS_BASE")"
elif [ "$ADMIN_VIA" = direct ]; then
  EFFECTIVE_VIA=direct; BASE="$(sub_env "$APIM_API_BASE")"
else
  EFFECTIVE_VIA=proxy-oauth2
  if [ -n "$APIM_PROXY_BASE" ]; then BASE="$(sub_env "$APIM_PROXY_BASE")"
  else BASE="$(sub_env "${APIM_PROXY_HOST}/gateway/${APIM_PROXY_API}/${APIM_PROXY_VER}${APIM_PROXY_PATH}")"; fi
fi
case "$BASE" in http://*|https://*) ;; *) refus APIM_BASE_INVALIDE "'${BASE}' — le gabarit d'URL admin doit produire une URL http(s)";; esac
if [ "$EFFECTIVE_VIA" = direct ]; then AUTH_MODE=basic; else AUTH_MODE=oauth2; fi

# ── le manifeste : la DONNÉE (name, team, auth.mode, auth.vault_sub effectif) ─
[ -r "$MANIFEST" ] || refus MANIFESTE_ILLISIBLE "'${MANIFEST}' absent ou illisible"
MAN="$(MAN_FILE="$MANIFEST" MAN_ENV="$ENVIRONMENT" python3 - 2>"$TMP/man.err" <<'PY'
import os, sys, yaml
try:
    d = yaml.load(open(os.environ["MAN_FILE"], encoding="utf-8"), Loader=yaml.BaseLoader) or {}
except Exception as e:
    sys.exit("YAML illisible : %s" % type(e).__name__)
app = d.get("apim_ss_app") if isinstance(d, dict) else None
if not isinstance(app, dict) or not str(app.get("name") or ""):
    sys.exit("apim_ss_app.name absent")
auth = app.get("auth") if isinstance(app.get("auth"), dict) else {}
over = ((app.get("per_env") or {}).get(os.environ["MAN_ENV"]) or {}) if isinstance(app.get("per_env"), dict) else {}
oauth = over.get("auth") if isinstance(over.get("auth"), dict) else {}
mode = str(oauth.get("mode") or auth.get("mode") or "idp")
vsub = str(oauth.get("vault_sub") or auth.get("vault_sub") or "")
vals = {"NAME": str(app.get("name")), "TEAM": str(app.get("team") or ""), "MODE": mode, "VSUB": vsub}
for k, v in vals.items():
    if "\n" in v or "\r" in v: sys.exit("le champ %s contient un saut de ligne" % k)
for k, v in vals.items(): print("%s=%s" % (k, v))
PY
)" || refus MANIFESTE_ILLISIBLE "${MANIFEST} — $(tail -1 "$TMP/man.err")"
MAN_NAME="$(printf '%s\n' "$MAN" | sed -n 's/^NAME=//p')"; MAN_TEAM="$(printf '%s\n' "$MAN" | sed -n 's/^TEAM=//p')"
MAN_MODE="$(printf '%s\n' "$MAN" | sed -n 's/^MODE=//p')"; MAN_VSUB="$(printf '%s\n' "$MAN" | sed -n 's/^VSUB=//p')"

# ── le token : fichier d'en-tête, jamais argv ────────────────────────────────
[ -s "$VAULT_TOKEN_FILE" ] || refus VAULT_TOKEN_ILLISIBLE "${VAULT_TOKEN_FILE} vide ou absent"
{ printf 'X-Vault-Token: '; tr -d '\r\n' < "$VAULT_TOKEN_FILE"; printf '\n'; } > "$TMP/vhdr" || refus VAULT_TOKEN_ILLISIBLE "$VAULT_TOKEN_FILE"
[ -n "${VAULT_NAMESPACE:-}" ] && printf 'X-Vault-Namespace: %s\n' "$VAULT_NAMESPACE" >> "$TMP/vhdr"
CA_ARGS=(); CA="${VAULT_CACERT:-${LABCTL_CA_FILE:-}}"; [ -n "$CA" ] && [ -f "$CA" ] && CA_ARGS=(--cacert "$CA")
vcurl(){ curl -sS --max-time 20 -H @"$TMP/vhdr" "${CA_ARGS[@]}" "$@"; }

# ── 2. L'ÉQUIPE, décidée par le TOKEN ────────────────────────────────────────
LC="$(vcurl -o "$TMP/lookup.json" -w '%{http_code}' "${VAULT_ADDR}/v1/auth/token/lookup-self")" || LC=000
[ "$LC" = 200 ] || refus IDENTITE_INVERIFIABLE "lookup-self HTTP ${LC} — les policies du porteur sont invérifiables"
S="$(SRC="$TMP/lookup.json" python3 -c 'import json,os
d=(json.load(open(os.environ["SRC"])) or {}).get("data") or {}
p=set((d.get("policies") or [])+(d.get("identity_policies") or []))
print("\n".join(sorted(x[len("deploy-"):] for x in p if x.startswith("deploy-") and len(x)>len("deploy-"))))')" || refus IDENTITE_INVERIFIABLE "lookup-self illisible"
TEAM="$APIM_TEAM"; [ -n "$TEAM" ] || TEAM="$MAN_TEAM"
if [ -z "$TEAM" ]; then
  N="$(printf '%s\n' "$S" | grep -c .)"
  [ "$N" -ge 1 ] || refus TEAM_INDETERMINEE "le token ne porte aucune policy deploy-<tenant> et ni APIM_TEAM ni le manifeste ne nomment d'équipe"
  [ "$N" -eq 1 ] || refus TEAM_AMBIGUE "le token porte plusieurs tenants ($(printf '%s' "$S" | tr '\n' ' ' | sed 's/ $//')) — nommer l'équipe (APIM_TEAM ou team: du manifeste)"
  TEAM="$S"
fi
case "$TEAM" in *[!a-z0-9-]*) refus TEAM_NON_PORTEE "'${TEAM}' hors de la classe [a-z0-9-]";; esac
printf '%s\n' "$S" | grep -qx -- "$TEAM" \
  || refus TEAM_NON_PORTEE "l'équipe '${TEAM}' n'est pas parmi les tenants que le token porte ($(printf '%s' "$S" | tr '\n' ' ' | sed 's/ $//')) — l'appelant ne choisit pas sous quelle équipe son application est cloisonnée"

# ── 3. LES CAPACITÉS, en un appel, AVANT de lire quoi que ce soit ────────────
VSUB_PATH=""
if [ "$MAN_MODE" = internal ]; then
  [ -n "$MAN_VSUB" ] || refus TENANT_NON_PORTE "mode internal sans auth.vault_sub (racine ou per_env.${ENVIRONMENT}) — le rôle ne saurait pas où écrire le client généré"
  VSUB_PATH="$(kv_data_path "$MAN_VSUB")"
fi
CAPS_BODY="$(T="$TICKET_PATH" V="$VSUB_PATH" python3 -c 'import json,os;ps=[os.environ["T"]]
if os.environ["V"]: ps.append(os.environ["V"])
print(json.dumps({"paths":ps}))')"
CC="$(vcurl -o "$TMP/caps.json" -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary "$CAPS_BODY" "${VAULT_ADDR}/v1/sys/capabilities-self")" || CC=000
[ "$CC" = 200 ] || refus CAPACITES_INVERIFIABLES "sys/capabilities-self HTTP ${CC} — le token ne peut pas interroger ses propres capacités (policy default absente ?)"
CV="$(SRC="$TMP/caps.json" T="$TICKET_PATH" V="$VSUB_PATH" python3 - <<'PY'
import json, os
d = json.load(open(os.environ["SRC"])) or {}
caps = d.get("data") if isinstance(d.get("data"), dict) else d
t = set(caps.get(os.environ["T"]) or [])
if t & {"create", "update", "delete", "patch"}: print("TICKET_INSCRIPTIBLE"); raise SystemExit
v = os.environ["V"]
if v and not (set(caps.get(v) or []) & {"create", "update"}): print("TENANT_NON_PORTE"); raise SystemExit
print("OK")
PY
)" || refus CAPACITES_INVERIFIABLES "réponse capabilities-self illisible"
case "$CV" in
  OK) ;;
  TICKET_INSCRIPTIBLE) refus TICKET_INSCRIPTIBLE "le chemin du ticket ${TICKET_PATH} est INSCRIPTIBLE par cette identité — un ticket qu'on peut s'écrire n'est pas un ticket (le gabarit vise-t-il le sous-arbre du tenant ?)" ;;
  TENANT_NON_PORTE) refus TENANT_NON_PORTE "mode internal : le token ne peut pas écrire ${VSUB_PATH} (client généré du palier ${ENVIRONMENT}) — le tenant '${TEAM}' n'est pas onboardé pour ce palier, ou l'identité n'en est pas" ;;
  *) refus CAPACITES_INVERIFIABLES "verdict inattendu ($CV)" ;;
esac

# ── 4. LE TICKET — le contrôle d'accès est la porte ; le corps n'est jamais lu ─
TC="$(vcurl -o /dev/null -w '%{http_code}' "${VAULT_ADDR}/v1/${TICKET_PATH}")" || TC=000
[ "$TC" = 200 ] || refus PALIER_FERME "lecture de ${WM_SUB} refusée (HTTP ${TC}) — le palier '${ENVIRONMENT}' n'est pas ouvert pour cette identité (ADR-082 : l'ouverture est un geste de credential, pas un edit de code)"

# ── 5. SORTIE (forme contrôlée à l'écriture ; le shell re-contrôle à la lecture)
OUT="$PALIER_OUT" python3 - "$ENVIRONMENT" "$EFFECTIVE_VIA" "$BASE" "$AUTH_MODE" "$WM_SUB" "$OAUTH_SUB" "$TEAM" "$TICKET_PATH" <<'PY' || refus SORTIE_INVALIDE "une valeur de sortie est hors de la classe [A-Za-z0-9_./:@+-]"
import os, re, sys
keys = ["PALIER_ENV", "PALIER_VIA", "APIM_API_BASE", "APIM_AUTH_MODE", "APIM_WM_CREDS_SUB", "APIM_OAUTH_SUB", "PALIER_TEAM", "PALIER_TICKET"]
vals = sys.argv[1:]
for k, v in zip(keys, vals):
    if not v or not re.fullmatch(r"[A-Za-z0-9_./:@+-]+", v): sys.exit("%s=%r" % (k, v))
fd = os.open(os.environ["OUT"], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    for k, v in zip(keys, vals): f.write("%s=%s\n" % (k, v))
PY
echo "palier ouvert : ${WM_SUB} lisible par l'identité du build"
echo "PALIER_CREDS=${WM_SUB}"
echo "PALIER_TEAM=${TEAM}"
echo "PALIER_BASE=${BASE}"
echo "PALIER_VIA=${EFFECTIVE_VIA}"
```

- [ ] **Step 4 : lancer la suite ⇒ vert (section A entière), `shellcheck -x scripts/selfservice-palier-gate.sh` propre, bash 3.2 (`bash --version`) et `python3 -c 'import yaml'` OK.**

- [ ] **Step 5 : commit** — `git add scripts/selfservice-palier-gate.sh scripts/test-selfservice-palier-a3.sh && git commit -m "feat(cd-apps): A3 — garde du palier : envs/<env>/wm-admin comme ticket, équipe décidée par le token, capacités avant lecture (suite hors ligne, stub Vault + canari + mutations)"`.

---

## T2 — `vault_token_ttl` (ci/lib/vault-login.sh, additif) + section E

**Fichiers :** modifier `ci/lib/vault-login.sh` (après `vault_read`) ; suite section E.

**Interface produite :** `vault_token_ttl` — imprime le `ttl` entier (secondes) de `auth/token/lookup-self` pour le token de la lib ; rc 1 sans login préalable ou si lookup ≠ 200 ou `ttl` absent. POSIX (dash), token par fichier d'en-tête.

- [ ] **Step 1 : épreuves E.1–E.4 écrites** : E.1 sans login ⇒ rc 1, stderr « sans login préalable » ; E.2 après un login simulé (fonction `vault_login_approle` contre le stub ? non — plus simple : poser `_VAULT_TMPDIR` et `token.hdr` à la main dans un sous-shell qui source la lib, motif de `test-vault-user-login.sh`) et stub lookup `ttl=299` ⇒ imprime `299`, rc 0 ; E.3 stub lookup 403 ⇒ rc 1, rien sur stdout ; E.4 journal : l'appel porte `X-Vault-Token` par en-tête, aucun token dans l'URL.
- [ ] **Step 2 : rouge** (fonction absente : `command not found`).
- [ ] **Step 3 : implémenter**

```sh
# vault_token_ttl — imprime le TTL restant (secondes, entier) du token de la lib,
# relu par lookup-self. A3 : le préflight de joignabilité peut durer plus que le
# TTL d'un token LDAP (600 s sur ce lab) ; l'appelant refuse TTL_INSUFFISANT
# AVANT de lancer un play qui relirait Vault avec un token mort. Token par
# fichier d'en-tête, jamais argv. rc 1 = pas de login, lookup refusé, ttl absent.
vault_token_ttl() {
  if [ -z "$_VAULT_TMPDIR" ] || [ ! -f "$_VAULT_TMPDIR/token.hdr" ]; then
    echo "  ✗ vault_token_ttl appelé sans login préalable" >&2
    return 1
  fi
  local resp="$_VAULT_TMPDIR/ttl.json" code rc
  code="$(_vault_curl "$resp" GET "$VAULT_ADDR/v1/auth/token/lookup-self" -H "@$_VAULT_TMPDIR/token.hdr" || true)"
  if [ "$code" != "200" ]; then
    rm -f "$resp"
    return 1
  fi
  python3 -c 'import json, sys
t = (json.load(open(sys.argv[1])).get("data") or {}).get("ttl")
if t is None: sys.exit(1)
print(int(t))' "$resp"
  rc=$?
  rm -f "$resp"
  return "$rc"
}
```

- [ ] **Step 4 : vert** ; `shellcheck -x ci/lib/vault-login.sh` ; `bash scripts/test-vault-user-login.sh` inchangé (34/34 — si la suite exige le lab, la noter comme non rejouée ici et la rejouer en T7).
- [ ] **Step 5 : commit** — `feat(cd-apps): A3 — vault_token_ttl (lib de login, additif)`.

---

## T3 — `ci/Jenkinsfile.selfservice` : la garde depuis `origin/main`, le préflight annoncé, le TTL, les extra-vars + section B (câblage, mutation d'ordre)

**Fichiers :** modifier `ci/Jenkinsfile.selfservice` (`environment{}` lignes ~85-140 ; stage Apply, `sh` lignes ~365-560) ; suite section B.

**Interfaces consommées :** T1 (`PALIER_OUT`, marqueurs), T2 (`vault_token_ttl`).

- [ ] **Step 1 : épreuves B.1–B.20 écrites** (vue code `code_view` = commentaires `//`/`#` blanchis, `code_line`, motif `test-provision-apply-wiring.sh`) :
  - B.1 aucun `deploy/banking-demo` ; aucun `APIM_WM_CREDS_SUB =` ni `APIM_OAUTH_SUB =` (les anciens knobs tenant) ; B.2 `APIM_WM_CREDS_SUB_TPL = "${env.APIM_WM_CREDS_SUB_TPL ?: 'envs/__ENV__/wm-admin'}"` et `APIM_OAUTH_SUB_TPL = … 'envs/__ENV__/admin-oauth'` ; B.3 `APIM_PROXY_API = … 'wm-admin-__ENV__'` ; B.4 `APIM_TERMINUS_BASE = "${env.APIM_TERMINUS_BASE ?: ''}"` ; B.5 plus aucun `cut -d/ -f2` ; B.6 ordre par lignes : `vault_login_nominative` < `git show "origin/main:${PFX}scripts/selfservice-palier-gate.sh"` < `selfservice-palier-gate.sh"` (appel) < `préflight de joignabilité :` < `vault_token_ttl` < `ansible/selfservice-app.yml` < `ansible/selfservice-app-verify.yml` < `cp .a2-reference-sha .a2-applied-sha` ; B.7 les trois `git show` (script, `scripts/lib/env-chain.sh`, `clients/_example/environments.yaml`) et `REFUS: GATE_ABSENTE` ; B.8 `git fetch -q origin main` précède les `git show` ; B.9 relecture : `while IFS='=' read -r k v` + `case "$v" in *[!A-Za-z0-9_./:@+-]*` + `REFUS: SORTIE_INVALIDE`, aucun `eval`, aucun `. "$PALIER_OUT"`/`source` ; B.10 `-e apim_ss_team="$PALIER_TEAM"`, `-e apim_ss_api_base="$APIM_API_BASE"`, `-e apim_ss_auth_mode="$APIM_AUTH_MODE"`, `-e apim_ss_vault_wm_creds_sub="$APIM_WM_CREDS_SUB"`, `-e apim_ss_vault_oauth_sub="$APIM_OAUTH_SUB"` présents **deux fois** (converge et verify) ; plus d'`OAUTH_SUB_OPT` ; B.11 `REFUS: TTL_INSUFFISANT` et `APIM_TOKEN_TTL_MIN` ; B.12 les listes `withEnv` des trois stages inchangées (re-jouées ici avec l'extracteur `wenv_names` de `test-a0-wiring`) ; B.13 `rm -f "$PALIER_OUT"` avant l'appel ; B.14 le `sh` de l'Apply reste en `'''` (aucune interpolation Groovy de PALIER_*) ; B.15 la garde est appelée par `bash "$GATE_DIR/scripts/selfservice-palier-gate.sh"` (jamais `scripts/selfservice-palier-gate.sh` relatif à l'arbre) ; B.16 mutation d'ordre : bloc d'appel de la garde déplacé (awk, ancre d'instruction) APRÈS la boucle de préflight ⇒ B.6 rougit en nommant l'ordre ; B.17 mutation : appel retiré ⇒ B.6 rougit en nommant la garde absente ; B.18 `ci/lint-jenkinsfiles.sh` compile ; B.19 `bash scripts/test-a0-wiring.sh` 175/175 et `bash scripts/test-provision-apply-wiring.sh` 141/141 rejoués (par la suite, en sous-process, résultat capturé) ; B.20 `bash scripts/test-palier-retention.sh` vert.
- [ ] **Step 2 : rouge.**
- [ ] **Step 3 : modifier le Jenkinsfile.** `environment{}` : remplacer les deux lignes `APIM_WM_CREDS_SUB`/`APIM_OAUTH_SUB` (et leurs commentaires) par les `_TPL`, `APIM_PROXY_API` défaut `wm-admin-__ENV__`, ajouter `APIM_TERMINUS_BASE`, reformuler le commentaire d'`APIM_TEAM` (borné par le token) et d'`APIM_API_BASE` (gabarit, `__ENV__` optionnel). Stage Apply, dans le `sh '''` : retirer le bloc `TEAM=…cut`, le bloc `if [ "${ADMIN_VIA:-direct}" = "proxy-oauth2" ]…` (composition), `OAUTH_SUB_OPT` ; déplacer le préflight APRÈS le login ; insérer après le login réussi :

```sh
              # 2) A3 — LA GARDE DU PALIER, depuis la LIGNÉE DE MAIN (jamais l'arbre pinné) …
              GATE_DIR="$WORKSPACE/.a3-gate"; rm -rf "$GATE_DIR"
              PFX="$(git rev-parse --show-prefix)"
              git fetch -q origin main
              for f in scripts/selfservice-palier-gate.sh scripts/lib/env-chain.sh clients/_example/environments.yaml; do
                mkdir -p "$GATE_DIR/$(dirname "$f")"
                git show "origin/main:${PFX}${f}" > "$GATE_DIR/$f" 2>/dev/null \
                  || { echo "REFUS: GATE_ABSENTE : ${PFX}${f} absent de origin/main — la garde du palier vient de la lignée de la définition du pipeline, jamais de l'arbre pinné ; rien n'est appliqué"; exit 1; }
              done
              PALIER_OUT="$WORKSPACE/.a3-palier.env"; rm -f "$PALIER_OUT"
              PALIER_OUT="$PALIER_OUT" bash "$GATE_DIR/scripts/selfservice-palier-gate.sh" || exit 1
              PALIER_ENV=""; PALIER_VIA=""; PALIER_TEAM=""; APIM_AUTH_MODE=""; APIM_WM_CREDS_SUB=""; APIM_OAUTH_SUB=""
              while IFS='=' read -r k v; do
                case "$v" in ''|*[!A-Za-z0-9_./:@+-]*) echo "REFUS: SORTIE_INVALIDE : valeur hors classe pour $k"; exit 1;; esac
                case "$k" in
                  PALIER_ENV) PALIER_ENV="$v";; PALIER_VIA) PALIER_VIA="$v";; PALIER_TEAM) PALIER_TEAM="$v";;
                  APIM_API_BASE) APIM_API_BASE="$v";; APIM_AUTH_MODE) APIM_AUTH_MODE="$v";;
                  APIM_WM_CREDS_SUB) APIM_WM_CREDS_SUB="$v";; APIM_OAUTH_SUB) APIM_OAUTH_SUB="$v";; PALIER_TICKET) ;;
                  *) echo "REFUS: SORTIE_INVALIDE : clé inconnue $k"; exit 1;;
                esac
              done < "$PALIER_OUT"
              [ -n "$PALIER_TEAM" ] && [ -n "$APIM_AUTH_MODE" ] && [ -n "$APIM_WM_CREDS_SUB" ] && [ -n "$APIM_OAUTH_SUB" ] && [ -n "$PALIER_VIA" ] \
                || { echo "REFUS: SORTIE_INVALIDE : PALIER_OUT incomplet"; exit 1; }
              echo "  (cloisonnement de l'application sur la team : ${PALIER_TEAM} — décidée par le token)"
              echo "  (API d'admin du palier ${PALIER_ENV} via ${PALIER_VIA} : ${APIM_API_BASE})"
```

puis le préflight (inchangé) précédé de `echo "  préflight de joignabilité : $PF_URL (codes attendus : $PF_CODES, max $PF_MAX essais)"` juste avant la boucle `while :`, puis :

```sh
              # 3) TTL — le préflight a pu durer ; un token mort ferait un 403 « policy/chemin » dans le rôle
              TTL="$(vault_token_ttl || true)"
              case "$TTL" in ''|*[!0-9]*) echo "REFUS: TTL_INSUFFISANT : durée de vie du token nominatif invérifiable (lookup-self) — rien n'est appliqué"; exit 1;; esac
              [ "$TTL" -ge "${APIM_TOKEN_TTL_MIN:-180}" ] \
                || { echo "REFUS: TTL_INSUFFISANT : le token nominatif n'a plus que ${TTL}s (minimum ${APIM_TOKEN_TTL_MIN:-180}s pour converge + verify) — relancer l'apply, la gateway est joignable maintenant"; exit 1; }
```

puis les deux `ansible-playbook` avec `-e apim_ss_team="$PALIER_TEAM" -e apim_ss_api_base="$APIM_API_BASE" -e apim_ss_auth_mode="$APIM_AUTH_MODE" -e apim_ss_vault_wm_creds_sub="$APIM_WM_CREDS_SUB" -e apim_ss_vault_oauth_sub="$APIM_OAUTH_SUB"` (les autres `-e` inchangés, `TOKEN_URL_OPT` conservé). En-tête du fichier : paragraphe A3 (« le palier est un credential ») remplaçant les mentions `X-Environment`/tenant.

- [ ] **Step 4 : vert** : section B, `ci/lint-jenkinsfiles.sh`, `test-a0-wiring` 175/175, `test-provision-apply-wiring` 141/141, `test-palier-retention` vert, `test-selfservice-form-live` non rejoué (live, T8).
- [ ] **Step 5 : commit** — `feat(cd-apps): A3 — selfservice-app-deploy lit envs/<env>/wm-admin par la garde chargée depuis main ; préflight annoncé ; TTL_INSUFFISANT`.

---

## T4 — `scripts/setup-wm-palier-admins.sh` + section C

**Fichiers :** créer `scripts/setup-wm-palier-admins.sh` ; suite section C.

**Interface produite :** `bash scripts/setup-wm-palier-admins.sh` (pose : `VAULT_TOKEN`, `VAULT_ADDR`, `GW_ADMIN`, `WM_USER`, `WM_PASS` requis ; `ADMIN_GROUP` défaut `API-Gateway-Administrators` ; `APIM_KV_MOUNT`/`APIM_KV_PREFIX` défauts `secret`/`stoa`) ; `--print` (hors ligne : paliers et loginIds attendus, aucun réseau, aucun secret) ; rc 0 = chaque compte s'authentifie (`GET /applications` ⇒ 200) et est membre du groupe (relu).

- [ ] **Step 1 : épreuves C.1–C.5** : C.1 `--print` avec chaîne jetable `[alpha, beta, gamma]` ⇒ mentionne `envs/alpha/wm-admin` et `envs/beta/wm-admin`, jamais `gamma` ; C.2 `--print` avec `VAULT_ADDR=http://127.0.0.1:1` réussit (aucun réseau) ; C.3 `--print` n'imprime aucun mot de passe (grep `password`/`secret-poc` absent) ; C.4 vue code : le mot de passe gateway part par `-K` fichier (jamais `-u "$U:$P"`), le token Vault par `-H @` ; C.5 mutation `env_chain_nonprod`→`env_chain` ⇒ `gamma` apparaît (le terminus est exclu par la dérivation).
- [ ] **Step 2 : rouge.**
- [ ] **Step 3 : implémenter** (forme `setup-vault-paliers.sh`) :

```bash
#!/usr/bin/env bash
# scripts/setup-wm-palier-admins.sh — LAB : les comptes d'admin PAR PALIER sur la
# gateway réelle (ADR-075 les supposait ; le re-seed du 2026-09-02 a rejoué Vault,
# pas la gateway). Pour chaque palier NON terminal (env_chain_nonprod) : lit
# envs/<e>/wm-admin dans Vault, crée le user s'il manque, l'ajoute au groupe
# d'admin (RMW en UUID — un loginId ⇒ 200 et membre absent, piège mesuré), et
# PROUVE le login (GET /applications ⇒ 200 ; sinon PUT /users/<id> avec le mot de
# passe de Vault, re-prouvé). Idempotent. Aucun secret imprimé ni en argv.
#   bash scripts/setup-wm-palier-admins.sh --print   # hors ligne
#   VAULT_TOKEN=… GW_ADMIN=… WM_USER=… WM_PASS=… bash scripts/setup-wm-palier-admins.sh
set -uo pipefail
_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/env-chain.sh"; [ -f "$_LIB" ] || _LIB="scripts/lib/env-chain.sh"
# shellcheck source=scripts/lib/env-chain.sh
. "$_LIB"
VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
APIM_KV_MOUNT="${APIM_KV_MOUNT:-secret}"; APIM_KV_PREFIX="${APIM_KV_PREFIX:-stoa}"
ADMIN_GROUP="${ADMIN_GROUP:-API-Gateway-Administrators}"
ENVS="$(env_chain_nonprod)" || { echo "CHAINE_ILLISIBLE" >&2; exit 1; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad(){ FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
if [ "${1:-pose}" = --print ]; then
  echo "# comptes d'admin par palier (hors-prod, terminus exclu par structure) :"
  for e in $ENVS; do printf '#   %s : loginId lu dans %s/%s/envs/%s/wm-admin, membre de %s, login prouvé\n' "$e" "$APIM_KV_MOUNT" "$APIM_KV_PREFIX" "$e" "$ADMIN_GROUP"; done
  exit 0
fi
VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN requis}"; GW_ADMIN="${GW_ADMIN:?GW_ADMIN requis (ex. http://localhost:5555/rest/apigateway)}"
WM_USER="${WM_USER:?WM_USER requis}"; WM_PASS="${WM_PASS:?WM_PASS requis}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; umask 077
printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN" > "$TMP/vhdr"
curl_cfg(){ # <fichier> <user> <pass> — config curl (-K), échappement " et \
  U="$2" P="$3" python3 -c 'import os,sys;e=lambda s:s.replace("\\","\\\\").replace("\"","\\\"");open(sys.argv[1],"w").write("user = \"%s:%s\"\n" % (e(os.environ["U"]),e(os.environ["P"])))' "$1"; }
curl_cfg "$TMP/adm.cfg" "$WM_USER" "$WM_PASS"
adm(){ curl -s -K "$TMP/adm.cfg" -H 'Accept: application/json' -H 'Content-Type: application/json' "$@"; }
kv_path(){ local p="$APIM_KV_MOUNT/data"; [ -n "$APIM_KV_PREFIX" ] && p="$p/$APIM_KV_PREFIX"; printf '%s/%s' "$p" "$1"; }
for e in $ENVS; do
  echo "── palier $e ──"
  HC="$(curl -s -H @"$TMP/vhdr" -o "$TMP/kv.$e" -w '%{http_code}' "$VAULT_ADDR/v1/$(kv_path "envs/$e/wm-admin")")"
  [ "$HC" = 200 ] || { bad "[$e] envs/$e/wm-admin illisible dans Vault (HTTP $HC) — jouer setup-vault-envs.sh"; continue; }
  U="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["data"]["data"].get("username",""))' "$TMP/kv.$e")"
  P="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["data"]["data"].get("password",""))' "$TMP/kv.$e")"
  rm -f "$TMP/kv.$e"
  [ -n "$U" ] && [ -n "$P" ] || { bad "[$e] username/password absents du secret"; continue; }
  curl_cfg "$TMP/u.$e.cfg" "$U" "$P"; unset P
  uid(){ adm "$GW_ADMIN/users" | U="$1" python3 -c 'import json,os,sys;print(next((u["id"] for u in json.load(sys.stdin).get("users",[]) if u.get("loginId")==os.environ["U"]),""))'; }
  ID="$(uid "$U")"
  if [ -z "$ID" ]; then
    BODY="$(U="$U" E="$e" python3 -c 'import json,os,sys;print(json.dumps({"loginId":os.environ["U"],"firstName":"wm-admin","lastName":os.environ["E"],"password":open(sys.argv[1]).read().split(":",1)[1].rstrip("\"\n").replace("\\\"","\"").replace("\\\\","\\"),"active":True,"type":"local"}))' "$TMP/u.$e.cfg")"
    HC="$(printf '%s' "$BODY" | adm -X POST --data-binary @- -o /dev/null -w '%{http_code}' "$GW_ADMIN/users")"; unset BODY
    case "$HC" in 200|201) ID="$(uid "$U")"; [ -n "$ID" ] && ok "[$e] user $U créé ($ID)" || bad "[$e] user $U créé mais introuvable à la relecture";; *) bad "[$e] POST /users -> HTTP $HC"; continue;; esac
  else ok "[$e] user $U présent ($ID)"; fi
  [ -n "$ID" ] || continue
  # groupe : read-modify-write en UUID
  adm "$GW_ADMIN/groups" | G="$ADMIN_GROUP" I="$ID" python3 -c 'import json,os,sys
g=next((g for g in json.load(sys.stdin).get("groups",[]) if g.get("name")==os.environ["G"]),None)
if g is None: sys.exit(1)
ids=list(g.get("userIds") or [])
if os.environ["I"] not in ids: ids.append(os.environ["I"])
g["userIds"]=ids; print(json.dumps(g))' > "$TMP/g.$e.json" || { bad "[$e] groupe $ADMIN_GROUP introuvable"; continue; }
  HC="$(adm -X PUT --data-binary @"$TMP/g.$e.json" -o /dev/null -w '%{http_code}' "$GW_ADMIN/groups/$ADMIN_GROUP")"
  adm "$GW_ADMIN/groups" | G="$ADMIN_GROUP" I="$ID" python3 -c 'import json,os,sys
g=next((g for g in json.load(sys.stdin).get("groups",[]) if g.get("name")==os.environ["G"]),{})
sys.exit(0 if os.environ["I"] in (g.get("userIds") or []) else 1)' \
    && ok "[$e] $U ∈ $ADMIN_GROUP (relu, PUT HTTP $HC)" || { bad "[$e] $U ABSENT de $ADMIN_GROUP après PUT (HTTP $HC)"; continue; }
  probe(){ curl -s -K "$TMP/u.$e.cfg" -H 'Accept: application/json' -o /dev/null -w '%{http_code}' "$GW_ADMIN/applications"; }
  if [ "$(probe)" != 200 ]; then
    BODY="$(adm "$GW_ADMIN/users/$ID" | python3 -c 'import json,sys;d=json.load(sys.stdin);u=(d.get("users") or [d])[0];u["password"]=open(sys.argv[1]).read().split(":",1)[1].rstrip("\"\n").replace("\\\"","\"").replace("\\\\","\\");print(json.dumps(u))' "$TMP/u.$e.cfg")"
    HC="$(printf '%s' "$BODY" | adm -X PUT --data-binary @- -o /dev/null -w '%{http_code}' "$GW_ADMIN/users/$ID")"; unset BODY
    echo "  mot de passe réaligné sur Vault (PUT /users/$ID -> HTTP $HC)"
  fi
  [ "$(probe)" = 200 ] && ok "[$e] login de $U PROUVÉ (GET /applications -> 200)" || bad "[$e] login de $U refusé après pose (GET /applications -> $(probe))"
  rm -f "$TMP/u.$e.cfg"
done
printf '\n%d PASS / %d FAIL\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]
```

- [ ] **Step 4 : vert** (section C) ; `shellcheck -x` propre. La pose réelle est jouée en T8 (rollout).
- [ ] **Step 5 : commit** — `feat(lab): setup-wm-palier-admins.sh — comptes wm-<env>-admin sur la gateway réelle, login prouvé (A3, prérequis de la preuve live)`.

---

## T5 — `scripts/setup-deployer-groups.sh` : `demandeuse_exclue`, ligne de plan `--print`, avertissement à deux refus + section D

**Fichiers :** modifier `scripts/setup-deployer-groups.sh` ; suite section D.

**Interface produite :** `demandeuse_exclue <palier>` (rc 0 = le read-back « demandeuse absente » s'applique — la porte déclare `deployerGroup` ; rc 1 = non ; rc 2 = chaîne illisible) ; `--print` émet `#   read-back demandeuse absente : OUI (deployerGroup=<g>)` / `: NON (aucun deployerGroup)` par palier ; `read_back_group <palier> <cn> <uid>…`.

- [ ] **Step 1 : épreuves D.1–D.6** : D.1 chaîne jetable `[alpha, beta, gamma]`, gates `[{to: beta, deployerGroup: apim-apply-beta}]`, `DEPLOYERS_ALPHA=alice DEPLOYERS_BETA=bob` ⇒ `--print` : `alpha … NON`, `beta … OUI (deployerGroup=apim-apply-beta)` ; D.2 `demandeuse_exclue alpha` ⇒ rc 1, `beta` ⇒ rc 0, chaîne illisible ⇒ rc 2 (sourcé dans un sous-shell qui `return` avant le `MODE`, ou extrait par `sed -n '/^demandeuse_exclue()/,/^}/p'`) ; D.3 l'avertissement d'un palier sans déployeur cite `DEPLOYER_GROUP_REQUIRED` ET `PALIER_FERME` (vue code) ; D.4 mutation : `demandeuse_exclue` forcé à `return 0` ⇒ `alpha … OUI` (le détecteur verrait rouge) ; D.5 `--print` sans docker ni réseau ; D.6 `test-team-promote-wiring.sh` G2(viii) toujours vert (le bind reste `-e LDAP_BIND_PW` nu, `-y "$f"`).
- [ ] **Step 2 : rouge.**
- [ ] **Step 3 : implémenter** — après `deployers_for` :

```bash
# demandeuse_exclue <palier> — le read-back « la demandeuse n'est PAS membre »
# ne s'applique qu'aux paliers dont la PORTE déclare un deployerGroup : c'est
# l'axe (annuaire n°2, LDAP→Vault) que ce poseur protège. Jamais fourEyes (axe
# d'approbation, claim Keycloak) : un palier déclarant deployerGroup sans
# fourEyes est légal. Sur dev/rec (sans deployerGroup), la demandeuse membre
# d'apim-apply-<palier> est l'état voulu — le grant nominatif d'A3/ADR-082.
# rc 0 = s'applique · 1 = ne s'applique pas · 2 = chaîne illisible.
demandeuse_exclue() {
  local g
  g="$(env_chain_gate_deployer_group "$1")" || return 2
  [ -n "$g" ]
}
```

`read_back_group` prend le palier en premier argument ; le `case` alice est enveloppé : `if demandeuse_exclue "$palier"; then <case existant> ; else ok "$LAB_ALICE_USER membre autorisé de $cn (aucun deployerGroup déclaré pour $palier — grant nominatif A3)" ; fi` (rc 2 ⇒ `bad "chaîne illisible"`). `--print` : après le LDIF de chaque palier, la ligne de plan. L'avertissement « palier FERMÉ » : `apply refusera DEPLOYER_GROUP_REQUIRED si la porte déclare le groupe, PALIER_FERME pour toute identité sans le grant (A3)`. En-tête : remplacer « dev/rec : VIDES (fermés) » par « dev/rec : VIDES par défaut (fermés) — le grant A3 est `DEPLOYERS_DEV=alice DEPLOYERS_REC=alice …` ».

- [ ] **Step 4 : vert** (section D, `test-team-promote-wiring.sh` 159, `shellcheck`).
- [ ] **Step 5 : commit** — `feat(lab): setup-deployer-groups — read-back demandeuse conditionné au deployerGroup déclaré, ligne de plan --print (grant nominatif A3)`.

---

## T6 — `Makefile` `[12/12]` + passage complet hors ligne

- [ ] **Step 1 :** renuméroter `[k/11]` → `[k/12]` ; ajouter `scripts/selfservice-palier-gate.sh scripts/setup-wm-palier-admins.sh scripts/test-a3-live.sh` (T8 le crée — l'ajouter à T8 si absent à ce stade) à la ligne shellcheck ; ajouter `@echo "== [12/12] épreuves du credential du seul palier — garde, câblage, poseurs (A3)"` + `@bash scripts/test-selfservice-palier-a3.sh`.
- [ ] **Step 2 :** `make lint-ci` ⇒ `[12/12]` vert ; `EXPECTED_CHECKS` de la suite posé et vérifié.
- [ ] **Step 3 : commit** — `build(lint-ci): [12/12] — suite A3`.

---

## T7 — `scripts/test-palier-retention-live.sh` ⑦ « la voie application » (lab : Vault)

**Fichiers :** modifier `scripts/test-palier-retention-live.sh` (après ⑤, avant ⑥ ; helpers, teardown).

- [ ] **Step 1 : écrire ⑦.** `THIRD="$(echo "$ENVS" | awk '{print $3}')"` ; `[ -n "$THIRD" ] || lab_absent "…au moins trois paliers hors-prod…"` ; token modèle : `auth/token/create` `{"policies":["deploy-$TENANT","apply-$SECOND"],"ttl":"5m"}` (fichier d'en-tête `$TMP/apphdr`) ; ⑦a `rd apphdr SECOND` = 200 ; ⑦b `rd apphdr THIRD` = 403 ; ⑦c `envs/$THIRD/admin-oauth` = 403 ; ⑦d terminus = 403 ; manifeste jetable `$TMP/probe.yml` (`apim_ss_app: {name: probe-g4, team: $TENANT, api: x, api_version: "1", per_env: {$SECOND: {}, $THIRD: {}}}`) ; token du modèle écrit dans `$TMP/apptok` (0600, via python depuis la réponse, jamais en variable interpolée) ; ⑦e `ENVIRONMENT=$SECOND ADMIN_VIA=direct MANIFEST=… VAULT_TOKEN_FILE=$TMP/apptok PALIER_OUT=$TMP/p.out APIM_KV_PREFIX=stoa bash scripts/selfservice-palier-gate.sh` ⇒ rc 0, `APIM_WM_CREDS_SUB=envs/$SECOND/wm-admin`, `PALIER_TEAM=$TENANT` ; ⑦f `ENVIRONMENT=$THIRD` ⇒ rc 1 `PALIER_FERME`, pas de `$TMP/p.out` ; ⑦g F4 : `POLICY_REVOKED=1`, `DELETE apply-$SECOND`, geste (`gate && curl canari/apply-app-$SECOND`) ⇒ fermé, canari sans `apply-app-` ; ⑦h `restore_policy` ⇒ geste vert, canari exactement 1 `apply-app-$SECOND` ; ⑦i révocation du token modèle (`revoke-self`) ; ⑦j rejeu de `restore_policy` sans effet (idempotent). Le canari de ④ est réutilisé (encore vivant : `kill "$CPID"` n'a lieu qu'en ⑥).
- [ ] **Step 2 :** rouge tant que T1 n'est pas dans l'arbre (déjà fait) — vérifier en lançant contre le lab : `VAULT_TOKEN=$(docker exec poc-vault printenv VAULT_DEV_ROOT_TOKEN_ID) bash scripts/test-palier-retention-live.sh` ⇒ tout ⑦ vert, total `N PASS / 0 FAIL` (N = 24 + les nouvelles).
- [ ] **Step 3 : commit** — `test(g4-live): ⑦ la voie application — matrice 403 sur l'identité de l'apply d'app, garde A3 jouée, F4 sur cette voie`.

---

## T8 — `scripts/test-a3-live.sh` + rollout + régression A2 (lab : Gitea + Jenkins + Vault + 10.15)

**Fichiers :** créer `scripts/test-a3-live.sh` (base : `test-provision-apply-a2-live.sh` — helpers copiés : `gapi`, `aapi`, `jcrumb`, `jstatus`, `jresult`, `jnext`, `jconsole`, `jinput_id`, `wait_until`, `fire_webhook`, `gw`, `gw_app`, `gw_app_ip`, cleanup) ; modifier `scripts/test-provision-apply-a2-live.sh` 0.9.

- [ ] **Step 1 : rollout (l'ordre est une contrainte)** : `git push gitea HEAD:main` ; `VAULT_TOKEN=… GW_ADMIN=http://localhost:5555/rest/apigateway WM_USER=Administrator WM_PASS=manage bash scripts/setup-wm-palier-admins.sh` ⇒ 4 comptes, login prouvé ; `DEPLOYERS_DEV=alice DEPLOYERS_REC=alice bash scripts/setup-deployer-groups.sh` ⇒ rc 0 ; contrôle : login LDAP alice ⇒ policies contiennent `apply-rec` (via `.env.lab-users`, `set -a`).
- [ ] **Step 2 : écrire `test-a3-live.sh`** (spec D7, marqueurs) :
  - 0.x préconditions : Jenkins/Gitea/gateway ; token ci ; `selfservice-app-deploy` from SCM et ses 8 paramètres ; `APPLY_ADMIN_VIA=direct` global ; aucune pause ; API active ; alice Gitea (créée/collab si absente) ; **alice Vault LDAP** : login ⇒ lookup-self policies ⊇ `{deploy-banking-demo, apply-rec}` (sinon `PREREQUIS : jouer DEPLOYERS_REC=alice scripts/setup-deployer-groups.sh`), lit `envs/rec/wm-admin` 200, **ne lit pas** `envs/int/wm-admin` 403 (la matrice sur l'identité réelle) ; `envs/rec/wm-admin` s'authentifie sur la gateway (lecture par root Vault, `-K`, `GET /applications` ⇒ 200, sinon `PREREQUIS : jouer scripts/setup-wm-palier-admins.sh`) ; tête de main ; aucune app homonyme.
  - 1.x PORTE : `provision-request.sh` rec `a3p$TS` (`10.42.0.1`, idp, sans team) ⇒ PR ; merge alice ; pause ; réponse ; SUCCESS amont/aval ; console aval : `palier ouvert : envs/rec/wm-admin`, `PALIER_CREDS=envs/rec/wm-admin`, `PALIER_TEAM=banking-demo`, ordre `palier ouvert` < `préflight de joignabilité` < `PLAY [Self-service application — converge` < `PLAY [Self-service application — verify` (`grep -n` + comparaison), aucune occurrence `deploy/banking-demo/wm-admin`, `failed=0` ; gateway : app présente (id capturé), claim `a3p$TS-rec`, IP `10.42.0.1-10.42.0.1` ; PR ✅ + SHA.
  - 2.x MATRICE PAR BUILD : `main` reçoit `per_env.int` (API contents PUT : ligne `    int: { auth: { claim: { value: "a3p$TS-int" } }, ip_allowlist: ["10.42.0.3"] }` insérée après la ligne `rec:`) ; `buildWithParameters` direct (crumb, form : `MANIFEST`, `ENVIRONMENT=int`, `ADMIN_VIA=direct`, `MERGE_SHA=`, `VAULT_USER=alice`, `VAULT_USER_PASSWORD`) ⇒ numéro via `nextBuildNumber` avant/après ; FAILURE ; console : `REFUS: PALIER_FERME`, `envs/int/wm-admin`, `HTTP 403`, aucun `préflight de joignabilité`, aucun `PLAY [Self-service application`, `mort PROUVÉE` ; gateway : claims == `[a3p$TS-rec]`, IP inchangée.
  - 3.x F4 : backup policy `apply-rec` (root), `POLICY_REVOKED=1`, DELETE, 404 ; build direct rec `MERGE_SHA=$MERGE_SHA` ⇒ FAILURE `PALIER_FERME` (`envs/rec/wm-admin`), aucun préflight/PLAY, mort prouvée ; gateway inchangée ; `restore_policy` (PUT + relecture `cmp`).
  - 4.x REJEU : build direct rec `MERGE_SHA=$MERGE_SHA` ⇒ SUCCESS, `palier ouvert`, `gw_app` id == id de 1.x.
  - 5.x MESURE : `envs/rec/wm-admin` lit `paiements-sepa` (dev) sur la gateway unique ⇒ ligne `MESURE :` (jamais un `ko`).
  - cleanup : PR/branches, manifeste retiré de main, app supprimée, policy restaurée (trap, motif G4 : `POLICY_REVOKED` déclaré avant le trap).
- [ ] **Step 3 : jouer** : `set -a; . ./.env.lab-users; set +a; JENKINS_UI=http://localhost:18080 GITEA_URL=http://localhost:13000 GW_ADMIN=http://localhost:5555/rest/apigateway WM_USER=Administrator WM_PASS=manage VAULT_TOKEN=… bash scripts/test-a3-live.sh` (recycler `poc-webmethods-real` avant si uptime ≥ 20 min) ⇒ `RÉSULTAT : N/N`.
- [ ] **Step 4 : régression** : `test-provision-apply-a2-live.sh` 0.9 complété (`envs/rec/wm-admin` lisible par alice) puis rejoué ⇒ 60/60 ; `test-selfservice-form-live.sh` rejoué ⇒ 14/14.
- [ ] **Step 5 : commit** — `test(a3-live): porte + matrice par build + F4 + rejeu, par builds réels ; régression A2 rejouée` (les commits d'artefacts des suites — merges de PR jetables, retraits — sont ceux de la forge, à rapatrier par `git pull gitea main` comme pour A2).

---

## T9 — Documentation, statuts, mémoire

- [ ] `ENVIRONNEMENTS.md` : section « Le credential du seul palier (A3 — GOAL cd-applications) » après « La référence d'une application (A2) » : le dessin, les knobs (`APIM_WM_CREDS_SUB_TPL`, `APIM_OAUTH_SUB_TPL`, `APIM_TERMINUS_BASE`, `APIM_TOKEN_TTL_MIN`, `APIM_TEAM` borné), les refus, le rollout (D8), le grant de lab, les limites (D9) ; corriger la « limite écrite d'avance » d'A2 (ligne ~807 : le palier n'est plus un en-tête).
- [ ] `adr/adr-082-…md` : section « Extension 2026-09-02 (A3) — le second objet » : le ticket `PALIER_FERME` porté à l'apply d'application, la garde depuis la lignée de main, l'équipe décidée par le token, `TICKET_INSCRIPTIBLE`, `TERMINUS_SANS_VOIE`, les limites (mono-gateway du lab, ticket par palier et non par objet).
- [ ] `GOAL-cd-applications-2026-09-02.md` : bloc « LIVRÉ le 2026-09-02 » sous A3 (résumé + chiffres des suites + numéros de builds) ; tableau des trous (ligne « Credential par palier ») mis à jour.
- [ ] Spec et plan : statuts `LIVRÉ`.
- [ ] Mémoire : `a3-credential-du-seul-palier.md` + index ; `cd-applications-goal.md` (A3 livré, prochain A4).
- [ ] Commits docs ; `git push gitea HEAD:main`.
