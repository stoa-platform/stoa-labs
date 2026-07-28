# F1 — Webhook Gitea→Jenkins + statut de commit — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **Exécution réelle :** inline (executing-plans) — câblage d'état live via ssh, séquentiel, avec une porte utilisateur (T4) ; le contexte empirique (quoting ssh/kubectl, réponses des API) ne survivrait pas à un découpage par sous-agents.

**Goal:** Un `git push` sur `ci/probe` déclenche le build sans action humaine et le commit porte un statut vert dans Gitea ; un Jenkinsfile cassé produit un statut rouge (porte F1 du GOAL lot 2).

**Architecture:** Trigger `generic-webhook-trigger` (2.4.2) ajouté au job `probe` existant ; webhook push Gitea → Service Jenkins ; le Jenkinsfile pose lui-même les statuts (`pending`/`success`/`failure`) via l'API Gitea avec un PAT lu dans Vault **à chaque build par l'identité du pod agent** (mécanique G-c). Aucun manifeste `stoa` touché, aucun changement de policy Vault.

**Tech Stack:** Jenkins LTS (image `jenkins-go:v1`) · generic-webhook-trigger 2.4.2 · Gitea 1.22.6 · Vault 1.18.5 (kv-v2 `secret/`) · accès opérateur `ssh worker-1 'sudo k3s kubectl …'`

**Spéc :** `docs/superpowers/specs/2026-07-28-f1-webhook-statut-design.md`

## Global Constraints

- **Le jeton racine Vault ne transite JAMAIS par la session agent** — la porte T4 est exécutée par l'exploitant (placeholder `<JETON_RACINE>`, style lot 1).
- **Aucun secret dans Git** : le jeton webhook réel ne figure que dans l'état Jenkins/Gitea ; le XML versionné porte `__WEBHOOK_TOKEN__`.
- **Aucun manifeste `stoa` modifié, aucun Ingress, worker-3 intouché.**
- Pods utilitaires éphémères : `kubectl -n ci run f1-* --rm -i --restart=Never --image=curlimages/curl:8.10.1`.
- Commits `stoa-labs` : conventionnels, signés DCO (`git commit -s`).
- Le fichier-véhicule des push de test est `PROBE.md` (le `Jenkinsfile` n'est modifié que pour la porte verte et la contre-épreuve).

## Interfaces stables

| Objet | Valeur exacte |
|---|---|
| Jeton d'invocation GWT | `openssl rand -hex 24`, variable de session, placeholder versionné `__WEBHOOK_TOKEN__` |
| URL webhook | `http://jenkins.ci.svc.cluster.local:8080/generic-webhook-trigger/invoke?token=<jeton>` |
| Secret Vault | `secret/ci/probe-status`, champ `token` (kv-v2 → data path `secret/data/ci/probe-status`, couvert par la policy `jenkins-agent`) |
| PAT Gitea | user `ci`, nom `probe-status`, scope `write:repository` |
| Statut de commit | `context: jenkins/probe`, `target_url: BUILD_URL` |
| SHA visé | `env.GWT_AFTER` (webhook) sinon `GIT_COMMIT` du `checkout scm` (manuel) |
| Fichiers versionnés | `docs/superpowers/plans/2026-07-28-jenkins-probe-job.xml` (mis à jour), `docs/superpowers/plans/2026-07-28-probe-Jenkinsfile.groovy` (nouveau) |

---

## Task 1 : Porte de preuve à blanc — un push ne déclenche rien aujourd'hui

**Files:** aucun (constat live).

**Interfaces:** produit le numéro de build de référence `N0` et le SHA `S1` du push à blanc.

- [ ] **Step 1 : Relever l'état de référence Jenkins**

```bash
ssh worker-1 'sudo k3s kubectl -n ci run f1-t1a --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s "http://jenkins.ci.svc.cluster.local:8080/job/probe/api/json?tree=nextBuildNumber,lastBuild\[number,result\]"'
```

Noter `nextBuildNumber` (→ `N0 = nextBuildNumber`).

- [ ] **Step 2 : Push à blanc via l'API Gitea (création de `PROBE.md`)**

```bash
ssh worker-1 'sudo k3s kubectl -n ci run f1-t1b --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s -X POST -u ci:ci-bootstrap -H "Content-Type: application/json" \
    -d "{\"content\":\"RjEgYmFzZWxpbmUgcGluZwo=\",\"message\":\"chore(f1): push à blanc — porte de preuve baseline\"}" \
    http://gitea.ci.svc.cluster.local:3000/api/v1/repos/ci/probe/contents/PROBE.md'
```

(`RjEgYmFzZWxpbmUgcGluZwo=` = base64 de `F1 baseline ping\n`.) Noter le SHA du commit renvoyé (→ `S1`).

- [ ] **Step 3 : Attendre 90 s, vérifier qu'il ne s'est RIEN passé**

```bash
sleep 90
ssh worker-1 'sudo k3s kubectl -n ci run f1-t1c --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- sh -c "
  curl -s \"http://jenkins.ci.svc.cluster.local:8080/job/probe/api/json?tree=nextBuildNumber\" ; echo ;
  curl -s -u ci:ci-bootstrap http://gitea.ci.svc.cluster.local:3000/api/v1/repos/ci/probe/commits/<S1>/status"'
```

Attendu : `nextBuildNumber` == `N0` (aucun build), statut du commit vide (`"state":""`, `"statuses":null` ou `[]`). **C'est la porte qui doit échouer maintenant** — si un build part, quelque chose est déjà câblé : s'arrêter et comprendre.

---

## Task 2 : Trigger GWT sur le job `probe`

**Files:**
- Modify: `docs/superpowers/plans/2026-07-28-jenkins-probe-job.xml` (ajout du bloc `<properties>`, jeton en placeholder)

**Interfaces:**
- Consomme : job `probe` existant, plugin GWT 2.4.2.
- Produit : endpoint `…/generic-webhook-trigger/invoke?token=<jeton>` actif, filtre `^refs/heads/main$`, variables `GWT_REF`/`GWT_AFTER`.

- [ ] **Step 1 : Frapper le jeton (session uniquement)**

```bash
WEBHOOK_TOKEN=$(openssl rand -hex 24)
```

- [ ] **Step 2 : Construire le config.xml complet**

Écrire dans le scratchpad `f1-config.xml` (jeton réel substitué à `__WEBHOOK_TOKEN__`) :

```xml
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <actions/>
  <description>Pipeline de preuve G-c : clone Gitea (ci/probe, public, sans credential), authentification Vault par identité de pod (SA jenkins-agent), lecture de secret/ci/probe. F1 : déclenché par push Gitea (generic-webhook-trigger) ; le pipeline pose le statut de commit via un PAT lu dans Vault par identité de pod.</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <org.jenkinsci.plugins.workflow.job.properties.DisableConcurrentBuildsJobProperty/>
    <org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
      <triggers>
        <org.jenkinsci.plugins.gwt.GenericTrigger plugin="generic-webhook-trigger@2.4.2">
          <spec></spec>
          <genericVariables>
            <org.jenkinsci.plugins.gwt.GenericVariable><key>GWT_REF</key><value>$.ref</value></org.jenkinsci.plugins.gwt.GenericVariable>
            <org.jenkinsci.plugins.gwt.GenericVariable><key>GWT_AFTER</key><value>$.after</value></org.jenkinsci.plugins.gwt.GenericVariable>
          </genericVariables>
          <printContributedVariables>true</printContributedVariables>
          <printPostContent>false</printPostContent>
          <token>__WEBHOOK_TOKEN__</token>
          <silentResponse>false</silentResponse>
          <regexpFilterText>$GWT_REF</regexpFilterText>
          <regexpFilterExpression>^refs/heads/main$</regexpFilterExpression>
          <overrideQuietPeriod>false</overrideQuietPeriod>
          <shouldNotFlattern>false</shouldNotFlattern>
          <allowSeveralTriggersPerBuild>false</allowSeveralTriggersPerBuild>
        </org.jenkinsci.plugins.gwt.GenericTrigger>
      </triggers>
    </org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>http://gitea.ci.svc.cluster.local:3000/ci/probe.git</url>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>*/main</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
      <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
      <submoduleCfg class="empty-list"/>
      <extensions/>
    </scm>
    <scriptPath>Jenkinsfile</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
```

- [ ] **Step 3 : POSTer la config dans Jenkins (crumb géré, depuis le pod)**

```bash
ssh worker-1 'sudo k3s kubectl -n ci exec -i deploy/jenkins -- bash -c "
  cat > /tmp/f1-config.xml
  CRUMB_RAW=\$(curl -s -c /tmp/f1-cj -w \"HTTPCODE=%{http_code}\" http://localhost:8080/crumbIssuer/api/json)
  if echo \"\$CRUMB_RAW\" | grep -q HTTPCODE=200; then
    CRUMB=\$(echo \"\$CRUMB_RAW\" | sed -n \"s/.*\\\"crumb\\\":\\\"\\([^\\\"]*\\)\\\".*/\\1/p\")
    HDR=\"Jenkins-Crumb: \$CRUMB\"
  else
    HDR=\"X-No-Crumb: 1\"
  fi
  curl -s -o /dev/null -w \"%{http_code}\" -b /tmp/f1-cj -H \"\$HDR\" -H \"Content-Type: application/xml\" \
    -X POST --data-binary @/tmp/f1-config.xml http://localhost:8080/job/probe/config.xml
  rm -f /tmp/f1-config.xml /tmp/f1-cj"' < <scratchpad>/f1-config.xml
```

Attendu : `200`.

- [ ] **Step 4 : Read-back**

```bash
ssh worker-1 'sudo k3s kubectl -n ci run f1-t2a --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s http://jenkins.ci.svc.cluster.local:8080/job/probe/config.xml' | grep -c "GenericTrigger\|GWT_AFTER\|refs/heads/main"
```

Attendu : le trigger, les deux variables et le filtre sont présents (le jeton relu doit être celui frappé au Step 1).

- [ ] **Step 5 : Contre-épreuves de l'endpoint (mauvais jeton, puis bon jeton)**

```bash
# Mauvais jeton → aucun job ne matche
ssh worker-1 'sudo k3s kubectl -n ci run f1-t2b --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s -X POST -H "Content-Type: application/json" -d "{\"ref\":\"refs/heads/main\",\"after\":\"deadbeef\"}" \
  "http://jenkins.ci.svc.cluster.local:8080/generic-webhook-trigger/invoke?token=mauvais-jeton"'
# Bon jeton, ref non-main → filtré, aucun build
… token=$WEBHOOK_TOKEN … -d "{\"ref\":\"refs/heads/dev\",\"after\":\"deadbeef\"}"
# Bon jeton, ref main → build déclenché (ancien Jenkinsfile → vert, sans statut)
… token=$WEBHOOK_TOKEN … -d "{\"ref\":\"refs/heads/main\",\"after\":\"<S1>\"}"
```

Attendu : réponse GWT « did not find any jobs » / « Did not match » pour les deux premiers ; `triggered: true` + build `N0` lancé pour le troisième. Vérifier la cause :

```bash
ssh worker-1 'sudo k3s kubectl -n ci run f1-t2c --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s "http://jenkins.ci.svc.cluster.local:8080/job/probe/<N0>/api/json?tree=result,actions\[causes\[shortDescription\]\]"'
```

Attendu : cause « Generic Cause », `result: SUCCESS` (l'ancien Jenkinsfile passe encore — le statut de commit n'existe pas à ce stade, c'est normal).

- [ ] **Step 6 : Mettre à jour le XML versionné (placeholder) et commiter**

Reporter le config.xml du Step 2 (avec `__WEBHOOK_TOKEN__`, PAS le jeton réel) dans `docs/superpowers/plans/2026-07-28-jenkins-probe-job.xml`, avec un commentaire XML en tête expliquant la re-frappe du jeton à la reconstruction.

```bash
cd /Users/potomitan/stoa-platform/stoa-labs
git add docs/superpowers/plans/2026-07-28-jenkins-probe-job.xml
git commit -s -m "feat(ci): trigger generic-webhook sur le job probe (jeton hors Git)"
```

---

## Task 3 : Webhook Gitea → moitié « déclenchement sans action humaine » de la porte

**Files:** aucun (état Gitea).

**Interfaces:**
- Consomme : l'endpoint GWT de la T2 (jeton réel en variable de session).
- Produit : webhook push actif sur `ci/probe` ; build auto-déclenché par push API.

- [ ] **Step 1 : Créer le webhook**

```bash
ssh worker-1 'sudo k3s kubectl -n ci run f1-t3a --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s -X POST -u ci:ci-bootstrap -H "Content-Type: application/json" \
    -d "{\"type\":\"gitea\",\"active\":true,\"events\":[\"push\"],\"config\":{\"url\":\"http://jenkins.ci.svc.cluster.local:8080/generic-webhook-trigger/invoke?token=<WEBHOOK_TOKEN>\",\"content_type\":\"json\"}}" \
    http://gitea.ci.svc.cluster.local:3000/api/v1/repos/ci/probe/hooks'
```

Attendu : JSON du hook créé (`"active":true`, `"events":["push"]`). `ALLOWED_HOST_LIST=jenkins.ci.svc.cluster.local` (lot 1) doit laisser passer — si Gitea refuse l'URL, s'arrêter : c'est l'allowlist qui parle.

- [ ] **Step 2 : Read-back**

```bash
… curl -s -u ci:ci-bootstrap http://gitea.ci.svc.cluster.local:3000/api/v1/repos/ci/probe/hooks'
```

Attendu : exactement 1 hook, actif, événement `push`.

- [ ] **Step 3 : Push réel → build sans action humaine**

Relever `nextBuildNumber` (→ `N1`), puis pousser une mise à jour de `PROBE.md` (PUT avec le `sha` du fichier, contenu base64 de `F1 webhook ping\n`), attendre ≤ 90 s :

```bash
# GET contents pour le sha du fichier, puis :
… curl -s -X PUT -u ci:ci-bootstrap -H "Content-Type: application/json" \
    -d "{\"content\":\"RjEgd2ViaG9vayBwaW5nCg==\",\"message\":\"chore(f1): ping webhook\",\"sha\":\"<sha-PROBE.md>\"}" \
    http://gitea.ci.svc.cluster.local:3000/api/v1/repos/ci/probe/contents/PROBE.md'
# poll jusqu'à 90 s :
… curl -s "http://jenkins.ci.svc.cluster.local:8080/job/probe/api/json?tree=nextBuildNumber,lastBuild\[number,result\]"'
```

Attendu : build `N1` créé **sans aucune action côté Jenkins**, cause « Generic Cause ». (Toujours vert-sans-statut : l'ancien Jenkinsfile ne poste rien.) **La moitié « déclenchement » de la porte F1 est acquise.**

---

## Task 4 : PORTE UTILISATEUR — PAT Gitea écrit dans Vault (jeton racine hors ligne)

**Files:** aucun (état Gitea + Vault).

**Interfaces:**
- Consomme : jeton racine Vault (exploitant, hors session).
- Produit : `secret/ci/probe-status` lisible par le rôle `jenkins-agent`.

- [ ] **Step 1 : Idempotence — purger un éventuel PAT homonyme**

```bash
ssh worker-1 'sudo k3s kubectl -n ci run f1-t4a --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s -o /dev/null -w "%{http_code}" -X DELETE -u ci:ci-bootstrap \
  http://gitea.ci.svc.cluster.local:3000/api/v1/users/ci/tokens/probe-status'
```

Attendu : `204` (supprimé) ou `404`/`422` (n'existait pas) — les deux sont sains.

- [ ] **Step 2 : Stager le script de provisioning dans vault-0**

Le script crée le PAT **dans le cluster** et l'écrit dans Vault sans jamais l'afficher :

```sh
#!/bin/sh
# /tmp/f1-provision.sh — exécuté DANS vault-0 ; $1 = jeton racine (jamais loggé)
set -eu
VAULT_TOKEN="$1"; export VAULT_TOKEN
wget -q -O /tmp/f1-pat.json --header='Content-Type: application/json' \
  --post-data='{"name":"probe-status","scopes":["write:repository"]}' \
  'http://ci:ci-bootstrap@gitea.ci.svc.cluster.local:3000/api/v1/users/ci/tokens'
PAT=$(sed -n 's/.*"sha1":"\([^"]*\)".*/\1/p' /tmp/f1-pat.json)
rm -f /tmp/f1-pat.json
[ -n "$PAT" ] || { echo "ECHEC: PAT non extrait"; exit 1; }
vault kv put secret/ci/probe-status token="$PAT" >/dev/null
unset VAULT_TOKEN
echo "OK: secret/ci/probe-status ecrit (PAT probe-status, scope write:repository)"
```

Staging : `ssh worker-1 'sudo k3s kubectl -n ci exec -i vault-0 -- sh -c "cat > /tmp/f1-provision.sh"' < f1-provision.sh`

- [ ] **Step 3 : Remettre la commande à l'exploitant (AskUserQuestion) et attendre son feu vert**

```bash
ssh -t worker-1 'read -r -s -p "Jeton racine Vault : " VT; echo; sudo k3s kubectl -n ci exec vault-0 -- sh /tmp/f1-provision.sh "$VT"; unset VT'
```

Le jeton est saisi masqué (`read -s`), n'entre ni dans l'historique local ni dans la session agent. Attendu : `OK: secret/ci/probe-status ecrit …`.

- [ ] **Step 4 : Vérifier par l'identité de pod (la seule qui compte) et nettoyer**

```bash
ssh worker-1 'sudo k3s kubectl -n ci run f1-t4b --rm -i --restart=Never \
  --overrides="{\"spec\":{\"serviceAccountName\":\"jenkins-agent\"}}" \
  --image=hashicorp/vault:1.18 -- sh -c "
    set +x
    VT=\$(vault write -address=http://vault.ci.svc.cluster.local:8200 -field=token \
      auth/kubernetes/login role=jenkins-agent \
      jwt=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token))
    LEN=\$(VAULT_TOKEN=\$VT vault kv get -address=http://vault.ci.svc.cluster.local:8200 \
      -field=token secret/ci/probe-status | wc -c)
    echo \"PAT présent, longueur \$LEN\""'
ssh worker-1 'sudo k3s kubectl -n ci exec vault-0 -- rm -f /tmp/f1-provision.sh'
```

Attendu : `PAT présent, longueur ≥ 40` (jamais la valeur). Le script est effacé de vault-0.

---

## Task 5 : Nouveau Jenkinsfile → PORTE F1 VERTE

**Files:**
- Create: `docs/superpowers/plans/2026-07-28-probe-Jenkinsfile.groovy` (copie versionnée)

**Interfaces:**
- Consomme : `secret/ci/probe-status` (T4), trigger + webhook (T2/T3).
- Produit : statuts de commit `pending`→`success|failure`, SHA du commit vert `S2`.

- [ ] **Step 0 : Vérifier `wget --post-data` dans l'image vault (pré-requis du postStatus)**

```bash
ssh worker-1 'sudo k3s kubectl -n ci run f1-t5a --rm -i --restart=Never --image=hashicorp/vault:1.18 -- \
  sh -c "wget --help 2>&1 | grep -c post-data"'
```

Attendu : ≥ 1. Sinon : ajouter un `containerTemplate` `curlimages/curl:8.10.1` au podTemplate et poster depuis ce conteneur (le PAT transite alors par un fichier de workspace effacé aussitôt).

- [ ] **Step 1 : Pousser le nouveau Jenkinsfile via l'API (PUT, avec le sha du fichier actuel)**

Contenu exact (aussi versionné au Step 4) :

```groovy
// ci/probe — preuve G-c (lot 1) + F1 : statut de commit posé par identité de pod.
// Le PAT Gitea est lu dans Vault À CHAQUE appel (SA jenkins-agent, mécanique
// G-c) : aucun secret statique dans Jenkins ni dans ce fichier.
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
```

Push : base64 du fichier → `PUT /api/v1/repos/ci/probe/contents/Jenkinsfile` (message : `feat(f1): statut de commit par identité de pod`). Noter le SHA (→ `S2`).

- [ ] **Step 2 : Le build part seul et vire au vert**

Poll ≤ 3 min : `GET /job/probe/api/json?tree=lastBuild[number,result]` → nouveau numéro, `result: SUCCESS`. En cas d'échec, lire la console (`/job/probe/<n>/consoleText`) — suspects : quoting du JSON, wget, droits du PAT.

- [ ] **Step 3 : PORTE F1 — le commit est VERT dans Gitea**

```bash
… curl -s -u ci:ci-bootstrap http://gitea.ci.svc.cluster.local:3000/api/v1/repos/ci/probe/commits/<S2>/status'
```

Attendu : `"state":"success"`, un statut `context: jenkins/probe`, `target_url` vers le build. **Porte F1 verte.**

- [ ] **Step 4 : Versionner le Jenkinsfile et commiter**

```bash
cd /Users/potomitan/stoa-platform/stoa-labs
git add docs/superpowers/plans/2026-07-28-probe-Jenkinsfile.groovy
git commit -s -m "feat(ci): le pipeline probe pose son statut de commit par identité de pod"
```

---

## Task 6 : CONTRE-ÉPREUVE — Jenkinsfile cassé → statut ROUGE, puis retour au vert

**Files:** aucun (commits sur `ci/probe`).

**Interfaces:** produit les SHA `S3` (saboté, rouge) et `S4` (restauré, vert).

- [ ] **Step 1 : Pousser le sabotage**

Même Jenkinsfile, avec — juste après le bloc `sh` de la preuve G-c, avant `postStatus(sha, 'success', …)` :

```groovy
        sh 'echo SABOTAGE-F1 && exit 1'
```

PUT sur `Jenkinsfile` (message : `test(f1): contre-épreuve — sabotage, le statut doit rougir`). Noter `S3`.

- [ ] **Step 2 : Build auto rouge, statut rouge**

Poll : nouveau build, `result: FAILURE`. Puis :

```bash
… /commits/<S3>/status'
```

Attendu : `"state":"failure"`, context `jenkins/probe`. **Un statut qui sait rougir : la contre-épreuve est faite.**

- [ ] **Step 3 : Restaurer, revenir au vert**

PUT du Jenkinsfile sain (message : `fix(f1): restauration post-contre-épreuve`). Noter `S4`. Poll : build vert, `/commits/<S4>/status` → `success`. (Troisième déclenchement automatique consécutif — la récurrence est prouvée de surcroît.)

- [ ] **Step 4 : Assertions annexes (rejouées du lot 1)**

```bash
# Aucun credential statique n'est apparu dans Jenkins :
ssh worker-1 'sudo k3s kubectl -n ci exec deploy/jenkins -- sh -c \
  "ls /var/jenkins_home/credentials.xml 2>/dev/null && echo ECHEC-credentials-statiques || echo OK-aucun-credential-statique"'
# Le jeton webhook réel n'est dans aucun fichier versionné :
cd /Users/potomitan/stoa-platform/stoa-labs && git grep -c "$WEBHOOK_TOKEN" || echo "OK-jeton-hors-Git"
```

Attendu : `OK-aucun-credential-statique` et `OK-jeton-hors-Git`.

---

## Task 7 : Preuves, GOAL, mémoire — clôture F1

**Files:**
- Modify: `docs/superpowers/plans/2026-07-28-f1-webhook-statut.md` (section « Preuve d'exécution » appendue, cases cochées)
- Modify: `poc-control-plane-federation/GOAL-socle-vers-gateway-2026-07-28.md` (ligne « État » de F1)
- Modify: mémoire agent (`memory/socle-ci-lot1-deploye.md` + `MEMORY.md`)

- [ ] **Step 1 : Appendre la « Preuve d'exécution (2026-07-28) »** — numéros de build, SHA `S1..S4`, réponses d'API réelles (statuts, causes), écarts éventuels documentés.

- [ ] **Step 2 : GOAL lot 2, jalon F1** — remplacer la ligne `**État :** tout est préparé, rien n'est câblé (écart assumé du lot 1, acté au plan).` par un état « fermé le 2026-07-28 » renvoyant vers ce plan.

- [ ] **Step 3 : Commit final**

```bash
cd /Users/potomitan/stoa-platform/stoa-labs
git add docs/superpowers/plans/2026-07-28-f1-webhook-statut.md poc-control-plane-federation/GOAL-socle-vers-gateway-2026-07-28.md
git commit -s -m "docs(ci): preuve F1 — push→build sans action humaine, statut vert/rouge dans Gitea"
```

- [ ] **Step 4 : Vérification finale avant clôture** (superpowers:verification-before-completion) — relire la porte F1 du GOAL mot à mot et pointer chaque preuve correspondante ; mettre à jour la mémoire.

## Auto-revue du plan

- **Couverture spéc :** D1→T2, D2→T5, D3→T4, D4→T6, D5→T2 S6, D6→T5 S4 + T7 ; porte « doit échouer d'abord » → T1 ; gestion d'erreur §5 → contre-épreuves T2 S5 (jeton faux, ref filtrée) et T6.
- **Placeholders :** `<JETON_RACINE>` (voulu, secret zéro), `__WEBHOOK_TOKEN__` (voulu, D5), `<S1..S4>`/`<N0..N1>`/`<sha-PROBE.md>` (valeurs relevées en exécution) — aucun TBD.
- **Cohérence :** chemin Vault, nom de PAT, context de statut identiques partout (cf. Interfaces stables) ; le Jenkinsfile de T6 S1 dérive exactement de T5 S1.
- **Risque résiduel connu :** forme XML GWT (champs 2.4.2) — le précédent POC utilise la même version ; le read-back T2 S4 et la contre-épreuve T2 S5 attrapent toute divergence. Support `--post-data` de busybox wget vérifié en T5 S0 avec variante de repli.
