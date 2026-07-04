import { Fragment, useMemo, useState, type MouseEvent as ReactMouseEvent } from 'react';
import { useQuery } from '@tanstack/react-query';
import {
  Check,
  ChevronDown,
  ChevronRight,
  ClipboardList,
  Copy,
  Download,
  FileBadge,
  GitCommit,
  Search,
  ShieldCheck,
  Users,
} from 'lucide-react';
import { apiService } from '../services/api';
import { PermissionGate } from '../components/PermissionGate';
import { StatCard } from '../vendor/stoa-shared/components/StatCard';
import { StatCardSkeletonRow, TableSkeleton } from '../vendor/stoa-shared/components/Skeleton';
import { EmptyState } from '../vendor/stoa-shared/components/EmptyState';
import { useToastActions } from '../vendor/stoa-shared/components/Toast';
import type { AuditEntry, GovernanceAction } from '../types';

/**
 * Écran 3 (CADRAGE §4) — Audit : la piste d'audit EST le git log.
 * Porté de la carrière (control-plane-ui/src/pages/AuditLog.tsx), branché sur
 * apiService.getAudit / exportAudit (API-CONTRACT §4). Le sha7 copiable et le
 * badge « Signé ✓ » sont le moment de preuve de la démo.
 */

const AUDIT_LIMIT = 200;

const ACTION_LABELS: Record<GovernanceAction, string> = {
  publish: 'Publication',
  draft: 'Brouillon',
  'promote-request': 'Demande de promotion',
  'promote-approve': 'Approbation de promotion',
  'promote-reject': 'Rejet de promotion',
  'sub-approve': 'Approbation de souscription',
  'sub-reject': 'Rejet de souscription',
  'role-change': 'Changement de rôle',
  deny: 'Refus (403)',
};

const ACTION_ORDER: GovernanceAction[] = [
  'publish',
  'draft',
  'promote-request',
  'promote-approve',
  'promote-reject',
  'sub-approve',
  'sub-reject',
  'role-change',
  'deny',
];

const ACTION_STYLES: Record<GovernanceAction, string> = {
  publish: 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400',
  draft: 'bg-neutral-100 text-neutral-600 dark:bg-neutral-700 dark:text-neutral-300',
  'promote-request': 'bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-400',
  'promote-approve': 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400',
  'promote-reject': 'bg-orange-100 text-orange-700 dark:bg-orange-900/30 dark:text-orange-400',
  'sub-approve': 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400',
  'sub-reject': 'bg-orange-100 text-orange-700 dark:bg-orange-900/30 dark:text-orange-400',
  'role-change': 'bg-purple-100 text-purple-700 dark:bg-purple-900/30 dark:text-purple-400',
  deny: 'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400',
};

function formatDate(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString('fr-FR', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}

/** Badge de signature — LE moment de preuve : vert quand le commit est signé. */
function SignedBadge({ signed }: { signed: boolean }) {
  return signed ? (
    <span
      className="inline-flex items-center gap-1 rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-700 dark:bg-green-900/30 dark:text-green-400"
      data-testid="audit-signed-badge"
    >
      <ShieldCheck className="h-3 w-3" />
      Signé ✓
    </span>
  ) : (
    <span
      className="inline-flex items-center rounded-full bg-neutral-100 px-2 py-0.5 text-xs font-medium text-neutral-500 dark:bg-neutral-700 dark:text-neutral-400"
      data-testid="audit-unsigned-badge"
    >
      Non signé
    </span>
  );
}

/** sha7 mono, copiable au clic (copie le sha complet). */
function ShaChip({ sha, sha7 }: { sha: string; sha7: string }) {
  const [copied, setCopied] = useState(false);

  const copy = async (event: ReactMouseEvent<HTMLButtonElement>) => {
    event.stopPropagation();
    try {
      await navigator.clipboard.writeText(sha);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1500);
    } catch {
      // Presse-papiers indisponible — pas bloquant.
    }
  };

  return (
    <button
      type="button"
      onClick={copy}
      title={copied ? 'Copié !' : `Copier le sha complet (${sha})`}
      data-testid={`audit-sha-${sha7}`}
      className="inline-flex items-center gap-1.5 rounded-md border border-neutral-200 bg-neutral-50 px-2 py-1 font-mono text-xs text-neutral-700 transition-colors hover:border-primary-300 hover:text-primary-700 dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-200 dark:hover:border-primary-600 dark:hover:text-primary-300"
    >
      <GitCommit className="h-3.5 w-3.5 text-neutral-400" />
      {sha7}
      {copied ? (
        <Check className="h-3 w-3 text-green-500" />
      ) : (
        <Copy className="h-3 w-3 text-neutral-400" />
      )}
    </button>
  );
}

export default function Audit() {
  const toast = useToastActions();
  const [actionFilter, setActionFilter] = useState<GovernanceAction | ''>('');
  const [search, setSearch] = useState('');
  const [expandedSha, setExpandedSha] = useState<string | null>(null);
  const [exporting, setExporting] = useState(false);

  const {
    data: entries = [],
    isLoading,
    isError,
    refetch,
  } = useQuery({
    queryKey: ['audit', { action: actionFilter || undefined, limit: AUDIT_LIMIT }],
    queryFn: () =>
      apiService.getAudit({
        action: actionFilter || undefined,
        limit: AUDIT_LIMIT,
      }),
  });

  // Recherche côté client (acteur, ressource, message, sha) — le filtre action
  // est lui appliqué côté BFF (?action=).
  const filtered = useMemo(() => {
    const needle = search.trim().toLowerCase();
    if (!needle) return entries;
    return entries.filter((entry) =>
      [entry.actor, entry.author, entry.email, entry.resource, entry.message, entry.sha7, entry.sha]
        .filter(Boolean)
        .some((field) => field.toLowerCase().includes(needle))
    );
  }, [entries, search]);

  const signedCount = useMemo(() => filtered.filter((e) => e.signed).length, [filtered]);
  const uniqueActors = useMemo(
    () => new Set(filtered.map((e) => e.actor || e.author).filter(Boolean)).size,
    [filtered]
  );

  const handleExport = async (format: 'csv' | 'json') => {
    setExporting(true);
    try {
      const { blob, filename } = await apiService.exportAudit(format);
      const url = URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url;
      link.download = filename ?? `audit-export-${new Date().toISOString().slice(0, 10)}.${format}`;
      link.click();
      URL.revokeObjectURL(url);
      toast.success('Export prêt', `Le journal d'audit a été exporté en ${format.toUpperCase()}.`);
    } catch {
      toast.error("Échec de l'export", "Le journal d'audit n'a pas pu être exporté. Réessayez.");
    } finally {
      setExporting(false);
    }
  };

  const hasActiveFilters = Boolean(actionFilter || search.trim());

  return (
    <div data-testid="page-audit" className="space-y-6 animate-fade-in">
      {/* En-tête */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-neutral-900 dark:text-white">Journal d'audit</h1>
          <p className="mt-1 text-sm text-neutral-500 dark:text-neutral-400">
            La piste d'audit est le journal Git du dépôt de gouvernance — chaque action validée est
            un commit signé.
          </p>
        </div>

        {/* Export CSV/JSON — réservé à audit:export (l'UI masque, le BFF refuse). */}
        <PermissionGate permission="audit:export">
          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={() => handleExport('csv')}
              disabled={exporting}
              data-testid="audit-export"
              className="inline-flex items-center gap-2 rounded-lg border border-neutral-300 px-3 py-2 text-sm font-medium text-neutral-700 transition-colors hover:bg-neutral-50 disabled:opacity-50 dark:border-neutral-600 dark:text-neutral-300 dark:hover:bg-neutral-700"
            >
              <Download className="h-4 w-4" />
              Exporter CSV
            </button>
            <button
              type="button"
              onClick={() => handleExport('json')}
              disabled={exporting}
              data-testid="audit-export-json"
              className="inline-flex items-center gap-2 rounded-lg border border-neutral-300 px-3 py-2 text-sm font-medium text-neutral-700 transition-colors hover:bg-neutral-50 disabled:opacity-50 dark:border-neutral-600 dark:text-neutral-300 dark:hover:bg-neutral-700"
            >
              <Download className="h-4 w-4" />
              Exporter JSON
            </button>
          </div>
        </PermissionGate>
      </div>

      {/* Erreur friendly */}
      {isError && (
        <div className="flex items-center justify-between rounded-lg border border-red-200 bg-red-50 px-4 py-3 dark:border-red-800 dark:bg-red-900/20">
          <p className="text-sm text-red-700 dark:text-red-400">
            Le journal d'audit n'a pas pu être chargé. Le service de gouvernance est peut-être
            indisponible.
          </p>
          <button
            type="button"
            onClick={() => refetch()}
            data-testid="audit-retry"
            className="text-sm font-medium text-red-700 underline hover:no-underline dark:text-red-400"
          >
            Réessayer
          </button>
        </div>
      )}

      {isLoading ? (
        <div className="space-y-6">
          <StatCardSkeletonRow count={3} />
          <TableSkeleton
            rows={6}
            headers={['', 'Date', 'Acteur', 'Action', 'Ressource', 'Commit', 'Signature']}
          />
        </div>
      ) : (
        <>
          {/* KPI — total, signés, acteurs uniques */}
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
            <StatCard
              label="Actions totales"
              value={filtered.length}
              icon={ClipboardList}
              colorClass="text-blue-600 dark:text-blue-400"
              subtitle={`${Math.min(entries.length, AUDIT_LIMIT)} dernières entrées Git`}
              data-testid="audit-kpi-total"
            />
            <StatCard
              label="Commits signés"
              value={signedCount}
              icon={ShieldCheck}
              colorClass="text-green-600 dark:text-green-400"
              subtitle={
                filtered.length > 0
                  ? `${Math.round((signedCount / filtered.length) * 100)} % du journal`
                  : '—'
              }
              data-testid="audit-kpi-signed"
            />
            <StatCard
              label="Acteurs uniques"
              value={uniqueActors}
              icon={Users}
              colorClass="text-purple-600 dark:text-purple-400"
              subtitle="Auteurs des commits de gouvernance"
              data-testid="audit-kpi-actors"
            />
          </div>

          {/* Filtres : recherche + action */}
          <div className="rounded-lg bg-white p-4 shadow dark:bg-neutral-800">
            <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
              <div className="relative flex-1">
                <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-neutral-400" />
                <input
                  type="text"
                  value={search}
                  onChange={(event) => setSearch(event.target.value)}
                  placeholder="Rechercher par acteur, ressource, message ou sha…"
                  data-testid="audit-search"
                  className="w-full rounded-lg border border-neutral-300 bg-white py-2 pl-10 pr-4 text-sm text-neutral-900 focus:border-primary-500 focus:ring-2 focus:ring-primary-500 dark:border-neutral-600 dark:bg-neutral-700 dark:text-white"
                />
              </div>
              <select
                value={actionFilter}
                onChange={(event) => setActionFilter(event.target.value as GovernanceAction | '')}
                data-testid="audit-filter-action"
                className="rounded-lg border border-neutral-300 bg-white px-3 py-2 text-sm text-neutral-700 dark:border-neutral-600 dark:bg-neutral-700 dark:text-neutral-300"
              >
                <option value="">Toutes les actions</option>
                {ACTION_ORDER.map((action) => (
                  <option key={action} value={action}>
                    {ACTION_LABELS[action]}
                  </option>
                ))}
              </select>
              {hasActiveFilters && (
                <button
                  type="button"
                  onClick={() => {
                    setActionFilter('');
                    setSearch('');
                  }}
                  data-testid="audit-filter-clear"
                  className="text-sm font-medium text-primary-600 hover:underline dark:text-primary-400"
                >
                  Effacer
                </button>
              )}
            </div>
          </div>

          {/* Table du journal */}
          <div className="overflow-hidden rounded-lg bg-white shadow dark:bg-neutral-800">
            {filtered.length === 0 ? (
              <EmptyState
                variant={hasActiveFilters ? 'search' : 'default'}
                title={hasActiveFilters ? 'Aucun résultat' : "Aucune entrée d'audit"}
                description={
                  hasActiveFilters
                    ? "Aucune entrée ne correspond aux filtres. Ajustez la recherche ou le type d'action."
                    : 'Les commits de gouvernance apparaîtront ici dès la première action validée.'
                }
              />
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b border-neutral-100 text-left text-xs font-medium uppercase text-neutral-500 dark:border-neutral-700 dark:text-neutral-400">
                      <th className="w-8 px-4 py-3" />
                      <th className="px-4 py-3">Date</th>
                      <th className="px-4 py-3">Acteur</th>
                      <th className="px-4 py-3">Action</th>
                      <th className="px-4 py-3">Ressource</th>
                      <th className="px-4 py-3">Commit</th>
                      <th className="px-4 py-3 text-center">Signature</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-neutral-50 dark:divide-neutral-700">
                    {filtered.map((entry) => {
                      const isExpanded = expandedSha === entry.sha;
                      return (
                        <Fragment key={entry.sha}>
                          <tr
                            data-testid="audit-row"
                            onClick={() => setExpandedSha(isExpanded ? null : entry.sha)}
                            className="cursor-pointer hover:bg-neutral-50 dark:hover:bg-neutral-700/40"
                          >
                            <td className="px-4 py-3">
                              {isExpanded ? (
                                <ChevronDown className="h-4 w-4 text-neutral-400" />
                              ) : (
                                <ChevronRight className="h-4 w-4 text-neutral-400" />
                              )}
                            </td>
                            <td className="whitespace-nowrap px-4 py-3 text-xs text-neutral-600 dark:text-neutral-400">
                              {formatDate(entry.date)}
                            </td>
                            <td className="px-4 py-3 text-neutral-900 dark:text-white">
                              {entry.actor || entry.author}
                            </td>
                            <td className="px-4 py-3">
                              <span
                                className={`inline-flex rounded-full px-2 py-0.5 text-xs font-medium ${
                                  ACTION_STYLES[entry.action] ?? ACTION_STYLES.draft
                                }`}
                              >
                                {ACTION_LABELS[entry.action] ?? entry.action}
                              </span>
                            </td>
                            <td className="px-4 py-3">
                              <span className="font-mono text-xs text-neutral-700 dark:text-neutral-300">
                                {entry.resource || '—'}
                              </span>
                            </td>
                            <td className="px-4 py-3">
                              <ShaChip sha={entry.sha} sha7={entry.sha7} />
                            </td>
                            <td className="px-4 py-3 text-center">
                              <SignedBadge signed={entry.signed} />
                            </td>
                          </tr>
                          {isExpanded && <ExpandedRow entry={entry} />}
                        </Fragment>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </>
      )}
    </div>
  );
}

/** Détails d'une entrée : trailers du commit, ressource, chemin d'évidence. */
function ExpandedRow({ entry }: { entry: AuditEntry }) {
  return (
    <tr data-testid="audit-row-details">
      <td
        colSpan={7}
        className="border-b border-neutral-100 bg-neutral-50 px-8 py-4 dark:border-neutral-700 dark:bg-neutral-900/40"
      >
        <div className="grid grid-cols-1 gap-6 text-sm md:grid-cols-2">
          {/* Trailers de gouvernance */}
          <div className="space-y-3">
            <p className="text-xs font-medium uppercase text-neutral-500 dark:text-neutral-400">
              Trailers du commit
            </p>
            <dl className="space-y-2">
              <div className="flex gap-2">
                <dt className="w-24 shrink-0 text-xs text-neutral-500 dark:text-neutral-400">
                  Action
                </dt>
                <dd className="font-mono text-xs text-neutral-700 dark:text-neutral-300">
                  {entry.action}
                </dd>
              </div>
              <div className="flex gap-2">
                <dt className="w-24 shrink-0 text-xs text-neutral-500 dark:text-neutral-400">
                  Ressource
                </dt>
                <dd className="font-mono text-xs text-neutral-700 dark:text-neutral-300">
                  {entry.resource || '—'}
                </dd>
              </div>
              <div className="flex gap-2">
                <dt className="w-24 shrink-0 text-xs text-neutral-500 dark:text-neutral-400">
                  Acteur
                </dt>
                <dd className="text-xs text-neutral-700 dark:text-neutral-300">
                  {entry.actor || entry.author}{' '}
                  {entry.email && <span className="text-neutral-400">&lt;{entry.email}&gt;</span>}
                </dd>
              </div>
              <div className="flex gap-2">
                <dt className="w-24 shrink-0 text-xs text-neutral-500 dark:text-neutral-400">
                  Rôles
                </dt>
                <dd className="flex flex-wrap gap-1">
                  {entry.roles.length > 0 ? (
                    entry.roles.map((role) => (
                      <span
                        key={role}
                        className="inline-flex items-center rounded-full bg-primary-50 px-2 py-0.5 text-[11px] font-medium text-primary-700 dark:bg-primary-900/30 dark:text-primary-300"
                      >
                        {role}
                      </span>
                    ))
                  ) : (
                    <span className="text-xs text-neutral-400">—</span>
                  )}
                </dd>
              </div>
            </dl>
          </div>

          {/* Commit & évidence */}
          <div className="space-y-3">
            <p className="text-xs font-medium uppercase text-neutral-500 dark:text-neutral-400">
              Commit & évidence
            </p>
            <dl className="space-y-2">
              <div>
                <dt className="text-xs text-neutral-500 dark:text-neutral-400">SHA complet</dt>
                <dd className="mt-0.5 break-all font-mono text-xs text-neutral-700 dark:text-neutral-300">
                  {entry.sha}
                </dd>
              </div>
              <div>
                <dt className="text-xs text-neutral-500 dark:text-neutral-400">Message</dt>
                <dd className="mt-0.5 whitespace-pre-wrap text-xs text-neutral-700 dark:text-neutral-300">
                  {entry.message}
                </dd>
              </div>
              <div>
                <dt className="text-xs text-neutral-500 dark:text-neutral-400">
                  Chemin d'évidence
                </dt>
                <dd className="mt-0.5">
                  {entry.evidence ? (
                    <span
                      className="inline-flex items-center gap-1.5 break-all font-mono text-xs text-primary-700 dark:text-primary-300"
                      data-testid="audit-evidence-path"
                    >
                      <FileBadge className="h-3.5 w-3.5 shrink-0" />
                      {entry.evidence}
                    </span>
                  ) : (
                    <span className="text-xs text-neutral-400">— (aucun pack d'évidence)</span>
                  )}
                </dd>
              </div>
            </dl>
          </div>
        </div>
      </td>
    </tr>
  );
}
