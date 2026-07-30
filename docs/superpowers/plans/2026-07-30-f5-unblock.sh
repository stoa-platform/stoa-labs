#!/bin/bash
# F5 — enveloppe des DEUX gestes exploitant, en une seule commande.
#
#   bash docs/superpowers/plans/2026-07-30-f5-unblock.sh
#
# Pourquoi une enveloppe plutôt que trois commandes à copier : l'étape 2 (le
# sabotage) DOIT échouer, et l'étape 3 ne doit surtout PAS être jouée si la
# restauration automatique n'a pas tenu. Enchaîner à la main revient à faire
# reposer cette règle sur la lecture correcte d'une sortie Ansible au mauvais
# moment. Ici elle est encodée : le script refuse de basculer si le filet n'est
# pas prouvé.
#
# Le script est IDEMPOTENT sur l'étape 1 (une PR déjà mergée est sautée) et
# s'arrête à la première anomalie.
set -uo pipefail

LABS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ANS="$LABS/ansible"
PUB_HEALTH="https://dev-wm.gostoa.dev/rest/apigateway/health"
PUB_INVOKE="https://dev-wm.gostoa.dev/gateway/accounts-read/1.0.0/accounts"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\n\033[31mARRÊT : %s\033[0m\n' "$*" >&2; exit 1; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>/dev/null || echo 000; }

# ── Étape 1 : merger la PR ───────────────────────────────────────────────────
say "Étape 1/3 — PR stoa #2825"
STATE="$(gh pr view 2825 --repo stoa-platform/stoa --json state -q .state 2>/dev/null || echo INCONNU)"
if [ "$STATE" = "MERGED" ]; then
  echo "  déjà mergée — on saute"
else
  gh pr merge 2825 --repo stoa-platform/stoa --squash --delete-branch \
    || die "le merge a échoué (état : $STATE)"
fi

# ── Étape 1bis : l'Application Argo, puis attendre backend-dev ───────────────
say "Étape 1bis — Application Argo et backend-dev"
if ! ssh worker-1 'sudo k3s kubectl get application -n argocd wm-backend-dev' >/dev/null 2>&1; then
  echo "  Application absente : on l'applique depuis le worktree"
  APP="$LABS/../stoa-f5/deploy/bootstrap/argocd/app-wm-backend-dev.yaml"
  [ -f "$APP" ] || die "manifeste introuvable : $APP"
  ssh worker-1 'sudo k3s kubectl apply -f -' < "$APP" || die "apply de l'Application échoué"
fi

echo "  attente du pod backend-dev (jusqu'à 5 min)…"
for i in $(seq 1 30); do
  R="$(ssh worker-1 'sudo k3s kubectl get deploy backend-dev -n wm -o jsonpath="{.status.readyReplicas}"' 2>/dev/null)"
  [ "${R:-0}" -ge 1 ] 2>/dev/null && { echo "  backend-dev prêt (essai $i)"; break; }
  sleep 10
done
[ "${R:-0}" -ge 1 ] 2>/dev/null || die "backend-dev n'est pas prêt — ne pas basculer sans backend réel"

# La ClusterIP épinglée doit être celle que le rôle Ansible cible.
say "Vérification — la ClusterIP épinglée correspond au rôle"
LIVE="$(ssh worker-1 'sudo k3s kubectl get svc wm-apigateway -n wm -o jsonpath="{.spec.clusterIP}"' 2>/dev/null)"
WANT="$(grep -E '^wm_cutover_upstream:' "$ANS/roles/caddy_wm_cutover/defaults/main.yml" | tr -d '"' | awk '{print $2}')"
echo "  cluster : $LIVE   rôle : $WANT"
[ -n "$LIVE" ] && [ "$LIVE" = "$WANT" ] \
  || die "désaccord de ClusterIP — corriger defaults/main.yml ET service.yaml avant de basculer"

# ── Étape 2 : sabotage — la restauration automatique doit JOUER ──────────────
say "Étape 2/3 — SABOTAGE : la porte doit ROUGIR et le filet tenir"
echo "  (un échec Ansible est ATTENDU ici)"
cd "$ANS" || die "répertoire ansible introuvable"
ansible-playbook -i inventory.contabo.ini wm-cutover.yml -e wm_cutover_verify_expect=599
RC=$?

if [ $RC -eq 0 ]; then
  die "le sabotage a RÉUSSI alors qu'il devait échouer : la porte ne rougit pas.
       Une porte qui ne rougit jamais ne prouve rien — ne pas basculer."
fi
echo "  le playbook a échoué comme prévu (code $RC). Le filet a-t-il tenu ?"

H="$(code "$PUB_HEALTH")"
echo "  $PUB_HEALTH -> $H  (200 attendu : le Docker de worker-3 sert de nouveau)"
[ "$H" = "200" ] || die "la restauration automatique N'A PAS tenu (health = $H).
       Le nom public est dégradé. Restaurer à la main :
         ansible-playbook -i inventory.contabo.ini wm-cutover.yml -e wm_cutover_rollback=true
       NE PAS basculer sur un filet non prouvé."
echo "  filet PROUVÉ : bascule ratée → retour automatique vérifié."

# ── Étape 3 : la vraie bascule ───────────────────────────────────────────────
say "Étape 3/3 — LA BASCULE"
ansible-playbook -i inventory.contabo.ini wm-cutover.yml || die "la bascule a échoué et s'est annulée (voir ci-dessus).
       Le trafic public sert de nouveau depuis Docker. Rien à réparer."

say "Portes, relues à la main"
printf '  P-a  %-58s -> %s\n' "invocation data-plane" "$(code "$PUB_INVOKE")"
for p in /rest/apigateway/apis /rest/apigateway/health /apigatewayui/ /; do
  printf '  P-b  %-58s -> %s\n' "$p (404 attendu)" "$(code "https://dev-wm.gostoa.dev$p")"
done
printf '  P-b  %-58s -> %s\n' "dev-wm-ui.gostoa.dev/ (404 attendu)" "$(code https://dev-wm-ui.gostoa.dev/)"
printf '  garde flotte %-50s -> %s\n' "dev-gw-k3s.gostoa.dev/health (200 attendu)" "$(code https://dev-gw-k3s.gostoa.dev/health)"

say "TERMINÉ — rendre la main à l'agent"
echo "  Il reste : T2 (invocation interne), le run de sauvegarde du ns wm,"
echo "  la contre-épreuve de rollback (AVANT tout retrait), l'archive froide"
echo "  relue sur worker-2, la décommission et P-c, puis la re-mesure du cycle."
