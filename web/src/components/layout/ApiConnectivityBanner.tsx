import type React from 'react'
import { useApiConnectivity } from '@/hooks/useApiConnectivity'

interface ApiConnectivityBannerProps {
  /**
   * Forwarded to useApiConnectivity; defaults to VITE_HEALTH_POLL_INTERVAL_MS.
   */
  pollIntervalMs?: number
}

export function ApiConnectivityBanner(
  props: ApiConnectivityBannerProps,
): React.ReactElement | null {
  const { isOnline } = useApiConnectivity(
    props.pollIntervalMs !== undefined
      ? { intervalMs: props.pollIntervalMs }
      : undefined,
  )

  // Don't show during initial load (null) or when online
  if (isOnline === null || isOnline === true) {
    return null
  }

  return (
    <div
      data-testid="connectivity-banner"
      role="status"
      aria-live="polite"
      style={{
        position: 'sticky',
        top: 0,
        zIndex: 100,
        background: '#fef9c3',
        borderBottom: '1px solid #eab308',
        color: '#713f12',
        padding: '.5rem 1.25rem',
        display: 'flex',
        alignItems: 'center',
        gap: '.5rem',
        fontSize: '.875rem',
        fontWeight: 500,
      }}
    >
      <svg
        aria-hidden="true"
        width="16"
        height="16"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
        style={{ flexShrink: 0 }}
      >
        <path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z" />
        <line x1="12" y1="9" x2="12" y2="13" />
        <line x1="12" y1="17" x2="12.01" y2="17" />
      </svg>
      Platform is currently unavailable — some actions may fail.
    </div>
  )
}
