import { Navigate } from 'react-router-dom'
import { useQuery, type UseQueryResult } from '@tanstack/react-query'
import { healthApi, type AdminHealthSnapshot } from '@/api/health'
import { queryKeys } from '@/api/queryKeys'
import { useAuth } from '@/auth/AuthContext'

const BADGE: Record<string, string> = { ok: '#16a34a', degraded: '#f59e0b', error: '#dc2626' }

export function useAdminHealthSnapshot(): UseQueryResult<AdminHealthSnapshot> {
  return useQuery({
    queryKey: queryKeys.admin.health(),
    queryFn: () => healthApi.ready(),
    refetchInterval: 15_000,
  })
}

export default function HealthDashboardPage() {
  const { session } = useAuth()
  const isPlatformAdmin = Boolean(session?.roles.includes('PLATFORM_ADMIN'))
  const { data, isLoading, isFetching, dataUpdatedAt, error, refetch } = useAdminHealthSnapshot()

  if (!isPlatformAdmin) {
    return <Navigate to="/instances" replace />
  }

  const isDegraded = data?.status === 'degraded' || data?.status === 'error'

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: '1rem', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Health</h2>
        {dataUpdatedAt > 0 && (
          <span style={{ fontSize: '.8rem', color: '#94a3b8' }}>
            Updated {new Date(dataUpdatedAt).toLocaleTimeString()}
          </span>
        )}
        {isFetching && <span style={{ fontSize: '.8rem', color: '#0369a1' }}>Refreshing…</span>}
        <button
          onClick={() => {
            void refetch()
          }}
          style={{ marginLeft: 'auto', padding: '.35rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px', background: '#fff', cursor: 'pointer', fontSize: '.82rem' }}
        >
          Refresh now
        </button>
      </div>

      {isLoading && <p>Loading…</p>}

      {!isLoading && error && (
        <div style={{ marginBottom: '1rem', padding: '.75rem .9rem', borderRadius: '6px', border: '1px solid #fca5a5', background: '#fff1f2', color: '#9f1239' }}>
          Unable to refresh readiness snapshot. Showing the last known data.
        </div>
      )}

      {isDegraded && (
        <div style={{ marginBottom: '1rem', padding: '.75rem .9rem', borderRadius: '6px', border: '1px solid #fdba74', background: '#fff7ed', color: '#9a3412' }}>
          Platform is not fully ready. Review subsystem details below.
        </div>
      )}

      {data && (
        <>
          <div style={{ display: 'flex', alignItems: 'center', gap: '.75rem', marginBottom: '1.5rem' }}>
            <span style={{ fontWeight: 700, fontSize: '1.2rem', color: BADGE[data.status] ?? '#374151' }}>
              {data.status.toUpperCase()}
            </span>
            <span style={{ color: '#64748b', fontSize: '.9rem' }}>Refreshed {new Date(data.refreshed_at).toLocaleTimeString()}</span>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(220px, 1fr))', gap: '1rem' }}>
            {[
              { name: 'database', comp: data.database },
              { name: 'scheduler', comp: data.scheduler },
            ].map(({ name, comp }) => (
              <div
                key={name}
                style={{
                  background: '#fff',
                  border: '1px solid #e2e8f0',
                  borderRadius: '6px',
                  padding: '1rem',
                  borderLeft: `4px solid ${BADGE[comp.status] ?? '#cbd5e1'}`,
                }}
              >
                <div style={{ fontWeight: 600, marginBottom: '.25rem', textTransform: 'capitalize' }}>{name}</div>
                <div style={{ fontSize: '.8rem', color: BADGE[comp.status] ?? '#374151', fontWeight: 600 }}>
                  {comp.status}
                </div>
                {comp.latency_ms !== undefined && (
                  <div style={{ fontSize: '.8rem', color: '#94a3b8', marginTop: '.25rem' }}>
                    {comp.latency_ms} ms
                  </div>
                )}
                {comp.detail && (
                  <div style={{ fontSize: '.8rem', color: '#64748b', marginTop: '.25rem' }}>{comp.detail}</div>
                )}
              </div>
            ))}
          </div>

          <div style={{ marginTop: '1rem', display: 'flex', gap: '1rem', color: '#64748b', fontSize: '.85rem' }}>
            <span>DB query latency: {data.db_query_latency_ms} ms</span>
            <span>Uptime: {data.uptime_seconds}s</span>
          </div>
        </>
      )}
    </div>
  )
}
