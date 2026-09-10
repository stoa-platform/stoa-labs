#!/usr/bin/env bash
# ci/lint-branch-literals.sh — LA BRANCHE PAR DÉFAUT NE S'ÉCRIT PLUS EN DUR.
#
# CE QU'ELLE INTERDIT (mesuré le 2026-09-09, CI client `ci-app-request`, GitLab).
# La chaîne écrivait « main » à 46 endroits EXÉCUTÉS (`-b main`, `origin/main`,
# `"base": "main"`, `${GIT_BASE:-main}`, `<name>*/main</name>`) et dans 155
# messages. La branche par défaut du client est `master` : deux jours perdus à
# lire des refus qui nommaient une branche qui n'existe pas chez lui. L'autorité
# est désormais scripts/lib/git-base.sh — knob GIT_BASE, sinon la HEAD que le
# dépôt annonce, sinon un refus nommé.
#
# LA RÈGLE, et pourquoi elle est formulée ainsi : INTERDIRE le littéral, jamais
# l'EXIGER (même règle que ci/lint-forge-literals.sh, et même raison : une porte
# écrite dans le vocabulaire de ce qu'elle garde finit par garantir ce
# vocabulaire au lieu de la propriété). Cette porte ne sait pas ce qu'est une
# bonne façon de résoudre une branche ; elle sait seulement qu'un nom de branche
# écrit en dur dans un fichier LIVRÉ est une seconde autorité — et c'est tout.
#
# DEUX SECTIONS, DEUX DÉGÂTS DISTINCTS :
#   A1  le littéral EXÉCUTÉ — « -b main », « origin/main », « */main »… : la
#       chaîne part sur une branche qui n'existe pas.
#   A2  le mot « main » seul dans une ligne de CODE : c'est le MESSAGE qui ment,
#       et c'est lui qui a coûté deux jours — un refus qui parle d'une branche
#       que l'exploitant n'a jamais eue envoie chercher la panne ailleurs.
#
# PORTÉE : le shell livré, les Jenkinsfile, les coquilles de jobs et les tâches
# Ansible. Les EXEMPTÉS sont nommés un par un plus bas, avec leur raison ; un
# fichier hors périmètre n'est pas contrôlé — dette nommée, pas silence.
#
#   bash ci/lint-branch-literals.sh
set -uo pipefail
RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RACINE" || exit 1
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# ── EXEMPTÉS, chacun avec sa raison ──────────────────────────────────────────
# Un exempté n'est pas un oubli : c'est un fichier dont NOMMER une branche est
# l'objet. La liste est FERMÉE et lisible ; elle ne s'élargit pas par motif.
exempte() {
  case "$1" in
    # Les harnais CONSTRUISENT des dépôts nommés (master, develop, main) : c'est
    # leur discriminant même. Les en priver rendrait la preuve impossible.
    scripts/test-*.sh)          return 0 ;;
    scripts/demo-*.sh)          return 0 ;;
    scripts/spike-*.sh)         return 0 ;;
    # Outils de LAB : ils fabriquent le laboratoire (dépôts semés, GitLab CE
    # jetable, applications du terminus), ils ne partent pas chez le client.
    scripts/seed-governance-chain.sh) return 0 ;;
    scripts/setup-gitlab-lab.sh)      return 0 ;;
    scripts/setup-terminus-apps.sh)   return 0 ;;
    # L'AUTORITÉ elle-même : le seul fichier qui a le droit de composer
    # refs/heads/… — et la section B prouve qu'il le fait toujours.
    scripts/lib/git-base.sh)    return 0 ;;
  esac
  return 1
}

# ── le CODE d'un fichier, commentaires blanchis, numérotation CONSERVÉE ───────
# Ce dépôt commente ses correctifs en CITANT le motif corrigé : sans ce
# blanchiment, la porte rougirait sur sa propre prose (piège mesuré sur
# test-deploy-pin.sh, puis sur lint-forge-literals.sh). Trois dialectes :
#   .job.xml     <!-- … -->  (multi-lignes)
#   Jenkinsfile  /* … */, // et le # des blocs sh embarqués
#   .sh / .yml   #
# Le # n'est blanchi que PRÉCÉDÉ D'UN BLANC ou en début de ligne : sinon
# &#8212; (entités XML des descriptions de jobs) tronquerait la ligne et
# cacherait ce qui suit. Idem pour //, qui vit dans http://…
code_de() {
  python3 - "$1" "${2:-}" <<'PY'
import re, sys
p, mode = sys.argv[1], sys.argv[2]
s = open(p, encoding='utf-8', errors='replace').read()
def blanc(m):                      # remplace par des blancs : les LIGNES restent
    return re.sub(r'[^\n]', ' ', m.group(0))
if p.endswith('.xml'):
    s = re.sub(r'<!--.*?-->', blanc, s, flags=re.S)
else:
    if '/Jenkinsfile' in p:
        s = re.sub(r'/\*.*?\*/', blanc, s, flags=re.S)
        s = re.sub(r'(?m)(?<=^)//.*$|(?<=\s)//.*$', blanc, s)
    s = re.sub(r'(?m)(?<=^)#.*$|(?<=\s)#.*$', blanc, s)
if mode == 'a2':
    s = re.sub(r'(?m)^.*CARTO_PAGES_BRANCH.*$', blanc, s)   # exempte NOMMEMENT
    s = re.sub(r'[Ll]a main', blanc, s)                     # « a la main », « sous la main »
    s = re.sub(r'main\.yml', blanc, s)                      # tasks/main.yml, defaults/main.yml
    s = re.sub(r'__main__|def main|main\(', blanc, s)       # points d entree
sys.stdout.write(s)
PY
}

# ── le CODE, moins ce qui n'est PAS un nom de branche (pour A2 seulement) ─────
# EXEMPTÉS par CONSTRUCTION : l'idiome français « à la main », les fichiers
# main.yml d'Ansible, les points d'entrée main() / def main / __main__, et le
# paramètre CARTO_PAGES_BRANCH de Jenkinsfile.carto — branche de Pages du dépôt
# carto, paramètre documenté, sans rapport avec la branche de la chaîne. Tout
# identifiant qui CONTIENT main (domain, remain, humain, demain, maintenant)
# sort de lui-même : grep -w exige les deux frontières de mot.
a2_code() { code_de "$1" a2; }

# ── les motifs interdits, et le refus que chacun mérite ──────────────────────
# Un motif ERE, une TABULATION, la phrase du refus. Here-doc QUOTÉ : rien ne
# s'expanse, ni les $ des motifs ni les guillemets.
motifs_a1() {
  cat <<'MOT'
(^|[^-[:alnum:]])-b[[:space:]]+["']?main([^[:alnum:]/._-]|$)	un clone « -b main » — la branche est un ARGUMENT, jamais un littéral
origin/main	« origin/main » — la référence de base vient de GIT_BASE
refs/heads/main	« refs/heads/main » — la ref se compose, elle ne se cite pas
"base"[[:space:]]*:[[:space:]]*"main"	« "base": "main" » — la base d'une PR est celle du dépôt CIBLE
:-main}	un défaut « :-main} » — un défaut de SITE que rien ne voit passer
\*/main	« */main » — la branche du <scm> est le placeholder __GIT_BASE__
branch:[[:space:]]*['"]main['"]	« branch: 'main' » — la branche du checkout vient du <scm>
MOT
}

perimetre() {
  git ls-files 'scripts/*.sh' 'scripts/lib/*.sh' 'ci/Jenkinsfile*' 'ci/jenkins/*.job.xml' 'ansible/roles/*/tasks/*.yml'
}

FICHIERS=""; N_EXEMPT=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if exempte "$f"; then N_EXEMPT=$((N_EXEMPT+1)); continue; fi
  FICHIERS="${FICHIERS}${f}
"
done <<EOF
$(perimetre)
EOF
N_FICHIERS=$(printf '%s' "$FICHIERS" | grep -c . )

echo "═══ A. aucun nom de branche écrit en dur dans les fichiers LIVRÉS ═══"
if [ "$N_FICHIERS" -gt 100 ]; then
  ok "A.0 périmètre non vide : $N_FICHIERS fichiers contrôlés, $N_EXEMPT exemptés nommément"
else
  ko "A.0 périmètre suspect ($N_FICHIERS fichiers) — une liste vide rendrait CETTE porte verte pour rien"
fi

n1=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  code="$(code_de "$f")" || { ko "A.1 $f illisible"; n1=$((n1+1)); continue; }
  while IFS="	" read -r motif phrase; do
    [ -n "$motif" ] || continue
    hits="$(printf '%s\n' "$code" | grep -nE -- "$motif")"
    # Ni `head` ni `cut` DANS le pipe de grep : leur sortie prématurée envoie un
    # SIGPIPE en amont, et python y répond par une trace qui noie le verdict
    # (piège mesuré en A4). On coupe APRÈS, sur une variable.
    hits="$(printf '%s' "$hits" | sed -n '1,3p' | cut -c1-90)"
    if [ -n "$hits" ]; then
      ko "A.1 $f : $phrase — $(printf '%s' "$hits" | tr '\n' ' ')"
      n1=$((n1+1))
    fi
  done < <(motifs_a1)
done <<EOF
$FICHIERS
EOF
if [ "$n1" -eq 0 ]; then
  ok "A.1 aucun -b main, origin/main, refs/heads/main, base:main, :-main}, */main ni branch:main"
fi

echo "═══ A2. et aucun MESSAGE qui nomme « main » comme une branche ═══"
# LE mode de panne du client : un refus qui parle d'une branche qu'il n'a pas.
n2=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  hits="$(a2_code "$f" | grep -nEw -- 'main')"
  hits="$(printf '%s' "$hits" | sed -n '1,3p' | cut -c1-90)"
  if [ -n "$hits" ]; then
    ko "A.2 $f : « main » nu dans une ligne de code — un message qui nomme une branche que le client n'a pas — $(printf '%s' "$hits" | tr '\n' ' ')"
    n2=$((n2+1))
  fi
done <<EOF
$FICHIERS
EOF
if [ "$n2" -eq 0 ]; then
  ok "A.2 aucun « main » nu dans une ligne de code (hors « à la main », main.yml, main(), CARTO_PAGES_BRANCH)"
fi

echo "═══ B. l'autorité, elle, DÉCOUVRE bien (sinon A est vacante) ═══"
AUTORITE=scripts/lib/git-base.sh
if grep -qF -- 'ls-remote --symref' "$AUTORITE" && grep -qF 'refs/heads/' "$AUTORITE"; then
  ok "B.1 $AUTORITE porte ls-remote --symref et lit refs/heads/ — la branche est DEMANDÉE au dépôt"
else
  ko "B.1 $AUTORITE ne découvre plus rien : interdire le littéral ne prouverait alors AUCUNE résolution"
fi
if grep -qF 'BRANCHE_PAR_DEFAUT_INCONNUE' "$AUTORITE"; then
  ok "B.2 la découverte manquée est un REFUS NOMMÉ, pas un repli silencieux"
else
  ko "B.2 aucun refus nommé dans l'autorité — une découverte ratée pourrait redevenir un main deviné"
fi

echo "═══ M. mutation : la porte attrape ce qu'elle prétend attraper ═══"
MT="$(mktemp -d)"; trap 'rm -rf "$MT"' EXIT
mut_a1(){ # <fichier> → rc 0 si A1 le signale
  local code motif; code="$(code_de "$1")"
  while IFS="	" read -r motif _; do
    [ -n "$motif" ] || continue
    printf '%s\n' "$code" | grep -qE -- "$motif" && return 0
  done < <(motifs_a1)
  return 1
}
a2_voit(){ a2_code "$1" | grep -qEw -- 'main'; }

cat > "$MT/mutant.sh" <<'MUT'
#!/usr/bin/env bash
git clone -q --depth 1 -b main "$URL" "$W"
MUT
if mut_a1 "$MT/mutant.sh"; then ok "M.1 un script qui recompose « -b main » EST signalé"
else ko "M.1 le prédicat A1 ne voit pas un « -b main » évident"; fi

cat > "$MT/temoin.sh" <<'MUT'
#!/usr/bin/env bash
# ancien : git clone -b main, puis merge-base origin/main (retiré le 2026-09-10)
git clone -q --depth 1 -b "$GIT_BASE" "$URL" "$W"
MUT
if mut_a1 "$MT/temoin.sh"; then ko "M.2 un littéral qui ne vit qu'en COMMENTAIRE est signalé à tort — la porte rougirait sur sa propre prose"
else ok "M.2 un littéral en commentaire n'est PAS signalé — la porte lit le code, pas la prose"; fi

cat > "$MT/mutant.job.xml" <<'MUT'
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition>
  <!-- miroir du `git url: …, branch: 'main'` du job Groovy d origine -->
  <branches><hudson.plugins.git.BranchSpec><name>*/main</name></hudson.plugins.git.BranchSpec></branches>
</flow-definition>
MUT
if mut_a1 "$MT/mutant.job.xml"; then ok "M.3 un job.xml dont le <scm> renomme « */main » EST signalé"
else ko "M.3 le prédicat A1 ne voit pas un « */main » réintroduit dans un XML"; fi

cat > "$MT/temoin.job.xml" <<'MUT'
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition>
  <!-- miroir du `git url: …, branch: 'main'` du job Groovy d origine -->
  <branches><hudson.plugins.git.BranchSpec><name>*/__GIT_BASE__</name></hudson.plugins.git.BranchSpec></branches>
</flow-definition>
MUT
if mut_a1 "$MT/temoin.job.xml"; then ko "M.4 un branch: 'main' en COMMENTAIRE XML est signalé à tort"
else ok "M.4 le récit historique d'un commentaire XML ne rougit pas — seul le <scm> compte"; fi

cat > "$MT/msg.sh" <<'MUT'
#!/usr/bin/env bash
echo "REFUS: PAYLOAD_PERIME : la PR ne vise pas main"
MUT
if a2_voit "$MT/msg.sh"; then ok "M.5 un message qui dit « ne vise pas main » EST signalé (le défaut qui a coûté deux jours)"
else ko "M.5 A2 ne voit pas un message qui nomme la branche en dur"; fi

cat > "$MT/idiome.sh" <<'MUT'
#!/usr/bin/env bash
echo "les listes FROM_ENV/TO_ENV sont écrites à la main"
cat ansible/roles/apim_common/tasks/main.yml
python3 -c 'def main(): pass'
MUT
if a2_voit "$MT/idiome.sh"; then ko "M.6 « à la main » ou main.yml sont signalés à tort — la porte deviendrait illisible"
else ok "M.6 « à la main », main.yml et def main ne rougissent PAS — l'idiome et le fichier Ansible sont exemptés"; fi

ATTENDU=11; TOTAL=$((PASS + FAIL))
[ "$TOTAL" -ge "$ATTENDU" ] || { printf '  ❌ %d assertions jouées, au moins %d attendues\n' "$TOTAL" "$ATTENDU"; FAIL=$((FAIL+1)); }
echo
if [ "$FAIL" -eq 0 ]; then printf 'PORTE VERTE : aucune branche écrite en dur (%d/%d)\n' "$PASS" "$TOTAL"
else printf 'PORTE ROUGE : %d/%d\n' "$PASS" "$TOTAL"; fi
[ "$FAIL" -eq 0 ]
