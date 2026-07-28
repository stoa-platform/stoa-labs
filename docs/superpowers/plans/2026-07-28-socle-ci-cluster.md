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
| Image Jenkins | `localhost:30300/ci/jenkins-go:v1` |

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

- [x] **Step 1 : Écrire la porte de preuve (elle doit échouer maintenant)**

Créer `stoa/deploy/bootstrap/ci/gitea/PROOF.md` avec l'assertion :

```bash
# Assertion : Gitea répond et son API est servie
kubectl -n ci exec deploy/probe -- curl -sf http://gitea.ci.svc.cluster.local:3000/api/v1/version
```

- [x] **Step 2 : Lancer l'assertion pour vérifier qu'elle échoue**

```bash
ssh worker-1 'sudo k3s kubectl get ns ci'
```
Attendu : `Error from server (NotFound): namespaces "ci" not found`

- [x] **Step 3 : Ajouter la destination `ci` à l'AppProject**

Dans `appproject-stoa.yaml`, sous `spec.destinations`, ajouter :

```yaml
    - server: https://kubernetes.default.svc
      namespace: ci
```

- [x] **Step 4 : Écrire les manifestes Gitea**

`stoa/deploy/bootstrap/ci/gitea/service.yaml` :

```yaml
apiVersion: v1
kind: Service
metadata:
  name: gitea
  namespace: ci
spec:
  # NodePort, et non ClusterIP : le registre d'images doit être joignable au
  # niveau HÔTE. containerd et `docker push` tournent hors du cluster et
  # utilisent /etc/resolv.conf, pas CoreDNS — un nom en .svc.cluster.local y est
  # irrésoluble. Chaque nœud tape son propre `localhost:30300`, kube-proxy route
  # vers le pod Gitea où qu'il soit.
  #
  # Ce n'est PAS une exposition publique : ufw est en `-P INPUT DROP` et
  # n'ouvre au monde que 22, 30080 et 30443 ; 30300 n'est joignable que par la
  # boucle locale et les pairs du cluster. Vérifié le 2026-07-28.
  #
  # Pourquoi pas une entrée /etc/hosts pointant la ClusterIP : ce serait une
  # liaison mutable posée hors de Git sur quatre nœuds. La ClusterIP change à
  # toute recréation du Service, et les /etc/hosts deviendraient périmés EN
  # SILENCE. `localhost` ne change jamais et le NodePort est versionné ici.
  type: NodePort
  selector:
    app: gitea
  ports:
    - name: http
      port: 3000
      targetPort: 3000
      nodePort: 30300
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

- [x] **Step 5 : Écrire l'Application Argo CD**

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

- [x] **Step 6 : Commiter, pousser, ouvrir la PR sur `stoa`**

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

- [x] **Step 7 : Après fusion, appliquer et vérifier la porte de preuve**

```bash
cd /Users/potomitan/stoa-platform/stoa-labs/ansible
ansible-playbook -i inventory.contabo.ini bootstrap.yml
ssh worker-1 'sudo k3s kubectl -n argocd patch application ci-gitea --type=merge -p "{\"operation\":null}"'
ssh worker-1 'sudo k3s kubectl -n ci wait --for=condition=Ready pod/gitea-0 --timeout=300s'
ssh worker-1 'sudo k3s kubectl -n ci run probe --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -sf http://gitea.ci.svc.cluster.local:3000/api/v1/version'
```
Attendu : un JSON du type `{"version":"1.22.x"}`

- [x] **Step 8 : Contre-épreuve — la donnée survit-elle au pod ?**

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

- [x] **Step 9 : Commiter la preuve**

```bash
cd /Users/potomitan/stoa-platform/stoa-labs
git add docs/superpowers/plans/
git commit -s -m "docs(ci): preuve d'exécution tâche 1 — Gitea persistant"
```

### Preuve d'exécution (2026-07-28)

- PR `stoa` : [#2816](https://github.com/stoa-platform/stoa/pull/2816), squash-mergée en `fb777fd934cb0c316e1e01e712c3b4a9a1a35359` (base pré-merge `5db0202f809b09fb25a8d5f063f694606601c6fb`). 4 checks requis verts : License Compliance, SBOM Generation, Verify Signed Commits, Regression Test Guard.
- Step 2 (porte de preuve, avant construction) :
  `ssh worker-1 'sudo k3s kubectl get ns ci'` → `Error from server (NotFound): namespaces "ci" not found`.
- Step 7 (après fusion, `ansible-playbook -i inventory.contabo.ini bootstrap.yml` exécuté avec succès sur worker-1 seul) :
  `curl -sf http://gitea.ci.svc.cluster.local:3000/api/v1/version` (via pod `probe`, image `curlimages/curl:8.10.1`) → `{"version":"1.22.6"}`.
- Step 8 (contre-épreuve) : utilisateur admin `ci` créé (`su git -c 'gitea admin user create ...'`, nécessaire — `gitea` refuse de tourner en root) ; pod `gitea-0` supprimé et recréé (0 redémarrage du conteneur, PVC `gitea-data-gitea-0` 20Gi toujours `Bound`) ; `gitea admin user list` après recréation → l'utilisateur `ci` (admin, actif) est toujours présent.
- Argo CD : Application `ci-gitea` → `Healthy`, mais reste `OutOfSync` sur la ressource `StatefulSet` seule (`Service` est `Synced`). Cause identifiée : Kubernetes ajoute `status: {phase: Pending}` à chaque `volumeClaimTemplates[]` d'un StatefulSet vivant ; ce champ n'existe pas côté Git et Argo le signale en diff — comportement connu (k8s #72964 / Argo CD #5342), sans effet sur la santé ni sur les données (0 redémarrage constaté, un seul cycle de sync). Aucune des 5 Applications préexistantes n'utilise de StatefulSet, donc cette dérive cosmétique n'était jamais apparue avant Gitea. À surveiller sur Vault (tâche 3), qui aura le même profil.
- worker-3 vérifié après le bootstrap (bien que l'ansible ne l'ait pas ciblé) : `wm-dev-apigateway` et `wm-dev-elasticsearch` `Up`/`healthy`, service `caddy` actif en continu depuis le 19 mai (aucun redémarrage pendant cette session). `curl -sk https://localhost` renvoie une erreur TLS — comportement préexistant et sans rapport : Caddy n'a pas de site configuré pour le SNI `localhost` ; un test avec le Host réel (`dev-wm.gostoa.dev`) renvoie `200`.

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

- [x] **Step 1 : Écrire l'assertion (elle doit échouer)**

```bash
ssh worker-5 'sudo sh -c "ls -1 /var/lib/k3s-backups/offsite/pvc-*.tar.gz 2>/dev/null | head -1"'
```
Attendu maintenant : **vide** — aucune sauvegarde de PVC n'existe.

- [x] **Step 2 : Ajouter les variables**

Dans `defaults/main.yml`, ajouter :

```yaml
# Namespaces dont les PVC local-path sont sauvegardés.
backup_pvc_namespaces:
  - ci
# Racine des volumes local-path sur les nœuds.
backup_localpath_root: "/var/lib/rancher/k3s/storage"
```

- [x] **Step 3 : Écrire `tasks/pvc.yml`**

```yaml
---
# Sauvegarde des PVC local-path. Ils vivent dans des répertoires sur UN nœud :
# sans cette sauvegarde, perdre le nœud c'est perdre Gitea, Vault et Jenkins.

- name: "Lister les PersistentVolumes"
  ansible.builtin.command:
    cmd: k3s kubectl get pv -o json
  become: true
  register: backup_pv_json
  changed_when: false

# Parsing en JSON plutôt qu'en champs séparés par des espaces : un PV sans
# `nodeAffinity` produisait moins de champs que prévu et faisait sortir
# `split(' ')[3]` de l'index. Ici, un PV incomplet est simplement ignoré.
#
# DÉVIATION DOCUMENTÉE PAR RAPPORT AU PLAN INITIAL : le plan supposait
# `spec.hostPath.path`. Sur ce cluster (k3s v1.34.5+k3s1), le provisioner
# `rancher.io/local-path` peuple `spec.local.path`, pas `spec.hostPath` — vérifié
# sur les 3 PV existants (0 occurrence de `hostPath` dans `get pv -o json`). Le
# provisioner a historiquement émis les deux formes selon les versions ; les
# deux sont donc tolérées ici plutôt que de figer sur une seule, au cas où un PV
# plus ancien ou un autre provisioner local-path coexisterait un jour.
#
# DEUXIÈME DÉVIATION, syntaxique celle-ci : `matchExpressions[0].values[0]`
# (notation pointée du plan) échoue partout où l'item passe réellement le
# filtre `when` — Jinja résout `.values` sur la méthode native `dict.values()`
# avant la clé JSON du même nom, et l'indexation `[0]` sur cette méthode plante
# avec « builtin_function_or_method object has no element 0 ». Reproduit
# isolément sur un dict minimal `{'values': [...]}`. Corrigé en notation par
# crochets `['values'][0]`, qui cible sans ambiguïté la clé JSON.
- name: "Sélectionner les PV local-path des namespaces surveillés"
  ansible.builtin.set_fact:
    backup_pvcs: "{{ backup_pvcs | default([]) + [{
      'ns':   item.spec.claimRef.namespace,
      'name': item.spec.claimRef.name,
      'path': item.spec.local.path if (item.spec.local is defined) else item.spec.hostPath.path,
      'node': item.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0]['values'][0]
    }] }}"
  loop: "{{ (backup_pv_json.stdout | from_json)['items'] }}"
  loop_control:
    label: "{{ item.metadata.name }}"
  when:
    - item.spec.claimRef is defined
    - item.spec.claimRef.namespace in backup_pvc_namespaces
    - (item.spec.local is defined) or (item.spec.hostPath is defined)
    - item.spec.nodeAffinity is defined

- name: "Assert : au moins un PVC à sauvegarder"
  ansible.builtin.assert:
    that:
      - backup_pvcs | default([]) | length > 0
    fail_msg: >-
      Aucun PVC trouvé dans {{ backup_pvc_namespaces | join(', ') }}. Une
      sauvegarde qui ne sauvegarde rien et sort en succès est pire que pas de
      sauvegarde : elle rassure.

# --- Quiescence -------------------------------------------------------------
# `tar` sur un PVC vivant a le MÊME défaut qu'un `cp` sur une base vivante — ce
# que la sauvegarde du datastore évite justement via `sqlite3 .backup`. Gitea
# porte du SQLite, Vault un stockage fichier : une archive prise à chaud peut
# être silencieusement incohérente. On met donc les charges à zéro le temps de
# l'archive. Consistant par construction, un seul mécanisme pour les trois
# composants. Coût : quelques dizaines de secondes d'indisponibilité.
# Si cette indisponibilité devient inacceptable, l'échappatoire est de passer
# aux dumps natifs (`gitea dump`, arrêt de Vault) — au prix d'un chemin de code
# par application.
- name: "Mémoriser le nombre de répliques courant"
  ansible.builtin.shell:
    cmd: >-
      k3s kubectl -n {{ item }} get deploy,statefulset
      -o jsonpath='{range .items[*]}{.kind}/{.metadata.name}={.spec.replicas}{"\n"}{end}'
  become: true
  register: backup_replicas
  changed_when: false
  loop: "{{ backup_pvc_namespaces }}"

# `block`/`always` est INDISPENSABLE ici : si l'archivage échoue, les charges
# resteraient à zéro réplique et le socle CI serait éteint sans que personne ne
# l'ait décidé. GARANTIE HONNÊTE : `always` s'exécute en cas d'ÉCHEC D'UNE TÂCHE
# du bloc (assert, tar, etc.) — mais PAS si l'hôte devient UNREACHABLE en cours
# de bloc (perte de connexion SSH vers le poste de contrôle) : dans ce cas précis,
# Ansible n'exécute PAS `always`, et le redémarrage n'a pas lieu. Remède : remettre
# les répliques à la main (`k3s kubectl -n <ns> scale deploy,statefulset --all
# --replicas=<n>`) ou relancer le play une fois la connexion rétablie.
- name: "Quiescer, archiver, redémarrer"
  block:
    - name: "Quiescer les charges"
      ansible.builtin.command:
        cmd: k3s kubectl -n {{ item }} scale deploy,statefulset --all --replicas=0
      become: true
      loop: "{{ backup_pvc_namespaces }}"
      changed_when: true

    - name: "Attendre l'arrêt effectif des pods"
      ansible.builtin.command:
        cmd: k3s kubectl -n {{ item }} wait --for=delete pod --all --timeout=180s
      become: true
      loop: "{{ backup_pvc_namespaces }}"
      changed_when: false
      failed_when: false

    # Le `wait` ci-dessus tolère l'absence de ressources (`failed_when: false`) —
    # voulu : un namespace déjà vide de pods n'est pas une erreur. Mais un `wait`
    # qui échoue par TIMEOUT sur un pod bloqué en `Terminating` ne doit PAS
    # laisser le rôle continuer : on archiverait alors un système de fichiers
    # qu'un processus peut encore écrire, ce qui défait silencieusement la
    # garantie de quiescence promise plus haut. On reliste donc les pods
    # restants et on échoue fermé (fail-closed, doctrine du rôle) si la liste
    # n'est pas vide, avant tout archivage.
    - name: "Lister les pods restants après l'attente"
      ansible.builtin.command:
        cmd: k3s kubectl -n {{ item }} get pods -o name
      become: true
      loop: "{{ backup_pvc_namespaces }}"
      loop_control:
        label: "{{ item }}"
      register: backup_pods_remaining
      changed_when: false

    - name: "Assert : aucun pod ne subsiste avant l'archivage"
      ansible.builtin.assert:
        that:
          - item.stdout == ""
        fail_msg: >-
          Pod(s) toujours présent(s) dans {{ item.item }} après le délai
          d'attente : {{ item.stdout_lines | join(', ') }}. Un processus peut
          encore écrire sur le PVC — archivage ABANDONNÉ plutôt que de produire
          une sauvegarde potentiellement incohérente.
      loop: "{{ backup_pods_remaining.results }}"
      loop_control:
        label: "{{ item.item }}"

    # Aucun fichier temporaire : `tar` est streamé du nœud porteur vers le nœud
    # de sauvegarde. `pipefail` est INDISPENSABLE — sans lui, l'échec du `tar`
    # en amont du tube est masqué par le succès du `tee`, et on dépose une
    # archive VIDE en croyant avoir sauvegardé. C'est exactement le défaut de la
    # première version de ce plan.
    - name: "Archiver et déposer hors-nœud, en flux"
      ansible.builtin.shell:
        cmd: |
          set -euo pipefail
          ssh -o BatchMode=yes {{ item.node }} \
            "sudo tar czf - -C {{ item.path }} ." \
          | ssh -o BatchMode=yes {{ backup_offsite_host }} \
            "sudo install -d -m 0700 {{ backup_offsite_dir }} && \
             sudo tee {{ backup_offsite_dir }}/pvc-{{ item.ns }}-{{ item.name }}-{{ backup_stamp }}.tar.gz >/dev/null && \
             sudo chmod {{ backup_mode }} {{ backup_offsite_dir }}/pvc-{{ item.ns }}-{{ item.name }}-{{ backup_stamp }}.tar.gz"
        executable: /bin/bash
      delegate_to: localhost
      become: false
      loop: "{{ backup_pvcs }}"
      loop_control:
        label: "{{ item.ns }}/{{ item.name }}"
      changed_when: true

  always:
    - name: "Redémarrer les charges, y compris après échec"
      ansible.builtin.command:
        # `item.0` est le résultat de la tâche « Mémoriser » ; le namespace
        # interrogé est dans `item.0.item`, pas dans `item.0` lui-même.
        cmd: >-
          k3s kubectl -n {{ item.0.item }} scale {{ item.1.split('=')[0] }}
          --replicas={{ item.1.split('=')[1] }}
      become: true
      loop: "{{ backup_replicas.results | subelements('stdout_lines') }}"
      loop_control:
        label: "{{ item.0.item }} {{ item.1 }}"
      when: item.1 | length > 0
      changed_when: true

# `tar tzf` seul ne suffit PAS : une archive vide mais bien formée le passe
# sans broncher. On compte les entrées, sinon on valide du vide.
- name: "Read-back : les archives PVC sont-elles lisibles ET non vides ?"
  ansible.builtin.shell:
    cmd: |
      set -euo pipefail
      n=0
      for f in {{ backup_offsite_dir }}/pvc-*-{{ backup_stamp }}.tar.gz; do
        [ -e "$f" ] || { echo "aucune archive pour cet horodatage"; exit 1; }
        entries=$(tar tzf "$f" | wc -l)
        [ "$entries" -gt 1 ] || { echo "archive vide ou quasi vide : $f ($entries entrée(s))"; exit 1; }
        n=$((n+1))
      done
      echo "$n archive(s) vérifiée(s)"
    executable: /bin/bash
  become: true
  delegate_to: "{{ backup_offsite_host }}"
  register: backup_pvc_readback
  changed_when: false
  failed_when: false

- name: "Assert : toutes les archives PVC sont lisibles et contiennent des données"
  ansible.builtin.assert:
    that:
      - backup_pvc_readback.rc == 0
    fail_msg: >-
      Sauvegarde PVC non fiable — {{ backup_pvc_readback.stdout | default('') }}
      {{ backup_pvc_readback.stderr | default('') }}
    success_msg: "{{ backup_pvc_readback.stdout | default('archives vérifiées') }}"
```

- [x] **Step 4 : Brancher dans `tasks/main.yml`**

À la fin de `main.yml`, ajouter :

```yaml
- name: "Sauvegarder les PVC local-path"
  ansible.builtin.include_tasks: pvc.yml
```

- [x] **Step 5 : Exécuter et vérifier**

```bash
cd /Users/potomitan/stoa-platform/stoa-labs/ansible
ansible-playbook -i inventory.contabo.ini backup.yml
ssh worker-5 'sudo sh -c "ls -1 /var/lib/k3s-backups/offsite/pvc-*.tar.gz"'
```
Attendu : au moins une archive `pvc-ci-gitea-data-*.tar.gz`

- [x] **Step 6 : Contre-épreuve — restaurer et retrouver la donnée**

```bash
ssh worker-5 'sudo sh -c "
  A=\$(ls -1t /var/lib/k3s-backups/offsite/pvc-ci-gitea-data-*.tar.gz | head -1)
  rm -rf /tmp/pvcrt && mkdir -p /tmp/pvcrt && tar xzf \"\$A\" -C /tmp/pvcrt
  ls /tmp/pvcrt | head -5
  test -d /tmp/pvcrt/gitea && echo RESTAURATION-OK || echo RESTAURATION-ÉCHEC
  rm -rf /tmp/pvcrt"'
```
Attendu : `RESTAURATION-OK`. Sinon, l'archive ne contient pas les données Gitea — arrêter et corriger.

- [x] **Step 7 : Commiter**

```bash
cd /Users/potomitan/stoa-platform/stoa-labs
git add ansible/roles/cluster_backup
git commit -s -m "feat(ansible): étendre la sauvegarde aux PVC local-path"
```

### Preuve d'exécution (2026-07-28)

- Step 1 (porte de preuve, avant implémentation) :
  `ssh worker-5 'sudo sh -c "ls -1 /var/lib/k3s-backups/offsite/pvc-*.tar.gz 2>/dev/null | head -1"'` → sortie vide, conforme.
- Deux déviations factuelles découvertes en exécutant Step 5 pour de vrai, documentées dans le code ci-dessus et non improvisées sans validation :
  1. `spec.hostPath.path` n'existe sur aucun des 3 PV du cluster (provisioner `rancher.io/local-path`, k3s v1.34.5+k3s1) ; le champ réel est `spec.local.path`. Confirmé par jsonpath ciblé et par `grep -c '"hostPath"'` sur `get pv -o json` (0 occurrence, 3 occurrences de `"local"`). Premier essai : l'assertion « au moins un PVC » échoue proprement, AVANT toute quiescence — aucun impact sur Gitea. Correction acceptée par le contrôleur : lire `spec.local.path` en priorité, tolérer les deux formes.
  2. Une fois la sélection corrigée et un item la franchissant réellement, `matchExpressions[0].values[0]` (notation pointée) échoue avec `builtin_function_or_method object has no element 0` — Jinja résout `.values` sur la méthode `dict.values()` avant la clé JSON homonyme. Reproduit isolément sur un dict minimal avant correction. Corrigé en `['values'][0]`.
- Step 5 (après correction, `ansible-playbook -i inventory.contabo.ini backup.yml`) : succès complet, `ok=28 changed=11 failed=0`. Archive produite : `pvc-ci-gitea-data-gitea-0-20260728T150557.tar.gz` sur worker-5.
- Fenêtre de quiescence observée sur les événements Kubernetes (`kubectl get events -n ci`) : un seul cycle `Killing`→`SuccessfulDelete`(13:06:21Z)→`SuccessfulCreate`(13:06:26Z)→`Started`(13:06:27Z) — environ 5 s d'indisponibilité, aucun double cycle qui aurait trahi une intervention de selfHeal Argo CD pendant la fenêtre. Le dernier `operationState`/`reconciledAt` d'`ci-gitea` datait de 13:05:18Z, avant le début de la quiescence (13:06:21Z) ; aucune nouvelle entrée d'historique de déploiement n'est apparue après le redémarrage. selfHeal n'a pas interféré de façon observable — la fenêtre réelle (~5 s, données de test quasi vides) était trop courte pour que son délai de réaction (~5 s empiriques) se manifeste avant que le rôle n'ait lui-même restauré `replicas=1`.
- Step 6 (contre-épreuve) : `RESTAURATION-OK`. Glob ajusté de `pvc-ci-gitea-data-*.tar.gz` à rien — le nom réel (`pvc-ci-gitea-data-gitea-0-...`) correspond déjà à ce glob, aucun ajustement nécessaire. Contre-épreuve renforcée : extraction de `gitea.db` de l'archive et requête SQLite directe → l'utilisateur `ci` (id=1, `ci@gostoa.dev`) y est bien présent.
- Contre-épreuve de sabotage du gate rouge : logique de relecture (comptage d'entrées) exécutée isolément sur worker-5 contre une fausse archive `.tar.gz` vide (`touch`, jamais un vrai PVC) → sort en échec (`exit=1`, message « archive vide ou quasi vide »), confirmant que le gate peut virer au rouge.
- État final du cluster, vérifié après coup : `gitea-0` `1/1 Running`, StatefulSet `gitea` `1/1`, les 6 Applications Argo CD `Healthy` (`ci-gitea` reste `OutOfSync` — cause déjà documentée en Tâche 1 : `status.phase: Pending` ajouté par Kubernetes aux `volumeClaimTemplates[]` d'un StatefulSet vivant, absent de Git, sans effet sur la santé ni les données).
- worker-3 non ciblé par cette automatisation (aucun groupe d'inventaire, aucun `delegate_to`) ; vérifié par prudence : Caddy actif en continu, `wm-dev-elasticsearch` `Up`/`healthy` sans interruption, `wm-dev-apigateway` `Up`/`healthy` avec un redémarrage (`RestartCount` 5→6) dont l'horodatage (13:05:50Z) chevauche la fenêtre du backup — coïncidence probable et non une conséquence de cette automatisation (aucune tâche du rôle ne cible worker-3), `RestartCount` stable ensuite et conteneur `healthy` en continu depuis.

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

- [x] **Step 1 : Assertion (doit échouer)**

```bash
ssh worker-1 'sudo k3s kubectl -n ci get sts vault'
```
Attendu : `Error from server (NotFound)`

- [x] **Step 2 : ServiceAccount et RBAC pour la revue de jeton**

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

- [x] **Step 3 : Service et StatefulSet Vault**

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
      # Amendement contrôleur validé (constat en cours de déploiement, PR #2819) :
      # le scheduler avait placé vault-0 sur worker-3, or les règles de sécurité
      # de la tâche interdisent de toucher ce nœud (hors périmètre, héberge des
      # charges hors socle CI). Anti-affinité ajoutée pour l'exclure durablement
      # (y compris après un self-heal Argo CD).
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: NotIn
                    values:
                      - worker-3
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
          # Amendement contrôleur validé : Vault scellé renvoie 503
          # (non-initialisé 501) → pod NotReady → le Service ferme les flux
          # (échec fermé) ET l'alerte VaultSealed (readiness) peut réellement
          # rougir ; sans cette sonde, un Vault scellé mais démarré resterait
          # « Ready » et l'alerte ne rougirait jamais.
          readinessProbe:
            httpGet:
              path: /v1/sys/health?standbyok=true
              port: 8200
            initialDelaySeconds: 5
            periodSeconds: 10
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

- [x] **Step 4 : Alerte `VaultSealed`**

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

- [x] **Step 5 : Application Argo CD**

`app-ci-vault.yaml` — identique à `app-ci-gitea.yaml` en remplaçant `name: ci-gitea` par `ci-vault` et `path: deploy/bootstrap/ci/gitea` par `deploy/bootstrap/ci/vault`.

- [x] **Step 6 : Commiter, PR, fusionner, appliquer**

```bash
cd /Users/potomitan/stoa-platform/stoa
git worktree add /tmp/wt-vault -b feat/ci-vault origin/main
# copier les fichiers, puis :
cd /tmp/wt-vault && git add deploy/bootstrap
git commit -s -m "feat(ci): Vault persistant avec auth Kubernetes"
git push -u origin feat/ci-vault && gh pr create --base main --title "feat(ci): Vault persistant avec auth Kubernetes" --body "Stockage fichier sur PVC. Auth Kubernetes pour l'identité de job Jenkins."
```

- [x] **Step 7 : Initialiser et desceller Vault (une seule fois)**

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

- [x] **Step 8 : Activer l'auth Kubernetes et créer le rôle**

```bash
ssh worker-1 'sudo k3s kubectl -n ci exec vault-0 -- sh -c "
  export VAULT_TOKEN=<JETON_RACINE>
  vault auth enable kubernetes
  vault write auth/kubernetes/config \
    kubernetes_host=https://\$KUBERNETES_PORT_443_TCP_ADDR:443
  vault policy write jenkins-agent - <<EOF
path \"secret/data/ci/*\" { capabilities = [\"read\"] }
EOF
  # Amendement contrôleur validé : token_policies=jenkins-agent (pas policy=,
  # paramètre invalide/non standard ; risque d'un rôle ne portant que la
  # policy default).
  vault write auth/kubernetes/role/jenkins-agent \
    bound_service_account_names=jenkins-agent \
    bound_service_account_namespaces=ci \
    token_policies=jenkins-agent \
    ttl=20m
  vault secrets enable -path=secret kv-v2
  vault kv put secret/ci/probe value=preuve-g8
"'
```

- [x] **Step 9 : PORTE DE PREUVE G-b — un pod avec le bon SA obtient un jeton**

```bash
ssh worker-1 'sudo k3s kubectl -n ci run g8-ok --rm -i --restart=Never \
  --overrides="{\"spec\":{\"serviceAccountName\":\"jenkins-agent\"}}" \
  --image=hashicorp/vault:1.18 -- sh -c "
    vault write -address=http://vault.ci.svc.cluster.local:8200 \
      auth/kubernetes/login role=jenkins-agent \
      jwt=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"'
```
Attendu : un `token` est renvoyé, avec un TTL de 20 min.

- [x] **Step 10 : CONTRE-ÉPREUVE — un autre ServiceAccount doit être REFUSÉ**

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

- [x] **Step 11 : Commiter la preuve**

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
- Produit : l'image `localhost:30300/ci/jenkins-go:v1`, tirable par tous les nœuds.

- [x] **Step 1 : Assertion (doit échouer)**

```bash
ssh worker-3 'sudo crictl pull localhost:30300/ci/jenkins-go:v1'
```
Attendu : échec — l'image n'existe pas et le registre n'est pas configuré.

- [x] **Step 2 : Configurer le registre dans k3s sur tous les nœuds**

Le registre Gitea est servi en HTTP sans TLS, sur un nom interne au cluster. containerd doit être configuré pour l'accepter, sinon tout `pull` échouera.

`roles/registry_config/defaults/main.yml` :

```yaml
# `localhost` parce que containerd tourne au niveau HÔTE et ignore CoreDNS :
# un nom en .svc.cluster.local y est irrésoluble. Chaque nœud tape son propre
# NodePort, kube-proxy route vers le pod Gitea. Valeur constante, versionnée,
# rien à rejouer après une reconstruction.
registry_host: "localhost:30300"
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

- [x] **Step 3 : Rôle de construction de l'image**

`roles/jenkins_image/defaults/main.yml` :

```yaml
jenkins_image_context: "/opt/stoa-build/poc-control-plane-federation"
jenkins_image_tag: "localhost:30300/ci/jenkins-go:v1"
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

- [x] **Step 4 : Playbook d'appel**

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

- [x] **Step 5 : Exécuter**

```bash
cd /Users/potomitan/stoa-platform/stoa-labs/ansible
ansible-playbook -i inventory.contabo.ini ci-image.yml
```

- [x] **Step 6 : Pousser l'image vers le registre Gitea**

```bash
# Depuis worker-3, via un port-forward vers Gitea
ssh worker-3 'sudo docker login localhost:30300 -u ci -p ci-bootstrap && \
  sudo docker push localhost:30300/ci/jenkins-go:v1'
```

- [x] **Step 7 : Porte de preuve — un AUTRE nœud peut tirer l'image**

C'est l'assertion qui compte : construire sur worker-3 ne sert à rien si worker-4 ne peut pas tirer.

```bash
ssh worker-4 'sudo crictl pull localhost:30300/ci/jenkins-go:v1 && echo PULL-OK'
```
Attendu : `PULL-OK`

- [x] **Step 8 : Commiter**

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

- [x] **Step 1 : Assertion (doit échouer)**

```bash
ssh worker-1 'sudo k3s kubectl -n ci get deploy jenkins'
```
Attendu : `Error from server (NotFound)`

- [x] **Step 2 : RBAC — Jenkins crée ses agents éphémères**

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

- [x] **Step 3 : Service et Deployment**

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
      # Déviation justifiée, même motif que PR #2819 (Vault, tâche 3) : le
      # scheduler avait déjà tenté de placer Vault sur worker-3, nœud hors
      # périmètre (Caddy TLS public + webMethods hors socle CI) ; le PVC
      # jenkins-home figerait ensuite Jenkins sur ce nœud de façon
      # permanente. Anti-affinité ajoutée dès le premier déploiement,
      # à l'identique de la StatefulSet Vault.
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: NotIn
                    values:
                      - worker-3
      containers:
        - name: jenkins
          image: localhost:30300/ci/jenkins-go:v1
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

- [x] **Step 4 : Application Argo CD**

`app-ci-jenkins.yaml` — identique à `app-ci-gitea.yaml` avec `name: ci-jenkins` et `path: deploy/bootstrap/ci/jenkins`.

- [x] **Step 5 : Commiter, PR, fusionner, appliquer**

```bash
cd /Users/potomitan/stoa-platform/stoa
git worktree add /tmp/wt-jenkins -b feat/ci-jenkins origin/main
cd /tmp/wt-jenkins && git add deploy/bootstrap
git commit -s -m "feat(ci): déployer Jenkins avec agents éphémères"
git push -u origin feat/ci-jenkins && gh pr create --base main --title "feat(ci): déployer Jenkins avec agents éphémères" --body "Dernier composant du socle CI."
```

- [x] **Step 6 : Vérifier que Jenkins démarre**

```bash
ssh worker-1 'sudo k3s kubectl -n ci wait --for=condition=Available deploy/jenkins --timeout=600s'
```

- [x] **Step 7 : PORTE DE PREUVE G-c — pipeline de bout en bout, sans secret statique**

Créer dans Gitea un dépôt `ci/probe` (public, sans credential Jenkins — Gitea API `ci`/`ci-bootstrap`) contenant ce `Jenkinsfile` :

```groovy
podTemplate(serviceAccount: 'jenkins-agent', containers: [
  containerTemplate(name: 'vault', image: 'hashicorp/vault:1.18', command: 'sleep', args: '9999',
    # Amendement contrôleur validé : VAULT_ADDR posé sur le Deployment
    # Jenkins ne se propage PAS aux conteneurs des pods agents (env
    # séparé) ; posé explicitement ici via envVars du containerTemplate.
    envVars: [envVar(key: 'VAULT_ADDR', value: 'http://vault.ci.svc.cluster.local:8200')])
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

Lancer le job. Attendu : la sortie affiche `preuve-g8`. **Constaté** (voir rapport tâche 5).
**Assertion complémentaire :** aucun credential statique dans Jenkins —
```bash
ssh worker-1 'sudo k3s kubectl -n ci exec deploy/jenkins -- ls /var/jenkins_home/credentials.xml 2>/dev/null && echo "ÉCHEC: credentials statiques" || echo "OK: aucun credential statique"'
```

**Amendement contrôleur validé (cloud Kubernetes) :** le Service `jenkins`
n'expose que le port 8080 (verbatim du brief) — le port JNLP 50000 par
défaut du plugin `kubernetes` pour les agents inbound est inaccessible.
Le cloud Kubernetes a été configuré avec `webSocket: true` (agents
connectés en WebSocket sur le port HTTP 8080 déjà exposé), via script
console (aucune JCasC, cf. écart assumé plus bas) : `namespace=ci`,
`jenkinsUrl=http://jenkins.ci.svc.cluster.local:8080/`, serveur API
Kubernetes auto-détecté (compte de service `jenkins`, in-cluster config).
Le job `probe` (pipeline SCM, dépôt Gitea `ci/probe`, aucun credential
stocké) a lui aussi été créé par REST (`createItem`). Cet état vit
uniquement dans `jenkins-home` (PVC couvert par la sauvegarde tâche 2) —
aucun fichier Git ne le décrit.

- [x] **Step 8 : CONTRE-ÉPREUVE — révoquer le rôle, le pipeline doit échouer fermé**

```bash
ssh worker-1 'sudo k3s kubectl -n ci exec vault-0 -- sh -c "
  export VAULT_TOKEN=<JETON_RACINE>
  vault delete auth/kubernetes/role/jenkins-agent"'
```
Relancer le job. Attendu : **échec**. **Constaté** : échec fermé confirmé,
mais avec le message Vault `400 invalid role name "jenkins-agent"` (le
rôle entier a été supprimé, pas seulement débindé de ce SA) plutôt que le
`permission denied` (403) littéral anticipé par le brief — sémantiquement
équivalent (aucun jeton obtenu, aucun secret lu, pas de mise en cache).
Détail dans le rapport tâche 5.
Si le pipeline réussit encore, un secret est mis en cache quelque part — arrêter et corriger.

Puis restaurer le rôle (répéter l'étape 8 de la tâche 3). **Fait**, puis
job relancé une 3e fois pour prouver le retour au vert (voir rapport).

- [x] **Step 9 : Commiter la preuve**

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

**Dette actée en cours d'exécution (Tâche 4, acceptée le 2026-07-28) :** le
realm d'auth OCI de Gitea dérive de `ROOT_URL`
(`gitea.ci.svc.cluster.local:3000`), irrésoluble côté hôte ; contourné par
une entrée `/etc/hosts` → ClusterIP, re-résolue à chaque exécution de
`registry_config` (fenêtre de risque documentée dans le rôle). Correction de
fond différée au lot 2 : repenser `ROOT_URL` côté `stoa`, en tenant compte
que `localhost:30300` casserait les accès registre depuis les pods
eux-mêmes (résoluble à l'hôte, pas dans le réseau de pods).

**Écart assumé :** la spéc mentionne JCasC pour la configuration Jenkins. Ce plan ne l'implémente pas — le job de preuve est créé à la main. JCasC devient pertinent quand il y aura plus d'un job ; l'introduire maintenant alourdirait la tâche 5 sans rien prouver de plus.
