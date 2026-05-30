import { client } from './client'
import type { ApiError, HealthStatus } from '@/types/api'

export interface AdminHealthComponentStatus {
  status: 'ok' | 'degraded' | 'error'
  detail?: string
  latency_ms?: number
}

export interface AdminHealthSnapshot {
  status: 'ok' | 'degraded' | 'error'
  database: AdminHealthComponentStatus
  scheduler: AdminHealthComponentStatus
  uptime_seconds: number
  db_query_latency_ms: number
  refreshed_at: string
}

interface ReadinessFailure {
  subsystem?: string
  code?: string
  detail?: string
  retryable?: boolean
}

interface ReadinessErrorBody {
  status?: string
  failing_subsystems?: ReadinessFailure[]
}

interface ReadinessOkBody {
  status: 'ok' | 'degraded' | 'error'
  db_latency_ms?: number
}

function toSnapshotFromOk(payload: ReadinessOkBody): AdminHealthSnapshot {
  const dbLatency = payload.db_latency_ms ?? 0
  return {
    status: payload.status,
    database: {
      status: payload.status === 'ok' ? 'ok' : 'degraded',
      latency_ms: payload.db_latency_ms,
    },
    scheduler: {
      status: payload.status === 'ok' ? 'ok' : 'degraded',
      detail: payload.status === 'ok' ? undefined : 'Readiness is degraded',
    },
    uptime_seconds: 0,
    db_query_latency_ms: dbLatency,
    refreshed_at: new Date().toISOString(),
  }
}

function toSnapshotFromDegraded(payload: ReadinessErrorBody): AdminHealthSnapshot {
  const failures = payload.failing_subsystems ?? []
  const dbFailure = failures.find((f) => f.subsystem === 'database')
  const schedulerFailure = failures.find((f) => f.subsystem === 'scheduler')

  return {
    status: 'degraded',
    database: {
      status: dbFailure ? 'error' : 'ok',
      detail: dbFailure?.detail ?? dbFailure?.code,
    },
    scheduler: {
      status: schedulerFailure ? 'error' : 'ok',
      detail: schedulerFailure?.detail ?? schedulerFailure?.code,
    },
    uptime_seconds: 0,
    db_query_latency_ms: 0,
    refreshed_at: new Date().toISOString(),
  }
}

export async function getReadinessSnapshot(): Promise<AdminHealthSnapshot> {
  try {
    const payload = await client.get<ReadinessOkBody>('/health/ready')
    return toSnapshotFromOk(payload)
  } catch (error) {
    const apiError = error as ApiError
    if (apiError.status !== 503) {
      throw error
    }
    const details = (apiError.details ?? {}) as ReadinessErrorBody
    return toSnapshotFromDegraded(details)
  }
}

export const healthApi = {
  get: () => client.get<HealthStatus>('/api/v1/health'),
  ready: () => getReadinessSnapshot(),
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
