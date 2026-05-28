/** Auth context — adapted from ai-dala-forge/frontend/src/core/auth/AuthContext.tsx */

import { createContext, useContext } from 'react'
import type { UserSession } from '@/types/api'

export interface AuthContextValue {
  session: UserSession | null
  isAuthenticated: boolean
  isLoading: boolean
  loginSource: 'token' | 'oidc' | null
  login: (token: string) => Promise<void>
  logout: () => void
  setSession: (s: UserSession) => void
}

export const AuthContext = createContext<AuthContextValue | undefined>(undefined)

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth must be used inside <AuthProvider>')
  return ctx
}
