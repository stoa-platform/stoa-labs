# HANDOFF — F1 : déclenchement par push + statut de commit (lot 2)

_Session 2026-07-28/29. Dépôt `stoa-labs`, branche `main`, tête `8fb9135`. Aucun manifeste `stoa` touché, aucune PR ouverte._

## En une phrase

**F1 est fermé** : un `git push` sur `ci/probe` déclenche le build Jenkins sans
action humaine, et le commit porte son statut dans Gitea — **vert** quand le
pipeline passe, **rouge** quand il casse. Le socle CI du lot 1 a désormais son
premier client réel.

## À lire en premier si tu reprends

1. **Un risque ouvert prime sur toute nouvelle tâche** : la détention des parts
   de descellement Vault courantes n'est pas prouvée (§ « Le point à lever »).
   Un socle dont personne ne détient les parts retombe en panne définitive au
   premier `backup.yml`. À trancher avant F2/F3.
2. Preuve détaillée : `docs/superpowers/plans/2026-07-28-f1-webhook-statut.md`,
   § « Preuve d'exécution ». Spécification :
   `docs/superpowers/specs/2026-07-28-f1-webhook-statut-design.md`.
3. Le GOAL lot 2 (`GOAL-socle-vers-gateway-2026-07-28.md`) porte l'état à jour
   des cinq jalons : F1 fermé, F2-F5 ouverts.

## Le flux câblé

```
push sur ci/probe [main]  (API Gitea ou git)
   │
   ▼
Gitea ── webhook push (ALLOWED_HOST_LIST ✓) ──▶ Jenkins
         POST /generic-webhook-trigger/invoke?token=…   (GWT 2.4.2)
   │                                    filtre ^refs/heads/main$
   │                                           │
   │                               build du job `probe`
   │                               pod agent éphémère (SA jenkins-agent)
   │                                           │
   │           ┌── login k8s → Vault ── lit secret/ci/probe        (G-c, lot 1)
   │           │                     └─ lit secret/ci/probe-status (PAT Gitea)
   │           ▼
   └◀── POST /repos/ci/probe/statuses/{sha}   pending → success | failure
```

Le PAT qui poste le statut est **lu dans Vault à chaque build par l'identité du
pod** : aucun credential statique dans Jenkins (`credentials.xml` toujours
absent). C'est la mécanique G-c du lot 1 dans son premier usage réel — celle que
F4 généralisera aux identifiants webMethods.

## Preuves (toutes re-mesurées contre le cluster vivant, pas relues)

| Build | Commit `ci/probe` | Cause | Résultat | Statut Gitea |
|---|---|---|---|---|
| 7 | `fc8c4a9b` (Jenkinsfile F1) | `Generic Cause` | SUCCESS | `success` |
| 8 | `e4a15058` (sabotage `exit 1`) | `Generic Cause` | FAILURE | **`failure`** |
| 9 | `c34f90d6` (restauration) | `Generic Cause` | SUCCESS | `success` |
| 10 | `f1e0f571` (push indépendant, contre-vérification) | `Generic Cause` | SUCCESS | `success` |

Contexte du statut : `jenkins/probe`, `target_url` vers le build, description
`probe <state>`. Quatre déclenchements automatiques consécutifs : la récurrence
est acquise en plus de la porte.

**Contre-épreuves de l'endpoint** (T2) : mauvais jeton → « Did not find any jobs
with GenericTrigger configured » ; branche autre que `main` → `triggered: false`
avec le filtre affiché ; `main` → build. **Contre-épreuve de la porte** (T6) :
Jenkinsfile cassé → build 8 rouge **et** statut rouge, puis retour au vert au
commit suivant. Un statut qui ne rougit jamais ne prouverait rien.

**Limite connue, assumée :** un Jenkinsfile *syntaxiquement invalide* échoue
avant qu'aucun pod agent n'existe — personne ne peut alors poster de statut, et
le commit reste **sans statut** (ni vert ni rouge). Le durcissement (JCasC + job
wrapper posant `pending`/`failure` depuis le contrôleur) appartient à F4, qui
apporte JCasC de toute façon.

## Ce qui vit où (état non versionné)

| Objet | Où | Sauvegardé ? |
|---|---|---|
| Config du job `probe` (avec le trigger et son jeton) | `jenkins-home` (PVC) | oui, sauvegarde PVC lot 1 |
| Webhook push `ci/probe` (id 1) | base Gitea | oui, idem |
| `secret/ci/probe-status` (PAT Gitea `probe-status`, scope `write:repository`) | Vault | oui, idem |
| Jeton d'invocation GWT | **nulle part en Git** — placeholder `__WEBHOOK_TOKEN__` | régénérable |

**Reconstruction :** le XML du job
(`docs/superpowers/plans/2026-07-28-jenkins-probe-job.xml`) et le Jenkinsfile
(`docs/superpowers/plans/2026-07-28-probe-Jenkinsfile.groovy`) sont versionnés.
Le jeton d'invocation ne l'est pas : à la reconstruction, frapper un jeton neuf
(`openssl rand -hex 24`) et le poser **des deux côtés** — dans le XML du job et
dans l'URL du webhook Gitea. Un secret régénérable n'a pas besoin d'être
conservé.

## Le point à lever — Vault, avant toute autre tâche

**Ce qui s'est passé.** Le jeton racine et les 3 parts de descellement du lot 1
avaient été **perdus** par l'exploitant : Vault n'était plus administrable et
devenait irrécupérable au premier redémarrage. Décision prise : ré-initialiser
(périmètre labo, seule la fixture `secret/ci/probe` y vivait). La sortie du
premier `init` a alors été **affichée en clair dans une session agent** — matériel
brûlé. Une seconde passe a été outillée pour que les secrets ne quittent jamais
le nœud (`docs/superpowers/plans/2026-07-28-vault-bootstrap.sh`).

**Ce qui est tranché (mesuré le 2026-07-29).** Le backend du premier `init` a été
effacé **avant** l'`init` en service : cluster ID distinct de celui du lot 1
(`c51f3c8b…` vs `5c0fecc0…`), `/vault/data/core/_master` écrit après le
redémarrage du pod. **Les valeurs exposées n'ouvrent plus rien — aucun `rekey`
n'est requis.**

**Ce qui reste ouvert.** Trente minutes séparent le redémarrage du pod
(08:51 UTC) de l'`init` en service (09:21 UTC), alors que `vault-bootstrap.sh`
enchaîne ces étapes en moins de cinq (attentes bornées à 180 s + 120 s).
L'`init` a donc été lancé **hors du script**, et rien ne prouve que sa sortie
soit passée par le fichier root-only prévu — absent à la vérification.
**Si personne ne détient les parts courantes, le socle est à un `backup.yml`
(qui quiesce les pods) ou à un reschedule de la panne définitive.**

Vérification non destructive — prouve la détention d'une part valide sans rien
modifier :

```bash
ssh -t worker-1 'sudo k3s kubectl -n ci exec vault-0 -- vault operator generate-root -init | grep -i nonce'
ssh -t worker-1 'read -r -s -p "Une part de descellement : " K; echo; \
  sudo k3s kubectl -n ci exec vault-0 -- vault operator generate-root -nonce=<NONCE> "$K" | grep -i progress; \
  unset K; sudo k3s kubectl -n ci exec vault-0 -- vault operator generate-root -cancel'
```

Attendu : `Progress 1/2`, puis l'annulation remet l'essai à zéro — aucun jeton
racine n'est produit. Si la part est refusée, relancer `vault-bootstrap.sh` en le
laissant **dérouler d'une traite**, et mettre les parts à l'abri hors ligne avant
toute autre opération.

## Leçon retenue, applicable au lot 2

**Une commande qui *affiche* un secret est un piège, même accompagnée de la
consigne « lance-la ailleurs ».** Les procédures doivent rediriger la sortie
sensible vers un fichier à droits restreints sur le nœud et ne laisser passer que
des messages de progression. C'est la forme retenue pour `vault-bootstrap.sh`, et
celle à reprendre pour tout provisioning du lot 2.

Corollaire de séquencement, appris à la dure ici : ne jamais effacer un script
stagé **dans le même appel** que sa vérification — si l'humain n'a pas encore
exécuté, le fichier manque au moment où il en a besoin.

## Dette F1 restante

| Dette | Jalon porteur |
|---|---|
| Jenkinsfile non-compilable → commit sans statut (durcissement wrapper) | F4 (avec JCasC) |
| Job `probe` créé/configuré par REST, pas par JCasC | F4 (dès le 2ᵉ job) |
| Mot de passe bootstrap `ci`/`ci-bootstrap` en clair dans les docs | F4 (les identités réelles arrivent) |

## Suite immédiate proposée

1. **Lever le point Vault** ci-dessus (10 min, non destructif).
2. **F2 — sauvegarde hors-nœud** : décision humaine sur la cible (candidat
   worker-2), vérification préalable de la joignabilité SSH w5→w2 et de l'espace
   disque. C'est le chemin critique du GOAL : « une sauvegarde qui ne survit pas
   au nœud ne protège rien ».
3. **F3** reste bloqué par la **licence webMethods** (décision humaine, hors
   portée d'un agent).

_Socle empirique : exécution F1 des 2026-07-28/29 (portes et contre-épreuves
ci-dessus), plan du lot 1 (`docs/superpowers/plans/2026-07-28-socle-ci-cluster.md`,
portes G-a/G-b/G-c), GOAL lot 2 (`GOAL-socle-vers-gateway-2026-07-28.md`)._
