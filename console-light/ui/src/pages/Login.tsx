import { Navigate, useLocation } from 'react-router-dom';
import { GitCommitHorizontal, LogIn, ShieldCheck } from 'lucide-react';
import { StoaLogo } from '../vendor/stoa-shared/components/StoaLogo';
import { StoaLoader } from '../vendor/stoa-shared/components/StoaLoader';
import { useAuth } from '../contexts/AuthContext';

/**
 * Page de connexion — étape 1 du parcours démo (CADRAGE §1) :
 * login SSO via le broker Oracle-master (Dex → Keycloak), session sans
 * secret statique, rôles extraits du JWT.
 */
export default function Login() {
  const { isAuthenticated, isLoading, login } = useAuth();
  const location = useLocation();

  const from =
    (location.state as { from?: { pathname?: string } } | null)?.from?.pathname ?? '/';

  if (isLoading) {
    return <StoaLoader variant="fullscreen" />;
  }

  if (isAuthenticated) {
    return <Navigate to={from} replace />;
  }

  return (
    <div
      data-testid="page-login"
      className="relative min-h-screen overflow-hidden bg-neutral-950 flex flex-col items-center justify-center p-4"
    >
      {/* Halos décoratifs */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute -top-48 left-1/2 h-96 w-[52rem] -translate-x-1/2 rounded-full bg-primary-600/10 blur-3xl"
      />
      <div
        aria-hidden="true"
        className="pointer-events-none absolute -bottom-56 left-1/3 h-96 w-[40rem] -translate-x-1/2 rounded-full bg-accent-600/10 blur-3xl"
      />

      <div className="relative w-full max-w-md animate-fade-in">
        {/* Marque */}
        <div className="mb-8 flex flex-col items-center text-center">
          <StoaLogo size="lg" />
          <h1 className="mt-4 text-2xl font-bold text-white">STOA Console</h1>
          <p className="mt-1 text-xs font-semibold uppercase tracking-[0.2em] text-neutral-400">
            Gouvernance fédérée des API
          </p>
        </div>

        {/* Carte de connexion */}
        <div className="rounded-modal border border-neutral-800 bg-neutral-900 p-8 shadow-modal">
          <h2 className="text-lg font-semibold text-white">Connexion</h2>
          <p className="mt-1 text-sm text-neutral-400">
            Authentifiez-vous via l’annuaire d’entreprise. La console ne stocke
            aucun secret : votre session est portée par l’IdP central.
          </p>

          <button
            type="button"
            data-testid="login-oracle"
            onClick={login}
            className="mt-6 inline-flex w-full items-center justify-center gap-2 rounded-lg bg-primary-600 px-4 py-3 text-sm font-semibold text-white transition-colors hover:bg-primary-500 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary-400"
          >
            <LogIn className="h-4 w-4" />
            Se connecter via Oracle IdP
          </button>

          <div className="mt-5 flex items-center justify-center gap-4 text-[11px] text-neutral-500">
            <span className="inline-flex items-center gap-1">
              <ShieldCheck className="h-3.5 w-3.5" />
              OpenID Connect · PKCE
            </span>
            <span className="inline-flex items-center gap-1">
              <GitCommitHorizontal className="h-3.5 w-3.5" />
              Zéro secret statique
            </span>
          </div>
        </div>

        <p className="mt-6 text-center text-xs text-neutral-600">
          Chaque action validée devient un commit signé dans le dépôt de gouvernance.
        </p>
      </div>
    </div>
  );
}
