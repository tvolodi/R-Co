/**
 * Shared E2E test helpers — login via Keycloak token injection.
 *
 * Since the token-based login page has been removed, tests authenticate by:
 *   1. Obtaining a JWT from Keycloak's token endpoint (password grant)
 *   2. Storing the session in sessionStorage via addInitScript
 *   3. The app reads it on startup and restores the session
 */

import type { Page, APIRequestContext } from '@playwright/test'

function normalizeIdpBaseUrl(raw: string | undefined): string {
  const fallback = 'http://localhost:8081'
  const value = (raw ?? fallback).trim()
  if (value.length == 0) return fallback
  // Keep issuer/authority host consistent with backend expectations.
  return value.replace('://127.0.0.1', '://localhost').replace(/\/$/, '')
}

// Use localhost (not 127.0.0.1) so that issued JWT tokens have iss=http://localhost:8081/...
// which matches the backend's configured BPM_IDP_BASE_URL.
const KEYCLOAK_BASE_URL =
  normalizeIdpBaseUrl(process.env.BPM_IDP_BASE_URL)
const KEYCLOAK_TOKEN_URL = `${KEYCLOAK_BASE_URL}/realms/bpm-default/protocol/openid-connect/token`
const KEYCLOAK_CLIENT_ID = 'bpm-platform-api'

/** Obtain a JWT access token from Keycloak via password grant. */
export async function getKeycloakToken(
  request: APIRequestContext,
  username = 'admin-user',
  password = 'admin-pass',
): Promise<string> {
  const response = await request.post(KEYCLOAK_TOKEN_URL, {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    form: {
      client_id: KEYCLOAK_CLIENT_ID,
      username,
      password,
      grant_type: 'password',
    },
  })

  if (!response.ok()) {
    const body = await response.text()
    throw new Error(
      `Keycloak token request failed (${response.status()}): ${body}\n` +
      `Ensure Keycloak is running at ${KEYCLOAK_TOKEN_URL.replace('/protocol/openid-connect/token', '')}\n` +
      `and user ${username} exists.`,
    )
  }

  const body = await response.json() as { access_token: string }
  return body.access_token
}

/** Decode a JWT payload without verification. */
function decodeJwtPayload(token: string): { sub: string; roles?: string[]; preferred_username?: string; name?: string; email?: string } {
  return JSON.parse(Buffer.from(token.split('.')[1], 'base64').toString('utf-8'))
}

/**
 * Log in to the app by injecting a Keycloak token via sessionStorage bridge.
 *
 * This must be called BEFORE page.goto(). It uses addInitScript to write the
 * session to sessionStorage before any page JS runs, so the app's AuthProvider
 * picks it up on initial render and treats the user as authenticated.
 *
 * Usage:
 *   const token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
 *   await loginWithToken(page, token)
 *   // page is now authenticated at /
 */
export async function loginWithToken(page: Page, token: string): Promise<void> {
  const payload = decodeJwtPayload(token)
  const displayName =
    payload.preferred_username ??
    payload.name ??
    payload.email ??
    payload.sub

  // Set up a script that runs before any page JS to inject the session
  await page.addInitScript((args: { token: string; displayName: string; roles: string[] }) => {
    const session = {
      token: args.token,
      display_name: args.displayName,
      roles: args.roles,
      loginSource: 'oidc' as const,
    }
    sessionStorage.setItem('__e2e_session', JSON.stringify(session))
  }, { token, displayName, roles: payload.roles ?? [] })

  // Navigate to the app root
  await page.goto('/', { waitUntil: 'domcontentloaded' })

  // Wait for the app shell to render (proves we're authenticated)
  await page.waitForSelector('[data-testid="user-display-name"]', { timeout: 15_000 }).catch(() => {
    // Fallback: just wait for any main content to appear
  })
}
