import { useMemo, useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { groupsApi, usersApi } from '@/api/identity'
import { queryKeys } from '@/api/queryKeys'
import type { Group, User } from '@/types/api'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { getRetryAfterSeconds } from '@/utils/getRetryAfterSeconds'

type GroupRow = Group & {
  group_id?: string
  member_count?: number
  display_name?: string
  description?: string
  is_system?: boolean
}

function groupId(group: GroupRow): string {
  return group.group_id ?? group.id ?? ''
}

function groupTitle(group: GroupRow): string {
  return group.display_name?.trim() || group.name || groupId(group) || 'Unnamed group'
}

function groupMembers(group: GroupRow): number {
  return group.member_count ?? 0
}

function formatUser(user: User): string {
  return `${user.display_name} <${user.email}>`
}

export default function GroupsPage() {
  const qc = useQueryClient()
  const [creating, setCreating] = useState(false)
  const [form, setForm] = useState({ name: '', display_name: '', description: '' })
  const [activeGroup, setActiveGroup] = useState<GroupRow | null>(null)
  const [pendingDelete, setPendingDelete] = useState<GroupRow | null>(null)
  const [selectedUserId, setSelectedUserId] = useState('')

  const { data, isLoading, isError, error, refetch } = useQuery({
    queryKey: queryKeys.admin.groups(),
    queryFn: () => groupsApi.list(),
  })

  const groups = useMemo(() => (data?.items ?? []) as GroupRow[], [data?.items])
  const activeGroupId = groupId(activeGroup ?? ({} as GroupRow))
  const rendererState: RendererState = isLoading ? 'loading' : isError ? classifyError(error) : 'success'

  const { data: members } = useQuery({
    queryKey: queryKeys.admin.groupMembers(activeGroupId),
    queryFn: () => groupsApi.members(activeGroupId),
    enabled: Boolean(activeGroup),
  })

  const { data: users } = useQuery({
    queryKey: queryKeys.admin.users({ page_size: 200 }),
    queryFn: () => usersApi.list({ page_size: 200 }),
    enabled: Boolean(activeGroup),
  })

  const createGroup = useMutation({
    mutationFn: (body: typeof form) => groupsApi.create(body),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: queryKeys.admin.groups() })
      setCreating(false)
      setForm({ name: '', display_name: '', description: '' })
    },
  })

  const addMember = useMutation({
    mutationFn: ({ groupId: id, userId }: { groupId: string; userId: string }) => groupsApi.addMembers(id, [userId]),
    onSuccess: () => {
      if (activeGroup) {
        qc.invalidateQueries({ queryKey: queryKeys.admin.groups() })
        qc.invalidateQueries({ queryKey: queryKeys.admin.groupMembers(groupId(activeGroup)) })
      }
      setSelectedUserId('')
    },
  })

  const removeMember = useMutation({
    mutationFn: ({ groupId: id, userId }: { groupId: string; userId: string }) => groupsApi.removeMembers(id, [userId]),
    onSuccess: () => {
      if (activeGroup) {
        qc.invalidateQueries({ queryKey: queryKeys.admin.groups() })
        qc.invalidateQueries({ queryKey: queryKeys.admin.groupMembers(groupId(activeGroup)) })
      }
    },
  })

  const deleteGroup = useMutation({
    mutationFn: (id: string) => groupsApi.delete(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: queryKeys.admin.groups() }),
  })

  const availableUsers = useMemo(() => {
    const list = users?.items ?? []
    const memberIds = new Set((members ?? []).map((user) => user.id ?? user.user_id ?? ''))
    return list.filter((user) => {
      const id = user.id ?? user.user_id ?? ''
      return id !== '' && !memberIds.has(id)
    })
  }, [members, users?.items])

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Groups</h2>
        <button
          onClick={() => setCreating(true)}
          style={{ marginLeft: 'auto', padding: '.4rem .9rem', background: '#2563eb', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
        >
          + New Group
        </button>
      </div>

      {creating && (
        <div style={{ background: '#f8fafc', border: '1px solid #e2e8f0', borderRadius: '6px', padding: '1.25rem', marginBottom: '1.25rem' }}>
          <h3 style={{ margin: '0 0 1rem' }}>Create group</h3>
          {(['name', 'display_name', 'description'] as const).map((f) => (
            <div key={f} style={{ marginBottom: '.75rem' }}>
              <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>{f.replace('_', ' ')}</label>
              <input
                value={form[f]}
                onChange={(e) => setForm((p) => ({ ...p, [f]: e.target.value }))}
                style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px', fontSize: '.9rem', boxSizing: 'border-box' }}
              />
            </div>
          ))}
          <div style={{ display: 'flex', gap: '.5rem' }}>
            <button onClick={() => createGroup.mutate(form)} style={{ padding: '.4rem .9rem', background: '#16a34a', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}>Save</button>
            <button onClick={() => setCreating(false)} style={{ padding: '.4rem .9rem', background: '#6b7280', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}>Cancel</button>
          </div>
        </div>
      )}

      <QueryStateBoundary
        state={rendererState}
        onRetry={() => { void refetch() }}
        rateLimitRetryAfter={
          rendererState === 'rate-limit' ? getRetryAfterSeconds(error) : undefined
        }
        columns={[{ widthPercent: 25 }, { widthPercent: 30 }, { widthPercent: 10 }, { widthPercent: 25 }, { widthPercent: 10 }]}
      >
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.9rem' }}>
        <thead>
          <tr style={{ background: '#f1f5f9', textAlign: 'left' }}>
            <th style={{ padding: '.6rem .8rem' }}>Name</th>
            <th style={{ padding: '.6rem .8rem' }}>Display name</th>
            <th style={{ padding: '.6rem .8rem' }}>Members</th>
            <th style={{ padding: '.6rem .8rem' }}>Description</th>
            <th style={{ padding: '.6rem .8rem' }}>Actions</th>
          </tr>
        </thead>
        <tbody>
          {groups.map((g) => {
            const id = groupId(g)
            const memberCount = groupMembers(g)
            return (
              <tr key={id} style={{ borderBottom: '1px solid #e2e8f0' }}>
                <td style={{ padding: '.6rem .8rem', fontFamily: 'monospace', fontSize: '.85rem' }}>{g.name}</td>
                <td style={{ padding: '.6rem .8rem' }}>{groupTitle(g)}</td>
                <td style={{ padding: '.6rem .8rem' }}>{memberCount}</td>
                <td style={{ padding: '.6rem .8rem', color: '#64748b', fontSize: '.85rem' }}>{g.description ?? '—'}</td>
                <td style={{ padding: '.6rem .8rem' }}>
                  <div style={{ display: 'flex', gap: '.5rem', flexWrap: 'wrap' }}>
                    <button
                      onClick={() => setActiveGroup(g)}
                      style={{ padding: '.25rem .6rem', background: '#2563eb', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.8rem' }}
                    >
                      Manage members
                    </button>
                    {!g.is_system && memberCount === 0 && (
                      <button
                        onClick={() => setPendingDelete(g)}
                        style={{ padding: '.25rem .6rem', background: '#dc2626', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.8rem' }}
                      >
                        Delete
                      </button>
                    )}
                  </div>
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>

      {activeGroup && (
        <div role="dialog" aria-modal="true" aria-label="Manage group members" style={{ position: 'fixed', inset: 0, background: 'rgba(15, 23, 42, .45)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '1rem', zIndex: 30 }}>
          <div style={{ background: '#fff', width: 'min(720px, 100%)', borderRadius: '12px', padding: '1.25rem', maxHeight: '85vh', overflow: 'auto' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: '1rem', alignItems: 'start', marginBottom: '1rem' }}>
              <div>
                <h3 style={{ margin: 0 }}>Manage members</h3>
                <p style={{ margin: '.25rem 0 0', color: '#64748b' }}>{groupTitle(activeGroup)}</p>
              </div>
              <button onClick={() => { setActiveGroup(null); setSelectedUserId('') }} style={{ padding: '.25rem .6rem', background: '#e2e8f0', border: 'none', borderRadius: '4px', cursor: 'pointer' }}>Close</button>
            </div>

            <div style={{ display: 'flex', gap: '.5rem', marginBottom: '1rem', alignItems: 'end', flexWrap: 'wrap' }}>
              <label style={{ display: 'grid', gap: '.25rem', minWidth: '18rem', flex: '1 1 18rem' }}>
                <span style={{ fontSize: '.875rem', fontWeight: 600 }}>Add member</span>
                <select value={selectedUserId} onChange={(event) => setSelectedUserId(event.target.value)} style={{ padding: '.45rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px' }}>
                  <option value="">Select a user</option>
                  {availableUsers.map((user) => {
                    const id = user.id ?? user.user_id ?? ''
                    return <option key={id} value={id}>{formatUser(user)}</option>
                  })}
                </select>
              </label>
              <button
                type="button"
                onClick={() => {
                  if (!selectedUserId) return
                  addMember.mutate({ groupId: groupId(activeGroup), userId: selectedUserId })
                }}
                disabled={!selectedUserId || addMember.isPending}
                style={{ padding: '.45rem .8rem', background: '#16a34a', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer' }}
              >
                Add member
              </button>
            </div>

            <div>
              <h4 style={{ margin: '0 0 .75rem' }}>Current members</h4>
              {(members ?? []).length === 0 ? (
                <p style={{ margin: 0, color: '#64748b' }}>No members in this group.</p>
              ) : (
                <div style={{ display: 'grid', gap: '.5rem' }}>
                  {(members ?? []).map((user) => {
                    const id = user.id ?? user.user_id ?? ''
                    return (
                      <div key={id} style={{ display: 'flex', justifyContent: 'space-between', gap: '1rem', alignItems: 'center', border: '1px solid #e2e8f0', borderRadius: '8px', padding: '.7rem .85rem' }}>
                        <div>
                          <div style={{ fontWeight: 600 }}>{user.display_name}</div>
                          <div style={{ color: '#64748b', fontSize: '.875rem' }}>{user.email}</div>
                        </div>
                        <button
                          type="button"
                          onClick={() => removeMember.mutate({ groupId: groupId(activeGroup), userId: id })}
                          style={{ padding: '.25rem .6rem', background: '#dc2626', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.8rem' }}
                        >
                          Remove
                        </button>
                      </div>
                    )
                  })}
                </div>
              )}
            </div>
          </div>
        </div>
      )}

      </QueryStateBoundary>

      {pendingDelete && (
        <div role="dialog" aria-modal="true" aria-label="Delete group" style={{ position: 'fixed', inset: 0, background: 'rgba(15, 23, 42, .45)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '1rem', zIndex: 40 }}>
          <div style={{ background: '#fff', width: 'min(520px, 100%)', borderRadius: '12px', padding: '1.25rem' }}>
            <h3 style={{ marginTop: 0 }}>Delete group?</h3>
            <p style={{ color: '#475569' }}>Delete {groupTitle(pendingDelete)} only if it is empty. This action cannot be undone.</p>
            <div style={{ display: 'flex', gap: '.5rem', justifyContent: 'flex-end' }}>
              <button type="button" onClick={() => setPendingDelete(null)} style={{ padding: '.45rem .8rem', background: '#e2e8f0', border: 'none', borderRadius: '4px', cursor: 'pointer' }}>Cancel</button>
              <button
                type="button"
                onClick={() => {
                  deleteGroup.mutate(groupId(pendingDelete))
                  setPendingDelete(null)
                }}
                style={{ padding: '.45rem .8rem', background: '#dc2626', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer' }}
              >
                Delete group
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
