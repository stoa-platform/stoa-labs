---
title: "ADR-087 — La parité des deux moteurs, prouvée par l'état : même .promote.yml, même archive, un snapshot normalisé par moteur, un diff sous registre mécanique des écarts assumés — et une parité qui sait rougir (mutation d'un moteur ⇒ rouge nommé)."
sidebar_label: "ADR-087 : la parité des moteurs (G8)"
status: "Acté et prouvé LIVE le 2026-08-27 contre la gateway webMethods réelle : scripts/test-parity-moteurs.sh 29/0 ×2 (rejouabilité comprise), make lint-ci 8/8. La porte a PRIS dès sa première exécution : l'alias promote de labctl seedait passSecurityHeaders=true + optimizationTechnique=None (la shape du PROXY self-service) là où le rôle laisse le défaut produit — un pass-through de headers de sécurité DIVERGENT sur palier vierge, corrigé (création promote minimale, projection proxy inchangée, test unitaire ancré). Contre-épreuves : labctl muté (scope sauté) ⇒ parité ROUGE 5 écarts nommés ; rôle muté ⇒ ROUGE 5 écarts nommés."
maturite_technique: "✅ Verbe de relecture labctl promote --action verify (lecture seule, 5 tests httptest dont la preuve GET-only) ; harnais live keepalive-aware (fresh_window : le trial expire ~25 min, on ne lance jamais le verbe en fin de fenêtre ; snapshot fail-closed SNAPSHOT_UNREADABLE). Le registre mécanique est CONSOMMÉ par le harnais : un écart non listé ne PEUT PAS passer."
date: 2026-08-27
adr_number: 87
note: "Solde la contrepartie de la décision n°6 du GOAL (option (c), deux moteurs iso-sémantiques — 'le prix est payé, pas éludé'). Consomme ADR-083 (le verbe archive et ses deux moteurs), ADR-079 (les sémantiques spike-pinnées que la parité compare)."
lié: "[[adr-083-verbe-archive-deux-moteurs]], [[adr-079-deploiement-promotion-multienv-import-archive]], [[adr-086-parcours-demandeur-pr-tableau-de-bord]]"
---

# ADR-087 — La parité des deux moteurs, prouvée (G8)

**Statut :** Acté, prouvé live 29/0 ×2 — le dernier jalon du GOAL
`cd-promotion-5-envs` est fermé (G1..G8 faits).

**Lié à :** [[adr-083-verbe-archive-deux-moteurs]], [[adr-086-parcours-demandeur-pr-tableau-de-bord]].

---

## Contexte

La décision n°6 du GOAL (2026-08-26) maintient **deux moteurs iso-sémantiques**
du verbe archive : `ansible/roles/apim_promote_api` (chemin client, celui qui a
tourné E2E) et `labctl promote` (chemin lab/gouvernance, celui des pipelines),
pilotés par **le même** `.promote.yml`. Le GOAL en fixait le prix : « sans
G8, ce ne sont pas deux moteurs, mais deux comportements dont on espère qu'ils
coïncident. » G5 avait éprouvé chaque moteur **séparément** (assets distincts,
mêmes assertions) ; personne n'avait encore comparé les **états** qu'ils
produisent.

## Décision

1. **Le verdict de la parité est l'ÉTAT, jamais les logs.** Un snapshot
   normalisé par moteur — API par GUID (record complet), graphe de politiques
   (shapes mesurées : `/policies/{id}` → `policyEnforcements[].enforcements[]
   .enforcementObjectId` → `/policyActions/{id}`), aliases per-env (endpoint,
   credential, générique), scope-mapping, sonde data-plane — et un diff de
   feuilles entre les deux.

2. **Le registre mécanique EST la définition de l'iso-sémantique.**
   `scripts/testdata/parity-ecarts.txt` (lignes `state`/`artifact`, TAB,
   raison obligatoire) est **consommé** par le harnais : les chemins listés
   sont retirés des snapshots avant diff, les motifs listés normalisent les
   artefacts avant comparaison. Tout le reste doit être identique — un écart
   inconnu ne peut pas passer, par construction.

3. **La parité doit savoir rougir** (motif F1). Le harnais mute chaque moteur
   à tour de rôle (copie patchée, ancre vérifiée : le scope-mapping sauté) et
   exige le ROUGE avec le champ muté nommé. Une parité qui ne rougit jamais ne
   prouve rien.

4. **La porte se rejoue par les deux moteurs, sans écrire** : côté rôle
   `promote-api-verify.yml` (le `--tags verify`), côté Go le NOUVEAU
   `labctl promote --action verify` (miroir de `tasks/verify.yml` : API par
   guid épinglé présente+active+nom conforme, valeur d'alias backend de l'env,
   smoke optionnel ; `VERIFY_REFUSED` avant tout réseau sans guid). Le
   snapshot avant/après verify est identique — prouvé à chaque run.

## Ce que la porte a pris (le jour même)

**`passSecurityHeaders` divergent sur palier vierge.** À la création de
l'alias backend, labctl POSTait la shape du **proxy self-service**
(`passSecurityHeaders: true`, `optimizationTechnique: "None"` — spike
2026-07-09, où le pass-through Basic est REQUIS) ; le rôle POSTe la shape
minimale (défaut produit : pas de pass-through). Sur un palier vierge, le
même manifeste produisait donc deux backends qui ne reçoivent PAS les mêmes
headers de sécurité selon le moteur qui a seedé l'alias. Corrigé dans labctl :
la création **promote** redevient minimale (identique au rôle), la projection
proxy garde sa shape prouvée (`ensureEndpointAliasValueWith`), un test
unitaire ancre l'interdiction. C'est exactement le genre d'écart que G8 existe
pour attraper — il a été attrapé à la **première** exécution de la porte.

## Le registre des écarts assumés

### Écarts d'ÉTAT (exclus du diff — mesurés le 2026-08-27)

| Chemin | Raison mesurée |
|---|---|
| `.aliases[].id` | identité générée par le POST du moteur créateur ; le binding `${alias}` résout NOM→id au déploiement, l'id n'est jamais référencé (ids distincts observés, data-plane identique) |
| `.scope.id` | identité générée par `POST /scopes` ; le mapping lie l'API par GUID et l'AS par NOM |
| `.aliases[].description` | auto-étiquette du moteur créateur (« apim_promote_api : … » vs « labctl promote: … ») — dit QUI a créé le record, aucun effet runtime |
| `.scope.scopeDescription` | même auto-étiquette, côté scope-mapping |

### Écarts d'ARTEFACT (normalisés avant comparaison)

| Motif | Raison mesurée |
|---|---|
| `BuildTimestamp` de l'ACDL | horodatage d'export posé par le PRODUIT — varie à chaque `GET /archive` (21:20:44 vs 21:20:48 à 4 s d'écart) |
| ordre des clés JSON | les deux sanitizers ré-écrivent le routing avec l'ordre de leur runtime (dict python vs map Go) — comparaison en DOCUMENTS (`jq -S`), l'ordre des clés n'est pas un contenu |

### Écarts de MOTEUR (hors état — assumés, pas des champs de snapshot)

1. **Digest sha256** : vérifié par le rôle (`ARCHIVE_DIGEST_REQUIRED` hors
   authoring, degrés D0/D2) et par le CI (`deploy-pin.sh`) — **jamais par
   labctl** (côté Go les octets sont gardés par l'ArchiveTaintCheck + le GUID
   iso ; le digest appartient à la chaîne qui fetch l'artefact).
2. **Voie du terminus** : moteur ansible SEUL (G7,
   `COMBINAISON_NON_SUPPORTEE` pour labctl vers le dernier palier).
3. **`apim_ss_authoring_env`** : default de rôle surchargeable aux degrés
   D0/D2 (l'opérateur joue le play lui-même) vs affectation sèche côté CI
   (`deploy-pin.sh`) — dissymétrie assumée et commentée dans le rôle.
4. **Acquisition de l'auth admin** : rôle via `apim_common/secrets.yml`
   (Vault, fallback PoC) ; labctl via `targets.yaml` (ou OAuth2). Même
   destination, chaînes de custody distinctes — chacune prouvée chez elle.

**Règle d'entretien** : quand la parité rougit, on MESURE l'écart ; s'il est
volatil et sans effet runtime, il entre au registre AVEC sa raison ; s'il est
sémantique, on répare le moteur fautif (comme `passSecurityHeaders`) — jamais
d'exclusion de confort.

## Preuve (2026-08-27, gateway webMethods réelle + Vault du lab)

| Phase | Épreuve | Résultat |
|---|---|---|
| 1 | EXPORT ×2 — même API source, artefacts comparés entrée par entrée (jq -S + registre) | même TOC (5 entrées), contenu identique |
| 2-3 | IMPORT ×2 — palier remis à VIERGE entre les deux, MÊME archive (celle du rôle, digest pinné), Vault pour cred_alias | `PROMOTE_CONFIRMED` ×2 |
| 4 | **LA PORTE** : diff des snapshots sous registre | **0 écart hors registre** — GUID épinglé actif, dp `/backend/rec/ping` des deux côtés |
| 5 | VERIFY ×2 (`--tags verify` rôle, `--action verify` labctl) | `PROMOTE_CONFIRMED` ×2, snapshot avant/après IDENTIQUE |
| 6a | labctl MUTÉ (scope sauté, copie patchée, ancre vérifiée) | parité **ROUGE**, 5 écarts nommés `scope.*` |
| 6b | rôle MUTÉ (même mutation, autre sens) | parité **ROUGE**, 5 écarts nommés |
| — | Rejouabilité : run complet ×2 | **29/0 puis 29/0** |
| — | `make lint-ci` (harnais shellchecké, branché [2/8]) | 8/8 |

Pièges mesurés en route : le trial wM expire ~25 min et le keepalive recycle à
23 min — un run lancé tard voyait la gateway mourir **en plein import**
(`fresh_window` attend le recyclage quand l'uptime ≥ 12 min, motif G7) ; un
snapshot pris pendant un recyclage était un état fantôme SILENCIEUX
(fail-closed `SNAPSHOT_UNREADABLE` désormais).

## Conséquences

- La dette « régime à deux moteurs = dette ouverte » de `DELIVERY-PROCESS.md`
  est soldée : l'iso-sémantique n'est plus une promesse, c'est une porte
  rejouable dont la définition exacte vit dans un registre versionné.
- Tout changement futur d'un moteur qui altère l'état produit se voit : la
  porte est dans `lint-ci` pour la syntaxe et se rejoue live à la demande
  (`ENVIRONNEMENTS.md` § G8) — le réflexe attendu avant de toucher
  `apim_promote_api` ou `promote.go` est de la rejouer.
