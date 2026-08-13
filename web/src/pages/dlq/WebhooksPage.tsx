import { useEffect, useMemo, useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useSearchParams } from 'react-router-dom'
import { webhooksApi } from '@/api/dlq'
import { queryKeys } from '@/api/queryKeys'
import { WebhookSubscriptionDetailPanel } from '@/components/webhooks/WebhookSubscriptionDetailPanel'
import type { WebhookSubscription } from '@/types/api'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'

type CreateFormState = {
  targetUrl: string
  secret: string
  eventTypes: string[]
}

const EVENT_OPTIONS: Array<{ value: string; label: string }> = [
  { value: 'task.completed', label: 'Task completed' },
  { value: 'instance.started', label: 'Instance started' },
  { value: 'instance.completed', label: 'Instance completed' },
  { value: 'instance.errored', label: 'Instance errored' },
]

function resolveSubscriptionId(item: WebhookSubscription): string {
  return item.subscription_id ?? item.id
}

function resolveTargetUrl(item: WebhookSubscription): string {
  return item.target_url ?? item.url ?? ''
}

function resolveStatus(item: WebhookSubscription): 'ACTIVE' | 'PAUSED' {
  if (item.status === 'ACTIVE' || item.status === 'PAUSED') return item.status
  return item.is_active === false ? 'PAUSED' : 'ACTIVE'
}

function isValidHttpUrl(value: string): boolean {
  try {
    const url = new URL(value)
    return url.protocol === 'http:' || url.protocol === 'https:'
  } catch {
    return false
  }
}

export default function WebhooksPage() {
  const qc = useQueryClient()
  const [searchParams, setSearchParams] = useSearchParams()
  const [creating, setCreating] = useState(false)
  const [form, setForm] = useState<CreateFormState>({ targetUrl: '', secret: '', eventTypes: [] })
  const [formError, setFormError] = useState<string | null>(null)
  const [oneTimeSecret, setOneTimeSecret] = useState<string | null>(null)

  const { data, isLoading, isError, error, refetch } = useQuery({
    queryKey: queryKeys.webhooks.list(),
    queryFn: () => webhooksApi.list(),
  })

  const subscriptions = useMemo(() => data?.items ?? [], [data])
  const selectedSubscriptionId = searchParams.get('subscription')
  const selectedSubscription = useMemo(
    () => subscriptions.find((item) => resolveSubscriptionId(item) === selectedSubscriptionId) ?? null,
    [selectedSubscriptionId, subscriptions],
  )

  useEffect(() => {
    if (!selectedSubscriptionId || isLoading) return
    if (selectedSubscription) return

    const nextParams = new URLSearchParams(searchParams)
    nextParams.delete('subscription')
    setSearchParams(nextParams, { replace: true })
  }, [isLoading, searchParams, selectedSubscription, selectedSubscriptionId, setSearchParams])

  const createWebhook = useMutation({
    mutationFn: () => webhooksApi.create({
      target_url: form.targetUrl,
      secret: form.secret.trim() ? form.secret : null,
      event_types: form.eventTypes,
    }),
    onSuccess: (created) => {
      qc.invalidateQueries({ queryKey: queryKeys.webhooks.list() })
      setCreating(false)
      setForm({ targetUrl: '', secret: '', eventTypes: [] })
      setFormError(null)
      setOneTimeSecret(created.hmac_secret_once ?? null)
    },
  })

  const updateWebhook = useMutation({
    mutationFn: ({ id, nextStatus }: { id: string; nextStatus: 'ACTIVE' | 'PAUSED' }) =>
      webhooksApi.update(id, { status: nextStatus, is_active: nextStatus === 'ACTIVE' }),
    onSuccess: () => qc.invalidateQueries({ queryKey: queryKeys.webhooks.list() }),
  })

  const deleteWebhook = useMutation({
    mutationFn: (id: string) => webhooksApi.delete(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: queryKeys.webhooks.list() }),
  })

  const handleToggleEventType = (eventType: string): void => {
    setForm((previous) => {
      if (previous.eventTypes.includes(eventType)) {
        return {
          ...previous,
          eventTypes: previous.eventTypes.filter((value) => value !== eventType),
        }
      }
      return {
        ...previous,
        eventTypes: [...previous.eventTypes, eventType],
      }
    })
  }

  const handleCreate = (): void => {
    if (!form.targetUrl.trim() || form.eventTypes.length === 0) {
      setFormError('Target URL and at least one event type are required.')
      return
    }

    if (!isValidHttpUrl(form.targetUrl.trim())) {
      setFormError('Target URL is invalid.')
      return
    }

    setFormError(null)
    createWebhook.mutate()
  }

  const handleCopyAndDismiss = async (): Promise<void> => {
    if (oneTimeSecret) {
      try {
        await navigator.clipboard.writeText(oneTimeSecret)
      } catch {
        // Clipboard write can fail in restricted contexts; dismiss still proceeds.
      }
    }
    setOneTimeSecret(null)
  }

  const openDetails = (subscriptionId: string): void => {
    const params = new URLSearchParams(searchParams)
    params.set('subscription', subscriptionId)
    setSearchParams(params)
  }

  const closeDetails = (): void => {
    const params = new URLSearchParams(searchParams)
    params.delete('subscription')
    setSearchParams(params)
  }

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Webhook Subscriptions</h2>
        <button
          onClick={() => setCreating(true)}
          style={{ marginLeft: 'auto', padding: '.4rem .9rem', background: '#2563eb', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
        >
          + New Subscription
        </button>
      </div>

      {oneTimeSecret && (
        <div
          data-testid="webhook-secret-once-panel"
          style={{
            background: '#ecfeff',
            border: '1px solid #a5f3fc',
            borderRadius: '6px',
            padding: '1rem',
            marginBottom: '1.25rem',
          }}
        >
          <h3 style={{ margin: '0 0 .5rem' }}>One-time HMAC secret</h3>
          <p style={{ margin: '0 0 .5rem', color: '#155e75', fontSize: '.85rem' }}>
            Copy this value now. It is shown only once after subscription creation.
          </p>
          <code style={{ display: 'block', background: '#cffafe', padding: '.45rem .6rem', borderRadius: '4px', marginBottom: '.75rem' }}>
            {oneTimeSecret}
          </code>
          <div style={{ display: 'flex', gap: '.5rem' }}>
            <button
              onClick={() => { void handleCopyAndDismiss() }}
              style={{ padding: '.4rem .9rem', background: '#0891b2', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
            >
              Copy and dismiss
            </button>
            <button
              onClick={() => setOneTimeSecret(null)}
              style={{ padding: '.4rem .9rem', background: '#6b7280', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
            >
              Dismiss
            </button>
          </div>
        </div>
      )}

      {creating && (
        <div style={{ background: '#f8fafc', border: '1px solid #e2e8f0', borderRadius: '6px', padding: '1.25rem', marginBottom: '1.25rem' }}>
          <h3 style={{ margin: '0 0 1rem' }}>Create subscription</h3>

          <div style={{ marginBottom: '.75rem' }}>
            <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>Target URL</label>
            <input
              value={form.targetUrl}
              onChange={(e) => setForm((previous) => ({ ...previous, targetUrl: e.target.value }))}
              placeholder="https://example.com/webhooks/bpm"
              style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px', fontSize: '.9rem', boxSizing: 'border-box' }}
            />
          </div>

          <div style={{ marginBottom: '.75rem' }}>
            <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>HMAC secret (optional)</label>
            <input
              value={form.secret}
              onChange={(e) => setForm((previous) => ({ ...previous, secret: e.target.value }))}
              placeholder="Leave empty to auto-generate"
              style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px', fontSize: '.9rem', boxSizing: 'border-box' }}
            />
          </div>

          <fieldset style={{ margin: '0 0 .75rem', border: '1px solid #cbd5e1', borderRadius: '4px', padding: '.65rem .75rem' }}>
            <legend style={{ fontSize: '.85rem', fontWeight: 600, padding: '0 .25rem' }}>Event types</legend>
            <div style={{ display: 'grid', gap: '.4rem' }}>
              {EVENT_OPTIONS.map((eventOption) => (
                <label key={eventOption.value} style={{ display: 'flex', alignItems: 'center', gap: '.5rem', fontSize: '.85rem' }}>
                  <input
                    type="checkbox"
                    checked={form.eventTypes.includes(eventOption.value)}
                    onChange={() => handleToggleEventType(eventOption.value)}
                  />
                  {eventOption.label}
                </label>
              ))}
            </div>
          </fieldset>

          {formError && (
            <p style={{ margin: '0 0 .75rem', color: '#dc2626', fontSize: '.85rem', fontWeight: 600 }}>
              {formError}
            </p>
          )}

          <div style={{ display: 'flex', gap: '.5rem' }}>
            <button onClick={handleCreate} style={{ padding: '.4rem .9rem', background: '#16a34a', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}>Save</button>
            <button onClick={() => setCreating(false)} style={{ padding: '.4rem .9rem', background: '#6b7280', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}>Cancel</button>
          </div>
        </div>
      )}

      <QueryStateBoundary
        state={(isLoading ? 'loading' : isError ? classifyError(error) : 'success') as RendererState}
        onRetry={() => { void refetch() }}
        columns={[{ widthPercent: 35 }, { widthPercent: 25 }, { widthPercent: 10 }, { widthPercent: 15 }, { widthPercent: 15 }]}
      >
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.875rem' }}>
        <thead>
          <tr style={{ background: '#f1f5f9', textAlign: 'left' }}>
            <th style={{ padding: '.6rem .8rem' }}>Target URL</th>
            <th style={{ padding: '.6rem .8rem' }}>Event types</th>
            <th style={{ padding: '.6rem .8rem' }}>Status</th>
            <th style={{ padding: '.6rem .8rem' }}>Created</th>
            <th style={{ padding: '.6rem .8rem' }}>Actions</th>
          </tr>
        </thead>
        <tbody>
          {subscriptions.map((w: WebhookSubscription) => {
            const id = resolveSubscriptionId(w)
            const targetUrl = resolveTargetUrl(w)
            const status = resolveStatus(w)
            const isPaused = status === 'PAUSED'
            const nextStatus: 'ACTIVE' | 'PAUSED' = isPaused ? 'ACTIVE' : 'PAUSED'

            return (
            <tr key={id} style={{ borderBottom: '1px solid #e2e8f0', background: isPaused ? '#fff7ed' : '#ffffff' }}>
              <td style={{ padding: '.6rem .8rem', fontFamily: 'monospace', fontSize: '.8rem', maxWidth: '320px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{targetUrl || '—'}</td>
              <td style={{ padding: '.6rem .8rem', fontSize: '.8rem', color: '#64748b' }}>{w.event_types?.join(', ') ?? '—'}</td>
              <td style={{ padding: '.6rem .8rem' }}>
                <span style={{ color: isPaused ? '#c2410c' : '#166534', fontWeight: 600, fontSize: '.8rem' }}>{status}</span>
              </td>
              <td style={{ padding: '.6rem .8rem', fontSize: '.8rem', color: '#64748b' }}>
                {new Date(w.created_at).toLocaleString()}
              </td>
              <td style={{ padding: '.6rem .8rem' }}>
                <button
                  onClick={() => openDetails(id)}
                  style={{ padding: '.25rem .6rem', marginRight: '.4rem', background: '#e2e8f0', color: '#0f172a', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.8rem' }}
                >
                  View details
                </button>
                <button
                  onClick={() => updateWebhook.mutate({ id, nextStatus })}
                  style={{ padding: '.25rem .6rem', marginRight: '.4rem', background: '#0f766e', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.8rem' }}
                >
                  {isPaused ? 'Resume' : 'Pause'}
                </button>
                <button
                  onClick={() => deleteWebhook.mutate(id)}
                  style={{ padding: '.25rem .6rem', background: '#dc2626', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.8rem' }}
                >
                  Delete
                </button>
              </td>
            </tr>
            )
          })}
        </tbody>
      </table>
      </QueryStateBoundary>

      {selectedSubscription ? (
        <WebhookSubscriptionDetailPanel
          subscription={selectedSubscription}
          isOpen={true}
          onClose={closeDetails}
        />
      ) : null}
    </div>
  )
}
