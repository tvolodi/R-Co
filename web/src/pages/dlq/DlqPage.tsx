import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { dlqApi } from '@/api/dlq'
import type { DlqEntry } from '@/types/api'

const STATUS_COLOR: Record<string, string> = {
  pending:   '#f59e0b',
  retrying:  '#3b82f6',
  resolved:  '#16a34a',
  discarded: '#9ca3af',
}

export default function DlqPage() {
  const qc = useQueryClient()

  const { data, isLoading } = useQuery({
    queryKey: ['dlq'],
    queryFn: () => dlqApi.list(),
  })

  const retry = useMutation({
    mutationFn: (id: string) => dlqApi.retry(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['dlq'] }),
  })

  const discard = useMutation({
    mutationFn: (id: string) => dlqApi.discard(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['dlq'] }),
  })

  return (
    <div style={{ padding: '1.5rem' }}>
      <h2 style={{ marginBottom: '1.25rem' }}>Dead-Letter Queue</h2>

      {isLoading && <p>Loading…</p>}

      {data?.items?.length === 0 && (
        <p style={{ color: '#64748b' }}>Queue is empty.</p>
      )}

      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.875rem' }}>
        <thead>
          <tr style={{ background: '#f1f5f9', textAlign: 'left' }}>
            <th style={{ padding: '.6rem .8rem' }}>Type</th>
            <th style={{ padding: '.6rem .8rem' }}>Instance</th>
            <th style={{ padding: '.6rem .8rem' }}>Reason</th>
            <th style={{ padding: '.6rem .8rem' }}>Attempts</th>
            <th style={{ padding: '.6rem .8rem' }}>Status</th>
            <th style={{ padding: '.6rem .8rem' }}>Next retry</th>
            <th style={{ padding: '.6rem .8rem' }}>Actions</th>
          </tr>
        </thead>
        <tbody>
          {(data?.items ?? []).map((e: DlqEntry) => (
            <tr key={e.id} style={{ borderBottom: '1px solid #e2e8f0' }}>
              <td style={{ padding: '.5rem .8rem', fontFamily: 'monospace', fontSize: '.8rem' }}>{e.entry_type}</td>
              <td style={{ padding: '.5rem .8rem', fontFamily: 'monospace', fontSize: '.75rem', color: '#64748b' }}>{e.instance_id?.slice(0, 8)}…</td>
              <td style={{ padding: '.5rem .8rem', fontSize: '.8rem', color: '#64748b', maxWidth: '240px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{e.reason}</td>
              <td style={{ padding: '.5rem .8rem', textAlign: 'center' }}>{e.retry_count}/{e.max_retries}</td>
              <td style={{ padding: '.5rem .8rem' }}>
                <span style={{ color: STATUS_COLOR[e.status] ?? '#374151', fontWeight: 600, fontSize: '.8rem' }}>{e.status}</span>
              </td>
              <td style={{ padding: '.5rem .8rem', fontSize: '.8rem', color: '#94a3b8' }}>
                {e.next_retry_at ? new Date(e.next_retry_at).toLocaleString() : '—'}
              </td>
              <td style={{ padding: '.5rem .8rem', display: 'flex', gap: '.4rem' }}>
                {e.status !== 'resolved' && e.status !== 'discarded' && (
                  <>
                    <button
                      onClick={() => retry.mutate(e.id)}
                      style={{ padding: '.25rem .5rem', background: '#2563eb', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.75rem' }}
                    >
                      Retry
                    </button>
                    <button
                      onClick={() => discard.mutate(e.id)}
                      style={{ padding: '.25rem .5rem', background: '#6b7280', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.75rem' }}
                    >
                      Discard
                    </button>
                  </>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
