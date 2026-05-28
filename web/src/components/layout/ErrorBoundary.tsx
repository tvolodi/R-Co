import React from 'react'

interface ErrorBoundaryProps {
  children: React.ReactNode
  /**
   * Optional custom fallback renderer. Receives the caught error and a reset callback.
   */
  fallback?: (error: Error, reset: () => void) => React.ReactNode
}

interface ErrorBoundaryState {
  hasError: boolean
  error: Error | null
}

export class ErrorBoundary extends React.Component<ErrorBoundaryProps, ErrorBoundaryState> {
  constructor(props: ErrorBoundaryProps) {
    super(props)
    this.state = { hasError: false, error: null }
    this.handleReset = this.handleReset.bind(this)
  }

  static getDerivedStateFromError(error: Error): ErrorBoundaryState {
    return { hasError: true, error }
  }

  componentDidCatch(error: Error, info: React.ErrorInfo): void {
    if (import.meta.env.DEV) {
      console.error('[ErrorBoundary] Caught render error:', error, info.componentStack)
    }
  }

  handleReset(): void {
    this.setState({ hasError: false, error: null })
  }

  render(): React.ReactNode {
    const { hasError, error } = this.state
    const { children, fallback } = this.props

    if (!hasError) {
      return children
    }

    if (fallback && error) {
      return fallback(error, this.handleReset)
    }

    return (
      <div
        data-testid="error-boundary-panel"
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          minHeight: '100vh',
          background: '#f8fafc',
          padding: '2rem',
        }}
      >
        <div
          style={{
            maxWidth: '480px',
            width: '100%',
            background: '#fff',
            border: '1.5px solid #fca5a5',
            borderRadius: '8px',
            padding: '2rem',
            boxShadow: '0 2px 8px rgba(0,0,0,.08)',
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: '.75rem', marginBottom: '1rem' }}>
            <svg
              aria-hidden="true"
              width="24"
              height="24"
              viewBox="0 0 24 24"
              fill="none"
              stroke="#dc2626"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
            >
              <circle cx="12" cy="12" r="10" />
              <line x1="12" y1="8" x2="12" y2="12" />
              <line x1="12" y1="16" x2="12.01" y2="16" />
            </svg>
            <h2 style={{ margin: 0, fontSize: '1.1rem', color: '#111827' }}>
              Something went wrong
            </h2>
          </div>

          <p style={{ margin: '0 0 1rem', color: '#374151', fontSize: '.9rem', lineHeight: 1.6 }}>
            An unexpected error occurred in this view.
            <br />
            Your session and other tabs are not affected.
          </p>

          {import.meta.env.DEV && error && (
            <details
              data-testid="error-boundary-details"
              style={{ marginBottom: '1rem', fontSize: '.8rem', color: '#6b7280' }}
            >
              <summary style={{ cursor: 'pointer', marginBottom: '.5rem' }}>Error details</summary>
              <pre
                style={{
                  background: '#f3f4f6',
                  borderRadius: '4px',
                  padding: '.75rem',
                  overflow: 'auto',
                  whiteSpace: 'pre-wrap',
                  wordBreak: 'break-word',
                  margin: 0,
                }}
              >
                {error.message}
                {error.stack ? `\n\n${error.stack}` : ''}
              </pre>
            </details>
          )}

          <div style={{ display: 'flex', gap: '.75rem', flexWrap: 'wrap' }}>
            <button
              data-testid="error-boundary-reset"
              onClick={this.handleReset}
              style={{
                background: '#2563eb',
                color: '#fff',
                border: 'none',
                borderRadius: '6px',
                padding: '.5rem 1.25rem',
                fontSize: '.9rem',
                cursor: 'pointer',
                fontWeight: 500,
              }}
            >
              Try again
            </button>
            <a
              href="/instances"
              style={{
                display: 'inline-flex',
                alignItems: 'center',
                background: '#f3f4f6',
                color: '#374151',
                border: '1px solid #d1d5db',
                borderRadius: '6px',
                padding: '.5rem 1.25rem',
                fontSize: '.9rem',
                textDecoration: 'none',
                fontWeight: 500,
              }}
            >
              Go to dashboard
            </a>
          </div>
        </div>
      </div>
    )
  }
}
