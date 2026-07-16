import { useMemo } from 'react';
import { useEnvironment } from '../contexts/EnvironmentContext';

/**
 * useEnvironmentMode — SIMPLIFIÉ vs la carrière : environnements statiques
 * (dev / staging / production), production en lecture seule SANS dérogation
 * cpi-admin (le refus en production est précisément la posture à démontrer).
 *
 * - mode `full`         : toutes les écritures permises
 * - mode `read-only`    : aucune écriture (production)
 * - mode `promote-only` : seule la promotion/déploiement est permise
 */

export interface EnvironmentPermissions {
  canCreate: boolean;
  canEdit: boolean;
  canDelete: boolean;
  canDeploy: boolean;
  isReadOnly: boolean;
}

export function useEnvironmentMode(): EnvironmentPermissions {
  const { activeConfig } = useEnvironment();

  return useMemo(() => {
    switch (activeConfig.mode) {
      case 'full':
        return {
          canCreate: true,
          canEdit: true,
          canDelete: true,
          canDeploy: true,
          isReadOnly: false,
        };
      case 'promote-only':
        return {
          canCreate: false,
          canEdit: false,
          canDelete: false,
          canDeploy: true,
          isReadOnly: false,
        };
      case 'read-only':
      default:
        return {
          canCreate: false,
          canEdit: false,
          canDelete: false,
          canDeploy: false,
          isReadOnly: true,
        };
    }
  }, [activeConfig.mode]);
}
