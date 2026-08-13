import { Fragment, useMemo, useState } from 'react'
import { Navigate } from 'react-router-dom'
import { useQuery, type UseQueryResult } from '@tanstack/react-query'
import { queryKeys } from '@/api/queryKeys'
import { auditApi, type AuditEntry, type AuditLogFilters } from '@/api/audit'
import type { CursorPage } from '@/types/api'
import { JsonDiffView } from '@/components/ui/JsonDiffView'
import { useAuth } from '@/auth/AuthContext'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { getRetryAfterSeconds } from '@/utils/getRetryAfterSeconds'

function isValidIsoDate(value?: string): boolean {
  if (!value) return true
  return !Number.isNaN(Date.parse(value))
}

function isFilterRangeValid(from?: string, to?: string): boolean {
  if (!from || !to) return true
  return new Date(from).getTime() <= new Date(to).getTime()
}

export function useAuditLog(filters: AuditLogFilters): UseQueryResult<CursorPage<AuditEntry>> {
  return useQuery({
    queryKey: queryKeys.admin.audit(filters),
    queryFn: () => auditApi.list(filters),
    refetchInterval: 30_000,
  })
}

export default function AuditLogPage() {
  const { session } = useAuth()
  const isPlatformAdmin = Boolean(session?.roles.includes('PLATFORM_ADMIN'))

  const [actor, setActor] = useState('')
  const [resourceType, setResourceType] = useState('')
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')
  const [cursorStack, setCursorStack] = useState<string[]>([])
  const [expandedRows, setExpandedRows] = useState<Record<string, boolean>>({})
  const [pageSize, setPageSize] = useState<number>(25)

  const cursor = cursorStack[cursorStack.length - 1]
  const filters = useMemo<AuditLogFilters>(() => ({
    actor: actor || undefined,
    resource_type: resourceType || undefined,
    from: from || undefined,
    to: to || undefined,
    cursor,
    page_size: pageSize,
  }), [actor, resourceType, from, to, cursor, pageSize])

  const validFilters = isValidIsoDate(from) && isValidIsoDate(to) && isFilterRangeValid(from, to)
  const { data, isLoading, isError, error, isFetching, refetch } = useQuery({
    queryKey: queryKeys.admin.audit(filters),
    queryFn: () => auditApi.list(filters),
    enabled: validFilters,
    refetchInterval: 30_000,
  })

  const rendererState: RendererState = isLoading ? 'loading' : isError ? classifyError(error) : 'success'

  if (!isPlatformAdmin) {
    return <Navigate to="/instances" replace />
  }

  const nextCursor = data?.next_cursor
  const hasResults = (data?.items.length ?? 0) > 0

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: '.75rem', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Audit Log</h2>
        {isFetching && <span style={{ fontSize: '.8rem', color: '#0369a1' }}>Refreshing…</span>}
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))', gap: '.65rem', marginBottom: '1rem' }}>
        <input
          value={actor}
          onChange={(e) => {
            setActor(e.target.value)
            setCursorStack([])
          }}
          placeholder="Actor ID"
          style={{ padding: '.45rem .6rem', border: '1px solid #cbd5e1', borderRadius: '4px' }}
        />
        <input
          value={resourceType}
          onChange={(e) => {
            setResourceType(e.target.value)
            setCursorStack([])
          }}
          placeholder="Resource type"
          style={{ padding: '.45rem .6rem', border: '1px solid #cbd5e1', borderRadius: '4px' }}
        />
        <input
          value={from}
          onChange={(e) => {
            setFrom(e.target.value)
            setCursorStack([])
          }}
          placeholder="From (ISO8601)"
          style={{ padding: '.45rem .6rem', border: '1px solid #cbd5e1', borderRadius: '4px' }}
        />
        <input
          value={to}
          onChange={(e) => {
            setTo(e.target.value)
            setCursorStack([])
          }}
          placeholder="To (ISO8601)"
          style={{ padding: '.45rem .6rem', border: '1px solid #cbd5e1', borderRadius: '4px' }}
        />
        <select
          value={pageSize}
          onChange={(e) => {
            setPageSize(Number(e.target.value))
            setCursorStack([])
          }}
          style={{ padding: '.45rem .6rem', border: '1px solid #cbd5e1', borderRadius: '4px' }}
        >
          <option value={25}>25 / page</option>
          <option value={50}>50 / page</option>
          <option value={100}>100 / page</option>
        </select>
      </div>

      {!validFilters && (
        <div style={{ marginBottom: '1rem', padding: '.75rem .9rem', borderRadius: '6px', border: '1px solid #fdba74', background: '#fff7ed', color: '#9a3412' }}>
          Please enter valid ISO8601 date filters and ensure from ≤ to.
        </div>
      )}

      <QueryStateBoundary
        state={rendererState}
        onRetry={() => { void refetch() }}
        rateLimitRetryAfter={
          rendererState === 'rate-limit'
            ? getRetryAfterSeconds(error)
            : undefined
        }
        columns={[{ widthPercent: 5 }, { widthPercent: 20 }, { widthPercent: 20 }, { widthPercent: 25 }, { widthPercent: 20 }, { widthPercent: 10 }]}
      >
        {validFilters && !hasResults && (
          <div style={{ marginBottom: '1rem', color: '#64748b' }}>No audit entries matched the selected filters.</div>
        )}

      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.85rem' }}>
        <thead>
          <tr style={{ background: '#f1f5f9', textAlign: 'left' }}>
            <th style={{ padding: '.6rem .8rem' }}></th>
            <th style={{ padding: '.6rem .8rem' }}>Time</th>
            <th style={{ padding: '.6rem .8rem' }}>Actor</th>
            <th style={{ padding: '.6rem .8rem' }}>Action</th>
            <th style={{ padding: '.6rem .8rem' }}>Resource</th>
            <th style={{ padding: '.6rem .8rem' }}>IP</th>
          </tr>
        </thead>
        <tbody>
          {(data?.items ?? []).map((e: AuditEntry) => (
            <Fragment key={e.id}>
              <tr key={e.id} style={{ borderBottom: '1px solid #e2e8f0' }}>
                <td style={{ padding: '.5rem .8rem' }}>
                  <button
                    onClick={() => {
                      setExpandedRows((prev) => ({ ...prev, [e.id]: !prev[e.id] }))
                    }}
                    style={{ border: '1px solid #cbd5e1', background: '#fff', borderRadius: '4px', cursor: 'pointer', fontSize: '.75rem', padding: '.1rem .35rem' }}
                  >
                    {expandedRows[e.id] ? '−' : '+'}
                  </button>
                </td>
                <td style={{ padding: '.5rem .8rem', color: '#64748b', fontFamily: 'monospace', fontSize: '.8rem', whiteSpace: 'nowrap' }}>
                  {new Date(e.occurred_at).toLocaleString()}
                </td>
                <td style={{ padding: '.5rem .8rem', fontSize: '.8rem', fontFamily: 'monospace' }}>{e.actor_display_name ?? e.actor_id}</td>
                <td style={{ padding: '.5rem .8rem', fontFamily: 'monospace', fontSize: '.8rem', fontWeight: 600 }}>{e.action}</td>
                <td style={{ padding: '.5rem .8rem', fontSize: '.8rem', color: '#64748b' }}>
                  {e.resource_type} / {e.resource_id}
                </td>
                <td style={{ padding: '.5rem .8rem', fontFamily: 'monospace', fontSize: '.8rem', color: '#94a3b8' }}>{e.ip_address ?? '—'}</td>
              </tr>
              {expandedRows[e.id] && (
                <tr>
                  <td colSpan={6} style={{ padding: '.6rem .8rem', background: '#f8fafc', borderBottom: '1px solid #e2e8f0' }}>
                    <JsonDiffView before={e.before_state} after={e.after_state} />
                  </td>
                </tr>
              )}
            </Fragment>
          ))}
        </tbody>
      </table>

      <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: '1rem' }}>
        <button
          onClick={() => setCursorStack((prev) => prev.slice(0, -1))}
          disabled={cursorStack.length === 0}
          style={{ padding: '.35rem .8rem', border: '1px solid #cbd5e1', borderRadius: '4px', background: cursorStack.length === 0 ? '#f1f5f9' : '#fff', cursor: cursorStack.length === 0 ? 'not-allowed' : 'pointer' }}
        >
          Previous
        </button>
        <button
          onClick={() => {
            if (nextCursor) setCursorStack((prev) => [...prev, nextCursor])
          }}
          disabled={!nextCursor}
          style={{ padding: '.35rem .8rem', border: '1px solid #cbd5e1', borderRadius: '4px', background: !nextCursor ? '#f1f5f9' : '#fff', cursor: !nextCursor ? 'not-allowed' : 'pointer' }}
        >
          Next
        </button>
      </div>
      </QueryStateBoundary>
    </div>
  )
}
