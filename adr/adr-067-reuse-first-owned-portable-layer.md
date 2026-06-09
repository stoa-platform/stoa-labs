---
title: "ADR-067 — Reuse-first : couche possédée portable au-dessus de runtimes commodity fédérés"
sidebar_label: "ADR-067 : Reuse-first"
status: "Proposé — en attente Council 8/10 (GO/NO-GO)"
date: 2026-06-07
adr_number: 67
visibility: private
note: "Hébergé dans stoa-labs (privé), PAS dans stoa-docs (public) — contient stratégie commerciale + engagement client anonymisé. Numéro 067 réservé dans la séquence org pour éviter collision."
---

# ADR-067 — Reuse-first : couche possédée portable, runtimes commodity fédérés

**Statut :** Proposé — en attente validation Council 8/10 (GO/NO-GO).
**Date :** 2026-06-07.
**Contexte client (anonymisé) :** banque centrale (Eurosystème).

> ⚠️ **Confidentialité.** Cet ADR contient de la stratégie GTM et un engagement client. Il vit dans `stoa-labs` (privé) et **ne doit pas** être porté dans `stoa-docs` (public, indexable sur docs.gostoa.dev). Toute version publique devra être assainie (principe d'archi seul, sans client / SAP / pricing / personas).

---

## Décision (test « archi 40 ans / 30 secondes »)

> On pointe le levier IA sur la **couche qu'on possède et qui survit au changement de runtime** (adapters, portail, orchestrateur, RBAC, self-service, contrats). On **fédère et réutilise** le commodity (runtimes, identité, observabilité). On **ne touche pas** la surface propriétaire de l'éditeur (jetée à la migration, lockée, insécure).
> Règle de tri pour tout nouvel élément : **« Je le possède ? Son *contrat/intention* (OpenAPI, policy) survit-il à la bascule SAP — même si son *implémentation* est re-ciblée ? »** Deux *oui* → on build, mais on possède l'**intention**, pas l'implémentation jetable. Sinon → on réutilise, ou on ne le fait pas.

---

## Contexte et problème

Le client gèle son contrat IBM/webMethods : plus d'évolution sur webMethods. S'ouvre un **intérim hybride ~2 ans** (custom cloud + legacy sur VM), avec une **cible probable à 2 ans : SAP Integration Suite** (alignement BCE). SAP comble vite l'objection souveraineté (Sovereign Cloud On-Site, hub FR ~2027), donc la souveraineté seule n'est plus un argument suffisant.

Contrainte économique structurante : **l'IA effondre le coût d'*écrire* le code, pas le coût de le *posséder*** (maintenance, sécurité, gouvernance, certification, bus-factor). La revue automatisée devient cheap pour la *correction* (low-stakes), pas pour l'*intention*, la *responsabilité réglementaire* (DORA) ni l'*assurance indépendante* — précisément ce qui domine en banque centrale. Conséquence : le custom code se **commoditise**, et la valeur durable migre vers ce qui ne se régénère pas — **produit possédé, contrats portables, gouvernance**.

Question à trancher : **où investir la customisation pour qu'elle capitalise et se ré-adapte sur SAP, à un coût inférieur à SAP et IBM.**

## Forces en présence (decision drivers)

- Portabilité IBM → hybride → SAP **sans réécriture de la gouvernance**.
- Souveraineté de la **couche de gouvernance** (on-prem, possédée), même si le control plane SAP reste un service managé.
- Coût de customisation **inférieur aux éditeurs**, amorti sur l'intérim + le futur SAP + le multi-clients (produit STOA).
- Sécurité, gouvernance et RBAC **par construction** — absents des surfaces propriétaires.
- Maintenabilité en **structure légère** (solo + canal ESN) : pas de bus-factor sur N forks bespoke.
- Anti-§7.6 (pas de moteur de fédération lourd maison) et AMARIS (pas d'architecture pilotée par l'opportunité).
- Le **levier IA** doit être dirigé vers la couche durable, pas vers le code jetable.

## Options considérées

1. **Tout custom maison** (rebuild gateway + ESB + portail + gouvernance). *Rejeté* : §7.6, lock-in interne, bus-factor, coût de possession — que l'IA ne réduit pas.
2. **Tout SAP-natif** (attendre SAP, customiser dans BTP / Site Editor). *Rejeté* : custom locké, payant à étendre, jeté à toute évolution hors SAP, couche de gouvernance dans un service managé ; ne couvre ni l'intérim, ni le legacy en drain, ni le non-SAP.
3. **Remplacer tout par de l'OSS** (PoC initial « OSS remplace webMethods »). *Rejeté* : ce n'est plus le sujet (SAP est la cible), chantier de remplacement lourd, ne raconte pas la transition.
4. **Approfondir la surface propriétaire** (web components webMethods, extensions BTP). *Rejeté* : insécure, non gouverné, jeté, locké — l'exemple même du custom à éviter.
5. **★ Reuse-first : couche possédée portable + runtimes commodity fédérés.** *Retenu.*

## Décision retenue — la règle des trois bacs

| Bac | Nature | Quoi | Posture |
|---|---|---|---|
| **A — BUILD** | Possédé + portable | Adapters, portail découplé, orchestrateur mince, RBAC lié à l'IdP master, self-service, contrats OpenAPI/Git, store d'audit | **Build vite avec l'IA**, custom *aux coutures* |
| **B — FÉDÈRE / RÉUTILISE** | Commodity | Runtimes (webMethods → APISIX → SAP), Keycloak, OTel, OpenSearch | **Jamais reconstruit** |
| **C — NE TOUCHE PAS** | Propriétaire (jeté + locké + insécure) | Web components webMethods, extensions BTP profondes, logique de médiation détournée en customisation | **Évité** |

**Decision gate** (tout nouvel élément) : « Je le possède ? Son **contrat/intention** (OpenAPI, policy) survit-il à la bascule SAP — même si son **code** est re-ciblé ? » → 2× *oui* = BUILD.

> **Précision sur les adapters (correctif Council).** Un adapter est **Bac A par son *contrat*** (l'intention captée — durable, porte sur SAP) mais **jetable par son *code*** (l'implémentation par-runtime : un adapter webMethods ≠ un adapter SAP). Ce qu'on possède et qui survit, c'est le **contrat + la policy**, pas le connecteur. La gate ne valide donc un BUILD que sur la **partie intention** ; le code de médiation reste explicitement re-ciblable (cf. ligne de partage ci-dessous). Corollaire de gouvernance : borner la masse de code custom des adapters et la couvrir par une **CI de contrat + détection de drift**, pour qu'elle reste « jetable maîtrisée » et non un moteur custom rampant (anti-§7.6).

**Verrou anti-jetable** — standards portables partout : OpenAPI (contrats), OTel (observabilité), OIDC/Keycloak (identité), GitOps (déploiement). Le jour SAP : **on bascule la cible, on ne refait pas la gouvernance.**

**Ligne de partage porte / ne-porte-pas :** la couche **expérience + gouvernance + contrats** porte d'un runtime à l'autre ; la **logique de médiation** (flow services webMethods vs iFlows SAP) **ne porte pas** — on capture l'**intention** (contrat + policy), pas l'implémentation.

## Amorçage (séquencé — chaque étape capitalise et porte sur SAP)

1. **Adapter webMethods + contrats OpenAPI en Git** → legacy fédéré, visible, drainable ; référentiel durable posé.
2. **Portail découplé possédé** (RBAC Keycloak, GitOps) → arrêt de la customisation sur la surface webMethods.
3. **Custom cloud = runtime #2** (APISIX léger + Camel/Quarkus) → les nouvelles APIs hors webMethods.
4. **Adapter SAP (stub) + preuve d'import OpenAPI** → migration dé-risquée dès J0.

## Conséquences

**Positives**
- Investissement de l'intérim **non jeté** à la migration : on re-cible l'adapter.
- Souveraineté de la couche gouvernance **maintenue** même si le control plane SAP est SaaS managé.
- Coût de customisation **< éditeurs**, sécurité/gouvernance/RBAC par construction.
- Maintenable en structure légère, sans bus-factor bespoke.
- **Renforcé par le progrès de l'IA** : plus le code devient cheap, plus le moat se déplace vers le produit possédé + les contrats + la gouvernance — exactement cette architecture.

**Négatives / risques (assumés)**
- Plus de glue d'intégration que la voie tout-éditeur ; les adapters sont à maintenir quand les admin APIs bougent.
- La logique de médiation reste **par-runtime** (webMethods → SAP = rebuild, pas portage).
- Si le SAP Sovereign Cloud On-Site couvre l'Integration Suite **et** que Joule répond au besoin agent, la surface durable de STOA se réduit au multi-runtime/vendor-neutral + le pont → **concevoir l'intérim pour qu'il se rentabilise seul**.
- Le PoC doit **séparer explicitement** le scaffold jetable (orchestrateur de démo) de la valeur produit, sinon on livre le plan du build-it-yourself (risque Gekk0). Cf. [`../poc-control-plane-federation/POSITIONING.md`](../poc-control-plane-federation/POSITIONING.md).
- Dépendance à des briques OSS : choisir des versions **supportées** pour une banque (ex. RHDH plutôt que Backstage nu).

## Non couvert / différé (à tracer ailleurs)

- **Reverse Invoke / zéro entrant** (critère éliminatoire de l'étude) → topologie de déploiement, ADR séparé. Cf. [`../poc-control-plane-federation/HARD-CRITERIA-MAP.md`](../poc-control-plane-federation/HARD-CRITERIA-MAP.md).
- **Chiffrage BUILD/RUN 5 ans** (template BdF) → Notion (business/CIR).
- **Gouvernance agent/MCP** → ADR séparé.

## Références

- Étude alternatives API Management & intégration (interne, anonymisé) — §7.6 (anti-moteur-custom), registre AMARIS.
- Doc « Capitalisation customisation webMethods → SAP ».
- PoC `stoa-labs` — [`../poc-control-plane-federation/PLAN.md`](../poc-control-plane-federation/PLAN.md) (fédération webMethods / APISIX / stand-in SAP).

## Definition of Done de cet ADR

- Validé Council **8/10** (GO/NO-GO).
- La règle des trois bacs + la decision gate sont **applicables telles quelles** à toute nouvelle décision build/reuse.
- La partition est comprise par un architecte de 40 ans d'expérience **en 30 secondes**.

---

## Point de réconciliation — TRANCHÉ (2026-06-08)

**Décision : on garde WSO2 dans le PoC ; le stand-in SAP est différé.** SAP n'est pas pour tout de suite — l'amorçage (étape 4 « Adapter SAP stub ») reste planifié mais hors du jet courant.

Cela ne contredit pas la règle des trois bacs : **WSO2 est un runtime commodity du Bac B (FÉDÈRE/RÉUTILISE)**, au même titre qu'APISIX ou, demain, SAP. Le « stand-in SAP » n'était qu'une illustration du 3ᵉ runtime ; la **couche possédée (Bac A) reste identique quel que soit le runtime fédéré**. Le PoC conserve donc le lineup validé **« WSO2 / APISIX / webMethods »** ; le `PLAN.md` est inchangé. Quand SAP deviendra la cible vivante, on **ajoute** l'adapter SAP (Bac B) sans toucher à la couche possédée — ce qui *est précisément* la thèse de cet ADR.
