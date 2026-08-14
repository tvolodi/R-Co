/** ConflictResolver — RND-UI-06
 *
 *  Three-action modal surfaced on a 409 write conflict:
 *    1. Refetch latest — leaves the local draft intact, signals caller to refetch.
 *    2. Merge manually — opens a side-by-side diff; emits onSaveMerged with
 *       mergedBody + conflictVersion. Disabled when conflictVersion is null
 *       (the server did not emit X-Resource-Version).
 *    3. Discard mine — opens a ConfirmDialog; on confirm emits onDiscardConfirmed.
 *
 *  The component makes NO API calls (§2.1 AC-2). The modal is the only
 *  rendered surface until the user clicks one of the three actions.
 */

import React, { useState } from 'react'
import { createPortal } from 'react-dom'
import { JsonDiffView } from './JsonDiffView'
import { ConfirmDialog } from './ConfirmDialog'

export interface ConflictResolverProps {
  /** Server payload after the 409. */
  serverPayload: Record<string, unknown>
  /** Local draft from the Zustand store. */
  localDraft: Record<string, unknown>
  /** The new version stamp to use when the user picks Merge manually. */
  conflictVersion: string | null
  /** Called when the user picks "Refetch latest". */
  onRefetch: () => void
  /** Called when the user picks "Merge manually" and saves. */
  onSaveMerged: (mergedBody: Record<string, unknown>, version: string) => void
  /** Called when the user confirms the Discard mine dialog. */
  onDiscardConfirmed: () => void
  /** The host element to portal into. Defaults to document.body. */
  portalContainer?: HTMLElement
}

const portalHost = (container?: HTMLElement): HTMLElement => {
  if (container) return container
  if (typeof document === 'undefined') {
    throw new Error('ConflictResolver cannot render without a DOM (SSR environment detected).')
  }
  return document.body
}

type MergeSource = 'server' | 'local'

function pickMergeValue(
  source: MergeSource,
  key: string,
  serverPayload: Record<string, unknown>,
  localDraft: Record<string, unknown>,
): unknown {
  const fromServer = serverPayload[key]
  const fromLocal = localDraft[key]
  return source === 'server' ? fromServer : fromLocal
}

export function ConflictResolver(props: ConflictResolverProps): React.ReactElement | null {
  const {
    serverPayload,
    localDraft,
    conflictVersion,
    onRefetch,
    onSaveMerged,
    onDiscardConfirmed,
    portalContainer,
  } = props

  const [showMerge, setShowMerge] = useState<boolean>(false)
  const [showDiscard, setShowDiscard] = useState<boolean>(false)
  const [choices, setChoices] = useState<Record<string, MergeSource>>({})

  // §12.2 mode 5 — server version older than local: keep Merge enabled but show banner.
  const serverIsStale = false // Computed in StaleVersionError when applicable.

  // Build the union of keys from server + local for the diff picker
  const allKeys = Array.from(
    new Set([...Object.keys(serverPayload ?? {}), ...Object.keys(localDraft ?? {})]),
  ).sort()

  const initialiseChoice = (k: string): MergeSource => choices[k] ?? 'local'

  const handleMergeSave = (): void => {
    if (conflictVersion == null) return
    const mergedBody: Record<string, unknown> = {}
    for (const k of allKeys) {
      mergedBody[k] = pickMergeValue(initialiseChoice(k), k, serverPayload, localDraft)
    }
    setShowMerge(false)
    onSaveMerged(mergedBody, conflictVersion)
  }

  const handleDiscardConfirm = (): void => {
    setShowDiscard(false)
    onDiscardConfirmed()
  }

  const mergeDisabledReasonId = 'conflict-merge-disabled-reason'

  const dialog = (
    <div
      data-testid="conflict-resolver"
      role="dialog"
      aria-modal="true"
      aria-labelledby="conflict-resolver-title"
      style={{
        position: 'fixed',
        inset: 0,
        background: 'rgba(0,0,0,0.45)',
        zIndex: 550,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      <div
        style={{
          background: '#fff',
          borderRadius: '8px',
          padding: '1.5rem',
          maxWidth: '560px',
          width: '92vw',
          boxShadow: '0 8px 32px rgba(0,0,0,0.18)',
        }}
      >
        <h3
          id="conflict-resolver-title"
          style={{ margin: '0 0 1rem', fontSize: '1.05rem', fontWeight: 600 }}
        >
          This record was updated by another user
        </h3>

        {serverIsStale && (
          <div
            data-testid="conflict-version-mismatch"
            style={{
              padding: '.75rem 1rem',
              background: '#fef3c7',
              border: '1px solid #fde68a',
              borderRadius: '4px',
              marginBottom: '1rem',
              color: '#92400e',
              fontSize: '.85rem',
            }}
          >
            Server version is older than local — Discard mine recommended.
          </div>
        )}

        <p style={{ margin: '0 0 1.25rem', color: '#374151', fontSize: '.9rem' }}>
          Choose how to resolve the conflict:
        </p>

        <div style={{ display: 'flex', flexDirection: 'column', gap: '.5rem' }}>
          <button
            data-testid="conflict-refetch"
            type="button"
            onClick={() => onRefetch()}
            style={{
              padding: '.6rem 1rem',
              border: '1px solid #2563eb',
              borderRadius: '4px',
              background: '#fff',
              color: '#2563eb',
              cursor: 'pointer',
              fontSize: '.9rem',
            }}
          >
            Refetch latest
          </button>

          <div>
            <button
              data-testid="conflict-merge"
              type="button"
              onClick={() => setShowMerge(true)}
              disabled={conflictVersion == null}
              aria-disabled={conflictVersion == null}
              aria-describedby={conflictVersion == null ? mergeDisabledReasonId : undefined}
              style={{
                padding: '.6rem 1rem',
                border: '1px solid #6b7280',
                borderRadius: '4px',
                background: '#fff',
                color: '#374151',
                cursor: conflictVersion == null ? 'not-allowed' : 'pointer',
                fontSize: '.9rem',
                opacity: conflictVersion == null ? 0.6 : 1,
              }}
            >
              Merge manually
            </button>
            {conflictVersion == null && (
              <p
                id={mergeDisabledReasonId}
                style={{
                  margin: '.25rem 0 0',
                  fontSize: '.8rem',
                  color: '#6b7280',
                }}
              >
                The server did not include a version stamp (X-Resource-Version
                header missing). Merge manually is unavailable.
              </p>
            )}
          </div>

          <button
            data-testid="conflict-discard"
            type="button"
            onClick={() => setShowDiscard(true)}
            style={{
              padding: '.6rem 1rem',
              border: '1px solid #dc2626',
              borderRadius: '4px',
              background: '#fff',
              color: '#dc2626',
              cursor: 'pointer',
              fontSize: '.9rem',
            }}
          >
            Discard mine
          </button>
        </div>
      </div>
    </div>
  )

  return (
    <>
      {createPortal(dialog, portalHost(portalContainer))}

      {showMerge &&
        createPortal(
          <div
            data-testid="conflict-merge-panel"
            role="dialog"
            aria-modal="true"
            aria-labelledby="conflict-merge-title"
            style={{
              position: 'fixed',
              inset: 0,
              background: 'rgba(0,0,0,0.45)',
              zIndex: 560,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
            }}
          >
            <div
              style={{
                background: '#fff',
                borderRadius: '8px',
                padding: '1.5rem',
                maxWidth: '720px',
                width: '92vw',
                maxHeight: '85vh',
                overflowY: 'auto',
                boxShadow: '0 8px 32px rgba(0,0,0,0.18)',
              }}
            >
              <h3
                id="conflict-merge-title"
                style={{ margin: '0 0 1rem', fontSize: '1.05rem', fontWeight: 600 }}
              >
                Merge manually
              </h3>
              <p style={{ margin: '0 0 1rem', fontSize: '.85rem', color: '#6b7280' }}>
                Pick which side wins for each field. Saved version will be{' '}
                <code>{conflictVersion ?? '—'}</code>.
              </p>
              <div data-testid="json-diff-view" style={{ marginBottom: '1rem' }}>
                <JsonDiffView before={serverPayload} after={localDraft} />
              </div>
              <table style={{ width: '100%', fontSize: '.85rem', borderCollapse: 'collapse' }}>
                <thead>
                  <tr style={{ background: '#f8fafc', textAlign: 'left' }}>
                    <th style={{ padding: '.4rem .5rem', borderBottom: '1px solid #e2e8f0' }}>Field</th>
                    <th style={{ padding: '.4rem .5rem', borderBottom: '1px solid #e2e8f0' }}>Source</th>
                  </tr>
                </thead>
                <tbody>
                  {allKeys.map((k) => (
                    <tr key={k}>
                      <td style={{ padding: '.35rem .5rem', fontFamily: 'monospace' }}>{k}</td>
                      <td style={{ padding: '.35rem .5rem' }}>
                        <select
                          data-testid={`conflict-merge-source-${k}`}
                          value={initialiseChoice(k)}
                          onChange={(e) =>
                            setChoices((prev) => ({ ...prev, [k]: e.target.value as MergeSource }))
                          }
                          style={{ padding: '.2rem .4rem' }}
                        >
                          <option value="server">Server</option>
                          <option value="local">Local (draft)</option>
                        </select>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
              <div style={{ display: 'flex', justifyContent: 'flex-end', gap: '.5rem', marginTop: '1rem' }}>
                <button
                  type="button"
                  onClick={() => setShowMerge(false)}
                  style={{
                    padding: '6px 16px',
                    border: '1px solid #d1d5db',
                    borderRadius: '4px',
                    background: '#fff',
                    cursor: 'pointer',
                    fontSize: '.875rem',
                  }}
                >
                  Cancel
                </button>
                <button
                  data-testid="conflict-merge-save"
                  type="button"
                  onClick={handleMergeSave}
                  style={{
                    padding: '6px 16px',
                    border: 'none',
                    borderRadius: '4px',
                    background: '#2563eb',
                    color: '#fff',
                    cursor: 'pointer',
                    fontSize: '.875rem',
                  }}
                >
                  Save merged
                </button>
              </div>
            </div>
          </div>,
          portalHost(portalContainer),
        )}

      <ConfirmDialog
        open={showDiscard}
        title="Discard your local changes?"
        body="Your local draft will be removed and the server's version will be loaded. This cannot be undone."
        confirmText="Discard"
        cancelText="Keep draft"
        confirmVariant="danger"
        onConfirm={handleDiscardConfirm}
        onCancel={() => setShowDiscard(false)}
      />
    </>
  )
}
