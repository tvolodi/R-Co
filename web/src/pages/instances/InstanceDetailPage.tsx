import { useEffect, useMemo, useState } from 'react'
import { useParams } from 'react-router-dom'
import { ReactFlow, Background, Controls, MiniMap, type Node, type Edge } from '@xyflow/react'
import '@xyflow/react/dist/style.css'
import { useInstance, useInstanceEvents, useCancelInstance, useInstanceTimeline } from '@/hooks/useInstances'
import { useTasks } from '@/hooks/useTasks'
import { useDefinition } from '@/hooks/useDefinitions'
import { graphToFlow, type CanvasNodeData, type CanvasEdgeData } from '@/utils/canvas/graphToFlow'
import { getTimelineActorDisplayName, getTimelineSecondaryContext, mergeTimelineItems } from './timelineUtils'
import type { TimelineEntry } from '@/types/api'

const STATUS_COLORS: Record<string, string> = {
  ACTIVE: '#2563eb',
  COMPLETED: '#16a34a',
  CANCELLED: '#6b7280',
  ERROR: '#dc2626',
}

function formatDateTime(value: string | undefined): string {
  if (!value) return '—'
  return new Date(value).toLocaleString()
}

function useReadonlyGraph(
  definitionGraph: unknown,
  activeNodeIds: string[],
): { nodes: Node<CanvasNodeData>[]; edges: Edge<CanvasEdgeData>[] } {
  return useMemo(() => {
    if (!definitionGraph || typeof definitionGraph !== 'object') {
      return { nodes: [], edges: [] }
    }

    const asGraph = definitionGraph as { nodes?: unknown[]; edges?: unknown[] }
    if (!Array.isArray(asGraph.nodes) || !Array.isArray(asGraph.edges)) {
      return { nodes: [], edges: [] }
    }

    const { nodes, edges } = graphToFlow(definitionGraph as never)
    const highlighted = new Set(activeNodeIds)

    return {
      nodes: nodes.map((node) => {
        const isActive = highlighted.has(node.id)
        return {
          ...node,
          style: {
            ...(node.style ?? {}),
            border: isActive ? '2px solid #2563eb' : '1px solid #cbd5e1',
            boxShadow: isActive ? '0 0 0 4px rgba(37, 99, 235, 0.18)' : undefined,
          },
        }
      }),
      edges,
    }
  }, [definitionGraph, activeNodeIds])
}

export default function InstanceDetailPage() {
  const { id } = useParams<{ id: string }>()
  const { data: instance, isLoading } = useInstance(id!)
  const { data: definition } = useDefinition(instance?.definition_id ?? '')
  const { data: pendingTasks } = useTasks({ status: 'PENDING', instance_id: id })
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

  const currentNodes = Array.isArray(instance?.current_nodes) ? instance.current_nodes : []
  const instanceVariables = instance?.variables && typeof instance.variables === 'object' ? instance.variables : {}
  const instanceGraph = instance?.definition_snapshot ?? definition?.graph
  const readonlyGraph = useReadonlyGraph(instanceGraph, currentNodes)

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

      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.9rem', marginBottom: '1rem' }}>
        <tbody>
          {[
            ['Definition', `${instance.definition_name} v${instance.definition_version}`],
            ['Status', instance.status],
            ['Active nodes', currentNodes.join(', ') || '—'],
            ['Correlation key', instance.correlation_key ?? '—'],
            ['Started at', formatDateTime(instance.started_at)],
            ['Last updated', formatDateTime(instance.updated_at ?? instance.started_at)],
            ['Completed at', formatDateTime(instance.completed_at)],
          ].map(([k, v]) => (
            <tr key={k as string} style={{ borderBottom: '1px solid #e2e8f0' }}>
              <td style={{ padding: '.5rem .75rem', color: '#64748b', width: '180px', fontWeight: 500 }}>{k}</td>
              <td style={{ padding: '.5rem .75rem' }}>
                {k === 'Status' ? (
                  <span style={{ color: STATUS_COLORS[String(v)] ?? '#334155', fontWeight: 700 }}>{v}</span>
                ) : v}
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      <section style={{ marginBottom: '1rem' }}>
        <h3 style={{ marginBottom: '.5rem' }}>Definition Snapshot</h3>
        <div style={{ display: 'grid', gap: '.35rem', color: '#475569', fontSize: '.85rem' }}>
          <div>Definition ID: <code>{instance.definition_id}</code></div>
          <div>Source: {instance.definition_snapshot ? 'Stored snapshot' : 'Current definition version'}</div>
          <div>Active tokens: {currentNodes.join(', ') || '—'}</div>
        </div>

        <div style={{ marginTop: '.75rem', height: '320px', border: '1px solid #e2e8f0', borderRadius: '6px', overflow: 'hidden' }}>
          {readonlyGraph.nodes.length === 0 ? (
            <div style={{ padding: '1rem', color: '#64748b', fontSize: '.85rem' }}>
              No graph snapshot is available for this instance.
            </div>
          ) : (
            <ReactFlow
              data-testid="instance-readonly-graph"
              nodes={readonlyGraph.nodes}
              edges={readonlyGraph.edges}
              nodesDraggable={false}
              nodesConnectable={false}
              elementsSelectable={false}
              fitView
              proOptions={{ hideAttribution: true }}
            >
              <Background color="#e2e8f0" gap={20} />
              <MiniMap />
              <Controls />
            </ReactFlow>
          )}
        </div>
      </section>

      <h3 style={{ marginBottom: '.75rem' }}>Variables</h3>
      <pre style={{ background: '#f1f5f9', padding: '1rem', borderRadius: '4px', fontSize: '.8rem', overflow: 'auto', marginBottom: '1.5rem' }}>
        {JSON.stringify(instanceVariables, null, 2)}
      </pre>

      <section style={{ marginBottom: '1.25rem' }}>
        <h3 style={{ marginBottom: '.5rem' }}>Active Tasks</h3>
        {pendingTasks?.items && pendingTasks.items.length > 0 ? (
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.85rem' }}>
            <thead>
              <tr style={{ background: '#f1f5f9', textAlign: 'left' }}>
                <th style={{ padding: '.5rem .75rem' }}>Task ID</th>
                <th style={{ padding: '.5rem .75rem' }}>Node</th>
                <th style={{ padding: '.5rem .75rem' }}>Name</th>
                <th style={{ padding: '.5rem .75rem' }}>Assignee</th>
                <th style={{ padding: '.5rem .75rem' }}>Created</th>
              </tr>
            </thead>
            <tbody>
              {pendingTasks.items.map((task, index) => {
                const taskId = typeof task.id === 'string'
                  ? task.id
                  : (typeof (task as unknown as { task_id?: unknown }).task_id === 'string'
                    ? (task as unknown as { task_id: string }).task_id
                    : '')
                const taskNodeId = typeof task.node_id === 'string' ? task.node_id : '—'
                const taskNodeName = typeof task.node_name === 'string' ? task.node_name : '—'
                const taskAssignee = typeof task.assignee_ref === 'string' ? task.assignee_ref : '—'
                return (
                <tr key={taskId || `task-${index}`} style={{ borderBottom: '1px solid #e2e8f0' }}>
                  <td style={{ padding: '.5rem .75rem', fontFamily: 'monospace' }}>{taskId ? `${taskId.slice(0, 8)}...` : '—'}</td>
                  <td style={{ padding: '.5rem .75rem' }}>{taskNodeId}</td>
                  <td style={{ padding: '.5rem .75rem' }}>{taskNodeName}</td>
                  <td style={{ padding: '.5rem .75rem' }}>{taskAssignee}</td>
                  <td style={{ padding: '.5rem .75rem', color: '#64748b' }}>{formatDateTime(task.created_at)}</td>
                </tr>
              )})}
            </tbody>
          </table>
        ) : (
          <p style={{ margin: 0, color: '#64748b', fontSize: '.85rem' }}>No active tasks.</p>
        )}
      </section>

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
                  <td style={{ padding: '.5rem .75rem', color: '#64748b', fontFamily: 'monospace', fontSize: '.8rem' }}>{typeof ev.actor_id === 'string' ? ev.actor_id.slice(0, 8) : 'system'}</td>
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
