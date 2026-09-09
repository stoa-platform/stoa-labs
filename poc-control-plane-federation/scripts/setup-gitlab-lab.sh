#!/usr/bin/env bash
# setup-gitlab-lab.sh — PRÉPARER LE GITLAB DU LAB pour la preuve de l'adaptateur
# de forge (FORGE_KIND=gitlab, plan 2026-09-09-forge-agnostique-debug-branche.md).
#
# Idempotent et rejouable. Ce que ça pose, et POURQUOI chaque geste :
#   1. attendre /-/readiness — GitLab met 3 à 5 min à se reconfigurer au premier
#      démarrage ; un appel d'API avant rend un 502 qui n'apprend rien ;
#   2. un PAT de SERVICE (scopes api, read_user, write_repository) créé par
#      `gitlab-rails runner`, le seul moyen sans passer par l'UI — c'est
#      exactement ce que le client devra fournir : un COUPLE user/mot de passe
#      suffit pour `git`, pas pour /api/v4 ;
#   3. l'autorisation des webhooks vers des adresses LOCALES (jenkins:8080) —
#      refusés par défaut (SSRF), ce qui casserait provision-plan/apply sans
#      rien dire ;
#   4. un groupe `ci` et un projet `stoa-labs` — le MÊME chemin que sur le Gitea
#      du lab (GIT_REPO=ci/stoa-labs), pour que les suites se rejouent à
#      l'identique en changeant seulement FORGE_KIND et GIT_HOST.
#
# Le PAT est écrit dans un fichier 0600 (jamais sur stdout, jamais en argv) :
#   .env.gitlab-lab   → GITLAB_LAB_TOKEN=<pat>   (hors Git, voir .gitignore .env.*)
#
#   docker compose -f docker-compose.gitlab.yml up -d gitlab
#   bash scripts/setup-gitlab-lab.sh
#   . ./.env.gitlab-lab ; curl -sS -H "PRIVATE-TOKEN: $GITLAB_LAB_TOKEN" localhost:13080/api/v4/user
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

GL_URL="${GITLAB_LAB_URL:-http://localhost:13080}"
GL_CONTAINER="${GITLAB_LAB_CONTAINER:-poc-gitlab}"
GL_GROUP="${GITLAB_LAB_GROUP:-ci}"
GL_PROJECT="${GITLAB_LAB_PROJECT:-stoa-labs}"
ENV_OUT="${GITLAB_LAB_ENV:-.env.gitlab-lab}"
WAIT_S="${WAIT_S:-600}"

say()  { printf '\033[1;36m[gitlab-lab]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[gitlab-lab]\033[0m %s\n' "$*" >&2; exit 1; }

umask 077
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── 1. attendre que la forge soit prête ─────────────────────────────────────
docker ps --format '{{.Names}}' | grep -qx "$GL_CONTAINER" \
  || fail "conteneur $GL_CONTAINER absent — docker compose -f docker-compose.gitlab.yml up -d gitlab"
# ⚠ PAS /-/readiness : GitLab ne le sert qu'à sa liste blanche (127.0.0.0/8, vu
# de l'INTÉRIEUR du conteneur) ; depuis l'hôte on arrive par la passerelle Docker
# et il rend un 404 JSON même quand tout est debout (mesuré 2026-09-09 : un
# sondage a attendu pour rien). /api/v4/version répond 401 JSON sans jeton dès
# que Rails sert — c'est la sonde qui dit « vivant ».
say "attente de $GL_URL/api/v4/version (jusqu'à ${WAIT_S}s — le premier démarrage reconfigure tout)"
t=0
until hc=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' "$GL_URL/api/v4/version"); [ "$hc" = 200 ] || [ "$hc" = 401 ]; do
  sleep 10; t=$((t+10)); [ "$t" -lt "$WAIT_S" ] || fail "GitLab pas prêt après ${WAIT_S}s (dernier code $hc) : docker logs $GL_CONTAINER"
done
say "prête après ${t}s"

# ── 2. le PAT de service, ou sa relecture s'il existe ───────────────────────
# `gitlab-rails runner` est LENT (20-40 s : il charge Rails) mais c'est le seul
# chemin sans UI. Idempotent : un token du même nom est réutilisé, jamais
# recréé — sa VALEUR n'étant relisible qu'à la création, on la garde dans
# $ENV_OUT et on ne régénère que si ce fichier manque.
if [ -r "$ENV_OUT" ] && grep -q '^GITLAB_LAB_TOKEN=' "$ENV_OUT"; then
  # shellcheck disable=SC1090
  . "./$ENV_OUT"
  hc=$(curl -s -o "$TMP/user.json" -w '%{http_code}' -H "PRIVATE-TOKEN: ${GITLAB_LAB_TOKEN:-}" "$GL_URL/api/v4/user")
  if [ "$hc" = 200 ]; then
    say "PAT existant valide ($ENV_OUT) — utilisateur $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("username"))' "$TMP/user.json")"
  else
    say "PAT du fichier refusé (HTTP $hc) — régénération"; rm -f "$ENV_OUT"
  fi
fi
if [ ! -r "$ENV_OUT" ]; then
  say "création du PAT de service par gitlab-rails runner (20-40 s)"
  # Le token est imprimé UNE fois par rails, capturé dans un fichier 0600.
  # MESURÉ 2026-09-09 : quand le PREMIER boot meurt avant le seed (ici :
  # statement_timeout sous contention), les boots suivants voient un schéma déjà
  # présent et ne font que migrer — root n'est JAMAIS semé, et le runner meurt
  # « undefined method personal_access_tokens for nil ». On crée root s'il
  # manque, ce qui rend ce setup indépendant de l'histoire du conteneur.
  # Le script passe par STDIN (`runner -`) : ni mot de passe ni logique en argv.
  # `gitlab-rails runner -` ne lit PAS stdin (mesuré 17.11 : il cherche un fichier
  # nommé « - »). Le script est donc DÉPOSÉ dans le conteneur par stdin, puis joué
  # par son chemin, puis effacé : le mot de passe ne passe jamais en argv. Le runner
  # tourne sous `git` : un fichier root 0600 lui est « introuvable » (LoadError), d'où le chown.
  printf '%s\n' "${GITLAB_ROOT_PASSWORD:-Forge-Jetable-2026-Xk7q}" \
    | docker exec -i "$GL_CONTAINER" sh -c 'umask 077; cat > /tmp/stoa-lab-pat.pw && chown git /tmp/stoa-lab-pat.pw'
  docker exec -i "$GL_CONTAINER" sh -c 'umask 077; cat > /tmp/stoa-lab-pat.rb && chown git /tmp/stoa-lab-pat.rb' <<'RUBY'
u = User.find_by_username('root')
if u.nil?
  # Le seed du premier boot n'a pas eu lieu (mesuré 17.11 sous contention) :
  # on fabrique root comme le seed l'aurait fait — espace personnel rattaché à
  # l'organisation par défaut (17.x exige un namespace), mot de passe hors de
  # la liste des combinaisons « trop courantes » (celle-ci refuse « gitlab »).
  pw = File.read('/tmp/stoa-lab-pat.pw').chomp
  org = (Organizations::Organization.default_organization rescue nil)
  u = User.new(username: 'root', email: 'root@lab.example', name: 'Administrator',
               password: pw, password_confirmation: pw, admin: true, confirmed_at: Time.now)
  u.assign_personal_namespace(org) if u.respond_to?(:assign_personal_namespace) && org
  u.skip_confirmation! if u.respond_to?(:skip_confirmation!)
  u.save!
  STDERR.puts 'root cree (le seed du premier boot n avait pas eu lieu)'
end
u.personal_access_tokens.where(name: 'stoa-lab-service').each(&:revoke!)
t = u.personal_access_tokens.create!(name: 'stoa-lab-service', scopes: [:api, :read_user, :write_repository, :read_repository], expires_at: 365.days.from_now)
puts t.token
RUBY
  docker exec "$GL_CONTAINER" gitlab-rails runner /tmp/stoa-lab-pat.rb > "$TMP/pat" 2>"$TMP/pat.err"; rc=$?
  docker exec "$GL_CONTAINER" rm -f /tmp/stoa-lab-pat.rb /tmp/stoa-lab-pat.pw
  [ "$rc" -eq 0 ] || fail "gitlab-rails runner en échec (rc $rc) : $(grep -v 'kernel_require\|^\s*from ' "$TMP/pat.err" | head -c 600 | tr '\n' ' ')"
  PAT=$(tail -n1 "$TMP/pat" | tr -d '\r\n')
  [ -n "$PAT" ] || fail "PAT vide rendu par rails : $(cat "$TMP/pat.err")"
  printf 'GITLAB_LAB_TOKEN=%s\n' "$PAT" > "$ENV_OUT"; chmod 600 "$ENV_OUT"
  GITLAB_LAB_TOKEN="$PAT"; unset PAT
  say "PAT écrit dans $ENV_OUT (0600)"
fi
printf 'PRIVATE-TOKEN: %s\n' "$GITLAB_LAB_TOKEN" > "$TMP/hdr"
gl() { curl -sS -H @"$TMP/hdr" -H 'Content-Type: application/json' "$@"; }

# ── 3. webhooks vers des adresses locales ───────────────────────────────────
hc=$(gl -o "$TMP/settings.json" -w '%{http_code}' -X PUT "$GL_URL/api/v4/application/settings" \
      -d '{"allow_local_requests_from_web_hooks_and_services": true, "allow_local_requests_from_system_hooks": true}')
[ "$hc" = 200 ] || fail "application/settings HTTP $hc : $(head -c 200 "$TMP/settings.json")"
say "webhooks vers le réseau local autorisés (jenkins:8080)"

# ── 4. groupe + projet, idempotents ──────────────────────────────────────────
gid=$(gl "$GL_URL/api/v4/groups?search=$GL_GROUP" | python3 -c 'import json,sys
for g in json.load(sys.stdin):
    if g.get("path")==sys.argv[1]: print(g["id"]); break' "$GL_GROUP")
if [ -z "$gid" ]; then
  gid=$(gl -X POST "$GL_URL/api/v4/groups" -d "{\"name\":\"$GL_GROUP\",\"path\":\"$GL_GROUP\",\"visibility\":\"private\"}" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("id",""))')
  [ -n "$gid" ] || fail "création du groupe $GL_GROUP en échec"
  say "groupe $GL_GROUP créé (id $gid)"
else say "groupe $GL_GROUP présent (id $gid)"; fi

enc="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$GL_GROUP/$GL_PROJECT")"
hc=$(gl -o "$TMP/proj.json" -w '%{http_code}' "$GL_URL/api/v4/projects/$enc")
if [ "$hc" != 200 ]; then
  hc=$(gl -o "$TMP/proj.json" -w '%{http_code}' -X POST "$GL_URL/api/v4/projects" \
        -d "{\"name\":\"$GL_PROJECT\",\"path\":\"$GL_PROJECT\",\"namespace_id\":$gid,\"visibility\":\"private\",\"initialize_with_readme\":true,\"default_branch\":\"main\"}")
  [ "$hc" = 201 ] || fail "création du projet HTTP $hc : $(head -c 200 "$TMP/proj.json")"
  say "projet $GL_GROUP/$GL_PROJECT créé"
else say "projet $GL_GROUP/$GL_PROJECT présent"; fi
pid=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["id"])' "$TMP/proj.json")

# main est PROTÉGÉE par défaut (force push interdit : « pre-receive hook
# declined », mesuré) ; le harnais de bout en bout pousse NOTRE main par-dessus
# le README initial. Forge JETABLE : on l'autorise — chez le client, jamais.
hc=$(gl -o "$TMP/prot.json" -w '%{http_code}' -X PATCH "$GL_URL/api/v4/projects/$pid/protected_branches/main" -d '{"allow_force_push": true}')
case "$hc" in
  200) say "main : force push autorisé (forge jetable — le harnais y pousse notre main)" ;;
  404) say "main : pas (encore) protégée — rien à autoriser" ;;
  *)   fail "protected_branches/main HTTP $hc : $(head -c 200 "$TMP/prot.json")" ;;
esac

say "Terminé. GIT_HOST=$GL_URL GIT_REPO=$GL_GROUP/$GL_PROJECT (id $pid) FORGE_KIND=gitlab FORGE_API_AUTH=private-token"
say "Vu du réseau compose : GIT_HOST=http://gitlab:80"
