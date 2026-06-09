# CI bank-réaliste — Gitea + Jenkins + webhooks (GitOps, air-gapped)

Reproduit l'environnement d'exploitation d'une banque : **Jenkins** (le CI du
client) déclenché par **webhook** sur un **push Git** (Gitea), qui build `labctl`
**sans internet** (deps vendorées) et fédère le contrat sur les 3 gateways **par
leurs noms internes** (zéro flux entrant depuis l'extérieur).

> ⚠️ Scaffold de démonstration — **première mise en route à valider** (création du
> repo Gitea + webhook + job Jenkins). Standard, mais non encore bouté ici.

## Build air-gapped (sans internet) — déjà prouvé

`labctl` se compile **hors-ligne** grâce aux dépendances vendorées :

```bash
cd labctl
go mod vendor                                   # une fois, avec internet (hors zone)
GOPROXY=off GOFLAGS=-mod=vendor go build -o /tmp/labctl .   # ZÉRO réseau
```

→ Deux modèles de livraison en banque (aucun ne suppose internet dans la zone) :
1. **Binaire pré-buildé + signé** (recommandé) : tu builds dehors, tu livres le
   binaire (9.6 Mo) signé + SBOM ; aucun toolchain Go ni internet dans la zone.
2. **Source + `vendor/`** : le CI du client build offline (`GOPROXY=off -mod=vendor`).
3. (variante) **proxy Go interne** (Athens/Artifactory) si la banque en a un.

## Lancer la CI locale

```bash
# socle déjà up (./scripts/up.sh). Ajouter Gitea + Jenkins (réseau partagé) :
docker compose -f docker-compose.poc.yml -f docker-compose.ci.yml up -d --build gitea jenkins
```

- **Gitea** : http://localhost:13000  (créer un user, un repo, y pousser ce dépôt)
- **Jenkins** : http://localhost:18080  (assistant désactivé pour la démo)

## Câbler le flux (webhook → pipeline)

1. Dans Gitea : créer un repo (ex. `stoa-labs`), y pousser le contenu du dépôt
   (il contient `poc-control-plane-federation/labctl` **avec `vendor/`**, les
   `apis/`, `targets.cluster.yaml` et `ci/Jenkinsfile`).
2. Dans Jenkins : créer un job **Pipeline** → *Pipeline script from SCM* → Git →
   URL `http://gitea:3000/<user>/stoa-labs.git` → *Script Path* `poc-control-plane-federation/ci/Jenkinsfile`.
3. Dans Gitea : repo → *Settings → Webhooks → Gitea* → URL
   `http://jenkins:8080/job/<job>/build?token=...` (ou le plugin Generic Webhook
   Trigger), événement **Push**.
4. **Commit un changement** dans `apis/accounts-read.openapi.yaml` ou
   `targets.cluster.yaml` → le webhook déclenche Jenkins → `labctl apply` fédère
   l'API sur WSO2 + APISIX + webMethods. **Define Once, depuis un commit.**

## Pourquoi c'est le bon modèle pour une banque

- **Pas d'agent runtime** : le CI applique l'état désiré (GitOps pull) — cf.
  [`../../adr/adr-068-stoa-off-the-transaction-path.md`](../../adr/adr-068-stoa-off-the-transaction-path.md).
- **Zéro entrant externe** : Jenkins tourne **dans** le réseau ; il atteint les
  admin APIs des gateways en interne. Rien n'ouvre de port vers la zone depuis dehors.
- **Air-gapped** : build sans internet (vendor/), binaire signable (condition
  ADR-068 : « build signé + reproductible, SBOM »).
- **Exécuté par le client, pas par toi** : c'est *leur* Jenkins qui lance un
  binaire **approuvé**, sous *leur* change-control et *leur* audit (cf. la
  réponse « ai-je le droit de lancer la CLI ? » → idéalement non, c'est leur CI).
