# CI bank-réaliste — Gitea + Jenkins + webhooks (GitOps, air-gapped)

Reproduit l'environnement d'exploitation d'une banque : **Jenkins** (le CI du
client) déclenché par **webhook** sur un **push Git** (Gitea), qui build `labctl`
**sans internet** (deps vendorées) et fédère le contrat sur les 3 gateways **par
leurs noms internes** (zéro flux entrant depuis l'extérieur).

## TROIS pipelines (modèle multi-env, ADR-075)

| Pipeline | Fichier | Déclenchement | Fait quoi |
|---|---|---|---|
| **Hors-prod** | `ci/Jenkinsfile` | webhook push (GenericTrigger token `stoa-ci`) | build air-gapped + apply 3 gateways + boucle **dev → rec → int** : `apply-uac --env $E -f envs/$E/targets.cluster.yaml` via les **proxies admin** `wm-admin-{env}` du wM réel (Bearer `ci-horsprod`, scopes `deploy:dev+rec+int`, **jamais** `deploy:prod`). Gate **GIT** : un env sans `deploy.{env}.yaml` mergé est skippé (narration). |
| **Prod** | `ci/Jenkinsfile.prod` | **AUCUN trigger** — Build with Parameters (`PROMOTION_ID`) | gate **Git-natif** relu avant tout dispatch (promotion `status=approved`, `to=prod`, 4-yeux `approved_by != requested_by`, `change_ref` ITSM + `pv_ref` non vides, `deploy.prod.yaml` avec **commit pinné**) → `apply-uac --env prod -f envs/prod/targets.cluster.yaml` (admin **direct**, creds Vault) → smoke data-plane. |
| **Rollback** | `ci/Jenkinsfile.rollback` | **AUCUN trigger** — paramètres `PROMOTION_ID`+`REASON`+`CHANGE_REF` | `POST .../promotions/{id}/rollback` sur governance-api (revert **Git** audité, token compte de service) puis **re-apply prod** idempotent + smoke. Jamais de DELETE gateway. |

**Câblage multi-env** (en plus du socle) : `docker-compose.envs.yml` (mocks wM
dev/rec/int sur le réseau **nonprod interne** + itsm-mock :8788 + wM réel ponté
`[poc, nonprod]` — recreate requis), `scripts/setup-vault-envs.sh` (secrets
`secret/stoa/envs/{env}/wm-admin` + `ciHorsprodSecret`),
`scripts/setup-ci-horsprod.sh` (client + client scopes `deploy:{env}`),
`scripts/setup-wm-admin-proxy.sh` (pose + prouve les 3 proxies allowlist).
Démo bout-en-bout + contre-épreuves : `scripts/demo-multienv.sh`.
Décision et findings : [`../adr/adr-075-wm-admin-proxy-multienv.md`](../adr/adr-075-wm-admin-proxy-multienv.md).

Contre-épreuve topologique : `docker exec poc-jenkins getent hosts wm-mock-dev`
échoue — Jenkins n'a **aucune route** vers les gateways d'envs bas ; l'unique
chemin est le proxy admin scopé du wM prod (la contrainte réseau du client est
respectée ET prouvée).

> ✅ **VALIDÉ LIVE le 2026-06-11** (Phase 0 Console Light) : commit → push Gitea →
> webhook → Jenkins → build labctl air-gapped → `apply` 3/3 gateways → catalogue
> vérifié. Builds #2 (manuel) et #3 (déclenché par webhook) SUCCESS — logs dans
> `console-light/evidence/ci/`. Câblage automatisé : `console-light/scripts/ci-wire.sh`
> (+ `ci-mirror.sh`). Trois corrections apportées au scaffold au premier run :
> 1. l'image Jenkins de base n'a AUCUN plugin → `git`, `workflow-aggregator` et
>    `generic-webhook-trigger` ajoutés au Dockerfile ;
> 2. `POST /job/…/build?token=` est refusé par les Jenkins modernes (403 crumb
>    CSRF) → webhook vers `/generic-webhook-trigger/invoke?token=…` (exempt),
>    trigger déclaré dans le Jenkinsfile (s'enregistre au premier build) ;
> 3. `options { timestamps() }` exigeait le plugin timestamper absent → retiré.

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
5. **Jobs prod et rollback** (ADR-075) : deux jobs Pipeline supplémentaires,
   *Script Path* `poc-control-plane-federation/ci/Jenkinsfile.prod` et
   `…/ci/Jenkinsfile.rollback` — **sans webhook** (aucun trigger déclaré : ils
   ne partent QUE de *Build with Parameters*). Lancer chaque job une première
   fois pour enregistrer ses paramètres (`PROMOTION_ID`, …).

## Pourquoi c'est le bon modèle pour une banque

- **Pas d'agent runtime** : le CI applique l'état désiré (GitOps pull) — cf.
  le principe « STOA hors du chemin transactionnel ».
- **Zéro entrant externe** : Jenkins tourne **dans** le réseau ; il atteint les
  admin APIs des gateways en interne. Rien n'ouvre de port vers la zone depuis dehors.
- **Air-gapped** : build sans internet (vendor/), binaire signable (condition
  le principe hors-data-plane : « build signé + reproductible, SBOM »).
- **Exécuté par le client, pas par toi** : c'est *leur* Jenkins qui lance un
  binaire **approuvé**, sous *leur* change-control et *leur* audit (cf. la
  réponse « ai-je le droit de lancer la CLI ? » → idéalement non, c'est leur CI).

## Identité Vault des pipelines (voie A, ADR-078 §3)

Les 4 pipelines partagent **`ci/lib/vault-login.sh`** — une seule implémentation du
login, de la lecture KV et de la révocation. Ce que chacun fait :

| Pipeline | Déclenchement | Identité Vault |
|---|---|---|
| `Jenkinsfile.selfservice` | webhook (plan) + humain (apply) | **nominative** user/mot de passe (voie A) ou JWT (voie B) ; sans identité → PLAN-only vert |
| `Jenkinsfile.publish-api` | humain | idem |
| `Jenkinsfile.prod` | **humain uniquement** (aucun trigger) | nominative si `VAULT_USER` + mot de passe fournis, **repli AppRole** sinon (annoncé dans le log) |
| `Jenkinsfile.rollback` | **humain uniquement** | idem |
| `Jenkinsfile` (apply-uac) | webhook | AppRole — un build sans humain tourne en `ACL.SYSTEM`, il n'y a **personne** à nommer |

Deux périmètres de secrets, **disjoints et prouvés tels** (T30-T33) :
`deploy-<tenant>` pour les déployeurs applicatifs, `operator-deploy` (secrets de
plateforme : `stoa/ci`, `stoa/opensearch`, `stoa/gateways/*`) pour les opérateurs de
mise en prod. Deux groupes d'annuaire séparés.

Preuve : `./scripts/test-vault-user-login.sh` → **34/34**.

## Runbook — jobs prod & rollback en identité nominative (validé 2026-07-23)

Prérequis d'infra (une fois par lab) :

1. **governance-api sur l'hôte, port 8787** (le job rollback l'appelle en
   `host.docker.internal:8787`), sur un CLONE du repo governance avec
   `GOVERNANCE_GIT_PUSH_REMOTE=origin` : chaque commit gouverné (revert, markers,
   deny) est POUSSÉ fail-closed — sans quoi le stage re-apply re-clonerait un état
   où le revert n'existe pas.
2. **Token de push Gitea** : `docker exec -u git poc-gitea gitea admin user
   generate-access-token --username ci --token-name <nom> --scopes
   write:repository` ; le poser dans l'URL push du clone LOCAL uniquement
   (jamais commité).
3. **Rôle realm `devops` au service-account `ci-applier`** (perdu à chaque
   recreate Keycloak) — sinon le rollback répond 403 `promotions:approve`.
4. **Secret AppRole frais** avant chaque salve : `scripts/jenkins-refresh-vault-secret.sh`
   (TTL ~10 min).

⚠ **Fenêtre keepalive** : la gateway trial est recyclée toutes les ~20 min
(`restart-wm.sh`, cron `*/5`, `WM_MAX_MIN=20`). Un build qui chevauche le seuil
est coupé en plein vol (« unreachable ») — lancer les jobs longs juste après un
cycle (`docker inspect poc-webmethods-real` → StartedAt récent + healthy).

En cas de NPE « Unable to process the PUT/ACTIVATE request for apis » :
`scripts/repair-wm-dangling-policyaction.sh` (diagnostic puis `--fix`), puis
re-apply depuis Git — voir l'en-tête du script.
