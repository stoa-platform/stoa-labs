import { createContext, useContext, useState, useCallback, useMemo, ReactNode } from 'react';
import type { EnvironmentName } from '../types';

/**
 * Contexte d'environnement SIMPLIFIÉ (vs la carrière) : trois environnements
 * statiques alignés sur le modèle Git (deploy.{env}.yaml — API-CONTRACT §3).
 *
 * Posture démontrée (CADRAGE §4) :
 * - dev        → accès complet (publication directe sur main)
 * - staging    → promotion seule (on n'édite pas, on promeut)
 * - production → LECTURE SEULE (bandeau rouge EnvironmentChrome)
 */

export type EnvironmentMode = 'full' | 'promote-only' | 'read-only';

export interface EnvironmentConfig {
  name: EnvironmentName;
  label: string;
  mode: EnvironmentMode;
}

export const ENVIRONMENTS: EnvironmentConfig[] = [
  { name: 'dev', label: 'Développement', mode: 'full' },
  { name: 'staging', label: 'Staging', mode: 'promote-only' },
  { name: 'production', label: 'Production', mode: 'read-only' },
];

interface EnvironmentContextValue {
  activeEnvironment: EnvironmentName;
  activeConfig: EnvironmentConfig;
  environments: EnvironmentConfig[];
  switchEnvironment: (name: string) => void;
}

const EnvironmentContext = createContext<EnvironmentContextValue | undefined>(undefined);

const STORAGE_KEY = 'console-light-env';

function isEnvironmentName(value: string): value is EnvironmentName {
  return ENVIRONMENTS.some((env) => env.name === value);
}

export function EnvironmentProvider({ children }: { children: ReactNode }) {
  const [activeEnvironment, setActiveEnvironment] = useState<EnvironmentName>(() => {
    const stored = localStorage.getItem(STORAGE_KEY);
    return stored && isEnvironmentName(stored) ? stored : 'dev';
  });

  const switchEnvironment = useCallback((name: string) => {
    if (isEnvironmentName(name)) {
      setActiveEnvironment(name);
      localStorage.setItem(STORAGE_KEY, name);
    }
  }, []);

  const activeConfig = useMemo(
    () => ENVIRONMENTS.find((env) => env.name === activeEnvironment) ?? ENVIRONMENTS[0],
    [activeEnvironment]
  );

  const value = useMemo(
    () => ({
      activeEnvironment,
      activeConfig,
      environments: ENVIRONMENTS,
      switchEnvironment,
    }),
    [activeEnvironment, activeConfig, switchEnvironment]
  );

  return <EnvironmentContext.Provider value={value}>{children}</EnvironmentContext.Provider>;
}

export function useEnvironment() {
  const context = useContext(EnvironmentContext);
  if (context === undefined) {
    throw new Error('useEnvironment must be used within an EnvironmentProvider');
  }
  return context;
}
