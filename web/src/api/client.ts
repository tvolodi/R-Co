/** API Client — typed fetch wrapper
 *  Adapted from ai-dala-forge/frontend/src/core/api/client.ts
 *  Changes for BPM Platform:
 *  - RFC 9457 Problem Details error parsing
 *  - Retry-After header surfaced on 429
 *  - VITE_API_BASE_URL via env
 */

import type { ApiError } from '@/types/api'

const BASE_URL = import.meta.env.VITE_API_BASE_URL ?? ''
const TOKEN_KEY = 'bpm_auth_token'
const REFRESH_TOKEN_KEY = 'bpm_refresh_token'

// ── Token storage ──────────────────────────────────────────────────────────────

export function getToken(): string | null {
  return localStorage.getItem(TOKEN_KEY)
}
export function setToken(token: string): void {
  localStorage.setItem(TOKEN_KEY, token)
}
export function clearToken(): void {
  localStorage.removeItem(TOKEN_KEY)
}
export function getRefreshToken(): string | null {
  return localStorage.getItem(REFRESH_TOKEN_KEY)
}
export function setRefreshToken(token: string): void {
  localStorage.setItem(REFRESH_TOKEN_KEY, token)
}
export function clearRefreshToken(): void {
  localStorage.removeItem(REFRESH_TOKEN_KEY)
}

// ── Token rotation ─────────────────────────────────────────────────────────────

/** In-flight refresh shared across concurrent 401s */
let refreshPromise: Promise<string | null> | null = null

function isAuthEndpoint(path: string): boolean {
  return (
    path.includes('/auth/login') ||
    path.includes('/auth/refresh') ||
    path.includes('/auth/logout')
  )
}

async function refreshAccessToken(): Promise<string | null> {
  if (refreshPromise) return refreshPromise
  const stored = getRefreshToken()
  if (!stored) return null

  refreshPromise = fetch(`${BASE_URL}/api/v1/auth/refresh`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ refresh_token: stored }),
  })
    .then(async (res) => {
      if (!res.ok) return null
      const data = (await res.json()) as { access_token: string }
      setToken(data.access_token)
      return data.access_token
    })
    .catch(() => null)
    .finally(() => {
      refreshPromise = null
    })

  return refreshPromise
}

// ── Core request ───────────────────────────────────────────────────────────────

async function request<T>(path: string, options: RequestInit = {}): Promise<T> {
  const token = getToken()
  const isFormData = options.body instanceof FormData

  const headers: Record<string, string> = {
    ...(isFormData ? {} : { 'Content-Type': 'application/json' }),
    ...(options.headers as Record<string, string>),
  }
  if (token) headers['Authorization'] = `Bearer ${token}`

  let response = await fetch(`${BASE_URL}${path}`, { ...options, headers })

  // Silent token rotation on 401
  if (response.status === 401 && !isAuthEndpoint(path)) {
    const newToken = await refreshAccessToken()
    if (newToken) {
      const retryHeaders: Record<string, string> = {
        ...(isFormData ? {} : { 'Content-Type': 'application/json' }),
        ...(options.headers as Record<string, string>),
        Authorization: `Bearer ${newToken}`,
      }
      const retry = await fetch(`${BASE_URL}${path}`, { ...options, headers: retryHeaders })
      if (retry.ok) {
        if (retry.status === 204) return undefined as unknown as T
        return retry.json() as Promise<T>
      }
      response = retry
    }
  }

  if (response.status === 401) {
    clearToken()
    clearRefreshToken()
    window.dispatchEvent(new CustomEvent('auth:session-expired'))
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
    const url = params ? `${path}?${new URLSearchParams(params as Record<string, string>)}` : path
    return request<T>(url)
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
