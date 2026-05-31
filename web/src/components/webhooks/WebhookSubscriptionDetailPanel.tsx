import { useEffect, useMemo, useRef } from 'react'
import { useQuery } from '@tanstack/react-query'
import { webhooksApi } from '@/api/dlq'
import { queryKeys } from '@/api/queryKeys'
import { WebhookDeliveryAttemptsTable } from '@/components/webhooks/WebhookDeliveryAttemptsTable'
import type { WebhookSubscription } from '@/types/api'

interface WebhookSubscriptionDetailPanelProps {
  subscription: WebhookSubscription
  isOpen: boolean
  onClose: () => void
}

function resolveSubscriptionId(subscription: WebhookSubscription): string {
  return subscription.subscription_id ?? subscription.id
}

function resolveTargetUrl(subscription: WebhookSubscription): string {
  return subscription.target_url ?? subscription.url ?? '—'
}

function resolveStatus(subscription: WebhookSubscription): 'ACTIVE' | 'PAUSED' {
  if (subscription.status === 'ACTIVE' || subscription.status === 'PAUSED') return subscription.status
  return subscription.is_active === false ? 'PAUSED' : 'ACTIVE'
}

function formatTimestamp(value?: string | null): string {
  if (!value) return '—'
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) return value
  return parsed.toLocaleString()
}

export function WebhookSubscriptionDetailPanel({
  subscription,
  isOpen,
  onClose,
}: WebhookSubscriptionDetailPanelProps) {
  const closeButtonRef = useRef<HTMLButtonElement | null>(null)
  const subscriptionId = resolveSubscriptionId(subscription)

  const deliveriesQuery = useQuery({
    queryKey: queryKeys.webhooks.deliveries(subscriptionId, 20),
    queryFn: () => webhooksApi.getDeliveries(subscriptionId, { limit: 20 }),
    enabled: isOpen,
  })

  useEffect(() => {
    if (!isOpen) return undefined

    closeButtonRef.current?.focus()

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        onClose()
      }
    }

    document.addEventListener('keydown', handleKeyDown)
    return () => {
      document.removeEventListener('keydown', handleKeyDown)
    }
  }, [isOpen, onClose])

  const eventTypes = useMemo(() => {
    if (!subscription.event_types || subscription.event_types.length === 0) return '—'
    return subscription.event_types.join(', ')
  }, [subscription.event_types])

  if (!isOpen) return null

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby="webhook-detail-title"
      data-testid="webhook-subscription-detail-panel"
      style={{
        position: 'fixed',
        inset: 0,
        background: 'rgba(15, 23, 42, 0.35)',
        display: 'flex',
        justifyContent: 'flex-end',
        zIndex: 1000,
      }}
      onClick={onClose}
    >
      <aside
        onClick={(event) => event.stopPropagation()}
        style={{
          width: 'min(560px, 100vw)',
          height: '100%',
          background: '#ffffff',
          boxShadow: '-12px 0 32px rgba(15, 23, 42, 0.18)',
          padding: '1.25rem',
          overflowY: 'auto',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: '.75rem', marginBottom: '1rem' }}>
          <div>
            <h3 id="webhook-detail-title" style={{ margin: 0 }}>Subscription details</h3>
            <p style={{ margin: '.3rem 0 0', color: '#64748b', fontSize: '.85rem' }}>
              Recent delivery attempts for the selected subscription.
            </p>
          </div>
          <button
            ref={closeButtonRef}
            onClick={onClose}
            style={{
              marginLeft: 'auto',
              border: '1px solid #cbd5e1',
              background: '#fff',
              borderRadius: '6px',
              padding: '.45rem .8rem',
              cursor: 'pointer',
            }}
          >
            Close
          </button>
        </div>

        <section
          data-testid="webhook-subscription-summary"
          style={{
            border: '1px solid #e2e8f0',
            borderRadius: '10px',
            padding: '1rem',
            marginBottom: '1rem',
            background: '#f8fafc',
          }}
        >
          <dl style={{ display: 'grid', gridTemplateColumns: 'minmax(120px, 160px) 1fr', rowGap: '.65rem', columnGap: '.75rem', margin: 0 }}>
            <dt style={{ color: '#475569', fontWeight: 600 }}>Target URL</dt>
            <dd style={{ margin: 0, fontFamily: 'monospace', wordBreak: 'break-word' }}>{resolveTargetUrl(subscription)}</dd>

            <dt style={{ color: '#475569', fontWeight: 600 }}>Status</dt>
            <dd style={{ margin: 0, color: resolveStatus(subscription) === 'PAUSED' ? '#c2410c' : '#166534', fontWeight: 700 }}>
              {resolveStatus(subscription)}
            </dd>

            <dt style={{ color: '#475569', fontWeight: 600 }}>Event types</dt>
            <dd style={{ margin: 0 }}>{eventTypes}</dd>

            <dt style={{ color: '#475569', fontWeight: 600 }}>Created</dt>
            <dd style={{ margin: 0 }}>{formatTimestamp(subscription.created_at)}</dd>
          </dl>
        </section>

        <section>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '.75rem' }}>
            <div>
              <h4 style={{ margin: 0 }}>Recent delivery attempts</h4>
              <p style={{ margin: '.25rem 0 0', color: '#64748b', fontSize: '.82rem' }}>
                Status, response code, and timestamp for the latest webhook deliveries.
              </p>
            </div>
            <button
              onClick={() => void deliveriesQuery.refetch()}
              style={{
                border: '1px solid #cbd5e1',
                background: '#fff',
                borderRadius: '6px',
                padding: '.4rem .7rem',
                cursor: 'pointer',
                fontSize: '.82rem',
              }}
            >
              Retry
            </button>
          </div>

          {deliveriesQuery.isLoading ? (
            <div data-testid="webhook-delivery-loading" style={{ padding: '1rem', border: '1px dashed #cbd5e1', borderRadius: '8px', color: '#475569' }}>
              Loading delivery attempts…
            </div>
          ) : null}

          {deliveriesQuery.isError ? (
            <div
              data-testid="webhook-delivery-error"
              style={{ border: '1px solid #fecaca', background: '#fef2f2', borderRadius: '8px', padding: '1rem', color: '#991b1b' }}
            >
              <strong>Unable to load delivery attempts.</strong>
              <div style={{ marginTop: '.35rem', fontSize: '.85rem' }}>
                {deliveriesQuery.error instanceof Error ? deliveriesQuery.error.message : 'WebhookDeliveryLogLoadFailed'}
              </div>
            </div>
          ) : null}

          {!deliveriesQuery.isLoading && !deliveriesQuery.isError && deliveriesQuery.data && deliveriesQuery.data.items.length === 0 ? (
            <div
              data-testid="webhook-delivery-empty"
              style={{ border: '1px dashed #cbd5e1', background: '#f8fafc', borderRadius: '8px', padding: '1rem', color: '#475569' }}
            >
              No delivery attempts recorded yet.
            </div>
          ) : null}

          {!deliveriesQuery.isLoading && !deliveriesQuery.isError && deliveriesQuery.data && deliveriesQuery.data.items.length > 0 ? (
            <WebhookDeliveryAttemptsTable attempts={deliveriesQuery.data.items} />
          ) : null}
        </section>
      </aside>
    </div>
  )
}