import { useQuery } from '@tanstack/react-query'
import { useTenantContext } from '@/auth/useTenantContext'
import { definitionsApi } from '@/api/definitions'
import { instancesApi } from '@/api/instances'
import { tasksApi } from '@/api/tasks'
import { queryKeys } from '@/api/queryKeys'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'

function SkeletonBox(): JSX.Element {
  return (
    <div
      style={{
        height: '4rem',
        background: '#e2e8f0',
        borderRadius: '6px',
        animation: 'pulse 1.5s ease-in-out infinite',
      }}
    />
  )
}

export default function TenantDashboardPage(): JSX.Element {
  const { tenantDisplayName, isUnknown } = useTenantContext()

  const { data: definitions, isLoading: loadingDefs, isError: errorDefs, error: defsError, refetch: refetchDefs } = useQuery({
    queryKey: queryKeys.definitions.list({ page_size: 5 }),
    queryFn: () => definitionsApi.list({ page_size: 5 }),
  })

  const { data: instances, isLoading: loadingInstances } = useQuery({
    queryKey: queryKeys.instances.list({ status: ['ACTIVE'], page_size: 1 }),
    queryFn: () => instancesApi.list({ status: ['ACTIVE'], page_size: 1 }),
  })

  const { data: tasks, isLoading: loadingTasks } = useQuery({
    queryKey: queryKeys.tasks.list({ status: 'PENDING', page_size: 1 }),
    queryFn: () => tasksApi.list({ status: 'PENDING', page_size: 1 }),
  })

  const rendererState: RendererState = loadingDefs ? 'loading' : errorDefs ? classifyError(defsError) : 'success'

  return (
    <div style={{ padding: '2rem', maxWidth: '900px' }}>
      <h1
        data-testid="tenant-dashboard-heading"
        style={{ fontSize: '1.75rem', fontWeight: 700, color: '#1e293b', marginBottom: '0.5rem' }}
      >
        {tenantDisplayName}
      </h1>

      <p style={{ color: '#64748b', marginBottom: '2rem' }}>
        Welcome to your BPM workspace. Here is a summary of your current activity.
      </p>

      {isUnknown && (
        <div
          data-testid="tenant-unknown-banner"
          style={{
            marginBottom: '1.5rem',
            padding: '.75rem 1rem',
            background: '#fef3c7',
            border: '1px solid #f59e0b',
            borderRadius: '6px',
            color: '#92400e',
            fontSize: '.875rem',
          }}
        >
          Tenant name could not be loaded. Contact your administrator.
        </div>
      )}

      <QueryStateBoundary
        state={rendererState}
        onRetry={() => { void refetchDefs() }}
        columns={[{ widthPercent: 33 }, { widthPercent: 33 }, { widthPercent: 34 }]}
      >
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '1.25rem' }}>
        {/* Recent Definitions */}
        <div
          data-testid="tile-definitions"
          style={{
            background: '#fff',
            border: '1px solid #e2e8f0',
            borderRadius: '8px',
            padding: '1.25rem',
            boxShadow: '0 1px 3px rgba(0,0,0,.06)',
          }}
        >
          <div style={{ fontSize: '.75rem', fontWeight: 600, color: '#64748b', textTransform: 'uppercase', marginBottom: '.75rem' }}>
            Recent Definitions
          </div>
          {loadingDefs ? (
            <SkeletonBox />
          ) : (
            <div>
              {(definitions?.items ?? []).slice(0, 5).map((d) => (
                <div
                  key={d.id}
                  style={{ fontSize: '.875rem', color: '#334155', padding: '.25rem 0', borderBottom: '1px solid #f1f5f9' }}
                >
                  {d.name}
                </div>
              ))}
              {(!definitions?.items || definitions.items.length === 0) && (
                <div style={{ color: '#94a3b8', fontSize: '.875rem' }}>No definitions yet.</div>
              )}
            </div>
          )}
        </div>

        {/* Active Instances */}
        <div
          data-testid="tile-instances"
          style={{
            background: '#fff',
            border: '1px solid #e2e8f0',
            borderRadius: '8px',
            padding: '1.25rem',
            boxShadow: '0 1px 3px rgba(0,0,0,.06)',
          }}
        >
          <div style={{ fontSize: '.75rem', fontWeight: 600, color: '#64748b', textTransform: 'uppercase', marginBottom: '.75rem' }}>
            Active Instances
          </div>
          {loadingInstances ? (
            <SkeletonBox />
          ) : (
            <div
              data-testid="tile-instances-count"
              style={{ fontSize: '2.25rem', fontWeight: 700, color: '#3b82f6' }}
            >
              {instances?.items?.length ?? 0}
            </div>
          )}
        </div>

        {/* Pending Tasks */}
        <div
          data-testid="tile-tasks"
          style={{
            background: '#fff',
            border: '1px solid #e2e8f0',
            borderRadius: '8px',
            padding: '1.25rem',
            boxShadow: '0 1px 3px rgba(0,0,0,.06)',
          }}
        >
          <div style={{ fontSize: '.75rem', fontWeight: 600, color: '#64748b', textTransform: 'uppercase', marginBottom: '.75rem' }}>
            Pending Tasks
          </div>
          {loadingTasks ? (
            <SkeletonBox />
          ) : (
            <div
              data-testid="tile-tasks-count"
              style={{ fontSize: '2.25rem', fontWeight: 700, color: '#f59e0b' }}
            >
              {tasks?.items?.length ?? 0}
            </div>
          )}
        </div>
      </div>
      </QueryStateBoundary>
    </div>
  )
}
