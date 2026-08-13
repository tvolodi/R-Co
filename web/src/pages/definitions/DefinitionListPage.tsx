import React, { useState, useEffect, useRef } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { useDefinitions, useDefinitionVersions, useActivateDefinition, useArchiveDefinition, useCreateDefinition, useDefinitionSearch, definitionKeys } from '@/hooks/useDefinitions'
import { definitionsApi } from '@/api/definitions'
import { useDebounce } from '@/hooks/useDebounce'
import { highlightText } from '@/utils/highlightText'
import { useAuth } from '@/auth/AuthContext'
import type { DefinitionStatus, ProcessDefinition, DefinitionGraph } from '@/types/api'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'

const STATUS_BADGE: Record<string, string> = {
  DRAFT:      '#f59e0b',
  ACTIVE:     '#16a34a',
  DEPRECATED: '#9ca3af',
  ARCHIVED:   '#6b7280',
}

const DESIGNER_ROLES = ['PROCESS_DESIGNER', 'PLATFORM_ADMIN']

export default function DefinitionListPage() {
  const navigate = useNavigate()
  const qc = useQueryClient()
  const { session } = useAuth()
  const [status, setStatus] = useState<DefinitionStatus | undefined>()
  const [search, setSearch] = useState('')
  const [showCreate, setShowCreate] = useState(false)
  const [createName, setCreateName] = useState('')
  const [createVersion, setCreateVersion] = useState('')
  const [createDesc, setCreateDesc] = useState('')
  const [createError, setCreateError] = useState<string | null>(null)
  const [createValidationErrors, setCreateValidationErrors] = useState<{ name?: string; version?: string }>({})
  const [expandedDefId, setExpandedDefId] = useState<string | null>(null)
  const [expandedDefName, setExpandedDefName] = useState<string | null>(null)
  const [pendingNavId, setPendingNavId] = useState<string | null>(null)
  const [importError, setImportError] = useState<string | null>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)

  const hasDesignerRole = session?.roles?.some((r) => DESIGNER_ROLES.includes(r)) ?? false

  // Debounce search query (300ms)
  const debouncedSearch = useDebounce(search, 300)

  // Navigate to the newly-created definition after React commits all state.
  // Using useEffect ensures this runs outside the mutation's async handler,
  // avoiding React 18 batching interactions with simultaneous query invalidations.
  useEffect(() => {
    if (pendingNavId) {
      navigate(`/definitions/${pendingNavId}`)
    }
  }, [pendingNavId, navigate])
  const { data, isLoading, isError, error, refetch } = useDefinitions({ status })
  const searchQuery = useDefinitionSearch(debouncedSearch, { limit: 20 })
  const versionsQuery = useDefinitionVersions(expandedDefName ?? '')
  const activate = useActivateDefinition()
  const archive = useArchiveDefinition()
  const createDef = useCreateDefinition()

  const isSearching = debouncedSearch.trim().length > 0
  const searchResults = searchQuery.data as { items?: { definition: ProcessDefinition; rank: number }[] } | undefined
  const items: ProcessDefinition[] = isSearching
    ? (searchResults?.items?.map((r) => r.definition) ?? [])
    : ((data as { items?: ProcessDefinition[] } | undefined)?.items ?? [])
  const isLoadingItems = isSearching ? searchQuery.isLoading : isLoading
  const rendererState: RendererState = isLoading ? 'loading' : isError ? classifyError(error) : 'success'

  const validateCreate = (): boolean => {
    const errors: { name?: string; version?: string } = {}
    if (!createName.trim()) errors.name = 'Name is required'
    if (!createVersion.trim()) errors.version = 'Version is required'
    setCreateValidationErrors(errors)
    return Object.keys(errors).length === 0
  }

  const handleCreate = async () => {
    if (!validateCreate()) return
    setCreateError(null)
    try {
      const result = await createDef.mutateAsync({
        name: createName.trim(),
        version: createVersion.trim(),
        description: createDesc.trim(),
        graph: {
          nodes: [
            { id: 'start', node_type: 'START' as string, label: null },
            { id: 'end', node_type: 'END' as string, label: null },
          ],
          edges: [
            { id: 'e1', source: 'start', target: 'end', condition: null, is_default: false },
          ],
        } as unknown as DefinitionGraph,
      })
      setShowCreate(false)
      setCreateName('')
      setCreateVersion('')
      setCreateDesc('')
      setCreateValidationErrors({})
      setPendingNavId(result.id)
    } catch (err: unknown) {
      setCreateError(err instanceof Error ? err.message : 'Failed to create definition')
    }
  }

  const handleImport = async () => {
    fileInputRef.current?.click()
  }

  const handleFileSelected = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file) return
    setImportError(null)

    try {
      const text = await file.text()
      const parsed = JSON.parse(text)

      const result = await definitionsApi.importJson(parsed)
      setImportError(null)
      qc.invalidateQueries({ queryKey: definitionKeys.all })
      navigate(`/definitions/${result.id}`)
    } catch (err: unknown) {
      const apiErr = err as { status?: number; message?: string }
      if (apiErr.status === 422) {
        setImportError(apiErr.message ?? 'Invalid file — expected a BPM export JSON file')
      } else if (apiErr.status === 409) {
        setImportError('A definition with this name and version already exists.')
      } else if (err instanceof SyntaxError) {
        setImportError('Invalid file — expected a BPM export JSON file')
      } else {
        setImportError(apiErr.message ?? 'Could not read file')
      }
    } finally {
      // Reset file input so the same file can be selected again
      if (fileInputRef.current) fileInputRef.current.value = ''
    }
  }

  return (
    <div style={{ padding: '1.5rem' }}>
      <div data-testid="filter-bar" style={{ display: 'flex', alignItems: 'center', gap: '1rem', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Process Definitions</h2>
        <input
          data-testid="definition-search"
          type="text"
          placeholder="Search definitions..."
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          style={{ padding: '.35rem .6rem', borderRadius: '4px', border: '1px solid #cbd5e1', fontSize: '.85rem', flex: 1, maxWidth: '280px' }}
        />
        {isSearching && searchQuery.isFetching && (
          <span style={{ fontSize: '.75rem', color: '#94a3b8' }}>Searching…</span>
        )}
        <div data-testid="status-filter" style={{ display: 'inline-flex', alignItems: 'center', gap: '.35rem' }}>
          <span style={{ fontSize: '.85rem', color: '#475569' }}>Status</span>
          <select
            data-testid="status-filter-select"
            value={status ?? ''}
            onChange={(e) => setStatus((e.target.value as DefinitionStatus) || undefined)}
            style={{ padding: '.35rem .6rem', borderRadius: '4px', border: '1px solid #cbd5e1', fontSize: '.85rem' }}
          >
            <option value="">All</option>
            <option value="DRAFT">Draft</option>
            <option value="ACTIVE">Active</option>
            <option value="DEPRECATED">Deprecated</option>
            <option value="ARCHIVED">Archived</option>
          </select>
        </div>
        <div style={{ marginLeft: 'auto', display: 'flex', gap: '.5rem' }}>
          {hasDesignerRole && (
            <>
              <button
                data-testid="btn-import-definition"
                onClick={handleImport}
                style={{ padding: '.4rem .9rem', background: '#fff', color: '#374151', borderRadius: '4px', border: '1px solid #cbd5e1', cursor: 'pointer', fontSize: '.85rem' }}
              >
                Import
              </button>
              <input
                ref={fileInputRef}
                type="file"
                accept=".json"
                style={{ display: 'none' }}
                onChange={handleFileSelected}
                data-testid="import-file-input"
              />
            </>
          )}
          <button
            data-testid="btn-new-definition"
            onClick={() => setShowCreate(true)}
            style={{ padding: '.4rem .9rem', background: '#2563eb', color: '#fff', borderRadius: '4px', border: 'none', cursor: 'pointer', fontSize: '.85rem' }}
          >
            + New Definition
          </button>
        </div>
      </div>

      <QueryStateBoundary
        state={rendererState}
        onRetry={() => { void refetch() }}
        columns={[{ widthPercent: 35 }, { widthPercent: 15 }, { widthPercent: 15 }, { widthPercent: 20 }, { widthPercent: 15 }]}
      >
      {!isLoadingItems && items.length === 0 && (
        <p data-testid="empty-state" style={{ textAlign: 'center', color: '#94a3b8', padding: '2rem' }}>
          {isSearching ? `No results found for "${debouncedSearch}"` : 'No definitions found'}
        </p>
      )}

      {importError && (
        <div
          data-testid="import-error-dialog"
          style={{
            padding: '8px 16px',
            background: '#ffe3e3',
            color: '#c92a2a',
            fontSize: '.85rem',
            borderBottom: '1px solid #fa5252',
            marginBottom: '.5rem',
          }}
        >
          {importError}
        </div>
      )}

      {items.length > 0 && (
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
            {items.map((def: ProcessDefinition) => (
              <React.Fragment key={def.id}>
                <tr style={{ borderBottom: '1px solid #e2e8f0' }}>
                  <td style={{ padding: '.6rem .8rem' }}>
                    <div>
                      <span
                        data-testid={`def-name-${def.id}`}
                        onClick={() => {
                          if (expandedDefId === def.id) {
                            setExpandedDefId(null)
                            setExpandedDefName(null)
                          } else {
                            setExpandedDefId(def.id)
                            setExpandedDefName(def.name)
                          }
                        }}
                        style={{ color: '#2563eb', textDecoration: 'none', cursor: 'pointer' }}
                      >
                        {isSearching ? highlightText(def.name, debouncedSearch) : def.name}
                      </span>
                      {isSearching && def.description && (
                        <div style={{ fontSize: '.8rem', color: '#64748b', marginTop: '2px' }}>
                          {highlightText(def.description ?? '', debouncedSearch)}
                        </div>
                      )}
                    </div>
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
                {expandedDefId === def.id && (
                  <tr data-testid="version-history-row">
                    <td colSpan={5} style={{ padding: '0' }}>
                      <div style={{ background: '#f8fafc', padding: '1rem 1.5rem', borderBottom: '1px solid #e2e8f0' }}>
                        <strong style={{ fontSize: '.85rem', color: '#374151' }}>
                          Version history: {def.name}
                        </strong>
                        {versionsQuery.isLoading && (
                          <p style={{ fontSize: '.8rem', color: '#94a3b8', margin: '.5rem 0 0' }}>Loading versions...</p>
                        )}
                        {versionsQuery.data && (
                          <div style={{ marginTop: '.5rem' }}>
                            {(versionsQuery.data as { items?: ProcessDefinition[] }).items?.map((v) => (
                              <div key={v.id} style={{ display: 'flex', gap: '1rem', padding: '.3rem 0', fontSize: '.85rem', color: '#475569', borderBottom: '1px solid #e2e8f0' }}>
                                <span style={{ fontWeight: 600 }}>{v.version}</span>
                                <span style={{ color: STATUS_BADGE[v.status] ?? '#374151' }}>{v.status}</span>
                                <span style={{ color: '#94a3b8' }}>{new Date(v.updated_at).toLocaleDateString()}</span>
                              </div>
                            ))}
                          </div>
                        )}
                      </div>
                    </td>
                  </tr>
                )}
              </React.Fragment>
            ))}
          </tbody>
        </table>
      )}
      </QueryStateBoundary>

      {/* Create Definition Dialog */}
      {showCreate && (
        <div
          data-testid="create-definition-dialog"
          style={{
            position: 'fixed', top: 0, left: 0, right: 0, bottom: 0,
            background: 'rgba(0,0,0,0.4)', display: 'flex',
            alignItems: 'center', justifyContent: 'center', zIndex: 1000,
          }}
          onClick={() => setShowCreate(false)}
        >
          <div
            style={{
              background: '#fff', borderRadius: '8px', padding: '1.5rem',
              width: '420px', maxWidth: '90vw', boxShadow: '0 4px 24px rgba(0,0,0,0.15)',
            }}
            onClick={(e) => e.stopPropagation()}
          >
            <h3 style={{ margin: '0 0 1rem' }}>Create New Definition</h3>

            {createError && (
              <p style={{ color: '#dc2626', fontSize: '.85rem', marginBottom: '.75rem' }}>{createError}</p>
            )}

            <div style={{ marginBottom: '.75rem' }}>
              <label style={{ display: 'block', fontSize: '.85rem', fontWeight: 600, marginBottom: '.25rem', color: '#374151' }}>
                Name <span style={{ color: '#dc2626' }}>*</span>
              </label>
              <input
                data-testid="create-name-input"
                type="text"
                value={createName}
                onChange={(e) => { setCreateName(e.target.value); setCreateValidationErrors((prev) => ({ ...prev, name: undefined })) }}
                style={{ width: '100%', padding: '.4rem .6rem', borderRadius: '4px', border: '1px solid #cbd5e1', fontSize: '.85rem', boxSizing: 'border-box' }}
                placeholder="My Process"
              />
              {createValidationErrors.name && (
                <p style={{ color: '#dc2626', fontSize: '.8rem', margin: '.25rem 0 0' }}>{createValidationErrors.name}</p>
              )}
            </div>

            <div style={{ marginBottom: '.75rem' }}>
              <label style={{ display: 'block', fontSize: '.85rem', fontWeight: 600, marginBottom: '.25rem', color: '#374151' }}>
                Version <span style={{ color: '#dc2626' }}>*</span>
              </label>
              <input
                data-testid="create-version-input"
                type="text"
                value={createVersion}
                onChange={(e) => { setCreateVersion(e.target.value); setCreateValidationErrors((prev) => ({ ...prev, version: undefined })) }}
                style={{ width: '100%', padding: '.4rem .6rem', borderRadius: '4px', border: '1px solid #cbd5e1', fontSize: '.85rem', boxSizing: 'border-box' }}
                placeholder="1.0.0"
              />
              {createValidationErrors.version && (
                <p style={{ color: '#dc2626', fontSize: '.8rem', margin: '.25rem 0 0' }}>{createValidationErrors.version}</p>
              )}
            </div>

            <div style={{ marginBottom: '1rem' }}>
              <label style={{ display: 'block', fontSize: '.85rem', fontWeight: 600, marginBottom: '.25rem', color: '#374151' }}>
                Description
              </label>
              <textarea
                data-testid="create-description-input"
                value={createDesc}
                onChange={(e) => setCreateDesc(e.target.value)}
                style={{ width: '100%', padding: '.4rem .6rem', borderRadius: '4px', border: '1px solid #cbd5e1', fontSize: '.85rem', boxSizing: 'border-box', minHeight: '60px' }}
                placeholder="Optional description"
              />
            </div>

            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: '.5rem' }}>
              <button
                data-testid="create-cancel"
                onClick={() => { setShowCreate(false); setCreateError(null); setCreateValidationErrors({}) }}
                style={{ padding: '.4rem .9rem', background: '#f1f5f9', color: '#374151', borderRadius: '4px', border: '1px solid #cbd5e1', cursor: 'pointer', fontSize: '.85rem' }}
              >
                Cancel
              </button>
              <button
                data-testid="create-submit"
                onClick={handleCreate}
                disabled={createDef.isPending}
                style={{
                  padding: '.4rem .9rem', background: '#2563eb',
                  color: '#fff', borderRadius: '4px', border: 'none', cursor: 'pointer',
                  fontSize: '.85rem',
                }}
              >
                {createDef.isPending ? 'Creating...' : 'Create'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
