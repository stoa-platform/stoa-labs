# HANDOFF — 2026-08-05 : palier 2, les formulaires — et ce que le vrai runtime a révélé

_Branche `feat/onboarding-equipe-palier-1`, palier 2 = 24 commits (`f52f0cc..38d681b`). Non fusionnée._

## En une phrase

L'onboarding d'équipe et la création d'application ont désormais leurs portes
humaines — deux formulaires Jenkins et un job post-merge, la décision restant le
merge (ADR-081) — et le chemin complet a été prouvé de bout en bout DANS le vrai
runtime : trois builds SUCCESS (#12/#13/#14), du webhook Gitea au ✅ sur la PR,
en passant par la pause nominative, la garde d'identité et le login Vault
d'oscar.

---

## 1. Ce qui est livré

| Brique | Où |
|---|---|
| Formulaire « onboarder une équipe » | `ci/jenkins/team-request.job.xml` + `scripts/team-request.sh` + `ansible/team-plan.yml` |
| Formulaire « créer une application » | `ci/jenkins/app-request.job.xml` (converge vers `provision-request.sh` existant) |
| Job post-merge | `ci/jenkins/team-apply.job.xml` + `scripts/team-apply.sh` |
| Prérequis Vault/Gitea | `scripts/setup-team-onboard-prereqs.sh` (policy `team-onboarder`, token org-admin dans Vault) |
| Pose des jobs | `scripts/setup-team-onboard-jobs.sh` (les 3 jobs) |
| Preuves | `scripts/test-team-apply-wiring.sh` (30/30 statique) + `scripts/test-team-onboarding-chain.sh` (10 preuves, verdict `fort`) |

Le flux : formulaire → PR `onboard/<team>-<env>` sur le dépôt plateforme, avec le
**plan commenté** — qui EST `resolve.yml` du rôle, donc les gardes mêmes de
l'apply, montrées au valideur avant le merge. Au merge : webhook → pause
nominative → garde d'identité du valideur (`assert-merge-identity.sh`) → login
Vault de l'opérateur (policy `team-onboarder`, token qui meurt avec le build) →
création du dépôt d'équipe depuis le squelette ADR-076 (idempotent, répare un
dépôt vide) → rôle d'onboarding du palier 1 → statut réel sur la PR, succès
comme échec. Les deux portes (formulaire et OIG/CLI2) convergent sur le même
aval — constaté en réel : `provision-plan` a commenté de lui-même une PR ouverte
par le formulaire.

Espace de noms `onboard/*` parallèle à `provision/*` : les chaînes s'ignorent
par construction. La chaîne machine existante n'a reçu qu'une modification,
additive (refus des `REQ_MODE` invalides — `REQ_MODE` lui-même préexistait).

## 2. Les QUATRE écarts d'environnement — la vraie moisson du palier

Aucun n'était connu avant qu'un job réel n'exécute la chaîne. C'est l'argument
définitif pour les preuves en conditions réelles.

1. **Le conteneur Jenkins tourne ansible-core 2.19.4 ; tous les postes (et
   toutes les preuves des paliers 1 et 2) tournaient en 2.18.2.** Sous 2.19, le
   `name:` d'un bloc référençant un fact runtime est templé AVANT l'exécution →
   `'onb' is undefined`, l'onboarding entier échouait. Corrigé dans le rôle
   (noms sur `apim_onb_team`, dispo au parse — jamais la logique), classe
   balayée et fermée sur tout le chemin E2E. **Décision : corriger le rôle, pas
   épingler 2.18** — épingler aurait caché la classe jusqu'à la prochaine
   montée, probablement chez le client.
2. **La voie A (identité nominative) n'avait JAMAIS été exercée contre
   `userpass` par un job** — la lib `vault-login.sh` retombe sur son défaut
   `ldap` (convention client), et aucun job ne posait `VAULT_USER_AUTH_MOUNT`.
   Corrigé dans `team-apply.job.xml` (défaut `userpass` calibré lab, surcharge
   client) — voir « ce qui te revient » : c'est un point de configuration
   client explicite.
3. **Le mock `poc-webmethods` du réseau compose était PÉRIMÉ** (image du
   2026-06-08, antérieure aux surfaces Teams) — reconstruit depuis le worktree,
   alias réseau `webmethods-mock` ajouté. Réparé pour tout le monde.
4. **`docker exec` est la SEULE voie pour minter le token org-admin Gitea**
   (`setup-team-onboard-prereqs.sh`) — or c'est l'artefact le plus destiné à
   être rejoué chez un client, où la forge n'est pas un conteneur local. Aucun
   chemin « je fournis un token déjà minté ». **Dette ouverte.**

## 3. Les défauts que les revues ont tués — un motif en trois familles

**Le secret en argv, corrigé QUATRE fois** : URL de push porteuse du token
(`team-apply`, puis `team-request` en fix transverse), mot de passe éphémère
dans `python3 -c`/`docker exec --password`/`grep -F` (le harnais lui-même), et
en toute fin un `grep -v "$TOKEN"` de chemin d'erreur — dont le commentaire
disait « détail masqué » et qui ne filtrait plus rien depuis que l'URL était
nue. `set +x` protège les logs ; RIEN ne protège la table des processus sauf de
ne jamais y mettre le secret. Motifs sains : header-file (`vhdr`),
`GIT_CONFIG_COUNT/KEY/VALUE`, heredoc+env, `grep -Ff fichier`,
`--random-password` (ne pas connaître un secret est la meilleure façon de ne
pas le fuiter). **`provision-request.sh` (chaîne préexistante) porte ENCORE le
motif URL-token — dette consignée, hors périmètre additif du palier.**

**L'extraction non gardée entre deux appels gardés** : la fusion de policies
dont le parse silencieusement vide aurait REMPLACÉ les droits de l'opérateur au
lieu d'y ajouter (prouvé en rouge réel : `operator-deploy` effacé, restauré) ;
le `REPO_FULL` dont l'échec de parse prenait le chemin « repo vide légitime ».
Sur cette base de code, le point aveugle n'est jamais l'appel HTTP — toujours
la transformation entre deux appels vérifiés.

**Le vert vacant** : la preuve `ps` qui n'établissait pas avoir VU du trafic ;
les verdicts de repli (`fort_partiel`) câblés sur PASS — un détecteur de
régression qui compte comme succès ; l'idempotence `changed=0` vraie par
construction du module. Un harnais doit prouver qu'il a regardé, et savoir
rougir — la matrice casse une garde exprès et vérifie son propre FAIL.

## 4. Ce qui te revient (gestes exploitant)

**1. Fusionner la branche** — verdict de la revue finale : fusionnable, le
Critical est corrigé (`38d681b`). Puis re-pousser `gitea main` une dernière
fois pour aligner le lab sur l'état final (le handoff compris).

**2. Enregistrer le webhook Gitea de `team-apply` côté serveur** (token
`stoa-team-apply`, événement pull_request, même forme que ceux des jobs
provision). La preuve 10 POSTe le payload directement sur l'endpoint GWT ; le
webhook serveur n'a jamais été enregistré — c'est le dernier maillon de la
pose réelle.

**3. Trancher le point de configuration client `VAULT_USER_AUTH_MOUNT`** : le
job `team-apply` porte un défaut `userpass` (lab), TOUT le reste du dépôt
(`Jenkinsfile.selfservice/.publish-api/.prod/.rollback`, la lib, ADR-078)
documente `ldap` comme convention client avec surcharge lab. Deux jobs du même
Jenkins ont des défauts opposés. Chez le client : surcharger `team-apply`
spécifiquement, ou aligner son défaut sur `ldap` et poser la surcharge lab en
variable d'env globale Jenkins.

**4. Trois dettes de robustesse, petites mais réelles** (constats I2/I3/I5 de
la revue finale, conservés hors vague pour ne pas précipiter du code de job) :
- les POST de commentaire PR ne sont pas vérifiés (`team-request.sh:185`,
  `team-apply.sh:192`) — un build vert peut laisser une PR muette, ce
  qu'ADR-081 corollaire 1 interdit ;
- un refus de la garde d'identité ne commente PAS la PR (`team-apply.job.xml` —
  `provision-apply` a un `finally` pour ça, le miroir a manqué ce seul point) ;
- le chemin « token org-admin déjà minté » manque au script de prérequis (écart
  d'environnement n°4).

**5. Le compte Gitea `oscar` existe désormais** (créé pour prouver la garde
d'identité avec un VRAI second compte — forger le payload aurait été un
mensonge). L'identité nominative de lab est complète : Vault (userpass) ET
Gitea. Conservé délibérément.

**6. Une pause jamais répondue bloque les onboardings suivants** : l'input de
`team-apply` n'a ni timeout ni restriction de répondeur, et
`disableConcurrentBuilds` met les suivants en file. Convention partagée avec
`provision-apply` (préexistante), jamais documentée ni testée — à trancher un
jour (timeout ? submitter ?), au minimum à savoir.

## 5. Comment rejouer la preuve

```bash
cd poc-control-plane-federation
# Hors ligne (aucun service requis) :
ansible-playbook -i ansible/inventory.lab.ini ansible/test-onboard-guards.yml      # gardes du rôle
bash scripts/test-team-apply-wiring.sh                                             # 30/30 câblage statique
# Contre le mock (go run . dans mocks/webmethods, relever le port) :
ansible-playbook -i ansible/inventory.lab.ini ansible/test-onboard-guards-live.yml # 4e ligne de la table EXÉCUTÉE
# La matrice complète (Gitea+Vault+Jenkins réels, mock gateway — JAMAIS 5555) :
GITEA_URL=… GITEA_TOKEN=… VAULT_ADDR=… VAULT_TOKEN=… WM_GATEWAY_URL=… JENKINS_UI=… \
  bash scripts/test-team-onboarding-chain.sh   # attendu : 11 PASS / 0 FAIL, preuve 10 = fort
```

Le verdict `fort` de la preuve 10 exige : oscar en userpass Vault ET en compte
Gitea, les DEUX mocks relancés (ils n'ont pas de DELETE — un re-run sans
relance échoue à raison sur l'ardoise sale), et le job posé. Toute autre issue
que `fort` est un FAIL — les replis sont des détecteurs de régression.

⚠️ La matrice fait transiter des merges de test par `gitea main` (revertés) et
`team-apply.sh` fait un `git checkout` du SHA mergé sur son cwd : **jamais
depuis un worktree de dev, toujours un clone jetable** (documenté en tête).

## 6. Ce qui n'est prouvé par rien (dit franchement)

1. `TEAM_NOT_IN_MERGED_STATE` — LA propriété anti-TOCTOU affichée — jamais vue
   rouge de façon REJOUABLE (contre-épreuve one-shot de T4 seulement).
2. La réparation d'un dépôt vide (le correctif de revue de T4) : hors matrice.
3. Le chemin `repo: ""` (payments-team) : hors matrice.
4. Le commentaire ❌ d'échec du rôle (hiérarchie fatal>tail-3) : hors matrice.
5. Les gardes d'entrée de `team-request` autres que TEAM (`YAML_UNSAFE_INPUT`,
   segments de REPO, `ENV_NOT_OPEN`, classe APPROVERS) : contre-épreuves
   one-shot de T1, non rejouables.
6. **`setup-team-onboard-prereqs.sh` n'a AUCUNE matrice de preuve** — le
   fichier le plus sensible du palier (il écrit une policy et fusionne des
   token_policies) ; ses mesures 204/200/200/403/403 et le rouge/vert du
   verrou fail-closed vivent dans un rapport de tâche.
7. `team-request.job.xml` et `app-request.job.xml` n'ont pas de wiring-test.
8. La branche `--random-password` (création d'oscar) : vérifiée par lecture du
   `--help` Gitea 1.22.6, jamais exécutée (oscar préexiste).
9. Le job `app-request` en mode idp-nominal ; l'identité `jenkins-form:<uid>`
   authentifiée (lab sans sécurité Jenkins) ; la voie machine OIG/CLI2 avec
   `REQ_MODE` explicite par un vrai OIG.

## 7. Ce qu'il faut garder de cette passe

**L'environnement est un terrain, pas une hypothèse.** Quatre écarts que
personne ne connaissait, tous découverts par l'exécution réelle, aucun par la
relecture : la version d'ansible du conteneur, le mount d'auth jamais exercé,
le mock périmé, le mint captif de docker. Les preuves contre le mock et les
preuves statiques n'ont pas menti — elles ne regardaient simplement pas là.

**La classe d'un bug vaut plus que le bug.** Le secret en argv a été corrigé
quatre fois parce qu'il a été traité trois fois comme une occurrence. C'est en
en faisant une CLASSE (balayage systématique, contrôle positif dans la preuve)
qu'il a cessé de revenir. Même leçon pour les extractions non gardées et les
en-têtes qui mentent.

**Un harnais de preuve est du code de production.** Le sien a eu ses propres
revues, ses propres bugs (le teardown qui visait le mauvais mock, le polling
qui laissait un build en pause, le mot de passe qu'il fuyait lui-même), et sa
propre contre-épreuve — il casse une garde et exige son propre FAIL. Un
harnais jamais vu rouge n'est pas un harnais.
