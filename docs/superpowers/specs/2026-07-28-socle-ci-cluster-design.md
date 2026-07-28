# Spécification — Socle CI sur le cluster k3s labs (lot 1)

**Date :** 2026-07-28
**Statut :** cadré, validé, prêt pour le plan d'implémentation
**Lot :** 1 sur 2 — le lot 2 (portage de webMethods 10.15 en cluster) fera l'objet
d'une spécification distincte.

---

## 1. Objectif

Déployer sur le cluster k3s labs la chaîne qui **construit** : Gitea, Vault,
Jenkins. Une fois debout, le reste du POC se déploie *par* cette chaîne au lieu
d'être posé à la main.

### Critère de succès

Repris tel quel de `poc-control-plane-federation/GOAL-self-service-api-app-2026-07-09.md`,
restreint à ce que le lot 1 peut prouver seul :

> Un pipeline Jenkins, déclenché par un push dans Gitea, obtient ses
> identifiants auprès de Vault **par l'identité de son pod** — sans qu'aucun
> secret statique n'existe dans la configuration Jenkins.

Le critère complet du GOAL (« une équipe publie une API de bout en bout par
REST, sans opérateur plateforme, sans voir les assets d'une autre équipe »)
exige la gateway du lot 2. Le lot 1 en construit la moitié amont.

---

## 2. Périmètre

### Inclus

| Composant | Rôle | Origine |
|---|---|---|
| **Gitea 1.22** | dépôts projet (ADR-076, repo-par-projet) + registre d'images | `docker-compose.ci.yml` |
| **Vault** | secrets + méthode d'auth Kubernetes | remplace le Vault dev du POC |
| **Jenkins** | pipelines, image `jenkins-go` construite | `ci/jenkins/Dockerfile` |
| Sauvegarde des PVC | extension du rôle `cluster_backup` | nouveau, cf. §7 |
| Alerte `VaultSealed` | rend visible l'échec fermé | nouveau |

### Exclus, explicitement

- **webMethods 10.15 en cluster** → lot 2.
- **La publication self-service réelle** → exige la gateway du lot 2.
- **Intégration Keycloak / échange de jeton JWT** (ADR-077) → Keycloak existe et
  tourne (`auth.gostoa.dev`), son intégration vient après.
- **Toute exposition publique** → cf. §4.1.
- **Migration du GitOps plateforme vers Gitea** → Argo CD continue de lire
  GitHub. Gitea n'héberge que les dépôts *projet*. Deux rôles disjoints, aucun
  problème d'amorçage.

---

## 3. Contraintes d'entrée (mesurées, non négociables)

- Cluster 4 nœuds : worker-1 (plan de contrôle), worker-3, worker-4, worker-5.
  **worker-2 est exclu** — Contabo isole les VPS d'un même segment L2.
- Disque contraint en `fsync` (p99 ≈ 10 ms à vide) → **Longhorn écarté**,
  stockage `local-path`.
- ~87 Go de RAM libres sur 96 — la RAM n'est pas la contrainte, le disque l'est.
- **Aucun Vault joignable** : `vault.gostoa.dev` (Infisical mort) et
  `hcvault.gostoa.dev` (OVH, ports filtrés) sont tous deux hors service. ADR-074
  est aujourd'hui une intention, pas un fait.
- Le jeton d'API Cloudflare est enfermé dans l'Infisical mort → **aucun nouvel
  enregistrement DNS n'est possible** tant que l'impasse n'est pas levée.
- L'image Jenkins n'existe dans aucun registre : elle doit être **construite**
  (contexte = racine du POC, pour compiler `labctl/`).

---

## 4. Architecture

Namespace `ci`. Trois Applications Argo CD, ajoutées aux `destinations` de
l'AppProject `stoa`, déployées dans l'ordre de dépendance.

```
                    ┌─────────────── namespace ci ───────────────┐
                    │                                            │
   dev ──push──▶ Gitea (StatefulSet + PVC)                       │
                    │   dépôts projet + registre d'images        │
                    │        │                                   │
                    │        └── webhook INTERNE ──▶ Jenkins     │
                    │                                (Deployment)│
                    │                                    │       │
                    │                          pod agent éphémère│
                    │                          SA: jenkins-agent │
                    │                                    │       │
                    │                    auth/kubernetes/login   │
                    │                                    ▼       │
                    │                        Vault (StatefulSet) │
                    │                        + PVC, auth k8s     │
                    └────────────────────────────────────────────┘
                                             │
                                   (lot 2) ──┴──▶ admin REST webMethods
```

### 4.1 Aucune exposition publique — décision motivée

Ni Gitea, ni Jenkins, ni Vault ne reçoivent d'Ingress. Accès par
`kubectl port-forward` ou tunnel SSH.

1. **Sécurité.** Exposer un Jenkins et un Vault sur l'Internet ouvert
   reproduirait exactement le défaut n8n que le rapport dénonce.
2. **Inutilité.** Le webhook Gitea → Jenkins est interne au cluster. Le compose
   d'origine le dit lui-même : « modèle GitOps pull, zéro flux entrant depuis
   l'extérieur ».
3. **Déblocage.** Exposer exigerait de nouveaux enregistrements DNS, donc le
   jeton Cloudflare indisponible. On contourne l'impasse au lieu de l'attendre.

### 4.2 Stockage `local-path` — conséquence assumée

Les pods avec état sont **épinglés à leur nœud**. Perdre ce nœud, c'est perdre
le service jusqu'à restauration. Acceptable pour un lab **à condition que la
sauvegarde couvre les PVC** (§7) — ce qui n'est pas le cas aujourd'hui.

---

## 5. Composants

### 5.1 Gitea

- Image `gitea/gitea:1.22`, épinglée.
- `GITEA__server__HTTP_PORT=3000`, `GITEA__security__INSTALL_LOCK=true`.
- `GITEA__server__ROOT_URL` : à repointer sur le Service interne
  (`http://gitea.ci.svc:3000/`) — la valeur du compose (`localhost:13000`) est
  spécifique à Docker et casserait les URL de clone.
- `GITEA__webhook__ALLOWED_HOST_LIST` : restreint au Service Jenkins, **pas**
  `*` comme dans le compose. Le `*` était acceptable sur un réseau Docker isolé,
  il ne l'est pas dans un cluster.
- PVC `/data`, `local-path`.
- Registre d'images intégré activé : Gitea sert les dépôts **et** les images,
  ce qui évite un composant de plus.

### 5.2 Vault

- Persistant, backend de stockage `file` sur PVC — **pas** le mode dev du POC
  (root token en dur, stockage en mémoire, tout perdu au redémarrage).
- Méthode d'auth **Kubernetes** activée, avec un rôle `jenkins-agent` lié au
  ServiceAccount du même nom, dans le namespace `ci` uniquement.
- **Les clés de descellement sont un nouveau « secret zéro ».** Elles ne peuvent
  pas vivre dans Vault. Elles sont remises à l'exploitant, hors ligne, et ne
  figurent dans aucun dépôt.
- Licence **BUSL-1.1** — source-available, non-OSI. Sans effet en usage interne ;
  à mentionner si le discours « pile 100 % open source » est tenu publiquement.

### 5.3 Jenkins

- Image **construite** depuis `ci/jenkins/Dockerfile` : base
  `jenkins/jenkins:lts-jdk17`, compile `labctl/`, installe 4 plugins
  (`git`, `workflow-aggregator`, `generic-webhook-trigger`,
  `pipeline-stage-view`).
- **Amorçage de la construction** : bâtie sur worker-3 (seul nœud avec Docker),
  poussée vers le registre Gitea. Ensuite, Jenkins construit son propre
  successeur.
- `JAVA_OPTS=-Djenkins.install.runSetupWizard=false` conservé, mais la
  configuration doit être versionnée (JCasC) plutôt que cliquée — le compose
  l'annonçait déjà : « en prod : JCasC et comptes maîtrisés ».
- PVC `/var/jenkins_home`, `local-path`.
- Agents en **pods éphémères** portant le SA `jenkins-agent` : c'est ce qui donne
  au job une identité vérifiable par Vault.

---

## 6. Gestion d'erreur

- Applications Argo : `retry` avec backoff, `selfHeal`, `allowEmpty: false` —
  posture déjà en vigueur sur le cluster.
- **Vault scellé après redémarrage fait échouer les pipelines, et c'est le
  comportement correct.** Un CI qui poursuit sans pouvoir s'authentifier serait
  pire qu'un CI arrêté. Mais l'échec doit être **visible** → alerte
  `VaultSealed`, absente de la pile actuelle.
- Les 5 alertes déjà déployées couvrent le niveau pod. **`PVC plein` est ici le
  mode de saturation le plus probable** : dépôts Gitea et historique de builds
  Jenkins croissent sans limite naturelle.
- Échec de pipeline → statut de commit rouge dans Gitea + build rouge Jenkins.

---

## 7. Lacune connue à combler dans ce lot

`cluster_backup` sauvegarde le datastore k3s — **pas les PVC**. Les données
Gitea, Vault et Jenkins vivent dans des PVC `local-path`, c'est-à-dire des
répertoires sur un nœud. En l'état, **elles ne sont pas sauvegardées**.

Ne pas corriger cela reproduirait, un cran plus loin, l'erreur du secret qui
n'existait qu'à un seul endroit — celle qui a failli coûter trois identifiants
lors de la mise au rebut de l'ancien cluster.

Le rôle doit donc être étendu aux PVC du namespace `ci`, avec la même discipline :
copie consistante, relecture, copie hors-nœud, et **restauration réellement
testée**.

---

## 8. Portes de preuve

Chacune avec sa contre-épreuve de sabotage. Une porte qui ne rougit jamais ne
prouve rien.

### G-a — Gitea

**Prouvé :** les dépôts vivent et survivent.
**Commande :** `git push` depuis un worker ; dépôt listé via l'API Gitea.
**Contre-épreuve :** restaurer depuis la sauvegarde PVC et retrouver le dépôt.
Sans elle, on n'a prouvé que « Gitea démarre ».

### G-b — Auth Kubernetes de Vault  *(ferme le jalon G8 du rapport)*

**Prouvé :** Vault distingue les identités de pod.
**Commande :** depuis un pod portant le SA `jenkins-agent` —
`vault write auth/kubernetes/login role=jenkins-agent jwt=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)`
→ jeton obtenu, TTL court.
**Contre-épreuve, la seule qui compte :** le même appel depuis un pod d'un
**autre** ServiceAccount, ou d'un autre namespace, doit être **refusé**. Sans
elle, on a prouvé que Vault répond — pas qu'il distingue.

### G-c — Jenkins de bout en bout

**Prouvé :** aucun secret statique dans la chaîne.
**Commande :** un pipeline tire depuis Gitea, s'authentifie à Vault par auth k8s,
lit un secret. Assertion : aucun identifiant statique dans la configuration
Jenkins.
**Contre-épreuve :** révoquer le rôle Vault → le pipeline doit échouer **fermé**,
sans repli sur un secret en cache.

---

## 9. Risques

| Risque | Gravité × probabilité | Parade |
|---|---|---|
| PVC non sauvegardés → perte de données | **Élevée × certaine si non traité** | §7, dans ce lot |
| Clés de descellement perdues → Vault irrécupérable | Élevée × moyenne | remise hors ligne à l'exploitant, documentée |
| PVC saturé (Gitea/Jenkins) | Moyenne × élevée | alerte déjà déployée ; définir une rétention de builds |
| Nœud perdu → service épinglé indisponible | Moyenne × faible | assumé (`local-path`) ; RTO = restauration PVC |
| Image Jenkins non reproductible | Moyenne × moyenne | construction versionnée, image épinglée par digest |

---

## 10. Questions ouvertes

1. **Rétention des builds Jenkins** — non fixée. À trancher avant que le PVC ne
   sature, pas après.
2. **Sauvegarde des PVC : où ?** Le rôle actuel copie vers worker-5. Les PVC sont
   plus volumineux que le datastore ; vérifier l'espace avant d'industrialiser.
3. **Automatisation de la sauvegarde** — toujours non tranchée (cf. PR #5) : un
   timer local ne protège pas de la perte du nœud, et l'automatiser exige soit
   une confiance SSH entre workers, soit un ordonnanceur externe.
