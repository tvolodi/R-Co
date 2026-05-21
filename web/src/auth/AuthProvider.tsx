/** Auth provider — adapted from ai-dala-forge/frontend/src/core/auth/AuthProvider.tsx
 *  Manages session restoration, login, logout, and token rotation event listening.
 */

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import { useNavigate } from 'react-router-dom'
import {
  client,
  clearRefreshToken,
  clearToken,
  getToken,
  setRefreshToken,
  setToken,
} from '@/api/client'
import type { User } from '@/types/api'
import { AuthContext, type AuthContextValue } from './AuthContext'

interface LoginResponse {
  access_token: string
  refresh_token: string
  user: User
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null)
  const [isLoading, setIsLoading] = useState(true)
  const navigate = useNavigate()

  // Restore session on mount
  useEffect(() => {
    let cancelled = false
    async function restore() {
      if (!getToken()) {
        if (!cancelled) setIsLoading(false)
        return
      }
      try {
        const me = await client.get<User>('/api/v1/auth/me')
        if (!cancelled) setUser(me)
      } catch {
        clearToken()
        clearRefreshToken()
      } finally {
        if (!cancelled) setIsLoading(false)
      }
    }
    restore()
    return () => { cancelled = true }
  }, [])

  // React to session-expired events dispatched by the API client
  useEffect(() => {
    const handle = () => {
      clearToken()
      clearRefreshToken()
      setUser(null)
      navigate('/login')
    }
    window.addEventListener('auth:session-expired', handle)
    return () => window.removeEventListener('auth:session-expired', handle)
  }, [navigate])

  const login = useCallback(async (email: string, password: string) => {
    const res = await client.post<LoginResponse>('/api/v1/auth/login', { email, password })
    setToken(res.access_token)
    setRefreshToken(res.refresh_token)
    setUser(res.user)
  }, [])

  const logout = useCallback(async () => {
    try { await client.post('/api/v1/auth/logout') } catch { /* best-effort */ }
    clearToken()
    clearRefreshToken()
    setUser(null)
    navigate('/login')
  }, [navigate])

  const refreshUser = useCallback(async () => {
    try {
      const me = await client.get<User>('/api/v1/auth/me')
      setUser(me)
    } catch {
      clearToken()
      setUser(null)
    }
  }, [])

  const value: AuthContextValue = useMemo(
    () => ({ user, isAuthenticated: user !== null, isLoading, login, logout, refreshUser }),
    [user, isLoading, login, logout, refreshUser],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}
