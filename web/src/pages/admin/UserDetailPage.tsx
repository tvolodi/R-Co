import { useEffect, useMemo, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { useAuth } from '@/auth/AuthContext'
import { DeactivateUserDialog } from '@/components/admin/users/DeactivateUserDialog'
import { useAdminGroups, useAdminRoles, useAdminUser, useDeactivateAdminUser, useUpdateAdminUser } from '@/hooks/useAdminUsers'
import type { User } from '@/types/api'

function userId(user: User): string {
  return user.user_id ?? user.id ?? ''
}

function userStatus(user: User): 'ACTIVE' | 'INACTIVE' {
  if (user.status) return user.status
  return user.is_active ? 'ACTIVE' : 'INACTIVE'
}

export default function UserDetailPage() {
  const { userId: routeUserId = '' } = useParams()
  const navigate = useNavigate()
  const { session } = useAuth()
  const isPlatformAdmin = session?.roles?.includes('PLATFORM_ADMIN') === true

  const userQuery = useAdminUser(routeUserId)
  const rolesQuery = useAdminRoles()
  const groupsQuery = useAdminGroups()
  const updateUser = useUpdateAdminUser(routeUserId)
  const deactivateUser = useDeactivateAdminUser(routeUserId)

  const [displayName, setDisplayName] = useState('')
  const [email, setEmail] = useState('')
  const [status, setStatus] = useState<'ACTIVE' | 'INACTIVE'>('ACTIVE')
  const [selectedRoleIds, setSelectedRoleIds] = useState<string[]>([])
  const [selectedGroupIds, setSelectedGroupIds] = useState<string[]>([])
  const [showDeactivate, setShowDeactivate] = useState(false)
  const [submitMessage, setSubmitMessage] = useState<string | null>(null)

  useEffect(() => {
    if (!userQuery.data) return
    const user = userQuery.data
    setDisplayName(user.display_name)
    setEmail(user.email)
    setStatus(userStatus(user))
    setSelectedRoleIds(user.role_ids ?? [])
    setSelectedGroupIds(user.group_ids ?? [])
  }, [userQuery.data])

  const pageUserId = useMemo(() => {
    if (!userQuery.data) return routeUserId
    return userId(userQuery.data) || routeUserId
  }, [routeUserId, userQuery.data])

  if (!isPlatformAdmin) {
    return (
      <div style={{ padding: '1.5rem' }}>
        <h2>User details</h2>
        <p>You do not have permission to manage users.</p>
      </div>
    )
  }

  return (
    <div style={{ padding: '1.5rem', maxWidth: 900 }}>
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', marginBottom: 12 }}>
        <button type="button" onClick={() => navigate('/admin/users')}>Back</button>
        <h2 style={{ margin: 0 }}>User details</h2>
      </div>

      {userQuery.isLoading && <p>Loading...</p>}
      {userQuery.isError && <p role="alert">Failed to load user.</p>}

      {userQuery.data && (
        <form
          data-testid="admin-user-detail-form"
          onSubmit={(event) => {
            event.preventDefault()
            setSubmitMessage(null)
            updateUser.mutate(
              {
                display_name: displayName.trim(),
                email: email.trim(),
                status,
                is_active: status === 'ACTIVE',
                role_ids: selectedRoleIds,
                group_ids: selectedGroupIds,
              },
              {
                onSuccess: () => setSubmitMessage('Saved'),
                onError: (error) => setSubmitMessage((error as Error).message),
              },
            )
          }}
        >
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
            <label>
              <span style={{ display: 'block', fontWeight: 600, marginBottom: 4 }}>Username</span>
              <input value={userQuery.data.username ?? ''} disabled readOnly data-testid="admin-user-username" />
            </label>
            <label>
              <span style={{ display: 'block', fontWeight: 600, marginBottom: 4 }}>Status</span>
              <select value={status} onChange={(event) => setStatus(event.target.value as 'ACTIVE' | 'INACTIVE')} data-testid="admin-user-status">
                <option value="ACTIVE">ACTIVE</option>
                <option value="INACTIVE">INACTIVE</option>
              </select>
            </label>
            <label>
              <span style={{ display: 'block', fontWeight: 600, marginBottom: 4 }}>Display name</span>
              <input value={displayName} onChange={(event) => setDisplayName(event.target.value)} data-testid="admin-user-display-name" />
            </label>
            <label>
              <span style={{ display: 'block', fontWeight: 600, marginBottom: 4 }}>Email</span>
              <input type="email" value={email} onChange={(event) => setEmail(event.target.value)} data-testid="admin-user-email" />
            </label>
          </div>

          <div style={{ marginTop: 16 }}>
            <h3 style={{ marginBottom: 8 }}>Role assignments</h3>
            <div style={{ border: '1px solid #d1d5db', borderRadius: 6, padding: 10 }}>
              {(rolesQuery.data?.items ?? []).map((role) => {
                const checked = selectedRoleIds.includes(role.id)
                return (
                  <label key={role.id} style={{ display: 'block', marginBottom: 6 }}>
                    <input
                      type="checkbox"
                      checked={checked}
                      onChange={(event) => {
                        setSelectedRoleIds((prev) => {
                          if (event.target.checked) return [...prev, role.id]
                          return prev.filter((id) => id !== role.id)
                        })
                      }}
                    />
                    {' '}{role.name}
                  </label>
                )
              })}
            </div>
          </div>

          <div style={{ marginTop: 16 }}>
            <h3 style={{ marginBottom: 8 }}>Group memberships</h3>
            <div style={{ border: '1px solid #d1d5db', borderRadius: 6, padding: 10 }}>
              {(groupsQuery.data?.items ?? []).map((group) => {
                const gid = group.group_id ?? group.id
                const checked = selectedGroupIds.includes(gid)
                return (
                  <label key={gid} style={{ display: 'block', marginBottom: 6 }}>
                    <input
                      type="checkbox"
                      checked={checked}
                      onChange={(event) => {
                        setSelectedGroupIds((prev) => {
                          if (event.target.checked) return [...prev, gid]
                          return prev.filter((id) => id !== gid)
                        })
                      }}
                    />
                    {' '}{group.display_name || group.name}
                  </label>
                )
              })}
            </div>
          </div>

          {submitMessage && <p role="status" data-testid="admin-user-submit-message">{submitMessage}</p>}

          <div style={{ display: 'flex', gap: 8, marginTop: 16 }}>
            <button type="submit" disabled={updateUser.isPending} data-testid="admin-user-save">
              {updateUser.isPending ? 'Saving...' : 'Save changes'}
            </button>
            {status === 'ACTIVE' && (
              <button type="button" onClick={() => setShowDeactivate(true)} data-testid="admin-user-deactivate">
                Deactivate
              </button>
            )}
          </div>
        </form>
      )}

      <DeactivateUserDialog
        open={showDeactivate}
        displayName={displayName || pageUserId}
        isSubmitting={deactivateUser.isPending}
        onCancel={() => setShowDeactivate(false)}
        onConfirm={() => {
          deactivateUser.mutate(undefined, {
            onSuccess: () => {
              setShowDeactivate(false)
              setStatus('INACTIVE')
              setSubmitMessage('User deactivated')
            },
            onError: (error) => {
              setSubmitMessage((error as Error).message)
            },
          })
        }}
      />
    </div>
  )
}
