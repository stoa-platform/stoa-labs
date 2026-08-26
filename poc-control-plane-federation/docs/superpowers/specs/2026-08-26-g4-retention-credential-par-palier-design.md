---
title: "G4 — Lever le verrou dev-only par SCELLEMENT, et le remplacer par la rétention de credential par palier"
type: design
status: "Conçu sur relevé du dépôt (6 lecteurs parallèles, 2026-08-26) + vérifications inline. Décisions D1-D9 arbitrées en autonomie (directive /goal g4), chacune avec son coût nommé. À exécuter selon la méthode SDD."
date: 2026-08-26
goal: GOAL-cd-promotion-5-envs-2026-08-26.md
jalon: G4
lié: [adr-075-wm-admin-proxy-multienv, adr-076-gitops-api-lifecycle-repo-per-project, adr-078-livrable-self-service-app-wm1015, adr-079-deploiement-promotion-multienv-import-archive, adr-081-ou-vit-la-decision-humaine, adr-082-ouverture-palier-retention-credential]
---

# G4 — La rétention de credential par palier

**Le mandat du GOAL, mot pour mot** : `ENV_NOT_OPEN` et `ENVN="${ENVN:-dev}"` tombent, remplacés
par trois mécanismes — (1) rétention du credential par palier, (2) définition de pipeline hors du
périmètre d'écriture du demandeur, (3) `scripts/` et `ansible/roles/` sous protection de chemin.
**Porte G4** : un membre de l'équipe demandeuse édite un fichier de la chaîne et pousse ⇒ le
pipeline de promotion ne bouge pas. **Contre-épreuve** : révoquer la policy Vault du palier ⇒
l'apply échoue fermé, gateway inchangée — motif F4, rejoué par palier.

---

## §1 — Ce que le relevé a mesuré

Chaque fait est ancré ; les implémenteurs re-vérifient les lignes avant de s'y appuyer.

1. **Le verrou vit exclusivement dans `scripts/` + `ci/`** — deux refus explicites
   (`team-request.sh:49`, `team-apply.sh:53`) et six défauts `dev` silencieux
   (`team-publish.sh:82`, `api-request.sh:70`, `team-request.sh:32`,
   `setup-team-onboard-jobs.sh:68`, `ci/Jenkinsfile.team-publish:106`,
   `ci/Jenkinsfile.api-request:112`). `labctl/` et `ansible/` n'en portent aucun.
2. **Hors dev, team-publish est mécaniquement sans issue** : `resolve_deploy_pin` y est appelé
   avec 4 arguments (`team-publish.sh:351`), donc `ARCHIVE_ABSENT` est garanti
   (`deploy-pin.sh:272-273`) même avec un marqueur parfait. Le verbe hors-dev est l'import
   d'archive — c'est G5. Lever le seul défaut `ENVN` n'ouvre RIEN : il expose un chemin mort.
3. **`providers.dev.yml` est le seul fichier providers** ; sa correspondance team→repo n'est
   consommée qu'avec `ENVN=dev` partout. Un `providers.rec.yml` n'aurait aucun consommateur
   une fois team-publish scellé (fait 2).
4. **Côté Vault, les DONNÉES sont par palier, le POUVOIR ne l'est pas** :
   `secret/stoa/envs/{dev,rec,int,homol}/wm-admin` existent (`setup-vault-envs.sh:44-50`,
   dérivés d'`env_chain_nonprod`, jamais d'entrée prod), mais la seule policy qui les touche est
   `stoa-proxy-provision` avec le wildcard `envs/+/wm-admin` (`setup-vault-approle.sh:68`).
   Aucune policy par palier n'existe.
5. **Le write tenant est trans-env** : `deploy-<tenant>` et `user-deploy` accordent
   create/update sur tout `apps/*` (`apim_team_onboard/tasks/vault.yml` bloc policy ;
   `setup-user-vault-jwt.sh` bloc `uvj-pol`). Un token dev peut écrire
   `deploy/<t>/apps/<app>/prod/oauth-client` — l'env n'est qu'un segment non gardé.
6. **Les applies self-service sont NOMINATIFS** : team-apply et team-publish font
   `vault_login_nominative` à la pause `input` (`ci/Jenkinsfile.team-apply`,
   `ci/Jenkinsfile.team-publish`, via `ci/lib/vault-login.sh`). Le « job » n'a pas d'identité
   Vault machine propre sur cette voie ; sans identité ⇒ PLAN-only (rc=2).
7. **La voie CONSOMMATEUR n'a jamais été dev-only** : `provision-request.sh:127` accepte
   `dev|rec|int|prod` (liste en dur, sans homol — stale vis-à-vis de G1), l'axe env y est
   légitime (per_env + header `X-Environment`, proxies ADR-075).
8. **Branch protection Gitea : zéro usage réel** — elle n'existe qu'en prose (ADR-081:35,
   `assert-merge-identity.sh:98-106`, ADR-078:72,212). Aucun script ne la pose, aucun ne la
   vérifie. Les dépôts d'équipe sont créés nus (`team-apply.sh:128`, `auto_init:false`, pas de
   protection, pas de collaborateur). L'équipe demandeuse n'a AUCUN droit Gitea aujourd'hui —
   le périmètre d'écriture du demandeur est à définir, pas à restreindre.
9. **Tous les Jenkinsfile SCM viennent du dépôt plateforme `ci/stoa-labs`** — mais (a) les jobs
   exécutent `scripts/*.sh` du MÊME clone : « Jenkinsfile non éditable » ne suffit pas si
   `scripts/` l'est (le trou PPE indirect d'OWASP) ; (b) le job `selfservice-app-deploy` ride la
   branche `feat/selfservice-app-adr078` (`setup-selfservice-job.sh:26`), pas main — or
   `Jenkinsfile.selfservice` existe sur la lignée gitea main (vérifié sur `deliver/gitea-main`) ;
   (c) les `<triggers>`/`<parameters>` du XML posé GAGNENT sur le Jenkinsfile (fait mesuré) — la
   frontière du déclencheur est le config.xml, posé par l'admin Jenkins, hors Git.
10. **Le motif F4 existe mais pas ici** : « rôle révoqué → FAILURE, aucune mutation » a été
    prouvé sur le Vault du cluster (auth kubernetes), jamais rejoué sur `poc-vault`, et aucun
    `test-*` du poc ne le porte. Le 403 inter-policy le plus proche : `demo-multienv.sh:283-292`.
11. **Le refus précis du résolveur n'atteint pas la PR** : `_dp_fail` écrit sur stderr
    (`deploy-pin.sh:48`), `fail()` de team-publish ne capture rien (`team-publish.sh:98`) — la
    PR dit `PIN_NON_RESOLU : … (voir le refus nommé ci-dessus)` et le « ci-dessus » est un log
    Jenkins que le lecteur de la PR ne voit pas. Handoff G3 : c'est LA surface de diagnostic à
    câbler dans G4.
12. **L'épreuve ⑳ de `test-deploy-pin.sh:673-676` verrouille le verrou** (« il appartient à
    G4 ») ; satellites : `test-team-request-wiring.sh:158-160` (présence littérale
    d'`ENV_NOT_OPEN`), `:149-151` (choix `dev,rec,int,prod`),
    `test-api-request-wiring.sh:219-221` (littéral `ENVN = "${env.ENVN ?: 'dev'}"`).
    Toutes devront être RETOURNÉES (asserter le remplacement, pas l'absence).
13. **Gitea 1.22.6 répond à l'API mais s'est montré instable** (endpoints DB et smart-http
    suspendus, restart en cours pendant la conception). La stratégie de preuve est donc
    étagée : hors-ligne d'abord, live en scripts séparés rejouables.

## §2 — Décisions

| # | Question | Tranché | Conséquence |
|---|---|---|---|
| D1 | Comment le verrou « tombe »-t-il ? | **Scellement**, pas ouverture paramétrique : les chemins d'authoring perdent leur axe env (constante de lib, non surchargeable). L'axe palier n'existe QUE sur la chaîne de promotion, où l'autorité est le credential. | `ENV_NOT_OPEN` disparaît par construction (plus de choix d'env à refuser) ; les défauts `:-dev` deviennent des affectations sèches depuis `DEPLOY_PIN_AUTHORING_ENV`. |
| D2 | La forme du plan de credential ? | Policies `apply-<env>` (read `envs/<env>/wm-admin`) + AppRoles `apply-<env>` liés 1:1, pour chaque palier NON terminal de la chaîne, dérivés d'`env_chain_nonprod`. Secret-id jamais minté par défaut. Terminus : ni policy ni AppRole (structurel). | « Ouvrir un palier » = geste Vault de l'exploitant (mint/grant), hors pipeline. Un pipeline compromis ne peut pas se l'accorder. |
| D3 | Le write tenant trans-env ? | Resserré : create/update sur `apps/+/<env>/*` par palier non terminal, dérivé de la chaîne — dans `apim_team_onboard` ET `user-deploy`. | La voie consommateur hors-prod est préservée à l'identique ; une écriture d'app au TERMINUS meurt structurellement (403). Tout chemin legacy « app-request prod » meurt avec — assumé. |
| D4 | team-publish et api-request hors dev ? | Scellés à l'env d'authoring (constante de lib). La publication est un geste d'authoring par conception (ADR-079) ; au-delà, c'est la promotion (G3 marqueurs → G5 verbe). | L'`ENVN` surchargeable par l'environnement du job (une faiblesse mesurable) disparaît. ⑳ est retournée : elle asserte le SCELLEMENT. |
| D5 | team-request / team-apply hors dev ? | L'onboarding d'équipe est un concept d'authoring : le paramètre `REQ_ENV` disparaît du formulaire, l'env du nom de branche `onboard/<team>-<env>` doit ÉGALER l'env d'authoring (refus `ENV_MISMATCH`). | La tenancy aux paliers supérieurs viendra du chemin de promotion (G5) ou d'un geste opérateur D0/D2 — pas de ce formulaire. Pas de `providers.rec.yml` à seeder (fait 3). |
| D6 | La liste consommateur `dev\|rec\|int\|prod` ? | Dérivée d'`env_chain_nonprod` (homol entre, terminus sort — structurel), dans `provision-request.sh` et `provision-plan.sh`. | Cohérent avec D3 ; la liste stale (sans homol) est réparée au passage. |
| D7 | Protections Gitea : quelle forme ? | Lib partagée `scripts/lib/repo-protection.sh` + poseur idempotent `setup-repo-protections.sh` (plateforme, governance, dépôts d'équipe existants) + pose à la création dans `team-apply.sh`. Baseline : main sans push direct (whitelist `ci` seul), tout passe par PR. `protected_file_patterns` : la sémantique 1.22 est MESURÉE par l'épreuve live AVANT d'être encodée dans le poseur. | La porte G4 devient prouvable : un push direct du demandeur sur main est rejeté par Gitea, pas par un `if` à nous. |
| D8 | Le job selfservice sur branche de feature ? | Défaut réaligné sur `main` (`setup-selfservice-job.sh:26`) — le fichier existe sur la lignée gitea main (vérifié). | Un pipeline qui ride une branche non protégée est exactement le trou M2 ; fermé. |
| D9 | La surface de refus ? | team-publish capture stderr du résolveur (fichier, jamais pipe — pipefail) et le DERNIER refus nommé `deploy-pin:` rejoint le commentaire de PR. | Le jour où la chaîne s'exerce, l'équipe lit `PIN_ABSENT` sur sa PR, pas « voir le log ». |

**Pourquoi D1 (et pas l'ouverture paramétrique).** Trois formes examinées. (a) *Paramétrique* :
garder un axe env sur les chemins d'authoring, gardé par la possession du credential à
l'exécution — rejeté : il conserve un axe surchargeable dont AUCUN consommateur n'existe
(faits 2-3), et il ressuscite la surface de défaut que l'arbitrage G3 vient de fermer (« le
palier libre ne se choisit pas de l'extérieur », `deploy-pin.sh:29-37`). (b) *Drapeau Vault*
(« palier ouvert » comme secret lisible) — rejeté : un drapeau est un contrôle qui se lève
lui-même ; le GOAL exige que le contrôle SOIT le credential. (c) *Scellement + plan de
credential* — retenu. **Coût assumé** : l'onboarding d'équipe à un palier supérieur n'est pas
exprimable par le self-service. Clause de réouverture : si un client exige la tenancy déclarée
par palier, elle passera par le chemin de promotion, pas par la réouverture du formulaire.

**Pourquoi D2 pose des AppRoles sans consommateur immédiat.** Le GOAL nomme « policies et
AppRole distincts par palier » comme livrable de G4 ; le consommateur est l'apply de promotion
(G5). Les poser ici, non mintés, fait de G5 un pur câblage — et l'épreuve live prouve dès G4
que le 403 inter-palier tient. Un AppRole non minté n'élargit aucune surface (pas de secret-id
en circulation).

**Pourquoi D5 ne seede aucun `providers.<env>.yml`.** Le seul lecteur non-dev serait
team-publish — scellé par D4. Seeder des fichiers sans consommateur, c'est déclarer une
capacité qui n'existe pas : le contraire de « dire ce que le mécanisme tient vraiment ».

## §3 — Mécanisme 1 : le plan de credential (`scripts/setup-vault-paliers.sh`)

Nouveau script, même famille que `setup-vault-approle.sh` (idempotent, rejouable au re-seed).

- **Dérivation** : `. scripts/lib/env-chain.sh` ; boucle sur `env_chain_nonprod`. AUCUN nom de
  palier en dur ; le terminus est exclu par construction (le dernier de la chaîne, pas « prod »).
- **Par palier `<e>`** : policy `apply-<e>` =
  `path "secret/data/stoa/envs/<e>/wm-admin" { capabilities = ["read"] }` (+ metadata read).
  Rien d'autre — le périmètre est le secret d'admin du palier, pas un sous-arbre.
- **AppRole `apply-<e>`** : `token_policies=apply-<e>`, TTL courts (mêmes ordres que
  `setup-vault-approle.sh:27-29`). **Aucun `--mint` au premier passage** : le script imprime le
  geste d'ouverture (`setup-vault-paliers.sh --mint apply-rec`) sans l'exécuter.
- **Grant nominatif** : l'ouverture d'un palier à un humain = `vault write auth/userpass/users/<u>
  token_policies=+apply-<e>` (ou groupe LDAP `apim-apply-<e>` → policy `apply-<e>`, mapping posé
  par le script, groupes non créés — le mapping seul est inerte). Le script N'ACCORDE RIEN par
  défaut : l'état sorti du script est « tout fermé ».
- **`--print` (mode hors-ligne)** : émet sur stdout les policies HCL et la liste des gestes
  SANS toucher Vault — c'est la surface que l'épreuve hors-ligne mute.
- **Interdit vérifié** : aucun `envs/+` (wildcard multi-palier) dans ce que le script émet.
  `stoa-proxy-provision` (outillage opérateur de pose des proxies) garde le sien — dissymétrie
  NOMMÉE dans le script, avec la clause : le jour où la pose de proxy devient déclenchable par
  un tiers, elle suit la discipline par palier.

**Resserrage tenant (D3)** — deux sites, même forme :
- `ansible/roles/apim_team_onboard/tasks/vault.yml` : le bloc write
  `…/{{ onb_tenant_root }}/apps/*` devient une boucle sur une nouvelle var
  `apim_onb_write_envs` (liste), émettant `…/apps/+/{{ e }}/*` par env. **Défaut de la var :
  `["dev"]`** (fail-closed) ; les appelants (team-apply.sh, onboard-team.yml) passent la chaîne
  non terminale dérivée d'`env_chain_nonprod`. Le chemin metadata suit le même motif.
- `scripts/setup-user-vault-jwt.sh` : le gabarit `uvj-pol` émet les mêmes lignes par env,
  liste dérivée au moment du setup (le script source `env-chain.sh`).

## §4 — Mécanismes 2 + 3 : les protections Gitea

**`scripts/lib/repo-protection.sh`** (nouvelle lib, sourçable, testable hors-ligne) :
- `repo_protection_payload <branch> <push_whitelist_csv> [file_patterns]` → imprime le JSON
  (via python3/json, jamais du formatage de chaîne) : `branch_name`, `enable_push=true`,
  `enable_push_whitelist=true`, `push_whitelist_usernames`, `protected_file_patterns` si fourni.
- `pose_branch_protection <host> <token_file> <owner/repo> <payload>` → GET puis POST/PATCH
  idempotent sur `/api/v1/repos/{owner}/{repo}/branch_protections` ; token en header-file,
  jamais argv (discipline `team-apply.sh:148-168`) ; échec = refus NOMMÉ (`PROTECTION_NON_POSEE`),
  jamais silencieux.

**`scripts/setup-repo-protections.sh`** (poseur opérateur, idempotent) :
- `ci/stoa-labs@main` : push whitelist = `ci` seul. Les patterns de chemin
  (`poc-control-plane-federation/scripts/**;poc-control-plane-federation/ansible/**;poc-control-plane-federation/ci/**`)
  ne sont posés QUE si l'épreuve live a mesuré qu'ils n'étranglent pas le flux de livraison de
  l'exploitant (la mesure décide, pas la doc — voir §6). À défaut, la whitelist de push suffit :
  personne d'autre que `ci` ne pousse main, tout le reste est PR.
- `ci/governance@main` : même baseline.
- Dépôts d'équipe existants (énumérés depuis `providers.dev.yml`, champ `repo` non vide) :
  baseline main. **`environments.yaml` du dépôt d'équipe** ajouté aux `protected_file_patterns`
  si la mesure valide la sémantique.
- `team-apply.sh` : après le push du squelette (l'ordre compte — protéger avant le premier push
  le bloquerait), pose la même baseline via la lib. Échec de pose = ❌ nommé dans le commentaire
  de PR, PAS un `fail` silencieux (même régime que la pose de webhook, `team-apply.sh:183-186`).

**Réalignement du job selfservice (D8)** : `BRANCH="${BRANCH:-main}"` dans
`setup-selfservice-job.sh`, commentaire disant pourquoi (M2 : un pipeline sur branche non
protégée est éditable hors revue).

**Ce que M2 ne peut PAS fermer et qui est dit** : les `<triggers>`/`<parameters>` du config.xml
posé gagnent sur le Jenkinsfile (fait 9c). La frontière est l'admin Jenkins — hors Git. C'est
consigné dans l'ADR-082, pas résolu par G4.

## §5 — Le scellement (D1, D4, D5, D6)

| Fichier | Avant | Après |
|---|---|---|
| `scripts/team-publish.sh:82` | `ENVN="${ENVN:-dev}"` | `. scripts/lib/deploy-pin.sh` (déjà sourcé) ; `ENVN="$DEPLOY_PIN_AUTHORING_ENV"` — affectation sèche, commentaire : la publication est un geste d'authoring (ADR-079) ; au-delà = promotion. |
| `scripts/api-request.sh:70` | idem | idem (le formulaire producteur écrit une PR `api/*` : geste d'authoring). |
| `scripts/team-request.sh:32,49` | `REQ_ENV` param + `ENV_NOT_OPEN` | `REQ_ENV` disparaît ; env = `$DEPLOY_PIN_AUTHORING_ENV`. Le refus `ENV_NOT_OPEN` disparaît par construction. Le script gagne le contrat `DRY_RUN=1` (gardes → exit 0 avant Git/réseau), motif `api-promote-request.sh:131-132`. |
| `ci/Jenkinsfile.team-request` + `ci/jenkins/team-request.job.xml` | `choice REQ_ENV [dev,rec,int,prod]` | Paramètre retiré des deux (le XML gagne sur le Jenkinsfile — les DEUX doivent bouger). |
| `scripts/team-apply.sh:52-53` | dérive `ENVN` du suffixe de branche + `ENV_NOT_OPEN` | dérive toujours (anti-tamper), mais refuse `ENV_MISMATCH : <env> ≠ <authoring>` si le suffixe diffère de la constante — les branches legacy `onboard/*-dev` passent inchangées. |
| `scripts/setup-team-onboard-jobs.sh:68` | `ENVN="${ENVN:-dev}"` | constante de lib (même geste). |
| `ci/Jenkinsfile.team-publish:106`, `ci/Jenkinsfile.api-request:112` | `ENVN = "${env.ENVN ?: 'dev'}"` | La ligne disparaît : le Groovy ne route plus d'axe env ; le script scelle. |
| `scripts/provision-request.sh:127`, `scripts/provision-plan.sh:59` | `case dev\|rec\|int\|prod` | liste dérivée d'`env_chain_nonprod` (voie consommateur : l'axe env est légitime, le terminus sort, homol entre). |

**Règle transverse** : aucune nouvelle constante en dur — TOUT dérive de
`DEPLOY_PIN_AUTHORING_ENV` (lib deploy-pin) ou d'`env_chain*` (lib env-chain). Un client dont le
premier palier s'appelle autrement change UNE ligne de lib.

## §6 — Preuve et contre-épreuves

### Porte hors-ligne : `scripts/test-palier-retention.sh` (branchée sur `make lint-ci`)

Discipline héritée de `test-deploy-pin.sh` : capture fichier jamais pipe (pipefail), ancrage sur
code décommenté (`sed 's/[[:space:]]*#.*$//'`), chaque garde MUTÉE (retirer la garde ⇒ rouge),
chemin nominal obligatoire, sabotage qui OUVRE la porte (jamais qui la soude), restauration
vérifiée par relecture.

| # | Épreuve | Verdict attendu |
|---|---|---|
| 1 | `setup-vault-paliers.sh --print` émet une policy par palier non terminal, dérivée (chaîne jetable via `STOA_ENV_CHAIN_FILE` à 3 paliers ⇒ 2 policies) | conforme |
| 2 | mutation : chaîne jetable réduite, le set de policies suit | rouge si le set ne suit pas |
| 3 | `--print` n'émet AUCUN `envs/+` ; mutation : injecter le wildcard ⇒ détecté | rouge au wildcard |
| 4 | aucun `--mint` exécuté sans l'argument explicite (le mode par défaut n'émet aucun secret-id) | conforme |
| 5 | terminus : ni policy ni AppRole émis pour le dernier palier ; mutation : `env_chain` au lieu d'`env_chain_nonprod` ⇒ rouge | rouge |
| 6 | `vault.yml` (code décommenté) : write sur `apps/+/…/*` par env depuis `apim_onb_write_envs`, plus AUCUN `apps/*` nu ; sonde YAML python, séparateur `\x1f` | conforme |
| 7 | défaut d'`apim_onb_write_envs` = `["dev"]` (fail-closed) dans defaults/main.yml | conforme |
| 8 | `setup-user-vault-jwt.sh` : gabarit uvj-pol par env, plus d'`apps/*` nu (décommenté) | conforme |
| 9 | scellement : CHAQUE site du tableau de §5 ne porte plus ni `:-dev` ni `ENV_NOT_OPEN` ; chacun porte l'affectation sèche depuis la constante/chaîne (grep décommenté, par site) | conforme |
| 10 | mutation : remettre `ENVN="${ENVN:-dev}"` dans team-publish.sh ⇒ rouge | rouge |
| 11 | `team-apply.sh` porte `ENV_MISMATCH` et le compare à la constante (pas à `dev` littéral) ; mutation : remplacer par `dev` en dur ⇒ rouge | rouge |
| 12 | `repo_protection_payload` : JSON bien formé (python -c json.loads), branch/whitelist/patterns présents ; mutation : casser l'échappement ⇒ rouge | conforme |
| 13 | `team-apply.sh` APPELLE `pose_branch_protection` (code décommenté, appel réel — « sourcer n'est pas appeler », leçon G3) et APRÈS le push du squelette (ordre par numéros de ligne) | conforme |
| 14 | mutation : retirer l'appel ⇒ rouge | rouge |
| 15 | D9 : team-publish capture stderr du résolveur dans un fichier et le refus `deploy-pin:` rejoint l'argument de `fail` ; mutation : supprimer la capture ⇒ rouge | rouge |
| 16 | `setup-selfservice-job.sh` : défaut `BRANCH` = main | conforme |
| 17 | Jenkinsfile.team-request/team-publish/api-request : plus d'axe env routé (grep décommenté) ; le job.xml team-request n'a plus le choice | conforme |
| 18 | chemin nominal : `team-request.sh` gagne le contrat `DRY_RUN=1` d'`api-promote-request.sh:131-132` (gardes OK → `exit 0` AVANT tout geste Git/réseau) et l'épreuve le traverse VERT sans variable d'env — une suite toute en refus ne prouve rien | conforme |

(La numérotation finale et le compte X/0 appartiennent au plan ; chaque garde nouvelle du code
DOIT avoir son épreuve de mutation — c'est la règle, pas la liste.)

### Portes live (lab requis, scripts séparés, rejouables)

**`scripts/test-palier-retention-live.sh`** (Vault poc) :
- pose réelle (`setup-vault-paliers.sh` sans `--print`), puis matrice 403 : token minté
  `apply-dev` lit `envs/dev/wm-admin` ✓, `envs/rec/…` ✗ 403 (et symétriques) ;
- token tenant (alice) : write `apps/x/rec/probe` ✓, `apps/x/<terminus>/probe` ✗ 403 ;
- **motif F4 par palier** : révoquer la policy `apply-<e>` ⇒ le geste d'apply minimal échoue
  FERMÉ — prouvé par canari : la « gateway » du harnais est un listener local qui enregistre
  toute connexion ; l'épreuve exige `rc≠0` ET **zéro connexion** au canari. Restauration
  vérifiée, motif `restore_lib` de G3.

**`scripts/test-repo-protections-live.sh`** (Gitea) :
- **MESURE d'abord** : sur un dépôt jetable, poser une protection avec `protected_file_patterns`
  et mesurer — (a) un push direct touchant le fichier protégé, (b) le merge d'une PR qui le
  touche, (c) le comportement pour un admin. Le verdict est ÉCRIT dans la sortie du test et le
  poseur n'encode que ce qui est mesuré vrai.
- **Porte G4 rejouée** : utilisateur jetable collaborateur write du dépôt d'équipe : push direct
  sur main ⇒ REJETÉ ; push sur `ci/stoa-labs` ⇒ 403 ; sa PR sur le dépôt d'équipe reste
  mergeable par la voie normale (la protection ne casse pas le flux légitime).
- team-request → team-apply rejoués après scellement (le flux dev intact, E2E).

### Contre-épreuves imposées par le GOAL
- « révoquer la policy Vault du palier ⇒ apply fermé, gateway inchangée » — c'est le F4-canari
  ci-dessus, par palier de la chaîne non terminale.
- « un membre édite un fichier de la chaîne et pousse ⇒ le pipeline ne bouge pas » — c'est le
  push rejeté + l'absence de tout build déclenché (le webhook ne part que sur PR mergée).

### §6.1 — Ce que G4 ne prouve PAS, et c'est voulu
- **Aucun apply réel à un palier supérieur** : le verbe est G5. G4 prouve la rétention (le refus
  fermé), pas la promotion (l'acte).
- **La parité des deux moteurs** : G8.
- **`DeployerGroup`** (« qui déclenche ») : G2. La porte G4 prouve que le demandeur ne peut pas
  ALTÉRER la chaîne ; pas encore que seul le groupe déployeur peut la DÉCLENCHER.
- **La sémantique `protected_file_patterns` n'est pas supposée** : tant que la mesure live n'a
  pas tourné (Gitea instable), le poseur n'émet que la baseline whitelist — et le dit.
- **Le config.xml Jenkins reste hors périmètre Git** (fait 9c) — nommé dans l'ADR-082, non résolu.

## §7 — Inventaire des livrables

| Fichier | Nature | Geste |
|---|---|---|
| `scripts/setup-vault-paliers.sh` | poseur credential plane (+ `--print`, `--mint`) | Créer |
| `scripts/lib/repo-protection.sh` | lib protections Gitea | Créer |
| `scripts/setup-repo-protections.sh` | poseur protections (plateforme, governance, équipes) | Créer |
| `scripts/test-palier-retention.sh` | porte hors-ligne (lint-ci) | Créer |
| `scripts/test-palier-retention-live.sh` | porte live Vault (403 + F4-canari) | Créer |
| `scripts/test-repo-protections-live.sh` | mesure + porte live Gitea | Créer |
| `ansible/roles/apim_team_onboard/tasks/vault.yml` + `defaults/main.yml` | write par palier (D3) | Modifier |
| `scripts/setup-user-vault-jwt.sh` | user-deploy par palier (D3) | Modifier |
| `scripts/team-request.sh`, `scripts/team-apply.sh`, `scripts/team-publish.sh`, `scripts/api-request.sh`, `scripts/setup-team-onboard-jobs.sh` | scellement (D1/D4/D5) + protections à la création + surface de refus (D9) | Modifier |
| `scripts/provision-request.sh`, `scripts/provision-plan.sh` | liste dérivée (D6) | Modifier |
| `ci/Jenkinsfile.team-request`, `ci/jenkins/team-request.job.xml`, `ci/Jenkinsfile.team-publish`, `ci/Jenkinsfile.api-request` | axe env retiré | Modifier |
| `scripts/setup-selfservice-job.sh` | branche défaut main (D8) | Modifier |
| `scripts/test-deploy-pin.sh` (⑳), `scripts/test-team-request-wiring.sh`, `scripts/test-api-request-wiring.sh`, `scripts/test-team-publish-wiring.sh`, `scripts/test-team-apply-wiring.sh` | épreuves retournées (asserter le remplacement) + EXPECTED_CHECKS | Modifier |
| `Makefile` (lint-ci) | + shellcheck des nouveaux .sh, + test-palier-retention | Modifier |
| `adr/adr-082-ouverture-palier-retention-credential.md` | l'ADR du jalon | Créer |
| `ENVIRONNEMENTS.md`, `GOAL-cd-promotion-5-envs-2026-08-26.md` (statut G4) | docs | Modifier |
| `HANDOFF-2026-08-26-G4-RETENTION-CREDENTIAL.md` | handoff de fin | Créer |

## §8 — Questions ouvertes et parkings, avec rulings

1. **`apim_ss_authoring_env` surchargeable (CRITIQUE parqué en G3)** : G4 ne rend PAS
   `apim_promote_api` déclenchable par un tiers (c'est G5). Le parking tient, la clause de
   réouverture (`defaults/main.yml:106-110`) est reprise dans le brief G5 via l'ADR-082.
   **Ruling maintenu, à la première personne.**
2. **`stoa-proxy-provision` garde son wildcard `envs/+`** : outillage opérateur, pas identité de
   pipeline. Dissymétrie nommée dans `setup-vault-paliers.sh`. Réouverture : le jour où la pose
   de proxy est déclenchable par un tiers.
3. **Les grants humains par palier** (qui a `apply-rec` ?) : décision client (groupes annuaire —
   décision n°2 du GOAL). G4 livre le mécanisme fermé par défaut, pas la politique d'attribution.
4. **Deux gestes G1 toujours en attente** (`setup-release-team.sh`, `seed-governance-chain.sh`)
   — bloqués classifieur, à lancer en `! bash` par l'exploitant. Sans eux, homol/prod restent
   inapprouvables (fail-closed). G4 n'en dépend pas.
5. **Gitea instable** (fait 13) : si l'instabilité persiste, les portes live sont livrées
   rouges-par-absence-de-lab et consignées comme telles — jamais « supposées vertes ».
