import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { Building2, GitCommit, Layers } from 'lucide-react';
import { apiService } from '../services/api';
import { useAuth } from '../contexts/AuthContext';
import { CardSkeleton } from '../vendor/stoa-shared/components/Skeleton';
import { EmptyState } from '../vendor/stoa-shared/components/EmptyState';
import type { ContractSummary, UacClassification, UacStatus } from '../types';

/**
 * Écran 4 (CADRAGE §4) — Catalogue des contrats UAC (fichiers api.yaml dans Git).
 * Porté de la carrière (control-plane-ui/src/pages/Contracts.tsx), vue LISTE
 * seulement, branché sur apiService.getContracts (API-CONTRACT §4).
 * cpi-admin (claim tenant vide) choisit le tenant ; les autres rôles sont
 * scopés par leur JWT.
 */

const STATUS_LABELS: Record<UacStatus, string> = {
  draft: 'Brouillon',
  published: 'Publié',
  deprecated: 'Déprécié',
};

const STATUS_STYLES: Record<UacStatus, string> = {
  draft: 'bg-neutral-100 text-neutral-600 dark:bg-neutral-700 dark:text-neutral-300',
  published: 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400',
  deprecated: 'bg-yellow-100 text-yellow-700 dark:bg-yellow-900/30 dark:text-yellow-400',
};

const CLASSIFICATION_LABELS: Record<UacClassification, string> = {
  M: 'Moyenne',
  H: 'Haute',
  VH: 'Très haute (critique)',
};

// VH (sommet de l'échelle client, OAuth2+mTLS) en ROUGE — la criticité bancaire
// doit sauter aux yeux.
const CLASSIFICATION_STYLES: Record<UacClassification, string> = {
  M: 'bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-400',
  H: 'bg-orange-100 text-orange-700 dark:bg-orange-900/30 dark:text-orange-400',
  VH: 'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400',
};

function formatDate(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleDateString('fr-FR', { day: '2-digit', month: '2-digit', year: 'numeric' });
}

export default function Contracts() {
  const navigate = useNavigate();
  const { user, hasRole } = useAuth();
  const isAdmin = hasRole('cpi-admin');
  const [selectedTenant, setSelectedTenant] = useState('');

  // Sélecteur de tenant pour cpi-admin uniquement (les autres rôles sont
  // scopés par le claim `tenant` du JWT — API-CONTRACT §2).
  const { data: tenants = [], isLoading: tenantsLoading } = useQuery({
    queryKey: ['tenants'],
    queryFn: () => apiService.getTenants(),
    enabled: isAdmin,
  });

  const tenant = isAdmin ? selectedTenant || tenants[0]?.id || '' : (user?.tenant ?? '');

  const {
    data: contracts = [],
    isLoading,
    isError,
    refetch,
  } = useQuery({
    queryKey: ['contracts', tenant],
    queryFn: () => apiService.getContracts(tenant),
    enabled: Boolean(tenant),
  });

  const sorted = useMemo(
    () => [...contracts].sort((a, b) => a.slug.localeCompare(b.slug)),
    [contracts]
  );

  const openDetail = (contract: ContractSummary) => {
    // Le tenant voyage en query param pour cpi-admin (la route ne le porte pas).
    const suffix = isAdmin && tenant ? `?tenant=${encodeURIComponent(tenant)}` : '';
    navigate(`/contracts/${contract.slug}${suffix}`);
  };

  const showSkeletons = isLoading || (isAdmin && tenantsLoading && !tenant);

  return (
    <div data-testid="page-contracts" className="space-y-6 animate-fade-in">
      {/* En-tête */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-neutral-900 dark:text-white">
            Catalogue des contrats
          </h1>
          <p className="mt-1 text-sm text-neutral-500 dark:text-neutral-400">
            Contrats UAC du tenant — chaque contrat est un fichier versionné dans le dépôt de
            gouvernance.
          </p>
        </div>

        {isAdmin && tenants.length > 0 && (
          <label className="flex items-center gap-2 text-sm text-neutral-600 dark:text-neutral-400">
            <Building2 className="h-4 w-4 text-neutral-400" />
            <span className="sr-only">Tenant</span>
            <select
              value={tenant}
              onChange={(event) => setSelectedTenant(event.target.value)}
              data-testid="contracts-tenant-select"
              className="rounded-lg border border-neutral-300 bg-white px-3 py-2 text-sm text-neutral-700 dark:border-neutral-600 dark:bg-neutral-700 dark:text-neutral-300"
            >
              {tenants.map((t) => (
                <option key={t.id} value={t.id}>
                  {t.displayName || t.name}
                </option>
              ))}
            </select>
          </label>
        )}
      </div>

      {/* Erreur friendly */}
      {isError && (
        <div className="flex items-center justify-between rounded-lg border border-red-200 bg-red-50 px-4 py-3 dark:border-red-800 dark:bg-red-900/20">
          <p className="text-sm text-red-700 dark:text-red-400">
            Le catalogue n'a pas pu être chargé. Le service de gouvernance est peut-être
            indisponible.
          </p>
          <button
            type="button"
            onClick={() => refetch()}
            data-testid="contracts-retry"
            className="text-sm font-medium text-red-700 underline hover:no-underline dark:text-red-400"
          >
            Réessayer
          </button>
        </div>
      )}

      {showSkeletons ? (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {[1, 2, 3, 4, 5, 6].map((i) => (
            <CardSkeleton key={i} />
          ))}
        </div>
      ) : !isError && sorted.length === 0 ? (
        <div className="rounded-lg bg-white shadow dark:bg-neutral-800">
          <EmptyState
            variant="apis"
            title="Aucun contrat"
            description={
              tenant
                ? `Aucun contrat UAC dans le dépôt de gouvernance pour le tenant « ${tenant} ».`
                : 'Aucun tenant accessible — le scope vient du claim JWT.'
            }
          />
        </div>
      ) : (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {sorted.map((contract) => (
            <button
              key={contract.slug}
              type="button"
              onClick={() => openDetail(contract)}
              data-testid={`contract-card-${contract.slug}`}
              className="rounded-lg border border-neutral-200 bg-white p-4 text-left shadow-sm transition-colors hover:border-primary-300 dark:border-neutral-700 dark:bg-neutral-800 dark:hover:border-primary-600"
            >
              {/* Nom + statut */}
              <div className="mb-2 flex items-start justify-between gap-2">
                <div className="min-w-0 flex-1">
                  <h3 className="truncate font-semibold text-neutral-900 dark:text-white">
                    {contract.name}
                  </h3>
                  <p className="truncate font-mono text-xs text-neutral-500 dark:text-neutral-400">
                    {contract.slug}
                  </p>
                </div>
                <span
                  className={`shrink-0 rounded-full px-2 py-0.5 text-xs font-medium ${STATUS_STYLES[contract.status]}`}
                >
                  {STATUS_LABELS[contract.status]}
                </span>
              </div>

              {/* Version + classification + endpoints */}
              <div className="mb-3 flex flex-wrap items-center gap-2">
                <span className="text-xs text-neutral-500 dark:text-neutral-400">
                  v{contract.version}
                </span>
                <span
                  title={`Classification : ${CLASSIFICATION_LABELS[contract.classification]}`}
                  className={`rounded px-1.5 py-0.5 text-xs font-bold ${CLASSIFICATION_STYLES[contract.classification]}`}
                >
                  {contract.classification}
                </span>
                <span className="inline-flex items-center gap-1 text-xs text-neutral-500 dark:text-neutral-400">
                  <Layers className="h-3.5 w-3.5" />
                  {contract.endpoints_count} endpoint{contract.endpoints_count > 1 ? 's' : ''}
                </span>
              </div>

              {/* Dernier commit : sha7 mono + date */}
              <div className="flex items-center justify-between border-t border-neutral-100 pt-3 text-xs text-neutral-500 dark:border-neutral-700 dark:text-neutral-400">
                <span className="inline-flex items-center gap-1.5">
                  <GitCommit className="h-3.5 w-3.5 text-neutral-400" />
                  <span className="font-mono">{contract.last_commit?.sha7 ?? '—'}</span>
                </span>
                <span>{contract.last_commit ? formatDate(contract.last_commit.date) : '—'}</span>
              </div>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
