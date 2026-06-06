/** Onboarding API — tenant registration via saga
 *  Covers: ONB-UI-01..04
 *  All calls go through client.ts per frontend conventions.
 *  Idempotency-Key is injected per-call by submitOnboarding (not by client.ts globally).
 */

import { client } from './client'
import type { ApiError } from '@/types/api'

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

  const response = await client.postWithHeaders<OnboardingCreateResponse>(
    '/api/v1/onboarding',
    body,
    { 'Idempotency-Key': idempotencyKey },
  ).catch((err: unknown) => {
    // Convert ApiError → OnboardingApiError for caller taxonomy handling
    const apiErr = err as ApiError
    const details = (apiErr.details ?? {}) as Record<string, unknown>
    throw new OnboardingApiError(apiErr.status ?? 500, {
      ...details,
      ...(!details['error'] && apiErr.code ? { error: apiErr.code } : {}),
      ...(!details['title'] && apiErr.message ? { title: apiErr.message } : {}),
    })
  })

  return response
}

/**
 * GET /api/v1/onboarding/:onboardingId
 * Returns the current saga state record.
 * Throws on non-2xx responses.
 */
export async function getOnboardingStatus(onboardingId: string): Promise<OnboardingSagaResult> {
  return client.get<OnboardingSagaResult>(`/api/v1/onboarding/${onboardingId}`)
}

/**
 * GET /api/v1/onboarding?hostname=<hostname>
 * Returns the completed saga record for the given hostname.
 * The backend only returns state=completed records via this endpoint.
 * Throws on non-2xx responses (404 means saga not found/failed).
 */
export async function getOnboardingByHostname(hostname: string): Promise<OnboardingStatusCompleted> {
  return client.get<OnboardingStatusCompleted>('/api/v1/onboarding', { hostname })
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
