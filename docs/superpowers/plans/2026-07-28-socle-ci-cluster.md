# Socle CI sur le cluster k3s labs — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Déployer Gitea, Vault et Jenkins sur le cluster k3s labs, de sorte qu'un pipeline obtienne ses identifiants par l'identité de son pod, sans aucun secret statique.

**Architecture:** Trois Applications Argo CD dans le namespace `ci`, déployées dans l'ordre de dépendance (Gitea → Vault → Jenkins). Aucune exposition publique : l'accès se fait par `kubectl port-forward`. Le stockage est `local-path`, donc les pods avec état sont épinglés à leur nœud, et la sauvegarde des PVC fait partie du lot.

**Tech Stack:** k3s v1.34.5 · Argo CD v3.4.5 · Gitea 1.22 · HashiCorp Vault · Jenkins LTS JDK17 · Ansible · Kustomize

## Global Constraints

- **Dépôt des manifestes : `stoa` (public), pas `stoa-labs`.** Argo CD lit GitHub sans credential ; un dépôt privé exigerait une deploy-key, donc un « secret zéro » interdit par la doctrine.
- **Aucun Ingress, aucune exposition publique** pour Gitea, Vault et Jenkins.
- **Toutes les images épinglées** par tag explicite ou digest. Jamais `:latest`.
- **`storageClassName: local-path`** partout. Longhorn est écarté par la mesure `fsync` (p99 ≈ 10 ms).
- **Namespace unique `ci`.** Il doit être ajouté aux `destinations` de l'AppProject `stoa`, sans quoi toute Application reste bloquée en `Unknown`.
- **`ServerSideApply=true` sans `Force`** dans tous les `syncOptions` ; `allowEmpty: false` posé explicitement.
- **Nœuds du cluster : worker-1 (plan de contrôle), worker-3, worker-4, worker-5.** worker-2 est exclu (isolation Contabo d'un même segment L2).
- **worker-3 est le seul nœud disposant d'un moteur de construction d'images** (Docker actif ; ni podman ni buildah ailleurs — vérifié).
- **Commits :** conventionnels (`feat`/`fix`/`docs`/`chore`), signés DCO (`git commit -s`).

## Interfaces stables (noms utilisés d'une tâche à l'autre)

| Objet | Nom exact |
|---|---|
| Namespace | `ci` |
| Gitea — Service | `gitea.ci.svc.cluster.local:3000` |
| Gitea — StatefulSet / PVC | `gitea` / `gitea-data` |
| Vault — Service | `vault.ci.svc.cluster.local:8200` |
| Vault — StatefulSet / PVC | `vault` / `vault-data` |
| Vault — rôle et politique | `jenkins-agent` |
| ServiceAccount des agents | `jenkins-agent` (namespace `ci`) |
| Jenkins — Deployment / Service / PVC | `jenkins` / `jenkins.ci.svc.cluster.local:8080` / `jenkins-home` |
| Image Jenkins | `gitea.ci.svc.cluster.local:3000/ci/jenkins-go:v1` |

---

## Structure des fichiers

**Dépôt `stoa` (public) — lu par Argo CD**

| Fichier | Responsabilité |
|---|---|
| `deploy/bootstrap/argocd/appproject-stoa.yaml` | *modifié* — ajoute la destination `ci` |
| `deploy/bootstrap/argocd/app-ci-gitea.yaml` | Application Gitea |
| `deploy/bootstrap/argocd/app-ci-vault.yaml` | Application Vault |
| `deploy/bootstrap/argocd/app-ci-jenkins.yaml` | Application Jenkins |
| `deploy/bootstrap/ci/gitea/` | manifestes Gitea (kustomization, statefulset, service) |
| `deploy/bootstrap/ci/vault/` | manifestes Vault + `PrometheusRule` `VaultSealed` |
| `deploy/bootstrap/ci/jenkins/` | manifestes Jenkins + ServiceAccount + RBAC |

**Dépôt `stoa-labs` (privé) — Ansible**

| Fichier | Responsabilité |
|---|---|
| `ansible/roles/cluster_backup/tasks/pvc.yml` | *nouveau* — sauvegarde des PVC `local-path` |
| `ansible/roles/registry_config/` | *nouveau* — `registries.yaml` k3s pour le registre Gitea |
| `ansible/roles/jenkins_image/` | *nouveau* — construction et poussée de l'image Jenkins |
| `ansible/ci-image.yml` | *nouveau* — playbook d'appel |

---

## Task 1 : Gitea déployé et persistant

**Files:**
- Modify: `stoa/deploy/bootstrap/argocd/appproject-stoa.yaml`
- Create: `stoa/deploy/bootstrap/argocd/app-ci-gitea.yaml`
- Create: `stoa/deploy/bootstrap/ci/gitea/kustomization.yaml`
- Create: `stoa/deploy/bootstrap/ci/gitea/statefulset.yaml`
- Create: `stoa/deploy/bootstrap/ci/gitea/service.yaml`

**Interfaces:**
- Consomme : l'AppProject `stoa` et le cluster existants.
- Produit : le Service `gitea.ci.svc.cluster.local:3000`, le namespace `ci`.

- [ ] **Step 1 : Écrire la porte de preuve (elle doit échouer maintenant)**

Créer `stoa/deploy/bootstrap/ci/gitea/PROOF.md` avec l'assertion :

```bash
# Assertion : Gitea répond et son API est servie
kubectl -n ci exec deploy/probe -- curl -sf http://gitea.ci.svc.cluster.local:3000/api/v1/version
```

- [ ] **Step 2 : Lancer l'assertion pour vérifier qu'elle échoue**

```bash
ssh worker-1 'sudo k3s kubectl get ns ci'
```
Attendu : `Error from server (NotFound): namespaces "ci" not found`

- [ ] **Step 3 : Ajouter la destination `ci` à l'AppProject**

Dans `appproject-stoa.yaml`, sous `spec.destinations`, ajouter :

```yaml
    - server: https://kubernetes.default.svc
      namespace: ci
```

- [ ] **Step 4 : Écrire les manifestes Gitea**

`stoa/deploy/bootstrap/ci/gitea/service.yaml` :

```yaml
apiVersion: v1
kind: Service
metadata:
  name: gitea
  namespace: ci
spec:
  type: ClusterIP
  selector:
    app: gitea
  ports:
    - name: http
      port: 3000
      targetPort: 3000
```

`stoa/deploy/bootstrap/ci/gitea/statefulset.yaml` :

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: gitea
  namespace: ci
spec:
  serviceName: gitea
  replicas: 1
  selector:
    matchLabels:
      app: gitea
  template:
    metadata:
      labels:
        app: gitea
    spec:
      containers:
        - name: gitea
          image: gitea/gitea:1.22
          env:
            # ROOT_URL pointe sur le Service interne. La valeur du compose
            # (localhost:13000) est spécifique à Docker et casserait les URL de clone.
            - name: GITEA__server__ROOT_URL
              value: "http://gitea.ci.svc.cluster.local:3000/"
            - name: GITEA__server__HTTP_PORT
              value: "3000"
            - name: GITEA__security__INSTALL_LOCK
              value: "true"
            # Restreint au Service Jenkins. Le compose utilisait "*", acceptable
            # sur un réseau Docker isolé, pas dans un cluster.
            - name: GITEA__webhook__ALLOWED_HOST_LIST
              value: "jenkins.ci.svc.cluster.local"
          ports:
            - containerPort: 3000
          volumeMounts:
            - name: gitea-data
              mountPath: /data
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 1Gi
          readinessProbe:
            httpGet:
              path: /api/v1/version
              port: 3000
            initialDelaySeconds: 20
            periodSeconds: 10
  volumeClaimTemplates:
    - metadata:
        name: gitea-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-path
        resources:
          requests:
            storage: 20Gi
```

`stoa/deploy/bootstrap/ci/gitea/kustomization.yaml` :

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ci
resources:
  - service.yaml
  - statefulset.yaml
```

- [ ] **Step 5 : Écrire l'Application Argo CD**

`stoa/deploy/bootstrap/argocd/app-ci-gitea.yaml` :

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ci-gitea
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: stoa
  source:
    repoURL: https://github.com/stoa-platform/stoa.git
    targetRevision: main
    path: deploy/bootstrap/ci/gitea
  destination:
    server: https://kubernetes.default.svc
    namespace: ci
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 5m
```

- [ ] **Step 6 : Commiter, pousser, ouvrir la PR sur `stoa`**

```bash
cd /Users/potomitan/stoa-platform/stoa
git worktree add /tmp/wt-gitea -b feat/ci-gitea origin/main
# copier les fichiers dans /tmp/wt-gitea, puis :
cd /tmp/wt-gitea
git add deploy/bootstrap
git commit -s -m "feat(ci): déployer Gitea dans le cluster labs"
git push -u origin feat/ci-gitea
gh pr create --base main --title "feat(ci): déployer Gitea dans le cluster labs" --body "Premier composant du socle CI. Aucune exposition publique."
```

- [ ] **Step 7 : Après fusion, appliquer et vérifier la porte de preuve**

```bash
cd /Users/potomitan/stoa-platform/stoa-labs/ansible
ansible-playbook -i inventory.contabo.ini bootstrap.yml
ssh worker-1 'sudo k3s kubectl -n argocd patch application ci-gitea --type=merge -p "{\"operation\":null}"'
ssh worker-1 'sudo k3s kubectl -n ci wait --for=condition=Ready pod/gitea-0 --timeout=300s'
ssh worker-1 'sudo k3s kubectl -n ci run probe --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -sf http://gitea.ci.svc.cluster.local:3000/api/v1/version'
```
Attendu : un JSON du type `{"version":"1.22.x"}`

- [ ] **Step 8 : Contre-épreuve — la donnée survit-elle au pod ?**

```bash
# Créer un utilisateur et un dépôt
ssh worker-1 'sudo k3s kubectl -n ci exec gitea-0 -- gitea admin user create \
  --username ci --password ci-bootstrap --email ci@gostoa.dev --admin --must-change-password=false'
# Supprimer le pod : le PVC doit survivre
ssh worker-1 'sudo k3s kubectl -n ci delete pod gitea-0'
ssh worker-1 'sudo k3s kubectl -n ci wait --for=condition=Ready pod/gitea-0 --timeout=300s'
ssh worker-1 'sudo k3s kubectl -n ci exec gitea-0 -- gitea admin user list'
```
Attendu : l'utilisateur `ci` est **toujours là**. S'il a disparu, le PVC n'est pas monté — arrêter et corriger.

- [ ] **Step 9 : Commiter la preuve**

```bash
cd /Users/potomitan/stoa-platform/stoa-labs
git add docs/superpowers/plans/
git commit -s -m "docs(ci): preuve d'exécution tâche 1 — Gitea persistant"
```

---

## Task 2 : Sauvegarde des PVC

Placée **immédiatement** après Gitea, avant que Vault et Jenkins n'accumulent des données non sauvegardées. `cluster_backup` ne couvre aujourd'hui que le datastore k3s.

**Files:**
- Create: `stoa-labs/ansible/roles/cluster_backup/tasks/pvc.yml`
- Modify: `stoa-labs/ansible/roles/cluster_backup/tasks/main.yml` (ajout d'un `include_tasks`)
- Modify: `stoa-labs/ansible/roles/cluster_backup/defaults/main.yml` (variables PVC)

**Interfaces:**
- Consomme : le rôle `cluster_backup` existant, le PVC `gitea-data` de la tâche 1.
- Produit : des archives PVC dans `{{ backup_dir }}/pvc/`, copiées hors-nœud.

- [ ] **Step 1 : Écrire l'assertion (elle doit échouer)**

```bash
ssh worker-5 'sudo sh -c "ls -1 /var/lib/k3s-backups/offsite/pvc-*.tar.gz 2>/dev/null | head -1"'
```
Attendu maintenant : **vide** — aucune sauvegarde de PVC n'existe.

- [ ] **Step 2 : Ajouter les variables**

Dans `defaults/main.yml`, ajouter :

```yaml
# Namespaces dont les PVC local-path sont sauvegardés.
backup_pvc_namespaces:
  - ci
# Racine des volumes local-path sur les nœuds.
backup_localpath_root: "/var/lib/rancher/k3s/storage"
```

- [ ] **Step 3 : Écrire `tasks/pvc.yml`**

```yaml
---
# Sauvegarde des PVC local-path. Ils vivent dans des répertoires sur UN nœud :
# sans cette sauvegarde, perdre le nœud c'est perdre Gitea, Vault et Jenkins.

- name: "Lister les volumes local-path des namespaces surveillés"
  ansible.builtin.shell:
    cmd: >-
      k3s kubectl get pv -o jsonpath='{range .items[*]}{.spec.claimRef.namespace}{" "}{.spec.claimRef.name}{" "}{.spec.hostPath.path}{" "}{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}{"\n"}{end}'
  become: true
  register: backup_pv_list
  changed_when: false

- name: "Archiver chaque PVC, sur le nœud qui le porte"
  ansible.builtin.shell:
    cmd: >-
      ssh -o BatchMode=yes {{ item.split(' ')[3] }}
      'sudo tar czf - -C {{ item.split(" ")[2] }} .'
      > /dev/null 2>&1 ||
      ssh -o BatchMode=yes {{ item.split(' ')[3] }}
      'sudo tar czf /tmp/pvc-{{ item.split(" ")[0] }}-{{ item.split(" ")[1] }}.tar.gz -C {{ item.split(" ")[2] }} .'
  delegate_to: localhost
  become: false
  loop: "{{ backup_pv_list.stdout_lines | select('search', '^(' + (backup_pvc_namespaces | join('|')) + ') ') | list }}"
  changed_when: true

- name: "Rapatrier et déposer hors-nœud, en flux"
  ansible.builtin.shell:
    cmd: >-
      ssh -o BatchMode=yes {{ item.split(' ')[3] }}
      'sudo cat /tmp/pvc-{{ item.split(" ")[0] }}-{{ item.split(" ")[1] }}.tar.gz'
      | ssh -o BatchMode=yes {{ backup_offsite_host }}
      'sudo install -d -m 0700 {{ backup_offsite_dir }} &&
       sudo tee {{ backup_offsite_dir }}/pvc-{{ item.split(" ")[0] }}-{{ item.split(" ")[1] }}-{{ backup_stamp }}.tar.gz >/dev/null'
  delegate_to: localhost
  become: false
  loop: "{{ backup_pv_list.stdout_lines | select('search', '^(' + (backup_pvc_namespaces | join('|')) + ') ') | list }}"
  changed_when: true

- name: "Read-back : les archives PVC hors-nœud sont-elles lisibles ?"
  ansible.builtin.shell:
    cmd: "for f in {{ backup_offsite_dir }}/pvc-*-{{ backup_stamp }}.tar.gz; do tar tzf \"$f\" >/dev/null || exit 1; done"
  become: true
  delegate_to: "{{ backup_offsite_host }}"
  register: backup_pvc_readback
  changed_when: false

- name: "Assert : toutes les archives PVC sont lisibles"
  ansible.builtin.assert:
    that:
      - backup_pvc_readback.rc == 0
    fail_msg: "Une archive PVC est illisible — sauvegarde non fiable."
    success_msg: "archives PVC vérifiées hors-nœud"
```

- [ ] **Step 4 : Brancher dans `tasks/main.yml`**

À la fin de `main.yml`, ajouter :

```yaml
- name: "Sauvegarder les PVC local-path"
  ansible.builtin.include_tasks: pvc.yml
```

- [ ] **Step 5 : Exécuter et vérifier**

```bash
cd /Users/potomitan/stoa-platform/stoa-labs/ansible
ansible-playbook -i inventory.contabo.ini backup.yml
ssh worker-5 'sudo sh -c "ls -1 /var/lib/k3s-backups/offsite/pvc-*.tar.gz"'
```
Attendu : au moins une archive `pvc-ci-gitea-data-*.tar.gz`

- [ ] **Step 6 : Contre-épreuve — restaurer et retrouver la donnée**

```bash
ssh worker-5 'sudo sh -c "
  A=\$(ls -1t /var/lib/k3s-backups/offsite/pvc-ci-gitea-data-*.tar.gz | head -1)
  rm -rf /tmp/pvcrt && mkdir -p /tmp/pvcrt && tar xzf \"\$A\" -C /tmp/pvcrt
  ls /tmp/pvcrt | head -5
  test -d /tmp/pvcrt/gitea && echo RESTAURATION-OK || echo RESTAURATION-ÉCHEC
  rm -rf /tmp/pvcrt"'
```
Attendu : `RESTAURATION-OK`. Sinon, l'archive ne contient pas les données Gitea — arrêter et corriger.

- [ ] **Step 7 : Commiter**

```bash
cd /Users/potomitan/stoa-platform/stoa-labs
git add ansible/roles/cluster_backup
git commit -s -m "feat(ansible): étendre la sauvegarde aux PVC local-path"
```

---

## Task 3 : Vault persistant, auth Kubernetes — *ferme le jalon G8*

**Files:**
- Create: `stoa/deploy/bootstrap/argocd/app-ci-vault.yaml`
- Create: `stoa/deploy/bootstrap/ci/vault/kustomization.yaml`
- Create: `stoa/deploy/bootstrap/ci/vault/statefulset.yaml`
- Create: `stoa/deploy/bootstrap/ci/vault/service.yaml`
- Create: `stoa/deploy/bootstrap/ci/vault/serviceaccount.yaml`
- Create: `stoa/deploy/bootstrap/ci/vault/prometheusrule.yaml`

**Interfaces:**
- Consomme : le namespace `ci`.
- Produit : `vault.ci.svc.cluster.local:8200`, le ServiceAccount `jenkins-agent`, le rôle Vault `jenkins-agent`.

- [ ] **Step 1 : Assertion (doit échouer)**

```bash
ssh worker-1 'sudo k3s kubectl -n ci get sts vault'
```
Attendu : `Error from server (NotFound)`

- [ ] **Step 2 : ServiceAccount et RBAC pour la revue de jeton**

`serviceaccount.yaml` :

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins-agent
  namespace: ci
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault
  namespace: ci
---
# Vault doit pouvoir valider les jetons de ServiceAccount présentés par les pods.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-tokenreview
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: vault
    namespace: ci
```

- [ ] **Step 3 : Service et StatefulSet Vault**

`service.yaml` :

```yaml
apiVersion: v1
kind: Service
metadata:
  name: vault
  namespace: ci
spec:
  type: ClusterIP
  selector:
    app: vault
  ports:
    - name: http
      port: 8200
      targetPort: 8200
```

`statefulset.yaml` :

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: vault
  namespace: ci
spec:
  serviceName: vault
  replicas: 1
  selector:
    matchLabels:
      app: vault
  template:
    metadata:
      labels:
        app: vault
    spec:
      serviceAccountName: vault
      containers:
        - name: vault
          image: hashicorp/vault:1.18
          args: ["server"]
          env:
            - name: VAULT_ADDR
              value: "http://127.0.0.1:8200"
            # Stockage FICHIER sur PVC — pas le mode dev du POC, dont tout
            # disparaît au redémarrage.
            - name: VAULT_LOCAL_CONFIG
              value: |
                storage "file" { path = "/vault/data" }
                listener "tcp" {
                  address     = "0.0.0.0:8200"
                  tls_disable = 1
                }
                disable_mlock = true
                ui = false
          ports:
            - containerPort: 8200
          securityContext:
            capabilities:
              add: ["IPC_LOCK"]
          volumeMounts:
            - name: vault-data
              mountPath: /vault/data
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 512Mi
  volumeClaimTemplates:
    - metadata:
        name: vault-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-path
        resources:
          requests:
            storage: 5Gi
```

- [ ] **Step 4 : Alerte `VaultSealed`**

`prometheusrule.yaml` :

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: vault-rules
  namespace: ci
spec:
  groups:
    - name: vault
      rules:
        # Vault scellé fait échouer les pipelines — comportement correct, mais
        # qui doit être VISIBLE. Sans cette alerte, un Vault scellé après
        # redémarrage se traduit par des builds rouges sans cause apparente.
        - alert: VaultSealed
          expr: |
            max_over_time(kube_pod_container_status_ready{namespace="ci", pod=~"vault-.*"}[5m]) == 0
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "Vault indisponible ou scellé"
            description: "Les pipelines Jenkins ne peuvent plus obtenir d'identifiants."
```

`kustomization.yaml` :

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ci
resources:
  - serviceaccount.yaml
  - service.yaml
  - statefulset.yaml
  - prometheusrule.yaml
```

- [ ] **Step 5 : Application Argo CD**

`app-ci-vault.yaml` — identique à `app-ci-gitea.yaml` en remplaçant `name: ci-gitea` par `ci-vault` et `path: deploy/bootstrap/ci/gitea` par `deploy/bootstrap/ci/vault`.

- [ ] **Step 6 : Commiter, PR, fusionner, appliquer**

```bash
cd /Users/potomitan/stoa-platform/stoa
git worktree add /tmp/wt-vault -b feat/ci-vault origin/main
# copier les fichiers, puis :
cd /tmp/wt-vault && git add deploy/bootstrap
git commit -s -m "feat(ci): Vault persistant avec auth Kubernetes"
git push -u origin feat/ci-vault && gh pr create --base main --title "feat(ci): Vault persistant avec auth Kubernetes" --body "Stockage fichier sur PVC. Auth Kubernetes pour l'identité de job Jenkins."
```

- [ ] **Step 7 : Initialiser et desceller Vault (une seule fois)**

```bash
ssh worker-1 'sudo k3s kubectl -n ci exec vault-0 -- vault operator init -key-shares=3 -key-threshold=2 -format=json'
```
**Conserver la sortie hors ligne.** Les clés de descellement et le jeton racine sont un nouveau « secret zéro » : ils ne peuvent pas vivre dans Vault, ne doivent figurer dans aucun dépôt, et sont remis à l'exploitant.

```bash
# Desceller avec 2 des 3 clés
ssh worker-1 'sudo k3s kubectl -n ci exec vault-0 -- vault operator unseal <CLÉ_1>'
ssh worker-1 'sudo k3s kubectl -n ci exec vault-0 -- vault operator unseal <CLÉ_2>'
ssh worker-1 'sudo k3s kubectl -n ci exec vault-0 -- vault status'
```
Attendu : `Sealed  false`

- [ ] **Step 8 : Activer l'auth Kubernetes et créer le rôle**

```bash
ssh worker-1 'sudo k3s kubectl -n ci exec vault-0 -- sh -c "
  export VAULT_TOKEN=<JETON_RACINE>
  vault auth enable kubernetes
  vault write auth/kubernetes/config \
    kubernetes_host=https://\$KUBERNETES_PORT_443_TCP_ADDR:443
  vault policy write jenkins-agent - <<EOF
path \"secret/data/ci/*\" { capabilities = [\"read\"] }
EOF
  vault write auth/kubernetes/role/jenkins-agent \
    bound_service_account_names=jenkins-agent \
    bound_service_account_namespaces=ci \
    policy=jenkins-agent \
    ttl=20m
  vault secrets enable -path=secret kv-v2
  vault kv put secret/ci/probe value=preuve-g8
"'
```

- [ ] **Step 9 : PORTE DE PREUVE G-b — un pod avec le bon SA obtient un jeton**

```bash
ssh worker-1 'sudo k3s kubectl -n ci run g8-ok --rm -i --restart=Never \
  --overrides="{\"spec\":{\"serviceAccountName\":\"jenkins-agent\"}}" \
  --image=hashicorp/vault:1.18 -- sh -c "
    vault write -address=http://vault.ci.svc.cluster.local:8200 \
      auth/kubernetes/login role=jenkins-agent \
      jwt=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"'
```
Attendu : un `token` est renvoyé, avec un TTL de 20 min.

- [ ] **Step 10 : CONTRE-ÉPREUVE — un autre ServiceAccount doit être REFUSÉ**

C'est la seule assertion qui prouve que Vault *distingue* les identités.

```bash
ssh worker-1 'sudo k3s kubectl -n ci run g8-ko --rm -i --restart=Never \
  --image=hashicorp/vault:1.18 -- sh -c "
    vault write -address=http://vault.ci.svc.cluster.local:8200 \
      auth/kubernetes/login role=jenkins-agent \
      jwt=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"'
```
(Ce pod porte le SA `default`, pas `jenkins-agent`.)
Attendu : **échec**, `permission denied` ou `service account name not authorized`.
Si ce pod obtient un jeton, **arrêter** : le rôle n'est pas correctement borné et G8 n'est pas fermé.

- [ ] **Step 11 : Commiter la preuve**

```bash
cd /Users/potomitan/stoa-platform/stoa-labs
git commit -s --allow-empty -m "docs(ci): preuve G-b — Vault distingue les identités de pod (ferme G8)"
```

---

## Task 4 : Image Jenkins construite et distribuable

**Files:**
- Create: `stoa-labs/ansible/roles/registry_config/tasks/main.yml`
- Create: `stoa-labs/ansible/roles/registry_config/defaults/main.yml`
- Create: `stoa-labs/ansible/roles/jenkins_image/tasks/main.yml`
- Create: `stoa-labs/ansible/roles/jenkins_image/defaults/main.yml`
- Create: `stoa-labs/ansible/ci-image.yml`

**Interfaces:**
- Consomme : Gitea (tâche 1) et son registre intégré.
- Produit : l'image `gitea.ci.svc.cluster.local:3000/ci/jenkins-go:v1`, tirable par tous les nœuds.

- [ ] **Step 1 : Assertion (doit échouer)**

```bash
ssh worker-3 'sudo crictl pull gitea.ci.svc.cluster.local:3000/ci/jenkins-go:v1'
```
Attendu : échec — l'image n'existe pas et le registre n'est pas configuré.

- [ ] **Step 2 : Configurer le registre dans k3s sur tous les nœuds**

Le registre Gitea est servi en HTTP sans TLS, sur un nom interne au cluster. containerd doit être configuré pour l'accepter, sinon tout `pull` échouera.

`roles/registry_config/defaults/main.yml` :

```yaml
registry_host: "gitea.ci.svc.cluster.local:3000"
```

`roles/registry_config/tasks/main.yml` :

```yaml
---
- name: "Déclarer le registre Gitea auprès de containerd"
  ansible.builtin.copy:
    dest: /etc/rancher/k3s/registries.yaml
    owner: root
    group: root
    mode: "0600"
    content: |
      # Registre interne Gitea, servi en HTTP sur un nom de Service du cluster.
      # Sans cette déclaration, containerd refuse le pull (pas de TLS).
      mirrors:
        "{{ registry_host }}":
          endpoint:
            - "http://{{ registry_host }}"
      configs:
        "{{ registry_host }}":
          tls:
            insecure_skip_verify: true
  become: true
  register: reg_conf

- name: "Redémarrer k3s si la configuration a changé"
  ansible.builtin.systemd:
    name: "{{ 'k3s' if inventory_hostname in groups['k3s_server'] else 'k3s-agent' }}"
    state: restarted
  become: true
  when: reg_conf.changed

- name: "Read-back : le fichier est-il en place ?"
  ansible.builtin.command:
    cmd: grep -c "{{ registry_host }}" /etc/rancher/k3s/registries.yaml
  become: true
  register: reg_check
  changed_when: false

- name: "Assert : registre déclaré"
  ansible.builtin.assert:
    that:
      - reg_check.stdout | int >= 1
    fail_msg: "Le registre n'est pas déclaré : tous les pulls d'image Jenkins échoueront."
```

- [ ] **Step 3 : Rôle de construction de l'image**

`roles/jenkins_image/defaults/main.yml` :

```yaml
jenkins_image_context: "/opt/stoa-build/poc-control-plane-federation"
jenkins_image_tag: "gitea.ci.svc.cluster.local:3000/ci/jenkins-go:v1"
gitea_registry_user: "ci"
```

`roles/jenkins_image/tasks/main.yml` :

```yaml
---
# Construite sur worker-3 : c'est le SEUL nœud disposant d'un moteur de
# construction (Docker actif ; ni podman ni buildah ailleurs — vérifié).

- name: "Assert : Docker est disponible sur cet hôte"
  ansible.builtin.command:
    cmd: docker info
  become: true
  changed_when: false

- name: "Déposer le contexte de construction"
  ansible.posix.synchronize:
    src: "{{ playbook_dir }}/../poc-control-plane-federation/"
    dest: "{{ jenkins_image_context }}/"
    delete: true
    rsync_opts:
      - "--exclude=.git"

- name: "Construire l'image Jenkins"
  ansible.builtin.command:
    cmd: >-
      docker build -f ci/jenkins/Dockerfile
      -t {{ jenkins_image_tag }} .
    chdir: "{{ jenkins_image_context }}"
  become: true
  changed_when: true

- name: "Read-back : l'image existe localement"
  ansible.builtin.command:
    cmd: docker image inspect {{ jenkins_image_tag }}
  become: true
  changed_when: false
```

- [ ] **Step 4 : Playbook d'appel**

`stoa-labs/ansible/ci-image.yml` :

```yaml
---
- name: "Déclarer le registre Gitea sur tous les nœuds"
  hosts: k3s_cluster
  gather_facts: false
  become: true
  roles:
    - registry_config

- name: "Construire l'image Jenkins (worker-3, seul nœud avec Docker)"
  hosts: worker-3
  gather_facts: false
  roles:
    - jenkins_image
```

- [ ] **Step 5 : Exécuter**

```bash
cd /Users/potomitan/stoa-platform/stoa-labs/ansible
ansible-playbook -i inventory.contabo.ini ci-image.yml
```

- [ ] **Step 6 : Pousser l'image vers le registre Gitea**

```bash
# Depuis worker-3, via un port-forward vers Gitea
ssh worker-3 'sudo docker login gitea.ci.svc.cluster.local:3000 -u ci -p ci-bootstrap && \
  sudo docker push gitea.ci.svc.cluster.local:3000/ci/jenkins-go:v1'
```

- [ ] **Step 7 : Porte de preuve — un AUTRE nœud peut tirer l'image**

C'est l'assertion qui compte : construire sur worker-3 ne sert à rien si worker-4 ne peut pas tirer.

```bash
ssh worker-4 'sudo crictl pull gitea.ci.svc.cluster.local:3000/ci/jenkins-go:v1 && echo PULL-OK'
```
Attendu : `PULL-OK`

- [ ] **Step 8 : Commiter**

```bash
cd /Users/potomitan/stoa-platform/stoa-labs
git add ansible/roles/registry_config ansible/roles/jenkins_image ansible/ci-image.yml
git commit -s -m "feat(ansible): construire et distribuer l'image Jenkins via le registre Gitea"
```

---

## Task 5 : Jenkins déployé et pipeline de bout en bout

**Files:**
- Create: `stoa/deploy/bootstrap/argocd/app-ci-jenkins.yaml`
- Create: `stoa/deploy/bootstrap/ci/jenkins/kustomization.yaml`
- Create: `stoa/deploy/bootstrap/ci/jenkins/deployment.yaml`
- Create: `stoa/deploy/bootstrap/ci/jenkins/service.yaml`
- Create: `stoa/deploy/bootstrap/ci/jenkins/rbac.yaml`

**Interfaces:**
- Consomme : Gitea (tâche 1), Vault et le SA `jenkins-agent` (tâche 3), l'image (tâche 4).
- Produit : `jenkins.ci.svc.cluster.local:8080`.

- [ ] **Step 1 : Assertion (doit échouer)**

```bash
ssh worker-1 'sudo k3s kubectl -n ci get deploy jenkins'
```
Attendu : `Error from server (NotFound)`

- [ ] **Step 2 : RBAC — Jenkins crée ses agents éphémères**

`rbac.yaml` :

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins
  namespace: ci
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: jenkins-agents
  namespace: ci
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/exec", "pods/log"]
    verbs: ["get", "list", "watch", "create", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jenkins-agents
  namespace: ci
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: jenkins-agents
subjects:
  - kind: ServiceAccount
    name: jenkins
    namespace: ci
```

- [ ] **Step 3 : Service et Deployment**

`service.yaml` :

```yaml
apiVersion: v1
kind: Service
metadata:
  name: jenkins
  namespace: ci
spec:
  type: ClusterIP
  selector:
    app: jenkins
  ports:
    - name: http
      port: 8080
      targetPort: 8080
```

`deployment.yaml` :

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jenkins
  namespace: ci
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: jenkins
  template:
    metadata:
      labels:
        app: jenkins
    spec:
      serviceAccountName: jenkins
      containers:
        - name: jenkins
          image: gitea.ci.svc.cluster.local:3000/ci/jenkins-go:v1
          env:
            - name: JAVA_OPTS
              value: "-Djenkins.install.runSetupWizard=false"
            - name: VAULT_ADDR
              value: "http://vault.ci.svc.cluster.local:8200"
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: jenkins-home
              mountPath: /var/jenkins_home
          resources:
            requests:
              cpu: 200m
              memory: 1Gi
            limits:
              memory: 3Gi
          readinessProbe:
            httpGet:
              path: /login
              port: 8080
            initialDelaySeconds: 60
            periodSeconds: 15
      volumes:
        - name: jenkins-home
          persistentVolumeClaim:
            claimName: jenkins-home
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jenkins-home
  namespace: ci
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources:
    requests:
      storage: 20Gi
```

`kustomization.yaml` :

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ci
resources:
  - rbac.yaml
  - service.yaml
  - deployment.yaml
```

- [ ] **Step 4 : Application Argo CD**

`app-ci-jenkins.yaml` — identique à `app-ci-gitea.yaml` avec `name: ci-jenkins` et `path: deploy/bootstrap/ci/jenkins`.

- [ ] **Step 5 : Commiter, PR, fusionner, appliquer**

```bash
cd /Users/potomitan/stoa-platform/stoa
git worktree add /tmp/wt-jenkins -b feat/ci-jenkins origin/main
cd /tmp/wt-jenkins && git add deploy/bootstrap
git commit -s -m "feat(ci): déployer Jenkins avec agents éphémères"
git push -u origin feat/ci-jenkins && gh pr create --base main --title "feat(ci): déployer Jenkins avec agents éphémères" --body "Dernier composant du socle CI."
```

- [ ] **Step 6 : Vérifier que Jenkins démarre**

```bash
ssh worker-1 'sudo k3s kubectl -n ci wait --for=condition=Available deploy/jenkins --timeout=600s'
```

- [ ] **Step 7 : PORTE DE PREUVE G-c — pipeline de bout en bout, sans secret statique**

Créer dans Gitea un dépôt `ci/probe` contenant ce `Jenkinsfile` :

```groovy
podTemplate(serviceAccount: 'jenkins-agent', containers: [
  containerTemplate(name: 'vault', image: 'hashicorp/vault:1.18', command: 'sleep', args: '9999')
]) {
  node(POD_LABEL) {
    container('vault') {
      sh '''
        set -e
        VT=$(vault write -address=$VAULT_ADDR -field=token \
          auth/kubernetes/login role=jenkins-agent \
          jwt=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token))
        VAULT_TOKEN=$VT vault kv get -address=$VAULT_ADDR -field=value secret/ci/probe
      '''
    }
  }
}
```

Lancer le job. Attendu : la sortie affiche `preuve-g8`.
**Assertion complémentaire :** aucun credential statique dans Jenkins —
```bash
ssh worker-1 'sudo k3s kubectl -n ci exec deploy/jenkins -- ls /var/jenkins_home/credentials.xml 2>/dev/null && echo "ÉCHEC: credentials statiques" || echo "OK: aucun credential statique"'
```

- [ ] **Step 8 : CONTRE-ÉPREUVE — révoquer le rôle, le pipeline doit échouer fermé**

```bash
ssh worker-1 'sudo k3s kubectl -n ci exec vault-0 -- sh -c "
  export VAULT_TOKEN=<JETON_RACINE>
  vault delete auth/kubernetes/role/jenkins-agent"'
```
Relancer le job. Attendu : **échec** avec `permission denied`.
Si le pipeline réussit encore, un secret est mis en cache quelque part — arrêter et corriger.

Puis restaurer le rôle (répéter l'étape 8 de la tâche 3).

- [ ] **Step 9 : Commiter la preuve**

```bash
cd /Users/potomitan/stoa-platform/stoa-labs
git commit -s --allow-empty -m "docs(ci): preuve G-c — pipeline authentifié sans secret statique"
```

---

## Auto-revue du plan

**Couverture de la spécification**

| Exigence de la spéc | Tâche |
|---|---|
| Gitea 1.22, ROOT_URL corrigé, webhook restreint | 1 |
| Registre d'images intégré | 1 + 4 |
| Sauvegarde des PVC (§7) | 2 |
| Vault persistant, stockage fichier | 3 |
| Auth Kubernetes, rôle borné | 3 |
| Alerte `VaultSealed` | 3 |
| Clés de descellement hors ligne | 3, étape 7 |
| Image Jenkins construite | 4 |
| Agents en pods éphémères | 5 |
| Aucune exposition publique | toutes — aucun Ingress n'est créé |
| G-a / G-b / G-c | 1 étape 8 / 3 étapes 9-10 / 5 étapes 7-8 |

**Points laissés ouverts par la spéc et non résolus ici** (à trancher en cours d'exécution, ils ne bloquent aucune tâche) : rétention des builds Jenkins, espace disque hors-nœud pour les PVC, automatisation de la sauvegarde.

**Écart assumé :** la spéc mentionne JCasC pour la configuration Jenkins. Ce plan ne l'implémente pas — le job de preuve est créé à la main. JCasC devient pertinent quand il y aura plus d'un job ; l'introduire maintenant alourdirait la tâche 5 sans rien prouver de plus.
