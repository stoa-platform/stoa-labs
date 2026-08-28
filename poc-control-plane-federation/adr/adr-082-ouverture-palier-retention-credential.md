---
title: "ADR-082 — Ouvrir un palier de déploiement est un geste de credential, jamais un edit de code. Le verrou dev-only ne se « lève » pas, il se SCELLE : l'axe env disparaît des chemins d'authoring (constante de lib non surchargeable), et le seul endroit où un palier existe est la chaîne de promotion, où l'autorité est la possession d'un AppRole apply-<env> et une protection de branche Gitea qu'un pipeline compromis ne se donne pas à lui-même."
sidebar_label: "ADR-082 : ouvrir un palier = un geste de credential, pas un if"
status: "Acté pour le MÉCANISME, prouvé par les portes (hors-ligne test-palier-retention.sh 126/0 branchée sur make lint-ci ; live Vault test-palier-retention-live.sh 24/24 avec matrice 403 + F4-canari ; live Gitea test-repo-protections-live.sh 13/13). Reste une DÉCISION CLIENT : la politique d'attribution des grants par palier (qui a apply-rec ?), décision n°2 du GOAL. G4 livre le mécanisme fermé par défaut, pas la politique."
maturite_technique: "✅ Mécanisme prouvé — contrairement à ADR-081 (décision d'endroit, non testable), la rétention de credential EST un mécanisme : la matrice 403 par palier et le F4-canari (révoquer la policy ⇒ apply fermé, gateway inchangée, zéro connexion au canari) le démontrent en live. Le SCELLEMENT (D1) est prouvé hors-ligne par mutation — remettre la garde retirée doit rougir. Ce qui reste au registre des décisions et non des preuves : où placer la frontière des grants humains, et le config.xml Jenkins qui gagne sur le Jenkinsfile (frontière = admin Jenkins, hors Git)."
date: 2026-08-26
adr_number: 82
note: "Précise ADR-076 (GitOps, repo-par-projet — G4 s'appuie sur le marqueur repo-par-projet, divergence §1 déjà consignée en G3, non re-tranchée ici) et ADR-078/ADR-079 : lève le verrou dev-only qu'ADR-079 avait posé comme frontière d'authoring, sans réintroduire un axe env surchargeable. Consomme la décision d'ADR-081 (l'autorité est le merge sous protection de branche) et l'étend aux définitions de pipeline et à la référence de déploiement."
lié: "[[adr-074-vault-secrets]], [[adr-076-gitops-api-lifecycle-repo-per-project]], [[adr-077-user-identity-to-vault-token-exchange]], [[adr-078-livrable-self-service-app-wm1015]], [[adr-079-deploiement-promotion-multienv-import-archive]], [[adr-081-ou-vit-la-decision-humaine]]"
---

# ADR-082 — Ouvrir un palier est un geste de credential, pas un edit de code

**Statut :** Acté pour le mécanisme, prouvé par les portes. La politique d'attribution des grants par palier reste une décision client (décision n°2 du GOAL).

**Maturité technique :** ✅ Mécanisme prouvé en live (matrice 403 par palier + F4-canari) et scellement prouvé hors-ligne par mutation. Le config.xml Jenkins qui gagne sur le Jenkinsfile reste une frontière hors Git, nommée mais non fermée par G4.

**Lié à :** [[adr-074-vault-secrets]], [[adr-076-gitops-api-lifecycle-repo-per-project]], [[adr-077-user-identity-to-vault-token-exchange]], [[adr-078-livrable-self-service-app-wm1015]], [[adr-079-deploiement-promotion-multienv-import-archive]], [[adr-081-ou-vit-la-decision-humaine]].

---

## Contexte

Jusqu'à G3, le fait qu'une demande self-service ne puisse cibler que `dev` reposait sur **trois `if` shell**, lisibles et éditables par le demandeur lui-même : `ENV_NOT_OPEN` dans `team-request.sh`, et les défauts `ENVN="${ENVN:-dev}"` dans `team-publish.sh`, `api-request.sh`, `team-apply.sh`, `setup-team-onboard-jobs.sh`. Un contrôle de ce genre se contourne de trois façons : surcharger la variable d'environnement du job, éditer la ligne, ou déclencher le pipeline sur une branche non protégée qui la porte différemment.

Le GOAL G4 énonce le besoin sans détour : le verrou dev-only doit **tomber**, mais être remplacé par « un contrôle qui ne se lève pas lui-même » — le seul qu'un pipeline compromis ne puisse pas s'accorder. Trois formes ont été examinées (spec §2, « Pourquoi D1 ») :

- **paramétrique** — garder un axe env sur les chemins d'authoring, gardé à l'exécution par la possession du credential : rejetée, elle conserve un axe surchargeable dont AUCUN consommateur n'existe (aucun `providers.rec.yml`, aucune équipe non-dev) et ressuscite la surface de défaut que l'arbitrage G3 venait de fermer ;
- **drapeau Vault** — « palier ouvert » comme secret lisible : rejetée, un drapeau est un contrôle qui se lève lui-même, l'inverse de ce que le GOAL demande ;
- **scellement + plan de credential** — retenue.

## Décision

**Le verrou ne se lève pas, il se SCELLE. L'axe env disparaît des chemins d'authoring ; là où un palier existe encore — la chaîne de promotion — l'autorité n'est plus un `if` mais un credential et une protection de branche.** Trois mécanismes, aucun `if` de plus.

### 1. L'axe env est scellé sur les chemins d'authoring (D1, D4, D5, D6)

Les scripts d'authoring — `team-request`, `team-apply`, `team-publish`, `api-request`, `setup-team-onboard-jobs` — ne dérivent plus leur env d'une variable ni d'un paramètre de formulaire. Ils lisent une **constante de bibliothèque non surchargeable**, `DEPLOY_PIN_AUTHORING_ENV` (dans `scripts/lib/deploy-pin.sh`). Le paramètre `REQ_ENV` disparaît du formulaire `team-request` **et** de son `job.xml` (le XML gagne sur le Jenkinsfile — les deux doivent bouger). `team-apply` continue de dériver l'env du suffixe de branche `onboard/<team>-<env>` par anti-tamper, mais **refuse** `ENV_MISMATCH` si le suffixe diffère de la constante. `ENV_NOT_OPEN` disparaît **par construction** : il n'y a plus de choix d'env à refuser.

La voie **consommateur** (`provision-request`, `provision-plan`) garde un axe env — il y est légitime — mais sa liste `dev|rec|int|prod` est désormais **dérivée d'`env_chain_nonprod`** (homol entre, terminus sort, structurellement), plus une constante stale.

Règle transverse : **aucune nouvelle constante en dur.** Tout dérive de `DEPLOY_PIN_AUTHORING_ENV` ou d'`env_chain*`. Un client dont le premier palier s'appelle autrement change **une** ligne de lib.

### 2. Ouvrir un palier est un geste de credential (D2, D3)

`scripts/setup-vault-paliers.sh` (nouveau, même famille idempotente que `setup-vault-approle.sh`) pose, **pour chaque palier non terminal** dérivé d'`env_chain_nonprod` :

- une policy `apply-<env>` en lecture du seul secret d'admin du palier (`secret/data/stoa/envs/<env>/wm-admin`), rien d'autre ;
- un AppRole `apply-<env>` lié 1:1, **jamais minté par défaut** — le script imprime le geste (`setup-vault-paliers.sh --mint apply-rec`) sans l'exécuter.

Le **terminus** ne reçoit ni policy ni AppRole : structurellement, on ne peut pas déployer au dernier palier par cette voie. Le write tenant trans-env est resserré en parallèle (D3) à `apps/+/<env>/*` par palier non terminal, dans `apim_team_onboard` **et** `setup-user-vault-jwt.sh` — une écriture d'app au terminus meurt en 403.

Conséquence directe : **« ouvrir rec à un humain » = un geste Vault de l'exploitant** (`--mint apply-rec`, puis — voie recommandée, additive — ajout de l'humain au groupe annuaire `apim-apply-rec` dont le mapping `auth/ldap/groups/apim-apply-rec` → policy `apply-rec` est déjà posé par le script ; la voie userpass directe doit réécrire la liste `token_policies` **complète**, `vault write` remplaçant sans append `+`). L'état sorti du script est « tout fermé ». **Un pipeline compromis ne peut pas se l'accorder** — il n'a pas la main sur Vault. Les AppRoles sont posés sans consommateur immédiat (le consommateur est l'apply de promotion, G5) ; un AppRole non minté n'élargit aucune surface, aucun secret-id ne circule.

### 3. Pipelines et référence de déploiement sous protection de branche Gitea (D7, D8)

`scripts/lib/repo-protection.sh` (lib sourçable, testable hors-ligne) et `scripts/setup-repo-protections.sh` (poseur idempotent) posent la baseline « main sans push direct, whitelist `ci` seul, tout passe par PR » sur `ci/stoa-labs@main`, `ci/governance@main` et les dépôts d'équipe existants. `team-apply.sh` pose la même baseline **à la création** d'un dépôt d'équipe, **après** le push du squelette (l'ordre compte — protéger avant le premier push le bloquerait) ; l'échec de pose est un ❌ nommé dans le commentaire de PR, jamais un `fail` silencieux. Le défaut du job selfservice repointe sur `main` (`BRANCH="${BRANCH:-main}"`) — un pipeline qui ride une branche non protégée est éditable hors revue, le trou M2 d'OWASP PPE, désormais fermé. La garde d'identité du valideur d'ADR-081 (`assert-merge-identity.sh`) reste en défense en profondeur ; le contrôle principal est Git.

## Ce qui est prouvé — les comptes des portes

| Porte | Nature | Résultat |
|---|---|---|
| `scripts/test-palier-retention.sh` (nouvelle, branchée sur `make lint-ci`) | hors-ligne, chaque garde MUTÉE | **126 / 0** |
| `scripts/test-palier-retention-live.sh` (Vault poc) | live : matrice 403 par palier + F4-canari | **24 / 24** |
| `scripts/test-repo-protections-live.sh` (Gitea) | live : mesure + porte push/merge | **13 / 13** |
| `make lint-ci` | shellcheck + 15 épreuves + portes | vert `[1/5]`→`[5/5]`, rc=0 |

Le F4-canari mérite d'être lu : révoquer la policy `apply-<env>` doit faire échouer **fermé** le geste d'apply minimal — l'épreuve exige `rc≠0` **et** zéro connexion au listener-canari local. C'est la contre-épreuve exacte du GOAL (« révoquer la policy Vault du palier ⇒ apply fermé, gateway inchangée »), rejouée par palier.

## Mesures live qui font désormais autorité (T9)

Trois faits, mesurés sur le lab, gouvernent l'exploitation — à consigner noir sur blanc parce que la doc n'y accédait pas avant :

1. **`protected_file_patterns` (Gitea 1.22) est un gate de CONTENU indépendant du rôle.** Il bloque le push direct **et** le merge d'une PR qui touche un fichier protégé (405), **l'admin de site compris**. C'est ce qui rend la protection des `scripts/**`/`ansible/**`/`ci/**` réelle et non décorative — la mesure a levé l'hypothèse laissée ouverte en spec §6.1.
2. **Le PATCH `branch_protection` de 1.22 FUSIONNE** (un champ absent du corps est préservé). Re-passer la baseline est donc **non destructif** : pas besoin de GET-merge-PATCH. Cela résout favorablement le risque « clobber silencieux » qu'un reviewer avait soulevé en T6.
3. **L'admin de site N'EST PAS exempté du `push_whitelist`.** Le défaut `PROTECT_PUSH_WHITELIST=ci` est donc **portant** et **doit rester aligné sur `GITEA_ADMIN_USER`** : sinon le chemin de réparation de `team-apply` (qui pousse le squelette sous l'identité admin avant de protéger) casse.

## Ce que ça ne ferme PAS (copie fidèle de la spec §6.1)

- **Aucun apply réel à un palier supérieur.** Le verbe de promotion (import d'archive à GUID stables) est **G5**. G4 prouve la rétention — le refus fermé — pas la promotion, l'acte.
- **La parité des deux moteurs** (`apim_promote_api` vs `labctl promote`) est **G8**.
- **`DeployerGroup` — « qui déclenche »** — est **G2**. La porte G4 prouve que le demandeur ne peut pas ALTÉRER la chaîne ; pas encore que seul le groupe déployeur peut la DÉCLENCHER.
- **Le config.xml Jenkins gagne sur le Jenkinsfile** (fait 9c). Les `<triggers>`/`<parameters>` du job posé priment sur le fichier versionné : la frontière est **l'admin Jenkins, hors Git**. Nommé ici, non résolu par G4 — geste de déploiement à ne pas oublier : re-poser le job pour que le config.xml reflète les listes.

## Parkings, avec clause de réouverture

1. **`apim_ss_authoring_env` surchargeable (classé CRITIQUE, parqué en G3).** G4 ne rend PAS `apim_promote_api` déclenchable par un tiers — c'est G5. Tant que l'opérateur lance le play lui-même (degrés D0/D2), lui interdire de nommer son env d'authoring reviendrait à coder « dev » en dur. **Clause de réouverture, écrite dans `ansible/roles/apim_promote_api/defaults/main.yml:106-110` :** le jour où ce rôle devient déclenchable par un job/webhook/API, le default doit suivre la discipline CI (valeur figée, hors de portée de l'appelant). À sceller quand G5 câble le déclenchement par un tiers.
2. **`stoa-proxy-provision` garde son wildcard `envs/+`.** Outillage opérateur de pose des proxies, pas identité de pipeline. Dissymétrie nommée dans `setup-vault-paliers.sh`. Réouverture : le jour où la pose de proxy devient déclenchable par un tiers, elle suit la discipline par palier.
3. **La cible de pose `$REPO_FULL` et le poseur sont lus dans l'arbre mergé.** Un push direct d'un fichier de la chaîne est bloqué par Gitea (mécanisme), mais la cible que `team-apply`/`setup-repo-protections` protègent est écrite par le demandeur dans le dépôt d'équipe. La frontière ici est tenue par **la revue de PR + la protection de `ci/stoa-labs@main`**, pas par le code. Même classe que le résiduel `merged_by` d'ADR-081.
4. **Profondeur fixe `apps/+/<env>/`.** Le resserrage D3 suppose un `kv_tpl` à un niveau de préfixe. Un client dont le gabarit KV a deux niveaux verra son write mourir en 403 **loin de la cause apparente**. À nommer dans la checklist rollout : poser `STOA_ENV_CHAIN_FILE` et vérifier la profondeur du gabarit.

## Divergence assumée avec ADR-076 §1 (rappel, non re-tranché)

ADR-076 §1 dessinait le marqueur de déploiement à la racine du dépôt, sous l'hypothèse « un dépôt = une API ». G3 a amendé ce point (le squelette porte `apis/` **et** `applications/`) et G4 **s'appuie sur ce marqueur repo-par-projet** sans le re-trancher — la décision est déjà consignée dans le handoff G3 et dans ADR-076 amendé.

## Conséquences

**Sur l'existant.** Le verrou dev-only d'ADR-079 (frontière d'authoring, `team-publish.sh:82`) est **remplacé**, pas seulement retiré : le lever sans son remplacement aurait livré la moitié de G4 — un contrôle ôté contre rien. Les épreuves retournées (`test-deploy-pin.sh` ⑳, les quatre wiring-tests) **assertent désormais le scellement** : elles rougissent si un `:-dev` ou un `ENV_NOT_OPEN` réapparaît.

**Sur le travail à faire.** G5 devient un **pur câblage** : les policies et AppRoles `apply-<env>` existent, non mintés ; brancher le verbe archive consomme un AppRole déjà posé. L'épreuve live prouve dès aujourd'hui que le 403 inter-palier tient.

**Sur la frontière des secrets.** Le grant nominatif reste indépendant de « qui initialise Vault » (ADR-078 §2, voie A/B) et de l'exchange d'identité (ADR-077). G4 fixe seulement que l'ouverture est un **geste hors pipeline**.

## Résiduel

- **Politique d'attribution des grants** (qui a `apply-rec` ? groupes annuaire) : décision client n°2 du GOAL. G4 livre le mécanisme fermé par défaut, pas la politique.
- **Les deux gestes G1** (`setup-release-team.sh`, `seed-governance-chain.sh`) restent en attente (bloqués classifieur, à lancer en `! bash`). Sans eux, homol/prod restent inapprouvables — fail-closed, mais bloquant. G4 n'en dépend pas.
- **Le config.xml Jenkins** reste hors périmètre Git : re-poser les jobs après tout changement de listes, sinon le config.xml posé prime silencieusement.
