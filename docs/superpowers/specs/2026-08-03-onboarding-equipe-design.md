---
title: "Onboarding d'équipe : le fichier déclare, le credential prouve (spécification)"
type: spec
status: "Cadré le 2026-08-03. Palier 1 à implémenter. Un point du terrain (§2, feature Teams éteinte) est une HYPOTHÈSE à mesurer, pas un acquis."
date: 2026-08-03
lié: [GOAL-self-service-api-app-2026-07-09, 2026-07-29-f4-chaine-publication-design, 2026-07-31-e1-producteur-gitops-design, adr-076-gitops-api-lifecycle-repo-per-project, adr-077-user-identity-to-vault-token-exchange, adr-078-livrable-self-service-app-wm1015]
---

# Onboarding d'équipe (spécification)

## En une phrase

Créer une équipe est aujourd'hui un script de spike joué à la main sur `worker-1`
avec deux équipes en dur ; cette spécification en fait un rôle Ansible piloté par
un fichier déclaratif par environnement — et, chemin faisant, répare une variable
qui ne fait pas ce que son nom promet.

---

## 1. Terrain — pourquoi `apim_ss_require_team=false` ne désactive rien

Constat du 2026-08-03 : bouton posé à `false`, le rôle appelle malgré tout
`GET /accessProfiles` et échoue sur une gateway dont la feature Teams est
éteinte. Ce n'est pas un bug du bouton, c'est un **écart entre son nom et sa
portée**.

| Ce qui est commandé | Par quoi | Fichier |
|---|---|---|
| les deux `assert` (`TEAM_UNDEFINED`, `TEAM_CONFIRMED`) | `apim_ss_require_team` | `team-name.yml:36`, `verify.yml:74` |
| le travail réel (`GET /accessProfiles`, `POST /assets/team`) | `ss_team_name \| length > 0` | `team.yml:45` |
| la garde de visibilité | `ss_team_name \| length > 0` | `main.yml:55` |

`apim_ss_require_team` dit **« une team n'est pas obligatoire »**, pas **« les
teams sont désactivées »**. Or un nom d'équipe arrive toujours : le job passe
`-e apim_ss_team="$TEAM"` (`Jenkinsfile.selfservice:287,304`,
`Jenkinsfile.publish-api:270,285`), avec

```sh
TEAM="${APIM_TEAM:-$(printf '%s' "$APIM_WM_CREDS_SUB" | cut -d/ -f2)}"
```

Le seul contournement actuel — retirer `team:` du manifeste **et** cesser de
passer `-e apim_ss_team=` — exige d'éditer le dépôt de l'équipe, c'est-à-dire
l'endroit dont E1 a établi qu'il ne doit avoir aucune autorité. Il fait de plus
reposer la désactivation sur une **absence** : rien dans Git ne dira jamais
« ici le cloisonnement est volontairement désactivé, depuis telle date, pour
telle raison ». C'est ce que §3 corrige.

**Contexte de la demande.** La feature Teams est éteinte sur l'environnement
visé à cause d'un bug dont le correctif ne peut pas partir en production (des
correctifs antérieurs attendent leur validation). La dérogation est donc réelle
et temporaire — elle doit être exprimable, traçable, et **mourir d'elle-même**
quand sa cause disparaît.

---

## 2. Ce que l'onboarding pose, pour une équipe

Le rapport est **1:1** : une équipe = un dépôt = une team gateway = un chemin KV.

| Système | Objets |
|---|---|
| Gateway | user `svc-<team>`, groupe `<team>-devs`, accessProfile `<team>`, adhésion à `API-Gateway-Providers` |
| Vault | chemin KV `<prefix>/deploy/<team>/wm-admin` + policy `deploy-<team>` |
| Gitea | dépôt de l'équipe depuis le gabarit ADR-076 — **hors palier 1** |

Les shapes REST et leurs pièges sont acquis (spike F4 T1,
`docs/superpowers/plans/2026-07-29-f4-teams-bootstrap.sh`) : UUID exigés partout
(les noms sont ignorés en silence, 200 + liste vide), `privilege` est un bitmask,
l'adhésion au groupe système est une étape distincte de la team,
`enableTeamWork` vit sous le configId `extended`.

**Hypothèse à mesurer, pas à supposer.** `POST /accessProfiles`, `/users` et
`/groups` portent des objets RBAC qui existent indépendamment du cloisonnement ;
`enableTeamWork` ne ferait qu'activer leur effet sur les assets. Si c'est exact,
**l'onboarding n'est pas bloqué par le bug** : les objets se posent, leur effet
reste dormant jusqu'à réactivation. C'est la preuve n°6 du §7. Si elle rougit,
le palier 1 se réduit à Vault et l'onboarding devient dépendant du correctif.

**L'activation de la feature reste hors de tout pipeline.** C'est un réglage
global de gateway : son rayon d'explosion est sans commune mesure avec un
déclencheur unitaire, et ce n'est pas un interrupteur mais une migration (tout
l'existant est en `Default` ; activer ne partitionne rien rétroactivement).
Geste d'admin, une fois, au montage. Le rôle ne l'active jamais.

---

## 3. La sonde Teams et le bouton

**Deux variables, deux natures.**

| Variable | Nature | Valeurs |
|---|---|---|
| `apim_ss_teams_feature` | **état de la plateforme** | `auto` (défaut, sondé) \| `off` (forcé) |
| `apim_ss_require_team` | **politique** | `true` (défaut) \| `false` |

La sonde vit dans `apim_common/tasks/teams-feature.yml`, lit
`GET /configurations/extended` et pose `apim_teams_enabled`. Trois consommateurs :

- `apim_selfservice_app` et `apim_publish_api` — décident de jouer ou non les
  gardes team ;
- `apim_team_onboard` — **ne conditionne rien** : il crée les objets dans tous
  les cas et rapporte l'état (« accessProfile posé ; feature éteinte, effet de
  cloisonnement dormant »).

**Table de vérité.**

| Feature | `require_team` | Comportement |
|---|---|---|
| OFF | `false` | `team.yml` et `api-visibility.yml` **sautés en entier**, quel que soit le nom d'équipe résolu ; avertissement tracé |
| OFF | `true` | **Refus** immédiat, message `TEAMS_DISABLED` — au lieu d'un 401/404 obscur trois tâches plus loin |
| ON | `true` | Nominal |
| ON | `false` | **Refus** — `TEAMS_DEROGATION_STALE` |

La dernière ligne est la raison d'être du dispositif. La gateway sait cloisonner,
donc la dérogation n'est plus recevable : elle meurt le jour où le correctif
passe, sans que personne ait à s'en souvenir. Une dérogation temporaire qui
survit par oubli est le mode de défaillance qu'on ferme ici.

**Correction de portée.** Le bouton commande désormais le **travail**, pas
seulement les assertions — c'est l'écart constaté au §1.

**Emplacement du bouton :** inventaire par environnement dans le dépôt
plateforme (`ansible/inventory.<env>.ini` ou `group_vars/<env>.yml`), protégé
par branch protection et revue. Retenu contre une variable de job Jenkins parce
que la dérogation devient un fait daté, revu et auditable dans Git — ce qu'un
auditeur demandera en voyant un environnement non cloisonné. Il ne doit **jamais**
provenir du manifeste ni d'un paramètre de build : sinon « qui peut lancer un
build » devient « qui peut désactiver le cloisonnement ».

---

## 4. `providers.<env>.yml` — la source déclarative

```yaml
# ansible/providers.dev.yml — les équipes de l'environnement dev.
# Revue par PR, protégée par branch protection : c'est ici que l'appartenance
# d'une équipe devient un fait daté.
providers:
  - team: banking-demo
    description: "Équipe paiements — comptes et virements"
    repo: banking-demo/accounts-api     # explicite : ne se dérive pas du nom d'équipe.
                                        # Déclaré dès le palier 1, consommé au palier 2.
    approvers: ["A123456", "B789012"]   # matricules — cf. §6
```

Une équipe = une ligne. Tout le reste est **dérivé** de gabarits déclarés une
fois, surchargeables :

```yaml
apim_onb_user_tpl:   "svc-{{ team }}"
apim_onb_group_tpl:  "{{ team }}-devs"
apim_onb_kv_tpl:     "deploy/{{ team }}/wm-admin"
apim_onb_policy_tpl: "deploy-{{ team }}"
```

**Pourquoi des gabarits et non une table de correspondance.** La team du runtime
est dérivée du chemin KV du compte de service dont le job lit les creds, et ce
chemin est borné par la policy Vault du token nominatif (ADR-077). Se réclamer de
l'équipe X exige donc de savoir lire `deploy/X/wm-admin` — mesuré : oscar
(`operator-deploy`) → 403 sur le KV tenant, alice (`deploy-banking-demo`) → 200.
C'est une **preuve auto-portée**.

Un fichier `dépôt → équipe` consulté au runtime serait un **lookup** : il
affirmerait une appartenance sans que rien n'empêche le run de tourner avec les
creds d'une autre équipe. Ce serait remplacer une propriété enforcée par une
déclaration, et créer une seconde source de vérité pouvant diverger de la policy
Vault.

D'où la répartition : **le fichier déclare qui existe, le credential prouve qui
parle.** Le fichier est en amont (onboarding), la dérivation en aval (runtime).
Jamais l'inverse.

**Effet de bord recherché :** la convention, aujourd'hui encodée deux fois dans
un `cut -d/ -f2` que rien ne nomme, devient assertable. Le CI pourra vérifier que
`APIM_WM_CREDS_SUB` correspond à `apim_onb_kv_tpl` avant d'en dériver quoi que ce
soit — au lieu de découper en aveugle et de produire une valeur fausse en silence
chez un client dont la disposition KV diffère.

**Pas de secret dans le fichier.** Le mot de passe du compte de service est
généré à la volée, écrit dans Vault, jamais affiché. Le fichier reste lisible et
commitable sans réserve.

---

## 5. Le rôle `apim_team_onboard`

| Fichier | Raison d'exister |
|---|---|
| `tasks/main.yml` | résout la cible (`-e apim_onb_team=<x>` ou toutes les entrées), orchestre |
| `tasks/vault.yml` | secret généré, écriture KV, policy `deploy-<team>` |
| `tasks/gateway.yml` | user → groupe → adhésion `API-Gateway-Providers` → accessProfile |
| `tasks/verify.yml` | relecture indépendante des deux systèmes |

**Vault d'abord, et ce n'est pas cosmétique.** Le mot de passe n'existe qu'une
fois. Généré, posé sur la gateway, puis écriture Vault en échec → compte vivant
dont le secret est perdu, à réinitialiser à la main. Dans l'autre sens, un secret
écrit dont le compte n'existe pas est inoffensif : le run suivant le reprend.

**Le secret n'est généré que s'il est absent de Vault.** Un re-run ne fait pas
tourner le mot de passe — sinon rejouer l'onboarding casserait tous les jobs de
l'équipe. La rotation est un geste séparé, jamais un effet de bord.

**Le bitmask est une variable** (`apim_onb_privilege`), défaut = celui de
`API-Gateway-Providers`, comme le bootstrap F4. Le retrait de `POST /apis` (D6)
n'est pas tranché ici : il exige un bit-flip sur un profil jetable et une lecture
des noms en console. Le jour où c'est tranché, une valeur par défaut suffit à
propager.

**Le dépôt Gitea est hors palier 1** : il suppose que le rôle détienne un token
avec droit de création sous une organisation. Geste manuel comme aujourd'hui,
ajouté au palier 2 avec le câblage CI.

---

## 6. Approbateurs — déclaration maintenant, surface plus tard

**Aujourd'hui :** la liste de matricules vit dans le champ `owner` de chaque API,
et un développement custom scrute les approbations en attente toutes les X
minutes pour notifier cette liste par mail. La liste est donc dupliquée autant de
fois qu'il y a d'API et modifiable API par API — une équipe qui change
d'approbateur doit repasser sur toutes ses API, et rien ne garantit qu'elles
disent la même chose.

**Ce qui change :** `approvers` entre dans `providers.<env>.yml` et devient la
source de vérité. `owner` continue d'être écrit **tel quel**, comme une
**projection** — le développement custom qui le lit n'est pas touché. Le jour où
il est remplacé, seul l'écrivain change, pas la donnée.

**Le point d'application est le publish, pas l'onboarding.** Les API sont créées
après l'onboarding et continueront de l'être : une liste posée une fois manquerait
à la première API publiée le lendemain. C'est donc `apim_publish_api` qui l'écrit
à chaque publish, depuis le nom d'équipe déjà résolu. Le rôle écrivant
systématiquement, une API ayant dérivé revient dans le rang au publish suivant.

**Hors périmètre : la surface d'approbation.** Les approbateurs n'atteignent pas
la gateway (zones réseau restreintes) ; seul Jenkins l'atteint, par rebonds. La
surface doit donc être quelque chose qu'ils atteignent **et** qui atteint la
gateway. Deux approbations distinctes ne doivent pas être confondues :

- l'approbation d'un **changement** (publier une API, créer une application) est
  **déjà résolue** — PR Gitea, plan commenté, merge, demande en attente Jenkins
  avec identité nominative ; la surface est Git ;
- l'approbation d'une **demande runtime** (une application qui souscrit) vit dans
  la gateway : c'est celle que le développement custom scrute, et celle que la
  contrainte réseau bloque.

Piste privilégiée pour la seconde, à instruire dans un spec dédié : **Jenkins
comme surface**, sans composant neuf — le mécanisme de demande en attente est
prouvé (`PAUSED_PENDING_INPUT`, build #22, identité alice), Jenkins restreint qui
peut répondre et **enregistre qui a répondu**, ce que le mail ne fait pas. Point
de forme non tranché : une demande en attente par approbation immobilise un build
tant que personne ne répond (saturation sur flux régulier) ; l'alternative est un
job paramétré, moins fluide mais sans build suspendu.

---

## 7. Gardes et preuves

**Gardes fail-closed du rôle.**

1. **Nom d'équipe contrôlé à l'entrée** — `^[a-z0-9][a-z0-9-]{1,30}$`. Il sert
   simultanément de segment de chemin Vault, de nom de policy et de nom de team :
   `team: ../autre` produirait `deploy/../autre/wm-admin`. C'est une évasion de
   chemin qui donnerait à une équipe les creds d'une autre, pas une coquetterie
   de validation.
2. **Chaque objet relu, jamais cru sur parole** — les quatre pièges du spike F4
   sont des succès HTTP silencieux (UUID par nom ignorés → 200 + liste vide ;
   `assetType` manquant → 200 no-op). Un code de retour vert ne prouve rien :
   chaque écriture est suivie d'un `GET` et d'un `assert` sur ce qui devait
   changer.
3. **Convention assertée** — le chemin KV écrit doit être exactement celui que le
   CI dérivera ; le rôle rejoue la dérivation et compare.

**Preuves du palier 1**, sur une équipe jetable `onboard-probe`, environnement dev :

| # | Ce qui est prouvé |
|---|---|
| 1 | Les 4 objets gateway existent et sont reliés (user ∈ groupe, groupe ∈ accessProfile, user ∈ `API-Gateway-Providers`) |
| 2 | Le secret est dans Vault, la policy `deploy-onboard-probe` existe |
| 3 | **La douve** : un token portant cette policy lit son propre KV (200) et **pas** celui de `banking-demo` (403) |
| 4 | La dérivation du CI sur ce chemin KV rend bien `onboard-probe` |
| 5 | Re-run → aucun changement, et **le mot de passe n'a pas tourné** |
| 6 | Feature Teams éteinte : l'accessProfile est bien posé (hypothèse du §2, **mesurée**) |
| 7 | Suppression symétrique : tout part, rien n'est orphelin |

Le n°3 est le seul qui compte vraiment : les autres vérifient que des objets
existent, celui-là vérifie que **l'isolation tient** — donc que la dérivation du
CI est digne de confiance. Sans lui, on a onboardé une équipe sans savoir si elle
est cloisonnée.

**Preuve de la garde anti-dérive** (§3), indépendante du rôle : feature ON +
`require_team=false` → refus `TEAMS_DEROGATION_STALE`.

---

## 8. Périmètre

**Palier 1 (cette spécification)** : `providers.<env>.yml`, gabarits de
convention, rôle `apim_team_onboard` (Vault + gateway), sonde Teams partagée et
correction de portée du bouton, `approvers` déclaré et projeté dans `owner` au
publish. Preuves 1–7 + garde anti-dérive.

**Palier 2** : création du dépôt Gitea depuis le gabarit ADR-076, câblage CI
(job *plan* sur PR de `providers.<env>.yml`, job *apply* en demande en attente),
en réutilisant `provision-plan.sh` et `provision-apply` presque tels quels.

**Hors périmètre, à instruire séparément** : la surface d'approbation (§6) ; le
scope Keycloak `selfservice:<team>` et son mapper (chemin consommateur E2) ; le
job Jenkins par équipe en `CpsFlowDefinition` (E1) ; l'arbitrage D6 sur le
bitmask ; l'activation de la feature Teams elle-même.

---

## 9. Décisions actées

| Décision | Pourquoi |
|---|---|
| Deux variables (`teams_feature` / `require_team`) plutôt qu'une | Un bouton qui ne commande que les assertions ne désactive rien (§1) |
| Dérogation refusée quand la feature est ON | Une dérogation temporaire ne doit pas survivre par oubli |
| Bouton dans l'inventaire par env, jamais dans le manifeste ni un paramètre de build | L'autorité vient de l'endroit où le bouton vit, pas d'un test « es-tu admin ? » |
| Gabarits de convention, pas de table `dépôt → équipe` | Le credential prouve, le fichier déclare — un lookup remplacerait une propriété enforcée par une affirmation |
| Vault avant gateway | Un secret orphelin est inoffensif ; un compte au secret perdu ne l'est pas |
| Secret non régénéré au re-run | Rejouer l'onboarding ne doit pas casser les jobs de l'équipe |
| `approvers` appliqué au publish, pas à l'onboarding | Les API naissent après l'onboarding |
| `owner` conservé comme projection | Le développement custom qui le lit continue de tourner |
| Dépôt Gitea reporté au palier 2 | Il demande un droit de création d'organisation, arbitrage distinct |
