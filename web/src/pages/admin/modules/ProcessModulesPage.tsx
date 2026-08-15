/** Process Module Catalog Page — PLC-01, PLC-02, PLC-03, PLC-04
 *
 * PLC-01: Lists all catalog entries with module_id, version, status, exportable
 * PLC-02: Publish button → 422 if interface not declared
 * PLC-03: Compatibility warning display on publish
 * PLC-04: Grant / Revoke visibility dialogs for cross-tenant distribution
 */
import { useState } from 'react'
import { useModules, useModuleShares, usePublishModule, useGrantModuleShare, useRevokeModuleShare } from '@/hooks/useModules'
import type { ProcessModuleCatalogEntry, CompatibilityWarning, ModuleShare } from '@/api/modules'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'

const STATUS_COLORS: Record<string, string> = {
  DRAFT: '#f59e0b',
  ACTIVE: '#16a34a',
  DEPRECATED: '#9ca3af',
}

// ── Compatibility Warning Banner ────────────────────────────────────────────────

function CompatibilityWarningBanner({ warning }: { warning: CompatibilityWarning }) {
  return (
    <div style={{
      marginTop: '1rem',
      padding: '.75rem 1rem',
      background: '#fff3bf',
      border: '1px solid #fcc419',
      borderRadius: '6px',
    }}>
      <strong style={{ color: '#92400e' }}>Compatibility Warning</strong>
      <ul style={{ margin: '.5rem 0 0 1.25rem', padding: 0, color: '#78350f' }}>
        {warning.breaking_changes.map((c, i) => (
          <li key={i}>{c}</li>
        ))}
      </ul>
    </div>
  )
}

// ── Module Detail Drawer ──────────────────────────────────────────────────────

interface DetailDrawerProps {
  entry: ProcessModuleCatalogEntry | null
  onClose: () => void
  onGrant: (moduleId: string, grantingTenantId: string) => void
  onRevoke: (grant: ModuleShare) => void
}

function DetailDrawer({ entry, onClose, onGrant, onRevoke }: DetailDrawerProps) {
  const [showShares, setShowShares] = useState(false)
  const { data: sharesData } = useModuleShares(entry?.module_id ?? '')
  const shares: ModuleShare[] = sharesData?.items ?? []

  if (!entry) return null

  return (
    <div style={{
      position: 'fixed', inset: 0, zIndex: 50,
      display: 'flex', justifyContent: 'flex-end',
    }}>
      <div style={{
        position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.4)',
      }} onClick={onClose} />
      <div style={{
        position: 'relative', width: '520px', background: '#fff',
        padding: '1.5rem', overflowY: 'auto',
        boxShadow: '-4px 0 16px rgba(0,0,0,0.15)',
      }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
          <h3 style={{ marginTop: 0 }}>Module: {entry.module_id}</h3>
          <button onClick={onClose} style={{ background: 'none', border: 'none', fontSize: '1.2rem', cursor: 'pointer', padding: 0 }}>×</button>
        </div>
        <dl style={{ display: 'grid', gridTemplateColumns: 'auto 1fr', gap: '.5rem' }}>
          <dt style={{ color: '#6b7280', fontSize: '.85rem' }}>Version</dt>
          <dd style={{ margin: 0, fontFamily: 'monospace' }}>{entry.version}</dd>
          <dt style={{ color: '#6b7280', fontSize: '.85rem' }}>Status</dt>
          <dd><span style={{
            display: 'inline-block', padding: '.1rem .5rem', borderRadius: '9999px',
            fontSize: '.75rem', fontWeight: 600, color: '#fff',
            background: STATUS_COLORS[entry.status] ?? '#6b7280',
          }}>{entry.status}</span></dd>
          <dt style={{ color: '#6b7280', fontSize: '.85rem' }}>Owning Definition ID</dt>
          <dd style={{ margin: 0, fontFamily: 'monospace', fontSize: '.8rem', wordBreak: 'break-all' }}>{entry.owning_definition_id}</dd>
          <dt style={{ color: '#6b7280', fontSize: '.85rem' }}>Owning Tenant ID</dt>
          <dd style={{ margin: 0, fontFamily: 'monospace', fontSize: '.75rem', wordBreak: 'break-all' }}>{entry.owning_tenant_id}</dd>
          <dt style={{ color: '#6b7280', fontSize: '.85rem' }}>Exportable</dt>
          <dd style={{ margin: 0 }}>{entry.exportable ? 'Yes' : 'No'}</dd>
          <dt style={{ color: '#6b7280', fontSize: '.85rem', marginTop: '.5rem' }}>Interface Schema</dt>
          <dd style={{ margin: 0 }}>
            <pre style={{
              background: '#f1f5f9', padding: '.5rem',
              borderRadius: '4px', fontSize: '.75rem',
              overflowX: 'auto', maxHeight: '200px',
            }}>
              {JSON.stringify(entry.interface_schema, null, 2)}
            </pre>
          </dd>
          <dt style={{ color: '#6b7280', fontSize: '.85rem' }}>Created</dt>
          <dd style={{ margin: 0 }}>{new Date(entry.created_at).toLocaleString()}</dd>
          <dt style={{ color: '#6b7280', fontSize: '.85rem' }}>Updated</dt>
          <dd style={{ margin: 0 }}>{new Date(entry.updated_at).toLocaleString()}</dd>
        </dl>

        {/* PLC-04: Cross-tenant visibility management */}
        <div style={{ display: 'flex', gap: '.5rem', marginTop: '1.25rem', marginBottom: '.5rem' }}>
          <button
            onClick={() => onGrant(entry.module_id, entry.owning_tenant_id)}
            style={{ padding: '.4rem .75rem', fontSize: '.85rem', border: '1px solid #d1d5db', borderRadius: '4px', background: '#fff', cursor: 'pointer' }}
          >
            Grant Visibility
          </button>
          <button
            onClick={() => setShowShares(!showShares)}
            style={{ padding: '.4rem .75rem', fontSize: '.85rem', border: '1px solid #d1d5db', borderRadius: '4px', background: '#fff', cursor: 'pointer' }}
          >
            View Shares ({shares.length})
          </button>
        </div>

        {showShares && shares.length > 0 && (
          <div style={{ marginTop: '1rem' }}>
            <h4 style={{ marginBottom: '.75rem' }}>Shared With</h4>
            <table style={{ width: '100%', fontSize: '.85rem', borderCollapse: 'collapse' }}>
              <thead>
                <tr style={{ borderBottom: '1px solid #e5e7eb' }}>
                  <th style={{ textAlign: 'left', padding: '.25rem .5rem .25rem 0', color: '#6b7280' }}>Receiving Tenant</th>
                  <th style={{ textAlign: 'left', padding: '.25rem .5rem .25rem 0', color: '#6b7280' }}>Granted At</th>
                  <th style={{ textAlign: 'right', padding: '.25rem 0', color: '#6b7280' }}></th>
                </tr>
              </thead>
              <tbody>
                {shares.map(s => (
                  <tr key={s.grant_id} style={{ borderBottom: '1px solid #f3f4f6' }}>
                    <td style={{ padding: '.25rem .5rem .25rem 0', fontFamily: 'monospace', fontSize: '.75rem', wordBreak: 'break-all' }}>
                      {s.receiving_tenant_id}
                    </td>
                    <td style={{ padding: '.25rem .5rem .25rem 0' }}>
                      {new Date(s.granted_at).toLocaleDateString()}
                    </td>
                    <td style={{ padding: '.25rem 0', textAlign: 'right' }}>
                      <button
                        onClick={() => onRevoke(s)}
                        style={{ fontSize: '.75rem', color: '#dc2626', background: 'none', border: 'none', cursor: 'pointer', padding: 0 }}
                      >
                        Revoke
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  )
}

// ── Grant Visibility Dialog ────────────────────────────────────────────────────

interface GrantDialogProps {
  moduleId: string
  open: boolean
  onClose: () => void
  onConfirm: (receivingTenantId: string) => Promise<void>
}

function GrantVisibilityDialog({ moduleId, open, onClose, onConfirm }: GrantDialogProps) {
  const [receivingTenantId, setReceivingTenantId] = useState('')
  const [isLoading, setIsLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  if (!open) return null

  const handleGrant = async () => {
    if (!receivingTenantId.trim()) return
    setIsLoading(true)
    setError(null)
    try {
      await onConfirm(receivingTenantId.trim())
      onClose()
      setReceivingTenantId('')
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Grant failed')
    } finally {
      setIsLoading(false)
    }
  }

  return (
    <div style={{ position: 'fixed', inset: 0, zIndex: 60, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <div style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.5)' }} onClick={onClose} />
      <div style={{
        position: 'relative', background: '#fff', borderRadius: '8px',
        padding: '1.5rem', width: '400px', boxShadow: '0 20px 40px rgba(0,0,0,0.2)',
      }}>
        <h3 style={{ marginTop: 0 }}>Grant Module Visibility</h3>
        <p style={{ fontSize: '.9rem', color: '#6b7280', marginBottom: '1rem' }}>
          Allow another tenant to resolve module <strong>{moduleId}</strong>.
        </p>
        <input
          value={receivingTenantId}
          onChange={e => setReceivingTenantId(e.target.value)}
          placeholder="Receiving Tenant ID (UUID)"
          style={{ width: '100%', padding: '.5rem', border: '1px solid #d1d5db', borderRadius: '4px', boxSizing: 'border-box' }}
        />
        {error && <p style={{ color: '#dc2626', fontSize: '.85rem', marginTop: '.5rem' }}>{error}</p>}
        <div style={{ display: 'flex', gap: '.75rem', justifyContent: 'flex-end', marginTop: '1rem' }}>
          <button onClick={onClose} style={{ padding: '.5rem 1rem', border: '1px solid #d1d5db', borderRadius: '4px', background: '#fff', cursor: 'pointer' }}>
            Cancel
          </button>
          <button onClick={handleGrant} disabled={isLoading || !receivingTenantId.trim()}
            style={{
              padding: '.5rem 1rem', border: 'none', borderRadius: '4px',
              background: isLoading ? '#93c5fd' : '#2563eb', color: '#fff',
              cursor: isLoading || !receivingTenantId.trim() ? 'not-allowed' : 'pointer',
            }}>
            {isLoading ? 'Granting…' : 'Grant'}
          </button>
        </div>
      </div>
    </div>
  )
}

// ── Revoke Confirmation Dialog ─────────────────────────────────────────────────

interface RevokeDialogProps {
  grant: ModuleShare | null
  onClose: () => void
  onConfirm: () => void
}

function RevokeVisibilityDialog({ grant, onClose, onConfirm }: RevokeDialogProps) {
  const [isLoading, setIsLoading] = useState(false)
  const revoke = useRevokeModuleShare()

  if (!grant) return null

  const handleRevoke = async () => {
    setIsLoading(true)
    try {
      await revoke.mutateAsync({ grantId: grant.grant_id, moduleId: grant.module_id })
      onConfirm()
      onClose()
    } finally {
      setIsLoading(false)
    }
  }

  return (
    <div style={{ position: 'fixed', inset: 0, zIndex: 60, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <div style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.5)' }} onClick={onClose} />
      <div style={{
        position: 'relative', background: '#fff', borderRadius: '8px',
        padding: '1.5rem', width: '400px', boxShadow: '0 20px 40px rgba(0,0,0,0.2)',
      }}>
        <h3 style={{ marginTop: 0, color: '#dc2626' }}>Revoke Module Visibility</h3>
        <p style={{ fontSize: '.9rem', color: '#374151' }}>
          Revoke access for tenant <strong>{grant.receiving_tenant_id}</strong> from module <strong>{grant.module_id}</strong>?
          This does not affect running instances.
        </p>
        <div style={{ display: 'flex', gap: '.75rem', justifyContent: 'flex-end', marginTop: '1rem' }}>
          <button onClick={onClose} style={{ padding: '.5rem 1rem', border: '1px solid #d1d5db', borderRadius: '4px', background: '#fff', cursor: 'pointer' }}>
            Cancel
          </button>
          <button onClick={handleRevoke} disabled={isLoading}
            style={{
              padding: '.5rem 1rem', border: 'none', borderRadius: '4px',
              background: isLoading ? '#fca5a5' : '#dc2626', color: '#fff', cursor: isLoading ? 'not-allowed' : 'pointer',
            }}>
            {isLoading ? 'Revoking…' : 'Revoke'}
          </button>
        </div>
      </div>
    </div>
  )
}

// ── Main Page ──────────────────────────────────────────────────────────────────

export default function ProcessModulesPage() {
  const [selectedEntry, setSelectedEntry] = useState<ProcessModuleCatalogEntry | null>(null)
  const [grantDialogOpen, setGrantDialogOpen] = useState(false)
  const [grantModuleId, setGrantModuleId] = useState('')
  const [grantTenantId, setGrantTenantId] = useState('')
  const [revokeGrant, setRevokeGrant] = useState<ModuleShare | null>(null)
  const [publishError, setPublishError] = useState<string | null>(null)
  const [publishWarning, setPublishWarning] = useState<CompatibilityWarning | null>(null)

  const { data, isLoading, isError, error, refetch } = useModules()
  const publish = usePublishModule()
  const grant = useGrantModuleShare()
  const revoke = useRevokeModuleShare()

  const entries: ProcessModuleCatalogEntry[] = data?.items ?? []
  const rendererState: RendererState = isLoading ? 'loading' : isError ? classifyError(error) : 'success'

  const handlePublish = async (entry: ProcessModuleCatalogEntry) => {
    setPublishError(null)
    setPublishWarning(null)
    try {
      const result = await publish.mutateAsync({ moduleId: entry.module_id, version: entry.version })
      setPublishWarning(result.compatibility_warning)
      setSelectedEntry(result.entry)
      await refetch()
    } catch (e: unknown) {
      const err = e as { response?: { data?: { code?: string; message?: string }; status?: number } }
      if (err.response?.status === 422) {
        setPublishError('Interface not declared: publish requires a declared SPC-01 interface (422 Unprocessable Entity).')
      } else if (err.response?.status === 409) {
        setPublishError('Module is already ACTIVE (409 Conflict).')
      } else {
        setPublishError(err.response?.data?.message ?? 'Publish failed')
      }
    }
  }

  const handleGrantOpen = (moduleId: string, grantingTenantId: string) => {
    setGrantModuleId(moduleId)
    setGrantTenantId(grantingTenantId)
    setGrantDialogOpen(true)
  }

  const handleGrantConfirm = async (receivingTenantId: string) => {
    await grant.mutateAsync({
      granting_tenant_id: grantTenantId,
      module_id: grantModuleId,
      receiving_tenant_id: receivingTenantId,
    })
  }

  const handleRevokeConfirm = async () => {
    if (!revokeGrant) return
    try {
      await revoke.mutateAsync({ grantId: revokeGrant.grant_id, moduleId: revokeGrant.module_id })
    } finally {
      setRevokeGrant(null)
    }
  }

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '1.5rem' }}>
        <h2 style={{ margin: 0 }}>Process Module Catalog</h2>
      </div>

      {publishError && (
        <div style={{ padding: '.75rem 1rem', background: '#ffe3e3', border: '1px solid #fa5252', borderRadius: '6px', marginBottom: '1rem', color: '#c92a2a', fontSize: '.9rem' }}>
          <strong>Publish Failed</strong><br />
          {publishError}
        </div>
      )}

      <QueryStateBoundary
        state={rendererState}
        onRetry={refetch}
      >
        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.9rem' }}>
          <thead>
            <tr style={{ borderBottom: '2px solid #e5e7eb', textAlign: 'left' }}>
              <th style={{ padding: '.5rem .75rem', color: '#6b7280', fontWeight: 500 }}>Module ID</th>
              <th style={{ padding: '.5rem .75rem', color: '#6b7280', fontWeight: 500 }}>Version</th>
              <th style={{ padding: '.5rem .75rem', color: '#6b7280', fontWeight: 500 }}>Status</th>
              <th style={{ padding: '.5rem .75rem', color: '#6b7280', fontWeight: 500 }}>Exportable</th>
              <th style={{ padding: '.5rem .75rem', color: '#6b7280', fontWeight: 500 }}>Actions</th>
            </tr>
          </thead>
          <tbody>
            {entries.length === 0 && !isLoading && (
              <tr>
                <td colSpan={5} style={{ padding: '2rem', textAlign: 'center', color: '#9ca3af' }}>
                  No modules found. Register a module from a process definition.
                </td>
              </tr>
            )}
            {entries.map(entry => (
              <tr key={`${entry.module_id}-${entry.version}`} style={{ borderBottom: '1px solid #f3f4f6' }}>
                <td style={{ padding: '.6rem .75rem', fontFamily: 'monospace', fontWeight: 500 }}>
                  {entry.module_id}
                </td>
                <td style={{ padding: '.6rem .75rem', fontFamily: 'monospace', color: '#374151' }}>
                  {entry.version}
                </td>
                <td style={{ padding: '.6rem .75rem' }}>
                  <span style={{
                    display: 'inline-block', padding: '.15rem .6rem', borderRadius: '9999px',
                    fontSize: '.75rem', fontWeight: 600, color: '#fff',
                    background: STATUS_COLORS[entry.status] ?? '#6b7280',
                  }}>
                    {entry.status}
                  </span>
                </td>
                <td style={{ padding: '.6rem .75rem', color: entry.exportable ? '#16a34a' : '#9ca3af' }}>
                  {entry.exportable ? 'Yes' : 'No'}
                </td>
                <td style={{ padding: '.6rem .75rem' }}>
                  <div style={{ display: 'flex', gap: '.5rem', alignItems: 'center' }}>
                    <button
                      onClick={() => setSelectedEntry(entry)}
                      style={{ padding: '.25rem .6rem', fontSize: '.8rem', border: '1px solid #d1d5db', borderRadius: '4px', background: '#fff', cursor: 'pointer' }}
                    >
                      Details
                    </button>
                    {entry.status === 'DRAFT' && (
                      <button
                        onClick={() => handlePublish(entry)}
                        disabled={publish.isPending}
                        style={{
                          padding: '.25rem .6rem', fontSize: '.8rem', border: 'none',
                          borderRadius: '4px', background: '#16a34a', color: '#fff',
                          cursor: publish.isPending ? 'not-allowed' : 'pointer',
                          opacity: publish.isPending ? 0.6 : 1,
                        }}
                      >
                        {publish.isPending ? 'Publishing…' : 'Publish'}
                      </button>
                    )}
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </QueryStateBoundary>

      {publishWarning && !selectedEntry && (
        <CompatibilityWarningBanner warning={publishWarning} />
      )}

      {selectedEntry && (
        <>
          {publishWarning && selectedEntry.status === 'ACTIVE' && (
            <CompatibilityWarningBanner warning={publishWarning} />
          )}
          <DetailDrawer
            entry={selectedEntry}
            onClose={() => { setSelectedEntry(null); setPublishWarning(null); setPublishError(null) }}
            onGrant={handleGrantOpen}
            onRevoke={(grant) => setRevokeGrant(grant)}
          />
        </>
      )}

      <GrantVisibilityDialog
        open={grantDialogOpen}
        moduleId={grantModuleId}
        onClose={() => setGrantDialogOpen(false)}
        onConfirm={handleGrantConfirm}
      />

      <RevokeVisibilityDialog
        grant={revokeGrant}
        onClose={() => setRevokeGrant(null)}
        onConfirm={handleRevokeConfirm}
      />
    </div>
  )
}
