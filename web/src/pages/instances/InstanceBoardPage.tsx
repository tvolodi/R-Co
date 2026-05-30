import { useEffect, useMemo, useState } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { useInstances, instanceKeys, useStartInstance } from '@/hooks/useInstances'
import { useDefinitions, useDefinition } from '@/hooks/useDefinitions'
import { useAuth } from '@/auth/AuthContext'
import { usePolling } from '@/hooks/usePolling'
import { queryKeys } from '@/api/queryKeys'
import type { InstanceStatus } from '@/types/api'

const STATUS_COLORS: Record<InstanceStatus, string> = {
  ACTIVE: '#2563eb',
  COMPLETED: '#16a34a',
  CANCELLED: '#6b7280',
  ERROR: '#dc2626',
}

const STATUS_OPTIONS: InstanceStatus[] = ['ACTIVE', 'COMPLETED', 'CANCELLED', 'ERROR']
const START_ROLES = ['PLATFORM_ADMIN', 'PROCESS_OPERATOR', 'PROCESS_DESIGNER']

function toISODate(value: string | undefined): string {
  if (!value) return '—'
  return new Date(value).toLocaleString()
}

function toRefreshLabel(value: string | null): string {
  if (!value) return 'Not yet refreshed'
  return new Date(value).toLocaleTimeString()
}

function parseStatusFilter(searchParams: URLSearchParams): InstanceStatus[] {
  const raw = searchParams.get('status')
  if (!raw) return []
  return raw
    .split(',')
    .map((entry) => entry.trim())
    .filter((entry): entry is InstanceStatus => STATUS_OPTIONS.includes(entry as InstanceStatus))
}

export default function InstanceBoardPage() {
  const navigate = useNavigate()
  const qc = useQueryClient()
  const { session } = useAuth()
  const [searchParams, setSearchParams] = useSearchParams()

  const statusFilters = useMemo(() => parseStatusFilter(searchParams), [searchParams])
  const definitionName = searchParams.get('definitionName') ?? ''
  const definitionId = searchParams.get('definitionId') ?? undefined
  const cursor = searchParams.get('cursor') ?? undefined
  const pageSizeRaw = Number(searchParams.get('pageSize') ?? '25')
  const pageSize = Number.isFinite(pageSizeRaw) && pageSizeRaw > 0 ? pageSizeRaw : 25

  const [showStart, setShowStart] = useState(false)
  const [startDefinitionName, setStartDefinitionName] = useState(definitionName)
  const [startDefinitionVersion, setStartDefinitionVersion] = useState('')
  const [startCorrelationKey, setStartCorrelationKey] = useState('')
  const [startVariablesJson, setStartVariablesJson] = useState('{\n  \n}')
  const [startError, setStartError] = useState<string | null>(null)
  const [startValidationError, setStartValidationError] = useState<string | null>(null)

  const canStartInstance = session?.roles.some((role) => START_ROLES.includes(role)) ?? false

  const { data: definitionTypeahead } = useDefinitions({
    status: 'ACTIVE',
    name: definitionName || undefined,
  })

  const { data: activeDefinitionByName, isLoading: isLoadingActiveDefinition } = useDefinition(
    definitionId ?? '',
  )

  const instancesQuery = useInstances({
    status: statusFilters.length > 0 ? statusFilters : undefined,
    definition_id: definitionId,
    cursor,
    page_size: pageSize,
  })
  const polling = usePolling({ queryKeyPrefix: queryKeys.instances.all })

  const startInstance = useStartInstance()

  useEffect(() => {
    if (definitionId) {
      setStartDefinitionVersion(activeDefinitionByName?.version ?? '')
      return
    }
    setStartDefinitionVersion('')
  }, [definitionId, activeDefinitionByName?.version])

  const onStatusToggle = (status: InstanceStatus) => {
    const next = new Set(statusFilters)
    if (next.has(status)) next.delete(status)
    else next.add(status)

    const updated = new URLSearchParams(searchParams)
    const values = Array.from(next)
    if (values.length === 0) updated.delete('status')
    else updated.set('status', values.join(','))
    updated.delete('cursor')
    setSearchParams(updated)
  }

  const onDefinitionInputChange = (value: string) => {
    const updated = new URLSearchParams(searchParams)
    if (!value.trim()) {
      updated.delete('definitionName')
      updated.delete('definitionId')
    } else {
      updated.set('definitionName', value)
      updated.delete('definitionId')
    }
    updated.delete('cursor')
    setSearchParams(updated)
  }

  const onResolveDefinition = () => {
    const activeList = definitionTypeahead?.items ?? []
    const exact = activeList.find((item) => item.name === definitionName)

    const updated = new URLSearchParams(searchParams)
    if (exact) {
      updated.set('definitionName', exact.name)
      updated.set('definitionId', exact.id)
      updated.delete('cursor')
      setSearchParams(updated)
    }
  }

  const goNextPage = () => {
    if (!instancesQuery.data?.next_cursor) return
    const updated = new URLSearchParams(searchParams)
    updated.set('cursor', instancesQuery.data.next_cursor)
    setSearchParams(updated)
  }

  const resetFirstPage = () => {
    const updated = new URLSearchParams(searchParams)
    updated.delete('cursor')
    setSearchParams(updated)
  }

  const openStartDialog = () => {
    setStartDefinitionName(definitionName)
    setStartDefinitionVersion(activeDefinitionByName?.version ?? '')
    setStartCorrelationKey('')
    setStartVariablesJson('{\n  \n}')
    setStartError(null)
    setStartValidationError(null)
    setShowStart(true)
  }

  const closeStartDialog = () => {
    setShowStart(false)
  }

  const onStartDefinitionNameChange = (value: string) => {
    setStartDefinitionName(value)

    const activeList = definitionTypeahead?.items ?? []
    const exact = activeList.find((item) => item.name === value)
    if (exact) {
      const updated = new URLSearchParams(searchParams)
      updated.set('definitionName', exact.name)
      updated.set('definitionId', exact.id)
      setSearchParams(updated)
      setStartDefinitionVersion(exact.version)
    } else {
      setStartDefinitionVersion('')
    }
  }

  const submitStartInstance = async () => {
    setStartError(null)
    setStartValidationError(null)

    if (!definitionId) {
      setStartValidationError('Select a valid active definition name.')
      return
    }

    let parsedVariables: Record<string, unknown>
    try {
      const parsed = JSON.parse(startVariablesJson) as unknown
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
        setStartValidationError('Initial variables must be a JSON object.')
        return
      }
      parsedVariables = parsed as Record<string, unknown>
    } catch {
      setStartValidationError('Initial variables must be valid JSON.')
      return
    }

    try {
      const created = await startInstance.mutateAsync({
        definition_id: definitionId,
        correlation_key: startCorrelationKey.trim() || undefined,
        initial_variables: parsedVariables,
      })
      await qc.invalidateQueries({ queryKey: instanceKeys.all })
      setShowStart(false)
      navigate(`/instances/${created.instance_id}`)
    } catch (err: unknown) {
      const e = err as { message?: string }
      setStartError(e.message ?? 'Failed to start instance.')
    }
  }

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '1rem' }}>
        <h2 style={{ margin: 0 }}>Instances</h2>
        {canStartInstance && (
          <button
            data-testid="start-instance-button"
            onClick={openStartDialog}
            style={{
              padding: '.45rem .9rem',
              background: '#2563eb',
              color: '#fff',
              border: 'none',
              borderRadius: '4px',
              cursor: 'pointer',
              fontSize: '.85rem',
            }}
          >
            Start Instance
          </button>
        )}
      </div>

      <div style={{ display: 'flex', justifyContent: 'flex-end', alignItems: 'center', gap: '.6rem', marginBottom: '.8rem' }}>
        <span style={{ color: '#64748b', fontSize: '.8rem' }}>
          Last refreshed: {toRefreshLabel(polling.lastRefreshedAt)}
        </span>
        <button
          onClick={() => void polling.refreshNow()}
          disabled={instancesQuery.isRefetching}
          style={{
            padding: '.35rem .8rem',
            border: '1px solid #cbd5e1',
            borderRadius: '4px',
            background: '#fff',
            cursor: 'pointer',
            fontSize: '.8rem',
          }}
        >
          {instancesQuery.isRefetching ? 'Refreshing...' : 'Refresh'}
        </button>
      </div>

      <div data-testid="instance-filter-bar" style={{ display: 'grid', gap: '.75rem', marginBottom: '1rem' }}>
        <div style={{ display: 'flex', gap: '.6rem', flexWrap: 'wrap' }}>
          {STATUS_OPTIONS.map((status) => (
            <label
              key={status}
              style={{
                display: 'inline-flex',
                alignItems: 'center',
                gap: '.35rem',
                fontSize: '.85rem',
                color: '#334155',
              }}
            >
              <input
                data-testid={`status-filter-${status.toLowerCase()}`}
                type="checkbox"
                checked={statusFilters.includes(status)}
                onChange={() => onStatusToggle(status)}
              />
              {status}
            </label>
          ))}
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: '.5rem', flexWrap: 'wrap' }}>
          <label htmlFor="instance-definition-filter" style={{ color: '#475569', fontSize: '.85rem' }}>
            Definition
          </label>
          <input
            id="instance-definition-filter"
            data-testid="instance-definition-filter"
            list="instance-definition-filter-options"
            value={definitionName}
            onChange={(e) => onDefinitionInputChange(e.target.value)}
            onBlur={onResolveDefinition}
            placeholder="Type definition name"
            style={{
              minWidth: '260px',
              padding: '.35rem .6rem',
              borderRadius: '4px',
              border: '1px solid #cbd5e1',
              fontSize: '.85rem',
            }}
          />
          <datalist id="instance-definition-filter-options">
            {(definitionTypeahead?.items ?? []).map((def) => (
              <option key={def.id} value={def.name}>{def.name} (v{def.version})</option>
            ))}
          </datalist>
          {definitionId && (
            <span style={{ color: '#64748b', fontSize: '.8rem' }}>
              using active version {activeDefinitionByName?.version ?? '...'}
            </span>
          )}
        </div>
      </div>

      {instancesQuery.isLoading && <p>Loading…</p>}
      {instancesQuery.error && <p style={{ color: '#dc2626' }}>Failed to load instances.</p>}

      {instancesQuery.data && (
        <>
          <table data-testid="instance-board-table" style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.9rem' }}>
            <thead>
              <tr style={{ background: '#f1f5f9', textAlign: 'left' }}>
                <th style={{ padding: '.6rem .8rem' }}>Instance ID</th>
                <th style={{ padding: '.6rem .8rem' }}>Definition</th>
                <th style={{ padding: '.6rem .8rem' }}>Status</th>
                <th style={{ padding: '.6rem .8rem' }}>Correlation Key</th>
                <th style={{ padding: '.6rem .8rem' }}>Started</th>
                <th style={{ padding: '.6rem .8rem' }}>Last Updated</th>
              </tr>
            </thead>
            <tbody>
              {instancesQuery.data.items.map((inst) => (
                <tr key={inst.instance_id} style={{ borderBottom: '1px solid #e2e8f0' }}>
                  <td style={{ padding: '.6rem .8rem', fontFamily: 'monospace', fontSize: '.8rem' }}>
                    <Link data-testid={`instance-link-${inst.instance_id}`} to={`/instances/${inst.instance_id}`} style={{ color: '#2563eb' }}>
                      {inst.instance_id.slice(0, 8)}...
                    </Link>
                  </td>
                  <td style={{ padding: '.6rem .8rem' }}>{inst.definition_name} v{inst.definition_version}</td>
                  <td style={{ padding: '.6rem .8rem' }}>
                    <span style={{ color: STATUS_COLORS[inst.status], fontWeight: 600, fontSize: '.8rem' }}>{inst.status}</span>
                  </td>
                  <td style={{ padding: '.6rem .8rem', color: '#475569' }}>{inst.correlation_key ?? '—'}</td>
                  <td style={{ padding: '.6rem .8rem', color: '#64748b', fontSize: '.8rem' }}>{toISODate(inst.started_at)}</td>
                  <td style={{ padding: '.6rem .8rem', color: '#64748b', fontSize: '.8rem' }}>{toISODate(inst.updated_at ?? inst.started_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>

          <div style={{ marginTop: '1rem', display: 'flex', alignItems: 'center', gap: '.75rem' }}>
            <button
              onClick={resetFirstPage}
              disabled={!cursor}
              style={{
                padding: '.35rem .8rem',
                border: '1px solid #cbd5e1',
                borderRadius: '4px',
                background: '#fff',
                cursor: cursor ? 'pointer' : 'not-allowed',
                fontSize: '.85rem',
              }}
            >
              First page
            </button>
            <button
              onClick={goNextPage}
              disabled={!instancesQuery.data.next_cursor}
              style={{
                padding: '.35rem .8rem',
                border: '1px solid #cbd5e1',
                borderRadius: '4px',
                background: '#fff',
                cursor: instancesQuery.data.next_cursor ? 'pointer' : 'not-allowed',
                fontSize: '.85rem',
              }}
            >
              Next page
            </button>
            <span style={{ color: '#64748b', fontSize: '.8rem' }}>Page size: {pageSize}</span>
          </div>
        </>
      )}

      {showStart && (
        <div
          data-testid="start-instance-dialog"
          style={{
            position: 'fixed',
            inset: 0,
            background: 'rgba(0, 0, 0, 0.45)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            zIndex: 1000,
          }}
          onClick={closeStartDialog}
        >
          <div
            onClick={(e) => e.stopPropagation()}
            style={{
              width: '560px',
              maxWidth: '92vw',
              background: '#fff',
              borderRadius: '8px',
              boxShadow: '0 8px 24px rgba(0,0,0,0.16)',
              padding: '1rem 1.2rem',
            }}
          >
            <h3 style={{ marginTop: 0, marginBottom: '.75rem' }}>Start Instance</h3>

            {startError && <p style={{ marginTop: 0, color: '#dc2626' }}>{startError}</p>}
            {startValidationError && <p style={{ marginTop: 0, color: '#dc2626' }}>{startValidationError}</p>}

            <label htmlFor="start-definition-name" style={{ display: 'block', fontSize: '.85rem', color: '#334155', marginBottom: '.25rem' }}>
              Definition name
            </label>
            <input
              id="start-definition-name"
              data-testid="start-definition-name"
              list="instance-definition-filter-options"
              value={startDefinitionName}
              onChange={(e) => onStartDefinitionNameChange(e.target.value)}
              style={{
                width: '100%',
                marginBottom: '.6rem',
                padding: '.4rem .6rem',
                border: '1px solid #cbd5e1',
                borderRadius: '4px',
              }}
            />

            <label htmlFor="start-definition-version" style={{ display: 'block', fontSize: '.85rem', color: '#334155', marginBottom: '.25rem' }}>
              Active version (auto-selected)
            </label>
            <input
              id="start-definition-version"
              data-testid="start-definition-version"
              value={startDefinitionVersion}
              readOnly
              placeholder={isLoadingActiveDefinition ? 'Loading active version…' : ''}
              style={{
                width: '100%',
                marginBottom: '.6rem',
                padding: '.4rem .6rem',
                border: '1px solid #cbd5e1',
                borderRadius: '4px',
                background: '#f8fafc',
              }}
            />

            <label htmlFor="start-correlation-key" style={{ display: 'block', fontSize: '.85rem', color: '#334155', marginBottom: '.25rem' }}>
              Correlation key (optional)
            </label>
            <input
              id="start-correlation-key"
              data-testid="start-correlation-key"
              value={startCorrelationKey}
              onChange={(e) => setStartCorrelationKey(e.target.value)}
              style={{
                width: '100%',
                marginBottom: '.6rem',
                padding: '.4rem .6rem',
                border: '1px solid #cbd5e1',
                borderRadius: '4px',
              }}
            />

            <label htmlFor="start-variables-json" style={{ display: 'block', fontSize: '.85rem', color: '#334155', marginBottom: '.25rem' }}>
              Initial variables (JSON object)
            </label>
            <textarea
              id="start-variables-json"
              data-testid="start-variables-json"
              rows={8}
              value={startVariablesJson}
              onChange={(e) => setStartVariablesJson(e.target.value)}
              style={{
                width: '100%',
                marginBottom: '.75rem',
                padding: '.5rem .6rem',
                border: '1px solid #cbd5e1',
                borderRadius: '4px',
                fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
              }}
            />

            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: '.5rem' }}>
              <button
                onClick={closeStartDialog}
                style={{
                  padding: '.4rem .8rem',
                  border: '1px solid #cbd5e1',
                  borderRadius: '4px',
                  background: '#fff',
                  cursor: 'pointer',
                }}
              >
                Cancel
              </button>
              <button
                data-testid="submit-start-instance"
                onClick={() => void submitStartInstance()}
                disabled={startInstance.isPending}
                style={{
                  padding: '.4rem .8rem',
                  border: 'none',
                  borderRadius: '4px',
                  background: '#2563eb',
                  color: '#fff',
                  cursor: startInstance.isPending ? 'not-allowed' : 'pointer',
                }}
              >
                {startInstance.isPending ? 'Starting…' : 'Start'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
