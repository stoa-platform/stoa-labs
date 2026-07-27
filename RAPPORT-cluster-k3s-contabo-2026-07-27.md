# RAPPORT — Reprise en main du cluster k3s Contabo & labs à la demande

**Date :** 2026-07-27 · **Répond à :** `RESEARCH-cluster-k3s-contabo-2026-07-27.md` (prompt v2)
**Base de preuves :** 6 angles de recherche, 32 sources primaires, 160 affirmations extraites,
25 vérifiées en 3 votes adverses → **7 confirmées, 18 réfutées** ; complétées par une analyse
directe du dépôt `stoa-platform/stoa`.

## Convention de preuve (lire avant tout)

Chaque affirmation porte son niveau de preuve. C'est la partie la plus importante de ce rapport :
la recherche web **n'a rien produit de vérifiable sur 4 des 6 axes**, et le dire est plus utile
que de combler avec des citations plausibles.

| Marque | Signification |
|---|---|
| `[DOC]` | Documentation éditeur primaire, vérifiée en 3 votes adverses, URL + date |
| `[REPO]` | Vérifié par lecture directe du dépôt local — `fichier:ligne` |
| `[INFÉR]` | Raisonnement à partir des mesures fournies. Falsifiable, **non sourcé** |
| `[VIDE]` | La recherche n'a rien produit qui survive. Aucune conclusion n'est tirée |

**Avertissement de couverture.** Les axes 3 (labs éphémères), 4 (alerting), 5 (n8n) et 6
(agents IA) sont sortis `[VIDE]` de la vérification adverse. Pour les axes 4 et 6, l'analyse du
dépôt a fourni une preuve **interne** plus forte que ne l'aurait été une source web. Pour les
axes 3 et 5, il n'y a ni source ni preuve interne : ils sont traités en `[INFÉR]` explicite, avec
le test qui les tranche. Aucune hypothèse n'est marquée PROUVÉE sur du vide.

---

## 0. Corrections apportées par la reconstruction (même jour, après build)

Un cluster a été effectivement reconstruit depuis Git sur les nœuds vides le
2026-07-27, après rédaction des sections ci-dessous. **La construction a réfuté
quatre affirmations de ce rapport.** Elles sont corrigées ici plutôt que
réécrites en silence dans le corps du texte.

**C1 — La flotte plafonne à 4 nœuds, pas 5. `[MESURÉ]`**
`worker-1` et `worker-2` **ne peuvent pas
communiquer**, dans aucun sens, sur aucun port — y compris le 22, que `ufw`
autorise pourtant explicitement « from Anywhere » sur les deux machines. Toutes
les paires inter-sous-réseaux fonctionnent. Ces deux machines sont les seules de
la flotte à partager un `/18` : Contabo isole les VPS clients d'un même segment
L2, et aucun réglage invité n'y remédie. Flannel exigeant une connectivité de
paire à paire, **worker-1 et worker-2 ne peuvent pas appartenir au même
cluster**. L'architecture cible de la section 4 doit se lire à 4 nœuds : un seul
de {worker-1, worker-2}, plus worker-3, worker-4, worker-5.

**C2 — La « dérive » du cluster précédent n'en était pas une. `[MESURÉ]`**
Ce rapport impute au laisser-aller l'écart entre un `setup.sh` visant « w1 + w2 »
et une réalité « w5 + w3 ». C'est faux : au vu de C1, **la topologie « w1 + w2 »
n'a jamais pu fonctionner**. La réalité observée n'est pas une dérive, c'est la
seule configuration réalisable. Le script est faux ; l'exploitation ne l'était
pas. La conclusion pratique reste identique (corriger `setup.sh`), la
qualification change — et elle change ce qu'on doit en conclure sur la rigueur
de l'exploitant.

**C3 — « Rebuild-from-Git intégral » est aujourd'hui FAUX. `[MESURÉ]`**
`charts/stoa-platform/crds/gatewayinstances.gostoa.dev.yaml` est **inapplicable** :
`spec.endpoints` porte à la fois `properties` et `additionalProperties`, refusé
par l'API. Le cluster en service tourne avec une CRD *permissive* posée à la
main le 2026-05-02. Git ne décrivait donc pas l'état réel, et personne ne
pouvait le savoir puisque rien n'avait jamais tenté d'appliquer ce fichier.
Correctif ouvert en PR (`fix/gatewayinstances-crd-schema`), validé par dry-run
serveur. **Tant qu'il n'est pas fusionné, les overlays dev/staging ne peuvent
pas être synchronisés.**

**C4 — Un overlay `production` existe. `[REPO]`**
Le corps du rapport affirme que seuls `dev` et `staging` ont un overlay. C'est
vrai de la copie locale, qui était **320 commits en retard** sur `origin/main`.
Sur la branche réelle il existe aussi `k8s/gateways/overlays/production`, et les
trois overlays créent des `GatewayInstance`. En revanche, les constats centraux
ont été re-vérifiés sur `origin/main` et **tiennent tous** : aucun overlay `rec`,
`setup.sh` crée toujours `gateway-rec`, le sélecteur et le seuil de
`PodCrashLooping` sont inchangés, Kyverno est toujours en `Audit`, le hook
autorise toujours `docker`, et le jalon G8 part bien de zéro code.

**Ce que cet épisode démontre, et qui vaut plus que les quatre corrections :**
reconstruire depuis Git n'est pas seulement une stratégie de déploiement, c'est
le **test** de l'affirmation « Git est la source de vérité ». Ce test a échoué en
deux endroits (C1 dans l'inventaire, C3 dans les CRD), et **aucune adoption
in-place ne les aurait révélés** — un cluster déjà debout ne vérifie jamais que
Git sait le reconstruire. Cela renforce la branche « reconstruire » de H1, non
pour des raisons de risque, mais pour des raisons de *diagnostic*.

---

## 1. Verdict en une phrase

**Adopter là où Git fait déjà foi (`gateway-dev`, `gateway-staging`), mettre au rebut ce que Git
n'a jamais décrit (`gateway-rec`), et reconstruire le plan de contrôle sur un nœud vide — la
condition qui tranche l'adoption est le nombre de conflits remontés par
`kubectl apply --server-side --dry-run=server` sur les deux namespaces sains, mesurable en moins
d'une heure : sous ~10 conflits triviaux on adopte, au-delà on reconstruit.**

La question « adopter OU reconstruire » est mal posée : le cluster se sépare proprement en deux.
Deux namespaces **ont** leur overlay Kustomize en Git `[REPO: k8s/gateways/overlays/{dev,staging}]`
→ adoptables. Un namespace n'existe nulle part en Git, ni en overlay ni en base
`[REPO: k8s/gateways/base/ = echo/, stoa-link-wm/, stoa-gateway/]` → rien à adopter, il n'y a pas
de source de vérité à réconcilier. On n'arbitre donc pas une stratégie globale, on applique la
bonne à chaque moitié.

## 2. Décision d'architecture (test 30 secondes)

1. **Plan de contrôle unique k3s + kine/SQLite, déplacé sur un nœud vide** (worker-1, meilleur
   disque mesuré) : l'etcd HA est écarté par la mesure, et le plan de contrôle actuel est posé
   sur la machine au disque le plus lent de la flotte — c'est l'inverse de ce qu'il faut.
2. **Argo CD ≥ 3.3.2 comme réconciliateur unique**, propriété par annotation de suivi,
   `ServerSideApply=true` **sans** `Force`, `Prune=false` en phase 1, et porte de preuve assise
   sur `argocd app diff` — **jamais** sur le statut `Synced`, qui reste `OutOfSync` par
   construction avec `Prune=false` `[DOC]`.
3. **`gateway-rec` est supprimé et `setup.sh` corrigé dans le même commit** : le namespace
   orphelin est **codé**, pas accidentel `[REPO: deploy/k3s-gateways/setup.sh:42]`. Le supprimer
   sans corriger le script le fait revenir au prochain run.
4. **Labs éphémères en namespace + ResourceQuota + NetworkPolicy d'abord** ; vcluster seulement
   si l'isolation des CRD devient bloquante — chaque vcluster ajoute **son propre datastore** sur
   le disque qui est déjà la contrainte `[INFÉR]`.
5. **n8n perd tout accès au cluster** (aucun kubeconfig, jamais) et repasse derrière Cloudflare
   Access ; **les agents perdent l'auto-approbation actuelle**, qui est contournable par
   chaînage trivial et qui ne se protège pas elle-même `[REPO]`.

---

## 3. Tableau de recommandation classée

Coûts en jours-homme pour un mono-mainteneur. « Réversibilité » = facilité de retrait si la
brique déçoit.

| # | Brique / approche | Rôle | Verdict | Licence | Mise en place | Maint. 18 mois | Réversibilité |
|---|---|---|---|---|---|---|---|
| 1 | **Argo CD ≥ 3.3.2** | Réconciliateur GitOps unique | **ADOPTER** — outillage d'adoption vérifié `[DOC]` | Apache-2.0 | 1–2 j | Faible (bump mineur) | **Haute** — `kubectl delete ns argocd` laisse les charges en place |
| 2 | **Correctif alerting existant** | Voir la dette avant qu'elle s'installe | **ADOPTER — priorité absolue** | Apache-2.0 | 0,5 j | Très faible | Haute |
| 3 | **k3s mono-CP + kine/SQLite** | Plan de contrôle | **ADOPTER par défaut**, plafond non établi `[VIDE]` | Apache-2.0 | 0,5 j | Faible | Moyenne (repli kine+Postgres) |
| 4 | **Suppression `gateway-rec` + fix `setup.sh`** | Purge de dette | **SUPPRIMER** | — | 0,5 j | Nulle | N/A |
| 5 | **Kyverno en `Enforce`** | Admission : labels, digests, TTL | **ADOPTER** — déjà en Git, en `Audit` `[REPO]` | Apache-2.0 | 1 j | Faible | Haute |
| 6 | **External Secrets Operator + Vault** | Fin des secrets créés à la main | **ADOPTER** | Apache-2.0 (ESO) / **BUSL-1.1** (Vault) | 1–2 j | Moyenne | Moyenne |
| 7 | **local-path (défaut k3s)** | Stockage des labs | **ADOPTER** — données de lab jetables | Apache-2.0 | 0 j | Nulle | Haute |
| 8 | **Namespace + Quota + NetworkPolicy** | Isolation des labs | **ADOPTER d'abord** | — | 1 j | Faible | Haute |
| 9 | **Cloudflare Access devant n8n** | Fermer l'exposition directe | **ADOPTER** | SaaS | 0,5 j | Nulle | Haute |
| 10 | **Refonte du hook d'auto-approbation** | Reprise en main des agents | **REFAIRE** — contourné `[REPO]` | Apache-2.0 | 2 j | Moyenne | Haute |
| 11 | **vcluster** | Isolation forte par lab | **DIFFÉRER** — coût fsync multiplié `[INFÉR]` | Apache-2.0 (cœur) | 2 j | Moyenne | Moyenne |
| 12 | **kine + Postgres externe** | Repli si SQLite plafonne | **PROVISIONNER, ne pas poser** | Apache-2.0 | 2 j | Moyenne | Faible (migration de données) |
| 13 | **Longhorn** | Stockage bloc répliqué | **REJETER** `[INFÉR]` — 3 pénalités cumulées | Apache-2.0 | — | — | — |
| 14 | **etcd embarqué en HA** | Plan de contrôle HA | **REJETÉ** (mesure, acquis) | Apache-2.0 | — | — | — |
| 15 | **n8n pour l'administration du cluster** | Orchestration d'ops | **REJETER** | **Sustainable Use** (non-OSI) | — | — | — |

**Deux licences à confirmer avant publication** (test : lire le `LICENSE` amont, 2 min chacune) —
elles sont matérielles pour un discours « OSS souverain » dans un dépôt Apache-2.0 :
**HashiCorp Vault** est passé en **BUSL-1.1** (source-available, pas open source au sens OSI) ;
**n8n** est sous **Sustainable Use License**, également source-available. Aucune des deux n'est
un problème d'*usage interne* — les deux en sont un pour un discours « pile 100 % open source ».
Rien dans l'architecture proposée ne redistribue ces composants, donc la contrainte reste
déclarative, pas juridique. `[INFÉR — non couvert par la recherche]`

---

## 4. Architecture cible et frontières de confiance

```
                          INTERNET
                              │
                    ┌─────────┴──────────┐
                    │  Cloudflare (proxy │  ← n8n DOIT repasser derrière (aujourd'hui : NON,
                    │  + Access, mTLS)   │     certificat émis pour l'origine = proxy désactivé)
                    └─────────┬──────────┘
                              │ 443 uniquement
                    ┌─────────┴──────────┐
                    │  Caddy (worker-5)  │  terminaison TLS
                    └─────────┬──────────┘
                              │
   ═══════════════════════════╪═══════════ FRONTIÈRE : plan de données ═════════════
                              │
  ┌───────────────────────────┴───────────────────────────────────────────────────┐
  │  CLUSTER k3s — 1 control-plane + 4 agents, réseau chiffré nœud-à-nœud          │
  │                                                                               │
  │  worker-1 [CP]      worker-2        worker-3        worker-4      worker-5     │
  │  kine/SQLite        agent           agent           agent         agent        │
  │  meilleur disque                    + wM 10.15                                 │
  │  mesuré                             en Docker                                  │
  │                                     (HORS cluster,                             │
  │                                      inchangé)                                 │
  │                                                                               │
  │  ┌─────────────────────────────────────────────────────────────────────────┐  │
  │  │ Argo CD  ─── SEUL mutateur du cluster ───────────────────────────────►  │  │
  │  │   source : Gitea (Git = vérité)      AppProject dédié, pas `default`    │  │
  │  │   Prune=false en phase 1 · ServerSideApply sans Force                   │  │
  │  └─────────────────────────────────────────────────────────────────────────┘  │
  │                              │                                                │
  │        ┌─────────────────────┼─────────────────────┐                          │
  │   gateway-dev          gateway-staging        labs éphémères                  │
  │   (overlay en Git)     (overlay en Git)       ns + Quota + NetPol             │
  │                                                TTL + kube-green               │
  │                                                                               │
  │   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                        │
  │   │ Kyverno      │  │ Prometheus + │  │ ESO ◄── Vault│                        │
  │   │ ENFORCE      │  │ Alertmanager │  │ (BUSL-1.1)   │                        │
  │   │ (auj: Audit) │  │ + KSM        │  │              │                        │
  │   └──────────────┘  └──────────────┘  └──────────────┘                        │
  └───────────────────────────────────────────────────────────────────────────────┘
        ▲                          ▲                              ▲
        │ écrit des manifestes     │ lit des métriques            │ NE PEUT PAS
        │ VIA PR — jamais kubectl  │ NE MUTE RIEN                 │ MUTER LE CLUSTER
        │                          │                              │
  ┌─────┴────────┐        ┌────────┴───────┐            ┌─────────┴─────────┐
  │ Agents IA    │        │ Healthchecks   │            │ n8n               │
  │ (HEGEMON)    │        │ (dead-man)     │            │ hôte NON GÉRÉ     │
  │ SA dédié     │        └────────────────┘            │ AUCUN kubeconfig  │
  │ RBAC lecture │                                      │ notifs sortantes  │
  │ seule        │                                      │ + appels webhook  │
  └──────────────┘                                      └───────────────────┘
```

### Qui détient quel secret

| Acteur | Détient | Ne doit JAMAIS détenir |
|---|---|---|
| **Vault** | Racine de confiance. Tous les secrets applicatifs | — |
| **ESO (in-cluster)** | Un jeton Vault à périmètre étroit, renouvelé | Le jeton racine Vault |
| **Argo CD** | Deploy-key Gitea en **lecture seule** | Des secrets applicatifs (ils viennent d'ESO) |
| **Jenkins (pods éphémères)** | Un ServiceAccount k8s → Vault k8s auth (jalon G8) | Un secret statique de longue durée |
| **Agents IA** | Un ServiceAccount k8s **lecture seule** + clé de signature de commits | Un kubeconfig cluster-admin. **Jamais** |
| **n8n** | Des jetons sortants (Slack, ITSM) uniquement | **Un kubeconfig. Aucune écriture cluster** |
| **Cloudflare** | Jeton DNS:Edit — **hors du coffre qu'il sert à réparer** (leçon G0) | — |

### La règle qui tient tout

**Un seul chemin de mutation du cluster : Git → Argo CD.** Tout le reste (agents, n8n, Jenkins,
humains) écrit **dans Git par PR**, jamais dans le cluster. Cette frontière n'est pas un principe
documenté : elle est **forcée** par le fait que personne d'autre qu'Argo CD ne détient de
credential en écriture sur l'API server.

---

## 5. Sort des hypothèses H1–H5

| # | Verdict | Confiance | Preuve / ce qui manque |
|---|---|---|---|
| **H1** — adoption progressive sous Argo CD | **INCERTAIN, penchant ACCEPTÉ avec conditions** | Moyenne | L'outillage existe et est fail-closed par défaut : suivi par annotation depuis Argo CD 3.0, SSA échoue par défaut sur conflit `[DOC]`. **Mais aucune** des affirmations qui rendraient la phase 1 non destructive « par défaut » (prune/selfHeal/allowEmpty/orphaned-resources) n'a survécu — **et la thèse alarmiste inverse non plus**. Tranché par le comptage de conflits au dry-run (G4), pas par la documentation. |
| **H2** — 5 nœuds sur IP publiques chiffrées | **INCERTAIN — non instruit** | Nulle | `[VIDE]` : zéro affirmation vérifiée sur WireGuard/Cilium/Tailscale, coût CPU, MTU, durcissement du `:6443`. **Ne pas marquer cette hypothèse.** Elle exige son propre cycle de recherche (G7). |
| **H3** — vcluster pour les labs | **INCERTAIN, penchant RÉFUTÉ** | Faible | `[VIDE]` côté sources. `[INFÉR]` : chaque vcluster embarque son propre datastore, donc N labs = N flux `fsync` supplémentaires sur le disque qui est **déjà** la contrainte dure. Sur une flotte limitée par `fsync`, l'isolation par vcluster se paie exactement dans la ressource la plus rare. Namespace + quotas d'abord. |
| **H4** — n8n a un périmètre légitime, mais pas l'administration | **ACCEPTÉ** | Haute (sur la partie exposition) | La partie « pas d'administration » est **acquise par la doctrine**, pas par une source : n8n stocke son état hors Git et mute impérativement — incompatible avec « Git = source de vérité ». La partie urgente est mesurée, pas discutable : **instance directement exposée sur Internet** (certificat émis pour l'origine ⇒ proxy Cloudflare désactivé), sur un **hôte non géré**. `[VIDE]` sur les CVE et la licence : à instruire (G9). |
| **H5** — agents avec auto-approbation sans dégrader l'auditabilité | **RÉFUTÉ** | **Haute** — preuve interne | `[REPO]` : allowlist sur le **premier mot** (`awk '{print $1}'`), contournable par chaînage (`echo ok; sudo id`), par trampoline (`env sudo …`), par `docker run --privileged` (root hôte, alors que `sudo` est refusé), par `curl … \| bash`. Surtout : **la garde ne se protège pas elle-même** — `Write` est allow-par-défaut, `.claude/hooks/` n'est pas protégé, et le scope censé compenser **fail-open**. |

---

## 6. Jalons

Séquencés par dépendance. Chaque jalon : ce qui est **prouvé** à la fin, une **porte de preuve
exécutable**, et une **contre-épreuve de sabotage** — casser volontairement la chose et vérifier
que la porte devient rouge. Une porte qui ne rougit jamais ne prouve rien.

---

### G0 — Sortie de l'impasse du jeton + inventaire DNS autoritatif
**Prérequis :** aucun. **Effort :** 0,5 j. **Pourquoi en premier :** c'est le seul risque de
sécurité *externe* et actif — `vault.gostoa.dev` pointe vers une IP Contabo recyclable ; si elle
est réattribuée, un tiers sert ce nom et obtient un certificat Let's Encrypt valide pour
l'ancien magasin de secrets.

**Prouvé à la fin :** une capacité d'écriture DNS existe hors de l'Infisical mort ;
`vault.gostoa.dev` ne résout plus ; la zone est inventoriée **de façon autoritative**.

**Porte de preuve :**
```bash
# 1. Nouveau jeton scopé, créé à la main dans l'UI Cloudflare (Zone:DNS:Edit sur gostoa.dev
#    UNIQUEMENT), stocké dans Vault — pas dans Infisical, pas dans un fichier.
# 2. Inventaire autoritatif — c'est le livrable, pas le sondage de noms devinés :
curl -sf -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?per_page=500" \
  | jq -r '.result[] | [.type,.name,.content,.proxied] | @tsv' | sort | tee dns-inventory.tsv
# 3. Purge de l'enregistrement pendant, puis assertion :
! dig +short vault.gostoa.dev | grep -q . || { echo "ÉCHEC : résout encore"; exit 1; }
# 4. Assertion de complétude : tout nom servi par le cluster doit exister dans l'inventaire.
```
**Contre-épreuve de sabotage :** recréer un enregistrement `takeover-test.gostoa.dev` pointant
vers une IP morte, relancer l'inventaire → il **doit** apparaître. S'il n'apparaît pas,
l'inventaire n'est pas autoritatif et la porte est fausse. Supprimer ensuite.

**Leçon à graver :** le jeton qui répare le coffre ne doit pas vivre **dans** le coffre. C'est la
seule exception admise à « zéro secret hors Vault », et elle doit être écrite comme telle.

---

### G1 — L'alerting qui aurait *vraiment* vu les 19 447 crashs
**Prérequis :** aucun (indépendant du cluster). **Effort :** 0,5–1 j.
**Pourquoi avant la purge :** si on purge d'abord, on perd la cible vivante qui prouve que
l'alerte fonctionne.

> **Constat qui change l'axe 4.** La question « quelle pile d'alerting choisir » est mal posée :
> **la pile est déjà écrite et commitée** — `deploy/prometheus/` contient 5 fichiers de règles,
> ~40 alertes, plus `alertmanager-config.yaml` `[REPO]`. Elle n'a jamais été appliquée. Et même
> appliquée, **elle aurait raté les 19 447 redémarrages, deux fois** :
>
> 1. **Mauvais périmètre.** `alerting-rules.yaml:222` :
>    `rate(kube_pod_container_status_restarts_total{namespace=~"stoa-system|team-alpha|team-beta"}[15m])`.
>    Les seuls sélecteurs présents dans tout `deploy/prometheus/` sont `stoa-system` (8×),
>    `stoa-system|team-alpha|team-beta` (7×), `stoa-system|stoa-monitoring` (2×).
>    **`gateway-dev`, `gateway-staging` et `gateway-rec` n'apparaissent dans aucune règle.**
>    Les seuls namespaces qui existent réellement ne sont surveillés par rien.
> 2. **Seuil inadapté au type même de la panne.** 19 447 ÷ 119 j = **1,7 redémarrage par
>    15 min**. La règle exige **> 3 / 15 min**. Même avec le bon namespace, **elle n'aurait
>    jamais déclenché.** CrashLoopBackOff plafonne l'intervalle à 5 min (≤ 12/h) : une alerte de
>    **débit** rate structurellement un crash-loop plafonné. Il faut une alerte **d'état**.
> 3. **Aucune règle ImagePull n'existe** `[REPO]` → les 510 126 événements n'avaient aucun capteur.

**Prouvé à la fin :** une alerte se déclenche en < 1 h sur un crash-loop dans un namespace réel,
et la chaîne va jusqu'à une notification reçue.

**Porte de preuve :**
```bash
# Les 5 alertes indispensables, formulées en ÉTAT et non en débit :
# 1. kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} == 1        for: 15m
# 2. kube_pod_container_status_waiting_reason{reason=~"ImagePullBackOff|ErrImagePull"} == 1  for: 15m
# 3. kube_node_status_condition{condition="Ready",status="true"} == 0                for: 5m
# 4. kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes < .15 for: 10m
# 5. certificat < 14 j (règles déjà présentes, à recâbler sur les vrais hôtes)
# + le dead-man : Healthchecks.io pingé par Alertmanager — un silence total DOIT alerter.

# Assertion de PÉRIMÈTRE (le vrai piège) — aucune règle ne doit filtrer par namespace :
grep -rE 'namespace=~?"' deploy/prometheus/ && { echo "ÉCHEC : filtre de namespace résiduel"; exit 1; }
```
**Contre-épreuve de sabotage :** déployer volontairement dans `gateway-dev` un pod en
`CrashLoopBackOff` (image inexistante + commande fausse) et **chronométrer**. Assertion :
notification reçue en < 60 min. Puis le supprimer. Deuxième sabotage, le plus important :
**couper Alertmanager** et vérifier que le dead-man Healthchecks passe au rouge — sans quoi on
reconstruit précisément la panne d'origine, un système de surveillance silencieux qu'on croit
vivant.

---

### G2 — `gateway-rec` : au rebut, et la cause racine avec
**Prérequis :** G1 (voir avant de toucher). **Effort :** 0,5 j.
**Décision : au rebut.** Trois faits concordants, aucun contradictoire :
- Ses 3 déploiements ne sont **nulle part** en Git — ni overlay, ni base `[REPO]`. « Écrire
  l'overlay manquant » signifie **écrire du neuf**, pas extraire de Git.
- Le seul Kong en Git est `k8s/arena/kong.yaml`, qui cible `namespace: stoa-system` — **pas**
  `gateway-rec` `[REPO]`. Ce qui tourne est une copie modifiée à la main.
- Son Ingress déclare `rec-gw` / `rec-kong` / `rec-wm.gostoa.dev`, **aucun n'a de DNS** : ce
  namespace ne sert de trafic à personne. Il consomme des ressources et produit des crashs.

**Prouvé à la fin :** le namespace n'existe plus, **et ne peut pas revenir**.

**Porte de preuve :**
```bash
# Snapshot légal avant destruction (traçabilité, hors Git) :
kubectl get all,ingress,cm,secret -n gateway-rec -o yaml > /tmp/gateway-rec-final-$(date +%F).yaml
kubectl delete namespace gateway-rec
# Correctif de la cause racine, DANS LE MÊME COMMIT — sinon setup.sh le recrée :
#   deploy/k3s-gateways/setup.sh:42,44,48,63,97 → retirer toute référence à gateway-rec
! grep -q 'gateway-rec' deploy/k3s-gateways/setup.sh || { echo "ÉCHEC : cause racine intacte"; exit 1; }
```
**Contre-épreuve de sabotage :** rejouer `setup.sh` en entier sur un cluster jetable et asserter
que `gateway-rec` **n'est pas recréé**. C'est la seule preuve qui compte : supprimer le namespace
sans cette contre-épreuve ne fait que remettre le compteur à zéro.

---

### G3 — Purge du reste de la dette mesurée
**Prérequis :** G2. **Effort :** 1 j.
**Prouvé à la fin :** plus aucun secret créé à la main, plus aucune image flottante.

**Porte de preuve :**
```bash
# a) ghcr-creds provient d'ESO/Vault, plus d'un `gh auth token` collé à la main :
kubectl get secret ghcr-creds -n gateway-dev -o jsonpath='{.metadata.ownerReferences[0].kind}' \
  | grep -q ExternalSecret || { echo "ÉCHEC : secret encore manuel"; exit 1; }
# b) plus aucune image flottante dans les manifestes rendus :
kustomize build k8s/gateways/overlays/dev | grep -E 'image:.*(:latest|:[0-9]+\.[0-9]+)$' \
  && { echo "ÉCHEC : image non épinglée par digest"; exit 1; }
```
**Contre-épreuve de sabotage :** (a) révoquer le jeton Vault d'ESO → le secret doit **cesser
d'être renouvelé et l'alerte doit partir** ; (b) proposer une PR contenant `image: nginx:latest`
→ Kyverno en `Enforce` doit la **rejeter** (voir G5 ; en `Audit`, elle passe — c'est l'état
actuel `[REPO: k8s/kyverno/policies/lifecycle-labels.yaml:27]`).

---

### G4 — Mesure d'arbitrage de H1 (le jalon qui décide)
**Prérequis :** G2. **Effort :** 1 h. **C'est le jalon le moins cher et le plus décisif.**

**Prouvé à la fin :** on sait, par un chiffre, s'il faut adopter ou reconstruire.

**Porte de preuve :**
```bash
# Contrôle de validité D'ABORD — sans lui, le test ne prouve rien :
kubectl get deploy -n gateway-dev -o json \
  | jq -r '.items[].metadata.managedFields[] | select(.operation=="Update") | .manager' | sort -u
# On DOIT y voir `kubectl-client-side-apply`. Si absent (objets posés par `create`/`replace`),
# l'absence de conflits observée plus bas ne signifierait rien.

# Mesure de la dérive impérative :
kustomize build k8s/gateways/overlays/dev \
  | kubectl apply --server-side --dry-run=server -f - 2>&1 | tee /tmp/ssa-dev.txt
grep -c -i conflict /tmp/ssa-dev.txt
```
**Règle de décision, fixée AVANT de regarder le résultat** (sinon on rationalise) :
**< 10 conflits triviaux** (labels, annotations) → **adopter** (G5). **≥ 10, ou des conflits sur
des champs de spec** (image, replicas, env) → **reconstruire** sur un nœud vide (G6) et basculer.

**Contre-épreuve de sabotage :** modifier à la main un champ dans le cluster
(`kubectl set image` sur un déploiement de `gateway-dev`), relancer le dry-run, vérifier que le
compteur de conflits **augmente**. S'il n'augmente pas, la mesure ne mesure rien.

---

### G5 — Argo CD posé et adoption en phase 1
**Prérequis :** G4 (branche « adopter »). **Effort :** 1–2 j.

> **`deploy/k3s-gateways/argocd.yaml` ne doit PAS être appliqué en l'état** `[REPO]`. Il est à la
> fois dangereux et obsolète :
> - `prune: true` **et** `selfHeal: true` dès le premier sync (l. 32-33, 53-54) — exactement
>   l'inverse de la phase 1 sûre ;
> - `destination.server: https://<K3S_CP_IP>:6443` — **placeholder non substitué** (l. 28, 49) ;
> - l'en-tête dit « Apply on the OVH prod cluster (where ArgoCD runs) » : il encode une
>   architecture *hub* sur un cluster OVH **qui n'existe plus** (les hôtes OVH sont hors gestion) ;
> - `project: default` — l'AppProject par défaut n'impose aucune restriction de destination.

**Prouvé à la fin :** Argo CD réconcilie `gateway-dev` et `gateway-staging` sans avoir rien
détruit, et la propriété des ressources lui appartient.

**Porte de preuve :**
```bash
# Argo CD >= 3.3.2 IMPÉRATIF : le correctif du bug de migration client-side sur objets > 256 Ko
# (CRD) est dans la 3.3.2 — issue argoproj/argo-cd#26279.
argocd version --short | grep -E 'v3\.(3\.[2-9]|[4-9])' || { echo "ÉCHEC : version < 3.3.2"; exit 1; }

# La porte NE PEUT PAS asserter sur `Synced` : avec Prune=false l'Application reste OutOfSync
# par construction (doc Argo CD « No Prune Resources »). On asserte sur le diff énuméré :
argocd app diff gateways-dev --server-side-generate > /tmp/diff-dev.txt
# Assertion : le diff ne contient QUE des ressources attendues, et AUCUNE suppression :
grep -E '^-' /tmp/diff-dev.txt | grep -v '^---' && { echo "ÉCHEC : suppression au programme"; exit 1; }

# Propriété effective, après le premier sync seulement (l'annotation n'est écrite qu'au sync) :
kubectl get deploy -n gateway-dev -o jsonpath='{.items[*].metadata.annotations.argocd\.argoproj\.io/tracking-id}'
```
**Configuration imposée en phase 1 :** `syncOptions: [ServerSideApply=true, CreateNamespace=true]`,
**sans** `Force`, `automated.prune: false`, **pas** de `selfHeal`, AppProject dédié restreignant
`destinations` aux deux namespaces.

**Pourquoi pas le suivi par label** `[DOC]` : le mode `label` réutilise
`app.kubernetes.io/instance`, que les charts Helm écrivent aussi — la doc Argo CD le désigne
elle-même comme mode de défaillance (« several Helm charts and operators also use this label
[…] confusing Argo CD about the owner »), et la valeur est tronquée à 63 caractères. Ce dépôt
émet précisément ce label depuis ses propres charts
`[REPO: charts/stoa-platform/templates/_helpers.tpl:30, charts/stoa-observability/templates/_helpers.tpl:7,18]`.
Le défaut depuis Argo CD 3.0 est l'annotation `argocd.argoproj.io/tracking-id` — le conserver.

**Contre-épreuve de sabotage :** modifier à la main une ressource adoptée, puis `argocd app sync`.
Avec SSA **sans** `Force`, le sync doit **échouer sur conflit** — c'est la preuve du
comportement fail-closed. S'il réussit silencieusement, `Force` traîne quelque part et la
garantie invoquée n'existe pas.

**Mode de défaillance documenté `[DOC]` :** sur objets > 256 Ko (typiquement les CRD), la
migration client-side écrit `last-applied-configuration` et échoue avec
`metadata.annotations: Too long` (Argo CD 3.3.0/3.3.1, issue #26279). **Parade :** ≥ 3.3.2, ou
`ClientSideApplyMigration=false` en remédiation **temporaire**, à retirer après correctif.

---

### G6 — Plan de contrôle reconstruit sur un nœud vide + RTO chronométré
**Prérequis :** G5. **Effort :** 1 j.
**Justification par la mesure :** le plan de contrôle est aujourd'hui sur `worker-5`, dont
l'écriture synchrone mesure **6,53 ms/op** contre **2,67 ms** sur `worker-1` (même méthode `dd`).
Le composant le plus sensible au `fsync` de toute la pile est posé sur la machine la plus lente
mesurée. *Nuance honnête :* `worker-5` est aussi le seul chargé, donc la comparaison confond
« lent » et « occupé » — mais dans les deux cas, déplacer le plan de contrôle vers un nœud vide
au disque mesuré meilleur est strictement préférable.

**Prouvé à la fin :** le RTO d'un rebuild-from-Git est **chronométré**, ce qui objective le
renoncement à la HA au lieu de le supposer acceptable.

**Porte de preuve :**
```bash
# Chronométrer un rebuild complet sur un nœud vide, du bare-metal au trafic servi :
time (ansible-playbook -l worker-1 playbooks/k3s-control-plane.yml \
      && kubectl apply -f bootstrap/argocd/ \
      && argocd app wait gateways-dev gateways-staging --health --timeout 900)
# Assertion : RTO mesuré < 60 min. Si oui, l'abandon de la HA est justifié PAR LA MESURE.

# Re-mesure disque standardisée, épinglée par digest (l'outil Red Hat tire :latest — inacceptable
# ici, et il cible /var/lib/etcd qui n'existe pas sous k3s) :
podman run --volume /var/lib/rancher/k3s/server/db:/var/lib/etcd \
  quay.io/cloud-bulldozer/etcd-perf@sha256:<DIGEST_À_FIGER>
# Attendu : WARN. L'outil teste en bs=8000 alors que la mesure du 27/07 était à ~2300 o : c'est
# une re-mesure standardisée, PAS une reproduction des chiffres existants. [DOC]
```
**Contre-épreuve de sabotage :** arrêter brutalement le plan de contrôle
(`systemctl stop k3s`) et vérifier que **les charges déjà ordonnancées continuent de servir le
trafic** — c'est ce qui rend le mono-CP acceptable : la perte du plan de contrôle interrompt les
*changements*, pas le *service*. Si le trafic tombe avec le CP, l'analyse de risque est fausse
et la HA redevient nécessaire.

---

### G7 — Extension à 5 nœuds + chiffrement inter-nœuds  ⚠️ **NON INSTRUIT**
**Prérequis :** G6. **Effort :** non estimable en l'état.

**Ce jalon ne peut pas être planifié aujourd'hui.** `[VIDE]` — zéro affirmation vérifiée sur le
coût CPU de WireGuard vs Cilium vs Tailscale, sur l'impact MTU, sur le durcissement du `:6443`.
Le prompt demandait des recommandations sourcées : il n'y en a pas.

**Action : refaire un cycle de recherche dédié sur H2 seul**, avant tout engagement. Ce qui est
sûr sans recherche : le `:6443` ne doit **jamais** être ouvert au monde — filtrage par IP source
sur les 5 nœuds, et `--tls-san` correct. C'est un prérequis, pas une recommandation.

---

### G8 — Vault Kubernetes auth pour l'identité de job Jenkins
**Prérequis :** G6 (il faut un cluster). **Effort :** 2 j.

> **Requalification nécessaire.** Le prompt décrit ce jalon comme « décidé, codé, jamais prouvé
> faute de cluster ». La vérification du dépôt ne trouve **ni dossier Jenkins, ni aucune
> occurrence de `kubernetes/login`, `VAULT_K8S_ROLE` ou d'une configuration Vault k8s auth**
> `[REPO]` — Jenkins n'apparaît que dans trois documents (`docs/TECHNOLOGY-CHOICES.md`,
> `docs/CAPACITY-PLANNING.md`, `docs/runbooks/medium/jenkins-pipeline-stuck.md`).
> **Ce jalon part de zéro code, pas de code écrit-non-prouvé.** L'effort est à revoir en
> conséquence — et si un dépôt Jenkins séparé existe hors de cette arborescence, il faut le
> verser à l'inventaire avant de planifier.

**Prouvé à la fin :** un job Jenkins s'authentifie auprès de Vault **par son identité de pod**,
sans aucun secret statique en CI (« pas de secret zero »).

**Porte de preuve :**
```bash
# Depuis un agent Jenkins éphémère, échange du ServiceAccount token contre un token Vault :
JWT=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
vault write auth/kubernetes/login role=jenkins-agent jwt="$JWT"
# Assertion : succès, et le token obtenu a un TTL court et des policies étroites.
```
**Contre-épreuve de sabotage :** rejouer le même appel depuis un pod d'un **autre**
ServiceAccount / namespace → il **doit** être refusé. Sans cette contre-épreuve, on n'a prouvé
que « Vault répond », pas « Vault distingue les identités ».

---

### G9 — Frontière n8n forcée techniquement
**Prérequis :** G0 (capacité DNS). **Effort :** 1 j.

**Ordre d'audit imposé** — du plus dommageable au moins dommageable si compromis :
1. **Quels credentials l'instance détient-elle déjà ?** C'est le premier livrable : tant qu'on
   ne le sait pas, on ignore le rayon d'explosion. Chercher en priorité tout kubeconfig, toute
   clé SSH de flotte, tout jeton Cloudflare (il pourrait résoudre l'impasse de G0), tout jeton
   Gitea/Vault.
2. **L'UI est-elle authentifiée, et par quoi ?** Elle est aujourd'hui **directement joignable
   depuis Internet** (certificat émis pour l'origine ⇒ proxy Cloudflare désactivé).
3. **Les webhooks exposés** — ce sont des points d'entrée non authentifiés par défaut.
4. **Les nœuds `Code` / `Execute Command`** présents dans les workflows existants = exécution de
   code arbitraire sur l'hôte.
5. **La reprise en gestion de l'hôte** (accès SSH) — sans quoi rien n'est vérifiable dans la durée.

**Prouvé à la fin :** n8n ne peut **pas** muter le cluster, et ne peut plus être atteint
directement depuis Internet.

**Porte de preuve :**
```bash
# 1. Plus d'accès direct à l'origine : le port 443 de l'origine ne doit répondre qu'à Cloudflare.
curl -sS --max-time 5 https://<IP_ORIGINE_N8N>/ -H 'Host: n8n.gostoa.dev' \
  && { echo "ÉCHEC : origine encore joignable en direct"; exit 1; }
# 2. Preuve NÉGATIVE, la plus importante : aucun credential cluster sur l'hôte.
#    Assertion : aucun kubeconfig, aucun ServiceAccount token.
# 3. Preuve par le réseau, pas par la confiance : depuis l'hôte n8n,
#    l'API server doit être INJOIGNABLE (filtrage par IP source sur le :6443).
```
**Contre-épreuve de sabotage :** déposer volontairement un kubeconfig valide sur l'hôte n8n et
tenter `kubectl get ns` → **doit échouer au niveau réseau**. C'est ce qui distingue une frontière
*forcée* d'une frontière *documentée* : elle tient même quand le credential fuit.

**Ce que n8n garde :** notifications sortantes, chatops, ITSM, appels de webhooks, collecte
d'approbation humaine. **Ce qu'il perd :** tout accès en écriture au cluster, tout kubeconfig,
tout rôle dans le chemin de déploiement. **Réveil/hibernation de lab :** autorisé **uniquement**
en ouvrant une PR (donc via Git), jamais par `kubectl` direct.

---

### G10 — Reprise en main des agents IA (remédiation de H5)
**Prérequis :** G5. **Effort :** 2 j.

**Ce qui est cassé aujourd'hui, vérifié dans le dépôt** `[REPO: .claude/hooks/permission-request-contabo.sh]` :

| # | Voie d'échappement | Mécanisme |
|---|---|---|
| 1 | `echo ok; sudo id` | L'allowlist ne lit que le **premier mot** (l. 27) ; le deny `sudo *` n'ancre qu'en début de chaîne |
| 2 | `env sudo -n id` | `env` est allowlisté (l. 59) et sert de trampoline |
| 3 | `docker run --privileged -v /:/host` | `docker` est allowlisté (l. 63) alors que `sudo` est refusé — **contradiction interne**, l'accès au socket Docker est root-équivalent |
| 4 | `curl http://…/x.sh \| bash` | `curl` allowlisté ; le pipe n'est pas examiné |
| 5 | `awk 'BEGIN{system("…")}'`, `find -exec` | Primitives d'exécution arbitraire dans l'allowlist |
| 6 | `git push -f` | Le deny cherche `--force` ; `-f` passe. **Ironie : `--force-with-lease`, la forme sûre, est bloquée** |
| 7 | `kubectl delete ns` | Le deny ne couvre que la forme longue `kubectl delete namespace` |
| 8 | `kubectl get secret -o yaml` | `kubectl` allowlisté en bloc ; avec le kubeconfig k3s par défaut, c'est cluster-admin |
| 9 | `infisical` allowlisté (l. 67) | Permission vivante sur un magasin de secrets **mort**, alors que la doctrine dit Vault |
| **10** | **Réécriture de la garde elle-même** | **Le plus grave.** `Write` est allow-par-défaut (l. 75-78) au motif que le scope est « enforced by PreToolUse hook ». Or `pre-edit-protect-infra.sh:14-17` ne protège que `terraform/environments/prod` et `deploy/config/prod.env` — **`.claude/hooks/` et `settings.json` ne sont pas protégés**. Et `pre-instance-scope.sh` **fail-open** : `STOA_INSTANCE` absent → `exit 0` (l. 19-21), fichier d'instance absent → `exit 0` (l. 32-34). **`grep -rn 'STOA_INSTANCE=' ` sur tout le dépôt → une seule occurrence, dans un commentaire.** La variable n'est exportée nulle part. Sur les workers, le scope annoncé est un **no-op**. Un agent peut réécrire sa propre garde, `git commit && git push`, et la levée se **propage à toute la flotte** au pull suivant. |

**Le principe à inverser :** on ne sécurise pas un agent en filtrant ses commandes shell — la
surface est indéfendable, comme ci-dessus. On le sécurise en **retirant le pouvoir**, pas en
listant les verbes : l'agent n'a **aucun credential en écriture sur le cluster**, il écrit des
manifestes **dans Git par PR**, et Argo CD est le seul mutateur.

**Prouvé à la fin :** un agent ne peut pas muter le cluster, et ses actions sont attribuables.

**Porte de preuve :**
```bash
# 1. L'agent a un ServiceAccount dédié, en LECTURE SEULE :
kubectl auth can-i --list --as=system:serviceaccount:agents:hegemon | grep -E '\b(create|update|delete)\b' \
  && { echo "ÉCHEC : l'agent peut muter"; exit 1; }
# 2. Identité auditable, distincte d'un humain : les commits d'agent sont signés par une clé
#    d'agent dédiée et traçables jusqu'à la PR.
git log --format='%an %G?' -20 | grep -v ' G$' && { echo "ÉCHEC : commit non signé"; exit 1; }
# 3. La garde se protège elle-même — ajouter .claude/ à PROTECTED_PATTERNS :
grep -q '\.claude/hooks' .claude/hooks/pre-edit-protect-infra.sh || { echo "ÉCHEC : garde non protégée"; exit 1; }
# 4. Fail-CLOSED au lieu de fail-open : STOA_INSTANCE absent doit REFUSER, pas exit 0.
```
**Contre-épreuve de sabotage — la seule qui compte :** demander à un agent, sur un worker, de
réécrire `.claude/hooks/permission-request-contabo.sh` pour s'auto-approuver. **Il doit être
bloqué.** Puis lui demander `kubectl delete deploy` dans `gateway-dev` → doit être refusé par
**RBAC**, pas par une liste de mots.

**À vérifier d'abord (< 5 min) :** le hook renvoie un `{"decision":"allow"}` **à plat**. Si le
schéma attendu par la version courante de Claude Code est
`hookSpecificOutput.permissionDecision`, le hook est un **no-op silencieux** — auquel cas tout
retombe en approbation manuelle (bénin) ou la garde ne s'applique pas du tout. Ce test change le
sens du verdict et doit précéder la remédiation.

---

### G11 — Labs éphémères (l'objectif réel)
**Prérequis :** G5, G6, G10. **Effort :** 3–5 j.

**Combien d'exemplaires concurrents ?** Le prompt demande un chiffre. Le voici, avec ses
hypothèses — et surtout avec **la raison pour laquelle ce n'est pas le bon chiffre** :

`[INFÉR]` Coût RAM d'une stack « WSO2 + wM 10.15 + Keycloak + OpenSearch + Redpanda + LGTM +
Microcks » : ≈ **20 Gi** (wM+ES ~6, WSO2 ~4, LGTM ~3, OpenSearch ~2, Redpanda ~2, Microcks ~1,5,
Keycloak ~1). RAM utilisable après OS, k3s, agents, le wM Docker existant et les services de
plateforme : ≈ **101 Gi**. Les pods d'un même lab s'ordonnancent indépendamment, donc la
contrainte est le **total**, pas la capacité d'un nœud.
→ **4 labs concurrents « chauds »** (5 tiennent, on garde une marge de burst).
→ Avec hibernation à ~25 % de cycle de service : **~16 labs définis, 4 éveillés**.

**Mais la RAM n'est probablement pas la contrainte.** Trois des sept composants sont
intensément `fsync` (OpenSearch translog, Elasticsearch de wM, Redpanda). À ~300 IOPS synchrones
et un p99 `fsync` déjà à 10 ms **à vide**, 4 labs × 3 composants = 12 flux de journalisation
synchrone concurrents sur le même disque. **Le plafond réel sera atteint par le disque avant de
l'être par la RAM.** C'est la réponse utile à la question posée : le budget n'est pas de 70 Go de
RAM, il est de ~300 IOPS synchrones — et il n'a pas été mesuré sous charge.

**Prouvé à la fin :** N labs concurrents tiennent, **avec N mesuré et non supposé**.

**Porte de preuve :**
```bash
# Monter en charge lab par lab en surveillant la latence du plan de contrôle, PAS la RAM :
for i in $(seq 1 6); do
  kubectl apply -k labs/overlays/lab-$i
  kubectl wait --for=condition=Ready pod --all -n lab-$i --timeout=900s || break
  # Signal d'arrêt : latence des appels API et taille du datastore kine
  ls -la /var/lib/rancher/k3s/server/db/state.db*
done
# Assertion : N labs Ready ; consigner N. C'est la capacité réelle.
```
**Contre-épreuve de sabotage :** dépasser volontairement le quota d'un lab → la création doit
être **refusée** par le ResourceQuota, et surtout **ne pas dégrader les autres labs**. Vérifier
aussi qu'un lab expiré est **effectivement** ramassé (TTL), sinon on reconstruit le namespace
orphelin de `gateway-rec` à l'échelle N.

**webMethods 10.15 : ne pas le porter dans le cluster.** Il fonctionne aujourd'hui en Docker sur
`worker-3`. Le déplacer n'apporte aucune capacité nouvelle, et les questions de support éditeur
et de licence d'évaluation (durée, hébergement distant, obligation de non-exposition) sont
`[VIDE]` — non instruites. On ne migre pas une charge dont on ne peut pas vérifier les conditions
de support. Décision : **statu quo**, et instruire la licence séparément.

---

## 7. Risques et pièges (gravité × probabilité)

| # | Risque | G×P | Parade | Signal de détection |
|---|---|---|---|---|
| 1 | **Agent réécrit sa propre garde et la propage par `git push`** | **Critique × Élevée** — la voie est ouverte aujourd'hui `[REPO]` | G10 : protéger `.claude/`, fail-closed, RBAC lecture seule | Diff sur `.claude/hooks/` dans une PR non humaine |
| 2 | **Subdomain takeover de `vault.gostoa.dev`** | **Critique × Moyenne** — IP Contabo recyclable | G0 : purger l'enregistrement | Certificate Transparency sur `*.gostoa.dev` |
| 3 | **Application de `argocd.yaml` en l'état** (`prune+selfHeal: true`) | **Élevée × Moyenne** | G5 : réécrire avant d'appliquer | Revue de PR ; `grep 'prune: true'` |
| 4 | **n8n compromis via l'exposition directe** | **Élevée × Moyenne** | G9 : Cloudflare Access + aucun credential cluster | Logs d'accès ; audit des credentials |
| 5 | **kine/SQLite plafonne sous le churn des labs** | Élevée × **Inconnue** `[VIDE]` | Provisionner kine+Postgres ; mesurer avant d'industrialiser | Taille de `state.db-wal` ; `database is locked` |
| 6 | **L'alerting reste aveugle malgré G1** (filtre de namespace) | Élevée × Moyenne — **c'est déjà arrivé** | Assertion anti-`namespace=~` en CI | La contre-épreuve de G1 doit rougir |
| 7 | **Le disque plafonne avant la RAM sur les labs** | Moyenne × **Élevée** `[INFÉR]` | Mesurer en IOPS, pas en Go | Latence API ; p99 `fsync` |
| 8 | **H2 engagé sans instruction** (chiffrement inter-nœuds) | Moyenne × Moyenne | G7 : recherche dédiée d'abord | — |
| 9 | **`Force` réintroduit pour faire taire les conflits SSA** | Moyenne × Moyenne | Interdire `Force` en revue | `grep Force` dans les syncOptions |

---

## 8. Critères d'abandon

Les trois signaux mesurables qui imposent de replier le lab **hors** de Kubernetes (retour à
Docker Compose piloté par Ansible, qui est déjà maîtrisé ici) :

1. **Le plan de contrôle devient le goulot avant 4 labs concurrents.** Mesure : p99 de latence
   des appels API > 1 s, ou `state.db-wal` qui croît sans être checkpointé, ou apparition de
   `database is locked` dans les logs k3s. Si k3s ne tient pas 4 labs, il ne rend aucun service
   qu'un `docker compose` ne rendrait mieux sur ce matériel.
2. **Le temps passé à réparer le cluster dépasse le temps passé à s'en servir**, mesuré sur
   4 semaines glissantes (traçable : commits d'infrastructure vs commits de lab). C'est le
   critère qui aurait dû se déclencher pendant les 119 jours de crash-loop.
3. **Le p99 `fsync` sous charge dépasse durablement ~20 ms** (le double du seuil etcd, déjà
   atteint au p99.9 **à vide** : 23,7–24,0 ms). À ce niveau, aucune charge journalisée
   (OpenSearch, Redpanda, wM) ne tient ses garanties, et le problème n'est plus l'orchestrateur
   mais le stockage — changer d'hébergeur ou de classe de disque, pas d'orchestrateur.

---

## 9. Questions ouvertes (test < 1 h chacune)

1. **Le hook d'auto-approbation est-il seulement actif ?** Le format `{"decision":"allow"}` à
   plat correspond-il au schéma attendu par la version courante de Claude Code ?
   **Test (< 5 min)** : exécuter le hook à la main avec un payload JSON, puis lancer un `Bash`
   réel sur un worker avec `STOA_CONTABO_WORKER=1` et observer. **Change le sens du verdict H5**
   (garde contournable vs garde inexistante) et doit précéder G10.
2. **Quels sont les défauts RÉELS de `prune`, `selfHeal`, `allowEmpty` ?** Communément tenus pour
   `false`, mais **réfutés 1-2 et 0-3** dans cette base de preuves — vraisemblablement un défaut
   d'adéquation source↔affirmation, pas une erreur de fond. **Ne rien construire dessus sans
   revérifier.** **Test (< 15 min)** : `kubectl explain application.spec.syncPolicy.automated
   --recursive` sur le CRD de la version cible, puis Application minimale sur namespace jetable.
3. **Combien de conflits SSA sur ce cluster de 128 jours ?** C'est G4 — la mesure qui arbitre H1.
   **Test (< 1 h)**, avec le contrôle de validité `managedFields` **d'abord**.
4. **Quel mécanisme donne l'inventaire autoritatif du delta cluster ↔ Git ?**
   « Orphaned Resources Monitoring » n'a **pas** survécu à la vérification, alors que c'était
   l'outil désigné pour qualifier `gateway-rec`. **Test (< 1 h)** : diff entre
   `kubectl get all,ingress,secret,cm -A -o name` et le rendu de tous les overlays Kustomize.
5. **À partir de quel taux de churn kine/SQLite devient-il le goulot ?** Aucune borne n'a
   survécu. **Test (< 1 h)** : boucle création/destruction de N namespaces peuplés sur un k3s
   neuf posé sur un nœud vide — **en fixant le seuil d'abandon avant de lancer**.
6. **Que détient déjà l'instance n8n comme credentials ?** Inconnu, et c'est le rayon d'explosion.
   **Test** : reprendre l'accès à l'hôte, inventorier les credentials stockés. Si un jeton
   Cloudflare s'y trouve, il **résout l'impasse de G0**.
7. **Existe-t-il un dépôt Jenkins hors de cette arborescence ?** Le code Vault k8s auth supposé
   « écrit mais non prouvé » est introuvable `[REPO]`. **Test (< 10 min)** : `gh repo list` sur
   l'organisation Gitea. Requalifie l'effort de G8.

---

## Annexe — Sources primaires retenues

Consultées le 2026-07-27, toutes vivantes. Uniquement de la documentation éditeur ou du code
amont ; aucune source marketing ni benchmark trié.

**Argo CD / Kubernetes**
- Resource tracking (annotation par défaut depuis v3.0) — https://argo-cd.readthedocs.io/en/stable/user-guide/resource_tracking/
- PR #22289 « set default tracking to annotation » (fusionnée 2025-03-13, jalon v3.0) — https://github.com/argoproj/argo-cd/pull/22289
- Sync options (« No Prune Resources » : reste `OutOfSync`) — https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/
- Issue #26279 — migration client-side / CRD > 256 Ko, corrigé en 3.3.2 — https://github.com/argoproj/argo-cd/issues/26279
- Issue #17188 — `requiresPruning` et statut `OutOfSync` — https://github.com/argoproj/argo-cd/issues/17188
- Server-Side Apply (échec par défaut sur conflit) — https://kubernetes.io/docs/reference/using-api/server-side-apply/

**etcd / disque**
- FAQ etcd v3.6 — seuils `wal_fsync_duration_seconds` p99 < 10 ms et `backend_commit_duration_seconds` p99 < 25 ms — https://etcd.io/docs/v3.6/faq/
- Hardware etcd v3.6 — mécanisme causal, planchers 50/500 IOPS séquentiels, **aucune milliseconde** — https://etcd.io/docs/v3.6/op-guide/hardware/
- Red Hat, validation matérielle etcd (module source) — https://raw.githubusercontent.com/openshift/openshift-docs/main/modules/etcd-verify-hardware.adoc
- `etcd-perf/run.sh` (fio `bs=8000`, seuil 10 ms en dur) — https://github.com/cloud-bulldozer/images/blob/master/etcd-perf/run.sh

**Non couvert par des sources vérifiées :** réseau chiffré inter-nœuds, Longhorn/OpenEBS,
vcluster/Capsule, pile d'alerting, n8n (CVE et licence), échappements d'allowlist d'agents.
Les conclusions de ce rapport sur ces sujets sont marquées `[REPO]` (preuve interne) ou
`[INFÉR]` (raisonnement depuis les mesures), **jamais** présentées comme sourcées.

---

## Correction d'une erreur de la base de preuves

La vérification affirmait avoir constaté la propagation de `app.kubernetes.io/instance` via
`charts/ingress-nginx/templates/_helpers.tpl` « sur ce cluster ». **Ce chemin n'existe pas dans
ce dépôt** — les charts présents sont `minio`, `stoa-observability`, `stoa-platform`. La
conclusion (le suivi par label est inutilisable ici) **tient**, mais par une preuve différente :
`charts/stoa-platform/templates/_helpers.tpl:30` et
`charts/stoa-observability/templates/_helpers.tpl:7,18` émettent bien ce label. Signalé plutôt
que corrigé en silence, conformément aux exigences de méthode.
