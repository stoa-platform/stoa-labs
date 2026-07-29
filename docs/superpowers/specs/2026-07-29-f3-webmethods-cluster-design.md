---
title: "F3 — webMethods 10.15 dans le cluster : spécification"
type: spec
status: "Arbitrages tranchés en autonomie (session /goal F3 du 2026-07-29) sur mesures terrain + rapports d'exploration ; à exécuter via le plan du même jour"
date: 2026-07-29
lié: [GOAL-socle-vers-gateway-2026-07-28, HANDOFF-2026-07-29-F2-VAULT-LICENCE]
---

# F3 — webMethods 10.15 dans le cluster (spécification)

## Objectif et porte de preuve (repris du GOAL, invariants)

**Porte F3 :** `/rest/apigateway` répond depuis un pod du cluster ; les données
survivent à la suppression du pod (PVC).
**Contre-épreuve :** pod tué en pleine vie → revient seul, config intacte ; et
l'admin REST reste **inaccessible hors du cluster** (aucun Ingress — la doctrine
du lot 1 tient).

Préalable licence : **tranché le 2026-07-29 (exploitant) — pas de licence** ;
le pod cluster porte le même motif que worker-3 : **redémarrage périodique
piloté** (pas subi), à intégrer à cette spéc.

## Terrain mesuré (2026-07-29, avant toute écriture)

| Mesure | Valeur |
|---|---|
| Source de vérité fonctionnelle | `stoa`:`deploy/vps/webmethods/docker-compose.dev.yml` (= `/opt/webmethods-dev/docker-compose.yml` sur worker-3) |
| Image gateway | `softwareag/apigateway-trial:10.15` (3,45 Go, build 95, 10.15.0.0), **aucun volume** — tout l'état vit dans Elasticsearch |
| Image ES | `docker.elastic.co/elasticsearch/elasticsearch:8.13.4` (1,23 Go), single-node, `xpack.security.enabled=false`, heap 512m |
| Données ES réelles | **109 Mo** (`webmethods-dev_es-dev-data`, mesuré `du -sh`) |
| Conso RAM mesurée | gateway 2,17 Gio ; ES 2,97 Gio (cache compris) |
| Cycle trial | expiration ~25-30 min ; retour `healthy` en ~5 min ; cron root worker-3 `*/20` (`docker restart`) **+** keepalive hegemon `*/25` conditionnel (doublon, cf. § Observations) |
| Cluster | w1 control-plane, w3/w4/w5 agents ; `local-path` (WaitForFirstConsumer, PV `spec.local`, racine `/var/lib/rancher/k3s/storage`) ; ns `ci` sur worker-5 |
| RAM/disque libres | ~20 Go RAM et >330 Go disque par nœud |
| fio (profil WAL, nœuds au repos) | w1 p99 10,03 ms ; w2 9,63 ms ; **w4 10,95 ms** ; w3/w5 **jamais mesurés** (garde de charge) |
| Registre | Gitea NodePort `localhost:30300`, pull **anonyme** (motif `ci/jenkins-go:v1`), push authentifié `ci`/`ci-bootstrap` depuis worker-3 (seul nœud à moteur de build) ; realm OCI = `ROOT_URL` (`gitea.ci.svc.cluster.local:3000`), résolu par `/etc/hosts`→ClusterIP sur les hôtes (rôle `registry_config`) |
| ufw public | 22, 30080, 30443 uniquement — 30300 et 5555 non routés |

## Décisions (avec alternatives écartées)

### D1 — Namespace dédié `wm`

Nouveau namespace `wm` (créé par `CreateNamespace=true`), ajouté aux
`destinations` de l'AppProject `stoa` (fail-closed : sans cette ligne,
l'Application reste `Unknown`). Écarté : réutiliser `ci` (mélange socle/charge
applicative) ; `gateway-dev` (déjà porteur des gateways stoa, sémantique
différente).

### D2 — Les images passent par le registre Gitea, épinglées par digest

Trois poussées depuis worker-3 (docker login `ci`, motif prouvé lot 1 T4) :

| Source | Cible registre |
|---|---|
| `softwareag/apigateway-trial:10.15` (déjà locale) | `localhost:30300/ci/apigateway-trial:10.15` |
| `elasticsearch:8.13.4` (déjà locale) | `localhost:30300/ci/elasticsearch:8.13.4` |
| `curlimages/curl` (à tirer, ~10 Mo) | `localhost:30300/ci/curl:<version>` (pour le CronJob de redémarrage) |

Les manifestes référencent les images **par digest** (`…@sha256:…`) : c'est la
dette « épinglage par digest » du lot 1, affectée « F3, même passe » — appliquée
aussi aux images du socle dans une PR distincte, **sauf Vault** : changer son
`image:` recréerait `vault-0`, qui redémarre **scellé** — le descellement est un
geste exploitant (les parts sont hors de portée de l'agent, à raison). Reporté à
la prochaine fenêtre exploitant, motif dans le commit. Conséquence assumée : l'image trial devient lisible anonymement par
quiconque atteint `:30300` — même exposition que `jenkins-go` (loopback + pairs
cluster, ufw ferme le reste) ; l'image est par ailleurs publique sur Docker Hub.

### D3 — Elasticsearch : StatefulSet 1 réplique sur worker-4, config identique au Docker prouvé

- StatefulSet `wm-elasticsearch`, 1 réplique, image ES par digest, env repris du
  compose à l'identique (`discovery.type=single-node`,
  `xpack.security.enabled=false`, `ES_JAVA_OPTS=-Xms512m -Xmx512m`).
- `volumeClaimTemplates` : 10 Gi `local-path` (données réelles : 109 Mo — marge
  ×90 pour F4+).
- **Placement : `nodeAffinity` requis `In [worker-4]`** — seul nœud à la fois
  *mesuré* (fio p99 10,95 ms, le composant est sensible au fsync) et *vide* ;
  worker-5 n'a jamais été mesuré et porte déjà les 3 PVC `ci` (rayon de panne).
  `local-path` épinglerait de toute façon le pod à son premier nœud : l'écrire
  en Git rend le placement voulu, pas subi. Satisfait l'anti-affinité worker-3
  par construction.
- Service `elasticsearch` ClusterIP :9200 — le même nom court que dans le
  compose, donc `apigw_elasticsearch_hosts=elasticsearch:9200` porte tel quel.
- Probes : readiness/liveness sur `GET /_cluster/health` (le healthcheck compose).
- requests 250m/1,5 Gi, limits mémoire 2,5 Gi (jamais de limite CPU — convention
  du socle).

Écarté : ES mutualisé avec une future pile observabilité (rien n'existe, YAGNI) ;
sécurité xpack activée (délta de config non prouvé par le Docker de référence ;
le namespace n'est pas exposé — une NetworkPolicy reste une dette, cf. § Dette).

### D4 — Gateway : Deployment 1 réplique, `Recreate`, sans volume

- Deployment `wm-apigateway`, 1 réplique, `strategy: Recreate` (miroir des
  sémantiques `docker restart` ; deux gateways trial simultanées sur le même ES
  n'ont aucun sens).
- Env du compose repris à l'identique (`apigw_elasticsearch_hosts=elasticsearch:9200`,
  user/pass ES vides). Aucun volume : l'état vit dans ES (confirmé worker-3).
- **Anti-affinité worker-3** (bloc PR #2819 recopié de `ci/vault/statefulset.yaml`) :
  la prod Docker y tourne encore (double-run F3–F5).
- Probes calquées sur le healthcheck compose (`GET /rest/apigateway/health`,
  header `Authorization: Basic` Administrator:manage — identifiants par défaut
  de la trial, cluster-interne) : startupProbe généreuse (retour mesuré ~5 min →
  échec à 10 min), readiness 15 s, liveness en filet.
- Service `wm-apigateway` ClusterIP :5555 (admin REST + data-plane) et :9072
  (console UI) — **aucun NodePort, aucun Ingress**. Accès humain :
  `kubectl port-forward` (doctrine lot 1).
- requests 500m/3 Gi, limits mémoire 4 Gi (mesuré : 2,17 Gio).

### D5 — Le cycle trial porté : CronJob `*/20` qui supprime le pod

Le motif worker-3 (« redémarrage contrôlé avant l'expiration, à instants
connus ») devient : **CronJob `wm-restarter`**, `schedule: "*/20 * * * *"`,
`concurrencyPolicy: Forbid`, image `ci/curl` (par digest), qui appelle l'API
server (`DELETE /api/v1/namespaces/wm/pods?labelSelector=app=wm-apigateway`)
avec un ServiceAccount dédié (Role : `list`+`deletecollection` sur `pods` —
c'est le verbe RBAC du DELETE-par-sélecteur ; RBAC namespacé, motif
`ci/jenkins/rbac.yaml`). Le ReplicaSet recrée le pod
immédiatement : redémarrage piloté, daté, visible dans les events.

Filets (l'expiration reste subie si le CronJob meurt) : le conteneur trial
s'auto-termine (ExitCode 0 observé au lot 1) → `restartPolicy: Always` le
relance ; la livenessProbe couvre les blocages sans exit. Conséquence de
service identique à worker-3 et assumée par l'exploitant : ~15 min de service
par cycle de 20 min.

Écarté : livenessProbe seule (redémarrage subi, pas piloté) ; `kubectl` en
image dédiée (une image de plus à porter pour un simple DELETE HTTP) ; toucher
au cron worker-3 (règle de sûreté n°1 du lot 1 : la prod Docker reste intacte
jusqu'à F5).

### D6 — Dette ROOT_URL/realm OCI : requalifiée et bornée ici

Constat re-mesuré : le realm OCI suit `ROOT_URL` =
`http://gitea.ci.svc.cluster.local:3000` — qui est **le nom DNS natif du
Service** : les pods le résolvent par CoreDNS sans artifice ; seuls les hôtes
(containerd, docker) ont besoin du shim `/etc/hosts`→ClusterIP posé et
re-vérifié par le rôle `registry_config`. « Un ROOT_URL résoluble partout »
est donc déjà vrai côté pods ; le changer pour `localhost:30300` casserait
précisément ce côté-là. Les pods wM ne parlent d'ailleurs jamais au registre à
l'exécution (le pull est l'affaire de containerd, côté hôte).

**Décision : `ROOT_URL` ne change pas.** Le résidu réel de la dette — « liaison
mutable hors Git » (une ClusterIP réattribuée périmerait `/etc/hosts` en
silence) — est soldé en **épinglant `spec.clusterIP` du Service `gitea` dans le
manifeste** (valeur actuelle `10.43.60.211`, immuable côté API, désormais
déclarée en Git ; apply server-side = no-op). Le rôle `registry_config` reste
le vérificateur (read-back 200/401 sur le realm).

### D7 — Livraison : PR sur `stoa`, Applications appliquées comme au lot 1

- Arborescence : `deploy/bootstrap/wm/{elasticsearch,apigateway}/` (kustomize
  minimaliste : `kustomization.yaml` avec `namespace: wm` + liste plate),
  Applications `deploy/bootstrap/argocd/app-wm-{elasticsearch,apigateway}.yaml`
  clonées du gabarit `app-ci-jenkins.yaml` (`project: stoa`, automated
  prune+selfHeal, `CreateNamespace=true`, `ServerSideApply=true`, jamais
  `Force`).
- **Trois PR** sur `github.com/stoa-platform/stoa` (trunk-based, commits
  conventionnels français, **DCO `-s`**, squash) :
  1. AppProject (+`wm` en destination) + clusterIP gitea épinglé (D6) + ES ;
  2. apigateway (Deployment, Services, RBAC, CronJob) ;
  3. épinglage par digest des 3 images du socle (dette, même passe).
- Les Applications ne s'auto-amorcent pas (pas d'app-of-apps) : après merge,
  `kubectl apply --server-side` de `appproject-stoa.yaml` + `app-wm-*.yaml`
  depuis worker-1 (le geste d'amorçage du lot 1).
- Le checkout local `stoa/` a 328 commits de retard : travail depuis un
  worktree neuf basé `origin/main`, jamais depuis le working tree courant.

## Preuves à jouer (dans l'ordre)

1. **Chaîne image** : push des 3 images, digests notés ; `crictl pull` du digest
   gateway depuis worker-4 (motif PULL-OK lot 1) ; contre-épreuve : tag
   inexistant → `NotFound`.
2. **Porte F3a — ça répond** : depuis un pod du cluster (autre que la gateway),
   `curl -u Administrator:manage http://wm-apigateway.wm.svc:5555/rest/apigateway/health`
   → 200, statut ES vert dans la réponse.
3. **Porte F3b — les données survivent** : créer un marqueur par l'admin REST
   (une application gateway nommée `f3-proof-<date>`), `kubectl delete pod` de
   la gateway **et** d'`elasticsearch-0`, attendre le retour `Ready`, relire le
   marqueur → présent (c'est le PVC ES qui a porté la preuve).
4. **Contre-épreuve 1 — retour seul** : pod gateway tué en pleine vie → le
   ReplicaSet le recrée sans action humaine, config intacte (le marqueur).
5. **Contre-épreuve 2 — rien ne fuit** : `kubectl get ingress -A` → aucun dans
   `wm` ; depuis l'extérieur (poste de travail), 5555/9072/9200 injoignables
   sur les IP publiques des nœuds (ufw) ; `kubectl get svc -n wm` → ClusterIP
   uniquement.
6. **Cycle piloté** : events du namespace sur ≥40 min → deux suppressions de
   pod aux minutes 0/20/40, retour `Ready` ~5 min, aucune expiration subie
   entre les cycles.

## Observations pour l'exploitant (hors périmètre, à ne pas perdre)

- **Doublon de crons sur worker-3** (mesuré) : root `*/20` (`docker restart`
  inconditionnel) **et** hegemon `*/25` (`wm-dev-keepalive.sh`, restart si
  non-`healthy`). Aux minutes 20→25, la gateway est encore en démarrage
  (`starting` ≠ `healthy`) → le keepalive la redémarre une seconde fois ;
  perte estimée ~5 min de service par heure. Suggestion : supprimer le
  keepalive hegemon (le cron root suffit), ou l'aligner sur un test
  `starting|healthy`.

## Dette nouvelle / reportée (actée)

| Dette | Porteur |
|---|---|
| Étendre la sauvegarde F2 au ns `wm` (`backup_pvc_namespaces`, quiescement ES à instruire — risque `.suspect` si archivage à chaud) | juste après la porte F3, même branche si possible |
| NetworkPolicy autour d'ES (sans auth xpack, joignable de tout pod du cluster) | F4 (quand les clients réels seront connus) |
| Migration des données worker-3 → cluster (109 Mo ; double-run = deux sources de vérité) | F5 (bascule) — F3 démarre **vide**, c'est assumé |
| Re-pointage `envs/dev/targets*.yaml` (labctl) vers le Service cluster | F4 |
| Rotation `ci`/`ci-bootstrap` (le push d'images en dépend encore) | F4 (inchangé) |

## Risques

- **ES en fsync** sur worker-4 : mesuré au repos seulement (p99 10,95 ms) ; la
  charge F3 est minuscule (109 Mo, une gateway dev). Seuil d'abandon du RAPPORT
  (p99 > ~20 ms sous charge) à re-mesurer si F4 charge réellement.
- **RAM** : +~5,5 Gi demandés sur worker-4 (21 Go libres) — large.
- **Double-run** : coût RAM/disque temporaire sur la flotte, fenêtre F3→F5 à
  garder courte (risque acté au GOAL).
- **selfHeal** : toute intervention out-of-band sur le ns `wm` sera revertée en
  ~5 s — les preuves passent par Git ou par des suppressions de pod (que le
  ReplicaSet répare, c'est le comportement voulu).
