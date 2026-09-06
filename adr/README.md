# ADRs — stoa-labs (privé)

Décisions d'architecture **internes / sensibles** (engagements clients anonymisés, stratégie GTM) qui ne peuvent **pas** vivre dans `stoa-docs` (public, indexable sur docs.gostoa.dev).

> Les ADR **produit/technique** publics restent dans `stoa-docs/docs/architecture/adr/`. Ici : uniquement ce qui doit rester privé. Les numéros suivent la **séquence org** pour éviter toute collision.

| ADR | Titre | Statut | Date |
|-----|-------|--------|------|
| [ADR-067](./adr-067-reuse-first-owned-portable-layer.md) | Reuse-first — couche possédée portable, runtimes commodity fédérés | Proposé (Council 8/10) | 2026-06-07 (rév. 2026-06-10) |
| [ADR-068](./adr-068-stoa-off-the-transaction-path.md) | STOA hors du chemin transactionnel — control plane sortant-only ; Reverse Invoke transactionnel = capacité gateway | Proposé (Council 8/10) | 2026-06-09 |
| [ADR-069](./adr-069-retention-moat-governance-source-of-truth.md) | Douve de rétention — gouvernance comme source de vérité vendor-neutral (survit à SAP+Joule ET à un pull GitOps) | Proposé (Council 8/10) | 2026-06-09 |

## Convention

- Fichier : `adr-<NNN>-<slug>.md`, numéro pris dans la séquence org (le dernier public dans stoa-docs est ADR-066).
- Frontmatter : `visibility: private` obligatoire.
- Toute version publiable doit être **assainie** (principe d'archi seul, sans client / éditeur cible / pricing / personas).
