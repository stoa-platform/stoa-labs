/**
 * Façade apiService — expose TOUTES les méthodes du §4 d'API-CONTRACT.md, typées.
 * Pattern carrière : clients par ressource derrière une façade unique,
 * consommée via TanStack Query dans les écrans.
 */

import { http } from './httpClient';
import type {
  EnvChainInfo,
  ApprovePromotionResponse,
  AuditEntry,
  ContractDetail,
  ContractSummary,
  CreatePromotionRequest,
  Dashboard,
  EnvironmentName,
  GovernanceAction,
  Me,
  Promotion,
  PromotionDiff,
  PromotionStatus,
  PublishContractResponse,
  Role,
  Subscription,
  SubscriptionActionResponse,
  SubscriptionStatus,
  Target,
  Tenant,
  UacContract,
  UpdateContractResponse,
  User,
  ValidationResult,
} from '../../types';

const enc = encodeURIComponent;

export const apiService = {
  // ==========================================================================
  // Identité
  // ==========================================================================

  /** GET /me — profil, rôles, permissions et tenant de l'acteur. */
  getMe(): Promise<Me> {
    return http.get<Me>('/me');
  },

  /** GET /environments — la chaîne de promotion + les gates par hop (source de
   * vérité pour l'UI : hops sélectionnables, champs change_ref/pv_ref exigés,
   * blocage 4-yeux). Jamais de nom d'env codé en dur côté client. */
  getEnvironments(): Promise<EnvChainInfo> {
    return http.get<EnvChainInfo>('/environments');
  },

  // ==========================================================================
  // Tenants
  // ==========================================================================

  /** GET /tenants — scopé par le BFF (cpi-admin voit tout). */
  getTenants(): Promise<Tenant[]> {
    return http.get<Tenant[]>('/tenants');
  },

  // ==========================================================================
  // Contrats UAC
  // ==========================================================================

  /** GET /tenants/{t}/contracts — catalogue des contrats d'un tenant. */
  getContracts(tenant: string): Promise<ContractSummary[]> {
    return http.get<ContractSummary[]>(`/tenants/${enc(tenant)}/contracts`);
  },

  /** GET /tenants/{t}/contracts/{slug} — contrat + versions Git + déploiements. */
  getContract(tenant: string, slug: string): Promise<ContractDetail> {
    return http.get<ContractDetail>(`/tenants/${enc(tenant)}/contracts/${enc(slug)}`);
  },

  /**
   * POST /tenants/{t}/contracts/{slug}/validate — validation serveur
   * (schéma §5 + règle destructive ⇒ requires_human_approval).
   */
  validateContract(tenant: string, slug: string, contract: UacContract): Promise<ValidationResult> {
    return http.post<ValidationResult>(
      `/tenants/${enc(tenant)}/contracts/${enc(slug)}/validate`,
      contract
    );
  },

  /** PUT /tenants/{t}/contracts/{slug} — enregistre (mode draft) → commit signé. */
  updateContract(
    tenant: string,
    slug: string,
    body: { contract: UacContract; message?: string }
  ): Promise<UpdateContractResponse> {
    return http.put<UpdateContractResponse>(
      `/tenants/${enc(tenant)}/contracts/${enc(slug)}`,
      body
    );
  },

  /** POST /tenants/{t}/contracts/{slug}/publish — publication dev = commit direct sur main + évidence. */
  publishContract(
    tenant: string,
    slug: string,
    body: { message: string }
  ): Promise<PublishContractResponse> {
    return http.post<PublishContractResponse>(
      `/tenants/${enc(tenant)}/contracts/${enc(slug)}/publish`,
      body
    );
  },

  // ==========================================================================
  // Promotions (4-yeux)
  // ==========================================================================

  /** GET /tenants/{t}/promotions?status= — statut dérivé de la position Git. */
  getPromotions(tenant: string, status?: PromotionStatus): Promise<Promotion[]> {
    return http.get<Promotion[]>(`/tenants/${enc(tenant)}/promotions`, { status });
  },

  /** POST /tenants/{t}/promotions — demande (message obligatoire ≤ 1000 c, chaînes dev→staging, staging→production). */
  createPromotion(tenant: string, body: CreatePromotionRequest): Promise<{ promotion: Promotion }> {
    return http.post<{ promotion: Promotion }>(`/tenants/${enc(tenant)}/promotions`, body);
  },

  /** GET /tenants/{t}/promotions/{id}/diff — vrai git diff de la branche de promotion. */
  getPromotionDiff(tenant: string, id: string): Promise<PromotionDiff> {
    return http.get<PromotionDiff>(`/tenants/${enc(tenant)}/promotions/${enc(id)}/diff`);
  },

  /**
   * POST /tenants/{t}/promotions/{id}/approve — 4-yeux côté BFF :
   * 403 SELF_APPROVAL_BLOCKED si to == production et requested_by == acteur.
   * Approve = merge --no-ff signé sur main + évidence.
   */
  approvePromotion(
    tenant: string,
    id: string,
    body?: { message?: string }
  ): Promise<ApprovePromotionResponse> {
    return http.post<ApprovePromotionResponse>(
      `/tenants/${enc(tenant)}/promotions/${enc(id)}/approve`,
      body ?? {}
    );
  },

  /** POST /tenants/{t}/promotions/{id}/reject — rejet motivé (reason obligatoire). */
  rejectPromotion(
    tenant: string,
    id: string,
    body: { reason: string }
  ): Promise<{ promotion: Promotion }> {
    return http.post<{ promotion: Promotion }>(
      `/tenants/${enc(tenant)}/promotions/${enc(id)}/reject`,
      body
    );
  },

  // ==========================================================================
  // Souscriptions
  // ==========================================================================

  /** GET /subscriptions?tenant=&status= */
  getSubscriptions(params?: {
    tenant?: string;
    status?: SubscriptionStatus;
  }): Promise<Subscription[]> {
    return http.get<Subscription[]>('/subscriptions', {
      tenant: params?.tenant,
      status: params?.status,
    });
  },

  /** POST /subscriptions/{id}/approve — commit + évidence. */
  approveSubscription(id: string): Promise<SubscriptionActionResponse> {
    return http.post<SubscriptionActionResponse>(`/subscriptions/${enc(id)}/approve`);
  },

  /** POST /subscriptions/{id}/reject — rejet motivé (reason obligatoire). */
  rejectSubscription(id: string, body: { reason: string }): Promise<SubscriptionActionResponse> {
    return http.post<SubscriptionActionResponse>(`/subscriptions/${enc(id)}/reject`, body);
  },

  // ==========================================================================
  // Audit
  // ==========================================================================

  /** GET /audit?tenant=&limit=100&action= — git log de main + branches stoa/promote/*. */
  getAudit(params?: {
    tenant?: string;
    limit?: number;
    action?: GovernanceAction;
  }): Promise<AuditEntry[]> {
    return http.get<AuditEntry[]>('/audit', {
      tenant: params?.tenant,
      limit: params?.limit,
      action: params?.action,
    });
  },

  /** GET /audit/export?format=csv|json — fichier avec Content-Disposition. */
  exportAudit(format: 'csv' | 'json'): Promise<{ blob: Blob; filename: string | null }> {
    return http.blob('/audit/export', { format });
  },

  // ==========================================================================
  // Cibles de fédération
  // ==========================================================================

  /** GET /targets — gateways enregistrées + santé (ping ≤ 2 s, jamais bloquant). */
  getTargets(): Promise<Target[]> {
    return http.get<Target[]>('/targets');
  },

  // ==========================================================================
  // Utilisateurs & rôles
  // ==========================================================================

  /** GET /users — Keycloak Admin API (cpi-admin uniquement). */
  getUsers(): Promise<User[]> {
    return http.get<User[]>('/users');
  },

  /** PUT /users/{id}/roles — maj Keycloak + commit d'audit role-change. */
  updateUserRoles(id: string, roles: string[]): Promise<{ user: User }> {
    return http.put<{ user: User }>(`/users/${enc(id)}/roles`, { roles });
  },

  /** GET /roles — définitions statiques §2 + comptes Keycloak. */
  getRoles(): Promise<Role[]> {
    return http.get<Role[]>('/roles');
  },

  // ==========================================================================
  // Dashboard & schéma
  // ==========================================================================

  /** GET /dashboard — compteurs « en attente » + 5 derniers commits. */
  getDashboard(): Promise<Dashboard> {
    return http.get<Dashboard>('/dashboard');
  },

  /** GET /schema/uac — JSON Schema UAC v1 pour la validation ajv côté UI. */
  getUacSchema(): Promise<Record<string, unknown>> {
    return http.get<Record<string, unknown>>('/schema/uac');
  },
};

export type ApiService = typeof apiService;

// Ré-exports utilitaires pour les écrans.
export { ApiError } from './httpClient';
export type { EnvironmentName };
