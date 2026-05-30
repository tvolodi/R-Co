import { useMemo, useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { tokensApi, usersApi } from '@/api/identity'
import { queryKeys } from '@/api/queryKeys'
import type { ApiToken, IssuedToken, User } from '@/types/api'

type TokenRow = ApiToken & {
  token_id?: string
  user_display_name?: string
  user_id?: string
  roles?: string[]
  status?: 'ACTIVE' | 'REVOKED' | 'EXPIRED'
}

function tokenId(token: TokenRow): string {
  return token.token_id ?? token.id ?? ''
}

function tokenUserLabel(token: TokenRow, usersById: Map<string, User>): string {
  const userId = token.user_id ?? ''
  if (token.user_display_name) return token.user_display_name
  const user = usersById.get(userId)
  if (user) return `${user.display_name} <${user.email}>`
  return userId || 'Unknown user'
}

function tokenRoleLabel(token: TokenRow): string {
  return (token.roles ?? []).join(', ')
}

function formatDate(value?: string | null): string {
  if (!value) return 'Never'
  const parsed = new Date(value)
  return Number.isNaN(parsed.getTime()) ? value : parsed.toLocaleDateString()
}

export default function TokensPage() {
  const qc = useQueryClient()
  const [creating, setCreating] = useState(false)
  const [form, setForm] = useState({ user_id: '', roles: '', expires_at: '' })
  const [issuedToken, setIssuedToken] = useState<IssuedToken | null>(null)
  const [createError, setCreateError] = useState('')
  const [pendingRevoke, setPendingRevoke] = useState<TokenRow | null>(null)
  const [copyState, setCopyState] = useState('')

  const { data: tokenList, isLoading } = useQuery({
    queryKey: queryKeys.admin.tokens(),
    queryFn: () => tokensApi.list(),
  })

  const { data: users } = useQuery({
    queryKey: queryKeys.admin.users({ page_size: 200 }),
    queryFn: () => usersApi.list({ page_size: 200 }),
  })

  const tokenItems = useMemo(() => (tokenList?.items ?? []) as TokenRow[], [tokenList?.items])
  const usersById = useMemo(() => new Map((users?.items ?? []).map((user) => [user.id ?? user.user_id ?? '', user])), [users?.items])

  const createToken = useMutation({
    mutationFn: () => {
      const roles = form.roles.split(',').map((role) => role.trim()).filter(Boolean)
      if (!form.user_id) throw new Error('Select a target user')
      if (roles.length === 0) throw new Error('Enter at least one role')
      return tokensApi.create({
        user_id: form.user_id,
        roles,
        expires_at: form.expires_at || undefined,
      })
    },
    onSuccess: (res) => {
      qc.invalidateQueries({ queryKey: queryKeys.admin.tokens() })
      setIssuedToken(res)
      setCreating(false)
      setCreateError('')
      setForm({ user_id: '', roles: '', expires_at: '' })
    },
    onError: (error) => setCreateError((error as Error).message),
  })

  const revokeToken = useMutation({
    mutationFn: (id: string) => tokensApi.revoke(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: queryKeys.admin.tokens() }),
  })

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>API Tokens</h2>
        <button
          onClick={() => { setCreating(true); setIssuedToken(null); setCreateError('') }}
          style={{ marginLeft: 'auto', padding: '.4rem .9rem', background: '#2563eb', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
        >
          + Issue token
        </button>
      </div>

      {issuedToken && (
        <div role="dialog" aria-modal="true" aria-label="Issued token" style={{ background: '#f0fdf4', border: '1px solid #bbf7d0', borderRadius: '6px', padding: '1rem', marginBottom: '1.25rem' }}>
          <p style={{ fontWeight: 600, marginBottom: '.5rem', color: '#15803d' }}>This value will not be shown again.</p>
          <code data-testid="issued-token-value" style={{ fontSize: '.85rem', wordBreak: 'break-all', display: 'block', marginBottom: '.75rem' }}>{issuedToken.token_value}</code>
          <div style={{ display: 'flex', gap: '.5rem', flexWrap: 'wrap' }}>
            <button
              type="button"
              onClick={() => {
                void navigator.clipboard.writeText(issuedToken.token_value)
                setCopyState('Copied')
              }}
              style={{ padding: '.35rem .8rem', background: '#2563eb', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer' }}
            >
              Copy token
            </button>
            <button
              type="button"
              onClick={() => setIssuedToken(null)}
              style={{ padding: '.35rem .8rem', background: '#e2e8f0', border: 'none', borderRadius: '4px', cursor: 'pointer' }}
            >
              Close
            </button>
            {copyState && <span style={{ alignSelf: 'center', color: '#166534', fontSize: '.875rem' }}>{copyState}</span>}
          </div>
        </div>
      )}

      {creating && (
        <div style={{ background: '#f8fafc', border: '1px solid #e2e8f0', borderRadius: '6px', padding: '1.25rem', marginBottom: '1.25rem' }}>
          <h3 style={{ margin: '0 0 1rem' }}>Issue token</h3>
          {createError && <p role="alert" style={{ marginTop: 0, color: '#dc2626', fontSize: '.875rem' }}>{createError}</p>}
          <div style={{ marginBottom: '.75rem' }}>
            <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>Target user</label>
            <select value={form.user_id} onChange={(e) => setForm((p) => ({ ...p, user_id: e.target.value }))}
              style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px', fontSize: '.9rem', boxSizing: 'border-box' }}>
              <option value="">Select a user</option>
              {(users?.items ?? []).map((user) => {
                const id = user.id ?? user.user_id ?? ''
                return <option key={id} value={id}>{user.display_name} ({user.email})</option>
              })}
            </select>
          </div>
          <div style={{ marginBottom: '.75rem' }}>
            <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>Role set</label>
            <input value={form.roles} onChange={(e) => setForm((p) => ({ ...p, roles: e.target.value }))}
              placeholder="Comma-separated roles"
              style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px', fontSize: '.9rem', boxSizing: 'border-box' }} />
          </div>
          <div style={{ marginBottom: '.75rem' }}>
            <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>Expiry date</label>
            <input type="datetime-local" value={form.expires_at} onChange={(e) => setForm((p) => ({ ...p, expires_at: e.target.value }))}
              style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px', fontSize: '.9rem', boxSizing: 'border-box' }} />
          </div>
          <p style={{ marginTop: 0, color: '#64748b', fontSize: '.875rem' }}>The generated value is shown once and can be copied from the confirmation dialog.</p>
          <div style={{ display: 'flex', gap: '.5rem' }}>
            <button onClick={() => createToken.mutate()} style={{ padding: '.4rem .9rem', background: '#16a34a', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}>Issue token</button>
            <button onClick={() => { setCreating(false); setCreateError('') }} style={{ padding: '.4rem .9rem', background: '#6b7280', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}>Cancel</button>
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
          {tokenItems.map((token) => {
            const id = tokenId(token)
            const revoked = Boolean(token.revoked_at)
            return (
            <tr key={id} style={{ borderBottom: '1px solid #e2e8f0', textDecoration: revoked ? 'line-through' : 'none', opacity: revoked ? 0.75 : 1 }}>
              <td style={{ padding: '.6rem .8rem' }}>{tokenUserLabel(token, usersById)}</td>
              <td style={{ padding: '.6rem .8rem', fontSize: '.8rem', color: '#64748b' }}>{tokenRoleLabel(token)}</td>
              <td style={{ padding: '.6rem .8rem', fontSize: '.8rem', color: '#64748b' }}>{formatDate(token.expires_at)}</td>
              <td style={{ padding: '.6rem .8rem', fontSize: '.8rem', color: '#64748b' }}>{formatDate(token.created_at)}</td>
              <td style={{ padding: '.6rem .8rem', fontSize: '.8rem', color: '#64748b' }}>{formatDate(token.revoked_at)}</td>
              <td style={{ padding: '.6rem .8rem' }}>
                <span style={{ color: revoked ? '#9ca3af' : '#16a34a', fontWeight: 600, fontSize: '.8rem' }}>
                  {token.status ?? (revoked ? 'REVOKED' : 'ACTIVE')}
                </span>
              </td>
              <td style={{ padding: '.6rem .8rem' }}>
                {!revoked && (
                  <button
                    onClick={() => setPendingRevoke(token)}
                    style={{ padding: '.25rem .6rem', background: '#dc2626', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.8rem' }}
                  >
                    Revoke
                  </button>
                )}
              </td>
            </tr>
            )
          })}
        </tbody>
      </table>

      {pendingRevoke && (
        <div role="dialog" aria-modal="true" aria-label="Revoke token" style={{ position: 'fixed', inset: 0, background: 'rgba(15, 23, 42, .45)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '1rem', zIndex: 40 }}>
          <div style={{ background: '#fff', width: 'min(520px, 100%)', borderRadius: '12px', padding: '1.25rem' }}>
            <h3 style={{ marginTop: 0 }}>Revoke token?</h3>
            <p style={{ color: '#475569' }}>Revoking this API token immediately removes access for the associated user and roles.</p>
            <div style={{ display: 'flex', gap: '.5rem', justifyContent: 'flex-end' }}>
              <button type="button" onClick={() => setPendingRevoke(null)} style={{ padding: '.45rem .8rem', background: '#e2e8f0', border: 'none', borderRadius: '4px', cursor: 'pointer' }}>Cancel</button>
              <button
                type="button"
                onClick={() => {
                  revokeToken.mutate(tokenId(pendingRevoke))
                  setPendingRevoke(null)
                }}
                style={{ padding: '.45rem .8rem', background: '#dc2626', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer' }}
              >
                Revoke token
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
