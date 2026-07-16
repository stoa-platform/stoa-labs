import { useMemo, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { CheckCircle2, Clock, Inbox, XCircle } from 'lucide-react';

import { apiService } from '../services/api';
import { useAuth } from '../contexts/AuthContext';
import { useEnvironmentMode } from '../hooks/useEnvironmentMode';
import { Button } from '../vendor/stoa-shared/components/Button';
import { useToastActions } from '../vendor/stoa-shared/components/Toast';
import { ConfirmDialog } from '../vendor/stoa-shared/components/ConfirmDialog';
import { EmptyState } from '../vendor/stoa-shared/components/EmptyState';
import { StatCard } from '../vendor/stoa-shared/components/StatCard';
import { StatCardSkeletonRow, TableSkeleton } from '../vendor/stoa-shared/components/Skeleton';
import { getFriendlyErrorMessage } from '../vendor/stoa-shared/utils/errorMessages';
import type { Subscription, SubscriptionStatus } from '../types';

/**
 * Écran 8 (CADRAGE §4) — Souscriptions.
 * Porté de la carrière (control-plane-ui/src/pages/Subscriptions.tsx),
 * adapté au modèle Git-first : une souscription = un fichier YAML
 * subscriptions/{tenant}/{id}.yaml ; approbation / rejet motivé = commit
 * signé + pack d'évidence (API-CONTRACT §3 & §6). Pas d'action en masse en v1.
 *
 * Statuts du contrat : pending / approved / rejected — pas de cycle
 * suspend/revoke (différence assumée vs carrière).
 */

// =============================================================================
// CONSTANTES & HELPERS
// =============================================================================

const STATUS_TABS: Array<{ key: SubscriptionStatus; label: string }> = [
  { key: 'pending', label: 'En attente' },
  { key: 'approved', label: 'Actives' },
  { key: 'rejected', label: 'Rejetées' },
];

const STATUS_BADGE: Record<SubscriptionStatus, { label: string; className: string }> = {
  pending: {
    label: 'En attente',
    className: 'bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-400',
  },
  approved: {
    label: 'Active',
    className: 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400',
  },
  rejected: {
    label: 'Rejetée',
    className: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-400',
  },
};

const READ_ONLY_TOOLTIP = 'Environnement en lecture seule';

function formatDate(iso: string): string {
  if (!iso) return '—';
  return new Date(iso).toLocaleString('fr-FR', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}

const EMPTY_DESCRIPTIONS: Record<SubscriptionStatus, string> = {
  pending: 'Aucune demande de souscription en attente de décision.',
  approved: 'Aucune souscription active pour le moment.',
  rejected: 'Aucune souscription rejetée.',
};

// =============================================================================
// MODAL DE REJET (motif obligatoire)
// =============================================================================

interface RejectSubscriptionModalProps {
  subscription: Subscription;
  loading: boolean;
  onCancel: () => void;
  onConfirm: (reason: string) => void;
}

function RejectSubscriptionModal({
  subscription,
  loading,
  onCancel,
  onConfirm,
}: RejectSubscriptionModalProps) {
  const [reason, setReason] = useState('');

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      role="dialog"
      aria-modal="true"
      aria-label="Rejeter la souscription"
    >
      <div className="bg-white dark:bg-neutral-800 rounded-lg shadow-xl p-6 w-full max-w-md">
        <h3 className="text-lg font-semibold text-neutral-900 dark:text-white mb-2">
          Rejeter la souscription
        </h3>
        <p className="text-sm text-neutral-500 dark:text-neutral-400 mb-4">
          Rejeter la souscription de <span className="font-medium">{subscription.consumer}</span> à
          l&rsquo;API <span className="font-mono">{subscription.api}</span> ? Le motif sera commité
          dans le dépôt de gouvernance.
        </p>
        <textarea
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="Motif du rejet (obligatoire)"
          rows={3}
          className="w-full px-3 py-2 border border-neutral-300 dark:border-neutral-600 rounded-lg bg-white dark:bg-neutral-900 text-neutral-900 dark:text-white text-sm resize-none"
          data-testid="subscription-reject-reason"
        />
        <div className="flex justify-end gap-3 mt-4">
          <Button variant="secondary" onClick={onCancel} disabled={loading}>
            Annuler
          </Button>
          <Button
            variant="danger"
            onClick={() => onConfirm(reason.trim())}
            disabled={!reason.trim() || loading}
            loading={loading}
            data-testid="subscription-reject-confirm"
          >
            Rejeter
          </Button>
        </div>
      </div>
    </div>
  );
}

// =============================================================================
// PAGE
// =============================================================================

export default function Subscriptions() {
  const { hasPermission } = useAuth();
  const { canEdit } = useEnvironmentMode();
  const toast = useToastActions();
  const queryClient = useQueryClient();

  const canDecide = hasPermission('subscriptions:approve');
  const [activeTab, setActiveTab] = useState<SubscriptionStatus>('pending');

  // ---------------------------------------------------------------------------
  // Données — le BFF scope par tenant (claim JWT) ; cpi-admin voit tout.
  // ---------------------------------------------------------------------------
  const subscriptionsQuery = useQuery({
    queryKey: ['subscriptions'],
    queryFn: () => apiService.getSubscriptions(),
  });
  const subscriptions = subscriptionsQuery.data ?? [];

  const counts = useMemo(() => {
    const byStatus: Record<SubscriptionStatus, number> = {
      pending: 0,
      approved: 0,
      rejected: 0,
    };
    for (const sub of subscriptions) {
      if (byStatus[sub.status] !== undefined) byStatus[sub.status] += 1;
    }
    return byStatus;
  }, [subscriptions]);

  const visibleSubscriptions = useMemo(
    () => subscriptions.filter((sub) => sub.status === activeTab),
    [subscriptions, activeTab]
  );

  // ---------------------------------------------------------------------------
  // Mutations approve / reject (commit + évidence côté BFF)
  // ---------------------------------------------------------------------------
  const invalidate = () => {
    void queryClient.invalidateQueries({ queryKey: ['subscriptions'] });
    void queryClient.invalidateQueries({ queryKey: ['dashboard'] });
    void queryClient.invalidateQueries({ queryKey: ['audit'] });
  };

  const [approveTarget, setApproveTarget] = useState<Subscription | null>(null);
  const approveMutation = useMutation({
    mutationFn: (sub: Subscription) => apiService.approveSubscription(sub.id),
    onSuccess: (result) => {
      setApproveTarget(null);
      toast.success(
        'Souscription approuvée',
        `Décision commitée — commit ${result.commit.sha7}${result.commit.signed ? ' (signé)' : ''}.`
      );
      invalidate();
    },
    onError: (err) => {
      setApproveTarget(null);
      toast.error('Échec de l’approbation', getFriendlyErrorMessage(err));
    },
  });

  const [rejectTarget, setRejectTarget] = useState<Subscription | null>(null);
  const rejectMutation = useMutation({
    mutationFn: ({ sub, reason }: { sub: Subscription; reason: string }) =>
      apiService.rejectSubscription(sub.id, { reason }),
    onSuccess: (result) => {
      setRejectTarget(null);
      toast.success(
        'Souscription rejetée',
        `Motif commité — commit ${result.commit.sha7}${result.commit.signed ? ' (signé)' : ''}.`
      );
      invalidate();
    },
    onError: (err) => {
      toast.error('Échec du rejet', getFriendlyErrorMessage(err));
    },
  });

  const actionBusy = approveMutation.isPending || rejectMutation.isPending;

  // ---------------------------------------------------------------------------
  // Rendu
  // ---------------------------------------------------------------------------
  return (
    <div className="space-y-6 animate-fade-in" data-testid="page-subscriptions">
      {/* En-tête */}
      <div>
        <h1 className="text-2xl font-bold text-neutral-900 dark:text-white">Souscriptions</h1>
        <p className="text-neutral-500 dark:text-neutral-400 mt-1 text-sm">
          Demandes de souscription des consommateurs — chaque décision (approbation ou rejet
          motivé) est un commit signé dans le dépôt de gouvernance.
        </p>
      </div>

      {/* StatCards */}
      {subscriptionsQuery.isPending ? (
        <StatCardSkeletonRow count={4} />
      ) : (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          <StatCard
            label="Total"
            value={subscriptions.length}
            icon={Inbox}
            colorClass="text-blue-600 dark:text-blue-400"
            subtitle="Toutes les demandes"
            data-testid="subscriptions-stat-total"
          />
          <StatCard
            label="En attente"
            value={counts.pending}
            icon={Clock}
            colorClass="text-yellow-600 dark:text-yellow-400"
            subtitle="À traiter"
            data-testid="subscriptions-stat-pending"
          />
          <StatCard
            label="Actives"
            value={counts.approved}
            icon={CheckCircle2}
            colorClass="text-green-600 dark:text-green-400"
            subtitle="Approuvées"
            data-testid="subscriptions-stat-approved"
          />
          <StatCard
            label="Rejetées"
            value={counts.rejected}
            icon={XCircle}
            colorClass="text-red-600 dark:text-red-400"
            subtitle="Rejet motivé"
            data-testid="subscriptions-stat-rejected"
          />
        </div>
      )}

      {/* Onglets par statut */}
      <div className="border-b border-neutral-200 dark:border-neutral-700">
        <nav className="-mb-px flex gap-6" aria-label="Onglets souscriptions">
          {STATUS_TABS.map((tab) => (
            <button
              key={tab.key}
              onClick={() => setActiveTab(tab.key)}
              className={`pb-3 text-sm font-medium border-b-2 transition-colors ${
                activeTab === tab.key
                  ? 'border-primary-500 text-primary-600 dark:text-primary-400'
                  : 'border-transparent text-neutral-500 hover:text-neutral-700 dark:text-neutral-400 dark:hover:text-neutral-300'
              }`}
              data-testid={`subscriptions-tab-${tab.key}`}
            >
              {tab.label}
              <span className="ml-1.5 text-xs text-neutral-400">({counts[tab.key]})</span>
            </button>
          ))}
        </nav>
      </div>

      {/* Erreur de chargement */}
      {subscriptionsQuery.isError && (
        <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 text-red-700 dark:text-red-400 px-4 py-3 rounded-lg text-sm flex items-center justify-between gap-4">
          <span>{getFriendlyErrorMessage(subscriptionsQuery.error)}</span>
          <Button
            size="sm"
            variant="secondary"
            onClick={() => void subscriptionsQuery.refetch()}
            data-testid="subscriptions-retry"
          >
            Réessayer
          </Button>
        </div>
      )}

      {/* Table */}
      {subscriptionsQuery.isPending ? (
        <TableSkeleton rows={5} columns={7} />
      ) : subscriptionsQuery.isError ? null : visibleSubscriptions.length === 0 ? (
        <EmptyState
          variant="subscriptions"
          title="Aucune souscription"
          description={EMPTY_DESCRIPTIONS[activeTab]}
        />
      ) : (
        <div className="bg-white dark:bg-neutral-800 rounded-lg shadow dark:shadow-none border border-neutral-100 dark:border-neutral-700 overflow-hidden">
          <div className="overflow-x-auto">
            <table className="min-w-full divide-y divide-neutral-200 dark:divide-neutral-700">
              <thead className="bg-neutral-50 dark:bg-neutral-900/50">
                <tr>
                  <th className="px-4 py-3 text-left text-xs font-medium text-neutral-500 dark:text-neutral-400 uppercase tracking-wider">
                    API
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-neutral-500 dark:text-neutral-400 uppercase tracking-wider">
                    Consommateur
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-neutral-500 dark:text-neutral-400 uppercase tracking-wider">
                    Tenant
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-neutral-500 dark:text-neutral-400 uppercase tracking-wider">
                    Demandeur
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-neutral-500 dark:text-neutral-400 uppercase tracking-wider">
                    Statut
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-neutral-500 dark:text-neutral-400 uppercase tracking-wider">
                    Demandée le
                  </th>
                  {canDecide && activeTab === 'pending' && (
                    <th className="px-4 py-3 text-right text-xs font-medium text-neutral-500 dark:text-neutral-400 uppercase tracking-wider">
                      Actions
                    </th>
                  )}
                </tr>
              </thead>
              <tbody className="divide-y divide-neutral-200 dark:divide-neutral-700">
                {visibleSubscriptions.map((sub) => {
                  const badge = STATUS_BADGE[sub.status];
                  return (
                    <tr
                      key={sub.id}
                      className="hover:bg-neutral-50 dark:hover:bg-neutral-700/50 transition-colors"
                      data-testid={`subscription-row-${sub.id}`}
                    >
                      <td className="px-4 py-3 text-sm font-medium text-neutral-900 dark:text-white font-mono">
                        {sub.api}
                      </td>
                      <td className="px-4 py-3 text-sm text-neutral-600 dark:text-neutral-300">
                        {sub.consumer}
                      </td>
                      <td className="px-4 py-3 text-sm text-neutral-500 dark:text-neutral-400">
                        {sub.tenant}
                      </td>
                      <td className="px-4 py-3 text-sm text-neutral-600 dark:text-neutral-300">
                        {sub.requested_by}
                      </td>
                      <td className="px-4 py-3">
                        <div className="flex flex-col gap-1">
                          <span
                            className={`w-fit inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium ${badge.className}`}
                          >
                            {badge.label}
                          </span>
                          {sub.reason && (
                            <span
                              title={sub.reason}
                              className="max-w-[14rem] truncate text-xs text-red-600 dark:text-red-400"
                            >
                              Motif : {sub.reason}
                            </span>
                          )}
                        </div>
                      </td>
                      <td className="px-4 py-3 text-sm text-neutral-500 dark:text-neutral-400">
                        {formatDate(sub.created_at)}
                      </td>
                      {canDecide && activeTab === 'pending' && (
                        <td className="px-4 py-3 text-right">
                          <div className="flex items-center justify-end gap-2">
                            <span title={!canEdit ? READ_ONLY_TOOLTIP : undefined}>
                              <Button
                                size="sm"
                                onClick={() => setApproveTarget(sub)}
                                disabled={actionBusy || !canEdit}
                                title={!canEdit ? READ_ONLY_TOOLTIP : undefined}
                                className="!bg-green-600 hover:!bg-green-700 dark:!bg-green-600 dark:hover:!bg-green-700"
                                data-testid={`subscription-approve-${sub.id}`}
                              >
                                Approuver
                              </Button>
                            </span>
                            <Button
                              size="sm"
                              variant="danger"
                              onClick={() => setRejectTarget(sub)}
                              disabled={actionBusy || !canEdit}
                              title={!canEdit ? READ_ONLY_TOOLTIP : undefined}
                              data-testid={`subscription-reject-${sub.id}`}
                            >
                              Rejeter
                            </Button>
                          </div>
                        </td>
                      )}
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* Confirmation d'approbation */}
      <ConfirmDialog
        open={approveTarget !== null}
        title="Approuver la souscription"
        message={
          approveTarget
            ? `Approuver la souscription de ${approveTarget.consumer} à l'API « ${approveTarget.api} » ? La décision sera commitée dans le dépôt de gouvernance avec pack d'évidence.`
            : ''
        }
        confirmLabel="Approuver"
        cancelLabel="Annuler"
        variant="default"
        loading={approveMutation.isPending}
        icon={<CheckCircle2 className="h-6 w-6" />}
        onConfirm={() => {
          if (approveTarget) approveMutation.mutate(approveTarget);
        }}
        onCancel={() => setApproveTarget(null)}
      />

      {/* Modal de rejet (motif obligatoire) */}
      {rejectTarget && (
        <RejectSubscriptionModal
          key={rejectTarget.id}
          subscription={rejectTarget}
          loading={rejectMutation.isPending}
          onCancel={() => setRejectTarget(null)}
          onConfirm={(reason) => rejectMutation.mutate({ sub: rejectTarget, reason })}
        />
      )}
    </div>
  );
}
