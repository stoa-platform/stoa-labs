import { useEffect, useMemo, useState } from 'react';
import { useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
// Le schéma UAC v1 est en draft 2020-12 ($schema) : on instancie la classe
// Ajv du build 2020 — l'appel reste `new Ajv({ allErrors: true, strict: false })`.
import Ajv from 'ajv/dist/2020';
import type { ErrorObject, ValidateFunction } from 'ajv';
import {
  AlertCircle,
  AlertTriangle,
  Bot,
  CheckCircle2,
  GitCommit,
  Globe,
  Plus,
  RefreshCw,
  Rocket,
  Save,
  ShieldCheck,
  Trash2,
  X,
} from 'lucide-react';
import { apiService } from '../services/api';
import { useAuth } from '../contexts/AuthContext';
import { useEnvironment } from '../contexts/EnvironmentContext';
import { useEnvironmentMode } from '../hooks/useEnvironmentMode';
import { PermissionGate } from '../components/PermissionGate';
import { Button } from '../vendor/stoa-shared/components/Button';
import { useToastActions } from '../vendor/stoa-shared/components/Toast';
import { EmptyState } from '../vendor/stoa-shared/components/EmptyState';
import { CardSkeleton, Skeleton } from '../vendor/stoa-shared/components/Skeleton';
import { Breadcrumb } from '../vendor/stoa-shared/components/Breadcrumb';
import { Collapsible } from '../vendor/stoa-shared/components/Collapsible';
import { getFriendlyErrorMessage } from '../vendor/stoa-shared/utils/errorMessages';
import type {
  CommitInfo,
  HttpMethod,
  UacClassification,
  UacContract,
  UacEndpoint,
  UacEndpointLlm,
  UacSideEffects,
  ValidationError,
} from '../types';

/**
 * Écran 6 (CADRAGE §4) — Éditeur de contrat UAC avec validation inline.
 *
 * - Validation ajv en direct sur le schéma chargé via GET /schema/uac
 *   (API-CONTRACT §5) + règle sémantique locale :
 *   side_effects == "destructive" ⇒ requires_human_approval == true
 *   (erreur bloquante ancrée sous le switch concerné).
 * - « Enregistrer (brouillon) » = PUT (mode draft : schéma seul) → commit signé.
 * - « Publier en dev » = zéro erreur + message obligatoire → POST publish
 *   → commit direct sur main + pack d'évidence → redirection vers le détail.
 * - Le BFF reste l'autorité : il revalide tout avant commit (§5) ; l'UI
 *   masque les actions interdites (RBAC §2), elle ne fait pas autorité.
 */

// ============================================================================
// Constantes du domaine
// ============================================================================

const HTTP_METHODS: HttpMethod[] = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'];

const CLASSIFICATIONS: Array<{ value: UacClassification; label: string }> = [
  { value: 'H', label: 'H — Haute (standard)' },
  { value: 'VH', label: 'VH — Très haute (sensible)' },
  { value: 'VVH', label: 'VVH — Critique' },
];

const SIDE_EFFECTS: Array<{ value: UacSideEffects; label: string }> = [
  { value: 'none', label: 'Aucun (none)' },
  { value: 'read', label: 'Lecture (read)' },
  { value: 'write', label: 'Écriture (write)' },
  { value: 'destructive', label: 'Destructif (destructive)' },
];

const SIDE_EFFECT_SHORT: Record<UacSideEffects, string> = {
  none: 'Aucun effet',
  read: 'Lecture',
  write: 'Écriture',
  destructive: 'Destructif',
};

/** Message de la règle sémantique §5 (code BFF : DESTRUCTIVE_REQUIRES_APPROVAL). */
const DESTRUCTIVE_MESSAGE = 'Un endpoint destructif exige l’approbation humaine';

/** Mots-clés ajv composites dont les messages sont du bruit (les erreurs filles suffisent). */
const NOISE_KEYWORDS = new Set(['if', 'then', 'else', 'anyOf', 'oneOf', 'allOf', 'not']);

// ============================================================================
// Aides validation — chemins & traduction des erreurs ajv
// ============================================================================

/** `/endpoints/0/llm/summary` (+ missingProperty) → `endpoints[0].llm.summary`. */
function toUiPath(err: ErrorObject): string {
  const segments = err.instancePath
    .split('/')
    .filter(Boolean)
    .map((s) => s.replace(/~1/g, '/').replace(/~0/g, '~'));
  if (err.keyword === 'required') {
    const missing = (err.params as { missingProperty?: string }).missingProperty;
    if (missing) segments.push(missing);
  }
  return segments.reduce(
    (acc, seg) => (/^\d+$/.test(seg) ? `${acc}[${seg}]` : acc ? `${acc}.${seg}` : seg),
    ''
  );
}

/** Traduit les erreurs ajv en messages français sobres. */
function translateAjvError(err: ErrorObject, path: string): string {
  const params = err.params as Record<string, unknown>;
  switch (err.keyword) {
    case 'required':
      return 'Champ obligatoire.';
    case 'minLength':
      return 'Ce champ ne peut pas être vide.';
    case 'maxLength':
      return `Maximum ${params.limit} caractères.`;
    case 'pattern':
      if (path.endsWith('version')) return 'Version sémantique attendue (ex. 1.2.0).';
      if (path === 'name') return 'Nom en kebab-case (minuscules, chiffres, tirets).';
      return 'Format invalide.';
    case 'enum': {
      const allowed = params.allowedValues as unknown[] | undefined;
      return `Valeur autorisée : ${allowed?.join(', ') ?? '—'}.`;
    }
    case 'minItems':
      return `Au moins ${params.limit} élément${Number(params.limit) > 1 ? 's' : ''} requis.`;
    case 'type':
      return `Type attendu : ${params.type}.`;
    case 'additionalProperties':
      return `Propriété inconnue : ${params.additionalProperty}.`;
    case 'format':
      return 'Format invalide (URI attendue).';
    case 'minimum':
      return `Valeur minimale : ${params.limit}.`;
    case 'maximum':
      return `Valeur maximale : ${params.limit}.`;
    default:
      return err.message ?? 'Valeur invalide.';
  }
}

// ============================================================================
// Fabriques (nouvel endpoint / bloc LLM)
// ============================================================================

function createDefaultEndpoint(): UacEndpoint {
  return { path: '', methods: ['GET'], backend_url: '' };
}

function createDefaultLlm(): UacEndpointLlm {
  return {
    summary: '',
    intent: '',
    tool_name: '',
    side_effects: 'read',
    safe_for_agents: false,
    requires_human_approval: false,
    // Le schéma exige ≥ 1 exemple — entrée vide valide par défaut.
    examples: [{ input: {} }],
  };
}

// ============================================================================
// Styles partagés des champs
// ============================================================================

const LABEL_CLASS = 'block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-1.5';

function fieldClass(hasError: boolean): string {
  return [
    'w-full rounded-lg border px-3 py-2 text-sm transition-colors',
    'bg-white dark:bg-neutral-800 text-neutral-900 dark:text-white',
    'placeholder-neutral-400 dark:placeholder-neutral-500',
    'focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-transparent',
    'disabled:opacity-60',
    hasError
      ? 'border-error-500 dark:border-error-500'
      : 'border-neutral-300 dark:border-neutral-600',
  ].join(' ');
}

// ============================================================================
// Atomes locaux (pas de brique équivalente dans vendor/stoa-shared)
// ============================================================================

/** Erreur inline ancrée sous un champ. */
function FieldError({ messages, testId }: { messages?: string[]; testId?: string }) {
  if (!messages || messages.length === 0) return null;
  return (
    <div
      role="alert"
      data-testid={testId}
      className="mt-1.5 flex items-start gap-1.5 text-xs text-error-600 dark:text-error-400"
    >
      <AlertCircle className="h-3.5 w-3.5 flex-shrink-0 mt-px" />
      <span>{messages.join(' — ')}</span>
    </div>
  );
}

/** Interrupteur accessible (role="switch") — il n'existe pas dans le design system vendorisé. */
function Switch({
  checked,
  onChange,
  label,
  description,
  testId,
}: {
  checked: boolean;
  onChange: (value: boolean) => void;
  label: string;
  description?: string;
  testId: string;
}) {
  return (
    <div className="flex items-start justify-between gap-4">
      <div className="min-w-0">
        <p className="text-sm font-medium text-neutral-700 dark:text-neutral-300">{label}</p>
        {description && (
          <p className="mt-0.5 text-xs text-neutral-500 dark:text-neutral-400">{description}</p>
        )}
      </div>
      <button
        type="button"
        role="switch"
        aria-checked={checked}
        aria-label={label}
        data-testid={testId}
        onClick={() => onChange(!checked)}
        className={`relative inline-flex h-6 w-11 flex-shrink-0 items-center rounded-full transition-colors focus:outline-none focus:ring-2 focus:ring-primary-500 focus:ring-offset-1 dark:focus:ring-offset-neutral-900 disabled:opacity-50 ${
          checked ? 'bg-primary-600' : 'bg-neutral-300 dark:bg-neutral-600'
        }`}
      >
        <span
          className={`inline-block h-4 w-4 transform rounded-full bg-white shadow transition-transform ${
            checked ? 'translate-x-6' : 'translate-x-1'
          }`}
        />
      </button>
    </div>
  );
}

/**
 * Boîte de publication avec message OBLIGATOIRE.
 * Le ConfirmDialog vendorisé n'accepte qu'un message texte (pas de champ de
 * saisie) : cette boîte page-locale en reprend exactement la structure
 * visuelle (backdrop, panneau, actions) et réutilise la brique Button.
 */
function PublishDialog({
  open,
  loading,
  contractLabel,
  version,
  hasUnsavedChanges,
  onConfirm,
  onCancel,
}: {
  open: boolean;
  loading: boolean;
  contractLabel: string;
  version: string;
  hasUnsavedChanges: boolean;
  onConfirm: (message: string) => void;
  onCancel: () => void;
}) {
  const [message, setMessage] = useState('');

  // Réinitialise le message à chaque ouverture.
  useEffect(() => {
    if (open) setMessage('');
  }, [open]);

  // Fermeture par Échap (sauf pendant le traitement).
  useEffect(() => {
    if (!open) return;
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !loading) onCancel();
    };
    document.addEventListener('keydown', handleKeyDown);
    return () => document.removeEventListener('keydown', handleKeyDown);
  }, [open, loading, onCancel]);

  if (!open) return null;

  const canConfirm = message.trim().length > 0 && !loading;

  return (
    <div
      className="fixed inset-0 z-[100] flex items-center justify-center p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="publish-dialog-title"
      onClick={(e) => {
        if (e.target === e.currentTarget && !loading) onCancel();
      }}
    >
      <div className="absolute inset-0 bg-black/50 animate-fade-in" />
      <div className="relative w-full max-w-md rounded-modal bg-white dark:bg-neutral-900 shadow-modal animate-scale-in">
        <button
          onClick={onCancel}
          disabled={loading}
          data-testid="publish-cancel-x"
          aria-label="Fermer la boîte de dialogue"
          className="absolute top-4 right-4 p-1 rounded-full text-neutral-400 hover:text-neutral-600 dark:text-neutral-500 dark:hover:text-neutral-300 hover:bg-neutral-100 dark:hover:bg-neutral-800 transition-colors disabled:opacity-50"
        >
          <X className="h-5 w-5" />
        </button>

        <div className="p-6">
          <div className="mx-auto mb-4 flex h-12 w-12 items-center justify-center rounded-full bg-primary-100 dark:bg-primary-900 text-primary-600 dark:text-primary-400">
            <Rocket className="h-6 w-6" />
          </div>
          <h2
            id="publish-dialog-title"
            className="mb-2 text-center text-lg font-semibold text-neutral-900 dark:text-neutral-100"
          >
            Publier en dev
          </h2>
          <p className="text-center text-sm text-neutral-600 dark:text-neutral-400">
            « {contractLabel} » v{version} sera publié : commit signé direct sur{' '}
            <code className="font-mono text-xs">main</code> + pack d’évidence
            (deploy.dev.yaml mis à jour).
          </p>
          {hasUnsavedChanges && (
            <p className="mt-2 text-center text-xs text-warning-600 dark:text-warning-400">
              Les modifications non enregistrées seront d’abord commitées en brouillon.
            </p>
          )}

          <label htmlFor="publish-message" className={`${LABEL_CLASS} mt-4`}>
            Message de publication <span className="text-error-500">*</span>
          </label>
          <textarea
            id="publish-message"
            data-testid="publish-message"
            rows={3}
            maxLength={1000}
            value={message}
            onChange={(e) => setMessage(e.target.value)}
            placeholder="Pourquoi cette publication ? (tracé dans le commit et l’évidence)"
            className={fieldClass(false)}
            disabled={loading}
          />
          <p className="mt-1 text-right text-xs text-neutral-400 dark:text-neutral-500">
            {message.length}/1000
          </p>
        </div>

        <div className="flex gap-3 px-6 pb-6">
          <Button
            variant="secondary"
            fullWidth
            onClick={onCancel}
            disabled={loading}
            data-testid="publish-cancel"
          >
            Annuler
          </Button>
          <Button
            variant="primary"
            fullWidth
            loading={loading}
            disabled={!canConfirm}
            onClick={() => onConfirm(message.trim())}
            data-testid="publish-confirm"
            title={canConfirm ? undefined : 'Le message de publication est obligatoire'}
          >
            Publier
          </Button>
        </div>
      </div>
    </div>
  );
}

// ============================================================================
// Page
// ============================================================================

export default function ContractEdit() {
  const { slug } = useParams<{ slug: string }>();
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();
  const { user, hasPermission } = useAuth();
  const { activeConfig } = useEnvironment();
  const { canEdit } = useEnvironmentMode();
  const toast = useToastActions();
  const queryClient = useQueryClient();

  // Scope tenant : claim JWT, surchargé par ?tenant= (cpi-admin multi-tenant).
  const tenantParam = searchParams.get('tenant') ?? '';
  const tenant = tenantParam || user?.tenant || '';
  const tenantSuffix = tenantParam ? `?tenant=${encodeURIComponent(tenantParam)}` : '';
  const detailPath = `/contracts/${slug ?? ''}${tenantSuffix}`;

  // --------------------------------------------------------------------------
  // État local de l'éditeur
  // --------------------------------------------------------------------------

  const [form, setForm] = useState<UacContract | null>(null);
  const [dirty, setDirty] = useState(false);
  const [lastCommit, setLastCommit] = useState<CommitInfo | null>(null);
  const [publishOpen, setPublishOpen] = useState(false);

  // --------------------------------------------------------------------------
  // Données (TanStack Query)
  // --------------------------------------------------------------------------

  const schemaQuery = useQuery({
    queryKey: ['uac-schema'],
    queryFn: () => apiService.getUacSchema(),
    staleTime: Infinity,
  });

  const contractQuery = useQuery({
    queryKey: ['contract', tenant, slug],
    queryFn: () => apiService.getContract(tenant, slug!),
    enabled: Boolean(tenant && slug),
  });

  // Initialise le formulaire à la première lecture (les refetchs ultérieurs
  // n'écrasent jamais une édition en cours).
  useEffect(() => {
    if (contractQuery.data && form === null) {
      setForm(contractQuery.data.contract);
    }
  }, [contractQuery.data, form]);

  // --------------------------------------------------------------------------
  // Mutateurs immuables du formulaire
  // --------------------------------------------------------------------------

  const mutateForm = (mutator: (draft: UacContract) => UacContract) => {
    setForm((prev) => (prev ? mutator(prev) : prev));
    setDirty(true);
  };

  const setMeta = (patch: Partial<UacContract>) => mutateForm((c) => ({ ...c, ...patch }));

  const setEndpoint = (index: number, patch: Partial<UacEndpoint>) =>
    mutateForm((c) => ({
      ...c,
      endpoints: c.endpoints.map((ep, i) => (i === index ? { ...ep, ...patch } : ep)),
    }));

  const setEndpointLlm = (index: number, patch: Partial<UacEndpointLlm>) =>
    mutateForm((c) => ({
      ...c,
      endpoints: c.endpoints.map((ep, i) =>
        i === index && ep.llm ? { ...ep, llm: { ...ep.llm, ...patch } } : ep
      ),
    }));

  const toggleMethod = (index: number, method: HttpMethod) =>
    mutateForm((c) => ({
      ...c,
      endpoints: c.endpoints.map((ep, i) => {
        if (i !== index) return ep;
        const next = ep.methods.includes(method)
          ? ep.methods.filter((m) => m !== method)
          : [...ep.methods, method];
        // Ordre canonique GET → OPTIONS pour des commits stables.
        next.sort((a, b) => HTTP_METHODS.indexOf(a) - HTTP_METHODS.indexOf(b));
        return { ...ep, methods: next };
      }),
    }));

  const toggleLlm = (index: number, enabled: boolean) =>
    mutateForm((c) => ({
      ...c,
      endpoints: c.endpoints.map((ep, i) => {
        if (i !== index) return ep;
        if (!enabled) {
          const { llm: _removed, ...rest } = ep;
          return rest;
        }
        return { ...ep, llm: ep.llm ?? createDefaultLlm() };
      }),
    }));

  const addEndpoint = () =>
    mutateForm((c) => ({ ...c, endpoints: [...c.endpoints, createDefaultEndpoint()] }));

  const removeEndpoint = (index: number) =>
    mutateForm((c) => ({ ...c, endpoints: c.endpoints.filter((_, i) => i !== index) }));

  // --------------------------------------------------------------------------
  // Validation en direct : ajv (schéma §5) + règle sémantique locale
  // --------------------------------------------------------------------------

  const validator = useMemo<ValidateFunction | null>(() => {
    const schema = schemaQuery.data;
    if (!schema) return null;
    try {
      const ajv = new Ajv({ allErrors: true, strict: false });
      return ajv.compile(schema);
    } catch {
      // Repli si un `format` du schéma n'est pas connu d'ajv (pas d'ajv-formats).
      try {
        const ajv = new Ajv({ allErrors: true, strict: false, validateFormats: false });
        return ajv.compile(schema);
      } catch {
        return null;
      }
    }
  }, [schemaQuery.data]);

  const errors = useMemo<ValidationError[]>(() => {
    if (!form) return [];
    const collected: ValidationError[] = [];

    // 1. Schéma JSON (ajv) — erreurs traduites, bruit composite filtré.
    if (validator) {
      validator(form);
      for (const err of validator.errors ?? []) {
        if (NOISE_KEYWORDS.has(err.keyword)) continue;
        const path = toUiPath(err);
        collected.push({ path, message: translateAjvError(err, path) });
      }
    }

    // 2. Règle sémantique §5 : destructive ⇒ approbation humaine (bloquante).
    form.endpoints.forEach((ep, i) => {
      if (ep.llm && ep.llm.side_effects === 'destructive' && !ep.llm.requires_human_approval) {
        collected.push({
          path: `endpoints[${i}].llm.requires_human_approval`,
          message: DESTRUCTIVE_MESSAGE,
        });
      }
    });

    // Dédoublonnage (allErrors peut produire des doublons via les branches if/then).
    const seen = new Set<string>();
    return collected.filter((e) => {
      const key = `${e.path}|${e.message}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  }, [form, validator]);

  const errorsByPath = useMemo(() => {
    const map = new Map<string, string[]>();
    for (const e of errors) {
      const list = map.get(e.path) ?? [];
      list.push(e.message);
      map.set(e.path, list);
    }
    return map;
  }, [errors]);

  const fieldErrors = (path: string) => errorsByPath.get(path);

  const endpointErrorCount = (index: number) =>
    errors.filter(
      (e) => e.path === `endpoints[${index}]` || e.path.startsWith(`endpoints[${index}].`)
    ).length;

  // Mode draft (§5) : schéma seul. La règle sémantique ne bloque que la publication.
  const semanticErrorCount = errors.filter((e) => e.message === DESTRUCTIVE_MESSAGE).length;
  const schemaErrorCount = errors.length - semanticErrorCount;

  // Mode published (§5) : schéma + règle sémantique + ≥ 1 endpoint (ou llm_config).
  const needsEndpointForPublish = form ? form.endpoints.length === 0 && !form.llm_config : false;
  const canPublishNow = errors.length === 0 && !needsEndpointForPublish;

  // --------------------------------------------------------------------------
  // Mutations (commits signés côté BFF — il relit depuis Git et répond relu)
  // --------------------------------------------------------------------------

  const invalidateContractQueries = () => {
    void queryClient.invalidateQueries({ queryKey: ['contract', tenant, slug] });
    void queryClient.invalidateQueries({ queryKey: ['contracts', tenant] });
    void queryClient.invalidateQueries({ queryKey: ['audit'] });
    void queryClient.invalidateQueries({ queryKey: ['dashboard'] });
  };

  const saveMutation = useMutation({
    mutationFn: (body: { contract: UacContract; message?: string }) =>
      apiService.updateContract(tenant, slug!, body),
    onSuccess: (res) => {
      // Le BFF répond avec le contrat RELU depuis Git — il devient l'état canonique.
      setForm(res.contract);
      setDirty(false);
      setLastCommit(res.commit);
      invalidateContractQueries();
      toast.success(
        `Brouillon enregistré — commit ${res.commit.sha7}${res.commit.signed ? ' ✓ signé' : ''}`
      );
    },
    onError: (err) => {
      toast.error('Échec de l’enregistrement', getFriendlyErrorMessage(err));
    },
  });

  const publishMutation = useMutation({
    mutationFn: async (message: string) => {
      // La publication porte sur l'état en Git : on commite d'abord le brouillon
      // courant si nécessaire, puis on publie (deploy.dev + evidence, §4).
      if (dirty && form) {
        await apiService.updateContract(tenant, slug!, {
          contract: form,
          message: `Brouillon avant publication : ${message}`,
        });
        setDirty(false);
      }
      return apiService.publishContract(tenant, slug!, { message });
    },
    onSuccess: (res) => {
      setPublishOpen(false);
      setLastCommit(res.commit);
      invalidateContractQueries();
      toast.success(
        `Contrat publié en dev — commit ${res.commit.sha7}${res.commit.signed ? ' ✓ signé' : ''}`,
        `Pack d’évidence : ${res.evidence}`
      );
      navigate(detailPath);
    },
    onError: (err) => {
      toast.error('Échec de la publication', getFriendlyErrorMessage(err));
    },
  });

  const isWorking = saveMutation.isPending || publishMutation.isPending;

  const handleSave = () => {
    if (!form || !slug || schemaErrorCount > 0) return;
    saveMutation.mutate({ contract: form });
  };

  // --------------------------------------------------------------------------
  // Rendus dégradés (RBAC, tenant, chargement, erreur)
  // --------------------------------------------------------------------------

  // RBAC §2 : sans apis:update, l'éditeur n'est pas proposé (le BFF refuserait
  // de toute façon l'écriture — l'UI ne fait que masquer).
  if (!hasPermission('apis:update')) {
    return (
      <div data-testid="page-contract-edit" className="animate-fade-in">
        <EmptyState
          title="Accès non autorisé"
          description="La modification des contrats requiert la permission « apis:update » (rôles cpi-admin ou tenant-admin)."
          action={{ label: 'Retour au contrat', onClick: () => navigate(detailPath) }}
        />
      </div>
    );
  }

  if (!slug || !tenant) {
    return (
      <div data-testid="page-contract-edit" className="animate-fade-in">
        <EmptyState
          variant="search"
          title="Tenant non déterminé"
          description="Votre compte n’est rattaché à aucun tenant. Ouvrez l’éditeur depuis le catalogue des contrats (le scope tenant est alors transmis en paramètre)."
          action={{ label: 'Retour au catalogue', onClick: () => navigate('/contracts') }}
        />
      </div>
    );
  }

  if (contractQuery.isError) {
    return (
      <div data-testid="page-contract-edit" className="animate-fade-in">
        <EmptyState
          variant="service-unavailable"
          title="Impossible de charger le contrat"
          description={getFriendlyErrorMessage(contractQuery.error)}
          action={{
            label: 'Réessayer',
            onClick: () => void contractQuery.refetch(),
            icon: <RefreshCw className="h-4 w-4" />,
          }}
          secondaryAction={{ label: 'Retour au contrat', onClick: () => navigate(detailPath) }}
        />
      </div>
    );
  }

  if (contractQuery.isLoading || schemaQuery.isLoading || !form) {
    return (
      <div data-testid="page-contract-edit" className="space-y-6 animate-fade-in">
        <Skeleton className="h-4 w-64" />
        <div className="flex items-center justify-between">
          <Skeleton className="h-8 w-80" />
          <Skeleton className="h-10 w-64 rounded-lg" />
        </div>
        <div className="grid grid-cols-1 gap-6 xl:grid-cols-3">
          <div className="space-y-6 xl:col-span-2">
            <CardSkeleton />
            <CardSkeleton />
            <CardSkeleton />
          </div>
          <CardSkeleton />
        </div>
      </div>
    );
  }

  // --------------------------------------------------------------------------
  // Rendu principal
  // --------------------------------------------------------------------------

  return (
    <div data-testid="page-contract-edit" className="space-y-6 animate-fade-in">
      {/* En-tête : fil d'Ariane, titre, actions */}
      <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
        <div className="min-w-0">
          <Breadcrumb
            items={[
              { label: 'Contrats', href: '/contracts' },
              { label: slug, href: detailPath },
              { label: 'Éditeur' },
            ]}
            onNavigate={(href) => navigate(href)}
          />
          <h1 className="mt-2 truncate text-2xl font-bold text-neutral-900 dark:text-white">
            Éditeur — {form.display_name || slug}
          </h1>
          <p className="mt-1 text-sm text-neutral-500 dark:text-neutral-400">
            Chaque enregistrement crée un commit signé dans le repo de gouvernance —
            le serveur revalide tout avant d’écrire.
          </p>
        </div>

        <div className="flex flex-wrap items-center gap-3">
          {dirty && (
            <span
              data-testid="editor-dirty"
              className="inline-flex items-center gap-1.5 text-xs font-medium text-warning-600 dark:text-warning-400"
            >
              <span className="h-2 w-2 rounded-full bg-warning-500" aria-hidden="true" />
              Modifications non enregistrées
            </span>
          )}

          {/* Référence du dernier commit d'écriture (cible Playwright commit-sha). */}
          {lastCommit && (
            <span
              data-testid="commit-sha"
              title={lastCommit.sha}
              className="inline-flex items-center gap-1.5 rounded-lg border border-success-200 dark:border-success-700 bg-success-50 dark:bg-success-900/20 px-3 py-1.5 text-xs font-medium text-success-700 dark:text-success-400"
            >
              <GitCommit className="h-3.5 w-3.5" />
              {lastCommit.sha7}
              {lastCommit.signed && (
                <span className="inline-flex items-center gap-1">
                  <ShieldCheck className="h-3.5 w-3.5" />✓ signé
                </span>
              )}
            </span>
          )}

          {canEdit && (
            <>
              <Button
                variant="secondary"
                data-testid="editor-save"
                icon={<Save className="h-4 w-4" />}
                loading={saveMutation.isPending}
                disabled={isWorking || schemaErrorCount > 0}
                title={
                  schemaErrorCount > 0
                    ? 'Corrigez d’abord les erreurs de schéma'
                    : 'Commit signé en mode brouillon'
                }
                onClick={handleSave}
              >
                Enregistrer (brouillon)
              </Button>
              <PermissionGate permission="apis:publish">
                <Button
                  variant="primary"
                  data-testid="editor-publish"
                  icon={<Rocket className="h-4 w-4" />}
                  loading={publishMutation.isPending}
                  disabled={isWorking || !canPublishNow}
                  title={
                    canPublishNow
                      ? 'Publication dev : commit direct sur main + évidence'
                      : 'La publication exige zéro erreur de validation'
                  }
                  onClick={() => setPublishOpen(true)}
                >
                  Publier en dev
                </Button>
              </PermissionGate>
            </>
          )}
        </div>
      </div>

      {/* Environnement non éditable (staging = promotion seule, production = lecture seule). */}
      {!canEdit && (
        <div
          data-testid="editor-readonly-banner"
          className="flex items-start gap-2 rounded-lg border border-warning-200 dark:border-warning-700 bg-warning-50 dark:bg-warning-900/20 px-4 py-3 text-sm text-warning-800 dark:text-warning-300"
        >
          <AlertTriangle className="mt-0.5 h-4 w-4 flex-shrink-0" />
          <span>
            Environnement « {activeConfig.label} » — édition désactivée. Basculez sur
            Développement pour modifier ce contrat ; les autres environnements ne changent
            que par promotion approuvée.
          </span>
        </div>
      )}

      <div className="grid grid-cols-1 gap-6 xl:grid-cols-3">
        {/* ================= Colonne formulaire ================= */}
        <fieldset disabled={!canEdit || isWorking} className="min-w-0 space-y-6 xl:col-span-2">
          {/* ---- Métadonnées ---- */}
          <section className="rounded-card border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-800 p-6">
            <h2 className="text-base font-semibold text-neutral-900 dark:text-neutral-100">
              Métadonnées
            </h2>
            <p className="mt-1 text-xs text-neutral-500 dark:text-neutral-400">
              Identifiants non modifiables :{' '}
              <code className="font-mono">{form.name}</code> · tenant{' '}
              <code className="font-mono">{form.tenant_id}</code> · statut{' '}
              <span className="font-medium">{form.status}</span>
            </p>

            <div className="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-2">
              <div>
                <label htmlFor="editor-display-name" className={LABEL_CLASS}>
                  Nom d’affichage
                </label>
                <input
                  id="editor-display-name"
                  data-testid="editor-display-name"
                  type="text"
                  value={form.display_name ?? ''}
                  onChange={(e) => setMeta({ display_name: e.target.value || null })}
                  placeholder="Nom lisible du contrat"
                  className={fieldClass(Boolean(fieldErrors('display_name')))}
                />
                <FieldError messages={fieldErrors('display_name')} />
              </div>

              <div>
                <label htmlFor="editor-version" className={LABEL_CLASS}>
                  Version <span className="text-error-500">*</span>
                </label>
                <input
                  id="editor-version"
                  data-testid="editor-version"
                  type="text"
                  value={form.version}
                  onChange={(e) => setMeta({ version: e.target.value })}
                  placeholder="1.0.0"
                  className={`${fieldClass(Boolean(fieldErrors('version')))} font-mono`}
                />
                <FieldError messages={fieldErrors('version')} />
              </div>

              <div>
                <label htmlFor="editor-classification" className={LABEL_CLASS}>
                  Classification (DORA) <span className="text-error-500">*</span>
                </label>
                <select
                  id="editor-classification"
                  data-testid="editor-classification"
                  value={form.classification}
                  onChange={(e) =>
                    setMeta({ classification: e.target.value as UacClassification })
                  }
                  className={fieldClass(Boolean(fieldErrors('classification')))}
                >
                  {CLASSIFICATIONS.map((c) => (
                    <option key={c.value} value={c.value}>
                      {c.label}
                    </option>
                  ))}
                </select>
                <FieldError messages={fieldErrors('classification')} />
              </div>

              <div className="sm:col-span-2">
                <label htmlFor="editor-description" className={LABEL_CLASS}>
                  Description
                </label>
                <textarea
                  id="editor-description"
                  data-testid="editor-description"
                  rows={3}
                  value={form.description ?? ''}
                  onChange={(e) => setMeta({ description: e.target.value || null })}
                  placeholder="À quoi sert cette API ? (visible dans le catalogue)"
                  className={fieldClass(Boolean(fieldErrors('description')))}
                />
                <FieldError messages={fieldErrors('description')} />
              </div>
            </div>
          </section>

          {/* ---- Endpoints ---- */}
          <section className="rounded-card border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-800 p-6">
            <div className="flex items-center justify-between gap-4">
              <div>
                <h2 className="text-base font-semibold text-neutral-900 dark:text-neutral-100">
                  Endpoints
                </h2>
                <p className="mt-1 text-xs text-neutral-500 dark:text-neutral-400">
                  {form.endpoints.length} endpoint{form.endpoints.length > 1 ? 's' : ''} — chaque
                  endpoint peut être projeté en outil MCP via son bloc LLM.
                </p>
              </div>
              <Button
                variant="secondary"
                size="sm"
                data-testid="endpoint-add"
                icon={<Plus className="h-4 w-4" />}
                onClick={addEndpoint}
              >
                Ajouter un endpoint
              </Button>
            </div>

            {form.endpoints.length === 0 ? (
              <EmptyState
                compact
                variant="apis"
                title="Aucun endpoint"
                description="Ajoutez un premier endpoint — la publication exige au moins un endpoint (ou une configuration LLM)."
              />
            ) : (
              <div className="mt-4 space-y-3">
                {form.endpoints.map((ep, i) => {
                  const errorCount = endpointErrorCount(i);
                  const destructiveUnapproved =
                    ep.llm?.side_effects === 'destructive' && !ep.llm.requires_human_approval;
                  return (
                    <Collapsible
                      key={i}
                      variant="bordered"
                      defaultExpanded
                      icon={
                        destructiveUnapproved ? (
                          <AlertTriangle className="h-4 w-4 text-error-500" />
                        ) : (
                          <Globe className="h-4 w-4" />
                        )
                      }
                      badge={
                        errorCount > 0
                          ? `${errorCount} erreur${errorCount > 1 ? 's' : ''}`
                          : ep.llm
                            ? `MCP · ${SIDE_EFFECT_SHORT[ep.llm.side_effects]}`
                            : undefined
                      }
                      title={
                        <span className="flex flex-wrap items-center gap-2">
                          <span className="font-mono text-xs font-semibold text-primary-600 dark:text-primary-400">
                            {ep.methods.length > 0 ? ep.methods.join(' · ') : 'Ø'}
                          </span>
                          <span className="font-mono text-sm">
                            {ep.path || '(chemin à définir)'}
                          </span>
                        </span>
                      }
                    >
                      <div className="space-y-4">
                        {/* Chemin + backend */}
                        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
                          <div>
                            <label htmlFor={`endpoint-path-${i}`} className={LABEL_CLASS}>
                              Chemin <span className="text-error-500">*</span>
                            </label>
                            <input
                              id={`endpoint-path-${i}`}
                              data-testid={`endpoint-path-${i}`}
                              type="text"
                              value={ep.path}
                              onChange={(e) => setEndpoint(i, { path: e.target.value })}
                              placeholder="/payments/{id}"
                              className={`${fieldClass(
                                Boolean(fieldErrors(`endpoints[${i}].path`))
                              )} font-mono`}
                            />
                            <FieldError messages={fieldErrors(`endpoints[${i}].path`)} />
                          </div>
                          <div>
                            <label htmlFor={`endpoint-backend-url-${i}`} className={LABEL_CLASS}>
                              URL du backend <span className="text-error-500">*</span>
                            </label>
                            <input
                              id={`endpoint-backend-url-${i}`}
                              data-testid={`endpoint-backend-url-${i}`}
                              type="text"
                              value={ep.backend_url}
                              onChange={(e) => setEndpoint(i, { backend_url: e.target.value })}
                              placeholder="http://backend.internal:8080"
                              className={`${fieldClass(
                                Boolean(fieldErrors(`endpoints[${i}].backend_url`))
                              )} font-mono`}
                            />
                            <FieldError messages={fieldErrors(`endpoints[${i}].backend_url`)} />
                          </div>
                        </div>

                        {/* Méthodes HTTP */}
                        <div>
                          <span className={LABEL_CLASS}>
                            Méthodes HTTP <span className="text-error-500">*</span>
                          </span>
                          <div className="flex flex-wrap gap-2">
                            {HTTP_METHODS.map((method) => {
                              const selected = ep.methods.includes(method);
                              return (
                                <label
                                  key={method}
                                  className={`inline-flex cursor-pointer items-center rounded-lg border px-2.5 py-1.5 font-mono text-xs font-medium transition-colors ${
                                    selected
                                      ? 'border-primary-500 bg-primary-50 text-primary-700 dark:bg-primary-900/30 dark:text-primary-300'
                                      : 'border-neutral-300 text-neutral-600 hover:border-neutral-400 dark:border-neutral-600 dark:text-neutral-400 dark:hover:border-neutral-500'
                                  }`}
                                >
                                  <input
                                    type="checkbox"
                                    className="sr-only"
                                    checked={selected}
                                    onChange={() => toggleMethod(i, method)}
                                    data-testid={`endpoint-method-${i}-${method}`}
                                  />
                                  {method}
                                </label>
                              );
                            })}
                          </div>
                          <FieldError messages={fieldErrors(`endpoints[${i}].methods`)} />
                        </div>

                        {/* Bloc LLM optionnel (projection MCP) */}
                        <div className="border-t border-neutral-200 pt-4 dark:border-neutral-700">
                          <Switch
                            checked={Boolean(ep.llm)}
                            onChange={(v) => toggleLlm(i, v)}
                            label="Métadonnées LLM (outil MCP)"
                            description="Expose cet endpoint comme outil aux agents IA — gouverné par les champs ci-dessous."
                            testId={`endpoint-llm-toggle-${i}`}
                          />

                          {ep.llm && (
                            <div className="mt-4 space-y-4 rounded-lg border border-neutral-200 bg-neutral-50 p-4 dark:border-neutral-700 dark:bg-neutral-900/40">
                              <div className="flex items-center gap-2 text-xs font-medium uppercase tracking-wider text-neutral-500 dark:text-neutral-400">
                                <Bot className="h-4 w-4" />
                                Projection MCP
                              </div>

                              <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
                                <div>
                                  <label
                                    htmlFor={`endpoint-llm-summary-${i}`}
                                    className={LABEL_CLASS}
                                  >
                                    Résumé <span className="text-error-500">*</span>
                                  </label>
                                  <input
                                    id={`endpoint-llm-summary-${i}`}
                                    data-testid={`endpoint-llm-summary-${i}`}
                                    type="text"
                                    value={ep.llm.summary}
                                    onChange={(e) =>
                                      setEndpointLlm(i, { summary: e.target.value })
                                    }
                                    placeholder="Ce que fait l’outil, en une phrase"
                                    className={fieldClass(
                                      Boolean(fieldErrors(`endpoints[${i}].llm.summary`))
                                    )}
                                  />
                                  <FieldError
                                    messages={fieldErrors(`endpoints[${i}].llm.summary`)}
                                  />
                                </div>

                                <div>
                                  <label
                                    htmlFor={`endpoint-llm-tool-name-${i}`}
                                    className={LABEL_CLASS}
                                  >
                                    Nom de l’outil <span className="text-error-500">*</span>
                                  </label>
                                  <input
                                    id={`endpoint-llm-tool-name-${i}`}
                                    data-testid={`endpoint-llm-tool-name-${i}`}
                                    type="text"
                                    value={ep.llm.tool_name}
                                    onChange={(e) =>
                                      setEndpointLlm(i, { tool_name: e.target.value })
                                    }
                                    placeholder="initiate_payment"
                                    className={`${fieldClass(
                                      Boolean(fieldErrors(`endpoints[${i}].llm.tool_name`))
                                    )} font-mono`}
                                  />
                                  <FieldError
                                    messages={fieldErrors(`endpoints[${i}].llm.tool_name`)}
                                  />
                                </div>

                                <div className="sm:col-span-2">
                                  <label
                                    htmlFor={`endpoint-llm-intent-${i}`}
                                    className={LABEL_CLASS}
                                  >
                                    Intention (quand l’agent doit l’utiliser){' '}
                                    <span className="text-error-500">*</span>
                                  </label>
                                  <textarea
                                    id={`endpoint-llm-intent-${i}`}
                                    data-testid={`endpoint-llm-intent-${i}`}
                                    rows={2}
                                    value={ep.llm.intent}
                                    onChange={(e) =>
                                      setEndpointLlm(i, { intent: e.target.value })
                                    }
                                    placeholder="Décrivez le cas d’usage pour l’agent"
                                    className={fieldClass(
                                      Boolean(fieldErrors(`endpoints[${i}].llm.intent`))
                                    )}
                                  />
                                  <FieldError
                                    messages={fieldErrors(`endpoints[${i}].llm.intent`)}
                                  />
                                </div>

                                <div>
                                  <label
                                    htmlFor={`endpoint-llm-side-effects-${i}`}
                                    className={LABEL_CLASS}
                                  >
                                    Effets de bord <span className="text-error-500">*</span>
                                  </label>
                                  <select
                                    id={`endpoint-llm-side-effects-${i}`}
                                    data-testid={`endpoint-llm-side-effects-${i}`}
                                    value={ep.llm.side_effects}
                                    onChange={(e) =>
                                      setEndpointLlm(i, {
                                        side_effects: e.target.value as UacSideEffects,
                                      })
                                    }
                                    className={fieldClass(
                                      Boolean(fieldErrors(`endpoints[${i}].llm.side_effects`))
                                    )}
                                  >
                                    {SIDE_EFFECTS.map((s) => (
                                      <option key={s.value} value={s.value}>
                                        {s.label}
                                      </option>
                                    ))}
                                  </select>
                                  <FieldError
                                    messages={fieldErrors(`endpoints[${i}].llm.side_effects`)}
                                  />
                                  {ep.llm.side_effects === 'destructive' && (
                                    <p className="mt-1.5 flex items-start gap-1.5 text-xs text-warning-600 dark:text-warning-400">
                                      <AlertTriangle className="mt-px h-3.5 w-3.5 flex-shrink-0" />
                                      Effet destructif — la politique de gouvernance exige
                                      l’approbation humaine.
                                    </p>
                                  )}
                                </div>

                                <div className="space-y-4">
                                  <Switch
                                    checked={ep.llm.safe_for_agents}
                                    onChange={(v) => setEndpointLlm(i, { safe_for_agents: v })}
                                    label="Sûr pour les agents"
                                    description="Les agents autonomes peuvent invoquer cet outil."
                                    testId={`endpoint-llm-safe-${i}`}
                                  />
                                  <div>
                                    <Switch
                                      checked={ep.llm.requires_human_approval}
                                      onChange={(v) =>
                                        setEndpointLlm(i, { requires_human_approval: v })
                                      }
                                      label="Approbation humaine requise"
                                      description="Un humain valide chaque invocation avant exécution."
                                      testId={`endpoint-llm-approval-${i}`}
                                    />
                                    {/* Règle sémantique §5 — erreur bloquante ancrée ici. */}
                                    <FieldError
                                      testId="editor-error-destructive"
                                      messages={fieldErrors(
                                        `endpoints[${i}].llm.requires_human_approval`
                                      )}
                                    />
                                    {ep.llm.side_effects === 'destructive' &&
                                      ep.llm.requires_human_approval && (
                                        <p
                                          data-testid="editor-destructive-ok"
                                          className="mt-1.5 flex items-start gap-1.5 text-xs text-success-600 dark:text-success-400"
                                        >
                                          <CheckCircle2 className="mt-px h-3.5 w-3.5 flex-shrink-0" />
                                          Approbation humaine activée — conforme à la politique.
                                        </p>
                                      )}
                                  </div>
                                </div>
                              </div>
                            </div>
                          )}
                        </div>

                        {/* Suppression de l'endpoint */}
                        <div className="flex justify-end border-t border-neutral-200 pt-3 dark:border-neutral-700">
                          <Button
                            variant="ghost"
                            size="sm"
                            data-testid={`endpoint-remove-${i}`}
                            icon={<Trash2 className="h-4 w-4" />}
                            className="text-error-600 hover:bg-error-50 dark:text-error-400 dark:hover:bg-error-900/20"
                            onClick={() => removeEndpoint(i)}
                          >
                            Supprimer l’endpoint
                          </Button>
                        </div>
                      </div>
                    </Collapsible>
                  );
                })}
              </div>
            )}
          </section>
        </fieldset>

        {/* ================= Colonne validation ================= */}
        <aside className="min-w-0">
          <section
            data-testid="editor-errors"
            className="rounded-card border border-neutral-200 bg-white p-6 dark:border-neutral-700 dark:bg-neutral-800 xl:sticky xl:top-28"
          >
            <h2 className="text-base font-semibold text-neutral-900 dark:text-neutral-100">
              Validation
            </h2>

            {schemaQuery.isError && (
              <p className="mt-3 flex items-start gap-2 text-xs text-warning-600 dark:text-warning-400">
                <AlertTriangle className="mt-px h-3.5 w-3.5 flex-shrink-0" />
                Schéma UAC indisponible — validation locale partielle (le serveur
                revalidera avant tout commit).
              </p>
            )}

            {errors.length === 0 && !needsEndpointForPublish ? (
              <div
                data-testid="editor-valid"
                className="mt-3 flex items-start gap-2 text-sm text-success-600 dark:text-success-400"
              >
                <CheckCircle2 className="mt-0.5 h-4 w-4 flex-shrink-0" />
                <span>Contrat valide — prêt à être publié en dev.</span>
              </div>
            ) : (
              <>
                <p className="mt-3 text-sm font-medium text-error-600 dark:text-error-400">
                  {errors.length + (needsEndpointForPublish ? 1 : 0)} erreur
                  {errors.length + (needsEndpointForPublish ? 1 : 0) > 1 ? 's' : ''} à corriger
                  avant publication
                </p>
                <ul className="mt-3 space-y-2.5">
                  {needsEndpointForPublish && (
                    <li className="flex items-start gap-2 text-xs">
                      <AlertCircle className="mt-px h-3.5 w-3.5 flex-shrink-0 text-error-500" />
                      <span className="text-neutral-600 dark:text-neutral-300">
                        La publication exige au moins un endpoint (ou une configuration LLM).
                      </span>
                    </li>
                  )}
                  {errors.map((e, idx) => (
                    <li
                      key={`${e.path}-${idx}`}
                      data-testid="editor-error-row"
                      className="flex items-start gap-2 text-xs"
                    >
                      <AlertCircle className="mt-px h-3.5 w-3.5 flex-shrink-0 text-error-500" />
                      <span className="min-w-0">
                        <code className="break-all font-mono text-[11px] text-neutral-500 dark:text-neutral-400">
                          {e.path || 'contrat'}
                        </code>
                        <span className="block text-neutral-700 dark:text-neutral-200">
                          {e.message}
                        </span>
                      </span>
                    </li>
                  ))}
                </ul>
              </>
            )}

            {/* Contexte Git (dernier commit connu du contrat) */}
            {contractQuery.data && contractQuery.data.versions.length > 0 && (
              <div className="mt-5 border-t border-neutral-200 pt-4 dark:border-neutral-700">
                <p className="text-xs font-medium uppercase tracking-wider text-neutral-500 dark:text-neutral-400">
                  Repo de gouvernance
                </p>
                <p className="mt-2 flex items-center gap-1.5 text-xs text-neutral-600 dark:text-neutral-300">
                  <GitCommit className="h-3.5 w-3.5 flex-shrink-0 text-neutral-400" />
                  <code className="font-mono">{contractQuery.data.versions[0].sha7}</code>
                  <span className="truncate">par {contractQuery.data.versions[0].author}</span>
                  {contractQuery.data.versions[0].signed && (
                    <ShieldCheck
                      className="h-3.5 w-3.5 flex-shrink-0 text-success-500"
                      aria-label="Commit signé"
                    />
                  )}
                </p>
              </div>
            )}

            <p className="mt-4 text-[11px] leading-snug text-neutral-400 dark:text-neutral-500">
              La validation est ré-exécutée côté serveur avant chaque commit — l’interface ne
              fait pas autorité (API-CONTRACT §5).
            </p>
          </section>
        </aside>
      </div>

      {/* Confirmation de publication (message obligatoire) */}
      <PublishDialog
        open={publishOpen}
        loading={publishMutation.isPending}
        contractLabel={form.display_name || form.name}
        version={form.version}
        hasUnsavedChanges={dirty}
        onConfirm={(message) => publishMutation.mutate(message)}
        onCancel={() => {
          if (!publishMutation.isPending) setPublishOpen(false);
        }}
      />
    </div>
  );
}
