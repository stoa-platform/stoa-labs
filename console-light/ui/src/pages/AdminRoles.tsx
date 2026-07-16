import { useQuery } from '@tanstack/react-query';
import { Check, Shield, ShieldOff, Users } from 'lucide-react';
import { apiService } from '../services/api';
import { useAuth } from '../contexts/AuthContext';
import { CardSkeleton } from '../vendor/stoa-shared/components/Skeleton';
import { getFriendlyErrorMessage } from '../vendor/stoa-shared/utils/errorMessages';

/**
 * Écran 2 (CADRAGE §4) — Rôles & permissions, lecture seule, cpi-admin only.
 * Porté de la carrière (control-plane-ui/src/pages/AdminRoles.tsx) : cards
 * colorées par rôle. Branché sur apiService.getRoles() (contrat §4) — les
 * définitions statiques §2 + comptes Keycloak viennent du BFF.
 */

interface RoleColors {
  bg: string;
  text: string;
  border: string;
}

const ROLE_COLORS: Record<string, RoleColors> = {
  'cpi-admin': {
    bg: 'bg-red-50 dark:bg-red-900/20',
    text: 'text-red-800 dark:text-red-400',
    border: 'border-red-200 dark:border-red-800',
  },
  'tenant-admin': {
    bg: 'bg-blue-50 dark:bg-blue-900/20',
    text: 'text-blue-800 dark:text-blue-400',
    border: 'border-blue-200 dark:border-blue-800',
  },
  devops: {
    bg: 'bg-purple-50 dark:bg-purple-900/20',
    text: 'text-purple-800 dark:text-purple-400',
    border: 'border-purple-200 dark:border-purple-800',
  },
  viewer: {
    bg: 'bg-neutral-50 dark:bg-neutral-800',
    text: 'text-neutral-800 dark:text-neutral-300',
    border: 'border-neutral-200 dark:border-neutral-700',
  },
};

const DEFAULT_ROLE_COLORS: RoleColors = {
  bg: 'bg-neutral-50 dark:bg-neutral-800',
  text: 'text-neutral-800 dark:text-neutral-300',
  border: 'border-neutral-200 dark:border-neutral-700',
};

/** Libellés français des rôles realm (le nom technique reste affiché en mono). */
const ROLE_LABELS: Record<string, string> = {
  'cpi-admin': 'Administrateur plateforme',
  'tenant-admin': 'Administrateur de tenant',
  devops: 'DevOps',
  viewer: 'Lecteur',
};

/** Traduction française des permissions resource:verb du contrat (§2). */
const PERMISSION_LABELS: Record<string, string> = {
  'apis:read': 'Consulter les contrats',
  'apis:update': 'Modifier les contrats',
  'apis:publish': 'Publier en dev',
  'promotions:read': 'Consulter les promotions',
  'promotions:request': 'Demander une promotion',
  'promotions:approve': 'Approuver ou rejeter une promotion',
  'subscriptions:read': 'Consulter les souscriptions',
  'subscriptions:approve': 'Approuver ou rejeter une souscription',
  'audit:read': 'Consulter le journal d’audit',
  'audit:export': 'Exporter le journal d’audit',
  'tenants:read': 'Consulter les tenants',
  'targets:read': 'Consulter les cibles de fédération',
  'users:read': 'Consulter les utilisateurs',
  'users:manage': 'Gérer les rôles des utilisateurs',
};

function AccessDenied() {
  return (
    <div data-testid="page-admin-roles" className="animate-fade-in">
      <div
        className="flex flex-col items-center justify-center rounded-lg border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-800 py-20 text-center"
        data-testid="admin-roles-access-denied"
      >
        <div className="mb-4 rounded-2xl bg-red-50 dark:bg-red-900/20 p-4">
          <ShieldOff className="h-8 w-8 text-red-500" />
        </div>
        <h1 className="text-xl font-semibold text-neutral-900 dark:text-white">Accès refusé</h1>
        <p className="mt-2 max-w-md text-sm text-neutral-500 dark:text-neutral-400">
          Cette page est réservée au rôle <span className="font-mono">cpi-admin</span>.
          Le contrôle d’accès fait foi côté serveur — chaque refus est audité.
        </p>
      </div>
    </div>
  );
}

export default function AdminRoles() {
  const { isReady, hasRole } = useAuth();
  const isCpiAdmin = hasRole('cpi-admin');

  const {
    data: roles = [],
    isLoading,
    error,
  } = useQuery({
    queryKey: ['roles'],
    queryFn: () => apiService.getRoles(),
    enabled: isReady && isCpiAdmin,
  });

  if (!isCpiAdmin) {
    return <AccessDenied />;
  }

  return (
    <div data-testid="page-admin-roles" className="space-y-6 animate-fade-in">
      {/* En-tête */}
      <div>
        <h1 className="text-2xl font-bold text-neutral-900 dark:text-white">
          Rôles &amp; permissions
        </h1>
        <p className="text-neutral-500 dark:text-neutral-400 mt-1">
          La matrice rôle → permissions du contrat de gouvernance, appliquée côté serveur —
          la console ne fait que masquer.
        </p>
      </div>

      {/* Erreur de chargement */}
      {error != null && (
        <div
          className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 text-red-700 dark:text-red-400 px-4 py-3 rounded-lg"
          role="alert"
        >
          {getFriendlyErrorMessage(error, 'Impossible de charger les rôles.')}
        </div>
      )}

      {/* Chargement */}
      {isLoading ? (
        <div className="grid gap-6 md:grid-cols-2">
          {[1, 2, 3, 4].map((i) => (
            <CardSkeleton key={i} />
          ))}
        </div>
      ) : !error && roles.length === 0 ? (
        <div className="flex flex-col items-center justify-center rounded-lg bg-white dark:bg-neutral-800 p-12 text-neutral-500 dark:text-neutral-400">
          <Shield className="h-10 w-10 mb-3 opacity-50" />
          <p className="text-sm">Aucun rôle configuré.</p>
        </div>
      ) : (
        <div className="grid gap-6 md:grid-cols-2" data-testid="roles-grid">
          {roles.map((role) => {
            const colors = ROLE_COLORS[role.name] ?? DEFAULT_ROLE_COLORS;
            return (
              <div
                key={role.name}
                className={`rounded-lg border ${colors.border} ${colors.bg} p-5`}
                data-testid={`role-card-${role.name}`}
              >
                <div className="flex items-start justify-between mb-3 gap-3">
                  <div className="min-w-0">
                    <h3 className={`text-lg font-semibold ${colors.text}`}>
                      {ROLE_LABELS[role.name] ?? role.name}
                    </h3>
                    <p className="text-xs font-mono text-neutral-500 dark:text-neutral-400 mt-0.5">
                      {role.name}
                    </p>
                    {role.description && (
                      <p className="text-sm text-neutral-600 dark:text-neutral-400 mt-1.5">
                        {role.description}
                      </p>
                    )}
                  </div>
                  <div
                    className="flex items-center gap-1.5 text-sm text-neutral-500 dark:text-neutral-400 flex-shrink-0"
                    data-testid={`role-user-count-${role.name}`}
                  >
                    <Users className="h-4 w-4" />
                    <span>
                      {role.user_count} utilisateur{role.user_count !== 1 ? 's' : ''}
                    </span>
                  </div>
                </div>

                <div className="space-y-1.5">
                  <p className="text-xs font-medium text-neutral-500 dark:text-neutral-400 uppercase tracking-wider">
                    Permissions
                  </p>
                  <ul className="grid gap-1">
                    {role.permissions.map((permission) => (
                      <li key={permission} className="flex items-start gap-2">
                        <Check className="h-3.5 w-3.5 text-green-500 mt-0.5 flex-shrink-0" />
                        <div className="min-w-0">
                          <span className="text-sm text-neutral-900 dark:text-white">
                            {PERMISSION_LABELS[permission] ?? permission}
                          </span>
                          <span className="text-xs font-mono text-neutral-500 dark:text-neutral-400 ml-2">
                            {permission}
                          </span>
                        </div>
                      </li>
                    ))}
                  </ul>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
