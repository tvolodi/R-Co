import { Outlet, NavLink } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { ApiConnectivityBanner } from './ApiConnectivityBanner'
import { TestEnvironmentBanner } from './TestEnvironmentBanner'
import { useTestEnvironment } from '@/hooks/useTestEnvironment'
import { dlqApi } from '@/api/dlq'
import { queryKeys } from '@/api/queryKeys'

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
  { to: '/admin/onboarding/new', label: 'Register Tenant', roles: ['PLATFORM_ADMIN'] },
  { to: '/admin/tenants',       label: 'Tenants',          roles: ['PLATFORM_ADMIN'] },
  { to: '/admin/services',       label: 'Services',         roles: ['PLATFORM_ADMIN'] },
]

export function AppShell() {
  const { session, logout } = useAuth()
  const { isTestTenant, productionTenantName } = useTestEnvironment()

  const dlqThreshold = Number(import.meta.env.VITE_DLQ_ALERT_THRESHOLD ?? '10')
  const { data: dlqSummary } = useQuery({
    queryKey: queryKeys.dlq.list({ status: 'pending', page_size: 101 }),
    queryFn: () => dlqApi.list({ status: 'pending', page_size: 101 }),
    refetchInterval: 15000,
  })

  const pendingDlqCount = dlqSummary?.items?.length ?? 0
  const dlqSeverity = pendingDlqCount <= 0 ? 'none' : (pendingDlqCount > dlqThreshold ? 'critical' : 'warning')

  const visibleNav = NAV_ITEMS.filter((n) =>
    n.roles.some((r) => session?.roles.includes(r)),
  )

  return (
    <div style={{ display: 'flex', minHeight: '100vh', fontFamily: 'system-ui, sans-serif', paddingTop: isTestTenant ? '40px' : '0' }}>
      <TestEnvironmentBanner isTestTenant={isTestTenant} productionTenantName={productionTenantName} />
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
              <span style={{ display: 'inline-flex', alignItems: 'center', gap: '.5rem' }}>
                {n.label}
                {n.to === '/dlq' && dlqSeverity !== 'none' && (
                  <span
                    style={{
                      minWidth: '1.25rem',
                      padding: '0 .35rem',
                      borderRadius: '999px',
                      fontSize: '.72rem',
                      lineHeight: '1.15rem',
                      textAlign: 'center',
                      fontWeight: 700,
                      color: '#0f172a',
                      background: dlqSeverity === 'critical' ? '#ef4444' : '#f59e0b',
                    }}
                    aria-label={`DLQ pending count ${pendingDlqCount}`}
                  >
                    {pendingDlqCount}
                  </span>
                )}
              </span>
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
