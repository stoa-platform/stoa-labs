---
title: "Plan — A6, le repli d'une application est une PR"
type: plan
status: "EN COURS 2026-09-03 — T0..T7 inline, TDD (chaque section vue rouge avant le code)"
date: 2026-09-03
spec: docs/superpowers/specs/2026-09-03-a6-repli-par-pr-design.md
---

# A6 — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline, un seul écrivain — le mode de défaillance « narration prématurée » des sous-agents est mesuré et cher, mémoire g2-axe-qui-deploie). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** un opérateur replie une application à un palier par un formulaire Jenkins qui ouvre une **PR de repli** `provision/<app>-<env>` — ligne `per_env.<env>` et cert du palier restaurés à l'octet du merge précédent (N-1), `change_ref` remplacé si la porte l'exige — et la chaîne existante l'applique comme tout apply (mêmes portes, même rôle, même GUID, même clé) ; preuves hors ligne (fixture git + stub forge à journal + shim git + 5 mutations) et par builds réels.

**Architecture:** `scripts/app-rollback-request.sh` (nouveau, frère de `provision-request.sh`) : forme → chaîne épinglée → porte (`GATE_REFS_REQUIRED` avant tout clone) → clone avec historique → manifeste + `BIRTH` → lignée (forge paginée, ordonnée par `git rev-list --first-parent`, bornée à `BIRTH`) → cohérence → ligne candidate en mémoire → `ETAT_IDENTIQUE` → restauration → auto-vérification → PR ouverte / `EXIST` strict → tête distante en bail → commit (trailers) + `push --force-with-lease` (`GIT_ASKPASS`) + `POST /pulls` + plan enchaîné. `ci/Jenkinsfile.app-rollback` (formulaire `properties()`) + coquille XML. Deux gardes de fenêtre : `REPLI_EN_COURS` dans `provision-request.sh` (amont, avant son push) et `REPLI_PERIME` dans `provision-apply-reconcile.sh` (aval, conditionnel au trailer `Repli-De`).

**Tech Stack:** bash 3.2 (poste) / dash-compatible via `bash` explicite (agent), python3 + PyYAML (`BaseLoader`), git ≥ 2.30 (`--filter=blob:none`, `--force-with-lease=<ref>:<sha>`), curl, Jenkins 2.541 déclaratif from SCM, Gitea 1.22 (API `pulls` paginée), wM 10.15 réelle (lab), openssl.

**Spec:** `docs/superpowers/specs/2026-09-03-a6-repli-par-pr-design.md`

## Global Constraints (copiées de la spec)

- **Aucun `job.xml` porteur de logique** : la coquille `ci/jenkins/app-rollback.job.xml` n'a que le pointeur SCM (`<properties/>`, `<triggers/>` vides) ; le formulaire est posé par `properties([parameters([…])])` depuis le Jenkinsfile (motif A0) ; pose par `JOBS=app-rollback BOOTSTRAP_JOBS=app-rollback scripts/setup-provision-jobs.sh`.
- **Rien n'est poussé avant le dernier refus** : les étapes 1-12bis sont en lecture seule (le clone est dans un `mktemp`) ; chaque étape imprime `ETAPE <nom>` ; les refus sont `REFUS: <TAG> : <phrase>` sur stderr, rc 2.
- **Ordre = propriété** : forme → chaîne → porte (`GATE_REFS_REQUIRED` **avant** `ETAPE clone` et avant tout appel de forge) → clone → manifeste → lignée → cohérence → candidate → identique → restauration → vérification → pr-en-cours → tête distante → commit/push/PR.
- **Lignée** = PR fermées **mergées** (`merged`, `head.ref` == branche exactement, `base.ref` == `GIT_BASE`, même dépôt sinon `LIGNEE_AMBIGUE`), `merge_commit_sha` sur `git rev-list --first-parent GIT_BASE` (sinon `FORGE_INCOHERENTE`), bornée à `BIRTH` (= `git log --first-parent --diff-filter=A -1 -- <manifeste>`) ; N = plus récent, N-1 = précédent ; `AUCUNE_LIGNEE` / `AUCUN_ETAT_PRECEDENT`.
- **Candidate** = mapping de la ligne `per_env.<env>` de N-1 à l'octet ⊕ `change_ref` (remplacé sous ses trois formes scalaires ou inséré avant `}`) ; N-1 avec 2+ `change_ref:` ⇒ `LIGNE_AMBIGUE` ; après édition : exactement une occurrence et mapping relu == mapping(N-1) ⊕ {change_ref} sinon `REF_DUPLIQUEE` ; digest attendu = `app_manifest_digest_env` d'une copie de N-1 où la candidate est fusionnée par la lib.
- **`ETAT_IDENTIQUE`** se décide sur `digest attendu == digest(main)` **et** cert identique (jamais sur la ligne brute de N-1).
- **`EXIST`** seulement si la PR ouverte est d'un login de `GITEA_SERVICE_LOGINS` (défaut `ci`), même dépôt, et contenu identique (digest de sa tête == digest attendu, cert à l'octet) ; sinon `PR_EN_COURS` ; les PR de fork sont ignorées.
- **Tête distante** : absente ou ancêtre de `GIT_BASE` ⇒ bail `--force-with-lease=refs/heads/<b>:<tête>` ; sinon `BRANCHE_NON_MERGEE`. Token par `GIT_ASKPASS`, jamais en URL ni argv.
- **Classes** : `REQ_APP` `^[a-z0-9][a-z0-9-]*$` ; `REQ_ENV` `^[a-z0-9]+$` ; `REQ_REASON` 1-300, sans `\r\n`, `` ` ``, `<`, `>`, `#`, `@`, `[`, `]`, `\` ; `REQ_CHANGE_REF` vide ou `^[A-Za-z0-9][A-Za-z0-9._-]*$` ; `REQ_CALLER` `^[A-Za-z0-9._:@-]+$`.
- **Chaîne épinglée** sur les deux lignes `sh` du Jenkinsfile (`STOA_ENV_CHAIN_FILE="$WORKSPACE/poc-control-plane-federation/clients/_example/environments.yaml"`) ; liste `ENV` = `env_chain` entière.
- **Aval** : un seul ajout, `provision-apply-reconcile.sh` §4bis `REPLI_PERIME`, conditionnel à `Repli-De:` dans le message de `MERGE_SHA^2` ; inerte sinon (diff du script hors bloc == vide).
- **Amont** : `provision-request.sh` gagne `REPLI_EN_COURS` (PR ouverte de service dont la tête porte `Repli-Vers:`, lue par git sur `FETCH_HEAD`) **avant** son push, et son push passe en `--force-with-lease`.
- Suites voisines INCHANGÉES dans leurs assertions (totaux à re-mesurer en T0) : a0 176, wiring 142, a2 148, a4 133, a3 177, a5 48, pr-comment 44, app-request-a1/v2/v3 (sections hors ligne), `make lint-ci` [14/14] → [15/15].
- Pièges bash 3.2 : pas de `mapfile`, pas de `declare -A`, tableaux vides `${A[@]+"${A[@]}"}`, toute sortie capturée dans un fichier AVANT `grep` (jamais `cmd | grep -q` sous pipefail), `case`/`grep -E` plutôt que `[[ =~ ]]` ; `kill` d'un stub suivi de `wait`.
- Lab : identité alice (`deploy-banking-demo apply-dev apply-rec`), palier rec (`selfApproval`), `APPLY_ADMIN_VIA=direct`, gateway réelle, API **jetable** `a6api<ts>` ; manifeste jetable SANS `team:` ni `per_env.dev` ; pousser gitea main AVANT la suite live ; keepalive ~20-25 min.

---

## Carte des fichiers

| Fichier | Rôle | Tâche |
|---|---|---|
| `scripts/app-rollback-request.sh` (créer) | la demande de repli : D1 en 13 étapes | T1 |
| `scripts/test-app-rollback-a6.sh` (créer) | suite hors ligne : fixture git + stub forge à journal + shim git ; A/A' nominal, B refus, B' garde symétrique, B'' `REPLI_PERIME`, C mutations, D câblage | T1, T2, T3, T4, T5 |
| `scripts/provision-request.sh` (modifier, additif avant `[3/4] push`) | `REPLI_EN_COURS` + `--force-with-lease` | T3 |
| `scripts/provision-apply-reconcile.sh` (modifier, bloc §4bis) | `REPLI_PERIME` | T4 |
| `ci/Jenkinsfile.app-rollback` (créer) | formulaire 4 champs, chaîne épinglée, appel du script | T5 |
| `ci/jenkins/app-rollback.job.xml` (créer) | coquille SCM pure | T5 |
| `ci/Jenkinsfile.selfservice` (:194, commentaire), `ENVIRONNEMENTS.md` (:1038-1040) | D8 : le levier n'est pas le repli | T5 |
| `Makefile` (modifier) | `[15/15]`, shellcheck des trois nouveaux scripts | T5 |
| `scripts/test-a6-live.sh` (créer) | preuve par builds réels (D5) | T6 |
| `adr/adr-089-repli-des-applications-par-pr.md` (créer), `ENVIRONNEMENTS.md` (section A6), `GOAL-cd-applications-2026-09-02.md`, `adr/adr-088-ordre-app-api.md` (note :65), `ci/README.md`, spec/plan (statuts), mémoire | docs | T7 |

---

## T0 — Mesurer les totaux AVANT de toucher (aucun code)

- [ ] **Step 1 : totaux des suites voisines**

```bash
cd poc-control-plane-federation
for s in test-a0-wiring test-provision-apply-wiring test-provision-apply-a2 test-provision-apply-a4 test-selfservice-palier-a3 test-selfservice-api-gate-a5 test-pr-comment test-app-request-a1 test-app-request-v2 test-app-request-v3; do
  printf '%s : ' "$s"; bash "scripts/$s.sh" > "/tmp/a6-t0-$s.log" 2>&1; echo "rc=$? $(grep -E 'RÉSULTAT|RESULTAT' "/tmp/a6-t0-$s.log" | tail -1)"
done
make lint-ci > /tmp/a6-t0-lint.log 2>&1; echo "lint-ci rc=$?"; grep -E '^== \[' /tmp/a6-t0-lint.log | tail -1
```
Attendu : a0 176, wiring 142, a2 148, a4 133, a3 177, a5 48, pr-comment 44, app-request-* verts (sections lab « sautées » sans Gitea), lint-ci rc 0 `[14/14]`. Noter les totaux réels dans le journal de plan ; tout écart est un fait à écrire avant de toucher.

- [ ] **Step 2 : git de fixture — vérifier que `--filter=blob:none` sur `file://` marche sur le poste**

```bash
T=$(mktemp -d); git init -q --bare "$T/o.git"; git -C "$T/o.git" config uploadpack.allowFilter true
git init -q "$T/w"; git -C "$T/w" -c user.name=t -c user.email=t@t commit -q --allow-empty -m c0; git -C "$T/w" push -q "$T/o.git" HEAD:main
git clone -q --single-branch --branch main --filter=blob:none "file://$T/o.git" "$T/c" && git -C "$T/c" rev-parse --is-shallow-repository; rm -rf "$T"
```
Attendu : `false` (un clone partiel n'est pas shallow). Si git refuse le filtre sur `file://`, le script garde `--filter=blob:none` (git ignore un filtre non supporté avec un avertissement) et la suite pose `uploadpack.allowFilter` sur le nu.

---

## T1 — `scripts/app-rollback-request.sh` + suite A/A'/B (TDD : la suite d'abord, rouge, puis le script)

**Files:** créer `scripts/test-app-rollback-a6.sh`, créer `scripts/app-rollback-request.sh`.

**Interfaces — Produces:** `app-rollback-request.sh` : entrées env `REQ_APP REQ_ENV REQ_REASON [REQ_CHANGE_REF] [REQ_CALLER] GITEA_TOKEN [GIT_HOST GIT_REPO GIT_BASE GIT_SUBDIR GIT_CLONE_URL GITEA_SERVICE_LOGINS STOA_ENV_CHAIN_FILE PROVISION_PLAN_INLINE ROLLBACK_OUT]` ; stdout `ETAPE <nom>` par étape, `LIGNEE : …`, `REPLI_DU_REPLI : …` (le cas échéant), `PR_URL=<url>`, `REPLI_DE=<sha> REPLI_VERS=<sha> REPLI_DIGEST=<sha256:…>` ; `ROLLBACK_OUT` (si posé) : `PR_URL=… PR_NUMBER=… REPLI_DE=… REPLI_VERS=… REPLI_DIGEST=… REPLI_DU_REPLI=0|1` ; rc 0 (PR créée ou `EXIST`), rc 2 refus nommé, rc 1 erreur technique. Trailers du commit : `Repli-De: <sha> (PR #n)`, `Repli-Vers: <sha> (PR #n)`, `Repli-Motif:`, `Repli-Par:`, `Repli-Digest:`, `Change-Ref:` (si fourni). Marqueur du corps de PR : `<!-- app-rollback: de <sha N> vers <sha N-1> -->`.

- [ ] **Step 1 : le squelette de la suite — fixture git, stub forge, shim git, helpers** (`scripts/test-app-rollback-a6.sh`)

```bash
#!/usr/bin/env bash
# test-app-rollback-a6.sh — LA PORTE HORS LIGNE d'A6 (le repli d'une application est une PR).
# Fixture : un dépôt nu servi en file:// (GIT_BASE=main) construit par de vrais
# `git merge --no-ff` dans l'ordre rec#a, rec#b, dev#c, rec#d, dev#e (le dev#e APRÈS
# le dernier rec fait mordre M1) ; un stub Gitea à JOURNAL (pulls paginées, POST /pulls
# ⇒ 201) ; un shim `git` qui journalise chaque verbe et peut déplacer la branche
# distante entre le bail et le push. Toute sortie va dans un fichier avant grep.
# `A && ok || ko` (SC2015) est l'idiome des scripts de preuve du repo.
# shellcheck disable=SC2015
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; umask 077
PIDS=""
cleanup(){ for p in $PIDS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
command -v python3 >/dev/null || { echo "python3 absent"; exit 2; }
SCRIPT="$REPO/scripts/app-rollback-request.sh"
# shellcheck source=scripts/lib/app-manifest.sh
. "$REPO/scripts/lib/app-manifest.sh" || { echo "lib app-manifest absente"; exit 2; }

# ── la chaîne de test : rec sans porte, int avec requireChangeRef, prod terminus ─
CHAIN="$TMP/chain.yaml"
cat > "$CHAIN" <<'YAML'
environments: [dev, rec, int, prod]
gates:
  - { to: rec, selfApproval: true }
  - { to: int, fourEyes: true, requireChangeRef: true }
  - { to: prod, fourEyes: true, requireChangeRef: true, itsmCheck: true }
YAML
CHAIN_REC_GATED="$TMP/chain-gated.yaml"
sed 's/{ to: rec, selfApproval: true }/{ to: rec, requireChangeRef: true }/' "$CHAIN" > "$CHAIN_REC_GATED"

# ── le stub Gitea : /pulls paginées (closed|open) depuis ctl.json, /pulls/<n>, POST /pulls ⇒ 201, journal ──
STUB_CTL="$TMP/ctl.json"; STUB_LOG="$TMP/http.log"; : > "$STUB_LOG"; STUB_TOKEN="t0k3n-a6"
cat > "$TMP/stub.py" <<'PY'
import json, os, re, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
CTL, LOG, TOKEN = os.environ["STUB_CTL"], os.environ["STUB_LOG"], os.environ["STUB_TOKEN"]
def ctl():
    try: return json.load(open(CTL))
    except Exception: return {}
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, *a): pass
    def _send(self, code, body):
        b = json.dumps(body).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def _route(self, method):
        u = urlparse(self.path); q = parse_qs(u.query); path = u.path
        with open(LOG, "a") as f: f.write("%s %s%s\n" % (method, path, ("?" + u.query) if u.query else ""))
        if self.headers.get("Authorization") != "token " + TOKEN: return self._send(401, {"message": "unauthorized"})
        c = ctl()
        if c.get("down"): return self._send(500, {"message": "boom"})
        m = re.match(r"^/api/v1/repos/[^/]+/[^/]+/pulls$", path)
        if m and method == "GET":
            state = (q.get("state") or ["open"])[0]; page = int((q.get("page") or ["1"])[0]); limit = int((q.get("limit") or ["50"])[0])
            if c.get("raw_list") is not None: return self._send(200, c["raw_list"])
            items = c.get(state, [])
            return self._send(200, items[(page-1)*limit: page*limit])
        m = re.match(r"^/api/v1/repos/[^/]+/[^/]+/pulls/([0-9]+)$", path)
        if m and method == "GET":
            for pr in c.get("closed", []) + c.get("open", []):
                if str(pr.get("number")) == m.group(1): return self._send(200, pr)
            return self._send(404, {"message": "no pr"})
        if m is None and re.match(r"^/api/v1/repos/[^/]+/[^/]+/pulls$", path) and method == "POST":
            n = int(self.headers.get("Content-Length") or 0); body = self.rfile.read(n) if n else b""
            with open(os.environ["STUB_POSTED"], "ab") as f: f.write(body + b"\n")
            return self._send(201, {"number": 900, "html_url": "http://stub/pulls/900"})
        return self._send(404, {"message": "stub: route inconnue " + path})
    def do_GET(self): self._route("GET")
    def do_POST(self): self._route("POST")
    def do_PATCH(self): self._route("PATCH")
srv = ThreadingHTTPServer(("127.0.0.1", 0), H); print(srv.server_address[1], flush=True); srv.serve_forever()
PY
STUB_POSTED="$TMP/posted.jsonl"; : > "$STUB_POSTED"
STUB_CTL="$STUB_CTL" STUB_LOG="$STUB_LOG" STUB_TOKEN="$STUB_TOKEN" STUB_POSTED="$STUB_POSTED" python3 "$TMP/stub.py" > "$TMP/stub.port" 2>"$TMP/stub.err" &
PIDS="$PIDS $!"
for _ in $(seq 1 60); do [ -s "$TMP/stub.port" ] && break; sleep 0.1; done
PORT="$(head -n1 "$TMP/stub.port" 2>/dev/null)"; case "$PORT" in ''|*[!0-9]*) echo "!! stub non démarré : $(cat "$TMP/stub.err")"; exit 2;; esac
GH="http://127.0.0.1:$PORT"

# ── le shim git : journalise le verbe, peut déplacer la branche distante avant un push ──
SHIM="$TMP/shim"; mkdir -p "$SHIM"; SHIM_LOG="$TMP/git.log"; : > "$SHIM_LOG"
REAL_GIT="$(command -v git)"
cat > "$SHIM/git" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SHIM_LOG"
if [ -n "\${SHIM_MOVE_BRANCH:-}" ] && [ "\${1:-}" = push ] || { [ "\${1:-}" = -C ] && [ "\${3:-}" = push ] && [ -n "\${SHIM_MOVE_BRANCH:-}" ]; }; then
  "$REAL_GIT" -C "\$SHIM_ORIGIN" update-ref "refs/heads/\$SHIM_MOVE_REF" "\$SHIM_MOVE_BRANCH"
fi
exec "$REAL_GIT" "\$@"
SH
chmod 700 "$SHIM/git"

# ── la fixture git : nu + clone de construction ──
ORIGIN="$TMP/origin.git"; W="$TMP/w"
git init -q --bare "$ORIGIN" && git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main && git -C "$ORIGIN" config uploadpack.allowFilter true
git init -q "$W" && git -C "$W" checkout -q -b main
gw(){ git -C "$W" -c user.name=t -c user.email=t@t "$@"; }
MAN="clients/provisioned/applications/appa.ansible.yml"; CERT="clients/provisioned/certs/appa-rec.crt"
mkdir -p "$W/clients/provisioned/applications" "$W/clients/provisioned/certs"
printf 'init\n' > "$W/README"; gw add -A; gw commit -qm c0
write_man(){ # <fichier> <ligne dev> <ligne rec>   (racine figée identique partout)
  printf -- '---\napim_ss_app:\n  name: "appa"\n  api: "demo-selfservice"\n  api_version: "1.0.0"\n  description: "fixture A6"\n  contact_emails: []\n  enforce: []\n  auth:\n    mode: "idp"\n    server_alias: "KeycloakStoaLab"\n    audience: "demo-selfservice"\n    claim: { name: "azp" }\n  per_env:\n%s%s' "$2" "$3" > "$1"
}
CLOSED="[]"   # les PR mergées, dans l'ordre de merge, telles que la forge les rend
pr_merge(){ # <n> <env> <ligne per_env complète "    env: {…}\n"> [cert content|"-"|"rm"] → merge sha ; alimente CLOSED
  local n="$1" e="$2" line="$3" cert="${4:--}" br="provision/appa-$2" sha
  gw checkout -q -B "$br" main
  case "$e" in
    rec) gw show "main:$MAN" > "$TMP/cur.yml" 2>/dev/null || write_man "$TMP/cur.yml" '    dev: { auth: { claim: { value: "appa-dev" } } }\n' ''
         cp "$TMP/cur.yml" "$W/$MAN"; app_manifest_merge_env "$W/$MAN" rec "$(printf '%s' "$line" | sed -E 's/^    rec: //')" || { echo "fixture : fusion rec"; exit 2; } ;;
    dev) gw show "main:$MAN" > "$W/$MAN" 2>/dev/null || write_man "$W/$MAN" '' ''
         app_manifest_merge_env "$W/$MAN" dev "$(printf '%s' "$line" | sed -E 's/^    dev: //')" || { echo "fixture : fusion dev"; exit 2; } ;;
  esac
  case "$cert" in -) ;; rm) gw rm -q "$CERT" 2>/dev/null || true ;; *) printf '%s\n' "$cert" > "$W/$CERT" ;; esac
  gw add -A; gw commit -qm "provision($e): application appa (demande t)" >/dev/null
  gw checkout -q main; gw merge -q --no-ff -m "Merge pull request 'provision($e): appa' (#$n) from $br into main" "$br"
  sha=$(gw rev-parse HEAD)
  CLOSED=$(printf '%s' "$CLOSED" | N="$n" BR="$br" SHA="$sha" python3 -c 'import json,os,sys
l=json.load(sys.stdin); l.append({"number":int(os.environ["N"]),"merged":True,"state":"closed","merge_commit_sha":os.environ["SHA"],
 "head":{"ref":os.environ["BR"],"sha":"deadbeef","repo":{"full_name":"ci/stoa-labs"}},"base":{"ref":"main"},"user":{"login":"ci"}}); print(json.dumps(l))')
  printf '%s' "$sha"
}
```

- [ ] **Step 2 : la fixture nominale et les helpers de scénario** (suite, à la suite)

```bash
# ordre imposé : rec#a(10), rec#b(11), dev#c(12), rec#d(13), dev#e(14)
SHA_A=$(pr_merge 10 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.1"], change_ref: "CHG-0001", pv_ref: "PV-1" }' "CERT-A")
SHA_B=$(pr_merge 11 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.2"], change_ref: "CHG-0001", pv_ref: "PV-1" }' "CERT-B")
SHA_C=$(pr_merge 12 dev '    dev: { auth: { claim: { value: "appa-dev" } }, ip_allowlist: ["10.0.0.9"] }')
SHA_D=$(pr_merge 13 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.3"], change_ref: "CHG-0002", pv_ref: "PV-1" }' "CERT-D")
SHA_E=$(pr_merge 14 dev '    dev: { auth: { claim: { value: "appa-dev" } }, ip_allowlist: ["10.0.0.10"] }')
gw remote add origin "$ORIGIN"; gw push -q origin main
MAIN0=$(gw rev-parse main)
LINE_B=$(gw show "$SHA_B:$MAN" | grep -E '^    rec: '); LINE_D=$(gw show "$SHA_D:$MAN" | grep -E '^    rec: ')
gw show "$SHA_B:$MAN" > "$TMP/b.yml"; D_B=$(app_manifest_digest_env "$TMP/b.yml" rec)
[ -n "$SHA_E" ] && [ "$LINE_B" != "$LINE_D" ] && [ -n "$D_B" ] && ok "0.1 fixture : 5 merges (rec#10 rec#11 dev#12 rec#13 dev#14), N=#13 N-1=#11, lignes distinctes" || ko "0.1 fixture illisible"
set_ctl(){ printf '%s' "$1" > "$STUB_CTL"; : > "$STUB_LOG"; : > "$STUB_POSTED"; : > "$SHIM_LOG"; }
ctl_json(){ # [open json list] → ctl avec CLOSED courant
  printf '{"closed":%s,"open":%s}' "$CLOSED" "${1:-[]}"
}
reset_origin(){ git -C "$W" push -q -f origin "$MAIN0:main"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true; }
# run_rb <sortie> [VAR=val …] : le script sous test ; rc dans $TMP/rb.rc
run_rb(){
  local out="$1"; shift
  rm -f "$TMP/rb.out"
  ( cd "$REPO" && env -i PATH="$SHIM:$PATH" HOME="$HOME" SHIM_ORIGIN="$ORIGIN" \
      GITEA_TOKEN="$STUB_TOKEN" GIT_HOST="$GH" GIT_REPO=ci/stoa-labs GIT_BASE=main GIT_SUBDIR="" \
      GIT_CLONE_URL="file://$ORIGIN" STOA_ENV_CHAIN_FILE="$CHAIN" PROVISION_PLAN_INLINE=false \
      REQ_APP=appa REQ_ENV=rec REQ_REASON="incident reseau" REQ_CALLER="jenkins-form:alice" ROLLBACK_OUT="$TMP/rb.env" \
      "$@" bash "$SCRIPT" ) > "$out" 2>&1
  echo $? > "$TMP/rb.rc"
}
rrc(){ cat "$TMP/rb.rc"; }
refus(){ [ "$(rrc)" = 2 ] && grep -qF "REFUS: $1 :" "$2"; }
posts(){ grep -c '^POST ' "$STUB_LOG" || true; }
remote_branch(){ git -C "$ORIGIN" rev-parse -q --verify "refs/heads/provision/appa-rec" 2>/dev/null || printf 'absente'; }
etapes(){ grep -E '^ETAPE ' "$1" | sed 's/^ETAPE //' | tr '\n' ' '; }
```

- [ ] **Step 3 : les sections A et A' (nominal, change_ref) — écrites AVANT le script**

```bash
echo "══ A. nominal : la PR de repli restaure la ligne rec et le cert de N-1 (#11) à l'octet ══"
set_ctl "$(ctl_json)"; reset_origin
run_rb "$TMP/a.out"
[ "$(rrc)" = 0 ] && ok "A.1 rc 0" || ko "A.1 rc $(rrc) : $(grep -E 'REFUS|ERREUR' "$TMP/a.out" | head -2 | tr '\n' ' ')"
[ "$(etapes "$TMP/a.out")" = "forme chaine porte clone main manifeste lignee coherence candidate identique restauration verification pr-en-cours tete-distante commit push pr " ] \
  && ok "A.2 ordre des étapes = la propriété" || ko "A.2 étapes : $(etapes "$TMP/a.out")"
[ "$(posts)" = 1 ] && grep -q '"head": "provision/appa-rec"' "$STUB_POSTED" && ok "A.3 un seul POST /pulls, head = provision/appa-rec" || ko "A.3 posts=$(posts)"
RB=$(remote_branch); [ "$RB" != absente ] && [ "$(git -C "$ORIGIN" show "$RB:$MAN" | grep -E '^    rec: ')" = "$LINE_B" ] && ok "A.4 ligne rec de la branche == ligne de #11 à l'octet" || ko "A.4 ligne : $(git -C "$ORIGIN" show "$RB:$MAN" 2>/dev/null | grep -E '^    rec: ')"
[ "$(git -C "$ORIGIN" show "$RB:$CERT")" = "CERT-B" ] && ok "A.5 cert == CERT-B (N-1) à l'octet" || ko "A.5 cert : $(git -C "$ORIGIN" show "$RB:$CERT" 2>/dev/null)"
[ "$(git -C "$ORIGIN" diff --name-only "$MAIN0" "$RB" | sort | tr '\n' ' ')" = "$CERT $MAN " ] && ok "A.6 diff == {manifeste, cert} exactement" || ko "A.6 diff : $(git -C "$ORIGIN" diff --name-only "$MAIN0" "$RB" | tr '\n' ' ')"
[ "$(git -C "$ORIGIN" diff -U0 "$MAIN0" "$RB" -- "$MAN" | grep -cE '^[-+][^-+]')" = 2 ] && ok "A.7 le diff du manifeste touche UNE ligne (racine et dev à l'octet)" || ko "A.7 diff manifeste : $(git -C "$ORIGIN" diff -U0 "$MAIN0" "$RB" -- "$MAN" | grep -E '^[-+][^-+]' | tr '\n' ' ')"
git -C "$ORIGIN" show "$RB:$MAN" > "$TMP/rb.yml"; [ "$(app_manifest_digest_env "$TMP/rb.yml" rec)" = "$D_B" ] && ok "A.8 digest(branche, rec) == digest(#11, rec) recalculé par la lib" || ko "A.8 digest divergent"
MSG=$(git -C "$ORIGIN" log -1 --format=%B "$RB")
printf '%s' "$MSG" | grep -q "^Repli-De: $SHA_D (PR #13)" && printf '%s' "$MSG" | grep -q "^Repli-Vers: $SHA_B (PR #11)" && printf '%s' "$MSG" | grep -q "^Repli-Par: jenkins-form:alice" && printf '%s' "$MSG" | grep -q "^Repli-Digest: $D_B" \
  && ok "A.9 trailers Repli-De/Vers/Par/Digest" || ko "A.9 message : $(printf '%s' "$MSG" | tr '\n' '|')"
grep -q "<!-- app-rollback: de $SHA_D vers $SHA_B -->" "$STUB_POSTED" && grep -q '#13' "$STUB_POSTED" && grep -q '#11' "$STUB_POSTED" && grep -q "$D_B" "$STUB_POSTED" \
  && ok "A.10 corps de PR : marqueur, #N, #N-1, digest" || ko "A.10 corps : $(head -c 300 "$STUB_POSTED")"
grep -q "^PR_URL=" "$TMP/a.out" && grep -q "^REPLI_DE=$SHA_D REPLI_VERS=$SHA_B REPLI_DIGEST=$D_B" "$TMP/a.out" && ok "A.11 stdout PR_URL + REPLI_*" || ko "A.11 stdout"
grep -q "^PR_NUMBER=900" "$TMP/rb.env" && grep -q "^REPLI_DU_REPLI=0" "$TMP/rb.env" && ok "A.12 ROLLBACK_OUT écrit" || ko "A.12 ROLLBACK_OUT : $(cat "$TMP/rb.env" 2>/dev/null | tr '\n' ' ')"
! grep -q "$STUB_TOKEN" "$SHIM_LOG" && grep -q '^push --force-with-lease=refs/heads/provision/appa-rec:' "$SHIM_LOG" && ok "A.13 push en bail, jamais le token en argv git" || ko "A.13 journal git : $(grep -E 'push|clone' "$SHIM_LOG" | head -3 | tr '\n' ' ')"

echo "══ A'. change_ref : la porte AVANT tout clone/forge ; remplacé, jamais dupliqué ; pv_ref intact ══"
set_ctl "$(ctl_json)"; reset_origin
run_rb "$TMP/ap.out" STOA_ENV_CHAIN_FILE="$CHAIN_REC_GATED"
refus GATE_REFS_REQUIRED "$TMP/ap.out" && [ ! -s "$STUB_LOG" ] && ! grep -q '^clone' "$SHIM_LOG" && ! grep -q '^ETAPE clone' "$TMP/ap.out" \
  && ok "A'.1 rec gaté sans REQ_CHANGE_REF ⇒ GATE_REFS_REQUIRED, journal forge vide, aucun clone" || ko "A'.1 rc $(rrc) forge=$(wc -l < "$STUB_LOG") git=$(grep -c '^clone' "$SHIM_LOG")"
set_ctl "$(ctl_json)"; reset_origin
run_rb "$TMP/ap2.out" STOA_ENV_CHAIN_FILE="$CHAIN_REC_GATED" REQ_CHANGE_REF=CHG-0009
RB=$(remote_branch); L=$(git -C "$ORIGIN" show "$RB:$MAN" 2>/dev/null | grep -E '^    rec: ')
[ "$(rrc)" = 0 ] && [ "$L" = "$(printf '%s' "$LINE_B" | sed 's/change_ref: "CHG-0001"/change_ref: "CHG-0009"/')" ] \
  && ok "A'.2 change_ref remplacé (CHG-0001 → CHG-0009), le reste de la ligne et pv_ref à l'octet" || ko "A'.2 rc $(rrc) ligne : $L"
[ "$(printf '%s' "$L" | grep -o 'change_ref' | wc -l | tr -d ' ')" = 1 ] && ok "A'.3 une seule occurrence de change_ref" || ko "A'.3 occurrences : $(printf '%s' "$L" | grep -o 'change_ref' | wc -l)"
cp "$TMP/b.yml" "$TMP/b9.yml"; app_manifest_merge_env "$TMP/b9.yml" rec "$(printf '%s' "$L" | sed -E 's/^    rec: //')" >/dev/null 2>&1
grep -q "^REPLI_DIGEST=$(app_manifest_digest_env "$TMP/b9.yml" rec)$" "$TMP/rb.env" && ok "A'.4 digest attendu recalculé avec le nouveau change_ref" || ko "A'.4 digest annoncé : $(grep REPLI_DIGEST "$TMP/rb.env")"
# le cas #442/#443 : N-1 et N ne diffèrent que par change_ref
gw checkout -q main; SAVE_CLOSED="$CLOSED"
SHA_F=$(pr_merge 15 rec "$(printf '%s' "$LINE_D" | sed 's/change_ref: "CHG-0002"/change_ref: "CHG-0003"/')" "CERT-D"); gw push -q origin main
set_ctl "$(ctl_json)"
run_rb "$TMP/ap3.out" STOA_ENV_CHAIN_FILE="$CHAIN_REC_GATED" REQ_CHANGE_REF=CHG-0003
refus ETAT_IDENTIQUE "$TMP/ap3.out" && [ "$(posts)" = 0 ] && ok "A'.5 #15 ne diffère de #13 que par change_ref et le repli fournit celui de #15 ⇒ ETAT_IDENTIQUE (pas de commit vide)" || ko "A'.5 rc $(rrc) : $(grep REFUS "$TMP/ap3.out")"
run_rb "$TMP/ap4.out" STOA_ENV_CHAIN_FILE="$CHAIN_REC_GATED" REQ_CHANGE_REF=CHG-0004
[ "$(rrc)" = 0 ] && [ "$(posts)" = 1 ] && ok "A'.6 avec un autre change_ref ⇒ PR ouverte" || ko "A'.6 rc $(rrc) posts=$(posts)"
# ligne N-1 avec change_ref NU
gw push -q -f origin "$MAIN0:main"; CLOSED="$SAVE_CLOSED"
SHA_G=$(pr_merge 16 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.7"], change_ref: CHG-0005 }' "CERT-G")
SHA_H=$(pr_merge 17 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.8"], change_ref: CHG-0006 }' "CERT-H"); gw push -q -f origin main
set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/ap5.out" STOA_ENV_CHAIN_FILE="$CHAIN_REC_GATED" REQ_CHANGE_REF=CHG-0009
RB=$(remote_branch); L=$(git -C "$ORIGIN" show "$RB:$MAN" 2>/dev/null | grep -E '^    rec: ')
[ "$(rrc)" = 0 ] && [ "$L" = '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.7"], change_ref: "CHG-0009" }' ] \
  && ok "A'.7 change_ref NU (non quoté) à N-1 ⇒ remplacé, une seule clé" || ko "A'.7 rc $(rrc) ligne : $L"
gw push -q -f origin "$MAIN0:main"; CLOSED="$SAVE_CLOSED"; gw checkout -q main; gw reset -q --hard "$MAIN0"
```

- [ ] **Step 4 : la section B (refus nommés, rien poussé)** — chaque scénario : `set_ctl` + `reset_origin`, `run_rb`, `refus TAG` + `[ "$(posts)" = 0 ]` + `[ "$(remote_branch)" = absente ]`. Fixtures :

```bash
echo "══ B. refus nommés — rien poussé, aucun POST ══"
b_refus(){ # <n> <libellé> <TAG> <fichier de sortie>
  refus "$3" "$4" && [ "$(posts)" = 0 ] && [ "$(remote_branch)" = absente ] && ok "$1 $2 ⇒ $3, rien poussé" || ko "$1 $2 : rc $(rrc) posts=$(posts) branche=$(remote_branch) $(grep -E 'REFUS|ERREUR' "$4" | head -1)"
}
# AUCUNE_LIGNEE : une app avec manifeste mais aucune PR -rec (appb, ajoutée par commit direct)
gw checkout -q main; write_man "$W/clients/provisioned/applications/appb.ansible.yml" '' '    rec: { auth: { claim: { value: "appb-rec" } } }\n'; gw add -A; gw commit -qm "appb direct"; gw push -q origin main
set_ctl "$(ctl_json)"; run_rb "$TMP/b1.out" REQ_APP=appb; b_refus B.1 "manifeste sans PR mergée" AUCUNE_LIGNEE "$TMP/b1.out"
gw reset -q --hard "$MAIN0"; gw push -q -f origin main
# AUCUN_ETAT_PRECEDENT : un seul merge (forge ne connaît que #13)
ONE=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; l=json.load(sys.stdin); print(json.dumps([p for p in l if p["number"]==13]))')
set_ctl "{\"closed\":$ONE,\"open\":[]}"; reset_origin; run_rb "$TMP/b2.out"; b_refus B.2 "un seul état mergé" AUCUN_ETAT_PRECEDENT "$TMP/b2.out"
# BIRTH : le manifeste retiré (commit direct) puis recréé par une PR ⇒ les merges d'avant ne comptent pas
gw rm -q "$MAN"; gw commit -qm "retrait du manifeste jetable"; gw push -q origin main
SHA_R=$(pr_merge 20 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.20"] }' "CERT-R"); gw push -q origin main
set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/b3.out"; b_refus B.3 "manifeste recréé : la lignée commence à sa naissance courante (#20 seul)" AUCUN_ETAT_PRECEDENT "$TMP/b3.out"
grep -q "^LIGNEE : #20" "$TMP/b3.out" && ok "B.3b la lignée imprimée ne cite pas #13" || ko "B.3b lignée : $(grep '^LIGNEE' "$TMP/b3.out")"
gw reset -q --hard "$MAIN0"; gw push -q -f origin main; CLOSED="$SAVE_CLOSED"
# FORGE_INCOHERENTE : merge_commit_sha de N-1 hors de la première parenté
BAD=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; l=json.load(sys.stdin)
for p in l:
    if p["number"]==11: p["merge_commit_sha"]="0"*40
print(json.dumps(l))')
set_ctl "{\"closed\":$BAD,\"open\":[]}"; reset_origin; run_rb "$TMP/b4.out"; b_refus B.4 "sha de #11 hors de main" FORGE_INCOHERENTE "$TMP/b4.out"
BADN=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; l=json.load(sys.stdin)
for p in l:
    if p["number"]==13: p["merge_commit_sha"]="1"*40
print(json.dumps(l))')
set_ctl "{\"closed\":$BADN,\"open\":[]}"; reset_origin; run_rb "$TMP/b4b.out"; b_refus B.4b "sha de #13 (N) hors de main" FORGE_INCOHERENTE "$TMP/b4b.out"
# merged:false sur #11 ⇒ pas un état ⇒ N-1 = #10
NM=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; l=json.load(sys.stdin)
for p in l:
    if p["number"]==11: p["merged"]=False
print(json.dumps(l))')
set_ctl "{\"closed\":$NM,\"open\":[]}"; reset_origin; run_rb "$TMP/b5.out"
[ "$(rrc)" = 0 ] && grep -q "^REPLI_VERS=$SHA_A " "$TMP/b5.out" && ok "B.5 #11 non mergée n'est pas un état : N-1 = #10" || ko "B.5 rc $(rrc) : $(grep REPLI_VERS "$TMP/b5.out")"
# FORGE_ILLISIBLE
set_ctl '{"down":true}'; reset_origin; run_rb "$TMP/b6.out"; b_refus B.6 "forge 500" FORGE_ILLISIBLE "$TMP/b6.out"
set_ctl '{"raw_list":{"not":"a list"}}'; run_rb "$TMP/b6b.out"; b_refus B.6b "réponse non-liste" FORGE_ILLISIBLE "$TMP/b6b.out"
# REFERENCE_DIVERGENTE : commit direct sur main après N modifiant la ligne rec
gw checkout -q main; app_manifest_merge_env "$W/$MAN" rec '{ auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.99"] }' >/dev/null; gw commit -qam "hors flux"; gw push -q origin main
set_ctl "$(ctl_json)"; run_rb "$TMP/b7.out"; b_refus B.7 "main écrit hors PR" REFERENCE_DIVERGENTE "$TMP/b7.out"
gw reset -q --hard "$MAIN0"; gw push -q -f origin main
# RACINE_DIVERGENTE : racine différente entre #11 et #13 (fixture dédiée : description changée par commit direct entre les deux)
# (construite sur une copie : main → reset à SHA_B, commit direct racine, puis re-merge d'un rec#13' et dev#14')
SAVE_MAIN="$MAIN0"
gw reset -q --hard "$SHA_B"; sed -i.bak 's/fixture A6/fixture A6 bis/' "$W/$MAN" && rm -f "$W/$MAN.bak"; gw commit -qam "racine hors flux"
CL_SAVE="$CLOSED"; CLOSED=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; print(json.dumps([p for p in json.load(sys.stdin) if p["number"]<=11]))')
SHA_D2=$(pr_merge 13 rec "$LINE_D" "CERT-D"); gw push -q -f origin main
set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/b8.out"; b_refus B.8 "racine différente entre N-1 et N" RACINE_DIVERGENTE "$TMP/b8.out"
gw reset -q --hard "$SAVE_MAIN"; gw push -q -f origin main; CLOSED="$CL_SAVE"
# ETAT_IDENTIQUE par quoting : #13' porte la même ligne que #11 aux guillemets près (digest égal, octets différents)
CLOSED=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; print(json.dumps([p for p in json.load(sys.stdin) if p["number"]<=11]))')
SHA_Q=$(pr_merge 13 rec "$(printf '%s' "$LINE_B" | sed "s/\"appa-rec\"/'appa-rec'/")" "CERT-B"); gw push -q -f origin main
set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/b9.out"; b_refus B.9 "N == N-1 au digest près (quoting)" ETAT_IDENTIQUE "$TMP/b9.out"
gw reset -q --hard "$SAVE_MAIN"; gw push -q -f origin main; CLOSED="$CL_SAVE"
```

- [ ] **Step 5 : la section B, suite (PR en cours / EXIST / tête distante / forme / cert / REPLI_DU_REPLI / LIGNEE_AMBIGUE / LIGNE_AMBIGUE / MANIFESTE_ABSENT / PALIER_ABSENT / LIGNEE_TRONQUEE / bail / token)**

```bash
open_pr(){ # <login> <repo> [head sha] → json d'une PR ouverte sur la branche
  printf '[{"number":77,"state":"open","merged":false,"head":{"ref":"provision/appa-rec","sha":"%s","repo":{"full_name":"%s"}},"base":{"ref":"main"},"user":{"login":"%s"},"body":"<!-- app-rollback: de %s vers %s -->"}]' "${3:-deadbeef}" "$2" "$1" "$SHA_D" "$SHA_B"
}
# PR_EN_COURS : PR ouverte par alice (marqueur collé) ; par ci mais contenu différent ; EXIST : ci + contenu identique
set_ctl "$(ctl_json "$(open_pr alice ci/stoa-labs)")"; reset_origin; run_rb "$TMP/b10.out"; b_refus B.10 "PR ouverte par alice, marqueur collé" PR_EN_COURS "$TMP/b10.out"
# une branche distante portant un AUTRE contenu (rec#13 = main) ouverte par ci
git -C "$ORIGIN" update-ref refs/heads/provision/appa-rec "$SHA_D"
set_ctl "$(ctl_json "$(open_pr ci ci/stoa-labs "$SHA_D")")"; run_rb "$TMP/b11.out"
refus PR_EN_COURS "$TMP/b11.out" && [ "$(posts)" = 0 ] && [ "$(remote_branch)" = "$SHA_D" ] && ok "B.11 PR de ci au contenu différent ⇒ PR_EN_COURS, branche intacte" || ko "B.11 rc $(rrc) : $(grep REFUS "$TMP/b11.out")"
# EXIST : on fabrique la branche de repli exacte (un premier passage nominal), puis on relance avec une PR ouverte de ci dessus
set_ctl "$(ctl_json)"; reset_origin; run_rb "$TMP/b12a.out"; RB=$(remote_branch)
set_ctl "$(ctl_json "$(open_pr ci ci/stoa-labs "$RB")")"; run_rb "$TMP/b12.out"
[ "$(rrc)" = 0 ] && [ "$(posts)" = 0 ] && ! grep -q '^push' "$SHIM_LOG" && grep -q "^PR_URL=.*/pulls/77" "$TMP/b12.out" && [ "$(remote_branch)" = "$RB" ] \
  && ok "B.12 EXIST strict : PR ouverte par ci au contenu identique ⇒ rc 0, ni push ni POST, PR_URL=#77" || ko "B.12 rc $(rrc) posts=$(posts) push=$(grep -c '^push' "$SHIM_LOG")"
# PR de FORK avec ce head.ref ⇒ ignorée (la PR est ouverte normalement)
set_ctl "$(ctl_json "$(open_pr mallory mallory/stoa-labs)")"; reset_origin; run_rb "$TMP/b13.out"
[ "$(rrc)" = 0 ] && [ "$(posts)" = 1 ] && ok "B.13 une PR de fork ne bloque pas le repli" || ko "B.13 rc $(rrc) posts=$(posts) : $(grep REFUS "$TMP/b13.out")"
# BRANCHE_NON_MERGEE : tête distante non ancêtre de main, sans PR
gw checkout -q -B provision/appa-rec main; printf 'x\n' > "$W/HAND"; gw add -A; gw commit -qm "poussé à la main"; gw push -q -f origin provision/appa-rec; gw checkout -q main
set_ctl "$(ctl_json)"; run_rb "$TMP/b14.out"; refus BRANCHE_NON_MERGEE "$TMP/b14.out" && [ "$(posts)" = 0 ] && ok "B.14 tête distante non mergée sans PR ⇒ BRANCHE_NON_MERGEE" || ko "B.14 rc $(rrc) : $(grep REFUS "$TMP/b14.out")"
gw branch -q -D provision/appa-rec; reset_origin
# tête distante MERGÉE (ancêtre de main) ⇒ réécrite en bail
git -C "$ORIGIN" update-ref refs/heads/provision/appa-rec "$SHA_C"
set_ctl "$(ctl_json)"; run_rb "$TMP/b15.out"; [ "$(rrc)" = 0 ] && grep -q "^push --force-with-lease=refs/heads/provision/appa-rec:$SHA_C " "$SHIM_LOG" && ok "B.15 tête mergée ⇒ bail sur cette tête, push accepté" || ko "B.15 rc $(rrc) : $(grep push "$SHIM_LOG")"
# bail perdu : la branche bouge entre 12bis et 13 (le shim la déplace au moment du push)
set_ctl "$(ctl_json)"; reset_origin
run_rb "$TMP/b16.out" SHIM_MOVE_BRANCH="$SHA_C" SHIM_MOVE_REF=provision/appa-rec
refus PUSH_ECHEC "$TMP/b16.out" && [ "$(posts)" = 0 ] && ok "B.16 bail perdu (la branche a bougé) ⇒ PUSH_ECHEC, aucune PR" || ko "B.16 rc $(rrc) posts=$(posts) : $(grep -E 'REFUS' "$TMP/b16.out")"
# formes
set_ctl "$(ctl_json)"; reset_origin
run_rb "$TMP/b17.out" REQ_APP="App_A"; b_refus B.17 "REQ_APP hors classe" APP_INVALIDE "$TMP/b17.out"
run_rb "$TMP/b18.out" REQ_REASON="$(printf 'ligne1\nligne2')"; b_refus B.18 "motif avec retour-ligne" MOTIF_INVALIDE "$TMP/b18.out"
run_rb "$TMP/b19.out" REQ_REASON="<!-- app-rollback: x -->"; b_refus B.19 "motif avec marqueur HTML" MOTIF_INVALIDE "$TMP/b19.out"
run_rb "$TMP/b20.out" REQ_CHANGE_REF='CHG"1'; b_refus B.20 "change_ref avec guillemet" REF_INVALIDE "$TMP/b20.out"
run_rb "$TMP/b21.out" REQ_CALLER='alice smith'; b_refus B.21 "caller avec espace" CALLER_INVALIDE "$TMP/b21.out"
run_rb "$TMP/b22.out" REQ_ENV=homol; b_refus B.22 "palier hors chaîne" ENV_INVALIDE "$TMP/b22.out"
[ ! -s "$STUB_LOG" ] && ! grep -q '^clone' "$SHIM_LOG" && ok "B.23 les six refus de forme n'ont touché ni la forge ni git" || ko "B.23 forge=$(wc -l < "$STUB_LOG") clone=$(grep -c '^clone' "$SHIM_LOG")"
run_rb "$TMP/b24.out" REQ_APP=nope; b_refus B.24 "manifeste absent" MANIFESTE_ABSENT "$TMP/b24.out"
run_rb "$TMP/b25.out" REQ_ENV=int; b_refus B.25 "palier non déclaré (int)" PALIER_ABSENT "$TMP/b25.out"
run_rb "$TMP/b26.out" REQ_ENV=prod STOA_ENV_CHAIN_FILE="$CHAIN"; refus GATE_REFS_REQUIRED "$TMP/b26.out" && ! grep -q '^ETAPE clone' "$TMP/b26.out" && ok "B.26 terminus sans change_ref ⇒ GATE_REFS_REQUIRED avant le clone" || ko "B.26 : $(grep -E 'REFUS|ETAPE' "$TMP/b26.out" | tr '\n' ' ')"
run_rb "$TMP/b27.out" REQ_ENV=prod REQ_CHANGE_REF=CHG-1; refus PALIER_ABSENT "$TMP/b27.out" && grep -q '^ETAPE clone' "$TMP/b27.out" && ok "B.27 terminus avec change_ref ⇒ PALIER_ABSENT après le clone (ordre porte < clone < manifeste)" || ko "B.27 : $(grep -E 'REFUS' "$TMP/b27.out")"
# LIGNEE_TRONQUEE : une origine elle-même shallow
SH="$TMP/shallow"; git clone -q --depth 1 "file://$ORIGIN" "$SH.tmp" && git -C "$SH.tmp" fetch -q --depth 1 origin main && rm -rf "$SH" && git clone -q --bare --depth 1 "file://$ORIGIN" "$SH" 2>/dev/null
set_ctl "$(ctl_json)"; run_rb "$TMP/b28.out" GIT_CLONE_URL="file://$SH"; b_refus B.28 "origine shallow" LIGNEE_TRONQUEE "$TMP/b28.out"
# cert absent à N-1, présent à N ⇒ git rm dans la PR
CL_SAVE="$CLOSED"; CLOSED=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; print(json.dumps([p for p in json.load(sys.stdin) if p["number"]<=12]))')
gw reset -q --hard "$SHA_C"; git -C "$W" rm -q "$CERT"; gw commit -qm "sans cert"; SHA_NC=$(pr_merge 13 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.5"] }' "-"); SHA_WC=$(pr_merge 14 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.6"] }' "CERT-W"); gw push -q -f origin main
set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/b29.out"; RB=$(remote_branch)
[ "$(rrc)" = 0 ] && [ "$(git -C "$ORIGIN" diff --name-status "$SHA_WC" "$RB" | sort | tr '\t' ' ' | tr '\n' ' ')" = "D $CERT M $MAN " ] && ok "B.29 cert absent à N-1 et présent à N ⇒ supprimé dans la PR (diff D cert, M manifeste)" || ko "B.29 rc $(rrc) diff : $(git -C "$ORIGIN" diff --name-status "$SHA_WC" "$RB" 2>/dev/null | tr '\n' ' ')"
grep -q 'cert : supprimé' "$STUB_POSTED" && ok "B.29b le corps de PR le dit" || ko "B.29b corps"
gw reset -q --hard "$MAIN0"; gw push -q -f origin main; CLOSED="$CL_SAVE"
# REPLI_DU_REPLI : N (#13') est lui-même un repli (son commit de branche porte Repli-Vers:)
CLOSED=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; print(json.dumps([p for p in json.load(sys.stdin) if p["number"]<=12]))')
gw reset -q --hard "$SHA_C"; gw checkout -q -B provision/appa-rec main; app_manifest_merge_env "$W/$MAN" rec "$(printf '%s' "$LINE_D" | sed -E 's/^    rec: //')" >/dev/null; gw add -A
gw commit -qm "$(printf 'provision(rec): repli de appa vers #10\n\nRepli-De: %s (PR #11)\nRepli-Vers: %s (PR #10)\n' "$SHA_B" "$SHA_A")"; gw checkout -q main; gw merge -q --no-ff -m "Merge pull request 'provision(rec): appa — repli' (#13) from provision/appa-rec into main" provision/appa-rec
SHA_RR=$(gw rev-parse HEAD); CLOSED=$(printf '%s' "$CLOSED" | N=13 SHA="$SHA_RR" python3 -c 'import json,os,sys; l=json.load(sys.stdin); l.append({"number":13,"merged":True,"state":"closed","merge_commit_sha":os.environ["SHA"],"head":{"ref":"provision/appa-rec","sha":"x","repo":{"full_name":"ci/stoa-labs"}},"base":{"ref":"main"},"user":{"login":"ci"}}); print(json.dumps(l))')
gw push -q -f origin main; set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/b30.out"
[ "$(rrc)" = 0 ] && grep -q '^REPLI_DU_REPLI : restaure #11' "$TMP/b30.out" && grep -q 'REPLI_DU_REPLI' "$STUB_POSTED" && grep -q '^REPLI_DU_REPLI=1' "$TMP/rb.env" && ok "B.30 N est un repli ⇒ REPLI_DU_REPLI imprimé, dans le corps, dans ROLLBACK_OUT" || ko "B.30 rc $(rrc) : $(grep -E 'REPLI_DU|REFUS' "$TMP/b30.out")"
gw reset -q --hard "$MAIN0"; gw push -q -f origin main; CLOSED="$CL_SAVE"
# LIGNEE_AMBIGUE : une PR mergée de fork avec ce head.ref
FK=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; l=json.load(sys.stdin)
for p in l:
    if p["number"]==11: p["head"]["repo"]["full_name"]="mallory/stoa-labs"
print(json.dumps(l))')
set_ctl "{\"closed\":$FK,\"open\":[]}"; reset_origin; run_rb "$TMP/b31.out"; b_refus B.31 "PR mergée depuis un fork dans la lignée" LIGNEE_AMBIGUE "$TMP/b31.out"
# LIGNE_AMBIGUE : N-1 porte deux change_ref (écrit à la main, la lib ne l'aurait jamais produit)
CLOSED=$(printf '%s' "$CLOSED" | python3 -c 'import json,sys; print(json.dumps([p for p in json.load(sys.stdin) if p["number"]<=10]))')
gw reset -q --hard "$SHA_A"; gw checkout -q -B provision/appa-rec main; python3 - "$W/$MAN" <<'PY'
import sys,re; p=sys.argv[1]; t=open(p).read(); t=re.sub(r'^(    rec: \{.*)change_ref: "CHG-0001"', r'\1change_ref: "CHG-0001", change_ref: "CHG-0002"', t, flags=re.M); open(p,"w").write(t)
PY
gw commit -qam "double clé"; gw checkout -q main; gw merge -q --no-ff -m "Merge pull request 'provision(rec): appa' (#11) from provision/appa-rec into main" provision/appa-rec; SHA_DK=$(gw rev-parse HEAD)
CLOSED=$(printf '%s' "$CLOSED" | SHA="$SHA_DK" python3 -c 'import json,os,sys; l=json.load(sys.stdin); l.append({"number":11,"merged":True,"state":"closed","merge_commit_sha":os.environ["SHA"],"head":{"ref":"provision/appa-rec","sha":"x","repo":{"full_name":"ci/stoa-labs"}},"base":{"ref":"main"},"user":{"login":"ci"}}); print(json.dumps(l))')
SHA_DK2=$(pr_merge 12 rec "$LINE_D" "CERT-D"); gw push -q -f origin main; set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
run_rb "$TMP/b32.out" STOA_ENV_CHAIN_FILE="$CHAIN_REC_GATED" REQ_CHANGE_REF=CHG-0009; b_refus B.32 "N-1 avec deux change_ref" LIGNE_AMBIGUE "$TMP/b32.out"
gw reset -q --hard "$MAIN0"; gw push -q -f origin main; CLOSED="$CL_SAVE"; gw branch -q -D provision/appa-rec 2>/dev/null || true
```

- [ ] **Step 6 : exécuter la suite (rouge attendu — le script n'existe pas)**

Run: `bash scripts/test-app-rollback-a6.sh > /tmp/a6.log 2>&1; tail -3 /tmp/a6.log`
Expected: tous les contrôles ❌ sauf 0.1 ; aucun « fixture : » fatal (si un `pr_merge` échoue, corriger la fixture AVANT d'écrire le script).

- [ ] **Step 7 : écrire `scripts/app-rollback-request.sh`** (le code intégral est dans le fichier de plan, section « Annexe T1 » ci-dessous — le copier tel quel, puis ajuster jusqu'au vert)

- [ ] **Step 8 : exécuter la suite jusqu'au vert de A/A'/B ; `shellcheck -x scripts/app-rollback-request.sh scripts/test-app-rollback-a6.sh`**

- [ ] **Step 9 : commit**

```bash
git add scripts/app-rollback-request.sh scripts/test-app-rollback-a6.sh
git commit -m "feat(cd-apps): A6 — app-rollback-request.sh (le repli est une PR : lignée forge+Git bornée à la naissance, candidate ⊕ change_ref, ETAT_IDENTIQUE, EXIST strict, bail de push, GIT_ASKPASS) + suite A/A'/B"
```

> **Note d'exécution (T1 step 7)** : le code du script n'est pas recopié ici — il est écrit directement dans `scripts/app-rollback-request.sh`, une fonction/bloc par étape de la table D1 de la spec (13 étapes, tags et phrases de la table, `ETAPE <nom>` en tête de chaque bloc, `refus(){ echo "REFUS: $1 : $2" >&2; exit 2; }`). Le contrat est la table D1 + la section « Interfaces » ci-dessus ; la suite est l'oracle.

---

## T2 — Les mutations (section C) : la suite attrape ce qu'elle prétend attraper

**Files:** modifier `scripts/test-app-rollback-a6.sh` (section C).

- [ ] **Step 1 : le harnais de mutation** — motif A5 : copie du script, `sed`/`python` ciblé, `cmp` anti-no-op (le mutant DOIT différer), le scénario visé rejoué avec `SCRIPT=$MUT`, verdict rouge attendu ; puis l'original rejoué vert.

```bash
echo "══ C. mutations : la suite mord ══"
mutate(){ # <nom> <python transformant stdin→stdout> → chemin du mutant
  local m="$TMP/mut-$1.sh"; python3 -c "$2" < "$SCRIPT" > "$m"; chmod 700 "$m"
  cmp -s "$m" "$SCRIPT" && { ko "C.$1 mutant identique à l'original (mutation sans effet)"; return 1; }; printf '%s' "$m"
}
run_mut(){ SCRIPT="$1" run_rb "$2" "${@:3}"; }   # NB bash 3.2 : "${@:3}" est valide en bash (pas en sh)
# M1 : filtre head.ref par PRÉFIXE ⇒ dev#14 devient N ⇒ N-1 = rec#13 = main ⇒ ETAT_IDENTIQUE ⇒ A rougit
M1=$(mutate M1 'import sys; s=sys.stdin.read(); assert "head_ref == BRANCH" in s; print(s.replace("head_ref == BRANCH", "head_ref.startswith(BRANCH.rsplit(\"-\",1)[0] + \"-\")"), end="")') && {
  set_ctl "$(ctl_json)"; reset_origin; run_mut "$M1" "$TMP/m1.out"
  [ "$(rrc)" != 0 ] && grep -q 'ETAT_IDENTIQUE\|RESTAURATION_INFIDELE' "$TMP/m1.out" && ok "C.M1 clé de lignée par préfixe ⇒ le nominal rougit (dev#14 pris pour N)" || ko "C.M1 le mutant passe : rc $(rrc)"; }
# M2 : la porte (#3) déplacée APRÈS la lignée ⇒ A'.1 journalise un GET avant GATE_REFS_REQUIRED
M2=$(mutate M2 'import sys; s=sys.stdin.read(); a=s.index("etape porte"); b=s.index("etape clone"); c=s.index("etape coherence"); print(s[:a]+s[b:c]+s[a:b]+s[c:], end="")') && {
  set_ctl "$(ctl_json)"; reset_origin; run_mut "$M2" "$TMP/m2.out" STOA_ENV_CHAIN_FILE="$CHAIN_REC_GATED"
  refus GATE_REFS_REQUIRED "$TMP/m2.out" && [ -s "$STUB_LOG" ] && ok "C.M2 porte après la lignée ⇒ la forge est appelée avant le refus (la suite le voit)" || ko "C.M2 : forge=$(wc -l < "$STUB_LOG")"; }
# M3 : auto-vérification retirée + ligne altérée avant le push ⇒ restauration infidèle poussée
M3=$(mutate M3 'import sys; s=sys.stdin.read(); assert "RESTAURATION_INFIDELE" in s; s=s.replace("[ \"$D_GOT\" = \"$D_EXPECT\" ] || refus RESTAURATION_INFIDELE", "sed -i.bak \"s/10.42.0.2/10.42.0.66/\" \"$R/$MAN_PATH\"; rm -f \"$R/$MAN_PATH.bak\"; git -C \"$R\" add \"$MAN_PATH\"; true"); print(s, end="")') && {
  set_ctl "$(ctl_json)"; reset_origin; run_mut "$M3" "$TMP/m3.out"; RB=$(remote_branch)
  [ "$(rrc)" = 0 ] && [ "$(git -C "$ORIGIN" show "$RB:$MAN" 2>/dev/null | grep -E '^    rec: ')" != "$LINE_B" ] && ok "C.M3 sans auto-vérification une ligne altérée est poussée — A.4 l'attrape" || ko "C.M3 rc $(rrc)"; }
# M4 : remplacement de change_ref retiré ⇒ A'.2 garde CHG-0001
M4=$(mutate M4 'import sys; s=sys.stdin.read(); assert "REQ_CHANGE_REF" in s; print(s.replace("CANDIDATE_REF=\"$REQ_CHANGE_REF\"", "CANDIDATE_REF=\"\""), end="")') && {
  set_ctl "$(ctl_json)"; reset_origin; run_mut "$M4" "$TMP/m4.out" STOA_ENV_CHAIN_FILE="$CHAIN_REC_GATED" REQ_CHANGE_REF=CHG-0009; RB=$(remote_branch)
  [ "$(rrc)" = 0 ] && git -C "$ORIGIN" show "$RB:$MAN" | grep -q 'change_ref: "CHG-0001"' && ok "C.M4 sans remplacement, CHG-0001 reste — A'.2 l'attrape" || ko "C.M4 rc $(rrc)"; }
# M5 : borne BIRTH retirée ⇒ le scénario « manifeste recréé » ouvre une PR vers une vie antérieure
M5=$(mutate M5 'import sys; s=sys.stdin.read(); assert "is-ancestor \"$BIRTH\"" in s; print(s.replace("is-ancestor \"$BIRTH\"", "is-ancestor \"$BIRTH\" \"$BIRTH\" || true; true"), end="")') && {
  gw rm -q "$MAN"; gw commit -qm "retrait"; gw push -q origin main; SHA_R2=$(pr_merge 20 rec '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.20"] }' "CERT-R"); gw push -q origin main
  set_ctl "$(ctl_json)"; git -C "$ORIGIN" update-ref -d refs/heads/provision/appa-rec 2>/dev/null || true
  run_mut "$M5" "$TMP/m5.out"; [ "$(rrc)" = 0 ] && [ "$(posts)" = 1 ] && ok "C.M5 sans la borne BIRTH, une PR vers la vie antérieure (#13) s'ouvre — B.3 l'attrape" || ko "C.M5 rc $(rrc) posts=$(posts)"
  gw reset -q --hard "$MAIN0"; gw push -q -f origin main; CLOSED="$SAVE_CLOSED"; }
```
(Les chaînes exactes à remplacer — `head_ref == BRANCH`, `CANDIDATE_REF=`, `is-ancestor "$BIRTH"`, `refus RESTAURATION_INFIDELE` — sont des ANCRES que le script de T1 doit porter littéralement ; l'`assert` du mutant le garantit.)

- [ ] **Step 2 : rejouer, tout vert ; commit** `test(a6): mutations M1..M5 (préfixe de lignée, ordre porte/lignée, auto-vérification, change_ref, borne BIRTH)`

---

## T3 — La garde symétrique `REPLI_EN_COURS` dans `provision-request.sh` (D1bis, section B')

**Files:** modifier `scripts/provision-request.sh` (avant `[3/4] push`, `:547-577`), `scripts/test-app-rollback-a6.sh` (section B').

- [ ] **Step 1 : la section B' (rouge)** — `provision-request.sh` contre le stub et le nu : une PR ouverte de `ci` sur `provision/appa-rec` dont la tête (branche distante) porte `Repli-Vers:` ⇒ `REFUS: REPLI_EN_COURS`, branche du nu inchangée, aucun `POST` ; sans trailer ⇒ `EXIST` comme avant ; le journal du shim montre `push --force-with-lease=`.

```bash
echo "══ B'. la garde symétrique : une demande ne réécrit pas une PR de repli ouverte ══"
set_ctl "$(ctl_json)"; reset_origin; run_rb "$TMP/bp0.out"; RB=$(remote_branch)   # une PR de repli « ouverte » : sa branche existe sur le nu
run_req(){ ( cd "$REPO" && env -i PATH="$SHIM:$PATH" HOME="$HOME" GITEA_TOKEN="$STUB_TOKEN" GIT_HOST="$GH" GIT_REPO=ci/stoa-labs GIT_CLONE_URL="file://$ORIGIN" GIT_PUSH_URL="file://$ORIGIN" \
   MANIFEST_DIR=clients/provisioned/applications STOA_ENV_CHAIN_FILE="$CHAIN" PROVISION_PLAN_INLINE=false REQ_APP=appa REQ_ENV=rec REQ_API=demo-selfservice REQ_CLIENT_ID=appa-rec REQ_CALLER=oig-provisioner REQ_IP_ALLOWLIST=10.42.0.44 bash scripts/provision-request.sh ) > "$1" 2>&1; echo $? > "$TMP/req.rc"; }
set_ctl "$(ctl_json "$(open_pr ci ci/stoa-labs "$RB")")"; run_req "$TMP/bp1.out"
[ "$(cat "$TMP/req.rc")" = 2 ] && grep -q 'REFUS: REPLI_EN_COURS' "$TMP/bp1.out" && [ "$(remote_branch)" = "$RB" ] && [ "$(posts)" = 0 ] && ok "B'.1 demande pendant un repli ouvert ⇒ REPLI_EN_COURS, branche intacte" || ko "B'.1 rc $(cat "$TMP/req.rc") branche=$(remote_branch) : $(grep -E 'REFUS|ERREUR' "$TMP/bp1.out" | head -1)"
git -C "$ORIGIN" update-ref refs/heads/provision/appa-rec "$SHA_D"; set_ctl "$(ctl_json "$(open_pr ci ci/stoa-labs "$SHA_D")")"; run_req "$TMP/bp2.out"
[ "$(cat "$TMP/req.rc")" = 0 ] && grep -q 'PR déjà ouverte: #77' "$TMP/bp2.out" && grep -q '^push --force-with-lease=refs/heads/provision/appa-rec:' "$SHIM_LOG" && ok "B'.2 PR ouverte sans trailer ⇒ EXIST comme avant, push en bail" || ko "B'.2 rc $(cat "$TMP/req.rc") : $(tail -2 "$TMP/bp2.out" | tr '\n' ' ')"
```
(`provision-request.sh` gagne les knobs `GIT_CLONE_URL` / `GIT_PUSH_URL` — défauts = les URL d'aujourd'hui, `CLONE_URL`/`PUSH_URL` — pour être testable sans forge ; comportement inchangé sinon.)

- [ ] **Step 2 : la garde, avant le push** (insérer juste avant `echo "[3/4] push ${BRANCH}"`, après le `git fetch … refs/heads/${BRANCH}` existant qui pose `REMOTE_UP_TO_DATE`) :

```bash
# ── A6 (D1bis) — une demande ne réécrit JAMAIS une PR de repli ouverte ────────
# La branche provision/<app>-<env> est poussée en force plus bas : si une PR de
# REPLI y est ouverte (auteur = compte de service, tête portant le trailer
# Repli-Vers: — relu par git sur FETCH_HEAD, jamais dans le corps éditable de la
# PR), la réécrire ferait merger une demande sous un titre « repli ». Refus.
REMOTE_TIP=""
if git rev-parse -q --verify FETCH_HEAD >/dev/null 2>&1 && [ "$(git rev-parse FETCH_HEAD 2>/dev/null)" != "" ]; then REMOTE_TIP=$(git rev-parse FETCH_HEAD); fi
if [ -n "$REMOTE_TIP" ] && git log -1 --format=%B "$REMOTE_TIP" | grep -q '^Repli-Vers: '; then
  OPEN_BY=$(API="$API" GIT_REPO="$GIT_REPO" GITEA_TOKEN="$GITEA_TOKEN" BRANCH="$BRANCH" python3 - <<'PY'
import os, json, urllib.request
api, repo, tok, br = os.environ["API"], os.environ["GIT_REPO"], os.environ["GITEA_TOKEN"], os.environ["BRANCH"]
page = 1
while True:
    r = urllib.request.Request(f"{api}/repos/{repo}/pulls?state=open&limit=50&page={page}", headers={"Authorization": "token " + tok})
    with urllib.request.urlopen(r, timeout=30) as resp: prs = json.load(resp)
    if not isinstance(prs, list) or not prs: break
    for pr in prs:
        h = pr.get("head") or {}
        if h.get("ref") == br and (h.get("repo") or {}).get("full_name") == repo:
            print("%s %s" % (pr.get("number"), (pr.get("user") or {}).get("login", ""))); raise SystemExit
    page += 1
PY
) || OPEN_BY=""
  case " ${GITEA_SERVICE_LOGINS:-ci} " in
    *" ${OPEN_BY#* } "*) [ -n "$OPEN_BY" ] && fail "REPLI_EN_COURS : la PR #${OPEN_BY%% *} est un repli ouvert sur ${BRANCH} — la merger ou la fermer avant une nouvelle demande" ;;
  esac
fi
```
et le push : `git push -q "--force-with-lease=refs/heads/${BRANCH}:${REMOTE_TIP}" "$PUSH_URL" "HEAD:refs/heads/${BRANCH}"` (bail sur la tête fetchée, vide = « ne doit pas exister »). ⚠ `fail` de `provision-request.sh` rend 2 (`REFUS:` déjà préfixé). Attention au `set -e` absent : tester le rc du python explicitement (`|| OPEN_BY=""` ci-dessus, fail-closed : une forge muette refuse **si** le trailer est là — le trailer est la preuve, la forge ne fait que nommer la PR ; sans forge : `REPLI_EN_COURS` quand même avec « (PR non identifiée) »).

- [ ] **Step 3 : rejouer B' (vert), puis les suites voisines de `provision-request.sh` : `test-app-request-a1.sh`, `test-app-request-v2.sh`, `test-app-request-v3.sh`, `test-a0-wiring.sh` — totaux de T0 inchangés ; commit** `feat(cd-apps): A6 — REPLI_EN_COURS dans provision-request.sh (avant le push), push en bail`

---

## T4 — `REPLI_PERIME` au réconciliateur (D1ter, section B'')

**Files:** modifier `scripts/provision-apply-reconcile.sh` (après le bloc `PALIER_SUPPLANTE`, avant `# ── 5. SORTIE`), `scripts/test-app-rollback-a6.sh` (section B'').

- [ ] **Step 1 : la section B'' (rouge)** — fixture : sur le nu, un vrai merge `MERGE_SHA` dont le second parent porte `Repli-De: <sha>` ; stub forge = le stub de la suite A2 réduit (`GET /pulls/<n>` ⇒ `{merged:true, merged_by:{login:alice}, user:{login:ci}, head:{ref, repo}, merge_commit_sha}`, `/pulls/<n>/files` ⇒ le manifeste). Quatre cas : (i) `MERGE_SHA^1` au même état que `<sha>` ⇒ `RECONCILE_OK` ; (ii) commit direct sur `main` modifiant la ligne `rec:` entre `<sha>` et le merge ⇒ `REPLI_PERIME` ; (iii) seul le cert modifié ⇒ `REPLI_PERIME` ; (iv) même fixture sans trailer ⇒ `RECONCILE_OK` (verdict d'avant). Invocation : `env -i … GITEA_TOKEN GIT_HOST GIT_REPO GIT_WORKTREE="$W2" GIT_SUBDIR="" PR_BRANCH=provision/appa-rec PR_NUMBER=42 MERGE_SHA=<sha> RECONCILE_OUT=… bash scripts/provision-apply-reconcile.sh` (motif `run_rec` de `test-provision-apply-a2.sh:365-370` ; le stub doit aussi servir `/pulls/42` et `/pulls/42/files` — l'ajouter au stub de cette suite, piloté par `ctl.pr42`).

- [ ] **Step 2 : le bloc §4bis** (additif, conditionnel) :

```bash
# ── 4bis. A6 (D1ter) — un REPLI ne restaure que l'état d'avant le MERGE ──────
# PALIER_SUPPLANTE compare le SHA mergé à main : pour la PR qui vient d'être
# mergée ce sont le même commit. Si main a bougé pour ce palier ENTRE la
# demande de repli (Repli-De: <sha>) et le merge, la PR restaure « l'état
# d'avant » d'un main qui n'existe plus. Inerte sans trailer (toute PR non-repli).
P2=$(git -C "$GIT_WORKTREE" rev-parse -q --verify "${MERGE_SHA}^2" 2>/dev/null || true)
REPLI_DE=""
[ -n "$P2" ] && REPLI_DE=$(git -C "$GIT_WORKTREE" log -1 --format=%B "$P2" | sed -n 's/^Repli-De: \([0-9a-f]\{40\}\).*/\1/p' | head -1)
if [ -n "$REPLI_DE" ]; then
  P1=$(git -C "$GIT_WORKTREE" rev-parse "${MERGE_SHA}^1")
  CERT_REL="clients/provisioned/certs/${APP_NAME}-${ENV_NAME}.crt"
  git -C "$GIT_WORKTREE" show "${P1}:./${MANIFEST}" > "$TMP/p1.yml" 2>/dev/null \
    || fail REPLI_PERIME "${MANIFEST} absent de main juste avant le merge (${P1}) — main a bougé depuis la demande de repli ; rejouer la demande de repli" "main a bougé depuis la demande de repli (manifeste absent avant le merge)"
  git -C "$GIT_WORKTREE" show "${REPLI_DE}:./${MANIFEST}" > "$TMP/de.yml" 2>/dev/null \
    || fail REPLI_PERIME "Repli-De ${REPLI_DE} ne porte pas ${MANIFEST}" "la référence Repli-De de la PR est illisible"
  D_P1=$(app_manifest_digest_env "$TMP/p1.yml" "$ENV_NAME" 2>/dev/null) ; D_DE=$(app_manifest_digest_env "$TMP/de.yml" "$ENV_NAME" 2>/dev/null)
  [ -n "$D_P1" ] && [ "$D_P1" = "$D_DE" ] \
    || fail REPLI_PERIME "main a bougé pour ${APP_NAME}/${ENV_NAME} entre la demande de repli (${REPLI_DE}) et le merge (${P1}) : digest ${D_DE} → ${D_P1:-illisible} — rejouer la demande de repli" "main a bougé pour ce palier entre la demande de repli et son merge — rejouer la demande de repli"
  C1=$(git -C "$GIT_WORKTREE" show "${P1}:./${CERT_REL}" 2>/dev/null | shasum -a 256 | cut -c1-64 || true); C2=$(git -C "$GIT_WORKTREE" show "${REPLI_DE}:./${CERT_REL}" 2>/dev/null | shasum -a 256 | cut -c1-64 || true)
  H1=$(git -C "$GIT_WORKTREE" cat-file -e "${P1}:./${CERT_REL}" 2>/dev/null && echo 1 || echo 0); H2=$(git -C "$GIT_WORKTREE" cat-file -e "${REPLI_DE}:./${CERT_REL}" 2>/dev/null && echo 1 || echo 0)
  [ "$H1" = "$H2" ] && { [ "$H1" = 0 ] || [ "$C1" = "$C2" ]; } \
    || fail REPLI_PERIME "le certificat ${CERT_REL} a changé sur main entre la demande de repli et le merge — rejouer la demande de repli" "le certificat du palier a changé sur main entre la demande de repli et son merge — rejouer la demande de repli"
  echo "REPLI_OK : la PR est un repli (Repli-De ${REPLI_DE}) et main n'a pas bougé pour ${APP_NAME}/${ENV_NAME} avant le merge"
fi
```
(`shasum` : macOS et le conteneur Jenkins l'ont ; `sha256sum` n'existe pas sur macOS.) La section B'' asserte aussi que `diff` entre l'ancien et le nouveau script, restreint hors des lignes `4bis` … `fi`, est vide (`git diff HEAD -- scripts/provision-apply-reconcile.sh | grep -E '^[-+][^-+]' | grep -vc 'REPLI\|4bis\|P2=\|P1=\|CERT_REL=\|D_P1\|D_DE\|C1=\|C2=\|H1=\|H2=\|fi$\|if \[ -n "\$REPLI_DE"'` == 0).

- [ ] **Step 3 : rejouer B'' (vert), `test-provision-apply-a2.sh` 148/148 et `test-provision-apply-wiring.sh` 142 inchangés ; commit** `feat(cd-apps): A6 — REPLI_PERIME au réconciliateur (conditionnel au trailer Repli-De, inerte sinon)`

---

## T5 — Le formulaire `ci/Jenkinsfile.app-rollback`, la coquille XML, D8, `make lint-ci` [15/15], section D

**Files:** créer `ci/Jenkinsfile.app-rollback`, créer `ci/jenkins/app-rollback.job.xml`, modifier `ci/Jenkinsfile.selfservice:194`, `ENVIRONNEMENTS.md:1038-1040`, `Makefile`, `scripts/test-app-rollback-a6.sh` (section D).

- [ ] **Step 1 : section D (rouge)** — vue code sur les fichiers ci-dessus (chaque assertion un `grep -q` sur le fichier, jamais une exécution Groovy) : `properties([parameters([` ; les quatre `name: 'APP'|'ENV'|'REASON'|'CHANGE_REF'` et **aucun autre** `name:` dans le bloc ; `FORM_BOOTSTRAP` avant `properties(` (offsets `grep -n`) ; `env_chain_validate` ; deux lignes `sh` portant `STOA_ENV_CHAIN_FILE="$WORKSPACE/poc-control-plane-federation/clients/_example/environments.yaml"` ; `withCredentials` ; `set +x` ; `bash scripts/app-rollback-request.sh` ; `withEnv(` avec `REQ_APP`, `REQ_ENV`, `REQ_REASON`, `REQ_CHANGE_REF` ; `UserIdCause` ; **pas** de `triggers {` ni `parameters {` ; XML : `CpsScmFlowDefinition`, `<scriptPath>poc-control-plane-federation/ci/Jenkinsfile.app-rollback</scriptPath>`, `<properties/>`, `<triggers/>`, pas de `<script>` ; `Makefile` : `test-app-rollback-a6.sh`, `app-rollback-request.sh`, `test-a6-live.sh` dans la liste shellcheck, `[15/15]` ; `Jenkinsfile.selfservice` et `ENVIRONNEMENTS.md` ne contiennent plus `sauf repli (A6)` / `levier du repli (A6)` mais `le repli (A6) est une PR`.

- [ ] **Step 2 : `ci/Jenkinsfile.app-rollback`** (motif `Jenkinsfile.app-request`) :

```groovy
// ci/Jenkinsfile.app-rollback — LE REPLI D'UNE APPLICATION EST UNE PR (A6, ADR-089).
// Formulaire humain : APP + ENV (chaîne ENTIÈRE, terminus compris — les portes décident)
// + REASON + CHANGE_REF (exigé à la demande si la porte du palier l'exige). Le script
// scripts/app-rollback-request.sh ouvre une PR provision/<app>-<env> dont la ligne
// per_env.<env> et le cert du palier sont ceux du merge PRÉCÉDENT ; la chaîne
// existante (merge → provision-apply → selfservice-app-deploy) l'applique comme
// tout apply. Ce fichier ROUTE ; le script DÉCIDE. Coquille XML sans propriété
// (ci/jenkins/app-rollback.job.xml) ; formulaire posé ICI (motif A0, faits 1-5 de
// Jenkinsfile.app-request). La chaîne est ÉPINGLÉE sur les deux lignes sh (A4).
pipeline {
  agent any
  environment {
    GIT_HOST             = "${env.GIT_HOST ?: 'http://gitea:3000'}"
    GIT_REPO             = "${env.GIT_REPO ?: 'ci/stoa-labs'}"
    GITEA_CREDENTIALS_ID = "${env.GITEA_CREDENTIALS_ID ?: 'gitea-provision-token'}"
    CHAIN_FILE           = "${env.WORKSPACE}/poc-control-plane-federation/clients/_example/environments.yaml"
  }
  stages {
    stage('Formulaire — la chaîne entière') {
      steps {
        script { env.FORM_BOOTSTRAP = (params.size() == 0) ? 'true' : 'false' }
        dir('poc-control-plane-federation') {
          sh 'set +x; STOA_ENV_CHAIN_FILE="$WORKSPACE/poc-control-plane-federation/clients/_example/environments.yaml" bash -c ". scripts/lib/env-chain.sh && env_chain_validate && env_chain" > "$WORKSPACE/.a6-envs" || { rm -f "$WORKSPACE/.a6-envs"; exit 1; }'
        }
        script {
          def envs = readFile("${env.WORKSPACE}/.a6-envs").trim().tokenize(' ')
          if (envs.isEmpty()) { error("FORMULAIRE_VIDE : chaîne illisible — rien n'est posé, le formulaire précédent reste en place.") }
          properties([parameters([
            string(name: 'APP', defaultValue: '', description: "Application à replier [a-z0-9-] — la paire (APP, ENV) est la branche provision/<app>-<env> dont le merge PRÉCÉDENT est restauré."),
            choice(name: 'ENV', choices: envs, description: "Palier à replier (chaîne ENTIÈRE, terminus compris : les portes du palier décident — GATE_REFS_REQUIRED, quatre-yeux, ITSM, voie du terminus)."),
            string(name: 'REASON', defaultValue: '', description: "Motif du repli (1-300 caractères, sans retour-ligne ni `<>#@[]\\`) — dans le commit (Repli-Motif) et la PR."),
            string(name: 'CHANGE_REF', defaultValue: '', description: "Référence de changement [A-Za-z0-9._-] — EXIGÉE si la porte du palier porte requireChangeRef ou itsmCheck (un repli d'urgence porte SON change, jamais celui de l'état restauré) ; remplace change_ref dans la ligne restaurée. pv_ref n'est jamais exigé.")
          ])])
          if (env.FORM_BOOTSTRAP == 'true') { currentBuild.displayName = "amorçage du formulaire (aucun repli)" }
        }
      }
    }
    stage('Ouvrir la PR de repli') {
      when { expression { env.FORM_BOOTSTRAP != 'true' } }
      steps {
        script {
          def cause = currentBuild.getBuildCauses('hudson.model.Cause$UserIdCause')
          def rawUid = (cause && !cause.isEmpty()) ? "${cause[0].userId}" : 'anonymous'
          def uid = (rawUid && rawUid != 'null') ? rawUid : 'anonymous'
          env.REQ_CALLER = "jenkins-form:${uid}"
          currentBuild.displayName = "repli ${params.APP ?: '?'}/${params.ENV ?: '?'} (par ${uid})"
        }
        withCredentials([string(credentialsId: env.GITEA_CREDENTIALS_ID, variable: 'GITEA_TOKEN')]) {
          withEnv(["REQ_APP=${params.APP}", "REQ_ENV=${params.ENV}", "REQ_REASON=${params.REASON}", "REQ_CHANGE_REF=${params.CHANGE_REF}"]) {
            dir('poc-control-plane-federation') {
              sh 'set +x; STOA_ENV_CHAIN_FILE="$WORKSPACE/poc-control-plane-federation/clients/_example/environments.yaml" ROLLBACK_OUT="$WORKSPACE/.a6-rollback.env" bash scripts/app-rollback-request.sh'
            }
          }
        }
        script {
          def kv = [:]
          readFile("${env.WORKSPACE}/.a6-rollback.env").readLines().each { l -> def i = l.indexOf('='); if (i > 0) { kv[l.substring(0, i)] = l.substring(i + 1) } }
          if (kv.PR_URL) { currentBuild.description = "PR de repli : ${kv.PR_URL} (restaure ${kv.REPLI_VERS?.take(7)}, remplace ${kv.REPLI_DE?.take(7)})" }
        }
      }
    }
  }
}
```
(Sandbox Groovy : `getBuildCauses`, `readFile`, `properties`, `params.size`, `take` sont en liste blanche — mesuré A0/A2.)

- [ ] **Step 3 : `ci/jenkins/app-rollback.job.xml`** — copie de `ci/jenkins/app-request.job.xml` avec : en-tête réécrit (A6, ADR-089, « aucun paramètre ni trigger, formulaire posé par le Jenkinsfile, amorçage après pose »), `<description>` « Repli d'une application : formulaire → PR provision/&lt;app&gt;-&lt;env&gt; restaurant le merge précédent (A6, ADR-089) ; même aval que toute demande. PIPELINE FROM SCM : ci/Jenkinsfile.app-rollback », `<scriptPath>poc-control-plane-federation/ci/Jenkinsfile.app-rollback</scriptPath>`, `<properties/>`, `<triggers/>`.

- [ ] **Step 4 : D8** — `ci/Jenkinsfile.selfservice:194` : « Posé par provision-apply, jamais à la main — le repli (A6) est une PR, pas un SHA saisi ; un SHA de la lignée saisi ici est un rejeu hors chaîne, borné par A3 (jamais les portes A4). » ; `ENVIRONNEMENTS.md:1038-1040` : « un `MERGE_SHA` saisi à la main sur l'aval est accepté s'il est sur la lignée de `main` — ce n'est PAS le repli (A6 : le repli est une PR), c'est un rejeu hors chaîne borné par l'identité nominative et Vault. »

- [ ] **Step 5 : `Makefile`** — renuméroter `[n/14]` → `[n/15]` (14 occurrences), ajouter `scripts/app-rollback-request.sh scripts/test-app-rollback-a6.sh scripts/test-a6-live.sh` à la liste shellcheck (étiquette « + A6 »), et en fin de cible :

```make
	@# A6 (CD des applications) : le repli est une PR — le script de demande contre
	@# une fixture git + un stub forge à journal + un shim git (5 mutations), la
	@# garde symétrique de provision-request.sh, REPLI_PERIME au réconciliateur,
	@# le câblage du formulaire. La preuve par builds réels (test-a6-live.sh) se rend à la main.
	@echo "== [15/15] épreuves du repli d'application par PR — demande, lignée, gardes de fenêtre, câblage (A6)"
	@bash scripts/test-app-rollback-a6.sh
```
(`test-a6-live.sh` n'existe pas encore en T5 : créer d'abord un squelette shellcheckable en T6 step 1, ou n'ajouter cette entrée qu'en T6 — choisir T6, et le noter.)

- [ ] **Step 6 : section D verte, `make lint-ci` [15/15] vert, `ci/lint-jenkinsfiles.sh` compte 15 Jenkinsfile ; suites voisines rejouées (a0, wiring, a2, a4, a3, a5, pr-comment) aux totaux de T0 ; commit** `feat(cd-apps): A6 — Jenkinsfile.app-rollback (formulaire 4 champs, chaîne épinglée) + coquille XML + lint-ci [15/15] + commentaires D8`

---

## T6 — La preuve par builds réels : `scripts/test-a6-live.sh` + rollout lab

**Files:** créer `scripts/test-a6-live.sh` ; `Makefile` (shellcheck) ; lab.

- [ ] **Step 1 : rollout** — `git push gitea HEAD:main` (le CI lit gitea) ; `JENKINS_UI=http://localhost:18080 JENKINS_USER=… JENKINS_TOKEN=… JOBS=app-rollback BOOTSTRAP_JOBS=app-rollback bash scripts/setup-provision-jobs.sh` ; vérifier `curl -s $JENKINS_UI/job/app-rollback/api/json?tree=property[parameterDefinitions[name]]` ⇒ `APP ENV REASON CHANGE_REF` (après l'amorçage) et `ENV` == `env_chain` entière.

- [ ] **Step 2 : la suite** — squelette = `scripts/test-a5-live.sh` (préambule, helpers Gitea/Jenkins/Vault lignes 50-260, `ensure_human`, `request_branch` étendu à `REQ_CERT_PEM`, `merge_as_alice`, `answer_pause`, `wait_built`, `console_order`, `pr_comments`, `replay_pr`, nettoyage) + `jbuild`/`form_file` de `test-a4-live.sh:210-230` (variante `form_file_any` sans l'exigence `VAULT_USER=alice`) + trois helpers neufs :

```bash
# gw_app_obj <id> → 5 lignes GUID / KEY(sha256) / IDS(canonique) / SUBS / SUSP — la clé n'est jamais imprimée
gw_app_obj(){ gw "$GW_ADMIN/applications/$1" | python3 -c '
import json,sys,hashlib
d=json.load(sys.stdin); a=(d.get("applications") or [d])[0]
key=((a.get("accessTokens") or {}).get("apiAccessKey_credentials") or {}).get("apiAccessKey") or ""
ids=sorted((i.get("key",""), i.get("name",""), sorted(i.get("value") or [])) for i in (a.get("identifiers") or []) if i.get("key") in ("httpsCertificate","ipAddressRange","openIdClaims","token"))
print("GUID=%s" % a.get("id")); print("KEY=%s" % hashlib.sha256(key.encode()).hexdigest())
print("IDS=%s" % hashlib.sha256(json.dumps(ids, sort_keys=True).encode()).hexdigest())
print("SUBS=%s" % ",".join(sorted(a.get("consumingAPIs") or []))); print("SUSP=%s" % a.get("isSuspended"))'; }
gw_app_ip(){ gw "$GW_ADMIN/applications/$1" | python3 -c 'import json,sys; a=(json.load(sys.stdin).get("applications") or [None])[0]; print(",".join(sorted(next((i.get("value") or []) for i in a.get("identifiers",[]) if i.get("key")=="ipAddressRange"))))' 2>/dev/null; }
gw_app_cert(){ gw "$GW_ADMIN/applications/$1" | python3 -c 'import json,sys; a=(json.load(sys.stdin).get("applications") or [None])[0]; i=next((i for i in a.get("identifiers",[]) if i.get("key")=="httpsCertificate"),{}); print(i.get("name",""), ",".join(sorted(i.get("value") or [])))' 2>/dev/null; }
# create_api <name> → id (multipart POST /apis + activate — motif spike-cd-applications.py:89-96) ; delete_api <id> (forceDelete)
create_api(){ printf 'openapi: 3.0.0\ninfo: { title: %s, version: 1.0.0 }\nservers: [ { url: "http://poc-token-echo:8080" } ]\npaths: { /ping: { get: { operationId: ping, responses: { "200": { description: ok } } } } }\n' "$1" > "$TMP/spec.yaml"
  local id; id=$(gw -X POST -F "type=openapi" -F "apiName=$1" -F "apiVersion=1.0.0" -F "file=@$TMP/spec.yaml;type=application/x-yaml" "$GW_ADMIN/apis" | jq_ "print(((d.get('apiResponse') or {}).get('api') or {}).get('id',''))")
  [ -n "$id" ] || die "PREREQUIS : création de l'API jetable $1 refusée"; gw -X PUT -o /dev/null "$GW_ADMIN/apis/$id/activate"; printf '%s' "$id"; }
delete_api(){ gw -X PUT -o /dev/null "$GW_ADMIN/apis/$1/deactivate"; gw -X DELETE -o /dev/null -w '%{http_code}' "$GW_ADMIN/apis/$1?forceDelete=true"; }
rollback_build(){ # <app> <env> <reason> [change_ref] → numéro de build app-rollback
  printf 'APP=%s\nENV=%s\nREASON=%s\nCHANGE_REF=%s\n' "$1" "$2" "$3" "${4:-}" | form_file_any "$TMP/rb.form"; jbuild app-rollback "$TMP/rb.form"; }
```
Scénarios 0-8 de la spec D5, chacun avec ses assertions écrites comme dans `test-a5-live.sh` (`ok`/`ko`, `console_order`, `pr_comments`, lectures gateway strictes : IP `10.42.0.1-10.42.0.1`, cert `name`+`value`, `GUID KEY SUBS` égaux, `IDS` ≠ en §3 et == en §4/§5). Précondition 0.x : `env_chain_gate <terminus>` ⇒ `GATE=1|…` (lue sur le clone de gitea main, motif `test-a4-live.sh:384`), job `app-rollback` posé et amorcé, `gitea main` porte `scripts/app-rollback-request.sh` (`raw_at main …` HTTP 200) et `provision-request.sh` citant `REPLI_EN_COURS`. Certs : `openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -days 365|400 -subj "/CN=a6-C1|C2" -out …` ; `REQ_CERT_PEM="$(cat …)"` passé à `request_branch`. Nettoyage (trap) : PR fermées, `git rm` du manifeste et des certs jetables sur gitea main (motif `test-a5-live.sh:312`), `DELETE /applications/<id>`, `delete_api` si encore là.

- [ ] **Step 3 : `shellcheck -x scripts/test-a6-live.sh` ; ajouter au Makefile (shellcheck) ; jouer la suite** `JENKINS_UI=http://localhost:18080 GITEA_URL=http://localhost:13000 GW_ADMIN=http://localhost:5555/rest/apigateway WM_USER=Administrator WM_PASS=manage bash scripts/test-a6-live.sh` — attendu tout vert au premier passage ou défauts de HARNAIS nommés et corrigés (le journal du plan les compte) ; puis régression `test-provision-apply-a2-live.sh` 60/60.

- [ ] **Step 4 : commit** `test(a6-live): la porte du GOAL par builds réels — N-1/N/repli/repli du repli, API_NOT_PROMOTED exact (API jetable), GATE_REFS_REQUIRED puis PALIER_ABSENT au terminus, AUCUN_ETAT_PRECEDENT par build`

---

## T7 — Docs, ADR-089, GOAL, mémoire

- [ ] `adr/adr-089-repli-des-applications-par-pr.md` (motif ADR-088 : contexte, décision, les 10 hypothèses tranchées, ce que G6 a en plus et pourquoi non repris, gardes de fenêtre `REPLI_EN_COURS`/`REPLI_PERIME`, limites D9, qualification DORA 17(1)(e) reprise d'ADR-085, preuves avec les chiffres).
- [ ] `ENVIRONNEMENTS.md` : section « Revenir en arrière — applications (A6) » après la section A5 (parcours opérateur, la lecture qui prouve, refus et remèdes, repli du repli, garde symétrique) ; `adr/adr-088-ordre-app-api.md:65` : note datée « résolu par A6 ».
- [ ] `ci/README.md` : ligne `app-rollback` dans le tableau des jobs.
- [ ] `GOAL-cd-applications-2026-09-02.md` : A6 LIVRÉ avec les chiffres ; statut de la spec et du plan ; mémoire `a6-repli-par-pr.md` + index + `cd-applications-goal.md`.
- [ ] `git push gitea HEAD:main` ; commit final `docs(cd-apps): A6 LIVRÉ — …`.

---

## Auto-revue du plan (faite à l'écriture)

- **Couverture spec** : D0 (T1/T5), D1 (T1), D1bis (T3), D1ter (T4), D2 (T5), D3 (rien à coder — T6 le mesure), D4 A/A'/B/B'/B''/C/D (T1-T5), D5 (T6), D6 (T6 step 1), D7 (T7), D8 (T5 step 4), D9 (T7 ADR).
- **Placeholders** : le code du script n'est pas dans le plan (décision d'exécution notée sous T1) — son contrat est la table D1 ; les ANCRES de mutation (`head_ref == BRANCH`, `CANDIDATE_REF=`, `is-ancestor "$BIRTH"`, `refus RESTAURATION_INFIDELE`, `etape porte|clone|coherence`) sont des exigences littérales du script.
- **Cohérence des noms** : `GIT_CLONE_URL` (script + suite + `provision-request.sh` T3), `GIT_PUSH_URL` (T3 seulement), `ROLLBACK_OUT` (script, Jenkinsfile), `STUB_POSTED`/`open_pr`/`ctl_json`/`reset_origin`/`run_rb`/`refus`/`posts`/`remote_branch`/`etapes` (suite), `gw_app_obj`/`gw_app_ip`/`gw_app_cert`/`create_api`/`delete_api`/`rollback_build`/`form_file_any` (live).
- **Écart connu** : la suite B.28 (`LIGNEE_TRONQUEE`) construit une origine shallow ; si `git clone --bare --depth 1 file://` refuse (git ancien), remplacer par `git clone --depth 1` + `git -C … config core.bare true` et noter.

---

## Écarts au plan (mesurés à l'exécution, 2026-09-03)

- **Pas de `--filter=blob:none`** : contre une origine shallow, le clone partiel boucle en fetchs paresseux (`git fetch … --filter=blob:none --stdin` ×8, mesuré) ; clone complet mono-branche (0,8 s sur le lab). `LIGNEE_TRONQUEE` reste testé par une origine `--bare --depth 1`.
- **Les mutants vivent à côté du script** (`scripts/.a6-mut-*.sh`, retirés par le trap) : le script fait `cd "$(dirname "$0")/.."` et source ses libs — copié dans `$TMP`, il meurt en rc 1 avant toute mutation.
- **`pr_merge` dans un `$( )`** : la variable `CLOSED` ne remonte pas d'un sous-shell (le même piège que `die`) — l'entrée de forge transite par un fichier + `closed_add` après chaque capture ; toute capture teste son rc (`|| exit 2`).
- **Ancres de mutation** : M1 vise `head_ref != BRANCH` (filtre par exclusion), pas `==`.
- **Stub pour le réconciliateur** : les fichiers de PR portent le préfixe `poc-control-plane-federation/` (le réconciliateur remet `GIT_SUBDIR` par défaut `:-`, une chaîne vide ne l'annule pas).
- **`json.dumps(…, ensure_ascii=False)`** pour le corps de PR (« supprimé » sinon échappé).
- **Section A5 en repli** (D5 §6) : jouée par **désactivation** de `demo-selfservice` (`API_INACTIVE`, proxy mono-gateway comme A5) — pas d'API jetable (visibilité d'équipe, IAM à recréer, `forceDelete` sur un lab partagé : trois risques neufs) ; `API_NOT_PROMOTED` est prouvé par A5 #80 sur la même porte.
- **Cinq défauts de harnais live**, corrigés entre les passages : la précondition 0.1 ne tolérait pas le recyclage keepalive (000) ; `grep 'suspension'` vs « SUSPENSION » ; `console_order` avec un motif répété (`PORTE_OK` ×2 : la première occurrence ne peut pas suivre la pause — `PORTE_OK(pre)`/`(dispatch)`) ; `isSuspended` absent de l'objet (`None`, pas `False`) ; `^REFUS: API_INACTIVE` ancré en tête de ligne alors que la phrase est dans le `msg` du `fail` Ansible.
- **Ne jamais éditer un script bash pendant qu'il tourne** (bash lit par offsets) : le passage 1 a exécuté des fragments décalés (« repli: command not found », 5.2 rejoué, pause répondue sur #143 puis attente de #144) — les corrections étaient bonnes, le passage ne l'était plus.
- **Le recyclage keepalive coupe un aval en plein play** (« Connection reset by peer » sur le `GET /apis` de la porte A5, passage 3 §5) : ce n'est pas un verdict — le harnais rejoue le webhook (motif A2), une fois, en l'annonçant.
- **`pgrep -f "scripts/test-a6-live.sh"` se trouve lui-même** dans un moniteur dont le texte porte le motif : `[.]` dans le motif.
