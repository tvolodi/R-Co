import { useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import { useInstance, useInstanceEvents, useCancelInstance, useInstanceTimeline } from '@/hooks/useInstances'
import { getTimelineActorDisplayName, getTimelineSecondaryContext, mergeTimelineItems } from './timelineUtils'
import type { TimelineEntry } from '@/types/api'

export default function InstanceDetailPage() {
  const { id } = useParams<{ id: string }>()
  const { data: instance, isLoading } = useInstance(id!)
  const { data: events } = useInstanceEvents(id!)
  const cancel = useCancelInstance()
  const [activeTab, setActiveTab] = useState<'history' | 'timeline'>('history')
  const [timelineCursor, setTimelineCursor] = useState<string | undefined>(undefined)
  const [timelineItems, setTimelineItems] = useState<TimelineEntry[]>([])
  const [timelineRequested, setTimelineRequested] = useState(false)
  const [lastAppliedCursor, setLastAppliedCursor] = useState<string>('')

  const timelineQuery = useInstanceTimeline(
    id!,
    { cursor: timelineCursor, page_size: 50 },
    timelineRequested,
  )

  useEffect(() => {
    if (activeTab === 'timeline' && !timelineRequested) {
      setTimelineRequested(true)
      setTimelineCursor(undefined)
      setLastAppliedCursor('')
      setTimelineItems([])
    }
  }, [activeTab, timelineRequested])

  useEffect(() => {
    if (!timelineQuery.data) return

    const cursorKey = timelineCursor ?? ''
    if (lastAppliedCursor === cursorKey) return

    setTimelineItems((current) =>
      mergeTimelineItems(current, timelineQuery.data.items, timelineCursor),
    )
    setLastAppliedCursor(cursorKey)
  }, [timelineCursor, timelineQuery.data, lastAppliedCursor])

  const onTimelineLoadMore = () => {
    if (!timelineQuery.data?.next_cursor) return
    setTimelineCursor(timelineQuery.data.next_cursor)
  }

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

      <div style={{ display: 'flex', gap: '.5rem', borderBottom: '1px solid #e2e8f0', marginBottom: '1rem' }}>
        <button
          onClick={() => setActiveTab('history')}
          style={{
            border: 'none',
            borderBottom: activeTab === 'history' ? '2px solid #2563eb' : '2px solid transparent',
            background: 'transparent',
            color: activeTab === 'history' ? '#1e40af' : '#475569',
            fontWeight: 600,
            padding: '.5rem .25rem',
            cursor: 'pointer',
          }}
        >
          History
        </button>
        <button
          onClick={() => setActiveTab('timeline')}
          style={{
            border: 'none',
            borderBottom: activeTab === 'timeline' ? '2px solid #2563eb' : '2px solid transparent',
            background: 'transparent',
            color: activeTab === 'timeline' ? '#1e40af' : '#475569',
            fontWeight: 600,
            padding: '.5rem .25rem',
            cursor: 'pointer',
          }}
        >
          Timeline
        </button>
      </div>

      {activeTab === 'history' && (
        <>
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
        </>
      )}

      {activeTab === 'timeline' && (
        <>
          <h3 style={{ marginBottom: '.75rem' }}>Timeline</h3>
          {timelineQuery.isLoading && timelineItems.length === 0 && <p>Loading timeline…</p>}
          {timelineQuery.error && timelineItems.length === 0 && (
            <p style={{ color: '#dc2626' }}>Failed to load timeline.</p>
          )}
          {timelineItems.length === 0 && !timelineQuery.isLoading && !timelineQuery.error && (
            <p style={{ color: '#64748b' }}>No timeline entries found.</p>
          )}

          <div style={{ borderLeft: '2px solid #dbeafe', paddingLeft: '1rem', display: 'grid', gap: '1rem' }}>
            {timelineItems.map((item) => {
              const actorDisplay = getTimelineActorDisplayName(item.actor_display_name)
              const secondaryContext = getTimelineSecondaryContext(item)
              return (
                <article key={item.event_id} style={{ position: 'relative' }}>
                  <span
                    aria-hidden
                    style={{
                      position: 'absolute',
                      left: '-1.44rem',
                      top: '.42rem',
                      width: '.55rem',
                      height: '.55rem',
                      borderRadius: '9999px',
                      background: '#2563eb',
                    }}
                  />
                  <div style={{ display: 'flex', justifyContent: 'space-between', gap: '.75rem', flexWrap: 'wrap' }}>
                    <strong style={{ color: '#0f172a', fontSize: '.9rem' }}>{item.description}</strong>
                    <span style={{ color: '#475569', fontSize: '.8rem' }}>{new Date(item.timestamp).toLocaleString()}</span>
                  </div>
                  <div style={{ color: '#475569', fontSize: '.8rem', marginTop: '.25rem' }}>
                    {item.event_type} • {actorDisplay} • seq {item.sequence_num}
                  </div>
                  {secondaryContext && (
                    <div style={{ color: '#64748b', fontSize: '.8rem', marginTop: '.15rem' }}>
                      {secondaryContext}
                    </div>
                  )}
                  {Object.keys(item.metadata ?? {}).length > 0 && (
                    <details style={{ marginTop: '.4rem' }}>
                      <summary style={{ color: '#334155', fontSize: '.8rem', cursor: 'pointer' }}>Metadata</summary>
                      <pre style={{ background: '#f8fafc', padding: '.65rem', borderRadius: '4px', fontSize: '.75rem', overflow: 'auto' }}>
                        {JSON.stringify(item.metadata, null, 2)}
                      </pre>
                    </details>
                  )}
                </article>
              )
            })}
          </div>

          <div style={{ marginTop: '1rem', display: 'flex', alignItems: 'center', gap: '.75rem' }}>
            <span style={{ color: '#64748b', fontSize: '.8rem' }}>Loaded {timelineItems.length} entries</span>
            {timelineQuery.data?.next_cursor && (
              <button
                onClick={onTimelineLoadMore}
                disabled={timelineQuery.isFetching}
                style={{
                  padding: '.35rem .8rem',
                  border: '1px solid #cbd5e1',
                  borderRadius: '4px',
                  background: '#fff',
                  cursor: 'pointer',
                  fontSize: '.85rem',
                }}
              >
                {timelineQuery.isFetching ? 'Loading…' : 'Load more'}
              </button>
            )}
          </div>
        </>
      )}
    </div>
  )
}
