# HANDOFF — 2026-08-03/04 : chaîne CI de provisioning, et cinq garde-fous qui ne gardaient rien

_Dépôt `stoa-labs`. Trois PR mergées : #9 (correctifs CI + cartographie), #10 (XML
orphelins), #11 (garde de secrets). `main` = `86b3a7e`._

## En une phrase

Six correctifs livrés sur la chaîne de provisioning et le rôle self-service,
tous partis d'un retour de terrain — mais l'enseignement de la session est
ailleurs : **cinq garde-fous étaient verts sans rien garder**, et aucun ne
signalait sa propre inutilité.

---

## 1. Ce qui a été corrigé

| # | Défaut | Correctif | Preuve |
|---|---|---|---|
| 1 | `public_cert_ref` relatif résolu depuis la seule racine du dépôt — un `.crt` posé à côté du manifeste était introuvable | deux bases (racine **puis** dossier du manifeste), `CERT_NOT_FOUND` affiche les deux chemins essayés, `CERT_PATH_AMBIGUOUS` refuse le même nom avec des contenus différents | `test-cert-path-resolution.sh` 16/16 |
| 2 | Certificat **DER binaire** (`.cer`, défaut Windows) refusé | détection sur le FICHIER, openssl normalise les deux formats | `test-cert-format.sh` 12/12 |
| 3 | `audience` exigée aussi en mode `internal`, où l'AS est la gateway et où il n'y a **aucune audience d'API** à recopier | obligatoire en `idp` seulement ; vide ⇒ clé **omise**, jamais envoyée à `""` | `test-auth-audience.sh` 13/13 |
| 4 | Le rôle ne retrouvait **jamais** ses stratégies (`GET /strategies` rend un tableau NU sur 10.15, le code lisait une enveloppe) | `strategies-list.yml` partagé | idem, cas 6-7 |
| 5 | `PUT /applications/{id}/apis` : `204` refusé alors qu'il est un succès | `[200, 201, 204]` | contrat épinglé par l'adapter Go |
| 6 | Clé backend par consommateur non gérée | identifier `token` ← Vault, 3 gardes fail-closed, knob `backend.inject` | `test-backend-key.sh` 27/27 |

**Défaut 4, ce qu'il coûtait** — et c'est le plus grave de la liste : le PUT de
convergence était du **code mort** (son `when` exigeait un id jamais trouvé), et
le `retire` de `rotate-strategy` déclarait un **« no-op »** sans rien détacher.
Une rotation 0-coupure qui annonce le succès en laissant l'ancienne identité
acceptée.

## 2. ADR-081 — où vit la décision humaine

Question posée en séance : et si tout se faisait dans **un seul CI**, validation
comprise ? Le besoin est réel (le demandeur avait trois endroits à regarder),
mais la solution déplaçait l'autorité hors de Git.

**Décision : le merge reste le point de décision.** Trois corollaires traitent
l'ergonomie sans y toucher — la demande **enchaîne le plan** (un seul build), le
statut de l'apply **remonte sur la PR** (succès comme échec, avec l'identité
nominative), et les quatre yeux sont imposés par la **protection de branche**,
pas par un job.

Statut **Proposé**, pas Accepté : l'option CI-unique vient du client, la marquer
acceptée ferait passer une recommandation pour sa décision. L'ADR décrit aussi ce
que coûterait le choix inverse, pour qu'il soit fait les yeux ouverts.

Corollaires livrés et validés par un build réel (`PLAN_INLINE=ok`, PR commentée).

## 3. La garde d'identité du valideur

Un `input` Jenkins **n'authentifie personne** : quiconque en a le droit peut y
répondre. Le webhook, lui, dit qui a mergé — mais c'est une **affirmation**, pas
un credential : on ne dérive pas un token Vault d'un nom dans un JSON.

`scripts/lib/assert-merge-identity.sh` relie l'identité **prouvée** (login Vault)
à l'identité **affirmée** (`merged_by`), et refuse si elles divergent.
`MERGER_UNKNOWN` quand `merged_by` manque — sinon deux chaînes vides seraient
« égales » et la garde passerait au vert sans rien vérifier.

Câblée dans `provision-apply`, **avant** le build aval : l'ordre est la garde, et
le test le verrouille par numéro de ligne.

## 4. Les cinq garde-fous verts qui ne gardaient rien

C'est le fil de la session, et la partie qu'il faut retenir.

| Garde | Pourquoi elle ne gardait rien |
|---|---|
| ordre `SELF_DIR`/`cd` | ne couvrait qu'un fichier ; élargie, son filtre excluait **exactement la forme buguée** qu'elle traquait — le fichier était *sauté*, pas refusé |
| faux Jenkins du test | acceptait n'importe quel `Content-Type`, donc **plus tolérant que le vrai** : il validait un script qui échoue en production |
| « pas de secret en argv » | le `grep` matchait le **commentaire** décrivant l'interdit |
| `trim` sur `APIM_PROXY_BASE` | portait sur un **paramètre de build qui n'existe nulle part** — c'est une variable d'environnement |
| `check-no-plaintext-secrets.sh` | **rouge en permanence** (23 occurrences préexistantes), donc plus lue : la 24ᵉ serait passée |

**Ce qu'il faut en tirer** : le nombre de cas verts ne dit rien. Ce qui informe,
c'est la **vérification de discriminance** — *le test échoue-t-il sur le code
d'avant ?* Trois fois dans cette session, la réponse était non alors que la suite
était verte.

## 5. Deux causes racines, et ce qui les a désignées

**`charset=utf-8`** — `POST /job/<nom>/config.xml` rendait 500 « Failed to
persist config.xml », message qui ne dit rien. Sans charset déclaré, Jenkins
parse le corps en ISO-8859-1 et casse sur le premier caractère accentué
(`É` = `0xC3 0x89`) : toutes les descriptions de jobs sont en français.

Ce qui a désigné la cause : **renvoyer à Jenkins sa propre config, relue et
inchangée, échouait aussi**. Ce contrôle écartait le contenu et ne laissait que
l'en-tête. (Et il a fallu vérifier que le fichier relu était bien du XML et non
une page d'erreur — un contrôle qui teste autre chose que ce qu'on croit ne
contrôle rien.)

Conséquence : `setup-provision-request-job.sh` contournait ce 500 par un
`delete+create` **inconditionnel**, qui détruisait l'historique de builds à
chaque exécution — 7 builds sur `provisioning-request`. Corrigé par délégation à
la logique correcte, pas par une seconde copie.

**Chemin résolu après un `cd`** — les scripts se déplacent dans un clone jetable
puis appellent un voisin ; `dirname "$0"` relatif n'y résout plus. Documenté dans
un fichier, **reproduit dans celui d'à côté le lendemain**, et non attrapé parce
que la garde ne couvrait qu'un fichier.

## 6. Cartographie des environnements

`ENVIRONNEMENTS.md`, écrit après avoir **appliqué en local une mise à jour
demandée sur le labs**. Les deux instances portaient les trois mêmes jobs, et
rien dans la réponse HTTP ne les distingue une fois le portail franchi.

| | Accès | Contenu |
|---|---|---|
| **local** (Docker) | direct | ~25 conteneurs ; `poc-jenkins:18080`, `poc-gitea:13000` ; **la chaîne de provisioning n'existe QUE là** |
| **labs** (k3s Contabo) | Cloudflare Access, ou `kubectl port-forward` via le tunnel | 5 jobs : `carto`, `probe`, `publish-accounts`, `publish-api-deploy`, `selfservice-app-deploy` |
| **plateforme** | public | `gostoa.dev`, `console`, `portal`, `api`, `docs`, `auth` |

Trois pièges consignés :

- **les jobs locaux clonent Gitea, pas GitHub** — et les deux dépôts n'ont
  **aucun ancêtre commun** : tout report est un transplant de contenu ;
- **les XML de `ci/jenkins/` ne visent pas tous la même instance** — pousser ceux
  du cluster en local aurait redirigé les jobs vers GitHub **et supprimé leurs
  tokens de webhook** ;
- `kubectl port-forward` contourne le **portail**, pas la segmentation : il
  transite par l'API server, pas par le ClusterIP.

## 7. La garde de secrets

La dette n'était pas les 23 valeurs — des identifiants de lab publics depuis le
2026-07-30, donc brûlés. C'était l'**alarme muette**.

`scripts/secrets-baseline.txt` fige le connu-et-assumé, une ligne par occurrence
**avec sa raison**. La clé est `(fichier, VARIABLE)` — pas le fichier, sinon en
lister un l'absoudrait en bloc.

Limite énoncée dans le fichier plutôt que découverte plus tard : changer la
**valeur** d'une entrée listée ne rouvre pas la garde. Hacher la valeur
publierait un condensat de secret dans un dépôt public.

`test-secrets-baseline.sh` 13/13 défend le risque du dispositif lui-même — qu'une
base de référence éteigne l'alarme avec le bruit. Cas décisifs : secret neuf dans
un fichier connu, dans un fichier inconnu, et **base absente** (le pire serait de
devenir permissif en perdant le fichier).

## 8. Ce qui reste ouvert

- **Les 22 littéraux** sont toujours dans les scripts. Les sortir vers
  l'environnement touche la propriété « une commande et le lab est debout » :
  c'est une décision, pas une évidence. La base les rend dénombrables — condition
  pour les traiter, pas absolution.
- **Le trim des overrides d'URL** n'est plus couvert. La garde supprimée
  protégeait une fiction, mais le risque réel se joue dans le shell des
  Jenkinsfile. Une note le signale à l'emplacement du bloc retiré.
- **Le formulaire de restitution du `client_id`/`secret`** reste bloqué sur le
  contrat DCR de l'AS interne wM. En mode `idp` il n'a de toute façon pas d'objet
  (le secret vit sur l'IdP).
- **Le Jenkins du labs n'a pas été modifié.** Rien ne l'exigeait : ses deux jobs
  adossés au dépôt clonent `origin/main` et aucun commit ne touchait leurs
  Jenkinsfile. L'accès par le cluster est documenté si besoin.
- **`value` de l'identifier `token`** est posé en liste à un élément — non
  confirmé contre l'application de production du client.

## 9. Avertissement d'exploitation

**Deux instances de l'agent ont travaillé dans le même arbre de travail.** Deux
fois, un `git commit` a atterri sur la branche de l'autre, HEAD ayant bougé entre
le `add` et le `commit`. Récupéré par cherry-pick via un worktree isolé, sans
toucher à leur HEAD.

La parade tenue ensuite : **tout faire dans un `git worktree` dédié**, et ne
jamais utiliser `git stash` sur l'arbre partagé — un stash y déplacerait le
travail en cours de l'autre.
