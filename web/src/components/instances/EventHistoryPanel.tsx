import { useMemo, useState } from 'react'
import { useInstanceEvents, type EventFilters } from '@/hooks/useInstances'
import { EventJsonExpandable } from './EventJsonExpandable'

interface EventHistoryPanelProps {
  instanceId: string
}

function toDatetimeLocal(isoValue: string | undefined): string {
  if (!isoValue) return ''
  const date = new Date(isoValue)
  if (Number.isNaN(date.getTime())) return ''
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000)
  return local.toISOString().slice(0, 16)
}

function toIsoOrUndefined(value: string): string | undefined {
  if (!value) return undefined
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return undefined
  return date.toISOString()
}

function compactFilters(filters: EventFilters): EventFilters {
  const compacted: EventFilters = {}
  if (filters.event_type) compacted.event_type = filters.event_type
  if (filters.from) compacted.from = filters.from
  if (filters.to) compacted.to = filters.to
  return compacted
}

export function EventHistoryPanel({ instanceId }: EventHistoryPanelProps) {
  const [draftEventType, setDraftEventType] = useState('')
  const [draftFrom, setDraftFrom] = useState('')
  const [draftTo, setDraftTo] = useState('')
  const [appliedFilters, setAppliedFilters] = useState<EventFilters>({})

  const eventsQuery = useInstanceEvents(instanceId, appliedFilters)

  const eventTypeOptions = useMemo(() => {
    const values = new Set<string>()
    for (const event of eventsQuery.data ?? []) {
      if (event.event_type) values.add(event.event_type)
    }
    return Array.from(values).sort()
  }, [eventsQuery.data])

  const onApply = () => {
    const filters = compactFilters({
      event_type: draftEventType || undefined,
      from: toIsoOrUndefined(draftFrom),
      to: toIsoOrUndefined(draftTo),
    })
    setAppliedFilters(filters)
  }

  const onClear = () => {
    setDraftEventType('')
    setDraftFrom('')
    setDraftTo('')
    setAppliedFilters({})
  }

  return (
    <section>
      <div
        data-testid="event-history-filter-bar"
        style={{
          display: 'flex',
          gap: '.6rem',
          flexWrap: 'wrap',
          alignItems: 'end',
          marginBottom: '.85rem',
        }}
      >
        <label style={{ display: 'grid', gap: '.2rem', fontSize: '.82rem', color: '#334155' }}>
          Event type
          <select
            value={draftEventType}
            onChange={(e) => setDraftEventType(e.target.value)}
            style={{
              minWidth: '180px',
              border: '1px solid #cbd5e1',
              borderRadius: '4px',
              padding: '.35rem .45rem',
            }}
          >
            <option value="">All types</option>
            {eventTypeOptions.map((eventType) => (
              <option key={eventType} value={eventType}>
                {eventType}
              </option>
            ))}
          </select>
        </label>

        <label style={{ display: 'grid', gap: '.2rem', fontSize: '.82rem', color: '#334155' }}>
          From
          <input
            type="datetime-local"
            value={draftFrom}
            onChange={(e) => setDraftFrom(e.target.value)}
            style={{
              border: '1px solid #cbd5e1',
              borderRadius: '4px',
              padding: '.32rem .45rem',
            }}
          />
        </label>

        <label style={{ display: 'grid', gap: '.2rem', fontSize: '.82rem', color: '#334155' }}>
          To
          <input
            type="datetime-local"
            value={draftTo}
            onChange={(e) => setDraftTo(e.target.value)}
            style={{
              border: '1px solid #cbd5e1',
              borderRadius: '4px',
              padding: '.32rem .45rem',
            }}
          />
        </label>

        <button
          onClick={onApply}
          style={{
            padding: '.35rem .8rem',
            border: 'none',
            borderRadius: '4px',
            background: '#2563eb',
            color: '#ffffff',
            cursor: 'pointer',
          }}
        >
          Apply
        </button>

        <button
          onClick={onClear}
          style={{
            padding: '.35rem .8rem',
            border: '1px solid #cbd5e1',
            borderRadius: '4px',
            background: '#ffffff',
            cursor: 'pointer',
          }}
        >
          Clear
        </button>
      </div>

      {eventsQuery.isLoading && <p>Loading event history...</p>}
      {eventsQuery.error && (
        <p role="alert" style={{ color: '#dc2626' }}>
          Failed to load events.
        </p>
      )}

      {!eventsQuery.isLoading && !eventsQuery.error && (
        <>
          {(eventsQuery.data?.length ?? 0) > 0 ? (
            <>
              <div style={{ color: '#64748b', fontSize: '.8rem', marginBottom: '.45rem' }}>
                Showing {eventsQuery.data?.length ?? 0} events
              </div>
              <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.85rem' }}>
                <thead>
                  <tr style={{ background: '#f1f5f9', textAlign: 'left' }}>
                    <th style={{ padding: '.5rem .75rem' }}>#</th>
                    <th style={{ padding: '.5rem .75rem' }}>Type</th>
                    <th style={{ padding: '.5rem .75rem' }}>Actor</th>
                    <th style={{ padding: '.5rem .75rem' }}>Time</th>
                    <th style={{ padding: '.5rem .75rem' }}>Payload</th>
                  </tr>
                </thead>
                <tbody>
                  {(eventsQuery.data ?? []).map((event) => (
                    <tr key={event.event_id} style={{ borderBottom: '1px solid #e2e8f0', verticalAlign: 'top' }}>
                      <td style={{ padding: '.5rem .75rem', color: '#94a3b8', fontFamily: 'monospace' }}>
                        {event.sequence_number}
                      </td>
                      <td style={{ padding: '.5rem .75rem', fontFamily: 'monospace', fontSize: '.8rem' }}>
                        {event.event_type}
                      </td>
                      <td style={{ padding: '.5rem .75rem', color: '#64748b', fontFamily: 'monospace', fontSize: '.8rem' }}>
                        {typeof event.actor_id === 'string' && event.actor_id
                          ? event.actor_id.slice(0, 8)
                          : 'system'}
                      </td>
                      <td style={{ padding: '.5rem .75rem', color: '#64748b' }}>
                        {new Date(event.created_at).toLocaleString()}
                      </td>
                      <td style={{ padding: '.5rem .75rem', minWidth: '180px' }}>
                        <EventJsonExpandable payload={event.payload ?? {}} />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </>
          ) : (
            <p style={{ color: '#64748b', margin: 0 }}>No events match the current filters.</p>
          )}
        </>
      )}

      {(appliedFilters.from || appliedFilters.to) && (
        <div style={{ marginTop: '.6rem', color: '#64748b', fontSize: '.78rem' }}>
          Range: {toDatetimeLocal(appliedFilters.from)} - {toDatetimeLocal(appliedFilters.to)}
        </div>
      )}
    </section>
  )
}
