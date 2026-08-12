/** OIDC Callback Page — processes the authorization code callback from Keycloak */

import { useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { getOidcManager } from '@/auth/OidcManager'
import { useAuth } from '@/auth/AuthContext'
import { setToken } from '@/api/client'
import { decodeTokenPayload, resolveDisplayName } from '@/auth/tokenUtils'
import { resolveRealmFromUrl } from '@/auth/tenantConfig'
import { tenantsApi } from '@/api/tenants'

/**
 * Module-level guard: prevent double-invocation of signinRedirectCallback().
 *
 * In development, React StrictMode fires useEffect twice (mount → unmount → remount).
 * An PKCE authorization code is single-use — the second call would receive
 * "Code not valid" from Keycloak and erroneously trigger a re-login attempt.
 *
 * This flag is set before the async call begins. Because it lives at module scope it
 * survives the StrictMode remount. It is reset to false on each full page load (the
 * module is re-imported when Keycloak redirects back to /auth/callback).
 */
let _callbackStarted = false

export default function OidcCallbackPage() {
  const { setSession } = useAuth()
  const navigate = useNavigate()

  useEffect(() => {
    if (_callbackStarted) return
    _callbackStarted = true

    ;(async () => {
      try {
        const m = await getOidcManager()
        const user = await m.signinRedirectCallback()
        const token = user.access_token
        const payload = decodeTokenPayload(token)
        if (!payload || !payload.roles || payload.roles.length === 0) {
          // Invalid token — redirect to root which triggers Keycloak login
          window.location.replace('/')
          return
        }
        setToken(token)
        const realmSlug = resolveRealmFromUrl() ?? sessionStorage.getItem('bpm_realm_slug') ?? null
        let tenantDisplayName: string | null = null
        let tenantId: string | null = null
        let tenantType: 'production' | 'test' | null = null
        let productionTenantDisplayName: string | null = null
        if (realmSlug) {
          try {
            const tenantData = await tenantsApi.getBySlug(realmSlug)
            tenantDisplayName = tenantData?.display_name ?? null
            tenantId = tenantData?.tenant_id ?? null
            tenantType = tenantData?.tenant_type ?? null
            productionTenantDisplayName = tenantData?.production_tenant_display_name ?? null
          } catch {
            // non-fatal — workspace header will show slug as fallback
          }
        }
        setSession({
          token,
          display_name: resolveDisplayName(payload),
          roles: payload.roles,
          loginSource: 'oidc',
          tenant_slug: realmSlug,
          tenant_display_name: tenantDisplayName,
          tenant_id: tenantId,
          tenant_type: tenantType,
          production_tenant_display_name: productionTenantDisplayName,
        })
        navigate('/', { replace: true })
      } catch {
        // OIDC callback failed — redirect to root which triggers Keycloak login
        window.location.replace('/')
      }
    })()
  }, [navigate, setSession])

  return (
    <div data-testid="page-oidc-callback">
      <span data-testid="oidc-callback-status">Completing sign-in...</span>
    </div>
  )
}
