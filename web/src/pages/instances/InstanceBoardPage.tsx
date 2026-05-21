import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useInstances } from '@/hooks/useInstances'
import type { InstanceStatus } from '@/types/api'

const STATUS_COLORS: Record<string, string> = {
  ACTIVE:    '#2563eb',
  COMPLETED: '#16a34a',
  CANCELLED: '#6b7280',
  ERROR:     '#dc2626',
}

export default function InstanceBoardPage() {
  const [status, setStatus] = useState<InstanceStatus | undefined>('ACTIVE')
  const { data, isLoading, error } = useInstances({ status })

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: '1rem', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Instances</h2>
        <select
          value={status ?? ''}
          onChange={(e) => setStatus((e.target.value as InstanceStatus) || undefined)}
          style={{ padding: '.35rem .6rem', borderRadius: '4px', border: '1px solid #cbd5e1' }}
        >
          <option value="">All</option>
          <option value="ACTIVE">Active</option>
          <option value="COMPLETED">Completed</option>
          <option value="CANCELLED">Cancelled</option>
          <option value="ERROR">Error</option>
        </select>
      </div>

      {isLoading && <p>Loading…</p>}
      {error && <p style={{ color: '#dc2626' }}>Failed to load instances.</p>}

      {data?.items && (
        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.9rem' }}>
          <thead>
            <tr style={{ background: '#f1f5f9', textAlign: 'left' }}>
              <th style={{ padding: '.6rem .8rem' }}>Instance ID</th>
              <th style={{ padding: '.6rem .8rem' }}>Definition</th>
              <th style={{ padding: '.6rem .8rem' }}>Status</th>
              <th style={{ padding: '.6rem .8rem' }}>Current Nodes</th>
              <th style={{ padding: '.6rem .8rem' }}>Started</th>
            </tr>
          </thead>
          <tbody>
            {data.items.map((inst) => (
              <tr key={inst.instance_id} style={{ borderBottom: '1px solid #e2e8f0' }}>
                <td style={{ padding: '.6rem .8rem', fontFamily: 'monospace', fontSize: '.8rem' }}>
                  <Link to={`/instances/${inst.instance_id}`} style={{ color: '#2563eb' }}>
                    {inst.instance_id.slice(0, 8)}…
                  </Link>
                </td>
                <td style={{ padding: '.6rem .8rem' }}>{inst.definition_name} v{inst.definition_version}</td>
                <td style={{ padding: '.6rem .8rem' }}>
                  <span style={{
                    color: STATUS_COLORS[inst.status] ?? '#374151',
                    fontWeight: 600,
                    fontSize: '.8rem',
                  }}>
                    {inst.status}
                  </span>
                </td>
                <td style={{ padding: '.6rem .8rem', color: '#64748b', fontSize: '.8rem' }}>
                  {inst.current_nodes.join(', ')}
                </td>
                <td style={{ padding: '.6rem .8rem', color: '#64748b', fontSize: '.8rem' }}>
                  {new Date(inst.started_at).toLocaleString()}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  )
}
