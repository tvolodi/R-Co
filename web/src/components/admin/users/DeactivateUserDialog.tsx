import { useState } from 'react'
import type { CSSProperties } from 'react'

type Props = {
  open: boolean
  displayName: string
  isSubmitting: boolean
  onCancel: () => void
  onConfirm: (reason?: string) => void
}

export function DeactivateUserDialog({ open, displayName, isSubmitting, onCancel, onConfirm }: Props) {
  const [reason, setReason] = useState('')
  if (!open) return null

  return (
    <div style={overlayStyle} role="dialog" aria-modal="true" aria-label="Deactivate user">
      <div style={dialogStyle}>
        <h3 style={{ marginTop: 0 }}>Deactivate user</h3>
        <p>
          Deactivating <strong>{displayName}</strong> will set the account to INACTIVE.
          Active tasks assigned to this user remain assigned, but the user cannot complete them while INACTIVE.
        </p>

        <label style={{ display: 'block', marginBottom: 12 }}>
          <span style={{ display: 'block', marginBottom: 6, fontWeight: 600, fontSize: 14 }}>Reason (optional)</span>
          <input value={reason} onChange={(event) => setReason(event.target.value)} style={{ width: '100%' }} />
        </label>

        <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
          <button type="button" onClick={onCancel}>Cancel</button>
          <button
            type="button"
            onClick={() => onConfirm(reason.trim() || undefined)}
            disabled={isSubmitting}
          >
            {isSubmitting ? 'Deactivating...' : 'Deactivate'}
          </button>
        </div>
      </div>
    </div>
  )
}

const overlayStyle: CSSProperties = {
  position: 'fixed',
  inset: 0,
  backgroundColor: 'rgba(15, 23, 42, 0.45)',
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'center',
  zIndex: 30,
}

const dialogStyle: CSSProperties = {
  backgroundColor: '#fff',
  width: 'min(560px, calc(100vw - 2rem))',
  borderRadius: 8,
  padding: 20,
}
