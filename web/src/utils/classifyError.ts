import type { ApiError } from '@/types/api'

export type RendererState =
  | 'loading'
  | 'success'
  | 'fetch-failure'
  | 'permission-denied'
  | 'stale-version'
  | 'rate-limit'

export function classifyError(error: unknown): RendererState {
  const e = error as ApiError | null | undefined
  if (!e || typeof e !== 'object' || typeof (e as ApiError).status !== 'number') {
    return 'fetch-failure'
  }
  const status = (e as ApiError).status
  if (status === 401 || status === 403) return 'permission-denied'
  if (status === 409) return 'stale-version'
  if (status === 429) {
    const retryAfter = (e as ApiError).details?.retryAfter
    return retryAfter != null ? 'rate-limit' : 'fetch-failure'
  }
  return 'fetch-failure'
}
