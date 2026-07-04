import { useEffect, useState, type ReactNode } from 'react';
import { useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import {
  ArrowUpRight,
  Bot,
  Check,
  Copy,
  FileJson,
  GitCommit,
  Info,
  Pencil,
  Send,
  Server,
  ShieldAlert,
  ShieldCheck,
} from 'lucide-react';
import { apiService, ApiError } from '../services/api';
import { useAuth } from '../contexts/AuthContext';
import { PermissionGate } from '../components/PermissionGate';
import { Button } from '../vendor/stoa-shared/components/Button';
import { Breadcrumb } from '../vendor/stoa-shared/components/Breadcrumb';
import { CardSkeleton } from '../vendor/stoa-shared/components/Skeleton';
import { EmptyState } from '../vendor/stoa-shared/components/EmptyState';
import { useToastActions } from '../vendor/stoa-shared/components/Toast';
import type {
  CommitInfo,
  ContractVersion,
  DeploymentState,
  EnvironmentName,
  HttpMethod,
  UacClassification,
  UacContract,
  UacEndpoint,
  UacSideEffects,
  UacStatus,
} from '../types';

/**
 * Écran 5 (CADRAGE §4) — Détail d'un contrat UAC.
 * Squelette à onglets porté de la carrière (control-plane-ui/src/pages/APIDetail.tsx),
 * branché sur apiService.getContract / publishContract (API-CONTRACT §4).
 * Onglets : Aperçu (métadonnées + déploiements) / Spécification (endpoints + IA) /
 * Versions (historique Git signé).
 */

type TabId = 'overview' | 'spec' | 'versions';

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

const CLASSIFICATION_STYLES: Record<UacClassification, string> = {
  M: 'bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-400',
  H: 'bg-orange-100 text-orange-700 dark:bg-orange-900/30 dark:text-orange-400',
  VH: 'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400',
};

const METHOD_STYLES: Record<HttpMethod, string> = {
  GET: 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400',
  POST: 'bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-400',
  PUT: 'bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400',
  PATCH: 'bg-purple-100 text-purple-700 dark:bg-purple-900/30 dark:text-purple-400',
  DELETE: 'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400',
  HEAD: 'bg-neutral-100 text-neutral-600 dark:bg-neutral-700 dark:text-neutral-300',
  OPTIONS: 'bg-neutral-100 text-neutral-600 dark:bg-neutral-700 dark:text-neutral-300',
};

const SIDE_EFFECTS_LABELS: Record<UacSideEffects, string> = {
  none: 'aucun effet',
  read: 'lecture',
  write: 'écriture',
  destructive: 'destructive',
};

// `destructive` en ROUGE — règle CADRAGE/§5 : destructive ⇒ approbation humaine.
const SIDE_EFFECTS_STYLES: Record<UacSideEffects, string> = {
  none: 'bg-neutral-100 text-neutral-600 dark:bg-neutral-700 dark:text-neutral-300',
  read: 'bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-400',
  write: 'bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400',
  destructive: 'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400',
};

const ENV_LABELS: Record<EnvironmentName, string> = {
  dev: 'Développement',
  staging: 'Préproduction',
  production: 'Production',
};

const ENVIRONMENTS: EnvironmentName[] = ['dev', 'staging', 'production'];

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

/** sha7 mono, copiable au clic (copie le sha complet). */
function ShaChip({ sha, sha7, testId }: { sha: string; sha7: string; testId?: string }) {
  const [copied, setCopied] = useState(false);

  const copy = async () => {
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
      data-testid={testId}
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

function SignedBadge({ signed }: { signed: boolean }) {
  return signed ? (
    <span className="inline-flex items-center gap-1 rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-700 dark:bg-green-900/30 dark:text-green-400">
      <ShieldCheck className="h-3 w-3" />
      Signé ✓
    </span>
  ) : (
    <span className="inline-flex items-center rounded-full bg-neutral-100 px-2 py-0.5 text-xs font-medium text-neutral-500 dark:bg-neutral-700 dark:text-neutral-400">
      Non signé
    </span>
  );
}

export default function ContractDetail() {
  const { slug } = useParams<{ slug: string }>();
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();
  const { user } = useAuth();
  const toast = useToastActions();
  const queryClient = useQueryClient();

  const [activeTab, setActiveTab] = useState<TabId>('overview');
  const [publishOpen, setPublishOpen] = useState(false);
  const [publishMessage, setPublishMessage] = useState('');
  const [lastCommit, setLastCommit] = useState<CommitInfo | null>(null);

  // Scope tenant : claim JWT pour tenant-admin/devops/viewer ; query param
  // `?tenant=` posé par le catalogue pour cpi-admin (la route ne le porte pas).
  const tenant = user?.tenant || searchParams.get('tenant') || '';
  const tenantSuffix = !user?.tenant && tenant ? `?tenant=${encodeURIComponent(tenant)}` : '';

  const { data, isLoading, isError } = useQuery({
    queryKey: ['contract', tenant, slug],
    queryFn: () => apiService.getContract(tenant, slug!),
    enabled: Boolean(tenant && slug),
  });

  const publishMutation = useMutation({
    mutationFn: () => apiService.publishContract(tenant, slug!, { message: publishMessage.trim() }),
    onSuccess: (res) => {
      setPublishOpen(false);
      setPublishMessage('');
      setLastCommit(res.commit);
      toast.success(
        'Contrat publié en dev',
        `Commit ${res.commit.sha7}${res.commit.signed ? ' — signé ✓' : ''}`
      );
      void queryClient.invalidateQueries({ queryKey: ['contract', tenant, slug] });
      void queryClient.invalidateQueries({ queryKey: ['contracts'] });
      void queryClient.invalidateQueries({ queryKey: ['audit'] });
      void queryClient.invalidateQueries({ queryKey: ['dashboard'] });
    },
    onError: (error) => {
      toast.error(
        'Échec de la publication',
        error instanceof ApiError ? error.message : 'Le service de gouvernance a refusé l’action.'
      );
    },
  });

  const tabs: { id: TabId; label: string; icon: ReactNode; testId: string }[] = [
    { id: 'overview', label: 'Aperçu', icon: <Info className="h-4 w-4" />, testId: 'tab-overview' },
    {
      id: 'spec',
      label: 'Spécification',
      icon: <FileJson className="h-4 w-4" />,
      testId: 'tab-spec',
    },
    {
      id: 'versions',
      label: 'Versions',
      icon: <GitCommit className="h-4 w-4" />,
      testId: 'tab-versions',
    },
  ];

  // --- Tenant introuvable (deep-link cpi-admin sans ?tenant=) ---
  if (!tenant) {
    return (
      <div data-testid="page-contract-detail" className="space-y-6 animate-fade-in">
        <div className="rounded-lg border border-yellow-200 bg-yellow-50 p-6 text-center dark:border-yellow-800 dark:bg-yellow-900/20">
          <p className="text-sm text-yellow-800 dark:text-yellow-300">
            Tenant non précisé — repassez par le catalogue pour sélectionner un tenant.
          </p>
          <Button
            variant="secondary"
            size="sm"
            className="mt-4"
            onClick={() => navigate('/contracts')}
            data-testid="contract-back"
          >
            Retour au catalogue
          </Button>
        </div>
      </div>
    );
  }

  // --- Chargement ---
  if (isLoading) {
    return (
      <div data-testid="page-contract-detail" className="space-y-6 animate-fade-in">
        <div className="h-4 w-64 animate-pulse rounded bg-neutral-200 dark:bg-neutral-700" />
        <CardSkeleton className="h-36" />
        <CardSkeleton className="h-72" />
      </div>
    );
  }

  // --- Erreur friendly ---
  if (isError || !data) {
    return (
      <div data-testid="page-contract-detail" className="space-y-6 animate-fade-in">
        <Breadcrumb
          items={[{ label: 'Contrats', href: '/contracts' }, { label: slug ?? 'Contrat' }]}
          onNavigate={(href) => navigate(href)}
        />
        <div className="rounded-lg border border-red-200 bg-red-50 p-6 text-center dark:border-red-800 dark:bg-red-900/20">
          <p className="text-sm text-red-700 dark:text-red-400">
            Le contrat « {slug} » n'a pas pu être chargé. Il n'existe peut-être pas dans le dépôt
            de gouvernance, ou le service est indisponible.
          </p>
          <Button
            variant="secondary"
            size="sm"
            className="mt-4"
            onClick={() => navigate('/contracts')}
            data-testid="contract-back"
          >
            Retour au catalogue
          </Button>
        </div>
      </div>
    );
  }

  const { contract, versions, deployments } = data;
  const title = contract.display_name || contract.name;

  return (
    <div data-testid="page-contract-detail" className="space-y-6 animate-fade-in">
      <Breadcrumb
        items={[{ label: 'Contrats', href: '/contracts' }, { label: title }]}
        onNavigate={(href) => navigate(href)}
      />

      {/* Bandeau de résultat de publication — le sha7 est le moment de preuve. */}
      {lastCommit && (
        <div
          className="flex flex-wrap items-center gap-2 rounded-lg border border-green-200 bg-green-50 px-4 py-3 text-sm text-green-800 dark:border-green-800 dark:bg-green-900/20 dark:text-green-300"
          data-testid="publish-result"
        >
          <ShieldCheck className="h-4 w-4 shrink-0" />
          <span>Publication enregistrée — commit</span>
          <ShaChip sha={lastCommit.sha} sha7={lastCommit.sha7} testId="commit-sha" />
          <SignedBadge signed={lastCommit.signed} />
        </div>
      )}

      {/* En-tête */}
      <div className="rounded-lg border border-neutral-200 bg-white p-6 dark:border-neutral-700 dark:bg-neutral-800">
        <div className="flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
          <div className="min-w-0 space-y-2">
            <div className="flex flex-wrap items-center gap-3">
              <h1 className="text-2xl font-bold text-neutral-900 dark:text-white">{title}</h1>
              <span className="text-sm text-neutral-500 dark:text-neutral-400">
                v{contract.version}
              </span>
              <span
                className={`rounded-full px-2 py-0.5 text-xs font-medium ${STATUS_STYLES[contract.status]}`}
              >
                {STATUS_LABELS[contract.status]}
              </span>
              <span
                title={`Classification : ${CLASSIFICATION_LABELS[contract.classification]}`}
                className={`rounded px-1.5 py-0.5 text-xs font-bold ${CLASSIFICATION_STYLES[contract.classification]}`}
              >
                {contract.classification}
              </span>
            </div>
            <p className="font-mono text-xs text-neutral-500 dark:text-neutral-400">{slug}</p>
            {contract.description && (
              <p className="max-w-2xl text-sm text-neutral-600 dark:text-neutral-400">
                {contract.description}
              </p>
            )}
          </div>

          {/* Actions — l'UI masque (PermissionGate), le BFF refuse. */}
          <div className="flex flex-wrap items-center gap-2 md:shrink-0">
            <PermissionGate permission="apis:update">
              <Button
                variant="secondary"
                size="sm"
                icon={<Pencil className="h-4 w-4" />}
                onClick={() => navigate(`/contracts/${slug}/edit${tenantSuffix}`)}
                data-testid="contract-edit"
              >
                Modifier
              </Button>
            </PermissionGate>
            <PermissionGate permission="apis:publish">
              <Button
                variant="primary"
                size="sm"
                icon={<Send className="h-4 w-4" />}
                onClick={() => setPublishOpen(true)}
                data-testid="contract-publish"
              >
                Publier en dev
              </Button>
            </PermissionGate>
            <PermissionGate permission="promotions:request">
              <Button
                variant="secondary"
                size="sm"
                icon={<ArrowUpRight className="h-4 w-4" />}
                onClick={() => navigate(`/promotions?slug=${encodeURIComponent(slug ?? '')}`)}
                data-testid="contract-request-promotion"
              >
                Demander une promotion
              </Button>
            </PermissionGate>
          </div>
        </div>
      </div>

      {/* Onglets */}
      <div className="border-b border-neutral-200 dark:border-neutral-700">
        <nav className="-mb-px flex gap-6" aria-label="Onglets du contrat">
          {tabs.map((tab) => (
            <button
              key={tab.id}
              type="button"
              onClick={() => setActiveTab(tab.id)}
              data-testid={tab.testId}
              className={`flex items-center gap-1.5 whitespace-nowrap border-b-2 px-1 pb-3 text-sm font-medium transition-colors ${
                activeTab === tab.id
                  ? 'border-primary-600 text-primary-600 dark:border-primary-400 dark:text-primary-400'
                  : 'border-transparent text-neutral-500 hover:border-neutral-300 hover:text-neutral-700 dark:text-neutral-400 dark:hover:text-neutral-200'
              }`}
            >
              {tab.icon}
              {tab.label}
            </button>
          ))}
        </nav>
      </div>

      {/* Contenu de l'onglet */}
      <div className="rounded-lg border border-neutral-200 bg-white p-6 dark:border-neutral-700 dark:bg-neutral-800">
        {activeTab === 'overview' && (
          <OverviewTab contract={contract} deployments={deployments} />
        )}
        {activeTab === 'spec' && <SpecTab contract={contract} />}
        {activeTab === 'versions' && <VersionsTab versions={versions} />}
      </div>

      {/* Dialogue de publication — message d'audit OBLIGATOIRE (CRV : action = commit).
          Le ConfirmDialog vendorisé n'accepte pas de champ : dialogue local au même style. */}
      {publishOpen && (
        <PublishDialog
          contractName={title}
          message={publishMessage}
          onMessageChange={setPublishMessage}
          loading={publishMutation.isPending}
          onConfirm={() => publishMutation.mutate()}
          onCancel={() => {
            if (!publishMutation.isPending) setPublishOpen(false);
          }}
        />
      )}
    </div>
  );
}

// ============================================================================
// Onglet Aperçu — métadonnées, classification, policies, déploiements par env
// ============================================================================

function OverviewTab({
  contract,
  deployments,
}: {
  contract: UacContract;
  deployments: Record<EnvironmentName, DeploymentState | null>;
}) {
  const fields: { label: string; value: string; mono?: boolean }[] = [
    { label: 'Nom', value: contract.name, mono: true },
    { label: 'Nom affiché', value: contract.display_name || '—' },
    { label: 'Version', value: contract.version, mono: true },
    { label: 'Tenant', value: contract.tenant_id, mono: true },
    { label: 'Statut', value: STATUS_LABELS[contract.status] },
    {
      label: 'Classification',
      value: `${contract.classification} — ${CLASSIFICATION_LABELS[contract.classification]}`,
    },
    { label: 'Endpoints', value: String(contract.endpoints.length) },
    { label: 'Spécification source', value: contract.source_spec_url || '—', mono: true },
  ];

  return (
    <div className="space-y-8">
      {/* Métadonnées */}
      <dl className="grid grid-cols-1 gap-4 md:grid-cols-2">
        {fields.map((field) => (
          <div key={field.label}>
            <dt className="text-xs font-medium uppercase tracking-wider text-neutral-500 dark:text-neutral-400">
              {field.label}
            </dt>
            <dd
              className={`mt-1 break-all text-sm text-neutral-900 dark:text-white ${
                field.mono ? 'font-mono' : ''
              }`}
            >
              {field.value}
            </dd>
          </div>
        ))}
      </dl>

      {/* Politiques requises */}
      <div>
        <h3 className="mb-2 text-xs font-medium uppercase tracking-wider text-neutral-500 dark:text-neutral-400">
          Politiques requises
        </h3>
        {contract.required_policies && contract.required_policies.length > 0 ? (
          <div className="flex flex-wrap gap-2">
            {contract.required_policies.map((policy) => (
              <span
                key={policy}
                className="inline-flex items-center rounded-full bg-primary-50 px-2.5 py-0.5 font-mono text-xs font-medium text-primary-700 dark:bg-primary-900/30 dark:text-primary-300"
              >
                {policy}
              </span>
            ))}
          </div>
        ) : (
          <p className="text-sm text-neutral-400 dark:text-neutral-500">Aucune politique requise.</p>
        )}
      </div>

      {/* Déploiements par environnement (deploy.{env}.yaml) */}
      <div>
        <h3 className="mb-3 text-xs font-medium uppercase tracking-wider text-neutral-500 dark:text-neutral-400">
          Déploiements par environnement
        </h3>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          {ENVIRONMENTS.map((env) => {
            const state = deployments[env];
            return (
              <div
                key={env}
                data-testid={`deployment-${env}`}
                className={`rounded-lg border p-4 ${
                  state
                    ? 'border-neutral-200 bg-neutral-50 dark:border-neutral-700 dark:bg-neutral-900/40'
                    : 'border-dashed border-neutral-200 dark:border-neutral-700'
                }`}
              >
                <div className="mb-2 flex items-center justify-between">
                  <span className="text-sm font-semibold text-neutral-900 dark:text-white">
                    {ENV_LABELS[env]}
                  </span>
                  {state ? (
                    <span
                      className={`rounded-full px-2 py-0.5 text-xs font-medium ${
                        state.enabled
                          ? 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400'
                          : 'bg-neutral-100 text-neutral-500 dark:bg-neutral-700 dark:text-neutral-400'
                      }`}
                    >
                      {state.enabled ? 'Actif' : 'Désactivé'}
                    </span>
                  ) : (
                    <span className="rounded-full bg-neutral-100 px-2 py-0.5 text-xs font-medium text-neutral-400 dark:bg-neutral-800 dark:text-neutral-500">
                      Non déployé
                    </span>
                  )}
                </div>
                {state ? (
                  <div className="space-y-1 text-xs text-neutral-600 dark:text-neutral-400">
                    <p>
                      Version <span className="font-mono">{state.version}</span>
                    </p>
                    <p>
                      Promu par <span className="font-medium">{state.promoted_by || '—'}</span>
                    </p>
                  </div>
                ) : (
                  <p className="text-xs text-neutral-400 dark:text-neutral-500">
                    Aucun état désiré pour cet environnement.
                  </p>
                )}
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}

// ============================================================================
// Onglet Spécification — endpoints, méthodes, backend, bloc IA/LLM
// ============================================================================

function SpecTab({ contract }: { contract: UacContract }) {
  if (contract.endpoints.length === 0) {
    return (
      <EmptyState
        compact
        variant="apis"
        title="Aucun endpoint"
        description="Ce contrat ne déclare encore aucun endpoint — la publication exige au moins un endpoint."
      />
    );
  }

  return (
    <div className="space-y-4">
      {contract.endpoints.map((endpoint, index) => (
        <EndpointBlock key={`${endpoint.path}-${index}`} endpoint={endpoint} index={index} />
      ))}
    </div>
  );
}

function EndpointBlock({ endpoint, index }: { endpoint: UacEndpoint; index: number }) {
  return (
    <div
      data-testid={`endpoint-${index}`}
      className="rounded-lg border border-neutral-100 p-4 dark:border-neutral-700"
    >
      {/* path + méthodes */}
      <div className="flex flex-wrap items-center gap-2">
        {endpoint.methods.map((method) => (
          <span
            key={method}
            className={`rounded px-1.5 py-0.5 font-mono text-xs font-bold ${METHOD_STYLES[method]}`}
          >
            {method}
          </span>
        ))}
        <span className="font-mono text-sm text-neutral-900 dark:text-white">{endpoint.path}</span>
        {endpoint.operation_id && (
          <span className="font-mono text-xs text-neutral-400 dark:text-neutral-500">
            ({endpoint.operation_id})
          </span>
        )}
      </div>

      {/* backend */}
      <div className="mt-2 flex items-center gap-1.5 text-xs text-neutral-500 dark:text-neutral-400">
        <Server className="h-3.5 w-3.5" />
        <span className="break-all font-mono">{endpoint.backend_url}</span>
      </div>

      {/* Bloc IA / LLM (métadonnées au niveau endpoint — doctrine UAC) */}
      {endpoint.llm && (
        <div className="mt-3 rounded-lg bg-neutral-50 p-3 dark:bg-neutral-900/40">
          <div className="mb-2 flex items-center gap-1.5 text-xs font-medium uppercase tracking-wider text-neutral-500 dark:text-neutral-400">
            <Bot className="h-3.5 w-3.5" />
            Exposition IA / LLM
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <span className="inline-flex items-center rounded bg-neutral-200 px-2 py-0.5 font-mono text-xs text-neutral-700 dark:bg-neutral-700 dark:text-neutral-200">
              {endpoint.llm.tool_name}
            </span>
            <span
              data-testid={`endpoint-${index}-side-effects`}
              className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium ${SIDE_EFFECTS_STYLES[endpoint.llm.side_effects]}`}
            >
              {endpoint.llm.side_effects === 'destructive' && (
                <ShieldAlert className="h-3 w-3" />
              )}
              Effets : {SIDE_EFFECTS_LABELS[endpoint.llm.side_effects]}
            </span>
            {endpoint.llm.requires_human_approval && (
              <span className="inline-flex items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-700 dark:bg-amber-900/30 dark:text-amber-400">
                <ShieldCheck className="h-3 w-3" />
                Approbation humaine requise
              </span>
            )}
            {endpoint.llm.safe_for_agents ? (
              <span className="inline-flex items-center rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-700 dark:bg-green-900/30 dark:text-green-400">
                Sûr pour agents
              </span>
            ) : (
              <span className="inline-flex items-center rounded-full bg-neutral-100 px-2 py-0.5 text-xs font-medium text-neutral-500 dark:bg-neutral-700 dark:text-neutral-400">
                Non exposé aux agents
              </span>
            )}
          </div>
          {(endpoint.llm.summary || endpoint.llm.intent) && (
            <div className="mt-2 space-y-1 text-xs text-neutral-600 dark:text-neutral-400">
              {endpoint.llm.summary && <p>{endpoint.llm.summary}</p>}
              {endpoint.llm.intent && (
                <p className="text-neutral-400 dark:text-neutral-500">
                  Intention : {endpoint.llm.intent}
                </p>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// ============================================================================
// Onglet Versions — historique Git (sha7, auteur, date, message, badge signé)
// ============================================================================

function VersionsTab({ versions }: { versions: ContractVersion[] }) {
  if (versions.length === 0) {
    return (
      <div className="py-12 text-center text-neutral-500 dark:text-neutral-400">
        <GitCommit className="mx-auto mb-4 h-12 w-12 text-neutral-300 dark:text-neutral-600" />
        <p className="text-sm">Aucun historique pour ce contrat.</p>
        <p className="mt-1 text-xs">Les commits Git du fichier api.yaml apparaîtront ici.</p>
      </div>
    );
  }

  return (
    <div className="space-y-3">
      {versions.map((version, index) => (
        <div
          key={version.sha}
          data-testid="version-row"
          className="flex items-start gap-3 rounded-lg border border-neutral-100 p-3 transition-colors hover:bg-neutral-50 dark:border-neutral-800 dark:hover:bg-neutral-700/30"
        >
          {/* Pastille de timeline */}
          <div className="mt-1 flex flex-col items-center self-stretch">
            <div
              className={`h-3 w-3 rounded-full ${
                index === 0 ? 'bg-green-500 dark:bg-green-400' : 'bg-neutral-300 dark:bg-neutral-600'
              }`}
            />
            {index < versions.length - 1 && (
              <div className="mt-1 h-full w-px bg-neutral-200 dark:bg-neutral-700" />
            )}
          </div>

          <div className="min-w-0 flex-1">
            <p className="truncate text-sm font-medium text-neutral-900 dark:text-white">
              {version.message.split('\n')[0]}
            </p>
            <div className="mt-1.5 flex flex-wrap items-center gap-3 text-xs text-neutral-500 dark:text-neutral-400">
              <span>{version.author}</span>
              <ShaChip sha={version.sha} sha7={version.sha7} />
              <span>{formatDate(version.date)}</span>
              <SignedBadge signed={version.signed} />
            </div>
          </div>
        </div>
      ))}
    </div>
  );
}

// ============================================================================
// Dialogue de publication — message d'audit obligatoire (commit sur main)
// ============================================================================

function PublishDialog({
  contractName,
  message,
  onMessageChange,
  loading,
  onConfirm,
  onCancel,
}: {
  contractName: string;
  message: string;
  onMessageChange: (value: string) => void;
  loading: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  const canConfirm = message.trim().length > 0 && !loading;

  // Échap pour fermer (parité avec le ConfirmDialog vendorisé).
  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && !loading) onCancel();
    };
    document.addEventListener('keydown', handleKeyDown);
    return () => document.removeEventListener('keydown', handleKeyDown);
  }, [loading, onCancel]);

  return (
    <div
      className="fixed inset-0 z-[100] flex items-center justify-center p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="publish-dialog-title"
      onClick={(event) => {
        if (event.target === event.currentTarget && !loading) onCancel();
      }}
    >
      <div className="absolute inset-0 bg-black/50 animate-fade-in" />

      <div className="relative w-full max-w-md rounded-lg bg-white p-6 shadow-xl dark:bg-neutral-900 animate-scale-in">
        <div className="mx-auto mb-4 flex h-12 w-12 items-center justify-center rounded-full bg-primary-100 text-primary-600 dark:bg-primary-900 dark:text-primary-400">
          <Send className="h-6 w-6" />
        </div>
        <h2
          id="publish-dialog-title"
          className="text-center text-lg font-semibold text-neutral-900 dark:text-neutral-100"
        >
          Publier en dev
        </h2>
        <p className="mt-2 text-center text-sm text-neutral-600 dark:text-neutral-400">
          La publication de « {contractName} » crée un commit signé sur main (statut publié +
          deploy.dev.yaml + pack d'évidence).
        </p>

        <label className="mt-4 block">
          <span className="text-sm font-medium text-neutral-700 dark:text-neutral-300">
            Message d'audit <span className="text-red-500">*</span>
          </span>
          <textarea
            value={message}
            onChange={(event) => onMessageChange(event.target.value)}
            rows={3}
            maxLength={1000}
            autoFocus
            placeholder="Pourquoi cette publication ? (obligatoire — tracé dans le commit)"
            data-testid="contract-publish-message"
            className="mt-1 w-full rounded-lg border border-neutral-300 bg-white px-3 py-2 text-sm text-neutral-900 focus:border-primary-500 focus:ring-2 focus:ring-primary-500 dark:border-neutral-600 dark:bg-neutral-800 dark:text-white"
          />
        </label>

        <div className="mt-5 flex gap-3">
          <Button
            variant="secondary"
            fullWidth
            disabled={loading}
            onClick={onCancel}
            data-testid="contract-publish-cancel"
          >
            Annuler
          </Button>
          <Button
            variant="primary"
            fullWidth
            disabled={!canConfirm}
            loading={loading}
            onClick={onConfirm}
            data-testid="contract-publish-confirm"
          >
            Publier
          </Button>
        </div>
      </div>
    </div>
  );
}
