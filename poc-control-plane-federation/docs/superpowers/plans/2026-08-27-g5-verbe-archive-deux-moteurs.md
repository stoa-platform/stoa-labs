# G5 — Le verbe archive porté par les deux moteurs — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal :** brancher l'import d'archive à GUID stables (ADR-079) sur les sauts `rec` et
au-delà : le merge d'une PR `promote/<api>-<env>` déclenche un apply réel par l'un des
deux moteurs (`apim_promote_api` / `labctl promote`), les octets voyagent par un dépôt
d'artefacts adressé par contenu, et **toute** porte refusée est mécaniquement antérieure
au lancement du moteur.

**Architecture :** un job Jenkins `team-promote` (même token webhook que team-publish,
filtre `promote/*`) consomme le marqueur G3 au SHA mergé, récupère l'archive au registre
de packages génériques Gitea par le digest du marqueur, déroule TOUTES les gardes puis
appelle UN site moteur (knob `PROMOTE_ENGINE`). Le mock wM apprend `/archive` (fidélité
prouvée par le harnais ADR-079 inchangé) pour que la chaîne soit exerçable en lab via
les proxies `wm-admin-<env>`.

**Tech stack :** bash 3.2-compatible, python3+PyYAML, Go (mock + labctl vendored,
GOPROXY=off), Ansible 2.x, Jenkins declarative + Generic Webhook Trigger, Gitea 1.22
(API packages génériques), Vault KV v2.

**Spec :** `docs/superpowers/specs/2026-08-27-g5-verbe-archive-deux-moteurs-design.md`
(lire AVANT toute tâche ; les décisions D1-D9 y sont argumentées).

## Global Constraints

- **bash 3.2 (macOS)** : jamais `mapfile`, jamais de tableaux exportés ; `read -r -a`.
- **Jamais de secret en argv/URL/log** : token via header-file (`-H @file`) ou
  `GIT_CONFIG_COUNT/KEY_0/VALUE_0` ; `set +x` dans tout script qui touche un token.
- **Sous `set -uo pipefail`, jamais `cmd | grep -q X && … || …`** : capturer dans un
  fichier PUIS grepper le fichier (leçon G3, mordue deux fois).
- **Toute assertion de garde se prouve par MUTATION** (retirer la garde ⇒ rouge), les
  `grep` s'ancrent sur le code décommenté (`sed 's/[[:space:]]*#.*$//'`).
- **`go test` toujours `-count=1`** quand une porte en dépend (le cache Go ment, piège G1).
- **Le config.xml Jenkins GAGNE sur le Jenkinsfile** : tout changement de
  triggers/parameters bouge dans LES DEUX fichiers, et le job doit être RE-POSÉ.
- **Refus nommés en français**, motif `JETON_EXPLICITE : détail` sur stderr, exit 1.
- **Aucun DELETE via les proxies admin** (allowlist ADR-075) — le teardown vit dans les
  scripts d'exploitation, jamais dans la chaîne.
- Commits : `type(g5): description` + trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Tout nouveau script livrable passe `shellcheck` (liste du Makefile, cible `lint-ci`).

---

### Task 1 : le mock wM apprend `/archive` — export, import, DELETE de teardown

**Files:**
- Create: `mocks/webmethods/archive.go`
- Create: `mocks/webmethods/archive_test.go`
- Modify: `mocks/webmethods/server.go` (routes)
- Modify: `mocks/webmethods/admin.go` (DELETE apis/alias/applications si absents)

**Interfaces:**
- Consomme : `store.go` (le store mutex du mock), `apiEnvelope`/`apiRecord` existants.
- Produit : `GET /rest/apigateway/archive?apis=<id>` → zip ; `POST
  /rest/apigateway/archive?overwrite=<types>` (multipart `file`) → JSON
  `{"ArchiveResult":[{"API":{id,name,status,overwritten}}, …]}` ; `DELETE
  /rest/apigateway/apis/{id}` → 204 (409 si souscrite/active), `DELETE
  /rest/apigateway/alias/{id}` → 204, `DELETE /rest/apigateway/applications/{id}` → 204.
  La Task 9 rejoue `scripts/test-archive-promotion.sh` contre ce mock : c'est LE contrat.

**La fidélité est bornée par deux consommateurs, à lire d'abord :**
`labctl/internal/adapter/webmethods/archive.go:88-300` (SanitizeArchive : layout attendu)
et `scripts/test-archive-promotion.sh` (chaque assertion = une sémantique due).
`ansible/roles/apim_promote_api/files/sanitize_archive.py` doit lui aussi passer.

**Layout d'export (pinné par SanitizeArchive) :**
```
APIGatewayAssets.acdl                      # manifeste XML
ExportReport.json                          # présent au RAW export (strippé ensuite)
API/API.<id>/API.<id>                      # record API JSON (id, apiName, apiVersion, isActive, policies:[pid])
API/Policy.<pid>/Policy.<pid>              # record Policy JSON (id, names, policyScope, actions:[aid])
API/PolicyAction.<aid>/PolicyAction.<aid>  # record JSON — le routing porte templateKey "straightThroughRouting"
                                           #   et parameters[{templateKey:"endpointUri", values:[url]}]
Alias/Alias.<alid>/Alias.<alid>            # SEULEMENT si un endpointUri référence ${<nom d'alias existant>}
```
L'acdl doit satisfaire les regex de `SanitizeArchive` (`<asset name="Type.id" …>…</asset>`
ou auto-fermant, `<dependsOn>APIGateway:Type.id</dependsOn>`) — forme minimale :
```xml
<assets>
  <asset name="API.<id>" type="API"><dependsOn>APIGateway:Policy.<pid></dependsOn></asset>
  <asset name="Policy.<pid>" type="Policy"><dependsOn>APIGateway:PolicyAction.<aid></dependsOn></asset>
  <asset name="PolicyAction.<aid>" type="PolicyAction"/>
  <asset name="Alias.<alid>" type="Alias"/>          <!-- si embarqué -->
</assets>
```

**Sémantique d'import (pinnée par le harnais, rien de plus) :**
1. multipart, champ `file`, zip ; entrées lues : `API/<Type>.<id>/<Type>.<id>` et
   `Alias/Alias.<id>/Alias.<id>` (le reste ignoré silencieusement, ExportReport compris).
2. `overwrite` = liste CSV de pluriels minuscules (`apis,policies,policyactions`,
   éventuellement `aliases`) ; `*` = tout couvert. Mapping type→pluriel :
   `API→apis, Policy→policies, PolicyAction→policyactions, Alias→aliases`.
3. Par entrée : l'asset **existe** et son type **non couvert** ⇒ ligne
   `status:"Failed", explanation:"Asset already exists"`, état INTACT (jamais de doublon,
   T3 du harnais). Existe et couvert ⇒ REMPLACÉ (même id), `overwritten:true` — pour un
   Alias couvert c'est le CLOBBER (fidèle, T6-T7 le distinguent). N'existe pas ⇒ créé
   **avec l'id de l'archive** (GUID iso, T9/T10), `overwritten:false`, `Success`.
   Alias existant non couvert ⇒ `Success, overwritten:false`, valeur locale INTACTE (T7).
4. `isActive` du record API est APPLIQUÉ tel quel — une archive `isActive:false`
   DÉSACTIVE (T5, le piège), `true` (ré)active.
5. La bascule du store est atomique sous mutex : le data-plane ne rend JAMAIS autre
   chose que 200 pendant l'overwrite (T4, charge 4 voies).
6. Réponse : `{"ArchiveResult":[ {"<Type>": {"id":…, "name":…, "status":…, "overwritten":…, "explanation":…}}, … ]}`.

**DELETE (teardown du harnais, et piège mémoire « mock sans DELETE ») :**
`DELETE /apis/{id}` → 204 si inactive et sans souscription (harnais : deactivate d'abord,
retrait de l'app d'abord) ; sinon 409. `DELETE /alias/{id}` → 204. `DELETE
/applications/{id}` → 204 (retire aussi ses souscriptions).

- [ ] **Step 1 : lire les trois contrats** — `archive.go` labctl (SanitizeArchive),
  `test-archive-promotion.sh`, `sanitize_archive.py`. Noter tout écart avec le layout
  ci-dessus et corriger le PLAN LOCALEMENT (le contrat, c'est eux).
- [ ] **Step 2 : tests Go d'abord** (`archive_test.go`) : export→sanitize(labctl copié ?
  non — le module mock ne peut pas importer labctl : recoder dans le test les
  VÉRIFICATIONS, pas le sanitizer) :
  - `TestExportLayout` : créer API+alias via handlers, router `${alias}`, exporter →
    zip contient acdl + `API/API.<id>/API.<id>` + Alias/ ; record API porte
    id/apiName/apiVersion/isActive.
  - `TestImportConflictWithoutOverwrite` : import du même zip sans overwrite → ≥1
    `Failed`/`Asset already exists`, catalogue sans doublon.
  - `TestImportOverwriteAppliesIsActive` : record muté `isActive:false` → API désactivée ;
    ré-import `true` → réactivée.
  - `TestImportVirginKeepsGUID` : delete API → import → même id, active.
  - `TestImportSkipsUncoveredAlias` : alias local modifié, import overwrite scoped →
    valeur intacte, ligne Alias `overwritten:false`.
- [ ] **Step 3 : `go test ./... -count=1` dans `mocks/webmethods` → FAIL** (routes absentes).
- [ ] **Step 4 : implémenter** `archive.go` (handlers export/import + zip build/parse),
  routes dans `server.go`, DELETE dans `admin.go`. L'import passe par le lock du store ;
  aucune fenêtre où l'API disparaît du data-plane.
- [ ] **Step 5 : `go test ./... -count=1` → PASS** ; `go vet ./...` propre.
- [ ] **Step 6 : commit** `feat(g5): le mock wm apprend /archive — export, import, teardown`.

---

### Task 2 : `scripts/lib/archive-store.sh` — le transport adressé par le contenu

**Files:**
- Create: `scripts/lib/archive-store.sh`
- Create: `scripts/test-archive-store.sh`
- Modify: `Makefile` (l'épreuve rejoint `lint-ci`, même motif que les autres)

**Interfaces:**
- Consomme : `GIT_HOST`, `GITEA_TOKEN` (env), `ARCHIVE_STORE_OWNER` (défaut `ci`).
- Produit (sourcé par Tasks 5/6) :
  - `archive_store_push <zip_abs> <team> <api>` → stdout `ARCHIVE_STORE_PUSHED
    sha256=<64hex> url=<url>` (idempotent : déjà présent ET identique ⇒ même sortie).
  - `archive_store_fetch <team> <api> <sha256> <dest_abs>` → dest écrit, re-haché,
    confronté ; stdout `ARCHIVE_STORE_FETCHED sha256=<…>`.
  - Refus nommés : `STORE_PARAM_INVALIDE`, `STORE_TOKEN_ABSENT`, `STORE_HTTP_<code>`,
    `STORE_DIGEST_MISMATCH`, `STORE_CONFLIT_CONTENU` (présent mais octets ≠ digest).

Adresse : `${GIT_HOST}/api/packages/${ARCHIVE_STORE_OWNER}/generic/promote--<team>--<api>/<sha256>/archive.zip`
— la **version du package est le sha256** : l'URL se dérive du seul marqueur G3.

- [ ] **Step 1 : écrire la lib.** Contenu complet :

```bash
#!/usr/bin/env bash
# scripts/lib/archive-store.sh — LE TRANSPORT DES OCTETS (jalon G5, ADR-079 C3 :
# l'archive est un artefact de build tagué — dépôt d'artefacts, PAS Git).
# Registre = packages GÉNÉRIQUES Gitea, ADRESSÉ PAR LE CONTENU : la version du
# package EST le sha256 de l'archive sanitizée. Conséquences voulues :
#   - l'URL de fetch se dérive du marqueur G3 (archive_sha256) sans champ nouveau ;
#   - pousser deux fois les mêmes octets est un no-op nommé, pas un doublon ;
#   - un même chemin portant d'AUTRES octets est un incident nommé, jamais écrasé.
# FAIL-CLOSED partout ; token via header-file, jamais argv/URL.
_STOA_ARCHIVE_STORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export _STOA_ARCHIVE_STORE_ROOT

_as_fail() { printf 'archive-store: %s\n' "$*" >&2; }

_as_ident_ok() {   # <valeur> — classe [a-z0-9-], jamais vide (segment d'URL/chemin)
  case "$1" in ""|*[!a-z0-9-]*) return 1;; esac; return 0
}

_as_curl() {       # $@ — curl authentifié, header-file éphémère (umask du caller)
  local hdr rc
  hdr="$(mktemp)" || { _as_fail "STORE_TMP_INCREABLE"; return 1; }
  printf 'Authorization: token %s\n' "${GITEA_TOKEN:?}" > "$hdr"
  curl -sS -H @"$hdr" "$@"; rc=$?
  rm -f "$hdr"
  return "$rc"
}

_as_url() {        # <team> <api> <sha> — l'URL canonique du contenu
  printf '%s/api/packages/%s/generic/promote--%s--%s/%s/archive.zip' \
    "${GIT_HOST:-http://gitea:3000}" "${ARCHIVE_STORE_OWNER:-ci}" "$1" "$2" "$3"
}

archive_store_push() { # <zip_abs> <team> <api>
  local zip="$1" team="$2" api="$3" sha url code probe
  [ -n "${GITEA_TOKEN:-}" ] || { _as_fail "STORE_TOKEN_ABSENT : GITEA_TOKEN requis"; return 1; }
  _as_ident_ok "$team" && _as_ident_ok "$api" \
    || { _as_fail "STORE_PARAM_INVALIDE : team='$team' api='$api' (classe [a-z0-9-])"; return 1; }
  case "$zip" in /*) ;; *) { _as_fail "STORE_PARAM_INVALIDE : chemin d'archive non absolu '$zip'"; return 1; };; esac
  [ -f "$zip" ] || { _as_fail "STORE_PARAM_INVALIDE : archive introuvable '$zip'"; return 1; }
  sha="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
  [ "${#sha}" -eq 64 ] || { _as_fail "STORE_DIGEST_INCALCULABLE : '$zip'"; return 1; }
  url="$(_as_url "$team" "$api" "$sha")"
  # Idempotence PAR LE CONTENU : si le chemin existe déjà, on re-hache ce qu'il
  # sert. Identique -> no-op nommé ; différent -> incident (l'adressage par
  # contenu vient d'être contredit), on n'écrase JAMAIS.
  probe="$(mktemp)" || { _as_fail "STORE_TMP_INCREABLE"; return 1; }
  code="$(_as_curl -o "$probe" -w '%{http_code}' --max-time 60 "$url")" || code=000
  if [ "$code" = 200 ]; then
    local got; got="$(shasum -a 256 "$probe" | cut -d' ' -f1)"; rm -f "$probe"
    [ "$got" = "$sha" ] \
      || { _as_fail "STORE_CONFLIT_CONTENU : $url sert $got, attendu $sha — registre incohérent, refus d'écraser"; return 1; }
    printf 'ARCHIVE_STORE_PUSHED sha256=%s url=%s\n' "$sha" "$url"
    return 0
  fi
  rm -f "$probe"
  [ "$code" = 404 ] || { _as_fail "STORE_HTTP_$code : sonde de $url"; return 1; }
  code="$(_as_curl -o /dev/null -w '%{http_code}' --max-time 300 --upload-file "$zip" "$url")" || code=000
  [ "$code" = 201 ] || { _as_fail "STORE_HTTP_$code : PUT $url"; return 1; }
  printf 'ARCHIVE_STORE_PUSHED sha256=%s url=%s\n' "$sha" "$url"
}

archive_store_fetch() { # <team> <api> <sha256> <dest_abs>
  local team="$1" api="$2" sha="$3" dest="$4" url code got tmp
  [ -n "${GITEA_TOKEN:-}" ] || { _as_fail "STORE_TOKEN_ABSENT : GITEA_TOKEN requis"; return 1; }
  _as_ident_ok "$team" && _as_ident_ok "$api" \
    || { _as_fail "STORE_PARAM_INVALIDE : team='$team' api='$api'"; return 1; }
  case "$sha" in *[!0-9a-f]*|"") { _as_fail "STORE_PARAM_INVALIDE : sha256 '$sha'"; return 1; };; esac
  [ "${#sha}" -eq 64 ] || { _as_fail "STORE_PARAM_INVALIDE : sha256 long de ${#sha}"; return 1; }
  case "$dest" in /*) ;; *) { _as_fail "STORE_PARAM_INVALIDE : destination non absolue '$dest'"; return 1; };; esac
  url="$(_as_url "$team" "$api" "$sha")"
  tmp="$(mktemp)" || { _as_fail "STORE_TMP_INCREABLE"; return 1; }
  code="$(_as_curl -o "$tmp" -w '%{http_code}' --max-time 300 "$url")" || code=000
  [ "$code" = 200 ] || { rm -f "$tmp"; _as_fail "STORE_HTTP_$code : GET $url — l'archive pinnée n'est pas au registre (export jamais poussé ?)"; return 1; }
  got="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
  [ "$got" = "$sha" ] \
    || { rm -f "$tmp"; _as_fail "STORE_DIGEST_MISMATCH : $url sert $got, le marqueur pinne $sha"; return 1; }
  mv "$tmp" "$dest" || { rm -f "$tmp"; _as_fail "STORE_DEST_INECRIVABLE : '$dest'"; return 1; }
  printf 'ARCHIVE_STORE_FETCHED sha256=%s\n' "$sha"
}
```

- [ ] **Step 2 : l'épreuve `scripts/test-archive-store.sh`** — stub HTTP python local
  (port éphémère) qui implémente PUT (stocke en mémoire, 201 ; re-PUT → 409), GET
  (200/404), et deux modes de panne pilotés par le chemin (`/corrompu/` sert d'autres
  octets ; `/erreur/` sert 500). Protocole PASS/FAIL cumulés, chaque cas capture
  stdout+stderr EN FICHIER puis greppe le fichier :
  ① push d'un zip → `ARCHIVE_STORE_PUSHED`, le stub a reçu 1 PUT ;
  ② re-push identique → `ARCHIVE_STORE_PUSHED`, le stub n'a PAS reçu de 2e PUT ;
  ③ fetch par digest → `ARCHIVE_STORE_FETCHED`, octets identiques (cmp) ;
  ④ fetch d'un digest jamais poussé → `STORE_HTTP_404`, dest ABSENT ;
  ⑤ contenu corrompu servi → `STORE_DIGEST_MISMATCH`, dest ABSENT ;
  ⑥ chemin occupé par d'autres octets au push → `STORE_CONFLIT_CONTENU`, aucun PUT ;
  ⑦ 500 → `STORE_HTTP_500` ;
  ⑧ team invalide (`Team/../x`) → `STORE_PARAM_INVALIDE` AVANT tout appel réseau
  (le stub ne voit aucune requête) ;
  ⑨ GITEA_TOKEN absent → `STORE_TOKEN_ABSENT` sans appel réseau ;
  ⑩ **mutation** : `sed` retire la comparaison `[ "$got" = "$sha" ]` du fetch sur une
  COPIE de la lib → ⑤ rejoué contre la copie doit VERDIR le fetch corrompu ⇒ l'épreuve
  n'est pas vacante (elle exige ce rouge-là) ; garde-fou « verdicts rendus == cas
  attendus ».
  ⑪ le token n'apparaît dans AUCUNE ligne de commande curl : assertion sur le code
  décommenté de la lib (`grep -c 'Authorization' après sed` == 1, dans le heredoc du
  header-file uniquement) + le stub vérifie l'en-tête `Authorization: token` reçu.
- [ ] **Step 3 : rouge d'abord** (lancer l'épreuve avant d'avoir écrit la lib si l'ordre
  s'y prête, sinon mutation ⑩ tient lieu de rouge), puis vert complet.
- [ ] **Step 4 : `Makefile`** — ajouter l'épreuve au bloc `lint-ci` (imiter l'intégration
  de `test-palier-retention.sh`, étape numérotée) ; la lib rejoint la liste shellcheck.
- [ ] **Step 5 : `make lint-ci` → vert. Commit** `feat(g5): archive-store — transport adresse par le contenu`.

---

### Task 3 : le credential de palier s'étend au client OAuth — et l'allowlist au verbe

**Files:**
- Modify: `scripts/setup-vault-envs.sh` (seed `envs/<env>/admin-oauth` par palier)
- Modify: `scripts/setup-vault-paliers.sh` (`policy_hcl` : + read `admin-oauth`)
- Modify: `scripts/test-palier-retention.sh` (les épreuves suivent la nouvelle forme)
- Modify: `gateways/webmethods/admin-proxy/wm-admin-proxy.openapi.yaml` (+ `/archive`)

**Interfaces:**
- Produit : secret KV `secret/stoa/envs/<env>/admin-oauth` champs
  `token_url,client_id,client_secret,scope` (scope=`deploy:<env>`) — consommé Task 6
  (`apim_ss_vault_oauth_sub=envs/<env>/admin-oauth` et mint Bearer labctl) ;
  policy `apply-<env>` lisant `envs/<env>/wm-admin` ET `envs/<env>/admin-oauth` ;
  allowlist proxy portant `GET+POST /rest/apigateway/archive`.

- [ ] **Step 1 : lire** `setup-vault-envs.sh` (bloc par env, dérivé de la chaîne) et le
  README du proxy. Le `client_secret` de `admin-oauth` est LU au moment du seed dans
  `secret/stoa/ci` champ `ciHorsprodSecret` (posé par `setup-ci-horsprod.sh`) — jamais
  une valeur en dur ; seed refusé (nommé `CI_SECRET_ABSENT`) si le champ manque.
  `token_url` = `http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/token`
  (vue in-cluster — celle des agents Jenkins), surchargeable `ADMIN_OAUTH_TOKEN_URL`.
- [ ] **Step 2 : `policy_hcl`** dans `setup-vault-paliers.sh` : ajouter
  `path "secret/data/stoa/envs/$1/admin-oauth" { capabilities = ["read"] }` (+ metadata).
  La limite « valeur partagée entre paliers » est DOCUMENTÉE en commentaire (spec D5,
  parking n°2) — le mécanisme de rétention reste le chemin par palier + le scope proxy.
- [ ] **Step 3 : `test-palier-retention.sh`** — étendre les attentes : la forme émise par
  `--print` porte les 4 chemins par palier ; la MUTATION existante (envs/$1→envs/+)
  doit continuer de rougir ; ajouter la mutation « retirer la ligne admin-oauth » ⇒
  rouge. Compte final mis à jour (il passera de 126 à N ; le README de l'épreuve dit N).
- [ ] **Step 4 : allowlist proxy** — dans `wm-admin-proxy.openapi.yaml`, après le bloc
  `/rest/apigateway/apis/{id}/deactivate`, ajouter :

```yaml
  /rest/apigateway/archive:
    get:
      summary: Export API archive (ADR-079 — GET ?apis=<guid> -> zip)
      responses:
        "200": { $ref: "#/components/responses/proxied" }
    post:
      summary: Import API archive (ADR-079 — POST ?overwrite=<types> multipart, 0-coupure)
      requestBody: { $ref: "#/components/requestBodies/passthroughJsonOrMultipart" }
      responses:
        "200": { $ref: "#/components/responses/proxied" }
        "201": { $ref: "#/components/responses/proxied" }
```
  (toujours AUCUN delete — relire l'en-tête du fichier avant d'éditer).
- [ ] **Step 5 : vert** `bash scripts/test-palier-retention.sh` (N/0) ; `make lint-ci`.
- [ ] **Step 6 : commit** `feat(g5): credential de palier etendu au client oauth, allowlist /archive`.

---

### Task 4 : les deux moteurs acceptent l'archive épinglée de l'extérieur

**Files:**
- Modify: `labctl/cmd/labctl/promote.go` (flag `--archive`, garde chemin templaté)
- Modify: `labctl/cmd/labctl/promote_test.go`
- Modify: `ansible/roles/apim_promote_api/defaults/main.yml` (`apim_ss_archive_pin: ""`)
- Modify: `ansible/roles/apim_promote_api/tasks/resolve-env.yml` (application du pin)
- Create: `ansible/promote-api.yml` (le play appelable CI)

**Interfaces:**
- Produit : `labctl promote --manifest <promote.yml> --env <env> --action import|export
  --archive <abs>` (le flag REMPLACE `apim_promote.archive` du manifeste) ;
  play `ansible/promote-api.yml` (hosts webmethods, rôle apim_promote_api) piloté par
  `-e apim_promote_manifest=<chemin> -e apim_promote_action=… -e apim_ss_env=… -e
  apim_ss_archive_pin=<abs> -e apim_ss_archive_sha256=… -e apim_ss_authoring_env=…`.
- Consomme : rien des tasks précédentes.

**Pourquoi :** le manifeste réel porte `archive: "{{ playbook_dir }}/../dist/…"` — une
expression Jinja que seul Ansible rend. Côté CI, l'archive est l'artefact FETCHÉ
(Task 2) : les deux moteurs doivent accepter ce chemin de l'EXTÉRIEUR, même motif que
`apim_ss_contract_pin` (G3).

- [ ] **Step 1 : test Go rouge.** Dans `promote_test.go` :

```go
func TestPromoteArchiveOverride(t *testing.T) {
	spec := promoteSpec{Archive: "{{ playbook_dir }}/../dist/x.zip"}
	if err := applyArchiveOverride(&spec, "/tmp/fetched.zip"); err != nil || spec.Archive != "/tmp/fetched.zip" {
		t.Fatalf("override: %v / %q", err, spec.Archive)
	}
	spec = promoteSpec{Archive: "{{ playbook_dir }}/../dist/x.zip"}
	if err := applyArchiveOverride(&spec, ""); err == nil {
		t.Fatal("un chemin templaté sans --archive doit refuser (ARCHIVE_PATH_TEMPLATED)")
	}
	spec = promoteSpec{Archive: "/deja/absolu.zip"}
	if err := applyArchiveOverride(&spec, ""); err != nil || spec.Archive != "/deja/absolu.zip" {
		t.Fatalf("chemin littéral sans flag: %v", err)
	}
}
```

- [ ] **Step 2 :** `go test ./cmd/labctl/ -run TestPromoteArchiveOverride -count=1` → FAIL.
- [ ] **Step 3 : implémenter** dans `promote.go` : flag
  `promoteCmd.Flags().StringVar(&promoteArchiveFlag, "archive", "", "…")` ;

```go
// applyArchiveOverride pins the CI-fetched artifact path over the manifest's
// archive field. The real manifests carry a Jinja expression only Ansible can
// render (measured: clients/_example/apis/accounts-read.promote.yml) — reading
// it raw would always fail, so a templated path WITHOUT an override is refused
// by name instead of surfacing as a confusing open() error.
func applyArchiveOverride(spec *promoteSpec, override string) error {
	if override != "" {
		if !strings.HasPrefix(override, "/") {
			return fmt.Errorf("promote: ARCHIVE_PATH_RELATIVE — --archive %q must be absolute", override)
		}
		spec.Archive = override
		return nil
	}
	if strings.Contains(spec.Archive, "{{") {
		return fmt.Errorf("promote: ARCHIVE_PATH_TEMPLATED — the manifest carries %q (a template only Ansible renders); pass --archive with the fetched artifact", spec.Archive)
	}
	return nil
}
```
  appelé dans `runPromote` juste après `loadPromoteManifest` (avant la garde
  `spec.Archive == ""` existante, qu'on conserve).
- [ ] **Step 4 :** tests Go verts (`-count=1`, tout le paquet).
- [ ] **Step 5 : le rôle.** `defaults/main.yml` : ajouter sous le bloc digest :

```yaml
# --- archive épinglée par le CI (jalon G5) ------------------------------------
# Chemin ABSOLU de l'archive fetchée au registre (adressée par archive_sha256 du
# marqueur). Non vide => REMPLACE apim_promote.archive après la fusion per_env —
# même motif que apim_ss_contract_pin (G3) : ce qui part au moteur est ce que le
# résolveur/le store ont vérifié, jamais ce que le manifeste prétend porter.
apim_ss_archive_pin: ""
```
  `resolve-env.yml`, APRÈS la fusion per_env (dernier set_fact), ajouter :

```yaml
- name: "Env : épingler l'archive fetchée par le CI (apim_ss_archive_pin, G5)"
  ansible.builtin.set_fact:
    apim_promote: "{{ apim_promote | combine({'archive': apim_ss_archive_pin}) }}"
  when: "(apim_ss_archive_pin | default('')) | length > 0"
```
- [ ] **Step 6 : le play** `ansible/promote-api.yml` (miroir exact de `publish-api.yml`) :

```yaml
---
- name: "Promouvoir une API par archive (ADR-079, jalon G5)"
  hosts: webmethods
  gather_facts: false
  roles: [ apim_promote_api ]
```
- [ ] **Step 7 :** `ansible-playbook --syntax-check -i ansible/inventory.lab.ini
  ansible/promote-api.yml` → OK.
- [ ] **Step 8 : commit** `feat(g5): les deux moteurs acceptent l'archive epinglee (--archive / apim_ss_archive_pin)`.

---

### Task 5 : le chemin d'export — job `api-promote-export`

**Files:**
- Create: `scripts/api-promote-export.sh`
- Create: `ci/Jenkinsfile.api-promote-export`
- Create: `ci/jenkins/api-promote-export.job.xml`
- Modify: `scripts/setup-team-onboard-jobs.sh` (le job rejoint la pose)
- Modify: `scripts/test-jenkinsfile-lint.sh` (11 → 12 fichiers attendus)

**Interfaces:**
- Consomme : Task 2 (`archive_store_push`), Task 4 (play + action=export),
  `ci/lib/vault-login.sh` (login nominatif, `VAULT_TOKEN_FILE`),
  `scripts/lib/env-chain.sh` (`DEPLOY_PIN_AUTHORING_ENV` via deploy-pin.sh).
- Produit : sortie `EXPORT_CONFIRMED_SUMMARY guid=<guid> sha256=<64hex>
  package=<url>` — ce que le demandeur recopie (guid → PR sur `promote.yml` ;
  sha256 → formulaire `api-promote-request`).

**Le script (`scripts/api-promote-export.sh`) — structure imposée :**
1. `set -uo pipefail; set +x; cd "$(dirname "$0")/.."` ; source `deploy-pin.sh`
   (constante d'authoring) puis `archive-store.sh`.
2. Entrées env : `TEAM`, `API_NAME` (classes IDENTIQUES à `api-promote-request.sh:60-62`),
   `GITEA_TOKEN`, `VAULT_ADDR`, `VAULT_TOKEN_FILE`, `APIM_API_BASE` (gateway
   d'AUTHORING — pas de défaut, même discipline que team-publish.sh:75),
   `GIT_HOST`, `GIT_REPO`.
3. `team → repo` : providers.<authoring>.yml lu sur Gitea main — REPRENDRE À
   L'IDENTIQUE le bloc de `api-promote-request.sh:141-175` (gapi --fail-with-body,
   marqueurs `REPO=`, refus `LECTURE_PROVIDERS`/`REPO_NON_DECLARE`).
4. Clone authentifié du dépôt d'équipe (bloc `gclone` de `team-publish.sh:110-116`),
   branche main. `apis/<api>.promote.yml` absent ⇒ `PROMOTE_MANIFEST_ABSENT`.
5. Moteur export : `ARCHIVE_OUT="$TMP/export.zip"` puis

```bash
( ansible-playbook -i ansible/inventory.lab.ini ansible/promote-api.yml \
    -e apim_promote_action=export \
    -e apim_promote_manifest="$TMP/team/apis/${API_NAME}.promote.yml" \
    -e apim_ss_archive_pin="$ARCHIVE_OUT" \
    -e apim_ss_env="$DEPLOY_PIN_AUTHORING_ENV" \
    -e apim_ss_authoring_env="$DEPLOY_PIN_AUTHORING_ENV" \
    -e apim_ss_api_base="$APIM_API_BASE" \
) >"$TMP/export.log" 2>&1 || { tail -30 "$TMP/export.log" >&2; fail "EXPORT_ECHEC : voir le log"; }
```
   ⚠ le pin d'archive sert AUSSI à l'export : c'est la DESTINATION (le rôle écrit
   l'archive à `apim_promote.archive`) — d'où la Task 4 appliquée aux deux actions.
6. Digest + guid : `SHA=$(shasum -a 256 "$ARCHIVE_OUT" | cut -d' ' -f1)` ; le guid se lit
   dans le log (`grep -o 'guid=[0-9a-f-]*' "$TMP/export.log" | tail -1`) — capture en
   fichier, jamais un pipe du play. Vides ⇒ `EXPORT_UNCONFIRMED`.
7. `archive_store_push "$ARCHIVE_OUT" "$TEAM" "$API_NAME"` (sa sortie donne l'URL).
8. `printf 'EXPORT_CONFIRMED_SUMMARY guid=%s sha256=%s package=%s\n' …` + rappel du
   geste : « épingler guid dans apis/<api>.promote.yml (PR), recopier sha256 dans le
   formulaire de promotion ».

**Le Jenkinsfile** : calqué sur `ci/Jenkinsfile.api-promote-request` (bloc
`environment{}` de config client identique + `APIM_API_BASE` défaut
`http://webmethods-mock:8080/rest/apigateway`), parameters `TEAM`, `API_NAME`,
`VAULT_USER` (string), `V_PASS` (password), stage unique : `withCredentials` token Gitea
→ `withEnv` params → un SEUL `sh` qui source `ci/lib/vault-login.sh`, trap
`vault_trap_revoke`, `vault_login_nominative` (motif exact de
`ci/Jenkinsfile.team-publish:175-204` — RC=0 pattern) puis `bash
scripts/api-promote-export.sh`.

**Le job.xml** : copier la structure de `ci/jenkins/team-request.job.xml` (job de
formulaire SANS webhook) en adaptant nom/description/paramètres — et le Jenkinsfile
est la source du pipeline (`definition` pointant le repo, même mécanique que les
frères). Le poser via `setup-team-onboard-jobs.sh` : ajouter `api-promote-export` à la
liste `JOBS` par défaut et vérifier que la boucle de pose n'a rien de spécifique par job.

- [ ] **Step 1 :** lire `api-promote-request.sh` entier + `setup-team-onboard-jobs.sh`
  (la boucle JOBS) + un job.xml frère. Écrire le script.
- [ ] **Step 2 :** `shellcheck scripts/api-promote-export.sh` propre ; DRY probe : lancer
  avec `TEAM=x API_NAME='a;b'` ⇒ refus de classe AVANT tout réseau.
- [ ] **Step 3 :** écrire Jenkinsfile + job.xml ; `scripts/test-jenkinsfile-lint.sh`
  passe à 12 (mettre à jour le compte attendu DANS l'épreuve — elle refuse un écart).
- [ ] **Step 4 :** `make lint-ci` vert. **Commit**
  `feat(g5): api-promote-export — l'archive part au registre, le digest au formulaire`.

---

### Task 6 : `team-promote.sh` — toutes les portes avant le moteur

**Files:**
- Create: `scripts/team-promote.sh`
- Modify: `scripts/lib/env-chain.sh` (+ `env_chain_gate_four_eyes`)
- Modify: `scripts/lib/assert-merge-identity.sh` (+ `--allow-self-approval`)
- Modify: `scripts/api-promote-request.sh` (le marqueur porte `pv_ref` — trou mesuré :
  la porte homol exige un PV que le marqueur ne transportait pas)

**Interfaces:**
- Consomme : `deploy-pin.sh` (`resolve_deploy_pin` 6 args), `archive-store.sh`
  (`archive_store_fetch`), `env-chain.sh` (`env_chain`, `env_chain_gate`,
  `env_chain_gate_four_eyes`), `gitea-pr-comment.sh`, `assert-merge-identity.sh`,
  Task 4 (play + labctl `--archive`), Task 3 (subs Vault par palier).
- Produit : le script appelé par `ci/Jenkinsfile.team-promote` (Task 7) avec env :
  `WEBHOOK_REPO PR_BRANCH PR_NUMBER MERGE_SHA PR_MERGED_BY PR_REQUESTER GITEA_TOKEN
  VAULT_ADDR VAULT_TOKEN_FILE GIT_HOST GIT_REPO PROMOTE_ENGINE ADMIN_VIA
  APIM_API_BASE_TPL APIM_DIRECT_BASE_TPL` ; marqueur de commentaire `<!-- team-promote -->`.

- [ ] **Step 1 : `env_chain_gate_four_eyes`** dans `env-chain.sh` (les consommateurs de
  `env_chain_gate` parsent 3 champs positionnels — on n'y touche PAS, fonction sœur) :

```bash
# La porte d'arrivée exige-t-elle les quatre yeux ? Rend FOUREYES=0|1.
env_chain_gate_four_eyes() {
  local f; f="$(_env_chain_file)"
  [ -r "$f" ] || { echo "env-chain: source illisible : $f" >&2; return 1; }
  python3 - "$f" "$1" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
g = next((x for x in (d.get("gates") or []) if x.get("to") == sys.argv[2]), {}) or {}
print("FOUREYES=%s" % ("1" if g.get("fourEyes") else "0"))
PY
}
```
- [ ] **Step 2 : `--allow-self-approval`** dans `assert-merge-identity.sh` : nouvelle
  option (défaut OFF — le comportement existant ne bouge pas pour team-publish/
  team-apply/provision-apply) ; quand posée, le bloc FOUR_EYES_VIOLATION est SAUTÉ,
  les blocs MERGER_UNKNOWN/MERGER_MISMATCH restent INCONDITIONNELS. Une ligne d'écho
  dit explicitement « auto-approbation admise par la porte (selfApproval) ».
- [ ] **Step 3 : `pv_ref` au marqueur** — dans `api-promote-request.sh`, le
  `yaml.safe_dump` ajoute `"pv_ref": os.environ["PV"]` (env `PV="$PV_REF"` à l'appel).
  Rejouer `bash scripts/test-deploy-pin.sh` : s'il épingle les clés du marqueur,
  mettre à jour SES attentes (le compte affiché change — le dire au rapport).
- [ ] **Step 4 : écrire `scripts/team-promote.sh`.** Squelette imposé — les blocs marqués
  `[= team-publish.sh §N =]` se REPRENNENT du fichier existant à l'identique (mêmes
  refus, mêmes commentaires adaptés) :

```bash
#!/usr/bin/env bash
# team-promote.sh — l'APPLY de PROMOTION, après la décision humaine (le merge
# d'une PR promote/<api>-<env>, ADR-081). Jalon G5 (ADR-079 : le verbe des
# paliers > authoring est l'IMPORT D'ARCHIVE, jamais le re-POST).
# TOUTES les portes sont mécaniquement ANTÉRIEURES au moteur : un refus, quel
# qu'il soit, se produit AVANT run_engine() — l'épreuve test-team-promote-wiring
# l'exige garde par garde (stub moteur jamais invoqué).
set -uo pipefail
set +x
cd "$(dirname "$0")/.." || exit 1
. scripts/lib/deploy-pin.sh    || { echo "ERREUR: deploy-pin.sh introuvable" >&2; exit 1; }
. scripts/lib/env-chain.sh     || { echo "ERREUR: env-chain.sh introuvable" >&2; exit 1; }
. scripts/lib/archive-store.sh || { echo "ERREUR: archive-store.sh introuvable" >&2; exit 1; }

WEBHOOK_REPO="${WEBHOOK_REPO:?}"; PR_BRANCH="${PR_BRANCH:?}"; PR_NUMBER="${PR_NUMBER:?}"
MERGE_SHA="${MERGE_SHA:?}"; GITEA_TOKEN="${GITEA_TOKEN:?}"
VAULT_ADDR="${VAULT_ADDR:?}"; VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:?}"
GIT_HOST="${GIT_HOST:-http://gitea:3000}"; GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"
PROMOTE_ENGINE="${PROMOTE_ENGINE:-ansible}"     # ansible|labctl — knob de PIPELINE (D6)
ADMIN_VIA="${ADMIN_VIA:-proxy-oauth2}"          # proxy-oauth2|direct (D5)
# Gabarits d'URL admin par palier (__ENV__ substitué) — config client au Jenkinsfile.
APIM_API_BASE_TPL="${APIM_API_BASE_TPL:?APIM_API_BASE_TPL requis (ex: http://webmethods-real:5555/gateway/wm-admin-__ENV__/1.0/rest/apigateway)}"
ENVN_AUTH="$DEPLOY_PIN_AUTHORING_ENV"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; umask 077
TEAM_PROMOTE_MARKER='<!-- team-promote -->'
comment(){ [= team-publish.sh §comment, marqueur TEAM_PROMOTE_MARKER =] }
fail(){ comment "$WEBHOOK_REPO" "❌ team-promote : $*"; echo "ERREUR: $*" >&2; exit 1; }
gclone(){ [= team-publish.sh :110-116 =] }

# ── 0. VALIDATION DE FORME [= team-publish.sh §0, à l'identique =] ───────────
# ── 1. branche gardée à promote/*, sinon rien à faire ────────────────────────
case "$PR_BRANCH" in promote/*) ;; *) echo "hors promote/* — rien à promouvoir"; exit 0;; esac
REST="${PR_BRANCH#promote/}"
TO_ENV="${REST##*-}"; API_NAME="${REST%-*}"
[ -n "$API_NAME" ] && [ -n "$TO_ENV" ] && [ "$API_NAME" != "$REST" ] \
  || fail "BRANCH_FORMAT_INVALIDE : '${PR_BRANCH}' — attendu promote/<api>-<env>"
[= classes API_NAME/TO_ENV : team-publish.sh §1, motifs ""|*[!a-z0-9-]* =]
# TO_ENV : un palier de la CHAÎNE, jamais l'authoring (une promotion va toujours
# vers un palier SUIVANT ; l'authoring suit HEAD et n'a pas de marqueur).
CHAIN="$(env_chain)" || fail "CHAINE_ILLISIBLE"
case " $CHAIN " in *" $TO_ENV "*) ;; *) fail "ENV_INVALIDE : '$TO_ENV' hors de la chaîne ($CHAIN)";; esac
[ "$TO_ENV" != "$ENVN_AUTH" ] || fail "ENV_INVALIDE : '$TO_ENV' est l'environnement d'authoring — rien ne s'y promeut"

# ── 2. RÉCONCILIATION GITEA [= team-publish.sh §2, à l'identique =] ──────────
# ── 3. AUTORITÉ PAR TOPOLOGIE [= team-publish.sh §3 : TEAM depuis providers =]
# ── 4. clone équipe + checkout MERGE_SHA + is-ancestor [= team-publish.sh §4 =]

# ── 5. LE MARQUEUR : digest pré-lu, archive fetchée, PUIS résolveur complet ──
# L'ordre est contraint par les interfaces : resolve_deploy_pin exige l'archive
# (6e arg) pour vérifier le digest, et le digest attendu vit DANS le marqueur.
# On pré-lit donc UNIQUEMENT archive_sha256 (au SHA mergé, jamais le worktree),
# on fetch par contenu, et le résolveur re-vérifie TOUT (pin, ancêtreté,
# version, digest — une divergence refusera là-bas, pas ici).
MARKER_REL="$(deploy_pin_marker_path "$API_NAME" "$TO_ENV")"
git -C "$TMP/team" show "${MERGE_SHA}:${MARKER_REL}" > "$TMP/marker.yaml" 2>/dev/null \
  || fail "PIN_ABSENT : ${MARKER_REL} absent au SHA mergé — la PR ne portait pas le marqueur"
PRE_SHA=$(DP_FILE="$TMP/marker.yaml" python3 -c 'import os,yaml;d=yaml.safe_load(open(os.environ["DP_FILE"])) or {};print(str(d.get("archive_sha256") or ""))') \
  || fail "PIN_MALFORMED : ${MARKER_REL} illisible"
case "$PRE_SHA" in *[!0-9a-f]*|"") fail "DIGEST_ABSENT : archive_sha256 absent/malformé dans ${MARKER_REL}";; esac
[ "${#PRE_SHA}" -eq 64 ] || fail "DIGEST_ABSENT : archive_sha256 long de ${#PRE_SHA}"
archive_store_fetch "$TEAM" "$API_NAME" "$PRE_SHA" "$TMP/archive.zip" 2>"$TMP/store.err" \
  || { cat "$TMP/store.err" >&2; REFUS="$(grep -o 'archive-store: [A-Z_]*' "$TMP/store.err" | tail -1)"; \
       fail "ARCHIVE_INTROUVABLE : ${REFUS:-voir le log} — l'export a-t-il été poussé au registre ?"; }
resolve_deploy_pin "$TMP/team" "$API_NAME" "$TO_ENV" "$TMP/resolved" origin/main "$TMP/archive.zip" \
  2>"$TMP/pin.err" || { cat "$TMP/pin.err" >&2; \
       REFUS="$(grep -o 'deploy-pin: [A-Z_]*' "$TMP/pin.err" | tail -1)"; \
       fail "PIN_NON_RESOLU : ${REFUS:-refus non nommé}"; }

# ── 6. LES EXIGENCES DE LA PORTE, RELUES SUR LE MARQUEUR MERGÉ ───────────────
# Le formulaire les a validées À LA DEMANDE ; on les re-vérifie sur ce qui a été
# MERGÉ (anti-TOCTOU : un marqueur édité entre la demande et le merge ne doit
# pas passer parce que le formulaire, lui, était propre).
GATE=$(env_chain_gate "$TO_ENV") || fail "PARSE_GATE"
case "$GATE" in GATE=*) GATE="${GATE#GATE=}";; *) fail "PARSE_GATE : sortie inattendue";; esac
NEED_CHANGE="${GATE%%|*}"; GATE="${GATE#*|}"; NEED_PV="${GATE%%|*}"
MK_FIELDS=$(DP_FILE="$TMP/marker.yaml" python3 -c 'import os,yaml;d=yaml.safe_load(open(os.environ["DP_FILE"])) or {};print("CR=%s\nPV=%s" % (str(d.get("change_ref") or ""), str(d.get("pv_ref") or "")))') \
  || fail "PIN_MALFORMED : relecture des références du marqueur"
MK_CHANGE=$(printf '%s\n' "$MK_FIELDS" | sed -n 's/^CR=//p')
MK_PV=$(printf '%s\n' "$MK_FIELDS" | sed -n 's/^PV=//p')
[ "$NEED_CHANGE" = 0 ] || [ -n "$MK_CHANGE" ] \
  || fail "GATE_REFS_REQUIRED : la porte vers '$TO_ENV' exige change_ref — absent du marqueur mergé"
[ "$NEED_PV" = 0 ] || [ -n "$MK_PV" ] \
  || fail "GATE_REFS_REQUIRED : la porte vers '$TO_ENV' exige pv_ref — absent du marqueur mergé"

# ── 7. LE PALIER EST-IL OUVERT ? (rétention G4 — ADR-082) ───────────────────
# La lecture du secret d'admin du palier EST le ticket d'entrée : palier jamais
# ouvert (policy apply-<env> non accordée / AppRole non minté) => 403 Vault =>
# refus nommé, gateway JAMAIS touchée. C'est le seul contrôle qu'un pipeline
# compromis ne se donne pas à lui-même.
VTOK="$(cat "$VAULT_TOKEN_FILE")" || fail "VAULT_TOKEN_ILLISIBLE"
WM_ADMIN_CODE=$(curl -sS -o "$TMP/wmadmin.json" -w '%{http_code}' --max-time 20 \
  -H "X-Vault-Token: $VTOK" "$VAULT_ADDR/v1/secret/data/stoa/envs/${TO_ENV}/wm-admin") || WM_ADMIN_CODE=000
unset VTOK
[ "$WM_ADMIN_CODE" = 200 ] \
  || fail "PALIER_FERME : lecture de envs/${TO_ENV}/wm-admin refusée (HTTP ${WM_ADMIN_CODE}) — le palier '$TO_ENV' n'est pas ouvert pour cette identité (ADR-082 : l'ouverture est un geste de credential, pas un edit de code)"

# ── 8. LE MOTEUR — UN SEUL SITE D'APPEL, APRÈS TOUT ─────────────────────────
APIM_BASE="$(printf '%s' "$APIM_API_BASE_TPL" | sed "s/__ENV__/${TO_ENV}/g")"
run_engine() {
  case "$PROMOTE_ENGINE" in
    ansible)
      ENGINE_AUTH_ARGS=""   # cf. bloc ADMIN_VIA ci-dessous
      ansible-playbook -i ansible/inventory.lab.ini ansible/promote-api.yml \
        -e apim_promote_action=import \
        -e apim_promote_manifest="$DEPLOY_PIN_PROMOTE" \
        -e apim_ss_archive_pin="$DEPLOY_PIN_ARCHIVE" \
        -e apim_ss_archive_sha256="$DEPLOY_PIN_SHA256" \
        -e apim_ss_env="$TO_ENV" \
        -e apim_ss_authoring_env="$ENVN_AUTH" \
        -e apim_ss_api_base="$APIM_BASE" \
        $ENGINE_AUTH_ARGS
      ;;
    labctl) … ;;   # cf. Step 5
    *) return 90 ;;   # ENGINE_INCONNU — refusé AVANT par la garde de forme
  esac
}
```
  Compléments imposés :
  - **Garde de forme sur le knob**, AVANT le site d'appel (avec les autres validations
    de tête) : `case "$PROMOTE_ENGINE" in ansible|labctl) ;; *) fail "ENGINE_INCONNU : '$PROMOTE_ENGINE'";; esac`
    — même chose pour `ADMIN_VIA`.
  - **Bloc ADMIN_VIA** (calcule `ENGINE_AUTH_ARGS` avant `run_engine`) :
    `proxy-oauth2` ⇒ `-e apim_ss_auth_mode=oauth2 -e apim_ss_vault_oauth_sub=envs/${TO_ENV}/admin-oauth` ;
    `direct` ⇒ `-e apim_ss_auth_mode=basic -e apim_ss_vault_wm_creds_sub=envs/${TO_ENV}/wm-admin`
    et `APIM_BASE` se calcule alors depuis `APIM_DIRECT_BASE_TPL` (second gabarit,
    requis seulement dans ce mode).
  - **Chemin labctl** : mint du Bearer AVANT (lecture `envs/${TO_ENV}/admin-oauth` avec
    le token Vault → `curl token_url` client_credentials+scope → `$TMP/bearer` 0600,
    échec ⇒ `BEARER_ECHEC` — toujours AVANT run_engine) ; génération
    `$TMP/targets.yaml` :

```yaml
targets:
  - name: wm-__ENV__
    type: webmethods
    adminUrl: <APIM_BASE sans le suffixe /rest/apigateway>
    auth:
      bearerTokenFile: <$TMP/bearer>
```
    (⚠ forme à CALQUER sur `envs/rec/targets.cluster.yaml:19-29` — la structure exacte
    du yaml targets fait foi, PAS ce squelette) ; puis
    `labctl promote --manifest "$DEPLOY_PIN_PROMOTE" --env "$TO_ENV" --action import
    --archive "$DEPLOY_PIN_ARCHIVE" -f "$TMP/targets.yaml"` (binaire : `$LABCTL_BIN`
    env, défaut `$WORKSPACE/labctl` — le Jenkinsfile le builde, motif `ci/Jenkinsfile:35-40`).
  - **§9 statut** : succès/échec sur la PR [= team-publish.sh §6, marqueur team-promote,
    résumé `PROMOTE_CONFIRMED|IMPORT_OK|ARCHIVE_DIGEST_OK` en succès, hiérarchie
    fatal>msg>tail-3 en échec =]. Pas de re-pose de formulaires ici (rien ne change
    dans les listes).
- [ ] **Step 5 : garde d'identité** — après §6, avant §7 (elle ne touche pas Vault) :

```bash
FE=$(env_chain_gate_four_eyes "$TO_ENV") || fail "PARSE_GATE : fourEyes"
case "$FE" in FOUREYES=1) AMI_ARGS="";; FOUREYES=0) AMI_ARGS="--allow-self-approval";; *) fail "PARSE_GATE : sortie inattendue ($FE)";; esac
# shellcheck disable=SC2086
sh scripts/lib/assert-merge-identity.sh --merged-by "${PR_MERGED_BY:-}" \
  --requester "${PR_REQUESTER:-}" --vault-user "${VAULT_IDENTITY_USER:?VAULT_IDENTITY_USER requis (posé par le Jenkinsfile depuis V_USER)}" $AMI_ARGS \
  || fail "IDENTITE_REFUSEE : la garde d'identité a refusé (voir le log)"
```
- [ ] **Step 6 :** `shellcheck` propre sur les 4 fichiers modifiés/créés ; probes de
  refus à la main (`WEBHOOK_REPO='x;y' … bash scripts/team-promote.sh` ⇒ refus de
  forme ; `PR_BRANCH=api/x-1.0` ⇒ sortie 0 « hors promote/* »).
- [ ] **Step 7 : commit** `feat(g5): team-promote — toutes les portes avant le moteur`.

---

### Task 7 : le job — `Jenkinsfile.team-promote`, son XML, sa pose

**Files:**
- Create: `ci/Jenkinsfile.team-promote`
- Create: `ci/jenkins/team-promote.job.xml`
- Modify: le script qui pose `team-publish.job.xml` (le trouver :
  `grep -ln "team-publish.job.xml" scripts/*.sh` → `setup-team-onboard-jobs.sh` ;
  `team-promote` rejoint la même pose)
- Modify: `scripts/test-jenkinsfile-lint.sh` (12 → 13)

**Interfaces:**
- Consomme : Task 6 (`scripts/team-promote.sh` + variables listées à son interface).
- Produit : job `team-promote` déclenché par le webhook EXISTANT des dépôts d'équipe
  (D1 : **même token GWT `stoa-team-publish`** — le plugin déclenche tous les jobs
  au token ; AUCUN geste sur les dépôts d'équipe).

Le Jenkinsfile est le MIROIR de `ci/Jenkinsfile.team-publish`, différences exactes :
1. `triggers { GenericTrigger( token: 'stoa-team-publish', … ) }` — MÊMES
  genericVariables (copier le bloc, y compris le commentaire « le XML gagne »),
  même regexpFilter closed|true.
2. Filtre de branche : `promote/` partout où team-publish dit `api/` (stage Contexte,
  `when { expression }`, bloc `post`).
3. `environment{}` : reprendre VAULT_ADDR/VAULT_USER_AUTH_MOUNT/GIT_HOST/GIT_REPO/
  GIT_WEB_HOST/GITEA_CREDENTIALS_ID, RETIRER APIM_API_BASE/JENKINS_UI, AJOUTER :

```groovy
    // Knob de PIPELINE (jamais un paramètre de build : la définition est
    // protégée — G4 D7 ; un paramètre rendrait le moteur choisissable par
    // quiconque déclenche). ansible = chemin client ; labctl = moteur lab.
    PROMOTE_ENGINE     = "${env.PROMOTE_ENGINE ?: 'ansible'}"
    ADMIN_VIA          = "${env.ADMIN_VIA ?: 'proxy-oauth2'}"
    // Gabarit d'URL admin par palier — __ENV__ substitué par team-promote.sh.
    APIM_API_BASE_TPL  = "${env.APIM_API_BASE_TPL ?: 'http://webmethods-real:5555/gateway/wm-admin-__ENV__/1.0/rest/apigateway'}"
```
4. La pause `input` : message « Promouvoir l'API portée par la PR fusionnée ? … »,
  mêmes V_USER/V_PASS ; le step d'identité N'appelle PAS assert-merge-identity dans le
  Jenkinsfile (team-publish le fait) : ici la garde vit DANS team-promote.sh (§Step 5
  Task 6 — le 4-yeux dépend de la porte, que seul le script lit). Le Jenkinsfile
  exporte `VAULT_IDENTITY_USER="${V_USER}"` dans le bloc sh.
5. Un stage préalable `Build labctl` (copie de `ci/Jenkinsfile:34-40`) quand
  `PROMOTE_ENGINE == 'labctl'` (`when { environment name: 'PROMOTE_ENGINE', value: 'labctl' }`).
6. `post` : marqueur `<!-- team-promote-build -->`, textes adaptés (promotion, pas
  publication).

Le job.xml : copie de `ci/jenkins/team-publish.job.xml` avec nom/description/token…
**identiques champ à champ à ce que le Jenkinsfile déclare** (le XML gagne — toute
divergence est silencieuse) ; l'épreuve Task 8 compare les deux.

- [ ] **Step 1 :** lire `Jenkinsfile.team-publish` + son job.xml + la pose ; écrire les
  trois livrables.
- [ ] **Step 2 :** `scripts/test-jenkinsfile-lint.sh` → 13/13 (compte mis à jour).
- [ ] **Step 3 :** `make lint-ci` vert. **Commit**
  `feat(g5): le job team-promote — meme webhook, branche promote/*, moteur knobbe`.

---

### Task 8 : l'épreuve — `test-team-promote-wiring.sh`, porte refusée ⇒ moteur jamais lancé

**Files:**
- Create: `scripts/test-team-promote-wiring.sh`
- Modify: `Makefile` (rejoint `lint-ci`)

**Interfaces:** consomme Tasks 6-7 (les fichiers qu'elle éprouve). Produit la porte
CI du jalon (avec Task 2).

Protocole en DEUX volets, compte PASS/FAIL, garde « verdicts == attendus », toutes les
captures en fichier :

**Volet A — statique (motif de `test-team-publish-wiring.sh`, sur code décommenté) :**
① les deux fichiers de job (Jenkinsfile + XML) portent le MÊME token GWT et les mêmes
genericVariables (comparaison des deux listes extraites) ; ② AUCUN bloc `parameters{}`
autre que l'input V_USER/V_PASS (PROMOTE_ENGINE/ADMIN_VIA absents des paramètres des
DEUX fichiers) ; ③ le filtre `promote/` est présent aux trois sites (contexte, when,
post) ; ④ `team-promote.sh` : `run_engine` défini UNE fois, appelé UNE fois, et
l'appel est la DERNIÈRE occurrence de la liste ordonnée des jetons de garde — extraire
les numéros de ligne (code décommenté) de `BRANCH_FORMAT_INVALIDE`, `PAYLOAD_PERIME`,
`REPO_NON_DECLARE`, `MERGE_SHA_NON_ANCETRE`, `PIN_ABSENT`, `ARCHIVE_INTROUVABLE`,
`PIN_NON_RESOLU`, `GATE_REFS_REQUIRED`, `IDENTITE_REFUSEE`, `PALIER_FERME`, puis du
premier appel de `run_engine` : chaque garde < site d'appel ; ⑤ le scellement :
`-e apim_ss_authoring_env=` présent (mutation : le retirer d'une copie ⇒ rouge) ;
`--archive "$DEPLOY_PIN_ARCHIVE"` présent sur le chemin labctl ; ⑥ `allowlist proxy` :
`/rest/apigateway/archive` présent dans `wm-admin-proxy.openapi.yaml`, et TOUJOURS
aucun `delete:` dans ce fichier ; ⑦ `env_chain_gate_four_eyes` : porte rec ⇒ 0,
porte int ⇒ 1 (sur le gabarit livré) ; `assert-merge-identity --allow-self-approval`
saute UNIQUEMENT le bloc 4-yeux (probe : merged_by==requester==vault-user passe AVEC
le flag, refuse SANS).

**Volet B — exécution avec stubs (la contre-épreuve du GOAL) :** un répertoire stub en
tête de PATH portant `ansible-playbook` et `labctl` qui écrivent `$STUB_LOG` et sortent
0 ; un stub Gitea+Vault python (un seul fichier, scénarios par variable d'env) servant
`GET /api/v1/repos/<r>/pulls/<n>` (payload piloté), `GET /repos/...` raw providers,
clones via de VRAIS dépôts git locaux (`git init --bare` + worktree, motif de
`test-deploy-pin.sh`), `GET/PUT /api/packages/...` (réutiliser le stub de Task 2),
`GET /v1/secret/data/...` (200 ou 403 piloté). Cas — pour CHACUN : refus attendu sur
stderr ET `$STUB_LOG` ABSENT :
⑧ WEBHOOK_REPO malformé ; ⑨ PR non mergée côté stub (PAYLOAD_PERIME) ; ⑩ branche
`promote/x-prod` avec marqueur absent (PIN_ABSENT) ; ⑪ digest absent du marqueur
(DIGEST_ABSENT) ; ⑫ archive jamais poussée (ARCHIVE_INTROUVABLE) ; ⑬ archive aux
mauvais octets (le résolveur refuse ARCHIVE_DIGEST_MISMATCH → PIN_NON_RESOLU) ;
⑭ porte int sans change_ref au marqueur (GATE_REFS_REQUIRED) ; ⑮ merger == requester
sur porte int (IDENTITE_REFUSEE) ; ⑯ Vault 403 (PALIER_FERME) ;
⑰ **chemin nominal** (tout propre, porte rec selfApproval, Vault 200) ⇒ sortie 0 ET
`$STUB_LOG` porte EXACTEMENT UNE invocation ansible-playbook avec
`apim_ss_env=rec`, `apim_ss_archive_pin=`, `apim_ss_authoring_env=dev` ;
⑱ idem `PROMOTE_ENGINE=labctl` ⇒ une invocation labctl avec `--archive` ;
⑲ **mutation finale** : déplacer (sed sur copie) l'appel `run_engine` AVANT la garde
PALIER_FERME ⇒ le volet A ④ rougit sur la copie — l'épreuve d'ordre n'est pas vacante.

- [ ] **Step 1 :** écrire le harnais (stubs compris) ; le faire tourner ROUGE d'abord en
  sabotant une garde à la main, puis vert complet.
- [ ] **Step 2 :** `Makefile` : rejoint `lint-ci` ; le harnais lui-même est EXÉCUTÉ, pas
  shellchecké (précédent test-deploy-pin, endossé G4).
- [ ] **Step 3 :** `make lint-ci` vert intégral. **Commit**
  `test(g5): porte refusee => moteur jamais lance — la contre-epreuve du GOAL`.

---

### Task 9 : les portes live — fidélité du mock, puis LE verbe par les deux moteurs

**Files:**
- Create: `scripts/test-promote-verb-live.sh`
- (exécution) `scripts/test-archive-promotion.sh` INCHANGÉ contre le mock

**Interfaces:** consomme Tasks 1 et 4. Lab requis (compose up). Rejouable, assets
jetables `g5live-*`, trap de nettoyage inconditionnel.

- [ ] **Step 1 : fidélité** — rebuilder et lancer le mock du socle :
  `docker compose -p stoa-labs-poc -f docker-compose.poc.yml up -d --build webmethods-mock`
  puis `GW_ADMIN=http://localhost:8090/rest/apigateway GW_DATA=http://localhost:8090/gateway
  WM_USER=… WM_PASS=… bash scripts/test-archive-promotion.sh` → **même X/X que sur le
  wM réel, script INCHANGÉ** (le contrat D7). Tout écart = correctif Task 1, jamais un
  patch du harnais.
- [ ] **Step 2 : écrire `test-promote-verb-live.sh`** — LA porte du GOAL, contre le wM
  réel (`GW_ADMIN=http://localhost:5555/rest/apigateway` par défaut). Pour
  `ENGINE in ansible labctl` (boucle, mêmes assertions) :
  1. setup jetable : alias `g5live-backend` → token-echo, API `g5live-api` v1.0.0
    routée `${alias}` via l'archive (reprendre le setup de test-archive-promotion.sh),
    ACTIVE ; manifeste promote jetable généré (`$WORK/g5live.promote.yml` : name,
    version, guid vide, archive `$WORK/g5live.zip`, overwrite par défaut, backend_alias
    name+per_env dev/rec → token-echo) ;
  2. **export par le moteur** : ansible ⇒ play action=export (extra-vars Task 5 step 5,
    api_base direct localhost:5555, auth basic env) ; labctl ⇒
    `labctl promote --manifest … --action export --archive $WORK/g5live.zip -f <targets
    direct basic>` ; assertion : zip existe, `EXPORT_CONFIRMED`/rapport, digest 64 hex,
    guid capturé (fichier, pas pipe) ;
  3. **0-coupure sous charge** : API active en place, charge 4 voies sur
    `/gateway/g5live-api/1.0.0/ping` pendant l'import par LE MOTEUR (guid pinné dans le
    manifeste — sed du champ guid) ⇒ TOUT 200 (`grep -cv '^200$'` == 0, > 50 requêtes) ;
    read-back : active, GUID inchangé ;
  4. **palier vierge simulé** (T9 ADR-079) : retrait souscriptions éventuelles,
    deactivate+delete DIRECT (script d'exploitation, pas le proxy), puis import par LE
    MOTEUR ⇒ GUID ISO (l'id relu == guid exporté), ACTIVE ;
  5. **contre-épreuve UPDATE_FORBIDDEN** : rejouer la garde du chemin publication hors
    authoring — `labctl` : cibler un targets `allowDeactivate: false` et tenter le
    deactivate (l'adapter refuse `UPDATE_FORBIDDEN`, cf.
    `labctl/internal/adapter/webmethods/inboundauth.go:935` ; s'il n'existe pas de
    commande CLI l'exerçant, la rejouer PAR LE RÔLE : play publish-api.yml
    `apim_ss_env=rec` sur une collision de version ⇒ le log porte UPDATE_FORBIDDEN et
    l'API reste ACTIVE — choisir la voie qui s'exerce sans nouvelle plomberie, dire
    laquelle au rapport) ;
  6. bilan PASS/FAIL par moteur, trap cleanup (app/API/alias/L2).
- [ ] **Step 3 : exécuter** contre le lab → X/X les deux moteurs. C'est LA porte G5.
- [ ] **Step 4 : commit** `test(g5): la porte du GOAL — guid iso + 0-coupure, par chacun des deux moteurs`.

---

### Task 10 : E2E chaîne sur le lab — du merge à la gateway de rec, et le refus fermé

**Files:** aucun nouveau (exécution + correctifs éventuels ; toute divergence mesurée
se corrige dans SA task d'origine, avec son épreuve).

Séquence (le contrôleur la déroule, gestes bloqués par le classifieur listés au
handoff en `! bash`) :
1. **Poser l'infra G5** : seed `admin-oauth` (Task 3, `setup-vault-envs.sh` rejoué ou
   son mode ciblé), `setup-vault-paliers.sh` re-posé (policies étendues), proxies
   re-posés (`setup-wm-admin-proxy.sh` — allowlist /archive), jobs posés
   (`setup-team-onboard-jobs.sh` : api-promote-export, team-promote ; **re-poser** —
   le config.xml gagne), mocks rebuildés
   (`docker compose … up -d --build wm-mock-dev wm-mock-rec wm-mock-int wm-mock-homol`).
2. **Ouvrir le palier rec** pour l'identité de test (geste ADR-082 —
   `ENVIRONNEMENTS.md` § « Ouvrir un palier ») : grant de la policy `apply-rec` à
   l'humain qui répondra à la pause.
3. **Chemin nominal** : API d'équipe publiée en dev (existante ou via api-request/
   team-publish) → job `api-promote-export` (build avec paramètres) →
   `EXPORT_CONFIRMED_SUMMARY` → guid épinglé dans `promote.yml` (PR ou push direct par
   `ci` selon les protections) → job `api-promote-request` (FROM dev TO rec, digest du
   summary) → PR `promote/<api>-rec` → merge par un AUTRE compte que le demandeur →
   webhook → build team-promote → pause répondue (V_USER = le merger) → **assertions** :
   build SUCCESS ; via le proxy `wm-admin-rec` (Bearer ci-horsprod) `GET /apis/<guid>`
   ⇒ 200, `isActive:true`, id == guid ; commentaire ✅ `team-promote` sur la PR.
4. **Moteur 2** : re-merge d'une promotion (nouvelle version ou re-run webhook) avec
   `PROMOTE_ENGINE=labctl` posé sur le job (variable d'env du job, pas un paramètre) ⇒
   mêmes assertions. (Si D1 se révèle faux — le job ne se déclenche pas au token
   partagé — appliquer le repli nommé de la spec : second webhook via team-apply.sh,
   et le DIRE au handoff.)
5. **Contre-épreuve de rétention (motif F4)** : révoquer le grant/la policy du palier
   (`vault policy delete apply-rec` ou retrait du grant) → rejouer le webhook → build
   FAILURE avec `PALIER_FERME` dans le commentaire ❌, **catalogue de wm-mock-rec
   INCHANGÉ** (relire avant/après par le proxy). Re-poser la policy ensuite
   (l'épreuve laisse le lab PROPRE — leçon impl-t9).
6. **Contre-épreuve TOCTOU marqueur** : PR de promotion dont le digest du marqueur est
   édité à la main après coup (commit direct impossible sous protection — passer par
   l'API en tant que `ci` si la whitelist l'admet, sinon simuler par un marqueur forgé
   dans une PR) ⇒ `ARCHIVE_INTROUVABLE` ou `DIGEST_*`, moteur jamais lancé (log de
   build : aucun `PLAY [`).

- [ ] **Step 1-6 :** dérouler ; chaque écart mesuré = correctif committé dans sa task.
- [ ] **Step 7 : commit final d'exécution** (fixes éventuels) + notes pour le handoff
  (numéros de builds, X/X).

---

### Task 11 : ADR-083 + ENVIRONNEMENTS.md

**Files:**
- Create: `adr/adr-083-verbe-archive-deux-moteurs.md`
- Modify: `ENVIRONNEMENTS.md` (section « Promouvoir une API (G5) »)

**ADR-083** (miroir de forme d'`adr/adr-082-…`) : le verbe (archive, jamais re-POST
hors authoring), le transport adressé par contenu (registre Gitea, la version EST le
sha256), le régime deux moteurs (décision n°6 du GOAL, knob de pipeline, G8 = la
contrepartie), le refus antérieur au play (l'ordre des gardes est une ÉPREUVE, pas une
convention), la rétention consommée (PALIER_FERME = ADR-082 en action), les limites
NOMMÉES : approverGroup non vérifié (G2), parité non prouvée (G8), client OAuth partagé
entre paliers hors-prod (parking spec §8-2), conversion du pipeline governance (parking
spec §8-3, la tension avec « apply-uac reste le verbe de dev » écrite noir sur blanc).

**ENVIRONNEMENTS.md** : le parcours complet du § Flux de la spec (§3) côté opérateur :
publier → exporter (job) → épingler le guid (PR) → demander (job) → merger → répondre à
la pause → vérifier ; le geste d'ouverture de palier RÉFÉRENCÉ (section G4 existante) ;
le repli « archive jamais poussée » (`ARCHIVE_INTROUVABLE` → rejouer l'export).

- [ ] **Step 1 :** écrire les deux ; relecture croisée avec la spec (aucune promesse
  au-delà de ce que les portes prouvent).
- [ ] **Step 2 : commit** `docs(g5): adr-083 — le verbe archive et son transport`.

---

## Self-review du plan (fait à l'écriture)

- **Couverture spec** : D1→T7, D2→T2, D3→T5, D4→T6, D5→T3+T6, D6→T6+T7, D7→T1+T9,
  D8→T3, D9→T11 (parking documenté) ; portes offline §4.1-4→T2/T8, live §4.5-7→T9/T10 ;
  §4.1 (ce que G5 ne prouve pas)→T11.
- **Types/interfaces** : `archive_store_push/fetch` (T2) consommés T5/T6 avec les mêmes
  signatures ; `apim_ss_archive_pin`/`--archive` (T4) consommés T5/T6 ;
  `env_chain_gate_four_eyes` (T6) éprouvé T8 ; `VAULT_IDENTITY_USER` produit T7,
  consommé T6.
- **Écart connu, assumé** : le squelette de `team-promote.sh` référence des blocs
  `[= team-publish.sh §N =]` à reprendre du fichier réel — c'est le motif maison
  (le fichier source fait foi), pas un placeholder : chaque bloc est nommé avec ses
  numéros de ligne et ses refus.
