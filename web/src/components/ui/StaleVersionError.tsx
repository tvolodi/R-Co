/** StaleVersionError — RND-UI-06
 *
 *  Boundary-mounted surface for the 'stale-version' state. Hosts the
 *  ConflictResolver inside an explanatory banner. Renders NO write side
 *  effects — the ConflictResolver's three actions emit to the four
 *  callbacks; the page decides how to fulfil them.
 */

import React, { useState } from 'react'
import type { ApiError } from '@/types/api'
import { ConflictResolver } from './ConflictResolver'
import { FetchError } from './FetchError'

export interface StaleVersionErrorProps {
  /** The 409 ApiError, including details.xResourceVersion. */
  error: ApiError
  /** Server payload after the 409. */
  serverPayload: Record<string, unknown>
  /** Local draft from the Zustand store. */
  localDraft: Record<string, unknown>
  /** Refetch callback. */
  onRefetch: () => void
  /** Save-merged callback. */
  onSaveMerged: (mergedBody: Record<string, unknown>, version: string) => void
  /** Discard-confirmed callback. */
  onDiscardConfirmed: () => void
}

export function StaleVersionError(props: StaleVersionErrorProps): React.ReactElement {
  const { error, serverPayload, localDraft, onRefetch, onSaveMerged, onDiscardConfirmed } = props
  const [refetchError, setRefetchError] = useState<Error | null>(null)

  const conflictVersion =
    typeof error.details?.xResourceVersion === 'string'
      ? (error.details.xResourceVersion as string)
      : null

  // §12.2 mode 4 — network failure during Refetch latest: show FetchError
  // banner ABOVE the resolver modal so the user can read both.
  const safeOnRefetch = (): void => {
    try {
      setRefetchError(null)
      onRefetch()
    } catch (e) {
      setRefetchError(e instanceof Error ? e : new Error(String(e)))
    }
  }

  return (
    <div data-testid="stale-version-error">
      <div
        role="alert"
        style={{
          padding: '1.25rem',
          border: '1px solid #fde68a',
          background: '#fffbeb',
          borderRadius: '6px',
          marginBottom: '1rem',
          color: '#92400e',
        }}
      >
        <p style={{ margin: 0, fontWeight: 500 }}>
          This record has been updated by another user since you started editing.
        </p>
        <p style={{ margin: '.5rem 0 0', fontSize: '.85rem' }}>
          Choose how to resolve the conflict.
        </p>
      </div>

      {refetchError && (
        <div style={{ marginBottom: '1rem' }}>
          <FetchError onRetry={safeOnRefetch} />
        </div>
      )}

      <ConflictResolver
        serverPayload={serverPayload}
        localDraft={localDraft}
        conflictVersion={conflictVersion}
        onRefetch={safeOnRefetch}
        onSaveMerged={onSaveMerged}
        onDiscardConfirmed={onDiscardConfirmed}
      />
    </div>
  )
}
