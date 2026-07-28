Exécute le plan `docs/superpowers/plans/2026-07-28-socle-ci-cluster.md` (dépôt
`stoa-labs`, branche `docs/spec-socle-ci`) en pilotage par sous-agents : utilise
la compétence `superpowers:subagent-driven-development`, un sous-agent neuf par
tâche, relecture entre chaque.

La spécification qui justifie chaque choix est dans
`docs/superpowers/specs/2026-07-28-socle-ci-cluster-design.md`. Lis-la avant de
commencer : elle explique *pourquoi*, le plan dit *comment*.

But : déployer Gitea, Vault et Jenkins sur le cluster k3s labs, de sorte qu'un
pipeline obtienne ses identifiants par l'identité de son pod, sans aucun secret
statique.

## Environnement — ce qu'une session neuve ne peut pas deviner

Cluster k3s v1.34.5 à 4 nœuds, joignables par alias SSH (`ssh worker-1`, etc.),
utilisateur `hegemon`, `sudo` sans mot de passe. `kubectl` s'invoque
`sudo k3s kubectl` sur les nœuds ; il n'y a pas de kubeconfig sur le poste.

- **worker-1** — plan de contrôle, datastore kine/SQLite (pas d'etcd)
- **worker-3** — agent, **et hors cluster : Caddy qui sert TOUT le trafic public
  + webMethods 10.15 et Elasticsearch en Docker**
- **worker-4**, **worker-5** — agents
- **worker-2 est EXCLU du cluster.** Contabo isole les VPS d'un même segment L2 :
  worker-1 et worker-2 ne peuvent pas communiquer, sur aucun port. Ne l'ajoute
  pas, ne cherche pas à « réparer » ça.

Argo CD v3.4.5 réconcilie déjà 5 applications, toutes `Synced/Healthy`. Il lit
les manifestes depuis **GitHub** (`stoa-platform/stoa`, public).

## Règles de sûreté — non négociables

1. **Ne perturbe rien sur worker-3.** Caddy y sert le trafic public de la flotte
   et webMethods y tourne en Docker. Toute action sur ce nœud doit être suivie
   d'une vérification que Caddy répond toujours et que les deux conteneurs
   `wm-dev-apigateway` / `wm-dev-elasticsearch` sont debout.
2. **Aucune exposition publique.** Ni Gitea, ni Vault, ni Jenkins ne reçoivent
   d'Ingress. Accès par `kubectl port-forward` uniquement. C'est une décision
   d'architecture, pas un oubli.
3. **Les clés de descellement de Vault ne vont dans AUCUN dépôt, AUCUN fichier
   du projet.** Affiche-les et demande à l'humain de les conserver hors ligne.
   Elles sont le nouveau « secret zéro ».
4. **Aucune IP en Git.** Les hôtes se désignent par leurs alias `~/.ssh/config`.
   L'inventaire Ansible le rappelle en tête.
5. **Jamais de tag `:latest`.** Toutes les images épinglées.

## Où va quoi, et pourquoi

- **Manifestes Kubernetes → dépôt `stoa` (PUBLIC).** Argo CD y lit sans
  credential ; les mettre dans `stoa-labs` (privé) exigerait une deploy-key,
  donc un « secret zéro » que la doctrine interdit. Les manifestes ne
  contiennent aucun secret.
- **Ansible → dépôt `stoa-labs` (privé).**

**Le checkout local de `stoa` est chroniquement en retard sur `origin/main`
(plusieurs centaines de commits) et se trouve sur une branche de travail.** Ne
t'y fie pas et n'y fais pas de `pull`. Pour toute lecture, interroge la branche
(`git show origin/main:<chemin>`, `git ls-tree origin/main`,
`git grep <motif> origin/main`). Pour toute écriture, crée un worktree :
`git worktree add <tmp> -b <branche> origin/main`, et retire-le après.

## Workflow Git imposé par le dépôt

Commits **conventionnels** (`feat`/`fix`/`docs`/`chore`) et **signés DCO**
(`git commit -s`) — une vérification CI les impose. Fusion en **squash
uniquement**. Sur `stoa`, 4 vérifications sont obligatoires : `License
Compliance`, `SBOM Generation`, `Verify Signed Commits`, `Regression Test
Guard`. La protection de branche est `strict` : rafraîchis la branche sur `main`
avant de fusionner (`gh pr update-branch`).

Une PR par composant. N'en fusionne aucune dont une vérification échoue sans
avoir d'abord établi que l'échec préexiste sur `main`.

## La règle qui compte plus que les autres

Chaque tâche a une **porte de preuve** et une **contre-épreuve de sabotage**.
Les deux doivent passer avant de déclarer la tâche terminée :

- la porte de preuve établit que ça marche ;
- la contre-épreuve casse volontairement la chose et vérifie que la porte
  **rougit**. Une porte qui ne rougit jamais ne prouve rien.

En particulier, tâche 3 : un pod portant un ServiceAccount **autre** que
`jenkins-agent` doit être **refusé** par Vault. Sans cette assertion, on a
prouvé que Vault répond, pas qu'il distingue les identités — et le jalon reste
ouvert.

Ne déclare jamais une tâche terminée sur la foi d'un code de retour. Relis
l'état (`read-back-assert`) : demande au plan de contrôle ce qu'il voit, pas à
l'installeur ce qu'il croit avoir fait.

## Si tu es bloqué

Arrête-toi et rends compte. Ne contourne pas une garde, ne force pas une
fusion, n'invente pas un secret manquant. Les trois questions déjà connues
comme ouvertes — rétention des builds Jenkins, espace hors-nœud pour les
archives PVC, automatisation de la sauvegarde — ne bloquent aucune tâche : si
elles se présentent, signale-les et continue.
