import { client } from './client'
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
    await client.get<unknown>('/health/ready')
    return true
  } catch {
    return false
  }
}
