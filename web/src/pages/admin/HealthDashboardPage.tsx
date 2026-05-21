import { useQuery } from '@tanstack/react-query'
import { healthApi } from '@/api/health'

const BADGE: Record<string, string> = { ok: '#16a34a', degraded: '#f59e0b', error: '#dc2626' }

export default function HealthDashboardPage() {
  const { data, isLoading, dataUpdatedAt } = useQuery({
    queryKey: ['admin', 'health'],
    queryFn: () => healthApi.get(),
    refetchInterval: 10_000,
  })

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: '1rem', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Health</h2>
        {dataUpdatedAt > 0 && (
          <span style={{ fontSize: '.8rem', color: '#94a3b8' }}>
            Updated {new Date(dataUpdatedAt).toLocaleTimeString()}
          </span>
        )}
      </div>

      {isLoading && <p>Loading…</p>}

      {data && (
        <>
          <div style={{ display: 'flex', alignItems: 'center', gap: '.75rem', marginBottom: '1.5rem' }}>
            <span style={{ fontWeight: 700, fontSize: '1.2rem', color: BADGE[data.status] ?? '#374151' }}>
              {data.status.toUpperCase()}
            </span>
            <span style={{ color: '#64748b', fontSize: '.9rem' }}>v{data.version}</span>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(220px, 1fr))', gap: '1rem' }}>
            {Object.entries(data.components).map(([name, comp]) => (
              <div
                key={name}
                style={{
                  background: '#fff',
                  border: '1px solid #e2e8f0',
                  borderRadius: '6px',
                  padding: '1rem',
                  borderLeft: `4px solid ${BADGE[(comp as { status: string }).status] ?? '#cbd5e1'}`,
                }}
              >
                <div style={{ fontWeight: 600, marginBottom: '.25rem' }}>{name}</div>
                <div style={{ fontSize: '.8rem', color: BADGE[(comp as { status: string }).status] ?? '#374151', fontWeight: 600 }}>
                  {(comp as { status: string }).status}
                </div>
                {(comp as { latency_ms?: number }).latency_ms !== undefined && (
                  <div style={{ fontSize: '.8rem', color: '#94a3b8', marginTop: '.25rem' }}>
                    {(comp as { latency_ms: number }).latency_ms} ms
                  </div>
                )}
              </div>
            ))}
          </div>
        </>
      )}
    </div>
  )
}
