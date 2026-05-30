import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAuth } from '@/auth/AuthContext'
import { CreateUserDialog } from '@/components/admin/users/CreateUserDialog'
import { useAdminUsers, useAdminRoles, useCreateAdminUser, type AdminUserFilters } from '@/hooks/useAdminUsers'
import type { User } from '@/types/api'

function userId(user: User): string {
    return user.user_id ?? user.id ?? ''
}

function userStatus(user: User): 'ACTIVE' | 'INACTIVE' {
    if (user.status) return user.status
    return user.is_active ? 'ACTIVE' : 'INACTIVE'
}

function userRoles(user: User): string[] {
    if (Array.isArray(user.roles)) return user.roles
    return []
}

export default function UsersPage() {
    const navigate = useNavigate()
    const { session } = useAuth()
    const isPlatformAdmin = session?.roles?.includes('PLATFORM_ADMIN') === true

    const [showCreate, setShowCreate] = useState(false)
    const [searchInput, setSearchInput] = useState('')
    const [filters, setFilters] = useState<AdminUserFilters>({
        search: '',
        status: 'ALL',
        page: 1,
        page_size: 25,
    })
    const [createError, setCreateError] = useState<string | null>(null)

    const usersQuery = useAdminUsers(filters)
    const rolesQuery = useAdminRoles()
    const createUser = useCreateAdminUser()

    const totalPages = useMemo(() => {
        const total = usersQuery.data?.total ?? 0
        return Math.max(1, Math.ceil(total / filters.page_size))
    }, [usersQuery.data?.total, filters.page_size])

    if (!isPlatformAdmin) {
        return (
            <div style={{ padding: '1.5rem' }}>
                <h2>Users</h2>
                <p>You do not have permission to manage users.</p>
            </div>
        )
    }

    return (
        <div style={{ padding: '1.5rem' }}>
            <div style={{ display: 'flex', alignItems: 'center', marginBottom: '1rem' }}>
                <h2 style={{ margin: 0 }}>Users</h2>
                <button
                    onClick={() => setShowCreate(true)}
                    style={{ marginLeft: 'auto', padding: '.45rem .9rem' }}
                    data-testid="admin-users-new"
                >
                    New User
                </button>
            </div>

            <form
                onSubmit={(event) => {
                    event.preventDefault()
                    setFilters((prev) => ({ ...prev, search: searchInput, page: 1 }))
                }}
                style={{ display: 'grid', gridTemplateColumns: '2fr 1fr 120px auto', gap: '.75rem', marginBottom: '1rem' }}
            >
                <label>
                    <span style={{ display: 'block', fontSize: '.875rem', marginBottom: 4 }}>Search</span>
                    <input
                        value={searchInput}
                        onChange={(event) => setSearchInput(event.target.value)}
                        placeholder="username, display name, or email"
                        data-testid="admin-users-search"
                    />
                </label>
                <label>
                    <span style={{ display: 'block', fontSize: '.875rem', marginBottom: 4 }}>Status</span>
                    <select
                        value={filters.status}
                        onChange={(event) => {
                            const status = event.target.value as AdminUserFilters['status']
                            setFilters((prev) => ({ ...prev, status, page: 1 }))
                        }}
                        data-testid="admin-users-status"
                    >
                        <option value="ALL">All</option>
                        <option value="ACTIVE">Active</option>
                        <option value="INACTIVE">Inactive</option>
                    </select>
                </label>
                <label>
                    <span style={{ display: 'block', fontSize: '.875rem', marginBottom: 4 }}>Page size</span>
                    <input
                        type="number"
                        min={1}
                        max={200}
                        value={filters.page_size}
                        onChange={(event) => {
                            const next = Number(event.target.value) || 25
                            setFilters((prev) => ({ ...prev, page_size: next, page: 1 }))
                        }}
                    />
                </label>
                <button type="submit" style={{ alignSelf: 'end', padding: '.45rem .8rem' }}>Apply</button>
            </form>

            {usersQuery.isLoading && <p>Loading...</p>}
            {usersQuery.isError && <p role="alert">Failed to load users.</p>}

            <table style={{ width: '100%', borderCollapse: 'collapse' }} data-testid="admin-users-table">
                <thead>
                    <tr style={{ background: '#f1f5f9', textAlign: 'left' }}>
                        <th style={{ padding: '.5rem .6rem' }}>Username</th>
                        <th style={{ padding: '.5rem .6rem' }}>Display name</th>
                        <th style={{ padding: '.5rem .6rem' }}>Email</th>
                        <th style={{ padding: '.5rem .6rem' }}>Roles</th>
                        <th style={{ padding: '.5rem .6rem' }}>Status</th>
                        <th style={{ padding: '.5rem .6rem' }}>Created</th>
                        <th style={{ padding: '.5rem .6rem' }}>Actions</th>
                    </tr>
                </thead>
                <tbody>
                    {(usersQuery.data?.items ?? []).map((user) => (
                        <tr key={userId(user)} style={{ borderBottom: '1px solid #e2e8f0' }} data-testid="admin-users-row">
                            <td style={{ padding: '.5rem .6rem' }}>{user.username ?? user.email.split('@')[0]}</td>
                            <td style={{ padding: '.5rem .6rem' }}>{user.display_name}</td>
                            <td style={{ padding: '.5rem .6rem' }}>{user.email}</td>
                            <td style={{ padding: '.5rem .6rem' }}>{userRoles(user).join(', ') || '-'}</td>
                            <td style={{ padding: '.5rem .6rem' }}>{userStatus(user)}</td>
                            <td style={{ padding: '.5rem .6rem' }}>{new Date(user.created_at).toLocaleDateString()}</td>
                            <td style={{ padding: '.5rem .6rem', display: 'flex', gap: 6 }}>
                                <button type="button" onClick={() => navigate(`/admin/users/${userId(user)}`)}>Edit</button>
                                <button type="button" onClick={() => navigate(`/admin/users/${userId(user)}`)}>Open</button>
                            </td>
                        </tr>
                    ))}
                </tbody>
            </table>

            <div style={{ display: 'flex', gap: '.5rem', justifyContent: 'flex-end', marginTop: '.75rem' }}>
                {filters.page > 1 && (
                    <button type="button" onClick={() => setFilters((prev) => ({ ...prev, page: prev.page - 1 }))}>Previous</button>
                )}
                {filters.page < totalPages && (
                    <button type="button" onClick={() => setFilters((prev) => ({ ...prev, page: prev.page + 1 }))}>Next</button>
                )}
            </div>

            <CreateUserDialog
                open={showCreate}
                roles={rolesQuery.data?.items ?? []}
                isSubmitting={createUser.isPending}
                submitError={createError}
                onCancel={() => {
                    setShowCreate(false)
                    setCreateError(null)
                }}
                onSubmit={(payload) => {
                    createUser.mutate(
                        {
                            username: payload.username,
                            display_name: payload.display_name,
                            email: payload.email,
                            role_ids: payload.role_ids,
                            status: 'ACTIVE',
                        },
                        {
                            onSuccess: (created) => {
                                setShowCreate(false)
                                setCreateError(null)
                                const createdId = userId(created)
                                if (createdId) navigate(`/admin/users/${createdId}`)
                            },
                            onError: (error) => {
                                setCreateError((error as Error).message)
                            },
                        },
                    )
                }}
            />
        </div>
    )
}
