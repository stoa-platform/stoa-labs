/**
 * Helpers de test par persona (CADRAGE §3) — fixtures pures, sans dépendance
 * à un framework de test. À utiliser avec les écrans RBAC-conditionnels :
 * chaque composant gardé par permission doit être vérifié pour les 4 personas.
 */

import { computePermissions } from '../contexts/permissions';
import type { AuthContextType } from '../contexts/AuthContext';
import type { AuthUser } from '../types';

export type PersonaId = 'alice' | 'bob' | 'auditor' | 'admin';

interface PersonaSeed {
  username: string;
  name: string;
  email: string;
  roles: string[];
  tenant: string;
}

const SEEDS: Record<PersonaId, PersonaSeed> = {
  /** Fournisseur d'API — édite/publie SES contrats, SON tenant, dev seulement. */
  alice: {
    username: 'alice',
    name: 'Alice Martin',
    email: 'alice@bc.example',
    roles: ['tenant-admin'],
    tenant: 'banking-demo',
  },
  /** Approbateur — approuve les promotions prod, mais pas les siennes (4-yeux). */
  bob: {
    username: 'bob',
    name: 'Bob Durand',
    email: 'bob@bc.example',
    roles: ['devops'],
    tenant: 'banking-demo',
  },
  /** Auditeur/sécurité — lit tout, n'écrit rien (boutons absents, pas grisés). */
  auditor: {
    username: 'auditor',
    name: 'Aude Iteur',
    email: 'auditor@bc.example',
    roles: ['viewer'],
    tenant: 'banking-demo',
  },
  /** Admin plateforme — tenants, rôles, cibles ; multi-tenant (claim tenant vide). */
  admin: {
    username: 'admin',
    name: 'Admin Plateforme',
    email: 'admin@bc.example',
    roles: ['cpi-admin'],
    tenant: '',
  },
};

/** Construit l'utilisateur authentifié d'une persona (permissions dérivées du §2). */
export function makePersonaUser(persona: PersonaId): AuthUser {
  const seed = SEEDS[persona];
  return {
    id: `test-${seed.username}`,
    username: seed.username,
    name: seed.name,
    email: seed.email,
    roles: [...seed.roles],
    tenant: seed.tenant,
    permissions: computePermissions(seed.roles),
  };
}

/**
 * Mock complet du AuthContext pour une persona (ou non authentifié si null).
 * Exemple vitest :
 *   vi.mock('../contexts/AuthContext', () => ({ useAuth: () => createAuthMock('alice') }))
 */
export function createAuthMock(persona: PersonaId | null): AuthContextType {
  const user = persona ? makePersonaUser(persona) : null;
  return {
    user,
    isAuthenticated: user !== null,
    isLoading: false,
    isReady: user !== null,
    login: () => undefined,
    logout: () => undefined,
    hasPermission: (permission: string) => user?.permissions.includes(permission) ?? false,
    hasRole: (role: string) => user?.roles.includes(role) ?? false,
  };
}

export const ALL_PERSONAS: PersonaId[] = ['alice', 'bob', 'auditor', 'admin'];
