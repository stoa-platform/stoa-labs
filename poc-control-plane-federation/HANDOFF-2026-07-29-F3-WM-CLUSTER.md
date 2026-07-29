# HANDOFF — Session 2026-07-29 (après-midi) : F3 fermé

_Dépôt `stoa-labs`, branche `feat/postman-bulk-owner-wm1015`. Session
`/goal F3`, exécution autonome (brainstorm → spec → plan → exécution),
merges `stoa` portés par l'exploitant._

## En une phrase

**webMethods 10.15 tourne dans le cluster** : ns `wm`, ES sur worker-4 (PVC),
gateway sans volume, images par digest depuis le registre Gitea, cycle trial
piloté par CronJob `*/20` — porte F3 et contre-épreuves vertes, worker-3
intact.

## Ce qui a été livré

| Objet | Où |
|---|---|
| Spec F3 (arbitrages D1–D7) | `docs/superpowers/specs/2026-07-29-f3-webmethods-cluster-design.md` |
| Plan F3 + **Preuve d'exécution** | `docs/superpowers/plans/2026-07-29-f3-webmethods-cluster.md` |
| Manifestes cluster | `stoa`:`deploy/bootstrap/wm/{elasticsearch,apigateway}/` + `deploy/bootstrap/argocd/app-wm-*.yaml` (PR #2821, #2822 — mergées) |
| Images (digests dans le plan) | registre Gitea `ci/apigateway-trial:10.15`, `ci/elasticsearch:8.13.4`, `ci/curl:8.10.1` |
| Dette realm OCI | requalifiée/bornée — clusterIP gitea épinglée en Git (PR #2821) |
| GOAL | F1 ✔ F2 ✔ **F3 ✔** — F4 (chaîne de publication) est le prochain jalon |

## La porte, en clair

`GET /rest/apigateway/health` → 200 depuis un pod du cluster (IS green, ES
connecté) ; application-marqueur `f3-proof-2026-07-29` créée, **les deux pods
supprimés simultanément**, retour autonome en ~3 min 30, marqueur **relu** —
le PVC ES porte la donnée. Aucun Ingress, ports fermés de l'extérieur (6/6),
`restart-pilote: 200` toutes les 20 min (3 jobs observés).

## Reste ouvert (décisions/gestes exploitant)

1. ~~PR #2823 (digests gitea+jenkins)~~ **mergée le 2026-07-29 en fin de
   session** — vérifié derrière : gitea-0 et jenkins roulés et Ready avec les
   digests épinglés en service, registre 401 (challenge normal), `vault-0`
   **non touché** (3 h 49 d'âge, Ready donc descellé), `ci-gitea` OutOfSync
   cosmétique connu. **Reste : Vault seul** — l'épingler en fenêtre
   exploitant, descellement dans la foulée.
2. **Doublon de crons worker-3** (mesuré) : root `*/20` restart inconditionnel
   **+** hegemon `*/25` keepalive conditionnel → aux minutes 20→25 le
   keepalive re-redémarre une gateway encore en `starting` (~5 min de service
   perdues/heure). Suggestion : supprimer le keepalive hegemon.
3. **Sauvegarde du ns `wm`** : `backup_pvc_namespaces` ne couvre que `ci` ;
   quiescement ES à instruire (risque `.suspect` à chaud). Dette actée spec F3.
4. Toujours pendant : récupération hors ligne des parts Vault + `shred`.

## Pour F4 (prochain jalon)

Toutes les briques sont en place : gateway cluster joignable en
`wm-apigateway.wm.svc:5555`, identité de pod → Vault prouvée (lot 1), webhook
F1, `labctl` dans `jenkins-go`. Re-pointer `envs/dev/targets*.yaml` vers le
Service cluster. NetworkPolicy ES à poser quand les clients réels seront
connus. F3 démarre **vide** : la migration des 109 Mo de worker-3 appartient à
la bascule (F5).

_Socle empirique : § « Preuve d'exécution » du plan F3 (sorties réelles
horodatées) ; PR stoa #2821/#2822 mergées, #2823 ouverte ; garde worker-3
jouée trois fois (healthy/200 en fin de session)._
