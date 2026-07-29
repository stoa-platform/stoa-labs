# F4 — La chaîne de publication réelle : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal :** un push de spec OpenAPI sur `banking-demo/accounts-api` (Gitea)
déclenche un build Jenkins qui publie l'API sur la gateway webMethods du
cluster, la scope à sa team, avec identifiants lus dans Vault par identité de
pod — porte et contre-épreuves du GOAL jouées et documentées.

**Architecture :** motif F1 rejoué (GenericTrigger + webhook + statut de
commit) sur un 2ᵉ job ; podTemplate deux conteneurs (`vault` pour le login
G-c, `jenkins-go` pour labctl + curl/python3) ; `labctl apply` lit les creds
gateway dans `secret/ci/gateways/wm-cluster` ; scoping par
`POST /assets/team` côté pipeline (UUID d'accessProfile) ; NetworkPolicy ES
par PR `stoa`. Spéc : `docs/superpowers/specs/2026-07-29-f4-chaine-publication-design.md`.

**Tech stack :** k3s v1.34.5, Jenkins (`ci/jenkins-go:v1` par digest,
labctl + ansible-core + python3), Vault 1.18 (kv-v2, auth k8s), Gitea 1.22
(API + webhooks), wM API Gateway trial 10.15 (ns `wm`), gh CLI (PR
`stoa-platform/stoa`), ssh (alias worker-1..5).

## Global Constraints

- **Règle de sûreté n°1** : ne rien changer sur worker-3 ; après chaque tâche,
  `curl -s -o /dev/null -w '%{http_code}' https://dev-wm.gostoa.dev/` depuis le
  poste → `200` (ou 502 transitoire dans la fenêtre de restart du cron —
  revérifier 5 min plus tard avant de conclure).
- **Aucun secret affiché** : toute valeur sensible → fichier root-only du nœud
  (`umask 077`), jamais stdout, jamais argv d'un `ssh` — les scripts partent en
  `scp` et s'exécutent par `ssh worker-1 'sudo bash /tmp/<script>'`.
- **Gestes bloqués par le classifieur** (merge PR, quorum Vault) : préparer,
  faire exécuter par l'exploitant via `!`, vérifier derrière.
- Accès cluster : `ssh worker-1 'sudo k3s kubectl -n <ns> …'` — le kubectl
  local du poste pointe un AUTRE cluster (sto-k8s OVH), ne jamais l'utiliser.
- Checkout `~/stoa-platform/stoa` en retard : worktree neuf basé `origin/main`.
- **Frontière des dépôts** : tous les commits de ce plan vont dans `stoa-labs`
  (ce dépôt). Seule T8 écrit dans le dépôt produit `stoa` (org GitHub
  `stoa-platform`) via le worktree `~/stoa-platform/stoa-f4` — dont le
  `plan.md` est le plan de sprint plateforme (Linear, périmé), PAS ce plan.
- Aucun Ingress/NodePort dans `wm` ; jamais `Force` dans ArgoCD.
- Commits : conventionnels, français, `-s` (DCO) ; PR stoa squash-merge,
  rebase si `BEHIND`.
- Timeout du job publish < 20 min (un seul cycle trial) ; jeton webhook frappé
  par `openssl rand -hex 24` sur worker-1, JAMAIS en Git (placeholder
  `__WEBHOOK_TOKEN__` dans le XML versionné).
- Identifiants admin gateway (`Administrator`/défaut trial) : déjà publics dans
  les docs du dépôt, mais on ne les tape plus dans un argv de session — ils
  vivent dans les scripts scp'és et dans Vault.

---

### Tâche 0 : Vérifications terrain

**Files :** aucun.

**Interfaces — Produces :** gateway saine, outillage confirmé (curl dans les
pods jenkins/ES), heure du dernier restart notée (pour caler les fenêtres).

- [x] **Step 1 : socle et gateway up**

```bash
ssh worker-1 'sudo k3s kubectl -n ci get pods; sudo k3s kubectl -n wm get pods'
```

Attendu : gitea-0, jenkins, vault-0 Ready 1/1 ; wm-elasticsearch-0 Ready ;
wm-apigateway Running (0/1 possible si fenêtre de démarrage).

- [x] **Step 2 : curl disponible dans le pod jenkins + health gateway depuis le cluster**

```bash
ssh worker-1 'sudo k3s kubectl -n ci exec deploy/jenkins -- curl --version | head -1'
ssh worker-1 'sudo k3s kubectl -n ci exec deploy/jenkins -- curl -s -o /dev/null \
  -w "%{http_code}\n" -H "Accept: application/json" \
  http://wm-apigateway.wm.svc:5555/rest/apigateway/health'
```

Attendu : version curl, puis `200` (sinon attendre la fin de fenêtre de
restart `*/20` et rejouer). Si curl absent du pod jenkins : repli
`kubectl -n wm exec wm-elasticsearch-0 -- curl …` pour tous les gestes
in-cluster du plan.

- [x] **Step 3 : jobs Jenkins existants + assertion zéro secret (état initial)**

```bash
ssh worker-1 'sudo k3s kubectl -n ci exec deploy/jenkins -- curl -s http://localhost:8080/api/json?tree=jobs[name]'
ssh worker-1 'sudo k3s kubectl -n ci exec deploy/jenkins -- sh -c \
  "test ! -f /var/jenkins_home/credentials.xml && echo ZERO-SECRET-OK"'
```

Attendu : `probe` seul job ; `ZERO-SECRET-OK`.

- [x] **Step 4 : noter l'heure du dernier restart gateway** (caler les preuves
hors fenêtre morte)

```bash
ssh worker-1 'sudo k3s kubectl -n wm get pod -l app=wm-apigateway \
  -o jsonpath="{.items[0].metadata.creationTimestamp}{\"\n\"}"'
```

- [x] **Step 5 : garde worker-3** (`curl` poste → dev-wm.gostoa.dev, cf.
contraintes globales).

### Tâche 1 : Spike Teams sur la gateway cluster — le maillon non prouvé

**Files :**
- Create : `docs/superpowers/plans/2026-07-29-f4-teams-bootstrap.sh` (copie
  versionnée du script exécuté, shapes RÉELS constatés en commentaire)

**Interfaces — Produces :** Teams actives ; accessProfiles `banking-demo` et
`insurance-demo` (UUIDs notés) ; users `svc-banking-demo`/`svc-insurance-demo`
(mots de passe dans `/root/f4-teams.env` de worker-1, 0600) ; shape
`POST /assets/team` VALIDÉ sur une API jetable ; survie au restart mesurée.
La Tâche 3 (Jenkinsfile) consomme le nom de team `banking-demo` ; la Tâche 6
consomme `/root/f4-teams.env`.

**Méthode :** c'est un spike — les shapes exacts (users/groups/accessProfiles,
activation Teams) sont best-effort du spike #1 (2026-07-09, non rejoués dans ce
dépôt) : chaque POST est précédé d'un GET d'observation ; si un shape diffère,
on ajuste ET on consigne le shape réel dans le script versionné. Tous les
appels partent du pod jenkins (`kubectl -n ci exec deploy/jenkins -- curl`),
enrobés dans un script scp'é sur worker-1 (les creds admin ne passent pas en
argv de session).

- [x] **Step 1 : préparer et pousser le script d'observation**

Écrire localement `/tmp/f4-teams-probe.sh` :

```bash
#!/bin/bash
# F4 T1 — observation Teams (lecture seule), exécuté sur worker-1.
set -eu
K="k3s kubectl -n ci exec deploy/jenkins --"
B=http://wm-apigateway.wm.svc:5555/rest/apigateway
A='Administrator:manage'
H='Accept: application/json'
echo "== extendedSettings (chercher enableTeamWork) =="
$K curl -s -u "$A" -H "$H" "$B/configurations/extendedSettings" | head -c 2000; echo
echo "== accessProfiles =="
$K curl -s -u "$A" -H "$H" "$B/accessProfiles" | head -c 2000; echo
echo "== users =="
$K curl -s -u "$A" -H "$H" "$B/users" | head -c 2000; echo
echo "== groups =="
$K curl -s -u "$A" -H "$H" "$B/groups" | head -c 2000; echo
```

```bash
scp /tmp/f4-teams-probe.sh worker-1:/tmp/f4-teams-probe.sh
ssh worker-1 'sudo bash /tmp/f4-teams-probe.sh'
```

Attendu : quatre blocs JSON (ou 404 explicites). Noter : le nom exact du
réglage Teams (`enableTeamWork` attendu), le shape des accessProfiles
(`accessProfiles` vs `accessProfile`), users/groups.

- [x] **Step 2 : activer Teams si inactif** — d'après l'observation, PUT du
réglage (shape à adapter au constat du Step 1) :

```bash
# Dans un script scp'é f4-teams-enable.sh, même en-tête K/B/A/H :
$K curl -s -u "$A" -H "$H" -H 'Content-Type: application/json' -X PUT \
  -d '{"extendedSettings":[{"name":"enableTeamWork","value":"true"}]}' \
  "$B/configurations/extendedSettings" ; echo
```

Attendu : 200/204. Relire (GET) : `enableTeamWork=true`. Si le réglage exige
un redémarrage : le cycle `*/20` le fournit — attendre le prochain restart et
relire.

- [x] **Step 3 : créer users, groupes, accessProfiles** — script
`f4-teams-bootstrap.sh` scp'é (génère les mots de passe, 0600, idempotent —
chaque création testée par GET avant POST) :

```bash
#!/bin/bash
# F4 T1 — bootstrap des 2 teams de démonstration. Shapes: à confirmer au GET
# du Step 1 ; corriger ici et consigner. Exécuté sur worker-1 (root).
set -eu
umask 077
K="k3s kubectl -n ci exec deploy/jenkins --"
B=http://wm-apigateway.wm.svc:5555/rest/apigateway
A='Administrator:manage'
H='Accept: application/json'
J='Content-Type: application/json'
ENV=/root/f4-teams.env
touch "$ENV"; chmod 600 "$ENV"
for T in banking-demo insurance-demo; do
  U="svc-$T"; G="$T-devs"
  # mot de passe : généré une fois, conservé root-only, jamais affiché
  if ! grep -q "^P_${T//-/_}=" "$ENV"; then
    echo "P_${T//-/_}=$(openssl rand -hex 12)" >> "$ENV"
  fi
  P=$(grep "^P_${T//-/_}=" "$ENV" | cut -d= -f2)
  $K curl -s -u "$A" -H "$H" -H "$J" -X POST \
    -d "{\"firstName\":\"svc\",\"lastName\":\"$T\",\"loginId\":\"$U\",\"password\":\"$P\"}" \
    "$B/users" -o /dev/null -w "user $U: %{http_code}\n"
  $K curl -s -u "$A" -H "$H" -H "$J" -X POST \
    -d "{\"groupName\":\"$G\",\"users\":[\"$U\"]}" \
    "$B/groups" -o /dev/null -w "group $G: %{http_code}\n"
  $K curl -s -u "$A" -H "$H" -H "$J" -X POST \
    -d "{\"name\":\"$T\",\"groups\":[\"$G\"],\"privileges\":[\"Manage APIs\"]}" \
    "$B/accessProfiles" -o /dev/null -w "accessProfile $T: %{http_code}\n"
done
echo "== relecture =="
$K curl -s -u "$A" -H "$H" "$B/accessProfiles"
```

Attendu : 200/201 par objet (ou 4xx « existe déjà » au rejeu) ; la relecture
donne les **UUIDs** des deux accessProfiles — les noter. **Si un shape est
refusé (400)** : lire le corps d'erreur, corriger le payload, consigner le
shape réel en commentaire du script versionné. (Doute connu : privilège
`Manage APIs` vs `Manage applications` — trancher ici sur le corps de
réponse.)

- [x] **Step 4 : valider `POST /assets/team` sur une API jetable**

```bash
# f4-teams-shape.sh — import minimal, assignation, relecture, nettoyage.
# APIID/UUID récupérés par python3 (présent dans le pod jenkins : ansible-core).
$K curl -s -u "$A" -H "$H" -H "$J" -X POST \
  -d '{"apiName":"f4-spike-jetable","apiVersion":"0.0.1","type":"openapi","apiDefinition":{"openapi":"3.0.0","info":{"title":"f4 spike","version":"0.0.1"},"paths":{}}}' \
  "$B/apis"
# → noter "id" dans la réponse (APIID)
$K curl -s -u "$A" -H "$H" -H "$J" -X POST \
  -d '{"assetIds":["<APIID>"],"newTeams":["<UUID banking-demo>"]}' \
  "$B/assets/team" -w "\nassets/team: %{http_code}\n"
$K curl -s -u "$A" -H "$H" "$B/apis/<APIID>"     # relecture : team présente ?
```

Attendu : `assets/team: 200` (ou 201) et la relecture porte la team (noter le
NOM DU CHAMP — `teams` attendu ; c'est lui que le Jenkinsfile relira).
Contre-essai : rejouer avec le NOM au lieu de l'UUID → 400 attendu (confirme
le piège documenté). Bonus si peu coûteux : `GET /apis` en
`svc-insurance-demo` → l'API jetable absente (pré-preuve T6).

- [x] **Step 5 : mesurer la survie au restart** — après le prochain cycle
`*/20` (≤ 20 min) :

```bash
ssh worker-1 'sudo bash /tmp/f4-teams-probe.sh'
```

Constat à consigner : users/groups/accessProfiles encore là (état ES) ou
disparus (état IS local → le bootstrap se rejoue avant chaque preuve, dit la
spéc D3). L'assignation de team de l'API jetable doit, elle, survivre (ES).

- [x] **Step 6 : nettoyer l'API jetable**

```bash
$K curl -s -u "$A" -H "$H" -X DELETE "$B/apis/<APIID>" -w "delete: %{http_code}\n"
```

- [x] **Step 7 : versionner le script avec les shapes réels + commit**

```bash
git add docs/superpowers/plans/2026-07-29-f4-teams-bootstrap.sh
git commit -s -m "feat(f4): bootstrap Teams gateway cluster — shapes constatés live (spike T1)"
```

### Tâche 2 : Geste exploitant — creds wM dans Vault (quorum)

**Files :**
- Create : `docs/superpowers/plans/2026-07-29-f4-provision-wm-creds.sh`

**Interfaces — Produces :** `secret/ci/gateways/wm-cluster`
(`username`/`password`), lisible par la policy `jenkins-agent` inchangée —
consommé par labctl (T3) via `VAULT_PREFIX=ci`.

- [x] **Step 1 : écrire le script (motif quorum F1, étapes 1-3 et 6
identiques au `2026-07-28-f1-provision-status-token.sh`)** — seule l'étape
d'écriture change :

```sh
#!/bin/sh
# F4 — à exécuter DANS vault-0, PAR L'EXPLOITANT : $1 $2 = 2 clés (quorum 2/3).
# Régénère un jeton racine ÉPHÉMÈRE, écrit les creds gateway wM du cluster
# dans secret/ci/gateways/wm-cluster, puis RÉVOQUE. Aucun jeton au repos.
#   scp docs/superpowers/plans/2026-07-29-f4-provision-wm-creds.sh worker-1:/tmp/f4-wm.sh
#   ssh -t worker-1 'sudo k3s kubectl -n ci exec -i vault-0 -- sh -c "cat > /tmp/f4w.sh && chmod 700 /tmp/f4w.sh" < /tmp/f4-wm.sh; \
#     read -r -s -p "Cle 1/2 : " K1; echo; read -r -s -p "Cle 2/2 : " K2; echo; \
#     sudo k3s kubectl -n ci exec vault-0 -- sh /tmp/f4w.sh "$K1" "$K2"; unset K1 K2; \
#     sudo k3s kubectl -n ci exec vault-0 -- rm -f /tmp/f4w.sh; rm -f /tmp/f4-wm.sh'
set -eu
K1="$1"; K2="$2"
# [étapes 1-3 : generate-root -cancel/-init, quorum K1 K2, decode → VAULT_TOKEN
#  — reprises À L'IDENTIQUE du script F1, y compris les reflis d'erreur]
echo "etape 4/5 : ecriture Vault secret/ci/gateways/wm-cluster…"
vault kv put secret/ci/gateways/wm-cluster \
  username=Administrator password=manage >/dev/null \
  || { vault token revoke -self >/dev/null 2>&1 || true; echo "ECHEC etape 4"; exit 1; }
echo "etape 5/5 : revocation du jeton racine ephemere…"
vault token revoke -self >/dev/null \
  || { echo "AVERTISSEMENT : revocation a verifier"; exit 1; }
echo "OK: secret/ci/gateways/wm-cluster ecrit, jeton revoque"
```

(À l'écriture réelle du fichier, recopier les étapes 1-3 complètes du script
F1 — pas de raccourci.)

- [ ] **Step 2 : commit du script**, puis **demander l'exécution à
l'exploitant** (commande `!` du bloc d'usage). Attendu : `OK: … ecrit, jeton
revoque`.

- [ ] **Step 3 : vérifier la lecture PAR IDENTITÉ DE POD** (Job k8s jetable,
SA `jenkins-agent` — n'affiche que le username) :

```bash
ssh worker-1 'sudo k3s kubectl -n ci apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata: {name: f4-vault-check, namespace: ci}
spec:
  ttlSecondsAfterFinished: 600
  backoffLimit: 0
  template:
    spec:
      serviceAccountName: jenkins-agent
      restartPolicy: Never
      containers:
        - name: check
          image: hashicorp/vault:1.18
          env: [{name: VAULT_ADDR, value: "http://vault.ci.svc.cluster.local:8200"}]
          command: ["/bin/sh","-c"]
          args:
            - VT=\$(vault write -field=token auth/kubernetes/login role=jenkins-agent
              jwt=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token));
              U=\$(VAULT_TOKEN=\$VT vault kv get -field=username secret/ci/gateways/wm-cluster);
              echo "wm-cluster username=\$U (password non affiche)"
EOF'
ssh worker-1 'sudo k3s kubectl -n ci wait --for=condition=complete job/f4-vault-check --timeout=120s \
  && sudo k3s kubectl -n ci logs job/f4-vault-check'
```

Attendu : `wm-cluster username=Administrator (password non affiche)`.

### Tâche 3 : Repo d'équipe `banking-demo/accounts-api` + webhook

**Files :**
- Create : `docs/superpowers/plans/2026-07-29-f4-publish-Jenkinsfile.groovy`
  (copie versionnée) — le vivant part dans Gitea
- Create : `docs/superpowers/plans/2026-07-29-f4-gitea-setup.sh` (copie
  versionnée du geste)

**Interfaces — Consumes :** team `banking-demo` (T1), chemin Vault
`secret/ci/gateways/wm-cluster` (T2). **Produces :** repo
`banking-demo/accounts-api` (main : `Jenkinsfile`, `stoa-publish.yaml`,
`apis/accounts-read.openapi.yaml`) ; webhook armé vers
`jenkins.ci.svc.cluster.local:8080/generic-webhook-trigger/invoke?token=<T>` ;
jeton dans `/root/f4-webhook.token` (worker-1, 0600) — consommé par T4.

- [x] **Step 1 : le Jenkinsfile** (contenu intégral, versionné puis poussé) :

```groovy
// banking-demo/accounts-api — F4 : publication réelle sur la gateway cluster.
// Identifiants wM et PAT Gitea lus dans Vault PAR IDENTITÉ DE POD (G-c) :
// aucun secret statique dans Jenkins ni dans ce fichier. Copie versionnée :
// stoa-labs docs/superpowers/plans/2026-07-29-f4-publish-Jenkinsfile.groovy.
def postStatus(String sha, String state, String buildUrl) {
  sh """
    set -e
    set +x
    VT=\$(vault write -address=\$VAULT_ADDR -field=token \\
      auth/kubernetes/login role=jenkins-agent \\
      jwt=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token))
    GT=\$(VAULT_TOKEN=\$VT vault kv get -address=\$VAULT_ADDR -field=token secret/ci/probe-status)
    wget -q -O /dev/null \\
      --header "Authorization: token \$GT" \\
      --header 'Content-Type: application/json' \\
      --post-data "{\\"state\\":\\"${state}\\",\\"context\\":\\"jenkins/publish\\",\\"target_url\\":\\"${buildUrl}\\",\\"description\\":\\"publish ${state}\\"}" \\
      "http://gitea.ci.svc.cluster.local:3000/api/v1/repos/banking-demo/accounts-api/statuses/${sha}"
  """
}

properties([buildDiscarder(logRotator(numToKeepStr: '25')), disableConcurrentBuilds()])

podTemplate(serviceAccount: 'jenkins-agent', containers: [
  containerTemplate(name: 'vault', image: 'hashicorp/vault:1.18', command: 'sleep', args: '9999',
    envVars: [envVar(key: 'VAULT_ADDR', value: 'http://vault.ci.svc.cluster.local:8200')]),
  // jenkins-go = l'image du contrôleur : labctl + python3 (via ansible-core) +
  // curl. Par digest (v1). Elle sert ici de boîte à outils, pas de Jenkins.
  containerTemplate(name: 'labctl',
    image: 'localhost:30300/ci/jenkins-go:v1@sha256:00ad5591be6f1c7b4eccfd7e498abe5e947dc07f01e4d7a247005b65ef0c565b',
    command: 'sleep', args: '9999',
    envVars: [envVar(key: 'VAULT_ADDR', value: 'http://vault.ci.svc.cluster.local:8200'),
              envVar(key: 'VAULT_KV_MOUNT', value: 'secret'),
              envVar(key: 'VAULT_PREFIX', value: 'ci'),
              envVar(key: 'WM_BASE', value: 'http://wm-apigateway.wm.svc:5555/rest/apigateway'),
              envVar(key: 'TEAM', value: 'banking-demo'),
              envVar(key: 'API_NAME', value: 'accounts-read')])
]) {
  node(POD_LABEL) {
    timeout(time: 18, unit: 'MINUTES') {
      def scmVars = checkout scm
      def sha = env.GWT_AFTER ?: scmVars.GIT_COMMIT
      container('vault') {
        postStatus(sha, 'pending', env.BUILD_URL)
        // Login G-c : jeton Vault éphémère + creds wM → fichiers 0600 du
        // workspace (partagé entre conteneurs du pod), jamais affichés.
        sh '''
          set -e
          set +x
          umask 077
          vault write -address=$VAULT_ADDR -field=token \
            auth/kubernetes/login role=jenkins-agent \
            jwt=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) > .vt
          VAULT_TOKEN=$(cat .vt) vault kv get -address=$VAULT_ADDR \
            -field=username secret/ci/gateways/wm-cluster > .wmu
          VAULT_TOKEN=$(cat .vt) vault kv get -address=$VAULT_ADDR \
            -field=password secret/ci/gateways/wm-cluster > .wmp
        '''
      }
      try {
        container('labctl') {
          stage('Attendre la gateway (cycle trial)') {
            sh '''
              set -e
              set +x
              for i in $(seq 1 48); do
                code=$(curl -s -o /dev/null -w '%{http_code}' \
                  -u "$(cat .wmu):$(cat .wmp)" -H 'Accept: application/json' \
                  "$WM_BASE/health" || true)
                [ "$code" = "200" ] && { echo "gateway prete (essai $i)"; exit 0; }
                sleep 10
              done
              echo "gateway indisponible apres 8 min"; exit 1
            '''
          }
          stage('Publier (labctl apply)') {
            sh '''
              set -e
              set +x
              export VAULT_TOKEN_FILE=$PWD/.vt
              labctl apply -f stoa-publish.yaml
            '''
          }
          stage('Scoper la team + relire') {
            sh '''
              set -e
              set +x
              AUTH="$(cat .wmu):$(cat .wmp)"
              H='Accept: application/json'
              APIID=$(curl -sf -u "$AUTH" -H "$H" "$WM_BASE/apis" | python3 -c '
import json,sys,os
d=json.load(sys.stdin); items=d.get("apiResponse",d)
if isinstance(items,dict): items=[items]
for it in items:
    a=it.get("api",it)
    if a.get("apiName")==os.environ["API_NAME"]: print(a["id"]); break
')
              test -n "$APIID" || { echo "API introuvable apres apply"; exit 1; }
              TID=$(curl -sf -u "$AUTH" -H "$H" "$WM_BASE/accessProfiles" | python3 -c '
import json,sys,os
d=json.load(sys.stdin)
profs=d.get("accessProfiles") or d.get("accessProfile") or d
if isinstance(profs,dict): profs=[profs]
for p in profs:
    if p.get("name")==os.environ["TEAM"]: print(p["id"]); break
')
              test -n "$TID" || { echo "accessProfile $TEAM introuvable"; exit 1; }
              code=$(curl -s -o /tmp/team.out -w '%{http_code}' -u "$AUTH" -H "$H" \
                -H 'Content-Type: application/json' -X POST \
                -d "{\\"assetIds\\":[\\"$APIID\\"],\\"newTeams\\":[\\"$TID\\"]}" \
                "$WM_BASE/assets/team")
              case "$code" in 200|201) echo "assets/team: $code";; \
                *) echo "assets/team REFUSE: $code"; cat /tmp/team.out; exit 1;; esac
              # relecture obligatoire : un 200 wM ne prouve rien
              curl -sf -u "$AUTH" -H "$H" "$WM_BASE/apis/$APIID" | python3 -c "
import json,sys
a=json.load(sys.stdin).get('apiResponse',{}).get('api',{})
teams=a.get('teams') or []
assert any('$TID' in str(t) for t in teams), 'team absente a la relecture: %r' % (teams,)
print('team relue OK sur', a.get('apiName'))
"
            '''
          }
        }
        container('vault') { postStatus(sha, 'success', env.BUILD_URL) }
      } catch (e) {
        container('vault') { postStatus(sha, 'failure', env.BUILD_URL) }
        throw e
      }
    }
  }
}
```

*Nota (à ajuster depuis T1)* : le champ relu (`teams`) et le shape de
`/accessProfiles` doivent correspondre au constat du spike — corriger le
Jenkinsfile AVANT le premier push si T1 a montré autre chose.

- [x] **Step 2 : le manifeste `stoa-publish.yaml`** (poussé dans le repo) :

```yaml
# banking-demo/accounts-api — manifeste labctl (cible unique : gateway cluster).
# Les credentials ci-dessous sont des PLACEHOLDERS : labctl les REMPLACE par
# secret/ci/gateways/wm-cluster (VAULT_PREFIX=ci, jeton par identité de pod).
apiVersion: labctl.stoa.io/v1
kind: FederationTarget
name: accounts-read
contract: ./apis/accounts-read.openapi.yaml
# Pas de backend réel en cluster : la porte F4 est la publication scopée,
# l'invocation data-plane appartient à F5 (trafic réel). Nom interne honnête :
backendUrl: http://backend-dev.wm.svc.cluster.local:8080/accounts
targets:
  - name: wm-cluster
    type: webmethods
    adminUrl: http://wm-apigateway.wm.svc:5555
    gatewayUrl: http://wm-apigateway.wm.svc:5555
    credentials:
      username: vault-resolved
      password: vault-resolved
```

- [x] **Step 3 : le geste Gitea** — `f4-gitea-setup.sh`, scp'é et exécuté sur
worker-1 (`sudo bash`). Les fichiers du repo sont scp'és à côté
(`/tmp/f4-repo/{Jenkinsfile,stoa-publish.yaml,apis/accounts-read.openapi.yaml}`
— le contrat copié de
`poc-control-plane-federation/apis/accounts-read.openapi.yaml`) :

```bash
#!/bin/bash
# F4 T3 — org + repo + contenu + webhook, via l'API Gitea (localhost:30300).
# Idempotent. Exécuté sur worker-1 (root). Le jeton webhook est frappé ICI et
# ne quitte jamais le nœud (/root/f4-webhook.token, 0600).
set -eu
umask 077
G=http://localhost:30300/api/v1
CRED='ci:ci-bootstrap'   # bootstrap — rotation en fin de passe (T9)
J='Content-Type: application/json'
TOKF=/root/f4-webhook.token
[ -s "$TOKF" ] || openssl rand -hex 24 > "$TOKF"
T=$(cat "$TOKF")
# org (422 = existe déjà : sain au rejeu)
curl -s -u "$CRED" -H "$J" -X POST -d '{"username":"banking-demo","visibility":"public"}' \
  "$G/orgs" -o /dev/null -w "org: %{http_code}\n"
# repo public (lecture anonyme requise : checkout Jenkins sans credential)
curl -s -u "$CRED" -H "$J" -X POST -d '{"name":"accounts-api","private":false,"default_branch":"main","auto_init":true}' \
  "$G/orgs/banking-demo/repos" -o /dev/null -w "repo: %{http_code}\n"
# contenu : création OU mise à jour (sha requis si le fichier existe)
put_file() { # $1=chemin repo  $2=fichier local
  BODY=$(base64 -w0 < "$2")
  SHA=$(curl -s -u "$CRED" "$G/repos/banking-demo/accounts-api/contents/$1" \
    | sed -n 's/.*"sha":"\([^"]*\)".*/\1/p' | head -1)
  if [ -n "$SHA" ]; then
    curl -s -u "$CRED" -H "$J" -X PUT \
      -d "{\"content\":\"$BODY\",\"message\":\"feat: $1 (F4)\",\"sha\":\"$SHA\"}" \
      "$G/repos/banking-demo/accounts-api/contents/$1" -o /dev/null -w "put $1: %{http_code}\n"
  else
    curl -s -u "$CRED" -H "$J" -X POST \
      -d "{\"content\":\"$BODY\",\"message\":\"feat: $1 (F4)\"}" \
      "$G/repos/banking-demo/accounts-api/contents/$1" -o /dev/null -w "post $1: %{http_code}\n"
  fi
}
put_file Jenkinsfile /tmp/f4-repo/Jenkinsfile
put_file stoa-publish.yaml /tmp/f4-repo/stoa-publish.yaml
put_file apis/accounts-read.openapi.yaml /tmp/f4-repo/apis/accounts-read.openapi.yaml
# webhook push → Jenkins (allowlist Gitea = jenkins.ci.svc.cluster.local)
curl -s -u "$CRED" -H "$J" -X POST -d "{\"type\":\"gitea\",\"active\":true,\"events\":[\"push\"],
  \"config\":{\"url\":\"http://jenkins.ci.svc.cluster.local:8080/generic-webhook-trigger/invoke?token=$T\",\"content_type\":\"json\"}}" \
  "$G/repos/banking-demo/accounts-api/hooks" -o /dev/null -w "hook: %{http_code}\n"
echo "OK — jeton webhook dans $TOKF (jamais affiche)"
```

```bash
scp -r /tmp/f4-repo worker-1:/tmp/f4-repo
scp docs/superpowers/plans/2026-07-29-f4-gitea-setup.sh worker-1:/tmp/f4-gitea-setup.sh
ssh worker-1 'sudo bash /tmp/f4-gitea-setup.sh'
```

Attendu : `org: 201` (ou 422 au rejeu), `repo: 201`, trois `post …: 201`,
`hook: 201`. **Si Gitea refuse l'URL du hook, s'arrêter : c'est l'allowlist
qui parle.**

- [x] **Step 4 : commit des copies versionnées**

```bash
git add docs/superpowers/plans/2026-07-29-f4-publish-Jenkinsfile.groovy \
        docs/superpowers/plans/2026-07-29-f4-gitea-setup.sh
git commit -s -m "feat(f4): repo d'équipe banking-demo/accounts-api — Jenkinsfile, manifeste, geste Gitea"
```

### Tâche 4 : Job Jenkins `publish-accounts` + rétention des builds

**Files :**
- Create : `docs/superpowers/plans/2026-07-29-f4-jenkins-publish-job.xml`
  (placeholder `__WEBHOOK_TOKEN__`)

**Interfaces — Consumes :** `/root/f4-webhook.token` (T3). **Produces :** job
`publish-accounts` armé ; rétention 25 builds sur `publish-accounts` ET
`probe`.

- [x] **Step 1 : le XML** — copie du XML probe F1 avec : description F4, URL
SCM `http://gitea.ci.svc.cluster.local:3000/banking-demo/accounts-api.git`,
mêmes `genericVariables` (`GWT_REF`/`GWT_AFTER`), même filtre
`^refs/heads/main$`, `<token>__WEBHOOK_TOKEN__</token>`, `scriptPath
Jenkinsfile`, `lightweight true`. (Reprendre le fichier
`2026-07-28-jenkins-probe-job.xml` intégralement et n'éditer que ces champs.)

- [x] **Step 2 : poser le job** — depuis worker-1, jeton injecté côté nœud
(motif crumb F1 : crumb si disponible, sinon `X-No-Crumb: 1`) :

```bash
scp docs/superpowers/plans/2026-07-29-f4-jenkins-publish-job.xml worker-1:/tmp/f4-job.xml
ssh worker-1 'sudo bash -s <<'"'"'EOS'"'"'
set -eu
sed "s/__WEBHOOK_TOKEN__/$(cat /root/f4-webhook.token)/" /tmp/f4-job.xml > /tmp/f4-job-armed.xml
k3s kubectl -n ci exec -i deploy/jenkins -- bash -c '\''
  set -eu
  CR=$(curl -s http://localhost:8080/crumbIssuer/api/json -c /tmp/cj || true)
  if echo "$CR" | grep -q crumbRequestField; then
    F=$(echo "$CR" | sed -n "s/.*\"crumbRequestField\":\"\([^\"]*\)\".*/\1/p")
    C=$(echo "$CR" | sed -n "s/.*\"crumb\":\"\([^\"]*\)\".*/\1/p")
    H="$F: $C"
  else H="X-No-Crumb: 1"; fi
  curl -s -o /dev/null -w "createItem: %{http_code}\n" -b /tmp/cj -H "$H" \
    -X POST "http://localhost:8080/createItem?name=publish-accounts" \
    -H "Content-Type: application/xml" --data-binary @-
'\'' < /tmp/f4-job-armed.xml
rm -f /tmp/f4-job-armed.xml
EOS'
```

Attendu : `createItem: 200`. (400 « job already exists » au rejeu → passer par
`POST /job/publish-accounts/config.xml`, même enveloppe.)

- [x] **Step 3 : rétention sur `probe`** — ajouter en tête du Jenkinsfile du
repo Gitea `ci/probe` (via `put_file` du geste T3, adapté au repo `ci/probe`,
ou push git) la ligne :

```groovy
properties([buildDiscarder(logRotator(numToKeepStr: '25')), disableConcurrentBuilds()])
```

Le push déclenche `probe` (webhook F1) → vérifier build vert = re-preuve F1
gratuite, et la rétention apparaît dans `GET /job/probe/config.xml`.

- [x] **Step 4 : commit du XML versionné**

```bash
git add docs/superpowers/plans/2026-07-29-f4-jenkins-publish-job.xml
git commit -s -m "feat(f4): job publish-accounts — webhook GenericTrigger, XML de reconstruction"
```

### Tâche 5 : Porte F4

**Interfaces — Consumes :** tout ce qui précède. **Produces :** la preuve de
porte (§ Preuve d'exécution).

- [ ] **Step 1 : caler la fenêtre** — vérifier l'âge du pod gateway (T0
Step 4) ; viser un push dans les minutes 6-18 du cycle (gateway prête).

- [ ] **Step 2 : LE push** — modifier la spec dans
`banking-demo/accounts-api` (bump `info.description`, par l'API contents
comme en T3, message `feat: publication F4`) → noter le sha du commit.

- [ ] **Step 3 : observer le build `publish-accounts` #1** (déclenché SANS
action humaine) :

```bash
ssh worker-1 'sudo k3s kubectl -n ci exec deploy/jenkins -- \
  curl -s "http://localhost:8080/job/publish-accounts/lastBuild/api/json?tree=number,result,timestamp"'
```

Attendu : `result: SUCCESS`. En cas d'échec : lire
`…/lastBuild/consoleText`, diagnostiquer (suspect n°1 : quoting/shape team —
retour T1), corriger, re-pousser.

- [ ] **Step 4 : le statut de commit dans Gitea**

```bash
ssh worker-1 'sudo k3s kubectl -n ci exec deploy/jenkins -- \
  curl -s "http://gitea.ci.svc.cluster.local:3000/api/v1/repos/banking-demo/accounts-api/commits/<SHA>/statuses"' \
  # → context jenkins/publish, state success
```

- [ ] **Step 5 : l'API sur la gateway, scopée** — depuis le pod jenkins :
`GET $WM_BASE/apis/<id>` → `apiName: accounts-read`, `isActive: true`, team
`banking-demo` présente.

- [ ] **Step 6 : zéro secret statique, rejoué**

```bash
ssh worker-1 'sudo k3s kubectl -n ci exec deploy/jenkins -- sh -c \
  "test ! -f /var/jenkins_home/credentials.xml && echo ZERO-SECRET-OK"'
```

- [ ] **Step 7 : garde worker-3** (contraintes globales) + consigner toutes
les sorties horodatées pour le § Preuve.

### Tâche 6 : Contre-épreuve isolation Teams

**Interfaces — Consumes :** `/root/f4-teams.env` (T1), API publiée (T5).

- [ ] **Step 1 : si T1 a montré des users volatils** : rejouer
`f4-teams-bootstrap.sh` (idempotent) — les accessProfiles/assignations (ES)
n'ont pas bougé, seuls les users IS se recréent.

- [ ] **Step 2 : `GET /apis` sous deux identités** — script scp'é (les mots de
passe restent sur le nœud) :

```bash
ssh worker-1 'sudo bash -c '"'"'
set -eu; . /root/f4-teams.env
K="k3s kubectl -n ci exec deploy/jenkins --"
B=http://wm-apigateway.wm.svc:5555/rest/apigateway
H="Accept: application/json"
echo "== svc-banking-demo (doit VOIR accounts-read) =="
$K curl -s -u "svc-banking-demo:$P_banking_demo" -H "$H" "$B/apis" | grep -c accounts-read || true
echo "== svc-insurance-demo (ne doit PAS voir) =="
$K curl -s -u "svc-insurance-demo:$P_insurance_demo" -H "$H" "$B/apis" | grep -c accounts-read || true
'"'"''
```

Attendu : compte ≥ 1 pour banking, **0 pour insurance**. (Adapter les noms de
variables à ceux réellement écrits par le bootstrap.) Consigner les sorties.

- [ ] **Step 3 (bonus, si T1 l'a préparé)** : assignation cross-team par
`svc-insurance-demo` → 400 attendu.

### Tâche 7 : Contre-épreuve Vault — rôle révoqué → rouge fermé

**Files :**
- Create : `docs/superpowers/plans/2026-07-29-f4-vault-role-toggle.sh`

- [ ] **Step 1 : le script à deux modes** (motif quorum, étapes 1-3 du script
F1 reprises à l'identique ; `$3` = `revoke` | `restore`) :

```sh
# … [étapes 1-3 quorum → VAULT_TOKEN éphémère, identiques au script F1] …
case "$3" in
  revoke)
    vault delete auth/kubernetes/role/jenkins-agent >/dev/null \
      || { vault token revoke -self >/dev/null 2>&1 || true; echo "ECHEC delete"; exit 1; }
    echo "role jenkins-agent REVOQUE";;
  restore)
    vault write auth/kubernetes/role/jenkins-agent \
      bound_service_account_names=jenkins-agent \
      bound_service_account_namespaces=ci \
      token_policies=jenkins-agent ttl=20m >/dev/null \
      || { vault token revoke -self >/dev/null 2>&1 || true; echo "ECHEC write"; exit 1; }
    echo "role jenkins-agent RESTAURE";;
esac
vault token revoke -self >/dev/null || { echo "AVERTISSEMENT : revocation a verifier"; exit 1; }
```

Commit, puis **geste exploitant 1** (`… revoke`).

- [ ] **Step 2 : push** (bump description, comme T5 Step 2) → build
`publish-accounts` attendu **FAILURE** (login G-c refusé, aucun secret servi),
statut `jenkins/publish: failure` sur le commit — **échec fermé** : vérifier
dans la console que l'échec est le login Vault (`permission denied`), pas un
timeout gateway. *(Le statut `pending`/`failure` du build rouge peut manquer
si le login du postStatus échoue aussi — c'est attendu et ça se consigne : le
statut Gitea reste alors sur l'état du dernier build vert, et la preuve du
rouge est le `result: FAILURE` du build. Si c'est le cas, le « statut rouge »
de la contre-épreuve est porté par le build, pas par Gitea — l'écart est acté
au § Preuve.)*

- [ ] **Step 3 : geste exploitant 2** (`… restore`), puis push → build
**SUCCESS**, statut vert. La chaîne est refermée.

- [ ] **Step 4 :** si la fenêtre exploitant n'est pas disponible : repli SA
(`kubectl -n ci delete sa jenkins-agent` puis re-création — attention : Argo
selfHeal peut le recréer seul ; mesurer et consigner l'écart au GOAL).

### Tâche 8 : NetworkPolicy ES (PR `stoa`)

**Files (worktree `stoa-f4`) :**
- Create : `deploy/bootstrap/wm/elasticsearch/networkpolicy.yaml`
- Modify : `deploy/bootstrap/wm/elasticsearch/kustomization.yaml` (+ resource)

- [x] **Step 1 : worktree**

```bash
git -C /Users/potomitan/stoa-platform/stoa fetch origin
git -C /Users/potomitan/stoa-platform/stoa worktree add \
  /Users/potomitan/stoa-platform/stoa-f4 -b feat/f4-netpol-es origin/main
```

- [x] **Step 2 : le manifeste**

```yaml
# ES ne sert QUE la gateway (F4 : les clients réels sont connus — le CronJob
# ne parle qu'à l'API k8s, les agents Jenkins qu'à la gateway:5555).
# 9300 omis : ES mono-pod (à rouvrir intra-ES si le cluster ES grandit).
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: wm-elasticsearch-ingress
  namespace: wm
spec:
  podSelector:
    matchLabels:
      app: wm-elasticsearch
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: wm-apigateway
      ports:
        - port: 9200
          protocol: TCP
```

- [ ] **Step 3 : PR** (commit `-s`, français : « feat(wm): NetworkPolicy ES —
ingress restreint à la gateway (F4) »), `gh pr create` sur
`stoa-platform/stoa`, **merge par l'exploitant** (`!`), sync Argo observée.

- [ ] **Step 4 : contre-épreuve** — depuis le pod jenkins (ns `ci`) :

```bash
ssh worker-1 'sudo k3s kubectl -n ci exec deploy/jenkins -- \
  curl -s -m 6 -o /dev/null -w "es-depuis-ci: %{http_code}\n" \
  http://wm-elasticsearch.wm.svc:9200/ || echo "es-depuis-ci: BLOQUE (attendu)"'
ssh worker-1 'sudo k3s kubectl -n ci exec deploy/jenkins -- curl -s -o /dev/null \
  -w "health-gw: %{http_code}\n" -H "Accept: application/json" \
  http://wm-apigateway.wm.svc:5555/rest/apigateway/health'
```

Attendu : `BLOQUE (attendu)` puis `health-gw: 200` (la gateway, elle, passe).
**Si le curl passe** : le contrôleur NetworkPolicy de k3s n'est pas actif —
constat à consigner, policy laissée en place (inerte mais prête), dette
re-actée ; ne pas improviser un composant réseau en fin de passe.

### Tâche 9 : Rotation `ci`/`ci-bootstrap` (geste, non bloquant)

**Files :**
- Create : `docs/superpowers/plans/2026-07-29-f4-rotate-ci-pass.sh`

- [ ] **Step 1 : le script** (worker-1, root — le nouveau mot de passe ne
quitte jamais le nœud) :

```bash
#!/bin/bash
set -eu
umask 077
NEWF=/root/gitea-ci-pass
[ -s "$NEWF" ] || openssl rand -base64 18 | tr -d '\n' > "$NEWF"
NEW=$(cat "$NEWF")
curl -s -u 'ci:ci-bootstrap' -H 'Content-Type: application/json' -X PATCH \
  -d "{\"login_name\":\"ci\",\"source_id\":0,\"password\":\"$NEW\",\"must_change_password\":false}" \
  http://localhost:30300/api/v1/admin/users/ci -o /dev/null -w "patch: %{http_code}\n"
# contre-épreuve : l'ancien mot de passe ne passe plus, le nouveau passe
curl -s -u 'ci:ci-bootstrap' -o /dev/null -w "ancien: %{http_code}\n" http://localhost:30300/api/v1/user
curl -s -u "ci:$NEW" -o /dev/null -w "nouveau: %{http_code}\n" http://localhost:30300/api/v1/user
echo "OK — mot de passe dans $NEWF ; les gestes futurs font: -u \"ci:\$(cat $NEWF)\""
```

Attendu : `patch: 200`, `ancien: 401`, `nouveau: 200`.

- [ ] **Step 2 :** vérifier derrière que la chaîne vit toujours : webhook
(token, pas de password) → un push profite du prochain geste ; PAT
`probe-status` (token) inchangé ; pulls d'images anonymes (registries.yaml
sans auth — mesuré T0 de la passe). Consigner : **tout geste futur** (docker
login worker-3, API admin) lit `/root/gitea-ci-pass`.

- [ ] **Step 3 :** commit du script + si la fenêtre manque, re-acter la dette
avec date au § Dette du GOAL.

### Tâche 10 : Preuve d'exécution, GOAL, handoff, mémoire

- [ ] **Step 1 :** § « Preuve d'exécution » ajouté à CE plan : sorties réelles
horodatées de T5 (porte), T6, T7, T8 ; shapes réels constatés en T1 ; écarts
éventuels (repli SA, statut rouge porté par le build, NetworkPolicy inerte…).
- [ ] **Step 2 :** GOAL
  `poc-control-plane-federation/GOAL-socle-vers-gateway-2026-07-28.md` : § F4 →
**FERMÉ** avec le résumé de preuve ; tableau des dettes mis à jour (rétention
soldée, JCasC re-actée avec déclencheur, rotation soldée ou datée).
- [ ] **Step 3 :** handoff de session
`poc-control-plane-federation/HANDOFF-2026-07-29-F4-CHAINE-PUBLICATION.md`
(même format que F3) ; mémoire projet mise à jour (fichier
`socle-ci-lot1-deploye.md` : F4 fermé, pièges nouveaux — teams volatiles ou
non, rotation faite ou datée).
- [ ] **Step 4 :** commits docs (`-s`, français), garde worker-3 finale.

---

## Self-review (fait à l'écriture)

- Spéc D1→D9 couverte : D1/D2 (T3), D3 (T1), D4 (T3/T4), D5 (Jenkinsfile
  stage attente), D6 (T2), D7 (T7), D8 (T8), D9 (T4 rétention, T9 rotation,
  JCasC re-actée en T10).
- Les shapes wM non prouvés sont TOUS derrière le spike T1, avant tout
  câblage ; le Jenkinsfile est marqué « à ajuster depuis T1 ».
- Cohérence des noms : `wm-cluster` (manifeste = chemin Vault
  `secret/ci/gateways/wm-cluster`), `banking-demo`/`insurance-demo`,
  `jenkins/publish` (contexte de statut), `publish-accounts` (job),
  `/root/f4-webhook.token`, `/root/f4-teams.env`, `/root/gitea-ci-pass`.
- Placeholders volontaires et uniques : `__WEBHOOK_TOKEN__` (XML), `<APIID>`,
  `<UUID banking-demo>`, `<SHA>` (valeurs de session, jamais versionnées).

---

## Preuve d'exécution (2026-07-29, en cours — complétée au fil des portes)

### T0 — Terrain (17:05–17:10 UTC)

- Pods `ci` (gitea-0, jenkins, vault-0) et `wm` (ES, gateway) Ready ; `probe`
  seul job Jenkins ; `ZERO-SECRET-OK` (credentials.xml absent) ;
  `dev-wm.gostoa.dev` → 200. curl 8.14.1 disponible dans le pod jenkins.
- Health gateway 200 depuis le pod jenkins ; cycle trial confirmé :
  redémarrages aux minutes :00/:20/:40, ~5 min de démarrage — une sonde à
  17:00 pile est tombée sur le restart (exit 7), re-jouée verte à 17:08.

### T1 — Spike Teams : FERMÉ (17:08–17:50 UTC), le maillon non prouvé est prouvé

Constats live (gateway `10.15.0.0.95`, ns `wm`) — TOUS différents du
best-effort documenté, chacun attrapé par un GET d'observation ou une
relecture :

| Attendu (spike #1 / rôle Ansible) | Constaté live |
|---|---|
| configId `extendedSettings` | **`extended`** (`PUT /configurations/extended {"enableTeamWork":"true"}` → 200, relu `true`) |
| `POST /assets/team {assetIds, newTeams}` | **`assetType:"API"` OBLIGATOIRE** — sans lui : 200 `{}` **no-op silencieux** (relecture inchangée) ; avec : message explicite + effet réel |
| `newTeams` par UUID (nom → 400) | confirmé : nom → 400 `Assigned team banking-demo is not valid.` |
| team relue dans l'API | champ `teams[]` au niveau **`apiResponse`** (PAS dans `api`) ; source `USER` ; l'assignation **retire `Default`** (confirmé) |
| `userIds`/`groupIds` par nom | **UUID internes exigés** — les noms sont **ignorés en silence** (200, liste vide) ; groupes custom : id UUID ≠ name (PUT par nom → 404) |
| accès admin REST des users d'équipe | 403 tant que le user n'est pas AUSSI membre du groupe système **`API-Gateway-Providers`** |
| privilèges d'accessProfile | champ `privilege` = **bitmask** (copié de API-Gateway-Providers : `111100101101100000001`) |

- Objets créés (201 partout, puis correctifs UUID en 200) : users
  `svc-banking-demo` / `svc-insurance-demo` (mdp dans `/root/f4-teams.env`,
  0600), groupes `banking-demo-devs` / `insurance-demo-devs`, accessProfiles
  `banking-demo` (`b178395d-…845a`) / `insurance-demo` (`59bbd3ba-…27ee`).
- **Survie au cycle trial MESURÉE** : objets créés à 17:12, restart 17:20,
  relecture 17:27 — enableTeamWork, users, teams tous présents (état ES ;
  PAS de re-bootstrap nécessaire avant les preuves — mieux que la crainte D3).
- **Pré-preuve d'isolation (API jetable `f4-spike-jetable` en team
  banking-demo)** :
  - `GET /apis` en `svc-banking-demo` → `visible: ['f4-spike-jetable']`
  - `GET /apis` en `svc-insurance-demo` → `{"apiResponse":[{"responseStatus":"NOT_FOUND","errorReason":"No APIs found"}]}`
- API jetable supprimée (204). Script complet consigné :
  `2026-07-29-f4-teams-bootstrap.sh` (idempotent, rejouable).

### T3 — Repo d'équipe + webhook (18:00 UTC)

`f4-gitea-setup.sh` sur worker-1 : `org: 201`, `repo: 201`, `post
Jenkinsfile/stoa-publish.yaml/apis/accounts-read.openapi.yaml: 201`,
`hook: 201` (l'allowlist Gitea a accepté l'URL du Service Jenkins). Jeton
webhook frappé sur le nœud, `/root/f4-webhook.token` (0600), jamais affiché.

### T4 — Job + rétention (18:05 UTC)

- `createItem: 200` → jobs = `probe`, `publish-accounts` (jeton injecté côté
  nœud par sed depuis `/root/f4-webhook.token`).
- Rétention 25 builds poussée sur `ci/probe` (PUT contents 200) → **build
  probe n°12 déclenché par le push, SUCCESS** = re-preuve F1 gratuite ;
  `logRotator` visible dans `GET /job/probe/config.xml` ; `ZERO-SECRET-OK`
  rejoué ; worker-3 → 200.
- Vérifs de dé-risquage porte : `labctl 0.1.0-poc` et `python3 3.13.5`
  présents dans l'image `jenkins-go` du conteneur agent ; `labctl apply -f`
  confirmé ; pas de `api.yaml` (UAC) dans le repo d'équipe → pas de gate
  d'enforcement.

### T8 — NetworkPolicy ES : PR créée

PR **stoa#2824** (`feat/f4-netpol-es`, 2 fichiers) — merge exploitant puis
contre-épreuve après sync.

### En attente au moment de ce point d'étape

**T2** (geste exploitant quorum : `secret/ci/gateways/wm-cluster`) — bloquant
pour T5 (porte), puis T6, T7 (2 gestes quorum), merge T8, T9, T10.

### Pré-preuve fail-closed (hors plan, jouée en attendant le geste T2 — 19:10–19:35 UTC)

Deux pushes d'essai AVANT l'écriture du secret Vault, pour dé-risquer toute la
chaîne amont sans publication :

- **Build #1** (push `e59f71b2`) : déclenché par le webhook SEUL, pod agent
  3 conteneurs monté (premier pull `jenkins-go` sur le nœud d'agent), statut
  `pending` posé par identité de pod, login G-c réussi, puis échec **fermé** :
  `No value found at secret/data/ci/gateways/wm-cluster` → `FAILURE`.
  Constat : la lecture des creds était AVANT le `try` → le statut est resté
  `pending` (défaut corrigé).
- **Build #2** (push `a52f79da`, Jenkinsfile corrigé — creds dans le `try`) :
  `FAILURE` attendu + **statut `jenkins/publish: failure`** posé sur le
  commit. L'échec fermé rougit dans Gitea — la contre-épreuve T7 aura son
  canal de statut complet (le login du postStatus reste servi tant que le
  RÔLE existe ; en cas de rôle révoqué, cf. réserve du plan T7).

Validé au passage : `labctl 0.1.0-poc`, `python3 3.13.5` et `curl` dans le
conteneur agent `jenkins-go` ; `labctl apply -f` (aide CLI) ; aucun gate UAC
(pas d'`api.yaml` dans le repo d'équipe).

### T2 — Creds wM dans Vault : geste exploitant joué (21:55 UTC)

**Écart de méthode assumé et outillé.** Le geste interactif prévu au plan
(`ssh -t` + `read -r -s` des 2 clés) **ne peut pas fonctionner** dans ce
harnais : pas de TTY → `Pseudo-terminal will not be allocated`, la commande
part en timeout sans rien faire (constaté). Variante livrée et utilisée :
`2026-07-29-f4-quorum-fromfile.sh`, exécutée **sur le nœud**, qui lit les 2
clés dans `/root/vault-init-ci.txt` (600, déjà présent depuis la re-init du
matin), les passe au script in-pod et n'affiche **rien**. Sortie :
`OK: secret/ci/gateways/wm-cluster ecrit, jeton racine ephemere revoque`.

Vérifications derrière :
- lecture **par identité de pod** (Job jetable, SA `jenkins-agent`) →
  `wm-cluster username=Administrator (password non affiche)` ;
- `vault token lookup` dans `vault-0` → **échec** = aucun jeton racine au repos.

Note : cette enveloppe rend le geste rejouable tant que le fichier d'init est
sur le nœud. **Il doit être récupéré hors ligne puis `shred -u`** (action
exploitant pendante) — après quoi les gestes quorum redeviennent interactifs.

### T5 — LA PORTE F4 : VERTE (build #4, 20:56–21:05 UTC)

Chemin complet, **sans aucune action humaine après le push** :

| Critère de la porte | Preuve |
|---|---|
| push d'une spec déclenche le build | commit `3a4822aa` sur `banking-demo/accounts-api` → build `publish-accounts` **#4** déclenché par le webhook (`GWT_AFTER=3a4822aa…`, `GWT_REF=refs/heads/main`) |
| identifiants par identité de pod | stage « Identité de pod → Vault » : `creds gateway obtenues par identite de pod (aucune valeur affichee)` |
| API publiée | `labctl apply` → `accounts-read` `1.0.0`, **`isActive: True`** sur `wm-apigateway.wm.svc:5555` |
| scopée à sa team | `assets/team: 200` puis relecture : `team relue OK: ['Administrators', 'banking-demo']` (source `USER`) |
| statut de commit vert | `jenkins/publish: success` (« publish success ») sur `3a4822aa` |
| **zéro secret statique** | `ZERO-SECRET-OK` (`/var/jenkins_home/credentials.xml` absent) |
| worker-3 intact | `dev-wm.gostoa.dev: 200` |

**Défaut trouvé et corrigé en route (build #3, FAILURE utile)** : les creds
étaient écrites par le conteneur `vault` en 0600 sous un **UID différent** de
celui du conteneur `labctl` → `cat: .wmu: Permission denied` en boucle dans le
stage d'attente, échec **fermé** après les 8 min (rien publié). Correctif : le
login Vault se fait **dans le conteneur qui consomme**, en HTTP direct sur
l'API Vault (le token de SA est projeté dans chaque conteneur du pod) —
**plus aucun secret ne transite entre conteneurs**.

### T6 — Contre-épreuve isolation : VERTE (21:06 UTC)

Même `GET /apis`, deux identités d'équipe (mots de passe lus sur le nœud, hors
session) :

- `svc-banking-demo` → `['accounts-read']`
- `svc-insurance-demo` → `{"apiResponse":[{"responseStatus":"NOT_FOUND","errorReason":"No APIs found"}]}`

L'isolation Teams du spike #1 est **rejouée sur la gateway cluster**, sur
l'API réellement publiée par le pipeline.

### T7 — Contre-épreuve Vault : VERTE (21:07–21:25 UTC)

1. `f4-quorum-fromfile.sh … revoke` → `role jenkins-agent REVOQUE`.
2. Push `3c88664e` → build **#5 : FAILURE**,
   `Error writing data to auth/kubernetes/login: … invalid role name
   "jenkins-agent"`. **Échec fermé au premier appel** : API sur la gateway
   **inchangée** (`accounts-read 1.0.0`, `isActive: True`, teams
   `['Administrators','banking-demo']`) — rien n'a été muté.
3. `… restore` → `role jenkins-agent RESTAURE`, puis push `bb9c578d` → build
   **#6** (verdict au § suivant).

**Constat structurel à retenir (pas un défaut)** : sur le commit `3c88664e`,
**aucun statut Gitea n'a été posté** — le canal de statut lui-même dépend de
l'identité de pod (le PAT vit dans Vault). Quand Vault refuse l'identité, la
chaîne ne peut par construction plus parler à Gitea : c'est le prix exact du
« zéro secret statique ». Le signal rouge est alors le `result: FAILURE` du
build (et l'absence de statut vert, qui empêche toute confusion avec un
succès). La réserve inscrite au plan T7 est donc **confirmée par la mesure**.

3. Restauration → push `bb9c578d` → build **#6 : SUCCESS**, statut
   `jenkins/publish: success`. **La chaîne reverdit** : la contre-épreuve est
   complète (vert → rouge fermé → vert).

### T9 — Rotation `ci`/`ci-bootstrap` : SOLDÉE (21:30 UTC)

Rayon d'action **mesuré avant d'écrire** (leçon fondatrice du dépôt) : aucun
`imagePullSecrets` dans `ci`/`wm`, aucune auth dans
`/etc/rancher/k3s/registries.yaml`, aucun secret `dockerconfigjson` → les
tirages d'images du registre Gitea sont **anonymes**, la rotation ne peut pas
casser le cluster.

- `patch: 200` ; contre-épreuve : `ancien mdp: 401`, `nouveau mdp: 200`.
- Nouveau mot de passe : `/root/gitea-ci-pass` (worker-1, 0600, jamais
  affiché) ; `f4-push-bump.sh` le lit désormais (repli bootstrap si absent).
- **Re-preuve de bout en bout après rotation** : push `1acf1f64` avec le
  nouvel identifiant → build **#7 : SUCCESS**, statut
  `jenkins/publish: success`. Le PAT `probe-status` (un jeton, pas un mot de
  passe) survit comme attendu.
- Trap retiré : les deux scripts du lot 1 qui portent l'ancien mot de passe
  **en dur** (`vault-bootstrap.sh`, `f1-provision-status-token.sh`) sont
  signalés en tête du script de rotation.

### T8 — NetworkPolicy ES : PR ouverte, merge exploitant

PR **stoa#2824** (`feat/f4-netpol-es`) — `gh pr merge` refusé à l'agent par le
classifieur (motif lot 1/F3 : l'exploitant merge). Contre-épreuve à jouer
derrière : `curl 9200` depuis un pod `ci` → bloqué ; health gateway → 200.
Si le curl passe, le contrôleur NetworkPolicy de k3s n'est pas actif : le
consigner, laisser la policy (inerte mais prête), re-acter la dette.

### Récapitulatif des builds de la passe

| # | Push | Verdict | Ce qu'il prouve |
|---|---|---|---|
| 1 | `e59f71b2` | FAILURE | webhook + pod agent + login G-c OK ; secret absent → **échec fermé** (statut resté `pending` : défaut corrigé) |
| 2 | `a52f79da` | FAILURE | l'échec fermé **rougit** dans Gitea (`jenkins/publish: failure`) |
| 3 | `619888d5` | FAILURE | secret présent, mais creds illisibles entre conteneurs (UID) → **échec fermé, rien publié** |
| 4 | `3a4822aa` | **SUCCESS** | **LA PORTE** : API active, scopée, statut vert, zéro secret statique |
| 5 | `3c88664e` | FAILURE | rôle Vault révoqué → `invalid role name`, **API inchangée** |
| 6 | `bb9c578d` | **SUCCESS** | rôle restauré → la chaîne reverdit |
| 7 | `1acf1f64` | **SUCCESS** | rotation du mdp `ci` sans régression |

Trois échecs, tous **fermés** et tous instructifs : aucun n'a publié quoi que
ce soit sur la gateway. C'est la propriété qu'on voulait.
