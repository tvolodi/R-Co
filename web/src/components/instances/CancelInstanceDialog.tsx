import { useEffect, useRef, useState } from 'react'

interface CancelInstanceDialogProps {
  open: boolean
  instanceId: string
  instanceName: string
  onConfirm: (reason?: string) => void
  onCancel: () => void
  isPending: boolean
}

export function CancelInstanceDialog({
  open,
  instanceId,
  instanceName,
  onConfirm,
  onCancel,
  isPending,
}: CancelInstanceDialogProps) {
  const [reason, setReason] = useState('')
  const dialogRef = useRef<HTMLDivElement | null>(null)
  const firstFocusableRef = useRef<HTMLButtonElement | null>(null)

  useEffect(() => {
    if (!open) {
      setReason('')
      return
    }

    const keyHandler = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        onCancel()
        return
      }

      if (event.key !== 'Tab' || !dialogRef.current) return

      const focusables = dialogRef.current.querySelectorAll<HTMLElement>(
        'button, textarea, input, [href], select, [tabindex]:not([tabindex="-1"])',
      )
      if (focusables.length === 0) return

      const first = focusables[0]
      const last = focusables[focusables.length - 1]
      const current = document.activeElement

      if (event.shiftKey && current === first) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && current === last) {
        event.preventDefault()
        first.focus()
      }
    }

    document.addEventListener('keydown', keyHandler)
    firstFocusableRef.current?.focus()

    return () => {
      document.removeEventListener('keydown', keyHandler)
    }
  }, [onCancel, open])

  if (!open) return null

  const onConfirmClick = () => {
    const trimmed = reason.trim()
    onConfirm(trimmed.length > 0 ? trimmed : undefined)
  }

  return (
    <div
      style={{
        position: 'fixed',
        inset: 0,
        background: 'rgba(0, 0, 0, 0.45)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        zIndex: 1000,
      }}
      onClick={onCancel}
    >
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="cancel-instance-title"
        aria-describedby="cancel-instance-description"
        onClick={(event) => event.stopPropagation()}
        style={{
          width: '560px',
          maxWidth: '92vw',
          background: '#fff',
          borderRadius: '8px',
          boxShadow: '0 8px 24px rgba(0,0,0,0.16)',
          padding: '1rem 1.2rem',
        }}
      >
        <h3 id="cancel-instance-title" style={{ marginTop: 0, marginBottom: '.5rem' }}>
          Cancel instance?
        </h3>

        <p id="cancel-instance-description" style={{ marginTop: 0, color: '#475569', fontSize: '.9rem' }}>
          This will cancel instance {instanceName}. Running tasks and timers will be terminated.
          This action cannot be undone.
        </p>

        <div style={{ color: '#64748b', fontSize: '.8rem', marginBottom: '.5rem' }}>
          Instance ID: <code>{instanceId}</code>
        </div>

        <label htmlFor="cancel-reason" style={{ display: 'block', fontSize: '.85rem', color: '#334155', marginBottom: '.25rem' }}>
          Reason (optional)
        </label>
        <textarea
          id="cancel-reason"
          value={reason}
          onChange={(event) => setReason(event.target.value.slice(0, 500))}
          rows={4}
          maxLength={500}
          style={{
            width: '100%',
            marginBottom: '.8rem',
            padding: '.5rem .6rem',
            border: '1px solid #cbd5e1',
            borderRadius: '4px',
            fontFamily: 'inherit',
          }}
        />

        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: '.5rem' }}>
          <button
            ref={firstFocusableRef}
            onClick={onCancel}
            disabled={isPending}
            style={{
              padding: '.4rem .8rem',
              border: '1px solid #cbd5e1',
              borderRadius: '4px',
              background: '#fff',
              cursor: 'pointer',
            }}
          >
            Close
          </button>
          <button
            onClick={onConfirmClick}
            disabled={isPending}
            style={{
              padding: '.4rem .8rem',
              border: 'none',
              borderRadius: '4px',
              background: '#dc2626',
              color: '#fff',
              cursor: isPending ? 'not-allowed' : 'pointer',
            }}
          >
            {isPending ? 'Cancelling...' : 'Confirm cancellation'}
          </button>
        </div>
      </div>
    </div>
  )
}
