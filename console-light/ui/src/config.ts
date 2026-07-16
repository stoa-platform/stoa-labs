import { WebStorageStateStore } from 'oidc-client-ts';
import type { AuthProviderProps } from 'react-oidc-context';

/**
 * Configuration OIDC — API-CONTRACT.md §1 :
 * - Authorization Code + PKCE (S256, défaut oidc-client-ts pour le flux code)
 * - authority : realm stoa-lab du Keycloak local (issuer épinglé)
 * - client_id : console-light (client public dédié, redirectUris épinglées)
 * - Le passage par le broker `oracle` (Dex) se fait via kc_idp_hint au
 *   signinRedirect (voir AuthContext.login).
 */
export const oidcConfig: AuthProviderProps = {
  authority: 'http://localhost:8480/realms/stoa-lab',
  client_id: 'console-light',
  redirect_uri: `${window.location.origin}/`,
  post_logout_redirect_uri: `${window.location.origin}/login`,
  response_type: 'code',
  scope: 'openid profile email',
  automaticSilentRenew: true,
  // sessionStorage (pattern carrière) — pas de jeton persistant inter-onglets.
  userStore: new WebStorageStateStore({ store: window.sessionStorage }),
  // Nettoie code/state de l'URL après le retour de Keycloak.
  onSigninCallback: () => {
    window.history.replaceState({}, document.title, window.location.pathname);
  },
};
