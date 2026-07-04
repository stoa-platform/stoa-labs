/**
 * Carte rôle → permissions, miroir EXACT du §2 d'API-CONTRACT.md.
 * Le RBAC est appliqué CÔTÉ BFF — l'UI ne fait que masquer (boutons absents,
 * pas grisés). Aucune permission calculée ici ne fait autorité.
 */

export const ROLE_PERMISSIONS: Record<string, string[]> = {
  'cpi-admin': [
    'apis:read',
    'apis:update',
    'apis:publish',
    'promotions:read',
    'promotions:request',
    'promotions:approve',
    'subscriptions:read',
    'subscriptions:approve',
    'audit:read',
    'audit:export',
    'tenants:read',
    'targets:read',
    'users:read',
    'users:manage',
  ],
  'tenant-admin': [
    'apis:read',
    'apis:update',
    'apis:publish',
    'promotions:read',
    'promotions:request',
    'subscriptions:read',
    'subscriptions:approve',
    'audit:read',
    'audit:export',
    'tenants:read',
    'targets:read',
  ],
  devops: [
    'apis:read',
    'promotions:read',
    'promotions:approve',
    'subscriptions:read',
    'audit:read',
    'tenants:read',
    'targets:read',
  ],
  viewer: [
    'apis:read',
    'promotions:read',
    'subscriptions:read',
    'audit:read',
    'tenants:read',
    'targets:read',
  ],
};

/** Agrège les permissions d'un ensemble de rôles realm (déduplication). */
export function computePermissions(roles: string[]): string[] {
  const permissions = new Set<string>();
  for (const role of roles) {
    for (const permission of ROLE_PERMISSIONS[role] ?? []) {
      permissions.add(permission);
    }
  }
  return Array.from(permissions);
}
