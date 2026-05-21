import { Outlet, NavLink, useNavigate } from 'react-router-dom'
import { useAuth } from '@/auth/AuthContext'

const NAV: { to: string; label: string; adminOnly?: boolean }[] = [
  { to: '/instances',      label: 'Instances' },
  { to: '/tasks',          label: 'My Tasks' },
  { to: '/definitions',   label: 'Definitions' },
  { to: '/dlq',            label: 'DLQ' },
  { to: '/webhooks',       label: 'Webhooks' },
  { to: '/admin/users',    label: 'Users',   adminOnly: true },
  { to: '/admin/groups',   label: 'Groups',  adminOnly: true },
  { to: '/admin/tokens',   label: 'Tokens',  adminOnly: true },
  { to: '/admin/audit',    label: 'Audit',   adminOnly: true },
  { to: '/admin/health',   label: 'Health',  adminOnly: true },
  { to: '/admin/metrics',  label: 'Metrics', adminOnly: true },
]

export function AppShell() {
  const { user, logout } = useAuth()
  const navigate = useNavigate()

  const isAdmin = user?.roles?.includes('PLATFORM_ADMIN') ?? false

  async function handleLogout() {
    await logout()
    navigate('/login')
  }

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
          {NAV.filter((n) => !n.adminOnly || isAdmin).map((n) => (
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
          <div style={{ marginBottom: '.5rem', color: '#94a3b8' }}>{user?.email}</div>
          <button
            onClick={handleLogout}
            style={{ background: 'none', border: 'none', color: '#64748b', cursor: 'pointer', padding: 0, fontSize: '.8rem' }}
          >
            Sign out
          </button>
        </div>
      </aside>

      {/* Main content */}
      <main style={{ flex: 1, overflow: 'auto', background: '#f8fafc' }}>
        <Outlet />
      </main>
    </div>
  )
}
