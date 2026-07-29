# HANDOFF — Session 2026-07-29 : F2 fermé, point Vault levé, licence tranchée

_Dépôt `stoa-labs`, branche `main`, tête `41e3b0f`. Aucun manifeste `stoa`
touché, aucune PR ouverte. Session `/goal F2`, puis deux directives exploitant
(« gère le sujet du vault », « pas de licence, cron 20 min »)._

## En une phrase

Le socle CI a désormais **des sauvegardes qui survivent au nœud** (F2, porte et
contre-épreuve vertes), **un matériel de descellement Vault détenu et prouvé**
(ré-init propre par l'exploitant, re-preuve F1 par le build 11), et **le
préalable licence webMethods est tranché** (pas de licence, redémarrage
contrôlé toutes les 20 min) — **F3 est débloqué**.

## Les trois fils de la session

### 1. F2 — sauvegarde hors-nœud : FERMÉ

Détail complet : `HANDOFF-F2-SAUVEGARDE-HORS-NOEUD.md`. L'essentiel :
archives des 3 PVC `ci` sur **worker-2** (hors cluster), staging local
(fenêtre d'arrêt ~30 s), **Vault jamais redémarré** (garde par empreinte
avant/après), fenêtre de sync Argo, quarantaine `.suspect`, rotation par
claim, porte encodée dans le rôle (cible = nœud porteur ⟹ refus). Deux runs
verts + sabotage D6 + drill de restauration (`ci` retrouvé dans le `gitea.db`
restauré sur worker-2). Preuve :
`docs/superpowers/plans/2026-07-29-f2-sauvegarde-hors-noeud.md`.

### 2. Vault — point « détention des parts » : LEVÉ

L'ancien matériel était indétenable (init lancé hors script le 2026-07-29
matin, fichier root-only absent — re-vérifié en session). Résolution :
**seconde ré-init, propre cette fois** — `vault-bootstrap.sh` déroulé d'une
traite **par l'exploitant** (le classifieur de permissions bloque l'agent sur
ce geste ; motif retenu : l'agent prépare, l'exploitant exécute via `!`,
l'agent vérifie). Résultat mesuré :

- cluster ID `3d3471a0…` (3ᵉ génération), `Sealed=false`, parts **validées
  par le descellement même du script** ;
- `/root/vault-init-ci.txt` présent sur worker-1 (root, 600, 783 octets,
  jamais affiché) ;
- ancien PAT `probe-status` supprimé de Gitea (sa valeur était perdue avec le
  backend précédent), **nouveau PAT re-frappé** et rangé dans Vault ;
- **re-preuve F1 de bout en bout** : push `b5459f58` sur `ci/probe` →
  build 11 déclenché sans action humaine → statut `jenkins/probe: success`
  posé via le nouveau PAT lu par identité de pod.

**Reste à l'exploitant (seul geste ouvert)** : récupérer les parts hors
ligne, puis `sudo shred -u /root/vault-init-ci.txt`. Recommandation tenue :
**garder Vault en garde à chaud** dans `backup_hot_workloads` — tant que le
descellement post-backup n'est pas automatisable, ne pas redémarrer Vault
pendant une sauvegarde reste le meilleur design.

### 3. Licence webMethods — TRANCHÉ (exploitant) : pas de licence

L'auto-redémarrage subi (~30 min, trial expirée) devient un cycle
d'exploitation : **cron root sur worker-3**, `docker restart
wm-dev-apigateway` toutes les 20 min (`ansible/wm-restart-cron.yml`, posé,
relu, et validé par un restart réel). Mesure à connaître : la gateway revient
`healthy` en **~5 min** → **~15 min de service par cycle de 20 min**. Passer à
`*/25` reste possible si l'exploitant veut plus de service (marge plus fine
sous l'expiration). **Conséquence GOAL : F3 débloqué**, avec l'exigence que la
spéc F3 porte le même motif côté cluster (redémarrage périodique **piloté**
du pod, pas subi).

## Ce qui vit où (nouveau ou modifié cette session)

| Objet | Où |
|---|---|
| Rôle backup F2 + drill | `ansible/roles/cluster_backup`, `ansible/backup.yml`, `ansible/backup-restore-drill.yml` |
| Cron webMethods | crontab root worker-3 (`wm-dev-apigateway-restart-trial`) + `ansible/wm-restart-cron.yml` |
| Parts Vault (3ᵉ génération) | `/root/vault-init-ci.txt` sur worker-1 — **à sortir hors ligne + shred** |
| Archives (nouvelles) | worker-2 `/var/lib/k3s-backups/offsite` ; staging worker-5 `/var/lib/k3s-backups/pvc` |
| Spec + plan F2 (avec preuve) | `docs/superpowers/specs/2026-07-29-f2-sauvegarde-hors-noeud-design.md`, `docs/superpowers/plans/2026-07-29-f2-sauvegarde-hors-noeud.md` |
| État des jalons | `GOAL-socle-vers-gateway-2026-07-28.md` : F1 ✔, F2 ✔, F3 débloqué, F4-F5 ouverts |

## Dette restante (consolidée)

| Dette | Porteur |
|---|---|
| Récupération hors ligne des parts + `shred` du fichier | exploitant, quand il veut (fichier en 600 root d'ici là) |
| Chemins quarantaine `.suspect` jamais déclenchés en réel | opportuniste |
| Cron/timer pour `backup.yml` lui-même (aujourd'hui manuel) | après adoption |
| Épinglage par digest des 3 images du socle | F3 (même passe) |
| Mot de passe bootstrap `ci`/`ci-bootstrap` + JCasC + rétention builds | F4 |

## Suite immédiate proposée

**Spécification F3** (webMethods 10.15 dans le cluster) : le préalable licence
est levé, la méthode est rodée (brainstorm → spec → plan → exécution avec
portes de preuve et contre-épreuves). Points durs déjà connus : image via
registre Gitea, anti-affinité worker-3, ES prudent en fsync, dette
ROOT_URL/realm OCI à repenser ici, et le cycle de redémarrage 20 min à porter
avec le pod.

_Socle empirique : preuves F2 (deux runs + sabotage + drill, § « Preuve
d'exécution » du plan), sortie du bootstrap Vault du 2026-07-29 (étapes 1-7
vertes, descellement 2/3), statut du commit `b5459f58` (build 11), crontab
worker-3 relu et restart validé `healthy` en ~300 s._
