# G8 — La parité des deux moteurs, prouvée (design)

**Date** : 2026-08-27 · **GOAL** : `GOAL-cd-promotion-5-envs-2026-08-26.md` § G8 —
le dernier jalon ouvert (G1..G7 faits).

## 1. Le problème, tel que le GOAL le pose

La décision n°6 (tranchée le 2026-08-26) maintient **deux moteurs
iso-sémantiques** du verbe archive : `ansible/roles/apim_promote_api` (chemin
client) et `labctl promote` (chemin lab/gouvernance), pilotés par **le même**
`.promote.yml`. Le prix de ce choix est G8 : « sans quoi ce ne sont pas deux
moteurs, mais deux comportements dont on espère qu'ils coïncident. »

**Porte G8** : les deux moteurs, sur le même manifeste, produisent un état de
gateway **identique** sur les champs du registre — rejouable en `--tags verify`.
**Contre-épreuve** : une divergence volontaire dans un moteur ⇒ la parité
**rougit** (motif F1 : une parité qui ne rougit jamais ne prouve rien).

## 2. Ce qui existe déjà — et ce qui manque exactement

| Attendu G8 | État mesuré |
|---|---|
| 1. `labctl promote` cesse d'être mort | **Largement acquis** : `test-promote-verb-live.sh` (G5, 54/54) l'exerce live contre la gateway réelle ; `team-promote.sh` (G5-G7) le dispatch sur les paliers intermédiaires. Mais il n'a **aucun verbe de relecture** : la porte « rejouable en verify » n'a pas de versant Go. |
| 2. Test de parité X/X sur l'ÉTAT | **Absent.** Le harnais G5 éprouve chaque moteur sur des assets **séparés** (`g5live-ansible-*` vs `g5live-labctl-*`) avec les mêmes assertions — il prouve que chacun tient le contrat, jamais que les deux produisent le **même état**. Aucune comparaison snapshot-contre-snapshot n'existe. |
| 3. Registre des écarts assumés | **Épars** : les écarts connus sont dispersés (G5 : digest hors labctl ; G7 : terminus ansible-only) dans des commentaires et handoffs. Rien de mécanique : un écart NOUVEAU ne ferait rougir aucun test. |

## 3. Architecture

Trois pièces neuves, aucune modification des moteurs eux-mêmes (leur sémantique
est l'objet mesuré — on ne la retouche pas dans le lot qui la mesure, hors
ajout d'un verbe de **lecture**).

### 3.1 `labctl promote --action verify` (lecture seule)

Miroir exact de `tasks/verify.yml` (le `--tags verify` du rôle) :

- relit l'API par **GUID épinglé** : présente (200), `isActive`, `apiName`
  conforme au manifeste → sinon `PROMOTE_UNCONFIRMED` ;
- relit la valeur d'alias backend de CET env : `endPointURI` == valeur
  `per_env` → sinon `ALIAS_DRIFT` ;
- smoke data-plane optionnel (`smoke_path`) ;
- **n'écrit rien** ; prononce `PROMOTE_CONFIRMED` en sortie.

Tests unitaires httptest (nominal + chaque refus). La porte G8 devient ainsi
rejouable **par les deux moteurs** : `promote-api-verify.yml` côté rôle,
`--action verify` côté Go.

### 3.2 `scripts/test-parity-moteurs.sh` — LE test de parité

Terrain : la gateway **réelle** (`poc-webmethods-real`, keepalive ~20 min
absorbé par `wait_gw`, motif G5). Assets jetables `g8par-*`, purgés au setup et
par trap. Un SEUL manifeste partagé couvrant toute la surface per-env :

```yaml
apim_promote:
  name: g8par-api        # v1.0.0, publiée active, backend littéral au setup
  guid: <épinglé après export>
  overwrite: "apis,policies,policyactions"
  backend_alias: { name: g8par-backend }
  cred_alias:    { name: g8par-backend-creds, vault_sub: backends/g8par }
  aliases:       [ { name: g8par-flag, record: { type: simple, value: g8par } } ]
  scope_mapping: { external_scope: g8par.read, auth_server_alias: g8par-as }
  smoke_path: ""
  per_env:
    rec: { backend_alias: { url: http://poc-token-echo:8080/backend/rec },
           cred_alias:    { vault_sub: backends/g8par } }
```

Le Vault du lab est vivant : le harnais **seed** les creds jetables sous
`envs/rec/backends/g8par` (KV v2, token `VAULT_TOKEN`) et les passe aux deux
moteurs par leurs voies respectives (`apim_ss_vault_*` / `VAULT_ADDR`+token).
L'alias auth-server `g8par-as` (shape `authServerAlias` +
`localIntrospectionConfig`, prouvée par labctl) est posé par le harnais —
alias-first, comme le play d'init d'env le ferait.

**Phases** :

1. **EXPORT ×2** — chaque moteur exporte la même API source → deux artefacts.
   Parité d'artefact : même liste d'entrées, même contenu **entrée par entrée**
   (`unzip -p`, normalisation des seuls champs volatils enregistrés au
   registre). Deux sanitizers qui divergent se voient ICI, avant tout import.
2. **IMPORT ansible → snapshot A** — palier remis à VIERGE (retrait direct API
   + aliases g8par-* + scope mapping ; l'AS reste : il est env-local), puis
   import par le rôle de l'archive **ansible** (digest pinné), snapshot.
3. **IMPORT labctl → snapshot B** — re-mise à vierge, import par labctl de la
   **même archive** (celle du rôle : la parité d'import se mesure à archive
   égale ; la parité d'export a été mesurée en 1), snapshot.
4. **PARITÉ** — diff des deux snapshots après application du registre
   d'exclusions. **Tout écart non enregistré rougit en nommant le champ.**
5. **VERIFY ×2 (rejouabilité)** — sur l'état final : `promote-api-verify.yml`
   (le `--tags verify` du rôle) ET `labctl promote --action verify` prononcent
   `PROMOTE_CONFIRMED` tous les deux, sans écrire (re-snapshot identique).
6. **CONTRE-ÉPREUVES par MUTATION** (§ 3.4).

### 3.3 Le snapshot normalisé — les « champs du registre »

Fonction unique (jq), mêmes lectures pour A et B :

- **API** (`/apis/<guid>`) : `id`, `apiName`, `apiVersion`, `isActive`,
  `type`, liste `policies` triée — le GUID iso et le graphe de politiques ;
- **actions de politique** : pour chaque policy, ses `policyAction` (id,
  template, champs de config dont le routing `${alias}`) — triés ;
- **aliases** (`/alias`) : records `g8par-backend` (type, `endPointURI`),
  `g8par-backend-creds` (type, `authType`, `userName` — le password est masqué
  par design, write-always), `g8par-flag` (champs déclarés) ;
- **scope-mapping** (`/scopes`) : record du mapping per-API
  (`scopeName`, `audience`, `apiScopes`, `requiredAuthScopes`) ;
- **sonde data-plane** : le chemin servi (`dp_path`) — le routing par
  `${g8par-backend}` prouvé fonctionnellement, pas seulement déclaré.

### 3.4 Les contre-épreuves — la parité doit savoir rougir

Deux mutations **volontaires**, une par moteur, jouées depuis des **copies**
patchées dans `$WORK` (jamais l'arbre de travail) :

- **labctl muté** : copie de `labctl/`, retrait de l'appel
  `EnsureScopeMappingPerAPI` dans `promote.go` (sed ancré, échec du harnais si
  le motif ne matche plus), rebuild → re-mise à vierge → import muté →
  snapshot B′ → le diff A vs B′ DOIT être non vide et nommer le scope-mapping.
- **rôle muté** : copie de `ansible/`, retrait de l'include `scope.yml` dans
  `import.yml` → même déroulé, même exigence, dans l'autre sens.

Un vert de mutation (= la parité n'a rien vu) est un ROUGE du harnais.

### 3.5 Le registre des écarts assumés

Deux faces, une seule vérité :

- **Machine** : `scripts/testdata/parity-ecarts.txt` — une ligne par
  exclusion : `<chemin jq du champ>\t<raison courte>`. Consommé par le harnais
  (les chemins listés sont retirés des deux snapshots avant diff ; pour la
  parité d'artefact, les motifs de normalisation y sont aussi). Un écart
  inconnu ne PEUT PAS passer : il n'est pas dans le fichier, donc il rougit.
- **Humain** : ADR-087, registre complet — les exclusions de champs (avec la
  mesure qui les justifie) ET les écarts de MOTEUR qui ne sont pas des champs
  d'état : digest sha256 vérifié par le rôle et le CI, jamais par labctl
  (gardé côté Go par taint-check + GUID) ; voie du terminus ansible-only
  (G7, `COMBINAISON_NON_SUPPORTEE`) ; défaut `apim_ss_authoring_env`
  surchargeable aux degrés D0/D2 (dissymétrie assumée, commentée au rôle) ;
  acquisition de l'auth admin (rôle : `apim_common/secrets.yml` Vault-fallback ;
  labctl : `targets.yaml`).

Le contenu initial des exclusions de champs est **mesuré, pas deviné** : ce
que le premier run révèle (ids générés par POST — scope mapping, alias —,
horodatages) entre au registre avec sa justification, le reste doit être
identique.

## 4. Livrables

1. `labctl promote --action verify` + tests unitaires (TDD).
2. `scripts/test-parity-moteurs.sh` (X/X, keepalive-aware, rejouable).
3. `scripts/testdata/parity-ecarts.txt` (+ lecture par le harnais).
4. `adr/adr-087-parite-des-moteurs.md` — la décision, le registre humain, le
   tableau de preuve.
5. `ENVIRONNEMENTS.md` § « La parité des deux moteurs (G8) ».
6. GOAL § G8 marqué FAIT ; handoff ; mémoire.
7. `make lint-ci` vert (shellcheck sur le nouveau script inclus).

## 5. Ce que ce lot NE fait PAS

- **Pas de builds Jenkins** : la porte G8 est un test de parité rejouable, pas
  un parcours CI — les moteurs sont déjà branchés aux pipelines (G5-G7).
- **Pas de parité sur la chaîne mock** : les mocks ne portent ni policies ni
  scopes de qualité produit ; une parité mesurée là dirait « les deux moteurs
  parlent au même simulacre ». Terrain = gateway réelle, la seule dont l'état
  est celui que le client observera.
- **Pas d'égalisation forcée** : un écart mesuré et justifié se REGISTRE
  (ADR-087), il ne déclenche pas une réécriture d'un moteur pour ressembler à
  l'autre — « l'iso-sémantique totale n'est probablement pas atteignable ni
  souhaitable » (GOAL).
- **Aucun argument de conformité** pour la topologie des gateways segmentées
  (réfuté, ne doit pas réapparaître).
