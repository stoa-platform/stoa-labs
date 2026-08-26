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
if resolve_deploy_pin "$REPO" accounts-read rec "$WORK" main "$REPO/dist/a.zip" 2>"$TMP/e1"; then
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

echo "② le pin couvre AUSSI promote.yml (pas seulement le contrat)"
REPO="$TMP/team2"; make_team_repo "$REPO"
marker "$REPO" rec "$C1" "1.0.0" "$(sha_of "$REPO/dist/a.zip")"
WORK="$TMP/w2"; mkdir -p "$WORK"
if resolve_deploy_pin "$REPO" accounts-read rec "$WORK" main "$REPO/dist/a.zip" 2>"$TMP/e2"; then
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

echo "⑥ PIN_NON_ANCETRE — commit inexistant (le refus REELLEMENT atteint)"
# ⚠ LE TITRE DE CETTE ÉPREUVE ANNONÇAIT « PIN_UNREADABLE », ET C'ÉTAIT FAUX :
# un commit inexistant échoue d'abord sur `merge-base --is-ancestor`, donc bien
# avant le `git show`. L'alternation `PIN_NON_ANCETRE|PIN_UNREADABLE` rendait la
# confusion invisible — et laissait PIN_UNREADABLE sans AUCUNE couverture
# (mesuré en revue : renommer le jeton dans deploy-pin.sh ne faisait rougir
# personne). On nomme donc ici le refus réellement atteint ; PIN_UNREADABLE a
# désormais son épreuve propre, ⑥ter.
REPO="$TMP/team6"; make_team_repo "$REPO"
marker "$REPO" rec "0123456789abcdef0123456789abcdef01234567" "1.0.0" "deadbeef"
WORK="$TMP/w6"
resolve_deploy_pin "$REPO" accounts-read rec "$WORK" main 2>"$TMP/e6" \
  && bad "commit inexistant ACCEPTÉ" \
  || { grep -q PIN_NON_ANCETRE "$TMP/e6" && ok "PIN_NON_ANCETRE sur commit inexistant" || bad "refusé sans nommer PIN_NON_ANCETRE : $(cat "$TMP/e6")"; }

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

echo "⑥ter PIN_UNREADABLE — un ancetre de main ou le manifeste n'existait pas encore"
# LE SEUL CHEMIN QUI ATTEINT CE REFUS. Il faut un pin qui PASSE l'ancetrete et
# ECHOUE au `git show` : un commit anterieur a la creation de l'API. Ce n'est
# pas un cas de laboratoire — un marqueur pointant un commit d'avant
# l'onboarding de l'API produit exactement cet etat, et le resolveur doit alors
# refuser plutot que materialiser un manifeste vide.
REPO="$TMP/team6t"; mkdir -p "$REPO/apis"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email ci@stoa.lab
git -C "$REPO" config user.name ci
printf 'squelette d equipe\n' > "$REPO/README.md"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "C0 squelette — aucune API"
C0=$(git -C "$REPO" rev-parse HEAD)
_write_api "$REPO" 1.0.0
git -C "$REPO" add -A && git -C "$REPO" commit -qm "C1 accounts-read 1.0.0"
# ⚠ LA FABRIQUE S'ASSERTE. Sans cette ligne, un C0 qui cesserait d'etre ancetre
# de main (fabrique remaniee, branche orpheline) ferait retomber l'epreuve sur
# PIN_NON_ANCETRE — elle passerait au rouge sans dire pourquoi, ou pire,
# passerait au vert sur un refus voisin si l'assertion tolerait l'alternation.
# C'est exactement le defaut que ⑥ portait.
git -C "$REPO" merge-base --is-ancestor "$C0" main \
  && ok "fabrique : C0 EST ancetre de main — la garde d'ancetrete passe, le refus vient donc du git show" \
  || bad "fabrique invalide : C0 n'est pas ancetre de main — l'epreuve n'atteindrait pas PIN_UNREADABLE"
marker "$REPO" rec "$C0" "1.0.0" "$(sha_of "$REPO/dist/a.zip")"
WORK="$TMP/w6t"
resolve_deploy_pin "$REPO" accounts-read rec "$WORK" main "$REPO/dist/a.zip" 2>"$TMP/e6t" \
  && bad "pin sur un commit SANS manifeste ACCEPTE — le resolveur a materialise un fichier vide" \
  || { grep -q PIN_UNREADABLE "$TMP/e6t" \
       && ok "PIN_UNREADABLE — nomme, et pas un refus voisin" \
       || bad "refuse sans nommer PIN_UNREADABLE (refus voisin ?) : $(cat "$TMP/e6t")"; }

echo "⑦ PIN_VERSION_MISMATCH — le marqueur ment sur la version"
REPO="$TMP/team7"; make_team_repo "$REPO"
marker "$REPO" rec "$C1" "7.7.7" "$(sha_of "$REPO/dist/a.zip")"
WORK="$TMP/w7"
resolve_deploy_pin "$REPO" accounts-read rec "$WORK" main 2>"$TMP/e7" \
  && bad "marqueur 7.7.7 vs manifeste 1.0.0 ACCEPTÉ" \
  || { grep -q PIN_VERSION_MISMATCH "$TMP/e7" && ok "PIN_VERSION_MISMATCH" || bad "refusé sans nommer PIN_VERSION_MISMATCH : $(cat "$TMP/e7")"; }

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
    # Séparateur \x1f (PAS '|') : when:/that: portent eux-mêmes des filtres
    # Jinja (`| default('')`) — un split sur '|' tronquerait le premier champ
    # au premier filtre rencontré (mesuré : "(apim_ss_env " au lieu du when
    # complet).
    US=$'\x1f'
    W_REQ="${IMPV%%$US*}"; IMPV="${IMPV#*$US}"
    T_CMP="${IMPV%%$US*}"; IMPV="${IMPV#*$US}"
    H_ABS="${IMPV%%$US*}"; O_ABS="${IMPV#*$US}"
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

  # ⚠ PAS DE PIPE DIRECT VERS grep -q ICI. Sous `pipefail` (actif en tête de
  # ce fichier), le statut d'un pipeline est le DERNIER exit NON NUL en
  # partant de la droite — pas forcément celui de la commande la plus à
  # droite. `run_w` sort volontairement en erreur (1) sur chaque garde
  # refusée (fail()) ; en pipe direct, ce 1 remonte et écrase le succès de
  # `grep -q`, qui pourtant a bien trouvé le refus attendu. Mesuré : les
  # quatre assertions ci-dessous restaient au rouge malgré un message
  # correct. On capture donc la sortie dans un fichier puis on grep CE
  # fichier — même discipline que le reste de ce script pour
  # resolve_deploy_pin (épreuves ①bis, ③, ④, ⑤…).
  run_w dev prod "" "" "$(printf 'a%.0s' $(seq 64))" > "$TMP/w16"
  grep -q CHAINE_INVALIDE "$TMP/w16" \
    && ok "CHAINE_INVALIDE — un saut dev→prod n'est pas exprimable" \
    || bad "saut de palier ACCEPTÉ"

  run_w int homol "" "" "$(printf 'a%.0s' $(seq 64))" > "$TMP/w16"
  grep -q GATE_REFS_REQUIRED "$TMP/w16" \
    && ok "GATE_REFS_REQUIRED — la porte homol exige un pv_ref, refusé À LA DEMANDE" \
    || bad "promotion vers homol sans pv_ref ACCEPTÉE"

  run_w dev rec "" "" "" > "$TMP/w16"
  grep -q DIGEST_ABSENT "$TMP/w16" \
    && ok "DIGEST_ABSENT — pas de promotion hors authoring sans digest" \
    || bad "promotion hors dev sans digest ACCEPTÉE"

  run_w dev rec "" "" "pas-un-digest" > "$TMP/w16"
  grep -q DIGEST_MALFORMED "$TMP/w16" \
    && ok "DIGEST_MALFORMED (longueur)" \
    || bad "digest de forme invalide ACCEPTÉ"

  # ⚠ « DEUX VERROUS, PAS UN » — et il faut donc DEUX épreuves. L'assertion
  # ci-dessus est interceptée par le verrou de LONGUEUR (13 caractères) et
  # laisse le verrou de CLASSE DE CARACTÈRES sans aucune couverture : mesuré
  # en revue, neutraliser ce dernier laissait les quatre assertions VERTES
  # alors que le mutant acceptait 64 caractères non hexadécimaux comme digest.
  run_w dev rec "" "" "$(printf 'z%.0s' $(seq 64))" > "$TMP/w16"
  grep -q DIGEST_MALFORMED "$TMP/w16" \
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
  # Même discipline anti-pipefail que run_w ci-dessus : capture fichier, grep
  # séparé.
  run_wc homol prod "" "" "$(printf 'a%.0s' $(seq 64))" > "$TMP/w16"
  grep -q GATE_REFS_REQUIRED "$TMP/w16" \
    && ok "itsmCheck SEUL implique change_ref — refus sur une porte sans requireChangeRef" \
    || bad "implication itsmCheck => requireChangeRef non appliquée (porte itsmCheck seul)"

  # ⚠ LE CHEMIN NOMINAL. Une suite dont toutes les épreuves sont des REFUS ne
  # teste jamais l'acceptation : une garde trop zélée — la boucle de chaîne
  # cassée de sorte que NEXT soit toujours vide, une validation de nom durcie à
  # l'excès — passerait au vert partout. Leçon déjà payée sur ce dépôt.
  run_w homol prod "C-1" "PV-1" "$(printf 'a%.0s' $(seq 64))" > "$TMP/w16"
  grep -q GARDES_OK "$TMP/w16" \
    && ok "chemin NOMINAL : une promotion complète et légitime est ACCEPTÉE" \
    || bad "une promotion pourtant conforme est refusée — garde trop zélée"
fi

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
grep -q SOURCE_NON_DEPLOYEE "$ROOT/scripts/lib/deploy-pin.sh" \
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
# ⚠ Motif mis à jour avec le préfixe de sous-répertoire (cf. ⑱bis, deuxième
# piège de LECTURE_PROVIDERS) : sans lui, cette assertion redevenait fausse
# malgré une garde correcte — un cas de désaccord entre deux greps du même
# fichier, l'un patché et l'autre laissé sur l'ancien chemin.
grep -q 'repos/${GIT_REPO}/raw/poc-control-plane-federation/ansible/providers' "$ROOT/scripts/api-promote-request.sh" \
  && ok "providers lu sur Gitea main, pas sur le worktree local" \
  || bad "providers lu localement — un worktree en retard déciderait de l'appartenance"

echo "⑱bis un CHANGE_REF ne peut pas fabriquer une cle du marqueur"
# ⚠ MÊME PIÈGE PIPEFAIL QUE ⑯, UN CRAN PLUS LOIN. Un `run_w ... | grep -q ...`
# EN PIPE DIRECT serait retombé exactement dans le trou documenté plus haut :
# `run_w` sort en erreur (1, via fail()) sur ce refus attendu, et sous
# `pipefail` c'est CE 1 qui gagne même quand `grep -q` trouve son motif — le
# test resterait rouge à jamais, y compris avec la garde correctement posée.
# Même discipline que ⑯ : capture fichier, grep séparé.
run_w dev rec 'x"
commit: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
zz: "y' "" "$(printf 'a%.0s' $(seq 64))" > "$TMP/w18bis"
grep -q REF_INVALIDE "$TMP/w18bis" \
  && ok "REF_INVALIDE — une reference qui tente d'ouvrir une ligne YAML est refusee" \
  || bad "un CHANGE_REF multiligne ACCEPTE — le demandeur choisirait le pin (derniere cle gagne)"

# ⚠ ANCRER SUR LE CODE, PAS SUR LE TEXTE. Les trois correctifs ci-dessous sont
# expliques par de longs commentaires qui CITENT le motif recherche — un
# `grep` nu sur le fichier entier est donc satisfait par l'EXPLICATION du
# correctif meme apres que le correctif a disparu. Mesure en re-revue sur
# l'assertion `fail-with-body` : elle passait au vert sur le seul commentaire,
# le correctif pouvait etre inverse sans faire rougir personne. C'est le
# troisieme vert vacant de cette campagne. On retire donc les commentaires
# avant de chercher — le grep porte alors sur le CODE, pas sur sa prose.
WCODE="$TMP/apr-sans-commentaires.sh"
sed 's/[[:space:]]*#.*$//' "$ROOT/scripts/api-promote-request.sh" > "$WCODE"
grep -q 'yaml.safe_dump' "$WCODE" \
  && ok "le marqueur est SERIALISE, pas formate — une valeur ne peut pas fabriquer de cle" \
  || bad "marqueur produit par %-formatage : une valeur peut ouvrir une nouvelle ligne YAML"
grep -q -- '--fail-with-body' "$WCODE" \
  && ok "curl echoue vraiment sur un HTTP non-2xx (sinon LECTURE_PROVIDERS est du code mort)" \
  || bad "curl -s rend 0 sur un 404 : le refus emis serait un mensonge"
grep -q 'raw/poc-control-plane-federation/ansible/providers' "$WCODE" \
  && ok "le chemin providers porte le prefixe du sous-repertoire" \
  || bad "chemin providers sans prefixe — 404 a chaque execution hors DRY_RUN"

# PV_REF passe par la meme garde que CHANGE_REF ; l'eprouver separement,
# sinon la moitie du verrou de reference n'est tenue par rien. `homol` est le
# premier palier de la chaine a exiger requirePVRef (int → homol) — CHANGE_REF
# reste vide, homol ne l'exige pas. Meme discipline anti-pipefail que
# l'epreuve juste au-dessus : capture fichier, grep separe.
run_w int homol "" 'PV"
commit: cccccccccccccccccccccccccccccccccccccccc' "$(printf 'a%.0s' $(seq 64))" > "$TMP/w18ter"
grep -q REF_INVALIDE "$TMP/w18ter" \
  && ok "REF_INVALIDE couvre aussi PV_REF" \
  || bad "PV_REF non contraint — la moitie du verrou de reference n'est tenue par rien"

echo "⑲ le job existe, et la porte de preuve est branchée sur make lint-ci"
[ -f "$ROOT/ci/Jenkinsfile.api-promote-request" ] \
  && ok "Jenkinsfile.api-promote-request présent" \
  || bad "aucun job — le formulaire de promotion n'existe pas"
grep -q 'test-deploy-pin.sh' "$ROOT/Makefile" \
  && ok "test-deploy-pin.sh branché sur le Makefile (la porte tourne en CI)" \
  || bad "porte non branchée — elle ne tournera que si quelqu'un y pense"
# ⚠ AUCUNE ÉPREUVE NE REGARDAIT LE NOM DU CREDENTIAL, et c'est ainsi qu'un
# `gitea-ci-token` inexistant est passé sous 50 assertions vertes. Un ID
# inconnu fait échouer le build sur CredentialNotFoundException — un job qui
# ne peut pas tourner. On exige donc que tout `credentialsId` littéral de ce
# Jenkinsfile soit un ID déjà utilisé ailleurs dans le dépôt.
JPR="$ROOT/ci/Jenkinsfile.api-promote-request"
# ⚠ DEUX TROUS MESURÉS DANS LA PREMIÈRE VERSION DE CETTE ASSERTION, ET ILS LA
# RENDAIENT INUTILE :
#  (A) AUTO-RÉFÉRENCE — elle cherchait l'ID dans tout le dépôt, Y COMPRIS le
#      fichier sous test : un littéral inconnu se trouvait donc LUI-MÊME et
#      l'assertion passait au vert. Le fichier est désormais EXCLU de son
#      propre périmètre de recherche.
#  (B) FORME VARIABLE — elle ne lisait que les littéraux `credentialsId: '…'`.
#      Or l'ID vit maintenant dans le DÉFAUT du bloc environment{} : un nom
#      inventé posé LÀ plutôt qu'ici serait passé sans un mot.
# Une garde de non-régression qui ne peut pas rougir n'est pas une garde.
CRED_IDS=$( { grep -oE "credentialsId: *'[^']+'" "$JPR"
              grep -oE "GITEA_CREDENTIALS_ID[^']*'[^']+'" "$JPR"; } \
            | sed "s/.*'\([^']*\)'.*/\1/" | grep -v '^$' | sort -u)
if [ -z "$CRED_IDS" ]; then
  bad "aucun ID de credential trouvé dans le job — ni littéral, ni défaut du bloc environment{} : l'assertion ne mesure rien"
else
  CRED_ORPHELIN=""
  for c in $CRED_IDS; do
    grep -rqF "$c" "$ROOT/scripts" "$ROOT/ci" \
      --include='*.sh' --include='Jenkinsfile*' \
      --exclude='Jenkinsfile.api-promote-request' 2>/dev/null \
      || CRED_ORPHELIN="$CRED_ORPHELIN $c"
  done
  [ -z "$CRED_ORPHELIN" ] && ok "tout ID de credential du job (littéral ET défaut environment{}) existe AILLEURS dans le dépôt" \
                          || bad "credential(s) inconnu(s) du dépôt :$CRED_ORPHELIN — le build échouerait sur CredentialNotFoundException"
fi
grep -q 'GITEA_CREDENTIALS_ID' "$JPR" \
  && ok "l'ID de credential est un point de bascule client (motif des Jenkinsfile freres)" \
  || bad "ID de credential en dur — un client au nom different devrait forker le Jenkinsfile"
grep -q 'apis/<name>.deploy' "$ROOT/adr/adr-076-gitops-api-lifecycle-repo-per-project.md" \
  && ok "ADR-076 amendé sur l'emplacement du marqueur" \
  || bad "ADR-076 dit toujours 'deploy.{env}.yaml' à la racine — la doc contredit le code"

echo "⑳ le résolveur est BRANCHÉ — pas du code mort"
TP="$ROOT/scripts/team-publish.sh"
# ⚠ CINQUIÈME VERT VACANT DE CETTE CAMPAGNE, ET LE PLUS IRONIQUE : l'assertion
# censée prouver que le résolveur n'est PAS du code mort était satisfaite par le
# COMMENTAIRE qui l'annonce. `team-publish.sh` porte deux fois la chaîne
# « lib/deploy-pin.sh » : la directive `# shellcheck source=lib/deploy-pin.sh`
# ET le `.` qui source réellement. Mutation-testé : retirer le source en
# gardant la directive laissait l'assertion VERTE.
#
# Et surtout : SOURCER N'EST PAS APPELER. Supprimer la ligne
# `resolve_deploy_pin …` laissait les QUATRE assertions vertes. Un
# team-publish.sh sans aucun appel serait passé entièrement au vert hors ligne.
# On ancre donc sur les lignes de CODE, et on exige l'APPEL, et son ORDRE.
grep -qE '^\. scripts/lib/deploy-pin\.sh( \|\||$)' "$TP" \
  && ok "team-publish.sh source réellement le résolveur (ligne de code, pas la directive shellcheck)" \
  || bad "le résolveur n'est pas sourcé — seule la directive shellcheck le mentionne"
grep -qE '^resolve_deploy_pin "\$TMP/team"' "$TP" \
  && ok "le résolveur est réellement APPELÉ — sourcer n'est pas appeler" \
  || bad "résolveur sourcé mais jamais appelé : code mort, exactement le reproche fait a labctl promote (G8)"
# L'ORDRE : la résolution doit précéder le play, sinon le refus arrive trop tard.
L_RESOLVE=$(grep -nE '^resolve_deploy_pin "\$TMP/team"' "$TP" | head -1 | cut -d: -f1)
L_PLAY=$(grep -nE '^\( ansible-playbook' "$TP" | head -1 | cut -d: -f1)
{ [ -n "$L_RESOLVE" ] && [ -n "$L_PLAY" ] && [ "$L_RESOLVE" -lt "$L_PLAY" ]; } \
  && ok "la résolution précède le play (refus mécaniquement antérieur)" \
  || bad "la résolution ne précède pas le play (resolve=$L_RESOLVE, play=$L_PLAY) — un refus arriverait après coup"
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

echo "㉑ LE CHAÎNAGE — un saut promeut ce que le palier SOURCE exécute, pas le dernier main"
# ⚠ C'EST L'ÉPREUVE QUI MANQUAIT, et son absence a laissé passer le défaut le
# plus grave du jalon. ⑰ vérifiait seulement qu'une API SŒUR ne fait pas bouger
# le pin — jamais que le pin égale ce que le palier source sert. Le GOAL, lui,
# l'exige mot pour mot : « chaque palier recevant exactement l'archive
# approuvée et pas "le dernier main" ».
REPO="$TMP/team21"; make_team_repo "$REPO"
# C1 = accounts-read 1.0.0 (ce que rec SERT) ; main est déjà à 2.0.0 (C2).
# ⚠ LE DIGEST DOIT ÊTRE CELUI DES OCTETS DE v1. `dist/a.zip` sur le disque porte
# ceux de v2 (make_team_repo l'a réécrit au second commit) : le hacher ici
# donnerait une fixture qui ANNONCE v1 et HACHE v2. L'assertion resterait
# valide — elle mesure la propagation d'une valeur — mais le prochain lecteur
# qui voudra la durcir tomberait dedans.
SHA_A="$(printf 'archive-bytes-1.0.0' | shasum -a 256 | cut -d' ' -f1)"
marker "$REPO" rec "$C1" "1.0.0" "$SHA_A"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "marqueur rec"

if resolve_promotion_pin "$REPO" accounts-read rec 2>"$TMP/e21"; then
  [ "$DEPLOY_PROMO_PIN" = "$C1" ] \
    && ok "rec -> int retient le pin du marqueur REC ($C1), pas le dernier main" \
    || bad "rec -> int a retenu '$DEPLOY_PROMO_PIN' au lieu de $C1 — un etat que rec n'a jamais servi"
  [ "$DEPLOY_PROMO_VERSION" = "1.0.0" ] \
    && ok "la version est lue AU COMMIT RETENU (1.0.0), pas sur main (2.0.0)" \
    || bad "version '$DEPLOY_PROMO_VERSION' — lue sur main au lieu du commit pinne"
  [ "$DEPLOY_PROMO_SHA256" = "$SHA_A" ] \
    && ok "le digest VOYAGE avec le pin — build once, deploy many devient vrai" \
    || bad "digest '$DEPLOY_PROMO_SHA256' != celui du marqueur source"
else
  bad "chainage refuse a tort : $(cat "$TMP/e21")"
fi

echo "㉑bis dev -> rec suit le dernier main — dev n'a pas de marqueur, par conception"
REPO="$TMP/team21b"; make_team_repo "$REPO"
if resolve_promotion_pin "$REPO" accounts-read dev 2>"$TMP/e21b"; then
  [ "$DEPLOY_PROMO_PIN" = "$C2" ] \
    && ok "dev -> rec pinne le dernier commit de main (env d'authoring)" \
    || bad "dev -> rec a retenu '$DEPLOY_PROMO_PIN' au lieu de $C2"
  [ -z "$DEPLOY_PROMO_SHA256" ] \
    && ok "aucun digest herite depuis dev — le demandeur le fournit (EXPORT_CONFIRMED)" \
    || bad "un digest a ete herite alors que dev n'a pas de marqueur"
else
  bad "dev -> rec refuse a tort : $(cat "$TMP/e21b")"
fi

echo "㉑ter SOURCE_DIGEST_ABSENT — un marqueur source sans digest ne peut pas faire voyager d'octets"
REPO="$TMP/team21c"; make_team_repo "$REPO"
marker "$REPO" rec "$C1" "1.0.0" ""
git -C "$REPO" add -A && git -C "$REPO" commit -qm "marqueur rec sans digest"
resolve_promotion_pin "$REPO" accounts-read rec 2>"$TMP/e21c" \
  && bad "marqueur source SANS digest accepte — les octets ne voyagent plus" \
  || { grep -q SOURCE_DIGEST_ABSENT "$TMP/e21c" && ok "SOURCE_DIGEST_ABSENT" || bad "refuse sans nommer SOURCE_DIGEST_ABSENT : $(cat "$TMP/e21c")"; }

echo "㉑quater SOURCE_PIN_MALFORMED — on ne retombe JAMAIS sur main pour reparer un pin casse"
REPO="$TMP/team21d"; make_team_repo "$REPO"
marker "$REPO" rec "pas-un-sha" "1.0.0" "$(sha_of "$REPO/dist/a.zip")"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "marqueur rec casse"
resolve_promotion_pin "$REPO" accounts-read rec 2>"$TMP/e21d" \
  && bad "pin source casse ACCEPTE — s'il retombait sur main, le defaut serait rouvert" \
  || { grep -q SOURCE_PIN_MALFORMED "$TMP/e21d" && ok "SOURCE_PIN_MALFORMED" || bad "refuse sans nommer SOURCE_PIN_MALFORMED : $(cat "$TMP/e21d")"; }

echo "㉑quinquies enabled: false — un palier source ETEINT ne promeut rien"
REPO="$TMP/team21e"; make_team_repo "$REPO"
marker "$REPO" rec "$C1" "1.0.0" "$(sha_of "$REPO/dist/a.zip")"
sed -i.bak 's/^enabled: true/enabled: false/' "$REPO/apis/accounts-read.deploy.rec.yaml"
rm -f "$REPO/apis/"*.bak
git -C "$REPO" add -A && git -C "$REPO" commit -qm "rec eteint"
resolve_promotion_pin "$REPO" accounts-read rec 2>"$TMP/e21e" \
  && bad "un palier source ETEINT a promu — on promeut ce qui ne tourne pas" \
  || { grep -q SOURCE_NON_DEPLOYEE "$TMP/e21e" && ok "SOURCE_NON_DEPLOYEE sur enabled: false" || bad "refuse sans nommer SOURCE_NON_DEPLOYEE : $(cat "$TMP/e21e")"; }

echo "㉑sexies marqueur source ABSENT — surtout pas de repli sur main"
# ⚠ C'est le defaut arbitre, rouvert par la porte de service : si l'absence de
# marqueur retombait sur `git log -1 main`, un saut rec -> int repartirait du
# dernier main sans que rien ne le dise.
REPO="$TMP/team21f"; make_team_repo "$REPO"
resolve_promotion_pin "$REPO" accounts-read rec 2>"$TMP/e21f" \
  && bad "marqueur source ABSENT accepte — repli implicite sur main, le defaut est rouvert" \
  || { grep -q SOURCE_NON_DEPLOYEE "$TMP/e21f" && ok "SOURCE_NON_DEPLOYEE sur marqueur absent" || bad "refuse sans nommer SOURCE_NON_DEPLOYEE : $(cat "$TMP/e21f")"; }

echo "㉒ la reconciliation du digest — les trois cas, hors ligne"
D_A="$(printf 'a%.0s' $(seq 64))"; D_B="$(printf 'b%.0s' $(seq 64))"
R=$(reconcile_promotion_digest "$D_A" "" 2>/dev/null) \
  && [ "$R" = "$D_A" ] && ok "depuis l'env d'authoring : le formulaire fait foi" \
  || bad "digest du formulaire non retenu depuis l'authoring (rendu '$R')"
R=$(reconcile_promotion_digest "$D_A" "$D_A" 2>/dev/null) \
  && [ "$R" = "$D_A" ] && ok "recopie exacte : accepte" \
  || bad "une recopie exacte a ete refusee (rendu '$R')"
R=$(reconcile_promotion_digest "" "$D_A" 2>/dev/null) \
  && [ "$R" = "$D_A" ] && ok "formulaire vide : l'herite est retenu" \
  || bad "l'herite n'a pas ete retenu sur formulaire vide (rendu '$R')"
reconcile_promotion_digest "$D_B" "$D_A" >/dev/null 2>"$TMP/e22" \
  && bad "un digest CONTREDISANT le palier source a ete accepte — les octets seraient substitues" \
  || { grep -q DIGEST_CONTREDIT_SOURCE "$TMP/e22" && ok "DIGEST_CONTREDIT_SOURCE" || bad "refuse sans nommer DIGEST_CONTREDIT_SOURCE : $(cat "$TMP/e22")"; }

echo "㉓ le CABLAGE de l'arbitrage — sourcer et definir ne suffit pas, il faut APPELER"
# ⚠ Mesure en revue : retirer l'appel a resolve_promotion_pin et retablir
# `git log -1 main` laissait les TROIS portes vertes. La fonction devenait du
# code mort et le defaut arbitre revenait sans qu'aucun voyant ne s'allume.
# Meme lecon qu'a ⑳, appliquee au jumeau — et ancree sur le CODE decommente,
# sinon le grep est satisfait par la prose qui cite le motif.
APR="$ROOT/scripts/api-promote-request.sh"
ACODE="$TMP/apr-code-only.sh"
sed 's/[[:space:]]*#.*$//' "$APR" > "$ACODE"
grep -qE '^resolve_promotion_pin "' "$ACODE" \
  && ok "resolve_promotion_pin est reellement APPELE par l'ecrivain" \
  || bad "l'arbitrage n'est branche sur rien : la fonction existe et personne ne l'appelle"
grep -q 'reconcile_promotion_digest' "$ACODE" \
  && ok "la reconciliation du digest est reellement APPELEE" \
  || bad "DIGEST_CONTREDIT_SOURCE ne peut pas se declencher : la garde n'est pas cablee"
grep -qE 'log -1 --format=%H' "$ACODE" \
  && bad "l'ecrivain recalcule le pin depuis main — c'est exactement le defaut arbitre" \
  || ok "l'ecrivain ne recalcule PAS le pin depuis main (il delegue a la bibliotheque)"

echo "㉔ SOURCE_VERSION_MISMATCH — un marqueur source incoherent ne se propage pas"
# Le jumeau a PIN_VERSION_MISMATCH « pour attraper un marqueur edite a la main
# apres coup ». Le meme risque existe au chainage : sans cette garde, un
# marqueur annoncant une version et pinnant un commit qui en porte une autre
# serait recopie en avant, la divergence emportee avec lui.
REPO="$TMP/team24"; make_team_repo "$REPO"
marker "$REPO" rec "$C1" "7.7.7" "$(printf 'archive-bytes-1.0.0' | shasum -a 256 | cut -d' ' -f1)"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "marqueur rec incoherent"
resolve_promotion_pin "$REPO" accounts-read rec 2>"$TMP/e24" \
  && bad "marqueur annoncant 7.7.7 sur un pin qui porte 1.0.0 ACCEPTE — l'incoherence se propage" \
  || { grep -q SOURCE_VERSION_MISMATCH "$TMP/e24" && ok "SOURCE_VERSION_MISMATCH" || bad "refuse sans nommer SOURCE_VERSION_MISMATCH : $(cat "$TMP/e24")"; }

echo "㉔bis un marqueur CORROMPU se dit autrement qu'un palier ETEINT"
# Fondre les deux causes dans un seul jeton rendait un marqueur corrompu
# indiscernable d'un palier volontairement arrete — et un grep de logs sur les
# jetons ne les separait plus.
REPO="$TMP/team24b"; make_team_repo "$REPO"
printf 'ceci: [n est pas: du yaml valide\n' > "$REPO/apis/accounts-read.deploy.rec.yaml"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "marqueur rec corrompu"
resolve_promotion_pin "$REPO" accounts-read rec 2>"$TMP/e24b" \
  && bad "marqueur CORROMPU accepte" \
  || { grep -q PARSE_MARQUEUR_SOURCE "$TMP/e24b" \
       && ok "PARSE_MARQUEUR_SOURCE — distinct de SOURCE_NON_DEPLOYEE" \
       || bad "un marqueur corrompu se presente comme 'pas deployee' : $(cat "$TMP/e24b")"; }

printf '\n  %d PASS / %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
