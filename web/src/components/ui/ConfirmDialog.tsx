/** ConfirmDialog — generic confirm dialog (RND-UI-06 §2.6 OQ-1)
 *
 *  Generic version of ConfirmPromoteModal: takes title, body, confirm/cancel
 *  text, and a confirmVariant ('primary' | 'danger'). Used by ConflictResolver
 *  for the Discard mine confirmation step.
 */

import React, { useEffect, useRef } from 'react'

export interface ConfirmDialogProps {
  open: boolean
  title: string
  body: string
  confirmText?: string
  cancelText?: string
  confirmVariant?: 'primary' | 'danger'
  onConfirm: () => void
  onCancel: () => void
  isLoading?: boolean
}

const VARIANT_STYLES: Record<NonNullable<ConfirmDialogProps['confirmVariant']>, { bg: string; hover: string }> = {
  primary: { bg: '#2563eb', hover: '#1d4ed8' },
  danger: { bg: '#dc2626', hover: '#b91c1c' },
}

export function ConfirmDialog(props: ConfirmDialogProps): React.ReactElement | null {
  const {
    open,
    title,
    body,
    confirmText = 'Confirm',
    cancelText = 'Cancel',
    confirmVariant = 'primary',
    onConfirm,
    onCancel,
    isLoading = false,
  } = props

  const confirmRef = useRef<HTMLButtonElement | null>(null)

  useEffect(() => {
    if (!open) return
    // Focus the confirm button when the dialog opens so Enter triggers it.
    confirmRef.current?.focus()
  }, [open])

  // Escape key cancels the dialog
  useEffect(() => {
    if (!open) return
    const handler = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') {
        e.stopPropagation()
        onCancel()
      }
    }
    window.addEventListener('keydown', handler)
    return () => {
      window.removeEventListener('keydown', handler)
    }
  }, [open, onCancel])

  if (!open) return null

  const variant = VARIANT_STYLES[confirmVariant]

  return (
    <div
      data-testid="confirm-dialog"
      role="dialog"
      aria-modal="true"
      aria-labelledby="confirm-dialog-title"
      style={{
        position: 'fixed',
        inset: 0,
        background: 'rgba(0,0,0,0.4)',
        zIndex: 600,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      <div
        style={{
          background: '#fff',
          borderRadius: '8px',
          padding: '1.5rem',
          maxWidth: '480px',
          width: '90vw',
          boxShadow: '0 8px 32px rgba(0,0,0,0.18)',
        }}
      >
        <h3
          id="confirm-dialog-title"
          style={{
            margin: '0 0 1rem',
            fontSize: '1.05rem',
            fontWeight: 600,
            color: '#111827',
          }}
        >
          {title}
        </h3>
        <p
          style={{
            margin: '0 0 1.5rem',
            fontSize: '.9rem',
            color: '#374151',
            lineHeight: 1.55,
          }}
        >
          {body}
        </p>
        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: '.5rem' }}>
          <button
            data-testid="confirm-dialog-cancel"
            type="button"
            onClick={onCancel}
            disabled={isLoading}
            style={{
              padding: '6px 16px',
              border: '1px solid #d1d5db',
              borderRadius: '4px',
              background: '#fff',
              cursor: isLoading ? 'not-allowed' : 'pointer',
              fontSize: '.875rem',
              color: '#374151',
              opacity: isLoading ? 0.6 : 1,
            }}
          >
            {cancelText}
          </button>
          <button
            ref={confirmRef}
            data-testid="confirm-dialog-confirm"
            type="button"
            onClick={onConfirm}
            disabled={isLoading}
            style={{
              padding: '6px 16px',
              border: 'none',
              borderRadius: '4px',
              background: variant.bg,
              color: '#fff',
              cursor: isLoading ? 'not-allowed' : 'pointer',
              fontSize: '.875rem',
              fontWeight: 500,
              opacity: isLoading ? 0.7 : 1,
            }}
          >
            {confirmText}
          </button>
        </div>
      </div>
    </div>
  )
}
