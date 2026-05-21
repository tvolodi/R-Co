import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { webhooksApi } from '@/api/dlq'
import type { WebhookSubscription } from '@/types/api'

export default function WebhooksPage() {
  const qc = useQueryClient()
  const [creating, setCreating] = useState(false)
  const [form, setForm] = useState({ url: '', secret: '', event_types: '' })

  const { data, isLoading } = useQuery({
    queryKey: ['webhooks'],
    queryFn: () => webhooksApi.list(),
  })

  const createWebhook = useMutation({
    mutationFn: () => webhooksApi.create({
      url: form.url,
      secret: form.secret,
      event_types: form.event_types.split(',').map((s) => s.trim()).filter(Boolean),
    }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['webhooks'] })
      setCreating(false)
      setForm({ url: '', secret: '', event_types: '' })
    },
  })

  const deleteWebhook = useMutation({
    mutationFn: (id: string) => webhooksApi.delete(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['webhooks'] }),
  })

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

      {creating && (
        <div style={{ background: '#f8fafc', border: '1px solid #e2e8f0', borderRadius: '6px', padding: '1.25rem', marginBottom: '1.25rem' }}>
          <h3 style={{ margin: '0 0 1rem' }}>Create subscription</h3>
          {[
            { key: 'url', label: 'URL', placeholder: 'https://…' },
            { key: 'secret', label: 'HMAC secret', placeholder: '…' },
            { key: 'event_types', label: 'Event types (comma-separated)', placeholder: 'INSTANCE_STARTED, TASK_COMPLETED' },
          ].map(({ key, label, placeholder }) => (
            <div key={key} style={{ marginBottom: '.75rem' }}>
              <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>{label}</label>
              <input
                value={form[key as keyof typeof form]}
                onChange={(e) => setForm((p) => ({ ...p, [key]: e.target.value }))}
                placeholder={placeholder}
                style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px', fontSize: '.9rem', boxSizing: 'border-box' }}
              />
            </div>
          ))}
          <div style={{ display: 'flex', gap: '.5rem' }}>
            <button onClick={() => createWebhook.mutate()} style={{ padding: '.4rem .9rem', background: '#16a34a', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}>Save</button>
            <button onClick={() => setCreating(false)} style={{ padding: '.4rem .9rem', background: '#6b7280', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}>Cancel</button>
          </div>
        </div>
      )}

      {isLoading && <p>Loading…</p>}

      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.875rem' }}>
        <thead>
          <tr style={{ background: '#f1f5f9', textAlign: 'left' }}>
            <th style={{ padding: '.6rem .8rem' }}>URL</th>
            <th style={{ padding: '.6rem .8rem' }}>Event types</th>
            <th style={{ padding: '.6rem .8rem' }}>Active</th>
            <th style={{ padding: '.6rem .8rem' }}>Actions</th>
          </tr>
        </thead>
        <tbody>
          {(data?.items ?? []).map((w: WebhookSubscription) => (
            <tr key={w.id} style={{ borderBottom: '1px solid #e2e8f0' }}>
              <td style={{ padding: '.6rem .8rem', fontFamily: 'monospace', fontSize: '.8rem', maxWidth: '320px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{w.url}</td>
              <td style={{ padding: '.6rem .8rem', fontSize: '.8rem', color: '#64748b' }}>{w.event_types.join(', ')}</td>
              <td style={{ padding: '.6rem .8rem' }}>
                <span style={{ color: w.is_active ? '#16a34a' : '#9ca3af', fontWeight: 600, fontSize: '.8rem' }}>{w.is_active ? 'Yes' : 'No'}</span>
              </td>
              <td style={{ padding: '.6rem .8rem' }}>
                <button
                  onClick={() => deleteWebhook.mutate(w.id)}
                  style={{ padding: '.25rem .6rem', background: '#dc2626', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.8rem' }}
                >
                  Delete
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
