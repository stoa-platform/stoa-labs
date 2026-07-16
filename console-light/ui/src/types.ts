/**
 * Console Light — types du contrat d'API (API-CONTRACT.md §4 & §5).
 * Toute divergence avec le contrat = bug. Le BFF reste l'autorité.
 */

// ============================================================================
// Environnements & énumérations partagées
// ============================================================================

/** Noms d'environnement tels que portés par le modèle Git (deploy.{env}.yaml). */
// The promotion chain is data-driven (GET /environments) — ADR-075 is
// dev→rec→int→prod, not the historical dev→staging→production. Kept as a string
// so the UI never hardcodes env names (they drift).
export type EnvironmentName = string;

/** One promotion hop's gate, mirroring the BFF (governance.Gate). */
export interface Gate {
  to: string;
  selfApproval?: boolean;
  approverGroup?: string;
  fourEyes?: boolean;
  requireChangeRef?: boolean;
  requirePVRef?: boolean;
  itsmCheck?: boolean;
}

/** Response of GET /environments — the chain + per-target-env gates. */
export interface EnvChainInfo {
  environments: string[];
  gates: Record<string, Gate>;
}

/** Trailer `Action:` des commits de gouvernance (API-CONTRACT §3). */
export type GovernanceAction =
  | 'publish'
  | 'draft'
  | 'promote-request'
  | 'promote-approve'
  | 'promote-reject'
  | 'sub-approve'
  | 'sub-reject'
  | 'role-change'
  | 'deny';

// `rolled_back` is emitted by the BFF when an approved promotion is reverted
// (ADR-075 rollback) — the UI must render it, not crash on an unknown status.
export type PromotionStatus = 'pending' | 'approved' | 'rejected' | 'rolled_back';
export type SubscriptionStatus = 'pending' | 'approved' | 'rejected';
export type TargetHealth = 'up' | 'down' | 'unknown';

// ============================================================================
// Identité & RBAC (§1, §2)
// ============================================================================

/** Réponse de `GET /me`. */
export interface Me {
  username: string;
  name: string;
  email: string;
  roles: string[];
  permissions: string[];
  /** Claim `tenant` du JWT — vide pour cpi-admin (multi-tenant). */
  tenant: string;
}

/** Utilisateur courant côté UI (Me + identifiant OIDC `sub`). */
export interface AuthUser extends Me {
  id: string;
}

/** Réponse de `GET /users` (Keycloak Admin API). */
export interface User {
  id: string;
  username: string;
  email: string;
  roles: string[];
  tenant?: string;
  federated: boolean;
}

/** Réponse de `GET /roles` (définitions statiques §2 + comptes Keycloak). */
export interface Role {
  name: string;
  description: string;
  permissions: string[];
  user_count: number;
}

// ============================================================================
// Tenants (§4)
// ============================================================================

/** Réponse de `GET /tenants` (scopée par le claim tenant côté BFF). */
export interface Tenant {
  id: string;
  name: string;
  displayName: string;
  tier: string;
  status: string;
  apis_count: number;
}

// ============================================================================
// Git / commits
// ============================================================================

/** Référence courte de commit (listes de contrats). */
export interface CommitRef {
  sha7: string;
  author: string;
  date: string;
}

/** Commit retourné par les écritures (PUT/publish/approve). */
export interface CommitInfo {
  sha: string;
  sha7: string;
  signed: boolean;
  message?: string;
}

/** Entrée d'historique Git d'un contrat (onglet Versions). */
export interface ContractVersion {
  sha: string;
  sha7: string;
  author: string;
  date: string;
  message: string;
  signed: boolean;
}

// ============================================================================
// Contrats UAC (§4, §5 — schéma uac_contract_v1_schema.json)
// ============================================================================

// Client-agreed integrity scale (ADR-076 décision #1) : VH > H > M. Replaces the
// former DORA H/VH/VVH — the BFF validates VH/H/M, so the UI must too. A future
// "critical" tier maps 1:1 to the old VVH (non-breaking extension).
export type UacClassification = 'VH' | 'H' | 'M';
export type UacStatus = 'draft' | 'published' | 'deprecated';
export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE' | 'HEAD' | 'OPTIONS';
export type UacSideEffects = 'none' | 'read' | 'write' | 'destructive';

export interface UacEndpointLlmExample {
  input: Record<string, unknown>;
  expected_output_contains?: Record<string, unknown> | null;
}

/**
 * Métadonnées LLM d'un endpoint. Règle sémantique (§5) :
 * side_effects == "destructive" ⇒ requires_human_approval == true
 * (sinon erreur DESTRUCTIVE_REQUIRES_APPROVAL).
 */
export interface UacEndpointLlm {
  summary: string;
  intent: string;
  tool_name: string;
  side_effects: UacSideEffects;
  safe_for_agents: boolean;
  requires_human_approval: boolean;
  examples: UacEndpointLlmExample[];
}

export interface UacEndpoint {
  path: string;
  methods: HttpMethod[];
  backend_url: string;
  operation_id?: string | null;
  input_schema?: Record<string, unknown> | null;
  output_schema?: Record<string, unknown> | null;
  llm?: UacEndpointLlm;
}

export interface UacLlmProvider {
  name: string;
  model: string;
  backend_url: string;
  priority: number;
}

export interface UacLlmCapability {
  capability: 'chat' | 'summarize' | 'embed' | 'classify' | 'extract' | 'generate';
  providers: UacLlmProvider[];
}

export interface UacLlmConfig {
  capabilities: UacLlmCapability[];
  default_timeout_ms?: number | null;
}

/** Contrat UAC v1 — fichier tenants/{t}/apis/{slug}/api.yaml. */
export interface UacContract {
  name: string;
  version: string;
  tenant_id: string;
  display_name?: string | null;
  description?: string | null;
  classification: UacClassification;
  endpoints: UacEndpoint[];
  required_policies?: string[];
  status: UacStatus;
  source_spec_url?: string | null;
  spec_hash?: string | null;
  llm_config?: UacLlmConfig | null;
}

/** Élément de `GET /tenants/{t}/contracts`. */
export interface ContractSummary {
  slug: string;
  name: string;
  version: string;
  status: UacStatus;
  classification: UacClassification;
  endpoints_count: number;
  updated_at: string;
  last_commit: CommitRef;
}

/** État désiré par environnement — deploy.{env}.yaml. */
export interface DeploymentState {
  version: string;
  enabled: boolean;
  promoted_by: string;
}

/** Réponse de `GET /tenants/{t}/contracts/{slug}`. */
export interface ContractDetail {
  contract: UacContract;
  versions: ContractVersion[];
  deployments: {
    dev: DeploymentState | null;
    staging: DeploymentState | null;
    production: DeploymentState | null;
  };
}

/** Réponse de `PUT /tenants/{t}/contracts/{slug}`. */
export interface UpdateContractResponse {
  contract: UacContract;
  commit: CommitInfo;
}

/** Réponse de `POST /tenants/{t}/contracts/{slug}/publish`. */
export interface PublishContractResponse {
  commit: CommitInfo;
  /** Chemin du pack d'évidence commité (evidence/{tenant}/{slug}/…). */
  evidence: string;
}

// ============================================================================
// Validation UAC (§5)
// ============================================================================

export interface ValidationError {
  /** Chemin JSON de l'erreur (ex: endpoints[2].llm.requires_human_approval). */
  path: string;
  message: string;
}

/** Réponse de `POST /tenants/{t}/contracts/{slug}/validate`. */
export interface ValidationResult {
  valid: boolean;
  errors: ValidationError[];
}

// ============================================================================
// Promotions (§4 — 4-yeux, branches stoa/promote/*)
// ============================================================================

export interface Promotion {
  id: string;
  slug: string;
  from: EnvironmentName;
  to: EnvironmentName;
  requested_by: string;
  message: string;
  status: PromotionStatus;
  created_at: string;
  /** Branche Git stoa/promote/{tenant}/{slug}/{id}. */
  branch: string;
  approved_by?: string;
  reason?: string;
}

/** Réponse de `GET /tenants/{t}/promotions/{id}/diff`. */
export interface PromotionDiff {
  /** Diff unifié texte (vrai git diff). */
  diff: string;
  files: Array<{
    path: string;
    additions: number;
    deletions: number;
  }>;
}

export interface CreatePromotionRequest {
  slug: string;
  from: EnvironmentName;
  to: EnvironmentName;
  /** Message d'audit obligatoire, ≤ 1000 caractères. */
  message: string;
  /** Référence de change ITSM — obligatoire si le gate du hop cible l'exige. */
  change_ref?: string;
  /** Référence de PV de recette — obligatoire si le gate du hop cible l'exige. */
  pv_ref?: string;
}

/** Réponse de `POST /tenants/{t}/promotions/{id}/approve` (merge signé + évidence). */
export interface ApprovePromotionResponse {
  promotion: Promotion;
  merge_commit: CommitInfo;
  evidence: string;
}

// ============================================================================
// Souscriptions (§4 — fichiers subscriptions/{tenant}/{id}.yaml)
// ============================================================================

export interface Subscription {
  id: string;
  tenant: string;
  api: string;
  consumer: string;
  requested_by: string;
  status: SubscriptionStatus;
  created_at: string;
  reason?: string;
}

export interface SubscriptionActionResponse {
  subscription: Subscription;
  commit: CommitInfo;
}

// ============================================================================
// Audit (§4 — git log de main + branches stoa/promote/*)
// ============================================================================

export interface AuditEntry {
  sha: string;
  sha7: string;
  author: string;
  email: string;
  date: string;
  action: GovernanceAction;
  /** Trailer Resource: {tenant}/{slug ou id}. */
  resource: string;
  actor: string;
  /** Rôles de l'acteur au moment de l'action (trailer Roles). */
  roles: string[];
  message: string;
  signed: boolean;
  /** Chemin du pack d'évidence, ou null si aucun (trailer Evidence: —). */
  evidence: string | null;
}

// ============================================================================
// Cibles de fédération (§4)
// ============================================================================

export interface Target {
  name: string;
  type: string;
  adminUrl: string;
  gatewayUrl: string;
  health: TargetHealth;
  latency_ms?: number;
}

// ============================================================================
// Dashboard (§4)
// ============================================================================

export interface Dashboard {
  pending_promotions: number;
  pending_subscriptions: number;
  contracts: number;
  tenants: number;
  /** Les 5 derniers commits de gouvernance (format AuditEntry). */
  last_commits: AuditEntry[];
}

// ============================================================================
// Erreurs (§4 — forme {error: {code, message}})
// ============================================================================

/** Codes d'erreur connus du contrat. */
export type KnownErrorCode = 'SELF_APPROVAL_BLOCKED' | 'DESTRUCTIVE_REQUIRES_APPROVAL';

export interface ApiErrorBody {
  error: {
    code: string;
    message: string;
  };
}
