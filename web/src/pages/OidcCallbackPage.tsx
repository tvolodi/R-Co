/** OIDC Callback Page — processes the authorization code callback from Keycloak */

import { useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { oidcManager } from '@/auth/OidcManager'
import { useAuth } from '@/auth/AuthContext'
import { setToken } from '@/api/client'
import { decodeTokenPayload, resolveDisplayName } from '@/auth/tokenUtils'

export default function OidcCallbackPage() {
  const { setSession } = useAuth()
  const navigate = useNavigate()

  useEffect(() => {
    oidcManager
      .signinRedirectCallback()
      .then((user) => {
        const token = user.access_token
        const payload = decodeTokenPayload(token)
        if (!payload || !payload.roles || payload.roles.length === 0) {
          window.location.replace('/login?reason=auth-error')
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
      })
      .catch(() => {
        window.location.replace('/login?reason=auth-error')
      })
  }, [navigate, setSession])

  return (
    <div data-testid="page-oidc-callback">
      <span data-testid="oidc-callback-status">Completing sign-in...</span>
    </div>
  )
}
