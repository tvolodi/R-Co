import { client } from './client'
import { getToken } from './client'
import type { HealthStatus } from '@/types/api'

export const healthApi = {
  get: () => client.get<HealthStatus>('/api/v1/health'),
}

/**
 * Connectivity probe — raw fetch to /health/ready.
 * Returns true if the backend responds with a 2xx status.
 * Returns false on any error (network failure, timeout, non-2xx).
 * Never throws.
 */
export async function healthReady(): Promise<boolean> {
  try {
    const token = getToken()
    const headers: Record<string, string> = {}
    if (token) {
      headers['Authorization'] = `Bearer ${token}`
    }
    const response = await fetch('/health/ready', {
      headers,
      signal: AbortSignal.timeout(5000),
    })
    return response.ok
  } catch {
    return false
  }
}
