---
title: "GOAL — Du socle CI à la gateway en cluster : solder le lot 1, porter webMethods 10.15, brancher la chaîne de publication (lot 2)"
type: goal
status: "Cadré sur les preuves du lot 1 (G-a/G-b/G-c fermées le 2026-07-28). Deux décisions humaines préalables (licence wM, cible de sauvegarde). À valider avant spécification du lot 2."
date: 2026-07-28
visibility: private
lié: [GOAL-self-service-api-app-2026-07-09, adr-074-vault, adr-076-gitops-api-lifecycle-repo-per-project, adr-077-user-identity-to-vault-token-exchange]
note: "Reste dans stoa-labs (privé). Le GOAL parent (self-service) reste le nord ; celui-ci construit la plateforme qui l'exécutera."
---

# GOAL — Du socle CI à la gateway en cluster

**Origine.** Le lot 1 est livré et prouvé (2026-07-28) : Gitea, Vault et Jenkins tournent dans le namespace `ci`, et un pipeline obtient ses identifiants **par l'identité de son pod** — contre-épreuves comprises (SA étranger refusé 403 ; rôle révoqué → échec fermé). Mais le socle a trois trous actés par écrit (déclenchement par push non câblé, sauvegardes co-localisées avec les données sur worker-5, dette ROOT_URL/realm OCI), et la cible du GOAL parent — le self-service webMethods — exige la gateway **dans** le cluster, pas dans un Docker isolé sur worker-3.

**Ce GOAL ne modifie rien.** C'est le plan d'objectif de la suite. L'implémentation passera par la même méthode que le lot 1 : spécification → plan → exécution par sous-agents avec portes de preuve.

---

## Décision (test « archi 40 ans / 30 secondes »)

> La suite n'invente rien : on **ferme d'abord les trous du socle** (déclenchement, sauvegarde, licence), puis on **porte webMethods dans le cluster par la chaîne qu'on vient de prouver** — chaque manifeste par PR, chaque image par le registre Gitea, chaque identifiant par Vault. **Le lot 2 est le premier client réel du lot 1** : si on pose la gateway à la main à côté du socle, on aura construit un CI pour rien.

**Test :** *un push dans Gitea suffit-il à publier une API sur une gateway webMethods qui tourne dans le cluster, avec des identifiants obtenus par l'identité du pod, et un statut de commit rouge quand ça échoue ?* Si oui, le lot 2 est réel et les jalons E1–E6 du GOAL parent ont leur plateforme.

---

## Préalable bloquant — la licence webMethods

Constat de terrain (lot 1, élucidé pendant la tâche 4) : la **licence d'essai de `wm-dev-apigateway` sur worker-3 est expirée** — le conteneur s'auto-redémarre proprement en boucle (~30 min), avec brèves 502 publiques. **Porter une licence morte en cluster, c'est porter la panne.** Aucun jalon F3+ ne démarre sans avoir tranché : licence client réelle, nouvelle trial, ou build non-trial. Décision humaine, hors de portée d'un agent.

---

## Jalons (F1…F5) — chacun avec sa porte de preuve et sa contre-épreuve

### F1 — Déclenchement par push + statut de commit *(solde le critère du lot 1)*

Câbler le webhook Gitea → Jenkins (`generic-webhook-trigger`, déjà dans l'image ; `ALLOWED_HOST_LIST` déjà restreint au Service Jenkins) et la remontée du statut de commit dans Gitea.
**Porte F1 :** un `git push` sur `ci/probe` déclenche le build **sans action humaine** ; le commit porte un statut vert dans Gitea.
**Contre-épreuve :** casser le Jenkinsfile → le commit porte un statut **rouge**. Un statut qui ne rougit jamais ne prouve rien.
**État : FERMÉ le 2026-07-29.** Porte et contre-épreuve vertes — builds 7 (vert), 8 (rouge, sabotage) et 9 (vert, restauration) déclenchés sans action humaine, statuts `jenkins/probe` correspondants dans Gitea. Preuve détaillée : `docs/superpowers/plans/2026-07-28-f1-webhook-statut.md`, § « Preuve d'exécution ». Écart à traiter : le matériel de descellement Vault a été perdu puis exposé en session (cf. § « Incident Vault »).

### F2 — Sauvegarde réellement hors-nœud *(tranche la question Q2 du lot 1)*

Aujourd'hui les trois PVC (gitea, vault, jenkins) **et** leurs archives vivent sur worker-5 : une panne disque y perd données et copies. Candidat naturel : **worker-2** — exclu du cluster par l'isolation L2 Contabo (w1↔w2), mais joignable depuis worker-4/worker-5 (matrice mesurée du 2026-07-27), déjà identifié comme « disponible pour toute charge n'exigeant pas l'appartenance au cluster ». À vérifier avant d'industrialiser : joignabilité SSH w5→w2 et espace disque. En même temps : rotation des `pvc-*.tar.gz`, quarantaine `.suspect` des archives dont la garde post-archive a rougi, et fenêtre de synchronisation Argo (auto-sync suspendu pendant la sauvegarde — le contournement actuel est une garde, pas une solution).
**Porte F2 :** archives des trois PVC lisibles sur l'hôte cible, **distinct du nœud porteur des données**.
**Contre-épreuve :** exercice de restauration depuis cet hôte (l'utilisateur `ci` retrouvé dans le `gitea.db` restauré, comme au lot 1).
**État :** décision humaine sur la cible, puis extension du rôle existant — la mécanique (flux, read-back, asserts) est prouvée.

### F3 — webMethods 10.15 dans le cluster *(le cœur du lot 2)*

Image poussée dans le **registre Gitea** (pas Docker Hub), manifestes par **PR sur `stoa`**, namespace dédié, Elasticsearch attenant. Contraintes mesurées à respecter : disque faible en `fsync` (prudence sur ES — c'est lui le composant sensible, pas la RAM : ~87 Go libres) ; **anti-affinité worker-3** tant que la prod Docker y tourne (le motif PR #2819 du lot 1, réutilisé) ; la dette ROOT_URL/realm OCI du lot 1 se repense **ici** (un ROOT_URL résoluble partout, sans casser les accès registre depuis les pods).
**Porte F3 :** `/rest/apigateway` répond depuis un pod du cluster ; les données survivent à la suppression du pod (PVC).
**Contre-épreuve :** pod tué en pleine vie → revient seul, config intacte. Et l'admin REST reste **inaccessible** hors du cluster (aucun Ingress — la doctrine du lot 1 tient).
**État :** bloqué par la licence (préalable). La spécification lot 2 détaillera image, licence, dimensionnement ES.

### F4 — La chaîne de publication réelle *(E1 du GOAL parent, câblé sur la plateforme)*

Un pipeline Jenkins (image `jenkins-go`, `labctl` embarqué) publie une API sur la gateway cluster : spec OpenAPI poussée dans un repo Gitea d'équipe → build déclenché (F1) → identifiants wM obtenus **depuis Vault par identité de pod** (mécanique G-c, prouvée) → `POST /apis` + `POST /assets/team`.
**Porte F4 :** push d'une spec → API visible, scopée à sa team, **zéro secret statique** dans Jenkins (l'assertion `credentials.xml` absent du lot 1, rejouée).
**Contre-épreuve :** rôle Vault révoqué → la publication échoue **fermée**, statut rouge dans Gitea (F1) ; et le membre d'une autre team ne voit pas l'API (l'isolation Teams prouvée au spike #1).
**État :** toutes les briques existent séparément ; ce jalon est leur premier assemblage bout en bout.

### F5 — Bascule et décommission

Caddy (worker-3) repointe le trafic concerné vers le cluster (le pattern `cutover.yml` : une ligne de Caddyfile, pas de DNS) ; les conteneurs Docker `wm-dev-*` de worker-3 s'éteignent après période de recouvrement.
**Porte F5 :** le trafic public est servi par la gateway cluster ; worker-3 ne porte plus que Caddy.
**Contre-épreuve :** rollback = une ligne de Caddyfile, exercé une fois avant la décommission définitive.
**État :** à cadrer en dernier ; ne démarre qu'avec F3+F4 verts et stables.

---

## Dette du lot 1 à solder en route

| Dette | Où actée | Jalon porteur |
|---|---|---|
| Realm OCI /etc/hosts→ClusterIP (ROOT_URL) | plan lot 1, § Dette actée | F3 |
| Sauvegardes co-localisées worker-5 + rotation + quarantaine | plan lot 1 + revue finale | F2 |
| ~~Webhook + statut de commit~~ | plan lot 1, écart assumé | **soldé — F1, 2026-07-29** |
| Rotation du matériel de descellement Vault (`operator rekey` + révocation du jeton racine) | incident F1 du 2026-07-29 | à trancher avec F2 (sauvegarde/restauration) |
| Épinglage par digest des 3 images du socle | revue finale, follow-up | F3 (même passe) |
| Rotation du mot de passe bootstrap `ci`/`ci-bootstrap` | rapports lot 1 | F4 (les identités réelles arrivent) |
| JCasC (cloud + jobs Jenkins versionnés) | plan lot 1, écart assumé | F4 (dès le 2ᵉ job, le seuil est franchi) |
| Intégration Keycloak / échange JWT (ADR-077) | spéc lot 1, exclusions | après F4 |
| Rétention des builds Jenkins | question ouverte Q1 | F4 |

---

## Risques & limites (assumés)

- **Licence wM** : bloquant absolu de F3+. Gravité haute × certaine tant que non tranchée.
- **Elasticsearch sur disque faible en fsync** : le composant le plus exposé du lot 2 ; mesurer avant de dimensionner, comme au lot 1 (la mesure a déjà écarté Longhorn et etcd).
- **Double-run wM** (Docker worker-3 + cluster) pendant F3–F5 : coût RAM/disque temporaire, et deux sources de vérité le temps de la bascule — fenêtre à garder courte.
- **worker-2 comme cible de sauvegarde** : joignabilité w5→w2 supposée d'après la matrice (w2↔w4 mesuré OK), **à vérifier avant d'écrire une ligne** — c'est exactement le genre d'hypothèse que le lot 1 a appris à tester d'abord (cf. `hostPath` vs `local`).
- **selfHeal vs opérations out-of-band** : la garde post-archive du lot 1 détecte la course, elle ne la supprime pas ; la fenêtre de synchronisation (F2) est la vraie réponse.

---

## Ce qui est déjà prouvé vs à faire

| | Prouvé (lot 1) | À faire |
|---|---|---|
| F1 | Plugin présent, allowlist posée, pipeline vert | Câbler webhook + statut de commit |
| F2 | Mécanique complète (flux, read-back, restauration exercée) | Cible hors-nœud réelle + rotation + quarantaine + sync-window |
| F3 | Chaîne image→registre→pull tous nœuds ; anti-affinité w3 ; doctrine no-Ingress | Licence, image wM, manifestes, ES |
| F4 | Identité de pod → Vault (G-b/G-c) ; isolation Teams (spike #1) ; labctl dans l'image | L'assemblage bout en bout |
| F5 | Pattern cutover une-ligne (existant) | L'exercer sur wM |

**Chemin critique = la licence webMethods**, puis F2 (une sauvegarde qui ne survit pas au nœud ne protège rien — leçon fondatrice du dépôt).

---

## Prochaine action proposée (hors de ce GOAL)

Deux décisions humaines d'abord : **licence wM** (F3) et **cible de sauvegarde** (F2 — vérification w5→w2 comprise, 10 min). Sur validation : brainstorm → spécification lot 2 → plan d'implémentation, même méthode que le lot 1 (sous-agents, portes de preuve, contre-épreuves de sabotage).

*Socle empirique : exécution du lot 1 (2026-07-28, portes G-a/G-b/G-c et leurs contre-épreuves, revue finale de branche), spikes live du 2026-07-09 ([[wm-1015-teams-scoping]], [[wm-1015-rest-shapes]]), matrice de joignabilité du 2026-07-27 (inventaire Ansible).*
