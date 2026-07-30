# Spécification — Lot A : Vault du cluster en voie A (user/mot de passe → LDAP)

**Date :** 2026-07-30
**Statut :** cadré en session de brainstorming, design validé par l'utilisateur.
**Périmètre :** porter dans le cluster k3s Contabo le chemin d'authentification **voie A** (user/mot de passe d'annuaire → Vault), prouvé le 2026-07-23 sur le POC docker-compose. Déployer un annuaire LDAP dans le cluster. Prouver la chaîne depuis un pod agent Jenkins.

**Hors périmètre**, traités en lots séparés :
- **Lot A-bis** — le realm de sécurité LDAP de Jenkins. Exclu d'ici parce que le `Deployment` de Jenkins vit dans le dépôt `stoa` : voir D7.
- **Lot B** — les pipelines `publish-api-deploy` (APIs) et `selfservice-app-deploy` (applications) exécutés dans le cluster contre la gateway `wm`.
- **Lot C** — l'API proxifiée qui écrit dans Gitea puis déclenche le plan par webhook.

Sans le lot A, B et C n'ont pas de secrets. C'est pourquoi il vient en premier.

---

## 1. Besoin

Le client ne peut pas utiliser l'authentification Kubernetes de Vault : sa plateforme est sous-dimensionnée et il veut limiter les appels réseau vers Vault. Son modèle est **LDAP par API, jeton Vault classique, récupération des secrets par API**. Le CI du lab doit donc savoir s'authentifier à Vault avec les identifiants d'annuaire d'un opérateur, et non par l'identité du pod.

## 2. Constats d'entrée (vérifiés le 2026-07-30)

### Ce qui existe déjà et n'est pas à réécrire

- **Les rôles Ansible portent déjà les deux chemins d'authentification.** `apim_common/defaults/main.yml` définit `apim_ss_vault_k8s_mount` (identité de pod) *et* `apim_ss_vault_user_mount`, ce dernier normalisé : `ldap`, `auth/ldap` et `auth/ldap/` donnent le même résultat. Un commentaire du fichier précise que la requête REST est identique chez le client, seul le mount change.
- **`ci/lib/vault-login.sh`** (POSIX) expose `vault_login_nominative`, `vault_login_approle`, `vault_login_any`, `vault_revoke_proof`, avec un mode debug non-fuyant.
- **La voie A est prouvée** : `scripts/test-vault-user-login.sh` **37/37** (dont D1/D2/D3 pour le mode debug), jobs `selfservice-app-deploy #7` et `publish-api-deploy #11` SUCCESS, sur le POC compose.
- **Le palier LDAP réel existe** : `scripts/setup-vault-ldap.sh` et `docker-compose.ldap.yml` (poc-openldap), avec tests UPN, `DOMAIN\user` et mapping groupe→policy.
- **`scripts/diagnose-vault.sh`** rejoue la chaîne étape par étape (joignable ? mount ? login ? lecture ?) en donnant le code HTTP et le message Vault à chacune. C'est l'outil le plus utile sur place ; il est honnête sur une ambiguïté : un mount **absent** renvoie 403 comme un mount qui **rejette**.

### Nombre d'appels Vault par build

Mesuré sur `apim_common/tasks/secrets.yml` : **quatre à cinq appels**.

1. `POST /v1/<mount>/login/<user>` — le login.
2. `GET /v1/<kv>/…/wm-admin` — identifiants d'admin de la gateway.
3. `GET /v1/<kv>/…/oauth` — paramètres OAuth2.
4. `POST /v1/sys/capabilities-self` — uniquement en mode debug.
5. La révocation du jeton en sortie.

Ni sidecar Vault Agent, ni driver CSI, ni lecture par tâche. **La contrainte « limiter les appels réseau » est satisfaite par construction**, et ce constat est chiffré plutôt qu'affirmé.

### État du cluster

- ns `ci` : `gitea-0`, `jenkins`, `vault-0` — tous `1/1 Running`, Vault **descellé**.
- ns `wm` : `wm-apigateway`, `wm-elasticsearch-0`, CronJob `wm-restarter` toutes les 20 min.
- ArgoCD pilote tout. L'`AppProject` `stoa` restreint ses sources au dépôt `stoa` ; le projet `default` accepte n'importe quelle source, montage validé le 2026-07-30 avec `edge/cloudflared`.
- **Aucun external-secrets** dans ce cluster : rien ne synchronise Vault vers des Secrets k8s, et c'est cohérent — les secrets sont lus au vol.
- **Jenkins n'a aucun realm de sécurité** : `GET /api/json` répond 200 sans authentification.

### Les clés de Vault sont hors ligne

Toute modification de la configuration de Vault exige un **jeton racine éphémère obtenu par quorum 2/3**, comme le montre `docs/superpowers/plans/2026-07-29-f4-vault-role-toggle.sh`. Cela ne peut être fait que **par l'exploitant**. Aucun agent ne peut activer un mount, écrire une policy ou créer un utilisateur.

### Quatre mots de passe de lab sont publics

`scripts/lib/lab-vault-users.sh` porte en clair `LAB_ALICE_PASS`, `LAB_CAROL_PASS`, `LAB_BOB_PASS` et `LAB_OSCAR_PASS`, dans deux commits (`83964e1`, `9ef7eb6`). Le dépôt étant passé public, ces valeurs sont **brûlées**.

## 3. Hypothèse critique, non vérifiée

> **Si l'annuaire du client impose du MFA, la voie A tombe.**

Un login user/mot de passe non interactif est incompatible avec un second facteur. Le handoff du 2026-07-23 pose cette question **en premier** parmi les huit décisions client, et elle n'a pas été récoltée.

Ce lot est donc construit sous l'hypothèse explicite **« annuaire sans MFA sur le compte de service de déploiement »**. Si elle tombe, le repli est la voie B (ADR-077, SSO) — un autre chantier, pas un ajustement.

Cette hypothèse ne bloque pas le lab : `userpass` et un LDAP sans MFA sont représentatifs de tout client qui n'impose pas de second facteur. Elle est notée comme risque, pas comme acquis.

## 4. Décisions

### D1 — Les deux chemins d'authentification coexistent, la voie A par défaut

L'identité de pod prouvée en F1 est **conservée** : sa porte reste rejouable, aucune régression sur un jalon fermé. La voie A devient le chemin **par défaut** des pipelines. `vault_login_any` bascule déjà entre les deux, il n'y a pas de code à écrire pour cela.

**Rejeté :** *retirer l'identité de pod* — invaliderait la porte F1 telle qu'elle est écrite et imposerait d'amender le GOAL, sans bénéfice pour le client. *Séparer par nature d'acteur* (infrastructure en identité de pod, publications en nominatif) — séduisant, mais ajoute une règle à retenir sans rien prouver de plus au stade actuel.

### D2 — La configuration de Vault est un script exécuté par l'exploitant, par quorum

Sur le modèle exact de `2026-07-29-f4-vault-role-toggle.sh` : deux clés de descellement en arguments, jamais affichées, jeton racine éphémère révoqué en sortie.

Le script est **idempotent** et fait, en une passe : activer le mount `userpass`, activer le mount `ldap`, écrire les policies `deploy-<tenant>` et `operator-deploy`, créer les identités, lier groupe d'annuaire → policy.

**Rejeté :** *un job Jenkins qui configure Vault* — il lui faudrait un jeton privilégié stocké dans Jenkins, ce qui violerait l'assertion « aucun secret statique dans Jenkins » prouvée en F1. *Vault en mode dev ou avec jeton racine persistant* — dégraderait la posture pour une commodité.

### D3 — Les mots de passe sont générés au setup et déposés dans un fichier root-only du nœud

Le script tire des mots de passe aléatoires et les écrit dans un fichier root-only de worker-1, sans jamais les afficher. C'est la doctrine déjà en vigueur sur ce projet pour toute sortie sensible.

**Le mot de passe de login à Vault ne peut pas vivre dans Vault** : il sert à s'y authentifier, l'y ranger est circulaire. Les identifiants d'admin wM et les secrets clients OAuth2, eux, restent bien dans Vault — ils sont lus *après* le login.

**Rejeté :** *les identifiants Jenkins* — même violation qu'en D2. *Un fichier chiffré en Git* — la clé de déchiffrement repose le problème un cran plus loin.

### D4 — Les identités publiques sont considérées mortes et recréées sous d'autres mots de passe

`lab-vault-users.sh` est réduit aux **noms d'utilisateur** et à la table utilisateur → tenant → policy. Les valeurs de mot de passe en sortent.

**Pas de réécriture d'historique.** Elle casserait tous les hachages et tous les clones, et sur un dépôt public les objets peuvent déjà être copiés dans des forks ou des archives : le bénéfice est illusoire. Les anciennes valeurs restent lisibles dans l'historique ; la mesure qui protège réellement est de **ne jamais les réutiliser**.

**Le vecteur de test à caractères hostiles reste en Git** — `B0b "q" \back $dollar 'sq' ;semi &amp {brace}`. Ce n'est pas un secret mais un **cas de test** : il prouve que le login ne casse ni ne s'injecte sur des guillemets, antislashs et dollars. Il garde sa valeur en public à condition de n'être le mot de passe d'aucun compte réel.

### D5 — OpenLDAP en ns `ci`, versionné dans `stoa-labs`, sans volume

Deployment sous `deploy/bootstrap/ci/openldap/`, synchronisé par une Application Argo sur le projet `default` — le montage validé avec `edge/cloudflared`.

**Aucun PVC** : l'annuaire du lab est entièrement reconstruit par le script de setup, sa donnée n'a pas de valeur à préserver. Un redémarrage le vide, le script le repeuple.

`docker-compose.ldap.yml` est **conservé** : le POC compose reste la référence de la preuve 37/37, et le supprimer avant que le cluster n'ait fait la sienne détruirait le seul témoin qui fonctionne.

### D6 — Les trois formats de login sont éprouvés, aucun n'est parié

`sAMAccountName`, UPN (`alice@corp`) et `DOMAIN\alice`. Le format du client est l'une des huit décisions ouvertes ; en éprouver un seul serait un pari.

C'est aussi ce qui démontre le point technique du handoff : **`userpass` refuse `@` et `\`**, seul le mount `ldap` les porte. Un lab qui ne teste que `userpass` ne peut pas révéler ce piège.

### D7 — Jenkins reçoit un realm LDAP, et le build prend les identifiants en paramètres

La contrainte énoncée — « authentification user/mot de passe de l'utilisateur sur Jenkins, ce qui permet de se connecter à Vault » — admet deux lectures, et une seule est techniquement saine.

**Retenu :** deux authentifications distinctes contre **le même annuaire**.
1. Jenkins obtient un **realm de sécurité LDAP** : l'annuaire gouverne qui peut lancer un build. Cela solde du même coup la dette « Jenkins anonyme », aujourd'hui ouverte.
2. Le build prend `VAULT_USER` et `VAULT_USER_PASSWORD` en **paramètres**, et `vault-login.sh` s'authentifie à Vault avec. C'est ce qui est déjà implémenté et prouvé.

**Le point 1 sort du périmètre de ce lot, pour une raison structurelle.** Le `Deployment` de Jenkins est synchronisé depuis le dépôt **`stoa`** (`ci-jenkins → deploy/bootstrap/ci/jenkins`). Y poser un realm LDAP — que ce soit par JCasC monté ou par variables d'environnement — exige de modifier ce dépôt, c'est-à-dire une PR sur la plateforme en cours de rebuild. C'est exactement ce que le découplage cherche à éviter.

Le realm devient donc **le lot A-bis**, avec son propre arbitrage : soit une PR assumée sur `stoa`, soit le déplacement de Jenkins vers un manifeste porté par `stoa-labs`. Aucun des deux ne se décide en passant.

**Conséquence à assumer en attendant : Jenkins reste anonyme.** Le seul rempart devant lui est la politique Cloudflare Access posée le 2026-07-30 — un périmètre, pas un correctif. Qui franchit Access obtient un Jenkins complet, donc la capacité de lancer un build. La voie A ne réduit pas ce risque : elle exige un mot de passe d'annuaire *en paramètre*, ce qui protège les **secrets** de Vault, pas l'**accès** à Jenkins.

**Rejeté :** *Jenkins réutilise le mot de passe saisi à sa propre connexion pour appeler Vault.* C'est la lecture littérale de l'énoncé, et elle est **à écarter** : Jenkins devrait conserver le mot de passe en clair pour la durée de la session. Aucun realm sérieux ne le fait, et le stocker créerait précisément le secret statique que F1 s'est attaché à éliminer.

Conséquence assumée : l'opérateur saisit son mot de passe **deux fois** — une fois pour entrer dans Jenkins, une fois comme paramètre de build. C'est le prix de ne pas stocker le secret. Le libellé « Change Password » du formulaire Jenkins est trompeur et doit être documenté dans la description du job : il ne change aucun mot de passe d'annuaire.

## 5. Artefacts

| Chemin | Rôle |
|---|---|
| `docs/superpowers/plans/2026-07-30-lot-a-vault-voie-a-setup.sh` | script exploitant : mounts, policies, identités, mapping groupe→policy. Quorum 2/3, idempotent |
| `deploy/bootstrap/ci/openldap/` | Deployment + Service + kustomization (ConfigMap généré à empreinte, sans PVC) |
| `deploy/bootstrap/argocd/app-ci-openldap.yaml` | Application Argo, projet `default`, source `stoa-labs` |
| `poc-control-plane-federation/scripts/lib/lab-vault-users.sh` | **modifié** : noms et mapping seulement, plus aucune valeur de mot de passe |
| `poc-control-plane-federation/scripts/setup-vault-ldap-cluster.sh` | peuplement de l'annuaire du cluster (utilisateurs, groupes) |

Le ConfigMap est **généré** (`configMapGenerator`), pas écrit en dur : un ConfigMap statique se met à jour en place sans redémarrer les pods, et l'annuaire servirait alors une configuration périmée en silence. Ce piège a été rencontré et corrigé sur `cloudflared` le 2026-07-30.

## 6. Porte de preuve et contre-épreuves

**Porte A :** depuis un **pod agent Jenkins du cluster**, `ci/lib/vault-login.sh` obtient un jeton nominatif via `auth/ldap`, lit les identifiants d'admin wM dans Vault, et le jeton est révoqué en sortie **avec preuve de mort** (une lecture avec le jeton révoqué doit échouer).

La porte doit être franchie depuis un pod, pas depuis un poste : c'est le chemin réel du pipeline, et lui seul prouve que la résolution DNS, le réseau et les politiques tiennent en conditions d'exécution.

**Contre-épreuves — sans elles la porte ne prouve rien :**

1. **Mauvais mot de passe** → échec **fermé**, aucun secret servi. Le code ne retente jamais un refus (politique de lockout AD chez le client).
2. **Utilisateur d'un autre tenant** → login réussi mais lecture **403**. C'est ce qui prouve que la policy, et non le login, gouverne l'accès aux secrets.
3. **Jeton révoqué** → lecture refusée. Prouve que la révocation est effective et non cosmétique.
4. **Les trois formats de login** → `sAMAccountName` accepté sur `ldap`, UPN accepté sur `ldap`, `DOMAIN\user` accepté sur `ldap`, et **UPN refusé sur `userpass`** — la démonstration du piège de D6.
5. **`diagnose-vault.sh` depuis un pod** → localise correctement une panne provoquée (mount inexistant, mot de passe faux, policy absente).

**Un `200` ne prouve rien par lui-même.** Sur ce projet, un `PUT` de la gateway a déjà renvoyé 200 sans appliquer la modification demandée (2026-07-29, champ `owner`). Chaque assertion de ce lot se vérifie par **relecture de l'état**, jamais par le code de retour de l'écriture.

## 7. Contrainte d'exécution : la fenêtre de 20 minutes

Le CronJob `wm-restarter` recycle la gateway toutes les 20 minutes, avec environ 3 minutes de démarrage — soit **une fenêtre utile d'environ 17 minutes**.

Le lot A ne touche pas la gateway, il n'est donc pas concerné directement. Mais toute preuve de bout en bout qui l'inclura (lots B et C) doit être lancée **juste après un cycle**, et une exécution de plus de 17 minutes sera coupée en plein vol. À traiter dans le lot B, pas ici.

## 8. Dettes assumées

- **Le TTL du jeton Vault face à la durée d'un build** : au-delà du TTL, il faudrait `renew-self`, non implémenté. Sans objet sur un lot A qui ne fait que se connecter et lire, à reprendre au lot B si un build long apparaît.
- **Groupes d'annuaire imbriqués** : le `groupfilter` par défaut de Vault ne résout pas le nesting (`LDAP_MATCHING_RULE_IN_CHAIN`). L'annuaire du lab restera plat ; si le client utilise des groupes imbriqués, le mapping groupe→policy devra être revu.
- **`VAULT_NAMESPACE`** (Vault Enterprise) : codé, non éprouvable — le lab tourne sur Vault OSS.
- **Les sept autres décisions client** du handoff restent ouvertes (mount exact, format de login, qui peuple les groupes, lockout, secrets de plateforme lisibles par un humain). Le lab les rend testables ; il ne les tranche pas.
