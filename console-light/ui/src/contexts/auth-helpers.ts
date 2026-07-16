/**
 * Helpers purs consommés par AuthContext (vendorisés depuis la carrière —
 * control-plane-ui/src/contexts/auth-helpers.ts, fonction MCP retirée).
 */

// Les JWT utilisent base64url (alphabet `-`, `_`, sans padding). `atob()`
// n'accepte que le base64 standard (`+`, `/`, `=`) : un payload contenant
// `-` ou `_` lèverait InvalidCharacterError et l'utilisateur perdrait
// silencieusement toutes ses permissions. On décode aussi via TextDecoder
// pour que les claims UTF-8 (noms accentués…) survivent.
export function decodeJwtPayload(token: string): unknown {
  const [, segment] = token.split('.');
  if (!segment) throw new Error('Invalid JWT — missing payload segment');
  const padded = segment + '='.repeat((4 - (segment.length % 4)) % 4);
  const base64 = padded.replace(/-/g, '+').replace(/_/g, '/');
  const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
  return JSON.parse(new TextDecoder().decode(bytes));
}
