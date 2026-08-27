# HANDOFF — G8 : la parité des deux moteurs, prouvée par l'état

**Session du 2026-08-27.** Branche `provision/probe-dev`, lot G8 (spec, plan,
8 commits). ADR-087 ; parcours opérateur `ENVIRONNEMENTS.md` § « La parité des
deux moteurs (G8) » ; `DELIVERY-PROCESS.md` : la dette « deux moteurs » est
**soldée**. **GOAL `cd-promotion-5-envs` : G1..G8 TOUS FAITS** — restent
uniquement les cinq décisions client (politique, pas construction).

| Porte | Nature | Résultat |
|---|---|---|
| Parité d'ARTEFACT (export ×2, même API source) | live, gateway réelle | même TOC (5 entrées), contenu identique entrée par entrée (jq -S + registre) |
| **LA porte** : import ×2 à archive égale, palier remis à vierge, diff des snapshots | live | **0 écart hors registre** — API/policies/actions/aliases (cred Vault compris)/scope/data-plane |
| Rejouable par les DEUX moteurs | live | `promote-api-verify.yml` + `labctl promote --action verify` → `PROMOTE_CONFIRMED` ×2, snapshot avant/après IDENTIQUE |
| Contre-épreuve F1 ×2 | live | labctl muté (scope sauté) ⇒ ROUGE 5 écarts nommés ; rôle muté ⇒ ROUGE idem |
| `scripts/test-parity-moteurs.sh` complet | live ×2 | **29/0 puis 29/0** (rejouabilité) |
| `labctl promote --action verify` | hors-ligne | 5 tests httptest (dont preuve GET-only, `VERIFY_REFUSED` avant tout réseau) |
| `make lint-ci` | intégral | 8/8 (harnais shellchecké, branché [2/8]) |

## Ce qui est livré

1. **`labctl promote --action verify`** (lecture seule) — miroir de
   `tasks/verify.yml` : API par guid épinglé présente+active+nom conforme,
   `VerifyEndpointAliasValue` (ALIAS_DRIFT/ALIAS_MISSING), smoke optionnel.
2. **`scripts/test-parity-moteurs.sh`** — la porte : export ×2, import ×2 à
   archive égale (palier vierge entre les deux), snapshot normalisé (shapes
   produit MESURÉES : `/policies/{id}` → `policyEnforcements[].enforcements[]
   .enforcementObjectId` → `/policyActions/{id}`), diff de feuilles sous
   registre, verify ×2, mutations ×2 attendues rouges.
3. **`scripts/testdata/parity-ecarts.txt`** — le registre MÉCANIQUE : lignes
   `state`/`artifact` TAB-séparées avec raison obligatoire, CONSOMMÉ par le
   harnais. Un écart non listé rougit par construction.
4. **ADR-087** — la décision, le registre humain complet (écarts d'état,
   d'artefact, et de MOTEUR : digest rôle/CI jamais labctl, terminus
   ansible-only, `apim_ss_authoring_env` D0/D2, auth admin).

## LA PRISE de la session — la porte a mordu à sa première exécution

L'alias backend créé par **labctl promote** sur palier vierge portait
`passSecurityHeaders: true` + `optimizationTechnique: "None"` — la shape du
**proxy self-service** (spike 2026-07-09, où le pass-through Basic est
REQUIS) — là où le **rôle** POSTe la shape minimale (défaut produit : pas de
pass-through). Même manifeste, deux backends qui ne reçoivent pas les mêmes
headers de sécurité selon le moteur. **Corrigé** : la création promote de
labctl redevient minimale (`EnsureEndpointAliasValue`), la projection proxy
garde sa shape via `ensureEndpointAliasValueWith` (routing_test inchangé
vert), un test unitaire ancre l'interdiction
(`TestEnsureEndpointAliasValue_PromoteShapeIsMinimal`).

## Pièges mesurés (à ne pas redécouvrir)

- **La fenêtre du trial tue les imports en vol** : expiry ~25 min, keepalive
  recycle à 23 min — un run lancé tard a vu le play ansible mourir au milieu
  (rc=2) puis un snapshot FANTÔME passer pour un état. Réponses dans le
  harnais : `fresh_window` (uptime ≥ 12 min ⇒ attendre le recyclage, motif
  G7) et snapshot fail-closed (`SNAPSHOT_UNREADABLE`).
- **Deux sanitizers, deux sérialiseurs** : mêmes octets d'entrée, JSON
  ré-écrit avec l'ordre de clés du runtime (dict python vs map Go) — la
  parité d'artefact compare des DOCUMENTS (`jq -S`), pas des octets ; le
  `BuildTimestamp` de l'ACDL varie à chaque `GET /archive` (registre).
- **Une directive shellcheck « file-wide » ne l'est que placée AVANT la
  première commande** (après le shebang/commentaires) — posée après `set -u`
  elle ne couvre que la ligne suivante.
- Les ids d'alias et de scope-mapping sont générés au POST par-run : exclus du
  diff par le registre (le binding `${alias}` est NOM→id au déploiement, le
  scope lie l'API par GUID et l'AS par NOM — rien ne référence ces ids).

## Gestes faits en session (état du lab)

- Vault : `secret/data/stoa/envs/rec/backends/g8par` seedé (creds jetables du
  harnais — re-seedé à chaque run, inoffensif).
- Gateway réelle : assets `g8par-*` créés/purgés par le harnais (trap) — état
  final propre, catalogue inchangé hors runs.
- Aucun build Jenkins requis (la porte G8 est un harnais rejouable ; les
  moteurs sont déjà branchés aux pipelines depuis G5-G7).

## Restes (après G8)

- Les **cinq décisions client** du GOAL (selfApproval dev/rec vs DORA 17(1)(b),
  groupes annuaire N-de-N, forge cible, homol linéaire ou parallèle, paliers
  ITSM) — des réglages de politique à arbitrer AVEC le client.
- Hérités nommés : approverGroup au merge (ADR-081), 4-yeux pipeline inerte
  sans `build-user-vars`, frère du C1 (identités du payload) — inchangés.
- `origin` (GitHub) en retard depuis G5 — le CI lit Gitea ; push optionnel.

## Où lire le détail

- **ADR** : `adr/adr-087-parite-des-moteurs.md` (registre humain complet).
- **Spec** : `docs/superpowers/specs/2026-08-27-g8-parite-des-moteurs-design.md`.
- **Plan** : `docs/superpowers/plans/2026-08-27-g8-parite-des-moteurs.md`.
- **Parcours opérateur** : `ENVIRONNEMENTS.md` § « La parité des deux moteurs (G8) ».
- **GOAL soldé** : `GOAL-cd-promotion-5-envs-2026-08-26.md` (status + encart G8).
