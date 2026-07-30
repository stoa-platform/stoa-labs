---
title: "GOAL — Du socle CI à la gateway en cluster : solder le lot 1, porter webMethods 10.15, brancher la chaîne de publication (lot 2)"
type: goal
status: "Cadré sur les preuves du lot 1 (G-a/G-b/G-c fermées le 2026-07-28). Deux décisions humaines préalables (licence wM, cible de sauvegarde). À valider avant spécification du lot 2."
date: 2026-07-28
lié: [GOAL-self-service-api-app-2026-07-09, adr-074-vault, adr-076-gitops-api-lifecycle-repo-per-project, adr-077-user-identity-to-vault-token-exchange]
note: "Le GOAL parent (self-service) reste le nord ; celui-ci construit la plateforme qui l'exécutera."
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

**TRANCHÉ le 2026-07-29 (exploitant) : pas de licence.** L'auto-redémarrage subi devient un redémarrage **contrôlé** : cron root sur worker-3, `docker restart wm-dev-apigateway` toutes les 20 min — avant l'expiration, à instants connus (`ansible/wm-restart-cron.yml`, posé et validé le jour même). Même indisponibilité brève, mais prévisible et datable. **F3 est débloqué**, avec la conséquence assumée : le pod cluster portera le même motif (redémarrage périodique piloté — à intégrer à la spéc F3, pas à subir), et la « panne portée en cluster » est désormais un cycle d'exploitation documenté, pas une surprise.

---

## Jalons (F1…F5) — chacun avec sa porte de preuve et sa contre-épreuve

### F1 — Déclenchement par push + statut de commit *(solde le critère du lot 1)*

Câbler le webhook Gitea → Jenkins (`generic-webhook-trigger`, déjà dans l'image ; `ALLOWED_HOST_LIST` déjà restreint au Service Jenkins) et la remontée du statut de commit dans Gitea.
**Porte F1 :** un `git push` sur `ci/probe` déclenche le build **sans action humaine** ; le commit porte un statut vert dans Gitea.
**Contre-épreuve :** casser le Jenkinsfile → le commit porte un statut **rouge**. Un statut qui ne rougit jamais ne prouve rien.
**État : FERMÉ le 2026-07-29.** Porte et contre-épreuve vertes — builds 7 (vert), 8 (rouge, sabotage) et 9 (vert, restauration) déclenchés sans action humaine, statuts `jenkins/probe` correspondants dans Gitea, puis **re-mesuré et rejoué par un quatrième push indépendant** (build 10, statut vert sur `f1e0f57`). Preuve détaillée : `docs/superpowers/plans/2026-07-28-f1-webhook-statut.md`, § « Preuve d'exécution ». ~~Écart Vault (détention des parts improuvée)~~ **levé le 2026-07-29** : ré-initialisation propre par `vault-bootstrap.sh` déroulé d'une traite **par l'exploitant** (l'agent en est bloqué par permission, à raison) — nouvelles parts dans `/root/vault-init-ci.txt` (root, 600, jamais affichées, validées par le descellement même du script), nouveau PAT `probe-status` re-frappé, et **re-preuve F1 complète** : push `b5459f58` → build 11 déclenché sans action humaine → statut `jenkins/probe: success` posé via le nouveau PAT. Reste à l'exploitant : récupérer les parts hors ligne puis `sudo shred -u /root/vault-init-ci.txt`.

### F2 — Sauvegarde réellement hors-nœud *(tranche la question Q2 du lot 1)*

Aujourd'hui les trois PVC (gitea, vault, jenkins) **et** leurs archives vivent sur worker-5 : une panne disque y perd données et copies. Candidat naturel : **worker-2** — exclu du cluster par l'isolation L2 Contabo (w1↔w2), mais joignable depuis worker-4/worker-5 (matrice mesurée du 2026-07-27), déjà identifié comme « disponible pour toute charge n'exigeant pas l'appartenance au cluster ». À vérifier avant d'industrialiser : joignabilité SSH w5→w2 et espace disque. En même temps : rotation des `pvc-*.tar.gz`, quarantaine `.suspect` des archives dont la garde post-archive a rougi, et fenêtre de synchronisation Argo (auto-sync suspendu pendant la sauvegarde — le contournement actuel est une garde, pas une solution).
**Porte F2 :** archives des trois PVC lisibles sur l'hôte cible, **distinct du nœud porteur des données**.
**Contre-épreuve :** exercice de restauration depuis cet hôte (l'utilisateur `ci` retrouvé dans le `gitea.db` restauré, comme au lot 1).
**État : FERMÉ le 2026-07-29.** Cible worker-2 (joignabilité et 361 Go mesurés avant d'écrire une ligne, comme exigé plus bas) ; deux runs verts consécutifs, trois archives lisibles sur worker-2 avec empreintes vérifiées, restauration exercée depuis worker-2 (`backup-restore-drill.yml`, utilisateur `ci` retrouvé). Rotation par claim, quarantaine `.suspect`, fenêtre de sync Argo (capture → patch → restauration) livrées. La porte est **encodée dans le rôle** : cible = nœud porteur ⟹ échec fermé (contre-épreuve de sabotage jouée). **Déviation assumée :** Vault n'est **pas** quiescé (il redémarrerait scellé alors que la détention des parts — point prioritaire du handoff F1, toujours ouvert — n'est pas prouvée) ; son PVC est archivé à chaud sous garde d'empreinte avant/après, et le rôle vérifie que Vault reste descellé en sortie. `backup_hot_workloads` à vider une fois le point Vault levé. Preuve : `docs/superpowers/plans/2026-07-29-f2-sauvegarde-hors-noeud.md`, § « Preuve d'exécution ».

### F3 — webMethods 10.15 dans le cluster *(le cœur du lot 2)*

Image poussée dans le **registre Gitea** (pas Docker Hub), manifestes par **PR sur `stoa`**, namespace dédié, Elasticsearch attenant. Contraintes mesurées à respecter : disque faible en `fsync` (prudence sur ES — c'est lui le composant sensible, pas la RAM : ~87 Go libres) ; **anti-affinité worker-3** tant que la prod Docker y tourne (le motif PR #2819 du lot 1, réutilisé) ; la dette ROOT_URL/realm OCI du lot 1 se repense **ici** (un ROOT_URL résoluble partout, sans casser les accès registre depuis les pods).
**Porte F3 :** `/rest/apigateway` répond depuis un pod du cluster ; les données survivent à la suppression du pod (PVC).
**Contre-épreuve :** pod tué en pleine vie → revient seul, config intacte. Et l'admin REST reste **inaccessible** hors du cluster (aucun Ingress — la doctrine du lot 1 tient).
**État : FERMÉ le 2026-07-29.** Porte et contre-épreuves vertes le jour même du déblocage : ns `wm` (PR stoa #2821/#2822, mergées par l'exploitant), ES 8.13.4 en StatefulSet sur worker-4 (nœud mesuré, PVC 10 Gi), gateway en Deployment sans volume (l'état vit dans ES), images **par digest** depuis le registre Gitea (PULL-OK worker-4, tag inexistant → NotFound), cycle trial **piloté** porté avec le pod (CronJob `*/20`, `restart-pilote: 200`, 3 jobs à 20 min d'intervalle observés). Porte : `GET /rest/apigateway/health` → 200 **depuis un pod du cluster** ; marqueur `f3-proof-2026-07-29` créé puis relu **après suppression simultanée des deux pods** (retour autonome en ~3 min 30) — la donnée est portée par le PVC ES. Contre-épreuves : aucun Ingress dans `wm`, ClusterIP only, 5555/9072/9200 fermés de l'extérieur (6/6), worker-3 intact toute la session. Dette realm OCI **requalifiée et bornée** (ROOT_URL inchangé — nom natif du Service, résoluble des pods ; ClusterIP gitea épinglée en Git). Preuve détaillée : `docs/superpowers/plans/2026-07-29-f3-webmethods-cluster.md`, § « Preuve d'exécution ». Reste de la passe : PR #2823 (digests gitea/jenkins — **Vault exclu**, un restart le rendrait scellé) à merger hors fenêtre de build ; F3 démarre **vide** (migration des 109 Mo de worker-3 = F5, double-run assumé).

### F4 — La chaîne de publication réelle *(E1 du GOAL parent, câblé sur la plateforme)*

Un pipeline Jenkins (image `jenkins-go`, `labctl` embarqué) publie une API sur la gateway cluster : spec OpenAPI poussée dans un repo Gitea d'équipe → build déclenché (F1) → identifiants wM obtenus **depuis Vault par identité de pod** (mécanique G-c, prouvée) → `POST /apis` + `POST /assets/team`.
**Porte F4 :** push d'une spec → API visible, scopée à sa team, **zéro secret statique** dans Jenkins (l'assertion `credentials.xml` absent du lot 1, rejouée).
**Contre-épreuve :** rôle Vault révoqué → la publication échoue **fermée**, statut rouge dans Gitea (F1) ; et le membre d'une autre team ne voit pas l'API (l'isolation Teams prouvée au spike #1).
**État : FERMÉ le 2026-07-29.** Porte et **deux** contre-épreuves vertes. Chaîne réelle : push d'une spec sur `banking-demo/accounts-api` (Gitea) → webhook → build `publish-accounts` **sans action humaine** → pod agent 2 conteneurs (SA `jenkins-agent`) → **login Vault par identité de pod dans le conteneur qui consomme** (API HTTP ; aucun secret ne transite entre conteneurs) → `labctl apply` → `accounts-read 1.0.0` **`isActive: true`** sur `wm-apigateway.wm.svc:5555` → `POST /assets/team` → relecture `['Administrators','banking-demo']` → statut `jenkins/publish: success`. **Zéro secret statique** rejoué (`credentials.xml` absent). Contre-épreuve **isolation** : même `GET /apis`, `svc-banking-demo` → `['accounts-read']`, `svc-insurance-demo` → `No APIs found`. Contre-épreuve **Vault** : rôle `jenkins-agent` révoqué (quorum) → build **FAILURE** `invalid role name`, **API inchangée sur la gateway** (échec fermé, aucune mutation) → rôle restauré → build **vert** de nouveau. Le **spike Teams** a corrigé quatre shapes que le dépôt tenait pour acquis (`assetType` obligatoire sinon 200 no-op ; UUID exigés pour users/groupes/teams ; appartenance au groupe `API-Gateway-Providers` requise pour l'admin REST ; configId `extended`). Preuve détaillée : `docs/superpowers/plans/2026-07-29-f4-chaine-publication.md`, § « Preuve d'exécution ». Reste de la passe : PR stoa **#2824** (NetworkPolicy ES) à merger par l'exploitant, puis sa contre-épreuve.

### F5 — Bascule et décommission

Caddy (worker-3) repointe le trafic concerné vers le cluster (le pattern `cutover.yml` : une ligne de Caddyfile, pas de DNS) ; les conteneurs Docker `wm-dev-*` de worker-3 s'éteignent après période de recouvrement.
**Porte F5 :** le trafic public est servi par la gateway cluster ; worker-3 ne porte plus que Caddy.
~~**Contre-épreuve :** rollback = une ligne de Caddyfile, exercé une fois avant la décommission définitive.~~
**Contre-épreuve CORRIGÉE (2026-07-30) :** rollback = **restauration de la sauvegarde horodatée**, un geste, exercé une fois avant la décommission définitive. La formulation « une ligne de Caddyfile » était **inexacte** : elle ne vaut que pour une substitution de cible. Or F5 change la **forme** du bloc (data-plane seul, admin fermé), donc un `replace` d'un jeton ne peut pas l'exprimer. La propriété qui compte — retour arrière immédiat et **vérifié** — est conservée (spéc F5 § D4).

**État : FERMÉ le 2026-07-30.** Les trois portes retenues et leurs contre-épreuves sont vertes, relues **après** la décommission — la vraie question n'étant pas « a-t-on retiré » mais « le public dépendait-il de ce qu'on a détruit ».

| Porte | Mesure |
|---|---|
| **P-a** | `https://dev-wm.gostoa.dev/gateway/accounts-read/1.0.0/accounts` → **200** + corps de `backend-dev`. **Première invocation data-plane de toute la plateforme** (`transactionalevents` de worker-3 était à 0 depuis toujours). |
| **P-b** | Les cinq chemins d'admin → **404** (contre `401`/`200`/`302`/`200`/`302` au relevé T0). Et **200 depuis un pod du cluster** : la surface est retirée du public, pas supprimée. |
| **P-c** | worker-3 : **Caddy et son agent k3s seuls**. Aucun conteneur Docker, crontab root vide, volume `webmethods-dev_es-dev-data` retiré. Le ping d'uptime `*/1` de `hegemon` préservé. |
| Garde flotte | Les **quatre** noms `*-k3s.gostoa.dev/health` → 200, avant et après. |

**Contre-épreuve tenue dans les deux sens** : la restauration *automatique* après une porte rouge (sabotage à code impossible : écriture, porte rouge, `rescue`, vérification que l'ancien chemin sert) **et** la restauration *explicite* demandée par un exploitant, dont l'assertion « empreinte d'avant-bascule retrouvée à l'identique » a mordu. Plus un troisième sabotage : cible amont fausse → **refus d'écrire**, `changed=0`. Le rollback a été exercé **avant** tout retrait — après `docker rm`, il n'y aurait plus eu de cible de retour.

**Prérequis soldés en route** : ClusterIP `wm-apigateway` épinglée en Git (sans quoi une recréation du Service produirait des 502 publics sans alerte) ; backend réel `backend-dev` posé en cluster ; PVC ES du ns `wm` sauvegardé hors-nœud et **relu** ; archive froide de worker-3 sur worker-2, vérifiée par empreinte **et par extraction réelle** avant tout retrait.

**Cycle trial mesuré côté public, sur deux cycles : 120 s et 235 s** — dispersion d'un facteur 2, donc un **intervalle**, pas un point : ~85 % de disponibilité. Le chiffre de 150 s inscrit dans `stoa` par la PR #2825 est **faux pour le data-plane** : il avait été mesuré sur `/rest/apigateway/health`, qui remonte ~85 s **avant** que l'API soit invocable. Un client voit plus long qu'une sonde de santé. À corriger dans `stoa` (dette ci-dessous).

Preuve détaillée : `docs/superpowers/plans/2026-07-30-f5-bascule-decommission.md`, § « Avancement » et sections T1→T8. Spéc : `docs/superpowers/specs/2026-07-30-f5-bascule-decommission-design.md`.

**Trois requalifications du jalon, par la mesure** (actées plutôt que contournées) :
- **Aucun trafic public d'API à préserver** : `transactionalevents` de worker-3 = 0 document ; les seuls accès externes tracés étaient 29 événements d'admin depuis 3 IP de l'exploitant. D'où une porte formulée en **invocation réelle** plutôt qu'en « le trafic est servi », qu'une gateway ne servant rien aurait tenue.
- **La « migration des ~109 Mo d'ES » n'était pas un sujet** : 92 % de logs d'audit produits par le cycle de redémarrage, et 7 APIs de spike sans consommateur. **Décision D6 : archiver, ne rien restaurer** — restaurer un `tar` contournerait la chaîne GitOps qu'on venait de prouver (ADR-076). L'archive du cluster pèse 4,7 Mo contre 108 Mo côté worker-3 : l'écart mesure ce que valait vraiment ce « volume ».
- **Un durcissement, non prévu au jalon** : `/rest/apigateway/apis` rendait **401 publiquement** — l'admin REST wM était sur l'Internet ouvert derrière un basic auth, alors que la contre-épreuve F3 avait mesuré 6/6 refus pour le cluster. Basculer Caddy à l'identique l'aurait **re-publié en silence**. F5 ne publie que `/gateway/*`.

**Le point d'amont est tranché par la mesure exigée ci-dessous** : `curl <clusterIP>:5555/rest/apigateway/health` **depuis l'hôte** worker-3 → **200 en 18,7 ms**. Voie 1 (ClusterIP épinglée) acquise ; ni Ingress ni NodePort.

---

## Nommage et exposition — inventaire des noms (F1 → F5)

**Aucun jalon F1–F5 ne crée d'enregistrement DNS public.** C'est une décision, pas un manque : le jeton Cloudflare `DNS:Edit` est enfermé dans l'Infisical mort (`docs/superpowers/specs/2026-07-28-socle-ci-cluster-design.md:66-67`) et la doctrine §4.1 du lot 1 (`:99-110`) refuse tout Ingress sur le socle. Tous les noms créés par le lot 2 sont **internes au cluster** ; la bascule F5 se fait **sans toucher au DNS** (`ansible/cutover.yml:17-18`, `roles/caddy_cutover/defaults/main.yml:7-14`).

### Les noms internes (faits mesurés, F1 → F4)

| Rôle | Nom | Exposition |
|---|---|---|
| Dépôt projet, webhook, realm OCI du registre | `gitea.ci.svc.cluster.local:3000` — ClusterIP **épinglée en Git** (`10.43.60.211`) | ClusterIP + NodePort 30300 |
| Pull d'image par containerd | `localhost:30300/ci/<image>@sha256:…` — containerd tourne au niveau **hôte** et ignore CoreDNS ; le realm renvoyé par le registre (`gitea.ci.svc.cluster.local:3000`) est résolu par un shim `/etc/hosts` → ClusterIP (rôle `registry_config`) | NodePort, **fermé de l'extérieur** (ufw : 22/30080/30443 seulement) |
| Secrets par identité de pod | `vault.ci.svc.cluster.local:8200` | ClusterIP |
| Cible du webhook (`ALLOWED_HOST_LIST`) | `jenkins.ci.svc.cluster.local:8080` | ClusterIP |
| Admin REST **et** data-plane wM | `wm-apigateway.wm.svc:5555` | ClusterIP |
| Console wM | `wm-apigateway.wm.svc:9072` | ClusterIP |
| Data store de la gateway | **`elasticsearch:9200`** — le Service du ns `wm` s'appelle `elasticsearch` (nom court = zéro delta avec le compose worker-3) ; le StatefulSet et l'Application Argo s'appellent `wm-elasticsearch`, le pod `wm-elasticsearch-0`, le label `app=wm-elasticsearch`. **Ne pas confondre : `wm-elasticsearch.wm.svc` ne résout pas.** | ClusterIP |
| Backend de l'API publiée (F4) | `backend-dev.wm.svc.cluster.local:8080/accounts` — **nom honnête, aucun backend réel derrière** : l'invocation data-plane appartient à F5 | — |
| Nom public existant servi par Caddy (worker-3) | `dev-wm.gostoa.dev` → worker-3 (200 avec le Host réel, mesuré au lot 1) | public, **préexistant** |

**Hors périmètre faute de DNS :** `rec-gw` / `rec-kong` / `rec-wm.gostoa.dev` sont déclarés par des Ingress historiques mais **n'ont aucun enregistrement** (`RESEARCH-cluster-k3s-contabo-2026-07-27.md:104-105`) ; `vps-wm.gostoa.dev` est un hôte à qualifier dont le TLS échoue et qui n'est pas le webMethods réellement utilisé (`:93-95`). Les faire servir exigerait des enregistrements **nouveaux**, donc le jalon **G0** du rapport cluster (« sortie de l'impasse du jeton + inventaire DNS autoritatif », `RAPPORT-cluster-k3s-contabo-2026-07-27.md:252-268`) — qui n'appartient à aucun jalon F.

### Le point d'amont de F5 : NodePort, Ingress, ou ClusterIP ?

F5 ne change pas de nom, il change une **cible amont** dans le Caddyfile. Les trois voies ne se valent pas :

1. **ClusterIP épinglée — voie recommandée.** Caddy (worker-3) → `<clusterIP wm-apigateway>:5555`, adresse déclarée en Git comme celle de gitea. worker-3 **est** un nœud du cluster, et le chemin hôte → ClusterIP est **déjà prouvé en service** : c'est exactement ce que fait containerd pour résoudre le realm du registre via le shim `registry_config`. Zéro Ingress, zéro NodePort, zéro règle ufw, doctrine du §4.1 intacte, rollback toujours d'une ligne.
2. **Ingress dans `wm`.** 30080/30443 sont déjà ouverts par ufw, donc c'est techniquement le chemin le plus court — mais cela **casse frontalement** la contre-épreuve F3 (« aucun Ingress dans `wm` », `wm` en ClusterIP only, 6/6 refus mesurés). À ne faire que par **exception explicite** au §4.1, jamais en contournement silencieux (même exigence qu'ADR-080 pour un webhook entrant).
3. **NodePort dédié sur 5555 — à refuser.** Il faudrait **ouvrir 5555 dans ufw sur les IP publiques de tous les nœuds** (un NodePort répond sur chaque nœud) : c'est-à-dire exposer un admin REST webMethods sur l'Internet ouvert, exactement le défaut n8n que le rapport dénonce.

**À mesurer avant de trancher** (le lot 1 a appris à tester d'abord, cf. `hostPath` vs `local`) : `curl <clusterIP>:5555/rest/apigateway/health` **depuis l'hôte worker-3** — pas depuis un pod. Si ça répond, la voie 1 est acquise ; si ça échoue, le choix remonte à l'exploitant entre l'exception §4.1 (voie 2) et l'abandon de la bascule publique.

**Note à conserver :** la note de sécurité de `roles/caddy_cutover/defaults/main.yml:44-51` (« le trafic Caddy → ingress traverse l'Internet public EN CLAIR ») visait la bascule ancien k3s → nouveau k3s, où Caddy était **hors** du cluster cible. Elle **ne s'applique pas** à F5 : worker-3 porte Caddy *et* un agent du cluster, le saut réseau n'existe pas. De même, `caddy_verify_hosts` (`:29-33`) liste les quatre noms `*-k3s.gostoa.dev` de cette bascule-là — F5 réutilise le **pattern**, pas la liste, et devra re-paramétrer les noms wM réels et le `caddy_verify_path`.

---

## Dette du lot 1 à solder en route

| Dette | Où actée | Jalon porteur |
|---|---|---|
| ~~Realm OCI /etc/hosts→ClusterIP (ROOT_URL)~~ | plan lot 1, § Dette actée | **requalifiée et bornée — F3, 2026-07-29** (ROOT_URL = nom natif du Service, résoluble des pods ; résidu « liaison mutable » soldé par clusterIP épinglée en Git ; shim /etc/hosts hôtes conservé, vérifié par `registry_config`) |
| ~~Sauvegardes co-localisées worker-5 + rotation + quarantaine~~ | plan lot 1 + revue finale | **soldé — F2, 2026-07-29** |
| ~~Webhook + statut de commit~~ | plan lot 1, écart assumé | **soldé — F1, 2026-07-29** |
| Rotation du matériel de descellement Vault (`operator rekey` + révocation du jeton racine) | incident F1 du 2026-07-29 | à trancher avec F2 (sauvegarde/restauration) |
| ~~Épinglage par digest des 3 images du socle~~ | revue finale, follow-up | **gitea+jenkins soldés — PR #2823 mergée le 2026-07-29** (pods roulés, digests vérifiés en service, registre 401 OK, vault-0 non touché) ; **Vault seul reporté** — un restart le rendrait scellé, à épingler en fenêtre exploitant avec descellement dans la foulée |
| ~~Rotation du mot de passe bootstrap `ci`/`ci-bootstrap`~~ | rapports lot 1 | **soldée — F4, 2026-07-29** (rayon d'action mesuré d'abord : tirages d'images anonymes, aucun `imagePullSecrets` ; ancien mdp → 401, nouveau → 200, nouveau mdp root-only sur worker-1 ; chaîne re-prouvée verte après rotation) |
| JCasC (cloud + jobs Jenkins versionnés) | plan lot 1, écart assumé | **re-actée F4** : déclencheur précis = *prochaine reconstruction de `jenkins-go`* (le plugin manque à l'image ; l'ajouter hors fenêtre exploitant ferait dériver les plugins) |
| Intégration Keycloak / échange JWT (ADR-077) | spéc lot 1, exclusions | après F4 |
| ~~Rétention des builds Jenkins~~ | question ouverte Q1 | **soldée — F4, 2026-07-29** (`buildDiscarder` 25 builds sur `probe` et `publish-accounts`) |
| `team:` natif dans labctl (moteur unique ADR-076) | spéc F4 § D1 | même déclencheur que JCasC (le binaire vit dans l'image) |
| ~~Contre-épreuve NetworkPolicy ES écrite sur un nom qui n'existe pas~~ | plan F4, PR #2824 | **SOLDÉE le 2026-07-30**, avec le contrôle qui manquait. Depuis un pod `ci` : `elasticsearch.wm.svc` **résout** (`10.43.210.198`) **et** la connexion au 9200 est **refusée** (`000`). Les deux ensemble prouvent un **refus réseau**, pas un `NXDOMAIN` — ce que la formulation fautive (`wm-elasticsearch.wm.svc`, inexistant) n'aurait jamais pu établir : elle aurait verdi sur une faute de frappe. La policy mord. |
| ~~Fichier d'init Vault encore sur worker-1 (`/root/vault-init-ci.txt`)~~ | F1 → F4 | **SOLDÉ le 2026-07-30** (exploitant) : parts récupérées hors ligne, empreintes comparées avant effacement, puis `shred -u`. Vérifié derrière : le fichier est absent **et Vault est resté descellé** — le geste n'a pas dégradé le socle. **Conséquence à retenir :** les gestes quorum redeviennent **interactifs**, et le `ssh -t` + `read` ne fonctionne pas dans le harnais agent — prévoir un terminal humain. |
| ~~Keepalive hegemon `*/25` en doublon du cron root, « ~5 min de service perdues par heure »~~ | handoff F4, point 4 | **LA DETTE N'EXISTE PAS** — vérifié au relevé T0 de F5 (2026-07-30) : crontab `root` = **une seule** entrée (`docker restart wm-dev-apigateway` + son marqueur Ansible `#Ansible: wm-dev-apigateway-restart-trial` — le « 2 lignes » qu'un `grep -c` compte est marqueur + entrée) ; crontab `hegemon` = un **ping d'uptime `*/1`** vers `status.gostoa.dev`, **étranger à webMethods**, qui surveille l'hôte et **doit rester** ; rien dans `/etc/cron.d` ; aucun timer systemd. Le point 4 du handoff F4 était **inexact**. Consigné comme erreur corrigée, pas comme dette soldée — retirer une dette sans dire qu'elle n'existait pas laisserait croire qu'on l'a réglée. |
| Sauvegarde du ns `wm` (le PVC ES n'avait **aucune** copie) | handoff F4, point 5 ; prérequis bloquant de F5 | **code livré** (`backup_pvc_namespaces: [ci, wm]`, les 3 Applications du ns `wm` dans la fenêtre Argo) ; **run en attente du merge de #2825** — la capture d'état échoue fermée si l'Application `wm-backend-dev` n'existe pas. Deux bugs du rôle corrigés au passage (voir ligne suivante). |
| Deux bugs de `cluster_backup` révélés par l'ajout du ns `wm` | F5, 2026-07-30 | **soldés** : l'attente de quiescence et le contrôle post-archivage listaient **tous** les pods, y compris ceux de Job en `Succeeded` — la première n'aurait jamais convergé, le second aurait mis en **quarantaine et rejeté une archive saine**. Corrigés par `--field-selector`, et les CronJobs des namespaces sauvegardés sont désormais suspendus pendant la fenêtre puis remis dans leur **état capturé**. Non-régression du chemin `ci` établie par la mesure (aucun pod terminal, aucun CronJob dans ce ns). |
| **Chiffre faux du cycle trial dans `stoa`** : la PR #2825 inscrit « 150 s » et « 87,5 % » dans le commentaire de `deploy/bootstrap/wm/apigateway/cronjob.yaml`. Mesuré ensuite **côté data-plane public sur deux cycles : 120 s et 235 s**, soit ~85 % — les 150 s portaient sur `/rest/apigateway/health`, qui remonte ~85 s **avant** que l'API soit invocable. | F5, T8 (2026-07-30) | **à corriger par une PR `stoa`** (commentaire seul). Laisser un chiffre connu comme faux est pire que l'estimation qu'il remplaçait : il se présente comme une mesure. Formulation juste : « 120–235 s mesurées côté data-plane public, dispersion d'un facteur 2, ~85 % ». |
| **`handle_errors` ne couvre pas tout** : sur 355 s de coupure mesurées, 340 s rendent bien le 503 explicite, mais **10 s rendent 500** (webMethods répond lui-même 500 pendant son arrêt et Caddy relaie ce 5xx amont — `handle_errors` ne capture que les erreurs *de Caddy*) et **5 s ne rendent rien** (délai de connexion dépassé). | F5, T8 | **à connaître, pas à maquiller.** Le couvrir exigerait d'intercepter les 5xx amont (`handle_response`), ce qui masquerait aussi de vraies erreurs applicatives de la gateway. |
| **`wm-elasticsearch` restera `OutOfSync` pour toujours** — l'écart porte sur des défauts ajoutés par Kubernetes dans `volumeClaimTemplates` (`apiVersion`, `kind`, `volumeMode: Filesystem`, `status`), or ce champ est **immuable** sur un StatefulSet : Argo ne peut pas réconcilier. Conséquence : pour cette Application, « OutOfSync » **ne signale plus rien** — c'est une alerte allumée en permanence, donc une alerte qu'on apprend à ignorer. | relevé pendant F5 (T1), **préexistant** et `Healthy` | **à corriger hors F5, une ligne** : déclarer `volumeMode: Filesystem` dans Git, ou poser un `ignoreDifferences` sur l'Application. Consigné surtout pour qu'on ne l'impute pas à la sauvegarde du ns `wm`. |
| **Spike : deux répliques wM 10.15 à redémarrages décalés sur un ES partagé** (A à :00/:20/:40, B à :10/:30/:50) — donnerait une disponibilité continue au lieu de 87,5 % | spéc F5 § D9 | **dette nouvelle, hors jalons F** : exige un vrai clustering (Terracotta/Ignite) **non instruit**. Rien n'a été tenté en F5 — l'improviser juste avant de détruire l'unique autre copie des données serait exactement la faute que ce dépôt évite. |

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
