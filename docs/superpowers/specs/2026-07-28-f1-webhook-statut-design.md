# Spécification — F1 : déclenchement par push + statut de commit

**Date :** 2026-07-28
**Statut :** cadré depuis le GOAL lot 2 (`poc-control-plane-federation/GOAL-socle-vers-gateway-2026-07-28.md`, commit `a91f5e5`), exécution en mode `/goal` autonome.
**Périmètre :** solde le critère du lot 1 — « un pipeline déclenché par un push dans Gitea » et « échec de pipeline → statut de commit rouge dans Gitea » (spéc lot 1, introduction et §6). Aucun autre jalon du lot 2 n'est touché.

---

## 1. Porte de preuve (reprise du GOAL, inchangée)

> **Porte F1 :** un `git push` sur `ci/probe` déclenche le build **sans action
> humaine** ; le commit porte un statut vert dans Gitea.
> **Contre-épreuve :** casser le Jenkinsfile → le commit porte un statut
> **rouge**. Un statut qui ne rougit jamais ne prouve rien.

## 2. Constats d'entrée (recon du 2026-07-28, session F1)

- `gitea-0`, `jenkins`, `vault-0` : `1/1 Running` ; **Vault descellé** (`Sealed false`, readiness verte).
- `GET /api/v1/repos/ci/probe/hooks` → `[]` : aucun webhook n'existe — l'écart assumé du lot 1 est bien l'état réel.
- Job `probe` : `<triggers/>` vide, pipeline SCM (`ci/probe`, `*/main`, `Jenkinsfile`), conforme au XML versionné.
- Plugin `generic-webhook-trigger` **2.4.2** installé — la même version que le POC compose, dont `ci/jenkins/provision-apply.job.xml` fournit la forme XML exacte du trigger (`PipelineTriggersJobProperty`).
- Jenkins répond en anonyme (config.xml servie, liste de plugins servie) — état lot 1 : pas de realm de sécurité, JCasC = dette actée pour F4.
- `GITEA__webhook__ALLOWED_HOST_LIST=jenkins.ci.svc.cluster.local` déjà posé (tâche 1 du lot 1) : Gitea n'acceptera d'appeler que ce host.
- Le rôle Vault `jenkins-agent` (policy read sur `secret/data/ci/*`) est en place et prouvé (G-b/G-c).

## 3. Décisions

### D1 — Déclenchement : `generic-webhook-trigger` sur le job `probe` existant

Trigger ajouté dans `<properties><PipelineTriggersJobProperty>` du job (forme du précédent POC, même version de plugin) :

- Variables : `GWT_REF ← $.ref`, `GWT_AFTER ← $.after` (payload push Gitea).
- Filtre : `regexpFilterText=$GWT_REF`, `regexpFilterExpression=^refs/heads/main$` — seuls les push sur `main` déclenchent. Le filtrage vit d'un seul côté (Jenkins) : les tentatives filtrées restent visibles dans la réponse du plugin, donc diagnosticables.
- Jeton d'invocation aléatoire (`openssl rand -hex 24`), routage par jeton : `POST /generic-webhook-trigger/invoke?token=<jeton>` ne déclenche que ce job. L'endpoint GWT est une `UnprotectedRootAction` (pas de crumb CSRF).
- `DisableConcurrentBuildsJobProperty` ajoutée (précédent POC) : pas de course de statuts sur des push rapprochés.

**Rejeté :** *polling SCM* (ce n'est pas un déclenchement par push — latence, charge) ; *plugin Gitea Jenkins* (absent de l'image, et il exigerait un credential stocké dans Jenkins — violerait l'assertion `credentials.xml absent`, rejouée en F4).

### D2 — Statut de commit : posté par le pipeline, jeton lu dans Vault par identité de pod

Le `Jenkinsfile` de `ci/probe` pose le statut lui-même via l'API Gitea
(`POST /api/v1/repos/ci/probe/statuses/{sha}`) : `pending` au démarrage, puis
`success` ou `failure` selon l'issue — depuis le pod agent (SA `jenkins-agent`),
avec un **PAT Gitea lu dans Vault à chaque build** :

- PAT du user `ci`, scope `write:repository`, nommé `probe-status`.
- Stocké dans **`secret/ci/probe-status`** (champ `token`) — couvert par la policy `jenkins-agent` existante (`secret/data/ci/*` en lecture) : **zéro changement de policy, zéro changement de rôle**.
- SHA visé : `GWT_AFTER` (webhook) ou le commit du `checkout scm` (déclenchement manuel).
- `context: jenkins/probe`, `target_url: BUILD_URL` (URL interne au cluster, assumé — aucune exposition publique, doctrine lot 1).
- Étape G-c d'origine (lecture `secret/ci/probe`) conservée telle quelle : la preuve lot 1 reste rejouée à chaque build.
- Échec de la pose de statut = échec du build (fail-closed, pas de statut silencieusement perdu).

C'est la mécanique G-c réutilisée pour son premier usage réel — exactement ce que
F4 généralisera (« identifiants wM obtenus depuis Vault par identité de pod »).

**Rejeté :** *credential dans Jenkins* (viole `credentials.xml absent`) ; *Secret Kubernetes monté dans le pod* (contourne Vault — « chaque identifiant par Vault », Décision du GOAL) ; *basic auth `ci`/`ci-bootstrap` dans le Jenkinsfile* (secret en clair dans un dépôt).

### D3 — L'écriture dans Vault est une porte utilisateur (secret zéro)

Écrire `secret/ci/probe-status` exige un jeton Vault à droits d'écriture — le
jeton racine, **hors ligne chez l'exploitant par conception** (lot 1, tâche 3).
Aucun agent ne peut ni ne doit le faire. C'est **la seule intervention humaine**
de F1 : une commande `vault kv put` fournie prête à l'emploi (placeholder
`<JETON_RACINE>`, style lot 1), le jeton ne transitant jamais par la session.
Le PAT est créé par l'agent via l'API Gitea (basic auth `ci`/`ci-bootstrap`,
déjà en clair dans les docs du lot 1 — rotation actée pour F4) ; sa valeur est
du même niveau de sensibilité que ce mot de passe bootstrap.

### D4 — Contre-épreuve : sabotage à l'exécution, limite syntaxique documentée

« Casser le Jenkinsfile » = commit qui fait échouer le build à l'exécution
(étape `exit 1`). Le `catch` poste alors le statut **rouge** — c'est la preuve
que le rouge existe. **Limite connue, assumée :** un Jenkinsfile
*syntaxiquement invalide* échoue avant tout pod agent — personne ne peut poster
de statut, le commit reste **sans statut** (ni vert ni rouge). Le durcissement
(JCasC + job wrapper posant `pending`/`failure` depuis le contrôleur) appartient
à F4, qui apporte JCasC de toute façon. La contre-épreuve du GOAL est satisfaite
par l'échec d'exécution ; la nuance est écrite ici pour n'être découverte par
personne d'autre.

### D5 — Le jeton webhook n'entre pas dans Git

Le jeton d'invocation vit dans l'état des deux systèmes (config du job dans
`jenkins-home`, webhook dans la base Gitea — tous deux couverts par la
sauvegarde PVC du lot 1). Le XML versionné
(`docs/superpowers/plans/2026-07-28-jenkins-probe-job.xml`) porte le placeholder
`__WEBHOOK_TOKEN__` : à la reconstruction, on **frappe un jeton neuf** et on le
pose des deux côtés — un secret régénérable n'a pas besoin d'être conservé.
Sensibilité faible (il ne permet que de déclencher un build, depuis l'intérieur
du cluster uniquement — Jenkins est ClusterIP, sans Ingress), mais la discipline
« pas de secret dans Git » reste la même pour tous.

### D6 — Aucun manifeste ne change

F1 est du **câblage d'état applicatif** : config de job Jenkins (REST), webhook
Gitea (API), deux à trois commits sur le dépôt `ci/probe` (dans Gitea), un
secret Vault. Le dépôt `stoa` n'est pas touché ; Argo CD ne voit rien passer.
Dans `stoa-labs` : le XML du job est mis à jour (reconstruisibilité), le
`Jenkinsfile` final est versionné à côté
(`docs/superpowers/plans/2026-07-28-probe-Jenkinsfile.groovy`), et le GOAL lot 2
voit sa ligne « État » de F1 passer à « fermé » avec renvoi vers la preuve.

## 4. Architecture du flux (état cible)

```
push (API ou git) sur ci/probe [main]
   │
   ▼
Gitea ── webhook push (ALLOWED_HOST_LIST ✓) ──▶ Jenkins
         POST /generic-webhook-trigger/invoke?token=…   (GWT 2.4.2)
   │                                             filtre ^refs/heads/main$
   │                                                    │
   │                                        build du job `probe`
   │                                        pod agent (SA jenkins-agent)
   │                                                    │
   │                    ┌── login k8s → Vault ── lit secret/ci/probe (G-c, inchangé)
   │                    │                     └─ lit secret/ci/probe-status (PAT)
   │                    ▼
   └◀── POST /repos/ci/probe/statuses/{sha}  (pending → success|failure)
```

## 5. Gestion d'erreur

- Vault scellé ou rôle révoqué → le build échoue **fermé** (G-c) et aucun statut n'est posté — pas même `pending`, qui exige lui aussi le PAT lu dans Vault : le commit reste **sans statut**, le build est rouge dans Jenkins. Cohérent avec la doctrine « un CI qui ne peut pas s'authentifier s'arrête ».
- Push sur une autre branche que `main` → GWT répond « did not match », aucun build.
- Jeton d'invocation faux → GWT ne route vers aucun job (réponse explicite), aucun build.
- Pose de statut en échec (Gitea down, PAT révoqué) → build rouge (fail-closed).

## 6. Note de processus (mode `/goal` autonome)

Le cadrage F1 (but, contraintes, critères) est celui du GOAL lot 2, écrit et
commité par l'exploitant (`a91f5e5`) — il tient lieu de brainstorm approuvé.
Les portes interactives du processus (revue de spéc) sont regroupées sur la
**porte utilisateur D3** : au moment de la seule intervention humaine, cette
spéc et le plan sont déjà commités et relisibles. Toute objection à ce moment-là
coûte un revert de câblage d'état (aucun manifeste, aucune migration) — le
risque d'avancer sans revue préalable est borné par construction.
