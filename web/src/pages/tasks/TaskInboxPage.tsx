import { useTaskInbox, useCompleteTask } from '@/hooks/useTasks'

export default function TaskInboxPage() {
  const { data, isLoading } = useTaskInbox()
  const complete = useCompleteTask()

  return (
    <div style={{ padding: '1.5rem' }}>
      <h2 style={{ marginBottom: '1.25rem' }}>My Tasks</h2>

      {isLoading && <p>Loading…</p>}

      {data?.items?.length === 0 && (
        <p style={{ color: '#64748b' }}>No pending tasks.</p>
      )}

      <div style={{ display: 'flex', flexDirection: 'column', gap: '.75rem' }}>
        {(data?.items ?? []).map((task) => (
          <div
            key={task.id}
            style={{
              background: '#fff',
              border: '1px solid #e2e8f0',
              borderRadius: '6px',
              padding: '1rem 1.25rem',
              display: 'flex',
              alignItems: 'center',
              gap: '1rem',
            }}
          >
            <div style={{ flex: 1 }}>
              <div style={{ fontWeight: 600, marginBottom: '.25rem' }}>{task.node_name}</div>
              <div style={{ fontSize: '.8rem', color: '#64748b' }}>
                Instance: <code>{task.instance_id.slice(0, 8)}…</code>
                {task.assignee_ref && <> · Assigned to: {task.assignee_ref}</>}
              </div>
            </div>
            <button
              onClick={() => complete.mutate({ id: task.id, body: {} })}
              disabled={complete.isPending}
              style={{
                padding: '.35rem .9rem',
                background: '#2563eb',
                color: '#fff',
                border: 'none',
                borderRadius: '4px',
                cursor: 'pointer',
                fontSize: '.85rem',
              }}
            >
              Complete
            </button>
          </div>
        ))}
      </div>
    </div>
  )
}
