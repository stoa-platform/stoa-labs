# HANDOFF — F2 : sauvegarde réellement hors-nœud (lot 2)

_Session 2026-07-29 (autonome, `/goal F2`). Dépôt `stoa-labs`, branche `main`.
Aucun manifeste `stoa` touché, aucune PR ouverte._

## En une phrase

**F2 est fermé** : les trois PVC du socle CI (gitea, jenkins, vault) sont
archivés sur **worker-2** — hôte hors cluster, distinct du nœud porteur
worker-5 — avec empreintes vérifiées, rotation, quarantaine, fenêtre de sync
Argo, et l'exercice de restauration a été joué **depuis worker-2** (utilisateur
`ci` retrouvé dans le `gitea.db` restauré).

## À lire en premier si tu reprends

1. **Le point Vault du handoff F1 reste ouvert** (détention des parts de
   descellement improuvée ; fichier `/root/vault-init-ci.txt` re-vérifié absent
   ce jour). F2 a été **conçu pour ne pas en dépendre** : Vault n'est jamais
   redémarré par la sauvegarde. Mais le point reste à lever (procédure non
   destructive au handoff F1) — et une fois levé, vider `backup_hot_workloads`
   dans `ansible/roles/cluster_backup/defaults/main.yml` restitue la
   quiescence pleine de Vault.
2. Spécification : `docs/superpowers/specs/2026-07-29-f2-sauvegarde-hors-noeud-design.md`.
   Preuve : `docs/superpowers/plans/2026-07-29-f2-sauvegarde-hors-noeud.md`,
   § « Preuve d'exécution ».
3. Le GOAL lot 2 porte l'état à jour : F1 et F2 fermés, F3 bloqué licence
   webMethods (décision humaine), F4-F5 ouverts.

## Le flux livré

```
backup.yml (poste de contrôle)
   │
   ├─ plan de contrôle k3s (worker-1) ── inchangé ── offsite → worker-2
   │
   └─ PVC ci (worker-5) :
        porte F2 : cible ≠ nœud porteur, sinon échec fermé
        Vault descellé ? (sinon refus de partir)
        capture syncPolicy des Applications ci-* ── patch : automated retiré
        quiescence gitea + jenkins (vault RESTE up)
        empreinte vault (tar non compressé | sha256) ── avant
        tar czf LOCAL sur worker-5 (fenêtre courte : pas de WAN)
        empreinte vault ── après ── ≠ ⟹ .suspect + échec
        pods réapparus ? ⟹ .suspect + échec
        always : répliques restaurées, automated restauré à l'identique
        read-back local → transfert streamé via poste de contrôle → worker-2
        read-back hors-nœud (entrées + sha256 = staging)
        rotation par claim, deux côtés (backup_keep=7, .suspect épargnés)
        Vault toujours descellé ? (assert final)
```

Contre-épreuve : `ansible-playbook -i inventory.contabo.ini backup-restore-drill.yml`
— restaure la dernière archive gitea sur worker-2, y retrouve l'utilisateur
`ci`, détruit son répertoire de travail root-only.

## Preuves (2026-07-29, re-mesurées contre le cluster vivant)

| Épreuve | Résultat |
|---|---|
| Sabotage D6 (`-e backup_offsite_host=worker-5`) | échec fermé « sauvegarde REFUSÉE (porte F2) », avant toute quiescence, pods intacts |
| Run n°1 (`20260729T121715`) | `failed=0` ; 3 archives sur worker-2 (496 Mo / 273 Mo / 19 Ko), empreintes = staging |
| Run n°2 (`20260729T122215`) | `failed=0` ; récurrence + rotation saine (2 horodatages par claim, ≤ 7) |
| Drill de restauration | utilisateur `ci` présent dans le `gitea.db` restauré **sur worker-2** |
| Socle après coup | gitea/jenkins Running, `vault-0` jamais redémarré (96 min), `Sealed=false`, `automated {prune, selfHeal}` restaurés |

## Ce qui vit où

| Objet | Où |
|---|---|
| Archives PVC + k3s (offsite) | worker-2 `/var/lib/k3s-backups/offsite` (0600 root) |
| Staging PVC | worker-5 `/var/lib/k3s-backups/pvc` (0600 root, tourne aussi) |
| Anciennes archives (avant F2) | worker-5 `/var/lib/k3s-backups/offsite` — historique, plus alimenté |
| Rôle et playbooks | `ansible/roles/cluster_backup`, `ansible/backup.yml`, `ansible/backup-restore-drill.yml` |

## Dette F2 restante

| Dette | Jalon porteur |
|---|---|
| Lever le point parts Vault, puis vider `backup_hot_workloads` (quiescence pleine) | humain, avant F3 |
| Chemins `.suspect` jamais déclenchés en réel (couverts par relecture seulement) | opportuniste |
| Cron/timer du backup (note d'en-tête du playbook) | après adoption |
| Rotation observée en suppression réelle (il faudrait 8 runs) | s'éteint tout seul à l'usage |

## Leçon retenue

La contrainte « ne jamais redémarrer Vault sans parts prouvées » a produit un
meilleur design que la quiescence uniforme : la garde par empreinte
avant/après donne une preuve de cohérence **mesurée** (rien n'a écrit pendant
la fenêtre) là où la quiescence ne donnait qu'une garantie **par
construction** — et le rôle vérifie désormais en sortie qu'il n'a pas dégradé
le socle qu'il protège. À réutiliser pour ES en F3 (autre composant qui
souffre au redémarrage).
