import { useQuery } from '@tanstack/react-query';
import { Cog } from 'lucide-react';
import { apiService } from '../services/api';
import { useAuth } from '../contexts/AuthContext';
import { EmptyState } from '../vendor/stoa-shared/components/EmptyState';
import { TableSkeleton } from '../vendor/stoa-shared/components/Skeleton';
import { getFriendlyErrorMessage } from '../vendor/stoa-shared/utils/errorMessages';
import type { TargetHealth } from '../types';

/**
 * Écran 10 (CADRAGE §4) — Cibles de fédération, lecture seule.
 * Table des gateways enregistrées + santé (ping ≤ 2 s côté BFF, jamais
 * bloquant). Branché sur apiService.getTargets() (contrat §4). Les
 * déploiements sont exécutés par la CI — la console ne touche jamais
 * les gateways.
 */

const TABLE_HEADERS = ['Nom', 'Type', 'URL d’administration', 'URL gateway', 'Santé', 'Latence'];

/** Badge par type de gateway (wso2 / apisix / webmethods, insensible à la casse). */
const TYPE_BADGES: Record<string, { label: string; className: string }> = {
  wso2: {
    label: 'WSO2',
    className: 'bg-orange-100 text-orange-800 dark:bg-orange-900/30 dark:text-orange-400',
  },
  apisix: {
    label: 'APISIX',
    className: 'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-400',
  },
  webmethods: {
    label: 'webMethods',
    className: 'bg-teal-100 text-teal-800 dark:bg-teal-900/30 dark:text-teal-400',
  },
};

const DEFAULT_TYPE_BADGE = {
  className: 'bg-neutral-100 text-neutral-700 dark:bg-neutral-700 dark:text-neutral-300',
};

const HEALTH_CONFIG: Record<TargetHealth, { label: string; dot: string; text: string }> = {
  up: {
    label: 'Opérationnelle',
    dot: 'bg-green-500',
    text: 'text-green-700 dark:text-green-400',
  },
  down: {
    label: 'Indisponible',
    dot: 'bg-red-500',
    text: 'text-red-700 dark:text-red-400',
  },
  unknown: {
    label: 'Inconnue',
    dot: 'bg-neutral-400',
    text: 'text-neutral-500 dark:text-neutral-400',
  },
};

function typeBadge(type: string) {
  const known = TYPE_BADGES[type.toLowerCase()];
  return {
    label: known?.label ?? type,
    className: known?.className ?? DEFAULT_TYPE_BADGE.className,
  };
}

export default function Targets() {
  const { isReady } = useAuth();

  const {
    data: targets = [],
    isLoading,
    error,
  } = useQuery({
    queryKey: ['targets'],
    queryFn: () => apiService.getTargets(),
    enabled: isReady,
    // La santé bouge : on rafraîchit discrètement pendant la démo.
    refetchInterval: 30_000,
  });

  return (
    <div data-testid="page-targets" className="space-y-6 animate-fade-in">
      {/* En-tête */}
      <div>
        <h1 className="text-2xl font-bold text-neutral-900 dark:text-white">
          Cibles de fédération
        </h1>
        <p className="text-neutral-500 dark:text-neutral-400 mt-1">
          Les gateways fédérées sous l’identité Oracle-master, avec leur état de santé.
        </p>
      </div>

      {/* Bandeau explicatif : la console n'exécute rien */}
      <div className="bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg p-4">
        <div className="flex gap-3">
          <Cog className="w-5 h-5 text-blue-600 dark:text-blue-400 flex-shrink-0 mt-0.5" />
          <p className="text-sm text-blue-700 dark:text-blue-300">
            Les déploiements sont exécutés par la CI (Jenkins) — la console ne touche
            jamais les gateways. Cette page est une vue de lecture sur l’inventaire et
            la santé des cibles.
          </p>
        </div>
      </div>

      {/* Erreur de chargement */}
      {error != null && (
        <div
          className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 text-red-700 dark:text-red-400 px-4 py-3 rounded-lg"
          role="alert"
        >
          {getFriendlyErrorMessage(error, 'Impossible de charger les cibles de fédération.')}
        </div>
      )}

      {/* Table des cibles */}
      {isLoading ? (
        <TableSkeleton rows={3} headers={TABLE_HEADERS} />
      ) : !error && targets.length === 0 ? (
        <div className="bg-white dark:bg-neutral-800 rounded-lg shadow">
          <EmptyState
            variant="servers"
            title="Aucune cible enregistrée"
            description="Les gateways fédérées sont déclarées côté plateforme (TARGETS_FILE) — aucune n’est enregistrée pour le moment."
          />
        </div>
      ) : !error && targets.length > 0 ? (
        <div className="bg-white dark:bg-neutral-800 rounded-lg shadow overflow-x-auto">
          <table
            className="min-w-full divide-y divide-neutral-200 dark:divide-neutral-700"
            data-testid="targets-table"
          >
            <thead className="bg-neutral-50 dark:bg-neutral-800">
              <tr>
                {TABLE_HEADERS.map((header) => (
                  <th
                    key={header}
                    scope="col"
                    className="px-4 py-3 text-left text-xs font-medium text-neutral-500 dark:text-neutral-400 uppercase tracking-wider"
                  >
                    {header}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="divide-y divide-neutral-200 dark:divide-neutral-700">
              {targets.map((target) => {
                const badge = typeBadge(target.type);
                const health = HEALTH_CONFIG[target.health] ?? HEALTH_CONFIG.unknown;
                return (
                  <tr
                    key={target.name}
                    className="hover:bg-neutral-50 dark:hover:bg-neutral-700/40 transition-colors"
                    data-testid={`target-row-${target.name}`}
                  >
                    <td className="px-4 py-3 whitespace-nowrap text-sm font-medium text-neutral-900 dark:text-white">
                      {target.name}
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap">
                      <span
                        className={`px-2 py-1 text-xs font-medium rounded-full ${badge.className}`}
                        data-testid="target-type"
                      >
                        {badge.label}
                      </span>
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap text-sm font-mono text-neutral-600 dark:text-neutral-300">
                      {target.adminUrl || '—'}
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap text-sm font-mono text-neutral-600 dark:text-neutral-300">
                      {target.gatewayUrl || '—'}
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap">
                      <span
                        className={`inline-flex items-center gap-2 text-sm font-medium ${health.text}`}
                        data-testid={`target-health-${target.name}`}
                      >
                        <span
                          className={`h-2.5 w-2.5 rounded-full flex-shrink-0 ${health.dot} ${
                            target.health === 'up' ? 'animate-pulse' : ''
                          }`}
                          aria-hidden="true"
                        />
                        {health.label}
                      </span>
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap text-sm text-neutral-600 dark:text-neutral-300">
                      {typeof target.latency_ms === 'number' ? `${target.latency_ms} ms` : '—'}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      ) : null}
    </div>
  );
}
