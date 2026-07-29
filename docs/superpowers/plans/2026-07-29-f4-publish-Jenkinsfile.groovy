// banking-demo/accounts-api — F4 : publication réelle sur la gateway cluster.
// Identifiants wM et PAT Gitea lus dans Vault PAR IDENTITÉ DE POD (G-c) :
// aucun secret statique dans Jenkins ni dans ce fichier.
// Copie versionnée (reconstruisibilité) du Jenkinsfile vivant dans le dépôt
// Gitea banking-demo/accounts-api (branche main) — plan F4
// 2026-07-29-f4-chaine-publication.md, Tâche 3.
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
  // jenkins-go = l'image du contrôleur : labctl + python3 (dep. ansible-core) +
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
      }
      try {
        container('labctl') {
          // Login G-c DANS le conteneur qui consomme : chaque conteneur du pod
          // porte le même token de SA projeté, et l'API HTTP de Vault suffit
          // (pas de binaire vault ici). Constat build #3 : écrire les creds
          // depuis le conteneur `vault` donnait des fichiers 0600 d'un AUTRE
          // UID — `cat: .wmu: Permission denied` côté labctl. Plus aucun
          // passage de secret entre conteneurs.
          // DANS le try : un refus Vault (secret absent, rôle révoqué) doit
          // poster un statut failure — constat build #1.
          stage('Identité de pod → Vault (creds gateway)') {
            sh '''
              set -e
              set +x
              umask 077
              SAT=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
              printf '{"role":"jenkins-agent","jwt":"%s"}' "$SAT" > .login.json
              curl -sf -X POST -d @.login.json \
                "$VAULT_ADDR/v1/auth/kubernetes/login" > .login.out
              rm -f .login.json
              python3 -c '
import json
tok=json.load(open(".login.out"))["auth"]["client_token"]
open(".vt","w").write(tok)
'
              rm -f .login.out
              curl -sf -H "X-Vault-Token: $(cat .vt)" \
                "$VAULT_ADDR/v1/secret/data/ci/gateways/wm-cluster" > .kv.out
              python3 -c '
import json
d=json.load(open(".kv.out"))["data"]["data"]
open(".wmu","w").write(d["username"])
open(".wmp","w").write(d["password"])
'
              rm -f .kv.out
              echo "creds gateway obtenues par identite de pod (aucune valeur affichee)"
            '''
          }
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
    if a.get("apiName")==os.environ["API_NAME"]:
        print(a["id"]); break
')
              test -n "$APIID" || { echo "API introuvable apres apply"; exit 1; }
              TID=$(curl -sf -u "$AUTH" -H "$H" "$WM_BASE/accessProfiles" | python3 -c '
import json,sys,os
d=json.load(sys.stdin)
profs=d.get("accessProfiles") or d.get("accessProfile") or d
if isinstance(profs,dict): profs=[profs]
for p in profs:
    if p.get("name")==os.environ["TEAM"]:
        print(p["id"]); break
')
              test -n "$TID" || { echo "accessProfile $TEAM introuvable"; exit 1; }
              # assetType OBLIGATOIRE : sans lui le POST rend 200 SANS RIEN
              # FAIRE (constat spike T1 du 2026-07-29)
              code=$(curl -s -o /tmp/team.out -w '%{http_code}' -u "$AUTH" -H "$H" \
                -H 'Content-Type: application/json' -X POST \
                -d "{\\"assetIds\\":[\\"$APIID\\"],\\"assetType\\":\\"API\\",\\"newTeams\\":[\\"$TID\\"]}" \
                "$WM_BASE/assets/team")
              case "$code" in
                200|201) echo "assets/team: $code" ;;
                *) echo "assets/team REFUSE: $code"; cat /tmp/team.out; exit 1 ;;
              esac
              # relecture obligatoire : un 200 wM ne prouve rien.
              # teams vit au niveau apiResponse (PAS dans api) — spike T1.
              export WM_TID="$TID"
              curl -sf -u "$AUTH" -H "$H" "$WM_BASE/apis/$APIID" | python3 -c '
import json,sys,os
r=json.load(sys.stdin).get("apiResponse",{})
teams=r.get("teams") or []
tid=os.environ["WM_TID"]
assert any(t.get("id")==tid for t in teams), "team absente a la relecture: %r" % (teams,)
print("team relue OK:", [t.get("name") for t in teams])
'
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
