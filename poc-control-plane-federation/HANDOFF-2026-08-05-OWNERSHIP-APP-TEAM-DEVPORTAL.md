# HANDOFF — 2026-08-04/05 : ownership d'application → team (wM 10.15) et Developer Portal réel

_Dépôt `stoa-labs`, branche `main`. Session ouverte sur une question client
(« sur le dev portal 10.15 on ne peut plus changer l'owner d'une application ;
si la personne quitte la société le mot de passe est perdu — peut-on l'affecter
à une team ? »), close sur une preuve 17/17, un overlay DevPortal 10.15 réel,
et un volet de validation prêt à jouer chez le client._

## En une phrase

Sur la gateway 10.15, le secret d'une application suit son **owner** — jamais
ses `teams[]` — et `POST /assets/owner` avec `ownerType=team` (UUID, jamais le
nom) transfère ce secret à toute une équipe, y compris **après** la suppression
du compte du partant ; côté portail, la ressource Teams **existe** (la note du
repo disait le contraire, corrigée) mais la licence trial bloque toute écriture,
donc le volet share y est prêt-à-prouver, pas prouvé.

---

## 1. La découverte centrale : deux gestes, deux effets — mesuré 17/17

`scripts/spike-devportal-app-ownership.sh` (nouveau, rejouable, cleanup
vérifié) contre `poc-webmethods-real` (trial 10.15) :

| Geste | Ce qu'il fait | Ce qu'il ne fait PAS |
|---|---|---|
| `POST /assets/team` | qui **voit** / qui **gère** (cloisonnement : cross-team GET/DELETE → 401, mesuré) | ne touche PAS la lisibilité du secret |
| `POST /assets/owner` | qui **lit le secret** en clair | — |

Faits mesurés (T1-T11) :

- La clé n'est lisible en clair **que par l'owner**. Ni un coéquipier, ni
  l'`Administrator` (masquée `********`, liste ET détail). « On demandera à
  l'admin » n'est pas un plan de secours.
- `ownerType=team` + **UUID d'accessProfile** ⇒ `owner=<uuid>/team`, **tous les
  membres lisent la clé**, l'équipe tierce reste en 401. C'est LA réponse à la
  question client.
- **Le départ** : `DELETE /users/<partant>` ⇒ l'app team-owned survit intacte,
  le coéquipier lit toujours. La gateway ne cascade pas (contrairement au
  portail, § 3).
- **Contre-factuel** : app cloisonnée (`/assets/team`) mais restée en propriété
  individuelle ⇒ après le départ, PERSONNE ne lit la clé (admin compris).
  `/assets/team` ne protège donc pas du scénario client.
- **Réparable après coup** : sur un owner fantôme (compte déjà supprimé),
  `assets/owner → team` rend la **même** clé lisible. Rien n'est perdu chez le
  client, seulement inaccessible — aucune rotation nécessaire.
- Geste **réservé à l'admin** : membre d'équipe ⇒ 401 sur `assets`.
- `ChangeOwnerRequest` = 8 propriétés : `assetIds, assetType, newOwner,
  ownerType, newTeams, currentOwner, currentTeams, matchingAssets`
  (`currentOwner`+`matchingAssets` ⇒ réaffectation en masse d'un partant — non
  testé).

### ⚠ Les deux pièges à ne jamais oublier

1. **Fail-open du NOM d'équipe (T7)** : `assets/owner` avec le nom (au lieu de
   l'UUID) répond 200 ET la relecture rend `owner=<nom>/team` — tout paraît
   juste — mais les membres ne lisent rien. La relecture de `owner` ne prouve
   RIEN ; la seule porte de preuve est « un membre lit-il la clé ». Pire que le
   no-op silencieux de `/assets/team` sans `assetType` : ici la relecture ment.
2. `Accept: application/json` obligatoire sur l'admin REST (sinon HTML/200).

---

## 2. Developer Portal 10.15 réel : monté, inspecté, écritures bloquées

### L'overlay (nouveau) : `docker-compose.devportal1015.yml`

`softwareag/devportal:10.15` (image locale, `pull_policy: never`, amd64 émulé).
Faits d'inspection qui divergent TOUS du 11.1 :

| Fait | 10.15 | (11.1 pour mémoire) |
|---|---|---|
| Port conteneur | **8083** → hôte `18103` | 8080 → 18101 |
| Datastore | **Elasticsearch 7.17.x** (client 7.17.4 dans le war) → service `dp1015-es` dédié (ES 7.17.3 local, hôte `19202`) | OpenSearch 2.19 |
| Propriété Spring | dépend du **profil** : `spring.elasticsearch.uris` (dev, actif) vs `.rest.uris` (prod) → on pose LES DEUX | idem, mais expliqué « version » par le chart IBM — c'est faux, c'est le profil |
| Licence | DPO expirée **2022/10/30** ⇒ health `yellow`, **toute écriture REST → 406 « Valid license is missing »** | expirée 2024/09/01, mêmes symptômes |

`poc-wm-es` (ES 8.13.4 de la gateway) est **incompatible** — instance dédiée
obligatoire.

### La note du repo était fausse — corrigée

`GOAL-self-service-api-app-2026-07-09.md` affirmait « le DevPortal n'expose pas
de ressource Teams » (REFUTÉ 0-3). **Faux, mesuré** : `/portal/rest/v1/teams`
est une vraie ressource (JSON là où un chemin bidon retombe en HTML/200 — c'est
le discriminant), avec `/teams/{id}/users` et `/teams/{id}/applications`. La
recherche de juillet s'appuyait sur une doc UI-centrée. Correction datée posée
dans le GOAL.

### Ce que le bytecode établit (javap sur le war — à VÉRIFIER sur instance licenciée)

- `ApplicationAccessTree$NodeType` = **{USER, TEAM}** — le partage vise users
  OU teams. `ApplicationManagementAPI` expose `/{id}/share` (POST-only).
- RBAC (`ApplicationsAccessManager`) : accès app = owner OU shared OU
  `isAdminOrProvider` ⇒ **forçage admin du share plausible**. Masque
  (`ApplicationMask`) raisonne en `isOwnerOrSharedUser` ⇒ credentials
  probablement visibles des partagés.
- Garde du share vers une team : « *Given Team(s) %s doesn't belong to the
  Application owner* » ⇒ on ne partage qu'avec une team **du owner** — partager
  AVANT le départ.
- **Owner portail : immuable**, confirmé (aucune route de transfert,
  `ApplicationUpdateHandler` ne touche pas owner). Le constat client tient.
- ⚠ **`ApplicationCleanupHandler implements UserDeletionHandler`** : supprimer
  un compte portail **détruit ses applications possédées** (hard delete si
  `INACTIVE`, sinon softDelete = `PortalAppDeletionRequestEvent` → UserRequest
  au moteur d'approbation). Le share ne sauve PAS une app possédée ; seules les
  apps où le partant est simple participant survivent (retiré de l'ACL). **Plus
  grave que la question posée** : la purge de comptes détruit des apps.

---

## 3. Le pattern retenu (contrainte client : PAS de compte de service)

1. Owner portail humain (inévitable) + **share systématique vers la team à la
   création** (automatisable, forçable par l'admin si T19 le confirme).
2. **Désactiver, jamais supprimer** un compte portail tant qu'il possède des
   apps (cascade § 2).
3. Filet de sécurité côté gateway (mesuré) : `assets/owner → ownerType=team`,
   même après coup.

## 4. Le volet share en écriture : prêt, gaté sur la licence

Dans le même script, T14 est devenu un **gate** : POST `/rest/v1/teams` —
406 ⇒ T15-T20 **SKIPPED** proprement (état du lab, 17/17 + SKIP affiché) ;
2xx ⇒ déroulé complet. Chez le client :

```bash
DP_BASE=https://<devportal>/portal DP_USER=<admin> DP_PASS=... \
GW_ADMIN=https://<gw>:5555/rest/apigateway WM_USER=<admin> WM_PASS=... \
./scripts/spike-devportal-app-ownership.sh
```

T15 users/teams/link (preuve par relecture) · T16 exclusion avant share ·
**T17 le test décisif** (membre voit l'app ET `/tokens`) · T18 garde « team du
owner » · T19 forçage admin · T20 cascade (possédée détruite, partagée
survit). **Shapes best-effort** dérivées du bytecode : les helpers tentent
POST/PUT × tableau/objet ; un 400 persistant = shape à ajuster, pas une
réfutation.

---

## 5. État du lab et du dépôt après session

- **Commit `2098e57` sur `main` local, NON poussé** (ni origin ni gitea) :
  script + overlay + correction GOAL. Les modifs `carto/` et
  `ci/Jenkinsfile.carto` restent hors commit.
- **`enableTeamWork=true` posé sur `poc-webmethods-real`** — aller simple
  assumé ; l'activation a **redémarré la gateway** et basculé tous les assets
  existants en `[Administrators, Default]`.
- Conteneurs `poc-devportal-1015` + `poc-dp1015-es` **créés puis arrêtés**
  (volume `dp1015-es-data` conservé — un `up` de l'overlay les relance avec
  leurs données). Démarrage : le `.env` du repo est décalé de `.env.example`
  (8 clés manquantes) → env mergé jetable utilisé, cf. scratchpad ; à
  réconcilier un jour.
- Utilisateurs/équipes/apps de spike : tout nettoyé, état gateway identique à
  l'avant-session (vérifié : users, groups, accessProfiles, applications).
- Mémoire : nouvelle note `wm-1015-app-ownership-team` ; résiduel « app
  assignée = protégée ? » clos dans `wm-1015-teams-scoping`.

## 6. Ce qui reste

| Quoi | Où | Bloqué par |
|---|---|---|
| Prouver T15-T20 (share, credentials des partagés, forçage admin, cascade) | instance DevPortal **licenciée** du client | licence DPO valide |
| Qui devient owner **gateway** d'une app née au portail (compte d'appairage ?) | idem — T15-T20 ne le couvrent pas | licence + appairage |
| Activation `enableTeamWork` sur les gateways client | fenêtre à planifier : redémarrage observé au lab, contrainte zéro-coupure ADR-079 | décision client |
| Réaffectation en masse d'un partant (`currentOwner`+`matchingAssets`) | gateway, testable au lab | rien — juste pas fait |
| Pousser `2098e57` (origin + gitea — gitea = ce que lit le CI) | `git push origin main && git push gitea main` | demande explicite |
