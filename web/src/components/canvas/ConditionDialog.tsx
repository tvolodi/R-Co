import { useState, useEffect, useCallback, type KeyboardEvent } from 'react'

interface ConditionDialogProps {
  /** Source node display name */
  sourceName: string
  /** Target node display name */
  targetName: string
  /** Called with condition data when user confirms */
  onConfirm: (data: { condition?: string; isDefault: boolean }) => void
  /** Called when user cancels */
  onCancel: () => void
}

export default function ConditionDialog({
  sourceName,
  targetName,
  onConfirm,
  onCancel,
}: ConditionDialogProps) {
  const [celExpression, setCelExpression] = useState('')
  const [isDefault, setIsDefault] = useState(false)

  const handleKeyDown = useCallback(
    (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        onCancel()
      }
    },
    [onCancel],
  )

  useEffect(() => {
    const handler = (e: globalThis.KeyboardEvent) => {
      if (e.key === 'Escape') onCancel()
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [onCancel])

  const isValid = isDefault || celExpression.trim().length > 0

  function handleConfirm() {
    if (!isValid) return
    onConfirm({
      condition: isDefault ? undefined : celExpression.trim(),
      isDefault,
    })
  }

  return (
    <div
      style={{
        position: 'fixed',
        inset: 0,
        background: 'rgba(0,0,0,0.5)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        zIndex: 1000,
      }}
      onClick={onCancel}
      onKeyDown={handleKeyDown}
    >
      <div
        style={{
          background: 'var(--color-neutral-0, #fff)',
          borderRadius: 8,
          padding: 24,
          minWidth: 420,
          maxWidth: 500,
          boxShadow: '0 8px 32px rgba(0,0,0,0.15)',
        }}
        onClick={(e) => e.stopPropagation()}
      >
        <h3
          style={{
            margin: '0 0 4px',
            fontSize: 'var(--text-lg, 1.125rem)',
            fontWeight: 600,
            color: 'var(--text-primary, #212529)',
          }}
        >
          Edge Condition
        </h3>
        <p
          style={{
            margin: '0 0 16px',
            fontSize: 'var(--text-sm, 0.875rem)',
            color: 'var(--text-secondary, #6c757d)',
          }}
        >
          {sourceName} → {targetName}
        </p>

        {/* CEL expression input */}
        <div style={{ marginBottom: 16 }}>
          <label
            style={{
              display: 'block',
              fontSize: 'var(--text-sm, 0.875rem)',
              fontWeight: 500,
              marginBottom: 6,
              color: isDefault ? 'var(--text-disabled, #ced4da)' : 'var(--text-primary, #212529)',
            }}
          >
            CEL Expression
          </label>
          <textarea
            value={celExpression}
            onChange={(e) => {
              setCelExpression(e.target.value)
              if (e.target.value) setIsDefault(false)
            }}
            placeholder="e.g. status == 'approved'"
            disabled={isDefault}
            rows={3}
            style={{
              width: '100%',
              padding: '8px 10px',
              border: `1px solid ${isDefault ? 'var(--color-neutral-200, #e9ecef)' : 'var(--border-default, #e9ecef)'}`,
              borderRadius: 4,
              fontFamily: 'var(--font-mono, monospace)',
              fontSize: 'var(--text-sm, 0.875rem)',
              resize: 'vertical',
              boxSizing: 'border-box',
              background: isDefault ? 'var(--color-neutral-50, #f8f9fa)' : '#fff',
              color: isDefault ? 'var(--text-disabled, #ced4da)' : undefined,
            }}
          />
        </div>

        {/* Default edge toggle */}
        <div style={{ marginBottom: 20 }}>
          <label
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 8,
              fontSize: 'var(--text-sm, 0.875rem)',
              cursor: 'pointer',
            }}
          >
            <input
              type="checkbox"
              checked={isDefault}
              onChange={(e) => {
                setIsDefault(e.target.checked)
                if (e.target.checked) setCelExpression('')
              }}
              style={{ width: 16, height: 16, cursor: 'pointer' }}
            />
            Default edge (no condition)
          </label>
        </div>

        {/* Buttons */}
        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
          <button
            onClick={onCancel}
            style={{
              padding: '6px 16px',
              border: '1px solid var(--border-default, #e9ecef)',
              borderRadius: 4,
              background: '#fff',
              cursor: 'pointer',
              fontSize: 'var(--text-sm, 0.875rem)',
              color: 'var(--text-primary, #212529)',
            }}
          >
            Cancel
          </button>
          <button
            onClick={handleConfirm}
            disabled={!isValid}
            style={{
              padding: '6px 16px',
              border: 'none',
              borderRadius: 4,
              background: isValid
                ? 'var(--interactive-primary, #228be6)'
                : 'var(--color-neutral-300, #dee2e6)',
              color: isValid ? '#fff' : 'var(--text-disabled, #ced4da)',
              cursor: isValid ? 'pointer' : 'not-allowed',
              fontSize: 'var(--text-sm, 0.875rem)',
              fontWeight: 500,
            }}
          >
            Confirm
          </button>
        </div>
      </div>
    </div>
  )
}
