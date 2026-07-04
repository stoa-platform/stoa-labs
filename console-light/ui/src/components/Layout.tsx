import { ReactNode, useEffect, useMemo, useRef, useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import {
  ArrowUpDown,
  Building2,
  ChevronDown,
  ClipboardList,
  FileText,
  Inbox,
  LayoutDashboard,
  LogOut,
  Menu,
  Server,
  Shield,
  User as UserIcon,
  Users,
  X,
} from 'lucide-react';
import { StoaLogo } from '../vendor/stoa-shared/components/StoaLogo';
import { ThemeToggle } from '../vendor/stoa-shared/components/ThemeToggle';
import { EnvironmentChrome } from '../vendor/stoa-shared/components/EnvironmentChrome';
import { useAuth } from '../contexts/AuthContext';
import { useEnvironment } from '../contexts/EnvironmentContext';

/**
 * Layout RÉDUIT — adapté de la carrière (control-plane-ui/src/components/Layout.tsx).
 * Retirés : CommandPalette, raccourcis séquentiels, bannière de connectivité,
 * i18n-toggle, sélecteur de tenant requêté (le scope tenant vient du JWT).
 * Conservés : EnvironmentChrome (bandeau prod read-only), ThemeToggle,
 * menu utilisateur avec déconnexion, navigation filtrée par permission.
 *
 * La sidebar couvre exactement les écrans du CADRAGE §4 (le détail, l'éditeur
 * et la revue de MR sont des sous-routes de Contrats / Promotions).
 */

interface LayoutProps {
  children: ReactNode;
}

interface NavItem {
  name: string;
  href: string;
  icon: typeof LayoutDashboard;
  /** Permission §2 requise — absente = visible pour tout authentifié. */
  permission?: string;
  testId: string;
  exact?: boolean;
}

interface NavSection {
  title: string;
  items: NavItem[];
}

const NAV_SECTIONS: NavSection[] = [
  {
    title: 'Vue d’ensemble',
    items: [
      {
        name: 'Tableau de bord',
        href: '/',
        icon: LayoutDashboard,
        testId: 'nav-dashboard',
        exact: true,
      },
    ],
  },
  {
    title: 'Gouvernance',
    items: [
      {
        name: 'Contrats',
        href: '/contracts',
        icon: FileText,
        permission: 'apis:read',
        testId: 'nav-contracts',
      },
      {
        name: 'Promotions',
        href: '/promotions',
        icon: ArrowUpDown,
        permission: 'promotions:read',
        testId: 'nav-promotions',
      },
      {
        name: 'Souscriptions',
        href: '/subscriptions',
        icon: Inbox,
        permission: 'subscriptions:read',
        testId: 'nav-subscriptions',
      },
      {
        name: 'Audit',
        href: '/audit',
        icon: ClipboardList,
        permission: 'audit:read',
        testId: 'nav-audit',
      },
    ],
  },
  {
    title: 'Plateforme',
    items: [
      {
        name: 'Tenants',
        href: '/tenants',
        icon: Building2,
        permission: 'tenants:read',
        testId: 'nav-tenants',
      },
      {
        name: 'Cibles de fédération',
        href: '/targets',
        icon: Server,
        permission: 'targets:read',
        testId: 'nav-targets',
      },
    ],
  },
  {
    title: 'Administration',
    items: [
      {
        name: 'Utilisateurs',
        href: '/admin/users',
        icon: Users,
        permission: 'users:read',
        testId: 'nav-admin-users',
      },
      {
        name: 'Rôles & permissions',
        href: '/admin/roles',
        icon: Shield,
        testId: 'nav-admin-roles',
      },
    ],
  },
];

function isItemActive(item: NavItem, pathname: string): boolean {
  if (item.exact || item.href === '/') {
    return pathname === item.href;
  }
  return pathname === item.href || pathname.startsWith(`${item.href}/`);
}

export function Layout({ children }: LayoutProps) {
  const { user, logout, hasPermission } = useAuth();
  const { activeConfig, environments, switchEnvironment } = useEnvironment();
  const location = useLocation();

  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [userMenuOpen, setUserMenuOpen] = useState(false);
  const userMenuRef = useRef<HTMLDivElement>(null);

  // Navigation filtrée par permission — l'UI masque, le BFF refuse.
  const filteredSections = useMemo(
    () =>
      NAV_SECTIONS.map((section) => ({
        ...section,
        items: section.items.filter(
          (item) => !item.permission || hasPermission(item.permission)
        ),
      })).filter((section) => section.items.length > 0),
    [hasPermission]
  );

  // Titre de la page courante (pour l'en-tête).
  const currentTitle = useMemo(() => {
    const allItems = filteredSections.flatMap((s) => s.items);
    const match = allItems.find((item) => isItemActive(item, location.pathname));
    return match?.name ?? 'Console';
  }, [filteredSections, location.pathname]);

  // Ferme la sidebar mobile au changement de route.
  useEffect(() => {
    setSidebarOpen(false);
  }, [location.pathname]);

  // Ferme le menu utilisateur au clic extérieur.
  useEffect(() => {
    if (!userMenuOpen) return;
    function handleClickOutside(event: MouseEvent) {
      if (userMenuRef.current && !userMenuRef.current.contains(event.target as Node)) {
        setUserMenuOpen(false);
      }
    }
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [userMenuOpen]);

  return (
    <div className="min-h-screen bg-neutral-100 dark:bg-neutral-900 transition-colors">
      {/* Backdrop sidebar mobile */}
      {sidebarOpen && (
        <div
          className="fixed inset-0 z-40 bg-black/50 lg:hidden animate-fade-in"
          onClick={() => setSidebarOpen(false)}
        />
      )}

      {/* Sidebar */}
      <div
        className={`fixed inset-y-0 left-0 z-50 w-64 bg-neutral-100 dark:bg-neutral-950 border-r border-neutral-200 dark:border-neutral-800 transition-transform duration-300 ease-in-out lg:translate-x-0 ${
          sidebarOpen ? 'translate-x-0' : '-translate-x-full'
        }`}
      >
        {/* En-tête sidebar */}
        <div className="flex h-16 items-center justify-between border-b border-neutral-200 dark:border-neutral-800 px-4">
          <div className="flex items-center gap-2">
            <StoaLogo size="sm" />
            <div>
              <h1 className="text-lg font-bold text-neutral-900 dark:text-white leading-tight">
                STOA
              </h1>
              <p className="text-[10px] font-medium text-neutral-500 dark:text-neutral-400 tracking-wider uppercase">
                Console Gouvernance
              </p>
            </div>
          </div>
          <button
            onClick={() => setSidebarOpen(false)}
            className="rounded-lg p-1.5 text-neutral-400 hover:bg-neutral-200 dark:hover:bg-neutral-800 hover:text-neutral-900 dark:hover:text-white lg:hidden"
            aria-label="Fermer le menu"
          >
            <X className="h-5 w-5" />
          </button>
        </div>

        {/* Navigation */}
        <nav
          className="mt-3 px-3 overflow-y-auto"
          style={{ maxHeight: 'calc(100vh - 160px)' }}
          data-testid="sidebar-nav"
        >
          <div className="space-y-5">
            {filteredSections.map((section) => (
              <div key={section.title}>
                <p className="px-3 mb-1.5 text-[11px] font-semibold uppercase tracking-wider text-neutral-500 dark:text-neutral-500">
                  {section.title}
                </p>
                <ul className="space-y-0.5">
                  {section.items.map((item) => {
                    const isActive = isItemActive(item, location.pathname);
                    return (
                      <li key={item.href}>
                        <Link
                          to={item.href}
                          data-testid={item.testId}
                          className={`flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition-colors ${
                            isActive
                              ? 'bg-primary-600 text-white'
                              : 'text-neutral-600 dark:text-neutral-300 hover:bg-neutral-200 dark:hover:bg-neutral-800 hover:text-neutral-900 dark:hover:text-white'
                          }`}
                        >
                          <item.icon className="h-4 w-4 flex-shrink-0" />
                          <span className="truncate">{item.name}</span>
                        </Link>
                      </li>
                    );
                  })}
                </ul>
              </div>
            ))}
          </div>
        </nav>

        {/* Pied de sidebar */}
        <div className="absolute bottom-0 left-0 right-0 border-t border-neutral-200 dark:border-neutral-800 px-4 py-3">
          <p className="text-[11px] text-neutral-500 dark:text-neutral-500 leading-snug">
            Gouvernance Git-first — chaque action validée est un commit signé.
          </p>
        </div>
      </div>

      {/* Contenu principal */}
      <div className="lg:pl-64">
        {/* Bandeau d'environnement (Stripe-inspired) — moment fort de la démo :
            « Production — LECTURE SEULE » en rouge. */}
        <EnvironmentChrome
          current={{
            name: activeConfig.name,
            label: activeConfig.label,
            mode: activeConfig.mode,
          }}
          environments={environments.map((env) => ({
            name: env.name,
            label: env.label,
            mode: env.mode,
          }))}
          onSwitch={switchEnvironment}
          variant="admin"
          className="sticky top-0 z-50"
        />

        {/* En-tête */}
        <header className="sticky top-[36px] z-40 flex h-16 items-center gap-4 border-b bg-white dark:bg-neutral-900 dark:border-neutral-800 px-4 sm:px-6 shadow-sm dark:shadow-none">
          {/* Bouton menu mobile */}
          <button
            onClick={() => setSidebarOpen(true)}
            className="rounded-lg p-2.5 text-neutral-500 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 lg:hidden"
            aria-label="Ouvrir le menu"
          >
            <Menu className="h-5 w-5" />
          </button>

          {/* Titre de page */}
          <span
            className="flex-1 font-semibold text-neutral-900 dark:text-white truncate"
            data-testid="page-title"
          >
            {currentTitle}
          </span>

          {/* Badge tenant (scope du JWT) */}
          {user?.tenant && (
            <span
              className="hidden sm:inline-flex items-center gap-1.5 rounded-lg bg-neutral-100 dark:bg-neutral-800 px-3 py-1.5 text-sm font-medium text-neutral-700 dark:text-neutral-300"
              data-testid="tenant-badge"
              title="Tenant (claim JWT)"
            >
              <Building2 className="h-4 w-4 text-neutral-500 dark:text-neutral-400" />
              {user.tenant}
            </span>
          )}

          {/* Bascule de thème */}
          <ThemeToggle size="md" />

          {/* Menu utilisateur */}
          <div className="relative" ref={userMenuRef}>
            <button
              onClick={() => setUserMenuOpen((open) => !open)}
              className="flex items-center gap-2 rounded-lg px-2 py-1.5 hover:bg-neutral-100 dark:hover:bg-neutral-800 transition-colors"
              aria-haspopup="menu"
              aria-expanded={userMenuOpen}
              data-testid="user-menu"
            >
              <span className="flex h-8 w-8 items-center justify-center rounded-full bg-primary-600 flex-shrink-0">
                <UserIcon className="h-4 w-4 text-white" />
              </span>
              <span className="hidden md:block text-left">
                <span className="block text-sm font-medium text-neutral-900 dark:text-white leading-tight max-w-[140px] truncate">
                  {user?.name || '—'}
                </span>
                <span className="block text-xs text-neutral-500 dark:text-neutral-400 leading-tight max-w-[140px] truncate">
                  {user?.roles.join(', ') || ''}
                </span>
              </span>
              <ChevronDown
                className={`h-4 w-4 text-neutral-400 transition-transform duration-200 ${
                  userMenuOpen ? 'rotate-180' : ''
                }`}
              />
            </button>

            {userMenuOpen && (
              <div
                className="absolute right-0 mt-1 w-64 bg-white dark:bg-neutral-800 rounded-lg border border-neutral-200 dark:border-neutral-700 shadow-lg z-50 py-1"
                role="menu"
              >
                <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-700">
                  <p className="text-sm font-medium text-neutral-900 dark:text-white truncate">
                    {user?.name || '—'}
                  </p>
                  <p className="text-xs text-neutral-500 dark:text-neutral-400 truncate">
                    {user?.email || ''}
                  </p>
                  {user && user.roles.length > 0 && (
                    <div className="mt-2 flex flex-wrap gap-1">
                      {user.roles.map((role) => (
                        <span
                          key={role}
                          className="inline-flex items-center rounded-full bg-primary-50 dark:bg-primary-900/30 px-2 py-0.5 text-[11px] font-medium text-primary-700 dark:text-primary-300"
                        >
                          {role}
                        </span>
                      ))}
                    </div>
                  )}
                </div>
                <button
                  onClick={logout}
                  className="w-full flex items-center gap-2 px-4 py-2.5 text-left text-sm text-neutral-700 dark:text-neutral-300 hover:bg-neutral-50 dark:hover:bg-neutral-700/50 transition-colors"
                  role="menuitem"
                  data-testid="logout"
                >
                  <LogOut className="h-4 w-4" />
                  Se déconnecter
                </button>
              </div>
            )}
          </div>
        </header>

        {/* Contenu de page */}
        <main className="p-4 sm:p-6">{children}</main>
      </div>
    </div>
  );
}
