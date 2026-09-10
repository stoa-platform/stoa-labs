#!/usr/bin/env bash
# test-repo-layout-portabilite.sh — la porte du PRÉFIXE DU LIVRABLE.
#
# CE QU'ELLE EMPÊCHE. Le livrable vit sous un préfixe dans le dépôt de la forge.
# Au lab c'est « poc-control-plane-federation/ » ; chez un client c'est autre
# chose, et depuis le 2026-09-03 ce préfixe est un knob (GIT_SUBDIR) dont
# scripts/lib/repo-layout.sh rend la forme prête à concaténer (SUB_PFX).
# La généralisation a laissé un résidu : provision-request.sh composait le
# chemin de providers.<env>.yml avec le préfixe du LAB écrit en dur, alors que
# le manifeste (REL_PATH) et le certificat (CERT_DIR) du même script suivaient
# déjà le knob. Chez un client, la garde d'appartenance d'équipe lisait donc un
# chemin qui n'existe pas, et TOUTE demande portant une `team` — fournie ou
# héritée du manifeste — mourait `PROVIDERS_MISSING` sur un fichier pourtant
# présent, sous un autre préfixe. Mesuré le 2026-09-08 sur le CI d'un client
# (`ci-app-request`, préfixe `apim-control-plane-federation`).
#
# POURQUOI CETTE SUITE EXISTE À PART. Le défaut est INVISIBLE aux deux portes
# déjà posées : ci/lint-config-knobs.sh n'examine que les VALEURS PAR DÉFAUT
# (`${X:-…}`), jamais un littéral affecté nu ; et toutes les fixtures des
# suites A1..A7 construisent leur dépôt AVEC le préfixe du lab — elles ne
# peuvent structurellement pas voir un chemin qui ne suit pas le knob.
# Une suite qui ne joue QUE sous un préfixe non-défaut est le seul harnais qui
# tombe sur ce défaut.
#
# TERRAIN : HORS LIGNE intégralement — un dépôt nu en file://, une forge
# injoignable (127.0.0.1:1). Aucune écriture ne sort : le parcours s'arrête de
# lui-même sur FORGE_ILLISIBLE, avant tout push (garde A6/A7 : « une PR ouverte
# pourrait exister »). C'est ce terminus qui sert de preuve de FRANCHISSEMENT :
# atteindre FORGE_ILLISIBLE, c'est avoir passé la garde providers.
#
# PORTÉE (étendue le 2026-09-09). Le même littéral vivait dans SEPT scripts
# livrables. §L couvre provision-request.sh (le défaut d'origine) ; §N/§O/§P
# jouent api-request.sh, team-request.sh et api-promote-{request,export}.sh
# POUR DE VRAI sous un préfixe non-défaut ; §Q assure la forme du chemin pour
# team-publish.sh, team-promote.sh et provision-plan.sh, que l'on ne sait pas
# conduire hors ligne ici (limite déclarée en tête de §N).
#
#   bash scripts/test-repo-layout-portabilite.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# Le script sous test source ses libs RELATIVEMENT au cwd (`. scripts/lib/…`,
# comme le job Jenkins qui fait dir(env.GIT_SUBDIR)).
cd "$REPO" || exit 1
S="$REPO/scripts/provision-request.sh"
TMP="$(mktemp -d /tmp/layoutport.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# ── fixture : un dépôt nu dont le livrable vit sous <préfixe> ────────────────
# fixture <nom> <préfixe|.> → chemin du dépôt nu. Le préfixe « . » pose le
# livrable À LA RACINE (la sentinelle de repo-layout.sh).
# fixture <nom> <préfixe|.> [palier déclaré] [style]
# style « client » : le MÊME contenu en YAML, écrit comme un client l'écrit —
# indentation à 4 espaces, valeur entre guillemets, commentaire en fin de ligne
# et fins de ligne CRLF. Tout ceci est valide ; le grep textuel le refusait.
# fixture <nom> <préfixe|.> [palier déclaré] [style] [branche par défaut]
# La BRANCHE est un paramètre depuis L3 (2026-09-10) : les dépôts que
# provision-request.sh clone sont construits sur `master`, pour que la
# DÉCOUVERTE de la branche (scripts/lib/git-base.sh) soit réellement mise à
# l'épreuve ici — un script qui devinerait « main » n'a plus de repli sans `-b`
# pour le rattraper, il refuse BRANCHE_DE_BASE_INTROUVABLE. Les fixtures des
# sections N/O/T (chaîne producteur, lot 4b) restent sur `main`.
fixture(){
  local pfx="$2" o="$TMP/$1.git" w="$TMP/$1" sub="" env_decl="${3:-dev}" style="${4:-lab}" br="${5:-main}"
  [ "$pfx" = "." ] || sub="$pfx/"
  git init -q --bare "$o" && git -C "$o" symbolic-ref HEAD "refs/heads/$br"
  git init -q "$w" && git -C "$w" checkout -q -b "$br"
  mkdir -p "$w/${sub}ansible" "$w/${sub}clients/provisioned/applications"
  # SEUL dev est déclaré : `rec` sert de contre-épreuve « vraiment absent ».
  if [ "$style" = client ]; then
    printf 'providers:\r\n    - team: "teamx"   # equipe reprise du referentiel interne\r\n      repo: ci/teamx\r\n      approvers: []\r\n' \
      > "$w/${sub}ansible/providers.${env_decl}.yml"
  else
    printf 'providers:\n  - team: teamx\n    repo: ci/teamx\n    approvers: []\n' \
      > "$w/${sub}ansible/providers.${env_decl}.yml"
  fi
  printf 'init\n' > "$w/README"
  git -C "$w" -c user.name=t -c user.email=t@t add -A >/dev/null
  git -C "$w" -c user.name=t -c user.email=t@t commit -qm c0 >/dev/null
  git -C "$w" remote add origin "$o" && git -C "$w" push -q origin "$br"
  printf '%s' "$o"
}
printf 'environments: [dev, rec, int, prod]\ngates:\n  - { to: rec, selfApproval: true }\n' > "$TMP/chain.yaml"

O_CLIENT=$(fixture client livrable dev lab master)          # préfixe NON-défaut, HEAD → master
O_LAB=$(fixture lab poc-control-plane-federation dev lab master)   # préfixe du lab
O_RACINE=$(fixture racine . dev lab master)                 # livrable = racine

# req <script> <dépôt nu> <GIT_SUBDIR|__ABSENT__> <env> [VAR=val…] → $TMP/req.out, $TMP/req.rc
# GIT_HOST vise un port fermé : la forge est injoignable PAR CONSTRUCTION.
req(){
  local sc="$1" origin="$2" sub="$3" e="$4"; shift 4
  # AUCUN GIT_BASE (L3, 2026-09-10) : la branche se DÉCOUVRE sur GIT_CLONE_URL,
  # un dépôt nu en file:// dont la HEAD est `master` — la suite reste hors ligne
  # (GIT_HOST vise un port fermé, et n'est jamais interrogé pour la branche).
  # Un knob « master » ici aurait été un vert vacant : jusqu'au 2026-09-10, le
  # repli sans `-b` de provision-request.sh rattrapait le clone `-b master` sur
  # des fixtures construites en `main` — 17 paires de clones, aucune détection.
  local -a envv=(GITEA_TOKEN=stub GIT_HOST=http://127.0.0.1:1 GIT_REPO=ci/appli
                 "GIT_CLONE_URL=file://$origin" "GIT_PUSH_URL=file://$origin"
                 MANIFEST_DIR=clients/provisioned/applications
                 "STOA_ENV_CHAIN_FILE=$TMP/chain.yaml" PROVISION_PLAN_INLINE=false
                 REQ_APP=appa "REQ_ENV=$e" REQ_API=demo REQ_API_VER=1.0.0
                 "REQ_CLIENT_ID=appa-$e" REQ_CALLER=oig-provisioner)
  [ "$sub" = "__ABSENT__" ] || envv+=("GIT_SUBDIR=$sub")
  ( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" "${envv[@]}" "$@" bash "$sc" ) > "$TMP/req.out" 2>&1
  echo $? > "$TMP/req.rc"
}
rrc(){ cat "$TMP/req.rc"; }
# franchie : la garde providers a été PASSÉE — le rendu a commencé ([2/5]) et le
# parcours est allé mourir sur la forge injoignable, jamais sur PROVIDERS_MISSING.
franchie(){ ! grep -q 'PROVIDERS_MISSING' "$TMP/req.out" && grep -q '^\[2/5\]' "$TMP/req.out" && grep -q 'REFUS: FORGE_ILLISIBLE' "$TMP/req.out"; }
detail(){ grep -E 'REFUS|ERREUR' "$TMP/req.out" | head -1; }

echo "═══ L. la garde providers suit le knob GIT_SUBDIR ═══"

req "$S" "$O_CLIENT" livrable dev REQ_TEAM=teamx
if franchie; then ok "L.1 préfixe non-défaut (livrable/) : la garde lit livrable/ansible/providers.dev.yml et PASSE"
else ko "L.1 rc $(rrc) : $(detail)"; fi

req "$S" "$O_CLIENT" livrable dev REQ_TEAM=inconnue
if [ "$(rrc)" = 2 ] && grep -q "REFUS: TEAM_NOT_DECLARED : 'inconnue'" "$TMP/req.out"; then
  ok "L.2 la garde reste FERMÉE sous le knob : une équipe non déclarée ⇒ TEAM_NOT_DECLARED (elle lit, elle ne saute pas)"
else ko "L.2 rc $(rrc) : $(detail)"; fi

req "$S" "$O_CLIENT" livrable rec REQ_TEAM=teamx
if [ "$(rrc)" = 2 ] && grep -q 'REFUS: PROVIDERS_MISSING' "$TMP/req.out"; then
  ok "L.3 palier sans fichier providers ⇒ PROVIDERS_MISSING, fail-closed (le refus légitime survit)"
else ko "L.3 rc $(rrc) : $(detail)"; fi

# Le refus doit NOMMER le chemin RÉELLEMENT LU — discipline « refus
# auto-diagnostique » (e1f4254). Un refus qui dit « ansible/providers.rec.yml »
# alors qu'il a lu « livrable/ansible/providers.rec.yml » envoie le client
# chercher au mauvais endroit : c'est ce message qui a masqué le défaut.
if grep -q 'PROVIDERS_MISSING : livrable/ansible/providers.rec.yml' "$TMP/req.out"; then
  ok "L.4 le refus NOMME le chemin réellement lu (préfixe compris), pas un chemin théorique"
else ko "L.4 refus non auto-diagnostique : $(grep -m1 PROVIDERS_MISSING "$TMP/req.out")"; fi

req "$S" "$O_RACINE" . dev REQ_TEAM=teamx
if franchie; then ok "L.5 sentinelle « le livrable EST la racine » (GIT_SUBDIR=.) : ansible/providers.dev.yml lu à la racine"
else ko "L.5 rc $(rrc) : $(detail)"; fi

req "$S" "$O_LAB" __ABSENT__ dev REQ_TEAM=teamx
if franchie; then ok "L.6 non-régression : GIT_SUBDIR absent ⇒ le défaut du lab s'applique, la garde lit poc-control-plane-federation/ansible/"
else ko "L.6 rc $(rrc) : $(detail)"; fi


# ═════════════════════════════════════════════════════════════════════════════
# LES CINQ AUTRES SCRIPTS DE LA CHAÎNE PRODUCTEUR (2026-09-09).
# Le même littéral vivait dans six scripts livrables, chacun avec sa suite —
# aucune ne pouvait le voir, pour la raison écrite en tête de fichier. Les
# sections N/O/P les jouent SOUS UN PRÉFIXE NON-DÉFAUT, pour de vrai.
#
# ⚠ LIMITE DÉCLARÉE (section Q). team-publish.sh et team-promote.sh lisent
# providers.<env>.yml DERRIÈRE une réconciliation de PR Gitea et un clone
# `--depth 1` en smart HTTP : les conduire ici exigerait de re-héberger le stub
# de test-team-promote-wiring.sh (git http-backend + API). Leur assertion est
# donc STATIQUE — la forme du chemin, doublée d'une mutation pour ne pas être
# vacante. C'est plus faible que N/O/P, et c'est dit.
# ═════════════════════════════════════════════════════════════════════════════

# labctl de paille : api-request.sh exige l'AUTORITÉ de posture dans le PATH
# (POSTURE_AUTORITE_ABSENTE) bien avant le clone. Ce qu'elle répond n'entre pas
# dans la garde éprouvée ici — seule sa présence compte.
LABCTL_STUB="$TMP/labctl"; printf '#!/bin/sh\nexit 0\n' > "$LABCTL_STUB"; chmod +x "$LABCTL_STUB"
# OPENAPI_SPEC est le contrat COLLÉ (le texte), pas un chemin.
SPEC='openapi: 3.0.0
info: {title: demo, version: "1.0.0"}
paths: {}'

# run <script> <GIT_SUBDIR|__ABSENT__> [VAR=val…] — même contrat que req().
run(){
  local sc="$1" sub="$2"; shift 2
  local -a envv=(GITEA_TOKEN=stub "STOA_ENV_CHAIN_FILE=$TMP/chain.yaml")
  [ "$sub" = "__ABSENT__" ] || envv+=("GIT_SUBDIR=$sub")
  ( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" "${envv[@]}" "$@" bash "$sc" ) > "$TMP/req.out" 2>&1
  echo $? > "$TMP/req.rc"
}
# nomme <chemin> — le refus PROVIDERS_MISSING désigne-t-il le chemin RÉELLEMENT lu ?
nomme(){ grep -q "PROVIDERS_MISSING : $1" "$TMP/req.out"; }

echo "═══ N. api-request.sh (chaîne producteur) suit le knob ═══"
S_AR="$REPO/scripts/api-request.sh"
# Le palier est SCELLÉ sur l'env d'authoring (G4/ADR-082) : c'est providers.dev.yml
# qui est lu, quel que soit le palier de publication. La fixture « arvide » ne
# déclare que `rec` — elle sert de « vraiment absent » pour CE script.
# Ces fixtures sont désignées par leur NOM (via GIT_REPO), pas par le chemin
# rendu : les affecter ferait des variables mortes.
fixture ar livrable >/dev/null
fixture arvide livrable rec >/dev/null
fixture arlab poc-control-plane-federation >/dev/null
ar(){ # ar <nom de fixture> <sub> [script]
  run "${3:-$S_AR}" "$2" "GIT_HOST=file://$TMP" "GIT_REPO=$1" ACTION=create TEAM=teamx \
      API_NAME=demo API_VERSION=1.0.0 API_BASE=/demo "OPENAPI_SPEC=$SPEC" INBOUND_MODE=jwt \
      CLASSIFICATION=M EXPOSURE=internal "LABCTL_BIN=$LABCTL_STUB"
}
# franchie_ar : la garde a été PASSÉE — l'équipe a été RÉSOLUE en dépôt, et le
# parcours est allé mourir sur le registre de gouvernance (sans défaut, exprès).
franchie_ar(){ ! grep -q 'PROVIDERS_MISSING' "$TMP/req.out" \
  && grep -q "équipe 'teamx' -> dépôt ci/teamx" "$TMP/req.out" \
  && grep -q 'CHAMP_REQUIS : GOVERNANCE_REPO' "$TMP/req.out"; }

ar ar livrable
if franchie_ar; then ok "N.1 préfixe non-défaut : api-request lit livrable/ansible/providers.dev.yml et résout l'équipe"
else ko "N.1 rc $(rrc) : $(detail)"; fi

ar arvide livrable
if [ "$(rrc)" != 0 ] && nomme 'livrable/ansible/providers.dev.yml'; then
  ok "N.2 fichier vraiment absent ⇒ PROVIDERS_MISSING qui NOMME le chemin lu (préfixe compris)"
else ko "N.2 rc $(rrc) : $(detail)"; fi

ar arlab __ABSENT__
if franchie_ar; then ok "N.3 non-régression : GIT_SUBDIR absent ⇒ le préfixe du lab s'applique"
else ko "N.3 rc $(rrc) : $(detail)"; fi

# DISCRIMINANT (ce que l'ancien code aurait passé). La fixture porte le préfixe
# du LAB, le knob dit « livrable » : le fichier existe, mais PAS là où le knob
# l'envoie. Un script qui ignore le knob le trouve et PASSE — c'est exactement
# le défaut du 2026-09-08, à l'envers. Aucune mutation n'est nécessaire pour
# prouver que N.1 n'est pas vacante : ce cas seul les sépare.
ar arlab livrable
if [ "$(rrc)" != 0 ] && nomme 'livrable/ansible/providers.dev.yml'; then
  ok "N.4 discriminant : le knob DÉCIDE du chemin lu (fichier présent au préfixe du lab ⇒ refus quand même)"
else ko "N.4 le knob est décoratif — le fichier du lab a été lu : rc $(rrc) : $(detail)"; fi

echo "═══ O. team-request.sh (onboarding d'équipe) suit le knob ═══"
S_TR="$REPO/scripts/team-request.sh"
# Fixtures DÉDIÉES : team-request POUSSE une branche dans le dépôt nu — les
# partager avec la section N ferait dépendre les cas de leur ordre.
fixture tr livrable >/dev/null
fixture trvide livrable rec >/dev/null
fixture trlab poc-control-plane-federation >/dev/null
fixture trleurre poc-control-plane-federation >/dev/null
trq(){ # trq <nom de fixture> <sub> [script]
  run "${3:-$S_TR}" "$2" "GIT_HOST=file://$TMP" "GIT_REPO=$1" TEAM=nouvelle REPO=eq/nouvelle \
      DESCRIPTION="equipe de sonde" REQ_ENV=dev
}
# franchie_tr : l'étape [2/4] n'est atteinte qu'APRÈS la garde providers.
franchie_tr(){ ! grep -q 'PROVIDERS_MISSING' "$TMP/req.out" && grep -q '^\[2/4\]' "$TMP/req.out"; }

trq tr livrable
if franchie_tr; then ok "O.1 préfixe non-défaut : team-request édite livrable/ansible/providers.dev.yml"
else ko "O.1 rc $(rrc) : $(detail)"; fi

trq trvide livrable
if [ "$(rrc)" != 0 ] && nomme 'livrable/ansible/providers.dev.yml'; then
  ok "O.2 fichier vraiment absent ⇒ refus auto-diagnostique (le message ne disait AUCUN chemin avant)"
else ko "O.2 rc $(rrc) : $(detail)"; fi

trq trlab __ABSENT__
if franchie_tr; then ok "O.3 non-régression : GIT_SUBDIR absent ⇒ le préfixe du lab s'applique"
else ko "O.3 rc $(rrc) : $(detail)"; fi

# DISCRIMINANT, même construction qu'en N.4 (fixture DÉDIÉE : team-request pousse).
trq trleurre livrable
if [ "$(rrc)" != 0 ] && nomme 'livrable/ansible/providers.dev.yml'; then
  ok "O.4 discriminant : le knob DÉCIDE du chemin lu (fichier présent au préfixe du lab ⇒ refus quand même)"
else ko "O.4 le knob est décoratif — le fichier du lab a été lu : rc $(rrc) : $(detail)"; fi

echo "═══ P. api-promote-{request,export}.sh : le préfixe est dans une URL ═══"
# Ces deux-là ne clonent pas le dépôt plateforme : ils lisent providers.<env>.yml
# par l'API RAW de la forge. Le préfixe est donc un SEGMENT D'URL — un stub qui
# ne sert QUE le préfixe non-défaut sépare sans ambiguïté les deux formes, et son
# journal dit le chemin RÉELLEMENT DEMANDÉ (le cas de non-régression n'a même pas
# besoin d'une réponse 200 : la demande suffit).
SERVED="$TMP/served"; mkdir -p "$SERVED/livrable/ansible"
printf 'providers:\n  - team: teamx\n    repo: ci/teamx\n' > "$SERVED/livrable/ansible/providers.dev.yml"
STUB_LOG="$TMP/stub.log"; : > "$STUB_LOG"
cat > "$TMP/rawstub.py" <<'PY'
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
ROOT, LOG = os.environ["STUB_ROOT"], os.environ["STUB_LOG"]
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, *a): pass
    def do_GET(self):
        with open(LOG, "a") as f: f.write(self.path + "\n")
        if "/raw/" in self.path:
            p = os.path.join(ROOT, self.path.split("/raw/", 1)[1])
            if os.path.isfile(p):
                b = open(p, "rb").read()
                self.send_response(200); self.send_header("Content-Length", str(len(b)))
                self.end_headers(); self.wfile.write(b); return
        self.send_response(404); self.send_header("Content-Length", "2")
        self.end_headers(); self.wfile.write(b"{}")
    do_POST = do_GET
s = ThreadingHTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY
STUB_ROOT="$SERVED" STUB_LOG="$STUB_LOG" python3 "$TMP/rawstub.py" > "$TMP/port" 2>"$TMP/stub.err" &
STUB_PID=$!
# Le trap d'origine ne connaît que $TMP : on le rearme pour emporter le stub.
trap '[ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM
for _ in $(seq 1 60); do [ -s "$TMP/port" ] && break; sleep 0.1; done
PORT="$(head -n1 "$TMP/port" 2>/dev/null)"
if [ -z "$PORT" ]; then
  ko "P.0 le stub HTTP n'a pas démarré — section P non jouée : $(head -3 "$TMP/stub.err" 2>/dev/null | tr '\n' ' ')"
else
STUB_HOST="http://127.0.0.1:$PORT"
S_APR="$REPO/scripts/api-promote-request.sh"
S_APE="$REPO/scripts/api-promote-export.sh"
printf 'hvs.stub\n' > "$TMP/vtok"
apr(){ run "${2:-$S_APR}" "$1" "GIT_HOST=$STUB_HOST" GIT_REPO=ci/plat TEAM=teamx API_NAME=demo \
           FROM_ENV=dev TO_ENV=rec MESSAGE=sonde; }
ape(){ run "${2:-$S_APE}" "$1" "GIT_HOST=$STUB_HOST" GIT_REPO=ci/plat TEAM=teamx API_NAME=demo \
           VAULT_ADDR=http://127.0.0.1:1 "VAULT_TOKEN_FILE=$TMP/vtok" APIM_API_BASE=http://127.0.0.1:1; }
# franchie_ap : LECTURE_PROVIDERS passée, l'équipe résolue — le parcours meurt
# au clone du dépôt d'équipe, que le stub ne sert pas.
franchie_ap(){ ! grep -q 'LECTURE_PROVIDERS' "$TMP/req.out" && grep -q 'CLONE_ECHEC : ci/teamx' "$TMP/req.out"; }
demande(){ grep -q "/raw/$1\$" "$STUB_LOG"; }

: > "$STUB_LOG"; apr livrable
if franchie_ap && demande 'livrable/ansible/providers.dev.yml'; then
  ok "P.1 api-promote-request : l'URL raw porte le préfixe non-défaut, la lecture aboutit"
else ko "P.1 rc $(rrc) : $(detail) | demandé: $(tr '\n' ' ' < "$STUB_LOG")"; fi

: > "$STUB_LOG"; ape livrable
if franchie_ap && demande 'livrable/ansible/providers.dev.yml'; then
  ok "P.2 api-promote-export : idem (le même chemin, la même autorité)"
else ko "P.2 rc $(rrc) : $(detail) | demandé: $(tr '\n' ' ' < "$STUB_LOG")"; fi

: > "$STUB_LOG"; apr __ABSENT__
if demande 'poc-control-plane-federation/ansible/providers.dev.yml'; then
  ok "P.3 non-régression : GIT_SUBDIR absent ⇒ l'URL demandée reste celle du lab"
else ko "P.3 URL demandée inattendue : $(tr '\n' ' ' < "$STUB_LOG")"; fi

: > "$STUB_LOG"; apr autre
if grep -q 'LECTURE_PROVIDERS : autre/ansible/providers.dev.yml' "$TMP/req.out"; then
  ok "P.4 fichier non servi sous le préfixe demandé ⇒ le refus NOMME l'URL réellement demandée"
else ko "P.4 refus non auto-diagnostique : $(detail)"; fi

# DISCRIMINANT (ce que l'ancien code aurait passé) : le stub ne sert QUE
# `livrable/`. Demander le préfixe du LAB doit donc échouer — un script qui
# ignore le knob et va toujours au lab ne peut pas distinguer ce cas de P.1.
: > "$STUB_LOG"; apr poc-control-plane-federation
if demande 'poc-control-plane-federation/ansible/providers.dev.yml' && grep -q 'LECTURE_PROVIDERS' "$TMP/req.out"; then
  ok "P.5 discriminant : le knob DÉCIDE de l'URL (préfixe du lab demandé ⇒ 404 ⇒ refus), il n'est pas décoratif"
else ko "P.5 le knob n'a pas décidé de l'URL : $(tr '\n' ' ' < "$STUB_LOG")"; fi
fi

echo "═══ Q. team-publish.sh / team-promote.sh : la forme du chemin (assertion STATIQUE) ═══"
# Assertion de FORME, faute de pouvoir les conduire hors ligne (limite déclarée
# en tête de section). Doublée d'une mutation plus bas : sans elle, elle ne
# prouverait que sa propre existence.
q_forme(){ # q_forme <fichier> → 0 si le chemin providers est composé avec SUB_PFX
  grep -q 'repo_layout_init' "$1" \
    && grep -qE 'PROV_REL="\$\{SUB_PFX\}ansible/providers\.' "$1" \
    && ! grep -qE 'poc-control-plane-federation/ansible/providers\.' "$1"
}
for f in team-publish team-promote; do
  if q_forme "$REPO/scripts/$f.sh"; then
    ok "Q.$f compose providers.<env>.yml avec \${SUB_PFX} (repo_layout_init appelé, aucun littéral de lab)"
  else ko "Q.$f porte encore le préfixe du lab en dur (ou ne sourcait pas repo-layout.sh)"; fi
done

# provision-plan.sh : même famille, autre forme — le préfixe y est un `cd` DANS
# le clone de la PR, juste avant l'`ansible-playbook --syntax-check`. Le reste
# du script suivait déjà le knob (MANIFEST_PATH) : ce `cd` en était le résidu.
# shellcheck disable=SC2016  # quotes SIMPLES à dessein : c'est le TEXTE cherché
q_cd(){ grep -qF 'cd "${SUB_PFX:-.}"' "$1" && ! grep -qE '^[[:space:]]*cd poc-control-plane-federation' "$1"; }
# team-request.sh entre dans le livrable du CLONE pour y jouer le plan ; le
# littéral y faisait échouer le `cd`, court-circuiter le `&&`, et le valideur
# lisait « PLAN EN ÉCHEC — NE PAS MERGER » sur une demande valide.
# shellcheck disable=SC2016  # motif recherché, jamais une expansion
q_cd_clone(){ grep -qF 'cd "$WORK/repo/${SUB_PFX:-.}"' "$1"; }
# setup-carto-job.sh : le défaut du <scriptPath> était VIDE, donc la
# substitution ne jouait pas et c'était le littéral du job.xml qui partait.
# shellcheck disable=SC2016  # motif recherché, jamais une expansion
q_scriptpath(){ grep -q 'repo_layout_init' "$1" && grep -qF 'SCRIPT_PATH:-${SUB_PFX}ci/Jenkinsfile' "$1"; }
# Le triplet labctl : la MÊME ligne dans trois Jenkinsfile qui déclarent déjà le
# knob et l'honorent partout ailleurs — seul le stage « Build labctl » tombait.
# shellcheck disable=SC2016  # motif recherché, jamais une expansion
q_dir_labctl(){ grep -qF 'dir("${env.GIT_SUBDIR}/labctl")' "$1" && ! grep -qF "dir('poc-control-plane-federation/labctl')" "$1"; }
if q_cd "$REPO/scripts/provision-plan.sh"; then
  ok "Q.provision-plan entre dans le livrable par le knob (cd \"\${SUB_PFX:-.}\"), plus par un littéral"
else ko "Q.provision-plan porte encore 'cd poc-control-plane-federation' en dur"; fi

if q_cd_clone "$REPO/scripts/team-request.sh"; then
  ok "Q.team-request joue le plan dans le livrable du clone, pris au knob"
else ko "Q.team-request porte encore le préfixe du lab dans le cd du plan"; fi
if q_scriptpath "$REPO/scripts/setup-carto-job.sh"; then
  ok "Q.setup-carto-job compose son <scriptPath> depuis \${SUB_PFX} (défaut non vide)"
else ko "Q.setup-carto-job garde un défaut vide ou un littéral"; fi
for jf in Jenkinsfile Jenkinsfile.prod Jenkinsfile.rollback; do
  if q_dir_labctl "$REPO/ci/$jf"; then
    ok "Q.$jf le stage « Build labctl » entre par dir(\"\${env.GIT_SUBDIR}/labctl\")"
  else ko "Q.$jf porte encore dir('poc-control-plane-federation/labctl')"; fi
done

echo "═══ R. l'appartenance d'équipe se LIT (YAML), elle ne se reconnaît pas (texte) ═══"
# Le second refus du client, le 2026-09-09 : passe PROVIDERS_MISSING, puis
# « TEAM_NOT_DECLARED : 'fbi' absent » sur un fichier qui DÉCLARE l'équipe.
# Ici on joue le parcours ENTIER contre un providers écrit comme chez lui.
fixture cli livrable dev client >/dev/null
fixture clivide livrable dev client >/dev/null

req "$S" "$TMP/cli.git" livrable dev REQ_TEAM=teamx
if franchie; then ok "R.1 providers en style client (4 espaces, guillemets, commentaire, CRLF) ⇒ l'équipe est reconnue"
else ko "R.1 rc $(rrc) : $(detail)"; fi

req "$S" "$TMP/clivide.git" livrable dev REQ_TEAM=inconnue
if [ "$(rrc)" = 2 ] && grep -q "REFUS: TEAM_NOT_DECLARED : 'inconnue'" "$TMP/req.out" \
   && grep -q 'équipes déclarées : teamx' "$TMP/req.out"; then
  ok "R.2 équipe vraiment absente ⇒ refus qui LISTE les équipes déclarées (le message qui manquait)"
else ko "R.2 rc $(rrc) : $(detail)"; fi

# Un providers illisible ne doit JAMAIS se présenter comme « équipe absente » :
# l'un est une panne de la plateforme, l'autre un défaut de la demande.
CASSE="$TMP/casse"; rm -rf "$CASSE" "$TMP/casse.git"
fixture casse livrable dev lab master >/dev/null
git clone -q "$TMP/casse.git" "$CASSE/w" 2>/dev/null \
  && printf 'providers:\n  - team: teamx\n   repo: mauvaise indentation\n' > "$CASSE/w/livrable/ansible/providers.dev.yml" \
  && git -C "$CASSE/w" -c user.name=t -c user.email=t@t commit -aqm casse \
  && git -C "$CASSE/w" push -q origin master
req "$S" "$TMP/casse.git" livrable dev REQ_TEAM=teamx
if [ "$(rrc)" = 2 ] && grep -q 'PROVIDERS_PARSE' "$TMP/req.out" && ! grep -q 'TEAM_NOT_DECLARED' "$TMP/req.out"; then
  ok "R.3 providers illisible en YAML ⇒ PROVIDERS_PARSE, jamais « équipe absente » (deux pannes, deux remèdes)"
else ko "R.3 rc $(rrc) : $(detail)"; fi

echo "═══ S. le <scriptPath> posé dans Jenkins suit le knob ═══"
# Un <scriptPath> est un chemin DANS LE DÉPÔT DE LA FORGE : Jenkins le résout au
# checkout. Écrit en dur, le job pointait un Jenkinsfile inexistant chez un
# client. `--print` sort le XML sur stdout AVANT le premier appel réseau : la
# preuve est behaviourale et hors ligne, sans faux Jenkins.
sp(){ # sp <GIT_SUBDIR|__ABSENT__> → le <scriptPath> réellement posé
  local -a e=(PATH="$PATH" HOME="$HOME" "STOA_ENV_CHAIN_FILE=$REPO/clients/_example/environments.yaml")
  [ "$1" = "__ABSENT__" ] || e+=("GIT_SUBDIR=$1")
  ( cd "$REPO" && env -i "${e[@]}" bash scripts/setup-selfservice-job.sh --print 2>/dev/null ) \
    | grep -o '<scriptPath>[^<]*</scriptPath>' | head -1
}
if [ "$(sp livrable)" = '<scriptPath>livrable/ci/Jenkinsfile.selfservice</scriptPath>' ]; then
  ok "S.1 GIT_SUBDIR=livrable ⇒ le job pointe livrable/ci/Jenkinsfile.selfservice"
else ko "S.1 posé : $(sp livrable)"; fi
if [ "$(sp .)" = '<scriptPath>ci/Jenkinsfile.selfservice</scriptPath>' ]; then
  ok "S.2 sentinelle « le livrable EST la racine » ⇒ ci/Jenkinsfile.selfservice"
else ko "S.2 posé : $(sp .)"; fi
if [ "$(sp __ABSENT__)" = '<scriptPath>poc-control-plane-federation/ci/Jenkinsfile.selfservice</scriptPath>' ]; then
  ok "S.3 non-régression : sans knob, le préfixe du lab (valeur identique à celle d'avant)"
else ko "S.3 posé : $(sp __ABSENT__)"; fi

echo "═══ T. le balayage de collision REGARDE là où le knob l'envoie ═══"
# Le plus cher du lot : un préfixe faux ici ne casse rien de VISIBLE. La boucle
# fait `[ -d … ] || continue` sur ses deux itérations, COLLISION_OWNER reste
# vide, et la moitié plateforme d'API_NAME_COLLISION rend « aucune collision »
# avec la même assurance que si elle avait regardé — un FAIL-OPEN silencieux,
# à comparer au clone d'équipe raté qui, lui, CRIE COLLISION_SCAN_INCOMPLET.
# fixture_collision <nom> <préfixe du dépôt> <préfixe où POSER le manifeste>
fixture_collision(){
  local o="$TMP/$1.git" w="$TMP/$1" sub="" psub=""
  [ "$2" = "." ] || sub="$2/"
  [ "$3" = "." ] || psub="$3/"
  git init -q --bare "$o" && git -C "$o" symbolic-ref HEAD refs/heads/main
  git init -q "$w" && git -C "$w" checkout -q -b main
  mkdir -p "$w/${sub}ansible" "$w/${psub}clients/autre-equipe"
  printf 'providers:\n  - team: teamx\n    repo: ci/teamx\n' > "$w/${sub}ansible/providers.dev.yml"
  printf 'apim_api:\n  name: "demo"\n  version: "1.0.0"\n' \
    > "$w/${psub}clients/autre-equipe/demo.publish.yml"
  printf 'classifications: {}\n' > "$w/registre.yaml"
  printf 'init\n' > "$w/README"
  git -C "$w" -c user.name=t -c user.email=t@t add -A >/dev/null
  git -C "$w" -c user.name=t -c user.email=t@t commit -qm c0 >/dev/null
  git -C "$w" remote add origin "$o" && git -C "$w" push -q origin main
}
# Le registre de gouvernance vit dans le MÊME dépôt nu (un second suffirait,
# mais il n'apporterait rien : ce qu'on éprouve est le balayage, pas le registre).
coll(){ # coll <fixture> <sub>
  run "$S_AR" "$2" "GIT_HOST=file://$TMP" "GIT_REPO=$1" ACTION=create TEAM=teamx \
      API_NAME=demo API_VERSION=1.0.0 API_BASE=/demo "OPENAPI_SPEC=$SPEC" INBOUND_MODE=jwt \
      CLASSIFICATION=M EXPOSURE=internal "LABCTL_BIN=$LABCTL_STUB" \
      "GOVERNANCE_REPO=$1" GOVERNANCE_PATH=registre.yaml
}

fixture_collision collok livrable livrable
coll collok livrable
if grep -q "API_NAME_COLLISION : 'demo' est déjà publiée par dépôt plateforme" "$TMP/req.out"; then
  ok "T.1 manifeste homonyme sous livrable/clients/ + knob livrable ⇒ la collision est VUE"
else ko "T.1 collision manquée — rc $(rrc) : $(detail)"; fi

# DISCRIMINANT : le manifeste est posé au préfixe du LAB, le knob dit livrable.
# Le balayage ne doit RIEN voir de ce côté — l'ancien code, lui, le voyait
# toujours, quel que soit le knob : c'est ce cas seul qui sépare les deux.
fixture_collision collleurre livrable poc-control-plane-federation
coll collleurre livrable
if ! grep -q 'API_NAME_COLLISION' "$TMP/req.out"; then
  ok "T.2 discriminant : manifeste au préfixe du lab + knob livrable ⇒ hors du périmètre balayé"
else ko "T.2 le balayage a regardé au préfixe du lab malgré le knob"; fi

echo "═══ M. mutation : l'épreuve attrape bien ce qu'elle prétend attraper ═══"
MUT="$TMP/mut.sh"
# BRE (pas -E) : `${SUB_PFX}` s'y écrit littéralement, sans échappement d'accolade
# — la forme ERE avec `\s`/`\{` n'est pas portable sur le sed de BSD/macOS.
# shellcheck disable=SC2016  # quotes SIMPLES à dessein : `${SUB_PFX}` est le texte cherché, jamais une expansion
sed 's#PROV_FILE="${SUB_PFX}ansible/#PROV_FILE="poc-control-plane-federation/ansible/#' "$S" > "$MUT"
if cmp -s "$S" "$MUT" || ! bash -n "$MUT" 2>/dev/null; then
  ko "M1 mutant no-op ou incompilable — l'épreuve ne prouve rien (le correctif a-t-il changé de forme ?)"
else
  req "$MUT" "$O_CLIENT" livrable dev REQ_TEAM=teamx
  if [ "$(rrc)" = 2 ] && grep -q 'REFUS: PROVIDERS_MISSING' "$TMP/req.out"; then
    ok "M1 préfixe du lab réécrit en dur ⇒ L.1 rougit (PROVIDERS_MISSING sur un fichier présent) — le défaut du 2026-09-08 reproduit"
  else ko "M1 le mutant passe encore : rc $(rrc) : $(detail)"; fi
fi

# M2 — la section Q est STATIQUE : sans mutation elle ne prouverait que sa
# propre existence. Le mutant réécrit le préfixe en dur sur une COPIE.
for f in team-publish team-promote; do
  MQ="$TMP/mutq-$f.sh"
  # shellcheck disable=SC2016  # `${SUB_PFX}` est le TEXTE cherché, jamais une expansion
  sed 's#PROV_REL="${SUB_PFX}ansible/#PROV_REL="poc-control-plane-federation/ansible/#' \
    "$REPO/scripts/$f.sh" > "$MQ"
  if cmp -s "$REPO/scripts/$f.sh" "$MQ"; then
    ko "M2-$f mutant no-op — l'assertion Q.$f ne prouve rien (le correctif a-t-il changé de forme ?)"
  elif q_forme "$MQ"; then
    ko "M2-$f Q.$f reste verte sur un mutant au préfixe du lab : assertion vacante"
  else
    ok "M2-$f préfixe du lab réécrit en dur ⇒ Q.$f rougit"
  fi
done

# M3 — même régime pour provision-plan.sh (assertion statique, donc mutée).
MQ3="$TMP/mutq-provision-plan.sh"
# shellcheck disable=SC2016  # idem : `${SUB_PFX:-.}` est le motif, pas une expansion
sed 's#cd "${SUB_PFX:-.}"#cd poc-control-plane-federation#' "$REPO/scripts/provision-plan.sh" > "$MQ3"
if cmp -s "$REPO/scripts/provision-plan.sh" "$MQ3"; then
  ko "M3 mutant no-op — l'assertion Q.provision-plan ne prouve rien"
elif q_cd "$MQ3"; then
  ko "M3 Q.provision-plan reste verte sur un mutant au préfixe du lab : assertion vacante"
else ok "M3 préfixe du lab réécrit en dur ⇒ Q.provision-plan rougit"; fi

# M4/M5/M6 — les trois assertions statiques ajoutées le 2026-09-09, chacune
# mutée : sans mutation, une assertion de forme ne prouve que sa propre existence.
mute(){ # mute <étiquette> <fichier> <sed> <prédicat>
  local m="$TMP/mut-$1.txt"
  sed "$3" "$2" > "$m"
  if cmp -s "$2" "$m"; then ko "$1 mutant no-op — l'assertion ne prouve rien"
  elif "$4" "$m"; then ko "$1 l'assertion reste verte sur le mutant : vacante"
  else ok "$1 préfixe du lab réécrit en dur ⇒ l'assertion rougit"; fi
}
# shellcheck disable=SC2016  # motifs, jamais des expansions
mute M4-team-request "$REPO/scripts/team-request.sh" 's#cd "$WORK/repo/${SUB_PFX:-.}"#cd "$WORK/repo/poc-control-plane-federation"#' q_cd_clone
# shellcheck disable=SC2016
mute M5-setup-carto-job "$REPO/scripts/setup-carto-job.sh" 's#SCRIPT_PATH:-${SUB_PFX}ci/Jenkinsfile#SCRIPT_PATH:-poc-control-plane-federation/ci/Jenkinsfile#' q_scriptpath
# shellcheck disable=SC2016
mute M6-labctl "$REPO/ci/Jenkinsfile" 's#dir("${env.GIT_SUBDIR}/labctl")#dir('"'"'poc-control-plane-federation/labctl'"'"')#' q_dir_labctl

echo
echo "═══════════════════════════════════════════════════"
printf 'RÉSULTAT : %d/%d\n' "$PASS" $((PASS + FAIL))
[ "$FAIL" -eq 0 ] || exit 1
