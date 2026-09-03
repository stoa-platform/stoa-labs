# Promotion sans recopie — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal :** solder la dette du formulaire de promotion — job `api-promote-request` posé, `promote.yml` rendu/épinglé par l'export (guid, sha256, version), champ `ARCHIVE_SHA256` facultatif — zéro fichier à la main, zéro recopie.

**Architecture :** la logique nouvelle vit dans une bibliothèque shell pure (`scripts/lib/promote-manifest.sh`, offline-testable), branchée dans les deux scripts moteurs existants (`api-promote-export.sh`, `api-promote-request.sh`). Le job Jenkins est une coquille pipeline-from-SCM posée par XML, miroir exact du Jenkinsfile déjà livré. Une suite d'épreuves dédiée accompagne chaque geste.

**Tech stack :** POSIX sh + bash, python3 (+PyYAML) pour lire/écrire le YAML, sed pour l'édition chirurgicale (préserve les commentaires), Go (test labctl), Jenkins pipeline-from-SCM, Gitea API.

**Spec :** `docs/superpowers/specs/2026-08-28-promotion-sans-recopie-design.md`

## Global Constraints

- Commits : `type(scope): description` (commitlint) — scope `promo` pour ce chantier ; commentaires et messages en français, style du dépôt (POURQUOI, pièges nommés).
- Fail-closed nommé : tout refus a un code greppable (`PUBLISH_MANIFEST_ABSENT`, `DIGEST_ABSENT`, `DIGEST_MALFORMED`, `PIN_DEJA_A_JOUR`…). Jamais de repli silencieux.
- Jamais de token en argv/URL : header Basic via `GIT_CONFIG_COUNT/KEY_0/VALUE_0`, motif `api-request.sh:344-349`.
- YAML écrit machine avec des valeurs venues d'un humain ⇒ sérialiseur (`yaml.safe_dump`) ou sed sur nos propres gabarits — jamais de `%`-formatage de valeurs libres.
- Champ vide ≠ absence (piège T10) : le gabarit OMET `backend_alias`/`cred_alias`/`scope_mapping`/`per_env`.
- Branches ouvertes par l'export : préfixe `chore/` — jamais `api/*` (réveille team-publish) ni `promote/*` (réveille team-promote).
- `make lint-ci` doit rester vert à chaque tâche (shellcheck inclut les nouveaux fichiers ; le glob Jenkinsfile prend le 12ᵉ automatiquement).
- Le lab tourne : Gitea `http://localhost:13000` (`poc-gitea`), Jenkins `http://localhost:18080` (`poc-jenkins`), non authentifié en local.
- Chaque commit se termine par `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` (les blocs `git commit` ci-dessous l'omettent pour la lisibilité — l'ajouter systématiquement).

---

### Task 1 : bibliothèque `promote-manifest.sh` + gabarit + début de la suite

**Files:**
- Create: `gateways/templates/promote.yml.tmpl`
- Create: `scripts/lib/promote-manifest.sh`
- Create: `scripts/test-promote-sans-recopie.sh`
- Modify: `Makefile` (liste shellcheck de `lint-ci` : ajouter `scripts/lib/promote-manifest.sh`)

**Interfaces:**
- Produces (consommées par Tasks 3/4) :
  - `render_promote_manifest <team_dir> <api_name> <tmpl_path>` → écrit `<team_dir>/apis/<api>.promote.yml`, échoue `PUBLISH_MANIFEST_ABSENT` si `<team_dir>/apis/<api>.publish.yml` absent, `PUBLISH_MANIFEST_ILLISIBLE` si name/version n'en sont pas extractibles.
  - `pin_promote_manifest <manifest_path> <guid> <sha256> [version]` → remplace la valeur de `guid:`, remplace-ou-insère `archive_sha256:` (après la ligne guid), et si `[version]` est fourni réaligne `version:` et la ligne `archive:` ; préserve les commentaires ; idempotent.
  - `manifest_pinned_digest <manifest_path>` → imprime `apim_promote.archive_sha256` (chaîne vide si clé absente ou fichier absent) ; rc=0 toujours sauf YAML illisible (rc=1, `MANIFESTE_ILLISIBLE`).
  - `publish_manifest_version <team_dir> <api_name>` → imprime la version du `publish.yml` (utilisée par Task 4 pour le réalignement).

- [ ] **Étape 1 : écrire le gabarit**

`gateways/templates/promote.yml.tmpl` :

```yaml
---
# apis/__API_NAME__.promote.yml — manifeste de PROMOTION (vars du rôle
# apim_promote_api, ADR-079). RENDU par scripts/api-promote-export.sh depuis
# gateways/templates/promote.yml.tmpl ; guid, archive_sha256 et version sont
# ÉPINGLÉS par l'export (PR) — jamais recopiés à la main (spec
# 2026-08-28-promotion-sans-recopie).
#
# AUTHORING LÉGITIME (à la main, PR sur ce dépôt) : ajouter backend_alias /
# cred_alias / scope_mapping / per_env pour une API à backend aliasé — forme
# de référence : clients/_example/apis/accounts-read.promote.yml. Les AJOUTER,
# jamais les poser vides : champ vide ≠ absence (ansible le traverse, labctl
# refuse — piège mesuré T10).
apim_promote:
  name: "__API_NAME__"
  version: "__API_VERSION__"
  # id-map (ADR-079) : GUID épinglé à l'export, IDENTIQUE sur toutes les gateways.
  guid: ""
  # sha256 de l'archive au registre (adressage par le contenu : la version du
  # package EST ce sha) — lu par api-promote-request quand ARCHIVE_SHA256 est vide.
  archive_sha256: ""
  # Usage hors-CI seulement : le CI épingle l'archive fetchée via apim_ss_archive_pin.
  archive: "{{ playbook_dir }}/../dist/__API_NAME__-__API_VERSION__.archive.zip"
  overwrite: "apis,policies,policyactions"   # JAMAIS aliases ni * (clobber per-env)
  smoke_path: ""
```

- [ ] **Étape 2 : écrire la suite avec les épreuves 1–6 (elles échouent : la lib n'existe pas)**

`scripts/test-promote-sans-recopie.sh` (motif ok/ko des wiring-tests) :

```bash
#!/usr/bin/env bash
# test-promote-sans-recopie.sh — porte de la spec 2026-08-28 : le manifeste de
# promotion se rend, s'épingle et se lit SANS recopie humaine. Épreuves hors
# ligne (lib pure + gabarit + miroirs) ; l'E2E se rend par builds réels.
set -uo pipefail
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*" >&2; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# shellcheck source=scripts/lib/promote-manifest.sh
. scripts/lib/promote-manifest.sh

# fixture : dépôt d'équipe minimal
mkdir -p "$TMP/team/apis"
cat > "$TMP/team/apis/demo-api.publish.yml" <<'EOF'
apim_api:
  name: "demo-api"
  version: "2.1.0"
  inbound:
    mode: "jwt"
EOF

echo "== 1. rendu nominal depuis publish.yml =="
if render_promote_manifest "$TMP/team" demo-api gateways/templates/promote.yml.tmpl; then
  M="$TMP/team/apis/demo-api.promote.yml"
  grep -q 'name: "demo-api"' "$M" && grep -q 'version: "2.1.0"' "$M" \
    && ok "name/version dérivés du publish.yml" || ko "name/version non dérivés"
  python3 - "$M" <<'PY' && ok "YAML parse (chemin ansible)" || ko "YAML illisible"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d["apim_promote"]["name"] == "demo-api"
assert d["apim_promote"]["guid"] == ""
PY
  for cle in backend_alias cred_alias scope_mapping per_env; do
    grep -q "$cle" "$M" && ko "clé interdite présente : $cle (champ vide ≠ absence, T10)" || :
  done
  ok "aucune clé optionnelle posée vide"
else
  ko "rendu nominal en échec"
fi

echo "== 2. publish.yml absent ⇒ refus nommé =="
mkdir -p "$TMP/vide/apis"
OUT=$(render_promote_manifest "$TMP/vide" fantome gateways/templates/promote.yml.tmpl 2>&1) \
  && ko "rendu accepté sans publish.yml" \
  || { echo "$OUT" | grep -q PUBLISH_MANIFEST_ABSENT && ok "PUBLISH_MANIFEST_ABSENT" || ko "refus sans nom ($OUT)"; }

echo "== 3. épinglage guid+sha : chirurgical, commentaires préservés =="
M="$TMP/team/apis/demo-api.promote.yml"
AVANT_COMMENTAIRES=$(grep -c '^\s*#' "$M")
pin_promote_manifest "$M" "14c2529e-0000-4000-8000-00000000aaaa" \
  "1111111111111111111111111111111111111111111111111111111111111111" \
  && ok "pin rc=0" || ko "pin en échec"
python3 - "$M" <<'PY' && ok "guid+sha relus par yaml" || ko "valeurs épinglées absentes"
import sys, yaml
p = yaml.safe_load(open(sys.argv[1]))["apim_promote"]
assert p["guid"] == "14c2529e-0000-4000-8000-00000000aaaa"
assert p["archive_sha256"] == "1" * 64
PY
[ "$(grep -c '^\s*#' "$M")" -eq "$AVANT_COMMENTAIRES" ] \
  && ok "commentaires préservés" || ko "commentaires perdus (édition non chirurgicale)"

echo "== 4. épinglage idempotent + réalignement de version =="
COPIE=$(cat "$M")
pin_promote_manifest "$M" "14c2529e-0000-4000-8000-00000000aaaa" \
  "1111111111111111111111111111111111111111111111111111111111111111"
[ "$(cat "$M")" = "$COPIE" ] && ok "second pin = aucun diff" || ko "pin non idempotent"
pin_promote_manifest "$M" "14c2529e-0000-4000-8000-00000000aaaa" \
  "2222222222222222222222222222222222222222222222222222222222222222" "2.2.0"
grep -q 'version: "2.2.0"' "$M" && grep -q 'demo-api-2.2.0.archive.zip' "$M" \
  && ok "version+archive réalignés" || ko "réalignement version manquant"

echo "== 5. manifest_pinned_digest : présent / absent / illisible =="
[ "$(manifest_pinned_digest "$M")" = "$(printf '2%.0s' $(seq 64))" ] \
  && ok "digest lu" || ko "digest non lu"
[ -z "$(manifest_pinned_digest "$TMP/team/apis/inexistant.promote.yml")" ] \
  && ok "fichier absent ⇒ chaîne vide, rc=0" || ko "fichier absent mal géré"
printf '{{invalide' > "$TMP/cassé.yml"
manifest_pinned_digest "$TMP/cassé.yml" 2>/dev/null \
  && ko "YAML illisible accepté" || ok "YAML illisible ⇒ rc=1 (MANIFESTE_ILLISIBLE)"

echo "== 6. publish_manifest_version =="
[ "$(publish_manifest_version "$TMP/team" demo-api)" = "2.1.0" ] \
  && ok "version du publish.yml lue" || ko "version non lue"

echo; echo "bilan : $PASS ✅  $FAIL ❌"
[ "$FAIL" -eq 0 ]
```

- [ ] **Étape 3 : lancer la suite, vérifier l'échec attendu**

Run : `bash scripts/test-promote-sans-recopie.sh`
Attendu : échec immédiat — `scripts/lib/promote-manifest.sh` introuvable.

- [ ] **Étape 4 : écrire la bibliothèque**

`scripts/lib/promote-manifest.sh` :

```sh
#!/bin/sh
# promote-manifest.sh — rendu, épinglage et lecture du manifeste de promotion
# (spec 2026-08-28-promotion-sans-recopie). Bibliothèque PURE : aucune E/S
# réseau, uniquement des fichiers passés en argument — c'est ce qui la rend
# éprouvable hors ligne (test-promote-sans-recopie.sh) là où les scripts
# appelants exigent Gitea/Vault.
#
# ÉDITION CHIRURGICALE, PAS DE ROUND-TRIP YAML : un safe_dump réécrirait le
# fichier entier et détruirait les commentaires — or le manifeste est AUSSI un
# document d'authoring (backend_alias, per_env ajoutés à la main). On ne
# touche que les lignes qu'on possède (guid/archive_sha256/version/archive),
# posées par notre propre gabarit, à l'indentation connue (2 espaces).

_pm_fail() { printf 'ERREUR: %s\n' "$*" >&2; return 1; }

# publish_manifest_version <team_dir> <api_name> — version portée par le
# publish.yml d'authoring (la vérité de ce qui est publié en dev).
publish_manifest_version() {
  _pub="$1/apis/$2.publish.yml"
  [ -f "$_pub" ] || { _pm_fail "PUBLISH_MANIFEST_ABSENT : $_pub — cette API n'est pas publiée en authoring"; return 1; }
  _v=$(python3 - "$_pub" <<'PY' 2>/dev/null
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
a = d.get("apim_api") or {}
n, v = a.get("name") or "", a.get("version") or ""
print(v if (n and v) else "")
PY
) || _v=""
  [ -n "$_v" ] || { _pm_fail "PUBLISH_MANIFEST_ILLISIBLE : $_pub — name/version inextractibles"; return 1; }
  printf '%s' "$_v"
}

# render_promote_manifest <team_dir> <api_name> <tmpl_path>
# Rend apis/<api>.promote.yml depuis le gabarit, name/version dérivés du
# publish.yml — même motif de substitution que api-request.sh:323-326.
render_promote_manifest() {
  _dir="$1"; _api="$2"; _tmpl="$3"
  _ver=$(publish_manifest_version "$_dir" "$_api") || return 1
  [ -f "$_tmpl" ] || { _pm_fail "GABARIT_ABSENT : $_tmpl"; return 1; }
  sed -e "s/__API_NAME__/${_api}/g" -e "s/__API_VERSION__/${_ver}/g" \
    "$_tmpl" > "$_dir/apis/$_api.promote.yml" \
    || { _pm_fail "RENDU_ECHEC : écriture de apis/$_api.promote.yml"; return 1; }
}

# manifest_pinned_digest <manifest_path> — le sha épinglé, '' si absent.
# Fichier absent = pas une erreur (le premier export n'a rien à lire) ;
# YAML illisible = erreur (un fichier corrompu ne doit pas passer pour vide).
manifest_pinned_digest() {
  [ -f "$1" ] || { printf ''; return 0; }
  python3 - "$1" <<'PY' 2>/dev/null || { _pm_fail "MANIFESTE_ILLISIBLE : $1"; return 1; }
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
print((d.get("apim_promote") or {}).get("archive_sha256") or "")
PY
}

# pin_promote_manifest <manifest_path> <guid> <sha256> [version]
# sed chirurgical sur NOS lignes (gabarit : indentation 2 espaces). La ligne
# archive_sha256 est insérée après guid si le manifeste (antérieur au gabarit,
# ex. t10) ne la porte pas encore.
pin_promote_manifest() {
  _m="$1"; _g="$2"; _s="$3"; _v="${4:-}"
  [ -f "$_m" ] || { _pm_fail "MANIFESTE_ABSENT : $_m"; return 1; }
  sed -i.bak -e "s|^\(  guid:\).*|\1 \"${_g}\"|" "$_m"
  if grep -q '^  archive_sha256:' "$_m"; then
    sed -i.bak -e "s|^\(  archive_sha256:\).*|\1 \"${_s}\"|" "$_m"
  else
    sed -i.bak -e "/^  guid:/a\\
  archive_sha256: \"${_s}\"" "$_m"
  fi
  if [ -n "$_v" ]; then
    _api=$(python3 - "$_m" <<'PY'
import sys, yaml
print((yaml.safe_load(open(sys.argv[1])) or {}).get("apim_promote", {}).get("name", ""))
PY
)
    sed -i.bak -e "s|^\(  version:\).*|\1 \"${_v}\"|" \
      -e "s|/${_api}-[0-9][0-9.]*\.archive\.zip|/${_api}-${_v}.archive.zip|" "$_m"
  fi
  rm -f "$_m.bak"
  # relecture fail-closed : l'épinglage doit se RELIRE, pas se supposer
  _lu=$(manifest_pinned_digest "$_m") || return 1
  [ "$_lu" = "$_s" ] || _pm_fail "PIN_NON_RELU : écrit ${_s}, relu '${_lu}' — édition chirurgicale en échec"
}
```

- [ ] **Étape 5 : relancer la suite, tout vert**

Run : `bash scripts/test-promote-sans-recopie.sh`
Attendu : `bilan : N ✅  0 ❌` (épreuves 1–6).

- [ ] **Étape 6 : brancher shellcheck**

Dans `Makefile`, cible `lint-ci`, bloc `@shellcheck -x ci/lib/*.sh …` : ajouter `scripts/lib/promote-manifest.sh` et `scripts/test-promote-sans-recopie.sh` à la liste (après `scripts/lib/archive-store.sh`). Run : `make lint-ci` → vert.

- [ ] **Étape 7 : commit**

```bash
git add gateways/templates/promote.yml.tmpl scripts/lib/promote-manifest.sh \
  scripts/test-promote-sans-recopie.sh Makefile
git commit -m "feat(promo): lib promote-manifest — rendu, épinglage, lecture du manifeste sans recopie"
```

---

### Task 2 : épreuve labctl — la clé `archive_sha256` est tolérée (et le reste)

**Files:**
- Modify: `labctl/cmd/labctl/promote_test.go` (nouveau test en fin de fichier)
- Modify: `scripts/test-promote-sans-recopie.sh` (épreuve 7)

**Interfaces:**
- Consumes : `loadPromoteManifest(path, env string) (promoteSpec, error)` (`labctl/cmd/labctl/promote.go:116`).

- [ ] **Étape 1 : écrire le test Go (échoue s'il ne compile pas — vérifier qu'il passe : le parse non strict est un fait mesuré qu'on FIGE ici)**

Ajouter à `labctl/cmd/labctl/promote_test.go` :

```go
// TestPromoteSpecToleratesPinnedSha fige un fait que la spec « promotion sans
// recopie » (2026-08-28) exploite : le manifeste porte désormais une clé
// archive_sha256 épinglée par l'export, lue par api-promote-request.sh —
// jamais par ce moteur. loadPromoteManifest décode en NON-strict
// (sigsyaml.Unmarshal + json.Unmarshal) : la clé doit passer sans erreur.
// Si quelqu'un rend un jour ce décodage strict, CE test rougit et nomme la
// dépendance — au lieu d'un formulaire de promotion qui casse en silence.
func TestPromoteSpecToleratesPinnedSha(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "demo.promote.yml")
	manifest := `apim_promote:
  name: "demo-api"
  version: "2.1.0"
  guid: "14c2529e-0000-4000-8000-00000000aaaa"
  archive_sha256: "1111111111111111111111111111111111111111111111111111111111111111"
  archive: "/tmp/demo.zip"
  overwrite: "apis,policies,policyactions"
  smoke_path: ""
`
	if err := os.WriteFile(p, []byte(manifest), 0o600); err != nil {
		t.Fatal(err)
	}
	spec, err := loadPromoteManifest(p, "")
	if err != nil {
		t.Fatalf("archive_sha256 doit être tolérée par le décodage non strict : %v", err)
	}
	if spec.Name != "demo-api" || spec.GUID != "14c2529e-0000-4000-8000-00000000aaaa" {
		t.Fatalf("spec mal décodée : %+v", spec)
	}
}
```

(Si `os`/`filepath` ne sont pas déjà importés par le fichier de test, les ajouter aux imports.)

- [ ] **Étape 2 : lancer le test**

Run : `cd labctl && go test ./cmd/labctl -run TestPromoteSpecToleratesPinnedSha -v`
Attendu : PASS.

- [ ] **Étape 3 : brancher l'épreuve 7 dans la suite**

Ajouter avant le bilan de `scripts/test-promote-sans-recopie.sh` :

```bash
echo "== 7. labctl tolère la clé épinglée (parse non strict FIGÉ par le test Go) =="
command -v go >/dev/null 2>&1 || { ko "go absent — l'épreuve labctl ne peut pas se rendre (ne PAS sauter en silence)"; }
if command -v go >/dev/null 2>&1; then
  ( cd labctl && go test ./cmd/labctl -run TestPromoteSpecToleratesPinnedSha >/dev/null 2>&1 ) \
    && ok "TestPromoteSpecToleratesPinnedSha PASS" || ko "labctl refuse archive_sha256"
fi
```

Run : `bash scripts/test-promote-sans-recopie.sh` → `0 ❌`.

- [ ] **Étape 4 : commit**

```bash
git add labctl/cmd/labctl/promote_test.go scripts/test-promote-sans-recopie.sh
git commit -m "test(promo): labctl fige la tolérance de archive_sha256 (parse non strict mesuré)"
```

---

### Task 3 : `api-promote-request.sh` — `ARCHIVE_SHA256` facultatif

**Files:**
- Modify: `scripts/api-promote-request.sh` (Garde 3 lignes ~147-157 ; résolution post-clone avant `reconcile_promotion_digest` ligne ~239 ; en-tête ligne 24)
- Modify: `scripts/test-promote-sans-recopie.sh` (épreuves 8–9)

**Interfaces:**
- Consumes : `manifest_pinned_digest` (Task 1), `reconcile_promotion_digest` (`scripts/lib/deploy-pin.sh:449` — forme vide + hérité ⇒ hérité, déjà en place).

- [ ] **Étape 1 : épreuves 8–9 dans la suite (échouent : le script refuse encore le champ vide)**

```bash
echo "== 8. request DRY_RUN : ARCHIVE_SHA256 vide ne bloque plus les gardes amont =="
OUT=$(TEAM=banking-demo API_NAME=demo-api FROM_ENV=dev TO_ENV=rec \
      MESSAGE="épreuve 8" ARCHIVE_SHA256= DRY_RUN=1 \
      bash scripts/api-promote-request.sh 2>&1)
echo "$OUT" | grep -q "GARDES_OK" && echo "$OUT" | grep -q "DIGEST_DIFFERE" \
  && ok "champ vide ⇒ DIGEST_DIFFERE + gardes vertes" \
  || ko "champ vide encore refusé en amont : $OUT"

echo "== 9. request DRY_RUN : forme invalide toujours refusée TÔT =="
OUT=$(TEAM=banking-demo API_NAME=demo-api FROM_ENV=dev TO_ENV=rec \
      MESSAGE="épreuve 9" ARCHIVE_SHA256=zz DRY_RUN=1 \
      bash scripts/api-promote-request.sh 2>&1) \
  && ko "sha 'zz' accepté" \
  || { echo "$OUT" | grep -q DIGEST_MALFORMED && ok "DIGEST_MALFORMED" || ko "refus sans nom : $OUT"; }
```

Run : `bash scripts/test-promote-sans-recopie.sh` → épreuve 8 ROUGE (DIGEST_ABSENT amont), épreuve 9 verte.

- [ ] **Étape 2 : réécrire la Garde 3**

Remplacer dans `scripts/api-promote-request.sh` (lignes ~147-157) :

```sh
# ── Garde 3 : LE DIGEST ─────────────────────────────────────────────────────
if [ "$TO_ENV" != "$AUTHORING_ENV" ]; then
  [ -n "$ARCHIVE_SHA256" ] \
    || fail "DIGEST_ABSENT : promotion vers '$TO_ENV' sans ARCHIVE_SHA256 — les octets déployés doivent être pinnés (sortie EXPORT_CONFIRMED)"
  case "$ARCHIVE_SHA256" in
    *[!0-9a-f]* | "") fail "DIGEST_MALFORMED : '$ARCHIVE_SHA256' n'est pas un sha256 hexadécimal minuscule" ;;
  esac
  [ "${#ARCHIVE_SHA256}" -eq 64 ] \
    || fail "DIGEST_MALFORMED : sha256 attendu sur 64 caractères, reçu ${#ARCHIVE_SHA256}"
fi
```

par :

```sh
# ── Garde 3 : LE DIGEST ─────────────────────────────────────────────────────
# FACULTATIF depuis la spec « promotion sans recopie » (2026-08-28) : vide, il
# sera RÉSOLU après le clone — depuis dev, le sha épinglé du manifeste
# (apim_promote.archive_sha256, posé par la PR d'export) ; au-delà, le digest
# HÉRITÉ du palier source (reconcile_promotion_digest, comportement existant).
# Ce qui reste amont : la FORME d'une valeur explicite (refus tôt, hors ligne),
# et l'avertissement qu'une résolution est différée. Le refus DIGEST_ABSENT
# n'a pas disparu — il a déménagé APRÈS la résolution, où il a le droit de
# conclure (ici, conclure serait exiger la recopie que la spec supprime).
if [ -n "$ARCHIVE_SHA256" ]; then
  case "$ARCHIVE_SHA256" in
    *[!0-9a-f]*) fail "DIGEST_MALFORMED : '$ARCHIVE_SHA256' n'est pas un sha256 hexadécimal minuscule" ;;
  esac
  [ "${#ARCHIVE_SHA256}" -eq 64 ] \
    || fail "DIGEST_MALFORMED : sha256 attendu sur 64 caractères, reçu ${#ARCHIVE_SHA256}"
elif [ "$TO_ENV" != "$AUTHORING_ENV" ]; then
  echo "DIGEST_DIFFERE : ARCHIVE_SHA256 vide — sera lu après clone (manifeste épinglé depuis dev, palier source au-delà)"
fi
```

- [ ] **Étape 3 : sourcer la lib et résoudre après le clone**

En tête de script, après `. scripts/lib/env-chain.sh` et `. scripts/lib/deploy-pin.sh`, ajouter :

```sh
# shellcheck source=scripts/lib/promote-manifest.sh
. scripts/lib/promote-manifest.sh
```

Puis juste AVANT l'appel `ARCHIVE_SHA256=$(reconcile_promotion_digest …)` (ligne ~239), insérer :

```sh
# ── LE DIGEST, RÉSOLU (spec promotion-sans-recopie) ─────────────────────────
# Depuis dev : le manifeste épinglé par la PR d'export fait foi quand le
# formulaire est vide. Un formulaire explicite GAGNE (désignation d'une archive
# antérieure, cas légitime) — mais une contradiction se DIT, bruyamment : le
# marqueur mergé portera le sha retenu, et c'est le merge qui l'approuve.
if [ "$FROM_ENV" = "$AUTHORING_ENV" ]; then
  MANIFEST_SHA=$(manifest_pinned_digest "$TMP/team/apis/${API_NAME}.promote.yml") \
    || fail "MANIFESTE_ILLISIBLE : apis/${API_NAME}.promote.yml ne se lit pas — impossible de résoudre le digest"
  if [ -z "$ARCHIVE_SHA256" ]; then
    ARCHIVE_SHA256="$MANIFEST_SHA"
    [ -n "$ARCHIVE_SHA256" ] && echo "DIGEST_RESOLU : archive_sha256 lu sur main (manifeste épinglé) = ${ARCHIVE_SHA256}"
  elif [ -n "$MANIFEST_SHA" ] && [ "$ARCHIVE_SHA256" != "$MANIFEST_SHA" ]; then
    echo "AVERTISSEMENT DIGEST_EXPLICITE : le formulaire (${ARCHIVE_SHA256}) remplace la valeur épinglée du manifeste (${MANIFEST_SHA}) — désignation explicite, le merge de la PR l'approuvera" >&2
  fi
fi
```

Et APRÈS l'appel à `reconcile_promotion_digest`, ajouter le refus qui a déménagé :

```sh
[ -n "$ARCHIVE_SHA256" ] \
  || fail "DIGEST_ABSENT : promotion vers '$TO_ENV' sans digest — ni formulaire, ni manifeste épinglé (mergez la PR d'api-promote-export d'abord), ni palier source"
```

Enfin, mettre à jour l'en-tête (ligne 24) : `ARCHIVE_SHA256  (facultatif — résolu depuis le manifeste épinglé (dev) ou hérité du palier source)`.

- [ ] **Étape 4 : suite verte + validation forme du digest RÉSOLU**

La forme du digest résolu (manifeste corrompu portant `archive_sha256: "zz"`) doit refuser aussi : ajouter à l'épreuve 8 de la suite :

```bash
# un manifeste épinglé MALFORMÉ ne doit pas passer pour une désignation
mkdir -p "$TMP/team2/apis"; cp "$TMP/team/apis/demo-api.promote.yml" "$TMP/team2/apis/"
sed -i.bak 's|^\(  archive_sha256:\).*|\1 "zz"|' "$TMP/team2/apis/demo-api.promote.yml"
[ "$(manifest_pinned_digest "$TMP/team2/apis/demo-api.promote.yml")" = "zz" ] \
  && ok "digest malformé LU par la lib (le refus de forme appartient au script après résolution)" \
  || ko "lecture du digest malformé incohérente"
```

et dans le script, la validation de forme déjà écrite en Garde 3 doit se REJOUER sur la valeur résolue — déplacer les deux `case`/`[ ${#…} -eq 64 ]` dans une fonction locale `valider_digest()` appelée (a) en Garde 3 sur la valeur explicite, (b) après résolution/réconciliation sur la valeur retenue :

```sh
valider_digest() {
  case "$1" in
    *[!0-9a-f]*) fail "DIGEST_MALFORMED : '$1' n'est pas un sha256 hexadécimal minuscule" ;;
  esac
  [ "${#1}" -eq 64 ] || fail "DIGEST_MALFORMED : sha256 attendu sur 64 caractères, reçu ${#1}"
}
```

(Garde 3 : `[ -n "$ARCHIVE_SHA256" ] && valider_digest "$ARCHIVE_SHA256"` ; post-réconciliation : `valider_digest "$ARCHIVE_SHA256"` après le refus DIGEST_ABSENT.)

Run : `bash scripts/test-promote-sans-recopie.sh` → `0 ❌` ; `make lint-ci` → vert (shellcheck couvre déjà `api-promote-request.sh`).

- [ ] **Étape 5 : commit**

```bash
git add scripts/api-promote-request.sh scripts/test-promote-sans-recopie.sh
git commit -m "feat(promo): ARCHIVE_SHA256 facultatif — résolu du manifeste épinglé (dev) ou hérité du palier source"
```

---

### Task 4 : `api-promote-export.sh` — rendre, réaligner, épingler, PR idempotente

**Files:**
- Modify: `scripts/api-promote-export.sh` (sourcing lib ; bloc manifeste lignes ~124-127 ; bloc final après `PUSHED_SHA` lignes ~200-207)
- Modify: `scripts/test-promote-sans-recopie.sh` (épreuve 10 — rendu+pin bout à bout sur fixture, sans réseau)

**Interfaces:**
- Consumes : `render_promote_manifest`, `pin_promote_manifest`, `publish_manifest_version`, `manifest_pinned_digest` (Task 1) ; motif push/PR d'`api-request.sh:330-377`.
- Produces : branche `chore/promote-manifest-<api>` + PR sur le dépôt d'équipe ; sortie `PIN_DEJA_A_JOUR` (cas sans diff) ; `EXPORT_CONFIRMED_SUMMARY` inchangée en forme, suivie de la ligne PR.

- [ ] **Étape 1 : épreuve 10 (échoue : l'export exige encore le manifeste)**

```bash
echo "== 10. export : les briques rendu→pin s'enchaînent sur fixture (sans réseau) =="
mkdir -p "$TMP/team3/apis"
cp "$TMP/team/apis/demo-api.publish.yml" "$TMP/team3/apis/"
render_promote_manifest "$TMP/team3" demo-api gateways/templates/promote.yml.tmpl \
  && pin_promote_manifest "$TMP/team3/apis/demo-api.promote.yml" \
       "14c2529e-0000-4000-8000-00000000bbbb" \
       "3333333333333333333333333333333333333333333333333333333333333333" "2.1.0" \
  && [ "$(manifest_pinned_digest "$TMP/team3/apis/demo-api.promote.yml")" = "$(printf '3%.0s' $(seq 64))" ] \
  && ok "rendu → pin → relecture, la chaîne que l'export joue" \
  || ko "chaîne rendu→pin en échec"
grep -q "PROMOTE_MANIFEST_ABSENT" scripts/api-promote-export.sh \
  && ko "l'export refuse encore un manifeste absent (doit le RENDRE)" \
  || ok "le refus PROMOTE_MANIFEST_ABSENT a disparu de l'export (remplacé par le rendu)"
```

Run : suite → épreuve 10 partiellement ROUGE (le grep trouve `PROMOTE_MANIFEST_ABSENT`).

- [ ] **Étape 2 : sourcer la lib et remplacer le refus par le rendu**

En tête d'`api-promote-export.sh`, après `. scripts/lib/archive-store.sh` :

```sh
# shellcheck source=scripts/lib/promote-manifest.sh
. scripts/lib/promote-manifest.sh || { echo "ERREUR: scripts/lib/promote-manifest.sh introuvable ou illisible" >&2; exit 1; }
```

Remplacer (lignes ~124-127) :

```sh
PROMOTE_REL="apis/${API_NAME}.promote.yml"
[ -f "$TMP/team/$PROMOTE_REL" ] \
  || fail "PROMOTE_MANIFEST_ABSENT : ${PROMOTE_REL} absent de ${REPO_FULL}@main — cette API n'est pas déclarée pour voyager par archive"
```

par :

```sh
PROMOTE_REL="apis/${API_NAME}.promote.yml"
# La version d'AUTHORING (publish.yml sur main) est la vérité de ce qui se
# publie en dev — le manifeste de promotion la SUIT, il ne la précède pas.
PUB_VERSION=$(publish_manifest_version "$TMP/team" "$API_NAME") \
  || fail "PUBLISH_MANIFEST_ABSENT : apis/${API_NAME}.publish.yml absent ou illisible sur ${REPO_FULL}@main — publier l'API d'abord (formulaire api-request)"
MANIFEST_RENDU=0
if [ ! -f "$TMP/team/$PROMOTE_REL" ]; then
  # Spec promotion-sans-recopie (2026-08-28) : le manifeste absent n'est plus
  # un refus, c'est le CAS NOMINAL du premier export — on le REND (gabarit),
  # et la PR d'épinglage ci-dessous le portera, guid et sha déjà remplis.
  render_promote_manifest "$TMP/team" "$API_NAME" gateways/templates/promote.yml.tmpl \
    || fail "RENDU_ECHEC : gabarit gateways/templates/promote.yml.tmpl -> ${PROMOTE_REL}"
  MANIFEST_RENDU=1
  echo "manifeste absent de main — RENDU depuis le gabarit (name=${API_NAME}, version=${PUB_VERSION})"
else
  # Manifeste présent mais version en retard sur l'authoring (new-version
  # publiée depuis) : réaligner AVANT l'export — sinon on exporterait
  # l'ancienne version, et la main reviendrait à chaque montée de version.
  M_VERSION=$(python3 -c "import sys,yaml; print((yaml.safe_load(open(sys.argv[1])) or {}).get('apim_promote',{}).get('version',''))" "$TMP/team/$PROMOTE_REL" 2>/dev/null || printf '')
  if [ -n "$M_VERSION" ] && [ "$M_VERSION" != "$PUB_VERSION" ]; then
    echo "version du manifeste (${M_VERSION}) en retard sur l'authoring (${PUB_VERSION}) — réalignée dans la PR d'épinglage"
  fi
fi
```

- [ ] **Étape 3 : épingler et ouvrir la PR après le push au registre**

Après le bloc `PUSHED_SHA`/`URL` (ligne ~207), remplacer les deux lignes finales :

```sh
printf 'EXPORT_CONFIRMED_SUMMARY guid=%s sha256=%s package=%s\n' "$GUID" "$SHA" "$URL"
echo "geste suivant : épingler guid=${GUID} dans ${PROMOTE_REL} (PR) ; recopier sha256=${SHA} dans le formulaire api-promote-request (ARCHIVE_SHA256)"
```

par :

```sh
# ── ÉPINGLAGE (spec promotion-sans-recopie) : guid + sha + version, par PR ──
# Le fichier de travail est celui que l'export vient de JOUER ($TMP/team) —
# épingler autre chose serait épingler ce qu'on n'a pas exporté.
pin_promote_manifest "$TMP/team/$PROMOTE_REL" "$GUID" "$SHA" "$PUB_VERSION" \
  || fail "PIN_ECHEC : épinglage de ${PROMOTE_REL}"

printf 'EXPORT_CONFIRMED_SUMMARY guid=%s sha256=%s package=%s\n' "$GUID" "$SHA" "$URL"

if git -C "$TMP/team" diff --quiet -- "$PROMOTE_REL" && [ "$MANIFEST_RENDU" = 0 ]; then
  # main porte déjà exactement ces valeurs : ré-export au contenu identique
  # (registre idempotent par le contenu) — aucune PR à ouvrir, et on le DIT.
  echo "PIN_DEJA_A_JOUR : ${PROMOTE_REL} sur main porte déjà guid/sha/version — pas de PR"
  echo "geste suivant : formulaire api-promote-request (ARCHIVE_SHA256 facultatif — lu sur main)"
else
  PIN_BRANCH="chore/promote-manifest-${API_NAME}"
  git -C "$TMP/team" checkout -q -B "$PIN_BRANCH"
  git -C "$TMP/team" add "$PROMOTE_REL"
  git -C "$TMP/team" -c user.name=ci -c user.email=ci@stoa.lab \
    commit -qm "promo(${API_NAME}): épingle guid/sha256/version ${PUB_VERSION} (export $(printf '%.12s' "$SHA"))" \
    || fail "PIN_COMMIT_VIDE : rien à committer alors qu'un diff était attendu"
  # push FORCÉ délibéré : la branche d'épinglage n'a qu'UN commit de tête et
  # appartient à l'export — un ré-export la REMPLACE (la PR ouverte suit),
  # jamais d'empilement (piège G5 « ré-export ⇒ PR neuve » fermé ici).
  AUTH_B64=$(printf 'x:%s' "$GITEA_TOKEN" | base64 | tr -d '\n')
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
    GIT_CONFIG_VALUE_0="Authorization: Basic ${AUTH_B64}" \
    git -C "$TMP/team" push -q -f "${GIT_HOST}/${REPO_FULL}.git" "$PIN_BRANCH" \
    || fail "PIN_PUSH_ECHEC : push de ${PIN_BRANCH} sur ${REPO_FULL}"
  unset AUTH_B64
  PIN_PR=$(API="${GIT_HOST}/api/v1" REPO_FULL="$REPO_FULL" GITEA_TOKEN="$GITEA_TOKEN" \
    BRANCH="$PIN_BRANCH" API_NAME="$API_NAME" GUID="$GUID" SHA="$SHA" VER="$PUB_VERSION" \
    python3 - <<'PY'
import json, os, urllib.error, urllib.request
api, repo, tok = os.environ["API"], os.environ["REPO_FULL"], os.environ["GITEA_TOKEN"]
head = os.environ["BRANCH"]
hdrs = {"Authorization": f"token {tok}", "Content-Type": "application/json"}
body = (
    "Épinglage du manifeste de promotion (formulaire api-promote-export).\n\n"
    f"- API : {os.environ['API_NAME']} v{os.environ['VER']}\n"
    f"- guid (id-map, ADR-079) : {os.environ['GUID']}\n"
    f"- archive_sha256 (registre, adressé par le contenu) : {os.environ['SHA']}\n\n"
    "Merger cette PR épingle CE guid et CES octets pour la promotion. "
    "Geste suivant : formulaire api-promote-request — ARCHIVE_SHA256 peut "
    "rester vide, il sera lu ici, sur main (ADR-081 : la décision est le merge)."
)
req = urllib.request.Request(f"{api}/repos/{repo}/pulls", method="POST",
    data=json.dumps({"base": "main", "head": head,
        "title": f"promo({os.environ['API_NAME']}): épinglage guid/sha v{os.environ['VER']}",
        "body": body}).encode(), headers=hdrs)
try:
    print(json.load(urllib.request.urlopen(req))["number"])
except urllib.error.HTTPError as e:
    if e.code != 409:
        raise
    # PR déjà ouverte pour cette branche : le push -f vient de la mettre à
    # jour — on retrouve son numéro au lieu d'échouer.
    with urllib.request.urlopen(urllib.request.Request(
            f"{api}/repos/{repo}/pulls?state=open", headers=hdrs)) as r:
        prs = json.load(r)
    n = next((p["number"] for p in prs if p["head"]["ref"] == head), None)
    if n is None:
        raise SystemExit("PR 409 mais introuvable parmi les PRs ouvertes")
    print(n)
PY
) || fail "PIN_PR_ECHEC : ouverture/retrouvaille de la PR d'épinglage"
  echo "PR d'épinglage : ${GIT_WEB_HOST:-$GIT_HOST}/${REPO_FULL}/pulls/${PIN_PR}"
  echo "geste suivant : MERGER cette PR, puis formulaire api-promote-request (ARCHIVE_SHA256 facultatif — lu sur main)"
fi
```

⚠ Vérifier en début de script que `GIT_WEB_HOST` a un défaut (`GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"`) — l'ajouter près de `GIT_HOST`/`GIT_REPO` s'il manque.

- [ ] **Étape 4 : suite verte + shellcheck**

Run : `bash scripts/test-promote-sans-recopie.sh` → `0 ❌` (l'épreuve 10 voit le refus disparu) ; `make lint-ci` → vert.

- [ ] **Étape 5 : mettre à jour la description du job d'export**

Dans `ci/jenkins/api-promote-export.job.xml` :
- `<description>` : remplacer « … et imprimer guid/sha256/package (EXPORT_CONFIRMED_SUMMARY) — à recopier dans apis/&lt;api&gt;.promote.yml (guid) et dans le formulaire api-promote-request (ARCHIVE_SHA256). » par « … rend apis/&lt;api&gt;.promote.yml s'il est absent (gabarit), puis ouvre la PR d'épinglage guid/sha256/version sur le dépôt d'équipe — AUCUNE recopie : api-promote-request lit le sha sur main. » (le reste de la description est inchangé).
- Dans le commentaire d'en-tête, remplacer le paragraphe « ⚠ MÉCANISME MESURÉ SUR LE FRÈRE LE PLUS PROCHE (api-promote-request …) … celui de team-request, pas celui — absent — d'api-promote-request. » par : « Le frère api-promote-request (jalon G3) a longtemps été un job jamais câblé (dette silencieuse) ; soldé le 2026-08-28 : ci/jenkins/api-promote-request.job.xml existe et rejoint setup-team-onboard-jobs.sh, comme ce fichier. »
- La description du paramètre `API_NAME` (« … avec un apis/&lt;api&gt;.promote.yml sur le dépôt d'équipe ») devient « … (déjà publiée en authoring — le manifeste de promotion est rendu par ce job s'il n'existe pas encore). »

- [ ] **Étape 6 : commit**

```bash
git add scripts/api-promote-export.sh ci/jenkins/api-promote-export.job.xml \
  scripts/test-promote-sans-recopie.sh
git commit -m "feat(promo): l'export rend le manifeste absent et épingle guid/sha/version par PR idempotente"
```

---

### Task 5 : poser le job `api-promote-request` + miroirs + textes qui mentent

**Files:**
- Create: `ci/jenkins/api-promote-request.job.xml`
- Modify: `ci/Jenkinsfile.api-promote-request` (en-tête périmé lignes 5-11 ; description `ARCHIVE_SHA256` ligne 52)
- Modify: `scripts/setup-team-onboard-jobs.sh` (ligne 97 `JOBS=` ; en-tête lignes 23-33)
- Modify: `scripts/test-promote-sans-recopie.sh` (épreuve 11 — miroir XML ↔ Jenkinsfile)

**Interfaces:**
- Consumes : bloc `parameters{}` du Jenkinsfile (TEAM, API_NAME, FROM_ENV, TO_ENV, MESSAGE, CHANGE_REF, PV_REF, ARCHIVE_SHA256 — `ci/Jenkinsfile.api-promote-request:44-53`) ; forme XML mesurée sur `api-promote-export.job.xml` (SCM block) et `api-request.job.xml` (ChoiceParameterDefinition).

- [ ] **Étape 1 : épreuve 11 (échoue : le XML n'existe pas)**

```bash
echo "== 11. miroir job.xml ↔ Jenkinsfile (api-promote-request) =="
XML=ci/jenkins/api-promote-request.job.xml
JF=ci/Jenkinsfile.api-promote-request
if [ -f "$XML" ]; then
  P_XML=$(grep -oE '<name>[A-Z_0-9]+</name>' "$XML" | sed 's/<[^>]*>//g' | tr '\n' ' ')
  P_JF=$(grep -oE "(string|choice)\(name: '[A-Z_0-9]+'" "$JF" | grep -oE "'[A-Z_0-9]+'" | tr -d "'" | tr '\n' ' ')
  [ "$P_XML" = "$P_JF" ] \
    && ok "params identiques et DANS LE MÊME ORDRE ($P_JF)" \
    || ko "divergence params — XML: [$P_XML] vs Jenkinsfile: [$P_JF] (le XML gagne, la divergence serait silencieuse)"
  grep -q '<scriptPath>poc-control-plane-federation/ci/Jenkinsfile.api-promote-request</scriptPath>' "$XML" \
    && ok "scriptPath pointe le bon Jenkinsfile" || ko "scriptPath faux"
  grep -q "api-promote-request" scripts/setup-team-onboard-jobs.sh \
    && grep -E '^JOBS=' scripts/setup-team-onboard-jobs.sh | grep -q api-promote-request \
    && ok "posé par setup-team-onboard-jobs.sh (liste JOBS)" || ko "absent de la liste JOBS"
else
  ko "$XML absent — le job n'est toujours pas posable"
fi
```

- [ ] **Étape 2 : écrire le job.xml**

`ci/jenkins/api-promote-request.job.xml` :

```xml
<?xml version='1.1' encoding='UTF-8'?>
<!--
  api-promote-request — PIPELINE FROM SCM, job de FORMULAIRE (jalon G3 ; posé
  le 2026-08-28, spec promotion-sans-recopie — ce fichier solde la « dette
  silencieuse » que l'en-tête d'api-promote-export.job.xml documentait).
  Calqué sur ce dernier : ni webhook ni <script> inline, le pipeline vit dans
  ci/Jenkinsfile.api-promote-request (déclaratif, versionné).

  Le bloc <parameterDefinitions> DOIT rester le miroir exact du bloc
  `parameters { … }` du Jenkinsfile — MÊME PIÈGE que team-request.job.xml
  documente (DeclarativeJobPropertyTrackerAction : le XML gagne, une
  divergence serait silencieuse). test-promote-sans-recopie.sh épreuve 11
  compare les deux, noms ET ordre.

  AUCUN marqueur CHOICES : les listes FROM_ENV/TO_ENV sont écrites à la main
  (mêmes valeurs que le Jenkinsfile — un bloc parameters{} est évalué à la
  pose, hors workspace, il ne peut pas dériver d'environments.yaml) ; le job
  est donc copié TEL QUEL par setup-team-onboard-jobs.sh.
-->
<flow-definition plugin="workflow-job">
  <description>Formulaire : demander la PROMOTION d'une API — ouvre la PR promote/&lt;api&gt;-&lt;env&gt; portant le marqueur apis/&lt;api&gt;.deploy.&lt;env&gt;.yaml sur le dépôt d'équipe. NE DÉPLOIE RIEN : la décision est le merge (ADR-081) ; le merge déclenche team-promote (pause nominative + garde d'identité). ARCHIVE_SHA256 est FACULTATIF : vide, il est lu sur main (manifeste épinglé par api-promote-export) ou hérité du palier source. PIPELINE FROM SCM : le pipeline est ci/Jenkinsfile.api-promote-request (branche main) — ce job ne contient AUCUN Groovy.</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
        <hudson.model.StringParameterDefinition>
          <name>TEAM</name>
          <description>Équipe propriétaire — doit revendiquer le dépôt dans providers.&lt;env&gt;.yml (REPO_NON_DECLARE sinon).</description>
          <defaultValue></defaultValue>
        </hudson.model.StringParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>API_NAME</name>
          <description>Nom de l'API ([a-z0-9-]) — publiée en authoring, manifeste de promotion épinglé (PR d'api-promote-export mergée).</description>
          <defaultValue></defaultValue>
        </hudson.model.StringParameterDefinition>
        <hudson.model.ChoiceParameterDefinition>
          <name>FROM_ENV</name>
          <description>Palier source. La paire (FROM_ENV,TO_ENV) est validée par le script (CHAINE_INVALIDE si le saut n'est pas le suivant de la chaîne).</description>
          <choices class="java.util.Arrays$ArrayList"><a class="string-array"><string>dev</string><string>rec</string><string>int</string><string>homol</string></a></choices>
        </hudson.model.ChoiceParameterDefinition>
        <hudson.model.ChoiceParameterDefinition>
          <name>TO_ENV</name>
          <description>Palier d'arrivée. Sa porte (environments.yaml) décide des références exigées (CHANGE_REF/PV_REF).</description>
          <choices class="java.util.Arrays$ArrayList"><a class="string-array"><string>rec</string><string>int</string><string>homol</string><string>prod</string></a></choices>
        </hudson.model.ChoiceParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>MESSAGE</name>
          <description>Message d'audit (obligatoire) — voyage dans le marqueur mergé.</description>
          <defaultValue></defaultValue>
        </hudson.model.StringParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>CHANGE_REF</name>
          <description>Référence de changement ITSM — exigée par la porte de certains paliers ([A-Za-z0-9._-]).</description>
          <defaultValue></defaultValue>
        </hudson.model.StringParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>PV_REF</name>
          <description>Référence de PV de recette — exigée par la porte de certains paliers ([A-Za-z0-9._-]).</description>
          <defaultValue></defaultValue>
        </hudson.model.StringParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>ARCHIVE_SHA256</name>
          <description>FACULTATIF. Vide : lu sur main (manifeste épinglé, depuis dev) ou hérité du palier source. Renseigné : désignation explicite — il gagne, une contradiction avec la source est refusée (DIGEST_CONTREDIT_SOURCE).</description>
          <defaultValue></defaultValue>
        </hudson.model.StringParameterDefinition>
      </parameterDefinitions>
    </hudson.model.ParametersDefinitionProperty>
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>http://gitea:3000/ci/stoa-labs.git</url>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>*/main</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
      <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
      <submoduleCfg class="empty-list"/>
      <extensions/>
    </scm>
    <scriptPath>poc-control-plane-federation/ci/Jenkinsfile.api-promote-request</scriptPath>
    <lightweight>false</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
```

(⚠ Reprendre à l'identique le commentaire `lightweight=false` d'`api-promote-export.job.xml` s'il explique le besoin du workspace — relire ce fichier au moment d'écrire, la fin du bloc `<definition>` doit avoir la même forme.)

- [ ] **Étape 3 : miroir Jenkinsfile + en-tête périmé**

Dans `ci/Jenkinsfile.api-promote-request` :
- description du paramètre : `string(name: 'ARCHIVE_SHA256', defaultValue: '', description: "FACULTATIF — vide : lu sur main (manifeste épinglé) ou hérité du palier source ; renseigné : désignation explicite")`
- remplacer le bloc d'en-tête périmé (lignes 5-11, « ⚠ ET LE MERGE N'APPLIQUE RIEN NON PLUS, AUJOURD'HUI … pas pour déclencher un apply. ») par :

```groovy
// Le merge de la PR promote/<name>-<env> déclenche team-promote (G5) : pause
// nominative, garde d'identité, pin de l'archive par sha256, apply réel.
// (Une version antérieure de cet en-tête décrivait l'époque — G3 — où ce
// merge ne déclenchait rien ; périmée depuis G5, corrigée le 2026-08-28.)
```

Vérification (hors périmètre de la spec, à CONSTATER seulement) : le corps de
PR d'`api-promote-request.sh` ne doit plus dire « ce merge n'applique rien »
(trou n°3 de G7, censé être déjà corrigé) — `grep -n "n'applique rien" scripts/api-promote-request.sh`
doit rendre vide ; s'il rend quelque chose, le signaler dans le rapport de
tâche sans le corriger ici.

- [ ] **Étape 4 : setup-team-onboard-jobs.sh**

Ligne 97 :

```sh
JOBS="${JOBS:-team-request app-request team-apply api-request team-publish api-promote-export api-promote-request team-promote}"
```

Et dans l'en-tête (lignes ~23-33), remplacer le paragraphe « ⚠ api-promote-request (jalon G3, le formulaire DE PROMOTION lui-même) n'a PAS de job.xml et n'est posé par AUCUN script de ce dépôt — dette distincte, non comblée ici (cf. l'en-tête du job.xml d'api-promote-export pour le détail de ce qui a été vérifié). » par : « api-promote-request → ci/jenkins/api-promote-request.job.xml (dette G3 soldée le 2026-08-28, spec promotion-sans-recopie) : sans marqueur CHOICES, copié tel quel, comme api-promote-export. »

- [ ] **Étape 5 : suite verte + lint**

Run : `bash scripts/test-promote-sans-recopie.sh` → `0 ❌` (épreuve 11 verte).
Run : `make lint-ci` → vert (« 12 Jenkinsfile compilent » — le glob prend le fichier existant, aucun ajout de liste).

- [ ] **Étape 6 : commit**

```bash
git add ci/jenkins/api-promote-request.job.xml ci/Jenkinsfile.api-promote-request \
  scripts/setup-team-onboard-jobs.sh scripts/test-promote-sans-recopie.sh
git commit -m "ci(promo): pose du job api-promote-request (pipeline from SCM) — dette G3 soldée, miroir XML/Jenkinsfile éprouvé"
```

---

### Task 6 : parcours opérateur, pose sur le lab, E2E réel

**Files:**
- Modify: `ENVIRONNEMENTS.md` (section « parcours » lignes ~344-368)
- Aucun autre fichier — cette tâche POSE et PROUVE.

**Interfaces:**
- Consumes : tout ce qui précède ; le lab (Gitea 13000, Jenkins 18080, Vault, users oscar/ci) ; `scripts/setup-team-onboard-jobs.sh`.

- [ ] **Étape 1 : réécrire le parcours dans ENVIRONNEMENTS.md**

Remplacer les étapes numérotées 1–4 du parcours de promotion (lignes ~344-361 : « …apis/<api>.promote.yml du dépôt d'équipe », « Exporter l'archive… », « Épingler le guid — recopier… », « Demander la promotion… ») par :

```markdown
1. **Exporter** — job `api-promote-export` (TEAM, API_NAME, identité Vault
   nominative). Le job REND `apis/<api>.promote.yml` s'il est absent (gabarit
   `gateways/templates/promote.yml.tmpl`), exporte l'archive vers le registre
   (adressé par le contenu), puis ouvre la PR d'épinglage guid/sha256/version
   sur le dépôt d'équipe. Aucune recopie.
2. **Merger la PR d'épinglage** — c'est elle qui fixe l'id-map (guid) et les
   octets (sha256) que la promotion désignera (ADR-081 : la décision est le
   merge). Ré-export ⇒ la même PR est mise à jour, jamais empilée.
3. **Demander la promotion** — job `api-promote-request` (posé depuis le
   2026-08-28). `ARCHIVE_SHA256` FACULTATIF : vide, il est lu sur main
   (manifeste épinglé) depuis dev, hérité du palier source au-delà. Ouvre la
   PR `promote/<api>-<env>`.
```

(Les étapes suivantes — merge par le 2nd humain, pause `team-promote`, réponse nominative — sont déjà justes : les conserver, renumérotées.)

- [ ] **Étape 2 : poser/mettre à jour les jobs sur le Jenkins du lab**

```bash
cd poc-control-plane-federation
JENKINS_UI=http://localhost:18080 ALLOW_RECREATE=true \
  JOBS="api-promote-export api-promote-request" \
  bash scripts/setup-team-onboard-jobs.sh
```

Vérifier : `curl -sg http://localhost:18080/job/api-promote-request/api/json?tree=name` → 200.

- [ ] **Étape 3 : E2E nominal — t7-e2e-api@1.0.1 dev→rec, entièrement par formulaires**

1. Jenkins → `api-promote-export` : `TEAM=banking-demo`, `API_NAME=t7-e2e-api`, `VAULT_USER=oscar`, `V_PASS=<LAB_OSCAR_PASS>`. Attendu console : « manifeste absent de main — RENDU… », `EXPORT_CONFIRMED_SUMMARY guid=… sha256=…`, « PR d'épinglage : http://localhost:13000/banking-demo/accounts-api/pulls/N ».
2. **Contre-épreuve AVANT merge** : Jenkins → `api-promote-request` (`TEAM=banking-demo`, `API_NAME=t7-e2e-api`, `FROM_ENV=dev`, `TO_ENV=rec`, `MESSAGE=contre-épreuve`, `ARCHIVE_SHA256` vide). Attendu : build ROUGE, `DIGEST_ABSENT … mergez la PR d'api-promote-export d'abord`.
3. Merger la PR d'épinglage dans Gitea (oscar). Vérifier le manifeste sur main (`guid` et `archive_sha256` remplis).
4. Re-lancer `api-promote-request`, mêmes paramètres, `ARCHIVE_SHA256` vide. Attendu : `DIGEST_RESOLU : archive_sha256 lu sur main…`, PR `promote/t7-e2e-api-rec` ouverte.
5. Merger la PR promote en **oscar** ; le build `team-promote` part et se met en pause ; répondre `oscar` / `<LAB_OSCAR_PASS>`. Attendu : `MERGE_IDENTITY_OK`, pin sha vérifié, apply vert, commentaire ✅ sur la PR.
6. Re-lancer `api-promote-export` mêmes paramètres : attendu `PIN_DEJA_A_JOUR … pas de PR` (idempotence en réel).

- [ ] **Étape 4 : suite complète + lint une dernière fois**

Run : `bash scripts/test-promote-sans-recopie.sh` → `0 ❌` ; `make lint-ci` → vert.

- [ ] **Étape 5 : commit + récapitulatif**

```bash
git add ENVIRONNEMENTS.md
git commit -m "docs(promo): parcours opérateur sans recopie — export rend/épingle, request lit sur main"
```

Rapporter : n° des builds E2E (export, contre-épreuve rouge, request, team-promote), n° des PRs, sortie `PIN_DEJA_A_JOUR`.
