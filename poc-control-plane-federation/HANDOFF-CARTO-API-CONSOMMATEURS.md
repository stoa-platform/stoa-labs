# HANDOFF — Carto des API et des consommateurs

**Session des 2026-07-30 / 07-31.** Lot livré, fusionné sur `main`, éprouvé en
réel contre la gateway du cluster. 205 tests.

## En une phrase

Un collecteur en **stdlib Python seule** lit l'inventaire et le trafic d'un API
Gateway webMethods **par son contrat public**, produit un contrat de données, et
publie des pages Markdown dans un dépôt git dédié — parce que chez le client il
n'y a pas de serveur web, il y a git.

## Le problème d'origine

La carto était régénérée à la main depuis la production à chaque intégration
d'API (~5 min), et produisait un HTML jetable. Le coût des 5 minutes n'était pas
le vrai problème : **une carto régénérée à la main est périmée dès qu'un tiers
modifie la production**, et elle n'existe que lorsque quelqu'un la fabrique.

La cause structurelle : le script faisait la collecte **et** le rendu d'un seul
geste. Les séparer par un contrat de données est la décision qui gouverne tout
le reste — c'est elle qui rend le produit testable sans accès production.

## Ce qui est livré

`carto/` — 37 fichiers, autonome et transportable.

| | |
|---|---|
| `collect/model.py` | contrat + validateur (refuse une carto vide) |
| `collect/gateway.py` | inventaire, liens déclarés |
| `collect/analytics.py` | trafic, par l'API publique de la gateway |
| `collect/build.py` | jointure déclaré × observé |
| `collect/history.py` | journal d'évolution, idempotent par date |
| `collect/publish.py` | publication atomique, refus si dégradé |
| `render/markdown.py` | les quatre pages du dépôt de publication |
| `render/page.py` + `index.html` | page **autoportante**, zéro requête réseau |
| `scripts/publier-markdown.sh` | publication git, appelée par les deux voies |
| `ansible/roles/carto_collect/` | déploiement + planification cron |

Plus, côté CI : `poc-control-plane-federation/ci/Jenkinsfile.carto`,
`ci/jenkins/carto.job.xml`, `scripts/setup-carto-job.sh`.

**Deux voies de déploiement au choix**, cron par Ansible ou job Jenkins. Elles
portent les **mêmes quatre assertions** contre une collecte dégradée : aucune
n'est une porte plus faible que l'autre.

## Ce qui est prouvé, en réel

Neuf builds Jenkins sur le cluster. Les échecs ont rapporté plus que les succès.

| Build | Ce qu'il a établi |
|---|---|
| #2 | Elasticsearch injoignable → NetworkPolicy révélée, **refonte décidée** |
| #3 | collecte par l'API de la gateway, puis **refus de la porte** |
| #4 | archivage des artefacts |
| #5 | historique repris d'un build à l'autre |
| #7 | enregistrement des paramètres (contrainte Jenkins, voir pièges) |
| #8 | chemin source relatif → **angle mort de la méthode de test** |
| #9 | **publication Markdown de bout en bout** |

Également prouvé hors Jenkins : une carto dégradée ne remplace jamais une bonne
publication (empreinte inchangée après refus, zéro résidu temporaire) ; la page
autoportante s'ouvre en `file://` sans émettre **aucune** requête réseau
(constaté dans un vrai navigateur, `performance.getEntriesByType('resource')`
vide) ; deux rendus des mêmes données sont identiques octet pour octet.

## Ce que la mesure a changé — la refonte

**La collecte du trafic interrogeait l'Elasticsearch interne de la gateway.**
C'était une erreur d'architecture, payée trois fois : un motif d'index piégeux,
des noms de champs à deviner, une syntaxe `${...}` qui voulait dire autre chose.

Une NetworkPolicy du cluster n'ouvre cet Elasticsearch **qu'aux pods de la
gateway**. Un agent de CI ne l'atteindra jamais — ni au labo, ni chez un client,
où personne n'expose l'API Data Store à un tiers.

La refonte passe par `GET /transactionalEvents/_count` et `_search`, le contrat
public. Elle **supprime deux dépendances** (`WM_ES_URL`, `WM_ES_INDEX`) au lieu
d'en ajouter, et une permission réseau de moins à négocier.

**Un port-forward masquait le problème depuis le début** : il passe par le
serveur d'API et contourne les NetworkPolicies. Toutes les vérifications
d'Elasticsearch empruntaient un chemin qui n'existe pas pour un client réel dans
le cluster.

## Défauts trouvés en exécutant — dont plusieurs dans ma propre conception

- **`--days` était décoratif** : le document annonçait une fenêtre que les
  agrégations ne respectaient pas. Supprimé plutôt que câblé — `history.json`
  accumule des totaux sur la fenêtre, la rendre réglable ferait cohabiter des
  totaux à 30 et 90 jours dans la même courbe. Un mensonge durable pour un
  mensonge ponctuel.
- **Le trafic non identifié n'était signalé nulle part**, alors que le terrain le
  mesurait comme le cas majoritaire attendu. Aucune tâche ne l'avait dans son
  périmètre : c'est un trou **entre** les périmètres, invisible à toute revue
  par tâche.
- **`no_log` d'Ansible ne masque pas la trace du plugin de connexion** : un
  secret passé par `environment:` sur une tâche `command` fuit en `-vvv`.
  Reproduit, corrigé, contre-épreuve à l'appui.
- **Un test qui passait pour la mauvaise raison** : 16 mutations passées, 15
  détectées, une survivante. Elle rendait sans garde la correction qu'elle
  prétendait protéger.
- **Le script de publication n'acceptait qu'un chemin absolu** — invisible à
  tous les tests manuels, qui en passaient toujours. Trouvé au build #8, avec un
  message d'erreur qui envoyait chercher au mauvais endroit.
- **La page HTML ne fonctionnait pas là où elle était publiée** : une forge
  l'affiche en source, et `file://` bloque `fetch`. Rendue autoportante.

## Quatre questions ouvertes, à trancher avec le client

Par ordre d'importance. Détail et gestes de mesure dans `carto/TERRAIN.md`.

**V5 — l'identification de l'appelant.** `applicationId` vaut `Unknown` sur
**100 %** des événements, y compris authentifiés par clé valide depuis une
Application déclarée. Confirmé par **trois routes indépendantes** (agrégation
Elasticsearch, `_count`, `_search`). Aucune API du catalogue ne porte d'étage
d'identification : il n'existait aucun gabarit fonctionnel à copier. Si le
client est dans le même cas, **la carto répond « on ne sait pas » à « qui
consomme quoi »**. Le produit le dit lui-même — bandeau en alerte, job rouge —
mais c'est la condition de valeur de toute la moitié observée.

**V7 — le plafond de regroupement de `_count`.** Non mesurable sur un labo à
trois APIs. S'il existe et qu'on le franchit, du trafic identifiable bascule
silencieusement dans le résidu « non identifié ». Les volumes par API restent
justes. **Premier point à mesurer chez le client.**

**V4 — les contacts.** `contactEmails` est vide sur toutes les Applications,
donc la vue « qui prévenir » ne rend aucune adresse. C'est le besoin de
communication qui a motivé le sujet : soit peupler le champ à l'enregistrement,
soit brancher une source externe.

**V6 — où publier.** Tranché pour le labo : dépôt git dédié rendu par la forge.
À confirmer côté client, avec le dépôt et le compte qui pousse.

## Gestes exploitant

- **Poser le credential** de la gateway dans Jenkins (identifiant paramétrable,
  `carto-wm-gateway` par défaut) et celui du dépôt de pages
  (`carto-pages-git`). Consigne de pose en tête du Jenkinsfile et du script.
- **Faire tourner ces mots de passe.** C'est la dette assumée du choix
  « identifiants dans Jenkins », imposé parce que le client n'autorise pas
  l'authentification Vault par identité de pod Kubernetes. Le jour où le mot de
  passe change côté gateway, le job passe au rouge avec un message qui distingue
  « credential absent » de « credential refusé » — encore faut-il que quelqu'un
  le lise.
- **Brancher une alerte sur l'échec du job.** C'est elle, et non la rétention,
  qui empêche les trente jours de silence après lesquels l'historique serait
  perdu.
- **Créer le dépôt de publication vierge** chez le client : celui du labo porte
  des traces de mise au point.

## Pièges mesurés — ne pas les redécouvrir

- **Aucun événement transactionnel** tant que la politique de journalisation de
  l'invocation n'est pas active. L'index reste vide, seuls les événements
  d'erreur sont produits. Symptôme : une carto vide qui a l'air valide.
- **`_count` ne rend pas une liste quand rien ne correspond**, mais la chaîne
  `" No records found."`. Itérer dessus parcourt ses caractères.
- **Les paramètres d'un `Jenkinsfile` ne sont enregistrés qu'à la fin** du build
  qui les introduit : le premier build après un ajout ignore les nouvelles
  valeurs.
- **`_cat/indices` compte primaires + répliques** : il annonçait 96 documents là
  où `_count` et `_search` en donnaient 48.
- **`/search/_aggregations` ne traite que les assets**, pas les événements.
- **Un `git stash` sur ce dépôt est partagé** avec les autres sessions.

## Ce qui n'a pas été éprouvé

- Le **rôle Ansible** n'a jamais été déroulé dans un vrai déploiement : gabarits
  rendus et validés, jamais exécutés par `ansible-playbook` sur une cible.
- La **lisibilité en régime sain** n'a été jugée que sur des données fabriquées :
  le labo ne produit qu'une carto dégradée (V5, index de moins d'un jour).
- Le script de publication **ne réessaie pas** après un échec de poussée. Une
  première tentative a échoué sans explication, jamais reproduite depuis.
