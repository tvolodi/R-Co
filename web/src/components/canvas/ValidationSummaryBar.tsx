import { useState } from 'react'

interface ValidationError {
  nodeId?: string
  edgeId?: string
  message: string
  severity: 'error' | 'warning'
}

interface ValidationSummaryBarProps {
  errors: ValidationError[]
}

export default function ValidationSummaryBar({ errors }: ValidationSummaryBarProps) {
  const [expanded, setExpanded] = useState(false)

  const errorCount = errors.filter((e) => e.severity === 'error').length
  const warningCount = errors.filter((e) => e.severity === 'warning').length

  if (errors.length === 0) return null

  return (
    <div
      style={{
        borderTop: '1px solid var(--border-default, #e9ecef)',
        background: errorCount > 0 ? 'var(--color-error-light, #ffe3e3)' : 'var(--color-warning-light, #fff3bf)',
      }}
    >
      {/* Collapsed bar */}
      <div
        onClick={() => setExpanded(!expanded)}
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          padding: '6px 16px',
          cursor: 'pointer',
          fontSize: 'var(--text-sm, 0.875rem)',
          color: 'var(--text-primary, #212529)',
          userSelect: 'none',
        }}
      >
        <span>
          {errorCount > 0 && <span style={{ fontWeight: 600, color: 'var(--color-error, #fa5252)' }}>{errorCount} error{errorCount !== 1 ? 's' : ''}</span>}
          {errorCount > 0 && warningCount > 0 && <span> · </span>}
          {warningCount > 0 && <span style={{ color: 'var(--color-warning-dark, #e67700)' }}>{warningCount} warning{warningCount !== 1 ? 's' : ''}</span>}
        </span>
        <span style={{ color: 'var(--text-secondary, #6c757d)' }}>
          {expanded ? '▲' : '▼'}
        </span>
      </div>

      {/* Expanded list */}
      {expanded && (
        <div style={{ padding: '0 16px 8px', maxHeight: 120, overflowY: 'auto' }}>
          {errors.map((err, idx) => (
            <div
              key={idx}
              style={{
                display: 'flex',
                alignItems: 'flex-start',
                gap: 6,
                padding: '3px 0',
                fontSize: 'var(--text-xs, 0.75rem)',
                color: 'var(--text-primary, #212529)',
              }}
            >
              <span
                style={{
                  color: err.severity === 'error' ? 'var(--color-error, #fa5252)' : 'var(--color-warning-dark, #e67700)',
                  fontWeight: 'bold',
                  flexShrink: 0,
                }}
              >
                {err.severity === 'error' ? '✗' : '⚠'}
              </span>
              <span>{err.message}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}

export type { ValidationError }
