/**
 * Client HTTP du BFF gouvernance — fetch natif + Authorization Bearer.
 * Le jeton est fourni par un getter injecté par l'AuthContext (aucun import
 * croisé auth ↔ services). Erreurs au format du contrat : {error: {code, message}}.
 */

// ============================================================================
// Injection du jeton
// ============================================================================

type TokenGetter = () => string | null;

let tokenGetter: TokenGetter | null = null;

/** Injecté par l'AuthProvider au montage ; null au démontage. */
export function setTokenGetter(getter: TokenGetter | null): void {
  tokenGetter = getter;
}

// ============================================================================
// Erreur d'API
// ============================================================================

export class ApiError extends Error {
  override readonly name = 'ApiError';
  /** Code du contrat (ex: SELF_APPROVAL_BLOCKED, DESTRUCTIVE_REQUIRES_APPROVAL). */
  readonly code: string;
  /** Statut HTTP. */
  readonly status: number;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

// ============================================================================
// Requêtes
// ============================================================================

const BASE_URL = '/api/v1';

export type QueryParams = Record<string, string | number | boolean | undefined>;

function buildUrl(path: string, params?: QueryParams): string {
  let url = BASE_URL + path;
  if (params) {
    const search = new URLSearchParams();
    for (const [key, value] of Object.entries(params)) {
      if (value !== undefined && value !== '') {
        search.set(key, String(value));
      }
    }
    const query = search.toString();
    if (query) url += `?${query}`;
  }
  return url;
}

function authHeaders(): Record<string, string> {
  const headers: Record<string, string> = { Accept: 'application/json' };
  const token = tokenGetter?.() ?? null;
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }
  return headers;
}

async function toApiError(response: Response): Promise<ApiError> {
  let code = 'HTTP_ERROR';
  let message = `Erreur ${response.status}`;
  try {
    const body = (await response.json()) as { error?: { code?: string; message?: string } };
    if (body?.error) {
      code = body.error.code ?? code;
      message = body.error.message ?? message;
    }
  } catch {
    // Corps non-JSON — on garde le message générique.
  }
  return new ApiError(response.status, code, message);
}

async function request<T>(
  method: 'GET' | 'POST' | 'PUT' | 'DELETE',
  path: string,
  options?: { params?: QueryParams; body?: unknown }
): Promise<T> {
  const headers = authHeaders();
  let body: string | undefined;
  if (options?.body !== undefined) {
    headers['Content-Type'] = 'application/json';
    body = JSON.stringify(options.body);
  }

  const response = await fetch(buildUrl(path, options?.params), { method, headers, body });

  if (!response.ok) {
    throw await toApiError(response);
  }
  if (response.status === 204) {
    return undefined as T;
  }
  return (await response.json()) as T;
}

/**
 * Téléchargement binaire (export audit). Retourne le blob et le nom de
 * fichier extrait de Content-Disposition.
 */
async function requestBlob(
  path: string,
  params?: QueryParams
): Promise<{ blob: Blob; filename: string | null }> {
  const response = await fetch(buildUrl(path, params), {
    method: 'GET',
    headers: authHeaders(),
  });
  if (!response.ok) {
    throw await toApiError(response);
  }
  const disposition = response.headers.get('Content-Disposition') ?? '';
  const match = /filename="?([^";]+)"?/.exec(disposition);
  return { blob: await response.blob(), filename: match ? match[1] : null };
}

export const http = {
  get: <T>(path: string, params?: QueryParams) => request<T>('GET', path, { params }),
  post: <T>(path: string, body?: unknown, params?: QueryParams) =>
    request<T>('POST', path, { body, params }),
  put: <T>(path: string, body?: unknown) => request<T>('PUT', path, { body }),
  delete: <T>(path: string) => request<T>('DELETE', path),
  blob: requestBlob,
};
