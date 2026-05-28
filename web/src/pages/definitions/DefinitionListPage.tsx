import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useDefinitions, useActivateDefinition, useArchiveDefinition } from '@/hooks/useDefinitions'
import type { DefinitionStatus } from '@/types/api'

const STATUS_BADGE: Record<string, string> = {
  DRAFT:      '#f59e0b',
  ACTIVE:     '#16a34a',
  DEPRECATED: '#9ca3af',
  ARCHIVED:   '#6b7280',
}

export default function DefinitionListPage() {
  const [status, setStatus] = useState<DefinitionStatus | undefined>()
  const { data, isLoading } = useDefinitions({ status })
  const activate = useActivateDefinition()
  const archive = useArchiveDefinition()

  return (
    <div style={{ padding: '1.5rem' }}>
      <div data-testid="filter-bar" style={{ display: 'flex', alignItems: 'center', gap: '1rem', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Process Definitions</h2>
        <select
          value={status ?? ''}
          onChange={(e) => setStatus((e.target.value as DefinitionStatus) || undefined)}
          style={{ padding: '.35rem .6rem', borderRadius: '4px', border: '1px solid #cbd5e1' }}
        >
          <option value="">All</option>
          <option value="DRAFT">Draft</option>
          <option value="ACTIVE">Active</option>
          <option value="DEPRECATED">Deprecated</option>
          <option value="ARCHIVED">Archived</option>
        </select>
        <Link
          to="/definitions/new"
          style={{ marginLeft: 'auto', padding: '.4rem .9rem', background: '#2563eb', color: '#fff', borderRadius: '4px', textDecoration: 'none', fontSize: '.85rem' }}
        >
          + New
        </Link>
      </div>

      {isLoading && <p>Loading…</p>}

      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.9rem' }}>
        <thead>
          <tr style={{ background: '#f1f5f9', textAlign: 'left' }}>
            <th style={{ padding: '.6rem .8rem' }}>Name</th>
            <th style={{ padding: '.6rem .8rem' }}>Version</th>
            <th style={{ padding: '.6rem .8rem' }}>Status</th>
            <th style={{ padding: '.6rem .8rem' }}>Updated</th>
            <th style={{ padding: '.6rem .8rem' }}>Actions</th>
          </tr>
        </thead>
        <tbody>
          {(data?.items ?? []).map((def) => (
            <tr key={def.id} style={{ borderBottom: '1px solid #e2e8f0' }}>
              <td style={{ padding: '.6rem .8rem' }}>
                <Link to={`/definitions/${def.id}`} style={{ color: '#2563eb', textDecoration: 'none' }}>
                  {def.name}
                </Link>
              </td>
              <td style={{ padding: '.6rem .8rem', color: '#64748b' }}>{def.version}</td>
              <td style={{ padding: '.6rem .8rem' }}>
                <span style={{ color: STATUS_BADGE[def.status] ?? '#374151', fontWeight: 600, fontSize: '.8rem' }}>
                  {def.status}
                </span>
              </td>
              <td style={{ padding: '.6rem .8rem', color: '#94a3b8', fontSize: '.8rem' }}>
                {new Date(def.updated_at).toLocaleDateString()}
              </td>
              <td style={{ padding: '.6rem .8rem', display: 'flex', gap: '.5rem' }}>
                {def.status === 'DRAFT' && (
                  <button
                    onClick={() => activate.mutate(def.id)}
                    style={{ padding: '.25rem .6rem', background: '#16a34a', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.8rem' }}
                  >
                    Activate
                  </button>
                )}
                {(def.status === 'ACTIVE' || def.status === 'DEPRECATED') && (
                  <button
                    onClick={() => archive.mutate(def.id)}
                    style={{ padding: '.25rem .6rem', background: '#6b7280', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.8rem' }}
                  >
                    Archive
                  </button>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
