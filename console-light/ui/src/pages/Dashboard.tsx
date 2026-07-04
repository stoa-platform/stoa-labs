import { useQuery } from '@tanstack/react-query';
import { Link } from 'react-router-dom';
import {
  ArrowRight,
  ArrowUpDown,
  Building2,
  FileText,
  Inbox,
  ShieldAlert,
  ShieldCheck,
} from 'lucide-react';
import { apiService } from '../services/api';
import { useAuth } from '../contexts/AuthContext';
import { StatCard } from '../vendor/stoa-shared/components/StatCard';
import { EmptyState } from '../vendor/stoa-shared/components/EmptyState';
import { CardSkeleton, StatCardSkeletonRow } from '../vendor/stoa-shared/components/Skeleton';
import { getFriendlyErrorMessage } from '../vendor/stoa-shared/utils/errorMessages';
import type { AuditEntry, GovernanceAction } from '../types';

/**
 * Écran 12 (CADRAGE §4) — Tableau de bord gouvernance. Première page vue en
 * démo : compteurs « en attente » cliquables + les 5 derniers commits signés.
 * Branché sur apiService.getDashboard() (contrat §4).
 */

/** Libellés français des trailers Action: des commits de gouvernance. */
const ACTION_LABELS: Record<GovernanceAction, string> = {
  publish: 'Publication',
  draft: 'Brouillon',
  'promote-request': 'Demande de promotion',
  'promote-approve': 'Promotion approuvée',
  'promote-reject': 'Promotion rejetée',
  'sub-approve': 'Souscription approuvée',
  'sub-reject': 'Souscription rejetée',
  'role-change': 'Changement de rôle',
  deny: 'Refus (audité)',
};

const ACTION_STYLES: Partial<Record<GovernanceAction, string>> = {
  publish: 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400',
  'promote-approve': 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400',
  'sub-approve': 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400',
  'promote-request': 'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-400',
  'promote-reject': 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-400',
  'sub-reject': 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-400',
  deny: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-400',
  'role-change': 'bg-purple-100 text-purple-800 dark:bg-purple-900/30 dark:text-purple-400',
};

const DEFAULT_ACTION_STYLE =
  'bg-neutral-100 text-neutral-700 dark:bg-neutral-700 dark:text-neutral-300';

/** Date relative en français (sobre : min / h / j, puis date complète). */
function formatRelativeDate(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return iso;
  const diffMs = Date.now() - date.getTime();
  const diffMins = Math.floor(diffMs / 60_000);
  if (diffMins < 1) return 'à l’instant';
  if (diffMins < 60) return `il y a ${diffMins} min`;
  const diffHours = Math.floor(diffMins / 60);
  if (diffHours < 24) return `il y a ${diffHours} h`;
  const diffDays = Math.floor(diffHours / 24);
  if (diffDays < 7) return `il y a ${diffDays} j`;
  return date.toLocaleDateString('fr-FR');
}

function CommitRow({ entry }: { entry: AuditEntry }) {
  return (
    <li
      className="flex flex-wrap items-center gap-x-3 gap-y-1.5 px-4 sm:px-6 py-3"
      data-testid={`dashboard-commit-${entry.sha7}`}
    >
      {/* sha7 mono */}
      <span
        className="font-mono text-xs text-neutral-600 dark:text-neutral-300 bg-neutral-100 dark:bg-neutral-700/60 rounded px-1.5 py-0.5"
        data-testid="commit-sha"
      >
        {entry.sha7}
      </span>

      {/* Badge signé / non signé */}
      {entry.signed ? (
        <span className="inline-flex items-center gap-1 text-xs font-medium text-green-700 dark:text-green-400">
          <ShieldCheck className="h-3.5 w-3.5" />
          Signé
        </span>
      ) : (
        <span className="inline-flex items-center gap-1 text-xs font-medium text-yellow-700 dark:text-yellow-400">
          <ShieldAlert className="h-3.5 w-3.5" />
          Non signé
        </span>
      )}

      {/* Badge action */}
      <span
        className={`px-2 py-0.5 text-xs font-medium rounded-full ${
          ACTION_STYLES[entry.action] ?? DEFAULT_ACTION_STYLE
        }`}
      >
        {ACTION_LABELS[entry.action] ?? entry.action}
      </span>

      {/* Ressource + acteur */}
      <span className="flex-1 min-w-0 text-sm text-neutral-700 dark:text-neutral-300 truncate">
        <span className="font-mono text-xs">{entry.resource}</span>
        <span className="text-neutral-400 dark:text-neutral-500"> — par </span>
        <span className="font-medium">{entry.actor}</span>
      </span>

      {/* Date relative */}
      <span
        className="text-xs text-neutral-400 dark:text-neutral-500 whitespace-nowrap"
        title={new Date(entry.date).toLocaleString('fr-FR')}
      >
        {formatRelativeDate(entry.date)}
      </span>
    </li>
  );
}

export default function Dashboard() {
  const { user, isReady } = useAuth();

  const { data, isLoading, error } = useQuery({
    queryKey: ['dashboard'],
    queryFn: () => apiService.getDashboard(),
    enabled: isReady,
  });

  const stats = [
    {
      key: 'promotions',
      label: 'Promotions en attente',
      value: data?.pending_promotions ?? 0,
      to: '/promotions',
      icon: ArrowUpDown,
      colorClass: 'text-yellow-600 dark:text-yellow-400',
      subtitle: 'À approuver (4-yeux)',
    },
    {
      key: 'subscriptions',
      label: 'Souscriptions en attente',
      value: data?.pending_subscriptions ?? 0,
      to: '/subscriptions',
      icon: Inbox,
      colorClass: 'text-orange-600 dark:text-orange-400',
      subtitle: 'Demandes à traiter',
    },
    {
      key: 'contracts',
      label: 'Contrats',
      value: data?.contracts ?? 0,
      to: '/contracts',
      icon: FileText,
      colorClass: 'text-blue-600 dark:text-blue-400',
      subtitle: 'Contrats UAC sous gouvernance',
    },
    {
      key: 'tenants',
      label: 'Tenants',
      value: data?.tenants ?? 0,
      to: '/tenants',
      icon: Building2,
      colorClass: 'text-purple-600 dark:text-purple-400',
      subtitle: 'Gérés via GitOps',
    },
  ] as const;

  return (
    <div data-testid="page-dashboard" className="space-y-6 animate-fade-in">
      {/* En-tête */}
      <div>
        <h1 className="text-2xl font-bold text-neutral-900 dark:text-white">Tableau de bord</h1>
        <p className="text-neutral-500 dark:text-neutral-400 mt-1">
          Bonjour {user?.name || user?.username || ''} — chaque action validée dans cette
          console est un commit signé dans le dépôt de gouvernance.
        </p>
      </div>

      {/* Erreur de chargement */}
      {error != null && (
        <div
          className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 text-red-700 dark:text-red-400 px-4 py-3 rounded-lg"
          role="alert"
        >
          {getFriendlyErrorMessage(error, 'Impossible de charger le tableau de bord.')}
        </div>
      )}

      {/* Compteurs */}
      {isLoading ? (
        <StatCardSkeletonRow count={4} />
      ) : (
        !error && (
          <div className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-4 sm:gap-6">
            {stats.map((stat) => (
              <Link
                key={stat.key}
                to={stat.to}
                className="block rounded-lg transition-shadow hover:shadow-md focus-visible:ring-2 focus-visible:ring-primary-500"
                data-testid={`dashboard-stat-${stat.key}`}
              >
                <StatCard
                  label={stat.label}
                  value={stat.value}
                  icon={stat.icon}
                  colorClass={stat.colorClass}
                  subtitle={stat.subtitle}
                />
              </Link>
            ))}
          </div>
        )
      )}

      {/* Derniers commits signés */}
      <section className="space-y-3">
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-semibold text-neutral-900 dark:text-white">
            Derniers commits signés
          </h2>
          <Link
            to="/audit"
            className="inline-flex items-center gap-1 text-sm font-medium text-primary-600 hover:text-primary-700 dark:text-primary-400 dark:hover:text-primary-300"
            data-testid="dashboard-view-audit"
          >
            Voir tout l’audit
            <ArrowRight className="h-4 w-4" />
          </Link>
        </div>

        {isLoading ? (
          <CardSkeleton />
        ) : !error && (data?.last_commits?.length ?? 0) === 0 ? (
          <div className="bg-white dark:bg-neutral-800 rounded-lg shadow">
            <EmptyState
              compact
              title="Aucun commit de gouvernance"
              description="Les actions validées (publication, promotion, souscription) apparaîtront ici."
            />
          </div>
        ) : !error && data ? (
          <div className="bg-white dark:bg-neutral-800 rounded-lg shadow">
            <ul
              className="divide-y divide-neutral-200 dark:divide-neutral-700"
              data-testid="dashboard-last-commits"
            >
              {data.last_commits.slice(0, 5).map((entry) => (
                <CommitRow key={entry.sha} entry={entry} />
              ))}
            </ul>
          </div>
        ) : null}
      </section>
    </div>
  );
}
