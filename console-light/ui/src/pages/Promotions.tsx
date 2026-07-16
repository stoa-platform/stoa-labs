import { useEffect, useMemo, useState, type FormEvent, type ReactNode } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import {
  AlertCircle,
  ArrowRight,
  ArrowUpRight,
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  Clock,
  GitBranch,
  GitMerge,
  Plus,
  RotateCcw,
  ShieldAlert,
  X,
  XCircle,
} from 'lucide-react';

import { apiService, ApiError } from '../services/api';
import { useAuth } from '../contexts/AuthContext';
import { useEnvironmentMode } from '../hooks/useEnvironmentMode';
import { PermissionGate } from '../components/PermissionGate';
import { Button } from '../vendor/stoa-shared/components/Button';
import { useToastActions } from '../vendor/stoa-shared/components/Toast';
import { ConfirmDialog } from '../vendor/stoa-shared/components/ConfirmDialog';
import { EmptyState } from '../vendor/stoa-shared/components/EmptyState';
import { Skeleton, TableSkeleton } from '../vendor/stoa-shared/components/Skeleton';
import { getFriendlyErrorMessage } from '../vendor/stoa-shared/utils/errorMessages';
import type { EnvironmentName, Gate, Promotion, PromotionStatus } from '../types';

/**
 * Écran 7 (CADRAGE §4) — Promotions : LA pièce maîtresse.
 * Porté de la carrière (control-plane-ui/src/pages/Promotions.tsx) SANS la
 * logique d'éligibilité gateways (hors périmètre Git-first) ; la revue de
 * merge-request (écran 11) est intégrée dans l'onglet « Revue ».
 *
 * Modèle (API-CONTRACT §3 & §4) : une promotion = une branche
 * stoa/promote/{tenant}/{slug}/{id} ; approbation = merge --no-ff signé sur
 * main ; rejet = marqueur commité avec motif. Le 4-yeux est appliqué côté
 * BFF (403 SELF_APPROVAL_BLOCKED) — l'UI ne fait que refléter la règle.
 */

// =============================================================================
// CONSTANTES & HELPERS
// =============================================================================

/** Hops valides = paires consécutives de la chaîne (GET /environments) —
 * dérivés à l'exécution, jamais codés en dur (ADR-075 : dev→rec→int→prod). */
function deriveHops(envs: string[]): Array<{ from: string; to: string }> {
  const hops: Array<{ from: string; to: string }> = [];
  for (let i = 0; i + 1 < envs.length; i++) hops.push({ from: envs[i], to: envs[i + 1] });
  return hops;
}

const STATUS_CONFIG: Record<
  PromotionStatus,
  { icon: typeof Clock; color: string; bg: string; label: string }
> = {
  pending: {
    icon: Clock,
    color: 'text-amber-600 dark:text-amber-400',
    bg: 'bg-amber-100 dark:bg-amber-900/30',
    label: 'En attente',
  },
  approved: {
    icon: CheckCircle2,
    color: 'text-green-600 dark:text-green-400',
    bg: 'bg-green-100 dark:bg-green-900/30',
    label: 'Approuvée',
  },
  rejected: {
    icon: XCircle,
    color: 'text-red-600 dark:text-red-400',
    bg: 'bg-red-100 dark:bg-red-900/30',
    label: 'Rejetée',
  },
  rolled_back: {
    icon: RotateCcw,
    color: 'text-orange-600 dark:text-orange-400',
    bg: 'bg-orange-100 dark:bg-orange-900/30',
    label: 'Rollback',
  },
};

/** Config de secours pour un statut inconnu (le BFF fait autorité : son enum
 * peut grandir avant l'UI — on affiche un badge neutre plutôt que crasher). */
const STATUS_FALLBACK = {
  icon: AlertCircle,
  color: 'text-neutral-600 dark:text-neutral-400',
  bg: 'bg-neutral-100 dark:bg-neutral-800',
  label: 'Inconnu',
} as const;

const ENV_BADGE: Record<string, string> = {
  dev: 'bg-emerald-100 text-emerald-800 dark:bg-emerald-900/30 dark:text-emerald-400',
  rec: 'bg-sky-100 text-sky-800 dark:bg-sky-900/30 dark:text-sky-400',
  staging: 'bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-400',
  int: 'bg-violet-100 text-violet-800 dark:bg-violet-900/30 dark:text-violet-400',
  prod: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-400',
  production: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-400',
};

/** Classe de badge d'un env, avec fallback neutre pour un nom inconnu. */
function envBadgeClass(env: string): string {
  return (
    ENV_BADGE[env] ??
    'bg-neutral-100 text-neutral-800 dark:bg-neutral-800 dark:text-neutral-300'
  );
}

const MESSAGE_MAX = 1000;

const FOUR_EYES_TOOLTIP = 'Auto-approbation bloquée (principe des 4 yeux)';
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

/** 4-yeux (miroir de la règle BFF) : demandeur == acteur ET le hop cible porte
 * un gate fourEyes. Basé sur la config de gate LIVE, pas sur un nom d'env figé
 * ('prod' vs l'ancien 'production'). */
function isBlockedSelfApproval(
  promotion: Promotion,
  username: string,
  gates: Record<string, Gate>,
): boolean {
  return Boolean(gates[promotion.to]?.fourEyes) && promotion.requested_by === username;
}

// =============================================================================
// BADGES
// =============================================================================

function EnvBadge({ env }: { env: EnvironmentName }) {
  return (
    <span className={`px-2 py-0.5 text-xs font-medium rounded ${envBadgeClass(env)}`}>
      {env.toUpperCase()}
    </span>
  );
}

function ChainBadge({ from, to }: { from: EnvironmentName; to: EnvironmentName }) {
  return (
    <span className="inline-flex items-center gap-1.5">
      <EnvBadge env={from} />
      <ArrowRight className="h-3.5 w-3.5 text-neutral-400 shrink-0" />
      <EnvBadge env={to} />
    </span>
  );
}

function StatusBadge({ status }: { status: PromotionStatus }) {
  const config = STATUS_CONFIG[status] ?? STATUS_FALLBACK;
  const Icon = config.icon;
  return (
    <span
      className={`inline-flex items-center gap-1.5 px-2 py-1 rounded text-xs font-medium ${config.bg} ${config.color}`}
    >
      <Icon className="h-3.5 w-3.5" />
      {config.label}
    </span>
  );
}

// =============================================================================
// PIPELINE VISUEL dev → staging → production
// =============================================================================

function PromotionPipeline({ promotions }: { promotions: Promotion[] }) {
  const envs: EnvironmentName[] = ['dev', 'staging', 'production'];

  const statusFor = (env: EnvironmentName): 'source' | 'approved' | 'pending' | 'none' => {
    if (env === 'dev') return 'source';
    if (promotions.some((p) => p.to === env && p.status === 'approved')) return 'approved';
    if (promotions.some((p) => p.to === env && p.status === 'pending')) return 'pending';
    return 'none';
  };

  return (
    <div
      className="bg-white dark:bg-neutral-800 rounded-lg shadow-sm border border-neutral-100 dark:border-neutral-700 p-4"
      data-testid="promotion-pipeline"
    >
      <h3 className="text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-3">
        Pipeline de promotion
      </h3>
      <div className="flex items-center gap-2 flex-wrap">
        {envs.map((env, i) => {
          const status = statusFor(env);
          return (
            <div key={env} className="flex items-center gap-2">
              {i > 0 && (
                <ArrowRight className="h-4 w-4 text-neutral-300 dark:text-neutral-600 shrink-0" />
              )}
              <div
                className={`px-3 py-1.5 rounded-lg text-xs font-medium border ${
                  status === 'source' || status === 'approved'
                    ? 'border-green-300 dark:border-green-700 bg-green-50 dark:bg-green-900/20 text-green-700 dark:text-green-400'
                    : status === 'pending'
                      ? 'border-amber-300 dark:border-amber-700 bg-amber-50 dark:bg-amber-900/20 text-amber-700 dark:text-amber-400'
                      : 'border-neutral-200 dark:border-neutral-700 bg-neutral-50 dark:bg-neutral-800 text-neutral-500 dark:text-neutral-400'
                }`}
              >
                {env.toUpperCase()}
                {status === 'approved' && <CheckCircle2 className="inline h-3 w-3 ml-1" />}
                {status === 'pending' && <Clock className="inline h-3 w-3 ml-1" />}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

// =============================================================================
// DIFF (rendu unifié, vrai git diff de la branche de promotion)
// =============================================================================

function diffLineClass(line: string): string {
  if (
    line.startsWith('diff ') ||
    line.startsWith('index ') ||
    line.startsWith('+++') ||
    line.startsWith('---') ||
    line.startsWith('new file') ||
    line.startsWith('deleted file')
  ) {
    return 'text-neutral-400 dark:text-neutral-500';
  }
  if (line.startsWith('@@')) {
    return 'text-blue-600 dark:text-blue-400 bg-blue-50 dark:bg-blue-900/20';
  }
  if (line.startsWith('+')) {
    return 'text-green-700 dark:text-green-400 bg-green-50 dark:bg-green-900/20';
  }
  if (line.startsWith('-')) {
    return 'text-red-700 dark:text-red-400 bg-red-50 dark:bg-red-900/20';
  }
  return 'text-neutral-600 dark:text-neutral-400';
}

/** Charge et affiche le diff Git d'une promotion (skeleton / erreur / rendu). */
function PromotionDiffPanel({ tenant, promotionId }: { tenant: string; promotionId: string }) {
  const diffQuery = useQuery({
    queryKey: ['promotion-diff', tenant, promotionId],
    queryFn: () => apiService.getPromotionDiff(tenant, promotionId),
  });

  if (diffQuery.isPending) {
    return (
      <div className="space-y-2" aria-label="Chargement du diff">
        <Skeleton className="h-4 w-48" />
        <Skeleton className="h-24 w-full" />
      </div>
    );
  }

  if (diffQuery.isError) {
    return (
      <p className="text-sm text-red-600 dark:text-red-400">
        Impossible de charger le diff — {getFriendlyErrorMessage(diffQuery.error)}
      </p>
    );
  }

  const diff = diffQuery.data;
  const lines = diff.diff ? diff.diff.replace(/\n$/, '').split('\n') : [];

  return (
    <div className="space-y-3" data-testid={`promotion-diff-${promotionId}`}>
      {diff.files.length > 0 && (
        <div className="flex flex-wrap gap-2">
          {diff.files.map((file) => (
            <span
              key={file.path}
              className="inline-flex items-center gap-2 rounded-lg border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-900 px-2.5 py-1 text-xs font-mono text-neutral-700 dark:text-neutral-300"
            >
              {file.path}
              <span className="text-green-600 dark:text-green-400">+{file.additions}</span>
              <span className="text-red-600 dark:text-red-400">−{file.deletions}</span>
            </span>
          ))}
        </div>
      )}
      {lines.length === 0 ? (
        <p className="text-sm text-neutral-500 dark:text-neutral-400">
          Aucun changement dans cette branche de promotion.
        </p>
      ) : (
        <pre className="text-xs font-mono rounded-lg border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-950 overflow-auto max-h-96 py-2">
          {lines.map((line, i) => (
            <div key={i} className={`px-3 whitespace-pre ${diffLineClass(line)}`}>
              {line || ' '}
            </div>
          ))}
        </pre>
      )}
    </div>
  );
}

// =============================================================================
// MÉTADONNÉES D'UNE PROMOTION (branche en mono, demandeur, message…)
// =============================================================================

function PromotionMeta({ promotion }: { promotion: Promotion }) {
  return (
    <dl className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-6 gap-y-3 text-sm">
      <div>
        <dt className="text-xs font-medium uppercase text-neutral-500 dark:text-neutral-400">
          Demandeur
        </dt>
        <dd className="text-neutral-900 dark:text-white">{promotion.requested_by}</dd>
      </div>
      <div>
        <dt className="text-xs font-medium uppercase text-neutral-500 dark:text-neutral-400">
          Demandée le
        </dt>
        <dd className="text-neutral-900 dark:text-white">{formatDate(promotion.created_at)}</dd>
      </div>
      <div>
        <dt className="text-xs font-medium uppercase text-neutral-500 dark:text-neutral-400">
          Branche
        </dt>
        <dd className="font-mono text-xs text-neutral-700 dark:text-neutral-300 break-all flex items-center gap-1.5">
          <GitBranch className="h-3.5 w-3.5 shrink-0 text-neutral-400" />
          {promotion.branch || '—'}
        </dd>
      </div>
      {promotion.approved_by && (
        <div>
          <dt className="text-xs font-medium uppercase text-neutral-500 dark:text-neutral-400">
            Approuvée par
          </dt>
          <dd className="text-neutral-900 dark:text-white">{promotion.approved_by}</dd>
        </div>
      )}
      {promotion.reason && (
        <div className="sm:col-span-2">
          <dt className="text-xs font-medium uppercase text-neutral-500 dark:text-neutral-400">
            Motif du rejet
          </dt>
          <dd className="text-red-700 dark:text-red-400">{promotion.reason}</dd>
        </div>
      )}
      <div className="sm:col-span-2 lg:col-span-3">
        <dt className="text-xs font-medium uppercase text-neutral-500 dark:text-neutral-400">
          Message d&rsquo;audit
        </dt>
        <dd className="text-neutral-700 dark:text-neutral-300 whitespace-pre-wrap">
          {promotion.message}
        </dd>
      </div>
    </dl>
  );
}

// =============================================================================
// BOUTONS APPROUVER / REJETER (4-yeux : affiché mais désactivé + tooltip)
// =============================================================================

interface ApprovalActionsProps {
  promotion: Promotion;
  username: string;
  canDeploy: boolean;
  busy: boolean;
  size?: 'sm' | 'lg';
  onApprove: (promotion: Promotion) => void;
  onReject: (promotion: Promotion) => void;
}

function ApprovalActions({
  promotion,
  username,
  canDeploy,
  busy,
  size = 'sm',
  onApprove,
  onReject,
}: ApprovalActionsProps) {
  const envQuery = useQuery({
    queryKey: ['environments'],
    queryFn: () => apiService.getEnvironments(),
  });
  const gates = envQuery.data?.gates ?? {};
  const selfBlocked = isBlockedSelfApproval(promotion, username, gates);
  const approveDisabled = busy || !canDeploy || selfBlocked;
  const approveTooltip = selfBlocked
    ? FOUR_EYES_TOOLTIP
    : !canDeploy
      ? READ_ONLY_TOOLTIP
      : undefined;

  return (
    <div className="flex items-center gap-2">
      <span title={approveTooltip}>
        <Button
          size={size}
          onClick={() => onApprove(promotion)}
          disabled={approveDisabled}
          title={approveTooltip}
          icon={
            selfBlocked ? (
              <ShieldAlert className={size === 'lg' ? 'h-5 w-5' : 'h-3.5 w-3.5'} />
            ) : (
              <GitMerge className={size === 'lg' ? 'h-5 w-5' : 'h-3.5 w-3.5'} />
            )
          }
          className={
            approveDisabled
              ? '!bg-neutral-300 !text-neutral-500 dark:!bg-neutral-700 dark:!text-neutral-400 !cursor-not-allowed'
              : '!bg-green-600 hover:!bg-green-700 dark:!bg-green-600 dark:hover:!bg-green-700'
          }
          data-testid={`promotion-approve-${promotion.id}`}
        >
          Approuver
        </Button>
      </span>
      <Button
        size={size}
        variant="danger"
        onClick={() => onReject(promotion)}
        disabled={busy || !canDeploy}
        title={!canDeploy ? READ_ONLY_TOOLTIP : undefined}
        icon={<XCircle className={size === 'lg' ? 'h-5 w-5' : 'h-3.5 w-3.5'} />}
        data-testid={`promotion-reject-${promotion.id}`}
      >
        Rejeter
      </Button>
    </div>
  );
}

// =============================================================================
// DIALOG « NOUVELLE PROMOTION »
// =============================================================================

interface CreatePromotionDialogProps {
  tenant: string;
  initialSlug: string | null;
  onClose: () => void;
  onCreated: () => void;
}

function CreatePromotionDialog({
  tenant,
  initialSlug,
  onClose,
  onCreated,
}: CreatePromotionDialogProps) {
  const toast = useToastActions();
  const [slug, setSlug] = useState(initialSlug ?? '');
  const [chainIndex, setChainIndex] = useState(0);
  const [message, setMessage] = useState('');
  const [changeRef, setChangeRef] = useState('');
  const [pvRef, setPvRef] = useState('');
  const [error, setError] = useState<string | null>(null);

  const envQuery = useQuery({
    queryKey: ['environments'],
    queryFn: () => apiService.getEnvironments(),
  });
  const hops = deriveHops(envQuery.data?.environments ?? []);
  const chain = hops[chainIndex];
  // Le gate du hop cible dicte les champs exigés (ADR-075 : prod = change_ref +
  // pv_ref) — lu de /environments, pas d'un nom d'env figé.
  const targetGate = chain ? envQuery.data?.gates?.[chain.to] : undefined;
  const needChangeRef = Boolean(targetGate?.requireChangeRef);
  const needPVRef = Boolean(targetGate?.requirePVRef);

  const contractsQuery = useQuery({
    queryKey: ['contracts', tenant],
    queryFn: () => apiService.getContracts(tenant),
  });
  const contracts = contractsQuery.data ?? [];

  const createMutation = useMutation({
    mutationFn: () =>
      apiService.createPromotion(tenant, {
        slug,
        from: chain.from,
        to: chain.to,
        message: message.trim(),
        ...(needChangeRef ? { change_ref: changeRef.trim() } : {}),
        ...(needPVRef ? { pv_ref: pvRef.trim() } : {}),
      }),
    onSuccess: ({ promotion }) => {
      toast.success(
        'Demande de promotion créée',
        `Branche ${promotion.branch} ouverte — en attente d'approbation (4 yeux).`
      );
      onCreated();
    },
    onError: (err) => {
      setError(getFriendlyErrorMessage(err, 'Impossible de créer la demande de promotion.'));
    },
  });

  const canSubmit =
    Boolean(slug) &&
    Boolean(chain) &&
    message.trim().length > 0 &&
    message.length <= MESSAGE_MAX &&
    (!needChangeRef || changeRef.trim().length > 0) &&
    (!needPVRef || pvRef.trim().length > 0) &&
    !createMutation.isPending;

  const handleSubmit = (e: FormEvent) => {
    e.preventDefault();
    if (!canSubmit) return;
    setError(null);
    createMutation.mutate();
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      role="dialog"
      aria-modal="true"
      aria-label="Nouvelle promotion"
    >
      <div
        className="bg-white dark:bg-neutral-800 rounded-lg shadow-xl w-full max-w-xl max-h-[90vh] overflow-y-auto"
        data-testid="promotion-new-dialog"
      >
        <div className="flex items-center justify-between border-b border-neutral-200 dark:border-neutral-700 px-6 py-4">
          <h2 className="text-lg font-semibold text-neutral-900 dark:text-white">
            Nouvelle promotion
          </h2>
          <button
            onClick={onClose}
            className="text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300"
            aria-label="Fermer"
            data-testid="promotion-create-cancel"
          >
            <X className="h-5 w-5" />
          </button>
        </div>

        <form onSubmit={handleSubmit} className="p-6 space-y-5">
          {error && (
            <div className="flex items-start gap-2 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 text-red-700 dark:text-red-400 px-4 py-3 rounded-lg text-sm">
              <AlertCircle className="h-4 w-4 mt-0.5 shrink-0" />
              <span>{error}</span>
            </div>
          )}

          {/* Contrat */}
          <div>
            <label
              htmlFor="promotion-create-slug"
              className="block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-1"
            >
              Contrat
            </label>
            <select
              id="promotion-create-slug"
              value={slug}
              onChange={(e) => setSlug(e.target.value)}
              className="w-full px-3 py-2 border border-neutral-300 dark:border-neutral-600 rounded-lg bg-white dark:bg-neutral-700 text-neutral-900 dark:text-white text-sm"
              required
              disabled={contractsQuery.isPending}
              data-testid="promotion-create-slug"
            >
              <option value="">
                {contractsQuery.isPending
                  ? 'Chargement des contrats…'
                  : contracts.length === 0
                    ? 'Aucun contrat dans ce tenant'
                    : 'Sélectionner un contrat…'}
              </option>
              {contracts.map((contract) => (
                <option key={contract.slug} value={contract.slug}>
                  {contract.name} ({contract.slug}) — v{contract.version}
                </option>
              ))}
            </select>
            {contractsQuery.isError && (
              <p className="text-xs text-red-500 mt-1">
                {getFriendlyErrorMessage(contractsQuery.error)}
              </p>
            )}
          </div>

          {/* Chaîne de promotion — seules dev→staging et staging→production sont valides */}
          <div>
            <label
              htmlFor="promotion-create-chain"
              className="block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-1"
            >
              Chaîne de promotion
            </label>
            <select
              id="promotion-create-chain"
              value={chainIndex}
              onChange={(e) => setChainIndex(Number(e.target.value))}
              className="w-full px-3 py-2 border border-neutral-300 dark:border-neutral-600 rounded-lg bg-white dark:bg-neutral-700 text-neutral-900 dark:text-white text-sm"
              disabled={envQuery.isPending || hops.length === 0}
              data-testid="promotion-create-chain"
            >
              {hops.map((c, i) => (
                <option key={`${c.from}-${c.to}`} value={i}>
                  {c.from} → {c.to}
                </option>
              ))}
            </select>
            {chain && (
              <div className="mt-2 flex items-center gap-1.5">
                <ChainBadge from={chain.from} to={chain.to} />
                {targetGate?.fourEyes && (
                  <span className="text-xs text-amber-600 dark:text-amber-400 ml-2">
                    Cible gated : approbation par un pair obligatoire (4 yeux).
                  </span>
                )}
              </div>
            )}
          </div>

          {/* Références de gate exigées par le hop cible (ex. int→prod) */}
          {needChangeRef && (
            <div>
              <label
                htmlFor="promotion-create-changeref"
                className="block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-1"
              >
                Change ITSM <span className="text-red-500">*</span>
              </label>
              <input
                id="promotion-create-changeref"
                type="text"
                value={changeRef}
                onChange={(e) => setChangeRef(e.target.value)}
                placeholder="ex. CHG-0001 (vérifié approuvé auprès de l'ITSM)"
                required
                className="w-full px-3 py-2 border border-neutral-300 dark:border-neutral-600 rounded-lg bg-white dark:bg-neutral-700 text-neutral-900 dark:text-white text-sm"
                data-testid="promotion-create-changeref"
              />
            </div>
          )}
          {needPVRef && (
            <div>
              <label
                htmlFor="promotion-create-pvref"
                className="block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-1"
              >
                Référence PV de recette <span className="text-red-500">*</span>
              </label>
              <input
                id="promotion-create-pvref"
                type="text"
                value={pvRef}
                onChange={(e) => setPvRef(e.target.value)}
                placeholder="ex. PV-2026-042"
                required
                className="w-full px-3 py-2 border border-neutral-300 dark:border-neutral-600 rounded-lg bg-white dark:bg-neutral-700 text-neutral-900 dark:text-white text-sm"
                data-testid="promotion-create-pvref"
              />
            </div>
          )}

          {/* Message d'audit (obligatoire, ≤ 1000 caractères) */}
          <div>
            <label
              htmlFor="promotion-create-message"
              className="block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-1"
            >
              Message d&rsquo;audit <span className="text-red-500">*</span>
            </label>
            <textarea
              id="promotion-create-message"
              value={message}
              onChange={(e) => setMessage(e.target.value)}
              placeholder="Pourquoi promouvoir ce contrat ? (tracé dans la piste d'audit Git)"
              rows={3}
              maxLength={MESSAGE_MAX}
              required
              className="w-full px-3 py-2 border border-neutral-300 dark:border-neutral-600 rounded-lg bg-white dark:bg-neutral-700 text-neutral-900 dark:text-white text-sm resize-none"
              data-testid="promotion-create-message"
            />
            <p className="text-xs text-neutral-400 mt-1">
              {message.length}/{MESSAGE_MAX}
            </p>
          </div>

          {/* Actions */}
          <div className="flex justify-end gap-3 pt-2 border-t border-neutral-200 dark:border-neutral-700">
            <Button variant="secondary" onClick={onClose} type="button">
              Annuler
            </Button>
            <Button
              type="submit"
              disabled={!canSubmit}
              loading={createMutation.isPending}
              icon={<ArrowUpRight className="h-4 w-4" />}
              data-testid="promotion-create-submit"
            >
              Créer la demande
            </Button>
          </div>
        </form>
      </div>
    </div>
  );
}

// =============================================================================
// MODAL DE REJET (motif obligatoire)
// =============================================================================

interface RejectPromotionModalProps {
  promotion: Promotion;
  loading: boolean;
  onCancel: () => void;
  onConfirm: (reason: string) => void;
}

function RejectPromotionModal({
  promotion,
  loading,
  onCancel,
  onConfirm,
}: RejectPromotionModalProps) {
  const [reason, setReason] = useState('');

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      role="dialog"
      aria-modal="true"
      aria-label="Rejeter la promotion"
    >
      <div className="bg-white dark:bg-neutral-800 rounded-lg shadow-xl p-6 w-full max-w-md">
        <h3 className="text-lg font-semibold text-neutral-900 dark:text-white mb-2">
          Rejeter la promotion
        </h3>
        <p className="text-sm text-neutral-500 dark:text-neutral-400 mb-4">
          Rejeter la promotion <span className="font-mono">{promotion.slug}</span>{' '}
          ({promotion.from} → {promotion.to}) ? Le motif sera commité dans le dépôt de
          gouvernance et la branche supprimée.
        </p>
        <textarea
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="Motif du rejet (obligatoire)"
          rows={3}
          className="w-full px-3 py-2 border border-neutral-300 dark:border-neutral-600 rounded-lg bg-white dark:bg-neutral-900 text-neutral-900 dark:text-white text-sm resize-none"
          data-testid="promotion-reject-reason"
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
            data-testid="promotion-reject-confirm"
          >
            Rejeter
          </Button>
        </div>
      </div>
    </div>
  );
}

// =============================================================================
// LIGNE DU TABLEAU (onglet Promotions) — expansion = métadonnées + diff
// =============================================================================

interface PromotionRowProps {
  promotion: Promotion;
  tenant: string;
  expanded: boolean;
  onToggle: () => void;
  actions: ReactNode;
}

function PromotionRow({ promotion, tenant, expanded, onToggle, actions }: PromotionRowProps) {
  return (
    <div data-testid={`promotion-row-${promotion.id}`}>
      <div
        className={`grid grid-cols-[1.5fr_1.3fr_1fr_2fr_1fr_1fr_minmax(180px,auto)] gap-2 px-6 py-4 items-center cursor-pointer transition-colors ${
          expanded
            ? 'bg-primary-50 dark:bg-primary-900/10'
            : 'hover:bg-neutral-50 dark:hover:bg-neutral-700/50'
        }`}
        onClick={onToggle}
        data-testid={`promotion-expand-${promotion.id}`}
      >
        {/* Slug */}
        <div className="flex items-center gap-2 min-w-0">
          <span className="text-neutral-400 dark:text-neutral-500 shrink-0">
            {expanded ? <ChevronDown className="h-4 w-4" /> : <ChevronRight className="h-4 w-4" />}
          </span>
          <span className="text-sm font-medium text-neutral-900 dark:text-white truncate font-mono">
            {promotion.slug}
          </span>
        </div>

        {/* Chaîne from → to */}
        <ChainBadge from={promotion.from} to={promotion.to} />

        {/* Demandeur */}
        <span className="text-sm text-neutral-900 dark:text-white truncate">
          {promotion.requested_by}
        </span>

        {/* Message */}
        <span className="text-xs text-neutral-500 dark:text-neutral-400 truncate">
          {promotion.message}
        </span>

        {/* Statut */}
        <StatusBadge status={promotion.status} />

        {/* Date */}
        <span className="text-xs text-neutral-500 dark:text-neutral-400">
          {formatDate(promotion.created_at)}
        </span>

        {/* Actions */}
        <div onClick={(e) => e.stopPropagation()}>{actions}</div>
      </div>

      {/* Expansion : métadonnées + diff Git */}
      {expanded && (
        <div className="px-6 pb-5 pt-4 space-y-4 bg-primary-50/50 dark:bg-primary-900/5 border-t border-neutral-100 dark:border-neutral-700">
          <PromotionMeta promotion={promotion} />
          <PromotionDiffPanel tenant={tenant} promotionId={promotion.id} />
        </div>
      )}
    </div>
  );
}

// =============================================================================
// CARTE DE REVUE (onglet Revue) — diff déplié par défaut, gros boutons
// =============================================================================

interface ReviewCardProps {
  promotion: Promotion;
  tenant: string;
  actions: ReactNode;
}

function ReviewCard({ promotion, tenant, actions }: ReviewCardProps) {
  return (
    <div
      className="bg-white dark:bg-neutral-800 rounded-lg shadow-sm border border-neutral-100 dark:border-neutral-700 overflow-hidden"
      data-testid={`promotion-review-${promotion.id}`}
    >
      <div className="flex flex-wrap items-center justify-between gap-3 px-6 py-4 border-b border-neutral-100 dark:border-neutral-700">
        <div className="flex items-center gap-3 min-w-0">
          <span className="text-base font-semibold text-neutral-900 dark:text-white font-mono truncate">
            {promotion.slug}
          </span>
          <ChainBadge from={promotion.from} to={promotion.to} />
        </div>
        <StatusBadge status={promotion.status} />
      </div>

      <div className="px-6 py-4 space-y-4">
        <PromotionMeta promotion={promotion} />
        <div>
          <h4 className="text-xs font-medium uppercase text-neutral-500 dark:text-neutral-400 mb-2">
            Changements (git diff de la branche)
          </h4>
          <PromotionDiffPanel tenant={tenant} promotionId={promotion.id} />
        </div>
      </div>

      <div className="flex justify-end px-6 py-4 border-t border-neutral-100 dark:border-neutral-700 bg-neutral-50/60 dark:bg-neutral-900/30">
        {actions}
      </div>
    </div>
  );
}

// =============================================================================
// PAGE
// =============================================================================

type TabKey = 'list' | 'review';

export default function Promotions() {
  const { user, hasPermission } = useAuth();
  const { canDeploy } = useEnvironmentMode();
  const toast = useToastActions();
  const queryClient = useQueryClient();
  const [searchParams, setSearchParams] = useSearchParams();

  const username = user?.username ?? '';
  const canRequest = hasPermission('promotions:request');
  const canApprove = hasPermission('promotions:approve');

  // ---------------------------------------------------------------------------
  // Scope tenant : claim JWT, sinon (cpi-admin multi-tenant) sélection.
  // ---------------------------------------------------------------------------
  const claimTenant = user?.tenant ?? '';
  const [pickedTenant, setPickedTenant] = useState('');
  const tenantsQuery = useQuery({
    queryKey: ['tenants'],
    queryFn: () => apiService.getTenants(),
    enabled: !claimTenant,
    staleTime: 5 * 60 * 1000,
  });
  const tenants = tenantsQuery.data ?? [];
  useEffect(() => {
    if (!claimTenant && !pickedTenant && tenants.length > 0) {
      setPickedTenant(tenants[0].id);
    }
  }, [claimTenant, pickedTenant, tenants]);
  const tenant = claimTenant || pickedTenant;

  // ---------------------------------------------------------------------------
  // Données
  // ---------------------------------------------------------------------------
  const promotionsQuery = useQuery({
    queryKey: ['promotions', tenant],
    queryFn: () => apiService.getPromotions(tenant),
    enabled: Boolean(tenant),
  });
  const promotions = promotionsQuery.data ?? [];

  const [activeTab, setActiveTab] = useState<TabKey>('list');
  const [statusFilter, setStatusFilter] = useState<PromotionStatus | ''>('');
  const [expandedId, setExpandedId] = useState<string | null>(null);

  const pendingPromotions = useMemo(
    () => promotions.filter((p) => p.status === 'pending'),
    [promotions]
  );
  const filteredPromotions = useMemo(
    () => (statusFilter ? promotions.filter((p) => p.status === statusFilter) : promotions),
    [promotions, statusFilter]
  );

  // ---------------------------------------------------------------------------
  // Dialog « Nouvelle promotion » + préremplissage par ?slug=
  // ---------------------------------------------------------------------------
  const slugParam = searchParams.get('slug');
  const [showCreate, setShowCreate] = useState(false);
  useEffect(() => {
    if (slugParam && canRequest) setShowCreate(true);
  }, [slugParam, canRequest]);

  const closeCreate = () => {
    setShowCreate(false);
    if (slugParam) {
      const next = new URLSearchParams(searchParams);
      next.delete('slug');
      setSearchParams(next, { replace: true });
    }
  };

  // ---------------------------------------------------------------------------
  // Mutations approve / reject
  // ---------------------------------------------------------------------------
  const invalidate = () => {
    void queryClient.invalidateQueries({ queryKey: ['promotions', tenant] });
    void queryClient.invalidateQueries({ queryKey: ['dashboard'] });
    void queryClient.invalidateQueries({ queryKey: ['audit'] });
  };

  const [approveTarget, setApproveTarget] = useState<Promotion | null>(null);
  const approveMutation = useMutation({
    mutationFn: (promotion: Promotion) => apiService.approvePromotion(tenant, promotion.id),
    onSuccess: (result) => {
      setApproveTarget(null);
      toast.success(
        'Promotion approuvée',
        `Merge signé sur main — commit ${result.merge_commit.sha7}${
          result.merge_commit.signed ? ' (signé)' : ''
        }. Évidence : ${result.evidence}`
      );
      invalidate();
    },
    onError: (err) => {
      setApproveTarget(null);
      if (err instanceof ApiError && err.code === 'SELF_APPROVAL_BLOCKED') {
        toast.error(
          'Auto-approbation bloquée (principe des 4 yeux)',
          'Le demandeur d’une promotion vers la production ne peut pas l’approuver lui-même. Ce refus est audité.'
        );
      } else {
        toast.error('Échec de l’approbation', getFriendlyErrorMessage(err));
      }
    },
  });

  const [rejectTarget, setRejectTarget] = useState<Promotion | null>(null);
  const rejectMutation = useMutation({
    mutationFn: ({ promotion, reason }: { promotion: Promotion; reason: string }) =>
      apiService.rejectPromotion(tenant, promotion.id, { reason }),
    onSuccess: () => {
      setRejectTarget(null);
      toast.success('Promotion rejetée', 'Le motif a été commité dans le dépôt de gouvernance.');
      invalidate();
    },
    onError: (err) => {
      toast.error('Échec du rejet', getFriendlyErrorMessage(err));
    },
  });

  const actionBusy = approveMutation.isPending || rejectMutation.isPending;

  const renderActions = (promotion: Promotion, size: 'sm' | 'lg') => {
    if (!canApprove || promotion.status !== 'pending') return null;
    return (
      <ApprovalActions
        promotion={promotion}
        username={username}
        canDeploy={canDeploy}
        busy={actionBusy}
        size={size}
        onApprove={setApproveTarget}
        onReject={setRejectTarget}
      />
    );
  };

  // ---------------------------------------------------------------------------
  // Rendu
  // ---------------------------------------------------------------------------
  const TABS: Array<{ key: TabKey; label: string; count?: number }> = [
    { key: 'list', label: 'Promotions', count: promotions.length },
    { key: 'review', label: 'Revue', count: pendingPromotions.length },
  ];

  return (
    <div className="space-y-6 animate-fade-in" data-testid="page-promotions">
      {/* En-tête */}
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-neutral-900 dark:text-white">Promotions</h1>
          <p className="text-neutral-500 dark:text-neutral-400 mt-1 text-sm">
            Promouvoir les contrats entre environnements — dev → staging → production. Chaque
            approbation est un merge signé sur main.
          </p>
        </div>
        <div className="flex items-center gap-3">
          {/* Sélecteur tenant (cpi-admin uniquement — sinon scope du JWT) */}
          {!claimTenant && tenants.length > 0 && (
            <select
              value={pickedTenant}
              onChange={(e) => setPickedTenant(e.target.value)}
              className="px-3 py-2 border border-neutral-300 dark:border-neutral-600 rounded-lg bg-white dark:bg-neutral-800 text-neutral-900 dark:text-white text-sm"
              aria-label="Tenant"
              data-testid="promotion-tenant-select"
            >
              {tenants.map((t) => (
                <option key={t.id} value={t.id}>
                  {t.displayName || t.name}
                </option>
              ))}
            </select>
          )}
          <PermissionGate permission="promotions:request">
            <span title={!canDeploy ? READ_ONLY_TOOLTIP : undefined}>
              <Button
                onClick={() => setShowCreate(true)}
                disabled={!tenant || !canDeploy}
                icon={<Plus className="h-4 w-4" />}
                data-testid="promotion-new"
              >
                Nouvelle promotion
              </Button>
            </span>
          </PermissionGate>
        </div>
      </div>

      {/* Pipeline visuel */}
      <PromotionPipeline promotions={promotions} />

      {/* Onglets Promotions / Revue */}
      <div className="border-b border-neutral-200 dark:border-neutral-700">
        <nav className="-mb-px flex gap-6" aria-label="Onglets promotions">
          {TABS.map((tab) => (
            <button
              key={tab.key}
              onClick={() => setActiveTab(tab.key)}
              className={`pb-3 text-sm font-medium border-b-2 transition-colors ${
                activeTab === tab.key
                  ? 'border-primary-500 text-primary-600 dark:text-primary-400'
                  : 'border-transparent text-neutral-500 hover:text-neutral-700 dark:text-neutral-400 dark:hover:text-neutral-300'
              }`}
              data-testid={`promotions-tab-${tab.key}`}
            >
              {tab.label}
              {tab.count !== undefined && (
                <span className="ml-1.5 text-xs text-neutral-400">({tab.count})</span>
              )}
            </button>
          ))}
        </nav>
      </div>

      {/* Erreur de chargement */}
      {promotionsQuery.isError && (
        <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 text-red-700 dark:text-red-400 px-4 py-3 rounded-lg text-sm flex items-center justify-between gap-4">
          <span>{getFriendlyErrorMessage(promotionsQuery.error)}</span>
          <Button
            size="sm"
            variant="secondary"
            onClick={() => void promotionsQuery.refetch()}
            data-testid="promotions-retry"
          >
            Réessayer
          </Button>
        </div>
      )}

      {/* Onglet « Promotions » : table complète */}
      {activeTab === 'list' && (
        <>
          <div className="flex items-center gap-4">
            <select
              value={statusFilter}
              onChange={(e) => setStatusFilter(e.target.value as PromotionStatus | '')}
              className="px-3 py-2 border border-neutral-300 dark:border-neutral-600 rounded-lg bg-white dark:bg-neutral-800 text-neutral-900 dark:text-white text-sm"
              aria-label="Filtrer par statut"
              data-testid="promotion-status-filter"
            >
              <option value="">Tous les statuts</option>
              <option value="pending">En attente</option>
              <option value="approved">Approuvées</option>
              <option value="rejected">Rejetées</option>
              <option value="rolled_back">Rollback</option>
            </select>
          </div>

          {!promotionsQuery.isError && (
            <div className="bg-white dark:bg-neutral-800 rounded-lg shadow-sm border border-neutral-100 dark:border-neutral-700 overflow-hidden">
              {promotionsQuery.isPending && Boolean(tenant) ? (
                <TableSkeleton rows={5} columns={6} />
              ) : filteredPromotions.length === 0 ? (
                <EmptyState
                  variant="deployments"
                  title="Aucune promotion"
                  description={
                    statusFilter
                      ? 'Aucune promotion ne correspond à ce statut.'
                      : 'Aucune demande de promotion pour ce tenant. Créez-en une pour promouvoir un contrat.'
                  }
                />
              ) : (
                <div className="overflow-x-auto">
                  <div className="min-w-[960px] divide-y divide-neutral-200 dark:divide-neutral-700">
                    <div className="grid grid-cols-[1.5fr_1.3fr_1fr_2fr_1fr_1fr_minmax(180px,auto)] gap-2 px-6 py-3 bg-neutral-50 dark:bg-neutral-700/50 text-xs font-medium text-neutral-500 dark:text-neutral-400 uppercase tracking-wider">
                      <span>Contrat</span>
                      <span>Chaîne</span>
                      <span>Demandeur</span>
                      <span>Message</span>
                      <span>Statut</span>
                      <span>Date</span>
                      <span>Actions</span>
                    </div>
                    {filteredPromotions.map((promotion) => (
                      <PromotionRow
                        key={promotion.id}
                        promotion={promotion}
                        tenant={tenant}
                        expanded={expandedId === promotion.id}
                        onToggle={() =>
                          setExpandedId((cur) => (cur === promotion.id ? null : promotion.id))
                        }
                        actions={renderActions(promotion, 'sm')}
                      />
                    ))}
                  </div>
                </div>
              )}
            </div>
          )}
        </>
      )}

      {/* Onglet « Revue » : promotions en attente, diff déplié par défaut */}
      {activeTab === 'review' && !promotionsQuery.isError && (
        <div className="space-y-6" data-testid="promotions-review-list">
          {promotionsQuery.isPending && Boolean(tenant) ? (
            <TableSkeleton rows={4} columns={4} />
          ) : pendingPromotions.length === 0 ? (
            <EmptyState
              variant="deployments"
              title="Rien à revoir"
              description="Aucune promotion en attente d'approbation. Les nouvelles demandes apparaîtront ici."
            />
          ) : (
            pendingPromotions.map((promotion) => (
              <ReviewCard
                key={promotion.id}
                promotion={promotion}
                tenant={tenant}
                actions={renderActions(promotion, 'lg')}
              />
            ))
          )}
        </div>
      )}

      {/* Dialog création */}
      {showCreate && tenant && (
        <CreatePromotionDialog
          tenant={tenant}
          initialSlug={slugParam}
          onClose={closeCreate}
          onCreated={() => {
            closeCreate();
            invalidate();
          }}
        />
      )}

      {/* Confirmation d'approbation (merge signé) */}
      <ConfirmDialog
        open={approveTarget !== null}
        title="Approuver la promotion"
        message={
          approveTarget
            ? `Approuver la promotion de « ${approveTarget.slug} » (${approveTarget.from} → ${approveTarget.to}) demandée par ${approveTarget.requested_by} ? La branche sera fusionnée sur main par un merge signé, avec pack d'évidence.`
            : ''
        }
        confirmLabel="Approuver"
        cancelLabel="Annuler"
        variant="default"
        loading={approveMutation.isPending}
        icon={<GitMerge className="h-6 w-6" />}
        onConfirm={() => {
          if (approveTarget) approveMutation.mutate(approveTarget);
        }}
        onCancel={() => setApproveTarget(null)}
      />

      {/* Modal de rejet (motif obligatoire) */}
      {rejectTarget && (
        <RejectPromotionModal
          key={rejectTarget.id}
          promotion={rejectTarget}
          loading={rejectMutation.isPending}
          onCancel={() => setRejectTarget(null)}
          onConfirm={(reason) => rejectMutation.mutate({ promotion: rejectTarget, reason })}
        />
      )}
    </div>
  );
}
