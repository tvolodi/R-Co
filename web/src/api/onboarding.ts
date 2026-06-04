/** Onboarding API — tenant registration via saga
 *  Covers: ONB-UI-01..04
 *  All calls go through client.ts per frontend conventions.
 *  Idempotency-Key is injected per-call by submitOnboarding (not by client.ts globally).
 */

import { getToken } from './client'

const BASE_URL = import.meta.env.VITE_API_BASE_URL ?? ''

// ── Types ──────────────────────────────────────────────────────────────────────

export interface RealmConfig {
  default_token_lifetime_seconds?: number
  min_password_length?: number
  require_uppercase?: boolean
  require_digit?: boolean
  signing_key_algorithm?: string
}

export interface ClientConfig {
  redirect_uris: string[]
  service_account_enabled?: boolean
}

export interface OnboardingFormValues {
  slug: string
  display_name: string
  admin_email: string
  admin_username: string
  admin_display_name: string
  hostname: string
  redirect_uris: string[]
  realm_config?: RealmConfig
  client_config?: Omit<ClientConfig, 'redirect_uris'>
}

export interface OnboardingSubmitRequest {
  slug: string
  display_name: string
  admin_email: string
  admin_username: string
  admin_display_name: string
  hostname: string
  client_config: ClientConfig
  realm_config?: RealmConfig
}

export interface OnboardingCreateResponse {
  onboarding_id: string
}

export type OnboardingState = 'pending' | 'completed' | 'failed'

export interface OnboardingStatusPending {
  state: 'pending'
}

export interface OnboardingStatusCompleted {
  state: 'completed'
  onboarding_id: string
  tenant_id: string
  idp_realm_id: string
  client_id: string
  admin_user_id: string
  hostname: string
  oidc_authority: string
  discovery_url: string
  created: string
  slug?: string
}

export interface OnboardingStatusFailed {
  state: 'failed'
  error: string
}

export type OnboardingSagaResult =
  | OnboardingStatusPending
  | OnboardingStatusCompleted
  | OnboardingStatusFailed

// ── API helpers ────────────────────────────────────────────────────────────────

function buildHeaders(extra?: Record<string, string>): Record<string, string> {
  const token = getToken()
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...extra,
  }
  if (token) {
    headers['Authorization'] = `Bearer ${token}`
  }
  return headers
}

async function parseErrorBody(response: Response): Promise<Record<string, unknown>> {
  try {
    return (await response.json()) as Record<string, unknown>
  } catch {
    return {}
  }
}

// ── Public API ─────────────────────────────────────────────────────────────────

/**
 * POST /api/v1/onboarding
 * Injects the provided idempotencyKey as the Idempotency-Key header.
 * Throws on non-201 responses with the raw response attached so callers
 * can inspect the status and body for the error taxonomy (section 9.2).
 */
export async function submitOnboarding(
  formValues: OnboardingFormValues,
  idempotencyKey: string,
): Promise<OnboardingCreateResponse> {
  const body: OnboardingSubmitRequest = {
    slug: formValues.slug,
    display_name: formValues.display_name,
    admin_email: formValues.admin_email,
    admin_username: formValues.admin_username,
    admin_display_name: formValues.admin_display_name,
    hostname: formValues.hostname,
    client_config: {
      redirect_uris: formValues.redirect_uris,
      ...(formValues.client_config?.service_account_enabled !== undefined
        ? { service_account_enabled: formValues.client_config.service_account_enabled }
        : {}),
    },
    ...(formValues.realm_config && Object.keys(formValues.realm_config).length > 0
      ? { realm_config: formValues.realm_config }
      : {}),
  }

  const response = await window.fetch(`${BASE_URL}/api/v1/onboarding`, {
    method: 'POST',
    headers: buildHeaders({ 'Idempotency-Key': idempotencyKey }),
    body: JSON.stringify(body),
  })

  if (response.status === 201) {
    return response.json() as Promise<OnboardingCreateResponse>
  }

  // Surface the parsed body and status for error taxonomy handling in the page
  const errorBody = await parseErrorBody(response)
  const err = new OnboardingApiError(response.status, errorBody)
  throw err
}

/**
 * GET /api/v1/onboarding/:onboardingId
 * Returns the current saga state record.
 * Throws on non-2xx responses.
 */
export async function getOnboardingStatus(onboardingId: string): Promise<OnboardingSagaResult> {
  const response = await window.fetch(`${BASE_URL}/api/v1/onboarding/${onboardingId}`, {
    headers: buildHeaders(),
  })

  if (response.ok) {
    return response.json() as Promise<OnboardingSagaResult>
  }

  const errorBody = await parseErrorBody(response)
  throw new OnboardingApiError(response.status, errorBody)
}

/**
 * GET /api/v1/onboarding?hostname=<hostname>
 * Returns the completed saga record for the given hostname.
 * The backend only returns state=completed records via this endpoint.
 * Throws on non-2xx responses (404 means saga not found/failed).
 */
export async function getOnboardingByHostname(hostname: string): Promise<OnboardingStatusCompleted> {
  const params = new URLSearchParams({ hostname })
  const response = await window.fetch(`${BASE_URL}/api/v1/onboarding?${params.toString()}`, {
    headers: buildHeaders(),
  })

  if (response.ok) {
    return response.json() as Promise<OnboardingStatusCompleted>
  }

  const errorBody = await parseErrorBody(response)
  throw new OnboardingApiError(response.status, errorBody)
}

// ── Error class ────────────────────────────────────────────────────────────────

export class OnboardingApiError extends Error {
  constructor(
    public readonly httpStatus: number,
    public readonly body: Record<string, unknown>,
  ) {
    super(`Onboarding API error: HTTP ${httpStatus}`)
    this.name = 'OnboardingApiError'
  }
}
