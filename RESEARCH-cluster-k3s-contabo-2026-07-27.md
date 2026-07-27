# PROMPT DEEP RESEARCH v2 — Reprise en main du cluster k3s Contabo & labs à la demande

> v2 : remplace la v1. Les axes « faisabilité Contabo », « choix de distribution » et
> « dimensionnement » ont été **tranchés par la mesure** (inventaire live du 2026-07-27) et
> sont désormais fournis comme CONTRAINTES, pas comme questions.

---

## RÔLE

Architecte plateforme senior : Kubernetes frugal auto-hébergé, GitOps, environnements
éphémères multi-tenant, sécurité des agents autonomes. Recommandations **sourcées, datées,
falsifiables**. Tu es explicitement chargé de **réfuter** les hypothèses quand les faits les
contredisent. Pas de complaisance : si la bonne réponse est « supprime ça », dis-le.

## FAITS MESURÉS (données d'entrée — ne pas re-questionner, ne pas re-chercher)

**Flotte Contabo — 5 VPS identiques, payés jusqu'en 2027 :**
8 vCPU AMD EPYC / 24 Go RAM / 400 Go disque `ROTA=0` (SSD) / 8 Go swap / Debian 12 / KVM.
**Total 40 vCPU, 120 Go RAM, 2 To.** `steal` CPU cumulé = **0 tick** sur les 5 machines, dont
3 à 21 semaines d'uptime → **pas de contention de vCPU mesurable**. Pas de réseau privé
souscrit : les nœuds communiquent sur **IP publiques**.

**Performance disque mesurée (2026-07-27, `dd`) — c'est l'axe faible, à traiter comme une
contrainte dure :**

| Mesure | worker-1 (au repos) | worker-5 (control-plane k3s) |
|---|---|---|
| Écriture **synchrone** 2300 o (profil WAL etcd) | **2,67 ms/op** (~375 IOPS) | **6,53 ms/op** (~153 IOPS) |
| Écriture **synchrone** 4 k | **3,20 ms/op** | **5,92 ms/op** |
| Débit séquentiel écriture 1 Go | 73 MB/s | 54 MB/s |
| Débit séquentiel lecture 1 Go (O_DIRECT) | 842 MB/s | 761 MB/s |

Lecture rapide (classe NVMe, cohérent avec `ROTA=0`), mais **latence de `fsync` élevée**, là où
un NVMe local dédié donne 0,1–0,5 ms. Le débit séquentiel en écriture (54–73 MB/s) suggère un
stockage réseau ou bridé.

**Percentiles `fsync` mesurés par `fio` (profil WAL etcd, rôle Ansible
`fleet_disk_bench`, 2026-07-27) sur les 3 nœuds au repos :**

| Hôte | moyenne | p50 | p95 | **p99** | p99.9 |
|---|---|---|---|---|---|
| worker-1 | 2,32 ms | 1,89 | 5,54 | **10,03 ms** | 23,72 ms |
| worker-2 | 2,01 ms | 1,55 | 5,15 | **9,63 ms** | 17,70 ms |
| worker-4 | 2,24 ms | 1,75 | 5,73 | **10,95 ms** | 23,99 ms |

**Verdict de la mesure — à traiter comme acquis, pas à re-chercher :** le seuil etcd
(`etcd_disk_wal_fsync_duration_seconds` p99 < 10 ms) **coupe au milieu du nuage de mesures**.
Les 3 machines sont identiques et au repos ; l'écart 9,63 / 10,03 / 10,95 tient dans la
variance inter-run. Conclusion : **la flotte entière est posée sur la limite etcd, sans
marge**. La queue est mauvaise (p99.9 ≈ 13× la médiane → stockage réseau/mutualisé). Et ces
chiffres viennent de nœuds **vides** : le control-plane réel (`worker-5`) mesurait 6,53 ms de
moyenne, ~3× celle d'un nœud vide, donc un p99 très au-delà du seuil sous charge.
`worker-3`/`worker-5` non mesurés en `fio` (le rôle refuse au-dessus de load 1.0).

**État actuel :**
- **k3s v1.34.5**, 2 nœuds : control-plane sur `worker-5`, un agent sur `worker-3`.
  Âge du cluster : 128 jours. Ingress : `ingress-nginx` en ClusterIP derrière **Caddy**.
- `worker-3` porte en plus, **hors cluster, en Docker** : webMethods API Gateway 10.15 +
  Elasticsearch, `vault-agent`, `stoa-connect-dev`.
- **`worker-1`, `worker-2`, `worker-4` sont totalement vides** (≈ 550 Mo de RAM utilisés,
  aucun conteneur) → **24 vCPU et ~70 Go de RAM inutilisés**.
- Namespaces : `gateway-dev`, `gateway-staging` (sains), `gateway-rec` (**partiellement vivant,
  hors Git**). Contenu réel de `gateway-rec` après nettoyage du 27/07 : `kong-gateway`
  (kong 3.9), `stoa-sidecar-kong` et `echo-backend` **tournent** ; les 2 déploiements en
  CrashLoopBackOff ont été supprimés. **Aucun overlay Kustomize `rec` n'existe** : ces trois
  déploiements ne sont définis nulle part en Git (snapshot YAML pris hors Git). Son Ingress
  déclare `rec-gw` / `rec-kong` / `rec-wm.gostoa.dev`, dont **aucun n'a d'enregistrement DNS**.
- **Aucun GitOps** : `deploy/k3s-gateways/argocd.yaml` existe dans le repo mais **n'a jamais
  été appliqué** (pas de namespace `argocd`). Le cluster a été posé **impérativement** par un
  `setup.sh`, et a divergé : le script vise « w1 + w2 », la réalité est « w5 + w3 ».
- **Dette mesurée** : 2 pods en CrashLoopBackOff avec **19 447 redémarrages sur 119 jours**
  (~7/heure), causés par un namespace orphelin (`STOA_ENVIRONMENT=rec` alors que le binaire
  n'accepte que `dev|staging|prod` ; aucun overlay Kustomize `rec` n'existe) ; secret
  `ghcr-creds` disparu (créé à la main depuis un `gh auth token` expiré) → 510 126 événements
  `FailedToRetrieveImagePullSecret` en 69 jours ; images en tag `:latest`, non épinglées.
  **`node_exporter` tourne sur les 5 machines mais rien n'alerte** — 4 mois sans détection.

**Écosystème (contrainte de réutilisation) :** Gitea self-hosted, Jenkins, Ansible, Backstage,
Keycloak, HashiCorp Vault, Caddy, Prometheus/`node_exporter`, Healthchecks.io, Cloudflare
Access. Une flotte d'agents IA (« HEGEMON », daemon Go + Claude Code) tourne sur les 5 workers
via `claude-watchdog.service`, avec un hook d'auto-approbation des appels d'outils quand
`STOA_CONTABO_WORKER=1`.

**Parc secondaire — état vérifié le 2026-07-27 (résolution DNS + test de ports + TLS) :**
- **`n8n` est VIVANT et en service** : `n8n.gostoa.dev` répond HTTP/2 200 et sert l'UI n8n
  derrière un certificat Let's Encrypt valide `CN=n8n.gostoa.dev` (exp. 2026-10-02). Le
  certificat est émis **pour l'origine**, donc le proxy Cloudflare est **désactivé** :
  l'instance est **directement exposée sur Internet**. Aucun accès SSH avec la clé de flotte
  → hôte non géré depuis le poste de contrôle.
- `kong-vps` et `gravitee-vps` (OVH) : **port 22 ouvert**, mais la clé de flotte et les comptes
  `hegemon`/`debian`/`root` sont tous refusés → hôtes vivants, **hors gestion**.
- `vps-wm.gostoa.dev` : 443 écoute mais la **négociation TLS échoue** (`tlsv1 alert internal
  error`) → probablement un hôte à nous avec un certificat absent/expiré, à qualifier. Le
  webMethods réellement utilisé est celui en Docker sur `worker-3`.
- **`vault.gostoa.dev` (Infisical) : le SEUL enregistrement DNS pendant confirmé** — résolution
  OK vers une adresse de **plage Contabo, donc recyclable**, connexion 443 impossible. Risque de
  *subdomain takeover* si l'IP est réattribuée : un tiers pourrait servir ce nom et obtenir un
  certificat Let's Encrypt valide pour l'ancien magasin de secrets.
- **Impasse à signaler** : le jeton d'API Cloudflare permettant de purger cet enregistrement
  (`shared/cloudflare` → `API_TOKEN`, scope DNS:Edit, cf. `docs/SECRETS-ROTATION.md`) était
  stocké **dans l'Infisical mort**. La clé qui nettoie l'enregistrement est enfermée derrière
  l'hôte que l'enregistrement désigne.
- `rec-gw` / `rec-kong` / `rec-wm.gostoa.dev` : **aucun enregistrement DNS** (problème inverse
  — c'est l'Ingress du cluster qui déclare des noms qui ne résolvent pas).
- 4 IPs héritées (Linode/OVH) dans `known_hosts` : hôtes éteints.

**Déjà traité (ne pas re-proposer) :** `scripts/ops/vps-inventory.sh` a été réconcilié avec le
parc réel le 27/07 — les 5 workers y sont désormais de premier rang, adressés par alias SSH
(aucune IP en Git), chaque hôte secondaire porte son état mesuré, le `${VAR:?}` qui faisait
avorter tout `source` a été retiré, et une fonction `vps_verify()` sonde la flotte et **sort
non-zéro sur divergence** (garde anti-récidive). Le magasin de secrets effectif est **Vault**
(ADR-074) ; du code référence encore Infisical.

**Doctrine d'ingénierie non négociable :** GitOps déclaratif (Git = source de vérité, mutation
par PR) ; preuve live exécutable par jalon avec contre-épreuve de sabotage ; fail-closed ;
read-back-assert et détection de drift ; zéro secret en clair, pas de « secret zero » en CI ;
rebuild-from-Git intégral ; reuse-first ; licences vérifiées et citées (repo Apache-2.0).

## HYPOTHÈSES À TRANCHER (accepter / nuancer / RÉFUTER, avec preuve)

- **H1 — Reprise progressive.** Un cluster k3s de 128 jours, construit impérativement et
  divergent, peut être mis sous Argo CD **sans interruption des workloads sains** — plutôt
  que rasé et reconstruit depuis Git. *Étant donné que le rebuild-from-Git est déjà dans la
  doctrine, la reconstruction n'est-elle pas la voie la plus sûre ET la plus rapide ?*
- **H2 — Extension à 5 nœuds** sur IP publiques avec chiffrement inter-nœuds, sans réseau privé.
- **H3 — Labs éphémères.** vcluster est le bon mécanisme pour des environnements de lab
  jetables par tenant/branche sur ce sizing, plutôt que namespace + quotas.
- **H4 — n8n.** L'instance n8n **déjà en service** a un périmètre légitime et défendable ; le
  rôle d'administration du cluster ne doit PAS lui revenir. *Biais de réfutation explicite dans
  les deux sens : justifier ce qui lui reste ET ce qu'on lui retire.* Traiter en outre son
  **exposition directe sur Internet** (proxy Cloudflare désactivé) comme un fait à corriger ou
  à assumer explicitement.
- **H5 — Agents IA.** Une flotte d'agents avec auto-approbation d'outils peut opérer sur ce
  cluster sans dégrader l'auditabilité ni les gates fail-closed.

## AXES DE RECHERCHE (par impact décisionnel)

### 1. Reprendre un cluster impératif sous GitOps — sans le casser
Procédures documentées d'**adoption d'un existant par Argo CD** : `ServerSideApply`,
annotations d'adoption, `Prune: false` en phase 1, détection du diff avant activation du
self-heal, ordre d'opérations sûr. Pièges connus : ressources créées à la main que le pruning
supprime, CRD orphelins, secrets hors Git. **Argo CD vs Flux** pour ce cas précis (2 → 5
nœuds, mono-mainteneur). Comparer honnêtement deux stratégies : *(a)* adoption in-place,
*(b)* reconstruction complète depuis Git sur les 3 nœuds vides puis bascule du trafic et mise
au rebut des 2 anciens — avec le RTO, le risque et l'effort de chacune.
**Question dure : combien de temps un cluster de 128 jours non-GitOps met-il à converger, et
qu'est-ce qui, typiquement, ne converge jamais ?**

### 2. Étendre à 5 nœuds sans réseau privé
Chiffrement inter-nœuds sur IP publiques : WireGuard natif, backend WireGuard de Flannel,
Cilium (WireGuard/IPsec), Tailscale/Headscale/Netbird — **coût CPU mesuré** et impact MTU.
Durcissement de l'API server exposé (firewall/ufw, `--tls-san`, audit log, restriction du
`:6443`). Topologie recommandée sur 5 nœuds identiques : control-plane unique + 4 agents, ou
3 CP en HA + 2 agents — sachant que le cluster est reconstructible depuis Git (une HA
coûteuse est-elle justifiée si le RTO d'un rebuild est acceptable ? le quantifier).
**Contrainte issue de la mesure disque — l'etcd embarqué en HA est DÉJÀ écarté** (p99 sur la
limite à vide, queue à 24 ms, control-plane réel 3× plus lent). Ne pas rouvrir ce débat :
chercher **ce qu'on fait à la place**, et le vérifier.
- Confirmer ou infirmer par les sources : quels sont les **symptômes documentés** d'un etcd sur
  disque à p99 ≈ 10 ms (élections de leader intempestives, `apply request took too long`,
  `etcdserver: request timed out`) ? À partir de quel p99 la littérature considère-t-elle etcd
  comme inexploitable ?
- Alternative par défaut : **mono-control-plane SQLite/kine** (défaut k3s, pas de consensus
  donc pas d'amplification `fsync`). Quelles sont ses **limites réelles** — nombre d'objets,
  de nœuds, de watches, comportement en compaction — et à partir de quelle taille de cluster
  elle devient le goulot ? Est-elle tenable pour N labs éphémères créés/détruits en continu
  (churn d'objets élevé) ?
- Alternative si SQLite plafonne : **kine + Postgres externe**. Où placer le Postgres, sachant
  que le même disque lent le porterait ? Le déport réseau (latence) est-il préférable au
  `fsync` local ?
- **Quantifier le RTO d'un rebuild-from-Git** du control-plane, pour objectiver le renoncement
  à la HA plutôt que le supposer acceptable.
- **Longhorn est-il contre-indiqué ici ?** Stockage bloc répliqué = écritures synchrones
  répliquées **sur IP publiques chiffrées**, par-dessus un disque dont le p99.9 `fsync` est
  déjà mesuré à 24 ms. Les trois pénalités se cumulent.
  Comparer honnêtement à local-path + rebuild-from-Git (données de lab jetables) et à OpenEBS
  en mode local. Donner le seuil de latence en dessous duquel Longhorn est déconseillé.
- Charges elles-mêmes sensibles au `fsync` : OpenSearch/Elasticsearch (translog), Redpanda,
  WSO2. Quel plafond d'indexation attendre à ~300 IOPS synchrones et 73 MB/s séquentiels ?

### 3. Labs à la demande — le besoin cible
Isolation : **namespace + ResourceQuota + NetworkPolicy** vs **vcluster** vs **Capsule/Kiosk**.
Critères : isolation réelle (CRD, RBAC, réseau), surcoût RAM par environnement, vitesse de
création/destruction, compatibilité avec des charges qui installent leurs propres CRD.
Cycle de vie : création par PR, **TTL et garbage collection**, **hibernation/scale-to-zero**
(kube-green, sleepmode). Sachant que ~70 Go de RAM sont libres, **combien d'exemplaires
concurrents** d'une stack « WSO2 + wM 10.15 + Keycloak + OpenSearch + Redpanda + LGTM +
Microcks » tiennent, avec et sans hibernation ? Donner un chiffre, pas une fourchette molle.
Traiter le cas de **webMethods 10.15** : le laisser en Docker sur `worker-3` (état actuel) ou
le porter dans le cluster — support éditeur, licence d'évaluation (durée, hébergement
distant, obligation de non-exposition), et si les sondes k8s corrigent ou aggravent son
instabilité connue (~25 min).

### 4. Empêcher que la dette mesurée se reforme
Le cluster a accumulé 19 447 crashs et 510 126 échecs de pull **sans que personne ne le voie**,
alors que `node_exporter` tournait. Quelle est la **pile d'alerting minimale** (effort de
maintenance le plus faible) qui aurait détecté ça en moins d'une heure : Prometheus +
Alertmanager auto-hébergé, kube-state-metrics, Grafana Cloud free tier, ou réutilisation du
**Healthchecks** déjà déployé ? Quelles sont les **5 alertes k8s indispensables** (CrashLoop,
pull failure, nœud NotReady, PVC plein, cert expirant) et leurs seuils éprouvés ?
Comment empêcher structurellement les 3 causes racines constatées : **namespaces orphelins**
(TTL/labels de propriété/politique Kyverno), **secrets créés à la main qui expirent**
(External Secrets Operator vs Vault Secrets Operator vs SOPS — et l'arbitrage **Infisical vs
Vault**, deux stores qui coexistent alors que la doctrine dit Vault), **images `:latest`**
(épinglage par digest, Renovate, politique d'admission).

### 5. n8n — délimiter une instance déjà en production
Un n8n **tourne déjà**, servi publiquement, sans proxy Cloudflare devant, sur un hôte non géré
depuis le poste de contrôle. Premier livrable de cet axe : **que faut-il auditer sur cette
instance** (credentials stockés, authentification de l'UI, exécution de nœuds `Code`, exposition
des webhooks) et dans quel ordre. Puis : quel périmètre lui donner dans une chaîne d'ops
Kubernetes (déclenchement, notifications, ITSM, chatops, approbation humaine, réveil/
hibernation de lab) et où devient-il un anti-pattern (état hors Git, mutation impérative,
credentials en base, non-rejouabilité) ? **Sécurité** : nœuds `Code`/`Execute Command`,
stockage des credentials, CVE et advisories 2024-2026, durcissement, et ce qu'implique lui
confier un kubeconfig. **Licence** : la *Sustainable Use License* est-elle compatible avec un
repo Apache-2.0 et un discours « OSS souverain » — limites exactes d'usage et de
redistribution. **Comparer à ce qui est déjà là** : Backstage Software Templates, Jenkins,
Ansible, plus Argo Workflows et Temporal. Conclure par une **frontière écrite** : ce que n8n
a le droit de faire, ce qu'il n'a pas le droit de faire, et comment la frontière est *forcée*
techniquement (RBAC, réseau, absence de kubeconfig) et pas seulement documentée.

### 6. Agents IA opérant le cluster
Une flotte d'agents Claude Code tourne déjà sur les workers avec **auto-approbation d'outils**
(`sudo` refusé, mais `rm`, `git`, `curl` autorisés). Analyser ce modèle : quelles sont les
**voies d'échappement connues** d'une allowlist par premier mot de commande (substitution,
pipes, scripts intermédiaires, `git` comme primitive d'écriture arbitraire) ? Quels garde-fous
rendent sûr un agent qui produit des manifestes : Kyverno/Gatekeeper en admission,
server-side dry-run, policy-as-code, RBAC dédié à l'agent, **jamais de kubeconfig
cluster-admin**. Comment donner à un agent une **identité auditable** distincte d'un humain
(compte de service dédié, commits signés par une clé d'agent, trace jusqu'à la PR) ?
Retours d'expérience documentés d'agents LLM opérant un cluster réel, **incidents inclus**.

## EXIGENCES DE MÉTHODE

- Chaque affirmation matérielle **sourcée** : lien + date. Distinguer documentation éditeur /
  retour terrain / inférence.
- Chaque hypothèse H1-H5 marquée **PROUVÉ / RÉFUTÉ / INCERTAIN** + niveau de confiance + ce
  qui manque pour trancher.
- Pour chaque option recommandée, **au moins un mode de défaillance documenté** et sa parade.
- Signaler les sources périmées ou contradictoires plutôt que d'arbitrer en silence.
- Reuse-first : ne recommander un produit de plus qu'en justifiant pourquoi les briques
  déjà déployées ne suffisent pas.

## LIVRABLE (format imposé)

1. **Verdict en une phrase** : adopter l'existant ou reconstruire — et la condition qui décide.
2. **Décision d'architecture** en 5 lignes, défendable devant un comité (test 30 secondes).
3. **Tableau de recommandation classée** : rang, brique/approche, rôle, verdict, licence, coût
   de mise en place, coût de maintenance 18 mois, réversibilité.
4. **Architecture cible** en ASCII : 5 nœuds → cluster → GitOps → labs éphémères → n8n/agents,
   avec les **frontières de confiance** (qui détient quel secret, qui peut muter quoi).
5. **Sort de chaque hypothèse H1-H5**, une ligne, verdict + preuve.
6. **Jalons G1..Gn** séquencés par dépendance. Chacun : intitulé, ce qui est prouvé à la fin,
   **porte de preuve exécutable** (commande + assertion + contre-épreuve de sabotage), effort,
   prérequis levé. Doivent y figurer explicitement :
   - le jalon **« purge de la dette mesurée »** (namespace orphelin, secret expiré, `:latest`) ;
   - le jalon **« alerting qui aurait vu les 19 447 crashs »**, avec son test de détection ;
   - le jalon fermant la preuve **Vault Kubernetes auth pour l'identité de job Jenkins**
     (agents Jenkins = pods éphémères — décidé, codé, jamais prouvé faute de cluster) ;
   - le jalon **« frontière n8n forcée techniquement »**, incluant la fermeture de son
     exposition directe et l'audit de ce qu'il détient déjà comme credentials ;
   - le jalon **« sortie de l'impasse du jeton »** : récupérer une capacité d'écriture DNS sans
     l'Infisical mort (jeton hors coffre, ou nouveau jeton scopé), purger
     `vault.gostoa.dev`, puis **inventorier la zone de façon autoritative** via l'API
     Cloudflare — le triage par sondage de noms devinés n'est pas un inventaire ;
   - le jalon **« `gateway-rec` : dans Git ou au rebut »** — trancher entre écrire l'overlay
     manquant et le passer sous Argo, ou acter la fin du bench Arena et retirer le namespace ;
     le laisser en l'état reconduit la configuration qui a produit les 19 455 crashs.
7. **Risques et pièges** triés par gravité × probabilité, avec parade et signal de détection.
8. **Critères d'abandon** : les 3 signaux mesurables qui imposent de replier le lab hors k8s.
9. **Questions ouvertes**, avec pour chacune le test le moins coûteux (< 1 h) pour trancher.
