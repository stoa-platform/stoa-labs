---
title: "F4 — La chaîne de publication réelle (spécification)"
type: spec
status: "Tranché sur les preuves F1–F3 ; à valider par la porte et les contre-épreuves du GOAL"
date: 2026-07-29
lié: [GOAL-socle-vers-gateway-2026-07-28, 2026-07-29-f3-webmethods-cluster-design, 2026-07-28-f1-webhook-statut-design]
---

# F4 — La chaîne de publication réelle (spécification)

## Objectif et porte de preuve (repris du GOAL, invariants)

Un pipeline Jenkins publie une API sur la gateway webMethods **du cluster** :
spec OpenAPI poussée dans un repo Gitea d'équipe → build déclenché sans action
humaine (motif F1) → identifiants wM obtenus **depuis Vault par identité de
pod** (mécanique G-c) → import + activation (`POST /apis`) + scoping d'équipe
(`POST /assets/team`).

**Porte F4 :** push d'une spec → API visible, scopée à sa team, **zéro secret
statique** dans Jenkins (l'assertion `credentials.xml` absent, rejouée).

**Contre-épreuves :**
1. rôle Vault révoqué → la publication échoue **fermée**, statut **rouge** dans
   Gitea (F1) ;
2. le membre d'une autre team ne voit pas l'API (`GET /apis` avec ses
   identifiants — isolation prouvée au spike #1 du 2026-07-09).

## Terrain (mesuré F1–F3, revérifié en début d'exécution)

- Gateway cluster : `wm-apigateway.wm.svc:5555`, ClusterIP only, health 200
  depuis un pod (porte F3) ; **cycle trial piloté** : redémarrage `*/20`,
  ~5 min de démarrage → ~15 min de service par cycle.
- L'état gateway (APIs, config) vit dans **ES** (PVC worker-4) — survit aux
  redémarrages (marqueur F3 relu après suppression des 2 pods).
- Jenkins contrôleur : image `ci/jenkins-go:v1` par digest — `labctl` **et**
  `ansible-core` dans l'image **contrôleur** ; le podTemplate agent actuel
  (probe) ne lance que `hashicorp/vault:1.18` → **labctl absent des agents**.
- Vault : policy `jenkins-agent` = lecture seule `secret/data/ci/*` ; rôle k8s
  `jenkins-agent` (SA `jenkins-agent`, ns `ci`, ttl 20 m) ; **aucun jeton au
  repos** — toute écriture passe par un jeton racine éphémère généré par
  quorum (motif `2026-07-28-f1-provision-status-token.sh`, geste exploitant).
- Gitea : webhook allowlist = `jenkins.ci.svc.cluster.local` uniquement ; PAT
  `probe-status` (user `ci`, `write:repository`) dans `secret/ci/probe-status`.
- labctl : résout les credentials gateway dans Vault à
  `{mount}/data/{VAULT_PREFIX}/gateways/{target}` (kv-v2), accepte
  `VAULT_TOKEN_FILE` (0600) ; adapter webmethods = health → import JSON
  idempotent (`POST|PUT /apis`) → `PUT /apis/{id}/activate` + relecture.
  **Il ne sait ni team ni owner.**
- Teams wM 10.15 : une « team » = un **accessProfile** ; assignation
  `POST /assets/team {assetIds:[apiId], newTeams:[<UUID accessProfile>]}`
  (UUID, pas le nom → 400). Isolation prouvée live au spike #1 (GET /apis
  scopé par identité ; assignation cross-team refusée 400). **Le shape
  /assets/team n'a jamais été exercé dans ce dépôt** — seul maillon
  best-effort de la chaîne, à valider par spike avant câblage (T1).

## Décisions (avec alternatives écartées)

### D1 — Publication par `labctl apply` dans un pod agent éphémère

Le job utilise un podTemplate **deux conteneurs** : `vault` (login k8s,
inchangé) + `jenkins-go` (l'image contrôleur, déjà dans le registre par
digest — elle porte labctl). Le pipeline fait le login G-c dans `vault`,
écrit le jeton dans un fichier 0600 du workspace partagé, puis lance
`labctl apply` dans `jenkins-go` avec `VAULT_ADDR`, `VAULT_TOKEN_FILE`,
`VAULT_KV_MOUNT=secret`, `VAULT_PREFIX=ci` → labctl lit
`secret/ci/gateways/<target>` avec la policy **inchangée**
(`secret/data/ci/*` couvre les sous-chemins).

*Écartées :* étendre labctl (support `team:`) — propre à terme (moteur unique
ADR-076) mais exige de reconstruire l'image `jenkins-go` (fenêtre exploitant,
drift de plugins) ; la chaîne Ansible `apim_publish_api` du PoC — fidèle
client mais le GOAL désigne labctl et l'image du socle le porte déjà ;
`agent any` sur le contrôleur — perdrait l'identité de pod (G-c).

### D2 — Scoping team par le pipeline (curl), UUID résolu à chaque run

Après `labctl apply`, le pipeline (conteneur `jenkins-go`, curl) :
`GET /apis` → id de l'API (name+version) ; `GET /accessProfiles` → UUID de la
team du manifeste ; `POST /assets/team`. Fail-closed : team introuvable ou
POST ≠ 200/201 → build rouge. Relecture obligatoire (un 200 wM ne prouve
rien) : `GET /apis/{id}` doit porter la team.

### D3 — Teams portées par la gateway, bootstrap one-shot, spike préalable (T1)

Deux teams de démonstration : `banking-demo` (porteuse) et `insurance-demo`
(témoin d'isolation), chacune : user technique `svc-<team>`, groupe
`<team>-devs`, accessProfile `<team>`. Créées par un script one-shot
(curl admin depuis un pod du cluster), **rejouable** (idempotent). Le spike T1
valide sur la gateway cluster : activation Teams, création, shape
`/assets/team`, et **mesure** si users/groups survivent au redémarrage `*/20`
(l'état ES survit ; les users IS sont peut-être hors ES — si volatils, le
bootstrap se rejoue avant chaque preuve, et c'est consigné).

### D4 — Repo d'équipe `banking-demo/accounts-api`, motif F1 à l'identique

Org Gitea `banking-demo`, repo **public en lecture** `accounts-api` :
`apis/accounts-read.openapi.yaml` (contrat du PoC), `stoa-publish.yaml`
(manifeste labctl : target unique `wm-cluster`,
`adminUrl/gatewayUrl=http://wm-apigateway.wm.svc:5555`, team `banking-demo`,
credentials placeholders — les vrais viennent de Vault), `Jenkinsfile`.
Job Jenkins `publish-accounts` : GenericTrigger, jeton dédié (`openssl rand`,
jamais en Git), filtre `refs/heads/main`, XML versionné comme artefact de
reconstruction (motif F1). Webhook Gitea posé par API. Statut de commit
contexte `jenkins/publish` via le PAT existant `secret/ci/probe-status`
(PAT du user `ci`, valable sur tout repo où `ci` écrit — pas de nouveau
matériel secret).

*Écartée :* un PAT dédié `publish-status` — un secret de plus à détenir pour
le même user Gitea ; à re-trancher quand les identités d'équipe Gitea
arriveront (Keycloak, après F4).

### D5 — Le cycle trial est un fait d'exploitation : le pipeline attend

Premier stage : attendre `GET /health` 200 (boucle ≤ 8 min ; curl avec les
identifiants lus dans Vault — même chemin que labctl). Un push tombant dans la
fenêtre morte (~5 min/20) doit donner un build **vert en retard**, pas un
rouge aléatoire. Le timeout global du job reste < 20 min pour ne pas
chevaucher deux cycles.

### D6 — Écriture Vault : un seul geste exploitant, motif quorum

`secret/ci/gateways/wm-cluster` = `{username: Administrator, password:
manage}` (défauts trial — la valeur importe moins que le **chemin** : le
pipeline ne connaît que Vault). Script préparé sur le motif
`f1-provision-status-token.sh` : quorum 2/3 → jeton racine éphémère →
`kv put` → `token revoke -self` (révocation dans tous les chemins d'erreur),
aucune valeur affichée. Exécution par l'exploitant (`!`), vérification par
lecture **depuis un pod agent** (la policy suffit).

### D7 — Contre-épreuve Vault : révocation du rôle k8s, deux gestes quorum

`vault delete auth/kubernetes/role/jenkins-agent` (geste 1) → push → le login
G-c échoue → build **rouge**, statut rouge dans Gitea ; puis re-création du
rôle à l'identique (geste 2, mêmes paramètres que `vault-bootstrap.sh`) →
push → **vert**. Deux scripts préparés, exécutés par l'exploitant via `!`.
*Repli* si fenêtre exploitant indisponible : suppression du SA
`jenkins-agent` (côté k8s, à portée de l'agent) — ferme aussi le login, mais
le levier du GOAL est le rôle Vault ; le repli n'est joué qu'à défaut.

### D8 — NetworkPolicy ES : posée maintenant (les clients réels sont connus)

Dette F3 : « à poser quand les clients réels seront connus ». F4 les fixe :
**seule la gateway** parle à ES (9200) ; le CronJob ne parle qu'à l'API k8s ;
les agents Jenkins parlent à la gateway (5555), jamais à ES. PR `stoa` :
NetworkPolicy ns `wm` — ingress ES restreint aux pods `app=wm-apigateway`
(+ intra-ES 9300 si cluster ES multi-nœud un jour ; ici mono-pod).
Contre-épreuve : `curl 9200` depuis un pod `ci` → bloqué ; health gateway
reste 200. La policy de la gateway elle-même attend F5 (exposition publique).

### D9 — Dettes F4 du GOAL : tranchées une par une

- **Rétention des builds** : `options { buildDiscarder(logRotator(numToKeepStr:
  '25')) }` dans le Jenkinsfile de `publish-accounts` **et** celui de `probe`
  (push sur `ci/probe`) — soldée dans la passe.
- **Rotation du mot de passe bootstrap de `ci`** : geste exploitant **en fin de session**
  (après la porte) : nouveau mot de passe dans un fichier root-only de
  worker-1, changé via l'API admin Gitea ; consommateurs mesurés = login
  docker push (manuel) et appels API admin des gestes — **aucun manifeste ni
  pull de nœud** (registries.yaml sans auth, pull anonyme). Non bloquant pour
  la porte ; si la fenêtre manque, re-acté avec date.
- **JCasC** : **reportée en connaissance de cause** — le plugin n'est pas dans
  l'image et l'ajouter impose une reconstruction (fenêtre exploitant, drift) ;
  le seuil « 2ᵉ job » est bien franchi, la dette est re-actée avec
  déclencheur précis : *à la prochaine reconstruction de `jenkins-go`*.
- **backendUrl honnête** : pas de backend réel en cluster —
  `backendUrl` pointe un nom interne inexistant, documenté dans le manifeste ;
  l'invocation data-plane n'est pas dans la porte F4 (elle appartient à F5,
  avec le trafic réel).

## Preuves à jouer (dans l'ordre)

1. **T1 (spike)** : Teams actives sur la gateway cluster, 2 teams créées,
   `POST /assets/team` exercé sur une API jetable → shape validé (le seul
   maillon non prouvé) ; survie au restart mesurée.
2. **Porte** : push de la spec sur `banking-demo/accounts-api` → build
   déclenché sans action humaine → `labctl apply` (import + activate) →
   team assignée + relue → statut `jenkins/publish: success` sur le commit ;
   `test ! -f /var/jenkins_home/credentials.xml` rejoué.
3. **Contre-épreuve isolation** : `GET /apis` en `svc-insurance-demo` →
   l'API absente du corps ; en `svc-banking-demo` → présente. (Bonus si T1
   l'a montré : assignation cross-team → 400.)
4. **Contre-épreuve Vault** : rôle révoqué → push → rouge fermé ; rôle
   restauré → push → vert.
5. **NetworkPolicy ES** : PR mergée → `curl 9200` depuis `ci` bloqué,
   health gateway 200.
6. Règle de sûreté n°1 : `dev-wm.gostoa.dev` répond après chaque phase
   (worker-3 intact).

## Observations pour l'exploitant (hors périmètre, à ne pas perdre)

- Mot de passe Administrator de la gateway = défaut trial ; la gateway est
  ClusterIP-only, mais une rotation (stockée dans Vault, consommée par le
  même chemin) serait cohérente après F4.
- Le keepalive hegemon `*/25` sur worker-3 double toujours le cron root
  `*/20` (~5 min de service perdues/heure) — suggestion de suppression
  maintenue.
- Parts Vault : récupération hors ligne + `shred -u /root/vault-init-ci.txt`
  toujours pendantes.

## Dette nouvelle / reportée (actée)

| Dette | Déclencheur de reprise |
|---|---|
| JCasC (cloud + jobs versionnés en YAML) | prochaine reconstruction de `jenkins-go` |
| `team:` dans labctl (moteur unique ADR-076) | même reconstruction (le binaire vit dans l'image) |
| Image `hashicorp/vault:1.18` des agents non épinglée par digest | passe d'épinglage suivante |
| Sauvegarde ns `wm` (quiescement ES) | reprise F2, avant F5 |
| Rotation Administrator gateway | après F4, fenêtre exploitant |

## Risques

- **`/assets/team` best-effort** : si le shape réel diffère (T1), on ajuste au
  spike **avant** de câbler le pipeline — c'est le but de T1.
- **Users IS volatils** (hors ES) : la preuve d'isolation pourrait devoir se
  jouer dans la fenêtre de service ; T1 le mesure, le bootstrap est rejouable.
- **Fenêtre morte du cycle** : traitée par D5 (attente bornée) ; un build
  chevauchant le restart peut rougir légitimement — relancer par push vide
  n'est PAS la porte ; la porte se joue hors fenêtre morte.
- **Deux gestes quorum exploitant** (D6, D7) : si indisponibles, la porte
  reste jouable (D6 obligatoire, un seul geste) et la contre-épreuve Vault
  passe par le repli SA — écart à consigner si emprunté.
