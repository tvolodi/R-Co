import { useState, useEffect } from 'react'
import { healthReady } from '@/api/health'

interface UseApiConnectivityOptions {
  /**
   * Polling interval in milliseconds.
   * Defaults to VITE_HEALTH_POLL_INTERVAL_MS env variable, or 30000.
   */
  intervalMs?: number
}

interface UseApiConnectivityResult {
  /** true = backend is reachable; false = unreachable; null = not yet checked */
  isOnline: boolean | null
  /** ISO timestamp of the last successful check, or null */
  lastOnlineAt: string | null
  /** ISO timestamp of when the outage began, or null if currently online */
  outageSince: string | null
}

const DEFAULT_INTERVAL_MS = Number(
  import.meta.env.VITE_HEALTH_POLL_INTERVAL_MS ?? 30000,
)

export function useApiConnectivity(
  options?: UseApiConnectivityOptions,
): UseApiConnectivityResult {
  const intervalMs = options?.intervalMs ?? DEFAULT_INTERVAL_MS

  const [isOnline, setIsOnline] = useState<boolean | null>(null)
  const [lastOnlineAt, setLastOnlineAt] = useState<string | null>(null)
  const [outageSince, setOutageSince] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false

    async function check(): Promise<void> {
      const ok = await healthReady()
      if (cancelled) return

      if (ok) {
        setIsOnline(true)
        setLastOnlineAt(new Date().toISOString())
        setOutageSince(null)
      } else {
        setIsOnline((prev) => {
          // Only set outageSince on the first failure (prev was true or null)
          if (prev !== false) {
            setOutageSince(new Date().toISOString())
          }
          return false
        })
      }
    }

    // Immediate check on mount
    void check()

    const id = setInterval(() => void check(), intervalMs)

    return () => {
      cancelled = true
      clearInterval(id)
    }
  }, [intervalMs])

  return { isOnline, lastOnlineAt, outageSince }
}
