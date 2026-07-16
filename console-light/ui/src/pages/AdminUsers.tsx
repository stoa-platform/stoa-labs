import { useMemo, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Cloud, ShieldAlert, ShieldCheck, UserCog, X } from 'lucide-react';

import { apiService } from '../services/api';
import { useAuth } from '../contexts/AuthContext';
import { Button } from '../vendor/stoa-shared/components/Button';
import { useToastActions } from '../vendor/stoa-shared/components/Toast';
import { ConfirmDialog } from '../vendor/stoa-shared/components/ConfirmDialog';
import { EmptyState } from '../vendor/stoa-shared/components/EmptyState';
import { TableSkeleton } from '../vendor/stoa-shared/components/Skeleton';
import { getFriendlyErrorMessage } from '../vendor/stoa-shared/utils/errorMessages';
import type { Role, User } from '../types';

/**
 * Écran 9 (CADRAGE §4) — Utilisateurs (cpi-admin uniquement).
 * Porté de la carrière (control-plane-ui/src/pages/AdminUsers.tsx), adapté :
 * les comptes viennent de Keycloak (fédérés par le broker Oracle/Dex), et
 * l'assignation des rôles realm passe par PUT /users/{id}/roles — chaque
 * changement produit un commit d'audit `role-change` (API-CONTRACT §4).
 */

// =============================================================================
// CONSTANTES & HELPERS
// =============================================================================

/** Les 4 rôles realm du contrat (§2) — ordre d'affichage canonique. */
const REALM_ROLES = ['cpi-admin', 'tenant-admin', 'devops', 'viewer'] as const;

const ROLE_BADGE: Record<string, string> = {
  'cpi-admin': 'bg-purple-100 text-purple-800 dark:bg-purple-900/30 dark:text-purple-400',
  'tenant-admin': 'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-400',
  devops: 'bg-emerald-100 text-emerald-800 dark:bg-emerald-900/30 dark:text-emerald-400',
  viewer: 'bg-neutral-100 text-neutral-700 dark:bg-neutral-700/50 dark:text-neutral-300',
};

function roleBadgeClass(role: string): string {
  return ROLE_BADGE[role] ?? 'bg-neutral-100 text-neutral-700 dark:bg-neutral-700/50 dark:text-neutral-300';
}

/** Ne garde que les rôles realm du contrat (filtre les rôles techniques KC). */
function realmRolesOf(user: User): string[] {
  return REALM_ROLES.filter((role) => user.roles.includes(role));
}

// =============================================================================
// MODAL D'ÉDITION DES RÔLES
// =============================================================================

interface EditRolesModalProps {
  user: User;
  roles: Role[];
  loading: boolean;
  onCancel: () => void;
  onSubmit: (roles: string[]) => void;
}

function EditRolesModal({ user, roles, loading, onCancel, onSubmit }: EditRolesModalProps) {
  const [selected, setSelected] = useState<string[]>(() => realmRolesOf(user));

  const roleByName = useMemo(() => {
    const map = new Map<string, Role>();
    for (const role of roles) map.set(role.name, role);
    return map;
  }, [roles]);

  const toggle = (role: string) => {
    setSelected((current) =>
      current.includes(role) ? current.filter((r) => r !== role) : [...current, role]
    );
  };

  const initial = realmRolesOf(user);
  const changed =
    selected.length !== initial.length || selected.some((role) => !initial.includes(role));

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      role="dialog"
      aria-modal="true"
      aria-label="Modifier les rôles"
    >
      <div
        className="bg-white dark:bg-neutral-800 rounded-lg shadow-xl w-full max-w-lg"
        data-testid="user-roles-dialog"
      >
        <div className="flex items-center justify-between border-b border-neutral-200 dark:border-neutral-700 px-6 py-4">
          <div>
            <h2 className="text-lg font-semibold text-neutral-900 dark:text-white">
              Rôles de {user.username}
            </h2>
            <p className="text-xs text-neutral-500 dark:text-neutral-400 mt-0.5">{user.email}</p>
          </div>
          <button
            onClick={onCancel}
            className="text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300"
            aria-label="Fermer"
          >
            <X className="h-5 w-5" />
          </button>
        </div>

        <div className="p-6 space-y-3">
          <p className="text-sm text-neutral-500 dark:text-neutral-400">
            Sélectionnez les rôles realm à assigner. Le RBAC est appliqué côté serveur — chaque
            changement est commité dans la piste d&rsquo;audit (<code>role-change</code>).
          </p>
          <div className="border border-neutral-200 dark:border-neutral-700 rounded-lg divide-y divide-neutral-200 dark:divide-neutral-700 overflow-hidden">
            {REALM_ROLES.map((roleName) => {
              const def = roleByName.get(roleName);
              return (
                <label
                  key={roleName}
                  className="flex items-start gap-3 px-4 py-3 text-sm hover:bg-neutral-50 dark:hover:bg-neutral-700/50 cursor-pointer"
                >
                  <input
                    type="checkbox"
                    checked={selected.includes(roleName)}
                    onChange={() => toggle(roleName)}
                    disabled={loading}
                    className="mt-0.5 h-4 w-4 rounded border-neutral-300 dark:border-neutral-600 text-primary-600 focus:ring-primary-500"
                    data-testid={`user-role-${roleName}`}
                  />
                  <span className="min-w-0 flex-1">
                    <span
                      className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-medium ${roleBadgeClass(roleName)}`}
                    >
                      {roleName}
                    </span>
                    {def?.description && (
                      <span className="block text-xs text-neutral-500 dark:text-neutral-400 mt-1">
                        {def.description}
                      </span>
                    )}
                  </span>
                </label>
              );
            })}
          </div>
        </div>

        <div className="flex justify-end gap-3 px-6 pb-6">
          <Button variant="secondary" onClick={onCancel} disabled={loading}>
            Annuler
          </Button>
          <Button
            onClick={() => onSubmit(selected)}
            disabled={!changed || loading}
            loading={loading}
            icon={<ShieldCheck className="h-4 w-4" />}
            data-testid="user-roles-save"
          >
            Enregistrer
          </Button>
        </div>
      </div>
    </div>
  );
}

// =============================================================================
// PAGE
// =============================================================================

export default function AdminUsers() {
  const { hasPermission } = useAuth();
  const toast = useToastActions();
  const queryClient = useQueryClient();

  const canRead = hasPermission('users:read');
  const canManage = hasPermission('users:manage');

  // ---------------------------------------------------------------------------
  // Données : comptes Keycloak + définitions de rôles (§2)
  // ---------------------------------------------------------------------------
  const usersQuery = useQuery({
    queryKey: ['users'],
    queryFn: () => apiService.getUsers(),
    enabled: canRead,
  });
  const rolesQuery = useQuery({
    queryKey: ['roles'],
    queryFn: () => apiService.getRoles(),
    enabled: canRead,
    staleTime: 5 * 60 * 1000,
  });

  const users = usersQuery.data ?? [];
  const roles = rolesQuery.data ?? [];

  // ---------------------------------------------------------------------------
  // Édition des rôles : modal → ConfirmDialog (« Ce changement est audité »)
  // ---------------------------------------------------------------------------
  const [editTarget, setEditTarget] = useState<User | null>(null);
  const [pendingRoles, setPendingRoles] = useState<string[] | null>(null);

  const updateMutation = useMutation({
    mutationFn: ({ id, nextRoles }: { id: string; nextRoles: string[] }) =>
      apiService.updateUserRoles(id, nextRoles),
    onSuccess: ({ user }) => {
      setPendingRoles(null);
      setEditTarget(null);
      toast.success(
        'Rôles mis à jour',
        `${user.username} : ${realmRolesOf(user).join(', ') || 'aucun rôle realm'}. Le changement est audité (commit role-change).`
      );
      void queryClient.invalidateQueries({ queryKey: ['users'] });
      void queryClient.invalidateQueries({ queryKey: ['roles'] });
      void queryClient.invalidateQueries({ queryKey: ['audit'] });
    },
    onError: (err) => {
      setPendingRoles(null);
      toast.error('Échec de la mise à jour des rôles', getFriendlyErrorMessage(err));
    },
  });

  // ---------------------------------------------------------------------------
  // Garde d'accès (la nav masque déjà — ceci couvre l'URL directe)
  // ---------------------------------------------------------------------------
  if (!canRead) {
    return (
      <div className="space-y-6 animate-fade-in" data-testid="page-admin-users">
        <div className="flex flex-col items-center justify-center rounded-lg border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-800 py-20 text-center">
          <ShieldAlert className="h-12 w-12 text-red-500 mb-4" />
          <h1 className="text-xl font-semibold text-neutral-900 dark:text-white mb-2">
            Accès refusé
          </h1>
          <p className="text-sm text-neutral-500 dark:text-neutral-400 max-w-md">
            Le rôle cpi-admin est requis pour consulter les utilisateurs. Tout refus est
            également appliqué et audité côté serveur.
          </p>
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-6 animate-fade-in" data-testid="page-admin-users">
      {/* En-tête */}
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-neutral-900 dark:text-white">Utilisateurs</h1>
          <p className="text-neutral-500 dark:text-neutral-400 mt-1 text-sm">
            Comptes fédérés par l&rsquo;IdP Oracle et rôles realm — chaque changement de rôle est
            commité dans la piste d&rsquo;audit.
          </p>
        </div>
        {usersQuery.isSuccess && (
          <span className="text-sm text-neutral-500 dark:text-neutral-400">
            {users.length} utilisateur{users.length > 1 ? 's' : ''}
          </span>
        )}
      </div>

      {/* Erreur de chargement */}
      {usersQuery.isError && (
        <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 text-red-700 dark:text-red-400 px-4 py-3 rounded-lg text-sm flex items-center justify-between gap-4">
          <span>{getFriendlyErrorMessage(usersQuery.error)}</span>
          <Button
            size="sm"
            variant="secondary"
            onClick={() => void usersQuery.refetch()}
            data-testid="users-retry"
          >
            Réessayer
          </Button>
        </div>
      )}

      {/* Table */}
      {usersQuery.isPending ? (
        <TableSkeleton rows={5} columns={canManage ? 6 : 5} />
      ) : users.length === 0 ? (
        !usersQuery.isError && (
          <EmptyState
            variant="users"
            title="Aucun utilisateur"
            description="Les comptes apparaîtront ici après leur fédération par l'IdP Oracle."
          />
        )
      ) : (
        <div className="bg-white dark:bg-neutral-800 rounded-lg shadow dark:shadow-none border border-neutral-100 dark:border-neutral-700 overflow-hidden">
          <div className="overflow-x-auto">
            <table className="min-w-full divide-y divide-neutral-200 dark:divide-neutral-700">
              <thead className="bg-neutral-50 dark:bg-neutral-900/50">
                <tr>
                  <th className="px-4 py-3 text-left text-xs font-medium text-neutral-500 dark:text-neutral-400 uppercase tracking-wider">
                    Utilisateur
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-neutral-500 dark:text-neutral-400 uppercase tracking-wider">
                    E-mail
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-neutral-500 dark:text-neutral-400 uppercase tracking-wider">
                    Rôles
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-neutral-500 dark:text-neutral-400 uppercase tracking-wider">
                    Tenant
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-neutral-500 dark:text-neutral-400 uppercase tracking-wider">
                    Fédération
                  </th>
                  {canManage && (
                    <th className="px-4 py-3 text-right text-xs font-medium text-neutral-500 dark:text-neutral-400 uppercase tracking-wider">
                      Actions
                    </th>
                  )}
                </tr>
              </thead>
              <tbody className="divide-y divide-neutral-200 dark:divide-neutral-700">
                {users.map((user) => {
                  const userRoles = realmRolesOf(user);
                  return (
                    <tr
                      key={user.id}
                      className="hover:bg-neutral-50 dark:hover:bg-neutral-700/50 transition-colors"
                      data-testid={`user-row-${user.username}`}
                    >
                      <td className="px-4 py-3 text-sm font-medium text-neutral-900 dark:text-white">
                        {user.username}
                      </td>
                      <td className="px-4 py-3 text-sm text-neutral-600 dark:text-neutral-300">
                        {user.email || '—'}
                      </td>
                      <td className="px-4 py-3">
                        <div className="flex flex-wrap gap-1">
                          {userRoles.length === 0 ? (
                            <span className="text-xs text-neutral-400">—</span>
                          ) : (
                            userRoles.map((role) => (
                              <span
                                key={role}
                                className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-medium ${roleBadgeClass(role)}`}
                              >
                                {role}
                              </span>
                            ))
                          )}
                        </div>
                      </td>
                      <td className="px-4 py-3 text-sm text-neutral-600 dark:text-neutral-300">
                        {user.tenant || '—'}
                      </td>
                      <td className="px-4 py-3">
                        {user.federated ? (
                          <span className="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-medium bg-indigo-100 text-indigo-800 dark:bg-indigo-900/30 dark:text-indigo-400">
                            <Cloud className="h-3 w-3" />
                            Fédéré Oracle
                          </span>
                        ) : (
                          <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-neutral-100 text-neutral-600 dark:bg-neutral-700/50 dark:text-neutral-400">
                            Local
                          </span>
                        )}
                      </td>
                      {canManage && (
                        <td className="px-4 py-3 text-right">
                          <Button
                            size="sm"
                            variant="secondary"
                            onClick={() => setEditTarget(user)}
                            disabled={updateMutation.isPending}
                            icon={<UserCog className="h-3.5 w-3.5" />}
                            data-testid={`user-edit-roles-${user.id}`}
                          >
                            Modifier les rôles
                          </Button>
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

      {/* Modal d'édition des rôles (reste monté sous le ConfirmDialog pour
          conserver la sélection si la confirmation est annulée) */}
      {editTarget && (
        <EditRolesModal
          key={editTarget.id}
          user={editTarget}
          roles={roles}
          loading={updateMutation.isPending}
          onCancel={() => setEditTarget(null)}
          onSubmit={(nextRoles) => setPendingRoles(nextRoles)}
        />
      )}

      {/* Confirmation — « Ce changement est audité » */}
      <ConfirmDialog
        open={editTarget !== null && pendingRoles !== null}
        title="Confirmer le changement de rôles"
        message={
          editTarget && pendingRoles
            ? `Assigner à ${editTarget.username} les rôles : ${
                pendingRoles.length > 0 ? pendingRoles.join(', ') : 'aucun'
              }. Ce changement est audité — un commit role-change sera créé dans le dépôt de gouvernance.`
            : ''
        }
        confirmLabel="Confirmer"
        cancelLabel="Annuler"
        variant="warning"
        loading={updateMutation.isPending}
        icon={<ShieldCheck className="h-6 w-6" />}
        onConfirm={() => {
          if (editTarget && pendingRoles) {
            updateMutation.mutate({ id: editTarget.id, nextRoles: pendingRoles });
          }
        }}
        onCancel={() => setPendingRoles(null)}
      />
    </div>
  );
}
