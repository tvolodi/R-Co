/** OIDC Manager — singleton UserManager for authorization code flow via oidc-client-ts */

import { UserManager, WebStorageStateStore } from 'oidc-client-ts'
import type { UserManagerSettings } from 'oidc-client-ts'
import { fetchTenantConfig } from './tenantConfig'

function buildOidcSettings(authority: string, clientId: string): UserManagerSettings {
  const normalizedAuthority = authority.replace(/\/+$/, '')
  return {
    authority: normalizedAuthority,
    client_id: clientId,
    redirect_uri: window.location.origin + '/auth/callback',
    response_type: 'code',
    scope: 'openid profile',
    // Keep endpoint URLs pinned to configured authority. Some local Keycloak setups
    // advertise discovery metadata without the exposed host port.
    metadata: {
      issuer: normalizedAuthority,
      authorization_endpoint: `${normalizedAuthority}/protocol/openid-connect/auth`,
      token_endpoint: `${normalizedAuthority}/protocol/openid-connect/token`,
      userinfo_endpoint: `${normalizedAuthority}/protocol/openid-connect/userinfo`,
      end_session_endpoint: `${normalizedAuthority}/protocol/openid-connect/logout`,
      jwks_uri: `${normalizedAuthority}/protocol/openid-connect/certs`,
    },
    userStore: new WebStorageStateStore({ store: window.sessionStorage }),
    automaticSilentRenew: false,
  }
}

const _defaultSettings: UserManagerSettings = buildOidcSettings(
  (import.meta.env.VITE_OIDC_AUTHORITY as string) ?? 'http://localhost:8081/realms/bpm-default',
  (import.meta.env.VITE_OIDC_CLIENT_ID as string) ?? 'bpm-platform-api',
)

/** Backward-compat sync export using default (env-var) config. */
export const oidcManager = new UserManager(_defaultSettings)

/** Lazy-resolved manager using dynamic tenant config from /api/tenant-config. */
let _resolvedManager: UserManager | null = null

export async function getOidcManager(): Promise<UserManager> {
  if (_resolvedManager) return _resolvedManager
  const config = await fetchTenantConfig(window.location.hostname)
  const settings: UserManagerSettings = buildOidcSettings(config.oidc_authority, config.client_id)
  _resolvedManager = new UserManager(settings)
  return _resolvedManager
}

/** Start the automatic silent renew loop. Call once after a successful OIDC login. */
export function startOidcSilentRenew(): void {
  oidcManager.startSilentRenew()
}
