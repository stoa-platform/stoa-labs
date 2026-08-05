#!/usr/bin/env python3
"""E1 / D2 — la définition du pipeline quitte le dépôt de l'équipe.

Trois gestes, dans cet ordre, chacun relu :
  1. poser le manifeste ANSIBLE dans le dépôt d'équipe (ses DONNÉES) ;
  2. remplacer la <definition> du job par un CpsFlowDefinition INLINE, en
     conservant tel quel le reste du config.xml — triggers, token de webhook,
     propriétés : les réécrire, c'est risquer de perdre le jeton qu'on ne
     connaît pas ;
  3. retirer le Jenkinsfile du dépôt d'équipe, sinon il reste une porte d'entrée.

Le mot de passe Gitea vient de /root/gitea-ci-pass (0600) et ne transite ni par
argv ni par un log.
"""
import base64
import json
import re
import sys
import http.cookiejar
import urllib.error
import urllib.request

# Jenkins LIE le crumb à la SESSION : demander /crumbIssuer puis POSTer sans
# reporter le cookie JSESSIONID donne « No valid crumb was included in the
# request » — un 403 qui parle de crumb alors que le crumb est bon. D'où un
# opener à cookie jar partagé pour TOUS les appels Jenkins.
_JAR = http.cookiejar.CookieJar()
_OPENER = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(_JAR))

GITEA = "http://10.43.60.211:3000"
JENKINS = "http://10.43.103.207:8080"
OWNER, REPO = "banking-demo", "accounts-api"
JOB = "publish-accounts"

with open("/root/gitea-ci-pass") as fh:
    GPASS = fh.read().strip()
GAUTH = "Basic " + base64.b64encode(f"ci:{GPASS}".encode()).decode()


def http(url, method="GET", data=None, headers=None, ctype=None):
    req = urllib.request.Request(url, method=method, data=data)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    if ctype:
        req.add_header("Content-Type", ctype)
    try:
        with _OPENER.open(req, timeout=60) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def gitea(path, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    return http(f"{GITEA}/api/v1{path}", method, data,
                {"Authorization": GAUTH, "Accept": "application/json"},
                "application/json" if data else None)


MANIFEST = """---
# banking-demo/accounts-api — manifeste de publication (vars du rôle apim_publish_api).
#
# CE FICHIER NE DIT PLUS SOUS QUELLE ÉQUIPE PUBLIER. La team est posée par le
# JOB, qui appartient à la plateforme : le manifeste vit dans ce dépôt, donc
# l'équipe l'écrit, donc il ne peut pas faire autorité sur son propre
# cloisonnement. Y déclarer une `team:` différente de celle du job fait ÉCHOUER
# le build (TEAM_FORBIDDEN) — un refus, pas un silence.
#
# Le contrat est résolu depuis le workspace Jenkins : le playbook tourne dans le
# dépôt PLATEFORME, pas ici.
apim_api:
  name: "accounts-read"
  version: "1.0.0"
  contract: "{{ lookup('env', 'WORKSPACE') }}/apis/accounts-read.openapi.yaml"
"""

GROOVY = r'''// publish-accounts — E1 : script INLINE, possédé par la plateforme (D2).
//
// Le dépôt de l'équipe ne fournit plus que ses DONNÉES (contrat + manifeste).
// Le TEAM ci-dessous et le serviceAccount du podTemplate sont écrits ICI, dans
// un objet que l'équipe ne peut pas modifier par un push — c'est la seule
// raison pour laquelle la garde d'équipe du rôle est opposable.
//
// Copie de reconstruction versionnée : ci/Jenkinsfile.publish-api.
def TEAM     = 'banking-demo'
def GIT_URL  = 'http://gitea.ci.svc.cluster.local:3000/banking-demo/accounts-api.git'
def PLATFORM = 'http://gitea.ci.svc.cluster.local:3000/ci/stoa-labs.git'
def MANIFEST = 'stoa-publish.ansible.yml'
def ADMIN    = 'http://wm-apigateway-admin.wm.svc:5555/rest/apigateway'

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
      --post-data '{"state":"${state}","context":"jenkins/publish","target_url":"${buildUrl}","description":"publish ${state}"}' \\
      "http://gitea.ci.svc.cluster.local:3000/api/v1/repos/banking-demo/accounts-api/statuses/${sha}"
  """
}

properties([buildDiscarder(logRotator(numToKeepStr: '25')), disableConcurrentBuilds()])

podTemplate(serviceAccount: 'jenkins-agent', containers: [
  containerTemplate(name: 'vault', image: 'hashicorp/vault:1.18', command: 'sleep', args: '9999',
    envVars: [envVar(key: 'VAULT_ADDR', value: 'http://vault.ci.svc.cluster.local:8200')]),
  containerTemplate(name: 'ansible',
    image: 'localhost:30300/ci/jenkins-go:v1@sha256:00ad5591be6f1c7b4eccfd7e498abe5e947dc07f01e4d7a247005b65ef0c565b',
    command: 'sleep', args: '9999',
    envVars: [envVar(key: 'VAULT_ADDR', value: 'http://vault.ci.svc.cluster.local:8200'),
              envVar(key: 'VAULT_K8S_ROLE', value: 'jenkins-agent')])
]) {
  node(POD_LABEL) {
    timeout(time: 20, unit: 'MINUTES') {
      def scmVars = checkout([$class: 'GitSCM', branches: [[name: '*/main']],
        userRemoteConfigs: [[url: GIT_URL]]])
      def sha = env.GWT_AFTER ?: scmVars.GIT_COMMIT
      dir('platform') {
        checkout([$class: 'GitSCM', branches: [[name: '*/main']],
          userRemoteConfigs: [[url: PLATFORM]]])
      }
      container('vault') { postStatus(sha, 'pending', env.BUILD_URL) }
      try {
        container('ansible') {
          stage('Attendre la gateway (cycle trial)') {
            sh """
              set -e
              set +x
              for i in \$(seq 1 60); do
                code=\$(curl -s -o /dev/null -m 5 -w '%{http_code}' "${ADMIN}/health" || true)
                [ "\$code" = "200" ] && { echo "gateway prete (essai \$i)"; exit 0; }
                sleep 10
              done
              echo "gateway indisponible apres 10 min"; exit 1
            """
          }
          stage('Publier (role Ansible, identite de pod -> Vault)') {
            sh """
              set -e
              set +x
              cd platform/poc-control-plane-federation
              ansible-playbook -i ansible/inventory.lab.ini ansible/publish-api.yml \\
                -e apim_ss_manifest="\$WORKSPACE/${MANIFEST}" \\
                -e apim_ss_team=${TEAM} \\
                -e apim_ss_api_base=${ADMIN} \\
                -e apim_ss_data_base=http://wm-apigateway.wm.svc:5555/gateway \\
                -e apim_ss_auth_mode=basic \\
                -e apim_ss_vault_kv_mount=secret \\
                -e apim_ss_vault_prefix=ci \\
                -e apim_ss_vault_wm_creds_sub=gateways/wm-cluster
            """
          }
          stage('Verify fail-closed') {
            sh """
              set -e
              set +x
              cd platform/poc-control-plane-federation
              ansible-playbook -i ansible/inventory.lab.ini ansible/publish-api-verify.yml \\
                -e apim_ss_manifest="\$WORKSPACE/${MANIFEST}" \\
                -e apim_ss_team=${TEAM} \\
                -e apim_ss_api_base=${ADMIN} \\
                -e apim_ss_auth_mode=basic \\
                -e apim_ss_vault_kv_mount=secret \\
                -e apim_ss_vault_prefix=ci \\
                -e apim_ss_vault_wm_creds_sub=gateways/wm-cluster
            """
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
'''


def xml_escape(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def main():
    # ---- 1. le manifeste Ansible dans le dépôt d'équipe ---------------------
    st, body = gitea(f"/repos/{OWNER}/{REPO}/contents/stoa-publish.ansible.yml")
    payload = {"content": base64.b64encode(MANIFEST.encode()).decode(),
               "message": "feat(E1): manifeste Ansible — le depot d'equipe ne porte plus que ses donnees"}
    if st == 200:
        payload["sha"] = json.loads(body)["sha"]
        st2, b2 = gitea(f"/repos/{OWNER}/{REPO}/contents/stoa-publish.ansible.yml", "PUT", payload)
    else:
        st2, b2 = gitea(f"/repos/{OWNER}/{REPO}/contents/stoa-publish.ansible.yml", "POST", payload)
    print(f"1. manifeste Ansible -> HTTP {st2}")
    if st2 not in (200, 201):
        print("   ", b2[:300].decode("utf-8", "replace")); return 1

    # ---- 2. le job devient un CpsFlowDefinition inline ----------------------
    st, cfg = http(f"{JENKINS}/job/{JOB}/config.xml")
    print(f"2. config.xml actuel -> HTTP {st} ({len(cfg)} octets)")
    if st != 200:
        print("   job introuvable"); return 1
    cfg = cfg.decode("utf-8")
    old = re.search(r"<definition class=\"[^\"]*\"[^>]*>.*?</definition>", cfg, re.S)
    if not old:
        print("   <definition> introuvable dans le config.xml"); return 1
    print(f"   ancienne definition : {old.group(0)[:70]}...")
    new_def = ('<definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">'
               f"<script>{xml_escape(GROOVY)}</script>"
               "<sandbox>false</sandbox></definition>")
    newcfg = cfg[:old.start()] + new_def + cfg[old.end():]

    crumb_st, crumb_b = http(f"{JENKINS}/crumbIssuer/api/json")
    headers = {}
    if crumb_st == 200:
        c = json.loads(crumb_b)
        headers[c["crumbRequestField"]] = c["crumb"]
        print(f"   crumb obtenu ({c['crumbRequestField']})")
    st3, b3 = http(f"{JENKINS}/job/{JOB}/config.xml", "POST",
                   newcfg.encode("utf-8"), headers, "application/xml; charset=utf-8")
    print(f"   POST config.xml -> HTTP {st3}")
    if st3 not in (200, 201):
        print("   ", b3[:400].decode("utf-8", "replace")); return 1

    st4, back = http(f"{JENKINS}/job/{JOB}/config.xml")
    ok = "CpsFlowDefinition" in back.decode("utf-8", "replace")
    print(f"   RELECTURE : CpsFlowDefinition present = {ok}")
    if not ok:
        print("   la definition n'a pas ete prise"); return 1

    # ---- 3. retirer le Jenkinsfile du dépôt d'équipe ------------------------
    st, body = gitea(f"/repos/{OWNER}/{REPO}/contents/Jenkinsfile")
    if st == 200:
        sha = json.loads(body)["sha"]
        st5, b5 = gitea(f"/repos/{OWNER}/{REPO}/contents/Jenkinsfile", "DELETE",
                        {"sha": sha,
                         "message": "chore(E1): le Jenkinsfile quitte le depot d'equipe (D2)"})
        print(f"3. suppression du Jenkinsfile -> HTTP {st5}")
        if st5 not in (200, 204):
            print("   ", b5[:300].decode("utf-8", "replace")); return 1
    else:
        print(f"3. Jenkinsfile deja absent (HTTP {st})")

    st, body = gitea(f"/repos/{OWNER}/{REPO}/contents")
    print("   contenu du depot d'equipe :",
          [x["path"] for x in json.loads(body)] if st == 200 else f"HTTP {st}")
    return 0


sys.exit(main())
