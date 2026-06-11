import { useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { tenantsApi } from '@/api/tenants'
import { queryKeys } from '@/api/queryKeys'

export interface PromoteConfirmModalProps {
  open: boolean
  testTenantId: string
  definitionName: string
  productionDisplayName: string
  onSuccess: () => void
  onCancel: () => void
}

export function PromoteConfirmModal({
  open,
  testTenantId,
  definitionName,
  productionDisplayName,
  onSuccess,
  onCancel,
}: PromoteConfirmModalProps) {
  const qc = useQueryClient()
  const [isPending, setIsPending] = useState(false)
  const [errorMsg, setErrorMsg] = useState<string | null>(null)
  const [successMsg, setSuccessMsg] = useState<string | null>(null)

  if (!open) return null

  async function handleConfirm() {
    setErrorMsg(null)
    setSuccessMsg(null)
    setIsPending(true)
    try {
      await tenantsApi.promote(testTenantId, definitionName)
      setSuccessMsg('Promoted successfully. A DRAFT version is now available in production.')
      await qc.invalidateQueries({ queryKey: queryKeys.definitions.list({}) })
      setTimeout(() => {
        setIsPending(false)
        onSuccess()
      }, 1500)
    } catch (err: unknown) {
      const apiErr = err as { status?: number; message?: string }
      if (apiErr.status === 404) {
        setErrorMsg('Promotion failed: definition or tenant not found.')
      } else if (apiErr.status === 409) {
        setErrorMsg('A version of this definition already exists in the production tenant.')
      } else if (apiErr.status === 422) {
        setErrorMsg(apiErr.message ?? 'Promotion failed: validation error.')
      } else {
        setErrorMsg('Promotion failed due to a server error. Please try again.')
      }
      setIsPending(false)
    }
  }

  return (
    <div
      data-testid="promote-confirm-modal-overlay"
      style={{
        position: 'fixed',
        inset: 0,
        background: 'rgba(0,0,0,0.5)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        zIndex: 1100,
      }}
    >
      <div
        data-testid="promote-confirm-modal"
        style={{
          background: '#fff',
          borderRadius: 8,
          padding: 24,
          minWidth: 380,
          maxWidth: 480,
          boxShadow: '0 8px 32px rgba(0,0,0,0.18)',
        }}
      >
        <h2 style={{ margin: '0 0 1rem 0', fontSize: '1.1rem', fontWeight: 700 }}>
          Confirm Promotion
        </h2>
        <p style={{ margin: '0 0 1.25rem 0', fontSize: '.92rem', lineHeight: 1.5, color: '#374151' }}>
          You are about to promote &ldquo;<strong>{definitionName}</strong>&rdquo; to production
          tenant &ldquo;<strong>{productionDisplayName}</strong>&rdquo;. This will create a{' '}
          <strong>DRAFT</strong> version that requires separate activation. Confirm?
        </p>

        {errorMsg && (
          <div
            role="alert"
            data-testid="promote-modal-error"
            style={{
              marginBottom: '1rem',
              padding: '.6rem .9rem',
              borderRadius: 4,
              background: '#fff1f2',
              border: '1px solid #fca5a5',
              color: '#9f1239',
              fontSize: '.88rem',
            }}
          >
            {errorMsg}
          </div>
        )}

        {successMsg && (
          <div
            role="status"
            data-testid="promote-modal-success"
            style={{
              marginBottom: '1rem',
              padding: '.6rem .9rem',
              borderRadius: 4,
              background: '#f0fdf4',
              border: '1px solid #86efac',
              color: '#166534',
              fontSize: '.88rem',
            }}
          >
            {successMsg}
          </div>
        )}

        <div style={{ display: 'flex', gap: '.75rem', justifyContent: 'flex-end' }}>
          <button
            data-testid="promote-modal-cancel"
            type="button"
            onClick={onCancel}
            disabled={isPending}
            style={{
              padding: '.45rem 1rem',
              border: '1px solid #cbd5e1',
              borderRadius: 4,
              background: '#fff',
              cursor: isPending ? 'not-allowed' : 'pointer',
              opacity: isPending ? 0.6 : 1,
              fontSize: '.9rem',
            }}
          >
            Cancel
          </button>
          <button
            data-testid="promote-modal-confirm"
            type="button"
            onClick={() => void handleConfirm()}
            disabled={isPending}
            style={{
              padding: '.45rem 1.1rem',
              border: 'none',
              borderRadius: 4,
              background: isPending ? '#d97706' : '#f59e0b',
              color: '#fff',
              fontWeight: 600,
              cursor: isPending ? 'not-allowed' : 'pointer',
              fontSize: '.9rem',
              display: 'inline-flex',
              alignItems: 'center',
              gap: '.4rem',
            }}
          >
            {isPending && (
              <span
                aria-hidden
                style={{
                  display: 'inline-block',
                  width: '0.85em',
                  height: '0.85em',
                  border: '2px solid rgba(255,255,255,0.4)',
                  borderTopColor: '#fff',
                  borderRadius: '50%',
                  animation: 'spin 0.7s linear infinite',
                }}
              />
            )}
            Confirm
          </button>
        </div>
      </div>
      <style>{`@keyframes spin { to { transform: rotate(360deg); } }`}</style>
    </div>
  )
}
