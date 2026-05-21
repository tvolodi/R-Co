import { useQuery } from '@tanstack/react-query'
import { client } from '@/api/client'

interface MetricSnapshot {
  name: string
  labels: Record<string, string>
  value: number
  captured_at: string
}

export default function MetricsPage() {
  const { data, isLoading } = useQuery({
    queryKey: ['admin', 'metrics'],
    queryFn: () => client.get<{ items: MetricSnapshot[] }>('/api/v1/admin/metrics'),
    refetchInterval: 30_000,
  })

  return (
    <div style={{ padding: '1.5rem' }}>
      <h2 style={{ marginBottom: '1.25rem' }}>Metrics</h2>

      {isLoading && <p>Loading…</p>}

      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.875rem' }}>
        <thead>
          <tr style={{ background: '#f1f5f9', textAlign: 'left' }}>
            <th style={{ padding: '.6rem .8rem' }}>Metric</th>
            <th style={{ padding: '.6rem .8rem' }}>Labels</th>
            <th style={{ padding: '.6rem .8rem' }}>Value</th>
            <th style={{ padding: '.6rem .8rem' }}>Captured</th>
          </tr>
        </thead>
        <tbody>
          {(data?.items ?? []).map((m, i) => (
            <tr key={i} style={{ borderBottom: '1px solid #e2e8f0' }}>
              <td style={{ padding: '.5rem .8rem', fontFamily: 'monospace', fontSize: '.8rem' }}>{m.name}</td>
              <td style={{ padding: '.5rem .8rem', fontSize: '.8rem', color: '#64748b' }}>
                {Object.entries(m.labels).map(([k, v]) => `${k}=${v}`).join(' ')}
              </td>
              <td style={{ padding: '.5rem .8rem', fontFamily: 'monospace', fontWeight: 600 }}>
                {typeof m.value === 'number' ? m.value.toLocaleString() : m.value}
              </td>
              <td style={{ padding: '.5rem .8rem', fontSize: '.8rem', color: '#94a3b8' }}>
                {new Date(m.captured_at).toLocaleTimeString()}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
