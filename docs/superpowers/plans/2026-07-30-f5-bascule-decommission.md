# F5 — Bascule et décommission : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal :** `https://dev-wm.gostoa.dev/gateway/accounts-read/1.0.0/accounts` rend
**200 + JSON** servi par la gateway webMethods **du cluster**, l'admin REST cesse
d'être public (401 → 404), et worker-3 ne porte plus que Caddy — portes et
contre-épreuves jouées et consignées.

**Architecture :** un backend réel (`backend-dev`) est posé dans le ns `wm` pour
rendre invocable l'`accounts-read` déjà publiée par F4 ; la ClusterIP de
`wm-apigateway` est épinglée en Git ; Caddy sur worker-3 est reconfiguré par un
nouveau rôle Ansible `caddy_wm_cutover` (template complet du Caddyfile + garde
d'empreinte + `caddy validate` + porte vérifiée depuis le poste + restauration
automatique) pour ne publier que `/gateway/*` ; puis les conteneurs Docker
`wm-dev-*` sont archivés à froid vers worker-2 et retirés.
Spéc : `docs/superpowers/specs/2026-07-30-f5-bascule-decommission-design.md`.

**Tech stack :** k3s v1.34.5 (ns `wm`), Argo CD (ServerSideApply, selfHeal),
wM API Gateway trial 10.15, Elasticsearch 8.13.4, Caddy (systemd, worker-3),
Ansible (`ansible/`, inventaire par alias SSH), Docker (worker-3, legacy),
gh CLI (PR `stoa-platform/stoa`), ssh (alias worker-1..5).

## Global Constraints

- **Règle de sûreté n°1 — F5 INVERSE celle de F1–F4.** worker-3 **est** la cible
  cette fois. Ce qui doit rester intact, c'est **le TLS de toute la flotte** :
  Caddy y termine les certificats de tous les noms. Après **chaque** écriture
  dans le Caddyfile, vérifier depuis le poste qu'un nom **non concerné** répond
  comme avant :
  `curl -s -o /dev/null -w '%{http_code}\n' https://dev-gw-k3s.gostoa.dev/health`
  (attendu : identique à la valeur relevée en T0). Un durcissement de `dev-wm`
  qui casserait un autre nom est une régression, pas une livraison.
- **Fenêtre du cycle trial : 150 s d'indisponibilité toutes les 20 min**
  (mesuré, cf. spéc § Terrain), aux minutes ~0/20/40 + ~2,5 min. **Ne jamais
  conclure sur un code non-200 sans avoir vérifié où on se trouve dans le
  cycle.** Toute assertion sur le data-plane est précédée d'une attente active
  de disponibilité (motif F4, étage « Attendre la gateway »).
- **Aucun secret affiché** : toute valeur sensible → fichier root-only du nœud
  (`umask 077`), jamais stdout, jamais dans l'argv d'un `ssh`. Les scripts
  partent en `scp` et s'exécutent par `ssh worker-N 'sudo bash /tmp/<script>'`.
- **Gestes bloqués par le classifieur** (merge de PR) : préparer, faire exécuter
  par l'exploitant via `!`, vérifier derrière.
- Accès cluster : `ssh worker-1 'sudo k3s kubectl -n <ns> …'`. Le kubectl local
  du poste pointe un **autre** cluster (sto-k8s OVH) — ne jamais l'utiliser.
- Checkout `~/stoa-platform/stoa` **en retard** (`1edada9b` vs `origin/main`
  `fd2f356f`) : travailler dans un worktree neuf basé sur `origin/main`.
- **Frontière des dépôts** : tous les commits de ce plan vont dans `stoa-labs`
  (ce dépôt). Seule T1 écrit dans le dépôt produit `stoa`.
- **Aucun Ingress, aucun NodePort, aucune règle ufw nouvelle** ; jamais `Force`
  dans Argo CD.
- **Aucune restauration d'état ES** vers le cluster (spéc § D6).
- Commits : conventionnels, français, `-s` (DCO) ; PR `stoa` en squash-merge,
  rebase si `BEHIND`.
- Les adresses `10.43.0.0/16` sont le CIDR de service du cluster (non routable) :
  les écrire est admis, contrairement aux IP publiques de la flotte.
- **Ordre non négociable** : le rollback est exercé **avant** tout retrait
  (T6 avant T7). Après `docker rm`, il n'existe plus de cible de retour.

---

## Avancement — session du 2026-07-30

| Tâche | État | Reste |
|---|---|---|
| **T0** Terrain | ✅ **fait** — voie 1 confirmée (200 en 18,7 ms depuis l'hôte), 2 écarts de doc élucidés | — |
| **T1** PR `stoa` | ✅ **FAIT** — PR **#2825 mergée** par l'exploitant à 08:30:07Z (`dc2cd17b`), Application `wm-backend-dev` appliquée, `Synced/Healthy`, pod prêt en 12 s. **ClusterIP `10.43.227.71` inchangée après re-sync** → l'épinglage a porté sur la valeur vive | — |
| **T2** Data-plane interne | ✅ **PORTE VERTE** — `/gateway/accounts-read/1.0.0/accounts` sur la ClusterIP → **200 + JSON de `backend-dev`**, là où elle rendait **500** avant | — |
| **T3** Sauvegarde ns `wm` | ✅ **FAIT** — run vert (`ok=52 changed=19 failed=0`), archive du PVC ES **relue sur worker-2**, Vault resté descellé | — |
| **T4** Rôle de bascule | ✅ **FAIT — les DEUX sabotages verts.** Sabotage 1 : cible fausse → refus d'écrire, `changed=0`. **Sabotage 2 : le chemin `rescue` est prouvé en conditions réelles** (détail ci-dessous) | — |
| **T5** Bascule + P-a/P-b | ✅ **PORTES P-a ET P-b VERTES** — bascule jouée par l'exploitant le 2026-07-30, `ok=15 changed=3 failed=0` (détail ci-dessous) | — |
| **T6** Contre-épreuve rollback | ⏸ le chemin `rescue` est déjà prouvé (sabotage 2) ; reste le chemin **explicite** `-e wm_cutover_rollback=true` | écriture Caddy — geste exploitant |
| **T7** Décommission + P-c | ⛔ **après T6, jamais avant** | `docker stop/rm` sur worker-3 — geste exploitant |
| **T8** Re-mesure + consignation | ⛔ en aval | — |

### T5 — les portes, mesurées

**P-a — l'invocation data-plane par le nom public :**

```
$ curl https://dev-wm.gostoa.dev/gateway/accounts-read/1.0.0/accounts
{"backend": "backend-dev.wm.svc.cluster.local",
 "receivedPath": "/accounts/accounts",
 "accounts": [{"id": "ACC-001", …}, {"id": "ACC-002", …}]}
HTTP 200
```

**P-b — le durcissement, avant/après, nom par nom :**

| Chemin | AVANT (T0) | APRÈS |
|---|---|---|
| `dev-wm.gostoa.dev/rest/apigateway/apis` | **401** | **404** |
| `dev-wm.gostoa.dev/rest/apigateway/health` | 200 | **404** |
| `dev-wm.gostoa.dev/apigatewayui/` | 302 | **404** |
| `dev-wm.gostoa.dev/` | 200 | **404** |
| `dev-wm-ui.gostoa.dev/` | 302 | **404** |
| `dev-gw-k3s.gostoa.dev/health` (garde flotte) | 200 | **200** |

L'admin REST de webMethods n'est plus sur l'Internet ouvert. Et ce n'est pas une
casse : **depuis un pod du cluster, `/rest/apigateway/apis` rend toujours 200**.
La surface a été retirée du public, pas supprimée.

**La preuve indépendante — et la correction d'une assertion fausse de ce plan.**

Le Step 6 prévu affirmait que `transactionalevents` passerait à > 0. **C'est
faux, et l'erreur est dans ce plan, pas dans la bascule** : mesuré après les
invocations, `count: 0`. L'index existe, et `errorevents: 2` /
`lifecycleevents: 117` montrent que l'écriture ES fonctionne — ce type
d'événement exige simplement une **politique de journalisation d'invocation** sur
l'API, que `accounts-read` (publiée avec des politiques minimales par F4) n'a
pas. L'assertion supposait un comportement par défaut de webMethods sans l'avoir
vérifié.

La preuve indépendante existe, et elle est **plus forte** que celle prévue —
prise au bout de la chaîne plutôt qu'en son milieu :

```
$ kubectl logs -n wm deploy/backend-dev
backend-dev "GET /accounts/accounts HTTP/1.1" 200 -
backend-dev "GET /accounts HTTP/1.1" 200 -        ← sondes de readiness
```

Le backend a journalisé la requête **avec le chemin concaténé par webMethods**.
Or son Service est en ClusterIP, injoignable de l'extérieur : une requête HTTPS
publique a produit une ligne de journal dans un pod inaccessible depuis
Internet. La chaîne `Caddy → gateway du cluster → backend-dev` est donc établie
de bout en bout, et le `receivedPath` est une empreinte que Caddy seul ne
pourrait pas fabriquer.

C'est exactement l'usage prévu au § D5 (« le chemin réellement reçu devient une
preuve consignée ») — la décision a servi deux fois : à éviter un 404, puis à
prouver la chaîne quand l'assertion prévue s'est révélée fausse.

### T4 sabotage 2 — le filet tient, prouvé sur le vrai fichier

Joué par l'exploitant le 2026-07-30 à ~10:47Z, **pendant que Docker servait
encore**. Déroulé constaté :

1. garde d'empreinte : « état reconnu (avant-bascule) — OK » ;
2. **garde d'amont : 30 essais en échec puis OK.** Elle a absorbé la fenêtre de
   quiescence de la sauvegarde T3 qui tournait en parallèle. Les 8 min de
   patience posées « pour le cycle trial » ont servi à un cas non prévu et ont
   évité un faux échec — la marge était la bonne, pour une autre raison que
   celle qui l'avait motivée ;
3. sauvegarde horodatée créée (`Caddyfile.20260730T104713`) ;
4. template écrit, **`caddy validate` ok** — première validation réelle du
   template, il est syntaxiquement bon ;
5. rechargement à chaud ;
6. **porte rouge** : 200 obtenu, 599 exigé → échec après 6 essais ;
7. **`rescue` : restauration, rechargement, et vérification que l'ancien chemin
   sert de nouveau** (`/rest/apigateway/health` → 200) ;
8. `BASCULE ANNULÉE`, bruyamment. `rescued=1`.

**État après coup : empreinte du Caddyfile EXACTEMENT la valeur T0**
(`5fab7a255ef128b4…`), surface publique revenue à 200/401/302/200. Une bascule
ratée revient donc toute seule, et sans laisser de trace.

**Preuve incidente de P-a, à travers le nom public.** Le message d'échec contient
la réponse réellement obtenue pendant la fenêtre :

```
status : 200
url    : https://dev-wm.gostoa.dev/gateway/accounts-read/1.0.0/accounts
via    : 1.1 Caddy
content: {"backend": "backend-dev.wm.svc.cluster.local",
          "receivedPath": "/accounts/accounts", "accounts": [...]}
```

L'invocation data-plane **a fonctionné par le nom public, à travers Caddy** : la
porte n'a rougi que parce qu'on exigeait 599. P-a reste à établir dans un état
**conservé** (avec P-b), mais son mécanisme n'est plus une hypothèse.

### T3 — la preuve

Run vert : `ok=52  changed=19  failed=0`. Le PVC du ns `wm` est passé par toute
la chaîne : archivé sur worker-4, **relu localement**, transféré en flux via le
poste, **relu hors-nœud avec empreinte égale au staging**, puis roté par claim.
`Vault descellé, socle intact.` en sortie.

Relecture **indépendante** sur worker-2 (une empreinte prouve un transfert, pas
une archive exploitable — leçon F2) :

```
pvc-wm-es-data-wm-elasticsearch-0-20260730T104324.tar.gz   4,7 Mo   0600 root
entrées : 1803        chemins d'index : 1695
./indices/m3SvOXbpQ_-aYlYY2mnA4Q/0/translog/translog-4.tlog
```

**4,7 Mo contre les 108 Mo de worker-3** : l'ES du cluster ne porte que
`accounts-read` et la configuration Teams, sans les 92 Mo de logs d'audit
accumulés par le cycle de redémarrage de worker-3. L'écart n'est pas une perte,
c'est la mesure de ce que valait vraiment le « volume » de worker-3.

**Piège de relecture, rencontré deux fois.** `cd /var/lib/k3s-backups/offsite`
échoue en `Permission denied` sans `sudo` (répertoire `0700 root`) : préfixer
chaque commande ne suffit pas, il faut `sudo bash -c '…'` pour le shell entier.
Déjà noté au relevé T0 — et refait quand même. C'est ce qui avait fait croire les
archives F2 absentes.

### T3 — la fenêtre s'est refermée proprement

Constaté pendant le run : ns `wm` entièrement quiescé, les 6 Applications sans
`automated`, **`wm-restarter: suspend=true`** (le code de suspension des CronJobs
ajouté pour F5, à l'œuvre), et `vault-0` **laissé tournant** comme charge à
chaud. Puis restauration : 3 pods `Running`, `automated` remis partout, et
**`wm-restarter: suspend=false`** — rendu à son état *capturé*, pas « repris »
à l'aveugle. Surface publique inchangée pendant toute la fenêtre (200/302/200) :
la quiescence du cluster est invisible du public, puisque le trafic est encore
sur Docker.

### T2 — la preuve, et ce qu'elle a validé au passage

```
$ curl http://10.43.227.71:5555/gateway/accounts-read/1.0.0/accounts   # depuis l'HÔTE worker-3
{"backend": "backend-dev.wm.svc.cluster.local",
 "receivedPath": "/accounts/accounts",
 "accounts": [{"id": "ACC-001", ...}, {"id": "ACC-002", ...}]}
HTTP 200
```

Le passage **500 → 200** prouve que c'est bien `backend-dev` qui a débloqué
l'invocation, et non un effet de bord.

**`receivedPath: "/accounts/accounts"` est le fait le plus utile de la tâche.**
C'est exactement le cas de concaténation anticipé en spéc § D5 : webMethods a
ajouté la ressource `/accounts` à un endpoint qui se terminait **déjà** par
`/accounts`. Un backend servant uniquement `/accounts` aurait rendu **404**, et
la porte F5 aurait rougi pour une raison subtile, à chercher entre wM, Caddy et
le backend. Avoir choisi un backend **agnostique au chemin et journalisant** a
transformé une inconnue en preuve consignée, au lieu de parier sur une règle de
concaténation non documentée.

La gateway a demandé **9 essais (~90 s)** avant d'être prête : on était dans la
fenêtre du cycle trial. L'attente active du plan (motif F4) a fait son office.

### Observation — `wm-elasticsearch` restera `OutOfSync` pour toujours

Relevé pendant T1, **préexistant à F5 et sans gravité** (`Healthy`), mais à
consigner pour qu'on ne le lise pas plus tard comme un dégât de la sauvegarde :
la seule ressource en écart est le `StatefulSet`, et l'écart porte sur des
**défauts ajoutés par Kubernetes** dans `volumeClaimTemplates` (`apiVersion`,
`kind`, `volumeMode: Filesystem`, `status`). Or `volumeClaimTemplates` est
**immuable** sur un StatefulSet : Argo ne pourra jamais réconcilier.

Conséquence à connaître : pour cette Application, « OutOfSync » **ne signale plus
rien** — c'est une alerte allumée en permanence. Correctif (hors F5, une ligne) :
déclarer `volumeMode: Filesystem` dans Git, ou poser un `ignoreDifferences`.

**Deux gestes exploitant bloquent la suite** (tous deux **tentés puis refusés**
au classifieur, en commandes propres et mono-objet — la contrainte n'est pas
héritée d'une session précédente, elle est vérifiée dans celle-ci) : le **merge
de la PR #2825**, et **toute écriture dans le Caddyfile de worker-3** — c'est la
terminaison TLS de la flotte entière. Aucun contournement n'a été tenté :
éditer le fichier par `ssh` serait exactement ce que ce refus existe pour
empêcher.

### Ce qui a été prouvé sans ces gestes

| Affirmation du plan | Comment elle a été établie |
|---|---|
| Les deux bugs de `cluster_backup` sont réels | **Mesuré** : `kubectl get pods -n wm -o name` rend **5** pods dont **3 `Succeeded`** ; l'attente exige une sortie vide → elle n'aurait jamais convergé, et le contrôle post-archivage les aurait comptés pour des « pods réapparus » → quarantaine et rejet d'une archive saine. |
| Le correctif marche | **Mesuré** : avec `--field-selector`, 2 pods (les seuls `Running`). Expression exacte du rôle rejouée sur `wm` **et** `ci`, grep des charges à chaud compris — `vault` reste bien filtré. |
| Le chemin `ci` ne régresse pas | **Établi par la mesure, pas par un run** : le ns `ci` n'a **aucun** pod `Succeeded`/`Failed` (donc le filtre n'y change rien) et **aucun CronJob** (donc les nouvelles boucles y sont vides). Comportement identique, sans quiescer le socle. |
| Les nouvelles boucles s'évaluent sans erreur | **Testé en local** (`localhost`, hors cluster) sur les deux cas réels : liste vide → aucune itération ; `wm-restarter=false` → suspend puis retour à l'**état capturé** ; un CronJob volontairement suspendu reste `true` ; un champ absent vaut `false` (défaut Kubernetes). |
| Le backend `backend-dev` fonctionne | **Exécuté** sur le poste avant tout déploiement. A révélé un défaut réel : `HTTPServer` mono-connexion + keep-alive HTTP/1.1 faisait **expirer 3 appels concurrents sur 3**. Corrigé en `ThreadingHTTPServer`, reprouvé **3/3 en moins de 5 ms** sous connexion tenue. Chemins `/accounts`, `/accounts/accounts`, `/accounts/ACC-001`, `/` tous à 200 avec le chemin reçu renvoyé. |
| Le rôle de bascule n'écrit pas à blanc | **Vérifié** : après `--check --diff`, empreinte du Caddyfile inchangée, aucune sauvegarde créée, services publics intacts. Le `--diff` montre que **les quatre blocs `*-k3s` ne bougent pas**. |
| La garde d'entrée du rollback mord | **Testé** : `-e wm_cutover_rollback=true` depuis un état non basculé → **refus**, `changed=0`. Sans elle, il aurait restauré une sauvegarde du 2026-07-27 en annonçant un succès. |
| **Sabotage 1** : cible amont fausse → refus d'écrire | **Joué** : échec sur la garde d'amont, `changed=0`, aucune sauvegarde créée, rien écrit. |
| La garde du script d'archive mord | **Joué** : conteneurs en service → **refus**, code 1, conteneurs fautifs nommés, aucun `tar`. |
| Il n'y a qu'UN volume à retirer | **Mesuré** : `wm-dev-apigateway` sans montage ; `webmethods-dev_es-dev-data`, 108 Mo. Plus aucun nom à deviner en T7. |

**État laissé** : identique au relevé T0. Empreinte du Caddyfile inchangée, une
seule sauvegarde (celle du 2026-07-27, antérieure), les deux conteneurs Docker
en service, surface publique intacte (`health` 200, `apis` 401, `ui` 302,
`dev-gw-k3s` 200). Rien n'est à moitié fait.

---

### Tâche 0 : Vérifications terrain

Les valeurs de la spéc ont été mesurées le 2026-07-29/30. Elles peuvent avoir
bougé. **Rien ne s'écrit avant que ce relevé soit consigné.**

- [ ] **Step 1 : relever l'état des deux plans**

```bash
ssh worker-1 'sudo k3s kubectl get svc,pods -n wm -o wide; \
  sudo k3s kubectl get networkpolicy -n wm; \
  sudo k3s kubectl get application -n argocd | grep -E "wm-|NAME"'
ssh worker-3 'sudo docker ps --format "{{.Names}}\t{{.Status}}"; \
  sudo crontab -l 2>/dev/null | grep -i wm; \
  sudo -u hegemon crontab -l 2>/dev/null | grep -i wm'
```

Consigner : **la ClusterIP de `wm-apigateway`** (la spéc dit `10.43.227.71` —
si elle diffère, c'est cette valeur-là qui sera épinglée en T1), le nœud
portant la gateway, la présence des deux conteneurs, et les **deux** crons
(root `*/20` ; le keepalive hegemon `*/25` du handoff F4 est à confirmer — le
  relevé ci-dessous établit qu'il n'existe pas).

- [ ] **Step 2 : la mesure qui autorise toute la suite** (voie 1 de la spéc)

```bash
ssh worker-3 'curl -s -o /dev/null -w "health depuis l_hote: %{http_code} en %{time_total}s\n" \
  --max-time 10 http://<CLUSTERIP>:5555/rest/apigateway/health'
```

Attendu : **200**. Si ce n'est pas 200, **arrêter le plan** : le choix remonte à
l'exploitant entre l'exception §4.1 (Ingress) et l'abandon de la bascule
publique. Ne rien improviser.

- [ ] **Step 3 : relever la surface publique AVANT, nom par nom** (c'est la
  référence du durcissement P-b, et la garde de la règle n°1)

```bash
for u in https://dev-wm.gostoa.dev/ \
         https://dev-wm.gostoa.dev/rest/apigateway/health \
         https://dev-wm.gostoa.dev/rest/apigateway/apis \
         https://dev-wm.gostoa.dev/apigatewayui/ \
         https://dev-wm-ui.gostoa.dev/ \
         https://dev-gw-k3s.gostoa.dev/health; do
  printf '%s -> %s\n' "$u" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$u")"
done
```

Attendu d'après la mesure du 2026-07-30 : `200`, `200`, `401`, `302`, `302`, et
une valeur de référence pour `dev-gw-k3s` (à conserver telle quelle).

- [ ] **Step 4 : empreinte du Caddyfile courant** (garde de T4)

```bash
ssh worker-3 'sudo sha256sum /etc/caddy/Caddyfile; sudo wc -l /etc/caddy/Caddyfile'
```

Consigner l'empreinte : le rôle de T4 **refusera** de s'exécuter si le fichier
a changé entre-temps.

- [ ] **Step 5 : espace disque sur worker-2** (cible d'archive de T7)

```bash
ssh worker-2 'df -h /var/lib | tail -1; echo; ls -la /var/lib/k3s-backups/offsite 2>/dev/null | head -3'
```

Attendu : largement plus que 200 Mo libres (F2 avait mesuré 361 Go).

- [x] **Step 6 : commit du relevé**

#### Relevé T0 — exécuté le 2026-07-30 (07:0x–07:3x UTC)

| Mesure | Valeur relevée |
|---|---|
| ClusterIP `wm-apigateway` | **`10.43.227.71`** (ports 5555, 9072) — conforme à la spéc |
| ClusterIP `elasticsearch` | `10.43.210.198:9200` |
| `health` depuis l'**hôte** worker-3 | **200 en 18,7 ms** → voie 1 acquise, le plan est autorisé |
| ES cluster depuis l'hôte | **000** (bloqué) — NetworkPolicy `wm-elasticsearch-ingress` en place, ingress restreint aux pods `app=wm-apigateway` |
| Surface publique AVANT | `/` **200** · `/rest/apigateway/health` **200** · `/rest/apigateway/apis` **401** · `/apigatewayui/` **302** · `dev-wm-ui/` **302** |
| Garde flotte, référence | `https://dev-gw-k3s.gostoa.dev/health` → à relever au run (Caddy sert 4 noms `*-k3s` vers `localhost:30080`) |
| Empreinte Caddyfile | **`5fab7a255ef128b4f7842df9bad86e84416f718477ec1bffb07df3e63e615689`**, 51 lignes |
| Conteneurs worker-3 | `wm-dev-apigateway` (127.0.0.1:5555, 127.0.0.1:19072), `wm-dev-elasticsearch` |
| Placement cluster | gateway sur worker-5, ES sur worker-4, `wm-restarter` sur worker-3 |
| worker-2 | **360 Go libres**, `/var/lib/k3s-backups/offsite` présent (root-only, `0700`) avec les 8 archives F2 (1,5 Go, deux runs) |
| Nommage des archives F2 | `pvc-<ns>-<pvc>-<stamp>.tar.gz` — donc le ns `wm` produira `pvc-wm-es-data-wm-elasticsearch-0-*.tar.gz` |
| Coupure du cycle trial | **150 s** (07:20:23 → 07:22:54), sonde à 5 s depuis l'hôte |

**Deux écarts avec la documentation, élucidés :**

1. **Les archives F2 sont bien sur worker-2.** Un premier `ls` sans `sudo` les
   avait fait croire absentes : le répertoire est `0700 root`. Aucun défaut —
   seulement un piège de relecture, à ne pas reproduire.
2. **Le keepalive hegemon `*/25` n'existe pas.** Le handoff F4 (point 4)
   l'annonçait « en doublon du cron root `*/20`, ~5 min de service perdues par
   heure ». Vérifié : crontab `root` = **une seule** ligne
   (`*/20 … docker restart wm-dev-apigateway`) ; crontab `hegemon` = **un ping
   d'uptime `*/1`** vers `status.gostoa.dev`, **sans aucun rapport avec
   webMethods** ; `/etc/cron.d` vide de tout wM ; aucun timer systemd.
   **Conséquence pour T7 Step 6 : il n'y a qu'UN cron à déposer**, et le ping
   d'uptime `*/1` **ne doit pas être touché** — le motif de filtrage
   (`wm-dev|wm-apigateway`) ne le capture pas, ce qui est exactement voulu.

```bash
git add docs/superpowers/plans/2026-07-30-f5-bascule-decommission.md
git commit -s -m "docs(f5): relevé terrain T0 — ClusterIP, surface publique, empreinte Caddyfile"
```

---

### Tâche 1 : PR `stoa` unique — ClusterIP épinglée, commentaire corrigé, `backend-dev`

**Files (dépôt `stoa`, worktree neuf) :**
- Modify: `deploy/bootstrap/wm/apigateway/service.yaml` (ajout `clusterIP`)
- Modify: `deploy/bootstrap/wm/apigateway/cronjob.yaml` (commentaire faux)
- Create: `deploy/bootstrap/wm/backend-dev/kustomization.yaml`
- Create: `deploy/bootstrap/wm/backend-dev/configmap.yaml`
- Create: `deploy/bootstrap/wm/backend-dev/deployment.yaml`
- Create: `deploy/bootstrap/wm/backend-dev/service.yaml`
- Create: `deploy/bootstrap/argocd/app-wm-backend-dev.yaml`

**Interfaces :**
- Consomme : la ClusterIP relevée en T0 Step 1.
- Produit : `backend-dev.wm.svc.cluster.local:8080` répondant 200 JSON sur
  **n'importe quel chemin** — c'est l'URI que `accounts-read` porte déjà depuis
  F4. Et une ClusterIP `wm-apigateway` **stable**, consommée par T4.

**Pourquoi une seule PR :** les trois changements vivent tous sous
`deploy/bootstrap/wm/`, et chaque PR coûte un geste exploitant (merge). Un seul
merge, un seul re-sync, une seule vérification.

- [ ] **Step 1 : worktree neuf sur `origin/main`**

```bash
cd ~/stoa-platform/stoa && git fetch origin
git worktree add ~/stoa-platform/stoa-f5 -b feat/f5-backend-dev-clusterip origin/main
cd ~/stoa-platform/stoa-f5 && git log --oneline -1
```

Attendu : le HEAD est `fd2f356f` (ou plus récent), **pas** `1edada9b`.

- [ ] **Step 2 : épingler la ClusterIP**

Dans `deploy/bootstrap/wm/apigateway/service.yaml`, ajouter sous `spec:` (avant
`selector:`), en remplaçant `<CLUSTERIP>` par la valeur **relevée en T0** :

```yaml
spec:
  # ClusterIP ÉPINGLÉE — F5. Caddy (worker-3, hôte) proxifie /gateway/* vers
  # cette adresse : Caddy ignore CoreDNS comme containerd, donc la cible est
  # une IP, pas un nom. Sans épinglage, une recréation du Service réattribue
  # l'adresse et le Caddyfile pointe dans le vide — 502 publics SANS alerte,
  # car rien ne relie mécaniquement les deux artefacts.
  # Motif identique à la ClusterIP gitea (10.43.60.211) épinglée au lot 1.
  # Si cette valeur doit changer : changer AUSSI
  # stoa-labs ansible/roles/caddy_wm_cutover/defaults/main.yml.
  clusterIP: <CLUSTERIP>
  selector:
    app: wm-apigateway
```

- [ ] **Step 3 : corriger le commentaire faux du CronJob**

Dans `deploy/bootstrap/wm/apigateway/cronjob.yaml`, remplacer la phrase
« retour Ready ~5 min ; ~15 min de service par cycle de 20 min, conséquence
assumée. » par :

```
# retour Ready MESURÉ 150 s (F5, 2026-07-30 : coupure 07:20:23 → 07:22:54
# observée depuis l'hôte worker-3, sonde à 5 s) — soit 17 min 30 de service
# par cycle de 20 min, 87,5 % de disponibilité. L'estimation précédente
# (« ~5 min », « ~15 min de service ») surestimait le trou d'un facteur 2.
# Conséquence assumée ; la haute dispo par répliques décalées est un spike
# séparé (spéc F5 § D9), PAS à improviser ici : deux instances wM 10.15 sur
# un ES partagé exigent un vrai clustering non instruit.
```

- [ ] **Step 4 : le backend réel — ConfigMap**

Créer `deploy/bootstrap/wm/backend-dev/configmap.yaml` :

```yaml
# Backend réel de l'API `accounts-read` publiée par F4. F4 avait posé l'URI
# `backend-dev.wm.svc.cluster.local:8080/accounts` en la documentant comme
# « nom honnête, aucun backend réel derrière » : F5 le fait EXISTER, ce qui
# rend l'API invocable sans rien renommer. Spéc F5 § D5.
#
# Le serveur répond 200 sur N'IMPORTE QUEL chemin, et JOURNALISE le chemin
# reçu. Raison : wM concatène la ressource à l'URI de l'endpoint, et l'endpoint
# se termine déjà par /accounts — le backend peut donc recevoir
# /accounts/accounts. Plutôt que de deviner, on est agnostique et le chemin
# réellement reçu devient une PREUVE consignée.
apiVersion: v1
kind: ConfigMap
metadata:
  name: backend-dev-src
  namespace: wm
data:
  server.py: |
    import json
    from http.server import BaseHTTPRequestHandler, HTTPServer

    ACCOUNTS = [
        {"id": "ACC-001", "holder": "Ada Lovelace", "balance": 1042.50, "currency": "EUR"},
        {"id": "ACC-002", "holder": "Alan Turing",  "balance":  317.00, "currency": "EUR"},
    ]

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _respond(self, with_body):
            payload = json.dumps({
                "backend": "backend-dev.wm.svc.cluster.local",
                "receivedPath": self.path,
                "accounts": ACCOUNTS,
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if with_body:
                self.wfile.write(payload)

        def do_GET(self):
            self._respond(True)

        def do_HEAD(self):
            self._respond(False)

        def log_message(self, fmt, *args):
            print("backend-dev %s" % (fmt % args), flush=True)

    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
```

- [ ] **Step 5 : le backend réel — Deployment**

Créer `deploy/bootstrap/wm/backend-dev/deployment.yaml` :

```yaml
# Image RÉUTILISÉE depuis le registre Gitea PAR DIGEST (doctrine F3 : aucune
# image depuis Docker Hub, aucun tag mutable). `jenkins-go:v1` embarque python3
# (dépendance d'ansible-core) : pas besoin de construire ni de pousser une
# image pour 40 lignes de serveur HTTP.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-dev
  namespace: wm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend-dev
  template:
    metadata:
      labels:
        app: backend-dev
    spec:
      # Anti-affinité worker-3 (motif PR #2819) : la prod Docker wm-dev-* y
      # tourne encore au moment où ce manifeste est posé (double-run F3–F5).
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: NotIn
                    values:
                      - worker-3
      containers:
        - name: backend
          image: localhost:30300/ci/jenkins-go:v1@sha256:00ad5591be6f1c7b4eccfd7e498abe5e947dc07f01e4d7a247005b65ef0c565b
          command: ["python3", "/opt/backend/server.py"]
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: src
              mountPath: /opt/backend
              readOnly: true
          readinessProbe:
            httpGet:
              path: /accounts
              port: 8080
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /accounts
              port: 8080
            periodSeconds: 30
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 128Mi
      volumes:
        - name: src
          configMap:
            name: backend-dev-src
```

- [ ] **Step 6 : le backend réel — Service et kustomization**

Créer `deploy/bootstrap/wm/backend-dev/service.yaml` :

```yaml
# ClusterIP, non épinglée : ce Service n'est consommé QUE par la gateway, par
# son nom DNS (résolu par CoreDNS depuis un pod). Contrairement à
# wm-apigateway, aucun consommateur au niveau hôte — donc aucune raison
# d'épingler l'adresse.
apiVersion: v1
kind: Service
metadata:
  name: backend-dev
  namespace: wm
spec:
  selector:
    app: backend-dev
  ports:
    - name: http
      port: 8080
      targetPort: 8080
```

Créer `deploy/bootstrap/wm/backend-dev/kustomization.yaml` :

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: wm
resources:
  - configmap.yaml
  - deployment.yaml
  - service.yaml
```

- [ ] **Step 7 : l'Application Argo** — copie conforme du motif
  `app-wm-apigateway.yaml`, seul `name`/`path` changent.

Créer `deploy/bootstrap/argocd/app-wm-backend-dev.yaml` :

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: wm-backend-dev
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: stoa
  source:
    repoURL: https://github.com/stoa-platform/stoa.git
    targetRevision: main
    path: deploy/bootstrap/wm/backend-dev
  destination:
    server: https://kubernetes.default.svc
    namespace: wm
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 5m
```

- [ ] **Step 8 : valider le rendu kustomize AVANT de pousser**

```bash
cd ~/stoa-platform/stoa-f5
kubectl kustomize deploy/bootstrap/wm/backend-dev
kubectl kustomize deploy/bootstrap/wm/apigateway | grep -A2 'clusterIP'
```

Attendu : les trois ressources `backend-dev` rendues sans erreur, et la
`clusterIP` présente avec la valeur de T0. (`kubectl kustomize` est du rendu
local pur — il ne parle à aucun cluster, donc l'interdiction du kubectl local
ne s'applique pas.)

- [ ] **Step 9 : commit + PR**

```bash
cd ~/stoa-platform/stoa-f5
git add deploy/bootstrap/wm/apigateway deploy/bootstrap/wm/backend-dev \
        deploy/bootstrap/argocd/app-wm-backend-dev.yaml
git commit -s -m "feat(wm): backend-dev réel, ClusterIP gateway épinglée, cycle trial rechiffré (F5)"
git push -u origin feat/f5-backend-dev-clusterip
gh pr create --repo stoa-platform/stoa --fill
```

- [ ] **Step 10 : faire merger par l'exploitant**, puis vérifier derrière

Demander le merge (le geste est bloqué côté agent). Puis :

L'Application Argo vit en Git mais doit être **appliquée une fois** (motif des
autres `app-*.yaml` du bootstrap). Le manifeste est **acheminé par le pipe**, pas
par un heredoc : `$(cat …)` dans une commande `ssh` entre guillemets simples ne
serait pas développé, et worker-1 ne connaît pas le chemin du worktree local.

```bash
cat ~/stoa-platform/stoa-f5/deploy/bootstrap/argocd/app-wm-backend-dev.yaml \
  | ssh worker-1 'sudo k3s kubectl apply -f -'
ssh worker-1 'sudo k3s kubectl get application -n argocd wm-backend-dev wm-apigateway \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

Attendu : les deux `Synced`/`Healthy`.

- [ ] **Step 11 : la ClusterIP est INCHANGÉE après re-sync** (l'assertion qui
  compte : épingler une valeur périmée provoquerait la panne qu'on prévient)

```bash
ssh worker-1 'sudo k3s kubectl get svc wm-apigateway -n wm -o jsonpath="{.spec.clusterIP}"; echo'
```

Attendu : **exactement** la valeur de T0. Si le Service a été recréé et
l'adresse refusée, Argo rendra une erreur d'immutabilité : corriger le
manifeste avec la nouvelle valeur, **ne pas supprimer le Service**.

- [ ] **Step 12 : commit du plan** dans `stoa-labs` (le plan coché, pas les
  manifestes — ils vivent dans `stoa`).

```bash
git add docs/superpowers/plans/2026-07-30-f5-bascule-decommission.md
git commit -s -m "docs(f5): T1 — PR stoa posée (backend-dev, clusterIP, chiffre du cycle)"
```

---

### Tâche 2 : Porte P-a **en interne** — l'invocation data-plane répond

On ne débogue jamais deux choses à la fois : le data-plane doit être vert
**avant** de toucher Caddy.

**Interfaces :**
- Consomme : `backend-dev` de T1, ClusterIP de T1.
- Produit : la certitude que la seule variable restante est Caddy.

- [ ] **Step 1 : le backend répond depuis un pod**

```bash
ssh worker-1 'sudo k3s kubectl run f5-probe -n wm --rm -i --restart=Never \
  --image=localhost:30300/ci/curl:8.10.1@sha256:3a57427a38852a03f246297e21aebaeaab5da747f5444b7b3383c1f4c49a4aa3 \
  -- curl -s -m 10 http://backend-dev.wm.svc.cluster.local:8080/accounts'
```

Attendu : JSON contenant `"receivedPath": "/accounts"` et les deux comptes.

- [ ] **Step 2 : attendre la gateway** (motif F4 — la fenêtre de 150 s)

```bash
ssh worker-3 'for i in $(seq 1 48); do
  c=$(curl -s -o /dev/null -w "%{http_code}" -m 5 http://<CLUSTERIP>:5555/rest/apigateway/health)
  [ "$c" = "200" ] && { echo "gateway prete (essai $i)"; exit 0; }
  sleep 10
done; echo "gateway indisponible apres 8 min"; exit 1'
```

- [ ] **Step 3 : l'invocation data-plane, depuis l'hôte worker-3, sur la ClusterIP**

```bash
ssh worker-3 'curl -s -m 20 -w "\nHTTP %{http_code}\n" \
  http://<CLUSTERIP>:5555/gateway/accounts-read/1.0.0/accounts'
```

Attendu : **200** et le corps JSON du backend. Avant T1 ce chemin rendait
**500** (route présente, backend absent) : le passage 500 → 200 est la preuve
que c'est bien `backend-dev` qui a débloqué l'invocation.

- [ ] **Step 4 : consigner le chemin réellement reçu par le backend** (la
  concaténation d'URI de wM, transformée en fait mesuré)

```bash
ssh worker-1 'sudo k3s kubectl logs -n wm deploy/backend-dev --tail=20 | grep backend-dev'
```

Consigner la ligne : elle dit si wM a demandé `/accounts` ou
`/accounts/accounts`. **Aucune correction n'est nécessaire** (le backend est
agnostique) — c'est de la documentation, pas un bug à traiter.

- [ ] **Step 5 : commit**

```bash
git add docs/superpowers/plans/2026-07-30-f5-bascule-decommission.md
git commit -s -m "docs(f5): T2 — invocation data-plane verte en interne (500 → 200)"
```

---

### Tâche 3 : Sauvegarde du ns `wm` — prérequis bloquant de la bascule

**Files :**
- Modify: `ansible/roles/cluster_backup/defaults/main.yml`

**Pourquoi bloquant :** la bascule fait du PVC `es-data-wm-elasticsearch-0` la
seule source de vérité de la gateway publique. Aujourd'hui il n'a **aucune**
sauvegarde (`backup_pvc_namespaces: [ci]`).

- [ ] **Step 1 : étendre la couverture**

Dans `ansible/roles/cluster_backup/defaults/main.yml` :

```yaml
# Namespaces dont les PVC local-path sont sauvegardés.
# `wm` ajouté par F5 : la bascule Caddy fait du PVC ES du ns wm la seule
# source de vérité de la gateway PUBLIQUE. Le sauvegarder est un prérequis
# bloquant de la bascule, pas une amélioration.
backup_pvc_namespaces:
  - ci
  - wm
```

Et dans la fenêtre de synchronisation :

```yaml
backup_sync_window_apps:
  - ci-gitea
  - ci-jenkins
  - ci-vault
  # F5 : ES du ns wm. Contrairement à Vault, ES est QUIESÇABLE — il ne revient
  # pas scellé. Et le pod gateway est de toute façon interrompu 150 s toutes
  # les 20 min par le cycle trial : la fenêtre ne coûte aucune indisponibilité
  # qui n'existe pas déjà. `backup_hot_workloads` reste donc à Vault seul.
  - wm-elasticsearch
  - wm-apigateway
```

- [ ] **Step 2 : vérifier qu'on n'a PAS ajouté ES aux charges à chaud**

```bash
grep -A4 'backup_hot_workloads' ansible/roles/cluster_backup/defaults/main.yml
```

Attendu : `statefulset/vault` **seul**. Si ES y figure, la sauvegarde serait
prise à chaud sans nécessité — le contraire de l'intention.

- [ ] **Step 3 : jouer la sauvegarde**

```bash
cd ansible && ansible-playbook -i inventory.contabo.ini backup.yml
```

Attendu : play vert, aucune tâche en `failed`.

- [ ] **Step 4 : l'archive du PVC ES est LISIBLE sur worker-2** (une empreinte
  qui concorde prouve un transfert, pas une archive exploitable — leçon F2)

Le rôle F2 nomme ses archives `pvc-*.tar.gz` : on ne devine pas le nom, on liste
les plus récentes et on identifie celle du ns `wm`.

```bash
ssh worker-2 'echo "=== archives les plus recentes ==="; \
  sudo ls -1t /var/lib/k3s-backups/offsite/*.tar.gz | head -8; \
  echo "=== celle du ns wm ==="; \
  A=$(sudo ls -1t /var/lib/k3s-backups/offsite/*.tar.gz | grep -iE "wm|es-data" | head -1); \
  echo "archive: ${A:-AUCUNE}"; \
  [ -n "$A" ] || { echo "ECHEC : aucune archive du ns wm — la couverture n_a pas pris"; exit 1; }; \
  echo "entrées: $(sudo tar -tzf "$A" | wc -l)"; \
  sudo tar -tzf "$A" | grep -i indices | head -5'
```

Attendu : une archive identifiée pour le ns `wm`, qui s'ouvre, et dont le
contenu montre l'arborescence d'index ES (`nodes/0/indices/…`). Si aucune
archive ne correspond, la couverture de T3 Step 1 n'a pas pris effet —
**ne pas passer à la bascule.**

- [ ] **Step 5 : le cluster est revenu sain après la fenêtre**

```bash
ssh worker-1 'sudo k3s kubectl get pods -n wm; \
  sudo k3s kubectl get application -n argocd | grep wm-'
```

Attendu : pods `Running`, Applications `Synced`/`Healthy` (l'auto-sync a été
restauré par la fenêtre).

- [ ] **Step 6 : commit**

```bash
git add ansible/roles/cluster_backup/defaults/main.yml \
        docs/superpowers/plans/2026-07-30-f5-bascule-decommission.md
git commit -s -m "feat(f5): sauvegarde étendue au ns wm — prérequis bloquant de la bascule"
```

---

### Tâche 4 : Le rôle de bascule, et sa contre-épreuve de sabotage **jouée d'abord**

**Files :**
- Create: `ansible/roles/caddy_wm_cutover/defaults/main.yml`
- Create: `ansible/roles/caddy_wm_cutover/tasks/main.yml`
- Create: `ansible/roles/caddy_wm_cutover/templates/Caddyfile.j2`
- Create: `ansible/roles/caddy_wm_cutover/handlers/main.yml`
- Create: `ansible/wm-cutover.yml`

**Interfaces :**
- Consomme : la ClusterIP épinglée (T1), l'empreinte du Caddyfile (T0 Step 4).
- Produit : `ansible-playbook wm-cutover.yml` (bascule) et
  `-e wm_cutover_rollback=true` (restauration).

**Pourquoi un template et non un `replace` :** le rôle `caddy_cutover` existant
substitue **un jeton**. F5 change la **forme** du bloc (des `handle` par chemin,
un fallback 404) : un `replace` ne peut pas l'exprimer. Le template rend l'état
cible explicite et diffable — et la garde d'empreinte empêche d'écraser une
configuration qu'on n'aurait pas vue.

**Pourquoi le sabotage AVANT la vraie bascule :** on valide la machinerie
fail-closed **pendant que Docker sert encore**. Si la restauration automatique
est cassée, on le découvre alors que le trafic public est intact — pas après
avoir basculé.

- [ ] **Step 1 : les valeurs par défaut**

Créer `ansible/roles/caddy_wm_cutover/defaults/main.yml` :

```yaml
---
# roles/caddy_wm_cutover/defaults/main.yml
#
# Bascule du nom public dev-wm.gostoa.dev depuis le webMethods DOCKER de
# worker-3 vers la gateway du CLUSTER — jalon F5.
#
# Ce rôle est distinct de `caddy_cutover` (bascule ancien k3s → nouveau k3s,
# lot précédent) pour deux raisons :
#   1. `caddy_cutover` substitue UN JETON (localhost:30080 → IP). F5 change la
#      FORME du bloc : seuls les chemins /gateway/* restent publics.
#   2. Les noms, les chemins de vérification et le sens de la porte diffèrent.
# La note de sécurité de caddy_cutover (« Caddy → ingress traverse l'Internet
# public EN CLAIR ») NE S'APPLIQUE PAS ici : worker-3 porte Caddy *et* un agent
# du cluster, il n'y a aucun saut réseau.

# Cible amont : ClusterIP du Service wm-apigateway, ÉPINGLÉE dans
# stoa deploy/bootstrap/wm/apigateway/service.yaml. Les deux valeurs doivent
# changer ENSEMBLE. Mesuré joignable depuis l'HÔTE worker-3 (200 en 18,7 ms).
wm_cutover_upstream: "10.43.227.71"
wm_cutover_upstream_port: 5555

# Empreinte SHA-256 du Caddyfile ATTENDU avant bascule (relevée en T0). Le rôle
# REFUSE de s'exécuter si le fichier n'est ni cet état-là, ni l'état cible :
# on n'écrase pas une configuration qu'on n'a pas vue.
wm_cutover_expected_sha256: "__RELEVE_EN_T0__"

# Marqueur reconnaissant un Caddyfile DÉJÀ basculé. Il rend le rôle idempotent
# (la re-bascule de T6 ne doit pas échouer sur sa propre empreinte). Doit
# apparaître VERBATIM dans templates/Caddyfile.j2.
wm_cutover_marker: "F5 : bascule vers la gateway du CLUSTER"

# Essais de la garde de cible amont (× 10 s). 48 = 8 min, soit largement les
# 150 s du cycle trial. La contre-épreuve de sabotage le réduit à 2 pour
# échouer vite sans attendre 8 min.
wm_cutover_upstream_retries: 48

# Porte de preuve de la BASCULE : l'invocation data-plane réelle. On ne vérifie
# PAS /rest/apigateway/health — il n'est plus public (§ D3), et une invocation
# prouve strictement plus qu'un health.
wm_cutover_verify_url: "https://dev-wm.gostoa.dev/gateway/accounts-read/1.0.0/accounts"
wm_cutover_verify_expect: 200

# Porte de preuve de la RESTAURATION : la configuration d'origine reproxyfie
# TOUT vers localhost:5555, donc /rest/apigateway/health redevient public.
# Confondre les deux ferait rougir une restauration réussie.
wm_rollback_verify_url: "https://dev-wm.gostoa.dev/rest/apigateway/health"
wm_rollback_verify_expect: 200

# Garde « TLS de la flotte » : un nom NON concerné doit répondre comme avant.
wm_cutover_guard_url: "https://dev-gw-k3s.gostoa.dev/health"

wm_cutover_rollback: false
caddy_config_path: "/etc/caddy/Caddyfile"
caddy_backup_dir: "/etc/caddy/backups"
```

- [ ] **Step 2 : le template**

Créer `ansible/roles/caddy_wm_cutover/templates/Caddyfile.j2` :

```jinja
# Managed by Ansible — do not edit manually
# TLS termination via Caddy (Let's Encrypt auto)


dev-gw-k3s.gostoa.dev {
    reverse_proxy localhost:30080 {
        header_up Host dev-gw-k3s.gostoa.dev
    }
}

dev-wm-k3s.gostoa.dev {
    reverse_proxy localhost:30080 {
        header_up Host dev-wm-k3s.gostoa.dev
    }
}

staging-gw-k3s.gostoa.dev {
    reverse_proxy localhost:30080 {
        header_up Host staging-gw-k3s.gostoa.dev
    }
}

staging-wm-k3s.gostoa.dev {
    reverse_proxy localhost:30080 {
        header_up Host staging-wm-k3s.gostoa.dev
    }
}

# ── F5 : bascule vers la gateway du CLUSTER, data-plane SEUL ────────────────
# Avant F5 ce bloc proxifiait TOUT vers localhost:5555 (webMethods Docker),
# ce qui publiait l'admin REST wM sur l'Internet ouvert derrière un simple
# basic auth (mesuré : /rest/apigateway/apis → 401). La contre-épreuve F3
# avait pourtant établi 6/6 refus pour la gateway du cluster : basculer à
# l'identique aurait annulé la doctrine §4.1 en silence.
# Publiquement : /gateway/* et rien d'autre. L'admin passe par le tunnel SSH.
dev-wm.gostoa.dev {
    handle /gateway/* {
        reverse_proxy {{ wm_cutover_upstream }}:{{ wm_cutover_upstream_port }}
    }
    handle {
        respond 404
    }
    # Le cycle trial coupe 150 s toutes les 20 min (mesuré F5). Un 503 explicite
    # vaut mieux qu'un 502 brut : la face publique dit ce qui se passe.
    handle_errors {
        respond "gateway en cycle de renouvellement" 503
    }
}

# Console d'admin : FERMÉE publiquement par F5. Le bloc est conservé et refuse,
# plutôt que supprimé : un refus est mesurable, une absence est ambiguë.
dev-wm-ui.gostoa.dev {
    respond 404
}
```

- [ ] **Step 3 : les tâches**

Créer `ansible/roles/caddy_wm_cutover/tasks/main.yml` :

```yaml
---
# roles/caddy_wm_cutover/tasks/main.yml
#
# Bascule fail-closed avec restauration AUTOMATIQUE. Même squelette que
# caddy_cutover (dont le comportement a fait ses preuves), avec un template
# au lieu d'un `replace`, et deux portes distinctes selon le sens.

- name: "Garde : le Caddyfile en place est-il celui qu'on croit ?"
  ansible.builtin.stat:
    path: "{{ caddy_config_path }}"
    checksum_algorithm: sha256
  become: true
  register: caddy_before

- name: "Garde : lire le contenu courant (pour détecter un état déjà basculé)"
  ansible.builtin.slurp:
    src: "{{ caddy_config_path }}"
  become: true
  register: caddy_before_raw

- name: "Garde : l'état courant est-il l'état AVANT, ou déjà l'état cible ?"
  ansible.builtin.set_fact:
    caddy_is_pre_cutover: "{{ caddy_before.stat.checksum == wm_cutover_expected_sha256 }}"
    caddy_is_already_target: "{{ wm_cutover_marker in (caddy_before_raw.content | b64decode) }}"

- name: "Garde : refuser si le fichier n'est NI l'état avant NI l'état cible"
  ansible.builtin.assert:
    that:
      - caddy_before.stat.exists
      - caddy_is_pre_cutover or caddy_is_already_target
    fail_msg: >-
      REFUS : {{ caddy_config_path }} a l'empreinte
      {{ caddy_before.stat.checksum | default('ABSENT') }} — ni l'état AVANT
      attendu ({{ wm_cutover_expected_sha256 }}), ni un état déjà basculé (le
      marqueur « {{ wm_cutover_marker }} » est absent). Le fichier a changé hors
      de ce rôle. Le relire, comprendre pourquoi, puis mettre à jour
      wm_cutover_expected_sha256 — ne JAMAIS forcer : le template écrirait
      l'état cible par-dessus une configuration inconnue, et le TLS de toute
      la flotte passe par ce fichier.
    success_msg: >-
      état reconnu ({{ 'avant-bascule' if caddy_is_pre_cutover else 'déjà basculé' }}) — OK
  when: not wm_cutover_rollback
  # Accepter les DEUX états rend le rôle idempotent. Sans cela, la re-bascule
  # de T6 (après la contre-épreuve de rollback) échouerait sur sa propre
  # empreinte — une garde qui refuse le geste légitime n'est pas une garde,
  # c'est un défaut.

- name: "Garde : la cible amont répond-elle depuis CET hôte ?"
  ansible.builtin.uri:
    url: "http://{{ wm_cutover_upstream }}:{{ wm_cutover_upstream_port }}/rest/apigateway/health"
    method: GET
    status_code: 200
    timeout: 10
  become: false
  register: wm_upstream_probe
  retries: "{{ wm_cutover_upstream_retries }}"
  delay: 10
  until: wm_upstream_probe is succeeded
  when: not wm_cutover_rollback
  # 48 × 10 s = 8 min par défaut : couvre largement les 150 s du cycle trial.
  # Basculer vers une cible en cours de redémarrage ferait rougir la porte pour
  # une raison qui n'est pas la bascule. Paramétré pour que la contre-épreuve
  # de sabotage puisse échouer vite (-e wm_cutover_upstream_retries=2).

- name: "Créer le répertoire de sauvegardes"
  ansible.builtin.file:
    path: "{{ caddy_backup_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0750"
  become: true

- name: "Sauvegarder la configuration courante"
  ansible.builtin.copy:
    src: "{{ caddy_config_path }}"
    dest: "{{ caddy_backup_dir }}/Caddyfile.{{ ansible_date_time.iso8601_basic_short }}"
    remote_src: true
    owner: root
    group: root
    mode: "0640"
  become: true
  register: caddy_backup
  when: not wm_cutover_rollback

# --- Restauration explicite (-e wm_cutover_rollback=true) ---------------------
- name: "Restauration : retrouver la sauvegarde la plus récente"
  ansible.builtin.shell:
    cmd: "ls -1t {{ caddy_backup_dir }}/Caddyfile.* | head -1"
  become: true
  register: caddy_latest_backup
  changed_when: false
  when: wm_cutover_rollback

- name: "Restauration : remettre la sauvegarde en place"
  ansible.builtin.copy:
    src: "{{ caddy_latest_backup.stdout }}"
    dest: "{{ caddy_config_path }}"
    remote_src: true
    owner: root
    group: root
    mode: "0644"
  become: true
  when: wm_cutover_rollback
  notify: reload caddy

- name: "Restauration : forcer le rechargement maintenant"
  ansible.builtin.meta: flush_handlers
  when: wm_cutover_rollback

- name: "Restauration : porte — l'ancien chemin sert de nouveau"
  ansible.builtin.uri:
    url: "{{ wm_rollback_verify_url }}"
    method: GET
    status_code: "{{ wm_rollback_verify_expect }}"
    timeout: 15
  delegate_to: localhost
  become: false
  register: rollback_probe
  retries: 6
  delay: 10
  until: rollback_probe is succeeded
  when: wm_cutover_rollback

# --- Bascule, avec restauration automatique en cas d'échec -------------------
- name: "Bascule du trafic"
  when: not wm_cutover_rollback
  block:
    - name: "Écrire l'état cible (data-plane seul)"
      ansible.builtin.template:
        src: Caddyfile.j2
        dest: "{{ caddy_config_path }}"
        owner: root
        group: root
        mode: "0644"
      become: true

    - name: "Valider la configuration AVANT de recharger"
      ansible.builtin.command:
        cmd: "caddy validate --adapter caddyfile --config {{ caddy_config_path }}"
      become: true
      changed_when: false

    - name: "Recharger Caddy (à chaud, sans coupure)"
      ansible.builtin.systemd:
        name: caddy
        state: reloaded
      become: true

    - name: "Laisser le rechargement s'établir"
      ansible.builtin.wait_for:
        timeout: 5

    # Vérification depuis le NŒUD DE CONTRÔLE : le chemin réel d'un client.
    - name: "PORTE P-a : l'invocation data-plane répond {{ wm_cutover_verify_expect }}"
      ansible.builtin.uri:
        url: "{{ wm_cutover_verify_url }}"
        method: GET
        status_code: "{{ wm_cutover_verify_expect }}"
        timeout: 20
        return_content: true
      delegate_to: localhost
      become: false
      register: wm_gate
      retries: 6
      delay: 15
      until: wm_gate is succeeded

    - name: "PORTE P-a : le corps vient bien du backend en cluster"
      ansible.builtin.assert:
        that:
          - "'backend-dev.wm.svc.cluster.local' in (wm_gate.content | default(''))"
        fail_msg: >-
          La porte rend 200 mais le corps ne vient pas de backend-dev. Un 200
          peut venir d'une page d'erreur ou d'un cache : sans cette assertion,
          la porte serait décorative.
        success_msg: "corps servi par backend-dev — OK"

    - name: "GARDE : un nom NON concerné répond comme avant"
      ansible.builtin.uri:
        url: "{{ wm_cutover_guard_url }}"
        method: GET
        status_code: 200
        timeout: 15
      delegate_to: localhost
      become: false

  rescue:
    - name: "ÉCHEC — restaurer la configuration précédente"
      ansible.builtin.copy:
        src: "{{ caddy_backup.dest }}"
        dest: "{{ caddy_config_path }}"
        remote_src: true
        owner: root
        group: root
        mode: "0644"
      become: true

    - name: "ÉCHEC — recharger Caddy sur la configuration restaurée"
      ansible.builtin.systemd:
        name: caddy
        state: reloaded
      become: true

    - name: "ÉCHEC — vérifier que l'ancien chemin sert de nouveau"
      ansible.builtin.uri:
        url: "{{ wm_rollback_verify_url }}"
        method: GET
        status_code: "{{ wm_rollback_verify_expect }}"
        timeout: 15
      delegate_to: localhost
      become: false
      retries: 6
      delay: 10

    - name: "Interrompre : la bascule a échoué et a été annulée"
      ansible.builtin.fail:
        msg: >-
          BASCULE ANNULÉE. La configuration précédente a été restaurée et le
          trafic sert de nouveau depuis le webMethods Docker de worker-3
          (vérifié ci-dessus). Causes probables : ClusterIP
          {{ wm_cutover_upstream }} injoignable depuis l'hôte, gateway en
          cycle de redémarrage, ou backend-dev non prêt.
```

- [ ] **Step 4 : le handler et le playbook**

Créer `ansible/roles/caddy_wm_cutover/handlers/main.yml` :

```yaml
---
- name: reload caddy
  ansible.builtin.systemd:
    name: caddy
    state: reloaded
  become: true
```

Créer `ansible/wm-cutover.yml` :

```yaml
---
# wm-cutover.yml — jalon F5 : le nom public dev-wm.gostoa.dev passe du
# webMethods DOCKER de worker-3 à la gateway du CLUSTER, en data-plane seul.
#
# PRÉREQUIS, vérifiés ailleurs et NON re-vérifiés ici :
#   - ClusterIP wm-apigateway épinglée en Git (stoa) et joignable de l'hôte ;
#   - backend-dev déployé, invocation /gateway/accounts-read/1.0.0/accounts
#     verte EN INTERNE (plan F5, T2) ;
#   - PVC ES du ns wm sauvegardé hors-nœud (plan F5, T3).
#
# Usage :
#   ansible-playbook -i inventory.contabo.ini wm-cutover.yml
# Retour arrière (la bascule se restaure aussi seule si la porte rougit) :
#   ansible-playbook -i inventory.contabo.ini wm-cutover.yml -e wm_cutover_rollback=true
#
# Aucun DNS n'est touché : dev-wm.gostoa.dev résout déjà vers worker-3.

- name: "F5 — bascule du nom public vers la gateway du cluster"
  hosts: caddy
  gather_facts: true
  become: false
  roles:
    - caddy_wm_cutover
```

- [ ] **Step 5 : renseigner l'empreinte relevée en T0**

Remplacer `__RELEVE_EN_T0__` dans `defaults/main.yml` par l'empreinte du
T0 Step 4, et `wm_cutover_upstream` par la ClusterIP du T0 Step 1 si elle
diffère de `10.43.227.71`.

- [ ] **Step 6 : `--check` puis `--diff`, sans écrire**

```bash
cd ansible
ansible-playbook -i inventory.contabo.ini wm-cutover.yml --check --diff
```

Attendu : la garde d'empreinte passe, la garde de cible amont passe, et le
`--diff` du template montre exactement les deux blocs `dev-wm*` réécrits — et
**aucun changement** sur les quatre blocs `*-k3s`. Si le diff touche autre
chose, le template est faux : corriger avant d'écrire.

- [ ] **Step 7a : SABOTAGE 1 — la garde refuse d'écrire (cible amont fausse)**

Le rôle a **deux** chemins fail-closed, et il faut les éprouver tous les deux.
Le premier : une cible injoignable doit être refusée **avant** toute écriture.

```bash
cd ansible
ansible-playbook -i inventory.contabo.ini wm-cutover.yml \
  -e wm_cutover_upstream=10.43.0.99 -e wm_cutover_upstream_retries=2 2>&1 | tail -25
```

Attendu : échec sur la tâche « Garde : la cible amont répond-elle depuis CET
hôte ? », **aucune sauvegarde créée, aucune écriture**, et l'empreinte du
Caddyfile **inchangée** (vérifié au Step 8).

- [ ] **Step 7b : SABOTAGE 2 — la restauration automatique joue (porte impossible)**

Le second chemin : l'écriture a lieu, Caddy est rechargé, **la porte rougit**,
et le bloc `rescue` doit restaurer. On l'obtient avec une attente de code
impossible — la cible est bonne, seule l'assertion est truquée.

```bash
cd ansible
ansible-playbook -i inventory.contabo.ini wm-cutover.yml \
  -e wm_cutover_verify_expect=599 2>&1 | tail -35
```

Attendu, dans cet ordre :
1. le template est écrit, `caddy validate` passe, Caddy recharge ;
2. la porte **rougit** (le serveur rend 200, pas 599) après ses 6 essais ;
3. le `rescue` restaure la sauvegarde, recharge, et **vérifie que l'ancien
   chemin sert de nouveau** (`/rest/apigateway/health` → 200) ;
4. le playbook **échoue bruyamment** avec « BASCULE ANNULÉE ».

C'est la contre-épreuve qui compte : elle prouve qu'une bascule ratée
**revient toute seule**, pendant que le trafic public est encore servi par
Docker. La jouer après la vraie bascule aurait signifié casser un service
public en fonctionnement pour tester le filet.

- [ ] **Step 8 : vérifier qu'aucune trace n'est restée**

```bash
ssh worker-3 'sudo sha256sum /etc/caddy/Caddyfile'
for u in https://dev-wm.gostoa.dev/rest/apigateway/health \
         https://dev-gw-k3s.gostoa.dev/health; do
  printf '%s -> %s\n' "$u" "$(curl -s -o /dev/null -w '%{http_code}' -m 15 "$u")"
done
```

Attendu : l'empreinte est **exactement** celle de T0, et les deux noms rendent
200. **Une porte qui ne rougit jamais ne prouve rien** (leçon F1) — et une
restauration qui laisse une trace n'est pas une restauration.

- [ ] **Step 9 : commit**

```bash
git add ansible/roles/caddy_wm_cutover ansible/wm-cutover.yml \
        docs/superpowers/plans/2026-07-30-f5-bascule-decommission.md
git commit -s -m "feat(f5): rôle caddy_wm_cutover — template, garde d'empreinte, fail-closed prouvé par sabotage"
```

---

### Tâche 5 : La bascule réelle — portes P-a et P-b

- [ ] **Step 1 : caler la fenêtre** — ne pas basculer dans les 150 s de
  redémarrage.

```bash
ssh worker-1 'date -u +%H:%M:%S; sudo k3s kubectl get pods -n wm -l app=wm-apigateway \
  -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,AGE:.metadata.creationTimestamp'
```

Viser un pod `Ready` et **au moins 5 min avant** la prochaine minute
0/20/40. (La garde de cible amont du rôle couvre le cas, mais autant ne pas
consommer 8 min d'attente pour rien.)

- [ ] **Step 2 : LA BASCULE**

```bash
cd ansible
ansible-playbook -i inventory.contabo.ini wm-cutover.yml 2>&1 | tail -30
```

Attendu : play **vert**, y compris la porte P-a (200 + corps contenant
`backend-dev.wm.svc.cluster.local`) et la garde `dev-gw-k3s`.

- [ ] **Step 3 : PORTE P-a, relue à la main depuis le poste**

```bash
curl -s -m 25 -w "\nHTTP %{http_code}\n" \
  https://dev-wm.gostoa.dev/gateway/accounts-read/1.0.0/accounts
```

Attendu : **200** et le JSON de `backend-dev` (`receivedPath`, deux comptes).
**C'est la première invocation data-plane de toute la plateforme** — l'index
`transactionalevents` était à 0 document avant elle.

- [ ] **Step 4 : PORTE P-b — le durcissement, mesuré nom par nom**

```bash
for u in https://dev-wm.gostoa.dev/rest/apigateway/apis \
         https://dev-wm.gostoa.dev/rest/apigateway/health \
         https://dev-wm.gostoa.dev/apigatewayui/ \
         https://dev-wm.gostoa.dev/ \
         https://dev-wm-ui.gostoa.dev/; do
  printf '%s -> %s\n' "$u" "$(curl -s -o /dev/null -w '%{http_code}' -m 15 "$u")"
done
```

Attendu : **404 partout** (contre `401`, `200`, `302`, `200`, `302` en T0
Step 3). Le tableau avant/après est la preuve du resserrement.

- [ ] **Step 5 : l'admin reste servi DEPUIS le cluster** (un durcissement qui
  casse l'exploitation n'est pas un durcissement)

```bash
ssh worker-1 'sudo k3s kubectl run f5-admin -n wm --rm -i --restart=Never \
  --image=localhost:30300/ci/curl:8.10.1@sha256:3a57427a38852a03f246297e21aebaeaab5da747f5444b7b3383c1f4c49a4aa3 \
  -- sh -c "curl -s -o /dev/null -w \"apis depuis un pod: %{http_code}\n\" \
     -u Administrator:manage http://wm-apigateway.wm.svc:5555/rest/apigateway/apis"'
```

Attendu : **200**. Contraste avec le 404 public du Step 4 : la surface a été
retirée du public, pas supprimée.

- [ ] **Step 6 : la transaction est tracée dans ES** (preuve indépendante que
  c'est bien le data-plane qui a servi, et non Caddy qui a inventé un 200)

```bash
ssh worker-1 'sudo k3s kubectl exec -n wm wm-elasticsearch-0 -- \
  curl -s "localhost:9200/gateway_default_analytics_transactionalevents_*/_count"'
```

Attendu : un `count` **strictement supérieur à 0** — là où worker-3 en compte 0
depuis toujours.

- [ ] **Step 7 : garde flotte + commit**

```bash
curl -s -o /dev/null -w 'dev-gw-k3s: %{http_code}\n' -m 15 https://dev-gw-k3s.gostoa.dev/health
git add docs/superpowers/plans/2026-07-30-f5-bascule-decommission.md
git commit -s -m "docs(f5): T5 — bascule jouée, portes P-a et P-b vertes"
```

---

### Tâche 6 : Contre-épreuve du rollback — **avant tout retrait**

C'est la contre-épreuve du GOAL. Elle n'est jouable **que maintenant** : après
`docker rm`, il n'y aurait plus de cible de retour, et la rejouer serait une
fiction.

- [ ] **Step 1 : restaurer**

```bash
cd ansible
ansible-playbook -i inventory.contabo.ini wm-cutover.yml -e wm_cutover_rollback=true 2>&1 | tail -20
```

Attendu : play vert, y compris la porte de restauration
(`/rest/apigateway/health` → 200).

- [ ] **Step 2 : le webMethods Docker sert de nouveau**

```bash
for u in https://dev-wm.gostoa.dev/rest/apigateway/health \
         https://dev-wm.gostoa.dev/rest/apigateway/apis \
         https://dev-wm-ui.gostoa.dev/; do
  printf '%s -> %s\n' "$u" "$(curl -s -o /dev/null -w '%{http_code}' -m 15 "$u")"
done
ssh worker-3 'sudo sha256sum /etc/caddy/Caddyfile'
```

Attendu : `200`, `401`, `302` — **l'état de T0 Step 3**, et l'empreinte de T0
Step 4. Le retour arrière est complet, pas approximatif.

- [ ] **Step 3 : re-basculer**

```bash
cd ansible
ansible-playbook -i inventory.contabo.ini wm-cutover.yml 2>&1 | tail -20
```

- [ ] **Step 4 : P-a de nouveau verte**

```bash
curl -s -m 25 -w "\nHTTP %{http_code}\n" \
  https://dev-wm.gostoa.dev/gateway/accounts-read/1.0.0/accounts
```

Attendu : 200 + JSON de `backend-dev`. Le cycle
bascule → restauration → re-bascule est **complet et vérifié dans les deux
sens**.

- [ ] **Step 5 : commit**

```bash
git add docs/superpowers/plans/2026-07-30-f5-bascule-decommission.md
git commit -s -m "docs(f5): T6 — contre-épreuve rollback exercée, re-bascule verte"
```

---

### Tâche 7 : Décommission de worker-3 — porte P-c

**Ordre interne non négociable :** arrêt → archive froide → **relecture sur
worker-2** → et seulement alors, retrait. L'archive est l'unique filet (choix
exploitant : `stop` **et** `rm` dans la même passe).

- [ ] **Step 1 : arrêter les conteneurs** (le trafic public est déjà sur le
  cluster depuis T6 — cet arrêt ne coupe rien)

```bash
ssh worker-3 'sudo docker stop wm-dev-apigateway wm-dev-elasticsearch; \
  sudo docker ps -a --filter "name=wm-dev-" --format "{{.Names}}\t{{.Status}}"'
```

- [ ] **Step 2 : vérifier que le public n'a rien senti**

```bash
curl -s -o /dev/null -w 'P-a apres arret Docker: %{http_code}\n' -m 25 \
  https://dev-wm.gostoa.dev/gateway/accounts-read/1.0.0/accounts
```

Attendu : **200**. Si c'est 503/502, on est dans la fenêtre trial : réessayer
dans 3 min avant de conclure.

- [ ] **Step 3 : l'archive froide, script scp'é** (aucun secret, mais le motif
  reste : le script part en `scp`, pas dans un argv)

Créer `docs/superpowers/plans/2026-07-30-f5-cold-archive.sh` :

```bash
#!/bin/bash
# F5 T7 — archive FROIDE des données webMethods Docker de worker-3.
# Exécuté SUR worker-3, en root, conteneurs DÉJÀ ARRÊTÉS.
#
# C'est l'UNIQUE filet : l'exploitant a choisi `stop` ET `rm` dans la même
# passe, donc le recouvrement « docker start » n'existera plus. Rien n'est
# retiré avant que la relecture sur worker-2 soit verte.
#
# Ce script ne TRANSFÈRE RIEN. Il fabrique l'archive et son empreinte sur
# place ; l'acheminement se fait par le POSTE DE CONTRÔLE (voir Step 3bis).
# Raison : la joignabilité TCP/22 w3→w2 est mesurée, mais l'AUTHENTIFICATION
# (clé de worker-3 autorisée sur worker-2) ne l'est pas — et F2 achemine déjà
# ses archives via le poste (« transfert WAN via le poste de contrôle »,
# roles/cluster_backup/defaults/main.yml). On ne crée pas une relation de
# confiance SSH nouvelle entre deux nœuds pour une archive unique.
#
#   scp docs/superpowers/plans/2026-07-30-f5-cold-archive.sh worker-3:/tmp/f5-arch.sh
#   ssh worker-3 'sudo bash /tmp/f5-arch.sh'
set -euo pipefail
umask 077

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="/var/tmp/wm-dev-worker3-${STAMP}.tar.gz"

# Refuser si un conteneur tourne encore : une archive « froide » prise à chaud
# serait un mensonge dans le nom du fichier.
if docker ps --filter "name=wm-dev-" --format '{{.Names}}' | grep -q .; then
  echo "REFUS : des conteneurs wm-dev-* tournent encore. Les arrêter d'abord." >&2
  exit 1
fi

# Les volumes Docker portent l'état : on archive les sources de montage plutôt
# que d'entrer dans les conteneurs (arrêtés, donc aucun exec possible).
VOLS="$(docker inspect wm-dev-elasticsearch wm-dev-apigateway \
  --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' | sort -u | sed '/^$/d')"
if [ -z "$VOLS" ]; then
  echo "REFUS : aucun volume trouvé — ne pas retirer les conteneurs à l'aveugle." >&2
  exit 1
fi
echo "volumes à archiver :"; echo "$VOLS"

# shellcheck disable=SC2086
tar -czf "$OUT" $VOLS
sha256sum "$OUT" | tee "${OUT}.sha256"
ls -lh "$OUT"
echo "ARCHIVE-PRETE $OUT"
```

Puis, sur le poste :

```bash
chmod +x docs/superpowers/plans/2026-07-30-f5-cold-archive.sh
scp docs/superpowers/plans/2026-07-30-f5-cold-archive.sh worker-3:/tmp/f5-arch.sh
ssh worker-3 'sudo bash /tmp/f5-arch.sh'
```

- [ ] **Step 3bis : acheminer l'archive vers worker-2 par le poste de contrôle**

```bash
ARCH=$(ssh worker-3 'sudo ls -1t /var/tmp/wm-dev-worker3-*.tar.gz | head -1')
BASE=$(basename "$ARCH")
echo "acheminement de $BASE (via le poste)"
ssh worker-2 'sudo mkdir -p /var/lib/k3s-backups/offsite/wm-dev-worker3'
ssh worker-3 "sudo cat $ARCH" \
  | ssh worker-2 "sudo tee /var/lib/k3s-backups/offsite/wm-dev-worker3/$BASE >/dev/null"
ssh worker-3 "sudo cat ${ARCH}.sha256" \
  | sed "s#/var/tmp/#/var/lib/k3s-backups/offsite/wm-dev-worker3/#" \
  | ssh worker-2 "sudo tee /var/lib/k3s-backups/offsite/wm-dev-worker3/${BASE}.sha256 >/dev/null"
ssh worker-2 "sudo chmod 600 /var/lib/k3s-backups/offsite/wm-dev-worker3/*"
```

Le `sed` réécrit le chemin dans le fichier d'empreinte : `sha256sum -c` compare
un chemin **et** un condensat, et l'archive n'est plus dans `/var/tmp`.

- [ ] **Step 4 : PORTE DURE — l'archive est RELUE sur worker-2**

Une empreinte qui concorde prouve un transfert, pas une archive exploitable
(leçon F2). On la vérifie, on l'ouvre, et on y cherche des chemins d'index ES.

```bash
ssh worker-2 'cd /var/lib/k3s-backups/offsite/wm-dev-worker3 && \
  A=$(ls -1t wm-dev-worker3-*.tar.gz | head -1); echo "archive: $A"; \
  sudo sha256sum -c "${A}.sha256" && echo "EMPREINTE-OK"; \
  echo "entrées: $(sudo tar -tzf "$A" | wc -l)"; \
  sudo tar -tzf "$A" | grep -i "indices" | head -5; \
  sudo du -h "$A"'
```

Attendu : `EMPREINTE-OK`, un nombre d'entrées non nul, et des chemins d'index ES
(`nodes/0/indices/…`). **Si l'un de ces trois échoue, ARRÊTER : ne rien
retirer.** C'est la seule chose qui se tient entre `docker rm` et une perte
définitive.

- [ ] **Step 4bis : ne laisser aucune copie traînante sur worker-3**

```bash
ssh worker-3 "sudo rm -f /var/tmp/wm-dev-worker3-*.tar.gz* /tmp/f5-arch.sh"
```

- [ ] **Step 5 : retirer les conteneurs et leurs volumes**

**Mesuré le 2026-07-30 (lecture seule) : il n'y a qu'UN volume.**
`wm-dev-apigateway` n'a **aucun** montage — il est sans état, tout vit dans ES
(cohérent avec la note F3 « gateway sans volume »). `wm-dev-elasticsearch` porte
`webmethods-dev_es-dev-data` → `/var/lib/docker/volumes/…/_data`, **108 Mo**,
ce qui recoupe les 100,1 Mo relevés côté ES (`_cat/allocation`).

```bash
ssh worker-3 'sudo docker rm wm-dev-apigateway wm-dev-elasticsearch; \
  sudo docker volume ls --format "{{.Name}}" | grep -i "wm\|elastic\|webmethods" || echo "(aucun volume nommé)"'
```

Puis retirer le volume **nommé explicitement**. **Jamais `volume prune`** : il
toucherait des volumes hors périmètre.

```bash
ssh worker-3 'sudo docker volume rm webmethods-dev_es-dev-data'
```

Relire la liste après coup : le volume doit avoir disparu, et **aucun autre**.

- [ ] **Step 6 : déposer LE cron** — il n'y en a qu'un

**Correction actée en T0 :** le handoff F4 (point 4) annonçait un keepalive
hegemon `*/25` « en doublon du cron root, ~5 min de service perdues par heure ».
**Il n'existe pas.** Mesuré : crontab `root` = une seule ligne
(`*/20 … docker restart wm-dev-apigateway`) ; crontab `hegemon` = un **ping
d'uptime `*/1`** vers `status.gostoa.dev`, étranger à webMethods ; rien dans
`/etc/cron.d` ; aucun timer systemd.

**Ne pas toucher au ping `*/1`** : il surveille l'hôte, pas la gateway. Le motif
de filtrage ci-dessous (`wm-dev|wm-apigateway`) ne le capture pas — c'est
délibéré, et le `diff` relu avant application le confirme. La boucle parcourt
quand même les deux crontabs : c'est ce qui rend la preuve du non-effet
explicite plutôt que supposée.

**Le cron est GÉRÉ PAR ANSIBLE** — relevé le 2026-07-30 :

```
#Ansible: wm-dev-apigateway-restart-trial
*/20 * * * * docker restart wm-dev-apigateway >/dev/null 2>&1
```

Il a été posé par `ansible/wm-restart-cron.yml` via le module `cron`
(`name: "wm-dev-apigateway-restart-trial"`). **On le retire donc par le même
module**, pas par un `grep` artisanal : `state: absent` enlève le marqueur *et*
l'entrée, atomiquement et idempotemment, sans jamais risquer de vider la
crontab. (Le « 2 lignes » que compte un `grep -c wm-dev` est ce marqueur plus
l'entrée — pas deux crons.)

```bash
cd /Users/potomitan/stoa-platform/stoa-labs/ansible
ansible worker-3 -i inventory.contabo.ini -b -m cron \
  -a 'name="wm-dev-apigateway-restart-trial" state=absent'
```

Relecture :

```bash
ssh worker-3 'sudo crontab -l; echo "--- lignes wm restantes : $(sudo crontab -l | grep -c wm-dev || true) ---"'
```

Attendu : plus aucune ligne `wm-dev`, et la crontab **non vidée** de ses
éventuelles autres entrées.

**Puis vérifier la crontab `hegemon` sans y toucher.** Elle contient un ping
d'uptime `*/1` vers `status.gostoa.dev`, **étranger à webMethods** : il surveille
l'hôte, pas la gateway, et doit rester. Le relevé ci-dessous rend le non-effet
explicite plutôt que supposé :

```bash
ssh worker-3 'echo "== hegemon (NE PAS MODIFIER) =="; crontab -l
             echo "== lignes wm dans la crontab hegemon =="
             crontab -l | grep -i "wm-dev\|apigateway" || echo "  aucune — rien a deposer ici"'
```

Vérifier aussi qu'aucun **timer systemd** ne prend le relais — c'est la
dernière forme sous laquelle un mécanisme de relance pourrait subsister :

```bash
ssh worker-3 'systemctl list-timers --all 2>/dev/null | grep -i "wm\|apigateway" || echo "aucun timer wm"
             systemctl list-units --all 2>/dev/null | grep -i "wm-dev\|apigateway" || echo "aucune unite wm"'
```

Si un mécanisme de relance subsiste sous une autre forme, le **consigner et le
déposer** avant de déclarer P-c : un conteneur retiré qu'un timer tente de
relancer toutes les 25 min produirait du bruit d'erreur permanent.

- [ ] **Step 7 : PORTE P-c**

```bash
ssh worker-3 'echo "=== conteneurs wm-dev-* ==="; \
  sudo docker ps -a --filter "name=wm-dev-" --format "{{.Names}}" || true; \
  echo "(vide attendu)"; \
  echo "=== Caddy ==="; systemctl is-active caddy; \
  echo "=== agent k3s ==="; systemctl is-active k3s-agent 2>/dev/null || systemctl is-active k3s 2>/dev/null; \
  echo "=== docker restant ==="; sudo docker ps --format "{{.Names}}"'
```

Attendu : aucun `wm-dev-*`, Caddy `active`, l'agent k3s `active`. worker-3 ne
porte plus que Caddy (et son agent de cluster, qui est ce qui rend la bascule
possible).

- [ ] **Step 8 : P-a survit à la décommission** (la vraie question : le public
  ne dépendait-il de rien de ce qu'on vient de détruire ?)

```bash
curl -s -m 25 -w "\nHTTP %{http_code}\n" \
  https://dev-wm.gostoa.dev/gateway/accounts-read/1.0.0/accounts
curl -s -o /dev/null -w 'dev-gw-k3s: %{http_code}\n' -m 15 https://dev-gw-k3s.gostoa.dev/health
```

- [ ] **Step 9 : mettre à jour le playbook du cron devenu sans objet**

`ansible/wm-restart-cron.yml` posait le cron root sur worker-3. Il n'a plus
d'objet : ajouter un en-tête qui le dit, **sans le supprimer** (il documente
comment le double-run a été tenu).

```yaml
# OBSOLÈTE depuis F5 (2026-07-30) : le webMethods Docker de worker-3 est
# décommissionné, et le cycle trial est porté en cluster par le CronJob
# wm-restarter (stoa deploy/bootstrap/wm/apigateway/cronjob.yaml).
# Conservé comme trace de la façon dont le double-run F3–F5 a été tenu.
# NE PAS REJOUER : il recréerait un cron visant un conteneur inexistant.
```

- [ ] **Step 10 : commit**

```bash
git add docs/superpowers/plans/2026-07-30-f5-cold-archive.sh \
        ansible/wm-restart-cron.yml \
        docs/superpowers/plans/2026-07-30-f5-bascule-decommission.md
git commit -s -m "feat(f5): décommission de worker-3 — archive froide relue, conteneurs et crons retirés"
```

---

### Tâche 8 : Re-mesure, consignation, GOAL, handoff

- [ ] **Step 1 : re-mesurer le cycle trial sur au moins DEUX cycles, à travers
  le nom public** (la spéc n'en avait observé qu'un ; le chiffre gravé doit
  être un intervalle si la dispersion est forte)

```bash
ssh worker-3 'nohup sudo bash -c "
 : > /tmp/f5-gap-public.log
 for i in \$(seq 1 600); do
   C=\$(curl -s -o /dev/null -w \"%{http_code}\" --max-time 6 \
     https://dev-wm.gostoa.dev/gateway/accounts-read/1.0.0/accounts)
   echo \"\$(date -u +%H:%M:%S) \$C\" >> /tmp/f5-gap-public.log
   sleep 5
 done" >/dev/null 2>&1 & echo "sonde publique lancee (50 min)"'
```

Après ~45 min :

```bash
ssh worker-3 'sudo awk "{ if (\$2 != prev) { print \$1, \$2; prev=\$2 } }" /tmp/f5-gap-public.log; \
  echo "--- decompte ---"; \
  sudo awk "{c[\$2]++} END {for (k in c) print k, c[k]*5 \"s\"}" /tmp/f5-gap-public.log'
```

Consigner : les deux coupures, leur durée, et **le code rendu pendant la
coupure** (attendu : `503` grâce au `handle_errors`, pas `502`).

- [ ] **Step 2 : la donnée survit au redémarrage** (l'état vit dans ES, pas
  dans le pod)

Après une coupure observée au Step 1 :

```bash
curl -s -m 25 -w "\nHTTP %{http_code}\n" \
  https://dev-wm.gostoa.dev/gateway/accounts-read/1.0.0/accounts
```

Attendu : 200 + le même JSON. `accounts-read` n'a pas été republiée : elle a
survécu, portée par le PVC ES.

- [ ] **Step 3 : écrire la section « Preuve d'exécution »** dans ce plan —
  sorties réelles horodatées, tableau avant/après de la surface publique,
  chemin reçu par `backend-dev`, `transactionalevents` avant (0) et après,
  durées des deux coupures, et l'ordre effectif des gestes.

- [ ] **Step 4 : mettre à jour le GOAL**

Dans `poc-control-plane-federation/GOAL-socle-vers-gateway-2026-07-28.md` :
- passer **F5 à FERMÉ** avec les chiffres mesurés ;
- **corriger la contre-épreuve** « rollback = une ligne de Caddyfile » en
  « restauration de la sauvegarde horodatée, un geste » (spéc § D4), en disant
  que la formulation initiale était inexacte ;
- acter la **dette nouvelle** : spike « répliques wM décalées sur ES partagé » ;
- barrer les dettes soldées : sauvegarde du ns `wm`, point d'amont F5, backend
  fictif d'`accounts-read`, chiffre faux du cycle trial ;
- **corriger** le point 4 du handoff F4 : le keepalive hegemon `*/25` n'existe
  pas (relevé T0) — la dette était imaginaire, et la retirer sans le dire
  laisserait croire qu'on l'a soldée ;
- noter que la **migration ES a été écartée par décision** (§ D6), pas oubliée.

- [ ] **Step 5 : écrire le handoff**
  `poc-control-plane-federation/HANDOFF-2026-07-30-F5-BASCULE.md` — même forme
  que les précédents : « en une phrase », ce qui a été livré, la porte en clair,
  les constats de conception, ce qui reste ouvert (gestes exploitant).

Y faire figurer, au minimum :
- l'archive `wm-dev-worker3-*.tar.gz` sur worker-2 (`/var/lib/k3s-backups/offsite/wm-dev-worker3/`),
  **hors rotation** de `cluster_backup` — donc à gérer à la main ;
- `/root/vault-init-ci.txt` sur worker-1, toujours à récupérer puis `shred -u` ;
- la contre-épreuve NetworkPolicy #2824 à jouer avec le **bon** nom
  (`elasticsearch.wm.svc:9200`, pas `wm-elasticsearch.wm.svc`) ;
- l'image `hashicorp/vault:1.18` des pods agents non épinglée par digest ;
- le spike « répliques décalées ».

- [ ] **Step 6 : commit final**

```bash
git add docs/superpowers/plans/2026-07-30-f5-bascule-decommission.md \
        poc-control-plane-federation/GOAL-socle-vers-gateway-2026-07-28.md \
        poc-control-plane-federation/HANDOFF-2026-07-30-F5-BASCULE.md
git commit -s -m "docs(f5): F5 FERMÉ — preuve d'exécution, GOAL soldé, handoff de session"
```

---

## Ce que ce plan ne fait pas

- Aucun enregistrement DNS, aucun Ingress, aucun NodePort, aucune règle ufw.
- Aucune haute disponibilité wM (spike séparé, § D9 de la spéc).
- Aucune restauration d'état ES vers le cluster (§ D6).
- Les quatre noms `*-k3s.gostoa.dev` restent sur `localhost:30080`, intouchés —
  le template les reproduit **à l'identique** et le `--diff` du T4 Step 6 le
  vérifie.
- La rotation de l'archive froide sur worker-2 (hors `cluster_backup`) : signalée
  au handoff, pas automatisée.
