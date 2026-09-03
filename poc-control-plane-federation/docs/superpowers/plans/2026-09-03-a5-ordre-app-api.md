---
title: "Plan — A5, l'ordre app/API : refus fermé si l'API n'est pas au palier"
type: plan
status: "RÉDIGÉ 2026-09-03 — exécution inline (un seul écrivain), TDD : chaque suite vue rouge avant le code"
date: 2026-09-03
spec: docs/superpowers/specs/2026-09-03-a5-ordre-app-api-design.md
---

# A5 — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline, un seul écrivain — le mode de défaillance « narration prématurée » des sous-agents est mesuré et cher, mémoire g2-axe-qui-deploie). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** l'apply d'application refuse, **avant sa première écriture**, une API absente du palier, absente dans cette version, ambiguë ou inactive — quatre refus nommés, relayés avec leur phrase jusqu'à la PR ; verify relit l'API au palier et la souscription au GUID ; le prototype Python porte la même porte ; preuves hors ligne (stub + mock + mutations) et par builds réels.

**Architecture:** la porte remplace l'`assert` §1 du rôle `apim_selfservice_app` (la dernière lecture avant `POST /applications`) et appelle une lib de refus additive `apim_common/tasks/refus.yml` (tag → fichier, phrase → fichier, `fail`) ; `ci/Jenkinsfile.selfservice` passe deux chemins de fichiers de plus et relaie le détail (`APPLIED_REFUSAL_DETAIL`) ; `ci/Jenkinsfile.provision-apply` compose `REFUSAL_DETAIL` ; `scripts/provision-apply-comment.sh` ajoute le paragraphe de remède ; la garde A3 écrit aussi sa phrase (`REFUS_DETAIL_OUT`).

**Tech Stack:** Ansible core 2.18 (poste) / 2.19 (conteneur Jenkins), Jinja2, bash 3.2 (poste) / dash (agent), python3, curl, Go (mock `mocks/webmethods`), Jenkins 2.541 déclaratif from SCM, Gitea 1.22, wM 10.15 réelle (lab).

**Spec:** `docs/superpowers/specs/2026-09-03-a5-ordre-app-api-design.md`

## Global Constraints (copiées de la spec)

- Aucun `job.xml` porteur de logique, aucun job re-posé, aucune globale Jenkins, aucun XML touché ; le Jenkinsfile ROUTE, le rôle DÉCIDE.
- La porte est à la position de l'`assert` §1 actuel : après la sonde Teams et `team-name.yml`, avant `api-visibility.yml` et avant `POST /applications`. Sur un refus : **aucun** `POST`/`PUT`/`DELETE` n'atteint la gateway (journal du stub).
- Tags et ordre du verdict : `API_NOT_PROMOTED` (aucune entrée `apiName == api`) → `API_VERSION_MISMATCH` (nom présent, aucune `apiVersion == api_version`) → `API_AMBIGUE` (plus d'une entrée nom+version) → `API_INACTIVE` (l'entrée unique n'a pas `isActive` **booléen vrai** : absent, `null`, `"true"`, `1` sont inactifs) → sinon `API_AT_PALIER : '<api>' v<ver> active au palier '<env>' (id=<uuid>)`.
- Ligne de refus : `REFUS: <TAG> : <phrase>` (dans le `msg` du `fail`) ; tag classe `[A-Z][A-Z0-9_]{2,40}` ; phrase une ligne ≤ 300 caractères ; `apim_ss_refus_out` / `apim_ss_refus_detail_out` vides par défaut (apply manuel : aucun fichier).
- Fichiers du relais : `$WORKSPACE/.a3-refus` (tag) et `$WORKSPACE/.a3-refus-detail` (phrase) ; purgés aux DEUX purges absolues existantes ; `post{always}` : `env.APPLIED_REFUSAL_DETAIL` sous `[^\r\n]{1,300}` et seulement avec un tag ; `Jenkinsfile.provision-apply` : `vars.APPLIED_REFUSAL_DETAIL` sous la même classe ⇒ `REFUSAL_DETAIL = "aval <job #n> : <détail>"`, sinon la phrase actuelle inchangée.
- `provision-apply-comment.sh` : paragraphe « L'ordre app/API » pour l'ensemble EXPLICITE `{API_NOT_PROMOTED, API_VERSION_MISMATCH, API_INACTIVE, API_AMBIGUE}` (« rien n'a été écrit ») et une variante pour `{API_AT_PALIER_UNCONFIRMED, SUBSCRIPTION_UNCONFIRMED}` (« la convergence a eu lieu, la relecture ne confirme pas »).
- Verify : `API_AT_PALIER_CONFIRMED`/`API_AT_PALIER_UNCONFIRMED` (même prédicat), `SUBSCRIPTION_CONFIRMED`/`SUBSCRIPTION_UNCONFIRMED` (`v_api_id ∈ consumingAPIs` de la liste relue), les deux refus via `refus.yml`.
- Prototype `scripts/apply-selfservice-application.py` : `api_version` obligatoire (`REFUS: CABLAGE_INCOMPLET`), mêmes quatre tags, `sys.exit(1)` avant `GET /applications`.
- Suites voisines INCHANGÉES dans leurs assertions (totaux à re-mesurer AVANT de toucher) : `test-selfservice-palier-a3.sh` 174 (→ 177 par cas additifs), `test-provision-apply-a4.sh` 133, `test-provision-apply-wiring.sh` 142, `test-provision-apply-a2.sh` 148, `test-a0-wiring.sh` 176, `test-pr-comment.sh` 41, `make lint-ci` [13/13] → [14/14].
- Pièges bash 3.2 : pas de `mapfile`, pas de `declare -A`, tableaux vides `${A[@]+"${A[@]}"}`, toute sortie capturée dans un fichier AVANT `grep` (jamais `cmd | grep -q` sous pipefail), `case`/`grep -E` plutôt que `[[ =~ ]]`.
- Lab : identité alice (`deploy-banking-demo apply-dev apply-rec`), palier rec (`selfApproval`), `APPLY_ADMIN_VIA=direct`, gateway réelle, `demo-selfservice 1.0.0` active ; manifestes jetables SANS `team:` ; le rôle appliqué est celui de l'ARBRE PINNÉ au `MERGE_SHA` (pousser gitea main AVANT la suite live) ; keepalive ~20-25 min.

---

## Carte des fichiers

| Fichier | Rôle | Tâche |
|---|---|---|
| `ansible/roles/apim_common/tasks/refus.yml` (créer) | la lib de refus : tag → fichier, phrase → fichier, `fail` | T1 |
| `ansible/roles/apim_selfservice_app/tasks/main.yml` (modifier §1) | la porte A5 (marqueurs `# ── A5 porte : début/fin`) | T1 |
| `scripts/test-selfservice-api-gate-a5.sh` (créer) | suite hors ligne : A rôle vs stub (+ M1..M3), B verify vs mock Go, C câblage, D rapport, E prototype | T1, T2, T3, T4, T5 |
| `ansible/roles/apim_selfservice_app/tasks/verify.yml` (modifier) | `API_AT_PALIER_*`, `SUBSCRIPTION_*` | T2 |
| `ci/Jenkinsfile.selfservice` (modifier) | `-e apim_ss_refus_*` ×2, `REFUS_DETAIL_OUT`, purges, `post{always}` détail, commentaire | T3 |
| `scripts/selfservice-palier-gate.sh` (modifier, 3 lignes) | `REFUS_DETAIL_OUT` | T3 |
| `ci/Jenkinsfile.provision-apply` (modifier) | `APPLIED_REFUSAL_DETAIL` → `REFUSAL_DETAIL` | T3 |
| `scripts/test-selfservice-palier-a3.sh` (modifier, additif A.38-A.40) | `REFUS_DETAIL_OUT` | T3 |
| `scripts/provision-apply-comment.sh` (modifier) | paragraphe « L'ordre app/API » | T4 |
| `scripts/apply-selfservice-application.py` (modifier) | porte A5 du prototype | T5 |
| `scripts/spike-cd-applications.py` (modifier S2-T3) | attendu réaligné (le moteur refuse) | T5 |
| `Makefile` (modifier) | `[14/14]`, shellcheck des deux nouveaux scripts | T6 |
| `scripts/test-a5-live.sh` (créer) | preuve par builds réels (D6) | T7 |
| `adr/adr-088-ordre-app-api.md` (créer), `ENVIRONNEMENTS.md`, `GOAL-cd-applications-2026-09-02.md`, spec/plan (statuts), mémoire | docs | T8 |

---

## T0 — Mesurer les totaux AVANT de toucher (aucun code)

- [ ] **Step 1 : totaux des suites voisines**

```bash
cd poc-control-plane-federation
for s in test-selfservice-palier-a3 test-provision-apply-a4 test-provision-apply-wiring test-provision-apply-a2 test-a0-wiring test-pr-comment; do
  bash scripts/$s.sh > /tmp/a5-$s.out 2>&1; echo "$s rc=$? $(grep -E '^RÉSULTAT|^Résultat|^RESULTAT' /tmp/a5-$s.out | tail -1)"
done
```
Expected : 174/174, 133/133, 142/142, 148/148, 176/176, 41/41 (sinon : noter l'écart, ne PAS le « corriger » en passant).

- [ ] **Step 2 : `make lint-ci` [13/13]** — `make lint-ci > /tmp/a5-lint.out 2>&1; echo rc=$?; tail -3 /tmp/a5-lint.out`.

---

## T1 — La porte dans le rôle + la lib de refus, prouvées contre un stub (section A + mutations)

**Files:** create `ansible/roles/apim_common/tasks/refus.yml`, modify `ansible/roles/apim_selfservice_app/tasks/main.yml` (tâches « API : résoudre l'id … » et « API : fail-closed si non publiée »), create `scripts/test-selfservice-api-gate-a5.sh` (squelette + section A).

**Interfaces:**
- Produces : `refus.yml` — entrées `refus_tag`, `refus_msg` ; lit `apim_ss_refus_out`, `apim_ss_refus_detail_out` ; facts `ss_api_by_name`, `ss_api_match`, `ss_api_refus`, `ss_api_refus_msg`, `ss_api_id` ; ligne console `API_AT_PALIER : …` ; marqueurs `# ── A5 porte : début` / `# ── A5 porte : fin` dans `main.yml`.

- [ ] **Step 1 : écrire le squelette de la suite + section A (rouge)**

`scripts/test-selfservice-api-gate-a5.sh` :

```bash
#!/usr/bin/env bash
# test-selfservice-api-gate-a5.sh — porte HORS LIGNE d'A5 (GOAL cd-applications) :
# l'ordre app/API — refus fermé si l'API n'est pas au palier.
#
#   A. le RÔLE apim_selfservice_app contre un STUB gateway (liste /apis pilotée
#      par ctl.json, JOURNAL méthode+chemin, toute écriture ⇒ 500 = canari) :
#      quatre refus nommés AVANT la première écriture, fichiers tag/détail,
#      chemin nominal (API_AT_PALIER puis POST /applications), mutations M1..M3.
#   B. VERIFY contre le MOCK webMethods du dépôt (binaire Go, shapes fidèles) :
#      API_AT_PALIER_CONFIRMED + SUBSCRIPTION_CONFIRMED, puis les deux refus.
#   C. le CÂBLAGE (vue code) : Jenkinsfile.selfservice, provision-apply, garde A3, rôle.
#   D. le RAPPORT de PR (provision-apply-comment.sh contre un faux Gitea).
#   E. le PROTOTYPE Python contre le stub : mêmes tags, exit 1 avant tout POST.
#
# Discipline A3 : toute sortie capturée dans un fichier avant grep ; mutations =
# copie, `cmp` anti-no-op, le scénario visé PASSE sur le mutant ET l'original
# refuse toujours ; le total des contrôles est asserté en dur.
# `A && ok || bad` (SC2015) est l'idiome des scripts de preuve du repo.
# shellcheck disable=SC2015
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; umask 077
PIDS=""
cleanup(){ for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
bad(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
command -v ansible-playbook >/dev/null || { echo "ansible-playbook absent"; exit 2; }
command -v python3 >/dev/null || { echo "python3 absent"; exit 2; }

# ── le stub gateway ─────────────────────────────────────────────────────────
STUB_CTL="$TMP/ctl.json"; STUB_LOG="$TMP/http.log"; : > "$STUB_LOG"
cat > "$TMP/stub.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
CTL, LOG = sys.argv[1], sys.argv[2]
def ctl():
    try: return json.load(open(CTL))
    except Exception: return {}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def _j(self, m):
        with open(LOG, "a") as f: f.write(m + " " + self.path.split("?")[0] + "\n")
    def do_GET(self):
        self._j("GET"); c = ctl(); p = self.path.split("?")[0]
        if p.endswith("/configurations/extended"): return self._send(200, {"enableTeamWork": "true"})
        if p.endswith("/apis"):
            return self._send(200, {"apiResponse": [{"api": a, "responseStatus": "SUCCESS", "teams": [{"id": "Default", "name": "Default", "source": "SYSTEM"}]} for a in c.get("apis", [])]})
        if "/apis/" in p:
            aid = p.rsplit("/", 1)[1]
            for a in c.get("apis", []):
                if a.get("id") == aid: return self._send(200, {"apiResponse": {"api": a, "teams": [{"id": "Default", "name": "Default", "source": "SYSTEM"}]}})
            return self._send(404, {"error": "no api"})
        if p.endswith("/applications"): return self._send(200, {"applications": c.get("applications", [])})
        if p.endswith("/policyActions"): return self._send(200, {"policyAction": []})
        return self._send(404, {"error": "stub: route inconnue " + p})
    def _write(self, m):
        n = int(self.headers.get("Content-Length", "0") or 0)
        if n: self.rfile.read(n)
        self._j(m); self._send(500, {"error": "stub: le canari a été touché (écriture refusée)"})
    def do_POST(self): self._write("POST")
    def do_PUT(self): self._write("PUT")
    def do_DELETE(self): self._write("DELETE")
srv = ThreadingHTTPServer(("127.0.0.1", 0), H); print(srv.server_address[1], flush=True); srv.serve_forever()
PY
python3 "$TMP/stub.py" "$STUB_CTL" "$STUB_LOG" > "$TMP/stub.port" 2>"$TMP/stub.err" &
PIDS="$PIDS $!"
for _ in $(seq 1 60); do [ -s "$TMP/stub.port" ] && break; sleep 0.1; done
PORT="$(head -n1 "$TMP/stub.port" 2>/dev/null)"
case "$PORT" in ''|*[!0-9]*) echo "!! stub non démarré : $(cat "$TMP/stub.err")"; exit 2;; esac
GW="http://127.0.0.1:$PORT/rest/apigateway"
# auto-test du canari : une écriture est journalisée ET refusée
curl -s -o /dev/null -X POST "$GW/canari-selftest"; grep -q '^POST .*/canari-selftest$' "$STUB_LOG" || { echo "!! le stub ne journalise pas les écritures — le silence des épreuves serait vacant"; exit 2; }

# ── fixtures ────────────────────────────────────────────────────────────────
ID_A="aaaaaaaa-0000-4000-8000-000000000001"; ID_B="bbbbbbbb-0000-4000-8000-000000000002"; ID_C="cccccccc-0000-4000-8000-000000000003"
api(){ printf '{"id":"%s","apiName":"%s","apiVersion":"%s"%s}' "$1" "$2" "$3" "${4:-}"; }
CTL_ABSENT='{"apis":[]}'
CTL_OTHER_VERSION="{\"apis\":[$(api "$ID_A" demo-selfservice 1.0.0 ',"isActive":true')]}"        # demandée : 2.0.0
CTL_INACTIVE="{\"apis\":[$(api "$ID_A" demo-selfservice 1.0.0 ',"isActive":false')]}"
CTL_NO_FIELD="{\"apis\":[$(api "$ID_A" demo-selfservice 1.0.0 '')]}"
CTL_STRING="{\"apis\":[$(api "$ID_A" demo-selfservice 1.0.0 ',"isActive":"true"')]}"
CTL_DUP="{\"apis\":[$(api "$ID_A" demo-selfservice 1.0.0 ',"isActive":true'),$(api "$ID_B" demo-selfservice 1.0.0 ',"isActive":true')]}"
CTL_ACTIVE="{\"apis\":[$(api "$ID_A" demo-selfservice 1.0.0 ',"isActive":true'),$(api "$ID_C" demo-selfservice 1.0.1 ',"isActive":false')]}"   # la fixture accounts-read du lab
man(){ # <fichier> <api_version>
  printf -- '---\napim_ss_app:\n  name: "a5app"\n  api: "demo-selfservice"\n  api_version: "%s"\n  description: "porte A5"\n  contact_emails: []\n  enforce: []\n  per_env:\n    rec: { ip_allowlist: ["10.42.0.1"] }\n' "$1" > "$2"
}
man 1.0.0 "$TMP/man.yml"; man 2.0.0 "$TMP/man-2.yml"
ANS_DIR="$REPO"   # un mutant pointe ailleurs
run_role(){ # <ctl json> [-e … | MAN=<fichier>] → rc $TMP/r.rc, console $TMP/r.out, journal $STUB_LOG
  printf '%s\n' "$1" > "$STUB_CTL"; : > "$STUB_LOG"; shift
  local m="$TMP/man.yml" a; local -a X=()
  for a in "$@"; do case "$a" in MAN=*) m="${a#MAN=}";; *) X+=("$a");; esac; done
  rm -f "$TMP/refus" "$TMP/refus.detail"
  ( cd "$ANS_DIR" && env -u VAULT_ADDR -u VAULT_TOKEN -u VAULT_TOKEN_FILE ANSIBLE_FORCE_COLOR=0 ANSIBLE_NOCOLOR=1 \
      ansible-playbook -i ansible/inventory.lab.ini ansible/selfservice-app.yml \
      -e "apim_ss_api_base=$GW" -e "apim_ss_manifest=$m" -e apim_ss_env=rec -e apim_ss_team=banking-demo \
      -e "apim_ss_refus_out=$TMP/refus" -e "apim_ss_refus_detail_out=$TMP/refus.detail" ${X[@]+"${X[@]}"} ) > "$TMP/r.out" 2>&1
  echo $? > "$TMP/r.rc"
}
rrc(){ cat "$TMP/r.rc"; }
writes(){ grep -cE '^(POST|PUT|DELETE) ' "$STUB_LOG"; }
refus(){ [ "$(rrc)" != 0 ] && grep -qF "REFUS: $1 :" "$TMP/r.out"; }
tail_out(){ grep -E 'REFUS|fatal|FAILED' "$TMP/r.out" | tail -2 | tr '\n' ' ' | cut -c1-300; }

echo "══ A. le rôle contre le stub : la porte AVANT la première écriture ══"
run_role "$CTL_ABSENT"
refus API_NOT_PROMOTED && [ "$(writes)" = 0 ] && ok "A.1 nom absent ⇒ rc≠0, REFUS: API_NOT_PROMOTED, AUCUNE écriture" || bad "A.1 rc $(rrc) writes=$(writes) : $(tail_out)"
[ "$(cat "$TMP/refus" 2>/dev/null)" = API_NOT_PROMOTED ] && ok "A.1b le tag est écrit dans apim_ss_refus_out" || bad "A.1b tag : '$(cat "$TMP/refus" 2>/dev/null)'"
[ "$(wc -l < "$TMP/refus.detail" 2>/dev/null | tr -d ' ')" = 1 ] && grep -q "promote/demo-selfservice-rec" "$TMP/refus.detail" && grep -q "rien n'a" "$TMP/refus.detail" \
  && ok "A.1c le détail (une ligne) nomme la promotion manquante promote/demo-selfservice-rec" || bad "A.1c détail : $(cat "$TMP/refus.detail" 2>/dev/null)"
! grep -qE "^GET .*/apis/$ID_A" "$STUB_LOG" && ok "A.1d le refus précède la garde de visibilité (aucun GET /apis/{id})" || bad "A.1d visibilité relue avant le refus"
run_role "$CTL_OTHER_VERSION" "MAN=$TMP/man-2.yml"
refus API_VERSION_MISMATCH && [ "$(writes)" = 0 ] && grep -q "1.0.0" "$TMP/refus.detail" && grep -q "'2.0.0'" "$TMP/refus.detail" \
  && ok "A.2 nom présent en 1.0.0, demandée 2.0.0 ⇒ API_VERSION_MISMATCH citant 1.0.0, aucune écriture" || bad "A.2 rc $(rrc) writes=$(writes) : $(tail_out) / $(cat "$TMP/refus.detail" 2>/dev/null)"
run_role "$CTL_INACTIVE"
refus API_INACTIVE && [ "$(writes)" = 0 ] && grep -q "isActive=False" "$TMP/refus.detail" && grep -q "$ID_A" "$TMP/refus.detail" \
  && ok "A.3 isActive:false ⇒ API_INACTIVE (valeur vue + id dans le détail), aucune écriture" || bad "A.3 rc $(rrc) writes=$(writes) : $(tail_out) / $(cat "$TMP/refus.detail" 2>/dev/null)"
run_role "$CTL_NO_FIELD"
refus API_INACTIVE && [ "$(writes)" = 0 ] && grep -q "isActive=absent" "$TMP/refus.detail" && ok "A.4 isActive ABSENT ⇒ API_INACTIVE (ne pas savoir n'est pas une raison de passer)" || bad "A.4 rc $(rrc) : $(tail_out) / $(cat "$TMP/refus.detail" 2>/dev/null)"
run_role "$CTL_STRING"
refus API_INACTIVE && [ "$(writes)" = 0 ] && ok "A.5 isActive:\"true\" (chaîne) ⇒ API_INACTIVE (booléen strict)" || bad "A.5 rc $(rrc) : $(tail_out)"
run_role "$CTL_DUP"
refus API_AMBIGUE && [ "$(writes)" = 0 ] && grep -q "^2 " "$TMP/refus.detail" && ok "A.6 deux entrées nom+version ⇒ API_AMBIGUE (fail-closed, jamais first)" || bad "A.6 rc $(rrc) : $(tail_out) / $(cat "$TMP/refus.detail" 2>/dev/null)"
run_role "$CTL_ACTIVE"
grep -q "API_AT_PALIER : 'demo-selfservice' v1.0.0 active au palier 'rec' (id=$ID_A)" "$TMP/r.out" && ok "A.7 active (1.0.1 inactive à côté) ⇒ API_AT_PALIER avec l'id de 1.0.0" || bad "A.7 marqueur absent : $(grep -c API_AT_PALIER "$TMP/r.out") — $(tail_out)"
[ "$(writes)" = 1 ] && grep -q "^POST .*/applications$" "$STUB_LOG" && ok "A.7b la porte laisse passer : la PREMIÈRE écriture (POST /applications) part et touche le canari" || bad "A.7b writes=$(writes) : $(grep -E '^(POST|PUT|DELETE)' "$STUB_LOG" | tr '\n' ' ')"
L_GATE=$(grep -n "API_AT_PALIER :" "$TMP/r.out" | head -1 | cut -d: -f1); L_POST=$(grep -n "App : créer si absente" "$TMP/r.out" | head -1 | cut -d: -f1)
[ -n "$L_GATE" ] && [ -n "$L_POST" ] && [ "$L_GATE" -lt "$L_POST" ] && ok "A.7c ORDRE console : API_AT_PALIER ($L_GATE) < « App : créer » ($L_POST)" || bad "A.7c ordre : porte=$L_GATE post=$L_POST"
grep -qE "^GET .*/apis/$ID_A$" "$STUB_LOG" && ok "A.7d la garde de visibilité a relu l'id résolu (GET /apis/{id}) — la porte lui fournit ss_api_id" || bad "A.7d GET /apis/{id} absent du journal"
[ ! -e "$TMP/refus" ] && [ ! -e "$TMP/refus.detail" ] && ok "A.7e chemin nominal : aucun fichier de refus" || bad "A.7e fichiers de refus présents sur le nominal"
run_role "$CTL_INACTIVE" -e apim_ss_refus_out= -e apim_ss_refus_detail_out=
refus API_INACTIVE && [ ! -e "$TMP/refus" ] && [ ! -e "$TMP/refus.detail" ] && ok "A.8 apply manuel (sans apim_ss_refus_*) : même REFUS:, aucun fichier" || bad "A.8 rc $(rrc) fichiers=$(ls "$TMP"/refus* 2>/dev/null | tr '\n' ' ')"
run_role "$CTL_INACTIVE"
[ "$(stat -f '%Lp' "$TMP/refus" 2>/dev/null || stat -c '%a' "$TMP/refus")" = 600 ] && ok "A.9 fichier de tag en 0600" || bad "A.9 mode : $(stat -f '%Lp' "$TMP/refus" 2>/dev/null || stat -c '%a' "$TMP/refus")"

# ── mutations : copie de l'arbre ansible, cmp anti-no-op, run depuis la copie ──
MAIN="$REPO/ansible/roles/apim_selfservice_app/tasks/main.yml"; REFUS="$REPO/ansible/roles/apim_common/tasks/refus.yml"
mutant(){ # <nom> <fichier relatif à ansible/> <sed -E expr> → $TMP/<nom>/ansible
  rm -rf "$TMP/$1"; mkdir -p "$TMP/$1"; cp -R "$REPO/ansible" "$TMP/$1/ansible"
  sed -E "$3" "$REPO/ansible/$2" > "$TMP/$1/ansible/$2"
  ! cmp -s "$REPO/ansible/$2" "$TMP/$1/ansible/$2" || { bad "mutation $1 = no-op (l'ancre a bougé)"; return 1; }
}
run_mut(){ local d="$1"; shift; ANS_DIR="$TMP/$d" run_role "$@"; }
if mutant m_active roles/apim_selfservice_app/tasks/main.yml 's/is sameas true/is not none/'; then
  run_mut m_active "$CTL_INACTIVE"
  [ "$(writes)" -ge 1 ] && grep -q "^POST .*/applications$" "$STUB_LOG" && ok "A.M1 isActive ignoré ⇒ l'inactive ATTEINT POST /applications sur le mutant" || bad "A.M1 le mutant refuse encore : $(tail_out)"
  run_role "$CTL_INACTIVE"; refus API_INACTIVE && [ "$(writes)" = 0 ] && ok "A.M1' l'original refuse toujours API_INACTIVE sans écriture" || bad "A.M1' l'original a dérivé"
fi
# A.M2 mutation d'ORDRE : le bloc de la porte (marqueurs) déplacé APRÈS « App : fail-closed — un id … » — l'ordre se mesure au JOURNAL (une écriture avant le refus).
awk '/^    # ── A5 porte : début/,/^    # ── A5 porte : fin/' "$MAIN" > "$TMP/blk-a5"
rm -rf "$TMP/m_order"; mkdir -p "$TMP/m_order"; cp -R "$REPO/ansible" "$TMP/m_order/ansible"
awk '/^    # ── A5 porte : début/ { skip=1 } skip && /^    # ── A5 porte : fin/ { skip=0; next } skip { next } { print } /^    - name: "App : fail-closed — un id d.application est obligatoire pour la suite"/ { getline; print; getline; print; getline; print; while ((getline l < B) > 0) print l; close(B) }' B="$TMP/blk-a5" "$MAIN" > "$TMP/m_order/ansible/roles/apim_selfservice_app/tasks/main.yml"
if [ -s "$TMP/blk-a5" ] && ! cmp -s "$MAIN" "$TMP/m_order/ansible/roles/apim_selfservice_app/tasks/main.yml" && python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$TMP/m_order/ansible/roles/apim_selfservice_app/tasks/main.yml" 2>/dev/null; then
  run_mut m_order "$CTL_ABSENT"
  [ "$(writes)" -ge 1 ] && ok "A.M2 porte déplacée après la création ⇒ une ÉCRITURE part avant le refus sur le mutant (le journal la voit)" || bad "A.M2 le mutant n'écrit pas : $(tail_out)"
  run_role "$CTL_ABSENT"; refus API_NOT_PROMOTED && [ "$(writes)" = 0 ] && ok "A.M2' l'original refuse toujours avant toute écriture" || bad "A.M2' l'original a dérivé"
else
  bad "A.M2 mutant d'ordre non construit (marqueurs A5 absents ou YAML invalide)"
fi
if mutant m_tag roles/apim_common/tasks/refus.yml '/^- name: "Refus : écrire le tag/,/^$/d'; then
  run_mut m_tag "$CTL_ABSENT"
  refus API_NOT_PROMOTED && [ ! -e "$TMP/refus" ] && ok "A.M3 refus.yml sans l'écriture du tag ⇒ le refus tombe mais RIEN n'atteint la PR sur le mutant" || bad "A.M3 mutant : rc $(rrc) tag=$(cat "$TMP/refus" 2>/dev/null)"
  run_role "$CTL_ABSENT"; [ "$(cat "$TMP/refus" 2>/dev/null)" = API_NOT_PROMOTED ] && ok "A.M3' l'original écrit le tag" || bad "A.M3' l'original a dérivé"
fi

# (sections B..E ajoutées par T2..T5)

EXPECTED_CHECKS=23
TOTAL=$((PASS+FAIL))
[ "$TOTAL" -eq "$((EXPECTED_CHECKS-1))" ] \
  && ok "$((TOTAL+1)) contrôles exécutés = $EXPECTED_CHECKS attendus (aucune section sautée)" \
  || bad "$((TOTAL+1)) contrôles exécutés, $EXPECTED_CHECKS attendus — une section a été sautée ou ajoutée sans mettre EXPECTED_CHECKS à jour"
echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 2 : la voir ROUGE** — `bash scripts/test-selfservice-api-gate-a5.sh > /tmp/a5-A.out 2>&1; tail -30 /tmp/a5-A.out` — attendu : A.1..A.9 rouges (le rôle rend « API … absente — la publier d'abord » sans tag, l'inactive passe jusqu'au POST), mutations non construites.

- [ ] **Step 3 : `refus.yml`**

```yaml
---
# roles/apim_common/tasks/refus.yml — UN refus nommé, RELAYÉ (A5, GOAL cd-applications).
#
# Entrées : refus_tag (classe [A-Z][A-Z0-9_]{2,40}), refus_msg (une phrase).
# Effets, dans l'ordre : (1) le TAG dans apim_ss_refus_out s'il est posé ;
# (2) la phrase dans apim_ss_refus_detail_out s'il est posé (une ligne, ≤ 300) ;
# (3) fail « REFUS: <TAG> : <phrase> » — la ligne que consoles et suites lisent.
# AUCUN appel gateway. Le relais jusqu'à la PR est celui d'A4 (fait Jenkins 11
# mesuré) : post{always} de stage → buildVariables → provision-apply →
# provision-apply-comment.sh. Sans les deux variables (apply manuel) : rien
# n'est écrit, la ligne REFUS: suffit.
- name: "Refus : le tag est de la classe [A-Z][A-Z0-9_]{2,40}"
  ansible.builtin.assert:
    that: "(refus_tag | default('') | string) is match('^[A-Z][A-Z0-9_]{2,40}$')"
    fail_msg: "REFUS: CABLAGE_INCOMPLET : refus.yml appelé avec un tag hors classe ('{{ refus_tag | default('') }}')"

- name: "Refus : la phrase, une ligne, bornée"
  ansible.builtin.set_fact:
    refus_line: >-
      {{ ((refus_msg | default('') | string) | regex_replace('[\r\n\t]+', ' ') | regex_replace(' {2,}', ' ') | trim)[:300] }}

- name: "Refus : écrire le tag pour l'amont"
  ansible.builtin.copy:
    content: "{{ refus_tag }}\n"
    dest: "{{ apim_ss_refus_out }}"
    mode: "0600"
  when: "(apim_ss_refus_out | default('') | string) | length > 0"
  delegate_to: localhost

- name: "Refus : écrire la phrase pour la PR"
  ansible.builtin.copy:
    content: "{{ refus_line }}\n"
    dest: "{{ apim_ss_refus_detail_out }}"
    mode: "0600"
  when: "(apim_ss_refus_detail_out | default('') | string) | length > 0"
  delegate_to: localhost

- name: "REFUS: {{ refus_tag }}"
  ansible.builtin.fail:
    msg: "REFUS: {{ refus_tag }} : {{ refus_line }}"
```

- [ ] **Step 4 : la porte dans `main.yml`** — remplacer les deux tâches « API : résoudre l'id de … » et « API : fail-closed si non publiée » (garder « API : lister » telle quelle) par :

```yaml
    # ── A5 porte : début ──────────────────────────────────────────────────
    # ===== 1. LA PORTE A5 — l'API est-elle AU PALIER : ce nom, cette version, ACTIVE ? =====
    # Spike S2 (2026-09-02, 10.15 réelle) : la gateway ACCEPTE la souscription
    # à une API inactive (200, trafic 404) et une paire posée puis retirée est
    # BRÛLÉE (S1-T3, ré-inscription 500). La porte précède donc la PREMIÈRE
    # écriture (§2, POST /applications) et ne se rattrape jamais après coup.
    # Quatre refus nommés, relayés jusqu'à la PR (apim_common/tasks/refus.yml).
    # `isActive` : booléen JSON strict — absent, null, "true" (chaîne) ou 1 sont
    # INACTIFS (ne pas savoir n'est pas une raison de passer). Le marqueur
    # `API_AT_PALIER :` est celui que les preuves live lisent.
    - name: "API : entrées de ce nom, puis de cette version"
      ansible.builtin.set_fact:
        ss_api_by_name: >-
          {{ (ss_apis.json.apiResponse | default([])) | map(attribute='api')
             | selectattr('apiName', 'defined') | selectattr('apiName', 'equalto', apim_ss_app.api) | list }}

    - ansible.builtin.set_fact:
        ss_api_match: >-
          {{ ss_api_by_name | selectattr('apiVersion', 'defined')
             | selectattr('apiVersion', 'equalto', apim_ss_app.api_version | string) | list }}

    - name: "API : verdict de la porte (nom → version → unicité → activité)"
      ansible.builtin.set_fact:
        ss_api_refus: >-
          {{ 'API_NOT_PROMOTED' if (ss_api_by_name | length == 0)
             else ('API_VERSION_MISMATCH' if (ss_api_match | length == 0)
             else ('API_AMBIGUE' if (ss_api_match | length > 1)
             else ('' if (((ss_api_match | first).isActive | default(none)) is sameas true) else 'API_INACTIVE'))) }}
        ss_api_env: "{{ (apim_ss_env | default('', true)) or '(mono-env)' }}"

    - name: "API : la phrase du refus (nomme l'API, la version, le palier, le remède)"
      ansible.builtin.set_fact:
        ss_api_refus_msg: >-
          {% if ss_api_refus == 'API_NOT_PROMOTED' %}l'API '{{ apim_ss_app.api }}' n'est pas au palier '{{ ss_api_env }}' (aucune version publiée sur {{ apim_ss_api_base }}) — promouvoir l'API vers {{ ss_api_env }} (chaîne des APIs : PR promote/{{ apim_ss_app.api }}-{{ ss_api_env }}, G5) puis rejouer l'apply ; rien n'a été écrit
          {%- elif ss_api_refus == 'API_VERSION_MISMATCH' %}l'API '{{ apim_ss_app.api }}' est au palier '{{ ss_api_env }}' en version(s) {{ ss_api_by_name | map(attribute='apiVersion') | map('string') | list | join(', ') }}, pas en '{{ apim_ss_app.api_version }}' — promouvoir cette version vers {{ ss_api_env }} (G5) ou corriger la demande (api_version est figé : une autre version est une NOUVELLE application, A1) ; rien n'a été écrit
          {%- elif ss_api_refus == 'API_AMBIGUE' %}{{ ss_api_match | length }} entrées '{{ apim_ss_app.api }}' v{{ apim_ss_app.api_version }} sur {{ apim_ss_api_base }} — résolution impossible sans choisir, refus fail-closed ; rien n'a été écrit
          {%- elif ss_api_refus == 'API_INACTIVE' %}l'API '{{ apim_ss_app.api }}' v{{ apim_ss_app.api_version }} est au palier '{{ ss_api_env }}' mais INACTIVE (isActive={{ (ss_api_match | first).isActive | default('absent') }}, id={{ (ss_api_match | first).id | default('?') }}) — une souscription à une API inactive est une souscription à rien (spike S2 : acceptée par la gateway, trafic 404) ; activer l'API au palier (geste producteur) puis rejouer l'apply ; rien n'a été écrit
          {%- endif %}
      when: "ss_api_refus | length > 0"

    - name: "API : REFUS {{ ss_api_refus }} — la porte A5, avant la première écriture"
      ansible.builtin.include_role:
        name: apim_common
        tasks_from: refus.yml
      vars:
        refus_tag: "{{ ss_api_refus }}"
        refus_msg: "{{ ss_api_refus_msg }}"
      when: "ss_api_refus | length > 0"

    - name: "API : id résolu — ce nom, cette version, active"
      ansible.builtin.set_fact:
        ss_api_id: "{{ (ss_api_match | first).id }}"

    - name: "API : au palier"
      ansible.builtin.debug:
        msg: "API_AT_PALIER : '{{ apim_ss_app.api }}' v{{ apim_ss_app.api_version }} active au palier '{{ ss_api_env }}' (id={{ ss_api_id }})"
    # ── A5 porte : fin ────────────────────────────────────────────────────
```

Piège Jinja : `{%- … %}` (trait d'union) sur les `elif`/`endif` pour ne pas laisser de retour-ligne dans la phrase ; `is sameas true` entre parenthèses (précédence filtre/test) ; `default(none)` sur un attribut absent.

- [ ] **Step 5 : la voir VERTE** — `bash scripts/test-selfservice-api-gate-a5.sh` ⇒ `RÉSULTAT : 23/23`. Si `isActive=False` (Python) apparaît autrement (`false`), aligner l'assertion A.3 sur la valeur rendue par Jinja.

- [ ] **Step 6 : régressions rôle** — `bash scripts/test-backend-key.sh` (mock Go, rôle entier) et `bash scripts/test-selfservice-palier-a3.sh` (174/174, inchangée) ; `ansible-playbook --syntax-check -i ansible/inventory.lab.ini ansible/selfservice-app.yml`.

- [ ] **Step 7 : commit** — `git add ansible/roles/apim_common/tasks/refus.yml ansible/roles/apim_selfservice_app/tasks/main.yml scripts/test-selfservice-api-gate-a5.sh && git commit -m "feat(cd-apps): A5 — la porte de l'ordre app/API dans le rôle (nom+version+isActive, API_NOT_PROMOTED/API_VERSION_MISMATCH/API_AMBIGUE/API_INACTIVE avant la première écriture) + lib de refus apim_common relayée ; suite hors ligne section A 23/23 (stub, journal, 3 mutations)"`.

---

## T2 — Verify relit l'API au palier et la souscription (section B, mock Go)

**Files:** modify `ansible/roles/apim_selfservice_app/tasks/verify.yml` (après le `set_fact` `v_api_id`), modify `scripts/test-selfservice-api-gate-a5.sh` (section B ; `EXPECTED_CHECKS`).

**Interfaces:** Consumes `refus.yml` (T1). Produces console `API_AT_PALIER_CONFIRMED : …`, `SUBSCRIPTION_CONFIRMED : …`, refus `API_AT_PALIER_UNCONFIRMED`, `SUBSCRIPTION_UNCONFIRMED`.

- [ ] **Step 1 : section B (rouge)** — insérer avant `EXPECTED_CHECKS` :

```bash
echo
echo "══ B. verify contre le MOCK webMethods (shapes fidèles) ══"
if command -v go >/dev/null && (cd "$REPO/mocks/webmethods" && go build -o "$TMP/wm-mock" . 2>"$TMP/mock.build"); then
  MPORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
  LISTEN_ADDR=":$MPORT" "$TMP/wm-mock" > "$TMP/mock.log" 2>&1 &
  PIDS="$PIDS $!"
  for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$MPORT/health" >/dev/null 2>&1 && break; sleep 0.2; done
  MGW="http://127.0.0.1:$MPORT/rest/apigateway"
  madm(){ curl -s -u Administrator:manage -H 'Accept: application/json' -H 'Content-Type: application/json' "$@"; }
  mk_api(){ madm -X POST "$MGW/apis" -d "{\"apiName\":\"$1\",\"apiVersion\":\"$2\",\"type\":\"REST\",\"apiDefinition\":{\"openapi\":\"3.0.0\"}}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["apiResponse"]["api"]["id"])'; }
  API1=$(mk_api demo-selfservice 1.0.0); madm -X PUT -o /dev/null "$MGW/apis/$API1/activate"
  [ -n "$API1" ] && ok "B.0 mock : demo-selfservice 1.0.0 publiée et activée ($API1)" || bad "B.0 mock : API non créée ($(head -c 200 "$TMP/mock.log"))"
  run_mock(){ # <playbook> → $TMP/r.rc, $TMP/r.out
    rm -f "$TMP/refus" "$TMP/refus.detail"
    ( cd "$REPO" && env -u VAULT_ADDR -u VAULT_TOKEN -u VAULT_TOKEN_FILE ANSIBLE_FORCE_COLOR=0 ANSIBLE_NOCOLOR=1 \
        ansible-playbook -i ansible/inventory.lab.ini "ansible/$1" -e "apim_ss_api_base=$MGW" -e "apim_ss_manifest=$TMP/man.yml" \
        -e apim_ss_env=rec -e apim_ss_team=banking-demo -e apim_ss_require_team=false \
        -e "apim_ss_refus_out=$TMP/refus" -e "apim_ss_refus_detail_out=$TMP/refus.detail" ) > "$TMP/r.out" 2>&1; echo $? > "$TMP/r.rc"
  }
  run_mock selfservice-app.yml
  [ "$(rrc)" = 0 ] && grep -q "API_AT_PALIER : 'demo-selfservice' v1.0.0 active" "$TMP/r.out" && ok "B.1 converge sur le mock : rc 0, API_AT_PALIER" || bad "B.1 rc $(rrc) : $(tail_out)"
  run_mock selfservice-app-verify.yml
  [ "$(rrc)" = 0 ] && grep -q "API_AT_PALIER_CONFIRMED" "$TMP/r.out" && grep -q "SUBSCRIPTION_CONFIRMED" "$TMP/r.out" && grep -q "id=$API1" "$TMP/r.out" \
    && ok "B.2 verify : API_AT_PALIER_CONFIRMED + SUBSCRIPTION_CONFIRMED (souscrite au GUID $API1)" || bad "B.2 rc $(rrc) : $(grep -E 'CONFIRMED|REFUS' "$TMP/r.out" | tr '\n' ' ' | cut -c1-300)"
  madm -X PUT -o /dev/null "$MGW/apis/$API1/deactivate"
  run_mock selfservice-app-verify.yml
  refus API_AT_PALIER_UNCONFIRMED && [ "$(cat "$TMP/refus")" = API_AT_PALIER_UNCONFIRMED ] && ok "B.3 API désactivée après l'apply ⇒ verify refuse API_AT_PALIER_UNCONFIRMED (tag relayé)" || bad "B.3 rc $(rrc) : $(tail_out)"
  run_mock selfservice-app.yml
  refus API_INACTIVE && ok "B.4 le mock est fidèle : converge sur l'inactive ⇒ API_INACTIVE (isActive booléen du mock)" || bad "B.4 rc $(rrc) : $(tail_out)"
  madm -X PUT -o /dev/null "$MGW/apis/$API1/activate"
  API2=$(mk_api autre-api 1.0.0); madm -X PUT -o /dev/null "$MGW/apis/$API2/activate"
  APPID=$(madm "$MGW/applications" | python3 -c 'import sys,json;print(next(a["id"] for a in json.load(sys.stdin)["applications"] if a["name"]=="a5app"))')
  madm -X PUT -o /dev/null "$MGW/applications/$APPID/apis" -d "{\"apiIDs\":[\"$API2\"]}"
  run_mock selfservice-app-verify.yml
  refus SUBSCRIPTION_UNCONFIRMED && grep -q "$API2" "$TMP/refus.detail" && ok "B.5 souscription remplacée par une autre API ⇒ SUBSCRIPTION_UNCONFIRMED (consumingAPIs cité)" || bad "B.5 rc $(rrc) : $(tail_out) / $(cat "$TMP/refus.detail" 2>/dev/null)"
else
  bad "B.0 mock Go non bâti (go absent ou build en échec : $(head -c 200 "$TMP/mock.build" 2>/dev/null))"
  for _ in 1 2 3 4 5; do bad "B.x section sautée"; done
fi
```
`EXPECTED_CHECKS=29`.

- [ ] **Step 2 : rouge** — B.2/B.3/B.5 rouges (verify ne connaît pas ces marqueurs).

- [ ] **Step 3 : `verify.yml`** — après le `set_fact` de `v_api_id` (avant « Verify : garde du register ») :

```yaml
    # ── A5 : l'API est-elle AU PALIER (nom, version, unique, ACTIVE) ? Même
    # prédicat qu'à l'apply — rejouable : une API désactivée APRÈS l'apply
    # rougit ici (l'apply seul ne le verrait plus). Refus relayé (refus.yml).
    - name: "Verify : entrées nom+version de l'API"
      ansible.builtin.set_fact:
        v_api_match: >-
          {{ (v_apis.json.apiResponse | default([])) | map(attribute='api')
             | selectattr('apiName', 'defined') | selectattr('apiName', 'equalto', apim_ss_app.api)
             | selectattr('apiVersion', 'defined') | selectattr('apiVersion', 'equalto', apim_ss_app.api_version | string) | list }}
        v_env: "{{ (apim_ss_env | default('', true)) or '(mono-env)' }}"

    - name: "Verify : REFUS API_AT_PALIER_UNCONFIRMED"
      ansible.builtin.include_role:
        name: apim_common
        tasks_from: refus.yml
      vars:
        refus_tag: API_AT_PALIER_UNCONFIRMED
        refus_msg: >-
          l'API '{{ apim_ss_app.api }}' v{{ apim_ss_app.api_version }} n'est pas (ou plus) active au palier '{{ v_env }}' :
          {{ v_api_match | length }} entrée(s), isActive={{ ((v_api_match | first).isActive | default('absent')) if (v_api_match | length == 1) else 'n/a' }}
          — l'application est convergée mais sa souscription ne sert rien ; promouvoir/activer l'API au palier puis rejouer verify
      when: "not ((v_api_match | length == 1) and (((v_api_match | first).isActive | default(none)) is sameas true))"

    - ansible.builtin.debug:
        msg: "API_AT_PALIER_CONFIRMED : '{{ apim_ss_app.api }}' v{{ apim_ss_app.api_version }} active au palier '{{ v_env }}' (id={{ v_api_id }})"

    # ── A5 : la souscription au GUID, RELUE (ce qu'A6 comparera avant/après repli)
    - name: "Verify : APIs consommées par l'application (liste relue en tête)"
      ansible.builtin.set_fact:
        v_app_apis: >-
          {{ ((v_apps.json.applications | selectattr('name', 'equalto', apim_ss_app.name) | list | first | default({})).consumingAPIs) | default([], true) }}

    - name: "Verify : REFUS SUBSCRIPTION_UNCONFIRMED"
      ansible.builtin.include_role:
        name: apim_common
        tasks_from: refus.yml
      vars:
        refus_tag: SUBSCRIPTION_UNCONFIRMED
        refus_msg: >-
          l'application '{{ apim_ss_app.name }}' n'est pas souscrite à '{{ apim_ss_app.api }}' v{{ apim_ss_app.api_version }} (id={{ v_api_id }}) —
          consumingAPIs={{ v_app_apis | list }} ; la convergence a eu lieu mais la souscription relue n'est pas celle du manifeste
      when: "v_api_id not in (v_app_apis | list)"

    - ansible.builtin.debug:
        msg: "SUBSCRIPTION_CONFIRMED : '{{ apim_ss_app.name }}' souscrite à '{{ apim_ss_app.api }}' v{{ apim_ss_app.api_version }} (id={{ v_api_id }})"
```

- [ ] **Step 4 : vert** — `bash scripts/test-selfservice-api-gate-a5.sh` ⇒ 29/29 ; `ansible-playbook --syntax-check -i ansible/inventory.lab.ini ansible/selfservice-app-verify.yml`. Si le mock ne porte pas `consumingAPIs` sur la liste, lire `GET /applications/{id}/apis` — mais le commentaire `admin.go:978` dit que la liste le porte : ne pas changer le rôle sans mesurer.

- [ ] **Step 5 : commit** — `git add ansible/roles/apim_selfservice_app/tasks/verify.yml scripts/test-selfservice-api-gate-a5.sh && git commit -m "feat(cd-apps): A5 — verify relit l'API au palier (API_AT_PALIER_CONFIRMED) et la souscription au GUID (SUBSCRIPTION_CONFIRMED), refus relayés ; section B contre le mock Go 29/29"`.

---

## T3 — Le relais tag + phrase : Jenkinsfile.selfservice, garde A3, provision-apply (section C, A3 additifs)

**Files:** modify `ci/Jenkinsfile.selfservice`, `scripts/selfservice-palier-gate.sh`, `ci/Jenkinsfile.provision-apply`, `scripts/test-selfservice-palier-a3.sh` (A.38-A.40, `EXPECTED_CHECKS=177`), `scripts/test-selfservice-api-gate-a5.sh` (section C ; `EXPECTED_CHECKS`).

- [ ] **Step 1 : section C (rouge)** :

```bash
echo
echo "══ C. le câblage (vue code) ══"
JFS="$REPO/ci/Jenkinsfile.selfservice"; JFA="$REPO/ci/Jenkinsfile.provision-apply"; GATE="$REPO/scripts/selfservice-palier-gate.sh"
sed -E 's@^[[:space:]]*(//|#).*$@@' "$JFS" > "$TMP/jfs.code"; sed -E 's@^[[:space:]]*//.*$@@' "$JFA" > "$TMP/jfa.code"
[ "$(grep -c -- '-e apim_ss_refus_out="\$WORKSPACE/.a3-refus" -e apim_ss_refus_detail_out="\$WORKSPACE/.a3-refus-detail"' "$TMP/jfs.code")" = 2 ] && ok "C.1 les DEUX plays (converge, verify) reçoivent apim_ss_refus_out + apim_ss_refus_detail_out" || bad "C.1 lignes -e apim_ss_refus_* : $(grep -c 'apim_ss_refus_out' "$TMP/jfs.code")"
grep 'selfservice-palier-gate.sh' "$TMP/jfs.code" | grep -q 'REFUS_DETAIL_OUT="\$WORKSPACE/.a3-refus-detail"' && ok "C.2 la garde A3 reçoit REFUS_DETAIL_OUT sur sa ligne d'appel" || bad "C.2 REFUS_DETAIL_OUT absent de la ligne de la garde"
[ "$(grep -c 'rm -f "\$WORKSPACE/.a3-refus" "\$WORKSPACE/.a3-refus-detail"' "$TMP/jfs.code")" -ge 2 ] && ok "C.3 deux purges ABSOLUES du tag ET du détail" || bad "C.3 purges : $(grep -c 'a3-refus-detail' "$TMP/jfs.code")"
grep -q 'env.APPLIED_REFUSAL_DETAIL = (env.APPLIED_REFUSAL && d ==~ /\[^\\r\\n\]{1,300}/) ? d : ' "$TMP/jfs.code" && ok "C.4 post{always} relit le détail sous [^\\r\\n]{1,300} et seulement avec un tag" || bad "C.4 relais du détail absent ou sans classe"
grep -q "vars.APPLIED_REFUSAL_DETAIL" "$TMP/jfa.code" && grep -q 'env.APPLIED_REFUSAL_DETAIL = (env.APPLIED_REFUSAL && ad ==~ /\[^\\r\\n\]{1,300}/) ? ad : ' "$TMP/jfa.code" && grep -q 'env.REFUSAL_DETAIL = env.APPLIED_REFUSAL_DETAIL ? "aval ${env.APPLY_BUILD} : ${env.APPLIED_REFUSAL_DETAIL}"' "$TMP/jfa.code" \
  && ok "C.5 provision-apply relit APPLIED_REFUSAL_DETAIL sous classe et compose « aval #n : <détail> »" || bad "C.5 composition du détail absente"
L_G=$(grep -n 'selfservice-palier-gate.sh" || exit 1' "$TMP/jfs.code" | head -1 | cut -d: -f1); L_P=$(grep -n 'préflight de joignabilité :' "$JFS" | head -1 | cut -d: -f1); L_C=$(grep -n 'ansible/selfservice-app.yml \\' "$TMP/jfs.code" | head -1 | cut -d: -f1); L_V=$(grep -n 'ansible/selfservice-app-verify.yml \\' "$TMP/jfs.code" | head -1 | cut -d: -f1)
[ -n "$L_G" ] && [ -n "$L_P" ] && [ -n "$L_C" ] && [ -n "$L_V" ] && [ "$L_G" -lt "$L_P" ] && [ "$L_P" -lt "$L_C" ] && [ "$L_C" -lt "$L_V" ] && ok "C.6 ORDRE inchangé : garde ($L_G) < préflight ($L_P) < converge ($L_C) < verify ($L_V)" || bad "C.6 ordre : garde=$L_G préflight=$L_P converge=$L_C verify=$L_V"
L_A5=$(grep -n '^    # ── A5 porte : début' "$MAIN" | cut -d: -f1); L_CR=$(grep -n 'App : créer si absente' "$MAIN" | head -1 | cut -d: -f1); L_VIS=$(grep -n 'import_tasks: api-visibility.yml' "$MAIN" | head -1 | cut -d: -f1)
[ -n "$L_A5" ] && [ "$L_A5" -lt "$L_VIS" ] && [ "$L_VIS" -lt "$L_CR" ] && ok "C.7 rôle : porte A5 ($L_A5) < visibilité ($L_VIS) < création ($L_CR)" || bad "C.7 rôle : a5=$L_A5 vis=$L_VIS create=$L_CR"
grep -q 'tasks_from: refus.yml' "$MAIN" && grep -q 'tasks_from: refus.yml' "$REPO/ansible/roles/apim_selfservice_app/tasks/verify.yml" && ok "C.8 main.yml ET verify.yml passent par refus.yml" || bad "C.8 refus.yml non consommé"
sed -E 's@^[[:space:]]*#.*$@@' "$GATE" > "$TMP/gate.code"
L_RD=$(grep -n '^REFUS_DETAIL_OUT="\${REFUS_DETAIL_OUT:-}"' "$TMP/gate.code" | cut -d: -f1); L_RF=$(grep -n '^refus()' "$TMP/gate.code" | cut -d: -f1)
[ -n "$L_RD" ] && [ -n "$L_RF" ] && [ "$L_RD" -lt "$L_RF" ] && grep -q 'rm -f "\$REFUS_DETAIL_OUT"' "$TMP/gate.code" && ok "C.9 garde A3 : REFUS_DETAIL_OUT lu AVANT refus(), purgé en tête" || bad "C.9 garde : lu=$L_RD refus=$L_RF"
```
`EXPECTED_CHECKS=38`.

- [ ] **Step 2 : A.38-A.40 dans la suite A3 (rouge)** — après A.37, avant `if mutant … m_dep` :

```bash
set_ctl '{"lookup":{"policies":["deploy-banking-demo","default"]},"caps":{"paths":{"secret/data/stoa/envs/int/wm-admin":["read"]}},"kv":{"secret/data/stoa/envs/int/wm-admin":403}}'
run_gate int "STOA_ENV_CHAIN_FILE=$TMP/chain.yaml" "REFUS_OUT=$TMP/refus" "REFUS_DETAIL_OUT=$TMP/refus.detail"
refus PALIER_FERME && [ "$(cat "$TMP/refus")" = PALIER_FERME ] && [ "$(wc -l < "$TMP/refus.detail" | tr -d ' ')" = 1 ] && grep -q "envs/int/wm-admin" "$TMP/refus.detail" \
  && ok "A.38 REFUS_DETAIL_OUT : la PHRASE du refus, une ligne, à côté du tag (A5 — la PR nomme la cause)" || bad "A.38 rc $(grc) tag=$(cat "$TMP/refus" 2>/dev/null) détail=$(cat "$TMP/refus.detail" 2>/dev/null)"
printf 'perime\n' > "$TMP/refus.detail"
set_ctl "$CTL_INT_OK"; run_gate int "STOA_ENV_CHAIN_FILE=$TMP/chain-gab.yaml" VAULT_USER=alice "REFUS_OUT=$TMP/refus" "REFUS_DETAIL_OUT=$TMP/refus.detail"
[ "$(grc)" = 0 ] && [ ! -e "$TMP/refus.detail" ] && ok "A.39 REFUS_DETAIL_OUT purgé en tête (un détail périmé n'est pas relayé)" || bad "A.39 rc $(grc) détail=$(cat "$TMP/refus.detail" 2>/dev/null)"
set_ctl '{"lookup":{"policies":["deploy-banking-demo","default"]},"caps":{"paths":{"secret/data/stoa/envs/int/wm-admin":["read"]}},"kv":{"secret/data/stoa/envs/int/wm-admin":403}}'
run_gate int "STOA_ENV_CHAIN_FILE=$TMP/chain.yaml" "REFUS_OUT=$TMP/refus" UNSET:REFUS_DETAIL_OUT
refus PALIER_FERME && [ ! -e "$TMP/refus.detail" ] && ok "A.40 sans REFUS_DETAIL_OUT : aucun fichier de détail (le tag seul)" || bad "A.40 rc $(grc) détail présent"
```
(`CTL_INT_OK` et `chain-gab.yaml` existent déjà dans la suite — vérifier leurs noms exacts avant d'écrire, `grep -n 'CTL_INT_OK=\|chain-gab' scripts/test-selfservice-palier-a3.sh`.) `EXPECTED_CHECKS=177`.

- [ ] **Step 3 : rouge** — les deux suites.

- [ ] **Step 4 : la garde A3** (`scripts/selfservice-palier-gate.sh`) :

```bash
REFUS_OUT="${REFUS_OUT:-}"
# A5 : la PHRASE du refus, à côté du tag — même relais, la PR nomme la cause.
REFUS_DETAIL_OUT="${REFUS_DETAIL_OUT:-}"
refus(){ printf 'REFUS: %s : %s\n' "$1" "$2"; [ -n "$REFUS_OUT" ] && printf '%s\n' "$1" > "$REFUS_OUT"; [ -n "$REFUS_DETAIL_OUT" ] && printf '%.300s\n' "$2" | tr -d '\r' > "$REFUS_DETAIL_OUT"; exit 1; }
…
[ -n "$REFUS_OUT" ] && rm -f "$REFUS_OUT"
[ -n "$REFUS_DETAIL_OUT" ] && rm -f "$REFUS_DETAIL_OUT"
```

- [ ] **Step 5 : `ci/Jenkinsfile.selfservice`** — (a) `rm -f "$WORKSPACE/.a3-refus"` ⇒ `rm -f "$WORKSPACE/.a3-refus" "$WORKSPACE/.a3-refus-detail"` (les deux occurrences) ; (b) ligne de la garde : `… REFUS_OUT="$WORKSPACE/.a3-refus" REFUS_DETAIL_OUT="$WORKSPACE/.a3-refus-detail" PALIER_OUT="$PALIER_OUT" …` ; (c) sur les deux `ansible-playbook`, après `-e apim_ss_env="${ENVIRONMENT:-}" \` : `-e apim_ss_refus_out="$WORKSPACE/.a3-refus" -e apim_ss_refus_detail_out="$WORKSPACE/.a3-refus-detail" \` ; (d) `post{always}` :

```groovy
      // A4/A5 — LE REFUS NOMMÉ, RELAYÉ (fait 11 mesuré) : le tag écrit dans
      // $WORKSPACE/.a3-refus (par la garde du palier AVANT son exit 1, ou par le
      // rôle via apim_common/tasks/refus.yml AVANT son fail) devient
      // env.APPLIED_REFUSAL ; sa PHRASE (.a3-refus-detail) devient
      // env.APPLIED_REFUSAL_DETAIL — relayée SEULEMENT avec un tag, sous classe
      // (une ligne, 300). provision-apply les lit dans buildVariables et la PR
      // nomme le refus ET sa cause. Restent « EN ÉCHEC — voir la console » :
      // TTL_INSUFFISANT, GATE_ABSENTE, login refusé (spec A4 D9).
      post {
        always {
          script {
            if (fileExists("${env.WORKSPACE}/.a3-refus")) {
              def t = readFile("${env.WORKSPACE}/.a3-refus").trim()
              env.APPLIED_REFUSAL = (t ==~ /[A-Z][A-Z0-9_]{2,40}/) ? t : ''
              def d = fileExists("${env.WORKSPACE}/.a3-refus-detail") ? readFile("${env.WORKSPACE}/.a3-refus-detail").trim() : ''
              env.APPLIED_REFUSAL_DETAIL = (env.APPLIED_REFUSAL && d ==~ /[^\r\n]{1,300}/) ? d : ''
              echo "refus relayé à l'amont : ${env.APPLIED_REFUSAL ?: '(tag hors classe, ignoré)'}${env.APPLIED_REFUSAL_DETAIL ? ' — ' + env.APPLIED_REFUSAL_DETAIL : ''}"
            }
          }
        }
      }
```

- [ ] **Step 6 : `ci/Jenkinsfile.provision-apply`** :

```groovy
          def ar = (vars.APPLIED_REFUSAL ?: '').toString()
          env.APPLIED_REFUSAL = (ar ==~ /[A-Z][A-Z0-9_]{2,40}/) ? ar : ''
          // A5 — la PHRASE du refus de l'aval (garde A3 ou rôle), sous classe, avec son tag seulement.
          def ad = (vars.APPLIED_REFUSAL_DETAIL ?: '').toString()
          env.APPLIED_REFUSAL_DETAIL = (env.APPLIED_REFUSAL && ad ==~ /[^\r\n]{1,300}/) ? ad : ''
          …
          } else if (env.APPLY_RESULT != 'SUCCESS' && env.APPLIED_REFUSAL) {
            env.REFUSAL        = env.APPLIED_REFUSAL
            env.REFUSAL_DETAIL = env.APPLIED_REFUSAL_DETAIL ? "aval ${env.APPLY_BUILD} : ${env.APPLIED_REFUSAL_DETAIL}" : "refus de la garde du palier dans l'aval ${env.APPLY_BUILD} — voir sa console (rien n'a été écrit sur la gateway)"
          }
```

- [ ] **Step 7 : vert** — les deux suites (38/38, 177/177) ; `ci/lint-jenkinsfiles.sh` (compilation) ; régressions `test-provision-apply-a4.sh` 133, `test-provision-apply-wiring.sh` 142, `test-a0-wiring.sh` 176, `test-provision-apply-a2.sh` 148.

- [ ] **Step 8 : commit** — `git commit -am "feat(cd-apps): A5 — le relais tag+phrase : Jenkinsfile.selfservice (deux plays, purges, post{always} APPLIED_REFUSAL_DETAIL), garde A3 REFUS_DETAIL_OUT, provision-apply compose « aval #n : <détail> » ; suites A5 section C 38/38, A3 177/177"`.

---

## T4 — Le rapport de PR : paragraphe « L'ordre app/API » (section D)

**Files:** modify `scripts/provision-apply-comment.sh` (branche `elif refusal:`), modify `scripts/test-selfservice-api-gate-a5.sh` (section D ; `EXPECTED_CHECKS`).

- [ ] **Step 1 : section D (rouge)** — faux Gitea (copie du `fakegitea.py` de `test-pr-comment.sh`, lignes 30-66, verbatim) puis :

```bash
echo
echo "══ D. le rapport de PR ══"
GPORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
printf '[]' > "$TMP/comments.json"
STORE="$TMP/comments.json" EXPECT_TOKEN=tok-ok python3 "$TMP/fakegitea.py" "$GPORT" >/dev/null 2>&1 &
PIDS="$PIDS $!"; for _ in $(seq 1 40); do curl -s -o /dev/null "http://127.0.0.1:$GPORT/" 2>/dev/null && break; sleep 0.1; done
GH="http://127.0.0.1:$GPORT"
bodies(){ python3 -c 'import json,sys;print("\n".join(c["body"] for c in json.load(open(sys.argv[1]))))' "$TMP/comments.json"; }
report(){ # <REFUSAL> <REFUSAL_DETAIL> → $TMP/d.out
  printf '[]' > "$TMP/comments.json"
  ( cd "$REPO" && PR_NUMBER=7 APPLY_RESULT=FAILURE APP_NAME=a5app ENV_NAME=rec VALIDATOR=alice REFUSAL="$1" REFUSAL_DETAIL="$2" \
      GIT_REPO=ci/stoa-labs GITEA_TOKEN=tok-ok GIT_HOST="$GH" bash scripts/provision-apply-comment.sh ) > "$TMP/d.out" 2>&1; echo $? > "$TMP/d.rc"
}
report API_NOT_PROMOTED "l'API 'demo-selfservice' n'est pas au palier 'rec' — promouvoir l'API vers rec (PR promote/demo-selfservice-rec, G5) puis rejouer l'apply ; rien n'a été écrit"
bodies > "$TMP/d.body"
[ "$(cat "$TMP/d.rc")" = 0 ] && grep -q 'API_NOT_PROMOTED' "$TMP/d.body" && grep -q "L'ordre app/API" "$TMP/d.body" && grep -q 'promote/<api>-rec' "$TMP/d.body" && grep -q 'promote/demo-selfservice-rec' "$TMP/d.body" && grep -q 'rejouer ce webhook' "$TMP/d.body" \
  && ok "D.1 API_NOT_PROMOTED : tag, détail (promote/demo-selfservice-rec), paragraphe « L'ordre app/API » avec le remède" || bad "D.1 rc $(cat "$TMP/d.rc") : $(tr '\n' ' ' < "$TMP/d.body" | cut -c1-400)"
report PALIER_FERME "lecture de envs/int/wm-admin refusée (HTTP 403)"
bodies > "$TMP/d.body"
grep -q 'PALIER_FERME' "$TMP/d.body" && grep -q 'envs/int/wm-admin' "$TMP/d.body" && ! grep -q "L'ordre app/API" "$TMP/d.body" && ok "D.2 PALIER_FERME : la phrase de la garde sur la PR, PAS le paragraphe A5" || bad "D.2 : $(tr '\n' ' ' < "$TMP/d.body" | cut -c1-300)"
report SUBSCRIPTION_UNCONFIRMED "consumingAPIs=['x']"
bodies > "$TMP/d.body"
grep -q "la convergence a eu lieu" "$TMP/d.body" && ! grep -q "rien n'a été écrit sur la gateway, cette PR" "$TMP/d.body" && ok "D.3 SUBSCRIPTION_UNCONFIRMED : variante « la convergence a eu lieu » (jamais « rien n'a été écrit »)" || bad "D.3 : $(tr '\n' ' ' < "$TMP/d.body" | cut -c1-300)"
report API_INACTIVE "$(printf 'x [lien](http://e) `code` *gras*\nseconde ligne')"
bodies > "$TMP/d.body"
grep -q 'API_INACTIVE' "$TMP/d.body" && ! grep -q '\[lien\]' "$TMP/d.body" && ! grep -q '\*gras\*' "$TMP/d.body" && [ "$(grep -c 'seconde ligne' "$TMP/d.body")" = 1 ] && ok "D.4 détail hostile nettoyé (markdown inerte, une ligne)" || bad "D.4 : $(tr '\n' ' ' < "$TMP/d.body" | cut -c1-300)"
```
`EXPECTED_CHECKS=42`.

- [ ] **Step 2 : rouge** (D.1, D.3).

- [ ] **Step 3 : le script** — dans `provision-apply-comment.sh`, remplacer la branche `elif refusal:` :

```python
elif refusal:
    lines.append(f"**L'application n'est PAS déployée.** Refus `{refusal}`"
                 + (f" : `{detail}`" if detail else "") + ".")
    env_name = clean(os.environ["ENV_NAME"], 40)
    # A5 — L'ORDRE APP/API : le remède est nommé, et il n'est pas « rouvrir une demande ».
    if refusal in ("API_NOT_PROMOTED", "API_VERSION_MISMATCH", "API_INACTIVE", "API_AMBIGUE"):
        lines.append(f"**L'ordre app/API** (A5) : une application ne précède jamais son API au palier. "
                     f"Promouvoir l'API vers `{env_name}` par la chaîne des APIs (`api-promote-request` → PR `promote/<api>-{env_name}` → merge → `team-promote`), "
                     "ou l'activer au palier, puis **rejouer ce webhook** : rien n'a été écrit sur la gateway, cette PR reste la référence — "
                     "inutile de rouvrir une demande.")
    elif refusal in ("API_AT_PALIER_UNCONFIRMED", "SUBSCRIPTION_UNCONFIRMED"):
        lines.append(f"**L'ordre app/API** (A5, au `verify`) : la convergence a eu lieu, mais la relecture ne confirme pas l'API au palier `{env_name}` "
                     "ou la souscription au GUID attendu — l'API a bougé entre l'apply et sa relecture (désactivée, remplacée). "
                     "Rétablir l'API au palier puis **rejouer ce webhook** ; l'état de la gateway est à vérifier avant tout trafic.")
    else:
        lines.append("Le merge a eu lieu, l'apply non — corriger puis relancer l'apply ; inutile de rouvrir une demande.")
```

- [ ] **Step 4 : vert** — 42/42 ; `bash scripts/test-pr-comment.sh` 41/41 ; `bash scripts/test-provision-apply-a4.sh` 133 (section D du rapport).

- [ ] **Step 5 : commit** — `git commit -am "feat(cd-apps): A5 — le rapport de PR nomme le remède (« L'ordre app/API » : promouvoir/activer puis rejouer ce webhook ; variante verify) ; section D 42/42"`.

---

## T5 — Le prototype Python porte la même porte (section E) + spike réaligné

**Files:** modify `scripts/apply-selfservice-application.py` (résolution), modify `scripts/spike-cd-applications.py` (S2-T3), modify `scripts/test-selfservice-api-gate-a5.sh` (section E ; `EXPECTED_CHECKS`).

- [ ] **Step 1 : section E (rouge)** :

```bash
echo
echo "══ E. le prototype Python (spec du fold-in) contre le stub ══"
ENG="$REPO/scripts/apply-selfservice-application.py"
run_eng(){ # <ctl> <manifest json> → $TMP/e.rc $TMP/e.out
  printf '%s\n' "$1" > "$STUB_CTL"; : > "$STUB_LOG"; printf '%s' "$2" > "$TMP/e.json"
  ( WM_ADMIN_URL="$GW" WM_USER=Administrator WM_PASS=manage python3 "$ENG" "$TMP/e.json" ) > "$TMP/e.out" 2>&1; echo $? > "$TMP/e.rc"
}
run_eng "$CTL_ABSENT" '{"name":"a5app","api":"demo-selfservice","api_version":"1.0.0"}'
[ "$(cat "$TMP/e.rc")" = 1 ] && grep -q '^REFUS: API_NOT_PROMOTED' "$TMP/e.out" && [ "$(writes)" = 0 ] && ok "E.1 prototype : nom absent ⇒ rc 1, REFUS: API_NOT_PROMOTED, aucune écriture" || bad "E.1 rc $(cat "$TMP/e.rc") writes=$(writes) : $(tail -1 "$TMP/e.out")"
run_eng "$CTL_INACTIVE" '{"name":"a5app","api":"demo-selfservice","api_version":"1.0.0"}'
[ "$(cat "$TMP/e.rc")" = 1 ] && grep -q '^REFUS: API_INACTIVE' "$TMP/e.out" && [ "$(writes)" = 0 ] && ok "E.2 prototype : inactive ⇒ REFUS: API_INACTIVE, aucune écriture (la dette du spike est fermée)" || bad "E.2 rc $(cat "$TMP/e.rc") writes=$(writes) : $(tail -1 "$TMP/e.out")"
run_eng "$CTL_OTHER_VERSION" '{"name":"a5app","api":"demo-selfservice","api_version":"2.0.0"}'
[ "$(cat "$TMP/e.rc")" = 1 ] && grep -q '^REFUS: API_VERSION_MISMATCH' "$TMP/e.out" && grep -q '1.0.0' "$TMP/e.out" && ok "E.3 prototype : version absente ⇒ API_VERSION_MISMATCH citant 1.0.0" || bad "E.3 : $(tail -1 "$TMP/e.out")"
run_eng "$CTL_ACTIVE" '{"name":"a5app","api":"demo-selfservice","api_version":"1.0.0"}'
grep -q "^POST .*/applications$" "$STUB_LOG" && ok "E.4 prototype : active ⇒ la porte laisse passer (POST /applications atteint le canari)" || bad "E.4 aucun POST : $(tail -2 "$TMP/e.out" | tr '\n' ' ')"
run_eng "$CTL_ACTIVE" '{"name":"a5app","api":"demo-selfservice"}'
[ "$(cat "$TMP/e.rc")" != 0 ] && grep -q 'CABLAGE_INCOMPLET' "$TMP/e.out" && [ "$(writes)" = 0 ] && ok "E.5 prototype : api_version absent ⇒ CABLAGE_INCOMPLET (la résolution par nom seul n'est plus admise)" || bad "E.5 rc $(cat "$TMP/e.rc") : $(tail -1 "$TMP/e.out")"
SPIKE="$REPO/scripts/spike-cd-applications.py"
grep -q "API_INACTIVE" "$SPIKE" && ! grep -q 'compare apiName SEUL' "$SPIKE" && ok "E.6 le spike attend désormais le refus (S2-T3 réaligné : il reste rejouable et dit l'état vrai)" || bad "E.6 spike non réaligné"
```
`EXPECTED_CHECKS=48`.

- [ ] **Step 2 : rouge.**

- [ ] **Step 3 : le prototype** — remplacer le bloc « résoudre l'API publiée » :

```python
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
```
Et dans le docstring : « Usage : … le manifeste porte `api_version` (obligatoire depuis A5) ».

- [ ] **Step 4 : le spike S2-T3** — ajouter `"api_version"` aux deux manifestes JSON (relire la version que le spike donne à `spikecd-api`/`spikecd-inactive` à leur création : `grep -n 'apiVersion' scripts/spike-cd-applications.py`), et remplacer les deux `check`/`mes` de lecture par :

```python
        check("S2-T3 moteur : API inactive ⇒ refus fermé API_INACTIVE (porte A5, 2026-09-03)", p.returncode != 0 and "REFUS: API_INACTIVE" in p.stdout)
        src = open(eng, encoding="utf-8").read()
        check("S2-T3 (lecture) la résolution du moteur compare nom + version + isActive (porte A5)",
              'is not True' in src and "API_VERSION_MISMATCH" in src and "API_NOT_PROMOTED" in src)
```
(La `mes("S2-T3 VERDICT moteur", …)` reste, son texte devient « refuse une API inactive (porte A5) » dans les deux branches.) Ne PAS rejouer le spike entier (S1-T3 brûle des paires) : la porte E couvre le moteur.

- [ ] **Step 5 : vert** — 48/48 ; `python3 -m py_compile scripts/apply-selfservice-application.py scripts/spike-cd-applications.py`.

- [ ] **Step 6 : commit** — `git commit -am "feat(cd-apps): A5 — le prototype Python porte la même porte (nom+version+isActive, mêmes tags, exit 1 avant tout POST) ; spike S2-T3 réaligné ; section E 48/48"`.

---

## T6 — `make lint-ci` [14/14] + régressions complètes

**Files:** modify `Makefile`.

- [ ] **Step 1** : `[N/13]` ⇒ `[N/14]` (les 13 échos), ajouter `scripts/test-selfservice-api-gate-a5.sh scripts/test-a5-live.sh` à la liste shellcheck (le second sera créé en T7 : l'ajouter en T7), l'écho `[2/14] … A4, A5)`, et en fin :

```make
	@# A5 (CD des applications) : l'ordre app/API — la porte du rôle contre un
	@# stub (journal, quatre refus AVANT la première écriture, 3 mutations),
	@# verify contre le mock Go, le câblage du relais tag+phrase, le rapport,
	@# le prototype. La preuve par builds réels (test-a5-live.sh) se rend à la main.
	@echo "== [14/14] épreuves de l'ordre app/API — porte du rôle, verify, relais, rapport, prototype (A5)"
	@bash scripts/test-selfservice-api-gate-a5.sh
```

- [ ] **Step 2** : `make lint-ci > /tmp/a5-lint.out 2>&1; echo rc=$?; grep -E '^== |RÉSULTAT|✓' /tmp/a5-lint.out | tail -20` ⇒ rc 0, `[14/14]`. Shellcheck propre (sinon corriger la suite, jamais désactiver un code sans motif écrit).

- [ ] **Step 3 : toutes les suites voisines** (les totaux de T0, inchangés sauf A3 177) + `bash scripts/test-backend-key.sh`, `bash scripts/test-cert-rotation.sh` (rôle).

- [ ] **Step 4 : commit** — `git commit -am "ci(lint-ci): [14/14] — épreuves A5 (porte du rôle, verify, relais, rapport, prototype) + shellcheck"`.

---

## T7 — La preuve par builds réels : `scripts/test-a5-live.sh`

**Files:** create `scripts/test-a5-live.sh` (motif `test-a4-live.sh` : en-tête, préconditions, helpers Gitea/Jenkins/gateway copiés verbatim des lignes 60-300 SAUF LDAP/ITSM, inutiles ici), modify `Makefile` (shellcheck).

- [ ] **Step 1 : écrire la suite** — squelette = `test-a4-live.sh` lignes 1-300 (helpers) sans `ldap_*`, `restore_ldap`, `ITSM_*`, `BIND_*`, `ensure_human carol`, puis :

```bash
APP1="a5p$TS"; APP3="a5n$TS"; APP4="a5v$TS"; NOPE="a5nope$TS"
GUID_REF=""; DEACTIVATED=0
api_id_of(){ gw "$GW_ADMIN/apis" | A="$1" V="$2" python3 -c "import json,os,sys
d=json.load(sys.stdin)
for i in d.get('apiResponse',[]):
    a=i.get('api',i)
    if a.get('apiName')==os.environ['A'] and a.get('apiVersion')==os.environ['V']: print(a.get('id')); break"; }
api_active(){ gw "$GW_ADMIN/apis/$1" | jq_ "print(d['apiResponse']['api'].get('isActive'))"; }
api_switch(){ # <id> <activate|deactivate> → attend la gateway (keepalive) et relit
  local dl=$(( $(date +%s) + 240 )) hc
  while :; do hc=$(gw -X PUT -o /dev/null -w '%{http_code}' "$GW_ADMIN/apis/$1/$2" || true); [ "$hc" = 200 ] && break; [ "$(date +%s)" -lt "$dl" ] || return 1; sleep 10; done
  sleep 2; case "$2:$(api_active "$1")" in activate:True|deactivate:False) return 0;; *) return 1;; esac
}
reactivate(){ [ "$DEACTIVATED" -eq 1 ] || return 0; api_switch "$GUID_REF" activate && { DEACTIVATED=0; echo "  API $REQ_API réactivée (isActive=True relu)"; } || echo "  ⚠ API $REQ_API NON réactivée — PUT $GW_ADMIN/apis/$GUID_REF/activate à la main" >&2; }
```
Le `cleanup` de A4 adapté : `reactivate` en tête (AVANT tout), puis PR fermées, branches `provision/<app>-rec` ×3 supprimées, manifestes ×3 retirés de main, applications ×3 supprimées de la gateway (best-effort). `request_branch` prend `<app> <env> <api> <ver> <ip>` (cinq arguments — REQ_APP/REQ_API/REQ_API_VER ne sont plus des globales). `fire_webhook` copié de `test-provision-apply-a2-live.sh:377-390` ; `replay_pr <pr> <branche> <merge_sha>` construit le payload Gitea (`action: closed, merged: true, merged_by alice, user ci, head.ref, number, merge_commit_sha`) comme `test-provision-apply-a2-live.sh:366-370`.

Préconditions 0.1-0.6 (A4 verbatim, moins LDAP/ITSM) + :
```bash
for f in ansible/roles/apim_common/tasks/refus.yml; do gapi -o /dev/null -w '%{http_code}' "$API/repos/$GIT_REPO/raw/main/$SUBDIR/$f" | grep -q '^200$' || die "PREREQUIS : $f absent de gitea main — git push gitea HEAD:main"; done
raw_at main "$SUBDIR/ansible/roles/apim_selfservice_app/tasks/main.yml" | grep -q 'API_INACTIVE' || die "PREREQUIS : le rôle sur gitea main n'a pas la porte A5"
raw_at main "$SUBDIR/ci/Jenkinsfile.selfservice" | grep -q 'apim_ss_refus_detail_out' || die "PREREQUIS : Jenkinsfile.selfservice sur gitea main n'est pas la version A5"
raw_at main "$SUBDIR/ci/Jenkinsfile.provision-apply" | grep -q 'APPLIED_REFUSAL_DETAIL' || die "PREREQUIS : Jenkinsfile.provision-apply sur gitea main n'est pas la version A5"
ok "0.3 A5 est sur gitea main (rôle, lib de refus, deux Jenkinsfile)"
GUID_REF=$(api_id_of "$REQ_API" "$REQ_API_VER"); [ -n "$GUID_REF" ] && [ "$(api_active "$GUID_REF")" = True ] && ok "0.7 API $REQ_API@$REQ_API_VER active — GUID_REF=$GUID_REF" || die "PREREQUIS : $REQ_API@$REQ_API_VER absente/inactive"
[ -z "$(api_id_of "$NOPE" 1.0.0)" ] && ok "0.7b aucune API $NOPE (le nom absent du scénario 3)" || die "PREREQUIS : $NOPE existe"
[ -z "$(api_id_of "$REQ_API" 9.9.9)" ] && ok "0.7c aucune $REQ_API@9.9.9 (la version absente du scénario 4)" || die "PREREQUIS : 9.9.9 existe"
for a in "$APP1" "$APP3" "$APP4"; do [ -z "$(gw_app "$a")" ] || die "PREREQUIS : application $a déjà présente"; done; ok "0.8 aucune application homonyme"
N_INACTIVE=$(gw "$GW_ADMIN/apis" | jq_ "print(sum(1 for i in d.get('apiResponse',[]) if i.get('api',i).get('isActive') is False))"); echo "  (mesure : $N_INACTIVE API(s) inactive(s) sur la gateway)"
```
Scénarios (chaque `chain_rec <app> <api> <ver> <ip>` = request_branch → merge_as_alice → wait_amont PAUSE → answer_pause → finish_amont ; globales `RES`, `S_NUM`, `N_PA`, `PR_N`, `BR_N`, `MS_N`) :

```bash
echo; echo "═══ 1. CONTRE-ÉPREUVE — API présente mais INACTIVE en rec ⇒ API_INACTIVE, rien écrit ═══"
DEACTIVATED=1; api_switch "$GUID_REF" deactivate && ok "1.0 $REQ_API désactivée (isActive=False relu) — trap de réactivation armé" || die "PREREQUIS : désactivation refusée"
chain_rec "$APP1" "$REQ_API" "$REQ_API_VER" 10.42.0.1; PR1="$PR_N"; BR1="$BR_N"; MS1="$MS_N"
[ "$RES" = FAILURE ] && ok "1.1 provision-apply #$N_PA : FAILURE (l'aval a refusé)" || ko "1.1 provision-apply #$N_PA : $RES"
grep -qF 'REFUS: API_INACTIVE' "$TMP/ss.$S_NUM.console" && grep -q "isActive=False" "$TMP/ss.$S_NUM.console" && ok "1.2 aval #$S_NUM : REFUS: API_INACTIVE (isActive=False, id cité)" || ko "1.2 aval : $(grep -E 'REFUS|fatal' "$TMP/ss.$S_NUM.console" | head -2 | tr '\n' ' ' | cut -c1-300)"
console_order "$TMP/ss.$S_NUM.console" 'palier ouvert : envs/rec/wm-admin' 'préflight de joignabilité :' 'PLAY [Self-service application — converge' 'REFUS: API_INACTIVE' && ok "1.3 ORDRE : ticket < préflight < converge < REFUS (la porte est DANS le rôle, après le credential du palier)" || ko "1.3 ordre inattendu"
! grep -q 'App : créer si absente' "$TMP/ss.$S_NUM.console" && ! grep -q 'PLAY \[Self-service application — verify' "$TMP/ss.$S_NUM.console" && ok "1.4 aucune tâche d'écriture atteinte, aucun verify" || ko "1.4 le rôle est allé plus loin que la porte"
[ -z "$(gw_app "$APP1")" ] && ok "1.5 gateway : $APP1 ABSENTE — rien écrit" || ko "1.5 gateway : $APP1 existe"
grep -q "refus relayé à l'amont : API_INACTIVE — " "$TMP/ss.$S_NUM.console" && ok "1.6 post{always} de l'aval : tag ET phrase relayés" || ko "1.6 relais : $(grep 'refus relayé' "$TMP/ss.$S_NUM.console" | head -1)"
CM=$(pr_comments "$PR1"); printf '%s' "$CM" | grep -q 'API_INACTIVE' && printf '%s' "$CM" | grep -q "$REQ_API" && printf '%s' "$CM" | grep -q "L'ordre app/API" && printf '%s' "$CM" | grep -q "aval selfservice-app-deploy #$S_NUM" \
  && ok "1.7 PR #$PR1 : ❌ API_INACTIVE, la phrase nomme $REQ_API, paragraphe « L'ordre app/API », aval #$S_NUM cité" || ko "1.7 commentaire : $(printf '%s' "$CM" | grep -i 'refus' | head -2 | tr '\n' ' ' | cut -c1-300)"

echo; echo "═══ 2. PORTE — « promotion » (réactivation) puis REJEU du même webhook ⇒ créée, souscrite au MÊME GUID ═══"
api_switch "$GUID_REF" activate && DEACTIVATED=0 && ok "2.0 $REQ_API réactivée (isActive=True relu) — même objet, même GUID $GUID_REF" || die "PREREQUIS : réactivation refusée"
replay_pr "$PR1" "$BR1" "$MS1"      # pose N_PA ; PAUSE attendue
wait_amont "$N_PA" PAUSE; answer_pause "$N_PA"; finish_amont "$N_PA"
[ "$RES" = SUCCESS ] && [ "$(jresult selfservice-app-deploy "$S_NUM")" = SUCCESS ] && ok "2.1 rejeu : provision-apply #$N_PA SUCCESS, aval #$S_NUM SUCCESS" || ko "2.1 $RES / $(jresult selfservice-app-deploy "${S_NUM:-0}")"
grep -q "API_AT_PALIER : '$REQ_API' v$REQ_API_VER active au palier 'rec' (id=$GUID_REF)" "$TMP/ss.$S_NUM.console" && ok "2.2 converge : API_AT_PALIER avec GUID_REF" || ko "2.2 marqueur absent"
grep -q "API_AT_PALIER_CONFIRMED" "$TMP/ss.$S_NUM.console" && grep -q "SUBSCRIPTION_CONFIRMED : '$APP1' souscrite à '$REQ_API' v$REQ_API_VER (id=$GUID_REF)" "$TMP/ss.$S_NUM.console" && ok "2.3 verify : API_AT_PALIER_CONFIRMED + SUBSCRIPTION_CONFIRMED au GUID $GUID_REF" || ko "2.3 verify : $(grep -E 'CONFIRMED|REFUS' "$TMP/ss.$S_NUM.console" | tr '\n' ' ' | cut -c1-300)"
APPJ=$(gw_app "$APP1"); printf '%s' "$APPJ" | grep -q "$GUID_REF" && printf '%s' "$APPJ" | grep -q "${APP1}-rec" && ok "2.4 gateway : $APP1 présente, consumingAPIs ∋ $GUID_REF (le GUID promu, le même), claim ${APP1}-rec" || ko "2.4 gateway : $(printf '%s' "$APPJ" | cut -c1-200)"
CM=$(pr_comments "$PR1"); printf '%s' "$CM" | grep -q 'Apply nominatif RÉUSSI' && ok "2.5 PR #$PR1 : ✅ (le rejeu a remplacé le refus)" || ko "2.5 commentaire : $(printf '%s' "$CM" | tail -c 200)"

echo; echo "═══ 3. API JAMAIS promue (nom absent) ⇒ API_NOT_PROMOTED, la PR nomme promote/<api>-rec ═══"
chain_rec "$APP3" "$NOPE" 1.0.0 10.42.0.3; PR3="$PR_N"
[ "$RES" = FAILURE ] && grep -qF 'REFUS: API_NOT_PROMOTED' "$TMP/ss.$S_NUM.console" && ok "3.1 aval #$S_NUM : REFUS: API_NOT_PROMOTED" || ko "3.1 $RES : $(grep -E 'REFUS|fatal' "$TMP/ss.$S_NUM.console" | head -2 | tr '\n' ' ' | cut -c1-300)"
[ -z "$(gw_app "$APP3")" ] && ok "3.2 gateway : $APP3 absente — rien écrit" || ko "3.2 $APP3 existe"
CM=$(pr_comments "$PR3"); printf '%s' "$CM" | grep -q 'API_NOT_PROMOTED' && printf '%s' "$CM" | grep -q "promote/$NOPE-rec" && ok "3.3 PR #$PR3 : ❌ API_NOT_PROMOTED nommant promote/$NOPE-rec" || ko "3.3 : $(printf '%s' "$CM" | grep -i refus | head -1 | cut -c1-300)"

echo; echo "═══ 4. version ABSENTE (9.9.9) ⇒ API_VERSION_MISMATCH citant 1.0.0 ═══"
chain_rec "$APP4" "$REQ_API" 9.9.9 10.42.0.4; PR4="$PR_N"
[ "$RES" = FAILURE ] && grep -qF 'REFUS: API_VERSION_MISMATCH' "$TMP/ss.$S_NUM.console" && grep -q "version(s) .*$REQ_API_VER" "$TMP/ss.$S_NUM.console" && ok "4.1 aval #$S_NUM : REFUS: API_VERSION_MISMATCH citant $REQ_API_VER" || ko "4.1 $RES : $(grep -E 'REFUS|fatal' "$TMP/ss.$S_NUM.console" | head -2 | tr '\n' ' ' | cut -c1-300)"
[ -z "$(gw_app "$APP4")" ] && ok "4.2 gateway : $APP4 absente" || ko "4.2 $APP4 existe"
CM=$(pr_comments "$PR4"); printf '%s' "$CM" | grep -q 'API_VERSION_MISMATCH' && ok "4.3 PR #$PR4 : ❌ API_VERSION_MISMATCH" || ko "4.3 : $(printf '%s' "$CM" | tail -c 200)"
```

- [ ] **Step 2 : shellcheck** — `shellcheck -x scripts/test-a5-live.sh` propre ; ajouter au Makefile.

- [ ] **Step 3 : pousser gitea** — `git pull --rebase gitea main` (la forge ajoute des commits d'artefacts) puis `git push gitea HEAD:main` ; vérifier `git log gitea/main --oneline -3`.

- [ ] **Step 4 : jouer** — `JENKINS_UI=http://localhost:18080 GITEA_URL=http://localhost:13000 GW_ADMIN=http://localhost:5555/rest/apigateway WM_USER=Administrator WM_PASS=manage bash scripts/test-a5-live.sh 2>&1 | tee /tmp/a5-live.out` (≈ 25 min ; lancer juste après un cycle keepalive : `docker inspect poc-webmethods-real --format '{{.State.StartedAt}}'`). Chaque défaut de HARNAIS mesuré ⇒ correction + commit nommant la mesure (D10 d'A4) ; chaque défaut de CHAÎNE ⇒ retour à la suite hors ligne d'abord (rouge → vert), push gitea, rejeu.

- [ ] **Step 5 : régression live** — `bash scripts/test-a3-live.sh` (54/54 attendu ; le Jenkinsfile a changé).

- [ ] **Step 6 : commit** — `git add scripts/test-a5-live.sh Makefile && git commit -m "test(a5-live): la porte et les contre-épreuves d'A5 par builds réels — API_INACTIVE (rien écrit, PR nommée), rejeu après réactivation (souscrite au même GUID), API_NOT_PROMOTED, API_VERSION_MISMATCH"` puis, si des commits de correction ont eu lieu, `git push gitea HEAD:main` à nouveau.

---

## T8 — Docs, ADR-088, GOAL, mémoire

**Files:** create `adr/adr-088-ordre-app-api.md`, modify `ENVIRONNEMENTS.md` (section « L'ordre app/API (A5 …) » insérée AVANT `## Tout en Jenkinsfile (A0`), `GOAL-cd-applications-2026-09-02.md` (ligne `status`, blockquote « LIVRÉ » sous `### A5`), spec/plan (`status`), mémoire (`a5-ordre-app-api.md`, `cd-applications-goal.md`, `MEMORY.md`).

- [ ] **Step 1 : ADR-088** (front-matter comme ADR-087 : `title`, `sidebar_label`, `status`, `maturite_technique`, `date`, `adr_number: 88`, `note`, `lié`) — Contexte (le spike S2 : la gateway et le moteur ne gardent pas la porte, la paire brûlée) ; Décision (D0 le site, D1 le prédicat et ses quatre tags, D2 le relais, D3 verify) ; Ce qui est prouvé (les comptes) ; Limites (D7 lignée, D8) ; Conséquences (A6 hérite, A7 hérite) ; Résiduel (les autres gardes non relayées, le plan ne sait pas).
- [ ] **Step 2 : `ENVIRONNEMENTS.md`** — section opérateur : ce que le demandeur voit sur la PR, le remède (promouvoir par la chaîne des APIs, ou activer), le rejeu du webhook, les marqueurs de console, la limite mono-gateway, la lignée du rôle.
- [ ] **Step 3 : GOAL** — `status` : ajouter `**A5 LIVRÉ le 2026-09-03 (…)**` avec les comptes ; blockquote sous `### A5` (motif A4).
- [ ] **Step 4 : spec/plan `status`** : « LIVRÉ 2026-09-03 — … ».
- [ ] **Step 5 : mémoire** — `a5-ordre-app-api.md` (type project : le site, les tags, le relais, les comptes, les pièges mesurés en live), mise à jour de `cd-applications-goal.md` (A5 LIVRÉ, prochain = A6), ligne dans `MEMORY.md`.
- [ ] **Step 6 : commit + push gitea** — `git commit -am "docs(cd-apps): A5 LIVRÉ — ADR-088 (l'ordre app/API), ENVIRONNEMENTS.md, GOAL, statuts spec/plan"` ; `git pull --rebase gitea main && git push gitea HEAD:main`.

---

## Auto-revue du plan (faite à l'écriture)

- Couverture de la spec : D0/D1 → T1 ; D2 → T1 (refus.yml) + T3 ; D3 → T2 ; D4 → T5 ; D5 → T1..T5 (sections A..E, F dans A3) + T6 ; D6 → T7 ; D7 → T7 step 3 + T8 ; D8 → T8. Hypothèses 1-6 → spec, reprises dans l'ADR.
- Cohérence des noms : `apim_ss_refus_out` / `apim_ss_refus_detail_out` (rôle, Jenkinsfile), `REFUS_DETAIL_OUT` (garde), `.a3-refus` / `.a3-refus-detail` (fichiers), `APPLIED_REFUSAL_DETAIL` (Groovy ×2), `ss_api_refus` / `ss_api_match` / `ss_api_by_name` / `ss_api_env` (rôle), `v_api_match` / `v_app_apis` / `v_env` (verify), marqueurs `API_AT_PALIER :`, `API_AT_PALIER_CONFIRMED`, `SUBSCRIPTION_CONFIRMED`, `# ── A5 porte : début/fin`.
- Totaux : suite A5 23 → 29 → 38 → 42 → 48 ; A3 174 → 177 ; lint-ci 13 → 14.
