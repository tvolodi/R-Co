import { useParams } from 'react-router-dom'
import { useInstance, useInstanceEvents, useCancelInstance } from '@/hooks/useInstances'

export default function InstanceDetailPage() {
  const { id } = useParams<{ id: string }>()
  const { data: instance, isLoading } = useInstance(id!)
  const { data: events } = useInstanceEvents(id!)
  const cancel = useCancelInstance()

  if (isLoading) return <p style={{ padding: '1.5rem' }}>Loading…</p>
  if (!instance) return <p style={{ padding: '1.5rem', color: '#dc2626' }}>Instance not found.</p>

  return (
    <div style={{ padding: '1.5rem', maxWidth: '900px' }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: '1rem', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Instance</h2>
        <code style={{ fontSize: '.8rem', color: '#64748b' }}>{instance.instance_id}</code>
        {instance.status === 'ACTIVE' && (
          <button
            onClick={() => cancel.mutate({ id: instance.instance_id })}
            disabled={cancel.isPending}
            style={{ marginLeft: 'auto', padding: '.35rem .8rem', background: '#dc2626', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
          >
            Cancel
          </button>
        )}
      </div>

      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.9rem', marginBottom: '1.5rem' }}>
        <tbody>
          {[
            ['Definition', `${instance.definition_name} v${instance.definition_version}`],
            ['Status', instance.status],
            ['Active nodes', instance.current_nodes.join(', ') || '—'],
            ['Correlation key', instance.correlation_key ?? '—'],
            ['Started at', new Date(instance.started_at).toLocaleString()],
            ['Completed at', instance.completed_at ? new Date(instance.completed_at).toLocaleString() : '—'],
          ].map(([k, v]) => (
            <tr key={k as string} style={{ borderBottom: '1px solid #e2e8f0' }}>
              <td style={{ padding: '.5rem .75rem', color: '#64748b', width: '180px', fontWeight: 500 }}>{k}</td>
              <td style={{ padding: '.5rem .75rem' }}>{v}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <h3 style={{ marginBottom: '.75rem' }}>Variables</h3>
      <pre style={{ background: '#f1f5f9', padding: '1rem', borderRadius: '4px', fontSize: '.8rem', overflow: 'auto', marginBottom: '1.5rem' }}>
        {JSON.stringify(instance.variables, null, 2)}
      </pre>

      <h3 style={{ marginBottom: '.75rem' }}>Event log</h3>
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.85rem' }}>
        <thead>
          <tr style={{ background: '#f1f5f9', textAlign: 'left' }}>
            <th style={{ padding: '.5rem .75rem' }}>#</th>
            <th style={{ padding: '.5rem .75rem' }}>Type</th>
            <th style={{ padding: '.5rem .75rem' }}>Actor</th>
            <th style={{ padding: '.5rem .75rem' }}>Time</th>
          </tr>
        </thead>
        <tbody>
          {(events ?? []).map((ev) => (
            <tr key={ev.event_id} style={{ borderBottom: '1px solid #e2e8f0' }}>
              <td style={{ padding: '.5rem .75rem', color: '#94a3b8', fontFamily: 'monospace' }}>{ev.sequence_number}</td>
              <td style={{ padding: '.5rem .75rem', fontFamily: 'monospace', fontSize: '.8rem' }}>{ev.event_type}</td>
              <td style={{ padding: '.5rem .75rem', color: '#64748b', fontFamily: 'monospace', fontSize: '.8rem' }}>{ev.actor_id.slice(0, 8)}</td>
              <td style={{ padding: '.5rem .75rem', color: '#64748b' }}>{new Date(ev.created_at).toLocaleString()}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
