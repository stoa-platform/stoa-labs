import { useQuery } from '@tanstack/react-query';
import { Building2, FileText, GitBranch } from 'lucide-react';
import { apiService } from '../services/api';
import { useAuth } from '../contexts/AuthContext';
import { EmptyState } from '../vendor/stoa-shared/components/EmptyState';
import { CardSkeleton } from '../vendor/stoa-shared/components/Skeleton';
import { getFriendlyErrorMessage } from '../vendor/stoa-shared/utils/errorMessages';

/**
 * Écran 1 (CADRAGE §4) — Tenants, lecture seule.
 * Porté de la carrière (control-plane-ui/src/pages/Tenants.tsx) : grid de
 * cards + bannière GitOps. Branché sur apiService.getTenants() (contrat §4),
 * scope tenant appliqué côté BFF (cpi-admin voit tout).
 */

const STATUS_STYLES: Record<string, string> = {
  active: 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400',
  suspended: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-400',
  pending: 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-400',
};

const STATUS_LABELS: Record<string, string> = {
  active: 'Actif',
  suspended: 'Suspendu',
  pending: 'En attente',
};

const DEFAULT_STATUS_STYLE =
  'bg-neutral-100 text-neutral-700 dark:bg-neutral-700 dark:text-neutral-300';

export default function Tenants() {
  const { isReady } = useAuth();

  const {
    data: tenants = [],
    isLoading,
    error,
  } = useQuery({
    queryKey: ['tenants'],
    queryFn: () => apiService.getTenants(),
    enabled: isReady,
  });

  if (isLoading) {
    return (
      <div data-testid="page-tenants" className="space-y-6 animate-fade-in">
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
          {[1, 2, 3].map((i) => (
            <CardSkeleton key={i} />
          ))}
        </div>
      </div>
    );
  }

  return (
    <div data-testid="page-tenants" className="space-y-6 animate-fade-in">
      {/* En-tête */}
      <div className="flex flex-wrap justify-between items-center gap-3">
        <div>
          <h1 className="text-2xl font-bold text-neutral-900 dark:text-white">Tenants</h1>
          <p className="text-neutral-500 dark:text-neutral-400 mt-1">
            Les tenants du dépôt de gouvernance — lecture seule dans la console.
          </p>
        </div>
        <div
          className="inline-flex items-center gap-2 text-sm text-neutral-600 dark:text-neutral-300 bg-neutral-100 dark:bg-neutral-800 px-3 py-2 rounded-lg"
          data-testid="tenants-gitops-pill"
        >
          <GitBranch className="h-4 w-4 text-neutral-500 dark:text-neutral-400" />
          Géré via GitOps
        </div>
      </div>

      {/* Erreur de chargement */}
      {error != null && (
        <div
          className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 text-red-700 dark:text-red-400 px-4 py-3 rounded-lg"
          role="alert"
        >
          {getFriendlyErrorMessage(error, 'Impossible de charger les tenants.')}
        </div>
      )}

      {/* Grid de tenants */}
      {!error && (
        <div
          className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6"
          role="list"
          aria-label="Tenants"
          data-testid="tenants-grid"
        >
          {tenants.length === 0 ? (
            <div className="col-span-full bg-white dark:bg-neutral-800 rounded-lg shadow">
              <EmptyState
                variant="users"
                title="Aucun tenant"
                description="Les tenants sont provisionnés dans le dépôt Git de gouvernance — aucun n’est visible avec votre scope actuel."
                illustration={
                  <div className="w-24 h-24 rounded-2xl bg-gradient-to-br from-purple-50 to-purple-100 dark:from-purple-950 dark:to-purple-900 flex items-center justify-center">
                    <Building2 className="w-10 h-10 text-purple-500" />
                  </div>
                }
              />
            </div>
          ) : (
            tenants.map((tenant) => (
              <div
                key={tenant.id}
                role="listitem"
                className="bg-white dark:bg-neutral-800 rounded-lg shadow p-6 hover:shadow-md transition-shadow"
                data-testid={`tenant-card-${tenant.id}`}
              >
                <div className="flex justify-between items-start mb-4 gap-3">
                  <div className="min-w-0">
                    <h3
                      className="text-lg font-semibold text-neutral-900 dark:text-white truncate"
                      data-testid="tenant-name"
                    >
                      {tenant.displayName || tenant.name}
                    </h3>
                    <p className="text-sm text-neutral-500 dark:text-neutral-400 font-mono truncate">
                      {tenant.name}
                    </p>
                  </div>
                  <span
                    className={`px-2 py-1 text-xs font-medium rounded-full flex-shrink-0 ${
                      STATUS_STYLES[tenant.status] ?? DEFAULT_STATUS_STYLE
                    }`}
                    data-testid="tenant-status"
                  >
                    {STATUS_LABELS[tenant.status] ?? tenant.status}
                  </span>
                </div>

                <div className="space-y-2 text-sm text-neutral-600 dark:text-neutral-300">
                  <div className="flex justify-between gap-3">
                    <span className="text-neutral-500 dark:text-neutral-400">Identifiant</span>
                    <span className="font-mono text-xs truncate">{tenant.id}</span>
                  </div>
                  <div className="flex justify-between gap-3">
                    <span className="text-neutral-500 dark:text-neutral-400">Offre</span>
                    <span className="capitalize">{tenant.tier || '—'}</span>
                  </div>
                  <div className="flex justify-between gap-3">
                    <span className="text-neutral-500 dark:text-neutral-400">Contrats</span>
                    <span className="inline-flex items-center gap-1.5">
                      <FileText className="h-3.5 w-3.5 text-neutral-400" />
                      {tenant.apis_count}
                    </span>
                  </div>
                </div>
              </div>
            ))
          )}
        </div>
      )}

      {/* Bannière GitOps */}
      <div className="bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg p-4">
        <div className="flex gap-3">
          <GitBranch className="w-5 h-5 text-blue-600 dark:text-blue-400 flex-shrink-0 mt-0.5" />
          <div>
            <h4 className="text-sm font-medium text-blue-800 dark:text-blue-400">
              Géré via GitOps — source de vérité : Git
            </h4>
            <p className="text-sm text-blue-700 dark:text-blue-300 mt-1">
              Les tenants sont déclarés dans le dépôt de gouvernance
              (<span className="font-mono text-xs">tenants/&#123;tenant&#125;/tenant.yaml</span>).
              Toute modification passe par un commit signé — la console n’écrit jamais
              cette ressource.
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}
