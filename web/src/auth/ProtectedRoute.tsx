/** Protected route — redirects unauthenticated users to Keycloak via OIDC */

import type { ReactNode } from 'react'
import { useEffect, useState } from 'react'
import { useAuth } from './AuthContext'
import { getOidcManager } from './OidcManager'
import { buildRedirectArgs } from './oidcRedirectArgs'

export function ProtectedRoute({ children }: { children: ReactNode }) {
  const { isAuthenticated, isLoading } = useAuth()
  const [redirecting, setRedirecting] = useState(false)

  useEffect(() => {
    if (!isLoading && !isAuthenticated && !redirecting) {
      setRedirecting(true)
      void getOidcManager().then(m => {
        void m.signinRedirect(buildRedirectArgs())
      })
    }
  }, [isLoading, isAuthenticated, redirecting])

  if (isLoading || redirecting) {
    return (
      <div
        style={{ display: 'flex', justifyContent: 'center', alignItems: 'center', height: '100vh' }}
        data-testid="auth-loading"
      >
        Redirecting to login…
      </div>
    )
  }

  if (!isAuthenticated) {
    return null
  }

  return <>{children}</>
}
