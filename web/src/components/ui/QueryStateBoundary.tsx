import React from 'react'
import type { RendererState } from '@/utils/classifyError'
import { SkeletonLayout, type SkeletonColumn } from './SkeletonLayout'
import { FetchError } from './FetchError'
import { PermissionDenied } from './PermissionDenied'

interface QueryStateBoundaryProps {
  state: RendererState
  children: React.ReactNode
  onRetry?: () => void
  columns?: SkeletonColumn[]
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
      return (
        <div role="alert" style={{ padding: '1.5rem' }}>
          <p style={{ marginBottom: '.75rem' }}>
            Too many requests. Please wait a moment before trying again.
          </p>
          <button
            type="button"
            onClick={onRetry ?? noop}
            style={{ padding: '.4rem .9rem', border: '1px solid #cbd5e1', borderRadius: '4px', cursor: 'pointer' }}
          >
            Try again
          </button>
        </div>
      )
    default: {
      const _exhaustive: never = state
      void _exhaustive
      return null
    }
  }
}
