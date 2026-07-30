# `deploy/bootstrap` — infrastructure d'accès du lab

Manifestes propres au **lab**, synchronisés par l'ArgoCD du cluster k3s Contabo.
Structure en miroir du dépôt `stoa` (`deploy/bootstrap/<namespace>/<composant>/`
plus `deploy/bootstrap/argocd/app-*.yaml`) pour garder un seul modèle mental
entre les deux dépôts.

Ce qui vit ici est **découplé du dépôt plateforme** : le lab doit pouvoir avancer
pendant le rebuild de `stoa`.

## `edge/cloudflared` — accès nominatif au lab

Un tunnel Cloudflare (`stoa-lab`) publie quatre noms sous `lab.gostoa.dev` :

| Nom | Service interne |
|---|---|
| `gitea.lab.gostoa.dev` | `gitea.ci:3000` |
| `jenkins.lab.gostoa.dev` | `jenkins.ci:8080` |
| `wm.lab.gostoa.dev` | `wm-apigateway.wm:9072` (console) |
| `wm-api.lab.gostoa.dev` | `wm-apigateway.wm:5555` (REST admin) |

**Aucun port n'est ouvert, aucun Ingress n'est créé.** La connexion vers
Cloudflare est sortante, et `cloudflared` joint les Services par leur nom DNS
interne. La contre-épreuve F3 — « aucun Ingress dans `wm`, ClusterIP only,
5555/9072/9200 fermés de l'extérieur » — reste vraie telle qu'elle a été prouvée.

Le TLS est terminé par Cloudflare : le cluster n'a ni cert-manager ni
ClusterIssuer, et n'en a pas besoin pour ce chemin.

### Ce qui n'est PAS dans Git

Deux secrets, créés hors dépôt. Les manifestes les référencent par nom.

**1. `Secret/cloudflared-credentials` dans le namespace `edge`**

Porte la clé `credentials.json` (`AccountTag`, `TunnelSecret`, `TunnelID`).
Obtenu à la création du tunnel ; conservé hors ligne côté exploitant.

```bash
kubectl -n edge create secret generic cloudflared-credentials \
  --from-file=credentials.json=<chemin-hors-ligne>/tunnel-credentials.json
```

**2. Secret de dépôt Argo, dans le namespace `argocd`**

`stoa-labs` est privé. Argo s'authentifie par une **clé de déploiement en
lecture seule** posée sur le dépôt (`argocd-k3s-contabo`).

```bash
kubectl -n argocd create secret generic repo-stoa-labs \
  --from-literal=type=git \
  --from-literal=url=git@github.com:stoa-platform/stoa-labs.git \
  --from-file=sshPrivateKey=<chemin-hors-ligne>/argocd-stoa-labs
kubectl -n argocd label secret repo-stoa-labs \
  argocd.argoproj.io/secret-type=repository
```

### Amorçage

L'`Application` elle-même n'est pas synchronisée par Argo (problème de
l'œuf et de la poule). Elle s'applique une fois, après les deux secrets :

```bash
kubectl apply -f deploy/bootstrap/argocd/app-cloudflared.yaml
```

À partir de là, tout changement dans `edge/cloudflared/` est repris
automatiquement (`selfHeal`, `prune`).

### Authentification

Chaque nom est protégé par une application **Cloudflare Access**. Les politiques
vivent chez Cloudflare, pas ici.

Point à ne pas perdre de vue : **Access est un périmètre, pas un correctif.**
Jenkins n'a toujours pas de realm de sécurité — qui franchit Access obtient un
Jenkins complet, donc Vault par identité de pod. Le jalon F4 reste nécessaire.

Pour les accès machine (collection Postman, CI Ansible), Access fournit des
**jetons de service** : en-têtes `CF-Access-Client-Id` et
`CF-Access-Client-Secret`, sans parcours navigateur.

### Dettes assumées

- **Image `cloudflared` épinglée par digest** (`2025.8.1`), mais tirée du Docker
  Hub et non du registre Gitea — contrairement aux images wM de F3. À reprendre
  si la doctrine « tout par le registre interne » doit tenir ici aussi.
- **Le cycle de licence webMethods reste visible** : `wm.lab` et `wm-api.lab`
  renvoient des 502 pendant ~3 min toutes les 20 min (CronJob `wm-restarter`).
  Ce n'est pas une défaillance du tunnel.
