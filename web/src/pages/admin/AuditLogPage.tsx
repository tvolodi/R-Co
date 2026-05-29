import { useQuery } from '@tanstack/react-query'
import { client } from '@/api/client'
import { queryKeys } from '@/api/queryKeys'
import type { AuditEntry, CursorPage } from '@/types/api'

export default function AuditLogPage() {
  const { data, isLoading } = useQuery({
    queryKey: queryKeys.admin.audit(),
    queryFn: () => client.get<CursorPage<AuditEntry>>('/api/v1/audit'),
    refetchInterval: 30_000,
  })

  return (
    <div style={{ padding: '1.5rem' }}>
      <h2 style={{ marginBottom: '1.25rem' }}>Audit Log</h2>

      {isLoading && <p>Loading…</p>}

      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.85rem' }}>
        <thead>
          <tr style={{ background: '#f1f5f9', textAlign: 'left' }}>
            <th style={{ padding: '.6rem .8rem' }}>Time</th>
            <th style={{ padding: '.6rem .8rem' }}>Actor</th>
            <th style={{ padding: '.6rem .8rem' }}>Action</th>
            <th style={{ padding: '.6rem .8rem' }}>Entity</th>
            <th style={{ padding: '.6rem .8rem' }}>IP</th>
          </tr>
        </thead>
        <tbody>
          {(data?.items ?? []).map((e: AuditEntry) => (
            <tr key={e.id} style={{ borderBottom: '1px solid #e2e8f0' }}>
              <td style={{ padding: '.5rem .8rem', color: '#64748b', fontFamily: 'monospace', fontSize: '.8rem', whiteSpace: 'nowrap' }}>
                {new Date(e.occurred_at).toLocaleString()}
              </td>
              <td style={{ padding: '.5rem .8rem', fontSize: '.8rem' }}>{e.actor_email ?? e.actor_id?.slice(0, 8)}</td>
              <td style={{ padding: '.5rem .8rem', fontFamily: 'monospace', fontSize: '.8rem', fontWeight: 600 }}>{e.action}</td>
              <td style={{ padding: '.5rem .8rem', fontSize: '.8rem', color: '#64748b' }}>
                {e.entity_type}{e.entity_name ? ` / ${e.entity_name}` : ''}
              </td>
              <td style={{ padding: '.5rem .8rem', fontFamily: 'monospace', fontSize: '.8rem', color: '#94a3b8' }}>{e.ip_address ?? '—'}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
