# F3 — webMethods 10.15 dans le cluster : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal :** la gateway webMethods 10.15 répond en `/rest/apigateway` depuis un pod
du cluster k3s, données portées par un PVC Elasticsearch, cycle trial piloté —
porte et contre-épreuves du GOAL jouées et documentées.

**Architecture :** ns `wm` ; StatefulSet ES 8.13.4 (PVC local-path, worker-4) ;
Deployment gateway trial 10.15 (sans volume, état dans ES) ; CronJob `*/20` qui
supprime le pod gateway (cycle trial piloté) ; images par digest depuis le
registre Gitea ; livraison par PR sur `stoa`, Applications ArgoCD appliquées
comme au lot 1. Spéc : `docs/superpowers/specs/2026-07-29-f3-webmethods-cluster-design.md`.

**Tech stack :** k3s v1.34.5, ArgoCD 3.4.5, kustomize plat, registre OCI Gitea
(`localhost:30300`), gh CLI (PR GitHub `stoa-platform/stoa`), ssh (alias
worker-1..5).

## Global Constraints

- **Règle de sûreté n°1 (lot 1)** : ne rien changer sur worker-3 (Caddy, conteneurs
  `wm-dev-*`, crons) ; après toute action, `dev-wm.gostoa.dev` doit répondre.
- **Aucun Ingress**, aucun NodePort pour `wm` ; ClusterIP uniquement.
- **Anti-affinité worker-3** (bloc PR #2819) sur toute charge persistante.
- **Jamais `Force`** dans les syncOptions ArgoCD ; apply server-side.
- **Aucun secret affiché** : toute sortie sensible → fichier root-only du nœud.
- Commits `stoa` : conventionnels, français, **`-s` (DCO)**, squash-merge.
- Le checkout `~/stoa-platform/stoa` a ~328 commits de retard : ne JAMAIS
  travailler dedans — worktree neuf basé `origin/main` (Tâche 1).
- Images : uniquement `localhost:30300/ci/...@sha256:...` dans les manifestes `wm`.
- ES : `vm.max_map_count=65530` mesuré identique sur worker-3 (où ES tourne
  depuis 2 mois) et worker-4 → parité de config, pas de préparation de nœud.

---

### Tâche 1 : Worktree stoa propre

**Files :** aucun (préparation git).

- [ ] **Step 1 : worktree basé origin/main**

```bash
git -C /Users/potomitan/stoa-platform/stoa fetch origin
git -C /Users/potomitan/stoa-platform/stoa worktree add \
  /Users/potomitan/stoa-platform/stoa-f3 -b feat/f3-wm-cluster origin/main
```

- [ ] **Step 2 : vérifier la base**

```bash
git -C /Users/potomitan/stoa-platform/stoa-f3 log --oneline -1   # = tête origin/main
ls /Users/potomitan/stoa-platform/stoa-f3/deploy/bootstrap/ci    # gitea jenkins vault
```

### Tâche 2 : Images dans le registre Gitea, digests notés

**Files :** aucun (registre). **Produces :** 3 digests `sha256:…` consommés par
les Tâches 3 et 5, notés dans `/tmp/f3-digests.txt` (poste de travail).

- [ ] **Step 1 : tirer curl (petite image du CronJob) sur worker-3**

```bash
ssh worker-3 'sudo docker pull curlimages/curl:8.10.1'
```

- [ ] **Step 2 : retag + push des 3 images (login `ci`, motif lot 1 T4)**

```bash
ssh worker-3 'sudo docker login localhost:30300 -u ci -p ci-bootstrap \
  && sudo docker tag softwareag/apigateway-trial:10.15 localhost:30300/ci/apigateway-trial:10.15 \
  && sudo docker tag docker.elastic.co/elasticsearch/elasticsearch:8.13.4 localhost:30300/ci/elasticsearch:8.13.4 \
  && sudo docker tag curlimages/curl:8.10.1 localhost:30300/ci/curl:8.10.1 \
  && sudo docker push localhost:30300/ci/apigateway-trial:10.15 \
  && sudo docker push localhost:30300/ci/elasticsearch:8.13.4 \
  && sudo docker push localhost:30300/ci/curl:8.10.1'
```

- [ ] **Step 3 : relever les digests DU REGISTRE (RepoDigests, pas Id)**

```bash
ssh worker-3 'for i in apigateway-trial:10.15 elasticsearch:8.13.4 curl:8.10.1; do \
  sudo docker image inspect localhost:30300/ci/$i \
    --format "{{index .RepoDigests 0}}"; done' | tee /tmp/f3-digests.txt
```

Attendu : trois lignes `localhost:30300/ci/<image>@sha256:…`.

- [ ] **Step 4 : preuve PULL-OK depuis worker-4 (le nœud cible) + contre-épreuve**

```bash
ssh worker-4 "sudo crictl pull $(grep apigateway /tmp/f3-digests.txt)" && echo PULL-OK
ssh worker-4 'sudo crictl pull localhost:30300/ci/apigateway-trial:9.99 && echo INATTENDU || echo REFUS-OK'
```

Attendu : `PULL-OK` puis `REFUS-OK` (NotFound).

### Tâche 3 : PR A — AppProject + clusterIP gitea + Elasticsearch

**Files (worktree `stoa-f3`) :**
- Modify : `deploy/bootstrap/argocd/appproject-stoa.yaml` (destination `wm`)
- Modify : `deploy/bootstrap/ci/gitea/service.yaml` (clusterIP épinglé)
- Create : `deploy/bootstrap/wm/elasticsearch/kustomization.yaml`
- Create : `deploy/bootstrap/wm/elasticsearch/statefulset.yaml`
- Create : `deploy/bootstrap/wm/elasticsearch/service.yaml`
- Create : `deploy/bootstrap/argocd/app-wm-elasticsearch.yaml`

**Interfaces — Produces :** Service `elasticsearch.wm.svc:9200` (nom court
`elasticsearch:9200` consommé par la gateway, Tâche 5) ; label `app=wm-elasticsearch`,
pod `wm-elasticsearch-0`.

- [ ] **Step 1 : destination `wm` dans l'AppProject** — dans la liste
`destinations:`, après l'entrée `ci` :

```yaml
    - server: https://kubernetes.default.svc
      namespace: wm
```

- [ ] **Step 2 : clusterIP épinglé dans `ci/gitea/service.yaml`** — sous
`type: NodePort`, ajouter (avec son commentaire, dette ROOT_URL/realm OCI — spéc F3 § D6) :

```yaml
  # ClusterIP épinglée (F3, dette realm OCI du lot 1) : le realm du registre
  # suit ROOT_URL (gitea.ci.svc.cluster.local:3000), que les HÔTES résolvent
  # par une entrée /etc/hosts vers cette ClusterIP (rôle registry_config,
  # stoa-labs). Tant que l'adresse n'était que runtime, une recréation du
  # Service l'aurait périmée en silence — exactement l'objection du commentaire
  # ci-dessus. La déclarer ici la rend stable et versionnée. Valeur = adresse
  # actuelle du Service (immuable côté API ; apply server-side = no-op).
  clusterIP: 10.43.60.211
```

- [ ] **Step 3 : manifestes ES** —

`deploy/bootstrap/wm/elasticsearch/kustomization.yaml` :

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: wm
resources:
  - service.yaml
  - statefulset.yaml
```

`deploy/bootstrap/wm/elasticsearch/service.yaml` :

```yaml
apiVersion: v1
kind: Service
metadata:
  name: elasticsearch
  namespace: wm
spec:
  # ClusterIP, pas de NodePort : seul le data store de la gateway. Le nom court
  # `elasticsearch` reproduit à l'identique l'adressage du compose worker-3
  # (apigw_elasticsearch_hosts=elasticsearch:9200) — zéro delta de config.
  selector:
    app: wm-elasticsearch
  ports:
    - name: http
      port: 9200
      targetPort: 9200
```

`deploy/bootstrap/wm/elasticsearch/statefulset.yaml` (env = copie conforme du
compose `deploy/vps/webmethods/docker-compose.dev.yml` ; digest = Tâche 2) :

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: wm-elasticsearch
  namespace: wm
spec:
  serviceName: elasticsearch
  replicas: 1
  selector:
    matchLabels:
      app: wm-elasticsearch
  template:
    metadata:
      labels:
        app: wm-elasticsearch
    spec:
      # Placement VOULU, pas subi : worker-4 est le seul nœud à la fois mesuré
      # (fio p99 10,95 ms — ES est le composant sensible au fsync du lot 2) et
      # vide ; worker-5 n'a jamais été mesuré et porte déjà les 3 PVC `ci`.
      # local-path épinglerait de toute façon le pod à son premier nœud : on
      # l'écrit. Exclut worker-3 par construction (motif PR #2819).
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: In
                    values:
                      - worker-4
      containers:
        - name: elasticsearch
          image: localhost:30300/ci/elasticsearch:8.13.4@sha256:DIGEST_ES
          env:
            # Copie conforme du Docker prouvé (worker-3, 2 mois de service).
            # xpack off : le namespace n'est pas exposé (aucun Ingress/NodePort) ;
            # NetworkPolicy = dette actée F4 (spéc F3).
            - name: discovery.type
              value: single-node
            - name: xpack.security.enabled
              value: "false"
            - name: ES_JAVA_OPTS
              value: "-Xms512m -Xmx512m"
          ports:
            - containerPort: 9200
          volumeMounts:
            - name: es-data
              mountPath: /usr/share/elasticsearch/data
          readinessProbe:
            httpGet:
              path: /_cluster/health
              port: 9200
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /_cluster/health
              port: 9200
            initialDelaySeconds: 60
            periodSeconds: 30
          resources:
            requests:
              cpu: 250m
              memory: 1536Mi
            limits:
              memory: 2560Mi
  volumeClaimTemplates:
    - metadata:
        name: es-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-path
        resources:
          requests:
            storage: 10Gi
```

`deploy/bootstrap/argocd/app-wm-elasticsearch.yaml` (gabarit `app-ci-jenkins.yaml`) :

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: wm-elasticsearch
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: stoa
  source:
    repoURL: https://github.com/stoa-platform/stoa.git
    targetRevision: main
    path: deploy/bootstrap/wm/elasticsearch
  destination:
    server: https://kubernetes.default.svc
    namespace: wm
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

- [ ] **Step 4 : remplacer `DIGEST_ES` par le digest réel (Tâche 2), valider kustomize**

```bash
D_ES=$(grep '/elasticsearch' /tmp/f3-digests.txt | sed 's/.*@//')
sed -i '' "s/sha256:DIGEST_ES/$D_ES/" \
  /Users/potomitan/stoa-platform/stoa-f3/deploy/bootstrap/wm/elasticsearch/statefulset.yaml
# Validation : rendu kustomize côté cluster (worker-1 a le binaire k3s kubectl).
tar -C /Users/potomitan/stoa-platform/stoa-f3/deploy/bootstrap/wm -cf - elasticsearch \
  | ssh worker-1 'rm -rf /tmp/f3-kz && mkdir -p /tmp/f3-kz && tar -C /tmp/f3-kz -xf - \
      && sudo k3s kubectl kustomize /tmp/f3-kz/elasticsearch >/dev/null && echo KUSTOMIZE-OK'
```

- [ ] **Step 5 : commit `-s`, push, PR, merge**

```bash
cd /Users/potomitan/stoa-platform/stoa-f3
git add deploy/bootstrap
git commit -s -m "feat(wm): Elasticsearch 8.13.4 en cluster — namespace wm, PVC worker-4 (F3 lot 2)"
git push -u origin feat/f3-wm-cluster
gh pr create --repo stoa-platform/stoa --fill
gh pr checks --watch && gh pr merge --squash --delete-branch
```

### Tâche 4 : Amorcer ES et prouver son état

- [ ] **Step 1 : appliquer AppProject + Application depuis origin/main (motif argocd_bootstrap)**

```bash
git -C /Users/potomitan/stoa-platform/stoa fetch origin
git -C /Users/potomitan/stoa-platform/stoa show origin/main:deploy/bootstrap/argocd/appproject-stoa.yaml \
  | ssh worker-1 'sudo k3s kubectl apply --server-side -f -'
git -C /Users/potomitan/stoa-platform/stoa show origin/main:deploy/bootstrap/argocd/app-wm-elasticsearch.yaml \
  | ssh worker-1 'sudo k3s kubectl apply --server-side -f -'
```

- [ ] **Step 2 : attendre le pod, vérifier placement + santé**

```bash
ssh worker-1 'sudo k3s kubectl -n wm wait pod/wm-elasticsearch-0 --for=condition=Ready --timeout=300s \
  && sudo k3s kubectl -n wm get pods -o wide \
  && sudo k3s kubectl -n wm get pvc'
```

Attendu : `wm-elasticsearch-0 Ready` sur **worker-4**, PVC `es-data-wm-elasticsearch-0` Bound.

- [ ] **Step 3 : garde worker-3 (règle n°1)**

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://dev-wm.gostoa.dev/rest/apigateway/health
ssh worker-3 'docker ps --format "{{.Names}} {{.Status}}" | grep wm-dev'
```

### Tâche 5 : PR B — la gateway et son cycle piloté

**Files (worktree `stoa-f3`, branche neuve `feat/f3-wm-apigateway`) :**
- Create : `deploy/bootstrap/wm/apigateway/kustomization.yaml`
- Create : `deploy/bootstrap/wm/apigateway/rbac.yaml`
- Create : `deploy/bootstrap/wm/apigateway/deployment.yaml`
- Create : `deploy/bootstrap/wm/apigateway/service.yaml`
- Create : `deploy/bootstrap/wm/apigateway/cronjob.yaml`
- Create : `deploy/bootstrap/argocd/app-wm-apigateway.yaml`

**Interfaces — Consumes :** `elasticsearch:9200` (Tâche 3). **Produces :**
Service `wm-apigateway.wm.svc:5555` (admin REST + data-plane) et `:9072` (UI) ;
label `app=wm-apigateway`.

- [ ] **Step 1 : brancher depuis main à jour**

```bash
cd /Users/potomitan/stoa-platform/stoa-f3
git fetch origin && git checkout -b feat/f3-wm-apigateway origin/main
```

- [ ] **Step 2 : manifestes** —

`deploy/bootstrap/wm/apigateway/kustomization.yaml` :

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: wm
resources:
  - rbac.yaml
  - service.yaml
  - deployment.yaml
  - cronjob.yaml
```

`deploy/bootstrap/wm/apigateway/rbac.yaml` :

```yaml
# ServiceAccount du CronJob de redémarrage piloté (cycle trial, spéc F3 § D5).
# deletecollection : c'est le verbe RBAC du DELETE par labelSelector.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: wm-restarter
  namespace: wm
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: wm-restarter
  namespace: wm
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["list", "deletecollection"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: wm-restarter
  namespace: wm
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: wm-restarter
subjects:
  - kind: ServiceAccount
    name: wm-restarter
    namespace: wm
```

`deploy/bootstrap/wm/apigateway/service.yaml` :

```yaml
# ClusterIP uniquement — doctrine no-Ingress du lot 1 : l'admin REST (5555) et
# la console (9072) ne sont joignables que du cluster ; accès humain par
# `kubectl port-forward`. L'exposition publique du data-plane viendra par la
# bascule Caddy (F5), pas par un Ingress.
apiVersion: v1
kind: Service
metadata:
  name: wm-apigateway
  namespace: wm
spec:
  selector:
    app: wm-apigateway
  ports:
    - name: is-admin-data
      port: 5555
      targetPort: 5555
    - name: console-ui
      port: 9072
      targetPort: 9072
```

`deploy/bootstrap/wm/apigateway/deployment.yaml` (`AUTH_B64` = base64 de
`Administrator:manage`, identifiants PAR DÉFAUT de la trial, déjà publics dans
le healthcheck du compose de ce dépôt) :

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wm-apigateway
  namespace: wm
spec:
  replicas: 1
  # Recreate : miroir des sémantiques `docker restart` du poste worker-3 ;
  # deux gateways trial simultanées sur le même ES n'ont aucun sens.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: wm-apigateway
  template:
    metadata:
      labels:
        app: wm-apigateway
    spec:
      # Anti-affinité worker-3 (motif PR #2819) : la prod Docker wm-dev-* y
      # tourne encore (double-run F3–F5) — GOAL, jalon F3.
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
        - name: apigateway
          image: localhost:30300/ci/apigateway-trial:10.15@sha256:DIGEST_GW
          env:
            # Copie conforme du compose dev worker-3 : l'état vit dans ES,
            # la gateway n'a AUCUN volume (constaté sur le Docker de référence).
            - name: apigw_elasticsearch_hosts
              value: "elasticsearch:9200"
            - name: apigw_elasticsearch_http_username
              value: ""
            - name: apigw_elasticsearch_http_password
              value: ""
          ports:
            - containerPort: 5555
            - containerPort: 9072
          # Retour mesuré ~5 min après restart (handoff 2026-07-29) : la
          # startupProbe laisse 10 min avant d'échouer ; ensuite readiness 15 s
          # (cadence du healthcheck compose) et liveness en filet du cas
          # « bloqué sans exit » (l'expiration trial, elle, sort en ExitCode 0
          # → restartPolicy Always la couvre).
          startupProbe:
            httpGet:
              path: /rest/apigateway/health
              port: 5555
              httpHeaders:
                - name: Authorization
                  value: "Basic AUTH_B64"
            periodSeconds: 15
            failureThreshold: 40
          readinessProbe:
            httpGet:
              path: /rest/apigateway/health
              port: 5555
              httpHeaders:
                - name: Authorization
                  value: "Basic AUTH_B64"
            periodSeconds: 15
          livenessProbe:
            httpGet:
              path: /rest/apigateway/health
              port: 5555
              httpHeaders:
                - name: Authorization
                  value: "Basic AUTH_B64"
            periodSeconds: 30
            failureThreshold: 10
          resources:
            requests:
              cpu: 500m
              memory: 3Gi
            limits:
              memory: 4Gi
```

`deploy/bootstrap/wm/apigateway/cronjob.yaml` :

```yaml
# Cycle trial PILOTÉ (spéc F3 § D5) : l'exploitant a tranché « pas de licence »
# (2026-07-29) ; l'expiration ~25-30 min devient un redémarrage contrôlé aux
# minutes 0/20/40 — le même motif que le cron root de worker-3, porté avec le
# pod. Le ReplicaSet recrée le pod aussitôt ; retour Ready ~5 min ; ~15 min de
# service par cycle de 20 min, conséquence assumée.
apiVersion: batch/v1
kind: CronJob
metadata:
  name: wm-restarter
  namespace: wm
spec:
  schedule: "*/20 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      activeDeadlineSeconds: 120
      template:
        spec:
          serviceAccountName: wm-restarter
          restartPolicy: Never
          containers:
            - name: restart
              image: localhost:30300/ci/curl:8.10.1@sha256:DIGEST_CURL
              command:
                - /bin/sh
                - -c
                - >
                  curl -sf --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
                  -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
                  -X DELETE
                  "https://kubernetes.default.svc/api/v1/namespaces/wm/pods?labelSelector=app%3Dwm-apigateway"
                  -o /dev/null -w "restart-piloté: %{http_code}\n"
```

`deploy/bootstrap/argocd/app-wm-apigateway.yaml` : identique à
`app-wm-elasticsearch.yaml` (Tâche 3) avec `name: wm-apigateway` et
`path: deploy/bootstrap/wm/apigateway`.

- [ ] **Step 3 : injecter digests + AUTH_B64**

```bash
cd /Users/potomitan/stoa-platform/stoa-f3
D_GW=$(grep apigateway /tmp/f3-digests.txt | sed 's/.*@//')
D_CURL=$(grep '/curl' /tmp/f3-digests.txt | sed 's/.*@//')
B64=$(printf 'Administrator:manage' | base64)
sed -i '' "s/sha256:DIGEST_GW/$D_GW/" deploy/bootstrap/wm/apigateway/deployment.yaml
sed -i '' "s/sha256:DIGEST_CURL/$D_CURL/" deploy/bootstrap/wm/apigateway/cronjob.yaml
sed -i '' "s/AUTH_B64/$B64/" deploy/bootstrap/wm/apigateway/deployment.yaml
grep -n 'sha256:DIGEST\|AUTH_B64' deploy/bootstrap/wm deploy/bootstrap/argocd -r && echo RESTE || echo PROPRE
```

- [ ] **Step 4 : commit `-s`, push, PR, merge** (même rituel que Tâche 3 Step 5,
message : `feat(wm): API Gateway 10.15 en cluster — cycle trial piloté, doctrine no-Ingress (F3 lot 2)`)

### Tâche 6 : Amorcer la gateway

- [ ] **Step 1 : appliquer l'Application**

```bash
git -C /Users/potomitan/stoa-platform/stoa fetch origin
git -C /Users/potomitan/stoa-platform/stoa show origin/main:deploy/bootstrap/argocd/app-wm-apigateway.yaml \
  | ssh worker-1 'sudo k3s kubectl apply --server-side -f -'
```

- [ ] **Step 2 : attendre Ready (jusqu'à 10 min), noter le nœud**

```bash
ssh worker-1 'sudo k3s kubectl -n wm wait pod -l app=wm-apigateway --for=condition=Ready --timeout=600s \
  && sudo k3s kubectl -n wm get pods -o wide'
```

- [ ] **Step 3 : garde worker-3** (même commande que Tâche 4 Step 3).

### Tâche 7 : Porte F3

- [ ] **Step 1 — F3a, ça répond depuis un pod** (curl éphémère, image du registre) :

```bash
ssh worker-1 'D=$(sudo k3s kubectl -n wm get cronjob wm-restarter -o jsonpath="{.spec.jobTemplate.spec.template.spec.containers[0].image}") \
  && sudo k3s kubectl -n wm run f3-probe --rm -i --restart=Never --image="$D" --command -- \
  curl -sf -u Administrator:manage http://wm-apigateway.wm.svc:5555/rest/apigateway/health'
```

Attendu : 200, JSON de santé avec le statut ES.

- [ ] **Step 2 — marqueur** :

```bash
ssh worker-1 'D=$(sudo k3s kubectl -n wm get cronjob wm-restarter -o jsonpath="{.spec.jobTemplate.spec.template.spec.containers[0].image}") \
  && sudo k3s kubectl -n wm run f3-marker --rm -i --restart=Never --image="$D" --command -- \
  curl -sf -u Administrator:manage -X POST -H "Content-Type: application/json" \
  -d "{\"name\":\"f3-proof-2026-07-29\",\"version\":\"1.0\"}" \
  http://wm-apigateway.wm.svc:5555/rest/apigateway/applications'
```

- [ ] **Step 3 — F3b, les données survivent aux pods** :

```bash
ssh worker-1 'sudo k3s kubectl -n wm delete pod -l app=wm-apigateway --wait=false \
  && sudo k3s kubectl -n wm delete pod wm-elasticsearch-0 --wait=false \
  && sudo k3s kubectl -n wm wait pod/wm-elasticsearch-0 --for=condition=Ready --timeout=300s \
  && sudo k3s kubectl -n wm wait pod -l app=wm-apigateway --for=condition=Ready --timeout=600s'
# puis relire :
# curl GET .../rest/apigateway/applications | grep f3-proof-2026-07-29  → présent
```

### Tâche 8 : Contre-épreuves + cycle observé

- [ ] **Step 1 — revient seul** : le Step 3 de la Tâche 7 EST la preuve (aucune
action de recréation humaine : ReplicaSet + StatefulSet). Confirmer par les
events : `kubectl -n wm get events --sort-by=.lastTimestamp | tail -20`.

- [ ] **Step 2 — rien ne fuit** :

```bash
ssh worker-1 'sudo k3s kubectl get ingress -A; sudo k3s kubectl -n wm get svc'
# depuis le poste de travail (hors cluster), sur l'IP publique de worker-4 :
for p in 5555 9072 9200; do nc -z -w3 <IP_worker4> $p && echo "OUVERT $p (ÉCHEC)" || echo "fermé $p (OK)"; done
```

Attendu : aucun Ingress dans `wm`, Services ClusterIP only, 3× `fermé`.

- [ ] **Step 3 — cycle piloté ≥ 40 min** : observer deux cycles :

```bash
ssh worker-1 'sudo k3s kubectl -n wm get jobs; sudo k3s kubectl -n wm get events \
  --field-selector reason=SuccessfulDelete 2>/dev/null; sudo k3s kubectl -n wm get pods'
```

Attendu : jobs `wm-restarter-*` Complete aux minutes 0/20/40 ; âge du pod
gateway < 20 min ; log du job = `restart-piloté: 200`.

### Tâche 9 : PR C — épinglage par digest des images du socle (dette lot 1)

**Files :** `deploy/bootstrap/ci/gitea/statefulset.yaml`,
`deploy/bootstrap/ci/jenkins/deployment.yaml` (Modify — digest ajouté à l'image).

- [ ] **Step 1** : relever les digests réellement en service :
`ssh worker-1 'sudo k3s crictl images --digests | grep -E "gitea|jenkins-go"'`
- [ ] **Step 2** : branche `feat/f3-digest-pinning`, remplacer `image:` par la
forme `repo:tag@sha256:…` dans les deux manifestes, avec un commentaire
`# Épinglé par digest (dette lot 1, passe F3)`.
- [ ] **Step 3 — VAULT EXCLU, motif documenté dans le commit** : épingler Vault
recréerait `vault-0`, qui redémarre SCELLÉ → descellement = geste exploitant
(parts hors de portée de l'agent, à raison). Reporté à la prochaine fenêtre
exploitant. Le commit le dit.
- [ ] **Step 4** : commit `-s`, PR, merge ; vérifier ensuite que gitea et
jenkins reviennent Ready (selfHeal roule les pods) et que Argo est `Synced/Healthy`.

### Tâche 10 : Preuve d'exécution + documentation + mémoire

- [ ] **Step 1** : section « Preuve d'exécution » ajoutée à CE plan (sorties
réelles horodatées de T2 S4, T7, T8).
- [ ] **Step 2** : `GOAL-socle-vers-gateway-2026-07-28.md` — F3 passe à
« FERMÉ le … » avec renvoi vers la preuve ; table de dette mise à jour
(ROOT_URL requalifiée/soldée D6 ; digest socle : gitea+jenkins soldés, vault
reporté motif scellement ; nouvelle dette : backup ns `wm`, NetworkPolicy ES,
migration données → F5).
- [ ] **Step 3** : handoff de session + mémoire auto (socle-ci-lot1 : F3 fermé).
- [ ] **Step 4** : commit stoa-labs.

---

## Preuve d'exécution (2026-07-29, session /goal F3)

Horodatages UTC, sorties réelles (transcript de session).

### Chaîne image (Tâche 2)

- Poussées depuis worker-3 (login `ci`) : `ci/apigateway-trial:10.15@sha256:b6aee2b4…`,
  `ci/elasticsearch:8.13.4@sha256:8efa98b1…`, `ci/curl:8.10.1@sha256:3a57427a…`.
- `crictl pull` **par digest** depuis worker-4 : `PULL-OK`.
- Contre-épreuve tag inexistant (`:9.99`) : `NotFound` (échec fermé).

### Livraison (Tâches 3–6)

- PR [#2821](https://github.com/stoa-platform/stoa/pull/2821) (AppProject `wm`,
  clusterIP gitea épinglée, ES) — checks verts, **mergée par l'exploitant**.
- PR [#2822](https://github.com/stoa-platform/stoa/pull/2822) (gateway + cycle
  piloté) — protection stricte : rebase requis après le merge de la A (motif
  mesuré : `mergeStateStatus: BEHIND` → rebase → `CLEAN`), merge relancé sur
  commande exploitant.
- Applications appliquées depuis `origin/main` (motif `argocd_bootstrap`, apply
  server-side, jamais `Force`).
- `wm-elasticsearch-0` : Ready en 109 s, **worker-4** (placement voulu), PVC
  `es-data-wm-elasticsearch-0` Bound 10 Gi local-path.
- `wm-apigateway-*` : Ready < 10 min (startupProbe), nœud hors worker-3.

### Porte F3 (Tâche 7)

- **F3a — répond depuis un pod** : depuis `wm-elasticsearch-0` (pod du cluster),
  `GET http://wm-apigateway.wm.svc:5555/rest/apigateway/health` → **HTTP 200** ;
  `health/all` : IS **green**, UI green, ES connecté (`elasticsearch:9200`,
  98 shards actifs, `yellow` = répliques non assignées, attendu en single-node).
- **Marqueur** : `POST /rest/apigateway/applications` `f3-proof-2026-07-29` →
  **201**, id `03e668ed-2925-4189-99bb-2d199d587dd9`, créé `15:51:37 GMT`.
- **F3b — les données survivent** : suppression simultanée du pod gateway ET de
  `wm-elasticsearch-0` à ~15:52Z → retour **autonome** des deux (ES en ~3 min,
  gateway Ready à `15:55:46Z`, ~3 min 31 au total, gateway re-planifiée sur
  worker-5) → relecture : `applications: ['f3-proof-2026-07-29']` →
  **MARQUEUR-PRESENT**. La preuve est portée par le PVC ES.

### Contre-épreuves (Tâche 8)

- **Revient seul** : events du ns — `SuccessfulCreate` ReplicaSet/StatefulSet
  sans action humaine (seul le `delete pod` était le sabotage).
- **Rien ne fuit** : `kubectl get ingress -A` → aucun dans `wm` (seuls les
  ingress historiques gateway-dev/staging, autres ns) ; Services `wm` ClusterIP
  uniquement ; depuis le poste de travail, 5555/9072/9200 **fermés** sur les IP
  publiques de worker-4 et worker-5 (6/6 refus, ufw 22/30080/30443 seulement).
- **Cycle piloté ≥ 40 min** : jobs `wm-restarter-29755640/29755660/29755680`
  Complete à 20 min d'intervalle exact ; log du job : `restart-pilote: 200` ;
  suppression du pod gateway observée en direct à la minute 0 (event `Killing`
  + `SuccessfulCreate` dans la même seconde). Les pods de job (curl, éphémères,
  sans PVC) tournent où le scheduler veut — y compris worker-3, toléré par la
  doctrine lot 1 (éphémère ≠ persistant).
- **Garde worker-3** (règle n°1) : prod Docker intacte pendant toute la session ;
  un 502 public observé à la minute 0 = le **propre cycle** `*/20` du cron root
  de worker-3 (conteneur `health: starting`), pas un effet de la session —
  retour healthy vérifié derrière.

### Écart assumé

- Le premier essai de sonde via `kubectl run -i --rm` a rendu la sortie
  illisible (course d'attache TTY) ; preuve rejouée par `kubectl exec` dans
  `wm-elasticsearch-0` — plus stable, et c'est bien « depuis un pod du cluster ».
- `gh pr merge` refusé à l'agent par le classifieur de permissions (2821) :
  motif lot 1 « l'agent prépare, l'exploitant exécute » — merges A et B portés
  par l'exploitant (commande `!`), rebase et vérifications par l'agent.
