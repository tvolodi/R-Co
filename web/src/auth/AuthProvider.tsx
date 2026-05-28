/** Auth provider — Stage F1: token-based login, in-memory session, role-aware navigation */

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import { useNavigate } from 'react-router-dom'
import { clearToken, setToken } from '@/api/client'
import { decodeTokenPayload, resolveDisplayName } from './tokenUtils'
import type { UserSession } from '@/types/api'
import { AuthContext, type AuthContextValue } from './AuthContext'

const BASE_URL = import.meta.env.VITE_API_BASE_URL ?? ''

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<UserSession | null>(null)
  const isLoading = false
  const navigate = useNavigate()

  // React to session-expired events dispatched by the API client.
  // Use window.location.replace to avoid a React Router ProtectedRoute re-render
  // race that would strip the ?reason=session-expired query parameter.
  useEffect(() => {
    const handle = () => {
      clearToken()
      setSession(null)
      window.location.replace('/login?reason=session-expired')
    }
    window.addEventListener('auth:session-expired', handle)
    return () => window.removeEventListener('auth:session-expired', handle)
  }, [])

  const login = useCallback(async (token: string) => {
    // Validate token against the health endpoint
    const res = await fetch(`${BASE_URL}/health/ready`, {
      headers: { Authorization: `Bearer ${token}` },
    })
    if (!res.ok) {
      const err = { status: res.status, message: 'Invalid token or access denied.', code: 'LOGIN_HEALTH_CHECK_FAILED', details: undefined }
      throw err
    }

    const payload = decodeTokenPayload(token)
    if (payload === null) {
      throw { status: 400, message: 'Token format is invalid.', code: 'TOKEN_DECODE_INVALID', details: undefined }
    }
    if (!payload.roles || payload.roles.length === 0) {
      throw { status: 400, message: 'Token does not contain role assignments. Contact your administrator.', code: 'TOKEN_MISSING_ROLES', details: undefined }
    }

    setToken(token)
    setSession({ token, display_name: resolveDisplayName(payload), roles: payload.roles })
  }, [])

  const logout = useCallback(() => {
    clearToken()
    setSession(null)
    navigate('/login')
  }, [navigate])

  const value: AuthContextValue = useMemo(
    () => ({ session, isAuthenticated: session !== null, isLoading, login, logout }),
    [session, isLoading, login, logout],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}
