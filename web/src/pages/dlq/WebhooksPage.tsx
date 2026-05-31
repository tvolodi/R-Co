import { useMemo, useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { webhooksApi } from '@/api/dlq'
import { queryKeys } from '@/api/queryKeys'
import type { WebhookSubscription } from '@/types/api'

type WebhookStatus = 'ACTIVE' | 'PAUSED'

const EVENT_TYPE_OPTIONS = [
  { key: 'task.completed', label: 'Task completed' },
  { key: 'instance.started', label: 'Instance started' },
  { key: 'instance.completed', label: 'Instance completed' },
  { key: 'instance.errored', label: 'Instance errored' },
]

type WebhookFormState = {
  target_url: string
  selected_event_types: string[]
}

type NormalizedWebhookSubscription = {
  id: string
  target_url: string
  event_types: string[]
  status: WebhookStatus
  created_at: string
  paused_at?: string | null
}

function normalizeWebhook(item: WebhookSubscription): NormalizedWebhookSubscription | null {
  const id = item.subscription_id ?? item.id
  const targetUrl = item.target_url ?? item.url
  if (!id || !targetUrl) return null

  const status: WebhookStatus = item.status ?? (item.is_active === false ? 'PAUSED' : 'ACTIVE')
  return {
    id,
    target_url: targetUrl,
    event_types: item.event_types ?? [],
    status,
    created_at: item.created_at ?? item.updated_at ?? '',
    paused_at: item.paused_at,
  }
}

function parseListPayload(payload: { items?: WebhookSubscription[] } | WebhookSubscription[] | undefined): WebhookSubscription[] {
  if (!payload) return []
  return Array.isArray(payload) ? payload : (payload.items ?? [])
}

export default function WebhooksPage() {
  const qc = useQueryClient()
  const [creating, setCreating] = useState(false)
  const [form, setForm] = useState<WebhookFormState>({ target_url: '', selected_event_types: [] })
  const [statusFilter, setStatusFilter] = useState<string>('')
  const [searchFilter, setSearchFilter] = useState<string>('')
  const [formError, setFormError] = useState<string | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)
  const [createdSecretOnce, setCreatedSecretOnce] = useState<string | null>(null)

  const { data, isLoading, isError } = useQuery({
    queryKey: queryKeys.webhooks.list({ search: searchFilter, status: statusFilter }),
    queryFn: () => webhooksApi.list({
      search: searchFilter || undefined,
      status: statusFilter || undefined,
    }),
  })

  const rows = useMemo(
    () => parseListPayload(data)
      .map(normalizeWebhook)
      .filter((item): item is NormalizedWebhookSubscription => item !== null),
    [data],
  )

  const createWebhook = useMutation({
    mutationFn: () => webhooksApi.create({
      target_url: form.target_url.trim(),
      event_types: form.selected_event_types,
      secret: null,
    }),
    onMutate: () => {
      setFormError(null)
      setActionError(null)
    },
    onSuccess: (created) => {
      qc.invalidateQueries({ queryKey: queryKeys.webhooks.all })

      const secret = created.hmac_secret_once
      if (!secret || secret.length === 0) {
        setCreatedSecretOnce(null)
        setActionError('Subscription was created but the one-time secret was not returned. Please regenerate the subscription secret.')
      } else {
        setCreatedSecretOnce(secret)
      }

      setCreating(false)
      setForm({ target_url: '', selected_event_types: [] })
    },
    onError: () => {
      setFormError('Failed to create subscription. Check the URL and selected event types.')
    },
  })

  const updateWebhookStatus = useMutation({
    mutationFn: ({ id, nextStatus }: { id: string; nextStatus: WebhookStatus }) =>
      webhooksApi.update(id, {
        status: nextStatus,
        is_active: nextStatus === 'ACTIVE',
      }),
    onMutate: () => {
      setActionError(null)
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: queryKeys.webhooks.all })
    },
    onError: () => {
      setActionError('Unable to change webhook status. Please retry.')
    },
  })

  const canSubmit = form.target_url.trim().length > 0 && form.selected_event_types.length > 0

  const submitCreate = () => {
    if (!canSubmit) {
      setFormError('Target URL and at least one event type are required.')
      return
    }

    try {
      const parsed = new URL(form.target_url)
      if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') {
        setFormError('Target URL must start with http:// or https://')
        return
      }
    } catch {
      setFormError('Target URL is invalid.')
      return
    }

    createWebhook.mutate()
  }

  const toggleEventType = (eventType: string) => {
    setForm((previous) => {
      const hasValue = previous.selected_event_types.includes(eventType)
      return {
        ...previous,
        selected_event_types: hasValue
          ? previous.selected_event_types.filter((value) => value !== eventType)
          : [...previous.selected_event_types, eventType],
      }
    })
  }

  const dismissSecretPanel = () => {
    setCreatedSecretOnce(null)
  }

  const copySecret = async () => {
    if (!createdSecretOnce) return
    try {
      await navigator.clipboard.writeText(createdSecretOnce)
      setCreatedSecretOnce(null)
    } catch {
      setActionError('Clipboard copy failed. Copy the secret manually before closing this panel.')
    }
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

      <div style={{ display: 'flex', gap: '.6rem', flexWrap: 'wrap', marginBottom: '1rem' }}>
        <input
          value={searchFilter}
          onChange={(e) => setSearchFilter(e.target.value)}
          placeholder="Search by URL or event type"
          style={{ minWidth: '280px', padding: '.45rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px' }}
        />
        <select
          value={statusFilter}
          onChange={(e) => setStatusFilter(e.target.value)}
          style={{ padding: '.45rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px' }}
        >
          <option value="">All statuses</option>
          <option value="ACTIVE">Active</option>
          <option value="PAUSED">Paused</option>
        </select>
      </div>

      {createdSecretOnce && (
        <div
          style={{ background: '#fffbeb', border: '1px solid #f59e0b', borderRadius: '6px', padding: '1rem', marginBottom: '1rem' }}
          data-testid="webhook-secret-once-panel"
        >
          <h3 style={{ marginTop: 0, marginBottom: '.5rem' }}>One-time HMAC secret</h3>
          <p style={{ margin: '0 0 .75rem', fontSize: '.875rem', color: '#78350f' }}>
            This secret is shown once. Copy it now and store it securely.
          </p>
          <code
            style={{ display: 'block', padding: '.6rem .75rem', borderRadius: '4px', background: '#111827', color: '#f9fafb', marginBottom: '.75rem', overflowX: 'auto' }}
          >
            {createdSecretOnce}
          </code>
          <div style={{ display: 'flex', gap: '.5rem' }}>
            <button
              type="button"
              onClick={copySecret}
              style={{ padding: '.35rem .7rem', background: '#2563eb', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer' }}
            >
              Copy and dismiss
            </button>
            <button
              type="button"
              onClick={dismissSecretPanel}
              style={{ padding: '.35rem .7rem', background: '#6b7280', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer' }}
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
              value={form.target_url}
              onChange={(e) => setForm((previous) => ({ ...previous, target_url: e.target.value }))}
              placeholder="https://example.com/webhooks/bpm"
              style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px', fontSize: '.9rem', boxSizing: 'border-box' }}
            />
          </div>
          <fieldset style={{ border: '1px solid #cbd5e1', borderRadius: '6px', padding: '.7rem .9rem', marginBottom: '.75rem' }}>
            <legend style={{ fontSize: '.85rem', color: '#334155' }}>Event types</legend>
            <div style={{ display: 'grid', gap: '.4rem' }}>
              {EVENT_TYPE_OPTIONS.map((option) => (
                <label key={option.key} style={{ display: 'inline-flex', alignItems: 'center', gap: '.45rem', fontSize: '.875rem' }}>
                  <input
                    type="checkbox"
                    checked={form.selected_event_types.includes(option.key)}
                    onChange={() => toggleEventType(option.key)}
                  />
                  {option.label}
                </label>
              ))}
            </div>
          </fieldset>

          {formError && (
            <p style={{ marginTop: 0, marginBottom: '.6rem', color: '#dc2626', fontSize: '.85rem' }}>{formError}</p>
          )}

          <div style={{ display: 'flex', gap: '.5rem' }}>
            <button
              onClick={submitCreate}
              disabled={createWebhook.isPending}
              style={{ padding: '.4rem .9rem', background: '#16a34a', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
            >
              {createWebhook.isPending ? 'Saving...' : 'Save'}
            </button>
            <button
              onClick={() => {
                setCreating(false)
                setFormError(null)
              }}
              style={{ padding: '.4rem .9rem', background: '#6b7280', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
            >
              Cancel
            </button>
          </div>
        </div>
      )}

      {actionError && (
        <p style={{ color: '#dc2626', marginTop: 0, marginBottom: '.8rem' }}>{actionError}</p>
      )}

      {isLoading && <p>Loading…</p>}
      {isError && <p style={{ color: '#dc2626' }}>Failed to load webhook subscriptions.</p>}

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
          {rows.map((w) => (
            <tr key={w.id} style={{ borderBottom: '1px solid #e2e8f0', background: w.status === 'PAUSED' ? '#fff7ed' : '#fff' }}>
              <td style={{ padding: '.6rem .8rem', fontFamily: 'monospace', fontSize: '.8rem', maxWidth: '320px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{w.target_url}</td>
              <td style={{ padding: '.6rem .8rem', fontSize: '.8rem', color: '#64748b' }}>{w.event_types.join(', ') || '—'}</td>
              <td style={{ padding: '.6rem .8rem' }}>
                <span style={{ color: w.status === 'PAUSED' ? '#b45309' : '#16a34a', fontWeight: 700, fontSize: '.8rem' }}>{w.status}</span>
              </td>
              <td style={{ padding: '.6rem .8rem', fontSize: '.8rem', color: '#64748b' }}>{w.created_at ? new Date(w.created_at).toLocaleString() : '—'}</td>
              <td style={{ padding: '.6rem .8rem' }}>
                {w.status === 'PAUSED' ? (
                  <button
                    onClick={() => updateWebhookStatus.mutate({ id: w.id, nextStatus: 'ACTIVE' })}
                    style={{ padding: '.25rem .6rem', background: '#16a34a', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.8rem' }}
                  >
                    Resume
                  </button>
                ) : (
                  <button
                    onClick={() => updateWebhookStatus.mutate({ id: w.id, nextStatus: 'PAUSED' })}
                    style={{ padding: '.25rem .6rem', background: '#d97706', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.8rem' }}
                  >
                    Pause
                  </button>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
