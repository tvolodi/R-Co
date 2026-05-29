/** API Client — typed fetch wrapper
 *  Adapted from ai-dala-forge/frontend/src/core/api/client.ts
 *  Changes for BPM Platform:
 *  - RFC 9457 Problem Details error parsing
 *  - Retry-After header surfaced on 429
 *  - VITE_API_BASE_URL via env
 */

import type { ApiError } from '@/types/api'

const BASE_URL = import.meta.env.VITE_API_BASE_URL ?? ''

// ── Token storage (in-memory — never localStorage/sessionStorage per FNFR-06) ──

let _token: string | null = null

export function getToken(): string | null {
  return _token
}
export function setToken(token: string): void {
  _token = token
}
export function clearToken(): void {
  _token = null
}

/** No-op — kept for API compatibility. */
export function tryRestoreE2eToken(): string | null {
  return null
}

// ── Core request ───────────────────────────────────────────────────────────────

async function request<T>(
  path: string,
  options: RequestInit = {},
  behavior: { suppressSessionExpiredEvent?: boolean } = {},
): Promise<T> {
  const token = getToken()
  const isFormData = options.body instanceof FormData

  const headers: Record<string, string> = {
    ...(isFormData ? {} : { 'Content-Type': 'application/json' }),
    ...(options.headers as Record<string, string>),
  }
  if (token) headers['Authorization'] = `Bearer ${token}`

  const response = await window.fetch(`${BASE_URL}${path}`, { ...options, headers })

  if (response.status === 401) {
    if (!behavior.suppressSessionExpiredEvent) {
      window.dispatchEvent(new CustomEvent('auth:session-expired'))
    }
    throw buildError(response, { status: 401, message: 'Session expired', code: 'UNAUTHORIZED' })
  }

  if (response.status === 429) {
    const retryAfter = response.headers.get('Retry-After')
    throw buildError(response, {
      status: 429,
      message: `Rate limit exceeded. Retry after ${retryAfter ?? '?'}s`,
      code: 'RATE_LIMITED',
      details: { retryAfter },
    })
  }

  if (!response.ok) {
    // RFC 9457 Problem Details
    let body: Record<string, unknown> = {}
    try {
      body = (await response.json()) as Record<string, unknown>
    } catch { /* not JSON */ }

    throw buildError(response, {
      status: response.status,
      message: (body['title'] as string) ?? (body['message'] as string) ?? response.statusText,
      code: (body['type'] as string) ?? (body['code'] as string) ?? String(response.status),
      details: body['errors'] as Record<string, unknown>,
    })
  }

  if (response.status === 204) return undefined as unknown as T
  return response.json() as Promise<T>
}

function buildError(response: Response, partial: Partial<ApiError>): ApiError {
  return {
    status: response.status,
    message: 'Request failed',
    code: String(response.status),
    ...partial,
  }
}

// ── Public API surface ─────────────────────────────────────────────────────────

export const client = {
  get<T>(path: string, params?: Record<string, unknown>): Promise<T> {
    const url = params
      ? `${path}?${new URLSearchParams(
          Object.fromEntries(
            Object.entries(params).filter((entry): entry is [string, string] => {
              const v = entry[1];
              return v !== undefined && v !== null && v !== '';
            }),
          ),
        )}`
      : path
    return request<T>(url)
  },
  getWithToken<T>(path: string, token: string, params?: Record<string, unknown>): Promise<T> {
    const url = params
      ? `${path}?${new URLSearchParams(
          Object.fromEntries(
            Object.entries(params).filter((entry): entry is [string, string] => {
              const v = entry[1];
              return v !== undefined && v !== null && v !== '';
            }),
          ),
        )}`
      : path
    return request<T>(url, {
      headers: { Authorization: `Bearer ${token}` },
    }, {
      suppressSessionExpiredEvent: true,
    })
  },
  post<T>(path: string, body?: unknown): Promise<T> {
    return request<T>(path, {
      method: 'POST',
      body: body instanceof FormData ? body : JSON.stringify(body),
    })
  },
  put<T>(path: string, body?: unknown): Promise<T> {
    return request<T>(path, {
      method: 'PUT',
      body: body instanceof FormData ? body : JSON.stringify(body),
    })
  },
  patch<T>(path: string, body?: unknown): Promise<T> {
    return request<T>(path, {
      method: 'PATCH',
      body: body instanceof FormData ? body : JSON.stringify(body),
    })
  },
  delete<T>(path: string): Promise<T> {
    return request<T>(path, { method: 'DELETE' })
  },
}
