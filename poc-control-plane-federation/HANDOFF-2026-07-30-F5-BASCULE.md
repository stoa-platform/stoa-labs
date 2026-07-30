# HANDOFF — Session 2026-07-30 : F5 cadré, outillé, **bloqué sur deux gestes**

_Dépôt `stoa-labs`, branche `main`. Session `/goal F5`, exécution autonome
(brainstorm → spéc → plan → exécution). **F5 n'est PAS fermé** : les trois
portes P-a/P-b/P-c sont toutes en aval de deux gestes refusés à l'agent._

## En une phrase

Tout ce que F5 exige est écrit, mesuré et éprouvé — **sauf la bascule
elle-même**, qui écrit dans le Caddyfile terminant le TLS de toute la flotte, et
le merge de la PR qui pose le backend réel. Les deux gestes ont été **tentés dans
cette session** et refusés par le classifieur ; aucun contournement n'a été
tenté.

## Les deux gestes qui débloquent

```bash
gh pr merge 2825 --repo stoa-platform/stoa --squash --delete-branch

cd ~/stoa-platform/stoa-labs/ansible
ansible-playbook -i inventory.contabo.ini wm-cutover.yml -e wm_cutover_verify_expect=599   # sabotage 2 : doit ROUGIR et se restaurer seul
ansible-playbook -i inventory.contabo.ini wm-cutover.yml                                    # la bascule
```

Le sabotage 2 est **volontairement** voué à l'échec : il éprouve le chemin
`rescue` pendant que Docker sert encore. Attendu : écriture, `caddy validate`
vert, rechargement, porte rouge après 6 essais, restauration automatique,
vérification que `/rest/apigateway/health` public rend de nouveau 200, puis
« BASCULE ANNULÉE ». Le jouer **après** la vraie bascule aurait signifié casser
un service public en fonctionnement pour tester le filet.

## Ce que la mesure a changé au cadrage de F5

Le jalon décrit par le GOAL n'existait pas tel quel. Trois requalifications,
actées dans la spéc plutôt que contournées :

1. **Aucun trafic public d'API à préserver.**
   `gateway_default_analytics_transactionalevents_*` de worker-3 = **0 document**.
   Aucune API n'a jamais été invoquée en data-plane. Les seuls accès externes
   tracés sont **29 événements d'admin depuis 3 IP grand public** (les sessions
   console de l'exploitant). Une porte « le trafic est servi » serait tenue par
   une gateway qui ne sert rien.
2. **La « migration des ~109 Mo d'ES » n'est pas un sujet.** 91,8 Mo sur 100,1
   (92 %) sont des logs d'audit produits par le cycle de redémarrage
   (`ALIAS_MANAGEMENT UPDATE local`, réécrit à chaque boot). Les 7 APIs (61 ko)
   sont des artefacts de spike sans consommateur → **on archive, on ne restaure
   pas** : restaurer un `tar` contournerait la chaîne GitOps qu'on vient de
   prouver (ADR-076).
3. **« Rollback = une ligne de Caddyfile » est faux** dès que la surface publique
   change de forme. Le retour arrière reste **un geste**, mais c'est la
   restauration d'une sauvegarde horodatée. La contre-épreuve du GOAL est à
   corriger, pas seulement à cocher.

**Et un durcissement est apparu** : `dev-wm.gostoa.dev/rest/apigateway/apis` rend
**401 publiquement** — l'admin REST de webMethods est sur l'Internet ouvert
derrière un basic auth, alors que la contre-épreuve F3 avait mesuré 6/6 refus
pour la gateway du cluster. Basculer Caddy à l'identique aurait **re-publié**
cette surface. F5 la ferme (404) au lieu de reporter le défaut.

## Le point d'amont : tranché par la mesure

Le GOAL exigeait `curl <clusterIP>:5555/rest/apigateway/health` **depuis l'hôte**
worker-3, pas depuis un pod. Résultat : **200 en 18,7 ms**.
→ **Voie 1 acquise** (ClusterIP épinglée). Ni Ingress (casserait la
contre-épreuve F3), ni NodePort (publierait un admin REST wM sur les IP publiques
de tous les nœuds).

## Le cycle trial, rechiffré

**150 s de coupure par cycle de 20 min** (07:20:23 → 07:22:54, sonde à 5 s depuis
l'hôte) → **87,5 % de disponibilité**. Le commentaire du CronJob annonçait
« retour Ready ~5 min ; ~15 min de service par cycle » : **faux d'un facteur 2**,
corrigé dans la PR #2825. Les jobs `wm-restarter` durent 4-9 s — les 150 s sont
le démarrage de webMethods.

Réserve honnête : **un seul cycle observé**. Le plan (T8) le rejoue sur au moins
deux cycles à travers le nom public avant de graver le chiffre.

## Cinq défauts trouvés en exécutant, dont quatre dans mon propre travail

1. **`backend-dev` aurait fait rougir la porte F5 pour une raison introuvable
   côté cluster.** `HTTPServer` est mono-connexion ; avec
   `protocol_version = HTTP/1.1` la connexion reste ouverte. Mesuré : une
   connexion keep-alive tenue faisait **expirer 3 appels concurrents sur 3**.
   Corrigé en `ThreadingHTTPServer`, reprouvé **3/3 en moins de 5 ms**. Trouvé en
   lançant le script sur le poste **avant** de le déployer.
2. **La sauvegarde du ns `wm` aurait échoué, puis rejeté une archive saine.**
   `kubectl get pods -n wm -o name` rend **5** pods dont **3 `Succeeded`**
   (`wm-restarter`, `successfulJobsHistoryLimit: 3`), alors que l'attente de
   quiescence exige une sortie **vide** : 36 essais puis mort du play. Pire, le
   contrôle post-archivage les comptait pour des « pods réapparus » →
   **quarantaine et rejet**. Une garde qui rejette le cas normal ne protège
   rien : elle apprend à ignorer les alertes. Corrigé par
   `--field-selector=status.phase!=Succeeded,!=Failed`.
3. **Un `rollback` hors séquence restaurait une configuration du 2026-07-27** en
   annonçant un retour arrière réussi (le répertoire contient aussi les
   sauvegardes de `caddy_cutover`). Garde d'entrée ajoutée et **testée** : refus,
   `changed=0`.
4. **Le `--check` déclenchait un `rescue`** cherchant une sauvegarde que le mode
   à blanc n'avait jamais créée : les vérifications d'après-écriture s'affirmaient
   alors que rien n'était écrit.
5. **Ma dépose de cron était artisanale.** Le cron porte le marqueur
   `#Ansible: wm-dev-apigateway-restart-trial` — posé par le module `cron`. Un
   `crontab -l | grep -v | crontab -` risquait de vider la crontab et défaisait à
   la main ce qu'un module gère. Remplacé par `state=absent`.

## Deux écarts de documentation élucidés

- **Le keepalive hegemon `*/25` du handoff F4 (point 4) n'existe pas.** Mesuré :
  crontab `root` = **une seule** entrée (`docker restart wm-dev-apigateway`, plus
  son marqueur Ansible — le « 2 lignes » d'un `grep -c` est marqueur + entrée) ;
  crontab `hegemon` = un **ping d'uptime `*/1`** vers `status.gostoa.dev`,
  **étranger à webMethods**, qui surveille l'hôte et **doit rester**. Rien dans
  `/etc/cron.d`, aucun timer systemd. La dette « ~5 min de service perdues par
  heure » était **imaginaire** : à corriger au GOAL, pas à cocher comme soldée.
- **Les archives F2 sont bien sur worker-2.** Un premier `ls` sans `sudo` les
  avait fait croire absentes (répertoire `0700 root`). 8 fichiers, 1,5 Go, deux
  runs. Nommage relevé : `pvc-<ns>-<pvc>-<stamp>.tar.gz`.

## Livré

| Objet | Où |
|---|---|
| Spéc F5 (D1–D10) | `docs/superpowers/specs/2026-07-30-f5-bascule-decommission-design.md` |
| Plan F5 (8 tâches) + relevé T0 + tableau des preuves | `docs/superpowers/plans/2026-07-30-f5-bascule-decommission.md` |
| Script d'archive froide (garde testée) | `docs/superpowers/plans/2026-07-30-f5-cold-archive.sh` |
| Rôle de bascule (4 gardes, template, fail-closed) | `ansible/roles/caddy_wm_cutover/` + `ansible/wm-cutover.yml` |
| Sauvegarde étendue au ns `wm` + 2 bugs corrigés | `ansible/roles/cluster_backup/` |
| `backend-dev`, ClusterIP épinglée, cycle rechiffré | `stoa` **PR #2825** — **à merger** |

## État du terrain à la fin de la session

**Rien n'est à moitié fait.** Identique au relevé T0 :

- empreinte du Caddyfile `5fab7a255ef128b4…` **inchangée** ; une seule
  sauvegarde, celle du 2026-07-27 (antérieure à cette session) ;
- les deux conteneurs `wm-dev-*` en service, cron `*/20` en place ;
- surface publique intacte : `health` 200, `apis` 401, `dev-wm-ui` 302,
  `dev-gw-k3s` 200 ;
- ns `wm` sain, `wm-restarter` actif (`suspend=false`).

## Reste ouvert (gestes exploitant)

1. **Les deux gestes ci-dessus** — chemin critique de F5.
2. **`stoa-labs` a 18 commits non poussés sur `main`**, dont **toute la preuve
   F4** de la session précédente. Ce travail n'existe que sur ce poste.
3. **`/root/vault-init-ci.txt` (worker-1)** : toujours à récupérer hors ligne
   puis `sudo shred -u`. Après le shred, les gestes quorum redeviennent
   interactifs (`ssh -t` + `read` **ne marche pas** dans le harnais agent).
4. **Contre-épreuve NetworkPolicy #2824** à jouer avec le **bon** nom :
   `elasticsearch.wm.svc:9200` (et non `wm-elasticsearch.wm.svc`, qui n'existe
   pas). Indice recueilli : ES est injoignable depuis l'hôte worker-3 **par IP
   directe** (donc sans DNS — c'est un refus réseau, pas un NXDOMAIN) alors que
   la gateway répond depuis le même hôte, et la policy restreint bien l'ingress
   aux pods `app=wm-apigateway`. La contre-épreuve propre depuis un pod `ci`
   reste à jouer.
5. **Image `hashicorp/vault:1.18`** des pods agents non épinglée par digest.
6. **Dette nouvelle, hors F5** : spike « deux répliques wM 10.15 à redémarrages
   décalés (A à :00/:20/:40, B à :10/:30/:50) sur un ES partagé » — donnerait une
   disponibilité continue. **Rien n'a été tenté** : cela exige un vrai clustering
   (Terracotta/Ignite) non instruit, et l'improviser juste avant de détruire
   l'unique autre copie serait exactement la faute que ce dépôt évite.
7. **L'archive froide de worker-3** (à venir en T7) ira dans
   `/var/lib/k3s-backups/offsite/wm-dev-worker3/` sur worker-2, **hors rotation**
   de `cluster_backup` : à gérer à la main.

_Socle empirique : mesures du 2026-07-29 soir et du 2026-07-30 (sonde de
disponibilité à 5 s ; inventaire ES des deux gateways ; surface publique relevée
nom par nom ; joignabilité w3→w2 ; découverte des volumes Docker en lecture
seule), sabotage 1 et gardes de refus joués, `--check --diff` vérifié sans
écriture._
