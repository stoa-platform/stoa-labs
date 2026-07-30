# HANDOFF — Session 2026-07-30 : F5 FERMÉ, lot 2 terminé

_Dépôt `stoa-labs`, branche `main`. Session `/goal F5`, exécution autonome
(brainstorm → spéc → plan → exécution). Merge de PR et écritures dans le
Caddyfile portés par l'exploitant — refusés à l'agent, à raison._

## En une phrase

**Le nom public est servi par la gateway du cluster, l'admin REST a quitté
l'Internet ouvert, et worker-3 ne porte plus que Caddy** — trois portes vertes,
trois sabotages joués, et le rollback exercé avant tout retrait.

## Les trois portes

| Porte | Mesure |
|---|---|
| **P-a** | `https://dev-wm.gostoa.dev/gateway/accounts-read/1.0.0/accounts` → **200** + corps de `backend-dev`. **Première invocation data-plane de toute la plateforme** : `transactionalevents` de worker-3 était à 0 document depuis toujours. |
| **P-b** | Les cinq chemins d'admin → **404** (contre `401`/`200`/`302`/`200`/`302` au relevé T0). Et **200 depuis un pod** : retiré du public, pas supprimé. |
| **P-c** | worker-3 : **Caddy et son agent k3s seuls**. Aucun conteneur Docker, crontab root vide, volume retiré, ping d'uptime `hegemon` préservé. |
| Garde flotte | Les **quatre** noms `*-k3s.gostoa.dev/health` → 200, avant et après. |

Les portes ont été relues **après** la décommission : la question n'était pas
« a-t-on retiré » mais « le public dépendait-il de ce qu'on a détruit ».

## Trois sabotages, pas un

1. **Cible amont fausse** → la garde **refuse d'écrire**, `changed=0`, aucune
   sauvegarde créée.
2. **Porte à code impossible** (599) → écriture, `caddy validate` vert,
   rechargement, **porte rouge**, `rescue` qui restaure et **vérifie que
   l'ancien chemin sert de nouveau**, échec bruyant. Empreinte revenue à
   l'identique.
3. **Rollback explicite** depuis l'état basculé → les trois gardes mordent, dont
   « empreinte d'avant-bascule retrouvée à l'identique ».

Le rollback est donc éprouvé **dans les deux sens** (automatique et explicite),
et **avant** tout retrait : après `docker rm`, il n'y aurait plus eu de cible.

## Ce que la mesure a changé au jalon

- **Aucun trafic public d'API à préserver** (`transactionalevents` = 0 ; 29
  accès d'admin depuis 3 IP de l'exploitant). D'où une porte formulée en
  **invocation réelle** plutôt qu'en « le trafic est servi » — qu'une gateway ne
  servant rien aurait tenue.
- **La « migration des 109 Mo d'ES » n'était pas un sujet** : 92 % de logs
  d'audit, 7 APIs de spike sans consommateur. Archivé, **rien restauré**
  (restaurer un `tar` contournerait la chaîne GitOps qu'on venait de prouver).
  L'archive du cluster pèse **4,7 Mo** contre 108 Mo côté worker-3 : l'écart
  mesure ce que valait ce « volume ».
- **Un durcissement non prévu au jalon** : `/rest/apigateway/apis` rendait
  **401 publiquement**. Basculer Caddy à l'identique l'aurait re-publié en
  silence contre la doctrine §4.1.
- **« Rollback = une ligne de Caddyfile » corrigé** : la surface change de
  forme, donc c'est la restauration d'une sauvegarde — un geste, pas une ligne.

## Le cycle trial, chiffré deux fois

| Mesure | Portée | Résultat |
|---|---|---|
| Interne, `/rest/apigateway/health` | 1 cycle | 150 s |
| **Publique, invocation data-plane** | **2 cycles** | **120 s et 235 s** → ~85 % |

**Le data-plane revient ~85 s après le health** : l'API doit être chargée, pas
seulement le process vivant. Un client voit donc plus long qu'une sonde de
santé — et c'est le client qui compte. La dispersion d'un facteur 2 impose un
**intervalle**, pas un point.

`handle_errors` tient l'intention (340 s de 503 sur 355 s) mais **pas
totalement** : 10 s de **500** (webMethods répond 500 pendant son arrêt, Caddy
relaie ce 5xx amont) et 5 s de silence.

## Sept défauts trouvés en exécutant — dont cinq dans mon propre travail

1. **`backend-dev` aurait fait rougir la porte pour une raison introuvable** :
   `HTTPServer` mono-connexion + keep-alive HTTP/1.1 → une connexion tenue
   faisait **expirer 3 appels concurrents sur 3**. Corrigé en
   `ThreadingHTTPServer`, reprouvé 3/3 en moins de 5 ms. Trouvé en lançant le
   script **avant** de le déployer.
2. **La sauvegarde du ns `wm` aurait échoué puis rejeté une archive saine** : les
   3 pods `wm-restarter` en `Succeeded` ne satisfaisaient jamais l'attente de
   quiescence, et le contrôle post-archivage les comptait pour des « pods
   réapparus » → quarantaine. Corrigé par `--field-selector`.
3. **Le CronJob `*/20` tirait pendant la fenêtre de sauvegarde** : suspension
   ajoutée, avec retour à l'**état capturé** (pas « reprise » à l'aveugle).
4. **Un `rollback` hors séquence restaurait une config du 2026-07-27** en
   annonçant un succès. Garde d'entrée ajoutée et testée.
5. **Le `--check` déclenchait un `rescue`** cherchant une sauvegarde jamais
   créée à blanc.
6. **Mon garde-fou d'archive a refusé une archive valide** :
   `set -o pipefail` + `grep -q` — le `-q` sort à la première correspondance,
   ferme le tube, `tar` reçoit SIGPIPE, le pipeline passe pour un échec.
   **Plus l'archive est valide, plus sûrement le contrôle échoue.** Corrigé en
   `grep -ci`.
7. **`transactionalevents > 0` était une assertion fausse de mon plan** : ce type
   d'événement exige une politique de journalisation d'invocation. La preuve
   indépendante est venue des **journaux de `backend-dev`**
   (`GET /accounts/accounts 200`) : un Service ClusterIP a journalisé une requête
   HTTPS publique, ce qui prouve la chaîne au bout plutôt qu'en son milieu.

**Le piège `0700 root`, rencontré trois fois** : un `cd` ou un glob dans
`/var/lib/k3s-backups/offsite` échoue sans `sudo bash -c` pour le shell
**entier** — préfixer chaque commande ne suffit pas. C'est ce qui avait fait
croire les archives F2 absentes.

## Deux écarts de documentation corrigés

- **Le keepalive hegemon `*/25` du handoff F4 n'existe pas.** Source probable de
  l'erreur : un `grep -c wm-dev` compte 2 lignes parce que le module Ansible
  écrit un marqueur `#Ansible:` au-dessus de l'entrée. Corrigé sur place, pas
  coché : une dette retirée sans dire qu'elle était imaginaire laisse croire
  qu'on l'a réglée.
- **Les archives F2 sont bien sur worker-2** (piège `0700` ci-dessus).

## Livré

| Objet | Où |
|---|---|
| Spéc F5 (D1–D10) | `docs/superpowers/specs/2026-07-30-f5-bascule-decommission-design.md` |
| Plan F5 + preuves T0→T8 | `docs/superpowers/plans/2026-07-30-f5-bascule-decommission.md` |
| Rôle de bascule (4 gardes, template, fail-closed) | `ansible/roles/caddy_wm_cutover/` + `ansible/wm-cutover.yml` |
| Script d'archive froide | `docs/superpowers/plans/2026-07-30-f5-cold-archive.sh` |
| Enveloppe des gestes exploitant | `docs/superpowers/plans/2026-07-30-f5-unblock.sh` |
| Sauvegarde étendue au ns `wm` + 2 bugs corrigés | `ansible/roles/cluster_backup/` |
| `backend-dev`, ClusterIP épinglée | `stoa` PR **#2825** (mergée, `dc2cd17b`) |

## Reste ouvert (gestes exploitant)

1. **`stoa-labs` a ~30 commits non poussés** sur `main`, dont **toute la preuve
   F4 et tout F5**. Ce travail n'existe que sur ce poste. **Priorité.**
2. **Chiffre faux dans `stoa`** : le commentaire du CronJob annonce « 150 s /
   87,5 % ». À remplacer par « 120–235 s côté data-plane public, ~85 % ». PR de
   commentaire seul — mais un chiffre connu comme faux est pire qu'une
   estimation, puisqu'il se présente comme une mesure.
3. **`/root/vault-init-ci.txt` (worker-1)** : à récupérer hors ligne puis
   `sudo shred -u`. Après le shred, les gestes quorum redeviennent interactifs
   (`ssh -t` + `read` **ne marche pas** dans le harnais agent).
4. **Contre-épreuve NetworkPolicy #2824** avec le **bon** nom
   (`elasticsearch.wm.svc:9200`). Indice recueilli : ES injoignable depuis
   l'hôte worker-3 **par IP directe** (donc refus réseau, pas NXDOMAIN) alors
   que la gateway répond du même hôte.
5. **`wm-elasticsearch` restera `OutOfSync`** : défauts Kubernetes sur
   `volumeClaimTemplates`, champ immuable. Correctif d'une ligne
   (`volumeMode: Filesystem` en Git, ou `ignoreDifferences`). Ce qui compte
   n'est pas la dérive mais l'**alerte allumée en permanence**.
6. ~~**Archive froide de worker-3**, **hors rotation** : à gérer à la main.~~
   **TRAITÉ le 2026-07-30 — et la formulation ci-dessus était trompeuse.**
   « Hors rotation » se lisait comme un manque ; c'est en réalité l'état
   **correct**. La rotation de `cluster_backup` balaie
   `offsite/pvc-<ns>-<claim>-*.tar.gz` — ancré sur le préfixe `pvc-` et à la
   racine d'`offsite` — alors que cette archive vit dans un sous-répertoire avec
   un autre préfixe : aucune correspondance possible (vérifié en lisant le
   rôle). Et c'est heureux, car l'archive est **terminale** : worker-3 étant
   décommissionné, rien ne la régénérera, donc une rotation ne pourrait que la
   détruire.
   Le risque réel n'était pas la suppression mais **l'oubli** — elle n'existait
   que dans ce handoff. Livré : `ansible/archive-verify.yml`, qui relit
   l'empreinte, ouvre l'archive, vérifie qu'elle porte bien des index ES, et
   rappelle ce qu'elle contient et la rétention décidée. Joué **vert**
   (empreinte OK, 1995 entrées, 1862 chemins d'index) **et saboté** (motif
   introuvable → `ARCHIVE INEXPLOITABLE`, l'empreinte restant OK : le contrôle
   distingue ses causes).
   **Rétention : conservation indéfinie**, décidée le 2026-07-30. 17 Mo pour
   356 Go libres — le coût de la garder est nul, celui de la perdre définitif.
   À ne supprimer que sur décision explicite.
7. **Image `hashicorp/vault:1.18`** des pods agents non épinglée par digest.
8. **Spike hors jalons F** : deux répliques wM 10.15 à redémarrages décalés sur
   un ES partagé, pour supprimer les 120–235 s. Exige un vrai clustering
   (Terracotta/Ignite) **non instruit** — n'a pas été tenté, et ne doit pas
   l'être en fin de lot.

## Où en est le lot 2

**F1 ✔ F2 ✔ F3 ✔ F4 ✔ F5 ✔** — le lot 2 est terminé. Le test du GOAL est tenu :
un push dans Gitea publie une API sur une gateway webMethods du cluster, avec
des identifiants obtenus par l'identité du pod, un statut rouge quand ça échoue,
et depuis F5 **cette API est réellement invocable depuis l'Internet**. Les jalons
E1–E6 du GOAL parent ont leur plateforme.

_Socle empirique : § T0→T8 du plan F5 (sorties réelles horodatées), trois
sabotages, deux sondes de disponibilité à 5 s, et la garde flotte vérifiée à
chaque phase._
