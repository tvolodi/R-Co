import { resolveRealmFromUrl } from './tenantConfig'

/**
 * Builds optional signinRedirect args that embed the current tenant realm
 * slug in the redirect_uri so that OidcCallbackPage can identify the realm
 * without relying on sessionStorage state alone.
 *
 * Returns `{ redirect_uri }` when a realm slug is resolvable, or `undefined`
 * to let the UserManager use its configured default redirect_uri.
 */
export function buildRedirectArgs(): { redirect_uri: string } | undefined {
  const slug = resolveRealmFromUrl()
  if (!slug) return undefined
  return {
    redirect_uri:
      window.location.origin + '/auth/callback?realm=' + encodeURIComponent(slug),
  }
}
