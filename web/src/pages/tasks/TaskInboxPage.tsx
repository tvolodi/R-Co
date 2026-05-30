import { useState, useMemo } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useTaskInbox, useCompleteTask, useTask, useClaimTask } from '@/hooks/useTasks'
import { useAuth } from '@/auth/AuthContext'

type FilterType = 'me' | 'group' | 'all'
type SortOrder = 'created' | '-created'

// Decode JWT to extract user ID (sub claim)
function decodeJwtPayload(token: string): { sub?: string; preferred_username?: string; [key: string]: unknown } {
  try {
    const parts = token.split('.')
    if (parts.length !== 3) throw new Error('Invalid JWT token')
    const decoded = JSON.parse(atob(parts[1]))
    return decoded
  } catch {
    return {}
  }
}

export default function TaskInboxPage() {
  const { session } = useAuth()
  const [searchParams, setSearchParams] = useSearchParams()
  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(null)

  // Parse URL search params
  const filter = (searchParams.get('filter') ?? 'me') as FilterType
  const sort = (searchParams.get('sort') ?? '-created') as SortOrder
  const search = searchParams.get('search') ?? ''

  const { data: inboxData, isLoading: inboxLoading } = useTaskInbox()

  // Extract user ID from JWT token
  const userId = useMemo(() => {
    if (!session?.token) return null
    const payload = decodeJwtPayload(session.token)
    return payload.sub || null
  }, [session?.token])

  // Filter and sort tasks
  const filteredTasks = useMemo(() => {
    if (!inboxData?.items) return []

    let results = inboxData.items

    // Filter by type
    if (filter === 'me') {
      results = results.filter(t => t.assignee_ref === userId)
    } else if (filter === 'group') {
      // TODO: filter by user's groups once implemented
    }

    // Filter by search query
    if (search) {
      const q = search.toLowerCase()
      results = results.filter(t =>
        t.node_name.toLowerCase().includes(q)
      )
    }

    // Sort
    if (sort === '-created') {
      results = [...results].sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())
    } else {
      results = [...results].sort((a, b) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime())
    }

    return results
  }, [inboxData?.items, filter, sort, search, userId])

  const handleFilterChange = (newFilter: FilterType) => {
    const params = new URLSearchParams(searchParams)
    params.set('filter', newFilter)
    setSearchParams(params)
  }

  const handleSortChange = (newSort: SortOrder) => {
    const params = new URLSearchParams(searchParams)
    params.set('sort', newSort)
    setSearchParams(params)
  }

  const handleSearchChange = (newSearch: string) => {
    const params = new URLSearchParams(searchParams)
    if (newSearch) {
      params.set('search', newSearch)
    } else {
      params.delete('search')
    }
    setSearchParams(params)
  }

  const isOperator = session?.roles?.includes('PROCESS_OPERATOR') || session?.roles?.includes('PLATFORM_ADMIN')

  return (
    <div style={{ display: 'flex', height: 'calc(100vh - 60px)' }}>
      {/* Left panel: task list */}
      <div style={{ flex: 1, borderRight: '1px solid #e2e8f0', overflowY: 'auto' }}>
        <div style={{ padding: '1.5rem' }}>
          {/* Filter bar */}
          <div style={{ marginBottom: '1.5rem', display: 'flex', gap: '1rem', alignItems: 'center', flexWrap: 'wrap' }}>
            <div style={{ display: 'flex', gap: '.5rem' }}>
              {(['me', 'group', isOperator && 'all'].filter(Boolean) as FilterType[]).map(f => (
                <button
                  key={f}
                  data-testid={f === 'all' ? 'task-filter-all-tasks' : undefined}
                  onClick={() => handleFilterChange(f)}
                  style={{
                    padding: '.5rem 1rem',
                    background: filter === f ? '#2563eb' : '#f1f5f9',
                    color: filter === f ? '#fff' : '#1e293b',
                    border: 'none',
                    borderRadius: '4px',
                    cursor: 'pointer',
                    fontSize: '.9rem',
                  }}
                >
                  {f === 'me' ? 'My Tasks' : f === 'group' ? 'Group Tasks' : 'All Tasks'}
                </button>
              ))}
            </div>

            <select
              data-testid="task-sort-control"
              value={sort}
              onChange={e => handleSortChange(e.target.value as SortOrder)}
              style={{
                padding: '.5rem .75rem',
                border: '1px solid #cbd5e1',
                borderRadius: '4px',
                cursor: 'pointer',
                fontSize: '.9rem',
              }}
            >
              <option value="-created">Newest first</option>
              <option value="created">Oldest first</option>
            </select>

            <input
              type="text"
              data-testid="task-search-input"
              placeholder="Search tasks…"
              value={search}
              onChange={e => handleSearchChange(e.target.value)}
              style={{
                padding: '.5rem .75rem',
                border: '1px solid #cbd5e1',
                borderRadius: '4px',
                fontSize: '.9rem',
                flex: 1,
                minWidth: '200px',
              }}
            />
          </div>

          {/* Task list */}
          <h2 style={{ marginBottom: '1.25rem' }}>
            {filter === 'me' ? 'My Tasks' : filter === 'group' ? 'Group Tasks' : 'All Tasks'}
          </h2>

          {inboxLoading && <p>Loading…</p>}

          {!inboxLoading && filteredTasks.length === 0 && (
            <p style={{ color: '#64748b' }}>No tasks found.</p>
          )}

          <div style={{ display: 'flex', flexDirection: 'column', gap: '.75rem' }} data-testid="task-inbox-list">
            {filteredTasks.map((task) => (
              <div
                key={task.id}
                data-testid="task-row"
                onClick={() => setSelectedTaskId(task.id)}
                style={{
                  background: selectedTaskId === task.id ? '#eff6ff' : '#fff',
                  border: selectedTaskId === task.id ? '2px solid #2563eb' : '1px solid #e2e8f0',
                  borderRadius: '6px',
                  padding: '1rem 1.25rem',
                  cursor: 'pointer',
                  display: 'flex',
                  alignItems: 'center',
                  gap: '1rem',
                }}
              >
                <div style={{ flex: 1 }}>
                  <div data-testid="task-name" style={{ fontWeight: 600, marginBottom: '.25rem' }}>{task.node_name}</div>
                  <div style={{ fontSize: '.85rem', color: '#64748b' }}>
                    Instance: <code data-testid="task-instance-id" style={{ fontSize: '.8rem' }}>{task.instance_id.slice(0, 8)}…</code>
                    {task.assignee_ref && <> · Assigned to: <span data-testid="task-assignee">{task.assignee_ref}</span></>}
                  </div>
                  <div style={{ fontSize: '.8rem', color: '#94a3b8', marginTop: '.25rem' }}>
                    {new Date(task.created_at).toLocaleDateString()} {new Date(task.created_at).toLocaleTimeString()}
                  </div>
                </div>
                <div
                  data-testid="task-status"
                  style={{
                    padding: '.25rem .75rem',
                    background: task.status === 'PENDING' ? '#dbeafe' : '#e5e7eb',
                    color: task.status === 'PENDING' ? '#0369a1' : '#374151',
                    borderRadius: '4px',
                    fontSize: '.85rem',
                    fontWeight: 500,
                  }}
                >
                  {task.status}
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* Right panel: task detail */}
      {selectedTaskId && (
        <TaskDetailPanel
          taskId={selectedTaskId}
          onClose={() => setSelectedTaskId(null)}
        />
      )}
    </div>
  )
}

function TaskDetailPanel({ taskId, onClose }: { taskId: string; onClose: () => void }) {
  const { data: task, isLoading } = useTask(taskId)
  const { session } = useAuth()
  const complete = useCompleteTask()
  const claim = useClaimTask()

  // Extract user ID from JWT token
  const userId = useMemo(() => {
    if (!session?.token) return null
    const payload = decodeJwtPayload(session.token)
    return payload.sub || null
  }, [session?.token])

  if (isLoading) {
    return (
      <div style={{ width: '40%', borderLeft: '1px solid #e2e8f0', padding: '1.5rem' }}>
        <p>Loading task details…</p>
      </div>
    )
  }

  if (!task) {
    return (
      <div style={{ width: '40%', borderLeft: '1px solid #e2e8f0', padding: '1.5rem' }}>
        <p style={{ color: '#ef4444' }}>Task not found</p>
        <button onClick={onClose}>Back</button>
      </div>
    )
  }

  const isAssignedToMe = task.assignee_ref === userId
  const isClaimable = task.assignee_type && ['GROUP', 'ROLE'].includes(task.assignee_type) && !isAssignedToMe

  return (
    <div data-testid="task-detail-panel" style={{ width: '40%', borderLeft: '1px solid #e2e8f0', padding: '1.5rem', overflowY: 'auto' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '1.5rem' }}>
        <h2 data-testid="task-detail-title" style={{ margin: 0 }}>{task.node_name}</h2>
        <button
          onClick={onClose}
          style={{
            background: 'none',
            border: 'none',
            fontSize: '1.5rem',
            cursor: 'pointer',
            color: '#64748b',
          }}
        >
          ×
        </button>
      </div>

      {/* Status badge */}
      <div style={{ marginBottom: '1.5rem' }}>
        <div
          style={{
            display: 'inline-block',
            padding: '.5rem 1rem',
            background: task.status === 'PENDING' ? '#dbeafe' : '#e5e7eb',
            color: task.status === 'PENDING' ? '#0369a1' : '#374151',
            borderRadius: '4px',
            fontWeight: 500,
          }}
        >
          {task.status}
        </div>
      </div>

      {/* Instance context */}
      <div
        style={{
          background: '#f8fafc',
          border: '1px solid #e2e8f0',
          borderRadius: '6px',
          padding: '1rem',
          marginBottom: '1.5rem',
        }}
      >
        <h3 style={{ margin: '0 0 0.75rem 0', fontSize: '.95rem', fontWeight: 600 }}>Instance Context</h3>
        <div style={{ fontSize: '.85rem', color: '#475569' }}>
          <p style={{ margin: '.25rem 0' }}>
            <strong>Definition:</strong> <span data-testid="instance-definition-name">{task.definition_name ?? 'N/A'}</span>
          </p>
          <p style={{ margin: '.25rem 0' }}>
            <strong>Instance ID:</strong> <span data-testid="instance-id">{task.instance_id}</span>
          </p>
          <p style={{ margin: '.25rem 0' }}>
            <strong>Created:</strong> {new Date(task.created_at).toLocaleString()}
          </p>
        </div>
      </div>

      {/* Form if schema exists */}
      {task.form_schema && (
        <div style={{ marginBottom: '1.5rem' }}>
          <h3 style={{ fontSize: '.95rem', fontWeight: 600, marginBottom: '.75rem' }}>Task Form</h3>
          <div style={{ background: '#fff', border: '1px solid #e2e8f0', borderRadius: '6px', padding: '1rem' }}>
            <p style={{ color: '#64748b', fontSize: '.9rem' }}>
              Form rendering from JSON Schema (TK-UI-03 implementation pending)
            </p>
          </div>
        </div>
      )}

      {/* Action buttons */}
      <div style={{ display: 'flex', gap: '.75rem', marginTop: '2rem' }}>
        {isClaimable && (
          <button
            data-testid="task-claim-button"
            onClick={() => claim.mutate(taskId)}
            disabled={claim.isPending || !isClaimable}
            style={{
              flex: 1,
              padding: '.75rem 1rem',
              background: '#10b981',
              color: '#fff',
              border: 'none',
              borderRadius: '4px',
              cursor: claim.isPending ? 'not-allowed' : 'pointer',
              opacity: claim.isPending ? 0.7 : 1,
              fontSize: '.9rem',
            }}
          >
            {claim.isPending ? 'Claiming…' : 'Claim Task'}
          </button>
        )}

        {isAssignedToMe && task.status === 'PENDING' && (
          <button
            data-testid="task-complete-button"
            onClick={() => complete.mutate({ id: taskId, body: { output_variables: {} } })}
            disabled={complete.isPending}
            style={{
              flex: 1,
              padding: '.75rem 1rem',
              background: '#2563eb',
              color: '#fff',
              border: 'none',
              borderRadius: '4px',
              cursor: complete.isPending ? 'not-allowed' : 'pointer',
              opacity: complete.isPending ? 0.7 : 1,
              fontSize: '.9rem',
            }}
          >
            {complete.isPending ? 'Completing…' : 'Complete Task'}
          </button>
        )}
      </div>

      <div style={{ marginTop: '1rem' }}>
        <button
          onClick={onClose}
          style={{
            width: '100%',
            padding: '.5rem 1rem',
            background: '#f1f5f9',
            color: '#1e293b',
            border: '1px solid #cbd5e1',
            borderRadius: '4px',
            cursor: 'pointer',
            fontSize: '.9rem',
          }}
        >
          Back to inbox
        </button>
      </div>
    </div>
  )
}
