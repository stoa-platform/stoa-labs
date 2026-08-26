# G3 — La référence de déploiement dans les dépôts d'équipe : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Porter la référence de déploiement pinnée (`deploy.<env>.yaml` : SHA de commit + digest d'archive) du monorepo de gouvernance aux dépôts d'équipe du modèle repo-par-projet, avec un résolveur unique dans le CI et une preuve N/N hors ligne.

**Architecture:** Le marqueur `apis/<name>.deploy.<env>.yaml` vit à côté des manifestes de l'API. Un résolveur shell partagé (`scripts/lib/deploy-pin.sh`) lit le marqueur **au SHA mergé**, matérialise les fichiers de l'API **au SHA pinné** via `git show`, vérifie le digest de l'archive, et passe les chemins résolus aux moteurs par les extra-vars **qui existent déjà** (`apim_ss_manifest`, `apim_promote_manifest`, `apim_ss_contract_pin`). Aucun moteur ne porte de logique de pin. Un script self-service (`api-promote-request.sh`) écrit le marqueur dans une PR sur le dépôt d'équipe.

**Tech Stack:** bash 3.2 (macOS compatible — **jamais `mapfile`**), python3 + PyYAML pour tout parse YAML, git, Ansible (rôles `apim_*`), Jenkins déclaratif.

## Global Constraints

Valeurs copiées telles quelles depuis la spec `docs/superpowers/specs/2026-08-26-g3-reference-deploiement-depots-equipe-design.md`.

- **bash 3.2 obligatoire.** `mapfile`/`readarray` n'existent pas sur macOS. Piège mesuré en G1 : un lint rendait « 1 PASS / 0 FAIL » et sortait `0` sans avoir linté **aucun** fichier.
- **Jamais d'apostrophe française (`’`) dans un `${VAR:?message}`.** bash y voit une ouverture de quote ; le script entier devient `unexpected EOF` signalé à la **dernière** ligne. Piège mesuré en G1.
- **`BASH_SOURCE` se résout AU SOURCE, jamais à l'appel.** Tous les scripts de ce dépôt font `cd "$(dirname "$0")/.."` après le source ; résolu plus tard, un chemin relatif pointe ailleurs et la fonction renvoie une **chaîne vide au lieu d'échouer**. Motif : `_STOA_ENV_CHAIN_ROOT` dans `scripts/lib/env-chain.sh:41`.
- **Tout parse YAML passe par python3 + `yaml.safe_load`**, jamais par `grep`/`sed`. Et toute extraction doit être **gardée** : `|| fail` sur l'échec du process **et** un marqueur de préfixe explicite en sortie, pour ne jamais confondre « champ légitimement vide » et « extraction cassée » (motif `REPO=` de `team-apply.sh:76-95`).
- **Aucun secret en argv ni en URL.** Push Git par `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0="Authorization: Basic <b64>"`. Mesuré en direct : un token dans l'URL apparaît en clair dans `ps -Aww` pendant tout le push.
- **`set -uo pipefail` et `set +x`** en tête de chaque script ; `TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; umask 077`.
- **Environnement d'authoring : `dev`.** Seul palier sans marqueur, seul palier qui suit HEAD (`pinned.go:15`).
- **Refus nommés en MAJUSCULES_AVEC_UNDERSCORES**, message disant la **cause**, pas la conséquence.
- **Toute porte de preuve joue son sabotage**, avec restauration inconditionnelle par `trap ... EXIT INT TERM`. Une porte qui ne rougit jamais ne prouve rien (motif F1).

---

## Structure des fichiers

| Fichier | Responsabilité | Tâche |
|---|---|---|
| `scripts/lib/deploy-pin.sh` | **Créer** — le résolveur : lire le marqueur, résoudre au SHA, vérifier le digest. Aucune I/O réseau, aucun Ansible. | 1–3 |
| `scripts/test-deploy-pin.sh` | **Créer** — la porte de preuve du résolveur, sur dépôt Git jetable, + sabotage. | 1–3 |
| `scripts/lib/export-order-probe.py` | **Créer** — sonde d'ordre sur `export.yml` (un grep ne peut pas prouver un ordre). | 5 |
| `scripts/lib/import-guard-probe.py` | **Créer** — sonde de garde sur `import.yml` (un grep ne distingue pas un test d'env d'un test de présence). | 6 |
| `clients/_example/apis/accounts-read.deploy.rec.yaml.example` | **Créer** — le gabarit documenté du marqueur (le squelette d'équipe le reçoit par `cp -R`). | 4 |
| `ansible/roles/apim_promote_api/tasks/export.yml` | **Modifier** — émettre le sha256 après sanitisation. | 5 |
| `ansible/roles/apim_promote_api/defaults/main.yml` | **Modifier** — `apim_ss_archive_sha256`, `apim_ss_authoring_env`. | 6 |
| `ansible/roles/apim_promote_api/tasks/import.yml` | **Modifier** — `assert` fail-closed du digest (degrés D0/D2). | 6 |
| `scripts/api-promote-request.sh` | **Créer** — l'écrivain du marqueur : gardes, clone, branche, PR. | 7–8 |
| `ci/Jenkinsfile.api-promote-request` | **Créer** — le job du formulaire, déclaratif. | 9 |
| `adr/adr-076-gitops-api-lifecycle-repo-per-project.md` | **Modifier** — amendement §1 sur l'emplacement du marqueur. | 9 |
| `Makefile` | **Modifier** — brancher `test-deploy-pin.sh` sur `lint-ci`. | 9 |

Le résolveur et l'écrivain sont **deux fichiers séparés** parce qu'un relecteur peut légitimement accepter l'un et rejeter l'autre : le résolveur est une fonction pure sur un dépôt Git, l'écrivain est un client d'API Gitea avec des gardes métier. Ils ne changent pas pour les mêmes raisons.

---

### Task 1 : Le résolveur — lecture du marqueur et résolution au SHA

**Files:**
- Create: `scripts/lib/deploy-pin.sh`
- Test: `scripts/test-deploy-pin.sh`

**Interfaces:**
- Consumes: rien (première tâche).
- Produces:
  - `resolve_deploy_pin <clone_dir> <api_name> <env> <workdir>` — écrit `<workdir>/<api>.publish.yml`, `<workdir>/<api>.promote.yml`, `<workdir>/<api>.openapi.yaml` ; exporte `DEPLOY_PIN_COMMIT`, `DEPLOY_PIN_VERSION`, `DEPLOY_PIN_SHA256`, `DEPLOY_PIN_PUBLISH`, `DEPLOY_PIN_PROMOTE`, `DEPLOY_PIN_CONTRACT`. Retour `0` = succès ; retour `1` + un refus nommé sur stderr = échec.
  - `deploy_pin_marker_path <api_name> <env>` — rend `apis/<api>.deploy.<env>.yaml`.

- [ ] **Step 1 : Écrire le harnais de test et la première épreuve (qui doit échouer)**

Créer `scripts/test-deploy-pin.sh` :

```bash
#!/usr/bin/env bash
# test-deploy-pin.sh — porte de preuve du RÉSOLVEUR DE PIN (jalon G3).
#
# Le pin est la réponse à « qu'est-ce qui tourne exactement en homol ». S'il
# retombe silencieusement sur HEAD, la question n'a plus de réponse et rien ne
# le signale : l'apply réussit, il déploie simplement autre chose que ce qui a
# été approuvé. Toutes les épreuves ci-dessous tournent HORS LIGNE, sur un
# dépôt Git RÉEL et jetable — aucune gateway, aucun Vault, aucun Jenkins.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# shellcheck source=lib/deploy-pin.sh
. "$ROOT/scripts/lib/deploy-pin.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT INT TERM; umask 077

# ── Fabrique : un dépôt d'équipe réel, deux commits ─────────────────────────
#   C1 : accounts-read v1.0.0  (le commit qui sera PINNÉ)
#   C2 : accounts-read v2.0.0  (main avance — le pin ne doit PAS suivre)
make_team_repo() {
  local d="$1"
  mkdir -p "$d/apis"
  git -C "$d" init -q -b main
  git -C "$d" config user.email ci@stoa.lab
  git -C "$d" config user.name ci
  _write_api "$d" 1.0.0
  git -C "$d" add -A && git -C "$d" commit -qm "C1 accounts-read 1.0.0"
  C1=$(git -C "$d" rev-parse HEAD)
  _write_api "$d" 2.0.0
  git -C "$d" add -A && git -C "$d" commit -qm "C2 accounts-read 2.0.0"
  C2=$(git -C "$d" rev-parse HEAD)
}

_write_api() {
  local d="$1" v="$2"
  printf 'apim_api:\n  name: "accounts-read"\n  version: "%s"\n' "$v" \
    > "$d/apis/accounts-read.publish.yml"
  printf 'apim_promote:\n  name: "accounts-read"\n  version: "%s"\n  archive: "%s/dist/a.zip"\n' \
    "$v" "$d" > "$d/apis/accounts-read.promote.yml"
  printf 'openapi: 3.0.0\ninfo: {title: accounts-read, version: "%s"}\n' "$v" \
    > "$d/apis/accounts-read.openapi.yaml"
  mkdir -p "$d/dist"
  printf 'archive-bytes-%s' "$v" > "$d/dist/a.zip"
}

marker() {  # marker <repo> <env> <commit> <version> [sha256]
  printf 'version: "%s"\nenabled: true\npromoted_by: alice\nmessage: "t"\ncommit: %s\nchange_ref: ""\narchive_sha256: "%s"\n' \
    "$4" "$3" "${5-}" > "$1/apis/accounts-read.deploy.$2.yaml"
}

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

echo "① le pin gagne sur HEAD — main avance, le résolu reste au commit pinné"
REPO="$TMP/team1"; make_team_repo "$REPO"
marker "$REPO" rec "$C1" "1.0.0" "$(sha_of "$REPO/dist/a.zip")"
WORK="$TMP/w1"; mkdir -p "$WORK"
if resolve_deploy_pin "$REPO" accounts-read rec "$WORK" 2>"$TMP/e1"; then
  if grep -q 'version: "1.0.0"' "$WORK/accounts-read.publish.yml"; then
    ok "publish.yml résolu au SHA pinné (1.0.0), alors que main porte 2.0.0"
  else
    bad "publish.yml résolu depuis HEAD — le pin ne gagne pas : $(cat "$WORK/accounts-read.publish.yml")"
  fi
else
  bad "résolution refusée alors qu'elle devait réussir : $(cat "$TMP/e1")"
fi

echo "①bis un NOM DE BRANCHE ne pinne rien — le pin doit être un objet immuable"
REPO="$TMP/team1b"; make_team_repo "$REPO"
git -C "$REPO" branch cafebabe-drift "$C2"
marker "$REPO" rec "cafebabe-drift" "1.0.0" "$(sha_of "$REPO/dist/a.zip")"
WORK="$TMP/w1b"
resolve_deploy_pin "$REPO" accounts-read rec "$WORK" 2>"$TMP/e1b" \
  && bad "un nom de branche a été ACCEPTÉ comme pin — il résout la tête du moment, donc il ne pinne rien" \
  || { grep -q PIN_MALFORMED "$TMP/e1b" && ok "PIN_MALFORMED sur une référence mouvante" || bad "refusé sans nommer PIN_MALFORMED : $(cat "$TMP/e1b")"; }

echo "①ter le délimiteur ne peut pas se cacher dans une valeur"
REPO="$TMP/team1c"; make_team_repo "$REPO"
printf 'version: "1.0|0"\nenabled: true\npromoted_by: a\nmessage: t\ncommit: %s\nchange_ref: ""\narchive_sha256: "x"\n' \
  "$C1" > "$REPO/apis/accounts-read.deploy.rec.yaml"
WORK="$TMP/w1c"
resolve_deploy_pin "$REPO" accounts-read rec "$WORK" 2>"$TMP/e1c" \
  && bad "une valeur portant '|' a été ACCEPTÉE — les frontières de champ se décalent en silence" \
  || { grep -q PIN_MALFORMED "$TMP/e1c" && ok "PIN_MALFORMED sur délimiteur dans une valeur" || bad "refusé sans nommer PIN_MALFORMED : $(cat "$TMP/e1c")"; }

echo "①quater le nom d'API ne peut pas s'évader de apis/"
REPO="$TMP/team1d"; make_team_repo "$REPO"
WORK="$TMP/w1d"
resolve_deploy_pin "$REPO" "../../etc/passwd" rec "$WORK" 2>"$TMP/e1d" \
  && bad "un nom d'API traversant ACCEPTÉ" \
  || { grep -q API_NAME_INVALIDE "$TMP/e1d" && ok "API_NAME_INVALIDE sur traversée de chemin" || bad "refusé sans nommer API_NAME_INVALIDE : $(cat "$TMP/e1d")"; }

printf '\n  %d PASS / %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2 : Lancer le test pour vérifier qu'il échoue**

Run: `bash scripts/test-deploy-pin.sh`
Expected: FAIL — `scripts/lib/deploy-pin.sh: No such file or directory`

- [ ] **Step 3 : Écrire le résolveur minimal**

Créer `scripts/lib/deploy-pin.sh` :

```bash
#!/usr/bin/env bash
# scripts/lib/deploy-pin.sh — LE RÉSOLVEUR DE PIN (jalon G3).
#
# POURQUOI CE FICHIER EXISTE : hors de dev, ce qui est déployé ne doit pas être
# « le dernier main » mais l'état EXACT qu'une porte a approuvé. Le marqueur
# apis/<name>.deploy.<env>.yaml porte ce SHA ; ce fichier le résout, une fois,
# EN AMONT des deux moteurs (décision D3 de la spec). Aucun moteur ne porte de
# logique de pin : ils reçoivent des CHEMINS de fichiers déjà résolus, par les
# extra-vars qui existent déjà (apim_ss_manifest, apim_promote_manifest,
# apim_ss_contract_pin).
#
# FAIL-CLOSED PARTOUT : toute anomalie est un refus nommé, jamais un repli sur
# HEAD. Un repli silencieux déploierait autre chose que l'approuvé, sans que
# rien ne rougisse — c'est le mode de panne que ce fichier existe pour rendre
# impossible (même discipline que labctl/internal/uac/pinned.go:15-16).

# Racine résolue AU SOURCE (piège mesuré en G1 : les appelants font un `cd`
# après le source, un BASH_SOURCE résolu à l'appel renverrait du vide).
_STOA_DEPLOY_PIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export _STOA_DEPLOY_PIN_ROOT

deploy_pin_marker_path() { printf 'apis/%s.deploy.%s.yaml' "$1" "$2"; }

# Nomme le refus sur stderr. Toujours appelé comme une INSTRUCTION suivie d'un
# `return 1` explicite — jamais `return $(_dp_fail …)`. Cette dernière forme
# « marche » (return sans argument rend le statut de la dernière commande) mais
# elle est illisible et se casse au premier refactor : un message qui écrirait
# par erreur sur stdout deviendrait l'argument de `return`, donc un code de
# sortie absurde ou une erreur de syntaxe.
_dp_fail() { printf 'deploy-pin: %s\n' "$*" >&2; }

# resolve_deploy_pin <clone_dir> <api_name> <env> <workdir>
resolve_deploy_pin() {
  local clone="$1" api="$2" env="$3" work="$4"

  # Le nom d'API construit des CHEMINS (`apis/<api>.publish.yml`) et des
  # arguments `git show`. On le contraint ici, indépendamment de ce que les
  # appelants valident de leur côté : une fonction qui fabrique des chemins à
  # partir de son argument ne délègue pas sa sûreté à ses appelants — le jour
  # où un nouvel appelant oublie de valider, c'est ce fichier qui tient.
  case "$api" in
    ""|*[!a-z0-9-]*) { _dp_fail "API_NAME_INVALIDE : '$api' — attendu des minuscules, chiffres et tirets (aucun '/', aucun '..')"; return 1; };;
  esac
  case "$env" in
    ""|*[!a-z0-9-]*) { _dp_fail "ENV_INVALIDE : '$env' — attendu des minuscules, chiffres et tirets"; return 1; };;
  esac

  local rel; rel="$(deploy_pin_marker_path "$api" "$env")"

  [ -f "$clone/$rel" ] || { _dp_fail "PIN_ABSENT : $rel absent — hors de l'environnement d'authoring, aucun repli sur HEAD"; return 1; }

  local raw
  raw=$(DP_FILE="$clone/$rel" python3 - <<'PY'
import os, sys, yaml
d = yaml.safe_load(open(os.environ["DP_FILE"])) or {}
c = str(d.get("commit") or "")
v = str(d.get("version") or "")
s = str(d.get("archive_sha256") or "")
# Les trois champs voyagent dans UNE ligne délimitée par '|', que le shell
# redécoupe. Un '|' présent dans une valeur décalerait silencieusement les
# frontières de champ — une version « 1.0|0 » ferait fuiter du texte dans le
# digest sans qu'aucun refus ne se déclenche. On REFUSE le délimiteur dans
# les valeurs plutôt que d'espérer qu'il n'y soit pas.
for name, val in (("commit", c), ("version", v), ("archive_sha256", s)):
    if "|" in val:
        sys.exit("le champ %s contient le délimiteur '|'" % name)
print("PIN=%s|%s|%s" % (c, v, s))
PY
) || { _dp_fail "PIN_MALFORMED : $rel illisible ou champ invalide (parse YAML, ou valeur contenant le délimiteur)"; return 1; }
  case "$raw" in PIN=*) raw="${raw#PIN=}";; *) { _dp_fail "PIN_MALFORMED : sortie inattendue de la lecture de $rel"; return 1; };; esac

  DEPLOY_PIN_COMMIT="${raw%%|*}"; raw="${raw#*|}"
  DEPLOY_PIN_VERSION="${raw%%|*}"
  DEPLOY_PIN_SHA256="${raw#*|}"

  # LE PIN DOIT ÊTRE UN OBJET IMMUABLE, PAS UNE RÉFÉRENCE MOUVANTE.
  #
  # ⚠ Un motif de la forme `[0-9a-f]×7*` ne contraint que les SEPT premiers
  # caractères : le `*` final accepte n'importe quoi ensuite. Reproduit en
  # revue — un marqueur portant `commit: cafebabe-drift` (un NOM DE BRANCHE)
  # passait, et `git show` résolvait la branche, donc la tête du moment. Le
  # résolveur rendait alors silencieusement une AUTRE version que celle
  # pinnée : précisément le mode de panne que ce fichier existe pour rendre
  # impossible, atteint par une référence mouvante au lieu de HEAD.
  #
  # Deux verrous, pas un : (1) AUCUN caractère non hexadécimal, où qu'il soit ;
  # (2) la longueur d'un identifiant d'objet COMPLET — 40 (SHA-1) ou 64
  # (SHA-256). L'écrivain pose `git log -1 --format=%H`, donc 40. Exiger la
  # forme complète ferme aussi le cas pathologique d'une branche dont le nom
  # serait entièrement hexadécimal : elle n'aura pas cette longueur.
  case "$DEPLOY_PIN_COMMIT" in
    *[!0-9a-f]*) { _dp_fail "PIN_MALFORMED : commit='$DEPLOY_PIN_COMMIT' contient un caractère non hexadécimal — un pin est un identifiant d'objet, jamais un nom de branche ou de tag (une référence mouvante ne pinne rien)"; return 1; };;
  esac
  case "${#DEPLOY_PIN_COMMIT}" in
    40|64) ;;
    *) { _dp_fail "PIN_MALFORMED : commit='$DEPLOY_PIN_COMMIT' fait ${#DEPLOY_PIN_COMMIT} caractères — un identifiant d'objet complet en fait 40 (SHA-1) ou 64 (SHA-256)"; return 1; };;
  esac

  mkdir -p "$work" \
    || { _dp_fail "WORKDIR_INCREABLE : impossible de creer '$work'"; return 1; }
  # publish.yml et openapi.yaml sont TOUJOURS présents — api-request.sh les pose
  # ENSEMBLE, au même commit (team-publish.sh:259 refuse déjà CONTRAT_ABSENT).
  local f
  for f in publish.yml openapi.yaml; do
    local src="apis/${api}.${f}" dst="$work/${api}.${f}"
    git -C "$clone" show "${DEPLOY_PIN_COMMIT}:${src}" > "$dst" 2>/dev/null \
      || { _dp_fail "PIN_UNREADABLE : git show ${DEPLOY_PIN_COMMIT}:${src} a échoué — le pin ne se résout pas, refus (jamais de repli sur HEAD)"; return 1; }
  done

  # promote.yml, LUI, peut légitimement manquer : api-request.sh n'écrit que
  # publish.yml + openapi.yaml (vérifié — scripts/api-request.sh:281-282). Le
  # manifeste de promotion n'existe que pour une API destinée à voyager par
  # archive. On le résout s'il existe ; la garde qui l'EXIGE vit plus bas, au
  # moment où on en a réellement besoin (le digest). Exiger les trois ici
  # casserait toute API créée par le formulaire.
  DEPLOY_PIN_PROMOTE=""
  if git -C "$clone" show "${DEPLOY_PIN_COMMIT}:apis/${api}.promote.yml" \
       > "$work/${api}.promote.yml" 2>/dev/null; then
    DEPLOY_PIN_PROMOTE="$work/${api}.promote.yml"
  else
    rm -f "$work/${api}.promote.yml"
  fi

  DEPLOY_PIN_PUBLISH="$work/${api}.publish.yml"
  DEPLOY_PIN_CONTRACT="$work/${api}.openapi.yaml"
  export DEPLOY_PIN_COMMIT DEPLOY_PIN_VERSION DEPLOY_PIN_SHA256 \
         DEPLOY_PIN_PUBLISH DEPLOY_PIN_PROMOTE DEPLOY_PIN_CONTRACT
  return 0
}
```

- [ ] **Step 4 : Lancer le test pour vérifier qu'il passe**

Run: `bash scripts/test-deploy-pin.sh`
Expected: PASS — `4 PASS / 0 FAIL`

- [ ] **Step 5 : Commit**

```bash
git add scripts/lib/deploy-pin.sh scripts/test-deploy-pin.sh
git commit -m "feat(g3): resolveur de pin — le SHA du marqueur gagne sur HEAD"
```

---

### Task 2 : Les refus fail-closed du résolveur

**Files:**
- Modify: `scripts/lib/deploy-pin.sh`
- Modify: `scripts/test-deploy-pin.sh`

**Interfaces:**
- Consumes: `resolve_deploy_pin`, `deploy_pin_marker_path` (Task 1).
- Produces: refus `PIN_NON_ANCETRE`, `PIN_VERSION_MISMATCH` ; `resolve_deploy_pin` prend un **5e paramètre optionnel** `<main_ref>` (défaut `origin/main`) — la référence contre laquelle l'ancêtreté est vérifiée.

- [ ] **Step 1 : Écrire les épreuves qui échouent**

Ajouter à `scripts/test-deploy-pin.sh`, avant le décompte final :

```bash
echo "② le pin couvre AUSSI promote.yml (pas seulement le contrat)"
REPO="$TMP/team2"; make_team_repo "$REPO"
marker "$REPO" rec "$C1" "1.0.0" "$(sha_of "$REPO/dist/a.zip")"
WORK="$TMP/w2"; mkdir -p "$WORK"
if resolve_deploy_pin "$REPO" accounts-read rec "$WORK" main 2>"$TMP/e2"; then
  grep -q 'version: "1.0.0"' "$WORK/accounts-read.promote.yml" \
    && ok "promote.yml résolu au SHA pinné — alias/GUID ne dérivent pas avec main" \
    || bad "promote.yml suit HEAD — le contrat serait figé et la config de déploiement, non"
else
  bad "résolution refusée à tort : $(cat "$TMP/e2")"
fi

echo "③ PIN_ABSENT — marqueur absent hors dev"
REPO="$TMP/team3"; make_team_repo "$REPO"
WORK="$TMP/w3"
resolve_deploy_pin "$REPO" accounts-read rec "$WORK" main 2>"$TMP/e3" \
  && bad "résolution ACCEPTÉE sans marqueur — repli implicite sur HEAD" \
  || { grep -q PIN_ABSENT "$TMP/e3" && ok "PIN_ABSENT" || bad "refusé mais sans nommer PIN_ABSENT : $(cat "$TMP/e3")"; }

echo "④ PIN_MALFORMED — commit non hexadécimal"
REPO="$TMP/team4"; make_team_repo "$REPO"
marker "$REPO" rec "pas-un-sha" "1.0.0" "deadbeef"
WORK="$TMP/w4"
resolve_deploy_pin "$REPO" accounts-read rec "$WORK" main 2>"$TMP/e4" \
  && bad "commit non hexadécimal ACCEPTÉ" \
  || { grep -q PIN_MALFORMED "$TMP/e4" && ok "PIN_MALFORMED" || bad "refusé sans nommer PIN_MALFORMED : $(cat "$TMP/e4")"; }

echo "⑤ PIN_NON_ANCETRE — un SHA vivant sur une branche JAMAIS mergée"
REPO="$TMP/team5"; make_team_repo "$REPO"
git -C "$REPO" checkout -q -b sournoise
_write_api "$REPO" 9.9.9
git -C "$REPO" add -A && git -C "$REPO" commit -qm "commit jamais mergé"
EVIL=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q main
marker "$REPO" rec "$EVIL" "9.9.9" "$(sha_of "$REPO/dist/a.zip")"
WORK="$TMP/w5"
resolve_deploy_pin "$REPO" accounts-read rec "$WORK" main 2>"$TMP/e5" \
  && bad "SHA non mergé ACCEPTÉ — le pin déplace la confiance du merge vers un champ que le demandeur remplit" \
  || { grep -q PIN_NON_ANCETRE "$TMP/e5" && ok "PIN_NON_ANCETRE" || bad "refusé sans nommer PIN_NON_ANCETRE : $(cat "$TMP/e5")"; }

echo "⑥ PIN_UNREADABLE — commit inexistant"
REPO="$TMP/team6"; make_team_repo "$REPO"
marker "$REPO" rec "0123456789abcdef0123456789abcdef01234567" "1.0.0" "deadbeef"
WORK="$TMP/w6"
resolve_deploy_pin "$REPO" accounts-read rec "$WORK" main 2>"$TMP/e6" \
  && bad "commit inexistant ACCEPTÉ" \
  || { grep -qE 'PIN_NON_ANCETRE|PIN_UNREADABLE' "$TMP/e6" && ok "refus nommé sur commit inexistant" || bad "refusé sans refus nommé : $(cat "$TMP/e6")"; }

echo "⑥bis version absente des DEUX cotes — un fail-open si on compare avant de verifier"
REPO="$TMP/team6b"; make_team_repo "$REPO"
printf 'apim_api:\n  name: "accounts-read"\n' > "$REPO/apis/accounts-read.publish.yml"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "manifeste sans version"
CNV=$(git -C "$REPO" rev-parse HEAD)
printf 'version: ""\nenabled: true\npromoted_by: a\nmessage: t\ncommit: %s\nchange_ref: ""\narchive_sha256: "%s"\n' \
  "$CNV" "$(sha_of "$REPO/dist/a.zip")" > "$REPO/apis/accounts-read.deploy.rec.yaml"
WORK="$TMP/w6b"
resolve_deploy_pin "$REPO" accounts-read rec "$WORK" main 2>"$TMP/e6b" \
  && bad "marqueur SANS version + manifeste SANS version ACCEPTES — '\"\" = \"\"' est passe pour une correspondance" \
  || { grep -q PIN_MALFORMED "$TMP/e6b" && ok "PIN_MALFORMED sur version absente" || bad "refuse sans nommer PIN_MALFORMED : $(cat "$TMP/e6b")"; }

echo "⑦ PIN_VERSION_MISMATCH — le marqueur ment sur la version"
REPO="$TMP/team7"; make_team_repo "$REPO"
marker "$REPO" rec "$C1" "7.7.7" "$(sha_of "$REPO/dist/a.zip")"
WORK="$TMP/w7"
resolve_deploy_pin "$REPO" accounts-read rec "$WORK" main 2>"$TMP/e7" \
  && bad "marqueur 7.7.7 vs manifeste 1.0.0 ACCEPTÉ" \
  || { grep -q PIN_VERSION_MISMATCH "$TMP/e7" && ok "PIN_VERSION_MISMATCH" || bad "refusé sans nommer PIN_VERSION_MISMATCH : $(cat "$TMP/e7")"; }
```

Et corriger l'appel de l'épreuve ① pour passer `main` en 5e argument :

```bash
if resolve_deploy_pin "$REPO" accounts-read rec "$WORK" main 2>"$TMP/e1"; then
```

- [ ] **Step 2 : Lancer les tests pour vérifier qu'ils échouent**

Run: `bash scripts/test-deploy-pin.sh`
Expected: FAIL sur ⑤ et ⑦ (`SHA non mergé ACCEPTÉ`, `marqueur 7.7.7 … ACCEPTÉ`). ①–④ et ⑥ passent déjà.

- [ ] **Step 3 : Ajouter les deux gardes au résolveur**

Dans `scripts/lib/deploy-pin.sh`, changer la signature et insérer les gardes.

Remplacer la ligne `local clone="$1" api="$2" env="$3" work="$4"` par :

```bash
  local clone="$1" api="$2" env="$3" work="$4" mainref="${5:-origin/main}" archive_in="${6:-}"

  # REMISE A ZERO DES SORTIES, AVANT TOUT REFUS.
  # Sans elle, un appel qui ECHOUE laisse en place les valeurs du precedent :
  # mesure en revue — apres un succes sur `bonapi` puis un echec sur
  # `mauvaiseapi`, DEPLOY_PIN_PUBLISH designait le manifeste de la seconde et
  # DEPLOY_PIN_ARCHIVE les octets de la PREMIERE. Un appelant qui ignore le code
  # de retour (ou un wrapper Ansible en `ignore_errors`) deploierait les octets
  # d'une API sous l'identite d'une autre. Un refus doit laisser un etat VIDE,
  # jamais l'etat de quelqu'un d'autre.
  DEPLOY_PIN_COMMIT=""; DEPLOY_PIN_VERSION=""; DEPLOY_PIN_SHA256=""
  DEPLOY_PIN_PUBLISH=""; DEPLOY_PIN_PROMOTE=""; DEPLOY_PIN_CONTRACT=""
  DEPLOY_PIN_ARCHIVE=""
  export DEPLOY_PIN_COMMIT DEPLOY_PIN_VERSION DEPLOY_PIN_SHA256 \
         DEPLOY_PIN_PUBLISH DEPLOY_PIN_PROMOTE DEPLOY_PIN_CONTRACT DEPLOY_PIN_ARCHIVE
```

Insérer **après** la garde `PIN_MALFORMED` du SHA hexadécimal, **avant** le `mkdir -p "$work"` :

```bash
  # GARDE D'ATTEIGNABILITÉ — la garde qui ne se devine pas.
  # `git show <sha>:<path>` réussit sur TOUT objet présent dans le clone, y
  # compris un commit vivant sur une branche jamais mergée (un `git clone`
  # sans --depth 1 récupère toutes les branches). Sans cette vérification, une
  # PR de promotion irréprochable en apparence peut pinner un SHA jamais revu :
  # le pin déplacerait alors la confiance du MERGE vers un champ que le
  # demandeur remplit lui-même. Même intention que MERGE_SHA_NON_ANCETRE
  # (team-publish.sh:246), un cran plus bas.
  git -C "$clone" merge-base --is-ancestor "$DEPLOY_PIN_COMMIT" "$mainref" 2>/dev/null \
    || { _dp_fail "PIN_NON_ANCETRE : $DEPLOY_PIN_COMMIT n'est pas un ancêtre de $mainref — refus de déployer depuis un état jamais fusionné"; return 1; }
```

Insérer **après** la boucle `for f in publish.yml openapi.yaml` (celle qui résout les deux fichiers TOUJOURS présents) et **avant** le bloc conditionnel qui résout `promote.yml` :

```bash
  # Le marqueur et le manifeste doivent parler de la MÊME version. Une
  # divergence signale un marqueur édité à la main après coup, ou un pin posé
  # sur le mauvais commit — dans les deux cas on déploierait une version que
  # personne n'a demandée.
  local mv
  mv=$(DP_FILE="$work/${api}.publish.yml" python3 - <<'PY'
import os, yaml
d = yaml.safe_load(open(os.environ["DP_FILE"])) or {}
print("V=" + str((d.get("apim_api") or {}).get("version") or ""))
PY
) || { _dp_fail "PIN_MALFORMED : publish.yml résolu illisible"; return 1; }
  case "$mv" in V=*) mv="${mv#V=}";; *) { _dp_fail "PIN_MALFORMED : sortie inattendue de la lecture de version"; return 1; };; esac
  # ⚠ COMPARER AVANT DE VÉRIFIER LA PRÉSENCE EST UN FAIL-OPEN. Les deux côtés
  # sont extraits en `… or ""` : un marqueur sans `version:` et un manifeste
  # sans `apim_api.version` donnent tous deux la chaîne vide, et `"" = ""`
  # passerait pour une CORRESPONDANCE. Le résolveur accepterait alors un pin
  # dont personne ne sait quelle version il déploie — exactement ce que ce
  # garde-fou existe pour empêcher. On exige donc la présence des deux, puis
  # seulement on compare.
  [ -n "$DEPLOY_PIN_VERSION" ] \
    || { _dp_fail "PIN_MALFORMED : le marqueur ne porte aucune version — impossible de vérifier ce qui serait déployé"; return 1; }
  [ -n "$mv" ] \
    || { _dp_fail "PIN_MALFORMED : le manifeste au SHA pinné ne porte aucune version (apim_api.version absent)"; return 1; }
  [ "$mv" = "$DEPLOY_PIN_VERSION" ] \
    || { _dp_fail "PIN_VERSION_MISMATCH : le marqueur annonce '$DEPLOY_PIN_VERSION' mais le manifeste au SHA pinné porte '$mv'"; return 1; }
```

- [ ] **Step 4 : Lancer les tests pour vérifier qu'ils passent**

Run: `bash scripts/test-deploy-pin.sh`
Expected: PASS — `11 PASS / 0 FAIL`

- [ ] **Step 5 : Commit**

```bash
git add scripts/lib/deploy-pin.sh scripts/test-deploy-pin.sh
git commit -m "feat(g3): gardes fail-closed du resolveur (ancetrete, version)"
```

---

### Task 3 : Le digest côté CI, et la contre-épreuve par sabotage

**Files:**
- Modify: `scripts/lib/deploy-pin.sh`
- Modify: `scripts/test-deploy-pin.sh`

**Interfaces:**
- Consumes: `resolve_deploy_pin` (Tasks 1–2).
- Produces: refus `DIGEST_ABSENT`, `ARCHIVE_ABSENT`, `ARCHIVE_DIGEST_MISMATCH`. Le résolveur exporte `DEPLOY_PIN_ARCHIVE` (chemin absolu de l'archive vérifiée).

- [ ] **Step 1 : Écrire les épreuves qui échouent**

Ajouter à `scripts/test-deploy-pin.sh` :

```bash
echo "⑧ DIGEST_ABSENT — pas de digest hors de l'environnement d'authoring"
REPO="$TMP/team8"; make_team_repo "$REPO"
marker "$REPO" rec "$C1" "1.0.0" ""
WORK="$TMP/w8"
resolve_deploy_pin "$REPO" accounts-read rec "$WORK" main "$REPO/dist/a.zip" 2>"$TMP/e8" \
  && bad "promotion hors dev SANS digest ACCEPTÉE — les octets déployés ne sont pinnés par rien" \
  || { grep -q DIGEST_ABSENT "$TMP/e8" && ok "DIGEST_ABSENT" || bad "refusé sans nommer DIGEST_ABSENT : $(cat "$TMP/e8")"; }

echo "⑨ ARCHIVE_DIGEST_MISMATCH — le digest ne correspond pas aux octets"
REPO="$TMP/team9"; make_team_repo "$REPO"
marker "$REPO" rec "$C1" "1.0.0" "0000000000000000000000000000000000000000000000000000000000000000"
WORK="$TMP/w9"
resolve_deploy_pin "$REPO" accounts-read rec "$WORK" main "$REPO/dist/a.zip" 2>"$TMP/e9" \
  && bad "digest faux ACCEPTÉ" \
  || { grep -q ARCHIVE_DIGEST_MISMATCH "$TMP/e9" && ok "ARCHIVE_DIGEST_MISMATCH" || bad "refusé sans nommer ARCHIVE_DIGEST_MISMATCH : $(cat "$TMP/e9")"; }

echo "⑩ ARCHIVE_ABSENT — pas d'archive, donc pas de vérification possible"
REPO="$TMP/team10"; make_team_repo "$REPO"
marker "$REPO" rec "$C1" "1.0.0" "$(sha_of "$REPO/dist/a.zip")"
rm -f "$REPO/dist/a.zip"
WORK="$TMP/w10"
resolve_deploy_pin "$REPO" accounts-read rec "$WORK" main "$REPO/dist/a.zip" 2>"$TMP/e10" \
  && bad "archive absente ACCEPTÉE — la vérification a été SAUTÉE au lieu d'échouer" \
  || { grep -q ARCHIVE_ABSENT "$TMP/e10" && ok "ARCHIVE_ABSENT" || bad "refusé sans nommer ARCHIVE_ABSENT : $(cat "$TMP/e10")"; }

echo "⑩bis PROMOTE_MANIFEST_ABSENT — hors authoring, le verbe est l'archive"
REPO="$TMP/team10b"; make_team_repo "$REPO"
git -C "$REPO" rm -q "apis/accounts-read.promote.yml"
git -C "$REPO" commit -qm "sans manifeste de promotion"
CNO=$(git -C "$REPO" rev-parse HEAD)
marker "$REPO" rec "$CNO" "2.0.0" "$(sha_of "$REPO/dist/a.zip")"
WORK="$TMP/w10b"
resolve_deploy_pin "$REPO" accounts-read rec "$WORK" main "$REPO/dist/a.zip" 2>"$TMP/e10b" \
  && bad "promotion hors authoring ACCEPTÉE sans promote.yml — rien ne nomme l'archive" \
  || { grep -q PROMOTE_MANIFEST_ABSENT "$TMP/e10b" && ok "PROMOTE_MANIFEST_ABSENT" || bad "refusé sans nommer PROMOTE_MANIFEST_ABSENT : $(cat "$TMP/e10b")"; }

echo "⑩ter ARCHIVE_PATH_RELATIVE — les octets verifies et consommes seraient resolus ailleurs"
REPO="$TMP/team10t"; make_team_repo "$REPO"
marker "$REPO" rec "$C1" "1.0.0" "$(sha_of "$REPO/dist/a.zip")"
WORK="$TMP/w10t"
resolve_deploy_pin "$REPO" accounts-read rec "$WORK" main "dist/a.zip" 2>"$TMP/e10t" \
  && bad "chemin d'archive RELATIF accepte — le resolveur hache un fichier, le moteur en rouvre un autre" \
  || { grep -q ARCHIVE_PATH_RELATIVE "$TMP/e10t" && ok "ARCHIVE_PATH_RELATIVE" || bad "refuse sans nommer ARCHIVE_PATH_RELATIVE : $(cat "$TMP/e10t")"; }

echo "⑩quater MANIFESTE_ABSENT — dev sans manifeste de publication"
REPO="$TMP/team10q"; make_team_repo "$REPO"
rm -f "$REPO/apis/accounts-read.publish.yml"
WORK="$TMP/w10q"
resolve_deploy_pin "$REPO" accounts-read dev "$WORK" main 2>"$TMP/e10q" \
  && bad "dev ACCEPTE sans manifeste de publication" \
  || { grep -q MANIFESTE_ABSENT "$TMP/e10q" && ok "MANIFESTE_ABSENT" || bad "refuse sans nommer MANIFESTE_ABSENT : $(cat "$TMP/e10q")"; }

echo "⑪ dev suit HEAD — l'environnement d'authoring n'exige ni marqueur ni digest"
REPO="$TMP/team11"; make_team_repo "$REPO"
WORK="$TMP/w11"; mkdir -p "$WORK"
if resolve_deploy_pin "$REPO" accounts-read dev "$WORK" main 2>"$TMP/e11"; then
  grep -q 'version: "2.0.0"' "$WORK/accounts-read.publish.yml" \
    && ok "dev résout depuis HEAD (2.0.0), sans marqueur — env d'authoring" \
    || bad "dev n'a pas résolu HEAD : $(cat "$WORK/accounts-read.publish.yml")"
else
  bad "dev refusé alors qu'il doit suivre HEAD : $(cat "$TMP/e11")"
fi

echo "⑫ CONTRE-ÉPREUVE — garde d'ancêtreté neutralisée ⇒ un SHA non mergé DOIT passer"
LIB="$ROOT/scripts/lib/deploy-pin.sh"
BAK="$(mktemp)"; cp "$LIB" "$BAK"
# LA RESTAURATION SE VÉRIFIE. Un `cp` dont personne ne lit le statut, suivi d'un
# `rm -f` inconditionnel de la sauvegarde, peut laisser la bibliothèque SABOTÉE
# dans l'arbre de travail — sans sauvegarde — pendant que le script imprime
# « N PASS / 0 FAIL ». Mesuré en revue. C'est très exactement « pire que pas de
# contre-épreuve ». On relit donc le fichier après restauration, et la
# sauvegarde ne disparaît qu'une fois la garde retrouvée.
restore_lib() {
  cp "$BAK" "$LIB" || { bad "RESTAURATION ECHOUEE : copie de $BAK vers $LIB"; return 1; }
  grep -q 'merge-base --is-ancestor' "$LIB" \
    || { bad "RESTAURATION ECHOUEE : la garde d'ancetrete est absente apres restauration — bibliotheque sabotee laissee sur disque"; return 1; }
  rm -f "$BAK"
}
trap 'restore_lib; rm -rf "$TMP"' EXIT INT TERM
# Sabotage : la garde devient un no-op QUI PASSE. Si l'épreuve ⑤ passe quand
# même au vert, c'est qu'elle mesurait autre chose que la garde — un vert
# vacant.
#
# ⚠ PIÈGE MESURÉ (2026-08-26) : le premier jet remplaçait `--is-ancestor` par
# un drapeau invalide (`--is-ancestor-DISABLED`). Ce n'est PAS un sabotage —
# c'est l'inverse : `git` rend alors un code non nul, le `||` se déclenche, et
# la garde REFUSE TOUJOURS. La contre-épreuve rougissait donc en annonçant
# « garde retirée et le refus persiste », ce qui était vrai et ne prouvait
# rien. Un sabotage doit OUVRIR la porte, jamais la souder fermée.
# On remplace donc la commande entière par `true`, ce qui laisse le `||` de la
# ligne suivante intact et fait passer la garde.
sed -i.tmp 's|git -C "$clone" merge-base --is-ancestor "$DEPLOY_PIN_COMMIT" "$mainref" 2>/dev/null|true|' "$LIB" && rm -f "$LIB.tmp"
# ⚠ TEST POSITIF, PAS NÉGATIF. Vérifier « la garde a disparu du fichier »
# (`! grep -q …`) serait satisfait par une RÉGRESSION qui l'aurait supprimée :
# le `sed` ne matcherait plus rien, aucun sabotage ne serait appliqué, et la
# sonde tournerait contre une bibliothèque déjà sans garde en imprimant
# « sabotage détecté ». Un vert vacant au cœur de l'épreuve écrite pour
# détecter les verts vacants. On exige donc que le fichier ait RÉELLEMENT
# changé.
if ! cmp -s "$LIB" "$BAK"; then
  ( set +u; . "$LIB"
    REPO2="$TMP/sab"; mkdir -p "$REPO2/apis"
    git -C "$REPO2" init -q -b main
    git -C "$REPO2" config user.email ci@stoa.lab; git -C "$REPO2" config user.name ci
    printf 'apim_api:\n  name: "a"\n  version: "1.0.0"\n' > "$REPO2/apis/a.publish.yml"
    printf 'apim_promote:\n  name: "a"\n  version: "1.0.0"\n  archive: "%s/z"\n' "$REPO2" > "$REPO2/apis/a.promote.yml"
    printf 'openapi: 3.0.0\n' > "$REPO2/apis/a.openapi.yaml"
    printf 'x' > "$REPO2/z"
    git -C "$REPO2" add -A && git -C "$REPO2" commit -qm base
    git -C "$REPO2" checkout -q -b evil
    printf 'apim_api:\n  name: "a"\n  version: "1.0.0"\n# evil\n' > "$REPO2/apis/a.publish.yml"
    git -C "$REPO2" add -A && git -C "$REPO2" commit -qm evil
    E=$(git -C "$REPO2" rev-parse HEAD); git -C "$REPO2" checkout -q main
    printf 'version: "1.0.0"\nenabled: true\npromoted_by: a\nmessage: t\ncommit: %s\nchange_ref: ""\narchive_sha256: "%s"\n' \
      "$E" "$(shasum -a 256 "$REPO2/z" | cut -d' ' -f1)" > "$REPO2/apis/a.deploy.rec.yaml"
    resolve_deploy_pin "$REPO2" a rec "$TMP/wsab" main "$REPO2/z" 2>/dev/null ) \
    && ok "sabotage détecté : garde retirée ⇒ un SHA non mergé passe (la garde mesurait bien quelque chose)" \
    || bad "garde retirée et le refus persiste — l'épreuve ⑤ ne mesure PAS cette garde (vert vacant)"
else
  bad "sabotage non appliqué — la contre-épreuve n'a rien prouvé"
fi
restore_lib
# Le trap est reduit au nettoyage : restore_lib vient de tourner et a detruit
# BAK, le rappeler echouerait sur un fichier absent.
trap 'rm -rf "$TMP"' EXIT INT TERM
```

- [ ] **Step 2 : Lancer les tests pour vérifier qu'ils échouent**

Run: `bash scripts/test-deploy-pin.sh`
Expected: FAIL sur ⑧, ⑨, ⑩ (digest non vérifié), et ⑪ échoue aussi (`dev` refusé par `PIN_ABSENT`).

- [ ] **Step 3 : Ajouter le traitement de dev et la vérification du digest**

**D'abord, trois modifications de la fonction EXISTANTE** (elles corrigent des défauts que les revues des tâches 1-2 ont mis au jour ; elles ne sont pas facultatives) :

1. **Signature** — ajouter un 6e positionnel : `archive_in="${6:-}"`. La ligne devient
   `local clone="$1" api="$2" env="$3" work="$4" mainref="${5:-origin/main}" archive_in="${6:-}"`.
2. **Remise à zéro des sorties, avant tout refus.** Juste après la ligne `local`, avant les validations de `$api`/`$env` :

```bash
  # Sans elle, un appel qui ÉCHOUE laisse en place les valeurs du précédent :
  # mesuré en revue — après un succès sur `bonapi` puis un échec sur
  # `mauvaiseapi`, DEPLOY_PIN_PUBLISH désignait le manifeste de la seconde et
  # DEPLOY_PIN_ARCHIVE les octets de la PREMIÈRE. Un appelant qui ignore le code
  # de retour (ou un wrapper Ansible en `ignore_errors`) déploierait les octets
  # d'une API sous l'identité d'une autre. Un refus doit laisser un état VIDE,
  # jamais l'état de quelqu'un d'autre.
  DEPLOY_PIN_COMMIT=""; DEPLOY_PIN_VERSION=""; DEPLOY_PIN_SHA256=""
  DEPLOY_PIN_PUBLISH=""; DEPLOY_PIN_PROMOTE=""; DEPLOY_PIN_CONTRACT=""
  DEPLOY_PIN_ARCHIVE=""
  export DEPLOY_PIN_COMMIT DEPLOY_PIN_VERSION DEPLOY_PIN_SHA256 \
         DEPLOY_PIN_PUBLISH DEPLOY_PIN_PROMOTE DEPLOY_PIN_CONTRACT DEPLOY_PIN_ARCHIVE
```

3. **Nommer le refus muet du `mkdir`** (le fichier affiche « toute anomalie est un refus **nommé** » ; celui-là ne l'était pas). Aux **deux** sites `mkdir -p "$work" || return 1` :

```bash
  mkdir -p "$work" \
    || { _dp_fail "WORKDIR_INCREABLE : impossible de créer '$work'"; return 1; }
```

**Ensuite**, dans `scripts/lib/deploy-pin.sh`, ajouter en tête du fichier, après `_STOA_DEPLOY_PIN_ROOT` :

```bash
# L'environnement d'AUTHORING — le seul palier sans marqueur, le seul qui suit
# HEAD (labctl/internal/uac/pinned.go:15 : « publish writes no pin: the entry
# environment follows HEAD by design »). ADR-079 : c'est le seul env où le blip
# de première création est toléré. C'est le PREMIER palier de la chaîne
# `environments.yaml` (clients/_example/environments.yaml : [dev, rec, int,
# homol, prod]).
#
# ⚠ AFFECTATION SÈCHE, PAS `${…:-dev}`. Une valeur surchargeable par
# l'environnement serait le contournement de TOUT ce fichier : poser
# `DEPLOY_PIN_AUTHORING_ENV=prod` ferait entrer la prod dans la branche
# d'authoring, qui retourne AVANT le marqueur, le pin, l'ancêtreté, la version
# et le digest — un repli total et silencieux sur HEAD, déclenché par un seul
# mot. Et ce n'est pas théorique ici : les paramètres d'un build Jenkins
# atterrissent dans l'environnement du job (fait mesuré lors du refactor des
# Jenkinsfile). Le seul palier qui a le droit de suivre HEAD ne se choisit pas
# depuis l'extérieur.
DEPLOY_PIN_AUTHORING_ENV="dev"
```

Remplacer la garde `PIN_ABSENT` par :

```bash
  if [ "$env" = "$DEPLOY_PIN_AUTHORING_ENV" ]; then
    # dev : pas de marqueur, pas de digest — on matérialise l'ARBRE DE TRAVAIL
    # du clone tel quel. En CI c'est exactement l'état revu (l'appelant a fait
    # `git checkout <MERGE_SHA>` avant d'appeler) ; hors CI, sur un clone sale,
    # ce n'est PAS HEAD — dire « HEAD » ici serait décrire autre chose que le
    # code.
    mkdir -p "$work" || return 1
    local g
    for g in publish.yml openapi.yaml; do
      cp "$clone/apis/${api}.${g}" "$work/${api}.${g}" \
        || { _dp_fail "MANIFESTE_ABSENT : apis/${api}.${g} introuvable sur HEAD"; return 1; }
    done
    DEPLOY_PIN_PROMOTE=""
    if [ -f "$clone/apis/${api}.promote.yml" ]; then
      cp "$clone/apis/${api}.promote.yml" "$work/${api}.promote.yml" \
        && DEPLOY_PIN_PROMOTE="$work/${api}.promote.yml"
    fi
    DEPLOY_PIN_COMMIT=""; DEPLOY_PIN_VERSION=""; DEPLOY_PIN_SHA256=""
    DEPLOY_PIN_PUBLISH="$work/${api}.publish.yml"
    DEPLOY_PIN_CONTRACT="$work/${api}.openapi.yaml"
    DEPLOY_PIN_ARCHIVE=""
    export DEPLOY_PIN_COMMIT DEPLOY_PIN_VERSION DEPLOY_PIN_SHA256 \
           DEPLOY_PIN_PUBLISH DEPLOY_PIN_PROMOTE DEPLOY_PIN_CONTRACT DEPLOY_PIN_ARCHIVE
    return 0
  fi

  [ -f "$clone/$rel" ] || { _dp_fail "PIN_ABSENT : $rel absent — hors de l'environnement d'authoring, aucun repli sur HEAD"; return 1; }
```

Ajouter **après** la garde `PIN_VERSION_MISMATCH**, en fin de fonction avant les `export` :

```bash
  # ── LE DIGEST ────────────────────────────────────────────────────────────
  # Le zip webMethods n'est pas reproductible bit-à-bit (horodatages) : cette
  # vérification FORCE donc la réutilisation des MÊMES octets d'un palier à
  # l'autre. C'est l'effet recherché — c'est ce qui distingue « build once,
  # deploy many » d'une intention.
  [ -n "$DEPLOY_PIN_SHA256" ] \
    || { _dp_fail "DIGEST_ABSENT : archive_sha256 vide pour l'env '$env' — hors authoring, les octets déployés doivent être pinnés"; return 1; }

  # promote.yml devient obligatoire ICI, et pas plus tôt : hors de l'env
  # d'authoring, le verbe est l'import d'archive (ADR-079) et c'est ce manifeste
  # qui pilote le play. Une API sans promote.yml ne peut pas voyager par archive.
  [ -n "$DEPLOY_PIN_PROMOTE" ] \
    || { _dp_fail "PROMOTE_MANIFEST_ABSENT : apis/${api}.promote.yml absent au SHA pinné — hors de '$DEPLOY_PIN_AUTHORING_ENV', la promotion se fait par archive et exige ce manifeste"; return 1; }

  # ⚠ LE CHEMIN DE L'ARCHIVE NE SE LIT PAS DANS promote.yml. Mesuré : le seul
  # manifeste réel du dépôt y porte une EXPRESSION JINJA, pas un chemin —
  #   clients/_example/apis/accounts-read.promote.yml:
  #     archive: "{{ playbook_dir }}/../dist/accounts-read-1.0.0.archive.zip"
  # que seul Ansible sait rendre, au moment du play. Un `stat` sur cette chaîne
  # brute échoue TOUJOURS : une première version de ce bloc la lisait, et la
  # promotion hors dev était donc morte au premier contact avec le format réel,
  # pendant que six fixtures inventaient un format littéral pour rester vertes.
  #
  # L'archive est un ARTEFACT DE BUILD dont l'appelant (le CI) connaît
  # l'emplacement — c'est lui qui l'a produite ou récupérée. Il le passe donc
  # explicitement. Le lien « approuvé == déployé » n'est pas porté par le
  # CHEMIN mais par le DIGEST, vérifié deux fois contre la même valeur pinnée :
  # ici sur les octets que le CI détient, et de nouveau dans le rôle sur les
  # octets qu'il s'apprête à POSTer (Task 6). Deux chemins, un invariant.
  [ -n "$archive_in" ] \
    || { _dp_fail "ARCHIVE_ABSENT : aucun chemin d'archive fourni (6e argument) — hors authoring le digest doit être vérifié, donc on ne promeut pas"; return 1; }
  # ABSOLU EXIGÉ : l'en-tête de ce fichier documente que les appelants font un
  # `cd` après le source. Un chemin relatif serait haché depuis le cwd du
  # résolveur puis réexporté tel quel, et le moteur le rouvrirait depuis SON
  # cwd : on vérifierait un fichier et on en déploierait un autre, sans aucun
  # refus. Mesuré.
  case "$archive_in" in
    /*) ;;
    *) { _dp_fail "ARCHIVE_PATH_RELATIVE : '$archive_in' n'est pas absolu — les octets vérifiés et les octets consommés seraient résolus depuis deux répertoires différents"; return 1; };;
  esac
  [ -f "$archive_in" ] \
    || { _dp_fail "ARCHIVE_ABSENT : archive '$archive_in' introuvable — le digest ne peut pas être vérifié, donc on ne promeut pas"; return 1; }

  local actual
  actual=$(shasum -a 256 "$archive_in" 2>/dev/null | cut -d' ' -f1) \
    || { _dp_fail "ARCHIVE_UNREADABLE : impossible de hacher '$archive_in' (droits ? fichier spécial ?)"; return 1; }
  # `actual` vide ne doit JAMAIS retomber dans la comparaison : si le digest
  # pinné pouvait l'être aussi, `"" = ""` passerait pour une correspondance —
  # le fail-open déjà rencontré sur la version.
  [ -n "$actual" ] \
    || { _dp_fail "ARCHIVE_UNREADABLE : sha256 vide pour '$archive_in'"; return 1; }
  [ "$actual" = "$DEPLOY_PIN_SHA256" ] \
    || { _dp_fail "ARCHIVE_DIGEST_MISMATCH : archive '$archive_in' porte $actual, le marqueur pinne $DEPLOY_PIN_SHA256"; return 1; }
  DEPLOY_PIN_ARCHIVE="$archive_in"
```

Et ajouter `DEPLOY_PIN_ARCHIVE` à la ligne `export` finale.

- [ ] **Step 4 : Lancer les tests pour vérifier qu'ils passent**

Run: `bash scripts/test-deploy-pin.sh`
Expected: PASS — `19 PASS / 0 FAIL`, contre-épreuve comprise.

- [ ] **Step 5 : Vérifier que shellcheck est propre**

Run: `shellcheck scripts/lib/deploy-pin.sh scripts/test-deploy-pin.sh`
Expected: aucune sortie (ou seulement des `SC1091` de source non suivi).

- [ ] **Step 6 : Commit**

```bash
git add scripts/lib/deploy-pin.sh scripts/test-deploy-pin.sh
git commit -m "feat(g3): digest d'archive verifie cote CI + contre-epreuve par sabotage"
```

---

### Task 4 : Le gabarit du marqueur dans le squelette d'équipe

**Files:**
- Create: `clients/_example/apis/accounts-read.deploy.rec.yaml.example`
- Modify: `scripts/test-deploy-pin.sh`

**Interfaces:**
- Consumes: le schéma du marqueur (Tasks 1–3).
- Produces: le fichier que `team-apply.sh:149` (`cp -R clients/_example/.`) propage à chaque nouveau dépôt d'équipe.

- [ ] **Step 1 : Écrire l'épreuve qui échoue**

Ajouter à `scripts/test-deploy-pin.sh` :

```bash
echo "⑬ le gabarit du marqueur est livré dans le squelette d'équipe"
TPL="$ROOT/clients/_example/apis/accounts-read.deploy.rec.yaml.example"
if [ -f "$TPL" ]; then
  MISSING=""
  for k in version enabled promoted_by message commit change_ref archive_sha256; do
    grep -qE "^${k}:" "$TPL" || MISSING="$MISSING $k"
  done
  [ -z "$MISSING" ] && ok "gabarit présent et complet (7 champs)" \
                    || bad "gabarit incomplet — champs manquants :$MISSING"
else
  bad "gabarit absent — un dépôt d'équipe créé par team-apply n'aurait aucun exemple de marqueur"
fi
```

- [ ] **Step 2 : Lancer le test pour vérifier qu'il échoue**

Run: `bash scripts/test-deploy-pin.sh`
Expected: FAIL — `gabarit absent`

- [ ] **Step 3 : Écrire le gabarit**

Créer `clients/_example/apis/accounts-read.deploy.rec.yaml.example` :

```yaml
# apis/<name>.deploy.<env>.yaml — LE MARQUEUR DE DÉPLOIEMENT (jalon G3).
#
# CE FICHIER EST LA RÉPONSE À « QU'EST-CE QUI TOURNE EXACTEMENT EN <env> ? ».
# Ce n'est PAS une branche d'environnement : une branche est un pointeur
# mouvant, elle ne peut pas répondre à cette question. Ici la réponse est
# immuable — un SHA de commit et un digest d'archive.
#
# ⚠ IL EST ÉCRIT PAR LA PROMOTION, JAMAIS À LA MAIN par l'équipe :
#   scripts/api-promote-request.sh ouvre une PR qui le porte. Le modèle retenu
#   est celui d'ADR-081 — « la décision humaine est le merge » — et cet ADR est
#   à ce jour au statut « Proposé, arbitrage client requis » : c'est le modèle
#   PROPOSÉ, pas une décision actée. Le dire autrement présenterait comme réglé
#   un point d'architecture que l'ADR lui-même laisse ouvert.
#   Ce fichier `.example` documente la forme, il n'est pas actif — renommez-le
#   sans `.example` seulement pour un test.
#
# ⚠ AUCUN MARQUEUR POUR L'ENVIRONNEMENT D'AUTHORING (`dev`) : dev suit HEAD
#   par conception (labctl/internal/uac/pinned.go:15). Un deploy.dev.yaml
#   n'est pas une erreur, il est sans objet.

# La version promue. Contrôle croisé : elle DOIT égaler la version du
# manifeste lu au SHA pinné, sinon PIN_VERSION_MISMATCH (un marqueur qui ment
# sur sa version déploierait une version que personne n'a demandée).
version: "1.0.0"

# Desired-state. `false` = le palier existe mais n'est pas servi.
enabled: true

# Le DEMANDEUR de la promotion. L'APPROBATEUR vit ailleurs (la porte de
# environments.yaml, et la trace du merge) : ce champ ne l'exprime pas et ne
# doit pas être lu comme tel.
promoted_by: alice

# Message d'audit — obligatoire côté écrivain.
message: "promotion dev → rec"

# ── LE PIN ───────────────────────────────────────────────────────────────────
# Un SHA de COMMIT du dépôt d'équipe, pas le SHA d'un fichier. TOUS les
# fichiers de cette API sont relus à ce commit : publish.yml, promote.yml,
# openapi.yaml. Pinner le seul contrat laisserait les alias backend, le GUID
# et le scope-mapping suivre main — le contrat serait figé et la configuration
# de déploiement, elle, dériverait.
#
# Le résolveur REFUSE un SHA qui n'est pas ancêtre de main (PIN_NON_ANCETRE) :
# `git show` réussit sur n'importe quel objet du clone, y compris un commit
# d'une branche jamais fusionnée.
commit: 0000000000000000000000000000000000000000

# Référence de changement ITSM, exigée À LA DEMANDE par les portes qui la
# réclament (`requireChangeRef` / `itsmCheck` dans environments.yaml) et
# conservée ici pour que la trace accompagne l'état promu. Vide si la porte du
# palier ne l'exige pas.
#
# ⚠ CE CHAMP N'EST PAS ENCORE RE-VÉRIFIÉ À L'APPLY pour ce marqueur-ci.
#   La garde anti-TOCTOU d'ADR-075 (labctl/cmd/labctl/dispatchgate.go) existe
#   bel et bien, mais elle porte sur l'AUTRE marqueur — celui du monorepo de
#   gouvernance, `tenants/{tenant}/apis/{slug}/deploy.{env}.yaml`. Le résolveur
#   de ce marqueur-ci ne lit que `commit`, `version` et `archive_sha256`.
#   Étendre la re-vérification ITSM à ce chemin reste à faire ; ne pas compter
#   dessus tant que ce n'est pas écrit.
change_ref: ""

# ── LE DIGEST ────────────────────────────────────────────────────────────────
# sha256 de l'archive promue, émis par `apim_promote_action=export`
# (EXPORT_CONFIRMED). OBLIGATOIRE dès que l'env n'est pas l'env d'authoring.
# Le zip webMethods n'étant pas reproductible bit-à-bit, cette vérification
# FORCE la réutilisation des mêmes octets d'un palier à l'autre — c'est ce qui
# fait de « build once, deploy many » autre chose qu'une intention.
archive_sha256: "0000000000000000000000000000000000000000000000000000000000000000"
```

- [ ] **Step 4 : Lancer le test pour vérifier qu'il passe**

Run: `bash scripts/test-deploy-pin.sh`
Expected: PASS — `20 PASS / 0 FAIL`

- [ ] **Step 5 : Commit**

```bash
git add clients/_example/apis/accounts-read.deploy.rec.yaml.example scripts/test-deploy-pin.sh
git commit -m "feat(g3): gabarit documente du marqueur dans le squelette d'equipe"
```

---

### Task 5 : L'export émet le digest

**Files:**
- Modify: `ansible/roles/apim_promote_api/tasks/export.yml:80-91`
- Test: `scripts/test-deploy-pin.sh`

**Interfaces:**
- Consumes: rien des tâches précédentes.
- Produces: le message `EXPORT_CONFIRMED` porte désormais `sha256=<64 hex>` ; fait Ansible `exp_sha256`.

- [ ] **Step 1 : Écrire l'épreuve qui échoue**

Ajouter à `scripts/test-deploy-pin.sh` :

```bash
echo "⑭ l'export ÉMET le sha256 APRÈS sanitisation — l'ORDRE est la propriété qui compte"
# ⚠ Un `grep` sur « checksum_algorithm: sha256 » ne prouverait RIEN d'utile : la
# sous-chaîne peut exister n'importe où, y compris dans un commentaire, et
# surtout elle ne dit pas si le digest est pris AVANT ou APRÈS la sanitisation.
# Or c'est exactement là qu'est le défaut possible — un digest des octets bruts
# pinnerait des octets que personne ne déploie. On PARSE donc le fichier et on
# vérifie l'ordre RÉEL des tâches, plus le câblage des variables.
EXP="$ROOT/ansible/roles/apim_promote_api/tasks/export.yml"
EXPV=$(EXP="$EXP" python3 "$ROOT/scripts/lib/export-order-probe.py") \
  || bad "PARSE_EXPORT : export.yml illisible"
case "$EXPV" in
  E=*)
    EXPV="${EXPV#E=}"
    I_SAN="${EXPV%%|*}";  EXPV="${EXPV#*|}"
    I_STAT="${EXPV%%|*}"; EXPV="${EXPV#*|}"
    I_CONF="${EXPV%%|*}"; EXPV="${EXPV#*|}"
    P_STAT="${EXPV%%|*}"; EXPV="${EXPV#*|}"
    F_SHA="${EXPV%%|*}";  G_64="${EXPV#*|}"
    { [ "$I_SAN" -ge 0 ] && [ "$I_STAT" -gt "$I_SAN" ] && [ "$I_CONF" -gt "$I_STAT" ]; } \
      && ok "ordre RÉEL : sanitize -> sha256 -> EXPORT_CONFIRMED (digest des octets SANITIZÉS)" \
      || bad "ordre FAUX (sanitize=$I_SAN, sha256=$I_STAT, confirmed=$I_CONF) — un digest pris avant sanitisation pinnerait des octets que personne ne déploie"
    [ "$P_STAT" = "{{ apim_promote.archive }}" ] \
      && ok "le stat cible bien l'archive du manifeste" \
      || bad "le stat cible '$P_STAT' et non {{ apim_promote.archive }}"
    case "$F_SHA" in
      *exp_stat.stat.checksum*) ok "exp_sha256 est alimenté par le checksum réellement calculé" ;;
      *) bad "exp_sha256 vient de '$F_SHA' — pas du stat : le sha256 affiché pourrait être sans rapport" ;;
    esac
    [ "$G_64" = 1 ] \
      && ok "garde fail-closed sur une longueur de 64 (digest incalculable => refus)" \
      || bad "aucune garde de longueur : un checksum vide partirait dans EXPORT_CONFIRMED"
    ;;
  *) bad "PARSE_EXPORT : sortie inattendue de la sonde d'ordre" ;;
esac
```

Créer aussi `scripts/lib/export-order-probe.py`, que l'épreuve appelle :

```python
#!/usr/bin/env python3
"""Sonde d'ORDRE sur export.yml (jalon G3, epreuve ⑭).

Un grep ne peut pas repondre a la seule question qui compte ici : le digest
est-il pris APRES la sanitisation ? Un digest des octets bruts pinnerait des
octets que personne ne deploie, et la sous-chaine cherchee serait pourtant la.
On parse donc le fichier et on rend les INDICES REELS des taches, plus le
cablage des variables, pour que le shell puisse comparer.

Sortie : E=<i_sanitize>|<i_stat>|<i_confirmed>|<chemin stat>|<source exp_sha256>|<garde 64 ? 0|1>
Un indice a -1 signale une tache introuvable.
"""
import os
import sys

import yaml

doc = yaml.safe_load(open(os.environ["EXP"])) or []

tasks = []


def walk(items):
    """Les taches reelles vivent dans le `.block` de la tache-enveloppe."""
    for t in items or []:
        if isinstance(t, dict):
            tasks.append(t)
            walk(t.get("block"))


walk(doc)
names = [str(t.get("name") or "") for t in tasks]


def idx(fragment):
    for i, n in enumerate(names):
        if fragment in n:
            return i
    return -1


stat_path, sha_fact, guard = "", "", "0"
for t in tasks:
    n = str(t.get("name") or "")
    if "sha256 de l" in n:
        stat_path = str((t.get("ansible.builtin.stat") or {}).get("path") or "")
    if "moriser le digest" in n:  # « mémoriser », sans l'accent pour la robustesse
        sha_fact = str((t.get("ansible.builtin.set_fact") or {}).get("exp_sha256") or "")
    if "digest calculable" in n:
        that = (t.get("ansible.builtin.assert") or {}).get("that") or []
        guard = "1" if any("64" in str(x) for x in that) else "0"

print("E=%d|%d|%d|%s|%s|%s" % (
    idx("sanitize de l"), idx("sha256 de l"), idx("archive saine"),
    stat_path, sha_fact, guard))
```

- [ ] **Step 2 : Lancer le test pour vérifier qu'il échoue**

Run: `bash scripts/test-deploy-pin.sh`
Expected: FAIL — la sonde rend `sha256=-1`, donc « ordre FAUX (sanitize=…, sha256=-1, …) », plus les trois autres assertions de ⑭ en échec.

- [ ] **Step 3 : Ajouter le calcul et l'affichage**

Dans `ansible/roles/apim_promote_api/tasks/export.yml`, insérer **entre** la tâche `"Export : rapport de sanitize"` et la tâche `"Export : FAIL-CLOSED — archive saine"` :

```yaml
    # ===== 4bis. Digest de l'ARTEFACT FINAL =================================
    # APRÈS la sanitisation, jamais avant : c'est l'archive sanitizée qui sera
    # importée, donc c'est elle dont les octets doivent être pinnés. Un digest
    # pris avant strippage pinnerait des octets que personne ne déploiera.
    - name: "Export : sha256 de l'archive sanitizée"
      ansible.builtin.stat:
        path: "{{ apim_promote.archive }}"
        checksum_algorithm: sha256
        get_checksum: true
      register: exp_stat

    - name: "Export : fail-closed — digest calculable"
      ansible.builtin.assert:
        that: "(exp_stat.stat.checksum | default('')) | length == 64"
        fail_msg: >-
          EXPORT_UNCONFIRMED : sha256 de {{ apim_promote.archive }} non calculable —
          sans digest, la promotion hors dev sera refusée (DIGEST_ABSENT).

    - name: "Export : mémoriser le digest"
      ansible.builtin.set_fact:
        exp_sha256: "{{ exp_stat.stat.checksum }}"
```

Puis, dans la tâche `"Export : FAIL-CLOSED — archive saine"`, remplacer le `success_msg` par :

```yaml
        success_msg: >-
          EXPORT_CONFIRMED : {{ apim_promote.archive }} — à épingler dans le manifeste et le
          marqueur : guid={{ exp_guid }} ; sha256={{ exp_sha256 }} ;
          strippé : {{ exp_report.stripped | length }} entrée(s).
```

- [ ] **Step 4 : Lancer le test et le lint Ansible**

Run: `bash scripts/test-deploy-pin.sh && ansible-playbook ansible/promote-api.yml --syntax-check 2>&1 | tail -3`
Expected: `24 PASS / 0 FAIL`, et `playbook: ansible/promote-api.yml` (syntaxe acceptée).

- [ ] **Step 5 : Commit**

```bash
git add ansible/roles/apim_promote_api/tasks/export.yml scripts/test-deploy-pin.sh scripts/lib/export-order-probe.py
git commit -m "feat(g3): l'export emet le sha256 de l'archive sanitizee"
```

---

### Task 6 : L'import vérifie le digest — la garde des degrés D0/D2

**Files:**
- Modify: `ansible/roles/apim_promote_api/defaults/main.yml`
- Modify: `ansible/roles/apim_promote_api/tasks/import.yml:13-21`
- Test: `scripts/test-deploy-pin.sh`

**Interfaces:**
- Consumes: `exp_sha256` (Task 5, pour l'opérateur).
- Produces: vars `apim_ss_archive_sha256` (défaut `""`), `apim_ss_authoring_env` (défaut `dev`) ; refus `ARCHIVE_DIGEST_REQUIRED`, `ARCHIVE_DIGEST_MISMATCH`.

- [ ] **Step 1 : Écrire l'épreuve qui échoue**

Ajouter à `scripts/test-deploy-pin.sh` :

```bash
echo "⑮ le rôle vérifie le digest LUI-MÊME — la garde des degrés D0/D2 (sans CI)"
# ⚠ MÊME LEÇON QU'À L'ÉPREUVE ⑭, ET IL FAUT LA RETENIR ICI AUSSI : cinq
# `grep -q` ne prouveraient que la présence de sous-chaînes quelque part dans
# le fichier. Une régression qui remplacerait le `when:` de l'assert par un
# test de PRÉSENCE (`… | length == 0`) — c'est-à-dire précisément le fail-open
# que cette tâche existe pour proscrire — laisserait les cinq greps VERTS tant
# que la chaîne « apim_ss_env != apim_ss_authoring_env » traîne ailleurs, un
# commentaire suffisant. On parse donc le YAML et on lit les champs `when:` et
# `that:` des asserts NOMMÉS.
IMP="$ROOT/ansible/roles/apim_promote_api/tasks/import.yml"
DEF="$ROOT/ansible/roles/apim_promote_api/defaults/main.yml"
grep -q '^apim_ss_archive_sha256:' "$DEF" \
  && ok "apim_ss_archive_sha256 déclaré dans les defaults" \
  || bad "apim_ss_archive_sha256 absent des defaults"
grep -q '^apim_ss_authoring_env:' "$DEF" \
  && ok "apim_ss_authoring_env déclaré (la condition n'est pas un nom d'env codé en dur)" \
  || bad "apim_ss_authoring_env absent — 'dev' serait codé en dur dans une condition"

IMPV=$(IMP="$IMP" python3 "$ROOT/scripts/lib/import-guard-probe.py") \
  || bad "PARSE_IMPORT : import.yml illisible"
case "$IMPV" in
  I=*)
    IMPV="${IMPV#I=}"
    W_REQ="${IMPV%%|*}"; IMPV="${IMPV#*|}"
    T_CMP="${IMPV%%|*}"; IMPV="${IMPV#*|}"
    H_ABS="${IMPV%%|*}"; O_ABS="${IMPV#*|}"
    # La condition du refus « digest obligatoire » doit porter sur l'ENV.
    case "$W_REQ" in
      *"apim_ss_env"*"!="*"apim_ss_authoring_env"*)
        ok "ARCHIVE_DIGEST_REQUIRED est conditionné par l'ENVIRONNEMENT" ;;
      "") bad "aucun assert ARCHIVE_DIGEST_REQUIRED trouvé — fail-open aux degrés D0/D2" ;;
      *)  bad "ARCHIVE_DIGEST_REQUIRED conditionné par '$W_REQ' — s'il teste la PRÉSENCE de la variable, oublier l'extra-var desactive le controle" ;;
    esac
    case "$T_CMP" in
      *apim_ss_archive_sha256*) ok "ARCHIVE_DIGEST_MISMATCH compare bien au digest pinné" ;;
      "") bad "aucun assert ARCHIVE_DIGEST_MISMATCH — les octets ne sont jamais compares" ;;
      *)  bad "ARCHIVE_DIGEST_MISMATCH compare '$T_CMP' — pas le digest pinné" ;;
    esac
    [ "$H_ABS" = 1 ] \
      && ok "une archive absente se dit ARCHIVE_ABSENT (pas une erreur Jinja brute)" \
      || bad "archive absente : la comparaison explose en 'dict object has no attribute checksum' au lieu de nommer la cause"
    [ "$O_ABS" = 1 ] \
      && ok "la garde d'existence precede la comparaison" \
      || bad "la garde d'existence ne precede pas la comparaison — l'erreur Jinja gagne quand meme"
    ;;
  *) bad "PARSE_IMPORT : sortie inattendue de la sonde" ;;
esac
```

- [ ] **Step 2 : Lancer le test pour vérifier qu'il échoue**

Run: `bash scripts/test-deploy-pin.sh`
Expected: FAIL — cinq échecs sur ⑮

- [ ] **Step 3 : Déclarer les vars**

Dans `ansible/roles/apim_promote_api/defaults/main.yml`, ajouter à la fin :

```yaml
# --- digest de l'archive (jalon G3) ------------------------------------------
# sha256 de l'archive à importer, épinglé dans apis/<name>.deploy.<env>.yaml et
# propagé par le CI. Le rôle le vérifie LUI AUSSI, et pas seulement le CI :
# DELIVERY-PROCESS.md §3 définit les degrés D0 (runbook, l'opérateur joue les
# scripts) et D2 (ansible-playbook --tags, sans orchestrateur) — à ces degrés il
# n'existe AUCUN résolveur CI. Une vérification qui ne vivrait que dans le CI
# serait absente précisément là où l'opérateur agit à la main.
apim_ss_archive_sha256: ""

# L'environnement d'AUTHORING — le seul qui n'exige pas de digest (il suit HEAD
# par conception, ADR-079). La condition du garde-fou porte sur CE NOM, pas sur
# la présence de apim_ss_archive_sha256 : un assert du genre « vérifie si on me
# donne un digest » se désactive en oubliant l'extra-var, ce qui est un
# fail-open déguisé en garde.
apim_ss_authoring_env: "dev"
```

- [ ] **Step 4 : Ajouter le garde-fou à l'import**

Dans `ansible/roles/apim_promote_api/tasks/import.yml`, insérer **après** la tâche `"Import : fail-closed — overwrite ne couvre JAMAIS les aliases"` et **avant** `"Import : inventaire de l'archive"` :

```yaml
    # ===== 0bis. Digest de l'archive (jalon G3) =============================
    # Défense en profondeur : le CI vérifie déjà ce digest AVANT de lancer ce
    # play (scripts/lib/deploy-pin.sh — un refus doit être mécaniquement
    # antérieur au play). Ce contrôle-ci existe pour les degrés D0/D2, où il
    # n'y a pas de CI du tout.
    - name: "Import : sha256 de l'archive à importer"
      ansible.builtin.stat:
        path: "{{ apim_promote.archive }}"
        checksum_algorithm: sha256
        get_checksum: true
      register: imp_stat

    - name: "Import : FAIL-CLOSED — digest EXIGÉ hors de l'environnement d'authoring"
      ansible.builtin.assert:
        that: "(apim_ss_archive_sha256 | default('')) | length == 64"
        fail_msg: >-
          ARCHIVE_DIGEST_REQUIRED : promotion vers '{{ apim_ss_env | default('') }}' sans
          apim_ss_archive_sha256. Hors de l'environnement d'authoring
          ('{{ apim_ss_authoring_env }}'), les octets déployés doivent être pinnés —
          le digest est produit par apim_promote_action=export (EXPORT_CONFIRMED).
      when: "(apim_ss_env | default('')) != apim_ss_authoring_env"

    # Une archive absente doit se dire AVEC SON NOM. Sans cette garde,
    # `imp_stat.stat` ne porte pas de clé `checksum` du tout et la comparaison
    # ci-dessous explose en erreur Jinja brute (« 'dict object' has no attribute
    # 'checksum' »). Le play s'arrête donc — la propriété fail-closed tient —
    # mais l'opérateur D0/D2, celui qui n'a AUCUN CI en amont pour le rattraper,
    # lit une trace de template au lieu de « l'archive est introuvable ». Or le
    # chemin d'archive erroné est justement sa panne la plus probable.
    - name: "Import : FAIL-CLOSED — l'archive existe"
      ansible.builtin.assert:
        that: "imp_stat.stat.exists | default(false)"
        fail_msg: >-
          ARCHIVE_ABSENT : {{ apim_promote.archive }} introuvable — le digest ne peut pas
          être vérifié, donc on n'importe pas.

    - name: "Import : FAIL-CLOSED — les octets sont bien ceux qui ont été approuvés"
      ansible.builtin.assert:
        that: "(imp_stat.stat.checksum | default('')) == apim_ss_archive_sha256"
        fail_msg: >-
          ARCHIVE_DIGEST_MISMATCH : {{ apim_promote.archive }} porte
          {{ imp_stat.stat.checksum | default('(illisible)') }} mais le marqueur pinne
          {{ apim_ss_archive_sha256 }} — ce ne sont pas les octets approuvés.
        success_msg: "ARCHIVE_DIGEST_OK : {{ apim_ss_archive_sha256 }}"
      when: "(apim_ss_archive_sha256 | default('')) | length == 64"
```

Créer aussi `scripts/lib/import-guard-probe.py`, que l'épreuve appelle :

```python
#!/usr/bin/env python3
"""Sonde de GARDE sur import.yml (jalon G3, epreuve ⑮).

Un grep ne peut pas repondre a la question qui compte : le refus « digest
obligatoire » est-il conditionne par l'ENVIRONNEMENT, ou par la PRESENCE de la
variable ? La seconde forme est un fail-open — oublier l'extra-var desactive le
controle — et les deux se ressemblent dans un grep. On lit donc les champs
`when:` et `that:` des asserts NOMMES.

Sortie : I=<when du refus digest>|<that de la comparaison>|<garde d'existence ? 0|1>|<elle precede ? 0|1>
"""
import os
import sys

import yaml

doc = yaml.safe_load(open(os.environ["IMP"])) or []

tasks = []


def walk(items):
    for t in items or []:
        if isinstance(t, dict):
            tasks.append(t)
            walk(t.get("block"))


walk(doc)


def find(fragment):
    """La tache dont le fail_msg porte ce fragment, avec son indice."""
    for i, t in enumerate(tasks):
        a = t.get("ansible.builtin.assert") or {}
        if fragment in str(a.get("fail_msg") or ""):
            return i, t, a
    return -1, None, None


i_req, _, a_req = find("ARCHIVE_DIGEST_REQUIRED")
i_cmp, t_cmp, a_cmp = find("ARCHIVE_DIGEST_MISMATCH")
i_abs, _, _ = find("ARCHIVE_ABSENT")

when_req = str((tasks[i_req].get("when") if i_req >= 0 else "") or "")
that_cmp = str((a_cmp.get("that") if a_cmp else "") or "")
has_abs = "1" if i_abs >= 0 else "0"
before = "1" if (i_abs >= 0 and i_cmp >= 0 and i_abs < i_cmp) else "0"

print("I=%s|%s|%s|%s" % (when_req, that_cmp, has_abs, before))
```

- [ ] **Step 5 : Lancer le test et le lint**

Run: `bash scripts/test-deploy-pin.sh && bash scripts/test-jenkinsfile-lint.sh`
Expected: `30 PASS / 0 FAIL` pour le premier ; le lint Jenkinsfile inchangé (12/12).

- [ ] **Step 6 : Commit**

```bash
git add ansible/roles/apim_promote_api/defaults/main.yml ansible/roles/apim_promote_api/tasks/import.yml scripts/test-deploy-pin.sh scripts/lib/import-guard-probe.py
git commit -m "feat(g3): l'import verifie le digest — garde fail-closed des degres D0/D2"
```

---

### Task 7 : L'écrivain — gardes d'entrée

**Files:**
- Create: `scripts/api-promote-request.sh`
- Test: `scripts/test-deploy-pin.sh`

**Interfaces:**
- Consumes: `env_chain` (`scripts/lib/env-chain.sh`, existant) ; `deploy_pin_marker_path` (Task 1).
- Produces:
  - `env_chain_gate <env>` — **nouvelle fonction publique** de `scripts/lib/env-chain.sh`, rendant `GATE=<needChange 0|1>|<needPV 0|1>|<approverGroup>`.
  - refus `CHAINE_INVALIDE`, `GATE_REFS_REQUIRED`, `DIGEST_ABSENT`, `DIGEST_MALFORMED`. Le script s'arrête sur toute garde **avant tout geste Git**.

> **Pourquoi une nouvelle fonction plutôt que lire le fichier directement.** `env-chain.sh` expose déjà `env_chain_approver_group` mais rien qui dise ce que la porte **exige**. Sans ajout, `api-promote-request.sh` devrait soit atteindre la fonction privée `_env_chain_file`, soit redupliquer sa règle de préséance (`$STOA_ENV_CHAIN_FILE` puis le gabarit livré) — deux façons de laisser la source de la chaîne diverger. La lecture de la chaîne appartient à `env-chain.sh` ; `env_chain_gate` s'y range à côté de `env_chain_approver_group`, dont elle est le prolongement naturel.

- [ ] **Step 1 : Écrire les épreuves qui échouent**

Ajouter à `scripts/test-deploy-pin.sh` :

```bash
echo "⑯ l'écrivain refuse AVANT tout geste Git"
W="$ROOT/scripts/api-promote-request.sh"
if [ ! -f "$W" ]; then
  bad "api-promote-request.sh absent — rien ne produit de marqueur"
else
  run_w() { ( cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" \
      STOA_ENV_CHAIN_FILE="$ROOT/clients/_example/environments.yaml" \
      TEAM=accounts-team API_NAME=accounts-read \
      FROM_ENV="$1" TO_ENV="$2" MESSAGE="m" \
      CHANGE_REF="${3-}" PV_REF="${4-}" ARCHIVE_SHA256="${5-}" \
      GITEA_TOKEN=x DRY_RUN=1 bash "$W" 2>&1 ); }

  run_w dev prod "" "" "$(printf 'a%.0s' $(seq 64))" | grep -q CHAINE_INVALIDE \
    && ok "CHAINE_INVALIDE — un saut dev→prod n'est pas exprimable" \
    || bad "saut de palier ACCEPTÉ"

  run_w int homol "" "" "$(printf 'a%.0s' $(seq 64))" | grep -q GATE_REFS_REQUIRED \
    && ok "GATE_REFS_REQUIRED — la porte homol exige un pv_ref, refusé À LA DEMANDE" \
    || bad "promotion vers homol sans pv_ref ACCEPTÉE"

  run_w dev rec "" "" "" | grep -q DIGEST_ABSENT \
    && ok "DIGEST_ABSENT — pas de promotion hors authoring sans digest" \
    || bad "promotion hors dev sans digest ACCEPTÉE"

  run_w dev rec "" "" "pas-un-digest" | grep -q DIGEST_MALFORMED \
    && ok "DIGEST_MALFORMED (longueur)" \
    || bad "digest de forme invalide ACCEPTÉ"

  # ⚠ « DEUX VERROUS, PAS UN » — et il faut donc DEUX épreuves. L'assertion
  # ci-dessus est interceptée par le verrou de LONGUEUR (13 caractères) et
  # laisse le verrou de CLASSE DE CARACTÈRES sans aucune couverture : mesuré
  # en revue, neutraliser ce dernier laissait les quatre assertions VERTES
  # alors que le mutant acceptait 64 caractères non hexadécimaux comme digest.
  run_w dev rec "" "" "$(printf 'z%.0s' $(seq 64))" | grep -q DIGEST_MALFORMED \
    && ok "DIGEST_MALFORMED (classe de caractères, 64 non-hex)" \
    || bad "64 caractères non hexadécimaux ACCEPTÉS comme digest — un nom de branche passerait pour des octets"

  # `itsmCheck` IMPLIQUE une référence de changement : sans elle il n'y a rien
  # à re-vérifier auprès de l'ITSM. C'est LA raison d'être d'env_chain_gate.
  #
  # ⚠ ET ELLE NE PEUT PAS S'ÉPROUVER SUR LA CHAÎNE LIVRÉE. Mesuré en revue : la
  # porte `prod` de clients/_example/environments.yaml déclare SIMULTANÉMENT
  # `requireChangeRef: true` ET `itsmCheck: true`. Sur ce jeu-là, retirer
  # l'implication ne change RIEN — `requireChangeRef` fait le même travail sur
  # la même porte, et l'assertion reste verte en croyant mesurer l'implication.
  # Il faut donc une chaîne JETABLE où `itsmCheck` est SEUL. `env-chain.sh`
  # prévoit exactement ça : $STOA_ENV_CHAIN_FILE l'emporte sur le gabarit.
  CHAIN_ITSM="$TMP/chain-itsm-seul.yaml"
  printf 'environments: [dev, rec, int, homol, prod]\ngates:\n  - to: prod\n    itsmCheck: true\n' \
    > "$CHAIN_ITSM"
  run_wc() { ( cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" \
      STOA_ENV_CHAIN_FILE="$CHAIN_ITSM" \
      TEAM=accounts-team API_NAME=accounts-read \
      FROM_ENV="$1" TO_ENV="$2" MESSAGE="m" \
      CHANGE_REF="${3-}" PV_REF="${4-}" ARCHIVE_SHA256="${5-}" \
      GITEA_TOKEN=x DRY_RUN=1 bash "$W" 2>&1 ); }
  run_wc homol prod "" "" "$(printf 'a%.0s' $(seq 64))" | grep -q GATE_REFS_REQUIRED \
    && ok "itsmCheck SEUL implique change_ref — refus sur une porte sans requireChangeRef" \
    || bad "implication itsmCheck => requireChangeRef non appliquée (porte itsmCheck seul)"

  # ⚠ LE CHEMIN NOMINAL. Une suite dont toutes les épreuves sont des REFUS ne
  # teste jamais l'acceptation : une garde trop zélée — la boucle de chaîne
  # cassée de sorte que NEXT soit toujours vide, une validation de nom durcie à
  # l'excès — passerait au vert partout. Leçon déjà payée sur ce dépôt.
  run_w homol prod "C-1" "PV-1" "$(printf 'a%.0s' $(seq 64))" | grep -q GARDES_OK \
    && ok "chemin NOMINAL : une promotion complète et légitime est ACCEPTÉE" \
    || bad "une promotion pourtant conforme est refusée — garde trop zélée"
fi
```

- [ ] **Step 2 : Lancer le test pour vérifier qu'il échoue**

Run: `bash scripts/test-deploy-pin.sh`
Expected: FAIL — `api-promote-request.sh absent`

- [ ] **Step 3 : Ajouter `env_chain_gate` à `scripts/lib/env-chain.sh`**

Ajouter à la fin de `scripts/lib/env-chain.sh`, juste après `env_chain_approver_group` :

```bash
# Ce que la porte d'un palier EXIGE, en une lecture — prolongement de
# env_chain_approver_group, qui ne disait que QUI approuve. Rend :
#   GATE=<changeRef 0|1>|<pvRef 0|1>|<approverGroup>
#
# `itsmCheck` IMPLIQUE une référence de changement : il n'y a rien à
# re-vérifier auprès de l'ITSM sans elle (même règle que
# governance-api, handlers_promotions.go:77-89 — la porte est lue au même
# endroit des deux côtés, sinon les deux divergent en silence).
env_chain_gate() {
  local f; f="$(_env_chain_file)"
  [ -r "$f" ] || { echo "env-chain: source illisible : $f" >&2; return 1; }
  python3 - "$f" "$1" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
g = next((x for x in (d.get("gates") or []) if x.get("to") == sys.argv[2]), {}) or {}
print("GATE=%s|%s|%s" % (
    "1" if (g.get("requireChangeRef") or g.get("itsmCheck")) else "0",
    "1" if g.get("requirePVRef") else "0",
    g.get("approverGroup") or ""))
PY
}
```

- [ ] **Step 4 : Écrire l'écrivain (gardes seulement, `DRY_RUN` s'arrête avant Git)**

Créer `scripts/api-promote-request.sh` :

```bash
#!/usr/bin/env bash
# api-promote-request.sh — moteur du formulaire « promouvoir une API »
# (jalon G3). Pendant de api-request.sh (publication) : MÊME MODÈLE STRUCTUREL
# — gardes nommées AVANT tout geste Git, team -> repo lu sur GITEA MAIN (jamais
# le worktree local), push par GIT_CONFIG_COUNT/KEY_0/VALUE_0 (jamais de token
# en URL ni en argv), PR par heredoc python, plan commenté sur la PR.
#
# CE SCRIPT NE DÉPLOIE RIEN. Il ouvre une PR portant le marqueur
# apis/<name>.deploy.<TO_ENV>.yaml. La DÉCISION est le merge (ADR-081) ; la
# PORTE (4-yeux, ITSM, groupe d'approbation) est enforcée à l'apply par
# labctl/governance-api, PAS ici — les gardes ci-dessous sont in-repo, donc
# justiciables d'OWASP CICD-SEC-04 : elles rendent le refus LISIBLE TÔT, elles
# ne le rendent pas INCONTOURNABLE. La fermeture réelle est le jalon G4
# (rétention du credential par palier).
#
# Entrées (env — mappées depuis les paramètres du job) :
#   TEAM, API_NAME, FROM_ENV, TO_ENV, MESSAGE   (requis)
#   CHANGE_REF, PV_REF                          (selon la porte d'arrivée)
#   ARCHIVE_SHA256                              (requis si TO_ENV != authoring)
#   GITEA_TOKEN                                 (requis hors DRY_RUN)
#   DRY_RUN=1                                   (s'arrête après les gardes)
set -uo pipefail
set +x   # jamais de trace : le token ne doit pas fuiter
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=lib/env-chain.sh
. scripts/lib/env-chain.sh
# shellcheck source=lib/deploy-pin.sh
. scripts/lib/deploy-pin.sh

fail() { printf 'ERREUR: %s\n' "$*" >&2; exit 1; }

TEAM="${TEAM:?TEAM requis}"
API_NAME="${API_NAME:?API_NAME requis}"
FROM_ENV="${FROM_ENV:?FROM_ENV requis}"
TO_ENV="${TO_ENV:?TO_ENV requis}"
MESSAGE="${MESSAGE:?MESSAGE requis}"
CHANGE_REF="${CHANGE_REF:-}"
PV_REF="${PV_REF:-}"
ARCHIVE_SHA256="${ARCHIVE_SHA256:-}"
AUTHORING_ENV="${DEPLOY_PIN_AUTHORING_ENV:-dev}"

# ⚠ FORME NÉGATIVE, ET C'EST LA SEULE QUI MARCHE. Dans un motif de `case`,
# `*` n'est pas un quantificateur mais le joker « n'importe quelle suite » :
# `[a-z0-9][a-z0-9-]*` se lit donc « un caractère, puis un caractère, puis
# ABSOLUMENT N'IMPORTE QUOI ». Mesuré en revue — cette forme acceptait
# `ab/../../../etc/passwd`, `ab$(id)` et `ab;rm -rf /`. C'est la classe de
# défaut que ce dépôt documente déjà noir sur blanc dans deploy-pin.sh, et
# dont la garde sœur (`""|*[!a-z0-9-]*`) est la forme correcte.
case "$API_NAME" in
  ""|-*|*[!a-z0-9-]*) fail "API_NAME_INVALIDE : '$API_NAME' — attendu des minuscules, chiffres et tirets, sans tiret initial" ;;
esac
[ "${#MESSAGE}" -le 1000 ] || fail "MESSAGE_TROP_LONG : le message d'audit dépasse 1000 caractères"

# ── Garde 1 : LA CHAÎNE ─────────────────────────────────────────────────────
# TO_ENV doit être le SUIVANT de FROM_ENV dans environments.yaml. L'ordre de la
# liste EST la chaîne : un saut dev -> prod n'est pas exprimable.
CHAIN="$(env_chain)" || fail "CHAINE_ILLISIBLE : environments.yaml absent, vide ou cassé"
NEXT=""
PREV=""
for e in $CHAIN; do
  if [ "$PREV" = "$FROM_ENV" ]; then NEXT="$e"; break; fi
  PREV="$e"
done
[ -n "$NEXT" ] && [ "$NEXT" = "$TO_ENV" ] \
  || fail "CHAINE_INVALIDE : '$FROM_ENV' -> '$TO_ENV' n'est pas un saut de la chaîne ($CHAIN)"

# ── Garde 2 : LES RÉFÉRENCES QUE LA PORTE D'ARRIVÉE EXIGE ───────────────────
# Refusé À LA DEMANDE, jamais découvert à l'approbation — miroir de
# handlers_promotions.go:77-89. itsmCheck IMPLIQUE change_ref : il n'y a rien à
# re-vérifier auprès de l'ITSM sans une référence.
GATE=$(env_chain_gate "$TO_ENV") || fail "PARSE_GATE : lecture de la porte vers '$TO_ENV'"
case "$GATE" in GATE=*) GATE="${GATE#GATE=}";; *) fail "PARSE_GATE : sortie inattendue";; esac
NEED_CHANGE="${GATE%%|*}"; GATE="${GATE#*|}"
NEED_PV="${GATE%%|*}"; APPROVER_GROUP="${GATE#*|}"

[ "$NEED_CHANGE" = 0 ] || [ -n "$CHANGE_REF" ] \
  || fail "GATE_REFS_REQUIRED : la porte vers '$TO_ENV' exige une référence de changement (CHANGE_REF)"
[ "$NEED_PV" = 0 ] || [ -n "$PV_REF" ] \
  || fail "GATE_REFS_REQUIRED : la porte vers '$TO_ENV' exige une référence de PV de recette (PV_REF)"

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

echo "GARDES_OK : $FROM_ENV -> $TO_ENV, groupe d'approbation='${APPROVER_GROUP:-<aucun>}'"
[ "${DRY_RUN:-0}" = 1 ] && exit 0

GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN requis}"
echo "GESTE_GIT_NON_IMPLEMENTE : voir Task 8" >&2
exit 1
```

- [ ] **Step 5 : Lancer le test pour vérifier qu'il passe**

Run: `bash scripts/test-deploy-pin.sh`
Expected: PASS — `37 PASS / 0 FAIL`

- [ ] **Step 6 : Commit**

```bash
git add scripts/api-promote-request.sh scripts/test-deploy-pin.sh
git commit -m "feat(g3): ecrivain du marqueur — gardes d'entree avant tout geste Git"
```

---

### Task 8 : L'écrivain — la garde de source, le pin, la PR

**Files:**
- Modify: `scripts/api-promote-request.sh`
- Test: `scripts/test-deploy-pin.sh`

**Interfaces:**
- Consumes: les gardes de la Task 7.
- Produces: refus `SOURCE_NON_DEPLOYEE`, `REPO_NON_DECLARE` ; une branche `promote/<name>-<TO_ENV>` portant `apis/<name>.deploy.<TO_ENV>.yaml`, et une PR sur le dépôt d'équipe.

- [ ] **Step 1 : Écrire l'épreuve qui échoue**

Ajouter à `scripts/test-deploy-pin.sh` :

```bash
echo "⑰ le pin écrit est le DERNIER COMMIT touchant l'API, pas HEAD"
# On teste la fonction de calcul du pin isolément, sur un dépôt réel : l'équipe
# modifie une AUTRE API après coup ; le pin d'accounts-read ne doit pas bouger.
REPO="$TMP/team17"; make_team_repo "$REPO"
TARGET=$(git -C "$REPO" log -1 --format=%H -- 'apis/accounts-read.*')
printf 'apim_api:\n  name: "payments-read"\n  version: "1.0.0"\n' > "$REPO/apis/payments-read.publish.yml"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "autre API"
AFTER=$(git -C "$REPO" log -1 --format=%H -- 'apis/accounts-read.*')
[ "$TARGET" = "$AFTER" ] \
  && ok "le pin d'accounts-read ne bouge pas quand payments-read change" \
  || bad "le pin a suivi HEAD — deux APIs du même dépôt se contamineraient"

echo "⑱ SOURCE_NON_DEPLOYEE — on ne promeut pas depuis un palier vide"
grep -q SOURCE_NON_DEPLOYEE "$ROOT/scripts/api-promote-request.sh" \
  && ok "SOURCE_NON_DEPLOYEE présent dans l'écrivain" \
  || bad "aucune garde sur l'état du palier SOURCE — on promouvrait du néant"
grep -q 'GIT_CONFIG_KEY_0=http.extraheader' "$ROOT/scripts/api-promote-request.sh" \
  && ok "push par header injecté (jamais de token en URL/argv)" \
  || bad "le token risque d'apparaître dans ps -Aww pendant le push"
grep -q REPO_NON_DECLARE "$ROOT/scripts/api-promote-request.sh" \
  && ok "REPO_NON_DECLARE — une équipe sans dépôt déclaré est refusée" \
  || bad "aucune garde sur l'appartenance dépôt↔équipe"
# L'équipe est dérivée de providers.<env>.yml lu sur GITEA MAIN — jamais du
# worktree local (qui peut être en retard ou modifié). Même discipline que
# team-publish.sh §3 : le seul énoncé qui fait autorité sur « ce dépôt
# appartient à cette équipe » vit sur main du dépôt plateforme.
grep -q 'repos/${GIT_REPO}/raw/ansible/providers' "$ROOT/scripts/api-promote-request.sh" \
  && ok "providers lu sur Gitea main, pas sur le worktree local" \
  || bad "providers lu localement — un worktree en retard déciderait de l'appartenance"
```

- [ ] **Step 2 : Lancer le test pour vérifier qu'il échoue**

Run: `bash scripts/test-deploy-pin.sh`
Expected: FAIL sur ⑱ (`aucune garde sur l'état du palier SOURCE`, `le token risque d'apparaître`). ⑰ passe déjà (c'est une propriété de `git log`, on la verrouille).

- [ ] **Step 3 : Écrire le geste Git**

Dans `scripts/api-promote-request.sh`, remplacer les trois dernières lignes (`GITEA_TOKEN=...`, `echo "GESTE_GIT_NON_IMPLEMENTE..."`, `exit 1`) par :

```bash
GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN requis}"
GIT_HOST="${GIT_HOST:-http://gitea:3000}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"   # dépôt PLATEFORME — porte providers.<env>.yml
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; umask 077
printf 'Authorization: token %s\n' "$GITEA_TOKEN" > "$TMP/ghdr"
gapi() { curl -s -H @"$TMP/ghdr" -H 'Content-Type: application/json' "$@"; }

# ── team -> repo, lu sur GITEA MAIN (jamais le worktree local) ───────────────
# Le worktree local peut être en retard, ou modifié : la seule source qui dit
# VRAIMENT « ce dépôt appartient à cette équipe » est providers.<env>.yml sur
# main du dépôt plateforme (même discipline que team-publish.sh §3).
gapi "${GIT_HOST}/api/v1/repos/${GIT_REPO}/raw/ansible/providers.${AUTHORING_ENV}.yml" \
  > "$TMP/providers.yml" || fail "LECTURE_PROVIDERS : providers.${AUTHORING_ENV}.yml illisible sur ${GIT_REPO}@main"
REPO_FULL=$(TEAM="$TEAM" PROV="$TMP/providers.yml" python3 - <<'PY'
import os, sys, yaml
d = yaml.safe_load(open(os.environ["PROV"])) or {}
e = next((p for p in (d.get("providers") or []) if p.get("team") == os.environ["TEAM"]), None)
if e is None:
    sys.exit("TEAM_NOT_FOUND")
print("REPO=" + (e.get("repo") or ""))
PY
) || fail "REPO_NON_DECLARE : équipe '$TEAM' absente de providers.${AUTHORING_ENV}.yml"
case "$REPO_FULL" in REPO=*) REPO_FULL="${REPO_FULL#REPO=}";; *) fail "PARSE_PROVIDERS : sortie inattendue";; esac
[ -n "$REPO_FULL" ] || fail "REPO_NON_DECLARE : équipe '$TEAM' sans dépôt dans providers.${AUTHORING_ENV}.yml"

# ── clone du dépôt d'équipe (authentifié — un dépôt privé casserait sinon) ───
AUTH_B64=$(printf 'x:%s' "$GITEA_TOKEN" | base64 | tr -d '\n')
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
       GIT_CONFIG_VALUE_0="Authorization: Basic ${AUTH_B64}"
unset AUTH_B64
git clone -q "${GIT_HOST}/${REPO_FULL}.git" "$TMP/team" \
  || fail "CLONE_ECHEC : ${REPO_FULL}"

# ── Garde 4 : LE PALIER SOURCE PORTE-T-IL QUELQUE CHOSE ? ───────────────────
# Depuis l'env d'authoring, c'est la présence du manifeste de publication qui
# en tient lieu : dev n'a PAS de marqueur, par conception.
if [ "$FROM_ENV" = "$AUTHORING_ENV" ]; then
  [ -f "$TMP/team/apis/${API_NAME}.publish.yml" ] \
    || fail "SOURCE_NON_DEPLOYEE : apis/${API_NAME}.publish.yml absent de ${REPO_FULL} — rien à promouvoir depuis '$FROM_ENV'"
else
  SRC_REL="$(deploy_pin_marker_path "$API_NAME" "$FROM_ENV")"
  [ -f "$TMP/team/$SRC_REL" ] \
    || fail "SOURCE_NON_DEPLOYEE : $SRC_REL absent — '$API_NAME' n'est pas déployée en '$FROM_ENV'"
  SRC_ON=$(DP_FILE="$TMP/team/$SRC_REL" python3 - <<'PY'
import os, yaml
d = yaml.safe_load(open(os.environ["DP_FILE"])) or {}
print("EN=" + ("1" if d.get("enabled") else "0"))
PY
) || fail "PARSE_MARQUEUR_SOURCE : $SRC_REL illisible"
  case "$SRC_ON" in EN=1) ;; EN=0) fail "SOURCE_NON_DEPLOYEE : $SRC_REL porte enabled: false" ;;
    *) fail "PARSE_MARQUEUR_SOURCE : sortie inattendue" ;; esac
fi

# ── le pin : DERNIER commit de main touchant CETTE API ──────────────────────
# Pas HEAD : le pin d'une API ne doit pas bouger parce qu'une API SŒUR du même
# dépôt a changé.
PIN=$(git -C "$TMP/team" log -1 --format=%H -- "apis/${API_NAME}.*")
[ -n "$PIN" ] || fail "PIN_INTROUVABLE : aucun commit ne touche apis/${API_NAME}.* sur ${REPO_FULL}@main"
VERSION=$(DP_FILE="$TMP/team/apis/${API_NAME}.publish.yml" python3 - <<'PY'
import os, yaml
d = yaml.safe_load(open(os.environ["DP_FILE"])) or {}
print("V=" + str((d.get("apim_api") or {}).get("version") or ""))
PY
) || fail "PARSE_MANIFEST : lecture de la version"
case "$VERSION" in V=*) VERSION="${VERSION#V=}";; *) fail "PARSE_MANIFEST : sortie inattendue";; esac
[ -n "$VERSION" ] || fail "VERSION_ABSENTE : apis/${API_NAME}.publish.yml ne porte pas de version"

# ── branche, marqueur, commit, push, PR ─────────────────────────────────────
BRANCH="promote/${API_NAME}-${TO_ENV}"
MARKER="$(deploy_pin_marker_path "$API_NAME" "$TO_ENV")"
git -C "$TMP/team" checkout -q -b "$BRANCH"
MSG="$MESSAGE" PB="${PROMOTED_BY:-ci}" V="$VERSION" P="$PIN" CR="$CHANGE_REF" \
  SH="$ARCHIVE_SHA256" OUT="$TMP/team/$MARKER" python3 - <<'PY'
import os
open(os.environ["OUT"], "w").write(
    'version: "%s"\nenabled: true\npromoted_by: %s\nmessage: "%s"\ncommit: %s\n'
    'change_ref: "%s"\narchive_sha256: "%s"\n' % (
        os.environ["V"], os.environ["PB"],
        os.environ["MSG"].replace('"', "'"), os.environ["P"],
        os.environ["CR"], os.environ["SH"]))
PY
git -C "$TMP/team" add "$MARKER"
git -C "$TMP/team" -c user.name=ci -c user.email=ci@stoa.lab \
  commit -qm "promote(${API_NAME}): ${FROM_ENV} -> ${TO_ENV} @ ${PIN}" \
  || fail "COMMIT_VIDE : le marqueur est déjà à cette valeur (rien à promouvoir)"
git -C "$TMP/team" push -q origin "$BRANCH" || fail "PUSH_ECHEC : $BRANCH sur $REPO_FULL"

PR_URL=$(API="${GIT_HOST}/api/v1" R="$REPO_FULL" B="$BRANCH" \
  T="promote(${API_NAME}): ${FROM_ENV} → ${TO_ENV}" \
  BODY="Marqueur \`${MARKER}\` — pin \`${PIN}\`, sha256 \`${ARCHIVE_SHA256:-<authoring>}\`.

La DÉCISION est le merge de cette PR (ADR-081). Groupe d'approbation attendu : \`${APPROVER_GROUP:-<aucun>}\`." \
  HDR="$TMP/ghdr" python3 - <<'PY'
import json, os, urllib.request
h = dict(l.split(": ", 1) for l in open(os.environ["HDR"]).read().splitlines() if l)
h["Content-Type"] = "application/json"
req = urllib.request.Request(
    f"{os.environ['API']}/repos/{os.environ['R']}/pulls", method="POST",
    data=json.dumps({"head": os.environ["B"], "base": "main",
                     "title": os.environ["T"], "body": os.environ["BODY"]}).encode(),
    headers=h)
print(json.load(urllib.request.urlopen(req))["html_url"])
PY
) || fail "PR_ECHEC : ouverture de la PR sur $REPO_FULL"
echo "PROMOTION_DEMANDEE : $PR_URL"
```

- [ ] **Step 4 : Lancer les tests et shellcheck**

Run: `bash scripts/test-deploy-pin.sh && shellcheck scripts/api-promote-request.sh scripts/lib/deploy-pin.sh`
Expected: `42 PASS / 0 FAIL` ; shellcheck sans erreur (les `SC1091` de source non suivi sont acceptables).

- [ ] **Step 5 : Commit**

```bash
git add scripts/api-promote-request.sh scripts/test-deploy-pin.sh
git commit -m "feat(g3): l'ecrivain pinne le dernier commit de l'API et ouvre la PR"
```

---

### Task 9 : Le job, l'amendement d'ADR-076, et la porte de lint

**Files:**
- Create: `ci/Jenkinsfile.api-promote-request`
- Modify: `adr/adr-076-gitops-api-lifecycle-repo-per-project.md`
- Modify: `Makefile`
- Test: `scripts/test-deploy-pin.sh`, `scripts/test-jenkinsfile-lint.sh`

**Interfaces:**
- Consumes: `scripts/api-promote-request.sh` (Tasks 7–8).
- Produces: le job Jenkins ; `make lint-ci` inclut `test-deploy-pin.sh`.

- [ ] **Step 1 : Écrire l'épreuve qui échoue**

Ajouter à `scripts/test-deploy-pin.sh` :

```bash
echo "⑲ le job existe, et la porte de preuve est branchée sur make lint-ci"
[ -f "$ROOT/ci/Jenkinsfile.api-promote-request" ] \
  && ok "Jenkinsfile.api-promote-request présent" \
  || bad "aucun job — le formulaire de promotion n'existe pas"
grep -q 'test-deploy-pin.sh' "$ROOT/Makefile" \
  && ok "test-deploy-pin.sh branché sur le Makefile (la porte tourne en CI)" \
  || bad "porte non branchée — elle ne tournera que si quelqu'un y pense"
grep -q 'apis/<name>.deploy' "$ROOT/adr/adr-076-gitops-api-lifecycle-repo-per-project.md" \
  && ok "ADR-076 amendé sur l'emplacement du marqueur" \
  || bad "ADR-076 dit toujours 'deploy.{env}.yaml' à la racine — la doc contredit le code"
```

- [ ] **Step 2 : Lancer le test pour vérifier qu'il échoue**

Run: `bash scripts/test-deploy-pin.sh`
Expected: FAIL — trois échecs sur ⑲

- [ ] **Step 3 : Écrire le Jenkinsfile**

Créer `ci/Jenkinsfile.api-promote-request` :

```groovy
// Jenkinsfile.api-promote-request — formulaire « promouvoir une API » (G3).
// Ouvre une PR portant apis/<name>.deploy.<TO_ENV>.yaml sur le dépôt d'ÉQUIPE.
// NE DÉPLOIE RIEN : la décision est le merge de cette PR (ADR-081).
//
// ⚠ La liste TO_ENV est écrite À LA MAIN, et c'est documenté comme tel : un
// bloc `parameters {}` déclaratif est évalué à la POSE du job, hors workspace —
// il n'a aucun accès au clone governance, donc il ne peut pas dériver
// d'environments.yaml. Même limite que ci/Jenkinsfile.selfservice:34.
pipeline {
  agent any
  options { disableConcurrentBuilds() }
  parameters {
    string(name: 'TEAM',           defaultValue: '', description: 'Équipe propriétaire')
    string(name: 'API_NAME',       defaultValue: '', description: "Nom de l'API")
    choice(name: 'FROM_ENV',       choices: ['dev', 'rec', 'int', 'homol'], description: 'Palier source')
    choice(name: 'TO_ENV',         choices: ['rec', 'int', 'homol', 'prod'], description: "Palier d'arrivée")
    string(name: 'MESSAGE',        defaultValue: '', description: "Message d'audit (obligatoire)")
    string(name: 'CHANGE_REF',     defaultValue: '', description: 'Référence de changement ITSM (selon la porte)')
    string(name: 'PV_REF',         defaultValue: '', description: 'Référence de PV de recette (selon la porte)')
    string(name: 'ARCHIVE_SHA256', defaultValue: '', description: "sha256 de l'archive (sortie EXPORT_CONFIRMED) — requis hors dev")
  }
  stages {
    stage('Demande de promotion') {
      steps {
        // Les paramètres de build subissent EnvVars.resolve : withEnv est
        // obligatoire pour qu'ils arrivent intacts au script (fait mesuré,
        // cf. mémoire ci-jenkinsfile-refactor).
        withCredentials([string(credentialsId: 'gitea-ci-token', variable: 'GITEA_TOKEN')]) {
          withEnv([
            "TEAM=${params.TEAM}", "API_NAME=${params.API_NAME}",
            "FROM_ENV=${params.FROM_ENV}", "TO_ENV=${params.TO_ENV}",
            "MESSAGE=${params.MESSAGE}", "CHANGE_REF=${params.CHANGE_REF}",
            "PV_REF=${params.PV_REF}", "ARCHIVE_SHA256=${params.ARCHIVE_SHA256}",
            "PROMOTED_BY=${env.BUILD_USER_ID ?: 'ci'}",
          ]) {
            dir('poc-control-plane-federation') {
              sh 'bash scripts/api-promote-request.sh'
            }
          }
        }
      }
    }
  }
}
```

- [ ] **Step 4 : Amender ADR-076**

Dans `adr/adr-076-gitops-api-lifecycle-repo-per-project.md`, dans le bloc de l'arborescence du §1 (« Le repo projet = shard byte-compatible »), remplacer la ligne `deploy.{env}.yaml       # marqueurs desired-state pinnés — ÉCRITS par la promotion, pas par l'équipe` par :

```
apis/<name>.deploy.{env}.yaml   # marqueurs desired-state pinnés — ÉCRITS par la
                        #   promotion, jamais par l'équipe. AMENDÉ le 2026-08-26
                        #   (jalon G3) : ces marqueurs étaient dessinés à la
                        #   RACINE, ce qui supposait « un dépôt = une API ». Le
                        #   squelette réellement livré (clients/_example) porte
                        #   apis/ ET applications/ au pluriel : à la racine,
                        #   deux APIs du même dépôt se disputeraient le même
                        #   fichier. Le nom plat suit la famille en place
                        #   (.publish.yml, .promote.yml, .openapi.yaml).
```

- [ ] **Step 5 : Brancher la porte sur le Makefile**

Dans `Makefile`, la cible `lint-ci` annonce aujourd'hui trois étapes numérotées. Remplacer la recette entière par celle-ci — les numéros sont **renumérotés** (`[1/4]`…`[4/4]`), sinon la sortie annonce trois étapes et en joue quatre :

```make
lint-ci:
	@echo "== [1/4] compilation des Jenkinsfile"
	@ci/lint-jenkinsfiles.sh
	@echo "== [2/4] shellcheck des bibliothèques ci/lib"
	@command -v shellcheck >/dev/null || { echo "!! shellcheck absent — \`brew install shellcheck\`"; exit 2; }
	@shellcheck ci/lib/*.sh && echo "  ✓ ci/lib propre"
	@echo "== [3/4] épreuves de ci/lib/carto-secrets.sh"
	@ci/test-carto-secrets.sh
	@echo "== [4/4] épreuves du résolveur de pin (G3)"
	@bash scripts/test-deploy-pin.sh
```

Et mettre à jour le commentaire de tête du `Makefile` (ligne 8) :

```make
#                  shellcheck des bibliothèques, épreuves de carto-secrets et
#                  du résolveur de pin.
```

- [ ] **Step 6 : Lancer toutes les portes**

Run: `bash scripts/test-deploy-pin.sh && bash scripts/test-jenkinsfile-lint.sh && bash scripts/test-env-chain.sh`
Expected: `45 PASS / 0 FAIL` ; le lint Jenkinsfile passe à **13/13** (un Jenkinsfile de plus à compiler) ; `test-env-chain.sh` reste 4/4.

- [ ] **Step 7 : Commit**

```bash
git add ci/Jenkinsfile.api-promote-request adr/adr-076-gitops-api-lifecycle-repo-per-project.md Makefile scripts/test-deploy-pin.sh
git commit -m "feat(g3): job de promotion, amendement ADR-076, porte branchee sur lint-ci"
```

---

### Task 10 : Brancher le résolveur sur le chemin vivant — la preuve de câblage

**Files:**
- Modify: `scripts/team-publish.sh:341-345`
- Test: `scripts/test-deploy-pin.sh`

**Interfaces:**
- Consumes: `resolve_deploy_pin` (Tasks 1–3).
- Produces: `team-publish.sh` passe `DEPLOY_PIN_PUBLISH` / `DEPLOY_PIN_CONTRACT` au rôle, jamais les chemins bruts du clone.

**Pourquoi cette tâche existe.** Sans elle, `scripts/lib/deploy-pin.sh` n'est appelé par **rien** — exactement le reproche que le GOAL fait à `labctl promote` (« appelé par : *rien du tout* — aucun pipeline, aucun script », G8). Un résolveur mort ne prouve rien et pourrit en silence. Le brancher sur le chemin **dev** existant est **sans changement de comportement** (en env d'authoring le résolveur matérialise HEAD, c'est-à-dire ce que `team-publish.sh` passait déjà) tout en le mettant sur un chemin réellement exercé à chaque publication. **Aucun verrou n'est levé** : `ENVN` reste figé à `dev`, c'est G4 qui le déverrouille.

- [ ] **Step 1 : Écrire l'épreuve qui échoue**

Ajouter à `scripts/test-deploy-pin.sh` :

```bash
echo "⑳ le résolveur est BRANCHÉ — pas du code mort"
TP="$ROOT/scripts/team-publish.sh"
grep -q 'lib/deploy-pin.sh' "$TP" \
  && ok "team-publish.sh source le résolveur" \
  || bad "résolveur appelé par RIEN — code mort, comme labctl promote (reproche G8)"
grep -q 'apim_ss_manifest="\$DEPLOY_PIN_PUBLISH"' "$TP" \
  && ok "le manifeste passé au rôle est le RÉSOLU, pas le chemin brut du clone" \
  || bad "team-publish.sh passe encore \$PUB_PATH — le résolveur ne sert à rien"
grep -q 'apim_ss_contract_pin="\$DEPLOY_PIN_CONTRACT"' "$TP" \
  && ok "le contrat épinglé est le RÉSOLU" \
  || bad "contrat non issu du résolveur"
# Le verrou dev-only appartient à G4 : cette tâche ne doit pas y toucher.
grep -q 'ENVN="\${ENVN:-dev}"' "$TP" \
  && ok "le verrou dev-only est INTACT (il appartient à G4)" \
  || bad "le verrou dev-only a bougé — G3 ne doit pas livrer la moitié de G4"
```

- [ ] **Step 2 : Lancer le test pour vérifier qu'il échoue**

Run: `bash scripts/test-deploy-pin.sh`
Expected: FAIL — `résolveur appelé par RIEN`, plus deux échecs de câblage. La 4e épreuve passe déjà (le verrou est intact).

- [ ] **Step 3 : Brancher le résolveur**

Dans `scripts/team-publish.sh`, ajouter le source juste après le `cd "$(dirname "$0")/.." || exit 1` de la tête de script :

```bash
# shellcheck source=lib/deploy-pin.sh
. scripts/lib/deploy-pin.sh
```

Puis, **juste avant** le bloc `( ansible-playbook -i ansible/inventory.lab.ini ansible/publish-api.yml` (ligne 341), insérer :

```bash
# ── 5bis. RÉSOLUTION DE LA RÉFÉRENCE DE DÉPLOIEMENT (jalon G3) ───────────────
# En env d'AUTHORING (dev), le résolveur matérialise HEAD : le comportement est
# celui d'avant, à l'octet près. Il est branché ICI, sur le chemin vivant, pour
# deux raisons : (1) un résolveur que personne n'appelle est du code mort qui
# pourrit en silence — c'est le reproche fait à `labctl promote` (GOAL G8) ;
# (2) le jour où G4 ouvre les paliers supérieurs, ce chemin PINNE déjà, sans
# nouvelle plomberie à écrire sous pression.
# Le clone est DÉJÀ positionné au SHA du merge (§4) — le résolveur lit donc
# l'état revu, pas une branche courante.
resolve_deploy_pin "$TMP/team" "$API_NAME" "$ENVN" "$TMP/resolved" \
  || fail "PIN_NON_RESOLU : la référence de déploiement de ${API_NAME} en ${ENVN} n'a pas pu être résolue (voir le refus nommé ci-dessus)"
```

Enfin, remplacer les deux extra-vars de l'invocation :

```bash
( ansible-playbook -i ansible/inventory.lab.ini ansible/publish-api.yml \
    -e apim_ss_manifest="$DEPLOY_PIN_PUBLISH" -e apim_ss_team="$TEAM" \
    -e apim_ss_api_base="$APIM_API_BASE" -e apim_ss_env="$ENVN" \
    -e apim_ss_contract_pin="$DEPLOY_PIN_CONTRACT" \
) >"$TMP/pub.log" 2>&1
```

> Les gardes de `team-publish.sh` qui inspectent `$PUB_PATH` (cohérence branche↔manifeste, liste blanche du champ `contract`) **restent sur le clone** et ne changent pas : elles valident l'état mergé. Le résolveur ne remplace pas ces gardes, il décide seulement **quels octets partent au moteur**.

- [ ] **Step 4 : Lancer les tests**

Run: `bash scripts/test-deploy-pin.sh && bash scripts/test-team-publish-wiring.sh && shellcheck scripts/team-publish.sh`
Expected: `49 PASS / 0 FAIL` pour le premier ; `test-team-publish-wiring.sh` **inchangé** (aucune régression sur les 20+ épreuves existantes, dont le test 17 sur `apim_ss_contract_pin`) ; shellcheck propre.

> Si `test-team-publish-wiring.sh` rougit sur le test 17, c'est attendu et il faut le **mettre à jour** : il vérifie littéralement `-e apim_ss_contract_pin="$SPEC_PATH"`. Remplacer cette chaîne par `-e apim_ss_contract_pin="$DEPLOY_PIN_CONTRACT"` dans l'assertion, et ajouter une assertion que `$SPEC_PATH` sert toujours à la garde de liste blanche. **Ne pas supprimer l'épreuve** : c'est elle qui empêche le manifeste de redevenir maître du contrat.

- [ ] **Step 5 : Commit**

```bash
git add scripts/team-publish.sh scripts/test-deploy-pin.sh scripts/test-team-publish-wiring.sh
git commit -m "feat(g3): brancher le resolveur sur team-publish — plus de code mort"
```

---

## Ce que ce plan ne fait PAS

À dire au moment de rendre compte, pas à découvrir :

- **Il ne lève pas le verrou dev-only** (`scripts/team-apply.sh:53` `ENV_NOT_OPEN`, `scripts/team-publish.sh:75` `ENVN="${ENVN:-dev}"`). C'est le jalon **G4**, qui le remplace par la rétention de credential. Le lever ici livrerait la moitié de G4 sans son remplacement.
- **Il ne branche pas le verbe archive sur les sauts rec et au-delà.** C'est **G5**. Le résolveur produit les chemins ; aucun pipeline ne les consomme encore en dehors du chemin dev existant.
- **Il ne transporte pas les octets de l'archive d'un palier à l'autre.** Pas de dépôt d'artefacts — c'est **G5**. Le digest lie l'approuvé au déployé ; il ne déplace rien.
- **Il n'ajoute pas `DeployerGroup`** (« qui déploie » à côté de « qui approuve »). C'est **G2**.
- **La porte G3 telle qu'écrite dans le GOAL** (« l'apply *en rec* projette ce contrat ») n'est donc **pas exerçable E2E** à l'issue de ce plan. Ce qui est prouvé : le résolveur, ses refus, le digest bout à bout, l'écrivain — 49/49 hors ligne sur dépôt Git réel, contre-épreuve par sabotage comprise.
