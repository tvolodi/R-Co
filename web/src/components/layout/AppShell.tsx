import { Outlet, NavLink } from 'react-router-dom'
import { useAuth } from '@/auth/AuthContext'
import { ApiConnectivityBanner } from './ApiConnectivityBanner'

type Role = 'PLATFORM_ADMIN' | 'PROCESS_DESIGNER' | 'PROCESS_OPERATOR' | 'TASK_WORKER'

interface NavItem {
  to: string
  label: string
  roles: Role[]
}

const NAV_ITEMS: NavItem[] = [
  { to: '/instances',     label: 'Instances',   roles: ['PLATFORM_ADMIN', 'PROCESS_DESIGNER', 'PROCESS_OPERATOR'] },
  { to: '/tasks',         label: 'My Tasks',    roles: ['PLATFORM_ADMIN', 'PROCESS_OPERATOR', 'TASK_WORKER'] },
  { to: '/definitions',  label: 'Definitions', roles: ['PLATFORM_ADMIN', 'PROCESS_DESIGNER'] },
  { to: '/dlq',           label: 'DLQ',         roles: ['PLATFORM_ADMIN', 'PROCESS_OPERATOR'] },
  { to: '/webhooks',      label: 'Webhooks',    roles: ['PLATFORM_ADMIN', 'PROCESS_OPERATOR'] },
  { to: '/admin/users',   label: 'Users',       roles: ['PLATFORM_ADMIN'] },
  { to: '/admin/groups',  label: 'Groups',      roles: ['PLATFORM_ADMIN'] },
  { to: '/admin/tokens',  label: 'Tokens',      roles: ['PLATFORM_ADMIN'] },
  { to: '/admin/audit',   label: 'Audit',       roles: ['PLATFORM_ADMIN'] },
  { to: '/admin/health',  label: 'Health',      roles: ['PLATFORM_ADMIN'] },
  { to: '/admin/metrics', label: 'Metrics',     roles: ['PLATFORM_ADMIN'] },
]

export function AppShell() {
  const { session, logout } = useAuth()

  const visibleNav = NAV_ITEMS.filter((n) =>
    n.roles.some((r) => session?.roles.includes(r)),
  )

  return (
    <div style={{ display: 'flex', minHeight: '100vh', fontFamily: 'system-ui, sans-serif' }}>
      {/* Sidebar */}
      <aside
        style={{
          width: '220px',
          background: '#1e293b',
          color: '#cbd5e1',
          display: 'flex',
          flexDirection: 'column',
          padding: '1.5rem 0',
          flexShrink: 0,
        }}
      >
        <div style={{ padding: '0 1.25rem', marginBottom: '1.5rem', fontWeight: 700, fontSize: '1.1rem', color: '#f1f5f9' }}>
          BPM Platform
        </div>

        <nav style={{ flex: 1 }}>
          {visibleNav.map((n) => (
            <NavLink
              key={n.to}
              to={n.to}
              style={({ isActive }) => ({
                display: 'block',
                padding: '.5rem 1.25rem',
                color: isActive ? '#f1f5f9' : '#94a3b8',
                background: isActive ? '#334155' : 'transparent',
                textDecoration: 'none',
                fontSize: '.9rem',
                borderLeft: isActive ? '3px solid #3b82f6' : '3px solid transparent',
              })}
            >
              {n.label}
            </NavLink>
          ))}
        </nav>

        <div style={{ padding: '.75rem 1.25rem', borderTop: '1px solid #334155', fontSize: '.8rem', color: '#64748b' }}>
          <div
            data-testid="user-display-name"
            style={{ marginBottom: '.25rem', color: '#94a3b8' }}
          >
            {session?.display_name}
          </div>
          <div
            data-testid="user-roles"
            style={{ marginBottom: '.5rem', color: '#64748b', fontSize: '.75rem' }}
          >
            {session?.roles.join(', ')}
          </div>
          <button
            data-testid="logout-button"
            onClick={logout}
            style={{ background: 'none', border: 'none', color: '#64748b', cursor: 'pointer', padding: 0, fontSize: '.8rem' }}
          >
            Sign out
          </button>
        </div>
      </aside>

      {/* Main content */}
      <main style={{ flex: 1, overflow: 'auto', background: '#f8fafc' }}>
        <ApiConnectivityBanner />
        <Outlet />
      </main>
    </div>
  )
}
