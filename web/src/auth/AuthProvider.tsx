/** Auth provider — OIDC-based login via Keycloak, in-memory session, role-aware navigation */

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import { clearToken, setToken, tryRestoreE2eSession } from '@/api/client'
import { decodeTokenPayload, resolveDisplayName, resolveTenantSlug } from './tokenUtils'
import type { UserSession } from '@/types/api'
import { AuthContext, type AuthContextValue } from './AuthContext'
import { getOidcManager } from './OidcManager'
import { tenantsApi } from '@/api/tenants'
import { resolveRealmFromUrl } from './tenantConfig'

function buildRedirectArgs(): { redirect_uri: string } | undefined {
  const slug = resolveRealmFromUrl()
  if (!slug) return undefined
  return { redirect_uri: window.location.origin + '/auth/callback?realm=' + encodeURIComponent(slug) }
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSessionState] = useState<UserSession | null>(() => {
    // E2E support: restore session from sessionStorage if present (written by test runner)
    const e2e = tryRestoreE2eSession()
    if (e2e) {
      return {
        token: e2e.token,
        display_name: e2e.display_name,
        roles: e2e.roles,
        loginSource: 'oidc',
        tenant_slug: e2e.tenant_slug ?? null,
        tenant_display_name: e2e.tenant_display_name ?? null,
      }
    }
    return null
  })
  const isLoading = false

  // React to session-expired events dispatched by the API client.
  // Redirect to Keycloak login via OIDC.
  useEffect(() => {
    const handle = () => {
      clearToken()
      setSessionState(null)
      void getOidcManager().then(m => {
        void m.signinRedirect(buildRedirectArgs())
      })
    }
    window.addEventListener('auth:session-expired', handle)
    return () => window.removeEventListener('auth:session-expired', handle)
  }, [])

  // Start OIDC silent renew if OIDC authority is configured.
  // On token-expiring event, perform silent renew and update the in-memory token.
  useEffect(() => {
    if (!import.meta.env.VITE_OIDC_AUTHORITY) return
    const handler = async () => {
      try {
        const m = await getOidcManager()
        const newUser = await m.signinSilent()
        if (newUser?.access_token) {
          const newToken = newUser.access_token
          setToken(newToken)
          setSessionState(prev => (prev ? { ...prev, token: newToken } : null))
        }
      } catch {
        // silent renew failed; session-expired event will handle logout
      }
    }
    let cleanup: (() => void) | undefined
    void getOidcManager().then(m => {
      m.events.addAccessTokenExpiring(handler)
      m.startSilentRenew()
      cleanup = () => m.events.removeAccessTokenExpiring(handler)
    })
    return () => {
      if (cleanup) cleanup()
    }
  }, [])

  const login = useCallback(async (token: string) => {
    const payload = decodeTokenPayload(token)
    if (payload === null) {
      throw { status: 400, message: 'Token format is invalid.', code: 'TOKEN_DECODE_INVALID', details: undefined }
    }
    if (!payload.roles || payload.roles.length === 0) {
      throw { status: 400, message: 'Token does not contain role assignments. Contact your administrator.', code: 'TOKEN_MISSING_ROLES', details: undefined }
    }

    setToken(token)

    const tenantSlug = resolveTenantSlug(payload)
    let tenantDisplayName: string | null = null
    if (tenantSlug) {
      try {
        const tenant = await tenantsApi.getBySlug(tenantSlug)
        tenantDisplayName = tenant.display_name
      } catch {
        console.error('[AuthProvider] Could not resolve tenant display name', tenantSlug)
        // tenantDisplayName stays null → rendered as 'Unknown workspace'
      }
    }

    setSessionState({
      token,
      display_name: resolveDisplayName(payload),
      roles: payload.roles,
      loginSource: 'oidc',
      tenant_slug: tenantSlug,
      tenant_display_name: tenantDisplayName,
    })
  }, [])

  const logout = useCallback(() => {
    clearToken()
    setSessionState(null)
    void getOidcManager().then(m => m.signoutRedirect())
  }, [])

  const setSession = useCallback((s: UserSession) => {
    setSessionState(s)
  }, [])

  const value: AuthContextValue = useMemo(
    () => ({
      session,
      isAuthenticated: session !== null,
      isLoading,
      loginSource: session?.loginSource ?? null,
      login,
      logout,
      setSession,
    }),
    [session, isLoading, login, logout, setSession],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}
