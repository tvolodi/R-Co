import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { dlqApi } from '@/api/dlq'
import { queryKeys } from '@/api/queryKeys'
import { useAuth } from '@/auth/AuthContext'
import type { DlqEntry } from '@/types/api'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'

const STATUS_COLOR: Record<string, string> = {
  pending:   '#f59e0b',
  retrying:  '#3b82f6',
  resolved:  '#16a34a',
  discarded: '#9ca3af',
}

const OPERATE_ROLES = ['PROCESS_OPERATOR', 'PLATFORM_ADMIN']

function parseJsonLike(value: unknown): unknown {
  if (typeof value !== 'string') return value
  try {
    return JSON.parse(value) as unknown
  } catch {
    return value
  }
}

function asObject(value: unknown): Record<string, unknown> {
  const parsed = parseJsonLike(value)
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return {}
  return parsed as Record<string, unknown>
}

function asArray(value: unknown): unknown[] {
  const parsed = parseJsonLike(value)
  return Array.isArray(parsed) ? parsed : []
}

function normalizeStatus(entry: DlqEntry, transientStatus?: string): string {
  if (transientStatus) return transientStatus
  if (entry.status) return entry.status

  const metadata = asObject(entry.processor_metadata)
  const rawStatus = metadata.status
  if (typeof rawStatus === 'string') return rawStatus.toLowerCase()

  if (entry.retry_count > 0 && entry.retry_limit && entry.retry_count < entry.retry_limit) {
    return 'retrying'
  }
  return 'pending'
}

function extractFailureReason(entry: DlqEntry): string {
  if (entry.full_reason && entry.full_reason.trim().length > 0) return entry.full_reason
  if (entry.reason && entry.reason.trim().length > 0) return entry.reason

  const chain = asArray(entry.error_chain)
  for (let idx = chain.length - 1; idx >= 0; idx -= 1) {
    const part = chain[idx]
    if (!part || typeof part !== 'object' || Array.isArray(part)) continue
    const candidate = (part as Record<string, unknown>).message
    if (typeof candidate === 'string' && candidate.trim().length > 0) return candidate
  }

  return 'No failure reason provided.'
}

function extractRetryHistory(entry: DlqEntry): Array<{ attemptNo: number; attemptedAt: string; outcome: string; errorMessage?: string }> {
  if (Array.isArray(entry.retry_history) && entry.retry_history.length > 0) {
    return entry.retry_history.map((attempt) => ({
      attemptNo: attempt.attempt_no,
      attemptedAt: attempt.attempted_at,
      outcome: attempt.outcome,
      errorMessage: attempt.error_message,
    }))
  }

  const metadata = asObject(entry.processor_metadata)
  const metadataHistory = asArray(metadata.retry_history)
  if (metadataHistory.length > 0) {
    return metadataHistory.map((item, index) => {
      const row = asObject(item)
      return {
        attemptNo: typeof row.attempt_no === 'number' ? row.attempt_no : index + 1,
        attemptedAt: typeof row.attempted_at === 'string' ? row.attempted_at : (entry.last_failed_at ?? entry.created_at),
        outcome: typeof row.outcome === 'string' ? row.outcome : 'failed',
        errorMessage: typeof row.error_message === 'string' ? row.error_message : undefined,
      }
    })
  }

  return asArray(entry.error_chain).map((item, index) => {
    const row = asObject(item)
    return {
      attemptNo: index + 1,
      attemptedAt: typeof row.timestamp === 'string' ? row.timestamp : (entry.last_failed_at ?? entry.created_at),
      outcome: 'failed',
      errorMessage: typeof row.message === 'string' ? row.message : undefined,
    }
  })
}

function toPrettyJson(value: unknown): string {
  const parsed = parseJsonLike(value)
  return JSON.stringify(parsed ?? {}, null, 2)
}

function toShortDate(value: string | undefined): string {
  if (!value) return '—'
  return new Date(value).toLocaleString()
}

function toRowTestId(id: string): string {
  return id.replace(/[^a-zA-Z0-9_-]/g, '-')
}

export default function DlqPage() {
  const qc = useQueryClient()
  const { session } = useAuth()
  const [search, setSearch] = useState('')
  const [statusFilter, setStatusFilter] = useState('')
  const [sourceTypeFilter, setSourceTypeFilter] = useState('')
  const [cursorStack, setCursorStack] = useState<string[]>([])
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)
  const [transientStatusById, setTransientStatusById] = useState<Record<string, string>>({})
  const [discardConfirmItem, setDiscardConfirmItem] = useState<DlqEntry | null>(null)

  const canOperate = session?.roles.some((role) => OPERATE_ROLES.includes(role)) ?? false
  const cursor = cursorStack.length > 0 ? cursorStack[cursorStack.length - 1] : undefined

  const { data, isLoading, isError, error, refetch } = useQuery({
    queryKey: queryKeys.dlq.list({ search, status: statusFilter, source_type: sourceTypeFilter, cursor }),
    queryFn: () => dlqApi.list({
      search: search || undefined,
      status: statusFilter || undefined,
      source_type: sourceTypeFilter || undefined,
      cursor,
      page_size: 25,
    }),
  })

  const rows = useMemo(() => data?.items ?? [], [data?.items])
  const selected = useMemo(() => rows.find((entry) => entry.id === selectedId) ?? null, [rows, selectedId])

  const retry = useMutation({
    mutationFn: (id: string) => dlqApi.retry(id),
    onMutate: (id) => {
      setActionError(null)
      setTransientStatusById((prev) => ({ ...prev, [id]: 'retrying' }))
    },
    onError: (_err, id) => {
      setTransientStatusById((prev) => {
        const next = { ...prev }
        delete next[id]
        return next
      })
      setActionError('Retry failed. Please try again.')
    },
    onSuccess: (_result, id) => {
      qc.invalidateQueries({ queryKey: queryKeys.dlq.list() })
      qc.invalidateQueries({ queryKey: queryKeys.dlq.detail(id) })
    },
  })

  const discard = useMutation({
    mutationFn: (id: string) => dlqApi.discard(id),
    onMutate: (id) => {
      setActionError(null)
      setTransientStatusById((prev) => ({ ...prev, [id]: 'discarded' }))
    },
    onError: (_err, id) => {
      setTransientStatusById((prev) => {
        const next = { ...prev }
        delete next[id]
        return next
      })
      setActionError('Discard failed. Please try again.')
    },
    onSuccess: (_result, id) => {
      qc.invalidateQueries({ queryKey: queryKeys.dlq.list() })
      qc.invalidateQueries({ queryKey: queryKeys.dlq.detail(id) })
      if (selectedId === id) setSelectedId(null)
    },
  })

  const applyFilters = () => {
    setCursorStack([])
  }

  const goNext = () => {
    if (!data?.next_cursor) return
    setCursorStack((prev) => [...prev, data.next_cursor as string])
  }

  const goPrev = () => {
    setCursorStack((prev) => prev.slice(0, -1))
  }

  const clearSelection = () => setSelectedId(null)

  const confirmDiscard = () => {
    if (!discardConfirmItem) return
    discard.mutate(discardConfirmItem.id)
    setDiscardConfirmItem(null)
  }

  const renderStatus = (entry: DlqEntry) => {
    const normalized = normalizeStatus(entry, transientStatusById[entry.id])
    return (
      <span style={{ color: STATUS_COLOR[normalized] ?? '#374151', fontWeight: 600, fontSize: '.8rem' }}>
        {normalized}
      </span>
    )
  }

  return (
    <div style={{ padding: '1.5rem' }} data-testid="dlq-page">
      <h2 style={{ marginBottom: '1.25rem' }}>Dead-Letter Queue</h2>

      <div style={{ display: 'flex', gap: '.6rem', flexWrap: 'wrap', marginBottom: '.8rem' }}>
        <input
          data-testid="dlq-filter-search"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="id, reason, or instance"
          style={{ minWidth: '240px', padding: '.35rem .6rem', border: '1px solid #cbd5e1', borderRadius: '4px' }}
        />
        <select
          data-testid="dlq-filter-status"
          value={statusFilter}
          onChange={(e) => setStatusFilter(e.target.value)}
          style={{ padding: '.35rem .6rem', border: '1px solid #cbd5e1', borderRadius: '4px' }}
        >
          <option value="">All statuses</option>
          <option value="pending">Pending</option>
          <option value="retrying">Retrying</option>
          <option value="resolved">Resolved</option>
          <option value="discarded">Discarded</option>
        </select>
        <select
          data-testid="dlq-filter-source"
          value={sourceTypeFilter}
          onChange={(e) => setSourceTypeFilter(e.target.value)}
          style={{ padding: '.35rem .6rem', border: '1px solid #cbd5e1', borderRadius: '4px' }}
        >
          <option value="">All sources</option>
          <option value="event">Event</option>
          <option value="timer">Timer</option>
          <option value="webhook">Webhook</option>
        </select>
        <button
          data-testid="dlq-filter-apply"
          type="button"
          onClick={applyFilters}
          style={{ padding: '.35rem .8rem', border: '1px solid #cbd5e1', borderRadius: '4px', background: '#fff', cursor: 'pointer' }}
        >
          Apply
        </button>
      </div>

      <QueryStateBoundary
        state={(isLoading ? 'loading' : isError ? classifyError(error) : 'success') as RendererState}
        onRetry={() => { void refetch() }}
        columns={[{ widthPercent: 20 }, { widthPercent: 40 }, { widthPercent: 10 }, { widthPercent: 15 }, { widthPercent: 15 }]}
      >
      {actionError && <p style={{ color: '#dc2626' }}>{actionError}</p>}

      {rows.length === 0 && (
        <p style={{ color: '#64748b' }}>Queue is empty.</p>
      )}

      <table data-testid="dlq-table" style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.875rem' }}>
        <thead>
          <tr style={{ background: '#f1f5f9', textAlign: 'left' }}>
            <th style={{ padding: '.6rem .8rem' }}>Source</th>
            <th style={{ padding: '.6rem .8rem' }}>Instance</th>
            <th style={{ padding: '.6rem .8rem' }}>Reason</th>
            <th style={{ padding: '.6rem .8rem' }}>Retry count</th>
            <th style={{ padding: '.6rem .8rem' }}>Created</th>
            <th style={{ padding: '.6rem .8rem' }}>Status</th>
            <th style={{ padding: '.6rem .8rem' }}>Actions</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((e) => {
            const displayReason = extractFailureReason(e)
            const status = normalizeStatus(e, transientStatusById[e.id])
            const source = e.entry_type ?? e.item_type ?? 'unknown'

            return (
              <tr
                key={e.id}
                data-testid={`dlq-row-${toRowTestId(e.id)}`}
                onClick={() => setSelectedId(e.id)}
                style={{
                  borderBottom: '1px solid #e2e8f0',
                  background: selectedId === e.id ? '#f8fafc' : '#fff',
                  cursor: 'pointer',
                }}
              >
                <td style={{ padding: '.5rem .8rem' }}>
                  <span style={{
                    display: 'inline-flex',
                    alignItems: 'center',
                    borderRadius: '999px',
                    padding: '.2rem .55rem',
                    fontSize: '.75rem',
                    fontWeight: 600,
                    background: '#e2e8f0',
                    color: '#334155',
                    textTransform: 'uppercase',
                  }}>
                    {source}
                  </span>
                </td>
                <td style={{ padding: '.5rem .8rem', fontFamily: 'monospace', fontSize: '.75rem' }}>
                  {e.instance_id ? (
                    <Link to={`/instances/${e.instance_id}`} onClick={(event) => event.stopPropagation()}>
                      {e.instance_id.slice(0, 8)}...
                    </Link>
                  ) : '—'}
                </td>
                <td style={{ padding: '.5rem .8rem', fontSize: '.8rem', color: '#64748b', maxWidth: '240px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {displayReason}
                </td>
                <td style={{ padding: '.5rem .8rem', textAlign: 'center' }}>{e.retry_count}</td>
                <td style={{ padding: '.5rem .8rem', color: '#64748b', fontSize: '.8rem' }}>{toShortDate(e.created_at)}</td>
                <td style={{ padding: '.5rem .8rem' }}>{renderStatus(e)}</td>
                <td style={{ padding: '.5rem .8rem', display: 'flex', gap: '.4rem' }}>
                  <button
                    data-testid={`dlq-details-${toRowTestId(e.id)}`}
                    type="button"
                    onClick={(event) => {
                      event.stopPropagation()
                      setSelectedId(e.id)
                    }}
                    style={{ padding: '.25rem .5rem', background: '#fff', border: '1px solid #cbd5e1', borderRadius: '4px', cursor: 'pointer', fontSize: '.75rem' }}
                  >
                    Details
                  </button>

                  {canOperate && status !== 'resolved' && status !== 'discarded' && (
                    <>
                      <button
                        data-testid={`dlq-retry-${toRowTestId(e.id)}`}
                        type="button"
                        onClick={(event) => {
                          event.stopPropagation()
                          retry.mutate(e.id)
                        }}
                        disabled={retry.isPending}
                        style={{ padding: '.25rem .5rem', background: '#2563eb', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.75rem' }}
                      >
                        Retry
                      </button>
                      <button
                        data-testid={`dlq-discard-${toRowTestId(e.id)}`}
                        type="button"
                        onClick={(event) => {
                          event.stopPropagation()
                          setDiscardConfirmItem(e)
                        }}
                        disabled={discard.isPending}
                        style={{ padding: '.25rem .5rem', background: '#6b7280', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.75rem' }}
                      >
                        Discard
                      </button>
                    </>
                  )}
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>

      <div style={{ marginTop: '.85rem', display: 'flex', gap: '.5rem' }}>
        <button
          data-testid="dlq-prev-page"
          type="button"
          disabled={cursorStack.length === 0}
          onClick={goPrev}
          style={{ padding: '.35rem .8rem', border: '1px solid #cbd5e1', borderRadius: '4px', background: '#fff', cursor: 'pointer', fontSize: '.85rem' }}
        >
          Previous
        </button>
        <button
          data-testid="dlq-next-page"
          type="button"
          disabled={!data?.next_cursor}
          onClick={goNext}
          style={{ padding: '.35rem .8rem', border: '1px solid #cbd5e1', borderRadius: '4px', background: '#fff', cursor: 'pointer', fontSize: '.85rem' }}
        >
          Next
        </button>
      </div>
      </QueryStateBoundary>

      {selected && (
        <section data-testid="dlq-detail-panel" style={{ marginTop: '1rem', border: '1px solid #e2e8f0', borderRadius: '6px', padding: '1rem', background: '#fff' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '.6rem' }}>
            <h3 style={{ margin: 0 }}>DLQ Item Detail</h3>
            <button
              type="button"
              onClick={clearSelection}
              style={{ padding: '.2rem .5rem', border: '1px solid #cbd5e1', borderRadius: '4px', background: '#fff', cursor: 'pointer' }}
            >
              Close
            </button>
          </div>

          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.85rem', marginBottom: '.8rem' }}>
            <tbody>
              <tr style={{ borderBottom: '1px solid #e2e8f0' }}>
                <td style={{ width: '180px', color: '#64748b', padding: '.45rem .55rem' }}>Item ID</td>
                <td style={{ padding: '.45rem .55rem', fontFamily: 'monospace' }}>{selected.id}</td>
              </tr>
              <tr style={{ borderBottom: '1px solid #e2e8f0' }}>
                <td style={{ color: '#64748b', padding: '.45rem .55rem' }}>Source</td>
                <td style={{ padding: '.45rem .55rem' }}>{selected.entry_type ?? selected.item_type ?? 'unknown'}</td>
              </tr>
              <tr style={{ borderBottom: '1px solid #e2e8f0' }}>
                <td style={{ color: '#64748b', padding: '.45rem .55rem' }}>Instance</td>
                <td style={{ padding: '.45rem .55rem' }}>{selected.instance_id ?? '—'}</td>
              </tr>
              <tr style={{ borderBottom: '1px solid #e2e8f0' }}>
                <td style={{ color: '#64748b', padding: '.45rem .55rem' }}>Status</td>
                <td style={{ padding: '.45rem .55rem' }}>{renderStatus(selected)}</td>
              </tr>
            </tbody>
          </table>

          <h4 style={{ margin: '.4rem 0' }}>Full failure reason</h4>
          <pre style={{ background: '#f8fafc', border: '1px solid #e2e8f0', borderRadius: '4px', padding: '.65rem', overflow: 'auto', fontSize: '.8rem' }}>
            {extractFailureReason(selected)}
          </pre>

          <h4 style={{ margin: '.8rem 0 .4rem' }}>Retry history</h4>
          {extractRetryHistory(selected).length > 0 ? (
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.82rem' }}>
              <thead>
                <tr style={{ background: '#f1f5f9', textAlign: 'left' }}>
                  <th style={{ padding: '.4rem .5rem' }}>Attempt</th>
                  <th style={{ padding: '.4rem .5rem' }}>Time</th>
                  <th style={{ padding: '.4rem .5rem' }}>Outcome</th>
                  <th style={{ padding: '.4rem .5rem' }}>Error</th>
                </tr>
              </thead>
              <tbody>
                {extractRetryHistory(selected).map((attempt) => (
                  <tr key={`${attempt.attemptNo}-${attempt.attemptedAt}`} style={{ borderBottom: '1px solid #e2e8f0' }}>
                    <td style={{ padding: '.4rem .5rem' }}>{attempt.attemptNo}</td>
                    <td style={{ padding: '.4rem .5rem' }}>{toShortDate(attempt.attemptedAt)}</td>
                    <td style={{ padding: '.4rem .5rem' }}>{attempt.outcome}</td>
                    <td style={{ padding: '.4rem .5rem' }}>{attempt.errorMessage ?? '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <p style={{ margin: 0, color: '#64748b' }}>No retry history available.</p>
          )}

          <h4 style={{ margin: '.8rem 0 .4rem' }}>Context JSON</h4>
          <pre style={{ background: '#f8fafc', border: '1px solid #e2e8f0', borderRadius: '4px', padding: '.65rem', overflow: 'auto', fontSize: '.8rem' }}>
            {toPrettyJson(selected.context_json ?? selected.processor_metadata)}
          </pre>

          <h4 style={{ margin: '.8rem 0 .4rem' }}>Source payload</h4>
          <pre style={{ background: '#f8fafc', border: '1px solid #e2e8f0', borderRadius: '4px', padding: '.65rem', overflow: 'auto', fontSize: '.8rem' }}>
            {toPrettyJson(selected.source_payload ?? selected.original_payload)}
          </pre>
        </section>
      )}

      {discardConfirmItem && (
        <div
          data-testid="dlq-discard-dialog"
          role="dialog"
          aria-modal="true"
          aria-label="Discard DLQ item"
          style={{
            position: 'fixed',
            inset: 0,
            background: 'rgba(15, 23, 42, 0.45)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            padding: '1rem',
            zIndex: 40,
          }}
        >
          <div style={{ background: '#fff', borderRadius: '6px', width: '100%', maxWidth: '520px', padding: '1rem', border: '1px solid #e2e8f0' }}>
            <h3 style={{ marginTop: 0 }}>Discard this DLQ item?</h3>
            <p style={{ marginTop: 0, color: '#475569' }}>
              This action cannot be undone.
            </p>
            {discardConfirmItem.instance_id && (
              <p style={{ marginTop: 0, color: '#92400e', background: '#fef3c7', border: '1px solid #f59e0b', borderRadius: '4px', padding: '.5rem .65rem' }}>
                This item is tied to instance {discardConfirmItem.instance_id}. Discarding may cancel the associated instance.
              </p>
            )}

            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: '.5rem' }}>
              <button
                type="button"
                onClick={() => setDiscardConfirmItem(null)}
                style={{ padding: '.38rem .82rem', border: '1px solid #cbd5e1', borderRadius: '4px', background: '#fff', cursor: 'pointer' }}
              >
                Cancel
              </button>
              <button
                data-testid="dlq-discard-confirm"
                type="button"
                onClick={confirmDiscard}
                style={{ padding: '.38rem .82rem', border: 'none', borderRadius: '4px', background: '#dc2626', color: '#fff', cursor: 'pointer' }}
              >
                Discard
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
