---
title: "ADR-083 — Le verbe archive et son transport — deux moteurs, un manifeste. Le seul verbe de déploiement au-delà de l'authoring est l'IMPORT D'ARCHIVE à GUID stable (jamais un re-POST) ; son transport est un registre adressé par le contenu (la version EST le sha256) ; et les deux moteurs qui le jouent — le rôle Ansible client et labctl — partagent un manifeste unique, un ordre de gardes ANTÉRIEUR au play, et la rétention de credential par palier posée en G4."
sidebar_label: "ADR-083 : le verbe archive, deux moteurs"
status: "Acté pour le MÉCANISME, prouvé par les portes. Porte du GOAL VERTE : 54/54 par chacun des deux moteurs contre le wM réel (scripts/test-promote-verb-live.sh — GUID iso, 0-coupure 3550/3550 et 4074/4074 requêtes 200 pendant l'import, UPDATE_FORBIDDEN rejouée live ET unitaire). Fidélité du mock 22/22 contre le mock ET contre le wM réel teamWork actif (scripts/test-archive-promotion.sh). Câblage hors-ligne 90/0 (scripts/test-team-promote-wiring.sh), branché make lint-ci [7/8]. Reste des DÉCISIONS CLIENT et des limites nommées : la politique d'attribution des grants par palier (ADR-082, décision n°2), la parité des deux moteurs (G8), le client OAuth partagé hors-prod, la conversion du pipeline governance."
maturite_technique: "✅ Mécanisme prouvé en live par les DEUX moteurs avec les MÊMES assertions — un moteur qui verdirait seul ne serait pas une porte, ce serait une préférence (test-promote-verb-live.sh). L'ordre des gardes (toutes antérieures au moteur) est prouvé par MUTATION, garde par garde ET par mutation d'ordre, pas seulement par lecture du script. Ce qui reste non fermé : le contrôle à quatre yeux est INERTE sur la chaîne CI tant que le plugin Jenkins build-user-vars n'est pas provisionné (aucun faux refus — le merger reste un humain réconcilié, mais le demandeur comparé vaut toujours 'ci')."
date: 2026-08-27
adr_number: 83
note: "Consomme ADR-079 (le verbe est l'import d'archive, jamais le re-POST) et ADR-082 (la rétention de credential par palier — G5 en est le premier consommateur réel : les policies/AppRoles posés par G4 sans consommateur immédiat sont maintenant lus par team-promote.sh). Précise ADR-081 (l'autorité est le merge sous protection de branche) pour la chaîne de promotion spécifiquement. Ouvre G8 (parité des deux moteurs) et nomme la tension avec le GOAL sur le pipeline governance (parking)."
lié: "[[adr-079-deploiement-promotion-multienv-import-archive]], [[adr-082-ouverture-palier-retention-credential]], [[adr-081-ou-vit-la-decision-humaine]], [[adr-076-gitops-api-lifecycle-repo-per-project]], [[adr-074-vault-secrets]]"
---

# ADR-083 — Le verbe archive et son transport — deux moteurs, un manifeste

**Statut :** Acté pour le mécanisme, prouvé par les portes. La porte du GOAL est VERTE par les deux moteurs. La politique d'attribution des grants par palier et la parité fine des deux moteurs restent des décisions/jalons ultérieurs.

**Maturité technique :** ✅ Mécanisme prouvé en live, deux moteurs, mêmes assertions. Limite nommée et non réparable ici : le 4-yeux de la chaîne de promotion est inerte tant qu'un plugin Jenkins manque (voir §4).

**Lié à :** [[adr-079-deploiement-promotion-multienv-import-archive]], [[adr-082-ouverture-palier-retention-credential]], [[adr-081-ou-vit-la-decision-humaine]], [[adr-076-gitops-api-lifecycle-repo-per-project]], [[adr-074-vault-secrets]].

---

## Contexte

ADR-079 avait tranché le VERBE de déploiement au-delà de l'authoring — l'import d'archive à GUID stable, jamais un re-POST du contrat — et ADR-082 (G4) avait posé la RÉTENTION : une policy et un AppRole `apply-<env>` par palier non terminal, jamais mintés par défaut. Au relevé du 2026-08-27 (jalon G5), quatre pièces existaient sans être reliées : le rôle Ansible `apim_promote_api` (livré, prouvé E2E, mais **appelé par rien**), `labctl promote` (écrit, **jamais exécuté contre une gateway**), le formulaire `api-promote-request.sh` (ouvre la PR `promote/<api>-<env>`, mais **le merge ne déclenche rien** — `team-publish.sh:142` filtre `api/*` et sort sur toute autre branche), et le credential de palier (posé, **sans consommateur**). Le transport des octets d'un palier à l'autre n'existait tout simplement pas — G3 l'avait nommé explicitement comme trou laissé à G5.

Trois formes de transport ont été considérées pour porter l'archive entre l'export en authoring et l'import sur le palier cible :

- **Git lui-même** (l'archive commitée dans le dépôt d'équipe ou plateforme) — rejetée : un artefact de build binaire dans l'historique Git est le point de friction qu'ADR-079 §C3 nommait déjà (« un artefact de build tagué, PAS Git ») ;
- **un stockage d'objets externe** (S3, un registre OCI dédié) — rejetée pour ce jalon : un composant de plus à opérer et sécuriser, sans que rien dans le lab ne le porte déjà ;
- **le registre de packages génériques de Gitea**, adressé par le contenu — retenue : Gitea 1.22.6 (mesuré sur le lab) l'expose nativement (`PUT/GET /api/packages/{owner}/generic/{name}/{version}/{file}`), refuse le doublon, et c'est déjà l'identité que la chaîne authentifie pour tout le reste (PR, protections de branche).

## Décision

**Le verbe reste l'import d'archive (ADR-079), son transport est le registre de packages génériques Gitea adressé par le contenu, et deux moteurs — le rôle Ansible client et `labctl` — le jouent contre le même manifeste, derrière le même ordre de gardes.**

### 1. Le transport : un registre adressé par le contenu, jamais par une révision Git

`scripts/lib/archive-store.sh` expose deux fonctions, `archive_store_push` et `archive_store_fetch`. Le `owner` est l'organisation du dépôt plateforme (`ci`), le package `promote--<team>--<api>`, et **la version est le sha256 complet de l'archive sanitisée** — le marqueur de déploiement (ADR-079/G3) porte déjà `archive_sha256`, l'URL de téléchargement s'en dérive sans champ nouveau. La poussée est idempotente (digest déjà présent ⇒ succès sans nouveau PUT) ; le téléchargement est re-haché et confronté au digest attendu, fail-closed. Tout refus est nommé sous le préfixe `STORE_` (`STORE_TOKEN_ABSENT`, `STORE_PARAM_INVALIDE`, `STORE_DIGEST_INCALCULABLE`, `STORE_CONFLIT_CONTENU`, `STORE_HTTP_<code>`, `STORE_DIGEST_MISMATCH`, `STORE_DEST_INECRIVABLE`, `STORE_TMP_INCREABLE`) — un code HTTP numérique fait partie du jeton (`STORE_HTTP_404` distingue « jamais poussée » de « registre en panne »), pas d'une classe qui le tronquerait. Le token Gitea transite par un fichier d'en-tête éphémère, jamais en argv ni en URL.

### 2. Le geste d'export est un job de formulaire, séparé du geste de demande

`scripts/api-promote-export.sh` (via `ci/Jenkinsfile.api-promote-export`) clone le dépôt d'équipe à `main`, lit `apis/<api>.promote.yml`, joue le rôle `apim_promote_api` en `action=export` contre la gateway d'authoring, pousse l'archive au registre et imprime `EXPORT_CONFIRMED_SUMMARY` (guid, sha256, package). Ce job **n'écrit aucun marqueur et ne publie rien** : il matérialise des octets qu'une promotion ultérieure épinglera. Le pinning du guid dans `promote.yml` reste un geste Git de l'équipe (une PR) — documenté, non automatisé (parking §5). Sans guid pinné, l'import se refuse par une garde déjà existante (`PIN_ABSENT`/`IMPORT_REFUSED`) : fail-closed, pas un trou.

Exiger une identité nominative pour ce job n'est pas un excès de prudence : `scripts/api-promote-export.sh` documente noir sur blanc que le user/password Vault posés au login sont les **creds réellement utilisées par le moteur** pour authentifier l'export contre la gateway — pas de simples jetons de preuve.

### 3. Le consommateur du merge est un job dédié, déclenché par le webhook existant

`ci/Jenkinsfile.team-promote` reprend le même token de déclenchement que `team-publish` (`stoa-team-publish` — le plugin Generic Webhook Trigger réveille tous les jobs enregistrés sur un token donné) et filtre `promote/*` là où `team-publish` filtre `api/*`. Aucun geste sur les dépôts d'équipe existants : leur webhook suffit déjà. Le job pose une pause nominative (mêmes `V_USER`/`V_PASS` que `team-publish`), puis délègue toute la substance à `scripts/team-promote.sh`.

### 4. L'ordre des gardes est une ÉPREUVE, pas une convention de lecture

`scripts/team-promote.sh` impose neuf étapes, **toutes mécaniquement antérieures au moteur** : validation de forme des variables webhook et des knobs de pipeline → filtre `promote/<api>-<env>` (l'env doit être un palier de la chaîne, jamais l'authoring) → réconciliation avec Gitea (l'état de la PR **et** les deux identités — mergeur et demandeur — sont relus dans la même réponse authentifiée, jamais le payload du webhook) → anti-TOCTOU (`merge-base --is-ancestor` sur le SHA du merge) → fetch de l'archive par le digest pré-lu dans le marqueur, puis résolveur complet (`resolve_deploy_pin`, pin/ancêtreté/version/digest) → relecture des exigences de la porte sur le marqueur MERGÉ (`change_ref`/`pv_ref`) → garde d'identité (le mergeur réconcilié comparé au `promoted_by` du marqueur, 4-yeux conditionnel à la porte) → lecture du secret de palier `envs/<env>/wm-admin` (le ticket d'entrée de la rétention G4) → **un seul site d'appel moteur**, `run_engine()`, tout en bas.

Cet ordre n'est pas un choix de mise en page : `scripts/test-team-promote-wiring.sh` le prouve par MUTATION — pour chaque garde (forme, réconciliation, branche, ancêtreté, archive absente ou digest faux, pin, références de porte manquantes, identité, palier fermé), un refus nommé se produit et **le fichier d'enregistrement du stub moteur n'existe pas**. Et la contre-épreuve porte aussi sur l'ordre lui-même : un script muté qui inverserait l'appel du moteur et la garde `PALIER_FERME` doit rougir pour la BONNE raison (une garde franchie trop tard), pas simplement rougir. 90 verdicts rendus (89 assertions + le garde-fou de compte), 0 échec.

### 5. Deux moteurs, un manifeste, un knob hors du périmètre du demandeur

`PROMOTE_ENGINE` ∈ {`ansible` (défaut, chemin client), `labctl`} et `ADMIN_VIA` ∈ {`proxy-oauth2` (lab), `direct` (client)} vivent dans le bloc `environment{}` de `ci/Jenkinsfile.team-promote` — une définition de pipeline protégée par Gitea (ADR-082 D7) — **jamais un paramètre de build**. Chemin `ansible` : `ansible-playbook ansible/promote-api.yml` avec l'env d'authoring scellé passé en extra-var sèche (`apim_ss_authoring_env="$ENVN_AUTH"`, jamais un `${ENVN_AUTH:-dev}` surchargeable). Chemin `labctl` : `labctl promote --manifest --env --action import` contre un `targets.yaml` généré à la volée, pointant le proxy d'admin via `bearerTokenFile` — le secret OAuth n'est jamais matérialisé en argv, un fichier 0600 porte le bearer.

La combinaison `labctl` + `ADMIN_VIA=direct` **n'existe pas et se refuse nommément** (`COMBINAISON_NON_SUPPORTEE`) : en `direct`, l'admin s'authentifie en Basic avec les creds `wm-admin` du palier ; le rôle Ansible sait les lire depuis Vault sans jamais les matérialiser, mais `labctl` ne consomme qu'un fichier de bearer ou un couple identifiant/mot de passe écrit sur disque. Refuser la combinaison coûte moins cher qu'écrire un secret sur disque pour la permettre.

### 6. La rétention de credential par palier, G4 en action

La lecture de `envs/<env>/wm-admin` **est** le ticket d'entrée : un palier non ouvert (policy `apply-<env>` non accordée, AppRole non minté) répond 403, et `team-promote.sh` refuse `PALIER_FERME` — le moteur n'est jamais invoqué. C'est le seul contrôle de toute la chaîne qu'un pipeline compromis ne se donne pas à lui-même : toutes les autres gardes sont in-repo. G4 avait posé ce mécanisme sans consommateur (§3 du contexte) ; G5 en est le premier appel réel, sur le chemin `proxy-oauth2` comme sur `direct`. Le chemin `labctl` étend le même principe à un second secret par palier, `envs/<env>/admin-oauth` (policy étendue par `setup-vault-paliers.sh`) : le moteur qui ne sait s'authentifier que par bearer relit Vault lui-même pour le frapper, avant le site d'appel du moteur — donc encore avant `run_engine()`.

### 7. La fidélité du mock est éprouvée par le harnais qui existait déjà, inchangé

`mocks/webmethods` a appris `GET /rest/apigateway/archive` et `POST /rest/apigateway/archive` — sémantique d'export/import calquée sur le comportement mesuré du wM réel (alias embarqué quand l'API route `${alias}`, refus sans `overwrite`, `isActive` de l'archive appliqué y compris la désactivation, GUID préservé). La porte de fidélité n'est pas une nouvelle suite : c'est `scripts/test-archive-promotion.sh`, le harnais d'ADR-079, rejoué **inchangé** contre le mock — 22/22, le même compte que contre le wM réel. Une purge de l'ACDL a dû être ajoutée au harnais (le manifeste de l'import portait une ligne de bruit du produit réel, `AccessProfile while importing the ACDL file`, sur chaque ligne) sans changer le compte d'assertions. Toute sémantique que le harnais épingle est due au mock, rien de plus — et cette même porte passe aussi contre le wM réel avec teamWork actif.

### 8. La porte du GOAL : deux moteurs, mêmes assertions, contre le wM réel

`scripts/test-promote-verb-live.sh` est LA porte de ce jalon : pour chacun des deux moteurs, contre le wM réel (`localhost:5555`), une API jetable active routée `${alias}` est exportée (digest calculé), importée sur un palier cible simulé vierge — GUID identique constaté des deux côtés, API active — puis ré-importée en overwrite sous charge concurrente, avec l'exigence de zéro réponse non-200 pendant l'import. La contre-épreuve `UPDATE_FORBIDDEN` (le chemin publication refuse un `deactivate` hors env d'authoring, et l'API reste active et servie après le refus) est rejouée à la fois live (le rôle) et par les tests Go de l'adaptateur (`labctl`, garde + projection de `allowDeactivate`). Résultat mesuré : **54/54 par chacun des deux moteurs**, GUID identique, 0-coupure sous charge (3550/3550 puis 4074/4074 requêtes 200 pendant les deux imports mesurés).

## Ce qui est prouvé — les comptes des portes

| Porte | Nature | Résultat |
|---|---|---|
| `scripts/test-archive-store.sh` (branchée `make lint-ci`) | hors-ligne : push idempotent, fetch re-haché, digest faux, token jamais en argv/URL | incluse dans `make lint-ci [6/8]` |
| `scripts/test-team-promote-wiring.sh` (branchée `make lint-ci`) | hors-ligne, chaque garde MUTÉE + mutation d'ordre | **90 / 0** |
| `go test ./mocks/webmethods/... -count=1` (branchée `make lint-ci [8/8]`) | hors-ligne : fidélité + archive du mock wM | incluse dans `make lint-ci [8/8]` |
| `scripts/test-archive-promotion.sh` | fidélité du verbe, mock ET wM réel (teamWork actif) | **22 / 22** (les deux) |
| `scripts/test-promote-verb-live.sh` | **LA porte du GOAL**, live wM réel, par CHACUN des deux moteurs | **54 / 54** (les deux), GUID iso, 0-coupure 3550/3550 et 4074/4074 |
| `make lint-ci` | Jenkinsfiles compilés + shellcheck + épreuves de tout G3/G4/G5 | `[1/8]`→`[8/8]`, rc=0 |

## Limites nommées

- **`approverGroup` non vérifié (G2).** La pause nominative et le 4-yeux conditionnel de `team-promote.sh` prouvent que le demandeur ne peut pas s'auto-approuver quand la porte l'exige ; ils ne vérifient PAS que la personne qui répond appartient au `approverGroup` déclaré dans `environments.yaml`. Nommé en G4 déjà, non fermé ici.
- **Le contrôle à quatre yeux est INERTE sur cette chaîne CI, aujourd'hui.** `promoted_by` (le demandeur comparé au mergeur) vaut `ci` tant que le plugin Jenkins `build-user-vars` n'est pas provisionné — `ci/Jenkinsfile.api-promote-request` pose `PROMOTED_BY=${BUILD_USER_ID ?: 'ci'}` et rien dans ce dépôt n'installe ce plugin. Ce n'est pas un faux refus : le mergeur reste un humain réconcilié auprès de Gitea, donc `merger == "ci"` ne peut jamais se produire par accident et la garde ne mord jamais à tort. Mais elle ne mord pas non plus tant que le plugin manque — écrit ici pour être lu avant d'être découvert en audit.
- **Un palier absent de `gates:` dans `environments.yaml` est une auto-approbation admise.** `env_chain_gate_four_eyes` rend `FOUREYES=0` quand aucune porte ne nomme le palier d'arrivée (`environments.yaml` documente déjà : « un palier SANS porte n'est pas un palier sans contrôle : c'est un palier où quiconque détient le droit d'approuver approuve, y compris le demandeur »). C'est un **fail-open par omission de configuration**, assumé et nommé — pas un défaut du mécanisme de porte, une propriété de ce qu'il garde : l'absence de déclaration.
- **La parité des deux moteurs n'est pas prouvée — c'est G8.** Les deux moteurs sont branchés et chacun prouvé vivant avec les mêmes assertions externes (GUID, activité, 0-coupure). Ce que ce jalon ne prouve pas, c'est l'iso-sémantique fine de l'état de gateway résultant entre les deux — un registre des écarts reste à construire.
- **Le client OAuth du chemin `proxy-oauth2` est partagé entre paliers hors-prod** (`ci-horsprod`, acquis ADR-075). La rétention mécanique de ce jalon tient par la lecture Vault par palier (§6) et le scope du proxy d'admin, pas par l'identité du client OAuth — le client par palier durcirait le plan réseau mais n'est pas posé (parking, réouverture : G2 ou exigence client).
- **La conversion du pipeline governance hors-prod au verbe archive n'est pas faite, et la tension est écrite noir sur blanc.** Le GOAL énonce « le verbe de déploiement est l'import d'archive… `apply-uac` reste le verbe de dev », et `ci/Jenkinsfile` re-POSTe aujourd'hui rec/int par le pipeline de gouvernance. La projection UAC n'est pas un artefact exporté d'une gateway au sens de ce jalon ; sa conversion se conçoit avec la parité G8, pas en silence.
- **Digest non vérifié par `labctl` lui-même.** Le CI (`team-promote.sh`, via `resolve_deploy_pin`) et le rôle Ansible vérifient le digest de l'archive avant l'appel moteur ; `labctl promote` reçoit une archive déjà vérifiée par son appelant et ne revérifie pas le sha256 en interne. Asymétrie assumée pour ce jalon : la garde existe une fois, au bon endroit du chemin CI, pas dans chaque moteur.
- **Statut E2E : la chaîne complète a tourné par des builds Jenkins réels** (T10, 2026-08-27, après le push exploitant `gitea/main = 646bf7b`). Nominal vert sur les DEUX moteurs — `team-promote #13` (moteur `ansible`, le défaut) et `#14` (moteur `labctl`, en overwrite du précédent, à GUID constant) — précédés de `api-promote-export #1` pour l'export et le push au registre. **La pause nominative est exercée** (`input` id=`Promote`, `V_USER` + `V_PASS` en `PasswordParameterDefinition`, répondue par `input/Promote/proceed`). Les deux contre-épreuves sont elles aussi passées par des builds : `#15` refuse en `PALIER_FERME` (rétention G4/ADR-082), `#16` refuse en `ARCHIVE_INTROUVABLE` (marqueur au digest forgé) — dans les deux cas le moteur n'est **jamais** lancé (`grep -c 'PLAY \['` = 0) et le catalogue du palier, remis à vide avant l'épreuve, reste à `n=0`. **La première preuve, elle, fut script-par-script** contre le même lab : c'est ce qui a permis d'isoler les écarts avant que la couche Jenkins n'existe — dont la fidélité base64 du mock (`0a1ac86`), sans laquelle le moteur Ansible ne pouvait pas importer vers un palier mocké.

## Parkings, avec clause de réouverture

1. **Pinner le guid automatiquement** (le job d'export ouvrirait lui-même la PR sur `promote.yml`) — non bloquant : `IMPORT_REFUSED` est fail-closed et le geste PR est celui que l'équipe fait déjà pour tout le reste. Réouverture : friction constatée à l'usage.
2. **Client OAuth par palier** (`apply-<env>` Keycloak, scope `deploy:<env>` seul) au lieu du client partagé `ci-horsprod`. Réouverture : G2, ou exigence client explicite.
3. **Conversion du pipeline governance hors-prod au verbe archive.** Tension nommée dans le GOAL lui-même, non résolue ici — à trancher avec G8, pas en silence.
4. **Second webhook si le multi-job-par-token du Generic Webhook Trigger ne tenait pas la mesure live** (il l'a tenue — ce parking documente le repli qui n'a pas eu à être activé, motif idempotent déjà présent dans `team-apply.sh`).
5. **Chaîne complète dev→…→prod par archive au-delà de `dev → rec`.** La porte de ce jalon vise `dev → rec` et la tient ; `homol`/`prod` n'ont ni mock d'Authorization Server ni backend seedé dans le lab. Réouverture : G6/G7 (parcours complet), rollback des paliers intermédiaires.

## Conséquences

**Sur l'existant.** ADR-082 posait des policies et des AppRoles sans consommateur immédiat ; ce jalon en est le premier appel réel, sur les deux chemins d'admin (`proxy-oauth2` et `direct`). Le formulaire de demande d'ADR-079/G3 (`api-promote-request.sh`) reste inchangé — son seul défaut nommé (« le merge ne déclenche rien ») est ce que ce jalon ferme.

**Sur le travail à faire.** G8 devient le lieu où la parité des deux moteurs se prouve, et où la conversion du pipeline governance se conçoit. G2 reste le lieu où `approverGroup` se vérifie effectivement, pas seulement se lit.

**Sur la frontière des secrets.** Aucun secret nouveau n'est matérialisé sur disque par ce jalon en dehors du bearer `labctl` (fichier 0600, jamais en argv) et du client-secret OAuth (jamais en argv, `--data-urlencode nom@fichier`). Le grant nominatif d'ADR-082 reste la seule autorité qui ouvre un palier.

## Résiduel

- **Le plugin Jenkins `build-user-vars`** reste à provisionner pour que le 4-yeux morde réellement sur cette chaîne (§ Limites nommées).
- **`approverGroup`** reste non vérifié — G2.
- **La politique d'attribution des grants par palier** (qui a `apply-rec` ?) reste une décision client — ADR-082, résiduel n°1, non re-tranchée ici.
