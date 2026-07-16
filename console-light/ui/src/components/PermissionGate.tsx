/**
 * PermissionGate — garde RBAC au niveau widget (vendorisé depuis la carrière).
 *
 * Convention contrat (API-CONTRACT §8) : l'UI MASQUE (boutons absents, pas
 * grisés), le BFF REFUSE. Aucune permission calculée côté UI ne fait autorité.
 *
 * Usage :
 *   <PermissionGate permission="promotions:approve">
 *     <ApproveButton />
 *   </PermissionGate>
 *
 *   <PermissionGate role="cpi-admin" fallback={<AccessDenied />}>
 *     <AdminPanel />
 *   </PermissionGate>
 */

import { type ReactNode } from 'react';
import { useAuth } from '../contexts/AuthContext';

interface PermissionGateProps {
  /** Permission requise (ex: 'promotions:approve') */
  permission?: string;
  /** Rôle requis (ex: 'cpi-admin') */
  role?: string;
  /** Contenu rendu si autorisé */
  children: ReactNode;
  /** Fallback optionnel si non autorisé (défaut : rien) */
  fallback?: ReactNode;
}

export function PermissionGate({
  permission,
  role,
  children,
  fallback = null,
}: PermissionGateProps) {
  const { hasPermission, hasRole } = useAuth();

  const isAuthorized =
    (permission ? hasPermission(permission) : true) && (role ? hasRole(role) : true);

  if (!isAuthorized) {
    return <>{fallback}</>;
  }

  return <>{children}</>;
}
