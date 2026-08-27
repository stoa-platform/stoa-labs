# HANDOFF — G4 : la rétention de credential par palier

**Session du 2026-08-26.** Branche `provision/probe-dev`, **19 commits** de G4 (dont ce
handoff). **Rien n'est poussé :** `origin` est resté au handoff G3 (`3b3a1ba`) — la branche est
**18 commits devant** — et `gitea` n'a rien reçu (lignée disjointe, jamais poussée). Voir les
points ouverts : sans la poussée sur `gitea`, aucun job du lab ne voit G4. Arbre propre.

| Porte | Nature | Résultat |
|---|---|---|
| `scripts/test-palier-retention.sh` *(nouvelle)* | hors-ligne, chaque garde MUTÉE, branchée `make lint-ci` | **126 / 0** |
| `scripts/test-palier-retention-live.sh` *(nouvelle)* | live Vault : matrice 403 par palier + F4-canari | **24 / 24** |
| `scripts/test-repo-protections-live.sh` *(nouvelle)* | live Gitea : mesure `protected_file_patterns` + porte push/merge | **13 / 13** |
| `make lint-ci` | 11 Jenkinsfile compilés + shellcheck + épreuves | vert `[1/5]`→`[5/5]`, `rc=0` |
| `scripts/test-deploy-pin.sh` (⑳ retournée) | hors-ligne, asserte le scellement | **79 / 0** |
| `scripts/test-team-publish-wiring.sh` | wiring, EXPECTED_CHECKS mis à jour | **116 / 116** |
| `scripts/test-team-request-wiring.sh` | wiring | **65 / 65** |
| `scripts/test-team-apply-wiring.sh` | wiring | **72 / 72** |
| `scripts/test-api-request-wiring.sh` | wiring | **52 / 52** |

---

## À LIRE EN PREMIER — ce qui a été arbitré, et ce que ça te coûte

**Le verrou dev-only ne se « lève » pas. Il se SCELLE.**

Le GOAL disait « lever le verrou et le remplacer par un contrôle qui ne se lève pas lui-même ».
La tentation était de garder un axe env sur les chemins d'authoring, gardé à l'exécution par la
possession d'un credential — l'*ouverture paramétrique*. Elle a été **rejetée** : elle conserve
un axe surchargeable dont AUCUN consommateur n'existe (pas de `providers.rec.yml`, pas d'équipe
non-dev), et elle ressuscite exactement la surface de défaut que l'arbitrage G3 venait de fermer.

**Arbitré (D1) : scellement.** L'axe env **disparaît** des chemins d'authoring — il devient une
constante de bibliothèque non surchargeable (`DEPLOY_PIN_AUTHORING_ENV`). `ENV_NOT_OPEN` ne
disparaît pas parce qu'on l'a retiré : il disparaît **par construction**, il n'y a plus de choix
d'env à refuser. Le seul endroit où un palier existe encore est la chaîne de promotion, et là,
l'autorité n'est plus un `if` mais **un AppRole `apply-<env>` et une protection de branche
Gitea** — deux choses qu'un pipeline compromis ne se donne pas à lui-même.

### Ce que ça te coûte, et il faut le savoir avant de le découvrir

**L'onboarding d'équipe à un palier supérieur n'est plus exprimable par le self-service.** Le
formulaire `team-request` ne porte plus de paramètre `REQ_ENV` ; `team-apply` refuse
`ENV_MISMATCH` si le suffixe de branche diffère de `dev`. Si un client exige un jour la
**tenancy déclarée par palier** (créer une équipe directement en rec), ce n'est pas ce
formulaire qui la lui donnera. **Clause de réouverture, assumée :** cette tenancy passera par le
**chemin de promotion** (G5), pas par la réouverture du formulaire d'onboarding. C'est le prix
du scellement : on a fermé un axe plutôt que de le garder ouvert-mais-gardé.

### Ce que ça te rend

« Ouvrir rec » devient un **geste de credential**, hors pipeline : `setup-vault-paliers.sh
--mint apply-rec` (le poseur ne minte JAMAIS par défaut) puis un grant nominatif Vault. L'état
par défaut est « tout fermé ». Et G5 devient un **pur câblage** : les policies et AppRoles
`apply-<env>` existent déjà, non mintés — brancher le verbe archive consomme un credential déjà
posé, et l'épreuve live prouve dès aujourd'hui que le 403 inter-palier tient.

---

## Ce qui est livré

Trois mécanismes, aucun `if` de plus. Le détail vit dans **ADR-082** ; l'essentiel :

1. **Scellement de l'axe env (D1/D4/D5/D6).** `team-request`, `team-apply`, `team-publish`,
   `api-request`, `setup-team-onboard-jobs` lisent la constante de lib. Le paramètre `REQ_ENV`
   quitte le formulaire **et** son `job.xml` (le XML gagne — les deux bougent). La voie
   consommateur (`provision-request`/`provision-plan`) garde son axe env, mais sa liste est
   **dérivée d'`env_chain_nonprod`** (homol entre, terminus sort), plus une constante stale.
2. **Plan de credential par palier (D2/D3).** `scripts/setup-vault-paliers.sh` pose, par palier
   non terminal, une policy `apply-<env>` (read du seul `envs/<env>/wm-admin`) + un AppRole
   `apply-<env>` **jamais minté par défaut**. Le terminus ne reçoit rien — structurel. Le write
   tenant est resserré à `apps/+/<env>/*` par palier, dans `apim_team_onboard` **et**
   `setup-user-vault-jwt.sh`.
3. **Protections de branche Gitea (D7/D8).** `scripts/lib/repo-protection.sh` +
   `scripts/setup-repo-protections.sh` posent « main sans push direct, whitelist `ci`, tout par
   PR » sur `ci/stoa-labs`, `ci/governance` et les dépôts d'équipe ; `team-apply.sh` la pose **à
   la création** (après le push du squelette). Le job selfservice ride `main` (D8, trou M2
   fermé).

**G4 s'appuie sur le marqueur repo-par-projet** (ADR-076, divergence §1 amendée en G3) — non
re-tranché ici.

---

## Ce que G4 ne prouve PAS, et c'est voulu

- **Aucun apply réel à un palier supérieur.** Le verbe de promotion est **G5**. G4 prouve la
  rétention — le refus fermé — pas la promotion, l'acte.
- **La parité des deux moteurs** (`apim_promote_api` / `labctl promote`) est **G8**.
- **`DeployerGroup` — « qui déclenche »** — est **G2**. La porte G4 prouve que le demandeur ne
  peut pas ALTÉRER la chaîne ; pas encore que seul le groupe déployeur peut la DÉCLENCHER.
- **Le config.xml Jenkins gagne sur le Jenkinsfile** (fait 9c). Frontière = admin Jenkins, hors
  Git. Nommé, non résolu par G4 — geste de déploiement à ne pas oublier (re-poser le job).

> Un point de la spec §6.1 est désormais **FERMÉ** : « la sémantique `protected_file_patterns`
> n'est pas supposée tant que la mesure live n'a pas tourné ». Elle a tourné (voir ci-dessous),
> le poseur peut encoder ce qui est mesuré vrai.

---

## Les trois mesures live qui gouvernent l'exploitation (T9)

Mesurées sur le lab, elles font autorité — la doc n'y accédait pas avant :

1. **`protected_file_patterns` (Gitea 1.22) est un gate de CONTENU indépendant du rôle.** Il
   bloque le push direct **et** le merge d'une PR qui touche un fichier protégé (405), **l'admin
   de site compris**. C'est ce qui rend réelle la protection des `scripts/**`/`ansible/**`/`ci/**`.
2. **Le PATCH `branch_protection` de 1.22 FUSIONNE** (champ absent = préservé). Re-passer la
   baseline est **non destructif** — pas de GET-merge-PATCH requis.
3. **L'admin de site N'EST PAS exempté du `push_whitelist`.** Le défaut
   `PROTECT_PUSH_WHITELIST=ci` est **portant** et **doit rester aligné sur `GITEA_ADMIN_USER`** :
   sinon le chemin de réparation de `team-apply` (push du squelette sous l'admin avant de
   protéger) casse.

---

## Points ouverts, par ordre de ce que je ferais

1. **Pousser sur `gitea`** — `git push gitea provision/probe-dev`. **BLOQUÉ par le classifieur**
   pour le contrôleur ; à lancer par l'exploitant en `! bash`. `gitea` est **ce que lit le CI du
   lab**, sa lignée n'a pas d'ancêtre commun avec GitHub : tant qu'il n'a rien, **aucun job du
   lab ne voit G4**. Si le lot passe le mégaoctet, `http.postBuffer` est requis sur ce remote.
   (Accessoirement, `origin` non plus n'a G4 — la branche est 18 commits devant ; à pousser si
   l'on veut GitHub à jour.)
2. **Poser les deux gestes de G1 restés en attente** (bloqués classifieur, `! bash`), dans cet
   ordre : `bash scripts/setup-release-team.sh` puis
   `GITEA_TOKEN=<write:repository> bash scripts/seed-governance-chain.sh`. Sans le groupe
   `release-team`, une promotion vers prod est inapprouvable — fail-closed, mais bloquant. G4
   n'en dépend pas.
3. **Brief G5.** Trois choses à emporter :
   - **`PIN_NON_RESOLU` atteint désormais la PR** (G3 point ouvert #4 : fermé par D9 — `team-publish`
     capture le stderr du résolveur dans un fichier et le dernier refus `deploy-pin:` rejoint le
     commentaire de PR). C'était la surface de diagnostic manquante ; elle existe.
   - **Le verbe archive est à brancher** sur les sauts rec et au-delà (les deux moteurs) — G5
     consomme les AppRoles `apply-<env>` déjà posés.
   - **`apim_ss_authoring_env` est à SCELLER quand G5 câble le déclenchement par un tiers**
     (`ansible/roles/apim_promote_api/defaults/main.yml:106-110`). Tant que l'opérateur lance le
     play lui-même (D0/D2), le default surchargeable tient ; le jour où un job/webhook/API le
     déclenche, il doit suivre la discipline CI. **C'est mon arbitrage repris de G3, pas un
     consensus.**
4. **Re-poser les jobs Jenkins** après tout changement de listes (choices/triggers/paramètres) :
   **le config.xml gagne sur le Jenkinsfile.** Un scellement présent dans le Jenkinsfile mais
   absent du config.xml posé ne prend pas effet.
5. **Dette de porte Makefile** (préexistante à G4, à trancher en revue finale) : le commentaire
   de la liste shellcheck dit « tout le shell qui part chez le client », mais la liste réelle
   n'énumère que quelques scripts — des dizaines de livrables shell en sont absents. Par ailleurs
   les harnais `test-*.sh` sont **exécutés** pour leur protocole, jamais shellcheckés
   (`test-palier-retention.sh` compris) — précédent `test-deploy-pin`, endossé en revue.

---

## Deux morts de session, dites plutôt que masquées

- **`impl-t9` (opus) est mort sur limite de session à 03:35**, en cours de T9. L'état du lab a
  été **vérifié propre par le contrôleur** avant re-dispatch : aucun artefact Gitea jetable
  (g4-proof/probe/user = 404), 4 policies + AppRoles `apply-*` présentes et complètes (aucune
  révocation orpheline), canari absent/port libre, aucune probe secret résiduelle. Le script
  `test-palier-retention-live.sh` était déjà écrit et valide. **Repris par `impl-t9b`** (opus),
  qui a terminé (`fef3602`, Vault 24/24, Gitea 13/13), lab re-vérifié pristine.
- Le ledger ne consigne explicitement **qu'une** mort de session (impl-t9). Si une seconde a été
  observée côté team-lead, elle n'a pas laissé de trace dans le ledger que je reprends.

## Six défauts de PLAN trouvés par les implémenteurs (addenda du ledger)

Le plan n'était pas sans trous ; chacun a été trouvé par un implémenteur ou un reviewer, et
corrigé dans sa tâche :

1. **(impl-t2)** le `lookup('pipe')` d'`onboard-team.yml` écrit au plan était cassé à tous les
   coups — le cwd du pipe est `ansible/`, pas la racine ; corrigé par ancrage `playbook_dir` +
   `|quote`, prouvé 3 cas (livrée/jetable/illisible→fatal).
2. **(rev-t3)** le bloc ⑨a du plan pour les Jenkinsfiles était une assertion d'**absence** sans
   garde d'existence ni mutation — vacance démontrée (sed sur fichier absent → fichier vide →
   vert). Troisième morsure du même piège ce jalon.
3. **(impl-t5)** le `if !` du Step 3 cassait l'ancre `^resolve_deploy_pin` de l'épreuve d'appel
   G3 — l'appel a été gardé en tête de ligne (forme `|| { … }`), même comportement.
4. **(impl-t6)** le détecteur `git push` du brief était **vacant** — la forme réelle est
   `git -C "$SK" push -q`.
5. **(impl-t6)** le point d'insertion du brief sourçait la lib **APRÈS** `git checkout
   "$MERGE_SHA"` — le poseur aurait tourné tel que le SHA du **demandeur** le porte (une PR
   d'onboarding touchant `scripts/lib/` se posait ses propres protections) ; lib sourcée **en
   tête**, avant le checkout.
6. **(impl-t7)** le plan ne scopait que le **texte descriptif** d'`app-request.job.xml:48` — la
   `<choices>` réelle du formulaire gardait `prod` (et le XML gagne) ; alignée sur la chaîne.

**Leçon transverse (3e occurrence ce jalon) :** une assertion de PRÉSENCE sur un fichier brut
commenté dans la même langue est **vacante par nature** — n'asserter que sur code décommenté
(`sed 's/[[:space:]]*#.*$//'`) ou sur octets (`cmp`). Réflexe : pour toute garde, **retirer la
garde et exiger le rouge** ; ancrer les `grep` sur le code décommenté ; capturer dans un fichier
puis grepper (jamais un pipe sous `pipefail`).

---

## Où lire le détail

- **ADR** : `adr/adr-082-ouverture-palier-retention-credential.md` — la décision, les mesures
  live, les parkings avec clause de réouverture.
- **Spécification** : `docs/superpowers/specs/2026-08-26-g4-retention-credential-par-palier-design.md`
  (§2 décisions D1-D9, §6.1 ce que G4 ne prouve pas, §8 parkings).
- **Plan** : `docs/superpowers/plans/2026-08-26-g4-retention-credential-par-palier.md`.
- **Ledger** — toutes les revues, tous les correctifs, les rulings, et les addenda listant les
  défauts du plan : `.superpowers/sdd/2026-08-26-g4-retention-credential-par-palier/progress.md`.
- **GOAL** : `GOAL-cd-promotion-5-envs-2026-08-26.md` — G4 est fait ; restent G2, G5, G6, G7, G8.
- **Ouvrir un palier, geste par geste** : `ENVIRONNEMENTS.md`, section « Ouvrir un palier (G4) ».
