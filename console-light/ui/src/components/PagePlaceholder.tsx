import { Construction } from 'lucide-react';

/**
 * Placeholder d'écran — les agents « écrans » remplaceront chaque page
 * src/pages/*.tsx par l'implémentation réelle SANS toucher au socle.
 */

interface PagePlaceholderProps {
  /** Titre français de l'écran (CADRAGE §4). */
  title: string;
  /** Sous-titre décrivant ce que l'écran livrera. */
  description?: string;
  /** data-testid de la page (convention page-{name}). */
  testId: string;
}

export function PagePlaceholder({ title, description, testId }: PagePlaceholderProps) {
  return (
    <div data-testid={testId} className="space-y-6 animate-fade-in">
      <div>
        <h1 className="text-2xl font-bold text-neutral-900 dark:text-white">{title}</h1>
        {description && (
          <p className="mt-1 text-sm text-neutral-500 dark:text-neutral-400">{description}</p>
        )}
      </div>

      <div className="flex flex-col items-center justify-center rounded-card border border-dashed border-neutral-300 dark:border-neutral-700 bg-white dark:bg-neutral-900 py-20 text-center">
        <div className="mb-4 rounded-2xl bg-primary-50 dark:bg-primary-950/40 p-4">
          <Construction className="h-8 w-8 text-primary-600 dark:text-primary-400" />
        </div>
        <h2 className="text-lg font-semibold text-neutral-900 dark:text-neutral-100">
          Écran en construction
        </h2>
        <p className="mt-2 max-w-md text-sm text-neutral-500 dark:text-neutral-400">
          Cet écran sera livré par un agent dédié. Le socle — authentification OIDC,
          RBAC, navigation, services d’API typés — est déjà opérationnel.
        </p>
      </div>
    </div>
  );
}
