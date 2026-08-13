import React from 'react'
import type { RendererState } from '@/utils/classifyError'
import { SkeletonLayout, type SkeletonColumn } from './SkeletonLayout'
import { FetchError } from './FetchError'
import { PermissionDenied } from './PermissionDenied'
import { RateLimitBackpressure } from './RateLimitBackpressure'
import { StaleVersionError } from './StaleVersionError'
import type { ApiError } from '@/types/api'

interface QueryStateBoundaryProps {
  state: RendererState
  children: React.ReactNode
  onRetry?: () => void
  columns?: SkeletonColumn[]
  /** RND-UI-05: the parsed Retry-After seconds from the 429 response. */
  rateLimitRetryAfter?: number
  /** RND-UI-06: server payload after the 409, used by StaleVersionError. */
  staleVersionServerPayload?: Record<string, unknown>
  /** RND-UI-06: local draft (from the Zustand store) after the 409. */
  staleVersionLocalDraft?: Record<string, unknown>
  /** RND-UI-06: the underlying 409 ApiError, used by StaleVersionError. */
  staleVersionError?: ApiError
  /** RND-UI-06: save-merged callback for the 'stale-version' state. */
  staleVersionOnSaveMerged?: (mergedBody: Record<string, unknown>, version: string) => void
  /** RND-UI-06: discard-confirmed callback for the 'stale-version' state. */
  staleVersionOnDiscardConfirmed?: () => void
}

const noop = (): void => undefined

const DEFAULT_COLUMNS: SkeletonColumn[] = [
  { widthPercent: 20 },
  { widthPercent: 35 },
  { widthPercent: 25 },
  { widthPercent: 20 },
]

export function QueryStateBoundary({
  state,
  children,
  onRetry,
  columns,
  rateLimitRetryAfter,
  staleVersionServerPayload,
  staleVersionLocalDraft,
  staleVersionError,
  staleVersionOnSaveMerged,
  staleVersionOnDiscardConfirmed,
}: QueryStateBoundaryProps): React.ReactElement | null {
  switch (state) {
    case 'loading':
      return <SkeletonLayout columns={columns ?? DEFAULT_COLUMNS} />
    case 'success':
      return <>{children}</>
    case 'fetch-failure':
      return <FetchError onRetry={onRetry ?? noop} />
    case 'permission-denied':
      return <PermissionDenied />
    case 'stale-version':
      if (
        staleVersionError &&
        staleVersionServerPayload !== undefined &&
        staleVersionLocalDraft !== undefined &&
        staleVersionOnSaveMerged &&
        staleVersionOnDiscardConfirmed
      ) {
        return (
          <StaleVersionError
            error={staleVersionError}
            serverPayload={staleVersionServerPayload}
            localDraft={staleVersionLocalDraft}
            onRefetch={onRetry ?? noop}
            onSaveMerged={staleVersionOnSaveMerged}
            onDiscardConfirmed={staleVersionOnDiscardConfirmed}
          />
        )
      }
      // Fallback: render the legacy alert surface when no callbacks are wired.
      return (
        <div role="alert" style={{ padding: '1.5rem' }}>
          <p style={{ marginBottom: '.75rem' }}>
            This record has been updated by another user. Refresh to see the latest version.
          </p>
          <button
            type="button"
            onClick={onRetry ?? noop}
            style={{ padding: '.4rem .9rem', border: '1px solid #cbd5e1', borderRadius: '4px', cursor: 'pointer' }}
          >
            Refresh
          </button>
        </div>
      )
    case 'rate-limit':
      // RND-UI-05: mount the countdown component; if the page didn't pipe
      // rateLimitRetryAfter, fall back to a default of 30s (matches the
      // API-10 default bucket refill window).
      return (
        <RateLimitBackpressure
          retryAfter={rateLimitRetryAfter ?? 30}
          onRetry={onRetry ?? noop}
        />
      )
    default: {
      const _exhaustive: never = state
      void _exhaustive
      return null
    }
  }
}
