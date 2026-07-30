# `deploy/bootstrap` — infrastructure d'accès du lab

Manifestes propres au **lab**, synchronisés par l'ArgoCD du cluster k3s Contabo.
Structure en miroir du dépôt `stoa` (`deploy/bootstrap/<namespace>/<composant>/`
plus `deploy/bootstrap/argocd/app-*.yaml`) pour garder un seul modèle mental
entre les deux dépôts.

Ce qui vit ici est **découplé du dépôt plateforme** : le lab doit pouvoir avancer
pendant le rebuild de `stoa`.

## `edge/cloudflared` — accès nominatif au lab

Un tunnel Cloudflare (`stoa-lab`) publie quatre noms sous `labs.gostoa.dev` :

| Nom | Service interne |
|---|---|
| `gitea.labs.gostoa.dev` | `gitea.ci:3000` |
| `jenkins.labs.gostoa.dev` | `jenkins.ci:8080` |
| `wm.labs.gostoa.dev` | `wm-apigateway.wm:9072` (console) |
| `wm-api.labs.gostoa.dev` | `wm-apigateway.wm:5555` (REST admin) |

**Aucun port n'est ouvert, aucun Ingress n'est créé.** La connexion vers
Cloudflare est sortante, et `cloudflared` joint les Services par leur nom DNS
interne. La contre-épreuve F3 — « aucun Ingress dans `wm`, ClusterIP only,
5555/9072/9200 fermés de l'extérieur » — reste vraie telle qu'elle a été prouvée.

Le TLS est terminé par Cloudflare : le cluster n'a ni cert-manager ni
ClusterIssuer, et n'en a pas besoin pour ce chemin.

### Ce qui n'est PAS dans Git

Un seul secret, créé hors dépôt. Le manifeste le référence par nom.

**`Secret/cloudflared-credentials` dans le namespace `edge`**

Porte la clé `credentials.json` (`AccountTag`, `TunnelSecret`, `TunnelID`).
Obtenu à la création du tunnel ; conservé hors ligne côté exploitant.

```bash
kubectl -n edge create secret generic cloudflared-credentials \
  --from-file=credentials.json=<chemin-hors-ligne>/tunnel-credentials.json
```

Aucun identifiant de dépôt n'est nécessaire : `stoa-labs` est **public**, comme
`stoa`, et Argo le clone en anonyme. Ce dépôt étant public, **rien de sensible ne
doit y entrer** — ni identifiant, ni topologie exploitable, ni dette de sécurité
encore ouverte.

### Amorçage

L'`Application` elle-même n'est pas synchronisée par Argo (problème de
l'œuf et de la poule). Elle s'applique une fois, après le secret :

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

Un jeton `lab-wm-api-postman` est en place sur `wm-api.labs.gostoa.dev`
(politique `non_identity`, validité 1 an). Ses valeurs sont conservées hors ligne
côté exploitant — Cloudflare n'affiche le secret qu'à la création.

Pour la collection `gateways/webmethods/postman/wm-1015-bulk-owner` :

| Variable | Valeur |
|---|---|
| `gwUrl` | `https://wm-api.labs.gostoa.dev` |
| `gwBasePath` | `/rest/apigateway` |

plus les deux en-têtes Access au niveau de la collection. Attention : cette
gateway est celle **du cluster**, pas l'instance Docker de worker-3 sur laquelle
la collection a été prouvée — leurs catalogues sont distincts (F3 démarre vide,
la migration des données est prévue en F5).

### Preuve d'exécution — 2026-07-30

- Tunnel `stoa-lab` : `healthy`, **8 connexions** (4 par pod, 2 réplicas sur
  worker-4 et worker-5 — worker-3 évité).
- Argo `edge-cloudflared` : `Synced/Healthy` sur la révision attendue ; ancien
  ConfigMap sans empreinte **élagué**, volume sur
  `cloudflared-config-<empreinte>`.
- Les 4 noms sans authentification → **302** vers `stoa-platform.cloudflareaccess.com`.
- `wm-api` avec jeton de service → **200** sur `/rest/apigateway/health`, puis
  `GET /rest/apigateway/apis` renvoie le catalogue réel.
- Fenêtre de licence observée telle que documentée : 502 pendant ~105 s après
  redémarrage du pod, puis 200.

### Dettes assumées

- **Image `cloudflared` épinglée par digest** (`2025.8.1`), mais tirée du Docker
  Hub et non du registre Gitea — contrairement aux images wM de F3. À reprendre
  si la doctrine « tout par le registre interne » doit tenir ici aussi.
- **Le cycle de licence webMethods reste visible** : `wm.lab` et `wm-api.lab`
  renvoient des 502 pendant ~3 min toutes les 20 min (CronJob `wm-restarter`).
  Ce n'est pas une défaillance du tunnel.
