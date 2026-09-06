# HANDOFF — P5 : l'API refuse elle-même le clair ; le listener ne protège personne

**2026-09-06 · GOAL `posture-par-exposition` · ADR-095 · branche `provision/probe-dev` · NON COMMITTÉ**

---

## Ce qui est livré, et ce qui le prouve

| Épreuve | Résultat |
|---|---|
| `cd labctl && go test ./... && go vet ./...` | **561 ✅ / 0 ❌** (4 assertions neuves), vet propre |
| `bash scripts/test-p5-https.sh` | **54 ✅ / 0 ❌** (A→D), dont **6/6 mutations rouges**, **rejouée** |
| `python3 scripts/spike-p5-https.py all` | **34 ✅ / 0 ❌**, 8 verdicts, rejouée à l'identique |
| `python3 scripts/spike-p5-https.py S9` / `S10` | 2 sondes de surface (promotion en no-op, `clientAuth`) |
| `bash scripts/test-p4-global-policy.sh` (non-régression) | **38 ✅ / 0 ❌** — *après portage de sa mesure sur le canal TLS, voir plus bas* |
| `bash scripts/test-p3-tag-plateforme.sh` (non-régression) | 24 ✅ / 0 ❌ |
| `bash scripts/test-p2-posture-producteur.sh` (non-régression) | 67 ✅ / 0 ❌ |
| `make lint-ci` | **17/17 vert**, sans ligne ajoutée à la dette |

**La porte du jalon, littéralement :** la MÊME API publiée par la chaîne répond **HTTP 500 « Transport protocol not supported » en clair** et **HTTP 200 en HTTPS**, pendant qu'une API témoin — publiée sans registre central, donc sans posture arbitrée — répond **200 en clair**. **Contre-épreuve :** le réglage retiré à la main, le clair **repasse en 200** ; le rôle rejoué le **re-converge** ; un troisième passage n'écrit rien.

## Fichiers

**Neufs**
- `scripts/spike-p5-https.py` — les 8 spikes + 2 sondes (S1→S10), actifs jetables, nettoyage en sortie
- `ansible/roles/apim_publish_api/tasks/entry-protocol.yml` — la pose, côté pipeline
- `ansible/roles/apim_https_listener/{defaults,tasks}/main.yml` + `ansible/is-https-listener.yml` — le listener, objet d'environnement
- `scripts/lib/wm-dataplane.sh` — appeler le plan de données sur le canal que l'API ACCEPTE
- `labctl/internal/render/posture_entry_protocol_test.go` — les gardes du couplage
- `scripts/test-p5-https.sh` — la matrice
- `adr/adr-095-https-protocole-par-api-listener-par-environnement.md`

**Modifiés**
- `labctl/internal/render/render.go` — `Result.EntryProtocol`, `EntryProtocolHTTPS`, `EntryProtocolFor()`
- `labctl/cmd/labctl/posture.go` — champ `entry_protocol` (JSON + texte), `orNone()`
- `ansible/roles/apim_publish_api/tasks/main.yml` — import en **1d**, après l'appartenance, avant l'activation
- `scripts/test-p4-global-policy.sh` — sa mesure du plan de données passe par la lib TLS
- `Makefile` — shellcheck de `scripts/lib/wm-dataplane.sh` et `scripts/test-p5-https.sh`

## Le fait qui commande tout le jalon, et qui est contre-intuitif

**La topologie des ports ne protège AUCUNE API.** Mesuré deux fois : ajouter un listener HTTPS ne change rien au protocole qu'une API accepte (spike C de P0), et promouvoir ce listener en primaire ne ferme pas le HTTP — `enabled` et `primary` sont deux champs indépendants (S6). Un environnement peut avoir un listener HTTPS impeccable et servir toutes ses APIs en clair.

D'où la répartition : le **refus** vit sur l'API (pipeline), le **transport** vit dans l'environnement (play autonome), et le play le **dit** — son dernier mot énumère les ports en clair restés ouverts et rappelle où vit le contrôle.

## Les faits produits mesurés en chemin

1. **L'action `entryProtocolPolicy` est PROPRE à chaque API** — contrairement au throttle du stage LMT, que P4 avait mesuré **partagé**. Sans cette vérification (ids distincts + écriture sur A, relecture de B), poser le protocole par API aurait pu être un effet de bord silencieux sur toutes les autres.
2. **Le paramètre est EXCLUSIF, pas additif.** `["http"]` ferme le TLS aussi sûrement que `["https"]` ferme le clair. C'est pourquoi le read-back exige l'**égalité stricte** : une liste `['http','https']` *contient* la valeur visée et laisse passer le clair — un `in` serait un vert parfaitement vacant.
3. **Le réglage se pose sur une API INACTIVE et survit à l'activation** (S8). C'est ce qui rend tenable la promesse « une API gouvernée ne sert jamais un seul appel en clair, pas même pendant sa publication ». Le fait jumeau avait dû être mesuré en P4 pour `GET /apis/{id}/globalPolicies`.
4. **Il survit aussi au ré-import de contrat** (S7) — contrairement au tag de P3, qui s'efface. La pose n'a donc pas besoin d'une seconde passe.
5. **⚠ `clientAuth` n'est pas éditable, et le produit ment.** `PUT /ports/{listenerKey}` **et** `PUT /ports/{alias}` rendent **200** et la relecture ne bouge pas ; il n'est honoré qu'à la **création** du port. Et le champ `alias` vaut « ssos » sur **tous** les listeners HTTPS, donc `/ports/{alias}` ne désigne même pas un port. Le « quirk 500 » qu'annonçait `is-mtls-setup.yml` est en réalité un 200 menteur — pire.

## Trois pièges de mesure payés dans cette session

- **Un `check()` qui imprimait son texte d'échec sur un vert.** Le premier jet du spike affichait « ✅ … — absente — le rôle devra CRÉER l'action ». Revenu à la sémantique du harnais P0 : le détail n'accompagne QUE l'échec, ce qui doit se voir en toutes circonstances passe par `mes()`.
- **Un `mutate()` qui `cd` dans le shell du harnais.** La première mutation faisait `cd labctl && go test` sans sous-shell : toutes les mutations suivantes échouaient à sauvegarder leur fichier, **et la première restait dans l'arbre de travail**. Un harnais de mutation qui ne restaure pas est pire qu'absent. Corrigé (sous-shell) — et la mutation résiduelle a dû être retirée à la main.
- **Un `\&\&` échappé dans une chaîne passée à `eval`.** Deux mutations passaient au vert sans rien exécuter. Vérifiées à la main avant correction, elles rougissent bien.

## La conséquence à annoncer, et elle n'est pas technique

**Une API gouvernée n'est plus joignable en clair : pour un appelant qui y était, c'est une rupture.** Ce n'est pas la plateforme qui coupe — l'API reste active, le data-plane HTTPS répond, rien au sens d'ADR-079 — c'est le contrôle qui s'applique. Sur un environnement où des consommateurs appellent en clair, **la première publication gouvernée les casse**. À dire au client avant, pas après.

Corollaire opérationnel : **le listener HTTPS devient un préalable d'environnement.** Sans lui, une API gouvernée n'est joignable par aucun canal.

## Ce qu'il faut savoir pour la suite

- **Tout harnais qui mesurait le plan de données EN CLAIR mesure autre chose depuis ce jalon.** Celui de P4 lisait le refus de protocole là où il attendait un 429 : sa contre-épreuve virait au rouge sans rien dire de la cellule. Porté sur `scripts/lib/wm-dataplane.sh` (canal TLS, via le conteneur — le listener HTTPS du lab n'est pas publié sur l'hôte). **Le prochain harnais qui touche au data-plane doit utiliser cette lib**, pas `curl` en direct.
- **La lib est fail-closed sur sa configuration** (`WM_DATA`, `WM_DP_TLS_BASE` requises, refus nommés) : la porte `ci/lint-config-knobs.sh` interdit un défaut de site dans du code partagé, et un défaut silencieux ferait mesurer une autre gateway que la sienne.
- **`is-mtls-setup.yml` porte un chemin d'écriture qui ne peut pas réussir sur ce build** (`PUT /ports/{alias}` pour `clientAuth`). Son read-back fail-closed le rattrape — il échoue bruyamment plutôt que de mentir — mais la tâche est inopérante. **Non corrigé** : hors périmètre P5, ADR-076 en est propriétaire. Nommé plutôt que tu.
- **Le proxy d'administration n'a rien à gagner** : `GET /apis/{id}`, `GET /policies/{id}`, `GET`/`PUT /policyActions/{id}` sont déjà dans l'allow-list ADR-075. Le play de listener, lui, parle à `/ports` — hors proxy, sous identifiant IS-admin, comme le play d'amorçage de P4.
- **Le lab recycle wM ~23 min.** Une exécution coupée se rejoue telle quelle ; la matrice complète tient en ~70 s, le spike en ~3 min.
- **Rien n'est committé ni poussé.** Comme après P2, P3 et P4 : le `labctl` du conteneur `poc-jenkins` date du 2026-07-02 et ne connaît ni `posture`, ni `--cells`, ni `entry_protocol` — un build Jenkins ne peut pas rejouer cette porte tant que gitea n'est pas servi.

## Restent P6 et P7

- **P6** garde sa prémisse **tombée** (P0, spike B) : le mode d'accès d'un port de l'Integration Server garde `/invoke`, pas le dispatch de l'API Gateway. À trancher avec le client : ce que « port en deny-by-default » désigne chez lui. P5 renforce le constat — c'est bien l'API, pas le port, qui garde une API.
- **P7** traversera `approvers.yml`, toujours cassé sur le produit réel (décision client n°2), et devra mesurer le protocole parmi le tag, l'inscription au port et les policies effectives. Sa contre-épreuve — un producteur qui se déclare moins exposé obtient exactement la même posture — a désormais un quatrième axe à couvrir.
