---
title: "ADR-099 — La chaîne ne crée rien sur la forge : dépôt d'équipe, webhooks et protection de branche sont des PRÉREQUIS posés par le client. Elle lit, elle ouvre des PR/MR, elle commente — sur les deux visages."
sidebar_label: "ADR-099 : la chaîne ne crée rien sur la forge (L5 phase 2)"
status: "Acté le 2026-09-12 (décision utilisateur « D10 profond »), prouvé hors ligne et par une matrice en direct sur le GitLab CE du lab. `test-forge-api.sh` 134/134, `test-archive-store.sh` 29/0, `test-setup-team-repos.sh` 11/11, `test-palier-retention.sh` 141/0, `test-team-apply-wiring.sh` 108/108, `test-forge-api-live.sh` 43/43 (les deux forges du lab) ; `test-producer-chain-gitlab.sh` **20/20 sur deux runs consécutifs du fichier commité `c88353d`, avec 8 preuves SKIP** pour une limite de lab NOMMÉE (le mock wM ne re-sérialise pas `apiDefinition`) — les quatre constats de Ruling 25 (0.4, 0.5, 2.1, 9.2 : aucun hook sur le dépôt plateforme, avant le semis comme après le teardown) sont PASS dans ces deux runs. Portes : `lint-forge-literals` 10/10 (`EN_ROUTAGE` VIDE — la phase 2 est close), `lint-branch-literals` 11/11, `lint-forge-knobs` 5 contrôles, `lint-config-knobs` verte."
maturite_technique: "✅ La moitié FORGE de la chaîne producteur est prouvée en direct sur un GitLab CE réel : MR ouverte par `team-request`, merge par l'API, apply sur le SHA mergé, `DEPOT_ABSENT` sur un dépôt non créé, squelette poussé dans un dépôt pré-créé VIDE, MR d'`api-request` sur le dépôt d'équipe, discriminant de visage à deux voies, sonde `ps -Aww` sans secret, porte « aucun hook sur le dépôt plateforme » tenue aux deux bouts de la fenêtre, teardown symétrique côté forge et Vault (les objets de gateway, eux, ne sont pas supprimables — le mock ne sert aucun DELETE). ⚠ La moitié GATEWAY (publication → export → promotion) n'est PAS prouvée en direct sous GitLab dans ce lot — elle l'est hors ligne et par l'historique Gitea ; cause exacte au § Limites. ⚠ La preuve « deux hooks + Secret Token + fusion réelle par builds Jenkins sous le visage gitlab » n'est pas faite non plus : la matrice joue les scripts en direct sur des projets pré-créés `--no-hook`."
date: 2026-09-12
adr_number: 99
note: "Lot L5 phase 2 du chantier forge-agnostique (après L1, L5 phase 1, L3, L2, L4, L6). Reprend ADR-082 §3 (la protection nominative de Gitea) et ADR-081 corollaire 3 (la décision humaine vit dans le merge sous protection) sans les réécrire. Décision utilisateur du 2026-09-12 : chez un client, créer un dépôt, un hook ou une protection n'est pas le métier de la chaîne."
lié: "[[adr-098-recepteur-de-webhooks-a-deux-visages]], [[adr-082-ouverture-palier-retention-credential]], [[adr-081-ou-vit-la-decision-humaine]], [[adr-076-gitops-api-lifecycle-repo-per-project]], [[adr-090-terminus-et-identite-de-forge]]"
---

# ADR-099 — La chaîne ne crée rien sur la forge : dépôts, webhooks et protection sont des prérequis (L5 phase 2)

## Contexte

`team-apply` **créait** ce sur quoi la chaîne allait ensuite travailler :
l'organisation, le dépôt d'équipe, son webhook vers `team-publish` et la
protection de sa branche par défaut — sept appels à l'API de Gitea, sous un
jeton `gitea-org-admin` lu dans Vault, distinct du secret de forge ordinaire.

Chez un client sur **GitLab**, chacun de ces quatre gestes meurt, et aucun
n'accuse sa vraie cause :

- créer un groupe ou un projet exige un PAT **Owner** — un droit que la chaîne
  n'a aucune raison de porter, et qu'un client n'a aucune raison de lui donner ;
- la protection de branche **nominative** (push whitelist, patterns de fichiers,
  ADR-082 §3) n'existe pas sur **GitLab CE** : elle est Premium. Le CE ne
  protège que **par rôle** ;
- le webhook n'a pas la même forme selon le récepteur du Jenkins (ADR-098) : une
  URL au token partagé sous `gwt`, une URL **par job** sous le GitLab Plugin ;
- et le jeton org-admin n'était mintable qu'à la main, par `docker exec` — une
  dette nommée depuis le palier 1.

La question n'est donc pas « comment créer sur les deux visages », mais **qui
crée**.

## Décision

**La chaîne LIT la forge, ouvre des PR/MR et commente. Elle ne crée ni
organisation, ni dépôt, ni webhook, ni protection de branche — sur AUCUN
visage.**

`team-apply` lit le dépôt d'équipe par l'autorité de forge (`forge repo_get`,
qui rend `EXISTS`, `EMPTY`, `DEFAULT_BRANCH`, `URL` sur les deux visages) et se
conduit selon **trois états**, plus une garde :

| État lu | Conduite | Sur la PR |
|---|---|---|
| `repo: ""` dans `providers.<env>.yml` | étape **sautée** — une équipe sans dépôt produit n'est pas un échec (cas réel `payments-team`) | « repo vide dans providers — étape sautée » |
| dépôt **absent** (`EXISTS=0`) | **`REFUS: DEPOT_ABSENT`**, rc 2, **rien n'est poussé** | le refus, nommé, sous le marqueur `<!-- team-apply -->` |
| dépôt **vide** (`EMPTY=1`) | squelette ADR-076 poussé sur la **HEAD annoncée par la forge** (`DEFAULT_BRANCH`), à défaut `GIT_BASE` : `clients/_example/` copié tel quel (`apis/`, `applications/`, **`environments.yaml`** — que `seed-governance-chain.sh` relit) plus un `README.md` **généré** | ✅ « vide, squelette poussé sur `<branche>` » |
| dépôt **non vide** | « déjà initialisé, étape sautée » — l'idempotence est **dite**, pas devinée | ✅, avec le lien du dépôt à la forme du visage |

Un **seul** commentaire par échec (`comment_upsert` sous le marqueur), jamais
une pile. Plus d'organisation créée, plus de hook posé, plus de protection
écrite, plus de `gitea-org-admin` dans Vault.

**Le client crée le dépôt VIDE, son ou ses webhooks et sa protection de
branche.** Au lab, ces trois gestes sont posés par un **outil de poste**,
`scripts/setup-team-repos.sh` — hors chaîne, exempté nommément par
`ci/lint-forge-literals.sh` (il parle aux API de création, ce que la chaîne n'a
plus le droit de faire).

### Les prérequis, à deux visages

Un dépôt d'équipe est prêt quand il porte les **trois** choses suivantes.

1. **Le dépôt, VIDE.** Gitea : l'organisation puis le dépôt. GitLab : le projet
   du groupe, **privé**, `merge_method=merge` (en fast-forward ou squash,
   `merge_commit_sha` est nul et l'apply post-merge n'a aucun SHA à checkouter).
2. **Le ou les webhooks vers les récepteurs.** Sous **`gwt`** : **un** hook, URL
   au token partagé. Sous **`gitlab`** : **DEUX** hooks —
   `/project/team-publish` et `/project/team-promote` —, événements
   « Merge request » **seulement**. Le GitLab Plugin expose une URL **par job**,
   donc il faut un hook par récepteur. C'est plus **serré** que le `gwt`, qui
   réveillait les deux jobs sur toute PR fusionnée et triait plus tard : un
   gain, **pas** une divergence entre visages.
   La valeur du champ *Secret token* du hook doit être **égale à celle que le
   JOB attend** (`TEAM_PUBLISH_WEBHOOK_SECRET`, `TEAM_PROMOTE_WEBHOOK_SECRET`,
   mêmes noms comme globales Jenkins ; défauts `stoa-team-publish` /
   `stoa-team-promote`, promote retombant sur publish puis sur son littéral ;
   **jamais** la chaîne vide). Ce n'est pas encore un secret — dette ADR-098. Le
   token **authentifie l'appelant**, il n'atteste **pas** le payload :
   l'intégrité reste la confrontation du dépôt réclamé à `providers.<env>.yml`
   (`REPO_AMBIGU`).
3. **La protection de la branche par défaut.** Gitea : **nominative**
   (`scripts/setup-repo-protections.sh`, ADR-082 §3). GitLab CE : **par RÔLE**,
   `push_access_level`/`merge_access_level` = 40. Corollaire opérationnel : le
   porteur de `FORGE_SECRET` doit donc être **Maintainer** sur le projet pour
   pouvoir y pousser le squelette.

Les quatre yeux d'ADR-081 restent portés par cette protection — posée par le
**client**, sous la forme que sa forge sait tenir.

### Le registre des archives suit la même règle : il est un prérequis, pas une création

Le registre générique n'a pas la même **échelle** selon le visage. Gitea :
par **PROPRIÉTAIRE** (`ARCHIVE_STORE_OWNER`, défaut `ci`). GitLab : par
**PROJET** — `ARCHIVE_STORE_PROJECT=<groupe>/<projet>` (au lab `ci/archives`,
créé par `setup-gitlab-lab.sh`), absent ⇒
**`REFUS: ARCHIVE_STORE_PROJECT_REQUIS`** avant tout appel réseau. `GIT_HOST`
y est requis, sans repli.

## Refus nommés

| Refus | Où | Quand |
|---|---|---|
| `DEPOT_ABSENT` | `team-apply.sh` §2, après `forge repo_get` | le dépôt d'équipe n'existe pas — **ou n'est pas visible pour ce jeton**. rc 2, rien de poussé, cause nommée sur la PR |
| `PROTECTION_GITEA_SEULEMENT` | `setup-repo-protections.sh`, avant tout réseau | l'outil d'exploitant Gitea est invoqué sous un autre visage : la protection nominative n'y existe pas, elle est un prérequis de forge |
| `ARCHIVE_STORE_PROJECT_REQUIS` | `scripts/lib/archive-store.sh` (`_as_url`), avant tout réseau | visage `gitlab` sans `ARCHIVE_STORE_PROJECT` : le registre générique de GitLab est par projet |
| `REPO_REQUIS` `REPO_INVALIDE` `BRANCHE_INVALIDE` `BRANCHE_PAR_DEFAUT_INDECIDABLE` `SECRET_FORGE_REQUIS` `FORGE_KIND_INCONNU` `ARGUMENT_INCONNU` `CREATION_ECHEC` `REPO_GET` `HOOK_ECHEC` `PROTECTION_ECHEC` | `setup-team-repos.sh` | l'outil de poste refuse par NOM plutôt que de créer à moitié ; `REPO_INVALIDE` est validé **avant** `--print` et avant tout réseau (le nom finit interpolé dans six corps JSON) |

`FORGE_KIND_REQUIS` **n'appartient pas à cet ADR** : c'est le refus de
l'**autorité de forge** (`forge_api_init`, et `_as_url` pour le transport
binaire des paquets), premier test avant tout réseau, sans défaut depuis le
2026-09-12. Voir ADR-098 et ENVIRONNEMENTS.md § « Le visage de la forge ».

## Conséquences

- **Un seul secret de forge pour toute la chaîne.** Plus de `gitea-org-admin`
  dans Vault, donc plus de second jeton à minter, à faire tourner et à
  révoquer ; la dette « `docker exec` est la seule voie pour le minter »
  disparaît avec lui.
- **Le droit demandé au client baisse d'un cran** : la chaîne n'a plus besoin
  d'Owner de groupe ni d'admin d'organisation. Elle a besoin de lire, de
  pousser sur un dépôt qu'on lui a ouvert, et d'ouvrir des MR.
- **Un refus de prérequis est lisible du demandeur** : `DEPOT_ABSENT` arrive sur
  **sa** PR, avec le geste à faire, et le merge se rejoue tel quel une fois le
  dépôt créé. Rien n'est à moitié appliqué entre-temps.
- `setup-repo-protections.sh` reste un outil d'**exploitant Gitea** ; il refuse
  ailleurs plutôt que de poser une protection dégradée qui aurait l'air posée.
- La liste `EN_ROUTAGE` de `ci/lint-forge-literals.sh` est désormais **VIDE** :
  la chaîne producteur entière (`team-request`, `team-apply`, `team-publish`,
  `team-promote`, `api-request`, `api-promote-export`, `api-promote-request`)
  passe par l'autorité de forge. La porte le dit en toutes lettres — « aucun
  fichier en routage : la phase 2 est close ».

## Limites

- **Sur GitLab, un 404 vaut aussi « invisible pour ce jeton ».** Le refus
  `DEPOT_ABSENT` le dit lui-même : il ne peut pas distinguer « ce projet
  n'existe pas » de « ce projet existe et ce PAT ne le voit pas ».
- **`team-apply` ne vérifie PAS la présence du webhook.** Lister les hooks d'un
  projet exige Maintainer, droit que le porteur du secret n'a pas partout : le
  webhook est un prérequis **écrit**, pas **contrôlé**. Conséquence à connaître,
  et elle est **muette côté Jenkins** : un hook absent, ou un *Secret token* qui
  diverge de celui du job, ne produit **aucun build et aucun log** — le
  diagnostic se lit dans l'historique de livraison du hook côté forge (401),
  jamais dans Jenkins.
- **La moitié GATEWAY de la chaîne producteur n'est pas prouvée en direct sur
  GitLab dans ce lot.** `test-producer-chain-gitlab.sh` marque 8 preuves SKIP —
  publication (2), export (3), promotion (3) — pour une **limite du lab**
  nommée et mesurée : le mock webMethods ne re-sérialise pas `apiDefinition`
  (`mocks/webmethods/store.go`, champ `Definition` en `json:"-"`), donc la
  relecture **fail-closed** du tag de posture (P3, ADR-093,
  `ansible/roles/apim_publish_api/tasks/tag.yml`) lit `tags=[]` et refuse
  `TAG_UNCONFIRMED`. La publication s'arrête **avant** l'activation ; sans API
  active, `api-promote-export` refuse `EXPORT_REFUSED` (piège `isActive`,
  ADR-079) et la promotion refuse `DIGEST_ABSENT`. Ce qui est **quand même**
  établi : l'API **est** créée sur la gateway (n=1) — tout ce qui précède la
  relecture a fonctionné, registre central de gouvernance et résolution de
  posture compris. Le tag lui-même est prouvé au jalon P3 contre la **10.15
  RÉELLE**. Cette moitié-là est prouvée **hors ligne** et par l'historique
  Gitea, pas en direct sur GitLab.
- **La preuve « deux hooks + Secret Token + fusion réelle par builds Jenkins
  sous le visage `gitlab` » n'est pas faite.** La matrice joue les scripts **en
  direct**, sur des projets pré-créés avec `--no-hook` : rien dans ce lot ne
  démontre que les récepteurs GitLab de `team-publish` et `team-promote` se
  déclenchent réellement. C'est le lot voisin (ADR-098).
- **Les défauts de visage qui subsistent sont tous APRÈS un `forge_api_init`
  réussi, ou dans un outil de poste.** L'inventaire refait en revue finale
  (2026-09-12) corrige la phrase d'origine, qui disait `_forge_auth_mode` « le
  dernier » : il y en a trois, plus deux outils exemptés.
  `_forge_auth_mode` (`scripts/lib/forge-identity.sh`, `${FORGE_KIND:-gitea}`
  pour dériver l'en-tête), `forge_web_file_url` (`scripts/lib/forge-api.sh`) et
  `kind()` de `scripts/lib/forge-api.py` (`or "gitea"`) — les deux derniers ne
  sont atteints qu'**après** un init réussi, donc après que
  `FORGE_KIND_REQUIS` aurait refusé. Les deux outils exempts (Ruling 22) gardent
  le leur et échouent **bruyamment** devant un terminal. Aucun n'est atteignable
  depuis la chaîne routée ; tous sont datés.
- **Le refus arrive APRÈS la pause nominative, deuxième instance.** Sur
  `ci/Jenkinsfile.team-publish`, le `when` passe sur `api/*`, l'`input`
  nominatif s'ouvre, l'humain saisit son mot de passe d'annuaire — et
  `REPO_NON_DECLARE` (`scripts/team-publish.sh:285`) ne refuse **qu'ensuite**.
  Même dette que `team-apply`, déjà nommée dans ADR-098 § Dettes ; même geste
  connu (un stage `agent any` de réconciliation dépôt → équipe **avant**
  l'`input`, motif de `provision-apply`), non fait ici, à arbitrer avec
  l'utilisateur puisqu'il touche le récepteur et le corps du job.

## Preuves

| Preuve | Commande | Résultat |
|---|---|---|
| Les verbes de forge, deux visages, mutations champ par champ | `bash scripts/test-forge-api.sh` | **134/134** (2026-09-12) |
| Les mêmes verbes contre les forges RÉELLES du lab (`repo_get`, `raw` sans ref, URL absolue) | `bash scripts/test-forge-api-live.sh` | **43/43**, GitLab CE **et** Gitea |
| Le registre des archives à deux échelles (par propriétaire / par projet), `ARCHIVE_STORE_PROJECT_REQUIS` | `bash scripts/test-archive-store.sh` | **29 PASS / 0** |
| **Le registre générique GitLab, EN DIRECT** (au niveau de la lib) | `archive_store_push` / `archive_store_fetch` contre `ci/archives` (GitLab 17.11), Task 13 | push, rejeu **no-op nommé** (mêmes octets), `fetch` **octets identiques** (`cmp`), et les **deux** refus joués (`ARCHIVE_STORE_PROJECT_REQUIS`, `FORGE_KIND_REQUIS`) |
| L'outil de poste : deux visages, refus nommés, aucune branche inventée | `bash scripts/test-setup-team-repos.sh` | **11/11** |
| La conduite D10 de `team-apply` (⑭), les mutants, les knobs de site | `bash scripts/test-palier-retention.sh` | **141 PASS / 0** |
| Le câblage de `team-apply` (XML vide, récepteur, chaîne d'identité) | `bash scripts/test-team-apply-wiring.sh` | **108/108** |
| Le trois-états en direct sur Gitea | `bash scripts/test-team-onboarding-chain.sh` (5 / 5bis / 6) | dépôt pré-créé, `DEPOT_ABSENT`, squelette poussé |
| **La chaîne PRODUCTEUR en direct sur le GitLab CE du lab** | `bash scripts/test-producer-chain-gitlab.sh` | **20/20 sur deux runs consécutifs** du fichier commité `c88353d`, `rc 0`, **8 preuves SKIP** avec leur cause (limite du lab, § Limites) ; les quatre constats de hooks de Ruling 25 sont PASS |
| Porte : une seule autorité de forge, `EN_ROUTAGE` VIDE | `bash ci/lint-forge-literals.sh` | **10/10** — « D.1 aucun fichier en routage : la phase 2 est close » |
| Porte : aucune branche écrite en dur | `bash ci/lint-branch-literals.sh` | **11/11** |
| Porte : tout Jenkinsfile qui invoque un script routé porte les trois knobs | `bash ci/lint-forge-knobs.sh` | **5 contrôles**, verte |
| Porte : aucun défaut de site hors de la dette déclarée | `bash ci/lint-config-knobs.sh` | verte (535 défauts examinés, 186 exemptés) |

Ce que la matrice GitLab établit, preuve par preuve : le dépôt plateforme est
**privé** (`info/refs` anonyme ⇒ 401 — le vrai cas client) ; `team-request`
ouvre une MR et y commente son plan ; `team-apply` refuse `DEPOT_ABSENT` sur un
dépôt non créé, avec un 404 exact derrière ; le même `team-apply` pousse le
squelette dans un projet pré-créé **VIDE** ; `api-request` ouvre une MR sur le
dépôt d'**équipe** et y commente ; le **discriminant** de visage
(`FORGE_KIND=gitea` contre ce GitLab) refuse par nom sur les deux voies — en
lecture (« la forge REDIRIGE vers …/users/sign_in ») comme en écriture (le
chemin `/api/v1` cité), et n'ouvre **aucune** MR ; un sondage `ps -Aww` sur
toute la fenêtre ne voit **aucun** secret en argv, contrôle positif tenu
(trafic réellement observé) ; et le teardown est **symétrique côté forge et
côté Vault** (404 exacts sur les projets du run, branches retirées, aucun
paquet au registre, KV et policies de l'équipe en 404, tokens éphémères
révoqués, bascule de gateway rendue).

⚠ **La réserve du teardown, telle que la suite l'imprime** : les objets de
**gateway** ne sont **PAS** supprimés. Le mock webMethods n'expose aucune route
`DELETE` (**405**, mesuré au palier 3) et son état est en mémoire — **une API
`demo-l5gl*` reste donc par run**. Le nettoyage est complet sur la forge et sur
Vault, pas sur la gateway, et la preuve 9.1 le dit elle-même.

Le **registre générique de GitLab** a, lui, une preuve **verte en direct** — mais
**au niveau de la lib**, pas de la chaîne : `archive_store_push` /
`archive_store_fetch` de l'arbre contre le vrai `ci/archives` (GitLab 17.11,
Task 13). Le paquet est retrouvé dans le registre du projet, le rejeu du même
contenu est un **no-op nommé**, le `fetch` rend des octets **identiques**
(`cmp`), et les deux refus tombent (`ARCHIVE_STORE_PROJECT_REQUIS`,
`FORGE_KIND_REQUIS`). Ce qui reste **SKIP** — la preuve 5.1 de la matrice — est
le push d'archive **depuis la CHAÎNE** (`api-promote-export` sous GitLab), qui
dépend de la publication, donc de la limite du mock ci-dessus. La lib est
prouvée contre le vrai registre ; le maillon qui l'appelle ne l'est pas encore.
