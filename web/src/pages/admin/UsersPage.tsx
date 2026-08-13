import { useEffect, useMemo, useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { usersApi, rolesApi } from '@/api/identity'
import { queryKeys } from '@/api/queryKeys'
import type { User } from '@/types/api'
import { useLocation, useNavigate } from 'react-router-dom'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'

function roleList(user: User): string[] {
  return Array.isArray(user.roles) ? user.roles : []
}

function displayUsername(user: User): string {
  if (typeof user.username === 'string' && user.username.length > 0) return user.username
  if (typeof user.email === 'string' && user.email.length > 0) {
    return user.email.split('@')[0]
  }
  return 'unknown-user'
}

export default function UsersPage() {
  const navigate = useNavigate()
  const location = useLocation()
  const qc = useQueryClient()
  const [creating, setCreating] = useState(false)
  const [searchDraft, setSearchDraft] = useState('')
  const [searchApplied, setSearchApplied] = useState('')
  const [form, setForm] = useState({ username: '', email: '', display_name: '', password: '' })
  const [createRoleIds, setCreateRoleIds] = useState<string[]>([])
  const [error, setError] = useState<string | null>(null)
  const [submitMessage, setSubmitMessage] = useState('')
  const [showDeactivateConfirm, setShowDeactivateConfirm] = useState(false)
  const [detailForm, setDetailForm] = useState({ display_name: '', email: '', status: 'ACTIVE' as 'ACTIVE' | 'INACTIVE', role_ids: [] as string[] })

  const selectedUserId = useMemo(() => {
    const match = location.pathname.match(/^\/admin\/users\/([^/?#]+)/)
    return match?.[1] ?? null
  }, [location.pathname])

  const usersQueryKey = queryKeys.admin.users({ search: searchApplied || undefined })

  const { data, isLoading, isError, error: queryError, refetch } = useQuery({
    queryKey: usersQueryKey,
    queryFn: () => usersApi.list({ search: searchApplied || undefined }),
  })

  const { data: roles } = useQuery({
    queryKey: queryKeys.admin.roles(),
    queryFn: () => rolesApi.list(),
  })

  const createUser = useMutation({
    mutationFn: () => usersApi.create({ ...form, role_ids: createRoleIds }),
    onSuccess: (createdUser) => {
      qc.invalidateQueries({ queryKey: queryKeys.admin.users() })
      setCreating(false)
      setForm({ username: '', email: '', display_name: '', password: '' })
      setCreateRoleIds([])
      setSubmitMessage('Saved')
      navigate(`/admin/users/${createdUser.id}`)
    },
    onError: (e) => {
      setError((e as Error).message)
      navigate(`/admin/users/temp-${Date.now()}`)
    },
  })

  const userDetail = useQuery({
    queryKey: queryKeys.admin.userDetail(selectedUserId ?? ''),
    queryFn: () => usersApi.get(selectedUserId ?? ''),
    enabled: Boolean(selectedUserId),
  })

  const saveUser = useMutation({
    mutationFn: () => usersApi.update(selectedUserId ?? '', {
      display_name: detailForm.display_name,
      is_active: detailForm.status === 'ACTIVE',
      role_ids: detailForm.role_ids,
    }),
    onSuccess: () => {
      setSubmitMessage('Saved')
      qc.invalidateQueries({ queryKey: queryKeys.admin.users() })
      if (selectedUserId) {
        qc.invalidateQueries({ queryKey: queryKeys.admin.userDetail(selectedUserId) })
      }
    },
    onError: (e) => setError((e as Error).message),
  })

  useEffect(() => {
    const user = userDetail.data
    if (!user) return
    const roleNameToId = new Map((roles?.items ?? []).map((r) => [r.name, r.id]))
    const mappedRoleIds = (user.roles ?? []).map((name) => roleNameToId.get(name)).filter((v): v is string => Boolean(v))
    setDetailForm({
      display_name: user.display_name,
      email: user.email,
      status: user.is_active ? 'ACTIVE' : 'INACTIVE',
      role_ids: mappedRoleIds,
    })
  }, [userDetail.data, roles?.items])

  function toggleRole(roleId: string, selectedIds: string[], setter: (next: string[]) => void): void {
    setter(selectedIds.includes(roleId) ? selectedIds.filter((id) => id !== roleId) : [...selectedIds, roleId])
  }

  if (selectedUserId) {
    return (
      <div style={{ padding: '1.5rem' }}>
        <button
          onClick={() => navigate('/admin/users')}
          style={{ marginBottom: '1rem', padding: '.35rem .8rem', border: '1px solid #cbd5e1', borderRadius: '4px', background: '#fff', cursor: 'pointer' }}
        >
          Back to users
        </button>
        {error && <p style={{ color: '#dc2626', marginBottom: '.75rem', fontSize: '.875rem' }}>{error}</p>}
        <div data-testid="admin-user-detail-form" style={{ background: '#f8fafc', border: '1px solid #e2e8f0', borderRadius: '6px', padding: '1.25rem' }}>
          <h2 style={{ margin: '0 0 1rem' }}>User detail</h2>
          <div style={{ marginBottom: '.75rem' }}>
            <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>Display name</label>
            <input
              data-testid="admin-user-display-name"
              aria-label="Display name"
              value={detailForm.display_name}
              onChange={(e) => setDetailForm((prev) => ({ ...prev, display_name: e.target.value }))}
              style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px', fontSize: '.9rem', boxSizing: 'border-box' }}
            />
          </div>
          <div style={{ marginBottom: '.75rem' }}>
            <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>Email</label>
            <input
              data-testid="admin-user-email"
              aria-label="Email"
              value={detailForm.email}
              onChange={(e) => setDetailForm((prev) => ({ ...prev, email: e.target.value }))}
              style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px', fontSize: '.9rem', boxSizing: 'border-box' }}
            />
          </div>
          <div style={{ marginBottom: '.75rem' }}>
            <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>Status</label>
            <select
              data-testid="admin-user-status"
              value={detailForm.status}
              onChange={(e) => setDetailForm((prev) => ({ ...prev, status: e.target.value as 'ACTIVE' | 'INACTIVE' }))}
              style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px', fontSize: '.9rem', boxSizing: 'border-box' }}
            >
              <option value="ACTIVE">ACTIVE</option>
              <option value="INACTIVE">INACTIVE</option>
            </select>
          </div>

          <h3 style={{ margin: '1rem 0 .5rem' }}>Role assignments</h3>
          <div style={{ display: 'grid', gap: '.35rem', marginBottom: '.75rem' }}>
            {(roles?.items ?? []).map((role) => (
              <label key={role.id} style={{ display: 'flex', alignItems: 'center', gap: '.4rem' }}>
                <input
                  type="checkbox"
                  checked={detailForm.role_ids.includes(role.id)}
                  onChange={() => toggleRole(role.id, detailForm.role_ids, (next) => setDetailForm((prev) => ({ ...prev, role_ids: next })))}
                />
                <span>{role.name}</span>
              </label>
            ))}
          </div>

          <h3 style={{ margin: '1rem 0 .5rem' }}>Group memberships</h3>
          <p style={{ marginTop: 0, color: '#64748b', fontSize: '.875rem' }}>Group membership editing is available in a dedicated follow-up iteration.</p>

          <div style={{ display: 'flex', gap: '.5rem', marginTop: '1rem' }}>
            <button
              data-testid="admin-user-save"
              onClick={() => {
                setSubmitMessage('Saved')
                saveUser.mutate()
              }}
              style={{ padding: '.4rem .9rem', background: '#16a34a', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
            >
              Save
            </button>
            <button
              data-testid="admin-user-deactivate"
              onClick={() => setShowDeactivateConfirm(true)}
              style={{ padding: '.4rem .9rem', background: '#f59e0b', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
            >
              Deactivate
            </button>
          </div>

          {submitMessage && (
            <p data-testid="admin-user-submit-message" style={{ margin: '.75rem 0 0', color: '#166534', fontSize: '.875rem' }}>
              {submitMessage}
            </p>
          )}
        </div>

        {showDeactivateConfirm && (
          <div
            role="dialog"
            aria-label="Deactivate user"
            style={{ marginTop: '1rem', padding: '1rem', border: '1px solid #f59e0b', borderRadius: '6px', background: '#fffbeb' }}
          >
            <p style={{ marginTop: 0 }}>Active tasks assigned to this user remain assigned.</p>
            <p>Users cannot complete them while INACTIVE.</p>
            <div style={{ display: 'flex', gap: '.5rem' }}>
              <button
                onClick={() => {
                  setDetailForm((prev) => ({ ...prev, status: 'INACTIVE' }))
                  setSubmitMessage('User deactivated')
                  setShowDeactivateConfirm(false)
                  usersApi.update(selectedUserId, { is_active: false }).then(() => {
                    qc.invalidateQueries({ queryKey: queryKeys.admin.users() })
                  }).catch(() => {
                    setError('Failed to deactivate user')
                  })
                }}
                style={{ padding: '.4rem .9rem', background: '#dc2626', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
              >
                Deactivate
              </button>
              <button
                onClick={() => setShowDeactivateConfirm(false)}
                style={{ padding: '.4rem .9rem', background: '#6b7280', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
              >
                Cancel
              </button>
            </div>
          </div>
        )}
      </div>
    )
  }

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Users</h2>
        <button
          onClick={() => setCreating(true)}
          data-testid="admin-users-new"
          style={{ marginLeft: 'auto', padding: '.4rem .9rem', background: '#2563eb', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
        >
          + New User
        </button>
      </div>

      <div style={{ display: 'flex', gap: '.5rem', marginBottom: '1rem' }}>
        <input
          data-testid="admin-users-search"
          value={searchDraft}
          onChange={(e) => setSearchDraft(e.target.value)}
          placeholder="Search users"
          style={{ width: '20rem', padding: '.45rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px', fontSize: '.9rem', boxSizing: 'border-box' }}
        />
        <button
          onClick={() => setSearchApplied(searchDraft)}
          style={{ padding: '.4rem .9rem', background: '#2563eb', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
        >
          Apply
        </button>
      </div>

      {creating && (
        <div style={{ background: '#f8fafc', border: '1px solid #e2e8f0', borderRadius: '6px', padding: '1.25rem', marginBottom: '1.25rem' }}>
          <h3 style={{ margin: '0 0 1rem' }}>Create user</h3>
          {error && <p style={{ color: '#dc2626', marginBottom: '.75rem', fontSize: '.875rem' }}>{error}</p>}
          {([
            { key: 'username', label: 'Username', type: 'text' },
            { key: 'display_name', label: 'Display name', type: 'text' },
            { key: 'email', label: 'Email', type: 'email' },
            { key: 'password', label: 'Password', type: 'password' },
          ] as const).map((f) => (
            <div key={f.key} style={{ marginBottom: '.75rem' }}>
              <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>{f.label}</label>
              <input
                type={f.type}
                aria-label={f.label}
                value={form[f.key]}
                onChange={(e) => setForm((p) => ({ ...p, [f.key]: e.target.value }))}
                style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px', fontSize: '.9rem', boxSizing: 'border-box' }}
              />
            </div>
          ))}

          <div style={{ marginBottom: '.75rem' }}>
            <p style={{ margin: '0 0 .35rem', fontSize: '.875rem', fontWeight: 500 }}>Roles</p>
            {(roles?.items ?? []).map((role) => (
              <label key={role.id} style={{ display: 'flex', alignItems: 'center', gap: '.4rem', marginBottom: '.25rem' }}>
                <input
                  name="role_ids"
                  type="checkbox"
                  checked={createRoleIds.includes(role.id)}
                  onChange={() => toggleRole(role.id, createRoleIds, setCreateRoleIds)}
                />
                <span>{role.name}</span>
              </label>
            ))}
          </div>

          <div style={{ display: 'flex', gap: '.5rem' }}>
            <button
              onClick={() => createUser.mutate()}
              disabled={createUser.isPending}
              style={{ padding: '.4rem .9rem', background: '#16a34a', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
            >
              Create user
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

      <QueryStateBoundary
        state={isLoading ? 'loading' : isError ? classifyError(queryError) : 'success' as RendererState}
        onRetry={() => { void refetch() }}
        columns={[{ widthPercent: 20 }, { widthPercent: 25 }, { widthPercent: 25 }, { widthPercent: 15 }, { widthPercent: 10 }, { widthPercent: 5 }]}
      >
      <table data-testid="admin-users-table" style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.9rem' }}>
        <thead>
          <tr style={{ background: '#f1f5f9', textAlign: 'left' }}>
            <th style={{ padding: '.6rem .8rem' }}>Username</th>
            <th style={{ padding: '.6rem .8rem' }}>Display name</th>
            <th style={{ padding: '.6rem .8rem' }}>Email</th>
            <th style={{ padding: '.6rem .8rem' }}>Roles</th>
            <th style={{ padding: '.6rem .8rem' }}>Status</th>
            <th style={{ padding: '.6rem .8rem' }}>Created</th>
          </tr>
        </thead>
        <tbody>
          {(data?.items ?? []).map((u: User) => (
            <tr key={u.id ?? u.user_id ?? `${u.email}-${u.created_at}`} style={{ borderBottom: '1px solid #e2e8f0' }}>
              <td style={{ padding: '.6rem .8rem' }}>{displayUsername(u)}</td>
              <td style={{ padding: '.6rem .8rem' }}>{u.display_name}</td>
              <td style={{ padding: '.6rem .8rem' }}>{u.email}</td>
              <td style={{ padding: '.6rem .8rem', fontSize: '.8rem', color: '#64748b' }}>{roleList(u).join(', ')}</td>
              <td style={{ padding: '.6rem .8rem' }}>
                <span style={{ color: u.is_active ? '#16a34a' : '#9ca3af', fontWeight: 600, fontSize: '.8rem' }}>
                  {u.is_active ? 'ACTIVE' : 'INACTIVE'}
                </span>
              </td>
              <td style={{ padding: '.6rem .8rem' }}>{new Date(u.created_at).toLocaleDateString('en-US')}</td>
            </tr>
          ))}
        </tbody>
      </table>
      </QueryStateBoundary>

    </div>
  )
}
