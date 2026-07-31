# Carto des API et des consommateurs

Job planifié en **lecture seule** qui produit `carto.json` + `history.json`, et
un site statique autonome qui les lit. Le rendu ne touche jamais la production.

Spec : `docs/superpowers/specs/2026-07-30-carto-api-consommateurs-design.md`
Terrain mesuré chez le client : `TERRAIN.md`

## Comment le trafic est lu (refonte du 2026-07-31)

Le collecteur passe par l'**API publique de la gateway**
(`GET /transactionalEvents/_count` et `/_search`), plus par son Elasticsearch
interne : `WM_ES_URL` et `WM_ES_INDEX` **n'existent plus**. Ce n'était pas un
choix esthétique — une NetworkPolicy du cluster n'ouvre cet Elasticsearch
qu'aux pods de la gateway, et aucun client n'ouvrira son API Data Store à un
tiers ; le job n'était donc exécutable nulle part ailleurs qu'à la main.

Il n'énumère **aucun événement** pour mesurer un volume : un comptage par
application (dont la réponse est déjà regroupée par API, ce qui donne toutes
ses arêtes en une requête), un comptage par API pour le total, et le trafic
non attribué d'une API se déduit par soustraction. Le coût est borné par la
**configuration** — nombre d'APIs et d'applications — jamais par le volume de
trafic (formule et mesure : `TERRAIN.md`, V7).

Deux informations demandent malgré tout de lire un événement ou un statut :
la **date du dernier appel** d'une arête (une page `size=1`, l'ordre de
`_search` étant décroissant) et le **taux d'erreur** (un second comptage
filtré sur `status=SUCCESS`). `status` n'étant pas un paramètre documenté, une
**sonde** vérifie à chaque collecte qu'il est toujours honoré : sans elle, sa
disparition mettrait le taux d'erreur de toutes les arêtes à zéro sans un mot.
La date du dernier appel du trafic **non identifié** reste `null` : aucun
filtre ne sait exprimer « tout sauf ces applications-là », et le contrat
accepte `lastCall` nul — l'inventer serait pire.

## Lancer à la main

    python3 -m carto.collect --out /var/www/carto              # publie
    python3 -m carto.collect --out /tmp/x --dry-run            # ne publie rien
    python3 -m carto.collect --out /tmp/x --from-fixtures carto/tests/fixtures

## Tests

    python3 -m unittest discover -s carto/tests -t . -v

Aucune dépendance, aucun accès réseau : tout tourne sur les fixtures.

## Déploiement (Ansible)

Le rôle `carto/ansible/roles/carto_collect/` installe un compte de service
dédié (sans shell), dépose le paquet dans `{{ carto_install_dir }}/carto/`
(`carto_install_dir` est le **parent** du paquet Python, pas le paquet
lui-même — le code s'invoque donc toujours par `python3 -m carto.collect`,
exactement comme depuis le dépôt), pose l'enveloppe d'exécution
`carto-collect.sh`, planifie une exécution quotidienne par `cron`, et vérifie
en fin de rôle qu'une collecte en `--dry-run` voit bien des APIs, **des arêtes,
une fenêtre couverte non nulle, et un trafic majoritairement rattaché à des
consommateurs identifiés** — les quatre assertions sont nécessaires :
`apis=0` seul laisse passer le mode de défaillance le plus sournois du produit
(dernières lignes du tableau de diagnostic ci-dessous), où l'inventaire est lu
mais aucun événement ne l'est ; et les trois premières laissent passer le pire
cas *réellement mesuré* (`TERRAIN.md`, V5), où la collecte sort
`trafic_non_identifie=100.0%` — déploiement vert, page qui crie. Le seuil
(`carto_seuil_non_identifie_pct`, 50 %) est celui du rendu
(`SEUIL_NON_IDENTIFIE`) : les deux se modifient ensemble.

Le rôle **ne porte aucun secret**. Les identifiants (`WM_ADMIN_URL`,
`WM_USER`, `WM_PASS`, variable `carto_env`) sont vides par défaut et doivent être fournis à l'exécution depuis le coffre,
comme le reste de la chaîne du projet. Seule la tâche qui écrit le gabarit
`carto-collect.sh.j2` est posée avec `no_log: true` — c'est elle qui manipule
réellement les identifiants. La tâche Ansible de vérification, elle,
n'utilise **jamais** `environment:` pour repasser `carto_env` : elle appelle
`carto-collect.sh --verify`, qui porte déjà les identifiants en interne
(injectés par `export` dans le fichier rendu). Ce choix n'est pas cosmétique :
passer des secrets par `environment:` sur une tâche `command` les expose en
clair dans la trace `EXEC` du plugin de connexion dès qu'on relance en
`-vvv` — un geste courant en diagnostic d'échec — et `no_log` **ne protège
pas** cette trace-là (il masque seulement le résultat affiché de la tâche).
L'enveloppe elle-même écrit toute sortie de la collecte — qui peut contenir
des éléments d'infrastructure — dans un fichier, jamais sur la sortie
standard du planificateur.

**Cible de publication (`carto_web_root`, V6) : non mesurée.** Aucun
mécanisme de dépôt/publication n'a été sondé sur le cluster de labo de ce
projet — la valeur par défaut (`/var/www/carto`) est neutre et **ne
correspond à aucun hôte réel**. La cible réelle (chemin, serveur web, éventuel
reverse-proxy) est un arbitrage à faire avec le client, pas une valeur à
déduire de ce dépôt.

### Règle qui justifie l'enveloppe d'exécution

Un job de carto qui échoue en silence produit **pire que rien** : une carto
périmée qui a l'air fraîche. `carto-collect.sh` :

- alerte systématiquement en cas d'échec (`carto_alert_command`, par défaut un
  `logger` local — à remplacer par le canal d'astreinte du client) ;
- laisse en place la dernière carto publiée avec succès (aucune publication
  partielle n'écrase la précédente) ;
- écrit le journal d'échec dans `{{ carto_install_dir }}/last-failure.log`,
  un fichier appartenant au compte de service (`carto_user`) et restreint
  (`chmod 0600`), jamais sur la sortie standard ;
- **efface ce journal au prochain passage réussi** : sa seule présence
  signale donc un échec non résolu, jamais un résidu d'un incident déjà
  corrigé — un journal qui traîne indéfiniment produirait le même faux
  signal d'alarme que ce que cette enveloppe combat par ailleurs.

## Diagnostic

| Symptôme | Cause | Geste |
|---|---|---|
| Bandeau orange « données périmées » | le job échoue depuis N jours | lire `last-failure.log` (compte de service, 0600) ; s'il est absent, le dernier passage a réussi |
| `publication refusee` | collecte dégradée, ancienne carto conservée | comparer les compteurs du `--dry-run` |
| `comptages contradictoires` | la gateway s'est contredite entre deux requêtes d'une même collecte (total d'une API inférieur à la somme de ses applications) | relancer ; si ça persiste, c'est la gateway qui n'est pas cohérente avec elle-même — ne pas rogner le résidu à zéro pour faire passer |
| `le parametre \`status\` n'est plus honore` | ce paramètre n'est pas documenté ; une montée de version l'a peut-être retiré | sans lui le taux d'erreur de **toutes** les arêtes serait nul par construction : la sonde refuse de publier plutôt que de le laisser mentir. Voir `TERRAIN.md` V3 |
| `deux applications portent le nom …` | la dimension consommateur s'interroge par **nom** d'application, et le filtre de la gateway ignore la casse | renommer l'une des deux côté gateway ; leur trafic serait sinon compté deux fois |
| `fenêtre couverte` < demandée | pas d'événement plus ancien que ça dans la gateway | normal, c'est la vérité (spec D4) — attention, ce n'est PAS la rétention configurée, c'est l'âge du plus vieil événement encore présent |
| Page vide, bandeau d'erreur | page ouverte en `file://` | passer par le serveur web |
| Bandeau en alerte « X % des appels ne sont rattachés à aucun consommateur identifié » | la gateway ne renseigne pas l'application appelante dans ses événements (`applicationName` = `Unknown`) — ce trafic est le **résidu** : total de l'API moins la somme de ses applications identifiées | c'est la vérité, pas un bug du collecteur : la carto reste juste sur les APIs, sa dimension consommateur ne l'est pas. Voir `TERRAIN.md` V5 et la question ouverte prioritaire ci-dessous. Le seuil d'alerte est de 50 % (`SEUIL_NON_IDENTIFIE` dans `render/index.html`) |
| Bandeau « version de schéma », page vide, **document plus ancien que la page** | fenêtre normale d'après-déploiement : le rôle dépose `index.html` et `collect/` ensemble, mais le `carto.json` déjà publié n'est réécrit qu'à la prochaine exécution planifiée | attendre la collecte suivante, ou la déclencher (`carto-collect.sh`). Le refus est volontaire : un document de version 1 lu par la page de version 2 dégraderait en silence (bloc des objets disparus vide, fantômes réintégrés à l'annuaire, part non identifiée en gris) |
| Bandeau « version de schéma », page vide, **document plus récent que la page** | `carto.json` produit par un collecteur plus récent que la page | redéployer `index.html` en même temps que `collect/` — le rôle Ansible dépose les deux ensemble |
| **Zéro arête et fenêtre couverte à zéro alors que le trafic existe** | sur webMethods 10.15, la policy système `GlobalLogInvocationPolicy` (Log Invocation) n'est pas active — sans elle, aucune API n'écrit jamais d'événement transactionnel, quel que soit le trafic | vérifier `GET /rest/apigateway/policies` et activer la policy (voir `TERRAIN.md`, V3). C'est **le mode de défaillance le plus sournois du produit** : la collecte publie sans erreur une carto où personne n'appelle personne. Il a survécu à la refonte du 2026-07-31 — il ne dépend pas de la façon de lire les événements, mais du fait que la gateway les écrive |
| Part de trafic non identifié anormalement haute sur un catalogue à beaucoup d'APIs | possible plafond de regroupement de `_count`, non mesurable sur le labo (trois APIs) | mesurer le plafond (`TERRAIN.md`, V7) avant de conclure que les consommateurs ne sont pas identifiés |

## Ce qu'il faut entretenir

- La rotation du compte technique lecture seule.
- La surveillance de l'échec du job : un échec silencieux publierait une carto
  périmée qui a l'air fraîche.
- À chaque montée de version du Gateway : rejouer `capture-fixtures.sh` (il
  capture les **quatre** fixtures — inventaire, formes brutes des deux routes
  d'événements, et sortie du collecteur — avec les seuls accès
  d'administration), relancer les tests, mettre à jour `TERRAIN.md` si quelque
  chose a bougé. `observed.json` n'est pas une capture brute : son bloc
  `_meta`, qui distingue le mesuré du substitué, est à réécrire à la main sur
  la nouvelle capture — le script le rappelle à la fin de son exécution.
- **Question ouverte prioritaire (`TERRAIN.md`, V5) : vérifier chez le client
  que l'identification de l'application appelante est effective dans les
  événements transactionnels de LEUR gateway.** Dans le labo de mesure de ce
  projet, `applicationName` valait `Unknown` sur 100 % du trafic authentifié
  malgré dix tentatives de configuration — re-vérifié le 2026-07-31 par l'API
  publique, même verdict. Sans cette identification, la carto observée n'a pas
  de dimension consommateur, quel que soit le reste du pipeline de collecte.
- **Second point à mesurer chez le client (`TERRAIN.md`, V7) : le plafond de
  regroupement de `_count`.** Ce labo n'a que trois APIs ; impossible d'y
  établir combien de lignes cette route accepte de rendre. Un plafond franchi
  ferait basculer du trafic identifiable dans la part « non identifiée ».
