import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { usersApi, rolesApi } from '@/api/identity'
import { queryKeys } from '@/api/queryKeys'
import type { User } from '@/types/api'

export default function UsersPage() {
  const qc = useQueryClient()
  const [creating, setCreating] = useState(false)
  const [form, setForm] = useState({ email: '', display_name: '', password: '' })
  const [error, setError] = useState<string | null>(null)

  const { data, isLoading } = useQuery({
    queryKey: queryKeys.admin.users(),
    queryFn: () => usersApi.list(),
  })

  const { data: roles } = useQuery({
    queryKey: queryKeys.admin.roles(),
    queryFn: () => rolesApi.list(),
  })

  const createUser = useMutation({
    mutationFn: (body: typeof form) => usersApi.create(body),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: queryKeys.admin.users() })
      setCreating(false)
      setForm({ email: '', display_name: '', password: '' })
    },
    onError: (e) => setError((e as Error).message),
  })

  const toggleActive = useMutation({
    mutationFn: ({ id, is_active }: { id: string; is_active: boolean }) =>
      usersApi.update(id, { is_active }),
    onSuccess: () => qc.invalidateQueries({ queryKey: queryKeys.admin.users() }),
  })

  void roles // available for role assignment future iteration

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Users</h2>
        <button
          onClick={() => setCreating(true)}
          style={{ marginLeft: 'auto', padding: '.4rem .9rem', background: '#2563eb', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
        >
          + New User
        </button>
      </div>

      {creating && (
        <div style={{ background: '#f8fafc', border: '1px solid #e2e8f0', borderRadius: '6px', padding: '1.25rem', marginBottom: '1.25rem' }}>
          <h3 style={{ margin: '0 0 1rem' }}>Create user</h3>
          {error && <p style={{ color: '#dc2626', marginBottom: '.75rem', fontSize: '.875rem' }}>{error}</p>}
          {(['email', 'display_name', 'password'] as const).map((f) => (
            <div key={f} style={{ marginBottom: '.75rem' }}>
              <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>{f.replace('_', ' ')}</label>
              <input
                type={f === 'password' ? 'password' : 'text'}
                value={form[f]}
                onChange={(e) => setForm((p) => ({ ...p, [f]: e.target.value }))}
                style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px', fontSize: '.9rem', boxSizing: 'border-box' }}
              />
            </div>
          ))}
          <div style={{ display: 'flex', gap: '.5rem' }}>
            <button
              onClick={() => createUser.mutate(form)}
              disabled={createUser.isPending}
              style={{ padding: '.4rem .9rem', background: '#16a34a', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
            >
              Save
            </button>
            <button
              onClick={() => { setCreating(false); setError(null) }}
              style={{ padding: '.4rem .9rem', background: '#6b7280', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
            >
              Cancel
            </button>
          </div>
        </div>
      )}

      {isLoading && <p>Loading…</p>}

      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.9rem' }}>
        <thead>
          <tr style={{ background: '#f1f5f9', textAlign: 'left' }}>
            <th style={{ padding: '.6rem .8rem' }}>Email</th>
            <th style={{ padding: '.6rem .8rem' }}>Name</th>
            <th style={{ padding: '.6rem .8rem' }}>Roles</th>
            <th style={{ padding: '.6rem .8rem' }}>Status</th>
            <th style={{ padding: '.6rem .8rem' }}>Actions</th>
          </tr>
        </thead>
        <tbody>
          {(data?.items ?? []).map((u: User) => (
            <tr key={u.id} style={{ borderBottom: '1px solid #e2e8f0' }}>
              <td style={{ padding: '.6rem .8rem' }}>{u.email}</td>
              <td style={{ padding: '.6rem .8rem' }}>{u.display_name}</td>
              <td style={{ padding: '.6rem .8rem', fontSize: '.8rem', color: '#64748b' }}>{u.roles.join(', ')}</td>
              <td style={{ padding: '.6rem .8rem' }}>
                <span style={{ color: u.is_active ? '#16a34a' : '#9ca3af', fontWeight: 600, fontSize: '.8rem' }}>
                  {u.is_active ? 'Active' : 'Disabled'}
                </span>
              </td>
              <td style={{ padding: '.6rem .8rem' }}>
                <button
                  onClick={() => toggleActive.mutate({ id: u.id, is_active: !u.is_active })}
                  style={{ padding: '.25rem .6rem', background: u.is_active ? '#f59e0b' : '#2563eb', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.8rem' }}
                >
                  {u.is_active ? 'Disable' : 'Enable'}
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
