# Console Light — Cadrage

> **Statut :** cadrage validé avant toute ligne de code (règle anti-boucle de réécriture).
> **Date :** 2026-06-10 · **Owner :** Christophe
> **Client cible démo :** banque anonyme (anonymisé) — ne jamais nommer dans ce repo.
> **Références :** ADR-067/068/069 (`../adr/`), PoC fédération (`../poc-control-plane-federation/HANDOFF.md`), plan de jeu commercial (stoa-strategy `clients/client-banque-etude-alternatives/document-4`).

---

## 1. Objet et critère de done

**Objet :** une IHM de gouvernance mince au-dessus de Git — RBAC métier (tenant / API / environnement) ancré sur l'IdP central, où **chaque action validée = commit signé + évidence**, et où l'exécution passe par la CI du client (Jenkins webhook → labctl). Cible : démontrer à des architectes bancaires que la gouvernance fédérée multi-gateway est un produit qui fonctionne.

**Critère de done UNIQUE (binaire) :** le parcours démo 15 minutes passe de bout en bout sur la stack PoC :

| # | Étape démo | Preuve attendue |
|---|---|---|
| 1 | Login SSO — persona *fournisseur d'API* (broker Oracle-master via Dex→Keycloak) | session sans secret statique, rôles depuis le JWT |
| 2 | Catalogue : il ne voit que **son** tenant | isolation RBAC visible |
| 3 | Édite un contrat UAC — validation schéma inline (dont règle `destructive ⇒ requires_human_approval`) | erreur de schéma bloquante affichée |
| 4 | Publie en dev → **le commit Git apparaît à l'écran** (sha, auteur, message) | l'action EST le commit |
| 5 | Les 3 gateways hétérogènes convergent (pipeline Jenkins déclenché par webhook) | `labctl apply` exécuté par la CI, pas par la console |
| 6 | Tente « Promouvoir en prod » → **refusé** (rôle insuffisant + self-approval bloqué) | le refus est AUDITÉ |
| 7 | Bascule persona *approbateur* → approuve avec message motivé → merge + commit signé | 4-yeux démontré |
| 8 | Écran Audit : chaque action ↔ son commit (sha cliquable) + export | la piste d'audit EST le git log |

Tout ce qui ne sert pas ce parcours est **hors scope v1**.

## 2. Principes non négociables

1. **La console n'exécute jamais labctl sur le chemin de prod** (ADR-068). Elle écrit des commits gouvernés dans Git ; le webhook déclenche Jenkins ; Jenkins exécute le binaire signé. La console *suit* le pipeline, elle ne le remplace pas. (Exception assumée : preview/plan en lecture seule.)
2. **Git = source de vérité, push direct interdit** sur le repo gouverné. Mode canonique `pull_request` de la spec `catalog-release-versioning-contract.md` (branches `stoa/api/{tenant}/{api}/...`, merge commit, tag annoté) — critères CRV-1..6 repris tels quels.
3. **Les 6 invariants Git-first** d'`api-creation-gitops-rewrite.md` s'appliquent au BFF : le payload HTTP ne projette jamais ; on projette depuis le contenu relu après commit ; idempotence par content hash ; `git_path` déterministe par slug.
4. **OSS-first** : pas de brique custom là où l'écosystème couvre (diff = git diff ; identité = Keycloak ; exécution = Jenkins ; convergence cluster = ArgoCD le moment venu).
5. **L'évidence ne vit jamais dans les logs CI** (volatils) : chaque action génère un evidence pack `evidence/<api>/<action>-<timestamp>.{json,md}` commité avec l'action.
6. **Réutiliser la carrière, ne pas la ressusciter** : on clone des fichiers choisis depuis `stoa/control-plane-ui` et `@stoa/shared`, on ne dépend jamais du monorepo ni du cp-api.

## 3. Personas & RBAC

Réutilisation directe du modèle 4 personas Keycloak-natif (`AuthContext.tsx`, map `ROLE_PERMISSIONS`, rôles extraits de `realm_access.roles` du JWT) :

| Persona démo | Rôle technique | Ce qu'il démontre |
|---|---|---|
| Fournisseur d'API (alice) | `tenant-admin` | édite/publie SES contrats, SON tenant, dev seulement |
| Approbateur (bob) | `devops` + claim approver | approuve les promotions prod — mais pas les siennes (4-yeux) |
| Auditeur/sécurité | `viewer` | lit tout (audit, contrats), n'écrit rien — boutons absents, pas grisés |
| Admin plateforme | `cpi-admin` | tenants, rôles, cibles de fédération ; multi-tenant |

Users alice/bob existent déjà dans Dex (`identity/dex/config.yaml`). À créer : client Keycloak **`console-light` dédié** (confidentiel ou public+PKCE, redirectUris épinglées — ne PAS réutiliser `stoa-portal` et ses `'*'`), + 2 users pour auditeur/admin.

## 4. Les écrans (10 + 2 = 12 max)

Ordre = rentabilité de clonage (verdicts de l'inventaire wf_54e4ab92) :

| # | Écran | Source carrière (stoa/control-plane-ui/src/…) | Effort |
|---|---|---|---|
| 1 | **Tenants** (read-only, bannière « managed via GitOps » déjà là) | `pages/Tenants.tsx` (166 LOC) | direct — lister les dossiers tenants du repo |
| 2 | **Rôles & permissions** (read-only) | `pages/AdminRoles.tsx` (149 LOC) | direct — brancher realm roles Keycloak |
| 3 | **Audit** (git log signé) | `pages/AuditLog.tsx` (760 LOC) | direct UI — source = git log ; AJOUTER commit_sha + badge « signed » + lien évidence |
| 4 | **Catalogue des contrats UAC** | `pages/Contracts.tsx` (757 LOC) | à adapter — contrat = fichier UAC dans Git, badges protocoles conservés |
| 5 | **Détail contrat** (tabs Overview / Spec / Versions) | `pages/APIDetail.tsx` (653 LOC, squelette tabs) | à adapter — Versions = git history du fichier |
| 6 | **Éditeur de contrat** (validation inline ajv sur `uac_contract_v1_schema.json` + règle destructive⇒approbation) | CreateContractView dans Contracts.tsx | à adapter + validation neuve |
| 7 | **Promotions** (4-yeux, message d'audit obligatoire, pipeline dev→staging→prod) | `pages/Promotions.tsx` (1315 LOC, retirer ~250 LOC d'éligibilité gateways) | à adapter — LA pièce maîtresse ; approve = merge + commit signé ; DiffViewer → vrai git diff |
| 8 | **Souscriptions** (approve / reject motivé / bulk) | `pages/Subscriptions.tsx` (784 LOC) | à adapter — souscription = fichier YAML dans Git |
| 9 | **Utilisateurs** (+ assignation rôle — NEUF) | `pages/AdminUsers.tsx` (283 LOC) | à adapter — Keycloak Admin API ; l'écriture user→rôle n'existait pas |
| 10 | **Cibles de fédération** (les gateways enregistrées, statut Health) | modèle `targets.yaml` + `Adapter.Health()` | neuf (simple : liste + santé) |
| 11 | **Revue de merge-request** (l'approbation = merge signé) — NEUF | contrat d'interface : `services/api/git.ts` (client orphelin commits/MRs, jamais branché — à étendre) | neuf |
| 12 | **Dashboard gouvernance** (« en attente d'approbation » + derniers commits signés) — NEUF | StatCards de @stoa/shared | neuf (simple) |

**Socle transverse repris tel quel :** `AuthContext` + `PermissionGate` (+ tests par persona `test/helpers.tsx`), `useEnvironmentMode` (prod read-only + promote-only = exactement la posture à démontrer), `Layout.tsx` réduit (nav filtrée par permission), **EnvironmentChrome** (bandeau rouge « Production — read-only » : moment fort de la démo), design system `@stoa/shared` vendorisé (~4 500 LOC ; exclusions : FloatingChat/chat, api-types générés).

## 5. Architecture

```
Console Light (React, vendored @stoa/shared)
      │ OIDC PKCE (client console-light, broker oracle Dex→Keycloak)
      ▼
BFF gouvernance (Go — DANS le module labctl, importe internal/{adapter,targets,openapi,keycloak})
      │── lecture : contrats/tenants depuis le repo Git (relu après commit, jamais depuis le payload)
      │── lecture : git log/diff/refs → écrans Audit, Versions, MR
      │── lecture : Keycloak Admin (users, roles) ; labctl plan/List (preview)
      │── écriture : UNIQUEMENT des commits signés via branche + PR (mode pull_request CRV)
      ▼
Git (repo de gouvernance : tenants/{t}/apis/{slug}/api.yaml + subscriptions/ + evidence/)
      │ webhook
      ▼
Jenkins (docker éphémère) ── labctl apply -f targets.cluster.yaml (air-gapped, vendor/)
      ▼
WSO2 · APISIX · webMethods-mock  (+ n+1 : module MCP dormant — même chaîne)
```

**Décision framework (2026-06-10) — React v1, Angular en point d'extension :**
Le client a une préférence Angular (compétence de ses équipes). Décision : **v1 en React** — la carrière réutilisable (~12k LOC : écrans 4-yeux, design system, RBAC) est React, et la Console est un *produit* maintenu par STOA (ADR-069 « produit, pas TMA »), pas un développement custom hérité par le client. L'argument Angular ne vaut que pour du code que le client possède : la réponse produit est **API-first** — leurs équipes Angular étendent via le BFF (REST/OIDC), option web components pour l'embed. **Trigger de révision** : si l'appel d'offres classe la console comme développement custom maintenable par les équipes client (à vérifier — question ajoutée au cadrage client), réévaluer un front Angular comme réécriture bornée sur le même BFF (les écrans v1 + Gherkin = la spec).

**Décisions d'implémentation :**
- BFF en Go **dans le module labctl** (recommandation inventaire) : import direct du moteur (`Adapter.Publish/List/CreateConsumer`, `keycloak.EnsureClient`) — le CLI reste une coque mince sur les mêmes packages, cohérent CLI-en-CI.
- **Pré-requis labctl (double usage CLI + BFF)** : `--output json` (sérialiser les `publishOutcome/consumerOutcome` existants) + verbe `plan`/`diff` (List vs NormalizedAPI désiré, le flag `Created` existe déjà). Le JSON devient à la fois le payload de l'écran de validation ET l'évidence.
- **Multi-API** : convention répertoire-par-API dans Git (`tenants/{t}/apis/{slug}/`), le manifeste FederationTarget reste 1-contrat (généré par le BFF par API).
- **Secrets** : sortir les credentials de `targets.yaml` (placeholders PoC en clair) → variables d'env injectées par Jenkins ; jamais dans Git.
- **Schéma de contrat** : `uac_contract_v1_schema.json` (le canonique, 279 lignes, classification DORA H/VH/VVH, `endpoint.llm` avec `destructive⇒requires_human_approval`) — PAS `stoa-catalog/uac.schema.json` (contrat de TENANT, autre usage ; ne pas confondre, dette CAB-2135).

## 6. Spec d'acceptance

- **Reprise** (~14 features Gherkin de la carrière, texte conservé, personas renommés, steps réécrits) : console-rbac, console-admin-rbac, console-audit-log, console-access-requests, console-isolation, integration-tenant-isolation, integration-contract-lifecycle, portal-catalog, portal-contracts, subscription-workflow, portal-consumer-flow, console-promotions, integration-promotion-flow, console-federation.
- **À écrire de neuf** (~8 features — la valeur différenciante du pivot) :
  1. Approbation → commit signé + évidence référencée (le scénario-clé absent de la carrière)
  2. Refus RBAC **audité** (le deny apparaît dans la piste)
  3. Rejet motivé d'une demande
  4. Quatre-yeux : le demandeur ne peut pas approuver sa propre promotion prod
  5. Login SSO via broker Oracle-master (mapping claims → rôles)
  6. Promotion prod gated par approbation
  7. Correspondance 1:1 entrée d'audit ↔ commit Git (sha, signature, auteur)
  8. Validation inline éditeur UAC (schéma + règle destructive)
- **Transcrire CRV-1..CRV-6** (catalog-release-versioning-contract.md) en scénarios du BFF.
- Conventions reprises : tags @smoke/@critical, personas multi-tenant antagonistes, evidence archive après chaque run.
- **Seed démo** : `stoa-catalog/tenants/banking-demo/uac.yaml` (narratif « regulated EU banking » déjà écrit) + les 4 exemples UAC gradués de `specs/uac/examples/` (le `03-destructive` déclenche la gate d'approbation humaine en démo).

## 7. Hors scope v1 (liste fermée)

Observabilité/métriques temps réel (Grafana du PoC suffit), analytique de transactions OpenSearch (slot 3 du Doc 4 — v2), portail consommateur self-service externe, écrans data-plane, chat/IA (module dormant), rollback automatisé (manuel via git revert documenté), notifications email, SCIM, i18n complet (français des 12 écrans seulement, la démo est en français), Backstage (cible d'intégration future, pas dépendance), mobile.

## 8. Plan borné

| Phase | Contenu | Budget | Jalon binaire |
|---|---|---|---|
| **0 — Prérequis** | Valider le scaffold CI **live** (commit → webhook → Jenkins → labctl apply ; thread #2 HANDOFF, jamais exécuté) ; labctl `--output json` + `plan` ; client Keycloak `console-light` ; users démo | 2-3 j | un commit dans Gitea déclenche un apply Jenkins qui converge les 3 gateways |
| **1 — Socle** | Vendoriser @stoa/shared ; AuthContext/PermissionGate/Layout réduit ; BFF squelette (OIDC + lecture Git : tenants, contrats, git log) | 3-4 j | login alice → catalogue de son tenant s'affiche depuis Git |
| **2 — Lecture** | Écrans 1-5 (Tenants, Rôles, Audit, Catalogue, Détail) + écran 10 (cibles + health) | 3-4 j | audit affiche les commits réels avec sha |
| **3 — Écriture gouvernée** | Éditeur + validation (6), publication = PR/commit signé, Promotions 4-yeux (7), Souscriptions (8), MR review (11), evidence pack généré, dashboard (12), users/rôles (9) | 5-6 j | le parcours démo §1 passe en local |
| **4 — Démo** | Seed banking-demo, smoke binaire (gabarit demo-scope.md : verdicts REAL_PASS, jamais MOCK_PASS pour « demo ready »), libellés FR, captures d'évidence, répétition | 2-3 j | parcours 15 min joué 2× sans incident |

**Total : 15-20 jours bornés.**

**Kill-triggers (contractuels, anti-boucle de réécriture) :**
- Phase 0 > 4 jours → STOP et re-cadrage (si le flux CI ne se valide pas, rien d'autre ne compte).
- Phase 3 > 8 jours → couper au parcours démo strict : sacrifier dans l'ordre bulk actions, écran users/rôles en écriture, MR review (l'approbation Promotions suffit), dashboard.
- 2 échecs d'Edit consécutifs sur un même fichier cloné → rewrite complet du fichier, pas de 3ᵉ patch (règle existante).
- Toute envie d'ajouter un écran hors liste §4 → inscription en backlog v2, jamais dans la v1.

## 9. Risques

| Risque | Impact | Mitigation |
|---|---|---|
| Scaffold CI jamais exécuté live (thread #2) | bloque le principe n°1 | Phase 0 AVANT tout le reste, kill-trigger 4 j |
| State machine d'approbation côté Git plus subtile que prévu (statuts pending/active sans DB) | Phase 3 déborde | statuts = position du fichier (branche PR = pending, mergé = approved) + labels ; pas d'état hors Git |
| Gotcha Keycloak : recreate efface les clients runtime | démo cassée | client console-light ajouté dans `realm-stoa-lab.json` (import au boot = seule persistance) |
| WSO2 lent/lourd (~3 min, 16 Go) | démo fragile | ordre de boot scripté (scripts/up.sh existant), `docker restart` jamais recreate |
| Re-sprawl (la carrière donne envie de tout reprendre) | perte de focus | liste d'écrans fermée §4, hors-scope fermé §7, kill-triggers §8 |

## 10. Backlog v2 (pour mémoire, PAS v1)

Analytique transactions OpenSearch DLS/FLS avec `provider_id` (slot 3 Doc 4), module MCP dormant activable (n+1 Mistral), intégration Backstage (catalog locations — le générateur d'entité existe dans labctl), portail consommateur, drift detection visuelle (Git vs runtime), rollback one-click, sidecar Envoy/OPA comme 4ᵉ cible de projection.
