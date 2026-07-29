// ci/probe — preuve G-c (lot 1) + F1 : statut de commit posé par identité de pod.
// Le PAT Gitea est lu dans Vault À CHAQUE appel (SA jenkins-agent, mécanique
// G-c) : aucun secret statique dans Jenkins ni dans ce fichier.
// Copie versionnée (reconstruisibilité) du Jenkinsfile vivant dans le dépôt
// Gitea ci/probe (branche main) — cf. plan 2026-07-28-f1-webhook-statut.md.
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
      --post-data "{\\"state\\":\\"${state}\\",\\"context\\":\\"jenkins/probe\\",\\"target_url\\":\\"${buildUrl}\\",\\"description\\":\\"probe ${state}\\"}" \\
      "http://gitea.ci.svc.cluster.local:3000/api/v1/repos/ci/probe/statuses/${sha}"
  """
}

podTemplate(serviceAccount: 'jenkins-agent', containers: [
  containerTemplate(name: 'vault', image: 'hashicorp/vault:1.18', command: 'sleep', args: '9999',
    envVars: [envVar(key: 'VAULT_ADDR', value: 'http://vault.ci.svc.cluster.local:8200')])
]) {
  node(POD_LABEL) {
    def scmVars = checkout scm
    def sha = env.GWT_AFTER ?: scmVars.GIT_COMMIT
    container('vault') {
      postStatus(sha, 'pending', env.BUILD_URL)
      try {
        // ── Preuve G-c du lot 1, inchangée ──
        sh '''
          set -e
          set +x
          VT=$(vault write -address=$VAULT_ADDR -field=token \
            auth/kubernetes/login role=jenkins-agent \
            jwt=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token))
          VAULT_TOKEN=$VT vault kv get -address=$VAULT_ADDR -field=value secret/ci/probe
        '''
        postStatus(sha, 'success', env.BUILD_URL)
      } catch (e) {
        postStatus(sha, 'failure', env.BUILD_URL)
        throw e
      }
    }
  }
}
