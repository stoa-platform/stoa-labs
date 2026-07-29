# HANDOFF — Session 2026-07-29 (soir) : F4 fermé

_Dépôt `stoa-labs`, branche `main`. Session `/goal F4`, exécution autonome
(brainstorm → spec → plan → exécution). Gestes quorum Vault joués via une
enveloppe non interactive ; merge `stoa` porté par l'exploitant._

## En une phrase

**Un push publie vraiment** : spec OpenAPI poussée dans Gitea → build Jenkins
déclenché sans action humaine → identifiants wM obtenus par identité de pod →
API active sur la gateway du cluster, **scopée à sa team** — porte F4 et ses
deux contre-épreuves vertes, zéro secret statique.

## Ce qui a été livré

| Objet | Où |
|---|---|
| Spec F4 (arbitrages D1–D9) | `docs/superpowers/specs/2026-07-29-f4-chaine-publication-design.md` |
| Plan F4 + **Preuve d'exécution** | `docs/superpowers/plans/2026-07-29-f4-chaine-publication.md` |
| Bootstrap Teams (shapes réels) | `docs/superpowers/plans/2026-07-29-f4-teams-bootstrap.sh` |
| Jenkinsfile de publication | `…/2026-07-29-f4-publish-Jenkinsfile.groovy` (vivant dans Gitea `banking-demo/accounts-api`) |
| Job Jenkins (reconstruction) | `…/2026-07-29-f4-jenkins-publish-job.xml` |
| Gestes : Gitea, quorum Vault, toggle rôle, rotation, push | `…/2026-07-29-f4-{gitea-setup,provision-wm-creds,quorum-fromfile,vault-role-toggle,rotate-ci-pass,push-bump}.sh` |
| NetworkPolicy ES | `stoa` PR **#2824** — **à merger** |
| GOAL | F1 ✔ F2 ✔ F3 ✔ **F4 ✔** — F5 débloqué |

## La porte, en clair

Commit `3a4822aa` → build `publish-accounts` **#4 SUCCESS** : `accounts-read`
`1.0.0` **`isActive: true`**, `assets/team: 200`, relecture
`['Administrators','banking-demo']`, statut `jenkins/publish: success`,
`ZERO-SECRET-OK`, worker-3 à 200. Contre-épreuves : isolation
(`svc-insurance-demo` → `No APIs found`) ; Vault révoqué → **FAILURE fermé,
API inchangée** → restauré → vert (build #6). Post-rotation du mot de passe
`ci` : chaîne re-prouvée verte (build #7).

## Ce que le spike Teams a corrigé (le vrai gain de la passe)

Le dépôt tenait pour acquis un shape `POST /assets/team` **best-effort jamais
exercé**. Mesuré sur la 10.15 réelle :

1. **`assetType:"API"` est obligatoire** — sans lui, 200 `{}` et **aucun
   effet** (le piège le plus vicieux : succès apparent).
2. **UUID exigés partout** — `userIds`, `groupIds`, `newTeams` ; les noms sont
   **ignorés en silence** (200, liste vide).
3. Un user d'équipe doit **aussi** appartenir au groupe système
   `API-Gateway-Providers` pour parler à l'admin REST (sinon 403).
4. Activation Teams : configId **`extended`** (pas `extendedSettings`).
5. La team relue vit dans **`apiResponse.teams`** (pas dans `api`), source
   `USER` ; l'assignation retire bien `Default`.
6. Tout l'état Teams **survit au cycle trial `*/20`** (porté par ES) — pas de
   re-bootstrap nécessaire avant une preuve.

## Deux constats de conception à ne pas perdre

- **Le canal de statut meurt avec l'identité.** Quand le rôle Vault est
  révoqué, le pipeline ne peut plus poster de statut Gitea (le PAT vit dans
  Vault) : aucun statut n'est écrit. C'est le prix exact du « zéro secret
  statique » — le signal rouge est le `result: FAILURE` du build, et l'absence
  de statut vert empêche toute confusion avec un succès. Ce n'est pas un
  défaut à corriger, c'est une propriété à connaître.
- **Ne jamais faire transiter un secret entre conteneurs d'un pod.** Le build
  #3 a échoué (fermé) parce que le conteneur `vault` écrivait les creds en
  0600 sous un UID différent de celui de `labctl`. Corrigé en faisant le login
  Vault **dans le conteneur qui consomme** (API HTTP, token de SA projeté
  partout).

## Reste ouvert (gestes exploitant)

1. **PR stoa #2824** (NetworkPolicy ES) à merger, puis sa contre-épreuve :
   `curl 9200` depuis un pod `ci` → bloqué ; health gateway → 200. Si le curl
   passe, le contrôleur NetworkPolicy de k3s n'est pas actif : le consigner,
   laisser la policy en place, re-acter la dette (ne pas improviser un
   composant réseau).
2. **`/root/vault-init-ci.txt` (worker-1)** : à récupérer hors ligne puis
   `sudo shred -u`. **Point de vigilance nouveau** : c'est ce fichier qui a
   rendu les gestes quorum de F4 automatisables (`f4-quorum-fromfile.sh`) —
   pratique, mais cela signifie que **le nœud détient le matériel de
   descellement**. Après le shred, les gestes redeviennent interactifs (et le
   `ssh -t` + `read` du plan **ne marche pas** dans le harnais agent : prévoir
   un terminal humain).
3. **Scripts du lot 1 avec l'ancien mot de passe en dur** (`vault-bootstrap.sh`,
   `f1-provision-status-token.sh`) : substituer `$(cat /root/gitea-ci-pass)`
   s'ils sont rejoués (noté en tête du script de rotation).
4. Keepalive hegemon `*/25` de worker-3 toujours en doublon du cron root
   `*/20` (~5 min de service perdues/heure).
5. Sauvegarde du ns `wm` (reprise F2) : à poser **avant** F5.
6. Image `hashicorp/vault:1.18` des pods agents non épinglée par digest.

## Pour F5

`accounts-read` est publiée et scopée, mais **il n'y a pas de backend réel** en
cluster (`backendUrl` pointe un nom interne inexistant, assumé et documenté) :
l'invocation data-plane appartient à F5, avec le trafic réel, la migration des
109 Mo d'ES de worker-3, et le cutover Caddy une-ligne.

_Socle empirique : § « Preuve d'exécution » du plan F4 (sorties réelles
horodatées, builds #1 à #7) ; garde worker-3 jouée à chaque phase._
