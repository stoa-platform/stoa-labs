# Initialisation des dépôts fournisseurs — plan 1 : socle + `scan`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** produire `estate.<env>.json` — l'inventaire fidèle et fail-closed d'un parc webMethods 10.15 existant, lu **à travers le proxy d'admin**, en lecture seule.

**Architecture:** deux libs sourçables (`apim-base.sh` compose la base d'admin et dérive la voie ; `wm-admin-curl.sh` porte l'appel HTTP authentifié sans secret en argv) puis un exécutable `scan-parc.sh` qui inventorie, groupe par lignée d'API, nomme huit situations de parc et écrit un JSON déterministe. Aucune écriture gateway, aucune écriture forge.

**Tech Stack:** bash (POSIX-compatible là où Jenkins l'exige), `curl`, `python3` (json/yaml — le conteneur Jenkins n'a pas `jq`), harnais de test bash avec faux serveur HTTP python.

**Spec:** `docs/superpowers/specs/2026-09-07-init-depots-fournisseurs-design.md`

## Global Constraints

- **Aucun défaut de site dans le code livrable.** `ci/lint-config-knobs.sh` (porte `make lint-ci`) scanne `scripts/*.sh`. Un knob absent ⇒ refus nommé, jamais une URL de lab.
- **Aucun secret en argv.** Fichier d'en-tête `0600` sous `umask 077`, nettoyé par `trap … EXIT`. Motif de référence : `scripts/assign-api-team.sh:37-43`.
- **Refus nommés, identifiant en TÊTE de message, en français, sur stderr.** stdout d'un script porte son produit, rien d'autre.
- **Fail-closed.** Un parse qui échoue refuse ; il n'est jamais lu comme une valeur par défaut (discipline `team-apply.sh:190-196`).
- **Toute épreuve ajoutée doit ROUGIR par mutation.** Une épreuve qui ne rougit jamais est un vert vacant.
- **Base d'admin proxifiée** : `<APIM_PROXY_HOST>/gateway/<APIM_PROXY_API>/<APIM_PROXY_VER><APIM_PROXY_PATH>`. Jamais `http://host:5555/rest/apigateway`.
- **Le préflight ne vise pas `/health`** (injoignable chez le client) : `<BASE>/apis` sans jeton, codes `200 401`.
- **`apim_ss_oauth_client_auth` vaut `basic`** chez ce client (l'AS local wM refuse `post` hors HTTPS).
- `set -uo pipefail` en tête de chaque script ; `shellcheck` propre.

---

## Structure des fichiers

| Fichier | Responsabilité |
|---|---|
| `scripts/lib/apim-base.sh` *(créé)* | compose la base d'admin, dérive la voie et le mode d'auth, porte `APIM_BASE_INVALIDE` / `VIA_INCONNU` / `TERMINUS_SANS_VOIE` |
| `scripts/selfservice-palier-gate.sh` *(modifié)* | consomme la lib au lieu de composer en ligne — refactor à comportement constant |
| `scripts/lib/wm-admin-curl.sh` *(créé)* | l'appel HTTP : en-tête d'auth en fichier, préflight knobé, distinction 401-authn / 401-authz |
| `scripts/lib/estate.sh` *(créé)* | normalisation d'enveloppe, prédicat `isActive`, groupement par lignée, les huit verdicts |
| `scripts/scan-parc.sh` *(créé)* | l'exécutable : orchestre, écrit `estate.<env>.json`, `contrats/`, `rapport.md` |
| `scripts/test-apim-base.sh` *(créé)* | épreuves de la lib de base + parité avec la garde |
| `scripts/test-scan-parc.sh` *(créé)* | épreuves du scan contre un faux wM en python |

---

### Task 1 : `scripts/lib/apim-base.sh` — composer la base, dériver la voie

**Files:**
- Create: `poc-control-plane-federation/scripts/lib/apim-base.sh`
- Test: `poc-control-plane-federation/scripts/test-apim-base.sh`

**Interfaces:**
- Consumes: rien (première tâche).
- Produces: `apim_base_resolve()` — lit l'environnement, pose `APIM_BASE`, `APIM_EFFECTIVE_VIA` (`direct`|`proxy-oauth2`), `APIM_AUTH_MODE` (`basic`|`oauth2`) ; rend `0`, ou `1` après avoir écrit un refus nommé sur stderr. Variables lues : `ENVIRONMENT`, `ADMIN_VIA`, `APIM_API_BASE`, `APIM_TERMINUS_BASE`, `APIM_PROXY_BASE`, `APIM_PROXY_HOST`, `APIM_PROXY_API`, `APIM_PROXY_VER`, `APIM_PROXY_PATH`, plus `APIM_TERMINUS` (nom du terminus, injecté par l'appelant — la lib ne lit pas la chaîne d'environnements elle-même).

- [ ] **Step 1 : écrire les épreuves qui échouent**

Créer `scripts/test-apim-base.sh` :

```bash
#!/usr/bin/env bash
# test-apim-base.sh — preuve X/X de scripts/lib/apim-base.sh : composition de
# la base d'admin, dérivation de la voie et du mode d'auth, et les trois refus
# nommés. TOUT EN LOCAL, aucun réseau.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO/scripts/lib/apim-base.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# run <VAR=val…> -- appelle apim_base_resolve dans un sous-shell propre et
# imprime "rc|BASE|VIA|AUTH" sur stdout, le refus sur stderr.
run(){
  env -i PATH="$PATH" HOME="$HOME" "$@" bash -c '
    . "'"$LIB"'" || exit 9
    if apim_base_resolve; then printf "0|%s|%s|%s\n" "$APIM_BASE" "$APIM_EFFECTIVE_VIA" "$APIM_AUTH_MODE"
    else printf "1|||\n"; fi' 2>"$ERRF"
}
ERRF="$(mktemp)"; trap 'rm -f "$ERRF"' EXIT

echo "== 1. composition proxy =="
R="$(run ENVIRONMENT=dev ADMIN_VIA=proxy-oauth2 APIM_TERMINUS=prod \
      APIM_PROXY_HOST=https://apim.vip:5543 APIM_PROXY_API=wm-admin-__ENV__ \
      APIM_PROXY_VER=1.0 APIM_PROXY_PATH=/rest/apigateway)"
[ "$R" = "0|https://apim.vip:5543/gateway/wm-admin-dev/1.0/rest/apigateway|proxy-oauth2|oauth2" ] \
  && ok "proxy : base composée, __ENV__ substitué, auth dérivée oauth2" \
  || ko "proxy : rendu '$R'"

echo "== 2. APIM_PROXY_BASE écrase les quatre morceaux =="
R="$(run ENVIRONMENT=rec ADMIN_VIA=proxy-oauth2 APIM_TERMINUS=prod \
      APIM_PROXY_BASE=https://autre/__ENV__/adm APIM_PROXY_HOST=https://ignore \
      APIM_PROXY_API=x APIM_PROXY_VER=9 APIM_PROXY_PATH=/z)"
[ "$R" = "0|https://autre/rec/adm|proxy-oauth2|oauth2" ] \
  && ok "APIM_PROXY_BASE gagne, et __ENV__ y est substitué aussi" || ko "override : rendu '$R'"

echo "== 3. le terminus force la voie directe =="
R="$(run ENVIRONMENT=prod ADMIN_VIA=proxy-oauth2 APIM_TERMINUS=prod \
      APIM_TERMINUS_BASE=https://prod.adm/rest/apigateway)"
[ "$R" = "0|https://prod.adm/rest/apigateway|direct|basic" ] \
  && ok "terminus : direct/basic malgré ADMIN_VIA=proxy-oauth2" || ko "terminus : rendu '$R'"

echo "== 4. les trois refus nommés =="
run ENVIRONMENT=dev ADMIN_VIA= APIM_TERMINUS=prod >/dev/null
grep -q '^REFUS: VIA_INCONNU' "$ERRF" && ok "ADMIN_VIA vide ⇒ VIA_INCONNU (aucun repli silencieux)" \
  || ko "ADMIN_VIA vide : stderr='$(cat "$ERRF")'"

run ENVIRONMENT=prod ADMIN_VIA=direct APIM_TERMINUS=prod >/dev/null
grep -q '^REFUS: TERMINUS_SANS_VOIE' "$ERRF" && ok "terminus sans APIM_TERMINUS_BASE ⇒ TERMINUS_SANS_VOIE" \
  || ko "terminus sans base : stderr='$(cat "$ERRF")'"

run ENVIRONMENT=dev ADMIN_VIA=proxy-oauth2 APIM_TERMINUS=prod \
    APIM_PROXY_HOST=https://h APIM_PROXY_API= APIM_PROXY_VER=1.0 APIM_PROXY_PATH=/p >/dev/null
grep -q '^REFUS: APIM_BASE_INVALIDE' "$ERRF" && ok "un composant VIDE ⇒ APIM_BASE_INVALIDE (jamais '//' accepté)" \
  || ko "composant vide : stderr='$(cat "$ERRF")'"

run ENVIRONMENT=dev ADMIN_VIA=direct APIM_TERMINUS=prod APIM_API_BASE=pas-une-url >/dev/null
grep -q '^REFUS: APIM_BASE_INVALIDE' "$ERRF" && ok "base non http(s) ⇒ APIM_BASE_INVALIDE" \
  || ko "base non http : stderr='$(cat "$ERRF")'"

printf '\n%d ✅  %d ❌\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2 : lancer les épreuves, vérifier qu'elles échouent**

```bash
cd poc-control-plane-federation && bash scripts/test-apim-base.sh
```
Attendu : ÉCHEC — `apim-base.sh` n'existe pas, chaque `run` rend `rc 9`, les 8 assertions sont rouges.

- [ ] **Step 3 : écrire la lib**

Créer `scripts/lib/apim-base.sh`. Le corps de la composition est **repris** de `scripts/selfservice-palier-gate.sh:104-125` — le lire d'abord et ne pas le réinventer :

```bash
#!/usr/bin/env bash
# scripts/lib/apim-base.sh — LA composition de la base d'admin webMethods.
#
# POURQUOI CETTE LIB (2026-09-07). La composition vivait dans
# selfservice-palier-gate.sh, monolithique (refus() fait exit 1, trap EXIT) :
# inextractible pour un autre appelant. Le scan de parc en a besoin. Même
# réflexe que scripts/lib/vault-kv.sh, créée pour la même raison.
#
# À SOURCER. apim_base_resolve pose APIM_BASE, APIM_EFFECTIVE_VIA, APIM_AUTH_MODE.
#
# ENTRÉES (aucun défaut de SITE — lint-config-knobs.sh les refuse) :
#   ENVIRONMENT         le palier visé
#   APIM_TERMINUS       le nom du terminus (l'appelant le résout ; la lib ne
#                       lit pas la chaîne d'environnements — elle n'en dépend pas)
#   ADMIN_VIA           direct | proxy-oauth2 — SANS DÉFAUT (VIA_INCONNU sinon)
#   APIM_API_BASE       base directe, gabarit avec __ENV__
#   APIM_TERMINUS_BASE  base directe du terminus
#   APIM_PROXY_BASE     override complet du proxy (gagne sur les 4 morceaux)
#   APIM_PROXY_{HOST,API,VER,PATH}  les quatre morceaux
_ab_refus(){ echo "REFUS: $1 : $2" >&2; return 1; }
_ab_sub_env(){ printf '%s' "$1" | sed "s/__ENV__/${ENVIRONMENT}/g"; }

apim_base_resolve(){
  local envn="${ENVIRONMENT:-}" via="${ADMIN_VIA:-}" term="${APIM_TERMINUS:-}"
  [ -n "$envn" ] || { _ab_refus ENV_REQUIS "ENVIRONMENT n'est pas posé"; return 1; }
  case "$via" in direct|proxy-oauth2) ;; *)
    _ab_refus VIA_INCONNU "'${via}' — attendu direct ou proxy-oauth2 (aucun repli : un ADMIN_VIA vide basculait autrefois du proxy vers le Basic direct, sans un mot)"; return 1;; esac

  if [ -n "$term" ] && [ "$envn" = "$term" ]; then
    [ -n "${APIM_TERMINUS_BASE:-}" ] || {
      _ab_refus TERMINUS_SANS_VOIE "le palier terminus '${envn}' n'a pas d'APIM_TERMINUS_BASE"; return 1; }
    APIM_EFFECTIVE_VIA=direct; APIM_BASE="$(_ab_sub_env "$APIM_TERMINUS_BASE")"
  elif [ "$via" = direct ]; then
    APIM_EFFECTIVE_VIA=direct; APIM_BASE="$(_ab_sub_env "${APIM_API_BASE:-}")"
  else
    APIM_EFFECTIVE_VIA=proxy-oauth2
    if [ -n "${APIM_PROXY_BASE:-}" ]; then
      APIM_BASE="$(_ab_sub_env "$APIM_PROXY_BASE")"
    else
      # Un composant VIDE produit une URL syntaxiquement valide (« …/gateway//1.0/… »)
      # que le contrôle de forme laisserait passer : on les teste UN PAR UN.
      local c
      for c in APIM_PROXY_HOST:"${APIM_PROXY_HOST:-}" APIM_PROXY_API:"${APIM_PROXY_API:-}" \
               APIM_PROXY_VER:"${APIM_PROXY_VER:-}" APIM_PROXY_PATH:"${APIM_PROXY_PATH:-}"; do
        [ -n "${c#*:}" ] || { _ab_refus APIM_BASE_INVALIDE "${c%%:*} est vide — le gabarit d'URL admin ne peut pas être composé (poser la variable, ou fournir APIM_PROXY_BASE)"; return 1; }
      done
      APIM_BASE="$(_ab_sub_env "${APIM_PROXY_HOST}/gateway/${APIM_PROXY_API}/${APIM_PROXY_VER}${APIM_PROXY_PATH}")"
    fi
  fi

  case "$APIM_BASE" in http://*|https://*) ;; *)
    _ab_refus APIM_BASE_INVALIDE "'${APIM_BASE}' — le gabarit d'URL admin doit produire une URL http(s)"; return 1;; esac
  APIM_BASE="${APIM_BASE%/}"
  if [ "$APIM_EFFECTIVE_VIA" = direct ]; then APIM_AUTH_MODE=basic; else APIM_AUTH_MODE=oauth2; fi
  export APIM_BASE APIM_EFFECTIVE_VIA APIM_AUTH_MODE
}
```

- [ ] **Step 4 : lancer les épreuves, vérifier qu'elles passent**

```bash
cd poc-control-plane-federation && bash scripts/test-apim-base.sh && shellcheck scripts/lib/apim-base.sh
```
Attendu : `8 ✅  0 ❌`, rc 0, `shellcheck` muet.

- [ ] **Step 5 : prouver par MUTATION que les épreuves rougissent**

Trois mutations, une par refus. Après chacune : relancer, constater le rouge, **restaurer**.

```bash
cd poc-control-plane-federation
# M1 : rendre ADMIN_VIA tolérant (le bug historique)
sed -i.bak 's/local envn="${ENVIRONMENT:-}" via="${ADMIN_VIA:-}"/local envn="${ENVIRONMENT:-}" via="${ADMIN_VIA:-direct}"/' scripts/lib/apim-base.sh
bash scripts/test-apim-base.sh; echo "attendu: au moins 1 ❌"
mv scripts/lib/apim-base.sh.bak scripts/lib/apim-base.sh
# M2 : retirer le contrôle composant-par-composant
# M3 : retirer le contrôle de forme http(s)
```
Attendu : chaque mutation produit au moins un ❌, et la restauration ramène `8 ✅  0 ❌`.

- [ ] **Step 6 : commit**

```bash
git add poc-control-plane-federation/scripts/lib/apim-base.sh poc-control-plane-federation/scripts/test-apim-base.sh
git commit -m "feat(apim-base): extraire la composition de la base d'admin dans une lib sourçable"
```

---

### Task 2 : brancher la garde du palier sur la lib — comportement constant

**Files:**
- Modify: `poc-control-plane-federation/scripts/selfservice-palier-gate.sh:104-125`
- Test: `poc-control-plane-federation/scripts/test-apim-base.sh` (section « parité » ajoutée)

**Interfaces:**
- Consumes: `apim_base_resolve()` de la Task 1.
- Produces: rien de nouveau. La garde continue d'exposer `BASE`, `EFFECTIVE_VIA`, `AUTH_MODE` **sous leurs noms actuels** à la suite du script.

- [ ] **Step 1 : lire la spécification exécutable existante**

```bash
cd poc-control-plane-federation && sed -n '300,380p' ci/test-proxy-base-et-preflight.sh
```
Ce fichier **est** le contrat de comportement de la garde. Il ne doit pas être modifié par cette tâche.

- [ ] **Step 2 : écrire l'épreuve de parité (elle doit échouer)**

Ajouter à la fin de `scripts/test-apim-base.sh`, avant le compteur final :

```bash
echo "== 5. parité lib ↔ garde (le refactor ne doit RIEN changer) =="
GATE="$REPO/scripts/selfservice-palier-gate.sh"
# La garde compose-t-elle encore en ligne ? Après le refactor, elle DOIT sourcer la lib.
grep -q 'apim-base\.sh' "$GATE" \
  && ok "la garde source scripts/lib/apim-base.sh (plus de composition recopiée)" \
  || ko "la garde compose toujours la base en ligne — la duplication subsiste"
grep -q 'gateway/\${APIM_PROXY_API}' "$GATE" \
  && ko "la garde porte ENCORE le gabarit d'URL en dur (deux vérités)" \
  || ok "le gabarit d'URL n'existe plus qu'à un seul endroit"
```

- [ ] **Step 3 : lancer, vérifier l'échec**

```bash
cd poc-control-plane-federation && bash scripts/test-apim-base.sh
```
Attendu : les deux nouvelles assertions sont ❌ (la garde n'a pas encore été modifiée).

- [ ] **Step 4 : modifier la garde**

Dans `scripts/selfservice-palier-gate.sh`, remplacer le bloc `:104-125` par un appel à la lib, en conservant les noms de variables locales que la suite du script utilise :

```bash
# shellcheck source=scripts/lib/apim-base.sh
. "$(dirname "$0")/lib/apim-base.sh" || refus LIB_ABSENTE "scripts/lib/apim-base.sh"
# La lib rend 1 après avoir écrit son refus nommé ; la garde le relaie tel quel
# et sort — les identifiants (VIA_INCONNU, TERMINUS_SANS_VOIE, APIM_BASE_INVALIDE)
# sont INCHANGÉS, les greps existants continuent de matcher.
APIM_TERMINUS="$TERMINUS" apim_base_resolve || exit 1
BASE="$APIM_BASE"; EFFECTIVE_VIA="$APIM_EFFECTIVE_VIA"; AUTH_MODE="$APIM_AUTH_MODE"
```

- [ ] **Step 5 : prouver le comportement constant**

```bash
cd poc-control-plane-federation
bash ci/test-proxy-base-et-preflight.sh 2>&1 | tail -20 ; echo "rc=${PIPESTATUS[0]}"
bash scripts/test-selfservice-palier-a3.sh 2>&1 | tail -10
bash scripts/test-apim-base.sh
shellcheck scripts/selfservice-palier-gate.sh scripts/lib/apim-base.sh
```
Attendu : `ci/test-proxy-base-et-preflight.sh` **inchangé et vert** (c'est la preuve du comportement constant), `test-selfservice-palier-a3.sh` vert, `10 ✅  0 ❌`.

- [ ] **Step 6 : commit**

```bash
git add poc-control-plane-federation/scripts/selfservice-palier-gate.sh poc-control-plane-federation/scripts/test-apim-base.sh
git commit -m "refactor(palier-gate): consommer apim-base.sh au lieu de composer la base en ligne"
```

---

### Task 3 : `scripts/lib/wm-admin-curl.sh` — l'appel authentifié, sans secret en argv

**Files:**
- Create: `poc-control-plane-federation/scripts/lib/wm-admin-curl.sh`
- Test: `poc-control-plane-federation/scripts/test-scan-parc.sh` (créé ici, section 1)

**Interfaces:**
- Consumes: `APIM_BASE`, `APIM_AUTH_MODE` (Task 1).
- Produces:
  - `wm_admin_init()` — construit le fichier d'en-tête `0600` (Basic ou Bearer), pose `WM_HDR` (chemin du fichier), enregistre son nettoyage. Rend 1 + refus nommé si l'identifiant manque.
  - `wm_get <chemin> <fichier de sortie>` — un GET ; imprime le code HTTP sur stdout, écrit le corps dans le fichier. Ne suit jamais de redirection.
  - `wm_preflight()` — sonde `<BASE>/apis` **sans jeton** ; accepte `APIM_PREFLIGHT_CODES` (défaut `200 401`) ; honore `APIM_PREFLIGHT=off` et `APIM_PREFLIGHT_URL`. Rend 0/1.
  - `wm_diag_401 <fichier de corps>` — rend la phrase à servir à l'ops, distinguant « identifiant refusé » de « compte hors groupe d'admin ».

- [ ] **Step 1 : écrire les épreuves qui échouent**

Créer `scripts/test-scan-parc.sh` avec le harnais et la section 1 :

```bash
#!/usr/bin/env bash
# test-scan-parc.sh — preuve X/X du scan de parc. TOUT EN LOCAL : le « wM » est
# un faux serveur HTTP python qui sert les ENVELOPPES réelles de la 10.15.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/scanparc.XXXXXX)"
PORT="${FAKE_WM_PORT:-18620}"
PID=""
cleanup(){ [ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# ── faux wM 10.15 : enveloppes RÉELLES (teams au niveau de l'entrée, pas dans api) ──
cat > "$TMP/fakewm.py" <<'PY'
import json, os
from http.server import BaseHTTPRequestHandler, HTTPServer
APIS = [
  # (id, name, version, isActive, teams)
  ("g-pai-100", "paiements", "1.0.0", True,  ["toto", "Administrators"]),
  ("g-pai-101", "paiements", "1.0.1", True,  ["Default", "Administrators"]),   # lignée mixte
  ("g-vir-100", "virements", "1.0.0", True,  ["toto", "titi"]),                # multi-équipes
  ("g-leg-100", "legacy_API", "1.0.0", True, ["toto"]),                        # nom hors regex
  ("g-off-100", "offline-api", "1.0.0", False, ["toto"]),                      # inactive
  ("g-orp-100", "orpheline", "1.0.0", True,  ["Default", "Administrators"]),   # non appropriée
]
def env(a):
    i, n, v, act, teams = a
    return {"api": {"id": i, "apiName": n, "apiVersion": v, "isActive": act},
            "responseStatus": "SUCCESS",
            "teams": [{"id": "u-"+t, "name": t} for t in teams]}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj=None):
        b = json.dumps(obj if obj is not None else {}).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        auth = self.headers.get("Authorization")
        p = self.path.split("?")[0]
        if not auth:
            return self._send(401, {"error": "no token"})     # la preuve de vie du proxy
        if auth == "Basic SANS-GROUPE":
            return self._send(401, {"error": "User is not a member of any administrator group"})
        if p.endswith("/apis"):
            return self._send(200, {"apiResponse": [env(a) for a in APIS]})
        if "/apis/" in p:
            gid = p.rsplit("/", 1)[1]
            for a in APIS:
                if a[0] == gid:
                    e = env(a); e["api"]["apiDefinition"] = {
                        "openapi": "3.0.1", "info": {"title": a[1], "version": a[2]},
                        "paths": {"/x": {"get": {"responses": {"200": {"description": "OK"}}}}}}
                    return self._send(200, {"apiResponse": e})
            return self._send(404)
        if p.endswith("/applications"):
            return self._send(200, {"applications": [{"id": "app-1", "name": "app-front"}]})
        if "/applications/" in p:
            return self._send(200, {"applications": [{
                "id": "app-1", "name": "app-front", "owner": "toto", "ownerType": "team",
                "teams": [{"name": "toto"}],
                "consumingAPIs": ["g-pai-100"],
                "identifiers": [{"key": "apiKey", "value": "SECRET-QUI-NE-DOIT-PAS-FUIR"},
                                {"key": "ip", "value": ["10.0.0.0/8"]}]}]})
        return self._send(404)
HTTPServer(("127.0.0.1", int(os.environ["PORT"])), H).serve_forever()
PY
PORT="$PORT" python3 "$TMP/fakewm.py" & PID=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/apis" && break; sleep 0.1
done
BASE="http://127.0.0.1:$PORT"

echo "== 1. wm-admin-curl : auth, préflight, diagnostic =="
LIBC="$REPO/scripts/lib/wm-admin-curl.sh"

# 1a. aucun secret en argv : on sonde ps pendant un appel lent
OUT="$(APIM_BASE="$BASE" APIM_AUTH_MODE=basic WM_USER=adm WM_PASSWORD=s3cr3t \
  bash -c '. "'"$LIBC"'" && wm_admin_init && ( sleep 1; ) & sleep 0.3; ps -Aww 2>/dev/null | grep -c "s3cr3t" || true')"
[ "${OUT:-1}" = "0" ] && ok "aucun secret dans l'argv d'aucun process (sonde ps -Aww)" \
  || ko "le secret apparaît dans un argv (${OUT} occurrence(s))"

# 1b. le fichier d'en-tête est 0600
M="$(APIM_BASE="$BASE" APIM_AUTH_MODE=basic WM_USER=adm WM_PASSWORD=s3cr3t \
  bash -c '. "'"$LIBC"'" && wm_admin_init && stat -f "%Lp" "$WM_HDR" 2>/dev/null || stat -c "%a" "$WM_HDR"')"
[ "$M" = "600" ] && ok "le fichier d'en-tête est en 0600" || ko "mode du fichier d'en-tête : '$M'"

# 1c. préflight : 401 SANS jeton est une preuve de vie
APIM_BASE="$BASE" bash -c '. "'"$LIBC"'" && wm_preflight' >/dev/null 2>"$TMP/pf.err" \
  && ok "préflight : 401 sans jeton accepté comme preuve de vie (200 401)" \
  || ko "préflight refusé alors que le faux wM rend 401 : $(cat "$TMP/pf.err")"

# 1d. le préflight ne vise PAS /health
APIM_BASE="$BASE" bash -c '. "'"$LIBC"'" && printf "%s\n" "$WM_PREFLIGHT_URL"' 2>/dev/null \
  | grep -q '/apis$' && ok "la sonde par défaut est <BASE>/apis, jamais /health" \
  || ko "la sonde par défaut n'est pas <BASE>/apis"

# 1e. APIM_PREFLIGHT=off désactive
APIM_BASE="http://127.0.0.1:1" APIM_PREFLIGHT=OFF bash -c '. "'"$LIBC"'" && wm_preflight' >/dev/null 2>&1 \
  && ok "APIM_PREFLIGHT=OFF désactive (comparaison insensible à la casse)" \
  || ko "APIM_PREFLIGHT=OFF n'a pas désactivé le préflight"

# 1f. les deux causes d'un 401 sont distinguées
printf '{"error":"User is not a member of any administrator group"}' > "$TMP/401.json"
bash -c '. "'"$LIBC"'" && wm_diag_401 "'"$TMP"'/401.json"' 2>&1 | grep -qi "droits de lecture" \
  && ok "401 d'AUTORISATION : le diagnostic demande les droits de lecture, pas un mot de passe" \
  || ko "le diagnostic ne distingue pas les deux causes d'un 401"

printf '\n%d ✅  %d ❌\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2 : lancer, vérifier l'échec**

```bash
cd poc-control-plane-federation && bash scripts/test-scan-parc.sh
```
Attendu : ÉCHEC — `scripts/lib/wm-admin-curl.sh` n'existe pas, les 6 assertions sont rouges.

- [ ] **Step 3 : écrire la lib**

Créer `scripts/lib/wm-admin-curl.sh` :

```bash
#!/usr/bin/env bash
# scripts/lib/wm-admin-curl.sh — l'appel HTTP vers l'admin webMethods.
#
# LE SECRET NE PASSE JAMAIS PAR ARGV. Motif de assign-api-team.sh:37-43 :
# un fichier d'en-tête 0600, lu par `curl -H @fichier`. `curl -u` et
# `-H "Authorization: …"` mettent tous deux le secret dans l'argv, visible
# par `ps -Aww` de tout utilisateur de la machine pendant toute la durée.
#
# LE PRÉFLIGHT NE VISE PAS /health : chez un client il peut être injoignable
# depuis la VIP ou filtré en amont (ci/Jenkinsfile.selfservice:503-507). La
# sonde est <BASE>/apis SANS jeton : un 401 dit que le proxy est vivant ET
# que son OAuth2 est enforce — c'est plus fort qu'un /health.
_wm_refus(){ echo "REFUS: $1 : $2" >&2; return 1; }

wm_admin_init(){
  local old_umask; old_umask="$(umask)"; umask 077
  WM_HDR="$(mktemp)" || { umask "$old_umask"; _wm_refus MKTEMP "fichier d'en-tête"; return 1; }
  umask "$old_umask"
  chmod 600 "$WM_HDR"
  case "${APIM_AUTH_MODE:-}" in
    basic)
      [ -n "${WM_USER:-}" ] && [ -n "${WM_PASSWORD:-}" ] \
        || { _wm_refus WM_CREDENTIAL_REQUIS "WM_USER et WM_PASSWORD sont requis en mode basic"; return 1; }
      printf 'Authorization: Basic %s\n' \
        "$(printf '%s:%s' "$WM_USER" "$WM_PASSWORD" | base64 | tr -d '\n')" > "$WM_HDR" ;;
    oauth2)
      [ -n "${WM_BEARER:-}" ] \
        || { _wm_refus WM_JETON_REQUIS "WM_BEARER est requis en mode oauth2 (client_credentials déjà échangé)"; return 1; }
      printf 'Authorization: Bearer %s\n' "$WM_BEARER" > "$WM_HDR" ;;
    *) _wm_refus WM_AUTH_MODE_INCONNU "'${APIM_AUTH_MODE:-}' — attendu basic ou oauth2"; return 1 ;;
  esac
  export WM_HDR
}
wm_admin_cleanup(){ [ -n "${WM_HDR:-}" ] && rm -f "$WM_HDR"; }

wm_get(){
  local path="$1" out="$2" ca=()
  [ -n "${VAULT_CACERT:-${LABCTL_CA_FILE:-}}" ] && ca=(--cacert "${VAULT_CACERT:-$LABCTL_CA_FILE}")
  curl -s -m "${WM_TIMEOUT:-30}" -o "$out" -w '%{http_code}' \
    -H @"$WM_HDR" "${ca[@]}" "${APIM_BASE}${path}"
}

wm_preflight(){
  local lc; lc="$(printf '%s' "${APIM_PREFLIGHT:-on}" | tr '[:upper:]' '[:lower:]')"
  WM_PREFLIGHT_URL="${APIM_PREFLIGHT_URL:-${APIM_BASE}/apis}"; export WM_PREFLIGHT_URL
  [ "$lc" = off ] && { echo "  (préflight désactivé — APIM_PREFLIGHT=off)" >&2; return 0; }
  local codes="${APIM_PREFLIGHT_CODES:-200 401}" c
  # SANS jeton, délibérément : le 401 est la preuve de vie du proxy.
  c="$(curl -s -o /dev/null -m "${WM_TIMEOUT:-30}" -w '%{http_code}' "$WM_PREFLIGHT_URL" || echo 000)"
  case " $codes " in *" $c "*) return 0 ;; esac
  _wm_refus GATEWAY_INJOIGNABLE "sonde ${WM_PREFLIGHT_URL} -> HTTP ${c} (attendus : ${codes})"
}

# wm_diag_401 <fichier de corps> — un 401 a DEUX causes, et les confondre fait
# relancer un login en boucle jusqu'à verrouiller le compte d'annuaire.
wm_diag_401(){
  if grep -qi 'administrator group\|not a member' "$1" 2>/dev/null; then
    echo "WM_401_AUTORISATION : le couple est bon, mais le compte n'appartient à aucun groupe d'administration. Demander à l'ops l'ajout des droits de LECTURE sur l'API d'administration (GET /apis, GET /applications) — ne PAS relancer avec un autre mot de passe." >&2
  else
    echo "WM_401_AUTHENTIFICATION : identifiant refusé. Vérifier WM_USER/WM_PASSWORD (mode basic) ou le jeton (mode oauth2) AVANT de réessayer — un compte d'annuaire se verrouille." >&2
  fi
}
```

- [ ] **Step 4 : lancer, vérifier le vert**

```bash
cd poc-control-plane-federation && bash scripts/test-scan-parc.sh && shellcheck scripts/lib/wm-admin-curl.sh
```
Attendu : `6 ✅  0 ❌`, `shellcheck` muet.

- [ ] **Step 5 : prouver par MUTATION**

```bash
cd poc-control-plane-federation
# M1 : remettre le secret en argv (curl -u)
sed -i.bak 's|-H @"$WM_HDR"|-u "$WM_USER:$WM_PASSWORD"|' scripts/lib/wm-admin-curl.sh
bash scripts/test-scan-parc.sh ; echo "attendu: 1a ❌"
mv scripts/lib/wm-admin-curl.sh.bak scripts/lib/wm-admin-curl.sh
# M2 : viser /health par défaut
sed -i.bak 's|${APIM_BASE}/apis}|${APIM_BASE}/health}|' scripts/lib/wm-admin-curl.sh
bash scripts/test-scan-parc.sh ; echo "attendu: 1c et 1d ❌"
mv scripts/lib/wm-admin-curl.sh.bak scripts/lib/wm-admin-curl.sh
# M3 : retirer la distinction des deux 401
```
Attendu : chaque mutation rougit l'assertion visée ; la restauration ramène `6 ✅  0 ❌`.

- [ ] **Step 6 : commit**

```bash
git add poc-control-plane-federation/scripts/lib/wm-admin-curl.sh poc-control-plane-federation/scripts/test-scan-parc.sh
git commit -m "feat(wm-admin-curl): appel admin sans secret en argv, preflight knobe hors /health"
```

---

### Task 4 : `scripts/lib/estate.sh` — normaliser, grouper par lignée, verdicter

**Files:**
- Create: `poc-control-plane-federation/scripts/lib/estate.sh`
- Modify: `poc-control-plane-federation/scripts/test-scan-parc.sh` (section 2 ajoutée)

**Interfaces:**
- Consumes: rien (pur : il transforme du JSON).
- Produces: `estate_from_apis <fichier GET /apis> <fichier de sortie JSON>` — écrit `{"lignees":[…]}` trié, chaque lignée portant `nom`, `equipe` (ou `null`), `verdict`, `versions[]`. Les verdicts possibles : `OK`, `API_NON_APPROPRIEE`, `LIGNEE_PARTIELLEMENT_ETRANGERE`, `API_MULTI_EQUIPES`, `NOM_HORS_REGEXP`, `VERSION_HORS_REGEXP`, `CONTRAT_NON_EXTRACTIBLE_API_INACTIVE`.

- [ ] **Step 1 : écrire les épreuves qui échouent**

Ajouter à `scripts/test-scan-parc.sh`, après la section 1 :

```bash
echo "== 2. estate.sh : normalisation, lignée, verdicts =="
LIBE="$REPO/scripts/lib/estate.sh"
curl -s -H "Authorization: Basic ok" "$BASE/apis" > "$TMP/apis.json"
bash -c '. "'"$LIBE"'" && estate_from_apis "'"$TMP"'/apis.json" "'"$TMP"'/lignees.json"' 2>"$TMP/e.err"
verdict(){ python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for l in d["lignees"]:
    if l["nom"]==sys.argv[2]: print(l["verdict"]); break
else: print("ABSENTE")' "$TMP/lignees.json" "$1"; }

[ "$(verdict paiements)" = "LIGNEE_PARTIELLEMENT_ETRANGERE" ] \
  && ok "lignée mixte (v1.0.1 en Default) ⇒ LIGNEE_PARTIELLEMENT_ETRANGERE, pas OK sur v1.0.0" \
  || ko "paiements : verdict '$(verdict paiements)'"
[ "$(verdict virements)" = "API_MULTI_EQUIPES" ] \
  && ok "deux équipes RÉELLES ⇒ API_MULTI_EQUIPES (l'outil refuse de trancher)" \
  || ko "virements : verdict '$(verdict virements)'"
[ "$(verdict legacy_API)" = "NOM_HORS_REGEXP" ] \
  && ok "nom hors ^[a-z0-9][a-z0-9-]{1,30}$ ⇒ NOM_HORS_REGEXP" || ko "legacy_API : '$(verdict legacy_API)'"
[ "$(verdict offline-api)" = "CONTRAT_NON_EXTRACTIBLE_API_INACTIVE" ] \
  && ok "isActive false ⇒ CONTRAT_NON_EXTRACTIBLE_API_INACTIVE" || ko "offline-api : '$(verdict offline-api)'"
[ "$(verdict orpheline)" = "API_NON_APPROPRIEE" ] \
  && ok "teams ⊆ profils système ⇒ API_NON_APPROPRIEE" || ko "orpheline : '$(verdict orpheline)'"

# les teams se lisent au niveau de l'ENTRÉE, jamais dans api (api.teams est null en 10.15)
python3 - "$TMP/apis.json" <<'PY' > "$TMP/nullteams.json"
import json,sys
d=json.load(open(sys.argv[1]))
for r in d["apiResponse"]: r["api"]["teams"]=None
json.dump(d,open(sys.stdout.fileno(),"w"))
PY
bash -c '. "'"$LIBE"'" && estate_from_apis "'"$TMP"'/nullteams.json" "'"$TMP"'/l2.json"' 2>/dev/null
python3 -c '
import json,sys
a=json.load(open(sys.argv[1]))["lignees"]; b=json.load(open(sys.argv[2]))["lignees"]
sys.exit(0 if a==b else 1)' "$TMP/lignees.json" "$TMP/l2.json" \
  && ok "api.teams=null ne change RIEN : les teams sont lues au niveau de l'entrée apiResponse" \
  || ko "la lib lit api.teams — elle sera aveugle sur la 10.15 réelle"

# déterminisme : deux rendus identiques octet pour octet
bash -c '. "'"$LIBE"'" && estate_from_apis "'"$TMP"'/apis.json" "'"$TMP"'/l3.json"' 2>/dev/null
cmp -s "$TMP/lignees.json" "$TMP/l3.json" \
  && ok "rendu DÉTERMINISTE (cmp -s) — diff devient l'outil de suivi du parc" \
  || ko "deux rendus du même parc diffèrent"
```

- [ ] **Step 2 : lancer, vérifier l'échec**

```bash
cd poc-control-plane-federation && bash scripts/test-scan-parc.sh
```
Attendu : les 7 assertions de la section 2 sont ❌.

- [ ] **Step 3 : écrire la lib**

Créer `scripts/lib/estate.sh`. Le cœur est un heredoc python3 — le conteneur Jenkins n'a pas `jq`, et le dépôt fait déjà ainsi partout :

```bash
#!/usr/bin/env bash
# scripts/lib/estate.sh — de GET /apis à des LIGNÉES verdictées.
#
# LA LIGNÉE EST L'UNITÉ, PAS LA VERSION. La garde de publication est ∀ sur la
# lignée du nom (apim_publish_api/tasks/version.yml:272-280) : une lignée dont
# UNE version reste en Default est INPUBLIABLE EN BLOC. Grouper par version
# produirait des verdicts localement vrais et globalement faux.
#
# LES TEAMS SE LISENT AU NIVEAU DE L'ENTRÉE apiResponse, jamais dans `api` :
# `apiResponse.api.teams` est NULL sur la 10.15 réelle (mesuré 2026-08-05,
# mocks/webmethods/store.go:42-48).
estate_from_apis(){
  local src="$1" out="$2"
  python3 - "$src" "$out" <<'PY'
import json, re, sys
SYSTEME = {"Administrators", "Default", "API-Gateway-Providers"}
RE_NOM = re.compile(r"^[a-z0-9][a-z0-9-]{1,30}$")
RE_VER = re.compile(r"^[0-9]+\.[0-9]+(\.[0-9]+)?$")

d = json.load(open(sys.argv[1])) or {}
lignees = {}
for r in (d.get("apiResponse") or []):
    api = r.get("api") or {}
    # frère de `api`, jamais dedans — repli sur api.teams seulement s'il est non-null
    teams = r.get("teams") or api.get("teams") or []
    noms = sorted({(t.get("name") or "") for t in teams if t.get("name")})
    reelles = sorted(set(noms) - SYSTEME)
    e = lignees.setdefault(api.get("apiName") or "", {"versions": [], "equipes": set()})
    e["versions"].append({
        "version": api.get("apiVersion") or "",
        "guid": api.get("id") or "",
        # booléen JSON STRICT : absent, null, "true" (chaîne) ou 1 sont INACTIFS
        "isActive": api.get("isActive") is True,
        "teams": noms,
        "_reelles": reelles,
    })
    e["equipes"].update(reelles)

sortie = []
for nom in sorted(lignees):
    e = lignees[nom]
    versions = sorted(e["versions"], key=lambda v: v["version"])
    equipes = sorted(e["equipes"])
    # L'ORDRE DES VERDICTS EST L'ORDRE DE GRAVITÉ : le premier qui matche gagne.
    if not equipes:
        verdict, equipe = "API_NON_APPROPRIEE", None
    elif len(equipes) > 1:
        verdict, equipe = "API_MULTI_EQUIPES", None
    elif not RE_NOM.match(nom):
        verdict, equipe = "NOM_HORS_REGEXP", equipes[0]
    elif any(not RE_VER.match(v["version"]) for v in versions):
        verdict, equipe = "VERSION_HORS_REGEXP", equipes[0]
    elif any(equipes[0] not in v["_reelles"] for v in versions):
        verdict, equipe = "LIGNEE_PARTIELLEMENT_ETRANGERE", equipes[0]
    elif not all(v["isActive"] for v in versions):
        verdict, equipe = "CONTRAT_NON_EXTRACTIBLE_API_INACTIVE", equipes[0]
    else:
        verdict, equipe = "OK", equipes[0]
    for v in versions:
        v.pop("_reelles", None)
    sortie.append({"nom": nom, "equipe": equipe, "verdict": verdict, "versions": versions})

json.dump({"lignees": sortie}, open(sys.argv[2], "w"),
          ensure_ascii=False, indent=2, sort_keys=True)
PY
}
```

- [ ] **Step 4 : lancer, vérifier le vert**

```bash
cd poc-control-plane-federation && bash scripts/test-scan-parc.sh && shellcheck scripts/lib/estate.sh
```
Attendu : `13 ✅  0 ❌`.

- [ ] **Step 5 : prouver par MUTATION**

```bash
cd poc-control-plane-federation
# M1 : lire api.teams en priorité (le bug de la 10.15)
sed -i.bak 's|r.get("teams") or api.get("teams") or \[\]|api.get("teams") or r.get("teams") or []|' scripts/lib/estate.sh
bash scripts/test-scan-parc.sh ; echo "attendu: l'assertion api.teams=null ❌"
mv scripts/lib/estate.sh.bak scripts/lib/estate.sh
# M2 : grouper par version au lieu de par lignée (retirer le test LIGNEE_PARTIELLEMENT_ETRANGERE)
# M3 : accepter isActive == "true" (chaîne)
sed -i.bak 's|api.get("isActive") is True|bool(api.get("isActive"))|' scripts/lib/estate.sh
bash scripts/test-scan-parc.sh ; echo "attendu: offline-api ❌ si le faux wM rend \"true\""
mv scripts/lib/estate.sh.bak scripts/lib/estate.sh
```

- [ ] **Step 6 : commit**

```bash
git add poc-control-plane-federation/scripts/lib/estate.sh poc-control-plane-federation/scripts/test-scan-parc.sh
git commit -m "feat(estate): grouper par lignee et verdicter les six situations de parc"
```

---

### Task 5 : `scripts/scan-parc.sh` — la garde de troncature et le contre-compte

**Files:**
- Create: `poc-control-plane-federation/scripts/scan-parc.sh`
- Modify: `poc-control-plane-federation/scripts/test-scan-parc.sh` (section 3)

**Interfaces:**
- Consumes: `apim_base_resolve` (T1), `wm_admin_init`/`wm_get`/`wm_preflight`/`wm_diag_401` (T3), `estate_from_apis` (T4).
- Produces: l'exécutable. Entrées : `SCAN_OUT` (répertoire de sortie, requis), `SCAN_PARC_ATTENDU` (requis au premier passage — `<apis>:<applications>`), plus les knobs de T1/T3. Sortie : `$SCAN_OUT/estate.<env>.json`.

- [ ] **Step 1 : écrire les épreuves qui échouent**

Ajouter à `scripts/test-scan-parc.sh` :

```bash
echo "== 3. garde de troncature : SCAN_PARC_ATTENDU =="
SCAN="$REPO/scripts/scan-parc.sh"
scan(){ env ENVIRONMENT=dev ADMIN_VIA=direct APIM_TERMINUS=prod APIM_API_BASE="$BASE" \
  APIM_AUTH_MODE=basic WM_USER=adm WM_PASSWORD=s3cr3t SCAN_OUT="$TMP/out" "$@" bash "$SCAN"; }

rm -rf "$TMP/out"; mkdir -p "$TMP/out"
scan >"$TMP/s1.out" 2>"$TMP/s1.err"
grep -q '^REFUS: SCAN_PARC_ATTENDU_REQUIS' "$TMP/s1.err" \
  && ok "SCAN_PARC_ATTENDU absent ⇒ refus nommé (aucun défaut deviné)" \
  || ko "le scan a tourné sans contre-compte : $(tail -2 "$TMP/s1.err")"
[ ! -f "$TMP/out/estate.dev.json" ] && ok "aucun inventaire écrit sur le chemin de refus" \
  || ko "un estate.dev.json a été écrit malgré le refus"

scan SCAN_PARC_ATTENDU=99:1 >"$TMP/s2.out" 2>"$TMP/s2.err"
grep -q '^REFUS: PARC_POSSIBLEMENT_TRONQUE' "$TMP/s2.err" \
  && ok "contre-compte faux (99 attendues, 6 rendues) ⇒ PARC_POSSIBLEMENT_TRONQUE" \
  || ko "compte divergent accepté : $(tail -2 "$TMP/s2.err")"

scan SCAN_PARC_ATTENDU=6:1 >"$TMP/s3.out" 2>"$TMP/s3.err"
[ -f "$TMP/out/estate.dev.json" ] \
  && ok "contre-compte juste ⇒ l'inventaire est écrit" || ko "rien écrit : $(tail -3 "$TMP/s3.err")"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get("schema")==1 and d["provenance"]["env"]=="dev" else 1)' "$TMP/out/estate.dev.json" \
  && ok "estate.dev.json porte schema:1 et sa provenance" || ko "en-tête d'inventaire incorrect"
grep -q 'SECRET-QUI-NE-DOIT-PAS-FUIR' "$TMP/out/estate.dev.json" \
  && ko "FUITE : la valeur d'un identifiant d'application est dans l'inventaire" \
  || ok "aucune valeur d'identifiant dans l'inventaire (NON_TRANSPORTEE)"
```

- [ ] **Step 2 : lancer, vérifier l'échec**

```bash
cd poc-control-plane-federation && bash scripts/test-scan-parc.sh
```
Attendu : les 6 assertions de la section 3 sont ❌.

- [ ] **Step 3 : écrire l'exécutable**

Créer `scripts/scan-parc.sh` (exécutable, `chmod +x`) :

```bash
#!/usr/bin/env bash
# scan-parc.sh — INVENTAIRE, EN LECTURE SEULE, d'un parc webMethods 10.15.
# N'écrit RIEN sur la gateway, rien sur la forge. Produit $SCAN_OUT/estate.<env>.json.
#
# LA GARDE DE TRONCATURE. Rien ne prouve que GET /apis rende le parc complet :
# aucun appelant du dépôt ne pagine, et toutes les mesures live portent sur
# ~10 APIs. Sur une instance de banque, un fournisseur entier peut manquer EN
# SILENCE — et un group-by sur une liste tronquée ment sans rien signaler.
# D'où SCAN_PARC_ATTENDU, EXIGÉ, sans défaut.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
refus(){ echo "REFUS: $*" >&2; exit 1; }

. "$REPO/scripts/lib/apim-base.sh"     || refus "LIB_ABSENTE : scripts/lib/apim-base.sh"
. "$REPO/scripts/lib/wm-admin-curl.sh" || refus "LIB_ABSENTE : scripts/lib/wm-admin-curl.sh"
. "$REPO/scripts/lib/estate.sh"        || refus "LIB_ABSENTE : scripts/lib/estate.sh"

SCAN_OUT="${SCAN_OUT:?SCAN_OUT requis (répertoire de sortie)}"
[ -n "${SCAN_PARC_ATTENDU:-}" ] || refus "SCAN_PARC_ATTENDU_REQUIS : poser SCAN_PARC_ATTENDU=<apis>:<applications>, relevé EN CONSOLE par l'ops. Sans contre-compte, une liste tronquée passerait pour un parc complet."
case "$SCAN_PARC_ATTENDU" in
  [0-9]*:[0-9]*) ;; *) refus "SCAN_PARC_ATTENDU_INVALIDE : '${SCAN_PARC_ATTENDU}' — attendu <entier>:<entier>";;
esac
ATT_APIS="${SCAN_PARC_ATTENDU%%:*}"; ATT_APPS="${SCAN_PARC_ATTENDU##*:}"

apim_base_resolve || exit 1
wm_preflight      || exit 1
wm_admin_init     || exit 1
WORK="$(mktemp -d)"; trap 'wm_admin_cleanup; rm -rf "$WORK"' EXIT

C="$(wm_get /apis "$WORK/apis.json")"
[ "$C" = 200 ] || { [ "$C" = 401 ] && wm_diag_401 "$WORK/apis.json"; refus "GET_APIS : HTTP ${C}"; }
N_APIS="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("apiResponse") or []))' "$WORK/apis.json")"
[ "$N_APIS" = "$ATT_APIS" ] || refus "PARC_POSSIBLEMENT_TRONQUE : ${N_APIS} API(s) rendue(s), ${ATT_APIS} attendue(s). Un inventaire partiel qui a l'air complet est le pire produit possible : vérifier le compte en console, ou la pagination de la gateway."

C="$(wm_get /applications "$WORK/apps.json")"
[ "$C" = 200 ] || refus "GET_APPLICATIONS : HTTP ${C}"
N_APPS="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("applications") or []))' "$WORK/apps.json")"
[ "$N_APPS" = "$ATT_APPS" ] || refus "PARC_POSSIBLEMENT_TRONQUE : ${N_APPS} application(s) rendue(s), ${ATT_APPS} attendue(s)."

estate_from_apis "$WORK/apis.json" "$WORK/lignees.json" || refus "ESTATE_RENDU : lecture de GET /apis"

mkdir -p "$SCAN_OUT"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BASE_RED="$(printf '%s' "$APIM_BASE" | sed -E 's#://[^[:space:]]*@#://<identifiants masqués>@#g')"
python3 - "$WORK/lignees.json" "$SCAN_OUT/estate.${ENVIRONMENT}.json" <<PY || refus "ECRITURE : ${SCAN_OUT}/estate.${ENVIRONMENT}.json"
import json, sys
lig = json.load(open(sys.argv[1]))
doc = {
  "schema": 1,
  "provenance": {"base": "${BASE_RED}", "env": "${ENVIRONMENT}",
                 "via": "${APIM_EFFECTIVE_VIA}", "scanned_at": "${STAMP}",
                 "sondes": {"preflight": "OK", "apis": 200, "applications": 200,
                            "archive_zip": "NON_MESURE"}},
  "comptes": {"apis": ${N_APIS}, "applications": ${N_APPS},
              "lignees": len(lig["lignees"]), "troncature": "OK"},
  "lignees": lig["lignees"],
  "applications": [],
  "refus": [ {"objet": l["nom"], "code": l["verdict"]}
             for l in lig["lignees"] if l["verdict"] != "OK" ],
}
json.dump(doc, open(sys.argv[2], "w"), ensure_ascii=False, indent=2, sort_keys=True)
PY
echo "inventaire écrit : ${SCAN_OUT}/estate.${ENVIRONMENT}.json (${N_APIS} API(s), ${N_APPS} application(s))"
```

- [ ] **Step 4 : lancer, vérifier le vert**

```bash
cd poc-control-plane-federation && chmod +x scripts/scan-parc.sh && bash scripts/test-scan-parc.sh && shellcheck scripts/scan-parc.sh
```
Attendu : `19 ✅  0 ❌`.

- [ ] **Step 5 : prouver par MUTATION**

```bash
cd poc-control-plane-federation
# M1 : donner un défaut à SCAN_PARC_ATTENDU
sed -i.bak 's|\[ -n "${SCAN_PARC_ATTENDU:-}" \] |[ -n "${SCAN_PARC_ATTENDU:-6:1}" ] |' scripts/scan-parc.sh
bash scripts/test-scan-parc.sh ; echo "attendu: SCAN_PARC_ATTENDU_REQUIS ❌"
mv scripts/scan-parc.sh.bak scripts/scan-parc.sh
# M2 : accepter un compte divergent (retirer le test d'égalité) ⇒ PARC_POSSIBLEMENT_TRONQUE ❌
# M3 : écrire l'inventaire AVANT les gardes ⇒ « aucun inventaire sur le chemin de refus » ❌
```

- [ ] **Step 6 : commit**

```bash
git add poc-control-plane-federation/scripts/scan-parc.sh poc-control-plane-federation/scripts/test-scan-parc.sh
git commit -m "feat(scan-parc): inventaire fail-closed avec contre-compte obligatoire"
```

---

### Task 6 : applications, contrats et rapport — compléter l'inventaire

**Files:**
- Modify: `poc-control-plane-federation/scripts/scan-parc.sh`
- Modify: `poc-control-plane-federation/scripts/lib/estate.sh` (ajout de `estate_applications`)
- Modify: `poc-control-plane-federation/scripts/test-scan-parc.sh` (section 4)

**Interfaces:**
- Consumes: tout ce qui précède.
- Produces: `estate_applications <fichier liste> <répertoire de détails> <sortie>` — rend le tableau `applications` de l'inventaire, **sans aucune valeur d'identifiant**. `scan-parc.sh` produit en plus `$SCAN_OUT/contrats/<nom>-<version>.openapi.yaml` et `$SCAN_OUT/rapport.md`.

- [ ] **Step 1 : écrire les épreuves qui échouent**

```bash
echo "== 4. applications, contrats, rapport =="
rm -rf "$TMP/out"; scan SCAN_PARC_ATTENDU=6:1 >/dev/null 2>&1
python3 -c '
import json,sys
a=json.load(open(sys.argv[1]))["applications"][0]
ids={i["type"]: i for i in a["identifiants"]}
assert a["ownerType"]=="team" and a["owner"]=="toto", a
assert ids["apiKey"]["valeur"]=="NON_TRANSPORTEE", ids
assert ids["ip"]["valeurs"]==["10.0.0.0/8"], ids
' "$TMP/out/estate.dev.json" \
  && ok "application : owner/ownerType lus, clé NON_TRANSPORTEE, IP conservée (ce n'est pas un secret)" \
  || ko "forme de l'application incorrecte"

[ -f "$TMP/out/contrats/paiements-1.0.0.openapi.yaml" ] \
  && ok "contrat extrait d'apiDefinition pour une lignée OK" || ko "contrat manquant"
[ ! -f "$TMP/out/contrats/offline-api-1.0.0.openapi.yaml" ] \
  && ok "aucun contrat pour une API INACTIVE (verdict non-OK ⇒ rien n'est produit)" \
  || ko "un contrat a été extrait pour une API inactive"
python3 -c '
import hashlib,json,sys
d=json.load(open(sys.argv[1]))
for l in d["lignees"]:
    if l["nom"]!="paiements": continue
    for v in l["versions"]:
        c=v.get("contrat")
        if c: 
            h=hashlib.sha256(open(sys.argv[2]+"/"+c["fichier"].split("/")[-1],"rb").read()).hexdigest()
            assert h==c["sha256"], (h,c)
' "$TMP/out/estate.dev.json" "$TMP/out/contrats" 2>/dev/null \
  && ok "sha256 du contrat vérifiable depuis l'inventaire" || ko "sha256 absent ou faux"

grep -q 'API_MULTI_EQUIPES' "$TMP/out/rapport.md" && grep -q 'assign-api-team.sh' "$TMP/out/rapport.md" \
  && ok "rapport.md nomme les refus ET le geste proposé" || ko "rapport.md incomplet"
```

- [ ] **Step 2 : lancer, vérifier l'échec** — `bash scripts/test-scan-parc.sh`, les 5 assertions de la section 4 sont ❌.

- [ ] **Step 3 : implémenter**

Dans `scripts/lib/estate.sh`, ajouter :

```bash
# estate_applications <liste JSON> <répertoire des détails> <sortie JSON>
#
# AUCUNE VALEUR D'IDENTIFIANT NE TRAVERSE. La 10.15 masque l'apiAccessKey à
# tout lecteur qui n'est pas l'owner (32 astérisques) — écrire ce masque serait
# un vert menteur. Et une clé d'API n'a de toute façon rien à faire dans Git :
# le manifeste porte le CHEMIN Vault, jamais la valeur.
# L'IP, elle, n'est pas un secret : elle est conservée.
estate_applications(){
  python3 - "$1" "$2" "$3" <<'PY'
import json, os, sys
SANS_VALEUR = {"apiKey", "oauth2Token", "jwt", "certificate", "sslCertificate"}
liste = json.load(open(sys.argv[1])) or {}
out = []
for a in (liste.get("applications") or []):
    det_p = os.path.join(sys.argv[2], a["id"] + ".json")
    det = (json.load(open(det_p)).get("applications") or [{}])[0] if os.path.exists(det_p) else a
    ownert = det.get("ownerType") or ""
    ids = []
    for i in (det.get("identifiers") or []):
        k = i.get("key") or ""
        if k in SANS_VALEUR:
            ids.append({"type": k, "valeur":
                        "CLE_MASQUEE_PROPRIETAIRE_UTILISATEUR" if ownert == "user" else "NON_TRANSPORTEE"})
        else:
            v = i.get("value")
            ids.append({"type": k, "valeurs": v if isinstance(v, list) else [v]})
    out.append({
        "nom": det.get("name") or a.get("name") or "", "id": det.get("id") or a.get("id") or "",
        "ownerType": ownert, "owner": det.get("owner") or "",
        "souscriptions": sorted(det.get("consumingAPIs") or []),
        "identifiants": sorted(ids, key=lambda x: x["type"]),
        "verdict": "APP_PROPRIETE_INDIVIDUELLE" if ownert == "user" else "OK",
    })
json.dump({"applications": sorted(out, key=lambda x: x["nom"])},
          open(sys.argv[3], "w"), ensure_ascii=False, indent=2, sort_keys=True)
PY
}
```

Dans `scripts/scan-parc.sh`, après le contre-compte des applications et avant l'écriture :

```bash
# détail par application : GET /applications/{id}. La liste ne porte pas
# teams/owner/identifiers sur la 10.15 réelle (vrai du mock seulement) — N+1 assumé.
mkdir -p "$WORK/appdet"
for AID in $(python3 -c 'import json,sys; [print(a["id"]) for a in (json.load(open(sys.argv[1])).get("applications") or [])]' "$WORK/apps.json"); do
  C="$(wm_get "/applications/${AID}" "$WORK/appdet/${AID}.json")"
  [ "$C" = 200 ] || refus "GET_APPLICATION : ${AID} -> HTTP ${C}"
done
estate_applications "$WORK/apps.json" "$WORK/appdet" "$WORK/apps-rendu.json" || refus "ESTATE_APPLICATIONS"

# contrats : apiDefinition de GET /apis/{id}, pour les LIGNÉES OK SEULEMENT.
mkdir -p "$SCAN_OUT/contrats"
python3 -c 'import json,sys
for l in json.load(open(sys.argv[1]))["lignees"]:
    if l["verdict"]=="OK":
        for v in l["versions"]: print(l["nom"], v["version"], v["guid"])' "$WORK/lignees.json" \
| while read -r NOM VER GUID; do
    C="$(wm_get "/apis/${GUID}" "$WORK/api-${GUID}.json")"
    [ "$C" = 200 ] || refus "GET_API : ${NOM}@${VER} -> HTTP ${C}"
    python3 -c 'import json,sys,yaml
d=json.load(open(sys.argv[1]))["apiResponse"]["api"].get("apiDefinition")
if not d: sys.exit("apiDefinition absente")
yaml.safe_dump(d, open(sys.argv[2],"w"), sort_keys=True, allow_unicode=True)' \
      "$WORK/api-${GUID}.json" "$SCAN_OUT/contrats/${NOM}-${VER}.openapi.yaml" \
      || refus "CONTRAT_ABSENT : ${NOM}@${VER} — apiDefinition vide sur GET /apis/{id}"
  done
```

Puis, dans le heredoc python d'écriture, remplacer `"applications": []` par la lecture de `$WORK/apps-rendu.json`, ajouter le bloc `contrat` (chemin + `sha256`) à chaque version de lignée OK, et écrire `$SCAN_OUT/rapport.md` — une section par refus, avec le geste :

```
| verdict | geste proposé |
| API_NON_APPROPRIEE | GW=… GW_PASS=… ./scripts/assign-api-team.sh --team <équipe> <api> |
| LIGNEE_PARTIELLEMENT_ETRANGERE | assigner les versions sœurs listées, puis rescanner |
| API_MULTI_EQUIPES | arbitrer l'appartenance, puis rescanner |
| NOM_HORS_REGEXP / VERSION_HORS_REGEXP | renommer = NOUVELLE publication, pas une migration |
| CONTRAT_NON_EXTRACTIBLE_API_INACTIVE | activer au palier, puis rescanner |
| APP_PROPRIETE_INDIVIDUELLE | POST /assets/owner avec l'UUID de l'accessProfile |
```

- [ ] **Step 4 : lancer, vérifier le vert** — `bash scripts/test-scan-parc.sh` ⇒ `24 ✅  0 ❌` ; `shellcheck scripts/scan-parc.sh scripts/lib/estate.sh` muet.

- [ ] **Step 5 : prouver par MUTATION**

```bash
cd poc-control-plane-federation
# M1 : laisser passer la valeur de la clé
sed -i.bak 's|if k in SANS_VALEUR:|if False:|' scripts/lib/estate.sh
bash scripts/test-scan-parc.sh ; echo "attendu: la FUITE de la section 3 ❌ ET la forme de la section 4 ❌"
mv scripts/lib/estate.sh.bak scripts/lib/estate.sh
# M2 : extraire un contrat pour toutes les lignées, OK ou non ⇒ « aucun contrat pour une API INACTIVE » ❌
# M3 : ne pas calculer le sha256 ⇒ l'assertion d'empreinte ❌
```

- [ ] **Step 6 : porte de dépôt et commit**

```bash
cd poc-control-plane-federation
make lint-ci 2>&1 | tail -25
git add poc-control-plane-federation/scripts/scan-parc.sh poc-control-plane-federation/scripts/lib/estate.sh poc-control-plane-federation/scripts/test-scan-parc.sh
git commit -m "feat(scan-parc): applications sans secret, contrats depuis apiDefinition, rapport des gestes"
```
Attendu : `make lint-ci` vert — notamment `lint-config-knobs` (aucun défaut de site) et `shellcheck`.

---

### Task 7 : gouvernance, `providers.<env>.yml` et sonde `/archive` — les trois verdicts manquants

**Files:**
- Modify: `poc-control-plane-federation/scripts/scan-parc.sh`
- Modify: `poc-control-plane-federation/scripts/lib/estate.sh`
- Modify: `poc-control-plane-federation/scripts/test-scan-parc.sh` (section 5)

**Interfaces:**
- Consumes: tout ce qui précède ; `GC_PLATFORM_DIR` (le dépôt plateforme déjà présent — knob existant, `generate-choices.sh:146-159`) ; `GOVERNANCE_PATH` (knob existant, **sans défaut**).
- Produces : `estate_gouvernance <registre> <lignees.json> <sortie>` — rejoue les verdicts en ajoutant `CLASSIFICATION_UNGOVERNED` ; `estate_repo_ambigu <providers.yml> <sortie>` — rend les couples équipe/dépôt en conflit. `scan-parc.sh` renseigne `provenance.sondes.archive_zip` par une mesure réelle.

**Pourquoi cette tâche existe** : l'auto-revue du plan a trouvé trois exigences de la spec (§5.4 n°6 et n°8, §5.5) sans aucune tâche. Sans elle, `scan` déclarerait `OK` des lignées que l'apply refusera.

- [ ] **Step 1 : écrire les épreuves qui échouent**

Ajouter à `scripts/test-scan-parc.sh` :

```bash
echo "== 5. gouvernance, providers, sonde archive =="
mkdir -p "$TMP/gov" "$TMP/plat/ansible"
cat > "$TMP/gov/registre.yaml" <<'YML'
apis:
  - owner: toto
    api: paiements
    classification: M
    exposure: internal
YML
# deux équipes déclarant le MÊME dépôt
cat > "$TMP/plat/ansible/providers.dev.yml" <<'YML'
providers:
  - team: toto
    repo: grp/apis-toto
  - team: titi
    repo: grp/apis-toto
YML
rm -rf "$TMP/out"
scan SCAN_PARC_ATTENDU=6:1 GC_PLATFORM_DIR="$TMP/plat" GIT_SUBDIR=. \
     GOVERNANCE_PATH="$TMP/gov/registre.yaml" >/dev/null 2>"$TMP/s5.err"

python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
codes={r["code"] for r in d["refus"]}
assert "CLASSIFICATION_UNGOVERNED" in codes, codes
assert "REPO_AMBIGU" in codes, codes
' "$TMP/out/estate.dev.json" \
  && ok "CLASSIFICATION_UNGOVERNED et REPO_AMBIGU sont inscrits aux refus" \
  || ko "verdicts manquants dans estate.dev.json"

[ ! -f "$TMP/out/contrats/virements-1.0.0.openapi.yaml" ] \
  && ok "une lignée non gouvernée ne produit PAS de contrat (verdict non-OK)" \
  || ko "un contrat a été produit pour une lignée hors registre"

python3 -c '
import json,sys
v=json.load(open(sys.argv[1]))["provenance"]["sondes"]["archive_zip"]
assert v in ("OK","KO"), v' "$TMP/out/estate.dev.json" \
  && ok "provenance.sondes.archive_zip porte une MESURE (OK|KO), pas NON_MESURE en dur" \
  || ko "archive_zip n'est pas mesuré"

rm -rf "$TMP/out"
scan SCAN_PARC_ATTENDU=6:1 GC_PLATFORM_DIR="$TMP/plat" GIT_SUBDIR=. >/dev/null 2>"$TMP/s6.err"
grep -q '^REFUS: GOUVERNANCE_REQUISE' "$TMP/s6.err" \
  && ok "GOVERNANCE_PATH absent ⇒ GOUVERNANCE_REQUISE (aucun défaut, aucun optimisme)" \
  || ko "le scan a tourné sans registre"
```

- [ ] **Step 2 : lancer, vérifier l'échec**

```bash
cd poc-control-plane-federation && bash scripts/test-scan-parc.sh
```
Attendu : les 4 assertions de la section 5 sont ❌.

- [ ] **Step 3 : implémenter les deux fonctions**

Dans `scripts/lib/estate.sh` :

```bash
# estate_gouvernance <registre yaml> <lignees.json> <sortie json>
#
# LA POSTURE EST CENTRALE ET OWNER-KEYÉE (ADR-076/092). Le scan ne la DÉCLARE
# jamais — il constate seulement si la ligne (owner, api) existe au registre.
# Une lignée absente est refusée à l'apply (CLASSIFICATION_UNGOVERNED) : la
# rendre OK ici produirait un dépôt mort-né.
estate_gouvernance(){
  python3 - "$1" "$2" "$3" <<'GOUV'
import json, sys, yaml
reg = yaml.safe_load(open(sys.argv[1])) or {}
gouv = {(str(e.get("owner") or ""), str(e.get("api") or "")): e
        for e in (reg.get("apis") or [])}
d = json.load(open(sys.argv[2]))
for l in d["lignees"]:
    if l["verdict"] != "OK":
        continue                      # un verdict plus grave a déjà tranché
    e = gouv.get((l["equipe"] or "", l["nom"]))
    if e is None:
        l["verdict"] = "CLASSIFICATION_UNGOVERNED"
    else:
        l["classification"] = e.get("classification")
        l["exposure"] = e.get("exposure")
json.dump(d, open(sys.argv[3], "w"), ensure_ascii=False, indent=2, sort_keys=True)
GOUV
}

# estate_repo_ambigu <providers.<env>.yml> <sortie json>
#
# Même discipline que team-publish.sh:244 : deux équipes déclarant le MÊME
# dépôt est un conflit qui ne se tranche pas tout seul. On NOMME, on ne choisit pas.
estate_repo_ambigu(){
  python3 - "$1" "$2" <<'AMBI'
import json, sys, yaml, collections
d = yaml.safe_load(open(sys.argv[1])) or {}
par_repo = collections.defaultdict(list)
for p in (d.get("providers") or []):
    r = (p.get("repo") or "").strip()
    t = (p.get("team") or "").strip()
    if r and t:
        par_repo[r].append(t)
out = [{"objet": r, "code": "REPO_AMBIGU",
        "detail": "declare par " + ", ".join(sorted(set(ts))),
        "geste": "corriger providers.<env>.yml — aucune equipe ne peut etre choisie sans arbitraire"}
       for r, ts in sorted(par_repo.items()) if len(set(ts)) > 1]
json.dump({"refus": out}, open(sys.argv[2], "w"), ensure_ascii=False, indent=2, sort_keys=True)
AMBI
}
```

- [ ] **Step 4 : brancher dans `scan-parc.sh`**

À insérer **avant** l'extraction des contrats — l'ordre compte : une lignée devenue non-OK ne doit plus produire de contrat.

```bash
# ── gouvernance : le registre CENTRAL tranche, le scan ne déclare rien ───────
[ -n "${GOVERNANCE_PATH:-}" ] || refus "GOUVERNANCE_REQUISE : poser GOVERNANCE_PATH (le registre central de classification). Sans lui, le scan déclarerait OK des lignées que l'apply refuse CLASSIFICATION_UNGOVERNED."
[ -r "$GOVERNANCE_PATH" ] || refus "GOUVERNANCE_ILLISIBLE : ${GOVERNANCE_PATH}"
estate_gouvernance "$GOVERNANCE_PATH" "$WORK/lignees.json" "$WORK/lignees-gouv.json" \
  || refus "GOUVERNANCE_PARSE : ${GOVERNANCE_PATH} illisible"
mv "$WORK/lignees-gouv.json" "$WORK/lignees.json"

# ── providers.<env>.yml : un dépôt déclaré par deux équipes ──────────────────
# shellcheck source=scripts/lib/repo-layout.sh
. "$REPO/scripts/lib/repo-layout.sh" && repo_layout_init || refus "LIB_ABSENTE : repo-layout.sh"
[ -n "${GC_PLATFORM_DIR:-}" ] || refus "PLATEFORME_REQUISE : poser GC_PLATFORM_DIR (racine du depot plateforme deja present)"
PROV="${GC_PLATFORM_DIR}/${SUB_PFX}ansible/providers.${ENVIRONMENT}.yml"
[ -r "$PROV" ] || refus "PROVIDERS_MISSING : ${PROV} illisible"
estate_repo_ambigu "$PROV" "$WORK/ambigu.json" || refus "PROVIDERS_PARSE : ${PROV}"

# ── sonde /archive : MESURÉE une fois, jamais en dépendance ──────────────────
# Le contrat du proxy declare le GET mais type sa reponse application/json, et
# aucun export n'a jamais ete joue a travers le proxy. On mesure, on rapporte,
# on n'en depend pas. L'archive porte PassmanData/ et Alias/ : elle ne survit pas.
ARCHIVE_ZIP=KO
FIRST_GUID="$(python3 -c 'import json,sys
for l in json.load(open(sys.argv[1]))["lignees"]:
    if l["verdict"]=="OK" and l["versions"]: print(l["versions"][0]["guid"]); break' "$WORK/lignees.json")"
if [ -n "$FIRST_GUID" ]; then
  C="$(wm_get "/archive?apis=${FIRST_GUID}" "$WORK/probe.zip")"
  if [ "$C" = 200 ] && [ "$(head -c 4 "$WORK/probe.zip" | od -An -tx1 | tr -d ' \n')" = "504b0304" ]; then
    ARCHIVE_ZIP=OK
  fi
  rm -f "$WORK/probe.zip"
fi
```

Puis, dans le heredoc d'écriture de l'inventaire : remplacer `"archive_zip": "NON_MESURE"` par `"archive_zip": "${ARCHIVE_ZIP}"`, et concaténer le tableau de `$WORK/ambigu.json` au tableau `refus`.

- [ ] **Step 5 : lancer, vérifier le vert**

```bash
cd poc-control-plane-federation && bash scripts/test-scan-parc.sh && shellcheck scripts/scan-parc.sh scripts/lib/estate.sh
```
Attendu : `28 ✅  0 ❌`, `shellcheck` muet.

- [ ] **Step 6 : prouver par MUTATION**

```bash
cd poc-control-plane-federation
# M1 : donner un défaut optimiste à la gouvernance
sed -i.bak 's|\[ -n "${GOVERNANCE_PATH:-}" \]|[ -n "${GOVERNANCE_PATH:-/dev/null}" ]|' scripts/scan-parc.sh
bash scripts/test-scan-parc.sh ; echo "attendu: GOUVERNANCE_REQUISE ❌"
mv scripts/scan-parc.sh.bak scripts/scan-parc.sh
# M2 : ne plus tester l'octet magique (declarer OK sur un simple 200)
sed -i.bak 's|&& \[ "$(head -c 4 "$WORK/probe.zip"|\&\& [ "200" = "200" ] \&\& [ "x$(head -c 4 "$WORK/probe.zip"|' scripts/scan-parc.sh
bash scripts/test-scan-parc.sh ; echo "attendu: 5c ❌ (le faux wM rend du JSON, pas un zip)"
mv scripts/scan-parc.sh.bak scripts/scan-parc.sh
# M3 : ignorer les doublons de providers (retirer le filtre len(set(ts)) > 1)
sed -i.bak 's|if len(set(ts)) > 1|if True|' scripts/lib/estate.sh
bash scripts/test-scan-parc.sh ; echo "attendu: la suite reste verte — corriger la mutation en RETIRANT le filtre autrement"
mv scripts/lib/estate.sh.bak scripts/lib/estate.sh
```

Attendu : M1 et M2 rougissent l'assertion visée. M3 est une mutation **trop faible** (elle sur-refuse au lieu de sous-refuser) : la refaire en supprimant l'appel à `estate_repo_ambigu` dans `scan-parc.sh`, ce qui doit rougir la première assertion de la section 5.

- [ ] **Step 7 : porte de dépôt et commit**

```bash
cd poc-control-plane-federation
make lint-ci 2>&1 | tail -25
git add poc-control-plane-federation/scripts/scan-parc.sh poc-control-plane-federation/scripts/lib/estate.sh poc-control-plane-federation/scripts/test-scan-parc.sh
git commit -m "feat(scan-parc): gouvernance centrale, REPO_AMBIGU et sonde d archive mesuree"
```

---

## Ce que ce plan ne couvre pas

Les paliers 3 à 5 de la spec (`render`, `publish`, `init-depots-fournisseurs.sh`) feront l'objet d'un **plan 2**, écrit une fois `estate.<env>.json` confronté à un parc réel — c'est le format pivot, et un premier passage client le fera bouger. Les tâches de ce plan produisent déjà un livrable autonome : l'inventaire verdicté d'un parc, avec ses gestes.
