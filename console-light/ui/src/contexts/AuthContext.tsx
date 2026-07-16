import {
  createContext,
  useContext,
  useEffect,
  useCallback,
  useMemo,
  useRef,
  ReactNode,
} from 'react';
import { useAuth as useOidcAuth } from 'react-oidc-context';
import type { User as OidcUser } from 'oidc-client-ts';
import type { AuthUser } from '../types';
import { setTokenGetter } from '../services/api/httpClient';
import { computePermissions } from './permissions';
import { decodeJwtPayload } from './auth-helpers';

/**
 * AuthContext — adapté de la carrière (control-plane-ui/src/contexts/AuthContext.tsx).
 *
 * Différences assumées (API-CONTRACT.md §1 & §2) :
 * - login passe `kc_idp_hint=oracle` (broker Dex) via extraQueryParams ;
 * - la carte des permissions est le miroir exact du §2 du contrat
 *   (contexts/permissions.ts), PAS l'ancienne carte cp-api ;
 * - plus de getMe() ni de prefetch tenants : le BFF est l'autorité, l'UI
 *   masque seulement ;
 * - le claim tenant s'appelle `tenant` (attribut user mappé), plus `tenant_id`.
 */

export interface AuthContextType {
  user: AuthUser | null;
  isAuthenticated: boolean;
  isLoading: boolean;
  /** Jeton présent et utilisateur extrait — prêt pour les appels /api. */
  isReady: boolean;
  /** Redirige vers Keycloak (broker oracle via kc_idp_hint). */
  login: () => void;
  logout: () => void;
  hasPermission: (permission: string) => boolean;
  hasRole: (role: string) => boolean;
}

const AuthContext = createContext<AuthContextType | undefined>(undefined);

function extractUserFromToken(oidcUser: OidcUser | null | undefined): AuthUser | null {
  if (!oidcUser?.profile) return null;

  const profile = oidcUser.profile;

  // Les rôles vivent dans l'access_token (realm_access.roles), pas dans
  // l'id_token. Le claim `tenant` (attribut user mappé) y vit aussi.
  let roles: string[] = [];
  let tenant = '';
  if (oidcUser.access_token) {
    try {
      const payload = decodeJwtPayload(oidcUser.access_token) as {
        realm_access?: { roles?: string[] };
        tenant?: string;
      };
      roles = payload.realm_access?.roles ?? [];
      tenant = payload.tenant ?? '';
    } catch (e) {
      if (import.meta.env.DEV) console.warn('Failed to decode access_token', e);
    }
  }

  // Fallback sur le profil id_token si disponible.
  if (roles.length === 0 && Array.isArray((profile as { roles?: string[] }).roles)) {
    roles = (profile as { roles?: string[] }).roles ?? [];
  }

  // Ne garder que les rôles de gouvernance (filtre le bruit Keycloak :
  // offline_access, uma_authorization, default-roles-…).
  const GOVERNANCE_ROLES = ['cpi-admin', 'tenant-admin', 'devops', 'viewer'];
  roles = roles.filter((r) => GOVERNANCE_ROLES.includes(r));
  if (!tenant && typeof (profile as { tenant?: string }).tenant === 'string') {
    tenant = (profile as { tenant?: string }).tenant ?? '';
  }

  return {
    id: profile.sub,
    username: profile.preferred_username ?? '',
    name: profile.name ?? profile.preferred_username ?? '',
    email: profile.email ?? '',
    roles,
    tenant,
    permissions: computePermissions(roles),
  };
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const oidc = useOidcAuth();

  // Getter de jeton injecté dans le client HTTP — toujours la valeur courante,
  // sans recréer le client à chaque renouvellement silencieux.
  const accessTokenRef = useRef<string | null>(null);
  accessTokenRef.current = oidc.user?.access_token ?? null;
  useEffect(() => {
    setTokenGetter(() => accessTokenRef.current);
    return () => setTokenGetter(null);
  }, []);

  const user = useMemo(() => extractUserFromToken(oidc.user), [oidc.user]);
  const isReady = Boolean(oidc.user?.access_token && user);

  const { signinRedirect, signoutRedirect } = oidc;

  // Le bouton « Se connecter via Oracle IdP » court-circuite l'écran de login
  // Keycloak : kc_idp_hint force le broker oracle (Dex) — API-CONTRACT §1.
  const login = useCallback(() => {
    void signinRedirect({ extraQueryParams: { kc_idp_hint: 'oracle' } });
  }, [signinRedirect]);

  const logout = useCallback(() => {
    void signoutRedirect();
  }, [signoutRedirect]);

  const hasPermission = useCallback(
    (permission: string): boolean => user?.permissions.includes(permission) ?? false,
    [user]
  );

  const hasRole = useCallback(
    (role: string): boolean => user?.roles.includes(role) ?? false,
    [user]
  );

  const value: AuthContextType = useMemo(
    () => ({
      user,
      isAuthenticated: oidc.isAuthenticated,
      isLoading: oidc.isLoading,
      isReady,
      login,
      logout,
      hasPermission,
      hasRole,
    }),
    [user, oidc.isAuthenticated, oidc.isLoading, isReady, login, logout, hasPermission, hasRole]
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (context === undefined) {
    throw new Error('useAuth must be used within an AuthProvider');
  }
  return context;
}
