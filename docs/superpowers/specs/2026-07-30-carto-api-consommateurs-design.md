---
title: "Carto des API et des consommateurs (spécification)"
type: spec
status: "Design validé le 2026-07-30 ; terrain client à mesurer avant implémentation"
date: 2026-07-30
contexte: client — API Gateway webMethods de production
---

# Carto des API et des consommateurs (spécification)

## Objectif

Le client dispose d'une carto **toujours à jour** de ses APIs et de ses
consommateurs, consultable sans intervention humaine, qui répond à trois
questions :

1. **Qui consomme quoi ?** — le lien API ↔ consommateur, déclaré et réellement
   observé.
2. **Qui dois-je prévenir ?** — la liste complète des consommateurs enregistrés
   sur une API, y compris ceux qui n'ont encore jamais appelé, pour les
   campagnes de communication (dépréciation, changement de contrat, incident).
3. **Comment ma plateforme évolue-t-elle ?** — le nombre d'APIs et de
   consommateurs dans le temps, et la part réellement active.

**Porte de preuve :** le jour de la livraison, un tiers qui n'est pas
l'intégrateur ouvre une URL interne, trouve la liste des consommateurs à
prévenir pour une API donnée, et l'exporte — sans demander quoi que ce soit à
personne.

### Le problème qu'on remplace

Aujourd'hui la carto est régénérée à la main depuis la prod à chaque
intégration d'une API en Dev (~5 mn), et produit un HTML jetable. Le coût des
5 mn n'est pas le vrai problème : le problème est qu'**une carto régénérée à la
main est périmée dès qu'un tiers modifie la prod**, et qu'elle n'existe que
lorsque l'intégrateur la fabrique.

La cause structurelle est que le script courant **fait la collecte et le rendu
d'un seul geste**. Les séparer est la décision centrale de ce design (D1).

## Contraintes arbitrées

- **Accès prod :** un compte technique **lecture seule** peut être créé sur
  l'API Gateway de production, et un job planifié peut s'y connecter.
- **Source des liens :** le trafic réellement observé **et** les
  autorisations déclarées — les deux, voir D2.
- **Exposition :** site statique auto-hébergé sur un serveur web interne.
  Pas de backend, pas de base.
- **Réseau :** on suppose l'intranet client **sans accès internet** → aucun
  CDN, aucune dépendance externe au moment de l'affichage.

## Décisions

### D1 — Séparer la collecte du rendu par un contrat de données

Le job de collecte produit un fichier `carto.json`. Le rendu est un site
statique qui lit ce fichier et **ne touche jamais la production**.

Conséquences recherchées :

- on itère sur le visuel sans retaper le Gateway ;
- le rendu est testable intégralement sur des fixtures ;
- le fichier devient un point d'extension (export tableur, diff, dashboard
  tiers) sans retoucher la collecte.

*Écarté — un service vivant* (backend interrogeant Elasticsearch à la demande) :
impose d'héberger, sécuriser et maintenir un service portant des identifiants
de production en permanence, pour une donnée qui évolue à la semaine.

*Écarté — accélérer le script existant* : traite le symptôme (les 5 mn), pas la
cause (l'artefact jetable, dépendant d'un geste humain).

### D2 — Le déclaré et l'observé sont deux arêtes de première classe

Le croisement des deux est la valeur du produit :

| | Trafic observé | Aucun trafic |
|---|---|---|
| **Déclaré / autorisé** | consommateur actif | **onboardé, pas encore parti en prod ou en sommeil — à prévenir, pas à supprimer** |
| **Non déclaré** | **écart de gouvernance à investiguer** | — |

Les deux cases en gras sont invisibles pour l'une ou l'autre source prise
seule :

- une carto fondée sur le **seul trafic** efface le consommateur enregistré qui
  n'a pas encore appelé — celui-là même qu'il faut prévenir lors d'une
  dépréciation, et qui découvrirait la coupure le jour J ;
- une carto fondée sur la **seule configuration** ne distingue pas un
  consommateur vivant d'un consommateur fantôme, et ne voit jamais un appel non
  autorisé.

### D3 — Une seule requête d'agrégation, jamais d'événements bruts

Le trafic est obtenu par **une agrégation côté serveur** (`terms` croisé
apiId × applicationId) portant le nombre d'appels, la date du dernier appel et
la part de codes d'erreur. Aucun événement unitaire n'est rapatrié.

C'est ce qui rend le job quasi gratuit pour la production, et ce qui le fait
tenir en quelques secondes indépendamment du volume de trafic.

### D4 — La fenêtre affichée est la fenêtre réellement couverte

Fenêtre demandée : **90 jours** glissants, avec sous-totaux à 30 et 7 jours.

Le job lit la date du **plus vieil événement réellement disponible** et inscrit
dans `carto.json` la profondeur effective, que le site affiche.

Motif : si le client purge ses index à 30 jours, une « fenêtre 90 jours » est un
mensonge qui fera conclure « cette API n'a plus de consommateur » à propos d'une
API appelée il y a 45 jours. **On n'affiche jamais une profondeur qu'on n'a
pas.**

### D5 — La table est la vue principale, le graphe est une vue focalisée

Un graphe force-directed de l'ensemble donne une pelote illisible qui
photographie bien et ne sert à personne. La vue par défaut est une **table à
double entrée** filtrable. Le graphe n'apparaît que sur la fiche d'un nœud, à
un saut de voisinage.

### D6 — L'évolution est une donnée, pas un `git diff`

Chaque passage **ajoute une ligne** à `history.json` (quelques centaines
d'octets). Le site en tire des courbes. Les snapshots complets datés restent
archivés pour les questions plus fines.

Motif : personne ne lit un diff JSON en comité.

**Agrégation hebdomadaire à l'affichage** (collecte quotidienne) : un point par
jour donne une série bruitée, illisible en réunion.

### D7 — Rétro-calcul de la courbe, avec sa réserve écrite

Si les APIs et les Applications portent leur date de création dans l'API
d'administration (**à vérifier**, cf. V1), la courbe de croissance des objets
**enregistrés** est rétro-calculée dès le premier passage : le client a sa photo
d'évolution le jour de la livraison, sans attendre des mois d'accumulation.

**Réserve à afficher dans la vue :** cette courbe rétro-calculée est une courbe
de **survivants** — elle ne connaît que les objets existant encore aujourd'hui,
donc elle sous-estime le passé et ne montre aucune disparition. Seule la série
accumulée par les snapshots est exacte, et seulement à partir de la mise en
service. Les deux séries doivent être **visuellement distinguées**, sans quoi la
carto laissera croire que la plateforme n'a jamais perdu un consommateur.

### D8 — Ne jamais écraser une bonne carto par une mauvaise

Le job écrit dans un fichier temporaire, valide le résultat contre un schéma,
et ne bascule qu'en cas de succès. Une montée de version du Gateway qui casse
un champ laisse en place la dernière bonne carto.

### D9 — L'échec est bruyant

Un job de carto qui échoue en silence produit **pire que rien** : une carto
périmée qui a l'air fraîche. Donc : échec → alerte, et le bandeau du site passe
en alerte en affichant l'âge réel des données.

## Contrat de données

### `carto.json`

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-07-30T02:11:00Z",
  "window": {
    "requestedDays": 90,
    "coveredDays": 34,
    "oldestEvent": "2026-06-26T00:00:00Z"
  },
  "apis": [
    { "id": "…", "name": "…", "version": "1.2", "owner": "…",
      "active": true, "createdAt": "…" }
  ],
  "consumers": [
    { "id": "…", "name": "…", "owner": "…", "contact": "…",
      "createdAt": "…" }
  ],
  "edges": [
    { "apiId": "…", "consumerId": "…",
      "declared": true,
      "calls": { "d7": 980, "d30": 4102, "d90": 12430 },
      "lastCall": "2026-07-29T18:02:00Z",
      "errorRate": 0.012 }
  ]
}
```

- `consumers[]` contient **toutes** les Applications enregistrées, y compris
  celles sans aucun trafic.
- `edges[]` contient l'union des liens déclarés et observés. `declared: false`
  signale un appel hors autorisation déclarée ; `calls` à zéro signale un
  déclaré inactif.
- **Rien d'autre.** Les APIs orphelines, les consommateurs fantômes, les tops
  et les compteurs sont **déduits au rendu**. Les stocker garantirait deux
  vérités qui divergeront.

Ordre de grandeur attendu : quelques milliers d'arêtes, quelques centaines de
Ko — un navigateur absorbe cela sans difficulté.

### `history.json`

Une ligne ajoutée par passage :

```json
{ "date": "2026-07-30", "apis": 128, "consumersRegistered": 96,
  "consumersActive": 71, "calls": 18402113 }
```

## Les vues

Un seul fichier `index.html` **autonome** — JS et CSS en ligne, zéro
dépendance externe. Trois fichiers publiés au total : `index.html`,
`carto.json`, `history.json`.

1. **Table à double entrée** *(vue par défaut)* — par API → ses consommateurs,
   ou par consommateur → ses APIs. Recherche instantanée, tri par volume ou par
   date de dernier appel, statut déclaré/observé visible sur chaque ligne.
2. **Annuaire des consommateurs** — la liste complète des consommateurs
   enregistrés, avec propriétaire, contact, APIs souscrites et date
   d'enregistrement. Filtrable par équipe. **Support des campagnes de
   communication.**
3. **Fiche** — un nœud, son voisinage à un saut en graphe, ses chiffres, et
   « la liste des gens à prévenir » (déclarés ∪ observés, dédoublonnés,
   exportable).
4. **Signaux** — APIs sans aucun appel sur la fenêtre, consommateurs déclarés
   inactifs, trafic non déclaré, taux d'erreur anormaux.
5. **Évolution** — courbes hebdomadaires : APIs, consommateurs enregistrés,
   consommateurs actifs ; delta depuis le mois précédent ; série rétro-calculée
   distinguée de la série mesurée (D7).
6. **Bandeau permanent** — date de collecte et fenêtre réellement couverte, en
   alerte si les données sont périmées (D9).

**Export CSV** côté navigateur, une ligne par lien : la demande de tableur
arrivera, autant qu'elle soit déjà servie.

## Exploitation

- Le job publie les fichiers sur le serveur web interne. Idempotent : il
  écrase, rien à nettoyer.
- Chaque `carto.json` est commité dans un dépôt git → historique et diffs sans
  code supplémentaire.
- **Entretien réel, à annoncer au client** : la rotation du compte lecture
  seule ; la surveillance de l'échec du job (D9) ; la validation de schéma qui
  protège des montées de version du Gateway (D8).

## Découpage et tests

- **Collecteur** : script autonome (Python), testé sur des **fixtures** — une
  réponse d'API d'administration et une réponse d'agrégation capturées une
  fois. Toute la logique et tout le rendu se testent **sans toucher la
  production**.
- **Ansible** déploie le script et pose la planification. Il implémente, il
  n'orchestre pas la logique métier.
- **Sonde de contrat** : le `carto.json` produit valide son JSON Schema
  (sonde, pas orchestration).
- **Mode `--dry-run`** : tire contre la prod, rapporte les compteurs, ne publie
  rien.

## À vérifier sur le terrain client avant implémentation

Ces points sont **supposés**, non mesurés. Chacun peut invalider une partie du
design.

- **V1 —** les APIs et Applications portent-elles une date de création
  exploitable dans l'API d'administration ? *(sinon : D7 tombe, la courbe
  d'évolution démarre au premier snapshot)*
- **V2 —** quelle est la **rétention réelle** des index d'analytics ?
  *(détermine la fenêtre effectivement affichable, D4)*
- **V3 —** les chemins exacts de l'API d'administration et le shape de la
  requête d'agrégation : **à lire dans le Swagger admin livré dans le
  conteneur**, jamais devinés.
- **V4 —** les Applications portent-elles un contact exploitable, ou faut-il
  une source externe pour les campagnes de communication ?
- **V5 —** l'événement de trafic porte-t-il de quoi identifier l'application
  appelante dans **tous** les cas ? *(un appel anonyme ou non identifié doit
  apparaître comme tel, pas être silencieusement perdu)*
- **V6 —** cible de publication : serveur web interne, chemin, et mécanisme de
  dépôt.

## Hors périmètre

- La cartographie des backends et dépendances aval (API → système cible).
  Écartée pour ce lot ; le contrat de données peut l'accueillir plus tard sans
  rupture.
- Toute écriture sur la production. Le compte est en lecture seule et le reste.
