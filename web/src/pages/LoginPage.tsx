/** Login page — adapted from ai-dala-forge/frontend/src/features/login/Login.tsx */

import { useState } from 'react'
import { useNavigate, useLocation } from 'react-router-dom'
import { useAuth } from '@/auth/AuthContext'
import type { ApiError } from '@/types/api'

export default function LoginPage() {
  const { login } = useAuth()
  const navigate = useNavigate()
  const location = useLocation()

  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [submitting, setSubmitting] = useState(false)

  const from = (location.state as { from?: { pathname: string } })?.from?.pathname ?? '/'

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
    setSubmitting(true)
    try {
      await login(email, password)
      navigate(from, { replace: true })
    } catch (err) {
      const ae = err as ApiError
      if (ae?.status === 401) setError('Invalid email or password.')
      else if (ae?.status === 403) setError('Account is locked or disabled.')
      else setError(ae?.message ?? 'Login failed.')
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div
      data-testid="page-login"
      style={{
        minHeight: '100vh',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        background: '#f5f5f5',
      }}
    >
      <div
        style={{
          background: '#fff',
          padding: '2.5rem',
          borderRadius: '8px',
          boxShadow: '0 2px 12px rgba(0,0,0,.1)',
          width: '100%',
          maxWidth: '400px',
        }}
      >
        <h1 style={{ marginBottom: '1.5rem', fontSize: '1.4rem' }}>BPM Platform</h1>

        {error && (
          <div
            data-testid="login-error"
            role="alert"
            style={{
              background: '#fff0f0',
              border: '1px solid #ffcccc',
              color: '#c00',
              padding: '.75rem 1rem',
              borderRadius: '4px',
              marginBottom: '1rem',
              fontSize: '.9rem',
            }}
          >
            {error}
          </div>
        )}

        <form onSubmit={handleSubmit} data-testid="login-form">
          <div style={{ marginBottom: '1rem' }}>
            <label htmlFor="email" style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem' }}>
              Email
            </label>
            <input
              id="email"
              data-testid="email-input"
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              required
              autoFocus
              disabled={submitting}
              style={{ width: '100%', padding: '.5rem .75rem', border: '1px solid #ccc', borderRadius: '4px', fontSize: '1rem', boxSizing: 'border-box' }}
            />
          </div>

          <div style={{ marginBottom: '1.5rem' }}>
            <label htmlFor="password" style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem' }}>
              Password
            </label>
            <input
              id="password"
              data-testid="password-input"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
              disabled={submitting}
              style={{ width: '100%', padding: '.5rem .75rem', border: '1px solid #ccc', borderRadius: '4px', fontSize: '1rem', boxSizing: 'border-box' }}
            />
          </div>

          <button
            type="submit"
            data-testid="login-submit"
            disabled={submitting || !email || !password}
            style={{
              width: '100%',
              padding: '.6rem',
              background: submitting ? '#999' : '#2563eb',
              color: '#fff',
              border: 'none',
              borderRadius: '4px',
              fontSize: '1rem',
              cursor: submitting ? 'not-allowed' : 'pointer',
            }}
          >
            {submitting ? 'Signing in…' : 'Sign in'}
          </button>
        </form>
      </div>
    </div>
  )
}
