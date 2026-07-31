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
- **`<MDP_CI>`** = mot de passe du user Gitea `ci`, lu sur worker-1 dans `/root/gitea-ci-pass` (0600) au moment de rejouer le geste. Même convention que `<JETON_RACINE>` : le substituant est versionné, jamais la valeur.
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

- [x] **Step 1 : Relever l'état de référence Jenkins**

```bash
ssh worker-1 'sudo k3s kubectl -n ci run f1-t1a --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s "http://jenkins.ci.svc.cluster.local:8080/job/probe/api/json?tree=nextBuildNumber,lastBuild\[number,result\]"'
```

Noter `nextBuildNumber` (→ `N0 = nextBuildNumber`).

- [x] **Step 2 : Push à blanc via l'API Gitea (création de `PROBE.md`)**

```bash
ssh worker-1 'sudo k3s kubectl -n ci run f1-t1b --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s -X POST -u ci:<MDP_CI> -H "Content-Type: application/json" \
    -d "{\"content\":\"RjEgYmFzZWxpbmUgcGluZwo=\",\"message\":\"chore(f1): push à blanc — porte de preuve baseline\"}" \
    http://gitea.ci.svc.cluster.local:3000/api/v1/repos/ci/probe/contents/PROBE.md'
```

(`RjEgYmFzZWxpbmUgcGluZwo=` = base64 de `F1 baseline ping\n`.) Noter le SHA du commit renvoyé (→ `S1`).

- [x] **Step 3 : Attendre 90 s, vérifier qu'il ne s'est RIEN passé**

```bash
sleep 90
ssh worker-1 'sudo k3s kubectl -n ci run f1-t1c --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- sh -c "
  curl -s \"http://jenkins.ci.svc.cluster.local:8080/job/probe/api/json?tree=nextBuildNumber\" ; echo ;
  curl -s -u ci:<MDP_CI> http://gitea.ci.svc.cluster.local:3000/api/v1/repos/ci/probe/commits/<S1>/status"'
```

Attendu : `nextBuildNumber` == `N0` (aucun build), statut du commit vide (`"state":""`, `"statuses":null` ou `[]`). **C'est la porte qui doit échouer maintenant** — si un build part, quelque chose est déjà câblé : s'arrêter et comprendre.

---

## Task 2 : Trigger GWT sur le job `probe`

**Files:**
- Modify: `docs/superpowers/plans/2026-07-28-jenkins-probe-job.xml` (ajout du bloc `<properties>`, jeton en placeholder)

**Interfaces:**
- Consomme : job `probe` existant, plugin GWT 2.4.2.
- Produit : endpoint `…/generic-webhook-trigger/invoke?token=<jeton>` actif, filtre `^refs/heads/main$`, variables `GWT_REF`/`GWT_AFTER`.

- [x] **Step 1 : Frapper le jeton (session uniquement)**

```bash
WEBHOOK_TOKEN=$(openssl rand -hex 24)
```

- [x] **Step 2 : Construire le config.xml complet**

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

- [x] **Step 3 : POSTer la config dans Jenkins (crumb géré, depuis le pod)**

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

- [x] **Step 4 : Read-back**

```bash
ssh worker-1 'sudo k3s kubectl -n ci run f1-t2a --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s http://jenkins.ci.svc.cluster.local:8080/job/probe/config.xml' | grep -c "GenericTrigger\|GWT_AFTER\|refs/heads/main"
```

Attendu : le trigger, les deux variables et le filtre sont présents (le jeton relu doit être celui frappé au Step 1).

- [x] **Step 5 : Contre-épreuves de l'endpoint (mauvais jeton, puis bon jeton)**

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

- [x] **Step 6 : Mettre à jour le XML versionné (placeholder) et commiter**

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

- [x] **Step 1 : Créer le webhook**

```bash
ssh worker-1 'sudo k3s kubectl -n ci run f1-t3a --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s -X POST -u ci:<MDP_CI> -H "Content-Type: application/json" \
    -d "{\"type\":\"gitea\",\"active\":true,\"events\":[\"push\"],\"config\":{\"url\":\"http://jenkins.ci.svc.cluster.local:8080/generic-webhook-trigger/invoke?token=<WEBHOOK_TOKEN>\",\"content_type\":\"json\"}}" \
    http://gitea.ci.svc.cluster.local:3000/api/v1/repos/ci/probe/hooks'
```

Attendu : JSON du hook créé (`"active":true`, `"events":["push"]`). `ALLOWED_HOST_LIST=jenkins.ci.svc.cluster.local` (lot 1) doit laisser passer — si Gitea refuse l'URL, s'arrêter : c'est l'allowlist qui parle.

- [x] **Step 2 : Read-back**

```bash
… curl -s -u ci:<MDP_CI> http://gitea.ci.svc.cluster.local:3000/api/v1/repos/ci/probe/hooks'
```

Attendu : exactement 1 hook, actif, événement `push`.

- [x] **Step 3 : Push réel → build sans action humaine**

Relever `nextBuildNumber` (→ `N1`), puis pousser une mise à jour de `PROBE.md` (PUT avec le `sha` du fichier, contenu base64 de `F1 webhook ping\n`), attendre ≤ 90 s :

```bash
# GET contents pour le sha du fichier, puis :
… curl -s -X PUT -u ci:<MDP_CI> -H "Content-Type: application/json" \
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

- [x] **Step 1 : Idempotence — purger un éventuel PAT homonyme**

```bash
ssh worker-1 'sudo k3s kubectl -n ci run f1-t4a --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s -o /dev/null -w "%{http_code}" -X DELETE -u ci:<MDP_CI> \
  http://gitea.ci.svc.cluster.local:3000/api/v1/users/ci/tokens/probe-status'
```

Attendu : `204` (supprimé) ou `404`/`422` (n'existait pas) — les deux sont sains.

- [x] **Step 2 : Stager le script de provisioning dans vault-0**

Le script crée le PAT **dans le cluster** et l'écrit dans Vault sans jamais l'afficher :

```sh
#!/bin/sh
# /tmp/f1-provision.sh — exécuté DANS vault-0 ; $1 = jeton racine (jamais loggé)
set -eu
VAULT_TOKEN="$1"; export VAULT_TOKEN
wget -q -O /tmp/f1-pat.json --header='Content-Type: application/json' \
  --post-data='{"name":"probe-status","scopes":["write:repository"]}' \
  'http://ci:<MDP_CI>@gitea.ci.svc.cluster.local:3000/api/v1/users/ci/tokens'
PAT=$(sed -n 's/.*"sha1":"\([^"]*\)".*/\1/p' /tmp/f1-pat.json)
rm -f /tmp/f1-pat.json
[ -n "$PAT" ] || { echo "ECHEC: PAT non extrait"; exit 1; }
vault kv put secret/ci/probe-status token="$PAT" >/dev/null
unset VAULT_TOKEN
echo "OK: secret/ci/probe-status ecrit (PAT probe-status, scope write:repository)"
```

Staging : `ssh worker-1 'sudo k3s kubectl -n ci exec -i vault-0 -- sh -c "cat > /tmp/f1-provision.sh"' < f1-provision.sh`

- [x] **Step 3 : Remettre la commande à l'exploitant (AskUserQuestion) et attendre son feu vert**

```bash
ssh -t worker-1 'read -r -s -p "Jeton racine Vault : " VT; echo; sudo k3s kubectl -n ci exec vault-0 -- sh /tmp/f1-provision.sh "$VT"; unset VT'
```

Le jeton est saisi masqué (`read -s`), n'entre ni dans l'historique local ni dans la session agent. Attendu : `OK: secret/ci/probe-status ecrit …`.

- [x] **Step 4 : Vérifier par l'identité de pod (la seule qui compte) et nettoyer**

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

- [x] **Step 0 : Vérifier `wget --post-data` dans l'image vault (pré-requis du postStatus)**

```bash
ssh worker-1 'sudo k3s kubectl -n ci run f1-t5a --rm -i --restart=Never --image=hashicorp/vault:1.18 -- \
  sh -c "wget --help 2>&1 | grep -c post-data"'
```

Attendu : ≥ 1. Sinon : ajouter un `containerTemplate` `curlimages/curl:8.10.1` au podTemplate et poster depuis ce conteneur (le PAT transite alors par un fichier de workspace effacé aussitôt).

- [x] **Step 1 : Pousser le nouveau Jenkinsfile via l'API (PUT, avec le sha du fichier actuel)**

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

- [x] **Step 2 : Le build part seul et vire au vert**

Poll ≤ 3 min : `GET /job/probe/api/json?tree=lastBuild[number,result]` → nouveau numéro, `result: SUCCESS`. En cas d'échec, lire la console (`/job/probe/<n>/consoleText`) — suspects : quoting du JSON, wget, droits du PAT.

- [x] **Step 3 : PORTE F1 — le commit est VERT dans Gitea**

```bash
… curl -s -u ci:<MDP_CI> http://gitea.ci.svc.cluster.local:3000/api/v1/repos/ci/probe/commits/<S2>/status'
```

Attendu : `"state":"success"`, un statut `context: jenkins/probe`, `target_url` vers le build. **Porte F1 verte.**

- [x] **Step 4 : Versionner le Jenkinsfile et commiter**

```bash
cd /Users/potomitan/stoa-platform/stoa-labs
git add docs/superpowers/plans/2026-07-28-probe-Jenkinsfile.groovy
git commit -s -m "feat(ci): le pipeline probe pose son statut de commit par identité de pod"
```

---

## Task 6 : CONTRE-ÉPREUVE — Jenkinsfile cassé → statut ROUGE, puis retour au vert

**Files:** aucun (commits sur `ci/probe`).

**Interfaces:** produit les SHA `S3` (saboté, rouge) et `S4` (restauré, vert).

- [x] **Step 1 : Pousser le sabotage**

Même Jenkinsfile, avec — juste après le bloc `sh` de la preuve G-c, avant `postStatus(sha, 'success', …)` :

```groovy
        sh 'echo SABOTAGE-F1 && exit 1'
```

PUT sur `Jenkinsfile` (message : `test(f1): contre-épreuve — sabotage, le statut doit rougir`). Noter `S3`.

- [x] **Step 2 : Build auto rouge, statut rouge**

Poll : nouveau build, `result: FAILURE`. Puis :

```bash
… /commits/<S3>/status'
```

Attendu : `"state":"failure"`, context `jenkins/probe`. **Un statut qui sait rougir : la contre-épreuve est faite.**

- [x] **Step 3 : Restaurer, revenir au vert**

PUT du Jenkinsfile sain (message : `fix(f1): restauration post-contre-épreuve`). Noter `S4`. Poll : build vert, `/commits/<S4>/status` → `success`. (Troisième déclenchement automatique consécutif — la récurrence est prouvée de surcroît.)

- [x] **Step 4 : Assertions annexes (rejouées du lot 1)**

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

- [x] **Step 1 : Appendre la « Preuve d'exécution (2026-07-28) »** — numéros de build, SHA `S1..S4`, réponses d'API réelles (statuts, causes), écarts éventuels documentés.

- [x] **Step 2 : GOAL lot 2, jalon F1** — remplacer la ligne `**État :** tout est préparé, rien n'est câblé (écart assumé du lot 1, acté au plan).` par un état « fermé le 2026-07-28 » renvoyant vers ce plan.

- [x] **Step 3 : Commit final**

```bash
cd /Users/potomitan/stoa-platform/stoa-labs
git add docs/superpowers/plans/2026-07-28-f1-webhook-statut.md poc-control-plane-federation/GOAL-socle-vers-gateway-2026-07-28.md
git commit -s -m "docs(ci): preuve F1 — push→build sans action humaine, statut vert/rouge dans Gitea"
```

- [x] **Step 4 : Vérification finale avant clôture** (superpowers:verification-before-completion) — relire la porte F1 du GOAL mot à mot et pointer chaque preuve correspondante ; mettre à jour la mémoire.

## Auto-revue du plan

- **Couverture spéc :** D1→T2, D2→T5, D3→T4, D4→T6, D5→T2 S6, D6→T5 S4 + T7 ; porte « doit échouer d'abord » → T1 ; gestion d'erreur §5 → contre-épreuves T2 S5 (jeton faux, ref filtrée) et T6.
- **Placeholders :** `<JETON_RACINE>` (voulu, secret zéro), `__WEBHOOK_TOKEN__` (voulu, D5), `<S1..S4>`/`<N0..N1>`/`<sha-PROBE.md>` (valeurs relevées en exécution) — aucun TBD.
- **Cohérence :** chemin Vault, nom de PAT, context de statut identiques partout (cf. Interfaces stables) ; le Jenkinsfile de T6 S1 dérive exactement de T5 S1.
- **Risque résiduel connu :** forme XML GWT (champs 2.4.2) — le précédent POC utilise la même version ; le read-back T2 S4 et la contre-épreuve T2 S5 attrapent toute divergence. Support `--post-data` de busybox wget vérifié en T5 S0 avec variante de repli.

---

## Preuve d'exécution (2026-07-28 / 2026-07-29)

Exécution inline (`executing-plans`), séquentielle, sur le cluster k3s labs via `ssh worker-1 'sudo k3s kubectl …'`.

### Porte F1 — verte

| Élément | Valeur relevée |
|---|---|
| Déclenchement | webhook Gitea `push` → `generic-webhook-trigger`, cause Jenkins **`Generic Cause`** |
| `S2` (Jenkinsfile F1) | `fc8c4a9b6c3b5e373da21a78e02a33e5544a8533` → build **7**, `SUCCESS`, statut **`success`** |
| `S3` (sabotage) | `e4a15058c62c9c910055b2cd407436c32764d5a3` → build **8**, `FAILURE`, statut **`failure`** |
| `S4` (restauration) | `c34f90d6e86674016570aff467ff30f9cf6a34c1` → build **9**, `SUCCESS`, statut **`success`** |
| Statut de commit | `context: jenkins/probe`, `target_url: …/job/probe/<n>/`, `description: probe <state>`, auteur `ci` |
| Secret Vault | `secret/ci/probe-status`, lu par identité de pod (SA `jenkins-agent`), longueur 40 = PAT Gitea sha1 |

Trois déclenchements automatiques consécutifs (7, 8, 9) : la récurrence est prouvée en plus de la porte. Le statut sait rougir (build 8) puis reverdir (build 9) — la contre-épreuve du GOAL est tenue.

**Contre-vérification indépendante (2026-07-29).** Les portes ci-dessus ayant été exécutées dans une autre session, elles ont été **re-mesurées** contre le cluster vivant plutôt que relues : les trois statuts (`fc8c4a9b`→`success`, `e4a1505 8`→`failure`, `c34f90d6`→`success`) et les trois causes de build (`Generic Cause`) ont été relus par API. Puis un **quatrième push, poussé depuis cette session**, a rejoué la porte de bout en bout :

| Élément | Valeur relevée |
|---|---|
| `S5` (push indépendant sur `PROBE.md`) | `f1e0f57165a5984beace30890da69a77209967d8` |
| Build | **10**, cause `Generic Cause`, `SUCCESS` |
| Statut de commit | `success`, `context: jenkins/probe`, `target_url: …/job/probe/10/` |

Vault relu au même moment par identité de pod (SA `jenkins-agent`) : `secret/ci/probe` = `preuve-g8`, `secret/ci/probe-status` présent (longueur 40). `credentials.xml` toujours absent de `/var/jenkins_home`. Le câblage est donc vivant maintenant, pas seulement au moment où il a été posé.

**Assertions annexes rejouées du lot 1 :**

- `credentials.xml` absent de `/var/jenkins_home` → `OK-aucun-credential-statique`.
- Le jeton webhook réel n'est dans aucun fichier versionné : `2026-07-28-jenkins-probe-job.xml` ne porte que le placeholder `__WEBHOOK_TOKEN__` (2 occurrences).
- Portes G-b/G-c du lot 1 rejouées après reconstruction de Vault : login par identité de pod OK, `secret/ci/probe` lisible.

### Incident Vault — écart assumé, à solder

La tâche 4 ne s'est pas déroulée comme planifiée. Chronologie factuelle :

1. Le jeton racine Vault **et** les trois clés de descellement du lot 1 étaient **perdus** côté exploitant. Aucune écriture dans `secret/` n'était donc plus possible : la policy `jenkins-agent` est en lecture seule (`path "secret/data/ci/*" { capabilities = ["read"] }`), et aucune autre identité in-cluster n'existe. `generate-root` et `rekey` exigeant tous deux un quorum de parts, il n'existait aucune voie de récupération.
2. Constat associé, plus grave que F1 : le socle était **à un redémarrage de la panne définitive** (Vault revient scellé après chaque `backup.yml` et à chaque reschedule du pod).
3. Décision de l'exploitant : ré-initialiser Vault (périmètre labo, aucune donnée de valeur — seule la fixture `secret/ci/probe` y vivait). Backend `file` sur `/vault/data` effacé, pod recréé, `vault operator init -key-shares=3 -key-threshold=2`.
4. **La sortie du premier `init` a été affichée dans la session de l'agent** (commande lancée sans TTY depuis l'outil, redirection absente) : les 3 clés et le jeton racine s'y trouvent en clair. Ce matériel doit être considéré comme **brûlé**.
5. Une seconde passe a été outillée pour que les secrets ne quittent jamais le nœud : script exécuté sur worker-1, écrivant l'`init` dans `/root/vault-init-ci.txt` (root, 600), relisant lui-même les parts pour desceller puis reconfigurer (auth Kubernetes, policy + rôle `jenkins-agent`, kv-v2, `secret/ci/probe`, PAT Gitea, `secret/ci/probe-status`).

**Point tranché par la mesure (2026-07-29, session F1) — le matériel brûlé n'est plus en service.** Horodatages relevés sur le cluster :

| Mesure | Valeur |
|---|---|
| `vault-bootstrap.sh` sur worker-1 | écrit `2026-07-29 10:49:27 +0200` (= 08:49 UTC) |
| Démarrage du pod `vault-0` courant | `2026-07-29T08:51:21Z` — l'effacement + redémarrage des étapes 1-2 du script |
| `/vault/data/core/_master` et `_keyring` | écrits `09:21` UTC — l'`init` a donc eu lieu **sur ce pod**, après l'effacement |
| Cluster ID Vault | `c51f3c8b-a6c6-c224-ea31-8156951fd9cd`, différent de celui du lot 1 (`5c0fecc0-1069-b4c0-fbf9-6079eba0b990`) |

Le backend du premier `init` (celui dont la sortie a été affichée en session) a été **effacé** avant l'`init` en service. Les clés brûlées n'ouvrent plus rien : aucun `rekey` n'est requis.

**Anomalie résiduelle, à confirmer par l'exploitant : 30 minutes séparent le redémarrage du pod (08:51) de l'`init` (09:21)**, alors que les étapes 2→3 du script s'enchaînent en moins de 5 minutes (attentes bornées à 180 s + 120 s). Le script n'a donc pas déroulé d'une traite : l'`init` en service a été lancé séparément, et **rien ne prouve que sa sortie soit passée par `/root/vault-init-ci.txt`** (fichier absent à la vérification — supprimé après récupération, ou jamais créé).

**Conséquence à lever avant tout redémarrage :** si personne ne détient les parts de descellement courantes, le socle CI est à nouveau à un `backup.yml` (qui quiesce les pods) ou à un reschedule de la panne définitive — la cause exacte de cet incident. **Vérification non destructive à exécuter par l'exploitant**, qui prouve la détention d'une part valide sans rien modifier :

```bash
ssh -t worker-1 'sudo k3s kubectl -n ci exec vault-0 -- vault operator generate-root -init | grep -i nonce'
# puis, avec le nonce affiché, soumettre UNE part (saisie masquée) :
ssh -t worker-1 'read -r -s -p "Une part de descellement : " K; echo; \
  sudo k3s kubectl -n ci exec vault-0 -- vault operator generate-root -nonce=<NONCE> "$K" | grep -i progress; \
  unset K; sudo k3s kubectl -n ci exec vault-0 -- vault operator generate-root -cancel'
```

Attendu : `Progress 1/2` (la part est valide), puis l'annulation remet l'essai à zéro — aucun jeton racine n'est produit. Si la part est refusée, les clés courantes sont perdues : ré-initialiser **immédiatement** avec `vault-bootstrap.sh` en le laissant dérouler d'une traite, et mettre les parts à l'abri hors ligne avant de toucher à quoi que ce soit d'autre.

**Leçon retenue, applicable au-delà de F1 :** une commande qui *affiche* un secret est un piège, même accompagnée de la consigne « lance-la ailleurs ». Les procédures doivent rediriger la sortie sensible vers un fichier à droits restreints sur le nœud, et ne laisser passer que des messages de progression. C'est la forme retenue pour le script de bootstrap, et celle à reprendre au lot 2.

### Écarts au plan tel qu'écrit

- **T4 Step 2/3** : le script `f1-provision.sh` a été absorbé par le script de bootstrap complet (init + descellement + configuration lot 1 + provisioning F1), la reconstruction de Vault ayant rendu la seule provision insuffisante.
- **T4 Step 1** : la purge du PAT homonyme a servi pour de bon — un premier essai avec jeton vide avait créé un PAT `probe-status` dont la valeur était irrécupérable. Le script a depuis été réordonné pour **valider le jeton Vault avant** toute création côté Gitea, afin qu'un échec ne laisse jamais d'orphelin.
- **T5 Step 0** : `wget --post-data` confirmé présent dans `hashicorp/vault:1.18` — le conteneur `curl` de repli n'a pas été nécessaire.
