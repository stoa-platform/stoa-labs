import { ReactNode } from 'react';
import { Plus, Search, FileText, Server, Layers, Wrench, Rocket, Users, Package, WifiOff } from 'lucide-react';

// Vendorisé depuis @stoa/shared/components/EmptyState (libellés français,
// messages adaptés au domaine gouvernance).

// ============================================================================
// Types
// ============================================================================

export type EmptyStateVariant =
  | 'default'
  | 'search'
  | 'apis'
  | 'tools'
  | 'servers'
  | 'deployments'
  | 'users'
  | 'subscriptions'
  | 'service-unavailable';

export interface EmptyStateProps {
  /** Variant determines the illustration and default messaging */
  variant?: EmptyStateVariant;
  /** Custom title (overrides variant default) */
  title?: string;
  /** Custom description (overrides variant default) */
  description?: string;
  /** Custom illustration (overrides variant default) */
  illustration?: ReactNode;
  /** Primary action button */
  action?: {
    label: string;
    onClick: () => void;
    icon?: ReactNode;
  };
  /** Secondary action link */
  secondaryAction?: {
    label: string;
    onClick: () => void;
  };
  /** Additional class for styling */
  className?: string;
  /** Compact mode for inline use */
  compact?: boolean;
}

// ============================================================================
// Illustrations (SVG-based for crisp rendering)
// ============================================================================

function DefaultIllustration() {
  return (
    <div className="relative">
      <div className="w-24 h-24 rounded-2xl bg-gradient-to-br from-neutral-100 to-neutral-200 dark:from-neutral-800 dark:to-neutral-700 flex items-center justify-center">
        <FileText className="w-10 h-10 text-neutral-400" />
      </div>
      <div className="absolute -bottom-1 -right-1 w-8 h-8 rounded-lg bg-primary-100 dark:bg-primary-900 flex items-center justify-center">
        <Plus className="w-4 h-4 text-primary-600 dark:text-primary-400" />
      </div>
    </div>
  );
}

function SearchIllustration() {
  return (
    <div className="relative">
      <div className="w-24 h-24 rounded-full bg-gradient-to-br from-neutral-100 to-neutral-200 dark:from-neutral-800 dark:to-neutral-700 flex items-center justify-center">
        <Search className="w-10 h-10 text-neutral-400" />
      </div>
      <div className="absolute top-0 right-0 w-6 h-6 rounded-full bg-warning-100 dark:bg-warning-900 flex items-center justify-center">
        <span className="text-warning-600 dark:text-warning-400 text-xs font-bold">?</span>
      </div>
    </div>
  );
}

function APIsIllustration() {
  return (
    <div className="relative">
      <div className="w-24 h-24 rounded-2xl bg-gradient-to-br from-primary-50 to-primary-100 dark:from-primary-950 dark:to-primary-900 flex items-center justify-center">
        <Layers className="w-10 h-10 text-primary-500" />
      </div>
      <div className="absolute -bottom-2 -right-2 flex -space-x-1">
        <div className="w-6 h-6 rounded-full bg-success-100 border-2 border-white dark:border-neutral-900" />
        <div className="w-6 h-6 rounded-full bg-primary-100 border-2 border-white dark:border-neutral-900" />
        <div className="w-6 h-6 rounded-full bg-accent-100 border-2 border-white dark:border-neutral-900" />
      </div>
    </div>
  );
}

function ToolsIllustration() {
  return (
    <div className="relative">
      <div className="w-24 h-24 rounded-2xl bg-gradient-to-br from-warning-50 to-warning-100 dark:from-warning-900 dark:to-warning-800 flex items-center justify-center">
        <Wrench className="w-10 h-10 text-warning-500" />
      </div>
    </div>
  );
}

function ServersIllustration() {
  return (
    <div className="relative">
      <div className="w-24 h-24 rounded-2xl bg-gradient-to-br from-accent-50 to-accent-100 dark:from-accent-950 dark:to-accent-900 flex items-center justify-center">
        <Server className="w-10 h-10 text-accent-500" />
      </div>
      <div className="absolute bottom-2 left-2 w-3 h-3 rounded-full bg-neutral-300 animate-pulse" />
      <div className="absolute bottom-2 left-7 w-3 h-3 rounded-full bg-neutral-300 animate-pulse" style={{ animationDelay: '0.2s' }} />
      <div className="absolute bottom-2 left-12 w-3 h-3 rounded-full bg-neutral-300 animate-pulse" style={{ animationDelay: '0.4s' }} />
    </div>
  );
}

function DeploymentsIllustration() {
  return (
    <div className="relative">
      <div className="w-24 h-24 rounded-2xl bg-gradient-to-br from-success-50 to-success-100 dark:from-success-900 dark:to-success-800 flex items-center justify-center">
        <Rocket className="w-10 h-10 text-success-500 transform -rotate-45" />
      </div>
    </div>
  );
}

function UsersIllustration() {
  return (
    <div className="relative">
      <div className="w-24 h-24 rounded-2xl bg-gradient-to-br from-purple-50 to-purple-100 dark:from-purple-950 dark:to-purple-900 flex items-center justify-center">
        <Users className="w-10 h-10 text-purple-500" />
      </div>
    </div>
  );
}

function ServiceUnavailableIllustration() {
  return (
    <div className="relative">
      <div className="w-24 h-24 rounded-2xl bg-gradient-to-br from-red-50 to-red-100 dark:from-red-900/30 dark:to-red-800/30 flex items-center justify-center">
        <WifiOff className="w-10 h-10 text-red-500" />
      </div>
      <div className="absolute -bottom-1 -right-1 w-8 h-8 rounded-lg bg-red-100 dark:bg-red-900 flex items-center justify-center">
        <span className="text-red-600 dark:text-red-400 text-xs font-bold">!</span>
      </div>
    </div>
  );
}

function SubscriptionsIllustration() {
  return (
    <div className="relative">
      <div className="w-24 h-24 rounded-2xl bg-gradient-to-br from-primary-50 to-accent-50 dark:from-primary-950 dark:to-accent-950 flex items-center justify-center">
        <Package className="w-10 h-10 text-primary-500" />
      </div>
      <div className="absolute -bottom-1 -right-1 w-8 h-8 rounded-lg bg-success-500 flex items-center justify-center text-white text-xs font-bold">
        +
      </div>
    </div>
  );
}

// ============================================================================
// Variant Configurations
// ============================================================================

const variantConfig: Record<EmptyStateVariant, {
  illustration: ReactNode;
  title: string;
  description: string;
}> = {
  default: {
    illustration: <DefaultIllustration />,
    title: 'Rien ici pour le moment',
    description: 'Commencez par créer votre premier élément.',
  },
  search: {
    illustration: <SearchIllustration />,
    title: 'Aucun résultat',
    description: 'Ajustez votre recherche ou vos filtres pour trouver ce que vous cherchez.',
  },
  apis: {
    illustration: <APIsIllustration />,
    title: 'Aucun contrat',
    description: 'Créez votre premier contrat UAC pour démarrer la gouvernance.',
  },
  tools: {
    illustration: <ToolsIllustration />,
    title: 'Aucun outil disponible',
    description: 'Parcourez le catalogue pour découvrir les outils disponibles.',
  },
  servers: {
    illustration: <ServersIllustration />,
    title: 'Aucune cible enregistrée',
    description: 'Enregistrez une première gateway pour démarrer la fédération.',
  },
  deployments: {
    illustration: <DeploymentsIllustration />,
    title: 'Aucun déploiement',
    description: 'Publiez un contrat pour le voir apparaître ici.',
  },
  users: {
    illustration: <UsersIllustration />,
    title: 'Aucun utilisateur',
    description: 'Les utilisateurs apparaîtront ici après leur création dans l’IdP.',
  },
  subscriptions: {
    illustration: <SubscriptionsIllustration />,
    title: 'Aucune souscription',
    description: 'Les demandes de souscription apparaîtront ici.',
  },
  'service-unavailable': {
    illustration: <ServiceUnavailableIllustration />,
    title: 'Service indisponible',
    description: 'L’API de gouvernance est injoignable. Réessayez dans un instant.',
  },
};

// ============================================================================
// Component
// ============================================================================

export function EmptyState({
  variant = 'default',
  title,
  description,
  illustration,
  action,
  secondaryAction,
  className = '',
  compact = false,
}: EmptyStateProps) {
  const config = variantConfig[variant];

  return (
    <div
      className={`flex flex-col items-center justify-center text-center ${
        compact ? 'py-8' : 'py-16'
      } ${className}`}
    >
      {/* Illustration */}
      <div className={compact ? 'mb-4' : 'mb-6'}>
        {illustration || config.illustration}
      </div>

      {/* Title */}
      <h3
        className={`font-semibold text-neutral-900 dark:text-neutral-100 ${
          compact ? 'text-base' : 'text-lg'
        }`}
      >
        {title || config.title}
      </h3>

      {/* Description */}
      <p
        className={`text-neutral-500 dark:text-neutral-400 max-w-sm ${
          compact ? 'text-sm mt-1' : 'mt-2'
        }`}
      >
        {description || config.description}
      </p>

      {/* Actions */}
      {(action || secondaryAction) && (
        <div className={`flex flex-col sm:flex-row items-center gap-3 ${compact ? 'mt-4' : 'mt-6'}`}>
          {action && (
            <button
              onClick={action.onClick}
              className="inline-flex items-center gap-2 px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 dark:bg-primary-500 dark:hover:bg-primary-600 transition-colors"
            >
              {action.icon || <Plus className="w-4 h-4" />}
              {action.label}
            </button>
          )}
          {secondaryAction && (
            <button
              onClick={secondaryAction.onClick}
              className="text-sm text-primary-600 hover:text-primary-700 dark:text-primary-400 dark:hover:text-primary-300 font-medium"
            >
              {secondaryAction.label}
            </button>
          )}
        </div>
      )}
    </div>
  );
}

export default EmptyState;
