import React from 'react'

interface FetchErrorProps {
  onRetry: () => void
}

export function FetchError({ onRetry }: FetchErrorProps): React.ReactElement {
  return (
    <div role="alert" style={{ padding: '1.5rem' }}>
      <p style={{ marginBottom: '.75rem' }}>
        Something went wrong loading this content.
      </p>
      <button
        type="button"
        onClick={onRetry}
        style={{
          padding: '.4rem .9rem',
          border: '1px solid #cbd5e1',
          borderRadius: '4px',
          background: '#fff',
          cursor: 'pointer',
        }}
      >
        Retry
      </button>
    </div>
  )
}
