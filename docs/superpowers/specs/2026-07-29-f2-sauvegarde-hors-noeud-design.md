# F2 — Sauvegarde réellement hors-nœud : spécification

_2026-07-29. Jalon F2 du GOAL lot 2 (`GOAL-socle-vers-gateway-2026-07-28.md`).
Session autonome (`/goal F2`) : les arbitrages réservés à l'humain dans le GOAL
sont pris ici sur la base du cadre écrit et des mesures du jour, et chaque
déviation est signalée. L'utilisateur relira ce document a posteriori._

## Problème

Les trois PVC du socle CI (gitea 478 Mo, jenkins 295 Mo, vault 312 Ko — mesurés
ce jour) vivent tous sur **worker-5**, et le répertoire offsite du rôle
`cluster_backup` (`backup_offsite_host: worker-5`) vit… sur worker-5 aussi. Une
panne disque y perd données **et** copies. De plus, l'offsite actuel ne contient
qu'**une seule** archive PVC (gitea, 2026-07-28) : vault et jenkins n'ont
jamais été archivés, et cette archive gitea est antérieure à la
ré-initialisation Vault du 2026-07-29.

**Porte F2 (GOAL) :** archives des trois PVC lisibles sur un hôte **distinct du
nœud porteur des données**. **Contre-épreuve :** restauration exercée depuis cet
hôte (l'utilisateur `ci` retrouvé dans le `gitea.db` restauré).

## Mesures du 2026-07-29 (état vivant, pas relu)

| Fait | Mesure |
|---|---|
| worker-2 joignable du poste de contrôle | `ssh -o BatchMode=yes worker-2` OK, sudo OK |
| worker-2 espace disque | 361 Go libres sur `/` |
| worker-2 outillage | tar, gzip, sha256sum, sqlite3, python3+sqlite3 |
| PVC ci (3) | tous `local-path` sur worker-5 |
| Applications Argo `ci-*` | `automated {prune, selfHeal}`, projet `stoa`, **pas** gérées par une app-of-apps (patch live stable) |
| Vault | `Sealed=false`, cluster ID `c51f3c8b…` (init en service) |
| `/root/vault-init-ci.txt` (worker-1) | **absent** — détention des parts toujours improuvée |

## Décisions

### D1 — Cible : worker-2

Le candidat du GOAL, confirmé par les mesures. Hors cluster (isolation L2
w1↔w2), donc il survit à la perte de n'importe quel nœud du cluster. Le
transfert garde le motif du lot 1 — **relais par le poste de contrôle**
(`ssh nœud 'tar' | ssh cible 'tee'`) : les workers continuent de ne pas se
faire confiance en SSH entre eux. `backup_offsite_host` passe à `worker-2`
pour **tout** le rôle : les archives du plan de contrôle (worker-1) y gagnent
aussi une copie hors-cluster, sans changement de mécanique.

### D2 — Staging local avant transfert : la fenêtre d'indisponibilité ne dépend plus du WAN

Aujourd'hui le `tar` des PVC est streamé pendant la quiescence : la fenêtre
d'arrêt dure autant que le transfert (le relais passe par la liaison montante
du poste de contrôle — ~775 Mo à travers une connexion résidentielle, minutes
à dizaines de minutes). Nouveau séquencement :

1. quiescer → archiver **localement sur worker-5** (`/var/lib/k3s-backups/pvc/`,
   disque local, secondes) → redémarrer ;
2. transférer ensuite les archives stagées vers worker-2, **hors fenêtre**, sans
   pression de temps ;
3. read-back des deux côtés, rotation des deux côtés (symétrie avec les
   archives k3s : copie locale + copie offsite).

### D3 — Vault n'est PAS quiescé (déviation assumée, réversible)

Le rôle actuel met tout le namespace à zéro réplique ; or Vault **redémarre
scellé**, et le point ouvert du handoff F1 tient toujours (mesuré ce jour : le
fichier d'init est absent, la détention des parts de descellement est
improuvée). Un run autonome qui redémarre Vault laisserait le socle **hors
service sans recours agent** — exactement la « panne définitive » contre
laquelle le handoff met en garde, en priorité sur F2.

Choix : une variable `backup_hot_workloads` (défaut : `statefulset/vault`)
exclut Vault de la quiescence. Son PVC (312 Ko, backend fichier) est archivé
**à chaud**, sous garde de cohérence honnête :

- **hash avant** : `tar cf - <pvc> | sha256sum` (flux non compressé — gzip
  horodate ses en-têtes, comparer le compressé mentirait) ;
- archive ;
- **hash après** : si les deux empreintes diffèrent, quelque chose a écrit
  pendant la fenêtre → l'archive est renommée `.suspect` et le play **échoue**.
  Empreintes identiques ⇒ le contenu archivé est le contenu au repos.

Pendant la fenêtre, Jenkins est quiescé donc aucun login k8s→Vault n'écrit de
lease : la fenêtre est calme par construction. Réversibilité : quand
l'exploitant aura prouvé la détention des parts (procédure non destructive du
handoff F1), vider `backup_hot_workloads` restitue la quiescence pleine.
Garde-fou supplémentaire : le rôle **échoue d'entrée** si Vault est scellé au
départ, et vérifie qu'il est toujours descellé à la fin — la sauvegarde ne doit
jamais dégrader le socle qu'elle protège.

### D4 — Fenêtre de synchronisation Argo (la vraie réponse à la course selfHeal)

Avant la quiescence : capturer `spec.syncPolicy.automated` des Applications
`ci-*`, puis le **retirer** (patch live ; stable car pas d'app-of-apps). Dans le
`always` : restaurer les répliques **puis** la politique capturée. La garde
post-archive du lot 1 (aucun pod réapparu) est conservée en défense en
profondeur — elle doit désormais passer à tous les coups. Limite héritée et
documentée : si l'hôte de contrôle devient injoignable en plein bloc, `always`
ne s'exécute pas ; le remède manuel (scale + re-patch) est documenté dans le
rôle.

### D5 — Quarantaine et rotation

- **Quarantaine** : toute archive produite dans un run dont une garde a rougi
  (pods réapparus, hash Vault divergent) est renommée `*.tar.gz.suspect` avant
  l'échec du play — une archive suspecte qui ressemble à une saine « rassure à
  tort » (doctrine du rôle).
- **Rotation** : les `pvc-*.tar.gz` tournent enfin, **par claim** (garder
  `backup_keep` versions de chaque), des deux côtés. Les `.suspect` ne sont
  pas comptés ni supprimés par la rotation : ils attendent une décision
  humaine.

### D6 — La porte F2 encodée dans le rôle

Assert par PVC : `backup_offsite_host != nœud porteur du PV`. Si un PVC migre
un jour sur worker-2, la sauvegarde échoue **fermée** au lieu de redevenir
silencieusement co-localisée.

### D7 — Contre-épreuve : exercice de restauration sur worker-2

Playbook dédié `ansible/backup-restore-drill.yml` (motif `*-verify` du dépôt) :
sur worker-2, extraire la **dernière** archive gitea dans un répertoire de
travail root-only, localiser `gitea.db`, vérifier via sqlite3 que l'utilisateur
`ci` existe, puis nettoyer. Rien de sensible n'est affiché (le nom `ci` n'est
pas un secret ; la base reste sur le nœud). L'exercice échoue fermé si
l'archive, la base ou l'utilisateur manquent.

## Hors périmètre (YAGNI, acté)

- Automatisation du descellement Vault et preuve de détention des parts —
  action humaine, procédure au handoff F1, préalable levé indépendamment.
- Chiffrement supplémentaire des archives (elles restent en 0600 root sur des
  nœuds de la flotte, comme au lot 1).
- Cron/timer : à brancher une fois le premier run vérifié (note existante du
  playbook conservée).
- Sauvegarde des PVC `observability` : autre périmètre.

## Critères d'acceptation

1. `ansible-playbook -i inventory.contabo.ini backup.yml` passe de bout en
   bout sans action humaine.
2. **Porte F2** : trois archives `pvc-ci-*` du run présentes et lisibles
   (read-back + comptage d'entrées) sur worker-2, et l'assert D6 prouve
   worker-2 ≠ worker-5.
3. **Contre-épreuve** : `backup-restore-drill.yml` retrouve l'utilisateur `ci`
   dans le `gitea.db` restauré sur worker-2.
4. Vault est `Sealed=false` avant **et après** le run ; Gitea et Jenkins sont
   revenus (répliques restaurées) ; les politiques `automated` des trois
   Applications sont restaurées à l'identique.
5. Rotation : au plus `backup_keep` archives par claim et par côté ; aucun
   `.suspect` produit sur un run sain.
