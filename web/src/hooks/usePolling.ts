import { useCallback, useEffect, useMemo, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'

interface UsePollingOptions {
  queryKeyPrefix: readonly unknown[]
  intervalMs?: number
  enabled?: boolean
}

interface UsePollingResult {
  lastRefreshedAt: string | null
  refreshNow: () => Promise<void>
  refreshCount: number
}

export function usePolling(options: UsePollingOptions): UsePollingResult {
  const queryClient = useQueryClient()
  const [lastRefreshedAt, setLastRefreshedAt] = useState<string | null>(null)
  const [refreshCount, setRefreshCount] = useState(0)

  const resolvedIntervalMs = useMemo(() => {
    if (typeof options.intervalMs === 'number' && options.intervalMs > 0) {
      return options.intervalMs
    }
    const fromEnv = Number(import.meta.env.VITE_POLL_INTERVAL_MS ?? 10_000)
    return Number.isFinite(fromEnv) && fromEnv > 0 ? fromEnv : 10_000
  }, [options.intervalMs])

  const pollingEnabled = (options.enabled ?? true) && import.meta.env.MODE !== 'test'

  const refreshNow = useCallback(async () => {
    if (!pollingEnabled) return
    try {
      await queryClient.invalidateQueries({ queryKey: options.queryKeyPrefix })
      setLastRefreshedAt(new Date().toISOString())
      setRefreshCount((count) => count + 1)
    } catch {
      // Keep stale-data timestamp when refresh fails.
    }
  }, [options.queryKeyPrefix, pollingEnabled, queryClient])

  useEffect(() => {
    if (!pollingEnabled) return

    const onVisibilityChange = () => {
      if (!document.hidden) {
        void refreshNow()
      }
    }

    const timer = window.setInterval(() => {
      if (!document.hidden) {
        void refreshNow()
      }
    }, resolvedIntervalMs)

    document.addEventListener('visibilitychange', onVisibilityChange)

    return () => {
      window.clearInterval(timer)
      document.removeEventListener('visibilitychange', onVisibilityChange)
    }
  }, [pollingEnabled, refreshNow, resolvedIntervalMs])

  return { lastRefreshedAt, refreshNow, refreshCount }
}
