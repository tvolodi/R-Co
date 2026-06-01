/** OIDC Callback Page — processes the authorization code callback from Keycloak */

import { useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { getOidcManager } from '@/auth/OidcManager'
import { useAuth } from '@/auth/AuthContext'
import { setToken } from '@/api/client'
import { decodeTokenPayload, resolveDisplayName } from '@/auth/tokenUtils'

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
        setSession({
          token,
          display_name: resolveDisplayName(payload),
          roles: payload.roles,
          loginSource: 'oidc',
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
