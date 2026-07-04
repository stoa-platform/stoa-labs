/**
 * Vendorisé depuis @stoa/shared/utils/errorMessages (messages traduits en français,
 * détection adaptée au client fetch du BFF : forme d'erreur `{error: {code, message}}`).
 *
 * Convertit les erreurs HTTP brutes en messages lisibles pour l'UI —
 * aucun code de statut brut ne doit être visible dans un composant.
 */

export interface FriendlyError {
  /** Message destiné à l'utilisateur */
  message: string;
  /** Action suggérée */
  action?: 'retry' | 'login' | 'home' | 'none';
}

const STATUS_MESSAGES: Record<number, FriendlyError> = {
  400: { message: 'La requête est invalide. Vérifiez votre saisie et réessayez.', action: 'retry' },
  401: { message: 'Votre session a expiré. Veuillez vous reconnecter.', action: 'login' },
  403: { message: 'Vous n’avez pas les droits nécessaires pour cette action.', action: 'home' },
  404: { message: 'La ressource demandée est introuvable.', action: 'home' },
  408: { message: 'La requête a expiré. Veuillez réessayer.', action: 'retry' },
  409: { message: 'Un conflit est survenu. La ressource a peut-être été modifiée. Rafraîchissez et réessayez.', action: 'retry' },
  422: { message: 'Les données fournies sont invalides. Vérifiez votre saisie.', action: 'retry' },
  429: { message: 'Trop de requêtes. Patientez un instant puis réessayez.', action: 'retry' },
  500: { message: 'Une erreur interne est survenue. Réessayez plus tard.', action: 'retry' },
  502: { message: 'Le serveur est temporairement indisponible. Réessayez plus tard.', action: 'retry' },
  503: { message: 'Le service est temporairement indisponible. Réessayez plus tard.', action: 'retry' },
  504: { message: 'Le serveur a mis trop de temps à répondre. Réessayez.', action: 'retry' },
};

const NETWORK_ERROR: FriendlyError = {
  message: 'Impossible de joindre le serveur. Vérifiez votre connexion.',
  action: 'retry',
};

const GENERIC_ERROR: FriendlyError = {
  message: 'Une erreur est survenue. Réessayez plus tard.',
  action: 'retry',
};

/**
 * Extrait le code de statut HTTP d'un objet erreur.
 * Gère la forme ApiError du httpClient (`error.status`) et les erreurs génériques.
 */
function extractStatusCode(error: unknown): number | null {
  if (error && typeof error === 'object') {
    const anyError = error as { status?: number; response?: { status?: number } };
    if (typeof anyError.status === 'number') {
      return anyError.status;
    }
    if (anyError.response?.status) {
      return anyError.response.status;
    }
  }
  return null;
}

/**
 * Détecte une erreur réseau (aucune réponse reçue).
 * `fetch` lève un TypeError quand le serveur est injoignable.
 */
function isNetworkError(error: unknown): boolean {
  if (error instanceof TypeError) {
    return true;
  }
  if (error && typeof error === 'object') {
    const anyError = error as { message?: string; code?: string };
    if (anyError.code === 'ERR_NETWORK' || anyError.code === 'ECONNABORTED') {
      return true;
    }
    if (anyError.message === 'Network Error' || anyError.message === 'Failed to fetch') {
      return true;
    }
  }
  if (typeof error === 'string') {
    return error === 'Network Error' || error.includes('Failed to fetch');
  }
  return false;
}

/**
 * Convertit n'importe quelle erreur en message convivial.
 *
 * Priorité :
 * 1. Détection d'erreur réseau
 * 2. Mapping du code de statut HTTP
 * 3. Message métier du BFF (`{error: {message}}` — porté par ApiError.message)
 * 4. Fallback générique
 */
export function getFriendlyError(error: unknown, fallback?: string): FriendlyError {
  // 1. Erreurs réseau
  if (isNetworkError(error)) {
    return NETWORK_ERROR;
  }

  // 2. Code de statut connu
  const statusCode = extractStatusCode(error);

  // 3. Message métier du BFF (ApiError porte le message du contrat {error:{code,message}})
  if (error && typeof error === 'object') {
    const apiError = error as { name?: string; message?: string };
    if (apiError.name === 'ApiError' && apiError.message) {
      return { message: apiError.message, action: statusCode === 401 ? 'login' : 'retry' };
    }
  }

  if (statusCode && STATUS_MESSAGES[statusCode]) {
    return STATUS_MESSAGES[statusCode];
  }

  // 4. Fallback
  if (fallback) {
    return { message: fallback, action: 'retry' };
  }

  return GENERIC_ERROR;
}

/**
 * Raccourci : retourne uniquement le message convivial.
 */
export function getFriendlyErrorMessage(error: unknown, fallback?: string): string {
  return getFriendlyError(error, fallback).message;
}
