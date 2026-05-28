/** Login page — Stage F1: token-based login with health check validation */

import { useState } from 'react'
import { useNavigate, useLocation } from 'react-router-dom'
import { useAuth } from '@/auth/AuthContext'
import { getOidcManager } from '@/auth/OidcManager'

export default function LoginPage() {
  const { login } = useAuth()
  const navigate = useNavigate()
  const location = useLocation()

  const [token, setToken] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [submitting, setSubmitting] = useState(false)

  const from = (location.state as { from?: { pathname: string } })?.from?.pathname ?? '/'
  const searchParams = new URLSearchParams(location.search)
  const sessionExpired = searchParams.get('reason') === 'session-expired'
  const authError = searchParams.get('reason') === 'auth-error'

  function mapError(code: string, fallback: string): string {
    switch (code) {
      case 'LOGIN_TOKEN_EMPTY': return 'Please enter an API token.'
      case 'LOGIN_HEALTH_CHECK_FAILED': return 'Invalid token or access denied.'
      case 'LOGIN_SERVER_UNAVAILABLE': return 'Cannot reach the server. Check your connection.'
      case 'TOKEN_DECODE_INVALID': return 'Token format is invalid.'
      case 'TOKEN_MISSING_ROLES': return 'Token does not contain role assignments. Contact your administrator.'
      default: return fallback
    }
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
    if (!token.trim()) {
      setError(mapError('LOGIN_TOKEN_EMPTY', 'Please enter an API token.'))
      return
    }
    setSubmitting(true)
    try {
      await login(token.trim())
      navigate(from, { replace: true })
    } catch (err) {
      const ae = err as { code?: string; message?: string }
      if (!ae.code && !ae.message) {
        setError(mapError('LOGIN_SERVER_UNAVAILABLE', 'Cannot reach the server. Check your connection.'))
      } else {
        setError(mapError(ae.code ?? '', ae.message ?? 'Login failed.'))
      }
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

        {sessionExpired && (
          <div
            data-testid="login-session-expired"
            role="alert"
            style={{
              background: '#fff8e1',
              border: '1px solid #ffe082',
              color: '#7a6400',
              padding: '.75rem 1rem',
              borderRadius: '4px',
              marginBottom: '1rem',
              fontSize: '.9rem',
            }}
          >
            Your session has expired. Please log in again.
          </div>
        )}

        {authError && (
          <div
            data-testid="login-auth-error"
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
            Authentication failed. Please try again.
          </div>
        )}

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
          <div style={{ marginBottom: '1.5rem' }}>
            <label htmlFor="login-token" style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem' }}>
              API Token
            </label>
            <input
              id="login-token"
              data-testid="login-token-input"
              type="password"
              value={token}
              onChange={(e) => setToken(e.target.value)}
              autoFocus
              disabled={submitting}
              placeholder="Paste your API token here"
              style={{ width: '100%', padding: '.5rem .75rem', border: '1px solid #ccc', borderRadius: '4px', fontSize: '1rem', boxSizing: 'border-box' }}
            />
          </div>

          <button
            type="submit"
            data-testid="login-submit"
            disabled={submitting}
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

        <div style={{ marginTop: '1rem', textAlign: 'center', color: '#666', fontSize: '.875rem' }}>or</div>

        <button
          data-testid="login-sso-button"
          onClick={() => { void getOidcManager().then(m => m.signinRedirect()) }}
          style={{
            width: '100%',
            marginTop: '.75rem',
            padding: '.6rem',
            background: '#fff',
            color: '#1a1a1a',
            border: '1px solid #ccc',
            borderRadius: '4px',
            fontSize: '1rem',
            cursor: 'pointer',
          }}
        >
          Sign in with Keycloak
        </button>
      </div>
    </div>
  )
}
