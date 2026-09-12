# L5 phase 2 — la chaîne producteur sur l'autorité de forge — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** router toutes les interactions de la chaîne producteur avec la forge sur `scripts/lib/forge-api.sh` (deux visages Gitea/GitLab), appliquer D10 dans `team-apply` (plus aucune création sur la forge), donner un second visage à `archive-store`, étendre la porte, et prouver les scripts en direct sur le GitLab CE réel du lab.

**Architecture:** une seule autorité python (`forge-api.py`) exposée par une enveloppe shell (`forge`), sorties `CLÉ=VALEUR`, refus `rc 2` + cause sur stderr, secret par descripteur 3. Les scripts bash de la chaîne remplacent leurs `urllib`/`curl` Gitea par des verbes normalisés ; `team-apply` lit le dépôt d'équipe et refuse `DEPOT_ABSENT` au lieu de créer ; `archive-store.sh` reste une seconde autorité étroite pour le transport binaire des paquets, à deux branches d'URL.

**Tech Stack:** bash (`set -uo pipefail`, suites `ok/ko` + `EXPECTED_CHECKS`), python3 stdlib (`urllib`, `json`, `http.server` pour les mocks), shellcheck, Gitea 1.22 et GitLab CE 17.11 du lab (`docker-compose.gitlab.yml`), `make lint-ci`.

**Spec:** `docs/superpowers/specs/2026-09-12-l5-phase-2-chaine-producteur-forge-design.md` — le plan argumente depuis la spec ; l'exécutant lit les deux.

## Global Constraints

- Une seule autorité de forge : hors `scripts/lib/forge-api.py`, `forge-api.sh`, `forge-identity.sh` et de la seconde autorité nommée `scripts/lib/archive-store.sh`, aucun fichier ROUTÉ ne porte `/api/v1`, `api/v4`, `Authorization: token`, `"token "`, `PRIVATE-TOKEN`, `urlopen(`, ni les formes de lien Gitea `/pulls/`, `/src/commit/`.
- Le secret ne passe **jamais** en argv ni en préfixe `VAR=… cmd` : descripteur 3 (`forge`), fichier d'en-tête 0600 (`forge_auth_write`), `--data-urlencode name@fichier` (curl).
- Contrat des verbes : stdout `CLÉ=VALEUR` rc 0 ; rc 2 + une ligne de cause sur stderr ; **l'appelant nomme le tag** (`|| fail "TAG : … (cause ci-dessus)"`).
- **D10 profond** : la chaîne ne crée ni org, ni dépôt, ni hook, ni protection, sur aucun visage.
- Un commentaire par RÔLE, sous marqueur HTML, par `comment_upsert` ; l'échec d'un commentaire est un avertissement nommé, jamais un changement de verdict.
- TDD : la porte rougit avant le code ; chaque suite touchée reste verte ; `make lint-ci` 20/20 avant chaque commit ; commits `type(scope): description` avec la ligne `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Arbre partagé avec la session voisine (L6 phase 2) : un seul éditeur par fichier ; `test-team-*-wiring.sh` = fichier entier à un seul éditeur, sur demande explicite ; `git add` par chemins explicites, jamais `-A`.
- Toute nouvelle suite entre sous `make lint-ci` **et** dans la liste shellcheck du rang 2 le jour où elle naît.
- Français partout : messages, commentaires de code, doc.

---

## Carte des fichiers

| Fichier | Responsabilité après ce plan |
|---|---|
| `scripts/lib/forge-api.py` | + `repo_get`, `raw` à ref optionnelle, `main()` à arguments bornés, `call(allow_404=)` |
| `scripts/lib/forge-api.sh` | + `forge_web_url`, `forge_web_file_url` ; doc des verbes |
| `scripts/lib/forge-identity.sh` | `forge_auth_write`/`forge_auth_header` dérivés du visage, `bearer` |
| `scripts/test-forge-api.sh` | routes du mock (dépôt, raw sans ref, 400 sur ref vide), sections R (repo_get), W (liens), Q (auth dérivée), mutations M6/M7, borne d'arguments |
| `ci/lint-forge-literals.sh` | `ROUTES` étendue, `EN_ROUTAGE` (dette rapportée, pas rouge), `EXEMPTS` nommés, motifs neufs, `json.load(` qualifié |
| `scripts/team-request.sh`, `api-request.sh`, `api-promote-request.sh`, `api-promote-export.sh`, `team-publish.sh`, `team-promote.sh`, `provision-plan.sh:339` | routés (verbes, marqueurs, liens) |
| `scripts/team-apply.sh` | conduite D10 §6.1 de la spec |
| `scripts/setup-team-repos.sh` *(créé)* | outil de poste du lab : dépôt d'équipe vide + hook + protection, deux visages |
| `scripts/test-setup-team-repos.sh` *(créé)* | porte hors ligne de l'outil (`--print`, refus, shellcheck) |
| `scripts/lib/archive-store.sh` | `_as_url` à deux visages, `ARCHIVE_STORE_PROJECT` |
| `scripts/test-archive-store.sh` | stub à deux routes, refus `ARCHIVE_STORE_PROJECT_REQUIS` |
| `scripts/setup-repo-protections.sh`, `scripts/seed-governance-chain.sh` | alias `FORGE_SECRET` corrigé ; refus de visage ; `raw` via l'adaptateur |
| `scripts/setup-gitlab-lab.sh` | + projet `ci/archives` |
| `scripts/test-forge-api-live.sh` | + `repo_get`, `raw` sans ref, liens |
| `scripts/test-producer-chain-gitlab.sh` *(créé)* | matrice producteur en direct sur le GitLab du lab |
| suites adaptées | `test-palier-retention.sh` ⑭, `test-deploy-pin.sh:576`, `test-team-publish-wiring.sh` §15, `test-generate-choices.sh` (pins `comment "✅`), `test-team-onboarding-chain.sh`, `test-producer-chain.sh` |
| `Makefile` | nouvelles suites sous lint-ci et shellcheck |
| `ENVIRONNEMENTS.md`, `adr/adr-099-la-chaine-ne-cree-rien-sur-la-forge.md` *(créé)*, plan `2026-09-09-forge-agnostique-debug-branche.md` | doc, ADR, Task 8 |

Conventions communes à toutes les suites de ce dépôt (à respecter dans chaque test écrit ici) :
`ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }`, `ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }`, un `EXPECTED_CHECKS` (ou `EXPECTED_ASSERTIONS`) écrit en dur et comparé à la fin, `RÉSULTAT : PASS/TOTAL`, `[ "$FAIL" -eq 0 ]` en dernière ligne. Une épreuve qui peut être vraie par vacuité porte sa garde d'existence.

---

## Sous-lot 1 — fondations de l'adaptateur et de la porte

### Task 1 : `main()` à arguments bornés et `raw` à ref optionnelle

**Files:**
- Modify: `scripts/lib/forge-api.py` (VERBES l.626-631, `main()` l.634-655, `v_raw` l.614-623)
- Modify: `scripts/lib/forge-api.sh:18` (doc)
- Test: `scripts/test-forge-api.sh` (section H, mock gitlab `raw`)

**Interfaces:**
- Produces: `VERBES = {nom: (fn, min_args, max_args)}` ; `forge raw <chemin> [ref]` ; un argument surnuméraire est **refusé** (`rc 2`, « <verbe> attend au plus N argument(s) »), plus jamais tronqué en silence.

- [ ] **Step 1 : écrire les épreuves rouges (H.3, H.4, H.5) dans `scripts/test-forge-api.sh`**, juste après H.2 dans la boucle `for K in gitea gitlab` :

```bash
  # H.3 — raw SANS ref : la doc (forge-api.sh:18) le promettait, le registre exigeait 2 arguments.
  f "$K" "$H" raw poc/ansible/providers.dev.yml
  [ "$(rc)" = 0 ] && grep -q 'team: fbi' "$TMP/out" && ok "$K H.3 raw sans ref ⇒ la HEAD du projet, rc 0" || ko "$K H.3 rc $(rc) : $(cause)"
  # H.4 — un argument SURNUMÉRAIRE est refusé, jamais tronqué (fn(*args[:nargs]) ignorait le reste).
  f "$K" "$H" pr_get 41 de-trop
  [ "$(rc)" = 2 ] && grep -q 'au plus 1 argument' "$TMP/err" && [ ! -s "$TMP/out" ] && ok "$K H.4 pr_get avec un argument de trop ⇒ rc 2 « attend au plus 1 argument(s) », rien sur stdout" || ko "$K H.4 rc $(rc) : $(cause)"
  # H.5 — sur GitLab, une ref VIDE ne part jamais en query (le vrai GitLab rend 400 sur ref=) : le mock le rend aussi.
  if [ "$K" = gitlab ]; then
    : > "$LOG"; f "$K" "$H" raw poc/ansible/providers.dev.yml ""
    [ "$(rc)" = 0 ] && ! grep -q 'ref=' "$LOG" && ok "$K H.5 ref vide ⇒ aucune query ref= (GitLab rendrait 400)" || ko "$K H.5 rc $(rc) log=$(grep raw "$LOG" | head -1)"
  fi
```

Et dans le mock gitlab (`test-forge-api.sh`, route `repository/files/<enc>/raw`), avant le `return self.raw(200, …)` :

```python
                if "ref" in q and q["ref"] == [""]: return self.js(400, {"error": "ref is empty"})
```

- [ ] **Step 2 : vérifier RED** — `bash scripts/test-forge-api.sh 2>&1 | grep -E 'H\.[345]'` ⇒ H.3 rouge (« raw attend 2 argument(s) »), H.4 rouge (le verbe passe : pas de borne haute), H.5 vert ou rouge selon le visage (il devient discriminant à l'étape 3). Mettre à jour le compte final de la suite si elle en porte un (elle imprime `RÉSULTAT : PASS/TOTAL` sans EXPECTED : rien à toucher).

- [ ] **Step 3 : implémenter** dans `scripts/lib/forge-api.py` :

```python
VERBES = {  # nom: (fonction, min_args, max_args)
    "probe": (v_probe, 0, 0), "whoami": (v_whoami, 0, 0), "pr_find_open": (v_pr_find_open, 1, 1),
    "pr_list_merged": (v_pr_list_merged, 1, 1),
    "pr_get": (v_pr_get, 1, 1), "pr_open": (v_pr_open, 4, 4), "pr_files": (v_pr_files, 1, 1),
    "comment_find": (v_comment_find, 2, 2), "comment_upsert": (v_comment_upsert, 3, 3), "raw": (v_raw, 1, 2),
}


def main(argv):
    if len(argv) < 1 or argv[0] not in VERBES:
        sys.stderr.write("verbe inconnu — attendu : %s\n" % ", ".join(sorted(VERBES)))
        return 2
    fn, mn, mx = VERBES[argv[0]]
    args = argv[1:]
    if len(args) < mn:
        sys.stderr.write("%s attend %d argument(s)\n" % (argv[0], mn))
        return 2
    if len(args) > mx:
        # Refusé, jamais tronqué : un argument de trop est une erreur d'appelant, pas un détail.
        sys.stderr.write("%s attend au plus %d argument(s) (%d reçus)\n" % (argv[0], mx, len(args)))
        return 2
    try:
        s = _secret()
        _secrets_connus(s)
        fn(*args)
        return 0
    except ForgeError as e:
        sys.stderr.write("%s\n" % _mask(str(e)))
        return 2
    except BrokenPipeError:
        return 0
```

et `v_raw(path, ref="")` (signature par défaut ; le corps ne change pas : `query={"ref": ref} if ref else None`). Dans `forge-api.sh:18` la doc reste `forge raw <chemin> [ref]` ; ajouter en fin de ligne « (sans ref : la HEAD du projet — GitLab ≥ 13.12) ».

- [ ] **Step 4 : vérifier GREEN** — `bash scripts/test-forge-api.sh` ⇒ RÉSULTAT sans ❌ ; `bash scripts/test-forge-api-live.sh` si les forges du lab répondent (sinon SAUTÉE, dit par la suite).

- [ ] **Step 5 : commit**

```bash
git add scripts/lib/forge-api.py scripts/lib/forge-api.sh scripts/test-forge-api.sh
git commit -m "feat(forge): raw à ref optionnelle et arguments bornés — un argument de trop est refusé, jamais tronqué"
```

### Task 2 : le verbe `repo_get`

**Files:**
- Modify: `scripts/lib/forge-api.py` (`call()` l.254, nouveau `v_repo_get`, VERBES)
- Modify: `scripts/lib/forge-api.sh` (doc l.11-19)
- Test: `scripts/test-forge-api.sh` (mock : routes projet/dépôt, CTL `repo`, mutations ; section R ; M6/M7)

**Interfaces:**
- Produces: `forge repo_get` → `EXISTS=0|1 EMPTY=0|1|<vide> DEFAULT_BRANCH=<nom|vide> URL=<web|vide>` ; 404 ⇒ `EXISTS=0`, rc 0 ; `call(..., allow_404=True)` rend `None` sur 404.
- Consumed by: Task 10 (`team-apply`), Task 11 (`setup-team-repos.sh` en relecture), Task 14/15 (live).

- [ ] **Step 1 : le mock** — dans `test-forge-api.sh`, visage gitlab, **avant** `m = re.match(r"^/api/v4/projects/([^/]+)/(.*)$", path)` :

```python
            mp0 = re.match(r"^/api/v4/projects/([^/]+)$", path)
            if mp0 and method == "GET":
                if unquote(mp0.group(1)) != "ci/stoa-labs":
                    return self.js(403 if mut("404_as_403") else 404, {"message": "404 Project Not Found"})
                etat = c.get("repo", "plein")            # absent | vide | plein
                if etat == "absent": return self.js(403 if mut("404_as_403") else 404, {"message": "404 Project Not Found"})
                d = {"id": 7, "path_with_namespace": "ci/stoa-labs", "empty_repo": etat == "vide",
                     "default_branch": "" if etat == "vide" else "main", "web_url": "http://mock/ci/stoa-labs"}
                if mut("empty_repo_as_empty"): d["empty"] = d.pop("empty_repo")
                return self.js(200, d)
```

visage gitea, **avant** `m = re.match(r"^/api/v1/repos/([^/]+/[^/]+)/(.*)$", path)` :

```python
        mr0 = re.match(r"^/api/v1/repos/([^/]+/[^/]+)$", path)
        if mr0 and method == "GET":
            etat = c.get("repo", "plein")
            if mr0.group(1) != "ci/stoa-labs" or etat == "absent": return self.js(404, {"message": "The target couldn't be found."})
            return self.js(200, {"id": 7, "full_name": "ci/stoa-labs", "empty": etat == "vide",
                                 "default_branch": "main", "html_url": "http://mock/ci/stoa-labs"})
```

- [ ] **Step 2 : la section R (rouge)** — après la boucle des visages, avant « J. le DISCRIMINANT » :

```bash
echo "═══ R. repo_get : trois états, un 404 est une réponse ═══"
for K in gitea gitlab; do
  case "$K" in gitea) H="$GITEA";; *) H="$GITLAB";; esac
  set_ctl "$PRS"; f "$K" "$H" repo_get
  [ "$(rc)" = 0 ] && [ "$(val EXISTS)" = 1 ] && [ "$(val EMPTY)" = 0 ] && [ "$(val DEFAULT_BRANCH)" = main ] && [ -n "$(val URL)" ] \
    && ok "$K R.1 dépôt plein ⇒ EXISTS=1 EMPTY=0 DEFAULT_BRANCH=main URL ($(nom empty_repo empty) lu)" || ko "$K R.1 rc $(rc) : $(tr '\n' ' ' < "$TMP/out") $(cause)"
  set_ctl '{"repo":"vide"}'; f "$K" "$H" repo_get
  [ "$(rc)" = 0 ] && [ "$(val EXISTS)" = 1 ] && [ "$(val EMPTY)" = 1 ] && ok "$K R.2 dépôt vide ⇒ EXISTS=1 EMPTY=1 (DEFAULT_BRANCH='$(val DEFAULT_BRANCH)')" || ko "$K R.2 rc $(rc) : $(tr '\n' ' ' < "$TMP/out")"
  set_ctl '{"repo":"absent"}'; f "$K" "$H" repo_get
  [ "$(rc)" = 0 ] && [ "$(val EXISTS)" = 0 ] && grep -qx 'EMPTY=' "$TMP/out" && ok "$K R.3 dépôt absent ⇒ EXISTS=0 EMPTY= rc 0 — l'absence est une réponse, pas une panne" || ko "$K R.3 rc $(rc) : $(tr '\n' ' ' < "$TMP/out") $(cause)"
  set_ctl '{"repo":"absent"}'; f "$K" "$H" repo_get 2>/dev/null; grep -q 'invisible' "$TMP/err" && INV=1 || INV=0
  if [ "$K" = gitlab ]; then [ "$INV" = 1 ] && ok "$K R.4 la cause informative dit qu'un 404 GitLab vaut aussi « invisible pour ce jeton »" || ko "$K R.4 pas de note « invisible » sur stderr"; fi
  set_ctl '{"body_mode":"html","repo":"plein"}'; f "$K" "$H" repo_get
  [ "$(rc)" = 2 ] && grep -q 'NON JSON' "$TMP/err" && ok "$K R.5 page HTML ⇒ refus (jamais « non vide » par défaut)" || ko "$K R.5 rc $(rc) : $(cause)"
done
set_ctl "$PRS"
```

Dans le mock, faire honorer `body_mode == "html"` par les deux routes projet/dépôt (`if bm == "html": return self.raw(200, "text/html", HTML)` en tête de chaque route).

- [ ] **Step 3 : les mutations M6/M7** — dans la section M :

```bash
mute empty_repo_as_empty repo_get
{ [ "$(rc)" != 0 ]; } && ok "M6 empty_repo→empty ⇒ repo_get refuse (il lit empty_repo sur GitLab, jamais « non vide » par défaut)" || ko "M6 le mutant passe : EMPTY=$(val EMPTY)"
mute 404_as_403 repo_get   # le CTL de mute() garde repo=plein : forcer l'état absent
set_ctl "$(python3 -c 'import json,sys;d=json.loads(sys.argv[1]);d["mutation"]="404_as_403";d["repo"]="absent";print(json.dumps(d))' "$PRS")"; f gitlab "$GITLAB" repo_get
[ "$(rc)" = 2 ] && grep -q '403' "$TMP/err" && ok "M7 404→403 ⇒ refus « REFUSE le secret » (un 403 n'est PAS « absent »)" || ko "M7 le mutant passe : $(tr '\n' ' ' < "$TMP/out")"
set_ctl "$PRS"
```

- [ ] **Step 4 : vérifier RED** — `bash scripts/test-forge-api.sh 2>&1 | grep -E 'R\.|M[67]'` ⇒ tout rouge (« verbe inconnu »).

- [ ] **Step 5 : implémenter** — dans `forge-api.py`, `call()` gagne `allow_404=False` ; dans le bloc `except urllib.error.HTTPError` :

```python
        if e.code == 404 and allow_404:
            if kind() == "gitlab":
                sys.stderr.write("(note : sur GitLab un 404 vaut aussi « invisible pour ce jeton » — %s)\n" % _mask(diag))
            return None
```

placé **avant** les tests de redirection/401. Puis le verbe :

```python
def v_repo_get():
    """Le dépôt GIT_REPO existe-t-il, est-il vide, quelle HEAD annonce-t-il ? Un 404 est une réponse (EXISTS=0)."""
    d = call("GET", repo_path(), want=dict, allow_404=True)
    if d is None:
        out(EXISTS="0", EMPTY="", DEFAULT_BRANCH="", URL="")
        return
    champ = "empty_repo" if kind() == "gitlab" else "empty"
    if not isinstance(d.get(champ), bool):
        raise ForgeError("la forge a rendu un dépôt sans champ « %s » lisible — jamais « non vide » par défaut" % champ)
    out(EXISTS="1", EMPTY="1" if d[champ] else "0",
        DEFAULT_BRANCH=_str(d, "default_branch"),
        URL=_str(d, "web_url") if kind() == "gitlab" else _str(d, "html_url"))
```

et `"repo_get": (v_repo_get, 0, 0)` dans VERBES ; `forge-api.sh:11-19` gagne la ligne `#   forge repo_get                       # EXISTS= EMPTY= DEFAULT_BRANCH= URL= (404 ⇒ EXISTS=0, rc 0)`.

- [ ] **Step 6 : vérifier GREEN** — `bash scripts/test-forge-api.sh` sans ❌ ; `shellcheck -x scripts/lib/forge-api.sh scripts/test-forge-api.sh` ; `python3 -m py_compile scripts/lib/forge-api.py`.

- [ ] **Step 7 : commit**

```bash
git add scripts/lib/forge-api.py scripts/lib/forge-api.sh scripts/test-forge-api.sh
git commit -m "feat(forge): repo_get — existe, vide, HEAD annoncée ; un 404 est une réponse, un 403 un refus, un champ absent un refus"
```

### Task 3 : les helpers de liens `forge_web_url` et `forge_web_file_url`

**Files:**
- Modify: `scripts/lib/forge-api.sh` (après `forge_kv`)
- Test: `scripts/test-forge-api.sh` (section W)

**Interfaces:**
- Produces: `forge_web_url <url>` (stdout : l'URL, préfixe `GIT_HOST` remplacé par `GIT_WEB_HOST` quand elle est posée et différente) ; `forge_web_file_url <sha> <chemin>` (stdout : lien du fichier à ce commit selon `FORGE_KIND`).

- [ ] **Step 1 : épreuves rouges** (section W, après R) :

```bash
echo "═══ W. les liens humains viennent de l'autorité, jamais composés à la forme Gitea ═══"
w(){ ( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" FORGE_KIND="$1" GIT_HOST="$2" GIT_WEB_HOST="${3:-}" GIT_REPO=ci/stoa-labs bash -c '. scripts/lib/forge-api.sh && '"$4" ) > "$TMP/out" 2> "$TMP/err"; echo $? > "$TMP/rc"; }
w gitea http://gitea:3000 "" 'forge_web_url http://gitea:3000/ci/stoa-labs/pulls/41'
[ "$(rc)" = 0 ] && [ "$(cat "$TMP/out")" = http://gitea:3000/ci/stoa-labs/pulls/41 ] && ok "W.1 sans GIT_WEB_HOST, l'URL rendue par la forge est rendue telle quelle" || ko "W.1 $(cat "$TMP/out")"
w gitea http://gitea:3000 http://localhost:13000 'forge_web_url http://gitea:3000/ci/stoa-labs/pulls/41'
[ "$(cat "$TMP/out")" = http://localhost:13000/ci/stoa-labs/pulls/41 ] && ok "W.2 GIT_WEB_HOST posée ⇒ le préfixe GIT_HOST est réécrit (vue poste contre vue conteneur)" || ko "W.2 $(cat "$TMP/out")"
w gitlab http://gitlab http://localhost:13080 'forge_web_url https://ailleurs.example/x'
[ "$(cat "$TMP/out")" = https://ailleurs.example/x ] && ok "W.3 une URL qui ne commence pas par GIT_HOST n'est pas touchée" || ko "W.3 $(cat "$TMP/out")"
w gitea http://gitea:3000 http://localhost:13000 'forge_web_file_url 0123abc poc/ansible/providers.dev.yml'
[ "$(cat "$TMP/out")" = http://localhost:13000/ci/stoa-labs/src/commit/0123abc/poc/ansible/providers.dev.yml ] && ok "W.4 gitea : {web}/{repo}/src/commit/{sha}/{chemin}" || ko "W.4 $(cat "$TMP/out")"
w gitlab http://gitlab "" 'forge_web_file_url 0123abc poc/ansible/providers.dev.yml'
[ "$(cat "$TMP/out")" = http://gitlab/ci/stoa-labs/-/blob/0123abc/poc/ansible/providers.dev.yml ] && ok "W.5 gitlab : {web}/{repo}/-/blob/{sha}/{chemin}" || ko "W.5 $(cat "$TMP/out")"
```

- [ ] **Step 2 : vérifier RED** — « command not found » sur les cinq.

- [ ] **Step 3 : implémenter** dans `forge-api.sh` :

```bash
# forge_web_url <url> — l'URL RENDUE PAR UN VERBE (URL= de pr_open/pr_get/repo_get),
# vue du poste : si GIT_WEB_HOST est posée et diffère de GIT_HOST, le préfixe
# GIT_HOST (vue conteneur, ex. http://gitea:3000) est remplacé par GIT_WEB_HOST.
# Une URL qui ne commence pas par GIT_HOST est rendue telle quelle. Les scripts
# ne composent plus jamais « /pulls/N » : la forme est celle du visage.
forge_web_url() {
  local u="$1" h="${GIT_HOST%/}" w="${GIT_WEB_HOST:-}"
  w="${w%/}"
  if [ -n "$w" ] && [ "$w" != "$h" ]; then
    case "$u" in "$h"/*) printf '%s\n' "${w}${u#"$h"}"; return 0 ;; esac
  fi
  printf '%s\n' "$u"
}

# forge_web_file_url <sha> <chemin> — le lien HUMAIN d'un fichier À UN COMMIT,
# selon le visage (gitea : src/commit ; gitlab : -/blob), base GIT_WEB_HOST sinon GIT_HOST.
forge_web_file_url() {
  local web="${GIT_WEB_HOST:-${GIT_HOST:-}}"
  web="${web%/}"
  case "${FORGE_KIND:-gitea}" in
    gitlab) printf '%s/%s/-/blob/%s/%s\n' "$web" "${GIT_REPO:-}" "$1" "$2" ;;
    *)      printf '%s/%s/src/commit/%s/%s\n' "$web" "${GIT_REPO:-}" "$1" "$2" ;;
  esac
}
```

- [ ] **Step 4 : vérifier GREEN** puis `shellcheck -x scripts/lib/forge-api.sh`.

- [ ] **Step 5 : commit** — `git add scripts/lib/forge-api.sh scripts/test-forge-api.sh && git commit -m "feat(forge): forge_web_url et forge_web_file_url — les liens humains suivent le visage, plus jamais /pulls/N composé"`

### Task 4 : `forge_auth_write` dérive l'en-tête du visage, et accepte `bearer`

**Files:**
- Modify: `scripts/lib/forge-identity.sh:64-89`
- Test: `scripts/test-forge-api.sh` (section Q)

**Interfaces:**
- Produces: `forge_auth_write <secret> <fichier>` et `forge_auth_header <fichier-secret> <fichier>` : mode = `FORGE_API_AUTH` si posée, sinon `private-token` sous `FORGE_KIND=gitlab`, `token` sinon ; `bearer` ⇒ `Authorization: Bearer <s>`.

- [ ] **Step 1 : épreuves rouges** (section Q) :

```bash
echo "═══ Q. forge_auth_write dérive l'en-tête du VISAGE quand FORGE_API_AUTH est absente ═══"
q(){ ( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" FORGE_KIND="$1" FORGE_API_AUTH="${2:-}" FORGE_USER="${3:-}" bash -c '. scripts/lib/forge-identity.sh && forge_auth_write s3cret "$1" && cat "$1"' _ "$TMP/hdr" ) > "$TMP/out" 2> "$TMP/err"; echo $? > "$TMP/rc"; }
q gitlab ""; [ "$(rc)" = 0 ] && [ "$(cat "$TMP/out")" = 'PRIVATE-TOKEN: s3cret' ] && ok "Q.1 FORGE_KIND=gitlab sans FORGE_API_AUTH ⇒ PRIVATE-TOKEN (dérivé, comme forge-api.py)" || ko "Q.1 rc $(rc) : $(cat "$TMP/out") $(cause)"
q gitea "";  [ "$(cat "$TMP/out")" = 'Authorization: token s3cret' ] && ok "Q.2 FORGE_KIND=gitea sans FORGE_API_AUTH ⇒ Authorization: token" || ko "Q.2 $(cat "$TMP/out")"
q gitlab bearer; [ "$(rc)" = 0 ] && [ "$(cat "$TMP/out")" = 'Authorization: Bearer s3cret' ] && ok "Q.3 FORGE_API_AUTH=bearer accepté (forge-api.py l'acceptait, la lib shell le refusait)" || ko "Q.3 rc $(rc) : $(cause)"
q gitlab basic; [ "$(rc)" = 2 ] && grep -q FORGE_USER_REQUIS "$TMP/err" && ok "Q.4 basic sans FORGE_USER ⇒ FORGE_USER_REQUIS (inchangé)" || ko "Q.4 rc $(rc)"
q gitlab oauth; [ "$(rc)" = 2 ] && grep -q 'token, private-token, bearer ou basic' "$TMP/err" && ok "Q.5 mode inconnu ⇒ la liste des modes nomme bearer" || ko "Q.5 $(cause)"
```

- [ ] **Step 2 : vérifier RED** — Q.1 rouge (`Authorization: token`), Q.3 rouge (`FORGE_API_AUTH_INCONNU`), Q.5 rouge (liste sans bearer).

- [ ] **Step 3 : implémenter** — dans `forge-identity.sh`, factoriser le mode :

```bash
# Le MODE d'authentification : FORGE_API_AUTH si posée, sinon DÉRIVÉ du visage —
# PRIVATE-TOKEN sous GitLab, « Authorization: token » sous Gitea — exactement ce
# que forge-api.py:212 fait ; avant le 2026-09-12 cette lib supposait `token`
# quel que soit le visage (setup-repo-protections, archive-store, api-promote-*
# parlaient Gitea à un GitLab). `bearer` est accepté, comme dans forge-api.py.
_forge_auth_mode() {
  local m="${FORGE_API_AUTH:-}"
  if [ -z "$m" ]; then case "${FORGE_KIND:-gitea}" in gitlab) m=private-token ;; *) m=token ;; esac; fi
  printf '%s' "$m" | tr '[:upper:]' '[:lower:]'
}

forge_auth_write() {
  local secret="$1" hf="$2" mode u b64
  mode="$(_forge_auth_mode)"
  case "$mode" in
    token)         printf 'Authorization: token %s\n' "$secret" > "$hf" ;;
    private-token) printf 'PRIVATE-TOKEN: %s\n' "$secret" > "$hf" ;;
    bearer)        printf 'Authorization: Bearer %s\n' "$secret" > "$hf" ;;
    basic)
      u="${FORGE_USER:-}"
      [ -n "$u" ] || { echo "REFUS: FORGE_USER_REQUIS : FORGE_API_AUTH=basic exige FORGE_USER (l'utilisateur du couple)" >&2; return 2; }
      b64=$(printf '%s:%s' "$u" "$secret" | base64 | tr -d '\n') || return 1
      printf 'Authorization: Basic %s\n' "$b64" > "$hf" ;;
    *) echo "REFUS: FORGE_API_AUTH_INCONNU : '$mode' — attendu token, private-token, bearer ou basic" >&2; return 2 ;;
  esac
}
```

et la même structure pour `forge_auth_header` (mode par `_forge_auth_mode`, branche `bearer` : `{ printf 'Authorization: Bearer '; tr -d '\r\n' < "$sf"; printf '\n'; } > "$hf"`).

- [ ] **Step 4 : vérifier GREEN** — section Q verte ; `bash scripts/test-app-request-a7.sh` (E0.10-E0.14 lisent `forge_auth_header`) ; `bash scripts/test-archive-store.sh` (⑪bis compte `forge_auth_write .* "$hdr"` dans la lib : inchangé).

- [ ] **Step 5 : commit** — `git add scripts/lib/forge-identity.sh scripts/test-forge-api.sh && git commit -m "fix(forge): forge_auth_write dérive l'en-tête du visage et accepte bearer — la lib shell disait token à un GitLab"`

### Task 5 : la porte étendue — `ROUTES`, `EN_ROUTAGE`, exemptions nommées, motifs neufs

**Files:**
- Modify: `ci/lint-forge-literals.sh`

**Interfaces:**
- Produces: trois listes — `ROUTES` (contrôlée, rouge sur motif), `EN_ROUTAGE` (rapportée « dette de phase 2 », jamais rouge : chaque tâche de routage y retire son fichier et l'ajoute à `ROUTES`), `EXEMPTS` (nom + raison, rapportés) ; motifs : les huit existants + `/api/packages` + `/pulls/` + `/src/commit/` ; `json.load(` ne compte que sur une ligne qui porte aussi `GIT_HOST`, `FORGE_`, `urlopen` ou `api/v`.

- [ ] **Step 1 : réécrire les listes et la boucle A** :

```bash
AUTORITES='scripts/lib/forge-api.py scripts/lib/forge-api.sh scripts/lib/forge-identity.sh'
# Seconde autorité, ÉTROITE et NOMMÉE : le transport binaire des paquets
# (l'adaptateur python ne parle que JSON). Elle a le droit à /api/packages et à
# l'en-tête écrit par forge_auth_write — et à rien d'autre.
AUTORITE_PAQUETS='scripts/lib/archive-store.sh'
# Les fichiers routés — la liste qui ne fait que grandir.
ROUTES='scripts/provision-request.sh
scripts/lib/gitea-pr-confirm.sh
scripts/lib/gitea-pr-comment.sh
scripts/provision-apply-reconcile.sh
scripts/app-rollback-request.sh
scripts/provision-plan.sh
scripts/provision-plan-status.sh'
# Phase 2 (2026-09-12) : les fichiers de la chaîne producteur EN COURS de routage.
# Rapportés (« dette »), jamais rouges : chaque tâche du plan L5 phase 2 retire
# son fichier d'ici et l'ajoute à ROUTES — la liste doit être VIDE à la fin.
EN_ROUTAGE='scripts/team-request.sh
scripts/team-apply.sh
scripts/team-publish.sh
scripts/team-promote.sh
scripts/api-request.sh
scripts/api-promote-request.sh
scripts/api-promote-export.sh'
# Exemptés NOMMÉMENT, avec la raison — un outil hors chaîne n'est pas une seconde
# autorité de la chaîne, mais on le dit plutôt que de le taire.
EXEMPTS='scripts/lib/repo-protection.sh|outil d exploitant Gitea seul (protection nominative, ADR-082 §3) — hors chaîne depuis D10
scripts/setup-repo-protections.sh|outil d exploitant Gitea seul — refuse PROTECTION_GITEA_SEULEMENT sur un autre visage
scripts/seed-governance-chain.sh|outil de lab (lint-branch-literals l exempte déjà)
scripts/setup-team-repos.sh|outil de poste du lab : pré-crée les dépôts d équipe que la chaîne ne crée plus (D10)
scripts/setup-gitlab-lab.sh|outil de lab : monte la forge GitLab elle-même'
MOTIFS='/api/v1
api/v4
Authorization: token
"token "
PRIVATE-TOKEN
urllib.request.urlopen
urlopen(
/api/packages
/pulls/
/src/commit/'

motifs_dans(){ # <fichier> → les motifs présents dans le CODE (commentaires retirés), un par ligne
  local f="$1" code m
  code="$(sed 's/[[:space:]]*#.*$//' "$f")"
  while IFS= read -r m; do printf '%s\n' "$code" | grep -qF -- "$m" && printf '%s\n' "$m"; done <<< "$MOTIFS"
  # json.load( n'est un motif de FORGE que sur une ligne qui parle à la forge (GIT_HOST,
  # FORGE_, urlopen, api/v) — pas une lecture de Vault, d'ITSM ou d'un payload local.
  printf '%s\n' "$code" | grep -F 'json.load(' | grep -qE 'GIT_HOST|FORGE_|urlopen|api/v' && printf '%s\n' 'json.load( (sur une ligne de forge)'
  return 0
}

echo "═══ A. aucun littéral de forge hors des autorités, dans les fichiers routés ═══"
n=0
for f in $ROUTES; do
  [ -f "$f" ] || { ko "A.0 $f absent de l'arbre — la liste ROUTES est fausse"; continue; }
  while IFS= read -r m; do [ -n "$m" ] && { ko "A.$f porte encore « $m » — une seconde autorité sur la forge"; n=$((n+1)); }; done <<< "$(motifs_dans "$f")"
done
[ "$n" -eq 0 ] && ok "A.1 $(printf '%s\n' "$ROUTES" | wc -l | tr -d ' ') fichiers routés : aucun littéral de forge (API, en-tête, urlopen, paquets, liens Gitea)"
# archive-store : /api/packages et l'en-tête délégué lui sont permis ; le reste, non.
for f in $AUTORITE_PAQUETS; do
  reste="$(motifs_dans "$f" | grep -vE '^/api/packages$' || true)"
  [ -z "$reste" ] && ok "A.2 $f (seconde autorité, paquets) ne porte que /api/packages" || ko "A.2 $f porte : $(printf '%s' "$reste" | tr '\n' ' ')"
done

echo "═══ D. la dette de phase 2 est NOMMÉE, jamais tue ═══"
for f in $EN_ROUTAGE; do
  [ -f "$f" ] || { ko "D.0 $f absent — la liste EN_ROUTAGE est fausse"; continue; }
  mm="$(motifs_dans "$f" | tr '\n' ' ')"
  printf '  ⚠ en routage : %s — motifs : %s\n' "$f" "${mm:-aucun (à passer dans ROUTES)}"
done
[ -n "$EN_ROUTAGE" ] && ok "D.1 $(printf '%s\n' "$EN_ROUTAGE" | wc -l | tr -d ' ') fichier(s) en routage, rapportés (la liste doit être VIDE à la fin de L5 phase 2)" \
  || ok "D.1 aucun fichier en routage : la phase 2 est close"
while IFS='|' read -r f raison; do
  [ -n "$f" ] || continue
  printf '  ℹ exempté : %s — %s\n' "$f" "$raison"
done <<< "$EXEMPTS"
ok "D.2 $(printf '%s\n' "$EXEMPTS" | grep -c '|') fichiers exemptés avec leur raison (outils hors chaîne)"
```

Section M : ajouter deux mutants et un témoin :

```bash
printf '#!/usr/bin/env bash\nurl="${GIT_HOST}/api/packages/ci/generic/x/1/a.zip"\n' > "$MT/paquets.sh"
[ -n "$(motifs_dans "$MT/paquets.sh")" ] && ok "M3 /api/packages hors d'archive-store EST signalé" || ko "M3 le motif des paquets n'est pas vu"
printf '#!/usr/bin/env bash\necho "${GIT_WEB_HOST}/${GIT_REPO}/pulls/${N}"\n' > "$MT/lien.sh"
[ -n "$(motifs_dans "$MT/lien.sh")" ] && ok "M4 un lien composé à la forme Gitea (/pulls/) EST signalé" || ko "M4 le lien Gitea n'est pas vu"
printf '#!/usr/bin/env bash\nd=$(python3 -c "import json;print(json.load(open(\\"vault.json\\")))")\n' > "$MT/vault.sh"
[ -z "$(motifs_dans "$MT/vault.sh")" ] && ok "M5 un json.load qui ne parle pas à la forge n'est PAS signalé (Vault, ITSM, payload local)" || ko "M5 faux positif json.load"
```

`ATTENDU=4` devient `ATTENDU=9`.

- [ ] **Step 2 : jouer la porte** — `bash ci/lint-forge-literals.sh` ⇒ VERTE, avec sept lignes « ⚠ en routage » listant les motifs réels de chaque script (c'est le RED de la phase 2, rendu visible sans casser lint-ci). Vérifier que `provision-plan.sh` (ROUTES) rougit sur `/src/commit/` **⇒ oui** : ce fichier porte `src/commit` (l.339). Le traiter maintenant : voir Step 3.

- [ ] **Step 3 : `provision-plan.sh:339` sur le helper** — remplacer :

```python
man_url = f"{os.environ['GIT_WEB_HOST']}/{os.environ['GIT_REPO']}/src/commit/{sha}/{man}"
```

par `man_url = os.environ["MAN_URL"]` et, côté shell, passer `MAN_URL="$(forge_web_file_url "$HEAD_SHA" "$MAN")"` dans le préfixe d'env de ce heredoc python (`provision-plan.sh` source déjà `forge-api.sh`). Jouer `bash scripts/test-a0-wiring.sh` et `bash scripts/test-provision-apply-a2.sh` (le lien n'y est pas épinglé ; si une ancre `src/commit` existe, la déplacer sur `forge_web_file_url`).

- [ ] **Step 4 : vérifier** — `bash ci/lint-forge-literals.sh` VERTE (9 assertions + A/D) ; `make lint-ci` 20/20.

- [ ] **Step 5 : commit** — `git add ci/lint-forge-literals.sh scripts/provision-plan.sh && git commit -m "feat(porte): lint-forge-literals étendue — ROUTES, EN_ROUTAGE rapportée, exemptions nommées, motifs paquets et liens Gitea, json.load qualifié"`

---

## Sous-lot 2 — PR et commentaires

Gabarit commun de routage (à appliquer tel quel dans chaque script) :

```bash
# ── la forge : UNE autorité (L5 phase 2) ─────────────────────────────────────
# shellcheck source=scripts/lib/forge-api.sh
. scripts/lib/forge-api.sh || { echo "ERREUR: scripts/lib/forge-api.sh introuvable ou illisible" >&2; exit 1; }
forge_api_init || exit 2          # FORGE_KIND (défaut gitea), GIT_HOST/GIT_REPO requis, FORGE_API_AUTH dérivée
```

Le secret : `forge` lit `FORGE_SECRET` (alias `GITEA_TOKEN`) par descripteur 3 — rien à passer. Un script qui vise un **autre** dépôt que `GIT_REPO` préfixe l'appel : `GIT_REPO="$REPO_FULL" forge …`.

### Task 6 : `team-request.sh` — `pr_open`, commentaire sous marqueur, lien du visage

**Files:**
- Modify: `scripts/team-request.sh:241-254` (ouverture), `:284-296` (commentaire)
- Modify: `ci/lint-forge-literals.sh` (déplacer le fichier d'`EN_ROUTAGE` vers `ROUTES`)
- Test: `scripts/test-team-request-wiring.sh` (sonde réelle :276-293 — **fichier partagé** : demander le fichier entier à la session voisine avant toute édition ; si aucune ancre ne change, ne pas l'ouvrir)

**Interfaces:**
- Consumes: `forge pr_open <head> <base> <titre> <fichier>` → `NUMBER= URL=` ; `forge comment_upsert <n> <marqueur> <fichier>` ; `forge_web_url`.
- Produces: marqueur `<!-- team-request-plan -->` ; la ligne `PR #N ouverte : <url>` (lue par `test-producer-chain.sh:725`, grep `PR #[0-9]+ ouverte`, inchangée).

- [ ] **Step 1 : RED par la porte** — déplacer `scripts/team-request.sh` d'`EN_ROUTAGE` vers `ROUTES` dans `ci/lint-forge-literals.sh` ; `bash ci/lint-forge-literals.sh` ⇒ ROUGE sur `/api/v1`, `"token "`, `urlopen(`, `/pulls/`.

- [ ] **Step 2 : router l'ouverture** — remplacer le bloc `PR_NUMBER=$(API=… python3 - <<'PY' … PY) || fail "…"` (l.241-253) par :

```bash
# La forge parle par l'autorité (L5 phase 2) : visage, base d'API, en-tête et
# garde de réponse vivent dans forge-api ; ici on ne connaît que NUMBER et URL.
: > "$WORK/pr-body.md"    # corps vide, comme avant : le plan vient en commentaire
if ! forge_kv PR pr_open "$BRANCH" "$GIT_BASE" "onboard: équipe ${TEAM} (${REQ_ENV})" "$WORK/pr-body.md"; then
  fail "ouverture de la PR (cause ci-dessus) — si la branche '${BRANCH}' est déjà poussée sur ${GIT_HOST}/${GIT_REPO} sans PR, la nettoyer avec 'git push ${GIT_HOST}/${GIT_REPO} --delete ${BRANCH}' puis rejouer"
fi
PR_NUMBER="$PR_REPO_NUMBER"; PR_LINK="$(forge_web_url "$PR_URL")"
echo "PR #${PR_NUMBER} ouverte : ${PR_LINK}"
```

(`forge_kv PR …` pose `PR_NUMBER` et `PR_URL` ; garder le nom `PR_NUMBER` pour les lecteurs en aval.) Ajouter le gabarit de sourçage juste après le sourçage de `git-base.sh` (l.55).

- [ ] **Step 3 : router le commentaire** — remplacer le second heredoc python (l.284-295) et l'`echo` :

```bash
printf '%s\n' "$BODY" > "$WORK/plan-comment.md"
# Un commentaire par RÔLE, sous marqueur : un rejeu remplace le verdict du plan,
# il ne l'empile pas. Son échec est un AVERTISSEMENT nommé — la PR existe, le
# verdict du plan (PLAN_RC) reste le verdict (dette HANDOFF-2026-08-05:121 fermée).
if forge comment_upsert "$PR_NUMBER" '<!-- team-request-plan -->' "$WORK/plan-comment.md" >/dev/null; then
  echo "plan ${VERDICT%% *} commenté sur la PR #${PR_NUMBER}"
else
  echo "AVERTISSEMENT: le verdict du plan n'a pas pu être posé sur la PR #${PR_NUMBER} (cause ci-dessus) — la PR existe, le valideur doit lire le build" >&2
fi
```

- [ ] **Step 4 : vérifier** — `bash ci/lint-forge-literals.sh` VERTE ; `bash scripts/test-team-request-wiring.sh` (68/68 : la sonde `env -i … GIT_HOST=http://127.0.0.1:1 TEAM=equipe-sonde` doit toujours sortir sur `SECRET_FORGE_REQUIS` **avant** `forge_api_init` — placer le sourçage/init APRÈS la garde du secret l.65) ; `bash scripts/test-palier-retention.sh` (⑱ DRY_RUN sort avant tout réseau : l'init ne fait aucun appel) ; `bash scripts/test-repo-layout-portabilite.sh` (O.1-O.4 `GIT_HOST=file://$TMP` : `forge_api_init` exige un schéma http — **le refus GIT_HOST sans schéma n'arrive qu'au premier verbe**, après `[2/4]`, donc « franchie_tr » tient ; si une de ces épreuves tombe, déplacer l'init juste avant le premier `forge`) ; `shellcheck -x scripts/team-request.sh`.

- [ ] **Step 5 : commit** — `git add scripts/team-request.sh ci/lint-forge-literals.sh && git commit -m "feat(team-request): PR et verdict du plan par l'autorité de forge — commentaire par rôle, échec nommé, lien du visage"`

### Task 7 : `api-request.sh` — `pr_open` sur le dépôt d'équipe, commentaire sous `<!-- api-request -->`

**Files:**
- Modify: `scripts/api-request.sh:523-557` (ouverture), `:660-685` (commentaire)
- Modify: `ci/lint-forge-literals.sh` (EN_ROUTAGE → ROUTES)
- Test: `scripts/test-api-request-wiring.sh` (55/55 : aucune ancre sur ces sites côté script ; vérifier), `scripts/test-p7-bout-en-bout.sh:1036` (live : le marqueur devient vivant)

- [ ] **Step 1 : RED par la porte** (déplacement de liste).

- [ ] **Step 2 : ouverture** — remplacer le bloc `PR_NUMBER=$(API=… python3 - <<'PY' … PY) || fail "…"` par :

```bash
# Le corps de la PR est écrit dans un FICHIER (jamais en argv) ; la base est
# TEAM_BASE, la HEAD découverte du dépôt d'équipe — jamais un littéral.
{
  printf "Demande de publication d'API (formulaire api-request).\n\n"
  printf -- "- action : %s\n- équipe : %s\n- API : %s v%s\n- inbound.mode : %s\n" "$ACTION" "$TEAM" "$API_NAME" "$EFFECTIVE_VERSION" "$INBOUND_MODE"
  [ "$ACTION" = new-version ] && [ -n "${BASE_VERSION:-}" ] && printf -- "- version de base : %s\n" "$BASE_VERSION"
  printf -- "- posture DÉCLARÉE : classification=%s exposure=%s — déclaration, pas décision : la posture retenue vient du registre central de gouvernance (commentaire de plan ci-dessous).\n\n" "$CLASSIFICATION" "$EXPOSURE"
  printf "Plan hors ligne (posture centrale + manifest-guard + team-name + syntax-check) à suivre en commentaire. Validation humaine requise avant merge (ADR-081) : le merge n'importe rien lui-même — la publication réelle vit dans le pipeline post-merge.\n"
} > "$WORK/pr-body.md"
if ! GIT_REPO="$REPO_FULL" forge_kv PR pr_open "$BRANCH" "$TEAM_BASE" "api(${TEAM}): ${API_NAME} v${EFFECTIVE_VERSION} (${ACTION})" "$WORK/pr-body.md"; then
  fail "ouverture de la PR (cause ci-dessus) — si la branche '${BRANCH}' est déjà poussée sur ${GIT_HOST}/${REPO_FULL} sans PR, la nettoyer avec 'git push ${GIT_HOST}/${REPO_FULL} --delete ${BRANCH}' puis rejouer"
fi
PR_NUMBER="$PR_REPO_NUMBER"; PR_LINK="$(forge_web_url "$PR_URL")"
```

et remplacer toute composition `${GIT_WEB_HOST}/${REPO_FULL}/pulls/${PR_NUMBER}` par `$PR_LINK`.

- [ ] **Step 3 : commentaire** — remplacer le bloc `COMMENT_ERR=$(… python3 - <<'PY' … PY 2>&1)` / `COMMENT_RC=$?` par :

```bash
printf '%s\n' "$BODY" > "$WORK/plan-comment.md"
COMMENT_RC=0
GIT_REPO="$REPO_FULL" forge comment_upsert "$PR_NUMBER" '<!-- api-request -->' "$WORK/plan-comment.md" >/dev/null 2>"$WORK/comment.err" || COMMENT_RC=$?
COMMENT_ERR="$(cat "$WORK/comment.err")"
```

(le `if [ "$COMMENT_RC" -ne 0 ]` existant garde son avertissement ; le marqueur `<!-- api-request -->` est celui que `test-p7-bout-en-bout.sh:1036` lit déjà).

- [ ] **Step 4 : vérifier** — porte VERTE ; `bash scripts/test-api-request-wiring.sh` 55/55 ; `bash scripts/test-api-request.sh` si elle existe hors ligne ; `shellcheck -x scripts/api-request.sh`.

- [ ] **Step 5 : commit** — `git add scripts/api-request.sh ci/lint-forge-literals.sh && git commit -m "feat(api-request): PR sur le dépôt d'équipe et verdict sous <!-- api-request --> par l'autorité de forge"`

### Task 8 : `api-promote-request.sh` et `api-promote-export.sh` — `raw`, `pr_open`, `pr_find_open`

**Files:**
- Modify: `scripts/api-promote-request.sh:246-250` (raw), `:402-421` (PR)
- Modify: `scripts/api-promote-export.sh:114-118` (raw), `:297-333` (PR + repli 409)
- Modify: `scripts/test-deploy-pin.sh:576` (ancre)
- Modify: `ci/lint-forge-literals.sh` (deux fichiers EN_ROUTAGE → ROUTES)

**Interfaces:**
- Consumes: `forge raw <chemin>` (sans ref = HEAD), `forge pr_find_open <head>` (`NUMBER=` vide si aucune), `forge pr_open`.

- [ ] **Step 1 : RED** — déplacer les deux fichiers dans `ROUTES` ; changer l'ancre de `test-deploy-pin.sh:576` :

```bash
grep -qE 'forge raw "\$\{?PROV_REL\}?"' "$ROOT/scripts/api-promote-request.sh" \
  && ok "providers lu sur la forge par l'autorité (forge raw, branche par défaut du dépôt), pas sur le worktree local" \
  || bad "providers lu localement ou par un curl Gitea — un worktree en retard déciderait de l'appartenance"
```

`bash scripts/test-deploy-pin.sh` ⇒ rouge ; porte ⇒ rouge.

- [ ] **Step 2 : `raw`** — dans les deux scripts, remplacer `gapi --fail-with-body --max-time 20 "${GIT_HOST}/api/v1/repos/${GIT_REPO}/raw/${PROV_REL}" > "$TMP/providers.yml" || fail "LECTURE_PROVIDERS : …"` par :

```bash
forge raw "$PROV_REL" > "$TMP/providers.yml" \
  || fail "LECTURE_PROVIDERS : ${PROV_REL} illisible sur la branche par défaut de ${GIT_REPO} (cause ci-dessus ; chemin RELATIF à la racine du dépôt, préfixe GIT_SUBDIR='${GIT_SUBDIR:-}')"
```

et retirer `gapi()` ainsi que `forge_auth_write … "$TMP/ghdr"` s'ils n'ont plus d'usage (l'export garde `archive-store`, qui écrit son propre en-tête).

- [ ] **Step 3 : PR de promotion (`api-promote-request.sh`)** — écrire le corps dans `$TMP/pr-body.md` (même texte, `printf` shell), puis :

```bash
GIT_REPO="$REPO_FULL" forge_kv PR pr_open "$BRANCH" "$TEAM_BASE" "promote(${API_NAME}): ${FROM_ENV} → ${TO_ENV}" "$TMP/pr-body.md" \
  || fail "PR_ECHEC : ouverture de la PR sur ${REPO_FULL} (cause ci-dessus)"
PR_URL="$(forge_web_url "$PR_URL")"
```

- [ ] **Step 4 : PR d'épinglage (`api-promote-export.sh`)** — remplacer le heredoc python et son repli 409 par :

```bash
# Le rejeu est NOMINAL (le push -f vient de remplacer la branche d'épinglage) :
# on RETROUVE la PR ouverte de cette tête avant d'en ouvrir une — plus de 409 à lire.
if ! GIT_REPO="$REPO_FULL" forge_kv PIN pr_find_open "$PIN_BRANCH"; then
  fail "PIN_PR_ECHEC : relecture des PR ouvertes de ${REPO_FULL} (cause ci-dessus)"
fi
if [ -n "${PIN_NUMBER:-}" ]; then
  PIN_PR="$PIN_NUMBER"; echo "PR d'épinglage déjà ouverte : #${PIN_PR} (mise à jour par le push)"
else
  {
    printf "Épinglage du manifeste de promotion (formulaire api-promote-export).\n\n"
    printf -- "- API : %s v%s\n- guid (id-map, ADR-079) : %s\n- archive_sha256 (registre, adressé par le contenu) : %s\n\n" "$API_NAME" "$PUB_VERSION" "$GUID" "$SHA"
    printf "Merger cette PR épingle CE guid et CES octets pour la promotion. Geste suivant : formulaire api-promote-request — ARCHIVE_SHA256 peut rester vide, il sera lu ici, sur %s (ADR-081 : la décision est le merge).\n" "$TEAM_BASE"
  } > "$TMP/pin-body.md"
  GIT_REPO="$REPO_FULL" forge_kv PIN pr_open "$PIN_BRANCH" "$TEAM_BASE" "promo(${API_NAME}): épinglage guid/sha v${PUB_VERSION}" "$TMP/pin-body.md" \
    || fail "PIN_PR_ECHEC : ouverture de la PR d'épinglage sur ${REPO_FULL} (cause ci-dessus)"
  PIN_PR="$PIN_NUMBER"
fi
```

- [ ] **Step 5 : vérifier** — porte VERTE ; `bash scripts/test-deploy-pin.sh` ; `bash scripts/test-promote-sans-recopie.sh` ; `bash scripts/test-repo-layout-portabilite.sh` (section P : ses stubs servent `/api/v1/repos/<repo>/raw/<chemin>` — `forge raw` sous le visage gitea appelle exactement ce chemin, sans `?ref=`) ; `bash scripts/test-archive-store.sh` ; `shellcheck -x` des deux scripts.

- [ ] **Step 6 : commit** — `git add scripts/api-promote-request.sh scripts/api-promote-export.sh scripts/test-deploy-pin.sh ci/lint-forge-literals.sh && git commit -m "feat(promote): providers par forge raw, PR par pr_open, rejeu de l'export par pr_find_open — plus de 409 à lire"`

### Task 9 : `team-publish.sh` et `team-promote.sh` — `pr_get`, liens du visage

**Files:**
- Modify: `scripts/team-publish.sh:219-240` (réconciliation), `:538` (lien)
- Modify: `scripts/team-promote.sh:279-305` (réconciliation), `:805` (lien)
- Modify: `scripts/test-team-publish-wiring.sh:404-421` (§15 — **fichier partagé** : obtenir « à toi » de la session voisine, éditer, rendre)
- Modify: `ci/lint-forge-literals.sh`

**Interfaces:**
- Consumes: `GIT_REPO="$WEBHOOK_REPO" forge_kv PR pr_get "$PR_NUMBER"` → `PR_MERGED PR_MERGE_SHA PR_HEAD_REF PR_BASE_REF PR_MERGED_BY PR_LOGIN PR_URL`.

- [ ] **Step 1 : RED** — déplacer les deux fichiers dans `ROUTES` ; réécrire §15 de `test-team-publish-wiring.sh` :

```bash
grep -qF 'fail "GITEA_RECONCILE_ECHEC :' "$REPO/scripts/team-publish.sh" && ok "GITEA_RECONCILE_ECHEC présent (échec de lecture de la forge = refus)" || ko "GITEA_RECONCILE_ECHEC absent"
grep -qF 'fail "PAYLOAD_PERIME :' "$REPO/scripts/team-publish.sh" && ok "PAYLOAD_PERIME présent (divergence webhook/forge = refus)" || ko "PAYLOAD_PERIME absent"
grep -qE 'GIT_REPO="\$WEBHOOK_REPO" forge_kv PR pr_get "\$PR_NUMBER"' "$REPO/scripts/team-publish.sh" && ok "la PR est relue chez la FORGE par l'autorité (pr_get), jamais déduite du payload" || ko "pr_get absent — la réconciliation ne passe pas par l'autorité"
grep -qF '"$PR_MERGED" = 1' "$REPO/scripts/team-publish.sh" && ok "merged relu (PR_MERGED)" || ko "PR_MERGED non vérifié"
grep -qF '"$PR_MERGE_SHA" = "$MERGE_SHA"' "$REPO/scripts/team-publish.sh" && ok "merge_commit_sha comparé au MERGE_SHA du webhook" || ko "MERGE_SHA non comparé"
grep -qF '"$PR_HEAD_REF" = "$PR_BRANCH"' "$REPO/scripts/team-publish.sh" && ok "head comparé à PR_BRANCH" || ko "PR_BRANCH non comparé"
grep -qF '"$PR_BASE_REF" = "$TEAM_BASE"' "$REPO/scripts/team-publish.sh" && ok "base comparée à la branche DÉCOUVERTE du dépôt d'équipe" || ko "TEAM_BASE non comparé"
grep -qE '^gbase git_base_of "\$\{GIT_HOST\}/\$\{WEBHOOK_REPO\}\.git"' "$REPO/scripts/team-publish.sh" && ok "TEAM_BASE vient d'une DÉCOUVERTE sous enveloppe (gbase)" || ko "TEAM_BASE non découvert sous enveloppe"
```

(même nombre d'assertions qu'avant : `EXPECTED_CHECKS` inchangé).

- [ ] **Step 2 : réconciliation** — dans les deux scripts, remplacer le bloc `PR_STATE=$(… python3 - <<'PY' … PY)` et son exploitation par :

```bash
GIT_REPO="$WEBHOOK_REPO" forge_kv PR pr_get "$PR_NUMBER" \
  || fail "GITEA_RECONCILE_ECHEC : la forge n'a pas confirmé la PR #${PR_NUMBER} de ${WEBHOOK_REPO} (cause ci-dessus)"
[ "$PR_MERGED" = 1 ] && [ "$PR_MERGE_SHA" = "$MERGE_SHA" ] && [ "$PR_HEAD_REF" = "$PR_BRANCH" ] && [ "$PR_BASE_REF" = "$TEAM_BASE" ] \
  || fail "PAYLOAD_PERIME : la forge dit merged=${PR_MERGED} merge_sha=${PR_MERGE_SHA} head=${PR_HEAD_REF} base=${PR_BASE_REF} — le payload disait ${MERGE_SHA} ${PR_BRANCH} ${TEAM_BASE}"
PR_MERGED_BY="$PR_MERGED_BY"; PR_REQUESTER="$PR_LOGIN"      # noms lus par la suite du script (garde d'identité)
```

Dans `team-promote.sh`, conserver la garde « pas de retour-ligne dans les logins » sur `PR_MERGED_BY`/`PR_LOGIN` (`case "$v" in *$'\n'*) fail …`) — `forge-api.py` refuse déjà un blanc dans une valeur (`line()`), la garde reste et devient vraie par construction.

- [ ] **Step 3 : liens** — remplacer `([PR #${PR_NUMBER}](${GIT_WEB_HOST}/${WEBHOOK_REPO}/pulls/${PR_NUMBER}))` par `([PR #${PR_NUMBER}]($(forge_web_url "$PR_URL")))` dans les deux commentaires ✅.

- [ ] **Step 4 : vérifier** — porte VERTE ; `bash scripts/test-team-publish-wiring.sh` (123/123) ; `bash scripts/test-team-promote-wiring.sh` (72/72 ; si une ancre python y vit, la déplacer sur `forge_kv PR pr_get` de la même façon — le fichier est partagé, même protocole) ; `bash scripts/test-promote-sans-recopie.sh` ; `bash scripts/test-parity-moteurs.sh` ; `shellcheck -x` des deux.

- [ ] **Step 5 : commit** — `git add scripts/team-publish.sh scripts/team-promote.sh scripts/test-team-publish-wiring.sh ci/lint-forge-literals.sh && git commit -m "feat(post-merge): team-publish et team-promote relisent la PR par pr_get — réconciliation normalisée, liens du visage"`

---

## Sous-lot 3 — `team-apply` sous D10, le lab, les outils

### Task 10 : `team-apply.sh` — lire le dépôt, refuser `DEPOT_ABSENT`, ne plus rien créer

**Files:**
- Modify: `scripts/team-apply.sh` (l.104-121 `comment()`/`fail()`, §2 l.187-424, §4 l.433-509)
- Modify: `scripts/test-palier-retention.sh:710-762` (⑭ retournée)
- Modify: `scripts/test-generate-choices.sh` (pins `comment "✅ team-apply…` l.326-332 : lire la nouvelle forme)
- Modify: `ci/lint-forge-literals.sh` (team-apply → ROUTES)
- Test: `scripts/test-team-apply-wiring.sh` (72/72 — **fichier partagé** ; ses assertions script-side : vault-login sourcé, `V_PASS` password — ne bougent pas ; ne l'ouvrir que si une ancre casse)

**Interfaces:**
- Consumes: `GIT_REPO="$REPO_FULL" forge_kv DEPOT repo_get` → `DEPOT_EXISTS DEPOT_EMPTY DEPOT_DEFAULT_BRANCH DEPOT_URL` ; `forge comment_upsert "$PR_NUMBER" '<!-- team-apply -->' <fichier>`.
- Produces: refus `DEPOT_ABSENT` (rc 2) ; notes `REPO_NOTE` : « dépôt X : vide, squelette poussé » / « dépôt X : déjà initialisé, étape sautée » ; un seul commentaire ❌.

- [ ] **Step 1 : RED** — (a) porte : déplacer `team-apply.sh` dans `ROUTES` ; (b) `test-palier-retention.sh` ⑭ réécrite :

```bash
echo "== ⑭ D10 : team-apply LIT le dépôt d'équipe et ne crée plus rien sur la forge =="
nc_strict scripts/team-apply.sh > "$TMP/ta14_nc"
grep -q 'repo-protection.sh' "$TMP/ta14_nc" \
  && bad "⑭ team-apply source encore repo-protection.sh — la protection est un prérequis de forge depuis D10" \
  || ok "⑭ repo-protection.sh n'est plus sourcée par team-apply (protection = prérequis de forge, ADR-099)"
grep -Eq '[^A-Za-z_]pose_branch_protection ' "$TMP/ta14_nc" \
  && bad "⑭bis pose_branch_protection encore appelée" || ok "⑭bis aucun appel de pose_branch_protection"
grep -q 'TEAM_PUBLISH_WEBHOOK_URL' "$TMP/ta14_nc" \
  && bad "⑭ter le webhook team-publish est encore posé par le job" || ok "⑭ter plus de pose de webhook (prérequis de forge)"
grep -qE '/orgs' "$TMP/ta14_nc" && bad "⑭quater création d'org encore présente" || ok "⑭quater aucune création d'org"
grep -q 'gitea-org-admin' "$TMP/ta14_nc" && bad "⑭quinquies le jeton org-admin est encore lu dans Vault" || ok "⑭quinquies plus de jeton org-admin (le secret de forge ordinaire pousse le squelette)"
grep -qE 'forge_kv DEPOT repo_get' "$TMP/ta14_nc" && ok "⑭sexies le dépôt est LU par repo_get" || bad "⑭sexies repo_get absent"
grep -qF 'DEPOT_ABSENT' "$TMP/ta14_nc" && ok "⑭septies le refus DEPOT_ABSENT existe" || bad "⑭septies DEPOT_ABSENT absent"
L_GET=$(grep -n 'forge_kv DEPOT repo_get' "$TMP/ta14_nc" | head -1 | cut -d: -f1)
L_PUSH=$(grep -nE 'git( -C [^ ]+)? push' "$TMP/ta14_nc" | head -1 | cut -d: -f1)
{ [ -n "$L_GET" ] && [ -n "$L_PUSH" ] && [ "$L_GET" -lt "$L_PUSH" ]; } \
  && ok "⑭octies la lecture précède le push du squelette (on ne pousse que dans un dépôt VIDE)" \
  || bad "⑭octies ordre lecture/push non prouvé (get=${L_GET:-absent} push=${L_PUSH:-absent})"
# mutants : réintroduire la pose rougit ⑭bis ; retirer DEPOT_ABSENT rougit ⑭septies
sed 's/^\(.*forge_kv DEPOT repo_get.*\)$/\1\npose_branch_protection "$GIT_HOST" "$TMP\/ghdr" "$REPO_FULL" "$TMP\/prot.json"/' scripts/team-apply.sh | nc_strict /dev/stdin > "$TMP/ta14_m1"
grep -Eq '[^A-Za-z_]pose_branch_protection ' "$TMP/ta14_m1" && ok "⑭nonies mutant « pose réintroduite » ⇒ ⑭bis rougirait" || bad "⑭nonies le mutant n'est pas vu"
sed '/DEPOT_ABSENT/d' scripts/team-apply.sh | nc_strict /dev/stdin > "$TMP/ta14_m2"
grep -qF 'DEPOT_ABSENT' "$TMP/ta14_m2" && bad "⑭decies le mutant « refus retiré » passe" || ok "⑭decies mutant « DEPOT_ABSENT retiré » ⇒ ⑭septies rougirait"
```

(10 assertions : ajuster le compte final de la suite — elle porte `EXPECTED_CHECKS`, relire la valeur avant/après : ⑭ en avait 8, ⑬ inchangé ; nouvelle valeur = ancienne + 2.) `nc_strict` doit accepter `/dev/stdin` : si elle prend un chemin par `sed … "$1"`, c'est bon.

- [ ] **Step 2 : `comment()` et `fail()`** — remplacer (l.111-121) :

```bash
# Un commentaire par RÔLE, sous marqueur : le statut de team-apply se REMPLACE à
# chaque passage (idempotence, ADR-081 corollaire 1). fail() écrit UN SEUL ❌ (le
# double commentaire d'antan — détaillé puis générique — est fermé, comme dans
# team-publish.sh). L'échec du commentaire est un avertissement : le verdict de
# l'apply ne dépend jamais de son rapport.
comment(){
  printf '%s\n' "$1" > "$TMP/comment.md"
  forge comment_upsert "$PR_NUMBER" '<!-- team-apply -->' "$TMP/comment.md" >/dev/null \
    || echo "AVERTISSEMENT: statut non posé sur la PR #${PR_NUMBER} (cause ci-dessus) — l'apply, lui, a rendu son verdict dans ce build" >&2
}
fail(){ comment "❌ team-apply ${TEAM:-?}/${ENVN:-?} — $*"; echo "ERREUR: $*" >&2; exit 1; }
refus(){ comment "❌ team-apply ${TEAM:-?}/${ENVN:-?} — REFUS: $*"; echo "REFUS: $*" >&2; exit 2; }
```

et sourcer `forge-api.sh` + `forge_api_init` juste après les gardes `GIT_HOST`/`GIT_REPO` (l.106-108). Sur le chemin ❌ du §4 (l.505-506), garder **un seul** appel : `fail "onboarding EN ÉCHEC : ${SUMMARY:-voir le build}. Re-run possible : tout est idempotent (${REPO_NOTE})"`.

- [ ] **Step 3 : la nouvelle section 2** — remplacer tout le bloc l.187-424 (« dépôt Gitea (idempotent ; token org-admin lu dans Vault) » jusqu'à la fin des hooks) par :

```bash
# ── 2. le dépôt d'équipe : LU, jamais créé (D10 profond, ADR-099) ────────────
# Le client crée le dépôt VIDE, son webhook vers team-publish et la protection de
# sa branche par défaut (prérequis de forge, ENVIRONNEMENTS.md § Prérequis côté
# client). Ici : repo_get par l'autorité de forge, sous le secret de forge
# ORDINAIRE (le jeton org-admin lu dans Vault n'existe plus), puis trois états :
#   absent            -> REFUS DEPOT_ABSENT (nommé sur la PR, rien de poussé) ;
#   existant ET vide   -> squelette ADR-076 poussé sur la HEAD que la forge annonce,
#                        sinon la branche de base de la plateforme ;
#   existant NON vide  -> déjà initialisé, étape sautée (idempotence : un re-run
#                        après un échec d'onboarding ne doit jamais refuser ici).
# Le parse est fail-closed dans l'autorité : un 200 sans champ « vide » lisible
# est un refus, jamais « non vide » par défaut.
GIT_REPO="$REPO_FULL" forge_kv DEPOT repo_get \
  || fail "lecture du dépôt d'équipe ${REPO_FULL} sur la forge (cause ci-dessus)"
PUSH_SKELETON=0
if [ "$DEPOT_EXISTS" != 1 ]; then
  refus "DEPOT_ABSENT : le dépôt ${REPO_FULL} n'existe pas sur ${GIT_HOST} (ou n'est pas visible pour ce jeton) — le client le crée VIDE, avec son webhook vers team-publish et la protection de sa branche par défaut (prérequis D10, ENVIRONNEMENTS.md § Prérequis côté client), puis rejoue ce merge. Rien n'a été poussé."
elif [ "$DEPOT_EMPTY" = 1 ]; then
  PUSH_SKELETON=1
  SKEL_BRANCH="${DEPOT_DEFAULT_BRANCH:-$GIT_BASE}"
  REPO_NOTE="dépôt ${REPO_FULL} : vide, squelette ADR-076 poussé sur ${SKEL_BRANCH}"
else
  REPO_NOTE="dépôt ${REPO_FULL} : déjà initialisé, étape sautée (idempotence)"
fi
if [ "$PUSH_SKELETON" = 1 ]; then
  SK="$TMP/skel"; mkdir -p "$SK"
  cp -R clients/_example/. "$SK/"
  printf '# %s\n\nDépôt d équipe (squelette ADR-076 : apis/, applications/).\nInitialisé par team-apply au merge de la PR #%s.\n' "$REPO_FULL" "$PR_NUMBER" > "$SK/README.md"
  git -C "$SK" init -q -b "$SKEL_BRANCH" && git -C "$SK" add -A \
    && git -C "$SK" -c user.name=ci -c user.email=ci@stoa.lab commit -qm "squelette ADR-076 (team-apply, PR #${PR_NUMBER})"
  # Le push passe par l'enveloppe de l'autorité git (login du visage, secret de
  # forge ordinaire, jamais en argv) — c'est le porteur de FORGE_SECRET qui
  # initialise le dépôt ; sur GitLab il doit être Developer sur le projet.
  ggit -C "$SK" push -q "${GIT_HOST}/${REPO_FULL}.git" "$SKEL_BRANCH" 2>"$TMP/pe" \
    || { cat "$TMP/pe" >&2; fail "push du squelette dans ${REPO_FULL} (dépôt vide : le porteur du secret de forge doit pouvoir y écrire)"; }
fi
REPO_LINK=""
[ -n "${DEPOT_URL:-}" ] && REPO_LINK=" ([${REPO_FULL}]($(forge_web_url "$DEPOT_URL")))"
```

Supprimer : le sourçage de `repo-protection.sh`, la lecture Vault `gitea-org-admin` et `$TMP/gt`, `forge_auth_write … "$TMP/ghdr"`, `gapi()`, `ORG`/`RNAME`, `PROT_*`, `WEBHOOK_*`, l'ancien `REPO_LINK` composé. Vérifier que `ggit` reste défini (l.102) et que le sourçage de `git-base.sh` précède.

- [ ] **Step 4 : `test-generate-choices.sh`** — ses pins (l.326-332) lisent le bloc entre `comment "✅ team-apply` et le `fail` ; adapter la borne au nouveau texte : `sed -n '/comment "✅ team-apply/,/^fi$/p'` et relire `REFRESH_NOTE` dans ce bloc (les assertions « pas de fail dans le bloc » et « REFRESH_NOTE atteint le ✅ » restent vraies).

- [ ] **Step 5 : vérifier** — porte VERTE ; `bash scripts/test-palier-retention.sh` ; `bash scripts/test-generate-choices.sh` ; `bash scripts/test-team-apply-wiring.sh` (si une ancre casse : demander le fichier entier) ; `bash scripts/test-git-base.sh` (H bis : `ggit` enveloppe le push, la découverte n'est plus faite ici) ; `shellcheck -x scripts/team-apply.sh` ; `make lint-ci` 20/20.

- [ ] **Step 6 : commit** — `git add scripts/team-apply.sh scripts/test-palier-retention.sh scripts/test-generate-choices.sh ci/lint-forge-literals.sh && git commit -m "feat(team-apply): D10 — le dépôt d'équipe est lu (repo_get), DEPOT_ABSENT refusé, squelette poussé dans un dépôt vide ; plus d'org, de hook, de protection ni de jeton org-admin"`

### Task 11 : `scripts/setup-team-repos.sh` — l'outil de poste du lab, deux visages ; suites live adaptées

**Files:**
- Create: `scripts/setup-team-repos.sh`, `scripts/test-setup-team-repos.sh`
- Modify: `scripts/test-team-onboarding-chain.sh` (préambule de la preuve 5, assertion « 404→200 » → « vide→squelette », preuve 6, nouvelle preuve « DEPOT_ABSENT »), `scripts/test-producer-chain.sh:714-777` (pré-création avant l'onboarding)
- Modify: `Makefile` (nouvelle suite sous l'étape 2 + liste shellcheck), `ci/lint-forge-literals.sh` (déjà exempté)

**Interfaces:**
- Produces: `setup-team-repos.sh <owner/repo> [--print] [--no-hook] [--no-protect]` — knobs `FORGE_KIND`, `GIT_HOST`, `FORGE_SECRET` (Gitea : `write:organization,write:repository` ; GitLab : PAT `api` Owner du groupe), `TEAM_PUBLISH_WEBHOOK_URL` (défaut `http://jenkins:8080/generic-webhook-trigger/invoke?token=stoa-team-publish`), `WEBHOOK_KIND` (gwt|gitlab : forme du hook), `GIT_BASE` (branche à protéger, défaut `main`). Sorties `--print` : `MODE=print HOST= KIND= REPO= HOOK= PROTECT=` ; refus `REPO_REQUIS`, `SECRET_FORGE_REQUIS`, `FORGE_KIND_INCONNU`, `CREATION_ECHEC : … (HTTP n)`.

- [ ] **Step 1 : la porte hors ligne (rouge)** — `scripts/test-setup-team-repos.sh` :

```bash
#!/usr/bin/env bash
# test-setup-team-repos.sh — l'outil de POSTE qui pré-crée les dépôts d'équipe du
# lab (D10 : la chaîne ne les crée plus). Hors ligne : --print, refus nommés,
# shellcheck, deux visages dans le --print, aucun réseau.
# shellcheck disable=SC2015
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO" || exit 2
T=scripts/setup-team-repos.sh
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }; ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
EXPECTED_CHECKS=8
[ -x "$T" ] && ok "1 l'outil existe et est exécutable" || ko "1 $T absent"
shellcheck -x "$T" >/dev/null 2>&1 && ok "2 shellcheck propre" || ko "2 shellcheck"
OUT=$(env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitea GIT_HOST=http://127.0.0.1:1 FORGE_SECRET=x bash "$T" fbi/apis --print 2>&1); RC=$?
[ "$RC" = 0 ] && grep -q '^KIND=gitea$' <<<"$OUT" && grep -q '^REPO=fbi/apis$' <<<"$OUT" && grep -q '^HOOK=http://jenkins:8080/generic-webhook-trigger/invoke?token=stoa-team-publish$' <<<"$OUT" \
  && ok "3 --print gitea : KIND/REPO/HOOK, sans réseau (hôte mort)" || ko "3 rc $RC : $(head -3 <<<"$OUT" | tr '\n' ' ')"
OUT=$(env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitlab WEBHOOK_KIND=gitlab GIT_HOST=http://127.0.0.1:1 FORGE_SECRET=x bash "$T" ci/fbi-apis --print 2>&1); RC=$?
[ "$RC" = 0 ] && grep -q '^KIND=gitlab$' <<<"$OUT" && grep -q '^HOOK=http://jenkins:8080/project/team-publish$' <<<"$OUT" && grep -q '^PROTECT=main (access_level 40, allow_force_push false)$' <<<"$OUT" \
  && ok "4 --print gitlab : hook de projet (WEBHOOK_KIND=gitlab) et protection par rôle" || ko "4 rc $RC : $(head -3 <<<"$OUT" | tr '\n' ' ')"
OUT=$(env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitea GIT_HOST=http://127.0.0.1:1 bash "$T" fbi/apis --print 2>&1); RC=$?
[ "$RC" = 2 ] && grep -q 'SECRET_FORGE_REQUIS' <<<"$OUT" && ok "5 sans secret ⇒ SECRET_FORGE_REQUIS (même en --print : l'outil ne ment pas sur ce qu'il faudra)" || ko "5 rc $RC : $(head -1 <<<"$OUT")"
OUT=$(env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitea GIT_HOST=http://127.0.0.1:1 FORGE_SECRET=x bash "$T" --print 2>&1); RC=$?
[ "$RC" = 2 ] && grep -q 'REPO_REQUIS' <<<"$OUT" && ok "6 sans dépôt ⇒ REPO_REQUIS" || ko "6 rc $RC"
OUT=$(env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=bitbucket GIT_HOST=http://127.0.0.1:1 FORGE_SECRET=x bash "$T" a/b --print 2>&1); RC=$?
[ "$RC" = 2 ] && grep -q 'FORGE_KIND_INCONNU' <<<"$OUT" && ok "7 visage inconnu ⇒ FORGE_KIND_INCONNU" || ko "7 rc $RC"
OUT=$(env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitea GIT_HOST=http://127.0.0.1:1 FORGE_SECRET=x bash "$T" fbi/apis 2>&1); RC=$?
[ "$RC" != 0 ] && grep -qE 'injoignable|CREATION_ECHEC|REPO_GET' <<<"$OUT" && ok "8 hôte mort sans --print ⇒ refus nommé, jamais un vert" || ko "8 rc $RC : $(head -1 <<<"$OUT")"
TOTAL=$((PASS+FAIL)); [ "$TOTAL" -eq "$EXPECTED_CHECKS" ] && ok "total $EXPECTED_CHECKS" || ko "total $TOTAL ≠ $EXPECTED_CHECKS"
printf 'RÉSULTAT : %d/%d\n' "$PASS" $((PASS+FAIL)); [ "$FAIL" -eq 0 ]
```

`bash scripts/test-setup-team-repos.sh` ⇒ rouge (outil absent).

- [ ] **Step 2 : l'outil** — `scripts/setup-team-repos.sh` :

```bash
#!/usr/bin/env bash
# scripts/setup-team-repos.sh — OUTIL DE POSTE du lab : pré-crée un dépôt d'équipe
# VIDE sur la forge, son webhook vers team-publish et la protection de sa branche
# par défaut — les trois gestes que la chaîne NE FAIT PLUS (D10 profond, ADR-099 :
# chez le client, c'est le client). Deux visages. Idempotent. Hors chaîne :
# exempté nommément par ci/lint-forge-literals.sh (il parle aux API de création).
#
#   FORGE_KIND=gitea  GIT_HOST=http://localhost:13000 FORGE_SECRET=<ci, write:organization,write:repository> \
#     scripts/setup-team-repos.sh <org>/<repo> [--print] [--no-hook] [--no-protect]
#   FORGE_KIND=gitlab GIT_HOST=http://localhost:13080 FORGE_SECRET=<PAT api, Owner du groupe> WEBHOOK_KIND=gitlab \
#     scripts/setup-team-repos.sh ci/<repo> [--print]
#
# Knobs : TEAM_PUBLISH_WEBHOOK_URL (défaut gwt : http://jenkins:8080/generic-webhook-trigger/invoke?token=stoa-team-publish ;
#         défaut gitlab : http://jenkins:8080/project/team-publish), WEBHOOK_KIND (gwt|gitlab), GIT_BASE (branche protégée, défaut main),
#         TEAM_PUBLISH_WEBHOOK_SECRET (Gitea : secret HMAC ; GitLab : X-Gitlab-Token), PROTECT_PUSH_WHITELIST (Gitea, défaut ci).
# Refus nommés (rc 2) : REPO_REQUIS, SECRET_FORGE_REQUIS, FORGE_KIND_INCONNU, CREATION_ECHEC, HOOK_ECHEC, PROTECTION_ECHEC.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=scripts/lib/forge-identity.sh
. scripts/lib/forge-identity.sh || { echo "ERREUR: forge-identity.sh introuvable" >&2; exit 1; }
REPO_FULL=""; MODE=apply; HOOK=1; PROTECT=1
for a in "$@"; do case "$a" in --print) MODE=print;; --no-hook) HOOK=0;; --no-protect) PROTECT=0;; -*) echo "REFUS: ARGUMENT_INCONNU : $a" >&2; exit 2;; *) REPO_FULL="$a";; esac; done
[ -n "$REPO_FULL" ] && case "$REPO_FULL" in */*) ;; *) REPO_FULL="";; esac
[ -n "$REPO_FULL" ] || { echo "REFUS: REPO_REQUIS : <owner>/<repo> attendu en argument" >&2; exit 2; }
FORGE_KIND="${FORGE_KIND:-gitea}"
case "$FORGE_KIND" in gitea|gitlab) ;; *) echo "REFUS: FORGE_KIND_INCONNU : '$FORGE_KIND' — attendu gitea ou gitlab" >&2; exit 2;; esac
GIT_HOST="${GIT_HOST:?GIT_HOST requis (base de la forge)}"
FORGE_SECRET="${FORGE_SECRET:-${GITEA_TOKEN:-}}"
[ -n "$FORGE_SECRET" ] || { echo "REFUS: SECRET_FORGE_REQUIS : FORGE_SECRET (Gitea : write:organization,write:repository ; GitLab : PAT api, Owner du groupe)" >&2; exit 2; }
WEBHOOK_KIND="${WEBHOOK_KIND:-gwt}"; GIT_BASE="${GIT_BASE:-main}"
case "$WEBHOOK_KIND" in gitlab) HOOK_URL="${TEAM_PUBLISH_WEBHOOK_URL:-http://jenkins:8080/project/team-publish}";; *) HOOK_URL="${TEAM_PUBLISH_WEBHOOK_URL:-http://jenkins:8080/generic-webhook-trigger/invoke?token=stoa-team-publish}";; esac
OWNER="${REPO_FULL%%/*}"; NAME="${REPO_FULL#*/}"
if [ "$MODE" = print ]; then
  echo "MODE=print"; echo "HOST=$GIT_HOST"; echo "KIND=$FORGE_KIND"; echo "REPO=$REPO_FULL"
  [ "$HOOK" = 1 ] && echo "HOOK=$HOOK_URL" || echo "HOOK=(non posé)"
  if [ "$PROTECT" = 1 ]; then case "$FORGE_KIND" in gitlab) echo "PROTECT=$GIT_BASE (access_level 40, allow_force_push false)";; *) echo "PROTECT=$GIT_BASE (push whitelist: ${PROTECT_PUSH_WHITELIST:-ci})";; esac; else echo "PROTECT=(non posée)"; fi
  exit 0
fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; umask 077
forge_auth_write "$FORGE_SECRET" "$TMP/hdr" || exit 2
api(){ curl -sS -m 30 -H @"$TMP/hdr" -H 'Content-Type: application/json' "$@"; }
enc(){ python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
case "$FORGE_KIND" in
  gitea)
    B="${GIT_HOST%/}/api/v1"
    hc=$(api -o /dev/null -w '%{http_code}' "$B/orgs/$OWNER") || { echo "REFUS: CREATION_ECHEC : forge injoignable ($GIT_HOST)" >&2; exit 2; }
    if [ "$hc" != 200 ]; then
      hc=$(api -X POST -d "{\"username\":\"$OWNER\"}" -o "$TMP/e" -w '%{http_code}' "$B/orgs"); { [ "$hc" = 201 ] || [ "$hc" = 200 ]; } || { echo "REFUS: CREATION_ECHEC : org $OWNER (HTTP $hc) $(head -c 200 "$TMP/e")" >&2; exit 2; }
      echo "org $OWNER : créée"
    fi
    hc=$(api -o "$TMP/r" -w '%{http_code}' "$B/repos/$REPO_FULL")
    if [ "$hc" = 404 ]; then
      hc=$(api -X POST -d "{\"name\":\"$NAME\",\"auto_init\":false,\"default_branch\":\"$GIT_BASE\"}" -o "$TMP/e" -w '%{http_code}' "$B/orgs/$OWNER/repos")
      [ "$hc" = 201 ] || { echo "REFUS: CREATION_ECHEC : dépôt $REPO_FULL (HTTP $hc) $(head -c 200 "$TMP/e")" >&2; exit 2; }
      echo "dépôt $REPO_FULL : créé VIDE (HEAD annoncée : $GIT_BASE)"
    elif [ "$hc" = 200 ]; then echo "dépôt $REPO_FULL : existe (idempotence)"
    else echo "REFUS: REPO_GET : $REPO_FULL (HTTP $hc)" >&2; exit 2; fi
    if [ "$HOOK" = 1 ]; then
      if api "$B/repos/$REPO_FULL/hooks" | grep -qF "\"url\":\"$HOOK_URL\""; then echo "hook team-publish : déjà posé"
      else
        S="${TEAM_PUBLISH_WEBHOOK_SECRET:-}"
        hc=$(api -X POST -d "{\"type\":\"gitea\",\"active\":true,\"events\":[\"pull_request\"],\"config\":{\"url\":\"$HOOK_URL\",\"content_type\":\"json\"${S:+,\"secret\":\"$S\"}}}" -o "$TMP/e" -w '%{http_code}' "$B/repos/$REPO_FULL/hooks")
        [ "$hc" = 201 ] && echo "hook team-publish : posé ($HOOK_URL)" || { echo "REFUS: HOOK_ECHEC : (HTTP $hc) $(head -c 200 "$TMP/e")" >&2; exit 2; }
      fi
    fi
    if [ "$PROTECT" = 1 ]; then
      # shellcheck source=scripts/lib/repo-protection.sh
      . scripts/lib/repo-protection.sh || exit 1
      repo_protection_payload "$GIT_BASE" "${PROTECT_PUSH_WHITELIST:-ci}" > "$TMP/prot.json" || { echo "REFUS: PROTECTION_ECHEC : payload" >&2; exit 2; }
      # la protection ne se pose que sur une branche qui EXISTE : sur un dépôt vide, elle attend le squelette
      if api "$B/repos/$REPO_FULL/branches/$GIT_BASE" -o /dev/null -w '%{http_code}' | grep -q 200; then
        pose_branch_protection "$GIT_HOST" "$TMP/hdr" "$REPO_FULL" "$TMP/prot.json" && echo "protection $GIT_BASE : posée" || { echo "REFUS: PROTECTION_ECHEC" >&2; exit 2; }
      else echo "protection $GIT_BASE : différée (branche absente — dépôt vide) : repasser après le squelette"; fi
    fi ;;
  gitlab)
    B="${GIT_HOST%/}/api/v4"; P=$(enc "$REPO_FULL")
    hc=$(api -o "$TMP/g" -w '%{http_code}' "$B/groups/$(enc "$OWNER")") || { echo "REFUS: CREATION_ECHEC : forge injoignable ($GIT_HOST)" >&2; exit 2; }
    [ "$hc" = 200 ] || { echo "REFUS: CREATION_ECHEC : groupe $OWNER introuvable (HTTP $hc) — le groupe est un prérequis (setup-gitlab-lab.sh crée ci)" >&2; exit 2; }
    GID=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["id"])' "$TMP/g")
    hc=$(api -o "$TMP/r" -w '%{http_code}' "$B/projects/$P")
    if [ "$hc" = 404 ]; then
      hc=$(api -X POST -d "{\"name\":\"$NAME\",\"path\":\"$NAME\",\"namespace_id\":$GID,\"visibility\":\"private\",\"initialize_with_readme\":false,\"merge_method\":\"merge\",\"default_branch\":\"$GIT_BASE\"}" -o "$TMP/e" -w '%{http_code}' "$B/projects")
      [ "$hc" = 201 ] || { echo "REFUS: CREATION_ECHEC : projet $REPO_FULL (HTTP $hc) $(head -c 200 "$TMP/e")" >&2; exit 2; }
      echo "projet $REPO_FULL : créé VIDE, privé, merge_method=merge"
    elif [ "$hc" = 200 ]; then echo "projet $REPO_FULL : existe (idempotence)"
    else echo "REFUS: REPO_GET : $REPO_FULL (HTTP $hc)" >&2; exit 2; fi
    if [ "$HOOK" = 1 ]; then
      if api "$B/projects/$P/hooks" | grep -qF "\"url\":\"$HOOK_URL\""; then echo "hook team-publish : déjà posé"
      else
        S="${TEAM_PUBLISH_WEBHOOK_SECRET:-}"
        hc=$(api -X POST -d "{\"url\":\"$HOOK_URL\",\"merge_requests_events\":true,\"push_events\":false,\"enable_ssl_verification\":false${S:+,\"token\":\"$S\"}}" -o "$TMP/e" -w '%{http_code}' "$B/projects/$P/hooks")
        [ "$hc" = 201 ] && echo "hook team-publish : posé ($HOOK_URL, merge_requests_events)" || { echo "REFUS: HOOK_ECHEC : (HTTP $hc) $(head -c 200 "$TMP/e")" >&2; exit 2; }
      fi
    fi
    if [ "$PROTECT" = 1 ]; then
      hc=$(api -o /dev/null -w '%{http_code}' "$B/projects/$P/protected_branches/$(enc "$GIT_BASE")")
      if [ "$hc" = 200 ]; then echo "protection $GIT_BASE : déjà posée"
      else
        hc=$(api -X POST -d "{\"name\":\"$GIT_BASE\",\"push_access_level\":40,\"merge_access_level\":40,\"allow_force_push\":false}" -o "$TMP/e" -w '%{http_code}' "$B/projects/$P/protected_branches")
        [ "$hc" = 201 ] && echo "protection $GIT_BASE : posée (par RÔLE — GitLab CE n'a pas la protection nominative)" || { echo "REFUS: PROTECTION_ECHEC : (HTTP $hc) $(head -c 200 "$TMP/e")" >&2; exit 2; }
      fi
    fi ;;
esac
echo "OK — $REPO_FULL prêt pour team-apply (vide ou initialisé), hook et protection selon les options"
```

`chmod +x scripts/setup-team-repos.sh`.

- [ ] **Step 3 : vérifier GREEN** — `bash scripts/test-setup-team-repos.sh` 9/9 ; `shellcheck -x scripts/setup-team-repos.sh`. Sur le lab : `FORGE_KIND=gitea GIT_HOST=http://localhost:13000 FORGE_SECRET=<jeton ci> scripts/setup-team-repos.sh fbi-l5/apis` puis `--print` ; sur GitLab avec le PAT de `.env.gitlab-lab`.

- [ ] **Step 4 : Makefile** — sous l'étape 2 (près de `test-setup-provision-jobs.sh`, l.197) : `@bash scripts/test-setup-team-repos.sh` avec un commentaire « D10 : l'outil de poste qui pré-crée ce que la chaîne ne crée plus » ; ajouter `scripts/setup-team-repos.sh scripts/test-setup-team-repos.sh` à la liste shellcheck du rang 2.

- [ ] **Step 5 : suites live** — `test-team-onboarding-chain.sh` : avant la preuve 5, pré-créer : `FORGE_KIND=gitea GIT_HOST="$GITEA_URL" FORGE_SECRET="$GITEA_TOKEN" GIT_BASE=main bash scripts/setup-team-repos.sh "$TEAM/apis" --no-protect >"$TMP/pre5.log" 2>&1 || bad "pré-création $TEAM/apis"` ; remplacer `[ "$REPO_BEFORE" != 200 ] && [ "$REPO_AFTER" = 200 ]` par `[ "$REPO_BEFORE" = 200 ] && [ "$(gapi "$GITEA_URL/api/v1/repos/$TEAM/apis" | python3 -c 'import json,sys;print(json.load(sys.stdin)["empty"])')" = False ]` (vide avant, squelette après) et le libellé « dépôt $TEAM/apis vide→squelette » ; preuve 6 : « déjà initialisé » au lieu de « déjà existant » (`grep -q 'déjà initialisé'`) ; nouvelle preuve **5bis** avant la pré-création (équipe jetable `$TEAM-absent` : `team-apply.sh` en direct sur un dépôt non créé ⇒ rc 2, `DEPOT_ABSENT` dans le log et dans le dernier commentaire de la PR, `gapi … /repos/$TEAM-absent/apis` ⇒ 404 inchangé) ; teardown : rien de plus (l'org et le dépôt sont déjà supprimés). `test-producer-chain.sh` : dans le pré-requis d'onboarding (l.714-777), même pré-création avant de merger la PR d'onboarding. Ces deux suites se jouent à la main (`GITEA_URL`, `GITEA_TOKEN` avec `write:organization`).

- [ ] **Step 6 : commit** — `git add scripts/setup-team-repos.sh scripts/test-setup-team-repos.sh scripts/test-team-onboarding-chain.sh scripts/test-producer-chain.sh Makefile && git commit -m "feat(lab): setup-team-repos.sh — l'outil de poste qui pré-crée les dépôts d'équipe (deux visages) ; les matrices Gitea pré-créent et prouvent DEPOT_ABSENT"`

### Task 12 : `setup-repo-protections.sh` et `seed-governance-chain.sh` — alias, visage, `raw`

**Files:**
- Modify: `scripts/setup-repo-protections.sh:143-145`
- Modify: `scripts/seed-governance-chain.sh:44-45`, `:66-70`, `:98`
- Test: `scripts/test-palier-retention.sh` (⑰ `--print` inchangé), `scripts/test-git-base.sh` (H bis : seed exempté nommément — vérifier que l'exemption cite encore le bon mécanisme)

- [ ] **Step 1 : épreuve rouge** — dans `test-palier-retention.sh`, après ⑰ :

```bash
OUT=$(env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitlab GIT_HOST=http://127.0.0.1:1 FORGE_SECRET=x bash scripts/setup-repo-protections.sh 2>&1); RC=$?
[ "$RC" = 2 ] && grep -q 'PROTECTION_GITEA_SEULEMENT' <<<"$OUT" && ok "⑰ter FORGE_KIND=gitlab ⇒ PROTECTION_GITEA_SEULEMENT (la protection nominative est un prérequis de forge chez un client GitLab)" || ko "⑰ter rc $RC : $(head -1 <<<"$OUT")"
OUT=$(env -i PATH="$PATH" HOME="$HOME" FORGE_SECRET=x GIT_HOST=http://127.0.0.1:1 bash scripts/setup-repo-protections.sh 2>&1); RC=$?
grep -q 'GITEA_TOKEN: FORGE_SECRET requis' <<<"$OUT" && ko "⑰quater l'alias FORGE_SECRET est mort (FORGE_SECRET seul ⇒ « GITEA_TOKEN: … requis »)" || ok "⑰quater FORGE_SECRET seul suffit (alias vivant)"
```

(+2 à `EXPECTED_CHECKS`.)

- [ ] **Step 2 : implémenter** — `setup-repo-protections.sh` : remplacer l.143-144 par

```bash
FORGE_SECRET="${FORGE_SECRET:-${GITEA_TOKEN:-}}"
[ -n "$FORGE_SECRET" ] || { echo "REFUS: SECRET_FORGE_REQUIS : ni FORGE_SECRET ni son alias GITEA_TOKEN (write:repository sur les dépôts visés) — ou --print pour voir ce qui serait posé" >&2; exit 2; }
case "${FORGE_KIND:-gitea}" in
  gitea) ;;
  *) echo "REFUS: PROTECTION_GITEA_SEULEMENT : cet outil pose la protection NOMINATIVE de Gitea (push whitelist, patterns — ADR-082 §3) ; sur ${FORGE_KIND}, la protection de branche est un prérequis de forge posé par le client (par rôle en CE) — voir ENVIRONNEMENTS.md § Prérequis côté client" >&2; exit 2 ;;
esac
```

(placer la vérification de visage **avant** la garde du secret pour que `--print` reste jouable ? Non : `--print` sort plus haut, l.126/140.) `seed-governance-chain.sh` : l.44-45 même forme canonique ; l.98 : remplacer le `curl -s -H "$AUTH" "$GIT_HOST/$GIT_REPO/raw/branch/main/environments.yaml"` par `. scripts/lib/forge-api.sh && forge_api_init && RAW=$(forge raw environments.yaml)` (HEAD, plus de `main` en dur), en gardant `GIT_REPO` déjà posé (:38-39).

- [ ] **Step 3 : vérifier** — `bash scripts/test-palier-retention.sh` ; `bash scripts/test-git-base.sh` ; `shellcheck -x` des deux ; `bash ci/lint-branch-literals.sh` (le `main` en dur de seed :98 disparaît — si l'exemption de seed y est nommée pour cette ligne, la retirer).

- [ ] **Step 4 : commit** — `git add scripts/setup-repo-protections.sh scripts/seed-governance-chain.sh scripts/test-palier-retention.sh && git commit -m "fix(outils): alias FORGE_SECRET vivant dans les deux outils, refus PROTECTION_GITEA_SEULEMENT, read-back du seed par forge raw"`

---

## Sous-lot 4 — `archive-store` à deux visages

### Task 13 : `_as_url` à deux branches, `ARCHIVE_STORE_PROJECT`, projet `ci/archives` au lab

**Files:**
- Modify: `scripts/lib/archive-store.sh:42-45`, `:49`, `:78`
- Modify: `scripts/test-archive-store.sh` (stub : route GitLab ; cas ⑫ ⑬ ; `EXPECTED_ASSERTIONS`)
- Modify: `scripts/setup-gitlab-lab.sh` (projet `ci/archives`), `scripts/setup-jenkins-globals.sh` (`ARCHIVE_STORE_PROJECT` dans CONNUES et OPTIONNELLES + bloc de doc), `ci/lint-config-knobs.exempt` si le knob y est requis

**Interfaces:**
- Produces: `_as_url <team> <api> <sha>` : gitea `${GIT_HOST}/api/packages/${ARCHIVE_STORE_OWNER:-ci}/generic/promote--<team>--<api>/<sha>/archive.zip` ; gitlab `${GIT_HOST}/api/v4/projects/<ARCHIVE_STORE_PROJECT enc>/packages/generic/promote--<team>--<api>/<sha>/archive.zip` ; refus `ARCHIVE_STORE_PROJECT_REQUIS` sous gitlab sans knob (avant tout réseau).

- [ ] **Step 1 : épreuves rouges** — dans `test-archive-store.sh`, le stub sert déjà `GET/PUT <chemin>` quel que soit le préfixe ? Vérifier son routage : s'il compare le chemin à `url_path`, ajouter une seconde fonction `url_path_gl() { printf '/api/v4/projects/ci%%2Farchives/packages/generic/promote--%s--%s/%s/archive.zip' "$1" "$2" "$3"; }` et faire accepter les deux préfixes par le stub. Puis :

```bash
echo "== ⑫ visage gitlab : l'URL est adressée PAR PROJET (ARCHIVE_STORE_PROJECT), PUT 201 =="
P12="$(url_path_gl deux beta "$SHA")"
RC="$(run "$TMP/c12.out" env GITEA_TOKEN=x FORGE_KIND=gitlab ARCHIVE_STORE_PROJECT=ci/archives GIT_HOST="$GIT_HOST" bash -c '. "$1"; archive_store_push "$2" deux beta' _ "$LIB" "$PAYLOAD")"
[ "$RC" -eq 0 ] && grep -q "ARCHIVE_STORE_PUSHED sha256=$SHA" "$TMP/c12.out" && [ "$(putcount "$P12")" = 1 ] \
  && ok "⑫ gitlab : PUT sur /api/v4/projects/ci%2Farchives/packages/generic/… (1 PUT)" || bad "⑫ rc $RC put=$(putcount "$P12") : $(cat "$TMP/c12.out")"
grep -q 'PRIVATE-TOKEN' "$STUB_LOG" && ok "⑫bis l'en-tête est PRIVATE-TOKEN (dérivé du visage par forge_auth_write)" || bad "⑫bis en-tête non dérivé du visage"
echo "== ⑬ visage gitlab sans ARCHIVE_STORE_PROJECT : refus AVANT tout réseau =="
L0="$(loglines)"
RC="$(run "$TMP/c13.out" env GITEA_TOKEN=x FORGE_KIND=gitlab GIT_HOST="$GIT_HOST" bash -c '. "$1"; archive_store_push "$2" deux beta' _ "$LIB" "$PAYLOAD")"
[ "$RC" -ne 0 ] && grep -q 'ARCHIVE_STORE_PROJECT_REQUIS' "$TMP/c13.out" && [ "$(loglines)" = "$L0" ] \
  && ok "⑬ ARCHIVE_STORE_PROJECT_REQUIS, aucun appel réseau" || bad "⑬ rc $RC : $(cat "$TMP/c13.out")"
```

Le stub doit journaliser les en-têtes (`PRIVATE-TOKEN`) : s'il ne le fait pas, ajouter au journal la présence de `Authorization`/`PRIVATE-TOKEN` (comme le mock de test-forge-api). `EXPECTED_ASSERTIONS` 24 → 27.

- [ ] **Step 2 : vérifier RED** — ⑫ rouge (URL Gitea), ⑬ rouge (pas de refus).

- [ ] **Step 3 : implémenter** :

```bash
_as_url() {        # <team> <api> <sha> — l'URL canonique du contenu, selon le VISAGE
  # Gitea : registre par PROPRIÉTAIRE ; GitLab : registre par PROJET (chemin URL-encodé).
  case "${FORGE_KIND:-gitea}" in
    gitlab)
      [ -n "${ARCHIVE_STORE_PROJECT:-}" ] || { _as_fail "ARCHIVE_STORE_PROJECT_REQUIS : sous GitLab le registre générique est PAR PROJET — poser ARCHIVE_STORE_PROJECT=<groupe>/<projet> (au lab : ci/archives)"; return 1; }
      printf '%s/api/v4/projects/%s/packages/generic/promote--%s--%s/%s/archive.zip' \
        "${GIT_HOST:?GIT_HOST requis}" "$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$ARCHIVE_STORE_PROJECT")" "$1" "$2" "$3" ;;
    *)
      printf '%s/api/packages/%s/generic/promote--%s--%s/%s/archive.zip' \
        "${GIT_HOST:?GIT_HOST requis}" "${ARCHIVE_STORE_OWNER:-ci}" "$1" "$2" "$3" ;;
  esac
}
```

et dans `archive_store_push`/`archive_store_fetch` : `url="$(_as_url …)" || return 1` (le refus du knob sort avant la sonde). Retirer le défaut `http://gitea:3000` (l.44) : `GIT_HOST` est requis (comme partout depuis L3). Vérifier `test-archive-store` ① à ⑪ (ils posent `GIT_HOST`).

- [ ] **Step 4 : le lab** — `setup-gitlab-lab.sh` : après le projet `ci/stoa-labs`, créer `ci/archives` (privé, `initialize_with_readme=false`) s'il n'existe pas, idempotent ; `setup-jenkins-globals.sh` : `ARCHIVE_STORE_PROJECT` dans `CONNUES` et `OPTIONNELLES` + bloc de doc (« GitLab seulement : registre par projet ; Gitea ignore ce knob ») ; poser la globale du lab `ARCHIVE_STORE_PROJECT=ci/archives`.

- [ ] **Step 5 : vérifier** — `bash scripts/test-archive-store.sh` 28/28 ; `bash scripts/test-promote-sans-recopie.sh` ; `bash scripts/test-parity-moteurs.sh` ; `bash ci/lint-forge-literals.sh` (A.2 : archive-store ne porte que `/api/packages` — le `api/v4` de la branche gitlab est un motif ! ⇒ étendre A.2 : la seconde autorité a droit à `/api/packages` **et** `api/v4/projects/…/packages`) ; `make lint-ci`.

- [ ] **Step 6 : commit** — `git add scripts/lib/archive-store.sh scripts/test-archive-store.sh scripts/setup-gitlab-lab.sh scripts/setup-jenkins-globals.sh ci/lint-forge-literals.sh && git commit -m "feat(archive-store): deux visages — registre par projet sous GitLab (ARCHIVE_STORE_PROJECT), par propriétaire sous Gitea ; ci/archives au lab"`

---

## Sous-lot 5 — preuve GitLab

### Task 14 : `test-forge-api-live.sh` — `repo_get`, `raw` sans ref, liens

**Files:**
- Modify: `scripts/test-forge-api-live.sh`

- [ ] **Step 1 : ajouter**, pour chaque forge du lab (Gitea 13000, GitLab 13080), après les verbes existants :

```bash
  fx repo_get; [ "$(rc)" = 0 ] && [ "$(val EXISTS)" = 1 ] && [ "$(val EMPTY)" = 0 ] && [ -n "$(val DEFAULT_BRANCH)" ] && ok "$K repo_get ci/stoa-labs ⇒ EXISTS=1 EMPTY=0 DEFAULT_BRANCH=$(val DEFAULT_BRANCH)" || ko "$K repo_get : $(cause)"
  GIT_REPO=ci/inexistant-$$ fx repo_get; [ "$(rc)" = 0 ] && [ "$(val EXISTS)" = 0 ] && ok "$K repo_get dépôt inexistant ⇒ EXISTS=0 rc 0" || ko "$K repo_get inexistant : rc $(rc) $(cause)"
  fx raw poc-control-plane-federation/ENVIRONNEMENTS.md; [ "$(rc)" = 0 ] && [ -s "$TMP/out" ] && ok "$K raw sans ref ⇒ HEAD (octets : $(wc -c < "$TMP/out"))" || ko "$K raw sans ref : $(cause)"
  fx pr_get 1 2>/dev/null; [ "$(rc)" = 0 ] && case "$(val URL)" in http*) ok "$K pr_get rend une URL absolue (base de forge_web_url)";; *) ko "$K URL=$(val URL)";; esac
```

(`fx` est l'enveloppe existante sous `env -i` ; `GIT_REPO=…` la surcharge.) Sur le GitLab du lab, un projet vide `ci/vide-l5` peut être créé par `setup-team-repos.sh` pour prouver `EMPTY=1` puis supprimé par curl DELETE dans le nettoyage.

- [ ] **Step 2 : jouer** — `GITEA_URL=http://localhost:13000 GITLAB_URL=http://localhost:13080 bash scripts/test-forge-api-live.sh` avec les secrets du lab (Gitea : jeton `ci` jetable minté par `gitea admin user generate-access-token` puis révoqué ; GitLab : `.env.gitlab-lab`).

- [ ] **Step 3 : commit** — `git add scripts/test-forge-api-live.sh && git commit -m "test(forge-live): repo_get, raw sans ref et URL absolue prouvés sur les deux forges du lab"`

### Task 15 : `test-producer-chain-gitlab.sh` — la matrice producteur en direct sur GitLab

**Files:**
- Create: `scripts/test-producer-chain-gitlab.sh`
- Modify: `Makefile` (liste shellcheck du rang 2 seulement : suite live, jamais exécutée par lint-ci)

**Interfaces:**
- Consumes: `setup-team-repos.sh` (Task 11), les scripts routés (Tasks 6-10), `archive-store` (Task 13), le mock webMethods du lab (`WM_GATEWAY_URL`), Vault du lab (`VAULT_ADDR`, `VAULT_TOKEN_FILE`).
- Produces: PASS/FAIL par preuve, teardown symétrique, aucun secret en argv (sondage `ps -Aww`).

- [ ] **Step 1 : squelette et prérequis** :

```bash
#!/usr/bin/env bash
# test-producer-chain-gitlab.sh — LA CHAÎNE PRODUCTEUR EN DIRECT SUR LE GITLAB CE
# RÉEL DU LAB (L5 phase 2). Les scripts sont joués DIRECTEMENT (pas par Jenkins :
# les récepteurs team-* à deux visages sont L6 phase 2), les MR sont mergées par
# l'API, l'apply post-merge est joué sur le SHA mergé. Dépôts d'équipe PRÉ-CRÉÉS
# par setup-team-repos.sh (D10). Cibles OBLIGATOIRES, sans défaut :
#   GITLAB_URL (http://localhost:13080) · GITLAB_TOKEN_FILE (fichier 0600, PAT api du lab : .env.gitlab-lab)
#   VAULT_ADDR · VAULT_TOKEN_FILE · WM_GATEWAY_URL (le MOCK, jamais 5555) · GIT_REPO (ci/stoa-labs)
# Preuves :
#   0  prérequis : GitLab joignable, projet plateforme privé (info/refs anonyme ⇒ 401), merge_method=merge, ci/archives présent
#   1  team-request.sh en direct ⇒ MR sur le dépôt plateforme, commentée <!-- team-request-plan --> ✅
#   2  merge par l'API ⇒ team-apply.sh en direct sur le SHA mergé, dépôt PRÉ-CRÉÉ vide ⇒ squelette poussé, ✅ <!-- team-apply -->
#   2b contre-épreuve : team-apply.sh sur un dépôt NON créé ⇒ rc 2, DEPOT_ABSENT sur la PR, rien de poussé
#   3  api-request.sh ⇒ MR sur le dépôt d'équipe, commentée <!-- api-request -->
#   4  merge par l'API ⇒ team-publish.sh en direct ⇒ API vue sur le mock, ✅ sur la MR (lien -/merge_requests/)
#   5  api-promote-export.sh ⇒ archive au registre ci/archives (PUT 201), MR d'épinglage ; rejeu ⇒ MR retrouvée (pr_find_open), pas de doublon
#   6  api-promote-request.sh ⇒ MR de promotion ; merge ⇒ team-promote.sh en direct ⇒ archive rapatriée par digest
#   7  discriminant : FORGE_KIND=gitea contre ce GitLab ⇒ refus nommé « REDIRIGE vers /users/sign_in »
#   8  sondage ps -Aww pendant 1-6 : aucun secret en argv (contrôle positif : du trafic git observé)
#   9  teardown symétrique : projets d'équipe supprimés (404 exact), MR fermées, paquets supprimés, Vault/KV nettoyés
# shellcheck disable=SC2015,SC2016
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO" || exit 2
: "${GITLAB_URL:?GITLAB_URL requis (ex. http://localhost:13080)}" "${GITLAB_TOKEN_FILE:?GITLAB_TOKEN_FILE requis (fichier 0600)}"
: "${VAULT_ADDR:?}" "${VAULT_TOKEN_FILE:?}" "${WM_GATEWAY_URL:?le MOCK webMethods, jamais 5555}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"; TS=$(date +%s); TEAM="l5gl${TS: -6}"; TEAM_REPO="ci/${TEAM}-apis"; API_NAME="demo-${TEAM}"
export FORGE_KIND=gitlab GIT_HOST="$GITLAB_URL" GIT_WEB_HOST="$GITLAB_URL" FORGE_SECRET_FILE="$GITLAB_TOKEN_FILE" ARCHIVE_STORE_PROJECT=ci/archives
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }; bad(){ FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
TMP=$(mktemp -d); umask 077
. scripts/lib/forge-api.sh; forge_api_init || exit 2
gl(){ curl -s -H @"$TMP/hdr" -H 'Content-Type: application/json' "$@"; }   # l'API DIRECTE n'est utilisée QUE pour merger, lire et nettoyer (harnais)
forge_auth_write "$(tr -d '\r\n' < "$GITLAB_TOKEN_FILE")" "$TMP/hdr"
enc(){ python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
merge_mr(){ # <projet> <iid> → merge_commit_sha
  local p; p=$(enc "$1")
  for _ in $(seq 1 30); do gl "$GITLAB_URL/api/v4/projects/$p/merge_requests/$2" | grep -q '"detailed_merge_status":"mergeable"' && break; sleep 1; done
  gl -X PUT "$GITLAB_URL/api/v4/projects/$p/merge_requests/$2/merge" -o "$TMP/merge.json" -w '%{http_code}' | grep -q 200 || return 1
  python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["merge_commit_sha"])' "$TMP/merge.json"
}
teardown(){ # symétrique, appelé par la preuve 9 et par le trap
  gl -X DELETE -o /dev/null "$GITLAB_URL/api/v4/projects/$(enc "$TEAM_REPO")"
  gl -X DELETE -o /dev/null "$GITLAB_URL/api/v4/projects/$(enc "${TEAM_REPO}-absent")" 2>/dev/null
  # les MR du dépôt plateforme ouvertes par la suite : fermées, branches supprimées
  for b in "onboard/${TEAM}-dev"; do gl -X DELETE -o /dev/null "$GITLAB_URL/api/v4/projects/$(enc "$GIT_REPO")/repository/branches/$(enc "$b")"; done
}
trap 'teardown; rm -rf "$TMP"' EXIT
```

- [ ] **Step 2 : preuves 0 à 2b** (écrire dans l'ordre ; chaque preuve `ok`/`bad`, jamais vraie par vacuité) :

```bash
echo "== 0. prérequis =="
hc=$(curl -s -o /dev/null -w '%{http_code}' "$GITLAB_URL/$GIT_REPO.git/info/refs?service=git-upload-pack")
[ "$hc" = 401 ] && ok "0.1 le dépôt plateforme est PRIVÉ (info/refs anonyme ⇒ 401) — le vrai cas client" || bad "0.1 info/refs anonyme ⇒ $hc (dépôt public : la preuve ne prouverait pas l'authentification)"
gl "$GITLAB_URL/api/v4/projects/$(enc "$GIT_REPO")" | grep -q '"merge_method":"merge"' && ok "0.2 merge_method=merge (merge_commit_sha non nul)" || bad "0.2 merge_method ≠ merge"
GIT_REPO=ci/archives forge_kv AR repo_get && [ "$AR_EXISTS" = 1 ] && ok "0.3 ci/archives existe (registre)" || bad "0.3 ci/archives absent — setup-gitlab-lab.sh"
echo "== 1. team-request.sh en direct ⇒ MR + commentaire de plan =="
TEAM="$TEAM" DESCRIPTION="équipe jetable L5 phase 2" APPROVERS="" REPO="$TEAM_REPO" REQ_ENV=dev GIT_REPO="$GIT_REPO" \
  bash scripts/team-request.sh > "$TMP/p1.log" 2>&1; R1=$?
MR1=$(grep -oE 'PR #[0-9]+ ouverte' "$TMP/p1.log" | grep -oE '[0-9]+' | head -1)
[ "$R1" = 0 ] && [ -n "$MR1" ] && ok "1.1 MR !$MR1 ouverte sur $GIT_REPO (rc 0)" || bad "1.1 rc $R1 : $(tail -3 "$TMP/p1.log" | tr '\n' ' ')"
gl "$GITLAB_URL/api/v4/projects/$(enc "$GIT_REPO")/merge_requests/$MR1/notes" | grep -q 'team-request-plan' && ok "1.2 commentaire sous <!-- team-request-plan --> présent" || bad "1.2 pas de commentaire de plan"
echo "== 2b. contre-épreuve DEPOT_ABSENT (dépôt d'équipe NON pré-créé) =="
SHA1=$(merge_mr "$GIT_REPO" "$MR1") || bad "2.0 merge de !$MR1"
git fetch -q "$GITLAB_URL/$GIT_REPO.git" "$SHA1" 2>/dev/null || true
PR_BRANCH="onboard/${TEAM}-dev" PR_NUMBER="$MR1" MERGE_SHA="$SHA1" APIM_API_BASE="${WM_GATEWAY_URL}/rest/apigateway" GIT_REPO="$GIT_REPO" \
  bash scripts/team-apply.sh > "$TMP/p2b.log" 2>&1; R2B=$?
[ "$R2B" = 2 ] && grep -q 'DEPOT_ABSENT' "$TMP/p2b.log" && ok "2b.1 team-apply refuse DEPOT_ABSENT (rc 2) sur un dépôt non créé" || bad "2b.1 rc $R2B : $(tail -2 "$TMP/p2b.log" | tr '\n' ' ')"
gl "$GITLAB_URL/api/v4/projects/$(enc "$GIT_REPO")/merge_requests/$MR1/notes" | grep -q 'DEPOT_ABSENT' && ok "2b.2 le refus est nommé sur la MR (<!-- team-apply -->)" || bad "2b.2 refus non commenté"
[ "$(gl -o /dev/null -w '%{http_code}' "$GITLAB_URL/api/v4/projects/$(enc "$TEAM_REPO")")" = 404 ] && ok "2b.3 rien n'a été créé (404 exact)" || bad "2b.3 un projet est apparu"
echo "== 2. dépôt pré-créé VIDE ⇒ team-apply pousse le squelette =="
FORGE_SECRET="$(tr -d '\r\n' < "$GITLAB_TOKEN_FILE")" WEBHOOK_KIND=gitlab bash scripts/setup-team-repos.sh "$TEAM_REPO" > "$TMP/pre.log" 2>&1 && ok "2.1 setup-team-repos.sh : projet vide + hook + protection" || bad "2.1 pré-création : $(tail -2 "$TMP/pre.log" | tr '\n' ' ')"
PR_BRANCH="onboard/${TEAM}-dev" PR_NUMBER="$MR1" MERGE_SHA="$SHA1" APIM_API_BASE="${WM_GATEWAY_URL}/rest/apigateway" GIT_REPO="$GIT_REPO" \
  bash scripts/team-apply.sh > "$TMP/p2.log" 2>&1; R2=$?
GIT_REPO="$TEAM_REPO" forge_kv D repo_get
[ "$R2" = 0 ] && [ "$D_EMPTY" = 0 ] && grep -q 'squelette' "$TMP/p2.log" && ok "2.2 team-apply rc 0, dépôt vide→squelette (EMPTY=0), ✅" || bad "2.2 rc $R2 EMPTY=$D_EMPTY : $(tail -2 "$TMP/p2.log" | tr '\n' ' ')"
```

- [ ] **Step 3 : preuves 3 à 9** — même facture : `api-request.sh` avec `ACTION=create TEAM=$TEAM API_NAME=$API_NAME API_VERSION=1.0.0 API_BASE=… OPENAPI_SPEC=<fichier de clients/_example> INBOUND_MODE=… CLASSIFICATION=internal EXPOSURE=internal` ⇒ MR sur `$TEAM_REPO`, note `<!-- api-request -->` ; merge ⇒ `WEBHOOK_REPO="$TEAM_REPO" PR_NUMBER=… MERGE_SHA=… PR_BRANCH=… bash scripts/team-publish.sh` ⇒ `curl "$WM_GATEWAY_URL/rest/apigateway/apis"` porte `$API_NAME` et la note ✅ contient `/-/merge_requests/` ; `api-promote-export.sh` ⇒ `gl … /projects/ci%2Farchives/packages` liste `promote--$TEAM--$API_NAME` ; rejeu ⇒ le log dit « déjà ouverte », une seule MR d'épinglage ; `api-promote-request.sh` `FROM_ENV=dev TO_ENV=rec` ⇒ MR, merge ⇒ `team-promote.sh` ⇒ `ARCHIVE_STORE_FETCHED` dans le log ; preuve 7 : `FORGE_KIND=gitea bash scripts/team-request.sh …` ⇒ rc ≠ 0 et « REDIRIGE » ; preuve 8 : boucle `ps -Aww | grep -F "$(head -c 12 "$GITLAB_TOKEN_FILE")"` en tâche de fond pendant 1-6, contrôle positif `grep -c git-remote-http` ≥ 1 ; preuve 9 : `teardown` puis 404 exacts et `RÉSULTAT`.

- [ ] **Step 4 : jouer** sur le lab (GitLab privé, `merge_method=merge`, `ci/archives`) : `GITLAB_URL=http://localhost:13080 GITLAB_TOKEN_FILE=$TMP/pat VAULT_ADDR=… VAULT_TOKEN_FILE=… WM_GATEWAY_URL=http://localhost:8090 bash scripts/test-producer-chain-gitlab.sh` ; corriger ce que la forge réelle révèle (c'est le but) et noter chaque fait mesuré dans l'en-tête de la suite.

- [ ] **Step 5 : commit** — `git add scripts/test-producer-chain-gitlab.sh Makefile && git commit -m "test(producteur): la chaîne producteur en direct sur le GitLab CE réel — MR, merges par l'API, apply sur le SHA mergé, DEPOT_ABSENT, registre, discriminant, ps -Aww"`

---

## Sous-lot 6 — documentation et ADR

### Task 16 : ENVIRONNEMENTS.md, ADR-099, plan, porte close

**Files:**
- Modify: `ENVIRONNEMENTS.md` (§ « Le visage de la forge » : tableau des verbes ; nouveau bloc « Prérequis côté client » unifié L5/L6/D10 ; § « L'onboarding » : conduite de `team-apply` ; § outils de poste : `setup-team-repos.sh` ; § preuves : matrice GitLab)
- Create: `adr/adr-099-la-chaine-ne-cree-rien-sur-la-forge.md`
- Modify: `docs/superpowers/plans/2026-09-09-forge-agnostique-debug-branche.md` (Task 8 ; cases des Tasks 2-3 cochées « livrées par 82f3c5d »)
- Modify: `ci/lint-forge-literals.sh` (`EN_ROUTAGE` vide : D.1 dit « la phase 2 est close »)

- [ ] **Step 1 : ADR-099** (forme des ADR du dépôt : Statut, Contexte, Décision, Conséquences, Refus nommés, Limites, Preuves) :

```markdown
# ADR-099 — La chaîne ne crée rien sur la forge : dépôts, webhooks et protection sont des prérequis

Statut : Accepté (2026-09-12, décision utilisateur D10 profond). Reprend ADR-082 §3 et ADR-081 corollaire 3 sans les réécrire.

## Contexte
`team-apply` créait l'org, le dépôt d'équipe, son webhook vers `team-publish` et sa protection de branche (sept appels Gitea, un jeton org-admin lu dans Vault). Chez un client GitLab, chacun meurt en accusant autre chose ; GitLab CE n'a pas la protection nominative (Premium) ; créer exige un PAT Owner que la chaîne n'a pas à porter.

## Décision
La chaîne **lit** la forge, ouvre des PR/MR et commente. Elle ne crée ni org, ni dépôt, ni hook, ni protection — sur **aucun** visage. `team-apply` lit le dépôt (`forge repo_get`) : absent ⇒ `DEPOT_ABSENT` (refus nommé sur la PR) ; vide ⇒ squelette poussé ; non vide ⇒ déjà initialisé (idempotence). Le client crée le dépôt vide, son webhook et sa protection ; le lab les pré-crée par `scripts/setup-team-repos.sh`.

## Conséquences
- Un seul secret de forge pour toute la chaîne ; plus de `gitea-org-admin` dans Vault ; la dette « docker exec seule voie pour le minter » disparaît.
- Les quatre yeux d'ADR-081 restent portés par la protection de branche — posée par le client (GitLab CE : par rôle).
- `setup-repo-protections.sh` reste un outil d'exploitant Gitea (refus `PROTECTION_GITEA_SEULEMENT` ailleurs).

## Refus nommés
`DEPOT_ABSENT`, `PROTECTION_GITEA_SEULEMENT`, `ARCHIVE_STORE_PROJECT_REQUIS`.

## Limites
Sur GitLab un 404 vaut aussi « invisible pour ce jeton » — le refus le dit. `team-apply` ne vérifie pas la présence du webhook (lister les hooks exige Maintainer) : prérequis écrit, pas contrôlé.

## Preuves
`test-palier-retention.sh` ⑭ (statique, mutants), `test-team-onboarding-chain.sh` 5/5bis/6 (Gitea, en direct), `test-producer-chain-gitlab.sh` 2/2b (GitLab réel), `test-forge-api.sh` R/M6/M7.
```

- [ ] **Step 2 : ENVIRONNEMENTS.md** — écrire les quatre sections (verbes : tableau `verbe | arguments | sortie | gitea | gitlab` pour les 11 verbes ; prérequis client : liste unique ; `team-apply` : le tableau §6.1 de la spec ; outils : `setup-team-repos.sh` avec ses knobs ; preuves : les comptes réels des suites jouées). Remplacer les mentions « team-apply crée le dépôt » dans les sections d'onboarding existantes.

- [ ] **Step 3 : plan** — Task 8 (L5 phase 2) avec ses cases cochées, commits et compteurs ; Tasks 2-3 : cases `[x]` + « livrées par 82f3c5d (2026-09-09) ».

- [ ] **Step 4 : vérifier** — `bash ci/lint-forge-literals.sh` : D.1 « aucun fichier en routage : la phase 2 est close » ; `make lint-ci` 20/20 ; relecture adverse à trois lentilles (conformité à la spec, fuite, hygiène des épreuves) avant le dernier commit.

- [ ] **Step 5 : commit** — `git add ENVIRONNEMENTS.md adr/adr-099-la-chaine-ne-cree-rien-sur-la-forge.md docs/superpowers/plans/2026-09-09-forge-agnostique-debug-branche.md ci/lint-forge-literals.sh && git commit -m "docs(l5): phase 2 close — verbes, prérequis côté client unifiés, ADR-099, Task 8 du plan"`

---

## Auto-revue du plan (faite à l'écriture)

- **Couverture de la spec** : §4.1 → Task 2 ; §4.2 → Task 1 ; §4.3 → Task 4 ; §4.4 → Task 3 + Tasks 6-9 (liens) ; §4.5 → Task 8 (find puis open) ; §5 → Task 13 ; §6 (tableau) → Tasks 6-10, 12, 5 (`provision-plan.sh:339`) ; §6.1 → Task 10 ; §6.2 → Task 11 (+ ⑭ dans Task 10) ; §7 → Task 5 (+ A.2 élargi en Task 13, close en Task 16) ; §8 hors ligne → Tasks 1-5, 10, 11, 13 ; §8 live → Tasks 14-15 ; §9 → règles globales et Tasks 9/10 ; §10 → Task 16 ; §11 → l'ordre des tâches ; §12 → notés dans Tasks 2 (404), 10 (`DEFAULT_BRANCH` vide ⇒ `GIT_BASE`), 6-7 (rejeu des commentaires), 13 (droits du registre : mesurés en Task 15).
- **Placeholders** : aucun « TBD » ; chaque étape de code montre le code ; les suites live (Task 11 Step 5, Task 15 Step 3) décrivent chaque assertion avec sa commande.
- **Cohérence des noms** : `forge_kv PR pr_open` ⇒ `PR_NUMBER`/`PR_URL` (Tasks 6-8) ; `forge_kv DEPOT repo_get` ⇒ `DEPOT_EXISTS/EMPTY/DEFAULT_BRANCH/URL` (Task 10, Task 15) ; `forge_kv PIN pr_find_open|pr_open` ⇒ `PIN_NUMBER` (Task 8) ; `forge_web_url`, `forge_web_file_url` (Task 3, utilisés Tasks 5-10) ; marqueurs `<!-- team-request-plan -->`, `<!-- team-apply -->`, `<!-- api-request -->` (Tasks 6, 7, 10, 15) ; refus `DEPOT_ABSENT`, `PROTECTION_GITEA_SEULEMENT`, `ARCHIVE_STORE_PROJECT_REQUIS`, `SECRET_FORGE_REQUIS`, `REPO_REQUIS`, `FORGE_KIND_INCONNU`, `CREATION_ECHEC` (Tasks 10-13, ADR).
