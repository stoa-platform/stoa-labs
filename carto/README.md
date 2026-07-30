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
en fin de rôle qu'une collecte en `--dry-run` voit bien des APIs.

Le rôle **ne porte aucun secret**. Les identifiants (`WM_ADMIN_URL`,
`WM_USER`, `WM_PASS`, `WM_ES_URL`, `WM_ES_INDEX`, variable `carto_env`) sont
vides par défaut et doivent être fournis à l'exécution depuis le coffre,
comme le reste de la chaîne du projet. La tâche qui écrit le gabarit
`carto-collect.sh.j2` (et celle qui vérifie la collecte) est posée avec
`no_log: true` : aucun identifiant ne doit pouvoir se retrouver dans une
sortie Ansible, un journal, ou un argument de ligne de commande. L'enveloppe
elle-même écrit toute sortie de la collecte — qui peut contenir des éléments
d'infrastructure — dans un fichier, jamais sur la sortie standard du
planificateur.

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
  un fichier root-only (`chmod 0600`), jamais sur la sortie standard.

## Diagnostic

| Symptôme | Cause | Geste |
|---|---|---|
| Bandeau orange « données périmées » | le job échoue depuis N jours | lire `last-failure.log` (root, 0600) |
| `publication refusee` | collecte dégradée, ancienne carto conservée | comparer les compteurs du `--dry-run` |
| `agregation tronquee` | plus d'objets que `BUCKET_SIZE` | augmenter `BUCKET_SIZE` dans `analytics.py` |
| `fenêtre couverte` < demandée | rétention des index plus courte | normal, c'est la vérité (spec D4) |
| Page vide, bandeau d'erreur | page ouverte en `file://` | passer par le serveur web |
| **Zéro arête et fenêtre couverte à zéro alors que le trafic existe** | `ES_INDEX` mal écrit : un tiret avant l'étoile (`..._transactionalevents-*`) ne matche **aucun** index — le motif réel est `<type>_<horodatage>-<séquence>`, sans tiret avant l'étoile (`..._transactionalevents*`) | relire `ES_INDEX` contre `TERRAIN.md` (V3) ; la collecte publie sans erreur une carto où personne n'appelle personne — c'est le mode de défaillance le plus sournois du produit |
| Index des événements transactionnels vide, seuls les événements d'erreur existent | sur webMethods 10.15, la policy système `GlobalLogInvocationPolicy` (Log Invocation) n'est pas active — sans elle, aucune API n'écrit jamais d'événement transactionnel, quel que soit le trafic | vérifier `GET /rest/apigateway/policies` et activer la policy (voir `TERRAIN.md`, V3) ; symptôme identique au précédent : une carto vide qui a l'air valide |

## Ce qu'il faut entretenir

- La rotation du compte technique lecture seule.
- La surveillance de l'échec du job : un échec silencieux publierait une carto
  périmée qui a l'air fraîche.
- À chaque montée de version du Gateway : rejouer `capture-fixtures.sh`,
  relancer les tests, mettre à jour `TERRAIN.md` si un champ a bougé.
- **Question ouverte prioritaire (`TERRAIN.md`, V5) : vérifier chez le client
  que l'identification de l'application appelante (`ES_APP_FIELD`,
  `applicationId`) est effective dans les événements transactionnels de LEUR
  gateway.** Dans le labo de mesure de ce projet, ce champ valait `Unknown`
  sur 100 % du trafic authentifié malgré dix tentatives de configuration —
  sans cette identification, la carto observée n'a pas de dimension
  consommateur, quel que soit le reste du pipeline de collecte.
