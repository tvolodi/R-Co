import { Navigate } from 'react-router-dom'
import { useQuery, type UseQueryResult } from '@tanstack/react-query'
import { queryKeys } from '@/api/queryKeys'
import { metricsApi, parsePrometheusText, type PrometheusMetricFamily } from '@/api/metrics'
import { useAuth } from '@/auth/AuthContext'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'

export function usePrometheusMetrics(): UseQueryResult<PrometheusMetricFamily[]> {
  return useQuery({
    queryKey: queryKeys.admin.metrics(),
    queryFn: async () => {
      const text = await metricsApi.prometheusText()
      return parsePrometheusText(text)
    },
    refetchInterval: 30_000,
  })
}

export default function MetricsPage() {
  const { session } = useAuth()
  const isPlatformAdmin = Boolean(session?.roles.includes('PLATFORM_ADMIN'))
  const { data, isLoading, isError, error, isFetching, refetch } = usePrometheusMetrics()

  if (!isPlatformAdmin) {
    return <Navigate to="/instances" replace />
  }

  const rendererState: RendererState = isLoading ? 'loading' : isError ? classifyError(error) : 'success'
  const showParseError = (error as Error | null)?.message === 'PROM_PARSE_ERROR'

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: '.75rem', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Metrics</h2>
        {isFetching && <span style={{ fontSize: '.8rem', color: '#0369a1' }}>Refreshing…</span>}
      </div>

      <QueryStateBoundary
        state={rendererState}
        onRetry={() => { void refetch() }}
        columns={[{ widthPercent: 40 }, { widthPercent: 40 }, { widthPercent: 20 }]}
      >
      {showParseError && (
        <div style={{ marginBottom: '1rem', padding: '.75rem .9rem', borderRadius: '6px', border: '1px solid #fca5a5', background: '#fff1f2', color: '#9f1239' }}>
          Metrics payload could not be parsed as Prometheus exposition text.
        </div>
      )}

      {data && data.length === 0 && (
        <div style={{ marginTop: '.5rem', color: '#64748b' }}>No metrics are currently exposed.</div>
      )}

      {(data ?? []).map((family) => (
        <section key={family.name} style={{ marginBottom: '1.25rem', background: '#fff', border: '1px solid #e2e8f0', borderRadius: '6px', overflow: 'hidden' }}>
          <header style={{ padding: '.65rem .8rem', background: '#f8fafc', borderBottom: '1px solid #e2e8f0' }}>
            <div style={{ display: 'flex', gap: '.6rem', alignItems: 'center' }}>
              <strong style={{ fontFamily: 'monospace' }}>{family.name}</strong>
              <span style={{ fontSize: '.75rem', color: '#475569', textTransform: 'uppercase' }}>{family.type}</span>
            </div>
            {family.help && <div style={{ marginTop: '.2rem', color: '#64748b', fontSize: '.8rem' }}>{family.help}</div>}
          </header>

          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.84rem' }}>
            <thead>
              <tr style={{ textAlign: 'left' }}>
                <th style={{ padding: '.5rem .8rem', borderBottom: '1px solid #e2e8f0' }}>Sample</th>
                <th style={{ padding: '.5rem .8rem', borderBottom: '1px solid #e2e8f0' }}>Labels</th>
                <th style={{ padding: '.5rem .8rem', borderBottom: '1px solid #e2e8f0' }}>Value</th>
              </tr>
            </thead>
            <tbody>
              {family.samples.map((sample, idx) => (
                <tr key={`${sample.name}-${idx}`} style={{ borderBottom: '1px solid #f1f5f9' }}>
                  <td style={{ padding: '.45rem .8rem', fontFamily: 'monospace', fontSize: '.8rem' }}>{sample.name}</td>
                  <td style={{ padding: '.45rem .8rem', color: '#64748b', fontFamily: 'monospace', fontSize: '.78rem' }}>
                    {Object.entries(sample.labels).length > 0
                      ? Object.entries(sample.labels).map(([k, v]) => `${k}=${v}`).join(', ')
                      : '—'}
                  </td>
                  <td style={{ padding: '.45rem .8rem', fontFamily: 'monospace', fontWeight: 600 }}>{sample.value}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      ))}      </QueryStateBoundary>    </div>
  )
}
