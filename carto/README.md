# Carto des API et des consommateurs

Job planifié en **lecture seule** qui produit `carto.json` + `history.json`, et
un site statique autonome qui les lit. Le rendu ne touche jamais la production.

Spec : `docs/superpowers/specs/2026-07-30-carto-api-consommateurs-design.md`
Terrain mesuré chez le client : `TERRAIN.md`

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
en fin de rôle qu'une collecte en `--dry-run` voit bien des APIs, **des arêtes
et une fenêtre couverte non nulle** — les trois assertions sont nécessaires :
`apis=0` seul laisse passer le mode de défaillance le plus sournois du produit
(dernières lignes du tableau de diagnostic ci-dessous), où l'inventaire est lu
mais aucun événement ne l'est.

Le rôle **ne porte aucun secret**. Les identifiants (`WM_ADMIN_URL`,
`WM_USER`, `WM_PASS`, `WM_ES_URL`, `WM_ES_INDEX`, variable `carto_env`) sont
vides par défaut et doivent être fournis à l'exécution depuis le coffre,
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
| `agregation tronquee` | plus d'objets que `BUCKET_SIZE` | augmenter `BUCKET_SIZE` dans `analytics.py` |
| `fenêtre couverte` < demandée | rétention des index plus courte | normal, c'est la vérité (spec D4) |
| Page vide, bandeau d'erreur | page ouverte en `file://` | passer par le serveur web |
| Bandeau en alerte « X % des appels ne sont rattachés à aucun consommateur identifié » | la gateway ne renseigne pas l'application appelante dans ses événements (`applicationId` = `Unknown`) | c'est la vérité, pas un bug du collecteur : la carto reste juste sur les APIs, sa dimension consommateur ne l'est pas. Voir `TERRAIN.md` V5 et la question ouverte prioritaire ci-dessous. Le seuil d'alerte est de 50 % (`SEUIL_NON_IDENTIFIE` dans `render/index.html`) |
| Bandeau « version de schéma », page vide, **document plus ancien que la page** | fenêtre normale d'après-déploiement : le rôle dépose `index.html` et `collect/` ensemble, mais le `carto.json` déjà publié n'est réécrit qu'à la prochaine exécution planifiée | attendre la collecte suivante, ou la déclencher (`carto-collect.sh`). Le refus est volontaire : un document de version 1 lu par la page de version 2 dégraderait en silence (bloc des objets disparus vide, fantômes réintégrés à l'annuaire, part non identifiée en gris) |
| Bandeau « version de schéma », page vide, **document plus récent que la page** | `carto.json` produit par un collecteur plus récent que la page | redéployer `index.html` en même temps que `collect/` — le rôle Ansible dépose les deux ensemble |
| **Zéro arête et fenêtre couverte à zéro alors que le trafic existe** | `ES_INDEX` mal écrit : un tiret avant l'étoile (`..._transactionalevents-*`) ne matche **aucun** index — le motif réel est `<type>_<horodatage>-<séquence>`, sans tiret avant l'étoile (`..._transactionalevents*`) | relire `ES_INDEX` contre `TERRAIN.md` (V3) ; la collecte publie sans erreur une carto où personne n'appelle personne — c'est le mode de défaillance le plus sournois du produit |
| Index des événements transactionnels vide, seuls les événements d'erreur existent | sur webMethods 10.15, la policy système `GlobalLogInvocationPolicy` (Log Invocation) n'est pas active — sans elle, aucune API n'écrit jamais d'événement transactionnel, quel que soit le trafic | vérifier `GET /rest/apigateway/policies` et activer la policy (voir `TERRAIN.md`, V3) ; symptôme identique au précédent : une carto vide qui a l'air valide |

## Ce qu'il faut entretenir

- La rotation du compte technique lecture seule.
- La surveillance de l'échec du job : un échec silencieux publierait une carto
  périmée qui a l'air fraîche.
- À chaque montée de version du Gateway : rejouer `capture-fixtures.sh` (il
  capture les **quatre** fixtures — inventaire, agrégation et plus vieil
  événement — et exige donc `WM_ES_URL`/`WM_ES_INDEX` en plus des accès
  d'administration), relancer les tests, mettre à jour `TERRAIN.md` si un champ
  a bougé. `aggregation-d90.json` n'est pas une capture brute : son bloc
  `_meta`, qui distingue le mesuré du substitué, est à réécrire à la main sur
  la nouvelle capture — le script le rappelle à la fin de son exécution.
- **Question ouverte prioritaire (`TERRAIN.md`, V5) : vérifier chez le client
  que l'identification de l'application appelante (`ES_APP_FIELD`,
  `applicationId`) est effective dans les événements transactionnels de LEUR
  gateway.** Dans le labo de mesure de ce projet, ce champ valait `Unknown`
  sur 100 % du trafic authentifié malgré dix tentatives de configuration —
  sans cette identification, la carto observée n'a pas de dimension
  consommateur, quel que soit le reste du pipeline de collecte.
