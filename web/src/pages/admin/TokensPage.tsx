import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { tokensApi } from '@/api/identity'
import type { ApiToken } from '@/types/api'

export default function TokensPage() {
  const qc = useQueryClient()
  const [creating, setCreating] = useState(false)
  const [form, setForm] = useState({ name: '', expires_at: '' })
  const [newToken, setNewToken] = useState<string | null>(null)

  const { data: tokenList, isLoading } = useQuery({
    queryKey: ['admin', 'tokens'],
    queryFn: () => tokensApi.list(),
  })
  const data = { items: tokenList ?? [] }

  const createToken = useMutation({
    mutationFn: () => tokensApi.create(form.name, form.expires_at || undefined),
    onSuccess: (res) => {
      qc.invalidateQueries({ queryKey: ['admin', 'tokens'] })
      setNewToken((res as { token: string }).token)
      setCreating(false)
      setForm({ name: '', expires_at: '' })
    },
  })

  const revokeToken = useMutation({
    mutationFn: (id: string) => tokensApi.revoke(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['admin', 'tokens'] }),
  })

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>API Tokens</h2>
        <button
          onClick={() => { setCreating(true); setNewToken(null) }}
          style={{ marginLeft: 'auto', padding: '.4rem .9rem', background: '#2563eb', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
        >
          + New Token
        </button>
      </div>

      {newToken && (
        <div style={{ background: '#f0fdf4', border: '1px solid #bbf7d0', borderRadius: '6px', padding: '1rem', marginBottom: '1.25rem' }}>
          <p style={{ fontWeight: 600, marginBottom: '.5rem', color: '#15803d' }}>Token created — copy it now, it won't be shown again.</p>
          <code style={{ fontSize: '.85rem', wordBreak: 'break-all' }}>{newToken}</code>
        </div>
      )}

      {creating && (
        <div style={{ background: '#f8fafc', border: '1px solid #e2e8f0', borderRadius: '6px', padding: '1.25rem', marginBottom: '1.25rem' }}>
          <h3 style={{ margin: '0 0 1rem' }}>Create API token</h3>
          <div style={{ marginBottom: '.75rem' }}>
            <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>Name</label>
            <input value={form.name} onChange={(e) => setForm((p) => ({ ...p, name: e.target.value }))}
              style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px', fontSize: '.9rem', boxSizing: 'border-box' }} />
          </div>
          <div style={{ marginBottom: '.75rem' }}>
            <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>Expires at (optional)</label>
            <input type="datetime-local" value={form.expires_at} onChange={(e) => setForm((p) => ({ ...p, expires_at: e.target.value }))}
              style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px', fontSize: '.9rem', boxSizing: 'border-box' }} />
          </div>
          <div style={{ display: 'flex', gap: '.5rem' }}>
            <button onClick={() => createToken.mutate()} style={{ padding: '.4rem .9rem', background: '#16a34a', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}>Create</button>
            <button onClick={() => setCreating(false)} style={{ padding: '.4rem .9rem', background: '#6b7280', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}>Cancel</button>
          </div>
        </div>
      )}

      {isLoading && <p>Loading…</p>}

      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.9rem' }}>
        <thead>
          <tr style={{ background: '#f1f5f9', textAlign: 'left' }}>
            <th style={{ padding: '.6rem .8rem' }}>Name</th>
            <th style={{ padding: '.6rem .8rem' }}>Created</th>
            <th style={{ padding: '.6rem .8rem' }}>Expires</th>
            <th style={{ padding: '.6rem .8rem' }}>Status</th>
            <th style={{ padding: '.6rem .8rem' }}>Actions</th>
          </tr>
        </thead>
        <tbody>
          {(data?.items ?? []).map((t: ApiToken) => (
            <tr key={t.id} style={{ borderBottom: '1px solid #e2e8f0' }}>
              <td style={{ padding: '.6rem .8rem' }}>{t.name}</td>
              <td style={{ padding: '.6rem .8rem', fontSize: '.8rem', color: '#64748b' }}>{new Date(t.created_at).toLocaleDateString()}</td>
              <td style={{ padding: '.6rem .8rem', fontSize: '.8rem', color: '#64748b' }}>{t.expires_at ? new Date(t.expires_at).toLocaleDateString() : 'Never'}</td>
              <td style={{ padding: '.6rem .8rem' }}>
                <span style={{ color: t.revoked_at ? '#9ca3af' : '#16a34a', fontWeight: 600, fontSize: '.8rem' }}>
                  {t.revoked_at ? 'Revoked' : 'Active'}
                </span>
              </td>
              <td style={{ padding: '.6rem .8rem' }}>
                {!t.revoked_at && (
                  <button
                    onClick={() => revokeToken.mutate(t.id)}
                    style={{ padding: '.25rem .6rem', background: '#dc2626', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.8rem' }}
                  >
                    Revoke
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
